extends Node

## Encounter director - the ONE place packs are decided.
##
## This runs inside the authority only (dedicated server, host, or the
## client in single-player). Every spawn samples the server-owned tables with the
## authority's seeded RNG and registers the mob with the authority, so clients
## online never roll their own encounter.
##
## Creature pass rules implemented here:
##   * encounters resolve through a data template (pack of 3/5, boss alone,
##     boss with exactly two escorts) and a region's separate pack_count;
##   * an anchor is only accepted when EVERY formation member passes: safe zones
##     and their spawn buffer, the authored exclusions (water, portal arrival
##     pads), solid geometry, standable ground, other packs' occupied spawns,
##     and no visible nearby player;
##   * bounded retries, then the spawn is DEFERRED (never placed inside a wall);
##   * a defeated pack respawns on a server-owned timer at a newly validated
##     anchor and keeps deferring while players camp the spot;
##   * a leashed-out pack resets its encounter (the authority cancels the
##     pending reward credit for it) and the director rebuilds it clean.

var packs: Array[Dictionary] = []
## Authored encounters that a region's pack_count keeps dormant. Reported, never
## silently ignored.
var dormant: Array[Dictionary] = []
var container: Node3D
var rng: RandomNumberGenerator
var encounter_seed := 0

func start(mobs: Node3D) -> void:
	container = mobs
	rng = SimAuthority.rng
	encounter_seed = HPRules.debug_seed()
	var report := HPRules.validate_encounters()
	if not report["ok"]:
		for problem in report["problems"]:
			printerr("[Encounters] DATA: %s" % problem)
	_build_packs()
	print("[Encounters] seed=%d active=%d dormant=%d" % [encounter_seed, packs.size(), dormant.size()])
	if SimAuthority.encounter_reset.is_connected(_on_encounter_reset) == false:
		SimAuthority.encounter_reset.connect(_on_encounter_reset)
	_spawn_initial.call_deferred()

# --------------------------------------------------------------- data -> packs

## Build the active pack list from the authored encounters. Order is the authored
## order, so stable encounter ids and pack ids do not move when tuning changes.
func _build_packs() -> void:
	var tables := HPRules.spawn_tables()
	var scenes: Dictionary = tables.get("mob_scenes", {})
	packs.clear()
	dormant.clear()
	var active_ids: Dictionary = {}
	for region in HPRules.regions():
		var zone := String(region.get("id", ""))
		for entry in HPRules.active_encounters_for(zone):
			active_ids[String((entry as Dictionary).get("encounter_id", ""))] = true
	for entry in HPRules.encounter_list():
		var authored: Dictionary = entry
		var encounter_id := String(authored.get("encounter_id", "pack#%s" % str(authored.get("id", "?"))))
		var pack := _prepare_encounter(authored, scenes)
		if pack.is_empty():
			continue
		if active_ids.has(encounter_id):
			pack["pack_id"] = packs.size() + 1
			packs.append(pack)
		else:
			dormant.append(pack)

func _prepare_encounter(authored: Dictionary, scenes: Dictionary) -> Dictionary:
	var scene_path := String(scenes.get(String(authored.get("mob", "")), ""))
	if scene_path == "":
		printerr("[Encounters] %s: no scene for mob '%s'" % [authored.get("encounter_id", "?"), authored.get("mob", "")])
		return {}
	var pack: Dictionary = authored.duplicate(true)
	pack["entry"] = authored
	pack["scene"] = load(scene_path)
	pack["encounter_id"] = String(authored.get("encounter_id", ""))
	pack["template_id"] = String(authored.get("template", ""))
	pack["template"] = HPRules.template_for(authored)
	pack["count"] = int(authored.get("count", 1))
	pack["escorts"] = HPRules.encounter_escorts(authored)
	pack["max_alive"] = HPRules.encounter_max_alive(authored)
	pack["boss"] = HPRules.is_boss_encounter(authored)
	pack["members"] = []
	pack["timer"] = -1.0
	pack["deferred"] = false
	pack["spawns"] = 0
	pack["zone"] = String(authored.get("zone", ""))
	var area: Array = authored.get("area", [0.0, 0.0, 1.0, 1.0])
	pack["area"] = Rect2(float(area[0]), float(area[1]), float(area[2]), float(area[3]))
	pack["offsets"] = HPRules.formation_offsets(int(pack["count"]), int(pack["escorts"]))
	return pack

