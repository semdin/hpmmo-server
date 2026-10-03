extends Node

## HPMMO maintenance controller and authenticated admin surface (plan.md Phase 6).
##
## OWNER: server repository. The client receives this file as part of the synced
## simulation package but never instantiates it: only the dedicated world server
## (server/world_server.gd) adds it to the tree.
##
## Godot has no built-in HTTP server, so this is a deliberately small HTTP/1.1
## server over TCPServer. It is bound to 127.0.0.1 only, answers one request per
## connection (no keep-alive), caps the request size, times out slow clients,
## and refuses to start at all when HPMMO_SERVICE_TOKEN is empty: an
## unauthenticated maintenance surface must not exist.
##
## State machine (the names are part of the contract - the deployment controller
## and the launcher poll them through GET /admin/status):
##
##   ONLINE -> ANNOUNCING -> DRAINING -> SAVING -> DISCONNECTING -> MAINTENANCE
##                 |            |
##                 +-- ABORTED -+ -> ONLINE        (only before SAVING starts)
##                              SAVING -> FAILED   (save barrier not confirmed)
##
## Every timer here runs on wall time in _process, never on the simulation
## clock: SAVING has to finish even while the simulation is frozen, and
## /admin/status has to answer in milliseconds while MAINTENANCE is not ticking.

const HPProtocol = preload("res://addons/hpmmo_sim/protocol.gd")

signal state_changed(state: String, reason: String)

enum State { ONLINE, ANNOUNCING, DRAINING, SAVING, DISCONNECTING, MAINTENANCE, ABORTED, FAILED }

const STATE_NAMES: Array = [
	"ONLINE", "ANNOUNCING", "DRAINING", "SAVING",
	"DISCONNECTING", "MAINTENANCE", "ABORTED", "FAILED",
]

const DEFAULT_ADMIN_PORT := 8082
const DEFAULT_COUNTDOWN_SECONDS := 300.0
const DEFAULT_DRAIN_SECONDS := 10.0
const DEFAULT_SAVE_MIN_MS := 1000
const DEFAULT_ANNOUNCE_MS := 10000
const URGENT_ANNOUNCE_MS := 3000
const URGENT_REMAINING_SEC := 15
## Bounded save-acknowledgement wait (plan Phase 6: "await persistence
## acknowledgments with bounded timeouts").
const SAVE_ACK_TIMEOUT_MS := 15000
## The bridge must be idle for this long before the flush counts as acknowledged.
const SAVE_SETTLE_MS := 250
## Reliable notices need a moment on the wire before the peers are closed.
const DISCONNECT_NOTICE_GRACE_MS := 500
const MAX_CONNECTIONS := 8
const MAX_HEADER_BYTES := 8192
const MAX_BODY_BYTES := 65536
const MAX_REQUEST_BYTES := MAX_HEADER_BYTES + MAX_BODY_BYTES
const REQUEST_TIMEOUT_MS := 5000
const RESPONSE_FLUSH_MS := 60
const DEFERRED_TIMEOUT_MS := 20000
const HISTORY_LIMIT := 24
const REASON_MAX := 200

# ------------------------------------------------------------------ configuration

var token := ""
var admin_port := DEFAULT_ADMIN_PORT
var drain_seconds := DEFAULT_DRAIN_SECONDS
var save_min_ms := DEFAULT_SAVE_MIN_MS
var announce_interval_ms := DEFAULT_ANNOUNCE_MS
var release := ""
var listening := false

# ------------------------------------------------------------------------ state

var state: int = State.ONLINE
var reason := ""
## Unix epoch milliseconds the countdown ends at; 0 when nothing is counting down.
var deadline_ms := 0

var _boot_ms := 0
var _history: Array = []
var _phase_deadline_ms := 0
var _last_announce_ms := 0
var _save_entered_ms := 0
var _disconnect_at_ms := 0

# ------------------------------------------------------------------- http server

var _server: TCPServer = null
var _connections: Array = []
var _deferred: Array = []

# ------------------------------------------------------------------------ flush

var _flush_active := false
var _flush_settled := true
var _flush_result: Dictionary = {}
var _flush_requested := 0
var _flush_skipped := 0
var _flush_deadline_ms := 0
var _flush_idle_since := 0
var _flush_bridge: Node = null

