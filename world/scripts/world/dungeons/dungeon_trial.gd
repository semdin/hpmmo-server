extends Node3D

## Trial Hall - the M2 test dungeon (an instanced map, maps.json "dng_trial").
##
## A greybox built in code: entry hall with the exit portal, a corridor closed
## by an iron gate, and an arena where the run's boss rises. Every copy of the
## dungeon is this scene placed at its instance origin (HPMaps.instance_origin);
## the world server builds it collision-only (server/world/server/map_host.gd),
## a client builds it with surfaces and torches.
##
## The run (dungeons.json "trial", scripts/world/dungeon_director.gd) owns the
## gates: `apply_state` opens/closes them from the replicated run state.

const GROUP := "dungeon_instance"
const FLOOR_Y := 1000.0
const WALL_H := 8.0

## Set by the loader before the node enters the tree.
var map_id := ""
var collision_only := false

var _gates: Dictionary = {}   # gate id -> StaticBody3D
var _stone: StandardMaterial3D
var _iron: StandardMaterial3D

func setup(p_map_id: String, p_collision_only: bool = false) -> void:
	map_id = p_map_id
	collision_only = p_collision_only
	position = HPMaps.instance_origin(map_id)
	set_meta("map_id", map_id)

func _ready() -> void:
	add_to_group(GROUP)
	if not collision_only:
		_stone = StandardMaterial3D.new()
		_stone.albedo_color = Color(0.33, 0.32, 0.34)
		_stone.roughness = 0.95
		_iron = StandardMaterial3D.new()
		_iron.albedo_color = Color(0.16, 0.15, 0.15)
		_iron.metallic = 0.6
		_iron.roughness = 0.5
	# Entry hall (z 12 .. -12), corridor (z -12 .. -36), arena (z -36 .. -84).
	_box(Vector3(0, FLOOR_Y - 0.5, 0), Vector3(24, 1, 24))
	_box(Vector3(0, FLOOR_Y - 0.5, -24), Vector3(8, 1, 24))
	_box(Vector3(0, FLOOR_Y - 0.5, -60), Vector3(40, 1, 48))
	_walls_around(Vector3(0, 0, 0), Vector2(24, 24), [Vector3(0, 0, -12)], 8.0)
	_box(Vector3(-4.5, FLOOR_Y + WALL_H * 0.5, -24), Vector3(1, WALL_H, 24))
	_box(Vector3(4.5, FLOOR_Y + WALL_H * 0.5, -24), Vector3(1, WALL_H, 24))
	_walls_around(Vector3(0, 0, -60), Vector2(40, 48), [Vector3(0, 0, -36)], 8.0)
	_gate("gate_a", Vector3(0, FLOOR_Y + 3.0, -36), Vector3(8, 6, 0.8))
	if not collision_only:
		_portal_ring(Vector3(0, FLOOR_Y + 0.05, 11))
		for z in [8.0, -8.0, -24.0, -48.0, -72.0]:
			for x in ([-10.0, 10.0] if z > -12.0 else ([-3.5, 3.5] if z > -36.0 else [-18.0, 18.0])):
				_torch(Vector3(x, FLOOR_Y + 3.5, z))

## The run's replicated state: open gates are passable and invisible.
func apply_state(state: Dictionary) -> void:
	var open: Array = state.get("open", [])
	for id in _gates.keys():
		var gate: StaticBody3D = _gates[id]
		var is_open := open.has(id)
		gate.visible = not is_open
		for shape in gate.get_children():
			if shape is CollisionShape3D:
				(shape as CollisionShape3D).set_deferred("disabled", is_open)

func gate_open(id: String) -> bool:
	return _gates.has(id) and not (_gates[id] as StaticBody3D).visible

# --------------------------------------------------------------- building

func _box(center: Vector3, size: Vector3, material: Material = null, parent: Node3D = self) -> StaticBody3D:
	var body := StaticBody3D.new()
	body.position = center
	var shape := CollisionShape3D.new()
	var box := BoxShape3D.new()
	box.size = size
	shape.shape = box
	body.add_child(shape)
	if not collision_only:
		var mesh := MeshInstance3D.new()
		var bm := BoxMesh.new()
		bm.size = size
		mesh.mesh = bm
		mesh.material_override = material if material != null else _stone
		body.add_child(mesh)
	parent.add_child(body)
	return body

## Four walls round a room of `size` (x, z) centred on `center`, leaving a
## doorway (8 m) wherever an opening point lies on a wall.
func _walls_around(center: Vector3, size: Vector2, openings: Array, door: float) -> void:
	var hx := size.x * 0.5
	var hz := size.y * 0.5
	var y := FLOOR_Y + WALL_H * 0.5
	for side in [-1.0, 1.0]:
		_box(Vector3(center.x + side * (hx + 0.5), y, center.z), Vector3(1, WALL_H, size.y + 2.0))
		var wz: float = center.z + side * (hz + 0.5)
		var gap := false
		for o in openings:
			if absf((o as Vector3).z - (center.z + side * hz)) < 0.6:
				gap = true
		if not gap:
			_box(Vector3(center.x, y, wz), Vector3(size.x, WALL_H, 1))
		else:
			var seg := (size.x - door) * 0.5
			_box(Vector3(center.x - (door * 0.5 + seg * 0.5), y, wz), Vector3(seg, WALL_H, 1))
			_box(Vector3(center.x + (door * 0.5 + seg * 0.5), y, wz), Vector3(seg, WALL_H, 1))

func _gate(id: String, center: Vector3, size: Vector3) -> void:
	_gates[id] = _box(center, size, _iron)
	(_gates[id] as StaticBody3D).name = "Gate_" + id

func _portal_ring(at: Vector3) -> void:
	var ring := MeshInstance3D.new()
	var torus := TorusMesh.new()
	torus.inner_radius = 1.8
	torus.outer_radius = 2.2
	ring.mesh = torus
	var glow := StandardMaterial3D.new()
	glow.albedo_color = Color(0.45, 0.75, 1.0)
	glow.emission_enabled = true
	glow.emission = glow.albedo_color
	glow.emission_energy_multiplier = 2.5
	ring.material_override = glow
	ring.position = at
	add_child(ring)

func _torch(at: Vector3) -> void:
	var light := OmniLight3D.new()
	light.position = at
	light.light_color = Color(1.0, 0.68, 0.35)
	light.light_energy = 1.6
	light.omni_range = 11.0
	add_child(light)
	var flame := MeshInstance3D.new()
	var sphere := SphereMesh.new()
	sphere.radius = 0.18
	sphere.height = 0.36
	flame.mesh = sphere
	var mat := StandardMaterial3D.new()
	mat.albedo_color = Color(1.0, 0.6, 0.2)
	mat.emission_enabled = true
	mat.emission = mat.albedo_color
	mat.emission_energy_multiplier = 4.0
	flame.material_override = mat
	flame.position = at
	add_child(flame)
