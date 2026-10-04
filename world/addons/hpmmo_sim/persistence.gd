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

func save_character(character_id: int, payload: Dictionary) -> void:
	if character_id <= 0:
		return
	var body := payload.duplicate(true)
	if revisions.has(character_id):
		body["base_revision"] = int(revisions[character_id])
	# Fire-and-forget: a failed save is reported and retried on the next tick of
	# the autosave timer rather than stalling the simulation.
	_post_async("/api/characters/save", body, func(response: Dictionary):
		var status := int(response.get("_status", 0))
		if status == 200:
			revisions[character_id] = int(response.get("revision", revisions.get(character_id, 0)))
		elif status == 409:
			# Someone else wrote first: adopt their revision and try again later.
			revisions[character_id] = int(response.get("revision", revisions.get(character_id, 0)))
			push_warning("[Persistence] stale revision for character %d; resynced" % character_id)
		else:
			last_error = "save_%d" % status)

## Exactly-once reward for things that must survive a crash (loot pickups),
## through the Phase 4 operations ledger.
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
