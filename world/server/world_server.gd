extends Node

## HPMMO world server entry point.
##
## OWNER: server repository (this tree is preserved by the world export and has
## no counterpart in the client). It boots the authoritative world headlessly,
## hosts the ENet transport and bridges the authority's events onto the network.
##
## Environment:
##   HPMMO_WORLD_PORT      UDP port (default 7777)
##   HPMMO_WORLD_SEED      RNG seed; logged and pinned so encounters replay
##   HPMMO_API_URL         C++ persistence service base URL (default 127.0.0.1:8081)
##   HPMMO_SERVICE_TOKEN   service token for that API (enables persistence) and
##                         for the maintenance API (never logged)
##   HPMMO_NET_PROFILE     latency/loss profile (local|broadband|mobile|awful)
##   HPMMO_ADMIN_PORT      maintenance API TCP port, 127.0.0.1 only (default 8082)
##   HPMMO_RELEASE         release identifier published on GET /admin/status

const WORLD_SCENE = preload("res://scenes/world/game_world.tscn")
const HPProtocol = preload("res://addons/hpmmo_sim/protocol.gd")
const AdminApi = preload("res://addons/hpmmo_sim/admin.gd")
const MapHost = preload("res://server/map_host.gd")

var world: Node3D = null
var admin: Node = null
var map_host: Node = null

func _ready() -> void:
	# A headless world with no cap spins its main loop flat out (a whole core)
	# doing nothing useful between physics steps. Physics stays 60 Hz; the frame
	# rate is how often ENet is serviced, and every packet (and every ack that
	# makes up the client's ping) waits for the next frame - half a frame on
	# average each way. 120 frames halve that wait for a few % of one core on
	# the 4-core box. HPMMO_SERVER_FPS overrides it.
	Engine.max_fps = clampi(int(_env("HPMMO_SERVER_FPS", "120")), 30, 240)
	# Section timers on the status line (see HPProf).
	HPProf.enabled = true
	print("=========================================================")
	print(">>> [HPMMO WORLD SERVER] booting %s <<<" % HPProtocol.version_string())
	print("=========================================================")
	# Marks this process as a server before the world scene builds: without it the
	# world would spawn a local player body nobody is driving.
	NetworkManager.is_dedicated_server = true
	# Nothing here is ever seen or heard. The AudioManager autoload would mix
	# zones and answer every combat signal; particle emitters spawned by any
	# scene (monolith runes, torches, spell bodies) would simulate on the CPU.
	AudioManager.disable_for_server()
	get_tree().node_added.connect(_strip_presentation)
	NetworkManager.is_server = true
	NetworkManager.is_connected_to_game = true
	var port := int(_env("HPMMO_WORLD_PORT", str(SimNet.DEFAULT_PORT)))
	# Reproducible by default: the authored debug seed replays an exact spawn
	# layout without anyone having to remember a number.
	var world_seed := int(_env("HPMMO_WORLD_SEED", str(HPRules.debug_seed())))
	SimAuthority.configure(SimAuthority.Role.DEDICATED, world_seed)

	var api_url := _env("HPMMO_API_URL", "")
	var service_token := _env("HPMMO_SERVICE_TOKEN", "")
	if api_url != "" and service_token != "":
		var bridge = load("res://addons/hpmmo_sim/persistence.gd").new()
		bridge.name = "PersistenceBridge"
		add_child(bridge)
		bridge.configure(api_url, service_token)
		SimAuthority.persistence = bridge
		print("[WorldServer] persistence: %s" % api_url)
	else:
		# Loud on purpose: a server without persistence looks healthy and loses
		# every character on restart. Printed on stdout (not push_warning) so it
		# lands in the server log rather than on stderr, which Windows shells
		# treat as a command failure.
		print("[WorldServer] WARNING: persistence disabled (HPMMO_API_URL / HPMMO_SERVICE_TOKEN unset)")
		print("[WorldServer] WARNING: characters are session-only until it is configured")

	var error := SimNet.host(port)
	if error != OK:
		printerr("[WorldServer] cannot bind UDP %d (error %d)" % [port, error])
		get_tree().quit(1)
		return
	SimNet.bridge_authority()

	# Maintenance controller. It owns the drain/save/disconnect
	# state machine and the authenticated admin HTTP API, and it is the gate the
	# authority consults while the world is frozen. Without HPMMO_SERVICE_TOKEN it
	# refuses to start and logs why - the API is never open.
	admin = AdminApi.new()
	admin.name = "AdminApi"
	add_child(admin)
	SimAuthority.maintenance = admin

	world = WORLD_SCENE.instantiate()
	add_child(world)

	# Map host: the authority consults it before it reserves a
	# transfer into a map, so the destination's collision exists in this process
	# before ownership moves. Without it, an authoritative body indoors has no
	# floor and the per-map fall rescue bounces it (and every client with it).
	map_host = MapHost.new()
	map_host.name = "MapHost"
	map_host.world = world
	add_child(map_host)
	# The castle interior is built now, not on the first player to walk in:
	# that build (~1900 bodies) froze every player's tick for ~0.7 s, live.
	# HPMMO_LAZY_MAPS=1 keeps the old build-on-first-use.
	if _env("HPMMO_LAZY_MAPS", "") != "1":
		map_host.ensure_map_built(MapHost.MAP_INTERIOR)
	_warm_player_body()
	HPSnapshots.warm_index(SimAuthority)
	# Roster transitions are logged immediately (not only on the 5 s status
	# tick): operations and the map transfer map tests need to see joins, leaves and
	# entity counts without waiting for a timer.
	SimAuthority.player_joined.connect(func(_uid: int, _character_id: int, _peer_id: int): _print_roster("join"))
	SimAuthority.player_left.connect(func(_uid: int, _character_id: int): _print_roster("leave"))

	# --- the map transfer magical staircase (ADDITIVE dev/test hook) --------------------
	# The interior map is authored by another workstream and is not part of the
	# exported world yet, so a test - or local play - can place the staircase by
	# environment. With HPMMO_DEV_STAIRCASE unset, none of this runs. Production
	# wiring is the interior scene instancing staircase.tscn at its StaircaseSlot;
	# the authority runtime is HPStaircase either way.
	var stair_at := OS.get_environment("HPMMO_DEV_STAIRCASE")
	if stair_at != "":
		var parts := stair_at.split(",")
		if parts.size() == 3:
			var stair: Node3D = (load("res://addons/hpmmo_sim/staircase.gd") as GDScript).new()
			stair.name = "MagicalStaircase"
			add_child(stair)
			stair.global_position = Vector3(float(parts[0]), float(parts[1]), float(parts[2]))
			print("[WorldServer] dev magical staircase at %s" % stair.global_position)
		else:
			printerr("[WorldServer] HPMMO_DEV_STAIRCASE wants 'x,y,z', got '%s'" % stair_at)
	# ---------------------------------------------------------------------------

	print("[WorldServer] world ready: seed=%d tick=%dHz protocol=%d maps=%s" % [
		SimAuthority.seed_value, HPProtocol.SIM_HZ, HPProtocol.PROTOCOL_VERSION,
		", ".join(HPMaps.map_ids())])
	print("[WorldServer] listening on :%d - waiting for players" % port)
	print("=========================================================")

