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
## filter: a client standing in the castle is never sent
## outdoor entity state, and vice versa, however close the two maps' coordinates
## happen to be.
##
## The world holds thousands of creatures and this runs per peer, ten times a
## second, so it never walks the whole entity table: creatures are indexed by
## pack on a coarse grid of pack anchors (a creature never strays further from
## its anchor than its leash), and only packs in the cells around the player
## are measured. Everything else that replicates (players, dummies, monoliths,
## pack-less creatures) is a short list checked directly.
static func interest_set(authority, peer_id: int, center: Vector3) -> Array:
	var radius := HPProtocol.INTEREST_RADIUS
	var own_uid := 0
	var peer_map := HPProtocol.DEFAULT_MAP
	var player_record: Dictionary = authority.player_record(peer_id)
	if not player_record.is_empty():
		own_uid = int(player_record["uid"])
		peer_map = String(player_record.get("map_id", HPProtocol.DEFAULT_MAP))
		if bool(player_record.get("awaiting_bind", false)):
			# Nothing around the placeholder body is this session's to see: the
			# bind moves it to the character's own map and spot.
			return [own_uid]
	_ensure_index(authority)
	var r2 := radius * radius
	var selected: Dictionary = {}
	for uid in authority.players_by_peer.values():
		var record: Dictionary = authority.entities.get(uid, {})
		if record.is_empty() or String(record.get("map_id", HPProtocol.DEFAULT_MAP)) != peer_map:
			continue
		if uid != own_uid and (bool(record.get("awaiting_bind", false)) or bool(record.get("awaiting_world", false))):
			continue   # a login not yet placed at its spot, or still loading in
		var node = record.get("node")
		if node == null or not is_instance_valid(node):
			continue
		if uid == own_uid or (node as Node3D).global_position.distance_squared_to(center) <= r2:
			selected[uid] = true
	for uid in _loose:
		var record: Dictionary = authority.entities.get(uid, {})
		if record.is_empty() or String(record.get("map_id", HPProtocol.DEFAULT_MAP)) != peer_map:
			continue
		var node = record.get("node")
		if node == null or not is_instance_valid(node):
			continue
		if uid == own_uid or (node as Node3D).global_position.distance_squared_to(center) <= r2:
			selected[uid] = true
	var grid: Dictionary = _grid.get(peer_map, {})
	if not grid.is_empty():
		var seen: Dictionary = {}
		var lo := _cell(center - Vector3(radius, 0.0, radius))
		var hi := _cell(center + Vector3(radius, 0.0, radius))
		for cx in range(lo.x, hi.x + 1):
			for cz in range(lo.y, hi.y + 1):
				for key in grid.get(Vector2i(cx, cz), []):
					if seen.has(key):
						continue
					seen[key] = true
					var members: Array = _packs[key]
					var in_range := false
					for uid in members:
						var node = (authority.entities.get(uid, {}) as Dictionary).get("node")
						if node != null and is_instance_valid(node) 								and (node as Node3D).global_position.distance_squared_to(center) <= r2:
							in_range = true
							break
					if not in_range:
						continue
					for uid in members:
						var node = (authority.entities.get(uid, {}) as Dictionary).get("node")
						if node != null and is_instance_valid(node):
							selected[uid] = true
	var out: Array = selected.keys()
	out.sort()
	return out

## Candidate uids for "who could be within `radius` of `center` on `map_id`":
## every player on the map, the short static list, and the members of every
## pack filed near the point. A superset - callers still measure exactly - but
## a few dozen bodies instead of the whole entity table. Used by the authority
## for spell hits, projectile aim assist and creature auras.
static func nearby(authority, map_id: String, center: Vector3, radius: float) -> Array:
	_ensure_index(authority)
	var out: Array = []
	for uid in authority.players_by_peer.values():
		out.append(uid)
	out.append_array(_loose)
	var grid: Dictionary = _grid.get(map_id, {})
	if grid.is_empty():
		return out
	var seen: Dictionary = {}
	var lo := _cell(center - Vector3(radius, 0.0, radius))
	var hi := _cell(center + Vector3(radius, 0.0, radius))
	for cx in range(lo.x, hi.x + 1):
		for cz in range(lo.y, hi.y + 1):
			for key in grid.get(Vector2i(cx, cz), []):
				if not seen.has(key):
					seen[key] = true
					out.append_array(_packs[key])
	return out

## Grid cell edge for the pack index, in metres.
const PACK_CELL := 64.0
## Slack on top of a creature's leash: knockback, separation, the walk home.
const PACK_MARGIN := 30.0
## No creature is filed wider than this around its home, whatever its data says.
const MAX_REACH := 160.0
static var _index_revision := -1
static var _index_owner: Object = null
static var _loose: Array = []         # static replicated uids (dummies, monoliths, pack-less mobs)
static var _packs: Dictionary = {}    # "map|pack_id" -> Array[uid] (one map's members of a pack)
static var _pack_keys: Dictionary = {} # pack_id -> Array[key] (a pack id can recur per map/copy)
static var _pack_cells: Dictionary = {} # key -> Array[Vector2i] it is filed under
static var _grid: Dictionary = {}     # map_id -> {Vector2i: Array[key]}

static func _cell(at: Vector3) -> Vector2i:
	return Vector2i(floori(at.x / PACK_CELL), floori(at.z / PACK_CELL))

