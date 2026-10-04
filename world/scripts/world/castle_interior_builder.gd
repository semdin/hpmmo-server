extends RefCounted

## Castle interior (plan.md Phase 8 greybox, resurfaced in Phase 10).
##
## OWNER: client. The layout, the collision and the walkable route are the
## Phase 8 geometry, unchanged: every floor, wall, ramp and railing keeps the
## same collider it had when the walkthrough passed (scenes/test/
## castle_walkthrough.tscn, 87 checks). Phase 10 replaces the greybox *surfaces*
## with authored PBR materials, dresses the rooms through the Gothic kit, and
## bakes a static occlusion term into the batched architecture.
##
## Geometry rules kept from Phase 8:
##   * everything walkable carries collision (layer 1);
##   * stairs are one ramp collider with decorative treads inside half a step;
##   * openings are recorded so the arch surrounds land exactly on the gap the
##     wall already has.
##
## Level heights and the stair profile are copied from the shared map contract
## (`addons/hpmmo_sim/data/maps.json`): floors at y 194 / 200 / 206 / 212 and a
## 6 m rise over a 12 m run with 0.2 m steps.

const Batch = preload("res://scripts/assets/static_batch.gd")
const PBR = preload("res://scripts/assets/pbr_kit.gd")

# --- vertical layout (matches maps.json "floors").
const Y_BASEMENT := 194.0
const Y_GROUND := 200.0
const Y_FIRST := 206.0
const Y_SECOND := 212.0
const STOREY := 6.0
const SLAB := 0.4          # floor slab thickness

# --- stair profile (matches maps.json "staircase.flight").
const STAIR_RISE := 6.0
const STAIR_RUN := 12.0
const STEP_H := 0.2
const STAIR_W := 6.0

# --- modular clearances (plan.md Phase 2 dimensions).
const DOOR_W := 2.2        # doorway clear width
const DOOR_H := 2.8
const WALL_T := 0.5
const RAIL_H := 1.1
const RAIL_T := 0.14

## Openings recorded while walls are built, so arch surrounds can dress the
## exact gaps the walls already have.
static var _openings: Array = []

static func build(root: Node3D) -> void:
	if root.has_node("InteriorStructure"):
		return
	var s := Node3D.new()
	s.name = "InteriorStructure"
	root.add_child(s)
	_openings.clear()

	_build_ground_shell(s)
	_build_first_floor(s)
	_build_second_floor(s)
	_build_basement(s)
	_build_stairs(s)
	_build_tower(s)
	_build_arches(s)
	_build_cloister_windows(s)
	_build_buttresses_and_columns(s)
	_build_furniture_great_hall(s)
	_build_furniture_library(s)
	_build_furniture_classrooms(s)
	_build_furniture_circulation(s)
	_build_furniture_basement(s)
	_build_signs(s)
	_build_lights(s)
	_build_floor_wear(s)

	# Repeated kit props (treads, balusters, candles, rubble) become one
	# MultiMesh per module; single props stay individual meshes.
	PBR.flush(s)
	# Merge the many architectural boxes into per-material, per-chunk draws.
	# Named nodes and their collision bodies stay in place.
	Batch.boxes(s)
	_openings.clear()

# =========================================================== materials

static func _stone() -> Material:
	return PBR.slot_material("stone")

static func _trim_mat() -> Material:
	return PBR.slot_material("trim")

static func _floor_mat() -> Material:
	return PBR.slot_material("stone_floor")

static func _wood() -> Material:
	return PBR.slot_material("wood")

static func _carpet(color: Color) -> Material:
	var m := StandardMaterial3D.new()
	m.albedo_color = color
	m.roughness = 0.95
	return m

static func _basement_mat() -> Material:
	return PBR.surface("stone_ashlar_02", Color(0.78, 0.80, 0.86), {"rough_min": 0.55})

static var _mats: Dictionary = {}

static func _mat(color: Color, glow: bool = false, rough: float = 0.82) -> StandardMaterial3D:
	var key := "%s_%s_%.2f" % [color.to_html(), glow, rough]
	if _mats.has(key):
		return _mats[key]
	var m := StandardMaterial3D.new()
	m.albedo_color = color
	m.roughness = rough
	if glow:
		m.emission_enabled = true
		m.emission = color
		m.emission_energy_multiplier = 1.6
	_mats[key] = m
	return m

# =========================================================== primitives

static func _mesh(parent: Node3D, title: String, mesh: Mesh, pos: Vector3, material: Material) -> MeshInstance3D:
	var node := MeshInstance3D.new()
	node.name = title
	node.mesh = mesh
	node.material_override = material
	node.position = pos
	parent.add_child(node)
	return node

## A box. `solid` adds the Phase 8 collider; `visible_box` false keeps a
## collider without a greybox mesh (the kit supplies the visible surface).
static func _box(parent: Node3D, title: String, pos: Vector3, size: Vector3,
		material: Material, solid: bool = true, visible_box: bool = true) -> MeshInstance3D:
	var node: MeshInstance3D = null
	if visible_box:
		var mesh := BoxMesh.new()
		mesh.size = size
		node = _mesh(parent, title, mesh, pos, material)
	if solid:
		var body := StaticBody3D.new()
		body.name = title + "Body" if node == null else "Body"
		body.collision_layer = 1
		body.collision_mask = 0
		var shape := BoxShape3D.new()
		shape.size = size
		var collision := CollisionShape3D.new()
		collision.shape = shape
		body.add_child(collision)
		if node != null:
			node.add_child(body)
		else:
			body.position = pos
			parent.add_child(body)
	return node

## A collider that is never drawn: the Phase 8 surface is replaced by a kit
## piece, but the collision it owned stays exactly where it was.
static func _collider(parent: Node3D, title: String, pos: Vector3, size: Vector3) -> void:
	_box(parent, title, pos, size, null, true, false)

static func _cyl_collider(parent: Node3D, title: String, pos: Vector3, radius: float, height: float) -> void:
	var body := StaticBody3D.new()
	body.name = title
	body.collision_layer = 1
	body.collision_mask = 0
	var shape := CylinderShape3D.new()
	shape.radius = radius
	shape.height = height
	var collision := CollisionShape3D.new()
	collision.shape = shape
	body.add_child(collision)
	body.position = pos + Vector3(0, height * 0.5, 0)
	parent.add_child(body)

## One kit module as a real node (multi-material props, banners with tint).
static func _kit(parent: Node3D, module: String, pos: Vector3, rot_y: float = 0.0,
		scale := Vector3.ONE, tint: Color = Color.WHITE) -> Node3D:
	var node := PBR.kit_instance(module, tint)
	if node == null:
		return null
	node.position = pos
	node.rotation.y = rot_y
	node.scale = scale
	parent.add_child(node)
	return node

## One kit module queued for MultiMesh instancing (repeated props).
static func _kit_instanced(module: String, pos: Vector3, rot_y: float = 0.0,
		scale := Vector3.ONE) -> void:
	var basis := Basis.from_euler(Vector3(0.0, rot_y, 0.0))
	basis = basis * Basis.from_scale(scale)
	PBR.queue(module, Transform3D(basis, pos))

## Floor slab with the top surface at `y`, spanning [x0,x1] x [z0,z1].
static func _slab(parent: Node3D, title: String, x0: float, x1: float, z0: float, z1: float, y: float, material: Material) -> void:
	if x1 - x0 <= 0.01 or z1 - z0 <= 0.01:
		return
	_box(parent, title, Vector3((x0 + x1) * 0.5, y - SLAB * 0.5, (z0 + z1) * 0.5),
		Vector3(x1 - x0, SLAB, z1 - z0), material)

