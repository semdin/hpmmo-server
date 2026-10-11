extends SkeletonModifier3D
class_name CastLayerModifier

## Rig upper-body casting layer.
##
## Godot's Blend2 nodes pull any track a clip does not animate toward the rest
## pose, so blending an upper-body-only clip through the animation tree drags
## the legs (measured: 0.46 rad of leg drift). A `SkeletonModifier3D` runs after
## the mixer has written its pose, which makes it the right place for a masked
## layer: this node samples the cast clip's upper-body tracks and writes only
## those bones, slerped by the layer weight, leaving every other bone exactly as
## the locomotion layer left it.
##
## It also owns the CAST AIM, because the two have to be written in one place: the
## clip supplies the pose, and the aim then turns the casting arm so the wand
## points at the target. Only arm bones are touched, so the layer still cannot
## disturb the lower body.
##
## The aim exists because the clip alone does not point anywhere: `Spellcast_Shoot`
## is a retarget of a generic "spell shoot" gesture, so the character faced the
## target while its wand hung down the leg (measured wand-to-aim dot -0.51 at
## release). The aim runs in two steps: a two-bone solve reaches the arm toward
## the target, and then the wrist is turned so the WAND's own axis - the wand
## rides the wrist bone, not the forearm - lands on the target.

var animation: Animation = null
var weight := 0.0
var time := 0.0
var playing := false
var _elapsed := 0.0
var _release_at := -1.0
var _release_clip_time := 0.0
var _duration := 0.0
var _release_phase := 0.6
## Bone name -> tracks that belong to it (index into the Animation).
var upper_tracks: Array[int] = []
var lower_prefixes := ["Hips", "Body", "Root", "UpperLeg", "LowerLeg", "Foot", "PT"]

## The casting hand's bone chain. `UpperArm.R` is the shoulder joint: the clavicle
## (Shoulder.R -> UpperArm.R) is left to the clip so the aim never dislocates it.
const AIM_ROOT_BONE := "UpperArm.R"
const AIM_MID_BONE := "LowerArm.R"
const AIM_END_BONE := "Wrist.R"
## How far short of full extension the aim targets the wrist, so the elbow keeps a
## natural bend instead of locking.
const AIM_EXTENSION := 0.97
## A wrist has a range; a solve that has to twist it further than this is asking
## the hand to do something a hand cannot, so the correction is clamped rather
## than allowed to snap the wrist. The aim blends in with the cast layer's own
## weight, so it needs no ramp of its own.
const AIM_MAX_WRIST_TWIST := 1.2

## World-space point the casting arm points at, and whether the aim is in force.
var aim_point := Vector3.ZERO
var _aim_active := false
var _hold_aim := false
## Clip rotations used as the blend source for the arm aim in this modifier pass.
var _clip_rotations := {}
var gesture_time := 0.0
var gesture_duration := 0.42
var gesture_strength := 0.0
var gesture_side := 1.0
var gesture_spell := ""

func set_gesture(spell: String, combo: int, duration: float) -> void:
	gesture_time = 0.0
	gesture_duration = duration
	gesture_spell = spell
	gesture_strength = float({"stupefy": 1.0, "incendio": 0.8, "bombarda": 1.2,
		"expelliarmus": 0.75, "protego": 0.55, "ultimate": 1.4}.get(spell, (0.8 if combo == 2 else 0.6) if spell == "basic_cast" else 0.0))
	gesture_side = -1.0 if combo == 1 else 1.0

func _bone_of(path: NodePath) -> String:
	var text := String(path)
	if not text.contains(":"):
		return ""
	return text.split(":")[-1]

func configure(clip: Animation) -> void:
	animation = clip
	upper_tracks.clear()
	if clip == null:
		return
	for i in range(clip.get_track_count()):
		if clip.track_get_type(i) != Animation.TYPE_ROTATION_3D:
			continue
		var bone := _bone_of(clip.track_get_path(i))
		if bone == "" or _is_lower(bone):
			continue
		upper_tracks.append(i)

func _is_lower(bone: String) -> bool:
	for prefix in lower_prefixes:
		if bone.begins_with(prefix):
			return true
	return false

func play(clip: Animation, start_time := 0.0) -> void:
	if clip != null and clip != animation:
		configure(clip)
	playing = true
	time = start_time
	_elapsed = start_time
	_release_at = -1.0
	_release_phase = 0.6
	_hold_aim = false
	gesture_time = 0.0
	gesture_strength = 0.0
	gesture_spell = ""