## The first join after a boot built the first wizard cold (~150 ms) while
## every connected player's tick waited. One throwaway body is built now
## instead, and the scene stays referenced (a resource nobody holds leaves the
## cache), so later joins instantiate it warm. A server body carries no
## presentation (player.gd `_strip_presentation`), so nothing else needs it.
## The body also restores a geared sheet: the first character restore after a
## boot ran its equipment, quest and stat code cold (24-82 ms on live binds,
## 144 ms locally) where every later one takes ~1.5 ms.
const TEST_CHARACTER := "res://scripts/server/test_character.gd"
var _warm_resources: Array = []

func _warm_player_body() -> void:
	var started := Time.get_ticks_usec()
	var player_scene: PackedScene = load("res://scenes/entities/player/player.tscn")
	_warm_resources.append(player_scene)
	var body: Node3D = player_scene.instantiate()
	body.name = "WarmupBody"
	body.set("is_local_player", false)
	world.add_child(body)
	if ResourceLoader.exists(TEST_CHARACTER):
		body.call("restore_character", load(TEST_CHARACTER).build("30"))
	body.queue_free()
	print("[WorldServer] player body warmed in %.1f ms" % ((Time.get_ticks_usec() - started) / 1000.0))

## One line per roster change: enough to prove "no duplicate character" and
## "the registry did not grow" without reading internals.
func _print_roster(event: String) -> void:
	var players := []
	for peer_id in SimAuthority.players_by_peer.keys():
		var record := SimAuthority.player_record(int(peer_id))
		players.append("peer %d uid %d char %d map=%s" % [
			int(peer_id), int(record.get("uid", 0)), int(record.get("character_id", 0)),
			String(record.get("map_id", ""))])
	print("[WorldServer] roster(%s): players=%d entities=%d | %s" % [
		event, SimAuthority.players_by_peer.size(), SimAuthority.entities.size(),
		" ; ".join(players)])

