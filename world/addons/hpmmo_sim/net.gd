extends Node

## SimNet - the transport between clients and the authoritative world.
##
## OWNER: server repository (synced to the client as part of hpmmo_sim).
##
## Four channels keep movement off the reliable stream, so a lost packet costs a
## few centimetres instead of stalling the player:
##   0 snapshots (unreliable)   1 events (reliable)
##   2 intents (reliable)       3 input frames (unreliable, ordered)
##
## Everything a client sends is an *intent*. Nothing a client sends is trusted:
## the server validates it and answers with its own state. Clients may not relay
## to each other (`server_relay = false`), so a forged snapshot cannot reach a
## third party.

signal joined(ok: bool, reason: String, character: Dictionary)
signal disconnected(reason: String)
signal server_ready(port: int)
signal client_spawned(peer_id: int, character_id: int, name: String)

const HPProtocol = preload("res://addons/hpmmo_sim/protocol.gd")

const DEFAULT_PORT := 7777
const MAX_PLAYERS := 64
const CLIENT_VERSION := "phase5"

enum NetProfile { LOCAL, BROADBAND, MOBILE, AWFUL }

const PROFILES := {
	"local": {"delay_ms": 0, "loss": 0.0},
	"broadband": {"delay_ms": 60, "loss": 0.005},
	"mobile": {"delay_ms": 150, "loss": 0.03},
	"awful": {"delay_ms": 300, "loss": 0.10},
}

var is_client: bool = false
var joined_world: bool = false
## Peer id of this process. Offline play is "peer 1" so the local player is
## addressable exactly like a remote one.
var local_peer_id: int = 1
## uid and character the server assigned at join; the world scene may be created
## after the answer arrives, so they are kept until it binds them.
var local_uid: int = 0
var pending_character: Dictionary = {}
var protocol_mismatch: String = ""
var net_profile: int = NetProfile.LOCAL
var _delayed: Array = []          # [{due_ms, peer_id, method, args}]
var _known_by_peer: Dictionary = {}   # peer_id -> {uid: true, __offset: cursor}
var _last_chat_ms: Dictionary = {}
const CHAT_MIN_INTERVAL_MS := 250
var _snapshot_accumulator: float = 0.0
var _input_accumulator: float = 0.0
var _last_sent_input_seq: int = -1
var _input_seq: int = 0
## Diagnostics for the multiplayer tests.
var input_frames_sent: int = 0
var inputs_received: int = 0
var cast_requests_received: int = 0


func _ready() -> void:
	multiplayer.peer_connected.connect(_on_peer_connected)
	multiplayer.peer_disconnected.connect(_on_peer_disconnected)
	multiplayer.connected_to_server.connect(_on_connected_to_server)
	multiplayer.connection_failed.connect(_on_connection_failed)
	multiplayer.server_disconnected.connect(_on_server_disconnected)
	var profile := OS.get_environment("HPMMO_NET_PROFILE")
	if profile != "":
		set_profile(profile)

func set_profile(name: String) -> void:
	var wanted := name.strip_edges().to_lower()
	for key in PROFILES.keys():
		if key == wanted:
			# Enum values are the uppercase of the profile names.
			net_profile = NetProfile[key.to_upper()]
			print("[SimNet] network profile: %s %s" % [wanted, PROFILES[key]])
			return
	push_warning("[SimNet] unknown network profile '%s'; keeping LOCAL" % name)

func profile_values() -> Dictionary:
	return PROFILES[PROFILES.keys()[net_profile]]

# ------------------------------------------------------------------ hosting

func host(port: int = DEFAULT_PORT) -> Error:
	var peer := ENetMultiplayerPeer.new()
	var error := peer.create_server(port, MAX_PLAYERS)
	if error != OK:
		push_error("[SimNet] cannot bind UDP %d (error %d)" % [port, error])
		return error
	multiplayer.multiplayer_peer = peer
	# Clients talk to the server and to nobody else: no peer-to-peer relay.
	multiplayer.server_relay = false
	is_client = false
	local_peer_id = 1
	print("[SimNet] world server listening on :%d (%s)" % [port, HPProtocol.version_string()])
	emit_signal("server_ready", port)
	return OK

func join(address: String, port: int = DEFAULT_PORT, token: String = "") -> Error:
	var peer := ENetMultiplayerPeer.new()
	var error := peer.create_client(address, port)
	if error != OK:
		push_error("[SimNet] cannot reach %s:%d (error %d)" % [address, port, error])
		emit_signal("disconnected", "connect_failed")
		return error
	multiplayer.multiplayer_peer = peer
	is_client = true
	join_token = token
	return OK

var join_token: String = ""

## Test/probe hook. When set, this intent is sent (and predicted locally) instead
## of reading the keyboard - a headless client has no input device.
var forced_intent: Dictionary = {}

func _local_intent() -> Dictionary:
	if not forced_intent.is_empty():
		return forced_intent
	var player = SimAuthority.local_player_node()
	if player == null or not is_instance_valid(player):
		return {"move": Vector2.ZERO, "yaw": 0.0, "jump": false, "descend": false}
	return player.sim_input_intent()

func leave() -> void:
	if is_inside_tree() and multiplayer and multiplayer.multiplayer_peer != null:
		multiplayer.multiplayer_peer.close()
		multiplayer.multiplayer_peer = null
	is_client = false
	joined_world = false
	_known_by_peer.clear()
	_last_chat_ms.clear()

