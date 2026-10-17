extends RefCounted
class_name ArchKit

## Procedural architecture batcher for the grounds (castle shell, village houses,
## sites). Primitives are appended into one mesh per material (so a whole castle
## is a handful of draw calls) and, optionally, into one collision body.
##
## Surfaces use the world-space triplanar PBR shader (PBRKit.surface), so boxes of
## any size keep a constant texel density and need no UVs.
##
## Winding: every triangle is oriented away from an `inside` point given by the
## primitive (its centre or axis), so callers never reason about clockwise order
## and every face is front-facing from outside (the shaders cull back faces).

var _tools := {}           # material key -> SurfaceTool
var _shapes: Array = []    # [Shape3D, Transform3D]
var _with_collision := true
## Optional colour written on every vertex while set (window glass carries a
## per-window random in it for its shader). A material key must be painted
## for all of its triangles or for none.
var vertex_color: Variant = null


func _init(with_collision: bool = true) -> void:
	_with_collision = with_collision


func _st(key: String) -> SurfaceTool:
	if not _tools.has(key):
		var st := SurfaceTool.new()
		st.begin(Mesh.PRIMITIVE_TRIANGLES)
		_tools[key] = st
	return _tools[key]


## One triangle facing away from `inside`. Godot treats clockwise (seen from the
## front) as front-facing; for that order the outward normal is (c-a) x (b-a).
func tri(key: String, a: Vector3, b: Vector3, c: Vector3, inside: Vector3, smooth_axis: Variant = null) -> void:
	var n := (c - a).cross(b - a)
	if n.dot((a + b + c) / 3.0 - inside) < 0.0:
		var t := b
		b = c
		c = t
		n = -n
	n = n.normalized()
	var st := _st(key)
	for v in [a, b, c]:
		if vertex_color != null:
			st.set_color(vertex_color)
		if smooth_axis != null:
			var ax: Vector3 = smooth_axis
			var radial := Vector3(v.x - ax.x, 0, v.z - ax.z).normalized()
			st.set_normal(radial if radial != Vector3.ZERO else n)
		else:
			st.set_normal(n)
		st.add_vertex(v)


func quad(key: String, a: Vector3, b: Vector3, c: Vector3, d: Vector3, inside: Vector3, smooth_axis: Variant = null) -> void:
	tri(key, a, b, c, inside, smooth_axis)
	tri(key, a, c, d, inside, smooth_axis)


# ------------------------------------------------------------------ solids

## Box rotated by rot_y around its centre.
func box(center: Vector3, size: Vector3, rot_y: float, key: String, collide: bool = true) -> void:
	var h := size * 0.5
	var basis := Basis(Vector3.UP, rot_y)
	var p := func(x: float, y: float, z: float) -> Vector3:
		return center + basis * Vector3(x * h.x, y * h.y, z * h.z)
	quad(key, p.call(1, -1, 1), p.call(1, -1, -1), p.call(1, 1, -1), p.call(1, 1, 1), center)
	quad(key, p.call(-1, -1, -1), p.call(-1, -1, 1), p.call(-1, 1, 1), p.call(-1, 1, -1), center)
	quad(key, p.call(-1, 1, 1), p.call(1, 1, 1), p.call(1, 1, -1), p.call(-1, 1, -1), center)
	quad(key, p.call(-1, -1, -1), p.call(1, -1, -1), p.call(1, -1, 1), p.call(-1, -1, 1), center)
	quad(key, p.call(-1, -1, 1), p.call(1, -1, 1), p.call(1, 1, 1), p.call(-1, 1, 1), center)
	quad(key, p.call(1, -1, -1), p.call(-1, -1, -1), p.call(-1, 1, -1), p.call(1, 1, -1), center)
	if collide and _with_collision:
		var s := BoxShape3D.new()
		s.size = size
		_shapes.append([s, Transform3D(basis, center)])


## Vertical (optionally tapered) cylinder from its base centre, smooth-shaded.
func cylinder(base: Vector3, radius: float, height: float, key: String, segments: int = 16,
		collide: bool = true, radius_top: float = -1.0) -> void:
	var rt := radius if radius_top < 0.0 else radius_top
	var top := base + Vector3.UP * height
	for i in segments:
		var a0 := TAU * i / segments
		var a1 := TAU * (i + 1) / segments
		var b0 := base + Vector3(cos(a0) * radius, 0, sin(a0) * radius)
		var b1 := base + Vector3(cos(a1) * radius, 0, sin(a1) * radius)
		var t0 := top + Vector3(cos(a0) * rt, 0, sin(a0) * rt)
		var t1 := top + Vector3(cos(a1) * rt, 0, sin(a1) * rt)
		quad(key, b0, b1, t1, t0, base + Vector3.UP * height * 0.5, base)
		tri(key, top, t0, t1, top - Vector3.UP)
	if collide and _with_collision:
		var s := CylinderShape3D.new()
		s.radius = maxf(radius, rt)
		s.height = height
		_shapes.append([s, Transform3D(Basis(), base + Vector3.UP * height * 0.5)])


