extends RefCounted
class_name HPRules

## Single implementation of every gameplay rule that the world server and the
## clients must agree on: faction/protection gating, spell maths, status effects,
## movement limits, aggro policy, spawn regions and loot rolls.
##
## OWNER: server repository (synced to the client by `dev.ps1 sync-sim`).
## Nothing here touches the scene tree except the two pure queries that take
## nodes (`can_damage`, `has_line_of_sight`), which are safe on both sides.

const DATA_DIR := "res://addons/hpmmo_sim/data/"

static var _spells: Dictionary = {}
static var _combat: Dictionary = {}
static var _zones: Dictionary = {}
static var _spawns: Dictionary = {}
static var _loot: Dictionary = {}
static var _quests: Dictionary = {}
static var _mobs: Dictionary = {}

static var _loaded := false

# ---------------------------------------------------------------- data access

static func ensure_loaded() -> void:
	if _loaded:
		return
	_spells = _read_json(DATA_DIR + "spells.json")
	_combat = _read_json(DATA_DIR + "combat.json")
	_zones = _read_json(DATA_DIR + "safe_zones.json")
	_spawns = _read_json(DATA_DIR + "spawn_tables.json")
	_loot = _read_json(DATA_DIR + "loot_tables.json")
	_quests = _read_json(DATA_DIR + "quests.json")
	_mobs = _read_json(DATA_DIR + "mobs.json")
	_loaded = true

static func reload() -> void:
	_loaded = false
	ensure_loaded()

static func _read_json(path: String) -> Dictionary:
	if not FileAccess.file_exists(path):
		push_error("[HPRules] missing data file: %s" % path)
		return {}
	var file := FileAccess.open(path, FileAccess.READ)
	if file == null:
		push_error("[HPRules] cannot open data file: %s" % path)
		return {}
	var parsed: Variant = JSON.parse_string(file.get_as_text())
	file.close()
	if parsed is Dictionary:
		return parsed
	push_error("[HPRules] malformed data file: %s" % path)
	return {}

static func spells() -> Dictionary:
	ensure_loaded()
	return _spells

static func spell(id: String) -> Dictionary:
	ensure_loaded()
	return _spells.get(id, {})

static func spell_ids() -> Array:
	ensure_loaded()
	return _spells.keys()

static func combat() -> Dictionary:
	ensure_loaded()
	return _combat

static func zones() -> Dictionary:
	ensure_loaded()
	return _zones

static func spawn_tables() -> Dictionary:
	ensure_loaded()
	return _spawns

# ----------------------------------------------------- encounter templates
# Encounters are data. These accessors are the ONE resolution path
# both the director and the tests use, so "pack size 3 or 5", "exactly two
# escorts" and "maximum alive" cannot drift between the two.

static func encounter_templates() -> Dictionary:
	ensure_loaded()
	return _spawns.get("templates", {})

static func encounter_template(template_id: String) -> Dictionary:
	ensure_loaded()
	return (encounter_templates() as Dictionary).get(template_id, {})

## The template an authored encounter entry resolves to. An entry that names no
## template resolves to the template whose pack_size matches its count, so older
## data keeps working while the authored table stays the source of truth.
static func template_for(pack: Dictionary) -> Dictionary:
	ensure_loaded()
	var named := encounter_template(String(pack.get("template", "")))
	if not named.is_empty():
		return named
	for _id in encounter_templates().keys():
		var candidate: Dictionary = encounter_templates()[_id]
		if int(candidate.get("pack_size", -1)) == int(pack.get("count", 0)):
			return candidate
	return {}

static func encounter_list() -> Array:
	ensure_loaded()
	return _spawns.get("packs", [])

static func encounter_by_id(encounter_id: String) -> Dictionary:
	ensure_loaded()
	for entry in encounter_list():
		if String(entry.get("encounter_id", "")) == encounter_id:
			return entry
	return {}

static func encounter_max_alive(pack: Dictionary) -> int:
	var template := template_for(pack)
	return int(pack.get("max_alive", template.get("max_alive", pack.get("count", 1))))

static func encounter_escorts(pack: Dictionary) -> int:
	var template := template_for(pack)
	return int(pack.get("escorts", template.get("escorts", 0)))

static func is_boss_encounter(pack: Dictionary) -> bool:
	var template := template_for(pack)
	return bool(pack.get("boss", template.get("boss", false)))

## Long respawn flag from the template ("boss" | "pack").
static func encounter_respawn_kind(pack: Dictionary) -> String:
	var template := template_for(pack)
	return String(template.get("respawn", "boss" if is_boss_encounter(pack) else "pack"))

static func boss_patterns() -> Dictionary:
	ensure_loaded()
	return _spawns.get("boss_patterns", {})

static func attack_patterns_for(style: String) -> Array:
	var table := boss_patterns()
	return table.get(style, table.get("spider", []))

# ------------------------------------------------------------------ regions

static func regions() -> Array:
	ensure_loaded()
	return _spawns.get("regions", [])

static func region_by_id(zone_id: String) -> Dictionary:
	ensure_loaded()
	for region in regions():
		if String(region.get("id", "")) == zone_id:
			return region
	return {}

## The separate "number of packs in this region" setting.
static func region_pack_count(zone_id: String) -> int:
	var region := region_by_id(zone_id)
	return int(region.get("pack_count", 0))

static func region_weight(zone_id: String) -> float:
	return float(region_by_id(zone_id).get("weight", 1.0))

## Weighted region choice: an encounter that lists `zones` (id + weight) has its
## region drawn from that distribution with the authority RNG; one that lists a
## fixed `zone` keeps it. The draw is part of the seeded spawn sequence, so a
## recorded debug seed replays the same placement.
static func resolve_encounter_zone(pack: Dictionary, rng: RandomNumberGenerator) -> String:
	var fixed := String(pack.get("zone", ""))
	var zones: Array = pack.get("zones", [])
	if zones.is_empty():
		return fixed
	var total := 0.0
	for entry in zones:
		total += maxf(0.0, float((entry as Dictionary).get("weight", 0.0)))
	if total <= 0.0:
		return fixed
	var roll := rng.randf() * total
	for entry in zones:
		roll -= maxf(0.0, float((entry as Dictionary).get("weight", 0.0)))
		if roll <= 0.0:
			return String((entry as Dictionary).get("id", fixed))
	return String((zones[zones.size() - 1] as Dictionary).get("id", fixed))

## The rect an encounter samples inside, resolved for the zone that was chosen:
## a fixed-zone encounter keeps its authored `area`, a weighted one samples the
## chosen region's `spawn_area` (falling back to `area` when a region has none).
static func encounter_area(pack: Dictionary, zone_id: String) -> Array:
	var fallback: Array = pack.get("area", [0.0, 0.0, 1.0, 1.0])
	if zone_id == String(pack.get("zone", "")):
		return fallback
	var region := region_by_id(zone_id)
	var area: Array = region.get("spawn_area", [])
	if area.size() != 4 or absf(float(area[2])) < 0.01:
		return fallback
	return area

static func debug_seed() -> int:
	ensure_loaded()
	return int(_spawns.get("debug_seed", 0))

static func pack_tuning(key: String, fallback: float) -> float:
	ensure_loaded()
	return float((_spawns.get("pack_tuning", {}) as Dictionary).get(key, fallback))

# --------------------------------------------------- spawn turn-down volumes

static func exclusions() -> Array:
	ensure_loaded()
	return _spawns.get("exclusions", [])

## Id of the exclusion volume containing `point` ("" when it is clear). Water
## and portal arrival pads are turn-down volumes for encounter placement.
static func exclusion_at(point: Vector3) -> String:
	for entry in exclusions():
		var volume: Dictionary = entry
		var center: Array = volume.get("center", [0.0, 0.0, 0.0])
		if center.size() != 3:
			continue
		var dx := point.x - float(center[0])
		var dz := point.z - float(center[2])
		if String(volume.get("shape", "cylinder")) == "box":
			var half: Array = volume.get("half_extents", [1.0, 1.0, 1.0])
			if absf(dx) <= float(half[0]) and absf(point.y - float(center[1])) <= float(half[1]) and absf(dz) <= float(half[2]):
				return String(volume.get("id", ""))
			continue
		var radius := float(volume.get("radius", 0.0))
		if (dx * dx + dz * dz) <= radius * radius:
			return String(volume.get("id", ""))
	return ""

