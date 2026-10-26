extends Control
class_name SettingsUI

const QualityPreset = preload("res://scripts/world/quality_preset.gd")
const GameCredits = preload("res://scripts/ui/game_credits.gd")

## Settings, opened from the Esc menu: graphics quality, interface scale, mouse
## sensitivity, screen shake and flash, the four volume buses and key
## rebinding - persisted under `user://` by `GameSettings`.
##
## Four tabs (Graphics, Audio, Controls, Credits) in one window sized to the
## screen, so nothing spills off it the way the single long panel did; the key
## list and the credits scroll inside their tabs.
##
## While open it registers as a UI input blocker, so keys typed here can never
## also cast a spell or mount the broom. Key capture is explicit: a row listens
## only after its button is pressed, and the very next key (or Escape to cancel)
## is consumed and never reaches gameplay.

const WINDOW_SIZE := Vector2(660, 640)

## The player picked another language and wants the HUD rebuilt in it now.
signal language_apply_requested

## Player-facing names for the bindable actions (English; shown through tr()).
# i18n-begin
const ACTION_NAMES := {
	"move_forward": "Move forward", "move_backward": "Move backward",
	"move_left": "Move left", "move_right": "Move right",
	"jump": "Jump / rise", "flight_descend": "Descend (broom)",
	"mount_broom": "Mount / dismount broom", "target_cycle": "Next target",
	"pickup_loot": "Pick up loot", "interact": "Talk / interact",
	"toggle_inventory": "Bag", "toggle_ollivander": "Ollivander's forge",
	"toggle_chat": "Chat", "toggle_map": "World map", "toggle_character": "Character", "toggle_onboarding": "Guide",
	"spell_1": "Spell slot 1", "spell_2": "Spell slot 2", "spell_3": "Spell slot 3",
	"spell_4": "Spell slot 4", "spell_q": "Spell slot Q", "spell_e": "Spell slot E",
	"spell_5": "Spell slot 5", "spell_6": "Spell slot 6",
	"quickslot_1": "Quick slot 1", "quickslot_2": "Quick slot 2",
	"quickslot_3": "Quick slot 3", "quickslot_4": "Quick slot 4",
}
const QUALITY_NAMES := {"low": "Low", "medium": "Medium", "high": "High"}
# i18n-end

## `panel` is the window card (kept under this name for the layout reports).
var panel: Control = null
var _window: HudWindow = null
var _pages: Dictionary = {}
var _tab_buttons: Dictionary = {}
var _sliders: Dictionary = {}
var _value_labels: Dictionary = {}
var _bind_buttons: Dictionary = {}
var _graphics: OptionButton = null
var _status: Label = null
var _listening_action := ""
var _built := false

## Evidence counters.
var opens: int = 0
var rebinds_applied: int = 0
var settings_written: int = 0

func open() -> void:
	_build()
	_window.open()
	opens += 1
	UIFocus.block(self)
	_refresh_all()

func close() -> void:
	if _window != null:
		_window.close()
	_listening_action = ""
	UIFocus.unblock(self)

