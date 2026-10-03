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
var remote_states: Dictionary = {} # peer_id -> {pos, rot_y, mounted, hp, level}
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
	multiplayer.peer_connected.connect(_on_peer_connected)
	multiplayer.peer_disconnected.connect(_on_peer_disconnected)
	multiplayer.connected_to_server.connect(_on_connected_to_server)
	multiplayer.connection_failed.connect(_on_connection_failed)
	multiplayer.server_disconnected.connect(_on_server_disconnected)

## Disconnect active peer and reset state cleanly
func disconnect_game() -> void:
	if is_inside_tree() and multiplayer and multiplayer.has_multiplayer_peer():
		if multiplayer.multiplayer_peer:
			multiplayer.multiplayer_peer.close()
		multiplayer.multiplayer_peer = null
	peer = null
	is_connected_to_game = false
	is_server = false
	is_dedicated_server = false
	connected_players.clear()
	remote_states.clear()
	peer_account_map.clear()
	peer_char_data_map.clear()

## Start Authoritative Dedicated Server (for Linux VPS)
func start_dedicated_server(port: int = DEFAULT_PORT) -> Error:
	disconnect_game()
	peer = ENetMultiplayerPeer.new()
	var error := peer.create_server(port, MAX_PLAYERS)
	if error != OK:
		print("[Server ERROR] Failed to bind UDP port %d: Error %d" % [port, error])
		emit_signal("connection_status_changed", "Failed to start dedicated server on port %d" % port)
		return error
	
	multiplayer.multiplayer_peer = peer
	is_server = true
	is_dedicated_server = true
	is_connected_to_game = true
	print("=========================================================")
	print("[Dedicated Server] HPMMO Running on Port %d" % port)
	print("[Dedicated Server] Ready for incoming player connections!")
	print("=========================================================")
	emit_signal("connection_status_changed", "Dedicated Server active on port %d" % port)
	return OK

## Host a new game (Server + Local Player)
func host_game(port: int = DEFAULT_PORT) -> Error:
	disconnect_game()
	peer = ENetMultiplayerPeer.new()
	var error := peer.create_server(port, MAX_PLAYERS)
	if error != OK:
		emit_signal("connection_status_changed", "Failed to host on port %d" % port)
		return error
	
	multiplayer.multiplayer_peer = peer
	is_server = true
	is_dedicated_server = false
	is_connected_to_game = true
	
	var local_info := {
		"name": local_player_name,
		"house": local_player_house,
		"level": 1,
		"wand_tier": 0
	}
	connected_players[1] = local_info
	emit_signal("connection_status_changed", "Server started on port %d" % port)
	return OK

## Join an existing game via IP and port
func join_game(address: String = "213.250.145.75", port: int = DEFAULT_PORT) -> Error:
	disconnect_game()
	peer = ENetMultiplayerPeer.new()
	var error := peer.create_client(address, port)
	if error != OK:
		emit_signal("connection_status_changed", "Failed to connect to %s:%d" % [address, port])
		emit_signal("connection_failed")
		return error
		
	multiplayer.multiplayer_peer = peer
	is_server = false
	is_dedicated_server = false
	emit_signal("connection_status_changed", "Connecting to %s:%d..." % [address, port])
	return OK

## Start singleplayer / offline session
func start_offline() -> void:
	disconnect_game()
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

func _on_peer_connected(id: int) -> void:
	print("[Network] Peer connected: ID %d" % id)
	if multiplayer.is_server():
		# Sync all currently connected players to the new peer
		for p_id in connected_players:
			_sync_player_info.rpc_id(id, p_id, connected_players[p_id])

func _on_peer_disconnected(id: int) -> void:
	print("[Network] Peer disconnected: ID %d" % id)
	if multiplayer.is_server():
		if peer_char_data_map.has(id):
			_save_peer_character(id)
			peer_char_data_map.erase(id)
		# Account mapping must clear even for peers that logged in but never
		# selected a character (previously leaked).
		peer_account_map.erase(id)
	if connected_players.has(id):
		var p_info = connected_players[id]
		print("[Server] Player left: %s [%s]" % [p_info.get("name", "Wizard"), p_info.get("house", "Gryffindor")])
		connected_players.erase(id)
	remote_states.erase(id)
	emit_signal("player_disconnected_signal", id)

func _save_peer_character(peer_id: int) -> void:
	if not peer_char_data_map.has(peer_id):
		return
	var char_data: Dictionary = peer_char_data_map[peer_id]
	if remote_states.has(peer_id):
		var rs = remote_states[peer_id]
		char_data["pos"] = [rs.pos.x, rs.pos.y, rs.pos.z]
		char_data["rot_y"] = rs.rot_y
		char_data["current_hp"] = rs.hp
		char_data["level"] = rs.level
	
	DatabaseManager.save_character(char_data, func(resp):
		if resp.get("success", false):
			print("[Server DB] Auto-saved character '%s' (ID %d) to database" % [char_data.get("name", "Unknown"), char_data.get("id", 0)])
	)

