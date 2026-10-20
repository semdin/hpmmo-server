extends Node3D
class_name WaypointGuide

## The map waypoint (right-click on the M map): a target, the route to it
## (WaypointRouter) and the way the route is shown in the world.
##   * On foot: Marauder's-Map footprints. A steady trail of left/right prints
##     from the player's feet along the route for the next stretch, pinned to
##     the route (they do not swim as you walk) with a glow rippling forward;
##     new prints ink in ahead as you go, however fast you move.
##   * In the air (on the broom, or well above the ground): a line of gold
##     chevrons gliding toward the target at flying height, straight there.
##   * Always: a column of light over the target, seen from far away.
## A target on another map routes to the portal that leads there first (e.g. a
## room in the castle from the grounds: to the front doors). Client only.

signal changed
signal arrived

const FOOTPRINT_SHADER := preload("res://assets/shaders/footprint.gdshader")
const BEACON_SHADER := preload("res://assets/shaders/waypoint_beacon.gdshader")
const STRIDE := 0.8
const TRAIL := 4.0                # prints the forward ripple lights at once
const AHEAD := 10.0               # metres of route shown ahead of the player
const RIPPLE_SPEED := 6.0         # prints per second the glow runs forward
const MAX_PRINTS := 14
const CHEVRONS := 22
const CHEVRON_SPACING := 8.0
const ARRIVE_RADIUS := 5.0
## Over open ground a broom overhead counts as arrived: the height check only
## matters where floors stack (castle storeys, caverns).
const ARRIVE_RADIUS_AIR := 12.0
const ARRIVE_AIR_HEIGHT := 120.0
## Off the route by this much (cut a corner, flew, got knocked) and the route
## is planned again from where you stand, so the prints start at your feet.
const OFF_ROUTE := 6.0

var world: Node3D = null
var player: Node3D = null
var target_map := ""
var target := Vector3.INF
## The route on the current map, and its cumulative length per point.
var path := PackedVector3Array()
var _arc := PackedFloat32Array()
var _path_map := ""
var _goal := Vector3.INF
var _ripple := 0.0
var _flow := 0.0
var _reroute_wait := 0.0
var _seg := 0

var _prints: MultiMeshInstance3D
var _chevrons: MultiMeshInstance3D
var _beacon: MeshInstance3D


static func find(tree: SceneTree) -> WaypointGuide:
	return tree.get_first_node_in_group("waypoint_guide") as WaypointGuide


func _ready() -> void:
	add_to_group("waypoint_guide")
	top_level = true
	_prints = _multimesh("Footprints", Vector2(0.21, 0.38), FOOTPRINT_SHADER, MAX_PRINTS, false)
	_chevrons = _multimesh("AirRoute", Vector2(2.4, 1.5), BEACON_SHADER, CHEVRONS, true)
	_beacon = MeshInstance3D.new()
	_beacon.name = "Beacon"
	var column := CylinderMesh.new()
	column.top_radius = 1.0
	column.bottom_radius = 1.4
	column.height = 140.0
	column.cap_top = false
	column.cap_bottom = false
	var mat := ShaderMaterial.new()
	mat.shader = BEACON_SHADER
	column.material = mat
	_beacon.mesh = column
	_beacon.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	add_child(_beacon)
	_hide_all()


func _multimesh(node_name: String, quad_size: Vector2, shader: Shader, count: int, chevron: bool) -> MultiMeshInstance3D:
	var quad := QuadMesh.new()
	quad.size = quad_size
	var mat := ShaderMaterial.new()
	mat.shader = shader
	if chevron:
		mat.set_shader_parameter("chevron", true)
	else:
		mat.set_shader_parameter("trail", TRAIL)
	quad.material = mat
	var mm := MultiMesh.new()
	mm.transform_format = MultiMesh.TRANSFORM_3D
	mm.use_custom_data = true
	mm.mesh = quad
	mm.instance_count = count
	mm.visible_instance_count = 0
	var mmi := MultiMeshInstance3D.new()
	mmi.name = node_name
	mmi.multimesh = mm
	mmi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	add_child(mmi)
	return mmi


# ------------------------------------------------------------------ API

func has_target() -> bool:
	return target != Vector3.INF

func set_target(map_id: String, point: Vector3) -> void:
	target_map = map_id
	target = point
	_path_map = ""
	_reroute()
	changed.emit()

