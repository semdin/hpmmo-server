extends RefCounted
class_name GroundsCourtyard

## The castle courtyard and the avenue up to the front doors (grounds spawn,
## safe zone "courtyard"). A paved plaza with a rosette round the owl fountain,
## a lawn ring cut by four paths (castle avenue north, the east and west roads,
## the lake walk south), a low balustrade with winged-boar gate statues, box
## hedges, flower beds, topiary, stone benches and Gothic lamp posts.
##
## Hero props are fal-generated meshes (art/grounds/props, MODEL_GENERATION.md):
## assets/models/grounds/{fountain,boar,lamp,bench}.glb. Everything that blocks
## a body has a box/cylinder collider built on every process (the server runs
## this headless for collision only), the meshes only where there is a screen.

const PBR = preload("res://scripts/assets/pbr_kit.gd")
const MODELS := "res://assets/models/grounds/%s.glb"

const PLAZA_R := 21.0
const ROSETTE := Vector2(6.4, 8.0)
const KERB_W := 0.6
const LAWN_OUT := 36.0
const BALUSTRADE_R := 31.0
const PATH_HALF := 3.0
const BENCH_R := 11.0
const LAMP_R := 19.4
## Path headings (radians, x = cos, z = sin): castle avenue, east road, lake
## walk, west road. The roads leave the courtyard centre on these bearings
## (assets/terrain/grounds/layout.json castle_east / castle_west).
const PATHS := [-PI * 0.5, -0.2075, PI * 0.5, -2.7795]
## The avenue's far end, just short of the front doors (world z).
const AVENUE_END_Z := 8.0


static func build(world: Node3D, visuals: bool) -> Node3D:
	var c := GroundsLayout.landmark("courtyard")
	if c == Vector3.INF:
		c = GroundsLayout.ground(0, 65)
	var root := Node3D.new()
	root.name = "Courtyard"
	world.add_child(root)
	var solid := ArchKit.new()
	# colliders for the hero props: shapes only, never drawn
	var shapes := ArchKit.new()
	_balustrade(solid, c)
	_hedges(solid, c)
	_stall(solid, c)
	_house_pillars(solid, c)
	_topiary(solid, c)
	_portal_arches(solid, c)
	shapes.cylinder(c + Vector3(0, -0.4, 0), 3.35, 1.4, "x", 16)
	shapes.cylinder(c + Vector3(0, 0.6, 0), 0.7, 3.4, "x", 10)
	for at in _bench_spots(c):
		shapes.box(at[0] + Vector3(0, 0.45, 0), Vector3(2.5, 0.9, 0.7), at[1], "x")
	for at in _lamp_spots(c):
		shapes.box(at + Vector3(0, 1.5, 0), Vector3(0.5, 3.0, 0.5), 0.0, "x")
	for at in _boar_spots(c):
		shapes.box(at[0] + Vector3(0, 1.4, 0), Vector3(1.2, 2.8, 1.2), at[1], "x")
	var mats := {}
	if visuals:
		mats = GroundsSites.materials().duplicate()
		mats["hedge"] = PBR.surface("moss_01", Color(0.42, 0.55, 0.32), {"metres": 1.0})
		mats["soil"] = PBR.surface("dirt_ground_01", Color(0.55, 0.45, 0.38), {"metres": 2.0})
		_ground_cover(root, c)
	solid.finish(root, mats, "CourtyardSolid", 1, visuals)
	shapes.finish(root, {}, "CourtyardPropShapes", 1, false)
	if visuals:
		_hero_props(root, c)
		_flowers(root, c)
		_portal_glow(root, c)
	return root


# ------------------------------------------------------------------ layout

static func _on_path(local: Vector2, half: float = PATH_HALF) -> bool:
	for heading in PATHS:
		var d := Vector2(cos(heading), sin(heading))
		var along := local.dot(d)
		if along > 0.0 and absf(local.x * d.y - local.y * d.x) < half:
			return true
	return false


static func _bench_spots(c: Vector3) -> Array:
	var out := []
	for i in 6:
		var a := TAU * i / 6.0
		var p := GroundsLayout.ground(c.x + cos(a) * BENCH_R, c.z + sin(a) * BENCH_R)
		# the seat faces the fountain
		out.append([p, -a - PI * 0.5])
	return out


