-- HPMMO characters: full persisted state + normalized item ownership.

CREATE TABLE IF NOT EXISTS characters (
    id           bigserial PRIMARY KEY,
    account_id   bigint NOT NULL REFERENCES accounts(id) ON DELETE CASCADE,
    name         text NOT NULL UNIQUE,
    house        text NOT NULL DEFAULT 'Gryffindor'
                 CHECK (house IN ('Gryffindor','Slytherin','Ravenclaw','Hufflepuff')),
    level        integer NOT NULL DEFAULT 1 CHECK (level BETWEEN 1 AND 100),
    exp          bigint  NOT NULL DEFAULT 0 CHECK (exp >= 0 AND exp <= 2000000000),
    max_hp       integer NOT NULL DEFAULT 500 CHECK (max_hp BETWEEN 1 AND 1000000),
    current_hp   integer NOT NULL DEFAULT 500 CHECK (current_hp >= 0 AND current_hp <= 1000000),
    max_mana     integer NOT NULL DEFAULT 300 CHECK (max_mana BETWEEN 1 AND 1000000),
    current_mana integer NOT NULL DEFAULT 300 CHECK (current_mana >= 0 AND current_mana <= 1000000),
    galleons     bigint  NOT NULL DEFAULT 500 CHECK (galleons >= 0 AND galleons <= 1000000000),
    wand_tier    integer NOT NULL DEFAULT 0 CHECK (wand_tier BETWEEN 0 AND 9),
    map_id       text NOT NULL DEFAULT 'grounds',
    pos_x        double precision NOT NULL DEFAULT 0.0,
    pos_y        double precision NOT NULL DEFAULT 0.5,
    pos_z        double precision NOT NULL DEFAULT 5.0,
    rot_y        double precision NOT NULL DEFAULT 3.14159,
    quests       jsonb NOT NULL DEFAULT '{}'::jsonb CHECK (jsonb_typeof(quests) = 'object'),
    revision     bigint NOT NULL DEFAULT 1,   -- stale-write rejection
    created_at   timestamptz NOT NULL DEFAULT now(),
    updated_at   timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX IF NOT EXISTS characters_account_idx ON characters (account_id);

-- Normalized mutable item ownership. One row per (character, item, tier);
-- quantity lives on the row. Trades/rewards mutate rows atomically.
CREATE TABLE IF NOT EXISTS character_items (
    id           bigserial PRIMARY KEY,
    character_id bigint NOT NULL REFERENCES characters(id) ON DELETE CASCADE,
    item_id      text NOT NULL CHECK (item_id <> '' AND length(item_id) <= 64),
    amount       integer NOT NULL CHECK (amount > 0 AND amount <= 9999),
    tier         integer NOT NULL DEFAULT 0 CHECK (tier BETWEEN 0 AND 9),
    UNIQUE (character_id, item_id, tier)
);
CREATE INDEX IF NOT EXISTS character_items_owner_idx ON character_items (character_id);

-- Ticket -> character binding now that characters exist.
DO $$
BEGIN
    IF NOT EXISTS (SELECT 1 FROM pg_constraint WHERE conname = 'game_tickets_character_fk') THEN
        ALTER TABLE game_tickets
            ADD CONSTRAINT game_tickets_character_fk
            FOREIGN KEY (character_id) REFERENCES characters(id) ON DELETE CASCADE;
    END IF;
END $$;