## Floor slab with a stairwell/opening cut out of it. The opening is a hole in
## the walkable surface, never a place to fall through by accident: the caller
## rails the edges that are not a stair mouth.
static func _slab_hole(parent: Node3D, title: String, x0: float, x1: float, z0: float, z1: float,
		hx0: float, hx1: float, hz0: float, hz1: float, y: float, material: Material) -> void:
	var lo_x: float = maxf(x0, hx0)
	var hi_x: float = minf(x1, hx1)
	var lo_z: float = maxf(z0, hz0)
	var hi_z: float = minf(z1, hz1)
	if lo_z > z0:
		_slab(parent, title, x0, x1, z0, lo_z, y, material)
	if hi_z < z1:
		_slab(parent, title, x0, x1, hi_z, z1, y, material)
	if lo_x > x0:
		_slab(parent, title, x0, lo_x, lo_z, hi_z, y, material)
	if hi_x < x1:
		_slab(parent, title, hi_x, x1, lo_z, hi_z, y, material)

## A wall plane with door openings. `axis` is the axis the plane is constant on:
## "x" -> the wall is at x = fixed and spans z; "z" -> at z = fixed, spans x.
## Openings are [centre, width] or [centre, width, height] or
## [centre, width, height, sill] (the sill lifts the opening off the floor, e.g.
## a balcony door in a tall wall). Openings must not overlap along the span.
static func _wall(parent: Node3D, title: String, axis: String, fixed: float, from: float, to: float,
		y0: float, y1: float, material: Material, openings: Array = [], thickness: float = WALL_T) -> void:
	if to < from:
		var swap := from
		from = to
		to = swap
	var sorted: Array = openings.duplicate()
	sorted.sort_custom(func(a, b): return float(a[0]) < float(b[0]))
	var cursor := from
	for o in sorted:
		var centre := float(o[0])
		var width := float(o[1])
		var height: float = float(o[2]) if o.size() > 2 else DOOR_H
		var sill: float = float(o[3]) if o.size() > 3 else 0.0
		var lo: float = centre - width * 0.5
		var hi: float = centre + width * 0.5
		if lo > cursor:
			_wall_segment(parent, title, axis, fixed, cursor, lo, y0, y1, material, thickness)
		if sill > 0.0:
			_wall_segment(parent, title + "Spandrel", axis, fixed, lo, hi, y0, y0 + sill, material, thickness)
		if y0 + sill + height < y1:
			_wall_segment(parent, title + "Lintel", axis, fixed, lo, hi, y0 + sill + height, y1, material, thickness)
		cursor = maxf(cursor, hi)
		_openings.append({"axis": axis, "fixed": fixed, "centre": centre, "width": width,
			"height": height, "sill": sill, "y0": y0, "thickness": thickness})
	if cursor < to:
		_wall_segment(parent, title, axis, fixed, cursor, to, y0, y1, material, thickness)

static func _wall_segment(parent: Node3D, title: String, axis: String, fixed: float, a: float, b: float,
		y0: float, y1: float, material: Material, thickness: float) -> void:
	if b - a <= 0.02 or y1 - y0 <= 0.02:
		return
	var h := y1 - y0
	var size: Vector3 = Vector3(thickness, h, b - a) if axis == "x" else Vector3(b - a, h, thickness)
	var pos: Vector3 = Vector3(fixed, (y0 + y1) * 0.5, (a + b) * 0.5) if axis == "x" \
		else Vector3((a + b) * 0.5, (y0 + y1) * 0.5, fixed)
	_box(parent, title, pos, size, material)

## A railing along a gallery edge or around a stairwell. The Phase 8 solid
## collision stays (a body cannot walk through); the visible surface is now a
## Gothic balustrade with newel posts at both ends.
static func _rail(parent: Node3D, title: String, axis: String, fixed: float, from: float, to: float, y: float) -> void:
	# Invisible collider exactly where the Phase 8 rail wall was.
	_wall(parent, title, axis, fixed, from, to, y, y + RAIL_H, null, [], RAIL_T)
	var length: float = absf(to - from)
	var segments: int = maxi(1, int(round(length / 4.0)))
	var seg_len := (to - from) / float(segments)
	for i in range(segments):
		var mid: float = from + seg_len * (float(i) + 0.5)
		var rot := 0.0 if axis == "x" else PI * 0.5
		# Balustrade runs along its local X; scale to the segment length.
		_kit_instanced("balustrade_4", Vector3(fixed, y, mid) if axis == "x" else Vector3(mid, y, fixed),
			rot, Vector3(absf(seg_len) / 4.0, 1.0, 1.0))
	for end in [from, to]:
		var pos: Vector3 = Vector3(fixed, y, end) if axis == "x" else Vector3(end, y, fixed)
		_kit_instanced("newel_post_1_2", pos)

# =========================================================== stairs

## A flight of stairs rising `rise` over `run`, travelling in `dir` along `axis`.
## `cross` is the coordinate the flight is centred on for the other axis.
##
## Collision is ONE ramp whose top surface runs exactly from the lower floor
## plane to the upper one. A CharacterBody3D has no step-up, so a flight of
## discrete collider boxes would stop the player at the first tread; the ramp
## makes the whole flight walkable while the treads are drawn on it for
## readability (they sit within half a step of the collision surface), with
## parapets on both sides so a walker cannot step off the edge.
static func _stairs(parent: Node3D, title: String, axis: String, cross: float, start: float, y0: float,
		dir: float, width: float = STAIR_W, rise: float = STAIR_RISE, run: float = STAIR_RUN) -> void:
	var length := sqrt(rise * rise + run * run)
	var travel := Vector3(0, 0, dir) if axis == "z" else Vector3(dir, 0, 0)
	var along := (travel * run + Vector3.UP * rise).normalized()
	var normal := (Vector3.UP - along * Vector3.UP.dot(along)).normalized()
	var lateral := normal.cross(along).normalized()
	var base := Vector3(cross, y0, start) if axis == "z" else Vector3(start, y0, cross)
	var centre := base + travel * (run * 0.5) + Vector3.UP * (rise * 0.5)
	var basis := Basis(lateral, normal, along)
	var ramp := Node3D.new()
	ramp.name = title
	ramp.transform = Transform3D(basis, centre - normal * (SLAB * 0.5))
	parent.add_child(ramp)
	_box(ramp, title + "Ramp", Vector3.ZERO, Vector3(width, SLAB, length), _floor_mat())

	# Treads: kit modules drawn on the ramp (the ramp carries the body).
	var treads := int(round(rise / STEP_H))
	var tread_depth := run / float(treads)
	for i in range(treads):
		var top := y0 + (float(i) + 0.5) * STEP_H
		var offset := start + dir * (float(i) + 0.5) * tread_depth
		var tread_pos := Vector3(cross, top - 0.3, offset) if axis == "z" else Vector3(offset, top - 0.3, cross)
		var rot := 0.0 if axis == "z" else PI * 0.5
		_kit_instanced("stair_tread_0_2x4", tread_pos, rot, Vector3(width / 4.0, 1.0, 1.0))

	# Parapets on both sides, following the ramp (collision stays; the visible
	# surface is a balustrade following the same slope).
	for side in [-1.0, 1.0]:
		var para := Node3D.new()
		para.name = title + "Parapet"
		para.transform = Transform3D(basis, centre + lateral * (side * (width * 0.5 + RAIL_T * 0.5)) + normal * (RAIL_H * 0.5))
		parent.add_child(para)
		_box(para, title + "ParapetWall", Vector3.ZERO, Vector3(RAIL_T, RAIL_H, length), null, true, false)
		var segs := int(round(length / 4.0))
		for i in range(segs):
			var t := (float(i) + 0.5) / float(segs)
			var piece := PBR.kit_instance("balustrade_4")
			if piece == null:
				continue
			piece.transform = Transform3D(basis,
				centre + lateral * (side * (width * 0.5 + RAIL_T * 0.5)) + along * (length * (t - 0.5)) + normal * (RAIL_H * 0.5))
			piece.scale = Vector3(length / float(segs) / 4.0, 1.0, 1.0)
			parent.add_child(piece)

	# Floor sign at the foot of the flight so the route is readable.
	var sign_pos := Vector3(cross, y0 + 2.4, start + dir * 0.8) if axis == "z" \
		else Vector3(start + dir * 0.8, y0 + 2.4, cross)
	_sign(parent, "↑ UP", sign_pos, 26, Color(1.0, 0.88, 0.55))

