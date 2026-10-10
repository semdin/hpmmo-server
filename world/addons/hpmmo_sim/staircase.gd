extends Node3D
class_name HPStaircase

## Magical staircase ("Magical staircase prototype").
##
## ADDITIVE MODULE. This file is new; it does not change any existing behaviour
## of the simulation package. It is synced to the client like the rest of
## `hpmmo_sim`, so the same code builds the geometry and computes the platform
## transform in both processes.
##
## Ownership split
##   * the authority (world server, or the offline/host process) owns the states,
##     the travel time and the chosen destination, and publishes them;
##   * every other process is a replica: it applies the published transform and
##     never decides anything;
##   * the geometry (greybox) is built from the same spec in both processes, so
##     collision and visuals always move together.
##
## Minimal authority shape (what another workstream's addon can replace with its
## own runtime - see `HPStaircaseNet` for the transport):
##
##   { "state": "docked|boarding_warning|moving|docking",
##     "dock_index": 0, "from_index": 0, "to_index": 1, "cycle": 3,
##     "move_start_tick": 120, "dock_start_tick": 220, "arrive_tick": 250,
##     "p0": Transform3D, "p1": Transform3D, "p2": Transform3D,
##     "origin": Vector3, "map_id": "castle_interior", "rise": 6.0 }
##
## The spec is read from the server-owned map catalog when it carries a
## `staircase` block, and otherwise from DEFAULT_SPEC below. Both use the same
## keys, so a catalog-authored staircase needs no code change here.

const OBJECT_ID := 1
const CATALOG_PATH := "res://addons/hpmmo_sim/data/maps.json"

## Documented states, in the order the plan names them.
const STATE_DOCKED := "docked"
const STATE_BOARDING_WARNING := "boarding_warning"
const STATE_MOVING := "moving"
const STATE_DOCKING := "docking"
const STATE_ORDER := [STATE_DOCKED, STATE_BOARDING_WARNING, STATE_MOVING, STATE_DOCKING]

## Feedback kinds sent to a client whose entry was refused.
const NOTICE_LOCKED := "staircase_locked"

## Group an authority-side resolver registers in (see `resolve_departing_player`).
const GROUP_RESOLVER := "world_object_resolver"

## Fraction of the path covered by `moving`; `docking` closes the last 10% slowly
## so the platform settles onto its landing instead of stopping dead.
const MOVE_FRACTION := 0.9
## Heartbeat so a late joiner receives the current state without a join hook.
const PUBLISH_EVERY_TICKS := 20
## One "entry refused" notice per player per second while the gate is closed.
const NOTICE_INTERVAL_TICKS := 20

## Fallback spec. Keys match the `staircase` block of the map catalog; the
## staircase spans three levels (0 m, 6 m, 12 m) and offers two alternative
## second-floor landings.
const DEFAULT_SPEC := {
	"id": 1,
	"map_id": "castle_interior",
	"origin": [0.0, 0.0, 0.0],
	"flight": {"rise": 6.0, "run": 12.0, "width": 3.0, "step_height": 0.2},
	"timing": {"dwell_ms": 6000, "warning_ms": 2000, "moving_ms": 5000, "docking_ms": 1500},
	"timing_scale_env": "HPMMO_DEV_STAIR_SCALE",
	"docks": [
		{
			"id": "ground_south", "bottom": [0.0, 0.0, -6.0], "yaw": 0.0,
			"bottom_landing": [0.0, 0.1, -8.0], "top_landing": [0.0, 6.1, 8.0],
			"connects": ["ground", "first"],
		},
		{
			"id": "first_south", "bottom": [0.0, 6.0, -6.0], "yaw": 0.0,
			"bottom_landing": [0.0, 6.1, -8.0], "top_landing": [0.0, 12.1, 8.0],
			"connects": ["first", "second"],
		},
		{
			"id": "first_east", "bottom": [8.0, 6.0, -6.0], "yaw": 0.0,
			"bottom_landing": [8.0, 6.1, -8.0], "top_landing": [8.0, 12.1, 8.0],
			"connects": ["first", "second"],
		},
	],
}

# --------------------------------------------------------------------- spec

static func load_spec() -> Dictionary:
	var spec: Dictionary = _spec_from_catalog()
	if spec.is_empty():
		spec = DEFAULT_SPEC.duplicate(true)
	return _normalize(spec)

