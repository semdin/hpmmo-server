extends Node3D

## Broom wake: a faint pale air ribbon, curling silvery mist puffs (fal Wan
## flipbook vfx_broom_mist) and a few glittering gold motes (vfx_broom_motes),
## all shed from the broom's own TailSocket and scaled by speed.
##
## The ribbon's UV layout and taper profile come from the authored mesh
## `assets/vfx/meshes/trail_ribbon.glb` (U along the length 0 -> 1, V across,
## alpha = the authored taper profile; see meshes_metadata.json). The strip is
## rebuilt along a motion history whose samples are the socket's own positions,
## so the trail follows the flight path rather than the broom's current facing.
##
## Nothing about it is steady: a slow noise "gust" breathes the mist density and
## the ribbon's width/brightness, banking, climbing and acceleration throw extra
## mist, and the gold motes come in short random flurries over a faint trickle
## instead of a constant stream. Every puff starts on a random flipbook frame,
## plays at its own speed and size, and medium/high presets add turbulence, so
## no two stretches of the wake look alike.
##
## It is presentation only: the ribbon's length and brightness follow speed, and
## nothing here touches movement, damage, mana or mount state. Dismount clears
## the history and hides every layer, so no trail can outlive the flight.

const VFX = preload("res://scripts/spells/vfx_library.gd")
const RIBBON_SHADER := "res://assets/shaders/spell_ribbon.gdshader"
const QualityPreset = preload("res://scripts/world/quality_preset.gd")

const SAMPLES := 26
const MAX_LENGTH := 7.0

var owner_node: Node3D
var tail_socket: Node3D
var ribbon: MeshInstance3D
var wisps: GPUParticles3D
var sparks: GPUParticles3D
var light: OmniLight3D

var _mesh := ImmediateMesh.new()
var _history: PackedVector3Array = []
var _material: ShaderMaterial
var _speed := 0.0
var _prev_speed := 0.0
var _accel := 0.0
var _flying := false
var _time := 0.0
var _taper: PackedFloat32Array = PackedFloat32Array()
var _quality := "high"
var _noise := FastNoiseLite.new()
var _prev_dir := Vector3.ZERO
var _agitation := 0.0        # 0..1: banking / climbing / accelerating right now
var _flurry_left := 0.0      # seconds of the current mote flurry
var _flurry_next := 2.0      # seconds until the next one


func setup(owner_body: Node3D, model_root: Node = null) -> void:
	owner_node = owner_body
	var scope: Node = model_root if model_root != null else get_parent()
	tail_socket = (scope.find_child("TailSocket", true, false) as Node3D) if scope != null else null
	_quality = QualityPreset.current()
	_noise.seed = randi()
	_noise.frequency = 0.35
	_noise.fractal_octaves = 2
	_load_authored_taper()
	_build()


## The authored taper profile is sampled straight out of the exported mesh's
## vertex colours (spell_meshes.py writes alpha = max(0.02, (1-t)^1.35)), so
## the runtime strip uses the authored shape rather than a second hand-written
## curve that could drift from the asset.
func _load_authored_taper() -> void:
	var scene := load(VFX.asset_path("vfx_trail_mesh")) as PackedScene
	if scene == null:
		return
	var instance := scene.instantiate()
	var mesh_instance := _find_mesh(instance)
	if mesh_instance != null:
		var arrays := mesh_instance.mesh.surface_get_arrays(0)
		var colours = arrays[Mesh.ARRAY_COLOR]
		if colours != null and colours.size() > 2:
			var sampled := PackedFloat32Array()
			# vertex colour alpha is stored per vertex, two vertices per step
			for i in range(0, colours.size(), 2):
				sampled.append(float((colours[i] as Color).a))
			_taper = sampled
	instance.free()


func _find_mesh(node: Node) -> MeshInstance3D:
	if node is MeshInstance3D and (node as MeshInstance3D).mesh != null:
		return node as MeshInstance3D
	for child in node.get_children():
		var found := _find_mesh(child)
		if found != null:
			return found
	return null


func _taper_at(t: float) -> float:
	if _taper.is_empty():
		return maxf(0.02, pow(1.0 - t, 1.35))
	var index := int(clampf(t, 0.0, 1.0) * float(_taper.size() - 1))
	return maxf(0.02, _taper[index])


