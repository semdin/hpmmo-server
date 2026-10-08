extends RefCounted
class_name ArcaneSkin

## A small opt-in material family. Images supply only geometry and metalwork;
## every state uses exactly the same geometry and all layout remains in Controls.
static var _textures: Dictionary = {}

static func texture(kind: String) -> Texture2D:
	if _textures.has(kind): return _textures[kind]
	var source := load("res://assets/ui/arcane/%s.png" % kind) as Texture2D
	if source == null: return null
	var img := source.get_image()
	if img.is_compressed(): img.decompress()
	# Normalize source padding once, at the logical UI resolution, not per frame.
	# Generated transparency may contain near-invisible pixels beyond the art.
	# Measure visible alpha, so nine-slice corners never include that padding.
	var left := img.get_width()
	var top := img.get_height()
	var right := 0
	var bottom := 0
	for y in img.get_height():
		for x in img.get_width():
			if img.get_pixel(x,y).a >= 0.25:
				left = mini(left,x)
				top = mini(top,y)
				right = maxi(right,x)
				bottom = maxi(bottom,y)
	if right >= left and bottom >= top: img = img.get_region(Rect2i(left,top,right-left+1,bottom-top+1))
	var target: Vector2i = {"window": Vector2i(240, 180), "button": Vector2i(220, 40), "slot": Vector2i(56, 56), "minimap": Vector2i(192, 192)}[kind]
	img.resize(target.x, target.y, Image.INTERPOLATE_LANCZOS)
	_textures[kind] = ImageTexture.create_from_image(img)
	return _textures[kind]

static func border(kind: String, tint := Color.WHITE) -> StyleBoxTexture:
	var box := StyleBoxTexture.new()
	box.texture = texture(kind)
	box.region_rect = Rect2(Vector2.ZERO, box.texture.get_size())
	box.modulate_color = tint
	box.draw_center = kind == "button"
	for side in [SIDE_LEFT, SIDE_TOP, SIDE_RIGHT, SIDE_BOTTOM]:
		box.set_texture_margin(side, (5.0 if side in [SIDE_TOP,SIDE_BOTTOM] else 12.0) if kind == "button" else 10.0)
		box.set_content_margin(side, 10.0 if kind == "window" else 5.0)
	return box

static func surface() -> StyleBoxFlat:
	var box := StyleBoxFlat.new()
	box.bg_color = Color("101b2bed")
	box.border_color = Color("716044")
	box.set_border_width_all(1)
	box.set_corner_radius_all(4)
	box.shadow_color = Color(0, 0, 0, 0.4)
	box.shadow_size = 5
	box.shadow_offset = Vector2(0, 3)
	box.set_content_margin_all(10)
	return box

static func install(theme: Theme) -> void:
	# The dedicated export and minimal-theme fallback may omit presentation art.
	for kind in ["window","button","slot","minimap"]:
		if not ResourceLoader.exists("res://assets/ui/arcane/%s.png" % kind): return
	for role in ["ArcaneCard", "ArcaneWindow"]:
		theme.set_type_variation(role, "Panel")
		theme.set_stylebox("panel", role, surface())
	for role in ["ArcaneSlot", "ArcaneButton"]:
		theme.set_type_variation(role, "Button")
		var kind := "slot" if role == "ArcaneSlot" else "button"
		for state in ["normal", "hover", "pressed", "disabled", "focus"]:
			var tint := Color.WHITE
			if state == "hover": tint = Color(1.15, 1.15, 1.2)
			if state == "pressed": tint = Color(0.7, 0.8, 0.9)
			if state == "disabled": tint = Color(0.5, 0.5, 0.5, 0.65)
			if state == "focus":
				var focus := surface()
				focus.draw_center = false
				focus.border_color = Color("7fceeb")
				focus.shadow_size = 0
				theme.set_stylebox(state, role, focus)
			else: theme.set_stylebox(state, role, border(kind, tint))
		theme.set_color("font_color", role, Color("ede2ca"))

static func decorate(control: Control, kind: String = "window") -> void:
	var frame := NinePatchRect.new()
	frame.name = "ArcaneFrame"
	frame.texture = texture(kind)
	frame.draw_center = false
	frame.patch_margin_left = 10
	frame.patch_margin_right = 10
	frame.patch_margin_top = 10
	frame.patch_margin_bottom = 10
	frame.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	frame.mouse_filter = Control.MOUSE_FILTER_IGNORE
	control.add_child(frame)
	control.move_child(frame, 0)
