extends Node

## Persistence bridge: the world server's only path to PostgreSQL.
##
## OWNER: server repository. Clients never load this script (SimAuthority only
## attaches it in authority roles, and it is refused without a service token),
## so database credentials and the service token never leave the server process.
##
## Characters are loaded once at join and written back on a timer, on level-up
## and on disconnect, always with `base_revision` optimistic locking: if another
## process (an admin tool, a crash-recovered session) wrote first, the save is
## refused with the current revision instead of silently overwriting it.

const REQUEST_TIMEOUT_SEC := 5.0

var base_url: String = "http://127.0.0.1:8081"
var host: String = "127.0.0.1"
var port: int = 8081
var use_tls: bool = false
var service_token: String = ""
var revisions: Dictionary = {}      # character_id -> revision
var last_error: String = ""

func configure(url: String, token: String) -> void:
	base_url = url.rstrip("/")
	service_token = token

	var clean := base_url
	if clean.begins_with("https://"):
		use_tls = true
		port = 443
		clean = clean.substr(8)
	elif clean.begins_with("http://"):
		use_tls = false
		port = 80
		clean = clean.substr(7)

	var colon := clean.find(":")
	if colon != -1:
		port = int(clean.substr(colon + 1))
		host = clean.substr(0, colon)
	else:
		var slash := clean.find("/")
		if slash != -1:
			host = clean.substr(0, slash)
		else:
			host = clean

func _headers() -> PackedStringArray:
	return PackedStringArray([
		"Content-Type: application/json",
		"X-Service-Token: " + service_token,
	])

## Synchronous POST for calls that must complete before the game continues
## (join). Only used at join/disconnect, never per tick.
func _post_sync(path: String, body: Dictionary) -> Dictionary:
	var client := HTTPClient.new()
	var err := client.connect_to_host(host, port)
	if err != OK:
		last_error = "connect:%d" % err
		return {}
	var deadline := Time.get_ticks_msec() + int(REQUEST_TIMEOUT_SEC * 1000)
	while client.get_status() in [HTTPClient.STATUS_CONNECTING, HTTPClient.STATUS_RESOLVING]:
		if Time.get_ticks_msec() > deadline:
			last_error = "connect_timeout"
			return {}
		client.poll()
		OS.delay_msec(2)
	if client.get_status() != HTTPClient.STATUS_CONNECTED:
		last_error = "connect_status:%d" % client.get_status()
		return {}
	err = client.request(HTTPClient.METHOD_POST, path, _headers(), JSON.stringify(body))
	if err != OK:
		last_error = "request:%d" % err
		return {}
	while client.get_status() == HTTPClient.STATUS_REQUESTING:
		if Time.get_ticks_msec() > deadline:
			last_error = "request_timeout"
			return {}
		client.poll()
		OS.delay_msec(2)
	if not client.has_response():
		last_error = "no_response"
		return {}
	var status := client.get_response_code()
	var chunks := PackedByteArray()
	while client.get_status() == HTTPClient.STATUS_BODY:
		if Time.get_ticks_msec() > deadline:
			last_error = "body_timeout"
			return {}
		client.poll()
		var chunk := client.read_response_body_chunk()
		if chunk.size() > 0:
			chunks.append_array(chunk)
		else:
			OS.delay_msec(1)
	var parsed: Variant = JSON.parse_string(chunks.get_string_from_utf8())
	if parsed is Dictionary:
		parsed["_status"] = status
		return parsed
	last_error = "http_%d" % status
	return {"_status": status}

## Resolve a client's session token into who it is. The world server is the only
## caller, which is why this needs the service token rather than the player's.
func resolve_session(token: String) -> Dictionary:
	if token.strip_edges().is_empty():
		return {"ok": false, "reason": "no_token"}
	var response := _post_sync("/api/session/introspect", {"token": token})
	if response.is_empty() or int(response.get("_status", 0)) != 200:
		var status := int(response.get("_status", 0))
		var reason := "auth_failed"
		if status == 503:
			reason = "service_unavailable"
		return {"ok": false, "reason": reason}
	if not bool(response.get("success", false)):
		return {"ok": false, "reason": "auth_failed"}
	return {
		"ok": true,
		"account_id": int(response.get("account_id", 0)),
		"character_id": int(response.get("character_id", 0)),
		"username": String(response.get("username", "Wizard")),
		"name": String(response.get("username", "Wizard")),
		"house": "Gryffindor",
	}

func load_character(character_id: int) -> Dictionary:
	if character_id <= 0:
		return {}
	var response := _post_sync("/api/characters/load", {"character_id": character_id})
	if response.is_empty() or int(response.get("_status", 0)) != 200:
		last_error = "load_%d" % int(response.get("_status", 0))
		return {}
	var character: Variant = response.get("character", {})
	if character is Dictionary:
		revisions[character_id] = int(character.get("revision", 0))
		return character
	return {}

