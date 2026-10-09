extends SkeletonModifier3D
class_name RigFollower

## Read the rendered pose while skeleton_updated is emitted, after ALL modifiers.
## Outside this signal Godot has restored the unmodified animation pose.
func _ready() -> void:
	get_skeleton().skeleton_updated.connect(_apply)

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
