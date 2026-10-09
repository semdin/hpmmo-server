extends SkeletonModifier3D
class_name BroomGripModifier

## Solve the rider onto the shaft after the animated pose and cast layer.
## Bone poses are temporary inside this pass: never reapply them deferred.
const LEAN_SHARE := {"Abdomen": 0.5, "Torso": 0.3, "Chest": 0.2}
const LEAN_DEG := 50.0
const GRIP_SPREAD := 0.065
const PALM_DEPTH := 0.039
# The imported shaft curves above its socket baseline: the wood rings in the
# grip region are centred 4.2-4.8 cm above GripSocket (build_broom.py).
const SHAFT_RISE := 0.045

const ARMS := [
	{"side": "L", "root": "UpperArm.L", "mid": "LowerArm.L", "end": "Wrist.L", "offset": -GRIP_SPREAD},
	{"side": "R", "root": "UpperArm.R", "mid": "LowerArm.R", "end": "Wrist.R", "offset": GRIP_SPREAD},
]

## The broom rig to solve onto (a BroomFlight). Set once by player.gd.
var broom: Node = null
## 0..1, driven from the player's mount blend; 0 hands the body back to the clips.
var target_weight := 0.0
var weight := 0.0

var _bases := {}
var _hand_error := 0.0
var _hand_alignment := 1.0


func setup(broom_rig: Node) -> void:
	broom = broom_rig


## Distance from the worst palm grip centre to the shaft, in metres.
func hand_error() -> float:
	return _hand_error if weight > 0.5 else -1.0

## Alignment of the handle axis across each palm with the shaft.
func hand_alignment() -> float:
	return _hand_alignment if weight > 0.5 else -1.0

func engaged() -> bool:
	return weight > 0.5


func _process_modification_with_delta(delta: float) -> void:
	weight = move_toward(weight, clampf(target_weight, 0.0, 1.0), delta * 3.2)
	var skeleton := get_skeleton()
	if skeleton == null or weight <= 0.001:
		return
	_capture_bases(skeleton)
	_lean(skeleton)
	for side in ["L", "R"]:
		RigIK.close_hand(skeleton, side, weight, PALM_DEPTH)
	_grip(skeleton)


## Remember what the animation (and the cast layer, which runs before us) wrote.
func _capture_bases(skeleton: Skeleton3D) -> void:
	_bases.clear()
	for bone in LEAN_SHARE:
		var index := RigIK.bone_index(skeleton, bone)
		if index >= 0:
			_bases[index] = skeleton.get_bone_pose_rotation(index)
	for name in ["Neck", "Head"]:
		var index := RigIK.bone_index(skeleton, name)
		if index >= 0:
			_bases[index] = skeleton.get_bone_pose_rotation(index)
	for arm in ARMS:
		for key in ["root", "mid", "end"]:
			var index := RigIK.bone_index(skeleton, String(arm[key]))
			if index >= 0:
				_bases[index] = skeleton.get_bone_pose_rotation(index)
	skeleton.force_update_all_bone_transforms()


## Aim the spine at an absolute riding lean. Adding a fixed angle to each
## authored clip over-bends dives and under-bends the driving-derived idle.
func _lean(skeleton: Skeleton3D) -> void:
	var shaft := _shaft(skeleton)
	if shaft.is_empty():
		return
	var hips := RigIK.bone_index(skeleton, "Hips")
	var neck := RigIK.bone_index(skeleton, "Neck")
	var up: Vector3 = shaft["up"]
	var forward: Vector3 = shaft["direction"]
	var wanted := up * cos(deg_to_rad(LEAN_DEG)) + forward * sin(deg_to_rad(LEAN_DEG))
	for _iteration in range(5):
		var current := (skeleton.get_bone_global_pose(neck).origin - skeleton.get_bone_global_pose(hips).origin).normalized()
		var correction := Quaternion(current, wanted)
		for bone in LEAN_SHARE:
			var index := RigIK.bone_index(skeleton, bone)
			if index >= 0:
				RigIK.rotate_global(skeleton, index, Quaternion.IDENTITY.slerp(correction, float(LEAN_SHARE[bone]) * weight), 1.0)
	# Keep the gaze ahead of the broom. Both joints start from the rig's rest
	# orientation rather than inheriting the driving clip's neck twists.
	var upright := Basis(up.cross(forward), up, forward).orthonormalized()
	for bone in ["Neck", "Head"]:
		var index := RigIK.bone_index(skeleton, bone)
		var parent := skeleton.get_bone_parent(index)
		var global_basis := upright * skeleton.get_bone_global_rest(index).basis.orthonormalized()
		var local := skeleton.get_bone_global_pose(parent).basis.orthonormalized().inverse() * global_basis
		RigIK.write_rotation(skeleton, index, local.get_rotation_quaternion(), weight, _bases[index])