## Bounded formation offsets for a pack of `count` members around its anchor.
## One member is the anchor; an escorted boss keeps the boss on the anchor with
## its escorts flanking it.
static func formation_offsets(count: int, escorts: int = 0) -> Array:
	var spacing := pack_tuning("pack_spacing", 3.1)
	var out: Array = []
	if count <= 1:
		out.append(Vector3.ZERO)
		return out
	if escorts > 0:
		out.append(Vector3.ZERO)
		for i in range(escorts):
			var angle := -0.35 * PI + float(i) * (0.7 * PI / maxf(1.0, float(escorts - 1)))
			out.append(Vector3(cos(angle), 0.0, sin(angle)) * spacing)
		while out.size() < count:
			out.append(Vector3.ZERO)
		return out
	for i in range(count):
		out.append(Vector3(cos(i * TAU / count), 0.0, sin(i * TAU / count)) * spacing)
	return out

## Data integrity report for the authored encounter table (used by the director
## at boot and asserted by encounters_sim.py). An entry that claims a template
## of another size, an escorted boss without exactly two escorts, a pack over
## its maximum alive count, or a region that wants more packs than are authored
## is a data error, not a runtime surprise.
static func validate_encounters() -> Dictionary:
	ensure_loaded()
	var problems: Array = []
	var per_region: Dictionary = {}
	for entry in encounter_list():
		var pack: Dictionary = entry
		var encounter_id := String(pack.get("encounter_id", "pack#%s" % str(pack.get("id", "?"))))
		var template := template_for(pack)
		if template.is_empty():
			problems.append("%s: no template resolves" % encounter_id)
			continue
		if int(pack.get("count", 0)) != int(template.get("pack_size", -1)):
			problems.append("%s: count %d != template pack_size %d" % [
				encounter_id, int(pack.get("count", 0)), int(template.get("pack_size", -1))])
		if encounter_max_alive(pack) > int(pack.get("count", 0)):
			problems.append("%s: max_alive %d exceeds pack size %d" % [
				encounter_id, encounter_max_alive(pack), int(pack.get("count", 0))])
		if is_boss_encounter(pack) and bool(template.get("boss", false)) == false:
			problems.append("%s: boss flag without a boss template" % encounter_id)
		if encounter_escorts(pack) not in [0, 2]:
			problems.append("%s: escort count must be 0 or exactly 2" % encounter_id)
		var zone := String(pack.get("zone", ""))
		per_region[zone] = int(per_region.get(zone, 0)) + 1
		for species in pack_species(pack):
			if mob_def(String(species)).is_empty():
				problems.append("%s: mob '%s' is not in mobs.json" % [encounter_id, species])
		var band := region_level_band(zone)
		if not band.is_empty() and not is_boss_encounter(pack):
			var level := int(pack.get("level", 1))
			if level < int(band[0]) or level > int(band[1]):
				problems.append("%s: level %d outside region %s band %d-%d" % [
					encounter_id, level, zone, int(band[0]), int(band[1])])
	for region in regions():
		var id := String(region.get("id", ""))
		var authored := int(per_region.get(id, 0))
		var wanted := int(region.get("pack_count", 0))
		if wanted > authored:
			problems.append("region %s: pack_count %d but only %d encounters authored" % [id, wanted, authored])
	return {"ok": problems.is_empty(), "problems": problems, "authored_per_region": per_region}

## Active encounters for a region: the first `pack_count` authored entries, in
## authored order. The rest stay dormant (authored content waiting for a tuning
## change) and are reported rather than silently dropped.
static func active_encounters_for(zone_id: String) -> Array:
	var out: Array = []
	var count := region_pack_count(zone_id)
	for entry in encounter_list():
		if String((entry as Dictionary).get("zone", "")) != zone_id:
			continue
		if out.size() >= count:
			break
		out.append(entry)
	return out

static func loot_tables() -> Dictionary:
	ensure_loaded()
	return _loot

static func wand_multiplier(tier: int) -> float:
	ensure_loaded()
	var tiers: Array = _combat.get("wand_tiers", [])
	var t := clampi(tier, 0, maxi(0, tiers.size() - 1))
	for entry in tiers:
		if int(entry.get("tier", -1)) == t:
			return float(entry.get("multiplier", 1.0))
	return 1.0

static func house_modifier(house: String, key: String, default_value: float = 1.0) -> float:
	ensure_loaded()
	var houses: Dictionary = _combat.get("houses", {})
	var entry: Dictionary = houses.get(house, {})
	return float(entry.get(key, default_value))

static func house_spell_damage(house: String, spell_id: String) -> float:
	ensure_loaded()
	var houses: Dictionary = _combat.get("houses", {})
	var entry: Dictionary = houses.get(house, {})
	var table: Dictionary = entry.get("spell_damage", {})
	return float(table.get(spell_id, 1.0))

static func base_max_hp(house: String) -> int:
	ensure_loaded()
	var base: Dictionary = _combat.get("base_stats", {})
	return int(float(base.get("max_hp", 500)) * house_modifier(house, "hp_multiplier"))

static func base_max_mana(house: String) -> int:
	ensure_loaded()
	var base: Dictionary = _combat.get("base_stats", {})
	return int(float(base.get("max_mana", 300)) * house_modifier(house, "mana_multiplier"))

static func regen_hp_per_second() -> float:
	ensure_loaded()
	return float((_combat.get("regeneration", {}) as Dictionary).get("hp_per_second", 4.0))

static func regen_mana_per_second(house: String) -> float:
	ensure_loaded()
	var regen: Dictionary = _combat.get("regeneration", {})
	if house == "Slytherin":
		return float(regen.get("mana_per_second_slytherin", 10.0))
	return float(regen.get("mana_per_second", 8.0))

static func respawn_ms() -> int:
	ensure_loaded()
	return int((_combat.get("death", {}) as Dictionary).get("respawn_ms", 2500))

## With no choice from the player, a dead body returns to town after this.
static func auto_respawn_ms() -> int:
	ensure_loaded()
	return int((_combat.get("death", {}) as Dictionary).get("auto_respawn_ms", 180000))

## Share of max hp/mana a "revive here" comes back with.
static func revive_here_fraction() -> float:
	ensure_loaded()
	return clampf(float((_combat.get("death", {}) as Dictionary).get("revive_here_fraction", 0.5)), 0.05, 1.0)

static func revive_here_ward_ms() -> int:
	ensure_loaded()
	return int((_combat.get("death", {}) as Dictionary).get("revive_here_ward_ms", 3000))

static func respawn_position() -> Vector3:
	ensure_loaded()
	var raw: Array = (_combat.get("death", {}) as Dictionary).get("respawn_position", [0.0, 0.5, 5.0])
	if raw.size() != 3:
		return Vector3(0.0, 0.5, 5.0)
	return Vector3(float(raw[0]), float(raw[1]), float(raw[2]))

## `stats` carries the caster's attack_speed / cast_speed (derived stats or the
## authority record): attack speed shortens the basic attack, casting speed
## every other spell.
static func cooldown_for(spell_id: String, house: String, skill_level: int = 1, stats: Dictionary = {}) -> float:
	var data := spell(spell_id)
	if data.is_empty():
		return 0.0
	var cd := float(data.get("cooldown", 0.0)) * house_modifier(house, "cooldown_multiplier") * skill_cooldown_multiplier(skill_level)
	if spell_id == "basic_cast":
		cd /= 1.0 + maxf(0.0, float(stats.get("attack_speed", 0.0))) / 100.0
	else:
		cd *= 1.0 - clampf(float(stats.get("cast_speed", 0.0)), 0.0, 90.0) / 100.0
	return cd

static func max_level() -> int:
	ensure_loaded()
	return int((_combat.get("limits", {}) as Dictionary).get("max_level", 100))

static func max_item_amount() -> int:
	ensure_loaded()
	return int((_combat.get("limits", {}) as Dictionary).get("max_item_amount", 9999))

static func max_inventory_kinds() -> int:
	ensure_loaded()
	return int((_combat.get("limits", {}) as Dictionary).get("max_inventory_kinds", 40))

