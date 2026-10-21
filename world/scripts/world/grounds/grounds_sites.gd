extends RefCounted
class_name GroundsSites

## Buildings and set dressing at the grounds' landmarks: Hogsmeade, Hagrid's hut,
## the greenhouses, the boathouse and its stair, the station, the Quidditch pitch,
## the highland stone circle, the smugglers' camp, the crypt and the spider hollow.
##
## Positions come from GroundsLayout (the same layout.json the terrain was built
## from). Each site is one ArchKit batch: a few draw calls and one collision body.
## Every footing is founded down to the lowest ground under it.

const PBR = preload("res://scripts/assets/pbr_kit.gd")

static var _mats: Dictionary = {}


static func materials() -> Dictionary:
	if not _mats.is_empty():
		return _mats
	var glass := ShaderMaterial.new()
	# Leaded glass mirroring the sky, with warm rooms behind some of the panes
	# (per-window random from ArchKit.window()).
	glass.shader = preload("res://assets/shaders/castle/window_lit.gdshader")
	glass.set_shader_parameter("quarry_m", 0.22)
	var glasshouse := StandardMaterial3D.new()
	glasshouse.albedo_color = Color(0.70, 0.82, 0.78, 0.28)
	glasshouse.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	glasshouse.roughness = 0.05
	glasshouse.metallic_specular = 0.9
	glasshouse.cull_mode = BaseMaterial3D.CULL_DISABLED
	var pumpkin := StandardMaterial3D.new()
	pumpkin.albedo_color = Color(0.85, 0.42, 0.08)
	pumpkin.roughness = 0.6
	var metal := StandardMaterial3D.new()
	metal.albedo_color = Color(0.16, 0.16, 0.17)
	metal.metallic = 0.8
	metal.roughness = 0.45
	var gold := StandardMaterial3D.new()
	gold.albedo_color = Color(0.85, 0.66, 0.25)
	gold.metallic = 0.9
	gold.roughness = 0.3
	var dark := StandardMaterial3D.new()
	dark.albedo_color = Color(0.03, 0.03, 0.035)
	dark.roughness = 1.0
	_mats = {
		"stone": PBR.surface("castle_wall_varriation", Color(0.95, 0.93, 0.90), {"metres": 4.0}),
		"rubble": PBR.surface("stone_wall", Color(0.85, 0.84, 0.82), {"metres": 4.0}),
		"mossy": PBR.surface("mossy_stone_wall", Color(0.9, 0.92, 0.88), {"metres": 3.0}),
		"plaster": PBR.surface("white_rough_plaster", Color(0.93, 0.90, 0.84), {"metres": 3.0}),
		"timber": PBR.surface("medieval_wood", Color(0.46, 0.38, 0.31), {"metres": 2.0}),
		"wood": PBR.surface("wooden_planks", Color(0.80, 0.70, 0.60), {"metres": 2.5}),
		"roof": PBR.surface("roof_slates_02", Color(0.46, 0.50, 0.60), {"metres": 3.0}),
		"roof_warm": PBR.surface("grey_roof_tiles", Color(0.80, 0.70, 0.62), {"metres": 3.0}),
		"cobble": PBR.surface("cobblestone_floor_04", Color(0.9, 0.9, 0.9), {"metres": 4.0}),
		"trim": PBR.surface("stone_wall", Color(0.86, 0.86, 0.86), {"metres": 3.0}),
		"glass": glass,
		"glasshouse": glasshouse,
		"pumpkin": pumpkin,
		"metal": metal,
		"gold": gold,
		"dark": dark,
		"cloth_red": _cloth(Color(0.55, 0.08, 0.08)),
		"cloth_blue": _cloth(Color(0.10, 0.20, 0.48)),
		"cloth_green": _cloth(Color(0.10, 0.36, 0.18)),
		"cloth_yellow": _cloth(Color(0.85, 0.65, 0.12)),
		"canvas": _cloth(Color(0.55, 0.50, 0.40)),
	}
	return _mats


static func _cloth(c: Color) -> StandardMaterial3D:
	var m := StandardMaterial3D.new()
	m.albedo_color = c
	m.roughness = 0.9
	m.cull_mode = BaseMaterial3D.CULL_DISABLED
	return m


static func build_all(parent: Node3D, visuals: bool) -> void:
	var root := Node3D.new()
	root.name = "Sites"
	parent.add_child(root)
	_hogsmeade(root, visuals)
	_hagrid(root, visuals)
	_greenhouses(root, visuals)
	_boathouse(root, visuals)
	_station(root, visuals)
	_quidditch(root, visuals)
	_stone_circle(root, visuals)
	_smugglers_camp(root, visuals)
	_crypt(root, visuals)
	_spider_hollow(root, visuals)
	# Village and site meshes end at the preset's site range (QualityPreset.apply):
	# a quidditch tower 900 m off is a few pixels and still a draw call.
	for node in root.find_children("*", "GeometryInstance3D", true, false):
		node.add_to_group("site_geometry")


