@tool
extends Terrain3D
class_name GroundsTerrain

## The outdoor map's terrain (Terrain3D, 2 x 2 km, 1 m cells, lake surface y = 0).
##
## Source: art/map (layout.json -> heightfield.py / control.py / scatter.py)
## built into assets/terrain/grounds/ by tools/terrain/build_grounds.gd. See
## docs/grounds-map.md.
##
## Collision: the dedicated server simulates every player's body wherever it is,
## so it needs the whole heightfield as colliders (FULL_GAME). A client only needs
## the ground around its own camera (DYNAMIC_GAME, Terrain3D's default for games).
## Dynamic collision cannot work headless (there is no camera to follow), so
## headless runs (server, tests) always get FULL_GAME.
##
## Looks: the texture set, vegetation meshes and shader settings are loaded only
## where something is drawn. A headless server keeps the heights and collision
## and never loads a texture or a tree.

const GROUND_LAYER := 1
## The render layer (1-based) of the ground and its vegetation. Parking the
## grounds (GroundsBuilder.teardown) takes it out of the camera's cull mask:
## hiding the node made Terrain3D destroy every vegetation multimesh and
## rebuild them all on the way back out, one ~420 ms frame on every dungeon
## exit (Intel iGPU; ~610 ms on an Apple M1).
const RENDER_LAYER := 18
const RENDER_BIT := 1 << (RENDER_LAYER - 1)
## Client dynamic-collision radius around the camera, in metres. The broom camera
## sits within ~12 m of the hero, so this covers the hero with a wide margin.
const CLIENT_COLLISION_RADIUS := 96
const ASSETS := "res://assets/terrain/grounds_assets.tres"
const MATERIAL := "res://assets/terrain/grounds_material.tres"
## An empty asset list for headless processes: no textures, no trees.
const SERVER_ASSETS := "res://assets/terrain/grounds_server_assets.tres"

static var _active: GroundsTerrain
## Foliage density the instances were added with (-1: none added yet).
var _vegetation_density := -1.0


func _init() -> void:
	# Both resources must be saved files: Terrain3D reloads its resources by
	# path, and an in-memory one makes it load an empty path (an error).
	material = load(MATERIAL)
	assets = load(ASSETS if DisplayServer.get_name() != "headless" else SERVER_ASSETS)
	# The ground draws on its own layer; the vegetation joins it in _ready.
	render_layers = (render_layers & ~1) | RENDER_BIT


func _enter_tree() -> void:
	if not Engine.is_editor_hint():
		_active = self


func _exit_tree() -> void:
	if _active == self:
		_active = null


func _ready() -> void:
	if Engine.is_editor_hint():
		return
	collision.layer = GROUND_LAYER
	collision.mask = 0
	if DisplayServer.get_name() == "headless":
		collision.mode = Terrain3DCollision.FULL_GAME
		# Terrain3D follows a camera for mesh LOD and stops (with an error) when it
		# finds none. Headless nothing is drawn, so give it a fixed one.
		var anchor := Camera3D.new()
		anchor.name = "HeadlessAnchor"
		add_child(anchor)
		set_camera(anchor)
	else:
		collision.mode = Terrain3DCollision.DYNAMIC_GAME
		collision.radius = CLIENT_COLLISION_RADIUS
		# The mesh assets are set up here, not in _init: entering the tree,
		# Terrain3D (free_editor_textures) reloads the asset list from disk, which
		# dropped every setting made before. Before any instance is added: it must
		# not see a mesh asset change under live instances.
		_set_assets(assets, _asset_plan(assets, preset_settings()))
		_add_vegetation.call_deferred()


## Trees, bushes and rocks are drawn by the Terrain3D instancer from the baked
## instance files (assets/terrain/grounds/scatter/<variant>.bin), one mesh slot
## per variant (the slot's name is the variant). They are added here, at load,
## rather than stored in the regions, so a headless server never holds them.
## `density` (the quality preset's foliage scale) thins the small stuff only;
## `only` limits the planting to those mesh ids (a preset switch).
func _add_vegetation(density: float = -1.0, only: Array = []) -> void:
	if density < 0.0:
		density = preload("res://scripts/world/quality_preset.gd").foliage_density()
	for i in assets.get_mesh_count():
		var asset := assets.get_mesh_asset(i)
		if asset == null or asset.name == "":
			continue
		if not only.is_empty() and not only.has(i):
			continue
		var data := GroundsScatter.instances(asset.name)
		var thin := density < 1.0 and _is_thinned(asset.name)
		var xforms: Array[Transform3D] = []
		for k in data.size() / 5:
			if thin and float(k % 100) / 100.0 >= density:
				continue
			xforms.append(GroundsScatter.transform_of(data, k))
		if not xforms.is_empty():
			instancer.add_transforms(i, xforms, PackedColorArray(), true)
	_vegetation_density = density


