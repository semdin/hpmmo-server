extends RefCounted
class_name RigIK

## Rig maths shared by the procedural pose layers (`cast_layer_modifier.gd` aims
## the casting arm, `broom_grip_modifier.gd` puts the rider's hands on the shaft).
##
## Everything works in SKELETON space, because that is the space every pose query
## returns. The two facts it relies on were measured, not assumed
## (tools/pose_math.gd):
##
##   global_pose(bone) = global_pose(parent) * pose(bone)
##   pose(bone) is an ABSOLUTE local transform - it equals the bone's rest until
##   something writes it, and setting it does not touch the origin.
##
## So the pose rotation that makes a bone's global orientation become `q * global`
## is `parent_global.basis^-1 * q * bone_global.basis`, and every writer here
## blends that against what the ANIMATION wrote (not against the bone's current
## pose), which is what makes a second pass in the same frame harmless.
##
## Writes are followed by `force_update_all_bone_transforms()`, because the
## global-pose cache the next step reads is only refreshed by the skeleton itself
## otherwise - reading straight after a write would return the previous pose.


## The bone index for `bone` (see HeroBones), also accepting an importer-sanitised
## spelling (`.` <-> `_`) for skeletons from other sources.
static func bone_index(skeleton: Skeleton3D, bone: String) -> int:
	if skeleton == null:
		return -1
	var index := skeleton.find_bone(bone)
	if index < 0:
		index = skeleton.find_bone(bone.replace(".", "_"))
	if index < 0:
		index = skeleton.find_bone(bone.replace("_", "."))
	return index


## Rotate `bone` about its own origin so the direction to `child` becomes
## `wanted` (skeleton space).
static func aim_bone(skeleton: Skeleton3D, bone: int, child: int, wanted: Vector3,
		weight: float, base: Quaternion = Quaternion()) -> void:
	if wanted.length_squared() < 1e-8:
		return
	var parent := skeleton.get_bone_parent(bone)
	var parent_global := skeleton.get_bone_global_pose(parent) if parent >= 0 else Transform3D()
	var bone_global := skeleton.get_bone_global_pose(bone).basis.orthonormalized()
	var current := skeleton.get_bone_global_pose(child).origin - skeleton.get_bone_global_pose(bone).origin
	if current.length_squared() < 1e-8:
		return
	var turn := Quaternion(current.normalized(), wanted.normalized())
	var wanted_basis := parent_global.basis.orthonormalized().inverse() * (Basis(turn) * bone_global)
	write_rotation(skeleton, bone, wanted_basis.get_rotation_quaternion(), weight, base)


## Rotate `bone` so an axis fixed in that bone (`axis_local`) points along
## `wanted`. `max_twist` clamps the correction so a bad target cannot snap a joint.
static func aim_axis(skeleton: Skeleton3D, bone: int, axis_local: Vector3, wanted: Vector3,
		weight: float, max_twist := 0.0, base: Quaternion = Quaternion()) -> void:
	if axis_local.length_squared() < 1e-8 or wanted.length_squared() < 1e-8:
		return
	var parent := skeleton.get_bone_parent(bone)
	var parent_global := skeleton.get_bone_global_pose(parent) if parent >= 0 else Transform3D()
	var bone_global := skeleton.get_bone_global_pose(bone).basis.orthonormalized()
	var current := (bone_global * axis_local).normalized()
	var turn := Quaternion(current, wanted.normalized())
	if max_twist > 0.0 and turn.get_angle() > max_twist:
		turn = Quaternion(turn.get_axis(), max_twist)
	var wanted_basis := parent_global.basis.orthonormalized().inverse() * (Basis(turn) * bone_global)
	write_rotation(skeleton, bone, wanted_basis.get_rotation_quaternion(), weight, base)


## Rotate `bone` by `turn` in SKELETON space, i.e. `global(bone)` becomes
## `turn * global(bone)`.
static func rotate_global(skeleton: Skeleton3D, bone: int, turn: Quaternion,
		weight: float, base: Quaternion = Quaternion()) -> void:
	var parent := skeleton.get_bone_parent(bone)
	var parent_global := skeleton.get_bone_global_pose(parent) if parent >= 0 else Transform3D()
	var bone_global := skeleton.get_bone_global_pose(bone).basis.orthonormalized()
	var wanted := parent_global.basis.orthonormalized().inverse() * (Basis(turn) * bone_global)
	write_rotation(skeleton, bone, wanted.get_rotation_quaternion(), weight, base)


## The axis a hand points along, in that hand's own bone frame: the elbow -> wrist
## vector re-expressed in the wrist's frame. For a held prop use grip_frame's
## transverse axis instead; the handle crosses the palm.
static func hand_axis(skeleton: Skeleton3D, wrist_bone: String) -> Vector3:
	var wrist := bone_index(skeleton, wrist_bone)
	if wrist < 0:
		return Vector3.UP
	var rest := skeleton.get_bone_rest(wrist)
	var axis := (rest.basis.inverse() * rest.origin).normalized()
	if axis.length_squared() < 0.5:
		return Vector3.UP
	return axis


