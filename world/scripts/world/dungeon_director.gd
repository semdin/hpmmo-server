extends Node

## Dungeon director - the scripted runs of instanced maps (dungeons.json).
##
## Authority only (dedicated server, host, offline client). A run starts when
## the authority opens a copy (`SimAuthority.instance_opened`, the first body
## arriving) and walks its steps in order: each waits for its trigger, then
## acts - spawn creatures (boss included), open/close gates, a message, a
## chest, completion. The state (step, open gates, message) is published to
## the players in that copy and applied to the copy's scene, so the gate a
## client sees and the gate the server collides with are the same fact.
## A torn-down copy (`instance_closed`) frees everything its run spawned.

const TICK := 0.25

var runs: Dictionary = {}   # map_id -> run
var container: Node3D
var encounters: Node        # EncounterDirector: stat/boss configuration is shared
var _timer := 0.0
var _next_pack := 9000

func start(world: Node3D, encounter_director: Node) -> void:
	encounters = encounter_director
	container = Node3D.new()
	container.name = "DungeonMobs"   # not a grounds container: never hidden off-map
	world.add_child(container)
	if not SimAuthority.instance_opened.is_connected(open_run):
		SimAuthority.instance_opened.connect(open_run)
		SimAuthority.instance_closed.connect(close_run)

func open_run(map_id: String) -> void:
	var def := HPMaps.dungeon_for_map(map_id)
	if def.is_empty() or runs.has(map_id):
		return
	runs[map_id] = {"def": def, "step": 0, "spawned": {}, "open": {}, "message": "",
		"complete": false, "origin": HPMaps.instance_origin(map_id), "done": {}, "lock": {}, "hazard_t": {}}
	print("[Dungeon] run '%s' opened in %s" % [def.get("id", "?"), map_id])
	advance(map_id)

func close_run(map_id: String) -> void:
	var run: Dictionary = runs.get(map_id, {})
	runs.erase(map_id)
	for list in (run.get("spawned", {}) as Dictionary).values():
		for mob in list:
			if is_instance_valid(mob):
				SimAuthority.unregister_node(mob)
				mob.queue_free()

func _process(delta: float) -> void:
	if not SimAuthority.is_authority() or runs.is_empty():
		return
	_timer -= delta
	if _timer > 0.0:
		return
	_timer = TICK
	for map_id in runs.keys():
		advance(map_id)
		var run: Dictionary = runs.get(map_id, {})
		if not run.is_empty():
			_tick_lock(map_id, run)
			_tick_hazards(map_id, run, TICK)

## The living players in a copy (records with a body).
func _players(map_id: String, alive_only: bool = true) -> Array:
	var out: Array = []
	for uid in SimAuthority.players_by_peer.values():
		var record: Dictionary = SimAuthority.entities.get(uid, {})
		if int(record.get("kind", 0)) != HPProtocol.Kind.PLAYER or String(record.get("map_id", "")) != map_id:
			continue
		if alive_only and bool(record.get("dead", false)):
			continue
		var node = record.get("node")
		if node is Node3D and is_instance_valid(node):
			out.append(record)
	return out

## Wipe and retry: a boss step that shut gates behind the party holds them shut
## only while somebody alive stands past its trigger. When nobody does (the
## party died and respawned at the entrance, or walked out) the gates open so
## the way back is free - cleared rooms stay cleared, the boss has gone home
## and reset - and crossing the trigger line again seals them once more.
func _tick_lock(map_id: String, run: Dictionary) -> void:
	var lock: Dictionary = run["lock"]
	if lock.is_empty():
		return
	var bosses: Array = (run["spawned"] as Dictionary).get(String(lock["step"]), [])
	var alive := bosses.any(func(m): return is_instance_valid(m) and m.state != m.State.DEAD)
	if not alive:
		run["lock"] = {}
		return
	var origin: Vector3 = run["origin"]
	var inside := false
	for record in _players(map_id):
		if ((record["node"] as Node3D).global_position.z - origin.z) < float(lock["z"]):
			inside = true
			break
	if inside == bool(lock["sealed"]):
		return
	lock["sealed"] = inside
	for gate in lock["gates"]:
		if inside:
			run["open"].erase(String(gate))
		else:
			run["open"][String(gate)] = true
	run["message"] = String(lock["message"]) if inside else "The way back is open. Regroup and try again."  # i18n
	_publish(map_id, run)

