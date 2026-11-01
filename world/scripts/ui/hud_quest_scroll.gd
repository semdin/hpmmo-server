extends Control
class_name HudQuestScroll

## The quest scroll: one quest written out on a parchment between two wooden
## rods - the chapter, the quest's name, an ink flourish, the story with a red
## initial and the giver's signature, the objective (an ink box, the count and
## a hatched progress track) and the rewards with their icons. A red wax seal
## closes it; a finished quest also shows the gold seal that claims the
## reward. Opened from a tracker row, a quest-log card or an NPC's quest row;
## closed with the seal, the corner cross, a click outside or Esc. Reading a
## quest clears its "new" blink. It unrolls when it opens and shrinks to fit a
## short screen.
##
## Art: assets/ui/scroll (paper, rod, seals; prepared by
## art/ui/scroll/prepare_chatgpt_art.py).

const ART := "res://assets/ui/scroll/"
const WIDTH := 560.0
## Inside the paper, clear of its torn and scorched band and of the rods.
const PAD := Vector4(74, 54, 74, 70)   # left, top, right, bottom
const ROD_H := 78.0
const ROD_OVER := 44.0   # how far a rod reaches past the paper on each side
const ROD_INTO := 40.0   # how far a rod sits above (below) the paper's edge

const INK := Color("3a2310")
const INK_SOFT := Color("6b4a26")
const RED := Color("6e1a0e")

