extends RefCounted

## Art pass static batching (replaces the castle whole-interior merge).
##
## Two things changed from the greybox version:
##   1. Instances are grouped by material *and by a 24 m chunk cell*, so the
##      renderer can cull the interior room by room instead of drawing one
##      interior-wide MultiMesh. "avoid one giant merged
##      interior mesh that defeats room-level culling."
##   2. Each instance carries a baked ambient-occlusion term in its instance
##      colour. The term is computed once per layout (see `_ao_for`) from the
##      module occupancy around it and cached across rebuilds, so torches read
##      against a settled light level instead of a flat one. This is a static
##      bake of the architecture's own occlusion; it is not a path-traced
##      lightmap (LightmapGI cannot bake procedural geometry at runtime).
##
## Collision bodies and named nodes are untouched; only the *visual* boxes are
## merged, exactly like the castle batch did.

const CHUNK := 24.0

## Bake results are keyed by the quantised module box so the identical layout is
## only ever analysed once per process (the walkthrough rebuilds it six times).
static var _ao_cache: Dictionary = {}

static func boxes(root: Node3D, bake_occlusion: bool = true) -> void:
	var groups: Dictionary = {}
	var inverse := root.global_transform.affine_inverse()
	var modules: Array = []
	for node in root.find_children("*", "MeshInstance3D", true, false):
		var instance := node as MeshInstance3D
		if not instance.mesh is BoxMesh or not instance.visible:
			continue
		var material := instance.get_active_material(0)
		if material == null:
			continue
		if material is ShaderMaterial:
			material.set_shader_parameter("use_baked_instance_ao", true)
		var local := inverse * instance.global_transform
		var centre := local.origin
		var size: Vector3 = (instance.mesh as BoxMesh).size
		modules.append({"centre": centre, "size": size})
		var key := "%s_%d_%d_%d" % [
			material.get_instance_id(),
			int(floor(centre.x / CHUNK)), int(floor(centre.y / CHUNK)),
			int(floor(centre.z / CHUNK))]
		if not groups.has(key):
			groups[key] = {"material": material, "instances": []}
		groups[key].instances.append(instance)

	var occupancy := _occupancy_index(modules) if bake_occlusion else {}
	var unit_box := BoxMesh.new()
	unit_box.size = Vector3.ONE
	var batch_index := 0
	for group in groups.values():
		var instances: Array = group.instances
		var batch := MultiMesh.new()
		batch.transform_format = MultiMesh.TRANSFORM_3D
		batch.use_colors = true
		batch.mesh = unit_box
		batch.instance_count = instances.size()
		for i in range(instances.size()):
			var instance: MeshInstance3D = instances[i]
			var transform := inverse * instance.global_transform
			transform.basis = transform.basis * Basis.from_scale((instance.mesh as BoxMesh).size)
			batch.set_instance_transform(i, transform)
			var ao := 1.0
			if bake_occlusion:
				ao = _ao_for(transform.origin, occupancy)
			batch.set_instance_color(i, Color(ao, ao, ao, 1.0))
			instance.hide()
		var renderer := MultiMeshInstance3D.new()
		# Unique per-chunk names: Godot renames duplicate siblings to generic
		# names, which would hide which chunk a batch belongs to.
		renderer.name = "ArchitectureBatch_%d" % batch_index
		batch_index += 1
		renderer.multimesh = batch
		renderer.material_override = group.material
		root.add_child(renderer)

# ------------------------------------------------------------------ occlusion

## A coarse spatial index of the architecture modules for the AO estimate.
static func _occupancy_index(modules: Array) -> Dictionary:
	var index: Dictionary = {}
	for entry in modules:
		var cell := _cell_of(entry["centre"])
		if not index.has(cell):
			index[cell] = []
		index[cell].append(entry)
	return index

static func _cell_of(point: Vector3) -> Vector3i:
	return Vector3i(int(floor(point.x / CHUNK)), int(floor(point.y / CHUNK)),
		int(floor(point.z / CHUNK)))

## Baked occlusion for one module: how much of the surrounding space within
## 3 m is occupied by other modules. Only two configurations count as
## occluding — something sitting above the module (a soffit or a floor over a
## room, delta.y > 0.8) and something right against it (a junction within
## 1.2 m). Coplanar neighbours, like the segments of a round tower wall, are
## not occlusion: they must not darken the wall. Cached by quantised box.
static func _ao_for(centre: Vector3, index: Dictionary) -> float:
	if index.is_empty():
		return 1.0
	var key := "%.2f_%.2f_%.2f" % [centre.x, centre.y, centre.z]
	if _ao_cache.has(key):
		return _ao_cache[key]
	var occupied := 0
	var checked := 0
	for dx in range(-1, 2):
		for dy in range(-1, 2):
			for dz in range(-1, 2):
				var cell := _cell_of(centre) + Vector3i(dx, dy, dz)
				if not index.has(cell):
					continue
				for other in index[cell]:
					var delta: Vector3 = (other["centre"] as Vector3) - centre
					var distance := delta.length()
					if distance < 0.05 or distance > 3.0:
						continue
					checked += 1
					if distance < 1.2:
						occupied += 1
					elif delta.y > 0.8:
						occupied += 1
	var ao: float = 1.0
	if checked > 0:
		ao = clampf(1.0 - float(occupied) / float(checked) * 0.55, 0.65, 1.0)
	_ao_cache[key] = ao
	return ao

static func clear_cache() -> void:
	_ao_cache.clear()
