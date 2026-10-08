extends Node

## Synthetic login + join check (VERIFYING step).
##
## The deployment controller runs this against a freshly started release and
## refuses to advertise it ONLINE unless this exits 0. It is the difference
## between "the process started" and "a player can actually get in": it logs in
## through the account service, redeems a game ticket, joins the world server
## with the resulting session and waits for replicated state.
##
## Shipped as a SCENE (`smoke_client.tscn`), not as a `--script`: Godot does not
## create autoloads for a bare script main loop, and the transport lives in an
## autoload. The script is deliberately not named `smoke_client.gd`, because
## deploy/smoke_client.sh prefers a script at exactly that path and would then
## run it in a mode where the autoloads are missing.
##
## Persistence scenario (the character-bind fix), enabled with HPMMO_SMOKE_PERSIST=1.
## The plain check above joins with an unbound session - exactly the launcher
## shape - and stops there, which is how the "characters are never saved" bug
## stayed invisible. This mode plays the whole promise out:
##
##   log in -> pick/create a character -> redeem an UNBOUND ticket -> join ->
##   the client NAMES its character (`SimNet.bind_character`, the same
##   exchange the character-select UI drives) -> the server proves ownership
##   through the account service and binds the session -> fight a pack, take a
##   kill reward (experience) and a piece of dropped loot -> disconnect.
##
## It prints `SMOKE PERSIST OK character=<id> exp=<n> galleons=<n> pos=x,y,z
## map=<id>`; the driver then reloads the character through the service and
## asserts the numbers came back, and runs `HPMMO_SMOKE_RELOAD=1` (a ticket
## redeemed WITH the character id, so the join itself carries the sheet) and
## `HPMMO_SMOKE_FOREIGN=<id of another account's character>` (which the server
## must refuse) as the two controls.
##
## Environment (credentials are never printed):
##   HPMMO_SMOKE_USER, HPMMO_SMOKE_PASSWORD   required
##   HPMMO_SMOKE_API_URL                      default: HPMMO_API_URL or 127.0.0.1:8081
##   HPMMO_SMOKE_WORLD_HOST / _PORT           default: 127.0.0.1 / HPMMO_WORLD_PORT or 7777
##   HPMMO_SMOKE_TIMEOUT                      seconds, default 60
##   HPMMO_SMOKE_PERSIST=1                    run the persistence scenario
##   HPMMO_SMOKE_RELOAD=1                     bind-at-join control (ticket carries
##                                            the character id); HPMMO_SMOKE_EXPECT_EXP
##                                            must be <= the sheet the join returns
##   HPMMO_SMOKE_FOREIGN=<character id>       bind-refusal control
##
## Exit: 0 pass, 1 fail (with a one-line diagnosis on stdout).

var api_url := ""
var world_host := "127.0.0.1"
var world_port := 7777
var username := ""
var password := ""
var deadline_ms := 0
var session_token := ""
var joined := false
var local_uid := 0
var failing_step := "startup"
var failure := ""
var _http: HTTPRequest = null

## Persistence scenario state (the character-bind fix).
var account_token := ""
var mode := "join"              # join | persist | reload | foreign
var foreign_id := 0
var expected_exp := -1
var character_id := 0
var character: Dictionary = {}
var _phase := "boot"
var _phase_deadline_ms := 0
var _bound_exp := -1
var _kills := 0
var _kill_exp := 0
var _loot_taken := 0
var _loot_events: Array = []
var _fight_started_ms := 0
var _last_move_check_ms := 0
var _last_move_pos := Vector3.ZERO
var _sidestep_until := 0
var _last_cast_ms := 0
var _cast_seq := 0
var _target_uid := 0
var _record_report := 0
var _loot_ground: Dictionary = {}   # loot uid -> {pos, item, amount} (event-driven)
var _state_at_disconnect: Dictionary = {}