## Full rebuild: only when creatures or static entities are added or removed
## (boot, a dungeon copy opening or closing). Players are read live from
## `players_by_peer` and loot is replicated separately, so neither rebuilds it.
static func _ensure_index(authority) -> void:
	var revision := int(authority.roster_revision)
	if revision == _index_revision and authority == _index_owner:
		return
	_index_revision = revision
	_index_owner = authority
	_loose = []
	_packs = {}
	_pack_keys = {}
	_pack_cells = {}
	_grid = {}
	for uid in authority.entities.keys():
		var record: Dictionary = authority.entities[uid]
		var kind := int(record.get("kind", 0))
		if kind == HPProtocol.Kind.LOOT or kind == HPProtocol.Kind.NPC or kind == HPProtocol.Kind.PLAYER:
			continue
		var pack_id := int(record.get("pack_id", 0))
		if kind != HPProtocol.Kind.MOB or pack_id <= 0:
			_loose.append(uid)
			continue
		var key := "%s|%d" % [String(record.get("map_id", HPProtocol.DEFAULT_MAP)), pack_id]
		if not _packs.has(key):
			_packs[key] = []
			(_pack_keys.get_or_add(pack_id, []) as Array).append(key)
		(_packs[key] as Array).append(uid)
	for key in _packs.keys():
		_file_pack(authority, key)

## Every creature uid filed under `pack_id` (on any map or copy).
static func pack_uids(authority, pack_id: int) -> Array:
	_ensure_index(authority)
	var out: Array = []
	for key in _pack_keys.get(pack_id, []):
		out.append_array(_packs.get(key, []))
	return out

## A pooled pack respawned somewhere else: re-file just that pack.
static func reindex_pack(authority, pack_id: int) -> void:
	if authority != _index_owner:
		return
	for key in _pack_keys.get(pack_id, []):
		_file_pack(authority, key)

## File a pack under every cell within reach of any member's home (its spawn
## point plus its leash), so a pack is found from wherever one of its members
## can be - without ever spanning the gap between members far apart.
static func _file_pack(authority, key: String) -> void:
	var map_grid: Dictionary = _grid.get_or_add(key.get_slice("|", 0), {})
	for cell in _pack_cells.get(key, []):
		var filed: Array = map_grid.get(cell, [])
		filed.erase(key)
		if filed.is_empty():
			map_grid.erase(cell)
	var cells: Dictionary = {}
	for uid in _packs[key]:
		var node = (authority.entities.get(uid, {}) as Dictionary).get("node")
		if node == null or not is_instance_valid(node):
			continue
		var home = node.get("spawn_point")
		if not (home is Vector3) or home == Vector3.ZERO:
			home = (node as Node3D).global_position
		var leash := 26.0
		var limit = node.get("boss_arena_radius") if bool(node.get("is_boss")) else null
		if not (limit is float) or float(limit) <= 0.0:
			limit = node.get("leash_distance")
		if limit is float:
			leash = float(limit)
		var reach := minf(leash + PACK_MARGIN, MAX_REACH)
		for at in [home, (node as Node3D).global_position]:
			var lo := _cell(at - Vector3(reach, 0.0, reach))
			var hi := _cell(at + Vector3(reach, 0.0, reach))
			for cx in range(lo.x, hi.x + 1):
				for cz in range(lo.y, hi.y + 1):
					cells[Vector2i(cx, cz)] = true
	for cell in cells:
		(map_grid.get_or_add(cell, []) as Array).append(key)
	_pack_cells[key] = cells.keys()


## Of the MAX_ENTITIES_PER_SNAPSHOT slots, this many always carry the nearest
## bodies; the rest rotate over everything farther away.
const PRIORITY_SLOTS := 20

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
	# Reserve a slot for the local player on EVERY packet. Rotate only the
	# remaining interest set; rotating the whole list also rotates the owner out.
	var others := uids.duplicate()
	if own_uid != 0 and others.has(own_uid):
		var own: Dictionary = authority.entities[own_uid]
		var own_node = own.get("node")
		if is_instance_valid(own_node):
			_encode_entity(buffer, own, own_node, authority)
			sent += 1
		others.erase(own_uid)
	# The nearest bodies (other players count as half their distance) go in
	# every snapshot; only the far remainder takes turns for the slots left.
	# Rotating the whole set put a fight's own targets at 3-5 Hz in a crowd.
	var keyed: Array = []
	for uid in others:
		var node = (authority.entities[uid] as Dictionary).get("node")
		if node == null or not is_instance_valid(node):
			continue
		var d := (node as Node3D).global_position.distance_squared_to(center)
		if int(authority.entities[uid].get("kind", 0)) == HPProtocol.Kind.PLAYER:
			d *= 0.25
		keyed.append([d, uid])
	keyed.sort_custom(func(a, b): return float(a[0]) < float(b[0]))
	var budget := HPProtocol.MAX_ENTITIES_PER_SNAPSHOT - sent
	var nearest := mini(keyed.size(), PRIORITY_SLOTS if keyed.size() > budget else budget)
	for i in range(nearest):
		var record: Dictionary = authority.entities[keyed[i][1]]
		_encode_entity(buffer, record, record["node"], authority)
		sent += 1
	var rest := keyed.slice(nearest)
	var start := int(known.get("__offset", 0)) % maxi(1, rest.size())
	var visited := 0
	for i in range(rest.size()):
		if sent >= HPProtocol.MAX_ENTITIES_PER_SNAPSHOT:
			break
		var record: Dictionary = authority.entities[rest[(start + i) % rest.size()][1]]
		visited += 1
		_encode_entity(buffer, record, record["node"], authority)
		sent += 1
	known["__offset"] = (start + visited) % maxi(1, rest.size())
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
