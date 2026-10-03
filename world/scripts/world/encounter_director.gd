extends Node

## Packs select a clear location inside their zone; an entire defeated pack
## respawns together at a new anchor. Boss escorts share their boss's timer.
const INFERI = preload("res://scenes/entities/mobs/mob_inferi.tscn")
const SPIDER = preload("res://scenes/entities/mobs/mob_acromantula.tscn")
const SNATCHER = preload("res://scenes/entities/mobs/mob_darksnatcher.tscn")
const COMMANDER = preload("res://assets/models/monsters/Orc_Skull.gltf")
const SafeZone = preload("res://scripts/world/safe_zone.gd")
var packs: Array[Dictionary] = []
var container: Node3D
var rng := RandomNumberGenerator.new()

func start(mobs: Node3D) -> void:
	container = mobs
	rng.randomize()
	var zones := [
		{"area": Rect2(17, -33, 15, 15), "scene": INFERI, "level": 3, "count": 3, "aggro_mode": "reactive", "assist_radius": 16.0, "leash_distance": 26.0},
		{"area": Rect2(8, 31, 19, 15), "scene": SPIDER, "level": 4, "count": 3, "aggro_mode": "reactive", "assist_radius": 16.0, "leash_distance": 26.0},
		{"area": Rect2(-37, -28, 14, 16), "scene": SPIDER, "level": 8, "count": 5, "aggro_mode": "reactive", "assist_radius": 16.0, "leash_distance": 26.0},
		{"area": Rect2(46, -57, 17, 15), "scene": SNATCHER, "level": 12, "count": 3, "aggro_mode": "reactive", "assist_radius": 16.0, "leash_distance": 26.0},
		{"area": Rect2(-69, -48, 16, 19), "scene": INFERI, "level": 14, "count": 5, "aggro_mode": "reactive", "assist_radius": 16.0, "leash_distance": 26.0},
		{"area": Rect2(-91, -74, 16, 16), "scene": SPIDER, "level": 25, "count": 1, "boss": true, "aggro_mode": "reactive", "assist_radius": 20.0, "leash_distance": 40.0},
		{"area": Rect2(53, -91, 18, 15), "scene": SNATCHER, "level": 20, "count": 3, "boss": true, "commander": true, "aggro_mode": "reactive", "assist_radius": 20.0, "leash_distance": 40.0},
	]
	for zone in zones:
		zone["members"] = []
		zone["timer"] = -1.0
		packs.append(zone)
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
	if SafeZone.is_spawn_blocked(anchor):
		return false
	if member_count > 1:
		for i in range(member_count):
			var offset := Vector3(cos(i * TAU / member_count), 0, sin(i * TAU / member_count)) * 3.1
			if SafeZone.is_spawn_blocked(anchor + offset):
				return false
	return true

func _spawn_pack(index: int) -> void:
	var pack := packs[index]
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
			var strength := maxf(0.35, 0.45 + float(pack.level) * 0.075)
			mob.max_hp = int(mob.max_hp * strength)
			mob.attack_power = int(mob.attack_power * strength * 0.75)
			mob.exp_reward = int(25 + pack.level * 6)
			mob.aggro_radius = 9 if pack.level < 8 else 12
			mob.aggro_mode = String(pack.get("aggro_mode", "reactive"))
			mob.assist_radius = float(pack.get("assist_radius", 16.0))
			mob.leash_distance = float(pack.get("leash_distance", 26.0))
			if i == 0 and pack.get("boss", false):
				mob.is_boss = true
				mob.is_commander = pack.get("commander", false)
				mob.max_hp = 2400 if mob.is_commander else 3500
				mob.attack_power = 55 if mob.is_commander else 65
				mob.attack_range = 4.5
				mob.exp_reward = 600
				mob.mob_name = "Dark Snatcher Commander" if mob.is_commander else "Acromantula Matriarch"
				mob.get_node("Visuals").scale = Vector3.ONE * (1.65 if mob.is_commander else 2.0)
				mob.get_node("Label3D").position.y = 4.2
				if mob.is_commander:
					for old in mob.get_node("Visuals").get_children():
						old.free()
					var model := COMMANDER.instantiate()
					model.scale = Vector3.ONE * 0.75
					mob.get_node("Visuals").add_child(model)
			elif pack.get("commander", false):
				mob.mob_name = "Elite Bodyguard"
			elif i == 2 and pack.scene == SNATCHER:
				mob.is_ranged = true
			mob.died.connect(_on_member_died.bind(index))
			container.add_child(mob)
			members.append(mob)
		else:
			var mob = members[i]
			mob.spawn_point = anchor + offset
			mob.pack_anchor = anchor
			mob._respawn()
	pack.timer = -1.0

func _on_member_died(_mob: Node3D, index: int) -> void:
	var pack := packs[index]
	for member in pack.members:
		if member.state != member.State.DEAD:
			return
	pack.timer = rng.randf_range(90, 120) if pack.get("boss", false) else rng.randf_range(25, 35)

func _process(delta: float) -> void:
	for index in range(packs.size()):
		if packs[index].timer >= 0:
			packs[index].timer -= delta
			if packs[index].timer <= 0:
				_spawn_pack(index)
