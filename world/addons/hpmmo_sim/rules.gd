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

static func respawn_position() -> Vector3:
	ensure_loaded()
	var raw: Array = (_combat.get("death", {}) as Dictionary).get("respawn_position", [0.0, 0.5, 5.0])
	if raw.size() != 3:
		return Vector3(0.0, 0.5, 5.0)
	return Vector3(float(raw[0]), float(raw[1]), float(raw[2]))

static func cooldown_for(spell_id: String, house: String) -> float:
	var data := spell(spell_id)
	if data.is_empty():
		return 0.0
	return float(data.get("cooldown", 0.0)) * house_modifier(house, "cooldown_multiplier")

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

## EXP required to leave `level` (matches the client's historical growth curve).
static func exp_threshold(level: int) -> int:
	ensure_loaded()
	var base: Dictionary = _combat.get("base_stats", {})
	var value := float(base.get("exp_base", 200))
	var growth := float(base.get("exp_growth", 1.5))
	var cap := float(max_exp())
	for _i in range(maxi(0, level - 1)):
		value = minf(cap, value * growth)
	return int(value)

# ------------------------------------------------------------ spell maths

## Full damage multiplier for a cast, matching the values the client used before
## authority moved to the server (wand tier, combo step, house affinity).
static func damage_multiplier(spell_id: String, wand_tier: int, house: String, combo_multiplier: float = 1.0) -> float:
	return wand_multiplier(wand_tier) * combo_multiplier * house_spell_damage(house, spell_id)

static func spell_damage(spell_id: String, wand_tier: int, house: String, combo_multiplier: float = 1.0) -> int:
	var data := spell(spell_id)
	if data.is_empty():
		return 0
	return int(float(data.get("damage", 0)) * damage_multiplier(spell_id, wand_tier, house, combo_multiplier))

## Damage after per-victim modifiers (fire weakness and the like).
static func damage_after_resistances(raw: int, spell_id: String, weak_to_fire: bool) -> int:
	if weak_to_fire and spell_id == "incendio":
		return raw * 2
	return raw

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

# --------------------------------------------------------- combat gating

## Faction + protection gate. Identical semantics to the Phase 1 client rule,
## now executed by the authority at resolution time and mirrored for prediction.
static func can_damage(caster: Node, target: Node) -> bool:
	if not faction_ok(caster, target):
		return false
	if target.is_in_group("dummies"):
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
		return not target.is_in_group("players")
	return target.is_in_group("players")

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

static func spawn_buffer() -> float:
	ensure_loaded()
	return float(_zones.get("spawn_buffer", 8.0))

static func is_protected_point(point: Vector3) -> bool:
	for zone in _zone_list():
		if _point_in_zone(point, zone, 0.0):
			return true
	return false

static func is_spawn_blocked(point: Vector3) -> bool:
	var pad := spawn_buffer()
	for zone in _zone_list():
		if _point_in_zone(point, zone, pad):
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
const WALK_SPEED := 8.5
const MOUNTED_SPEED := 15.0
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
	return int(float(tuning.get("exp_base", 25)) + float(level) * float(tuning.get("exp_per_level", 6)))

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

static func mob_loot(is_boss: bool, rng: RandomNumberGenerator) -> Array:
	ensure_loaded()
	var table: Dictionary = _loot.get("mob", {})
	var drops := roll_loot(table, rng)
	if is_boss:
		drops.append_array(roll_loot({
			"always": table.get("boss_always", []),
			"rolls": table.get("boss_rolls", [])}, rng))
	return drops

static func monolith_loot(rng: RandomNumberGenerator) -> Array:
	ensure_loaded()
	return roll_loot(_loot.get("monolith", {}), rng)

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
