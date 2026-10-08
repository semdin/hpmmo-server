extends Control
class_name SettingsUI

## Interface settings screen (): scalable UI, key
## rebinding, mouse sensitivity, and independent shake / flash / volume
## controls - persisted under `user://` by `GameSettings`.
##
## While the screen is open it registers itself as a UI input blocker, so keys
## typed here can never also cast a spell or mount the broom. Key capture is
## explicit: a row starts listening only after its button is pressed, and the
## very next key (or Escape to cancel) is consumed and never reaches gameplay.

const ROW_HEIGHT := 22
const SCROLL_HEIGHT := 210

var panel: Panel = null
var _sliders: Dictionary = {}
var _value_labels: Dictionary = {}
var _bind_buttons: Dictionary = {}
var _status: Label = null
var _listening_action := ""
var _built := false

## Evidence counters.
var opens: int = 0
var rebinds_applied: int = 0
var settings_written: int = 0

func open() -> void:
	_build()
	panel.show()
	opens += 1
	UIFocus.block(self)
	_refresh_all()

func close() -> void:
	if panel != null:
		panel.hide()
	_listening_action = ""
	UIFocus.unblock(self)

func is_open() -> bool:
	return panel != null and panel.visible

func toggle() -> void:
	if is_open():
		close()
	else:
		open()

## ------------------------------------------------------------------- build

func _build() -> void:
	if _built:
		return
	_built = true
	set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	panel = Panel.new()
	panel.name = "SettingsPanel"
	panel.set_anchors_preset(Control.PRESET_CENTER)
	UILayout.place_centred(panel, Vector2(560, 480))
	panel.custom_minimum_size = Vector2(560, 480)
	panel.mouse_filter = Control.MOUSE_FILTER_STOP
	var style := StyleBoxFlat.new()
	style.bg_color = Color(0.045, 0.05, 0.075, 0.97)
	style.border_color = Color(0.85, 0.72, 0.32, 0.95)
	style.set_border_width_all(2)
	style.set_corner_radius_all(10)
	panel.add_theme_stylebox_override("panel", style)
	add_child(panel)

	var title := _label(panel, "Settings", 20, Color(1.0, 0.88, 0.55), Vector2(44, 10))
	title.name = "Title"
	var title_icon := UITheme.icon_rect("ui_settings", 22.0)
	title_icon.name = "TitleIcon"
	title_icon.position = Vector2(14, 12)
	panel.add_child(title_icon)

	# --- display and input ---
	var y := 46.0
	_add_slider(panel, "ui_scale", "UI scale", GameSettings.UI_SCALE_MIN, GameSettings.UI_SCALE_MAX, 0.05, y)
	y += 30
	_add_slider(panel, "mouse_sensitivity", "Mouse sensitivity", GameSettings.SENSITIVITY_MIN, GameSettings.SENSITIVITY_MAX, 0.05, y)
	y += 30
	_add_slider(panel, "shake", "Screen shake", GameSettings.INTENSITY_MIN, GameSettings.INTENSITY_MAX, 0.05, y)
	y += 30
	_add_slider(panel, "flash", "Screen flash", GameSettings.INTENSITY_MIN, GameSettings.INTENSITY_MAX, 0.05, y)
	y += 34

	_label(panel, "Volume", 15, Color(0.95, 0.92, 0.8), Vector2(16, y))
	y += 24
	for bus_name in GameSettings.BUSES:
		_add_slider(panel, "vol_%s" % bus_name, "%s volume" % bus_name, 0.0, 1.0, 0.05, y, "audio_%s" % String(bus_name).to_lower())
		y += 28
	y += 8

	_label(panel, "Key bindings", 15, Color(0.95, 0.92, 0.8), Vector2(40, y), "ui_help")
	y += 22

	var scroll := ScrollContainer.new()
	scroll.position = Vector2(16, y)
	scroll.custom_minimum_size = Vector2(396, SCROLL_HEIGHT)
	panel.add_child(scroll)
	var rows := VBoxContainer.new()
	rows.custom_minimum_size = Vector2(380, 0)
	rows.add_theme_constant_override("separation", 2)
	scroll.add_child(rows)
	for action in GameSettings.BINDABLE_ACTIONS:
		var row := HBoxContainer.new()
		row.custom_minimum_size = Vector2(376, ROW_HEIGHT)
		var name_label := _label(row, action.replace("_", " "), 12, Color(0.88, 0.9, 0.95), Vector2.ZERO)
		name_label.custom_minimum_size = Vector2(220, ROW_HEIGHT)
		var button := Button.new()
		button.custom_minimum_size = Vector2(140, ROW_HEIGHT)
		button.focus_mode = Control.FOCUS_NONE
		button.add_theme_font_size_override("font_size", 11)
		button.pressed.connect(_on_bind_pressed.bind(action))
		row.add_child(button)
		rows.add_child(row)
		_bind_buttons[action] = button

	var reset := Button.new()
	reset.text = "Reset keys"
	reset.focus_mode = Control.FOCUS_NONE
	reset.position = Vector2(424, y)
	reset.custom_minimum_size = Vector2(120, 26)
	reset.pressed.connect(_on_reset_pressed)
	panel.add_child(reset)

	_status = _label(panel, "", 12, Color(1.0, 0.8, 0.5), Vector2(16, 440))
	_status.custom_minimum_size = Vector2(400, 20)
	var close_button := Button.new()
	close_button.text = "Close (F1)"
	close_button.focus_mode = Control.FOCUS_NONE
	close_button.position = Vector2(446, 440)
	close_button.custom_minimum_size = Vector2(100, 26)
	close_button.tooltip_text = "Close the settings (F1)"
	UITheme.set_button_icon(close_button, "ui_close")
	close_button.pressed.connect(_on_close_pressed)
	panel.add_child(close_button)
	panel.hide()

