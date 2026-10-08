-- Equipment is separate ownership: a copy is either in the bag or a slot.
ALTER TABLE characters ADD COLUMN IF NOT EXISTS base_max_hp integer NOT NULL DEFAULT 500 CHECK (base_max_hp BETWEEN 1 AND 1000000);
ALTER TABLE characters ADD COLUMN IF NOT EXISTS base_max_mana integer NOT NULL DEFAULT 300 CHECK (base_max_mana BETWEEN 1 AND 1000000);
ALTER TABLE characters ADD COLUMN IF NOT EXISTS equipment_version integer NOT NULL DEFAULT 0;
ALTER TABLE characters ADD COLUMN IF NOT EXISTS inventory_revision bigint NOT NULL DEFAULT 0;
CREATE TABLE IF NOT EXISTS character_equipment (
    character_id bigint NOT NULL REFERENCES characters(id) ON DELETE CASCADE,
    slot text NOT NULL CHECK (slot IN ('head','chest','hands','feet','main_hand','off_hand','neck','ring_left','ring_right','broom')),
    item_id text NOT NULL CHECK (length(item_id) BETWEEN 1 AND 64),
    tier integer NOT NULL DEFAULT 0 CHECK (tier BETWEEN 0 AND 9),
    PRIMARY KEY(character_id, slot)
);

-- Idempotent, also used to initialize new characters from the starter bag.
CREATE OR REPLACE FUNCTION initialize_character_equipment(cid bigint) RETURNS void AS $$
DECLARE c record; selected record; target text; preferred text;
BEGIN
    SELECT * INTO c FROM characters WHERE id=cid FOR UPDATE;
    IF NOT FOUND OR c.equipment_version >= 1 THEN RETURN; END IF;
    UPDATE characters SET base_max_hp=max_hp, base_max_mana=max_mana WHERE id=cid;
    FOREACH target IN ARRAY ARRAY['main_hand','chest','broom'] LOOP
        preferred := CASE target WHEN 'main_hand' THEN 'wand_hawthorn' WHEN 'chest' THEN 'robe_apprentice' ELSE 'broom_nimbus2000' END;
        SELECT * INTO selected FROM character_items WHERE character_id=cid AND
          ((target='main_hand' AND item_id IN ('wand_hawthorn','wand_elder')) OR
           (target='chest' AND item_id IN ('robe_apprentice','robe_auror')) OR
           (target='broom' AND item_id IN ('broom_nimbus2000','broom_firebolt')))
          ORDER BY (item_id=preferred) DESC, item_id, tier LIMIT 1 FOR UPDATE;
        IF FOUND THEN
            INSERT INTO character_equipment VALUES(cid,target,selected.item_id,
              CASE WHEN target='main_hand' THEN GREATEST(selected.tier,c.wand_tier) ELSE selected.tier END);
            IF selected.amount=1 THEN DELETE FROM character_items WHERE id=selected.id;
            ELSE UPDATE character_items SET amount=amount-1 WHERE id=selected.id; END IF;
        END IF;
    END LOOP;
    UPDATE characters SET equipment_version=1, inventory_revision=inventory_revision+1,
      max_hp=base_max_hp + COALESCE((SELECT CASE item_id WHEN 'robe_apprentice' THEN 50 WHEN 'robe_auror' THEN 150 ELSE 0 END FROM character_equipment WHERE character_id=cid AND slot='chest'),0),
      wand_tier=COALESCE((SELECT tier FROM character_equipment WHERE character_id=cid AND slot='main_hand'),0),
      revision=revision+1 WHERE id=cid;
END;
$$ LANGUAGE plpgsql;
SELECT initialize_character_equipment(id) FROM characters ORDER BY id;
