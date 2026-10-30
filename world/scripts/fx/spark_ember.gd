extends Node3D
class_name SparkEmber

## A spark that hit nothing: it loses its push, floats down on the air with a
## little flutter and cools from its house colour to a dull ember, then breaks
## into a few glowing flecks that wink out before they reach the grass. Drawn
## where a basic bolt that missed ends (spell_projectile `_fizzle`);
## presentation only.

const GLOW_TEX := "res://assets/vfx/tex/soft_glow_512.png"
const LIFE := 1.1
const TRAIL_POINTS := 10
## When the spark breaks into flecks (fraction of LIFE).
const BREAK_AT := 0.72

static var _materials: Dictionary = {}

var velocity := Vector3.ZERO
var colour := Color(1.0, 0.6, 0.25)
var _age := 0.0
var _glow: MeshInstance3D = null
var _glow_material: StandardMaterial3D = null
var _core: MeshInstance3D = null
var _core_material: StandardMaterial3D = null
var _trail: MeshInstance3D = null
var _history := PackedVector3Array()
var _flecks: CPUParticles3D = null
var _broken := false
var _phase := 0.0
var _floor_y := -INF

## Start an ember at `pos` drifting with `push` (its leftover momentum).
static func spawn(parent: Node, pos: Vector3, push: Vector3, tint: Color) -> SparkEmber:
	if parent == null or not parent.is_inside_tree() or not HitFeedback.enabled():
		return null
	var ember := SparkEmber.new()
	ember.name = "SparkEmber"
	ember.velocity = push
	ember.colour = tint
	# Placed BEFORE it enters the tree: `_ready` starts the trail and finds the
	# floor from where it stands (placed after, the trail began at the world
	# origin and drew a line across the map).
	ember.position = (parent as Node3D).global_transform.affine_inverse() * pos if parent is Node3D else pos
	parent.add_child(ember)
	return ember

func _ready() -> void:
	_phase = randf() * TAU
	_glow_material = _material("glow").duplicate() as StandardMaterial3D
	_glow = _quad(0.2, _glow_material)
	_core_material = _material("glow").duplicate() as StandardMaterial3D
	_core = _quad(0.07, _core_material)
	_trail = MeshInstance3D.new()
	_trail.mesh = ImmediateMesh.new()
	_trail.top_level = true
	_trail.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	_trail.material_override = _material("trail")
	add_child(_trail)
	_trail.global_transform = Transform3D.IDENTITY
	_flecks = CPUParticles3D.new()
	var fleck := QuadMesh.new()
	fleck.size = Vector2(0.028, 0.028)
	fleck.material = _material("fleck")
	_flecks.mesh = fleck
	_flecks.amount = 6
	_flecks.lifetime = 0.75
	_flecks.one_shot = true
	_flecks.explosiveness = 0.85
	_flecks.local_coords = false
	_flecks.direction = Vector3.DOWN
	_flecks.spread = 120.0
	_flecks.initial_velocity_min = 0.12
	_flecks.initial_velocity_max = 0.45
	_flecks.gravity = Vector3(0, -0.7, 0)
	_flecks.damping_min = 0.5
	_flecks.damping_max = 1.2
	_flecks.scale_amount_min = 0.6
	_flecks.scale_amount_max = 1.2
	# a fleck glows, dims to a red spark and winks out
	var ramp := Gradient.new()
	ramp.offsets = PackedFloat32Array([0.0, 0.5, 1.0])
	ramp.colors = PackedColorArray([Color(1.0, 0.62, 0.22, 1.0), Color(0.85, 0.22, 0.05, 0.75), Color(0.4, 0.05, 0.0, 0.0)])
	_flecks.color_ramp = ramp
	_flecks.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	_flecks.emitting = false
	add_child(_flecks)
	# The ember never sinks into the grass: it dies a little above it.
	var space := get_world_3d().direct_space_state if get_world_3d() != null else null
	if space != null:
		var query := PhysicsRayQueryParameters3D.create(global_position + Vector3.UP * 0.3, global_position + Vector3.DOWN * 6.0, 1)
		var hit := space.intersect_ray(query)
		if not hit.is_empty():
			_floor_y = (hit.position as Vector3).y + 0.08
	_history.push_back(global_position)

func _quad(size: float, material: StandardMaterial3D) -> MeshInstance3D:
	var node := MeshInstance3D.new()
	var quad := QuadMesh.new()
	quad.size = Vector2(size, size)
	quad.material = material
	node.mesh = quad
	node.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	add_child(node)
	return node

