extends RefCounted

const MaterialKitScript = preload("res://scripts/assets/material_kit.gd")

## Builds a real wizarding valley: castle, village, forest, lake,
## quidditch pitch, paths, lamps, fences, floating candles, stars.
## All procedural so no external binary assets are needed.


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
	_build_forbidden_forest(world, rng)
	_build_black_lake(world)
	_build_quidditch_pitch(world)
	_build_lamps_and_fences(world, rng)
	_build_level_dressing(world, rng)
	_build_floating_candles(world)
	_build_stars_and_moon(world)
	_build_world_boundaries(world)

# ---------------------------------------------------------------- sky

static func _apply_sky_and_fog(world: Node3D) -> void:
	var env_node := world.get_node_or_null("WorldEnvironment")
	if env_node and env_node is WorldEnvironment:
		var env: Environment = (env_node as WorldEnvironment).environment
		if env:
			env.background_mode = Environment.BG_SKY
			# Golden-hour grade: warm sun, cool shadows, crystal-clear horizons
			var sky_mat := env.sky.sky_material as ProceduralSkyMaterial
			if sky_mat:
				sky_mat.sky_top_color = Color(0.12, 0.29, 0.52)
				sky_mat.sky_horizon_color = Color(0.62, 0.76, 0.88)
				sky_mat.ground_bottom_color = Color(0.08, 0.10, 0.12)
				sky_mat.ground_horizon_color = Color(0.35, 0.42, 0.49)
				sky_mat.sun_angle_max = 14.0
			
			# Fog Removal & Horizon Clarity (Section 8.1 of plan.md):
			# Reduced by 92% from 0.008 to 0.0006 for pristine horizons and distant castle visibility
			env.fog_enabled = false
			env.fog_light_color = Color(0.75, 0.68, 0.60)
			env.fog_density = 0.0006
			env.fog_aerial_perspective = 0.08
			env.fog_sky_affect = 0.15
			
			# Lighting & Filmic Post-Processing (Section 8.2 of plan.md):
			env.glow_enabled = true
			env.glow_intensity = 0.35
			env.glow_bloom = 0.04
			env.glow_blend_mode = Environment.GLOW_BLEND_MODE_ADDITIVE
			env.tonemap_mode = Environment.TONE_MAPPER_ACES
			env.tonemap_exposure = 1.15
			env.ambient_light_source = Environment.AMBIENT_SOURCE_SKY
			env.ambient_light_energy = 0.95
			env.adjustment_enabled = true
			env.adjustment_saturation = 1.05
			env.adjustment_contrast = 1.02
			env.ssao_enabled = true
			env.ssao_intensity = 1.2
			env.ssr_enabled = false
			env.ssr_max_steps = 64
	
	# Directional Sunlight: Golden hour rim lighting with 4-split shadow cascades (Section 8.2)
	var sun := world.get_node_or_null("DirectionalLight3D") as DirectionalLight3D
	if sun:
		sun.light_color = Color(1.0, 0.93, 0.8)
		sun.light_energy = 1.35
		sun.shadow_enabled = true
		sun.rotation_degrees = Vector3(-38, -32, 0)
		sun.directional_shadow_mode = DirectionalLight3D.SHADOW_PARALLEL_4_SPLITS
		sun.directional_shadow_max_distance = 110.0

# ---------------------------------------------------------------- terrain

static func _reskin_terrain(world: Node3D) -> void:
	var grass_mesh := world.get_node_or_null("Terrain/GrassMesh")
	if grass_mesh and grass_mesh is MeshInstance3D:
		(grass_mesh as MeshInstance3D).set_surface_override_material(0, 	MaterialKitScript.grass_material())
		# enlarge play area feel: keep 200x200 but add outer meadow ring
	var meadow := MeshInstance3D.new()
	meadow.name = "OuterMeadow"
	var pm := PlaneMesh.new()
	pm.size = Vector2(600, 600)
	pm.material = 	MaterialKitScript.meadow_material()
	meadow.mesh = pm
	meadow.position = Vector3(0, -0.62, 0)
	world.add_child(meadow)

	var court := world.get_node_or_null("Terrain/Courtyard")
	if court and court is MeshInstance3D:
		(court as MeshInstance3D).set_surface_override_material(0, 	MaterialKitScript.cobble_material())

# ---------------------------------------------------------------- paths

static func _cobble_path(parent: Node3D, from: Vector3, to: Vector3, width: float = 3.0) -> void:
	var dir := to - from
	var length := Vector2(dir.x, dir.z).length()
	if length < 0.5:
		return
	var mid := (from + to) * 0.5
	mid.y = 0.02
	var path := MeshInstance3D.new()
	var pm := PlaneMesh.new()
	pm.size = Vector2(width, length)
	pm.material = 	MaterialKitScript.cobble_material()
	path.mesh = pm
	path.position = mid
	path.rotation.y = atan2(dir.x, dir.z)
	parent.add_child(path)

