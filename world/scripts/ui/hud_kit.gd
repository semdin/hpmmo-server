extends RefCounted
class_name HudKit

## The in-game HUD's visual kit: one place for the MMO frame language so the
## unit frame, the action bar, the buff row, the chat, the trackers, the notices,
## the menus and the maps are drawn from the same handful of materials.
##
## The language is the project's "arcane" palette pushed toward a classic MMO
## frame: deep midnight glass, a thin aged-gold bevel, glossy gauges with a lit
## top edge, and text with a soft dark outline so it reads over any terrain.
## Everything is generated in code (no new chrome art), and every font is
## loaded through `ResourceLoader.exists` so the dedicated server - which ships
## no fonts or UI art - never fails to parse a script that uses the kit.

const FONT_DIR := "res://assets/fonts/"

# ------------------------------------------------------------------ colours
const INK := Color(0.035, 0.043, 0.063)
const NAVY := Color(0.055, 0.075, 0.118)
const NAVY_LT := Color(0.098, 0.129, 0.192)
const GOLD_DK := Color(0.373, 0.286, 0.137)
const GOLD := Color(0.749, 0.604, 0.298)
const GOLD_LT := Color(0.910, 0.784, 0.478)
const GOLD_HI := Color(1.0, 0.929, 0.729)
const PARCHMENT := Color(0.949, 0.910, 0.812)
const TEXT := Color(0.886, 0.867, 0.820)
const TEXT_DIM := Color(0.647, 0.635, 0.604)
const SHADOW := Color(0, 0, 0, 0.85)
const RED := Color(0.886, 0.200, 0.176)
const BLUE := Color(0.243, 0.502, 0.949)
const GREEN := Color(0.392, 0.820, 0.341)
const SHOUT := Color(1.0, 0.647, 0.278)
const WHISPER := Color(0.851, 0.569, 1.0)

static var _fonts: Dictionary = {}
static var _boxes: Dictionary = {}

# -------------------------------------------------------------------- fonts

static func _font(file: String, weight: int = 0) -> Font:
	var key := "%s@%d" % [file, weight]
	if _fonts.has(key):
		return _fonts[key]
	var path := FONT_DIR + file
	var out: Font = ThemeDB.fallback_font
	if ResourceLoader.exists(path):
		var base := load(path) as FontFile
		if base != null:
			if weight > 0:
				var v := FontVariation.new()
				v.base_font = base
				v.variation_opentype = {"wght": weight}
				out = v
			else:
				out = base
	_fonts[key] = out
	return out

## Body copy: chat, tooltips, numbers.
static func body() -> Font:
	return _font("Philosopher-Regular.ttf")

static func bold() -> Font:
	return _font("Philosopher-Bold.ttf")

## Captions and window titles (Cinzel, heavy).
static func title() -> Font:
	return _font("Cinzel-Variable.ttf", 700)

## Place names and the big zone announcement.
static func deco() -> Font:
	var f := _font("CinzelDecorative-Bold.ttf")
	return f if f != ThemeDB.fallback_font else title()

# ------------------------------------------------------------------- labels

## A label that reads over the world: dark outline plus a soft drop shadow.
static func label(text: String, size: int, colour: Color = TEXT, font: Font = null, outline: int = 4) -> Label:
	var l := Label.new()
	l.text = text
	l.mouse_filter = Control.MOUSE_FILTER_IGNORE
	l.add_theme_font_override("font", font if font != null else body())
	l.add_theme_font_size_override("font_size", size)
	l.add_theme_color_override("font_color", colour)
	l.add_theme_color_override("font_outline_color", Color(0, 0, 0, 0.9))
	l.add_theme_constant_override("outline_size", outline)
	l.add_theme_color_override("font_shadow_color", Color(0, 0, 0, 0.55))
	l.add_theme_constant_override("shadow_offset_x", 1)
	l.add_theme_constant_override("shadow_offset_y", 2)
	return l

static func style_label(l: Control, size: int, colour: Color, font: Font = null, outline: int = 4) -> void:
	l.add_theme_font_override("font", font if font != null else body())
	l.add_theme_font_size_override("font_size", size)
	l.add_theme_color_override("font_color", colour)
	l.add_theme_color_override("font_outline_color", Color(0, 0, 0, 0.9))
	l.add_theme_constant_override("outline_size", outline)

# --------------------------------------------------------------- styleboxes

## Midnight glass with a thin gold bevel - the base of every HUD card.
static func panel(alpha: float = 0.88, radius: int = 6, border_alpha: float = 0.85) -> StyleBoxFlat:
	var key := "panel%.2f/%d/%.2f" % [alpha, radius, border_alpha]
	if _boxes.has(key):
		return _boxes[key]
	var sb := StyleBoxFlat.new()
	sb.bg_color = Color(NAVY.r, NAVY.g, NAVY.b, alpha)
	sb.border_color = Color(GOLD.r, GOLD.g, GOLD.b, border_alpha)
	sb.set_border_width_all(1)
	sb.set_corner_radius_all(radius)
	sb.shadow_color = Color(0, 0, 0, 0.45 * alpha)
	sb.shadow_size = 6
	sb.shadow_offset = Vector2(0, 2)
	sb.set_content_margin_all(10)
	sb.anti_aliasing = true
	_boxes[key] = sb
	return sb

## A window: same glass, heavier frame, title band drawn by the window itself.
static func window() -> StyleBoxFlat:
	if _boxes.has("window"):
		return _boxes["window"]
	var sb := StyleBoxFlat.new()
	sb.bg_color = Color(0.039, 0.051, 0.082, 0.96)
	sb.border_color = GOLD
	sb.set_border_width_all(2)
	sb.set_corner_radius_all(8)
	sb.shadow_color = Color(0, 0, 0, 0.6)
	sb.shadow_size = 18
	sb.shadow_offset = Vector2(0, 6)
	sb.set_content_margin_all(0)
	_boxes["window"] = sb
	return sb