## Two-bone IK: place `end`'s origin as close to `target` as the `root -> mid ->
## end` chain allows, keeping the elbow on the side `pole_hint` suggests.
## Returns the position the end effector actually reached.
static func two_bone(skeleton: Skeleton3D, root: int, mid: int, end: int, target: Vector3,
		pole_hint: Vector3, weight: float, bases: Dictionary = {}) -> Vector3:
	# Segment lengths come from the LIVE pose, not the rest: these clips translate
	# bones as well as rotating them, and the posed segments measure 15-28% longer
	# than the rest (arm 0.550 m posed against 0.453 m at rest). A solve against the
	# rest lengths cannot reach its own target and leaves the hand short.
	var shoulder := skeleton.get_bone_global_pose(root).origin
	var elbow_live := skeleton.get_bone_global_pose(mid).origin
	var end_live := skeleton.get_bone_global_pose(end).origin
	var upper_len := shoulder.distance_to(elbow_live)
	var lower_len := elbow_live.distance_to(end_live)
	if upper_len < 0.001 or lower_len < 0.001:
		return end_live
	var toward := target - shoulder
	if toward.length_squared() < 1e-8:
		return skeleton.get_bone_global_pose(end).origin
	var axis := toward.normalized()
	# Keep the elbow where the pose already had it unless that is degenerate.
	var elbow := skeleton.get_bone_global_pose(mid).origin
	var offset := elbow - shoulder
	var pole := offset - axis * offset.dot(axis)
	if pole.length_squared() < 1e-6:
		pole = pole_hint - axis * pole_hint.dot(axis)
	if pole.length_squared() < 1e-6:
		pole = Vector3.DOWN
	pole = pole.normalized()
	var span := clampf(toward.length(), absf(upper_len - lower_len) + 1e-4, upper_len + lower_len - 1e-4)
	var cosine := clampf((upper_len * upper_len + span * span - lower_len * lower_len)
		/ (2.0 * upper_len * span), -1.0, 1.0)
	var bend := acos(cosine)
	var solved_elbow := shoulder + axis * (upper_len * cos(bend)) + pole * (upper_len * sin(bend))
	aim_bone(skeleton, root, mid, solved_elbow - shoulder, weight, bases.get(root, Quaternion()))
	aim_bone(skeleton, mid, end,
		target - skeleton.get_bone_global_pose(mid).origin, weight, bases.get(mid, Quaternion()))
	return skeleton.get_bone_global_pose(end).origin


## Blend a solved pose rotation over what the animation wrote for this bone.
##
## `base` is that animation value; pass it wherever it is known so repeated
## passes in one frame converge instead of compounding.
static func write_rotation(skeleton: Skeleton3D, bone: int, wanted: Quaternion,
		weight: float, base: Quaternion = Quaternion()) -> void:
	var from := base if base != Quaternion() else skeleton.get_bone_pose_rotation(bone)
	if weight >= 0.999:
		skeleton.set_bone_pose_rotation(bone, wanted)
	else:
		skeleton.set_bone_pose_rotation(bone, from.slerp(wanted, weight))
	skeleton.force_update_all_bone_transforms()


## Distance from `point` to the infinite line through `a` along `direction`.
static func distance_to_line(point: Vector3, a: Vector3, direction: Vector3) -> float:
	var dir := direction.normalized()
	var offset := point - a
	return (offset - dir * offset.dot(dir)).length()


## A grip across the knuckles (the heads of the proximal phalanges), on the
## palm side of the skin, in the hand bone's frame: x across the palm (little ->
## index), y along the hand toward the fingers.
static func grip_frame(skeleton: Skeleton3D, side: String, palm_depth := 0.026) -> Transform3D:
	var wrist := bone_index(skeleton, HeroBones.hand(side))
	var to_wrist := skeleton.get_bone_global_rest(wrist).affine_inverse()
	var knuckles: Array[Vector3] = []
	for finger in HeroBones.FINGERS:
		knuckles.append((to_wrist * skeleton.get_bone_global_rest(
			bone_index(skeleton, HeroBones.finger(side, finger, 0)))).origin)
	var across := (knuckles[0] - knuckles[3]).normalized()
	var forward := Vector3.UP
	forward = (forward - across * forward.dot(across)).normalized()
	var normal := across.cross(forward).normalized()
	if normal.dot(palm_normal(skeleton, side)) < 0.0:
		normal = -normal
	var centre := (knuckles[0] + knuckles[1] + knuckles[2] + knuckles[3]) * 0.25
	centre += normal * palm_depth - forward * 0.008
	return Transform3D(Basis(across, forward, across.cross(forward)), centre)