static func _lamp_spots(c: Vector3) -> Array:
	var out := []
	var stall := Vector2(c.x + 16.0, c.z + 5.0)
	for i in 8:
		var a := TAU * (i + 0.5) / 8.0
		var p := Vector2(c.x + cos(a) * LAMP_R, c.z + sin(a) * LAMP_R)
		if p.distance_to(stall) < 4.5:
			continue
		out.append(GroundsLayout.ground(p.x, p.y))
	# the castle avenue, both sides
	var z := c.z - BALUSTRADE_R - 4.0
	while z > AVENUE_END_Z + 4.0:
		for side in [-1.0, 1.0]:
			out.append(GroundsLayout.ground(c.x + side * (PATH_HALF + 1.2), z))
		z -= 9.0
	return out


static func _boar_spots(c: Vector3) -> Array:
	var out := []
	for heading in [PATHS[0], PATHS[2]]:
		var d := Vector2(cos(heading), sin(heading))
		var n := Vector2(-d.y, d.x)
		for side in [-1.0, 1.0]:
			var p: Vector2 = Vector2(c.x, c.z) + d * (BALUSTRADE_R + 0.6) + n * side * (PATH_HALF + 0.9)
			# face out along the path, snout away from the fountain
			out.append([GroundsLayout.ground(p.x, p.y), atan2(d.x, d.y)])
	return out


# ------------------------------------------------------------------ ground

## Draped meshes that follow the terrain: the plaza (flagstones), the rosette
## and kerb, the lawn ring (grass) with its paths (flagstones), and the avenue.
static func _ground_cover(root: Node3D, c: Vector3) -> void:
	var tools := {}
	var add := func(key: String, a: Vector3, b: Vector3, cc: Vector3, d: Vector3) -> void:
		if not tools.has(key):
			var st := SurfaceTool.new()
			st.begin(Mesh.PRIMITIVE_TRIANGLES)
			tools[key] = st
		var st: SurfaceTool = tools[key]
		for v in [a, b, cc, a, cc, d]:
			st.set_normal(Vector3.UP)
			st.add_vertex(v)
	var g := func(x: float, z: float, lift: float) -> Vector3:
		return GroundsLayout.ground(x, z) + Vector3.UP * lift
	var segs := 96
	# rings no wider than 1.5 m, so the cover follows the ground's bumps
	var bands := []
	for spec in [[0.0, ROSETTE.x, "flag", 0.09], [ROSETTE.x, ROSETTE.y, "rosette", 0.1],
			[ROSETTE.y, PLAZA_R, "flag", 0.09], [PLAZA_R, PLAZA_R + KERB_W, "kerb", 0.16],
			[PLAZA_R + KERB_W, LAWN_OUT, "lawn", 0.06]]:
		var r: float = spec[0]
		while r < float(spec[1]) - 0.01:
			bands.append([r, minf(r + 1.5, float(spec[1])), spec[2], spec[3]])
			r += 1.5
	for band in bands:
		var r0: float = band[0]
		var r1: float = band[1]
		for i in segs:
			var a0 := TAU * i / segs
			var a1 := TAU * (i + 1) / segs
			var key: String = band[2]
			if key == "lawn":
				var mid := (r0 + r1) * 0.5
				var am := (a0 + a1) * 0.5
				if _on_path(Vector2(cos(am), sin(am)) * mid):
					key = "path"
			var lift: float = band[3]
			add.call(key,
				g.call(c.x + cos(a0) * r0, c.z + sin(a0) * r0, lift), g.call(c.x + cos(a0) * r1, c.z + sin(a0) * r1, lift),
				g.call(c.x + cos(a1) * r1, c.z + sin(a1) * r1, lift), g.call(c.x + cos(a1) * r0, c.z + sin(a1) * r0, lift))
	# the avenue up to the doors
	var z0 := c.z - LAWN_OUT + 0.5
	var z := z0
	while z > AVENUE_END_Z:
		var z1 := maxf(AVENUE_END_Z, z - 2.0)
		for k in 3:
			var x0 := c.x - PATH_HALF + k * PATH_HALF * 2.0 / 3.0
			var x1 := x0 + PATH_HALF * 2.0 / 3.0
			add.call("path", g.call(x0, z1, 0.09), g.call(x1, z1, 0.09), g.call(x1, z, 0.09), g.call(x0, z, 0.09))
		z = z1
	var mats := {
		"flag": PBR.surface("floor_flagstone_01", Color(0.74, 0.72, 0.68), {"metres": 3.0}),
		"rosette": PBR.surface("cobblestone_floor_04", Color(0.82, 0.74, 0.64), {"metres": 2.0}),
		"kerb": PBR.surface("sandstone_blocks_08", Color(0.9, 0.86, 0.8), {"metres": 1.5}),
		"lawn": PBR.surface("grass_ground_01", Color(0.5, 0.58, 0.42), {"metres": 4.0}),
		"path": PBR.surface("floor_flagstone_01", Color(0.68, 0.66, 0.62), {"metres": 3.0}),
	}
	for key in tools:
		var mi := MeshInstance3D.new()
		mi.name = "Cover_%s" % key
		mi.mesh = (tools[key] as SurfaceTool).commit()
		mi.material_override = mats[key]
		mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		root.add_child(mi)
		# The cover sits 6-16 cm above the terrain (so the terrain's bumps never
		# poke through it); a body standing on the terrain sank its feet into the
		# flagstones. Bodies stand on the cover itself.
		var shape := ConcavePolygonShape3D.new()
		shape.set_faces(mi.mesh.get_faces())
		var body := StaticBody3D.new()
		body.name = "CoverBody_%s" % key
		body.collision_layer = 1
		body.collision_mask = 0
		var collider := CollisionShape3D.new()
		collider.shape = shape
		body.add_child(collider)
		root.add_child(body)


