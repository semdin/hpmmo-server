extends RefCounted

## Phase 10 PBR material library + Gothic kit loader (plan.md Phase 10).
##
## One place that knows:
##   * which texture set backs each surface (and at what physical scale);
##   * how a shader material is built from it (world-space triplanar, so no
##     surface stretches regardless of the box size it is painted on);
##   * which material slots each Gothic kit module carries, and how to instance
##     a module and replace those slots with the PBR materials.
##
## The checks scene (`scenes/test/phase10_regression.tscn`) asserts the maps are
## actually assigned, so this file is also the material contract for Phase 10.

const SHADER := preload("res://assets/shaders/triplanar_pbr.gdshader")

## ------------------------------------------------------------------ sets
## metres_per_tile drives texel density: px / (metres * 1000) px/m.
## Budget: 256 px/m +/-15% for architecture (art-direction.md §4). Documented
## deviations: roof slates and planks are used finer because their course/plank
## size is the readable feature; recorded in assets/manifest.json.
const PBR_SETS := {
	"stone_ashlar_01": {
		"dir": "res://assets/textures/pbr/stone_ashlar_01", "res": "2k", "ext": "png",
		"maps": {"albedo": "albedo", "normal": "normal", "rough": "rough", "ao": "ao"},
		"metres": 8.0, "source": "authored",
	},
	"stone_ashlar_02": {
		"dir": "res://assets/textures/pbr/stone_ashlar_02", "res": "1k", "ext": "png",
		"maps": {"albedo": "albedo", "normal": "normal", "rough": "rough", "ao": "ao"},
		"metres": 4.0, "source": "authored",
	},
	"floor_flagstone_01": {
		"dir": "res://assets/textures/pbr/floor_flagstone_01", "res": "2k", "ext": "png",
		"maps": {"albedo": "albedo", "normal": "normal", "rough": "rough", "ao": "ao"},
		"metres": 8.0, "source": "authored",
	},
	"trim_sheet_01": {
		"dir": "res://assets/textures/pbr/trim_sheet_01", "res": "1k", "ext": "png",
		"maps": {"albedo": "albedo", "normal": "normal", "rough": "rough", "ao": "ao"},
		"metres": 4.0, "source": "authored",
	},
	"wood_timber_01": {
		"dir": "res://assets/textures/pbr/wood_timber_01", "res": "1k", "ext": "png",
		"maps": {"albedo": "albedo", "normal": "normal", "rough": "rough"},
		"metres": 2.0, "source": "authored",
	},
	"metal_iron_01": {
		"dir": "res://assets/textures/pbr/metal_iron_01", "res": "512", "ext": "png",
		"maps": {"albedo": "albedo", "normal": "normal", "rough": "rough"},
		"metres": 1.0, "source": "authored",
	},
	"moss_01": {
		"dir": "res://assets/textures/pbr/moss_01", "res": "1k", "ext": "png",
		"maps": {"albedo": "albedo", "normal": "normal", "rough": "rough"},
		"metres": 2.0, "source": "authored", "alpha": true,
	},
	"dirt_ground_01": {
		"dir": "res://assets/textures/pbr/dirt_ground_01", "res": "1k", "ext": "png",
		"maps": {"albedo": "albedo", "normal": "normal", "rough": "rough"},
		"metres": 4.0, "source": "authored", "alpha": true,
	},
	"grass_ground_01": {
		"dir": "res://assets/textures/pbr/grass_ground_01", "res": "1k", "ext": "png",
		"maps": {"albedo": "albedo", "normal": "normal", "rough": "rough", "ao": "ao"},
		"metres": 4.0, "source": "authored",
	},
	"foliage_leafcard_01": {
		"dir": "res://assets/textures/pbr/foliage_leafcard_01", "res": "512", "ext": "png",
		"maps": {"albedo": "albedo", "normal": "normal"},
		"metres": 1.0, "source": "authored", "alpha": true,
	},
	"grass_blade_01": {
		"dir": "res://assets/textures/pbr/grass_blade_01", "res": "512", "ext": "png",
		"maps": {"albedo": "albedo"},
		"metres": 1.0, "source": "authored", "alpha": true,
	},
	"stone_tiles_02": {
		"dir": "res://assets/textures/pbr/stone_tiles_02", "res": "2k", "ext": "jpg",
		"maps": {"albedo": "diff", "normal": "nor_gl", "rough": "rough", "ao": "ao"},
		"metres": 8.0, "source": "polyhaven-cc0",
	},
	"dark_wooden_planks": {
		"dir": "res://assets/textures/pbr/dark_wooden_planks", "res": "2k", "ext": "jpg",
		"maps": {"albedo": "diff", "normal": "nor_gl", "rough": "rough", "ao": "ao"},
		"metres": 2.5, "source": "polyhaven-cc0",
	},
	"white_plaster_02": {
		"dir": "res://assets/textures/pbr/white_plaster_02", "res": "2k", "ext": "jpg",
		"maps": {"albedo": "diff", "normal": "nor_gl", "rough": "rough", "ao": "ao"},
		"metres": 4.0, "source": "polyhaven-cc0",
	},
	"roof_slates_03": {
		"dir": "res://assets/textures/pbr/roof_slates_03", "res": "2k", "ext": "jpg",
		"maps": {"albedo": "diff", "normal": "nor_gl", "rough": "rough", "ao": "ao"},
		"metres": 3.0, "source": "polyhaven-cc0",
	},
}

