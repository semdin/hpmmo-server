extends SkeletonModifier3D
class_name RigFollower

## Keeps props that hang off a bone glued to the FINAL pose of that bone.
##
## `BoneAttachment3D` looks like the right tool for this and is not: it follows
## the skeleton's `pose_updated` notification, which the skeleton emits while it
## updates itself - BEFORE the `SkeletonModifier3D` nodes that pose the arms. The
## equipped wand therefore sat at the clip-only pose while a cast aimed the hand
## somewhere else; measured, the attachment froze at (0.303, 1.154, 4.947) while
## the wrist it was bound to travelled 0.4 m.
##
## This modifier applies itself deferred, i.e. after the other modifiers have
## written their poses, and places each follower in SKELETON space from
## `get_bone_global_pose` - the same pose the mixer, the cast layer and the aim
## all ended on. So a prop cannot lag the pose that moved the hand.
##
## It also serves the character-select podium, which plays a single idle clip and
## has no player to do the wiring.

## One entry per followed prop: {node, bone, index, local}.
var _followers: Array[Dictionary] = []


## Glue `node` to `bone`, offset by `local_transform` in that bone's space.
func attach(node: Node3D, bone: String, local_transform: Transform3D) -> void:
	if node == null:
		return
	_followers.append({"node": node, "bone": bone, "index": -1, "local": local_transform})
	_apply()


## Stop following `node` (it is about to be freed).
func detach(node: Node) -> void:
	for i in range(_followers.size() - 1, -1, -1):
		if _followers[i]["node"] == node:
			_followers.remove_at(i)


func followed(node: Node) -> bool:
	for entry in _followers:
		if entry["node"] == node:
			return true
	return false


func _process_modification_with_delta(_delta: float) -> void:
	# Deferred, so this runs after the cast layer and the aim have written: see the
	# class comment for the measurement that makes that ordering load-bearing.
	call_deferred("apply_now")


func _process_modification() -> void:
	_apply()


func apply_now() -> void:
	if not is_inside_tree():
		return
	_apply()


func _apply() -> void:
	var skeleton := get_skeleton()
	if skeleton == null:
		return
	for entry in _followers:
		var node: Node3D = entry["node"]
		if node == null or not is_instance_valid(node):
			continue
		var index: int = entry["index"]
		if index < 0:
			index = _bone_index(skeleton, String(entry["bone"]))
			entry["index"] = index
		if index < 0:
			continue
		# Skeleton space, which is also this node's parent space - the follower
		# lives on the skeleton, so no world conversion is needed.
		node.transform = skeleton.get_bone_global_pose(index) * (entry["local"] as Transform3D)


func _bone_index(skeleton: Skeleton3D, bone: String) -> int:
	var index := skeleton.find_bone(bone)
	if index < 0:
		index = skeleton.find_bone(bone.replace(".", "_"))
	if index < 0:
		index = skeleton.find_bone(bone.replace("_", "."))
	return index


## The rig's follower, created on demand. Callers that need a prop glued to the
## final pose ask for this rather than adding their own; one per skeleton.
static func of(skeleton: Skeleton3D) -> RigFollower:
	if skeleton == null:
		return null
	var existing := skeleton.get_node_or_null("RigFollower")
	if existing is RigFollower:
		return existing as RigFollower
	var follower := RigFollower.new()
	follower.name = "RigFollower"
	skeleton.add_child(follower)
	return follower