## The catalog owns the map/portal data; when it also carries a `staircase`
## block that is the authored spec (server-owned timing and landings).
static func _spec_from_catalog() -> Dictionary:
	if not FileAccess.file_exists(CATALOG_PATH):
		return {}
	var file := FileAccess.open(CATALOG_PATH, FileAccess.READ)
	if file == null:
		return {}
	var parsed: Variant = JSON.parse_string(file.get_as_text())
	file.close()
	if not (parsed is Dictionary):
		return {}
	var entry: Variant = (parsed as Dictionary).get("staircase", {})
	if not (entry is Dictionary):
		return {}
	var spec := entry as Dictionary
	if (spec.get("docks", []) as Array).size() < 2:
		return {}
	return spec

static func _normalize(spec: Dictionary) -> Dictionary:
	var out := spec.duplicate(true)
	out["flight"] = out.get("flight", DEFAULT_SPEC["flight"])
	out["timing"] = out.get("timing", DEFAULT_SPEC["timing"])
	var origin: Array = out.get("origin", [0.0, 0.0, 0.0])
	var flight: Dictionary = out["flight"]
	for dock in out.get("docks", []):
		dock["_bottom"] = _sub(_vec3(dock.get("bottom", []), Vector3.ZERO), _vec3(origin, Vector3.ZERO))
		dock["_bottom_landing"] = _sub(_vec3(dock.get("bottom_landing", []), Vector3.ZERO), _vec3(origin, Vector3.ZERO))
		dock["_top_landing"] = _sub(_vec3(dock.get("top_landing", []), Vector3.ZERO), _vec3(origin, Vector3.ZERO))
		dock["_flight"] = flight
	return out

## Server-owned timing. `timing_scale_env` lets a test shorten a full cycle
## without changing production data (same affordance the rest of the suite uses).
static func scale_from_env(spec: Dictionary) -> float:
	var name := String(spec.get("timing_scale_env", ""))
	if name == "":
		return 1.0
	var raw := OS.get_environment(name)
	if raw == "":
		return 1.0
	return maxf(0.05, float(raw))

static func _vec3(raw: Variant, fallback: Vector3) -> Vector3:
	if not (raw is Array) or (raw as Array).size() != 3:
		return fallback
	var a := raw as Array
	return Vector3(float(a[0]), float(a[1]), float(a[2]))

static func _sub(a: Vector3, b: Vector3) -> Vector3:
	return Vector3(a.x - b.x, a.y - b.y, a.z - b.z)

# ----------------------------------------------------------------- instance

var spec: Dictionary = {}
var timing: Dictionary = {}
var state := STATE_DOCKED
var dock_index := 0
var from_index := 0
var to_index := 0
var cycle := 0
var move_start_tick := 0
var dock_start_tick := 0
var arrive_tick := 0
var phase_start_tick := 0
var is_authority_runtime := false
var platform: AnimatableBody3D = null

var nav_link: NavigationLink3D = null

## True between `boarding_warning` and the next arrival: new entry is refused
## while the platform is unsafe ("Block new entry during unsafe
## motion"). Set in `_begin_warning`, cleared in `_arrive`.
var _locked: bool = false

var _riders: Dictionary = {}
var _net: Node = null
var _last_publish_tick := -1000
var _gates: Array = []
## Replica state: what the authority published (a client never re-derives the
## platform transform from its own copy of the spec).
var _replica_p0 := Transform3D.IDENTITY
var _replica_p1 := Transform3D.IDENTITY
var _replica_p2 := Transform3D.IDENTITY
var replica_active := false
var _pending_payloads: Array = []

func _ready() -> void:
	spec = load_spec()
	timing = _scaled_timing(spec)
	is_authority_runtime = SimAuthority.is_authority()
	build_geometry()
	if is_authority_runtime:
		add_to_group(GROUP_RESOLVER)
		phase_start_tick = SimAuthority.sim_tick
		from_index = dock_index
		to_index = dock_index
		_net = HPStaircaseNet.ensure()
		print("[Staircase] authority at %s, %d docks, timing %s" % [
			global_position, dock_count(), timing])
	else:
		_net = HPStaircaseNet.ensure()
		if _net != null:
			_net.state_received.connect(_on_state_received)
	_apply_platform(platform_transform_at(SimAuthority.sim_tick))

func _scaled_timing(the_spec: Dictionary) -> Dictionary:
	var base: Dictionary = the_spec.get("timing", {})
	var scale := scale_from_env(the_spec)
	return {
		"dwell_ms": int(float(base.get("dwell_ms", 6000)) * scale),
		"warning_ms": int(float(base.get("warning_ms", 2000)) * scale),
		"moving_ms": int(float(base.get("moving_ms", 5000)) * scale),
		"docking_ms": int(float(base.get("docking_ms", 1500)) * scale),
	}

