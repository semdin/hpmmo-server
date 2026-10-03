extends Node

## DatabaseManager - Dedicated Server Persistence & Local Offline Save/Load
## Communicates with Server DB Microservice (127.0.0.1:8081) backed by PostgreSQL/SQLite.
## Also manages offline local character save files.

const DB_API_URL = "http://127.0.0.1:8081"
const LOCAL_SAVE_PATH = "user://hpmmo_character_save.json"
const LEGACY_SAVE_PATH = "user://pottermetin_character_save.json"

var http_client_node: HTTPRequest = null

func _ready() -> void:
	http_client_node = HTTPRequest.new()
	add_child(http_client_node)

## ---------------------------------------------------------
## DEDICATED SERVER HTTP API CALLS
## ---------------------------------------------------------

func register_account(username: String, password: String, callback: Callable) -> void:
	var payload := {"username": username, "password": password}
	_send_post("/api/register", payload, callback)

func login_account(username: String, password: String, callback: Callable) -> void:
	var payload := {"username": username, "password": password}
	_send_post("/api/login", payload, callback)

func get_characters(account_id: int, callback: Callable) -> void:
	var payload := {"account_id": account_id}
	_send_post("/api/characters/list", payload, callback)

func create_character(account_id: int, char_name: String, house: String, callback: Callable) -> void:
	var payload := {"account_id": account_id, "name": char_name, "house": house}
	_send_post("/api/characters/create", payload, callback)

func save_character(char_data: Dictionary, callback: Callable = Callable()) -> void:
	_send_post("/api/characters/save", char_data, callback)

func load_character(char_id: int, callback: Callable) -> void:
	var payload := {"character_id": char_id}
	_send_post("/api/characters/load", payload, callback)

func _send_post(endpoint: String, payload: Dictionary, callback: Callable) -> void:
	var req := HTTPRequest.new()
	add_child(req)
	
	req.request_completed.connect(func(result: int, response_code: int, _headers: PackedStringArray, body: PackedByteArray):
		var response_dict := {}
		if result == HTTPRequest.RESULT_SUCCESS:
			var json = JSON.new()
			var parse_err = json.parse(body.get_string_from_utf8())
			if parse_err == OK and json.data is Dictionary:
				response_dict = json.data
			else:
				response_dict = {"success": false, "message": "Failed to parse database response"}
		else:
			response_dict = {"success": false, "message": "Database service connection failed (Code: %d)" % result}
		
		req.queue_free()
		if callback.is_valid():
			callback.call(response_dict)
	)
	
	var json_str := JSON.stringify(payload)
	var headers := PackedStringArray(["Content-Type: application/json"])
	var err := req.request(DB_API_URL + endpoint, headers, HTTPClient.METHOD_POST, json_str)
	if err != OK:
		req.queue_free()
		if callback.is_valid():
			callback.call({"success": false, "message": "Failed to issue HTTP request to DB service"})

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
