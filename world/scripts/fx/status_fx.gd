extends Node3D
class_name StatusFX

## What crowd control and damage over time look like on a body: the status
## byte the authority replicates (HPProtocol.STATUS_*), drawn the same way on
## every client for creatures and players alike.
##
##   stun     gold stars circling the head and red sparks dripping off the body
##   freeze   a clear ice shell over the body, crystals at its feet, cold mist
##            rolling off it, the pose held; the ice bursts when it thaws
##   slow     rime creeping up from the feet, frost motes and a cold mist, the
##            animation at the slowed pace
##   bleed    wet stains on the body, drops, a spurt now and then, and a
##            trail of blood on the ground behind it
##   burn     the body is on fire: a few big tongues of flame off its back and
##            shoulders, sparks, smoke over its head, a little soot and the
##            fire's glow on it, a flickering firelight (the spell, an ignite proc)
##   poison   a faint green sheen, green vapour rising, bubbles
##   knocked  dust where the throw starts and where it lands
##   weak     (disarmed) only its name
##
## A status that begins pops its name over the body (HitFeedback). Bodies call
## `StatusFX.update(self, bits)` a few times a second; nothing is built on a
## headless or dedicated process. Presentation only: the rules live in the
## authority's *_until_tick fields.

const SkillFX = preload("res://scripts/spells/skill_fx.gd")
const STAR_TEX := "res://assets/vfx/tex/star_flare_256.png"
const GLOW_TEX := "res://assets/vfx/tex/soft_glow_512.png"
const FLAME_ATLAS := "res://assets/vfx/atlases/flame_loop_8x8_1k.png"
const SMOKE_ATLAS := "res://assets/vfx/atlases/smoke_puff_8x8_1k.png"
const NOISE_TEX := "res://assets/vfx/tex/noise_erosion_512.png"
const SKIN_SHADER := preload("res://assets/shaders/status_skin.gdshader")
const FLAME_SHADER := preload("res://assets/shaders/body_flame.gdshader")
const BURN_SOUND := "spell_incendio_sustain"
## Blood left on the ground at a time, per bleeding body.
const MAX_SPLATS := 5
const POP_RANGE := 45.0
## One pop per status per this many seconds across all bodies: a blast that
## stuns six creatures says so once, not six times on top of each other.
const POP_GAP := 0.35

const BITS := [HPProtocol.STATUS_STUN, HPProtocol.STATUS_FREEZE, HPProtocol.STATUS_SLOW,
	HPProtocol.STATUS_BLEED, HPProtocol.STATUS_BURN, HPProtocol.STATUS_POISON,
	HPProtocol.STATUS_KNOCKED, HPProtocol.STATUS_WEAK]

# i18n-begin
## What pops over the body when a status begins: [text, colour].
const POPS := {
	HPProtocol.STATUS_STUN: ["Stunned!", Color(1.0, 0.86, 0.3)],
	HPProtocol.STATUS_FREEZE: ["Frozen!", Color(0.62, 0.9, 1.0)],
	HPProtocol.STATUS_SLOW: ["Slowed", Color(0.55, 0.78, 1.0)],
	HPProtocol.STATUS_BLEED: ["Bleeding", Color(1.0, 0.22, 0.2)],
	HPProtocol.STATUS_BURN: ["Burning", Color(1.0, 0.55, 0.2)],
	HPProtocol.STATUS_POISON: ["Poisoned", Color(0.55, 1.0, 0.35)],
	HPProtocol.STATUS_KNOCKED: ["Knocked back!", Color(1.0, 0.95, 0.82)],
	HPProtocol.STATUS_WEAK: ["Disarmed", Color(0.8, 0.7, 1.0)],
}
# i18n-end

static var _materials: Dictionary = {}
static var _last_pop: Dictionary = {}   # status bit -> msec