func _on_connected_to_server() -> void:
	is_connected_to_game = true
	var my_id := multiplayer.get_unique_id()
	var my_info := {
		"name": local_player_name,
		"house": local_player_house,
		"level": 1,
		"wand_tier": 0
	}
	connected_players[my_id] = my_info
	emit_signal("connection_status_changed", "Connected to server as ID %d" % my_id)
	emit_signal("connection_succeeded")
	_register_my_info.rpc(my_info)

func _on_connection_failed() -> void:
	disconnect_game()
	emit_signal("connection_status_changed", "Connection failed! Check server IP & firewall.")
	emit_signal("connection_failed")

func _on_server_disconnected() -> void:
	disconnect_game()
	emit_signal("connection_status_changed", "Disconnected from server.")
	emit_signal("server_disconnected_signal")

func _process(delta: float) -> void:
	if not is_connected_to_game or not multiplayer or not multiplayer.has_multiplayer_peer():
		return
	
	# Server: Periodic auto-save to PostgreSQL / SQLite (Every 30 seconds)
	if multiplayer.is_server():
		_auto_save_timer -= delta
		if _auto_save_timer <= 0.0:
			_auto_save_timer = 30.0
			for p_id in peer_char_data_map.keys():
				_save_peer_character(p_id)
		return
	
	# Client: 15 Hz transform broadcast from local player to server
	_sync_timer -= delta
	if _sync_timer <= 0.0:
		_sync_timer = 1.0 / 15.0
		var lp := _find_local_player()
		if lp:
			rpc_broadcast_state.rpc(lp.global_position, lp.visuals.rotation.y, lp.is_mounted, lp.current_hp, lp.level)

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

## Player movement broadcast & server relay
@rpc("any_peer", "unreliable")
func rpc_broadcast_state(pos: Vector3, rot_y: float, mounted: bool, hp: int, level: int) -> void:
	var sender := multiplayer.get_remote_sender_id()
	if sender == 0:
		sender = multiplayer.get_unique_id()
	remote_states[sender] = {"pos": pos, "rot_y": rot_y, "mounted": mounted, "hp": hp, "level": level}
	
	# Server relays this player's position to all other connected peers!
	if multiplayer.is_server():
		for p_id in multiplayer.get_peers():
			if p_id != sender:
				rpc_relay_state.rpc_id(p_id, sender, pos, rot_y, mounted, hp, level)

@rpc("authority", "unreliable")
func rpc_relay_state(peer_id: int, pos: Vector3, rot_y: float, mounted: bool, hp: int, level: int) -> void:
	remote_states[peer_id] = {"pos": pos, "rot_y": rot_y, "mounted": mounted, "hp": hp, "level": level}

## Player spell broadcast & server relay
@rpc("any_peer", "reliable")
func rpc_broadcast_spell(spell_id: String, from_pos: Vector3, dir: Vector3) -> void:
	var sender := multiplayer.get_remote_sender_id()
	emit_signal("remote_spell_cast", sender, spell_id, from_pos, dir)
	if multiplayer.is_server():
		for p_id in multiplayer.get_peers():
			if p_id != sender:
				rpc_relay_spell.rpc_id(p_id, sender, spell_id, from_pos, dir)

@rpc("authority", "reliable")
func rpc_relay_spell(caster_id: int, spell_id: String, from_pos: Vector3, dir: Vector3) -> void:
	emit_signal("remote_spell_cast", caster_id, spell_id, from_pos, dir)

func broadcast_spell(spell_id: String, from_pos: Vector3, dir: Vector3) -> void:
	if multiplayer and multiplayer.has_multiplayer_peer() and is_connected_to_game and not is_server_only_offline():
		rpc_broadcast_spell.rpc(spell_id, from_pos, dir)

func is_server_only_offline() -> bool:
	return not multiplayer or not multiplayer.has_multiplayer_peer()

@rpc("any_peer", "reliable")
func _register_my_info(info: Dictionary) -> void:
	var sender_id := multiplayer.get_remote_sender_id()
	connected_players[sender_id] = info
	print("[Server] Registered player %d: %s [%s]" % [sender_id, info.get("name", "Wizard"), info.get("house", "Gryffindor")])
	emit_signal("player_connected_signal", sender_id, info)
	if multiplayer.is_server():
		_sync_player_info.rpc(sender_id, info)

@rpc("authority", "reliable")
func _sync_player_info(id: int, info: Dictionary) -> void:
	connected_players[id] = info
	emit_signal("player_connected_signal", id, info)

## Chat message replication
@rpc("any_peer", "call_local", "reliable")
func rpc_send_chat(sender_name: String, sender_house: String, message: String) -> void:
	emit_signal("chat_message_received", sender_name, sender_house, message)

func send_chat(message: String) -> void:
	if message.strip_edges().is_empty():
		return
	if multiplayer and multiplayer.has_multiplayer_peer() and is_connected_to_game:
		rpc_send_chat.rpc(local_player_name, local_player_house, message)
	else:
		emit_signal("chat_message_received", local_player_name, local_player_house, message)

## -------------------------------------------------------------------
## AUTHENTICATION & CHARACTER PERSISTENCE RPCs (PostgreSQL & SQLite)
## -------------------------------------------------------------------