# ------------------------------------------------------------------- stand-alone

var _kick_active := false
var _kick_done := false
var _kick_at_ms := 0
var _kick_count := 0


func _ready() -> void:
	# The admin surface must keep answering while MAINTENANCE has the world
	# paused, so it ignores the tree pause.
	process_mode = Node.PROCESS_MODE_ALWAYS
	_boot_ms = _ticks()
	token = OS.get_environment("HPMMO_SERVICE_TOKEN").strip_edges()
	release = OS.get_environment("HPMMO_RELEASE").strip_edges()
	admin_port = int(_env("HPMMO_ADMIN_PORT", str(DEFAULT_ADMIN_PORT)))
	drain_seconds = maxf(0.0, float(_env("HPMMO_MAINTENANCE_DRAIN_SECONDS", str(DEFAULT_DRAIN_SECONDS))))
	save_min_ms = maxi(0, int(_env("HPMMO_MAINTENANCE_SAVE_MIN_MS", str(DEFAULT_SAVE_MIN_MS))))
	announce_interval_ms = maxi(250, int(_env("HPMMO_MAINTENANCE_ANNOUNCE_MS", str(DEFAULT_ANNOUNCE_MS))))
	if token == "":
		# Loud and final: a maintenance API without a token would let anything on
		# the host drain the world. The world itself keeps running.
		print("[AdminApi] REFUSING TO START: HPMMO_SERVICE_TOKEN is empty - admin API stays closed")
		set_process(false)
		return
	_server = TCPServer.new()
	var error := _server.listen(admin_port, "127.0.0.1")
	if error != OK:
		_server = null
		printerr("[AdminApi] ERROR: cannot bind 127.0.0.1:%d (error %d) - maintenance API unavailable" % [admin_port, error])
		return
	listening = true
	print("[AdminApi] maintenance API on 127.0.0.1:%d (service token required, drain=%.0fs)" % [
		admin_port, drain_seconds])


func _env(name: String, fallback: String) -> String:
	var value := OS.get_environment(name)
	return value if value != "" else fallback

func _ticks() -> int:
	return Time.get_ticks_msec()

func _wall_ms() -> int:
	return int(Time.get_unix_time_from_system() * 1000.0)

func state_name() -> String:
	return String(STATE_NAMES[state])

func state_name_of(value: int) -> String:
	return String(STATE_NAMES[clampi(value, 0, STATE_NAMES.size() - 1)])

## Queried by SimAuthority (see the maintenance gate there).
func accepts_joins() -> bool:
	return state == State.ONLINE

## True from SAVING on: the authority refuses every mutation.
func is_frozen() -> bool:
	return state == State.SAVING or state == State.DISCONNECTING \
		or state == State.MAINTENANCE or state == State.FAILED

## True in MAINTENANCE: the simulation does no work at all.
func is_paused() -> bool:
	return state == State.MAINTENANCE


# ------------------------------------------------------------------- http intake

func _process(_delta: float) -> void:
	_tick_flush()
	_tick_kick()
	_serve()
	match state:
		State.ANNOUNCING:
			_tick_announcing()
		State.DRAINING:
			if _ticks() >= _phase_deadline_ms:
				_enter_saving()
		State.SAVING:
			_tick_saving()
		State.DISCONNECTING:
			_tick_disconnecting()
	_roll_deferred()