func _on_connected_to_server() -> void:
	local_peer_id = multiplayer.get_unique_id()
	sim_join.rpc_id(1, join_token, HPProtocol.PROTOCOL_VERSION, CLIENT_VERSION)
	print("[SimNet] connected as peer %d; join sent" % local_peer_id)

## Two bodies spawned at the same point interpenetrate, and the physics engine
## resolves that by launching them apart - which looks exactly like a teleport
## hack to everyone else. Nudge a new arrival to the nearest clear spot instead.
func _avoid_spawn_overlap(node: Node3D) -> void:
	const CLEARANCE := 1.4
	var my_map := HPMaps.map_for_point(node.global_position)
	var occupied: Array = []
	for uid in SimAuthority.entities.keys():
		var record: Dictionary = SimAuthority.entities[uid]
		if int(record.get("kind", 0)) != HPProtocol.Kind.PLAYER:
			continue
		if String(record.get("map_id", HPProtocol.DEFAULT_MAP)) != my_map:
			continue   # two bodies on different maps are not in each other's way
		var other = record.get("node")
		if other != null and is_instance_valid(other) and other != node:
			occupied.append((other as Node3D).global_position)
	if occupied.is_empty():
		return
	var origin := node.global_position
	for ring in range(1, 5):
		for step in range(8):
			var angle := TAU * float(step) / 8.0
			var candidate := origin + Vector3(cos(angle), 0.0, sin(angle)) * (CLEARANCE * float(ring))
			var clear := true
			for position in occupied:
				if (position as Vector3).distance_to(candidate) < CLEARANCE:
					clear = false
					break
			if clear:
				node.global_position = candidate
				return

func _on_peer_connected(peer_id: int) -> void:
	print("[SimNet] peer %d connected" % peer_id)

func _on_peer_disconnected(peer_id: int) -> void:
	print("[SimNet] peer %d disconnected" % peer_id)
	_known_by_peer.erase(peer_id)
	if not is_client:
		SimAuthority.remove_player(peer_id)
		emit_signal("client_spawned", peer_id, 0, "")

func _on_connection_failed() -> void:
	leave()
	emit_signal("disconnected", "connect_failed")

func _on_server_disconnected() -> void:
	leave()
	emit_signal("disconnected", "server_closed")

# -------------------------------------------------------------- RPC surface
# Client -> server (validated). "any_peer" is required so a client may call it;
# every handler re-derives the sender and validates before acting.

@rpc("any_peer", "call_remote", "reliable", HPProtocol.CH_INTENT)
func sim_join(token: String, protocol_version: int, client_version: String) -> void:
	if is_client:
		return
	var peer_id := multiplayer.get_remote_sender_id()
	if SimAuthority.players_by_peer.has(peer_id):
		# One join per connection: a repeat would spawn another body, leak the
		# previous one, and re-run the (synchronous) auth round trip.
		sim_join_result.rpc_id(peer_id, false, "already_joined", 0, {}, SimAuthority.sim_tick, 0)
		return
	if not SimAuthority.joins_allowed():
		# Maintenance (plan.md Phase 6): logins close at ANNOUNCING and stay
		# closed until the world is ONLINE again.
		sim_join_result.rpc_id(peer_id, false, "maintenance", 0, {}, SimAuthority.sim_tick, 0)
		return
	if protocol_version != HPProtocol.PROTOCOL_VERSION:
		sim_join_result.rpc_id(peer_id, false, "protocol_mismatch:%d" % HPProtocol.PROTOCOL_VERSION, 0, {}, SimAuthority.sim_tick, 0)
		return
	var identity := {}
	if SimAuthority.persistence != null:
		var resolved: Dictionary = SimAuthority.persistence.resolve_session(token)
		if not bool(resolved.get("ok", false)):
			sim_join_result.rpc_id(peer_id, false, String(resolved.get("reason", "auth_failed")), 0, {}, SimAuthority.sim_tick, 0)
			return
		identity = resolved
	elif OS.get_environment("HPMMO_ALLOW_DEV_JOIN") == "1":
		# Development/testing only: with no auth backend configured the join token
		# is taken as a display name. Refused outright when the opt-in is absent.
		var dev_name := token.strip_edges()
		if dev_name.is_empty():
			dev_name = "Dev%d" % peer_id
		identity = {"account_id": 0, "character_id": 0, "name": dev_name, "house": "Gryffindor"}
		# Optional dev spawn point ("x,y,z"): lets a test place clients next to the
		# content under test instead of walking there. Dev joins only.
		var spawn := OS.get_environment("HPMMO_DEV_SPAWN")
		if spawn != "":
			var parts := spawn.split(",")
			if parts.size() == 3:
				identity["spawn"] = [float(parts[0]), float(parts[1]), float(parts[2])]
		print("[SimNet] DEV JOIN (no auth backend): peer %d as '%s'" % [peer_id, dev_name])
	else:
		sim_join_result.rpc_id(peer_id, false, "no_auth_backend", 0, {}, SimAuthority.sim_tick, 0)
		return
	sim_spawn_player(peer_id, identity)

