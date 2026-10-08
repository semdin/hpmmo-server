extends RefCounted
class_name HPMaps

## Map catalog. OWNER: server repository; the client runs the
## synced copy, exactly like HPRules.
##
## `data/maps.json` is the one authored file both processes agree on: which maps
## exist, each map's spawn points, its safe-zone references (`safe_zones.json`
## ids that apply there), the entity set that spawns on it (the `map_id` of
## `spawn_tables.json`), its flight rule and player capacity, and the portals
## between maps. The authority validates every transfer against it; clients load
## one map at a time and build trigger volumes, landing pads and labels from the
## same data.
##
## Map membership is a y-band: the grounds own everything below 185, the castle
## interior is authored above it. The two maps never overlap in space, which is
## what lets the server keep both registered while a client has one loaded, and
## what makes the interest filter's map check the outer scope of replication.

const DATA_PATH := "res://addons/hpmmo_sim/data/maps.json"

static var _data: Dictionary = {}
static var _loaded := false

# ---------------------------------------------------------------- data access

static func ensure_loaded() -> void:
	if _loaded:
		return
	_loaded = true
	if not FileAccess.file_exists(DATA_PATH):
		push_error("[HPMaps] missing map catalog: %s" % DATA_PATH)
		_data = {}
		return
	var file := FileAccess.open(DATA_PATH, FileAccess.READ)
	if file == null:
		push_error("[HPMaps] cannot open map catalog: %s" % DATA_PATH)
		_data = {}
		return
	var parsed: Variant = JSON.parse_string(file.get_as_text())
	file.close()
	_data = parsed if parsed is Dictionary else {}
	if _data.is_empty():
		push_error("[HPMaps] malformed map catalog: %s" % DATA_PATH)

static func reload() -> void:
	_loaded = false
	ensure_loaded()

static func data() -> Dictionary:
	ensure_loaded()
	return _data

static func maps() -> Dictionary:
	ensure_loaded()
	return _data.get("maps", {})

static func map_info(map_id: String) -> Dictionary:
	return maps().get(map_id, {})

static func map_exists(map_id: String) -> bool:
	return maps().has(map_id)

## A map can be authored but temporarily unavailable (content not shipped, a
## zone disabled for maintenance). Transfers only target available maps.
static func map_available(map_id: String) -> bool:
	var info := map_info(map_id)
	if info.is_empty():
		return false
	return bool(info.get("available", true))

static func map_ids() -> Array:
	return maps().keys()

static func display_name(map_id: String) -> String:
	return String(map_info(map_id).get("display", map_id))

static func flight_allowed(map_id: String) -> bool:
	return bool(map_info(map_id).get("flight_allowed", true))

## Player capacity of a map; the authority refuses a transfer into a full one.
static func capacity(map_id: String) -> int:
	var base := int(map_info(map_id).get("capacity", 64))
	# Test affordance (never set in production): clamps every map's capacity so
	# a "destination full" refusal can be exercised with two clients.
	var raw := OS.get_environment("HPMMO_DEV_MAP_CAPACITY")
	if raw != "" and raw.is_valid_int():
		base = mini(base, maxi(1, int(raw)))
	return maxi(1, base)

## Safe-zone ids (`safe_zones.json`) that apply on this map. A volume is only
## evaluated on the maps that reference it, so an outdoor volume can never
## protect a position inside the castle.
static func safe_zone_ids(map_id: String) -> Array:
	return map_info(map_id).get("safe_zones", [])

## The `spawn_tables.json` entity set that populates this map; "" means the map
## has no authored encounters (a greybox interior).
static func entity_set(map_id: String) -> String:
	return String(map_info(map_id).get("entity_set", ""))

# ------------------------------------------------------------- map membership

static func y_min(map_id: String) -> float:
	return float(map_info(map_id).get("y_min", -1000.0))

static func y_max(map_id: String) -> float:
	return float(map_info(map_id).get("y_max", 1000.0))

