extends VBoxContainer
class_name HudTracker

## The objective tracker on the left edge of the screen: one card per quest at
## the top of the log (QuestManager.log_entries - finished first, then new,
## then the rest), at most MAX_ROWS, each with its title and live count
## ("Defeat 6 Acromantulas 3/6"). A new (unread) quest pulses gold, a finished
## one pulses green until it is claimed: clicking a finished card claims the
## reward, clicking any other opens it on its parchment scroll. "More quests"
## opens the quest log (J) when the log holds more than fits here.

signal quest_opened(quest_id: String)
signal guide_opened

const WIDTH := 200.0
const ICON := 30.0
const MAX_ROWS := 3
const NEW_GLOW := Color(1.0, 0.82, 0.35)
const READY_GLOW := Color(0.45, 1.0, 0.55)

var onboarding: Node = null
var _rows: Array = []
var _row_ids: Array = []
var _more: Button
var _poll := 0.0
var _t := 0.0

func _init() -> void:
	name = "Tracker"
	add_theme_constant_override("separation", 6)
	custom_minimum_size = Vector2(WIDTH, 0)
	mouse_filter = Control.MOUSE_FILTER_IGNORE

func _ready() -> void:
	for i in MAX_ROWS:
		var row := _make_row()
		row.pressed.connect(_on_row_pressed.bind(i))
		add_child(row)
		_rows.append(row)
		_row_ids.append("")
	_more = Button.new()
	_more.flat = true
	_more.focus_mode = Control.FOCUS_NONE
	_more.text = tr("More quests (J)")
	_more.add_theme_font_override("font", HudKit.bold())
	_more.add_theme_font_size_override("font_size", 13)
	_more.add_theme_color_override("font_color", HudKit.GOLD_LT)
	_more.add_theme_color_override("font_hover_color", HudKit.GOLD_HI)
	_more.alignment = HORIZONTAL_ALIGNMENT_LEFT
	_more.pressed.connect(func(): guide_opened.emit())
	add_child(_more)
	if has_node("/root/QuestManager"):
		QuestManager.quest_updated.connect(refresh)
	refresh()

## A card: the scroll icon on the left, the title and the objective beside it.
func _make_row() -> Button:
	var b := Button.new()
	b.focus_mode = Control.FOCUS_NONE
	b.custom_minimum_size = Vector2(WIDTH, 0)
	var normal := StyleBoxFlat.new()
	normal.bg_color = Color(0.031, 0.043, 0.071, 0.62)
	normal.border_color = Color(HudKit.GOLD.r, HudKit.GOLD.g, HudKit.GOLD.b, 0.3)
	normal.set_border_width_all(1)
	normal.set_corner_radius_all(4)
	var hover := normal.duplicate() as StyleBoxFlat
	hover.bg_color = Color(0.063, 0.082, 0.129, 0.85)
	hover.border_color = HudKit.GOLD_LT
	b.add_theme_stylebox_override("normal", normal)
	b.add_theme_stylebox_override("hover", hover)
	b.add_theme_stylebox_override("pressed", hover)
	b.add_theme_stylebox_override("focus", HudKit.empty())
	var line := HBoxContainer.new()
	line.name = "Line"
	line.add_theme_constant_override("separation", 6)
	line.mouse_filter = Control.MOUSE_FILTER_IGNORE
	line.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	line.offset_top = 6
	line.offset_bottom = -6
	line.offset_left = 6
	line.offset_right = -6
	b.add_child(line)
	var icon := UITheme.icon_rect("ui_quest", ICON)
	icon.name = "Icon"
	icon.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	icon.mouse_filter = Control.MOUSE_FILTER_IGNORE
	line.add_child(icon)
	var column := VBoxContainer.new()
	column.name = "Column"
	column.add_theme_constant_override("separation", 1)
	column.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	column.mouse_filter = Control.MOUSE_FILTER_IGNORE
	line.add_child(column)
	var title := HudKit.label("", 13, HudKit.PARCHMENT, HudKit.bold(), 3)
	title.name = "Title"
	title.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	title.custom_minimum_size = Vector2(WIDTH - ICON - 24, 0)
	title.mouse_filter = Control.MOUSE_FILTER_IGNORE
	column.add_child(title)
	var objective := HudKit.label("", 12, HudKit.GOLD_LT, HudKit.body(), 3)
	objective.name = "Objective"
	objective.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	objective.custom_minimum_size = Vector2(WIDTH - ICON - 24, 0)
	objective.mouse_filter = Control.MOUSE_FILTER_IGNORE
	column.add_child(objective)
	return b

func _set_row(row: Button, title_text: String, objective_text: String) -> void:
	var title := row.get_node("Line/Column/Title") as Label
	var objective := row.get_node("Line/Column/Objective") as Label
	if title.text != title_text:
		title.text = title_text
	if objective.text != objective_text:
		objective.text = objective_text
	var column := row.get_node("Line") as Control
	row.custom_minimum_size.y = maxf(ICON, (row.get_node("Line/Column") as Control).get_combined_minimum_size().y) + 12.0
	column.queue_sort()

func _on_row_pressed(index: int) -> void:
	var id := String(_row_ids[index])
	if id == "":
		return
	if QuestManager.is_ready(id):
		QuestManager.claim(id)
	else:
		quest_opened.emit(id)

func _process(delta: float) -> void:
	_t += delta
	_poll -= delta
	if _poll <= 0.0:
		_poll = 0.5
		refresh()
	# New and finished quests pulse until they are read / claimed.
	var pulse := 0.5 + 0.5 * sin(_t * 5.0)
	for i in _rows.size():
		var row: Button = _rows[i]
		var id := String(_row_ids[i])
		if not row.visible or id == "":
			continue
		var glow := Color.WHITE
		if QuestManager.is_ready(id):
			glow = READY_GLOW
		elif QuestManager.is_new(id):
			glow = NEW_GLOW
		row.self_modulate = Color.WHITE.lerp(glow, pulse) if glow != Color.WHITE else Color.WHITE
		var box := row.get_theme_stylebox("normal") as StyleBoxFlat
		if box != null:
			box.border_color = Color(glow, 0.35 + 0.65 * pulse) if glow != Color.WHITE \
				else Color(HudKit.GOLD.r, HudKit.GOLD.g, HudKit.GOLD.b, 0.3)
			box.set_border_width_all(2 if glow != Color.WHITE else 1)

func refresh() -> void:
	if _rows.is_empty() or not has_node("/root/QuestManager"):
		return
	var entries: Array = QuestManager.log_entries()
	for i in _rows.size():
		var row: Button = _rows[i]
		if i >= entries.size():
			row.visible = i == 0
			_row_ids[i] = ""
			if i == 0:
				_set_row(row, tr("No open quests"), tr("Level up to unlock more"))
				row.tooltip_text = ""
			continue
		var q: Dictionary = entries[i]
		var id := String(q.get("id", ""))
		_row_ids[i] = id
		row.visible = true
		_set_row(row, I18n.t(String(q.get("title", ""))), QuestManager.objective_text(q))
		row.tooltip_text = tr("Click to claim the reward") if QuestManager.is_ready(id) else tr("Click to read the quest scroll")
	_more.visible = entries.size() > MAX_ROWS
	_more.text = tr("More quests (%d)  ·  J") % (entries.size() - MAX_ROWS)