# ------------------------------------------------------------------ slots
## Material slot map per kit module, in the order the Blender script registered
## them (`tools/blender/phase10_kit.py`). Slot names resolve through
## `slot_material()` below.
const KIT_SLOTS := {
	"wall_module_4x6": ["stone"],
	"wall_module_4x6_damaged": ["stone"],
	"corner_4x6": ["stone"],
	"arch_pointed_2_4x3_4": ["stone"],
	"arch_arcade_6x5": ["stone"],
	"column_6": ["stone"],
	"column_broken_2_2": ["stone"],
	"buttress_1x6": ["stone"],
	"window_lancet_2x4": ["stone", "glass"],
	"door_double_2_4x3": ["wood", "iron", "wood_dark"],
	"floor_flag_4": ["stone_floor"],
	"stair_tread_0_2x4": ["stone"],
	"balustrade_4": ["stone"],
	"newel_post_1_2": ["stone"],
	"roof_slope_4x6": ["slate"],
	"tower_cap_7": ["slate"],
	"trim_band_4": ["trim"],
	"rubble_pile_1": ["stone"],
	"long_table_8": ["wood", "wood_dark"],
	"bench_4": ["wood", "wood_dark"],
	"bookshelf_4x3": ["wood", "books"],
	"ladder_3": ["wood"],
	"desk_1_6": ["wood", "wood_dark"],
	"lectern_1": ["wood", "books"],
	"armour_stand_2": ["iron", "cloth"],
	"banner_1_2x3": ["cloth", "wood"],
	"portrait_1x1_5": ["wood_dark", "books"],
	"candelabra_1_6": ["iron", "wax", "flame"],
	"candle_cluster": ["wax", "flame"],
	"tree_pine_8": ["wood_dark", "foliage"],
	"tree_broad_8": ["wood_dark", "foliage"],
	"bush_1": ["foliage"],
	"grass_clump_1": ["grass"],
	"rock_01": ["stone"],
	"rock_02": ["stone"],
	"rock_03": ["stone"],
	"plaque_0_8x0_5": ["trim"],
}

## Props that repeat enough to be drawn as MultiMesh instances.
const INSTANCED_MODULES := [
	"balustrade_4", "newel_post_1_2", "stair_tread_0_2x4", "candle_cluster",
	"rock_01", "rock_02", "rock_03", "bush_1", "grass_clump_1",
	"tree_pine_8", "tree_broad_8", "ladder_3", "portrait_1x1_5",
]

## Visibility range end (metres) for repeated props; architecture is culled by
## its chunked batches instead. -1 means "no limit" (view-scale geometry).
const VISIBILITY_RANGES := {
	"grass_clump_1": 45.0,
	"bush_1": 70.0,
	"tree_pine_8": 220.0,
	"tree_broad_8": 220.0,
	"rock_01": 120.0, "rock_02": 120.0, "rock_03": 120.0,
	"candle_cluster": 60.0,
	"balustrade_4": 90.0,
	"newel_post_1_2": 90.0,
}

static var _set_cache: Dictionary = {}
static var _material_cache: Dictionary = {}
static var _scene_cache: Dictionary = {}
static var _queued: Dictionary = {}

# ------------------------------------------------------------------ textures

