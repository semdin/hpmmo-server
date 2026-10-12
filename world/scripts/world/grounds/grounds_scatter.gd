extends RefCounted
class_name GroundsScatter

## Solid trunks and boulders for the grounds vegetation.
##
## The Terrain3D instancer only draws the trees and rocks; it has no collision.
## Players and mobs must not walk through a trunk, and the server simulates every
## body, so both sides build the same colliders from the same baked instance files
## (assets/terrain/grounds/scatter/<variant>.bin: float32 x, y, z, yaw, scale)
## and the collider spec in vegetation.json.
##
## One StaticBody3D per 256 m cell keeps the physics broadphase tidy (each body's
## AABB stays local) without paying a node per tree.

const DIR := "res://assets/terrain/grounds/"
const CELL := 256.0
const GROUND_LAYER := 1


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


## Build the collider bodies under `parent`. Returns the number of shapes.
static func build_colliders(parent: Node3D) -> int:
	var cat := catalog()
	var variants: Dictionary = cat.get("variants", {})
	var bodies := {}
	var count := 0
	var shapes := {}
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
			var body: StaticBody3D = bodies.get(key)
			if body == null:
				body = StaticBody3D.new()
				body.name = "VegetationColliders_%d_%d" % [key.x, key.y]
				body.collision_layer = GROUND_LAYER
				body.collision_mask = 0
				parent.add_child(body)
				bodies[key] = body
			var col := CollisionShape3D.new()
			if spec.has("sphere"):
				var r := float(spec["sphere"]) * s
				var shape_key := "s%.2f" % r
				if not shapes.has(shape_key):
					var sph := SphereShape3D.new()
					sph.radius = r
					shapes[shape_key] = sph
				col.shape = shapes[shape_key]
				col.position = pos + Vector3(0, r * 0.55, 0)
			else:
				var r := float(spec.get("radius", 0.3)) * clampf(s, 0.7, 1.6)
				var h := float(spec.get("height", 4.0))
				var shape_key := "c%.2f_%.1f" % [r, h]
				if not shapes.has(shape_key):
					var cyl := CylinderShape3D.new()
					cyl.radius = r
					cyl.height = h
					shapes[shape_key] = cyl
				col.shape = shapes[shape_key]
				col.position = pos + Vector3(0, h * 0.5 - 0.2, 0)
			body.add_child(col)
			count += 1
	return count
