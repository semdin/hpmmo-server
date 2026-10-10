#include "app.h"

#include "auth.h"

#include <httplib.h>
#include <nlohmann/json.hpp>

#include <algorithm>
#include <cmath>
#include <cstdio>
#include <fstream>
#include <limits>
#include <optional>
#include <set>
#include <sstream>
#include <unordered_map>

using json = nlohmann::json;
using db::ErrorKind;

namespace app {

namespace {

constexpr int kMaxInventoryKinds = 40;   // destination capacity (distinct item ids)
constexpr int kMaxItemAmount = 9999;
constexpr long long kMaxGalleons = 1'000'000'000LL;
constexpr long long kAbsent = std::numeric_limits<long long>::min() + 1;  // "field not sent"

struct Session {
    long long account_id = 0;
    std::string username;
};

std::string lower(std::string s) {
    std::transform(s.begin(), s.end(), s.begin(),
                   [](unsigned char c) { return static_cast<char>(std::tolower(c)); });
    return s;
}

int status_for(ErrorKind kind) {
    switch (kind) {
        case ErrorKind::Connection: return 503;
        case ErrorKind::Constraint: return 409;
        default: return 500;
    }
}

void send_json(httplib::Response& res, int status, const json& body) {
    res.status = status;
    res.set_content(body.dump(), "application/json");
}

void send_error(httplib::Response& res, int status, const std::string& message) {
    send_json(res, status, {{"success", false}, {"message", message}});
}

void send_db_error(httplib::Response& res, const db::Result& r, const std::string& what) {
    if (r.kind == ErrorKind::Connection) {
        send_error(res, 503, "Service unavailable: database unreachable.");
    } else if (r.kind == ErrorKind::Constraint) {
        // Never echo raw constraint text (schema details) to callers; log it.
        send_error(res, 409, what + " failed: a data constraint was violated.");
        std::printf("[error] %s: %s\n", what.c_str(), r.error.c_str());
    } else {
        send_error(res, status_for(r.kind), what + " failed.");
        std::printf("[error] %s: %s\n", what.c_str(), r.error.c_str());
    }
}

std::optional<json> parse_body(const httplib::Request& req, httplib::Response& res) {
    try {
        json body = json::parse(req.body.empty() ? "{}" : req.body);
        if (!body.is_object()) {
            send_error(res, 400, "Body must be a JSON object.");
            return std::nullopt;
        }
        return body;
    } catch (const std::exception&) {
        send_error(res, 400, "Invalid JSON payload.");
        return std::nullopt;
    }
}

std::string bearer_token(const httplib::Request& req) {
    const std::string h = req.get_header_value("Authorization");
    if (h.rfind("Bearer ", 0) == 0) return h.substr(7);
    return "";
}

// --- session lookup ----------------------------------------------------------

std::optional<Session> require_session(const httplib::Request& req, httplib::Response& res,
                                       db::Pool& pool) {
    const std::string token = bearer_token(req);
    if (token.empty()) {
        send_error(res, 401, "Missing session token.");
        return std::nullopt;
    }
    auto lease = pool.acquire();
    db::Result r = lease.exec(
        "UPDATE sessions s SET last_seen_at = now() FROM accounts a "
        "WHERE s.token_hash = $1 AND a.id = s.account_id "
        "AND s.revoked_at IS NULL AND s.expires_at > now() "
        "RETURNING s.account_id::text, a.username",
        {db::sha256_hex(token)});
    if (!r.ok) {
        send_db_error(res, r, "session check");
        return std::nullopt;
    }
    if (r.rows.empty()) {
        send_error(res, 401, "Invalid or expired session.");
        return std::nullopt;
    }
    Session s;
    s.account_id = std::stoll(r.rows[0][0].second.value_or("0"));
    s.username = r.rows[0][1].second.value_or("");
    return s;
}

bool require_service_token(const httplib::Request& req, httplib::Response& res, const Config& cfg) {
    if (cfg.service_token.empty()) {
        send_error(res, 503, "Private API disabled: HPMMO_SERVICE_TOKEN not configured.");
        return false;
    }
    if (!auth::constant_time_equal(req.get_header_value("X-Service-Token"), cfg.service_token)) {
        send_error(res, 403, "Service token required.");
        return false;
    }
    return true;
}

// Character endpoints accept either the caller's own session (scoped to that
// account) or the trusted world server presenting the service token, which may
// act on any character by id.
//
// TRUST BOUNDARY: HPMMO_SERVICE_TOKEN is infrastructure-only. It must never be
// shipped to or handled by a client (launcher, game build, logs): a holder can
// read and write every character, with no ownership restriction.
struct CharacterAuth {
    bool service = false;
    long long account_id = 0;
};

std::optional<CharacterAuth> require_session_or_service(const httplib::Request& req,
                                                        httplib::Response& res, const Config& cfg,
                                                        db::Pool& pool) {
    // The service token wins when both are presented: the world server carries
    // no end-user session.
    if (!req.get_header_value("X-Service-Token").empty()) {
        if (!require_service_token(req, res, cfg)) return std::nullopt;
        return CharacterAuth{true, 0};
    }
    auto session = require_session(req, res, pool);
    if (!session) return std::nullopt;
    return CharacterAuth{false, session->account_id};
}

// Ownership: does this account own this character id?
std::optional<bool> owns_character(db::Conn& conn, long long account_id, long long character_id) {
    db::Result r = conn.exec("SELECT 1 FROM characters WHERE id = $1 AND account_id = $2",
                             {std::to_string(character_id), std::to_string(account_id)});
    if (!r.ok && r.kind == ErrorKind::Connection) return std::nullopt;
    return !r.rows.empty();
}

// --- items -------------------------------------------------------------------

struct ItemLine {
    std::string item_id;
    int amount = 0;
    int tier = 0;
};

std::optional<ItemLine> parse_item(const json& j) {
    if (!j.is_object() || !j.contains("id") || !j["id"].is_string()) return std::nullopt;
    ItemLine line;
    line.item_id = j["id"].get<std::string>();
    if (line.item_id.empty() || line.item_id.size() > 64) return std::nullopt;
    if (!j.contains("amount") || !j["amount"].is_number_integer()) return std::nullopt;
    const long long amount = j["amount"].get<long long>();
    if (amount <= 0 || amount > kMaxItemAmount) return std::nullopt;
    line.amount = static_cast<int>(amount);
    if (j.contains("tier")) {
        // Godot decodes JSON integers as floats. An unchanged equipped item
        // may therefore return as 0.0; accept exactly integral tiers only.
        if (!j["tier"].is_number()) return std::nullopt;
        const double tier = j["tier"].get<double>();
        if (!std::isfinite(tier) || tier < 0 || tier > 9 || std::floor(tier) != tier)
            return std::nullopt;
        line.tier = static_cast<int>(tier);
    }
    return line;
}

json items_from_rows(const db::Rows& rows) {
    // rows: item_id, amount, tier  (aggregated)
    json arr = json::array();
    for (const auto& row : rows) {
        arr.push_back({{"id", row[0].second.value_or("")},
                       {"amount", std::stoi(row[1].second.value_or("0"))},
                       {"tier", std::stoi(row[2].second.value_or("0"))}});
    }
    return arr;
}

int distinct_item_kinds(db::Conn& conn, long long character_id) {
    db::Result r = conn.exec("SELECT COUNT(DISTINCT item_id)::text FROM character_items WHERE character_id = $1",
                             {std::to_string(character_id)});
    if (!r.ok || r.rows.empty()) return 0;
    return std::stoi(r.rows[0][0].second.value_or("0"));
}

// Grant items to a character inside an existing transaction.
bool grant_items(db::Conn& conn, long long character_id, const std::vector<ItemLine>& items,
                 std::string& error) {
    for (const auto& line : items) {
        // Clean stack-limit check first: exceeding the row cap fails the whole
        // operation with a readable reason instead of a raw CHECK violation.
        db::Result have = conn.exec(
            "SELECT COALESCE(SUM(amount),0)::text FROM character_items "
            "WHERE character_id=$1 AND item_id=$2 AND tier=$3",
            {std::to_string(character_id), line.item_id, std::to_string(line.tier)});
        if (!have.ok) {
            error = have.error;
            return false;
        }
        const long long held = std::stoll(have.rows[0][0].second.value_or("0"));
        if (held + line.amount > kMaxItemAmount) {
            error = "stack limit reached for " + line.item_id;
            return false;
        }
        db::Result up = conn.exec(
            "INSERT INTO character_items (character_id, item_id, amount, tier) VALUES ($1,$2,$3,$4) "
            "ON CONFLICT (character_id, item_id, tier) DO UPDATE SET amount = character_items.amount + EXCLUDED.amount",
            {std::to_string(character_id), line.item_id, std::to_string(line.amount), std::to_string(line.tier)});
        if (!up.ok) {
            error = up.error;
            return false;
        }
    }
    return true;
}

// Debit items from a character if fully owned; false with reason otherwise.
bool debit_items(db::Conn& conn, long long character_id, const std::vector<ItemLine>& items,
                 std::string& reason) {
    for (const auto& line : items) {
        db::Result have = conn.exec(
            "SELECT COALESCE(SUM(amount),0)::text FROM character_items WHERE character_id=$1 AND item_id=$2 AND tier=$3",
            {std::to_string(character_id), line.item_id, std::to_string(line.tier)});
        if (!have.ok) {
            reason = have.error;
            return false;
        }
        const long long held = std::stoll(have.rows[0][0].second.value_or("0"));
        if (held < line.amount) {
            reason = "sender does not own enough of " + line.item_id;
            return false;
        }
        long long to_remove = line.amount;
        while (to_remove > 0) {
            db::Result pick = conn.exec(
                "SELECT ctid::text, amount::text FROM character_items "
                "WHERE character_id=$1 AND item_id=$2 AND tier=$3 AND amount > 0 ORDER BY amount ASC LIMIT 1",
                {std::to_string(character_id), line.item_id, std::to_string(line.tier)});
            if (!pick.ok || pick.rows.empty()) {
                reason = "inventory state changed during transfer";
                return false;
            }
            const std::string ctid = pick.rows[0][0].second.value_or("");
            const long long row_amount = std::stoll(pick.rows[0][1].second.value_or("0"));
            if (row_amount <= to_remove) {
                db::Result del = conn.exec("DELETE FROM character_items WHERE ctid = $1::tid", {ctid});
                if (!del.ok) {
                    reason = del.error;
                    return false;
                }
                to_remove -= row_amount;
            } else {
                db::Result dec = conn.exec(
                    "UPDATE character_items SET amount = amount - $1 WHERE ctid = $2::tid",
                    {std::to_string(to_remove), ctid});
                if (!dec.ok) {
                    reason = dec.error;
                    return false;
                }
                to_remove = 0;
            }
        }
    }
    return true;
}

// --- op ledger ---------------------------------------------------------------

struct OpBegin {
    bool ok = false;
    bool replay = false;
    json stored_result;
    std::string error;
    ErrorKind kind = ErrorKind::Other;
};

OpBegin begin_op(db::Conn& conn, const std::string& op_id, const std::string& kind) {
    OpBegin out;
    db::Result ins = conn.exec(
        "INSERT INTO operations (op_id, kind) VALUES ($1,$2) ON CONFLICT (op_id) DO NOTHING",
        {op_id, kind});
    if (!ins.ok) {
        out.error = ins.error;
        out.kind = ins.kind;
        return out;
    }
    if (ins.affected == 0) {
        // Replay: the op already ran; return its recorded result unchanged.
        // An op_id reused for a DIFFERENT kind is a caller bug - refuse loudly
        // rather than replaying the wrong operation's result.
        db::Result prev = conn.exec("SELECT result::text, kind FROM operations WHERE op_id = $1", {op_id});
        if (!prev.ok || prev.rows.empty()) {
            out.error = "operation ledger lookup failed";
            out.kind = prev.kind;
            return out;
        }
        if (prev.rows[0][1].second.value_or("") != kind) {
            out.error = "op_id was used for a different operation kind";
            out.kind = ErrorKind::Constraint;
            return out;
        }
        if (!prev.rows[0][0].second.has_value()) {
            // A ledger row without a result means the original op never
            // finished; do NOT replay an empty result as success.
            out.error = "operation ledger entry has no recorded result";
            out.kind = ErrorKind::Other;
            return out;
        }
        out.ok = true;
        out.replay = true;
        out.stored_result = json::parse(*prev.rows[0][0].second);
        return out;
    }
    out.ok = true;
    return out;
}

bool finish_op(db::Conn& conn, const std::string& op_id, const json& result) {
    db::Result r = conn.exec("UPDATE operations SET result = $2::jsonb WHERE op_id = $1",
                             {op_id, result.dump()});
    return r.ok;
}

// --- handlers ----------------------------------------------------------------

void handle_register(const httplib::Request& req, httplib::Response& res, const Config& cfg,
                     db::Pool& pool) {
    auto body = parse_body(req, res);
    if (!body) return;
    const std::string username = body->value("username", "");
    const std::string password = body->value("password", "");
    const auto user_check = auth::check_username_policy(username);
    if (!user_check.ok) return send_error(res, 400, user_check.message);
    const auto pass_check = auth::check_password_policy(password);
    if (!pass_check.ok) return send_error(res, 400, pass_check.message);

    const std::string phc = auth::hash_password(password, cfg);
    if (phc.empty()) return send_error(res, 500, "Password hashing failed.");

    auto lease = pool.acquire();
    db::Result r = lease.exec(
        "INSERT INTO accounts (username, password_hash) VALUES ($1,$2) RETURNING id::text",
        {username, phc});
    if (!r.ok) {
        if (r.kind == ErrorKind::Constraint) return send_error(res, 409, "Username already exists.");
        return send_db_error(res, r, "register");
    }
    send_json(res, 200, {{"success", true}, {"message", "Account created."},
                         {"account_id", std::stoll(r.rows[0][0].second.value_or("0"))}});
}

void handle_login(const httplib::Request& req, httplib::Response& res, const Config& cfg,
                  db::Pool& pool) {
    auto body = parse_body(req, res);
    if (!body) return;
    const std::string username = body->value("username", "");
    const std::string password = body->value("password", "");

    auto lease = pool.acquire();
    db::Result r = lease.exec(
        "SELECT id::text, password_hash FROM accounts WHERE lower(username) = lower($1)", {username});
    if (!r.ok) return send_db_error(res, r, "login");
    if (r.rows.empty() || !auth::verify_password(password, r.rows[0][1].second.value_or(""))) {
        return send_error(res, 401, "Invalid username or password.");
    }
    const long long account_id = std::stoll(r.rows[0][0].second.value_or("0"));
    const std::string token = db::gen_hex(24);
    const std::string token_hash = db::sha256_hex(token);

    // Duplicate-login policy: keep at most N active sessions per account.
    std::vector<std::string> stmts = {
        "UPDATE accounts SET last_login = now() WHERE id = " + std::to_string(account_id),
        "UPDATE sessions SET revoked_at = now() WHERE account_id = " + std::to_string(account_id) +
            " AND revoked_at IS NULL AND id IN (SELECT id FROM sessions WHERE account_id = " +
            std::to_string(account_id) + " AND revoked_at IS NULL ORDER BY created_at DESC OFFSET " +
            std::to_string(cfg.max_sessions_per_account - 1) + ")",
        "INSERT INTO sessions (account_id, token_hash, expires_at) VALUES (" +
            std::to_string(account_id) + ", '" + token_hash + "', now() + interval '" +
            std::to_string(cfg.session_ttl_hours) + " hours')",
    };
    db::Result tx = lease.exec_tx(stmts);
    if (!tx.ok) return send_db_error(res, tx, "login session");
    send_json(res, 200, {{"success", true}, {"message", "Login successful."},
                         {"account_id", account_id}, {"username", username},
                         {"token", token},
                         {"expires_in_seconds", cfg.session_ttl_hours * 3600}});
}

void handle_logout(const httplib::Request& req, httplib::Response& res, db::Pool& pool) {
    const std::string token = bearer_token(req);
    if (token.empty()) return send_error(res, 401, "Missing session token.");
    auto lease = pool.acquire();
    db::Result r = lease.exec(
        "UPDATE sessions SET revoked_at = now() WHERE token_hash = $1 AND revoked_at IS NULL",
        {db::sha256_hex(token)});
    if (!r.ok) return send_db_error(res, r, "logout");
    send_json(res, 200, {{"success", true}, {"message", "Logged out."}});
}

// Service-token only: map a session token to its account and bound character
// (world-server lookup). The token itself and its hash are never
// returned; unknown, expired, and revoked tokens are indistinguishable.
void handle_session_introspect(const httplib::Request& req, httplib::Response& res, const Config& cfg,
                               db::Pool& pool) {
    if (!require_service_token(req, res, cfg)) return;
    auto body = parse_body(req, res);
    if (!body) return;
    if (!body->contains("token") || !(*body)["token"].is_string()) {
        return send_error(res, 400, "Missing token.");
    }
    const std::string token = (*body)["token"].get<std::string>();
    if (token.empty() || token.size() > 512) return send_error(res, 400, "Invalid token.");
    auto lease = pool.acquire();
    db::Result r = lease.exec(
        "SELECT s.account_id::text, a.username, COALESCE(s.character_id, 0)::text, "
        "GREATEST(0, CEIL(EXTRACT(EPOCH FROM (s.expires_at - now()))))::bigint::text "
        "FROM sessions s JOIN accounts a ON a.id = s.account_id "
        "WHERE s.token_hash = $1 AND s.revoked_at IS NULL AND s.expires_at > now()",
        {db::sha256_hex(token)});
    if (!r.ok) return send_db_error(res, r, "session introspect");
    if (r.rows.empty()) return send_error(res, 404, "Session not found.");
    send_json(res, 200, {{"success", true},
                         {"account_id", std::stoll(r.rows[0][0].second.value_or("0"))},
                         {"username", r.rows[0][1].second.value_or("")},
                         {"character_id", std::stoll(r.rows[0][2].second.value_or("0"))},
                         {"expires_in_seconds", std::stoll(r.rows[0][3].second.value_or("0"))}});
}

void handle_game_ticket(const httplib::Request& req, httplib::Response& res, const Config& cfg,
                        db::Pool& pool) {
    auto session = require_session(req, res, pool);
    if (!session) return;
    auto body = parse_body(req, res);
    if (!body) return;
    std::optional<long long> character_id;
    if (body->contains("character_id")) {
        if (!(*body)["character_id"].is_number_integer()) {
            return send_error(res, 400, "Invalid character_id.");
        }
        character_id = (*body)["character_id"].get<long long>();
    }
    auto lease = pool.acquire();
    if (character_id) {
        auto owns = owns_character(*lease.conn(), session->account_id, *character_id);
        if (!owns) return send_error(res, 503, "Service unavailable: database unreachable.");
        if (!*owns) return send_error(res, 404, "Character not found.");
    }
    const std::string ticket = db::gen_hex(32);
    db::Result r = lease.exec(
        "INSERT INTO game_tickets (ticket_hash, account_id, character_id, expires_at) VALUES "
        "($1,$2,$3, now() + interval '" + std::to_string(cfg.ticket_ttl_seconds) + " seconds')",
        {db::sha256_hex(ticket), std::to_string(session->account_id),
         character_id ? std::optional<std::string>(std::to_string(*character_id)) : std::nullopt});
    if (!r.ok) return send_db_error(res, r, "ticket issue");
    send_json(res, 200, {{"success", true}, {"ticket", ticket},
                         {"expires_in_seconds", cfg.ticket_ttl_seconds}});
}

void handle_ticket_redeem(const httplib::Request& req, httplib::Response& res, const Config& cfg,
                          db::Pool& pool) {
    auto body = parse_body(req, res);
    if (!body) return;
    const std::string ticket = body->value("ticket", "");
    if (ticket.empty()) return send_error(res, 400, "Missing ticket.");
    auto lease = pool.acquire();
    // Claim + session issue are one transaction: a failure after the claim
    // must not burn the one-time ticket.
    if (!lease.begin()) return send_error(res, 503, "Service unavailable: database unreachable.");
    db::Result claim = lease.exec(
        "UPDATE game_tickets SET used_at = now() WHERE ticket_hash = $1 AND used_at IS NULL "
        "AND expires_at > now() RETURNING account_id::text, COALESCE(character_id, 0)::text",
        {db::sha256_hex(ticket)});
    if (!claim.ok) {
        lease.rollback();
        return send_db_error(res, claim, "ticket redeem");
    }
    if (claim.rows.empty()) {
        lease.rollback();
        return send_error(res, 410, "Ticket invalid, expired, or already used.");
    }
    const long long account_id = std::stoll(claim.rows[0][0].second.value_or("0"));
    const long long character_id = std::stoll(claim.rows[0][1].second.value_or("0"));
    const std::string token = db::gen_hex(24);
    // A ticket that carried a character binds the issued session to it, so the
    // world server can resolve the token back to the character it may act on.
    // Unbound tickets (and plain logins) leave character_id NULL.
    db::Result ins = lease.exec(
        "INSERT INTO sessions (account_id, token_hash, character_id, expires_at) VALUES "
        "($1,$2,$3, now() + interval '" + std::to_string(cfg.session_ttl_hours) + " hours')",
        {std::to_string(account_id), db::sha256_hex(token),
         character_id != 0 ? std::optional<std::string>(std::to_string(character_id)) : std::nullopt});
    if (!ins.ok) {
        lease.rollback();
        return send_db_error(res, ins, "ticket session");
    }
    db::Result commit;
    if (!lease.commit_checked(commit)) {
        return send_error(res, 503, "Service unavailable: database unreachable (ticket not consumed).");
    }
    send_json(res, 200, {{"success", true}, {"token", token}, {"account_id", account_id},
                         {"character_id", character_id},
                         {"expires_in_seconds", cfg.session_ttl_hours * 3600}});
}

void handle_character_create(const httplib::Request& req, httplib::Response& res, db::Pool& pool) {
    auto session = require_session(req, res, pool);
    if (!session) return;
    auto body = parse_body(req, res);
    if (!body) return;
    const std::string name = body->value("name", "");
    const std::string house = body->value("house", "Gryffindor");
    if (name.size() < 2 || name.size() > 20) return send_error(res, 400, "Name must be 2-20 characters.");
    static const char* houses[] = {"Gryffindor", "Slytherin", "Ravenclaw", "Hufflepuff"};
    if (std::find_if(std::begin(houses), std::end(houses),
                     [&](const char* h) { return house == h; }) == std::end(houses)) {
        return send_error(res, 400, "Unknown house.");
    }
    auto lease = pool.acquire();
    db::Result count = lease.exec("SELECT COUNT(*)::text FROM characters WHERE account_id = $1",
                                   {std::to_string(session->account_id)});
    if (!count.ok) return send_db_error(res, count, "character count");
    if (std::stoi(count.rows[0][0].second.value_or("0")) >= 2) {
        return send_error(res, 400, "Maximum 2 characters per account.");
    }
    if (!lease.begin()) return send_error(res, 503, "Service unavailable: database unreachable.");
    const char* starter = R"([{"id":"wand_hawthorn","amount":1,"tier":0},)"
                          R"({"id":"robe_apprentice","amount":1,"tier":0},)"
                          R"({"id":"broom_nimbus2000","amount":1,"tier":0},)"
                          R"({"id":"mat_phoenix_ash","amount":5,"tier":0},)"
                          R"({"id":"mat_dragon_heartstring","amount":2,"tier":0},)"
                          R"({"id":"potion_health","amount":5,"tier":0},)"
                          R"({"id":"potion_mana","amount":5,"tier":0}])";
    db::Result ins = lease.exec(
        "INSERT INTO characters (account_id, name, house) VALUES ($1,$2,$3) RETURNING id::text",
        {std::to_string(session->account_id), name, house});
    if (!ins.ok) {
        lease.rollback();
        if (ins.kind == ErrorKind::Constraint) return send_error(res, 409, "Character name already taken.");
        return send_db_error(res, ins, "character create");
    }
    const long long char_id = std::stoll(ins.rows[0][0].second.value_or("0"));
    // Seed starter items as normalized ownership rows.
    db::Result seed = lease.exec(
        "INSERT INTO character_items (character_id, item_id, amount, tier) "
        "SELECT $1, x.id, x.amount, x.tier FROM jsonb_to_recordset($2::jsonb) "
        "AS x(id text, amount integer, tier integer)",
        {std::to_string(char_id), starter});
    if (!seed.ok) { lease.rollback(); return send_db_error(res, seed, "starter inventory"); }
    auto gear = lease.exec("SELECT initialize_character_equipment($1)", {std::to_string(char_id)});
    if (!gear.ok) { lease.rollback(); return send_db_error(res, gear, "starter equipment"); }
    db::Result starter_commit;
    if (!lease.commit_checked(starter_commit)) return send_error(res, 503, "Service unavailable: starter transaction failed.");
    send_json(res, 200, {{"success", true}, {"message", "Character created."},
                         {"character", {{"id", char_id}, {"name", name}, {"house", house}}}});
}

json character_snapshot(db::Conn& conn, const db::Row& row, bool include_items) {
    auto get = [&](size_t i) { return row[i].second.value_or(""); };
    json c = {
        {"id", std::stoll(get(0))}, {"name", get(1)}, {"house", get(2)},
        {"level", std::stoi(get(3))}, {"exp", std::stoll(get(4))},
        {"max_hp", std::stoi(get(5))}, {"current_hp", std::stoi(get(6))},
        {"max_mana", std::stoi(get(7))}, {"current_mana", std::stoi(get(8))},
        {"galleons", std::stoll(get(9))}, {"wand_tier", std::stoi(get(10))},
        {"revision", std::stoll(get(11))},
        {"pos", {std::stod(get(12)), std::stod(get(13)), std::stod(get(14))}},
        {"rot_y", std::stod(get(15))},
        {"map_id", get(16)},
        {"quests", json::parse(get(17).empty() ? "{}" : get(17))},
    };
    if (include_items) {
        db::Result items = conn.exec(
            "SELECT item_id, SUM(amount)::text, tier::text FROM character_items "
            "WHERE character_id = $1 GROUP BY item_id, tier ORDER BY item_id, tier",
            {get(0)});
        if (!items.ok) return nullptr;
        c["inventory"] = items_from_rows(items.rows);
    }
    // The owning account. The world server carries the service token, so it
    // receives this field and uses it to prove a character belongs to the
    // session's account before it binds the session to that character
    // (the character-bind fix). It is the same fact `owns_character` checks.
    const std::string account = get(18);
    c["account_id"] = account.empty() ? 0 : std::stoll(account);
    c["base_max_hp"] = std::stoi(get(19));
    c["base_max_mana"] = std::stoi(get(20));
    c["equipment_version"] = std::stoi(get(21));
    c["inventory_revision"] = std::stoll(get(22));
    c["equipment"] = json::object();
    auto gear = conn.exec("SELECT slot,item_id,tier::text FROM character_equipment WHERE character_id=$1 ORDER BY slot", {get(0)});
    if (!gear.ok) return nullptr;
    for (const auto& e : gear.rows) {
        c["equipment"][e[0].second.value_or("")] = {{"id", e[1].second.value_or("")}, {"tier", std::stoi(e[2].second.value_or("0"))}};
    }
    return c;
}

constexpr const char* kCharacterCols =
    "id::text, name, house, level::text, exp::text, max_hp::text, current_hp::text, "
    "max_mana::text, current_mana::text, galleons::text, wand_tier::text, revision::text, "
    "pos_x::text, pos_y::text, pos_z::text, rot_y::text, map_id, quests::text, account_id::text, base_max_hp::text, base_max_mana::text, equipment_version::text, inventory_revision::text";

void handle_character_list(const httplib::Request& req, httplib::Response& res, db::Pool& pool) {
    auto session = require_session(req, res, pool);
    if (!session) return;
    auto lease = pool.acquire();
    db::Result r = lease.exec(
        std::string("SELECT ") + kCharacterCols + " FROM characters WHERE account_id = $1 ORDER BY id",
        {std::to_string(session->account_id)});
    if (!r.ok) return send_db_error(res, r, "character list");
    json list = json::array();
    for (const auto& row : r.rows) {
        auto snapshot = character_snapshot(*lease.conn(), row, false);
        if (snapshot.is_null()) return send_error(res,503,"Character snapshot unavailable.");
        list.push_back(snapshot);
    }
    send_json(res, 200, {{"success", true}, {"characters", list}});
}

void handle_character_load(const httplib::Request& req, httplib::Response& res, const Config& cfg,
                           db::Pool& pool) {
    auto auth = require_session_or_service(req, res, cfg, pool);
    if (!auth) return;
    auto body = parse_body(req, res);
    if (!body) return;
    if (!body->contains("character_id") || !(*body)["character_id"].is_number_integer()) {
        return send_error(res, 400, "Missing character_id.");
    }
    const long long char_id = (*body)["character_id"].get<long long>();
    auto lease = pool.acquire();
    std::vector<std::optional<std::string>> params = {std::to_string(char_id)};
    std::string scope;
    if (!auth->service) {
        scope = " AND account_id = $2";  // a session stays scoped to its own account
        params.push_back(std::to_string(auth->account_id));
    }
    // Save/trade/reward writers lock this same row. Hold a shared lock until
    // all ownership rows have been read, so a load cannot mix two revisions.
    if (!lease.begin()) return send_error(res,503,"Character snapshot unavailable.");
    db::Result r = lease.exec(
        std::string("SELECT ") + kCharacterCols + " FROM characters WHERE id = $1" + scope + " FOR SHARE", params);
    if (!r.ok) { lease.rollback(); return send_db_error(res, r, "character load"); }
    if (r.rows.empty()) { lease.rollback(); return send_error(res, 404, "Character not found."); }
    auto snapshot = character_snapshot(*lease.conn(), r.rows[0], true);
    if (snapshot.is_null()) { lease.rollback(); return send_error(res,503,"Character snapshot unavailable."); }
    db::Result committed;
    if (!lease.commit_checked(committed)) return send_error(res,503,"Character snapshot unavailable.");
    send_json(res, 200, {{"success", true}, {"character", snapshot}});
}

void handle_character_save(const httplib::Request& req, httplib::Response& res, const Config& cfg,
                           db::Pool& pool) {
    auto auth = require_session_or_service(req, res, cfg, pool);
    if (!auth) return;
    auto body = parse_body(req, res);
    if (!body) return;
    if (!body->contains("character_id") || !(*body)["character_id"].is_number_integer()) {
        return send_error(res, 400, "Missing character_id.");
    }
    const long long char_id = (*body)["character_id"].get<long long>();

    // The world is the only writer of progression and item ownership.
    if (!auth->service) return send_error(res, 403, "Character saves require the world server.");
    json equipment;
    if (body->contains("equipment")) {
        equipment = (*body)["equipment"];
        if (!equipment.is_object() || equipment.size() > 10 || !body->contains("inventory"))
            return send_error(res,400,"Equipment requires an atomic inventory snapshot.");
        const std::set<std::string> slots = {"head","chest","hands","feet","main_hand","off_hand","neck","ring_left","ring_right","broom"};
        for (auto it=equipment.begin(); it!=equipment.end(); ++it) {
            if (!slots.count(it.key()) || !it.value().is_object()) return send_error(res,400,"Invalid equipment slot.");
            json line=it.value(); line["amount"]=1;
            if (!parse_item(line)) return send_error(res,400,"Invalid equipped item.");
        }
    }
    for (const auto* key : {"base_max_hp", "base_max_mana", "inventory_revision", "equipment_version"}) {
        if (body->contains(key) && (!(*body)[key].is_number_integer() || (*body)[key].get<long long>() < 0 || (*body)[key].get<long long>() > 2000000000))
            return send_error(res,400,"Invalid equipment state.");
    }
    for (const auto* key : {"base_max_hp", "base_max_mana"}) {
        if (body->contains(key) && ((*body)[key].get<long long>() < 1 || (*body)[key].get<long long>() > 1000000))
            return send_error(res,400,"Invalid base resource maximum.");
    }
    // Numeric state with bounds (server-side validation; rejects garbage).
    auto int_field = [&](const char* key, long long def, long long lo, long long hi,
                         std::optional<long long>& out) -> bool {
        if (!body->contains(key)) {
            out = def;
            return true;
        }
        if (!(*body)[key].is_number_integer()) return false;
        const long long v = (*body)[key].get<long long>();
        if (v < lo || v > hi) return false;
        out = v;
        return true;
    };
    std::optional<long long> level, exp, max_hp, current_hp, max_mana, current_mana, galleons,
        wand_tier, base_revision;
    // Absent fields -> kAbsent; they are resolved to the CURRENT stored values
    // after the row lock below: a partial save must never zero progress.
    if (!int_field("level", kAbsent, 1, 100, level) || !int_field("exp", kAbsent, 0, 2'000'000'000, exp) ||
        !int_field("max_hp", kAbsent, 1, 1'000'000, max_hp) || !int_field("current_hp", kAbsent, 0, 1'000'000, current_hp) ||
        !int_field("max_mana", kAbsent, 1, 1'000'000, max_mana) || !int_field("current_mana", kAbsent, 0, 1'000'000, current_mana) ||
        !int_field("galleons", kAbsent, 0, kMaxGalleons, galleons) || !int_field("wand_tier", kAbsent, 0, 9, wand_tier)) {
        return send_error(res, 400, "Invalid numeric field.");
    }
    if (!int_field("base_revision", kAbsent, -1, 1'000'000'000, base_revision)) {
        return send_error(res, 400, "Invalid base_revision.");
    }
    std::optional<double> pos_x, pos_y, pos_z, rot_y;
    if (body->contains("pos")) {
        if (!(*body)["pos"].is_array() || (*body)["pos"].size() != 3) return send_error(res, 400, "Invalid pos.");
        for (int i = 0; i < 3; ++i) {
            if (!(*body)["pos"][i].is_number()) return send_error(res, 400, "Invalid pos.");
        }
        pos_x = (*body)["pos"][0].get<double>();
        pos_y = (*body)["pos"][1].get<double>();
        pos_z = (*body)["pos"][2].get<double>();
    }
    if (body->contains("rot_y")) {
        if (!(*body)["rot_y"].is_number()) return send_error(res, 400, "Invalid rot_y.");
        rot_y = (*body)["rot_y"].get<double>();
    }
    if (body->contains("map_id") && !(*body)["map_id"].is_string()) return send_error(res, 400, "Invalid map_id.");

    // Inventory: optional full-state replacement (validated); when absent the
    // normalized rows remain authoritative (trades/rewards mutate them).
    std::vector<ItemLine> inventory;
    bool replace_inventory = false;
    if (body->contains("inventory")) {
        if (!(*body)["inventory"].is_array() || (*body)["inventory"].size() > kMaxInventoryKinds * 2) {
            return send_error(res, 400, "Invalid inventory.");
        }
        for (const auto& entry : (*body)["inventory"]) {
            if (entry.is_object() && entry.contains("id") && entry.contains("amount") &&
                entry["id"].is_string() && entry["amount"].is_number_integer() &&
                entry["amount"].get<long long>() <= 0) {
                continue;  // tolerate zero/negative leftovers the way the client sanitizer does
            }
            auto line = parse_item(entry);
            if (!line) return send_error(res, 400, "Invalid inventory entry.");
            inventory.push_back(*line);
        }
        if (inventory.empty() && !(*body)["inventory"].empty()) {
            return send_error(res, 400, "Invalid inventory entries.");
        }
        // Enforce the same 40-kind capacity the trade path enforces: otherwise
        // a full-state save could bypass it entirely.
        std::set<std::string> kinds;
        for (const auto& line : inventory) kinds.insert(line.item_id);
        if (static_cast<int>(kinds.size()) > kMaxInventoryKinds) {
            return send_error(res, 400, "Inventory exceeds the item-kind capacity.");
        }
        replace_inventory = true;
    }
    json quests = json::object();
    bool has_quests = false;
    if (body->contains("quests")) {
        if (!(*body)["quests"].is_object()) return send_error(res, 400, "Invalid quests.");
        quests = (*body)["quests"];
        if (quests.dump().size() > 65536) return send_error(res, 400, "Quests payload too large.");
        has_quests = true;
    }

    auto lease = pool.acquire();
    if (!lease.begin()) return send_error(res, 503, "Service unavailable: database unreachable.");

    std::vector<std::optional<std::string>> lock_params = {std::to_string(char_id)};
    std::string lock_scope;
    if (!auth->service) {
        lock_scope = " AND account_id=$2";  // a session stays scoped to its own account
        lock_params.push_back(std::to_string(auth->account_id));
    }
    db::Result cur = lease.exec(
        "SELECT revision::text, level::text, exp::text, max_hp::text, current_hp::text, max_mana::text, "
        "current_mana::text, galleons::text, wand_tier::text, pos_x::text, pos_y::text, pos_z::text, "
        "rot_y::text, map_id, quests::text FROM characters WHERE id=$1" + lock_scope + " FOR UPDATE",
        lock_params);
    if (!cur.ok) {
        lease.rollback();
        return send_db_error(res, cur, "character save");
    }
    if (cur.rows.empty()) {
        lease.rollback();
        return send_error(res, 404, "Character not found.");
    }
    auto cur_i = [&](size_t i) { return std::stoll(cur.rows[0][i].second.value_or("0")); };
    auto cur_d = [&](size_t i) { return std::stod(cur.rows[0][i].second.value_or("0")); };
    const long long revision = cur_i(0);
    if (base_revision && *base_revision >= 0 && *base_revision != revision) {
        lease.rollback();
        send_json(res, 409, {{"success", false}, {"message", "Stale revision."}, {"revision", revision}});
        return;
    }
    const long long r_level = (*level != kAbsent) ? *level : cur_i(1);
    const long long r_exp = (*exp != kAbsent) ? *exp : cur_i(2);
    const long long r_max_hp = (*max_hp != kAbsent) ? *max_hp : cur_i(3);
    const long long r_cur_hp = (*current_hp != kAbsent) ? *current_hp : cur_i(4);
    const long long r_max_mana = (*max_mana != kAbsent) ? *max_mana : cur_i(5);
    const long long r_cur_mana = (*current_mana != kAbsent) ? *current_mana : cur_i(6);
    const long long r_galleons = (*galleons != kAbsent) ? *galleons : cur_i(7);
    const long long r_wand_tier = (*wand_tier != kAbsent) ? *wand_tier : cur_i(8);
    const double r_px = pos_x ? *pos_x : cur_d(9);
    const double r_py = pos_y ? *pos_y : cur_d(10);
    const double r_pz = pos_z ? *pos_z : cur_d(11);
    const double r_rot = rot_y ? *rot_y : cur_d(12);
    const std::string r_map = body->contains("map_id") ? body->value("map_id", "grounds")
                                                       : cur.rows[0][13].second.value_or("grounds");
    const std::string r_quests = has_quests ? quests.dump() : cur.rows[0][14].second.value_or("{}");

    // All values are bound parameters - never concatenated (injection-safe).
    db::Result upd = lease.exec(
        "UPDATE characters SET level=$2, exp=$3, max_hp=$4, current_hp=$5, max_mana=$6, "
        "current_mana=$7, galleons=$8, wand_tier=$9, pos_x=$10, pos_y=$11, pos_z=$12, rot_y=$13, "
        "map_id=$14, quests=$15::jsonb, revision=revision+1, updated_at=now() WHERE id=$1",
        {std::to_string(char_id), std::to_string(r_level), std::to_string(r_exp),
         std::to_string(r_max_hp), std::to_string(r_cur_hp), std::to_string(r_max_mana),
         std::to_string(r_cur_mana), std::to_string(r_galleons), std::to_string(r_wand_tier),
         std::to_string(r_px), std::to_string(r_py), std::to_string(r_pz),
         std::to_string(r_rot), r_map, r_quests});
    if (!upd.ok) {
        lease.rollback();
        return send_db_error(res, upd, "character save");
    }
    if (replace_inventory) {
        db::Result del = lease.exec("DELETE FROM character_items WHERE character_id=$1",
                                     {std::to_string(char_id)});
        if (!del.ok) {
            lease.rollback();
            return send_db_error(res, del, "inventory replace");
        }
        for (const auto& line : inventory) {
            db::Result ins = lease.exec(
                "INSERT INTO character_items (character_id,item_id,amount,tier) VALUES ($1,$2,$3,$4)",
                {std::to_string(char_id), line.item_id, std::to_string(line.amount),
                 std::to_string(line.tier)});
            if (!ins.ok) {
                lease.rollback();
                return send_db_error(res, ins, "inventory replace");
            }
        }
    }
    if (!equipment.is_null()) {
        auto del = lease.exec("DELETE FROM character_equipment WHERE character_id=$1", {std::to_string(char_id)});
        if (!del.ok) { lease.rollback(); return send_db_error(res,del,"equipment replace"); }
        for (auto it=equipment.begin(); it!=equipment.end(); ++it) {
            auto ins = lease.exec("INSERT INTO character_equipment(character_id,slot,item_id,tier) VALUES($1,$2,$3,$4)",
                {std::to_string(char_id),it.key(),it.value()["id"].get<std::string>(),std::to_string(it.value().value("tier",0))});
            if (!ins.ok) { lease.rollback(); return send_db_error(res,ins,"equipment replace"); }
        }
    }
    for (const auto* key : {"base_max_hp", "base_max_mana", "inventory_revision", "equipment_version"}) {
        if (!body->contains(key)) continue;
        // key is selected only from the fixed list above.
        auto upd_gear = lease.exec(std::string("UPDATE characters SET ")+key+"=$2 WHERE id=$1",
            {std::to_string(char_id),std::to_string((*body)[key].get<long long>())});
        if (!upd_gear.ok) { lease.rollback(); return send_db_error(res,upd_gear,"equipment state"); }
    }
    db::Result commit_res;
    if (!lease.commit_checked(commit_res)) {
        if (commit_res.kind == ErrorKind::Connection) {
            return send_error(res, 503, "Service unavailable: database unreachable (save may not have applied).");
        }
        send_error(res, 500, "Save commit failed.");
        std::printf("[error] save commit: %s\n", commit_res.error.c_str());
        return;
    }
    send_json(res, 200, {{"success", true}, {"message", "Saved."}, {"revision", revision + 1}});
}

void handle_reward(const httplib::Request& req, httplib::Response& res, const Config& cfg,
                   db::Pool& pool) {
    if (!require_service_token(req, res, cfg)) return;
    auto body = parse_body(req, res);
    if (!body) return;
    const std::string op_id = body->value("op_id", "");
    if (op_id.empty() || op_id.size() > 64) return send_error(res, 400, "Invalid op_id.");
    if (!body->contains("character_id") || !(*body)["character_id"].is_number_integer()) {
        return send_error(res, 400, "Missing character_id.");
    }
    const long long char_id = (*body)["character_id"].get<long long>();
    long long exp_grant = 0, gold_grant = 0;
    if (body->contains("exp")) {
        if (!(*body)["exp"].is_number_integer()) return send_error(res, 400, "Invalid exp.");
        exp_grant = (*body)["exp"].get<long long>();
    }
    if (body->contains("galleons")) {
        if (!(*body)["galleons"].is_number_integer()) return send_error(res, 400, "Invalid galleons.");
        gold_grant = (*body)["galleons"].get<long long>();
    }
    if (exp_grant < 0 || gold_grant < 0 || exp_grant > 10'000'000 || gold_grant > kMaxGalleons) {
        return send_error(res, 400, "Grant out of range.");
    }
    std::vector<ItemLine> items;
    if (body->contains("items")) {
        if (!(*body)["items"].is_array() || (*body)["items"].size() > 20) {
            return send_error(res, 400, "Invalid items.");
        }
        for (const auto& entry : (*body)["items"]) {
            auto line = parse_item(entry);
            if (!line) return send_error(res, 400, "Invalid item entry.");
            items.push_back(*line);
        }
    }

    auto lease = pool.acquire();
    if (!lease.begin()) return send_error(res, 503, "Service unavailable: database unreachable.");
    OpBegin op = begin_op(*lease.conn(), op_id, "reward");
    if (!op.ok) {
        lease.rollback();
        return send_db_error(res, db::Result{false, op.kind, op.error, {}}, "reward");
    }
    if (op.replay) {
        lease.rollback();
        send_json(res, 200, {{"success", true}, {"replayed", true}, {"result", op.stored_result}});
        return;
    }
    db::Result upd = lease.exec(
        "UPDATE characters SET exp = exp + $2, galleons = LEAST(galleons + $3, $4), revision = revision + 1, "
        "updated_at = now() WHERE id = $1 RETURNING revision::text",
        {std::to_string(char_id), std::to_string(exp_grant), std::to_string(gold_grant),
         std::to_string(kMaxGalleons)});
    if (!upd.ok || upd.rows.empty()) {
        lease.rollback();
        if (upd.ok) return send_error(res, 404, "Character not found.");
        return send_db_error(res, upd, "reward");
    }
    std::string err;
    if (!grant_items(*lease.conn(), char_id, items, err)) {
        lease.rollback();
        return send_error(res, 409, "Reward failed: " + err);
    }
    const json result = {{"character_id", char_id}, {"exp", exp_grant}, {"galleons", gold_grant},
                         {"items", items.size()}};
    if (!finish_op(*lease.conn(), op_id, result)) {
        lease.rollback();
        return send_error(res, 500, "Reward ledger write failed.");
    }
    db::Result commit;
    if (!lease.commit_checked(commit)) {
        if (commit.kind == ErrorKind::Connection) {
            send_json(res, 503, {{"success", false}, {"status", "uncertain"},
                                 {"op_id", op_id}, {"message", "Commit result unknown; retry with the same op_id."}});
        } else {
            send_error(res, 500, "Reward commit failed.");
        }
        return;
    }
    send_json(res, 200, {{"success", true}, {"result", result}});
}

void handle_trade(const httplib::Request& req, httplib::Response& res, const Config& cfg,
                  db::Pool& pool) {
    if (!require_service_token(req, res, cfg)) return;
    auto body = parse_body(req, res);
    if (!body) return;
    const std::string op_id = body->value("op_id", "");
    if (op_id.empty() || op_id.size() > 64) return send_error(res, 400, "Invalid op_id.");
    if (!body->contains("from_id") || !body->contains("to_id") ||
        !(*body)["from_id"].is_number_integer() || !(*body)["to_id"].is_number_integer()) {
        return send_error(res, 400, "Missing from_id/to_id.");
    }
    const long long from_id = (*body)["from_id"].get<long long>();
    const long long to_id = (*body)["to_id"].get<long long>();
    if (from_id == to_id) return send_error(res, 400, "Self-trade is not allowed.");
    auto parse_offer = [&](const char* key, long long& gold, std::vector<ItemLine>& items) -> bool {
        if (!body->contains(key) || !(*body)[key].is_object()) return false;
        const json& offer = (*body)[key];
        if (offer.contains("galleons")) {
            if (!offer["galleons"].is_number_integer()) return false;
            gold = offer["galleons"].get<long long>();
            if (gold < 0 || gold > kMaxGalleons) return false;
        }
        if (offer.contains("items")) {
            if (!offer["items"].is_array() || offer["items"].size() > 20) return false;
            for (const auto& entry : offer["items"]) {
                auto line = parse_item(entry);
                if (!line) return false;
                items.push_back(*line);
            }
        }
        return true;
    };
    long long offer_gold = 0, request_gold = 0;
    std::vector<ItemLine> offer_items, request_items;
    if (!parse_offer("offer", offer_gold, offer_items) || !parse_offer("request", request_gold, request_items)) {
        return send_error(res, 400, "Invalid offer/request.");
    }

    auto lease = pool.acquire();
    if (!lease.begin()) return send_error(res, 503, "Service unavailable: database unreachable.");
    OpBegin op = begin_op(*lease.conn(), op_id, "trade");
    if (!op.ok) {
        lease.rollback();
        return send_db_error(res, db::Result{false, op.kind, op.error, {}}, "trade");
    }
    if (op.replay) {
        lease.rollback();
        send_json(res, 200, {{"success", true}, {"replayed", true}, {"result", op.stored_result}});
        return;
    }
    // Consistent lock order: lock the lower character id first.
    const long long lo = (std::min)(from_id, to_id);
    const long long hi = (std::max)(from_id, to_id);
    db::Result lock_lo = lease.exec("SELECT id::text, galleons::text FROM characters WHERE id = $1 FOR UPDATE",
                                     {std::to_string(lo)});
    db::Result lock_hi = lease.exec("SELECT id::text, galleons::text FROM characters WHERE id = $1 FOR UPDATE",
                                     {std::to_string(hi)});
    if (!lock_lo.ok || !lock_hi.ok) {
        lease.rollback();
        return send_error(res, 503, "Service unavailable: database unreachable.");
    }
    if (lock_lo.rows.empty() || lock_hi.rows.empty()) {
        lease.rollback();
        return send_error(res, 404, "Trade participant not found.");
    }
    auto gold_of = [&](long long id) -> long long {
        const db::Rows& rows = (id == lo) ? lock_lo.rows : lock_hi.rows;
        return std::stoll(rows[0][1].second.value_or("0"));
    };
    if (gold_of(from_id) < offer_gold || gold_of(to_id) < request_gold) {
        lease.rollback();
        return send_error(res, 400, "Insufficient galleons.");
    }
    // Destination capacity: distinct item kinds after the swap.
    struct Target {
        long long receiver;
        const std::vector<ItemLine>* incoming;
    };
    const Target targets[2] = {{to_id, &offer_items}, {from_id, &request_items}};
    for (const auto& target : targets) {
        int kinds = distinct_item_kinds(*lease.conn(), target.receiver);
        for (const auto& line : *target.incoming) {
            db::Result exists = lease.exec(
                "SELECT 1 FROM character_items WHERE character_id=$1 AND item_id=$2 LIMIT 1",
                {std::to_string(target.receiver), line.item_id});
            if (exists.ok && exists.rows.empty()) kinds += 1;
        }
        if (kinds > kMaxInventoryKinds) {
            lease.rollback();
            return send_error(res, 400, "Destination inventory is full.");
        }
    }
    std::string err;
    if (!debit_items(*lease.conn(), from_id, offer_items, err)) {
        lease.rollback();
        return send_error(res, 400, "Sender cannot cover the offer: " + err);
    }
    if (!debit_items(*lease.conn(), to_id, request_items, err)) {
        lease.rollback();
        return send_error(res, 400, "Receiver cannot cover the request: " + err);
    }
    if (!grant_items(*lease.conn(), to_id, offer_items, err) || !grant_items(*lease.conn(), from_id, request_items, err)) {
        lease.rollback();
        return send_error(res, 500, "Grant failed: " + err);
    }
    {
        db::Result g1 = lease.exec("UPDATE characters SET galleons = galleons - $2 + $3, revision = revision + 1, "
                                    "updated_at = now() WHERE id = $1",
                                    {std::to_string(from_id), std::to_string(offer_gold), std::to_string(request_gold)});
        db::Result g2 = lease.exec("UPDATE characters SET galleons = galleons - $2 + $3, revision = revision + 1, "
                                    "updated_at = now() WHERE id = $1",
                                    {std::to_string(to_id), std::to_string(request_gold), std::to_string(offer_gold)});
        if (!g1.ok || !g2.ok) {
            lease.rollback();
            return send_error(res, 500, "Galleon swap failed.");
        }
    }
    const json result = {{"from_id", from_id}, {"to_id", to_id}, {"offer_galleons", offer_gold},
                         {"request_galleons", request_gold}, {"items_moved", offer_items.size() + request_items.size()}};
    if (!finish_op(*lease.conn(), op_id, result)) {
        lease.rollback();
        return send_error(res, 500, "Trade ledger write failed.");
    }
    db::Result commit;
    if (!lease.commit_checked(commit)) {
        if (commit.kind == ErrorKind::Connection) {
            send_json(res, 503, {{"success", false}, {"status", "uncertain"},
                                 {"op_id", op_id}, {"message", "Commit result unknown; retry with the same op_id."}});
        } else {
            send_error(res, 500, "Trade commit failed.");
        }
        return;
    }
    send_json(res, 200, {{"success", true}, {"result", result}});
}

void handle_version(const httplib::Request&, httplib::Response& res, const Config& cfg) {
    std::ifstream in("version.json");
    if (in) {
        std::stringstream ss;
        ss << in.rdbuf();
        try {
            send_json(res, 200, json::parse(ss.str()));
            return;
        } catch (...) {
        }
    }
    send_json(res, 200, {{"version", "1.1.0"}, {"game_title", "HPMMO"}, {"protocol", 2}});
}

void handle_health(const httplib::Request&, httplib::Response& res) {
    send_json(res, 200, {{"status", "ok"}, {"service", "hpmmo-service"}, {"time", db::now_iso8601()}});
}

void handle_ready(const httplib::Request&, httplib::Response& res, const Config& cfg, db::Pool& pool) {
    auto lease = pool.acquire();
    if (cfg.database_url.empty()) {
        send_json(res, 503, {{"status", "unavailable"}, {"db", "none"},
                             {"message", "DATABASE_URL is not configured; no fallback backend is used."}});
        return;
    }
    db::MigrationStatus st = db::migration_status(*lease.conn(), cfg.migrations_dir);
    if (!st.db_reachable) {
        send_json(res, 503, {{"status", "unavailable"}, {"db", "postgresql"},
                             {"message", "Database unreachable."}});
        return;
    }
    if (st.applied != st.required) {
        send_json(res, 503, {{"status", "unavailable"}, {"db", "postgresql"},
                             {"schema", st.applied}, {"required", st.required},
                             {"message", st.error.empty() ? "Schema migration required." : st.error}});
        return;
    }
    send_json(res, 200, {{"status", "ready"}, {"db", "postgresql"},
                         {"schema", st.applied}, {"time", db::now_iso8601()}});
}

}  // namespace

int serve(const Config& cfg, db::Pool& pool) {
    httplib::Server svr;
    svr.set_payload_max_length(1024 * 1024);
    svr.set_error_handler([](const httplib::Request&, httplib::Response& res) {
        if (res.body.empty()) {
            res.set_content(json{{"success", false},
                                 {"message", "HTTP " + std::to_string(res.status)}}.dump(),
                            "application/json");
        }
    });
    svr.set_read_timeout(10, 0);
    svr.set_write_timeout(10, 0);

    svr.Get("/api/health", [&](const httplib::Request& req, httplib::Response& res) {
        handle_health(req, res);
    });
    svr.Get("/api/ready", [&](const httplib::Request& req, httplib::Response& res) {
        handle_ready(req, res, cfg, pool);
    });
    svr.Get("/api/version", [&](const httplib::Request& req, httplib::Response& res) {
        handle_version(req, res, cfg);
    });
    svr.Post("/api/register", [&](const httplib::Request& req, httplib::Response& res) {
        handle_register(req, res, cfg, pool);
    });
    svr.Post("/api/login", [&](const httplib::Request& req, httplib::Response& res) {
        handle_login(req, res, cfg, pool);
    });
    svr.Post("/api/logout", [&](const httplib::Request& req, httplib::Response& res) {
        handle_logout(req, res, pool);
    });
    svr.Post("/api/session/introspect", [&](const httplib::Request& req, httplib::Response& res) {
        handle_session_introspect(req, res, cfg, pool);
    });
    svr.Post("/api/game-ticket", [&](const httplib::Request& req, httplib::Response& res) {
        handle_game_ticket(req, res, cfg, pool);
    });
    svr.Post("/api/ticket/redeem", [&](const httplib::Request& req, httplib::Response& res) {
        handle_ticket_redeem(req, res, cfg, pool);
    });
    svr.Post("/api/characters/create", [&](const httplib::Request& req, httplib::Response& res) {
        handle_character_create(req, res, pool);
    });
    svr.Post("/api/characters/list", [&](const httplib::Request& req, httplib::Response& res) {
        handle_character_list(req, res, pool);
    });
    svr.Post("/api/characters/load", [&](const httplib::Request& req, httplib::Response& res) {
        handle_character_load(req, res, cfg, pool);
    });
    svr.Post("/api/characters/save", [&](const httplib::Request& req, httplib::Response& res) {
        handle_character_save(req, res, cfg, pool);
    });
    svr.Post("/api/reward", [&](const httplib::Request& req, httplib::Response& res) {
        handle_reward(req, res, cfg, pool);
    });
    svr.Post("/api/trade", [&](const httplib::Request& req, httplib::Response& res) {
        handle_trade(req, res, cfg, pool);
    });

    std::printf("[hpmmo-service] listening on %s:%d (db=%s, private api=%s)\n",
                cfg.bind_addr.c_str(), cfg.http_port,
                cfg.database_url.empty() ? "unconfigured" : "postgresql",
                cfg.service_token.empty() ? "disabled" : "enabled");
    if (!svr.listen(cfg.bind_addr.c_str(), cfg.http_port)) {
        std::fprintf(stderr, "[hpmmo-service] failed to bind %s:%d\n", cfg.bind_addr.c_str(), cfg.http_port);
        return 1;
    }
    return 0;
}

}  // namespace app