## Cone (spire) on a base circle; `flare` makes the eaves overhang the wall.
func cone(base: Vector3, radius: float, height: float, key: String, segments: int = 16, flare: float = 1.12) -> void:
	var r := radius * flare
	var apex := base + Vector3.UP * height
	var inside := base + Vector3.UP * height * 0.25
	for i in segments:
		var a0 := TAU * i / segments
		var a1 := TAU * (i + 1) / segments
		var b0 := base + Vector3(cos(a0) * r, 0, sin(a0) * r)
		var b1 := base + Vector3(cos(a1) * r, 0, sin(a1) * r)
		tri(key, b0, b1, apex, inside)
		tri(key, b0, b1, base, base + Vector3.UP)


## Pyramid roof over a rectangle (size x, z) rotated by rot_y.
func pyramid(base_center: Vector3, size_xz: Vector2, height: float, rot_y: float, key: String, overhang: float = 0.6) -> void:
	var basis := Basis(Vector3.UP, rot_y)
	var hx := size_xz.x * 0.5 + overhang
	var hz := size_xz.y * 0.5 + overhang
	var c := [basis * Vector3(-hx, 0, -hz), basis * Vector3(hx, 0, -hz), basis * Vector3(hx, 0, hz), basis * Vector3(-hx, 0, hz)]
	var apex := base_center + Vector3.UP * height
	var inside := base_center + Vector3.UP * height * 0.25
	for i in 4:
		tri(key, base_center + c[i], base_center + c[(i + 1) % 4], apex, inside)
	quad(key, base_center + c[0], base_center + c[1], base_center + c[2], base_center + c[3], base_center + Vector3.UP)


## Gable roof: ridge along local x over a footprint (size x, z), rotated by rot_y.
## The triangular ends use `gable_key` (usually the wall material).
func gable(base_center: Vector3, size_xz: Vector2, height: float, rot_y: float, key: String,
		gable_key: String = "", overhang: float = 0.7) -> void:
	var basis := Basis(Vector3.UP, rot_y)
	var hx := size_xz.x * 0.5 + overhang * 0.5
	var hz := size_xz.y * 0.5 + overhang
	var p := func(x: float, y: float, z: float) -> Vector3:
		return base_center + basis * Vector3(x, y, z)
	var inside := base_center + Vector3.UP * height * 0.3
	var ra: Vector3 = p.call(-hx, height, 0)
	var rb: Vector3 = p.call(hx, height, 0)
	quad(key, p.call(-hx, 0, hz), p.call(hx, 0, hz), rb, ra, inside)
	quad(key, p.call(hx, 0, -hz), p.call(-hx, 0, -hz), ra, rb, inside)
	quad(key, p.call(-hx, 0, -hz), p.call(hx, 0, -hz), p.call(hx, 0, hz), p.call(-hx, 0, hz), base_center + Vector3.UP)
	var gk := gable_key if gable_key != "" else key
	var gx := size_xz.x * 0.5
	var gz := size_xz.y * 0.5
	var h_end := height * (gz / hz)
	tri(gk, p.call(gx, 0, gz), p.call(gx, 0, -gz), p.call(gx, h_end, 0), inside)
	tri(gk, p.call(-gx, 0, -gz), p.call(-gx, 0, gz), p.call(-gx, h_end, 0), inside)


## Crenellated parapet along a wall top from a to b (merlons every `pitch`).
func battlements(a: Vector3, b: Vector3, thickness: float, key: String, merlon_h: float = 1.4, pitch: float = 2.2) -> void:
	var d := b - a
	var length := Vector2(d.x, d.z).length()
	var rot := atan2(-d.z, d.x)
	var count := maxi(1, int(length / pitch))
	for i in count:
		var t := (i + 0.5) / count
		box(a.lerp(b, t) + Vector3.UP * merlon_h * 0.5, Vector3(pitch * 0.55, merlon_h, thickness), rot, key, false)


## Ring of merlons on a tower top.
func tower_battlements(center_top: Vector3, radius: float, key: String, count: int = 12) -> void:
	for i in count:
		var a := TAU * (i + 0.5) / count
		box(center_top + Vector3(cos(a) * radius, 0.7, sin(a) * radius), Vector3(1.0, 1.4, 1.2), -a, key, false)


