extends Node3D
class_name GroundsImpostors

## The grounds' far tree band: every tree past its LOD1, drawn as its impostor
## card from one MultiMesh per 256 m tile (all variants together) instead of
## Terrain3D's one multimesh per 32 m cell, variant and LOD.
##
## Why: Terrain3D's far LOD averaged ~3.5 trees per multimesh, ~300-740 of them
## in view on low, each drawn twice (depth prepass + colour) - most of the
## grounds' 800-1,500 draw calls. A tile holds a few hundred to ~2,000 cards;
## ~5-9 tiles are in view.
##
## The data is baked (tools/terrain/bake_impostors.gd): the texture arrays,
## impostors.json and impostor_tiles.bin under assets/terrain/vegetation/.
## Client only: GroundsTerrain builds it with the vegetation, never headless.
## Terrain3D keeps LOD0/LOD1 of these variants (their scenes end at LOD1) and
## the handover distance is read back from those assets (set_ranges), so the
## band always starts where Terrain3D's LOD1 ends, on every preset.

const DIR := "res://assets/terrain/vegetation/"
const SHADER := DIR + "tree_impostor.gdshader"
const MAX_VARIANTS := 16
## The catalogue's backlight for foliage cards (cook_vegetation.gd).
const BACKLIGHT := Color(0.22, 0.27, 0.10)

static var _catalog = null

var _material: ShaderMaterial
var _tiles: Array[MultiMeshInstance3D] = []


## impostors.json ({} when the bake is missing).
static func catalog() -> Dictionary:
	if _catalog == null:
		var path := DIR + "impostors.json"
		var parsed = JSON.parse_string(FileAccess.get_file_as_string(path)) if FileAccess.file_exists(path) else null
		_catalog = parsed if parsed is Dictionary else {}
	return _catalog


## True when `variant`'s far band is drawn here (its Terrain3D asset ends at LOD1).
static func has_variant(variant: String) -> bool:
	for entry in catalog().get("variants", []):
		if String(entry.get("name", "")) == variant:
			return true
	return false


## The band on render `layers`, or null when the bake is missing.
static func build(layers: int) -> GroundsImpostors:
	var variants: Array = catalog().get("variants", [])
	var tiles_path := DIR + "impostor_tiles.bin"
	if variants.is_empty() or variants.size() > MAX_VARIANTS or not FileAccess.file_exists(tiles_path):
		push_warning("GroundsImpostors: no impostor bake (tools/terrain/bake_impostors.gd); distant trees are not drawn")
		return null
	var node := GroundsImpostors.new()
	node.name = "TreeImpostors"
	node._material = ShaderMaterial.new()
	node._material.shader = load(SHADER)
	node._material.set_shader_parameter("albedo_array", load(DIR + "impostor_alb.png"))
	node._material.set_shader_parameter("normal_array", load(DIR + "impostor_nrm.png"))
	var tints := PackedVector3Array()
	tints.resize(MAX_VARIANTS)
	for v in variants.size():
		var t: Array = variants[v].get("tint", [1, 1, 1])
		var c := Color(float(t[0]), float(t[1]), float(t[2])).srgb_to_linear()
		tints[v] = Vector3(c.r, c.g, c.b)
	node._material.set_shader_parameter("tints", tints)
	var bl := BACKLIGHT.srgb_to_linear()
	node._material.set_shader_parameter("backlight_color", Vector3(bl.r, bl.g, bl.b))
	var card := _card()
	var bytes := FileAccess.get_file_as_bytes(tiles_path)
	var count := bytes.decode_s32(0)
	var at := 4
	for i in count:
		var n := bytes.decode_s32(at + 8)
		at += 12
		var mm := MultiMesh.new()
		mm.transform_format = MultiMesh.TRANSFORM_3D
		mm.use_custom_data = true
		mm.mesh = card
		mm.instance_count = n
		mm.buffer = bytes.slice(at, at + n * 64).to_float32_array()
		at += n * 64
		var mmi := MultiMeshInstance3D.new()
		mmi.name = "Tile%d" % i
		mmi.multimesh = mm
		mmi.layers = layers
		mmi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		mmi.gi_mode = GeometryInstance3D.GI_MODE_DISABLED
		mmi.material_override = node._material
		node.add_child(mmi)
		node._tiles.append(mmi)
	return node


## Handover and far ranges for the preset now applied to `assets`: near is the
## variant's Terrain3D LOD1 range as set (GroundsTerrain._asset_plan), far the
## catalogue's far range times the preset's vegetation_far_scale.
func set_ranges(assets: Terrain3DAssets, preset: Dictionary) -> void:
	var far_scale := float(preset.get("vegetation_far_scale", preset.get("vegetation_lod_scale", 1.0)))
	var variants: Array = catalog().get("variants", [])
	var ranges := PackedVector2Array()
	ranges.resize(MAX_VARIANTS)
	var margin := 0.0
	var far_max := 0.0
	for v in variants.size():
		var name := String(variants[v].get("name", ""))
		var near := float(variants[v].get("near", 0.0))
		for i in assets.get_mesh_count():
			var asset := assets.get_mesh_asset(i)
			if asset != null and asset.name == name:
				near = asset.get_lod_range(asset.last_lod)
				margin = maxf(margin, asset.fade_margin)
		var far := float(variants[v].get("far", 0.0)) * far_scale
		ranges[v] = Vector2(near, far)
		far_max = maxf(far_max, far)
	_material.set_shader_parameter("ranges", ranges)
	_material.set_shader_parameter("fade_margin", margin)
	# A tile wholly past every far range is not submitted at all (Godot
	# measures from the tile's AABB centre).
	for mmi in _tiles:
		mmi.visibility_range_end = far_max + 2.0 * margin + mmi.get_aabb().size.length() * 0.5
		mmi.visibility_range_end_margin = 0.0


## The impostor card at unit size: two crossed quads, x / z in [-0.5, 0.5],
## y in [0, 1]; the quad facing +z samples the left half of the slice, the one
## facing +x the right half (the cooked `<variant>_lod2` card's layout).
static func _card() -> ArrayMesh:
	var verts := PackedVector3Array([
		Vector3(-0.5, 0, 0), Vector3(0.5, 1, 0), Vector3(0.5, 0, 0), Vector3(-0.5, 1, 0),
		Vector3(0, 0, 0.5), Vector3(0, 1, -0.5), Vector3(0, 0, -0.5), Vector3(0, 1, 0.5)])
	var uvs := PackedVector2Array([
		Vector2(0, 1), Vector2(0.5, 0), Vector2(0.5, 1), Vector2(0, 0),
		Vector2(0.5, 1), Vector2(1, 0), Vector2(1, 1), Vector2(0.5, 0)])
	var normals := PackedVector3Array()
	var tangents := PackedFloat32Array()
	for i in 8:
		normals.append(Vector3(0, 0, 1) if i < 4 else Vector3(1, 0, 0))
		tangents.append_array([1.0, 0.0, 0.0, 1.0] if i < 4 else [0.0, 0.0, -1.0, 1.0])
	var arrays := []
	arrays.resize(Mesh.ARRAY_MAX)
	arrays[Mesh.ARRAY_VERTEX] = verts
	arrays[Mesh.ARRAY_NORMAL] = normals
	arrays[Mesh.ARRAY_TANGENT] = tangents
	arrays[Mesh.ARRAY_TEX_UV] = uvs
	arrays[Mesh.ARRAY_INDEX] = PackedInt32Array([0, 1, 2, 0, 3, 1, 4, 5, 6, 4, 7, 5])
	var mesh := ArrayMesh.new()
	mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)
	return mesh
