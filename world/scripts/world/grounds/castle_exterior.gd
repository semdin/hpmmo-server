extends RefCounted
class_name CastleExterior

## Hogwarts as seen from the grounds: a walled shell of halls, wings and towers
## on the promontory (plateau ~58 m). Nothing here is enterable except the great
## doors, which are the portal into the castle interior map.
##
## Layout is in castle-local metres with the origin at ORIGIN and +z pointing at
## the courtyard (south). The entrance front is at local z = 55, i.e. world z = 5,
## which is where maps.json puts the castle_door portal.
##
## Every block's foundation is extended down to the lowest ground under its
## footprint, so a hall on the plateau edge sits on masonry, never on air.

const PBR = preload("res://scripts/assets/pbr_kit.gd")

const ORIGIN := Vector3(0.0, 0.0, -50.0)
## Door opening (world): centre of the threshold, and the doorway size.
const DOOR_CENTER := Vector3(0.0, 0.0, 5.0)
const DOOR_SIZE := Vector2(6.0, 9.0)

## [name, centre x, centre z, size x, size z, wall height, roof height, roof axis ("x"/"z"/"pyr")]
const HALLS := [
	["EntranceHall", 0.0, 46.0, 28.0, 18.0, 24.0, 11.0, "z"],
	["GreatHall", -37.0, 40.0, 40.0, 18.0, 22.0, 12.0, "x"],
	["CentralKeep", 0.0, 18.0, 22.0, 26.0, 32.0, 14.0, "pyr"],
	["EastWing", 38.0, 36.0, 40.0, 16.0, 20.0, 9.0, "x"],
	["NorthRange", 0.0, -30.0, 96.0, 18.0, 26.0, 10.0, "x"],
	["WestRange", -56.0, 4.0, 16.0, 52.0, 22.0, 9.0, "z"],
	["Library", 40.0, 0.0, 26.0, 18.0, 24.0, 10.0, "x"],
]
## [name, x, z, radius, height, spire height, windows per ring]
const TOWERS := [
	["AstronomyTower", -46.0, -52.0, 7.0, 74.0, 22.0, 6],
	["GryffindorTower", 42.0, -54.0, 7.0, 62.0, 19.0, 6],
	["RavenclawTower", 64.0, 6.0, 6.5, 56.0, 17.0, 6],
	["HeadmasterTower", 0.0, -48.0, 5.5, 54.0, 18.0, 5],
	["EntranceTowerW", -17.0, 54.0, 4.6, 34.0, 13.0, 4],
	["EntranceTowerE", 17.0, 54.0, 4.6, 34.0, 13.0, 4],
	["WestTowerS", -64.0, 46.0, 5.0, 40.0, 14.0, 4],
	["WestTowerN", -66.0, -18.0, 5.2, 44.0, 15.0, 4],
	["EastTowerS", 62.0, 44.0, 4.6, 36.0, 13.0, 4],
	["NorthEastTower", 62.0, -34.0, 5.0, 46.0, 15.0, 4],
	["KeepTowerW", -12.0, 4.0, 3.6, 48.0, 13.0, 3],
	["KeepTowerE", 12.0, 4.0, 3.6, 48.0, 13.0, 3],
]
## Curtain wall ring (local x, z), closed.
const CURTAIN := [[-64.0, 46.0], [-66.0, -18.0], [-46.0, -52.0], [0.0, -48.0], [42.0, -54.0], [62.0, -34.0], [64.0, 6.0], [62.0, 44.0]]
const CURTAIN_HEIGHT := 14.0
const CURTAIN_THICK := 3.0
## The clock tower: square, beside the east wing, facing the courtyard.
const CLOCK := [30.0, 56.0, 9.0, 46.0, 16.0]


