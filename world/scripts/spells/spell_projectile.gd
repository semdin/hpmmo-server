extends Area3D

const SkillFX = preload("res://scripts/spells/skill_fx.gd")
const Rules = preload("res://scripts/spells/combat_rules.gd")
const VFX = preload("res://scripts/spells/vfx_library.gd")
## How long a view that met a body waits there for the authority's verdict.
const HOLD_SECONDS := 0.35
## A spark that flies at nothing burns out this far before its aim point.
const BURNOUT_METRES := 1.1
@export var speed := 40.0
@export var damage := 40
@export var spell_id := "basic_cast"
@export var spell_color := Color(1, 0.85, 0.4)
@export var max_lifetime := 4.0
var direction := Vector3.FORWARD
var caster: Node3D
var target_node: Node3D
var lifetime := 0.0
var spent := false
var visual_only := false
var _base_scale := Vector3.ONE
var _reflection_grace := 0.0
## Where the bolt really is on its straight (or homing) path; every hit test
## uses it. The node itself is drawn off it by the curve (`_bend`), so a spell
## that bends (vfx_library `curve`) arcs to the same point at the same moment.
var _path_pos := Vector3.ZERO
var _travelled := 0.0
var _curve_length := 1.0
var _curve_amp := 0.0
var _curve_side := Vector3.ZERO
## The drawn direction of travel (the curve's tangent), read by the travel stage.
var visual_direction := Vector3.FORWARD
## Where the cast was aimed (INF when unknown).
var _end_point := Vector3.INF
## A view that met a body stays on it (`_held_on`) until the authority's
## `cast_landed` says hit (`end_on_landed`) or miss (`on_missed`).
var _held_on: Node3D = null
var _held_offset := Vector3.ZERO
var _hold_left := 0.0
## The authority's victim this view finishes its flight onto (`end_on_landed`).
var _rush_to: Node3D = null
var _missed := false
@onready var mesh: MeshInstance3D = $MeshInstance3D
@onready var light: OmniLight3D = $OmniLight3D
@onready var travel_slot: Node3D = get_node_or_null("TravelFx")
## The travel stage (authored core mesh, tapered ribbon, wisps) is
## built by the effect scene and parented here, so it dies with the bolt.
var travel_effect: Node3D

func _ready() -> void:
	body_entered.connect(_on_overlap)
	area_entered.connect(_on_area_entered)
	collision_mask = 3

## `end_point` is where the cast was aimed (the curve's far end); without one
## the curve spans a typical flight.
func setup(source: Node3D, id: String, aim: Vector3, target: Node3D = null, bonus_mult: float = 1.0,
		end_point: Vector3 = Vector3.INF) -> void:
	caster = source
	spell_id = id
	direction = aim.normalized() if aim.length_squared() > 0.001 else Vector3.FORWARD
	visual_direction = direction
	target_node = target
	_path_pos = global_position
	_end_point = end_point
	_setup_curve(end_point)
	var data: Dictionary = GameData.SPELLS.get(id, {})
	damage = int(data.get("damage", 40) * bonus_mult)
	speed = float(data.get("projectile_speed", 40))
	max_lifetime = float(data.get("range", 36)) / speed
	spell_color = data.get("color", Color.WHITE)
	if bool((VFX.SPELLS.get(id, {}) as Dictionary).get("house_colour", false)):
		spell_color = VFX.colours_for(id, source)[0]
	# These wand bolts are entirely light layers. A second, full-size imported
	# carrier obscured the streak and read as a flying solid block.
	# The travel composition owns every spell's visible body: the carrier mesh
	# stays hidden. It used to load the authored core scene, instance it and
	# dress it in a new material on every cast (up to ~28 ms on the cast's
	# frame, perf_probe 2026-10-30) for a mesh nobody sees.
	mesh.visible = false
	_base_scale = Vector3(0.7, 0.7, 1.0) if id == "basic_cast" else Vector3(1.1, 1.1, 1.0)
	light.light_color = spell_color
	# the basic flick is one small spark: it barely lights what it passes
	light.light_energy = 0.6 if id == "basic_cast" else 1.5
	light.omni_range = 2.5 if id == "basic_cast" else 4.0
	light.visible = SkillFX.quality() != "low"
	look_at(global_position + direction, Rules.safe_up(direction))
	travel_effect = SkillFX.spawn_stage(travel_slot if travel_slot != null else get_parent(),
		id, "travel", global_position, direction, caster, {"follow_target": self})
	SkillFX.play_cast(get_parent(), caster, id, global_position, direction)