func _build() -> void:
	var preset := VFX.BROOM_TRAIL
	var colour: Color = preset["colour"]
	# A faint air wake: a thin pale ribbon, not a jet of fire.
	ribbon = MeshInstance3D.new()
	ribbon.name = "TrailRibbon"
	ribbon.mesh = _mesh
	ribbon.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	ribbon.top_level = true
	_material = ShaderMaterial.new()
	_material.shader = load(RIBBON_SHADER)
	_material.set_shader_parameter("streak", load(VFX.asset_path("vfx_energy_streak")))
	_material.set_shader_parameter("tint", colour)
	_material.set_shader_parameter("edge_softness", 0.9)
	_material.set_shader_parameter("opacity", 0.35)
	ribbon.material_override = _material
	add_child(ribbon)
	ribbon.visible = false

	# Curling silvery air left hanging in the broom's wake (world space, so the
	# puffs stay where they were shed and the wake reads as a path).
	wisps = _make_flipbook("TrailWisps", "vfx_broom_mist", 14, 1.5, Color(0.86, 0.9, 1.0, 0.22),
		Vector2(0.55, 2.1), 0.5, 0.15, false)
	# A few glittering motes of broom magic drifting down out of the bristles.
	sparks = _make_flipbook("TrailSparks", "vfx_broom_motes", 7, 1.3, Color(1.0, 0.88, 0.62, 0.8),
		Vector2(0.5, 1.2), 0.35, -0.35, true)
	if _quality == "low":
		sparks.amount = 4


## A world-space flipbook stream from the tail socket: every particle plays the
## whole sheet over its life, grows from size.x to size.y and fades in and out.
func _make_flipbook(node_name: String, tex: String, amount: int, life: float, colour: Color,
		size: Vector2, drift: float, gravity: float, additive: bool) -> GPUParticles3D:
	var particles := GPUParticles3D.new()
	particles.name = node_name
	particles.amount = amount
	particles.lifetime = life
	particles.local_coords = false
	particles.randomness = 0.5
	particles.fixed_fps = 0
	particles.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	particles.visibility_aabb = AABB(Vector3(-12, -6, -12), Vector3(24, 12, 24))
	var quad := QuadMesh.new()
	quad.size = Vector2.ONE
	var material := StandardMaterial3D.new()
	material.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	material.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	material.blend_mode = BaseMaterial3D.BLEND_MODE_ADD if additive else BaseMaterial3D.BLEND_MODE_MIX
	material.billboard_mode = BaseMaterial3D.BILLBOARD_PARTICLES
	material.billboard_keep_scale = true
	material.particles_anim_h_frames = 8
	material.particles_anim_v_frames = 8
	material.particles_anim_loop = false
	material.vertex_color_use_as_albedo = true
	material.depth_draw_mode = BaseMaterial3D.DEPTH_DRAW_DISABLED
	material.proximity_fade_enabled = true
	material.proximity_fade_distance = 0.6
	material.albedo_texture = load(VFX.asset_path(tex))
	quad.material = material
	particles.draw_pass_1 = quad
	var process := ParticleProcessMaterial.new()
	process.emission_shape = ParticleProcessMaterial.EMISSION_SHAPE_SPHERE
	process.emission_sphere_radius = 0.12
	process.direction = Vector3(0, 0, 1)
	process.spread = 180.0
	process.initial_velocity_min = drift * 0.3
	process.initial_velocity_max = drift
	process.gravity = Vector3(0, gravity, 0)
	process.damping_min = 0.6
	process.damping_max = 1.2
	process.angle_min = -180.0
	process.angle_max = 180.0
	process.angular_velocity_min = -25.0
	process.angular_velocity_max = 25.0
	# Variety per particle: a random start frame and playback speed, a wide
	# size range and a little hue drift, so the stream never repeats itself.
	process.anim_speed_min = 0.7
	process.anim_speed_max = 1.3
	process.anim_offset_min = 0.0
	process.anim_offset_max = 0.85
	process.scale_min = size.x * 0.65
	process.scale_max = size.x * 1.45
	process.hue_variation_min = -0.03
	process.hue_variation_max = 0.03
	process.emission_sphere_radius = 0.22
	if _quality != "low":
		process.turbulence_enabled = true
		process.turbulence_noise_strength = 0.8
		process.turbulence_noise_scale = 2.2
		process.turbulence_noise_speed = Vector3(0.2, 0.35, 0.2)
		process.turbulence_influence_min = 0.05
		process.turbulence_influence_max = 0.22
	var grow := Curve.new()
	grow.add_point(Vector2(0.0, 1.0))
	grow.add_point(Vector2(1.0, size.y / maxf(0.01, size.x)))
	grow.max_value = maxf(1.0, size.y / maxf(0.01, size.x))
	var grow_tex := CurveTexture.new()
	grow_tex.curve = grow
	process.scale_curve = grow_tex
	var ramp := Gradient.new()
	ramp.set_color(0, Color(colour.r, colour.g, colour.b, 0.0))
	ramp.set_color(1, Color(colour.r, colour.g, colour.b, 0.0))
	ramp.add_point(0.15, colour)
	ramp.add_point(0.55, Color(colour.r, colour.g, colour.b, colour.a * 0.7))
	var ramp_tex := GradientTexture1D.new()
	ramp_tex.gradient = ramp
	process.color_ramp = ramp_tex
	particles.process_material = process
	add_child(particles)
	particles.emitting = false
	return particles