static func _build_paths(world: Node3D) -> void:
	var paths := Node3D.new()
	paths.name = "StonePaths"
	world.add_child(paths)
	# courtyard -> castle, village, lake, pitch, forest edge
	_cobble_path(paths, Vector3(0, 0, 5), Vector3(0, 0, -47), 6.0)
	_cobble_path(paths, Vector3(0, 0, 5), Vector3(38, 0, 14), 3.0)
	_cobble_path(paths, Vector3(0, 0, 5), Vector3(-34, 0, 18), 3.0)
	_cobble_path(paths, Vector3(0, 0, -20), Vector3(-52, 0, -52), 2.5)
	_cobble_path(paths, Vector3(0, 0, -20), Vector3(55, 0, -55), 2.5)

# ---------------------------------------------------------------- castle

static func _build_courtyard_details(world: Node3D) -> void:
	var forge := world.get_node_or_null("OllivanderWorkshop")
	if forge:
		forge.position = Vector3(8, 0.5, 5)
	# fountain
	var fountain := Node3D.new()
	fountain.name = "CourtyardFountain"
	fountain.position = Vector3(-9, 0, 6)
	world.add_child(fountain)
	var base := MeshInstance3D.new()
	var base_mesh := CylinderMesh.new()
	base_mesh.top_radius = 2.4
	base_mesh.bottom_radius = 2.8
	base_mesh.height = 1.0
	base_mesh.material = 	MaterialKitScript.cobble_material()
	base.mesh = base_mesh
	base.position.y = 0.5
	fountain.add_child(base)
	var water := MeshInstance3D.new()
	var water_mesh := CylinderMesh.new()
	water_mesh.top_radius = 2.2
	water_mesh.bottom_radius = 2.2
	water_mesh.height = 0.2
	water_mesh.material = 	MaterialKitScript.water_material()
	water.mesh = water_mesh
	water.position.y = 1.0
	fountain.add_child(water)
	var pillar := MeshInstance3D.new()
	var pillar_mesh := CylinderMesh.new()
	pillar_mesh.top_radius = 0.3
	pillar_mesh.bottom_radius = 0.45
	pillar_mesh.height = 2.2
	pillar_mesh.material = 	MaterialKitScript.castle_wall_material()
	pillar.mesh = pillar_mesh
	pillar.position.y = 1.6
	fountain.add_child(pillar)
	var fl := OmniLight3D.new()
	fl.light_color = Color(0.4, 0.7, 1.0)
	fl.light_energy = 1.2
	fl.omni_range = 8.0
	fl.position.y = 2.6
	fountain.add_child(fl)

# ---------------------------------------------------------------- village

static func _hut(parent: Node3D, pos: Vector3, rot_y: float, wall_mat: Material, roof_mat: Material, wood_mat: Material) -> void:
	var hut := Node3D.new()
	hut.position = pos
	hut.rotation.y = rot_y
	parent.add_child(hut)
	var body := MeshInstance3D.new()
	var bm := BoxMesh.new()
	bm.size = Vector3(6, 3.4, 5)
	bm.material = wall_mat
	body.mesh = bm
	body.position.y = 1.7
	hut.add_child(body)
	var roof := MeshInstance3D.new()
	var prism := PrismMesh.new()
	prism.size = Vector3(7, 2.4, 6)
	prism.material = roof_mat
	roof.mesh = prism
	roof.position.y = 4.6
	hut.add_child(roof)
	var door := MeshInstance3D.new()
	var dm := BoxMesh.new()
	dm.size = Vector3(1.2, 2.2, 0.2)
	dm.material = wood_mat
	door.mesh = dm
	door.position = Vector3(0, 1.1, 2.55)
	hut.add_child(door)
	# warm window
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
	var wall_mat := 	MaterialKitScript.castle_wall_material()
	var roof_mat := 	MaterialKitScript.wood_material()
	var wood_mat := 	MaterialKitScript.wood_material()
	var spots := [
		[Vector3(34, 0, 16), 0.4], [Vector3(42, 0, 10), -0.5],
		[Vector3(38, 0, 24), 2.8], [Vector3(28, 0, 24), -2.6],
		[Vector3(-30, 0, 20), 0.9], [Vector3(-38, 0, 14), -0.8],
		[Vector3(-34, 0, 28), 3.0],
	]
	for s in spots:
		_hut(village, s[0], s[1], wall_mat, roof_mat, wood_mat)
	var label := Label3D.new()
	label.text = "HOGSMEADE"
	label.font_size = 40
	label.outline_size = 8
	label.outline_modulate = Color(0, 0, 0)
	label.billboard = BaseMaterial3D.BILLBOARD_ENABLED
	label.position = Vector3(35, 8, 18)
	village.add_child(label)

