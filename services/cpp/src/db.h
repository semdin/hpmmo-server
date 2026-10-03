// libpq wrapper: connection pool, transactions, typed query results,
// error classification (connection vs constraint), migrations + readiness.
#pragma once

#include <libpq-fe.h>

#include <atomic>
#include <chrono>
#include <cstdint>
#include <memory>
#include <mutex>
#include <optional>
#include <string>
#include <vector>

namespace db {

// One row: column name -> value (NULL => no value).
using Row = std::vector<std::pair<std::string, std::optional<std::string>>>;
using Rows = std::vector<Row>;

enum class ErrorKind {
    None,
    Connection,   // server unreachable / connection lost (=> 503 unavailable)
    Constraint,   // unique/check/foreign-key violation (=> 409/400)
    Other,
};

struct Result {
    bool ok = false;
    ErrorKind kind = ErrorKind::Other;
    std::string error;   // human-readable, never contains secrets
    Rows rows;
    long long affected = -1;  // command-tag row count when available
};

class Conn {
public:
    explicit Conn(const std::string& dsn);
    ~Conn();
    Conn(const Conn&) = delete;
    Conn& operator=(const Conn&) = delete;

    bool valid() const { return conn_ != nullptr && PQstatus(conn_) == CONNECTION_OK; }
    // Reconnect if the connection died (used by the pool between checkouts).
    bool ensure_ok();

    // nullopt parameters bind as SQL NULL (an empty string is NOT NULL).
    Result exec(const std::string& sql, const std::vector<std::optional<std::string>>& params = {});
    // Multi-statement, no parameters (extended protocol forbids multi-statement
    // SQL, so migration files go through the simple protocol here).
    Result exec_simple(const std::string& sql);
    Result exec_tx(const std::vector<std::string>& statements);  // single transaction, all-or-nothing

    bool begin();
    bool commit_checked(Result& out);  // distinguishes uncertain commit (connection lost during COMMIT)
    void rollback();

    const std::string& last_error() const { return last_error_; }

private:
    PGconn* conn_ = nullptr;
    std::string dsn_;
    std::string last_error_;
};

class Pool {
public:
    Pool(const std::string& dsn, int size);

    // Checked-out connection; unlocks its pool slot on destruction. Movable,
    // not copyable. Forwarding methods so callers use `lease.exec(...)`.
    class Lease {
    public:
        Lease(Conn* c, std::mutex* m) : conn_(c), mutex_(m) {}
        ~Lease() { if (mutex_) mutex_->unlock(); }
        Lease(const Lease&) = delete;
        Lease& operator=(const Lease&) = delete;
        Lease(Lease&& other) noexcept : conn_(other.conn_), mutex_(other.mutex_) { other.mutex_ = nullptr; }

        Conn* conn() const { return conn_; }
        Result exec(const std::string& sql, const std::vector<std::optional<std::string>>& params = {}) {
            return conn_->exec(sql, params);
        }
        Result exec_tx(const std::vector<std::string>& statements) { return conn_->exec_tx(statements); }
        bool begin() { return conn_->begin(); }
        bool commit_checked(Result& out) { return conn_->commit_checked(out); }
        void rollback() { conn_->rollback(); }

    private:
        Conn* conn_;
        std::mutex* mutex_;
    };
    Lease acquire();

private:
    std::vector<std::unique_ptr<Conn>> conns_;
    std::vector<std::unique_ptr<std::mutex>> locks_;
    std::atomic<size_t> next_{0};
};

// --- migrations / readiness ---
struct MigrationStatus {
    bool db_reachable = false;
    int applied = -1;     // highest applied version, -1 if unknown
    int required = -1;    // highest version present on disk
    std::string error;
};

int highest_migration_on_disk(const std::string& dir);
MigrationStatus migrate(Conn& conn, const std::string& migrations_dir);
MigrationStatus migration_status(Conn& conn, const std::string& migrations_dir);

std::string now_iso8601();
void secure_random_bytes(unsigned char* out, size_t bytes);  // OS CSPRNG (BCryptGenRandom / urandom)
std::string gen_hex(size_t bytes);              // CSPRNG-backed hex (tokens, salts, tickets)
std::string sha256_hex(const std::string& data); // hex digest

}  // namespace db