func set_flying(flying: bool) -> void:
	_flying = flying
	visible = flying
	if wisps:
		wisps.emitting = flying
	if sparks:
		sparks.emitting = flying
	if ribbon:
		ribbon.visible = flying
	if not flying:
		# braking and dismount clear the history: no trail outlives the flight
		_history.clear()
		if _mesh:
			_mesh.clear_surfaces()
		_speed = 0.0
		_prev_speed = 0.0
		_accel = 0.0


func flying() -> bool:
	return _flying


func tick(delta: float) -> void:
	if owner_node == null or not is_instance_valid(owner_node):
		return
	var vel := Vector3.ZERO
	if owner_node is CharacterBody3D:
		vel = (owner_node as CharacterBody3D).velocity
	_speed = Vector3(vel.x, 0.0, vel.z).length()
	_accel = (_speed - _prev_speed) / maxf(delta, 0.0001)
	_prev_speed = _speed
	_time += delta
	if not _flying:
		return
	_measure_agitation(vel, delta)
	_scale_to_speed(delta)
	if tail_socket != null and is_instance_valid(tail_socket):
		_history.push_back(tail_socket.global_position)
		while _history.size() > SAMPLES:
			_history.remove_at(0)
		_rebuild()


## How hard the rider is manoeuvring: turn rate, climb/dive and acceleration,
## decaying smoothly so a bank leaves a swirl behind it.
func _measure_agitation(vel: Vector3, delta: float) -> void:
	var flat := Vector3(vel.x, 0.0, vel.z)
	var dir := flat.normalized() if flat.length() > 0.5 else Vector3.ZERO
	var turn := 0.0
	if dir != Vector3.ZERO and _prev_dir != Vector3.ZERO:
		turn = _prev_dir.angle_to(dir) / maxf(delta, 0.0001)
	_prev_dir = dir
	var push := clampf(turn / 2.5, 0.0, 1.0) * 0.6 + clampf(absf(vel.y) / 8.0, 0.0, 1.0) * 0.4 \
			+ clampf(absf(_accel) / 20.0, 0.0, 1.0) * 0.4
	_agitation = maxf(clampf(push, 0.0, 1.0), _agitation - delta * 0.9)


## 0..1 slow breathing value; `offset` decorrelates the layers.
func _gust(offset: float) -> float:
	return clampf(_noise.get_noise_1d(_time * 10.0 + offset) * 0.5 + 0.5, 0.0, 1.0)


