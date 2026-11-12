extends RefCounted
class_name StandingCards

## A flipbook clip standing on the ground at many points: one MultiMesh of
## cards that face the camera about Y (standing_flipbook.gdshader), one draw
## call for a whole ring. The flames on a boss warning's boundary, the light
## over a portal. Presentation only; the atlas is loaded at run time so a
## script the server compiles never drags the texture in.

const SHADER := preload("res://assets/shaders/standing_flipbook.gdshader")

## The card mesh, one material per clip and the clips, kept for the whole
## process (a shader dropped with its last user is compiled again by the next).
static var _kept: Dictionary = {}

## Cards at `points` (in the parent's space), each `width` x `height` metres
## (both [min, max]), playing `atlas_path` (an 8x8 flipbook) at `fps`. White
## `tint` keeps the clip's own colours. Null when the clip is missing.
static func make(atlas_path: String, points: PackedVector3Array, width: Vector2, height: Vector2,
		fps: float, tint: Color = Color(1, 1, 1)) -> MultiMeshInstance3D:
	if not _kept.has(atlas_path):
		_kept[atlas_path] = load(atlas_path) if ResourceLoader.exists(atlas_path) else null
	var atlas := _kept[atlas_path] as Texture2D
	if atlas == null or points.is_empty():
		return null
	if not _kept.has("mesh"):
		var quad := QuadMesh.new()
		quad.size = Vector2(1.0, 1.0)
		quad.center_offset = Vector3(0.0, 0.5, 0.0)   # stands on its origin
		_kept["mesh"] = quad
	var key := "material|" + atlas_path
	if not _kept.has(key):
		var base := ShaderMaterial.new()
		base.shader = SHADER
		base.set_shader_parameter("flipbook", atlas)
		_kept[key] = base
	# its own copy: height and strength are this mark's own
	var material := (_kept[key] as ShaderMaterial).duplicate() as ShaderMaterial
	material.set_shader_parameter("fps", fps)
	material.set_shader_parameter("tint", tint)
	var multi := MultiMesh.new()
	multi.transform_format = MultiMesh.TRANSFORM_3D
	multi.use_custom_data = true
	multi.mesh = _kept["mesh"]
	multi.instance_count = points.size()
	var reach := 0.0
	for i in points.size():
		var size := Vector3(randf_range(width.x, width.y), randf_range(height.x, height.y), 1.0)
		multi.set_instance_transform(i, Transform3D(Basis.from_scale(size), points[i]))
		multi.set_instance_custom_data(i, Color(randf(), float(randi() % 2), 0.0, 0.0))
		reach = maxf(reach, Vector2(points[i].x, points[i].z).length())
	var node := MultiMeshInstance3D.new()
	node.name = "StandingCards"
	node.multimesh = multi
	node.material_override = material
	node.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	# the cards are placed by the shader: a box that holds them all
	var span := reach + width.y
	node.custom_aabb = AABB(Vector3(-span, -2.5, -span), Vector3(span * 2.0, height.y * 2.0 + 5.0, span * 2.0))
	return node

## Set every card on the ground under it (a ray each, world layer). Call from
## a physics step, once the node is in the tree: the mark is flat, the ground
## is not.
static func settle(node: MultiMeshInstance3D) -> void:
	if node == null or not is_instance_valid(node) or not node.is_inside_tree() or node.get_world_3d() == null:
		return
	var space := node.get_world_3d().direct_space_state
	if space == null:
		return
	var multi := node.multimesh
	var to_world := node.global_transform
	for i in multi.instance_count:
		var xform := multi.get_instance_transform(i)
		var at := to_world * xform.origin
		var query := PhysicsRayQueryParameters3D.create(at + Vector3.UP * 1.6, at + Vector3.DOWN * 2.4, 1)
		var hit := space.intersect_ray(query)
		if not hit.is_empty():
			xform.origin.y += (hit.position as Vector3).y - at.y
			multi.set_instance_transform(i, xform)
