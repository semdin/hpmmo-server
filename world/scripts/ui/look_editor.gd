extends PanelContainer
class_name LookEditor

## The appearance panel of the character screen, two tabs: the look (outfit,
## hairstyle, beard, brows, hair / eye / skin colour swatches, height) and the
## face (a preset face, the face type and the face sliders in five parts -
## shape, eyes, nose, mouth, ears - one part's sliders at a time, so the panel
## keeps its height; plans/ui/face-tab.html) (HPRules.LOOK_*). A preset face
## sets every face slider at once; moving one after makes the face "Custom".
## Every change emits `look_changed` so the podium wizard is redrawn live
## (HeroAppearance.apply_look); `confirmed` / `cancelled` close an edit of an
## existing wizard (the create card has its own buttons).

signal look_changed(look: Dictionary)
signal confirmed(look: Dictionary)
signal cancelled
## "look" or "face": the character screen frames the face for the face tab
signal tab_changed(tab_name: String)

# i18n-begin
const HAIR_NAMES := {"SimpleParted": "Side Part", "Buzzed": "Buzzed", "Long": "Long", "Wavy": "Wavy",
	"Tousled": "Tousled", "Neat": "Neat Comb", "Ponytail": "Ponytail", "Curly": "Curly", "none": "Shaved"}
const BEARD_NAMES := {"none": "Clean-shaven", "stubble": "Stubble", "short": "Short Beard", "full": "Full Beard"}
const BROW_NAMES := {"natural": "Natural Brows", "bushy": "Bushy Brows", "arched": "Arched Brows",
	"thin": "Thin Brows", "angular": "Sharp Brows", "classic": "Classic Brows", "classic_straight": "Classic Straight Brows"}
const OUTFIT_NAMES := {"peasant": "Tunic", "peasant_2": "Travel Tunic", "ranger": "Ranger", "ranger_3": "Scout"}
const SLIDER_NAMES := {"height": "Height", "jaw": "Jaw", "chin": "Chin", "chin_height": "Chin Length",
	"cheekbones": "Cheekbones", "cheeks": "Cheeks", "nose_length": "Nose Length", "nose_width": "Nose Width",
	"nose_bridge": "Nose Bridge", "lips": "Lips", "brow_ridge": "Brow Ridge", "eye_size": "Eye Size",
	"eye_spacing": "Eye Spacing", "eye_height": "Eye Height", "eye_tilt": "Eye Tilt", "eyelids": "Eyelids",
	"eye_bags": "Under-Eyes", "nose_tip": "Nose Tip", "nostrils": "Nostrils", "nose_curve": "Nose Curve",
	"mouth_width": "Mouth Width", "mouth_corners": "Mouth Corners", "jaw_angle": "Jaw Angle", "age": "Age",
	"ear_size": "Ear Size", "ear_out": "Ear Angle"}
const FACE_NAMES := {"default": "Classic Face", "oval": "Oval Face", "round": "Round Face", "square": "Square Face",
	"triangular": "Triangular Face", "diamond": "Diamond Face"}
## the face tab's parts: [name, slider keys]
const FACE_PARTS := [
	["Shape", ["jaw", "jaw_angle", "chin", "chin_height", "cheekbones", "cheeks", "age"]],
	["Eyes", ["eye_size", "eye_spacing", "eye_height", "eye_tilt", "eyelids", "eye_bags", "brow_ridge"]],
	["Nose", ["nose_length", "nose_width", "nose_bridge", "nose_tip", "nostrils", "nose_curve"]],
	["Mouth", ["lips", "mouth_width", "mouth_corners"]],
	["Ears", ["ear_size", "ear_out"]],
]
## Preset faces: [name, face type (HPRules.LOOK_FACES index), sliders]. A
## character each, tuned on renders (tools/downloads/_preset_sheet.tscn);
## Random starts from one and wanders off it.
const PRESET_FACES := [
	["Classic", 0, {}],
	["Noble", 1, {"nose_length": 0.4, "nose_bridge": 0.5, "cheekbones": 0.5, "eye_tilt": 0.3, "lips": -0.3, "jaw": -0.2}],
	["Stern", 3, {"jaw": 0.2, "jaw_angle": 0.4, "brow_ridge": 0.7, "eyelids": 0.7, "mouth_corners": -0.6, "nose_width": 0.3, "eye_size": -0.3}],
	["Youthful", 2, {"age": -0.9, "eye_size": 0.5, "cheeks": 0.3, "nose_length": -0.4, "chin": -0.2, "jaw": -0.3}],
	["Sage", 1, {"age": 1.0, "eye_bags": 0.8, "cheeks": -0.6, "nose_length": 0.5, "mouth_corners": -0.4, "eyelids": 0.4}],
	["Sharp", 5, {"cheekbones": 0.8, "cheeks": -0.7, "nose_tip": 0.4, "eye_tilt": 0.6, "jaw_angle": 0.4, "chin": 0.3}],
	["Gentle", 2, {"cheeks": 0.5, "jaw": -0.5, "nose_curve": -0.5, "lips": 0.6, "eye_size": 0.4, "mouth_corners": 0.4}],
	["Warrior", 0, {"jaw": 0.5, "jaw_angle": 0.6, "nose_bridge": 0.8, "nostrils": 0.5, "brow_ridge": 0.8, "eye_spacing": -0.3, "ear_out": 0.3}],
	["Cunning", 1, {"eye_tilt": 0.8, "eyelids": 0.5, "chin": 0.5, "nose_tip": 0.5, "mouth_width": -0.4, "cheeks": -0.4, "eye_spacing": 0.3}],
	["Highlander", 0, {"jaw_angle": 0.6, "nose_width": 0.6, "nostrils": 0.6, "eye_bags": 0.5, "ear_size": 0.5, "brow_ridge": 0.4, "age": 0.4}],
]
# i18n-end
## how far Random wanders off its preset face, per slider
const RANDOM_SPREAD := 0.45

