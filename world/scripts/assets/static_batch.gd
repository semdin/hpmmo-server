extends RefCounted

## Batch repeated architectural boxes while leaving their collision bodies
## and named nodes intact. Animated rigs and transparent FX are not included.
static func boxes(root: Node3D) -> void:
	var groups: Dictionary = {}
	var inverse := root.global_transform.affine_inverse()
	for node in root.find_children("*", "MeshInstance3D", true, false):
		var instance := node as MeshInstance3D
		if not instance.mesh is BoxMesh or not instance.visible:
			continue
		var material := instance.get_active_material(0)
		if material == null:
			continue
		var key := material.get_instance_id()
		if not groups.has(key):
			groups[key] = {"material": material, "instances": []}
		groups[key].instances.append(instance)
	var unit_box := BoxMesh.new()
	unit_box.size = Vector3.ONE
	for group in groups.values():
		var instances: Array = group.instances
		if instances.size() < 3:
			continue
		var batch := MultiMesh.new()
		batch.transform_format = MultiMesh.TRANSFORM_3D
		batch.mesh = unit_box
		batch.instance_count = instances.size()
		for i in range(instances.size()):
			var instance: MeshInstance3D = instances[i]
			var transform := inverse * instance.global_transform
			transform.basis = transform.basis * Basis.from_scale((instance.mesh as BoxMesh).size)
			batch.set_instance_transform(i, transform)
			instance.hide()
		var renderer := MultiMeshInstance3D.new()
		renderer.name = "ArchitectureBatch"
		renderer.multimesh = batch
		renderer.material_override = group.material
		root.add_child(renderer)
