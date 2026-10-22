extends RefCounted
class_name ReplicaMotion

## Snapshot interpolation for a body this client only watches (another
## player, a creature). Snapshots arrive at 10 Hz on an unreliable channel, and
## in a crowd the far bodies take turns for the slots; chasing the newest
## sample with an exponential lerp moved a body in bursts. Here each sample
## keeps the server tick it describes, and the body is drawn a little in the
## past, between the two samples around that moment, so its motion is as
## smooth as the server's own.
##
## The delay adapts per body: just over one sample interval (a nearby body
## updated every snapshot is drawn ~140 ms back, a far one that is rotated
## longer). Past the newest sample the body coasts on its last velocity for a
## moment and then holds.

const MS_PER_TICK := 1000.0 / HPProtocol.SIM_HZ
const MIN_DELAY_MS := 110.0
const MAX_DELAY_MS := 320.0
const MAX_EXTRAPOLATE_MS := 150.0
## A jump this far between two samples is a teleport (a respawn, a Floo trip):
## the body goes there at once instead of gliding across the map.
const TELEPORT_DISTANCE := 8.0
const MAX_SAMPLES := 16

## Local clock minus server clock, in ms, tracked from the snapshots' ticks:
## it follows the fastest arrivals at once and drifts slowly towards slower
## ones, so jitter does not move the render time around.
static var _clock_offset := NAN
static var _clock_tick := -1

var _samples: Array = []          # [{t: server ms, pos: Vector3, rot: float}], oldest first
var _interval_ms := 100.0         # smoothed time between this body's samples
var snapped := false              # set by push() on a teleport; the caller clears it

static func _note_tick(tick: int) -> void:
	if tick <= _clock_tick:
		return
	_clock_tick = tick
	var sample := float(Time.get_ticks_msec()) - float(tick) * MS_PER_TICK
	if is_nan(_clock_offset) or sample < _clock_offset:
		_clock_offset = sample
	else:
		_clock_offset += (sample - _clock_offset) * 0.02

## Server time the client is at now (ms), from the tracked clock offset.
static func server_now_ms() -> float:
	return float(Time.get_ticks_msec()) - (0.0 if is_nan(_clock_offset) else _clock_offset)

## A new snapshot of this body (its position and facing at server tick `tick`).
func push(tick: int, pos: Vector3, rot: float) -> void:
	_note_tick(tick)
	var t := float(tick) * MS_PER_TICK
	if not _samples.is_empty():
		var last: Dictionary = _samples[-1]
		if t <= float(last.t):
			return   # a late datagram: the body already moved past it
		if (pos - (last.pos as Vector3)).length() > TELEPORT_DISTANCE:
			_samples.clear()
			snapped = true
		else:
			_interval_ms = lerpf(_interval_ms, t - float(last.t), 0.2)
	_samples.append({"t": t, "pos": pos, "rot": rot})
	if _samples.size() > MAX_SAMPLES:
		_samples.pop_front()

func has_samples() -> bool:
	return not _samples.is_empty()

func clear() -> void:
	_samples.clear()

## Where the body is drawn now: {pos, rot}.
func sample() -> Dictionary:
	var delay := clampf(_interval_ms * 1.2 + 20.0, MIN_DELAY_MS, MAX_DELAY_MS)
	var at := server_now_ms() - delay
	var first: Dictionary = _samples[0]
	if at <= float(first.t) or _samples.size() == 1:
		return {"pos": first.pos, "rot": first.rot} if at <= float(first.t) else _coast(at)
	for i in range(_samples.size() - 1, 0, -1):
		var a: Dictionary = _samples[i - 1]
		var b: Dictionary = _samples[i]
		if at >= float(a.t) and at <= float(b.t):
			var f := (at - float(a.t)) / maxf(1.0, float(b.t) - float(a.t))
			# Samples older than the pair in use are no longer needed.
			if i > 1:
				_samples = _samples.slice(i - 1)
			return {"pos": (a.pos as Vector3).lerp(b.pos, f), "rot": lerp_angle(float(a.rot), float(b.rot), f)}
	return _coast(at)

## Past the newest sample: continue on the last velocity for a moment, then hold.
func _coast(at: float) -> Dictionary:
	var last: Dictionary = _samples[-1]
	if _samples.size() < 2:
		return {"pos": last.pos, "rot": last.rot}
	var prev: Dictionary = _samples[-2]
	var span := maxf(1.0, float(last.t) - float(prev.t))
	var ahead := minf(at - float(last.t), MAX_EXTRAPOLATE_MS)
	var velocity := ((last.pos as Vector3) - (prev.pos as Vector3)) / span
	return {"pos": (last.pos as Vector3) + velocity * ahead, "rot": last.rot}
