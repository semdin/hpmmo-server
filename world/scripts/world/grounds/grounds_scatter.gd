extends RefCounted
class_name GroundsScatter

## Solid trunks and boulders for the grounds vegetation.
##
## The Terrain3D instancer only draws the trees and rocks; it has no collision.
## Players must not walk through a trunk, and the server simulates every body,
## so both sides build the same colliders from the same baked instance files
## (assets/terrain/grounds/scatter/<variant>.bin: float32 x, y, z, yaw, scale)
## and the collider spec in vegetation.json.
##
## The colliders sit on their own layer (VEGETATION_LAYER), which the player
## body collides with and creatures do not: without a navigation mesh a pack
## chasing through the forest wedged itself on trunk after trunk (2026-10-21
## playtest), so creatures - and their steering rays, and bolts - pass through.
##
## One static body per 256 m cell keeps the physics broadphase tidy (each
## body's AABB stays local). The bodies and their shapes live in the physics
## server only: a CollisionShape3D node per tree was ~20k nodes and 2.7 s of
## every world entry (2026-11-08); `parent` holds the RIDs and they are freed
## with it.

const DIR := "res://assets/terrain/grounds/"
const CELL := 256.0
const VEGETATION_LAYER := 32


static func catalog() -> Dictionary:
	var text := FileAccess.get_file_as_string(DIR + "vegetation.json")
	var parsed = JSON.parse_string(text) if text != "" else null
	return parsed if parsed is Dictionary else {}


## Raw instances of one variant as PackedFloat32Array (5 floats per instance).
static func instances(variant: String) -> PackedFloat32Array:
	var path := DIR + "scatter/" + variant + ".bin"
	if not FileAccess.file_exists(path):
		return PackedFloat32Array()
	return FileAccess.get_file_as_bytes(path).to_float32_array()


static func transform_of(data: PackedFloat32Array, i: int) -> Transform3D:
	var o := i * 5
	var s := data[o + 4]
	var basis := Basis(Vector3.UP, data[o + 3]).scaled(Vector3(s, s, s))
	return Transform3D(basis, Vector3(data[o], data[o + 1], data[o + 2]))


## Build the collider bodies for `parent`'s world. Returns the number of shapes.
static func build_colliders(parent: Node3D) -> int:
	var cat := catalog()
	var variants: Dictionary = cat.get("variants", {})
	var space := parent.get_world_3d().space
	var bodies := {}
	var shapes := {}
	var count := 0
	for variant in variants:
		var spec: Dictionary = variants[variant].get("collider", {})
		if spec.is_empty():
			continue
		var data := instances(String(variant))
		for i in data.size() / 5:
			var o := i * 5
			var pos := Vector3(data[o], data[o + 1], data[o + 2])
			var s := data[o + 4]
			var key := Vector2i(floori(pos.x / CELL), floori(pos.z / CELL))
			var body: RID = bodies.get(key, RID())
			if not body.is_valid():
				body = PhysicsServer3D.body_create()
				PhysicsServer3D.body_set_mode(body, PhysicsServer3D.BODY_MODE_STATIC)
				PhysicsServer3D.body_set_collision_layer(body, VEGETATION_LAYER)
				PhysicsServer3D.body_set_collision_mask(body, 0)
				bodies[key] = body
			var shape: RID
			var at: Vector3
			if spec.has("sphere"):
				var r := float(spec["sphere"]) * s
				var shape_key := "s%.2f" % r
				if not shapes.has(shape_key):
					shapes[shape_key] = PhysicsServer3D.sphere_shape_create()
					PhysicsServer3D.shape_set_data(shapes[shape_key], r)
				shape = shapes[shape_key]
				at = pos + Vector3(0, r * 0.55, 0)
			else:
				var r := float(spec.get("radius", 0.3)) * clampf(s, 0.7, 1.6)
				var h := float(spec.get("height", 4.0))
				var shape_key := "c%.2f_%.1f" % [r, h]
				if not shapes.has(shape_key):
					shapes[shape_key] = PhysicsServer3D.cylinder_shape_create()
					PhysicsServer3D.shape_set_data(shapes[shape_key], {"radius": r, "height": h})
				shape = shapes[shape_key]
				at = pos + Vector3(0, h * 0.5 - 0.2, 0)
			PhysicsServer3D.body_add_shape(body, shape, Transform3D(Basis(), at))
			count += 1
	# Into the world only once every shape is on: a body already in the space
	# rebuilds its compound shape on each add.
	for body in bodies.values():
		PhysicsServer3D.body_set_space(body, space)
	var owner := _PhysicsRids.new()
	owner.rids = bodies.values() + shapes.values()
	parent.set_meta("physics_rids", owner)
	return count


## Frees its physics-server RIDs when the last reference goes (the owning
## node's metadata, when that node is freed). Bodies first, then their shapes.
class _PhysicsRids extends RefCounted:
	var rids: Array = []

	func _notification(what: int) -> void:
		if what == NOTIFICATION_PREDELETE:
			for rid in rids:
				PhysicsServer3D.free_rid(rid)
