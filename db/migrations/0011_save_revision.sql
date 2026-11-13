-- The revision the last committed character save produced (with last_save_id,
-- migration 0010). A save naming that write as `after_save_id` may skip the
-- stale-revision check only while the stored revision is still exactly this
-- one: a reward or trade that bumped it since (and cleared both columns) or
-- any other writer must still cause a 409, not have its items wiped by the
-- save's full bag replace.
ALTER TABLE characters ADD COLUMN IF NOT EXISTS last_save_revision bigint;