# =========================================================== ground floor

static func _build_ground_shell(s: Node3D) -> void:
	var stone := _stone()
	var floor_m := _floor_mat()
	# --- floors (Great Hall + corridors + stair hall + vestibule) -------------
	_slab_hole(s, "GreatHallFloor", -58, -16, -24, 20, -49, -43, -24, -12, Y_GROUND, floor_m)
	_slab(s, "NorthCorridorFloor", -64, 44, -30, -24, Y_GROUND, floor_m)
	_slab(s, "WestCorridorFloor", -64, -58, -24, 20, Y_GROUND, floor_m)
	_slab(s, "SouthCorridorFloor", -64, -16, 20, 26, Y_GROUND, floor_m)
	_slab(s, "StairHallFloor", -16, 44, -24, 36, Y_GROUND, floor_m)
	_slab(s, "VestibuleFloor", -12, 12, 36, 38, Y_GROUND, floor_m)
	_slab(s, "GreatHallDoorApron", -16, -14, 2, 10, Y_GROUND, floor_m)

	# Great Hall walls (19 m to the balcony).
	_wall(s, "GreatHallEast", "x", -16, -24, 20, Y_GROUND, Y_GROUND + 19.0, stone,
		[[0.0, 6.0, 5.0], [8.0, 6.0, 5.0], [16.0, 6.0, 3.0, 12.0]])
	_wall(s, "GreatHallWest", "x", -58, -24, 20, Y_GROUND, Y_GROUND + 19.0, stone)
	_wall(s, "GreatHallSouth", "z", 20, -58, -16, Y_GROUND, Y_GROUND + 19.0, stone, [[-36.0, 8.0, 5.0]])
	_wall(s, "GreatHallNorth", "z", -24, -58, -16, Y_GROUND, Y_GROUND + 19.0, stone,
		[[-36.0, 8.0, 5.0], [-46.0, 6.0, 6.0]])
	_slab(s, "GreatHallCeiling", -58, -16, -24, 20, Y_GROUND + 19.0, stone)

	# Stair hall walls.
	_wall(s, "StairHallNorth", "z", -24, -16, 44, Y_GROUND, Y_GROUND + 6.0, stone, [[1.0, 10.0, 5.0]])
	_wall(s, "StairHallEast", "x", 44, -24, 36, Y_GROUND, Y_GROUND + 18.0, stone, [[8.0, 8.0, 3.0, 12.0]])
	_wall(s, "HallSouthWest", "z", 26, -16, 12, Y_GROUND, Y_GROUND + 6.0, stone, [[0.0, 8.0, 4.0]])
	_wall(s, "HallSouthEast", "z", 36, 12, 44, Y_GROUND, Y_GROUND + 18.0, stone)
	_slab(s, "StairHallRoof", -16, 44, -24, 36, Y_GROUND + 18.0, stone)

	# Entrance vestibule.
	_wall(s, "VestibuleWest", "x", -12, 26, 38, Y_GROUND, Y_GROUND + 6.0, stone)
	_wall(s, "VestibuleEast", "x", 12, 26, 38, Y_GROUND, Y_GROUND + 6.0, stone)
	_wall(s, "VestibuleFront", "z", 38, -12, 12, Y_GROUND, Y_GROUND + 6.0, stone, [[0.0, 6.0, 3.4]])
	_slab(s, "VestibuleCeiling", -12, 12, 36, 38, Y_FIRST, stone)
	_slab(s, "EntrancePorch", -6, 6, 38, 44, Y_GROUND, floor_m)
	_wall(s, "PorchWest", "x", -6, 38, 44, Y_GROUND, Y_GROUND + 2.4, stone, [], 0.4)
	_wall(s, "PorchEast", "x", 6, 38, 44, Y_GROUND, Y_GROUND + 2.4, stone, [], 0.4)
	_wall(s, "PorchFront", "z", 44, -6, 6, Y_GROUND, Y_GROUND + 2.4, stone, [], 0.4)

	# Corridor shells.
	_wall(s, "NorthCorridorBack", "z", -30, -64, 44, Y_GROUND, Y_GROUND + 6.0, stone, [], 0.8)
	_wall(s, "WestCorridorOuter", "x", -64, -30, 20, Y_GROUND, Y_GROUND + 6.0, stone)
	_wall(s, "NorthCorridorEnd", "x", 44, -30, -24, Y_GROUND, Y_GROUND + 6.0, stone)
	_wall(s, "SouthCorridorSouth", "z", 26, -64, -16, Y_GROUND, Y_GROUND + 18.0, stone)
	_wall(s, "SouthCorridorEast", "x", -16, 20, 26, Y_GROUND, Y_GROUND + 6.0, stone, [[23.0, 6.0, 5.0]])
	_wall(s, "SouthCorridorEastUpper", "x", -16, 20, 26, Y_FIRST, Y_GROUND + 18.0, stone)
	_slab(s, "NorthCorridorCeiling", -64, 44, -30, -24, Y_FIRST, stone)
	_slab(s, "WestCorridorCeiling", -64, -58, -30, 20, Y_FIRST, stone)
	_slab(s, "SouthCorridorCeiling", -64, -16, 20, 26, Y_FIRST, stone)

	# Dungeon stairwell (railed on the three open sides).
	_rail(s, "DungeonWellWest", "x", -49, -24, -12, Y_GROUND)
	_rail(s, "DungeonWellEast", "x", -43, -24, -12, Y_GROUND)
	_rail(s, "DungeonWellSouth", "z", -12, -49, -43, Y_GROUND)

# =========================================================== first floor

