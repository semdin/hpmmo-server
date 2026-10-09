extends Node3D

## Stupefy's authored geometry layer. All geometry is presentation-only.
## Three helical streamers trail actual sampled positions, while impact arcs
## and ballistic splinters break the silhouette in three dimensions.
const PLASMA = preload("res://assets/shaders/stupefy_plasma.gdshader")
const FILAMENT = preload("res://assets/shaders/stupefy_filament.gdshader")
const NOISE = preload("res://assets/vfx/tex/noise_flow_512.png")
const CRIMSON := Color(1.0, 0.018, 0.055)
const SCARLET := Color(1.0, 0.065, 0.11)
const HOT := Color(1.0, 0.52, 0.38)

var stage := "travel"
var quality := "high"
var direction := Vector3.FORWARD
var _clock := 0.0
var _history: Array[Vector3] = []
var _head: MeshInstance3D
var _head_material: ShaderMaterial
var _strands: MeshInstance3D
var _strand_mesh: ImmediateMesh
var _strand_material: ShaderMaterial
var _retired := false
var _retired_at := 0.0
var _tail_age := 0.0
var _splinters: Array[Dictionary] = []

func setup(p_stage: String, p_quality: String, aim: Vector3) -> void:
	stage = p_stage
	quality = p_quality
	direction = aim.normalized()
	_head = MeshInstance3D.new()
	_head.name = "TurbulentHeart"
	var quad := QuadMesh.new()
	var size := 0.92 if stage == "travel" else (3.4 if stage == "impact" else 1.2)
	quad.size = Vector2.ONE * size
	_head_material = ShaderMaterial.new()
	_head_material.shader = PLASMA
	_head_material.set_shader_parameter("flow_noise", NOISE)
	_head_material.set_shader_parameter("tint", CRIMSON)
	_head_material.set_shader_parameter("form", 1 if stage == "impact" else (2 if stage == "cast" else 0))
	quad.material = _head_material
	_head.mesh = quad
	_head.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	add_child(_head)
	_strand_mesh = ImmediateMesh.new()
	_strand_material = ShaderMaterial.new()
	_strand_material.shader = FILAMENT
	_strands = MeshInstance3D.new()
	_strands.name = "HelicalFilaments" if stage == "travel" else "FractureArcs"
	_strands.mesh = _strand_mesh
	_strands.material_override = _strand_material
	_strands.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	_strands.top_level = true
	add_child(_strands)
	_strands.global_transform = Transform3D.IDENTITY
	_history.append(global_position)
	if stage == "impact":
		for ray in range(12 if quality == "low" else 26):
			var rng := RandomNumberGenerator.new()
			rng.seed = 739 + ray * 977
			_splinters.append({"axis": Vector3(rng.randf_range(-1, 1), rng.randf_range(-0.6, 1), rng.randf_range(-1, 1)).normalized(),
				"speed": rng.randf_range(2.3, 6.8)})
	set_process(false) # The containing SpellEffect owns the clock and lifecycle.

func retire() -> void:
	_retired = true
	_retired_at = _clock
	_head.hide()

func advance(age: float, aim: Vector3) -> void:
	_clock = age
	direction = aim.normalized()
	_tail_age = maxf(0.0, age - _retired_at) if _retired else 0.0
	_head_material.set_shader_parameter("clock", age)
	_head_material.set_shader_parameter("phase", clampf(age / 0.65, 0.0, 1.0))
	_strand_material.set_shader_parameter("clock", age)
	_strand_material.set_shader_parameter("opacity", 1.0 - smoothstep(0.0, 0.24, _tail_age))
	_strand_mesh.clear_surfaces()
	_strand_mesh.surface_begin(Mesh.PRIMITIVE_TRIANGLES)
	match stage:
		"travel":
			_flight(age)
		"cast":
			_discharge(age)
		"impact":
			_impact(age)
	_strand_mesh.surface_end()

func _axes() -> Basis:
	var up := Vector3.UP if absf(direction.dot(Vector3.UP)) < 0.95 else Vector3.RIGHT
	var side := direction.cross(up).normalized()
	return Basis(side, direction.cross(side).normalized(), direction)

func _flight(age: float) -> void:
	var origin := global_position
	if not _retired and _history[-1].distance_squared_to(origin) > 0.0025:
		_history.append(origin)
	while _history.size() > 48:
		_history.pop_front()
	var frame := _axes()
	var strands := 2 if quality == "low" else 4
	var length := minf(4.8, maxf(0.15, age * 48.0))
	for strand in range(strands):
		var points: Array[Vector3] = []
		var segments := 18 if quality == "low" else 34
		for i in range(segments + 1):
			var t := float(i) / segments
			var distance := t * length
			var center := _sample_tail(distance)
			var theta := t * TAU * (0.85 + strand * 0.29) - age * (12.0 + strand) + strand * 2.2
			theta += sin(t * 15.0 + age * 7.0 + strand) * 0.4
			var radius := sin(t * PI * 0.85) * (0.11 + t * (0.12 + strand * 0.025))
			var wobble := sin(t * 32.0 + age * 23.0 + strand) * 0.035 * t
			points.append(center + (frame.x * cos(theta) + frame.y * sin(theta)) * (radius + wobble))
		_strip(points, 0.075 if strand == 0 else 0.045, HOT if strand == 0 else SCARLET, true)
	# A small bright spine joins the textured heart and corkscrew filaments.
	_strip([origin + direction * 0.12, origin - direction * 0.32, origin - direction * 0.95], 0.045, HOT, true)
	_head.scale = Vector3.ONE * (1.0 + 0.07 * sin(age * 41.0))
	_head_material.set_shader_parameter("opacity", 0.9)

