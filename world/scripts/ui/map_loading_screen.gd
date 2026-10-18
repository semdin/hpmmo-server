extends CanvasLayer
class_name MapLoadingScreen

## The loading screen of a map transfer (castle door, dungeon copies, a login
## that resumes indoors). The same frame language as WorldLoader - key art, the
## gold bar, a tip and the turning rune - so stepping through a door looks like
## part of the game rather than a black flash, and the bar says what is
## happening: freeing the old map, loading the new one, waiting for the server.
##
##   await screen.open("HOGWARTS CASTLE", "Opening the great doors…")
##   screen.set_progress(40.0, "Lighting the torches…")
##   await screen.close()

const ART := "res://assets/branding/hpmmo_banner.jpg"
const FADE := 0.25
## Never flash: once shown, the screen stays at least this long.
const MIN_SHOW := 0.8
const TIPS := WorldLoader.TIPS

var _root: Control
var _title: Label
var _bar: ProgressBar
var _status: Label
var _tip: Label
var _target := 0.0
var _shown_at := 0
var _fading := 0.0     # +1 fading in, -1 fading out, 0 still

func _ready() -> void:
	layer = 90
	process_mode = Node.PROCESS_MODE_ALWAYS
	_root = Control.new()
	_root.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	_root.mouse_filter = Control.MOUSE_FILTER_STOP
	_root.modulate.a = 0.0
	_root.visible = false
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
		art.modulate = Color(0.62, 0.62, 0.68)
		_root.add_child(art)
	var shade := WorldLoader.ShadeRect.new()
	shade.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	_root.add_child(shade)
	_title = HudKit.label("", 52, HudKit.GOLD_HI, HudKit.deco(), 10)
	_title.set_anchors_preset(Control.PRESET_CENTER_BOTTOM)
	_title.offset_left = -560
	_title.offset_right = 560
	_title.offset_top = -220
	_title.offset_bottom = -150
	_title.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_title.add_theme_color_override("font_outline_color", Color(0.1, 0.06, 0.02, 0.95))
	_root.add_child(_title)
	_bar = ProgressBar.new()
	_bar.set_anchors_preset(Control.PRESET_CENTER_BOTTOM)
	_bar.offset_left = -360
	_bar.offset_right = 360
	_bar.offset_top = -132
	_bar.offset_bottom = -118
	_bar.min_value = 0
	_bar.max_value = 100
	_bar.show_percentage = false
	HudKit.style_gauge(_bar, Color(0.9, 0.68, 0.2))
	_root.add_child(_bar)
	_status = HudKit.label("", 16, HudKit.PARCHMENT, HudKit.title(), 4)
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
	_root.add_child(_tip)
	var rune := WorldLoader.Spinner.new()
	rune.set_anchors_preset(Control.PRESET_BOTTOM_RIGHT)
	rune.offset_left = -92
	rune.offset_top = -92
	rune.offset_right = -36
	rune.offset_bottom = -36
	_root.add_child(rune)

func is_open() -> bool:
	return _root != null and _root.visible

## Show the screen (fades in; awaitable). The world behind keeps running.
func open(title: String, status: String) -> void:
	_title.text = title
	_status.text = status
	_tip.text = "Tip: " + String(TIPS[randi() % TIPS.size()])
	_target = 5.0
	_bar.value = 0.0
	_root.visible = true
	_shown_at = Time.get_ticks_msec()
	_fading = 1.0
	while _root.modulate.a < 1.0 and is_inside_tree():
		await get_tree().process_frame

func set_progress(percent: float, status: String = "") -> void:
	_target = maxf(_target, clampf(percent, 0.0, 100.0))
	if status != "":
		_status.text = status

## Fill the bar, respect the minimum show time, fade out (awaitable).
func close() -> void:
	set_progress(100.0)
	while Time.get_ticks_msec() - _shown_at < int(MIN_SHOW * 1000.0) and is_inside_tree():
		await get_tree().process_frame
	_fading = -1.0
	while _root.visible and is_inside_tree():
		await get_tree().process_frame

func _process(delta: float) -> void:
	if _root == null or not _root.visible:
		return
	_bar.value = lerpf(_bar.value, _target, minf(1.0, delta * 8.0))
	if _fading != 0.0:
		_root.modulate.a = clampf(_root.modulate.a + _fading * delta / FADE, 0.0, 1.0)
		if _fading > 0.0 and _root.modulate.a >= 1.0:
			_fading = 0.0
		elif _fading < 0.0 and _root.modulate.a <= 0.0:
			_fading = 0.0
			_root.visible = false
