extends RefCounted

const MaterialKitScript = preload("res://scripts/assets/material_kit.gd")
const PBR = preload("res://scripts/assets/pbr_kit.gd")
const OutdoorTerrain = preload("res://scripts/world/outdoor_terrain.gd")
const QualityPreset = preload("res://scripts/world/quality_preset.gd")

## Builds a real wizarding valley: castle, village, forest, lake,
## quidditch pitch, paths, lamps, fences, floating candles, stars.
## Expanded to a vast 1000m x 1000m realm (3-4x size) featuring Metin2-style
## terraced villages, elevation plateaus, mountain bridges, Hagrid's hut & pumpkin patch,
## ancient megalith highlands, deep forbidden forest hollows, and dark mountain passes.

static func build(world: Node3D) -> void:
	if world.has_node("HogwartsCastle"):
		return
	var rng := RandomNumberGenerator.new()
	rng.seed = 20260707

	_apply_sky_and_fog(world)
	_reskin_terrain(world)
	_build_paths(world)
	preload("res://scripts/world/castle_builder.gd").build(world)
	_build_courtyard_details(world)
	_build_village(world)
	_build_hagrids_grounds(world, rng)
	_build_valley_bridges(world)
	_build_forbidden_forest(world, rng)
	_build_black_lake(world)
	_build_quidditch_pitch(world)
	_build_highlands_circle(world)
	_build_smugglers_ridge(world, rng)
	_build_lamps_and_fences(world, rng)
	_build_level_dressing(world, rng)
	OutdoorTerrain.build(world)
	PBR.flush(world)
	_build_floating_candles(world)
	_build_stars_and_moon(world)
	_build_world_boundaries(world)
	_build_broom_landing(world)
	# Apply budgets after the light rig and all fixtures exist.
	QualityPreset.apply(world)

## Everything build() adds at the world root. `teardown()` frees exactly these,
## which is what lets the map controller prove an outdoor world can be unloaded
## before the castle interior is loaded ("old worlds actually
## unload").
const BUILT_NODES := [
	"OuterMeadow", "StonePaths", "HogwartsCastle", "CourtyardFountain",
	"HogsmeadeVillage", "HagridsGrounds", "ValleyBridges", "ForbiddenForest",
	"BlackLake", "QuidditchPitch", "HighlandsStoneCircle", "SmugglersRidge",
	"Props", "LevelDressing", "TerrainPass", "FloatingCandles", "Moon", "MoonLight",
	"BroomLanding", "WorldBoundaries",
]

## Free the outdoor scenery built by build().
static func teardown(world: Node3D) -> void:
	if world == null or not is_instance_valid(world):
		return
	for node_name in BUILT_NODES:
		var node := world.get_node_or_null(node_name)
		if node == null:
			continue
		world.remove_child(node)
		node.queue_free()
	# Kit batches are flushed directly under the world root (one MultiMesh per
	# repeated module), so they must go too — otherwise a reloaded map draws
	# every batch twice.
	for child in world.get_children():
		if child.name.begins_with("KitBatch_"):
			world.remove_child(child)
			child.queue_free()

# ---------------------------------------------------------------- sky

static func _apply_sky_and_fog(world: Node3D) -> void:
	var env_node := world.get_node_or_null("WorldEnvironment")
	if env_node and env_node is WorldEnvironment:
		var env: Environment = (env_node as WorldEnvironment).environment
		if env:
			env.background_mode = Environment.BG_SKY
			var sky_mat := env.sky.sky_material as ProceduralSkyMaterial
			if sky_mat:
				sky_mat.sky_top_color = Color(0.24, 0.35, 0.49)
				sky_mat.sky_horizon_color = Color(0.57, 0.64, 0.70)
				sky_mat.ground_bottom_color = Color(0.14, 0.16, 0.17)
				sky_mat.ground_horizon_color = Color(0.29, 0.32, 0.34)
				sky_mat.sun_angle_max = 3.0
			env.fog_enabled = false
			env.fog_density = 0.0002
			env.fog_aerial_perspective = 0.0
			env.fog_sky_affect = 0.0
			env.glow_enabled = true
			env.glow_intensity = 0.16
			env.glow_bloom = 0.0
			env.glow_hdr_threshold = 1.35
			env.glow_blend_mode = Environment.GLOW_BLEND_MODE_ADDITIVE
			env.tonemap_mode = Environment.TONE_MAPPER_ACES
			env.tonemap_exposure = 0.92
			env.ambient_light_source = Environment.AMBIENT_SOURCE_SKY
			env.ambient_light_energy = 0.62
			env.adjustment_enabled = true
			env.adjustment_saturation = 0.96
			env.adjustment_contrast = 1.04
			env.ssao_enabled = true
			env.ssao_intensity = 1.35
			env.ssao_radius = 0.9
			env.ssr_enabled = false
			env.ssr_max_steps = 64
	var sun := world.get_node_or_null("DirectionalLight3D") as DirectionalLight3D
	if sun:
		sun.light_color = Color(1.0, 0.96, 0.89)
		sun.light_energy = 1.1
		sun.shadow_enabled = true
		sun.rotation_degrees = Vector3(-38, -30, 0)
		sun.directional_shadow_mode = DirectionalLight3D.SHADOW_PARALLEL_4_SPLITS
		sun.directional_shadow_max_distance = 180.0
		sun.directional_shadow_blend_splits = true
		sun.shadow_normal_bias = 0.8

# ---------------------------------------------------------------- terrain

static func _reskin_terrain(world: Node3D) -> void:
	var grass_mesh := world.get_node_or_null("Terrain/GrassMesh")
	if grass_mesh and grass_mesh is MeshInstance3D:
		(grass_mesh as MeshInstance3D).visible = false

	# OuterMeadow: modular ground slabs covering the world while keeping the
	# southwestern Hagrid & Black Lake valley carved out in full 3D below z = 50.
	var meadow := Node3D.new()
	meadow.name = "OuterMeadow"
	world.add_child(meadow)

	var grass_mat := PBR.surface("grass_ground_01", PBR.MEADOW_TINT, {"metres": 8.0, "rough_min": 0.88})

	# 1. Main North & Central Plateau: spans z: -700..50 across x: -700..700!
	# Completely covers Castle, Courtyard, Staging at (-70, 20), all encounters, safe zones, landing pad!
	_ground_slab(meadow, Vector3(0, -0.05, -325.0), Vector2(1400, 750), grass_mat, true)

	# 2. East Plains & Foothills (Hogsmeade Lower & Upper tiers, Quidditch Moors, Highlands):
	# Spans x: -15..700, z: 50..700
	_ground_slab(meadow, Vector3(342.5, -0.05, 375.0), Vector2(715, 650), grass_mat, true)

	# 3. Far South Perimeter: spans z: 260..700 across x: -700..-15
	_ground_slab(meadow, Vector3(-357.5, -0.05, 480.0), Vector2(685, 440), grass_mat, true)

	# 4. Far West Perimeter: spans x: -700..-320 across z: 50..260
	_ground_slab(meadow, Vector3(-510.0, -0.05, 155.0), Vector2(380, 210), grass_mat, true)

	var court := world.get_node_or_null("Terrain/Courtyard")
	if court and court is MeshInstance3D:
		(court as MeshInstance3D).set_surface_override_material(0, PBR.surface("stone_tiles_02"))
		court.position.y = -0.13

	var grass_col := world.get_node_or_null("Terrain/CollisionShape3D")
	if grass_col and grass_col is CollisionShape3D:
		var shape := (grass_col as CollisionShape3D).shape
		if shape is BoxShape3D:
			(shape as BoxShape3D).size = Vector3(1400, 1, 750)
			grass_col.position = Vector3(0, -0.5, -325.0)

static func _ground_slab(parent: Node3D, pos: Vector3, size: Vector2, mat: Material, add_col: bool = false) -> void:
	var mi := MeshInstance3D.new()
	var pm := PlaneMesh.new()
	pm.size = size
	mi.mesh = pm
	mi.material_override = mat
	mi.position = pos
	parent.add_child(mi)
	if add_col:
		var sb := StaticBody3D.new()
		sb.collision_layer = 1
		sb.collision_mask = 0
		var col := CollisionShape3D.new()
		var box := BoxShape3D.new()
		box.size = Vector3(size.x, 1.0, size.y)
		col.shape = box
		sb.add_child(col)
		sb.position = pos + Vector3(0, -0.45, 0)
		parent.add_child(sb)
# ---------------------------------------------------------------- paths

static func _cobble_path(parent: Node3D, from: Vector3, to: Vector3, width: float = 3.0) -> void:
	# Terrain-following path ribbon: samples the real ground at both ends and
	# the midpoint, pitches to the slope and floats 6cm above it so hillside
	# roads never bury or hover. Input Y is a hint only.
	var dir := to - from
	var length := Vector2(dir.x, dir.z).length()
	if length < 0.5:
		return
	var gy_from: float = OutdoorTerrain.ground_y(from.x, from.z) + 0.06
	var gy_to: float = OutdoorTerrain.ground_y(to.x, to.z) + 0.06
	var mid_xz := (Vector2(from.x, from.z) + Vector2(to.x, to.z)) * 0.5
	var gy_mid: float = OutdoorTerrain.ground_y(mid_xz.x, mid_xz.y) + 0.06
	var mid := Vector3((from.x + to.x) * 0.5, (gy_from + gy_to) * 0.5, (from.z + to.z) * 0.5)
	mid.y = maxf(mid.y, gy_mid - 0.3)
	var path := MeshInstance3D.new()
	var pm := PlaneMesh.new()
	pm.size = Vector2(width, length)
	path.material_override = PBR.surface("stone_tiles_02", Color(0.9, 0.9, 0.86))
	path.mesh = pm
	path.position = mid
	path.rotation.y = atan2(dir.x, dir.z)
	# Pitch along the slope between the two ends.
	var dy := gy_to - gy_from
	if absf(dy) > 0.05:
		path.rotation.x = -atan2(dy, length)
	parent.add_child(path)

static func _build_paths(world: Node3D) -> void:
	var paths := Node3D.new()
	paths.name = "StonePaths"
	world.add_child(paths)
	# Core routes: courtyard -> castle, village, landing pad
	_cobble_path(paths, Vector3(0, 0, 5), Vector3(0, 0, -47), 6.0)
	_cobble_path(paths, Vector3(0, 0, 5), Vector3(38, 0, 14), 3.2)
	_cobble_path(paths, Vector3(0, 0, -20), Vector3(-52, 0, -52), 2.5)
	_cobble_path(paths, Vector3(0, 0, -20), Vector3(55, 0, -55), 2.5)

	# South: Monumental descent from castle to Hagrid's grounds (starting from z=50)
	_cobble_path(paths, Vector3(0, 0, 5), Vector3(-18, 0, 50), 3.5)
	_cobble_path(paths, Vector3(-36, -1.6, 68), Vector3(-42, -1.6, 74), 3.5) # Overlook terrace
	_cobble_path(paths, Vector3(-72, -3.2, 92), Vector3(-78, -3.2, 95), 3.2) # Middle landing

	# Hagrid's grounds hollow to Black Lake docks
	_cobble_path(paths, Vector3(-100, -4.5, 108), Vector3(-120, -4.5, 118), 3.2)
	_cobble_path(paths, Vector3(-120, -4.5, 118), Vector3(-138, -4.5, 132), 3.2)
	_cobble_path(paths, Vector3(-162, -7.0, 148), Vector3(-170, -7.0, 155), 3.5) # Boathouse entry

	# East: Hogsmeade High Street & Upper Terraces (plateau 0m -> 5m)
	_cobble_path(paths, Vector3(38, 0, 14), Vector3(65, 0, 28), 3.8)
	_cobble_path(paths, Vector3(65, 0, 28), Vector3(88, 0, 45), 3.8) # Tavern square
	_cobble_path(paths, Vector3(88, 0, 45), Vector3(130, 0, 52), 3.5) # Climbing terrace
	_cobble_path(paths, Vector3(130, 0, 52), Vector3(165, 5.0, 60), 3.2) # Upper town street

	# East: Hogsmeade to Quidditch Stadium
	_cobble_path(paths, Vector3(88, 0, 45), Vector3(150, 0, 35), 3.5)
	_cobble_path(paths, Vector3(150, 0, 35), Vector3(220, 0, 25), 3.5)
	_cobble_path(paths, Vector3(220, 0, 25), Vector3(280, 0, 20), 4.0)

	# Deep North-West: Forbidden Forest trail
	_cobble_path(paths, Vector3(-52, 0, -52), Vector3(-85, 0, -78), 2.5)
	_cobble_path(paths, Vector3(-85, 0, -78), Vector3(-130, 0, -115), 2.4)
	_cobble_path(paths, Vector3(-130, 0, -115), Vector3(-180, 0, -145), 2.2)

	# Far East: Highlands mountain road to the Ancient Megaliths (5m -> 6m plateau)
	_cobble_path(paths, Vector3(165, 5.0, 60), Vector3(230, 5.0, 30), 3.0)
	_cobble_path(paths, Vector3(230, 5.0, 30), Vector3(350, 6.0, -70), 3.0)
	_cobble_path(paths, Vector3(350, 6.0, -70), Vector3(400, 6.0, -150), 3.0)
	_cobble_path(paths, Vector3(400, 6.0, -150), Vector3(430, 6.0, -260), 3.2)

	# North-East: Smuggler's Pass & Dark Snatcher Stronghold
	_cobble_path(paths, Vector3(55, 0, -55), Vector3(95, 0, -90), 2.5)
	_cobble_path(paths, Vector3(95, 0, -90), Vector3(140, 0, -130), 2.5)
	_cobble_path(paths, Vector3(140, 0, -130), Vector3(180, 0, -160), 2.8)

