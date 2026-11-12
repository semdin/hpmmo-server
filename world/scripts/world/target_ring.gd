extends MeshInstance3D
class_name TargetRing

## The mark on the ground under whatever the local player has targeted (mob,
## boss, player, dummy, monolith): a ring of energy (target_ring.gdshader) with
## a few sparks lifting off it. It closes in from wide when a target is taken,
## and is sized to the target: bosses get a wide ring. Gold for creatures and
## objects, violet for a boss, pale blue for other players.
##
## The mesh is only a box round the target's feet: the shader draws the ring on
## the ground it finds inside it, so it lies on a slope.

const SHADER := preload("res://assets/shaders/target_ring.gdshader")
## The cloud map the ring's energy is cut from (the spell effects' erosion map).
const NOISE := "res://assets/vfx/tex/noise_erosion_512.png"
const GOLD := Color(1.0, 0.74, 0.28, 1.0)
## A boss's ring is violet, not ember: it stands inside the boss's own warnings,
## which burn orange, and an ember ring there read as a second ring of the
## warning.
const BOSS := Color(0.72, 0.40, 1.0, 1.0)
const ALLY := Color(0.42, 0.72, 1.0, 1.0)
## The box reaches past the ring: its spill of light, and the wide start of
## the closing-in.
const BOX_PER_RADIUS := 1.8
const HALF_HEIGHT := 0.7
const SNAP_S := 0.26

var _material: ShaderMaterial
var _box: BoxMesh
var _target: Node3D = null
var _snap := 0.0
var _motes: GPUParticles3D = null

func _ready() -> void:
	name = "TargetRing"
	_box = BoxMesh.new()
	_box.size = Vector3(2.0, HALF_HEIGHT * 2.0, 2.0)
	mesh = _box
	_material = ShaderMaterial.new()
	_material.shader = SHADER
	_material.set_shader_parameter("half_height", HALF_HEIGHT)
	if ResourceLoader.exists(NOISE):
		_material.set_shader_parameter("noise", load(NOISE))
	material_override = _material
	cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	top_level = true
	visible = false

func _process(delta: float) -> void:
	var player = SimAuthority.local_player_node()
	var target: Node3D = null
	if player != null and is_instance_valid(player):
		var t = player.get("current_target")
		if t is Node3D and is_instance_valid(t) and t.is_inside_tree() and t.get("is_dead") != true:
			target = t
	if target != _target:
		_target = target
		if target != null:
			_dress(_radius_of(target), _tint_of(target))
			_snap = 1.0
	visible = target != null
	if target == null:
		return
	global_position = target.global_position
	if _snap > 0.0:
		_snap = maxf(0.0, _snap - delta / SNAP_S)
		_material.set_shader_parameter("snap", _snap)

## Size and colour the ring for a new target, with its own sparks.
func _dress(radius: float, tint: Color) -> void:
	_box.size = Vector3(radius * BOX_PER_RADIUS * 2.0, HALF_HEIGHT * 2.0, radius * BOX_PER_RADIUS * 2.0)
	_material.set_shader_parameter("radius", radius)
	_material.set_shader_parameter("tint", tint)
	if _motes != null and is_instance_valid(_motes):
		_motes.queue_free()
	_motes = RisingMotes.make(radius, 4.0, tint, 8 + int(radius * 5.0), 1.5, Vector2(0.12, 0.55), Vector2(0.007, 0.016))
	add_child(_motes)
	_motes.emitting = true

static func _tint_of(target: Node3D) -> Color:
	if target.is_in_group("players"):
		return ALLY
	return BOSS if target.get("is_boss") == true else GOLD

## Ring radius in metres: bosses wide, the rest by their collision size.
static func _radius_of(target: Node3D) -> float:
	if target.get("is_boss") == true:
		return 2.6
	for child in target.get_children():
		if child is CollisionShape3D and (child as CollisionShape3D).shape != null:
			var shape: Shape3D = (child as CollisionShape3D).shape
			var r := 0.0
			if shape is CapsuleShape3D: r = (shape as CapsuleShape3D).radius
			elif shape is CylinderShape3D: r = (shape as CylinderShape3D).radius
			elif shape is SphereShape3D: r = (shape as SphereShape3D).radius
			elif shape is BoxShape3D: r = maxf((shape as BoxShape3D).size.x, (shape as BoxShape3D).size.z) * 0.5
			if r > 0.0:
				return clampf(r * child.global_transform.basis.get_scale().x * 1.7, 1.0, 3.0)
	return 1.1
