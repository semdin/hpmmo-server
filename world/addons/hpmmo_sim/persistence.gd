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

## Requests run on their own thread (`use_threads`): on the main loop an
## HTTPRequest only advances once per frame, and the frames right after boot
## (thousands of creatures spawning) are long enough that three of them - connect,
## send, read - outlasted a 5 s timeout, so the first join after a restart
## (the deploy's own login check) was refused. The timeout is generous for the
## same reason: it is counted in frame time.
const REQUEST_TIMEOUT_SEC := 15.0

static func _new_request() -> HTTPRequest:
	var request := HTTPRequest.new()
	request.use_threads = true
	request.timeout = REQUEST_TIMEOUT_SEC
	return request

static func _parse_body(data: PackedByteArray) -> Dictionary:
	if data.is_empty():
		return {}
	var parsed: Variant = JSON.parse_string(data.get_string_from_utf8())
	return parsed if parsed is Dictionary else {}

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

## How long an arriving session waits for the last save of its character (a
## relog a moment after leaving) to land before the join is refused.
const SAVE_SETTLE_TIMEOUT_MS := 6000

## One POST through an HTTPRequest, awaited: the caller is a coroutine, and the
## main loop - every player's tick and the ENet service - keeps running while
## the account service answers. The synchronous HTTPClient loop this replaced
## froze the whole world for the round trip at every join, bind and logout
## (up to 5 s per request when the service or the database was slow).
func _post_await(path: String, body: Dictionary) -> Dictionary:
	var request := _new_request()
	add_child(request)
	var err := request.request(base_url + path, _headers(), HTTPClient.METHOD_POST, JSON.stringify(body))
	if err != OK:
		request.queue_free()
		last_error = "request:%d" % err
		return {"_status": 0}
	var answer: Array = await request.request_completed
	request.queue_free()
	if int(answer[0]) != HTTPRequest.RESULT_SUCCESS:
		last_error = "%s: result %d" % [path, int(answer[0])]
		print("[Persistence] %s failed (HTTPRequest result %d)" % [path, int(answer[0])])
	var response := _parse_body(answer[3])
	response["_status"] = int(answer[1])
	return response

## Resolve a client's session token into who it is. The world server is the only
## caller, which is why this needs the service token rather than the player's.
## A coroutine: `await` it.
func resolve_session(token: String) -> Dictionary:
	if token.strip_edges().is_empty():
		return {"ok": false, "reason": "no_token"}
	var response: Dictionary = await _post_await("/api/session/introspect", {"token": token})
	if int(response.get("_status", 0)) != 200:
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

## A coroutine: `await` it.
func load_character(character_id: int) -> Dictionary:
	if character_id <= 0:
		return {}
	var response: Dictionary = await _post_await("/api/characters/load", {"character_id": character_id})
	if int(response.get("_status", 0)) != 200:
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
## rather than trusted. A coroutine: `await` it.
func resolve_character(character_id: int, account_id: int) -> Dictionary:
	if character_id <= 0:
		return {"ok": false, "reason": "invalid_character"}
	if account_id <= 0:
		return {"ok": false, "reason": "no_account"}

	# A save of this character still on its way (the player's last session, a
	# takeover a moment ago) lands first, so the new session reads the fresh
	# sheet. Never load past unsaved loot; past the deadline the join is refused.
	if _pending_saves.has(character_id) and not _saving.has(character_id) and not _reconciling.has(character_id):
		_flush_character(character_id)
	var deadline := Time.get_ticks_msec() + SAVE_SETTLE_TIMEOUT_MS
	while _pending_saves.has(character_id) or _saving.has(character_id) or _reconciling.has(character_id):
		if Time.get_ticks_msec() > deadline:
			return {"ok": false, "reason": "save_pending"}
		await get_tree().create_timer(0.05).timeout

	var character: Dictionary = await load_character(character_id)
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

## A save that is not urgent waits this long, so a burst of changes (every
## kill moves a quest, every chest take changes the bag) becomes one write of
## the latest sheet instead of one full-inventory rewrite per event.
const SAVE_DEBOUNCE_MS := 5000
## The periodic autosave spreads its characters over this window instead of
## sending every save in the same frame.
const AUTOSAVE_SPREAD_MS := 20000

var _due: Dictionary = {}           # character_id -> ticks_msec the queued save goes out
var _due_check_elapsed := 0.0

## Queue `payload` as the character's next write. It goes out `delay_ms` from
## now (0 = at once); a later call replaces the queued sheet but never pushes
## an earlier due time back, so no change waits longer than its first delay.
func save_character(character_id: int, payload: Dictionary, delay_ms: int = SAVE_DEBOUNCE_MS) -> void:
	if character_id <= 0: return
	if _reconciling.has(character_id): return
	_pending_saves[character_id] = payload.duplicate(true)
	var due := Time.get_ticks_msec() + maxi(0, delay_ms)
	if not _due.has(character_id) or due < int(_due[character_id]):
		_due[character_id] = due
	if delay_ms <= 0:
		_flush_character(character_id)

func _process(delta: float) -> void:
	_due_check_elapsed += delta
	if _due_check_elapsed >= 0.25:
		_due_check_elapsed = 0.0
		var now := Time.get_ticks_msec()
		for cid in _due.keys():
			if int(_due[cid]) <= now:
				_flush_character(int(cid))
	_retry_elapsed += delta
	if _retry_elapsed < 5.0: return
	_retry_elapsed = 0.0
	for cid in _reconciling.keys():
		if not _saving.has(cid): _reconcile_character(int(cid), _reconciling[cid])

