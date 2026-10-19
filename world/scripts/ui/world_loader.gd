extends CanvasLayer
class_name WorldLoader

## The loading screen between the character screen and the world. It loads the
## world scene once the screen is on show, switches to it,
## and stays on top until the world has actually built its ground and the
## player's body exists - so there is no grey frame and no half-built map, just
## the key art, the bar and a tip, fading out onto the game.
##
##   WorldLoader.enter_world(get_tree())

const WORLD_SCENE := "res://scenes/world/game_world.tscn"
const ART := "res://assets/branding/hpmmo_banner.jpg"
const MIN_SHOW := 1.2
const TIPS := [
	"Start a chat line with ! to shout to every wizard in the realm.",
	"Drag a potion from your bag onto F1-F4 to drink it with one key.",
	"Protego reflects projectiles back at their caster.",
	"Inferi fear fire: Incendio burns them for double damage.",
	"Hold the right mouse button to turn the camera; the wheel zooms.",
	"Land on level ground before you dismount your broom.",
	"Dark Monoliths summon waves of creatures - bring friends.",
	"Ollivander can refine your wand. Higher tiers glow brighter.",
	"Press M for the map of the valley, Esc for the menu.",
]

var _path := WORLD_SCENE
var _phase := "load"      # load -> switch -> settle -> fade
var _t := 0.0
var _progress := 0.0
var _shown := 0.0
var _settle := 0.0
var _bar: ProgressBar
var _status: Label
var _tip: Label
var _root: Control
var _spin := 0.0
var _rune: Control

static func enter_world(tree: SceneTree, path: String = WORLD_SCENE) -> void:
	var existing := tree.root.get_node_or_null("WorldLoader")
	if existing != null:
		return
	var loader := WorldLoader.new()
	loader.name = "WorldLoader"
	loader._path = path
	tree.root.add_child.call_deferred(loader)

func _ready() -> void:
	layer = 100
	process_mode = Node.PROCESS_MODE_ALWAYS
	_root = Control.new()
	_root.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	_root.mouse_filter = Control.MOUSE_FILTER_STOP
	add_child(_root)
	var black := ColorRect.new()
	black.color = Color(0.01, 0.012, 0.02)
	black.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	_root.add_child(black)
	if ResourceLoader.exists(ART):
		var art := TextureRect.new()
		art.texture = load(ART)
		art.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
		art.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_COVERED
		art.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
		art.modulate = Color(0.78, 0.78, 0.82)
		_root.add_child(art)
	# Bottom shade for legibility.
	var shade := ShadeRect.new()
	shade.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	_root.add_child(shade)
	var title := HudKit.label("HOGWARTS", 64, HudKit.GOLD_HI, HudKit.deco(), 10)
	title.set_anchors_preset(Control.PRESET_CENTER_BOTTOM)
	title.offset_left = -500
	title.offset_right = 500
	title.offset_top = -230
	title.offset_bottom = -150
	title.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	title.add_theme_color_override("font_outline_color", Color(0.1, 0.06, 0.02, 0.95))
	_root.add_child(title)
	_bar = ProgressBar.new()
	_bar.set_anchors_preset(Control.PRESET_CENTER_BOTTOM)
	_bar.offset_left = -360
	_bar.offset_right = 360
	_bar.offset_top = -132
	_bar.offset_bottom = -118
	_bar.min_value = 0
	_bar.max_value = 100
	HudKit.style_gauge(_bar, Color(0.9, 0.68, 0.2))
	_root.add_child(_bar)
	_status = HudKit.label("Opening the gates…", 16, HudKit.PARCHMENT, HudKit.title(), 4)
	_status.set_anchors_preset(Control.PRESET_CENTER_BOTTOM)
	_status.offset_left = -360
	_status.offset_right = 360
	_status.offset_top = -112
	_status.offset_bottom = -90
	_status.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_root.add_child(_status)
	_tip = HudKit.label("", 16, HudKit.TEXT, HudKit.body(), 4)
	_tip.set_anchors_preset(Control.PRESET_CENTER_BOTTOM)
	_tip.offset_left = -520
	_tip.offset_right = 520
	_tip.offset_top = -70
	_tip.offset_bottom = -40
	_tip.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_tip.text = "Tip: " + String(TIPS[randi() % TIPS.size()])
	_root.add_child(_tip)
	_rune = Spinner.new()
	_rune.set_anchors_preset(Control.PRESET_BOTTOM_RIGHT)
	_rune.offset_left = -92
	_rune.offset_top = -92
	_rune.offset_right = -36
	_rune.offset_bottom = -36
	_root.add_child(_rune)