## A sideways bend for a spell whose table asks for one: a random angle around
## the flight (rarely much below it, so it does not dive into the floor), sized
## by the flight's length.
func _setup_curve(end_point: Vector3) -> void:
	var bend := float((VFX.SPELLS.get(spell_id, {}) as Dictionary).get("curve", 0.0))
	if bend <= 0.0:
		return
	var end := end_point
	if target_node != null and is_instance_valid(target_node):
		end = SkillFX.body_chest(target_node)
	_curve_length = maxf(1.0, global_position.distance_to(end)) if end.is_finite() else 15.0
	_curve_amp = clampf(bend * _curve_length, 0.25, 1.5)
	var right := direction.cross(Vector3.UP)
	right = right.normalized() if right.length_squared() > 0.0001 else Vector3.RIGHT
	var up := right.cross(direction).normalized()
	var angle := randf_range(-0.15 * PI, 1.15 * PI)
	_curve_side = (right * cos(angle) + up * sin(angle)).normalized()

func _bend() -> Vector3:
	if _curve_amp <= 0.0:
		return Vector3.ZERO
	return _curve_side * _curve_amp * sin(PI * clampf(_travelled / _curve_length, 0.0, 1.0))

func _physics_process(delta: float) -> void:
	if _rush_to != null:
		_tick_rush(delta)
		return
	if _held_on != null:
		_tick_hold(delta)
		return
	if spent:
		return
	lifetime += delta
	_reflection_grace = maxf(0, _reflection_grace - delta)
	if lifetime >= max_lifetime:
		global_position = _path_pos
		if HPRules.delivery(spell_id) == "projectile_aoe":
			_handle_hit(null)
		else:
			# out of range: the travel stage ends, never left running; a spark
			# drifts on and burns out
			_fizzle(visual_direction * speed * 0.07)
		return
	# Aimed at a body: steer onto its chest every frame, as the authority's bolt
	# does, so a target up or down a slope is met on screen where it is hit.
	var homing := _homing_target()
	var from := _path_pos
	if homing != null:
		var chest := SkillFX.body_chest(homing)
		if (chest - from).length_squared() > 0.0001:
			direction = (chest - from).normalized()
	# Aimed at nothing: the spark burns out just short of its aim point and
	# floats down instead of diving into the grass.
	if homing == null and target_node == null and _fizzles() and _end_point.is_finite() \
			and from.distance_to(_end_point) <= BURNOUT_METRES:
		_fizzle(visual_direction * speed * 0.07)
		return
	var next := from + direction * speed * delta
	# Swept ray prevents fast spells tunnelling through thin walls/enemies.
	var query := PhysicsRayQueryParameters3D.create(from, next, 3)
	var excluded: Array[RID] = [get_rid()]
	for npc in get_tree().get_nodes_in_group("npcs"):
		excluded.append(npc.get_rid())
	for player in get_tree().get_nodes_in_group("players"):
		if player == caster or (is_instance_valid(caster) and caster.is_in_group("players")):
			excluded.append(player.get_rid())
	if is_instance_valid(caster) and caster is CollisionObject3D:
		excluded.append(caster.get_rid())
	query.exclude = excluded
	var hit := get_world_3d().direct_space_state.intersect_ray(query)
	# A creature's bolt passes through other creatures. Skip the ones actually
	# on the segment instead of excluding every creature in the world (~4500
	# RIDs per bolt per frame on the server).
	var mob_caster := is_instance_valid(caster) and caster.is_in_group("mobs")
	var skips := 0
	while mob_caster and not hit.is_empty() and hit.collider is Node and (hit.collider as Node).is_in_group("mobs") and skips < 8:
		excluded.append((hit.collider as CollisionObject3D).get_rid())
		query.exclude = excluded
		hit = get_world_3d().direct_space_state.intersect_ray(query)
		skips += 1
	if mob_caster and not hit.is_empty() and hit.collider is Node and (hit.collider as Node).is_in_group("mobs"):
		hit = {}
	# A homing bolt skims over ground between caster and target (the
	# authority's HOMING_GROUND_NORMAL_Y); walls still stop it.
	if homing != null and not hit.is_empty() and hit.collider != homing \
			and not (hit.collider is Node and (hit.collider as Node).has_method("take_damage")) \
			and (hit.normal as Vector3).y >= SimAuthority.HOMING_GROUND_NORMAL_Y:
		hit = {}
	if not hit.is_empty():
		_path_pos = hit.position
		global_position = _path_pos
		_on_body_entered(hit.collider)
		if spent:
			return
	else:
		_path_pos = next
	_travelled += from.distance_to(_path_pos)
	var drawn_from := global_position
	global_position = _path_pos + _bend()
	var drawn := global_position - drawn_from
	visual_direction = drawn.normalized() if drawn.length_squared() > 0.000001 else direction
	look_at(global_position + visual_direction, Rules.safe_up(visual_direction))
	# a gentle pulse, never an abrupt on/off
	mesh.scale = _base_scale * (1 + sin(lifetime * 18.0) * 0.06)

