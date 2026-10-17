extends "res://scripts/world/dungeons/dungeon_greybox.gd"

## The Forbidden Corridor (maps.json "dng_forbidden_corridor", dungeons.json
## "forbidden_corridor"), entered through the locked door on the castle's
## third-floor east corridor.
##
## Rooms, north (entry, local z +12) to south:
##   corridor      z  12 ..  -56   pixies + two armours           gate_a
##   armour gallery z -56 .. -100  the Cursed Armour Commander    gate_b
##   snare cellar  z -100 .. -140  the Devil's Snare
##   stair         z -140 .. -160  pixie swarm                    gate_c
##   Fluffy's hall z -160 .. -216  Fluffy, the harp, the trapdoor gate_d
##   reward room   z -216 .. -232  the chest, the way out
## Positions here and in dungeons.json are local to the copy.

const HARP := Vector3(18, 0, -172)
const ARMOUR := "res://assets/models/monsters/armour_guard.glb"
const SNARE := "res://assets/models/monsters/devils_snare.glb"
## Generated dressing (art/forbidden_corridor: gpt-image concepts -> Hunyuan 3D
## -> scripts/prop_prepare.py; carpet and tapestries are gpt-image textures).
const ART := "res://assets/dungeons/forbidden_corridor/"
const PBR = preload("res://scripts/assets/pbr_kit.gd")

var _carpet: StandardMaterial3D
var _moss: Material
var _wood: StandardMaterial3D
var _gold: StandardMaterial3D

func _build() -> void:
	floor_y = 1200.0
	if not collision_only:
		_carpet = _mat(Color(0.85, 0.8, 0.78), 0.92)
		if ResourceLoader.exists(ART + "carpet.jpg"):
			_carpet.albedo_texture = load(ART + "carpet.jpg")
		_moss = PBR.surface("mossy_stone_wall", Color(0.62, 0.72, 0.58))
		_wood = _mat(Color(0.30, 0.19, 0.10), 0.85)
		_gold = _mat(Color(0.95, 0.75, 0.30), 0.35, 0.8)
		_gold.emission_enabled = true
		_gold.emission = Color(0.9, 0.7, 0.3)
		_gold.emission_energy_multiplier = 0.6
	var f := floor_y
	_room(Vector2(0, -22), Vector2(10, 68), [-56.0])
	_room(Vector2(0, -78), Vector2(30, 44), [-56.0, -100.0])
	_room(Vector2(0, -120), Vector2(30, 40), [-100.0, -140.0])
	_room(Vector2(0, -150), Vector2(10, 20), [-140.0, -160.0])
	wall_h = 14.0
	_room(Vector2(0, -188), Vector2(48, 56), [-160.0, -216.0])
	wall_h = 8.0
	_room(Vector2(0, -224), Vector2(16, 16), [-216.0])
	# The hall is taller than the rooms either side: wall over their doorways.
	_box(Vector3(0, f + 11.0, -160), Vector3(8.2, 6.0, 1))
	_box(Vector3(0, f + 11.0, -216), Vector3(8.2, 6.0, 1))
	_gate("gate_a", Vector3(0, f + 3.0, -56), Vector3(8, 6, 0.8))
	_gate("gate_b", Vector3(0, f + 3.0, -100), Vector3(8, 6, 0.8))
	_gate("gate_c", Vector3(0, f + 3.0, -160), Vector3(8, 6, 0.8))
	_gate("gate_d", Vector3(0, f + 3.0, -216), Vector3(8, 6, 0.8))
	# The harp's pedestal is solid (stand beside it to play); the model draws it.
	var pedestal := _box(Vector3(HARP.x, f + 0.5, HARP.z), Vector3(1.6, 1.0, 1.6))
	for child in pedestal.get_children():
		if child is MeshInstance3D:
			child.queue_free()
	if collision_only:
		return
	_portal_ring(Vector3(0, f + 0.05, 11))
	_portal_ring(Vector3(0, f + 0.05, -230))
	_dress_corridor(f)
	_dress_gallery(f)
	_dress_cellar(f)
	_dress_hall(f)

## A carpet runner on the floor: the texture repeats every 4.5 m of length.
func _runner(center: Vector3, width: float, length: float) -> void:
	if collision_only:
		return
	var mesh := MeshInstance3D.new()
	var plane := PlaneMesh.new()
	plane.size = Vector2(width, length)
	mesh.mesh = plane
	var m: StandardMaterial3D = _carpet.duplicate()
	m.uv1_scale = Vector3(1.0, length / 4.5, 1.0)
	mesh.material_override = m
	mesh.position = center
	add_child(mesh)

## A woven tapestry hung flat on a wall; `facing` is the yaw it looks along.
func _tapestry(file: String, at: Vector3, facing: float, size: Vector2 = Vector2(3.2, 4.8)) -> void:
	if collision_only or not ResourceLoader.exists(ART + file):
		return
	var mesh := MeshInstance3D.new()
	var quad := QuadMesh.new()
	quad.size = size
	mesh.mesh = quad
	var m := StandardMaterial3D.new()
	m.albedo_texture = load(ART + file)
	m.roughness = 0.95
	mesh.material_override = m
	mesh.position = at
	mesh.rotation.y = deg_to_rad(facing)
	add_child(mesh)
	_deco(at + Vector3(0, size.y * 0.5 + 0.08, 0), Vector3(size.x + 0.4, 0.1, 0.1) if absf(facing) < 1.0 or absf(facing - 180.0) < 1.0 else Vector3(0.1, 0.1, size.x + 0.4), _wood)