var quest_id := ""
var _scroll: Control
var _paper: PanelContainer
var _rods: Array = []
var _chapter: Label
var _chapter_row: HBoxContainer
var _title: Label
var _story: RichTextLabel
var _sign: Label
var _objective_block: VBoxContainer
var _box: InkBox
var _objective: Label
var _count: Label
var _track: InkTrack
var _reward_block: VBoxContainer
var _rewards: HFlowContainer
var _claim: Control
var _claim_btn: TextureButton
var _tween: Tween

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

	_scroll = Control.new()
	_scroll.name = "Scroll"
	_scroll.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(_scroll)
	_paper = PanelContainer.new()
	_paper.name = "Paper"
	var sheet := StyleBoxTexture.new()
	sheet.texture = _art("scroll_paper.png")   # scaled whole: slicing it seamed the scorched band
	sheet.content_margin_left = PAD.x
	sheet.content_margin_top = PAD.y
	sheet.content_margin_right = PAD.z
	sheet.content_margin_bottom = PAD.w
	_paper.add_theme_stylebox_override("panel", sheet)
	_paper.mouse_filter = Control.MOUSE_FILTER_STOP   # clicks on the paper do not close it
	_scroll.add_child(_paper)
	for i in 2:
		var rod := TextureRect.new()
		rod.texture = _art("scroll_rod.png")
		rod.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
		rod.stretch_mode = TextureRect.STRETCH_SCALE
		rod.mouse_filter = Control.MOUSE_FILTER_IGNORE
		_scroll.add_child(rod)
		_rods.append(rod)

	var col := VBoxContainer.new()
	col.add_theme_constant_override("separation", 0)
	col.custom_minimum_size.x = WIDTH - PAD.x - PAD.z
	_paper.add_child(col)

	_chapter_row = HBoxContainer.new()
	_chapter_row.alignment = BoxContainer.ALIGNMENT_CENTER
	_chapter_row.add_theme_constant_override("separation", 10)
	col.add_child(_chapter_row)
	_chapter_row.add_child(InkRule.new(true))
	_chapter = _ink("", 13, INK_SOFT, HudKit.title())
	_chapter_row.add_child(_chapter)
	_chapter_row.add_child(InkRule.new(false))
	_title = _ink("", 30, RED, HudKit.deco())
	_title.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_title.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	col.add_child(_title)
	var flourish := InkFlourish.new()
	flourish.custom_minimum_size = Vector2(0, 30)
	col.add_child(flourish)

	_story = RichTextLabel.new()
	_story.bbcode_enabled = true
	_story.fit_content = true
	_story.scroll_active = false
	_story.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_story.add_theme_font_override("normal_font", HudKit.body())
	_story.add_theme_font_size_override("normal_font_size", 17)
	_story.add_theme_color_override("default_color", INK)
	_story.add_theme_constant_override("line_separation", 4)
	col.add_child(_story)
	_sign = _ink("", 16, INK_SOFT, _slanted())
	_sign.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
	col.add_child(_sign)

	_objective_block = VBoxContainer.new()
	_objective_block.add_theme_constant_override("separation", 6)
	col.add_child(_objective_block)
	_objective_block.add_child(_section(tr("Objective")))
	var obj_row := HBoxContainer.new()
	obj_row.add_theme_constant_override("separation", 12)
	_objective_block.add_child(obj_row)
	_box = InkBox.new()
	_box.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	obj_row.add_child(_box)
	_objective = _ink("", 17, INK, HudKit.body())
	_objective.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_objective.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	obj_row.add_child(_objective)
	_count = _ink("", 15, INK_SOFT, HudKit.title())
	_count.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	obj_row.add_child(_count)
	var track_row := MarginContainer.new()
	track_row.add_theme_constant_override("margin_left", 30)
	_objective_block.add_child(track_row)
	_track = InkTrack.new()
	_track.custom_minimum_size = Vector2(0, 8)
	track_row.add_child(_track)

	_reward_block = VBoxContainer.new()
	_reward_block.add_theme_constant_override("separation", 6)
	col.add_child(_reward_block)
	_reward_block.add_child(_section(tr("Reward")))
	_rewards = HFlowContainer.new()
	_rewards.add_theme_constant_override("h_separation", 18)
	_rewards.add_theme_constant_override("v_separation", 8)
	_reward_block.add_child(_rewards)

	var actions := HBoxContainer.new()
	actions.alignment = BoxContainer.ALIGNMENT_CENTER
	actions.add_theme_constant_override("separation", 24)
	var gap := Control.new()
	gap.custom_minimum_size = Vector2(0, 18)
	col.add_child(gap)
	col.add_child(actions)
	var claim := _seal("seal_claim.png", tr("Claim reward"))
	_claim = claim[0]
	_claim_btn = claim[1]
	_claim_btn.pressed.connect(func():
		QuestManager.claim(quest_id)
		close())
	actions.add_child(_claim)
	var close_seal := _seal("seal_close.png", tr("Close"))
	(close_seal[1] as TextureButton).pressed.connect(close)
	actions.add_child(close_seal[0])

	var cross := Button.new()
	cross.name = "Cross"
	cross.text = "×"
	cross.flat = true
	cross.focus_mode = Control.FOCUS_NONE
	cross.tooltip_text = tr("Close")
	cross.mouse_default_cursor_shape = Control.CURSOR_POINTING_HAND
	cross.add_theme_font_override("font", HudKit.body())
	cross.add_theme_font_size_override("font_size", 24)
	cross.add_theme_color_override("font_color", INK_SOFT)
	cross.add_theme_color_override("font_hover_color", RED)
	cross.pressed.connect(close)
	_scroll.add_child(cross)   # over the paper's corner, placed in _layout
	get_viewport().size_changed.connect(_layout)

static func _art(file: String) -> Texture2D:
	return load(ART + file) if ResourceLoader.exists(ART + file) else null

func _ink(text: String, size: int, colour: Color, font: Font) -> Label:
	var l := Label.new()
	l.text = text
	l.mouse_filter = Control.MOUSE_FILTER_IGNORE
	l.add_theme_font_override("font", font)
	l.add_theme_font_size_override("font_size", size)
	l.add_theme_color_override("font_color", colour)
	return l

## The giver's signature: the body face leaned like handwriting.
static func _slanted() -> Font:
	var v := FontVariation.new()
	v.base_font = HudKit.body()
	v.variation_transform = Transform2D(Vector2(1, 0), Vector2(-0.22, 1), Vector2.ZERO)
	return v

## "OBJECTIVE ———" : a caption in small capitals and an ink rule fading right.
func _section(text: String) -> HBoxContainer:
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 10)
	row.custom_minimum_size.y = 34
	row.alignment = BoxContainer.ALIGNMENT_END
	var label := _ink(I18n.upper(text), 12, INK_SOFT, HudKit.title())
	label.size_flags_vertical = Control.SIZE_SHRINK_END
	row.add_child(label)
	var rule := InkFade.new()
	rule.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	rule.size_flags_vertical = Control.SIZE_SHRINK_END
	rule.custom_minimum_size = Vector2(0, 9)
	row.add_child(rule)
	return row