var look: Dictionary = HPRules.default_look()
var _hair_label: Label
var _outfit_label: Label
var _beard_label: Label
var _brows_label: Label
var _face_label: Label
var _preset_label: Label
var _preset_note: Label
var _preset := 0
var _tabs := {}              # tab name -> [Button, VBoxContainer]
var _parts: Array = []       # per FACE_PARTS: [TabChip, dot Label, VBoxContainer]
var _part := 0
var _swatches := {}          # look key -> Array[Button]
var _sliders := {}           # look key -> HSlider
var _buttons: HBoxContainer
var _quiet := false


func _init() -> void:
	add_theme_stylebox_override("panel", HudKit.window())
	var margin := MarginContainer.new()
	for side in ["left", "right", "top", "bottom"]:
		margin.add_theme_constant_override("margin_" + side, 16)
	add_child(margin)
	var box := VBoxContainer.new()
	box.add_theme_constant_override("separation", 8)
	margin.add_child(box)
	var title := Label.new()
	title.text = tr("APPEARANCE")
	HudKit.style_label(title, 22, HudKit.GOLD_HI, HudKit.deco(), 4)
	title.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	box.add_child(title)

	var tab_row := HBoxContainer.new()
	tab_row.alignment = BoxContainer.ALIGNMENT_CENTER
	box.add_child(tab_row)
	var general := VBoxContainer.new()
	general.add_theme_constant_override("separation", 8)
	box.add_child(general)
	var face := VBoxContainer.new()
	face.add_theme_constant_override("separation", 6)
	box.add_child(face)
	for entry in [["look", tr("Look"), general], ["face", tr("Face"), face]]:
		var tab := _small_button(entry[1])
		var tab_name: String = entry[0]
		tab.pressed.connect(func(): _show_tab(tab_name))
		tab_row.add_child(tab)
		_tabs[tab_name] = [tab, entry[2]]

	general.add_child(_caption(tr("Outfit")))
	_outfit_label = _stepper(general, "outfit", HPRules.LOOK_OUTFITS.size())
	general.add_child(_caption(tr("Hairstyle")))
	_hair_label = _stepper(general, "hair", HPRules.LOOK_HAIR_STYLES.size())
	general.add_child(_caption(tr("Facial hair")))
	_beard_label = _stepper(general, "beard", HPRules.LOOK_BEARDS.size())
	_brows_label = _stepper(general, "brows", HPRules.LOOK_BROWS.size())

	for entry in [["hair_color", tr("Hair colour"), HPRules.LOOK_HAIR_COLORS],
			["eyes", tr("Eye colour"), HPRules.LOOK_EYE_COLORS],
			["skin", tr("Skin tone"), HPRules.LOOK_SKIN_TONES]]:
		general.add_child(_caption(entry[1]))
		var row := HFlowContainer.new()
		row.add_theme_constant_override("h_separation", 6)
		row.add_theme_constant_override("v_separation", 6)
		var buttons: Array = []
		for i in range((entry[2] as Array).size()):
			var b := _swatch(Color.html(entry[2][i]))
			var key: String = entry[0]
			var index := i
			b.pressed.connect(func(): _set_value(key, index))
			row.add_child(b)
			buttons.append(b)
		_swatches[entry[0]] = buttons
		general.add_child(row)
	general.add_child(_slider_row("height"))

	# --- face: preset, type, then one part's sliders
	face.add_child(_caption(tr("Preset face")))
	_preset_label = _step_row(face, func(step: int): apply_preset((_preset + step + PRESET_FACES.size()) % PRESET_FACES.size()))
	_preset_note = Label.new()
	HudKit.style_label(_preset_note, 12, HudKit.TEXT_DIM, HudKit.body(), 1)
	_preset_note.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	face.add_child(_preset_note)
	face.add_child(_caption(tr("Face type")))
	_face_label = _stepper(face, "face", HPRules.LOOK_FACES.size())
	var chips := HBoxContainer.new()
	chips.add_theme_constant_override("separation", 2)
	face.add_child(chips)
	var rule := ColorRect.new()
	rule.color = HudKit.GOLD_DK
	rule.custom_minimum_size = Vector2(0, 1)
	face.add_child(rule)
	# the tallest part's height, so switching parts does not move the buttons
	var tallest := 0
	for part in FACE_PARTS:
		tallest = maxi(tallest, (part[1] as Array).size())
	var holder := Control.new()
	holder.custom_minimum_size = Vector2(0, tallest * 32)
	face.add_child(holder)
	for i in FACE_PARTS.size():
		var chip := PartChip.new(tr(FACE_PARTS[i][0]))
		chip.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		var index := i
		chip.chosen.connect(func(): _show_part(index))
		chips.add_child(chip)
		var rows := VBoxContainer.new()
		rows.add_theme_constant_override("separation", 0)
		rows.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
		for key: String in FACE_PARTS[i][1]:
			rows.add_child(_slider_row(key))
		holder.add_child(rows)
		_parts.append([chip, chip.dot, rows])
	_show_part(0)
	_show_tab("look")

	var tools := HBoxContainer.new()
	tools.alignment = BoxContainer.ALIGNMENT_CENTER
	var random := _small_button(tr("Random"))
	random.pressed.connect(randomize_look)
	var reset_part := _small_button(tr("Reset Section"))
	reset_part.pressed.connect(_reset_part)
	var reset := _small_button(tr("Reset"))
	reset.pressed.connect(func(): set_look(HPRules.default_look(), true))
	tools.add_child(random)
	tools.add_child(reset_part)
	tools.add_child(reset)
	box.add_child(tools)
	# "Reset Section" belongs to the face tab
	_tabs["face"].append(reset_part)
	reset_part.visible = false

	_buttons = HBoxContainer.new()
	_buttons.alignment = BoxContainer.ALIGNMENT_CENTER
	var save := _small_button(tr("Save"))
	save.pressed.connect(func(): confirmed.emit(look.duplicate()))
	var cancel := _small_button(tr("Cancel"))
	cancel.pressed.connect(func(): cancelled.emit())
	_buttons.add_child(save)
	_buttons.add_child(cancel)
	box.add_child(_buttons)
	set_look(look)