func _ticks(ms: int) -> int:
	return maxi(1, int(round(float(ms) / 50.0)))

# ------------------------------------------------------------------- public

func dock_count() -> int:
	return (spec.get("docks", []) as Array).size()

func dock_id(index: int) -> String:
	var docks: Array = spec.get("docks", [])
	if docks.is_empty():
		return ""
	return String((docks[posmod(index, docks.size())] as Dictionary).get("id", ""))

func dock_origin(index: int) -> Vector3:
	var docks: Array = spec.get("docks", [])
	if docks.is_empty():
		return Vector3.ZERO
	return (docks[posmod(index, docks.size())] as Dictionary).get("_bottom", Vector3.ZERO)

func dock_landing(index: int, top: bool) -> Vector3:
	var docks: Array = spec.get("docks", [])
	if docks.is_empty():
		return Vector3.ZERO
	var dock: Dictionary = docks[posmod(index, docks.size())]
	return dock.get("_top_landing" if top else "_bottom_landing", Vector3.ZERO)

func rise() -> float:
	return float((spec.get("flight", {}) as Dictionary).get("rise", 6.0))

func run_length() -> float:
	return float((spec.get("flight", {}) as Dictionary).get("run", 12.0))

func half_width() -> float:
	return float((spec.get("flight", {}) as Dictionary).get("width", 3.0)) * 0.5

## The map this staircase occupies, from where it stands (the catalog's y-band
## decides). Riders are only owned while they are on that map; the dev/test hook
## places the same scene outdoors, so the spec's own `map_id` is not authority.
func map_id() -> String:
	return HPMaps.map_for_point(global_position)

func slope() -> float:
	var r := run_length()
	return 0.0 if is_zero_approx(r) else rise() / r

## Railings exist during travel; navigation links exist only while docked.
func navigation_open() -> bool:
	return state == STATE_DOCKED

func entry_allowed() -> bool:
	return state == STATE_DOCKED

func state_label() -> String:
	return state

## Is this entity one of the riders the deck is carrying?
func is_riding(uid: int) -> bool:
	return _riders.has(uid)

func rider_count() -> int:
	return _riders.size()

# ---------------------------------------------------------------- transforms

func _dock_xform(index: int) -> Transform3D:
	var docks: Array = spec.get("docks", [])
	if docks.is_empty():
		return Transform3D.IDENTITY
	var dock: Dictionary = docks[posmod(index, docks.size())]
	var yaw := deg_to_rad(float(dock.get("yaw", 0.0)))
	var bottom: Vector3 = dock.get("_bottom", Vector3.ZERO)
	return Transform3D(Basis(Vector3.UP, yaw), bottom)

func p0() -> Transform3D:
	if replica_active:
		return _replica_p0
	return _dock_xform(from_index)

func p1() -> Transform3D:
	if replica_active:
		return _replica_p1
	return p0().interpolate_with(p2(), MOVE_FRACTION)

func p2() -> Transform3D:
	if replica_active:
		return _replica_p2
	return _dock_xform(to_index)

## The one function both the authority and every replica use. It is a pure
## function of the published (state, transforms, ticks), so two clients that
## received the same message compute the same transform on the same tick.
func platform_transform_at(tick: int) -> Transform3D:
	match state:
		STATE_MOVING:
			var span := maxi(1, dock_start_tick - move_start_tick)
			var t := clampf(float(tick - move_start_tick) / float(span), 0.0, 1.0)
			return p0().interpolate_with(p1(), t)
		STATE_DOCKING:
			var span := maxi(1, arrive_tick - dock_start_tick)
			var t := clampf(float(tick - dock_start_tick) / float(span), 0.0, 1.0)
			return p1().interpolate_with(p2(), t)
		_:
			return p0()

## The world-space transform of the deck right now.
func platform_world_transform(tick: int) -> Transform3D:
	return global_transform * platform_transform_at(tick)

## Local coordinates of a world point on the deck, in "flight space": x across
## the deck, y above the deck surface, z along the run.
func to_deck_space(world_point: Vector3, tick: int) -> Vector3:
	return platform_world_transform(tick).affine_inverse() * world_point

## The deck surface height at a local z.
func deck_surface_y(local_z: float) -> float:
	return local_z * slope()