func _serve() -> void:
	if _server == null:
		return
	while _connections.size() < MAX_CONNECTIONS and _server.is_connection_available():
		var peer := _server.take_connection()
		if peer == null:
			break
		_connections.append({
			"peer": peer,
			"buffer": PackedByteArray(),
			"started_ms": _ticks(),
			"responded_ms": 0,
			"deferred": false,
		})
	if _connections.is_empty():
		return
	var now := _ticks()
	var keep: Array = []
	for conn in _connections:
		var peer: StreamPeerTCP = conn["peer"]
		peer.poll()
		var status := peer.get_status()
		if status != StreamPeerTCP.STATUS_CONNECTED and status != StreamPeerTCP.STATUS_CONNECTING:
			_close(peer)
			continue
		if int(conn["responded_ms"]) > 0:
			# The response is written; keep polling briefly so the OS flushes it,
			# then close. One request per connection: no keep-alive.
			if now - int(conn["responded_ms"]) >= RESPONSE_FLUSH_MS:
				_close(peer)
			else:
				keep.append(conn)
			continue
		if bool(conn["deferred"]):
			# Being answered by _roll_deferred (a save barrier or a kick).
			if now - int(conn["started_ms"]) > DEFERRED_TIMEOUT_MS:
				_respond(conn, 503, {"ok": false, "error": "timeout"})
				keep.append(conn)
			else:
				keep.append(conn)
			continue
		if now - int(conn["started_ms"]) > REQUEST_TIMEOUT_MS:
			_respond(conn, 408, {"ok": false, "error": "request_timeout"})
			keep.append(conn)
			continue
		var buffer: PackedByteArray = conn["buffer"]
		var available := peer.get_available_bytes()
		if available > 0:
			if buffer.size() + available > MAX_REQUEST_BYTES:
				_respond(conn, 413, {"ok": false, "error": "request_too_large"})
				keep.append(conn)
				continue
			var chunk: Array = peer.get_partial_data(available)
			if int(chunk[0]) != OK:
				_close(peer)
				continue
			buffer.append_array(chunk[1] as PackedByteArray)
			conn["buffer"] = buffer
		var request := _parse_request(buffer)
		if bool(request.get("incomplete", false)):
			keep.append(conn)
			continue
		if not bool(request.get("ok", false)):
			_respond(conn, int(request.get("status", 400)), {
				"ok": false, "error": String(request.get("error", "bad_request"))})
			keep.append(conn)
			continue
		var response := _handle(request)
		if response.has("defer"):
			conn["deferred"] = true
			_deferred.append({"conn": conn, "kind": String(response["defer"])})
			keep.append(conn)
			continue
		_respond(conn, int(response.get("status", 500)), response.get("body", {}))
		keep.append(conn)
	_connections = keep


func _close(peer: StreamPeerTCP) -> void:
	if peer == null:
		return
	if peer.get_status() == StreamPeerTCP.STATUS_CONNECTED:
		peer.disconnect_from_host()


func _respond(conn: Dictionary, status: int, body: Dictionary) -> void:
	if int(conn.get("responded_ms", 0)) > 0:
		return   # one response per connection, even if two paths race to answer
	var peer: StreamPeerTCP = conn["peer"]
	if peer == null or peer.get_status() != StreamPeerTCP.STATUS_CONNECTED:
		return
	var payload := JSON.stringify(body)
	var text := "HTTP/1.1 %d %s\r\nContent-Type: application/json\r\nContent-Length: %d\r\nCache-Control: no-store\r\nConnection: close\r\n\r\n%s" % [
		status, _status_text(status), payload.to_utf8_buffer().size(), payload]
	peer.put_data(text.to_utf8_buffer())
	conn["responded_ms"] = _ticks()


func _status_text(status: int) -> String:
	match status:
		200: return "OK"
		400: return "Bad Request"
		403: return "Forbidden"
		404: return "Not Found"
		408: return "Request Timeout"
		409: return "Conflict"
		413: return "Payload Too Large"
		431: return "Request Header Fields Too Large"
		503: return "Service Unavailable"
	return "Error"


