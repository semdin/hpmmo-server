extends RefCounted

## The laid tables: gold plates and goblets, bread, fruit and roasts on the Great
## Hall house and staff tables, vegetables, fish and tools on the kitchen work
## tables. NVIDIA SimReady scans (CC BY 4.0, assets/ASSET_CREDITS.md) decimated
## onto one atlas by art/feast/scripts; assets/models/feast/feast.glb holds every
## dressing piece as one mesh:
##   hall_a..c     6 m of a house table, places on both sides
##   staff         the whole staff table, places on the chair side (+z)
##   kitchen_a..c  2 m of a kitchen work table
## Piece frame: x along the table, the table top at y = 0.
## Client only (CastleDecor builds it); no colliders - the tables have theirs.

const FEAST := "res://assets/models/feast/feast.glb"
const LAYOUT := "res://assets/castle/castle_layout.json"
const HALL_PIECES := ["hall_a", "hall_b", "hall_c"]
const KITCHEN_PIECES := ["kitchen_a", "kitchen_b", "kitchen_c"]
const HALL_PIECE_LENGTH := 6.0
const KITCHEN_PIECE_LENGTH := 2.0
## Kitchen work tables (art/castle/scripts/castle_rooms.py kitchens()): two
## tables along z, 5.5 m in from the room's x walls, from z0 + 6 to z1 - 5,
## top 0.9 m above the floor. They are not layout blocks.
const KITCHEN_TABLE_INSET := 5.5
const KITCHEN_TABLE_Z := [6.0, 5.0]
const KITCHEN_TABLE_TOP := 0.9
## Of the eight 2 m lengths of a kitchen table, this many stay bare.
const KITCHEN_BARE := 2


static func build(parent: Node3D, map_y: float, quality: String) -> void:
	if not ResourceLoader.exists(FEAST):
		return
	var meshes := _meshes()
	if meshes.is_empty():
		return
	var layout := _layout()
	var root := Node3D.new()
	root.name = "Feast"
	parent.add_child(root)
	# Tableware shadows are barely seen but double the triangles (moon + candle
	# shadow maps): ~1 ms GPU on medium, so only high casts them.
	var shadows := quality == "high"
	var rng := RandomNumberGenerator.new()
	rng.seed = 1991
	for b in layout.get("blocks", []):
		var id := String(b.get("id", ""))
		var lo: Array = b.get("min", [])
		var hi: Array = b.get("max", [])
		if id.begins_with("house_table_"):
			# along x, the run of pieces centred on the table
			var count := int(floor((float(hi[0]) - float(lo[0])) / HALL_PIECE_LENGTH))
			var x0 := (float(lo[0]) + float(hi[0])) * 0.5 - count * HALL_PIECE_LENGTH * 0.5
			var z := (float(lo[2]) + float(hi[2])) * 0.5
			var last := ""
			for k in count:
				var at := Vector3(x0 + (k + 0.5) * HALL_PIECE_LENGTH, map_y + float(hi[1]), z)
				var yaw := PI if rng.randf() < 0.5 else 0.0
				last = _pick(HALL_PIECES, rng, last)
				_place(root, meshes[last], at, yaw, shadows)
		elif id == "staff_table":
			# along z with the chairs on its -x side: the piece's +z (diners) turns to -x
			var at := Vector3((float(lo[0]) + float(hi[0])) * 0.5, map_y + float(hi[1]),
				(float(lo[2]) + float(hi[2])) * 0.5)
			_place(root, meshes["staff"], at, -PI * 0.5, shadows)
	for room in layout.get("rooms", []):
		if String(room.get("id", "")) != "kitchens":
			continue
		var rect: Array = room["rect"]
		var top := map_y + float(room["y"]) + KITCHEN_TABLE_TOP
		var z0 := float(rect[2]) + KITCHEN_TABLE_Z[0]
		var z1 := float(rect[3]) - KITCHEN_TABLE_Z[1]
		var count := int(floor((z1 - z0) / KITCHEN_PIECE_LENGTH))
		for x in [float(rect[0]) + KITCHEN_TABLE_INSET, float(rect[1]) - KITCHEN_TABLE_INSET]:
			var bare := []
			while bare.size() < mini(KITCHEN_BARE, count - 1):
				var k := rng.randi() % count
				if not bare.has(k):
					bare.append(k)
			var last := ""
			for k in count:
				if bare.has(k):
					last = ""
					continue
				var at := Vector3(x, top, z0 + (k + 0.5) * KITCHEN_PIECE_LENGTH)
				var yaw := -PI * 0.5 if rng.randf() < 0.5 else PI * 0.5
				last = _pick(KITCHEN_PIECES, rng, last)
				_place(root, meshes[last], at, yaw, shadows)


## A random piece name other than `last` (neighbours would repeat).
static func _pick(names: Array, rng: RandomNumberGenerator, last: String) -> String:
	var k := rng.randi() % names.size()
	if names[k] == last:
		k = (k + 1) % names.size()
	return names[k]


static func _place(root: Node3D, mesh: Mesh, at: Vector3, yaw: float, shadows: bool) -> void:
	var mi := MeshInstance3D.new()
	mi.mesh = mesh
	mi.position = at
	mi.rotation.y = yaw
	mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_ON if shadows \
		else GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	root.add_child(mi)


## Piece name -> mesh, from the glb's MeshInstance3D nodes.
static func _meshes() -> Dictionary:
	var scene := (load(FEAST) as PackedScene).instantiate()
	var out := {}
	for node in scene.find_children("*", "MeshInstance3D", true, false):
		out[String(node.name)] = (node as MeshInstance3D).mesh
	scene.free()
	return out


static func _layout() -> Dictionary:
	var f := FileAccess.open(LAYOUT, FileAccess.READ)
	if f == null:
		return {}
	var data: Variant = JSON.parse_string(f.get_as_text())
	return data if data is Dictionary else {}