static func set_maps(set_id: String) -> Dictionary:
	if _set_cache.has(set_id):
		return _set_cache[set_id]
	var spec: Dictionary = PBR_SETS.get(set_id, {})
	var out: Dictionary = {}
	if not spec.is_empty():
		for channel in spec["maps"].keys():
			var path: String = "%s/%s_%s_%s.%s" % [
				spec["dir"], set_id, spec["maps"][channel], spec["res"], spec["ext"]]
			out[channel] = load(path) if ResourceLoader.exists(path) else null
		out["metres"] = float(spec["metres"])
		out["alpha"] = bool(spec.get("alpha", false))
		out["source"] = String(spec.get("source", ""))
	_set_cache[set_id] = out
	return out

## Every texture file this library expects, for the checks script's
## "no missing resources" assertion.
static func expected_paths() -> Array:
	var paths: Array = []
	for set_id in PBR_SETS:
		var spec: Dictionary = PBR_SETS[set_id]
		for channel in spec["maps"].keys():
			paths.append("%s/%s_%s_%s.%s" % [
				spec["dir"], set_id, spec["maps"][channel], spec["res"], spec["ext"]])
	for module_name in KIT_SLOTS:
		paths.append("res://assets/models/gothic_kit/%s.glb" % module_name)
	return paths

# ------------------------------------------------------------------ materials

## A world-space triplanar PBR material. `tint` multiplies albedo (sRGB).
static func surface(set_id: String, tint: Color = Color.WHITE, opts: Dictionary = {}) -> ShaderMaterial:
	var key := "%s|%s|%s" % [set_id, tint.to_html(), str(opts)]
	if _material_cache.has(key):
		return _material_cache[key]
	var maps := set_maps(set_id)
	var m := ShaderMaterial.new()
	m.shader = SHADER
	m.set_shader_parameter("albedo_tex", maps.get("albedo"))
	m.set_shader_parameter("normal_tex", maps.get("normal"))
	m.set_shader_parameter("rough_tex", maps.get("rough"))
	m.set_shader_parameter("ao_tex", maps.get("ao"))
	m.set_shader_parameter("tint", tint)
	var metres: float = float(opts.get("metres", maps.get("metres", 4.0)))
	m.set_shader_parameter("world_scale", 1.0 / maxf(0.05, metres))
	m.set_shader_parameter("normal_strength", float(opts.get("normal_strength", 1.0)))
	m.set_shader_parameter("rough_min", float(opts.get("rough_min", 0.03)))
	m.set_shader_parameter("rough_max", float(opts.get("rough_max", 1.0)))
	m.set_shader_parameter("ao_strength", float(opts.get("ao_strength", 1.0)))
	m.set_shader_parameter("metallic_amount", float(opts.get("metallic", 0.0)))
	m.set_shader_parameter("use_baked_instance_ao", bool(opts.get("instance_ao", false)))
	m.set_shader_parameter("emission_color", opts.get("emission", Color(0, 0, 0)))
	m.set_shader_parameter("emission_energy", float(opts.get("emission_energy", 0.0)))
	m.set_shader_parameter("rim_color", opts.get("rim", Color(0, 0, 0)))
	m.set_shader_parameter("rim_amount", float(opts.get("rim_amount", 0.0)))
	_material_cache[key] = m
	return m

## A UV-mapped texture material (masked foliage, trim sheet, decals).
static func textured(set_id: String, opts: Dictionary = {}) -> StandardMaterial3D:
	var key := "uv|%s|%s" % [set_id, str(opts)]
	if _material_cache.has(key):
		return _material_cache[key]
	var maps := set_maps(set_id)
	var m := StandardMaterial3D.new()
	m.albedo_texture = maps.get("albedo")
	if maps.get("normal") != null:
		m.normal_enabled = true
		m.normal_texture = maps["normal"]
		m.normal_scale = float(opts.get("normal_strength", 1.0))
	if maps.get("rough") != null:
		m.roughness_texture = maps["rough"]
		m.roughness = float(opts.get("roughness", 1.0))
	m.albedo_color = opts.get("tint", Color.WHITE)
	m.texture_filter = BaseMaterial3D.TEXTURE_FILTER_LINEAR_WITH_MIPMAPS_ANISOTROPIC
	m.uv1_scale = opts.get("uv_scale", Vector3.ONE)
	m.uv1_offset = opts.get("uv_offset", Vector3.ZERO)
	if bool(maps.get("alpha", false)):
		if bool(opts.get("blend", false)):
			# Soft-edged ground decals: real alpha blend, no depth write.
			m.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
			m.depth_draw_mode = BaseMaterial3D.DEPTH_DRAW_DISABLED
			m.cull_mode = BaseMaterial3D.CULL_DISABLED
		else:
			m.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA_SCISSOR
			m.alpha_scissor_threshold = float(opts.get("alpha_scissor", 0.45))
			m.cull_mode = BaseMaterial3D.CULL_DISABLED
		m.shading_mode = BaseMaterial3D.SHADING_MODE_PER_PIXEL
	if opts.get("unshaded", false):
		m.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	if float(opts.get("emission_energy", 0.0)) > 0.0:
		m.emission_enabled = true
		m.emission = opts.get("emission", Color.WHITE)
		m.emission_energy_multiplier = float(opts["emission_energy"])
	_material_cache[key] = m
	return m

