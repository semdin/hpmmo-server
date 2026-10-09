extends RefCounted

## Art pass outdoor pass: shaped terrain, path edges, clearings, vegetation,
## landmarks and readable safe-zone boundaries.
##
## The flat playable core is preserved exactly: every encounter area, the
## courtyard, the paths, the broom landing pad and the castle entrance
## sightline stay on the y = 0 plane with the map transfer collider. The shaping
## happens in a ring outside the core, meshed from one height function and
## collided by a matching HeightMapShape3D sampled from the same field, so the
## walkable surface and the visible surface are the same surface.
##
## Vegetation is drawn as MultiMesh instances from the Gothic kit (two tree
## species, bushes, grass clumps, three rocks) with visibility ranges, and the
## density follows the quality preset. Nothing here carries gameplay logic.

const PBR = preload("res://scripts/assets/pbr_kit.gd")
const QUALITY = preload("res://scripts/world/quality_preset.gd")

## The flat core: all gameplay (encounters, courtyard, castle, village, lake,
## quidditch pitch, boss arenas) lives between these bounds.
const CORE_MIN := Vector2(-110.0, -125.0)
const CORE_MAX := Vector2(110.0, 70.0)
const WORLD_LIMIT := 495.0
## Outdoor stones are weathered grey, not the pale interior ashlar.
const ROCK_TINT := Color(0.60, 0.58, 0.54)
const GRID := 4.0          # visual mesh resolution, metres
const COLL_GRID := 1.0     # collision heightfield resolution, metres
const EDGE_FADE := 6.0     # metres of flat apron before the hills start
const EDGE_RUN := 55.0     # metres over which the hills rise
## Shared lake datum: single source of truth for water surface, basin floor and
## swim bounds. WorldBuilder, Player and the kill-plane all read these.
const LAKE_CENTER := Vector3(-220.0, -7.0, 185.0)
const LAKE_SIZE := Vector2(170.0, 150.0)
const LAKE_BED_Y := -13.5
## Terrain height at the waterline (just under the surface so the shore reads as a wet edge).
const LAKE_SHORE_Y := -7.4
const LAKE_SHELF := 14.0   # metres from the waterline down to the flat bed
## Land under the boathouse, stair flight and pier root: [cx, cz, half_x, half_z, feather].
const DOCK_LAND := [-156.5, 146.0, 21.5, 24.0, 10.0]
const MEADOW_TOP_Y := -0.05


static func build(world: Node3D) -> void:
	if world.has_node("TerrainPass"):
		return
	var root := Node3D.new()
	root.name = "TerrainPass"
	world.add_child(root)
	_build_hill_bands(root)
	_build_path_curbs(root, world)
	_build_clearings(root)
	_build_vegetation(root)
	_build_rocks(root)
	_build_safe_zone_marks(root)
	_build_waystones(root)

# ------------------------------------------------------------------ height

static func _make_noise(seed_value: int, frequency: float) -> FastNoiseLite:
	var noise := FastNoiseLite.new()
	noise.seed = seed_value
	noise.frequency = frequency
	noise.fractal_octaves = 3
	noise.fractal_gain = 0.5
	noise.noise_type = FastNoiseLite.TYPE_SIMPLEX_SMOOTH
	return noise

static var _hills: FastNoiseLite = null
static var _detail: FastNoiseLite = null

