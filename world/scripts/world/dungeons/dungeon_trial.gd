extends "res://scripts/world/dungeons/dungeon_greybox.gd"

## Trial Hall - the M2 test dungeon (an instanced map, maps.json "dng_trial").
##
## A greybox: entry hall with the exit portal, a corridor closed by an iron
## gate, and an arena where the run's boss rises (dungeons.json "trial").

func _build() -> void:
	floor_y = 1000.0
	# Entry hall (z 12 .. -12), corridor (z -12 .. -36), arena (z -36 .. -84).
	_room(Vector2(0, 0), Vector2(24, 24), [-12.0])
	_box(Vector3(0, floor_y - 0.5, -24), Vector3(8, 1, 24))
	_box(Vector3(-4.5, floor_y + wall_h * 0.5, -24), Vector3(1, wall_h, 24))
	_box(Vector3(4.5, floor_y + wall_h * 0.5, -24), Vector3(1, wall_h, 24))
	_room(Vector2(0, -60), Vector2(40, 48), [-36.0])
	_gate("gate_a", Vector3(0, floor_y + 3.0, -36), Vector3(8, 6, 0.8))
	_portal_ring(Vector3(0, floor_y + 0.05, 11))
	for z in [8.0, -8.0, -24.0, -48.0, -72.0]:
		for x in ([-10.0, 10.0] if z > -12.0 else ([-3.5, 3.5] if z > -36.0 else [-18.0, 18.0])):
			_torch(Vector3(x, floor_y + 3.5, z))