## Named slot -> material used by kit modules and by the castle builders.
static func slot_material(slot: String, tint: Color = Color.WHITE) -> Material:
	match slot:
		"stone":
			return surface("stone_ashlar_01")
		"stone_dark":
			return surface("stone_ashlar_02")
		"stone_floor":
			return surface("floor_flagstone_01")
		"plaster":
			return surface("white_plaster_02")
		"slate":
			return surface("roof_slates_03", Color(1, 1, 1), {"metallic": 0.0, "rough_min": 0.35})
		"trim":
			# The trim sheet carries the moulding bands; kit UVs are box
			# projected at 0.25/m so the 4 m sheet spans one full module width.
			return textured("trim_sheet_01", {"uv_scale": Vector3(0.25, 2.4, 1.0),
				"uv_offset": Vector3(0.0, 0.02, 0.0), "roughness": 0.95})
		"wood":
			return textured("wood_timber_01", {"uv_scale": Vector3(2.0, 2.0, 2.0)})
		"wood_dark":
			return textured("wood_timber_01", {"uv_scale": Vector3(2.0, 2.0, 2.0),
				"tint": Color(0.55, 0.5, 0.48)})
		"iron":
			return surface("metal_iron_01", Color.WHITE, {"metallic": 1.0, "rough_min": 0.2, "rough_max": 0.75})
		"metal_soft":
			return surface("metal_iron_01", Color(1.3, 1.15, 0.85), {"metallic": 1.0, "rough_min": 0.2, "rough_max": 0.6})
		"glass":
			return _glass()
		"cloth":
			return _flat(Color(0.40, 0.42, 0.48), 0.92)
		"wax":
			return _flat(Color(0.88, 0.85, 0.76), 0.55)
		"books":
			return _flat(Color(0.36, 0.28, 0.24), 0.9)
		"flame":
			return _flame()
		"foliage":
			return textured("foliage_leafcard_01", {"alpha_scissor": 0.4, "roughness": 0.9})
		"grass":
			return textured("grass_blade_01", {"alpha_scissor": 0.35, "roughness": 0.95})
		"moss":
			return textured("moss_01", {"blend": true, "roughness": 0.95})
		"dirt":
			return textured("dirt_ground_01", {"blend": true, "roughness": 0.98})
		_:
			return _flat(Color(1, 0, 1), 0.9)  # magenta = unassigned slot, never silent

static var _flat_cache: Dictionary = {}

static func _flat(color: Color, rough: float) -> StandardMaterial3D:
	var key := "%s|%.2f" % [color.to_html(), rough]
	if _flat_cache.has(key):
		return _flat_cache[key]
	var m := StandardMaterial3D.new()
	m.albedo_color = color
	m.roughness = rough
	m.metallic = 0.0
	_flat_cache[key] = m
	return m

static func _glass() -> StandardMaterial3D:
	if _flat_cache.has("glass"):
		return _flat_cache["glass"]
	# A dull leaded light that reads as glazing and still emits a little warmth
	# from the torchlit interior; it is not a transparent surface.
	var m := StandardMaterial3D.new()
	m.albedo_color = Color(0.42, 0.52, 0.62)
	m.roughness = 0.18
	m.metallic = 0.1
	m.emission_enabled = true
	m.emission = Color(0.35, 0.45, 0.6)
	m.emission_energy_multiplier = 0.25
	_flat_cache["glass"] = m
	return m

static func _flame() -> StandardMaterial3D:
	if _flat_cache.has("flame"):
		return _flat_cache["flame"]
	var m := StandardMaterial3D.new()
	m.albedo_color = Color(1.0, 0.72, 0.32)
	m.roughness = 0.6
	m.emission_enabled = true
	m.emission = Color(1.0, 0.66, 0.25)
	m.emission_energy_multiplier = 1.5
	_flat_cache["flame"] = m
	return m

static func clear_cache() -> void:
	_set_cache.clear()
	_material_cache.clear()
	_flat_cache.clear()

