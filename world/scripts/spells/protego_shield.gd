extends Area3D

## Protego Shield - the spell effects layered ward.
##
## This is the ONE place a solid shell is correct (12.3): the mesh is the
## authored `shield_shell.glb`, and it is entirely presentation. The rule it
## presents is the tooltip's and the authority's rule, unchanged: projectiles
## that strike the ward are REFLECTED, all other damage is REDUCED BY 60%
## (`other_damage_multiplier: 0.4` in spells.json, evaluated in the authority).
## Nothing here decides any of that - the projectile and the server do.
##
## Layers: the shell with a flowing noise field and a bright rim, a ward glyph
## rune band, a positional impact ripple per hit, an expiration fracture
## (erosion dissolve), a restrained light and the raise/hum/ping/collapse audio.

const VFX = preload("res://scripts/spells/vfx_library.gd")
const SHADER_ALPHA := "res://assets/shaders/spell_layer.gdshader"
const SHADER_ADD := "res://assets/shaders/spell_layer_add.gdshader"

@export var duration: float = 3.5
var caster: Node3D = null
var elapsed: float = 0.0
var hits_absorbed: int = 0

var _shell: MeshInstance3D
var _glyph: MeshInstance3D
var _light: OmniLight3D
var _fracturing := false
var _quality := "high"
var _audio_player: Node = null
var _hits_root: Node3D

@onready var mesh: MeshInstance3D = $MeshInstance3D
@onready var light: OmniLight3D = $OmniLight3D

const MAX_RIPPLES := 4


func setup(p_caster: Node3D) -> void:
	caster = p_caster
	_quality = preload("res://scripts/world/quality_preset.gd").current()
	_build_layers()
	area_entered.connect(_on_projectile_entered)
	_start_audio()


func _build_layers() -> void:
	var colour := VFX.spell_colour("protego")
	if mesh != null:
		var packed: PackedScene = load(VFX.asset_path("vfx_shield_mesh"))
		if packed != null:
			var shell_source := packed.instantiate()
			var source_mesh := _find_mesh(shell_source)
			if source_mesh != null:
				mesh.mesh = source_mesh.mesh
			shell_source.free()
		# flowing noise + rim: a ward reads as a surface with motion in it
		var material := ShaderMaterial.new()
		material.shader = load(SHADER_ALPHA)
		material.set_shader_parameter("atlas", load(VFX.asset_path("vfx_noise_flow")))
		material.set_shader_parameter("grid", Vector2.ONE)
		material.set_shader_parameter("billboard", false)
		material.set_shader_parameter("tint", Color(colour.r, colour.g, colour.b, 0.26))
		material.set_shader_parameter("opacity", 0.85)
		material.set_shader_parameter("soft_fade", 0.0)
		mesh.material_override = material
		_shell = mesh
	# ward glyph band on the ground under the caster
	var quad := QuadMesh.new()
	quad.size = Vector2(4.2, 4.2)
	var glyph_material := ShaderMaterial.new()
	glyph_material.shader = load(SHADER_ADD)
	glyph_material.set_shader_parameter("atlas", load(VFX.asset_path("vfx_rune_masks")))
	glyph_material.set_shader_parameter("grid", Vector2(2, 2))
	glyph_material.set_shader_parameter("frame", 3.0)
	glyph_material.set_shader_parameter("billboard", false)
	glyph_material.set_shader_parameter("tint", colour)
	glyph_material.set_shader_parameter("opacity", 0.5)
	glyph_material.set_shader_parameter("soft_fade", 0.0)
	quad.material = glyph_material
	_glyph = MeshInstance3D.new()
	_glyph.name = "WardGlyph"
	_glyph.mesh = quad
	_glyph.rotation = Vector3(-PI * 0.5, 0.0, 0.0)
	_glyph.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	add_child(_glyph)
	_hits_root = Node3D.new()
	_hits_root.name = "ImpactRipples"
	add_child(_hits_root)
	if light != null:
		light.light_color = colour
		_light = light


func _find_mesh(node: Node) -> MeshInstance3D:
	if node is MeshInstance3D and (node as MeshInstance3D).mesh != null:
		return node as MeshInstance3D
	for child in node.get_children():
		var found := _find_mesh(child)
		if found != null:
			return found
	return null


