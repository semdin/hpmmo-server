extends Node3D
class_name SpellEffect

## Spell effects reusable effect scene: builds one stage (cast / travel / impact /
## sustain / end) of one spell from the composition table in vfx_library.gd and
## drives its layers over time.
##
## Presentation only. Nothing here touches damage, cooldowns or rewards: the
## authority already decided the outcome before the effect exists, and a late
## animation callback can never produce a second hit. Quality reduction, culling
## and cancellation only ever change what is drawn.
##
## Lifecycle contract (12.4):
##   * `finished` fires when the stage has played out and the node frees itself;
##   * `cancel(reason)` stops emission, fades fast and frees - used by death,
##     map transfer, cast interruption, network rejection and shutdown;
##   * an effect whose caster died or was freed cancels itself in `_process`,
##     so an effect can never outlive its caster;
##   * every audio stream this effect started is stopped on exit.

signal finished(spell_id: String, stage: String)

const VFX = preload("res://scripts/spells/vfx_library.gd")
const SHADER_ALPHA := "res://assets/shaders/spell_layer.gdshader"
const SHADER_ADD := "res://assets/shaders/spell_layer_add.gdshader"
const RIBBON_SHADER := "res://assets/shaders/spell_ribbon.gdshader"

var spell_id := "basic_cast"
var stage := "cast"
var quality := "high"
var caster: Node3D
var direction := Vector3.FORWARD
var base_position := Vector3.ZERO
var follow_target: Node3D
var target_position := Vector3.ZERO
var aoe_radius := 0.0
var cancelled := false

var _layers: Array = []
var _elapsed := 0.0
var _duration := 0.6
var _audio_started: Array[String] = []
var _audio_key := ""
var _audio_manager: Node = null
var _audio_looping := false
## The follow target's position on the last tick. A following effect is
## translated BY the target's motion, so the offset it was authored with - a stun
## halo 1.9 m over the head, an impact placed at chest height - survives the
## first tick. Snapping the effect onto the target's origin instead dropped that
## offset (the halo fell to the caster's feet).
var _follow_anchor := Vector3.ZERO
## Set when the follow target already carries this effect inside its own scene
## tree (the projectile parents its travel stage to `TravelFx`): translating it
## again would apply the motion twice.
var _follow_carried := false
## Set for a travel stage that follows a bolt. The bolt owns that stage and ends
## it by spending, leaving range or being freed; a fixed timer would clip the
## flight short (basic_cast flies 0.9 s, the viewer rehearses up to 3 s).
var _follow_owned := false
var _retiring := false
var _retire_at := 0.0

func _ready() -> void:
	set_process(true)

## The stage's sound. It starts at the end of `setup`, never in `_ready`: the
## emission point is only known once the stage is built, and a sound started on
## `add_child` came out of the world origin instead of the caster's wand. A
## looping stage is kept on the effect afterwards (see `_process`), or the bolt's
## whoosh would stay behind at the point where the loop began.
func _start_audio() -> void:
	if not _audio_started.is_empty():
		return
	_audio_key = _resolve_audio()
	if _audio_key == "" or not has_node("/root/AudioManager"):
		return
	_audio_manager = get_node("/root/AudioManager")
	if bool(_stage_data().get("loop_audio", false)):
		_audio_looping = true
		_audio_manager.call("loop_sound", _audio_key, self, 0.0)
	else:
		_audio_manager.call("play_sound_at", _audio_key, global_position, self)
	_audio_started.append(_audio_key)

func _stage_data() -> Dictionary:
	return VFX.stages_for(spell_id).get(stage, {})

func _resolve_audio() -> String:
	return String(_stage_data().get("audio", ""))