var body: Node3D = null
var bits := 0
var _head := 1.9
var _radius := 0.5
## The drawn body's bounds in the body's own space (the meshes at rest), so the
## flames cover a wide low spider as well as a tall troll.
var _bounds := AABB()
var _parts: Dictionary = {}       # status bit -> Node (its look while it runs)
var _overlay: Material = null
var _overlaid: Array = []         # meshes carrying _overlay
var _stars: Node3D = null
## Spell-stage effects that live in the world, following the body (the stun
## sparks, the flames): freed with the status, or with the body.
var _world_parts: Dictionary = {}  # status bit -> Node3D
var _t := 0.0
var _firelight: OmniLight3D = null
var _burn_audio := false
var _spurt_wait := 0.0
var _splats: Array = []
var _cold: ShaderMaterial = null

## Draw `status` on `target` (creating its StatusFX child the first time).
static func update(target: Node3D, status: int) -> void:
	if target == null or not is_instance_valid(target) or not target.is_inside_tree():
		return
	if NetworkManager.is_dedicated_server or not HitFeedback.enabled():
		return
	var fx := target.get_node_or_null("StatusFX") as StatusFX
	if fx == null:
		if status == 0:
			return
		fx = StatusFX.new()
		fx.name = "StatusFX"
		fx.body = target
		target.add_child(fx)
	fx._apply(status)

func _ready() -> void:
	_measure()
	set_process(false)

## Head height and girth from the body's nameplate and collision shape.
func _measure() -> void:
	for label_name in ["Label3D", "NameplateLabel3D", "HpLabel3D", "DummyLabel"]:
		var label := body.get_node_or_null(label_name) as Node3D
		if label != null:
			_head = clampf(label.position.y - 0.45, 1.0, 6.0)
			break
	for child in body.get_children():
		if child is CollisionShape3D and (child as CollisionShape3D).shape != null:
			var shape: Shape3D = (child as CollisionShape3D).shape
			if shape is CapsuleShape3D:
				_radius = (shape as CapsuleShape3D).radius
			elif shape is CylinderShape3D:
				_radius = (shape as CylinderShape3D).radius
			elif shape is SphereShape3D:
				_radius = (shape as SphereShape3D).radius
			elif shape is BoxShape3D:
				_radius = maxf((shape as BoxShape3D).size.x, (shape as BoxShape3D).size.z) * 0.5
			break
	_radius = clampf(_radius, 0.3, 2.5)
	_bounds = AABB(Vector3(-_radius, 0.0, -_radius), Vector3(_radius * 2.0, _head, _radius * 2.0))
	var root = body.get("visuals")
	var meshes: Array = []
	_collect(root if root is Node3D else body, meshes)
	var found := false
	var to_body := body.global_transform.affine_inverse()
	var merged := AABB()
	for mesh in meshes:
		var box := (to_body * (mesh as VisualInstance3D).global_transform) * (mesh as VisualInstance3D).get_aabb()
		merged = box if not found else merged.merge(box)
		found = true
	# Trust the meshes only when they look like this body (a stray 100x rig
	# scale or an empty mesh would put the fire metres away).
	if found and merged.size.y > 0.3 and merged.size.y < _head * 2.5 + 1.0 			and maxf(merged.size.x, merged.size.z) < _radius * 8.0 + 2.0:
		_bounds = merged

func _apply(status: int) -> void:
	if status == bits:
		return
	var began := status & ~bits
	var ended := bits & ~status
	bits = status
	for bit in BITS:
		if ended & int(bit):
			_end(int(bit))
	for bit in BITS:
		if began & int(bit):
			_begin(int(bit))
	_refresh_overlay()
	_refresh_pace()
	set_process(_stars != null or bits & (HPProtocol.STATUS_BURN | HPProtocol.STATUS_BLEED) != 0)

func _exit_tree() -> void:
	_stop_burn_audio()
	_clear_overlay()
	for part in _world_parts.values():
		if part is Node and is_instance_valid(part):
			(part as Node).queue_free()
	_world_parts.clear()

func _process(delta: float) -> void:
	_t += delta
	if _stars != null and is_instance_valid(_stars):
		_stars.rotation.y = _t * 3.4
		_stars.position.y = _head + 0.4 + sin(_t * 5.0) * 0.06
	if _firelight != null and is_instance_valid(_firelight):
		# firelight never holds still
		_firelight.light_energy = 1.5 + sin(_t * 23.0) * 0.25 + sin(_t * 9.7) * 0.3 + randf() * 0.25
	if _burn_audio:
		var audio := SkillFX.audio_manager()
		if audio != null:
			audio.call("move_loop", BURN_SOUND, self, global_position)
	if bits & HPProtocol.STATUS_BLEED:
		_spurt_wait -= delta
		if _spurt_wait <= 0.0:
			_spurt_wait = randf_range(0.8, 1.4)
			_spurt()