func _spawn_initial() -> void:
	await get_tree().physics_frame
	for index in range(packs.size()):
		_spawn_pack(index)

# ------------------------------------------------------------- placement rules

## Every formation member is validated, not just the anchor.
## Returns the id of the rule that rejected the placement, or "" when the whole
## formation is clear.
func _placement_refusal(anchor: Vector3, pack: Dictionary) -> String:
	var clearance := HPRules.pack_tuning("respawn_clear_radius", 16.0)
	# Static rules first (safe zones, authored exclusions, geometry), then the
	# dynamic ones (other packs, players): a refusal names the most fundamental
	# reason, which is what the checks below assert on.
	for offset in pack.get("offsets", []):
		var point: Vector3 = anchor + offset
		if HPRules.is_spawn_blocked(point):
			return "safe_zone"
		var excluded := HPRules.exclusion_at(point)
		if excluded != "":
			return "exclusion:%s" % excluded
		if not _ground_ok(point):
			return "unstandable"
		if not _member_clear_of_geometry(point):
			return "solid_geometry"
	for other in packs:
		if other.get("members", []).is_empty() or other.get("pack_id", 0) == pack.get("pack_id", 0):
			continue
		var home: Vector3 = other.get("anchor", Vector3.ZERO)
		if home != Vector3.ZERO and home.distance_to(anchor) < float(HPRules.pack_tuning("pack_spacing", 3.1)) * 2.0:
			return "occupied_spawn"
	for player in get_tree().get_nodes_in_group("players"):
		if player is Node3D and (player as Node3D).global_position.distance_to(anchor) < clearance:
			return "player_nearby"
	return ""

## Standable ground: a floor hit with a sane normal, and not perched on shaped
## terrain (cliffs). The flat playable core sits at y ~ 0; a hill is rejected.
func _ground_ok(point: Vector3) -> bool:
	var space := container.get_world_3d().direct_space_state
	var from := point + Vector3.UP * 3.0
	var to := point - Vector3.UP * 3.0
	var query := PhysicsRayQueryParameters3D.create(from, to, 1)
	var hit := space.intersect_ray(query)
	if hit.is_empty():
		return false
	if (hit["normal"] as Vector3).dot(Vector3.UP) < 0.72:
		return false
	return absf((hit["position"] as Vector3).y - point.y) <= 1.2

func _member_clear_of_geometry(point: Vector3) -> bool:
	var shape := SphereShape3D.new()
	shape.radius = maxf(0.35, float(HPRules.pack_tuning("member_clearance", 1.0)) * 0.5)
	var query := PhysicsShapeQueryParameters3D.new()
	query.shape = shape
	query.transform.origin = point + Vector3.UP * 0.9
	query.collision_mask = 1
	return container.get_world_3d().direct_space_state.intersect_shape(query, 1).is_empty()

## Prototype compatibility: the old formation check. Kept because earlier checks
## and callers use it; the creature pass path is `_placement_refusal`.
func _formation_clear(anchor: Vector3, member_count: int) -> bool:
	if HPRules.is_spawn_blocked(anchor):
		return false
	if member_count > 1:
		for offset in HPRules.formation_offsets(member_count):
			if HPRules.is_spawn_blocked(anchor + offset):
				return false
	return true

## Sample a whole formation inside the pack's area, with bounded retries.
## Returns Vector3.INF when nothing valid was found, so the caller defers
## instead of placing enemies inside walls.
func _sample_anchor(pack: Dictionary) -> Vector3:
	var attempts := int(HPRules.pack_tuning("placement_attempts", 40.0))
	var area: Rect2 = pack["area"]
	for _attempt in range(attempts):
		var point := Vector3(rng.randf_range(area.position.x, area.end.x), 0.1,
			rng.randf_range(area.position.y, area.end.y))
		if not _formation_clear(point, int(pack["count"])):
			continue
		if _placement_refusal(point, pack) != "":
			continue
		return point
	return Vector3.INF