# ------------------------------------------------------------------ built

## A low stone balustrade round the lawn, open where the paths pass.
static func _balustrade(kit: ArchKit, c: Vector3) -> void:
	var segs := 72
	for i in segs:
		var a0 := TAU * i / segs
		var a1 := TAU * (i + 1) / segs
		var am := (a0 + a1) * 0.5
		var mid := Vector2(cos(am), sin(am)) * BALUSTRADE_R
		if _on_path(mid, PATH_HALF + 0.4):
			continue
		var p0 := GroundsLayout.ground(c.x + cos(a0) * BALUSTRADE_R, c.z + sin(a0) * BALUSTRADE_R)
		var p1 := GroundsLayout.ground(c.x + cos(a1) * BALUSTRADE_R, c.z + sin(a1) * BALUSTRADE_R)
		var m := (p0 + p1) * 0.5
		var length := Vector2(p1.x - p0.x, p1.z - p0.z).length()
		var rot := -am
		kit.box(m + Vector3(0, 0.12, 0), Vector3(0.7, 0.24, length + 0.02), rot, "trim")
		kit.box(m + Vector3(0, 0.98, 0), Vector3(0.55, 0.14, length + 0.02), rot, "trim")
		# balusters
		for k in 3:
			var t := (k + 0.5) / 3.0
			var b := p0.lerp(p1, t)
			kit.cylinder(b + Vector3(0, 0.24, 0), 0.11, 0.68, "trim", 6, false, 0.07)
	# posts with caps at every path opening
	for heading in PATHS:
		var d := Vector2(cos(heading), sin(heading))
		var n := Vector2(-d.y, d.x)
		for side in [-1.0, 1.0]:
			var p: Vector2 = Vector2(c.x, c.z) + d * BALUSTRADE_R + n * side * (PATH_HALF + 0.35)
			var at := GroundsLayout.ground(p.x, p.y)
			kit.box(at + Vector3(0, 0.7, 0), Vector3(0.8, 1.4, 0.8), heading, "trim")
			kit.pyramid(at + Vector3(0, 1.4, 0), Vector2(0.95, 0.95), 0.45, heading, "trim", 0.05)


## Box hedges just inside the balustrade, open at the paths.
static func _hedges(kit: ArchKit, c: Vector3) -> void:
	var r := BALUSTRADE_R - 1.6
	var segs := 64
	for i in segs:
		var a0 := TAU * i / segs
		var a1 := TAU * (i + 1) / segs
		var am := (a0 + a1) * 0.5
		if _on_path(Vector2(cos(am), sin(am)) * r, PATH_HALF + 0.6):
			continue
		var p0 := GroundsLayout.ground(c.x + cos(a0) * r, c.z + sin(a0) * r)
		var p1 := GroundsLayout.ground(c.x + cos(a1) * r, c.z + sin(a1) * r)
		var m := (p0 + p1) * 0.5
		var length := Vector2(p1.x - p0.x, p1.z - p0.z).length()
		kit.box(m + Vector3(0, 0.55, 0), Vector3(1.0, 1.1, length + 0.05), -am, "hedge")