## Returns {"incomplete": true} until the request is fully readable, then either
## {"ok": false, status, error} or {"ok": true, method, path, headers, body}.
func _parse_request(buffer: PackedByteArray) -> Dictionary:
	var header_end := _find_header_end(buffer)
	if header_end < 0:
		if buffer.size() > MAX_HEADER_BYTES:
			return {"ok": false, "status": 431, "error": "header_too_large"}
		return {"incomplete": true}
	var header_text := buffer.slice(0, header_end).get_string_from_utf8()
	var lines := header_text.split("\r\n")
	if lines.is_empty():
		return {"ok": false, "status": 400, "error": "malformed"}
	var parts := lines[0].split(" ")
	if parts.size() < 2:
		return {"ok": false, "status": 400, "error": "malformed_request_line"}
	var method := parts[0].to_upper()
	var path := parts[1]
	var headers := {}
	for index in range(1, lines.size()):
		var line: String = lines[index]
		if line.is_empty():
			continue
		var colon := line.find(":")
		if colon <= 0:
			continue
		headers[line.substr(0, colon).strip_edges().to_lower()] = line.substr(colon + 1).strip_edges()
	var length := int(String(headers.get("content-length", "0")))
	if length < 0 or length > MAX_BODY_BYTES:
		return {"ok": false, "status": 413, "error": "body_too_large"}
	var body_start := header_end + 4
	if buffer.size() < body_start + length:
		return {"incomplete": true}
	var body := {}
	if length > 0:
		var text := buffer.slice(body_start, body_start + length).get_string_from_utf8()
		var parsed: Variant = JSON.parse_string(text)
		if parsed is Dictionary:
			body = parsed
		elif parsed != null:
			return {"ok": false, "status": 400, "error": "body_must_be_object"}
	return {"ok": true, "method": method, "path": path, "headers": headers, "body": body}


func _find_header_end(buffer: PackedByteArray) -> int:
	var limit := mini(buffer.size(), MAX_HEADER_BYTES)
	for index in range(0, maxi(0, limit - 3)):
		if buffer[index] == 13 and buffer[index + 1] == 10 and buffer[index + 2] == 13 and buffer[index + 3] == 10:
			return index
	return -1


## Nothing is answered before the token is checked - not even which routes exist.
func _authorized(headers: Dictionary) -> bool:
	var supplied := String(headers.get("x-service-token", ""))
	return supplied != "" and _constant_time_equals(supplied, token)


func _constant_time_equals(a: String, b: String) -> bool:
	var left := a.to_utf8_buffer()
	var right := b.to_utf8_buffer()
	var diff := left.size() ^ right.size()
	var length := maxi(left.size(), right.size())
	for index in range(length):
		var x := int(left[index]) if index < left.size() else 0
		var y := int(right[index]) if index < right.size() else 0
		diff |= x ^ y
	return diff == 0


func _normalize_path(raw: String) -> String:
	var path := raw.split("?")[0]
	if path.length() > 1 and path.ends_with("/"):
		path = path.substr(0, path.length() - 1)
	return path


func _handle(request: Dictionary) -> Dictionary:
	var method := String(request["method"])
	var path := _normalize_path(String(request["path"]))
	if not _authorized(request["headers"]):
		return {"status": 403, "body": {"ok": false, "error": "forbidden"}}
	var body: Dictionary = request["body"]
	var route := method + " " + path
	if route == "POST /admin/maintenance/begin":
		return _handle_begin(body)
	if route == "POST /admin/maintenance/abort":
		return _handle_abort()
	# `/admin/save` is the contract; `/admin/admin/save` was a typo in the spec
	# that shipped once, so both are accepted (the deployment controller calls
	# the contract path first and only falls back to the typo).
	if route == "POST /admin/save" or route == "POST /admin/admin/save":
		return _handle_save()
	if route == "POST /admin/disconnect-all":
		return _handle_disconnect_all()
	if route == "GET /admin/state" or route == "GET /admin/status":
		return {"status": 200, "body": _status_payload()}
	return {"status": 404, "body": {"ok": false, "error": "not_found"}}


# --------------------------------------------------------------------- endpoints

func _handle_begin(body: Dictionary) -> Dictionary:
	if state != State.ONLINE:
		return {"status": 409, "body": {
			"ok": false,
			"error": "already_in_maintenance",
			"state": state_name(),
			"message": "a maintenance cycle is already running (state %s)" % state_name(),
		}}
	var text := String(body.get("reason", "")).strip_edges().substr(0, REASON_MAX)
	if text == "":
		text = "scheduled maintenance"
	var countdown := clampf(float(body.get("countdown_seconds", DEFAULT_COUNTDOWN_SECONDS)), 0.0, 86400.0)
	return _begin(text, countdown)