## Build this stage. `opts` may carry follow_target, target_position, aoe_radius
## and duration (an authoritative status length that outranks the table's).
func setup(p_spell: String, p_stage: String, p_quality: String, p_origin: Vector3,
		p_dir: Vector3, p_caster: Node3D = null, opts: Dictionary = {}) -> void:
	spell_id = p_spell
	stage = p_stage
	quality = p_quality
	base_position = p_origin
	global_position = p_origin
	direction = p_dir.normalized() if p_dir.length_squared() > 0.0001 else Vector3.FORWARD
	caster = p_caster
	follow_target = opts.get("follow_target", null)
	target_position = opts.get("target_position", p_origin)
	aoe_radius = float(opts.get("aoe_radius", 0.0))
	if _live(follow_target):
		_follow_anchor = follow_target.global_position
		_follow_carried = follow_target.is_ancestor_of(self)
	var colour := VFX.spell_colour(spell_id)
	var layers := VFX.layers_for(spell_id, stage, quality)
	var authored_length := float(_stage_data().get("length", 0.0))
	# A status effect's authoritative length wins over the authored one, and the
	# layers written to span the whole stage span the requested length with it.
	var requested := float(opts.get("duration", 0.0))
	var offset := 0.0
	for layer in layers:
		var node := _build_layer(layer, colour)
		if node == null:
			continue
		var life := float(layer.get("life", 0.0))
		if requested > 0.0 and authored_length > 0.0 and is_equal_approx(life, authored_length):
			life = requested
			layer["life"] = requested
		offset = float(layer.get("delay", 0.0))
		node.visible = offset <= 0.0
		_layers.append({"node": node, "layer": layer, "born": _elapsed, "offset": offset})
		if life > 0.0:
			_duration = maxf(_duration, life + float(layer.get("delay", 0.0)))
	_duration = maxf(_duration, authored_length)
	_duration = maxf(_duration, 0.2)
	if requested > 0.0:
		_duration = requested
	if stage == "travel":
		if follow_target == null:
			# nobody owns this stage: keep it alive for the projectile's flight
			# estimate instead of one frame
			_duration = maxf(_duration, 2.5)
		else:
			_follow_owned = true
	_start_audio()

# ------------------------------------------------------------------ building

func _build_layer(layer: Dictionary, colour: Color) -> Node3D:
	match String(layer.get("kind", "")):
		"signature":
			var signature := preload("res://scripts/spells/spell_signature_vfx.gd").new()
			signature.name = "SpellSignature"
			add_child(signature)
			var area := aoe_radius if aoe_radius > 0.0 else float(GameData.SPELLS.get(spell_id, {}).get("radius", 0.0))
			signature.configure(spell_id, float(layer.get("life", 0.8)), area)
			signature.setup(stage, quality, direction)
			return signature
		"stupefy_energy":
			var energy := preload("res://scripts/spells/stupefy_vfx.gd").new()
			energy.name = "StupefyEnergy"
			add_child(energy)
			energy.setup(stage, quality, direction)
			return energy
		"flipbook":
			return _build_flipbook(layer, colour)
		"sprite":
			return _build_sprite(layer, colour)
		"particles":
			return _build_particles(layer, colour)
		"mesh":
			return _build_mesh_layer(layer, colour)
		"ribbon":
			return _build_ribbon(layer, colour)
		"light":
			return _build_light(layer, colour)
	return null

func _layer_colour(layer: Dictionary, colour: Color) -> Color:
	if bool(layer.get("colour", false)):
		return colour
	return Color.WHITE

func _material_for(layer: Dictionary, colour: Color) -> ShaderMaterial:
	var additive := String(layer.get("blend", "alpha")) == "add"
	var material := ShaderMaterial.new()
	if layer.has("energy_shape"):
		material.shader = preload("res://assets/shaders/wand_energy.gdshader")
		material.set_shader_parameter("shape", int(layer["energy_shape"]))
		material.set_shader_parameter("tint", _layer_colour(layer, colour))
		material.set_shader_parameter("aim", direction)
		material.set_shader_parameter("opacity", float(layer.get("opacity", 1.0)))
		return material
	material.shader = load(SHADER_ADD if additive else SHADER_ALPHA)
	var entry: Dictionary = VFX.asset(String(layer.get("atlas", layer.get("tex", ""))))
	if layer.has("atlas") and entry.is_empty():
		entry = VFX.asset(String(layer.get("atlas", "")))
	var texture_path := String(entry.get("path", ""))
	if texture_path != "":
		var texture: Texture2D = load(texture_path)
		material.set_shader_parameter("atlas", texture)
	material.set_shader_parameter("grid", entry.get("grid", Vector2.ONE))
	material.set_shader_parameter("frame", float(layer.get("frame", 0)))
	material.set_shader_parameter("billboard", not bool(layer.get("flat", false)))
	material.set_shader_parameter("tint", _layer_colour(layer, colour))
	material.set_shader_parameter("opacity", float(layer.get("opacity", 1.0)))
	material.set_shader_parameter("soft_fade", 0.35 if not bool(layer.get("flat", false)) else 0.0)
	if layer.has("fracture"):
		material.set_shader_parameter("erode", 0.0)
		material.set_shader_parameter("erosion", load(VFX.asset_path("vfx_noise_erosion")))
	return material

