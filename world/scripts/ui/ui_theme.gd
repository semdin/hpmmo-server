extends RefCounted
class_name UITheme

## The single styling entry point for every HPMMO interface surface.
##
## The base theme supplies stable flat styles for existing screens. ArcaneSkin
## adds opt-in textured roles with coordinated nine-slice margins, shadows and
## matching button-state geometry for the HUD and inventory.
## Layout and gameplay feedback remain control-driven; artwork is chrome only.
##
## Text uses Cinzel (headings) and Alegreya Sans (body/UI), both SIL OFL 1.1 with
## the licence vendored beside each face in `assets/fonts/`.

const DIR := "res://assets/ui/"
const ICON_DIR := "res://assets/ui/icons/"
const FONT_DIR := "res://assets/fonts/"
const THEME_PATH := DIR + "hpmmo.tres"

## The heading face ships as one variable file, so a weight is an axis value.
const TITLE_FONT_FILE := "Cinzel-Variable.ttf"
## The body face is not variable, so a requested weight resolves to the nearest
## shipped cut. Each entry is `[highest weight this cut covers, file stem]`.
const BODY_FONT_CUTS := [
	[499, "AlegreyaSans-Regular"],
	[649, "AlegreyaSans-Medium"],
	[1000, "AlegreyaSans-Bold"],
]

## Type-variation names. A widget asks for a role by setting
## `theme_type_variation` to one of these; the styles themselves are in the .tres.
const V_CARD := &"Card"
const V_WINDOW := &"WindowFrame"
const V_TOOLTIP_CARD := &"TooltipCard"
const V_SLOT := &"SlotButton"
const V_ICON_BTN := &"IconButton"
const V_PRIMARY_BTN := &"PrimaryButton"
const V_TITLE := &"TitleLabel"
const V_HP := &"HpBar"
const V_MANA := &"ManaBar"
const V_EXP := &"ExpBar"
const V_BOSS := &"BossBar"

## Every variation, mapped to the built-in type it inherits from. Registered on
## load so a variation that omits an entry (a bar with no font, say) falls back to
## the base type instead of to nothing.
const VARIATION_BASES := {
	V_CARD: &"Panel",
	V_WINDOW: &"Panel",
	V_TOOLTIP_CARD: &"Panel",
	V_SLOT: &"Button",
	V_ICON_BTN: &"Button",
	V_PRIMARY_BTN: &"Button",
	V_TITLE: &"Label",
	V_HP: &"ProgressBar",
	V_MANA: &"ProgressBar",
	V_EXP: &"ProgressBar",
	V_BOSS: &"ProgressBar",
}

## Font sizes, in the 1280x720 canvas the project stretches from. A 1280x720
## canvas is `canvas_items`-stretched, so these land 1.5x larger at 1080p - the
## values are chosen for the 720p pixel grid, where 12 px is the smallest size
## that still resolves a stroke cleanly.
const FS_TINY := 12
const FS_SMALL := 13
const FS_BODY := 15
const FS_LABEL := 16
const FS_HEADER := 18
const FS_TITLE := 24
const FS_BANNER := 36

## Screen-edge grid, in canvas (1280x720) pixels.
##
## The HUD, the overlay and the combat feedback are separate nodes that draw one
## screen between them, so the inset and the column widths live here rather than
## in each of them. Pinning every edge-anchored surface to the same `EDGE` and
## the same column width is what makes the left rail (plate, onboarding, chat)
## and the right rail (quest, controls, toasts) read as stacks instead of as
## panels that happen to be near each other.
const EDGE := 16.0
const LEFT_COL_W := 314.0
const RIGHT_COL_W := 260.0
## The action bar: gauges, hotbar and quick actions in one row. There is no plate
## behind it - the bars and slots carry their own frames, and a full-width panel
## behind them read as a slab of background that the controls sat on rather than
## as part of the game. Metin2's taskbar is 37 px at 1024x768; this is 80 px at
## 1280x720, which is the height the stacked gauges and the level badge need.
## `DECK_H` / `DECK_BOTTOM` are also what the right rail measures against to keep
## its notification stack clear of the bar.
const DECK_H := 80.0
const DECK_BOTTOM := 24.0

static var _palette: Dictionary = {}
static var _theme: Theme = null
static var _icons: Dictionary = {}
static var _fonts: Dictionary = {}


