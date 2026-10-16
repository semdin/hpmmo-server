extends SkeletonModifier3D

## Droops (Fluffy's fainted head) or withers (a burned Snare vine) the bone
## chains of parts that are down. Runs after the AnimationPlayer, so the clip
## keeps playing on everything else. `chains`: part key -> bone names, root
## first; `down`: the part keys to bend.

var chains: Dictionary = {}
var down: Array = []
## Degrees each bone of a downed chain bends (about its local X) and the scale
## it shrinks to (1.0 = keep size).
var bend_degrees := 22.0
var shrink := 1.0
var _blend: Dictionary = {}   # key -> 0..1, eased in so a part sags rather than snaps

func _process_modification_with_delta(delta: float) -> void:
	var skeleton := get_skeleton()
	if skeleton == null:
		return
	for key in chains.keys():
		var target := 1.0 if down.has(key) else 0.0
		var t := move_toward(float(_blend.get(key, 0.0)), target, delta * 0.8)
		_blend[key] = t
		if t <= 0.0:
			continue
		var turn := Quaternion(Vector3.RIGHT, deg_to_rad(bend_degrees) * t)
		var scale_to := lerpf(1.0, shrink, t)
		for bone_name in chains[key]:
			var idx := skeleton.find_bone(String(bone_name))
			if idx < 0:
				continue
			skeleton.set_bone_pose_rotation(idx, skeleton.get_bone_pose_rotation(idx) * turn)
			if scale_to != 1.0:
				skeleton.set_bone_pose_scale(idx, skeleton.get_bone_pose_scale(idx) * scale_to)
