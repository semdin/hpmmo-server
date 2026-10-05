extends Node3D

## Phase 12 boss warning: a layered ground effect whose timing is the
## authoritative telegraph's, never a client guess.
##
## The shape and the countdown come straight from the replicated telegraph
## (`MSG_TELEGRAPH` / the entity record's `telegraph` dict): `start_tick`,
## `release_tick`, `kind` and the hit area's `radius`/`range`/`half_angle`. The
## effect is only the presentation of that data - it cannot move the release
## tick, and `set_progress()` is driven by the same `sim_tick` the authority
## scheduled the damage on, so what the player sees is what the server will do.
##
## Layers (plan.md 12.3 last row): the ground mask matching the hit area, an
## edge ring, a countdown ring that fills to the release tick, rim motes so it
## stays readable in a crowd, a pulse light and the charge/release audio.

const VFX = preload("res://scripts/spells/vfx_library.gd")
const SHADER_ADD := "res://assets/shaders/spell_layer_add.gdshader"
const SHADER_ALPHA := "res://assets/shaders/spell_layer.gdshader"
const QualityPreset = preload("res://scripts/world/quality_preset.gd")

var kind := "area"
var radius := 5.5
var range_length := 8.0
var half_angle := 0.6
var colour := Color(1.0, 0.25, 0.08)
var progress := 0.0
var _layers := {}
var _released := false
var _audio: Node = null

const CHARGE_SOUND := "boss_slam_cast"
const RELEASE_SOUND := "boss_slam_release"


## `data` is the telegraph dictionary exactly as replicated.
func setup(data: Dictionary) -> void:
	kind = String(data.get("kind", "area"))
	radius = float(data.get("radius", 5.5))
	range_length = float(data.get("range", 8.0))
	half_angle = float(data.get("half_angle", 0.6))
	_build()
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

func _build() -> void:
	var quality := QualityPreset.current()
	var light_allowed := quality != "low"
	# The hit-area mask itself stays the parent mob's own mesh: it carries the
	# authoritative radius (the multiplayer probe reads `mesh.top_radius` from
	# it), so this effect layers ON it rather than duplicating it.
	var shape_size := radius * 2.0 if kind != "directional" else range_length * 2.0
	# 2) edge ring (the boundary the player must leave)
	var edge := _make_quad(SHADER_ADD, "vfx_rune_masks", 0, shape_size * 1.04, 0.09)
	edge.name = "EdgeRing"
	edge.set_meta("base_scale", Vector3.ONE)
	_layers["edge"] = edge
	# 3) countdown ring: fills from the start tick to the release tick
	var countdown := _make_quad(SHADER_ADD, "vfx_rune_masks", 1, shape_size * 0.86, 0.11)
	countdown.name = "CountdownRing"
	_layers["countdown"] = countdown
	# 4) a scorched ground mark so the area is visible even with glow disabled
	var mark := _make_quad(SHADER_ALPHA, "vfx_ground_marks", 3, shape_size * 1.02, 0.05)
	mark.name = "GroundMark"
	_layers["mark"] = mark
	# 5) rim motes: readable in a crowd, never in the middle where they would
	#    hide the player's own feet
	if quality != "low":
		var motes := GPUParticles3D.new()
		motes.name = "RimMotes"
		motes.amount = 12
		motes.lifetime = 0.8
		motes.local_coords = false
		motes.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		var quad := QuadMesh.new()
		quad.size = Vector2(0.09, 0.09)
		var pmat := StandardMaterial3D.new()
		pmat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
		pmat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
		pmat.blend_mode = BaseMaterial3D.BLEND_MODE_ADD
		pmat.billboard_mode = BaseMaterial3D.BILLBOARD_ENABLED
		pmat.albedo_texture = load(VFX.asset_path("vfx_spark_static"))
		pmat.albedo_color = colour
		quad.material = pmat
		motes.draw_pass_1 = quad
		var process := ParticleProcessMaterial.new()
		process.emission_shape = ParticleProcessMaterial.EMISSION_SHAPE_RING
		process.emission_ring_radius = maxf(0.4, radius * 0.92)
		process.emission_ring_inner_radius = maxf(0.3, radius * 0.80)
		process.emission_ring_axis = Vector3.UP
		process.direction = Vector3.UP
		process.spread = 20.0
		process.initial_velocity_min = 0.3
		process.initial_velocity_max = 0.9
		process.gravity = Vector3(0, 0.3, 0)
		process.color = colour
		motes.process_material = process
		add_child(motes)
		motes.emitting = true
		_layers["motes"] = motes
	# 6) a restrained pulse light, off on the reduced preset
	if light_allowed:
		var light := OmniLight3D.new()
		light.name = "WarningLight"
		light.light_color = colour
		light.light_energy = 1.4
		light.omni_range = maxf(4.0, radius * 1.6)
		light.shadow_enabled = false
		add_child(light)
		light.position = Vector3(0, 0.6, 0)
		_layers["light"] = light