# ---------------------------------------------------------------- forest

static func _tree(parent: Node3D, pos: Vector3, trunk_mat: Material, leaf_mat: Material, s: float) -> void:
	var t := Node3D.new()
	t.position = pos
	parent.add_child(t)
	var trunk := MeshInstance3D.new()
	var cm := CylinderMesh.new()
	cm.top_radius = 0.28 * s
	cm.bottom_radius = 0.5 * s
	cm.height = 3.2 * s
	cm.material = trunk_mat
	trunk.mesh = cm
	trunk.position.y = 1.6 * s
	t.add_child(trunk)
	for i in range(3):
		var fol := MeshInstance3D.new()
		var sm := SphereMesh.new()
		sm.radius = (1.7 - i * 0.35) * s
		sm.height = (2.2 - i * 0.3) * s
		sm.material = leaf_mat
		fol.mesh = sm
		fol.position.y = (3.4 + i * 1.1) * s
		t.add_child(fol)

static func _build_forbidden_forest(world: Node3D, rng: RandomNumberGenerator) -> void:
	var forest := Node3D.new()
	forest.name = "ForbiddenForest"
	world.add_child(forest)
	var trunk_mat := 	MaterialKitScript.bark_material()
	var leaf_mat := 	MaterialKitScript.leaf_material()
	# dense cluster west + north-west
	for i in range(110):
		var x := rng.randf_range(-85, -38)
		var z := rng.randf_range(-70, -12)
		# keep monolith clearing
		if Vector2(x + 45, z + 28).length() < 9.0:
			continue
		var s := rng.randf_range(0.8, 1.7)
		_tree(forest, Vector3(x, 0, z), trunk_mat, leaf_mat, s)
	# a few lone pines east
	for i in range(18):
		var x := rng.randf_range(48, 80)
		var z := rng.randf_range(-60, 0)
		_tree(forest, Vector3(x, 0, z), trunk_mat, leaf_mat, rng.randf_range(0.9, 1.5))
	var label := Label3D.new()
	label.text = "FORBIDDEN FOREST"
	label.font_size = 36
	label.modulate = Color(0.6, 1.0, 0.6)
	label.outline_size = 8
	label.outline_modulate = Color(0, 0, 0)
	label.billboard = BaseMaterial3D.BILLBOARD_ENABLED
	label.position = Vector3(-60, 9, -40)
	forest.add_child(label)
	# spooky green light deep in forest
	var gl := OmniLight3D.new()
	gl.light_color = Color(0.3, 1.0, 0.4)
	gl.light_energy = 1.6
	gl.omni_range = 22.0
	gl.position = Vector3(-60, 4, -42)
	forest.add_child(gl)

# ---------------------------------------------------------------- lake

static func _build_black_lake(world: Node3D) -> void:
	var lake := Node3D.new()
	lake.name = "BlackLake"
	lake.position = Vector3(-38, 0, 30)
	world.add_child(lake)
	var water := MeshInstance3D.new()
	var pm := PlaneMesh.new()
	pm.size = Vector2(30, 22)
	pm.material = 	MaterialKitScript.water_material()
	water.mesh = pm
	water.position.y = 0.05
	lake.add_child(water)
	# sandy rim
	var rim := MeshInstance3D.new()
	var rim_mesh := CylinderMesh.new()
	rim_mesh.top_radius = 17.0
	rim_mesh.bottom_radius = 18.5
	rim_mesh.height = 0.35
	rim_mesh.material = 	MaterialKitScript.cobble_material()
	rim.mesh = rim_mesh
	rim.position.y = -0.1
	lake.add_child(rim)
	var label := Label3D.new()
	label.text = "BLACK LAKE"
	label.font_size = 36
	label.modulate = Color(0.5, 0.85, 1.0)
	label.outline_size = 8
	label.outline_modulate = Color(0, 0, 0)
	label.billboard = BaseMaterial3D.BILLBOARD_ENABLED
	label.position = Vector3(0, 6, 0)
	lake.add_child(label)

# ---------------------------------------------------------------- quidditch