## Ollivander's stall (east side of the plaza): counter, posts, blue awning.
static func _stall(kit: ArchKit, c: Vector3) -> void:
	var o := GroundsLayout.ground(c.x + 16.0, c.z + 5.0)
	kit.box(o + Vector3(0, 0.55, 0), Vector3(4.2, 1.1, 1.4), 0.0, "wood")
	for sx in [-1, 1]:
		for sz in [-1, 1]:
			kit.box(o + Vector3(sx * 2.0, 1.4, sz * 0.9 - 0.4), Vector3(0.18, 2.8, 0.18), 0.0, "timber", false)
	kit.gable(o + Vector3(0, 2.8, -0.4), Vector2(4.8, 2.8), 0.9, 0.0, "cloth_blue", "cloth_blue", 0.2)


## The four house pillars, now standing in the north lawn either side of the
## castle avenue, banners facing the fountain.
static func _house_pillars(kit: ArchKit, c: Vector3) -> void:
	var houses := ["cloth_red", "cloth_yellow", "cloth_blue", "cloth_green"]
	var xs := [-16.0, -9.0, 9.0, 16.0]
	for i in 4:
		var p := GroundsLayout.ground(c.x + xs[i], c.z - 22.0 + absf(xs[i]) * 0.2)
		kit.box(p + Vector3(0, 0.3, 0), Vector3(1.9, 0.6, 1.9), 0.0, "trim")
		kit.box(p + Vector3(0, 3.0, 0), Vector3(1.4, 6.0, 1.4), 0.0, "stone")
		kit.pyramid(p + Vector3(0, 6.0, 0), Vector2(1.7, 1.7), 0.8, 0.0, "trim", 0.05)
		kit.box(p + Vector3(0, 4.0, 0.74), Vector3(1.2, 3.2, 0.06), 0.0, houses[i], false)


## Clipped yew cones in the four lawn quarters.
static func _topiary(kit: ArchKit, c: Vector3) -> void:
	for i in 4:
		var a := TAU * i / 4.0 + PI * 0.25
		for rr in [25.0, 27.6]:
			var p := GroundsLayout.ground(c.x + cos(a) * rr, c.z + sin(a) * rr)
			kit.cylinder(p, 0.5, 0.5, "soil", 8)
			kit.cone(p + Vector3(0, 0.45, 0), 0.75, 2.6, "hedge", 10, 1.0)


## Grounds portals dressed as an arch on the lawn (maps.json `dressing`
## "portal_arch": the Trial Hall). The trigger centre is the arch's centre and
## the arch faces the fountain, so the glowing doorway is seen from the plaza.
static func _arch_spots(c: Vector3) -> Array:
	var out := []
	for entry in HPMaps.portals_for_map("grounds"):
		if String((entry as Dictionary).get("dressing", "")) != "portal_arch":
			continue
		var raw: Array = (entry as Dictionary).get("trigger", {}).get("center", [0, 0, 0])
		var at := GroundsLayout.ground(float(raw[0]), float(raw[2]))
		var to_c := Vector2(c.x - at.x, c.z - at.z).normalized()
		var tangent := Vector2(-to_c.y, to_c.x)
		out.append([at, atan2(-tangent.y, tangent.x), String(entry.get("label", ""))])
	return out


const ARCH_HALF := 2.0
const ARCH_H := 4.4

static func _portal_arches(kit: ArchKit, c: Vector3) -> void:
	for spot in _arch_spots(c):
		var at: Vector3 = spot[0]
		var rot: float = spot[1]
		var basis := Basis(Vector3.UP, rot)
		kit.box(at + Vector3(0, 0.12, 0), Vector3(ARCH_HALF * 2.0 + 1.6, 0.24, 1.8), rot, "trim", false)
		for side in [-1.0, 1.0]:
			var p: Vector3 = at + basis * Vector3(side * ARCH_HALF, 0, 0)
			kit.box(p + Vector3(0, 0.35, 0), Vector3(1.05, 0.7, 1.05), rot, "trim")
			kit.box(p + Vector3(0, ARCH_H * 0.5, 0), Vector3(0.75, ARCH_H, 0.75), rot, "stone")
			kit.box(p + Vector3(0, ARCH_H + 0.15, 0), Vector3(0.95, 0.3, 0.95), rot, "trim", false)
		kit.box(at + Vector3(0, ARCH_H + 0.6, 0), Vector3(ARCH_HALF * 2.0 + 1.3, 0.6, 1.0), rot, "trim", false)
		kit.gable(at + Vector3(0, ARCH_H + 0.9, 0), Vector2(ARCH_HALF * 2.0 + 1.1, 0.9), 1.3, rot, "stone", "trim", 0.15)


