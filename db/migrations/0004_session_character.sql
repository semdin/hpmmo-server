-- Sessions carry the character they were bound to at game-ticket redemption.
-- NULL for plain logins and unbound tickets; set when the redeemed ticket
-- carried a character (Phase 5: the world server resolves a token to its
-- character through this column).

ALTER TABLE sessions
    ADD COLUMN IF NOT EXISTS character_id bigint REFERENCES characters(id) ON DELETE CASCADE;

-- Active sessions per character (world server lookups in Phase 5).
CREATE INDEX IF NOT EXISTS sessions_character_active_idx
    ON sessions (character_id) WHERE character_id IS NOT NULL AND revoked_at IS NULL;
