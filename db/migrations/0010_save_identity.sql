-- The id of the last character save that committed (security audit 2026-11-09).
-- A save whose answer was lost (timeout, service restart, unknown COMMIT
-- outcome) used to be retried with a stale base_revision, got a 409, and the
-- world then rolled the live character back to the older sheet. The service
-- now recognises its own committed write by this id (handle_character_save).
ALTER TABLE characters ADD COLUMN IF NOT EXISTS last_save_id text;