func _begin(reason_text: String, countdown_seconds: float) -> Dictionary:
	reason = reason_text
	deadline_ms = _wall_ms() + int(countdown_seconds * 1000.0)
	_announce_interval_reset()
	_set_state(State.ANNOUNCING)
	_announce()
	print("[AdminApi] maintenance begins: '%s' countdown=%ds players=%d" % [
		_redact(reason), int(countdown_seconds), SimAuthority.players_by_peer.size()])
	return {"status": 200, "body": {
		"ok": true,
		"state": state_name(),
		"reason": reason,
		"deadline_ms": deadline_ms,
		"players": SimAuthority.players_by_peer.size(),
		"countdown_seconds": countdown_seconds,
	}}


func _handle_abort() -> Dictionary:
	if state == State.ANNOUNCING or state == State.DRAINING:
		var previous := state_name()
		# ABORTED is the transition out of the cycle: the world lands back in
		# ONLINE in the same frame, and the players are told the countdown is off.
		_set_state(State.ABORTED)
		deadline_ms = 0
		reason = ""
		_set_state(State.ONLINE)
		_broadcast(State.ONLINE, 0)
		print("[AdminApi] maintenance aborted from %s; world is ONLINE" % previous)
		return {"status": 200, "body": {
			"ok": true,
			"state": state_name(),
			"previous_state": previous,
			"players": SimAuthority.players_by_peer.size(),
		}}
	if state == State.ONLINE:
		return {"status": 409, "body": {
			"ok": false, "error": "not_in_maintenance", "state": state_name(),
			"message": "no maintenance cycle is running",
		}}
	# SAVING and everything after it is past the point of no return: a save
	# followed by more gameplay is not a final save.
	return {"status": 409, "body": {
		"ok": false,
		"error": "too_late",
		"state": state_name(),
		"message": "maintenance has passed the save barrier (state %s); abort is refused" % state_name(),
	}}


func _handle_save() -> Dictionary:
	if _flush_active:
		# A barrier is already running (SAVING, or a previous request): wait for
		# its result instead of saving the same characters twice.
		return {"defer": "save"}
	_start_flush()
	if _flush_settled:
		return {"status": 200, "body": _flush_result}
	return {"defer": "save"}


func _handle_disconnect_all() -> Dictionary:
	if _kick_active or state == State.DISCONNECTING:
		return {"status": 409, "body": {
			"ok": false, "error": "already_disconnecting", "state": state_name(),
		}}
	# The DISCONNECTING step on its own: notify, close the peers, verify zero
	# sessions. The response is parked until the step has actually completed.
	_notify_disconnecting()
	_kick_active = true
	_kick_done = false
	_kick_at_ms = _ticks() + DISCONNECT_NOTICE_GRACE_MS
	return {"defer": "disconnect"}


func _status_payload() -> Dictionary:
	var payload := {
		"ok": true,
		"state": state_name(),
		"reason": reason,
		"deadline_ms": deadline_ms,
		"players": SimAuthority.players_by_peer.size(),
		"tick": SimAuthority.sim_tick,
		"uptime_ms": _ticks() - _boot_ms,
		"protocol": HPProtocol.PROTOCOL_VERSION,
		"frozen": is_frozen(),
		"simulation_paused": is_paused(),
		"history": _history.duplicate(),
	}
	if release != "":
		payload["release"] = release
	return payload


# ------------------------------------------------------------------ state machine

func _set_state(new_state: int) -> void:
	state = new_state
	_history.append({"state": state_name(), "at_ms": _wall_ms()})
	while _history.size() > HISTORY_LIMIT:
		_history.pop_front()
	state_changed.emit(state_name(), reason)
	print("[AdminApi] STATE %s (players=%d tick=%d)" % [
		state_name(), SimAuthority.players_by_peer.size(), SimAuthority.sim_tick])


func _announce_interval_reset() -> void:
	_last_announce_ms = 0


func _remaining_seconds() -> int:
	if deadline_ms <= 0:
		return 0
	return maxi(0, int(ceil(float(deadline_ms - _wall_ms()) / 1000.0)))


func _tick_announcing() -> void:
	var remaining := _remaining_seconds()
	if remaining <= 0:
		_enter_draining()
		return
	var interval := announce_interval_ms
	if remaining <= URGENT_REMAINING_SEC:
		interval = mini(URGENT_ANNOUNCE_MS, announce_interval_ms)
	var now := _ticks()
	if now - _last_announce_ms >= interval:
		_announce()


