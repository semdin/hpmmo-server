extends "res://scripts/world/dungeons/dungeon_greybox.gd"

## The Queen's Lair (maps.json "dng_spider_lair", dungeons.json "spider_lair"),
## behind the sealed web gate deep in the Blackweb Caverns' Egg Caverns.
##
## Rooms, north (entry, local z +10) to south:
##   entry hall      z  10 ..  -10   the way back                     start
##   web tunnel      z -10 ..  -50   spiders; the silk nest east (side slot)
##   egg chamber     z -50 .. -100   egg sacs to burn before they hatch  gate_a
##   brood hall      z -100 .. -140  the Brood Guardian; the bone pit west (side slot)  gate_b
##   queen's nest    z -140 .. -212  the Blackweb Queen                gate_c
##   hoard           z -212 .. -228  the chest, the way out
## Positions here and in dungeons.json are local to the copy. Stone, light and
## dressing are the caverns' own (cave textures, egg clutches, cocoons, bones).

const PROP := "res://assets/models/caverns/cavern_%s.glb"
const TEX := "res://assets/terrain/textures/%s.png"

func _cave(texture: String, tint: Color, scale: float) -> StandardMaterial3D:
	var m := StandardMaterial3D.new()
	m.albedo_texture = load(TEX % (texture + "_alb_ht"))
	m.albedo_color = tint
	m.normal_enabled = true
	m.normal_texture = load(TEX % (texture + "_nrm_rgh"))
	m.uv1_triplanar = true
	m.uv1_world_triplanar = true
	m.uv1_scale = Vector3.ONE * scale
	m.roughness = 0.92
	return m

func _build() -> void:
	floor_y = 1700.0
	bay = 0.0   # rock walls carry no pilasters
	if not collision_only:
		_stone = _cave("cave_wall", Color(0.78, 0.75, 0.8), 0.3)
		_floor_mat = _cave("cave_gravel", Color(0.7, 0.68, 0.72), 0.35)
		_vault = _cave("cave_wall", Color(0.45, 0.42, 0.48), 0.25)
		_trim = _cave("cave_dust", Color(0.6, 0.58, 0.62), 0.4)
	var f := floor_y
	_room(Vector2(0, 0), Vector2(20, 20), [-10.0])
	_room(Vector2(0, -30), Vector2(10, 40), [-10.0, -50.0], 8.0, INF, [Vector2(1, -30)])
	_room(Vector2(15, -30), Vector2(18, 16), [], 8.0, INF, [], -1)
	_room(Vector2(0, -75), Vector2(36, 50), [-50.0, -100.0])
	_room(Vector2(0, -120), Vector2(24, 40), [-100.0, -140.0], 8.0, INF, [Vector2(-1, -120)])
	_room(Vector2(-21, -120), Vector2(18, 16), [], 8.0, INF, [], 1)
	wall_h = 14.0
	_room(Vector2(0, -176), Vector2(56, 72), [-140.0, -212.0])
	wall_h = 8.0
	_room(Vector2(0, -220), Vector2(16, 16), [-212.0])
	# The nest is taller than the rooms either side: wall over their doorways.
	_box(Vector3(0, f + 11.0, -140), Vector3(8.2, 6.0, 1))
	_box(Vector3(0, f + 11.0, -212), Vector3(8.2, 6.0, 1))
	_gate("start", Vector3(0, f + 3.0, -10), Vector3(8, 6, 0.8))
	_gate("gate_a", Vector3(0, f + 3.0, -100), Vector3(8, 6, 0.8))
	_gate("gate_b", Vector3(0, f + 3.0, -140), Vector3(8, 6, 0.8))
	_gate("gate_c", Vector3(0, f + 3.0, -212), Vector3(8, 6, 0.8))
	if collision_only:
		return
	_portal_ring(Vector3(0, f + 0.05, 8.5))
	_portal_ring(Vector3(0, f + 0.05, -224))
	_dress(f)