static func _build_quidditch_pitch(world: Node3D) -> void:
	var pitch := Node3D.new()
	pitch.name = "QuidditchPitch"
	pitch.position = Vector3(52, 0, 26)
	world.add_child(pitch)
	var grass := MeshInstance3D.new()
	var pm := PlaneMesh.new()
	var gm := 	MaterialKitScript.meadow_material()
	pm.size = Vector2(36, 22)
	pm.material = gm
	grass.mesh = pm
	grass.position.y = 0.03
	pitch.add_child(grass)
	# center circle (torus flat)
	var ring := MeshInstance3D.new()
	var tm := TorusMesh.new()
	tm.inner_radius = 4.6
	tm.outer_radius = 5.0
	tm.material = 	MaterialKitScript.cobble_material()
	ring.mesh = tm
	ring.rotation.x = PI * 0.5
	ring.position.y = 0.08
	pitch.add_child(ring)
	# 6 goal hoops
	var gold := 	MaterialKitScript.gold_material()
	for side in [-1, 1]:
		for h_i in range(3):
			var pole := MeshInstance3D.new()
			var cm := CylinderMesh.new()
			cm.top_radius = 0.12
			cm.bottom_radius = 0.12
			cm.height = 6.0 + h_i * 1.6
			cm.material = 	MaterialKitScript.wood_material()
			pole.mesh = cm
			pole.position = Vector3(side * 16.0, (6.0 + h_i * 1.6) * 0.5, (h_i - 1) * 5.0)
			pitch.add_child(pole)
			var hoop := MeshInstance3D.new()
			var tor := TorusMesh.new()
			tor.inner_radius = 0.85
			tor.outer_radius = 1.0
			tor.material = gold
			hoop.mesh = tor
			hoop.position = Vector3(side * 16.0, 6.0 + h_i * 1.6, (h_i - 1) * 5.0)
			hoop.rotation.y = PI * 0.5
			pitch.add_child(hoop)
	var label := Label3D.new()
	label.text = "QUIDDITCH PITCH"
	label.font_size = 36
	label.modulate = Color(1.0, 0.9, 0.4)
	label.outline_size = 8
	label.outline_modulate = Color(0, 0, 0)
	label.billboard = BaseMaterial3D.BILLBOARD_ENABLED
	label.position = Vector3(0, 10, 0)
	pitch.add_child(label)

# ---------------------------------------------------------------- lamps / fences

static func _lamp(parent: Node3D, pos: Vector3) -> void:
	var l := Node3D.new()
	l.position = pos
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
	]
	for p in lamp_spots:
		_lamp(props, p)
	# fence line around courtyard
	var wood := 	MaterialKitScript.wood_material()
	for i in range(-8, 9):
		if abs(i) < 2:
			continue # gate opening
		for z in [12.0]:
			var post := MeshInstance3D.new()
			var bm := BoxMesh.new()
			bm.size = Vector3(0.25, 1.1, 0.25)
			bm.material = wood
			post.mesh = bm
			post.position = Vector3(i * 2.0, 0.55, z)
			props.add_child(post)
	var rail := MeshInstance3D.new()
	var rm := BoxMesh.new()
	rm.size = Vector3(34, 0.15, 0.15)
	rm.material = wood
	rail.mesh = rm
	rail.position = Vector3(0, 0.9, 12)
	props.add_child(rail)

# ------------------------------------------------------- level dressing
# Original set dressing (own art): forest arch, ruins + crystals, market
# stalls, torches, banners, dock, mountains, grass tufts / rocks / flowers.

