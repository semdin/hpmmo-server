extends RefCounted

## Low-cost, continuous terrain silhouette beyond the playable boundaries.
static func build(parent: Node3D) -> void:
	var noise := FastNoiseLite.new()
	noise.seed = 7429
	noise.frequency = 0.005
	noise.fractal_octaves = 3
	var radii := [480.0, 560.0, 660.0, 780.0, 920.0]
	var elevations := [-2.0, 18.0, 95.0, 65.0, -2.0]
	var rows: Array = []
	for ring in range(radii.size()):
		var row: Array[Vector3] = []
		for i in range(145):
			var angle := TAU * i / 144
			var position: Vector3 = Vector3(cos(angle), 0, sin(angle)) * radii[ring]
			var relief := noise.get_noise_2d(position.x, position.z)
			position.y = elevations[ring] * (0.85 + relief * 0.75 + sin(angle * 5.0) * 0.2)
			row.append(position)
		rows.append(row)
	var surface := SurfaceTool.new()
	surface.begin(Mesh.PRIMITIVE_TRIANGLES)
	surface.set_smooth_group(0)
	for ring in range(rows.size() - 1):
		for i in range(144):
			for position in [rows[ring][i], rows[ring + 1][i + 1], rows[ring + 1][i], rows[ring][i], rows[ring][i + 1], rows[ring + 1][i + 1]]:
				surface.set_color(Color(0.19, 0.28, 0.22).lerp(Color(0.36, 0.43, 0.46), clampf(position.y / 65, 0, 1)))
				surface.add_vertex(position)
	surface.index()
	surface.generate_normals()
	var terrain := MeshInstance3D.new()
	terrain.name = "DistantRidges"
	terrain.mesh = surface.commit()
	terrain.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	var material := StandardMaterial3D.new()
	material.albedo_color = Color(0.35, 0.43, 0.47)
	material.vertex_color_use_as_albedo = true
	material.roughness = 1
	material.cull_mode = BaseMaterial3D.CULL_DISABLED
	terrain.material_override = material
	parent.add_child(terrain)
