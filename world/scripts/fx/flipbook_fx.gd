extends Node3D
class_name FlipbookFX

## Layered flipbook effects outside the spell system (travel, ambience):
## upright quads that turn to the camera around the vertical axis (so a column
## stays a column under the high MMO camera) or flat ground quads, each reading
## one 8x8 atlas (assets/vfx/atlases, built by tools/vfx/build_spell_vfx.py),
## plus an optional light pulse and a sound. One-shot effects free themselves;
## looping ones (an aura, drifting spores) live until their parent goes.
##
##   FlipbookFX.play(parent, at, [{atlas, size, height, fps, delay, tint,
##       flat, loop, opacity, roll}], {life, light, light_energy, sound})

const SHADER_ADD := preload("res://assets/shaders/spell_layer_add.gdshader")
const ATLAS := "res://assets/vfx/atlases/%s.png"

var _layers: Array = []
var _age := 0.0
var _life := 3.0
var _light: OmniLight3D = null
var _light_energy := 0.0
var follow: Node3D = null

static func play(parent: Node, at: Vector3, layers: Array, opts: Dictionary = {}) -> FlipbookFX:
	if parent == null or not parent.is_inside_tree() or NetworkManager.is_dedicated_server:
		return null   # pictures only; the dedicated server draws nothing
	var fx := FlipbookFX.new()
	fx.name = String(opts.get("name", "FlipbookFX"))
	fx._life = float(opts.get("life", 3.0))
	parent.add_child(fx)
	fx.global_position = at
	if opts.has("rotation_y"):
		fx.rotation.y = float(opts["rotation_y"])
	for layer in layers:
		fx._add_layer(layer)
	if opts.has("light"):
		fx._light = OmniLight3D.new()
		fx._light.light_color = opts["light"]
		fx._light.omni_range = float(opts.get("light_range", 8.0))
		fx._light.shadow_enabled = false
		fx._light.position = Vector3(0, float(opts.get("light_height", 1.4)), 0)
		fx._light.light_energy = 0.0
		fx._light_energy = float(opts.get("light_energy", 4.0))
		fx.add_child(fx._light)
	if opts.has("sound"):
		var audio := parent.get_node_or_null("/root/AudioManager")
		if audio != null and audio.has_method("play_sound_at"):
			audio.call("play_sound_at", String(opts["sound"]), at, null, false)
	return fx

func _add_layer(layer: Dictionary) -> void:
	var material := ShaderMaterial.new()
	material.shader = SHADER_ADD
	# `texture` (a still, full path) or `atlas` (an 8x8 flipbook name).
	var still := layer.has("texture")
	material.set_shader_parameter("atlas", load(String(layer["texture"]) if still else ATLAS % String(layer.get("atlas", ""))))
	material.set_shader_parameter("grid", Vector2.ONE if still else Vector2(8, 8))
	material.set_shader_parameter("frame", 0.0)
	material.set_shader_parameter("billboard", false)
	material.set_shader_parameter("tint", layer.get("tint", Color.WHITE))
	material.set_shader_parameter("opacity", 0.0)
	material.set_shader_parameter("soft_fade", 0.0 if bool(layer.get("flat", false)) else 0.35)
	material.set_shader_parameter("roll", float(layer.get("roll", 0.0)))
	var quad := QuadMesh.new()
	var size: Variant = layer.get("size", 2.0)
	quad.size = size if size is Vector2 else Vector2(float(size), float(size))
	quad.material = material
	var node := MeshInstance3D.new()
	node.mesh = quad
	node.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	node.position = layer.get("offset", Vector3(0, float(layer.get("height", 1.0)), 0))
	if bool(layer.get("flat", false)):
		node.rotation = Vector3(-PI * 0.5, 0.0, 0.0)
	node.visible = false
	add_child(node)
	_layers.append({"node": node, "material": material, "delay": float(layer.get("delay", 0.0)),
		"fps": float(layer.get("fps", 22.0)), "loop": bool(layer.get("loop", false)),
		"flat": bool(layer.get("flat", false)), "opacity": float(layer.get("opacity", 1.0)),
		"fade_in": float(layer.get("fade_in", 0.08)), "still": still, "spin": float(layer.get("spin", 0.0))})

func _process(delta: float) -> void:
	_age += delta
	if follow != null and is_instance_valid(follow) and follow.is_inside_tree():
		global_position = follow.global_position
	var camera := get_viewport().get_camera_3d()
	for entry in _layers:
		var node: MeshInstance3D = entry["node"]
		var t := _age - float(entry["delay"])
		node.visible = t >= 0.0
		if t < 0.0:
			continue
		var material: ShaderMaterial = entry["material"]
		var frame := 0.0 if bool(entry["still"]) else t * float(entry["fps"])
		var fade_in := clampf(t / maxf(0.001, float(entry["fade_in"])), 0.0, 1.0)
		var opacity := float(entry["opacity"]) * fade_in
		if bool(entry["still"]):
			if _life > 0.0:
				opacity *= clampf((_life - _age) / 0.6, 0.0, 1.0)
			node.rotation.y = t * float(entry["spin"])
		elif bool(entry["loop"]):
			frame = fmod(frame, 64.0)
			if _life > 0.0 and _age > _life - 0.6:
				opacity *= clampf((_life - _age) / 0.6, 0.0, 1.0)
		else:
			frame = minf(frame, 63.0)
			opacity *= clampf((63.0 - frame) / 8.0, 0.0, 1.0)
		material.set_shader_parameter("frame", frame)
		material.set_shader_parameter("opacity", opacity)
		if not bool(entry["flat"]) and camera != null:
			var to_cam := camera.global_position - node.global_position
			node.global_rotation = Vector3(0.0, atan2(to_cam.x, to_cam.z), 0.0)
	if _light != null:
		var swell := clampf(_age / 0.2, 0.0, 1.0)
		var fall := 1.0 if _life <= 0.0 else clampf((_life - _age) / maxf(0.3, _life * 0.5), 0.0, 1.0)
		_light.light_energy = _light_energy * minf(swell, fall)
	if _life > 0.0 and _age >= _life:
		queue_free()
