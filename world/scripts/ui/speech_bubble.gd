extends Node3D
class_name SpeechBubble

## What a player says in local chat, floating over their head for a few
## seconds (Metin2 style). A small 2D panel rendered into a viewport and shown on
## a billboarded sprite, so it can carry a real background, word wrap and the
## HUD's fonts. One per speaker: a new line replaces the old one.

const LIFETIME := 6.0
const FADE := 0.6
const MAX_WIDTH := 300
const PIXEL := 0.0052

var _viewport: SubViewport
var _sprite: Sprite3D
var _age := 0.0

static func say(speaker: Node3D, text: String, height: float) -> SpeechBubble:
	if speaker == null or not is_instance_valid(speaker) or text.strip_edges() == "":
		return null
	var old := speaker.get_node_or_null("SpeechBubble")
	if old != null:
		old.name = "SpeechBubbleOld"
		old.queue_free()
	var bubble := SpeechBubble.new()
	bubble.name = "SpeechBubble"
	speaker.add_child(bubble)
	bubble.position = Vector3(0, height, 0)
	bubble._build(text)
	return bubble

func _build(text: String) -> void:
	_viewport = SubViewport.new()
	_viewport.transparent_bg = true
	_viewport.disable_3d = true
	_viewport.render_target_update_mode = SubViewport.UPDATE_ONCE
	add_child(_viewport)
	var card := PanelContainer.new()
	var sb := StyleBoxFlat.new()
	sb.bg_color = Color(0.97, 0.95, 0.89, 0.94)
	sb.border_color = Color(0.29, 0.22, 0.12)
	sb.set_border_width_all(2)
	sb.set_corner_radius_all(10)
	sb.content_margin_left = 12
	sb.content_margin_right = 12
	sb.content_margin_top = 7
	sb.content_margin_bottom = 8
	card.add_theme_stylebox_override("panel", sb)
	var label := Label.new()
	label.text = text.strip_edges().substr(0, 140)
	label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	label.add_theme_font_override("font", HudKit.bold())
	label.add_theme_font_size_override("font_size", 22)
	label.add_theme_color_override("font_color", Color(0.12, 0.09, 0.06))
	var font := HudKit.bold()
	var one_line := font.get_string_size(label.text, HORIZONTAL_ALIGNMENT_LEFT, -1, 22).x
	label.custom_minimum_size.x = minf(one_line + 2.0, float(MAX_WIDTH))
	card.add_child(label)
	_viewport.add_child(card)
	# Size the viewport to the laid-out card (one frame later, once it has a size).
	_viewport.size = Vector2i(MAX_WIDTH + 30, 200)
	_sprite = Sprite3D.new()
	_sprite.billboard = BaseMaterial3D.BILLBOARD_ENABLED
	_sprite.no_depth_test = true
	_sprite.render_priority = 10
	_sprite.pixel_size = PIXEL
	_sprite.texture_filter = BaseMaterial3D.TEXTURE_FILTER_LINEAR_WITH_MIPMAPS
	_sprite.texture = _viewport.get_texture()
	_sprite.centered = true
	_sprite.offset = Vector2(0, 0)
	add_child(_sprite)
	await get_tree().process_frame
	if not is_instance_valid(card):
		return
	var s := card.get_combined_minimum_size()
	card.size = s
	# A small tail under the bubble.
	_viewport.size = Vector2i(int(ceil(s.x)) + 2, int(ceil(s.y)) + 14)
	var tail := Polygon2D.new()
	var cx := s.x * 0.5
	tail.polygon = PackedVector2Array([Vector2(cx - 9, s.y - 2), Vector2(cx + 9, s.y - 2), Vector2(cx, s.y + 11)])
	tail.color = Color(0.97, 0.95, 0.89, 0.94)
	_viewport.add_child(tail)
	_viewport.render_target_update_mode = SubViewport.UPDATE_ONCE
	_sprite.offset = Vector2(0, (s.y + 14) * 0.5)

func _process(delta: float) -> void:
	_age += delta
	if _sprite != null:
		_sprite.modulate.a = clampf((LIFETIME - _age) / FADE, 0.0, 1.0)
	if _age >= LIFETIME:
		queue_free()
