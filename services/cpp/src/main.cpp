// HPMMO C++ service entry point.
// Commands: serve | migrate | dev-reset | selfcheck | version
#include "app.h"
#include "auth.h"
#include "config.h"
#include "db.h"

#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <filesystem>
#include <string>

namespace {

std::string env_or(const char* name, const std::string& fallback) {
    const char* v = std::getenv(name);
    return (v && *v) ? std::string(v) : fallback;
}

long env_int(const char* name, long fallback) {
    const char* v = std::getenv(name);
    if (!v || !*v) return fallback;
    try {
        return std::stol(v);
    } catch (...) {
        return fallback;
    }
}

}  // namespace

Config Config::from_env() {
    Config c;
    c.bind_addr = env_or("HPMMO_BIND", "127.0.0.1");
    c.http_port = static_cast<int>(env_int("HPMMO_HTTP_PORT", 8081));
    c.database_url = env_or("DATABASE_URL", "");
    c.service_token = env_or("HPMMO_SERVICE_TOKEN", "");
    c.session_ttl_hours = static_cast<int>(env_int("HPMMO_SESSION_TTL_HOURS", 24));
    c.ticket_ttl_seconds = static_cast<int>(env_int("HPMMO_TICKET_TTL_SECONDS", 60));
    c.max_sessions_per_account = static_cast<int>(env_int("HPMMO_MAX_SESSIONS", 5));
    c.argon2_m_cost = static_cast<unsigned>(env_int("HPMMO_ARGON2_M", 65536));
    c.argon2_t_cost = static_cast<unsigned>(env_int("HPMMO_ARGON2_T", 3));
    c.argon2_parallelism = static_cast<unsigned>(env_int("HPMMO_ARGON2_P", 1));
    c.migrations_dir = env_or("HPMMO_MIGRATIONS_DIR", "db/migrations");
    if (!std::filesystem::exists(c.migrations_dir)) {
        if (std::filesystem::exists("../../db/migrations")) {
            c.migrations_dir = "../../db/migrations";
        } else if (std::filesystem::exists("../db/migrations")) {
            c.migrations_dir = "../db/migrations";
        }
    }
    c.db_pool_size = static_cast<int>(env_int("HPMMO_DB_POOL", 4));
    c.allow_reset = env_or("HPMMO_ALLOW_RESET", "0") == "1";
    if (c.max_sessions_per_account < 1) c.max_sessions_per_account = 1;  // guard OFFSET arithmetic
    if (c.ticket_ttl_seconds < 1) c.ticket_ttl_seconds = 1;
    return c;
}