## Is this world point on the deck? `above`/`below` are expressed in deck space
## (metres above the ramp surface). A caller that compares a *predicted* body
## against a transform a snapshot or two old passes a generous `above`; a caller
## that decides whether a body standing near a raised deck belongs on it leaves
## `below` tight, so a body on the ground under the flight is not swept up.
func on_deck(world_point: Vector3, tick: int, above: float = 2.6, below: float = 0.8) -> bool:
	var local := to_deck_space(world_point, tick)
	if absf(local.x) > half_width() + 0.35:
		return false
	if local.z < 0.2 or local.z > run_length() - 0.2:
		return false
	var surface := deck_surface_y(local.z)
	return local.y >= surface - below and local.y <= surface + above

## The landing a stranded rider is put back on: the nearest authored landing of
## the nearest dock. Always a real floor, never "between floors".
func nearest_landing(world_point: Vector3) -> Vector3:
	var best := global_transform * dock_landing(dock_index, false)
	var best_distance := INF
	for index in range(dock_count()):
		for top in [false, true]:
			var candidate: Vector3 = global_transform * dock_landing(index, top)
			var distance := candidate.distance_to(world_point)
			if distance < best_distance:
				best_distance = distance
				best = candidate
	return best

# ------------------------------------------------------------- authority sim

func _physics_process(_delta: float) -> void:
	if is_authority_runtime:
		if SimAuthority.simulation_paused():
			return
		_authority_step(SimAuthority.sim_tick)
	else:
		_apply_pending_payloads()
		_apply_platform(platform_transform_at(SimAuthority.sim_tick))

func _authority_step(tick: int) -> void:
	match state:
		STATE_DOCKED:
			_collect_riders(tick)
			if tick - phase_start_tick >= _ticks(int(timing["dwell_ms"])):
				_begin_warning(tick)
		STATE_BOARDING_WARNING:
			_enforce_entry(tick)
			if tick - phase_start_tick >= _ticks(int(timing["warning_ms"])):
				_begin_moving(tick)
		STATE_MOVING:
			_enforce_entry(tick)
			if tick >= dock_start_tick:
				_begin_docking(tick)
		STATE_DOCKING:
			_enforce_entry(tick)
			if tick >= arrive_tick:
				_arrive(tick)
	_apply_platform(platform_transform_at(tick))
	# The riders travel with the deck. Without this the flight moves out from
	# under the body that boarded it: the authority never carries them, the
	# client's prediction is corrected straight back to the floor, and the
	# staircase reads as scenery that does nothing.
	if not _riders.is_empty():
		_carry_riders(tick)
	_maybe_publish(tick)

func _begin_warning(tick: int) -> void:
	_locked = true
	state = STATE_BOARDING_WARNING
	phase_start_tick = tick
	from_index = dock_index
	to_index = posmod(dock_index + 1, maxi(1, dock_count()))
	_publish_now(tick)

func _begin_moving(tick: int) -> void:
	state = STATE_MOVING
	move_start_tick = tick
	dock_start_tick = tick + _ticks(int(timing["moving_ms"]))
	arrive_tick = dock_start_tick + _ticks(int(timing["docking_ms"]))
	phase_start_tick = tick
	_publish_now(tick)

func _begin_docking(tick: int) -> void:
	state = STATE_DOCKING
	phase_start_tick = tick
	_publish_now(tick)

func _arrive(tick: int) -> void:
	state = STATE_DOCKED
	dock_index = to_index
	from_index = dock_index
	phase_start_tick = tick
	cycle += 1
	_locked = false
	_riders.clear()
	_publish_now(tick)

func _collect_riders(tick: int) -> void:
	for uid in SimAuthority.entities.keys():
		var record: Dictionary = SimAuthority.entities[uid]
		if int(record.get("kind", 0)) != HPProtocol.Kind.PLAYER:
			continue
		if bool(record.get("dead", false)):
			continue
		var node = record.get("node")
		if node == null or not is_instance_valid(node):
			continue
		if on_deck((node as Node3D).global_position, tick):
			_riders[int(uid)] = true

## Entry is refused outside `docked`: a body that was not aboard when the
## warning started is put back on a landing and told why, and a body pressing
## against the closed gate is told why too (the gate itself is solid, so this is
## presentation - but the plan asks for feedback, not just a wall).
func _enforce_entry(tick: int) -> void:
	for uid in SimAuthority.entities.keys():
		var record: Dictionary = SimAuthority.entities[uid]
		if int(record.get("kind", 0)) != HPProtocol.Kind.PLAYER:
			continue
		if bool(record.get("dead", false)) or _riders.has(int(uid)):
			continue
		var node = record.get("node")
		if node == null or not is_instance_valid(node):
			continue
		var position := (node as Node3D).global_position
		if on_deck(position, tick):
			_refuse_entry(record, node as Node3D, tick)
			continue
		if _near_boarding_edge(position, tick):
			if tick - int(_last_notice_tick.get(int(uid), -1000)) >= NOTICE_INTERVAL_TICKS:
				_last_notice_tick[int(uid)] = tick
				_notify_locked(record)