func sim_spawn_player(peer_id: int, identity: Dictionary) -> void:
	var world = SimAuthority.world
	if world == null:
		sim_join_result.rpc_id(peer_id, false, "world_not_ready", 0, {}, SimAuthority.sim_tick, 0)
		return
	var players_container = world.get_node_or_null("Players")
	if players_container == null:
		sim_join_result.rpc_id(peer_id, false, "world_not_ready", 0, {}, SimAuthority.sim_tick, 0)
		return
	var scene: PackedScene = load("res://scenes/entities/player/player.tscn")
	var node: Node3D = scene.instantiate()
	node.name = "P%d" % peer_id
	node.is_local_player = false
	node.player_name = String(identity.get("name", "Wizard"))
	node.house = String(identity.get("house", "Gryffindor"))
	players_container.add_child(node)
	var character: Dictionary = {}
	if SimAuthority.persistence != null:
		character = SimAuthority.persistence.load_character(int(identity.get("character_id", 0)))
	if not character.is_empty():
		node.restore_character(character)
		if character.has("pos") and (character["pos"] as Array).size() == 3:
			var pos: Array = character["pos"]
			node.global_position = Vector3(float(pos[0]), float(pos[1]), float(pos[2]))
		# A character that logged out inside the castle resumes there: the saved
		# map is authoritative, and a saved position that does not belong to it
		# (an interrupted transfer, an edited save) is replaced by that map's
		# authored respawn instead of stranding the body between maps.
		var saved_map := String(character.get("map_id", ""))
		if HPMaps.map_exists(saved_map):
			node.global_position = HPMaps.valid_position(saved_map, node.global_position)
		else:
			node.global_position = HPMaps.valid_position(
				HPMaps.map_for_point(node.global_position), node.global_position)
	elif identity.has("spawn"):
		var spawn: Array = identity["spawn"]
		node.global_position = Vector3(float(spawn[0]), float(spawn[1]), float(spawn[2]))
	_avoid_spawn_overlap(node)
	var uid := SimAuthority.register_player(node, int(identity.get("character_id", 0)), peer_id)
	_known_by_peer[peer_id] = {}
	sim_join_result.rpc_id(peer_id, true, "", uid, character, SimAuthority.sim_tick, SimAuthority.seed_value)
	# The client needs its own numbers immediately: without this it would show
	# defaults until the first time something changed them.
	sim_stats_event.rpc_id(peer_id, uid, SimAuthority.build_stats(SimAuthority.entities[uid]))
	# And it needs to know which map it belongs to before a single snapshot
	# arrives, or it would boot the wrong map scene.
	sim_map_state.rpc_id(peer_id, String(SimAuthority.entities[uid].get("map_id", HPProtocol.DEFAULT_MAP)),
		node.global_position, "")
	sim_chat_event.rpc("[Server] %s joined the realm." % node.player_name)
	emit_signal("client_spawned", peer_id, int(identity.get("character_id", 0)), String(node.player_name))

@rpc("any_peer", "call_remote", "unreliable_ordered", HPProtocol.CH_INPUT)
func sim_input(seq: int, move: Vector2, yaw: float, jump: bool, descend: bool) -> void:
	if is_client:
		return
	inputs_received += 1
	SimAuthority.submit_input(multiplayer.get_remote_sender_id(), seq, move, yaw, jump, descend)

@rpc("any_peer", "call_remote", "reliable", HPProtocol.CH_INTENT)
func sim_cast_request(spell_id: String, aim: Vector3, cast_seq: int) -> void:
	if is_client:
		return
	var peer_id := multiplayer.get_remote_sender_id()
	cast_requests_received += 1
	# A NaN aim is not a direction: it compares false against every cone and
	# range test and would leak NaN into other clients' VFX.
	if not is_finite(aim.x) or not is_finite(aim.y) or not is_finite(aim.z):
		sim_cast_result.rpc_id(peer_id, cast_seq, 0, false, HPProtocol.REJECT_STATE)
		return
	var result := SimAuthority.request_cast(peer_id, spell_id, aim, cast_seq)
	sim_cast_result.rpc_id(peer_id, cast_seq, int(result.get("cast_id", 0)),
		bool(result.get("ok", false)), String(result.get("reason", "")))

@rpc("any_peer", "call_remote", "reliable", HPProtocol.CH_INTENT)
func sim_mount_request(mounted: bool) -> void:
	if is_client:
		return
	var result := SimAuthority.submit_mount(multiplayer.get_remote_sender_id(), mounted)
	if not bool(result.get("ok", false)):
		sim_notice.rpc_id(multiplayer.get_remote_sender_id(), "cannot_mount", String(result.get("reason", "")))

@rpc("any_peer", "call_remote", "reliable", HPProtocol.CH_INTENT)
func sim_respawn_request() -> void:
	if is_client:
		return
	SimAuthority.submit_respawn(multiplayer.get_remote_sender_id())

## Map transfer (plan.md Phase 8), client -> server. The client names the portal
## it stands at and the map it believes the door leads to; the authority checks
## both against the catalog (never trusting the claim) and answers through the
## transfer signals, which the bridge below fans out to exactly this peer.
@rpc("any_peer", "call_remote", "reliable", HPProtocol.CH_INTENT)
func sim_transfer_request(portal_id: String, to_map: String) -> void:
	if is_client:
		return
	SimAuthority.request_transfer(multiplayer.get_remote_sender_id(),
		portal_id.strip_edges().substr(0, 64), to_map.strip_edges().substr(0, 64))

