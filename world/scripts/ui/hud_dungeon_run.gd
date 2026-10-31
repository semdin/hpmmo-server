extends Control
class_name HudDungeonRun

## The local player's dungeon run on screen, driven by the copy's replicated
## run state (protocol v30):
##   - while the roster gathers, a line saying so; then the start countdown in
##     the middle of the screen (10 ... 1, "Go!") as the gate opens;
##   - the tracker on the right rail under the minimap: the run's curses, the
##     clock against the medal times, the clear, the bosses, the deaths and the
##     party's lives;
##   - at completion, the result window (HudDungeonResult).

const MEDAL_TINTS := {"gold": Color(0.92, 0.74, 0.30), "silver": Color(0.76, 0.80, 0.86), "bronze": Color(0.82, 0.54, 0.32)}

## Set by the HUD.
var result_window: HudDungeonResult = null

var _count: Label
var _wait: Label
var _go_at_ms := 0
var _last_count := 0
var _phase := ""
var _map := ""
var _state: Dictionary = {}
var _clock_base := 0.0
var _clock_at_ms := 0
var _shown_result := ""
var _pop_tween: Tween
var _controller: Node

var _panel: PanelContainer
var _title: Label
var _curses: Label
var _clock: Label
var _target: Label
var _medal_bar: MedalBar
var _clear: Label
var _clear_bar: MedalBar
var _bosses: VBoxContainer
var _deaths: Label

func _init() -> void:
	name = "DungeonRun"
	mouse_filter = Control.MOUSE_FILTER_IGNORE

func _ready() -> void:
	set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	_count = HudKit.label("", 96, HudKit.GOLD_HI, HudKit.deco(), 10)
	_count.name = "Countdown"
	_count.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_count.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	_count.set_anchors_preset(Control.PRESET_CENTER)
	_count.custom_minimum_size = Vector2(700, 140)
	_count.offset_left = -350
	_count.offset_right = 350
	_count.offset_top = -190
	_count.offset_bottom = -50
	_count.pivot_offset = Vector2(350, 70)
	_count.visible = false
	add_child(_count)
	_wait = HudKit.label("", 20, HudKit.GOLD_LT, HudKit.bold(), 5)
	_wait.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_wait.set_anchors_preset(Control.PRESET_CENTER_TOP)
	_wait.custom_minimum_size = Vector2(700, 40)
	_wait.offset_left = -350
	_wait.offset_right = 350
	_wait.offset_top = 210
	_wait.visible = false
	add_child(_wait)
	_build_tracker()
	SimAuthority.dungeon_state.connect(_on_state)

func _build_tracker() -> void:
	_panel = PanelContainer.new()
	_panel.name = "DungeonTracker"
	_panel.mouse_filter = Control.MOUSE_FILTER_IGNORE
	var box := StyleBoxFlat.new()
	box.bg_color = Color(0.031, 0.040, 0.067, 0.88)
	box.border_color = HudKit.GOLD_DK.lerp(HudKit.GOLD, 0.4)
	box.set_border_width_all(1)
	box.border_width_bottom = 2
	box.set_corner_radius_all(8)
	box.shadow_color = Color(0, 0, 0, 0.5)
	box.shadow_size = 8
	box.content_margin_left = 14
	box.content_margin_right = 14
	box.content_margin_top = 8
	box.content_margin_bottom = 10
	_panel.add_theme_stylebox_override("panel", box)
	# The right rail under the minimap (where a duel's plaque also sits).
	_panel.set_anchors_preset(Control.PRESET_TOP_RIGHT)
	_panel.grow_horizontal = Control.GROW_DIRECTION_BEGIN
	_panel.offset_right = -UITheme.EDGE
	_panel.offset_left = -UITheme.EDGE - UITheme.RIGHT_COL_W
	_panel.offset_top = 272
	_panel.visible = false
	add_child(_panel)
	var column := VBoxContainer.new()
	column.add_theme_constant_override("separation", 4)
	column.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_panel.add_child(column)
	_title = HudKit.label("", 14, HudKit.GOLD_LT, HudKit.title(), 4)
	_title.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	column.add_child(_title)
	_curses = HudKit.label("", 12, Color(0.86, 0.62, 1.0), HudKit.body(), 3)
	_curses.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	column.add_child(_curses)
	var clock_row := HBoxContainer.new()
	clock_row.mouse_filter = Control.MOUSE_FILTER_IGNORE
	column.add_child(clock_row)
	_clock = HudKit.label("0:00", 30, HudKit.PARCHMENT, HudKit.deco(), 5)
	_clock.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	clock_row.add_child(_clock)
	_target = HudKit.label("", 13, HudKit.TEXT_DIM, HudKit.body(), 3)
	_target.size_flags_vertical = Control.SIZE_SHRINK_END
	clock_row.add_child(_target)
	_medal_bar = MedalBar.new()
	column.add_child(_medal_bar)
	_clear = HudKit.label("", 13, HudKit.TEXT, HudKit.body(), 3)
	column.add_child(_clear)
	_clear_bar = MedalBar.new()
	_clear_bar.plain = Color(0.45, 0.82, 0.52)
	column.add_child(_clear_bar)
	_bosses = VBoxContainer.new()
	_bosses.add_theme_constant_override("separation", 0)
	_bosses.mouse_filter = Control.MOUSE_FILTER_IGNORE
	column.add_child(_bosses)
	_deaths = HudKit.label("", 13, HudKit.TEXT, HudKit.body(), 3)
	_deaths.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	column.add_child(_deaths)