func clear() -> void:
	target = Vector3.INF
	target_map = ""
	path = PackedVector3Array()
	_arc = PackedFloat32Array()
	_hide_all()
	changed.emit()

func current_map() -> String:
	if world != null and is_instance_valid(world):
		var mc = world.get("map_controller")
		if mc != null and is_instance_valid(mc):
			return String(mc.get("current_map"))
	return "grounds"

## The route points on the current map (for the HUD map).
func route() -> PackedVector3Array:
	return path


# ------------------------------------------------------------------ routing

func _portal_toward(from_map: String, to_map: String) -> Vector3:
	for entry in HPMaps.portals_for_map(from_map):
		if entry is Dictionary and String(entry.get("to_map", "")) == to_map:
			var c: Array = (entry.get("trigger", {}) as Dictionary).get("center", [])
			if c.size() == 3:
				return Vector3(float(c[0]), float(c[1]), float(c[2]))
	return Vector3.INF

func _reroute() -> void:
	if not has_target() or player == null or not is_instance_valid(player):
		return
	var cur := current_map()
	_goal = target
	if target_map != cur:
		_goal = _portal_toward(cur, target_map)
		if _goal == Vector3.INF:
			# no direct portal (an instanced dungeon...): nothing to walk here
			path = PackedVector3Array()
			_arc = PackedFloat32Array()
			_path_map = cur
			return
	var from := player.global_position
	match cur:
		"grounds":
			path = WaypointRouter.grounds_path(from, _goal)
		"castle_interior":
			path = WaypointRouter.castle_path(from, _goal)
		_:
			path = PackedVector3Array([from, _goal])
	_arc.resize(path.size())
	var total := 0.0
	for i in path.size():
		if i > 0:
			total += path[i - 1].distance_to(path[i])
		_arc[i] = total
	_path_map = cur
	_seg = 0
	changed.emit()


## Arc length of the closest point of the route to `p`, and its distance.
func _project(p: Vector3) -> Vector2:
	var best := INF
	var best_s := 0.0
	var lo := maxi(0, _seg - 40)
	var hi := mini(path.size() - 1, _seg + 80)
	for i in range(lo, hi):
		var a := path[i]
		var b := path[i + 1]
		var ab := b - a
		var t := clampf((p - a).dot(ab) / maxf(ab.length_squared(), 0.0001), 0.0, 1.0)
		var d := p.distance_to(a + ab * t)
		if d < best:
			best = d
			best_s = _arc[i] + ab.length() * t
			_seg = i
	return Vector2(best_s, best)

## Position and heading on the route at arc length s.
func _at(s: float) -> Array:
	s = clampf(s, 0.0, _arc[_arc.size() - 1])
	var i := _seg
	while i > 0 and _arc[i] > s:
		i -= 1
	while i < path.size() - 2 and _arc[i + 1] < s:
		i += 1
	var a := path[i]
	var b := path[i + 1]
	var seg_len := maxf(0.0001, _arc[i + 1] - _arc[i])
	var p := a.lerp(b, clampf((s - _arc[i]) / seg_len, 0.0, 1.0))
	var dir := Vector3(b.x - a.x, 0.0, b.z - a.z)
	return [p, dir.normalized() if dir.length_squared() > 0.0001 else Vector3.FORWARD]


# ------------------------------------------------------------------ frame

func _hide_all() -> void:
	if _prints != null:
		_prints.multimesh.visible_instance_count = 0
		_chevrons.multimesh.visible_instance_count = 0
		_beacon.visible = false

func _process(delta: float) -> void:
	if not has_target():
		return
	if player == null or not is_instance_valid(player):
		if world != null and is_instance_valid(world):
			player = world.get("local_player")
		if player == null:
			return
	var cur := current_map()
	var p := player.global_position
	if cur == target_map and _arrived(p, cur):
		clear()
		arrived.emit()
		return
	_reroute_wait = maxf(0.0, _reroute_wait - delta)
	if _path_map != cur and _reroute_wait <= 0.0:
		_reroute_wait = 1.0
		_reroute()
	if path.size() < 2:
		_hide_all()
		return
	var proj := _project(p)
	if proj.y > OFF_ROUTE and _reroute_wait <= 0.0:
		_reroute_wait = 0.6
		_reroute()
		if path.size() < 2:
			return
		proj = _project(p)
	_beacon.visible = _goal != Vector3.INF
	if _beacon.visible:
		_beacon.global_position = _goal + Vector3(0, 70.0, 0)
	var flying := bool(player.get("is_mounted"))
	if not flying and cur == "grounds":
		var ground := GroundsTerrain.height_at(p.x, p.z)
		flying = not is_nan(ground) and p.y - ground > 4.0
	if flying:
		_prints.multimesh.visible_instance_count = 0
		_draw_air(delta, p)
	else:
		_chevrons.multimesh.visible_instance_count = 0
		_draw_prints(delta, proj.x, cur)