static func materials() -> Dictionary:
	var glass := StandardMaterial3D.new()
	# Leaded glass: dark and glossy by day, with a faint warm glow from inside.
	glass.albedo_color = Color(0.07, 0.08, 0.10)
	glass.metallic = 0.3
	glass.roughness = 0.12
	glass.emission_enabled = true
	glass.emission = Color(0.95, 0.64, 0.32)
	glass.emission_energy_multiplier = 0.35
	var clock := StandardMaterial3D.new()
	clock.albedo_color = Color(0.85, 0.80, 0.62)
	clock.emission_enabled = true
	clock.emission = Color(1.0, 0.86, 0.55)
	clock.emission_energy_multiplier = 0.9
	var door := PBR.surface("medieval_wood", Color(0.55, 0.42, 0.32), {"metres": 2.0})
	return {
		"stone": PBR.surface("castle_wall_varriation", Color(0.84, 0.86, 0.92), {"metres": 6.0}),
		"trim": PBR.surface("stone_wall", Color(0.80, 0.81, 0.84), {"metres": 3.0}),
		"roof": PBR.surface("roof_slates_02", Color(0.42, 0.47, 0.58), {"metres": 3.0}),
		"glass": glass,
		"clock": clock,
		"door": door,
		"dark": _flat(Color(0.03, 0.03, 0.035)),
	}


static func _flat(c: Color) -> StandardMaterial3D:
	var m := StandardMaterial3D.new()
	m.albedo_color = c
	m.roughness = 1.0
	return m


static func _w(x: float, z: float) -> Vector3:
	return ORIGIN + Vector3(x, 0, z)


## Lowest and highest ground under a footprint rectangle (world).
static func _ground_span(c: Vector3, size: Vector2) -> Vector2:
	var lo := INF
	var hi := -INF
	for i in 5:
		for j in 5:
			var p := c + Vector3((i / 4.0 - 0.5) * size.x, 0, (j / 4.0 - 0.5) * size.y)
			var h := GroundsTerrain.height_at(p.x, p.z)
			if is_nan(h):
				continue
			lo = minf(lo, h)
			hi = maxf(hi, h)
	return Vector2(lo, hi) if lo != INF else Vector2(58.0, 58.0)


static func build(parent: Node3D, visuals: bool = true) -> Node3D:
	var kit := ArchKit.new(true)
	# The castle floor is the ground at the doors, so the threshold is flush with
	# the approach; blocks on higher ground are simply founded into it.
	var at_door := GroundsTerrain.height_at(DOOR_CENTER.x, DOOR_CENTER.z + 3.0)
	var top := (at_door if not is_nan(at_door) else 58.0) + 0.05
	for h in HALLS:
		_hall(kit, h, top)
	for t in TOWERS:
		_tower(kit, t, top)
	_curtain(kit, top)
	_clock_tower(kit, top)
	_entrance(kit, top)
	var node := kit.finish(parent, materials() if visuals else {}, "HogwartsCastle", 1, visuals)
	node.set_meta("floor_y", top)
	if visuals:
		_lights(node, top)
	return node


