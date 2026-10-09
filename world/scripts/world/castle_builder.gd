extends RefCounted

## Walkable Hogwarts-inspired campus. Every structural piece has collision;
## doors are actual openings, with a continuous ground-level route throughout.
const Kit = preload("res://scripts/assets/material_kit.gd")
const PBR = preload("res://scripts/assets/pbr_kit.gd")
static var _materials: Dictionary = {}

static func build(world: Node3D) -> void:
	_materials.clear()
	var castle := Node3D.new()
	castle.name = "HogwartsCastle"
	castle.position = Vector3(0, 0, -72)
	world.add_child(castle)
	var stone := PBR.surface("stone_ashlar_01")
	var trim := PBR.surface("trim_sheet_01", Color(0.95, 0.92, 0.86), {"metres": 2.0})
	var roof := PBR.surface("roof_slates_03")
	var wood := PBR.surface("dark_wooden_planks")
	var floor_mat := PBR.surface("stone_tiles_02")
	var gold := Kit.gold_material()
	# Great Hall: 28 m wide, 46 m long, 13 m high. Open portal at z=24.
	_box(castle, "GreatHallFloor", Vector3(0, -0.04, 1), Vector3(30, 0.24, 48), floor_mat)
	for side in [-1, 1]:
		_box(castle, "EntranceWing", Vector3(side * 10, 6.5, 25), Vector3(10, 13, 1.4), stone)
	_box(castle, "EntranceLintel", Vector3(0, 10.2, 25), Vector3(10, 5.6, 1.4), stone)
	_arch(castle, Vector3(0, 0, 25.9), 5, 5, trim)
	_box(castle, "RearWall", Vector3(0, 6.5, -23), Vector3(30, 13, 1.2), stone)
	# Two open side doors lead to the library and classroom through cloisters.
	for side in [-1, 1]:
		for section in [{"z": 15.0, "length": 20.0}, {"z": -14.0, "length": 18.0}]:
			_box(castle, "HallWall", Vector3(side * 15, 6.5, section.z), Vector3(1.2, 13, section.length), stone)
		_box(castle, "SideDoorLintel", Vector3(side * 15, 9.5, 0), Vector3(1.2, 7, 10), stone)
		for z in [-18, -10, 10, 18]:
			_box(castle, "Buttress", Vector3(side * 16.1, 5.2, z), Vector3(1.5, 10.4, 1.4), stone)
			_box(castle, "ColumnFoot", Vector3(side * 16.1, 0.5, z), Vector3(2, 1, 2), trim)
			_window(castle, Vector3(side * 15.65, 8, z + 2.8), side * PI / 2, trim)
			_window(castle, Vector3(side * 14.35, 8, z + 2.8), -side * PI / 2, trim)
		_box(castle, "Cornice", Vector3(side * 15.2, 12.5, 1), Vector3(1.8, 0.65, 48), trim)
	# Pitched slate roof and timber rafters above the occupied volume.
	var roof_mesh := PrismMesh.new()
	roof_mesh.size = Vector3(33, 8, 50)
	_mesh(castle, "GreatHallRoof", roof_mesh, Vector3(0, 17, 1), roof)
	_box(castle, "HallCeiling", Vector3(0, 13, 1), Vector3(30, 0.3, 48), wood)
	for z in range(-20, 24, 6):
		_box(castle, "TimberRafter", Vector3(0, 12.5, z), Vector3(30, 0.6, 0.7), wood, false)
		_arch(castle, Vector3(0, 0, z), 13, 5.0, trim)
	# Dining hall: four rows, a clear center aisle, benches, plates and candles.
	var house_colors := [Color(0.55, 0.06, 0.08), Color(0.1, 0.24, 0.45), Color(0.12, 0.32, 0.2), Color(0.8, 0.58, 0.12)]
	for i in range(4):
		var x: float = [-10.0, -5.8, 5.8, 10.0][i]
		# Leave a full-width cross aisle aligned with both side-room doorways.
		_table(castle, Vector3(x, 0, -10), 10, wood)
		_table(castle, Vector3(x, 0, 12), 16, wood)
		for z in [-13, -9, -5, 5, 9, 13, 17]:
			for side in [-1, 1]:
				var plate := CylinderMesh.new()
				plate.top_radius = 0.23
				plate.bottom_radius = 0.23
				plate.height = 0.04
				_mesh(castle, "GoldPlate", plate, Vector3(x + side * 0.48, 1.12, z), gold)
		_banner(castle, Vector3(x, 9.4, -21.9), house_colors[i])
	_table(castle, Vector3(0, 0, -18), 4, wood)
	# Side rooms, open connecting halls, and vaulted cloister arcades.
	for side in [-1, 1]:
		var room_x: float = side * 28.0
		_box(castle, "CloisterFloor", Vector3(side * 17.5, -0.02, 0), Vector3(5, 0.2, 10), floor_mat)
		for z in [-5, 5]:
			_box(castle, "CloisterWall", Vector3(side * 17.5, 3, z), Vector3(5, 6, 0.8), stone)
		_box(castle, "CloisterRoof", Vector3(side * 17.5, 6, 0), Vector3(5, 0.5, 11), roof)
		_box(castle, "WingFloor", Vector3(room_x, -0.02, 0), Vector3(16, 0.2, 30), floor_mat)
		_box(castle, "WingOuterWall", Vector3(side * 36, 4.5, 0), Vector3(1, 9, 30), stone)
		for z in [-15, 15]:
			_box(castle, "WingEndWall", Vector3(room_x, 4.5, z), Vector3(16, 9, 1), stone)
		for z in [-10, 10]:
			_box(castle, "WingDoorJamb", Vector3(side * 20, 4.5, z), Vector3(1, 9, 10), stone)
		_box(castle, "WingLintel", Vector3(side * 20, 7.5, 0), Vector3(1, 3, 10), stone)
		_box(castle, "WingCeiling", Vector3(room_x, 9, 0), Vector3(17, 0.5, 31), roof)
		var wing_roof := PrismMesh.new()
		wing_roof.size = Vector3(18, 5, 32)
		_mesh(castle, "WingSlateRoof", wing_roof, Vector3(room_x, 11.7, 0), roof)
		_light(castle, Vector3(room_x, 5, 0), 2.2, 20)
		_sign(castle, "LIBRARY" if side < 0 else "CHARMS CLASSROOM", Vector3(side * 19, 5, 0), 22)
		for z in [-10, -5, 5, 10]:
			if side < 0:
				_bookshelf(castle, Vector3(-34.5, 0, z), wood, house_colors)
			else:
				_table(castle, Vector3(29, 0, z), 2.5, wood)
		if side < 0:
			_table(castle, Vector3(-27, 0, 0), 7, wood)
		else:
			_box(castle, "Blackboard", Vector3(28, 2.5, -14.3), Vector3(8, 3, 0.2), _mat(Color(0.04, 0.13, 0.12)), false)
	# Distinct skyline, flanking towers and rear astronomy spire. The front pair
	# are finished guard posts (door frame, braziers, house banners) so they
	# read as dressed architecture rather than "later content".
	for side in [-1, 1]:
		_tower(castle, Vector3(side * 20, 0, 24), 4.2, 25, stone, roof, trim)
		_tower(castle, Vector3(side * 18, 0, -25), 5, 32, stone, roof, trim)
		_guard_post(castle, Vector3(side * 20, 0, 28.6), stone, wood)
	_tower(castle, Vector3(0, 0, -33), 6, 43, stone, roof, trim)
	# Entry forecourt with uninterrupted six-metre approach from the spawn area.
	_box(castle, "EntryCourt", Vector3(0, 0.02, 33), Vector3(34, 0.1, 16), floor_mat)
	# Central runner guides the player from the portal to the head table.
	_box(castle, "HallRunner", Vector3(0, 0.088, 2), Vector3(3.4, 0.008, 39), _mat(Color(0.28, 0.055, 0.07)), false)
	for side in [-1, 1]:
		_box(castle, "RunnerTrim", Vector3(side * 1.57, 0.095, 2), Vector3(0.075, 0.01, 39), _mat(Color(0.64, 0.45, 0.19)), false)
	_sign(castle, "H O G W A R T S", Vector3(0, 11.8, 26), 42)
	_sign(castle, "GREAT HALL  •  LIBRARY  •  CHARMS", Vector3(0, 7.2, 26), 20)
	for pos in [Vector3(-7, 4, 29), Vector3(7, 4, 29), Vector3(0, 7, 14), Vector3(0, 7, 0), Vector3(0, 7, -15)]:
		_light(castle, pos, 2.0, 19)
	var candles := Node3D.new()
	candles.name = "HallCandles"
	castle.add_child(candles)
	for i in range(48):
		var pos := Vector3(-11 + (i % 8) * 3.1, 6.8 + sin(i * 2.1), -16 + (i / 8) * 6)
		var wax := CylinderMesh.new()
		wax.top_radius = 0.055
		wax.bottom_radius = 0.055
		wax.height = 0.5
		var candle := _mesh(candles, "FloatingCandle", wax, pos, trim)
		candle.set_meta("base_y", pos.y)
		candle.set_meta("phase", float(i))
		candle.add_to_group("floating_candles")
		var flame := SphereMesh.new()
		flame.radius = 0.065
		flame.height = 0.22
		_mesh(candle, "Flame", flame, Vector3(0, 0.34, 0), _mat(Color(1, 0.65, 0.2), true))
	preload("res://scripts/assets/static_batch.gd").boxes(castle)
	_materials.clear()