# ------------------------------------------------------------------ kit loading

## The shared mesh for a kit module, with its PBR slot materials assigned on the
## mesh itself (once). Assigning on the shared resource — not per instance —
## means a MultiMesh can batch every surface of a multi-material module in one
## draw, and single instances need no overrides at all.
static func kit_mesh(module_name: String) -> Mesh:
	if _scene_cache.has(module_name):
		return _scene_cache[module_name]
	var mesh: Mesh = null
	var path := "res://assets/models/gothic_kit/%s.glb" % module_name
	if ResourceLoader.exists(path):
		var scene := load(path) as PackedScene
		if scene != null:
			var probe: Node3D = scene.instantiate()
			var found := probe.find_children("*", "MeshInstance3D", true, false)
			if not found.is_empty():
				mesh = (found[0] as MeshInstance3D).mesh
			probe.free()
	if mesh != null:
		var slots: Array = KIT_SLOTS.get(module_name, [])
		for surface in range(mesh.get_surface_count()):
			var slot := String(slots[surface]) if surface < slots.size() else "stone"
			var mat := slot_material(slot)
			if mat is ShaderMaterial:
				mat.set_shader_parameter("use_baked_instance_ao", true)
			mesh.surface_set_material(surface, mat)
	_scene_cache[module_name] = mesh
	return mesh

## Instantiate a kit module as real nodes. `tint` recolours cloth slots (house
## banners and other per-instance drapery).
static func kit_instance(module_name: String, tint: Color = Color.WHITE) -> Node3D:
	var mesh := kit_mesh(module_name)
	if mesh == null:
		push_warning("[pbr_kit] missing kit module: %s" % module_name)
		return null
	var node := MeshInstance3D.new()
	# Godot renames duplicate siblings automatically, so the module identity is
	# carried in metadata as well as the name (checks and dressing count by it).
	node.name = module_name
	node.set_meta("kit_module", module_name)
	node.mesh = mesh
	if tint != Color.WHITE:
		_tint_cloth(node, module_name, tint)
	var limit: float = float(VISIBILITY_RANGES.get(module_name, -1.0))
	if limit > 0.0:
		node.visibility_range_end = limit
		node.visibility_range_end_margin = limit * 0.1
	return node

static func _tint_cloth(node: MeshInstance3D, module_name: String, tint: Color) -> void:
	var slots: Array = KIT_SLOTS.get(module_name, [])
	for surface in range(node.mesh.get_surface_count()):
		if surface < slots.size() and String(slots[surface]) == "cloth":
			node.set_surface_override_material(surface, slot_material("cloth", tint))

# ------------------------------------------------------------------ instancing

## Queue a repeated module for one MultiMesh draw. Only single-slot modules are
## accepted; multi-slot props must be real instances so both materials survive.
static func queue(module_name: String, xform: Transform3D, tint: Color = Color.WHITE,
		ao: float = 1.0) -> void:
	if not _queued.has(module_name):
		_queued[module_name] = []
	_queued[module_name].append({"xform": xform, "tint": tint, "ao": ao})

static func flush(parent: Node3D) -> int:
	var drawn := 0
	for module_name in _queued:
		var entries: Array = _queued[module_name]
		if entries.is_empty():
			continue
		var source_mesh := kit_mesh(module_name)
		if source_mesh == null:
			continue
		var multimesh := MultiMesh.new()
		multimesh.transform_format = MultiMesh.TRANSFORM_3D
		multimesh.use_colors = true
		multimesh.mesh = source_mesh
		multimesh.instance_count = entries.size()
		for i in range(entries.size()):
			multimesh.set_instance_transform(i, entries[i]["xform"])
			var tint: Color = entries[i]["tint"]
			var ao: float = entries[i]["ao"]
			multimesh.set_instance_color(i, Color(tint.r * ao, tint.g * ao, tint.b * ao, 1.0))
		var renderer := MultiMeshInstance3D.new()
		renderer.name = "KitBatch_" + module_name
		renderer.multimesh = multimesh
		var limit: float = float(VISIBILITY_RANGES.get(module_name, -1.0))
		if limit > 0.0:
			renderer.visibility_range_end = limit
			renderer.visibility_range_end_margin = limit * 0.1
		parent.add_child(renderer)
		drawn += entries.size()
	_queued.clear()
	return drawn

static func pending_count() -> int:
	var total := 0
	for module_name in _queued:
		total += (_queued[module_name] as Array).size()
	return total
