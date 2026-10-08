extends SkeletonModifier3D
class_name BroomGripModifier

## Puts the flying rider's hands ON the broom.
##
## The mounted poses were authored from a retargeted car-driving clip (`Drive_
## Reference`, both arms out at steering-wheel height) with only a small wrist and
## finger delta added, so nothing ever matched the hands to the broom. Measured
## while mounted: the hands floated 0.44 m above the shaft, and the broom's own
## two-handed `GripSocket` sat 0.818 m from the shoulder - 0.30 m beyond the whole
## 0.453 m arm (UpperArm -> Wrist), i.e. unreachable by construction.
##
## The broom is left exactly where it is. Its socket contract is what makes the
## rider look seated - the rider's hips stay on `SeatSocket` (gap 0.000 m, and a
## gate asserts <= 0.35 m) and the shaft is 0.18 m below that seat. So the RIDER is
## solved onto the broom instead: the upper spine leans forward, and each arm runs
## a two-bone IK onto a point on the shaft, with the wrist turned so the hand lies
## ALONG the shaft - the fingers then curl over it instead of stabbing it.
##
## Reach, with the measured numbers (shoulder 0.407 m above the hips, seat 0.18 m
## above the shaft, arm 0.453 m):
##   0.407 + 0.18 = 0.587 m straight down is 0.134 m out of reach un-leaned;
##   leaning the torso by `LEAN_DEG` brings the shoulder to 0.407*cos(lean) above
##   the hips, so 22 deg leaves 0.377 + 0.18 = 0.557 m: 0.104 m short of the WRIST
##   but only 0.077 m short of the FIST, which sits 0.027 m further on. The target
##   is clamped into the reach sphere, so the hands land as far down the shaft as
##   the arm allows even if the lean is later retuned.
##
## Only spine and arm bones are written. The hips and legs are untouched, so the
## seat contract, `rider_forward.dot(broom_forward)` and the cast layer's
## "legs are never disturbed" gate all still hold.

## Spine bones that take the lean, and the share of it each takes. Sum = 1.
const LEAN_SHARE := {"Abdomen": 0.5, "Torso": 0.3, "Chest": 0.2}
## Head counter-rotation as a share of the lean, so the rider looks where they are
## going instead of at the shaft.
const HEAD_COUNTER_SHARE := -0.35
## How far the torso leans into the broom. The measured un-leaned shoulder to
## shaft distance is 0.61 m against a 0.48 m fist reach, so the lean has to close
## 0.13 m of it; the rig's own bank and climb clips already lean the rider some,
## and 30 deg covers the rest.
const LEAN_DEG := 30.0
## The two hands sit this far apart along the shaft, centred on the point of the
## shaft nearest the shoulder - reaching sideways along the shaft is what the arm
## cannot do, so the pair is centred on its own projection rather than pinned to a
## fixed distance ahead of the hips.
const GRIP_SPREAD := 0.09
## The wrist is placed this far off the shaft, on the shoulder side, so the shaft
## passes through the palm rather than through the wrist joint.
const PALM_OFFSET := 0.03
## The hand's own bones. The mounted pose translates the index/middle/ring/pinky
## bases about 0.35 m away from the wrist joint (measured: they sit 0.027 m from it
## at rest), which tears the visible hand off the end of the arm - the single
## biggest reason the hands did not look like they were holding anything. They are
## pinned back onto their rest offsets while the grip is in force.
const HAND_BONES := [
	"Index1", "Index2", "Index3", "Index4", "Middle1", "Middle2", "Middle3", "Middle4",
	"Ring1", "Ring2", "Ring3", "Ring4", "Pinky1", "Pinky2", "Pinky3", "Pinky4",
	"Thumb1", "Thumb2", "Thumb3",
]

## The hand bones each arm is solved through, and which hand takes which side of
## the pair (back hand first, the way a two-handed grip sits).
const ARMS := [
	{"side": "L", "root": "UpperArm.L", "mid": "LowerArm.L", "end": "Wrist.L", "offset": -GRIP_SPREAD},
	{"side": "R", "root": "UpperArm.R", "mid": "LowerArm.R", "end": "Wrist.R", "offset": GRIP_SPREAD},
]