namespace {

int cmd_migrate(const Config& cfg) {
    if (cfg.database_url.empty()) {
        std::fprintf(stderr, "DATABASE_URL is not set.\n");
        return 2;
    }
    db::Conn conn(cfg.database_url);
    db::MigrationStatus st = db::migrate(conn, cfg.migrations_dir);
    if (!st.db_reachable) {
        std::fprintf(stderr, "database unavailable: %s\n", st.error.c_str());
        return 1;
    }
    if (st.applied != st.required) {
        std::fprintf(stderr, "migrations incomplete: applied=%d required=%d (%s)\n", st.applied,
                     st.required, st.error.c_str());
        return 1;
    }
    std::printf("schema at version %d\n", st.applied);
    return 0;
}

int cmd_selfcheck(const Config& cfg) {
    std::printf("bind=%s:%d pool=%d migrations=%s reset=%s\n", cfg.bind_addr.c_str(),
                cfg.http_port, cfg.db_pool_size, cfg.migrations_dir.c_str(),
                cfg.allow_reset ? "allowed" : "disabled");
    std::printf("database_url=%s\n", cfg.database_url.empty() ? "(unset)" : "(set)");
    std::printf("service_token=%s\n", cfg.service_token.empty() ? "(unset)" : "(set)");
    if (cfg.database_url.empty()) return 1;
    db::Conn conn(cfg.database_url);
    if (!conn.ensure_ok()) {
        std::printf("database: UNAVAILABLE\n");
        return 1;
    }
    db::MigrationStatus st = db::migration_status(conn, cfg.migrations_dir);
    std::printf("database: reachable; schema applied=%d required=%d\n", st.applied, st.required);
    return (st.applied == st.required) ? 0 : 1;
}

std::string current_database(db::Conn& conn) {
    db::Result r = conn.exec("SELECT current_database()");
    if (!r.ok || r.rows.empty()) return "";
    return r.rows[0][0].second.value_or("");
}

int cmd_dev_reset(const Config& cfg) {
    if (!cfg.allow_reset) {
        std::fprintf(stderr, "REFUSING: set HPMMO_ALLOW_RESET=1 to run a development reset.\n");
        return 2;
    }
    if (cfg.database_url.empty()) {
        std::fprintf(stderr, "DATABASE_URL is not set.\n");
        return 2;
    }
    db::Conn conn(cfg.database_url);
    if (!conn.ensure_ok()) {
        std::fprintf(stderr, "database unavailable - refusing to reset\n");
        return 1;
    }
    const std::string db_name = current_database(conn);
    std::string lowered = db_name;
    for (char& ch : lowered) ch = static_cast<char>(std::tolower(static_cast<unsigned char>(ch)));
    if (lowered.find("dev") == std::string::npos) {
        std::fprintf(stderr, "REFUSING: database '%s' does not look like a development database.\n",
                     db_name.c_str());
        return 2;
    }
    std::printf("development reset of database '%s' at %s\n", db_name.c_str(), db::now_iso8601().c_str());

    std::vector<std::string> stmts = {
        "DROP SCHEMA public CASCADE",
        "CREATE SCHEMA public",
    };
    db::Result wipe = conn.exec_tx(stmts);
    if (!wipe.ok) {
        std::fprintf(stderr, "reset failed: %s\n", wipe.error.c_str());
        return 1;
    }
    db::MigrationStatus st = db::migrate(conn, cfg.migrations_dir);
    if (!st.db_reachable || st.applied != st.required) {
        std::fprintf(stderr, "post-reset migration failed: %s\n", st.error.c_str());
        return 1;
    }
    // Seed the conventional dev account (created through the normal hashing path).
    const std::string phc = auth::hash_password("devpassword1", cfg);
    db::Result acc = conn.exec(
        "INSERT INTO accounts (username, password_hash) VALUES ('dev', $1) RETURNING id::text", {phc});
    if (!acc.ok) {
        std::fprintf(stderr, "seed account failed: %s\n", acc.error.c_str());
        return 1;
    }
    const std::string account_id = acc.rows[0][0].second.value_or("0");
    db::Result chr = conn.exec(
        "INSERT INTO characters (account_id, name, house) VALUES ($1, 'Dev Wizard', 'Gryffindor') "
        "RETURNING id::text",
        {account_id});
    if (!chr.ok) {
        std::fprintf(stderr, "seed character failed: %s\n", chr.error.c_str());
        return 1;
    }
    const std::string char_id = chr.rows[0][0].second.value_or("0");
    const char* starter =
        R"([{"id":"wand_hawthorn","amount":1,"tier":0},{"id":"broom_nimbus2000","amount":1,"tier":0},)"
        R"({"id":"potion_health","amount":5,"tier":0},{"id":"potion_mana","amount":5,"tier":0},)"
        R"({"id":"mat_phoenix_ash","amount":5,"tier":0}])";
    db::Result seed = conn.exec(
        "INSERT INTO character_items (character_id, item_id, amount, tier) "
        "SELECT $1, x.id, x.amount, x.tier FROM jsonb_to_recordset($2::jsonb) "
        "AS x(id text, amount integer, tier integer)",
        {char_id, starter});
    if (!seed.ok) {
        std::fprintf(stderr, "seed inventory failed: %s\n", seed.error.c_str());
        return 1;
    }
    std::printf("reset complete: schema v%d, dev account id=%s, character id=%s (password devpassword1)\n",
                st.applied, account_id.c_str(), char_id.c_str());
    return 0;
}

}  // namespace

int main(int argc, char** argv) {
    const std::string command = argc > 1 ? argv[1] : "serve";
    const Config cfg = Config::from_env();

    if (command == "serve") {
        db::Pool pool(cfg.database_url, cfg.db_pool_size);
        return app::serve(cfg, pool);
    }
    if (command == "migrate") return cmd_migrate(cfg);
    if (command == "selfcheck") return cmd_selfcheck(cfg);
    if (command == "dev-reset") return cmd_dev_reset(cfg);
    if (command == "version") {
        std::printf("hpmmo-service 2.0.0 (persistence)\n");
        return 0;
    }
    std::fprintf(stderr,
                 "usage: hpmmo_service [serve|migrate|selfcheck|dev-reset|version]\n"
                 "env: DATABASE_URL, HPMMO_BIND, HPMMO_HTTP_PORT, HPMMO_SERVICE_TOKEN,\n"
                 "     HPMMO_MIGRATIONS_DIR, HPMMO_ARGON2_M/T/P, HPMMO_ALLOW_RESET\n");
    return 2;
}
