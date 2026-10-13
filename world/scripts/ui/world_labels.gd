extends CanvasLayer
class_name WorldLabels

## Screen-space text for things that float over the world: player nameplates,
## mob / NPC / monolith captions and the local-chat speech bubbles.
##
## A `Label3D` or a viewport sprite is a 3D object, so it goes through
## everything the 3D frame does - tonemapping, distance fog, glow bleeding from
## a sunlit rock behind it, mip blur once it is small. That is why names read as
## washed into whatever stood behind them at range. Here the text is drawn by
## the 2D canvas instead, at a projected anchor: the same crisp glyphs and
## outlines the HUD uses, at every distance and over every background.
##
## The 3D labels stay in the scene as the source of truth (their text, colour,
## visibility and height are still set by their owners, and the checks still
## read them); they are only removed from every camera's render layers. On a
## headless run (server, checks) nothing here activates and the labels behave
## exactly as before.

const LAYER := 0
## Font px at the reference distance; scaled down with distance to MIN_SCALE.
const REF_DISTANCE := 7.0
const MIN_SCALE := 0.62
const MAX_SCALE := 1.08
const DEFAULT_RANGE := 55.0

static var _instance: WorldLabels = null

## label -> {"px": base font px, "font": Font, "bold": bool}
var _labels: Dictionary = {}
## bubble -> Control (the card); positioned each frame over the bubble's anchor.
var _bubbles: Dictionary = {}
var _canvas: _Canvas = null

static func enabled() -> bool:
	return DisplayServer.get_name() != "headless"

static func get_label_layer(from: Node) -> WorldLabels:
	if not enabled() or from == null or not from.is_inside_tree():
		return null
	# (Added deferred, so a fresh instance is valid before it is in the tree.)
	if _instance != null and is_instance_valid(_instance) and not _instance.is_queued_for_deletion():
		return _instance
	_instance = WorldLabels.new()
	_instance.name = "WorldLabels"
	_instance.layer = LAYER
	from.get_tree().root.add_child.call_deferred(_instance)
	return _instance

## Mirror a Label3D on screen. `px` is the font size the text should have at the
## reference distance (a nameplate name is ~19 px, its level line ~14 px).
static func track(label: Label3D, px: float, bold: bool = true) -> void:
	if label == null:
		return
	var layer := get_label_layer(label)
	if layer == null:
		return
	label.layers = 0   # no camera draws the 3D copy any more
	layer._labels[label] = {"px": px, "bold": bold}

static func track_bubble(bubble: Node3D, card: Control) -> void:
	var layer := get_label_layer(bubble)
	if layer == null:
		return
	layer._add_bubble(bubble, card)

func _ready() -> void:
	_canvas = _Canvas.new()
	_canvas.owner_layer = self
	_canvas.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_canvas.set_anchors_preset(Control.PRESET_FULL_RECT)
	add_child(_canvas)

func _add_bubble(bubble: Node3D, card: Control) -> void:
	if not is_node_ready():
		await ready
	if not is_instance_valid(card):
		return
	card.mouse_filter = Control.MOUSE_FILTER_IGNORE
	card.visible = false
	add_child(card)
	_bubbles[bubble] = card
	bubble.tree_exiting.connect(func():
		if is_instance_valid(card):
			card.queue_free()
		_bubbles.erase(bubble))

func _camera() -> Camera3D:
	return get_viewport().get_camera_3d()

func _process(_delta: float) -> void:
	var cam := _camera()
	for bubble in _bubbles.keys():
		var card: Control = _bubbles[bubble]
		if not is_instance_valid(bubble) or not is_instance_valid(card):
			_bubbles.erase(bubble)
			continue
		var at := _project(cam, (bubble as Node3D).global_position, DEFAULT_RANGE)
		var shown: bool = at.z > 0.0 and (bubble as Node3D).is_visible_in_tree()
		card.visible = shown
		if shown:
			var s := clampf(REF_DISTANCE / maxf(at.z, 0.01), 0.72, 1.0)
			card.scale = Vector2(s, s)
			card.pivot_offset = Vector2(card.size.x * 0.5, card.size.y)
			card.position = Vector2(at.x, at.y) - Vector2(card.size.x * 0.5, card.size.y)
			card.modulate.a = float((bubble as Node).get("fade") if "fade" in bubble else 1.0)
	if _canvas != null:
		_canvas.queue_redraw()