## A caption, optionally with an icon in front of it. `at` is the caption's own
## position, so an icon shifts it (never the other way around).
func _label(parent: Node, text: String, size: int, color: Color, at: Vector2, icon_id: String = "") -> Label:
	if icon_id != "":
		var icon := UITheme.icon_rect(icon_id, float(size) + 4.0)
		icon.position = at - Vector2(float(size) + 6.0, 1.0)
		parent.add_child(icon)
	var label := Label.new()
	label.text = text
	label.position = at
	label.mouse_filter = Control.MOUSE_FILTER_IGNORE
	label.add_theme_font_size_override("font_size", size)
	label.add_theme_color_override("font_color", color)
	label.add_theme_color_override("font_outline_color", Color(0, 0, 0, 1))
	label.add_theme_constant_override("outline_size", 4)
	parent.add_child(label)
	return label

func _add_slider(parent: Node, key: String, title: String, minimum: float, maximum: float, step: float, y: float, icon_id: String = "") -> void:
	var label_at := Vector2(38, y) if icon_id != "" else Vector2(16, y)
	var label := _label(parent, title, 13, Color(0.9, 0.92, 0.96), label_at)
	label.custom_minimum_size = Vector2(148, 20)
	if icon_id != "":
		var icon := UITheme.icon_rect(icon_id, 16.0)
		icon.position = Vector2(16, y + 1)
		parent.add_child(icon)
	var value_label := _label(parent, "", 12, Color(1.0, 0.9, 0.6), Vector2(486, y))
	value_label.custom_minimum_size = Vector2(56, 20)
	var slider := HSlider.new()
	slider.position = Vector2(190, y + 2)
	slider.custom_minimum_size = Vector2(288, 16)
	slider.min_value = minimum
	slider.max_value = maximum
	slider.step = step
	slider.focus_mode = Control.FOCUS_NONE
	slider.value_changed.connect(_on_slider_changed.bind(key))
	parent.add_child(slider)
	_sliders[key] = slider
	_value_labels[key] = value_label

## ---------------------------------------------------------------- controls

func _on_slider_changed(value: float, key: String) -> void:
	var settings := GameSettings.instance()
	match key:
		"ui_scale":
			settings.set_ui_scale(value)
		"mouse_sensitivity":
			settings.set_mouse_sensitivity(value)
		"shake":
			settings.set_shake_intensity(value)
		"flash":
			settings.set_flash_intensity(value)
		_:
			if key.begins_with("vol_"):
				settings.set_volume(key.trim_prefix("vol_"), value)
	settings_written += 1
	_refresh_all()

func _refresh_all() -> void:
	var settings := GameSettings.instance()
	for key in _sliders:
		var slider: HSlider = _sliders[key]
		slider.set_value_no_signal(_setting_value(settings, key))
		(_value_labels[key] as Label).text = _format_value(key, _setting_value(settings, key))
	for action in _bind_buttons:
		var button: Button = _bind_buttons[action]
		if action == _listening_action:
			button.text = "press a key..."
		else:
			button.text = OS.get_keycode_string(settings.binding_keycode(action))

func _setting_value(settings: GameSettings, key: String) -> float:
	match key:
		"ui_scale":
			return settings.ui_scale
		"mouse_sensitivity":
			return settings.mouse_sensitivity
		"shake":
			return settings.shake_intensity
		"flash":
			return settings.flash_intensity
		_:
			if key.begins_with("vol_"):
				return settings.get_volume(key.trim_prefix("vol_"))
	return 0.0

func _format_value(key: String, value: float) -> String:
	if key.begins_with("vol_"):
		return "%d%%" % int(round(value * 100.0))
	if key == "mouse_sensitivity":
		return "%.2fx" % value
	return "%.2f" % value

## --------------------------------------------------------------- rebinding

func _on_bind_pressed(action: String) -> void:
	_listening_action = action
	_status.text = "Press a key for '%s' (Esc cancels)" % action.replace("_", " ")
	_refresh_all()

func _on_close_pressed() -> void:
	close()

func _on_reset_pressed() -> void:
	GameSettings.instance().reset_bindings()
	_listening_action = ""
	_status.text = "Key bindings reset to defaults."
	_refresh_all()

## Consume the key while a row is listening: it never reaches gameplay, and the
## capture is the only thing that can end it (Escape cancels).
func _input(event: InputEvent) -> void:
	if _listening_action == "" or not is_open():
		return
	if not (event is InputEventKey) or not event.pressed or event.echo:
		return
	var key_event := event as InputEventKey
	get_viewport().set_input_as_handled()
	var action := _listening_action
	if key_event.keycode == KEY_ESCAPE:
		_listening_action = ""
		_status.text = "Rebinding cancelled."
		_refresh_all()
		return
	var error := GameSettings.instance().set_binding(action, key_event.physical_keycode)
	_listening_action = ""
	if error == "":
		rebinds_applied += 1
		_status.text = "'%s' is now %s." % [action.replace("_", " "), OS.get_keycode_string(key_event.physical_keycode)]
	else:
		_status.text = "Refused: %s." % error
	_refresh_all()

func describe() -> Dictionary:
	return {
		"open": is_open(),
		"listening": _listening_action,
		"opens": opens,
		"rebinds": rebinds_applied,
		"writes": settings_written,
		"settings": GameSettings.instance().describe(),
	}
