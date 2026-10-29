extends PanelContainer
class_name LookEditor

## The appearance panel of the character screen, two tabs: the look (outfit,
## hairstyle, beard, brows, hair / eye / skin colour swatches, height) and the
## face (face type and the face sliders) (HPRules.LOOK_*). Every change
## emits `look_changed` so the podium wizard is redrawn live
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
	"nose_bridge": "Nose Bridge", "lips": "Lips", "brow_ridge": "Brow Ridge"}
const FACE_NAMES := {"default": "Classic Face", "oval": "Oval Face", "round": "Round Face", "square": "Square Face",
	"triangular": "Triangular Face", "diamond": "Diamond Face"}
# i18n-end

var look: Dictionary = HPRules.default_look()
var _hair_label: Label
var _outfit_label: Label
var _beard_label: Label
var _brows_label: Label
var _face_label: Label
var _tabs := {}              # tab name -> [Button, VBoxContainer]
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
	face.add_theme_constant_override("separation", 8)
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

	face.add_child(_caption(tr("Face type")))
	_face_label = _stepper(face, "face", HPRules.LOOK_FACES.size())
	for key: String in HPRules.LOOK_SLIDERS:
		var span: Array = HPRules.LOOK_SLIDERS[key]
		var row := HBoxContainer.new()
		var name_label := _caption(tr(SLIDER_NAMES[key]))
		name_label.custom_minimum_size = Vector2(118, 0)
		row.add_child(name_label)
		var slider := HSlider.new()
		slider.min_value = float(span[0])
		slider.max_value = float(span[1])
		slider.step = 0.05
		slider.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		slider.custom_minimum_size = Vector2(150, 22)
		var slider_key := key
		slider.value_changed.connect(func(v: float): _set_value(slider_key, v))
		row.add_child(slider)
		_sliders[key] = slider
		# height is the body: it stays on the look tab
		(general if key == "height" else face).add_child(row)
	_show_tab("look")

	var tools := HBoxContainer.new()
	tools.alignment = BoxContainer.ALIGNMENT_CENTER
	var random := _small_button(tr("Random"))
	random.pressed.connect(randomize_look)
	var reset := _small_button(tr("Reset"))
	reset.pressed.connect(func(): set_look(HPRules.default_look(), true))
	tools.add_child(random)
	tools.add_child(reset)
	box.add_child(tools)

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
	_quiet = false
	if notify:
		look_changed.emit(look.duplicate())


func _show_tab(tab_name: String) -> void:
	for name: String in _tabs:
		var on := name == tab_name
		(_tabs[name][1] as Control).visible = on
		(_tabs[name][0] as Button).modulate = Color.WHITE if on else Color(1, 1, 1, 0.55)
	tab_changed.emit(tab_name)


## The Save / Cancel row belongs to editing an existing wizard.
func set_edit_buttons(on: bool) -> void:
	_buttons.visible = on


func randomize_look() -> void:
	var l := HPRules.default_look()
	l["hair"] = randi() % HPRules.LOOK_HAIR_STYLES.size()
	l["hair_color"] = randi() % HPRules.LOOK_HAIR_COLORS.size()
	l["eyes"] = randi() % HPRules.LOOK_EYE_COLORS.size()
	l["skin"] = randi() % HPRules.LOOK_SKIN_TONES.size()
	l["outfit"] = randi() % HPRules.LOOK_OUTFITS.size()
	l["beard"] = randi() % HPRules.LOOK_BEARDS.size()
	l["brows"] = randi() % HPRules.LOOK_BROWS.size()
	l["face"] = randi() % HPRules.LOOK_FACES.size()
	for key: String in HPRules.LOOK_SLIDERS:
		var span: Array = HPRules.LOOK_SLIDERS[key]
		l[key] = randf_range(float(span[0]), float(span[1])) * 0.8
	set_look(l, true)


func _set_value(key: String, value) -> void:
	if _quiet:
		return
	var l := look.duplicate()
	l[key] = value
	set_look(l, true)


## A "< name >" row that steps `key` through `count` choices; returns the name label.
func _stepper(box: VBoxContainer, key: String, count: int) -> Label:
	var row := HBoxContainer.new()
	row.alignment = BoxContainer.ALIGNMENT_CENTER
	var prev := _small_button("<")
	prev.pressed.connect(func(): _set_value(key, (int(look[key]) - 1 + count) % count))
	var label := Label.new()
	label.custom_minimum_size = Vector2(150, 0)
	label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	HudKit.style_label(label, 16, HudKit.PARCHMENT, HudKit.bold(), 2)
	var next := _small_button(">")
	next.pressed.connect(func(): _set_value(key, (int(look[key]) + 1) % count))
	row.add_child(prev)
	row.add_child(label)
	row.add_child(next)
	box.add_child(row)
	return label


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
	b.custom_minimum_size = Vector2(maxf(36.0, 14.0 * text.length() + 20.0), 32)
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