## Show `value` in the controls; `notify` also redraws the podium.
func set_look(value: Dictionary, notify := false) -> void:
	look = HPRules.clean_look(value)
	_quiet = true
	_hair_label.text = tr(HAIR_NAMES.get(HPRules.LOOK_HAIR_STYLES[int(look["hair"])], "Hair"))
	_outfit_label.text = tr(OUTFIT_NAMES.get(HPRules.LOOK_OUTFITS[int(look["outfit"])], "Outfit"))
	_beard_label.text = tr(BEARD_NAMES.get(HPRules.LOOK_BEARDS[int(look["beard"])], "Beard"))
	_brows_label.text = tr(BROW_NAMES.get(HPRules.LOOK_BROWS[int(look["brows"])], "Brows"))
	_face_label.text = tr(FACE_NAMES.get(HPRules.LOOK_FACES[int(look["face"])], "Face"))
	for key in _swatches:
		var buttons: Array = _swatches[key]
		for i in range(buttons.size()):
			_mark(buttons[i], i == int(look[key]))
	for key in _sliders:
		(_sliders[key] as HSlider).value = float(look[key])
	for part in _parts.size():
		(_parts[part][1] as Label).visible = (FACE_PARTS[part][1] as Array).any(
			func(k): return not is_zero_approx(float(look[k])))
	var matched := _matching_preset()
	if matched >= 0:
		_preset = matched
	_preset_label.text = tr(PRESET_FACES[_preset][0]) if matched >= 0 else tr("Custom")
	_preset_note.text = "" if matched >= 0 else tr("Changed from %s") % tr(PRESET_FACES[_preset][0])
	_quiet = false
	if notify:
		look_changed.emit(look.duplicate())