func _clear_anchor(area: Rect2, member_count: int) -> Vector3:
	var probe := {"area": area, "count": member_count, "offsets": HPRules.formation_offsets(member_count),
		"pack_id": -1, "members": [], "entry": {}}
	var point := _sample_anchor(probe)
	return point

# ---------------------------------------------------------------------- spawn

func _spawn_pack(index: int) -> void:
	var pack := packs[index]
	if pack.get("scene") == null:
		return
	# Maximum alive count: never stack a second copy of an
	# encounter on top of living members.
	var alive := 0
	for member in pack.members:
		if is_instance_valid(member) and member.state != member.State.DEAD:
			alive += 1
	if alive >= int(pack.get("max_alive", pack.count)):
		return
	var anchor := _sample_anchor(pack)
	if not anchor.is_finite():
		# Defer instead of placing enemies inside walls or on top of players.
		pack.timer = float(HPRules.pack_tuning("respawn_retry_seconds", 5.0))
		pack.deferred = true
		print("[Encounters] %s deferred (no valid anchor; retry in %.1fs)" % [
			pack.get("encounter_id", "?"), pack.timer])
		return
	pack["anchor"] = anchor
	pack.deferred = false
	var members: Array = pack.members
	var offsets: Array = pack.get("offsets", HPRules.formation_offsets(int(pack.count), int(pack.escorts)))
	for i in range(int(pack.count)):
		var offset: Vector3 = offsets[i] if i < offsets.size() else Vector3.ZERO
		if members.size() <= i:
			var mob = pack.scene.instantiate()
			mob.name = "Pack%dMember%d" % [index + 1, i]
			mob.position = anchor + offset
			mob.pack_anchor = anchor
			mob.pack_id = int(pack.get("pack_id", index + 1))
			mob.managed_respawn = true
			mob.encounter_id = String(pack.get("encounter_id", ""))
			mob.level = pack.level
			var strength := HPRules.pack_strength(int(pack.level))
			var tuning: Dictionary = HPRules.spawn_tables().get("pack_tuning", {})
			mob.max_hp = int(mob.max_hp * strength)
			mob.attack_power = int(mob.attack_power * strength * float(tuning.get("attack_multiplier", 0.75)))
			mob.exp_reward = HPRules.pack_exp_reward(int(pack.level))
			mob.aggro_radius = HPRules.aggro_radius_for_level(int(pack.level))
			mob.aggro_mode = String(pack.get("aggro_mode", "reactive"))
			mob.assist_radius = float(pack.get("assist_radius", 16.0))
			mob.leash_distance = float(pack.get("leash_distance", 26.0))
			mob.escort_count = int(pack.get("escorts", 0))
			if i == 0 and pack.get("boss", false):
				_apply_boss(mob, pack)
			elif pack.get("boss", false):
				mob.mob_name = "Elite Bodyguard"
			elif i == 2 and String(pack.get("mob", "")) == "darksnatcher":
				mob.is_ranged = true
			mob.died.connect(_on_member_died.bind(index))
			container.add_child(mob)
			members.append(mob)
			SimAuthority.register_mob(mob, int(pack.get("pack_id", index + 1)), String(pack.get("zone", "")))
		else:
			var mob = members[i]
			mob.spawn_point = anchor + offset
			mob.pack_anchor = anchor
			mob.escort_count = int(pack.get("escorts", 0))
			mob._respawn()
	pack["spawns"] = int(pack.get("spawns", 0)) + 1
	if members.size() > 0:
		print("[Encounters] %s (#%d) spawned at (%.1f, %.1f, %.1f) zone=%s cycle=%d" % [
			pack.get("encounter_id", "?"), int(pack.get("pack_id", index + 1)),
			anchor.x, anchor.y, anchor.z, String(pack.get("zone", "")), int(pack["spawns"])])
	pack.timer = -1.0

