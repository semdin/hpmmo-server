extends Node3D

## The boss warning's effect: what burns on the telegraph's ground disc, with
## timing that is the authoritative telegraph's, never a client guess.
##
## The shape and the countdown come straight from the replicated telegraph
## (`MSG_TELEGRAPH` / the entity record's `telegraph` dict): `start_tick`,
## `release_tick`, `kind` and the hit area's `radius`/`range`/`half_angle`. The
## effect is only the presentation of that data - it cannot move the release
## tick, and `set_progress()` is driven by the same sim clock the authority
## scheduled the damage on, so what the player sees is what the server will do.
##
## It is the ground that burns, built from the game's own fire and not from
## drawn shapes:
##   * the ground - one disc with ground_telegraph.gdshader: the exact hit area
##     charred and seamed with fire, a line of fire on its boundary, a ragged
##     front crawling out to the boundary as the countdown. A creature's
##     warning brings its own disc (this effect is its child and drives its
##     material); a dungeon hazard has none, so the effect makes one;
##   * embers lifting off the boundary (RisingMotes: the sparks every spell
##     throws), and a burst of them when it goes off;
##   * a flickering light, the charge/release audio and the release blast.
## A lasting patch (a venom pool, sticky ground) is the ground alone.
## No flames stand on it: a ring of flame cards round this ground was tried
## and the user threw it out, as they did a red swirl of energy and, before
## either, ruled lines with a flat fill. The burning ground is what they kept.

const MobBase = preload("res://scripts/entities/mobs/mob_base.gd")
const QualityPreset = preload("res://scripts/world/quality_preset.gd")
const APPEAR_S := 0.16
const BLAST_S := 0.34
## How long the embers already in the air are left to burn out after a release.
const AFTERGLOW_S := 0.8

var kind := "area"
var radius := 5.5
var range_length := 8.0
var half_angle := 0.6
var colour := MobBase.WARNING_TINT
var progress := 0.0
var _layers := {}
var _released := false
var _held := false
var _audio: Node = null
## The disc this effect burns on: the parent creature's, or its own.
var _disc: MeshInstance3D = null
var _own_disc := false
var _embers: GPUParticles3D = null
var _light: OmniLight3D = null
var _appear := 0.0

const CHARGE_SOUND := "boss_slam_cast"
const RELEASE_SOUND := "boss_slam_release"


## `data` is the telegraph dictionary exactly as replicated. Without a
## `release_tick` it is a lasting patch (a venom pool, sticky ground): the
## ground is held, with no countdown and no flames.
func setup(data: Dictionary) -> void:
	kind = String(data.get("kind", "area"))
	radius = float(data.get("radius", 5.5))
	range_length = float(data.get("range", 8.0))
	half_angle = float(data.get("half_angle", 0.6))
	_held = not data.has("release_tick")
	_build()
	_param("held", 1.0 if _held else 0.0)
	if data.has("start_tick") and data.has("release_tick"):
		# One charge cue at the start of the anticipation, one release cue at the
		# authoritative release tick - both scheduled on the telegraph's ticks.
		var start_tick := int(data.get("start_tick", 0))
		var release_tick := int(data.get("release_tick", start_tick))
		var lead := maxf(0.0, float(release_tick - start_tick) / float(maxi(1, int(_sim_hz()))))
		_play_cue(CHARGE_SOUND, 0.0)
		if lead > 0.05:
			var timer := get_tree().create_timer(lead)
			timer.timeout.connect(func(): _play_cue(RELEASE_SOUND, 0.0))

func _sim_hz() -> float:
	var sim := get_node_or_null("/root/SimAuthority")
	if sim != null and "SIM_HZ" in sim:
		return float(sim.get("SIM_HZ"))
	return 20.0

func _reach() -> float:
	return range_length if kind == "directional" else radius

func _sector() -> float:
	return half_angle if kind == "directional" else 4.0

func _ready() -> void:
	set_process(false)
	set_physics_process(false)

func _build() -> void:
	var low := QualityPreset.current() == "low"
	# 1) the ground: the creature's own disc (it carries the authoritative
	#    radius - the multiplayer probe reads `mesh.top_radius` from it), or one
	#    made here for a hazard that has no creature
	var host := get_parent() as MeshInstance3D
	if host != null and host.mesh is CylinderMesh and (host.mesh as CylinderMesh).material is ShaderMaterial:
		_disc = host
	else:
		_disc = MobBase.warning_disc(_reach(), half_angle if kind == "directional" else 0.0)
		_disc.name = "Area"
		_disc.position = Vector3(0, 0.08, 0)
		add_child(_disc)
		_own_disc = true
	_param("tint", colour)
	if _held:
		_appear = 1.0
		_param("fade", 1.0)
		return
	_param("fade", 0.0)
	# 2) embers lifting off the boundary
	_embers = RisingMotes.make(_reach(), _sector(), colour, 16 if low else 36, 1.5, Vector2(0.4, 1.7), Vector2(0.011, 0.026))
	RisingMotes.set_rate(_embers, 0.3)
	add_child(_embers)
	_embers.emitting = true
	_layers["embers"] = _embers
	# 3) a flickering light, off on the reduced preset
	if not low:
		_light = OmniLight3D.new()
		_light.name = "WarningLight"
		_light.light_color = colour.lerp(Color(1.0, 0.75, 0.45), 0.3)
		_light.light_energy = 0.0
		_light.omni_range = maxf(4.5, _reach() * 1.5)
		_light.omni_attenuation = 1.4
		_light.shadow_enabled = false
		add_child(_light)
		_light.position = Vector3(0, 1.1, _reach() * 0.5 if kind == "directional" else 0.0)
		_layers["light"] = _light
	set_process(true)