static func _build_first_floor(s: Node3D) -> void:
	var stone := _stone()
	var floor_m := _floor_mat()
	_slab(s, "FirstLibraryFloor", -58, -18, -50, -30, Y_FIRST, floor_m)
	_slab(s, "FirstClassroomFloor", -14, 20, -50, -30, Y_FIRST, floor_m)
	_slab(s, "FirstPierFloor", -18, -14, -50, -30, Y_FIRST, floor_m)
	_slab(s, "FirstCorridorFloor", -58, 44, -30, -24, Y_FIRST, floor_m)
	_slab(s, "FirstGalleryNorth", -16, 44, -24, -16, Y_FIRST, floor_m)
	_slab(s, "FirstGallerySouth", -16, 44, 26, 36, Y_FIRST, floor_m)
	_slab(s, "FirstGalleryWest", -16, -4, -16, 26, Y_FIRST, floor_m)
	_slab(s, "FirstGalleryEastNorth", 36, 44, -16, 12, Y_FIRST, floor_m)
	_slab(s, "FirstGalleryEastSouth", 36, 44, 24, 26, Y_FIRST, floor_m)
	_slab(s, "FirstGalleryEastWalkway", 36, 38.5, 12, 24, Y_FIRST, floor_m)
	_slab(s, "FirstGalleryEastLedge", 43.5, 44, 12, 24, Y_FIRST, floor_m)

	_wall(s, "FirstLibraryWest", "x", -58, -50, -30, Y_FIRST, Y_FIRST + 6.0, stone)
	_wall(s, "FirstLibraryNorth", "z", -50, -58, -18, Y_FIRST, Y_FIRST + 6.0, stone)
	_wall(s, "FirstLibrarySouth", "z", -30, -58, -18, Y_FIRST, Y_FIRST + 6.0, stone, [[-34.0, DOOR_W, 2.8]])
	_wall(s, "FirstLibraryEast", "x", -18, -50, -30, Y_FIRST, Y_FIRST + 6.0, stone)
	_wall(s, "FirstPierWest", "x", -14, -50, -30, Y_FIRST, Y_FIRST + 6.0, stone)
	_wall(s, "FirstClassroomEast", "x", 20, -50, -30, Y_FIRST, Y_FIRST + 6.0, stone)
	_wall(s, "FirstClassroomNorth", "z", -50, -14, 20, Y_FIRST, Y_FIRST + 6.0, stone)
	_wall(s, "FirstClassroomSouth", "z", -30, -14, 20, Y_FIRST, Y_FIRST + 6.0, stone, [[-4.0, DOOR_W, 2.8]])
	_wall(s, "FirstCorridorNorthPier", "z", -30, -18, -14, Y_FIRST, Y_FIRST + 6.0, stone)
	_wall(s, "FirstCorridorNorthEast", "z", -30, 20, 44, Y_FIRST, Y_FIRST + 6.0, stone)
	_wall(s, "FirstCorridorSouth", "z", -24, -58, -16, Y_FIRST, Y_FIRST + 6.0, stone)
	_wall(s, "FirstCorridorWestEnd", "x", -58, -30, -24, Y_FIRST, Y_FIRST + 6.0, stone)
	_wall(s, "FirstCorridorEnd", "x", 44, -30, -24, Y_FIRST, Y_FIRST + 6.0, stone)
	_wall(s, "FirstGalleryWestEnd", "x", -16, 26, 36, Y_FIRST, Y_FIRST + 6.0, stone)
	_slab(s, "FirstNorthBlockRoof", -64, 44, -50, -24, Y_SECOND, stone)

	_rail(s, "FirstWellWest", "x", -4, -16, 26, Y_FIRST)
	_rail(s, "FirstWellEast", "x", 36, -16, 26, Y_FIRST)
	_rail(s, "FirstWellNorth", "z", -16, -4, 36, Y_FIRST)
	_rail(s, "FirstWellSouth", "z", 26, -4, 36, Y_FIRST)
	_rail(s, "FirstStairWellWest", "x", 38.5, 12, 24, Y_FIRST)
	_rail(s, "FirstStairWellEast", "x", 43.5, 12, 24, Y_FIRST)
	_rail(s, "FirstStairWellSouth", "z", 24, 38.5, 43.5, Y_FIRST)

static func _build_second_floor(s: Node3D) -> void:
	var stone := _stone()
	var floor_m := _floor_mat()
	_slab(s, "SecondClassroomOneFloor", -58, -18, -50, -30, Y_SECOND, floor_m)
	_slab(s, "SecondClassroomTwoFloor", -14, 20, -50, -30, Y_SECOND, floor_m)
	_slab(s, "SecondPierFloor", -18, -14, -50, -30, Y_SECOND, floor_m)
	_slab(s, "SecondCorridorFloor", -58, 44, -30, -24, Y_SECOND, floor_m)
	_slab(s, "SecondGalleryNorth", -16, 44, -24, -16, Y_SECOND, floor_m)
	_slab(s, "SecondGallerySouth", -16, 44, 26, 36, Y_SECOND, floor_m)
	_slab(s, "SecondGalleryWest", -16, -4, -16, 26, Y_SECOND, floor_m)
	_slab(s, "SecondGalleryEastNorth", 36, 44, -16, -4, Y_SECOND, floor_m)
	_slab(s, "SecondGalleryEastSouth", 36, 44, 8, 26, Y_SECOND, floor_m)
	_slab(s, "SecondGalleryEastWalkway", 36, 38.5, -4, 8, Y_SECOND, floor_m)
	_slab(s, "SecondGalleryEastLedge", 43.5, 44, -4, 8, Y_SECOND, floor_m)
	_slab(s, "GreatHallBalconyFloor", -24, -16, 12, 20, Y_SECOND, floor_m)

	_wall(s, "SecondLibraryWest", "x", -58, -50, -30, Y_SECOND, Y_SECOND + 6.0, stone)
	_wall(s, "SecondLibraryNorth", "z", -50, -58, -18, Y_SECOND, Y_SECOND + 6.0, stone)
	_wall(s, "SecondLibrarySouth", "z", -30, -58, -18, Y_SECOND, Y_SECOND + 6.0, stone, [[-34.0, DOOR_W, 2.8]])
	_wall(s, "SecondLibraryEast", "x", -18, -50, -30, Y_SECOND, Y_SECOND + 6.0, stone)
	_wall(s, "SecondPierWest", "x", -14, -50, -30, Y_SECOND, Y_SECOND + 6.0, stone)
	_wall(s, "SecondClassroomEast", "x", 20, -50, -30, Y_SECOND, Y_SECOND + 6.0, stone)
	_wall(s, "SecondClassroomNorth", "z", -50, -14, 20, Y_SECOND, Y_SECOND + 6.0, stone)
	_wall(s, "SecondClassroomSouth", "z", -30, -14, 20, Y_SECOND, Y_SECOND + 6.0, stone, [[-4.0, DOOR_W, 2.8]])
	_wall(s, "SecondCorridorNorthPier", "z", -30, -18, -14, Y_SECOND, Y_SECOND + 6.0, stone)
	_wall(s, "SecondCorridorNorthEast", "z", -30, 20, 44, Y_SECOND, Y_SECOND + 6.0, stone)
	_wall(s, "SecondCorridorSouth", "z", -24, -58, -16, Y_SECOND, Y_SECOND + 6.0, stone)
	_wall(s, "SecondCorridorWestEnd", "x", -58, -30, -24, Y_SECOND, Y_SECOND + 6.0, stone)
	_wall(s, "SecondCorridorEnd", "x", 44, -30, -24, Y_SECOND, Y_SECOND + 6.0, stone)
	_wall(s, "SecondGalleryWestEnd", "x", -16, 26, 36, Y_SECOND, Y_SECOND + 6.0, stone)
	_slab(s, "SecondRoof", -64, 44, -50, -24, Y_SECOND + 6.0, stone)
	_rail(s, "BalconyWest", "x", -24, 12, 20, Y_SECOND)
	_rail(s, "BalconyNorth", "z", 12, -24, -16, Y_SECOND)
	_rail(s, "BalconySouth", "z", 20, -24, -16, Y_SECOND)
	_rail(s, "SecondWellWest", "x", -4, -16, 26, Y_SECOND)
	_rail(s, "SecondWellEast", "x", 36, -16, 26, Y_SECOND)
	_rail(s, "SecondWellNorth", "z", -16, -4, 36, Y_SECOND)
	_rail(s, "SecondWellSouth", "z", 26, -4, 36, Y_SECOND)
	_rail(s, "SecondStairWellWest", "x", 38.5, -4, 8, Y_SECOND)
	_rail(s, "SecondStairWellEast", "x", 43.5, -4, 8, Y_SECOND)
	_rail(s, "SecondStairWellSouth", "z", 8, 38.5, 43.5, Y_SECOND)

# =========================================================== basement

