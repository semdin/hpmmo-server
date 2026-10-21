extends RefCounted

## Static batching for dressing built from code (castle decor, the moving
## staircase flights): many small MeshInstance3Ds that never move relative to
## a common parent become one mesh per material, so each costs one draw call
## per pass instead of one per piece.
##
## Materials are matched by value, not identity: the decor builders make a
## fresh iron StandardMaterial3D per sconce, and those must still batch.
## `cell` > 0 also splits the batches on a grid (metres), so a batch stays
## small enough for frustum and occlusion culling to drop it with its room.

## Merge `meshes` (descendants of `root`) into new children of `root`; the
## originals are freed. Hidden pieces and pieces with layers = 0 are left
## alone. Returns the number of meshes made.
static func merge(root: Node3D, meshes: Array, name_prefix: String = "Merged", cell: float = 0.0) -> int:
	var groups := {}
	var merged: Array = []
	for node in meshes:
		var mi := node as MeshInstance3D
		if mi == null or mi.mesh == null or not mi.visible or mi.layers == 0:
			continue
		var found: Variant = _relative_transform(root, mi)
		if found == null:
			continue
		var xform: Transform3D = found
		var cell_key := ""
		if cell > 0.0:
			var at := xform.origin / cell
			cell_key = "%d,%d,%d" % [floori(at.x), floori(at.y), floori(at.z)]
		for s in mi.mesh.get_surface_count():
			var mat := mi.get_active_material(s)
			var key := "%s|%s|%d" % [cell_key, _material_key(mat), mi.cast_shadow]
			if not groups.has(key):
				groups[key] = {"tool": SurfaceTool.new(), "material": mat, "shadow": mi.cast_shadow}
			(groups[key]["tool"] as SurfaceTool).append_from(mi.mesh, s, xform)
		merged.append(mi)
	var made := 0
	for key in groups:
		var group: Dictionary = groups[key]
		var mesh := (group["tool"] as SurfaceTool).commit()
		if mesh == null or mesh.get_surface_count() == 0:
			continue
		mesh.surface_set_material(0, group["material"])
		var out := MeshInstance3D.new()
		out.name = "%s%d" % [name_prefix, made]
		out.mesh = mesh
		out.cast_shadow = group["shadow"]
		root.add_child(out)
		made += 1
	for mi in merged:
		mi.get_parent().remove_child(mi)
		mi.queue_free()
	return made

## `node`'s transform in `root`'s space, from the local transforms (works
## before the tree is entered); null when `node` is not under `root`.
static func _relative_transform(root: Node3D, node: Node3D) -> Variant:
	var xform := node.transform
	var parent := node.get_parent()
	while parent != root:
		if parent == null:
			return null
		if parent is Node3D:
			xform = (parent as Node3D).transform * xform
		parent = parent.get_parent()
	return xform

static func _material_key(mat: Material) -> String:
	if mat is StandardMaterial3D:
		var m := mat as StandardMaterial3D
		return var_to_str([m.albedo_color, m.albedo_texture, m.metallic, m.roughness, m.emission_enabled,
			m.emission, m.emission_energy_multiplier, m.transparency, m.cull_mode, m.shading_mode])
	return str(mat.get_instance_id()) if mat != null else "none"
