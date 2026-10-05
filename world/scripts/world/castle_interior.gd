extends Node3D

## CastleInterior - the separate indoor map (plan.md Phase 8).
##
## This scene is built procedurally on entry and freed on the way out, so an
## outdoor world and an indoor world are never both resident. It owns no
## gameplay state: entities, the player body and the HUD belong to the world
## scene that hosts it (`map_controller.gd` moves the body and keeps the HUD).
##
## The floor levels and the stair profile mirror the shared map contract in
## `addons/hpmmo_sim/data/maps.json`. If that contract is present (Phase 8 sync),
## `HPMaps` is asked for the floor names; otherwise the documented values are
## used, so the interior keeps working with today's offline build.

const Builder = preload("res://scripts/world/castle_interior_builder.gd")

## The world server builds this map with collision only (server/world/server/
## map_host.gd sets this before the node enters the tree): a dedicated server
## simulates bodies, it does not draw, and it must not load the visual kit.
var collision_only := false

const MAP_ID := "castle_interior"
const DISPLAY_NAME := "Hogwarts Castle"

## Documented floor plan (maps.json "floors"), used when HPMaps is not synced.
const FLOORS := [
	{"id": "basement", "name": "Dungeon Level", "y": 194.0},
	{"id": "ground", "name": "Ground Floor", "y": 200.0},
	{"id": "first", "name": "First Floor", "y": 206.0},
	{"id": "second", "name": "Second Floor", "y": 212.0},
]

## Authored arrival points (maps.json "spawn_points.castle_interior").
const SPAWN_POINTS := {
	"default": Vector3(0.0, 200.5, 30.0),
	"vestibule": Vector3(0.0, 200.5, 30.0),
}

func _ready() -> void:
	build()

func build() -> void:
	Builder.build(self, collision_only)

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
		return DISPLAY_NAME
	return "%s - %s" % [DISPLAY_NAME, name]

func _local_floor_for_y(y: float) -> Dictionary:
	var best: Dictionary = {}
	for entry in FLOORS:
		var level := float(entry["y"])
		if y >= level - 0.6 and (best.is_empty() or level > float(best["y"])):
			best = entry
	return best

## The shared map catalog, when the Phase 8 sync has landed. Loaded by path
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

## Where the moving staircase will be placed. The marker is created empty, and
## the staircase scene is instantiated only when it exists in this build; the
## staircase itself is owned by a different workstream.
func attach_staircase() -> bool:
	var slot := get_node_or_null("StaircaseSlot") as Node3D
	if slot == null:
		return false
	if not ResourceLoader.exists("res://scenes/world/castle/staircase.tscn"):
		return false
	var packed: PackedScene = load("res://scenes/world/castle/staircase.tscn")
	if packed == null:
		return false
	slot.add_child(packed.instantiate())
	return true
