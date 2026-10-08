extends Panel
class_name UIWindow

## A framed, draggable game window: a red ribbon carrying the title, a round
## close button, and a body.
##
## Built in code rather than as a .tscn so every window in the game (bag,
## Ollivander, settings, journal) shares one construction and one look. A panel
## only has to set `title` and add its content to `body`.
##
## The ribbon is the title bar. It is sized to its own texture's aspect ratio
## and overhangs the top edge of the frame, which is what makes the header read
## as a banner pinned over the window rather than as another row inside it. It
## is also the drag handle, for the same reason a title bar usually is.
##
## Dragging writes `offset_*`, never `position`. `UILayout` documents why: a
## Control's `position` is measured from its parent's top-left, so assigning it
## on an anchored control teleports the window off-screen as soon as the anchor
## is not (0, 0). This window anchors top-left, which makes offsets and position
## agree, and the drag math stays correct at every stretch factor.

signal closed
signal moved

## A ribbon is a fixed-height band drawn as a nine-patch, so its rounded ends
## stay crisp at any window width. It overhangs the top edge of the frame so the
## header reads as a banner pinned over the window rather than another row.
const RIBBON_H := 40.0
const RIBBON_INSET := 10.0
const RIBBON_OVERHANG := 18.0

var title: String = "":
	set(value):
		title = value
		if _title_label != null:
			_title_label.text = value

var close_button_visible: bool = true
var draggable: bool = true

## Where callers add their content.
var body: VBoxContainer = null
var _title_label: Label = null
var _ribbon: Panel = null
var _close_button: Button = null
var _content_margin: MarginContainer = null
var _dragging := false
var _drag_offset := Vector2.ZERO
var _default_offset := Vector2.ZERO


func _init(p_title: String = "", p_size := Vector2(560, 420)) -> void:
	title = p_title
	custom_minimum_size = p_size
	_default_offset = Vector2(80, 70)


func _ready() -> void:
	# Top-left anchored: offsets == position, which keeps the drag math honest.
	set_anchors_preset(Control.PRESET_TOP_LEFT)
	offset_left = _default_offset.x
	offset_top = _default_offset.y
	offset_right = _default_offset.x + custom_minimum_size.x
	offset_bottom = _default_offset.y + custom_minimum_size.y
	theme = UITheme.get_theme()
	theme_type_variation = UITheme.V_WINDOW

	# ---- body first, so the ribbon and its label are drawn over the frame ----
	_content_margin = MarginContainer.new()
	_content_margin.set_anchors_preset(Control.PRESET_FULL_RECT)
	_content_margin.add_theme_constant_override("margin_left", 18)
	_content_margin.add_theme_constant_override("margin_right", 18)
	_content_margin.add_theme_constant_override("margin_top", int(RIBBON_H - RIBBON_OVERHANG) + 10)
	_content_margin.add_theme_constant_override("margin_bottom", 16)
	_content_margin.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(_content_margin)

	body = VBoxContainer.new()
	body.add_theme_constant_override("separation", 6)
	_content_margin.add_child(body)

	_build_ribbon()