## The world scene loads on the main thread, once this screen has been drawn.
## It used to load on a background thread: online, the snapshots and stats that
## arrive meanwhile make the main thread load resources too, and a client could
## sit on "Opening the gates" for good (seen live: a body in the world for 35
## minutes, its client never past this screen). A frozen bar for a couple of
## seconds is the price of a load that always finishes.
const LOAD_AFTER := 0.25

func _process(delta: float) -> void:
	_t += delta
	_shown += delta
	match _phase:
		"load":
			_progress = minf(30.0, _progress + delta * 60.0)
			if _shown >= LOAD_AFTER:
				_status.text = "Raising the castle…"
				_bar.value = 35.0
				_phase = "switch"
		"switch":
			var packed := load(_path) as PackedScene
			if packed == null:
				_phase = "fallback"
				return
			_progress = 72.0
			_bar.value = 72.0
			_phase = "settle"
			_settle = 0.0
			# Building the grounds happens in the world's _ready, on this thread:
			# the overlay stays drawn (it is on the root, above the scene).
			get_tree().change_scene_to_packed(packed)
		"settle":
			_settle += delta
			_progress = minf(98.0, _progress + delta * 25.0)
			var world := get_tree().current_scene
			var ready_world := world != null and "local_player" in world and is_instance_valid(world.get("local_player"))
			if ready_world:
				_status.text = "Entering the valley…"
			if (ready_world and _settle > 0.6 and _shown >= MIN_SHOW) or _settle > 12.0:
				_progress = 100.0
				_phase = "fade"
				_t = 0.0
		"fade":
			_root.modulate.a = clampf(1.0 - _t / 0.6, 0.0, 1.0)
			if _t >= 0.6:
				queue_free()
		"fallback":
			_phase = "settle"
			get_tree().change_scene_to_file(_path)
	if _phase != "fade":
		_bar.value = lerpf(_bar.value, _progress, minf(1.0, delta * 6.0))


class ShadeRect extends Control:
	func _init() -> void:
		mouse_filter = Control.MOUSE_FILTER_IGNORE
	func _draw() -> void:
		var top := Color(0, 0, 0, 0.0)
		var bottom := Color(0.0, 0.0, 0.02, 0.88)
		var y0 := size.y * 0.45
		draw_polygon(PackedVector2Array([Vector2(0, y0), Vector2(size.x, y0), Vector2(size.x, size.y), Vector2(0, size.y)]),
			PackedColorArray([top, top, bottom, bottom]))


class Spinner extends Control:
	var _a := 0.0
	func _init() -> void:
		mouse_filter = Control.MOUSE_FILTER_IGNORE
	func _process(delta: float) -> void:
		_a += delta * 2.4
		queue_redraw()
	func _draw() -> void:
		var c := size * 0.5
		var r := minf(size.x, size.y) * 0.42
		draw_arc(c, r, 0, TAU, 48, Color(HudKit.GOLD.r, HudKit.GOLD.g, HudKit.GOLD.b, 0.25), 2.0, true)
		draw_arc(c, r, _a, _a + 1.6, 24, HudKit.GOLD_HI, 3.0, true)
		draw_arc(c, r * 0.6, -_a * 1.3, -_a * 1.3 + 1.1, 18, HudKit.GOLD, 2.0, true)