## The approach volume at the foot of the flight: close enough that the player
## is plainly trying to walk on.
func _near_boarding_edge(world_point: Vector3, tick: int) -> bool:
	var local := to_deck_space(world_point, tick)
	if absf(local.x) > half_width() + 0.6:
		return false
	if local.z < -3.0 or local.z > 1.5:
		return false
	return local.y > -1.5 and local.y < 2.5

func _notify_locked(record: Dictionary) -> void:
	var peer_id := int(record.get("peer_id", 0))
	if peer_id > 0 and not SimNet.is_client:
		SimNet.sim_notice.rpc_id(peer_id, NOTICE_LOCKED, state)

var _last_notice_tick: Dictionary = {}

func _refuse_entry(record: Dictionary, body: Node3D, tick: int) -> void:
	var landing := nearest_landing(body.global_position)
	body.global_position = landing
	body.set("velocity", Vector3.ZERO)
	record["safe_spawn"] = landing
	record["safe_spawn_map"] = String(record.get("map_id", HPProtocol.DEFAULT_MAP))
	SimAuthority.touch(record)
	var peer_id := int(record.get("peer_id", 0))
	if peer_id > 0 and not SimNet.is_client:
		SimNet.sim_notice.rpc_id(peer_id, NOTICE_LOCKED, state)
	print("[Staircase] entry refused (uid %d, state %s) -> landing (%.2f, %.2f, %.2f)" % [
		int(record.get("uid", 0)), state, landing.x, landing.y, landing.z])

## Carry. The deck is an AnimatableBody3D, so Godot already hands its velocity
## to a CharacterBody3D standing on it; this keeps the rider rigidly inside the
## railings as well (and still carries a rider if the deck has no collider at
## all, e.g. a server instance built without geometry).
func _carry_riders(tick: int) -> void:
	var xform := platform_world_transform(tick)
	var inverse := xform.affine_inverse()
	for uid in _riders.keys():
		var record: Dictionary = SimAuthority.entities.get(uid, {})
		if record.is_empty() or bool(record.get("dead", false)):
			continue
		if String(record.get("map_id", HPProtocol.DEFAULT_MAP)) != map_id():
			# The body left on a transfer: stop owning it. Otherwise the deck
			# keeps dragging a body that is on another map back into this one.
			_riders.erase(int(uid))
			continue
		var node = record.get("node")
		if node == null or not is_instance_valid(node):
			continue
		var body := node as Node3D
		if body == null:
			continue
		var local := inverse * body.global_position
		local.x = clampf(local.x, -half_width() + 0.35, half_width() - 0.35)
		local.z = clampf(local.z, 0.3, run_length() - 0.3)
		var surface := deck_surface_y(local.z)
		if local.y < surface + 0.05:
			local.y = surface + 0.05
		local.y = minf(local.y, surface + 2.4)
		body.global_position = xform * local
		var velocity = body.get("velocity")
		if velocity is Vector3 and (velocity as Vector3).y < 0.0:
			body.set("velocity", Vector3((velocity as Vector3).x, 0.0, (velocity as Vector3).z))

## Failure cases: death, disconnect, logout or a map transfer while a rider is
## between floors. The body is returned to the nearest authored landing, and the
## authority's own rescue paths (`_settle_to_safe_spawn`) are pointed at the same
## spot so every route agrees.
func resolve_departing_player(record: Dictionary, reason: String) -> Vector3:
	var node = record.get("node")
	if node == null or not is_instance_valid(node) or not _riders.has(int(record.get("uid", 0))):
		return Vector3.ZERO
	if String(record.get("map_id", HPProtocol.DEFAULT_MAP)) != map_id():
		# A rider that already left on a transfer owns no landing here: moving
		# it back into this map would corrupt the save the disconnect makes
		# (measured: a journey that exited the castle was saved on the
		# interior's landing while its record said grounds).
		_riders.erase(int(record.get("uid", 0)))
		return Vector3.ZERO
	var tick := SimAuthority.sim_tick
	if state == STATE_DOCKED and node is Node3D and on_deck((node as Node3D).global_position, tick):
		return Vector3.ZERO
	var landing := nearest_landing((node as Node3D).global_position)
	(node as Node3D).global_position = landing
	node.set("velocity", Vector3.ZERO)
	record["safe_spawn"] = landing
	record["safe_spawn_map"] = String(record.get("map_id", HPProtocol.DEFAULT_MAP))
	_riders.erase(int(record.get("uid", 0)))
	SimAuthority.touch(record)
	print("[Staircase] rider uid %d resolved to landing (%.2f, %.2f, %.2f) (%s, state %s)" % [
		int(record.get("uid", 0)), landing.x, landing.y, landing.z, reason, state])
	return landing