const PORTAL_SHADER := """
shader_type spatial;
render_mode unshaded, blend_add, cull_disabled, depth_draw_never, shadows_disabled;
uniform vec4 rim : source_color = vec4(1.0, 0.76, 0.32, 1.0);
uniform vec4 core : source_color = vec4(0.32, 0.58, 1.0, 1.0);
void fragment() {
	vec2 p = (UV - vec2(0.5, 0.55)) * vec2(2.0, 2.2);
	float r = length(p);
	float a = atan(p.y, p.x);
	float swirl = 0.5 + 0.5 * sin(a * 5.0 + r * 9.0 - TIME * 2.2);
	float rings = 0.5 + 0.5 * sin(r * 13.0 - TIME * 3.0);
	float edge = smoothstep(1.05, 0.7, r);
	ALBEDO = mix(core.rgb, rim.rgb, clamp(r * 0.95 + swirl * 0.25, 0.0, 1.0));
	ALPHA = edge * (0.22 + 0.5 * swirl * (0.55 + 0.45 * rings));
}
"""

## The doorway itself: a slow swirl of gold and blue, a light, motes and the
## place's name over the arch (eyes only).
static func _portal_glow(root: Node3D, c: Vector3) -> void:
	for spot in _arch_spots(c):
		var at: Vector3 = spot[0]
		var holder := Node3D.new()
		holder.name = "PortalArch"
		holder.position = at
		holder.rotation.y = spot[1]
		root.add_child(holder)
		var quad := QuadMesh.new()
		quad.size = Vector2(ARCH_HALF * 2.0 - 0.75, ARCH_H - 0.1)
		var shader := Shader.new()
		shader.code = PORTAL_SHADER
		var mat := ShaderMaterial.new()
		mat.shader = shader
		quad.material = mat
		var veil := MeshInstance3D.new()
		veil.mesh = quad
		veil.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		veil.position = Vector3(0, 0.25 + quad.size.y * 0.5, 0)
		holder.add_child(veil)
		var light := OmniLight3D.new()
		light.light_color = Color(0.55, 0.7, 1.0)
		light.light_energy = 1.6
		light.omni_range = 9.0
		light.position = Vector3(0, 2.0, 0)
		holder.add_child(light)
		var sign := Label3D.new()
		sign.text = I18n.upper(I18n.t("Trial Hall"))
		sign.font = HudKit.deco()
		sign.font_size = 44
		sign.outline_size = 10
		sign.modulate = Color(1.0, 0.86, 0.55)
		sign.outline_modulate = Color(0.05, 0.03, 0.02, 0.9)
		sign.billboard = BaseMaterial3D.BILLBOARD_ENABLED
		sign.pixel_size = 0.006
		sign.position = Vector3(0, ARCH_H + 3.0, 0)
		holder.add_child(sign)
		var sub := Label3D.new()
		sub.text = I18n.t("Press F inside the arch")
		sub.font = HudKit.bold()
		sub.font_size = 30
		sub.outline_size = 8
		sub.modulate = Color(0.85, 0.9, 1.0)
		sub.outline_modulate = Color(0.05, 0.03, 0.02, 0.9)
		sub.billboard = BaseMaterial3D.BILLBOARD_ENABLED
		sub.pixel_size = 0.005
		sub.position = Vector3(0, ARCH_H + 2.45, 0)
		holder.add_child(sub)


# ------------------------------------------------------------------ props

static func _place(root: Node3D, model: String, at: Vector3, yaw: float) -> void:
	var path := MODELS % model
	if not ResourceLoader.exists(path):
		return
	var node: Node3D = (load(path) as PackedScene).instantiate()
	node.position = at
	node.rotation.y = yaw
	root.add_child(node)


