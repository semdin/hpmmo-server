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
## Client dynamic-collision radius around the camera, in metres. The broom camera
## sits within ~12 m of the hero, so this covers the hero with a wide margin.
const CLIENT_COLLISION_RADIUS := 96
const ASSETS := "res://assets/terrain/grounds_assets.tres"
const MATERIAL := "res://assets/terrain/grounds_material.tres"
## An empty asset list for headless processes: no textures, no trees.
const SERVER_ASSETS := "res://assets/terrain/grounds_server_assets.tres"

static var _active: GroundsTerrain


func _init() -> void:
	# Both resources must be saved files: Terrain3D reloads its resources by
	# path, and an in-memory one makes it load an empty path (an error).
	material = load(MATERIAL)
	assets = load(ASSETS if DisplayServer.get_name() != "headless" else SERVER_ASSETS)


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
		_add_vegetation.call_deferred()


## Trees, bushes and rocks are drawn by the Terrain3D instancer from the baked
## instance files (assets/terrain/grounds/scatter/<variant>.bin), one mesh slot
## per variant (the slot's name is the variant). They are added here, at load,
## rather than stored in the regions, so a headless server never holds them.
## `density` (the quality preset's foliage scale) thins the small stuff only.
func _add_vegetation(density: float = -1.0) -> void:
	if density < 0.0:
		density = preload("res://scripts/world/quality_preset.gd").foliage_density()
	for i in assets.get_mesh_count():
		var asset := assets.get_mesh_asset(i)
		if asset == null or asset.name == "":
			continue
		var data := GroundsScatter.instances(asset.name)
		var thin := density < 1.0 and (asset.name.begins_with("fern") or asset.name == "shrub" or asset.name.begins_with("rock_moss"))
		var xforms: Array[Transform3D] = []
		for k in data.size() / 5:
			if thin and float(k % 100) / 100.0 >= density:
				continue
			xforms.append(GroundsScatter.transform_of(data, k))
		if not xforms.is_empty():
			instancer.add_transforms(i, xforms, PackedColorArray(), true)


## The loaded grounds terrain, or null when the current map has none.
static func active() -> GroundsTerrain:
	return _active if is_instance_valid(_active) else null


## Ground height at (x, z), or NAN outside the terrain or with no terrain loaded.
static func height_at(x: float, z: float) -> float:
	var t := active()
	if t == null or t.data == null:
		return NAN
	return t.data.get_height(Vector3(x, 0.0, z))