# ------------------------------------------------------------------ palette

## The palette lives in the theme resource as its `Palette` type, so a colour and
## the boxes drawn with it cannot drift apart. These values are used only when
## that resource is missing.
static func _fallback_palette() -> Dictionary:
	return {
		"ink": Color(0.043, 0.051, 0.071),
		"night": Color(0.071, 0.078, 0.106),
		"slate": Color(0.102, 0.114, 0.149),
		"slate_lt": Color(0.165, 0.180, 0.227),
		"steel": Color(0.137, 0.153, 0.200),
		"steel_lt": Color(0.227, 0.255, 0.322),
		"gold_dk": Color(0.353, 0.271, 0.125),
		"gold": Color(0.659, 0.537, 0.184),
		"gold_lt": Color(0.847, 0.714, 0.290),
		"gold_hi": Color(0.957, 0.886, 0.627),
		"blood_dk": Color(0.227, 0.051, 0.071),
		"blood": Color(0.361, 0.086, 0.125),
		"blood_lt": Color(0.486, 0.122, 0.169),
		"parchment": Color(0.925, 0.882, 0.753),
		"text": Color(0.812, 0.792, 0.729),
		"text_dim": Color(0.600, 0.596, 0.557),
		"good": Color(0.361, 0.788, 0.290),
		"magic": Color(0.647, 0.361, 0.851),
		"mana": Color(0.227, 0.455, 0.851),
		"hp": Color(0.769, 0.157, 0.157),
		"exp": Color(0.851, 0.639, 0.122),
		"shadow": Color(0, 0, 0),
	}


static func palette() -> Dictionary:
	if not _palette.is_empty():
		return _palette
	_palette = _fallback_palette()
	var theme := get_theme()
	for key in _palette.keys():
		if theme.has_color(key, "Palette"):
			_palette[key] = theme.get_color(key, "Palette")
	return _palette


## A palette colour by name. Raises the colour when the key is unknown so a typo
## is visible on screen instead of silently rendering black.
static func c(key: String) -> Color:
	return palette().get(key, Color.MAGENTA)


static func alpha(key: String, a: float) -> Color:
	var col := c(key)
	col.a = a
	return col


# ------------------------------------------------------------------- icons

## Spell and item icons. The interface chrome is drawn from the theme, but an icon
## is content - it says which spell a slot holds - so the icons stay.
##
## Returns null when an icon has not been generated, so callers fall back to text
## rather than showing a broken texture.
static func icon(kind: String, id: String) -> Texture2D:
	var key := kind + ":" + id
	if _icons.has(key):
		return _icons[key]
	var path := ICON_DIR + "icon_" + id + ".png"
	var t: Texture2D = null
	if ResourceLoader.exists(path):
		t = load(path) as Texture2D
	_icons[key] = t
	return t


## Spells and items share one icon namespace (`icon_<id>.png`), so a hotbar slot
## holding a spell and a bag cell holding an item resolve through the same call.
static func icon_for(id: String) -> Texture2D:
	return icon("any", id)


static func spell_icon(spell_id: String) -> Texture2D:
	return icon_for(spell_id)


static func item_icon(item_id: String) -> Texture2D:
	return icon_for(item_id)


## The interface's own pictures: `ui_*` (buttons and panels), `status_*` (the
## effects on the local body), `stat_*` (the gauges), `minimap_*` (map markers),
## `audio_*` (the volume rows), `house_*` (the crests). They are plain files in
## the same folder and the same namespace as the spell and item icons, so one
## lookup answers for both - only the id says which is which.
static func chrome(id: String) -> Texture2D:
	return icon("chrome", id)


## A chrome icon scaled once to `px` and cached, for the widgets that draw their
## icon at the texture's own size: a `Button` sizes itself to its icon, so handing
## it a 512 px master would force a 512 px button. This build exposes no
## `icon_max_width`, and `expand_icon` scales the icon to the whole button - which
## squeezes the caption out of a button that carries both - so the resize happens
## here, once per id and size.
static func chrome_at(id: String, px: float) -> Texture2D:
	var key := "%s@%d" % [id, int(px)]
	if _icons.has(key):
		return _icons[key]
	var source := chrome(id)
	var out: Texture2D = source
	if source != null:
		var img := source.get_image()
		if img != null:
			var scaled := img.duplicate() as Image
			scaled.resize(int(px), int(px), Image.INTERPOLATE_LANCZOS)
			out = ImageTexture.create_from_image(scaled)
	_icons[key] = out
	return out


