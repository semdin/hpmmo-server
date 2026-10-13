extends Control
class_name MapMarker

## The player's marker on the minimap: a gold arrow that turns with the way the
## character faces, over a soft light cone showing where the camera looks (the
## classic MMO "torch" on the map). Map space is world x to the right and world
## z downwards, so a world direction (dx, dz) is drawn as Vector2(dx, dz).

var facing := Vector2(0, -1)
var camera_dir := Vector2(0, -1)
var cone_length := 70.0

func _init() -> void:
	mouse_filter = Control.MOUSE_FILTER_IGNORE

func _draw() -> void:
	var c := size * 0.5
	draw_view_cone(self, c, camera_dir, cone_length)
	draw_arrow(self, c, facing, 11.0)

## A translucent wedge (about 70°) fading out from `at` along `dir`.
static func draw_view_cone(canvas: CanvasItem, at: Vector2, dir: Vector2, length: float) -> void:
	if dir.length_squared() < 0.0001:
		return
	dir = dir.normalized()
	var half := deg_to_rad(35.0)
	var rings := 6
	for i in range(rings, 0, -1):
		var r := length * float(i) / rings
		var a := 0.30 * (1.0 - float(i - 1) / rings)
		var pts := PackedVector2Array([at])
		var steps := 14
		for s in range(steps + 1):
			var ang := -half + 2.0 * half * float(s) / steps
			pts.append(at + dir.rotated(ang) * r)
		canvas.draw_colored_polygon(pts, Color(1.0, 0.93, 0.62, a * 0.55))

## The player's arrow pointing along `dir`: the painted gold arrowhead from the
## icon set, turned to face `dir` (it is authored pointing up); the vector
## arrowhead below is the fallback when the art is absent.
static func draw_arrow(canvas: CanvasItem, at: Vector2, dir: Vector2, radius: float) -> void:
	if dir.length_squared() < 0.0001:
		dir = Vector2(0, -1)
	dir = dir.normalized()
	var art := UITheme.chrome("minimap_player")
	if art != null:
		var s := radius * 2.6
		canvas.draw_set_transform(at, dir.angle() + PI * 0.5, Vector2.ONE)
		canvas.draw_texture_rect(art, Rect2(Vector2(-s, -s) * 0.5, Vector2(s, s)), false)
		canvas.draw_set_transform(Vector2.ZERO, 0.0, Vector2.ONE)
		return
	var side := Vector2(-dir.y, dir.x)
	var tip := at + dir * radius
	var left := at - dir * radius * 0.7 + side * radius * 0.75
	var right := at - dir * radius * 0.7 - side * radius * 0.75
	var notch := at - dir * radius * 0.25
	var rim := 2.2
	var outline := PackedVector2Array([
		at + dir * (radius + rim), left + (left - at).normalized() * rim,
		notch - dir * rim, right + (right - at).normalized() * rim])
	canvas.draw_colored_polygon(outline, Color(0.05, 0.03, 0.01, 0.95))
	canvas.draw_colored_polygon(PackedVector2Array([tip, left, notch, right]), Color(1.0, 0.82, 0.32))
	# A lit half for a bevelled look.
	canvas.draw_colored_polygon(PackedVector2Array([tip, left, notch]), Color(1.0, 0.95, 0.7))