static func contains_point(map_id: String, point: Vector3) -> bool:
	var info := map_info(map_id)
	if info.is_empty():
		return false
	return point.y >= float(info.get("y_min", -1000.0)) and point.y <= float(info.get("y_max", 1000.0))

## The map whose authored band contains this point. Bands are disjoint, so the
## answer is a membership test, not a guess; a point outside every band falls
## back to the map whose respawn is nearest in height.
static func map_for_point(point: Vector3) -> String:
	ensure_loaded()
	var best := ""
	var best_distance := INF
	for id in maps().keys():
		var map_id := String(id)
		if contains_point(map_id, point):
			return map_id
		var distance: float = absf(point.y - respawn_point(map_id).y)
		if distance < best_distance:
			best_distance = distance
			best = map_id
	if best == "":
		return HPProtocol.DEFAULT_MAP
	return best

## A server-approved position on `map_id`: the point itself when it lies inside
## the map's band, otherwise that map's authored respawn.
static func valid_position(map_id: String, point: Vector3) -> Vector3:
	if contains_point(map_id, point):
		return point
	return respawn_point(map_id)

# --------------------------------------------------------------- spawn points

static func _spawn_table(map_id: String) -> Dictionary:
	return map_info(map_id).get("spawn_points", {})

static func has_spawn_point(map_id: String, spawn_id: String) -> bool:
	return _spawn_table(map_id).has(spawn_id)

static func spawn_point(map_id: String, spawn_id: String) -> Vector3:
	var table := _spawn_table(map_id)
	var raw: Array = table.get(spawn_id, table.get("default", []))
	return _to_vec3(raw, Vector3(0.0, 0.5, 5.0))

static func default_spawn(map_id: String) -> Vector3:
	return spawn_point(map_id, "default")

## Where this map puts a dead, stranded or failed-transfer character. Always a
## valid, walkable authored location - never a half-transferred position.
static func respawn_point(map_id: String) -> Vector3:
	var table := _spawn_table(map_id)
	var id := String(map_info(map_id).get("respawn_spawn", "default"))
	var raw: Array = table.get(id, table.get("default", []))
	return _to_vec3(raw, Vector3(0.0, 0.5, 5.0))

# ------------------------------------------------------------------- portals

static func portals() -> Array:
	ensure_loaded()
	return _data.get("portals", [])

static func portal(portal_id: String) -> Dictionary:
	for entry in portals():
		if entry is Dictionary and String(entry.get("id", "")) == portal_id:
			return entry
	return {}

static func portals_for_map(map_id: String) -> Array:
	var out: Array = []
	for entry in portals():
		if entry is Dictionary and String(entry.get("map_id", "")) == map_id:
			out.append(entry)
	return out

## The portal on `map_id` that leads to `to_map`, if one exists.
static func portal_between(map_id: String, to_map: String) -> Dictionary:
	for entry in portals_for_map(map_id):
		if String(entry.get("to_map", "")) == to_map:
			return entry
	return {}

## True when `point` stands inside the portal's trigger volume. The authority
## checks ITS OWN body position against this before reserving a transfer: a
## forged request from anywhere in the world is not a transfer.
static func portal_contains(entry: Dictionary, point: Vector3) -> bool:
	var trigger: Dictionary = entry.get("trigger", {})
	if trigger.is_empty():
		return false
	if point.y < float(trigger.get("y_min", -1000.0)) or point.y > float(trigger.get("y_max", 1000.0)):
		return false
	var center := _to_vec3(trigger.get("center", []), Vector3.ZERO)
	var dx := point.x - center.x
	var dz := point.z - center.z
	var radius := float(trigger.get("radius", 0.0))
	return (dx * dx + dz * dz) <= radius * radius

# -------------------------------------------------------------------- helpers

static func _to_vec3(raw: Array, fallback: Vector3) -> Vector3:
	if raw.size() != 3:
		return fallback
	return Vector3(float(raw[0]), float(raw[1]), float(raw[2]))