## Match the palm's full frame to the handle, then solve the wrist position.
## Aligning only the forearm direction leaves the palm rolled away from the wood.
func _grip(skeleton: Skeleton3D) -> void:
	var shaft := _shaft(skeleton)
	if shaft.is_empty():
		_hand_error = -1.0
		return
	var origin: Vector3 = shaft["origin"]
	var direction: Vector3 = shaft["direction"]
	_hand_error = 0.0
	_hand_alignment = 1.0
	for arm in ARMS:
		var root := RigIK.bone_index(skeleton, String(arm["root"]))
		var mid := RigIK.bone_index(skeleton, String(arm["mid"]))
		var end := RigIK.bone_index(skeleton, String(arm["end"]))
		if root < 0 or mid < 0 or end < 0:
			continue
		var shoulder := skeleton.get_bone_global_pose(root).origin
		var palm_point: Vector3 = shaft["grip"] + direction * (float(arm["offset"]) - 0.08)
		var down := palm_point - shoulder
		down = (down - direction * down.dot(direction)).normalized()
		var grip := RigIK.grip_frame(skeleton, String(arm["side"]), PALM_DEPTH)
		# grip_frame already mirrors the palm normal. Both index sides point
		# forward; reversing the left frame again turns its palm away from wood.
		var across := direction
		var wanted := Basis(across, down, across.cross(down)).orthonormalized() * grip.basis.inverse()
		var target := palm_point - wanted * grip.origin
		RigIK.two_bone(skeleton, root, mid, end, target, Vector3.DOWN, weight, _bases)
		var parent := skeleton.get_bone_parent(end)
		var local := skeleton.get_bone_global_pose(parent).basis.orthonormalized().inverse() * wanted
		RigIK.write_rotation(skeleton, end, local.get_rotation_quaternion(), weight, _bases[end])
		var wrist := skeleton.get_bone_global_pose(end)
		_hand_error = maxf(_hand_error, RigIK.distance_to_line(wrist * grip.origin, origin, direction))
		_hand_alignment = minf(_hand_alignment, absf((wrist.basis * grip.basis.x).normalized().dot(direction)))


## The shaft's centreline in skeleton space: the SeatSocket projecting onto it,
## including the authored wood curvature above the socket baseline.
func _shaft(skeleton: Skeleton3D) -> Dictionary:
	if broom == null or not is_instance_valid(broom):
		return {}
	var seat_socket = broom.get("seat_socket")
	var grip_socket = broom.get("grip_socket")
	if seat_socket == null or grip_socket == null:
		return {}
	var to_local: Transform3D = skeleton.global_transform.affine_inverse()
	var seat: Vector3 = to_local * (seat_socket as Node3D).global_position
	var grip: Vector3 = to_local * (grip_socket as Node3D).global_position
	var model = broom.get("model_root_ref")
	var up := Vector3.UP
	# The broom is authored +Z forward (broom_flight.verify_axes measures exactly
	# that), so its own forward IS the shaft axis. Deriving the axis from the two
	# sockets instead would tilt it: the grip socket sits 0.18 m BELOW the seat as
	# well as ahead of it, so seat -> grip is 18 deg off the shaft.
	var direction := grip - seat
	if model is Node3D:
		direction = to_local.basis * (model as Node3D).global_basis.z
		up = (to_local.basis * (model as Node3D).global_basis.y).normalized()
	if direction.length_squared() < 1e-6:
		return {}
	direction = direction.normalized()
	# The seat sits `drop` above the centreline.
	var drop := absf((seat_socket as Node3D).position.y - (grip_socket as Node3D).position.y)
	return {"origin": seat - up * (drop - SHAFT_RISE), "direction": direction,
		"up": up, "grip": grip + up * SHAFT_RISE}
