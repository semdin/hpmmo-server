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

var world: Node3D = null
var admin: Node = null

func _ready() -> void:
	print("=========================================================")
	print(">>> [HPMMO WORLD SERVER] booting %s <<<" % HPProtocol.version_string())
	print("=========================================================")
	# Marks this process as a server before the world scene builds: without it the
	# world would spawn a local player body nobody is driving.
	NetworkManager.is_dedicated_server = true
	NetworkManager.is_server = true
	NetworkManager.is_connected_to_game = true
	var port := int(_env("HPMMO_WORLD_PORT", str(SimNet.DEFAULT_PORT)))
	var world_seed := int(_env("HPMMO_WORLD_SEED", "0"))
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

	# Maintenance controller (plan.md Phase 6). It owns the drain/save/disconnect
	# state machine and the authenticated admin HTTP API, and it is the gate the
	# authority consults while the world is frozen. Without HPMMO_SERVICE_TOKEN it
	# refuses to start and logs why - the API is never open.
	admin = AdminApi.new()
	admin.name = "AdminApi"
	add_child(admin)
	SimAuthority.maintenance = admin

	world = WORLD_SCENE.instantiate()
	add_child(world)
	# Roster transitions are logged immediately (not only on the 5 s status
	# tick): operations and the Phase 8 map tests need to see joins, leaves and
	# entity counts without waiting for a timer.
	SimAuthority.player_joined.connect(func(_uid: int, _character_id: int, _peer_id: int): _print_roster("join"))
	SimAuthority.player_left.connect(func(_uid: int, _character_id: int): _print_roster("leave"))

	# --- Phase 8 magical staircase (ADDITIVE dev/test hook) --------------------
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

func _env(name: String, fallback: String) -> String:
	var value := OS.get_environment(name)
	return value if value != "" else fallback

var _status_accumulator: float = 0.0

## Periodic status line: enough to tell "nobody is connected" from "somebody is
## connected but their input is not arriving".
func _process(delta: float) -> void:
	_status_accumulator += delta
	if _status_accumulator < 5.0:
		return
	_status_accumulator = 0.0
	var players := []
	for peer_id in SimAuthority.players_by_peer.keys():
		var record := SimAuthority.player_record(int(peer_id))
		var node = record.get("node")
		if node != null and is_instance_valid(node):
			players.append("peer %d uid %d map=%s at (%.1f, %.1f, %.1f) hp %d exp %d" % [
				int(peer_id), int(record.get("uid", 0)), String(record.get("map_id", "")),
				(node as Node3D).global_position.x, (node as Node3D).global_position.y,
				(node as Node3D).global_position.z, int(record.get("hp", 0)),
				int(record.get("exp", 0))])
	print("[WorldServer] tick=%d state=%s entities=%d players=%d inputs=%d casts=%d | %s" % [
		SimAuthority.sim_tick, SimAuthority.maintenance_state(), SimAuthority.entities.size(),
		SimAuthority.players_by_peer.size(), SimNet.inputs_received, SimNet.cast_requests_received,
		" ; ".join(players)])
