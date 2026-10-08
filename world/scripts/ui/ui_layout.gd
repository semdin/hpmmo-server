extends RefCounted
class_name UILayout

## Interface layout helper.
##
## `Control.position` is expressed against the parent's top-left corner, so
## assigning it after `set_anchors_preset()` on anything that is not anchored to
## the top-left lands the control off-screen as soon as the anchor is not
## (0, 0) - at 1280x720 a centre-anchored panel assigned `position = (-280, -240)`
## ends up 280 px left of the left edge. These helpers set the offsets, which
## are relative to the anchor, so a panel sits where the anchor says it does at
## every resolution and aspect ratio the stretch mode supports.

## Place a Control at `at` (relative to its anchors) with `size`.
static func place(control: Control, at: Vector2, size: Vector2) -> void:
	control.offset_left = at.x
	control.offset_top = at.y
	control.offset_right = at.x + size.x
	control.offset_bottom = at.y + size.y

## Place a Control centred on its anchor point (anchor must be a centred
## preset), keeping the given size.
static func place_centred(control: Control, size: Vector2, offset: Vector2 = Vector2.ZERO) -> void:
	place(control, -size * 0.5 + offset, size)
