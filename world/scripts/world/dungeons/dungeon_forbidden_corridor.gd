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

var _carpet: StandardMaterial3D
var _moss: StandardMaterial3D
var _wood: StandardMaterial3D
var _gold: StandardMaterial3D

func _build() -> void:
	floor_y = 1200.0
	if not collision_only:
		_carpet = _mat(Color(0.42, 0.07, 0.08), 0.9)
		_moss = _mat(Color(0.16, 0.22, 0.13), 0.95)
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
	_gate("gate_a", Vector3(0, f + 3.0, -56), Vector3(8, 6, 0.8))
	_gate("gate_b", Vector3(0, f + 3.0, -100), Vector3(8, 6, 0.8))
	_gate("gate_c", Vector3(0, f + 3.0, -160), Vector3(8, 6, 0.8))
	_gate("gate_d", Vector3(0, f + 3.0, -216), Vector3(8, 6, 0.8))
	# The harp's pedestal is solid (stand beside it to play).
	_box(Vector3(HARP.x, f + 0.5, HARP.z), Vector3(1.6, 1.0, 1.6))
	if collision_only:
		return
	_portal_ring(Vector3(0, f + 0.05, 11))
	_portal_ring(Vector3(0, f + 0.05, -230))
	_dress_corridor(f)
	_dress_gallery(f)
	_dress_cellar(f)
	_dress_hall(f)

func _dress_corridor(f: float) -> void:
	_deco(Vector3(0, f + 0.02, -21), Vector3(3.0, 0.04, 64), _carpet)
	for z in [4.0, -12.0, -28.0, -44.0]:
		_torch(Vector3(-4.3, f + 3.2, z))
		_torch(Vector3(4.3, f + 3.2, z - 8.0))
	for z in [-6.0, -20.0, -34.0]:
		_prop(ARMOUR, Vector3(-4.0, f, z), 90.0)
		_prop(ARMOUR, Vector3(4.0, f, z - 7.0), -90.0)

func _dress_gallery(f: float) -> void:
	_deco(Vector3(0, f + 0.02, -78), Vector3(4.0, 0.04, 42), _carpet)
	for z in [-66.0, -78.0, -90.0]:
		_prop(ARMOUR, Vector3(-14.0, f, z), 90.0)
		_prop(ARMOUR, Vector3(14.0, f, z), -90.0)
		_torch(Vector3(-14.3, f + 4.0, z + 6.0), Color(0.6, 0.75, 1.0), 1.4)
		_torch(Vector3(14.3, f + 4.0, z + 6.0), Color(0.6, 0.75, 1.0), 1.4)

func _dress_cellar(f: float) -> void:
	_deco(Vector3(0, f + 0.03, -120), Vector3(28, 0.06, 38), _moss)
	# Root tangles hanging off the walls.
	for i in range(10):
		var x := -13.5 if i % 2 == 0 else 13.5
		var z := -104.0 - i * 3.6
		_deco(Vector3(x, f + 4.0, z), Vector3(0.8, 5.5, 1.4), _moss)
	for z in [-108.0, -124.0, -136.0]:
		_torch(Vector3(-14.2, f + 3.0, z), Color(0.55, 1.0, 0.45), 1.2, 14.0)
		_torch(Vector3(14.2, f + 3.0, z), Color(0.55, 1.0, 0.45), 1.2, 14.0)

func _dress_hall(f: float) -> void:
	# The trapdoor Fluffy guards, gnawed bones, chains on the walls.
	_deco(Vector3(0, f + 0.05, -205), Vector3(4.0, 0.1, 4.0), _wood)
	_deco(Vector3(0, f + 0.12, -205), Vector3(4.2, 0.06, 0.25), _iron)
	_deco(Vector3(0, f + 0.12, -203.6), Vector3(4.2, 0.06, 0.25), _iron)
	_deco(Vector3(0, f + 0.12, -206.4), Vector3(4.2, 0.06, 0.25), _iron)
	for b in [Vector3(-6, 0, -180), Vector3(7, 0, -199), Vector3(-9, 0, -207), Vector3(4, 0, -186)]:
		_deco(Vector3(b.x, f + 0.12, b.z), Vector3(1.6, 0.22, 0.28), _mat(Color(0.86, 0.82, 0.72), 0.8))
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
	var frame := MeshInstance3D.new()
	var torus := TorusMesh.new()
	torus.inner_radius = 0.75
	torus.outer_radius = 0.9
	frame.mesh = torus
	frame.material_override = _gold
	frame.rotation = Vector3(deg_to_rad(90), 0, 0)
	frame.position = Vector3(0, 1.0, 0)
	harp.add_child(frame)
	for i in range(7):
		var s := MeshInstance3D.new()
		var cyl := CylinderMesh.new()
		cyl.top_radius = 0.012
		cyl.bottom_radius = 0.012
		cyl.height = 1.5 - absf(i - 3) * 0.18
		s.mesh = cyl
		s.material_override = _gold
		s.position = Vector3(-0.54 + i * 0.18, 1.0, 0)
		harp.add_child(s)
	var glow := OmniLight3D.new()
	glow.light_color = Color(1.0, 0.85, 0.5)
	glow.light_energy = 1.2
	glow.omni_range = 6.0
	glow.position = Vector3(0, 1.5, 0)
	harp.add_child(glow)