## Quality preset (QualityPreset.apply): terrain clipmap size, how far every
## vegetation LOD reaches, which LODs cast shadows, and how much of the small
## stuff is drawn. The catalogue's LOD distances are kept in metadata, so
## switching presets never compounds.
func apply_quality(preset: Dictionary) -> void:
	if Engine.is_editor_hint() or DisplayServer.get_name() == "headless":
		return
	var size := int(preset.get("terrain_mesh_size", mesh_size))
	if size != mesh_size:
		mesh_size = size
	var density := float(preset.get("foliage_density", 1.0))
	var plan := _asset_plan(assets, preset)
	if _vegetation_density < 0.0:
		# nothing planted yet: the instances are added with the new settings
		_set_assets(assets, plan)
		return
	# A preset switch. Only the thinned small stuff is cleared and added back
	# (its instance count follows the density); every other mesh keeps its
	# multimeshes and the instancer just restyles them (LOD ranges, shadows).
	# Clearing and re-adding all ~100k instances was a ~200 ms call and a
	# ~650 ms frame on every switch (Intel iGPU, 2026-11-08).
	var thinned: Array = []
	if not is_equal_approx(density, _vegetation_density):
		for i in assets.get_mesh_count():
			var asset := assets.get_mesh_asset(i)
			if asset != null and _is_thinned(asset.name):
				thinned.append(i)
				instancer.clear_by_mesh(i)
	for i in _set_assets(assets, plan):
		if not thinned.has(i):
			instancer.update_mmis(i)
	if not thinned.is_empty():
		_add_vegetation(density, thinned)


static func preset_settings() -> Dictionary:
	return preload("res://scripts/world/quality_preset.gd").settings()


## What every mesh asset of `list` should be under `preset`: one entry per
## asset ({} for an empty slot). The catalogue's LOD distances are kept in
## metadata, so presets never compound.
static func _asset_plan(list: Terrain3DAssets, preset: Dictionary) -> Array:
	var lod_scale := float(preset.get("vegetation_lod_scale", 1.0))
	var far_scale := float(preset.get("vegetation_far_scale", lod_scale))
	var shadow_lod := int(preset.get("vegetation_shadow_lod", 1))
	var small_shadows := bool(preset.get("small_plant_shadows", true))
	var wanted: Array = []
	for i in list.get_mesh_count():
		var asset := list.get_mesh_asset(i)
		if asset == null:
			wanted.append({})
			continue
		if not asset.has_meta("base_ranges"):
			var base: Array = []
			for l in asset.get_lod_count():
				base.append(asset.get_lod_range(l))
			asset.set_meta("base_ranges", base)
		var base_ranges: Array = asset.get_meta("base_ranges")
		var ranges: Array = []
		for l in base_ranges.size():
			ranges.append(float(base_ranges[l]) * (far_scale if l == asset.last_lod else lod_scale))
		# One shadow mesh at every distance: LOD0 cast its own detailed shadow and
		# LOD1 a different one, so a tree's shadow changed shape (or appeared and
		# vanished on low) as the camera came near. The shadow impostor draws the
		# shadow LOD's mesh under the nearer LODs too; the sun's shadow distance
		# fades it out before that LOD's range ends.
		var shadow_mesh := mini(shadow_lod, asset.last_lod)
		var entry := {"ranges": ranges, "shadow_lod": shadow_mesh, "impostor": shadow_mesh, "cast": -1}
		if _is_small_plant(asset.name):
			entry["cast"] = GeometryInstance3D.SHADOW_CASTING_SETTING_ON if small_shadows else GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		wanted.append(entry)
	return wanted


## Applies an _asset_plan and returns the ids of the meshes it changed. Each
## asset's signals are blocked while it changes: Terrain3D answers every LOD /
## shadow setter by rendering a 512 px thumbnail of the mesh and updating its
## multimeshes, ~1.4 s for one preset's worth of setters at every world entry
## (2026-11-08). The caller updates the multimeshes once (apply_quality), or
## adds the instances afterwards.
static func _set_assets(list: Terrain3DAssets, wanted: Array) -> Array:
	var changed: Array = []
	for i in wanted.size():
		var entry: Dictionary = wanted[i]
		if entry.is_empty():
			continue
		var asset := list.get_mesh_asset(i)
		var before := _asset_state(asset)
		asset.set_block_signals(true)
		asset.visibility_layers = RENDER_BIT
		var ranges: Array = entry["ranges"]
		for l in ranges.size():
			asset.set_lod_range(l, float(ranges[l]))
		asset.last_shadow_lod = int(entry["shadow_lod"])
		asset.shadow_impostor = int(entry["impostor"])
		if int(entry["cast"]) >= 0:
			asset.cast_shadows = int(entry["cast"])
		asset.set_block_signals(false)
		if _asset_state(asset) != before:
			changed.append(i)
	return changed


static func _asset_state(asset: Terrain3DMeshAsset) -> Array:
	var state: Array = [asset.visibility_layers, asset.last_shadow_lod, asset.shadow_impostor, asset.cast_shadows]
	for l in asset.get_lod_count():
		state.append(asset.get_lod_range(l))
	return state


static func _is_small_plant(variant: String) -> bool:
	return variant.begins_with("fern") or variant == "shrub"


## The small stuff the preset's foliage density thins out.
static func _is_thinned(variant: String) -> bool:
	return _is_small_plant(variant) or variant.begins_with("rock_moss")


## The loaded grounds terrain, or null when the current map has none.
static func active() -> GroundsTerrain:
	return _active if is_instance_valid(_active) else null


## Ground height at (x, z), or NAN outside the terrain or with no terrain loaded.
## The surface the collision is built from (interpolated between texels).
static func height_at(x: float, z: float) -> float:
	var t := active()
	if t == null or t.data == null:
		return NAN
	return t.data.get_surface_height(Vector3(x, 0.0, z))