# --------------------------------------------------------------- buildings

## A Hogsmeade cottage: stone ground floor, plastered timber-framed upper floor,
## steep slate roof, chimney, lit windows, a door on the street side (+z local).
static func cottage(kit: ArchKit, c: Vector2, rot: float, w: float, d: float, floors: int, roof_key: String = "roof", tall: bool = false) -> Vector3:
	var span := GroundsLayout.ground_span(c, Vector2(w + 1, d + 1), rot)
	var floor_y := span.y + 0.1
	var basis := Basis(Vector3.UP, rot)
	var at := func(x: float, y: float, z: float) -> Vector3:
		return Vector3(c.x, 0, c.y) + basis * Vector3(x, 0, z) + Vector3.UP * y
	var storey := 3.3
	var base := span.x - 1.0
	# plinth/ground floor in stone, founded into the slope
	kit.box(at.call(0, (base + floor_y + storey) * 0.5, 0), Vector3(w, floor_y + storey - base, d), rot, "stone")
	var y := floor_y + storey
	for f in floors - 1:
		kit.box(at.call(0, y + storey * 0.5, 0), Vector3(w + 0.5, storey, d + 0.5), rot, "plaster")
		# timber frame: posts and a rail
		for i in 5:
			var x := -w * 0.5 - 0.25 + i * (w + 0.5) / 4.0
			kit.box(at.call(x, y + storey * 0.5, d * 0.5 + 0.28), Vector3(0.22, storey, 0.1), rot, "timber", false)
			kit.box(at.call(x, y + storey * 0.5, -d * 0.5 - 0.28), Vector3(0.22, storey, 0.1), rot, "timber", false)
		kit.box(at.call(0, y + 0.1, d * 0.5 + 0.3), Vector3(w + 0.6, 0.25, 0.12), rot, "timber", false)
		kit.box(at.call(0, y + 0.1, -d * 0.5 - 0.3), Vector3(w + 0.6, 0.25, 0.12), rot, "timber", false)
		y += storey
	var roof_h := (d * 0.85) if not tall else d * 1.15
	kit.gable(at.call(0, y, 0), Vector2(w + 0.6, d + 0.6), roof_h, rot, roof_key, "plaster" if floors > 1 else "stone", 0.9)
	# chimney
	kit.box(at.call(w * 0.32, y + roof_h * 0.7, -d * 0.18), Vector3(0.9, roof_h * 1.1, 0.9), rot, "stone", false)
	# door and windows on the street face, windows at the back and the ends
	kit.box(at.call(0, floor_y + 1.15, d * 0.5 + 0.06), Vector3(1.3, 2.3, 0.15), rot, "wood", false)
	kit.box(at.call(0, floor_y + 2.45, d * 0.5 + 0.1), Vector3(1.7, 0.25, 0.25), rot, "timber", false)
	var n_front := basis * Vector3(0, 0, 1)
	var n_back := basis * Vector3(0, 0, -1)
	for f in floors:
		var wy := floor_y + 1.7 + f * storey
		for sx in [-1, 1]:
			var x: float = sx * w * 0.3
			if f == 0 and absf(x) < 1.2:
				continue
			kit.window(at.call(x, wy, d * 0.5 + (0.25 if f > 0 else 0.0)), n_front, 0.9, 1.2, "timber", "glass")
			kit.window(at.call(x, wy, -d * 0.5 - (0.25 if f > 0 else 0.0)), n_back, 0.9, 1.2, "timber", "glass")
	# doorstep
	kit.box(at.call(0, floor_y - 0.12, d * 0.5 + 0.7), Vector3(1.8, 0.3, 1.0), rot, "stone")
	return at.call(0, floor_y, d * 0.5 + 1.5)


static func _lamp_light(parent: Node3D, pos: Vector3, energy: float = 1.2, rng: float = 9.0) -> void:
	var l := OmniLight3D.new()
	l.light_color = Color(1.0, 0.76, 0.46)
	l.light_energy = energy
	l.omni_range = rng
	l.shadow_enabled = false
	l.position = pos
	l.add_to_group("torch_lights")
	parent.add_child(l)


# ----------------------------------------------------------------- Hogsmeade