func _announce() -> void:
	_last_announce_ms = _ticks()
	_broadcast(State.ANNOUNCING, _remaining_seconds())


func _broadcast(state_value: int, seconds_remaining: int) -> void:
	# SimNet bridges this signal onto the reliable event channel (see
	# bridge_authority); the client turns it into SimAuthority.maintenance_event.
	SimAuthority.emit_signal("maintenance_event", state_name_of(state_value), reason, seconds_remaining)


func _enter_draining() -> void:
	_set_state(State.DRAINING)
	_phase_deadline_ms = _ticks() + int(drain_seconds * 1000.0)
	_broadcast(State.DRAINING, 0)
	print("[AdminApi] draining: new joins refused, existing players keep playing (%.0fs)" % drain_seconds)


func _enter_saving() -> void:
	_set_state(State.SAVING)
	_save_entered_ms = _ticks()
	# Freeze is real: bodies stop moving on their last intent, and from here on
	# SimAuthority refuses input, casts, mounts and pickups outright.
	SimAuthority.halt_player_motion()
	_start_flush()


func _tick_saving() -> void:
	if not _flush_settled:
		return
	# The barrier dwells long enough to be observable: a deployment controller
	# (and a client) has to be able to see SAVING, not just the states around it.
	if _ticks() - _save_entered_ms < save_min_ms:
		return
	if int(_flush_result.get("failed", 0)) > 0:
		_enter_failed("the save barrier did not confirm %d character save(s) inside %d ms" % [
			int(_flush_result.get("failed", 0)), SAVE_ACK_TIMEOUT_MS])
		return
	_enter_disconnecting()


func _enter_disconnecting() -> void:
	_set_state(State.DISCONNECTING)
	_broadcast(State.DISCONNECTING, 0)
	_disconnect_at_ms = _ticks() + DISCONNECT_NOTICE_GRACE_MS


func _tick_disconnecting() -> void:
	if _ticks() < _disconnect_at_ms:
		return
	var removed := _kick_everyone()
	if not SimAuthority.players_by_peer.is_empty():
		_enter_failed("%d player session(s) survived the disconnect barrier" % SimAuthority.players_by_peer.size())
		return
	print("[AdminApi] disconnect barrier: %d session(s) removed, server reports zero players" % removed)
	_enter_maintenance()


func _enter_maintenance() -> void:
	_set_state(State.MAINTENANCE)
	deadline_ms = 0
	# MAINTENANCE means idle, not merely labelled idle: the simulation stops
	# doing work. process_mode on this node is ALWAYS, so /admin/status keeps
	# answering in milliseconds - which is the whole point of that endpoint.
	if get_tree() != null:
		get_tree().paused = true
	print("[AdminApi] MAINTENANCE: zero players, simulation idle, status endpoint live")


func _enter_failed(message: String) -> void:
	_set_state(State.FAILED)
	deadline_ms = 0
	printerr("[AdminApi] FAILED: %s" % message)
	print("[AdminApi] FAILED is a safe hold: players stay connected, joins stay refused, no release may proceed")


func _notify_disconnecting() -> void:
	_broadcast(State.DISCONNECTING, 0)


func _tick_kick() -> void:
	if not _kick_active:
		return
	if _ticks() < _kick_at_ms:
		return
	_kick_count = _kick_everyone()
	_kick_active = false
	_kick_done = true
	print("[AdminApi] disconnect-all: %d session(s) removed, %d remaining" % [
		_kick_count, SimAuthority.players_by_peer.size()])


## Closes every peer and removes every session record, then reports how many
## sessions were attached. Verification (zero players) is the caller's business.
func _kick_everyone() -> int:
	var sessions := SimAuthority.players_by_peer.size()
	var peer := multiplayer.multiplayer_peer
	var ids: Array = multiplayer.get_peers()
	if peer is ENetMultiplayerPeer:
		var enet := peer as ENetMultiplayerPeer
		for peer_id in ids:
			enet.disconnect_peer(int(peer_id), true)
	for peer_id in SimAuthority.players_by_peer.keys():
		SimAuthority.remove_player(int(peer_id))
	return sessions


