extends Node3D
class_name LevelUpFX

## The level-up moment: a golden light pillar and a rising sparkle helix around
## the character, a rune seal and shockwave on the ground, a warm light pulse,
## and a big "LEVEL N" banner on screen.
##
## Presentation only - the authority already applied the level. One call from
## the feedback layer (`LevelUpFX.play(player, level, overlay)`) does all of it.
## Art: fal.ai Wan 3.0 clips packed by tools/vfx/build_spell_vfx.py
## (vfx_levelup_pillar / vfx_levelup_spiral); the sound is ui_levelup.

const QualityPreset = preload("res://scripts/world/quality_preset.gd")
const SHADER_ADD := "res://assets/shaders/spell_layer_add.gdshader"
const PILLAR := "res://assets/vfx/atlases/levelup_pillar_8x8_1k.png"
const SPIRAL := "res://assets/vfx/atlases/levelup_spiral_8x8_1k.png"
const SHOCKWAVE := "res://assets/vfx/atlases/shockwave_8x8_1k.png"
const RUNE := "res://assets/vfx/tex/rune_seal_512.png"
const FLARE := "res://assets/vfx/tex/star_flare_256.png"
const GOLD := Color(1.0, 0.82, 0.38)
const LENGTH := 3.2
const FPS := 22.0

var target: Node3D
var quality := "high"
var _age := 0.0
## {node, kind, delay, ...} - ticked in _process.
var _layers: Array = []
var _light: OmniLight3D

## Spawn the whole moment. `overlay` is a full-rect Control for the banner;
## either half is skipped when its anchor is missing.
static func play(player: Node3D, level: int, overlay: Control = null) -> Node3D:
	if overlay != null and is_instance_valid(overlay):
		_banner(overlay, level)
	if player == null or not is_instance_valid(player) or not player.is_inside_tree():
		return null
	# several levels from one reward arrive in one frame: one pillar is enough
	for child in player.get_parent().get_children():
		if child is LevelUpFX and (child as LevelUpFX).target == player and (child as LevelUpFX)._age < 0.5:
			return child
	var fx := LevelUpFX.new()
	fx.name = "LevelUpFX"
	fx.target = player
	fx.quality = QualityPreset.current()
	player.get_parent().add_child(fx)
	fx.global_position = player.global_position
	fx._build()
	return fx

func _build() -> void:
	var full := quality != "low"
	# core (every preset): pillar, helix, rune seal
	_add_flipbook(PILLAR, 4.2, 1.95, 0.0)
	_add_flipbook(SPIRAL, 3.0, 1.35, 0.15)
	_add_flat(RUNE, Vector2(0.8, 2.8), 0.0, 2.4, true)
	if full:
		_add_flat(SHOCKWAVE, Vector2(3.6, 3.6), 0.05, 64.0 / 33.0, false)
		_add_particles()
	_light = OmniLight3D.new()
	_light.light_color = GOLD
	_light.omni_range = 6.0
	_light.light_energy = 0.0
	_light.shadow_enabled = false
	_light.position = Vector3(0, 1.4, 0)
	add_child(_light)

func _material(texture_path: String, grid: Vector2, billboard: bool) -> ShaderMaterial:
	var material := ShaderMaterial.new()
	material.shader = load(SHADER_ADD)
	material.set_shader_parameter("atlas", load(texture_path))
	material.set_shader_parameter("grid", grid)
	material.set_shader_parameter("frame", 0.0)
	material.set_shader_parameter("billboard", billboard)
	material.set_shader_parameter("tint", Color.WHITE)
	material.set_shader_parameter("opacity", 1.0)
	material.set_shader_parameter("soft_fade", 0.35)
	return material

## An upright flipbook that turns to face the camera around the vertical axis
## only, so the column stays a column under the high MMO camera.
func _add_flipbook(path: String, size: float, height: float, delay: float) -> void:
	var quad := QuadMesh.new()
	quad.size = Vector2(size, size)
	quad.material = _material(path, Vector2(8, 8), false)
	var node := MeshInstance3D.new()
	node.mesh = quad
	node.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	node.position = Vector3(0, height, 0)
	node.visible = delay <= 0.0
	add_child(node)
	_layers.append({"node": node, "kind": "flipbook", "delay": delay, "material": quad.material})