func _build_flipbook(layer: Dictionary, colour: Color) -> Node3D:
	var quad := QuadMesh.new()
	var size := float(layer.get("size", 1.0))
	quad.size = Vector2(size * float(layer.get("stretch", 1.0)), size)
	var material := _material_for(layer, colour)
	quad.material = material
	var node := MeshInstance3D.new()
	node.name = "Layer_Flipbook"
	node.mesh = quad
	node.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	add_child(node)
	_place(node, layer, size)
	return node

func _build_sprite(layer: Dictionary, colour: Color) -> Node3D:
	return _build_flipbook(layer, colour)

func _forward_of(layer: Dictionary) -> float:
	## `forward` is metres along the aim direction; `true` means "one metre".
	if not layer.has("forward"):
		return 0.0
	var raw = layer["forward"]
	if typeof(raw) == TYPE_BOOL:
		return 1.0 if bool(raw) else 0.0
	return float(raw)

func _place(node: Node3D, layer: Dictionary, size: float) -> void:
	var forward := _forward_of(layer)
	if bool(layer.get("flat", false)):
		# ground marks lie on the floor and keep the world's up axis
		node.rotation = Vector3(-PI * 0.5, 0.0, 0.0)
		node.global_position = base_position + Vector3.UP * float(layer.get("lift", 0.05))
		if aoe_radius > 0.0 and bool(layer.get("core", false)):
			node.scale = Vector3.ONE * maxf(1.0, aoe_radius * 2.0 / maxf(0.001, size))
	elif bool(layer.get("at_hit", false)):
		node.global_position = target_position
	else:
		node.global_position = base_position + direction * forward
	if bool(layer.get("spin", false)):
		node.set_meta("spin", randf_range(-1.4, 1.4))
	if bool(layer.get("flicker", false)):
		node.set_meta("flicker", true)

func _build_particles(layer: Dictionary, colour: Color) -> Node3D:
	var particles := GPUParticles3D.new()
	particles.name = "Layer_Particles"
	particles.amount = int(layer.get("amount", 12))
	particles.lifetime = float(layer.get("life", 0.5))
	particles.one_shot = true
	if bool(layer.get("continuous", false)):
		particles.one_shot = false
	particles.explosiveness = 0.92
	if not particles.one_shot:
		particles.explosiveness = 0.0
	particles.randomness = 0.8
	particles.local_coords = false
	particles.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	var quad := QuadMesh.new()
	var size := float(layer.get("size", 0.1))
	quad.size = Vector2(size, size)
	var material := StandardMaterial3D.new()
	material.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	material.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	material.blend_mode = BaseMaterial3D.BLEND_MODE_ADD if String(layer.get("blend", "alpha")) == "add" else BaseMaterial3D.BLEND_MODE_MIX
	material.billboard_mode = BaseMaterial3D.BILLBOARD_ENABLED
	material.vertex_color_use_as_albedo = true
	material.albedo_texture = load(VFX.asset_path(String(layer.get("tex", "vfx_spark_static"))))
	quad.material = material
	particles.draw_pass_1 = quad
	var process := ParticleProcessMaterial.new()
	var dir := direction if bool(layer.get("forward", false)) else Vector3.UP
	if bool(layer.get("edge_only", false)):
		# keep a warning readable in a crowd: motes hug the rim, never the middle
		process.emission_shape = ParticleProcessMaterial.EMISSION_SHAPE_RING
		process.emission_ring_radius = 0.85
		process.emission_ring_inner_radius = 0.7
		process.emission_ring_axis = Vector3.UP
		dir = Vector3.UP
	process.direction = dir
	process.spread = float(layer.get("spread", 45.0))
	process.initial_velocity_min = float(layer.get("speed", 2.0)) * 0.6
	process.initial_velocity_max = float(layer.get("speed", 2.0))
	process.gravity = Vector3(0.0, float(layer.get("gravity", -3.0)), 0.0)
	process.scale_min = 0.6
	process.scale_max = 1.4
	process.color = _layer_colour(layer, colour)
	var gradient := Gradient.new()
	gradient.set_color(0, Color(1, 1, 1, 1))
	gradient.set_color(1, Color(1, 1, 1, 0))
	var ramp := GradientTexture1D.new()
	ramp.gradient = gradient
	process.color_ramp = ramp
	particles.process_material = process
	add_child(particles)
	particles.global_position = base_position + direction * _forward_of(layer)
	if bool(layer.get("flat", false)):
		particles.global_position = base_position + Vector3.UP * 0.15
	particles.emitting = true
	return particles

