extends "res://scripts/spells/stupefy_vfx.gd"

## Spell-specific choreography over the shared world-space strip renderer.
## Colours, silhouettes and motion differ; no gameplay is resolved here.
const SURFACE = preload("res://assets/shaders/spell_signature.gdshader")
var spell := "bombarda"
var colour := Color(1, 0.5, 0.03)
var duration := 0.8
var radius := 0.0
var _ground := Vector3.ZERO
var _flames: Array[MeshInstance3D] = []
var _cone_directions: Array[Vector3] = []
var _cone_reaches: Array[float] = []

func configure(id: String, lifetime: float, area: float) -> void:
	spell = id
	duration = maxf(lifetime, 0.1)
	radius = area
	colour = preload("res://scripts/spells/vfx_library.gd").spell_colour(spell)

func setup(p_stage: String, p_quality: String, aim: Vector3) -> void:
	super.setup(p_stage, p_quality, aim)
	_head.name = "SignatureCore"
	_strands.name = "SignatureGeometry"
	_head_material.shader = SURFACE
	_head_material.set_shader_parameter("flow_noise", NOISE)
	_head_material.set_shader_parameter("tint", colour)
	var form := {"incendio": 0, "bombarda": 1, "expelliarmus": 2, "ultimate": 3, "protego": 2}
	_head_material.set_shader_parameter("form", int(form.get(spell, 1)))
	_head_material.set_shader_parameter("burst", stage == "impact")
	var size := 1.1 if stage == "travel" else (3.8 if stage == "impact" else 1.25)
	if spell == "expelliarmus":
		size = 1.4 if stage == "travel" else 2.2
	elif spell == "ultimate":
		size = 1.6 if stage == "travel" else (5.0 if stage == "impact" else 1.9)
	(_head.mesh as QuadMesh).size = Vector2.ONE * size
	_ground = global_position
	var query := PhysicsRayQueryParameters3D.create(global_position + Vector3.UP * 0.2, global_position + Vector3.DOWN * 10, 1)
	var hit := get_world_3d().direct_space_state.intersect_ray(query)
	if not hit.is_empty():
		_ground = hit.position + Vector3.UP * 0.045
	if spell == "incendio" and stage == "cast":
		_build_cone()
	if stage == "end":
		_head_material.set_shader_parameter("form", 4)
		_head_material.set_shader_parameter("tint", Color(0.25, 0.22, 0.2) if spell == "bombarda" else colour * 0.3)
	if spell == "protego":
		_head.hide()

func _build_cone() -> void:
	var data: Dictionary = GameData.SPELLS["incendio"]
	var reach := float(data["range"])
	var half_angle := deg_to_rad(float(data["cone_angle"]) * 0.5)
	var frame := _axes()
	var count := 3 if quality == "low" else 5
	for i in range(count):
		var angle := lerpf(-half_angle, half_angle, float(i) / (count - 1))
		var ray := (direction * cos(angle) + frame.x * sin(angle)).normalized()
		var query := PhysicsRayQueryParameters3D.create(global_position, global_position + ray * reach, 1)
		var hit := get_world_3d().direct_space_state.intersect_ray(query)
		_cone_directions.append(ray)
		_cone_reaches.append(global_position.distance_to(hit.position) if not hit.is_empty() else reach)
		for part in range(2):
			var flare := MeshInstance3D.new()
			var quad := QuadMesh.new()
			quad.size = Vector2(2.0 + part * 0.7, 5.0 + part * 1.2)
			quad.material = _head_material.duplicate()
			(quad.material as ShaderMaterial).set_shader_parameter("aim", ray)
			flare.mesh = quad
			flare.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
			add_child(flare)
			_flames.append(flare)
	_head.hide()

func advance(age: float, aim: Vector3) -> void:
	_clock = age
	direction = aim.normalized()
	var k := clampf(age / duration, 0, 1)
	var fade := 1.0 if stage == "travel" else 1.0 - smoothstep(0.35, 1.0, k)
	if stage == "sustain":
		fade = smoothstep(0, 0.08, k) * (1.0 - smoothstep(0.86, 1, k))
	if _retired:
		fade = 1.0 - smoothstep(0, 0.24, age - _retired_at)
	_head_material.set_shader_parameter("clock", age)
	_head_material.set_shader_parameter("phase", k)
	_head_material.set_shader_parameter("opacity", fade)
	_head_material.set_shader_parameter("turn", age * (5.0 if spell == "expelliarmus" else 0.2))
	_strand_material.set_shader_parameter("clock", age)
	_strand_material.set_shader_parameter("opacity", fade)
	_strand_mesh.clear_surfaces()
	_strand_mesh.surface_begin(Mesh.PRIMITIVE_TRIANGLES)
	match spell:
		"incendio": _fire_fan(age, k, fade)
		"bombarda": _concussion(age, k)
		"expelliarmus": _disarm(age, k)
		"ultimate": _arcana(age, k)
		"protego": _ward(age, k)
	# A transparent degenerate triangle lets fully faded stages keep a valid surface.
	for i in range(3):
		_vertex(global_position, Vector2.ZERO, Color(0, 0, 0, 0))
	_strand_mesh.surface_end()

