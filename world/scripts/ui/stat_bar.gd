extends RefCounted
class_name StatBar

## One progress bar bound to authoritative numeric state, with a
## smooth animation layer that can never show an older value than the newest
## server update ("A tween must not overwrite a newer server
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

## The band is parented to a clipping frame rather than straight to the bar.
## A `ProgressBar` always fills from its own left edge, so a translucent band
## drawn from 0 would sit over the whole bar and wash its colour out - at rest,
## permanently, which is exactly what it looked like. The clip starts at the
## filled edge, so only the band's overhang past the fill survives, which is the
## receding damage it is meant to show.
var _clip: Control = null

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
	_clip = Control.new()
	_clip.name = "LagClip"
	_clip.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_clip.clip_contents = true
	_clip.set_anchors_preset(Control.PRESET_FULL_RECT)
	bar.add_child(_clip)

	lag = ProgressBar.new()
	lag.name = "Lag"
	lag.show_percentage = false
	lag.mouse_filter = Control.MOUSE_FILTER_IGNORE
	lag.set_anchors_preset(Control.PRESET_TOP_LEFT)
	var fill := StyleBoxFlat.new()
	fill.bg_color = LAG_COLOR
	lag.add_theme_stylebox_override("fill", fill)
	lag.add_theme_stylebox_override("background", StyleBoxEmpty.new())
	_clip.add_child(lag)
	lag.max_value = maxf(1.0, bar.max_value)
	lag.value = bar.value
	if not bar.resized.is_connected(_sync_geometry):
		bar.resized.connect(_sync_geometry)
	_sync_geometry()
	return self


## Put the clip's left edge on the filled edge and give the band the bar's full
## width, so the band's own fill measures the same span the bar's does and only
## the part past the fill is left visible.
func _sync_geometry() -> void:
	if _clip == null or lag == null or bar == null:
		return
	var width := bar.size.x
	var filled: float = width * clampf(bar.value / maxf(1.0, bar.max_value), 0.0, 1.0)
	_clip.offset_left = filled
	_clip.offset_right = 0.0
	_clip.offset_top = 0.0
	_clip.offset_bottom = 0.0
	lag.offset_left = -filled
	lag.offset_right = width - filled
	lag.offset_top = 0.0
	lag.offset_bottom = bar.size.y

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
	_sync_geometry()
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
	_sync_geometry()

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