# ------------------------------------------------------------------ begin/end

func _begin(bit: int) -> void:
	_pop(bit)
	match bit:
		HPProtocol.STATUS_STUN:
			_stars = _make_stars()
			_parts[bit] = _stars
			_world_parts[bit] = SkillFX.spawn_stage(body.get_parent(), "stupefy", "sustain", body.global_position + Vector3.UP * (_head + 0.1),
				Vector3.UP, null, {"follow_target": body, "duration": 30.0})
		HPProtocol.STATUS_FREEZE:
			_parts[bit] = _holder("Freeze", [_make_crystals(), _make_mist(Color(0.82, 0.93, 1.0, 0.32), -0.25, 5)])
		HPProtocol.STATUS_SLOW:
			_parts[bit] = _holder("Slow", [_make_motes(Color(0.7, 0.9, 1.0, 0.9), -1.2, 10, 1.1, 0.09),
				_make_mist(Color(0.78, 0.9, 1.0, 0.22), -0.12, 4)])
		HPProtocol.STATUS_BLEED:
			_parts[bit] = _make_drops()
			_spurt_wait = 0.25
		HPProtocol.STATUS_BURN:
			_parts[bit] = _make_fire()
		HPProtocol.STATUS_POISON:
			_parts[bit] = _holder("Poison", [_make_motes(Color(0.45, 1.0, 0.3, 0.8), 1.4, 8, 1.0, 0.11),
				_make_mist(Color(0.45, 0.75, 0.3, 0.12), 0.3, 3, 0.55)])
		HPProtocol.STATUS_KNOCKED:
			_dust(1.0)

func _end(bit: int) -> void:
	for parts in [_parts, _world_parts]:
		var part = parts.get(bit)
		parts.erase(bit)
		if part is Node and is_instance_valid(part):
			(part as Node).queue_free()
	match bit:
		HPProtocol.STATUS_STUN:
			_stars = null
		HPProtocol.STATUS_BURN:
			_firelight = null
			_stop_burn_audio()
			if is_inside_tree() and not _is_dead():
				_smoke_out()
		HPProtocol.STATUS_FREEZE:
			if is_inside_tree() and not _is_dead():
				_shatter()
		HPProtocol.STATUS_KNOCKED:
			if is_inside_tree() and not _is_dead():
				_dust(1.35)

func _is_dead() -> bool:
	return body.get("is_dead") == true or body.get("current_hp") != null and int(body.get("current_hp")) <= 0

## The status name over the body when it begins (near the camera only).
func _pop(bit: int) -> void:
	if not POPS.has(bit):
		return
	var camera := get_viewport().get_camera_3d()
	if camera == null or camera.global_position.distance_to(body.global_position) > POP_RANGE:
		return
	var now := Time.get_ticks_msec()
	if now - int(_last_pop.get(bit, -100000)) < int(POP_GAP * 1000.0):
		return
	_last_pop[bit] = now
	var feedback := HitFeedback.ensure(body)
	if feedback != null and feedback.is_inside_tree():
		var pop: Array = POPS[bit]
		feedback.show_status(body, tr(String(pop[0])), pop[1])

# ------------------------------------------------------------------ the body

## One overlay at a time, the strongest look first: ice, then fire, rime,
## poison, blood. HitFeedback's flash returns to it (meta `status_overlay`).
func _refresh_overlay() -> void:
	var wanted: Material = null
	if bits & HPProtocol.STATUS_FREEZE:
		wanted = _material("ice")
	elif bits & HPProtocol.STATUS_BURN:
		wanted = _material("burn")
	elif bits & HPProtocol.STATUS_SLOW:
		# rime climbs a third of this body's height (a spider is not a troll)
		if _cold == null:
			_cold = _material("cold").duplicate() as ShaderMaterial
			_cold.set_shader_parameter("reach", clampf(_bounds.size.y * 0.35, 0.2, 1.2))
		wanted = _cold
	elif bits & HPProtocol.STATUS_POISON:
		wanted = _material("poison")
	elif bits & HPProtocol.STATUS_BLEED:
		wanted = _material("blood")
	if wanted == _overlay:
		return
	_clear_overlay()
	_overlay = wanted
	if wanted == null:
		return
	var root = body.get("visuals")
	_collect(root if root is Node3D else body, _overlaid)
	for mesh in _overlaid:
		(mesh as GeometryInstance3D).material_overlay = wanted
		(mesh as Node).set_meta("status_overlay", wanted)