# ---------------------------------------------------------------- castle

static func _build_courtyard_details(world: Node3D) -> void:
	var forge := world.get_node_or_null("OllivanderWorkshop")
	if forge:
		forge.position = Vector3(8, 0.5, 5)
	var fountain := Node3D.new()
	fountain.name = "CourtyardFountain"
	fountain.position = Vector3(-9, 0, 6)
	world.add_child(fountain)
	var base := MeshInstance3D.new()
	var base_mesh := CylinderMesh.new()
	base_mesh.top_radius = 2.4
	base_mesh.bottom_radius = 2.8
	base_mesh.height = 1.0
	base_mesh.material = PBR.surface("stone_tiles_02")
	base.mesh = base_mesh
	base.position.y = 0.5
	fountain.add_child(base)
	var water := MeshInstance3D.new()
	var water_mesh := CylinderMesh.new()
	water_mesh.top_radius = 2.2
	water_mesh.bottom_radius = 2.2
	water_mesh.height = 0.2
	water_mesh.material = MaterialKitScript.water_material()
	water.mesh = water_mesh
	water.position.y = 1.0
	fountain.add_child(water)
	var pillar := MeshInstance3D.new()
	var pillar_mesh := CylinderMesh.new()
	pillar_mesh.top_radius = 0.3
	pillar_mesh.bottom_radius = 0.45
	pillar_mesh.height = 2.2
	pillar_mesh.material = PBR.surface("stone_ashlar_01")
	pillar.mesh = pillar_mesh
	pillar.position.y = 1.6
	fountain.add_child(pillar)
	var fl := OmniLight3D.new()
	fl.light_color = Color(0.4, 0.7, 1.0)
	fl.light_energy = 1.2
	fl.omni_range = 8.0
	fl.position.y = 2.6
	fountain.add_child(fl)
	# Solid base + rim so bodies collide instead of walking through the fountain.
	_add_box_col(fountain, Vector3(0, 0.5, 0), Vector3(5.2, 1.0, 5.2))

# ---------------------------------------------------------------- village

static func _hut(parent: Node3D, pos: Vector3, rot_y: float, wall_mat: Material, roof_mat: Material, wood_mat: Material, scale: float = 1.0) -> void:
	# Terrain-aware placement: the authored Y is a hint, the ground is the truth.
	# Sampling OutdoorTerrain prevents the old buried (-1.2m) and floating
	# (+3..7m) houses — every hut sits on its hill/plateau with a stone
	# foundation skirt so grass can never clip through the floor.
	var gy: float = OutdoorTerrain.ground_y(pos.x, pos.z)
	var snapped := Vector3(pos.x, gy, pos.z)
	# On the flat meadow keep a 5cm step above the slab so the floor never
	# z-fights the grass; on hills sit exactly on the sampled height.
	if absf(gy) < 0.5:
		snapped.y = maxf(snapped.y, OutdoorTerrain.MEADOW_TOP_Y + 0.05)
	var hut := Node3D.new()
	hut.position = snapped
	hut.rotation.y = rot_y
	hut.scale = Vector3.ONE * scale
	parent.add_child(hut)
	# Stone foundation skirt: hides any grass/terrain seam and carries collision
	# so the player cannot walk through the hut.
	var found := MeshInstance3D.new()
	var fbm := BoxMesh.new()
	fbm.size = Vector3(7.4, 0.9, 6.4)
	fbm.material = PBR.surface("stone_tiles_02")
	found.mesh = fbm
	found.position.y = -0.35
	hut.add_child(found)
	_add_box_col(hut, Vector3(0, 0.4, 0), Vector3(7.4, 1.6, 6.4))
	var body := MeshInstance3D.new()
	var bm := BoxMesh.new()
	bm.size = Vector3(6, 3.4, 5)
	bm.material = wall_mat
	body.mesh = bm
	body.position.y = 1.7
	hut.add_child(body)
	_add_box_col(hut, Vector3(0, 1.7, 0), Vector3(6.0, 3.4, 5.0))
	var roof := MeshInstance3D.new()
	var prism := PrismMesh.new()
	prism.size = Vector3(7, 2.4, 6)
	prism.material = roof_mat
	roof.mesh = prism
	roof.position.y = 4.6
	hut.add_child(roof)
	# Ridge beam cap so the roof never shows an open seam from the hills.
	var ridge := MeshInstance3D.new()
	var rbm := BoxMesh.new()
	rbm.size = Vector3(7.2, 0.25, 0.5)
	rbm.material = wood_mat
	ridge.mesh = rbm
	ridge.position.y = 5.75
	hut.add_child(ridge)
	var door := MeshInstance3D.new()
	var dm := BoxMesh.new()
	dm.size = Vector3(1.2, 2.2, 0.2)
	dm.material = wood_mat
	door.mesh = dm
	door.position = Vector3(0, 1.1, 2.55)
	hut.add_child(door)
	# Doorstep stone + lintel: reads as finished, not a floating door.
	var step := MeshInstance3D.new()
	var sbm := BoxMesh.new()
	sbm.size = Vector3(1.8, 0.25, 0.9)
	sbm.material = PBR.surface("stone_tiles_02")
	step.mesh = sbm
	step.position = Vector3(0, 0.12, 3.0)
	hut.add_child(step)
	var win := MeshInstance3D.new()
	var wm := BoxMesh.new()
	wm.size = Vector3(1.4, 1.0, 0.15)
	var wmat := StandardMaterial3D.new()
	wmat.albedo_color = Color(1, 0.82, 0.45)
	wmat.emission_enabled = true
	wmat.emission = Color(1, 0.72, 0.3)
	wmat.emission_energy_multiplier = 2.0
	wm.material = wmat
	win.mesh = wm
	win.position = Vector3(1.8, 1.9, 2.55)
	hut.add_child(win)
	# Second window on the side so the hut does not look flat from the road.
	var win2 := MeshInstance3D.new()
	var wm2 := BoxMesh.new()
	wm2.size = Vector3(0.15, 1.0, 1.2)
	wm2.material = wmat
	win2.mesh = wm2
	win2.position = Vector3(3.05, 1.9, 0.2)
	hut.add_child(win2)
	# Chimney with warm smoke glow.
	var chim := MeshInstance3D.new()
	var chm := BoxMesh.new()
	chm.size = Vector3(0.8, 2.2, 0.8)
	chm.material = wall_mat
	chim.mesh = chm
	chim.position = Vector3(1.8, 5.2, -1.2)
	hut.add_child(chim)
	var smoke := MeshInstance3D.new()
	var smm := SphereMesh.new()
	smm.radius = 0.35
	smm.height = 0.7
	var smat := StandardMaterial3D.new()
	smat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	smat.albedo_color = Color(0.7, 0.7, 0.75, 0.5)
	smat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	smm.material = smat
	smoke.mesh = smm
	smoke.position = Vector3(1.8, 6.6, -1.2)
	hut.add_child(smoke)
	var l := OmniLight3D.new()
	l.light_color = Color(1.0, 0.78, 0.45)
	l.light_energy = 1.4
	l.omni_range = 10.0
	l.position = Vector3(0, 2.5, 4)
	hut.add_child(l)

static func _build_village(world: Node3D) -> void:
	var village := Node3D.new()
	village.name = "HogsmeadeVillage"
	world.add_child(village)
	var wall_mat := PBR.surface("stone_ashlar_01", Color(0.92, 0.9, 0.86), {"metres": 4.0})
	var roof_mat := PBR.surface("roof_slates_03")
	var wood_mat := PBR.surface("dark_wooden_planks")

	# Tier 1: Welcome Plaza / West Gate (Safe zone preserved at 35, 20)
	var spots_tier1 := [
		[Vector3(34, 0, 16), 0.4], [Vector3(42, 0, 10), -0.5],
		[Vector3(38, 0, 26), 2.8], [Vector3(28, 0, 24), -2.6]
	]
	for s in spots_tier1:
		_hut(village, s[0], s[1], wall_mat, roof_mat, wood_mat)

	# Tier 2: Lower Town High Street & Tavern Plaza. Ground-snapped to the
	# meadow plateau (old -1.2m buried every hut to its windows).
	var spots_tier2 := [
		[Vector3(62, 0, 24), -0.3], [Vector3(70, 0, 16), 0.8],
		[Vector3(66, 0, 38), 2.6], [Vector3(78, 0, 42), -2.8],
		[Vector3(92, 0, 34), 0.2], [Vector3(104, 0, 28), 1.2],
		[Vector3(108, 0, 44), -0.4]
	]
	for s in spots_tier2:
		_hut(village, s[0], s[1], wall_mat, roof_mat, wood_mat)

	# Three Broomsticks Tavern (Grand Village Inn at Lower Town)
	var tavern_pos := Vector3(88, 0, 54)
	_hut(village, tavern_pos, 0.2, wall_mat, roof_mat, wood_mat, 1.45)
	for ti in range(3):
		var t_raw := tavern_pos + Vector3(float(ti - 1) * 3.8, 0, 6.0)
		var t_pos := Vector3(t_raw.x, OutdoorTerrain.ground_y(t_raw.x, t_raw.z), t_raw.z)
		var table := PBR.kit_instance("long_table_8")
		if table:
			table.position = t_pos
			table.scale = Vector3(0.7, 0.7, 0.7)
			village.add_child(table)
			_add_box_col(village, t_pos + Vector3(0, 0.5, 0), Vector3(2.6, 1.0, 1.2))
		for side in [-1, 1]:
			var bench := PBR.kit_instance("bench_4")
			if bench:
				bench.position = t_pos + Vector3(0, 0, side * 0.9)
				bench.scale = Vector3(0.7, 0.7, 0.7)
				village.add_child(bench)

	# Tier 3: Upper Terraces. Ground-snapped to the 5m highland plateau
	# (old 2.8..7m floated or clipped on the procedural hills).
	var spots_tier3 := [
		[Vector3(135, 5.0, 30), 0.4], [Vector3(145, 5.0, 22), -0.6],
		[Vector3(142, 5.0, 46), 2.9], [Vector3(158, 5.0, 38), -2.5],
		[Vector3(168, 5.0, 26), 0.7], [Vector3(175, 5.0, 44), 3.1],
		[Vector3(188, 5.0, 36), -0.4]
	]
	for s in spots_tier3:
		_hut(village, s[0], s[1], wall_mat, roof_mat, wood_mat)

	# Upper terrace stone retaining walls, snapped to the plateau.
	for wi in range(8):
		var r_wall := PBR.kit_instance("wall_module_4x6")
		if r_wall:
			var wx := 122.0
			var wz := 16.0 + float(wi) * 4.0
			r_wall.position = Vector3(wx, OutdoorTerrain.ground_y(wx, wz), wz)
			r_wall.rotation.y = PI * 0.5
			r_wall.scale = Vector3(1.0, 0.7, 1.0)
			village.add_child(r_wall)
	# Terrace stair link from lower town (0m) to upper plateau (5m).
	_build_stair_flight(village, Vector3(118, 0.0, 34), Vector3(132, 5.0, 32), 12, 3.5)

	# Town square paved plaza at West Gate
	var plaza := MeshInstance3D.new()
	var pm := PlaneMesh.new()
	pm.size = Vector2(24, 20)
	plaza.material_override = PBR.surface("stone_tiles_02")
	plaza.mesh = pm
	plaza.position = Vector3(36, 0.03, 20)
	village.add_child(plaza)

	# Town square fountain well
	var well := Node3D.new()
	well.position = Vector3(36, 0, 20)
	village.add_child(well)
	var w_base := MeshInstance3D.new()
	var wbm := CylinderMesh.new()
	wbm.top_radius = 2.0
	wbm.bottom_radius = 2.2
	wbm.height = 0.9
	wbm.material = wall_mat
	w_base.mesh = wbm
	w_base.position.y = 0.45
	well.add_child(w_base)
	var w_water := MeshInstance3D.new()
	var wwm := CylinderMesh.new()
	wwm.top_radius = 1.7
	wwm.bottom_radius = 1.7
	wwm.height = 0.15
	wwm.material = PBR.surface("stone_tiles_02", Color(0.4, 0.75, 1.0))
	w_water.mesh = wwm
	w_water.position.y = 0.75
	well.add_child(w_water)
	var wl := OmniLight3D.new()
	wl.light_color = Color(0.5, 0.85, 1.0)
	wl.light_energy = 1.5
	wl.omni_range = 10.0
	wl.position.y = 1.6
	well.add_child(wl)
	# Timber well roof + crossbar + hanging bucket, and a solid base.
	for side in [-1, 1]:
		var wpost := MeshInstance3D.new()
		var wpm := BoxMesh.new()
		wpm.size = Vector3(0.18, 2.2, 0.18)
		wpm.material = wood_mat
		wpost.mesh = wpm
		wpost.position = Vector3(side * 1.6, 1.6, 0)
		well.add_child(wpost)
	var wroof := MeshInstance3D.new()
	var wrm := PrismMesh.new()
	wrm.size = Vector3(4.2, 1.2, 3.0)
	wrm.material = roof_mat
	wroof.mesh = wrm
	wroof.position.y = 3.2
	well.add_child(wroof)
	var bucket := MeshInstance3D.new()
	var bbm := CylinderMesh.new()
	bbm.top_radius = 0.28
	bbm.bottom_radius = 0.22
	bbm.height = 0.4
	bbm.material = wood_mat
	bucket.mesh = bbm
	bucket.position = Vector3(0, 1.4, 0)
	well.add_child(bucket)
	_add_box_col(village, Vector3(36, 0.45, 20), Vector3(4.4, 0.9, 4.4))

	# Directional signpost
	var sign_node := Node3D.new()
	sign_node.position = Vector3(32, 0, 14)
	village.add_child(sign_node)
	var post := MeshInstance3D.new()
	var cm := CylinderMesh.new()
	cm.top_radius = 0.08
	cm.bottom_radius = 0.1
	cm.height = 3.2
	cm.material = wood_mat
	post.mesh = cm
	post.position.y = 1.6
	sign_node.add_child(post)
	var post_lbl := Label3D.new()
	post_lbl.text = "← HOGWARTS   •   MARKET ↑   •   HIGHLANDS →"
	post_lbl.font_size = 28
	post_lbl.outline_size = 6
	post_lbl.outline_modulate = Color(0, 0, 0)
	post_lbl.billboard = BaseMaterial3D.BILLBOARD_ENABLED
	post_lbl.position = Vector3(0, 3.2, 0)
	sign_node.add_child(post_lbl)
	_add_box_col(village, Vector3(32, 1.0, 14), Vector3(0.4, 2.0, 0.4))

	# Village Labels
	var label := Label3D.new()
	label.text = "HOGSMEADE VILLAGE — LOWER TOWN"
	label.font_size = 38
	label.outline_size = 8
	label.outline_modulate = Color(0, 0, 0)
	label.billboard = BaseMaterial3D.BILLBOARD_ENABLED
	label.position = Vector3(35, 8, 18)
	village.add_child(label)

	var terrace_lbl := Label3D.new()
	terrace_lbl.text = "UPPER TERRACES — HIGHLAND QUARTER"
	terrace_lbl.font_size = 34
	terrace_lbl.modulate = Color(1.0, 0.9, 0.7)
	terrace_lbl.outline_size = 6
	terrace_lbl.outline_modulate = Color(0, 0, 0)
	terrace_lbl.billboard = BaseMaterial3D.BILLBOARD_ENABLED
	terrace_lbl.position = Vector3(150, 12, 35)
	village.add_child(terrace_lbl)