func _build_mesh_layer(layer: Dictionary, colour: Color) -> Node3D:
	var scene: PackedScene = load(VFX.asset_path(String(layer.get("mesh", ""))))
	if scene == null:
		return null
	var root := Node3D.new()
	root.name = "Layer_Mesh"
	add_child(root)
	var amount := int(layer.get("amount", 1))
	for i in range(maxi(1, amount)):
		var instance: Node3D = scene.instantiate()
		root.add_child(instance)
		if bool(layer.get("burst", false)):
			var rng := RandomNumberGenerator.new()
			rng.seed = hash(spell_id) + i * 977
			instance.position = Vector3(rng.randf_range(-1.2, 1.2), rng.randf_range(0.2, 1.4), rng.randf_range(-1.2, 1.2))
			instance.rotation = Vector3(rng.randf_range(-PI, PI), rng.randf_range(-PI, PI), rng.randf_range(-PI, PI))
			instance.set_meta("burst_velocity", Vector3(rng.randf_range(-3.0, 3.0), rng.randf_range(2.0, 6.0), rng.randf_range(-3.0, 3.0)))
		if layer.has("size"):
			var s: Vector3 = layer["size"]
			instance.scale = s
		var mat := StandardMaterial3D.new()
		mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
		mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
		mat.blend_mode = BaseMaterial3D.BLEND_MODE_ADD if String(layer.get("blend", "alpha")) == "add" else BaseMaterial3D.BLEND_MODE_MIX
		mat.vertex_color_use_as_albedo = true
		var tint := _layer_colour(layer, colour)
		if bool(layer.get("ward", false)):
			var ward := ShaderMaterial.new()
			ward.shader = preload("res://assets/shaders/ward_surface.gdshader")
			ward.set_shader_parameter("flow_noise", load(VFX.asset_path("vfx_noise_flow")))
			ward.set_shader_parameter("tint", tint)
			_set_mesh_material(instance, ward)
		elif bool(layer.get("flow", false)):
			# the shell carries a flowing noise field and a bright rim so the
			# ward reads as a surface, not as a sprite
			var shader_mat := ShaderMaterial.new()
			shader_mat.shader = load(SHADER_ALPHA)
			shader_mat.set_shader_parameter("atlas", load(VFX.asset_path("vfx_noise_flow")))
			shader_mat.set_shader_parameter("grid", Vector2.ONE)
			shader_mat.set_shader_parameter("billboard", false)
			shader_mat.set_shader_parameter("tint", Color(tint.r, tint.g, tint.b, 0.22 if not bool(layer.get("fracture", false)) else 0.30))
			shader_mat.set_shader_parameter("soft_fade", 0.0)
			if bool(layer.get("fracture", false)):
				shader_mat.set_shader_parameter("erosion", load(VFX.asset_path("vfx_noise_erosion")))
			_set_mesh_material(instance, shader_mat)
			instance.set_meta("fracture", true)
		else:
			mat.albedo_color = Color(tint.r, tint.g, tint.b, 0.9)
			if bool(layer.get("colour", false)):
				mat.emission_enabled = true
				mat.emission = tint
				mat.emission_energy_multiplier = 1.4
			_set_mesh_material(instance, mat)
		if bool(layer.get("follow", false)) and follow_target != null:
			instance.set_meta("follows", true)
	return root

func _set_mesh_material(node: Node, material: Material) -> void:
	if node is MeshInstance3D:
		(node as MeshInstance3D).material_override = material
	for child in node.get_children():
		_set_mesh_material(child, material)