## Parchment card (quest dialog).
static func parchment() -> StyleBoxFlat:
	if _boxes.has("parchment"):
		return _boxes["parchment"]
	var sb := StyleBoxFlat.new()
	sb.bg_color = Color(0.886, 0.812, 0.639)
	sb.border_color = Color(0.384, 0.259, 0.114)
	sb.set_border_width_all(3)
	sb.set_corner_radius_all(4)
	sb.shadow_color = Color(0, 0, 0, 0.55)
	sb.shadow_size = 16
	sb.shadow_offset = Vector2(0, 6)
	sb.set_content_margin_all(0)
	_boxes["parchment"] = sb
	return sb

static func empty() -> StyleBoxEmpty:
	return StyleBoxEmpty.new()

## Buttons: gold-rimmed navy, lit on hover.
static func button_box(state: String) -> StyleBoxFlat:
	var key := "btn_" + state
	if _boxes.has(key):
		return _boxes[key]
	var sb := StyleBoxFlat.new()
	sb.set_corner_radius_all(5)
	sb.set_border_width_all(1)
	sb.content_margin_left = 14
	sb.content_margin_right = 14
	sb.content_margin_top = 6
	sb.content_margin_bottom = 6
	match state:
		"hover":
			sb.bg_color = Color(0.141, 0.176, 0.255)
			sb.border_color = GOLD_LT
		"pressed":
			sb.bg_color = Color(0.051, 0.063, 0.094)
			sb.border_color = GOLD
		"disabled":
			sb.bg_color = Color(0.067, 0.071, 0.086, 0.8)
			sb.border_color = Color(0.3, 0.28, 0.24)
		"focus":
			sb.draw_center = false
			sb.border_color = GOLD_HI
		_:
			sb.bg_color = Color(0.090, 0.114, 0.165)
			sb.border_color = GOLD_DK.lerp(GOLD, 0.6)
	_boxes[key] = sb
	return sb

static func style_button(b: Button, size: int = 15) -> void:
	for state in ["normal", "hover", "pressed", "disabled", "focus"]:
		b.add_theme_stylebox_override(state, button_box(state))
	b.add_theme_font_override("font", bold())
	b.add_theme_font_size_override("font_size", size)
	b.add_theme_color_override("font_color", PARCHMENT)
	b.add_theme_color_override("font_hover_color", GOLD_HI)
	b.add_theme_color_override("font_pressed_color", GOLD_LT)
	b.add_theme_color_override("font_disabled_color", TEXT_DIM)
	b.add_theme_color_override("font_outline_color", Color(0, 0, 0, 0.8))
	b.add_theme_constant_override("outline_size", 3)

static func button(text: String, size: int = 15) -> Button:
	var b := Button.new()
	b.text = text
	b.focus_mode = Control.FOCUS_NONE
	style_button(b, size)
	return b

# ------------------------------------------------------------------- gauges

## Vertical gloss gradient for a gauge fill: lit top edge, body colour, dark foot.
static func gauge_fill(base: Color) -> StyleBoxTexture:
	var key := "fill_" + base.to_html()
	if _boxes.has(key):
		return _boxes[key]
	var g := Gradient.new()
	g.offsets = PackedFloat32Array([0.0, 0.10, 0.42, 0.58, 1.0])
	g.colors = PackedColorArray([
		base.lightened(0.62),
		base.lightened(0.28),
		base.lightened(0.05),
		base.darkened(0.12),
		base.darkened(0.45),
	])
	var tex := GradientTexture2D.new()
	tex.gradient = g
	tex.width = 4
	tex.height = 32
	tex.fill_from = Vector2(0, 0)
	tex.fill_to = Vector2(0, 1)
	var sb := StyleBoxTexture.new()
	sb.texture = tex
	_boxes[key] = sb
	return sb

static func gauge_track() -> StyleBoxFlat:
	if _boxes.has("track"):
		return _boxes["track"]
	var sb := StyleBoxFlat.new()
	sb.bg_color = Color(0.02, 0.024, 0.035, 0.92)
	sb.border_color = Color(0, 0, 0, 0.95)
	sb.set_border_width_all(1)
	sb.set_corner_radius_all(2)
	sb.set_expand_margin_all(1)
	_boxes["track"] = sb
	return sb

static func style_gauge(bar: ProgressBar, base: Color) -> void:
	bar.add_theme_stylebox_override("background", gauge_track())
	bar.add_theme_stylebox_override("fill", gauge_fill(base))
	bar.show_percentage = false

# --------------------------------------------------------------- tooltip

## The HUD tooltip: first line as a gold heading, the rest as body copy, on the
## midnight card. Controls return this from `_make_custom_tooltip`.
static func tooltip(for_text: String, accent: Color = GOLD_LT) -> Control:
	var card := PanelContainer.new()
	var sb := panel(0.96, 5).duplicate() as StyleBoxFlat
	sb.set_content_margin_all(9)
	card.add_theme_stylebox_override("panel", sb)
	var box := VBoxContainer.new()
	box.add_theme_constant_override("separation", 3)
	card.add_child(box)
	var lines := for_text.split("\n")
	for i in range(lines.size()):
		var line := String(lines[i])
		if i == 0:
			box.add_child(label(line, 15, accent, bold(), 2))
		else:
			var l := label(line, 13, TEXT if i > 1 else Color(0.62, 0.78, 1.0), body(), 0)
			l.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
			l.custom_minimum_size.x = 240
			box.add_child(l)
	return card