func _scale_to_speed(delta: float) -> void:
	var ratio := clampf(_speed / 15.0, 0.0, 1.4)
	var moving := clampf(ratio, 0.0, 1.0)
	var gust := _gust(0.0)
	# amount_ratio, not amount: reassigning `amount` restarts the system and
	# the wake flickered every frame.
	if wisps:
		# Hovering sheds almost nothing; cruising breathes with the gust; a bank
		# or a dive throws a thicker swirl.
		var base := lerpf(0.08, 0.75, moving) * lerpf(0.45, 1.0, gust)
		wisps.amount_ratio = clampf(base + _agitation * 0.55 * maxf(0.3, moving), 0.03, 1.0)
		wisps.speed_scale = lerpf(0.85, 1.15, _gust(37.0))
		if tail_socket != null and is_instance_valid(tail_socket):
			wisps.global_position = tail_socket.global_position
	if sparks:
		# Motes: a faint trickle, with a short flurry every few seconds (and one
		# whenever the rider really pushes).
		_flurry_next -= delta
		var pushed := _agitation > 0.75 and _flurry_left <= 0.0 and _flurry_next < 1.5
		if (_flurry_next <= 0.0 or pushed) and moving > 0.15:
			_flurry_left = randf_range(0.35, 0.9)
			_flurry_next = randf_range(2.5, 7.5)
		_flurry_left = maxf(0.0, _flurry_left - delta)
		var trickle := lerpf(0.04, 0.22, moving) * _gust(71.0)
		sparks.amount_ratio = clampf(trickle + (0.85 if _flurry_left > 0.0 else 0.0) * moving, 0.0, 1.0)
		if tail_socket != null and is_instance_valid(tail_socket):
			sparks.global_position = tail_socket.global_position
	if _material != null:
		var preset := VFX.BROOM_TRAIL
		var colour: Color = preset["colour"]
		_material.set_shader_parameter("tint", Color(colour.r, colour.g, colour.b, 1.0))
		var shimmer := lerpf(0.7, 1.15, _gust(113.0))
		# Cruising leaves only a faint wisp; banking / climbing brightens it.
		_material.set_shader_parameter("opacity", (0.05 + 0.16 * moving + 0.2 * _agitation) * shimmer)
		_material.set_shader_parameter("scroll", _time * (0.4 + ratio) + _gust(151.0) * 0.6)


func _rebuild() -> void:
	_mesh.clear_surfaces()
	var count := _history.size()
	if count < 3:
		return
	_mesh.surface_begin(Mesh.PRIMITIVE_TRIANGLE_STRIP)
	var travelled := 0.0
	var width := 0.16 * lerpf(0.75, 1.25, _gust(191.0)) * (1.0 + _agitation * 0.35)
	for i in range(count):
		var idx := count - 1 - i
		var point := _history[idx]
		if i > 0:
			travelled += point.distance_to(_history[idx + 1])
		var age := float(i) / float(count)
		var taper := _taper_at(age)
		var dir := Vector3.FORWARD
		if idx > 0:
			dir = (point - _history[idx - 1]).normalized()
		elif count > 1:
			dir = (point - _history[idx + 1]).normalized()
		var side := dir.cross(Vector3.UP)
		if side.length_squared() < 0.0001:
			side = Vector3.RIGHT
		# a slow ripple along the length so the ribbon edge is never a clean taper
		var ripple := 1.0 + 0.18 * sin(age * 9.0 - _time * 3.1) * _gust(233.0)
		side = side.normalized()
		# The wake drifts as it ages: older samples curl sideways and lift a
		# little on a slow wave, so a straight flight leaves a wavering wisp of
		# air rather than a ruler-straight line.
		var drift := age * age * (0.35 + 0.4 * _gust(271.0))
		point += side * sin(age * 7.0 - _time * 2.3 + _gust(311.0) * 3.0) * drift 				+ Vector3.UP * sin(age * 5.0 - _time * 1.7) * drift * 0.5
		side *= width * taper * ripple * lerpf(0.4, 1.0, clampf(_speed / 8.0, 0.0, 1.0)) * (1.0 + age * 1.6)
		# Brightness breaks up along the length (patchy air, not a solid beam).
		var patch := lerpf(0.45, 1.0, clampf(0.5 + 0.5 * sin(age * 13.0 - _time * 4.0 + _gust(353.0) * 6.0), 0.0, 1.0))
		var fade := (1.0 - age) * (1.0 - clampf(travelled / MAX_LENGTH, 0.0, 1.0)) * patch
		_mesh.surface_set_color(Color(1, 1, 1, fade))
		_mesh.surface_set_uv(Vector2(age, 0.0))
		_mesh.surface_add_vertex(point - side)
		_mesh.surface_set_color(Color(1, 1, 1, fade))
		_mesh.surface_set_uv(Vector2(age, 1.0))
		_mesh.surface_add_vertex(point + side)
	_mesh.surface_end()


## Measurement hook for the checks: what the trail actually consumed.
func describe() -> Dictionary:
	return {"flying": _flying, "samples": _history.size(), "speed": _speed,
		"taper_from_asset": not _taper.is_empty(), "quality": _quality,
		"layers": 3}
