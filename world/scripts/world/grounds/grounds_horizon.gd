extends RefCounted
class_name GroundsHorizon

## Distant mountains beyond the 2 km map, so a rider high on a broom sees ranges
## fading into haze instead of the edge of the world. Visual only: a single
## low-poly mesh (rings from just inside the map edge out to ~3.5 km) whose inner
## edge sits below the real mountain ring and rises to taller peaks outside it,
## coloured by height (moor to rock) and left to the fog for depth.

const RINGS := [990.0, 1150.0, 1450.0, 1900.0, 2500.0, 3400.0]
const HEIGHTS := [60.0, 175.0, 260.0, 230.0, 300.0, 120.0]
const SEGMENTS := 192


static func build(parent: Node3D) -> MeshInstance3D:
	var noise := FastNoiseLite.new()
	noise.seed = 2026
	noise.frequency = 0.0018
	noise.fractal_octaves = 4
	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)
	var rows: Array = []
	for r in RINGS.size():
		var row: Array[Vector3] = []
		for i in SEGMENTS + 1:
			var a := TAU * i / SEGMENTS
			var dir := Vector3(cos(a), 0, sin(a))
			# square-ish: the map is a square, so push the ring out at the corners
			var sq: float = 1.0 / maxf(absf(cos(a)), absf(sin(a)))
			var radius: float = RINGS[r] * lerpf(1.0, sq, 0.85 if r < 2 else 0.4)
			var p := dir * radius
			var n := noise.get_noise_2d(p.x, p.z)
			p.y = HEIGHTS[r] * (0.75 + 0.5 * n) + (n * 60.0 if r > 0 else 0.0)
			row.append(p)
		rows.append(row)
	for r in rows.size() - 1:
		for i in SEGMENTS:
			var quad := [rows[r][i], rows[r][i + 1], rows[r + 1][i + 1], rows[r + 1][i]]
			for idx in [0, 2, 1, 0, 3, 2]:
				var v: Vector3 = quad[idx]
				var t := clampf((v.y - 80.0) / 180.0, 0.0, 1.0)
				st.set_color(Color(0.33, 0.37, 0.24).lerp(Color(0.46, 0.47, 0.48), t))
				st.add_vertex(v)
	st.generate_normals()
	var mi := MeshInstance3D.new()
	mi.name = "Horizon"
	mi.mesh = st.commit()
	mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	var m := StandardMaterial3D.new()
	m.vertex_color_use_as_albedo = true
	m.roughness = 1.0
	m.cull_mode = BaseMaterial3D.CULL_DISABLED
	mi.material_override = m
	parent.add_child(mi)
	return mi
