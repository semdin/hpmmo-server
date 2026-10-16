extends Node3D

## Shared base of the code-built dungeon maps (an instanced map's scene).
##
## Every copy of a dungeon is its scene placed at the copy's instance origin
## (HPMaps.instance_origin); the world server builds it collision-only
## (server/world/server/map_host.gd), a client with surfaces and lights.
## Subclasses lay the rooms out in `_build()` with the helpers below; the run
## (dungeons.json, scripts/world/dungeon_director.gd) owns the gates, which
## `apply_state` opens/closes from the replicated run state.

const GROUP := "dungeon_instance"

## Set by the loader before the node enters the tree.
var map_id := ""
var collision_only := false
var floor_y := 1000.0
var wall_h := 8.0

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
		_stone = _mat(Color(0.33, 0.32, 0.34), 0.95)
		_iron = _mat(Color(0.16, 0.15, 0.15), 0.5, 0.6)
	_build()

## Subclasses build their rooms here.
func _build() -> void:
	pass

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

func _mat(color: Color, roughness: float, metallic: float = 0.0) -> StandardMaterial3D:
	var m := StandardMaterial3D.new()
	m.albedo_color = color
	m.roughness = roughness
	m.metallic = metallic
	return m

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

## A decorative box (no collision), client only.
func _deco(center: Vector3, size: Vector3, material: Material) -> void:
	if collision_only:
		return
	var mesh := MeshInstance3D.new()
	var bm := BoxMesh.new()
	bm.size = size
	mesh.mesh = bm
	mesh.material_override = material
	mesh.position = center
	add_child(mesh)

## A room's floor and four walls, `size` (x, z) centred on `center` (x, z),
## leaving an 8 m doorway wherever an opening point lies on a wall.
func _room(center: Vector2, size: Vector2, openings: Array, door: float = 8.0, y: float = INF) -> void:
	var fy := floor_y if y == INF else y
	_box(Vector3(center.x, fy - 0.5, center.y), Vector3(size.x, 1, size.y))
	var hx := size.x * 0.5
	var hz := size.y * 0.5
	var wy := fy + wall_h * 0.5
	for side in [-1.0, 1.0]:
		_box(Vector3(center.x + side * (hx + 0.5), wy, center.y), Vector3(1, wall_h, size.y + 2.0))
		var wz: float = center.y + side * (hz + 0.5)
		var gap := false
		for o in openings:
			if absf(float(o) - (center.y + side * hz)) < 0.6:
				gap = true
		if not gap:
			_box(Vector3(center.x, wy, wz), Vector3(size.x, wall_h, 1))
		else:
			var seg := (size.x - door) * 0.5
			if seg > 0.0:
				_box(Vector3(center.x - (door * 0.5 + seg * 0.5), wy, wz), Vector3(seg, wall_h, 1))
				_box(Vector3(center.x + (door * 0.5 + seg * 0.5), wy, wz), Vector3(seg, wall_h, 1))
	# A ceiling keeps the light in and the sky out.
	_deco(Vector3(center.x, fy + wall_h + 0.25, center.y), Vector3(size.x + 2, 0.5, size.y + 2), _stone)

func _gate(id: String, center: Vector3, size: Vector3) -> void:
	_gates[id] = _box(center, size, _iron)
	(_gates[id] as StaticBody3D).name = "Gate_" + id

func _portal_ring(at: Vector3) -> void:
	if collision_only:
		return
	var ring := MeshInstance3D.new()
	var torus := TorusMesh.new()
	torus.inner_radius = 1.8
	torus.outer_radius = 2.2
	ring.mesh = torus
	var glow := _mat(Color(0.45, 0.75, 1.0), 0.5)
	glow.emission_enabled = true
	glow.emission = glow.albedo_color
	glow.emission_energy_multiplier = 2.5
	ring.material_override = glow
	ring.position = at
	add_child(ring)

func _torch(at: Vector3, color: Color = Color(1.0, 0.68, 0.35), energy: float = 1.6, reach: float = 11.0) -> void:
	if collision_only:
		return
	var light := OmniLight3D.new()
	light.position = at
	light.light_color = color
	light.light_energy = energy
	light.omni_range = reach
	add_child(light)
	var flame := MeshInstance3D.new()
	var sphere := SphereMesh.new()
	sphere.radius = 0.18
	sphere.height = 0.36
	flame.mesh = sphere
	var mat := _mat(color, 0.5)
	mat.emission_enabled = true
	mat.emission = color
	mat.emission_energy_multiplier = 4.0
	flame.material_override = mat
	flame.position = at
	add_child(flame)

## An authored model as static scenery (client only), e.g. a suit of armour on
## its plinth. It stands in its bind pose (no clip is played).
func _prop(path: String, at: Vector3, yaw_deg: float = 0.0, scale_by: float = 1.0) -> Node3D:
	if collision_only or not ResourceLoader.exists(path):
		return null
	var node: Node3D = (load(path) as PackedScene).instantiate()
	node.position = at
	node.rotation.y = deg_to_rad(yaw_deg)
	node.scale = Vector3.ONE * scale_by
	add_child(node)
	return node