static func max_exp() -> int:
	ensure_loaded()
	return int((_combat.get("base_stats", {}) as Dictionary).get("max_exp", 2000000000))

## EXP required to leave `level`: one ordinary creature's experience at that
## level x the kills a level should take (combat.json base_stats.exp_curve),
## rounded to 10. Without exp_curve, the old exponential growth curve.
static func exp_threshold(level: int) -> int:
	ensure_loaded()
	var base: Dictionary = _combat.get("base_stats", {})
	var curve: Dictionary = base.get("exp_curve", {})
	if not curve.is_empty():
		var lv := maxi(1, level)
		var kills := float(curve.get("kills_base", 10)) + float(curve.get("kills_per_level", 10)) * float(lv - 1)
		return mini(max_exp(), int(round(float(pack_exp_reward(lv)) * kills / 10.0)) * 10)
	var value := float(base.get("exp_base", 200))
	var growth := float(base.get("exp_growth", 1.5))
	var cap := float(max_exp())
	for _i in range(maxi(0, level - 1)):
		value = minf(cap, value * growth)
	return int(value)

# ------------------------------------------------------------ house standing

## House standing is a second progression track beside the character level:
## reputation with the character's own house, earned only from quests, read as
## a rank 1..max_house_rank(). Gated content (spells, later potions and skill
## upgrades) names the rank it needs and asks `house_rank_meets`.
static func _house_thresholds() -> Array:
	ensure_loaded()
	var table: Array = (_combat.get("house_ranks", {}) as Dictionary).get("thresholds", [0])
	return table if not table.is_empty() else [0]

static func max_house_rank() -> int:
	return _house_thresholds().size()

## Reputation stops at the top threshold: there is nothing past the last rank.
static func max_house_rep() -> int:
	var table := _house_thresholds()
	return int(table[table.size() - 1])

static func clamp_house_rep(rep: int) -> int:
	return clampi(rep, 0, max_house_rep())

static func house_rank_for(rep: int) -> int:
	var table := _house_thresholds()
	var rank := 1
	for i in range(table.size()):
		if rep >= int(table[i]):
			rank = i + 1
	return rank

## Total reputation needed to hold `rank` (rank 1 needs nothing).
static func house_rank_threshold(rank: int) -> int:
	var table := _house_thresholds()
	return int(table[clampi(rank, 1, table.size()) - 1])

static func house_rank_title(rank: int) -> String:
	ensure_loaded()
	var titles: Array = (_combat.get("house_ranks", {}) as Dictionary).get("titles", [])
	var i := clampi(rank, 1, max_house_rank()) - 1
	return String(titles[i]) if i < titles.size() else "Rank %d" % (i + 1)  # i18n

static func house_rank_meets(rep: int, required_rank: int) -> bool:
	return house_rank_for(rep) >= required_rank

## The house rank a spell needs before it may be cast (1 = always allowed).
static func spell_house_rank(spell_id: String) -> int:
	return int(spell(spell_id).get("requires_house_rank", 1))

# ------------------------------------------------------------ skill training
##
## Metin2-style: one skill point per level above 1, spent one at a time on an
## upgradeable spell (combat.json `skills`). A character's levels live in a
## {spell_id: level} dictionary; a spell missing from it is level 1.

static func skill_rules() -> Dictionary:
	ensure_loaded()
	return _combat.get("skills", {})

static func skill_max_level() -> int:
	return int(skill_rules().get("max_level", 10))

static func skill_master_level() -> int:
	return int(skill_rules().get("master_level", skill_max_level()))

static func upgradeable_skills() -> Array:
	return skill_rules().get("upgradeable", [])

static func skill_upgradeable(spell_id: String) -> bool:
	return upgradeable_skills().has(spell_id)

## The level of one skill in a levels dictionary, 0 (not learned) .. max. A
## spell that is not upgradeable (the basic attack, Patronum) is always 1.
static func skill_level_of(levels: Dictionary, spell_id: String) -> int:
	if not skill_upgradeable(spell_id):
		return 1
	return clampi(int(levels.get(spell_id, 0)), 0, skill_max_level())

## True when the caster may use the spell at all (learned, or not a skill).
static func skill_learned(levels: Dictionary, spell_id: String) -> bool:
	return skill_level_of(levels, spell_id) >= 1

## A saved/received levels object reduced to known skills with valid levels
## (learned skills only; a missing skill is level 0).
static func clean_skill_levels(raw: Variant) -> Dictionary:
	var out := {}
	if raw is Dictionary:
		for spell_id in upgradeable_skills():
			var level := clampi(int((raw as Dictionary).get(spell_id, 0)), 0, skill_max_level())
			if level >= 1:
				out[spell_id] = level
	return out

## Every learned level costs one point (learning a skill is its first level).
static func skill_points_spent(levels: Dictionary) -> int:
	var spent := 0
	for spell_id in upgradeable_skills():
		spent += skill_level_of(levels, spell_id)
	return spent

## Unspent points: one per character level (the level-1 point is the starter
## skill a new character picks), plus `bonus` (characters from before skills
## had to be learned keep every spell and every point they had), minus spent.
static func skill_points_available(character_level: int, levels: Dictionary, bonus: int = 0) -> int:
	return maxi(0, maxi(1, character_level) + bonus - skill_points_spent(levels))

static func skill_is_master(level: int) -> bool:
	return level >= skill_master_level()

## What a hotbar badge / the skill window prints: "1".."9", then "M".
static func skill_level_label(level: int) -> String:
	return "M" if skill_is_master(level) else str(maxi(1, level))

static func skill_damage_multiplier(level: int) -> float:
	var rules := skill_rules()
	var lv := clampi(level, 1, skill_max_level())
	var mult := 1.0 + float(rules.get("damage_per_level", 0.0)) * float(lv - 1)
	if skill_is_master(lv):
		mult += float(rules.get("master_damage_bonus", 0.0))
	return mult

static func skill_cooldown_multiplier(level: int) -> float:
	var lv := clampi(level, 1, skill_max_level())
	return maxf(0.25, 1.0 - float(skill_rules().get("cooldown_per_level", 0.0)) * float(lv - 1))

## Duration scaling for a skill's lasting effect (ward, stun, weaken).
static func skill_effect_multiplier(level: int) -> float:
	var lv := clampi(level, 1, skill_max_level())
	return 1.0 + float(skill_rules().get("effect_per_level", 0.0)) * float(lv - 1)

# ------------------------------------------------------------ attributes

## combat.json `attributes`: Vitality / Intellect / Strength / Agility points
## (Metin2 status points), `points_per_level` per level gained.
static func attribute_rules() -> Dictionary:
	ensure_loaded()
	return _combat.get("attributes", {})

static func attribute_ids() -> Array:
	return (attribute_rules().get("stats", {}) as Dictionary).keys()

## A saved/received attribute object reduced to known stats with valid values.
static func clean_attributes(raw: Variant) -> Dictionary:
	var out := {}
	var cap := int(attribute_rules().get("max", 90))
	if raw is Dictionary:
		for id in attribute_ids():
			var value := clampi(int((raw as Dictionary).get(id, 0)), 0, cap)
			if value > 0:
				out[id] = value
	return out