@rpc("any_peer", "call_remote", "reliable", HPProtocol.CH_INTENT)
func sim_transfer_ready(token: int) -> void:
	if is_client:
		return
	SimAuthority.transfer_ready(multiplayer.get_remote_sender_id(), token)

@rpc("any_peer", "call_remote", "reliable", HPProtocol.CH_INTENT)
func sim_transfer_abort(token: int) -> void:
	if is_client:
		return
	SimAuthority.transfer_abort(multiplayer.get_remote_sender_id(), token)

@rpc("any_peer", "call_remote", "reliable", HPProtocol.CH_INTENT)
func sim_pickup_request(loot_uid: int) -> void:
	if is_client:
		return
	var result := SimAuthority.request_pickup(multiplayer.get_remote_sender_id(), loot_uid)
	if not bool(result.get("ok", false)):
		sim_notice.rpc_id(multiplayer.get_remote_sender_id(), "pickup", String(result.get("reason", "")))

@rpc("any_peer", "call_remote", "reliable", HPProtocol.CH_INTENT)
func sim_chat_request(text: String) -> void:
	if is_client:
		return
	var peer_id := multiplayer.get_remote_sender_id()
	var record := SimAuthority.player_record(peer_id)
	if record.is_empty():
		return
	var now := Time.get_ticks_msec()
	if now - int(_last_chat_ms.get(peer_id, 0)) < CHAT_MIN_INTERVAL_MS:
		return   # one line per interval: chat shares the reliable channel
	_last_chat_ms[peer_id] = now
	var clean := text.strip_edges().substr(0, 200)
	if clean.is_empty():
		return
	sim_chat_event.rpc("[%s] %s" % [String(record.get("name", "Wizard")), clean])

# Server -> client (authority only). A client calling these is ignored.

@rpc("authority", "call_remote", "reliable", HPProtocol.CH_EVENT)
func sim_join_result(ok: bool, reason: String, uid: int, character: Dictionary, tick: int, world_seed: int) -> void:
	joined_world = ok
	protocol_mismatch = reason if reason.begins_with("protocol_mismatch") else ""
	if ok:
		SimAuthority.sim_tick = tick
		SimAuthority.seed_value = world_seed
		local_uid = uid
		pending_character = character
		# Bind even when the server sent no character sheet (a dev join with no
		# persistence): the uid is what makes this body addressable.
		if SimAuthority.local_player_node() != null:
			SimAuthority.register_local_player(uid, character)
	emit_signal("joined", ok, reason, character)

@rpc("authority", "call_remote", "reliable", HPProtocol.CH_EVENT)
func sim_cast_result(cast_seq: int, cast_id: int, ok: bool, reason: String) -> void:
	SimAuthority.on_cast_result(cast_seq, cast_id, ok, reason)

@rpc("authority", "call_remote", "reliable", HPProtocol.CH_EVENT)
func sim_cast_started(uid: int, cast_id: int, spell_id: String, aim: Vector3, release_tick: int) -> void:
	SimAuthority.emit_signal("cast_started", uid, cast_id, spell_id, aim, release_tick)

@rpc("authority", "call_remote", "reliable", HPProtocol.CH_EVENT)
func sim_cast_released(cast_id: int, caster_uid: int, spell_id: String, origin: Vector3, dir: Vector3) -> void:
	SimAuthority.emit_signal("cast_released", cast_id, caster_uid, spell_id, origin, dir)

@rpc("authority", "call_remote", "reliable", HPProtocol.CH_EVENT)
func sim_cast_landed(cast_id: int, caster_uid: int, spell_id: String, hits: Array) -> void:
	SimAuthority.emit_signal("cast_landed", cast_id, caster_uid, spell_id, hits)

@rpc("authority", "call_remote", "reliable", HPProtocol.CH_EVENT)
func sim_damage_event(uid: int, amount: int, hp: int, spell_id: String, attacker_uid: int) -> void:
	SimAuthority.on_damage_event(uid, amount, hp, spell_id, attacker_uid)

@rpc("authority", "call_remote", "reliable", HPProtocol.CH_EVENT)
func sim_death_event(uid: int, killer_uid: int) -> void:
	SimAuthority.on_death_event(uid, killer_uid)

@rpc("authority", "call_remote", "reliable", HPProtocol.CH_EVENT)
func sim_respawn_event(uid: int) -> void:
	SimAuthority.on_respawn_event(uid)

@rpc("authority", "call_remote", "reliable", HPProtocol.CH_EVENT)
func sim_stats_event(uid: int, stats: Dictionary) -> void:
	SimAuthority.apply_stats_payload(uid, stats)

@rpc("authority", "call_remote", "reliable", HPProtocol.CH_EVENT)
func sim_loot_event(uid: int, item_id: String, amount: int, pos: Vector3) -> void:
	SimAuthority.emit_signal("loot_spawned", uid, item_id, amount, pos)

@rpc("authority", "call_remote", "reliable", HPProtocol.CH_EVENT)
func sim_loot_despawn(uid: int) -> void:
	SimAuthority.emit_signal("entity_despawned", uid)

@rpc("authority", "call_remote", "reliable", HPProtocol.CH_EVENT)
func sim_reward_event(character_id: int, exp: int, galleons: int, items: Array, op_id: String) -> void:
	SimAuthority.emit_signal("reward_granted", SimAuthority.local_uid, character_id, exp, galleons, items, op_id)