func is_open() -> bool:
	return _window != null and _window.visible

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
	_window = HudWindow.new("Settings", WINDOW_SIZE)
	_window.modal = true   # key rebinding takes the keyboard
	_window.closed.connect(func():
		_listening_action = ""
		UIFocus.unblock(self))
	add_child(_window)
	panel = _window.card
	panel.name = "SettingsPanel"

	var tabs := HBoxContainer.new()
	tabs.add_theme_constant_override("separation", 6)
	_window.body.add_child(tabs)
	var pages := MarginContainer.new()
	pages.size_flags_vertical = Control.SIZE_EXPAND_FILL
	_window.body.add_child(pages)
	for spec in [["graphics", tr("General")], ["audio", tr("Audio")], ["controls", tr("Controls")],
			["credits", tr("Credits")]]:
		var key := String(spec[0])
		var b := HudKit.button(String(spec[1]), 15)
		b.toggle_mode = true
		b.custom_minimum_size = Vector2(130, 34)
		b.pressed.connect(_show_page.bind(key))
		tabs.add_child(b)
		_tab_buttons[key] = b
		var page := VBoxContainer.new()
		page.add_theme_constant_override("separation", 12)
		page.size_flags_vertical = Control.SIZE_EXPAND_FILL
		pages.add_child(page)
		_pages[key] = page

	# --- graphics & interface ---
	var g: VBoxContainer = _pages["graphics"]
	g.add_child(_section(tr("Language")))
	g.add_child(_language_row())
	g.add_child(_section(tr("Display")))
	var row := _row(tr("Graphics quality"))
	_graphics = OptionButton.new()
	_graphics.name = "GraphicsQuality"
	_graphics.focus_mode = Control.FOCUS_NONE
	_graphics.custom_minimum_size = Vector2(280, 32)
	_graphics.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	HudKit.style_button(_graphics, 14)
	for choice in GameSettings.GRAPHICS_CHOICES:
		_graphics.add_item(_graphics_label(choice))
	_graphics.tooltip_text = tr("Auto picks Low on integrated graphics and High on a dedicated GPU")
	_graphics.item_selected.connect(_on_graphics_selected)
	row.add_child(_graphics)
	g.add_child(row)
	var tod_row := _row(tr("Time of day"))
	var tod := OptionButton.new()
	tod.name = "TimeOfDay"
	tod.focus_mode = Control.FOCUS_NONE
	tod.custom_minimum_size = Vector2(280, 32)
	tod.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	HudKit.style_button(tod, 14)
	for choice in GameSettings.TIME_OF_DAY_CHOICES:
		tod.add_item(tr(String(DayNight.CHOICES[choice])))
		if choice == GameSettings.instance().time_of_day:
			tod.select(tod.item_count - 1)
	tod.tooltip_text = tr("Server time follows the clock in GMT+3: day, dusk and night on the grounds")
	tod.item_selected.connect(func(index: int):
		GameSettings.instance().set_time_of_day(GameSettings.TIME_OF_DAY_CHOICES[index])
		settings_written += 1)
	tod_row.add_child(tod)
	g.add_child(tod_row)
	g.add_child(_slider_row("ui_scale", tr("Interface scale"), GameSettings.UI_SCALE_MIN, GameSettings.UI_SCALE_MAX, 0.05))
	g.add_child(_section(tr("Camera & effects")))
	g.add_child(_slider_row("mouse_sensitivity", tr("Mouse sensitivity"), GameSettings.SENSITIVITY_MIN, GameSettings.SENSITIVITY_MAX, 0.05))
	g.add_child(_slider_row("shake", tr("Screen shake"), GameSettings.INTENSITY_MIN, GameSettings.INTENSITY_MAX, 0.05))
	g.add_child(_slider_row("flash", tr("Screen flash"), GameSettings.INTENSITY_MIN, GameSettings.INTENSITY_MAX, 0.05))

	# --- audio ---
	var a: VBoxContainer = _pages["audio"]
	a.add_child(_section(tr("Volume")))
	for bus_name in GameSettings.BUSES:
		a.add_child(_slider_row("vol_%s" % bus_name, "%s" % _bus_title(String(bus_name)), 0.0, 1.0, 0.05, "audio_%s" % String(bus_name).to_lower()))

	# --- controls ---
	var c: VBoxContainer = _pages["controls"]
	var head := HBoxContainer.new()
	var caption := _section(tr("Key bindings"))
	caption.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	head.add_child(caption)
	var reset := HudKit.button(tr("Reset keys"), 14)
	reset.pressed.connect(_on_reset_pressed)
	head.add_child(reset)
	c.add_child(head)
	var scroll := ScrollContainer.new()
	scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
	scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	c.add_child(scroll)
	var rows := VBoxContainer.new()
	rows.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	rows.add_theme_constant_override("separation", 4)
	scroll.add_child(rows)
	var index := 0
	for action in GameSettings.BINDABLE_ACTIONS:
		var r := HBoxContainer.new()
		r.custom_minimum_size.y = 34
		var stripe := PanelContainer.new()
		var sb := StyleBoxFlat.new()
		sb.bg_color = Color(1, 1, 1, 0.035 if index % 2 == 0 else 0.0)
		sb.set_corner_radius_all(4)
		sb.content_margin_left = 10
		sb.content_margin_right = 6
		stripe.add_theme_stylebox_override("panel", sb)
		stripe.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		stripe.add_child(r)
		var name_label := HudKit.label(_action_name(action), 15, HudKit.TEXT, HudKit.body(), 0)
		name_label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		name_label.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
		r.add_child(name_label)
		var button := HudKit.button("", 14)
		button.custom_minimum_size = Vector2(150, 30)
		button.pressed.connect(_on_bind_pressed.bind(action))
		r.add_child(button)
		rows.add_child(stripe)
		_bind_buttons[action] = button
		index += 1

	# --- credits ---
	(_pages["credits"] as VBoxContainer).add_child(GameCredits.build())

	# --- footer ---
	var footer := HBoxContainer.new()
	_window.body.add_child(footer)
	_status = HudKit.label("", 14, HudKit.GOLD_LT, HudKit.body(), 2)
	_status.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_status.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	footer.add_child(_status)
	var close_button := HudKit.button(tr("Close"), 15)
	close_button.custom_minimum_size = Vector2(120, 34)
	close_button.tooltip_text = tr("Close the settings (Esc)")
	close_button.pressed.connect(_on_close_pressed)
	footer.add_child(close_button)
	_show_page("graphics")

