extends RefCounted
class_name FountainWater

## The courtyard fountain's water. The model (assets/models/grounds/fountain.glb)
## is the stone only: its painted pools and its eight sculpted streams were cut
## off in Blender (art/grounds/scripts/split_fountain_water.py, which also wrote
## the pools' exact outlines to fountain_water.glb, and cut_fountain_streams.py).
## This draws the live water: clear rippling pools in those outlines over a
## dark stone floor (fountain_pool.gdshader: the floor seen through the water,
## bent by the ripples, foam along the stone and rings where the streams land),
## streaks running down each stream, and droplets splashing at the landings.
## Presentation only (never built on a dedicated server).
##
## Where the water is, measured on the model (local metres, y up):
##   basin pool y 0.92 (octagon, 2.9 m to the walls), middle bowl y 3.05 r 1.47,
##   top bowl y 3.92 r 0.79; four streams off the middle bowl's lip (r 1.5 ->
##   1.98, y 2.86 -> 0.9) and four off the top bowl's (r 1.0 -> 1.14, y 3.9 ->
##   3.02), on the x and z axes.

const SHADER := preload("res://assets/shaders/fountain_water.gdshader")
const POOL_SHADER := preload("res://assets/shaders/fountain_pool.gdshader")
const PBR = preload("res://scripts/assets/pbr_kit.gd")
const WATER_MODEL := "res://assets/models/grounds/fountain_water.glb"
const GLOW_TEX := "res://assets/vfx/tex/soft_glow_512.png"
const DIRS := [Vector3(1, 0, 0), Vector3(0, 0, -1), Vector3(-1, 0, 0), Vector3(0, 0, 1)]
## [mesh in fountain_water.glb, outline (0 round, 1 octagon), metres to the
## stone, floor depth, where the streams land (0: none)]
const POOLS := [["pool_basin", 1, 2.9, 0.5, 1.98], ["pool_mid", 0, 1.47, 0.18, 1.14], ["pool_top", 0, 0.79, 0.14, 0.0]]
const SHALLOW := Color(0.40, 0.62, 0.60)
const DEEP := Color(0.10, 0.27, 0.30)
const STREAM := [Color(0.5, 0.7, 0.75, 0.5), Color(0.9, 0.97, 1.0, 0.55)]

## Build the water under `parent`, the fountain standing at `at` (yaw 0).
static func build(parent: Node3D, at: Vector3) -> Node3D:
	var root := Node3D.new()
	root.name = "FountainWater"
	parent.add_child(root)
	root.position = at
	var meshes := {}
	if ResourceLoader.exists(WATER_MODEL):
		var scene: Node = (load(WATER_MODEL) as PackedScene).instantiate()
		for mi in scene.find_children("*", "MeshInstance3D", true, false):
			meshes[String(mi.name)] = (mi as MeshInstance3D).mesh
		scene.free()
	var floor_mat := PBR.surface("mossy_stone_wall", Color(0.22, 0.25, 0.23), {"metres": 1.5})
	for pool in POOLS:
		var mesh: Mesh = meshes.get(pool[0])
		if mesh != null:
			_pool(root, mesh, pool, floor_mat)
	for dir in DIRS:
		_stream(root, dir, 1.5, 1.98, 2.86, 0.9, 0.16, STREAM)
		_stream(root, dir, 1.0, 1.14, 3.9, 3.02, 0.1, STREAM)
		_splash(root, dir * 1.98 + Vector3.UP * 0.94, 1.0)
		_splash(root, dir * 1.14 + Vector3.UP * 3.06, 0.6)
	return root

## A flat regular octagon at height `y`, `apothem` metres to each side, edges
## facing the axes.
static func _octagon(apothem: float, y: float) -> ArrayMesh:
	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)
	var r := apothem / cos(PI / 8.0)
	for i in 8:
		var a0 := PI / 8.0 + TAU * i / 8.0
		var a1 := PI / 8.0 + TAU * (i + 1) / 8.0
		for v in [Vector3(0, y, 0), Vector3(cos(a1) * r, y, sin(a1) * r), Vector3(cos(a0) * r, y, sin(a0) * r)]:
			st.set_normal(Vector3.UP)
			st.add_vertex(v)
	return st.commit()

static func _drops(r: float) -> Array:
	var out: Array = []
	for dir in DIRS:
		var p: Vector3 = dir * r
		out.append(Vector4(p.x, 0.0, p.z, 0.0))
	return out