static func _hogsmeade(parent: Node3D, visuals: bool) -> void:
	var sq := GroundsLayout.landmark("hogsmeade_square")
	if sq == Vector3.INF:
		return
	var kit := ArchKit.new()
	var centre := Vector2(sq.x, sq.z)
	var placed: Array[Rect2] = []
	var rng := RandomNumberGenerator.new()
	rng.seed = 6870
	# The Three Broomsticks: big inn on the north side of the square, facing it.
	var inn := centre + Vector2(0, -44)
	cottage(kit, inn, 0.0, 16.0, 11.0, 3, "roof_warm", true)
	placed.append(Rect2(inn - Vector2(10, 8), Vector2(20, 16)))
	# Houses facing the square on a ring, then along the roads leaving it.
	for i in 9:
		var a := -PI * 0.5 + TAU * (i + 0.5) / 10.0 + 0.25
		if absf(wrapf(a + PI * 0.5, -PI, PI)) < 0.45:
			continue
		var p := centre + Vector2(cos(a), sin(a)) * 46.0
		_try_house(kit, p, centre - p, placed, rng)
	for road_id in ["castle_east", "hogsmeade_station", "highlands_path"]:
		var r := GroundsLayout.road(road_id)
		if r.is_empty():
			continue
		var pts: Array = r["points"]
		for k in pts.size() - 1:
			var a := Vector2(pts[k][0], pts[k][1])
			var b := Vector2(pts[k + 1][0], pts[k + 1][1])
			var length := a.distance_to(b)
			var dir := (b - a) / length
			var nrm := Vector2(-dir.y, dir.x)
			var s := 6.0
			while s < length:
				var on := a + dir * s
				var dist := on.distance_to(centre)
				if dist > 50.0 and dist < 150.0:
					for side in [-1.0, 1.0]:
						var p: Vector2 = on + nrm * side * (float(r["width"]) * 0.5 + 8.5)
						_try_house(kit, p, -nrm * side, placed, rng)
				s += 17.0
	# square: a well and four lamp posts
	kit.cylinder(sq + Vector3(0, -0.5, 0), 1.6, 1.4, "stone", 14)
	kit.cylinder(sq + Vector3(0, 0.9, 0), 1.35, 0.1, "dark", 14, false)
	for sx in [-1, 1]:
		kit.box(sq + Vector3(sx * 1.2, 1.9, 0), Vector3(0.18, 2.2, 0.18), 0.0, "timber", false)
	kit.gable(sq + Vector3(0, 2.9, 0), Vector2(3.0, 2.4), 0.9, 0.0, "roof", "timber", 0.2)
	var root := kit.finish(parent, materials() if visuals else {}, "HogsmeadeVillage", 1, visuals)
	if visuals:
		for i in 4:
			var a := TAU * (i + 0.5) / 4.0
			_lamp_post(root, GroundsLayout.ground(sq.x + cos(a) * 26.0, sq.z + sin(a) * 26.0))
		_lamp_light(root, Vector3(inn.x, sq.y + 3.0, inn.y + 7.0), 1.6, 12.0)


## A house at p whose door faces `toward` (a direction on the ground plane),
## unless it would overlap a placed house, sit on a road or straddle a slope.
static func _try_house(kit: ArchKit, p: Vector2, toward: Vector2, placed: Array[Rect2], rng: RandomNumberGenerator) -> void:
	var w := rng.randf_range(7.5, 10.5)
	var d := rng.randf_range(6.5, 8.0)
	var rect := Rect2(p - Vector2(7, 7), Vector2(14, 14))
	for r in placed:
		if r.intersects(rect):
			return
	if GroundsLayout.road_distance(p) < d * 0.5 + 1.5:
		return
	var rot := atan2(toward.x, toward.y)
	var span := GroundsLayout.ground_span(p, Vector2(w, d), rot)
	if span.y - span.x > 3.0:
		return
	placed.append(rect)
	cottage(kit, p, rot, w, d, rng.randi_range(1, 3), "roof" if rng.randf() < 0.75 else "roof_warm")


static func _lamp_post(parent: Node3D, at: Vector3) -> void:
	var kit := ArchKit.new()
	kit.box(at + Vector3(0, 1.6, 0), Vector3(0.16, 3.2, 0.16), 0.0, "metal")
	kit.box(at + Vector3(0, 3.35, 0), Vector3(0.5, 0.5, 0.5), 0.0, "glass", false)
	kit.pyramid(at + Vector3(0, 3.6, 0), Vector2(0.6, 0.6), 0.35, 0.0, "metal", 0.05)
	kit.finish(parent, materials(), "Lamp", 1, true)
	_lamp_light(parent, at + Vector3(0, 3.3, 0), 1.0, 8.0)


# -------------------------------------------------------------- Hagrid's hut