static func _build_basement(s: Node3D) -> void:
	var dark := _basement_mat()
	_slab(s, "BasementBayFloor", -52, -40, -24, -10, Y_BASEMENT, PBR.surface("stone_tiles_02", Color(0.7, 0.72, 0.78)))
	_slab(s, "BasementClassroomFloor", -58, -34, -10, 10, Y_BASEMENT, PBR.surface("stone_tiles_02", Color(0.7, 0.72, 0.78)))
	_wall(s, "BasementBayWest", "x", -52, -24, -10, Y_BASEMENT, Y_GROUND, dark)
	_wall(s, "BasementBayEast", "x", -40, -24, -10, Y_BASEMENT, Y_GROUND, dark)
	_wall(s, "BasementBayNorth", "z", -24, -52, -40, Y_BASEMENT, Y_GROUND, dark)
	_wall(s, "BasementDivider", "z", -10, -58, -34, Y_BASEMENT, Y_GROUND, dark, [[-46.0, 3.0, 2.8]])
	_wall(s, "BasementWest", "x", -58, -10, 10, Y_BASEMENT, Y_GROUND, dark)
	_wall(s, "BasementEast", "x", -34, -10, 10, Y_BASEMENT, Y_GROUND, dark)
	_wall(s, "BasementSouth", "z", 10, -58, -34, Y_BASEMENT, Y_GROUND, dark, [[-52.0, 3.0, 3.2]])
	_slab(s, "BasementCeiling", -58, -34, -24, 10, Y_GROUND, dark)
	# The future encounter entrance: a sealed arch, deliberately obvious.
	var seal := _mat(Color(0.13, 0.07, 0.20), false, 0.6)
	_wall(s, "EncounterSeal", "z", 10, -55.0, -49.0, Y_BASEMENT, Y_BASEMENT + 3.4, seal, [[-52.0, 3.0, 3.2]])
	var glow := _mat(Color(0.55, 0.2, 0.95), true, 0.4)
	_box(s, "EncounterSealGlow", Vector3(-52, Y_BASEMENT + 1.6, 10.15), Vector3(3.0, 3.2, 0.08), glow, false)
	_sign(s, "FUTURE ENCOUNTER\nSEALED - PHASE 8", Vector3(-52, Y_BASEMENT + 3.9, 10.4), 30, Color(0.85, 0.6, 1.0))
	_rail(s, "EncounterSealRailL", "x", -53.6, 8.6, 10.0, Y_BASEMENT)
	_rail(s, "EncounterSealRailR", "x", -50.4, 8.6, 10.0, Y_BASEMENT)

# =========================================================== staircases

static func _build_stairs(s: Node3D) -> void:
	# The conventional (fallback) route lives in the hall's EAST bay.
	_stairs(s, "StairGroundToFirst", "z", 41.0, 24.0, Y_GROUND, -1.0, 5.0)
	_stairs(s, "StairFirstToSecond", "z", 41.0, 8.0, Y_FIRST, -1.0, 5.0)
	_stairs(s, "StairGroundToBasement", "z", -46.0, -24.0, Y_GROUND, 1.0, 6.0,
		Y_GROUND - Y_BASEMENT, STAIR_RUN)
	_sign(s, "↑ FIRST FLOOR  •  CONVENTIONAL STAIRS", Vector3(41, Y_GROUND + 3.2, 25.6), 30, Color(1.0, 0.9, 0.6))
	_sign(s, "↑ SECOND FLOOR", Vector3(41, Y_FIRST + 3.2, 9.6), 30, Color(1.0, 0.9, 0.6))
	_sign(s, "↓ GROUND FLOOR", Vector3(41, Y_SECOND + 3.2, -4.6), 30, Color(1.0, 0.9, 0.6))
	_sign(s, "↓ DUNGEON LEVEL", Vector3(-46, Y_GROUND + 3.2, -22.6), 30, Color(0.8, 0.75, 1.0))

# =========================================================== tower

static func _build_tower(s: Node3D) -> void:
	var stone := _stone()
	var centre := Vector3(56, 0, 8)
	var radius := 7.0
	var segments := 16
	var open_from := 11   # segment index facing the bridge (-X)
	var open_to := 12
	for i in range(segments):
		if i == open_from or i == open_to:
			continue
		var a0 := TAU * float(i) / float(segments)
		var a1 := TAU * float(i + 1) / float(segments)
		var mid := (a0 + a1) * 0.5
		var chord := 2.0 * radius * sin((a1 - a0) * 0.5) + 0.25
		var node := Node3D.new()
		node.name = "TowerWall"
		node.position = centre + Vector3(sin(mid) * radius, 0, cos(mid) * radius)
		node.rotation.y = mid
		s.add_child(node)
		_box(node, "TowerWallSegment", Vector3(0, Y_SECOND + 3.0, 0), Vector3(0.6, 6.0 + (Y_SECOND - Y_GROUND), chord), stone)
		# Lancet openings up the tower shaft, so the tower reads as a tower from
		# inside the stair hall as well as from the bridge.
		if i % 4 == 1:
			_kit(s, "window_lancet_2x4",
				centre + Vector3(sin(mid) * (radius + 0.32), Y_SECOND + 2.6, cos(mid) * (radius + 0.32)),
				atan2(sin(mid), cos(mid)), Vector3(0.8, 0.8, 1.0))
	# tower landing floor + roof
	var disc := CylinderMesh.new()
	disc.top_radius = radius - 0.4
	disc.bottom_radius = radius - 0.4
	disc.height = SLAB
	var floor_node := _mesh(s, "TowerLandingFloor", disc, centre + Vector3(0, Y_SECOND - SLAB * 0.5, 0), _floor_mat())
	var body := StaticBody3D.new()
	var shape := CylinderShape3D.new()
	shape.radius = radius - 0.4
	shape.height = SLAB
	var collision := CollisionShape3D.new()
	collision.shape = shape
	body.add_child(collision)
	floor_node.add_child(body)
	# Slate cap: an octagonal Gothic roof instead of the Phase 8 cone.
	var cap := PBR.kit_instance("tower_cap_7")
	if cap != null:
		cap.position = centre + Vector3(0, Y_SECOND + 5.2, 0)
		cap.rotation.y = PI / 16.0
		s.add_child(cap)
	# bridge from the second-floor east gallery into the tower
	_slab(s, "TowerBridgeFloor", 44, 49.5, 4, 12, Y_SECOND, _floor_mat())
	_rail(s, "TowerBridgeRailN", "z", 4, 44, 49.5, Y_SECOND)
	_rail(s, "TowerBridgeRailS", "z", 12, 44, 49.5, Y_SECOND)
	_sign(s, "TOWER LANDING", Vector3(52, Y_SECOND + 3.4, 8), 32, Color(0.85, 0.92, 1.0))

# =========================================================== arches

## Dress every recorded wall opening with a pointed arch that fills its
## rectangle exactly, scaled to the opening the wall already has. Visual only:
## the collider is the wall's own gap.
static func _build_arches(s: Node3D) -> void:
	for o in _openings:
		var width: float = float(o["width"])
		var height: float = float(o["height"])
		if width < 1.6 or width > 9.0 or height < 2.2:
			continue
		var wide := width >= 4.2
		var module := "arch_arcade_6x5" if wide else "arch_pointed_2_4x3_4"
		var rect_w := 6.8 if wide else 2.4
		var rect_h := 5.4 if wide else 3.4
		var depth := 1.02 if wide else 0.41
		var node := PBR.kit_instance(module)
		if node == null:
			continue
		var y_centre: float = float(o["y0"]) + float(o["sill"]) + height * 0.5
		node.scale = Vector3(width / rect_w, height / rect_h, 1.0)
		if String(o["axis"]) == "x":
			node.rotation.y = PI * 0.5
			node.position = Vector3(float(o["fixed"]) - depth * 0.5, y_centre, float(o["centre"]))
		else:
			node.position = Vector3(float(o["centre"]), y_centre, float(o["fixed"]) - depth * 0.5)
		s.add_child(node)