static func _hero_props(root: Node3D, c: Vector3) -> void:
	_place(root, "fountain", c + Vector3(0, 0.05, 0), 0.0)
	# The model's water is painted on; this one moves (pools, streams, splashes).
	FountainWater.build(root, c + Vector3(0, 0.05, 0))
	for at in _bench_spots(c):
		_place(root, "bench", at[0] + Vector3(0, 0.08, 0), at[1])
	for at in _boar_spots(c):
		_place(root, "boar", at[0], at[1])
	for at in _lamp_spots(c):
		_place(root, "lamp", at, 0.0)
		var l := OmniLight3D.new()
		l.light_color = Color(1.0, 0.76, 0.45)
		l.light_energy = 1.2
		l.omni_range = 11.0
		l.distance_fade_enabled = true
		l.distance_fade_begin = 80.0
		l.distance_fade_length = 30.0
		l.position = at + Vector3(0, 3.95, 0)
		l.add_to_group("torch_lights")
		root.add_child(l)
	# water light under the fountain's spill
	var fl := OmniLight3D.new()
	fl.light_color = Color(0.55, 0.78, 1.0)
	fl.light_energy = 0.8
	fl.omni_range = 8.0
	fl.position = c + Vector3(0, 1.4, 0)
	root.add_child(fl)


## Flower beds: a soil strip in each lawn quarter, sown with small blooms
## (one MultiMesh, colour per instance).
static func _flowers(root: Node3D, c: Vector3) -> void:
	var rng := RandomNumberGenerator.new()
	rng.seed = 6501
	var bloom := SphereMesh.new()
	bloom.radius = 0.075
	bloom.height = 0.1
	bloom.radial_segments = 6
	bloom.rings = 3
	var mat := StandardMaterial3D.new()
	mat.vertex_color_use_as_albedo = true
	mat.roughness = 0.8
	bloom.material = mat
	var colours := [Color(0.7, 0.1, 0.12), Color(0.85, 0.66, 0.12), Color(0.42, 0.2, 0.66),
		Color(0.85, 0.84, 0.78), Color(0.8, 0.36, 0.52)]
	var spots: Array = []
	var bed := SurfaceTool.new()
	bed.begin(Mesh.PRIMITIVE_TRIANGLES)
	for q in 4:
		var a_mid := TAU * q / 4.0 + PI * 0.25
		var a0 := a_mid - 0.42
		var a1 := a_mid + 0.42
		var r0 := 22.6
		var r1 := 24.2
		var n := 12
		for i in n:
			var b0 := lerpf(a0, a1, float(i) / n)
			var b1 := lerpf(a0, a1, float(i + 1) / n)
			var pts := [Vector2(cos(b0), sin(b0)) * r0, Vector2(cos(b0), sin(b0)) * r1,
				Vector2(cos(b1), sin(b1)) * r1, Vector2(cos(b1), sin(b1)) * r0]
			var v := []
			for p in pts:
				v.append(GroundsLayout.ground(c.x + p.x, c.z + p.y) + Vector3.UP * 0.1)
			for k in [0, 1, 2, 0, 2, 3]:
				bed.set_normal(Vector3.UP)
				bed.add_vertex(v[k])
		for k in 160:
			var a := rng.randf_range(a0, a1)
			var rr := rng.randf_range(r0 + 0.15, r1 - 0.15)
			var colour: Color = colours[(q + int(rng.randi() % 3)) % colours.size()]
			spots.append([GroundsLayout.ground(c.x + cos(a) * rr, c.z + sin(a) * rr) + Vector3.UP * rng.randf_range(0.18, 0.32), colour, rng.randf_range(0.6, 1.1)])
	var bed_mi := MeshInstance3D.new()
	bed_mi.name = "FlowerBeds"
	bed_mi.mesh = bed.commit()
	bed_mi.material_override = PBR.surface("dirt_ground_01", Color(0.5, 0.4, 0.34), {"metres": 2.0})
	root.add_child(bed_mi)
	var mm := MultiMesh.new()
	mm.transform_format = MultiMesh.TRANSFORM_3D
	mm.use_colors = true
	mm.mesh = bloom
	mm.instance_count = spots.size()
	for i in spots.size():
		var s: float = spots[i][2]
		mm.set_instance_transform(i, Transform3D(Basis().scaled(Vector3.ONE * s), spots[i][0]))
		mm.set_instance_color(i, spots[i][1])
	var mmi := MultiMeshInstance3D.new()
	mmi.name = "Flowers"
	mmi.multimesh = mm
	mmi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	root.add_child(mmi)