static func _hagrid(parent: Node3D, visuals: bool) -> void:
	var h := GroundsLayout.landmark("hagrid_hut")
	if h == Vector3.INF:
		return
	var kit := ArchKit.new()
	var span := GroundsLayout.ground_span(Vector2(h.x, h.z), Vector2(10, 10))
	var fy := span.y + 0.1
	kit.cylinder(Vector3(h.x, span.x - 1.0, h.z), 4.6, fy + 3.6 - span.x + 1.0, "rubble", 18)
	kit.cone(Vector3(h.x, fy + 3.6, h.z), 4.6, 4.2, "roof_warm", 18, 1.2)
	kit.box(Vector3(h.x + 2.2, fy + 5.0, h.z - 1.5), Vector3(1.0, 4.0, 1.0), 0.0, "rubble", false)
	kit.box(Vector3(h.x, fy + 1.3, h.z + 4.62), Vector3(1.6, 2.6, 0.3), 0.0, "wood", false)
	kit.window(Vector3(h.x + 3.2, fy + 1.9, h.z + 3.2), Vector3(0.7, 0, 0.7), 0.8, 1.0, "timber", "glass")
	kit.window(Vector3(h.x - 3.2, fy + 1.9, h.z + 3.2), Vector3(-0.7, 0, 0.7), 0.8, 1.0, "timber", "glass")
	# pumpkin patch with a low post-and-rail fence: pumpkins of every size that
	# never overlap, a few giants among them, leaves on the ground between
	var patch := Vector2(h.x + 10.0, h.z + 4.0)
	var rng := RandomNumberGenerator.new()
	rng.seed = 280
	var placed: Array = []   # [Vector2 at, float diameter]
	for attempt in 400:
		if placed.size() >= 16:
			break
		var d := rng.randf_range(0.55, 1.0) if placed.size() >= 3 else rng.randf_range(1.25, 1.5)
		var p := patch + Vector2(rng.randf_range(-4.6, 4.6), rng.randf_range(-3.3, 3.3))
		if pow((p.x - patch.x) / 5.0, 2.0) + pow((p.y - patch.y) / 3.7, 2.0) > 1.0:
			continue
		var free := true
		for other in placed:
			if p.distance_to(other[0]) < (d + float(other[1])) * 0.55:
				free = false
				break
		if free:
			placed.append([p, d])
	var pumpkins: Array[Transform3D] = []
	for item in placed:
		var p: Vector2 = item[0]
		var d: float = item[1]
		var g := GroundsLayout.ground(p.x, p.y)
		var tilt := Basis(Vector3(rng.randf_range(-1, 1), 0, rng.randf_range(-1, 1)).normalized(), rng.randf_range(0.0, 0.12))
		var squash := Vector3(d, d * rng.randf_range(0.85, 1.1), d)
		pumpkins.append(Transform3D(tilt * Basis(Vector3.UP, rng.randf() * TAU).scaled(squash), g + Vector3(0, -0.03 * d, 0)))
	var leaves: Array[Transform3D] = []
	for i in 34:
		var p := patch + Vector2(rng.randf_range(-4.7, 4.7), rng.randf_range(-3.4, 3.4))
		if pow((p.x - patch.x) / 5.2, 2.0) + pow((p.y - patch.y) / 3.9, 2.0) > 1.0:
			continue
		var g := GroundsLayout.ground(p.x, p.y)
		var tip := Basis(Vector3(rng.randf_range(-1, 1), 0, rng.randf_range(-1, 1)).normalized(), rng.randf_range(0.0, 0.25))
		leaves.append(Transform3D(tip * Basis(Vector3.UP, rng.randf() * TAU).scaled(Vector3.ONE * rng.randf_range(0.8, 1.35)), g + Vector3(0, 0.02, 0)))
	var posts: Array[Vector3] = []
	for i in 14:
		var a := TAU * i / 14.0
		var p := patch + Vector2(cos(a) * 6.0, sin(a) * 4.6)
		var g := GroundsLayout.ground(p.x, p.y)
		posts.append(g)
		kit.box(g + Vector3(0, 0.55, 0), Vector3(0.16, 1.1, 0.16), a, "timber", false)
	for i in posts.size():
		var a := posts[i]
		var b := posts[(i + 1) % posts.size()]
		var mid := (a + b) * 0.5
		var run := Vector2(b.x - a.x, b.z - a.z)
		for rail_y in [0.42, 0.86]:
			kit.box(mid + Vector3(0, rail_y, 0), Vector3(run.length() + 0.1, 0.09, 0.07), atan2(-run.y, run.x), "timber", false)
	var root := kit.finish(parent, materials() if visuals else {}, "HagridsHut", 1, visuals)
	if visuals:
		_lamp_light(root, Vector3(h.x, fy + 2.4, h.z + 5.5), 1.2, 9.0)
		_pumpkin_patch(root, pumpkins, leaves, rng)


## The pumpkins and their leaves as two MultiMeshes of the Blender-baked
## PumpkinMesh, each a shade apart (instance colour multiplies the skin).
static func _pumpkin_patch(parent: Node3D, xforms: Array[Transform3D], leaves: Array[Transform3D], rng: RandomNumberGenerator) -> void:
	for layer in [["Pumpkins", PumpkinMesh.mesh(), xforms], ["PumpkinLeaves", PumpkinMesh.leaf_mesh(), leaves]]:
		if layer[1] == null:
			continue
		var list: Array[Transform3D] = layer[2]
		var mm := MultiMesh.new()
		mm.transform_format = MultiMesh.TRANSFORM_3D
		mm.use_colors = true
		mm.mesh = layer[1]
		mm.instance_count = list.size()
		for i in list.size():
			mm.set_instance_transform(i, list[i])
			var v := rng.randf_range(0.88, 1.1)
			mm.set_instance_color(i, Color(v, v * rng.randf_range(0.94, 1.04), v * rng.randf_range(0.9, 1.0)))
		var mmi := MultiMeshInstance3D.new()
		mmi.name = String(layer[0])
		mmi.multimesh = mm
		parent.add_child(mmi)


