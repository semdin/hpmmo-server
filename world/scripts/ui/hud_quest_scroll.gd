extends Control
class_name HudQuestScroll

## The quest scroll: one quest written out on parchment - the story, the
## objective with its progress and the reward. Opened from a tracker row or a
## quest-log card, closed with the seal button, a click outside it or Esc.
## Reading a quest clears its "new" blink; a finished quest shows a Claim
## button that asks the authority for the reward.

var quest_id := ""
var _card: PanelContainer
var _claim_btn: Button
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
	_claim_btn = close_btn.duplicate() as Button
	_claim_btn.text = "Claim reward"
	var gold := seal.duplicate() as StyleBoxFlat
	gold.bg_color = Color(0.62, 0.45, 0.1)
	gold.border_color = Color(0.35, 0.22, 0.03)
	var gold_hover := gold.duplicate() as StyleBoxFlat
	gold_hover.bg_color = Color(0.75, 0.56, 0.14)
	_claim_btn.add_theme_stylebox_override("normal", gold)
	_claim_btn.add_theme_stylebox_override("hover", gold_hover)
	_claim_btn.add_theme_stylebox_override("pressed", gold)
	_claim_btn.pressed.connect(func():
		QuestManager.claim(quest_id)
		close())
	close_row.add_child(_claim_btn)
	close_row.move_child(_claim_btn, 0)
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

## Open one quest (default: the top of the log). Silent: the quest sounds are
## for news (a new or finished quest), not for reading.
func open(id: String = "") -> void:
	quest_id = id if id != "" else String(QuestManager.current_quest().get("id", ""))
	refresh()
	# Over every other window: opened from the quest log (J), the scroll was
	# drawn behind it (the log is a later sibling).
	move_to_front()
	show()
	_layout()
	UIFocus.block(self)

func close() -> void:
	if visible and quest_id != "":
		QuestManager.mark_seen(quest_id)   # read: it stops blinking
	hide()
	UIFocus.unblock(self)

func is_open() -> bool:
	return visible

func refresh() -> void:
	if not has_node("/root/QuestManager"):
		return
	var q := HPRules.quest_by_id(quest_id)
	_claim_btn.visible = not q.is_empty() and QuestManager.is_ready(quest_id)
	if q.is_empty():
		_title.text = "No Open Quests"
		_story.text = "Every task open to you is done. Level up to unlock more, hunt the Dark Monoliths and refine your gear."
		_objective.text = "—"
		_reward.text = "—"
		return
	_title.text = String(q.get("title", "Quest"))
	if String(q.get("chapter", "")) != "":
		_title.text = "%s  ·  %s" % [String(q.get("chapter", "")), _title.text]
	_story.text = String(q.get("desc", ""))
	if String(q.get("giver", "")) != "":
		_story.text += "\n\n- %s" % String(q.get("giver", ""))
	_objective.text = QuestManager.objective_text(q)
	_reward.text = "%d experience  ·  %d Galleons" % [int(q.get("reward_exp", 0)), int(q.get("reward_gold", 0))]
	var items := QuestManager.reward_items_text(q)
	if items != "":
		_reward.text += "  ·  %s" % items
	if int(q.get("reward_house_rep", 0)) > 0:
		var house := String(QuestManager.player_ref.house) if is_instance_valid(QuestManager.player_ref) else "House"
		_reward.text += "  ·  %d %s reputation" % [int(q.get("reward_house_rep", 0)), house]
