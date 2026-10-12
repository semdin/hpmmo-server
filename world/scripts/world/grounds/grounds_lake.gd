extends RefCounted
class_name GroundsLake

## The Black Lake: one water surface at the datum (y = 0) over the lake basin.
##
## The water has no collider. Swimming is a body state (player.gd asks
## `is_water_at()`): over water deeper than SWIM_DEPTH the body floats at the
## surface instead of walking the lake bed. The depth comes from the terrain, so
## the shoreline, the swim test and the shader's shallow/deep colour all agree.

const WATER_Y := 0.0
## Ground this far below the surface counts as swimmable water.
const SWIM_DEPTH := 1.25
const DEPTH_MAP := "res://assets/terrain/grounds/lake_depth.png"
## World rect the depth map covers (x, z, width, depth). Must match build_grounds.gd.
const DEPTH_RECT := Rect2(-640.0, 10.0, 1280.0, 660.0)
const DEPTH_SCALE := 20.0
const SHADER := preload("res://assets/shaders/lake_water.gdshader")


## True when (x, z) is over the lake and the bed is at least SWIM_DEPTH down.
static func is_water_at(x: float, z: float) -> bool:
	if not DEPTH_RECT.has_point(Vector2(x, z)):
		return false
	var h := GroundsTerrain.height_at(x, z)
	return not is_nan(h) and h < WATER_Y - SWIM_DEPTH


static func build(parent: Node3D) -> MeshInstance3D:
	var water := MeshInstance3D.new()
	water.name = "LakeWater"
	var plane := PlaneMesh.new()
	plane.size = DEPTH_RECT.size
	# Enough vertices for the low swell to read at the shore, few enough to be free.
	plane.subdivide_width = 160
	plane.subdivide_depth = 82
	water.mesh = plane
	water.position = Vector3(DEPTH_RECT.position.x + DEPTH_RECT.size.x * 0.5, WATER_Y,
		DEPTH_RECT.position.y + DEPTH_RECT.size.y * 0.5)
	water.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	var m := ShaderMaterial.new()
	m.shader = SHADER
	if ResourceLoader.exists(DEPTH_MAP):
		m.set_shader_parameter("depth_map", load(DEPTH_MAP))
	m.set_shader_parameter("depth_rect", Vector4(DEPTH_RECT.position.x, DEPTH_RECT.position.y,
		DEPTH_RECT.size.x, DEPTH_RECT.size.y))
	m.set_shader_parameter("depth_scale", DEPTH_SCALE)
	m.set_shader_parameter("normal_a", _normal_noise(7, 0.012))
	m.set_shader_parameter("normal_b", _normal_noise(19, 0.025))
	water.material_override = m
	parent.add_child(water)
	return water


static func _normal_noise(seed_value: int, frequency: float) -> NoiseTexture2D:
	var n := FastNoiseLite.new()
	n.seed = seed_value
	n.noise_type = FastNoiseLite.TYPE_SIMPLEX_SMOOTH
	n.frequency = frequency
	n.fractal_octaves = 3
	var t := NoiseTexture2D.new()
	t.width = 512
	t.height = 512
	t.seamless = true
	t.as_normal_map = true
	t.bump_strength = 6.0
	t.noise = n
	t.generate_mipmaps = true
	return t