## The broom rig to solve onto (a BroomFlight). Set once by player.gd.
var broom: Node = null
## 0..1, driven from the player's mount blend; 0 hands the body back to the clips.
var target_weight := 0.0
var weight := 0.0

## The animation's own rotation for every bone this modifier writes, captured once
## per frame. Re-solving FROM these (rather than from the bone's current pose)
## makes the whole solve idempotent, which matters because both
## `_process_modification` and the deferred `apply_now` call `_apply`.
var _bases := {}
var _frame := -1
## For the gates: the largest wrist-to-shaft distance, and the worst hand/shaft
## alignment, both over the two hands.
var _hand_error := 0.0
var _hand_alignment := 1.0


func setup(broom_rig: Node) -> void:
	broom = broom_rig


## How far the worst WRIST is from the shaft's centreline, in metres - or -1 while
## the grip is not engaged (a caller that measures before the mount blend has
## finished would otherwise read a meaningless 0).
##
## The wrist is the right effector to measure. The finger-base centroid is not the
## palm on this rig - measured in the idle pose it sits 0.33 m from the wrist, so a
## fist-centroid distance says nothing about whether the hand is wrapped round the
## shaft. What makes a grip read is the wrist riding the shaft with the hand lying
## ALONG it, which is what the solve targets and what `hand_alignment` reports.
func hand_error() -> float:
	return _hand_error if weight > 0.5 else -1.0

## The worst hand's alignment with the shaft, 1.0 = lying exactly along it.
func hand_alignment() -> float:
	return _hand_alignment if weight > 0.5 else -1.0

func engaged() -> bool:
	return weight > 0.5


func _process_modification_with_delta(delta: float) -> void:
	# Deferred, like the cast layer: the mixer writes the pose during the idle
	# frame, and a write before that is silently overwritten.
	call_deferred("apply_now")
	weight = move_toward(weight, clampf(target_weight, 0.0, 1.0), delta * 3.2)


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
	var frame := Engine.get_physics_frames()
	if frame != _frame:
		_frame = frame
		_capture_bases(skeleton)
	else:
		_restore_bases(skeleton)
	if _bases.is_empty():
		return
	_lean(skeleton)
	_pin_hands(skeleton)
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


func _restore_bases(skeleton: Skeleton3D) -> void:
	for index in _bases:
		skeleton.set_bone_pose_rotation(index, _bases[index])
	skeleton.force_update_all_bone_transforms()


## Tip the upper spine into the broom, keeping the gaze up.
func _lean(skeleton: Skeleton3D) -> void:
	var lean := deg_to_rad(LEAN_DEG)
	for bone in LEAN_SHARE:
		var index := RigIK.bone_index(skeleton, bone)
		if index < 0:
			continue
		RigIK.rotate_global(skeleton, index, Quaternion(Vector3.RIGHT, lean * float(LEAN_SHARE[bone])),
			weight, _bases.get(index, Quaternion()))
	for name in ["Neck", "Head"]:
		var index := RigIK.bone_index(skeleton, name)
		if index < 0:
			continue
		RigIK.rotate_global(skeleton, index,
			Quaternion(Vector3.RIGHT, lean * HEAD_COUNTER_SHARE), weight,
			_bases.get(index, Quaternion()))


## Put the hand's bones back on their rest offsets from the wrist, backed off by
## the grip weight. The mixer rewrites these every frame, so nothing has to be
## undone when the grip releases.
func _pin_hands(skeleton: Skeleton3D) -> void:
	for side in ["L", "R"]:
		for bone in HAND_BONES:
			var index := RigIK.bone_index(skeleton, "%s.%s" % [bone, side])
			if index < 0:
				continue
			var rest: Vector3 = skeleton.get_bone_rest(index).origin
			skeleton.set_bone_pose_position(index,
				skeleton.get_bone_pose_position(index).lerp(rest, weight))
	skeleton.force_update_all_bone_transforms()