## Every face slider and the face type from preset face `index`.
func apply_preset(index: int) -> void:
	_preset = index
	set_look(_with_face(look, index, 0.0), true)


func _show_tab(tab_name: String) -> void:
	for name: String in _tabs:
		var on := name == tab_name
		(_tabs[name][1] as Control).visible = on
		(_tabs[name][0] as Button).modulate = Color.WHITE if on else Color(1, 1, 1, 0.55)
		for extra in (_tabs[name] as Array).slice(2):
			(extra as Control).visible = on
	tab_changed.emit(tab_name)


func _show_part(index: int) -> void:
	_part = index
	for i in _parts.size():
		(_parts[i][0] as PartChip).selected = i == index
		(_parts[i][2] as Control).visible = i == index


func _reset_part() -> void:
	var l := look.duplicate()
	for key: String in FACE_PARTS[_part][1]:
		l[key] = 0.0
	set_look(l, true)


## The Save / Cancel row belongs to editing an existing wizard.
func set_edit_buttons(on: bool) -> void:
	_buttons.visible = on


## A whole new wizard: hair, colours, outfit; a preset face and every face
## slider wandered off it (RANDOM_SPREAD), so random faces differ but stay a
## face someone made.
func randomize_look() -> void:
	var l := HPRules.default_look()
	l["hair"] = randi() % HPRules.LOOK_HAIR_STYLES.size()
	l["hair_color"] = randi() % HPRules.LOOK_HAIR_COLORS.size()
	l["eyes"] = randi() % HPRules.LOOK_EYE_COLORS.size()
	l["skin"] = randi() % HPRules.LOOK_SKIN_TONES.size()
	l["outfit"] = randi() % HPRules.LOOK_OUTFITS.size()
	l["beard"] = randi() % HPRules.LOOK_BEARDS.size()
	l["brows"] = randi() % HPRules.LOOK_BROWS.size()
	l["height"] = randf_range(-0.8, 0.8)
	_preset = randi() % PRESET_FACES.size()
	set_look(_with_face(l, _preset, RANDOM_SPREAD), true)


## `base` with preset face `index` (its type and sliders, the rest at 0),
## each face slider moved by up to +-`spread`.
static func _with_face(base: Dictionary, index: int, spread: float) -> Dictionary:
	var l := base.duplicate()
	var preset: Array = PRESET_FACES[index]
	l["face"] = int(preset[1])
	for part in FACE_PARTS:
		for key: String in part[1]:
			var v := float((preset[2] as Dictionary).get(key, 0.0))
			l[key] = clampf(v + randf_range(-spread, spread), -1.0, 1.0) if spread > 0.0 else v
	return l


## The preset face the look's face is, or -1 (custom).
func _matching_preset() -> int:
	for i in PRESET_FACES.size():
		if int(look["face"]) != int(PRESET_FACES[i][1]):
			continue
		var same := true
		for part in FACE_PARTS:
			for key: String in part[1]:
				if absf(float(look[key]) - float((PRESET_FACES[i][2] as Dictionary).get(key, 0.0))) > 0.011:
					same = false
		if same:
			return i
	return -1


func _set_value(key: String, value) -> void:
	if _quiet:
		return
	var l := look.duplicate()
	l[key] = value
	set_look(l, true)


## A "< name >" row that steps `key` through `count` choices; returns the name label.
func _stepper(box: VBoxContainer, key: String, count: int) -> Label:
	return _step_row(box, func(step: int): _set_value(key, (int(look[key]) + step + count) % count))


## A "< name >" row calling `on_step` with -1 / +1; returns the name label.
func _step_row(box: VBoxContainer, on_step: Callable) -> Label:
	var row := HBoxContainer.new()
	row.alignment = BoxContainer.ALIGNMENT_CENTER
	var prev := _small_button("<")
	prev.pressed.connect(func(): on_step.call(-1))
	var label := Label.new()
	label.custom_minimum_size = Vector2(150, 0)
	label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	HudKit.style_label(label, 16, HudKit.PARCHMENT, HudKit.bold(), 2)
	var next := _small_button(">")
	next.pressed.connect(func(): on_step.call(1))
	row.add_child(prev)
	row.add_child(label)
	row.add_child(next)
	box.add_child(row)
	return label


