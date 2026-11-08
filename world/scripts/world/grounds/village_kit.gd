extends RefCounted
class_name VillageKit

## Orvell's buildings: shops, houses and the inn assembled from the Quaternius
## Medieval Village MegaKit (CC0) by art/village/scripts/build_village_kit.py,
## plus the crooked "storybook" house (build_hand_house.py). The kit's walls,
## timber, stone and roofs wear our own world-space PBR materials (REMAP), so
## they match the castle and the courtyard; each building gets its plaster
## colour and roof from a hash of its position, so repeats differ.
##
## A building is placed in two halves: found() adds its founded plinth and its
## colliders (walls box + roof hull, from village_kit.json) to the site's
## ArchKit batch, which owns the collision body; place() instances the model
## once the batch's root exists. The door side is the model's +z. Both build
## scripts write their building's footprint and colliders to village_kit.json.

const DIR := "res://assets/models/village/"
const MANIFEST := DIR + "village_kit.json"
## kit material -> GroundsSites.materials() key ("plaster"/"roof" pick a variant per building)
const REMAP := {
	"MI_Plaster": "plaster", "MI_Brick": "plaster", "MI_UnevenBrick": "rubble", "MI_RockTrim": "stone",
	"MI_WoodTrim": "timber", "MI_WoodTrim_Wear": "wood", "MI_RoundTiles": "roof", "MI_MetalOrnaments": "metal",
	"MI_WindowGlass": "glass",
}
const PLASTERS := ["plaster", "plaster_cream", "plaster_ochre", "plaster_rose", "plaster_sage"]
const ROOFS := ["roof", "roof", "roof_warm"]

## Where a building's near model gives way to its far one (an eighth of the
## triangles, <id>_far.glb), metres from the camera.
const LOD_NEAR := 60.0

static var _manifest := {}
static var _loaded := false
static var _scenes := {}


static func manifest() -> Dictionary:
	if not _loaded:
		_loaded = true
		var parsed = JSON.parse_string(FileAccess.get_file_as_string(MANIFEST))
		if parsed is Dictionary:
			_manifest = parsed
		else:
			push_error("VillageKit: %s is missing or broken - no village buildings" % MANIFEST)
	return _manifest


## Footprint (width along the door side, depth) in metres.
static func size(id: String) -> Vector2:
	var m: Dictionary = manifest().get(id, {})
	return Vector2(float(m.get("w", 8)), float(m.get("d", 6)))


## Found building `id` at c with its door turned along rot (atan2 of the
## door's direction x, z): a rubble plinth down to the lowest ground under it
## and its colliders go into `kit`. Returns the placement for place().
static func found(kit: ArchKit, id: String, c: Vector2, rot: float) -> Array:
	var m: Dictionary = manifest().get(id, {})
	if m.is_empty():
		return []
	var sz := size(id)
	var span := GroundsLayout.ground_span(c, sz + Vector2(1.0, 1.0), rot)
	var floor_y := span.y + 0.15
	var base := span.x - 1.0
	var basis := Basis(Vector3.UP, rot)
	var origin := Vector3(c.x, floor_y, c.y)
	kit.box(Vector3(c.x, (base + floor_y) * 0.5, c.y), Vector3(sz.x + 0.6, floor_y - base, sz.y + 0.6), rot, "rubble")
	var colliders: Dictionary = m.get("colliders", {})
	for b in colliders.get("boxes", []):
		kit.solid(origin + basis * Vector3(b[0], b[1], b[2]), Vector3(b[3], b[4], b[5]), rot)
	for h in colliders.get("hulls", []):
		var pts := PackedVector3Array()
		for p in h:
			pts.append(origin + basis * Vector3(p[0], p[1], p[2]))
		kit.solid_hull(pts)
	return [id, origin, rot]


## Instance the founded buildings under root, wearing `mats` (GroundsSites.materials()).
static func place(root: Node3D, placements: Array, mats: Dictionary) -> void:
	for entry in placements:
		if entry.is_empty():
			continue
		var id: String = entry[0]
		if not _scenes.has(id):
			_scenes[id] = load(DIR + id + ".glb")
		var scene: PackedScene = _scenes[id]
		if scene == null:
			continue
		var pick := absi(int(entry[1].x * 7.0) * 31 + int(entry[1].z * 7.0) * 17)
		var plaster: String = PLASTERS[pick % PLASTERS.size()]
		var roof: String = ROOFS[(pick / 7) % ROOFS.size()]
		var far_path := DIR + id + "_far.glb"
		if not _scenes.has(far_path):
			_scenes[far_path] = load(far_path) if ResourceLoader.exists(far_path) else null
		for model in [scene, _scenes[far_path]]:
			if model == null:
				continue
			var near: bool = model == scene
			var house: Node3D = (model as PackedScene).instantiate()
			house.name = id.to_pascal_case() + ("" if near else "Far")
			root.add_child(house)
			house.position = entry[1]
			house.rotation.y = entry[2]
			for mi in house.find_children("*", "MeshInstance3D", true, false):
				_dress(mi as MeshInstance3D, mats, plaster, roof)
				# QualityPreset hands the near model over to the far one here
				if _scenes[far_path] != null:
					mi.set_meta("lod_near_end" if near else "lod_far_begin", LOD_NEAR)


## A garden fence piece at `at` (x, z) turned `yaw`, standing on the ground:
## its collider goes into kit; returns its transform for place_fences().
static func found_fence(kit: ArchKit, at: Vector2, yaw: float) -> Transform3D:
	var xf := Transform3D(Basis(Vector3.UP, yaw), GroundsLayout.ground(at.x, at.y))
	kit.solid(xf * Vector3(0, 0.42, 0), Vector3(2.06, 0.84, 0.14), yaw)
	return xf


## Draw the fence pieces (one MultiMesh of the kit's fence, in our timber).
static func place_fences(root: Node3D, xforms: Array, mats: Dictionary) -> void:
	if xforms.is_empty() or not ResourceLoader.exists(DIR + "fence.glb"):
		return
	var scene: Node = (load(DIR + "fence.glb") as PackedScene).instantiate()
	var found := scene.find_children("*", "MeshInstance3D", true, false)
	var mesh: Mesh = (found[0] as MeshInstance3D).mesh.duplicate() if not found.is_empty() else null
	scene.free()
	if mesh == null:
		return
	for s in mesh.get_surface_count():
		var mat := mesh.surface_get_material(s)
		var key: String = REMAP.get(mat.resource_name if mat != null else "", "")
		if mats.has(key):
			mesh.surface_set_material(s, mats[key])
	var mm := MultiMesh.new()
	mm.transform_format = MultiMesh.TRANSFORM_3D
	mm.mesh = mesh
	mm.instance_count = xforms.size()
	for i in xforms.size():
		mm.set_instance_transform(i, xforms[i])
	var mmi := MultiMeshInstance3D.new()
	mmi.name = "GardenFences"
	mmi.multimesh = mm
	root.add_child(mmi)


static func _dress(m: MeshInstance3D, mats: Dictionary, plaster: String, roof: String) -> void:
	for s in m.mesh.get_surface_count():
		var mat := m.mesh.surface_get_material(s)
		var name := mat.resource_name if mat != null else ""
		# the storybook house names its materials after our keys directly
		var key: String = REMAP.get(name, name)
		if key == "plaster":
			key = plaster
		elif key == "roof":
			key = roof
		if mats.has(key):
			m.set_surface_override_material(s, mats[key])
