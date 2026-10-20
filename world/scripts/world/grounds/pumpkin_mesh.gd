extends RefCounted
class_name PumpkinMesh

## Hagrid's pumpkins: one procedural mesh, drawn many times by a MultiMesh.
## A squat sphere pushed into ten rounded lobes with deep grooves, a dimpled
## crown and base, mottled orange shading that darkens into the grooves and
## fades to yellow-green underneath (vertex colours), and a curved woody stem.
## Unit size: about 1 m across and 0.7 m tall before the instance scale.
## Replaces the 10-sided cylinders the patch used to be.

const LOBES := 10
const RINGS := 22
const SEGMENTS := 80

static var _mesh: ArrayMesh = null


static func mesh() -> ArrayMesh:
	if _mesh != null:
		return _mesh
	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)
	var deep := Color(0.62, 0.22, 0.03)
	var skin := Color(0.93, 0.47, 0.08)
	var pale := Color(0.92, 0.66, 0.24)
	var green := Color(0.5, 0.48, 0.18)
	for r in RINGS + 1:
		var theta := PI * float(r) / float(RINGS)
		for k in SEGMENTS + 1:
			var phi := TAU * float(k) / float(SEGMENTS)
			var lobe := 1.0 - pow(1.0 - absf(cos(phi * LOBES * 0.5)), 2.2)
			var radius := (0.9 + 0.1 * lobe) * 0.5
			var p := Vector3(cos(phi) * sin(theta) * radius, cos(theta) * 0.34, sin(phi) * sin(theta) * radius)
			# dimples where the stem grows and underneath
			p.y -= 0.1 * exp(-pow(theta / 0.38, 2.0))
			p.y += 0.05 * exp(-pow((PI - theta) / 0.4, 2.0))
			p.y += 0.36
			var shade := skin.lerp(deep, (1.0 - lobe) * 0.75)
			shade = shade.lerp(pale, clampf((theta - 1.9) / 1.2, 0.0, 1.0) * 0.6)
			shade = shade.lerp(green, exp(-pow(theta / 0.3, 2.0)) * 0.7)
			# faint vertical striations along each lobe
			shade = shade.darkened(0.06 * (0.5 + 0.5 * sin(phi * LOBES * 3.0)))
			st.set_color(shade)
			st.set_uv(Vector2(float(k) / SEGMENTS, float(r) / RINGS))
			st.add_vertex(p)
	for r in RINGS:
		for k in SEGMENTS:
			var a := r * (SEGMENTS + 1) + k
			var b := a + SEGMENTS + 1
			st.add_index(a)
			st.add_index(a + 1)
			st.add_index(b)
			st.add_index(a + 1)
			st.add_index(b + 1)
			st.add_index(b)
	st.generate_normals()
	var skin_mat := StandardMaterial3D.new()
	skin_mat.vertex_color_use_as_albedo = true
	skin_mat.vertex_color_is_srgb = true
	skin_mat.roughness = 0.5
	skin_mat.metallic_specular = 0.35
	st.set_material(skin_mat)
	_mesh = st.commit()
	_add_stem(_mesh)
	return _mesh


## A thick, slightly bent woody stem rising out of the crown dimple.
static func _add_stem(target: ArrayMesh) -> void:
	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)
	var sides := 7
	var steps := 6
	var base := Vector3(0, 0.6, 0)
	for i in steps + 1:
		var t := float(i) / float(steps)
		var centre := base + Vector3(0.05 * t * t, 0.15 * t, 0.015 * t)
		var rad := lerpf(0.05, 0.03, t) * (1.25 if i == 0 else 1.0)
		for k in sides + 1:
			var a := TAU * float(k) / float(sides)
			var ridge := 1.0 + 0.12 * cos(a * 5.0)
			st.set_color(Color(0.32, 0.3, 0.14).lerp(Color(0.45, 0.36, 0.2), t))
			st.add_vertex(centre + Vector3(cos(a), 0, sin(a)) * rad * ridge)
	for i in steps:
		for k in sides:
			var a := i * (sides + 1) + k
			var b := a + sides + 1
			st.add_index(a)
			st.add_index(b)
			st.add_index(a + 1)
			st.add_index(a + 1)
			st.add_index(b)
			st.add_index(b + 1)
	st.generate_normals()
	var stem_mat := StandardMaterial3D.new()
	stem_mat.vertex_color_use_as_albedo = true
	stem_mat.vertex_color_is_srgb = true
	stem_mat.roughness = 0.9
	st.set_material(stem_mat)
	st.commit(target)
