extends RefCounted
class_name TestCharacter

## Developer test character for offline play: `--solo --test-char=<preset>`.
##
## Builds a fresh offline sheet at a chosen level with the best gear that level
## may wear (refined +9, full enchant bonuses), every spell mastered, the
## quests below that level already claimed and plenty of potions, scrolls,
## materials and galleons, so any part of the game can be tried without
## grinding. It is rebuilt on every launch and saved to its own file, so the
## normal `--solo` character is never touched.
##
## Presets: a number (1-50) is that level; `trial` (Trial Hall, 10),
## `corridor` / `fluffy` (the Forbidden Corridor, 35), `max` (50).

const SAVE_PATH := "user://hpmmo_test_character_save.json"
const PRESETS := {"trial": 10, "corridor": 35, "fluffy": 35, "max": 50}
const REFINE_TIER := 9
## Every equipment slot, in the order the bag shows them.
const SLOTS := ["main_hand", "off_hand", "chest", "head", "hands", "feet", "neck", "ring_left", "ring_right", "broom"]

## The `--test-char` value on the command line, "" when absent. A bare
## `--test-char` means the Forbidden Corridor preset.
static func requested() -> String:
	for arg in OS.get_cmdline_args() + OS.get_cmdline_user_args():
		if arg == "--test-char":
			return "corridor"
		if arg.begins_with("--test-char="):
			return arg.substr("--test-char=".length()).strip_edges().to_lower()
	return ""

static func level_for(preset: String) -> int:
	if PRESETS.has(preset):
		return int(PRESETS[preset])
	if preset.is_valid_int():
		return clampi(int(preset), 1, 50)
	push_warning("[TestCharacter] unknown preset '%s', using the corridor preset" % preset)
	return int(PRESETS["corridor"])

static func build(preset: String) -> Dictionary:
	var level := level_for(preset)
	var house := "Gryffindor"
	var gains: Dictionary = HPRules.combat().get("base_stats", {})
	var base_hp := HPRules.base_max_hp(house) + (level - 1) * int(gains.get("level_hp_gain", 45))
	var base_mana := int(gains.get("max_mana", 300)) + (level - 1) * int(gains.get("level_mana_gain", 25))
	var rng := RandomNumberGenerator.new()
	rng.randomize()

	var equipment := {}
	for slot in SLOTS:
		var id := _best_item(slot, level)
		if id != "":
			equipment[slot] = HPEquipment.worn(HPEquipment.instance(id, REFINE_TIER, _bonuses(id, rng)))

	var inventory: Array = []
	for stack in [["potion_health", 200], ["potion_mana", 200], ["scroll_imbue", 50], ["scroll_reweave", 50],
			["mat_phoenix_ash", 99], ["mat_dragon_heartstring", 99], ["mat_thestral_hair", 99], ["mat_elder_core", 99]]:
		if not HPEquipment.item(String(stack[0])).is_empty():
			inventory.append({"id": stack[0], "amount": stack[1], "tier": 0})

	# Every spell mastered; the bonus keeps the point arithmetic at zero spare.
	var skills := {}
	for spell_id in HPRules.upgradeable_skills():
		skills[String(spell_id)] = HPRules.skill_max_level()
	var spent := HPRules.skill_points_spent(skills)

	# The quests below this level count as claimed (with their house standing),
	# so the log offers what fits the character.
	var done: Array = []
	var house_rep := 0
	for quest in HPRules.quest_chain():
		if int(quest.get("level", 1)) < level:
			done.append(String(quest.get("id", "")))
			house_rep += int(quest.get("reward_house_rep", 0))

	return {
		"id": 1,
		"name": "Tester",
		"house": house,
		"level": level,
		"exp": 0,
		"base_max_hp": base_hp,
		"base_max_mana": base_mana,
		"max_hp": base_hp,
		"current_hp": base_hp,
		"max_mana": base_mana,
		"current_mana": base_mana,
		"galleons": 10000000,
		"wand_tier": 0,
		"rot_y": PI,
		"equipment": equipment,
		"equipment_version": 1,
		"inventory": inventory,
		"inventory_revision": 1,
		"quests": {
			"done": done,
			"ready": [],
			"progress": {},
			"house_rep": HPRules.clamp_house_rep(house_rep),
			"skills": skills,
			"skill_bonus": maxi(0, spent - level),
			"skills_v2": true,
			"attributes": {},
			"titles": [],
		},
	}

## The highest-level item for `slot` the character may wear (authored
## `required_level`; legacy items without one are skipped).
static func _best_item(slot: String, level: int) -> String:
	var best := ""
	var best_level := -1
	var catalog := HPEquipment.catalog()
	for id in catalog:
		var entry = catalog[id]
		if not entry is Dictionary or not (entry as Dictionary).has("required_level"):
			continue
		if not HPEquipment.fits(String(id), slot):
			continue
		var need := int(entry.get("required_level", 1))
		if need <= level and need > best_level:
			best = String(id)
			best_level = need
	return best

static func _bonuses(id: String, rng: RandomNumberGenerator) -> Array:
	var held: Array = []
	if not HPEquipment.enchantable(id):
		return held
	for i in int(HPEquipment.enchant_rules().get("max_bonuses", 5)):
		var bonus := HPEquipment.roll_bonus(id, held, rng)
		if bonus.is_empty():
			break
		held.append(bonus)
	return held
