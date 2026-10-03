-- HPMMO core: accounts (argon2id) + sessions.
-- PostgreSQL only; there is no SQLite fallback in the C++ service.

CREATE TABLE IF NOT EXISTS accounts (
    id            bigserial PRIMARY KEY,
    username      text NOT NULL,
    password_hash text NOT NULL,              -- argon2id PHC string
    created_at    timestamptz NOT NULL DEFAULT now(),
    last_login    timestamptz
);
CREATE UNIQUE INDEX IF NOT EXISTS accounts_username_lower_uniq ON accounts (lower(username));

CREATE TABLE IF NOT EXISTS sessions (
    id           bigserial PRIMARY KEY,
    account_id   bigint NOT NULL REFERENCES accounts(id) ON DELETE CASCADE,
    token_hash   text NOT NULL UNIQUE,        -- sha256 hex of the bearer token
    created_at   timestamptz NOT NULL DEFAULT now(),
    last_seen_at timestamptz NOT NULL DEFAULT now(),
    expires_at   timestamptz NOT NULL,
    revoked_at   timestamptz
);
CREATE INDEX IF NOT EXISTS sessions_owner_active_idx ON sessions (account_id) WHERE revoked_at IS NULL;

CREATE TABLE IF NOT EXISTS game_tickets (
    ticket_hash  text PRIMARY KEY,            -- sha256 hex of the one-time ticket
    account_id   bigint NOT NULL REFERENCES accounts(id) ON DELETE CASCADE,
    character_id bigint,                      -- FK added in 0002 once characters exist
    created_at   timestamptz NOT NULL DEFAULT now(),
    expires_at   timestamptz NOT NULL,
    used_at      timestamptz
);
CREATE INDEX IF NOT EXISTS game_tickets_expiry_idx ON game_tickets (expires_at);