## The warning burns in over APPEAR_S instead of popping on.
func _process(delta: float) -> void:
	if _released:
		return
	if _appear < 1.0:
		_appear = minf(1.0, _appear + delta / APPEAR_S)
		_param("fade", _appear)
	if _light != null and is_instance_valid(_light):
		var t := Time.get_ticks_msec() * 0.001
		_light.light_energy = (0.5 + 2.4 * progress) * _appear * (0.86 + 0.14 * sin(t * 17.0) * sin(t * 7.3))

func _material() -> ShaderMaterial:
	if _disc == null or not is_instance_valid(_disc) or not (_disc.mesh is CylinderMesh):
		return null
	return (_disc.mesh as CylinderMesh).material as ShaderMaterial

func _param(parameter: String, value: Variant) -> void:
	var material := _material()
	if material != null:
		material.set_shader_parameter(parameter, value)

## Driven by the replicated telegraph each frame: `progress` goes 0 -> 1 across
## start_tick -> release_tick, so the fire's reach is exactly the authority's
## countdown. The embers thicken with it.
func set_progress(p: float) -> void:
	if _released:
		return
	progress = clampf(p, 0.0, 1.0)
	_param("progress", progress)
	RisingMotes.set_rate(_embers, 0.3 + 0.7 * progress)

## The attack fired: the fire flashes, a blast runs out to the boundary, embers
## are thrown up, and it is gone. The disc goes with it, whichever made it (a
## creature hands its disc over on release).
func release() -> void:
	if _released:
		return
	_released = true
	_param("progress", 1.0)
	_param("flash", 1.0)
	_param("fade", 1.0)
	if _embers != null and is_instance_valid(_embers):
		_embers.emitting = false
	if not _held and QualityPreset.current() != "low":
		var burst := RisingMotes.make(_reach(), _sector(), colour, 46, 0.95, Vector2(1.6, 4.6), Vector2(0.012, 0.034), true)
		add_child(burst)
		burst.emitting = true
		_layers["burst"] = burst
	var tween := create_tween()
	tween.set_parallel(true)
	var material := _material()
	if material != null:
		tween.tween_property(material, "shader_parameter/shock", 1.0, BLAST_S).from(0.001).set_ease(Tween.EASE_OUT).set_trans(Tween.TRANS_QUAD)
		tween.tween_property(material, "shader_parameter/flash", 0.0, BLAST_S).set_ease(Tween.EASE_OUT)
		tween.tween_property(material, "shader_parameter/fade", 0.0, BLAST_S).set_ease(Tween.EASE_IN).set_trans(Tween.TRANS_QUAD)
	if _light != null and is_instance_valid(_light):
		_light.light_energy = 5.0
		tween.tween_property(_light, "light_energy", 0.0, BLAST_S)
	tween.tween_interval(BLAST_S)
	tween.set_parallel(false)
	tween.tween_interval(AFTERGLOW_S)
	tween.tween_callback(_end)

func _end() -> void:
	clear()
	if not _own_disc and _disc != null and is_instance_valid(_disc):
		_disc.queue_free()   # frees this effect with it

## Remove the picture (a held patch that ran out); the node itself is freed by
## whoever made it.
func clear() -> void:
	for key in _layers:
		var node = _layers[key]
		if is_instance_valid(node):
			node.queue_free()
	_layers.clear()
	_embers = null
	_light = null
	if _own_disc and _disc != null and is_instance_valid(_disc):
		_disc.queue_free()
		_disc = null
	_stop_cues()

func set_colour(c: Color) -> void:
	colour = c
	_param("tint", c)
	if _light != null and is_instance_valid(_light):
		_light.light_color = c
	RisingMotes.set_colour(_embers, c)

func _play_cue(sound_id: String, _delay: float) -> void:
	var manager := get_node_or_null("/root/AudioManager")
	if manager == null or not is_inside_tree():
		return
	if _audio == null:
		_audio = manager.call("play_sound_at", sound_id, global_position, self)
	else:
		manager.call("play_sound_at", sound_id, global_position, self)

func _stop_cues() -> void:
	if _audio != null and is_instance_valid(_audio):
		get_node("/root/AudioManager").call("stop_player", _audio)
		_audio = null

func _exit_tree() -> void:
	_stop_cues()

## Presentation description used by the checks.
func describe() -> Dictionary:
	return {"kind": kind, "radius": radius, "range": range_length,
		"layers": _layers.size() + (1 if _disc != null else 0), "progress": progress, "colour": colour}