func request_register(username: String, password: String) -> void:
	if multiplayer.is_server():
		DatabaseManager.register_account(username, password, func(res):
			emit_signal("auth_register_result", res.get("success", false), res.get("message", ""))
		)
	else:
		rpc_request_register.rpc_id(1, username, password)

func request_login(username: String, password: String) -> void:
	if multiplayer.is_server():
		DatabaseManager.login_account(username, password, func(res):
			var ok: bool = res.get("success", false)
			var msg: String = res.get("message", "")
			var chars: Array = res.get("characters", [])
			if ok:
				local_account_id = res.get("account_id", 0)
			emit_signal("auth_login_result", ok, msg, chars)
		)
	else:
		rpc_request_login.rpc_id(1, username, password)

func request_create_character(char_name: String, house: String) -> void:
	if multiplayer.is_server():
		DatabaseManager.create_character(local_account_id, char_name, house, func(res):
			var ok: bool = res.get("success", false)
			var msg: String = res.get("message", "")
			var c_data: Dictionary = res.get("character", {})
			emit_signal("character_create_result", ok, msg, c_data)
		)
	else:
		rpc_request_create_character.rpc_id(1, char_name, house)

func request_select_character(char_id: int) -> void:
	if multiplayer.is_server():
		DatabaseManager.load_character(char_id, func(res):
			var ok: bool = res.get("success", false)
			var c_data: Dictionary = res.get("character", {})
			if ok:
				local_character_id = char_id
				local_character_data = c_data
				local_player_name = c_data.get("name", "Wizard")
				local_player_house = c_data.get("house", "Gryffindor")
			emit_signal("character_select_result", ok, res.get("message", ""), c_data)
		)
	else:
		rpc_request_select_character.rpc_id(1, char_id)

@rpc("any_peer", "reliable")
func rpc_request_register(username: String, password: String) -> void:
	var sender_id := multiplayer.get_remote_sender_id()
	DatabaseManager.register_account(username, password, func(res):
		rpc_register_result.rpc_id(sender_id, res.get("success", false), res.get("message", ""))
	)

@rpc("authority", "reliable")
func rpc_register_result(success: bool, message: String) -> void:
	emit_signal("auth_register_result", success, message)

@rpc("any_peer", "reliable")
func rpc_request_login(username: String, password: String) -> void:
	var sender_id := multiplayer.get_remote_sender_id()
	DatabaseManager.login_account(username, password, func(res):
		var ok: bool = res.get("success", false)
		var msg: String = res.get("message", "")
		var chars: Array = res.get("characters", [])
		if ok:
			peer_account_map[sender_id] = res.get("account_id", 0)
		rpc_login_result.rpc_id(sender_id, ok, msg, chars)
	)

@rpc("authority", "reliable")
func rpc_login_result(success: bool, message: String, characters: Array) -> void:
	if success:
		print("[Network] Logged in successfully. Characters available: %d" % characters.size())
	emit_signal("auth_login_result", success, message, characters)

@rpc("any_peer", "reliable")
func rpc_request_create_character(char_name: String, house: String) -> void:
	var sender_id := multiplayer.get_remote_sender_id()
	var acc_id: int = peer_account_map.get(sender_id, 0)
	if acc_id <= 0:
		rpc_create_character_result.rpc_id(sender_id, false, "Not logged in!", {})
		return
	DatabaseManager.create_character(acc_id, char_name, house, func(res):
		var ok: bool = res.get("success", false)
		var msg: String = res.get("message", "")
		var c_data: Dictionary = res.get("character", {})
		rpc_create_character_result.rpc_id(sender_id, ok, msg, c_data)
	)

@rpc("authority", "reliable")
func rpc_create_character_result(success: bool, message: String, char_data: Dictionary) -> void:
	emit_signal("character_create_result", success, message, char_data)

@rpc("any_peer", "reliable")
func rpc_request_select_character(char_id: int) -> void:
	var sender_id := multiplayer.get_remote_sender_id()
	DatabaseManager.load_character(char_id, func(res):
		var ok: bool = res.get("success", false)
		var msg: String = res.get("message", "")
		var c_data: Dictionary = res.get("character", {})
		if ok:
			peer_char_data_map[sender_id] = c_data
			var p_info := {
				"name": c_data.get("name", "Wizard"),
				"house": c_data.get("house", "Gryffindor"),
				"level": c_data.get("level", 1),
				"wand_tier": c_data.get("wand_tier", 0),
				"char_id": char_id
			}
			connected_players[sender_id] = p_info
			_sync_player_info.rpc(sender_id, p_info)
		rpc_character_select_result.rpc_id(sender_id, ok, msg, c_data)
	)

@rpc("authority", "reliable")
func rpc_character_select_result(success: bool, message: String, char_data: Dictionary) -> void:
	if success:
		local_character_id = char_data.get("id", 0)
		local_character_data = char_data
		local_player_name = char_data.get("name", "Wizard")
		local_player_house = char_data.get("house", "Gryffindor")
		print("[Network] Character loaded from DB: %s [%s] Level %d" % [local_player_name, local_player_house, char_data.get("level", 1)])
	emit_signal("character_select_result", success, message, char_data)