## dungeons.json `hazards`: a periodic shove of every player inside a band of
## the copy (Fluffy's breath down the stair), between two steps of the run.
func _tick_hazards(map_id: String, run: Dictionary, dt: float) -> void:
	var origin: Vector3 = run["origin"]
	for hazard in run["def"].get("hazards", []):
		var h: Dictionary = hazard
		var id := String(h.get("id", ""))
		var done: Dictionary = run["done"]
		if not done.has(String(h.get("from_step", ""))) or done.has(String(h.get("until_step", ""))):
			continue
		var t := float(run["hazard_t"].get(id, 0.0)) + dt
		var every := float(h.get("every_s", 6.0))
		var warn := float(h.get("warn_s", 1.0))
		var band: Array = h.get("z", [0.0, 0.0])
		var victims: Array = []
		for record in _players(map_id):
			var z: float = (record["node"] as Node3D).global_position.z - origin.z
			if z >= float(band[0]) and z <= float(band[1]):
				victims.append(record)
		if victims.is_empty():
			run["hazard_t"][id] = 0.0
			continue
		if t >= every - warn and t - dt < every - warn and h.has("message"):
			run["message"] = String(h["message"])
			_publish(map_id, run)
		if t >= every:
			t = 0.0
			var p: Array = h.get("push", [0, 0, 0])
			var force := Vector3(float(p[0]), float(h.get("lift", 0.0)), float(p[2]))
			for record in victims:
				SimAuthority.push_player(record, force)
		run["hazard_t"][id] = t

## Walk the run as far as its triggers allow.
func advance(map_id: String) -> void:
	var run: Dictionary = runs.get(map_id, {})
	if run.is_empty():
		return
	var steps: Array = run["def"].get("steps", [])
	var changed := false
	while int(run["step"]) < steps.size():
		var step: Dictionary = steps[int(run["step"])]
		if not _triggered(map_id, run, String(step.get("on", "enter"))):
			break
		_act(map_id, run, step)
		run["step"] = int(run["step"]) + 1
		changed = true
	if changed:
		_publish(map_id, run)

func _triggered(map_id: String, run: Dictionary, on: String) -> bool:
	if on == "enter":
		return true
	if on.begins_with("cleared:"):
		var list: Array = (run["spawned"] as Dictionary).get(on.substr(8), [])
		if list.is_empty():
			return false
		for mob in list:
			if is_instance_valid(mob) and mob.state != mob.State.DEAD:
				return false
		return true
	if on.begins_with("hp_below:"):
		# hp_below:<step id>:<fraction> - a creature that step spawned is down to
		# that share of its hit points (or already dead).
		var bits := on.split(":")
		var watched: Array = (run["spawned"] as Dictionary).get(bits[1] if bits.size() > 1 else "", [])
		var fraction := float(bits[2]) if bits.size() > 2 else 0.5
		for mob in watched:
			if not is_instance_valid(mob) or mob.state == mob.State.DEAD:
				return true
			if mob.max_hp > 0 and float(mob.current_hp) / float(mob.max_hp) < fraction:
				return true
		return false
	if on.begins_with("area:"):
		var z_below := float(on.substr(5))
		var origin: Vector3 = run["origin"]
		for uid in SimAuthority.players_by_peer.values():
			var record: Dictionary = SimAuthority.entities.get(uid, {})
			if int(record.get("kind", 0)) != HPProtocol.Kind.PLAYER or String(record.get("map_id", "")) != map_id:
				continue
			var node = record.get("node")
			if node != null and is_instance_valid(node) and (node as Node3D).global_position.z - origin.z < z_below:
				return true
		return false
	return false