static func _build_level_dressing(world: Node3D, rng: RandomNumberGenerator) -> void:
	var dz := Node3D.new()
	dz.name = "LevelDressing"
	world.add_child(dz)
	var stone := MaterialKitScript.castle_wall_material()
	var wood := MaterialKitScript.wood_material()
	# -- forest arch gate (west path): two pillars + beam + hanging lantern
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
	# -- ruins + crystals near each monolith approach (cover + landmark)
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
		# dark crystal cluster (emissive landmark)
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
	# -- Hogsmeade market stalls (2) with striped awnings
	for si in range(2):
		var stall := Node3D.new()
		stall.position = Vector3(31 + si * 7.0, 0, 21)
		stall.rotation.y = -0.4 + si * 0.3
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
		awmat.albedo_color = Color(0.75, 0.2, 0.2) if si == 0 else Color(0.2, 0.35, 0.65)
		awm.material = awmat
		awn.mesh = awm
		awn.position.y = 2.8
		awn.rotation.x = 0.15
		stall.add_child(awn)
	# -- torches along main castle road (flicker handled by game_world)
	for tz in [-6.0, -18.0, -30.0]:
		for side in [-1, 1]:
			_torch(dz, Vector3(side * 3.0, 0, tz))
	# -- castle banners (house colors) on gate pillars
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
	# -- lake dock (planks + posts)
	for i in range(5):
		var plank := MeshInstance3D.new()
		var plm := BoxMesh.new()
		plm.size = Vector3(2.4, 0.15, 0.9)
		plm.material = wood
		plank.mesh = plm
		plank.position = Vector3(-30 + 0.0, 0.25, 22 + i * 1.0)
		dz.add_child(plank)
	preload("res://scripts/world/distant_ridges.gd").build(dz)
	# -- scatter: grass tufts (crossed planes), rocks, flowers — cheap but rich
	var leaf := MaterialKitScript.leaf_material()
	for i in range(160):
		var tuft := MeshInstance3D.new()
		var tm := PlaneMesh.new()
		tm.size = Vector2(0.7, 0.5)
		tm.material = leaf
		tuft.mesh = tm
		tuft.position = Vector3(rng.randf_range(-90, 90), 0.25, rng.randf_range(-70, 45))
		if tuft.position.distance_to(Vector3(0, 0, 5)) < 12.0 or (absf(tuft.position.x) < 40 and tuft.position.z < -38):
			tuft.free()
			continue # keep courtyard clean
		tuft.rotation.y = rng.randf_range(0, TAU)
		dz.add_child(tuft)
	for i in range(50):
		var rock := MeshInstance3D.new()
		var rm := SphereMesh.new()
		rm.radius = rng.randf_range(0.25, 0.8)
		rm.height = rm.radius * 1.2
		rm.material = stone
		rock.mesh = rm
		rock.position = Vector3(rng.randf_range(-90, 90), 0.15, rng.randf_range(-70, 45))
		if absf(rock.position.x) < 40 and rock.position.z < -38:
			rock.free()
			continue
		rock.scale.y = 0.6
		dz.add_child(rock)
	for i in range(60):
		var fl := MeshInstance3D.new()
		var fm := SphereMesh.new()
		fm.radius = 0.09
		fm.height = 0.18
		var fmat := StandardMaterial3D.new()
		fmat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
		var petals := [Color(1, 0.4, 0.5), Color(1, 0.9, 0.3), Color(0.7, 0.5, 1.0), Color(1, 1, 1)]
		fmat.albedo_color = petals[i % petals.size()]
		fm.material = fmat
		fl.mesh = fm
		fl.position = Vector3(rng.randf_range(-60, 60), 0.35, rng.randf_range(-40, 35))
		dz.add_child(fl)

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
	# animate in game_world _process via group
	candles.add_to_group("floating_candles")

static func _build_stars_and_moon(world: Node3D) -> void:
	# moon
	var moon := MeshInstance3D.new()
	var sm := SphereMesh.new()
	sm.radius = 6.0
	sm.height = 12.0
	var mm := StandardMaterial3D.new()
	mm.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	mm.albedo_color = Color(0.95, 0.95, 0.85)
	sm.material = mm
	moon.mesh = sm
	moon.position = Vector3(-140, 110, -220)
	world.add_child(moon)
	var ml := DirectionalLight3D.new()
	ml.light_color = Color(0.7, 0.8, 1.0)
	ml.light_energy = 0.35
	ml.rotation_degrees = Vector3(-50, -30, 0)
	world.add_child(ml)

# ---------------------------------------------------------------- boundaries

static func _build_world_boundaries(world: Node3D) -> void:
	var bounds := Node3D.new()
	bounds.name = "WorldBoundaries"
	world.add_child(bounds)

	var half_size: float = 250.0 # 500m x 500m world boundary
	var wall_height: float = 60.0
	var wall_thickness: float = 8.0

	var wall_specs = [
		{"pos": Vector3(0, wall_height * 0.5, -half_size), "size": Vector3(half_size * 2, wall_height, wall_thickness)}, # North
		{"pos": Vector3(0, wall_height * 0.5, half_size), "size": Vector3(half_size * 2, wall_height, wall_thickness)},  # South
		{"pos": Vector3(-half_size, wall_height * 0.5, 0), "size": Vector3(wall_thickness, wall_height, half_size * 2)}, # West
		{"pos": Vector3(half_size, wall_height * 0.5, 0), "size": Vector3(wall_thickness, wall_height, half_size * 2)}   # East
	]

	# Glowing ancient magical barrier effect (Section 7.2 of plan.md)
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

		# Visual subtle shimmering blue ancient ward barrier
		var mesh_inst := MeshInstance3D.new()
		var bm := BoxMesh.new()
		bm.size = spec["size"]
		bm.material = barrier_mat
		mesh_inst.mesh = bm
		mesh_inst.visible = false
		sb.add_child(mesh_inst)