## A fixed-size icon holder, for chrome and content alike. `px` is the box, and
## the icon is fitted inside it, so a square crest and a tall broom can use the
## same call.
static func icon_rect(id: String, px: float) -> TextureRect:
	var rect := TextureRect.new()
	rect.texture = icon_for(id)
	rect.custom_minimum_size = Vector2(px, px)
	rect.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	rect.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
	rect.mouse_filter = Control.MOUSE_FILTER_IGNORE
	return rect


## A caption with an icon in front of it, as one row. The caption keeps its own
## node (callers keep writing to it); the icon explains it.
static func icon_row(id: String, label: Control, px: float) -> HBoxContainer:
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 5)
	row.mouse_filter = Control.MOUSE_FILTER_IGNORE
	row.add_child(icon_rect(id, px))
	row.add_child(label)
	return row


## A button that is only a picture, like the round chrome controls (close, zoom).
## `tip` is the tooltip and, for a screen reader, the button's name.
static func icon_button(id: String, tip: String = "", px: float = 26.0) -> Button:
	var button := Button.new()
	button.icon = chrome_at(id, px - 10.0)
	button.icon_alignment = HORIZONTAL_ALIGNMENT_CENTER
	button.tooltip_text = tip
	button.custom_minimum_size = Vector2(px, px)
	button.focus_mode = Control.FOCUS_NONE
	role(button, V_ICON_BTN)
	return button


## Give a captioned button its icon, at `px` square. The caption stays, and the
## icon is pre-scaled so it cannot push the caption out of the row.
static func set_button_icon(button: Button, id: String, px: float = 15.0) -> void:
	button.icon = chrome_at(id, px)
	button.icon_alignment = HORIZONTAL_ALIGNMENT_LEFT


# ------------------------------------------------------------------- fonts

## The font for a weight, in the heading face (`title`) or the body face.
##
## Cinzel is variable, so its weight is an axis value on one file. Alegreya Sans
## is not, so a weight picks the nearest shipped cut; the call sites ask for 500
## (`font_body`) and 700 (`font_body_bold`), which are exactly the Medium and
## Bold cuts, and anything in between still lands on something sensible rather
## than silently rendering at an unintended weight.
static func font(weight: int, title: bool = false) -> Font:
	var key := ("title" if title else "body") + str(weight)
	if _fonts.has(key):
		return _fonts[key]
	var out := _load_variable(TITLE_FONT_FILE, weight) if title else _load_cut(_body_cut_for(weight))
	_fonts[key] = out
	return out


## The shipped body-face file that covers `weight`.
static func _body_cut_for(weight: int) -> String:
	for cut in BODY_FONT_CUTS:
		if weight < int(cut[0]):
			return String(cut[1])
	return String(BODY_FONT_CUTS[BODY_FONT_CUTS.size() - 1][1])


## A variable-font instance at `weight` on the `wght` axis.
##
## The dedicated server exports no fonts (it has no display), so a null font
## would be handed straight to Label/RichTextLabel overrides and Godot would
## report a missing font for every widget it builds. The engine's own fallback
## keeps those controls rendering anywhere the art is absent.
static func _load_variable(file: String, weight: int) -> Font:
	var path := FONT_DIR + file
	if not ResourceLoader.exists(path):
		return ThemeDB.fallback_font
	var base := load(path) as FontFile
	if base == null:
		return ThemeDB.fallback_font
	var v := FontVariation.new()
	v.base_font = base
	v.variation_opentype = {"wght": weight}
	return v


## One static cut of the body face.
static func _load_cut(stem: String) -> Font:
	var path := FONT_DIR + stem + ".ttf"
	if not ResourceLoader.exists(path):
		return ThemeDB.fallback_font
	var f := load(path) as Font
	if f == null:
		return ThemeDB.fallback_font
	return f


static func font_title() -> Font:
	return font(700, true)


static func font_body() -> Font:
	return font(500, false)


static func font_body_bold() -> Font:
	return font(700, false)


# ------------------------------------------------------------------- theme