@rpc("authority", "call_remote", "reliable", HPProtocol.CH_EVENT)
func sim_chat_event(text: String) -> void:
	SimAuthority.emit_signal("chat", text)

@rpc("authority", "call_remote", "reliable", HPProtocol.CH_EVENT)
func sim_notice(kind: String, detail: String) -> void:
	SimAuthority.emit_signal("notice", kind + ":" + detail, Color(1.0, 0.8, 0.4))

## Maintenance lifecycle (plan.md Phase 6). Signal emission only: the client's
## countdown/HUD presentation listens to SimAuthority.maintenance_event.
@rpc("authority", "call_remote", "reliable", HPProtocol.CH_EVENT)
func sim_maintenance_event(state: String, reason: String, seconds_remaining: int) -> void:
	SimAuthority.on_maintenance_event(state, reason, seconds_remaining)

## Map transfer lifecycle (plan.md Phase 8). Emission only: the client's map
## controller listens to SimAuthority.transfer_* / map_state.
@rpc("authority", "call_remote", "reliable", HPProtocol.CH_EVENT)
func sim_transfer_granted(token: int, map_id: String, spawn_id: String) -> void:
	SimAuthority.emit_signal("transfer_granted", local_peer_id, token, map_id, spawn_id)

@rpc("authority", "call_remote", "reliable", HPProtocol.CH_EVENT)
func sim_transfer_committed(token: int, map_id: String, pos: Vector3, spawn_id: String) -> void:
	SimAuthority.emit_signal("transfer_committed", local_peer_id, token, map_id, pos, spawn_id)
	# Ownership already moved on the authority: the client binds the new map and
	# places its predicted body at the server-approved spawn immediately, so the
	# transition does not wait for the next snapshot.
	SimAuthority.apply_map_state(SimAuthority.local_uid, map_id, pos, spawn_id)

@rpc("authority", "call_remote", "reliable", HPProtocol.CH_EVENT)
func sim_transfer_refused(reason: String) -> void:
	SimAuthority.emit_signal("transfer_refused", local_peer_id, reason)

@rpc("authority", "call_remote", "reliable", HPProtocol.CH_EVENT)
func sim_transfer_expired(token: int, map_id: String, pos: Vector3) -> void:
	SimAuthority.emit_signal("transfer_expired", local_peer_id, token, map_id, pos)
	# The body is back at its last valid safe spawn: resync the prediction.
	SimAuthority.apply_map_state(SimAuthority.local_uid, map_id, pos, "")

@rpc("authority", "call_remote", "reliable", HPProtocol.CH_EVENT)
func sim_map_state(map_id: String, pos: Vector3, spawn_id: String) -> void:
	SimAuthority.note_map_state(map_id, pos, spawn_id)

@rpc("authority", "call_remote", "unreliable", HPProtocol.CH_SNAPSHOT)
func sim_snapshot(tick: int, chunk: int, chunks: int, data: PackedByteArray) -> void:
	if not is_client:
		return
	# The snapshot carries the server's clock: mirroring it here is what lets a
	# client reason about "the same tick" as everyone else (timings, and every
	# test that compares when something happened).
	if tick < SimAuthority.sim_tick:
		return   # a late datagram must not drag the world backwards
	if tick > SimAuthority.sim_tick:
		SimAuthority.sim_tick = tick
	HPSnapshots.apply(data, SimAuthority)

@rpc("authority", "call_remote", "reliable", HPProtocol.CH_SNAPSHOT)
func sim_despawn(uid: int) -> void:
	SimAuthority.emit_signal("entity_despawned", uid)

## Boss telegraph (plan.md Phase 11). The record keeps the shape and the
## authoritative start/release ticks; presentation (mob_base) renders the
## warning from them, so what a player sees cannot disagree with when the
## damage lands.
@rpc("authority", "call_remote", "reliable", HPProtocol.CH_EVENT)
func sim_telegraph(uid: int, data: Dictionary) -> void:
	var record: Dictionary = SimAuthority.entities.get(uid, {})
	if not record.is_empty():
		record["telegraph"] = data
	SimAuthority.emit_signal("mob_telegraph", uid, data)

@rpc("authority", "call_remote", "reliable", HPProtocol.CH_EVENT)
func sim_telegraph_end(uid: int) -> void:
	var record: Dictionary = SimAuthority.entities.get(uid, {})
	if not record.is_empty():
		record.erase("telegraph")
	SimAuthority.emit_signal("mob_telegraph_end", uid)

# ------------------------------------------------------------ outbound sends

func _process(delta: float) -> void:
	_flush_delayed()
	if SimAuthority.is_authority():
		_snapshot_accumulator += delta
		if _snapshot_accumulator >= 1.0 / float(HPProtocol.SNAPSHOT_HZ):
			_snapshot_accumulator = 0.0
			_broadcast_snapshots()
		return
	if not is_client or not joined_world:
		return
	_input_accumulator += delta
	if _input_accumulator >= HPProtocol.SIM_DT:
		_input_accumulator = 0.0
		_send_local_input()

func _send_local_input() -> void:
	var player = SimAuthority.local_player_node()
	if player == null or not is_instance_valid(player):
		return
	_input_seq += 1
	var intent: Dictionary = _local_intent()
	input_frames_sent += 1
	var values := profile_values()
	var args := [_input_seq, intent["move"], intent["yaw"], intent["jump"], intent["descend"]]
	if float(values["loss"]) > 0.0 and randf() < float(values["loss"]):
		return
	_send_delayed(1, "sim_input", args, int(values["delay_ms"]))