## Clerestory lancets on the Great Hall's walls, above the route: the hall's
## verticality only reads if light enters high up. No collision (they sit at
## 12-18 m), so the walkable route is untouched.
static func _build_cloister_windows(s: Node3D) -> void:
	var y := Y_GROUND + 14.4
	for z in [-18.0, -12.0, -6.0, 0.0, 6.0]:
		_kit(s, "window_lancet_2x4", Vector3(-57.55, y, z), PI * 0.5)
		_kit(s, "window_lancet_2x4", Vector3(-16.45, y, z), -PI * 0.5)
	for x in [-52.0, -45.0, -38.0, -31.0, -24.0]:
		_kit(s, "window_lancet_2x4", Vector3(x, y, -23.55), 0.0)
		_kit(s, "window_lancet_2x4", Vector3(x, y, 19.55), PI)
	# The stair hall gets its own high lights so the galleries are not a cave.
	for z in [-16.0, 0.0, 16.0, 32.0]:
		_kit(s, "window_lancet_2x4", Vector3(43.55, Y_GROUND + 12.4, z), -PI * 0.5)

## Interior buttresses along the great walls and clustered columns in the Great
## Hall. Both carry real collision, placed clear of every walkthrough route leg.
static func _build_buttresses_and_columns(s: Node3D) -> void:
	for z in [-16.0, -8.0, 0.0, 8.0, 16.0]:
		var pos := Vector3(-57.35, Y_GROUND, z)
		_kit_instanced("buttress_1x6", pos, -PI * 0.5)
		_cyl_collider(s, "ButtressCollider", pos + Vector3(-0.1, 0, 0), 0.72, 6.0)
	for z in [-20.0, -12.0, -4.0, 4.0, 12.0, 20.0, 28.0]:
		var pos := Vector3(43.35, Y_GROUND, z)
		_kit_instanced("buttress_1x6", pos, PI * 0.5)
		_cyl_collider(s, "ButtressCollider", pos + Vector3(0.1, 0, 0), 0.72, 6.0)
	# Hall columns, on the west aisle line.
	for z in [-12.0, 0.0, 12.0]:
		_kit(s, "column_6", Vector3(-54.0, Y_GROUND, z))
		_cyl_collider(s, "ColumnCollider", Vector3(-54.0, Y_GROUND, z), 0.62, 6.0)
	# Gallery columns on the first floor, tucked against the same line.
	for z in [-12.0, 0.0, 12.0]:
		_kit(s, "column_6", Vector3(-54.0, Y_FIRST, z))
		_cyl_collider(s, "ColumnCollider", Vector3(-54.0, Y_FIRST, z), 0.62, 6.0)

# =========================================================== floor wear

## Sparse decals: moss at the wall bases and worn earth where routes converge.
## Alpha-scissored quads, no collision, laid 1 cm over the floor.
static func _build_floor_wear(s: Node3D) -> void:
	var moss := PBR.slot_material("moss")
	var dirt := PBR.slot_material("dirt")
	for spot in [
			[Vector3(-14.0, Y_GROUND + 0.02, 24.0), 6.0],
			[Vector3(-20.0, Y_GROUND + 0.02, -21.0), 5.0],
			[Vector3(-46.0, Y_GROUND + 0.02, 12.0), 4.0],
			[Vector3(41.0, Y_GROUND + 0.02, 20.0), 5.0],
			[Vector3(-46.0, Y_BASEMENT + 0.02, 4.0), 5.0],
		]:
		var quad := PlaneMesh.new()
		quad.size = Vector2(float(spot[1]), float(spot[1]))
		var decal := _mesh(s, "WearPatch", quad, spot[0], dirt)
		decal.rotation.y = float(int(spot[0].x) % 4) * 0.7
	for spot in [
			[Vector3(-57.5, Y_GROUND + 0.02, -6.0), 4.0],
			[Vector3(-16.6, Y_GROUND + 0.02, 4.0), 3.5],
			[Vector3(-24.0, Y_FIRST + 0.02, -32.0), 4.0],
			[Vector3(-50.0, Y_BASEMENT + 0.02, -18.0), 4.5],
			[Vector3(42.0, Y_SECOND + 0.02, 16.0), 3.0],
		]:
		var quad := PlaneMesh.new()
		quad.size = Vector2(float(spot[1]), float(spot[1]) * 0.6)
		var decal := _mesh(s, "MossPatch", quad, spot[0], moss)
		decal.rotation.y = float(int(spot[0].z) % 3) * 0.9

# =========================================================== furniture

## Long tables, benches and candles: the Great Hall reads as a hall at a glance.
## Collision stays exactly where the Phase 8 tables were.
static func _build_furniture_great_hall(s: Node3D) -> void:
	var house_colors := [Color(0.52, 0.06, 0.09), Color(0.09, 0.22, 0.44), Color(0.10, 0.30, 0.19), Color(0.78, 0.56, 0.11)]
	for i in range(4):
		var x: float = [-46.0, -40.0, -34.0, -28.0][i]
		for z in [-12.0, 6.0]:
			_table(s, Vector3(x, Y_GROUND, z), 14.0 if z < 0.0 else 16.0)
		var banner := PBR.kit_instance("banner_1_2x3", house_colors[i])
		if banner != null:
			banner.position = Vector3(x, Y_GROUND + 8.6, -23.55)
			s.add_child(banner)
	# head table on the dais at the north end
	_box(s, "Dais", Vector3(-37, Y_GROUND + 0.15, -20), Vector3(34, 0.3, 6), _trim_mat())
	_table(s, Vector3(-37, Y_GROUND + 0.3, -20), 6.0)
	_sign(s, "THE GREAT HALL", Vector3(-37, Y_GROUND + 12.5, -14), 52, Color(1.0, 0.88, 0.6))
	# suits of armour flanking the head table
	for x in [-52.0, -22.0]:
		_kit(s, "armour_stand_2", Vector3(x, Y_GROUND + 0.3, -20.5), 0.0)
	# floating candles (the world animates anything in this group with base_y)
	for i in range(16):
		var pos := Vector3(-52 + (i % 8) * 5.0, Y_GROUND + 7.6 + sin(float(i) * 2.1) * 0.4, -14 + float(i / 8) * 14.0)
		var wax := CylinderMesh.new()
		wax.top_radius = 0.05
		wax.bottom_radius = 0.05
		wax.height = 0.45
		var candle := _mesh(s, "FloatingCandle", wax, pos, PBR.slot_material("wax"))
		candle.set_meta("base_y", pos.y)
		candle.set_meta("phase", float(i))
		candle.add_to_group("floating_candles")

## A trestle table with benches and candles; collision matches Phase 8.
static func _table(parent: Node3D, pos: Vector3, length: float, width: float = 1.7) -> void:
	_collider(parent, "TableBody", pos + Vector3(0, 1.0, 0), Vector3(width, 0.2, length))
	var table := PBR.kit_instance("long_table_8")
	if table != null:
		table.position = pos
		table.rotation.y = PI * 0.5
		table.scale = Vector3(length / 7.6, 1.0, width / 1.62)
		parent.add_child(table)
	for side in [-1, 1]:
		_collider(parent, "BenchBody", pos + Vector3(side * (width * 0.5 + 0.5), 0.55, 0),
			Vector3(0.5, 0.15, length))
		var bench := PBR.kit_instance("bench_4")
		if bench != null:
			bench.position = pos + Vector3(side * (width * 0.5 + 0.5), 0, 0)
			bench.rotation.y = PI * 0.5
			bench.scale = Vector3(length / 3.8, 1.0, 1.0)
			parent.add_child(bench)
	for i in range(2):
		_kit_instanced("candle_cluster", pos + Vector3(0.0, 0.82, -length * 0.25 + length * 0.5 * float(i)))