func _fire_fan(age: float, k: float, fade: float) -> void:
	if stage == "cast":
		for i in range(_cone_directions.size()):
			var ray := _cone_directions[i]
			var length := minf(_cone_reaches[i], age * 100.0)
			var points: Array[Vector3] = []
			for j in range(22):
				var t := float(j) / 21.0
				points.append(global_position + ray * length * t + Vector3.UP * (sin(t * PI) * 0.28 + sin(t * 21 - age * 20 + i) * t * 0.13))
			_strip(points, 0.06, Color(0.7, 0.15, 0.01, 0.45), true)
			for part in range(2):
				var flare := _flames[i * 2 + part]
				flare.global_position = global_position + ray * length * (0.24 + part * 0.28) + Vector3.UP * 0.1
				flare.scale = Vector3.ONE * (0.4 + sin(k * PI) * 0.65)
				var mat := flare.mesh.surface_get_material(0) as ShaderMaterial
				mat.set_shader_parameter("clock", age + i * 0.13 + part * 0.31)
				mat.set_shader_parameter("opacity", fade * 0.85)
	else:
		_head.position.y = 0.65 if stage == "sustain" else 0.15
		_head.scale = Vector3(0.55, 0.85, 1) if stage == "sustain" else Vector3.ONE
		for i in range(3 if quality == "low" else 5):
			var points: Array[Vector3] = []
			for j in range(14):
				var t := float(j) / 13
				var theta := i * TAU / 5 + t * 3 + age * 2
				points.append(global_position + Vector3(cos(theta) * 0.28 * (1-t), t * 1.7, sin(theta) * 0.28 * (1-t)))
			_strip(points, 0.06, colour, true)

func _concussion(age: float, k: float) -> void:
	if stage == "travel":
		_record_path()
		for belt in range(2):
			var frame := _axes()
			_arc(global_position, frame.x, frame.y if belt == 0 else direction, 0.35, age * (7 if belt == 0 else -5), TAU * 0.84, 0.045, colour)
		var points: Array[Vector3] = []
		for i in range(22):
			points.append(_sample_tail(float(i) / 21 * 2.6))
		_strip(points, 0.18, Color(1, 0.19, 0.02), true)
	elif stage == "impact":
		_head.scale = Vector3.ONE * (0.35 + pow(k, 0.4) * 1.0)
		var front := maxf(0.15, radius * minf(1, age / 0.48))
		_arc(_ground, Vector3.RIGHT, Vector3.BACK, front, 0, TAU, 0.13 * (1-k) + 0.025, colour)
		_arc(_ground + Vector3.UP * 0.12, Vector3.RIGHT, Vector3.BACK, front * 0.88, 0, TAU, 0.04, Color(1, 0.22, 0.02))
		_splinter_burst(age, Color(1, 0.63, 0.1), 1.0)
	elif stage == "cast":
		var frame := _axes()
		_arc(global_position, frame.x, frame.y, 0.42 * (1-k) + 0.06, age * 6, TAU * 0.9, 0.07, colour)
	else:
		_head.scale = Vector3.ONE * (0.8 + k * 1.7)
		_head.position.y = k * 0.6

func _disarm(age: float, k: float) -> void:
	var frame := _axes()
	var size := 0.48 if stage == "travel" else (0.25 + k * 1.2)
	for arc in range(2):
		var side := (frame.x + frame.y * (0.65 if arc == 0 else -0.65)).normalized()
		_arc(global_position, side, direction, size, age * 5 + arc * PI, PI * 1.25, 0.075, Color(1, 0.12, 0.38))
	if stage == "travel":
		_record_path()
		var points: Array[Vector3] = []
		for i in range(26):
			var t := float(i) / 25
			points.append(_sample_tail(t * 4.2) + frame.y * sin(t * PI) * sin(age * 8 + t * 4) * 0.16)
		_strip(points, 0.065, Color(1, 0.38, 0.57), true)
	elif stage == "impact":
		for i in range(2):
			var slash := (frame.x + frame.y * (1 if i == 0 else -1)).normalized()
			_strip([global_position - slash * (0.2 + k * 1.8), global_position, global_position + slash * (0.2 + k * 1.8)], 0.085 * (1-k), Color(1, 0.65, 0.8), false)