## The language picker. Labels built from now on use the new language at once;
## what is already on screen switches when the HUD is built again, so the row
## offers the character screen (the usual leave countdown applies).
func _language_row() -> VBoxContainer:
	var box := VBoxContainer.new()
	box.add_theme_constant_override("separation", 6)
	var row := _row(tr("Game language"))
	var picker := OptionButton.new()
	picker.name = "LanguagePicker"
	picker.focus_mode = Control.FOCUS_NONE
	picker.auto_translate_mode = Node.AUTO_TRANSLATE_MODE_DISABLED
	picker.custom_minimum_size = Vector2(280, 32)
	picker.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	HudKit.style_button(picker, 14)
	var languages: Array = I18n.languages()
	for i in languages.size():
		picker.add_item(String(languages[i].name), i)
		picker.set_item_metadata(i, String(languages[i].code))
		if String(languages[i].code) == I18n.current:
			picker.select(i)
	row.add_child(picker)
	box.add_child(row)
	var apply_row := HBoxContainer.new()
	apply_row.add_theme_constant_override("separation", 10)
	apply_row.visible = false
	var note := HudKit.label(tr("Open windows switch language when the interface is rebuilt."), 13, HudKit.TEXT_DIM, HudKit.body(), 0)
	note.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	note.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	apply_row.add_child(note)
	var apply := HudKit.button(tr("Change character now"), 13)
	apply.custom_minimum_size = Vector2(190, 30)
	apply.pressed.connect(func():
		close()
		language_apply_requested.emit())
	apply_row.add_child(apply)
	box.add_child(apply_row)
	picker.item_selected.connect(func(index: int):
		var code := String(picker.get_item_metadata(index))
		if code == I18n.current:
			return
		I18n.set_language(code)
		settings_written += 1
		apply_row.visible = true
		note.text = tr("Open windows switch language when the interface is rebuilt.")
		apply.text = tr("Change character now")
		_status.text = tr("Language: %s") % I18n.native_name(code))
	return box

func _show_page(key: String) -> void:
	for k in _pages:
		(_pages[k] as Control).visible = k == key
		(_tab_buttons[k] as Button).set_pressed_no_signal(k == key)

func _section(text: String) -> Label:
	var l := HudKit.label(I18n.upper(text), 14, HudKit.GOLD, HudKit.title(), 2)
	return l

func _row(title: String, icon_id: String = "") -> HBoxContainer:
	var r := HBoxContainer.new()
	r.add_theme_constant_override("separation", 12)
	r.custom_minimum_size.y = 32
	if icon_id != "":
		r.add_child(UITheme.icon_rect(icon_id, 20.0))
	var l := HudKit.label(title, 15, HudKit.TEXT, HudKit.body(), 0)
	l.custom_minimum_size.x = 190 if icon_id == "" else 158
	l.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	r.add_child(l)
	return r

