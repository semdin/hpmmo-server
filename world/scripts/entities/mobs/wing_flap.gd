extends SkeletonModifier3D

## Beats a flier's wings (the Cornish pixie's Left/Right WingUp/WingLow bones,
## meshy_merge_clips --wings). Runs after the AnimationPlayer, so the clip keeps
## posing the body while the wings stroke up and down about the body's forward
## axis with a little backward sweep, the lower pair a beat behind the upper.
## mob_base sets `pace` (0 hover .. 1 full flight), `rate_scale` (crowd
## control: 0 = frozen) and `folded` (dead: the wings sag still).

const WINGS := {
	"LeftWingUp": [1.0, 0.0],
	"RightWingUp": [-1.0, 0.0],
	"LeftWingLow": [1.0, 0.9],
	"RightWingLow": [-1.0, 0.9],
}
## Beats per second hovering and at full pace; degrees of the up-down stroke.
var hover_rate := 7.0
var flight_rate := 10.0
var stroke_degrees := 34.0
var pace := 0.0
var rate_scale := 1.0
var folded := false
var _phase := randf() * TAU
var _open := 1.0   # eased to 0 when folded, so a falling pixie's wings settle
var _bones: Array = []   # [index, side, lag, parent rest rotation]

func _process_modification_with_delta(delta: float) -> void:
	var skeleton := get_skeleton()
	if skeleton == null:
		return
	if _bones.is_empty():
		for bone_name in WINGS:
			var idx := skeleton.find_bone(bone_name)
			if idx < 0:
				continue
			var parent := skeleton.get_bone_parent(idx)
			var rest := skeleton.get_bone_global_rest(parent).basis.get_rotation_quaternion() if parent >= 0 else Quaternion.IDENTITY
			_bones.append([idx, WINGS[bone_name][0], WINGS[bone_name][1], rest])
		if _bones.is_empty():
			active = false
			return
	_open = move_toward(_open, 0.0 if folded else 1.0, delta * 2.0)
	_phase = fmod(_phase + delta * lerpf(hover_rate, flight_rate, pace) * rate_scale * _open * TAU, TAU)
	var stroke := deg_to_rad(stroke_degrees)
	for entry in _bones:
		var side: float = entry[1]
		var s := sin(_phase - float(entry[2]))
		# Model space: +X is the body's left, +Y up, +Z forward. A positive turn
		# about Z lifts a left wing tip; the mirrored sign lifts the right one.
		var up := side * (stroke * s * _open - deg_to_rad(28.0) * (1.0 - _open))
		var sweep := side * deg_to_rad(10.0 + 8.0 * pace) * (0.5 + 0.5 * cos(_phase - float(entry[2])))
		var turn := Quaternion(Vector3(0, 0, 1), up) * Quaternion(Vector3.UP, sweep)
		var parent_rest: Quaternion = entry[3]
		var local_turn := parent_rest.inverse() * turn * parent_rest
		skeleton.set_bone_pose_rotation(entry[0], local_turn * skeleton.get_bone_pose_rotation(entry[0]))