## The height above the flat plane at (x, z). Zero everywhere inside the core,
## blending to rolling hills in the ring. One function feeds both the mesh and
## the collision.
## Gameplay plateaus are carved here so houses never sit inside procedural
## hills: Hogsmeade terraces, the pitch, Hagrid's hollow, the smuggler camp and
## the forest hollows each get a flat, known height. WorldBuilder snaps every
## hut/tent/tower to ground_y() so even future noise tweaks cannot bury them.
static func _height(x: float, z: float) -> float:
	if _hills == null:
		_hills = _make_noise(90210, 0.0085)
		_detail = _make_noise(1017, 0.028)
	var dx: float = maxf(0.0, maxf(CORE_MIN.x - x, x - CORE_MAX.x))
	var dz: float = maxf(0.0, maxf(CORE_MIN.y - z, z - CORE_MAX.y))
	var distance: float = sqrt(dx * dx + dz * dz)
	var fade: float = clampf((distance - EDGE_FADE) / EDGE_RUN, 0.0, 1.0)
	fade = fade * fade * (3.0 - 2.0 * fade)
	var h: float = (7.0 + 11.0 * _hills.get_noise_2d(x, z)) * fade
	h += (2.0 * _detail.get_noise_2d(x, z)) * fade
	# A ridge line lifts the far corners so the valley reads as enclosed.
	var rim: float = clampf((maxf(absf(x), absf(z)) - 410.0) / 75.0, 0.0, 1.0)
	h += rim * rim * 12.0

	# Flat gameplay plateaus: [cx, cz, radius, target_y, feather].
	# Feather blends back to hills so there is no cliff seam.
	var plateaus := [
		[35.0, 20.0, 30.0, 0.0, 18.0],     # Hogsmeade west gate / plaza
		[75.0, 30.0, 42.0, 0.0, 20.0],     # Hogsmeade lower town (was buried at -1.2)
		[160.0, 35.0, 55.0, 5.0, 25.0],    # Hogsmeade upper terraces (was floating)
		[280.0, 20.0, 58.0, 0.0, 22.0],    # Quidditch stadium
		[350.0, -70.0, 30.0, 6.0, 18.0],   # Highlands stone circle overlook (clear of pitch)
		[180.0, -160.0, 30.0, 0.5, 20.0],  # Smuggler's ridge camp
		[-120.0, 118.0, 40.0, -4.5, 22.0], # Hagrid's hollow
		[-180.0, -140.0, 32.0, 0.0, 20.0], # Spider hollow clearing
		[-240.0, -200.0, 32.0, 0.0, 20.0], # Cursed crypt clearing
	]
	for p in plateaus:
		var pdx := x - float(p[0])
		var pdz := z - float(p[1])
		var pdist := sqrt(pdx * pdx + pdz * pdz)
		var pr: float = float(p[2])
		if pdist < pr + float(p[4]):
			var inner := clampf(1.0 - (pdist - pr) / float(p[4]), 0.0, 1.0)
			inner = inner * inner * (3.0 - 2.0 * inner)
			var core := clampf(1.0 - pdist / pr, 0.0, 1.0)
			core = core * core * (3.0 - 2.0 * core)
			var blend := maxf(inner * 0.65 + core * 0.35, core)
			h = lerpf(h, float(p[3]), blend)

	# Black Lake basin carved from the SAME rectangle as the water surface and
	# its collider: signed distance to the rect (negative inside). The bank
	# ramps from the surrounding ground down to the waterline, then a shelf
	# drops to the flat bed.
	var l_qx := absf(x - LAKE_CENTER.x) - LAKE_SIZE.x * 0.5
	var l_qz := absf(z - LAKE_CENTER.z) - LAKE_SIZE.y * 0.5
	var l_d := Vector2(maxf(l_qx, 0.0), maxf(l_qz, 0.0)).length() + minf(maxf(l_qx, l_qz), 0.0)
	var ramp := clampf(absf(h - LAKE_SHORE_Y) * 2.4, 10.0, 40.0)
	if l_d > 0.0:
		if l_d < ramp:
			var bw := clampf(1.0 - l_d / ramp, 0.0, 1.0)
			bw = bw * bw * (3.0 - 2.0 * bw)
			h = lerpf(h, LAKE_SHORE_Y, bw)
	else:
		var st := clampf(-l_d / LAKE_SHELF, 0.0, 1.0)
		st = st * st * (3.0 - 2.0 * st)
		h = lerpf(LAKE_SHORE_Y, LAKE_BED_Y, st)
	# Dock peninsula: the stair flight descends from the -4.5m ridge at x=-138
	# to the -7.0m boathouse floor at x=-162; the ground follows it just below.
	var d_qx := absf(x - float(DOCK_LAND[0])) - float(DOCK_LAND[2])
	var d_qz := absf(z - float(DOCK_LAND[1])) - float(DOCK_LAND[3])
	var d_out := Vector2(maxf(d_qx, 0.0), maxf(d_qz, 0.0)).length()
	var d_feather: float = float(DOCK_LAND[4])
	if d_out < d_feather:
		var dm := clampf(1.0 - d_out / d_feather, 0.0, 1.0)
		dm = dm * dm * (3.0 - 2.0 * dm)
		var slope_t := clampf((-138.0 - x) / 24.0, 0.0, 1.0)
		h = lerpf(h, lerpf(-4.6, -7.1, slope_t), dm)

	return clampf(h, -14.0, 30.0)

