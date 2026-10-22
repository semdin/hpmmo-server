extends Node
class_name HudChat

## Metin2-style chat, driving the HUD's `ChatContainer` (its node paths are part
## of the HUD contract, so the nodes stay and this styles and feeds them).
##
## Idle, the box is see-through: only the last few lines float over the world,
## outlined so they read on grass or sky, and each fades out after a while.
## Enter focuses the input; the box gains a glass panel, shows the full scroll-
## back and the input line. Enter again sends and lets go; Esc lets go.
##
## Channels: a plain line is LOCAL (players near you, and it rises over your
## head as a speech bubble); a line starting with "!" is a SHOUT to the whole
## server. System lines carry no "[System]"/"[Server]" tags any more.

const IDLE_LINES := 7
const IDLE_FADE_AFTER := 14.0
const IDLE_FADE_TIME := 2.0
const HISTORY := 150
const FONT_SIZE := 15

var container: PanelContainer
var history: RichTextLabel
var input: LineEdit
var _lines: Array = []   # [{t: float, bb: String}]
var _dirty := true
var _tick := 0.0
var _focused := false

func setup(p_container: PanelContainer, p_history: RichTextLabel, p_input: LineEdit) -> void:
	container = p_container
	history = p_history
	input = p_input
	history.bbcode_enabled = true
	history.scroll_following = true
	history.fit_content = false
	history.selection_enabled = false
	history.mouse_filter = Control.MOUSE_FILTER_IGNORE
	history.add_theme_font_override("normal_font", HudKit.body())
	history.add_theme_font_override("bold_font", HudKit.bold())
	history.add_theme_font_size_override("normal_font_size", FONT_SIZE)
	history.add_theme_font_size_override("bold_font_size", FONT_SIZE)
	history.add_theme_color_override("default_color", HudKit.TEXT)
	history.add_theme_color_override("font_outline_color", Color(0, 0, 0, 0.92))
	history.add_theme_constant_override("outline_size", 4)
	history.add_theme_color_override("font_shadow_color", Color(0, 0, 0, 0.5))
	history.add_theme_constant_override("shadow_offset_y", 1)
	history.add_theme_constant_override("line_separation", 2)
	history.add_theme_stylebox_override("normal", HudKit.empty())
	input.placeholder_text = tr("Say something…   (start with ! to shout to everyone)")
	input.max_length = 200
	input.add_theme_font_override("font", HudKit.body())
	input.add_theme_font_size_override("font_size", FONT_SIZE)
	input.add_theme_color_override("font_color", HudKit.PARCHMENT)
	input.add_theme_color_override("font_placeholder_color", Color(1, 1, 1, 0.35))
	input.add_theme_color_override("caret_color", HudKit.GOLD_HI)
	var field := StyleBoxFlat.new()
	field.bg_color = Color(0.02, 0.027, 0.043, 0.85)
	field.border_color = HudKit.GOLD.darkened(0.2)
	field.set_border_width_all(1)
	field.set_corner_radius_all(4)
	field.content_margin_left = 8
	field.content_margin_right = 8
	field.content_margin_top = 4
	field.content_margin_bottom = 4
	for state in ["normal", "focus", "read_only"]:
		input.add_theme_stylebox_override(state, field)
	input.focus_entered.connect(_on_focus.bind(true))
	input.focus_exited.connect(_on_focus.bind(false))
	input.gui_input.connect(_on_input_gui)
	container.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_on_focus(false)

func is_open() -> bool:
	return _focused

func open() -> void:
	input.show()
	input.grab_focus()

func close() -> void:
	input.release_focus()

func _on_focus(on: bool) -> void:
	_focused = on
	container.add_theme_stylebox_override("panel", HudKit.panel(0.74, 6, 0.6) if on else HudKit.empty())
	input.visible = on
	history.mouse_filter = Control.MOUSE_FILTER_STOP if on else Control.MOUSE_FILTER_IGNORE
	history.scroll_active = on
	_dirty = true
	_rebuild()

func _on_input_gui(event: InputEvent) -> void:
	if event is InputEventKey and event.pressed and event.keycode == KEY_ESCAPE:
		input.clear()
		close()
		input.accept_event()

## ------------------------------------------------------------------- lines

func add_player_line(channel: String, sender: String, house: String, text: String) -> void:
	var name_col := HudKit.GOLD_LT
	if GameData.HOUSES.has(house):
		name_col = (GameData.HOUSES[house].primary_color as Color).lightened(0.45)
	var safe := _escape(text)
	var bb := ""
	if channel == "system":
		add_system_line(text)
		return
	if channel == "shout":
		bb = "[color=#%s{a}]%s[/color]" % [HudKit.SHOUT.to_html(false), tr("%s shouts: %s") % ["[b]%s[/b]" % _escape(sender), safe]]
	elif channel == "party":
		bb = "[color=#%s{a}]%s [b]%s[/b]: %s[/color]" % [Color(0.55, 0.8, 1.0).to_html(false), tr("[Party]"), _escape(sender), safe]
	else:
		bb = "[color=#%s{a}][b]%s[/b][/color][color=#%s{a}]: %s[/color]" % [name_col.to_html(false), _escape(sender), HudKit.TEXT.to_html(false), safe]
	_push(bb)

func add_system_line(text: String) -> void:
	text = text.strip_edges()
	for tag in ["[System]", "[Server]", "[SYSTEM]"]:
		text = text.trim_prefix(tag).strip_edges()
	if text.is_empty():
		return
	_push("[color=#%s{a}]%s[/color]" % [Color(0.96, 0.82, 0.45).to_html(false), _escape(text)])

func add_info_line(text: String, colour: Color) -> void:
	_push("[color=#%s{a}]%s[/color]" % [colour.to_html(false), _escape(text)])

func _push(bb: String) -> void:
	_lines.append({"t": Time.get_ticks_msec() / 1000.0, "bb": bb})
	while _lines.size() > HISTORY:
		_lines.pop_front()
	_dirty = true
	_rebuild()

static func _escape(text: String) -> String:
	return text.replace("[", "[lb]")

func _process(delta: float) -> void:
	_tick -= delta
	if _tick <= 0.0:
		_tick = 0.25
		if not _focused:
			_dirty = true
		_rebuild()

func _rebuild() -> void:
	if not _dirty or history == null:
		return
	_dirty = false
	var now := Time.get_ticks_msec() / 1000.0
	var out := PackedStringArray()
	if _focused:
		for line in _lines:
			out.append(String(line.bb).replace("{a}", "ff"))
	else:
		var start := maxi(0, _lines.size() - IDLE_LINES)
		for i in range(start, _lines.size()):
			var age: float = now - float(_lines[i].t)
			var a := clampf(1.0 - (age - IDLE_FADE_AFTER) / IDLE_FADE_TIME, 0.0, 1.0)
			if a <= 0.0:
				continue
			var hex := "%02x" % int(a * 255.0)
			var line_bb := String(_lines[i].bb).replace("{a}", hex)
			if a < 1.0:
				line_bb = "[outline_color=#000000%s]%s[/outline_color]" % ["%02x" % int(a * 235.0), line_bb]
			out.append(line_bb)
	var text := "\n".join(out)
	if history.text != text:
		history.text = text

## Evidence for the checks: the plain text of every stored line.
func plain_lines() -> Array[String]:
	var out: Array[String] = []
	var re := RegEx.new()
	re.compile("\\[[^\\]]*\\]")
	for line in _lines:
		out.append(re.sub(String(line.bb).replace("{a}", ""), "", true).replace("[lb]", "["))
	return out
