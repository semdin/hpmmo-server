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
## The world server answered a character-binding request (the character-bind fix).
signal character_bind_result(success: bool, message: String, character: Dictionary)

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

## The character the player picked in the selection UI (the character-bind fix). The
## world session is bound to it on the server; holding the id here is what lets
## a reconnect re-bind the same character without asking the player again.
var selected_character_id: int = 0
## True once the server confirmed the session is bound to selected_character_id.
var character_bound: bool = false

func _notification(what: int) -> void:
	if what == NOTIFICATION_PREDELETE:
		disconnect_game()
		var mk = load("res://scripts/assets/material_kit.gd")
		if mk and mk.has_method("clear_cache"):
			mk.clear_cache()

func _ready() -> void:
	# Transport and lifecycle live in SimNet now; this node keeps the public
	# surface the rest of the game (and the test harness) already calls.
	if is_instance_valid(SimNet):
		SimNet.disconnected.connect(func(_reason: String):
			is_connected_to_game = false
			emit_signal("server_disconnected_signal"))
		SimNet.character_bound.connect(_on_character_bound)
		SimNet.joined.connect(func(ok: bool, _reason: String, character: Dictionary):
			is_connected_to_game = ok
			if not ok:
				return
			if not character.is_empty() and int(character.get("id", 0)) > 0:
				# The session itself carried the character (a ticket redeemed
				# with one): the server already bound it, so the client is bound
				# too, without another exchange.
				selected_character_id = int(character["id"])
				character_bound = true
			elif selected_character_id > 0:
				# A reconnect: the new session must be bound again, or the
				# character's progress would stop being saved.
				call_deferred("_rebind_selected_character"))

## The player chose a character in the selection UI. The server has not bound it
## yet - `bind_selected_character` asks, and the server validates ownership.
func select_character(data: Dictionary) -> void:
	local_character_data = data
	local_player_name = String(data.get("name", "Wizard"))
	local_player_house = String(data.get("house", "Gryffindor"))
	selected_character_id = int(data.get("id", 0))
	character_bound = false

## Ask the world server to bind this session to the selected character (Release gates
## character-bind). The server proves the character belongs to this session's account
## through the account service before it binds; a foreign character is refused
## and the session stays unbound, so the refusal is returned rather than papered
## over. Safe to await from UI code; bounded so a lost answer cannot hang a menu.
func bind_selected_character(timeout: float = 6.0) -> Dictionary:
	if selected_character_id <= 0:
		return {"ok": false, "reason": "no_character_selected", "character": {}}
	if not is_instance_valid(SimNet) or not SimNet.joined_world:
		return {"ok": false, "reason": "not_joined", "character": {}}
	var answer: Array = []
	SimNet.character_bound.connect(func(ok: bool, reason: String, character: Dictionary):
		answer.append({"ok": ok, "reason": reason, "character": character}), CONNECT_ONE_SHOT)
	SimNet.bind_character(selected_character_id)
	var waited := 0.0
	while answer.is_empty() and waited < timeout:
		await get_tree().create_timer(0.1).timeout
		waited += 0.1
	if answer.is_empty():
		return {"ok": false, "reason": "timeout", "character": {}}
	return answer[0]

func _on_character_bound(ok: bool, reason: String, character: Dictionary) -> void:
	if ok:
		character_bound = true
		if not character.is_empty():
			# The service's sheet (not the list row) is the authority: keep it.
			local_character_data = character
			local_player_name = String(character.get("name", local_player_name))
			local_player_house = String(character.get("house", local_player_house))
			selected_character_id = int(character.get("id", selected_character_id))
	character_bind_result.emit(ok, reason, character)

func _rebind_selected_character() -> void:
	var result := await bind_selected_character()
	if not bool(result.get("ok", false)):
		push_warning("[Network] reconnect could not re-bind character %d (%s)" % [
			selected_character_id, str(result.get("reason", ""))])

## Disconnect active peer and reset state cleanly
func disconnect_game() -> void:
	if is_instance_valid(SimNet):
		SimNet.leave()
	peer = null
	is_connected_to_game = false
	is_server = false
	is_dedicated_server = false
	character_bound = false
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
