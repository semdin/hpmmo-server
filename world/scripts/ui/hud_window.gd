extends Control
class_name HudWindow

## A centred modal window in the HUD's frame language: dim backdrop, midnight
## glass card with a gold frame, an engraved title band and a close button.
## Content goes into `body`. Size is clamped to the screen so a window never
## spills off a small canvas (the old settings screen did).

signal closed

var title_text := ""
var body: VBoxContainer
var card: PanelContainer
var _title: Label
var _wanted := Vector2(560, 480)
var _backdrop: ColorRect
var dim_backdrop := true
## A modal window dims the world, swallows clicks around it and takes the
## keyboard. A non-modal one (the Esc menu, the world map) is a card floating
## over a live game: no dimming, clicks around it reach the world and the
## character keeps moving.
var modal := true

func _init(p_title: String = "", wanted: Vector2 = Vector2(560, 480)) -> void:
	title_text = p_title
	_wanted = wanted
	name = p_title.replace(" ", "") + "Window" if p_title != "" else "HudWindow"
	set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	visible = false

func _ready() -> void:
	_backdrop = ColorRect.new()
	_backdrop.color = Color(0, 0, 0, 0.45 if dim_backdrop and modal else 0.0)
	_backdrop.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	_backdrop.mouse_filter = Control.MOUSE_FILTER_STOP if modal else Control.MOUSE_FILTER_IGNORE
	_backdrop.visible = modal
	add_child(_backdrop)
	card = PanelContainer.new()
	card.name = "Card"
	card.add_theme_stylebox_override("panel", HudKit.window())
	card.mouse_filter = Control.MOUSE_FILTER_STOP
	add_child(card)
	var column := VBoxContainer.new()
	column.add_theme_constant_override("separation", 0)
	card.add_child(column)
	# Title band.
	var band := PanelContainer.new()
	var band_box := StyleBoxFlat.new()
	band_box.bg_color = Color(0.067, 0.086, 0.133)
	band_box.border_color = HudKit.GOLD.darkened(0.25)
	band_box.border_width_bottom = 1
	band_box.corner_radius_top_left = 7
	band_box.corner_radius_top_right = 7
	band_box.content_margin_left = 18
	band_box.content_margin_right = 8
	band_box.content_margin_top = 8
	band_box.content_margin_bottom = 8
	band.add_theme_stylebox_override("panel", band_box)
	column.add_child(band)
	var row := HBoxContainer.new()
	band.add_child(row)
	_title = HudKit.label(title_text.to_upper(), 19, HudKit.GOLD_LT, HudKit.title(), 3)
	_title.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	row.add_child(_title)
	var close_btn := Button.new()
	close_btn.text = "✕"
	close_btn.focus_mode = Control.FOCUS_NONE
	close_btn.flat = true
	close_btn.tooltip_text = "Close (Esc)"
	close_btn.add_theme_font_size_override("font_size", 18)
	close_btn.add_theme_color_override("font_color", HudKit.GOLD)
	close_btn.add_theme_color_override("font_hover_color", HudKit.GOLD_HI)
	close_btn.custom_minimum_size = Vector2(32, 28)
	close_btn.pressed.connect(close)
	row.add_child(close_btn)
	var margin := MarginContainer.new()
	for side in ["left", "right", "top", "bottom"]:
		margin.add_theme_constant_override("margin_" + side, 18 if side in ["left", "right"] else 14)
	margin.size_flags_vertical = Control.SIZE_EXPAND_FILL
	column.add_child(margin)
	body = VBoxContainer.new()
	body.add_theme_constant_override("separation", 10)
	body.size_flags_vertical = Control.SIZE_EXPAND_FILL
	margin.add_child(body)
	get_viewport().size_changed.connect(_layout)
	_layout()

func set_title(text: String) -> void:
	title_text = text
	if _title != null:
		_title.text = text.to_upper()

func _layout() -> void:
	if card == null:
		return
	var canvas := get_viewport().get_visible_rect().size
	var s := Vector2(minf(_wanted.x, canvas.x - 40.0), minf(_wanted.y, canvas.y - 40.0))
	card.custom_minimum_size = s
	card.size = s
	card.position = ((canvas - s) * 0.5).floor()

func open() -> void:
	show()
	_layout()
	if modal:
		UIFocus.block(self)

func close() -> void:
	if not visible:
		return
	hide()
	UIFocus.unblock(self)
	closed.emit()

func is_open() -> bool:
	return visible

func toggle() -> void:
	if visible:
		close()
	else:
		open()
