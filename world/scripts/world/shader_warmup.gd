extends Node3D
class_name ShaderWarmup

## macOS only: draws every creature, a remote player and every spell stage once,
## in front of the camera while the loading screen still covers it, so Metal
## compiles their shaders there instead of in play.
##
## Godot 4.7's Metal driver keeps no pipeline cache and our Linux export cannot
## bake Metal shaders, so on a Mac each new material compiled the first time it
## was drawn: seconds-long freezes on entering the world and on first sight of
## a new creature kind (Apple M1, 1.0.68). Windows and Linux keep Vulkan's
## pipeline cache and skip this (`--shader-warmup` forces it, for testing).
##
##   WorldLoader: if ShaderWarmup.wanted(): warmup = ShaderWarmup.start(world)
##                ... wait for warmup.done ...

const DISTANCE := 7.0       # metres in front of the camera
const SPACING := 1.4
const SCALE := 0.35         # big creatures still fit the view; scale changes no shader
const QUIET := 0.75         # done once no pipeline compiled for this long...
const MIN_TIME := 1.5
const MAX_TIME := 60.0      # ...or after this, whatever is left compiles in play
const REFIRE := [0.0, 0.9]  # spell stages fire twice: short layers die fast

const PIPELINE_INFOS := [
	RenderingServer.RENDERING_INFO_PIPELINE_COMPILATIONS_CANVAS,
	RenderingServer.RENDERING_INFO_PIPELINE_COMPILATIONS_MESH,
	RenderingServer.RENDERING_INFO_PIPELINE_COMPILATIONS_SURFACE,
	RenderingServer.RENDERING_INFO_PIPELINE_COMPILATIONS_DRAW,
	RenderingServer.RENDERING_INFO_PIPELINE_COMPILATIONS_SPECIALIZATION,
]

var done := false
var _t := 0.0
var _quiet := 0.0
var _fired := 0
var _start_count := 0
var _last_count := 0
var _mute_was := false
var _slot := 0

static func wanted() -> bool:
	if DisplayServer.get_name() == "headless":
		return false
	var forced := "--shader-warmup" in OS.get_cmdline_args() or "--shader-warmup" in OS.get_cmdline_user_args()
	return OS.get_name() == "macOS" or forced

static func start(world: Node) -> ShaderWarmup:
	var warmup := ShaderWarmup.new()
	warmup.name = "ShaderWarmup"
	world.add_child(warmup)
	return warmup

static func pipeline_count() -> int:
	var total := 0
	for info in PIPELINE_INFOS:
		total += int(RenderingServer.get_rendering_info(info))
	return total

func _ready() -> void:
	var camera := get_viewport().get_camera_3d()
	if camera == null:
		_finish("no camera")
		return
	# In front of the camera, facing it.
	var basis := camera.global_transform.basis
	global_position = camera.global_position - basis.z * DISTANCE
	global_basis = basis
	_mute_was = AudioServer.is_bus_mute(0)
	AudioServer.set_bus_mute(0, true)
	_start_count = pipeline_count()
	_last_count = _start_count
	# Creature bodies are puppets as on any client; the authority (solo play)
	# would enrol them in the simulation, so it warms spells only.
	if not SimAuthority.is_authority():
		for path in HPProtocol.MOB_SCENES.values():
			_add_body(String(path), true)
		_add_body("res://scenes/entities/player/player.tscn", true)
	print("[ShaderWarmup] started: %d bodies" % get_child_count())

func _add_body(path: String, puppet: bool) -> void:
	if not ResourceLoader.exists(path):
		return
	var scene := load(path) as PackedScene
	if scene == null:
		return
	var body := scene.instantiate() as Node3D
	if body == null:
		return
	if puppet and "sim_puppet" in body:
		body.sim_puppet = true
	if "is_local_player" in body:
		body.is_local_player = false
	add_child(body)
	body.position = _grid(_slot)
	body.scale = Vector3.ONE * SCALE
	# A puppet walks to its last replicated position: here, where it stands.
	if "sim_target_pos" in body:
		body.sim_target_pos = body.global_position
	_slot += 1
	# A creature out of sight stays a puppet; keep it out of targeting.
	for group in ["mobs", "targetable", "players"]:
		if body.is_in_group(group):
			body.remove_from_group(group)

func _grid(i: int) -> Vector3:
	const COLUMNS := 7
	return Vector3((i % COLUMNS - COLUMNS / 2) * SPACING, (i / COLUMNS) * SPACING - 1.0, 0.0)

func _fire_spells() -> void:
	var skill_fx := preload("res://scripts/spells/skill_fx.gd")
	var i := 0
	for spell_id in skill_fx.VFX.SPELLS.keys():
		var stages: Dictionary = skill_fx.VFX.SPELLS[spell_id].get("stages", {})
		for stage in stages.keys():
			var at := global_transform * Vector3(((i % 9) - 4) * 0.8, 1.5, -1.0)
			skill_fx.spawn_stage(self, String(spell_id), String(stage), at, -global_basis.z)
			i += 1

func _process(delta: float) -> void:
	if done:
		return
	_t += delta
	if _fired < REFIRE.size() and _t >= float(REFIRE[_fired]):
		_fire_spells()
		_fired += 1
	var count := pipeline_count()
	if count != _last_count:
		_last_count = count
		_quiet = 0.0
	else:
		_quiet += delta
	if (_t >= MIN_TIME and _quiet >= QUIET) or _t >= MAX_TIME:
		_finish("")

func _finish(reason: String) -> void:
	done = true
	AudioServer.set_bus_mute(0, _mute_was)
	print("[ShaderWarmup] %s%d pipelines compiled in %.1f s" % [
		(reason + ": ") if reason != "" else "", _last_count - _start_count, _t])
	queue_free()