# ------------------------------------------------------------- greenhouses

static func _greenhouses(parent: Node3D, visuals: bool) -> void:
	var g := GroundsLayout.landmark("greenhouses")
	if g == Vector3.INF:
		return
	# Founded on a stone plinth that follows the ground; the greenhouse itself
	# is the Blender model (art/greenhouse/greenhouse_work.blend). The glass
	# shell keeps a plain box collider.
	var kit := ArchKit.new()
	var tops: Array[Vector3] = []
	for i in 3:
		var c := Vector2(g.x - 14.0 + i * 14.0, g.z)
		var span := GroundsLayout.ground_span(c, Vector2(9, 18))
		var fy := span.y + 0.05
		kit.box(Vector3(c.x, (span.x - 1.0 + fy + 0.6) * 0.5, c.y), Vector3(9.4, fy + 0.6 - span.x + 1.0, 18.4), 0.0, "stone")
		kit.box(Vector3(c.x, fy + 0.6 + 1.6, c.y), Vector3(9.0, 3.2, 18.0), 0.0, "glasshouse")
		tops.append(Vector3(c.x, fy + 0.6, c.y))
	var root := kit.finish(parent, materials() if visuals else {}, "Greenhouses", 1, visuals)
	if not visuals or not ResourceLoader.exists(GREENHOUSE):
		return
	var shell := root.get_node_or_null("Greenhouses_glasshouse")
	if shell != null:
		shell.queue_free()   # the model draws the glass; the box stays a collider
	for at in tops:
		var house: Node3D = (load(GREENHOUSE) as PackedScene).instantiate()
		house.name = "Greenhouse"
		root.add_child(house)
		house.global_position = at
		_greenhouse_materials(house)


const GREENHOUSE := "res://assets/models/grounds/greenhouse.glb"

## The model's slots (GH_*) painted with the site's own PBR stone and wood,
## dark green painted iron, clear sky-tinted glass, terracotta and leaves.
static func _greenhouse_materials(house: Node3D) -> void:
	if not _mats.has("gh_frame"):
		var frame := StandardMaterial3D.new()
		frame.albedo_color = Color(0.09, 0.2, 0.14)
		frame.metallic = 0.55
		frame.roughness = 0.42
		var glass := StandardMaterial3D.new()
		glass.albedo_color = Color(0.78, 0.9, 0.86, 0.16)
		glass.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
		glass.roughness = 0.04
		glass.metallic = 0.2
		glass.metallic_specular = 1.0
		glass.rim_enabled = true
		glass.rim = 0.6
		glass.rim_tint = 0.8
		glass.cull_mode = BaseMaterial3D.CULL_DISABLED
		var pot := StandardMaterial3D.new()
		pot.albedo_color = Color(0.62, 0.3, 0.16)
		pot.roughness = 0.85
		var leaf := StandardMaterial3D.new()
		leaf.albedo_color = Color(0.16, 0.38, 0.12)
		leaf.roughness = 0.6
		leaf.cull_mode = BaseMaterial3D.CULL_DISABLED
		_mats["gh_frame"] = frame
		_mats["gh_glass"] = glass
		_mats["gh_pot"] = pot
		_mats["gh_leaf"] = leaf
	var by_name := {"GH_Stone": _mats["stone"], "GH_Frame": _mats["gh_frame"], "GH_Glass": _mats["gh_glass"],
		"GH_Wood": _mats["wood"], "GH_Floor": _mats["cobble"], "GH_Pot": _mats["gh_pot"], "GH_Leaf": _mats["gh_leaf"]}
	for node in house.find_children("*", "MeshInstance3D", true, false):
		var mi := node as MeshInstance3D
		for i in mi.mesh.get_surface_count():
			var m := mi.mesh.surface_get_material(i)
			if m != null and by_name.has(m.resource_name):
				mi.set_surface_override_material(i, by_name[m.resource_name])
		mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_ON


# -------------------------------------------------- boathouse and lake stair