func _process(delta: float) -> void:
	_age += delta
	var k := clampf(_age / LIFE, 0.0, 1.0)
	# The push dies fast; what is left is a slow fall with a sideways flutter.
	velocity *= exp(-4.5 * delta)
	velocity.y = maxf(velocity.y - 1.1 * delta, -0.5)
	var flutter := Vector3(sin(_age * 7.0 + _phase), 0.0, cos(_age * 5.3 + _phase * 1.7)) * 0.18
	var next := global_position + (velocity + flutter) * delta
	if next.y < _floor_y:
		next.y = _floor_y
		velocity.y = 0.0
	global_position = next
	# House colour -> ember orange -> dull red, dimming and shrinking as it cools.
	var hot := colour.lerp(Color(1.0, 0.92, 0.75), 0.3)
	var tint := hot.lerp(Color(1.0, 0.45, 0.12), smoothstep(0.0, 0.4, k)).lerp(Color(0.75, 0.15, 0.03), smoothstep(0.4, BREAK_AT, k))
	var flicker := 0.8 + 0.2 * sin(_age * 29.0 + _phase)
	var alive := 1.0 - smoothstep(BREAK_AT - 0.08, BREAK_AT + 0.05, k)
	_glow_material.albedo_color = Color(tint.r, tint.g, tint.b, 0.55 * alive * flicker)
	_core_material.albedo_color = Color(1.0, lerpf(0.9, 0.55, k), lerpf(0.75, 0.3, k), alive * flicker)
	var shrink := lerpf(1.0, 0.45, k)
	_glow.scale = Vector3.ONE * shrink
	_core.scale = Vector3.ONE * shrink
	if not _broken and k >= BREAK_AT:
		_broken = true
		_flecks.emitting = true
	_history.push_back(global_position)
	while _history.size() > TRAIL_POINTS:
		_history.remove_at(0)
	_draw_trail(tint, alive * (1.0 - smoothstep(0.2, 0.6, k)))
	if _age >= LIFE + _flecks.lifetime:
		queue_free()

## A hair-thin, fading wake over the last few positions.
func _draw_trail(tint: Color, strength: float) -> void:
	var mesh := _trail.mesh as ImmediateMesh
	mesh.clear_surfaces()
	if _history.size() < 2 or strength <= 0.01:
		return
	var camera := get_viewport().get_camera_3d()
	mesh.surface_begin(Mesh.PRIMITIVE_TRIANGLE_STRIP)
	var count := _history.size()
	for i in range(count):
		var idx := count - 1 - i
		var point := _history[idx]
		var age := float(i) / float(count - 1)
		var along := point - (_history[idx - 1] if idx > 0 else _history[idx + 1])
		var to_camera := (camera.global_position - point).normalized() if camera != null else Vector3.UP
		var side := along.cross(to_camera)
		side = side.normalized() if side.length_squared() > 0.000001 else Vector3.RIGHT
		side *= lerpf(0.014, 0.003, age)
		var c := Color(tint.r, tint.g, tint.b, (1.0 - age) * strength)
		mesh.surface_set_color(c)
		mesh.surface_add_vertex(point - side)
		mesh.surface_set_color(c)
		mesh.surface_add_vertex(point + side)
	mesh.surface_end()

static func _material(kind: String) -> StandardMaterial3D:
	if _materials.has(kind):
		return _materials[kind]
	var mat := StandardMaterial3D.new()
	mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	mat.blend_mode = BaseMaterial3D.BLEND_MODE_ADD
	mat.cull_mode = BaseMaterial3D.CULL_DISABLED
	mat.depth_draw_mode = BaseMaterial3D.DEPTH_DRAW_DISABLED
	match kind:
		"glow":
			mat.billboard_mode = BaseMaterial3D.BILLBOARD_ENABLED
			mat.albedo_texture = SpellEffect.asset(GLOW_TEX)
		"trail":
			mat.vertex_color_use_as_albedo = true
		"fleck":
			mat.billboard_mode = BaseMaterial3D.BILLBOARD_PARTICLES
			mat.albedo_texture = SpellEffect.asset(GLOW_TEX)
			mat.vertex_color_use_as_albedo = true
	_materials[kind] = mat
	return mat

## Every material, for ShaderWarmup.
static func warm_materials() -> Array:
	return [_material("glow"), _material("trail"), _material("fleck")]