func stop() -> void:
	_hold_aim = _aim_active
	playing = false

func align_release(seconds: float, clip_fraction: float, duration: float) -> void:
	if animation == null:
		return
	_duration = maxf(0.02, duration)
	_release_at = clampf(seconds, 0.01, _duration - 0.01)
	_release_clip_time = animation.length * clip_fraction
	_release_phase = _release_at / _duration
	_elapsed = 0.0
	time = 0.0

## Deterministic mapping also lets captures sample the actual release pose.
func clip_time_at(elapsed: float) -> float:
	if _release_at < 0.0 or animation == null:
		return elapsed
	if elapsed <= _release_at:
		return _release_clip_time * clampf(elapsed / _release_at, 0.0, 1.0)
	return lerpf(_release_clip_time, animation.length,
		clampf((elapsed - _release_at) / (_duration - _release_at), 0.0, 1.0))

func upper_bone_count() -> int:
	return upper_tracks.size()

## Point the casting arm at `point` (world space) while the cast layer is blended
## in. Pass `active = false` to hand the arm back to the clip.
func set_aim(point: Vector3, active: bool) -> void:
	if active:
		aim_point = point
	elif playing:
		_hold_aim = false
	_aim_active = active

func aim_active() -> bool:
	return _aim_active

func _process_modification_with_delta(delta: float) -> void:
	if playing:
		_elapsed += delta
		time = clip_time_at(_elapsed)
		gesture_time += delta
	_apply()

func _apply() -> void:
	var skeleton := get_skeleton()
	if skeleton == null:
		return
	_clip_rotations.clear()
	# Retain the final pose while weight fades; stopping sampling immediately
	# discarded the entire upper-body layer in a single frame.
	if animation != null and weight > 0.001:
		var clamped := clampf(time, 0.0, maxf(0.0, animation.length))
		for track in upper_tracks:
			var bone := _bone_of(animation.track_get_path(track))
			if bone == "":
				continue
			var index := _bone_index(skeleton, bone)
			if index < 0:
				continue
			var cast_pose: Quaternion = animation.rotation_track_interpolate(track, clamped)
			_clip_rotations[bone] = cast_pose
			if weight >= 0.999:
				skeleton.set_bone_pose_rotation(index, cast_pose)
			else:
				var current := skeleton.get_bone_pose_rotation(index)
				skeleton.set_bone_pose_rotation(index, current.slerp(cast_pose, weight))
	_apply_cast_torso(skeleton)
	_apply_aim(skeleton)

func _apply_cast_torso(skeleton: Skeleton3D) -> void:
	if animation == null or weight <= 0.001:
		return
	var phase := clampf(gesture_time / maxf(0.05, gesture_duration), 0, 1)
	var envelope := sin(phase * PI) * weight
	var yaw := 0.0
	var pitch := 0.0
	match gesture_spell:
		"incendio": yaw = lerpf(-0.16, 0.16, phase) * envelope
		"bombarda": pitch = -0.13 * envelope
		"expelliarmus": yaw = 0.17 * sin(phase * TAU) * envelope
		"protego": pitch = 0.08 * envelope
		"ultimate": pitch = -0.19 * envelope
	for name in ["Chest", "Torso", "Abdomen"]:
		var index := _bone_index(skeleton, name)
		if index >= 0 and _clip_rotations.has(skeleton.get_bone_name(index)):
			var rotation := skeleton.get_bone_pose_rotation(index)
			skeleton.set_bone_pose_rotation(index, rotation * Quaternion(Vector3.UP, yaw) * Quaternion(Vector3.RIGHT, pitch))
			break

## ---------------------------------------------------------------- aim