func _make_quad(shader_path: String, asset_id: String, frame: int, size: float, lift: float) -> MeshInstance3D:
	var quad := QuadMesh.new()
	quad.size = Vector2(size, size)
	var material := ShaderMaterial.new()
	material.shader = load(shader_path)
	material.set_shader_parameter("atlas", load(VFX.asset_path(asset_id)))
	material.set_shader_parameter("grid", VFX.asset(asset_id).get("grid", Vector2.ONE))
	material.set_shader_parameter("frame", float(frame))
	material.set_shader_parameter("billboard", false)
	material.set_shader_parameter("tint", colour)
	material.set_shader_parameter("opacity", 0.0)
	material.set_shader_parameter("soft_fade", 0.0)
	quad.material = material
	var node := MeshInstance3D.new()
	node.mesh = quad
	node.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	node.rotation = Vector3(-PI * 0.5, 0.0, 0.0)
	node.position = Vector3(0, lift, 0)
	add_child(node)
	return node

## Driven by the replicated telegraph each frame: `progress` goes 0 -> 1 across
## start_tick -> release_tick, so the fill is exactly the authority's countdown.
func set_progress(p: float) -> void:
	progress = clampf(p, 0.0, 1.0)
	if _layers.has("edge"):
		_set_opacity(_layers["edge"], 0.25 + 0.60 * progress)
		# the edge pulses faster as the release approaches - a read the player
		# gets even at the lowest quality or with the screen small
		var pulse := 1.0 + 0.035 * sin(Time.get_ticks_msec() * 0.001 * (2.0 + 9.0 * progress))
		_layers["edge"].scale = Vector3(pulse, pulse, 1.0) * (_layers["edge"].get_meta("base_scale", Vector3.ONE))
	if _layers.has("countdown"):
		# the countdown ring "wraps": completed notches read as an arc
		_set_opacity(_layers["countdown"], 0.15 + 0.85 * progress)
	if _layers.has("mark"):
		_set_opacity(_layers["mark"], 0.35)
	if _layers.has("light"):
		_layers["light"].light_energy = 0.8 + 3.0 * progress

func _set_opacity(node: Node3D, value: float) -> void:
	if not (node is MeshInstance3D):
		return
	var material := (node as MeshInstance3D).mesh.surface_get_material(0) as ShaderMaterial
	if material != null:
		material.set_shader_parameter("opacity", clampf(value, 0.0, 1.0))

## The attack fired: flash the shape and clear it immediately.
func release() -> void:
	_released = true
	for key in ["mask", "edge", "countdown"]:
		if _layers.has(key):
			_set_opacity(_layers[key], 0.9)
	var tween := create_tween()
	tween.tween_interval(0.12)
	tween.tween_callback(clear)

func clear() -> void:
	for key in _layers:
		var node = _layers[key]
		if is_instance_valid(node):
			node.queue_free()
	_layers.clear()
	_stop_cues()

func set_colour(c: Color) -> void:
	colour = c
	for key in _layers:
		var node = _layers[key]
		if node is MeshInstance3D:
			var material := (node as MeshInstance3D).mesh.surface_get_material(0) as ShaderMaterial
			if material != null:
				material.set_shader_parameter("tint", c)

func _play_cue(sound_id: String, delay: float) -> void:
	var manager := get_node_or_null("/root/AudioManager")
	if manager == null:
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
		"layers": _layers.size(), "progress": progress, "colour": colour}