func _act(map_id: String, run: Dictionary, step: Dictionary) -> void:
	var origin: Vector3 = run["origin"]
	var id := String(step.get("id", ""))
	if step.has("spawn"):
		var list: Array = []
		var pack_id := _next_pack
		_next_pack += 1
		for entry in step["spawn"]:
			var mob := _spawn(map_id, entry as Dictionary, origin, pack_id)
			if mob != null:
				list.append(mob)
		run["spawned"][id] = list
	for gate in step.get("open", []):
		run["open"][String(gate)] = true
	for gate in step.get("close", []):
		run["open"].erase(String(gate))
	if step.has("message"):
		run["message"] = String(step["message"])
	if step.has("chest"):
		var chest: Dictionary = step["chest"]
		SimAuthority.drop_loot_table(String(chest.get("table", "")), origin + _vec(chest.get("at", [])), map_id)
	if bool(step.get("complete", false)):
		run["complete"] = true
		_grant_title(map_id, run)
		for record in _players(map_id, false):
			SimAuthority.quest_event(record, "dungeon", String(run["def"].get("id", "")))
	run["done"][id] = true
	# A boss behind shut gates: remembered so a wipe can reopen them.
	var on := String(step.get("on", ""))
	if not (step.get("close", []) as Array).is_empty() and on.begins_with("area:"):
		run["lock"] = {"step": id, "gates": (step["close"] as Array).duplicate(), "z": float(on.substr(5)),
			"sealed": true, "message": String(step.get("message", ""))}
	print("[Dungeon] %s step '%s'" % [map_id, id])

## dungeons.json first_clear_title: everyone in the copy when the run completes.
func _grant_title(map_id: String, run: Dictionary) -> void:
	var title: Dictionary = run["def"].get("first_clear_title", {})
	if title.is_empty():
		return
	for record in _players(map_id, false):
		if SimAuthority.grant_title(record, String(title.get("id", ""))):
			SimNet._tell(record, "New title earned: %s!" % String(title.get("name", "")))

func _spawn(map_id: String, entry: Dictionary, origin: Vector3, pack_id: int) -> Node3D:
	var species := String(entry.get("mob", ""))
	var path := HPRules.mob_scene_path(species)
	if path == "" or not ResourceLoader.exists(path):
		push_error("[Dungeon] %s: no scene for '%s'" % [map_id, species])
		return null
	var mob = (load(path) as PackedScene).instantiate()
	var at: Vector3 = origin + _vec(entry.get("at", []))
	mob.position = at
	mob.pack_anchor = at
	mob.pack_id = pack_id
	mob.managed_respawn = true   # a dungeon creature stays dead
	mob.encounter_id = "dng:%s:%d" % [map_id, pack_id]
	mob.level = int(entry.get("level", 1))
	var pack := {"mob": species, "level": int(entry.get("level", 1))}
	if encounters != null:
		encounters._configure_member(mob, pack, false, species)
	mob.aggro_mode = "aggressive"
	mob.assist_radius = 22.0
	mob.leash_distance = 70.0
	if entry.has("boss_key") and encounters != null:
		encounters._apply_boss(mob, {"boss_key": String(entry["boss_key"]),
			"template": HPRules.encounter_template(String(entry.get("template", "boss_solo")))})
		mob.set_meta("boss_key", String(entry["boss_key"]))
	if entry.has("harp") and "harp_point" in mob:
		mob.harp_point = origin + _vec(entry["harp"])
	# A boss with its own beats (Fluffy's harp, a head fainting) speaks through
	# the run's message line.
	if mob.has_signal("dungeon_message"):
		mob.dungeon_message.connect(func(text: String) -> void:
			var live: Dictionary = runs.get(map_id, {})
			if not live.is_empty():
				live["message"] = text
				_publish(map_id, live))
	container.add_child(mob)
	SimAuthority.register_mob(mob, pack_id, "")
	return mob

func _publish(map_id: String, run: Dictionary) -> void:
	var steps: Array = run["def"].get("steps", [])
	var index := mini(int(run["step"]), steps.size()) - 1
	var state := {"dungeon": String(run["def"].get("id", "")),
		"step": String((steps[index] as Dictionary).get("id", "")) if index >= 0 else "",
		"open": (run["open"] as Dictionary).keys(), "message": String(run["message"]),
		"complete": bool(run["complete"])}
	for node in get_tree().get_nodes_in_group("dungeon_instance"):
		if String(node.get_meta("map_id", "")) == map_id and node.has_method("apply_state"):
			node.apply_state(state)
	SimAuthority.publish_dungeon_state(map_id, state)

## Test/debug surface.
func run_state(map_id: String) -> Dictionary:
	return runs.get(map_id, {})

static func _vec(raw: Array) -> Vector3:
	return Vector3(float(raw[0]), float(raw[1]), float(raw[2])) if raw.size() == 3 else Vector3.ZERO
