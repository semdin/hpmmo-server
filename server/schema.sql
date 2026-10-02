-- HPMMO - PostgreSQL Database Schema
-- Dedicated Game Server Persistence Layer

-- 1. Accounts Table
CREATE TABLE IF NOT EXISTS accounts (
    id SERIAL PRIMARY KEY,
    username VARCHAR(50) UNIQUE NOT NULL,
    password_hash VARCHAR(256) NOT NULL,
    created_at TIMESTAMP WITH TIME ZONE DEFAULT CURRENT_TIMESTAMP,
    last_login TIMESTAMP WITH TIME ZONE DEFAULT CURRENT_TIMESTAMP
);

CREATE INDEX IF NOT EXISTS idx_accounts_username ON accounts(username);

-- 2. Characters Table
CREATE TABLE IF NOT EXISTS characters (
    id SERIAL PRIMARY KEY,
    account_id INTEGER NOT NULL REFERENCES accounts(id) ON DELETE CASCADE,
    name VARCHAR(50) UNIQUE NOT NULL,
    house VARCHAR(30) NOT NULL DEFAULT 'Gryffindor',
    level INTEGER NOT NULL DEFAULT 1,
    exp INTEGER NOT NULL DEFAULT 0,
    max_hp INTEGER NOT NULL DEFAULT 500,
    current_hp INTEGER NOT NULL DEFAULT 500,
    max_mana INTEGER NOT NULL DEFAULT 300,
    current_mana INTEGER NOT NULL DEFAULT 300,
    galleons INTEGER NOT NULL DEFAULT 500,
    wand_tier INTEGER NOT NULL DEFAULT 0,
    pos_x REAL NOT NULL DEFAULT 0.0,
    pos_y REAL NOT NULL DEFAULT 0.5,
    pos_z REAL NOT NULL DEFAULT 5.0,
    rot_y REAL NOT NULL DEFAULT 3.14159,
    inventory JSONB NOT NULL DEFAULT '[]'::jsonb,
    quests JSONB NOT NULL DEFAULT '{}'::jsonb,
    updated_at TIMESTAMP WITH TIME ZONE DEFAULT CURRENT_TIMESTAMP
);

CREATE INDEX IF NOT EXISTS idx_characters_account ON characters(account_id);
CREATE INDEX IF NOT EXISTS idx_characters_name ON characters(name);

-- 3. Trade Transaction Log (ACID Atomic Swaps)
CREATE TABLE IF NOT EXISTS trade_logs (
    id SERIAL PRIMARY KEY,
    sender_char_id INTEGER REFERENCES characters(id) ON DELETE SET NULL,
    receiver_char_id INTEGER REFERENCES characters(id) ON DELETE SET NULL,
    details JSONB NOT NULL,
    created_at TIMESTAMP WITH TIME ZONE DEFAULT CURRENT_TIMESTAMP
);
