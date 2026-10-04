extends RefCounted
class_name HPSnapshots

## Compact entity snapshots (channel 0, unreliable).
##
## 30 bytes per entity so a full interest set fits in one datagram and never
## fragments (an unreliable packet larger than the MTU is simply lost):
##   u32 uid | u8 kind | u8 variant | u8 flags | u8 state | u16 pack_id |
##   3 x f32 position | f32 rot_y | u16 hp | u16 max_hp
##
## Loot is not carried here: it does not move, so it is replicated as reliable
## spawn/despawn events instead. NPCs are client-side scenery and are never
## replicated.

const ENTITY_BYTES := 30


static func _encode_entity(buffer: StreamPeerBuffer, record: Dictionary, node: Node3D, authority) -> void:
	buffer.put_u32(int(record["uid"]))
	buffer.put_u8(int(record["kind"]))
	buffer.put_u8(int(record.get("variant", 0)) & 0xff)
	buffer.put_u8(authority.flags_for(record) & 0xff)
	buffer.put_u8(int(record.get("state", 0)) & 0xff)
	buffer.put_u16(clampi(int(record.get("pack_id", 0)), 0, 65535))
	var pos := node.global_position
	buffer.put_float(pos.x)
	buffer.put_float(pos.y)
	buffer.put_float(pos.z)
	buffer.put_float(_rotation_y(node))
	buffer.put_u16(clampi(int(record.get("hp", 0)), 0, 65535))
	buffer.put_u16(clampi(int(record.get("max_hp", 0)), 0, 65535))


static func _rotation_y(node: Node3D) -> float:
	var visuals = node.get("visuals")
	if visuals is Node3D:
		return (visuals as Node3D).rotation.y
	return node.rotation.y


## Interest set for one peer: everything ON THAT PEER'S MAP within
## INTEREST_RADIUS of its player, plus every pack mate of an in-range mob (a
## pack must appear whole), plus the player itself. Map membership is the outer
## filter (plan.md Phase 8): a client standing in the castle is never sent
## outdoor entity state, and vice versa, however close the two maps' coordinates
## happen to be.
static func interest_set(authority, peer_id: int, center: Vector3) -> Array:
	var radius := HPProtocol.INTEREST_RADIUS
	var own_uid := 0
	var peer_map := HPProtocol.DEFAULT_MAP
	var player_record: Dictionary = authority.player_record(peer_id)
	if not player_record.is_empty():
		own_uid = int(player_record["uid"])
		peer_map = String(player_record.get("map_id", HPProtocol.DEFAULT_MAP))
	var selected: Dictionary = {}
	var pack_ids: Dictionary = {}
	for uid in authority.entities.keys():
		var record: Dictionary = authority.entities[uid]
		var kind := int(record.get("kind", 0))
		if kind == HPProtocol.Kind.LOOT or kind == HPProtocol.Kind.NPC:
			continue
		if String(record.get("map_id", HPProtocol.DEFAULT_MAP)) != peer_map:
			continue
		var node = record.get("node")
		if node == null or not is_instance_valid(node):
			continue
		if uid == own_uid or (node as Node3D).global_position.distance_to(center) <= radius:
			selected[uid] = true
			# Only mobs group by pack: a pack is a single encounter on one map.
			var pack_id := int(record.get("pack_id", 0))
			if kind == HPProtocol.Kind.MOB and pack_id > 0:
				pack_ids[pack_id] = true
	if not pack_ids.is_empty():
		for uid in authority.entities.keys():
			if selected.has(uid):
				continue
			var record: Dictionary = authority.entities[uid]
			if int(record.get("kind", 0)) != HPProtocol.Kind.MOB:
				continue
			if String(record.get("map_id", HPProtocol.DEFAULT_MAP)) != peer_map:
				continue
			if not pack_ids.has(int(record.get("pack_id", 0))):
				continue
			var node = record.get("node")
			if node != null and is_instance_valid(node):
				selected[uid] = true
	var out: Array = selected.keys()
	out.sort()
	return out


static func encode_for(authority, peer_id: int, center: Vector3, known: Dictionary) -> Dictionary:
	var uids := interest_set(authority, peer_id, center)
	var buffer := StreamPeerBuffer.new()
	buffer.big_endian = false
	var sent := 0
	# The peer's own body is never the one left out: the client cannot reconcile
	# without it, and it is the entity its player cares about most.
	var own_uid := 0
	var player_record: Dictionary = authority.player_record(peer_id)
	if not player_record.is_empty():
		own_uid = int(player_record["uid"])
	if own_uid != 0 and uids.has(own_uid):
		uids.erase(own_uid)
		uids.insert(0, own_uid)
	# More entities than fit in one datagram: every entity is still delivered,
	# just spread over consecutive ticks instead of being dropped. The cursor
	# lives in the caller's per-peer bookkeeping (`__offset`).
	var start := int(known.get("__offset", 0)) % maxi(1, uids.size())
	var ordered: Array = []
	for i in range(uids.size()):
		ordered.append(uids[(start + i) % uids.size()])
	for uid in ordered:
		if sent >= HPProtocol.MAX_ENTITIES_PER_SNAPSHOT:
			break
		var record: Dictionary = authority.entities[uid]
		var node = record.get("node")
		if node == null or not is_instance_valid(node):
			continue
		_encode_entity(buffer, record, node, authority)
		sent += 1
	known["__offset"] = start + sent
	buffer.seek(0)
	return {"bytes": buffer.data_array, "uids": uids}


## Apply a received snapshot to the client-side replica table.
static func apply(bytes: PackedByteArray, authority) -> void:
	var buffer := StreamPeerBuffer.new()
	buffer.big_endian = false
	buffer.data_array = bytes
	var total := int(bytes.size() / ENTITY_BYTES)
	for _i in range(total):
		var uid := buffer.get_u32()
		var kind := buffer.get_u8()
		var variant := buffer.get_u8()
		var flags := buffer.get_u8()
		var state := buffer.get_u8()
		var pack_id := buffer.get_u16()
		var pos := Vector3(buffer.get_float(), buffer.get_float(), buffer.get_float())
		var rot_y := buffer.get_float()
		var hp := buffer.get_u16()
		var max_hp := buffer.get_u16()
		authority.upsert_replica(uid, kind, pos, rot_y, hp, max_hp, flags, state, variant, pack_id)