## Out of the palm, in the hand bone's rest frame, from the rest knuckles: with
## the fingers pointing forward and the palm down, a right hand has its index on
## the left (left hand: mirrored). Geometry, not a measured constant, so a
## re-rolled rig cannot flip it.
static func palm_normal(skeleton: Skeleton3D, side: String) -> Vector3:
	var wrist := bone_index(skeleton, HeroBones.hand(side))
	var to_wrist := skeleton.get_bone_global_rest(wrist).affine_inverse()
	var index := (to_wrist * skeleton.get_bone_global_rest(
		bone_index(skeleton, HeroBones.finger(side, "Index", 0)))).origin
	var little := (to_wrist * skeleton.get_bone_global_rest(
		bone_index(skeleton, HeroBones.finger(side, "Little", 0)))).origin
	var middle := (to_wrist * skeleton.get_bone_global_rest(
		bone_index(skeleton, HeroBones.finger(side, "Middle", 0)))).origin
	var across := (index - little).normalized()
	var forward := middle.normalized()
	if HeroBones.side_name(side) == "Right":
		return across.cross(forward).normalized()
	return forward.cross(across).normalized()


## The rotation, in `bone`'s own rest frame, that bends it `degrees` toward the
## palm: about (bone direction x palm normal), so the curl is right whatever
## roll the rig gave the finger.
static func _curl(skeleton: Skeleton3D, bone: int, palm_world: Vector3, degrees: float) -> Quaternion:
	var global := skeleton.get_bone_global_rest(bone).basis.orthonormalized()
	var axis := global.y.cross(palm_world)
	if axis.length_squared() < 1e-8:
		return Quaternion()
	return Quaternion((global.inverse() * axis).normalized(), deg_to_rad(degrees))


static func close_hand(skeleton: Skeleton3D, side: String, weight: float, palm_depth := 0.026) -> void:
	# Proximal, intermediate, distal flexion in degrees; a deeper palm (a thicker
	# handle) opens the fist a little.
	var finger_angles := [65.0, 85.0, 45.0]
	if palm_depth > 0.03:
		finger_angles = [50.0, 70.0, 40.0]
	var thumb_angles := [0.0, 25.0, 35.0]
	var hand_rest := skeleton.get_bone_global_rest(bone_index(skeleton, HeroBones.hand(side))).basis.orthonormalized()
	var palm_world := (hand_rest * palm_normal(skeleton, side)).normalized()
	for finger in HeroBones.FINGERS + ["Thumb"]:
		var angles: Array = thumb_angles if finger == "Thumb" else finger_angles
		for k in range(angles.size()):
			var name := HeroBones.thumb(side, k) if finger == "Thumb" else HeroBones.finger(side, finger, k)
			var index := bone_index(skeleton, name)
			if index < 0:
				continue
			var rest := skeleton.get_bone_rest(index)
			var rotation := rest.basis.get_rotation_quaternion() * _curl(skeleton, index, palm_world, angles[k])
			skeleton.set_bone_pose_position(index, skeleton.get_bone_pose_position(index).lerp(rest.origin, weight))
			skeleton.set_bone_pose_rotation(index, skeleton.get_bone_pose_rotation(index).slerp(rotation, weight))
	skeleton.force_update_all_bone_transforms()
	# Wrap the thumb over the handle: it runs along the outside of the handle and
	# its tip rests on the index finger's middle segment, the side away from the
	# palm (aimed at the handle's axis it sank inside the handle and read as an
	# open hand).
	var wrist := skeleton.get_bone_global_pose(bone_index(skeleton, HeroBones.hand(side)))
	var grip := grip_frame(skeleton, side, palm_depth)
	var out := palm_normal(skeleton, side)
	var thumb1 := bone_index(skeleton, HeroBones.thumb(side, 0))
	var thumb2 := bone_index(skeleton, HeroBones.thumb(side, 1))
	var thumb3 := bone_index(skeleton, HeroBones.thumb(side, 2))
	var base_target := wrist * (grip.origin + grip.basis.x * 0.045 - grip.basis.y * 0.03)
	aim_bone(skeleton, thumb1, thumb2, base_target - skeleton.get_bone_global_pose(thumb1).origin, weight)
	var knuckle_target := wrist * (grip.origin + grip.basis.x * 0.035 + out * (palm_depth * 0.6) - grip.basis.y * 0.012)
	aim_bone(skeleton, thumb2, thumb3, knuckle_target - skeleton.get_bone_global_pose(thumb2).origin, weight)
	var tip_target := wrist * (grip.origin + grip.basis.x * 0.012 + out * (palm_depth * 0.85))
	var thumb3_pose := skeleton.get_bone_global_pose(thumb3)
	aim_axis(skeleton, thumb3, Vector3.UP, tip_target - thumb3_pose.origin, weight)
