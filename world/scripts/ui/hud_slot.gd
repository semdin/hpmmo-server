extends Button
class_name HudSlot

## One action-bar cell: a framed icon, its hotkey, a stack count and a radial
## cooldown that sweeps clockwise from twelve o'clock (the MMO convention), with
## the seconds left in the middle. Drawn in `_draw` so it stays crisp at any UI
## scale - the icon art is the only texture.
##
## Optionally a drop target (potion slots): `accept_drop` decides whether a
## dragged payload may land here and `item_dropped` reports it.

signal item_dropped(slot: HudSlot, payload: Dictionary)
signal cleared(slot: HudSlot)

var icon_texture: Texture2D = null:
	set(value):
		icon_texture = value
		queue_redraw()
var key_text := "":
	set(value):
		key_text = value
		queue_redraw()
## Stack size; -1 hides it.
var count := -1:
	set(value):
		if value != count:
			count = value
			queue_redraw()
## 0..1 of the cooldown still to run, and the seconds that represents.
var cooldown_fraction := 0.0
var cooldown_seconds := 0.0
## Greys the icon (not enough mana, dead, empty stack).
var unusable := false:
	set(value):
		if value != unusable:
			unusable = value
			queue_redraw()
var accept_drop: Callable
## Id of whatever this slot holds (a spell or an item); "" when empty.
var held_id := ""
var empty_hint := ""
var flash := 0.0
var _hover := false

func _init(px: float = 52.0) -> void:
	custom_minimum_size = Vector2(px, px)
	focus_mode = Control.FOCUS_NONE
	mouse_filter = Control.MOUSE_FILTER_STOP
	flat = true
	text = ""
	mouse_entered.connect(func(): _hover = true; queue_redraw())
	mouse_exited.connect(func(): _hover = false; queue_redraw())

func set_cooldown(seconds: float, fraction: float) -> void:
	seconds = maxf(0.0, seconds)
	fraction = clampf(fraction, 0.0, 1.0)
	if absf(seconds - cooldown_seconds) > 0.04 or absf(fraction - cooldown_fraction) > 0.004 or (seconds == 0.0) != (cooldown_seconds == 0.0):
		if cooldown_seconds > 0.0 and seconds <= 0.0:
			flash = 1.0   # ready again: a brief gold pulse
		cooldown_seconds = seconds
		cooldown_fraction = fraction if seconds > 0.0 else 0.0
		queue_redraw()

func _process(delta: float) -> void:
	if flash > 0.0:
		flash = maxf(0.0, flash - delta * 2.5)
		queue_redraw()