## The map the local body is on: the map controller's word (it changes the
## moment a transfer lands), the player's record only before a world exists.
func _local_map() -> String:
	if not is_instance_valid(_controller):
		_controller = get_tree().root.find_child("MapController", true, false)
	if _controller != null:
		return String(_controller.get("current_map"))
	return String(SimAuthority.record_by_uid(SimAuthority.local_uid).get("map_id", ""))

## The run's copy is where the local body stands: only then is anything drawn.
func _tracking() -> bool:
	return _map != "" and _local_map() == _map \
		and not (HPMaps.dungeons().get(String(_state.get("dungeon", "")), {}) as Dictionary).is_empty()

func _on_state(map_id: String, state: Dictionary) -> void:
	# A copy's state reaches the players in it; one arriving while the body is
	# still on its way in is kept and drawn once the transfer lands.
	var record_map := String(SimAuthority.record_by_uid(SimAuthority.local_uid).get("map_id", ""))
	if SimAuthority.local_uid != 0 and map_id != _local_map() and map_id != record_map:
		return
	if map_id != _map:
		_shown_result = ""
	_map = map_id
	_state = state
	_clock_base = float(state.get("elapsed_s", 0.0))
	_clock_at_ms = Time.get_ticks_msec()
	var phase := String(state.get("phase", "running"))
	if phase == "gather":
		_wait.text = tr("Waiting for the party to arrive...")
	if phase == "countdown" and _phase != "countdown":
		_go_at_ms = Time.get_ticks_msec() + int(float(state.get("countdown_s", 0.0)) * 1000.0)
		_last_count = 0
	if phase == "running" and _phase == "countdown":
		_pop(I18n.upper(tr("Go!")), Color(0.55, 0.95, 0.6), 1.1)
		AudioManager.play_sound_at("ui_confirm", Vector3.ZERO, null, true)
	_phase = phase
	_refresh_tracker()
	if bool(state.get("complete", false)) and not (state.get("result", {}) as Dictionary).is_empty() \
			and _shown_result != map_id and result_window != null:
		_shown_result = map_id
		result_window.show_result(state)

func _process(_delta: float) -> void:
	# Out of the copy (the run over, or walked out) nothing of it stays on screen.
	var here := _tracking()
	_panel.visible = here
	_wait.visible = here and _phase == "gather"
	if not here:
		_count.visible = false
		return
	_tick_clock()
	if _phase != "countdown":
		return
	var left := int(ceil(float(_go_at_ms - Time.get_ticks_msec()) / 1000.0))
	if left > 0 and left != _last_count:
		_last_count = left
		_pop(str(left), HudKit.GOLD_HI if left > 3 else Color(1.0, 0.62, 0.35))
		AudioManager.play_sound_at("ui_button", Vector3.ZERO, null, true)

## Seconds on the run's clock now: the authority's last word, ticking on
## while the run is under way.
func _seconds() -> float:
	if _phase != "running" or bool(_state.get("complete", false)):
		return _clock_base
	return _clock_base + float(Time.get_ticks_msec() - _clock_at_ms) / 1000.0

func _tick_clock() -> void:
	var seconds := _seconds()
	_clock.text = HudDungeon._clock(seconds)
	var par := float(_state.get("par_s", 0.0))
	var medals := HPMaps.dungeon_rules("medals")
	var bronze := par * float(medals.get("bronze", 1.6))
	_medal_bar.fraction = clampf(seconds / maxf(1.0, bronze), 0.0, 1.0)
	_medal_bar.marks = [float(medals.get("gold", 1.0)) / float(medals.get("bronze", 1.6)),
		float(medals.get("silver", 1.3)) / float(medals.get("bronze", 1.6))]
	var target := ""
	var tint := HudKit.TEXT_DIM
	if bool(_state.get("broken", false)):
		target = tr("no medal")
	else:
		for id in ["gold", "silver", "bronze"]:
			var limit := par * float(medals.get(id, 0.0))
			if seconds <= limit:
				target = "%s %s" % [{"gold": tr("Gold"), "silver": tr("Silver"), "bronze": tr("Bronze")}[id], HudDungeon._clock(limit)]
				tint = MEDAL_TINTS[id]
				_medal_bar.plain = MEDAL_TINTS[id]
				break
		if target == "":
			target = tr("no medal")
			_medal_bar.plain = Color(0.5, 0.5, 0.55)
	_target.text = target
	_target.add_theme_color_override("font_color", tint)

