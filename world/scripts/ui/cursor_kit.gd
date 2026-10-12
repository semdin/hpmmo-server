extends RefCounted
class_name CursorKit

## The pointer while the right mouse button turns the camera: a gold "rotate"
## glyph instead of the arrow, so it is obvious the mouse is steering the view
## and not pointing at something. Released, the project's arrow comes back.

const ROTATE := "res://assets/ui/cursor_rotate.png"
const ARROW := "res://assets/ui/cursor.png"

static var _rotating := false

static func set_rotating(on: bool) -> void:
	if on == _rotating or DisplayServer.get_name() == "headless":
		return
	_rotating = on
	var path := ROTATE if on else ARROW
	if not ResourceLoader.exists(path):
		return
	var tex := load(path) as Texture2D
	if tex == null:
		return
	var hotspot := tex.get_size() * 0.5 if on else Vector2.ZERO
	Input.set_custom_mouse_cursor(tex, Input.CURSOR_ARROW, hotspot)