## A wax seal button with its caption under it; [holder, button].
func _seal(file: String, caption: String) -> Array:
	var holder := VBoxContainer.new()
	holder.add_theme_constant_override("separation", 4)
	var button := TextureButton.new()
	button.texture_normal = _art(file)
	button.ignore_texture_size = true
	button.stretch_mode = TextureButton.STRETCH_KEEP_ASPECT_CENTERED
	button.custom_minimum_size = Vector2(74, 74)
	button.size_flags_horizontal = Control.SIZE_SHRINK_CENTER
	button.focus_mode = Control.FOCUS_NONE
	button.tooltip_text = caption
	button.mouse_default_cursor_shape = Control.CURSOR_POINTING_HAND
	button.pivot_offset = Vector2(37, 37)
	button.mouse_entered.connect(func():
		button.scale = Vector2.ONE * 1.07
		button.rotation_degrees = -3.0
		button.modulate = Color(1.1, 1.1, 1.1))
	button.mouse_exited.connect(func():
		button.scale = Vector2.ONE
		button.rotation_degrees = 0.0
		button.modulate = Color.WHITE)
	holder.add_child(button)
	var label := _ink(I18n.upper(caption), 12, INK_SOFT, HudKit.title())
	label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	holder.add_child(label)
	return [holder, button]

## One reward: its icon (framed for an item), the amount, and a dim word.
func _reward(icon_id: String, amount: String, word: String, framed: bool) -> HBoxContainer:
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 7)
	var icon := TextureRect.new()
	icon.texture = UITheme.icon_for(icon_id)
	icon.custom_minimum_size = Vector2(28, 28)
	icon.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	icon.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
	icon.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	if framed:
		var frame := PanelContainer.new()
		var box := StyleBoxFlat.new()
		box.bg_color = Color(INK, 0.08)
		box.border_color = INK_SOFT
		box.set_border_width_all(1)
		box.set_corner_radius_all(3)
		box.set_content_margin_all(2)
		frame.add_theme_stylebox_override("panel", box)
		frame.size_flags_vertical = Control.SIZE_SHRINK_CENTER
		frame.add_child(icon)
		row.add_child(frame)
	else:
		row.add_child(icon)
	if amount != "":
		var n := _ink(amount, 16, INK, HudKit.body())
		n.size_flags_vertical = Control.SIZE_SHRINK_CENTER
		row.add_child(n)
	var w := _ink(word, 14 if amount != "" else 16, INK_SOFT if amount != "" else INK, HudKit.body())
	w.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	row.add_child(w)
	return row

func _layout() -> void:
	if _paper == null or not visible:
		return
	var canvas := get_viewport().get_visible_rect().size
	_paper.custom_minimum_size = Vector2(WIDTH, 0)
	_paper.reset_size()
	await get_tree().process_frame
	_paper.reset_size()
	var paper := _paper.size
	_paper.position = Vector2(ROD_OVER, ROD_INTO)
	var rods := [Vector2(0, 0), Vector2(0, ROD_INTO + paper.y - (ROD_H - ROD_INTO))]
	for i in 2:
		var rod := _rods[i] as TextureRect
		rod.position = rods[i]
		rod.size = Vector2(paper.x + ROD_OVER * 2.0, ROD_H)
	var cross := _scroll.get_node("Cross") as Control
	cross.size = Vector2(28, 28)
	cross.position = _paper.position + Vector2(paper.x - PAD.z + 4.0, PAD.y - 10.0)
	var whole := Vector2(paper.x + ROD_OVER * 2.0, paper.y + ROD_INTO * 2.0)
	_scroll.size = whole
	# A short screen shrinks the scroll rather than cutting it; it hangs from
	# its top rod (the pivot the unrolling uses too).
	var k := minf(1.0, (canvas.y - 32.0) / whole.y)
	_scroll.pivot_offset = Vector2(whole.x * 0.5, 0)
	_scroll.position = Vector2(floorf((canvas.x - whole.x) * 0.5), floorf((canvas.y - whole.y * k) * 0.5))
	_scroll.set_meta("fit", k)
	_scroll.scale = Vector2.ONE * k