func _refresh_tracker() -> void:
	var dungeon := HPMaps.dungeons().get(String(_state.get("dungeon", "")), {}) as Dictionary
	var difficulty := String(_state.get("difficulty", "normal"))
	_panel.visible = _tracking()
	if dungeon.is_empty():
		return
	_title.text = "%s - %s" % [I18n.upper(I18n.t(String(dungeon.get("display", "")))),
		I18n.t(String(HPRules.dungeon_difficulty(difficulty).get("display", "")))]
	_title.add_theme_color_override("font_color", HudDungeon.COLOURS.get(difficulty, HudKit.GOLD_LT))
	var names: Array[String] = []
	for id in _state.get("affixes", []):
		names.append(I18n.t(String(HPRules.dungeon_affix(String(id)).get("display", id))))
	_curses.text = " · ".join(PackedStringArray(names))
	_curses.visible = not names.is_empty()
	var forces := int(_state.get("forces", 0))
	var total := int(_state.get("forces_total", 0))
	var share := 1.0 if total <= 0 else minf(1.0, float(forces) / float(total))
	_clear.text = tr("Clear %d%% (%d / %d)") % [int(floor(share * 100.0)), forces, total]
	# Every boss down: the creatures still standing are all that holds the finish.
	var left := int(_state.get("left", -1))
	if left > 0 and not bool(_state.get("complete", false)):
		_clear.text += "\n" + tr("%d creature(s) left") % left
	_clear_bar.fraction = share
	for child in _bosses.get_children():
		child.queue_free()
	for boss in _state.get("bosses", []):
		var done := bool((boss as Dictionary).get("done", false))
		var line := HudKit.label(("✔ " if done else "○ ") + I18n.t(String(boss.get("name", ""))), 13,
			HudKit.GREEN if done else HudKit.TEXT, HudKit.body(), 3)
		_bosses.add_child(line)
	var deaths := int(_state.get("deaths", 0))
	var penalty := float(HPRules.dungeon_difficulty(difficulty).get("death_penalty_s", 0))
	var text := tr("Deaths %d") % deaths
	if penalty > 0.0 and deaths > 0:
		text += " " + tr("(+%d s)") % int(penalty * deaths)
	var lives := int(_state.get("lives_left", -1))
	if lives >= 0:
		text += " · " + tr("Lives %d / %d") % [lives, int(HPRules.dungeon_difficulty(difficulty).get("lives", 0))]
	_deaths.text = text
	_deaths.add_theme_color_override("font_color", HudKit.RED if bool(_state.get("broken", false)) else HudKit.TEXT)
	_tick_clock()

func _pop(text: String, colour: Color, hold := 0.8) -> void:
	_count.text = text
	_count.add_theme_color_override("font_color", colour)
	_count.visible = true
	_count.scale = Vector2(1.6, 1.6)
	_count.modulate.a = 1.0
	# One number at a time: the last second's fade must not run on into this
	# one's (a pop lasting past the next second hid every number after the first).
	if _pop_tween != null and _pop_tween.is_valid():
		_pop_tween.kill()
	_pop_tween = create_tween()
	_pop_tween.tween_property(_count, "scale", Vector2.ONE, 0.22).set_trans(Tween.TRANS_BACK).set_ease(Tween.EASE_OUT)
	_pop_tween.tween_interval(hold * 0.6)
	_pop_tween.tween_property(_count, "modulate:a", 0.0, hold * 0.4)


## A thin progress bar; `marks` (fractions) draw the medal lines across it.
class MedalBar extends Control:
	var plain := Color(0.92, 0.74, 0.30)
	var marks: Array = []
	var fraction := 0.0:
		set(v):
			if absf(v - fraction) > 0.0005:
				fraction = v
				queue_redraw()

	func _init() -> void:
		custom_minimum_size = Vector2(0, 7)
		mouse_filter = Control.MOUSE_FILTER_IGNORE

	func _draw() -> void:
		var r := Rect2(Vector2.ZERO, size)
		draw_rect(r, Color(0, 0, 0, 0.55))
		draw_rect(Rect2(Vector2.ZERO, Vector2(size.x * fraction, size.y)), plain.darkened(0.1))
		draw_rect(Rect2(Vector2.ZERO, Vector2(size.x * fraction, 1.0)), plain.lightened(0.35))
		for i in marks.size():
			var x := size.x * float(marks[i])
			draw_line(Vector2(x, -2), Vector2(x, size.y + 2), HudDungeonRun.MEDAL_TINTS["gold" if i == 0 else "silver"], 2.0)