# -------------------------------------------------------------- replication

func payload() -> Dictionary:
	return {
		"state": state,
		"phase_start_tick": phase_start_tick,
		"dock_index": dock_index,
		"from_index": from_index,
		"to_index": to_index,
		"cycle": cycle,
		"move_start_tick": move_start_tick,
		"dock_start_tick": dock_start_tick,
		"arrive_tick": arrive_tick,
		"p0": p0(),
		"p1": p1(),
		"p2": p2(),
		"origin": global_position,
		"map_id": String(spec.get("map_id", HPProtocol.DEFAULT_MAP)),
		"rise": rise(),
	}

func _publish_now(tick: int) -> void:
	_last_publish_tick = tick
	_publish()

func _maybe_publish(tick: int) -> void:
	# Heartbeat: a client that joined after the last transition still converges.
	if tick - _last_publish_tick >= PUBLISH_EVERY_TICKS:
		_publish_now(tick)

func _publish() -> void:
	if _net == null or SimNet.is_client or not SimNet.has_peers():
		return
	_net.publish(payload())

## A state change is applied on the tick the authority stamped it with, never on
## the tick the datagram happens to arrive. Two clients whose packets arrive at
## different moments therefore still change state on the same tick, which is what
## makes "same state, same position, same tick" true rather than approximately
## true.
func _on_state_received(received_id: int, incoming: Dictionary) -> void:
	if received_id != OBJECT_ID:
		return
	_pending_payloads.append(incoming)
	if _pending_payloads.size() > 16:
		_pending_payloads.pop_front()
	_apply_pending_payloads()

## Applies every payload whose tick has arrived, oldest first: a client whose
## clock is behind must not skip a phase just because a newer message overtook
## the older one while it was waiting.
func _apply_pending_payloads() -> void:
	while not _pending_payloads.is_empty():
		var next: Dictionary = _pending_payloads[0]
		if SimAuthority.sim_tick < int(next.get("phase_start_tick", 0)):
			return
		_pending_payloads.pop_front()
		_apply_payload(next)

func _apply_payload(incoming: Dictionary) -> void:
	state = String(incoming.get("state", STATE_DOCKED))
	dock_index = int(incoming.get("dock_index", 0))
	from_index = int(incoming.get("from_index", dock_index))
	to_index = int(incoming.get("to_index", dock_index))
	cycle = int(incoming.get("cycle", 0))
	phase_start_tick = int(incoming.get("phase_start_tick", 0))
	move_start_tick = int(incoming.get("move_start_tick", 0))
	dock_start_tick = int(incoming.get("dock_start_tick", 0))
	arrive_tick = int(incoming.get("arrive_tick", 0))
	if incoming.get("p0") is Transform3D:
		_replica_p0 = incoming["p0"]
	if incoming.get("p1") is Transform3D:
		_replica_p1 = incoming["p1"]
	if incoming.get("p2") is Transform3D:
		_replica_p2 = incoming["p2"]
	replica_active = true

func _apply_platform(xform: Transform3D) -> void:
	if platform == null or not is_instance_valid(platform):
		return
	platform.transform = xform
	_update_gates()

## Gates follow the replicated state on every process, so a client and the
## server always agree about whether the deck is open for boarding.
func _update_gates() -> void:
	var blocked := not entry_allowed()
	for gate in _gates:
		if is_instance_valid(gate):
			gate.set_deferred("disabled", not blocked)
	if nav_link != null and is_instance_valid(nav_link):
		nav_link.enabled = navigation_open()

# ----------------------------------------------------------------- geometry
# Greybox only: untextured standard materials, no art pass.

const MAT_DECK := Color(0.42, 0.4, 0.38)
const MAT_STEP := Color(0.5, 0.48, 0.45)
const MAT_RAIL := Color(0.3, 0.28, 0.26)
const MAT_LANDING := Color(0.36, 0.34, 0.33)
const MAT_GATE := Color(0.55, 0.35, 0.2)

