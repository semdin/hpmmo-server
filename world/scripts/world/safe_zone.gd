extends RefCounted

## SafeZone — data-defined protected volumes (plan Phase 1).
##
## Volumes live in data/json/safe_zones.json and are loaded into
## GameData.SAFE_ZONES at startup. DEFAULT_ZONES mirrors the same authored
## values so protection never silently disappears if the file is missing.
## A point is protected when it lies inside a volume's XZ footprint and its
## y is inside [y_min, y_max]. Volumes are authored around real places
## (NPC/training courtyard, castle approach, village square) rather than a
## bare distance from the world origin.

const DEFAULT_ZONES: Array = [
	{"id": "courtyard", "shape": "cylinder", "center": [0.0, 0.0, 0.0], "radius": 21.0, "y_min": -10.0, "y_max": 200.0},
	{"id": "castle_approach", "shape": "cylinder", "center": [0.0, 0.0, -28.0], "radius": 12.0, "y_min": -10.0, "y_max": 200.0},
	{"id": "village_square", "shape": "cylinder", "center": [35.0, 0.0, 20.0], "radius": 9.0, "y_min": -10.0, "y_max": 200.0},
]
const DEFAULT_SPAWN_BUFFER := 8.0

static var _zones: Array = []
static var _spawn_buffer: float = DEFAULT_SPAWN_BUFFER

## Re-read the authored zones (used by tests / hot-reload).
static func reload() -> void:
	_zones = []
	_spawn_buffer = DEFAULT_SPAWN_BUFFER
	_ensure_loaded()

static func _ensure_loaded() -> void:
	if not _zones.is_empty():
		return
	var zones: Array = []
	var buffer: float = DEFAULT_SPAWN_BUFFER
	var src = GameData.SAFE_ZONES
	if src is Dictionary and not (src as Dictionary).is_empty():
		var authored = src.get("zones", [])
		if authored is Array and not (authored as Array).is_empty():
			zones = authored
		buffer = float(src.get("spawn_buffer", DEFAULT_SPAWN_BUFFER))
	if zones.is_empty():
		zones = DEFAULT_ZONES
	_zones = zones
	_spawn_buffer = buffer

## True when the point is inside any protected volume.
static func is_protected_point(point: Vector3) -> bool:
	_ensure_loaded()
	for zone in _zones:
		if _point_in_zone(point, zone, 0.0):
			return true
	return false

## Convenience for nodes; non-Node3D nodes are never protected.
static func is_protected_node(node: Node) -> bool:
	if node is Node3D:
		return is_protected_point((node as Node3D).global_position)
	return false

## True when an encounter spawn anchor is inside a volume or its spawn buffer.
static func is_spawn_blocked(point: Vector3) -> bool:
	_ensure_loaded()
	for zone in _zones:
		if _point_in_zone(point, zone, _spawn_buffer):
			return true
	return false

static func _point_in_zone(point: Vector3, zone: Dictionary, pad: float) -> bool:
	var y_min: float = float(zone.get("y_min", -10.0))
	var y_max: float = float(zone.get("y_max", 200.0))
	if point.y < y_min or point.y > y_max:
		return false
	var c = zone.get("center", [0.0, 0.0, 0.0])
	var center := Vector3(float(c[0]), float(c[1]), float(c[2]))
	if String(zone.get("shape", "cylinder")) == "box":
		var s = zone.get("size", [0.0, 0.0, 0.0])
		var half := Vector3(float(s[0]), float(s[1]), float(s[2])) * 0.5 + Vector3.ONE * pad
		var d := point - center
		return absf(d.x) <= half.x and absf(d.y) <= half.y and absf(d.z) <= half.z
	var radius: float = float(zone.get("radius", 0.0)) + pad
	var dx := point.x - center.x
	var dz := point.z - center.z
	return dx * dx + dz * dz <= radius * radius