# ------------------------------------------------------------------ look
## A character's appearance (v28): picked at creation, saved as `quests.look`,
## shown to every player through player info. Palettes are indices so a look
## is a few small numbers; sliders are floats in their range. The client maps
## them onto the hero model (HeroAppearance.apply_look): hair meshes, shader
## tints and blend shapes.
## New styles go at the end: a saved look keeps its index.
const LOOK_HAIR_STYLES := ["SimpleParted", "Buzzed", "Long", "none", "Wavy", "Tousled", "Neat", "Ponytail", "Curly"]
## Outfits: the Hero_<Outfit>_* meshes of the hero model, each with two
## textures; the main cloth takes the wearer's house colour.
const LOOK_OUTFITS := ["peasant", "peasant_2", "ranger", "ranger_3"]
## Facial hair: a beard shade painted on the skin (stubble, short) or the kit's
## beard mesh (full, Hero_Beard_Full); it takes the hair colour.
const LOOK_BEARDS := ["none", "stubble", "short", "full"]
## Eyebrows: five painted on the skin (Hero_BrowPaint tiles) and the kit's two
## brow meshes (the Superhero head's own, the Regular ones).
const LOOK_BROWS := ["natural", "bushy", "arched", "thin", "angular", "classic", "classic_straight"]
const LOOK_HAIR_COLORS := ["2b1d16", "120d0b", "4b3122", "6e3b1f", "9a4f26", "b9874f", "dcc08a", "e9e4da", "7e7a76"]
const LOOK_EYE_COLORS := ["6f8088", "4c78b0", "3f7d58", "6a4a2d", "a77f3d", "2e3d62", "8b8f93"]
const LOOK_SKIN_TONES := ["ffffff", "f1ded3", "dcc0ab", "b8977f", "8f7160", "62503f"]
## slider -> [min, max]
## Face sliders are MakeHuman targets on the head (face_<key>_neg/_pos shape
## keys, art/characters/hero_q/face_morphs.py).
const LOOK_SLIDERS := {"height": [-1.0, 1.0], "jaw": [-1.0, 1.0], "chin": [-1.0, 1.0], "chin_height": [-1.0, 1.0],
	"cheekbones": [-1.0, 1.0], "cheeks": [-1.0, 1.0], "nose_length": [-1.0, 1.0], "nose_width": [-1.0, 1.0],
	"nose_bridge": [-1.0, 1.0], "lips": [-1.0, 1.0], "brow_ridge": [-1.0, 1.0]}
## Face types: MakeHuman whole-face targets (face_type_<name> shape keys).
const LOOK_FACES := ["default", "oval", "round", "square", "triangular", "diamond"]

static func default_look() -> Dictionary:
	var look := {"hair": 0, "hair_color": 0, "eyes": 0, "skin": 0, "outfit": 0, "beard": 0, "brows": 0, "face": 0}
	for key: String in LOOK_SLIDERS:
		look[key] = 0.0
	return look

## A saved/received look reduced to known keys with valid values; anything
## missing or out of range falls back to the default, so an old save or a
## crafted request can never name a mesh or colour that does not exist.
static func clean_look(raw: Variant) -> Dictionary:
	var out := default_look()
	if not (raw is Dictionary):
		return out
	var src := raw as Dictionary
	for key_size in [["hair", LOOK_HAIR_STYLES.size()], ["hair_color", LOOK_HAIR_COLORS.size()],
			["eyes", LOOK_EYE_COLORS.size()], ["skin", LOOK_SKIN_TONES.size()], ["outfit", LOOK_OUTFITS.size()],
			["beard", LOOK_BEARDS.size()], ["brows", LOOK_BROWS.size()], ["face", LOOK_FACES.size()]]:
		var key: String = key_size[0]
		if src.has(key) and (src[key] is int or src[key] is float):
			out[key] = clampi(int(src[key]), 0, int(key_size[1]) - 1)
	for key in LOOK_SLIDERS:
		if src.has(key) and (src[key] is int or src[key] is float):
			var span: Array = LOOK_SLIDERS[key]
			# two decimals: a look travels in every player-info packet
			out[key] = snappedf(clampf(float(src[key]), float(span[0]), float(span[1])), 0.01)
	return out

static func attribute_points_available(character_level: int, attributes: Dictionary) -> int:
	var spent := 0
	for id in attributes:
		spent += int(attributes[id])
	return maxi(0, (maxi(1, character_level) - 1) * int(attribute_rules().get("points_per_level", 2)) - spent)

# ------------------------------------------------------------ quests

## The quest chain, in order. The authority walks it; clients only display it.
static func quest_chain() -> Array:
	ensure_loaded()
	return _quests.get("chain", [])

## The quest at a chain position, or {} past the end.
static func quest_at(index: int) -> Dictionary:
	var chain := quest_chain()
	return chain[index] if index >= 0 and index < chain.size() else {}

static func quest_by_id(quest_id: String) -> Dictionary:
	for quest in quest_chain():
		if String(quest.get("id", "")) == quest_id:
			return quest
	return {}

## The quests a character can work on now: reached their level, every quest
## they `require` claimed, and neither claimed (`done`) nor waiting to be
## claimed (`ready`). Several are open at once; they accumulate.
static func quests_open(character_level: int, done: Array, ready: Array) -> Array:
	var out: Array = []
	# Sets, not Array.has: the chain is ~100 quests and the log as long, and this
	# runs on every kill and every visit check of every player.
	var done_set := {}
	for id in done:
		done_set[String(id)] = true
	var ready_set := {}
	for id in ready:
		ready_set[String(id)] = true
	for quest in quest_chain():
		var id := String(quest.get("id", ""))
		if done_set.has(id) or ready_set.has(id) or int(quest.get("level", 1)) > character_level:
			continue
		var blocked := false
		for need in quest.get("requires", []):
			if not done_set.has(String(need)):
				blocked = true
				break
		if not blocked:
			out.append(quest)
	return out

static func quest_talk_radius() -> float:
	ensure_loaded()
	return float(_quests.get("talk_radius", 6.0))

## Named places a visit quest can target: {map, center: [x, z], radius}.
static func quest_places() -> Dictionary:
	ensure_loaded()
	return _quests.get("places", {})

## The place containing (map, pos), or "" (x/z distance; height is ignored so a
## flying broom still counts).
static func quest_place_at(map_id: String, pos: Vector3) -> String:
	var places := quest_places()
	for place in places.keys():
		var area: Dictionary = places[place]
		var center: Array = area.get("center", [0, 0])
		var center_xz := Vector2(float(center[0]), float(center[1]))
		if String(area.get("map", HPProtocol.DEFAULT_MAP)) == map_id and Vector2(pos.x, pos.z).distance_to(center_xz) <= float(area.get("radius", 0.0)):
			return String(place)
	return ""

# ------------------------------------------------------------ spell maths

## Full damage multiplier for a cast, matching the values the client used before
## authority moved to the server (wand tier, combo step, house affinity).
static func damage_multiplier(spell_id: String, wand_tier: int, house: String, combo_multiplier: float = 1.0, skill_level: int = 1) -> float:
	return wand_multiplier(wand_tier) * combo_multiplier * house_spell_damage(house, spell_id) * skill_damage_multiplier(skill_level)

## `weapon_roll` is one roll of the wand range the spell draws on (weapon_range_key)
## at +0; it joins the spell's base damage x magic_attack_coef before every
## multiplier, so +N scales both together.
static func spell_damage(spell_id: String, wand_tier: int, house: String, combo_multiplier: float = 1.0, skill_level: int = 1, weapon_roll: float = 0.0) -> int:
	var data := spell(spell_id)
	if data.is_empty():
		return 0
	var base := float(data.get("damage", 0)) + weapon_roll * float(data.get("magic_attack_coef", 1.0))
	return int(base * damage_multiplier(spell_id, wand_tier, house, combo_multiplier, skill_level))

## Which wand range a spell rolls: the basic attack uses the Attack Value, every
## other spell the Magic Attack Value.
static func weapon_range_key(spell_id: String) -> String:
	return "attack_value" if spell_id == "basic_cast" else "magic_attack"

## combat.json item_stats: armour, resistance and speed rules for item stats.
static func item_rules() -> Dictionary:
	return combat().get("item_stats", {})

## Damage fraction armour removes from a hit by a level `attacker_level` creature.
static func armor_reduction(armor: float, attacker_level: int) -> float:
	var rules := item_rules()
	if armor <= 0.0:
		return 0.0
	var k := float(rules.get("armor_base", 100)) + float(rules.get("armor_per_level", 8)) * float(maxi(1, attacker_level))
	return minf(armor / (armor + k), float(rules.get("armor_max_reduction", 75)) / 100.0)

## "melee", "projectile" or "spell" for a creature attack id.
static func mob_attack_kind(spell_id: String) -> String:
	return String((item_rules().get("mob_attack_kinds", {}) as Dictionary).get(spell_id, "spell"))

