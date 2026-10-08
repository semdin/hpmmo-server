extends Node

## Server-side map host (Map transfer; installs the `SimAuthority.map_provider`
## hook the authority consults before it reserves a transfer).
##
## The authority simulates every player body, so the map a body stands in must
## have collision in THIS process. The grounds are built by the world scene
## itself (its `Terrain` collider). The castle interior is a separate map scene,
## exported with the world: this host instantiates it on demand and keeps it
## resident, so an authoritative body indoors rests on real floors instead of
## cycling on the per-map fall rescue
## (authority.gd::_check_fall_protection).
##
## It is built with `collision_only` on purpose: a dedicated server draws
## nothing, so the map's builder creates the same colliders and none of the
## surfaces, kit props, lights or PBR textures (castle_interior.gd /
## castle_interior_builder.gd). The grounds map itself is always resident.
##
## Built lazily on first use so a server nobody takes indoors pays nothing, and
## kept once built: the two maps never overlap in space and rebuilding the
## interior per visit would hitch the tick.

const MAP_GROUNDS := "grounds"
const MAP_INTERIOR := "castle_interior"
const INTERIOR_PATH := "res://scenes/world/castle_interior.tscn"

## The world scene the map is parented to. Assigned by world_server.gd before
## this node enters the tree.
var world: Node3D = null

var _built: Dictionary = {}

func _ready() -> void:
	SimAuthority.map_provider = self

## Provider contract: is `map_id` resident, and if not, can this host make it so
## now? Called by the authority (main thread) before it reserves a transfer into
## the map, and when a character that logged out inside the castle rejoins.
func ensure_map_built(map_id: String) -> bool:
	if world == null or not is_instance_valid(world):
		return false
	if map_id == MAP_GROUNDS:
		return true
	if map_id != MAP_INTERIOR:
		return false
	if _built.has(map_id) and is_instance_valid(_built[map_id]):
		return true
	if not ResourceLoader.exists(INTERIOR_PATH):
		push_error("[MapHost] interior scene missing from this build: %s" % INTERIOR_PATH)
		return false
	var packed := load(INTERIOR_PATH) as PackedScene
	if packed == null:
		push_error("[MapHost] cannot load %s" % INTERIOR_PATH)
		return false
	var interior: Node3D = packed.instantiate()
	interior.name = "CastleInterior"
	interior.set("collision_only", true)
	world.add_child(interior)
	# The map's movable furniture is instanced by the map, not by its builder:
	# the grand staircase lives in the interior's StaircaseSlot. Without this the
	# authority has no staircase at all - a rider's client replica receives no
	# published state (it can never board), and the body's collision and the
	# server's disagree at the stair hall. The client's map controller attaches
	# it on load; the authority must do the same here.
	if interior.has_method("attach_staircase"):
		interior.call("attach_staircase")
	_built[map_id] = interior
	print("[MapHost] %s resident for the authority: collision-only build, %d static bodies" % [
		map_id, _static_body_count(interior)])
	return true

## Which maps this host has made resident (test/ops evidence).
func built_maps() -> Array:
	return _built.keys()

## Evidence for the boot log: a build with no collision would report zero.
func _static_body_count(root: Node) -> int:
	var count := 0
	for node in root.find_children("*", "StaticBody3D", true, false):
		count += 1
	return count