## Single entry points used by client code in EVERY role. In role CLIENT the
## request travels to the server; in the authority roles it is answered locally
## by the same engine, so offline play exercises the identical code path.
func submit_cast(player_node: Node, spell_id: String, aim: Vector3, cast_seq: int) -> Dictionary:
	if is_client:
		_send_delayed(1, "sim_cast_request", [spell_id, aim, cast_seq], int(profile_values()["delay_ms"]))
		return {"ok": true, "reason": "sent", "cast_id": 0}
	var record := SimAuthority.record_for(player_node)
	if record.is_empty():
		return HPProtocol.reject(HPProtocol.REJECT_STATE)
	var result := SimAuthority.cast_for_record(record, spell_id, aim, cast_seq)
	SimAuthority.on_cast_result(cast_seq, int(result.get("cast_id", 0)),
		bool(result.get("ok", false)), String(result.get("reason", "")))
	return result

func submit_mount(player_node: Node, mounted: bool) -> Dictionary:
	if is_client:
		sim_mount_request.rpc_id(1, mounted)
		return HPProtocol.accept()
	var record := SimAuthority.record_for(player_node)
	if record.is_empty():
		return HPProtocol.reject(HPProtocol.REJECT_STATE)
	return SimAuthority.submit_mount(int(record.get("peer_id", 0)), mounted)

func submit_respawn(player_node: Node) -> Dictionary:
	if is_client:
		sim_respawn_request.rpc_id(1)
		return HPProtocol.accept()
	var record := SimAuthority.record_for(player_node)
	if record.is_empty():
		return HPProtocol.reject(HPProtocol.REJECT_STATE)
	return SimAuthority.submit_respawn(int(record.get("peer_id", 0)))

func submit_pickup(player_node: Node, loot_uid: int) -> Dictionary:
	if is_client:
		sim_pickup_request.rpc_id(1, loot_uid)
		return HPProtocol.accept()
	var record := SimAuthority.record_for(player_node)
	if record.is_empty():
		return HPProtocol.reject(HPProtocol.REJECT_STATE)
	return SimAuthority.request_pickup(int(record.get("peer_id", 0)), loot_uid)

## Map transfer entry points, used by client code in EVERY role (plan.md Phase
## 8). In role CLIENT the exchange travels to the server; in the authority roles
## the same engine answers locally, so offline/host play exercises the identical
## validation. A client-role call answers only "sent": the transfer_* signals
## are the real answer, and no local code may skip them.
func request_transfer(player_node: Node, portal_id: String, to_map: String = "") -> Dictionary:
	if is_client:
		sim_transfer_request.rpc_id(1, portal_id, to_map)
		return {"ok": true, "reason": "sent"}
	var record := SimAuthority.record_for(player_node)
	if record.is_empty():
		return HPProtocol.reject(HPProtocol.REJECT_STATE)
	return SimAuthority.request_transfer(int(record.get("peer_id", 0)), portal_id, to_map)

## The client finished loading the destination map: acknowledging is what moves
## entity ownership. Nothing else may do it.
func mark_transfer_ready(token: int) -> Dictionary:
	if is_client:
		sim_transfer_ready.rpc_id(1, token)
		return {"ok": true, "reason": "sent"}
	return SimAuthority.transfer_ready(local_peer_id, token)

func abort_transfer(token: int) -> Dictionary:
	if is_client:
		sim_transfer_abort.rpc_id(1, token)
		return {"ok": true, "reason": "sent"}
	return SimAuthority.transfer_abort(local_peer_id, token)

func submit_chat(text: String) -> void:
	if is_client:
		sim_chat_request.rpc_id(1, text)
		return
	SimAuthority.emit_signal("chat", text)
	if has_peers():
		sim_chat_event.rpc(text)

## True once a peer is attached (offline and dedicated-without-clients return
## false, which is what keeps `rpc()` from erroring in single-player).
func has_peers() -> bool:
	if multiplayer.multiplayer_peer == null:
		return false
	return not multiplayer.get_peers().is_empty()

## Wire the authority's events onto the network. Called by the world server and
## by a hosting player; a pure client must never call this (it would echo the
## server's own events back at it).
func bridge_authority() -> void:
	if is_client:
		return
	SimAuthority.chat.connect(broadcast_chat)
	SimAuthority.entity_damaged.connect(broadcast_damage)
	SimAuthority.entity_died.connect(broadcast_death)
	SimAuthority.entity_respawned.connect(broadcast_respawn)
	SimAuthority.cast_started.connect(broadcast_cast_started)
	SimAuthority.cast_released.connect(broadcast_cast_released)
	SimAuthority.cast_landed.connect(broadcast_cast_landed)
	SimAuthority.stats_changed.connect(broadcast_stats)
	SimAuthority.loot_spawned.connect(broadcast_loot)
	SimAuthority.loot_taken.connect(broadcast_loot_taken)
	SimAuthority.mob_telegraph.connect(broadcast_telegraph)
	SimAuthority.mob_telegraph_end.connect(broadcast_telegraph_end)
	SimAuthority.maintenance_event.connect(broadcast_maintenance)
	SimAuthority.transfer_granted.connect(broadcast_transfer_granted)
	SimAuthority.transfer_committed.connect(broadcast_transfer_committed)
	SimAuthority.transfer_refused.connect(broadcast_transfer_refused)
	SimAuthority.transfer_expired.connect(broadcast_transfer_expired)
	SimAuthority.reward_granted.connect(func(uid: int, character_id: int, exp: int, galleons: int, items: Array, op_id: String):
		broadcast_reward(uid, character_id, exp, galleons, items, op_id))
	print("[SimNet] authority events bridged to %d peer(s)" % multiplayer.get_peers().size())