## Walkable ground height for gameplay placement. Inside the flat meadow slabs
## this is the slab top; outside it is the hill/plateau height. Always use this
## (never a hardcoded Y) when placing huts, tents, bridges, lamps or paths.
static func ground_y(x: float, z: float) -> float:
	# Meadow slabs sit at MEADOW_TOP_Y across the core and the east/south
	# aprons; the hill bands add _height() on top outside the core.
	var base := _height(x, z)
	# Inside the fully flat core the authored slabs are the ground.
	if x > CORE_MIN.x and x < CORE_MAX.x and z > CORE_MIN.y and z < CORE_MAX.y:
		return maxf(base, MEADOW_TOP_Y)
	# Village/pitch aprons are also slab-covered at MEADOW_TOP_Y where the
	# plateau target is ~0; where plateaus lift the ground (upper terraces,
	# highlands) the hill height wins.
	if base < 0.2 and base > -1.0:
		return maxf(base, MEADOW_TOP_Y)
	return base

static func is_in_lake(x: float, z: float, margin: float = 0.0) -> bool:
	return absf(x - LAKE_CENTER.x) <= LAKE_SIZE.x * 0.5 + margin \
		and absf(z - LAKE_CENTER.z) <= LAKE_SIZE.y * 0.5 + margin

## Bands that make up the ring around the core.
static func _bands() -> Array:
	return [
		# [x0, z0, x1, z1]
		[-WORLD_LIMIT, -WORLD_LIMIT, WORLD_LIMIT, CORE_MIN.y],
		[-WORLD_LIMIT, CORE_MAX.y, WORLD_LIMIT, WORLD_LIMIT],
		[-WORLD_LIMIT, CORE_MIN.y, CORE_MIN.x, CORE_MAX.y],
		[CORE_MAX.x, CORE_MIN.y, WORLD_LIMIT, CORE_MAX.y],
	]

static func _build_hill_bands(root: Node3D) -> void:
	var material: Material = PBR.surface("grass_ground_01", PBR.MEADOW_TINT,
		{"rough_min": 0.88})
	for band in _bands():
		var x0: float = band[0]
		var z0: float = band[1]
		var x1: float = band[2]
		var z1: float = band[3]
		var cols := int(ceil((x1 - x0) / GRID)) + 1
		var rows := int(ceil((z1 - z0) / GRID)) + 1
		var cx := (x1 - x0) / float(cols - 1)
		var cz := (z1 - z0) / float(rows - 1)
		# Height field (shared by mesh and collision through bilinear sampling).
		var field := PackedFloat32Array()
		field.resize(cols * rows)
		for j in range(rows):
			for i in range(cols):
				field[j * cols + i] = _height(x0 + i * cx, z0 + j * cz)
		_add_band_mesh(root, x0, z0, cx, cz, cols, rows, field, material)
		_add_band_collision(root, x0, z0, x1, z1, cols, rows, field)

static func _sample_field(field: PackedFloat32Array, cols: int, rows: int,
		x0: float, z0: float, cx: float, cz: float, x: float, z: float) -> float:
	var fx: float = clampf((x - x0) / cx, 0.0, float(cols - 1) - 0.001)
	var fz: float = clampf((z - z0) / cz, 0.0, float(rows - 1) - 0.001)
	var i := int(fx)
	var j := int(fz)
	var tx := fx - float(i)
	var tz := fz - float(j)
	var h00 := field[j * cols + i]
	var h10 := field[j * cols + i + 1]
	var h01 := field[(j + 1) * cols + i]
	var h11 := field[(j + 1) * cols + i + 1]
	return lerpf(lerpf(h00, h10, tx), lerpf(h01, h11, tx), tz)