static func _boathouse(parent: Node3D, visuals: bool) -> void:
	var b := GroundsLayout.landmark("boathouse")
	if b == Vector3.INF:
		return
	var kit := ArchKit.new()
	# boathouse on the shore, its open end towards the lake (south)
	var c := Vector2(b.x, b.z + 4.0)
	var span := GroundsLayout.ground_span(c, Vector2(8, 10))
	var fy := maxf(span.y, 0.6) + 0.1
	for sx in [-1, 1]:
		kit.box(Vector3(c.x + sx * 3.8, (span.x - 1.0 + fy + 3.4) * 0.5, c.y), Vector3(0.5, fy + 3.4 - span.x + 1.0, 10.0), 0.0, "rubble")
	kit.box(Vector3(c.x, (span.x - 1.0 + fy + 3.4) * 0.5, c.y - 5.0), Vector3(8.1, fy + 3.4 - span.x + 1.0, 0.5), 0.0, "rubble")
	kit.gable(Vector3(c.x, fy + 3.4, c.y), Vector2(10.6, 8.6), 3.0, PI * 0.5, "roof", "wood", 0.5)
	# jetty out over the water
	for k in 10:
		var z := c.y + 6.0 + k * 2.0
		kit.box(Vector3(c.x, 0.55, z), Vector3(3.0, 0.2, 2.0), 0.0, "wood")
		for sx in [-1, 1]:
			kit.box(Vector3(c.x + sx * 1.4, -2.0, z), Vector3(0.25, 5.0, 0.25), 0.0, "timber", false)
	# the stair down the cliff from the castle side
	var stair := GroundsLayout.road("boathouse_stairs")
	if not stair.is_empty():
		_stair(kit, stair["points"], float(stair.get("width", 3.0)))
	var root := kit.finish(parent, materials() if visuals else {}, "Boathouse", 1, visuals)
	if visuals:
		_lamp_light(root, Vector3(c.x, fy + 2.6, c.y + 5.2), 1.0, 8.0)


## Treads along a polyline that follow the ground downhill: every tread is a
## solid block from its top down to the ground, rises are at most 0.3 m (under
## the player's 0.45 m step-up), so the whole flight is walkable both ways.
static func _stair(kit: ArchKit, pts: Array, width: float) -> void:
	var samples: Array = []
	for i in pts.size() - 1:
		var a := Vector2(pts[i][0], pts[i][1])
		var b := Vector2(pts[i + 1][0], pts[i + 1][1])
		var n := maxi(1, int(a.distance_to(b) / 0.5))
		for k in n:
			samples.append(a.lerp(b, float(k) / n))
	samples.append(Vector2(pts[-1][0], pts[-1][1]))
	var prev_top := INF
	for i in samples.size() - 1:
		var p: Vector2 = samples[i]
		var q: Vector2 = samples[i + 1]
		var g := GroundsTerrain.height_at(p.x, p.y)
		if is_nan(g):
			continue
		var top := g + 0.15
		if prev_top != INF and prev_top - top > 0.3:
			top = prev_top - 0.3
		prev_top = top
		var mid := (p + q) * 0.5
		var rot := atan2(-(q - p).y, (q - p).x)
		var bottom := g - 1.2
		kit.box(Vector3(mid.x, (top + bottom) * 0.5, mid.y), Vector3(p.distance_to(q) + 0.02, top - bottom, width), rot, "stone")


# ------------------------------------------------------------------ station

static func _station(parent: Node3D, visuals: bool) -> void:
	var s := GroundsLayout.landmark("station")
	if s == Vector3.INF:
		return
	var kit := ArchKit.new()
	var fy := s.y + 0.9
	kit.box(Vector3(s.x, fy - 1.5, s.z), Vector3(6.0, 3.0, 70.0), 0.0, "stone")
	kit.box(Vector3(s.x - 0.0, fy + 0.02, s.z), Vector3(5.6, 0.06, 69.6), 0.0, "cobble", false)
	for sx in [6.0, 7.5]:
		kit.box(Vector3(s.x + sx, s.y + 0.1, s.z), Vector3(0.12, 0.15, 220.0), 0.0, "metal", false)
	for k in 70:
		kit.box(Vector3(s.x + 6.75, s.y - 0.02, s.z - 108.0 + k * 3.1), Vector3(2.4, 0.16, 0.3), 0.0, "timber", false)
	cottage(kit, Vector2(s.x - 7.5, s.z), PI * 0.5, 14.0, 7.0, 1, "roof")
	for k in 3:
		kit.box(Vector3(s.x + 2.2, fy + 1.6, s.z - 20.0 + k * 20.0), Vector3(0.25, 3.2, 0.25), 0.0, "metal", false)
	kit.box(Vector3(s.x + 1.0, fy + 3.3, s.z), Vector3(3.4, 0.2, 46.0), 0.0, "roof", false)
	var root := kit.finish(parent, materials() if visuals else {}, "HogsmeadeStation", 1, visuals)
	if visuals:
		for k in 3:
			_lamp_light(root, Vector3(s.x + 1.0, fy + 3.0, s.z - 20.0 + k * 20.0), 0.9, 9.0)


# --------------------------------------------------------- Quidditch pitch

