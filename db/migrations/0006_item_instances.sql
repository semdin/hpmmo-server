-- Item instances. A non-stackable item (wand, robe, broom, accessory) is its own
-- row: amount 1, a `uid` that names it for its whole life, and its own `bonuses`
-- (enchantments). Stackable items (potions, materials) keep one row per
-- (character, item, tier) with uid NULL. Which items stack is the world's rule
-- (items.json); the world splits rows saved before this migration on load and
-- writes them back as instances, so no data is rewritten here.
ALTER TABLE character_items ADD COLUMN IF NOT EXISTS uid bigint;
ALTER TABLE character_items ADD COLUMN IF NOT EXISTS bonuses jsonb NOT NULL DEFAULT '[]'::jsonb;
ALTER TABLE character_items DROP CONSTRAINT IF EXISTS character_items_character_id_item_id_tier_key;
CREATE UNIQUE INDEX IF NOT EXISTS character_items_stack_uidx
    ON character_items (character_id, item_id, tier) WHERE uid IS NULL;
CREATE UNIQUE INDEX IF NOT EXISTS character_items_instance_uidx
    ON character_items (character_id, uid) WHERE uid IS NOT NULL;
DO $$
BEGIN
    IF NOT EXISTS (SELECT 1 FROM pg_constraint WHERE conname = 'character_items_instance_check') THEN
        ALTER TABLE character_items ADD CONSTRAINT character_items_instance_check
            CHECK ((uid IS NULL OR (uid > 0 AND amount = 1)) AND jsonb_typeof(bonuses) = 'array'
                   AND jsonb_array_length(bonuses) <= 8);
    END IF;
END $$;

ALTER TABLE character_equipment ADD COLUMN IF NOT EXISTS uid bigint;
ALTER TABLE character_equipment ADD COLUMN IF NOT EXISTS bonuses jsonb NOT NULL DEFAULT '[]'::jsonb;
DO $$
BEGIN
    IF NOT EXISTS (SELECT 1 FROM pg_constraint WHERE conname = 'character_equipment_instance_check') THEN
        ALTER TABLE character_equipment ADD CONSTRAINT character_equipment_instance_check
            CHECK ((uid IS NULL OR uid > 0) AND jsonb_typeof(bonuses) = 'array'
                   AND jsonb_array_length(bonuses) <= 8);
    END IF;
END $$;
