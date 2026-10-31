extends RefCounted
class_name CursorKit

## The game's mouse pointers, all one size (36 px; the source art stays local
## in art/ui/cursors): the arrow, a pointing hand over buttons, a text bar over
## text fields, and a gold "rotate" glyph while the right mouse button turns
## the camera, so it is obvious the mouse is steering the view and not pointing
## at something. Released, the usual pointers come back.

const ARROW := "res://assets/ui/cursor.png"
const HAND := "res://assets/ui/cursor_hand.png"
const IBEAM := "res://assets/ui/cursor_ibeam.png"
const ROTATE := "res://assets/ui/cursor_rotate.png"
## Where each pointer points: the arrow's tip, the index fingertip, centres.
const HOTSPOTS := {
	ARROW: Vector2(0, 0),
	HAND: Vector2(12, 1),
	IBEAM: Vector2(18, 18),
	ROTATE: Vector2(18, 18),
}
## The shapes the game draws itself, and the pointer each one normally shows.
const SHAPES := {
	Input.CURSOR_ARROW: ARROW,
	Input.CURSOR_POINTING_HAND: HAND,
	Input.CURSOR_IBEAM: IBEAM,
}

static var _rotating := false

## Boot: install every pointer (GameData._ready).
static func apply() -> void:
	if DisplayServer.get_name() == "headless":
		return
	for shape in SHAPES:
		_install(SHAPES[shape], shape)

## Quitting (GameData._exit_tree): hand every shape back to the system while the
## RenderingServer still exists, or the pointer textures leak at exit.
static func release() -> void:
	if DisplayServer.get_name() == "headless":
		return
	for shape in SHAPES:
		Input.set_custom_mouse_cursor(null, shape)

## While turning the camera every shape shows the rotate glyph (the pointer
## may cross a button or a text field on the way).
static func set_rotating(on: bool) -> void:
	if on == _rotating or DisplayServer.get_name() == "headless":
		return
	_rotating = on
	for shape in SHAPES:
		_install(ROTATE if on else SHAPES[shape], shape)

## Buttons show the hand (GameData hooks this to SceneTree.node_added). Text
## fields already ask for the I-beam; a control that chose another shape keeps it.
static func point_at_buttons(node: Node) -> void:
	if node is BaseButton and (node as Control).mouse_default_cursor_shape == Control.CURSOR_ARROW:
		(node as Control).mouse_default_cursor_shape = Control.CURSOR_POINTING_HAND

static func _install(path: String, shape: Input.CursorShape) -> void:
	var tex := load(path) as Texture2D if ResourceLoader.exists(path) else null
	if tex != null:
		Input.set_custom_mouse_cursor(tex, shape, HOTSPOTS[path])