static func _build_furniture_library(s: Node3D) -> void:
	var colors := [Color(0.45, 0.12, 0.12), Color(0.15, 0.3, 0.5), Color(0.2, 0.4, 0.22), Color(0.55, 0.42, 0.15)]
	for row in range(6):
		for side in [-1.0, 1.0]:
			var x: float = -54.0 + row * 6.0
			var z: float = -46.0 if side < 0 else -48.6
			_collider(s, "BookcaseBody", Vector3(x, Y_FIRST + 1.9, z), Vector3(4.6, 3.8, 1.0))
			_kit(s, "bookshelf_4x3", Vector3(x, Y_FIRST, z), 0.0 if side < 0 else PI)
	# ladders leaning on the end cases, and two reading tables with benches
	_kit(s, "ladder_3", Vector3(-56.6, Y_FIRST, -44.0), 0.0, Vector3(1.0, 1.0, 1.0))
	_kit(s, "ladder_3", Vector3(-21.0, Y_FIRST, -49.0), PI * 0.5)
	for i in range(3):
		_table(s, Vector3(-52.0 + i * 9.0, Y_FIRST, -36.0), 5.0, 2.2)
	_kit(s, "lectern_1", Vector3(-26.0, Y_FIRST, -32.0), PI * 0.25)
	_kit(s, "candelabra_1_6", Vector3(-44.0, Y_FIRST, -34.0))
	_kit(s, "candelabra_1_6", Vector3(-58.0 + 2.0, Y_FIRST, -40.0))
	_sign(s, "LIBRARY", Vector3(-38, Y_FIRST + 4.4, -30.4), 42, Color(1.0, 0.86, 0.6))
	_sign(s, "READING ROOM - KEEP QUIET", Vector3(-38, Y_FIRST + 3.4, -33.6), 24, Color(0.9, 0.85, 0.7))
	# The third shelf bay doubles as a study corner on the second floor.
	for i in range(3):
		_table(s, Vector3(-50.0 + i * 10.0, Y_SECOND, -38.0), 6.0, 2.4)

static func _build_furniture_classrooms(s: Node3D) -> void:
	for i in range(6):
		for j in range(3):
			_desk(s, Vector3(-10.0 + i * 5.0, Y_FIRST, -46.0 + j * 5.5), "Desk")
	_blackboard(s, Vector3(-4, Y_FIRST + 2.4, -49.4), "Blackboard")
	_kit(s, "lectern_1", Vector3(-4, Y_FIRST, -47.0), PI)
	_sign(s, "CLASSROOM", Vector3(-4, Y_FIRST + 4.4, -31.6), 42, Color(1.0, 0.86, 0.6))
	for i in range(6):
		for j in range(3):
			_desk(s, Vector3(-10.0 + i * 5.0, Y_SECOND, -46.0 + j * 5.5), "UpperDesk")
	_blackboard(s, Vector3(-4, Y_SECOND + 2.4, -49.4), "UpperBlackboard")
	_sign(s, "UPPER CLASSROOM", Vector3(-4, Y_SECOND + 4.4, -31.6), 42, Color(1.0, 0.86, 0.6))
	# west upper room doubles as a study hall
	_kit(s, "lectern_1", Vector3(-38, Y_SECOND, -40.0), PI)
	_kit(s, "candelabra_1_6", Vector3(-50.0, Y_SECOND, -32.0))
	_sign(s, "UPPER STUDY", Vector3(-38, Y_SECOND + 4.4, -31.6), 42, Color(1.0, 0.86, 0.6))

## A desk with its stool; collision matches the Phase 8 desk.
static func _desk(parent: Node3D, pos: Vector3, title: String) -> void:
	_collider(parent, title + "Body", pos + Vector3(0, 0.85, 0), Vector3(1.6, 0.12, 1.2))
	_kit_instanced("desk_1_6", pos)

static func _blackboard(parent: Node3D, pos: Vector3, title: String) -> void:
	_box(parent, title, pos, Vector3(9, 3, 0.2), _mat(Color(0.05, 0.14, 0.13), false, 0.7), false)
	_kit(parent, "trim_band_4", pos + Vector3(0, 1.62, 0.06), 0.0, Vector3(2.2, 1.0, 1.0))
	_kit(parent, "trim_band_4", pos + Vector3(0, -1.58, 0.06), 0.0, Vector3(2.2, 1.0, 1.0))

## Circulation dressing: stair hall, galleries, corridors, tower.
static func _build_furniture_circulation(s: Node3D) -> void:
	# Suits of armour and candelabra at the grand staircase foot.
	_kit(s, "armour_stand_2", Vector3(-13.6, Y_GROUND, 20.0), 0.0)
	_kit(s, "armour_stand_2", Vector3(41.6, Y_GROUND, 20.0), PI)
	_kit(s, "candelabra_1_6", Vector3(-10.0, Y_GROUND, 10.0))
	_kit(s, "candelabra_1_6", Vector3(30.0, Y_GROUND, 30.0))
	for y in [Y_FIRST, Y_SECOND]:
		_kit(s, "candelabra_1_6", Vector3(-10.0, y, 10.0))
		_kit(s, "candelabra_1_6", Vector3(30.0, y, 30.0))
		_kit(s, "armour_stand_2", Vector3(42.6, y, -20.5), PI * 0.5)
	# Portraits along the corridor north wall, one per bay.
	for i in range(5):
		_kit(s, "portrait_1x1_5", Vector3(-52.0 + i * 14.0, Y_GROUND + 3.2, -29.55), 0.0)
	for i in range(4):
		_kit(s, "portrait_1x1_5", Vector3(-48.0 + i * 16.0, Y_FIRST + 3.2, -29.55), 0.0)
	for i in range(2):
		_kit(s, "portrait_1x1_5", Vector3(-40.0 + i * 20.0, Y_SECOND + 3.2, -29.55), 0.0)
	# The reachable tower: dressed as a lookout (plan.md: one tower is enterable).
	_kit(s, "candelabra_1_6", Vector3(56.0, Y_SECOND, 4.5))
	_kit(s, "armour_stand_2", Vector3(59.5, Y_SECOND, 11.0), PI)
	_kit(s, "portrait_1x1_5", Vector3(50.5, Y_SECOND + 3.0, 13.6), PI)
	_kit(s, "banner_1_2x3", Vector3(61.0, Y_SECOND + 2.0, 8.0), PI * 0.5, Vector3.ONE, Color(0.18, 0.24, 0.5))
	_kit(s, "plaque_0_8x0_5", Vector3(52.0, Y_SECOND + 1.4, 14.2), PI)