## A box with an arbitrary orientation (no collision): slanted mouldings.
func obox(center: Vector3, size: Vector3, basis: Basis, key: String) -> void:
	var h := size * 0.5
	var p := func(x: float, y: float, z: float) -> Vector3:
		return center + basis * Vector3(x * h.x, y * h.y, z * h.z)
	quad(key, p.call(1, -1, 1), p.call(1, -1, -1), p.call(1, 1, -1), p.call(1, 1, 1), center)
	quad(key, p.call(-1, -1, -1), p.call(-1, -1, 1), p.call(-1, 1, 1), p.call(-1, 1, -1), center)
	quad(key, p.call(-1, 1, 1), p.call(1, 1, 1), p.call(1, 1, -1), p.call(-1, 1, -1), center)
	quad(key, p.call(-1, -1, -1), p.call(1, -1, -1), p.call(1, -1, 1), p.call(-1, -1, 1), center)
	quad(key, p.call(-1, -1, 1), p.call(1, -1, 1), p.call(1, 1, 1), p.call(-1, 1, 1), center)
	quad(key, p.call(1, -1, -1), p.call(-1, -1, -1), p.call(-1, 1, -1), p.call(1, 1, -1), center)


static func _hash01(v: Vector3) -> float:
	return fposmod(sin(v.dot(Vector3(12.9898, 78.233, 37.719))) * 43758.5453, 1.0)


## A Gothic lancet set into a wall facing `normal`: leaded glass recessed
## behind a stone reveal (jambs, sill, pointed arch), a mullion and a transom.
## The glass carries a per-window random in its vertex colour (r: lit or dark,
## g: warmth) for the window shader.
func window(center: Vector3, normal: Vector3, width: float, height: float, frame_key: String, glass_key: String) -> void:
	var n := Vector3(normal.x, 0, normal.z).normalized()
	var rot := atan2(n.x, n.z)
	var side := Vector3(n.z, 0, -n.x)
	var depth := 0.34
	var jamb := clampf(width * 0.17, 0.14, 0.24)
	var head := width * 0.55
	vertex_color = Color(_hash01(center), _hash01(center + Vector3(3.1, 1.7, 7.3)), 0.0, 1.0)
	box(center + n * 0.03, Vector3(width, height, 0.06), rot, glass_key, false)
	# the pointed head's glass: a stack of narrowing panes under the arch
	for i in 3:
		var t := (float(i) + 0.5) / 3.0
		box(center + n * 0.03 + Vector3.UP * (height * 0.5 + head * t * 0.95 - head * 0.16),
			Vector3(width * (1.0 - t * 0.78), head / 3.0 + 0.02, 0.06), rot, glass_key, false)
	vertex_color = null
	var out := n * (depth * 0.5 + 0.02)
	for s in [-1.0, 1.0]:
		box(center + side * s * (width * 0.5 + jamb * 0.5) + out, Vector3(jamb, height + 0.1, depth), rot, frame_key, false)
	box(center + Vector3.UP * (-height * 0.5 - 0.09) + n * (depth * 0.5 + 0.08), Vector3(width + jamb * 2.0 + 0.3, 0.18, depth + 0.16), rot, frame_key, false)
	# pointed arch: two slanted voussoir bars meeting at the apex
	var apex := center + Vector3.UP * (height * 0.5 + head) + out
	for s in [-1.0, 1.0]:
		var foot: Vector3 = center + side * s * (width * 0.5 + jamb * 0.5) + Vector3.UP * (height * 0.5) + out
		var along := apex - foot
		var y_axis := along.normalized()
		var basis := Basis(y_axis.cross(n).normalized(), y_axis, n)
		obox((foot + apex) * 0.5, Vector3(jamb, along.length() + jamb * 0.6, depth), basis, frame_key)
	# mullion and transom
	box(center + n * 0.07, Vector3(0.07, height, 0.07), rot, frame_key, false)
	box(center + n * 0.07 + Vector3.UP * (height * 0.12), Vector3(width, 0.07, 0.07), rot, frame_key, false)


## Windows around a tower at height y above its base.
func tower_windows(base: Vector3, radius: float, y: float, count: int, frame_key: String, glass_key: String,
		w: float = 1.0, h: float = 2.0, phase: float = 0.0) -> void:
	for i in count:
		var a := TAU * i / count + phase
		var n := Vector3(cos(a), 0, sin(a))
		window(base + n * (radius - 0.02) + Vector3.UP * y, n, w, h, frame_key, glass_key)


## Commit: one MeshInstance3D per material key, one StaticBody3D for all shapes.
func finish(parent: Node3D, materials: Dictionary, name_prefix: String, collision_layer: int = 1,
		visuals: bool = true) -> Node3D:
	var root := Node3D.new()
	root.name = name_prefix
	parent.add_child(root)
	if visuals:
		for key in _tools:
			var st: SurfaceTool = _tools[key]
			var mi := MeshInstance3D.new()
			mi.name = "%s_%s" % [name_prefix, key]
			mi.mesh = st.commit()
			if materials.has(key):
				mi.material_override = materials[key]
			root.add_child(mi)
	if not _shapes.is_empty():
		var body := StaticBody3D.new()
		body.name = name_prefix + "_Collision"
		body.collision_layer = collision_layer
		body.collision_mask = 0
		root.add_child(body)
		for entry in _shapes:
			var cs := CollisionShape3D.new()
			cs.shape = entry[0]
			cs.transform = entry[1]
			body.add_child(cs)
	_tools.clear()
	_shapes.clear()
	return root
