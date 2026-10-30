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
## The castle's world-space PBR kit (triplanar, no UVs): a dungeon reads as
## part of the same castle, not a grey box.
const Kit = preload("res://scripts/world/castle/castle_blockout.gd")

## Set by the loader before the node enters the tree.
var map_id := ""
var collision_only := false
var floor_y := 1000.0
var wall_h := 8.0

var _gates: Dictionary = {}   # gate id -> StaticBody3D
var _stone: Material
var _iron: StandardMaterial3D
var _floor_mat: Material
var _vault: Material
var _trim: Material
## Pilaster spacing along a room's long walls (0 = none).
var bay := 6.0

func setup(p_map_id: String, p_collision_only: bool = false) -> void:
	map_id = p_map_id
	collision_only = p_collision_only
	position = HPMaps.instance_origin(map_id)
	set_meta("map_id", map_id)

func _ready() -> void:
	add_to_group(GROUP)
	if not collision_only:
		_stone = Kit.kit_material_for_quality("stone_cold")
		_floor_mat = Kit.kit_material_for_quality("stone_floor")
		_vault = Kit.kit_material_for_quality("stone_vault_cold")
		_trim = Kit.kit_material_for_quality("trim_cold")
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
## `side_doors` (Vector2(side, z): side -1 west, +1 east) cut SIDE_DOOR wide
## doorways into the long x walls; `open_side` (-1 / +1) leaves that x wall
## out - a side room joined to the room whose wall already stands there.
func _room(center: Vector2, size: Vector2, openings: Array, door: float = 8.0, y: float = INF,
		side_doors: Array = [], open_side: int = 0) -> void:
	var fy := floor_y if y == INF else y
	_box(Vector3(center.x, fy - 0.5, center.y), Vector3(size.x, 1, size.y), _floor_mat)
	var hx := size.x * 0.5
	var hz := size.y * 0.5
	var wy := fy + wall_h * 0.5
	for side in [-1.0, 1.0]:
		if int(side) != open_side:
			_wall_x(center.x + side * (hx + 0.5), wy, center.y - hz - 1.0, center.y + hz + 1.0, _doors_on(side_doors, int(side)))
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
	# A ceiling keeps the light in and the sky out (short of a joined room's).
	var lip := 1.0 if open_side != 0 else 2.0
	_deco(Vector3(center.x - float(open_side) * 0.5, fy + wall_h + 0.25, center.y), Vector3(size.x + lip, 0.5, size.y + 2), _vault)
	_dress_room(center, size, fy, open_side, side_doors)

const SIDE_DOOR := 6.0

static func _doors_on(side_doors: Array, side: int) -> Array:
	var out: Array = []
	for d in side_doors:
		if int((d as Vector2).x) == side:
			out.append((d as Vector2).y)
	out.sort()
	return out

## A wall along z at `x`, from `z_from` to `z_to`, with a SIDE_DOOR doorway
## centred on each z in `doors` (ascending); a sill floors each doorway.
func _wall_x(x: float, wy: float, z_from: float, z_to: float, doors: Array) -> void:
	var z := z_from
	for d in doors:
		var a := float(d) - SIDE_DOOR * 0.5
		if a > z:
			_box(Vector3(x, wy, (z + a) * 0.5), Vector3(1, wall_h, a - z))
		_box(Vector3(x, wy - wall_h * 0.5 - 0.5, float(d)), Vector3(1, 1, SIDE_DOOR), _floor_mat)
		z = float(d) + SIDE_DOOR * 0.5
	if z_to > z:
		_box(Vector3(x, wy, (z + z_to) * 0.5), Vector3(1, wall_h, z_to - z))

## Dressed stone on a plain room: a plinth along every wall, pilasters every
## `bay` metres down the long walls carrying transverse ribs under the ceiling,
## and a cornice where wall meets vault (none along an open side).
func _dress_room(center: Vector2, size: Vector2, fy: float, open_side: int = 0, side_doors: Array = []) -> void:
	if collision_only:
		return
	var hx := size.x * 0.5
	var hz := size.y * 0.5
	for side in [-1.0, 1.0]:
		if int(side) != open_side:
			_deco(Vector3(center.x + side * (hx - 0.15), fy + 0.25, center.y), Vector3(0.3, 0.5, size.y), _trim)
			_deco(Vector3(center.x + side * (hx - 0.2), fy + wall_h - 0.3, center.y), Vector3(0.4, 0.6, size.y), _trim)
		_deco(Vector3(center.x, fy + 0.25, center.y + side * (hz - 0.15)), Vector3(size.x, 0.5, 0.3), _trim)
	if bay <= 0.0:
		return
	var count := int(floor(size.y / bay))
	for i in range(1, count + 1):
		var z := center.y + hz - i * bay
		if z <= center.y - hz + 0.5:
			break
		for side in [-1.0, 1.0]:
			var in_door := _doors_on(side_doors, int(side)).any(func(d): return absf(float(d) - z) < SIDE_DOOR * 0.5 + 0.5)
			if int(side) != open_side and not in_door:
				_deco(Vector3(center.x + side * (hx - 0.35), fy + wall_h * 0.5, z), Vector3(0.7, wall_h, 0.9), _trim)
		_deco(Vector3(center.x, fy + wall_h - 0.2, z), Vector3(size.x, 0.4, 0.6), _trim)

## A portcullis: iron bars and cross straps (the body's collision is the
## full box; the bars are what a client sees).
func _gate(id: String, center: Vector3, size: Vector3) -> void:
	var body := StaticBody3D.new()
	body.name = "Gate_" + id
	body.position = center
	var shape := CollisionShape3D.new()
	var box := BoxShape3D.new()
	box.size = size
	shape.shape = box
	body.add_child(shape)
	add_child(body)
	_gates[id] = body
	if collision_only:
		return
	var bars := int(size.x / 0.45)
	for i in range(bars + 1):
		var bar := MeshInstance3D.new()
		var cyl := CylinderMesh.new()
		cyl.top_radius = 0.06
		cyl.bottom_radius = 0.06
		cyl.height = size.y
		cyl.radial_segments = 8
		bar.mesh = cyl
		bar.material_override = _iron
		bar.position = Vector3(-size.x * 0.5 + i * size.x / bars, 0, 0)
		body.add_child(bar)
	for y in [-size.y * 0.3, 0.0, size.y * 0.3]:
		var strap := MeshInstance3D.new()
		var bm := BoxMesh.new()
		bm.size = Vector3(size.x + 0.1, 0.16, 0.12)
		strap.mesh = bm
		strap.material_override = _iron
		strap.position = Vector3(0, y, 0)
		body.add_child(strap)

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
	# A living flame (FireCard flipbook); a cold or green torch keeps its hue.
	var warm := color.r > 0.9 and color.g < 0.8
	FireCard.make(self, at + Vector3(0, 0.12, 0), Vector2(0.42, 0.68), Color(1, 1, 1) if warm else color, 1.5)
	# The iron sconce under the flame.
	var cup := MeshInstance3D.new()
	var cm := CylinderMesh.new()
	cm.top_radius = 0.2
	cm.bottom_radius = 0.08
	cm.height = 0.3
	cm.radial_segments = 10
	cup.mesh = cm
	cup.material_override = _iron
	cup.position = at - Vector3(0, 0.25, 0)
	add_child(cup)

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