# ---------------------------------------------------------------- hagrid's grounds

static func _build_hagrids_grounds(world: Node3D, rng: RandomNumberGenerator) -> void:
	var grounds := Node3D.new()
	grounds.name = "HagridsGrounds"
	world.add_child(grounds)

	var stone := PBR.surface("stone_ashlar_01", Color(0.88, 0.85, 0.80), {"metres": 4.0})
	var roof := PBR.surface("roof_slates_03")
	var wood := PBR.surface("dark_wooden_planks")

	# =========================================================================
	# 1. MONUMENTAL STEPPED DESCENT FROM HOGWARTS (Level Design Hierarchy)
	# Descends down the southern hillside starting at z = 50 (below the flat core)
	# =========================================================================
	
	# Flight 1: South Plateau (0.0m) down to Scenic Overlook (-1.6m)
	_build_stair_flight(grounds, Vector3(-18, 0.0, 50), Vector3(-36, -1.6, 68), 8, 4.0)
	
	# Scenic Lookout Terrace at y = -1.6m
	var overlook := MeshInstance3D.new()
	var opm := PlaneMesh.new()
	opm.size = Vector2(8.0, 8.0)
	overlook.mesh = opm
	overlook.material_override = PBR.surface("floor_flagstone_01")
	overlook.position = Vector3(-42, -1.58, 74)
	grounds.add_child(overlook)
	_add_box_col(grounds, Vector3(-42, -2.08, 74), Vector3(8.0, 1.0, 8.0))

	# Lookout balustrade and benches
	for bi in range(2):
		var bal := PBR.kit_instance("balustrade_4")
		if bal:
			bal.position = Vector3(-46.2, -1.6, 72.0 + float(bi) * 4.0)
			bal.rotation.y = PI * 0.5
			grounds.add_child(bal)
	_add_box_col(grounds, Vector3(-46.2, -1.0, 74.0), Vector3(0.5, 1.2, 9.0))
	var obench := PBR.kit_instance("bench_4")
	if obench:
		obench.position = Vector3(-40.0, -1.6, 76.0)
		obench.rotation.y = -0.4
		grounds.add_child(obench)
	_lamp(grounds, Vector3(-45.0, -1.6, 77.0), false)

	# Flight 2: Scenic Overlook (-1.6m) down to Middle Landing (-3.2m)
	_build_stair_flight(grounds, Vector3(-48, -1.6, 78), Vector3(-72, -3.2, 92), 9, 3.8)

	# Flight 3: Middle Landing (-3.2m) down into Hagrid's Hollow (-4.5m)
	_build_stair_flight(grounds, Vector3(-78, -3.2, 95), Vector3(-100, -4.5, 108), 8, 3.8)

	# =========================================================================
	# 2. HAGRID'S GROUNDS HOLLOW (y = -4.5m, x: -120, z: 118)
	# Sheltered mountain terrace with round stone cottage, toolshed and pumpkin patch
	# =========================================================================
	var hollow_pos := Vector3(-120, -4.5, 118)
	
	# Terrace ground floor slab & collision
	var floor_mesh := MeshInstance3D.new()
	var fpm := PlaneMesh.new()
	fpm.size = Vector2(48, 44)
	floor_mesh.mesh = fpm
	floor_mesh.material_override = PBR.surface("grass_ground_01", PBR.MEADOW_TINT, {"metres": 8.0})
	floor_mesh.position = hollow_pos + Vector3(0, 0.02, 0)
	grounds.add_child(floor_mesh)
	_add_box_col(grounds, hollow_pos + Vector3(0, -0.5, 0), Vector3(48, 1.0, 44))

	# Mountain retaining cliffs framing the hollow
	for ci in range(7):
		var cliff := PBR.kit_instance("wall_module_4x6")
		if cliff:
			cliff.position = hollow_pos + Vector3(-20.0 + float(ci) * 6.5, 0.0, -22.0)
			cliff.scale = Vector3(1.6, 1.2, 1.6)
			grounds.add_child(cliff)

	# Hagrid's round stone cottage
	var hut := Node3D.new()
	hut.position = hollow_pos + Vector3(6.0, 0.0, -4.0)
	grounds.add_child(hut)
	var base := MeshInstance3D.new()
	var bm := CylinderMesh.new()
	bm.top_radius = 4.6
	bm.bottom_radius = 5.0
	bm.height = 4.0
	bm.material = stone
	base.mesh = bm
	base.position.y = 2.0
	hut.add_child(base)
	var cap := MeshInstance3D.new()
	var cm_roof := CylinderMesh.new()
	cm_roof.top_radius = 0.1
	cm_roof.bottom_radius = 5.8
	cm_roof.height = 3.8
	cm_roof.material = roof
	cap.mesh = cm_roof
	cap.position.y = 5.8
	hut.add_child(cap)
	var door := MeshInstance3D.new()
	var dm := BoxMesh.new()
	dm.size = Vector3(1.5, 2.6, 0.35)
	dm.material = wood
	door.mesh = dm
	door.position = Vector3(0, 1.3, 4.8)
	hut.add_child(door)
	var chim := MeshInstance3D.new()
	var chm := BoxMesh.new()
	chm.size = Vector3(1.2, 5.5, 1.2)
	chm.material = stone
	chim.mesh = chm
	chim.position = Vector3(3.4, 4.2, -1.8)
	hut.add_child(chim)
	var hl := OmniLight3D.new()
	hl.light_color = Color(1.0, 0.75, 0.4)
	hl.light_energy = 1.8
	hl.omni_range = 16.0
	hl.position = Vector3(0, 2.8, 6.0)
	hut.add_child(hl)
	# Round stone walls collide as a cylinder so bodies stop at the wall.
	var hut_body := StaticBody3D.new()
	hut_body.collision_layer = 1
	hut_body.collision_mask = 0
	var hut_col := CollisionShape3D.new()
	var hut_shape := CylinderShape3D.new()
	hut_shape.radius = 5.0
	hut_shape.height = 4.0
	hut_col.shape = hut_shape
	hut_body.add_child(hut_col)
	hut_body.position.y = 2.0
	hut.add_child(hut_body)
	# Doorstep slab in front of the round door.
	var hstep := MeshInstance3D.new()
	var hsbm := BoxMesh.new()
	hsbm.size = Vector3(2.2, 0.25, 1.2)
	hsbm.material = PBR.surface("stone_tiles_02")
	hstep.mesh = hsbm
	hstep.position = Vector3(0, 0.12, 5.4)
	hut.add_child(hstep)

	# Lean-to tool shed
	var shed := Node3D.new()
	shed.position = hollow_pos + Vector3(14.0, 0.0, -3.0)
	grounds.add_child(shed)
	var s_wall := MeshInstance3D.new()
	var s_bm := BoxMesh.new()
	s_bm.size = Vector3(3.6, 2.4, 2.6)
	s_bm.material = wood
	s_wall.mesh = s_bm
	s_wall.position.y = 1.2
	shed.add_child(s_wall)
	var s_roof := MeshInstance3D.new()
	var s_rm := PrismMesh.new()
	s_rm.size = Vector3(4.0, 1.4, 3.0)
	s_roof.material_override = roof
	s_roof.mesh = s_rm
	s_roof.position.y = 3.0
	shed.add_child(s_roof)
	_add_box_col(shed, Vector3(0, 1.2, 0), Vector3(3.6, 2.4, 2.6))
	# Chopped wood pile +Tools beside the shed: stacked logs and a leaning axe.
	for li in range(6):
		var log := MeshInstance3D.new()
		var lgm := CylinderMesh.new()
		lgm.top_radius = 0.22
		lgm.bottom_radius = 0.22
		lgm.height = 1.1
		lgm.material = wood
		log.mesh = lgm
		log.rotation.z = PI * 0.5
		log.position = Vector3(-1.2 + float(li % 3) * 0.55, 0.25 + float(li / 3) * 0.5, 2.4)
		shed.add_child(log)

	# =========================================================================
	# 3. GIANT PUMPKIN PATCH (18 giant pumpkins, rustic fence, tools, dark soil)
	# =========================================================================
	var patch_center := hollow_pos + Vector3(-8.0, 0, 8.0)
	var soil := MeshInstance3D.new()
	var spm := PlaneMesh.new()
	spm.size = Vector2(24, 18)
	soil.mesh = spm
	soil.material_override = PBR.slot_material("dirt")
	soil.position = patch_center + Vector3(0, 0.04, 0)
	grounds.add_child(soil)

	var pumpkin_mat := StandardMaterial3D.new()
	pumpkin_mat.albedo_color = Color(0.92, 0.42, 0.08)
	pumpkin_mat.roughness = 0.65
	var stem_mat := StandardMaterial3D.new()
	stem_mat.albedo_color = Color(0.18, 0.35, 0.12)

	# 18 giant pumpkins
	for pi in range(18):
		var p := Node3D.new()
		var p_offset := Vector3(rng.randf_range(-9.0, 9.0), 0, rng.randf_range(-7.0, 7.0))
		p.position = patch_center + p_offset
		grounds.add_child(p)
		var p_radius := rng.randf_range(0.7, 1.85)
		var p_mesh := MeshInstance3D.new()
		var sm := SphereMesh.new()
		sm.radius = p_radius
		sm.height = p_radius * 1.55
		p_mesh.mesh = sm
		p_mesh.material_override = pumpkin_mat
		p_mesh.position.y = p_radius * 0.65
		p.add_child(p_mesh)
		var stem := MeshInstance3D.new()
		var stm := CylinderMesh.new()
		stm.top_radius = 0.06
		stm.bottom_radius = 0.1
		stm.height = 0.5
		stem.mesh = stm
		stem.material_override = stem_mat
		stem.position.y = p_radius * 1.35
		stem.rotation.z = rng.randf_range(-0.3, 0.3)
		p.add_child(stem)

	# Rustic fences surrounding the patch: posts + two rails + a gate gap.
	for fi in range(11):
		if fi == 5:
			continue # gate opening onto the hut path
		var post_p := patch_center + Vector3(-11.0 + float(fi) * 2.2, 0.55, -8.5)
		var post_node := MeshInstance3D.new()
		var pbm := BoxMesh.new()
		pbm.size = Vector3(0.2, 1.2, 0.2)
		pbm.material = wood
		post_node.mesh = pbm
		post_node.position = post_p
		grounds.add_child(post_node)
	for rail_i in range(2):
		var rail := MeshInstance3D.new()
		var rbm := BoxMesh.new()
		rbm.size = Vector3(10.0, 0.12, 0.12)
		rbm.material = wood
		rail.mesh = rbm
		rail.position = patch_center + Vector3(-6.6, 0.55 + float(rail_i) * 0.35, -8.5)
		grounds.add_child(rail)
		var rail2 := MeshInstance3D.new()
		var rbm2 := BoxMesh.new()
		rbm2.size = Vector3(10.0, 0.12, 0.12)
		rbm2.material = wood
		rail2.mesh = rbm2
		rail2.position = patch_center + Vector3(6.6, 0.55 + float(rail_i) * 0.35, -8.5)
		grounds.add_child(rail2)

	var label := Label3D.new()
	label.text = "HAGRID'S HUT & PUMPKIN PATCH — GROUNDSKEEPER"
	label.font_size = 36
	label.modulate = Color(1.0, 0.8, 0.4)
	label.outline_size = 8
	label.outline_modulate = Color(0, 0, 0)
	label.billboard = BaseMaterial3D.BILLBOARD_ENABLED
	label.position = hollow_pos + Vector3(0, 8.5, 0)
	grounds.add_child(label)

