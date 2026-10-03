#include "db.h"

#include <algorithm>
#include <cctype>
#include <cstdint>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <ctime>
#include <filesystem>
#include <fstream>
#include <random>
#include <sstream>

#ifdef _WIN32
#include <windows.h>
#include <bcrypt.h>
#endif

namespace db {

namespace {

std::string sqlstate_of(PGresult* res) {
    const char* s = PQresultErrorField(res, PG_DIAG_SQLSTATE);
    return s ? std::string(s) : std::string();
}

ErrorKind classify(PGresult* res, const std::string& msg) {
    const std::string state = sqlstate_of(res);
    if (state.rfind("08", 0) == 0 || state == "57P01" || state == "57P02" || state == "57P03") {
        return ErrorKind::Connection;
    }
    if (state.rfind("23", 0) == 0) return ErrorKind::Constraint;  // integrity constraint violation
    if (msg.find("server closed the connection") != std::string::npos ||
        msg.find("could not connect") != std::string::npos ||
        msg.find("Connection refused") != std::string::npos) {
        return ErrorKind::Connection;
    }
    return ErrorKind::Other;
}

std::string escape_literal(const std::string& v) { return v; }  // docs only; params are used for values

}  // namespace

Conn::Conn(const std::string& dsn) : dsn_(dsn) {
    if (!dsn.empty()) {
        conn_ = PQconnectdb(dsn.c_str());
    }
}

Conn::~Conn() {
    if (conn_) PQfinish(conn_);
}

bool Conn::ensure_ok() {
    if (valid()) return true;
    if (conn_) PQfinish(conn_);
    if (dsn_.empty()) return false;
    conn_ = PQconnectdb(dsn_.c_str());
    return valid();
}

Result Conn::exec(const std::string& sql, const std::vector<std::optional<std::string>>& params) {
    Result out;
    if (!ensure_ok()) {
        out.kind = ErrorKind::Connection;
        out.error = "database unavailable";
        return out;
    }
    std::vector<const char*> values;
    values.reserve(params.size());
    for (const auto& p : params) values.push_back(p ? p->c_str() : nullptr);
    PGresult* res = PQexecParams(conn_, sql.c_str(), static_cast<int>(params.size()), nullptr,
                                 values.data(), nullptr, nullptr, 0);
    if (!res) {
        out.kind = ErrorKind::Connection;
        out.error = "database unavailable";
        return out;
    }
    const ExecStatusType st = PQresultStatus(res);
    if (st == PGRES_TUPLES_OK || st == PGRES_COMMAND_OK) {
        out.ok = true;
        const char* tag = PQcmdTuples(res);
        if (tag && *tag) {
            try {
                out.affected = std::stoll(tag);
            } catch (...) {
                out.affected = -1;
            }
        }
        const int rows = PQntuples(res);
        const int cols = PQnfields(res);
        for (int r = 0; r < rows; ++r) {
            Row row;
            row.reserve(cols);
            for (int c = 0; c < cols; ++c) {
                std::optional<std::string> v;
                if (!PQgetisnull(res, r, c)) v = std::string(PQgetvalue(res, r, c), PQgetlength(res, r, c));
                row.emplace_back(PQfname(res, c), std::move(v));
            }
            out.rows.push_back(std::move(row));
        }
    } else {
        const std::string msg = PQresultErrorMessage(res) ? PQresultErrorMessage(res) : "";
        out.error = msg.substr(0, 400);
        out.kind = classify(res, msg);
    }
    PQclear(res);
    return out;
}

Result Conn::exec_simple(const std::string& sql) {
    Result out;
    if (!ensure_ok()) {
        out.kind = ErrorKind::Connection;
        out.error = "database unavailable";
        return out;
    }
    PGresult* res = PQexec(conn_, sql.c_str());
    if (!res) {
        out.kind = ErrorKind::Connection;
        out.error = "database unavailable";
        return out;
    }
    const ExecStatusType st = PQresultStatus(res);
    if (st == PGRES_TUPLES_OK || st == PGRES_COMMAND_OK) {
        out.ok = true;
    } else {
        const std::string msg = PQresultErrorMessage(res) ? PQresultErrorMessage(res) : "";
        out.error = msg.substr(0, 400);
        out.kind = classify(res, msg);
    }
    PQclear(res);
    return out;
}

Result Conn::exec_tx(const std::vector<std::string>& statements) {
    Result out;
    if (!begin()) {
        out.kind = ErrorKind::Connection;
        out.error = "database unavailable";
        return out;
    }
    for (const auto& sql : statements) {
        Result r = exec(sql);
        if (!r.ok) {
            rollback();
            return r;
        }
    }
    if (!commit_checked(out)) return out;
    out.ok = true;
    return out;
}

bool Conn::begin() {
    // Pin the isolation level the ledger concurrency reasoning depends on.
    Result r = exec("BEGIN ISOLATION LEVEL READ COMMITTED");
    return r.ok;
}

bool Conn::commit_checked(Result& out) {
    if (!conn_ || PQstatus(conn_) != CONNECTION_OK) {
        out.kind = ErrorKind::Connection;
        out.error = "connection lost before commit (commit result unknown)";
        return false;
    }
    PGresult* res = PQexec(conn_, "COMMIT");
    if (!res) {
        out.kind = ErrorKind::Connection;
        out.error = "connection lost during commit (commit result unknown)";
        return false;
    }
    const ExecStatusType st = PQresultStatus(res);
    if (st == PGRES_COMMAND_OK) {
        // COMMIT on an aborted transaction succeeds with the tag "ROLLBACK";
        // that is a rolled-back transaction, not a commit.
        const char* tag = PQcmdStatus(res);
        if (tag && std::strcmp(tag, "COMMIT") == 0) {
            PQclear(res);
            return true;
        }
        out.kind = ErrorKind::Other;
        out.error = "transaction was rolled back instead of committed";
        PQclear(res);
        return false;
    }
    if (st == PGRES_FATAL_ERROR && PQstatus(conn_) != CONNECTION_OK) {
        // Server went away while processing COMMIT: outcome unknown.
        out.kind = ErrorKind::Connection;
        out.error = "connection lost during commit (commit result unknown)";
        PQclear(res);
        return false;
    }
    const std::string msg = PQresultErrorMessage(res) ? PQresultErrorMessage(res) : "";
    out.kind = classify(res, msg);
    out.error = msg.substr(0, 400);
    PQclear(res);
    return false;
}

void Conn::rollback() {
    if (conn_ && PQstatus(conn_) == CONNECTION_OK) {
        PGresult* res = PQexec(conn_, "ROLLBACK");
        if (res) PQclear(res);
    }
}

Pool::Pool(const std::string& dsn, int size) {
    for (int i = 0; i < std::max(1, size); ++i) {
        conns_.push_back(std::make_unique<Conn>(dsn));
        locks_.push_back(std::make_unique<std::mutex>());
    }
}

Pool::Lease Pool::acquire() {
    const size_t idx = next_.fetch_add(1) % conns_.size();
    locks_[idx]->lock();
    return Lease(conns_[idx].get(), locks_[idx].get());
}

std::string now_iso8601() {
    std::time_t t = std::time(nullptr);
    std::tm tm{};
#ifdef _WIN32
    gmtime_s(&tm, &t);
#else
    gmtime_r(&t, &tm);
#endif
    char buf[32];
    std::strftime(buf, sizeof(buf), "%Y-%m-%dT%H:%M:%SZ", &tm);
    return buf;
}

void secure_random_bytes(unsigned char* out, size_t bytes) {
#ifdef _WIN32
    // BCryptGenRandom: the OS CSPRNG (std::random_device on MinGW is not guaranteed).
    const NTSTATUS status =
        BCryptGenRandom(nullptr, out, static_cast<ULONG>(bytes), BCRYPT_USE_SYSTEM_PREFERRED_RNG);
    if (status != 0) {
        std::abort();  // never silently fall back to weak randomness
    }
#else
    std::ifstream urandom("/dev/urandom", std::ios::binary);
    urandom.read(reinterpret_cast<char*>(out), static_cast<std::streamsize>(bytes));
    if (!urandom) std::abort();
#endif
}

std::string gen_hex(size_t bytes) {
    std::vector<unsigned char> raw(bytes);
    secure_random_bytes(raw.data(), bytes);
    static const char* hex = "0123456789abcdef";
    std::string out;
    out.reserve(bytes * 2);
    for (size_t i = 0; i < bytes; ++i) {
        out.push_back(hex[raw[i] >> 4]);
        out.push_back(hex[raw[i] & 0xF]);
    }
    return out;
}

// Minimal SHA-256 (public-domain style implementation) for session/ticket
// hashing. Password hashing uses argon2id (auth.cpp); this is for tokens only.
namespace {
struct Sha256 {
    uint32_t h[8];
    uint64_t len = 0;
    unsigned char buf[64];
    size_t buf_len = 0;