## The one Theme, loaded once. Falls back to a code-built minimal theme when the
## resource is absent, so a checkout without it still renders something usable
## instead of magenta rectangles.
static func get_theme() -> Theme:
	if _theme != null:
		return _theme
	var loaded: Theme = null
	if ResourceLoader.exists(THEME_PATH):
		loaded = load(THEME_PATH) as Theme
	if loaded == null:
		loaded = _minimal_theme()
	for variation in VARIATION_BASES:
		loaded.set_type_variation(variation, VARIATION_BASES[variation])
	_theme = loaded
	ArcaneSkin.install(_theme)
	return _theme


## The last-resort theme, used only when `hpmmo.tres` cannot be loaded.
static func _minimal_theme() -> Theme:
	var t := Theme.new()
	var body := font_body()
	t.default_font = body
	t.default_font_size = FS_BODY
	var card := StyleBoxFlat.new()
	card.bg_color = alpha("ink", 0.85)
	card.border_color = c("steel_lt")
	card.set_border_width_all(1)
	card.set_corner_radius_all(6)
	card.content_margin_left = 10
	card.content_margin_top = 8
	card.content_margin_right = 10
	card.content_margin_bottom = 8
	for type in ["Panel", "PanelContainer", "Card", "WindowFrame", "TooltipCard"]:
		t.set_stylebox("panel", type, card)
	t.set_font("font", "Label", body)
	t.set_color("font_color", "Label", c("text"))
	t.set_font_size("font_size", "Label", FS_BODY)
	t.set_font("font", "Button", font_body_bold())
	t.set_color("font_color", "Button", c("text"))
	for state in ["normal", "hover", "pressed", "disabled", "focus"]:
		t.set_stylebox(state, "Button", card)
		t.set_stylebox(state, "SlotButton", card)
	var track := StyleBoxFlat.new()
	track.bg_color = Color(0.02, 0.02, 0.03, 0.9)
	var fill := StyleBoxFlat.new()
	fill.bg_color = c("hp")
	for type in ["ProgressBar", "HpBar", "ManaBar", "ExpBar", "BossBar"]:
		t.set_stylebox("background", type, track)
		t.set_stylebox("fill", type, fill)
	return t


## Give a control a role from the theme. A thin wrapper so a call site reads as
## intent (`UITheme.role(bar, UITheme.V_HP)`) rather than as a property write.
static func role(control: Control, variation: StringName) -> void:
	control.theme_type_variation = variation


## Apply the shared theme to a whole subtree. Every top level surface calls this
## once in `_ready`.
static func apply(node: Node) -> void:
	if node is Control:
		(node as Control).theme = get_theme()
	elif node is CanvasLayer:
		# A CanvasLayer has no theme of its own; its Control children inherit
		# from the window, so stamp them individually.
		for child in node.get_children():
			apply(child)


## A heading label in the title face, used by every window caption.
static func heading(text: String, size: int = FS_HEADER, colour: Color = Color(0, 0, 0, 0)) -> Label:
	var l := Label.new()
	l.text = text
	l.theme_type_variation = V_TITLE
	l.add_theme_font_size_override("font_size", size)
	if colour.a > 0.0:
		l.add_theme_color_override("font_color", colour)
	l.mouse_filter = Control.MOUSE_FILTER_IGNORE
	return l


## A body-copy label in the regular face, for panel content rather than for a
## caption. It carries no outline: it sits on a panel that already supplies its
## own contrast, and an outline there is what turns small body text into a smear.
static func body(text: String, size: int = FS_BODY, colour: Color = Color(0, 0, 0, 0)) -> Label:
	var l := Label.new()
	l.text = text
	l.add_theme_font_override("font", font_body())
	l.add_theme_font_size_override("font_size", size)
	if colour.a > 0.0:
		l.add_theme_color_override("font_color", colour)
	l.mouse_filter = Control.MOUSE_FILTER_IGNORE
	return l


## A one-pixel horizontal rule, for separating a heading from its body. A flat
## line rather than an ornament: it costs no art and cannot misalign with the two
## labels it sits between.
static func divider() -> Panel:
	var line := Panel.new()
	var sb := StyleBoxFlat.new()
	sb.bg_color = c("steel_lt")
	line.add_theme_stylebox_override("panel", sb)
	line.custom_minimum_size = Vector2(0, 1)
	line.mouse_filter = Control.MOUSE_FILTER_IGNORE
	return line