## Damage after per-victim modifiers. `resist` is the victim's mobs.json
## resistance map (element -> reduction fraction, -1.0 = double damage); the
## legacy `weak_to_fire` flag still means fire x2 when no fire entry is given.
static func damage_after_resistances(raw: int, spell_id: String, weak_to_fire: bool, resist: Dictionary = {}) -> int:
	var element := spell_element(spell_id)
	var factor := resist_factor(resist, element)
	if weak_to_fire and element == "fire" and not resist.has("fire"):
		factor = 2.0
	return int(round(float(raw) * factor))

## The element a spell deals (spells.json `element`; "arcane" when unset).
static func spell_element(spell_id: String) -> String:
	return String(spell(spell_id).get("element", "arcane"))

## Damage factor for one element: 1 - resist, clamped to [0, 3].
static func resist_factor(resist: Dictionary, element: String) -> float:
	return clampf(1.0 - float(resist.get(element, 0.0)), 0.0, 3.0)

static func aoe_falloff(distance: float, radius: float, floor_ratio: float) -> float:
	if radius <= 0.0:
		return 1.0
	return clampf(1.0 - distance / radius, floor_ratio, 1.0)

static func knockback_force(spell_id: String, push_dir: Vector3) -> Vector3:
	var data := spell(spell_id)
	var magnitude := float(data.get("knockback", 0.0))
	if magnitude <= 0.0:
		return Vector3.ZERO
	var flat := Vector3(push_dir.x, 0.15, push_dir.z)
	if flat.length_squared() < 0.0001:
		return Vector3.ZERO
	return flat.normalized() * magnitude

static func stun_ms(spell_id: String, is_boss: bool) -> int:
	var data := spell(spell_id)
	if data.is_empty():
		return 0
	if is_boss:
		return int(data.get("stun_ms_boss", data.get("stun_ms", 0)))
	return int(data.get("stun_ms", 0))

static func burn_spec(spell_id: String) -> Dictionary:
	return spell(spell_id).get("burn", {})

static func weaken_ms(spell_id: String) -> int:
	return int(spell(spell_id).get("weaken_ms", 0))

static func weaken_factor(spell_id: String) -> float:
	return float(spell(spell_id).get("weaken_factor", 1.0))

## The damage-over-time ticks (they carry no crowd control and roll no procs).
static func is_damage_over_time(spell_id: String) -> bool:
	return spell_id == "burn" or spell_id == "poison" or spell_id == "bleed"

## Glacius-style freeze (spells.json `freeze_ms` / `freeze_ms_boss`): the body
## cannot move, act or animate while it runs.
static func freeze_ms(spell_id: String, is_boss: bool) -> int:
	var data := spell(spell_id)
	if is_boss:
		return int(data.get("freeze_ms_boss", data.get("freeze_ms", 0)))
	return int(data.get("freeze_ms", 0))

## A spell's slow (`slow` {ms, factor, boss_ms}); empty when it has none. A
## freeze's slow starts when the ice thaws (the chill after Glacius).
static func slow_spec(spell_id: String) -> Dictionary:
	return spell(spell_id).get("slow", {})

## A spell's bleed (`bleed` {damage, ticks, interval_ms, hit_share}).
static func bleed_spec(spell_id: String) -> Dictionary:
	return spell(spell_id).get("bleed", {})

## A spell's launch (`launch` {push, lift, land_stun_ms}): the victim is thrown
## `push` m/s away from the blast and `lift` m/s up, cannot act in the air, and
## lies stunned for `land_stun_ms` after it lands.
static func launch_spec(spell_id: String) -> Dictionary:
	return spell(spell_id).get("launch", {})

## How far a creature resists being thrown (mobs.json `displace_resist`, 1 =
## never moves). Bosses and rooted bodies are never thrown.
static func displace_scale(species: String, is_boss: bool) -> float:
	if is_boss:
		return 0.0
	return clampf(1.0 - float(mob_def(species).get("displace_resist", 0.0)), 0.0, 1.0)

## Gravity a thrown body falls under (mob_base and player.gd use the same).
const LAUNCH_GRAVITY := 24.0

## How long a throw of `lift` m/s keeps a body in the air (it lands where it
## took off), at least `floor_ms`: the window in which it cannot act.
static func airborne_ms(lift: float, floor_ms := 350) -> int:
	return maxi(floor_ms, int(round(2.0 * maxf(0.0, lift) / LAUNCH_GRAVITY * 1000.0)))

## How long a shove of `force` (authority push_player) keeps a player from
## acting: the time up in the air, or a flat push's slide. The authority and the
## owner's prediction use the same number.
static func shove_lock_ms(force: Vector3) -> int:
	return airborne_ms(maxf(0.0, force.y), int(clampf(Vector2(force.x, force.z).length() * 70.0, 300.0, 700.0)))

## A mob's resistance to crowd control (resist.stun; 1.0 = immune, negative =
## longer). Scales every stun, freeze and landing stun on that creature.
static func cc_scale(resist: Dictionary) -> float:
	return clampf(1.0 - float(resist.get("stun", 0.0)), 0.0, 2.0)

## Character level a spell unlocks at (spells.json `requires_level`, 1 = always).
static func spell_required_level(spell_id: String) -> int:
	return int(spell(spell_id).get("requires_level", 1))

## Creature families a spell banishes: a hit cancels that creature's attack
## (Expecto Patronum breaks a dementor's kiss).
static func spell_banishes(spell_id: String, family: String) -> bool:
	return family != "" and (spell(spell_id).get("banishes", []) as Array).has(family)

static func spell_interrupts(spell_id: String) -> bool:
	return bool(spell(spell_id).get("interrupts", false))

static func ward_duration_ms(spell_id: String) -> int:
	return int(spell(spell_id).get("duration_ms", 0))

static func ward_projectile_rule(spell_id: String) -> String:
	return String(spell(spell_id).get("projectile_rule", "reflect"))

static func ward_other_multiplier(spell_id: String) -> float:
	return float(spell(spell_id).get("other_damage_multiplier", 1.0))

static func delivery(spell_id: String) -> String:
	return String(spell(spell_id).get("delivery", "projectile"))

static func cast_lock(spell_id: String) -> float:
	return float(spell(spell_id).get("cast_lock", 0.28))

static func combo_multipliers(spell_id: String) -> Array:
	return spell(spell_id).get("combo_multipliers", [1.0])

static func combo_window(spell_id: String) -> float:
	return float(spell(spell_id).get("combo_window", 0.0))

## Critical-hit chance in percent for a player attacker carrying `bonus_chance`
## (enchanted crit_chance); the last hit of a combo chain adds the finisher bonus.
static func crit_chance(bonus_chance: float, finisher: bool) -> float:
	var rules: Dictionary = combat().get("critical", {})
	var chance := float(rules.get("base_chance", 0.0)) + bonus_chance
	if finisher:
		chance += float(rules.get("finisher_bonus", 0.0))
	return clampf(chance, 0.0, float(rules.get("max_chance", 100.0)))

static func crit_multiplier() -> float:
	return float(combat().get("critical", {}).get("multiplier", 1.5))

# --------------------------------------------------------- combat gating

## Faction + protection gate. Identical semantics to the core client rule,
## now executed by the authority at resolution time and mirrored for prediction.
static func can_damage(caster: Node, target: Node) -> bool:
	if not faction_ok(caster, target):
		return false
	if target.is_in_group("dummies"):
		return true
	# Duelists agreed to the fight: it goes on inside a safe volume too.
	if are_duel_foes(caster, target):
		return true
	# Protected space: neither side of the exchange may be inside a volume.
	if is_protected_node(caster) or is_protected_node(target):
		return false
	return true

## The part of `can_damage` that is about WHO may hit whom (not where they
## stand). Damage application uses this; attack paths use `can_damage`.
static func faction_ok(caster: Node, target: Node) -> bool:
	if not is_instance_valid(target) or target == caster or not target.has_method("take_damage"):
		return false
	if target.is_in_group("npcs"):
		return false
	if "current_hp" in target and target.current_hp <= 0:
		return false
	if "is_destroyed" in target and target.is_destroyed:
		return false
	if not is_instance_valid(caster):
		return false
	if caster.is_in_group("players"):
		return not target.is_in_group("players") or are_duel_foes(caster, target)
	return target.is_in_group("players")

