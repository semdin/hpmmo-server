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
##   HPMMO_SERVICE_TOKEN   service token for that API (enables persistence)
##   HPMMO_NET_PROFILE     latency/loss profile (local|broadband|mobile|awful)

const WORLD_SCENE = preload("res://scenes/world/game_world.tscn")

var world: Node3D = null

func _ready() -> void:
	print("=========================================================")
	print(">>> [HPMMO WORLD SERVER] booting %s <<<" % HPProtocol.version_string())
	print("=========================================================")
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
		# every character on restart.
		push_warning("[WorldServer] running WITHOUT persistence (HPMMO_API_URL / HPMMO_SERVICE_TOKEN unset)")
		print("[WorldServer] WARNING: persistence disabled - characters are session-only")

	var error := SimNet.host(port)
	if error != OK:
		printerr("[WorldServer] cannot bind UDP %d (error %d)" % [port, error])
		get_tree().quit(1)
		return
	SimNet.bridge_authority()

	world = WORLD_SCENE.instantiate()
	add_child(world)
	print("[WorldServer] world ready: seed=%d tick=%dHz protocol=%d" % [
		SimAuthority.seed_value, HPProtocol.SIM_HZ, HPProtocol.PROTOCOL_VERSION])
	print("[WorldServer] listening on :%d - waiting for players" % port)
	print("=========================================================")

func _env(name: String, fallback: String) -> String:
	var value := OS.get_environment(name)
	return value if value != "" else fallback

func _process(_delta: float) -> void:
	pass