func _clear_overlay() -> void:
	for mesh in _overlaid:
		if is_instance_valid(mesh):
			(mesh as Node).remove_meta("status_overlay")
			if (mesh as GeometryInstance3D).material_overlay == _overlay:
				(mesh as GeometryInstance3D).material_overlay = null
	_overlaid.clear()
	_overlay = null

func _collect(node: Node, out: Array) -> void:
	for child in node.get_children():
		if child == self or child.name == "StatusFX":
			continue
		if child is MeshInstance3D and (child as MeshInstance3D).visible:
			out.append(child)
		if out.size() < 32:
			_collect(child, out)

## Frozen: the pose is held. Slowed: the clips play at the slowed pace.
func _refresh_pace() -> void:
	if not body.has_method("set_cc_anim_scale"):
		return
	var pace := 1.0
	if bits & HPProtocol.STATUS_FREEZE:
		pace = 0.0
	elif bits & HPProtocol.STATUS_SLOW:
		pace = 0.55
	body.call("set_cc_anim_scale", pace)

# ------------------------------------------------------------------ the looks

## Several looks under one node, freed together with their status.
func _holder(holder_name: String, parts: Array) -> Node3D:
	var holder := Node3D.new()
	holder.name = holder_name
	add_child(holder)
	for part in parts:
		(part as Node).reparent(holder, false)
	return holder