## Duels (v27): uid -> {foe uid: true} for every duelist whose fight is on and
## who is still standing. The authority writes it (`set_duel_foes`); a client
## mirrors its own player's row from `sim_duel_state` so targeting and aim
## assist pick the foe like any hostile body.
static var duel_foes: Dictionary = {}

static func are_duel_foes(a: Node, b: Node) -> bool:
	if duel_foes.is_empty() or not is_instance_valid(a) or not is_instance_valid(b):
		return false
	var row = duel_foes.get(int(a.get_meta("sim_uid", 0)))
	return row is Dictionary and (row as Dictionary).has(int(b.get_meta("sim_uid", 0)))

static func set_duel_foes(uid: int, foes: Array) -> void:
	if foes.is_empty():
		duel_foes.erase(uid)
		return
	var row := {}
	for foe in foes:
		row[int(foe)] = true
	duel_foes[uid] = row

static func has_line_of_sight(source: Node3D, target: Node3D) -> bool:
	if not is_instance_valid(source) or not is_instance_valid(target):
		return false
	var space := source.get_world_3d().direct_space_state
	var query := PhysicsRayQueryParameters3D.create(
		source.global_position + Vector3.UP, target.global_position + Vector3.UP, 1)
	return space.intersect_ray(query).is_empty()

static func safe_up(direction: Vector3) -> Vector3:
	var n := direction.normalized()
	return Vector3.FORWARD if absf(n.dot(Vector3.UP)) > 0.98 else Vector3.UP

# ------------------------------------------------------------ safe zones

static func _zone_list() -> Array:
	ensure_loaded()
	return _zones.get("zones", [])

## Safe zones are map-scoped: a volume is only evaluated on
## the maps whose catalog entry references it, so a position inside the castle
## can never be "protected" by an outdoor volume, and the grounds keep every
## volume they author. Without a catalog the legacy behaviour (all volumes
## apply) is preserved rather than silently disabling protection.
static func _zone_applies(zone: Dictionary, point: Vector3) -> bool:
	return _zone_applies_on(zone, _zones_for_point(point))

## The safe-zone ids of the map holding `point`, or null when the point is on
## no catalogued map (every volume applies then). Resolved once per query, not
## once per volume: map_for_point walks the map catalog.
static func _zones_for_point(point: Vector3) -> Variant:
	var map_id := HPMaps.map_for_point(point)
	if not HPMaps.map_exists(map_id):
		return null
	return HPMaps.safe_zone_ids(map_id)

static func _zone_applies_on(zone: Dictionary, map_zones: Variant) -> bool:
	return map_zones == null or (map_zones as Array).has(String(zone.get("id", "")))

static func spawn_buffer() -> float:
	ensure_loaded()
	return float(_zones.get("spawn_buffer", 8.0))

static func is_protected_point(point: Vector3) -> bool:
	var map_zones: Variant = _zones_for_point(point)
	for zone in _zone_list():
		if _point_in_zone_on(point, zone, 0.0, map_zones):
			return true
	return false

static func is_spawn_blocked(point: Vector3) -> bool:
	var pad := spawn_buffer()
	var map_zones: Variant = _zones_for_point(point)
	for zone in _zone_list():
		if _point_in_zone_on(point, zone, pad, map_zones):
			return true
	return false

static func is_protected_node(node: Node) -> bool:
	if not (node is Node3D):
		return false
	return is_protected_point((node as Node3D).global_position)

static func protection_id(point: Vector3) -> String:
	for zone in _zone_list():
		if _point_in_zone(point, zone, 0.0):
			return String(zone.get("id", ""))
	return ""

static func _point_in_zone(point: Vector3, zone: Dictionary, pad: float) -> bool:
	return _point_in_zone_on(point, zone, pad, _zones_for_point(point))

static func _point_in_zone_on(point: Vector3, zone: Dictionary, pad: float, map_zones: Variant) -> bool:
	if not _zone_applies_on(zone, map_zones):
		return false
	var y_min := float(zone.get("y_min", -1000.0))
	var y_max := float(zone.get("y_max", 1000.0))
	if point.y < y_min or point.y > y_max:
		return false
	var center: Array = zone.get("center", [0.0, 0.0, 0.0])
	if center.size() != 3:
		return false
	var dx := point.x - float(center[0])
	var dz := point.z - float(center[2])
	if String(zone.get("shape", "cylinder")) == "box":
		var half: Array = zone.get("half_extents", [1.0, 1.0, 1.0])
		var dy := point.y - float(center[1])
		return absf(dx) <= float(half[0]) + pad and absf(dy) <= float(half[1]) + pad and absf(dz) <= float(half[2]) + pad
	var radius := float(zone.get("radius", 0.0)) + pad
	return (dx * dx + dz * dz) <= radius * radius

## Zone id for an entity on a specific map. The authored regions belong to one
## entity set (`spawn_tables.json`); a map that does not run that set (the
## greybox interior) has no regions, so its entities carry no grounds zone id.
static func zone_id_for_map(map_id: String, point: Vector3) -> String:
	ensure_loaded()
	if map_id == "" or HPMaps.entity_set(map_id) != String(_spawns.get("map_id", "")):
		return ""
	return zone_id_for(point)

## Authored region containing this point (used for entity zone ids and interest
## grouping). Falls back to the nearest region whose radius covers the point.
static func zone_id_for(point: Vector3) -> String:
	ensure_loaded()
	var best := ""
	var best_distance := INF
	for region in _spawns.get("regions", []):
		var center: Array = region.get("center", [0.0, 0.0])
		if center.size() != 2:
			continue
		var dx := point.x - float(center[0])
		var dz := point.z - float(center[1])
		var distance := sqrt(dx * dx + dz * dz)
		if distance <= float(region.get("radius", 0.0)):
			return String(region.get("id", ""))
		if distance < best_distance:
			best_distance = distance
			best = String(region.get("id", ""))
	return best

# ------------------------------------------------------------- movement

const GRAVITY := 24.0
const WALK_SPEED := 6.5
const MOUNTED_SPEED := 12.0
const MOUNTED_ASCEND_SPEED := 7.0
const MOUNTED_ACCEL := 25.0
const GROUND_ACCEL := 65.0
const JUMP_VELOCITY := 8.0

static func speed_for(mounted: bool) -> float:
	return MOUNTED_SPEED if mounted else WALK_SPEED

## The authority never trusts a client position, only an input vector. Anything
## longer than a unit vector is a forged input and is clamped, not refused, so a
## lossy client that repeats an input still moves normally.
static func sanitize_input_vector(input: Vector2) -> Vector2:
	if not is_finite(input.x) or not is_finite(input.y):
		return Vector2.ZERO
	if input.length_squared() <= 1.0:
		return input
	return input.normalized()

## Largest distance a player may legitimately cover in `dt` (used to detect and
## reject teleport claims; the server also caps its own simulation by this).
static func max_travel_distance(dt: float) -> float:
	return MOUNTED_SPEED * dt * 1.45 + 0.6

static func movement_direction(input_dir: Vector2, camera_yaw_degrees: float) -> Vector3:
	if input_dir.length_squared() < 0.0001:
		return Vector3.ZERO
	var cam_yaw := deg_to_rad(camera_yaw_degrees)
	var forward := Vector3(-sin(cam_yaw), 0, -cos(cam_yaw))
	var right := Vector3(cos(cam_yaw), 0, -sin(cam_yaw))
	return (right * input_dir.x + forward * -input_dir.y).normalized()

# ------------------------------------------------------------ aggro policy

static func aggro_radius_for_level(level: int) -> float:
	ensure_loaded()
	var tuning: Dictionary = _spawns.get("pack_tuning", {})
	if level < int(tuning.get("aggro_radius_level", 8)):
		return float(tuning.get("aggro_radius_low", 9.0))
	return float(tuning.get("aggro_radius_high", 12.0))

static func pack_strength(level: int) -> float:
	ensure_loaded()
	var tuning: Dictionary = _spawns.get("pack_tuning", {})
	var strength := float(tuning.get("hp_strength_base", 0.45)) + float(level) * float(tuning.get("hp_strength_per_level", 0.075))
	return maxf(float(tuning.get("hp_strength_floor", 0.35)), strength)