func pending_count() -> int:
	var dirty := _pending_saves.duplicate()
	dirty.merge(_saving, true)
	dirty.merge(_reconciling, true)
	return dirty.size()

func _flush_character(character_id: int) -> void:
	if _saving.has(character_id) or _reconciling.has(character_id) or not _pending_saves.has(character_id): return
	var body: Dictionary = _pending_saves[character_id]
	_pending_saves.erase(character_id)
	_due.erase(character_id)
	body["base_revision"] = int(revisions.get(character_id, -1))
	_saving[character_id] = true
	_post_async("/api/characters/save", body, func(response: Dictionary):
		_saving.erase(character_id)
		var status := int(response.get("_status", 0))
		if status == 200:
			_save_failures.erase(character_id)
			revisions[character_id] = int(response.get("revision", 0))
			# A sheet queued while this one was in flight goes out on its own
			# due time (_process), not straight away: a fight would otherwise
			# write back to back.
		elif status == 409:
			_save_failures.erase(character_id)
			# A concurrent writer won. Adopt its inventory; never replay a stale full bag.
			_reconcile_character(character_id, body)
		else:
			last_error = "save_%d" % status
			var fails: int = int(_save_failures.get(character_id, 0)) + 1
			_save_failures[character_id] = fails
			if not _pending_saves.has(character_id): _pending_saves[character_id] = body
			if not _due.has(character_id): _due[character_id] = Time.get_ticks_msec() + 5000)

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
		_due.erase(character_id)
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
			if node.has_method("restore_quest_state"):
				node.restore_quest_state(sheet.get("quests", {}))
				record["house_rep"] = node.house_rep
				SimAuthority._load_quest_state(record, node)
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

## A full clear for the weekly leaderboard (`/api/dungeon/run`); `on_rank`
## gets the run's place this week (0 when the service could not say).
func record_dungeon_run(run: Dictionary, on_rank: Callable) -> void:
	_post_async("/api/dungeon/run", run, func(response: Dictionary):
		if int(response.get("_status", 0)) != 200:
			last_error = "dungeon_run_%d" % int(response.get("_status", 0))
		on_rank.call(int(response.get("rank", 0))))

## This week's fastest runs of a dungeon on a difficulty (`/api/dungeon/board`).
func dungeon_board(dungeon: String, difficulty: String, week: int, on_runs: Callable) -> void:
	_post_async("/api/dungeon/board", {"dungeon": dungeon, "difficulty": difficulty, "week": week, "limit": 10},
		func(response: Dictionary):
			on_runs.call(response.get("runs", []) if int(response.get("_status", 0)) == 200 else null))

func autosave_all(entities: Dictionary, players_by_peer: Dictionary) -> void:
	var spread := float(AUTOSAVE_SPREAD_MS) / float(maxi(1, players_by_peer.size()))
	var index := 0
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
		save_character(character_id, character_payload(node, record), int(spread * index))
		index += 1

func save_player(record: Dictionary) -> void:
	var character_id := int(record.get("character_id", 0))
	var node = record.get("node")
	if character_id <= 0 or node == null or not is_instance_valid(node):
		return
	save_character(character_id, character_payload(node, record))

## The last save of a session that is ending (logout, change character, takeover),
## sent at once instead of waiting for the autosave. It never blocks the main
## loop: the next session of the same character (often the same player a
## second later) waits for it to land in `resolve_character`.
func save_player_now(record: Dictionary) -> void:
	var character_id := int(record.get("character_id", 0))
	var node = record.get("node")
	if character_id <= 0 or node == null or not is_instance_valid(node):
		return
	if _reconciling.has(character_id):
		return
	save_character(character_id, character_payload(node, record), 0)

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
				var line := {
					"id": String(item.id),
					"amount": int(item.get("amount", 1)),
					"tier": int(item.get("tier", 0)),
				}
				# An instance carries its identity and bonuses; a stack has neither.
				if int(item.get("uid", 0)) > 0:
					line["uid"] = int(item.uid)
					line["bonuses"] = (item.get("bonuses", []) as Array).duplicate(true)
				inventory.append(line)
	# JSON.parse_string turns tiers into floats. The persistence wire format
	# requires integers even when an equipped item has never been changed.
	var equipment: Dictionary = {}
	for slot in node.equipment:
		var entry: Dictionary = node.equipment[slot]
		equipment[slot] = {"id": String(entry.id), "tier": int(entry.get("tier", 0)),
			"uid": int(entry.get("uid", 0)), "bonuses": (entry.get("bonuses", []) as Array).duplicate(true)}
	var payload := {
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
	# The `quests` column is a free JSON object; house standing lives in it so
	# the progression needs no schema change. Left out (the service keeps the
	# stored value) rather than sent empty when the body cannot produce it.
	if node.has_method("persisted_quests"):
		payload["quests"] = node.persisted_quests()
	return payload

func _post_async(path: String, body: Dictionary, callback: Callable) -> void:
	var request := _new_request()
	add_child(request)
	request.request_completed.connect(func(_result: int, code: int, _headers: PackedStringArray, data: PackedByteArray):
		var response := _parse_body(data)
		response["_status"] = code
		request.queue_free()
		callback.call(response))
	var err := request.request(base_url + path, _headers(), HTTPClient.METHOD_POST, JSON.stringify(body))
	if err != OK:
		request.queue_free()
		callback.call({"_status": 0})