func _ready() -> void:
	api_url = _env_any(["HPMMO_SMOKE_API_URL", "HPMMO_API_URL"], "http://127.0.0.1:8081").rstrip("/")
	world_host = _env("HPMMO_SMOKE_WORLD_HOST", "127.0.0.1")
	world_port = int(_env("HPMMO_SMOKE_WORLD_PORT", _env_any(["HPMMO_WORLD_PORT"], "7777")))
	username = _env("HPMMO_SMOKE_USER", "")
	password = _env("HPMMO_SMOKE_PASSWORD", "")
	deadline_ms = Time.get_ticks_msec() + int(_env("HPMMO_SMOKE_TIMEOUT", "60")) * 1000
	if _env("HPMMO_SMOKE_PERSIST", "") == "1":
		mode = "persist"
	elif _env("HPMMO_SMOKE_RELOAD", "") == "1":
		mode = "reload"
		expected_exp = int(_env("HPMMO_SMOKE_EXPECT_EXP", "-1"))
	elif _env("HPMMO_SMOKE_FOREIGN", "") != "":
		mode = "foreign"
		foreign_id = int(_env("HPMMO_SMOKE_FOREIGN", "0"))
	_http = HTTPRequest.new()
	_http.timeout = 10.0
	add_child(_http)
	SimNet.character_bound.connect(_on_character_bound)
	SimAuthority.reward_granted.connect(_on_reward)
	# Ground loot travels as spawn/despawn events, not as snapshot replicas:
	# track it where the events arrive.
	SimAuthority.loot_spawned.connect(func(uid: int, item_id: String, amount: int, pos: Vector3):
		_loot_ground[int(uid)] = {"pos": pos, "item": item_id, "amount": amount})
	SimAuthority.entity_despawned.connect(func(uid: int): _loot_ground.erase(int(uid)))
	print("[smoke] api=%s world=%s:%d user=%s mode=%s" % [api_url, world_host, world_port,
		username if username != "" else "(unset)", mode])
	_run.call_deferred()

func _env(name: String, fallback: String) -> String:
	var value := OS.get_environment(name)
	return value if value != "" else fallback

func _env_any(names: Array, fallback: String) -> String:
	for name in names:
		var value := OS.get_environment(String(name))
		if value != "":
			return value
	return fallback

func _policy() -> int:
	return HTTPClient.METHOD_POST

## One POST, awaited. Returns {status:int, body:Dictionary}. Never logs the body
## of an auth call, because it carries the session token.
func _post(path: String, body: Dictionary, bearer: String = "") -> Dictionary:
	var headers := PackedStringArray(["Content-Type: application/json"])
	if bearer != "":
		headers.append("Authorization: Bearer " + bearer)
	var err := _http.request(api_url + path, headers, _policy(), JSON.stringify(body))
	if err != OK:
		return {"status": 0, "error": "request_error_%d" % err}
	var result: Array = await _http.request_completed
	var code := int(result[1])
	var parsed: Variant = JSON.parse_string((result[3] as PackedByteArray).get_string_from_utf8())
	return {"status": code, "body": parsed if parsed is Dictionary else {}}

func _fail(step: String, detail: String) -> void:
	print("[smoke] SMOKE FAIL: %s: %s" % [step, detail])
	get_tree().quit(1)