## Open one quest (default: the top of the log). Silent: the quest sounds are
## for news (a new or finished quest), not for reading.
func open(id: String = "") -> void:
	quest_id = id if id != "" else String(QuestManager.current_quest().get("id", ""))
	refresh()
	# Over every other window: opened from the quest log (J), the scroll was
	# drawn behind it (the log is a later sibling).
	move_to_front()
	show()
	await _layout()
	_unroll()
	UIFocus.block(self)

## The scroll opens downwards from its top rod.
func _unroll() -> void:
	if _tween != null:
		_tween.kill()
	var k := float(_scroll.get_meta("fit", 1.0))
	_scroll.scale = Vector2(k, k * 0.08)
	_scroll.modulate.a = 0.0
	_tween = create_tween().set_parallel(true).set_trans(Tween.TRANS_CUBIC).set_ease(Tween.EASE_OUT)
	_tween.tween_property(_scroll, "scale", Vector2(k, k), 0.4)
	_tween.tween_property(_scroll, "modulate:a", 1.0, 0.15)

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
	var ready := not q.is_empty() and QuestManager.is_ready(quest_id)
	_claim.visible = ready
	for child in _rewards.get_children():
		_rewards.remove_child(child)
		child.queue_free()
	if q.is_empty():
		_chapter_row.visible = false
		_title.text = tr("No Open Quests")
		_set_story(tr("Every task open to you is done. Level up to unlock more, hunt the Dark Monoliths and refine your gear."))
		_sign.text = ""
		_objective_block.visible = false
		_reward_block.visible = false
		return
	var chapter := I18n.t(String(q.get("chapter", "")))
	_chapter_row.visible = chapter != ""
	_chapter.text = I18n.upper(chapter)
	_title.text = I18n.upper(I18n.t(String(q.get("title", "Quest"))))
	_set_story(I18n.t(String(q.get("desc", ""))))
	var giver := String(q.get("giver", ""))
	_sign.text = "— %s" % I18n.t(giver) if giver != "" else ""
	_objective_block.visible = true
	var count := int(q.get("count", 1))
	var progress := mini(QuestManager.progress_of(quest_id), count)
	_objective.text = I18n.t(String(q.get("name", "")))
	_objective.add_theme_color_override("font_color", RED if ready else INK)
	_box.checked = ready or progress >= count
	_count.visible = count > 1
	_count.text = "%d/%d" % [progress, count]
	_track.get_parent().visible = count > 1
	_track.fraction = float(progress) / float(maxi(1, count))
	_reward_block.visible = true
	var galleon_text: Callable = preload("res://scripts/ui/inventory_arcane.gd").galleon_text
	if int(q.get("reward_exp", 0)) > 0:
		_rewards.add_child(_reward("stat_exp", galleon_text.call(int(q.reward_exp)), tr("experience"), false))
	if int(q.get("reward_gold", 0)) > 0:
		_rewards.add_child(_reward("galleons", galleon_text.call(int(q.reward_gold)), tr("Galleons"), false))
	if int(q.get("reward_house_rep", 0)) > 0:
		var house := String(QuestManager.player_ref.house) if is_instance_valid(QuestManager.player_ref) else ""
		_rewards.add_child(_reward("house_" + house.to_lower(), str(int(q.reward_house_rep)), tr("%s reputation") % house, false))
	for item in q.get("reward_items", []):
		var id := String(item.get("id", ""))
		var amount := int(item.get("amount", 1))
		var name := I18n.t(String(HPEquipment.item(id).get("name", id)))
		_rewards.add_child(_reward(id, "", name if amount <= 1 else "%s ×%d" % [name, amount], true))

## The story with its first letter as a large red initial.
func _set_story(text: String) -> void:
	_story.clear()
	if text == "":
		return
	_story.push_font(HudKit.deco(), 34)
	_story.push_color(RED)
	_story.add_text(text.left(1))
	_story.pop()
	_story.pop()
	_story.add_text(text.substr(1))