## A ground layer: either a still that grows/spins (rune) or a flipbook.
func _add_flat(path: String, sizes: Vector2, delay: float, life: float, still: bool) -> void:
	var quad := QuadMesh.new()
	quad.size = Vector2.ONE
	var material := _material(path, Vector2.ONE if still else Vector2(8, 8), false)
	material.set_shader_parameter("soft_fade", 0.0)
	material.set_shader_parameter("tint", GOLD if not still else Color(1.0, 0.88, 0.5))
	quad.material = material
	var node := MeshInstance3D.new()
	node.mesh = quad
	node.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	node.rotation = Vector3(-PI * 0.5, 0.0, 0.0)
	node.position = Vector3(0, 0.06 if still else 0.08, 0)
	node.scale = Vector3.ONE * sizes.x
	node.visible = delay <= 0.0
	add_child(node)
	_layers.append({"node": node, "kind": "rune" if still else "ring", "delay": delay,
		"life": life, "sizes": sizes, "material": material})

func _add_particles() -> void:
	var particles := GPUParticles3D.new()
	particles.amount = 20
	particles.lifetime = 1.8
	particles.one_shot = true
	particles.explosiveness = 0.7
	particles.randomness = 0.6
	particles.local_coords = false
	particles.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	var quad := QuadMesh.new()
	quad.size = Vector2(0.18, 0.18)
	var material := StandardMaterial3D.new()
	material.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	material.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	material.blend_mode = BaseMaterial3D.BLEND_MODE_ADD
	material.billboard_mode = BaseMaterial3D.BILLBOARD_ENABLED
	material.vertex_color_use_as_albedo = true
	material.albedo_texture = load(FLARE)
	quad.material = material
	particles.draw_pass_1 = quad
	var process := ParticleProcessMaterial.new()
	process.emission_shape = ParticleProcessMaterial.EMISSION_SHAPE_RING
	process.emission_ring_axis = Vector3.UP
	process.emission_ring_radius = 0.9
	process.emission_ring_inner_radius = 0.5
	process.emission_ring_height = 0.1
	process.direction = Vector3.UP
	process.spread = 12.0
	process.initial_velocity_min = 1.6
	process.initial_velocity_max = 3.0
	process.gravity = Vector3(0, 0.4, 0)
	process.scale_min = 0.6
	process.scale_max = 1.5
	process.color = GOLD
	var gradient := Gradient.new()
	gradient.set_color(0, Color(1, 1, 1, 1))
	gradient.set_color(1, Color(1, 1, 1, 0))
	var ramp := GradientTexture1D.new()
	ramp.gradient = gradient
	process.color_ramp = ramp
	particles.process_material = process
	add_child(particles)
	particles.position = Vector3(0, 0.1, 0)
	particles.emitting = true

func _process(delta: float) -> void:
	_age += delta
	if target != null and is_instance_valid(target) and target.is_inside_tree():
		global_position = target.global_position
	var camera := get_viewport().get_camera_3d()
	for entry in _layers:
		_tick(entry, camera)
	if _light != null:
		# a quick warm swell, then a long falloff
		var swell := clampf(_age / 0.15, 0.0, 1.0)
		var fall := clampf(1.0 - (_age - 0.3) / 1.6, 0.0, 1.0)
		_light.light_energy = 3.0 * minf(swell, fall)
	if _age >= LENGTH:
		queue_free()

func _tick(entry: Dictionary, camera: Camera3D) -> void:
	var node: MeshInstance3D = entry["node"]
	var t := _age - float(entry["delay"])
	node.visible = t >= 0.0
	if t < 0.0:
		return
	var material: ShaderMaterial = entry["material"]
	match String(entry["kind"]):
		"flipbook":
			var frame := minf(t * FPS, 63.0)
			material.set_shader_parameter("frame", frame)
			# hold the last frames out: fade over the tail of the clip
			material.set_shader_parameter("opacity", clampf((63.0 - frame) / 10.0, 0.0, 1.0))
			if camera != null:
				var to_cam := camera.global_position - node.global_position
				node.global_rotation = Vector3(0.0, atan2(to_cam.x, to_cam.z), 0.0)
		"rune":
			var life := float(entry["life"])
			var k := clampf(t / life, 0.0, 1.0)
			var sizes: Vector2 = entry["sizes"]
			node.scale = Vector3.ONE * lerpf(sizes.x, sizes.y, 1.0 - pow(1.0 - minf(k * 2.5, 1.0), 3.0))
			node.rotation.y = t * 0.9
			var fade_in := clampf(t / 0.15, 0.0, 1.0)
			material.set_shader_parameter("opacity", fade_in * clampf((1.0 - k) / 0.45, 0.0, 1.0))
		"ring":
			var life := float(entry["life"])
			material.set_shader_parameter("frame", minf(t / life * 64.0, 63.0))

