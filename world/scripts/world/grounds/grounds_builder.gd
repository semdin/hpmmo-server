extends RefCounted
class_name GroundsBuilder

## Builds the outdoor map ("grounds") into the game world: sky and sun, the
## Terrain3D ground, the Black Lake, the castle shell, the courtyard, the sites
## (Hogsmeade, Hagrid's hut...), vegetation colliders, a far horizon and the map
## edge. Replaces the old procedural valley (world_builder.gd / outdoor_terrain.gd).
##
## The terrain is the world's ground collider and stays loaded for the life of the
## world (the server simulates bodies on it whichever map a client shows). The
## scenery listed in BUILT_NODES is what map transfer frees and rebuilds:
## `teardown()` before the castle interior loads, `build()` when the player
## comes back out. On a headless process (dedicated server, tests) visuals are
## skipped but every collider is built, so client and server collide alike.

const QualityPreset = preload("res://scripts/world/quality_preset.gd")
const PBR = preload("res://scripts/assets/pbr_kit.gd")
const TERRAIN_SCENE := preload("res://scenes/world/grounds_terrain.tscn")

const TERRAIN_NODE := "GroundsTerrain"
## Scenery freed by teardown(); the terrain is not in this list on purpose.
const BUILT_NODES := ["HogwartsCastle", "Courtyard", "BroomLanding", "Sites", "Lake",
	"VegetationColliders", "WorldBoundaries", "Horizon", "RoadLamps", "SafeZoneWards"]

## The broom landing pad (maps.json `castle_door.landing` / `castle_landing_pad`).
const LANDING_PAD := Vector2(40.0, 15.0)
const LANDING_RADIUS := 4.0
## Map edge: invisible walls just inside the terrain's 2048 m square.
const EDGE := 1010.0


static func is_headless() -> bool:
	return DisplayServer.get_name() == "headless"


static func build(world: Node3D) -> void:
	if world.has_node("HogwartsCastle"):
		return
	var visuals := not is_headless()
	var terrain := ensure_terrain(world)
	terrain.visible = true
	_apply_sky_and_sun(world)
	CastleExterior.build(world, visuals)
	_courtyard(world, visuals)
	_broom_landing(world, visuals)
	GroundsSites.build_all(world, visuals)
	if visuals:
		var lake := Node3D.new()
		lake.name = "Lake"
		world.add_child(lake)
		GroundsLake.build(lake)
		GroundsHorizon.build(world)
		_road_lamps(world)
	var colliders := Node3D.new()
	colliders.name = "VegetationColliders"
	world.add_child(colliders)
	GroundsScatter.build_colliders(colliders)
	_boundaries(world)
	_ward_lines(world)
	QualityPreset.apply(world)


## The persistent ground. Created once per world.
static func ensure_terrain(world: Node3D) -> GroundsTerrain:
	var t := world.get_node_or_null(TERRAIN_NODE) as GroundsTerrain
	if t == null:
		t = TERRAIN_SCENE.instantiate()
		t.name = TERRAIN_NODE
		world.add_child(t)
	return t


static func teardown(world: Node3D) -> void:
	if world == null or not is_instance_valid(world):
		return
	for node_name in BUILT_NODES:
		var node := world.get_node_or_null(node_name)
		if node == null:
			continue
		world.remove_child(node)
		node.queue_free()
	# Inside the castle nothing of the grounds is visible; the ground keeps its
	# collision (other players are still out there on the server).
	var t := world.get_node_or_null(TERRAIN_NODE) as Node3D
	if t:
		t.visible = false


# ------------------------------------------------------------------ sky