func _dress_corridor(f: float) -> void:
	_runner(Vector3(0, f + 0.02, -21), 3.0, 64)
	for z in [4.0, -12.0, -28.0, -44.0]:
		_torch(Vector3(-4.3, f + 3.2, z))
		_torch(Vector3(4.3, f + 3.2, z - 8.0))
	for z in [-6.0, -20.0, -34.0]:
		_prop(ARMOUR, Vector3(-4.0, f, z), 90.0)
		_prop(ARMOUR, Vector3(4.0, f, z - 7.0), -90.0)

func _dress_gallery(f: float) -> void:
	_runner(Vector3(0, f + 0.02, -78), 4.0, 42)
	for z in [-72.0, -84.0]:
		_tapestry("tapestry_knight.jpg", Vector3(-14.9, f + 4.2, z), 90.0)
		_tapestry("tapestry_knight.jpg", Vector3(14.9, f + 4.2, z), -90.0)
	for z in [-66.0, -78.0, -90.0]:
		_prop(ARMOUR, Vector3(-14.0, f, z), 90.0)
		_prop(ARMOUR, Vector3(14.0, f, z), -90.0)
		_torch(Vector3(-14.3, f + 4.0, z + 6.0), Color(0.6, 0.75, 1.0), 1.4)
		_torch(Vector3(14.3, f + 4.0, z + 6.0), Color(0.6, 0.75, 1.0), 1.4)

func _dress_cellar(f: float) -> void:
	_deco(Vector3(0, f + 0.03, -120), Vector3(28, 0.06, 38), _moss)
	# Snare growth climbing every wall: the creature's own vines, posed still.
	var rng := RandomNumberGenerator.new()
	rng.seed = 1999
	for i in range(10):
		var x := -13.2 if i % 2 == 0 else 13.2
		var z := -104.0 - (i / 2) * 7.5 - (3.5 if i % 2 else 0.0)
		_prop(SNARE, Vector3(x, f, z), rng.randf_range(0, 360), rng.randf_range(0.55, 0.8))
	for z in [-108.0, -124.0, -136.0]:
		_torch(Vector3(-14.2, f + 3.0, z), Color(0.75, 1.0, 0.6), 1.3, 14.0)
		_torch(Vector3(14.2, f + 3.0, z), Color(0.75, 1.0, 0.6), 1.3, 14.0)

## One hanging root: a tapered, slightly leaning cylinder.
func _unused_root(top: Vector3, length: float, radius: float, lean: Vector3, material: Material) -> void:
	var mesh := MeshInstance3D.new()
	var cyl := CylinderMesh.new()
	cyl.top_radius = radius
	cyl.bottom_radius = radius * 0.25
	cyl.height = length
	cyl.radial_segments = 6
	cyl.rings = 1
	mesh.mesh = cyl
	mesh.material_override = material
	mesh.rotation = lean
	mesh.position = top - (Basis.from_euler(lean) * Vector3(0, length * 0.5, 0))
	add_child(mesh)

func _dress_hall(f: float) -> void:
	# The trapdoor Fluffy guards, gnawed bones, the tapestry of the sleeping dog.
	_prop(ART + "fc_trapdoor.glb", Vector3(0, f - 0.3, -205), 0.0, 1.35)
	if not collision_only:
		var lamp := OmniLight3D.new()
		lamp.light_color = Color(1.0, 0.75, 0.45)
		lamp.light_energy = 1.6
		lamp.omni_range = 9.0
		lamp.position = Vector3(0, f + 4.5, -205)
		add_child(lamp)
	for b in [[Vector3(-7, 0, -181), 20.0], [Vector3(8, 0, -198), 140.0], [Vector3(-10, 0, -207), 250.0], [Vector3(5, 0, -186), 300.0]]:
		_prop(ART + "fc_bones.glb", Vector3(b[0].x, f, b[0].z), b[1], 1.4)
	_tapestry("tapestry_fluffy.jpg", Vector3(-23.9, f + 6.0, -190), 90.0, Vector2(4.4, 6.6))
	_tapestry("tapestry_fluffy.jpg", Vector3(23.9, f + 6.0, -190), -90.0, Vector2(4.4, 6.6))
	for z in [-168.0, -184.0, -200.0, -212.0]:
		_torch(Vector3(-23.3, f + 5.0, z), Color(1.0, 0.62, 0.3), 2.2, 16.0)
		_torch(Vector3(23.3, f + 5.0, z), Color(1.0, 0.62, 0.3), 2.2, 16.0)
	# A great hanging brazier light over the arena so the dog reads at range.
	var brazier := OmniLight3D.new()
	brazier.light_color = Color(1.0, 0.7, 0.42)
	brazier.light_energy = 2.4
	brazier.omni_range = 34.0
	brazier.position = Vector3(0, f + 12.0, -190)
	add_child(brazier)
	# The harp on its pedestal (it plays when a player stands at it).
	var harp := Node3D.new()
	harp.name = "Harp"
	harp.position = Vector3(HARP.x, f + 1.0, HARP.z)
	add_child(harp)
	if ResourceLoader.exists(ART + "fc_harp.glb"):
		var model: Node3D = (load(ART + "fc_harp.glb") as PackedScene).instantiate()
		model.position = Vector3(0, -1.0, 0)
		model.rotation.y = deg_to_rad(-90.0)
		harp.add_child(model)
	var glow := OmniLight3D.new()
	glow.light_color = Color(1.0, 0.85, 0.5)
	glow.light_energy = 1.2
	glow.omni_range = 6.0
	glow.position = Vector3(0, 1.5, 0)
	harp.add_child(glow)