static func pack_exp_reward(level: int) -> int:
	ensure_loaded()
	var tuning: Dictionary = _spawns.get("pack_tuning", {})
	return int(round(float(tuning.get("exp_base", 25)) + float(level) * float(tuning.get("exp_per_level", 6))
		+ float(level * level) * float(tuning.get("exp_per_level_sq", 0.0))))

# -------------------------------------------------------------- creatures

static func mob_catalog() -> Dictionary:
	ensure_loaded()
	return _mobs.get("mobs", {})

static func mob_ids() -> Array:
	return mob_catalog().keys()

## A shield-bearer (mobs.json front_guard) blocks blows from within ~60 degrees
## of where it faces.
const FRONT_GUARD_COS := 0.5

static func mob_def(species: String) -> Dictionary:
	return mob_catalog().get(species, {})

## Scene for a species: the catalog first, spawn_tables `mob_scenes` as the
## fallback for content authored before the catalog existed.
static func mob_scene_path(species: String) -> String:
	var path := String(mob_def(species).get("scene", ""))
	if path != "":
		return path
	return String(spawn_tables().get("mob_scenes", {}).get(species, ""))

## Species of pack member `index`: the entry's `roster` (a mixed pack - goblin
## tellers, hexers and vault guards together) or its single `mob`.
static func pack_member_species(pack: Dictionary, index: int) -> String:
	var roster: Array = pack.get("roster", [])
	if roster.is_empty():
		return String(pack.get("mob", ""))
	return String(roster[index % roster.size()])

## Every species a pack fields, its lead (`mob`) first.
static func pack_species(pack: Dictionary) -> Array:
	var out: Array = [String(pack.get("mob", ""))]
	for species in pack.get("roster", []):
		if not out.has(String(species)):
			out.append(String(species))
	return out

static func mob_resist(species: String) -> Dictionary:
	return (mob_def(species).get("resist", {}) as Dictionary).duplicate()

static func elite_rules() -> Dictionary:
	ensure_loaded()
	return _mobs.get("elite", {})

## One elite roll on the authority RNG (bosses and their escorts never roll).
static func roll_elite(rng: RandomNumberGenerator) -> bool:
	return rng.randf() < float(elite_rules().get("chance", 0.0))

## Experience / drop factor for a player of `player_level` killing a mob of
## `mob_level` (mobs.json level_gap bands, highest min_diff first).
static func level_gap_band(player_level: int, mob_level: int) -> Dictionary:
	ensure_loaded()
	var diff := mob_level - player_level
	var bands: Array = (_mobs.get("level_gap", {}) as Dictionary).get("bands", [])
	var best: Dictionary = {}
	var best_min := -INF
	for band in bands:
		var min_diff := float((band as Dictionary).get("min_diff", -999))
		if diff >= min_diff and min_diff > best_min:
			best = band
			best_min = min_diff
	return best

static func level_gap_exp(player_level: int, mob_level: int) -> float:
	return float(level_gap_band(player_level, mob_level).get("exp", 1.0))

static func level_gap_drop(player_level: int, mob_level: int) -> float:
	return float(level_gap_band(player_level, mob_level).get("drop", 1.0))

## Hunting band [min, max] of a region, or [] when it is not a hunting region.
static func region_level_band(zone_id: String) -> Array:
	var region := region_by_id(zone_id)
	if not region.has("level_min"):
		return []
	return [int(region.get("level_min", 1)), int(region.get("level_max", 1))]

## The hunting region a point is INSIDE (strict radius test; "" when none).
## Unlike `zone_id_for`, there is no nearest-region fallback: the HUD only
## names a hunting ground the player actually stands in.
static func hunting_region_at(point: Vector3) -> Dictionary:
	ensure_loaded()
	for region in _spawns.get("regions", []):
		if not (region as Dictionary).has("level_min"):
			continue
		var center: Array = region.get("center", [0.0, 0.0])
		if center.size() != 2:
			continue
		# Maps share x/z (they are y bands): a region belongs to its `map`
		# (default the grounds) and only answers for points on it.
		if HPMaps.map_for_point(point) != String(region.get("map", "grounds")):
			continue
		if Vector2(point.x - float(center[0]), point.z - float(center[1])).length() <= float(region.get("radius", 0.0)):
			return region
	return {}

# -------------------------------------------------------------- dungeons

## Difficulty ids, easiest first (dungeons.json `difficulty`).
const DUNGEON_DIFFICULTIES := ["easy", "normal", "hard", "very_hard", "legendary"]

## A difficulty's place from easiest (0) to Legendary (4).
static func dungeon_difficulty_rank(id: String) -> int:
	return DUNGEON_DIFFICULTIES.find(dungeon_difficulty_id(id))

## Whether a step or spawn entry takes part on `difficulty`: its
## `min_difficulty` (dungeons.json) is at most the run's.
static func dungeon_active_on(item: Dictionary, difficulty: String) -> bool:
	return not item.has("min_difficulty") \
		or dungeon_difficulty_rank(String(item["min_difficulty"])) <= dungeon_difficulty_rank(difficulty)

## A known difficulty id, or "normal".
static func dungeon_difficulty_id(id: String) -> String:
	return id if DUNGEON_DIFFICULTIES.has(id) else "normal"

static func dungeon_difficulty(id: String) -> Dictionary:
	return HPMaps.dungeon_rules("difficulty").get(dungeon_difficulty_id(id), {})

static func dungeon_group() -> Dictionary:
	return HPMaps.dungeon_rules("group")

## A spawn role (trash / elite / miniboss / boss); unknown roles read as trash.
static func dungeon_role(id: String) -> Dictionary:
	var roles := HPMaps.dungeon_rules("roles")
	return roles.get(id, roles.get("trash", {}))

## Highest minus lowest level of a party.
static func dungeon_level_spread(levels: Array) -> int:
	if levels.is_empty():
		return 0
	return int(levels.max()) - int(levels.min())

## A party's reference level for a dungeon: weighted toward its strongest member
## (an average lets a high member carry low ones through easy creatures, the
## highest alone buries the lowest), clamped to the dungeon's level band.
static func dungeon_ref_level(dungeon: Dictionary, levels: Array) -> int:
	var low := int(dungeon.get("level_min", 1))
	if levels.is_empty():
		return low
	var total := 0
	for level in levels:
		total += int(level)
	var weight := float(dungeon_group().get("ref_max_weight", 0.6))
	var ref := roundi(weight * float(levels.max()) + (1.0 - weight) * float(total) / float(levels.size()))
	return clampi(ref, low, int(dungeon.get("level_max", max_level())))

## What a run fixes when it opens: difficulty, the party's levels and size, and
## the reference level every creature of the run is built from.
static func dungeon_run_params(dungeon: Dictionary, difficulty: String, levels: Array) -> Dictionary:
	return {"difficulty": dungeon_difficulty_id(difficulty), "levels": levels.duplicate(),
		"party_size": maxi(1, levels.size()), "ref_level": dungeon_ref_level(dungeon, levels)}

## The level of one spawn entry in a run: reference + difficulty offset + role + its own `lvl`.
static func dungeon_mob_level(params: Dictionary, entry: Dictionary) -> int:
	var role := dungeon_role(String(entry.get("role", "trash")))
	var level := int(params.get("ref_level", 1)) + int(dungeon_difficulty(String(params.get("difficulty", ""))).get("level_offset", 0)) \
		+ int(role.get("lvl", 0)) + int(entry.get("lvl", 0))
	return clampi(level, 1, max_level())

## HP and damage multipliers a run puts on one spawn entry: the difficulty's, and
## HP for the party size (damage never scales with the party).
static func dungeon_stat_scale(params: Dictionary, entry: Dictionary) -> Dictionary:
	var difficulty := dungeon_difficulty(String(params.get("difficulty", "")))
	var kind := String(dungeon_role(String(entry.get("role", "trash"))).get("party_hp", "trash"))
	var per_member := float(dungeon_group().get("party_hp_" + kind, 0.5))
	var extra := maxi(0, int(params.get("party_size", 1)) - 1)
	return {"hp": float(difficulty.get("hp", 1.0)) * (1.0 + per_member * float(extra)),
		"damage": float(difficulty.get("damage", 1.0))}