func _broadcast_snapshots() -> void:
	if not has_peers():
		return
	for peer_id in multiplayer.get_peers():
		var record := SimAuthority.player_record(peer_id)
		if record.is_empty():
			continue
		var center: Vector3 = record["node"].global_position
		var known: Dictionary = _known_by_peer.get(peer_id, {})
		var result: Dictionary = HPSnapshots.encode_for(SimAuthority, peer_id, center, known)
		var bytes: PackedByteArray = result["bytes"]

		# Visible set = replicated entities in the interest set, plus loot in
		# range. Loot never moves, so it travels as reliable spawn/despawn
		# events; spawns are re-sent on first sight, which is what lets a late
		# joiner see ground loot that dropped before it arrived.
		var current: Dictionary = {}
		for uid in result["uids"]:
			current[int(uid)] = true
		for uid in SimAuthority.entities.keys():
			var loot: Dictionary = SimAuthority.entities[uid]
			if int(loot.get("kind", 0)) != HPProtocol.Kind.LOOT:
				continue
			if String(loot.get("map_id", HPProtocol.DEFAULT_MAP)) != String(record.get("map_id", HPProtocol.DEFAULT_MAP)):
				continue   # loot on another map is not this client's to see
			if (loot["pos"] as Vector3).distance_to(center) > HPProtocol.INTEREST_RADIUS:
				continue
			current[int(uid)] = true
			if not known.has(int(uid)):
				sim_loot_event.rpc_id(peer_id, int(uid), String(loot["item_id"]), int(loot["amount"]), loot["pos"])

		for uid in known.keys():
			if typeof(uid) == TYPE_STRING:
				continue   # rotation cursor, not an entity (int == String is an error)
			if not current.has(int(uid)):
				sim_despawn.rpc_id(peer_id, int(uid))
		_known_by_peer[peer_id] = current

		var chunk_size := 900
		var chunks := maxi(1, int(ceil(float(bytes.size()) / float(chunk_size))))
		for index in range(chunks):
			var slice := bytes.slice(index * chunk_size, mini(bytes.size(), (index + 1) * chunk_size))
			sim_snapshot.rpc_id(peer_id, SimAuthority.sim_tick, index, chunks, slice)

## Event fan-out used by the world server for authority signals. Clients that
## cannot see the entity are skipped; that is the interest filter for events.
func broadcast_damage(uid: int, amount: int, hp: int, spell_id: String, attacker_uid: int) -> void:
	if not has_peers():
		return
	for peer_id in multiplayer.get_peers():
		if _peer_can_see(peer_id, uid) or _peer_can_see(peer_id, attacker_uid):
			sim_damage_event.rpc_id(peer_id, uid, amount, hp, spell_id, attacker_uid)

func broadcast_death(uid: int, killer_uid: int) -> void:
	if not has_peers():
		return
	for peer_id in multiplayer.get_peers():
		if _peer_can_see(peer_id, uid):
			sim_death_event.rpc_id(peer_id, uid, killer_uid)

func broadcast_respawn(uid: int) -> void:
	if not has_peers():
		return
	for peer_id in multiplayer.get_peers():
		sim_respawn_event.rpc_id(peer_id, uid)

func broadcast_cast_started(uid: int, cast_id: int, spell_id: String, aim: Vector3, release_tick: int) -> void:
	if not has_peers():
		return
	for peer_id in multiplayer.get_peers():
		if _peer_can_see(peer_id, uid):
			sim_cast_started.rpc_id(peer_id, uid, cast_id, spell_id, aim, release_tick)

func broadcast_cast_released(cast_id: int, caster_uid: int, spell_id: String, origin: Vector3, dir: Vector3) -> void:
	if not has_peers():
		return
	for peer_id in multiplayer.get_peers():
		sim_cast_released.rpc_id(peer_id, cast_id, caster_uid, spell_id, origin, dir)

func broadcast_cast_landed(cast_id: int, caster_uid: int, spell_id: String, hits: Array) -> void:
	if not has_peers():
		return
	for peer_id in multiplayer.get_peers():
		sim_cast_landed.rpc_id(peer_id, cast_id, caster_uid, spell_id, hits)

func broadcast_stats(uid: int, stats: Dictionary) -> void:
	if not has_peers():
		return
	for peer_id in multiplayer.get_peers():
		if _peer_can_see(peer_id, uid):
			sim_stats_event.rpc_id(peer_id, uid, stats)

func broadcast_loot(uid: int, item_id: String, amount: int, pos: Vector3) -> void:
	if not has_peers():
		return
	var loot_map := String(SimAuthority.entities.get(uid, {}).get("map_id", HPProtocol.DEFAULT_MAP))
	for peer_id in multiplayer.get_peers():
		var record := SimAuthority.player_record(peer_id)
		if record.is_empty() or String(record.get("map_id", HPProtocol.DEFAULT_MAP)) != loot_map:
			continue
		sim_loot_event.rpc_id(peer_id, uid, item_id, amount, pos)