func _build_ribbon(layer: Dictionary, colour: Color) -> Node3D:
	var node := MeshInstance3D.new()
	node.name = "Layer_Ribbon"
	node.mesh = ImmediateMesh.new()
	node.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	node.top_level = true
	var material := ShaderMaterial.new()
	material.shader = load(RIBBON_SHADER)
	material.set_shader_parameter("streak", load(VFX.asset_path(String(layer.get("tex", "vfx_energy_streak")))))
	material.set_shader_parameter("tint", _layer_colour(layer, colour))
	material.set_shader_parameter("edge_softness", 0.6)
	node.material_override = material
	add_child(node)
	# Vertices below are world positions; inherit neither spawn translation nor rotation.
	node.global_transform = Transform3D.IDENTITY
	node.set_meta("width", float(layer.get("width", 0.1)))
	node.set_meta("max_length", float(layer.get("length", 3.0)))
	node.set_meta("history", PackedVector3Array())
	return node

func _build_light(layer: Dictionary, colour: Color) -> Node3D:
	var light := OmniLight3D.new()
	light.name = "Layer_Light"
	light.light_color = _layer_colour(layer, colour)
	light.light_energy = float(layer.get("energy", 2.0))
	light.omni_range = float(layer.get("range", 6.0))
	light.shadow_enabled = false
	light.set_meta("peak_energy", light.light_energy)
	add_child(light)
	light.global_position = base_position + Vector3.UP * 0.4
	return light

# ------------------------------------------------------------------ lifecycle

func _process(delta: float) -> void:
	if cancelled:
		return
	_elapsed += delta
	if not is_instance_valid(caster) and caster != null:
		cancel("caster_gone")
		return
	if caster != null and "is_dead" in caster and bool(caster.get("is_dead")):
		cancel("caster_dead")
		return
	if _live(follow_target) and not _follow_carried:
		var anchor := follow_target.global_position
		global_position += anchor - _follow_anchor
		_follow_anchor = anchor
	if _audio_looping and is_instance_valid(_audio_manager):
		# the pooled voice is positioned once, so it has to be told to ride along
		_audio_manager.call("move_loop", _audio_key, self, global_position)
	for entry in _layers:
		_tick_layer(entry, delta)
	if _follow_owned:
		# the bolt is gone: nothing owns this stage any more, so it ends here
		if not _live(follow_target):
			_finish()
		return
	if _elapsed >= _duration:
		_finish()

## A follow target that was detached from the tree (a rebuilt prop, a freed
## holder) can no longer be read; it counts as gone.
static func _live(node: Variant) -> bool:
	if node == null or not is_instance_valid(node):
		return false
	return (node as Node).is_inside_tree()