func _material(color: Color) -> StandardMaterial3D:
	var material := StandardMaterial3D.new()
	material.albedo_color = color
	material.roughness = 0.85
	return material

func _box(parent: Node3D, size: Vector3, position: Vector3, color: Color, rotation_x: float = 0.0, name_hint: String = "Box") -> MeshInstance3D:
	var mesh_instance := MeshInstance3D.new()
	mesh_instance.name = name_hint
	var mesh := BoxMesh.new()
	mesh.size = size
	mesh.material = _material(color)
	mesh_instance.mesh = mesh
	mesh_instance.position = position
	mesh_instance.rotation.x = rotation_x
	parent.add_child(mesh_instance)
	return mesh_instance

func _collider(parent: Node3D, size: Vector3, position: Vector3, rotation_x: float = 0.0, name_hint: String = "Shape") -> CollisionShape3D:
	var collider := CollisionShape3D.new()
	collider.name = name_hint
	var shape := BoxShape3D.new()
	shape.size = size
	collider.shape = shape
	collider.position = position
	collider.rotation.x = rotation_x
	parent.add_child(collider)
	return collider

func build_geometry() -> void:
	if get_node_or_null("Platform") != null:
		return
	var flight: Dictionary = spec.get("flight", {})
	var rise_v := float(flight.get("rise", 6.0))
	var run_v := float(flight.get("run", 12.0))
	var width := float(flight.get("width", 3.0))
	var step_height := float(flight.get("step_height", 0.2))
	var angle := atan2(rise_v, run_v)
	var ramp_length := sqrt(rise_v * rise_v + run_v * run_v)
	var mid := Vector3(0.0, rise_v * 0.5, run_v * 0.5)
	var up := Vector3(0.0, cos(angle), -sin(angle))

	# --- the moving deck
	platform = AnimatableBody3D.new()
	platform.name = "Platform"
	platform.sync_to_physics = true
	platform.collision_layer = 1
	platform.collision_mask = 0
	add_child(platform)
	# One ramp collider under a stepped visual: a CharacterBody3D walks a 26.6 deg
	# ramp cleanly, and the steps stay a greybox visual ("stairs/ramps").
	_collider(platform, Vector3(width, 0.3, ramp_length), mid - up * 0.15, -angle, "DeckShape")
	_box(platform, Vector3(width, 0.3, ramp_length), mid - up * 0.15, MAT_DECK, -angle, "DeckMesh")
	var steps := maxi(1, int(round(rise_v / maxf(step_height, 0.05))))
	var step_run := run_v / float(steps)
	for index in range(steps):
		_box(platform, Vector3(width - 0.1, step_height, step_run),
			Vector3(0.0, (float(index) + 0.5) * step_height, (float(index) + 0.5) * step_run),
			MAT_STEP, 0.0, "Step%d" % index)
	# --- side railings: always present, they are what keeps a rider on the deck
	for side in [-1.0, 1.0]:
		var rail_pos := mid + up * 0.55 + Vector3(side * (width * 0.5 + 0.12), 0.0, 0.0)
		_box(platform, Vector3(0.16, 1.1, ramp_length), rail_pos, MAT_RAIL, -angle, "Rail%d" % int(side))
		_collider(platform, Vector3(0.16, 1.1, ramp_length), rail_pos, -angle, "RailShape%d" % int(side))
	# --- end gates: solid unless the staircase is docked (new entry blocked)
	for end in [0, 1]:
		var z := -0.15 if end == 0 else run_v + 0.15
		var y := 0.8 if end == 0 else rise_v + 0.8
		_box(platform, Vector3(width, 1.6, 0.2), Vector3(0.0, y, z), MAT_GATE, 0.0, "Gate%d" % end)
		var gate := _collider(platform, Vector3(width, 1.6, 0.2), Vector3(0.0, y, z), 0.0, "GateShape%d" % end)
		gate.disabled = true
		_gates.append(gate)

	_build_landings(rise_v, run_v)
	_build_fallback(rise_v, run_v, width, step_height)
	_build_navigation(rise_v, run_v)