func _slider_row(key: String, title: String, minimum: float, maximum: float, step: float, icon_id: String = "") -> HBoxContainer:
	var r := _row(title, icon_id)
	var slider := HSlider.new()
	slider.min_value = minimum
	slider.max_value = maximum
	slider.step = step
	slider.focus_mode = Control.FOCUS_NONE
	slider.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	slider.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	var track := StyleBoxFlat.new()
	track.bg_color = Color(0.02, 0.025, 0.04)
	track.border_color = Color(0, 0, 0)
	track.set_border_width_all(1)
	track.set_corner_radius_all(3)
	track.content_margin_top = 3
	track.content_margin_bottom = 3
	var fill := StyleBoxFlat.new()
	fill.bg_color = HudKit.GOLD
	fill.set_corner_radius_all(3)
	fill.content_margin_top = 3
	fill.content_margin_bottom = 3
	slider.add_theme_stylebox_override("slider", track)
	slider.add_theme_stylebox_override("grabber_area", fill)
	slider.add_theme_stylebox_override("grabber_area_highlight", fill)
	if key == "ui_scale":
		# Rescaling the interface while the knob is held moves the slider under
		# the cursor and the drag fights itself (the windows flickered). While
		# dragging only the number updates; the scale applies on release.
		slider.drag_started.connect(func(): _scale_dragging = true)
		slider.drag_ended.connect(func(_changed: bool):
			_scale_dragging = false
			_on_slider_changed(slider.value, key))
	slider.value_changed.connect(_on_slider_changed.bind(key))
	r.add_child(slider)
	var value_label := HudKit.label("", 14, HudKit.GOLD_HI, HudKit.bold(), 0)
	value_label.custom_minimum_size.x = 58
	value_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
	value_label.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	r.add_child(value_label)
	_sliders[key] = slider
	_value_labels[key] = value_label
	return r

static func _bus_title(bus: String) -> String:
	match bus:
		"SFX":
			return I18n.t("Effects")
		"UI":
			return I18n.t("Interface")
		"Music":
			return I18n.t("Music")
		"Ambience":
			return I18n.t("Ambience")
	return bus

## ---------------------------------------------------------------- controls

var _scale_dragging := false

func _on_slider_changed(value: float, key: String) -> void:
	var settings := GameSettings.instance()
	if key == "ui_scale" and _scale_dragging:
		(_value_labels[key] as Label).text = "%.2f" % value
		return
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

func _graphics_label(choice: String) -> String:
	if choice == "auto":
		return tr("Auto (%s)") % _quality_name(QualityPreset.detect())
	return _quality_name(choice)

func _quality_name(preset: String) -> String:
	return tr(String(QUALITY_NAMES.get(preset, preset.capitalize())))

func _action_name(action: String) -> String:
	return tr(String(ACTION_NAMES.get(action, String(action).replace("_", " ").capitalize())))

func _on_graphics_selected(index: int) -> void:
	var choice: String = GameSettings.GRAPHICS_CHOICES[index]
	var terrain := GroundsTerrain.active()
	var world: Node3D = terrain.get_parent() as Node3D if terrain != null else get_tree().current_scene as Node3D
	QualityPreset.choose(choice, world)
	settings_written += 1
	_status.text = tr("Graphics: %s") % _quality_name(QualityPreset.current())
	_refresh_all()

func _refresh_all() -> void:
	var settings := GameSettings.instance()
	if _graphics != null:
		_graphics.select(maxi(0, GameSettings.GRAPHICS_CHOICES.find(settings.graphics_quality)))
	for key in _sliders:
		var slider: HSlider = _sliders[key]
		slider.set_value_no_signal(_setting_value(settings, key))
		(_value_labels[key] as Label).text = _format_value(key, _setting_value(settings, key))
	for action in _bind_buttons:
		var button: Button = _bind_buttons[action]
		if action == _listening_action:
			button.text = tr("press a key…")
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
	_status.text = tr("Press a key for '%s' (Esc cancels)") % _action_name(action)
	_refresh_all()

func _on_close_pressed() -> void:
	close()

func _on_reset_pressed() -> void:
	GameSettings.instance().reset_bindings()
	_listening_action = ""
	_status.text = tr("Key bindings reset to defaults.")
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
		_status.text = tr("Rebinding cancelled.")
		_refresh_all()
		return
	var error := GameSettings.instance().set_binding(action, key_event.physical_keycode)
	_listening_action = ""
	if error == "":
		rebinds_applied += 1
		_status.text = tr("'%s' is now %s.") % [_action_name(action), OS.get_keycode_string(key_event.physical_keycode)]
	elif error.begins_with("already bound to "):
		_status.text = tr("Refused: that key already drives '%s'.") % _action_name(error.trim_prefix("already bound to "))
	else:
		_status.text = tr("Refused: %s.") % tr(error)
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
