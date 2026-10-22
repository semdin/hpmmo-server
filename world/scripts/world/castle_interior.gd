extends Node3D

## CastleInterior - the separate indoor map.
##
## This scene is built on entry and freed on the way out, so an outdoor world
## and an indoor world are never both resident. It owns no gameplay state:
## entities, the player body and the HUD belong to the world scene that hosts it
## (`map_controller.gd` moves the body and keeps the HUD).
##
## Geometry: the HP-scale blockout (docs/castle-interior.md, F1) -
## art/castle/layout.json built by Blender into assets/castle/castle_blockout.glb,
## placed so layout L0 is world y 200. The glb carries one convex collider per
## piece, so the world server builds the very same walkable map with the visual
## meshes stripped. The Grand Staircase's seven moving flights are HPStaircase
## instances, one per `staircases` entry of the map catalog.
##
## Spawn points, the exit portal and the staircase specs are the shared map
## contract in `addons/hpmmo_sim/data/maps.json` (written from the layout by
## art/castle/scripts/export_catalog.py); the values below are the documented
## fallback for a build without the synced catalog.

const Blockout = preload("res://scripts/world/castle/castle_blockout.gd")
const Decor = preload("res://scripts/world/castle/castle_decor.gd")

## The world server builds this map with collision only (server/world/server/
## map_host.gd sets this before the node enters the tree): a dedicated server
## simulates bodies, it does not draw, and it must not load the visual kit.
var collision_only := false

const MAP_ID := "castle_interior"
const DISPLAY_NAME := "Hogwarts Castle"  # i18n
## Layout L0 in world space.
const MAP_Y := 200.0

## Floor plan (layout levels, storey 10 m).
const FLOORS := [
	# i18n-begin
	{"id": "dungeons", "name": "Dungeons", "y": 190.0},
	{"id": "ground", "name": "Ground Floor", "y": 200.0},
	{"id": "first", "name": "First Floor", "y": 210.0},
	{"id": "second", "name": "Second Floor", "y": 220.0},
	{"id": "third", "name": "Third Floor", "y": 230.0},
	{"id": "fourth", "name": "Fourth Floor", "y": 240.0},
	{"id": "fifth", "name": "Fifth Floor", "y": 250.0},
	{"id": "sixth", "name": "Sixth Floor", "y": 260.0},
	{"id": "seventh", "name": "Seventh Floor", "y": 270.0},
	# i18n-end
]

## Authored arrival points (maps.json "spawn_points.castle_interior").
const SPAWN_POINTS := {
	"default": Vector3(0.0, 200.5, 58.0),
	"vestibule": Vector3(0.0, 200.5, 58.0),
}

func _ready() -> void:
	build()

func build() -> void:
	if has_node("InteriorStructure"):
		return
	var structure := Blockout.instantiate()
	if structure == null:
		push_error("[CastleInterior] %s is missing from this build" % Blockout.BLOCKOUT)
		return
	structure.name = "InteriorStructure"
	structure.position.y = MAP_Y
	add_child(structure)
	if collision_only:
		Blockout.strip_visuals(structure)
		return
	Blockout.restyle(structure)
	# Lights and decor live under the structure so `teardown` takes them with
	# it; the structure is offset by MAP_Y, so they are placed in layout space.
	# A low fill only: the candles, chandeliers and moonlight carry the rooms.
	Blockout.add_room_lights(structure, Blockout.load_layout(), 0.0, 0.55)
	Decor.build(structure, 0.0)
	Blockout.add_occluders(structure)
	# The decor's moonlight replaces the scene's flat fill light.
	var fill := get_node_or_null("SkyLight") as DirectionalLight3D
	if fill != null:
		fill.visible = false

## Remove everything this map put in the tree. The map controller then frees the
## scene root itself; keeping both paths means a map can also be cleared in
## place without leaking nodes.
func teardown() -> void:
	for child in get_children():
		if child.name == "InteriorStructure":
			remove_child(child)
			child.queue_free()

func spawn_point(spawn_id: String) -> Vector3:
	if SPAWN_POINTS.has(spawn_id):
		return SPAWN_POINTS[spawn_id]
	return SPAWN_POINTS["default"]

func floor_for_y(y: float) -> Dictionary:
	# The synced map catalog does not carry a floor plan yet; when it does, it
	# wins (probed, so an older catalog cannot break the client).
	var maps := _maps_script()
	if maps != null and maps.has_method("floor_for_y"):
		var entry: Dictionary = maps.call("floor_for_y", MAP_ID, y)
		if not entry.is_empty():
			return entry
	return _local_floor_for_y(y)

func floor_display(y: float) -> String:
	var entry := floor_for_y(y)
	var name := String(entry.get("name", ""))
	if name == "":
		return tr(DISPLAY_NAME)
	return tr("%s - %s") % [tr(DISPLAY_NAME), tr(name)]

func _local_floor_for_y(y: float) -> Dictionary:
	var best: Dictionary = {}
	for entry in FLOORS:
		var level := float(entry["y"])
		if y >= level - 0.6 and (best.is_empty() or level > float(best["y"])):
			best = entry
	return best

## The shared map catalog, when the map transfer sync has landed. Loaded by path
## rather than preloaded so today's build (which has no maps.gd) still runs.
func _maps_script() -> GDScript:
	if not ResourceLoader.exists("res://addons/hpmmo_sim/maps.gd"):
		return null
	return load("res://addons/hpmmo_sim/maps.gd") as GDScript

## Collision sweep used by the walkthrough test: true when a straight line at
## eye height is clear between two points of the route.
func route_clear(from: Vector3, to: Vector3, mask: int = 1) -> bool:
	var space := get_world_3d().direct_space_state
	var query := PhysicsRayQueryParameters3D.create(from, to, mask)
	return space.intersect_ray(query).is_empty()

## The Grand Staircase: one staircase scene per `staircases` entry of the map
## catalog, all under the StaircaseSlot (which stands at the layout origin, so
## the catalog's coordinates are layout-local). A catalog without the list gets
## the single prototype staircase, as before.
func attach_staircase() -> bool:
	var slot := get_node_or_null("StaircaseSlot") as Node3D
	if slot == null:
		return false
	if not ResourceLoader.exists("res://scenes/world/castle/staircase.tscn"):
		return false
	var packed: PackedScene = load("res://scenes/world/castle/staircase.tscn")
	if packed == null:
		return false
	var count := HPStaircase.catalog_staircase_count()
	if count == 0:
		slot.add_child(packed.instantiate())
		return true
	for index in range(count):
		var stair := packed.instantiate()
		stair.name = "MagicalStaircase%d" % index
		stair.set("spec_index", index)
		slot.add_child(stair)
	return true