static func _add_band_mesh(root: Node3D, x0: float, z0: float, cx: float, cz: float,
		cols: int, rows: int, field: PackedFloat32Array, material: Material) -> void:
	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)
	for j in range(rows - 1):
		for i in range(cols - 1):
			var xa := x0 + i * cx
			var xb := x0 + (i + 1) * cx
			var za := z0 + j * cz
			var zb := z0 + (j + 1) * cz
			var ha := field[j * cols + i]
			var hb := field[j * cols + i + 1]
			var hc := field[(j + 1) * cols + i + 1]
			var hd := field[(j + 1) * cols + i]
			var a := Vector3(xa, ha, za)
			var b := Vector3(xb, hb, za)
			var c := Vector3(xb, hc, zb)
			var d := Vector3(xa, hd, zb)
			for tri in [[a, b, c], [a, c, d]]:
				for v in tri:
					st.set_uv(Vector2(v.x * 0.25, v.z * 0.25))
					st.add_vertex(v)
	st.generate_normals()
	var mesh := st.commit()
	var node := MeshInstance3D.new()
	node.name = "HillBand"
	node.mesh = mesh
	node.material_override = material
	root.add_child(node)

static func _add_band_collision(root: Node3D, x0: float, z0: float, x1: float, z1: float,
		cols: int, rows: int, field: PackedFloat32Array) -> void:
	var cx := (x1 - x0) / float(cols - 1)
	var cz := (z1 - z0) / float(rows - 1)
	var map_cols := int(round((x1 - x0) / COLL_GRID)) + 1
	var map_rows := int(round((z1 - z0) / COLL_GRID)) + 1
	var heights := PackedFloat32Array()
	heights.resize(map_cols * map_rows)
	for j in range(map_rows):
		for i in range(map_cols):
			heights[j * map_cols + i] = _sample_field(field, cols, rows, x0, z0, cx, cz,
				x0 + i * COLL_GRID, z0 + j * COLL_GRID)
	var shape := HeightMapShape3D.new()
	shape.map_width = map_cols
	shape.map_depth = map_rows
	shape.map_data = heights
	var body := StaticBody3D.new()
	body.name = "HillCollision"
	body.collision_layer = 1
	body.collision_mask = 0
	var collision := CollisionShape3D.new()
	collision.shape = shape
	body.add_child(collision)
	body.position = Vector3(x0 + (map_cols - 1) * COLL_GRID * 0.5, 0.0,
		z0 + (map_rows - 1) * COLL_GRID * 0.5)
	root.add_child(body)

# ------------------------------------------------------------------ paths

## Curb stones along every cobble path edge: the path reads as a made thing
## rather than a painted stripe on grass.
static func _build_path_curbs(root: Node3D, world: Node3D) -> void:
	var paths := world.get_node_or_null("StonePaths")
	if paths == null:
		return
	for path_node in paths.get_children():
		if not (path_node is MeshInstance3D):
			continue
		var path: MeshInstance3D = path_node
		if not (path.mesh is PlaneMesh):
			continue
		var plane: PlaneMesh = path.mesh
		var length: float = plane.size.y
		var width: float = plane.size.x
		var basis: Basis = path.global_transform.basis
		var along: Vector3 = basis * Vector3(0, 0, 1)
		var lateral: Vector3 = basis * Vector3(1, 0, 0)
		var count := int(length / 1.6)
		for i in range(count):
			var t := (float(i) + 0.5) / float(count) - 0.5
			for side in [-1.0, 1.0]:
				var pos: Vector3 = path.global_position + along * (length * t) \
					+ lateral * (side * (width * 0.5 + 0.25))
				pos.y = ground_y(pos.x, pos.z) - 0.02
				var scale := 0.28 + float((i * 7 + int(side) * 3) % 5) * 0.03
				PBR.queue("rock_02", _xform(pos + Vector3(0, -0.08, 0),
					float((i * 37) % 6) * 0.5, Vector3.ONE * scale), ROCK_TINT)

# ------------------------------------------------------------------ clearings

