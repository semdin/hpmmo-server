extends MeshInstance3D
class_name TargetRing

## A slowly turning, softly glowing spiral ring on the ground under whatever
## the local player has targeted (mob, boss, player, dummy, monolith). Sized
## to the target: bosses get a wide ring. Gold for creatures and objects,
## pale blue for other players.

const SHADER := preload("res://assets/shaders/target_ring.gdshader")
const GOLD := Color(1.0, 0.78, 0.32, 1.0)
const ALLY := Color(0.45, 0.75, 1.0, 1.0)

var _material: ShaderMaterial
var _target: Node3D = null

func _ready() -> void:
	name = "TargetRing"
	var plane := PlaneMesh.new()
	plane.size = Vector2(2.0, 2.0)
	mesh = plane
	_material = ShaderMaterial.new()
	_material.shader = SHADER
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
			var radius := _radius_of(target)
			scale = Vector3(radius, 1.0, radius)
			_material.set_shader_parameter("tint", ALLY if target.is_in_group("players") else GOLD)
	visible = target != null
	if target == null:
		return
	global_position = target.global_position + Vector3(0, 0.1, 0)
	rotation.y += delta * 0.6

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