static func _hall(kit: ArchKit, h: Array, top: float) -> void:
	var c := _w(h[1], h[2])
	var size := Vector2(h[3], h[4])
	var wall_h: float = h[5]
	var span := _ground_span(c, size)
	var base := minf(span.x, top) - 3.0
	var height := top + wall_h - base
	kit.box(Vector3(c.x, base + height * 0.5, c.z), Vector3(size.x, height, size.y), 0.0, "stone")
	# plinth and cornice bands
	kit.box(Vector3(c.x, top + 0.6, c.z), Vector3(size.x + 0.8, 1.2, size.y + 0.8), 0.0, "trim", false)
	kit.box(Vector3(c.x, top + wall_h - 0.4, c.z), Vector3(size.x + 0.6, 0.8, size.y + 0.6), 0.0, "trim", false)
	var roof_base := Vector3(c.x, top + wall_h, c.z)
	match String(h[7]):
		"x":
			kit.gable(roof_base, size, h[6], 0.0, "roof", "stone")
		"z":
			kit.gable(roof_base, Vector2(size.y, size.x), h[6], PI * 0.5, "roof", "stone")
		_:
			kit.pyramid(roof_base, size, h[6], 0.0, "roof")
	# windows: rows on the long faces, tall lancets
	var floors := maxi(1, int(wall_h / 8.0))
	for f in floors:
		var y := top + 4.5 + f * 8.0
		var tall := 4.5 if f == floors - 1 and String(h[0]) == "GreatHall" else 2.6
		for side in [-1, 1]:
			var nx := int(size.x / 6.0)
			for i in nx:
				var x := c.x - size.x * 0.5 + (i + 0.5) * size.x / nx
				kit.window(Vector3(x, y, c.z + side * (size.y * 0.5 + 0.02)), Vector3(0, 0, side), 1.3, tall, "trim", "glass")
			var nz := int(size.y / 6.0)
			for i in nz:
				var z := c.z - size.y * 0.5 + (i + 0.5) * size.y / nz
				kit.window(Vector3(c.x + side * (size.x * 0.5 + 0.02), y, z), Vector3(side, 0, 0), 1.2, 2.4, "trim", "glass")
	# corner buttresses
	for sx in [-1, 1]:
		for sz in [-1, 1]:
			var p := Vector3(c.x + sx * size.x * 0.5, 0, c.z + sz * size.y * 0.5)
			kit.box(Vector3(p.x, base + (top + wall_h * 0.8 - base) * 0.5, p.z), Vector3(2.2, top + wall_h * 0.8 - base, 2.2), 0.0, "trim")


static func _tower(kit: ArchKit, t: Array, top: float) -> void:
	var c := _w(t[1], t[2])
	var r: float = t[3]
	var h: float = t[4]
	var span := _ground_span(c, Vector2(r * 2, r * 2))
	var base := minf(span.x, top) - 3.0
	var foot := Vector3(c.x, base, c.z)
	# battered base, shaft, corbelled crown, spire
	kit.cylinder(foot, r * 1.18, top - base + 4.0, "stone", 20, true, r * 1.02)
	kit.cylinder(Vector3(c.x, top + 4.0, c.z), r, h - 4.0, "stone", 20)
	kit.cylinder(Vector3(c.x, top + h - 1.2, c.z), r * 1.14, 1.6, "trim", 20, false)
	kit.tower_battlements(Vector3(c.x, top + h + 0.4, c.z), r * 1.08, "trim", int(r * 2.2))
	kit.cylinder(Vector3(c.x, top + h + 0.4, c.z), r * 0.86, 3.2, "stone", 18, false)
	kit.cone(Vector3(c.x, top + h + 3.6, c.z), r * 0.86, t[5], "roof", 18, 1.18)
	var rings := maxi(2, int(h / 11.0))
	for k in rings:
		kit.tower_windows(Vector3(c.x, top, c.z), r, 8.0 + k * (h - 12.0) / maxf(1, rings - 1), int(t[6]), "trim", "glass", 0.9, 2.1, k * 0.4)


static func _curtain(kit: ArchKit, top: float) -> void:
	for i in CURTAIN.size():
		var a: Array = CURTAIN[i]
		var b: Array = CURTAIN[(i + 1) % CURTAIN.size()]
		var pa := _w(a[0], a[1])
		var pb := _w(b[0], b[1])
		var mid := (pa + pb) * 0.5
		var d := pb - pa
		var length := Vector2(d.x, d.z).length()
		var rot := atan2(-d.z, d.x)
		var span := _ground_span(mid, Vector2(length * 0.7, 4.0))
		var base := minf(span.x, top) - 3.0
		var height := top + CURTAIN_HEIGHT - base
		kit.box(Vector3(mid.x, base + height * 0.5, mid.z), Vector3(length, height, CURTAIN_THICK), rot, "stone")
		kit.battlements(Vector3(pa.x, top + CURTAIN_HEIGHT, pa.z), Vector3(pb.x, top + CURTAIN_HEIGHT, pb.z), CURTAIN_THICK * 0.4, "trim")


