extends RefCounted
class_name WaypointRouter

## Routes for the map waypoint (WaypointGuide): a walkable path from a point to
## a target on the same map, as world-space points.
##
## Grounds: A* over an 8 m grid of the terrain (AStarGrid2D). Steep cells cost
## more and cliffs are closed, the Black Lake is closed, the castle shell is
## closed, and road cells are cheap so a route prefers the paths.
## Castle interior: a graph built from the layout (assets/castle/castle_layout.json):
## every door and every stair end is a node, two nodes are joined when they
## stand in the same room / floor plate on the same level (rooms are rectangles,
## so the straight line between them stays inside), and a stair joins its two
## ends. The moving staircases are left out: the fixed stairs always connect.

const CELL := 8.0
const ORIGIN := Vector2(-1024.0, -1024.0)
const SIZE := 256
const WATER_Y := 0.35
const MAX_SLOPE := 1.15        # rise / run beyond which a cell is a cliff
## The castle shell on the grounds (castle_exterior.gd CURTAIN + ORIGIN z -50).
const CASTLE_RING := [[-64.0, -4.0], [-66.0, -68.0], [-46.0, -102.0], [0.0, -98.0], [42.0, -104.0],
	[62.0, -84.0], [64.0, -44.0], [62.0, -6.0]]
const LAYOUT := "res://assets/castle/castle_layout.json"
## The interior map's vertical datum: layout L0 sits at world y 200.
const CASTLE_Y := 200.0

static var _grid: AStarGrid2D = null
static var _heights := PackedFloat32Array()
static var _castle: Dictionary = {}


# ------------------------------------------------------------------ grounds

static func grounds_ready() -> bool:
	return _grid != null

static func _height(x: float, z: float) -> float:
	var h := GroundsTerrain.height_at(x, z)
	return 0.0 if is_nan(h) else h

static func _build_grounds() -> bool:
	if GroundsTerrain.active() == null:
		return false
	_heights.resize((SIZE + 1) * (SIZE + 1))
	for j in SIZE + 1:
		for i in SIZE + 1:
			_heights[j * (SIZE + 1) + i] = _height(ORIGIN.x + i * CELL, ORIGIN.y + j * CELL)
	var grid := AStarGrid2D.new()
	grid.region = Rect2i(0, 0, SIZE, SIZE)
	grid.cell_size = Vector2.ONE
	grid.diagonal_mode = AStarGrid2D.DIAGONAL_MODE_ONLY_IF_NO_OBSTACLES
	grid.default_compute_heuristic = AStarGrid2D.HEURISTIC_OCTILE
	grid.default_estimate_heuristic = AStarGrid2D.HEURISTIC_OCTILE
	grid.update()
	var ring := PackedVector2Array()
	for p in CASTLE_RING:
		ring.append(Vector2(p[0], p[1]))
	var road_cells := {}
	for r in GroundsLayout.roads():
		var pts: Array = r["points"]
		for k in pts.size() - 1:
			var a := Vector2(pts[k][0], pts[k][1])
			var b := Vector2(pts[k + 1][0], pts[k + 1][1])
			var steps := int(ceil(a.distance_to(b) / (CELL * 0.5)))
			for s in steps + 1:
				var p := a.lerp(b, float(s) / maxf(1, steps))
				road_cells[_cell(p)] = true
	var court3 := GroundsLayout.landmark("courtyard")
	var court := Vector2(court3.x, court3.z) if court3 != Vector3.INF else Vector2(INF, INF)
	for j in SIZE:
		for i in SIZE:
			var h00 := _heights[j * (SIZE + 1) + i]
			var h10 := _heights[j * (SIZE + 1) + i + 1]
			var h01 := _heights[(j + 1) * (SIZE + 1) + i]
			var h11 := _heights[(j + 1) * (SIZE + 1) + i + 1]
			var centre := Vector2(ORIGIN.x + (i + 0.5) * CELL, ORIGIN.y + (j + 0.5) * CELL)
			var lo := minf(minf(h00, h10), minf(h01, h11))
			var slope := maxf(absf(h00 - h11), absf(h10 - h01)) / (CELL * 1.414)
			var cell := Vector2i(i, j)
			if (h00 + h10 + h01 + h11) * 0.25 < WATER_Y or lo < WATER_Y - 0.6 or slope > MAX_SLOPE \
					or Geometry2D.is_point_in_polygon(centre, ring) or centre.distance_to(court) < GroundsCourtyard.BALUSTRADE_R + 1.0 or i < 2 or j < 2 or i > SIZE - 3 or j > SIZE - 3:
				grid.set_point_solid(cell, true)
				continue
			var weight := 1.0 + slope * 6.0
			if road_cells.has(cell):
				weight *= 0.45
			grid.set_point_weight_scale(cell, weight)
	_grid = grid
	return true

