extends RefCounted

## Only recent predicted motion can explain an old authoritative position.
## Wall time bounds the grace period even if rendering or simulation slows.
## Two seconds: in an uplink stall the server halts the body on this path
## (authority `_expire_stale_inputs`) until the next claimed position, and a
## one-second window snapped the player back to it in mid-flight.
const MAX_AGE_MS := 2000
const MAX_SAMPLES := 180
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

## Where the body was at `t_ms` (linear between samples), or Vector3.INF when
## that moment is older than the history.
func at(t_ms: int) -> Vector3:
	_prune(Time.get_ticks_msec())
	if _positions.is_empty() or t_ms < _times[0]:
		return Vector3.INF
	for i in range(_times.size() - 1, -1, -1):
		if _times[i] <= t_ms:
			if i == _times.size() - 1:
				return _positions[i]
			var span := float(_times[i + 1] - _times[i])
			var f := 0.0 if span <= 0.0 else float(t_ms - _times[i]) / span
			return _positions[i].lerp(_positions[i + 1], f)
	return _positions[0]

## A correction moved the body: its past moves with it, so the next snapshot
## is compared against where the corrected body would have been.
func shift(delta: Vector3) -> void:
	for i in _positions.size():
		_positions[i] += delta

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
