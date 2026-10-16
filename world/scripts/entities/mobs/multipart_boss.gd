extends "res://scripts/entities/mobs/mob_base.gd"

## A creature made of targetable parts (mobs.json `parts`): Fluffy's three
## heads, the Devil's Snare's three vines.
##
## Authority: once the body is registered it grows one boss_part per bone
## (catalog `parts.bones`, hit points from boss_overrides `part_hp`), carries
## them on those bones every frame, and is IMMUNE while any part stands. A
## part's death is published on the body's mob info (`parts_down`) so every
## client droops/withers that chain. What happens when the last part falls is
## the subclass's call (`_all_parts_down`): Fluffy dies, the Snare's heart opens.
##
## Clients: a puppet only reads `parts_down` and bends the chains.

signal dungeon_message(text: String)

## Whether the body's hit points are the sum of its parts (Fluffy) or its own
## pool behind them (the Snare).
var hp_is_sum := true
## Bone chains each part key bends when it is down (root first).
var droop_chains: Dictionary = {}
var droop_degrees := 22.0
var droop_shrink := 1.0

var parts: Dictionary = {}          # key -> boss_part node (authority)
var parts_down: Array = []
var _parts_spawned := false
var _skeleton: Skeleton3D
var _droop: Node
var _down_poll := 0.0

func _ready() -> void:
	immune = true   # until the last part falls (read by the authority at registration)
	super()
	_skeleton = visuals.find_child("Skeleton3D", true, false) as Skeleton3D if visuals else null
	if _skeleton != null and not droop_chains.is_empty():
		_droop = preload("res://scripts/entities/mobs/part_droop.gd").new()
		_droop.name = "PartDroop"
		_droop.chains = droop_chains
		_droop.bend_degrees = droop_degrees
		_droop.shrink = droop_shrink
		_skeleton.add_child(_droop)

func _physics_process(delta: float) -> void:
	super(delta)
	if sim_puppet:
		_down_poll -= delta
		if _down_poll <= 0.0:
			_down_poll = 0.4
			var record := SimAuthority.record_for(self)
			var down: Array = record.get("parts_down", [])
			if down != parts_down:
				parts_down = down.duplicate()
				_apply_droop()
		return
	if not SimAuthority.is_authority():
		return
	if not _parts_spawned:
		if not SimAuthority.record_for(self).is_empty():
			_spawn_parts()
		return
	_tick_parts()

# ------------------------------------------------------------------ parts

func _part_def() -> Dictionary:
	return HPRules.mob_def(species).get("parts", {})

func _boss_data() -> Dictionary:
	return (HPRules.spawn_tables().get("boss_overrides", {}) as Dictionary).get(String(get_meta("boss_key", "")), {})

func _spawn_parts() -> void:
	_parts_spawned = true
	var def := _part_def()
	var part_species := String(def.get("species", ""))
	var path := HPRules.mob_scene_path(part_species)
	if path == "" or not ResourceLoader.exists(path):
		push_error("[Boss] %s: no part scene for '%s'" % [species, part_species])
		return
	var part_def := HPRules.mob_def(part_species)
	var hp := int(_boss_data().get("part_hp", (part_def.get("base", {}) as Dictionary).get("max_hp", 1000)))
	var bones: Dictionary = def.get("bones", {})
	for key in bones.keys():
		var part = (load(path) as PackedScene).instantiate()
		part.owner_body = self
		part.part_key = String(key)
		part.bone_name = String(bones[key])
		part.species = part_species
		part.mob_name = _part_name(String(key), String(part_def.get("display", "Part")))
		part.level = level
		part.max_hp = hp
		part.current_hp = hp
		part.pack_id = pack_id
		part.encounter_id = encounter_id
		part.managed_respawn = true
		part.resist = HPRules.mob_resist(part_species)
		part.exp_reward = 0
		part.position = _bone_position(part.bone_name)
		get_parent().add_child(part)
		SimAuthority.register_mob(part, pack_id, "")
		parts[String(key)] = part
	if hp_is_sum:
		max_hp = hp * parts.size()
		SimAuthority.set_mob_hp(self, max_hp, max_hp)
	SimAuthority.set_mob_immune(self, true)

func _part_name(key: String, display: String) -> String:
	var side: String = {"L": "Left", "R": "Right", "M": "Middle", "T": "Upper"}.get(key, key)
	# "Fluffy's Head" -> "Fluffy's Left Head"; "Snare Vine" -> "Snare Left Vine".
	var words := display.split(" ")
	words.insert(words.size() - 1, side)
	return " ".join(words)

func _bone_position(bone: String) -> Vector3:
	if _skeleton == null:
		return global_position + Vector3.UP * 3.0
	var idx := _skeleton.find_bone(bone)
	if idx < 0:
		return global_position + Vector3.UP * 3.0
	return _skeleton.global_transform * _skeleton.get_bone_global_pose(idx).origin

func _tick_parts() -> void:
	var total := 0
	for key in parts.keys():
		var part = parts[key]
		if not is_instance_valid(part):
			continue
		if part.state == State.DEAD:
			if not parts_down.has(key):
				parts_down.append(key)
				SimAuthority.mark_part_down(self, key)
				_apply_droop()
				_on_part_down(key)
			continue
		part.global_position = _bone_position(part.bone_name)
		total += int(part.current_hp)
	if hp_is_sum and state != State.DEAD:
		if total > 0:
			SimAuthority.set_mob_hp(self, total)
	if parts_down.size() == parts.size() and not parts.is_empty() and state != State.DEAD and immune:
		immune = false
		_all_parts_down()

func living_parts() -> Array:
	var out: Array = []
	for key in parts.keys():
		if is_instance_valid(parts[key]) and parts[key].state != State.DEAD:
			out.append(parts[key])
	return out

## Subclass hooks.
func _on_part_down(_key: String) -> void:
	pass

func _all_parts_down() -> void:
	pass

func _apply_droop() -> void:
	if _droop != null:
		_droop.down = parts_down.duplicate()

## The body's own death (or a torn-down copy) takes the parts with it.
func on_authoritative_death(killer: Node3D) -> void:
	super(killer)
	if sim_puppet:
		return
	for part in parts.values():
		if is_instance_valid(part) and part.state != State.DEAD:
			SimAuthority.force_kill(part)

func _exit_tree() -> void:
	if not sim_puppet:
		for part in parts.values():
			if is_instance_valid(part):
				SimAuthority.unregister_node(part)
				part.queue_free()