## Load a character and prove it belongs to `account_id` before a session may be
## bound to it (the character-bind fix). The service token authenticates this process;
## the account comparison against the sheet the service returns is the fact a
## client cannot forge, because the client never sees or sends an account id.
## Fails closed: a sheet without an account id (an older service) is refused
## rather than trusted.
func resolve_character(character_id: int, account_id: int) -> Dictionary:
	if character_id <= 0:
		return {"ok": false, "reason": "invalid_character"}
	if account_id <= 0:
		return {"ok": false, "reason": "no_account"}

	# If there is a pending dirty save and nothing is actively saving or reconciling,
	# synchronously flush it now so the arriving session reads its fresh data immediately.
	if _pending_saves.has(character_id) and not _saving.has(character_id) and not _reconciling.has(character_id):
		_flush_character_sync(character_id)

	# HTTPRequest callbacks need the main loop. Never block it waiting for them,
	# and never discard unsaved loot to allow a join against an older sheet.
	if _pending_saves.has(character_id) or _saving.has(character_id) or _reconciling.has(character_id):
		return {"ok": false, "reason": "save_pending"}

	var character := load_character(character_id)
	if character.is_empty():
		return {"ok": false, "reason": "character_not_found"}
	var owner := int(character.get("account_id", 0))
	if owner <= 0:
		return {"ok": false, "reason": "ownership_unavailable"}
	if owner != account_id:
		# Same answer for "exists but foreign" and "does not exist": a client
		# learns nothing about another account's characters.
		return {"ok": false, "reason": "character_not_found"}
	return {"ok": true, "character": character}

var _pending_saves: Dictionary = {}
var _saving: Dictionary = {}
var _reconciling: Dictionary = {}
var _save_failures: Dictionary = {}
var _retry_elapsed := 0.0

func _flush_character_sync(character_id: int) -> bool:
	if _saving.has(character_id) or _reconciling.has(character_id):
		return false
	if not _pending_saves.has(character_id):
		return true
	var body: Dictionary = _pending_saves[character_id]
	_pending_saves.erase(character_id)
	body["base_revision"] = int(revisions.get(character_id, -1))
	var response := _post_sync("/api/characters/save", body)
	var status := int(response.get("_status", 0))
	if status == 200:
		revisions[character_id] = int(response.get("revision", 0))
		_save_failures.erase(character_id)
		return true
	elif status == 409:
		_reconcile_character(character_id, body)
		return false
	last_error = "save_%d" % status
	var fails: int = int(_save_failures.get(character_id, 0)) + 1
	_save_failures[character_id] = fails
	_pending_saves[character_id] = body
	return false

func save_character(character_id: int, payload: Dictionary) -> void:
	if character_id <= 0: return
	if _reconciling.has(character_id): return
	_pending_saves[character_id] = payload.duplicate(true)
	_flush_character(character_id)

func _process(delta: float) -> void:
	_retry_elapsed += delta
	if _retry_elapsed < 5.0: return
	_retry_elapsed = 0.0
	for cid in _reconciling.keys():
		if not _saving.has(cid): _reconcile_character(int(cid), _reconciling[cid])
	for cid in _pending_saves.keys(): _flush_character(int(cid))

func pending_count() -> int:
	var dirty := _pending_saves.duplicate()
	dirty.merge(_saving, true)
	dirty.merge(_reconciling, true)
	return dirty.size()

func _flush_character(character_id: int) -> void:
	if _saving.has(character_id) or _reconciling.has(character_id) or not _pending_saves.has(character_id): return
	var body: Dictionary = _pending_saves[character_id]
	_pending_saves.erase(character_id)
	body["base_revision"] = int(revisions.get(character_id, -1))
	_saving[character_id] = true
	_post_async("/api/characters/save", body, func(response: Dictionary):
		_saving.erase(character_id)
		var status := int(response.get("_status", 0))
		if status == 200:
			_save_failures.erase(character_id)
			revisions[character_id] = int(response.get("revision", 0))
			_flush_character(character_id)
		elif status == 409:
			_save_failures.erase(character_id)
			# A concurrent writer won. Adopt its inventory; never replay a stale full bag.
			_reconcile_character(character_id, body)
		else:
			last_error = "save_%d" % status
			var fails: int = int(_save_failures.get(character_id, 0)) + 1
			_save_failures[character_id] = fails
			if not _pending_saves.has(character_id): _pending_saves[character_id] = body)

