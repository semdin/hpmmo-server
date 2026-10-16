extends Control
class_name HudNotices

## Centre-screen notices: "Descend near level ground first", "Not enough mana",
## "Target is on protected ground". The old feedback was a floating 3D label
## that drifted up off the character and vanished before it could be read.
##
## A notice is a dark band that fades at both ends with the text in the middle,
## held long enough to read (about 2.5 s plus a little per word) and faded out.
## The same message again refreshes the band instead of stacking a copy; at
## most three different notices are shown at once, newest on top.

const MAX_LINES := 3
const BAND_H := 34.0

var _lines: Array = []   # [{text, kind, node, until, born}]

func _init() -> void:
	name = "Notices"
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	set_anchors_preset(Control.PRESET_CENTER_TOP)

func show_notice(text: String, kind: String = "warn") -> void:
	text = text.strip_edges()
	if text.is_empty():
		return
	var now := Time.get_ticks_msec() / 1000.0
	var hold := 2.4 + 0.12 * float(text.split(" ").size())
	for line in _lines:
		if String(line.text) == text:
			line.until = now + hold
			line.born = now
			(line.node as NoticeBand).pulse()
			return
	var band := NoticeBand.new()
	band.setup(text, kind)
	add_child(band)
	move_child(band, 0)
	_lines.push_front({"text": text, "kind": kind, "node": band, "until": now + hold, "born": now})
	while _lines.size() > MAX_LINES:
		var old: Dictionary = _lines.pop_back()
		(old.node as Node).queue_free()
	_layout()

func _layout() -> void:
	var y := 0.0
	for line in _lines:
		var n: Control = line.node
		n.position = Vector2(-n.size.x * 0.5, y)
		y += BAND_H + 4.0

func _process(_delta: float) -> void:
	if _lines.is_empty():
		return
	var now := Time.get_ticks_msec() / 1000.0
	var changed := false
	for line in _lines.duplicate():
		var n: NoticeBand = line.node
		var t_in := clampf((now - float(line.born)) / 0.15, 0.0, 1.0)
		var t_out := clampf((float(line.until) - now) / 0.45, 0.0, 1.0)
		n.modulate.a = minf(t_in, t_out)
		if now >= float(line.until):
			n.queue_free()
			_lines.erase(line)
			changed = true
	if changed:
		_layout()

## Evidence for the checks.
func visible_texts() -> Array[String]:
	var out: Array[String] = []
	for line in _lines:
		out.append(String(line.text))
	return out


class NoticeBand extends Control:
	var _label: Label
	var _kind := "warn"
	var _pulse := 0.0

	func setup(text: String, kind: String) -> void:
		_kind = kind
		mouse_filter = Control.MOUSE_FILTER_IGNORE
		var colour := HudKit.GOLD_HI
		match kind:
			"error":
				colour = Color(1.0, 0.55, 0.45)
			"mana":
				colour = Color(0.62, 0.78, 1.0)
			"info":
				colour = HudKit.PARCHMENT
			"good":
				colour = Color(0.65, 1.0, 0.6)
			"boss":
				colour = Color(1.0, 0.62, 0.95)
		_label = HudKit.label(text, 19, colour, HudKit.bold(), 5)
		_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
		_label.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
		add_child(_label)
		var w := HudKit.bold().get_string_size(text, HORIZONTAL_ALIGNMENT_LEFT, -1, 19).x
		size = Vector2(maxf(320.0, w + 160.0), HudNotices.BAND_H)
		_label.size = size

	func pulse() -> void:
		_pulse = 1.0
		queue_redraw()

	func _process(delta: float) -> void:
		if _pulse > 0.0:
			_pulse = maxf(0.0, _pulse - delta * 3.0)
			queue_redraw()

	func _draw() -> void:
		# Horizontal band, opaque in the middle and fading to nothing at the ends,
		# with hairlines top and bottom in the notice's colour.
		var accent := Color(1.0, 0.45, 0.35) if _kind == "error" else (Color(0.45, 0.65, 1.0) if _kind == "mana" else HudKit.GOLD)
		if _kind == "boss":
			accent = Color(0.85, 0.35, 0.95)
		var steps := 24
		for i in range(steps):
			var t0 := float(i) / steps
			var t1 := float(i + 1) / steps
			var a := sin(PI * (t0 + t1) * 0.5)
			var x0 := size.x * t0
			var x1 := size.x * t1
			draw_rect(Rect2(x0, 0, x1 - x0 + 0.5, size.y), Color(0.02, 0.025, 0.04, 0.72 * a))
			draw_rect(Rect2(x0, 0, x1 - x0 + 0.5, 1), Color(accent.r, accent.g, accent.b, (0.75 + _pulse * 0.25) * a))
			draw_rect(Rect2(x0, size.y - 1, x1 - x0 + 0.5, 1), Color(accent.r, accent.g, accent.b, 0.45 * a))
