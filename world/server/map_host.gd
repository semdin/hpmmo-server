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
## nothing, so the map loads the same blockout colliders and strips its
## surfaces and lights (castle_interior.gd / castle/castle_blockout.gd). The
## grounds map itself is always resident.
##
## The world server builds it at boot (world_server.gd; HPMMO_LAZY_MAPS=1 for
## build-on-first-use), and it is kept: the two maps never overlap in space and
## building it while players are online hitched every tick.

const MAP_GROUNDS := "grounds"
const MAP_INTERIOR := "castle_interior"
const INTERIOR_PATH := "res://scenes/world/castle_interior.tscn"

## The world scene the map is parented to. Assigned by world_server.gd before
## this node enters the tree.
var world: Node3D = null

var _built: Dictionary = {}

func _ready() -> void:
	SimAuthority.map_provider = self
	SimAuthority.instance_closed.connect(release_map)

## Provider contract: is `map_id` resident, and if not, can this host make it so
## now? Called by the authority (main thread) before it reserves a transfer into
## the map, and when a character that logged out inside the castle rejoins.
func ensure_map_built(map_id: String) -> bool:
	if world == null or not is_instance_valid(world):
		return false
	if map_id == MAP_GROUNDS:
		return true
	if HPMaps.instance_slot(map_id) > 0:
		return _ensure_instance_built(map_id)
	# A shared heightfield map (the Blackweb Caverns): its ground is the
	# resident collider every process builds at world start
	# (scripts/world/caverns/cavern_colliders.gd); its scene is presentation.
	if HPMaps.map_info(map_id).get("collision") is Dictionary:
		return world.has_node("MapCollider_" + map_id)
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

## A dungeon copy (`<base>#<slot>`): the map's scene, collision-only, placed at
## the copy's origin. Built on the first transfer into the copy and freed when
## the authority tears the empty copy down.
func _ensure_instance_built(map_id: String) -> bool:
	if _built.has(map_id) and is_instance_valid(_built[map_id]):
		return true
	var path := HPMaps.map_scene(map_id)
	if path == "" or not ResourceLoader.exists(path):
		push_error("[MapHost] instanced map %s has no scene in this build (%s)" % [map_id, path])
		return false
	var node: Node3D = (load(path) as PackedScene).instantiate()
	node.name = "Instance_" + map_id.replace("#", "_")
	if node.has_method("setup"):
		node.call("setup", map_id, true)
	world.add_child(node)
	_built[map_id] = node
	print("[MapHost] %s resident: collision-only copy at x=%.0f, %d static bodies" % [
		map_id, node.position.x, _static_body_count(node)])
	return true

func release_map(map_id: String) -> void:
	var node = _built.get(map_id)
	_built.erase(map_id)
	if node != null and is_instance_valid(node):
		node.queue_free()
		print("[MapHost] %s released" % map_id)

## Which maps this host has made resident (test/ops evidence).
func built_maps() -> Array:
	return _built.keys()

## Evidence for the boot log: a build with no collision would report zero.
func _static_body_count(root: Node) -> int:
	var count := 0
	for node in root.find_children("*", "StaticBody3D", true, false):
		count += 1
	return count
