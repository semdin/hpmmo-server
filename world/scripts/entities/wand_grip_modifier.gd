extends SkeletonModifier3D
class_name WandGripModifier

## Write only in the modifier pass, so Godot restores the animation afterwards.
var weight := 1.0
var target_weight := 1.0

func _process_modification_with_delta(delta: float) -> void:
	weight = move_toward(weight, clampf(target_weight, 0.0, 1.0), delta * 5.0)
	var skeleton := get_skeleton()
	if skeleton != null and weight > 0.001:
		RigIK.close_hand(skeleton, "R", weight)