## A "name ----o----" row for slider `key` (HPRules.LOOK_SLIDERS).
func _slider_row(key: String) -> HBoxContainer:
	var span: Array = HPRules.LOOK_SLIDERS[key]
	var row := HBoxContainer.new()
	row.custom_minimum_size = Vector2(0, 32)
	var name_label := _caption(tr(SLIDER_NAMES[key]))
	name_label.custom_minimum_size = Vector2(128, 0)
	row.add_child(name_label)
	var slider := HSlider.new()
	slider.min_value = float(span[0])
	slider.max_value = float(span[1])
	slider.step = 0.05
	slider.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	slider.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	slider.custom_minimum_size = Vector2(150, 22)
	slider.value_changed.connect(func(v: float): _set_value(key, v))
	row.add_child(slider)
	_sliders[key] = slider
	return row


func _caption(text: String) -> Label:
	var l := Label.new()
	l.text = text
	HudKit.style_label(l, 14, HudKit.TEXT, HudKit.body(), 1)
	return l


func _small_button(text: String) -> Button:
	var b := Button.new()
	b.text = text
	b.focus_mode = Control.FOCUS_NONE
	HudKit.style_button(b, 14)
	var font := b.get_theme_font("font")
	var width := font.get_string_size(text, HORIZONTAL_ALIGNMENT_LEFT, -1, 14).x + 28.0 if font != null else 14.0 * text.length() + 20.0
	b.custom_minimum_size = Vector2(maxf(36.0, width), 32)
	return b


func _swatch(color: Color) -> Button:
	var b := Button.new()
	b.focus_mode = Control.FOCUS_NONE
	b.custom_minimum_size = Vector2(30, 30)
	b.tooltip_text = "#" + color.to_html(false)
	b.set_meta("color", color)
	_mark(b, false)
	return b


func _mark(b: Button, selected: bool) -> void:
	var color: Color = b.get_meta("color")
	var box := StyleBoxFlat.new()
	box.bg_color = color
	box.set_corner_radius_all(15)
	box.border_color = HudKit.GOLD_HI if selected else Color(0, 0, 0, 0.6)
	box.set_border_width_all(3 if selected else 1)
	for state in ["normal", "hover", "pressed", "focus"]:
		b.add_theme_stylebox_override(state, box)


## A face part's tab (the character window's TabChip, narrower: five fit the
## panel) with a gold dot while any of the part's sliders is moved.
class PartChip extends PanelContainer:
	signal chosen
	var dot: Label
	var _label: Label
	var _hover := false
	var selected := false:
		set(value):
			selected = value
			_restyle()

	func _init(caption: String) -> void:
		mouse_filter = Control.MOUSE_FILTER_STOP
		mouse_default_cursor_shape = Control.CURSOR_POINTING_HAND
		var row := HBoxContainer.new()
		row.alignment = BoxContainer.ALIGNMENT_CENTER
		row.add_theme_constant_override("separation", 3)
		row.mouse_filter = Control.MOUSE_FILTER_IGNORE
		add_child(row)
		_label = HudKit.label(caption, 14, HudKit.TEXT_DIM, HudKit.body(), 0)
		row.add_child(_label)
		dot = HudKit.label("•", 14, HudKit.GOLD_HI, HudKit.body(), 0)
		dot.visible = false
		row.add_child(dot)
		mouse_entered.connect(func(): _hover = true; _restyle())
		mouse_exited.connect(func(): _hover = false; _restyle())
		_restyle()

	func _gui_input(event: InputEvent) -> void:
		if event is InputEventMouseButton and event.pressed and event.button_index == MOUSE_BUTTON_LEFT:
			chosen.emit()
			accept_event()

	func _restyle() -> void:
		var sb := StyleBoxFlat.new()
		sb.bg_color = Color("1d2f4a") if selected else Color(0, 0, 0, 0)
		sb.border_color = HudKit.GOLD_DK if selected else Color(0, 0, 0, 0)
		sb.set_border_width_all(1)
		sb.border_width_bottom = 0
		sb.corner_radius_top_left = 5
		sb.corner_radius_top_right = 5
		sb.content_margin_left = 6
		sb.content_margin_right = 6
		sb.content_margin_top = 5
		sb.content_margin_bottom = 6
		add_theme_stylebox_override("panel", sb)
		_label.add_theme_color_override("font_color", HudKit.GOLD_HI if selected else (HudKit.PARCHMENT if _hover else HudKit.TEXT_DIM))
