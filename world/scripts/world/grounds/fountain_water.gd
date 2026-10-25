extends RefCounted
class_name FountainWater

## The courtyard fountain's moving water. The fountain model
## (assets/models/grounds/fountain.glb) is one baked mesh whose water - three
## pools and eight streams - is painted on and never moves; this lays live water
## over it: rippling pool surfaces with rings where the streams land, streaks
## running down each stream, and droplets splashing at the landings.
## Presentation only (never built on a dedicated server).
##
## Where the water is, measured on the model (local metres, y up):
##   basin pool y 0.90 r 2.95, middle bowl y 3.0 r 1.45, top bowl y 3.9 r 0.75;
##   four streams off the middle bowl's lip (r 1.5 -> 1.98, y 2.86 -> 0.9) and
##   four off the top bowl's (r 1.0 -> 1.14, y 3.9 -> 3.02), on the x and z axes.

const SHADER := preload("res://assets/shaders/fountain_water.gdshader")
const GLOW_TEX := "res://assets/vfx/tex/soft_glow_512.png"
const DIRS := [Vector3(1, 0, 0), Vector3(0, 0, -1), Vector3(-1, 0, 0), Vector3(0, 0, 1)]

## Build the water under `parent`, the fountain standing at `at` (yaw 0).
static func build(parent: Node3D, at: Vector3) -> Node3D:
	var root := Node3D.new()
	root.name = "FountainWater"
	parent.add_child(root)
	root.position = at
	_pool(root, 0.92, 2.95, _drops(1.98))
	_pool(root, 3.03, 1.45, _drops(1.14))
	_pool(root, 3.92, 0.75, [])
	for dir in DIRS:
		_stream(root, dir, 1.5, 1.98, 2.86, 0.9, 0.24)
		_stream(root, dir, 1.0, 1.14, 3.9, 3.02, 0.15)
		_splash(root, dir * 1.98 + Vector3.UP * 0.94, 1.0)
		_splash(root, dir * 1.14 + Vector3.UP * 3.06, 0.6)
	return root

static func _drops(r: float) -> Array:
	var out: Array = []
	for dir in DIRS:
		var p: Vector3 = dir * r
		out.append(Vector4(p.x, 0.0, p.z, 0.0))
	return out

static func _pool(root: Node3D, y: float, r: float, drops: Array) -> void:
	var mat := ShaderMaterial.new()
	mat.shader = SHADER
	mat.set_shader_parameter("mode", 0)
	mat.set_shader_parameter("radius", r)
	mat.set_shader_parameter("ripple_scale", 3.5 / clampf(r / 1.5, 0.6, 2.0))
	var packed: Array = drops.duplicate()
	while packed.size() < 4:
		packed.append(Vector4.ZERO)
	mat.set_shader_parameter("drops", packed)
	mat.set_shader_parameter("drop_count", drops.size())
	var plane := PlaneMesh.new()
	plane.size = Vector2(r * 2.0, r * 2.0)
	plane.subdivide_width = 0
	plane.subdivide_depth = 0
	plane.material = mat
	var mi := MeshInstance3D.new()
	mi.name = "Pool"
	mi.mesh = plane
	mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	mi.position = Vector3(0, y, 0)
	root.add_child(mi)

## A falling stream: a ribbon along the arc water takes off a lip (thrown
## out level, so the distance out grows with the square root of the drop),
## doubled crosswise so it reads from every side. UV.y runs down the fall.
static func _stream(root: Node3D, dir: Vector3, r0: float, r1: float, top_y: float, bottom_y: float, width: float) -> void:
	var mat := ShaderMaterial.new()
	mat.shader = SHADER
	mat.set_shader_parameter("mode", 1)
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