    Sha256() { reset(); }
    static uint32_t rotr(uint32_t x, int n) { return (x >> n) | (x << (32 - n)); }
    void reset() {
        static const uint32_t init[8] = {0x6a09e667, 0xbb67ae85, 0x3c6ef372, 0xa54ff53a,
                                         0x510e527f, 0x9b05688c, 0x1f83d9ab, 0x5be0cd19};
        std::memcpy(h, init, sizeof(h));
        len = 0;
        buf_len = 0;
    }
    void block(const unsigned char* p) {
        static const uint32_t k[64] = {
            0x428a2f98, 0x71374491, 0xb5c0fbcf, 0xe9b5dba5, 0x3956c25b, 0x59f111f1, 0x923f82a4, 0xab1c5ed5,
            0xd807aa98, 0x12835b01, 0x243185be, 0x550c7dc3, 0x72be5d74, 0x80deb1fe, 0x9bdc06a7, 0xc19bf174,
            0xe49b69c1, 0xefbe4786, 0x0fc19dc6, 0x240ca1cc, 0x2de92c6f, 0x4a7484aa, 0x5cb0a9dc, 0x76f988da,
            0x983e5152, 0xa831c66d, 0xb00327c8, 0xbf597fc7, 0xc6e00bf3, 0xd5a79147, 0x06ca6351, 0x14292967,
            0x27b70a85, 0x2e1b2138, 0x4d2c6dfc, 0x53380d13, 0x650a7354, 0x766a0abb, 0x81c2c92e, 0x92722c85,
            0xa2bfe8a1, 0xa81a664b, 0xc24b8b70, 0xc76c51a3, 0xd192e819, 0xd6990624, 0xf40e3585, 0x106aa070,
            0x19a4c116, 0x1e376c08, 0x2748774c, 0x34b0bcb5, 0x391c0cb3, 0x4ed8aa4a, 0x5b9cca4f, 0x682e6ff3,
            0x748f82ee, 0x78a5636f, 0x84c87814, 0x8cc70208, 0x90befffa, 0xa4506ceb, 0xbef9a3f7, 0xc67178f2};
        uint32_t w[64];
        for (int i = 0; i < 16; ++i) {
            w[i] = (p[i * 4] << 24) | (p[i * 4 + 1] << 16) | (p[i * 4 + 2] << 8) | p[i * 4 + 3];
        }
        for (int i = 16; i < 64; ++i) {
            const uint32_t s0 = rotr(w[i - 15], 7) ^ rotr(w[i - 15], 18) ^ (w[i - 15] >> 3);
            const uint32_t s1 = rotr(w[i - 2], 17) ^ rotr(w[i - 2], 19) ^ (w[i - 2] >> 10);
            w[i] = w[i - 16] + s0 + w[i - 7] + s1;
        }
        uint32_t a = h[0], b = h[1], c = h[2], d = h[3], e = h[4], f = h[5], g = h[6], hh = h[7];
        for (int i = 0; i < 64; ++i) {
            const uint32_t s1 = rotr(e, 6) ^ rotr(e, 11) ^ rotr(e, 25);
            const uint32_t ch = (e & f) ^ (~e & g);
            const uint32_t t1 = hh + s1 + ch + k[i] + w[i];
            const uint32_t s0 = rotr(a, 2) ^ rotr(a, 13) ^ rotr(a, 22);
            const uint32_t maj = (a & b) ^ (a & c) ^ (b & c);
            const uint32_t t2 = s0 + maj;
            hh = g; g = f; f = e; e = d + t1; d = c; c = b; b = a; a = t1 + t2;
        }
        h[0] += a; h[1] += b; h[2] += c; h[3] += d; h[4] += e; h[5] += f; h[6] += g; h[7] += hh;
    }
    void update(const unsigned char* p, size_t n) {
        len += n;
        while (n > 0) {
            const size_t take = std::min<size_t>(n, 64 - buf_len);
            std::memcpy(buf + buf_len, p, take);
            buf_len += take;
            p += take;
            n -= take;
            if (buf_len == 64) {
                block(buf);
                buf_len = 0;
            }
        }
    }
    std::string hex() {
        const uint64_t bit_len = len * 8;
        unsigned char pad = 0x80;
        update(&pad, 1);
        unsigned char zero = 0;
        while (buf_len != 56) update(&zero, 1);
        unsigned char lenb[8];
        for (int i = 0; i < 8; ++i) lenb[i] = static_cast<unsigned char>(bit_len >> (56 - i * 8));
        update(lenb, 8);
        static const char* hx = "0123456789abcdef";
        std::string out;
        out.reserve(64);
        for (int i = 0; i < 8; ++i) {
            for (int s = 28; s >= 0; s -= 4) out.push_back(hx[(h[i] >> s) & 0xF]);
        }
        return out;
    }
};
}  // namespace

std::string sha256_hex(const std::string& data) {
    Sha256 s;
    s.update(reinterpret_cast<const unsigned char*>(data.data()), data.size());
    return s.hex();
}

// --- migrations ---------------------------------------------------------------

int highest_migration_on_disk(const std::string& dir) {
    int highest = 0;
    std::error_code ec;
    for (const auto& entry : std::filesystem::directory_iterator(dir, ec)) {
        if (!entry.is_regular_file()) continue;
        const std::string name = entry.path().filename().string();
        if (name.size() < 4 || !std::isdigit(static_cast<unsigned char>(name[0]))) continue;
        try {
            const int version = std::stoi(name.substr(0, 4));
            highest = std::max(highest, version);
        } catch (...) {
        }
    }
    return highest;
}

MigrationStatus migration_status(Conn& conn, const std::string& migrations_dir) {
    MigrationStatus st;
    st.required = highest_migration_on_disk(migrations_dir);
    if (!conn.ensure_ok()) {
        st.error = "database unavailable";
        return st;
    }
    st.db_reachable = true;
    Result r = conn.exec("SELECT COALESCE(MAX(version), 0)::text FROM schema_migrations");
    if (!r.ok) {
        if (r.kind == ErrorKind::Connection) {
            st.db_reachable = false;
            st.error = "database unavailable";
        } else {
            st.error = "schema_migrations missing (run: hpmmo_service migrate)";
        }
        return st;
    }
    st.applied = std::stoi(r.rows.at(0).at(0).second.value_or("0"));
    return st;
}

MigrationStatus migrate(Conn& conn, const std::string& migrations_dir) {
    MigrationStatus st;
    st.required = highest_migration_on_disk(migrations_dir);
    if (!conn.ensure_ok()) {
        st.error = "database unavailable";
        return st;
    }
    st.db_reachable = true;
    Result lock = conn.exec("SELECT pg_advisory_lock(0x48504D4D)");
    if (!lock.ok) {
        st.error = "could not take migration lock: " + lock.error;
        return st;
    }
    Result init = conn.exec(
        "CREATE TABLE IF NOT EXISTS schema_migrations (version integer PRIMARY KEY, "
        "name text NOT NULL, applied_at timestamptz NOT NULL DEFAULT now())");
    if (!init.ok) {
        st.error = "could not create schema_migrations: " + init.error;
        return st;
    }
    std::vector<std::filesystem::path> files;
    std::error_code ec;
    for (const auto& entry : std::filesystem::directory_iterator(migrations_dir, ec)) {
        if (entry.is_regular_file() && entry.path().extension() == ".sql") files.push_back(entry.path());
    }
    std::sort(files.begin(), files.end());
    for (const auto& path : files) {
        int version = 0;
        try {
            version = std::stoi(path.filename().string().substr(0, 4));
        } catch (...) {
            continue;
        }
        Result has = conn.exec("SELECT 1 FROM schema_migrations WHERE version = $1",
                               {std::to_string(version)});
        if (has.ok && !has.rows.empty()) continue;
        std::ifstream in(path, std::ios::binary);
        std::stringstream ss;
        ss << in.rdbuf();
        const std::string sql = ss.str();
        if (!conn.begin()) {
            st.error = "database unavailable";
            st.db_reachable = false;
            return st;
        }
        Result r = conn.exec_simple(sql);
        if (!r.ok) {
            conn.rollback();
            st.error = "migration " + path.filename().string() + " failed: " + r.error;
            return st;
        }
        Result rec = conn.exec("INSERT INTO schema_migrations (version, name) VALUES ($1, $2)",
                               {std::to_string(version), path.filename().string()});
        if (!rec.ok) {
            conn.rollback();
            st.error = "recording migration failed: " + rec.error;
            return st;
        }
        Result commit;
        if (!conn.commit_checked(commit)) {
            st.error = "commit of migration " + path.filename().string() + " failed: " + commit.error;
            return st;
        }
        std::printf("[migrate] applied %s\n", path.filename().string().c_str());
    }
    Result rel = conn.exec("SELECT pg_advisory_unlock(0x48504D4D)");
    (void)rel;
    MigrationStatus after = migration_status(conn, migrations_dir);
    return after;
}

}  // namespace db