func _run() -> void:
	if username == "" or password == "":
		_fail("config", "HPMMO_SMOKE_USER / HPMMO_SMOKE_PASSWORD are not set")
		return

	# 1. log in (registering first if this box has no such account yet, so the
	#    check also works against a fresh database).
	failing_step = "login"
	var login := await _post("/api/login", {"username": username, "password": password})
	if login["status"] == 401:
		failing_step = "register"
		var created := await _post("/api/register", {"username": username, "password": password})
		if created["status"] != 200:
			_fail("register", "HTTP %d" % created["status"])
			return
		failing_step = "login"
		login = await _post("/api/login", {"username": username, "password": password})
	if login["status"] != 200:
		_fail("login", "HTTP %d" % login["status"])
		return
	account_token = String(login["body"].get("token", ""))
	if account_token == "":
		_fail("login", "no session token in the response")
		return
	print("[smoke] logged in (account %s)" % str(login["body"].get("account_id", "?")))

	# 2. persistence runs: the character this session will play. The account's
	#    first character, created here if the account has none.
	if mode == "persist" or mode == "reload":
		failing_step = "characters"
		var listed := await _post("/api/characters/list", {}, account_token)
		if listed["status"] != 200:
			_fail("characters", "HTTP %d" % listed["status"])
			return
		var characters: Array = (listed["body"] as Dictionary).get("characters", [])
		if characters.is_empty() and mode == "persist":
			failing_step = "create_character"
			var new_name := "Smoke%d" % (int(Time.get_unix_time_from_system()) % 100000)
			var created := await _post("/api/characters/create",
				{"name": new_name, "house": "Gryffindor"}, account_token)
			if created["status"] != 200:
				_fail("create_character", "HTTP %d" % created["status"])
				return
			print("[smoke] created character '%s'" % new_name)
			characters = [(created["body"] as Dictionary).get("character", {})]
		if characters.is_empty():
			_fail("characters", "the account has no character to play")
			return
		character = characters[0]
		character_id = int(character.get("id", 0))
		if character_id <= 0:
			_fail("characters", "no character id in the list response")
			return
		print("[smoke] playing character %d (%s, exp %s)" % [
			character_id, String(character.get("name", "?")), str(character.get("exp", "?"))])

	# 3. a one-time game ticket, the same handoff the launcher uses. The
	#    persistence scenario asks for an UNBOUND one on purpose: that is the
	#    launcher shape (a ticket issued before a character is chosen), which is
	#    what made character-bind invisible. The reload control carries the character id.
	failing_step = "game_ticket"
	var ticket_body := {}
	if mode == "reload":
		ticket_body = {"character_id": character_id}
	var ticket_response := await _post("/api/game-ticket", ticket_body, account_token)
	if ticket_response["status"] != 200:
		_fail("game_ticket", "HTTP %d" % ticket_response["status"])
		return
	var ticket := String(ticket_response["body"].get("ticket", ""))
	if ticket == "":
		_fail("game_ticket", "no ticket in the response")
		return

	# 4. redeem it, as the game does, to get the session the world server checks.
	failing_step = "ticket_redeem"
	var redeemed := await _post("/api/ticket/redeem", {"ticket": ticket})
	if redeemed["status"] != 200:
		_fail("ticket_redeem", "HTTP %d" % redeemed["status"])
		return
	session_token = String(redeemed["body"].get("token", ""))
	if session_token == "":
		_fail("ticket_redeem", "no session token in the response")
		return
	print("[smoke] ticket redeemed; joining the world")

	# 5. join the world server with that session. The role has to be CLIENT
	# before joining, or this process would run the authority itself and wait
	# forever for state nobody is producing.
	failing_step = "join"
	SimAuthority.configure(SimAuthority.Role.CLIENT)
	SimNet.joined.connect(_on_joined)
	var err := SimNet.join(world_host, world_port, session_token)
	if err != OK:
		_fail("join", "create_client error %d" % err)

func _on_joined(ok: bool, reason: String, sheet: Dictionary) -> void:
	joined = ok
	if not ok:
		_fail("join", "refused: %s" % reason)
		return
	# The transport holds the identity the server granted; SimAuthority's copy is
	# only filled in when a world scene binds a local body, and this check has no
	# world scene on purpose (it must not need the world content to run).
	local_uid = SimNet.local_uid
	if local_uid == 0:
		_fail("join", "accepted but no entity id was assigned")
		return

	if mode == "reload":
		# The ticket carried the character id: the join itself must have bound
		# the session and delivered the saved sheet, without a bind exchange.
		if sheet.is_empty():
			_fail("reload", "the join returned no character sheet")
			return
		if int(sheet.get("id", 0)) != character_id:
			_fail("reload", "the join bound character %s, expected %d" % [str(sheet.get("id", 0)), character_id])
			return
		if expected_exp >= 0 and int(sheet.get("exp", -1)) < expected_exp:
			_fail("reload", "reloaded exp %d is below the session's %d" % [int(sheet.get("exp", -1)), expected_exp])
			return
		print("[smoke] SMOKE RELOAD OK character=%d exp=%d level=%d map=%s pos=%s" % [
			int(sheet.get("id", 0)), int(sheet.get("exp", -1)), int(sheet.get("level", -1)),
			String(sheet.get("map_id", "")), str(sheet.get("pos", []))])
		get_tree().quit(0)
		return

	if mode == "persist":
		if not sheet.is_empty() and int(sheet.get("id", 0)) > 0:
			# The ticket was unbound and asked for none, so a sheet here means
			# the server bound a character unprompted; accept it and play.
			_on_character_bound(true, "", sheet)
			return
		print("[smoke] joined uid %d unbound; asking the server to bind character %d" % [local_uid, character_id])
		SimNet.bind_character(character_id)
		_phase = "bind"
		_phase_deadline_ms = Time.get_ticks_msec() + 15000
		return

	if mode == "foreign":
		if not sheet.is_empty() and int(sheet.get("id", 0)) > 0:
			_fail("foreign", "the unbound join returned a character sheet")
			return
		print("[smoke] joined unbound; naming another account's character %d" % foreign_id)
		SimNet.bind_character(foreign_id)
		_phase = "foreign"
		_phase_deadline_ms = Time.get_ticks_msec() + 15000
		return

	print("[smoke] joined as uid %d; waiting for replicated state" % local_uid)