## Screen point (x, y) and camera distance (z); z <= 0 means "do not draw".
func _project(cam: Camera3D, world: Vector3, max_range: float) -> Vector3:
	if cam == null or cam.is_position_behind(world):
		return Vector3(0, 0, -1)
	var dist := cam.global_position.distance_to(world)
	if dist > max_range:
		return Vector3(0, 0, -1)
	var p := cam.unproject_position(world)
	var rect := get_viewport().get_visible_rect()
	if not rect.grow(120.0).has_point(p):
		return Vector3(0, 0, -1)
	return Vector3(p.x, p.y, dist)

func _draw_labels(canvas: CanvasItem) -> void:
	var cam := _camera()
	if cam == null:
		return
	# Far labels first so nearer ones are drawn on top of them.
	var order: Array = []
	for label in _labels.keys():
		if not is_instance_valid(label):
			_labels.erase(label)
			continue
		var l := label as Label3D
		if not l.is_visible_in_tree() or l.text == "":
			continue
		var max_range := l.visibility_range_end if l.visibility_range_end > 0.0 else DEFAULT_RANGE
		# A label under a tracked label (a nameplate's level line) is laid out in
		# screen pixels below its parent: in world units the gap shrinks with
		# distance while the 2D text does not, so the lines would collide.
		var parent := l.get_parent() as Label3D
		if parent != null and _labels.has(parent):
			var pat := _project(cam, parent.global_position, max_range)
			if pat.z <= 0.0:
				continue
			var ppx := _px_for(parent, pat.z)
			var lines := parent.text.split("\n").size()
			order.append([Vector3(pat.x, pat.y + float(ppx) * 1.12 * float(lines) * 0.5 + float(_px_for(l, pat.z)) * 0.62 + 1.0, pat.z - 0.001), l])
			continue
		var at := _project(cam, l.global_position, max_range)
		if at.z <= 0.0:
			continue
		order.append([at, l])
	order.sort_custom(func(a, b): return a[0].z > b[0].z)
	for pair in order:
		_draw_one(canvas, pair[0], pair[1])

## Font px for a tracked label seen from `dist` metres.
func _px_for(l: Label3D, dist: float) -> int:
	var k := clampf(REF_DISTANCE / maxf(dist, 0.01), MIN_SCALE, MAX_SCALE)
	return maxi(9, int(round(float(_labels[l].px) * k)))

func _draw_one(canvas: CanvasItem, at: Vector3, l: Label3D) -> void:
	var spec: Dictionary = _labels[l]
	var px := _px_for(l, at.z)
	var font: Font = HudKit.bold() if bool(spec.bold) else HudKit.body()
	var colour := l.modulate
	colour.a = 1.0
	var outline := Color(0.02, 0.015, 0.01, 0.92)
	var lines := l.text.split("\n")
	var line_h := float(px) * 1.12
	# Label3D is centred on its anchor, so the 2D copy is too.
	var y := at.y - line_h * float(lines.size()) * 0.5 + float(px) * 0.82
	var ow := maxi(3, int(round(float(px) * 0.26)))
	for line in lines:
		var w := font.get_string_size(line, HORIZONTAL_ALIGNMENT_LEFT, -1, px).x
		var pos := Vector2(roundf(at.x - w * 0.5), roundf(y))
		canvas.draw_string(font, pos + Vector2(0, 2), line, HORIZONTAL_ALIGNMENT_LEFT, -1, px, Color(0, 0, 0, 0.45))
		canvas.draw_string_outline(font, pos, line, HORIZONTAL_ALIGNMENT_LEFT, -1, px, ow, outline)
		canvas.draw_string(font, pos, line, HORIZONTAL_ALIGNMENT_LEFT, -1, px, colour)
		y += line_h


class _Canvas extends Control:
	var owner_layer: WorldLabels = null
	func _draw() -> void:
		if owner_layer != null:
			owner_layer._draw_labels(self)