## Reach the casting arm at `aim_point`, then turn the WRIST so the wand's own
## axis - the prop rides the wrist bone, not the forearm - lands on the target.
func _apply_aim(skeleton: Skeleton3D) -> void:
	if (not _aim_active and not _hold_aim) or weight <= 0.001:
		return
	var root := _bone_index(skeleton, AIM_ROOT_BONE)
	var mid := _bone_index(skeleton, AIM_MID_BONE)
	var end := _bone_index(skeleton, AIM_END_BONE)
	if root < 0 or mid < 0 or end < 0:
		return
	skeleton.force_update_all_bone_transforms()
	# The aim point arrives in world space; every pose query is in skeleton space.
	var to_aim: Vector3 = skeleton.global_transform.affine_inverse() * aim_point
	var shoulder := skeleton.get_bone_global_pose(root).origin
	var towards := to_aim - shoulder
	if towards.length_squared() < 1e-6:
		return
	var elbow_live := skeleton.get_bone_global_pose(mid).origin
	var end_live := skeleton.get_bone_global_pose(end).origin
	var upper_len := shoulder.distance_to(elbow_live)
	var lower_len := elbow_live.distance_to(end_live)
	# Target just inside full extension so the elbow keeps a natural bend.
	# A short elbow draw, quick extension, then recoil. The wrist continues to
	# aim at the actual target; locomotion and the wand grip remain untouched.
	var phase := clampf(gesture_time / maxf(0.05, gesture_duration), 0.0, 1.0)
	var snap := smoothstep(_release_phase * 0.45, _release_phase, phase)
	var recoil := smoothstep(_release_phase + 0.04, 1.0, phase)
	var extension := AIM_EXTENSION - gesture_strength * (0.25 * (1.0 - snap) + 0.16 * recoil)
	var side := towards.normalized().cross(Vector3.UP).normalized()
	var sweep := sin(phase * PI * 2.0) * (1.0 - snap) * gesture_strength * 0.12 * gesture_side
	var lift := 0.0
	match gesture_spell:
		"incendio":
			sweep = lerpf(-0.2, 0.22, smoothstep(0, 0.65, phase)) * sin(phase * PI)
			lift = 0.05 * sin(phase * PI)
		"bombarda":
			lift = 0.14 * (1.0 - snap)
		"expelliarmus":
			sweep = 0.26 * sin(phase * TAU) * (1.0 - phase)
			lift = 0.08 * sin(phase * TAU)
		"protego":
			extension = 0.68
			lift = 0.22 * sin(phase * PI)
			sweep = 0.13 * sin(phase * PI)
		"ultimate":
			lift = 0.22 * (1.0 - snap) - 0.07 * recoil
	var target := shoulder + towards.normalized() * ((upper_len + lower_len) * extension) + side * sweep + Vector3.UP * lift
	var bases := {}
	for bone in [root, mid]:
		bases[bone] = _clip_rotations.get(skeleton.get_bone_name(bone), Quaternion())
	RigIK.two_bone(skeleton, root, mid, end, target, Vector3.DOWN, weight, bases)
	var aimed_wrist := skeleton.get_bone_global_pose(end).origin
	var wanted := to_aim - aimed_wrist
	if wanted.length_squared() > 1e-6:
		if gesture_spell in ["bombarda", "ultimate"]:
			# Share the raised/heavy pose's correction with forearm pronation;
			# the wrist keeps its normal limit and the hand stays at the IK target.
			var forearm := (aimed_wrist - skeleton.get_bone_global_pose(mid).origin).normalized()
			var wand_axis := skeleton.get_bone_global_pose(end).basis * HeroAppearance.wand_axis_in_wrist(skeleton)
			var current_flat := wand_axis.slide(forearm)
			var wanted_flat := wanted.slide(forearm)
			if current_flat.length_squared() > 0.0001 and wanted_flat.length_squared() > 0.0001:
				var roll := clampf(current_flat.signed_angle_to(wanted_flat, forearm), -1.1, 1.1)
				RigIK.rotate_global(skeleton, mid, Quaternion(forearm, roll), weight, skeleton.get_bone_pose_rotation(mid))
		_aim_axis(skeleton, end, HeroAppearance.wand_axis_in_wrist(skeleton), wanted)

## Rotate `bone` so an axis fixed in that bone (`axis_local`, e.g. the wand's own
## long axis in the wrist's frame) points along `wanted`, blended by the layer
## weight over what the clip wrote for that bone.
func _aim_axis(skeleton: Skeleton3D, bone: int, axis_local: Vector3, wanted: Vector3) -> void:
	RigIK.aim_axis(skeleton, bone, axis_local, wanted, weight, AIM_MAX_WRIST_TWIST,
		_clip_rotations.get(skeleton.get_bone_name(bone), Quaternion()))

func _bone_index(skeleton: Skeleton3D, bone: String) -> int:
	return RigIK.bone_index(skeleton, bone)