## One readable clearing per encounter region: trampled ground, a broken rock
## ring outside the spawn rect, and a landmark stone. Nothing collides inside a
## spawn rect, and nothing is placed on a path.
static func _build_clearings(root: Node3D) -> void:
	var regions := _regions()
	for region in regions:
		var centre := Vector2(float(region["center"][0]), float(region["center"][1]))
		var radius := float(region["radius"])
		# Encounter regions only: the courtyard and castle hubs already carry
		# paving and forecourt surfaces of their own.
		if radius < 12.0 or radius > 34.0:
			continue
		var decal := MeshInstance3D.new()
		var quad := PlaneMesh.new()
		quad.size = Vector2(radius * 1.7, radius * 1.4)
		decal.mesh = quad
		decal.material_override = PBR.slot_material("dirt")
		decal.position = Vector3(centre.x, ground_y(centre.x, centre.y) + 0.06, centre.y)
		decal.rotation.y = float(int(absf(centre.x)) % 5) * 0.6
		root.add_child(decal)
		var rng := RandomNumberGenerator.new()
		rng.seed = int(absf(centre.x) * 13.0 + absf(centre.y) * 7.0)
		for i in range(7):
			var angle := TAU * float(i) / 7.0 + rng.randf() * 0.3
			var dist := radius * (0.92 + rng.randf() * 0.25)
			var rx := centre.x + cos(angle) * dist
			var rz := centre.y + sin(angle) * dist
			var pos := Vector3(rx, ground_y(rx, rz) - 0.1, rz)
			PBR.queue("rock_0%d" % (1 + i % 3), _xform(pos, rng.randf() * TAU,
				Vector3.ONE * rng.randf_range(0.7, 1.3)), ROCK_TINT)
		# A landmark stone at the far edge: findable from a distance.
		var lmx := centre.x
		var lmz := centre.y - radius - 4.0
		var lm := Vector3(lmx, ground_y(lmx, lmz) - 0.1, lmz)
		PBR.queue("rock_01", _xform(lm, 0.4, Vector3(2.0, 1.6, 2.0)), ROCK_TINT)

static func _regions() -> Array:
	# HPRules is a static content class (addons/hpmmo_sim/rules.gd).
	var tables: Dictionary = HPRules.spawn_tables()
	return tables.get("regions", [])

# ------------------------------------------------------------------ vegetation

static func _xform(pos: Vector3, rot_y: float, scale: Vector3) -> Transform3D:
	return Transform3D(Basis.from_euler(Vector3(0.0, rot_y, 0.0)) * Basis.from_scale(scale), pos)

## Everything scatter must avoid: castle footprint, village, lake, pitch,
## courtyard, landing pad and a margin around every path.
static func _blocked(x: float, z: float, margin: float = 2.0) -> bool:
	var p := Vector2(x, z)
	if p.distance_to(Vector2(0.0, 5.0)) < 21.0 + margin:      # courtyard
		return true
	if absf(x) < 46.0 + margin and z < -42.0 + margin:        # castle + approach
		return true
	if Vector2(35.0, 20.0).distance_to(p) < 22.0 + margin:    # Hogsmeade west gate
		return true
	if Vector2(110.0, 50.0).distance_to(p) < 62.0 + margin:   # Hogsmeade village & terraces
		return true
	if is_in_lake(x, z, 40.0 + margin): # Black Lake basin, banks & docks
		return true
	if Vector2(280.0, 20.0).distance_to(p) < 55.0 + margin:   # Quidditch stadium
		return true
	if Vector2(0.0, -40.0).distance_to(p) < 7.0 + margin:     # broom landing
		return true
	if Vector2(-118.0, 102.0).distance_to(p) < 38.0 + margin:   # Hagrid's hut & pumpkin patch
		return true
	if Vector2(350.0, -70.0).distance_to(p) < 32.0 + margin:    # Highlands stone circle
		return true
	if Vector2(180.0, -160.0).distance_to(p) < 28.0 + margin: # Smuggler's camp
		return true
	# Stepped descent & connecting road clearances
	for path in [
			[Vector2(0, 5), Vector2(0, -47), 4.0],
			[Vector2(0, 5), Vector2(38, 14), 3.0],
			[Vector2(38, 14), Vector2(110, 50), 4.0],
			[Vector2(110, 50), Vector2(280, 20), 4.0],
			[Vector2(0, 5), Vector2(-18, 20), 3.5],
			[Vector2(-18, 20), Vector2(-118, 102), 4.0],
			[Vector2(-118, 102), Vector2(-162, 132), 4.0],
			[Vector2(0, -20), Vector2(-52, -52), 2.5],
			[Vector2(0, -20), Vector2(55, -55), 2.5]
		]:
		if _segment_distance(p, path[0], path[1]) < float(path[2]) + margin:
			return true
	return false

