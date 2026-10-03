extends Node

## Encounter director - the ONE place packs are decided.
##
## Phase 5: this runs inside the authority only (dedicated server, host, or the
## client in single-player). Every spawn samples the server-owned tables with the
## authority's seeded RNG and registers the mob with the authority, so clients
## online never roll their own encounter.
##
## Packs select a clear location inside their zone; an entire defeated pack
## respawns together at a new anchor. Boss escorts share their boss's timer.

const COMMANDER_MODEL = "res://assets/models/monsters/Orc_Skull.gltf"

var packs: Array[Dictionary] = []
var container: Node3D
var rng: RandomNumberGenerator

func start(mobs: Node3D) -> void:
	container = mobs
	rng = SimAuthority.rng
	var tables := HPRules.spawn_tables()
	var scenes: Dictionary = tables.get("mob_scenes", {})
	for entry in tables.get("packs", []):
		var scene_path := String(scenes.get(String(entry.get("mob", "")), ""))
		var pack: Dictionary = entry.duplicate(true)
		pack["scene"] = load(scene_path) if scene_path != "" else null
		# Areas are authored as [x, z, width, depth] in JSON; the sampler works in
		# Rect2 (x/z plane).
		var area: Array = pack.get("area", [0.0, 0.0, 1.0, 1.0])
		pack["area"] = Rect2(float(area[0]), float(area[1]), float(area[2]), float(area[3]))
		pack["members"] = []
		pack["timer"] = -1.0
		packs.append(pack)
	_spawn_initial.call_deferred()

func _spawn_initial() -> void:
	await get_tree().physics_frame
	for index in range(packs.size()):
		_spawn_pack(index)

func _clear_anchor(area: Rect2, member_count: int) -> Vector3:
	for _attempt in range(40):
		var point := Vector3(rng.randf_range(area.position.x, area.end.x), 0.1, rng.randf_range(area.position.y, area.end.y))
		if not _formation_clear(point, member_count):
			continue
		var near_player := false
		for player in get_tree().get_nodes_in_group("players"):
			if player.global_position.distance_to(point) < 16:
				near_player = true
		if near_player:
			continue
		var shape := CylinderShape3D.new()
		shape.radius = 5.5
		shape.height = 3
		var query := PhysicsShapeQueryParameters3D.new()
		query.shape = shape
		query.transform.origin = point + Vector3.UP * 1.6
		query.collision_mask = 3
		if container.get_world_3d().direct_space_state.intersect_shape(query, 1).is_empty():
			return point
	# Defer a blocked spawn rather than putting enemies inside walls or players.
	return Vector3.INF

## Every formation member (not just the anchor) must sit outside the protected
## volumes and their spawn buffer (plan Phase 1, task 2).
func _formation_clear(anchor: Vector3, member_count: int) -> bool:
	if HPRules.is_spawn_blocked(anchor):
		return false
	if member_count > 1:
		for i in range(member_count):
			var offset := Vector3(cos(i * TAU / member_count), 0, sin(i * TAU / member_count)) * 3.1
			if HPRules.is_spawn_blocked(anchor + offset):
				return false
	return true

func _spawn_pack(index: int) -> void:
	var pack := packs[index]
	if pack.get("scene") == null:
		return
	var anchor := _clear_anchor(pack.area, int(pack.count))
	if not anchor.is_finite():
		pack.timer = 5.0
		return
	var members: Array = pack.members
	for i in range(int(pack.count)):
		var offset := Vector3.ZERO if pack.count == 1 else Vector3(cos(i * TAU / pack.count), 0, sin(i * TAU / pack.count)) * 3.1
		if members.size() <= i:
			var mob = pack.scene.instantiate()
			mob.name = "Pack%dMember%d" % [index + 1, i]
			mob.position = anchor + offset
			mob.pack_anchor = anchor
			mob.pack_id = index + 1
			mob.managed_respawn = true
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
			if i == 0 and pack.get("boss", false):
				_apply_boss(mob, pack)
			elif pack.get("commander", false):
				mob.mob_name = "Elite Bodyguard"
			elif i == 2 and String(pack.get("mob", "")) == "darksnatcher":
				mob.is_ranged = true
			mob.died.connect(_on_member_died.bind(index))
			container.add_child(mob)
			members.append(mob)
			SimAuthority.register_mob(mob, index + 1, String(pack.get("zone", "")))
		else:
			var mob = members[i]
			mob.spawn_point = anchor + offset
			mob.pack_anchor = anchor
			mob._respawn()
	if members.size() > 0:
		print("[Encounters] pack %d respawned at (%.1f, %.1f, %.1f)" % [
			index + 1, anchor.x, anchor.y, anchor.z])
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
	var visuals := mob.get_node_or_null("Visuals")
	if visuals:
		visuals.scale = Vector3.ONE * float(data.get("scale", 1.65))
	var label := mob.get_node_or_null("Label3D")
	if label:
		label.position.y = 4.2
	if mob.is_commander and visuals:
		for old in visuals.get_children():
			old.free()
		var model = load(COMMANDER_MODEL).instantiate()
		model.scale = Vector3.ONE * 0.75
		visuals.add_child(model)

func _on_member_died(_mob: Node3D, index: int) -> void:
	var pack := packs[index]
	for member in pack.members:
		if member.state != member.State.DEAD:
			return
	var is_boss: bool = bool(pack.get("boss", false))
	pack.timer = float(HPRules.respawn_delay_ms(is_boss, rng, true)) / 1000.0
	print("[Encounters] pack %d wiped; respawn in %.1fs" % [index + 1, pack.timer])

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