## The aimed-at body while it is alive, else null (the bolt flies straight on).
func _homing_target() -> Node3D:
	if target_node == null or not is_instance_valid(target_node) or not target_node.is_inside_tree():
		return null
	if "is_dead" in target_node and bool(target_node.get("is_dead")):
		return null
	if "is_destroyed" in target_node and bool(target_node.get("is_destroyed")):
		return null
	return target_node

## The area brushed a body. A homing bolt leaves scenery to the swept ray
## (which tells a hump it skims from a wall it stops at).
func _on_overlap(body: Node3D) -> void:
	if _curve_amp > 0.0:
		return   # a curving bolt's body is off its path; the swept ray decides
	if _homing_target() != null and body != target_node and not body.has_method("take_damage"):
		return
	_on_body_entered(body)

func _on_body_entered(body: Node3D) -> void:
	if spent or body == caster:
		return
	if body.has_method("take_damage") and not Rules.can_damage(caster, body):
		return
	if "is_protego_active" in body and body.is_protego_active:
		_reflect_projectile(body)
		return
	_handle_hit(body)

func _on_area_entered(area: Area3D) -> void:
	if area.is_in_group("shields") and Rules.can_damage(caster, area.get_parent()):
		_reflect_projectile(area.get_parent())

func _reflect_projectile(owner_node: Node3D) -> void:
	if spent or _reflection_grace > 0:
		return
	direction = -direction
	caster = owner_node
	_curve_amp = 0.0   # a reflected bolt flies straight back
	global_position = _path_pos
	_reflection_grace = 0.12
	speed *= 1.1

## The projectile is a VIEW. Damage is decided by the authority: this call is a
## report that the bolt reached something, and the engine answers with the
## numbers (and refuses when the target is protected, already dead, or the caster
## was not allowed to hit it in the first place).
func _handle_hit(target: Node) -> void:
	if spent:
		return
	spent = true
	if not visual_only and SimAuthority.is_authority():
		if HPRules.delivery(spell_id) == "projectile_aoe":
			var radius := float(GameData.SPELLS[spell_id].get("radius", 9))
			SimAuthority.spell_area_impact(caster, global_position, radius, spell_id, damage)
		elif Rules.can_damage(caster, target):
			SimAuthority.apply_damage(target, damage, spell_id, caster)
	# A view that reached a damageable body waits on it for the authority's
	# `cast_landed`: a hit strikes there (end_on_landed), a miss burns out
	# (on_missed). Ground, walls and area blasts are drawn here.
	var victim_hit := visual_only and target != null and is_instance_valid(target) \
		and target.has_method("take_damage") and HPRules.delivery(spell_id) != "projectile_aoe"
	if victim_hit:
		if _missed:
			_fizzle(-direction * 1.2 + Vector3.UP * 0.4)
			return
		_held_on = target as Node3D
		_held_offset = global_position - _held_on.global_position
		_hold_left = HOLD_SECONDS
		return
	if _fizzles() and not (target != null and target.has_method("take_damage")):
		# a spark that met the ground or a wall skips off it and burns out
		_fizzle(-direction * 1.4 + Vector3.UP * 0.9)
		return
	SkillFX.play_impact(get_parent(), global_position, spell_id, target, direction, caster)
	if travel_effect != null and is_instance_valid(travel_effect):
		_end_travel("spent")
	queue_free()

