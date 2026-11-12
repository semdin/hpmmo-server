extends RefCounted
class_name RisingMotes

## Sparks lifting off a mark on the ground: a boss warning's embers, the
## flecks round a target ring, the lights over a portal. Born on the mark's
## boundary (a circle, or a cone's arc and sides) and a few inside it, they
## rise, sway, cool along a colour ramp and wink out
## (rising_motes.gdshader), drawn like every spark in the game
## (ember_spark.gdshader). All on the GPU. Presentation only.

const PROCESS := preload("res://assets/shaders/rising_motes.gdshader")
const DRAW := preload("res://assets/shaders/ember_spark.gdshader")

## The draw mesh, one process material and the ramps, kept for the whole
## process: a mark lives seconds, and a shader dropped with its last user is
## compiled again by the next one, in the middle of a fight.
static var _kept: Dictionary = {}

## `reach` metres to the boundary, `sector` a cone's half angle (4.0: the whole
## circle), `rise` and `size` as [min, max] (m/s, metres). A `burst` throws
## them all at once, a single time.
static func make(reach: float, sector: float, colour: Color, amount: int, lifetime: float,
		rise: Vector2, size: Vector2, burst: bool = false) -> GPUParticles3D:
	var particles := GPUParticles3D.new()
	particles.name = "MoteBurst" if burst else "Motes"
	particles.amount = amount
	particles.lifetime = lifetime
	particles.one_shot = burst
	particles.explosiveness = 0.95 if burst else 0.0
	particles.randomness = 0.0
	particles.fixed_fps = 0
	particles.local_coords = false
	particles.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	var span := reach + 3.0
	particles.visibility_aabb = AABB(Vector3(-span, -2.0, -span), Vector3(span * 2.0, 4.0 + rise.y * lifetime * 1.5, span * 2.0))
	if not _kept.has("mesh"):
		var quad := QuadMesh.new()
		var draw := ShaderMaterial.new()
		draw.shader = DRAW
		quad.material = draw
		_kept["mesh"] = quad
		var base := ShaderMaterial.new()
		base.shader = PROCESS
		_kept["process"] = base
	particles.draw_pass_1 = _kept["mesh"]
	# its own copy: the mark thins and thickens its own motes
	var process := (_kept["process"] as ShaderMaterial).duplicate() as ShaderMaterial
	process.set_shader_parameter("radius", reach)
	process.set_shader_parameter("sector", sector)
	process.set_shader_parameter("rise_min", rise.x)
	process.set_shader_parameter("rise_max", rise.y)
	process.set_shader_parameter("size_min", size.x)
	process.set_shader_parameter("size_max", size.y)
	process.set_shader_parameter("ramp", ramp(colour))
	particles.process_material = process
	particles.emitting = false
	return particles

## White-hot -> the colour -> a dull glow, fading out at the end.
static func ramp(colour: Color) -> GradientTexture1D:
	var key := "ramp|" + colour.to_html(false)
	if _kept.has(key):
		return _kept[key]
	var gradient := Gradient.new()
	gradient.offsets = PackedFloat32Array([0.0, 0.08, 0.35, 0.8, 1.0])
	gradient.colors = PackedColorArray([Color(1.0, 0.96, 0.85, 1.0), colour.lerp(Color(1.0, 0.9, 0.7), 0.45),
		colour, Color(colour.r * 0.55, colour.g * 0.35, colour.b * 0.35, 0.75), Color(colour.r * 0.3, colour.g * 0.15, colour.b * 0.15, 0.0)])
	var texture := GradientTexture1D.new()
	texture.gradient = gradient
	texture.width = 64
	_kept[key] = texture
	return texture

## Thin or thicken a running layer (0..1 of its particles alive).
static func set_rate(particles: GPUParticles3D, rate: float) -> void:
	if particles != null and is_instance_valid(particles) and particles.process_material is ShaderMaterial:
		(particles.process_material as ShaderMaterial).set_shader_parameter("rate", rate)

static func set_colour(particles: GPUParticles3D, colour: Color) -> void:
	if particles != null and is_instance_valid(particles) and particles.process_material is ShaderMaterial:
		(particles.process_material as ShaderMaterial).set_shader_parameter("ramp", ramp(colour))