static func _apply_sky_and_sun(world: Node3D) -> void:
	var env_node := world.get_node_or_null("WorldEnvironment") as WorldEnvironment
	if env_node and env_node.environment:
		var env := env_node.environment
		env.background_mode = Environment.BG_SKY
		if env.sky == null:
			env.sky = Sky.new()
		var sky_mat := env.sky.sky_material as ProceduralSkyMaterial
		if sky_mat == null:
			sky_mat = ProceduralSkyMaterial.new()
			env.sky.sky_material = sky_mat
		sky_mat.sky_top_color = Color(0.24, 0.35, 0.49)
		sky_mat.sky_horizon_color = Color(0.60, 0.66, 0.72)
		sky_mat.ground_bottom_color = Color(0.20, 0.23, 0.22)
		sky_mat.ground_horizon_color = Color(0.46, 0.52, 0.55)
		sky_mat.sun_angle_max = 3.0
		env.ambient_light_source = Environment.AMBIENT_SOURCE_SKY
		env.ambient_light_energy = 0.62
		env.tonemap_mode = Environment.TONE_MAPPER_ACES
		env.tonemap_exposure = 0.86
		# A 2 km valley: light exponential fog plus aerial perspective, and a
		# height falloff so the view from a broom stays clear above the haze.
		env.fog_enabled = true
		env.fog_mode = Environment.FOG_MODE_EXPONENTIAL
		env.fog_light_color = Color(0.66, 0.73, 0.80)
		env.fog_light_energy = 1.0
		env.fog_density = 0.00032
		env.fog_height = 40.0
		env.fog_height_density = 0.004
		env.fog_aerial_perspective = 0.35
		env.fog_sky_affect = 0.25
		env.glow_enabled = true
		env.glow_intensity = 0.16
		env.glow_bloom = 0.0
		env.glow_hdr_threshold = 1.35
		env.glow_blend_mode = Environment.GLOW_BLEND_MODE_ADDITIVE
		env.ssao_enabled = true
		env.ssao_intensity = 1.35
		env.ssao_radius = 0.9
	var sun := world.get_node_or_null("DirectionalLight3D") as DirectionalLight3D
	if sun:
		sun.light_color = Color(1.0, 0.96, 0.89)
		# Softer sun with a weaker specular lobe: the bare rock faces were
		# blowing out to near-white at grazing angles.
		sun.light_energy = 0.95
		sun.light_specular = 0.25
		sun.shadow_enabled = true
		sun.rotation_degrees = Vector3(-38, -30, 0)
		sun.directional_shadow_mode = DirectionalLight3D.SHADOW_PARALLEL_4_SPLITS
		sun.directional_shadow_max_distance = 180.0
		sun.directional_shadow_blend_splits = true
		sun.shadow_normal_bias = 0.8


# ------------------------------------------------------------- courtyard

## The courtyard before the castle doors: a fountain, Ollivander's stall, benches
## and the four house pillars with banners.
static func _courtyard(world: Node3D, visuals: bool) -> void:
	GroundsCourtyard.build(world, visuals)


static func _broom_landing(world: Node3D, visuals: bool) -> void:
	var p := GroundsLayout.ground(LANDING_PAD.x, LANDING_PAD.y)
	var pad := Node3D.new()
	pad.name = "BroomLanding"
	pad.position = p
	world.add_child(pad)
	if not visuals:
		return
	var disc := MeshInstance3D.new()
	var cm := CylinderMesh.new()
	cm.top_radius = LANDING_RADIUS
	cm.bottom_radius = LANDING_RADIUS + 0.2
	cm.height = 0.5
	cm.material = PBR.surface("stone_tiles_02")
	disc.mesh = cm
	disc.position.y = -0.18
	pad.add_child(disc)
	var ring := MeshInstance3D.new()
	var tm := TorusMesh.new()
	tm.inner_radius = LANDING_RADIUS - 0.6
	tm.outer_radius = LANDING_RADIUS - 0.3
	var gold := StandardMaterial3D.new()
	gold.albedo_color = Color(0.95, 0.75, 0.25)
	gold.metallic = 0.9
	gold.roughness = 0.25
	gold.emission_enabled = true
	gold.emission = Color(0.9, 0.65, 0.2)
	gold.emission_energy_multiplier = 0.4
	tm.material = gold
	ring.mesh = tm
	ring.position.y = 0.1
	pad.add_child(ring)
	var label := Label3D.new()
	label.text = "BROOM LANDING"
	label.font_size = 30
	label.outline_size = 8
	label.outline_modulate = Color(0, 0, 0)
	label.billboard = BaseMaterial3D.BILLBOARD_ENABLED
	label.position = Vector3(0, 3.2, 0)
	pad.add_child(label)


## Lamp posts along the roads near the castle and Hogsmeade (positions baked by
## art/map/scripts/scatter.py into scatter/lamp.bin).
static func _road_lamps(world: Node3D) -> void:
	var data := GroundsScatter.instances("lamp")
	var root := Node3D.new()
	root.name = "RoadLamps"
	world.add_child(root)
	var kit := ArchKit.new(false)
	for i in data.size() / 5:
		var o := i * 5
		var at := Vector3(data[o], data[o + 1], data[o + 2])
		kit.box(at + Vector3(0, 1.6, 0), Vector3(0.16, 3.2, 0.16), 0.0, "metal", false)
		kit.box(at + Vector3(0, 3.35, 0), Vector3(0.45, 0.5, 0.45), 0.0, "glass", false)
		kit.pyramid(at + Vector3(0, 3.6, 0), Vector2(0.55, 0.55), 0.35, 0.0, "metal", 0.05)
		var l := OmniLight3D.new()
		l.light_color = Color(1.0, 0.78, 0.48)
		l.light_energy = 0.9
		l.omni_range = 9.0
		l.distance_fade_enabled = true
		l.distance_fade_begin = 90.0
		l.distance_fade_length = 30.0
		l.position = at + Vector3(0, 3.3, 0)
		l.add_to_group("torch_lights")
		root.add_child(l)
	kit.finish(root, GroundsSites.materials(), "LampPosts", 1, true)