## The body on fire: flames licking up off its whole height (they trail behind
## a body that runs, local_coords off), embers flying up, smoke rolling off the
## top, a flickering firelight on everything round it, and its crackle.
func _make_fire() -> Node3D:
	var holder := Node3D.new()
	holder.name = "Burning"
	add_child(holder)
	var low := SkillFX.quality() == "low"
	var middle := _bounds.get_center()
	var half := _bounds.size * 0.5
	# A few big tongues sized to the body (a scatter of small ones read as
	# speckles), rising off its upper half; a wide body gets a couple more.
	var tongue := clampf(minf(maxf(half.x, half.z) * 2.0, _bounds.size.y) * 0.8, 0.55, 1.9)
	var spread_area := clampf((half.x * half.z) / 0.25, 1.0, 1.8)
	var flames := _particles(_material("flame"), int((6 if low else 8) * spread_area), 0.85, tongue)
	flames.reparent(holder, false)
	flames.position = Vector3(middle.x, middle.y + half.y * 0.3, middle.z)
	flames.emission_shape = CPUParticles3D.EMISSION_SHAPE_BOX
	flames.emission_box_extents = Vector3(half.x * 0.45, half.y * 0.3, half.z * 0.45)
	flames.direction = Vector3.UP
	flames.spread = 12.0
	flames.initial_velocity_min = 0.35
	flames.initial_velocity_max = 0.9
	flames.gravity = Vector3(0, 1.4, 0)
	flames.angle_min = -14.0
	flames.angle_max = 14.0
	flames.anim_speed_min = 0.22
	flames.anim_speed_max = 0.32
	flames.anim_offset_max = 1.0
	flames.scale_amount_min = 0.7
	flames.scale_amount_max = 1.25
	flames.scale_amount_curve = _curve([Vector2(0.0, 0.35), Vector2(0.25, 1.0), Vector2(1.0, 0.25)])
	flames.color = Color(1.0, 0.9, 0.8, 1.0)
	flames.color_ramp = _ramp([Color(1, 1, 1, 0.0), Color(1, 1, 1, 1.0), Color(1.0, 0.7, 0.5, 0.0)], [0.0, 0.15, 1.0])
	var embers := _particles(_material("mote"), 4 if low else 6, 1.1, 0.045 * clampf(tongue / 0.5, 0.8, 2.0))
	embers.reparent(holder, false)
	embers.position = Vector3(middle.x, middle.y + half.y * 0.3, middle.z)
	embers.emission_shape = CPUParticles3D.EMISSION_SHAPE_BOX
	embers.emission_box_extents = Vector3(half.x * 0.7, half.y * 0.4, half.z * 0.7)
	embers.direction = Vector3.UP
	embers.spread = 30.0
	embers.initial_velocity_min = 1.2
	embers.initial_velocity_max = 2.6
	embers.gravity = Vector3(0, 0.6, 0)
	embers.damping_min = 0.6
	embers.damping_max = 1.4
	embers.color = Color(1.0, 0.55, 0.15, 1.0)
	var smoke := _particles(_material("smoke"), 4 if low else 7, 1.8, tongue * 1.4)
	smoke.reparent(holder, false)
	smoke.position = Vector3(middle.x, _bounds.end.y, middle.z)
	smoke.emission_shape = CPUParticles3D.EMISSION_SHAPE_BOX
	smoke.emission_box_extents = Vector3(half.x * 0.5, 0.1, half.z * 0.5)
	smoke.direction = Vector3.UP
	smoke.spread = 15.0
	smoke.initial_velocity_min = 0.5
	smoke.initial_velocity_max = 0.9
	smoke.gravity = Vector3(0, 0.3, 0)
	smoke.angle_min = -180.0
	smoke.angle_max = 180.0
	smoke.anim_speed_min = 0.8
	smoke.anim_speed_max = 1.0
	smoke.scale_amount_curve = _curve([Vector2(0.0, 0.5), Vector2(1.0, 1.7)])
	smoke.color = Color(0.13, 0.11, 0.1, 1.0)
	smoke.color_ramp = _ramp([Color(1, 1, 1, 0.0), Color(1, 1, 1, 0.45), Color(1, 1, 1, 0.0)], [0.0, 0.2, 1.0])
	if not low:
		_firelight = OmniLight3D.new()
		_firelight.light_color = Color(1.0, 0.5, 0.18)
		_firelight.omni_range = 3.0 + maxf(half.x, half.z) * 3.0
		_firelight.shadow_enabled = false
		holder.add_child(_firelight)
		_firelight.position = Vector3(middle.x, _bounds.end.y, middle.z)
	var audio := SkillFX.audio_manager()
	if audio != null and audio.has_method("loop_sound"):
		audio.call("loop_sound", BURN_SOUND, self, 0.0)
		_burn_audio = true
	return holder

func _stop_burn_audio() -> void:
	if not _burn_audio:
		return
	_burn_audio = false
	var audio := SkillFX.audio_manager()
	if audio != null:
		audio.call("stop_sound", BURN_SOUND, self)

## The fire goes out in a puff of smoke.
func _smoke_out() -> void:
	var size := clampf(_radius * 2.2, 1.2, 3.6)
	FlipbookFX.play(body.get_parent(), body.global_position + Vector3.UP * (_head * 0.55), [
		{"atlas": "smoke_puff_8x8_1k", "size": size, "height": 0.0, "fps": 26.0, "tint": Color(0.2, 0.18, 0.17), "opacity": 0.5},
	], {"life": 1.3, "name": "BurnOut"})

## Slow-rolling vapour round the body: cold mist sinking off ice and rime
## (`rise` < 0), green fumes rising off poison.
func _make_mist(colour: Color, rise: float, amount: int, size: float = 0.9) -> CPUParticles3D:
	var girth := clampf(_radius / 0.45, 0.8, 2.6)
	var mist := _particles(_material("smoke"), amount, 1.9, size * girth)
	mist.position.y = _head * (0.25 if rise < 0.0 else 0.55)
	mist.emission_shape = CPUParticles3D.EMISSION_SHAPE_SPHERE
	mist.emission_sphere_radius = _radius * 0.8
	mist.direction = Vector3.UP if rise > 0.0 else Vector3.DOWN
	mist.spread = 60.0
	mist.initial_velocity_min = absf(rise) * 0.4
	mist.initial_velocity_max = absf(rise)
	mist.gravity = Vector3.ZERO
	mist.angle_min = -180.0
	mist.angle_max = 180.0
	mist.anim_speed_min = 0.7
	mist.anim_speed_max = 0.9
	mist.scale_amount_curve = _curve([Vector2(0.0, 0.6), Vector2(1.0, 1.5)])
	mist.color = Color(colour.r, colour.g, colour.b, 1.0)
	mist.color_ramp = _ramp([Color(1, 1, 1, 0.0), Color(1, 1, 1, colour.a), Color(1, 1, 1, 0.0)], [0.0, 0.3, 1.0])
	return mist

