extends Node

## NetworkManager Autoload - Multiplayer ENet Host/Client Management
## Handles connection lifecycle, peer registry, chat replication, state relaying, and dedicated server mode

signal player_connected_signal(peer_id: int, player_info: Dictionary)
signal player_disconnected_signal(peer_id: int)
signal connection_status_changed(status: String)
signal connection_succeeded
signal connection_failed
signal server_disconnected_signal
signal chat_message_received(sender_name: String, sender_house: String, message: String)
signal remote_spell_cast(peer_id: int, spell_id: String, from_pos: Vector3, dir: Vector3)
signal auth_register_result(success: bool, message: String)
signal auth_login_result(success: bool, message: String, characters: Array)
signal character_create_result(success: bool, message: String, char_data: Dictionary)
signal character_select_result(success: bool, message: String, char_data: Dictionary)

const DEFAULT_PORT: int = 7777
const MAX_PLAYERS: int = 32

var peer: ENetMultiplayerPeer = null
var is_server: bool = false
var is_dedicated_server: bool = false
var is_connected_to_game: bool = false
var _sync_timer: float = 0.0

var local_player_name: String = "Wizard"
var local_player_house: String = "Gryffindor"
var local_account_id: int = 0
var local_character_id: int = 0
var local_character_data: Dictionary = {}
var connected_players: Dictionary = {}
var peer_account_map: Dictionary = {} # peer_id -> account_id
var peer_char_data_map: Dictionary = {} # peer_id -> full char_data
var _auto_save_timer: float = 30.0

func _notification(what: int) -> void:
	if what == NOTIFICATION_PREDELETE:
		disconnect_game()
		var mk = load("res://scripts/assets/material_kit.gd")
		if mk and mk.has_method("clear_cache"):
			mk.clear_cache()

func _ready() -> void:
	# Transport and lifecycle live in SimNet now; this node keeps the public
	# surface the rest of the game (and the test harness) already calls.
	SimNet.disconnected.connect(func(_reason: String):
		is_connected_to_game = false
		emit_signal("server_disconnected_signal"))
	SimNet.joined.connect(func(ok: bool, _reason: String, _character: Dictionary):
		is_connected_to_game = ok)

## Disconnect active peer and reset state cleanly
func disconnect_game() -> void:
	if is_instance_valid(SimNet):
		SimNet.leave()
	peer = null
	is_connected_to_game = false
	is_server = false
	is_dedicated_server = false
	connected_players.clear()
	peer_account_map.clear()
	peer_char_data_map.clear()

## Start Authoritative Dedicated Server (for Linux VPS).
## The transport is SimNet's; the authority engine is what makes it authoritative.
func start_dedicated_server(port: int = DEFAULT_PORT) -> Error:
	disconnect_game()
	SimAuthority.configure(SimAuthority.Role.DEDICATED)
	var error := SimNet.host(port)
	if error != OK:
		print("[Server ERROR] Failed to bind UDP port %d: Error %d" % [port, error])
		emit_signal("connection_status_changed", "Failed to start dedicated server on port %d" % port)
		return error
	is_server = true
	is_dedicated_server = true
	is_connected_to_game = true
	print("=========================================================")
	print("[Dedicated Server] HPMMO Running on Port %d" % port)
	print("[Dedicated Server] Ready for incoming player connections!")
	print("=========================================================")
	emit_signal("connection_status_changed", "Dedicated Server active on port %d" % port)
	return OK

## Host a new game (authority + local player in this process)
func host_game(port: int = DEFAULT_PORT) -> Error:
	disconnect_game()
	SimAuthority.configure(SimAuthority.Role.HOST)
	var error := SimNet.host(port)
	if error != OK:
		emit_signal("connection_status_changed", "Failed to host on port %d" % port)
		return error
	is_server = true
	is_dedicated_server = false
	is_connected_to_game = true
	connected_players[1] = {
		"name": local_player_name,
		"house": local_player_house,
		"level": 1,
		"wand_tier": 0
	}
	emit_signal("connection_status_changed", "Server started on port %d" % port)
	return OK

## Join an existing game via IP and port. This process becomes a pure client: it
## decides nothing and asks the world server for everything.
func join_game(address: String = "213.250.145.75", port: int = DEFAULT_PORT) -> Error:
	disconnect_game()
	SimAuthority.configure(SimAuthority.Role.CLIENT)
	# The world server resolves this token through the account service; without it
	# the join is refused.
	var error := SimNet.join(address, port, DatabaseManager.session_token)
	if error != OK:
		emit_signal("connection_status_changed", "Failed to connect to %s:%d" % [address, port])
		emit_signal("connection_failed")
		return error
	is_server = false
	is_dedicated_server = false
	emit_signal("connection_status_changed", "Connecting to %s:%d..." % [address, port])
	return OK

## Start singleplayer: the same authority engine, hosted in this process, with no
## network at all. Single-player and online therefore run identical rules.
func start_offline() -> void:
	disconnect_game()
	SimAuthority.configure(SimAuthority.Role.OFFLINE)
	is_server = true
	is_dedicated_server = false
	is_connected_to_game = true
	connected_players[1] = {
		"name": local_player_name,
		"house": local_player_house,
		"level": 1,
		"wand_tier": 0
	}
	emit_signal("connection_status_changed", "Offline mode active")

func _process(_delta: float) -> void:
	pass

func _find_local_player() -> Node3D:
	if not is_inside_tree():
		return null
	var tree := get_tree()
	if not tree:
		return null
	var players := tree.get_nodes_in_group("players")
	for p in players:
		if is_instance_valid(p) and p.get("is_local_player") == true:
			return p
	return null

func send_chat(message: String) -> void:
	if message.strip_edges().is_empty():
		return
	SimNet.submit_chat(message)

## -------------------------------------------------------------------
## AUTHENTICATION & CHARACTER PERSISTENCE RPCs (PostgreSQL & SQLite)
## -------------------------------------------------------------------
