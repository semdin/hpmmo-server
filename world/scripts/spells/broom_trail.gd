extends Node3D

## Phase 12 broom trail: a tapered energy ribbon, translucent wisps and sparse
## embers, driven by speed and acceleration from the broom's own TailSocket.
##
## The ribbon's UV layout and taper profile come from the authored mesh
## `assets/vfx/meshes/trail_ribbon.glb` (U along the length 0 -> 1, V across,
## alpha = the authored taper profile; see meshes_metadata.json). The strip is
## rebuilt along a motion history whose samples are the socket's own positions,
## so the trail follows the flight path rather than the broom's current facing.
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


func setup(owner_body: Node3D, model_root: Node = null) -> void:
	owner_node = owner_body
	var scope: Node = model_root if model_root != null else get_parent()
	tail_socket = (scope.find_child("TailSocket", true, false) as Node3D) if scope != null else null
	_quality = QualityPreset.current()
	_load_authored_taper()
	_build()


## The authored taper profile is sampled straight out of the exported mesh's
## vertex colours (phase12_meshes.py writes alpha = max(0.02, (1-t)^1.35)), so
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
	ribbon = MeshInstance3D.new()
	ribbon.name = "TrailRibbon"
	ribbon.mesh = _mesh
	ribbon.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	ribbon.top_level = true
	_material = ShaderMaterial.new()
	_material.shader = load(RIBBON_SHADER)
	_material.set_shader_parameter("streak", load(VFX.asset_path("vfx_energy_streak")))
	_material.set_shader_parameter("tint", colour)
	_material.set_shader_parameter("edge_softness", 0.65)
	ribbon.material_override = _material
	add_child(ribbon)
	ribbon.visible = false

	wisps = _make_particles("TrailWisps", "vfx_flame_static", 26, 0.55, 2.2, 22.0, 0.6, 0.44, colour, true)
	sparks = _make_particles("TrailSparks", "vfx_spark_static", 18, 0.7, 3.0, 30.0, -1.5, 0.09, colour, false)
	light = OmniLight3D.new()
	light.name = "TrailLight"
	light.light_color = colour
	light.light_energy = 1.2
	light.omni_range = 5.0
	light.shadow_enabled = false
	add_child(light)


func _make_particles(node_name: String, tex: String, amount: int, life: float, speed: float,
		spread: float, gravity: float, size: float, colour: Color, alpha_blend: bool) -> GPUParticles3D:
	var particles := GPUParticles3D.new()
	particles.name = node_name
	particles.amount = amount
	particles.lifetime = life
	particles.local_coords = false
	particles.randomness = 0.7
	particles.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	var quad := QuadMesh.new()
	quad.size = Vector2(size, size)
	var material := StandardMaterial3D.new()
	material.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	material.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	material.blend_mode = BaseMaterial3D.BLEND_MODE_MIX if alpha_blend else BaseMaterial3D.BLEND_MODE_ADD
	material.billboard_mode = BaseMaterial3D.BILLBOARD_ENABLED
	material.vertex_color_use_as_albedo = true
	material.albedo_texture = load(VFX.asset_path(tex))
	quad.material = material
	particles.draw_pass_1 = quad
	var process := ParticleProcessMaterial.new()
	process.direction = Vector3(0, 0, 1)
	process.spread = spread
	process.initial_velocity_min = speed * 0.5
	process.initial_velocity_max = speed
	process.gravity = Vector3(0, gravity, 0)
	process.color = colour
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
	if light:
		light.visible = flying and _quality != "low"
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
	_scale_to_speed()
	if tail_socket != null and is_instance_valid(tail_socket):
		_history.push_back(tail_socket.global_position)
		while _history.size() > SAMPLES:
			_history.remove_at(0)
		_rebuild()
	if light != null:
		light.global_position = global_position


func _scale_to_speed() -> void:
	var ratio := clampf(_speed / 15.0, 0.0, 1.4)
	var preset := VFX.BROOM_TRAIL
	for entry in preset["layers"]:
		var layer: Dictionary = entry
		if String(layer.get("kind", "")) != "particles":
			continue
		var node: GPUParticles3D = wisps if String(layer.get("tex", "")) == "vfx_flame_static" else sparks
		if node == null:
			continue
		node.amount = maxi(1, int(float(layer.get("amount", 20)) * lerpf(0.35, 1.0, clampf(ratio, 0.0, 1.0))))
		node.speed_scale = 0.6 + ratio
	if _material != null:
		var heat := clampf(0.35 + ratio * 0.5 + maxf(0.0, _accel) * 0.02, 0.0, 1.0)
		_material.set_shader_parameter("tint", Color(
			lerpf(0.9, 1.0, heat), lerpf(0.5, 0.9, heat), lerpf(0.2, 0.55, heat), 0.55 + 0.4 * clampf(ratio, 0.0, 1.0)))
		_material.set_shader_parameter("scroll", _time * (0.6 + ratio))


func _rebuild() -> void:
	_mesh.clear_surfaces()
	var count := _history.size()
	if count < 3:
		return
	_mesh.surface_begin(Mesh.PRIMITIVE_TRIANGLE_STRIP)
	var travelled := 0.0
	var width := 0.22
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
		side = side.normalized() * width * taper * lerpf(0.4, 1.0, clampf(_speed / 8.0, 0.0, 1.0))
		var fade := (1.0 - age) * (1.0 - clampf(travelled / MAX_LENGTH, 0.0, 1.0))
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
		"layers": 4 if _quality != "low" else 3}