static func _quidditch(parent: Node3D, visuals: bool) -> void:
	var q := GroundsLayout.landmark("quidditch")
	if q == Vector3.INF:
		return
	var kit := ArchKit.new()
	var long := 70.0
	var short := 30.0
	# hoops: three per end
	for end in [-1, 1]:
		for k in 3:
			var x: float = q.x + (k - 1) * 9.0
			var z: float = q.z + end * long
			var g := GroundsLayout.ground(x, z)
			var hgt: float = [14.0, 17.0, 14.0][k]
			kit.cylinder(g + Vector3(0, -0.5, 0), 0.25, hgt + 0.5, "gold", 8)
			for s in 16:
				var a := TAU * s / 16.0
				kit.box(g + Vector3(cos(a) * 2.0, hgt + 2.0 + sin(a) * 2.0, 0), Vector3(0.25, 0.25, 0.25), 0.0, "gold", false)
	# spectator towers around the oval, in house colours
	var cloths := ["cloth_red", "cloth_yellow", "cloth_blue", "cloth_green"]
	for i in 16:
		var a := TAU * i / 16.0
		var p := Vector2(q.x + cos(a) * (short + 14.0), q.z + sin(a) * (long + 12.0))
		var span := GroundsLayout.ground_span(p, Vector2(6, 6))
		var top := span.y + 16.0
		kit.box(Vector3(p.x, (span.x - 1.0 + top) * 0.5, p.y), Vector3(5.5, top - span.x + 1.0, 5.5), -a, "wood")
		kit.box(Vector3(p.x, top - 3.0, p.y), Vector3(5.8, 4.0, 5.8), -a, cloths[i % 4], false)
		kit.pyramid(Vector3(p.x, top, p.y), Vector2(5.5, 5.5), 4.0, -a, cloths[i % 4], 0.4)
	kit.finish(parent, materials() if visuals else {}, "QuidditchPitch", 1, visuals)


# -------------------------------------------------------- stone circle etc.

static func _stone_circle(parent: Node3D, visuals: bool) -> void:
	var c := GroundsLayout.landmark("stone_circle")
	if c == Vector3.INF:
		return
	var kit := ArchKit.new()
	var rng := RandomNumberGenerator.new()
	rng.seed = 7601
	for i in 13:
		var a := TAU * i / 13.0
		var g := GroundsLayout.ground(c.x + cos(a) * 16.0, c.z + sin(a) * 16.0)
		var hgt := rng.randf_range(3.2, 5.2)
		kit.box(g + Vector3(0, hgt * 0.5 - 0.6, 0), Vector3(1.6, hgt, 0.9), -a + rng.randf_range(-0.15, 0.15), "mossy")
	kit.box(c + Vector3(0, 0.4, 0), Vector3(3.0, 1.2, 1.6), 0.3, "mossy")
	kit.finish(parent, materials() if visuals else {}, "StoneCircle", 1, visuals)


static func _smugglers_camp(parent: Node3D, visuals: bool) -> void:
	var c := GroundsLayout.landmark("smugglers_camp")
	if c == Vector3.INF:
		return
	var kit := ArchKit.new()
	for i in 5:
		var a := TAU * i / 5.0 + 0.4
		var g := GroundsLayout.ground(c.x + cos(a) * 11.0, c.z + sin(a) * 11.0)
		kit.gable(g + Vector3(0, -0.1, 0), Vector2(4.4, 3.4), 2.5, -a, "canvas", "canvas", 0.0)
	for i in 8:
		var a := TAU * i / 8.0
		var g := GroundsLayout.ground(c.x + cos(a) * 5.0, c.z + sin(a) * 5.0)
		kit.box(g + Vector3(0, 0.45, 0), Vector3(0.9, 0.9, 0.9), a, "wood")
	# palisade
	for i in 40:
		var a := TAU * i / 40.0
		if absf(wrapf(a - PI * 0.5, -PI, PI)) < 0.25:
			continue
		var g := GroundsLayout.ground(c.x + cos(a) * 20.0, c.z + sin(a) * 20.0)
		kit.cylinder(g + Vector3(0, -0.5, 0), 0.22, 3.3, "timber", 6)
	var root := kit.finish(parent, materials() if visuals else {}, "SmugglersCamp", 1, visuals)
	if visuals:
		_lamp_light(root, c + Vector3(0, 1.0, 0), 2.0, 12.0)


static func _crypt(parent: Node3D, visuals: bool) -> void:
	var c := GroundsLayout.landmark("crypt")
	if c == Vector3.INF:
		return
	var kit := ArchKit.new()
	var span := GroundsLayout.ground_span(Vector2(c.x, c.z), Vector2(10, 14))
	var fy := span.y + 0.1
	kit.box(Vector3(c.x, (span.x - 1.0 + fy + 5.0) * 0.5, c.z), Vector3(9.0, fy + 5.0 - span.x + 1.0, 13.0), 0.0, "mossy")
	kit.gable(Vector3(c.x, fy + 5.0, c.z), Vector2(13.6, 9.6), 2.6, PI * 0.5, "mossy", "mossy", 0.3)
	for sx in [-1, 1]:
		kit.cylinder(Vector3(c.x + sx * 3.0, fy, c.z + 7.2), 0.45, 4.6, "trim", 10)
	kit.box(Vector3(c.x, fy + 1.6, c.z + 6.55), Vector3(2.4, 3.2, 0.12), 0.0, "dark", false)
	var rng := RandomNumberGenerator.new()
	rng.seed = 640
	for i in 16:
		var p := Vector2(c.x + rng.randf_range(-16, 16), c.z + rng.randf_range(9, 22))
		var g := GroundsLayout.ground(p.x, p.y)
		kit.box(g + Vector3(0, 0.5, 0), Vector3(0.7, 1.2, 0.18), rng.randf_range(-0.2, 0.2), "mossy")
	kit.finish(parent, materials() if visuals else {}, "Crypt", 1, visuals)