static func _build_stair_flight(parent: Node3D, from: Vector3, to: Vector3, step_count: int, width: float) -> void:
	var delta := to - from
	var h_dist := Vector2(delta.x, delta.z).length()
	var angle_y := atan2(delta.x, delta.z)
	
	# Physical stepped treads
	for i in range(step_count):
		var t := float(i) / float(step_count - 1)
		var step_pos := from + delta * t
		var tread := PBR.kit_instance("stair_tread_0_2x4")
		if tread:
			tread.position = step_pos
			tread.rotation.y = angle_y
			tread.scale = Vector3(width / 4.0, 1.0, 1.2)
			parent.add_child(tread)
		if i % 3 == 0:
			for side in [-1, 1]:
				var np := PBR.kit_instance("newel_post_1_2")
				if np:
					var lateral := Basis.from_euler(Vector3(0, angle_y, 0)) * Vector3(side * (width * 0.5 + 0.2), 0, 0)
					np.position = step_pos + lateral
					parent.add_child(np)
					if i == 0 or i == step_count - 1:
						_lamp(parent, np.position, false)

	# Sloping collision ramp
	var ramp_body := StaticBody3D.new()
	ramp_body.collision_layer = 1
	ramp_body.collision_mask = 0
	var col := CollisionShape3D.new()
	var box := BoxShape3D.new()
	box.size = Vector3(width, 0.4, sqrt(h_dist * h_dist + delta.y * delta.y))
	col.shape = box
	ramp_body.add_child(col)
	ramp_body.position = (from + to) * 0.5 + Vector3(0, 0.1, 0)
	ramp_body.rotation.y = angle_y
	ramp_body.rotation.x = -atan2(delta.y, h_dist)
	parent.add_child(ramp_body)

# ---------------------------------------------------------------- bridges

static func _build_valley_bridges(world: Node3D) -> void:
	var bridges := Node3D.new()
	bridges.name = "ValleyBridges"
	world.add_child(bridges)
	var specs := [
		[Vector3(50, 0, 22), 0.4, 18.0, 4.5],   # Hogsmeade West Gate viaduct bridge
		[Vector3(108, 0, 48), 0.2, 16.0, 4.0],   # Lower to Upper Terrace bridge
		[Vector3(165, 0, 14), 0.1, 18.0, 4.0],   # East mountain bridge
		[Vector3(115, 0, -110), 0.6, 16.0, 3.8]  # North ravine bridge
	]
	var flag := PBR.surface("floor_flagstone_01")
	for s in specs:
		var raw: Vector3 = s[0]
		var gy: float = OutdoorTerrain.ground_y(raw.x, raw.z)
		var b := Node3D.new()
		b.position = Vector3(raw.x, gy, raw.z)
		b.rotation.y = s[1]
		bridges.add_child(b)
		var length: float = s[2]
		var width: float = s[3]
		var deck := MeshInstance3D.new()
		var dm := BoxMesh.new()
		dm.size = Vector3(width, 0.4, length)
		dm.material = flag
		deck.mesh = dm
		deck.position.y = 0.2
		b.add_child(deck)
		_add_box_col(b, Vector3(0, 0.1, 0), Vector3(width, 0.4, length))
		var rail_count := int(length / 4.0)
		for r_i in range(rail_count):
			var r_z := -length * 0.5 + 2.0 + float(r_i) * 4.0
			for side in [-1, 1]:
				var bal := PBR.kit_instance("balustrade_4")
				if bal:
					bal.position = Vector3(side * (width * 0.5 - 0.2), 0.4, r_z)
					bal.rotation.y = PI * 0.5 if side > 0 else -PI * 0.5
					b.add_child(bal)
		for side in [-1, 1]:
			for end_z in [-length * 0.5 + 0.5, length * 0.5 - 0.5]:
				_lamp(b, Vector3(side * (width * 0.5 + 0.4), 0.2, end_z), false)

# ---------------------------------------------------------------- forest

static func _build_forbidden_forest(world: Node3D, rng: RandomNumberGenerator) -> void:
	var forest := Node3D.new()
	forest.name = "ForbiddenForest"
	world.add_child(forest)
	var label := Label3D.new()
	label.text = "FORBIDDEN FOREST"
	label.font_size = 36
	label.modulate = Color(0.6, 1.0, 0.6)
	label.outline_size = 8
	label.outline_modulate = Color(0, 0, 0)
	label.billboard = BaseMaterial3D.BILLBOARD_ENABLED
	label.position = Vector3(-60, 9, -40)
	forest.add_child(label)
	var gl := OmniLight3D.new()
	gl.light_color = Color(0.3, 1.0, 0.4)
	gl.light_energy = 1.6
	gl.omni_range = 22.0
	gl.position = Vector3(-60, 4, -42)
	forest.add_child(gl)

	# Deep Forest Hollows
	var spider_lbl := Label3D.new()
	spider_lbl.text = "SPIDER HOLLOW (ACROMANTULA LAIR)"
	spider_lbl.font_size = 32
	spider_lbl.modulate = Color(0.4, 0.9, 0.5)
	spider_lbl.outline_size = 8
	spider_lbl.outline_modulate = Color(0, 0, 0)
	spider_lbl.billboard = BaseMaterial3D.BILLBOARD_ENABLED
	spider_lbl.position = Vector3(-180, 8, -140)
	forest.add_child(spider_lbl)
	var s_light := OmniLight3D.new()
	s_light.light_color = Color(0.25, 0.85, 0.35)
	s_light.light_energy = 2.0
	s_light.omni_range = 28.0
	s_light.position = Vector3(-180, 3.5, -140)
	forest.add_child(s_light)
	# Spider Hollow dressing: webs, cocoons, egg sacs. Ground-snapped so none
	# float above the plateau.
	_build_spider_hollow(forest, Vector3(-180, 0, -140))

	var ruins_lbl := Label3D.new()
	ruins_lbl.text = "CURSED CRYPT & DARK RUINS"
	ruins_lbl.font_size = 32
	ruins_lbl.modulate = Color(0.7, 0.4, 0.9)
	ruins_lbl.outline_size = 8
	ruins_lbl.outline_modulate = Color(0, 0, 0)
	ruins_lbl.billboard = BaseMaterial3D.BILLBOARD_ENABLED
	ruins_lbl.position = Vector3(-240, 8, -200)
	forest.add_child(ruins_lbl)
	var r_light := OmniLight3D.new()
	r_light.light_color = Color(0.6, 0.2, 0.9)
	r_light.light_energy = 2.2
	r_light.omni_range = 26.0
	r_light.position = Vector3(-240, 4.0, -200)
	forest.add_child(r_light)
	_build_cursed_crypt(forest, Vector3(-240, 0, -200))
	# Forest floor dressing along the trail: glowing mushrooms + fireflies.
	_build_forest_floor(forest, rng)

static func _forest_ground(x: float, z: float) -> float:
	return OutdoorTerrain.ground_y(x, z)

static func _build_spider_hollow(parent: Node3D, center: Vector3) -> void:
	var gy := _forest_ground(center.x, center.z)
	var web_mat := StandardMaterial3D.new()
	web_mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	web_mat.albedo_color = Color(0.85, 0.9, 0.95, 0.4)
	web_mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	web_mat.cull_mode = BaseMaterial3D.CULL_DISABLED
	var cocoon_mat := StandardMaterial3D.new()
	cocoon_mat.albedo_color = Color(0.75, 0.78, 0.7)
	cocoon_mat.roughness = 0.9
	var sac_mat := StandardMaterial3D.new()
	sac_mat.albedo_color = Color(0.6, 0.85, 0.5)
	sac_mat.emission_enabled = true
	sac_mat.emission = Color(0.35, 0.8, 0.3)
	sac_mat.emission_energy_multiplier = 1.2
	# Web canopy: concentric rings + radial strands between four poles.
	for px in [-8.0, 8.0]:
		for pz in [-6.0, 6.0]:
			var pole := MeshInstance3D.new()
			var pm := CylinderMesh.new()
			pm.top_radius = 0.15
			pm.bottom_radius = 0.25
			pm.height = 6.0
			pm.material = PBR.slot_material("wood_dark")
			pole.mesh = pm
			pole.position = center + Vector3(px, gy - center.y + 3.0, pz)
			parent.add_child(pole)
	for ri in range(3):
		var ring := MeshInstance3D.new()
		var tm := TorusMesh.new()
		tm.inner_radius = 2.5 + float(ri) * 2.0 - 0.06
		tm.outer_radius = 2.5 + float(ri) * 2.0 + 0.06
		tm.material = web_mat
		ring.mesh = tm
		ring.rotation.x = PI * 0.5
		ring.position = center + Vector3(0, gy - center.y + 4.5 - float(ri) * 0.6, 0)
		parent.add_child(ring)
	# Cocoons + egg sacs ring the lair.
	for i in range(8):
		var ang := TAU * float(i) / 8.0
		var cx := center.x + cos(ang) * 7.0
		var cz := center.z + sin(ang) * 7.0
		var cy := _forest_ground(cx, cz)
		var coc := MeshInstance3D.new()
		var sm := SphereMesh.new()
		sm.radius = 0.7
		sm.height = 1.6
		sm.material = cocoon_mat if i % 3 != 0 else sac_mat
		coc.mesh = sm
		coc.position = Vector3(cx, cy + 0.8, cz)
		coc.rotation.z = 0.25 * float((i % 3) - 1)
		parent.add_child(coc)
	_add_box_col(parent, Vector3(center.x, gy + 0.5, center.z), Vector3(3.0, 1.0, 3.0))

static func _build_cursed_crypt(parent: Node3D, center: Vector3) -> void:
	var gy := _forest_ground(center.x, center.z)
	var stone := PBR.surface("stone_ashlar_02")
	# Sunken crypt: floor slab, three walls (open front), altar, coffins.
	var floor_m := MeshInstance3D.new()
	var fbm := BoxMesh.new()
	fbm.size = Vector3(14, 0.4, 10)
	fbm.material = PBR.surface("floor_flagstone_01")
	floor_m.mesh = fbm
	floor_m.position = Vector3(center.x, gy + 0.1, center.z)
	parent.add_child(floor_m)
	_add_box_col(parent, Vector3(center.x, gy, center.z), Vector3(14, 0.5, 10))
	for wi in range(3):
		var wall := PBR.kit_instance("wall_module_4x6_damaged")
		if wall:
			wall.position = Vector3(center.x - 4.5 + float(wi) * 4.5, gy, center.z - 5.0)
			parent.add_child(wall)
	for ci in range(2):
		var col := PBR.kit_instance("column_broken_2_2")
		if col:
			col.position = Vector3(center.x - 5.5 + float(ci) * 11.0, gy, center.z + 1.0)
			parent.add_child(col)
	var altar := MeshInstance3D.new()
	var am := BoxMesh.new()
	am.size = Vector3(3.0, 1.1, 1.6)
	am.material = stone
	altar.mesh = am
	altar.position = Vector3(center.x, gy + 0.55, center.z - 2.0)
	parent.add_child(altar)
	_add_box_col(parent, Vector3(center.x, gy + 0.55, center.z - 2.0), Vector3(3.0, 1.1, 1.6))
	var glow_mat := StandardMaterial3D.new()
	glow_mat.albedo_color = Color(0.6, 0.2, 0.95)
	glow_mat.emission_enabled = true
	glow_mat.emission = Color(0.6, 0.2, 1.0)
	glow_mat.emission_energy_multiplier = 2.0
	var rune := MeshInstance3D.new()
	var rm := BoxMesh.new()
	rm.size = Vector3(2.4, 0.1, 1.0)
	rm.material = glow_mat
	rune.mesh = rm
	rune.position = Vector3(center.x, gy + 1.15, center.z - 2.0)
	parent.add_child(rune)
	for ti in range(2):
		var coff := MeshInstance3D.new()
		var cbm := BoxMesh.new()
		cbm.size = Vector3(1.1, 0.8, 2.4)
		cbm.material = PBR.surface("dark_wooden_planks")
		coff.mesh = cbm
		coff.position = Vector3(center.x - 3.0 + float(ti) * 6.0, gy + 0.4, center.z + 3.0)
		coff.rotation.y = 0.2 * float(ti)
		parent.add_child(coff)