func _apply_boss(mob: Node3D, pack: Dictionary) -> void:
	var overrides: Dictionary = HPRules.spawn_tables().get("boss_overrides", {})
	var key := "commander" if pack.get("commander", false) else "matriarch"
	var data: Dictionary = overrides.get(key, {})
	mob.is_boss = true
	mob.is_commander = pack.get("commander", false)
	mob.max_hp = int(data.get("hp", mob.max_hp))
	mob.attack_power = int(data.get("attack_power", mob.attack_power))
	mob.attack_range = float(data.get("attack_range", 4.5))
	mob.exp_reward = int(data.get("exp_reward", mob.exp_reward))
	mob.mob_name = String(data.get("name", mob.mob_name))
	# A boss fights with its authored patterns, not the ordinary ranged/melee
	# reach: the cone and area attacks carry their own range.
	mob.is_ranged = false
	mob.move_speed = float(data.get("move_speed", mob.move_speed))
	# The authored creature cycle has a real ground speed; the boss uses it so
	# the walk does not skate (exit: coordinated walking).
	mob.walk_speed = float(data.get("walk_speed", 0.0))
	mob.boss_style = String(pack.get("template", {}).get("attack_style", "spider"))
	mob.boss_arena_radius = float(pack.get("template", {}).get("arena_radius", 18.0))
	var scale := float(data.get("scale", 1.0))
	var visuals := mob.get_node_or_null("Visuals")
	if visuals:
		visuals.scale = Vector3.ONE * scale
	var label := mob.get_node_or_null("Label3D")
	if label:
		label.position.y = 4.2
	# The boss body is authored art (assets/models/monsters/boss_*.glb) selected
	# by the mob scene itself when `is_boss` is set - the director never swaps in
	# a scaled-up placeholder.

# -------------------------------------------------------------- lifecycle

func _on_member_died(_mob: Node3D, index: int) -> void:
	var pack := packs[index]
	for member in pack.members:
		if member.state != member.State.DEAD:
			return
	var is_boss: bool = bool(pack.get("boss", false))
	pack.timer = float(HPRules.respawn_delay_ms(is_boss, rng, true)) / 1000.0
	print("[Encounters] %s wiped; respawn in %.1fs" % [pack.get("encounter_id", "?"), pack.timer])

## A pack that leashed home (or lost every valid target) resets: the authority
## cancelled its pending reward credit and this keeps the pack bookkeeping in
## step. Nothing is granted to the players who pulled it.
func _on_encounter_reset(pack_id: int, reason: String) -> void:
	for index in range(packs.size()):
		if int(packs[index].get("pack_id", -1)) != pack_id:
			continue
		packs[index]["timer"] = -1.0
		print("[Encounters] %s reset (%s)" % [packs[index].get("encounter_id", "?"), reason])
		return

func _process(delta: float) -> void:
	# Client-only processes never own encounters; the server tells them what
	# exists. This guard also keeps a stray director from double-spawning.
	if not SimAuthority.is_authority():
		return
	for index in range(packs.size()):
		if packs[index].timer >= 0:
			packs[index].timer -= delta
			if packs[index].timer <= 0:
				_spawn_pack(index)

## Test/debug surface: one line per active encounter with its live state.
func encounter_report() -> Array:
	var out: Array = []
	for pack in packs:
		var alive := 0
		for member in pack.members:
			if is_instance_valid(member) and member.state != member.State.DEAD:
				alive += 1
		out.append({
			"encounter_id": String(pack.get("encounter_id", "")),
			"pack_id": int(pack.get("pack_id", 0)),
			"template": String(pack.get("template_id", "")),
			"zone": String(pack.get("zone", "")),
			"count": int(pack.get("count", 0)),
			"escorts": int(pack.get("escorts", 0)),
			"max_alive": int(pack.get("max_alive", 0)),
			"alive": alive,
			"anchor": pack.get("anchor", Vector3.ZERO),
		})
	return out