func _tick_layer(entry: Dictionary, delta: float) -> void:
	var node = entry["node"]
	if not is_instance_valid(node):
		return
	var layer: Dictionary = entry["layer"]
	var age: float = _elapsed - float(entry["born"]) - float(entry["offset"])
	if age < 0.0:
		return
	node.visible = true
	var life := float(layer.get("life", 0.0))
	var kind := String(layer.get("kind", ""))
	# fade curves: nothing pops, everything is a curve
	var fade := _fade_for(layer, age, life)
	match kind:
		"signature":
			var current_aim := direction
			if is_instance_valid(follow_target) and "direction" in follow_target:
				current_aim = follow_target.get("direction")
			node.duration = maxf(0.1, life)
			node.advance(age, current_aim)
		"stupefy_energy":
			var current_aim := direction
			if is_instance_valid(follow_target) and "direction" in follow_target:
				current_aim = follow_target.get("direction")
			node.advance(age, current_aim)
		"flipbook", "sprite":
			var material := (node as MeshInstance3D).mesh.surface_get_material(0) as ShaderMaterial
			if material != null:
				if layer.has("energy_shape"):
					material.set_shader_parameter("phase", clampf(age / maxf(life, 0.01), 0.0, 1.0))
					if stage == "travel" and is_instance_valid(follow_target):
						var current_aim: Vector3 = follow_target.get("direction") if "direction" in follow_target else direction
						material.set_shader_parameter("aim", current_aim)
				# a flipbook walks its atlas frame by frame; a sprite holds the
				# single cell it was placed on (a rune mask, a ground mark, a glow)
				if not layer.has("energy_shape"):
					var frame := float(layer.get("frame", 0)) if kind == "sprite" else _flipbook_frame(layer, age)
					material.set_shader_parameter("frame", frame)
				material.set_shader_parameter("opacity", fade * float(layer.get("opacity", 1.0)))
				if bool(layer.get("fracture", false)):
					material.set_shader_parameter("erode", clampf(age / maxf(0.05, life), 0.0, 1.0))
			if bool(node.get_meta("spin", false)):
				node.rotate_y(delta * float(node.get_meta("spin")))
			if bool(node.get_meta("flicker", false)):
				var s := 0.85 + 0.3 * sin(_elapsed * 47.0) * randf()
				node.scale = Vector3.ONE * s
		"particles":
			if not bool(layer.get("continuous", false)) and age > life and (node as GPUParticles3D).emitting:
				(node as GPUParticles3D).emitting = false
		"mesh":
			for child in node.get_children():
				if child.has_meta("follows") and _live(follow_target):
					child.global_position = follow_target.global_position
				if child.has_meta("burst_velocity"):
					var vel: Vector3 = child.get_meta("burst_velocity")
					child.global_position += vel * delta
					vel.y -= 9.0 * delta
					child.set_meta("burst_velocity", vel)
					child.rotate_y(delta * 3.0)
			var mat := _first_material(node)
			if mat is ShaderMaterial:
				var shader_mat := mat as ShaderMaterial
				if bool(layer.get("ward", false)):
					shader_mat.set_shader_parameter("clock", age)
					shader_mat.set_shader_parameter("opacity", fade)
					if bool(layer.get("grow", false)):
						node.scale = Vector3.ONE * maxf(0.01, smoothstep(0, 0.18, age))
				var tint: Color = shader_mat.get_shader_parameter("tint")
				shader_mat.set_shader_parameter("tint", Color(tint.r, tint.g, tint.b, fade * 0.35))
				if bool(layer.get("fracture", false)):
					shader_mat.set_shader_parameter("erode", clampf(age / maxf(0.05, life), 0.0, 1.0))
			elif mat is StandardMaterial3D:
				var std := mat as StandardMaterial3D
				std.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
				std.albedo_color = Color(std.albedo_color.r, std.albedo_color.g, std.albedo_color.b, fade)
		"ribbon":
			_update_ribbon(node, delta)
			if _retiring:
				(node.material_override as ShaderMaterial).set_shader_parameter("opacity", 1.0 - smoothstep(0.0, 0.24, _elapsed - _retire_at))
		"light":
			var peak := float(node.get_meta("peak_energy", 2.0))
			(node as OmniLight3D).light_energy = peak * fade

## The atlas cell a flipbook shows at `age`: it walks the sheet from the layer's
## start frame and holds the last cell when the layer does not loop.
func _flipbook_frame(layer: Dictionary, age: float) -> float:
	var entry := VFX.asset(String(layer.get("atlas", layer.get("tex", ""))))
	var frames := float(entry.get("frames", 1))
	var fps := float(entry.get("fps", 20))
	var base := float(layer.get("frame", 0))
	if frames <= 1.0 or fps <= 0.0:
		return base
	var advance := age * fps / maxf(1.0, float(layer.get("frame_step", 1)))
	var frame := base + advance
	if bool(layer.get("loop", false)):
		frame = base + fmod(advance, maxf(1.0, frames - base))
	elif frame > frames - 1.0:
		frame = frames - 1.0
	return floor(frame + 0.5)

func _first_material(node: Node) -> Material:
	if node is MeshInstance3D:
		return (node as MeshInstance3D).material_override
	for child in node.get_children():
		var found := _first_material(child)
		if found != null:
			return found
	return null

func _fade_for(layer: Dictionary, age: float, life: float) -> float:
	if life <= 0.0:
		return 1.0
	var k := clampf(age / life, 0.0, 1.0)
	match String(layer.get("fade", "out")):
		"in":
			return smoothstep(0.0, 0.35, k) * (1.0 - smoothstep(0.8, 1.0, k))
		"hold":
			return smoothstep(0.0, 0.12, k) * (1.0 - smoothstep(0.82, 1.0, k))
		"slow":
			return smoothstep(0.0, 0.2, k) * (1.0 - smoothstep(0.65, 1.0, k))
		_:
			return 1.0 - smoothstep(0.55, 1.0, k)