func _reconcile_character(character_id: int, rejected: Dictionary) -> void:
	_reconciling[character_id] = rejected
	_saving[character_id] = true
	var uid := int(SimAuthority.players_by_character.get(character_id, 0))
	var record: Dictionary = SimAuthority.record_by_uid(uid)
	if not record.is_empty(): record["persistence_conflict"] = true
	_post_async("/api/characters/load", {"character_id": character_id}, func(response: Dictionary):
		_saving.erase(character_id)
		if int(response.get("_status", 0)) != 200:
			var fails: int = int(_save_failures.get(character_id, 0)) + 1
			_save_failures[character_id] = fails
			return
		_save_failures.erase(character_id)
		var sheet: Dictionary = response.get("character", {})
		revisions[character_id] = int(sheet.get("revision", 0))
		_pending_saves.erase(character_id)
		_reconciling.erase(character_id)
		var node = record.get("node")
		if is_instance_valid(node):
			# Keep live location/combat HP; reconcile durable ownership and base progression.
			sheet["inventory_revision"] = maxi(int(sheet.get("inventory_revision", 0)), node.inventory_revision + 1)
			node.apply_equipment_snapshot(sheet)
			node.galleons = int(sheet.get("galleons", node.galleons))
			node.level = int(sheet.get("level", node.level))
			node.current_exp = int(sheet.get("exp", node.current_exp))
			node.max_exp = HPRules.exp_threshold(node.level)
			record["level"] = node.level
			record["exp"] = node.current_exp
			SimAuthority.refresh_equipment(record)
			SimAuthority._push_stats(record)
			node.equipment_answer.emit({"ok": false, "reason": "save_conflict", "request_id": -1})
		if not record.is_empty(): record["persistence_conflict"] = false)

## Reward through the operations ledger (exactly-once via `op_id`).
##
## NOT called by the live pickup path any more: a bound character's writes are
## owned by this bridge's saves, and applying the ledger on top credited the
## same loot twice (the character-bind fix). Kept because the service contract
## (`/api/reward`) is real and exercised by tests/integration_api.py.
func queue_reward(op_id: String, character_id: int, exp: int, galleons: int, items: Array) -> void:
	if character_id <= 0:
		return
	_post_async("/api/reward", {
		"op_id": op_id,
		"character_id": character_id,
		"exp": exp,
		"galleons": galleons,
		"items": items,
	}, func(response: Dictionary):
		if int(response.get("_status", 0)) not in [200]:
			last_error = "reward_%d" % int(response.get("_status", 0)))

func autosave_all(entities: Dictionary, players_by_peer: Dictionary) -> void:
	for peer_id in players_by_peer.keys():
		var uid: int = players_by_peer[peer_id]
		var record: Dictionary = entities.get(uid, {})
		if record.is_empty():
			continue
		var character_id := int(record.get("character_id", 0))
		if character_id <= 0:
			continue
		var node = record.get("node")
		if node == null or not is_instance_valid(node):
			continue
		save_character(character_id, character_payload(node, record))

func save_player(record: Dictionary) -> void:
	var character_id := int(record.get("character_id", 0))
	var node = record.get("node")
	if character_id <= 0 or node == null or not is_instance_valid(node):
		return
	save_character(character_id, character_payload(node, record))

## Full character state. `pos` and `inventory` are written wholesale, which is
## why the world server is the single writer of a character during its session.
## `map_id` comes from the authoritative record, never from the client: it is
## what lets a character that logged out inside the castle resume there, and
## what makes an interrupted transfer recover to a valid map on relog.
func character_payload(node: Node, record: Dictionary) -> Dictionary:
	var inventory: Array = []
	if "inventory" in node:
		for item in node.inventory:
			if item is Dictionary and item.get("id") is String:
				inventory.append({
					"id": String(item.id),
					"amount": int(item.get("amount", 1)),
					"tier": int(item.get("tier", 0)),
				})
	# JSON.parse_string turns tiers into floats. The persistence wire format
	# requires integers even when an equipped item has never been changed.
	var equipment: Dictionary = {}
	for slot in node.equipment:
		var entry: Dictionary = node.equipment[slot]
		equipment[slot] = {"id": String(entry.id), "tier": int(entry.get("tier", 0))}
	return {
		"character_id": int(record.get("character_id", 0)),
		"level": int(node.get("level")),
		"exp": int(node.get("current_exp")),
		"max_hp": int(node.get("max_hp")),
		"current_hp": int(node.get("current_hp")),
		"max_mana": int(node.get("max_mana")),
		"current_mana": int(node.get("current_mana")),
		"galleons": int(node.get("galleons")),
		"wand_tier": int(node.get("wand_tier")),
		"pos": [node.global_position.x, node.global_position.y, node.global_position.z],
		"rot_y": float(node.get("visuals").rotation.y) if node.get("visuals") != null else 0.0,
		"map_id": String(record.get("map_id", HPProtocol.DEFAULT_MAP)),
		"inventory": inventory,
		"equipment": equipment,
		"equipment_version": 1,
		"inventory_revision": node.inventory_revision,
		"base_max_hp": node.base_max_hp,
		"base_max_mana": node.base_max_mana,
	}

func _post_async(path: String, body: Dictionary, callback: Callable) -> void:
	var request := HTTPRequest.new()
	request.timeout = REQUEST_TIMEOUT_SEC
	add_child(request)
	request.request_completed.connect(func(_result: int, code: int, _headers: PackedStringArray, data: PackedByteArray):
		var parsed: Variant = JSON.parse_string(data.get_string_from_utf8())
		var response: Dictionary = parsed if parsed is Dictionary else {}
		response["_status"] = code
		request.queue_free()
		callback.call(response))
	var err := request.request(base_url + path, _headers(), HTTPClient.METHOD_POST, JSON.stringify(body))
	if err != OK:
		request.queue_free()
		callback.call({"_status": 0})
