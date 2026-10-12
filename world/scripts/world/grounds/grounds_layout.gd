extends RefCounted
class_name GroundsLayout

## The grounds design as the game reads it: a copy of art/map/layout.json written
## by tools/terrain/build_grounds.gd (landmarks, roads, regions, lake). The terrain
## and every building placement come from the same file, so a moved landmark moves
## its building with it.

const PATH := "res://assets/terrain/grounds/layout.json"

static var _data: Dictionary = {}


static func data() -> Dictionary:
	if _data.is_empty():
		var parsed = JSON.parse_string(FileAccess.get_file_as_string(PATH))
		_data = parsed if parsed is Dictionary else {}
	return _data


## Landmark position on the ground (x, ground y, z); Vector3.INF if unknown.
static func landmark(id: String) -> Vector3:
	for l in data().get("landmarks", []):
		if String(l.get("id", "")) == id:
			var p: Array = l["pos"]
			return ground(float(p[0]), float(p[1]))
	return Vector3.INF


## Point on the ground at (x, z); y = 0 if the terrain is not loaded.
static func ground(x: float, z: float) -> Vector3:
	var h := GroundsTerrain.height_at(x, z)
	return Vector3(x, 0.0 if is_nan(h) else h, z)


static func road(id: String) -> Dictionary:
	for r in data().get("roads", []):
		if String(r.get("id", "")) == id:
			return r
	return {}


static func roads() -> Array:
	return data().get("roads", [])


## Distance on the XZ plane from p to the nearest road centre line.
static func road_distance(p: Vector2) -> float:
	var best := INF
	for r in roads():
		var pts: Array = r["points"]
		for i in pts.size() - 1:
			var a := Vector2(pts[i][0], pts[i][1])
			var b := Vector2(pts[i + 1][0], pts[i + 1][1])
			best = minf(best, Geometry2D.get_closest_point_to_segment(p, a, b).distance_to(p) - float(r.get("width", 4.0)) * 0.5)
	return best


## Height range (min, max) of the ground over a rotated rectangle.
static func ground_span(center: Vector2, size: Vector2, rot_y: float = 0.0) -> Vector2:
	var lo := INF
	var hi := -INF
	var b := Basis(Vector3.UP, rot_y)
	for i in 4:
		for j in 4:
			var o := b * Vector3((i / 3.0 - 0.5) * size.x, 0, (j / 3.0 - 0.5) * size.y)
			var h := GroundsTerrain.height_at(center.x + o.x, center.y + o.z)
			if is_nan(h):
				continue
			lo = minf(lo, h)
			hi = maxf(hi, h)
	return Vector2(lo, hi) if lo != INF else Vector2.ZERO
