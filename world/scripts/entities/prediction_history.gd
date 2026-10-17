extends RefCounted

## Only recent predicted motion can explain an old authoritative position.
## Wall time bounds the grace period even if rendering or simulation slows.
const MAX_AGE_MS := 1000
const MAX_SAMPLES := 90
var _positions: Array[Vector3] = []
var _times: Array[int] = []

func clear() -> void:
	_positions.clear()
	_times.clear()

func record(pos: Vector3, now_ms: int = -1) -> void:
	if now_ms < 0:
		now_ms = Time.get_ticks_msec()
	_positions.append(pos)
	_times.append(now_ms)
	_prune(now_ms)

func _prune(now_ms: int) -> void:
	while not _times.is_empty() and (_times.size() > MAX_SAMPLES or now_ms - _times[0] > MAX_AGE_MS):
		_times.pop_front()
		_positions.pop_front()

func is_empty() -> bool:
	_prune(Time.get_ticks_msec())
	return _positions.is_empty()

func closest(pos: Vector3, current: Vector3, now_ms: int = -1) -> Vector3:
	if now_ms < 0:
		now_ms = Time.get_ticks_msec()
	_prune(now_ms)
	var best := current
	var distance := pos.distance_squared_to(best)
	for point in _positions:
		var candidate := pos.distance_squared_to(point)
		if candidate < distance:
			distance = candidate
			best = point
	return best