# ------------------------------------------------------- persistence scenario

func _on_character_bound(ok: bool, reason: String, sheet: Dictionary) -> void:
	if mode == "foreign":
		if ok:
			_fail("foreign", "the server bound another account's character")
			return
		# The refusal must leave the session unbound: no sheet was delivered.
		if not sheet.is_empty() and int(sheet.get("id", 0)) > 0:
			_fail("foreign", "a refusal still delivered a character sheet")
			return
		print("[smoke] SMOKE FOREIGN OK refused reason=%s" % (reason if reason != "" else "unknown"))
		get_tree().quit(0)
		return
	if mode != "persist" or _phase != "bind":
		return
	if not ok:
		_fail("bind", "the server refused the bind: %s" % reason)
		return
	if int(sheet.get("id", 0)) != character_id:
		_fail("bind", "bound character %s, expected %d" % [str(sheet.get("id", 0)), character_id])
		return
	_bound_exp = int(sheet.get("exp", -1))
	print("[smoke] bound to character %d (exp %d, map %s)" % [
		character_id, _bound_exp, String(sheet.get("map_id", ""))])
	_phase = "fight"
	_fight_started_ms = Time.get_ticks_msec()
	_phase_deadline_ms = _fight_started_ms + int(_env("HPMMO_SMOKE_FIGHT_SECONDS", "180")) * 1000
	_record_report = _fight_started_ms + 10000

func _on_reward(_uid: int, _character_id: int, exp: int, _galleons: int, _items: Array, op_id: String) -> void:
	if op_id.begins_with("kill:"):
		_kills += 1
		_kill_exp += exp
	elif op_id == "loot":
		_loot_taken += 1

func _kind_count(kind: int) -> int:
	var count := 0
	for uid in SimAuthority.entities.keys():
		if int(SimAuthority.entities[uid].get("kind", 0)) == kind:
			count += 1
	return count

func _visible_summary() -> String:
	return "%d entit(ies), %d mob(s), %d loot" % [
		SimAuthority.entities.size(), _kind_count(HPProtocol.Kind.MOB), _kind_count(HPProtocol.Kind.LOOT)]

func _local_pos() -> Vector3:
	var record: Dictionary = SimAuthority.entities.get(local_uid, {})
	var pos: Variant = record.get("pos", Vector3.ZERO)
	return pos if pos is Vector3 else Vector3.ZERO

func _nearest_of_kind(kind: int, require_pack: bool) -> int:
	var best := 0
	var best_distance := 1e9
	var mine := _local_pos()
	for uid in SimAuthority.entities.keys():
		var record: Dictionary = SimAuthority.entities[uid]
		if int(record.get("kind", 0)) != kind:
			continue
		if require_pack and int(record.get("pack_id", 0)) == 0:
			continue
		if bool(record.get("dead", false)) or int(record.get("hp", 0)) <= 0:
			continue
		var pos: Vector3 = record.get("pos", Vector3.ZERO)
		var distance := mine.distance_to(pos)
		if distance < best_distance:
			best_distance = distance
			best = int(uid)
	return best

func _walk_toward(goal: Vector3) -> void:
	var mine := _local_pos()
	var flat := goal - mine
	flat.y = 0.0
	if flat.length() <= 0.8:
		SimNet.forced_intent = {}
		return
	var now := Time.get_ticks_msec()
	if now - _last_move_check_ms >= 1000:
		_last_move_check_ms = now
		if _last_move_pos.distance_to(mine) < 0.6:
			_sidestep_until = now + 1200
		_last_move_pos = mine
	var offset := 0.0
	var jump := false
	if now < _sidestep_until:
		offset = deg_to_rad(90.0)
		jump = int(now / 250) % 2 == 0
	var direction := flat.rotated(Vector3.UP, offset)
	SimNet.forced_intent = {
		"move": Vector2(0, -1),
		"yaw": rad_to_deg(atan2(-direction.x, -direction.z)),
		"jump": jump,
		"descend": false,
	}

