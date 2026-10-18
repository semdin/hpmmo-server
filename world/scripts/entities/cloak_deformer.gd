extends Node
class_name CloakDeformer

## Feeds assets/shaders/cloak.gdshader: the arm capsules (and, while riding,
## the broom shaft) the cloak's fabric is pushed out of, plus the riding sweep.
## Lives as a child of the EquippedCloak mesh, which sits under the body's
## Skeleton3D with an identity transform, so skeleton space is the mesh's model
## space and bone poses go to the shader as they are.

var mesh: MeshInstance3D
var skeleton: Skeleton3D
var rider: Node
var _bones: Dictionary = {}
var _riding := 0.0
var _wind := 0.0


func _ready() -> void:
	mesh = get_parent() as MeshInstance3D
	skeleton = mesh.get_parent() as Skeleton3D if mesh != null else null
	if skeleton == null or NetworkManager.is_dedicated_server:
		set_process(false)
		return
	for bone in ["Hips", "Neck", "UpperChest", "LeftUpperArm", "LeftLowerArm", "LeftHand",
			"RightUpperArm", "RightLowerArm", "RightHand"]:
		_bones[bone] = skeleton.find_bone(bone)
	var node: Node = skeleton
	while node != null and not ("is_mounted" in node):
		node = node.get_parent()
	rider = node
	process_priority = 100


func _pos(bone: String) -> Vector3:
	var index: int = _bones.get(bone, -1)
	return skeleton.get_bone_global_pose(index).origin if index >= 0 else Vector3.ZERO


func _process(delta: float) -> void:
	if not mesh.is_visible_in_tree():
		return
	var hips := _pos("Hips")
	var neck := _pos("Neck")
	var torso := maxf(0.05, hips.distance_to(neck))
	mesh.set_instance_shader_parameter("spine_a", hips)
	mesh.set_instance_shader_parameter("spine_b", neck)
	for side in ["Left", "Right"]:
		var key := "l" if side == "Left" else "r"
		var upper := _pos(side + "UpperArm")
		var lower := _pos(side + "LowerArm")
		var hand := _pos(side + "Hand")
		var upper_len := upper.distance_to(lower)
		var fore_len := lower.distance_to(hand)
		# Radii include the fabric's own clearance; the forearm runs on past the
		# wrist to cover the hand.
		mesh.set_instance_shader_parameter("arm_%s_a" % key, Vector4(upper.x, upper.y, upper.z, upper_len * 0.36))
		mesh.set_instance_shader_parameter("arm_%s_b" % key, lower)
		var tip := hand + (hand - lower) * 0.45
		mesh.set_instance_shader_parameter("fore_%s_a" % key, Vector4(lower.x, lower.y, lower.z, fore_len * 0.34))
		mesh.set_instance_shader_parameter("fore_%s_b" % key, tip)

	var mounted := rider != null and bool(rider.get("is_mounted"))
	_riding = move_toward(_riding, 1.0 if mounted else 0.0, delta * 2.5)
	var speed := 0.0
	if rider is CharacterBody3D:
		var v: Vector3 = (rider as CharacterBody3D).velocity
		speed = Vector2(v.x, v.z).length() / maxf(1.0, float(rider.get("mounted_speed")) if mounted else 8.0)
	_wind = lerpf(_wind, clampf(speed, 0.0, 1.0), minf(1.0, delta * 3.0))

	# Body frame in skeleton space: right from shoulder to shoulder, back = right x up.
	var up := (neck - hips).normalized()
	var right := (_pos("RightUpperArm") - _pos("LeftUpperArm")).normalized()
	var back := right.cross(up).normalized()
	var hinge := _pos("UpperChest").lerp(neck, 0.5)
	mesh.set_instance_shader_parameter("hinge", Vector4(hinge.x, hinge.y, hinge.z, _riding))
	mesh.set_instance_shader_parameter("back", Vector4(back.x, back.y, back.z, torso * 2.4))
	mesh.set_instance_shader_parameter("wind", _wind)

	var shaft := Vector4.ZERO
	var shaft_end := Vector3.ZERO
	if _riding > 0.0 and rider != null:
		var broom = rider.get("broom")
		if broom != null and is_instance_valid(broom):
			var grip: Node3D = broom.get("grip_socket")
			var tail: Node3D = broom.get("tail_socket")
			if grip != null and tail != null and is_instance_valid(grip) and is_instance_valid(tail):
				var to_local := mesh.global_transform.affine_inverse()
				var a := to_local * grip.global_position
				shaft_end = to_local * tail.global_position
				shaft = Vector4(a.x, a.y, a.z, torso * 0.16)
	mesh.set_instance_shader_parameter("shaft_a", shaft)
	mesh.set_instance_shader_parameter("shaft_b", shaft_end)
