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

var animation: Animation = null
var weight := 0.0
var time := 0.0
var playing := false
## Bone name -> tracks that belong to it (index into the Animation).
var upper_tracks: Array[int] = []
var lower_prefixes := ["Hips", "Body", "Root", "UpperLeg", "LowerLeg", "Foot", "PT"]
func _bone_of(path: NodePath) -> String:
	var text := String(path)
	if not text.contains(":"):
		return ""
	return text.split(":")[-1]

var writes := 0
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

func stop() -> void:
	playing = false

func upper_bone_count() -> int:
	return upper_tracks.size()

func _process_modification_with_delta(delta: float) -> void:
	# The mixer writes its own pose during the idle frame; writing here would be
	# overwritten whenever this node is processed before the AnimationTree. The
	# layer therefore applies itself deferred, at the end of the frame, and the
	# skeleton renders the masked result.
	call_deferred("apply_now")
	time += delta

## Apply the mask at the end of the frame (see _process_modification_with_delta).
func apply_now() -> void:
	if not is_inside_tree():
		return
	_apply()

func _process_modification() -> void:
	_apply()

func _apply() -> void:
	var skeleton := get_skeleton()
	if not playing or animation == null or skeleton == null or weight <= 0.001:
		return
	var clamped := clampf(time, 0.0, maxf(0.0, animation.length))
	for track in upper_tracks:
		var bone := _bone_of(animation.track_get_path(track))
		if bone == "":
			continue
		var index := skeleton.find_bone(bone)
		if index < 0:
			index = skeleton.find_bone(bone.replace(".", "_"))
		if index < 0:
			continue
		var cast_pose: Quaternion = animation.rotation_track_interpolate(track, clamped)
		if weight >= 0.999:
			skeleton.set_bone_pose_rotation(index, cast_pose)
		else:
			var current := skeleton.get_bone_pose_rotation(index)
			skeleton.set_bone_pose_rotation(index, current.slerp(cast_pose, weight))
