extends Node

## Synthetic login + join check (plan.md Phase 6, VERIFYING step).
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
## Environment (credentials are never printed):
##   HPMMO_SMOKE_USER, HPMMO_SMOKE_PASSWORD   required
##   HPMMO_SMOKE_API_URL                      default: HPMMO_API_URL or 127.0.0.1:8081
##   HPMMO_SMOKE_WORLD_HOST / _PORT           default: 127.0.0.1 / HPMMO_WORLD_PORT or 7777
##   HPMMO_SMOKE_TIMEOUT                      seconds, default 60
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

func _ready() -> void:
	api_url = _env_any(["HPMMO_SMOKE_API_URL", "HPMMO_API_URL"], "http://127.0.0.1:8081").rstrip("/")
	world_host = _env("HPMMO_SMOKE_WORLD_HOST", "127.0.0.1")
	world_port = int(_env("HPMMO_SMOKE_WORLD_PORT", _env_any(["HPMMO_WORLD_PORT"], "7777")))
	username = _env("HPMMO_SMOKE_USER", "")
	password = _env("HPMMO_SMOKE_PASSWORD", "")
	deadline_ms = Time.get_ticks_msec() + int(_env("HPMMO_SMOKE_TIMEOUT", "60")) * 1000
	_http = HTTPRequest.new()
	_http.timeout = 10.0
	add_child(_http)
	print("[smoke] api=%s world=%s:%d user=%s" % [api_url, world_host, world_port, username if username != "" else "(unset)"])
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
	var account_token := String(login["body"].get("token", ""))
	if account_token == "":
		_fail("login", "no session token in the response")
		return
	print("[smoke] logged in (account %s)" % str(login["body"].get("account_id", "?")))

	# 2. a one-time game ticket, the same handoff the launcher uses.
	failing_step = "game_ticket"
	var ticket_response := await _post("/api/game-ticket", {}, account_token)
	if ticket_response["status"] != 200:
		_fail("game_ticket", "HTTP %d" % ticket_response["status"])
		return
	var ticket := String(ticket_response["body"].get("ticket", ""))
	if ticket == "":
		_fail("game_ticket", "no ticket in the response")
		return

	# 3. redeem it, as the game does, to get the session the world server checks.
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

	# 4. join the world server with that session. The role has to be CLIENT
	# before joining, or this process would run the authority itself and wait
	# forever for state nobody is producing.
	failing_step = "join"
	SimAuthority.configure(SimAuthority.Role.CLIENT)
	SimNet.joined.connect(_on_joined)
	var err := SimNet.join(world_host, world_port, session_token)
	if err != OK:
		_fail("join", "create_client error %d" % err)

func _on_joined(ok: bool, reason: String, _character: Dictionary) -> void:
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
	print("[smoke] joined as uid %d; waiting for replicated state" % local_uid)

func _process(_delta: float) -> void:
	if Time.get_ticks_msec() > deadline_ms:
		_fail(failing_step, "timed out after the configured window")
		return
	if not joined:
		return
	# Replicated state is the proof that the authority is actually running: the
	# peer's own body plus whatever is in range.
	if SimAuthority.entities.size() > 0 and SimAuthority.sim_tick > 0:
		print("[smoke] SMOKE OK: login+join verified (uid=%d entities=%d tick=%d)" % [
			local_uid, SimAuthority.entities.size(), SimAuthority.sim_tick])
		get_tree().quit(0)