static func _build_forest_floor(parent: Node3D, rng: RandomNumberGenerator) -> void:
	var cap_mat := StandardMaterial3D.new()
	cap_mat.albedo_color = Color(0.4, 0.8, 0.45)
	cap_mat.emission_enabled = true
	cap_mat.emission = Color(0.25, 0.7, 0.35)
	cap_mat.emission_energy_multiplier = 1.4
	var stem_mat := StandardMaterial3D.new()
	stem_mat.albedo_color = Color(0.8, 0.82, 0.75)
	var trail := [Vector3(-52, 0, -52), Vector3(-85, 0, -78), Vector3(-130, 0, -115), Vector3(-180, 0, -145)]
	for tp in trail:
		var tpv: Vector3 = tp
		for mi in range(5):
			var mx: float = tpv.x + rng.randf_range(-6.0, 6.0)
			var mz: float = tpv.z + rng.randf_range(-6.0, 6.0)
			var my := _forest_ground(mx, mz)
			var stem := MeshInstance3D.new()
			var sm := CylinderMesh.new()
			sm.top_radius = 0.08
			sm.bottom_radius = 0.12
			sm.height = 0.5
			sm.material = stem_mat
			stem.mesh = sm
			stem.position = Vector3(mx, my + 0.25, mz)
			parent.add_child(stem)
			var cap := MeshInstance3D.new()
			var cm := SphereMesh.new()
			cm.radius = 0.3
			cm.height = 0.4
			cm.material = cap_mat
			cap.mesh = cm
			cap.position = Vector3(mx, my + 0.55, mz)
			parent.add_child(cap)
	# Fireflies drifting over the trail: tiny emissive motes that bob with the
	# same phase system as the floating candles (game_world animates the group).
	var fly_mat := StandardMaterial3D.new()
	fly_mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	fly_mat.albedo_color = Color(0.7, 1.0, 0.5)
	for fi in range(14):
		var tpv2: Vector3 = (trail as Array)[fi % (trail as Array).size()]
		var fx: float = tpv2.x + rng.randf_range(-8.0, 8.0)
		var fz: float = tpv2.z + rng.randf_range(-8.0, 8.0)
		var fy := _forest_ground(fx, fz) + rng.randf_range(1.0, 2.5)
		var mote := MeshInstance3D.new()
		var mm := SphereMesh.new()
		mm.radius = 0.07
		mm.height = 0.14
		mm.material = fly_mat
		mote.mesh = mm
		mote.position = Vector3(fx, fy, fz)
		parent.add_child(mote)
		mote.set_meta("base_y", fy)
		mote.set_meta("phase", rng.randf() * TAU)
		mote.add_to_group("floating_candles")

# ---------------------------------------------------------------- lake

static func _build_black_lake(world: Node3D) -> void:
	var lake := Node3D.new()
	lake.name = "BlackLake"
	world.add_child(lake)

	var lake_center: Vector3 = OutdoorTerrain.LAKE_CENTER # Water surface at y = -7.0m
	var lake_size: Vector2 = OutdoorTerrain.LAKE_SIZE
	var bed_y: float = OutdoorTerrain.LAKE_BED_Y

	# =========================================================================
	# 1. 3D CARVED LAKEBED BASIN & DEEP UNDERWATER FLOOR (y = -13.5m)
	# Eliminates the 2D plane: 6.5 meters of underwater depth beneath the surface!
	# Bed sits above the grounds kill-plane (y_min = -16) so touching it never
	# triggers a fall rescue; the water surface collision above keeps swimmers
	# from ever reaching it by walking.
	# =========================================================================
	var bed_mesh := MeshInstance3D.new()
	var bpm := PlaneMesh.new()
	bpm.size = Vector2(150, 130)
	bed_mesh.mesh = bpm
	bed_mesh.material_override = PBR.surface("floor_flagstone_01", Color(0.22, 0.26, 0.28), {"metres": 4.0})
	bed_mesh.position = Vector3(lake_center.x, bed_y, lake_center.z)
	lake.add_child(bed_mesh)
	_add_box_col(lake, Vector3(lake_center.x, bed_y - 0.5, lake_center.z), Vector3(150, 1.0, 130))

	# The banks are now real terrain (OutdoorTerrain carves the basin from the
	# water rectangle), so the old visual-only bank boxes are gone. Shore
	# boulders ring the rectangular shoreline, snapped to the actual ground.
	var half_x := lake_size.x * 0.5
	var half_z := lake_size.y * 0.5
	var rock_i := 0
	for si in range(24):
		var sang := TAU * float(si) / 24.0
		var dir := Vector2(cos(sang), sin(sang))
		var edge_scale := 1.0 / maxf(absf(dir.x) / (half_x + 3.0), absf(dir.y) / (half_z + 3.0))
		var sx := lake_center.x + dir.x * edge_scale
		var sz := lake_center.z + dir.y * edge_scale
		# Keep the dock peninsula and Hagrid's ridge side clear.
		if sx > -182.0 and sz > 118.0 and sz < 176.0:
			continue
		var shore_rock := PBR.kit_instance("rock_0%d" % (1 + rock_i % 3))
		rock_i += 1
		if shore_rock:
			shore_rock.position = Vector3(sx, OutdoorTerrain.ground_y(sx, sz) - 0.3, sz)
			var sc := 1.2 + float((si * 7) % 4) * 0.3
			shore_rock.scale = Vector3(sc, sc * 0.8, sc)
			shore_rock.rotation.y = sang
			lake.add_child(shore_rock)

	# =========================================================================
	# 2. SUBMERGED 3D UNDERWATER FEATURES (Visible through translucent water)
	# =========================================================================
	var wood := PBR.surface("dark_wooden_planks")

	# Sunken wooden rowboat resting tilted on the lakebed floor
	var wreck := Node3D.new()
	wreck.position = Vector3(lake_center.x + 15.0, -13.2, lake_center.z - 10.0)
	wreck.rotation.z = 0.3
	wreck.rotation.y = 0.6
	lake.add_child(wreck)
	var hull := MeshInstance3D.new()
	var hm := BoxMesh.new()
	hm.size = Vector3(2.4, 0.9, 5.6)
	hull.material_override = wood
	hull.mesh = hm
	hull.position.y = 0.45
	wreck.add_child(hull)
	var mast := MeshInstance3D.new()
	var mm := CylinderMesh.new()
	mm.top_radius = 0.08
	mm.bottom_radius = 0.12
	mm.height = 4.2
	mast.material_override = wood
	mast.mesh = mm
	mast.position = Vector3(0, 2.0, 0)
	mast.rotation.x = 0.4
	wreck.add_child(mast)

	# Ancient Merpeople sunken ruins: pointed arches and broken columns
	var ruins := Node3D.new()
	ruins.position = Vector3(lake_center.x - 20.0, -13.5, lake_center.z + 15.0)
	lake.add_child(ruins)
	for ri in range(2):
		var arch := PBR.kit_instance("arch_pointed_2_4x3_4")
		if arch:
			arch.position = Vector3(float(ri) * 3.5, 0.0, 0.0)
			arch.rotation.y = 0.3
			ruins.add_child(arch)
		var col := PBR.kit_instance("column_broken_2_2")
		if col:
			col.position = Vector3(float(ri) * 4.0 - 2.0, 0.0, 4.0)
			ruins.add_child(col)

	# Submerged boulders and rock piles rising from the deep floor
	for bi in range(6):
		var srock := PBR.kit_instance("rock_0%d" % (1 + bi % 3))
		if srock:
			srock.position = Vector3(lake_center.x + float(bi * 17 % 50) - 25.0, -13.0, lake_center.z + float(bi * 23 % 50) - 25.0)
			srock.scale = Vector3(2.0, 2.5, 2.0)
			lake.add_child(srock)
	# Murky-depth light + weed fronds so the deep floor never reads pitch black
	# through the translucent surface.
	var deep_light := OmniLight3D.new()
	deep_light.light_color = Color(0.3, 0.7, 0.8)
	deep_light.light_energy = 1.2
	deep_light.omni_range = 30.0
	deep_light.position = Vector3(lake_center.x, -11.0, lake_center.z)
	lake.add_child(deep_light)
	var weed_mat := StandardMaterial3D.new()
	weed_mat.albedo_color = Color(0.15, 0.4, 0.25)
	weed_mat.roughness = 0.9
	for wi in range(10):
		var weed := MeshInstance3D.new()
		var wcm := CylinderMesh.new()
		wcm.top_radius = 0.05
		wcm.bottom_radius = 0.16
		wcm.height = 2.0 + float(wi % 3)
		wcm.material = weed_mat
		weed.mesh = wcm
		weed.position = Vector3(
			lake_center.x + float((wi * 37) % 60) - 30.0, bed_y + 1.0, lake_center.z + float((wi * 53) % 60) - 30.0)
		weed.rotation.z = 0.12 * float((wi % 3) - 1)
		lake.add_child(weed)

	# =========================================================================
	# 3. CLIFF DESCENT STAIRWAY TO THE BOATHOUSE
	# Descends from Hagrid's ridge (-4.5m) to Boathouse dock (-7.0m)
	# =========================================================================
	_build_stair_flight(lake, Vector3(-138, -4.5, 132), Vector3(-162, -7.0, 148), 14, 4.0)

	# =========================================================================
	# 4. HOGWARTS BOATHOUSE & DOCKS (y = -7.0m at water's edge)
	# =========================================================================
	var boathouse_pos := Vector3(-162, -7.0, 148)
	var boathouse := Node3D.new()
	boathouse.position = boathouse_pos
	lake.add_child(boathouse)

	var stone := PBR.surface("stone_ashlar_01", Color(0.9, 0.88, 0.84), {"metres": 4.0})
	var roof := PBR.surface("roof_slates_03")

	# Heavy stone arcade arches straddling the boat slips
	for ai in range(3):
		var b_arch := PBR.kit_instance("arch_arcade_6x5")
		if b_arch:
			b_arch.position = Vector3(float(ai) * 6.5, 0.0, 0.0)
			b_arch.scale = Vector3(1.0, 1.2, 1.2)
			boathouse.add_child(b_arch)

	# Boathouse walls and pitched roof
	var bh_body := MeshInstance3D.new()
	var bh_bm := BoxMesh.new()
	bh_bm.size = Vector3(18.0, 6.0, 12.0)
	bh_body.material_override = stone
	bh_body.mesh = bh_bm
	bh_body.position = Vector3(6.5, 3.0, -6.0)
	boathouse.add_child(bh_body)
	_add_box_col(boathouse, Vector3(6.5, 3.0, -6.0), Vector3(18.0, 6.0, 12.0))

	var bh_roof := MeshInstance3D.new()
	var bh_rm := PrismMesh.new()
	bh_rm.size = Vector3(20.0, 4.5, 14.0)
	bh_roof.material_override = roof
	bh_roof.mesh = bh_rm
	bh_roof.position = Vector3(6.5, 8.2, -6.0)
	boathouse.add_child(bh_roof)
	# Open slip doors (swung back against the piers) + a warm hanging lantern
	# so the boathouse reads as working, not a solid block.
	for di in range(2):
		var sdoor := MeshInstance3D.new()
		var sdm := BoxMesh.new()
		sdm.size = Vector3(2.6, 4.2, 0.25)
		sdm.material = wood
		sdoor.mesh = sdm
		sdoor.position = Vector3(-2.0 + float(di) * 15.0, 2.1, 0.6)
		sdoor.rotation.y = 0.9 if di == 0 else -0.9
		boathouse.add_child(sdoor)
	var blight := OmniLight3D.new()
	blight.light_color = Color(1.0, 0.8, 0.5)
	blight.light_energy = 1.6
	blight.omni_range = 14.0
	blight.position = Vector3(6.5, 4.5, 1.0)
	boathouse.add_child(blight)

	# =========================================================================
	# 5. WOODEN PROMENADE, DOCKS & PIERS (Extending out onto the lake surface)
	# =========================================================================
	var pier_start := Vector3(-162, -6.7, 155)
	for pi in range(8):
		var plank := MeshInstance3D.new()
		var plm := BoxMesh.new()
		plm.size = Vector3(5.0, 0.35, 7.0)
		plank.material_override = wood
		plank.mesh = plm
		plank.position = pier_start + Vector3(-float(pi) * 5.0, 0.0, float(pi) * 2.5)
		lake.add_child(plank)
		_add_box_col(lake, plank.position, Vector3(5.0, 0.35, 7.0))
		for side in [-1, 1]:
			var post := MeshInstance3D.new()
			var psm := CylinderMesh.new()
			psm.top_radius = 0.14
			psm.bottom_radius = 0.18
			psm.height = 3.5
			post.material_override = wood
			post.mesh = psm
			post.position = plank.position + Vector3(0, -1.0, side * 2.6)
			lake.add_child(post)
		# Rope handrail along one side + a swim ladder at the pier end.
		if pi < 7:
			var rope := MeshInstance3D.new()
			var rpm := BoxMesh.new()
			rpm.size = Vector3(5.4, 0.09, 0.09)
			rpm.material = wood
			rope.mesh = rpm
			var next := pier_start + Vector3(-float(pi + 1) * 5.0, 0.0, float(pi + 1) * 2.5)
			rope.position = (plank.position + next) * 0.5 + Vector3(0, 0.9, -2.6)
			rope.rotation.y = atan2(next.x - plank.position.x, next.z - plank.position.z) + PI * 0.5
			lake.add_child(rope)
		if pi == 7:
			for ri in range(3):
				var rung := MeshInstance3D.new()
				var rum := BoxMesh.new()
				rum.size = Vector3(0.7, 0.08, 0.08)
				rum.material = wood
				rung.mesh = rum
				rung.position = plank.position + Vector3(-2.2, -0.4 - float(ri) * 0.5, 3.5)
				lake.add_child(rung)
		if pi % 2 == 1:
			_lamp(lake, plank.position + Vector3(0, 0.2, 2.8), false)

	# Moored wooden rowboats with bench + shipped oars
	for rbi in range(3):
		var boat := Node3D.new()
		boat.position = pier_start + Vector3(-float(rbi) * 8.0 - 4.0, 0.0, 6.0)
		boat.rotation.y = 0.2 + float(rbi) * 0.15
		lake.add_child(boat)
		var b_mesh := MeshInstance3D.new()
		var b_box := BoxMesh.new()
		b_box.size = Vector3(2.2, 0.8, 4.8)
		b_mesh.material_override = wood
		b_mesh.mesh = b_box
		b_mesh.position.y = 0.25
		boat.add_child(b_mesh)
		var bench := MeshInstance3D.new()
		var bbm := BoxMesh.new()
		bbm.size = Vector3(1.8, 0.12, 0.5)
		bbm.material = wood
		bench.mesh = bbm
		bench.position = Vector3(0, 0.7, 0)
		boat.add_child(bench)
		var oar := MeshInstance3D.new()
		var obm := BoxMesh.new()
		obm.size = Vector3(0.12, 0.08, 3.0)
		obm.material = wood
		oar.mesh = obm
		oar.position = Vector3(0.4, 0.75, 0.4)
		oar.rotation.y = 0.25
		boat.add_child(oar)

	# =========================================================================
	# 6. WATER SURFACE: bright animated PBR + walkable collision + shoreline life
	# The old lake had a visual-only plane: walking onto it dropped the body
	# 6.5m to the lakebed (below the -10 kill-plane) and teleported the player
	# to the courtyard. The surface now carries its own thin walkable collider
	# at mean water level so the character wades/floats instead of falling, and
	# the player script adds swim drag + buoyancy on top of it.
	# =========================================================================
	var water := MeshInstance3D.new()
	water.name = "LakeWaterSurface"
	var pm := PlaneMesh.new()
	pm.size = lake_size
	pm.subdivide_width = 80
	pm.subdivide_depth = 80
	water.material_override = MaterialKitScript.water_material()
	water.mesh = pm
	water.position = lake_center
	lake.add_child(water)
	# Walkable water surface: thin box at mean level (+0.15 above visual mean so
	# wave troughs never expose feet below the collider).
	_add_box_col(lake, lake_center + Vector3(0, 0.15, 0), Vector3(lake_size.x, 0.5, lake_size.y))
	# Underwater safety net 1m above the bed: a swimmer that dives is caught
	# before the kill-plane, and the player script floats them back up.
	_add_box_col(lake, Vector3(lake_center.x, bed_y + 1.2, lake_center.z), Vector3(140, 0.4, 120))

	# Shoreline foam: four flat emissive strips hugging the rectangular water
	# edge so the contact line reads even when depth fade is unavailable.
	var foam_mat := StandardMaterial3D.new()
	foam_mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	foam_mat.albedo_color = Color(0.85, 0.94, 1.0, 0.55)
	foam_mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	foam_mat.cull_mode = BaseMaterial3D.CULL_DISABLED
	for fi in range(4):
		var foam := MeshInstance3D.new()
		var fq := PlaneMesh.new()
		var horizontal := fi < 2
		fq.size = Vector2(lake_size.x, 2.0) if horizontal else Vector2(2.0, lake_size.y)
		fq.material = foam_mat
		foam.mesh = fq
		var sign_v := -1.0 if fi % 2 == 0 else 1.0
		if horizontal:
			foam.position = lake_center + Vector3(0, 0.12, sign_v * (half_z - 1.0))
		else:
			foam.position = lake_center + Vector3(sign_v * (half_x - 1.0), 0.12, 0)
		lake.add_child(foam)

	# Shoreline life: reeds, lily pads, mooring buoys. All snap to the water
	# surface so they ride with the lake, never buried in the banks.
	var reed_mat := StandardMaterial3D.new()
	reed_mat.albedo_color = Color(0.22, 0.42, 0.18)
	reed_mat.roughness = 0.9
	var lily_mat := StandardMaterial3D.new()
	lily_mat.albedo_color = Color(0.16, 0.45, 0.2)
	lily_mat.roughness = 0.7
	var flower_mat := StandardMaterial3D.new()
	flower_mat.albedo_color = Color(0.95, 0.6, 0.8)
	flower_mat.emission_enabled = true
	flower_mat.emission = Color(0.9, 0.4, 0.7)
	flower_mat.emission_energy_multiplier = 0.8
	var buoy_mat := StandardMaterial3D.new()
	buoy_mat.albedo_color = Color(0.85, 0.2, 0.12)
	buoy_mat.emission_enabled = true
	buoy_mat.emission = Color(0.85, 0.2, 0.1)
	buoy_mat.emission_energy_multiplier = 0.6
	for ri in range(26):
		var ang := TAU * float(ri) / 26.0
		var rr := 68.0 + float((ri * 13) % 7)
		var rx := lake_center.x + cos(ang) * rr
		var rz := lake_center.z + sin(ang) * rr * 0.9
		if ri % 3 == 0:
			# Reed cluster: 3 crossed blades.
			for bi in range(3):
				var blade := MeshInstance3D.new()
				var bm := BoxMesh.new()
				bm.size = Vector3(0.12, 1.6 + float(bi) * 0.3, 0.12)
				bm.material = reed_mat
				blade.mesh = bm
				blade.position = Vector3(rx + float(bi - 1) * 0.35, lake_center.y + 0.7, rz)
				blade.rotation.z = float(bi - 1) * 0.12
				lake.add_child(blade)
		elif ri % 3 == 1:
			# Lily pad + flower.
			var pad := MeshInstance3D.new()
			var cm := CylinderMesh.new()
			cm.top_radius = 0.7
			cm.bottom_radius = 0.7
			cm.height = 0.08
			cm.material = lily_mat
			pad.mesh = cm
			pad.position = Vector3(rx, lake_center.y + 0.1, rz)
			lake.add_child(pad)
			if ri % 2 == 0:
				var fl := MeshInstance3D.new()
				var sm := SphereMesh.new()
				sm.radius = 0.18
				sm.height = 0.36
				sm.material = flower_mat
				fl.mesh = sm
				fl.position = Vector3(rx, lake_center.y + 0.3, rz)
				lake.add_child(fl)
		else:
			# Mooring buoy with blinking lamp.
			var buoy := MeshInstance3D.new()
			var bsm := SphereMesh.new()
			bsm.radius = 0.4
			bsm.height = 0.8
			bsm.material = buoy_mat
			buoy.mesh = bsm
			buoy.position = Vector3(rx, lake_center.y + 0.25, rz)
			lake.add_child(buoy)
			var bl := OmniLight3D.new()
			bl.light_color = Color(1.0, 0.3, 0.15)
			bl.light_energy = 0.8
			bl.omni_range = 6.0
			bl.position = Vector3(rx, lake_center.y + 0.9, rz)
			lake.add_child(bl)

	var label := Label3D.new()
	label.text = "THE BLACK LAKE — HOGWARTS BOATHOUSE & DOCKS"
	label.font_size = 38
	label.modulate = Color(0.5, 0.85, 1.0)
	label.outline_size = 8
	label.outline_modulate = Color(0, 0, 0)
	label.billboard = BaseMaterial3D.BILLBOARD_ENABLED
	label.position = lake_center + Vector3(0, 14.0, 0)
	lake.add_child(label)

