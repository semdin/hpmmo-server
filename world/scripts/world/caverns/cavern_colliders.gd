extends RefCounted

## Resident heightfield colliders of the scene maps that carry creatures
## (maps.json `collision: {shape, origin}`; today the Blackweb Caverns).
##
## Built once at world start in EVERY process - dedicated server, host,
## offline and remote client - and never torn down: the authority places and
## simulates the packs that live down there whether or not a player has the
## map loaded, and a remote client predicts its own body on the same ground.
## A 513^2 HeightMapShape3D is about 1 MB and costs nothing while nobody is
## near it. The map's scene (spider_caverns.gd) is presentation only.

const NODE_PREFIX := "MapCollider_"

static func ensure(world: Node3D) -> int:
	if world == null:
		return 0
	var made := 0
	for map_id in HPMaps.map_ids():
		var spec = HPMaps.map_info(String(map_id)).get("collision")
		if not (spec is Dictionary):
			continue
		var name := NODE_PREFIX + String(map_id)
		if world.has_node(name):
			continue
		var shape := load(String(spec.get("shape", ""))) as Shape3D
		if shape == null:
			push_error("[CavernColliders] %s: cannot load %s" % [map_id, spec.get("shape", "")])
			continue
		var origin: Array = spec.get("origin", [0, 0, 0])
		var body := StaticBody3D.new()
		body.name = name
		body.collision_layer = 1
		body.collision_mask = 0
		var col := CollisionShape3D.new()
		col.shape = shape
		body.add_child(col)
		body.position = Vector3(float(origin[0]), float(origin[1]), float(origin[2]))
		world.add_child(body)
		made += 1
		print("[CavernColliders] %s collider resident at %s" % [map_id, body.position])
	return made
