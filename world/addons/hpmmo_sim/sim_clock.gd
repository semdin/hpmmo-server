extends RefCounted
class_name HPSimClock

## The sim tick as a screen should draw it: continuous.
##
## `SimAuthority.sim_tick` is an integer. It reaches a client with its
## snapshots - ten a second, unevenly - and steps twenty times a second where
## the world runs in this process. Anything drawn straight from it moves in
## jerks: a staircase flight swinging across the well took ten visible steps a
## second, a boss warning's countdown filled in ten notches.
##
## `now()` runs with time and is steered to the newest tick plus the time since
## that tick arrived, so what is drawn glides and still meets the authority's
## tick. Presentation only: nothing here decides anything, and a process
## without a screen should keep the integer tick (see HPStaircase.pose_tick).
##
## Counted in physics steps, not wall time: two steps run in one late frame are
## still a step apart. One clock for every caller, advanced once per step.

const STEER_PER_S := 3.0
const SNAP_TICKS := 6.0
const AGE_CAP_S := 0.25

static var _clock := -1.0
static var _frame := -1
static var _seen_tick := -1
static var _seen_frame := 0

static func now() -> float:
	var frame := Engine.get_physics_frames()
	if frame == _frame:
		return _clock
	var step_s := 1.0 / float(Engine.physics_ticks_per_second)
	var dt := float(mini(frame - _frame, 6)) * step_s if _frame >= 0 else 0.0
	_frame = frame
	var tick: int = SimAuthority.sim_tick
	if tick != _seen_tick:
		_seen_tick = tick
		_seen_frame = frame
	var age := minf(float(frame - _seen_frame) * step_s, AGE_CAP_S)
	var estimate := float(tick) + age * float(HPProtocol.SIM_HZ)
	if _clock < 0.0 or absf(estimate - _clock) > SNAP_TICKS:
		_clock = estimate
	else:
		_clock += dt * float(HPProtocol.SIM_HZ)
		_clock += (estimate - _clock) * minf(1.0, dt * STEER_PER_S)
	return _clock