## Stat ratio between two creature levels: authored numbers (boss_overrides at
## their `stat_level`) follow a run's level the way pack stats do.
static func level_strength_ratio(from_level: int, to_level: int) -> float:
	return pack_strength(to_level) / pack_strength(from_level)

static func level_exp_ratio(from_level: int, to_level: int) -> float:
	return float(pack_exp_reward(to_level)) / float(maxi(1, pack_exp_reward(from_level)))

## A weekly curse's rules (dungeons.json affixes.defs).
static func dungeon_affix(id: String) -> Dictionary:
	return (HPMaps.dungeon_rules("affixes").get("defs", {}) as Dictionary).get(id, {})

## The dungeon week of a moment: weeks turn on Monday 03:00 UTC (06:00 Turkey
## time); the Unix epoch fell on a Thursday, four days before a Monday.
static func dungeon_week(unix: int) -> int:
	return int(floor(float(unix - 3 * 3600 - 4 * 86400) / 604800.0))

## This week's first `count` curses: the pool shuffled with the week as seed,
## the same in every dungeon and on every machine.
static func dungeon_week_affixes(count: int, unix: int = -1) -> Array:
	if count <= 0:
		return []
	var pool: Array = (HPMaps.dungeon_rules("affixes").get("pool", []) as Array).duplicate()
	var shuffle := RandomNumberGenerator.new()
	shuffle.seed = dungeon_week(unix if unix >= 0 else int(Time.get_unix_time_from_system())) * 7919 + 17
	for i in range(pool.size() - 1, 0, -1):
		var j := shuffle.randi_range(0, i)
		var held = pool[i]
		pool[i] = pool[j]
		pool[j] = held
	return pool.slice(0, mini(count, pool.size()))

## Medal order: none < bronze < silver < gold.
const MEDAL_RANK := {"": 0, "bronze": 1, "silver": 2, "gold": 3}

static func dungeon_rewards() -> Dictionary:
	return HPMaps.dungeon_rules("rewards")

## Whether a character whose clears are `cleared` ({difficulty: best medal
## rank}) may enter `difficulty`: it needs its unlock_after difficulty cleared
## with at least its unlock_medal.
static func dungeon_unlocked(cleared: Dictionary, difficulty: String) -> bool:
	var rules := dungeon_difficulty(difficulty)
	var after := String(rules.get("unlock_after", ""))
	if after == "":
		return true
	return cleared.has(after) and int(cleared[after]) >= int(MEDAL_RANK.get(String(rules.get("unlock_medal", "")), 0))

## Experience multiplier of a party of `members` in a dungeon run.
static func dungeon_party_exp(members: int) -> float:
	var group := dungeon_group()
	return 1.0 + minf(float(group.get("party_exp_cap", 0.2)), float(group.get("party_exp_per_member", 0.05)) * float(maxi(0, members - 1)))

## Experience for `share` of a full clear on `difficulty`, for a player of
## `level` in a run whose creatures stand at `run_level`: a share of the
## player's own level threshold, cut by the level gap downward only.
static func dungeon_exp(level: int, run_level: int, difficulty: String, share: float) -> int:
	var budget := float(dungeon_difficulty(difficulty).get("exp_budget", 0.0))
	var gap := minf(1.0, level_gap_exp(level, run_level))
	return int(round(float(exp_threshold(level)) * budget * share * gap))

# -------------------------------------------------------------- rewards

## Every player that damaged the mob inside the credit window shares the reward.
static func reward_recipients(damage_log: Array, now_ms: int, killer_id: int) -> Array:
	var recipients: Array = []
	for entry in damage_log:
		var attacker_id := int(entry.get("attacker_id", 0))
		var at_ms := int(entry.get("at_ms", 0))
		if attacker_id <= 0:
			continue
		if now_ms - at_ms > HPProtocol.KILL_CREDIT_MS:
			continue
		if not recipients.has(attacker_id):
			recipients.append(attacker_id)
	if killer_id > 0 and not recipients.has(killer_id):
		recipients.append(killer_id)
	return recipients

## Roll one loot table (always + probabilistic rolls) with the authority RNG.
static func roll_loot(table: Dictionary, rng: RandomNumberGenerator) -> Array:
	var drops: Array = []
	for entry in table.get("always", []):
		drops.append({"id": String(entry.get("id", "")),
			"amount": rng.randi_range(int(entry.get("min", 1)), int(entry.get("max", 1)))})
	for entry in table.get("rolls", []):
		if rng.randf() < float(entry.get("chance", 0.0)):
			drops.append({"id": String(entry.get("id", "")),
				"amount": rng.randi_range(int(entry.get("min", 1)), int(entry.get("max", 1)))})
	return drops

## Mob drops: the base `mob` table, plus the species table (`tables[id]`), plus
## the `elite` table for elites, plus the boss rows for bosses. `drop_factor`
## (level gap) scales every probabilistic roll, never the `always` rows.
static func mob_loot(is_boss: bool, rng: RandomNumberGenerator, table_id: String = "", elite: bool = false, drop_factor: float = 1.0) -> Array:
	ensure_loaded()
	var table: Dictionary = _loot.get("mob", {})
	var species_table: Dictionary = (_loot.get("tables", {}) as Dictionary).get(table_id, {})
	# `no_base_rolls`: the species keeps the base galleons but none of the base
	# item rolls (goblins: gold, and items only from their own rare rolls).
	var base_table := {"always": table.get("always", [])} if bool(species_table.get("no_base_rolls", false)) else table
	var drops := roll_loot(_scaled_table(base_table, drop_factor), rng)
	if not species_table.is_empty():
		drops.append_array(roll_loot(_scaled_table(species_table, drop_factor), rng))
	if elite:
		drops.append_array(roll_loot(_scaled_table(_loot.get("elite", {}), drop_factor), rng))
	if is_boss:
		drops.append_array(roll_loot(_scaled_table({
			"always": table.get("boss_always", []),
			"rolls": table.get("boss_rolls", [])}, drop_factor), rng))
	return drops

static func _scaled_table(table: Dictionary, factor: float) -> Dictionary:
	if is_equal_approx(factor, 1.0):
		return table
	var rolls: Array = []
	for entry in table.get("rolls", []):
		var scaled: Dictionary = (entry as Dictionary).duplicate()
		scaled["chance"] = float(scaled.get("chance", 0.0)) * factor
		rolls.append(scaled)
	return {"always": table.get("always", []), "rolls": rolls}

static func monolith_loot(rng: RandomNumberGenerator, table: String = "") -> Array:
	ensure_loaded()
	return roll_loot(_loot.get(table if table != "" and _loot.has(table) else "monolith", {}), rng)

## A metin stone type (spawn_tables.json monolith_types; "dark" falls back to
## the legacy monolith_config block).
static func monolith_type(type_id: String) -> Dictionary:
	ensure_loaded()
	var types: Dictionary = _spawns.get("monolith_types", {})
	if types.has(type_id):
		return types[type_id]
	return types.get("dark", _spawns.get("monolith_config", {}))

## Respawn delay for one authored encounter: its own `respawn_s` [min, max]
## (world bosses come back on a long timer) or the shared table.
static func encounter_respawn_ms(entry: Dictionary, is_boss: bool, rng: RandomNumberGenerator) -> int:
	var own: Array = entry.get("respawn_s", [])
	if own.size() == 2 and OS.get_environment("HPMMO_DEV_FAST_RESPAWN") == "":
		return rng.randi_range(int(float(own[0]) * 1000.0), int(float(own[1]) * 1000.0))
	return respawn_delay_ms(is_boss, rng, true)

static func respawn_delay_ms(is_boss: bool, rng: RandomNumberGenerator, pack: bool = false) -> int:
	ensure_loaded()
	# Test affordance (never set in production): compresses respawn timers so the
	# respawn path is observable inside a test run.
	var fast := OS.get_environment("HPMMO_DEV_FAST_RESPAWN")
	if fast != "":
		return maxi(250, int(fast))
	var table: Dictionary = _loot.get("respawn_ms", {})
	var prefix := "pack_" if pack else "mob_"
	var kind := "boss" if is_boss else "normal"
	return rng.randi_range(
		int(table.get(prefix + kind + "_min", 25000)),
		int(table.get(prefix + kind + "_max", 35000)))