func _process(delta: float) -> void:
	elapsed += delta
	if is_instance_valid(caster):
		global_position = caster.global_position + Vector3(0, 1.0, 0)
	rotate_y(delta * 0.6)
	if elapsed >= duration:
		_expire()
		return
	else:
		var pulse := (sin(elapsed * 8.0) * 0.2) + 0.8
		if _light:
			# a restrained pulse: never a strobing light over the player's eyes
			_light.light_energy = (1.6 if _quality != "low" else 0.0) * pulse
		if _shell:
			var material := _shell.material_override as ShaderMaterial
			if material != null:
				# the noise field scrolls by driving the frame uniform through the
				# 1x1 grid - the flow texture is static data, so the motion is
				# the ward breathing rather than a texture crawl
				material.set_shader_parameter("opacity", 0.7 + 0.25 * pulse)
		# ripples are presentation of hits the authority already resolved
		for ripple in _hits_root.get_children():
			ripple.set_meta("age", float(ripple.get_meta("age", 0.0)) + delta)
			var age := float(ripple.get_meta("age", 0.0))
			var life := float(ripple.get_meta("life", 0.65))
			var material := (ripple as MeshInstance3D).mesh.surface_get_material(0) as ShaderMaterial
			if material != null:
				material.set_shader_parameter("opacity", clampf(1.0 - age / life, 0.0, 1.0))
				material.set_shader_parameter("frame", floor(clampf(age / life, 0.0, 0.999) * 16.0))
			if age >= life:
				ripple.queue_free()


## A projectile reached the ward. The reflection itself is decided elsewhere
## (spell_projectile / the authority); this is the positional ping.
func _on_projectile_entered(area: Area3D) -> void:
	if not area.is_in_group("projectiles"):
		return
	on_hit(area.global_position)


## Presentation of one absorbed hit: a localized ripple, a brief light, the cue.
func on_hit(point: Vector3) -> void:
	if _fracturing:
		return
	hits_absorbed += 1
	if _hits_root.get_child_count() >= MAX_RIPPLES:
		_hits_root.get_child(0).queue_free()
	var quad := QuadMesh.new()
	quad.size = Vector2(0.9, 0.9)
	var material := ShaderMaterial.new()
	material.shader = load(SHADER_ADD)
	material.set_shader_parameter("atlas", load(VFX.asset_path("vfx_shield_ripple")))
	material.set_shader_parameter("grid", Vector2(4, 4))
	material.set_shader_parameter("frame", 0.0)
	material.set_shader_parameter("billboard", true)
	material.set_shader_parameter("tint", VFX.spell_colour("protego"))
	material.set_shader_parameter("opacity", 1.0)
	material.set_shader_parameter("soft_fade", 0.0)
	quad.material = material
	var ripple := MeshInstance3D.new()
	ripple.name = "Ripple"
	ripple.mesh = quad
	ripple.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	_hits_root.add_child(ripple)
	ripple.global_position = point
	ripple.set_meta("age", 0.0)
	ripple.set_meta("life", 0.65)
	if _light:
		_light.light_energy = 3.2
	_play_sound("spell_protego_impact", point)


## Expiration: the ward fractures (the erosion dissolve reads the same noise map
## the atlases were eroded with) and then clears.
func _expire() -> void:
	if _fracturing:
		return
	_fracturing = true
	if _shell:
		var material := _shell.material_override as ShaderMaterial
		if material != null:
			material.set_shader_parameter("erosion", load(VFX.asset_path("vfx_noise_erosion")))
			material.set_shader_parameter("erode", 0.05)
	# a short fracture beat, then the shell is gone
	var fracture := create_tween()
	fracture.tween_method(_set_fracture, 0.05, 1.0, 0.45)
	fracture.tween_callback(_finish)


func _set_fracture(v: float) -> void:
	if _shell == null:
		return
	var material := _shell.material_override as ShaderMaterial
	if material == null:
		return
	material.set_shader_parameter("erode", v)
	material.set_shader_parameter("tint", Color(0.55, 0.85, 1.0, 0.4 * (1.0 - v)))


func _start_audio() -> void:
	if not has_node("/root/AudioManager"):
		return
	var manager := get_node("/root/AudioManager")
	manager.call("play_sound_at", "spell_protego_cast", global_position, self)
	_audio_player = manager.call("loop_sound", "spell_protego_sustain", self, 0.0)


func _play_sound(key: String, at: Vector3) -> void:
	if has_node("/root/AudioManager"):
		get_node("/root/AudioManager").call("play_sound_at", key, at, self)


func _finish() -> void:
	_stop_audio()
	if has_node("/root/AudioManager"):
		get_node("/root/AudioManager").call("play_sound_at", "spell_protego_end", global_position, self)
	queue_free()


func _stop_audio() -> void:
	if has_node("/root/AudioManager"):
		get_node("/root/AudioManager").call("stop_sound", "spell_protego_sustain", self)


func _exit_tree() -> void:
	_stop_audio()


## Presentation description for the checks.
func describe() -> Dictionary:
	return {"duration": duration, "elapsed": elapsed, "hits": hits_absorbed,
		"shell": _shell != null and _shell.mesh != null, "fracturing": _fracturing}
