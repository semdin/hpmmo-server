-- New characters start with the basic Ashwood Twig only (the cloak, accessories
-- and the broom are quest rewards). initialize_character_equipment equips the
-- starter wand; the legacy wands / robes / brooms are still recognised so the
-- function stays idempotent for characters created before this migration.
CREATE OR REPLACE FUNCTION initialize_character_equipment(cid bigint) RETURNS void AS $$
DECLARE c record; selected record; target text; preferred text;
BEGIN
    SELECT * INTO c FROM characters WHERE id=cid FOR UPDATE;
    IF NOT FOUND OR c.equipment_version >= 1 THEN RETURN; END IF;
    UPDATE characters SET base_max_hp=max_hp, base_max_mana=max_mana WHERE id=cid;
    FOREACH target IN ARRAY ARRAY['main_hand','chest','broom'] LOOP
        preferred := CASE target WHEN 'main_hand' THEN 'wand_ashwood' WHEN 'chest' THEN 'cloak_wool' ELSE 'broom_ashwood' END;
        SELECT * INTO selected FROM character_items WHERE character_id=cid AND
          ((target='main_hand' AND item_id IN ('wand_ashwood','wand_hawthorn','wand_elder')) OR
           (target='chest' AND item_id IN ('cloak_wool','robe_apprentice','robe_auror')) OR
           (target='broom' AND item_id IN ('broom_ashwood','broom_nimbus2000','broom_firebolt')))
          ORDER BY (item_id=preferred) DESC, item_id, tier LIMIT 1 FOR UPDATE;
        IF FOUND THEN
            INSERT INTO character_equipment VALUES(cid,target,selected.item_id,
              CASE WHEN target='main_hand' THEN GREATEST(selected.tier,c.wand_tier) ELSE selected.tier END);
            IF selected.amount=1 THEN DELETE FROM character_items WHERE id=selected.id;
            ELSE UPDATE character_items SET amount=amount-1 WHERE id=selected.id; END IF;
        END IF;
    END LOOP;
    UPDATE characters SET equipment_version=1, inventory_revision=inventory_revision+1,
      wand_tier=COALESCE((SELECT tier FROM character_equipment WHERE character_id=cid AND slot='main_hand'),0),
      revision=revision+1 WHERE id=cid;
END;
$$ LANGUAGE plpgsql;