## A bleeding wound pumps: a few drops thrown out and a fresh spot of blood
## on the ground under the body (the old ones fade as it walks on).
func _spurt() -> void:
	if not is_inside_tree() or _is_dead():
		return
	var spray := _particles(_material("drop"), 6, 0.6, 0.06)
	spray.reparent(body.get_parent(), true)
	spray.global_position = body.global_position + Vector3.UP * (_head * 0.6)
	spray.one_shot = true
	spray.explosiveness = 0.9
	spray.direction = Vector3(randf_range(-1.0, 1.0), 0.6, randf_range(-1.0, 1.0)).normalized()
	spray.spread = 25.0
	spray.initial_velocity_min = 1.2
	spray.initial_velocity_max = 2.4
	spray.gravity = Vector3(0, -9.0, 0)
	spray.color = Color(0.45, 0.0, 0.01, 1.0)
	spray.emitting = true
	spray.finished.connect(spray.queue_free)
	_splat()

func _splat() -> void:
	var space := get_world_3d().direct_space_state
	var from := body.global_position + Vector3.UP * 0.5
	var hit := space.intersect_ray(PhysicsRayQueryParameters3D.create(from, from + Vector3.DOWN * 3.0, 1))
	if hit.is_empty():
		return
	var spot := MeshInstance3D.new()
	var quad := QuadMesh.new()
	var size := randf_range(0.25, 0.45) * clampf(_radius / 0.45, 0.8, 1.8)
	quad.size = Vector2(size, size * randf_range(0.7, 1.0))
	quad.orientation = PlaneMesh.FACE_Y
	quad.material = _material("splat")
	spot.mesh = quad
	spot.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	body.get_parent().add_child(spot)
	spot.global_position = (hit.position as Vector3) + Vector3.UP * 0.03 \
		+ Vector3(randf_range(-0.3, 0.3), 0.0, randf_range(-0.3, 0.3)) * _radius
	spot.rotation.y = randf() * TAU
	spot.transparency = 0.15
	var tw := spot.create_tween()
	tw.tween_interval(3.0)
	tw.tween_property(spot, "transparency", 1.0, 2.5)
	tw.tween_callback(spot.queue_free)
	_splats = _splats.filter(func(s): return is_instance_valid(s))
	_splats.append(spot)
	while _splats.size() > MAX_SPLATS:
		var old = _splats.pop_front()
		if is_instance_valid(old):
			(old as Node).queue_free()

static func _curve(points: Array) -> Curve:
	var curve := Curve.new()
	curve.max_value = 2.0
	for point in points:
		curve.add_point(point)
	return curve

static func _ramp(colours: Array, offsets: Array) -> Gradient:
	var ramp := Gradient.new()
	ramp.offsets = PackedFloat32Array(offsets)
	ramp.colors = PackedColorArray(colours)
	return ramp

func _make_stars() -> Node3D:
	var ring := Node3D.new()
	ring.name = "StunStars"
	add_child(ring)
	ring.position.y = _head + 0.4
	var count := 5
	var r := clampf(_radius * 0.75, 0.4, 1.2)
	var size := clampf(_radius * 0.75, 0.62, 1.1)
	for i in range(count):
		var star := MeshInstance3D.new()
		var quad := QuadMesh.new()
		quad.size = Vector2(size, size)
		quad.material = _material("star")
		star.mesh = quad
		star.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		var a := TAU * float(i) / float(count)
		star.position = Vector3(cos(a) * r, 0.06 * float(i % 2), sin(a) * r)
		ring.add_child(star)
	return ring