func broadcast_loot_taken(uid: int, character_id: int, _item_id: String, _amount: int) -> void:
	if not has_peers():
		return
	var loot_map := String(SimAuthority.entities.get(uid, {}).get("map_id", HPProtocol.DEFAULT_MAP))
	for peer_id in multiplayer.get_peers():
		var record := SimAuthority.player_record(peer_id)
		if record.is_empty() or String(record.get("map_id", HPProtocol.DEFAULT_MAP)) != loot_map:
			continue
		if int(record.get("character_id", 0)) == character_id:
			sim_reward_event.rpc_id(peer_id, character_id, 0, 0, [], "loot")
		sim_loot_despawn.rpc_id(peer_id, uid)

func broadcast_reward(uid: int, character_id: int, exp: int, galleons: int, items: Array, op_id: String) -> void:
	if not has_peers():
		return
	# Addressed by entity uid: the reward belongs to one session, and two
	# sessions may legitimately have no character bound yet.
	for peer_id in multiplayer.get_peers():
		var record := SimAuthority.player_record(peer_id)
		if not record.is_empty() and int(record.get("uid", 0)) == uid:
			sim_reward_event.rpc_id(peer_id, character_id, exp, galleons, items, op_id)

## Boss telegraph fan-out (plan.md Phase 11). Reliable, to every peer that can
## see the mob inside its interest set; the timing inside is authoritative, not
## a client-side estimate.
func broadcast_telegraph(uid: int, data: Dictionary) -> void:
	if not has_peers():
		return
	for peer_id in multiplayer.get_peers():
		if _peer_can_see(peer_id, uid):
			sim_telegraph.rpc_id(peer_id, uid, data)

func broadcast_telegraph_end(uid: int) -> void:
	if not has_peers():
		return
	for peer_id in multiplayer.get_peers():
		if _peer_can_see(peer_id, uid):
			sim_telegraph_end.rpc_id(peer_id, uid)

func broadcast_chat(text: String) -> void:
	if not has_peers():
		return
	sim_chat_event.rpc(text)

## Maintenance notification fan-out (plan.md Phase 6). Reliable, to every
## connected client: the countdown has to arrive even for a client that is not
## (or no longer) a spawned player.
func broadcast_maintenance(state: String, reason: String, seconds_remaining: int) -> void:
	if not has_peers():
		return
	sim_maintenance_event.rpc(state, reason, seconds_remaining)

## Map transfer fan-out (plan.md Phase 8). Each answer goes to exactly the peer
## that owns the reservation; a peer that has already dropped is skipped.
func _send_peer_event(peer_id: int, method: String, args: Array) -> void:
	if peer_id <= 0 or not has_peers():
		return
	if not multiplayer.get_peers().has(peer_id):
		return
	callv("rpc_id", [peer_id, method] + args)

func broadcast_transfer_granted(peer_id: int, token: int, map_id: String, spawn_id: String) -> void:
	_send_peer_event(peer_id, "sim_transfer_granted", [token, map_id, spawn_id])

func broadcast_transfer_committed(peer_id: int, token: int, map_id: String, pos: Vector3, spawn_id: String) -> void:
	_send_peer_event(peer_id, "sim_transfer_committed", [token, map_id, pos, spawn_id])

func broadcast_transfer_refused(peer_id: int, reason: String) -> void:
	_send_peer_event(peer_id, "sim_transfer_refused", [reason])
	if reason != HPProtocol.REJECT_ABORTED:
		# The player asked to go somewhere; the refusal must say why rather than
		# silently doing nothing.
		_send_peer_event(peer_id, "sim_notice", ["transfer_refused", reason])

func broadcast_transfer_expired(peer_id: int, token: int, map_id: String, pos: Vector3) -> void:
	_send_peer_event(peer_id, "sim_transfer_expired", [token, map_id, pos])
	_send_peer_event(peer_id, "sim_map_state", [map_id, pos, ""])
	_send_peer_event(peer_id, "sim_notice", ["transfer_expired",
		"the transfer timed out; you are back at your last safe spot"])

func _peer_can_see(peer_id: int, uid: int) -> bool:
	var known: Dictionary = _known_by_peer.get(peer_id, {})
	return known.has(uid)

# --------------------------------------------------- latency/loss simulation

## Delay and drop *outgoing* messages for the documented test profiles. Applied
## at the application layer so it can be enabled per process (server, client, or
## both) without touching ENet internals.
func _send_delayed(peer_id: int, method: String, args: Array, delay_ms: int) -> void:
	if delay_ms <= 0:
		callv("rpc_id", [peer_id, method] + args)
		return
	_delayed.append({
		"due": Time.get_ticks_msec() + delay_ms,
		"peer_id": peer_id,
		"method": method,
		"args": args,
	})

func _flush_delayed() -> void:
	if _delayed.is_empty():
		return
	var now := Time.get_ticks_msec()
	var keep: Array = []
	for entry in _delayed:
		if int(entry["due"]) <= now:
			callv("rpc_id", [int(entry["peer_id"]), String(entry["method"])] + (entry["args"] as Array))
		else:
			keep.append(entry)
	_delayed = keep