static func _cell(p: Vector2) -> Vector2i:
	return Vector2i(clampi(int(floor((p.x - ORIGIN.x) / CELL)), 0, SIZE - 1),
		clampi(int(floor((p.y - ORIGIN.y) / CELL)), 0, SIZE - 1))

static func _nearest_open(c: Vector2i) -> Vector2i:
	if not _grid.is_point_solid(c):
		return c
	for r in range(1, 12):
		for dj in range(-r, r + 1):
			for di in range(-r, r + 1):
				if absi(di) != r and absi(dj) != r:
					continue
				var n := c + Vector2i(di, dj)
				if _grid.is_in_boundsv(n) and not _grid.is_point_solid(n):
					return n
	return c

## World points (terrain heights) from `from` to `to`. The walled courtyard
## (GroundsCourtyard) is left and entered through its path openings.
static func grounds_path(from: Vector3, to: Vector3) -> PackedVector3Array:
	if _grid == null and not _build_grounds():
		return PackedVector3Array([from, to])
	var court := GroundsLayout.landmark("courtyard")
	if court != Vector3.INF:
		var c2 := Vector2(court.x, court.z)
		var inside_from := Vector2(from.x, from.z).distance_to(c2) < GroundsCourtyard.BALUSTRADE_R
		var inside_to := Vector2(to.x, to.z).distance_to(c2) < GroundsCourtyard.BALUSTRADE_R
		if inside_from and inside_to:
			return _drape([Vector2(from.x, from.z), Vector2(to.x, to.z)])
		if inside_from or inside_to:
			var inner := Vector2(from.x, from.z) if inside_from else Vector2(to.x, to.z)
			var outer := Vector2(to.x, to.z) if inside_from else Vector2(from.x, from.z)
			var best: Array = []
			var best_cost := INF
			for heading in GroundsCourtyard.PATHS:
				var d := Vector2(cos(heading), sin(heading))
				var gate_in := c2 + d * (GroundsCourtyard.PLAZA_R - 1.0)
				var gate_out := c2 + d * (GroundsCourtyard.LAWN_OUT + 3.0)
				var cost := inner.distance_to(gate_in) + gate_in.distance_to(gate_out) + gate_out.distance_to(outer)
				if cost < best_cost:
					best_cost = cost
					best = [gate_in, gate_out]
			var leg := _drape([inner, best[0], best[1]])
			var gate3 := Vector3(best[1].x, 0.0, best[1].y)
			var rest := _grid_path(gate3, to) if inside_from else _grid_path(from, gate3)
			if inside_from:
				leg.remove_at(leg.size() - 1)
				leg.append_array(rest)
				return leg
			leg.reverse()
			rest.remove_at(rest.size() - 1)
			rest.append_array(leg)
			return rest
	return _grid_path(from, to)

static func _drape(pts: Array) -> PackedVector3Array:
	var out := PackedVector3Array()
	var dense: Array = [pts[0]]
	for k in pts.size() - 1:
		var a: Vector2 = pts[k]
		var b: Vector2 = pts[k + 1]
		var n := maxi(1, int(ceil(a.distance_to(b) / 6.0)))
		for s in range(1, n + 1):
			dense.append(a.lerp(b, float(s) / n))
	for p: Vector2 in dense:
		out.append(Vector3(p.x, _height(p.x, p.y), p.y))
	return out

static func _grid_path(from: Vector3, to: Vector3) -> PackedVector3Array:
	var a := _nearest_open(_cell(Vector2(from.x, from.z)))
	var b := _nearest_open(_cell(Vector2(to.x, to.z)))
	var cells := _grid.get_id_path(a, b, true)
	var pts: Array = [Vector2(from.x, from.z)]
	for k in range(1, cells.size() - 1):
		var c: Vector2i = cells[k]
		pts.append(Vector2(ORIGIN.x + (c.x + 0.5) * CELL, ORIGIN.y + (c.y + 0.5) * CELL))
	pts.append(Vector2(to.x, to.z))
	pts = _smooth(_simplify(pts))
	var out := PackedVector3Array()
	for p: Vector2 in pts:
		out.append(Vector3(p.x, _height(p.x, p.y), p.y))
	return out

## Drop grid points a straight walk can skip (no solid cell under the line).
static func _simplify(pts: Array) -> Array:
	if pts.size() < 3:
		return pts
	var out: Array = [pts[0]]
	var k := 0
	while k < pts.size() - 1:
		var far := k + 1
		for m in range(pts.size() - 1, k + 1, -1):
			if _clear(pts[k], pts[m]):
				far = m
				break
		out.append(pts[far])
		k = far
	return out

static func _clear(a: Vector2, b: Vector2) -> bool:
	var steps := int(ceil(a.distance_to(b) / (CELL * 0.5)))
	if steps > 60:
		return false
	for s in range(1, steps):
		if _grid.is_point_solid(_cell(a.lerp(b, float(s) / steps))):
			return false
	return true