## Particle emitters cost CPU even headless (CPUParticles3D simulates on the
## main thread) and decide nothing: stop each one as it enters the tree.
func _strip_presentation(node: Node) -> void:
	if node is CPUParticles3D or node is GPUParticles3D:
		node.set("emitting", false)
		node.process_mode = Node.PROCESS_MODE_DISABLED

func _env(name: String, fallback: String) -> String:
	var value := OS.get_environment(name)
	return value if value != "" else fallback

var _status_accumulator: float = 0.0
## Worst frame and hitches (frames over 50 ms) since the last status line. The
## physics/process numbers below are one frame's sample; a hitch between two
## lines only shows here. Measured on the wall clock: the engine clamps the
## frame `delta` it hands out, so a 10 s freeze of the host read as one 139 ms
## frame and the status line itself came 16 s apart.
var _worst_frame_ms := 0.0
var _hitches := 0
var _frame_usec := 0
var _stall_ms_logged := 0

## Periodic status line: enough to tell "nobody is connected" from "somebody is
## connected but their input is not arriving".
func _process(delta: float) -> void:
	# The interest index is kept up to date on use - which was the first
	# snapshot after a boot, 30-100 ms of the first player's join, because the
	# creatures register in the frames after the world is up. While nobody is
	# on, it is brought up to date every frame instead (a no-op when nothing
	# changed).
	if SimAuthority.players_by_peer.is_empty():
		HPSnapshots.warm_index(SimAuthority)
	var now_usec := Time.get_ticks_usec()
	var frame_s := delta if _frame_usec == 0 else float(now_usec - _frame_usec) / 1000000.0
	_frame_usec = now_usec
	_worst_frame_ms = maxf(_worst_frame_ms, frame_s * 1000.0)
	if frame_s > 0.05:
		_hitches += 1
	if frame_s > 1.0:
		# Nothing in this process takes a second: the host did not run it.
		print("[WorldServer] stall %.0f ms (players=%d)" % [frame_s * 1000.0, SimAuthority.players_by_peer.size()])
	_status_accumulator += frame_s
	if _status_accumulator < 5.0:
		return
	_status_accumulator = 0.0
	var players := []
	for peer_id in SimAuthority.players_by_peer.keys():
		var record := SimAuthority.player_record(int(peer_id))
		var node = record.get("node")
		if node != null and is_instance_valid(node):
			# claims: positions its client claimed that the body took, and the
			# refused ones by reason (player.gd claim_position), since the last line
			var refused: Dictionary = node.get("claims_refused") if "claims_refused" in node else {}
			players.append("peer %d uid %d map=%s at (%.1f, %.1f, %.1f) hp %d exp %d rtt %d claims %d %s" % [
				int(peer_id), int(record.get("uid", 0)), String(record.get("map_id", "")),
				(node as Node3D).global_position.x, (node as Node3D).global_position.y,
				(node as Node3D).global_position.z, int(record.get("hp", 0)),
				int(record.get("exp", 0)), SimNet.peer_rtt_ms(int(peer_id)),
				int(node.get("claims_taken")) if "claims_taken" in node else 0,
				JSON.stringify(refused)])
			if "claims_taken" in node:
				node.set("claims_taken", 0)
				refused.clear()
	# Frame cost: one physics step per sim tick, so physics_ms + process_ms
	# near 1000 / SIM_HZ means the server cannot hold its tick rate (players
	# then see their corrections pull them back).
	# `prof` is ms per second / slowest call per section (HPProf); `mobs` and
	# `players` are the bodies' own physics frames, `net` the end-of-frame ENet
	# service with the RPCs it dispatched.
	# `stalled_ms`: wall time the simulation lost since the last line (frames
	# far past their budget; SimAuthority.stall_ms).
	print("[WorldServer] tick=%d state=%s entities=%d players=%d inputs=%d casts=%d physics_ms=%.1f process_ms=%.1f worst_frame_ms=%.0f hitches=%d stalled_ms=%d prof: %s | %s" % [
		SimAuthority.sim_tick, SimAuthority.maintenance_state(), SimAuthority.entities.size(),
		SimAuthority.players_by_peer.size(), SimNet.inputs_received, SimNet.cast_requests_received,
		Performance.get_monitor(Performance.TIME_PHYSICS_PROCESS) * 1000.0,
		Performance.get_monitor(Performance.TIME_PROCESS) * 1000.0,
		_worst_frame_ms, _hitches, SimAuthority.stall_ms - _stall_ms_logged, HPProf.report(),
		" ; ".join(players)])
	_worst_frame_ms = 0.0
	_hitches = 0
	_stall_ms_logged = SimAuthority.stall_ms