static func _add_box_col(parent: Node3D, pos: Vector3, size: Vector3) -> void:
	var sb := StaticBody3D.new()
	sb.collision_layer = 1
	sb.collision_mask = 0
	var col := CollisionShape3D.new()
	var box := BoxShape3D.new()
	box.size = size
	col.shape = box
	sb.add_child(col)
	sb.position = pos
	parent.add_child(sb)

# ---------------------------------------------------------------- quidditch

static func _build_quidditch_pitch(world: Node3D) -> void:
	var pitch := Node3D.new()
	pitch.name = "QuidditchPitch"
	pitch.position = Vector3(280, 0, 20)
	world.add_child(pitch)
	var grass := MeshInstance3D.new()
	var pm := PlaneMesh.new()
	var gm := PBR.surface("grass_ground_01", PBR.MEADOW_TINT, {"metres": 8.0, "rough_min": 0.88})
	pm.size = Vector2(90, 55)
	pm.material = gm
	grass.mesh = pm
	grass.position.y = 0.03
	pitch.add_child(grass)
	_add_box_col(pitch, Vector3(0, -0.45, 0), Vector3(90, 1.0, 55))

	var ring := MeshInstance3D.new()
	var tm := TorusMesh.new()
	tm.inner_radius = 7.5
	tm.outer_radius = 8.0
	tm.material = PBR.surface("stone_tiles_02")
	ring.mesh = tm
	ring.rotation.x = PI * 0.5
	ring.position.y = 0.08
	pitch.add_child(ring)

	# 6 gold goal hoops
	var gold := MaterialKitScript.gold_material()
	for side in [-1, 1]:
		for h_i in range(3):
			var pole := MeshInstance3D.new()
			var cm := CylinderMesh.new()
			cm.top_radius = 0.16
			cm.bottom_radius = 0.16
			cm.height = 9.0 + h_i * 2.5
			cm.material = PBR.surface("dark_wooden_planks")
			pole.mesh = cm
			pole.position = Vector3(side * 36.0, (9.0 + h_i * 2.5) * 0.5, (h_i - 1) * 7.5)
			pitch.add_child(pole)
			var hoop := MeshInstance3D.new()
			var tor := TorusMesh.new()
			tor.inner_radius = 1.3
			tor.outer_radius = 1.6
			tor.material = gold
			hoop.mesh = tor
			hoop.position = Vector3(side * 36.0, 9.0 + h_i * 2.5, (h_i - 1) * 7.5)
			hoop.rotation.y = PI * 0.5
			pitch.add_child(hoop)

	# 4 House Spectator Towers (Gryffindor, Slytherin, Ravenclaw, Hufflepuff)
	var house_data := [
		{"name": "Gryffindor", "pos": Vector3(-32, 0, -24), "color": Color(0.78, 0.08, 0.12)},
		{"name": "Slytherin", "pos": Vector3(-32, 0, 24), "color": Color(0.08, 0.45, 0.18)},
		{"name": "Ravenclaw", "pos": Vector3(32, 0, -24), "color": Color(0.08, 0.28, 0.58)},
		{"name": "Hufflepuff", "pos": Vector3(32, 0, 24), "color": Color(0.92, 0.72, 0.15)}
	]
	var wood := PBR.surface("dark_wooden_planks")
	for hd in house_data:
		var tower := Node3D.new()
		tower.position = hd["pos"]
		pitch.add_child(tower)
		for c_x in [-1.6, 1.6]:
			for c_z in [-1.6, 1.6]:
				var col := MeshInstance3D.new()
				var ccm := BoxMesh.new()
				ccm.size = Vector3(0.35, 12.0, 0.35)
				ccm.material = wood
				col.mesh = ccm
				col.position = Vector3(c_x, 6.0, c_z)
				tower.add_child(col)
		var plat := MeshInstance3D.new()
		var pbm := BoxMesh.new()
		pbm.size = Vector3(4.2, 0.4, 4.2)
		pbm.material = wood
		plat.mesh = pbm
		plat.position.y = 10.0
		tower.add_child(plat)
		var troof := MeshInstance3D.new()
		var rpm := PrismMesh.new()
		rpm.size = Vector3(4.8, 3.0, 4.8)
		var t_mat := StandardMaterial3D.new()
		t_mat.albedo_color = hd["color"]
		troof.mesh = rpm
		troof.material_override = t_mat
		troof.position.y = 13.5
		tower.add_child(troof)
		var ban := MeshInstance3D.new()
		var bpm := PlaneMesh.new()
		bpm.size = Vector2(2.0, 4.5)
		ban.mesh = bpm
		ban.material_override = t_mat
		ban.position = Vector3(0, 7.5, 2.15)
		ban.add_to_group("castle_banners")
		tower.add_child(ban)

	var label := Label3D.new()
	label.text = "QUIDDITCH STADIUM — EASTERN MOORS"
	label.font_size = 40
	label.modulate = Color(1.0, 0.9, 0.4)
	label.outline_size = 8
	label.outline_modulate = Color(0, 0, 0)
	label.billboard = BaseMaterial3D.BILLBOARD_ENABLED
	label.position = Vector3(0, 16, 0)
	pitch.add_child(label)
	# Finished stadium dressing: scoreboard, changing tents, equipment racks.
	var board := MeshInstance3D.new()
	var bbm := BoxMesh.new()
	bbm.size = Vector3(8.0, 4.0, 0.4)
	var bmat := StandardMaterial3D.new()
	bmat.albedo_color = Color(0.12, 0.1, 0.08)
	bmat.emission_enabled = true
	bmat.emission = Color(1.0, 0.85, 0.4)
	bmat.emission_energy_multiplier = 0.35
	bbm.material = bmat
	board.mesh = bbm
	board.position = Vector3(0, 6.0, -30.0)
	pitch.add_child(board)
	var board_lbl := Label3D.new()
	board_lbl.text = "GRYFFINDOR 120 : 80 SLYTHERIN"
	board_lbl.font_size = 30
	board_lbl.modulate = Color(1.0, 0.9, 0.5)
	board_lbl.outline_size = 6
	board_lbl.outline_modulate = Color(0, 0, 0)
	board_lbl.position = Vector3(0, 6.2, -29.6)
	pitch.add_child(board_lbl)
	_add_box_col(pitch, Vector3(0, 3.0, -30.0), Vector3(8.0, 6.0, 0.6))
	for ti in range(2):
		var tent := MeshInstance3D.new()
		var tpm := PrismMesh.new()
		tpm.size = Vector3(5.0, 2.8, 6.0)
		var tmat := StandardMaterial3D.new()
		tmat.albedo_color = Color(0.85, 0.82, 0.75) if ti == 0 else Color(0.2, 0.25, 0.4)
		tent.mesh = tpm
		tent.material_override = tmat
		tent.position = Vector3(-50.0 + float(ti) * 100.0, 1.4, 18.0)
		pitch.add_child(tent)
		_add_box_col(pitch, Vector3(-50.0 + float(ti) * 100.0, 1.4, 18.0), Vector3(5.0, 2.8, 6.0))