## The authority's area bolt burst at `pos` (game_world `cast_impact`): this
## view bursts there too, whether it was still flying or a little short.
func detonate_at(pos: Vector3) -> void:
	if spent:
		return
	spent = true
	global_position = pos
	SkillFX.play_impact(get_parent(), pos, spell_id, null, direction, caster)
	if travel_effect != null and is_instance_valid(travel_effect):
		_end_travel("spent")
	queue_free()

## The authority says this cast hit `victim`. A view still short of it finishes
## its flight onto the body in a few frames and strikes there; a view waiting on
## it strikes now. True when this view draws the impact (game_world then does
## not draw a second one).
func end_on_landed(victim: Node3D = null) -> bool:
	if victim == null or not is_instance_valid(victim) or not victim.is_inside_tree():
		if spent and _held_on == null and _rush_to == null:
			return false
		spent = true
		_held_on = null
		_rush_to = null
		if travel_effect != null and is_instance_valid(travel_effect):
			_end_travel("landed")
		queue_free()
		return false
	if _held_on != null and _held_on == victim:
		_strike(victim, global_position)
		return true
	if spent and _held_on == null:
		return false
	spent = true
	_held_on = null
	_rush_to = victim
	return true

## The authority says this cast hit nothing: a view waiting on a body burns
## out, one still flying does when its flight ends.
func on_missed() -> void:
	_missed = true
	if _held_on != null:
		_fizzle(-direction * 1.2 + Vector3.UP * 0.4)

func _tick_rush(delta: float) -> void:
	if not is_instance_valid(_rush_to) or not _rush_to.is_inside_tree():
		_rush_to = null
		_fizzle(direction * 2.0)
		return
	var contact := SkillFX.body_contact(_rush_to, direction)
	var to := contact - global_position
	# At least 2.5x its flight speed, and never more than ~4 frames away.
	var step := maxf(speed * 2.5, to.length() / 0.06) * delta
	if to.length() <= step:
		_strike(_rush_to, contact)
		return
	direction = to.normalized()
	visual_direction = direction
	global_position += direction * step
	look_at(global_position + direction, Rules.safe_up(direction))

func _tick_hold(delta: float) -> void:
	_hold_left -= delta
	if not is_instance_valid(_held_on) or not _held_on.is_inside_tree() or _hold_left <= 0.0:
		_held_on = null
		_fizzle(-direction * 1.2 + Vector3.UP * 0.4)
		return
	global_position = _held_on.global_position + _held_offset

func _strike(victim: Node3D, at: Vector3) -> void:
	_rush_to = null
	_held_on = null
	spent = true
	global_position = at
	SkillFX.play_hit_on(get_parent(), victim, spell_id, direction, caster, at)
	if travel_effect != null and is_instance_valid(travel_effect):
		_end_travel("spent")
	queue_free()

## A spell whose spark burns out when it hits nothing (vfx_library `fizzle`).
func _fizzles() -> bool:
	return bool((VFX.SPELLS.get(spell_id, {}) as Dictionary).get("fizzle", false))

## The bolt ends without a victim: its wake fades, and a spark that fizzles
## floats on as an ember (SparkEmber) with `push` left in it.
func _fizzle(push: Vector3) -> void:
	spent = true
	_held_on = null
	_rush_to = null
	if travel_effect != null and is_instance_valid(travel_effect):
		_end_travel("missed")
	if _fizzles():
		SparkEmber.spawn(get_parent(), global_position, push, spell_color)
	queue_free()


func _end_travel(reason: String) -> void:
	if HPRules.delivery(spell_id) in ["projectile", "projectile_aoe"]:
		# Keep the last quarter-second of filaments in world space at impact.
		travel_effect.reparent(get_parent(), true)
		travel_effect.call("retire_travel")
	else:
		travel_effect.call("cancel", reason)
