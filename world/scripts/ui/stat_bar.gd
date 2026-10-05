extends RefCounted
class_name StatBar

## Phase 13: one progress bar bound to authoritative numeric state, with a
## smooth animation layer that can never show an older value than the newest
## server update (plan.md Phase 13: "A tween must not overwrite a newer server
## value").
##
## Two layers, two jobs:
##
##   * `bar`  - the authoritative readout. `max_value` and `value` are written
##              together and synchronously on every update, clamped only so a
##              malformed payload cannot draw outside its own range. Nothing
##              animates this bar, so the number a player reads is always the
##              newest one the authority sent.
##   * `lag`  - a translucent bar drawn over the fill that eases toward the same
##              value. A lagging animation is deliberately allowed; what is not
##              allowed is a *stale* one. Every update kills the in-flight tween
##              before starting the next, and each tween write is also guarded
##              by the update generation, so an older tween can never write after
##              a newer update has been applied - the lag bar only ever converges
##              on the newest target.

const LAG_COLOR := Color(1.0, 1.0, 1.0, 0.30)
const MIN_DURATION := 0.08
const MAX_DURATION := 0.45
## Below this difference the lag snaps: sub-pixel motion is not worth a tween.
const SNAP_EPSILON := 0.5

var bar: ProgressBar = null
var lag: ProgressBar = null

var _host: Node = null
var _tween: Tween = null
var _generation := 0
var _last_current := NAN
var _last_maximum := NAN
## Evidence counters (read by the checks): how many updates were applied and how
## many tween writes landed on the lag bar.
var updates: int = 0
var tween_writes: int = 0

func attach(host: Node, target: ProgressBar) -> StatBar:
	_host = host
	bar = target
	if bar == null:
		return self
	lag = ProgressBar.new()
	lag.name = "Lag"
	lag.show_percentage = false
	lag.mouse_filter = Control.MOUSE_FILTER_IGNORE
	lag.set_anchors_preset(Control.PRESET_FULL_RECT)
	var fill := StyleBoxFlat.new()
	fill.bg_color = LAG_COLOR
	lag.add_theme_stylebox_override("fill", fill)
	var transparent := StyleBoxEmpty.new()
	lag.add_theme_stylebox_override("background", transparent)
	bar.add_child(lag)
	lag.max_value = maxf(1.0, bar.max_value)
	lag.value = bar.value
	return self

## Apply a server value. `current` and `maximum` always travel together.
func set_value(current: float, maximum: float) -> void:
	if bar != null and current == _last_current and maximum == _last_maximum:
		# Same numbers again (the target frame re-applies every frame): nothing
		# to write, and no tween to disturb.
		return
	_last_current = current
	_last_maximum = maximum
	updates += 1
	_generation += 1
	if bar == null:
		return
	bar.max_value = maxf(1.0, maximum)
	# Clamp for display safety only: the authority can never send a value the
	# bar cannot draw, but a payload from a future schema must not break the HUD.
	bar.value = clampf(current, 0.0, bar.max_value)
	if lag == null:
		return
	lag.max_value = bar.max_value
	_stop_tween()
	var difference := absf(lag.value - bar.value)
	if difference <= SNAP_EPSILON:
		lag.value = bar.value
		return
	var duration := clampf(MIN_DURATION + (difference / maxf(1.0, bar.max_value)) * 0.9,
		MIN_DURATION, MAX_DURATION)
	var generation := _generation
	_tween = _host.create_tween()
	_tween.tween_method(
		func(displayed: float) -> void: _write_lag(displayed, generation),
		lag.value, bar.value, duration)

## Jump both layers to the current value with no animation (bind time, respawn,
## map transfer): a fresh bind must never animate in from a previous life's bar.
func snap() -> void:
	_generation += 1
	_stop_tween()
	if bar != null and lag != null:
		lag.max_value = bar.max_value
		lag.value = bar.value

func is_animating() -> bool:
	return _tween != null and _tween.is_valid()

func _stop_tween() -> void:
	if _tween != null and _tween.is_valid():
		_tween.kill()
	_tween = null

func _write_lag(displayed: float, generation: int) -> void:
	if generation != _generation or lag == null:
		return
	lag.value = clampf(displayed, 0.0, maxf(1.0, lag.max_value))
	tween_writes += 1