# ---------------------------------------------------------------- highlands stone circle

static func _build_highlands_circle(world: Node3D) -> void:
	var highlands := Node3D.new()
	highlands.name = "HighlandsStoneCircle"
	highlands.position = Vector3(350, 0, -70)
	world.add_child(highlands)

	var stone := PBR.surface("stone_ashlar_01", Color(0.75, 0.72, 0.68))
	var circle_radius: float = 14.0

	# Plateau ground: the circle sits at 6m, mesh origin at 0.
	var base_y := 6.0
	var floor_m := MeshInstance3D.new()
	var fbm := CylinderMesh.new()
	fbm.top_radius = 18.0
	fbm.bottom_radius = 18.5
	fbm.height = 0.5
	fbm.material = PBR.surface("grass_ground_01", PBR.MEADOW_TINT, {"metres": 8.0})
	floor_m.mesh = fbm
	floor_m.position.y = base_y - 0.2
	highlands.add_child(floor_m)
	_add_box_col(highlands, Vector3(0, base_y - 0.4, 0), Vector3(36, 0.8, 36))

	# 12 megalith standing stones, all footed on the plateau.
	for i in range(12):
		var angle := TAU * float(i) / 12.0
		var pos := Vector3(cos(angle) * circle_radius, 0, sin(angle) * circle_radius)
		var megalith := MeshInstance3D.new()
		var mm := BoxMesh.new()
		var h := 4.5 + float((i * 7) % 5) * 0.4
		mm.size = Vector3(1.6, h, 0.9)
		mm.material = stone
		megalith.mesh = mm
		megalith.position = pos + Vector3(0, base_y + h * 0.5 - 0.2, 0)
		megalith.rotation.y = angle + PI * 0.5
		highlands.add_child(megalith)
		_add_box_col(highlands, pos + Vector3(0, base_y + h * 0.5, 0), Vector3(1.6, h, 0.9))

	# Central runic altar
	var altar := MeshInstance3D.new()
	var am := CylinderMesh.new()
	am.top_radius = 3.6
	am.bottom_radius = 4.0
	am.height = 0.8
	am.material = stone
	altar.mesh = am
	altar.position.y = base_y + 0.4
	highlands.add_child(altar)
	_add_box_col(highlands, Vector3(0, base_y + 0.4, 0), Vector3(7.0, 0.8, 7.0))

	# Floating cyan rune crystal
	var cry := MeshInstance3D.new()
	var cm := PrismMesh.new()
	cm.size = Vector3(1.0, 2.4, 1.0)
	var cmat := StandardMaterial3D.new()
	cmat.albedo_color = Color(0.3, 0.85, 1.0)
	cmat.emission_enabled = true
	cmat.emission = Color(0.3, 0.9, 1.0)
	cmat.emission_energy_multiplier = 2.5
	cry.mesh = cm
	cry.material_override = cmat
	cry.position.y = base_y + 2.8
	highlands.add_child(cry)

	var cl := OmniLight3D.new()
	cl.light_color = Color(0.35, 0.85, 1.0)
	cl.light_energy = 2.5
	cl.omni_range = 18.0
	cl.position.y = base_y + 3.0
	highlands.add_child(cl)
	# Rune braziers between every third stone: finished circle, not bare rocks.
	for bi in range(4):
		var ang := TAU * float(bi) / 4.0 + 0.26
		var bx := cos(ang) * 9.0
		var bz := sin(ang) * 9.0
		_torch(highlands, Vector3(bx, base_y, bz))

	var label := Label3D.new()
	label.text = "ANCIENT MEGALITHS — HIGHLANDS OVERLOOK"
	label.font_size = 36
	label.modulate = Color(0.5, 0.9, 1.0)
	label.outline_size = 8
	label.outline_modulate = Color(0, 0, 0)
	label.billboard = BaseMaterial3D.BILLBOARD_ENABLED
	label.position = Vector3(0, base_y + 8.0, 0)
	highlands.add_child(label)

# ---------------------------------------------------------------- smuggler's ridge

static func _build_smugglers_ridge(world: Node3D, rng: RandomNumberGenerator) -> void:
	var ridge := Node3D.new()
	ridge.name = "SmugglersRidge"
	ridge.position = Vector3(180, 0, -160)
	world.add_child(ridge)

	var wood := PBR.surface("dark_wooden_planks")
	var stone := PBR.surface("stone_ashlar_01", Color(0.5, 0.5, 0.52))

	# Ruined watchtower, footed on the 0.5m plateau with a timber platform.
	var tower := PBR.kit_instance("wall_module_4x6_damaged")
	if tower:
		tower.position = Vector3(0, 0.5, 0)
		tower.scale = Vector3(1.2, 1.2, 1.2)
		ridge.add_child(tower)
	_add_box_col(ridge, Vector3(0, 1.5, 0), Vector3(4.5, 3.0, 1.5))

	# Spiked timber palisades
	for pi in range(8):
		var p := MeshInstance3D.new()
		var pm := CylinderMesh.new()
		pm.top_radius = 0.05
		pm.bottom_radius = 0.2
		pm.height = 3.2
		pm.material = wood
		p.mesh = pm
		p.position = Vector3(-8.0 + float(pi) * 2.2, 0.5 + 1.6, 6.0)
		ridge.add_child(p)

	# Dark snatcher campfires and tents
	for ti in range(3):
		var tent := MeshInstance3D.new()
		var tm := PrismMesh.new()
		tm.size = Vector3(4.0, 2.5, 4.5)
		var tmat := StandardMaterial3D.new()
		tmat.albedo_color = Color(0.2, 0.16, 0.14)
		tent.mesh = tm
		tent.material_override = tmat
		tent.position = Vector3(float(ti - 1) * 8.0, 0.5 + 1.25, -6.0)
		ridge.add_child(tent)
		_add_box_col(ridge, Vector3(float(ti - 1) * 8.0, 0.5 + 1.0, -6.0), Vector3(4.0, 2.0, 4.5))

	# Bone bonfire with purple flame
	var fire := Node3D.new()
	fire.position = Vector3(0, 0.5, 0)
	ridge.add_child(fire)
	var flame := MeshInstance3D.new()
	var fmesh := SphereMesh.new()
	fmesh.radius = 0.5
	fmesh.height = 1.1
	var fmat := StandardMaterial3D.new()
	fmat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	fmat.albedo_color = Color(0.7, 0.25, 1.0)
	fmesh.material = fmat
	flame.mesh = fmesh
	flame.position.y = 0.8
	flame.add_to_group("torch_flames")
	fire.add_child(flame)
	# Supply crates + barrels: the camp reads as occupied, not a bare spawn.
	for ci in range(4):
		var crate := MeshInstance3D.new()
		var cbm := BoxMesh.new()
		cbm.size = Vector3(0.9, 0.9, 0.9)
		cbm.material = wood
		crate.mesh = cbm
		crate.position = Vector3(-6.0 + float(ci) * 1.2, 0.5 + 0.45, -2.5)
		crate.rotation.y = 0.3 * float(ci)
		ridge.add_child(crate)
	var fl := OmniLight3D.new()
	fl.light_color = Color(0.7, 0.2, 0.95)
	fl.light_energy = 2.4
	fl.omni_range = 22.0
	fl.position.y = 1.5
	fire.add_child(fl)

	var label := Label3D.new()
	label.text = "SMUGGLER'S RIDGE — DARK STRONGHOLD"
	label.font_size = 36
	label.modulate = Color(0.8, 0.4, 0.95)
	label.outline_size = 8
	label.outline_modulate = Color(0, 0, 0)
	label.billboard = BaseMaterial3D.BILLBOARD_ENABLED
	label.position = Vector3(0, 0.5 + 7.5, 0)
	ridge.add_child(label)

# ---------------------------------------------------------------- lamps / fences

static func _lamp(parent: Node3D, pos: Vector3, snap_to_ground: bool = true) -> void:
	# Snap lamp feet to the ground so hillside lamps are never buried/floating.
	# Bridge/dock lamps pass snap_to_ground=false because their pos is already
	# relative to a deck.
	var snapped := pos
	if snap_to_ground:
		snapped = Vector3(pos.x, OutdoorTerrain.ground_y(pos.x, pos.z), pos.z)
	var l := Node3D.new()
	l.position = snapped
	parent.add_child(l)
	var pole := MeshInstance3D.new()
	var cm := CylinderMesh.new()
	cm.top_radius = 0.09
	cm.bottom_radius = 0.12
	cm.height = 3.4
	var iron := StandardMaterial3D.new()
	iron.albedo_color = Color(0.08, 0.08, 0.1)
	iron.metallic = 0.7
	iron.roughness = 0.4
	cm.material = iron
	pole.mesh = cm
	pole.position.y = 1.7
	l.add_child(pole)
	var bulb := MeshInstance3D.new()
	var sm := SphereMesh.new()
	sm.radius = 0.28
	sm.height = 0.56
	var bm := StandardMaterial3D.new()
	bm.albedo_color = Color(1, 0.9, 0.6)
	bm.emission_enabled = true
	bm.emission = Color(1, 0.82, 0.45)
	bm.emission_energy_multiplier = 3.0
	sm.material = bm
	bulb.mesh = sm
	bulb.position.y = 3.55
	l.add_child(bulb)
	var omni := OmniLight3D.new()
	omni.light_color = Color(1.0, 0.82, 0.5)
	omni.light_energy = 1.6
	omni.omni_range = 12.0
	omni.position.y = 3.6
	l.add_child(omni)

static func _build_lamps_and_fences(world: Node3D, rng: RandomNumberGenerator) -> void:
	var props := Node3D.new()
	props.name = "Props"
	world.add_child(props)
	var lamp_spots := [
		Vector3(3, 0, 2), Vector3(-3, 0, 2), Vector3(2, 0, -12),
		Vector3(-2, 0, -12), Vector3(2, 0, -28), Vector3(-2, 0, -28),
		Vector3(12, 0, 8), Vector3(30, 0, 14), Vector3(-14, 0, 10),
		# Expanded road lamps
		Vector3(50, 0, 18), Vector3(70, 0, 24), Vector3(90, 0, 28),
		Vector3(-50, 0, 18), Vector3(-70, 0, 18),
		Vector3(-40, 0, 36), Vector3(-55, 0, 52), Vector3(-70, 0, 68),
		Vector3(50, 0, 35), Vector3(75, 0, 48),
		Vector3(120, 0, 20), Vector3(180, 0, 12),
		Vector3(75, 0, -70), Vector3(120, 0, -110),
	]
	for p in lamp_spots:
		_lamp(props, p)
	var wood := PBR.surface("dark_wooden_planks")
	for i in range(-8, 9):
		if abs(i) < 2:
			continue
		for z in [12.0]:
			var fx := float(i) * 2.0
			var post := MeshInstance3D.new()
			var bm := BoxMesh.new()
			bm.size = Vector3(0.25, 1.1, 0.25)
			bm.material = wood
			post.mesh = bm
			post.position = Vector3(fx, OutdoorTerrain.ground_y(fx, z) + 0.55, z)
			props.add_child(post)
	var rail := MeshInstance3D.new()
	var rm := BoxMesh.new()
	rm.size = Vector3(34, 0.15, 0.15)
	rm.material = wood
	rail.mesh = rm
	rail.position = Vector3(0, 0.9, 12)
	props.add_child(rail)

# ------------------------------------------------------- level dressing