static func _mat(color: Color, glow: bool = false) -> StandardMaterial3D:
	var key := "%s_%s" % [color.to_html(), glow]
	if _materials.has(key):
		return _materials[key]
	var mat := StandardMaterial3D.new()
	mat.albedo_color = color
	mat.roughness = 0.78
	if glow:
		mat.emission_enabled = true
		mat.emission = color
		mat.emission_energy_multiplier = 1.8
	_materials[key] = mat
	return mat

static func _mesh(parent: Node3D, title: String, mesh: Mesh, pos: Vector3, material: Material) -> MeshInstance3D:
	var node := MeshInstance3D.new()
	node.name = title
	node.mesh = mesh
	node.material_override = material
	node.position = pos
	parent.add_child(node)
	return node

static func _box(parent: Node3D, title: String, pos: Vector3, size: Vector3, material: Material, solid: bool = true) -> MeshInstance3D:
	var mesh := BoxMesh.new()
	mesh.size = size
	var node := _mesh(parent, title, mesh, pos, material)
	if solid:
		var body := StaticBody3D.new()
		body.collision_layer = 1
		body.collision_mask = 0
		var shape := BoxShape3D.new()
		shape.size = size
		var collision := CollisionShape3D.new()
		collision.shape = shape
		body.add_child(collision)
		node.add_child(body)
	return node