func _make_crystals() -> Node3D:
	var holder := Node3D.new()
	holder.name = "IceCrystals"
	add_child(holder)
	var count := 6
	var r := _radius * 0.95
	for i in range(count):
		var spike := MeshInstance3D.new()
		var prism := PrismMesh.new()
		var h := randf_range(0.55, 1.05) * clampf(_head / 1.9, 0.8, 2.2)
		prism.size = Vector3(0.26, h, 0.22)
		prism.material = _material("crystal")
		spike.mesh = prism
		spike.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		var a := TAU * float(i) / float(count) + randf_range(-0.25, 0.25)
		spike.position = Vector3(cos(a) * r, h * 0.42, sin(a) * r)
		# Leaning out from the body, each its own way.
		spike.rotation = Vector3(sin(a) * 0.35, randf_range(0.0, TAU), -cos(a) * 0.35)
		holder.add_child(spike)
	return holder

func _make_drops() -> CPUParticles3D:
	var drops := _particles(_material("drop"), 14, 0.75, 0.07)
	drops.position.y = _head * 0.62
	drops.emission_shape = CPUParticles3D.EMISSION_SHAPE_SPHERE
	drops.emission_sphere_radius = _radius * 0.65
	drops.direction = Vector3.DOWN
	drops.spread = 25.0
	drops.initial_velocity_min = 0.3
	drops.initial_velocity_max = 1.0
	drops.gravity = Vector3(0, -9.0, 0)
	drops.color = Color(0.5, 0.0, 0.01, 1.0)
	return drops

## Frost motes falling (slow) or bubbles rising (poison) round the body.
func _make_motes(colour: Color, rise: float, amount: int, life: float, size: float) -> CPUParticles3D:
	var motes := _particles(_material("mote"), amount, life, size)
	motes.position.y = _head * (0.25 if rise > 0.0 else 0.9)
	motes.emission_shape = CPUParticles3D.EMISSION_SHAPE_SPHERE
	motes.emission_sphere_radius = _radius * 0.9
	motes.direction = Vector3.UP if rise > 0.0 else Vector3.DOWN
	motes.spread = 15.0
	motes.initial_velocity_min = absf(rise) * 0.5
	motes.initial_velocity_max = absf(rise)
	motes.gravity = Vector3.ZERO
	motes.color = colour
	return motes

func _particles(material: Material, amount: int, life: float, size: float) -> CPUParticles3D:
	var p := CPUParticles3D.new()
	var quad := QuadMesh.new()
	quad.size = Vector2(size, size)
	quad.material = material
	p.mesh = quad
	p.amount = amount
	p.lifetime = life
	p.local_coords = false
	p.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	var fade := Gradient.new()
	fade.set_color(0, Color(1, 1, 1, 1))
	fade.set_color(1, Color(1, 1, 1, 0))
	p.color_ramp = fade
	add_child(p)
	return p

## Dust thrown up at the feet: the throw's take-off and its landing.
func _dust(scale: float) -> void:
	var feet := body.global_position + Vector3.UP * 0.05
	var size := clampf(_radius * 1.7, 1.1, 3.2) * scale
	FlipbookFX.play(body.get_parent(), feet, [
		{"atlas": "smoke_puff_8x8_1k", "size": size, "height": size * 0.3, "fps": 32.0, "tint": Color(0.55, 0.48, 0.38), "opacity": 0.45},
		{"atlas": "smoke_puff_8x8_1k", "size": size * 1.2, "flat": true, "height": 0.06, "fps": 28.0, "tint": Color(0.5, 0.44, 0.36), "opacity": 0.4},
	], {"life": 1.2, "name": "ThrowDust"})

## The ice bursts when the freeze ends.
func _shatter() -> void:
	var burst := _particles(_material("crystal"), 16, 0.6, 0.14)
	remove_child(burst)
	body.get_parent().add_child(burst)
	burst.global_position = body.global_position + Vector3.UP * (_head * 0.5)
	burst.one_shot = true
	burst.explosiveness = 1.0
	burst.emission_shape = CPUParticles3D.EMISSION_SHAPE_SPHERE
	burst.emission_sphere_radius = _radius * 0.7
	burst.direction = Vector3.UP
	burst.spread = 180.0
	burst.initial_velocity_min = 2.5
	burst.initial_velocity_max = 5.0
	burst.gravity = Vector3(0, -14.0, 0)
	burst.color = Color(0.8, 0.95, 1.0, 1.0)
	burst.emitting = true
	burst.finished.connect(burst.queue_free)

