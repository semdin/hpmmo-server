// HPMMO service configuration - environment only, no secrets in code.
#pragma once

#include <optional>
#include <string>

struct Config {
    std::string bind_addr = "127.0.0.1";      // HPMMO_BIND (VPS sets 0.0.0.0 behind the firewall)
    int http_port = 8081;                     // HPMMO_HTTP_PORT
    std::string database_url;                 // DATABASE_URL (postgres only; empty => not ready)
    std::string service_token;                // HPMMO_SERVICE_TOKEN (private endpoints; empty => refuse)
    int session_ttl_hours = 24;               // HPMMO_SESSION_TTL_HOURS
    int ticket_ttl_seconds = 60;              // HPMMO_TICKET_TTL_SECONDS
    int max_sessions_per_account = 5;         // HPMMO_MAX_SESSIONS
    unsigned argon2_m_cost = 65536;           // HPMMO_ARGON2_M (KiB)
    unsigned argon2_t_cost = 3;               // HPMMO_ARGON2_T
    unsigned argon2_parallelism = 1;          // HPMMO_ARGON2_P
    std::string migrations_dir = "db/migrations"; // HPMMO_MIGRATIONS_DIR
    int db_pool_size = 4;                     // HPMMO_DB_POOL
    bool allow_reset = false;                 // HPMMO_ALLOW_RESET=1 (dev-reset only)

    static Config from_env();
};