# ------------------------------------------------------------------ save barrier

func _start_flush() -> void:
	_flush_settled = false
	_flush_result = {}
	var bridge := SimAuthority.persistence
	_flush_bridge = bridge
	if bridge == null:
		# No auth backend: there is nothing to acknowledge, and the barrier must
		# never hang waiting for acks that cannot come (plan Phase 6).
		print("[AdminApi] persistence disabled - save barrier reports saved=0 failed=0")
		_flush_requested = 0
		_flush_skipped = SimAuthority.players_by_peer.size()
		_finish_flush(0, 0)
		return
	var requested := 0
	var skipped := 0
	for peer_id in SimAuthority.players_by_peer.keys():
		var record := SimAuthority.player_record(int(peer_id))
		if record.is_empty():
			continue
		if int(record.get("character_id", 0)) <= 0:
			# A dev join has no character row to flush.
			skipped += 1
			continue
		var node = record.get("node")
		if node == null or not is_instance_valid(node):
			skipped += 1
			continue
		requested += 1
		bridge.save_player(record)
	_flush_requested = requested
	_flush_skipped = skipped
	if requested == 0:
		_finish_flush(0, 0)
		return
	_flush_active = true
	_flush_deadline_ms = _ticks() + SAVE_ACK_TIMEOUT_MS
	# The bridge publishes no per-call completion callback, so the acknowledgement
	# it does publish is watched instead: one HTTPRequest per character appears
	# under it, and the flush has landed once the bridge has been idle for a
	# settle window. If that never happens inside the bounded timeout, the
	# character is reported failed - never silently assumed saved.
	_flush_idle_since = _ticks() if _bridge_inflight(bridge) == 0 else 0


func _tick_flush() -> void:
	if not _flush_active:
		return
	var now := _ticks()
	var inflight := _bridge_inflight(_flush_bridge)
	if inflight == 0:
		if _flush_idle_since == 0:
			_flush_idle_since = now
		elif now - _flush_idle_since >= SAVE_SETTLE_MS:
			_finish_flush(_flush_requested, 0)
			return
	else:
		_flush_idle_since = 0
	if now >= _flush_deadline_ms:
		_finish_flush(maxi(0, _flush_requested - inflight), inflight)


func _finish_flush(saved: int, failed: int) -> void:
	_flush_active = false
	_flush_settled = true
	_flush_result = {
		"ok": failed == 0,
		"saved": saved,
		"failed": failed,
		"skipped": _flush_skipped,
	}
	print("[AdminApi] save barrier: saved=%d failed=%d skipped=%d" % [saved, failed, _flush_skipped])


func _bridge_inflight(bridge: Node) -> int:
	if bridge == null or not is_instance_valid(bridge):
		return 0
	var count := 0
	for child in bridge.get_children():
		if child is HTTPRequest:
			count += 1
	return count


# ------------------------------------------------------------------- deferred IO

func _roll_deferred() -> void:
	if _deferred.is_empty():
		return
	var remaining: Array = []
	for entry in _deferred:
		var kind := String(entry["kind"])
		if kind == "save" and _flush_settled:
			_respond(entry["conn"], 200, _flush_result)
			continue
		if kind == "disconnect" and _kick_done:
			_kick_done = false
			_respond(entry["conn"], 200, {"ok": true, "disconnected": _kick_count})
			continue
		remaining.append(entry)
	_deferred = remaining


# ------------------------------------------------------------------ log hygiene

## Nothing that looks like a service token may reach a log line, even when an
## operator pastes one into a reason string.
func _redact(text: String) -> String:
	var out: Array = []
	for word in text.split(" ", false):
		out.append("***" if _looks_like_secret(word) else word)
	return " ".join(out)


func _looks_like_secret(word: String) -> bool:
	if word.length() < 24:
		return false
	for index in range(word.length()):
		var c := word[index]
		var allowed := (c >= "0" and c <= "9") or (c >= "a" and c <= "z") \
			or (c >= "A" and c <= "Z") or c == "-" or c == "_"
		if not allowed:
			return false
	return true
