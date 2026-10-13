extends Control
class_name HudQuestScroll

## The quest scroll: the active quest written out on parchment - the story, the
## objective with its progress and the reward. Opened from the tracker row,
## closed with the seal button, a click outside it or Esc.

var _card: PanelContainer
var _title: Label
var _story: Label
var _objective: Label
var _reward: Label

func _init() -> void:
	name = "QuestScroll"
	set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	visible = false

func _ready() -> void:
	var backdrop := ColorRect.new()
	backdrop.color = Color(0, 0, 0, 0.35)
	backdrop.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	backdrop.mouse_filter = Control.MOUSE_FILTER_STOP
	backdrop.gui_input.connect(func(e):
		if e is InputEventMouseButton and e.pressed:
			close())
	add_child(backdrop)
	_card = PanelContainer.new()
	_card.add_theme_stylebox_override("panel", HudKit.parchment())
	add_child(_card)
	var m := MarginContainer.new()
	for side in ["left", "right"]:
		m.add_theme_constant_override("margin_" + side, 34)
	m.add_theme_constant_override("margin_top", 26)
	m.add_theme_constant_override("margin_bottom", 22)
	_card.add_child(m)
	var col := VBoxContainer.new()
	col.add_theme_constant_override("separation", 12)
	m.add_child(col)
	var ink := Color(0.22, 0.13, 0.05)
	_title = Label.new()
	_title.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_title.add_theme_font_override("font", HudKit.deco())
	_title.add_theme_font_size_override("font_size", 26)
	_title.add_theme_color_override("font_color", Color(0.36, 0.12, 0.05))
	col.add_child(_title)
	col.add_child(_rule(ink))
	_story = _ink_label(17, ink)
	col.add_child(_story)
	var obj_head := _ink_label(14, Color(0.42, 0.25, 0.08))
	obj_head.text = "OBJECTIVE"
	obj_head.autowrap_mode = TextServer.AUTOWRAP_OFF
	obj_head.add_theme_font_override("font", HudKit.title())
	col.add_child(obj_head)
	_objective = _ink_label(18, ink)
	_objective.add_theme_font_override("font", HudKit.bold())
	col.add_child(_objective)
	var rew_head := _ink_label(14, Color(0.42, 0.25, 0.08))
	rew_head.text = "REWARD"
	rew_head.autowrap_mode = TextServer.AUTOWRAP_OFF
	rew_head.add_theme_font_override("font", HudKit.title())
	col.add_child(rew_head)
	_reward = _ink_label(17, ink)
	col.add_child(_reward)
	col.add_child(_rule(ink))
	var close_row := HBoxContainer.new()
	close_row.alignment = BoxContainer.ALIGNMENT_CENTER
	col.add_child(close_row)
	var close_btn := Button.new()
	close_btn.text = "Close"
	close_btn.focus_mode = Control.FOCUS_NONE
	close_btn.custom_minimum_size = Vector2(140, 36)
	var seal := StyleBoxFlat.new()
	seal.bg_color = Color(0.48, 0.09, 0.07)
	seal.border_color = Color(0.25, 0.04, 0.03)
	seal.set_border_width_all(2)
	seal.set_corner_radius_all(18)
	var seal_hover := seal.duplicate() as StyleBoxFlat
	seal_hover.bg_color = Color(0.6, 0.13, 0.09)
	close_btn.add_theme_stylebox_override("normal", seal)
	close_btn.add_theme_stylebox_override("hover", seal_hover)
	close_btn.add_theme_stylebox_override("pressed", seal)
	close_btn.add_theme_font_override("font", HudKit.title())
	close_btn.add_theme_font_size_override("font_size", 15)
	close_btn.add_theme_color_override("font_color", Color(1, 0.9, 0.75))
	close_btn.pressed.connect(close)
	close_row.add_child(close_btn)
	get_viewport().size_changed.connect(_layout)

func _ink_label(size: int, colour: Color) -> Label:
	var l := Label.new()
	l.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	l.custom_minimum_size.x = 452.0
	l.add_theme_font_override("font", HudKit.body())
	l.add_theme_font_size_override("font_size", size)
	l.add_theme_color_override("font_color", colour)
	return l

func _rule(colour: Color) -> ColorRect:
	var r := ColorRect.new()
	r.color = Color(colour.r, colour.g, colour.b, 0.45)
	r.custom_minimum_size = Vector2(0, 2)
	return r

func _layout() -> void:
	var canvas := get_viewport().get_visible_rect().size
	var w := minf(520.0, canvas.x - 40.0)
	for l in [_title, _story, _objective, _reward]:
		(l as Control).custom_minimum_size.x = w - 68.0
	_card.custom_minimum_size = Vector2(w, 0)
	_card.reset_size()
	await get_tree().process_frame
	_card.reset_size()
	_card.position = ((canvas - _card.size) * 0.5).floor()

func open() -> void:
	refresh()
	show()
	_layout()
	UIFocus.block(self)
	var audio := get_node_or_null("/root/AudioManager")
	if audio != null and audio.has_method("play_sound_at"):
		audio.call("play_sound_at", "ui_quest", Vector3.ZERO, null, true)

func close() -> void:
	hide()
	UIFocus.unblock(self)

func is_open() -> bool:
	return visible

func refresh() -> void:
	if not has_node("/root/QuestManager"):
		return
	if QuestManager.is_all_done():
		_title.text = "Graduate of Hogwarts"
		_story.text = "Every task the professors set you is done. Explore the valley, hunt the Dark Monoliths and refine your wand."
		_objective.text = "—"
		_reward.text = "—"
		return
	var q: Dictionary = QuestManager.current_quest()
	_title.text = String(q.get("title", "Quest"))
	_story.text = String(q.get("desc", ""))
	var n := mini(int(QuestManager.progress), int(q.get("count", 1)))
	_objective.text = "%s   (%d / %d)" % [q.get("name", ""), n, int(q.get("count", 1))]
	_reward.text = "%d experience  ·  %d Galleons" % [int(q.get("reward_exp", 0)), int(q.get("reward_gold", 0))]
	if int(q.get("reward_house_rep", 0)) > 0:
		var house := String(QuestManager.player_ref.house) if is_instance_valid(QuestManager.player_ref) else "House"
		_reward.text += "  ·  %d %s reputation" % [int(q.get("reward_house_rep", 0)), house]