func _tick_fight() -> void:
	if _kills > 0:
		print("[smoke] kill credited (%d kill(s), +%d exp); looking for the drop" % [_kills, _kill_exp])
		_phase = "loot"
		_phase_deadline_ms = Time.get_ticks_msec() + 20000
		return
	var now_ms := Time.get_ticks_msec()
	if now_ms > _record_report:
		_record_report = now_ms + 10000
		print("[smoke] fight: %s visible, target=%d, %d cast(s) sent" % [
			_visible_summary(), _target_uid, _cast_seq])
	if now_ms > _phase_deadline_ms:
		_fail("fight", "no kill within the window (%d casts sent; %s visible)" % [_cast_seq, _visible_summary()])
		return
	var record: Dictionary = SimAuthority.entities.get(local_uid, {})
	if record.is_empty():
		return   # no snapshot yet
	if bool(record.get("dead", false)):
		SimNet.forced_intent = {}
		SimNet.submit_respawn(null)
		return
	_target_uid = _nearest_of_kind(HPProtocol.Kind.MOB, true)
	if _target_uid == 0:
		return   # nothing in interest range yet
	var target: Vector3 = SimAuthority.entities[_target_uid].get("pos", Vector3.ZERO)
	var flat := target - _local_pos()
	flat.y = 0.0
	if flat.length() > 18.0:
		_walk_toward(target)
		return
	SimNet.forced_intent = {}
	var now := Time.get_ticks_msec()
	if now - _last_cast_ms >= 500:
		_last_cast_ms = now
		_cast_seq += 1
		SimNet.submit_cast(null, "basic_cast", target + Vector3.UP, _cast_seq)

func _tick_loot() -> void:
	if _loot_taken > 0:
		_begin_disconnect()
		return
	if Time.get_ticks_msec() > _phase_deadline_ms:
		_fail("loot", "the kill dropped nothing this client could pick up (%d ground drop(s) seen)"
			% _loot_ground.size())
		return
	# Nearest ground drop, from the spawn events the authority sent.
	var loot_uid := 0
	var loot_pos := Vector3.ZERO
	var best := 1e9
	var mine := _local_pos()
	for uid in _loot_ground.keys():
		var pos: Vector3 = _loot_ground[uid]["pos"]
		var distance := mine.distance_to(pos)
		if distance < best:
			best = distance
			loot_uid = int(uid)
			loot_pos = pos
	if loot_uid == 0:
		return
	if best > 5.0:
		_walk_toward(loot_pos)
		return
	SimNet.forced_intent = {}
	SimNet.submit_pickup(null, loot_uid)

func _begin_disconnect() -> void:
	var record: Dictionary = SimAuthority.entities.get(local_uid, {})
	var mine := _local_pos()
	_state_at_disconnect = {
		"exp": int(record.get("exp", -1)),
		"galleons": int(record.get("galleons", -1)),
		"pos": mine,
		"map": String(record.get("map_id", "")),
	}
	print("[smoke] disconnecting: exp=%d galleons=%d pos=%.2f,%.2f,%.2f map=%s kills=%d loot=%d" % [
		int(_state_at_disconnect["exp"]), int(_state_at_disconnect["galleons"]),
		mine.x, mine.y, mine.z, String(_state_at_disconnect["map"]), _kills, _loot_taken])
	SimNet.forced_intent = {}
	SimNet.leave()
	_phase = "disconnect"
	_phase_deadline_ms = Time.get_ticks_msec() + 4000

func _process(_delta: float) -> void:
	if Time.get_ticks_msec() > deadline_ms:
		_fail(failing_step, "timed out after the configured window")
		return
	if not joined:
		return
	if mode == "join":
		# Replicated state is the proof that the authority is actually running: the
		# peer's own body plus whatever is in range.
		if SimAuthority.entities.size() > 0 and SimAuthority.sim_tick > 0:
			print("[smoke] SMOKE OK: login+join verified (uid=%d entities=%d tick=%d)" % [
				local_uid, SimAuthority.entities.size(), SimAuthority.sim_tick])
			get_tree().quit(0)
		return
	match _phase:
		"bind", "foreign":
			if Time.get_ticks_msec() > _phase_deadline_ms:
				_fail(_phase, "no answer to the character-naming request")
		"fight":
			_tick_fight()
		"loot":
			_tick_loot()
		"disconnect":
			if Time.get_ticks_msec() >= _phase_deadline_ms:
				var mine: Vector3 = _state_at_disconnect.get("pos", Vector3.ZERO)
				print("[smoke] SMOKE PERSIST OK character=%d exp=%d galleons=%d pos=%.2f,%.2f,%.2f map=%s kills=%d loot=%d" % [
					character_id, int(_state_at_disconnect.get("exp", -1)),
					int(_state_at_disconnect.get("galleons", -1)), mine.x, mine.y, mine.z,
					String(_state_at_disconnect.get("map", "")), _kills, _loot_taken])
				get_tree().quit(0)