func _arrived(p: Vector3, cur: String) -> bool:
	var flat := Vector2(p.x - target.x, p.z - target.z).length()
	if flat < ARRIVE_RADIUS and absf(p.y - target.y) < 6.0:
		return true
	return cur == "grounds" and flat < ARRIVE_RADIUS_AIR \
			and p.y > target.y - 2.0 and p.y - target.y < ARRIVE_AIR_HEIGHT


func _draw_prints(delta: float, s_player: float, cur: String) -> void:
	var total := _arc[_arc.size() - 1]
	var k_player := s_player / STRIDE
	var first := int(floor(k_player)) + 1
	var last := mini(int(floor(minf(total, s_player + AHEAD) / STRIDE)), first + MAX_PRINTS - 1)
	var count := maxi(1, last - first + 1)
	# The glow runs from the feet to the far end and starts over.
	_ripple = fmod(_ripple + delta * RIPPLE_SPEED, float(count) + TRAIL)
	var mm := _prints.multimesh
	var n := 0
	for k in range(first, last + 1):
		var at: Array = _at(float(k) * STRIDE)
		var pos: Vector3 = at[0]
		var fwd: Vector3 = at[1]
		var right := fwd.cross(Vector3.UP).normalized()
		pos += right * (0.15 if k % 2 == 0 else -0.15)
		if cur == "grounds":
			var h := GroundsTerrain.height_at(pos.x, pos.z)
			if not is_nan(h):
				pos.y = h
			# clear of the draped paving and lawns laid over the terrain
			pos.y += 0.14
		else:
			pos.y += 0.05
		var basis := Basis(right, fwd, Vector3.UP)
		mm.set_instance_transform(n, Transform3D(basis, pos))
		# x: steps since the ripple passed this print; y: how far along the
		# shown stretch it is (the far end fades out, the feet fade in).
		var i := float(k - first)
		mm.set_instance_custom_data(n, Color(_ripple - i, i / float(count), k - k_player, 0))
		n += 1
	mm.visible_instance_count = n


## Ground height under `at` on the current map (terrain outside, a ray onto the
## floors elsewhere); NAN when there is nothing under it.
func _ground_at(at: Vector3) -> float:
	if current_map() == "grounds":
		return GroundsTerrain.height_at(at.x, at.z)
	var query := PhysicsRayQueryParameters3D.create(at + Vector3.UP * 6.0, at + Vector3.DOWN * 30.0, 1)
	var hit := get_world_3d().direct_space_state.intersect_ray(query)
	return NAN if hit.is_empty() else float((hit["position"] as Vector3).y)


func _draw_air(delta: float, p: Vector3) -> void:
	var to := _goal + Vector3(0, 3.0, 0)
	var flat := Vector3(to.x - p.x, 0.0, to.z - p.z)
	var dist := flat.length()
	var mm := _chevrons.multimesh
	if dist < 2.0:
		mm.visible_instance_count = 0
		return
	var fwd := flat / dist
	var right := fwd.cross(Vector3.UP).normalized()
	_flow = fmod(_flow + delta * 9.0, CHEVRON_SPACING)
	var n := 0
	for k in CHEVRONS:
		var s := 6.0 + float(k) * CHEVRON_SPACING + _flow
		if s > dist:
			break
		# hold the rider's height, settle onto the target over the last 60 m
		var y := lerpf(p.y - 1.0, to.y, smoothstep(dist - 60.0, dist, s))
		var pos := p + fwd * s
		# never inside a rise: a low rider's line climbs over the hill ahead
		var ground := _ground_at(pos)
		if not is_nan(ground):
			y = maxf(y, ground + 1.6)
		pos.y = y
		mm.set_instance_transform(n, Transform3D(Basis(right, fwd, Vector3.UP), pos))
		mm.set_instance_custom_data(n, Color(0, 0, 0, 0))
		n += 1
	mm.visible_instance_count = n