## The objective's ink box, with a red tick once it is done.
class InkBox extends Control:
	var checked := false:
		set(value):
			checked = value
			queue_redraw()

	func _init() -> void:
		custom_minimum_size = Vector2(18, 18)
		mouse_filter = Control.MOUSE_FILTER_IGNORE

	func _draw() -> void:
		draw_rect(Rect2(Vector2(1, 1), size - Vector2(2, 2)), HudQuestScroll.INK, false, 2.0)
		if checked:
			var pts := PackedVector2Array([Vector2(3.5, 9.5), Vector2(7.5, 14), Vector2(16, 3)])
			draw_polyline(pts, HudQuestScroll.RED, 2.6, true)


## The objective's progress: an ink-outlined track, red hatching for the part done.
class InkTrack extends Control:
	var fraction := 0.0:
		set(value):
			fraction = clampf(value, 0.0, 1.0)
			queue_redraw()

	func _init() -> void:
		mouse_filter = Control.MOUSE_FILTER_IGNORE

	func _draw() -> void:
		var r := Rect2(Vector2.ZERO, size)
		draw_rect(r, Color(HudQuestScroll.INK, 0.06))
		var w := (size.x - 2.0) * fraction
		if w > 0.0:
			draw_rect(Rect2(1, 1, w, size.y - 2.0), Color(HudQuestScroll.RED, 0.55))
			var x := -size.y
			while x < w:
				draw_line(Vector2(maxf(1.0, x + 1.0), size.y - 1.0), Vector2(minf(w, x + size.y), 1.0), Color(HudQuestScroll.RED, 0.85), 2.0)
				x += 8.0
		draw_rect(r, HudQuestScroll.INK_SOFT, false, 1.0)


## The short rule each side of the chapter: a line ending in a small diamond.
class InkRule extends Control:
	var left := true

	func _init(p_left: bool) -> void:
		left = p_left
		custom_minimum_size = Vector2(64, 10)
		size_flags_vertical = Control.SIZE_SHRINK_CENTER
		mouse_filter = Control.MOUSE_FILTER_IGNORE

	func _draw() -> void:
		var y := size.y * 0.5
		var tip := size.x - 6.0 if left else 6.0
		draw_line(Vector2(0.0 if left else 12.0, y), Vector2(size.x - 12.0 if left else size.x, y), HudQuestScroll.INK_SOFT, 1.0)
		draw_colored_polygon(PackedVector2Array([Vector2(tip, y - 4), Vector2(tip + 4, y), Vector2(tip, y + 4), Vector2(tip - 4, y)]), HudQuestScroll.INK_SOFT)


## The section rule: ink fading out to the right.
class InkFade extends Control:
	func _init() -> void:
		mouse_filter = Control.MOUSE_FILTER_IGNORE

	func _draw() -> void:
		var y := floorf(size.y * 0.5)
		var steps := 20
		for i in steps:
			var t := float(i) / steps
			draw_line(Vector2(size.x * t, y), Vector2(size.x * (t + 1.0 / steps), y), Color(HudQuestScroll.INK, 0.45 * (1.0 - t)), 1.0)


## The flourish under the title: two mirrored ink waves round a red diamond.
class InkFlourish extends Control:
	func _init() -> void:
		mouse_filter = Control.MOUSE_FILTER_IGNORE

	func _draw() -> void:
		var c := Vector2(size.x * 0.5, size.y * 0.5)
		var half := 130.0
		var ink := HudQuestScroll.INK_SOFT
		draw_line(Vector2(c.x - half, c.y), Vector2(c.x - 30, c.y), ink, 1.2, true)
		draw_line(Vector2(c.x + 30, c.y), Vector2(c.x + half, c.y), ink, 1.2, true)
		for side in [-1.0, 1.0]:
			var upper := PackedVector2Array()
			var lower := PackedVector2Array()
			for i in 13:
				var t := float(i) / 12.0
				var x := c.x - 30.0 + 60.0 * t
				var y: float = 6.0 * sin(t * TAU) * side
				upper.append(Vector2(x, c.y + y))
				lower.append(Vector2(x, c.y - y * 0.6))
			draw_polyline(upper, ink, 1.2, true)
			draw_polyline(lower, Color(ink, 0.6), 1.0, true)
		draw_colored_polygon(PackedVector2Array([c + Vector2(0, -4), c + Vector2(4, 0), c + Vector2(0, 4), c + Vector2(-4, 0)]), HudQuestScroll.RED)
		for x in [c.x - half, c.x + half]:
			draw_circle(Vector2(x, c.y), 1.8, ink)