func _arcana(age: float, k: float) -> void:
	var frame := _axes()
	if stage == "travel":
		_record_path()
		var count := 2 if quality == "low" else 4
		for branch in range(count):
			var points: Array[Vector3] = []
			for i in range(24):
				var t := float(i) / 23
				var jitter := sin(i * 8.1 + age * 19 + branch * 3) * t * 0.3
				points.append(_sample_tail(t * 5.5) + frame.x * jitter + frame.y * sin(i * 7.3 + age * 13 + branch) * t * 0.3)
			_strip(points, 0.055 if branch > 0 else 0.09, Color(0.1, 1, 0.48) if branch > 0 else Color(0.58, 1, 0.75), true)
	elif stage == "impact":
		var reach := maxf(0.1, radius * minf(1, age / 0.35))
		for branch in range(7 if quality == "low" else 12):
			var theta := branch * TAU / (7 if quality == "low" else 12)
			var axis := Vector3(cos(theta), 0, sin(theta))
			var side := axis.cross(Vector3.UP)
			var points: Array[Vector3] = []
			for i in range(12):
				var t := float(i) / 11
				var jag := sin(i * 7.13 + branch * 3.7) * sin(i * 3.7) * sin(t * PI)
				points.append(_ground + axis * reach * t + side * jag * 0.9 + Vector3.UP * sin(t * PI) * 0.4)
			_strip(points, 0.075, colour, true)
			if quality != "low" or branch % 2 == 0:
				var fork := points[5]
				_lightning(fork, fork + (axis + side * (0.8 if branch % 2 == 0 else -0.8)).normalized() * reach * 0.27, float(branch), 0.035)
		_lightning(global_position, global_position + Vector3.UP * (2.5 + k * 3), age, 0.07)
		_head.scale = Vector3.ONE * (0.4 + k * 0.6)
	else:
		for i in range(3):
			var theta := i * TAU / 3 + age
			var end := global_position + frame.x * cos(theta) * 0.85 + frame.y * sin(theta) * 0.85
			_lightning(global_position, end, age + i, 0.045)

func _ward(age: float, k: float) -> void:
	var size := 1.65 * (smoothstep(0, 0.2, k) if stage == "cast" else 1.0)
	if stage == "end":
		size *= 1 + k * 0.25
	for i in range(2 if quality == "low" else 3):
		var normal := Vector3(sin(i * 2.0) * 0.3, 1, cos(i * 2.0) * 0.3).normalized()
		var x := normal.cross(Vector3.FORWARD).normalized()
		var y := normal.cross(x).normalized()
		_arc(global_position, x, y, maxf(0.03, size), age * (0.5 if i % 2 == 0 else -0.4) + i * 2.1, TAU * 0.67, 0.026, Color(0.3, 0.7, 1))

func _record_path() -> void:
	if not _retired and _history[-1].distance_squared_to(global_position) > 0.0025:
		_history.append(global_position)
	while _history.size() > 48:
		_history.pop_front()

func _arc(center: Vector3, x: Vector3, y: Vector3, size: float, start: float, span: float, width: float, tint: Color) -> void:
	var points: Array[Vector3] = []
	var segments := 28 if quality == "low" else 46
	for i in range(segments + 1):
		var theta := start + span * float(i) / segments
		points.append(center + (x * cos(theta) + y * sin(theta)) * size)
	_strip(points, width, tint, false)

func _lightning(start: Vector3, end: Vector3, age: float, width: float) -> void:
	var points: Array[Vector3] = []
	var axis := (end-start).normalized()
	var side := axis.cross(Vector3.UP).normalized()
	if side.length_squared() < 0.01:
		side = Vector3.RIGHT
	for i in range(12):
		var t := float(i) / 11
		points.append(start.lerp(end, t) + side * sin(i * 7.7 + age * 9) * sin(t * PI) * 0.3)
	_strip(points, width, colour, false)

func _splinter_burst(age: float, tint: Color, weight: float) -> void:
	for shard in _splinters:
		var axis: Vector3 = shard["axis"]
		var speed: float = shard["speed"]
		var end := age * speed
		var gravity := Vector3.DOWN * age * age * 2.8 * weight
		_strip([global_position + axis * maxf(0, end - 0.28) + gravity, global_position + axis * end + gravity], 0.036, tint, false)