func _build_ribbon() -> void:
	_ribbon = Panel.new()
	_ribbon.name = "Ribbon"
	_ribbon.set_anchors_preset(Control.PRESET_CENTER_TOP)
	# A flat band rather than a band of art: the header has to stretch with the
	# window, and a box does that without a nine-patch margin to keep in step.
	_ribbon.offset_left = -custom_minimum_size.x * 0.5 + RIBBON_INSET
	_ribbon.offset_right = custom_minimum_size.x * 0.5 - RIBBON_INSET
	_ribbon.offset_top = -RIBBON_OVERHANG
	_ribbon.offset_bottom = -RIBBON_OVERHANG + RIBBON_H
	var band := StyleBoxFlat.new()
	band.bg_color = UITheme.alpha("blood", 0.92)
	band.border_color = UITheme.c("gold_dk")
	band.set_border_width_all(1)
	band.set_corner_radius_all(6)
	_ribbon.add_theme_stylebox_override("panel", band)
	add_child(_ribbon)

	_title_label = Label.new()
	_title_label.name = "Title"
	_title_label.text = title
	_title_label.set_anchors_preset(Control.PRESET_FULL_RECT)
	_title_label.offset_left = 20
	_title_label.offset_right = -44
	_title_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_title_label.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	_title_label.add_theme_font_override("font", UITheme.font_title())
	_title_label.add_theme_font_size_override("font_size", UITheme.FS_HEADER)
	_title_label.add_theme_color_override("font_color", UITheme.c("gold_hi"))
	_title_label.add_theme_color_override("font_outline_color", Color(0.12, 0.02, 0.02))
	_title_label.add_theme_constant_override("outline_size", 5)
	_title_label.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_ribbon.add_child(_title_label)

	_close_button = Button.new()
	_close_button.name = "Close"
	_close_button.text = "✕"
	_close_button.custom_minimum_size = Vector2(26, 26)
	_close_button.focus_mode = Control.FOCUS_NONE
	UITheme.role(_close_button, UITheme.V_ICON_BTN)
	_close_button.add_theme_font_size_override("font_size", UITheme.FS_BODY)
	_close_button.add_theme_color_override("font_color", UITheme.c("gold_lt"))
	_close_button.tooltip_text = "Close"
	_close_button.pressed.connect(close)
	_close_button.visible = close_button_visible
	# Pinned to the ribbon's right end.
	_close_button.set_anchors_preset(Control.PRESET_CENTER_RIGHT)
	_close_button.offset_left = -38.0
	_close_button.offset_right = -12.0
	_close_button.offset_top = -13.0
	_close_button.offset_bottom = 13.0
	_ribbon.add_child(_close_button)

	if draggable:
		_ribbon.mouse_default_cursor_shape = Control.CURSOR_MOVE
		_ribbon.mouse_filter = Control.MOUSE_FILTER_STOP
		_ribbon.gui_input.connect(_on_header_input)
	else:
		_ribbon.mouse_filter = Control.MOUSE_FILTER_IGNORE


func _on_header_input(event: InputEvent) -> void:
	if event is InputEventMouseButton:
		var mb := event as InputEventMouseButton
		if mb.button_index == MOUSE_BUTTON_LEFT:
			_dragging = mb.pressed
			if _dragging:
				_drag_offset = get_global_mouse_position() - global_position
				move_to_front()
			accept_event()
	elif event is InputEventMouseMotion and _dragging:
		_clamp_to(get_global_mouse_position() - _drag_offset)
		moved.emit()
		accept_event()


## Keep at least the ribbon reachable, so a window can never be dragged out of
## the screen and lost.
func _clamp_to(pos: Vector2) -> void:
	var limit := view_size()
	var clamped := Vector2(
		clampf(pos.x, -size.x + 90.0, limit.x - 90.0),
		clampf(pos.y, -RIBBON_H * 0.4, limit.y - 40.0)
	)
	var delta := clamped - global_position
	offset_left += delta.x
	offset_right += delta.x
	offset_top += delta.y
	offset_bottom += delta.y


func view_size() -> Vector2:
	var vp := get_viewport()
	if vp == null:
		return Vector2(1280, 720)
	return vp.get_visible_rect().size


func open() -> void:
	if not visible:
		move_to_front()
	show()


func close() -> void:
	hide()
	closed.emit()


func is_open() -> bool:
	return visible


func set_close_visible(v: bool) -> void:
	close_button_visible = v
	if _close_button != null:
		_close_button.visible = v


## Place the window so it is fully on screen, centred on `anchor` when given.
func place_centred(size_hint := Vector2.ZERO) -> void:
	var target := size_hint if size_hint != Vector2.ZERO else size
	var view := view_size()
	var at := ((view - target) * 0.5).floor()
	offset_left = at.x
	offset_top = at.y
	offset_right = at.x + target.x
	offset_bottom = at.y + target.y