static func _arch(parent: Node3D, pos: Vector3, radius: float, spring_height: float, mat: Material) -> void:
	var surface := SurfaceTool.new()
	surface.begin(Mesh.PRIMITIVE_TRIANGLES)
	# Continuous extruded elliptical arch, with no floating/disconnected blocks.
	for i in range(32):
		var corners: Array[Vector3] = []
		for angle in [PI * i / 32, PI * (i + 1) / 32]:
			for r in [radius - 0.3, radius + 0.3]:
				for z in [-0.32, 0.32]:
					corners.append(Vector3(cos(angle) * r, spring_height + sin(angle) * r * 0.5, z))
		for face in [[0, 4, 6, 2], [1, 3, 7, 5], [0, 1, 5, 4], [2, 6, 7, 3]]:
			for vertex in [face[0], face[1], face[2], face[0], face[2], face[3]]:
				surface.add_vertex(corners[vertex])
	surface.generate_normals()
	_mesh(parent, "VaultArch", surface.commit(), pos, mat)
	for side in [-1, 1]:
		_box(parent, "ArchSupport", pos + Vector3(side * radius, spring_height / 2, 0), Vector3(0.65, spring_height, 0.7), mat, false)

static func _window(parent: Node3D, pos: Vector3, yaw: float, trim: Material) -> void:
	var root := Node3D.new()
	parent.add_child(root)
	root.position = pos
	root.rotation.y = yaw
	_box(root, "WindowFrame", Vector3.ZERO, Vector3(2.2, 5, 0.18), trim, false)
	var glass := _mat(Color(0.13, 0.27, 0.34), true)
	glass.emission_energy_multiplier = 0.3
	_box(root, "StainedGlass", Vector3(0, 0, 0.11), Vector3(1.8, 4.6, 0.05), glass, false)
	_box(root, "Mullion", Vector3(0, 0, 0.18), Vector3(0.1, 4.8, 0.1), trim, false)
	for y in [-1.4, 0, 1.4]:
		_box(root, "Transom", Vector3(0, y, 0.18), Vector3(2, 0.1, 0.1), trim, false)

static func _table(parent: Node3D, pos: Vector3, length: float, wood: Material) -> void:
	_box(parent, "Table", pos + Vector3(0, 1, 0), Vector3(1.7, 0.2, length), wood)
	for side in [-1, 1]:
		_box(parent, "Bench", pos + Vector3(side * 1.35, 0.5, 0), Vector3(0.5, 0.15, length), wood)
		for z in [-length * 0.4, length * 0.4]:
			_box(parent, "TableLeg", pos + Vector3(side * 0.5, 0.5, z), Vector3(0.2, 1, 0.2), wood, false)

static func _bookshelf(parent: Node3D, pos: Vector3, wood: Material, colors: Array) -> void:
	_box(parent, "Bookcase", pos + Vector3(0, 2, 0), Vector3(1.1, 4, 3.8), wood)
	for row in range(5):
		for column in range(10):
			_box(parent, "BookSpine", pos + Vector3(0.61, 0.5 + row * 0.7, -1.6 + column * 0.33), Vector3(0.15, 0.42 + (column % 3) * 0.07, 0.24), _mat(colors[(row + column) % 4].lightened(0.1)), false)