## Floor plates at every level the staircase serves, so a landing is a real
## floor and not a gap (a rider stepping off lands on something, and the fallback
## route is walkable at every level). One walkable ring per level, with the
## flights' shaft left open:
##   apron    z in [-15, -6]   (in front of a flight's foot)
##   arrival  z in [ 6, 15]    (past a flight's top edge)
##   east ring x in [15, 22] around z in (-6, 6), the open shaft
## The ring is deliberately clear of every flight corridor (the moving deck and
## both conventional flights), so nothing is built through a stair.
func _build_landings(rise_v: float, _run_v: float) -> void:
	var levels := {}
	for dock in spec.get("docks", []):
		var bottom: Vector3 = dock.get("_bottom", Vector3.ZERO)
		levels[bottom.y] = true
		levels[bottom.y + rise_v] = true
	for level in levels.keys():
		var y := float(level)
		var body := StaticBody3D.new()
		body.name = "Landing%03d" % int(round(y * 10.0))
		body.collision_layer = 1
		body.collision_mask = 0
		add_child(body)
		_plate(body, Vector3(-2.0, y - 0.2, -10.5), Vector3(36.0, 0.4, 9.0))
		_plate(body, Vector3(-2.0, y - 0.2, 10.5), Vector3(36.0, 0.4, 9.0))
		_plate(body, Vector3(18.5, y - 0.2, 10.5), Vector3(7.0, 0.4, 9.0))
		_plate(body, Vector3(18.5, y - 0.2, -10.5), Vector3(7.0, 0.4, 9.0))
		_plate(body, Vector3(20.0, y - 0.2, 0.0), Vector3(4.0, 0.4, 30.0))

func _plate(parent: Node3D, center: Vector3, size: Vector3) -> void:
	_box(parent, size, center, MAT_LANDING, 0.0, "PlateMesh")
	_collider(parent, size, center, 0.0, "PlateShape")

## The conventional fallback route: two straight flights that always connect the
## same levels while the magical staircase is somewhere else.
func _build_fallback(rise_v: float, run_v: float, width: float, step_height: float) -> void:
	var fallback := Node3D.new()
	fallback.name = "FallbackStairs"
	add_child(fallback)
	_build_static_flight(fallback, Transform3D(Basis(Vector3.UP, 0.0), Vector3(-8.0, 0.0, -6.0)), rise_v, run_v, width, step_height, "FallbackGroundToFirst")
	_build_static_flight(fallback, Transform3D(Basis(Vector3.UP, 0.0), Vector3(16.0, 6.0, -6.0)), rise_v, run_v, width, step_height, "FallbackFirstToSecond")

func _build_static_flight(parent: Node3D, xform: Transform3D, rise_v: float, run_v: float, width: float, step_height: float, flight_name: String) -> void:
	var flight := Node3D.new()
	flight.name = flight_name
	parent.add_child(flight)
	flight.transform = xform
	var angle := atan2(rise_v, run_v)
	var ramp_length := sqrt(rise_v * rise_v + run_v * run_v)
	var mid := Vector3(0.0, rise_v * 0.5, run_v * 0.5)
	var up := Vector3(0.0, cos(angle), -sin(angle))
	var body := StaticBody3D.new()
	body.name = "Body"
	body.collision_layer = 1
	body.collision_mask = 0
	flight.add_child(body)
	_collider(body, Vector3(width, 0.3, ramp_length), mid - up * 0.15, -angle, "RampShape")
	_box(body, Vector3(width, 0.3, ramp_length), mid - up * 0.15, MAT_DECK, -angle, "RampMesh")
	var steps := maxi(1, int(round(rise_v / maxf(step_height, 0.05))))
	var step_run := run_v / float(steps)
	for index in range(steps):
		_box(body, Vector3(width - 0.1, step_height, step_run),
			Vector3(0.0, (float(index) + 0.5) * step_height, (float(index) + 0.5) * step_run),
			MAT_STEP, 0.0, "Step%d" % index)
	for side in [-1.0, 1.0]:
		var rail_pos := mid + up * 0.55 + Vector3(side * (width * 0.5 + 0.12), 0.0, 0.0)
		_box(body, Vector3(0.16, 1.1, ramp_length), rail_pos, MAT_RAIL, -angle, "Rail%d" % int(side))
		_collider(body, Vector3(0.16, 1.1, ramp_length), rail_pos, -angle, "RailShape%d" % int(side))

## Navigation links exist only while docked, so an NPC never paths across a
## connection that is not there.
func _build_navigation(rise_v: float, run_v: float) -> void:
	var region := NavigationRegion3D.new()
	region.name = "StairNavigation"
	add_child(region)
	nav_link = NavigationLink3D.new()
	nav_link.name = "DeckLink"
	nav_link.start_position = Vector3(0.0, 0.2, -5.5)
	nav_link.end_position = Vector3(0.0, rise_v + 0.2, run_v - 0.5)
	nav_link.enabled = navigation_open()
	region.add_child(nav_link)