# ------------------------------------------------------------------ materials

## The shared materials (one of each per process; ShaderWarmup draws them).
static func _material(kind: String) -> Material:
	if _materials.has(kind):
		return _materials[kind]
	if kind in ["burn", "ice", "cold", "poison", "blood"]:
		# The skin looks (status_skin.gdshader): one shader, a mode each.
		var skin := ShaderMaterial.new()
		skin.shader = SKIN_SHADER
		skin.set_shader_parameter("mode", {"burn": 0, "ice": 1, "cold": 2, "poison": 3, "blood": 4}[kind])
		skin.set_shader_parameter("noise", SpellEffect.asset(NOISE_TEX))
		# the ice shell sits a little proud of the skin; rime reaches the knees
		skin.set_shader_parameter("grow", 0.025 if kind == "ice" else 0.004)
		skin.set_shader_parameter("reach", 0.85)
		_materials[kind] = skin
		return skin
	if kind == "flame":
		var flame := ShaderMaterial.new()
		flame.shader = FLAME_SHADER
		flame.set_shader_parameter("atlas", SpellEffect.asset(FLAME_ATLAS))
		_materials[kind] = flame
		return flame
	var mat := StandardMaterial3D.new()
	mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	mat.cull_mode = BaseMaterial3D.CULL_DISABLED
	match kind:
		"smoke":
			# A rolling puff: the smoke flipbook played over each particle's life.
			mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
			mat.billboard_mode = BaseMaterial3D.BILLBOARD_PARTICLES
			mat.billboard_keep_scale = true
			mat.particles_anim_h_frames = 8
			mat.particles_anim_v_frames = 8
			mat.particles_anim_loop = false
			mat.albedo_texture = SpellEffect.asset(SMOKE_ATLAS)
			mat.vertex_color_use_as_albedo = true
			mat.depth_draw_mode = BaseMaterial3D.DEPTH_DRAW_DISABLED
		"splat":
			# A spot of blood on the ground.
			mat.albedo_texture = SpellEffect.asset(GLOW_TEX)
			mat.albedo_color = Color(0.3, 0.0, 0.01, 0.9)
			mat.roughness = 0.15
			mat.metallic_specular = 0.8
			mat.depth_draw_mode = BaseMaterial3D.DEPTH_DRAW_DISABLED
			mat.cull_mode = BaseMaterial3D.CULL_BACK
		"crystal":
			mat.albedo_color = Color(0.7, 0.92, 1.0, 0.7)
			mat.emission_enabled = true
			mat.emission = Color(0.45, 0.75, 1.0)
			mat.emission_energy_multiplier = 1.1
			mat.roughness = 0.05
			mat.metallic_specular = 1.0
			mat.vertex_color_use_as_albedo = false
		"star", "mote", "drop":
			mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
			mat.blend_mode = BaseMaterial3D.BLEND_MODE_ADD if kind != "drop" else BaseMaterial3D.BLEND_MODE_MIX
			mat.billboard_mode = BaseMaterial3D.BILLBOARD_ENABLED if kind == "star" else BaseMaterial3D.BILLBOARD_PARTICLES
			mat.albedo_texture = SpellEffect.asset(STAR_TEX if kind == "star" else GLOW_TEX)
			mat.albedo_color = Color(1.0, 0.85, 0.3) if kind == "star" else Color(1, 1, 1)
			mat.vertex_color_use_as_albedo = kind != "star"
			# The stun stars are an indicator: drawn over the crowd round the head.
			mat.no_depth_test = kind == "star"
			if kind == "star":
				mat.render_priority = 2
			mat.depth_draw_mode = BaseMaterial3D.DEPTH_DRAW_DISABLED
	_materials[kind] = mat
	return mat

## Every look's material, for ShaderWarmup.
static func warm_materials() -> Array:
	var out: Array = []
	for kind in ["ice", "burn", "cold", "poison", "blood", "crystal", "star", "mote", "drop", "flame", "smoke", "splat"]:
		out.append(_material(kind))
	return out