static func _build_level_dressing(world: Node3D, rng: RandomNumberGenerator) -> void:
	var dz := Node3D.new()
	dz.name = "LevelDressing"
	world.add_child(dz)
	var stone := PBR.surface("stone_ashlar_01", Color(1.0, 1.0, 1.0), {"metres": 4.0})
	var wood := MaterialKitScript.wood_material()
	for side in [-1, 1]:
		var pillar := MeshInstance3D.new()
		var pm := BoxMesh.new()
		pm.size = Vector3(1.2, 6.0, 1.2)
		pm.material = stone
		pillar.mesh = pm
		pillar.position = Vector3(side * 3.2, 3.0, -14)
		dz.add_child(pillar)
	var beam := MeshInstance3D.new()
	var bm := BoxMesh.new()
	bm.size = Vector3(8.0, 1.0, 1.4)
	bm.material = wood
	beam.mesh = bm
	beam.position = Vector3(0, 6.4, -14)
	dz.add_child(beam)
	var arch_label := Label3D.new()
	arch_label.text = "HOGWARTS ↑   •   FOREST ←"
	arch_label.font_size = 32
	arch_label.outline_size = 8
	arch_label.outline_modulate = Color(0, 0, 0)
	arch_label.billboard = BaseMaterial3D.BILLBOARD_ENABLED
	arch_label.position = Vector3(0, 7.6, -14)
	dz.add_child(arch_label)
	var ruin_spots := [Vector3(28, 0, -40), Vector3(39, 0, -20), Vector3(-39, 0, -23)]
	for rs in ruin_spots:
		for i in range(4):
			var wall := MeshInstance3D.new()
			var wm := BoxMesh.new()
			wm.size = Vector3(rng.randf_range(1.5, 3.0), rng.randf_range(1.5, 3.5), 0.6)
			wm.material = stone
			wall.mesh = wm
			wall.position = rs + Vector3(rng.randf_range(-5, 5), wm.size.y * 0.5, rng.randf_range(-4, 4))
			wall.rotation.y = rng.randf_range(0, TAU)
			dz.add_child(wall)
		for i in range(3):
			var cry := MeshInstance3D.new()
			var cm := PrismMesh.new()
			cm.size = Vector3(0.5, rng.randf_range(1.2, 2.2), 0.5)
			var cmat := StandardMaterial3D.new()
			cmat.albedo_color = Color(0.45, 0.15, 0.8)
			cmat.emission_enabled = true
			cmat.emission = Color(0.6, 0.2, 1.0)
			cmat.emission_energy_multiplier = 1.6
			cm.material = cmat
			cry.mesh = cm
			cry.position = rs + Vector3(rng.randf_range(-3, 3), 0.8, rng.randf_range(-3, 3))
			cry.rotation.z = rng.randf_range(-0.25, 0.25)
			dz.add_child(cry)
	# Hogsmeade market stalls (4 colorful stalls)
	var stall_specs := [
		{"pos": Vector3(31, 0, 21), "color": Color(0.75, 0.2, 0.2)},
		{"pos": Vector3(38, 0, 21), "color": Color(0.2, 0.35, 0.65)},
		{"pos": Vector3(47, 0, 23), "color": Color(0.18, 0.55, 0.22)},
		{"pos": Vector3(54, 0, 23), "color": Color(0.85, 0.65, 0.15)}
	]
	for si in range(stall_specs.size()):
		var spec: Dictionary = stall_specs[si]
		var stall := Node3D.new()
		stall.position = spec["pos"]
		stall.rotation.y = -0.4 + float(si) * 0.2
		dz.add_child(stall)
		var counter := MeshInstance3D.new()
		var ccm := BoxMesh.new()
		ccm.size = Vector3(3.0, 1.0, 1.6)
		ccm.material = wood
		counter.mesh = ccm
		counter.position.y = 0.5
		stall.add_child(counter)
		for pi in range(2):
			var pole := MeshInstance3D.new()
			var plm := CylinderMesh.new()
			plm.top_radius = 0.07
			plm.bottom_radius = 0.07
			plm.height = 2.4
			plm.material = wood
			pole.mesh = plm
			pole.position = Vector3(-1.3 + pi * 2.6, 1.6, 0)
			stall.add_child(pole)
		var awn := MeshInstance3D.new()
		var awm := BoxMesh.new()
		awm.size = Vector3(3.6, 0.12, 2.2)
		var awmat := StandardMaterial3D.new()
		awmat.albedo_color = spec["color"]
		awm.material = awmat
		awn.mesh = awm
		awn.position.y = 2.8
		awn.rotation.x = 0.15
		stall.add_child(awn)
		# Goods on the counter: potion bottles, produce sacks, folded cloth.
		var bottle_mat := StandardMaterial3D.new()
		bottle_mat.albedo_color = Color(0.3, 0.6, 0.9)
		bottle_mat.emission_enabled = true
		bottle_mat.emission = Color(0.2, 0.45, 0.8)
		bottle_mat.emission_energy_multiplier = 0.7
		for gi in range(3):
			var goods := MeshInstance3D.new()
			var gm := BoxMesh.new()
			if gi == 2:
				gm.size = Vector3(0.7, 0.5, 0.6)
				gm.material = wood
			else:
				gm.size = Vector3(0.22, 0.45, 0.22)
				gm.material = bottle_mat
			goods.mesh = gm
			goods.position = Vector3(-0.9 + float(gi) * 0.9, 1.25 if gi != 2 else 1.3, 0.1)
			stall.add_child(goods)
		_add_box_col(stall, Vector3(0, 0.5, 0), Vector3(3.0, 1.0, 1.6))
	for tz in [-6.0, -18.0, -30.0]:
		for side in [-1, 1]:
			_torch(dz, Vector3(side * 3.0, 0, tz))
	var banner_cols := [Color(0.78, 0.08, 0.12), Color(0.08, 0.45, 0.18), Color(0.08, 0.28, 0.58), Color(0.92, 0.72, 0.15)]
	for i in range(4):
		var b := MeshInstance3D.new()
		var bmesh := PlaneMesh.new()
		bmesh.size = Vector2(1.2, 2.4)
		var bmat := StandardMaterial3D.new()
		bmat.albedo_color = banner_cols[i]
		bmat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
		bmesh.material = bmat
		b.mesh = bmesh
		b.position = Vector3(-6 + i * 4.0, 12.0, -49.5)
		dz.add_child(b)
		b.add_to_group("castle_banners")
	for i in range(5):
		var plank := MeshInstance3D.new()
		var plm := BoxMesh.new()
		plm.size = Vector3(2.4, 0.15, 0.9)
		plm.material = wood
		plank.mesh = plm
		plank.position = Vector3(-30 + 0.0, 0.25, 22 + i * 1.0)
		dz.add_child(plank)
	preload("res://scripts/world/distant_ridges.gd").build(dz)

static func _torch(parent: Node3D, pos: Vector3) -> void:
	var t := Node3D.new()
	t.position = pos
	parent.add_child(t)
	var pole := MeshInstance3D.new()
	var cm := CylinderMesh.new()
	cm.top_radius = 0.07
	cm.bottom_radius = 0.09
	cm.height = 2.2
	var iron := StandardMaterial3D.new()
	iron.albedo_color = Color(0.1, 0.08, 0.06)
	cm.material = iron
	pole.mesh = cm
	pole.position.y = 1.1
	t.add_child(pole)
	var flame := MeshInstance3D.new()
	var sm := SphereMesh.new()
	sm.radius = 0.16
	sm.height = 0.32
	var fm := StandardMaterial3D.new()
	fm.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	fm.albedo_color = Color(1.0, 0.6, 0.15)
	sm.material = fm
	flame.mesh = sm
	flame.position.y = 2.35
	flame.add_to_group("torch_flames")
	t.add_child(flame)
	var l := OmniLight3D.new()
	l.light_color = Color(1.0, 0.62, 0.25)
	l.light_energy = 1.3
	l.omni_range = 9.0
	l.position.y = 2.4
	l.add_to_group("torch_lights")
	t.add_child(l)

# ---------------------------------------------------------------- candles / stars

static func _build_floating_candles(world: Node3D) -> void:
	var candles := Node3D.new()
	candles.name = "FloatingCandles"
	candles.position = Vector3(0, 0, -58)
	world.add_child(candles)
	for i in range(40):
		var c := MeshInstance3D.new()
		var cm := CylinderMesh.new()
		cm.top_radius = 0.06
		cm.bottom_radius = 0.06
		cm.height = 0.35
		var wm := StandardMaterial3D.new()
		wm.albedo_color = Color(0.95, 0.9, 0.8)
		wm.emission_enabled = true
		wm.emission = Color(1.0, 0.85, 0.5)
		wm.emission_energy_multiplier = 1.5
		cm.material = wm
		c.mesh = cm
		var rng_pos := Vector3(randf_range(-14, 14), randf_range(6, 12), randf_range(-6, 10))
		c.position = rng_pos
		candles.add_child(c)
		c.set_meta("base_y", rng_pos.y)
		c.set_meta("phase", randf() * TAU)
	candles.add_to_group("floating_candles")

static func _build_stars_and_moon(world: Node3D) -> void:
	var moon := MeshInstance3D.new()
	moon.name = "Moon"
	var sm := SphereMesh.new()
	sm.radius = 8.0
	sm.height = 16.0
	var mm := StandardMaterial3D.new()
	mm.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	mm.albedo_color = Color(0.95, 0.95, 0.85)
	sm.material = mm
	moon.mesh = sm
	moon.position = Vector3(-280, 160, -420)
	world.add_child(moon)
	var ml := DirectionalLight3D.new()
	ml.name = "MoonLight"
	ml.light_color = Color(0.7, 0.8, 1.0)
	ml.light_energy = 0.35
	ml.rotation_degrees = Vector3(-50, -30, 0)
	world.add_child(ml)

# ------------------------------------------------------ broom landing

static func _build_broom_landing(world: Node3D) -> void:
	var pad := Node3D.new()
	pad.name = "BroomLanding"
	pad.position = Vector3(0, 0, -40)
	world.add_child(pad)
	var disc := MeshInstance3D.new()
	var cm := CylinderMesh.new()
	cm.top_radius = 4.0
	cm.bottom_radius = 4.2
	cm.height = 0.12
	cm.material = PBR.surface("stone_tiles_02")
	disc.mesh = cm
	disc.position.y = -0.04
	pad.add_child(disc)
	var ring := MeshInstance3D.new()
	var tm := TorusMesh.new()
	tm.inner_radius = 3.4
	tm.outer_radius = 3.7
	tm.material = MaterialKitScript.gold_material()
	ring.mesh = tm
	ring.rotation.x = PI * 0.5
	ring.position.y = 0.03
	pad.add_child(ring)
	for i in range(4):
		var angle := PI * 0.25 + TAU * float(i) / 4.0
		var post := MeshInstance3D.new()
		var bm := BoxMesh.new()
		bm.size = Vector3(0.22, 1.2, 0.22)
		bm.material = PBR.surface("dark_wooden_planks")
		post.mesh = bm
		post.position = Vector3(cos(angle) * 4.3, 0.6, sin(angle) * 4.3)
		pad.add_child(post)
	var lamp := OmniLight3D.new()
	lamp.light_color = Color(1.0, 0.85, 0.5)
	lamp.light_energy = 1.2
	lamp.omni_range = 14.0
	lamp.position.y = 2.4
	pad.add_child(lamp)
	var label := Label3D.new()
	label.text = "BROOM LANDING\nDISMOUNT BEFORE ENTERING"
	label.font_size = 30
	label.outline_size = 8
	label.outline_modulate = Color(0, 0, 0)
	label.billboard = BaseMaterial3D.BILLBOARD_ENABLED
	label.position = Vector3(3.2, 3.6, 1.6)
	pad.add_child(label)

# ---------------------------------------------------------------- boundaries

static func _build_world_boundaries(world: Node3D) -> void:
	var bounds := Node3D.new()
	bounds.name = "WorldBoundaries"
	world.add_child(bounds)

	var half_size: float = 500.0 # 1000m x 1000m world boundary (4x area expansion)
	var wall_height: float = 70.0
	var wall_thickness: float = 12.0

	var wall_specs = [
		{"pos": Vector3(0, wall_height * 0.5, -half_size), "size": Vector3(half_size * 2, wall_height, wall_thickness)},
		{"pos": Vector3(0, wall_height * 0.5, half_size), "size": Vector3(half_size * 2, wall_height, wall_thickness)},
		{"pos": Vector3(-half_size, wall_height * 0.5, 0), "size": Vector3(wall_thickness, wall_height, half_size * 2)},
		{"pos": Vector3(half_size, wall_height * 0.5, 0), "size": Vector3(wall_thickness, wall_height, half_size * 2)}
	]

	var barrier_mat := StandardMaterial3D.new()
	barrier_mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	barrier_mat.albedo_color = Color(0.15, 0.55, 1.0, 0.12)
	barrier_mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	barrier_mat.cull_mode = BaseMaterial3D.CULL_DISABLED

	for spec in wall_specs:
		var sb := StaticBody3D.new()
		sb.collision_layer = 1
		sb.collision_mask = 3
		sb.position = spec["pos"]
		bounds.add_child(sb)

		var col := CollisionShape3D.new()
		var box := BoxShape3D.new()
		box.size = spec["size"]
		col.shape = box
		sb.add_child(col)

		var mesh_inst := MeshInstance3D.new()
		var bm := BoxMesh.new()
		bm.size = spec["size"]
		bm.material = barrier_mat
		mesh_inst.mesh = bm
		mesh_inst.visible = false
		sb.add_child(mesh_inst)
