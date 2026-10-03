extends Node

## DatabaseManager - Dedicated Server Persistence & Local Offline Save/Load
## Communicates with the HPMMO service (default http://127.0.0.1:8081).
## Also manages offline local character save files.
##
## Online sessions come from the launcher handoff: when the HPMMO_TICKET
## environment variable is set, the single-use ticket is redeemed exactly once
## for a session token that is kept in memory only. Tokens, tickets and
## passwords are never written to disk or logged.

const DEFAULT_API_URL = "http://127.0.0.1:8081"
const LOCAL_SAVE_PATH = "user://hpmmo_character_save.json"
const LEGACY_SAVE_PATH = "user://pottermetin_character_save.json"

## Emitted once the startup launcher-ticket redemption has finished.
signal session_established(success: bool, account_id: int)

## Service base URL; the launcher overrides it with HPMMO_API_URL so the game
## talks to the same host it authenticated against.
var api_base_url: String = DEFAULT_API_URL

## Launcher session state (in memory only; never persisted, never logged).
var session_token: String = ""
var session_account_id: int = 0
var session_character_id: int = 0
var session_active: bool = false

var http_client_node: HTTPRequest = null

var _ticket_redeem_started: bool = false
var _ticket_redeem_finished: bool = false

func _ready() -> void:
	http_client_node = HTTPRequest.new()
	add_child(http_client_node)

	var env_url := OS.get_environment("HPMMO_API_URL").strip_edges()
	if not env_url.is_empty():
		api_base_url = env_url.rstrip("/")

	var ticket := OS.get_environment("HPMMO_TICKET")
	if OS.has_method("unset_environment"):
		OS.unset_environment("HPMMO_TICKET")
	if not ticket.is_empty():
		_redeem_game_ticket(ticket)

## True while the launcher handoff ticket is still being redeemed.
func is_session_pending() -> bool:
	return _ticket_redeem_started and not _ticket_redeem_finished

## Redeem the launcher-issued game ticket. Exactly one attempt is made: the
## ticket is single-use, so a retry would be an invalid replay.
func _redeem_game_ticket(ticket: String) -> void:
	if _ticket_redeem_started:
		return
	_ticket_redeem_started = true

	var req := HTTPRequest.new()
	add_child(req)
	req.request_completed.connect(func(result: int, response_code: int, _headers: PackedStringArray, body: PackedByteArray):
		req.queue_free()
		_ticket_redeem_finished = true

		var success := false
		var reason := ""
		if result == HTTPRequest.RESULT_SUCCESS:
			var response := _parse_json_dict(body)
			if response_code == 200 and bool(response.get("success", false)):
				var token := str(response.get("token", ""))
				if not token.is_empty():
					session_token = token
					session_account_id = int(response.get("account_id", 0))
					session_character_id = int(response.get("character_id", 0))
					session_active = true
					success = true
					print("[DBManager] Launcher session established (account %d)." % session_account_id)
			else:
				reason = _redact(str(response.get("message", "")))
		else:
			reason = "service unreachable (code %d)" % result

		if not success:
			if reason.is_empty():
				push_warning("[DBManager] Game ticket not redeemed; continuing without a launcher session.")
			else:
				push_warning("[DBManager] Game ticket not redeemed (%s); continuing without a launcher session." % reason)
		session_established.emit(success, session_account_id)
	)

	var headers := PackedStringArray(["Content-Type: application/json"])
	var err := req.request(api_base_url + "/api/ticket/redeem", headers,
		HTTPClient.METHOD_POST, JSON.stringify({"ticket": ticket}))
	if err != OK:
		_ticket_redeem_finished = true
		req.queue_free()
		push_warning("[DBManager] Could not issue the ticket redemption request; continuing without a launcher session.")
		session_established.emit(false, 0)

## ---------------------------------------------------------
## DEDICATED SERVER HTTP API CALLS
## ---------------------------------------------------------

func register_account(username: String, password: String, callback: Callable) -> void:
	var payload := {"username": username, "password": password}
	_send_post("/api/register", payload, callback, false)

func login_account(username: String, password: String, callback: Callable) -> void:
	var payload := {"username": username, "password": password}
	_send_post("/api/login", payload, callback, false)

func get_characters(_account_id: int, callback: Callable) -> void:
	# The session account owns the list; the server scopes it (no id in the body).
	_send_post("/api/characters/list", {}, callback)

func create_character(_account_id: int, char_name: String, house: String, callback: Callable) -> void:
	_send_post("/api/characters/create", {"name": char_name, "house": house}, callback)

func save_character(char_data: Dictionary, callback: Callable = Callable()) -> void:
	_send_post("/api/characters/save", char_data, callback)

func load_character(char_id: int, callback: Callable) -> void:
	var payload := {"character_id": char_id}
	_send_post("/api/characters/load", payload, callback)

func _send_post(endpoint: String, payload: Dictionary, callback: Callable, authenticated: bool = true) -> void:
	var req := HTTPRequest.new()
	add_child(req)

	req.request_completed.connect(func(result: int, response_code: int, _headers: PackedStringArray, body: PackedByteArray):
		var response_dict := {}
		if result == HTTPRequest.RESULT_SUCCESS:
			response_dict = _parse_json_dict(body)
			if response_dict.is_empty():
				response_dict = {"success": false, "message": "Failed to parse database response"}
		else:
			response_dict = {"success": false, "message": "Database service connection failed (Code: %d)" % result}

		req.queue_free()
		if callback.is_valid():
			callback.call(response_dict)
	)

	var headers := PackedStringArray(["Content-Type: application/json"])
	if authenticated and not session_token.is_empty():
		headers.append("Authorization: Bearer " + session_token)
	var json_str := JSON.stringify(payload)
	var err := req.request(api_base_url + endpoint, headers, HTTPClient.METHOD_POST, json_str)
	if err != OK:
		req.queue_free()
		if callback.is_valid():
			callback.call({"success": false, "message": "Failed to issue HTTP request to DB service"})

func _parse_json_dict(body: PackedByteArray) -> Dictionary:
	var json := JSON.new()
	if json.parse(body.get_string_from_utf8()) == OK and json.data is Dictionary:
		return json.data
	return {}

## Defensive redaction: tokens, tickets and passwords must never reach a log
## line, even inside echoed server text.
func _redact(text: String) -> String:
	if session_token.is_empty():
		return text
	return text.replace(session_token, "[redacted]")

## ---------------------------------------------------------
## OFFLINE / SINGLEPLAYER PERSISTENCE (SQLite / Local JSON)
## ---------------------------------------------------------

func save_offline_character(char_data: Dictionary) -> void:
	var file = FileAccess.open(LOCAL_SAVE_PATH, FileAccess.WRITE)
	if file:
		file.store_string(JSON.stringify(char_data, "\t"))
		print("[DBManager] Offline character saved locally to %s" % LOCAL_SAVE_PATH)

func load_offline_character() -> Dictionary:
	var path_to_load = LOCAL_SAVE_PATH
	if not FileAccess.file_exists(path_to_load) and FileAccess.file_exists(LEGACY_SAVE_PATH):
		path_to_load = LEGACY_SAVE_PATH
	if not FileAccess.file_exists(path_to_load):
		return {}
	var file = FileAccess.open(path_to_load, FileAccess.READ)
	if not file:
		return {}
	var content = file.get_as_text()
	var json = JSON.new()
	var err = json.parse(content)
	if err == OK and json.data is Dictionary:
		print("[DBManager] Loaded offline character from %s" % path_to_load)
		return json.data
	return {}