func _sample_tail(distance: float) -> Vector3:
	var remaining := distance
	for i in range(_history.size() - 1, 0, -1):
		var length := _history[i].distance_to(_history[i - 1])
		if remaining <= length:
			return _history[i].lerp(_history[i - 1], remaining / maxf(length, 0.001))
		remaining -= length
	# Do not invent a tail through scenery behind the launch point.
	return _history[0]

func _discharge(age: float) -> void:
	var k := clampf(age / 0.3, 0.0, 1.0)
	var frame := _axes()
	var fade := 1.0 - smoothstep(0.28, 1.0, k)
	_head_material.set_shader_parameter("opacity", fade)
	_head.scale = Vector3.ONE * lerpf(0.45, 1.15, pow(k, 0.35))
	for arm in range(3):
		var points: Array[Vector3] = []
		for i in range(22):
			var t := float(i) / 21.0
			var angle := arm * TAU / 3.0 + t * 3.7 - k * 5.0
			var radius := (0.08 + t * 0.45) * (1.0 - k * 0.65)
			points.append(global_position + (frame.x * cos(angle) + frame.y * sin(angle)) * radius - direction * t * 0.3)
		_strip(points, 0.045, Color(SCARLET, fade), true)

func _impact(age: float) -> void:
	var k := clampf(age / 0.7, 0.0, 1.0)
	var fade := 1.0 - smoothstep(0.18, 1.0, k)
	_head_material.set_shader_parameter("opacity", fade)
	var frame := _axes()
	# Broken, tilted arcs instead of a complete, perfectly circular shock ring.
	for ring in range(2 if quality == "low" else 3):
		var points: Array[Vector3] = []
		var radius := (0.18 + pow(k, 0.44) * (1.25 + ring * 0.3))
		for i in range(28):
			var t := float(i) / 27.0
			var angle := t * TAU * 0.71 + ring * 2.5 + k * 0.7
			var wave := 1.0 + 0.05 * sin(angle * 11.0 + ring)
			points.append(global_position + (frame.x * cos(angle) + frame.y * sin(angle)) * radius * wave + direction * sin(angle * 2.0 + ring) * radius * 0.25)
		_strip(points, 0.07 * (1.0 - k) + 0.008, Color(SCARLET, fade), false)
	# Deterministic ballistic light splinters; they decelerate and bend down.
	for ray in range(_splinters.size()):
		var axis: Vector3 = _splinters[ray]["axis"]
		var speed: float = _splinters[ray]["speed"]
		var start := age * speed / (1.0 + age * 2.3)
		var end := maxf(0, start - (0.12 + age * 0.55))
		var gravity := Vector3.DOWN * age * age * 0.8
		_strip([global_position + axis * end + gravity, global_position + axis * start + gravity], 0.025, Color(HOT if ray % 4 == 0 else SCARLET, fade), false)

func _strip(points: Array[Vector3], width: float, colour: Color, taper: bool) -> void:
	if points.size() < 2:
		return
	var camera := get_viewport().get_camera_3d()
	var previous_side := Vector3.ZERO
	for i in range(points.size() - 1):
		var t := float(i) / (points.size() - 1)
		var next_t := float(i + 1) / (points.size() - 1)
		var tangent := points[i + 1] - points[i]
		if tangent.length_squared() < 0.000001:
			continue
		var view := camera.global_position - points[i] if camera != null else Vector3.UP
		var side := tangent.normalized().cross(view.normalized()).normalized()
		if side.length_squared() < 0.01:
			side = Vector3.RIGHT
		if previous_side.length_squared() > 0.0 and side.dot(previous_side) < 0.0:
			side = -side
		previous_side = side
		var w0 := width * (lerpf(1.0, 0.08, t) if taper else sin(t * PI) * 0.7 + 0.3)
		var w1 := width * (lerpf(1.0, 0.08, next_t) if taper else sin(next_t * PI) * 0.7 + 0.3)
		var c0 := Color(colour, colour.a * (1.0 - t if taper else 1.0))
		var c1 := Color(colour, colour.a * (1.0 - next_t if taper else 1.0))
		_vertex(points[i] - side * w0, Vector2(t, 0), c0)
		_vertex(points[i] + side * w0, Vector2(t, 1), c0)
		_vertex(points[i + 1] - side * w1, Vector2(next_t, 0), c1)
		_vertex(points[i + 1] - side * w1, Vector2(next_t, 0), c1)
		_vertex(points[i] + side * w0, Vector2(t, 1), c0)
		_vertex(points[i + 1] + side * w1, Vector2(next_t, 1), c1)

func _vertex(point: Vector3, uv: Vector2, colour: Color) -> void:
	_strand_mesh.surface_set_color(colour)
	_strand_mesh.surface_set_uv(uv)
	_strand_mesh.surface_add_vertex(point)