## The Matriarch's webs: the caverns' dew-beaded orb web (cobweb.gdshader over
## a silk photo) strung between the real trunks round the hollow, plus a few
## sagging over the open floor. (Flat translucent boxes read as white cards.)
static func _hollow_webs(root: Node3D, c: Vector3) -> void:
	var trunks: Array = []
	for variant in ["fir_a", "fir_b", "fir_c", "pine_a", "pine_b", "pine_c", "broadleaf_a", "broadleaf_b"]:
		var data := GroundsScatter.instances(variant)
		for i in data.size() / 5:
			var p := Vector2(data[i * 5], data[i * 5 + 2])
			if p.distance_to(Vector2(c.x, c.z)) < 26.0:
				trunks.append(Vector3(p.x, data[i * 5 + 1], p.y))
	var rng := RandomNumberGenerator.new()
	rng.seed = 7004
	var xforms: Array = []
	var used := {}
	for i in trunks.size():
		if xforms.size() >= 12:
			break
		for j in range(i + 1, trunks.size()):
			var a: Vector3 = trunks[i]
			var b: Vector3 = trunks[j]
			var span := Vector2(a.x, a.z).distance_to(Vector2(b.x, b.z))
			if span < 2.5 or span > 8.0 or used.has(i) or used.has(j):
				continue
			used[i] = true
			used[j] = true
			var mid := (a + b) * 0.5
			var across := Vector3(b.x - a.x, 0.0, b.z - a.z).normalized()
			var s := span * 1.05
			var basis := Basis(across, Vector3.UP, across.cross(Vector3.UP)) * Basis(Vector3.RIGHT, rng.randf_range(-0.25, 0.25))
			var g := GroundsLayout.ground(mid.x, mid.z)
			xforms.append(Transform3D(basis.scaled_local(Vector3(s, s * 0.85, 1.0)), g + Vector3(0, s * 0.42 + rng.randf_range(0.6, 2.2), 0)))
			break
	# open-floor webs facing the hollow's heart, low and tilted back
	while xforms.size() < 16:
		var ang := rng.randf() * TAU
		var r := rng.randf_range(9.0, 19.0)
		var g := GroundsLayout.ground(c.x + cos(ang) * r, c.z + sin(ang) * r)
		var to_c := Vector3(c.x - g.x, 0.0, c.z - g.z).normalized()
		var basis := Basis.looking_at(-to_c, Vector3.UP) * Basis(Vector3.RIGHT, rng.randf_range(-0.5, -0.1)) * Basis(Vector3.FORWARD, rng.randf() * TAU)
		var s := rng.randf_range(3.0, 5.5)
		xforms.append(Transform3D(basis.scaled_local(Vector3(s, s, 1.0)), g + Vector3(0, s * 0.45 + 0.2, 0)))
	var mat := ShaderMaterial.new()
	mat.shader = load("res://assets/shaders/cobweb.gdshader")
	mat.set_shader_parameter("web", load("res://assets/vfx/tex/cobweb_1024.png"))
	mat.set_shader_parameter("tint", Color(0.6, 0.8, 0.55))
	mat.set_shader_parameter("opacity", 0.7)
	var quad := QuadMesh.new()
	quad.size = Vector2(1, 1)
	quad.material = mat
	var mm := MultiMesh.new()
	mm.transform_format = MultiMesh.TRANSFORM_3D
	mm.use_custom_data = true
	mm.mesh = quad
	mm.instance_count = xforms.size()
	for k in xforms.size():
		mm.set_instance_transform(k, xforms[k])
		mm.set_instance_custom_data(k, Color(rng.randf(), 0, 0, 0))
	var inst := MultiMeshInstance3D.new()
	inst.name = "Webs"
	inst.multimesh = mm
	inst.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	root.add_child(inst)


static func _spider_hollow(parent: Node3D, visuals: bool) -> void:
	var c := GroundsLayout.landmark("spider_hollow")
	if c == Vector3.INF or not visuals:
		return
	var root := Node3D.new()
	root.name = "SpiderHollow"
	parent.add_child(root)
	_hollow_webs(root, c)
	var l := OmniLight3D.new()
	l.light_color = Color(0.5, 0.75, 0.45)
	l.light_energy = 1.4
	l.omni_range = 18.0
	l.position = c + Vector3(0, 3.0, 0)
	root.add_child(l)