## Chaikin corner cutting, twice: soft bends instead of grid elbows.
static func _smooth(pts: Array) -> Array:
	var out := pts
	for _pass in 2:
		if out.size() < 3:
			return out
		var next: Array = [out[0]]
		for k in out.size() - 1:
			var a: Vector2 = out[k]
			var b: Vector2 = out[k + 1]
			next.append(a.lerp(b, 0.25))
			next.append(a.lerp(b, 0.75))
		next.append(out[-1])
		out = next
	# resample: no leg longer than 12 m, so the draped heights follow the hills
	var dense: Array = [out[0]]
	for k in out.size() - 1:
		var a: Vector2 = out[k]
		var b: Vector2 = out[k + 1]
		var n := maxi(1, int(ceil(a.distance_to(b) / 12.0)))
		for s in range(1, n + 1):
			dense.append(a.lerp(b, float(s) / n))
	return dense


# ------------------------------------------------------------------ castle

static func castle_layout() -> Dictionary:
	if _castle.is_empty():
		var parsed = JSON.parse_string(FileAccess.get_file_as_string(LAYOUT))
		_castle = parsed if parsed is Dictionary else {}
	return _castle

## Walkable plates: [rect [x0, x1, z0, z1], y (layout), label].
static func castle_plates() -> Array:
	var out := []
	var d := castle_layout()
	for r in d.get("rooms", []):
		out.append([r["rect"], float(r["y"]), String(r.get("label", r.get("id", "")))])
	for f in d.get("floors", []):
		out.append([f["rect"], float(f["y"]), ""])
	return out

static func _in_rect(rect: Array, x: float, z: float, grow: float) -> bool:
	return x >= float(rect[0]) - grow and x <= float(rect[1]) + grow and z >= float(rect[2]) - grow and z <= float(rect[3]) + grow

static func castle_path(from: Vector3, to: Vector3) -> PackedVector3Array:
	var d := castle_layout()
	if d.is_empty():
		return PackedVector3Array([from, to])
	var a_local := from - Vector3(0, CASTLE_Y, 0)
	var b_local := to - Vector3(0, CASTLE_Y, 0)
	var plates := castle_plates()
	# nodes: [position (layout space)]
	var nodes: Array = []
	var edges: Array = []          # [i, j]
	for door in d.get("doors", []):
		var at: Array = door["at"]
		nodes.append(Vector3(float(at[0]), float(door["y"]), float(at[1])))
	for stair in d.get("stairs", []):
		var f: Array = stair["from"]
		var t: Array = stair["to"]
		nodes.append(Vector3(float(f[0]), float(f[1]), float(f[2])))
		nodes.append(Vector3(float(t[0]), float(t[1]), float(t[2])))
		edges.append([nodes.size() - 2, nodes.size() - 1])
	var start := nodes.size()
	nodes.append(a_local)
	nodes.append(b_local)
	# plate membership (doors sit in walls: grow the rects by a wall's width)
	var members := {}
	for i in nodes.size():
		var p: Vector3 = nodes[i]
		var grow := 0.3 if i >= start else 3.2
		for k in plates.size():
			var plate: Array = plates[k]
			if absf(p.y - float(plate[1])) < 1.6 and _in_rect(plate[0], p.x, p.z, grow):
				if not members.has(k):
					members[k] = []
				members[k].append(i)
	for k in members:
		var list: Array = members[k]
		for m in list.size():
			for n in range(m + 1, list.size()):
				edges.append([list[m], list[n]])
	var astar := AStar3D.new()
	for i in nodes.size():
		astar.add_point(i, nodes[i])
	for e in edges:
		if not astar.are_points_connected(e[0], e[1]):
			astar.connect_points(e[0], e[1])
	var ids := astar.get_id_path(start, start + 1)
	if ids.is_empty():
		return PackedVector3Array([from, to])
	var out := PackedVector3Array()
	for id in ids:
		out.append(nodes[id] + Vector3(0, CASTLE_Y, 0))
	return _dense3(out, 3.0)

static func _dense3(pts: PackedVector3Array, leg: float) -> PackedVector3Array:
	var out := PackedVector3Array()
	if pts.is_empty():
		return out
	out.append(pts[0])
	for k in pts.size() - 1:
		var n := maxi(1, int(ceil(pts[k].distance_to(pts[k + 1]) / leg)))
		for s in range(1, n + 1):
			out.append(pts[k].lerp(pts[k + 1], float(s) / n))
	return out

## The castle storey (layout level index) of a world point: L-1 .. L7.
static func castle_level(world_y: float) -> int:
	return clampi(int(floor((world_y - CASTLE_Y + 2.0) / 10.0)), -1, 7)