static func _build_furniture_basement(s: Node3D) -> void:
	for i in range(5):
		_box(s, "Crate", Vector3(-56 + (i % 3) * 2.0, Y_BASEMENT + 0.6, -6 + float(i) * 1.6),
			Vector3(1.4, 1.2, 1.4), _wood())
	for i in range(4):
		_desk(s, Vector3(-50.0 + i * 4.5, Y_BASEMENT, -6.0), "DungeonDesk")
	_sign(s, "DUNGEON CLASSROOM", Vector3(-46, Y_BASEMENT + 3.6, -10.6), 34, Color(0.85, 0.8, 0.95))
	_box(s, "Cauldron", Vector3(-36, Y_BASEMENT + 0.6, 4), Vector3(1.6, 1.2, 1.6), _mat(Color(0.12, 0.12, 0.14)))
	# The dungeon's own story: a collapsed bay and a broken column, clear of
	# every route leg.
	_kit_instanced("rubble_pile_1", Vector3(-56.0, Y_BASEMENT, -6.0), 0.6)
	_kit_instanced("rubble_pile_1", Vector3(-37.5, Y_BASEMENT, 4.0), 2.1)
	_kit_instanced("rubble_pile_1", Vector3(-55.0, Y_BASEMENT, -20.0), 3.4)
	_kit(s, "column_broken_2_2", Vector3(-56.4, Y_BASEMENT, 2.0))
	_cyl_collider(s, "BrokenColumnCollider", Vector3(-56.4, Y_BASEMENT, 2.0), 0.55, 1.7)
	_kit(s, "column_broken_2_2", Vector3(-34.8, Y_BASEMENT, -18.0))
	_kit(s, "wall_module_4x6_damaged", Vector3(-58.0 + 0.2, Y_BASEMENT, -13.0), PI * 0.5)

# =========================================================== signage and light

static func _sign(parent: Node3D, text: String, pos: Vector3, size: int, color: Color) -> void:
	var label := Label3D.new()
	label.text = text
	label.font_size = size
	label.modulate = color
	label.outline_size = 6
	label.outline_modulate = Color(0, 0, 0)
	label.billboard = BaseMaterial3D.BILLBOARD_ENABLED
	label.no_depth_test = false
	label.position = pos
	parent.add_child(label)

## A wall torch: iron bracket, wax stub, emissive flame and a warm, local,
## non-shadow-casting light. Phase 10 keeps shadow-casting dynamic lights to
## zero inside; contrast comes from the fixtures plus the baked occlusion.
static func _torch(parent: Node3D, pos: Vector3) -> void:
	var t := Node3D.new()
	t.position = pos
	parent.add_child(t)
	var pole := CylinderMesh.new()
	pole.top_radius = 0.06
	pole.bottom_radius = 0.08
	pole.height = 1.4
	_mesh(t, "TorchPole", pole, Vector3(0, 0.7, 0), PBR.slot_material("iron"))
	var flame := SphereMesh.new()
	flame.radius = 0.085
	flame.height = 0.22
	var node := _mesh(t, "TorchFlame", flame, Vector3(0, 1.46, 0), PBR.slot_material("flame"))
	node.add_to_group("torch_flames")
	var light := OmniLight3D.new()
	light.light_color = Color(1.0, 0.68, 0.32)
	light.light_energy = 1.25
	light.omni_range = 9.0
	light.omni_attenuation = 1.4
	light.shadow_enabled = false
	light.position = Vector3(0, 1.6, 0)
	light.add_to_group("torch_lights")
	t.add_child(light)

static func _build_signs(s: Node3D) -> void:
	_sign(s, "ENTRANCE VESTIBULE", Vector3(0, Y_GROUND + 3.6, 27.5), 34, Color(1.0, 0.9, 0.65))
	_sign(s, "↑ GREAT HALL   •   ↑ GRAND STAIRCASE", Vector3(0, Y_GROUND + 2.6, 25.4), 24, Color(1.0, 0.9, 0.65))
	_sign(s, "TO THE GROUNDS", Vector3(0, Y_GROUND + 3.9, 37.4), 28, Color(0.8, 0.9, 1.0))
	_sign(s, "GRAND STAIRCASE HALL", Vector3(14, Y_GROUND + 5.4, 18), 40, Color(1.0, 0.9, 0.6))
	_sign(s, "GROUND FLOOR", Vector3(-15.4, Y_GROUND + 3.6, 6), 34, Color(0.95, 0.9, 0.8))
	_sign(s, "FIRST FLOOR", Vector3(-15.4, Y_FIRST + 3.6, 6), 34, Color(0.95, 0.9, 0.8))
	_sign(s, "SECOND FLOOR", Vector3(-15.4, Y_SECOND + 3.6, 6), 34, Color(0.95, 0.9, 0.8))
	_sign(s, "↑ FIRST FLOOR  •  LIBRARY / CLASSROOM", Vector3(-20, Y_GROUND + 3.0, -24.4), 28, Color(1.0, 0.9, 0.65))
	_sign(s, "SIDE CORRIDOR  •  GREAT HALL  •  DUNGEON ↓", Vector3(-60, Y_GROUND + 3.0, -27), 26, Color(1.0, 0.9, 0.65))
	_sign(s, "GALLERY - OVERLOOKS THE GRAND STAIRCASE", Vector3(20, Y_FIRST + 3.4, -19), 26, Color(0.95, 0.9, 0.8))
	_sign(s, "↑ SECOND FLOOR  •  UPPER CLASSROOMS  •  TOWER", Vector3(-20, Y_FIRST + 3.0, -24.4), 28, Color(1.0, 0.9, 0.65))
	_sign(s, "FIRST FLOOR CORRIDOR", Vector3(-40, Y_FIRST + 3.0, -27), 28, Color(1.0, 0.9, 0.65))
	_sign(s, "SECOND FLOOR CORRIDOR", Vector3(-40, Y_SECOND + 3.0, -27), 28, Color(1.0, 0.9, 0.65))

static func _build_lights(s: Node3D) -> void:
	# Vestibule and hall mouths.
	for pos in [Vector3(0, Y_GROUND + 3.0, 33.0), Vector3(0, Y_GROUND + 3.0, 22.0),
			Vector3(-12, Y_GROUND + 3.2, 23.0), Vector3(12, Y_GROUND + 3.2, 23.0)]:
		_torch(s, pos)
	# Great Hall: warm fixtures down both walls; the candles carry the rest.
	for x in [-50.0, -37.0, -24.0]:
		for z in [-16.0, 0.0, 16.0]:
			_torch(s, Vector3(x, Y_GROUND + 3.0, z))
	# The arcade wall gets its own row so the hall's far half is not a cave.
	for z in [-16.0, -8.0, 0.0, 8.0, 16.0]:
		_torch(s, Vector3(-20.0, Y_GROUND + 3.0, z))
	# Stair hall, one per gallery bay and level.
	for y in [Y_GROUND, Y_FIRST, Y_SECOND]:
		_torch(s, Vector3(-14, y + 2.6, -20))
		_torch(s, Vector3(40, y + 2.6, -20))
		_torch(s, Vector3(40, y + 2.6, 30))
	# Corridors.
	for x in [-56.0, -40.0, -24.0, 20.0, 36.0]:
		_torch(s, Vector3(x, Y_GROUND + 2.6, -27))
		_torch(s, Vector3(x, Y_FIRST + 2.6, -27))
		_torch(s, Vector3(x, Y_SECOND + 2.6, -27))
	for z in [-20.0, -4.0, 12.0]:
		_torch(s, Vector3(-61, Y_GROUND + 2.6, z))
	# Library, classrooms, tower, dungeon.
	_torch(s, Vector3(-38, Y_FIRST + 2.6, -40))
	_torch(s, Vector3(-4, Y_FIRST + 2.6, -40))
	_torch(s, Vector3(-38, Y_SECOND + 2.6, -40))
	_torch(s, Vector3(-4, Y_SECOND + 2.6, -40))
	_torch(s, Vector3(52, Y_SECOND + 2.6, 8))
	_torch(s, Vector3(-46, Y_BASEMENT + 2.6, -14))
	_torch(s, Vector3(-46, Y_BASEMENT + 2.6, 2))