static func _segment_distance(p: Vector2, a: Vector2, b: Vector2) -> float:
	var ab := b - a
	var t := clampf((p - a).dot(ab) / maxf(0.001, ab.length_squared()), 0.0, 1.0)
	return (a + ab * t).distance_to(p)

static func _in_core(x: float, z: float) -> bool:
	return x > CORE_MIN.x and x < CORE_MAX.x and z > CORE_MIN.y and z < CORE_MAX.y

static func _build_vegetation(root: Node3D) -> void:
	var density := QUALITY.foliage_density()
	var rng := RandomNumberGenerator.new()
	rng.seed = 424242
	# Forest west, forest east, and hillside scatter: one species mix.
	var plantings := [
		{"count": 150, "rect": Rect2(-100, -110, 62, 95), "mix": 0.75},
		{"count": 55, "rect": Rect2(42, -105, 55, 95), "mix": 0.45},
		{"count": 220, "rect": Rect2(-380, -380, 260, 290), "mix": 0.85},
		{"count": 110, "rect": Rect2(140, -190, 220, 240), "mix": 0.50},
		{"count": 140, "rect": Rect2(-485, -485, 970, 970), "mix": 0.55, "ring_only": true},
	]
	for planting in plantings:
		var count := int(float(planting["count"]) * density)
		var rect: Rect2 = planting["rect"]
		var placed := 0
		var attempts := 0
		while placed < count and attempts < count * 12:
			attempts += 1
			var x := rng.randf_range(rect.position.x, rect.position.x + rect.size.x)
			var z := rng.randf_range(rect.position.y, rect.position.y + rect.size.y)
			# The ring planting covers the shaped hills outside the flat core;
			# the two forest plantings fill their own rects inside it.
			if planting.get("ring_only", false) and _in_core(x, z):
				continue
			if _blocked(x, z, 1.5):
				continue
			var y := ground_y(x, z) - 0.12
			var species := "tree_pine_8" if rng.randf() < float(planting["mix"]) else "tree_broad_8"
			var s := rng.randf_range(0.75, 1.35)
			PBR.queue(species, _xform(Vector3(x, y, z), rng.randf() * TAU,
				Vector3(s, s * rng.randf_range(0.9, 1.25), s)))
			placed += 1
	# Bushes near the forest edges and along the hills' feet.
	var bushes := int(220.0 * density)
	for i in range(bushes):
		var x := rng.randf_range(-460.0, 460.0)
		var z := rng.randf_range(-460.0, 460.0)
		if _blocked(x, z, 0.5):
			continue
		var y := ground_y(x, z) - 0.08
		var s := rng.randf_range(0.8, 1.7)
		PBR.queue("bush_1", _xform(Vector3(x, y, z), rng.randf() * TAU, Vector3.ONE * s))
	# Grass clumps fill the open meadow, denser near the paths.
	var clumps := int(1600.0 * density)
	for i in range(clumps):
		var x := rng.randf_range(-450.0, 450.0)
		var z := rng.randf_range(-450.0, 450.0)
		if _blocked(x, z, 0.2):
			continue
		var y := ground_y(x, z) - 0.03
		var s := rng.randf_range(0.7, 1.5)
		PBR.queue("grass_clump_1", _xform(Vector3(x, y, z), rng.randf() * TAU, Vector3.ONE * s))

static func _build_rocks(root: Node3D) -> void:
	var density := QUALITY.foliage_density()
	var rng := RandomNumberGenerator.new()
	rng.seed = 5150
	# Path-edge and hillside rock clusters (visual only: no collision, no spawn
	# interference; large landmark rocks carry no collider either, consistent
	# with the map transfer ruin scatter).
	for i in range(int(160.0 * density)):
		var x := rng.randf_range(-460.0, 460.0)
		var z := rng.randf_range(-460.0, 460.0)
		if _blocked(x, z, -0.5):
			continue
		var y := ground_y(x, z) - 0.15
		var module := "rock_0%d" % (1 + i % 3)
		var s := rng.randf_range(0.45, 1.15)
		PBR.queue(module, _xform(Vector3(x, y, z), rng.randf() * TAU,
			Vector3(s, s * rng.randf_range(0.6, 1.0), s)), ROCK_TINT)