## One pool: the water surface and, under it, the stone floor seen through it.
static func _pool(root: Node3D, mesh: Mesh, pool: Array, floor_mat: Material) -> void:
	var mat := ShaderMaterial.new()
	mat.shader = POOL_SHADER
	mat.set_shader_parameter("shallow", SHALLOW)
	mat.set_shader_parameter("deep", DEEP)
	mat.set_shader_parameter("clarity", 0.65)
	mat.set_shader_parameter("refraction", 0.03)
	mat.set_shader_parameter("edge_foam", 0.35)
	mat.set_shader_parameter("shape", pool[1])
	mat.set_shader_parameter("reach", pool[2])
	mat.set_shader_parameter("ripple_scale", 3.5 / clampf(float(pool[2]) / 1.5, 0.6, 2.0))
	var drops: Array = _drops(float(pool[4])) if float(pool[4]) > 0.0 else []
	var packed: Array = drops.duplicate()
	while packed.size() < 4:
		packed.append(Vector4.ZERO)
	mat.set_shader_parameter("drops", packed)
	mat.set_shader_parameter("drop_count", drops.size())
	var water := MeshInstance3D.new()
	water.name = "Water_" + String(pool[0])
	water.mesh = mesh
	water.material_override = mat
	water.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	root.add_child(water)
	var bottom := MeshInstance3D.new()
	bottom.name = "Floor_" + String(pool[0])
	# the basin's floor is one clean octagon running under the walls (the split
	# water mesh is triangle soup: its seams showed through the clear water)
	bottom.mesh = _octagon(float(pool[2]) + 0.25, mesh.get_aabb().position.y) if int(pool[1]) == 1 else mesh
	bottom.material_override = floor_mat
	bottom.position = Vector3(0, -float(pool[3]), 0)
	bottom.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	root.add_child(bottom)

## A falling stream: a ribbon along the arc water takes off a lip (thrown
## out level, so the distance out grows with the square root of the drop),
## doubled crosswise so it reads from every side. UV.y runs down the fall.
static func _stream(root: Node3D, dir: Vector3, r0: float, r1: float, top_y: float, bottom_y: float, width: float, colours: Array = []) -> void:
	var mat := ShaderMaterial.new()
	mat.shader = SHADER
	if colours.size() == 2:
		mat.set_shader_parameter("deep", colours[0])
		mat.set_shader_parameter("foam", colours[1])
	mat.set_shader_parameter("flow_speed", 2.6 if top_y - bottom_y > 1.0 else 1.8)
	var side := Vector3(-dir.z, 0.0, dir.x)
	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)
	const SEGMENTS := 14
	for across in [side, Vector3.ZERO]:
		var rows: Array = []
		for i in range(SEGMENTS + 1):
			var t := float(i) / float(SEGMENTS)
			var c: Vector3 = dir * (r0 + (r1 - r0) * sqrt(t)) + Vector3.UP * lerpf(top_y, bottom_y, t)
			# the second ribbon spans the radial plane: along the arc's outward lean
			var w: Vector3 = across if across != Vector3.ZERO else (dir * 0.6 + Vector3.UP * 0.0).normalized()
			rows.append([c - w * width * 0.5, c + w * width * 0.5, t])
		for i in range(SEGMENTS):
			var a: Array = rows[i]
			var b: Array = rows[i + 1]
			for v in [[a[0], 0.0, a[2]], [a[1], 1.0, a[2]], [b[1], 1.0, b[2]], [a[0], 0.0, a[2]], [b[1], 1.0, b[2]], [b[0], 0.0, b[2]]]:
				st.set_uv(Vector2(float(v[1]), float(v[2])))
				st.add_vertex(v[0])
	st.generate_normals()
	var mi := MeshInstance3D.new()
	mi.name = "Stream"
	mi.mesh = st.commit()
	mi.material_override = mat
	mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	root.add_child(mi)

## Droplets thrown up where a stream lands.
static func _splash(root: Node3D, at: Vector3, strength: float) -> void:
	var p := CPUParticles3D.new()
	p.name = "Splash"
	var quad := QuadMesh.new()
	quad.size = Vector2(0.07, 0.07) * (0.7 + strength * 0.3)
	var mat := StandardMaterial3D.new()
	mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	mat.billboard_mode = BaseMaterial3D.BILLBOARD_PARTICLES
	mat.vertex_color_use_as_albedo = true
	mat.albedo_texture = load(GLOW_TEX)
	quad.material = mat
	p.mesh = quad
	p.amount = int(10 * strength) + 4
	p.lifetime = 0.55
	p.position = at
	p.emission_shape = CPUParticles3D.EMISSION_SHAPE_SPHERE
	p.emission_sphere_radius = 0.08
	p.direction = Vector3.UP
	p.spread = 40.0
	p.initial_velocity_min = 0.9 * strength
	p.initial_velocity_max = 1.9 * strength
	p.gravity = Vector3(0, -9.0, 0)
	p.color = Color(0.85, 0.95, 1.0, 0.85)
	var fade := Gradient.new()
	fade.set_color(0, Color(1, 1, 1, 1))
	fade.set_color(1, Color(1, 1, 1, 0))
	p.color_ramp = fade
	p.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	root.add_child(p)
