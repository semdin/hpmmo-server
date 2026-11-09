-- Character names are unique regardless of case (security audit 2026-11-09).
-- `name text UNIQUE` was case-sensitive, so "Mehmet" and "mehmet" could both
-- exist - and the world server's GA list, chat and party commands match names
-- case-insensitively, which let a look-alike name act as a game admin. The API
-- (character_name_problem) also refuses leading/trailing/doubled separators
-- and control characters; the CHECK keeps the table honest on its own.
CREATE UNIQUE INDEX IF NOT EXISTS characters_name_lower ON characters (lower(name));

DO $$
BEGIN
    IF NOT EXISTS (SELECT 1 FROM pg_constraint WHERE conname = 'characters_name_clean') THEN
        ALTER TABLE characters ADD CONSTRAINT characters_name_clean
            CHECK (name = btrim(name) AND name !~ '[[:cntrl:]]' AND name !~ '  ');
    END IF;
END $$;