# ------------------------------------------------------------------ safe zones

## The safe-zone boundary reads as a boundary: a line of ward stones with a
## thin emissive ward line between them. No collision, so a levelled player can
## still walk over it and the message is "protected here", not "wall here".
static func _build_safe_zone_marks(root: Node3D) -> void:
	var zones: Array = []
	if GameData != null and GameData.get("SAFE_ZONES") is Dictionary:
		zones = (GameData.SAFE_ZONES as Dictionary).get("zones", [])
	for zone in zones:
		var radius := float(zone.get("radius", 0.0))
		if radius < 10.0 or radius > 26.0:
			continue
		var centre3: Array = zone.get("center", [0.0, 0.0, 0.0])
		var centre := Vector2(float(centre3[0]), float(centre3[2]) if centre3.size() > 2 else 0.0)
		if centre.length() > 60.0:
			continue
		var posts := int(round(TAU * radius / 5.0))
		for i in range(posts):
			var angle := TAU * float(i) / float(posts)
			var pos := Vector3(centre.x + cos(angle) * radius, 0.0, centre.y + sin(angle) * radius)
			if _blocked(pos.x, pos.z, -3.0):
				# Keep the line unbroken anyway: it is a marker, not scenery.
				pass
			PBR.queue("rock_02", _xform(pos + Vector3(0, -0.06, 0), angle,
				Vector3(0.34, 0.5, 0.34)), ROCK_TINT)
		var ring := TorusMesh.new()
		ring.inner_radius = radius - 0.09
		ring.outer_radius = radius + 0.09
		var node := MeshInstance3D.new()
		node.name = "WardLine"
		node.mesh = ring
		node.material_override = _ward_material()
		node.position = Vector3(centre.x, 0.06, centre.y)
		root.add_child(node)

static var _ward: StandardMaterial3D = null

static func _ward_material() -> StandardMaterial3D:
	if _ward != null:
		return _ward
	_ward = StandardMaterial3D.new()
	_ward.albedo_color = Color(0.55, 0.85, 1.0, 0.85)
	_ward.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	_ward.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	_ward.emission_enabled = true
	_ward.emission = Color(0.35, 0.7, 1.0)
	_ward.emission_energy_multiplier = 1.1
	return _ward

# ------------------------------------------------------------------ landmarks

## Waystones at the path junctions: a broken column on a plinth, readable from
## the air and at ground level, with real collision so it is a landmark, not a
## decoration.
static func _build_waystones(root: Node3D) -> void:
	for spot in [
			[Vector3(3.6, 0.0, -18.0), 0.4],
			[Vector3(-4.2, 0.0, -18.0), -0.4],
			[Vector3(33.0, 0.0, 12.5), 0.9],
		]:
		var raw: Vector3 = spot[0]
		var pos := Vector3(raw.x, ground_y(raw.x, raw.z), raw.z)
		_kit_static(root, "column_broken_2_2", pos, float(spot[1]), 1.35)
		PBR.queue("rock_03", _xform(pos + Vector3(0, -0.15, 0), float(spot[1]), Vector3(1.5, 0.5, 1.5)))

static func _kit_static(root: Node3D, module: String, pos: Vector3, rot_y: float, scale: float) -> void:
	var node := PBR.kit_instance(module)
	if node == null:
		return
	node.name = "Waystone"
	node.position = pos
	node.rotation.y = rot_y
	node.scale = Vector3.ONE * scale
	root.add_child(node)
	var body := StaticBody3D.new()
	body.collision_layer = 1
	body.collision_mask = 0
	var shape := CylinderShape3D.new()
	shape.radius = 0.75 * scale
	shape.height = 1.7 * scale
	var collision := CollisionShape3D.new()
	collision.shape = shape
	body.add_child(collision)
	body.position = pos + Vector3(0, 0.85 * scale, 0)
	root.add_child(body)
