extends SkeletonModifier3D
class_name WandGripModifier

## Poses the right hand into a natural, firm grip around the equipped wand.
##
## Without this modifier, the character's right hand remains in an open, flat
## resting pose, leaving the wand floating or clipping through uncurled fingers.
## This modifier curls the fingers (Index, Middle, Ring, Pinky) around the wand
## handle and wraps the thumb over the side, locking the wand firmly into the fist.

var weight := 1.0
var target_weight := 1.0

const WAND_FINGERS := ["Index", "Middle", "Ring", "Pinky"]

func _process_modification_with_delta(delta: float) -> void:
	call_deferred("apply_now")
	weight = move_toward(weight, clampf(target_weight, 0.0, 1.0), delta * 5.0)
	_apply()

func _process_modification() -> void:
	_apply()

func apply_now() -> void:
	if not is_inside_tree():
		return
	_apply()

func _apply() -> void:
	var skeleton := get_skeleton()
	if skeleton == null or weight <= 0.001:
		return
	
	# Lock finger base positions to rest and curl joints around wand
	for f in WAND_FINGERS:
		for k in [1, 2, 3, 4]:
			var index := RigIK.bone_index(skeleton, "%s%d.R" % [f, k])
			if index < 0:
				continue
			var rest: Transform3D = skeleton.get_bone_rest(index)
			skeleton.set_bone_pose_position(index,
				skeleton.get_bone_pose_position(index).lerp(rest.origin, weight))
			var rest_q := rest.basis.get_rotation_quaternion()
			var curl_q := rest_q
			if k == 1:
				curl_q = rest_q * Quaternion(Vector3(1, 0, 0), deg_to_rad(15.0))
			elif k == 2:
				curl_q = rest_q * Quaternion(Vector3(1, 0, 0), deg_to_rad(70.0))
			elif k == 3:
				curl_q = rest_q * Quaternion(Vector3(1, 0, 0), deg_to_rad(80.0))
			elif k == 4:
				curl_q = rest_q * Quaternion(Vector3(1, 0, 0), deg_to_rad(55.0))
			var current_q := skeleton.get_bone_pose_rotation(index)
			skeleton.set_bone_pose_rotation(index, current_q.slerp(curl_q, weight))
			
	for k in [1, 2, 3]:
		var index := RigIK.bone_index(skeleton, "Thumb%d.R" % k)
		if index < 0:
			continue
		var rest: Transform3D = skeleton.get_bone_rest(index)
		skeleton.set_bone_pose_position(index,
			skeleton.get_bone_pose_position(index).lerp(rest.origin, weight))
		var rest_q := rest.basis.get_rotation_quaternion()
		var curl_q := rest_q
		if k == 1:
			curl_q = rest_q * Quaternion(Vector3(0, 1, 0), deg_to_rad(25.0)) * Quaternion(Vector3(1, 0, 0), deg_to_rad(10.0))
		elif k == 2:
			curl_q = rest_q * Quaternion(Vector3(1, 0, 0), deg_to_rad(50.0))
		elif k == 3:
			curl_q = rest_q * Quaternion(Vector3(1, 0, 0), deg_to_rad(50.0))
		var current_q := skeleton.get_bone_pose_rotation(index)
		skeleton.set_bone_pose_rotation(index, current_q.slerp(curl_q, weight))
		
	skeleton.force_update_all_bone_transforms()
