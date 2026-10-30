extends Node3D
class_name ShaderWarmup

## Draws every creature, a remote player and every spell stage once, in front
## of the camera while the loading screen still covers it, so the GPU driver
## compiles their pipelines there instead of in play.
##
## Godot 4.7's Metal driver keeps no pipeline cache and our Linux export cannot
## bake Metal shaders, so on a Mac each new material compiled the first time it
## was drawn: seconds-long freezes on entering the world and on first sight of
## a new creature kind (Apple M1, 1.0.68). Vulkan (Windows, Linux) does keep a
## pipeline cache, but a fight still compiled ~170 pipelines in its first
## 30 s (perf_probe, Intel iGPU, 2026-10-30); warmed, half of them move to the
## loading screen (~2.5 s) and the fight's p95 frame went 21 -> 15 ms. So every
## platform warms now (`--no-shader-warmup` skips it, for comparisons).
##
##   WorldLoader: if ShaderWarmup.wanted(): warmup = ShaderWarmup.start(world)
##                ... wait for warmup.done ...

const DISTANCE := 7.0       # metres in front of the camera
const SPACING := 1.4
const SCALE := 0.35         # big creatures still fit the view; scale changes no shader
const QUIET := 0.75         # done once no pipeline compiled for this long...
const MIN_TIME := 2.5
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
var _bodies: Array = []

static func wanted() -> bool:
	if DisplayServer.get_name() == "headless":
		return false
	return not ("--no-shader-warmup" in OS.get_cmdline_args() or "--no-shader-warmup" in OS.get_cmdline_user_args())

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
	_bodies = get_children()
	_add_combat_extras()
	print("[ShaderWarmup] started: %d bodies" % _bodies.size())

## What first shows on a hit or a kill (1.0.70 still froze there on an M5): the
## hit flash overlay on every body, the loot chest with its rim overlay, an
## attack telegraph, the target ring, floating text and the level-up pillar
## (stun stars and burn are spell stages, drawn below).
func _add_combat_extras() -> void:
	var flash := HitFeedback.flash_material()
	flash.albedo_color = Color(1.0, 0.95, 0.85, 0.3)
	for body in _bodies:
		for mesh in (body as Node).find_children("*", "MeshInstance3D", true, false):
			(mesh as GeometryInstance3D).material_overlay = flash
	for item_id in ["chest", "chest_rare"]:
		var chest := preload("res://scenes/entities/loot/loot_drop.tscn").instantiate()
		add_child(chest)
		chest.position = _grid(_slot)
		_slot += 1
		chest.setup(item_id, 1, [])
		chest.remove_from_group("loot")
	var ring := MeshInstance3D.new()
	var plane := PlaneMesh.new()
	plane.size = Vector2(2.0, 2.0)
	ring.mesh = plane
	var ring_mat := ShaderMaterial.new()
	ring_mat.shader = TargetRing.SHADER
	ring.material_override = ring_mat
	ring.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	add_child(ring)
	ring.position = _grid(_slot) + Vector3.BACK * 0.5
	ring.rotation.x = PI * 0.5   # face the camera
	_slot += 1
	# Crowd-control looks (StatusFX): ice shell, tints, crystals, stars, motes.
	for mat in StatusFX.warm_materials():
		var swatch := MeshInstance3D.new()
		var quad := QuadMesh.new()
		quad.size = Vector2(0.6, 0.6)
		swatch.mesh = quad
		swatch.material_override = mat
		swatch.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		add_child(swatch)
		swatch.position = _grid(_slot) + Vector3.BACK * 0.5
		_slot += 1
	for body in _bodies:
		if body.has_method("_show_warning"):
			body.set("_attack_center", (body as Node3D).global_position)
			body.call("_show_warning", {})
			break
	for body in _bodies:
		if body.has_method("_spawn_floating_text"):
			body.call("_spawn_floating_text", "1234!", Color(1.0, 0.8, 0.3), 1.3)
			LevelUpFX.play(body, 2)
			break

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