func _draw() -> void:
	var r := Rect2(Vector2.ZERO, size)
	# Frame: dark recess, gold bevel (two tones), inner shadow.
	draw_rect(r, Color(0, 0, 0, 0.55))
	draw_rect(r.grow(-1), Color(0.031, 0.039, 0.058, 0.95))
	var inner := r.grow(-3)
	if icon_texture != null:
		draw_texture_rect(icon_texture, inner, false, Color(0.42, 0.42, 0.45) if unusable else Color.WHITE)
		# Soft vignette so every icon sits in the frame the same way.
		draw_rect(Rect2(inner.position, Vector2(inner.size.x, 4)), Color(0, 0, 0, 0.25))
	elif empty_hint != "":
		var f := HudKit.body()
		var fs := 11
		var w := f.get_string_size(empty_hint, HORIZONTAL_ALIGNMENT_LEFT, -1, fs).x
		draw_string(f, Vector2((size.x - w) * 0.5, size.y * 0.5 + fs * 0.35), empty_hint, HORIZONTAL_ALIGNMENT_LEFT, -1, fs, Color(1, 1, 1, 0.22))
	# Radial cooldown: the dark wedge is the time still to run, swept clockwise.
	if cooldown_fraction > 0.0:
		_draw_sweep(inner, cooldown_fraction)
		var txt := ("%.1f" % cooldown_seconds) if cooldown_seconds < 3.0 else str(int(ceil(cooldown_seconds)))
		var fs2 := int(size.y * 0.36)
		var bf := HudKit.bold()
		var tw := bf.get_string_size(txt, HORIZONTAL_ALIGNMENT_LEFT, -1, fs2).x
		var pos := Vector2((size.x - tw) * 0.5, size.y * 0.5 + fs2 * 0.36)
		draw_string_outline(bf, pos, txt, HORIZONTAL_ALIGNMENT_LEFT, -1, fs2, 5, Color(0, 0, 0, 0.95))
		draw_string(bf, pos, txt, HORIZONTAL_ALIGNMENT_LEFT, -1, fs2, HudKit.GOLD_HI)
	# Bevel.
	var edge := HudKit.GOLD_LT if _hover else HudKit.GOLD.darkened(0.15)
	draw_rect(r.grow(-0.5), Color(0, 0, 0, 0.9), false, 1.0)
	draw_rect(r.grow(-1.5), edge, false, 1.0)
	draw_line(Vector2(2, 2), Vector2(size.x - 2, 2), Color(1, 0.95, 0.8, 0.35), 1.0)
	if button_pressed or (is_hovered() and Input.is_mouse_button_pressed(MOUSE_BUTTON_LEFT)):
		draw_rect(inner, Color(0, 0, 0, 0.25))
	if flash > 0.0:
		draw_rect(r.grow(-1.5), Color(1, 0.9, 0.5, flash), false, 2.0)
		draw_rect(inner, Color(1, 0.95, 0.7, flash * 0.25))
	# Hotkey (top-left) and stack (bottom-right).
	if key_text != "":
		var kf := HudKit.bold()
		var ks := 12 if key_text.length() <= 1 else 11
		var kp := Vector2(4, ks + 2)
		draw_string_outline(kf, kp, key_text, HORIZONTAL_ALIGNMENT_LEFT, -1, ks, 4, Color(0, 0, 0, 0.95))
		draw_string(kf, kp, key_text, HORIZONTAL_ALIGNMENT_LEFT, -1, ks, HudKit.PARCHMENT)
	if count >= 0:
		var cf := HudKit.bold()
		var cs := 13
		var ctext := str(count)
		var cw := cf.get_string_size(ctext, HORIZONTAL_ALIGNMENT_LEFT, -1, cs).x
		var cp := Vector2(size.x - cw - 4, size.y - 4)
		draw_string_outline(cf, cp, ctext, HORIZONTAL_ALIGNMENT_LEFT, -1, cs, 4, Color(0, 0, 0, 0.95))
		draw_string(cf, cp, ctext, HORIZONTAL_ALIGNMENT_LEFT, -1, cs, Color(1, 1, 1) if count > 0 else HudKit.RED)

func _draw_sweep(rect: Rect2, fraction: float) -> void:
	# A pie from 12 o'clock, clockwise over the elapsed part; the REMAINING part
	# is shaded, so the shade shrinks as the spell comes back.
	var c := rect.get_center()
	var radius := rect.size.length()  # past the corners; clipped below
	var start := -PI * 0.5 + TAU * (1.0 - fraction)
	var end := -PI * 0.5 + TAU
	var pts := PackedVector2Array([c])
	var steps := maxi(3, int(48 * fraction))
	for i in range(steps + 1):
		var a := lerpf(start, end, float(i) / float(steps))
		pts.append(c + Vector2(cos(a), sin(a)) * radius)
	# Clip the pie to the icon square.
	var clipped := Geometry2D.intersect_polygons(pts, PackedVector2Array([
		rect.position, Vector2(rect.end.x, rect.position.y), rect.end, Vector2(rect.position.x, rect.end.y)]))
	for poly in clipped:
		draw_colored_polygon(poly, Color(0.0, 0.0, 0.02, 0.68))
	# The sweeping hand.
	var hand := Vector2(cos(start), sin(start))
	var tip := _ray_to_rect(c, hand, rect)
	draw_line(c, tip, Color(1, 0.9, 0.55, 0.55), 1.5, true)

static func _ray_to_rect(origin: Vector2, dir: Vector2, rect: Rect2) -> Vector2:
	var t := INF
	if absf(dir.x) > 0.0001:
		t = minf(t, ((rect.end.x if dir.x > 0 else rect.position.x) - origin.x) / dir.x)
	if absf(dir.y) > 0.0001:
		t = minf(t, ((rect.end.y if dir.y > 0 else rect.position.y) - origin.y) / dir.y)
	return origin + dir * t

func _make_custom_tooltip(for_text: String) -> Object:
	return HudKit.tooltip(for_text)

func _gui_input(event: InputEvent) -> void:
	if event is InputEventMouseButton and event.pressed and event.button_index == MOUSE_BUTTON_RIGHT and accept_drop.is_valid() and held_id != "":
		accept_event()
		cleared.emit(self)

func _can_drop_data(_at: Vector2, payload: Variant) -> bool:
	return accept_drop.is_valid() and payload is Dictionary and bool(accept_drop.call(self, payload))

func _drop_data(_at: Vector2, payload: Variant) -> void:
	if _can_drop_data(_at, payload):
		item_dropped.emit(self, payload)