# ------------------------------------------------------------------- banner

## The on-screen moment: a gold flash and a big "LEVEL N" that punches in,
## holds and fades. A second level in the same frame updates the live banner.
static func _banner(overlay: Control, level: int) -> void:
	var live := overlay.get_node_or_null("LevelUpBanner")
	if live != null:
		var title := live.get_node_or_null("Box/Title") as Label
		if title != null:
			title.text = I18n.upper(I18n.t("Level %d") % level)
		return
	var root := Control.new()
	root.name = "LevelUpBanner"
	root.mouse_filter = Control.MOUSE_FILTER_IGNORE
	root.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	overlay.add_child(root)

	var flash := ColorRect.new()
	flash.mouse_filter = Control.MOUSE_FILTER_IGNORE
	flash.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	flash.color = Color(1.0, 0.8, 0.35, 0.16)
	var flash_material := CanvasItemMaterial.new()
	flash_material.blend_mode = CanvasItemMaterial.BLEND_MODE_ADD
	flash.material = flash_material
	root.add_child(flash)

	var box := VBoxContainer.new()
	box.name = "Box"
	box.mouse_filter = Control.MOUSE_FILTER_IGNORE
	box.alignment = BoxContainer.ALIGNMENT_CENTER
	box.add_theme_constant_override("separation", 0)
	box.anchor_left = 0.0
	box.anchor_right = 1.0
	box.anchor_top = 0.2
	box.anchor_bottom = 0.2
	box.offset_top = -10
	box.offset_bottom = 110
	root.add_child(box)

	var glow := TextureRect.new()
	glow.mouse_filter = Control.MOUSE_FILTER_IGNORE
	glow.texture = load(FLARE)
	glow.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	glow.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
	glow.modulate = Color(1.0, 0.8, 0.4, 0.55)
	var glow_material := CanvasItemMaterial.new()
	glow_material.blend_mode = CanvasItemMaterial.BLEND_MODE_ADD
	glow.material = glow_material
	glow.anchor_left = 0.5
	glow.anchor_right = 0.5
	glow.anchor_top = 0.2
	glow.anchor_bottom = 0.2
	glow.offset_left = -260
	glow.offset_right = 260
	glow.offset_top = -110
	glow.offset_bottom = 160
	glow.pivot_offset = Vector2(260, 135)
	root.add_child(glow)
	root.move_child(glow, 1)

	var kicker := Label.new()
	kicker.text = I18n.upper(I18n.t("Level up"))
	kicker.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	kicker.add_theme_font_override("font", UITheme.font_title())
	kicker.add_theme_font_size_override("font_size", UITheme.FS_HEADER)
	kicker.add_theme_color_override("font_color", Color(1.0, 0.93, 0.75))
	kicker.add_theme_color_override("font_outline_color", Color(0.18, 0.1, 0.02, 0.9))
	kicker.add_theme_constant_override("outline_size", 6)
	box.add_child(kicker)

	var title := Label.new()
	title.name = "Title"
	title.text = I18n.upper(I18n.t("Level %d") % level)
	title.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	title.add_theme_font_override("font", UITheme.font_title())
	title.add_theme_font_size_override("font_size", 64)
	title.add_theme_color_override("font_color", Color(1.0, 0.86, 0.42))
	title.add_theme_color_override("font_outline_color", Color(0.25, 0.12, 0.0, 0.95))
	title.add_theme_constant_override("outline_size", 12)
	title.add_theme_color_override("font_shadow_color", Color(1.0, 0.7, 0.2, 0.55))
	title.add_theme_constant_override("shadow_offset_x", 0)
	title.add_theme_constant_override("shadow_offset_y", 0)
	title.add_theme_constant_override("shadow_outline_size", 28)
	box.add_child(title)

	root.modulate.a = 0.0
	box.pivot_offset = Vector2(overlay.size.x * 0.5, 60)
	box.scale = Vector2(1.5, 1.5)
	var tween := root.create_tween()
	tween.set_parallel(true)
	tween.tween_property(root, "modulate:a", 1.0, 0.18)
	tween.tween_property(box, "scale", Vector2.ONE, 0.35).set_trans(Tween.TRANS_BACK).set_ease(Tween.EASE_OUT)
	tween.tween_property(flash, "color:a", 0.0, 0.6).set_delay(0.08)
	tween.tween_property(glow, "rotation", 0.6, 2.6)
	tween.set_parallel(false)
	tween.tween_interval(1.9)
	tween.tween_property(root, "modulate:a", 0.0, 0.6)
	tween.tween_callback(root.queue_free)