static func _clock_tower(kit: ArchKit, top: float) -> void:
	var c := _w(CLOCK[0], CLOCK[1])
	var s: float = CLOCK[2]
	var h: float = CLOCK[3]
	var span := _ground_span(c, Vector2(s, s))
	var base := minf(span.x, top) - 3.0
	kit.box(Vector3(c.x, base + (top + h - base) * 0.5, c.z), Vector3(s, top + h - base, s), 0.0, "stone")
	kit.box(Vector3(c.x, top + h - 0.5, c.z), Vector3(s + 1.0, 1.0, s + 1.0), 0.0, "trim", false)
	kit.pyramid(Vector3(c.x, top + h, c.z), Vector2(s, s), CLOCK[4], 0.0, "roof", 0.5)
	for n: Vector3 in [Vector3(0, 0, 1), Vector3(1, 0, 0), Vector3(-1, 0, 0), Vector3(0, 0, -1)]:
		var face := Vector3(c.x, top + h - 6.0, c.z) + n * (s * 0.5 + 0.06)
		kit.box(face, Vector3(5.2, 5.2, 0.2) if n.z != 0 else Vector3(0.2, 5.2, 5.2), 0.0, "trim", false)
		kit.box(face + n * 0.12, Vector3(4.2, 4.2, 0.1) if n.z != 0 else Vector3(0.1, 4.2, 4.2), 0.0, "clock", false)
		kit.window(Vector3(c.x, top + 10.0, c.z) + n * (s * 0.5 + 0.02), n, 1.2, 3.0, "trim", "glass")
		kit.window(Vector3(c.x, top + 20.0, c.z) + n * (s * 0.5 + 0.02), n, 1.2, 3.0, "trim", "glass")


## The great doors: a deep arched porch in the entrance hall's south face. The
## porch floor is open (no collider in the doorway) so a player can walk up to
## the doors; the doors themselves are a solid slab at the back of the porch.
static func _entrance(kit: ArchKit, top: float) -> void:
	var front_z := DOOR_CENTER.z
	var w := DOOR_SIZE.x
	var h := DOOR_SIZE.y
	# porch: two piers and a lintel projecting 3 m from the facade
	for sx in [-1, 1]:
		kit.box(Vector3(sx * (w * 0.5 + 1.2), top + (h + 2.0) * 0.5, front_z + 1.5), Vector3(2.4, h + 2.0, 3.0), 0.0, "trim")
	kit.box(Vector3(0, top + h + 2.6, front_z + 1.5), Vector3(w + 4.8, 3.2, 3.0), 0.0, "trim")
	kit.gable(Vector3(0, top + h + 4.2, front_z + 1.5), Vector2(3.0, w + 5.0), 3.2, PI * 0.5, "roof", "trim", 0.3)
	# the doors stand at the back of the porch, against the facade
	kit.box(Vector3(0, top + h * 0.5, front_z + 0.2), Vector3(w, h, 0.4), 0.0, "door")
	kit.box(Vector3(0, top + h + 0.6, front_z + 0.12), Vector3(w, 1.2, 0.2), 0.0, "dark", false)
	# a flush stone apron in front (its top is the threshold height)
	var g := GroundsTerrain.height_at(DOOR_CENTER.x, DOOR_CENTER.z + 6.0)
	var apron_bottom := (g if not is_nan(g) else top) - 1.5
	kit.box(Vector3(0, (top + apron_bottom) * 0.5, front_z + 5.0), Vector3(w + 6.0, top - apron_bottom, 10.0), 0.0, "trim")


static func _lights(node: Node3D, top: float) -> void:
	for sx in [-1, 1]:
		var l := OmniLight3D.new()
		l.light_color = Color(1.0, 0.72, 0.42)
		l.light_energy = 1.6
		l.omni_range = 12.0
		l.position = Vector3(sx * 4.4, top + 6.5, DOOR_CENTER.z + 3.4)
		l.add_to_group("torch_lights")
		node.add_child(l)
