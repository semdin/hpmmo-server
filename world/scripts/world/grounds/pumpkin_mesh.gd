extends RefCounted
class_name PumpkinMesh

## Hagrid's pumpkins: the meshes of assets/models/grounds/pumpkin.glb, drawn
## many times by MultiMeshes. Modelled and baked in Blender (art/pumpkin/
## pumpkin_work.blend): ten rounded lobes over deep grooves, a crown dimple and
## a ridged, bent stem; the mottled skin, its darkened grooves and the green
## crown are baked from a 51k-face sculpt into a 1k albedo + normal map on a
## 1.7k-face mesh. The broad lobed leaves lie on the ground between them.
## Unit size: about 1 m across and 0.75 m tall before the instance scale.
## Replaces the procedural lathe that rendered with holes.

const SOURCE := "res://assets/models/grounds/pumpkin.glb"

static var _meshes: Dictionary = {}


## The pumpkin (skin + stem surfaces).
static func mesh() -> Mesh:
	return _mesh("Pumpkin")


## One lobed leaf lying flat, its stalk end at the origin.
static func leaf_mesh() -> Mesh:
	return _mesh("PumpkinLeaf")


static func _mesh(node_name: String) -> Mesh:
	if _meshes.is_empty():
		_load()
	return _meshes.get(node_name)


## Pull the meshes out of the scene once. The surfaces take the MultiMesh
## instance colour (the materials multiply vertex colour, white on the skin),
## so every pumpkin in the patch is a shade apart.
static func _load() -> void:
	var packed := load(SOURCE) as PackedScene
	if packed == null:
		return
	var scene := packed.instantiate()
	for node in scene.find_children("*", "MeshInstance3D", true, false):
		var mi := node as MeshInstance3D
		var source := mi.mesh
		var copy := source.duplicate() as Mesh
		for i in copy.get_surface_count():
			var mat := copy.surface_get_material(i)
			if mat is StandardMaterial3D:
				var m := (mat as StandardMaterial3D).duplicate() as StandardMaterial3D
				m.vertex_color_use_as_albedo = true
				m.vertex_color_is_srgb = false   # glTF vertex colours are linear
				if mi.name == "PumpkinLeaf":
					m.cull_mode = BaseMaterial3D.CULL_DISABLED
				copy.surface_set_material(i, m)
		_meshes[String(mi.name)] = copy
	scene.free()