static func _banner(parent: Node3D, pos: Vector3, color: Color) -> void:
	_box(parent, "HouseBanner", pos, Vector3(2.2, 4.8, 0.07), _mat(color), false)
	_box(parent, "BannerGoldStripe", pos + Vector3(0, 0, 0.06), Vector3(0.22, 4.7, 0.03), Kit.gold_material(), false)

## A finished guard post at a tower base: arched door frame, twin braziers,
## house banner and plaque, so the tower reads as dressed rather than pending.
static func _guard_post(parent: Node3D, pos: Vector3, stone: Material, wood: Material) -> void:
	_box(parent, "GuardDoorL", pos + Vector3(-1.3, 1.5, 0), Vector3(0.6, 3.0, 0.6), stone)
	_box(parent, "GuardDoorR", pos + Vector3(1.3, 1.5, 0), Vector3(0.6, 3.0, 0.6), stone)
	_box(parent, "GuardLintel", pos + Vector3(0, 3.2, 0), Vector3(3.2, 0.6, 0.6), stone)
	var door := _box(parent, "GuardDoor", pos + Vector3(0, 1.3, -0.2), Vector3(2.0, 2.6, 0.25), wood, false)
	door.position = pos + Vector3(0, 1.3, -0.2)
	for side in [-1, 1]:
		var braz := CylinderMesh.new()
		braz.top_radius = 0.3
		braz.bottom_radius = 0.22
		braz.height = 1.0
		_mesh(parent, "GuardBrazier", braz, pos + Vector3(side * 2.2, 0.5, 0.6), stone)
		_light(parent, pos + Vector3(side * 2.2, 1.6, 0.6), 1.6, 9.0)
	_sealed_tower_mark(parent, pos + Vector3(0, 2.0, 0.4), "HOGWARTS WATCH")

## A sealed plaque at an inactive tower's base: "this is not a door".
static func _sealed_tower_mark(parent: Node3D, pos: Vector3, text: String) -> void:
	var plaque := PBR.kit_instance("plaque_0_8x0_5")
	if plaque != null:
		plaque.position = pos
		plaque.scale = Vector3(1.6, 1.6, 1.0)
		parent.add_child(plaque)
	var label := Label3D.new()
	label.text = text
	label.font_size = 22
	label.modulate = Color(0.92, 0.86, 0.72)
	label.outline_size = 8
	label.outline_modulate = Color(0, 0, 0)
	label.billboard = BaseMaterial3D.BILLBOARD_ENABLED
	label.position = pos + Vector3(0, 0.95, 0.1)
	parent.add_child(label)

static func _tower(parent: Node3D, pos: Vector3, radius: float, height: float, stone: Material, roof: Material, trim: Material) -> void:
	var cylinder := CylinderMesh.new()
	cylinder.top_radius = radius
	cylinder.bottom_radius = radius * 1.04
	cylinder.height = height
	cylinder.radial_segments = 24
	var tower := _mesh(parent, "Tower", cylinder, pos + Vector3.UP * height / 2, stone)
	var body := StaticBody3D.new()
	var shape := CylinderShape3D.new()
	shape.radius = radius
	shape.height = height
	var collision := CollisionShape3D.new()
	collision.shape = shape
	body.add_child(collision)
	tower.add_child(body)
	for h in [height * 0.33, height * 0.65, height]:
		var ring := TorusMesh.new()
		ring.inner_radius = radius - 0.15
		ring.outer_radius = radius + 0.3
		_mesh(parent, "TowerCornice", ring, pos + Vector3.UP * h, trim)
	var cone := CylinderMesh.new()
	cone.top_radius = 0.06
	cone.bottom_radius = radius * 1.25
	cone.height = radius * 2.8
	cone.radial_segments = 24
	_mesh(parent, "SlateSpire", cone, pos + Vector3.UP * (height + radius * 1.4), roof)
	for i in range(8):
		var angle := i * TAU / 8
		for h in [height * 0.35, height * 0.7]:
			_window(parent, pos + Vector3(sin(angle) * (radius + 0.05), h, cos(angle) * (radius + 0.05)), angle, trim)

static func _light(parent: Node3D, pos: Vector3, energy: float, radius: float) -> void:
	var light := OmniLight3D.new()
	light.position = pos
	light.light_color = Color(1, 0.8, 0.53)
	light.light_energy = energy
	light.omni_range = radius
	parent.add_child(light)

static func _sign(parent: Node3D, text: String, pos: Vector3, size: int) -> void:
	var label := Label3D.new()
	label.text = text
	label.position = pos
	label.font_size = size
	label.modulate = Color(1, 0.85, 0.55)
	label.outline_size = 4
	parent.add_child(label)