func _update_ribbon(node: MeshInstance3D, delta: float) -> void:
	var history: PackedVector3Array = node.get_meta("history")
	var origin := follow_target.global_position if _live(follow_target) else global_position
	if history.is_empty() or history[history.size() - 1].distance_squared_to(origin) > 0.0001:
		history.push_back(origin)
	# keep ~0.5 s of motion, decimated so a slow frame cannot grow the strip
	while history.size() > 32:
		history.remove_at(0)
	node.set_meta("history", history)
	var max_length := float(node.get_meta("max_length", 3.0))
	var width := float(node.get_meta("width", 0.1))
	var mesh := node.mesh as ImmediateMesh
	mesh.clear_surfaces()
	if history.size() < 3:
		return
	mesh.surface_begin(Mesh.PRIMITIVE_TRIANGLE_STRIP)
	var travelled := 0.0
	var count := history.size()
	for i in range(count):
		var idx := count - 1 - i
		var point := history[idx]
		if i > 0:
			travelled += point.distance_to(history[idx + 1])
		var age := float(i) / float(count)
		var taper := lerpf(1.0, 0.06, age)
		var dir := (point - history[maxi(0, idx - 1)]).normalized() if idx > 0 else direction
		var camera := get_viewport().get_camera_3d()
		var to_camera := (camera.global_position - point).normalized() if camera != null else Vector3.UP
		var side := dir.cross(to_camera)
		if side.length_squared() < 0.0001:
			side = Vector3.RIGHT
		side = side.normalized() * width * taper
		var fade := (1.0 - age) * (1.0 - clampf(travelled / max_length, 0.0, 1.0))
		mesh.surface_set_color(Color(1, 1, 1, fade))
		mesh.surface_set_uv(Vector2(age, 0.0))
		mesh.surface_add_vertex(point - side)
		mesh.surface_set_color(Color(1, 1, 1, fade))
		mesh.surface_set_uv(Vector2(age, 1.0))
		mesh.surface_add_vertex(point + side)
	mesh.surface_end()

## Cancel: stop emitting, fade over a short beat, then free. Used by death,
## interruption, transfer, network rejection and shutdown.
func retire_travel() -> void:
	if _retiring or cancelled:
		return
	_retiring = true
	_retire_at = _elapsed
	_follow_owned = false
	_follow_carried = false
	if is_instance_valid(follow_target) and "direction" in follow_target:
		direction = follow_target.get("direction")
	follow_target = null
	_duration = _elapsed + 0.26
	_stop_audio()
	for entry in _layers:
		var node: Node = entry["node"]
		if node.has_method("retire"):
			node.call("retire")
		elif node is GPUParticles3D:
			(node as GPUParticles3D).emitting = false


func cancel(reason: String = "") -> void:
	if cancelled:
		return
	cancelled = true
	_stop_audio()
	for entry in _layers:
		var node = entry["node"]
		if not is_instance_valid(node):
			continue
		if node is GPUParticles3D:
			(node as GPUParticles3D).emitting = false
		elif node is MeshInstance3D:
			node.visible = false
		elif node.has_method("retire"):
			node.visible = false
	set_meta("cancel_reason", reason)
	# one short beat so a cancelled quad does not vanish between two frames
	var tween := create_tween()
	tween.tween_interval(0.08)
	tween.tween_callback(_finish)

func _finish() -> void:
	_stop_audio()
	finished.emit(spell_id, stage)
	queue_free()

func _stop_audio() -> void:
	if _audio_started.is_empty() or not has_node("/root/AudioManager"):
		return
	var manager := get_node("/root/AudioManager")
	for key in _audio_started:
		manager.call("stop_sound", key, self)
	_audio_started.clear()

func _exit_tree() -> void:
	_stop_audio()

## Presentation-only description for the checks and the debug overlay.
func describe() -> Dictionary:
	return {"spell": spell_id, "stage": stage, "quality": quality,
		"layers": _layers.size(), "duration": _duration, "following": follow_target != null}