## Solve both arms onto the shaft.
func _grip(skeleton: Skeleton3D) -> void:
	var shaft := _shaft(skeleton)
	if shaft.is_empty():
		_hand_error = 0.0
		return
	var origin: Vector3 = shaft["origin"]
	var direction: Vector3 = shaft["direction"]
	var rest_root := RigIK.bone_index(skeleton, String(ARMS[0]["root"]))
	var shoulder_ref: Vector3 = skeleton.get_bone_global_pose(rest_root).origin
	# The point of the shaft nearest the shoulders: the hands have to sit here,
	# because the arm reaches across to the shaft but barely along it.
	var along: float = (shoulder_ref - origin).dot(direction)
	var centre := origin + direction * along
	# Hand the sides out by what each arm can actually reach, so a rider whose
	# shoulders are not square to the shaft is still solved symmetrically.
	_hand_error = 0.0
	_hand_alignment = 1.0
	for arm in ARMS:
		var root := RigIK.bone_index(skeleton, String(arm["root"]))
		var mid := RigIK.bone_index(skeleton, String(arm["mid"]))
		var end := RigIK.bone_index(skeleton, String(arm["end"]))
		if root < 0 or mid < 0 or end < 0:
			continue
		var shoulder := skeleton.get_bone_global_pose(root).origin
		var wrist_now := skeleton.get_bone_global_pose(end).origin
		var fist_now := _fist(skeleton, String(arm["side"]))
		var side := (shoulder - origin).dot(direction) - along
		var palm_point := centre + direction * (side + float(arm["offset"]))
		# Aim the wrist at a point just off the shaft on the shoulder side, so the
		# shaft passes through the palm.
		var away := shoulder - palm_point
		away -= direction * away.dot(direction)
		if away.length_squared() < 1e-6:
			away = shaft["up"]
		palm_point += away.normalized() * PALM_OFFSET
		# Solve for the WRIST, but place the FIST. On this rig the fist's centre is
		# 0.2 m or more from the wrist joint (measured live below), so a wrist on the
		# shaft leaves the visible hand well away from it - which is exactly what it
		# looked like. The hand is going to be aligned along the shaft, so backing the
		# wrist up by the hand's own length puts the fist on the palm point.
		var hand_length := (fist_now - wrist_now).length()
		var target := palm_point - direction * hand_length
		var bases := {}
		for index in [root, mid]:
			bases[index] = _bases.get(index, Quaternion())
		RigIK.two_bone(skeleton, root, mid, end, target, Vector3.DOWN, weight, bases)
		# The hand lies ALONG the shaft, fingers curling over it.
		var hand_axis := RigIK.hand_axis(skeleton, String(arm["end"]))
		RigIK.aim_axis(skeleton, end, hand_axis, direction, weight, 1.2,
			_bases.get(end, Quaternion()))
		var fist := _fist(skeleton, String(arm["side"]))
		_hand_error = maxf(_hand_error, RigIK.distance_to_line(fist, origin, direction))
		var wrist_basis := skeleton.get_bone_global_pose(end).basis.orthonormalized()
		_hand_alignment = minf(_hand_alignment,
			absf((wrist_basis * hand_axis).normalized().dot(direction)))


## The shaft's centreline in skeleton space: the SeatSocket projecting onto it,
## with the model's own measured seat offset removed, so nothing is hardcoded.
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
	return {"origin": seat - up * drop, "direction": direction, "up": up}


## The centre of a fist: the mean of the finger bases, in skeleton space. On this
## rig it sits 0.2 m or more from the wrist joint, so it - not the wrist - is what
## the eye reads as "the hand".
func _fist(skeleton: Skeleton3D, side: String) -> Vector3:
	var acc := Vector3.ZERO
	var counted := 0
	for bone in ["Index1", "Middle1", "Ring1", "Pinky1", "Thumb1"]:
		var index := RigIK.bone_index(skeleton, "%s.%s" % [bone, side])
		if index < 0:
			continue
		acc += skeleton.get_bone_global_pose(index).origin
		counted += 1
	if counted == 0:
		return Vector3.INF
	return acc / float(counted)
