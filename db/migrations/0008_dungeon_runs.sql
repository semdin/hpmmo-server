-- Dungeon runs (dungeon system v2, Z6): every full clear of a scored run, for
-- the weekly leaderboards. `week` is the dungeon week (HPRules.dungeon_week:
-- weeks turn on Monday 03:00 UTC); `party` lists the members who finished it
-- ([{character_id, name, level}]). `op_id` makes a retried post land once.
CREATE TABLE IF NOT EXISTS dungeon_runs (
    id          bigserial PRIMARY KEY,
    op_id       text NOT NULL UNIQUE,
    dungeon     text NOT NULL,
    difficulty  text NOT NULL,
    week        integer NOT NULL,
    seconds     double precision NOT NULL CHECK (seconds >= 0),
    medal       text NOT NULL DEFAULT '',
    deaths      integer NOT NULL DEFAULT 0,
    party       jsonb NOT NULL DEFAULT '[]'::jsonb,
    finished_at timestamptz NOT NULL DEFAULT now()
);

CREATE INDEX IF NOT EXISTS dungeon_runs_board ON dungeon_runs (dungeon, difficulty, week, seconds);