## Invisible walls at the map edge (the mountain ring is the visual boundary;
## these stop a body that flies or climbs past it).
static func _boundaries(world: Node3D) -> void:
	var bounds := Node3D.new()
	bounds.name = "WorldBoundaries"
	world.add_child(bounds)
	var h := 500.0
	for spec in [
		[Vector3(0, h * 0.5 - 50.0, -EDGE - 10.0), Vector3(EDGE * 2 + 40, h, 20)],
		[Vector3(0, h * 0.5 - 50.0, EDGE + 10.0), Vector3(EDGE * 2 + 40, h, 20)],
		[Vector3(-EDGE - 10.0, h * 0.5 - 50.0, 0), Vector3(20, h, EDGE * 2 + 40)],
		[Vector3(EDGE + 10.0, h * 0.5 - 50.0, 0), Vector3(20, h, EDGE * 2 + 40)],
	]:
		var sb := StaticBody3D.new()
		sb.collision_layer = 1
		sb.collision_mask = 0
		sb.position = spec[0]
		var col := CollisionShape3D.new()
		var box := BoxShape3D.new()
		box.size = spec[1]
		col.shape = box
		sb.add_child(col)
		bounds.add_child(sb)


## The safe zones' edges: a band of slowly turning gold runes that follows
## the ground, with a low veil of light standing on it, so a player can see
## where enemies will not follow without a hard neon line across the grass.
static func _ward_lines(world: Node3D) -> void:
	var root := Node3D.new()
	root.name = "SafeZoneWards"
	world.add_child(root)
	if is_headless():
		return
	var zones: Array = []
	if GameData != null and GameData.get("SAFE_ZONES") is Dictionary:
		zones = (GameData.SAFE_ZONES as Dictionary).get("zones", [])
	var shader := preload("res://assets/shaders/safe_ward.gdshader")
	var rune: Texture2D = load("res://assets/fx/rune_band.png")
	var band := ShaderMaterial.new()
	band.shader = shader
	band.set_shader_parameter("rune", rune)
	var veil := ShaderMaterial.new()
	veil.shader = shader
	veil.set_shader_parameter("veil", true)
	const BAND := 1.1          # metres across the rune band
	const TILE := BAND * 5.14  # the rune strip is 5.14:1
	const VEIL_H := 2.6
	for zone in zones:
		var radius := float(zone.get("radius", 0.0))
		var c: Array = zone.get("center", [0.0, 0.0, 0.0])
		var cx := float(c[0])
		var cz := float(c[2]) if c.size() > 2 else 0.0
		var segs := maxi(64, int(TAU * radius / 1.2))
		# whole tiles round the ring, so the runes meet without a seam
		var tiles := maxf(1.0, round(TAU * radius / TILE))
		var ring := SurfaceTool.new()
		ring.begin(Mesh.PRIMITIVE_TRIANGLES)
		var wall := SurfaceTool.new()
		wall.begin(Mesh.PRIMITIVE_TRIANGLES)
		var prev: Array = []
		for i in segs + 1:
			var a := TAU * i / segs
			var dir := Vector3(cos(a), 0, sin(a))
			var u := tiles * float(i) / segs
			var pin := GroundsLayout.ground(cx + dir.x * (radius - BAND), cz + dir.z * (radius - BAND)) + Vector3.UP * 0.06
			var pout := GroundsLayout.ground(cx + dir.x * radius, cz + dir.z * radius) + Vector3.UP * 0.06
			var top := pout + Vector3.UP * VEIL_H
			if i > 0:
				var pu: float = prev[3]
				for v in [[prev[0], pu, 0.0], [prev[1], pu, 1.0], [pout, u, 1.0], [prev[0], pu, 0.0], [pout, u, 1.0], [pin, u, 0.0]]:
					ring.set_normal(Vector3.UP)
					ring.set_uv(Vector2(v[1], v[2]))
					ring.add_vertex(v[0])
				# veil UV.x: tenths of the arc in metres (the shader's streak columns)
				var wu := pu * TILE * 0.1
				var wv := u * TILE * 0.1
				for v in [[prev[1], wu, 0.0], [prev[2], wu, 1.0], [top, wv, 1.0], [prev[1], wu, 0.0], [top, wv, 1.0], [pout, wv, 0.0]]:
					wall.set_normal(dir)
					wall.set_uv(Vector2(v[1], v[2]))
					wall.add_vertex(v[0])
			prev = [pin, pout, top, u]
		var id := String(zone.get("id", "zone"))
		for spec in [["WardRunes_%s" % id, ring, band], ["WardVeil_%s" % id, wall, veil]]:
			var node := MeshInstance3D.new()
			node.name = spec[0]
			node.mesh = (spec[1] as SurfaceTool).commit()
			node.material_override = spec[2]
			node.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
			root.add_child(node)