func _dress(f: float) -> void:
	var rng := RandomNumberGenerator.new()
	rng.seed = 7311
	# Entry and tunnel: silk-hung walls, cold light.
	for z in [4.0, -4.0]:
		_torch(Vector3(-9.3, f + 3.0, z), Color(0.6, 0.85, 1.0), 1.2)
		_torch(Vector3(9.3, f + 3.0, z), Color(0.6, 0.85, 1.0), 1.2)
	for z in [-18.0, -40.0]:
		_torch(Vector3(-4.3, f + 3.0, z), Color(0.7, 0.9, 0.6), 1.2)
	_torch(Vector3(4.3, f + 3.0, -46.0), Color(0.7, 0.9, 0.6), 1.2)
	for z in [-14.0, -26.0, -38.0, -47.0]:
		_prop(PROP % "cocoon", Vector3(-4.2 if int(z) % 2 == 0 else 4.2, f, z), rng.randf_range(0, 360), rng.randf_range(0.8, 1.1))
	# The silk nest and the bone pit (side slots).
	_prop(PROP % "eggs", Vector3(21, f, -24), 40.0, 0.7)
	_prop(PROP % "cocoon", Vector3(22, f, -36), 10.0, 1.0)
	_torch(Vector3(23.3, f + 3.0, -30), Color(0.8, 0.55, 1.0), 1.3)
	_prop(PROP % "bones", Vector3(-26, f, -116), 120.0, 1.1)
	_prop(PROP % "bones", Vector3(-24, f, -126), 300.0, 0.9)
	_torch(Vector3(-29.3, f + 3.0, -120), Color(1.0, 0.6, 0.35), 1.3)
	# The egg chamber: clutches along the walls, glowing mushrooms.
	for at in [Vector3(-16, 0, -54), Vector3(16, 0, -56), Vector3(-16, 0, -97), Vector3(16, 0, -97)]:
		_prop(PROP % "eggs", Vector3(at.x, f, at.z), rng.randf_range(0, 360), rng.randf_range(0.6, 0.8))
	for at in [Vector3(-17, 0, -70), Vector3(17, 0, -88), Vector3(-6, 0, -98)]:
		_prop(PROP % "mushrooms", Vector3(at.x, f, at.z), rng.randf_range(0, 360), 0.9)
	for z in [-58.0, -76.0, -94.0]:
		_torch(Vector3(-17.3, f + 3.2, z), Color(0.8, 0.55, 1.0), 1.4, 13.0)
		_torch(Vector3(17.3, f + 3.2, z), Color(0.8, 0.55, 1.0), 1.4, 13.0)
	# The brood hall: stalagmites and bones.
	for at in [Vector3(-10, 0, -106), Vector3(10, 0, -134)]:
		_prop(PROP % "stalag", Vector3(at.x, f, at.z), rng.randf_range(0, 360), 0.8)
	_prop(PROP % "bones", Vector3(8, f, -112), 60.0, 1.0)
	for z in [-110.0, -130.0]:
		_torch(Vector3(11.3, f + 3.2, z), Color(1.0, 0.6, 0.35), 1.4)
	# The Queen's nest: a ring of clutches and cocoons, crags at the rim, one
	# great violet light over the arena so she reads at range.
	for i in 10:
		var a := TAU * float(i) / 10.0
		var at := Vector3(cos(a) * 23.0, 0, -176.0 + sin(a) * 30.0)
		_prop(PROP % ("eggs" if i % 2 == 0 else "cocoon"), Vector3(at.x, f, at.z), rng.randf_range(0, 360), rng.randf_range(0.7, 1.0))
	for at in [Vector3(-24, 0, -146), Vector3(24, 0, -148), Vector3(-25, 0, -206), Vector3(25, 0, -204)]:
		_prop(PROP % "stalag", Vector3(at.x, f, at.z), rng.randf_range(0, 360), 1.2)
	for z in [-150.0, -176.0, -202.0]:
		_torch(Vector3(-27.3, f + 5.0, z), Color(0.8, 0.5, 1.0), 2.0, 16.0)
		_torch(Vector3(27.3, f + 5.0, z), Color(0.8, 0.5, 1.0), 2.0, 16.0)
	var glow := OmniLight3D.new()
	glow.light_color = Color(0.72, 0.5, 1.0)
	glow.light_energy = 2.2
	glow.omni_range = 36.0
	glow.position = Vector3(0, f + 12.0, -176)
	add_child(glow)
	# The hoard.
	_prop(PROP % "bones", Vector3(-5, f, -222), 0.0, 0.8)
	_torch(Vector3(-7.3, f + 3.0, -220), Color(1.0, 0.75, 0.4), 1.6)
	_torch(Vector3(7.3, f + 3.0, -220), Color(1.0, 0.75, 0.4), 1.6)
