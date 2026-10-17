extends VBoxContainer
class_name HudTracker

## The objective tracker on the left edge of the screen: one small card per
## objective - the scroll for the active quest, the book for the training
## guide - showing only the icon with the title centred under it. Details live
## behind a click (the quest on its parchment scroll, the guide in its window).

signal quest_opened
signal guide_opened

const WIDTH := 150.0
const ICON := 40.0

var onboarding: Node = null
var _quest_row: Button
var _guide_row: Button
var _poll := 0.0

func _init() -> void:
	name = "Tracker"
	add_theme_constant_override("separation", 8)
	custom_minimum_size = Vector2(WIDTH, 0)
	mouse_filter = Control.MOUSE_FILTER_IGNORE

func _ready() -> void:
	_quest_row = _make_row("ui_quest")
	_quest_row.pressed.connect(func(): quest_opened.emit())
	add_child(_quest_row)
	_guide_row = _make_row("ui_journal")
	_guide_row.pressed.connect(func(): guide_opened.emit())
	add_child(_guide_row)
	if has_node("/root/QuestManager"):
		QuestManager.quest_updated.connect(refresh)
	refresh()

## A card: the icon centred, the title centred beneath it.
func _make_row(icon_id: String) -> Button:
	var b := Button.new()
	b.focus_mode = Control.FOCUS_NONE
	b.custom_minimum_size = Vector2(WIDTH, 0)
	var normal := StyleBoxFlat.new()
	normal.bg_color = Color(0.031, 0.043, 0.071, 0.55)
	normal.border_color = Color(HudKit.GOLD.r, HudKit.GOLD.g, HudKit.GOLD.b, 0.3)
	normal.set_border_width_all(1)
	normal.set_corner_radius_all(4)
	var hover := normal.duplicate() as StyleBoxFlat
	hover.bg_color = Color(0.063, 0.082, 0.129, 0.8)
	hover.border_color = HudKit.GOLD_LT
	b.add_theme_stylebox_override("normal", normal)
	b.add_theme_stylebox_override("hover", hover)
	b.add_theme_stylebox_override("pressed", hover)
	b.add_theme_stylebox_override("focus", HudKit.empty())
	var column := VBoxContainer.new()
	column.name = "Column"
	column.alignment = BoxContainer.ALIGNMENT_CENTER
	column.add_theme_constant_override("separation", 4)
	column.mouse_filter = Control.MOUSE_FILTER_IGNORE
	column.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	column.offset_top = 8
	column.offset_bottom = -8
	column.offset_left = 6
	column.offset_right = -6
	b.add_child(column)
	var icon := UITheme.icon_rect(icon_id, ICON)
	icon.name = "Icon"
	icon.size_flags_horizontal = Control.SIZE_SHRINK_CENTER
	icon.mouse_filter = Control.MOUSE_FILTER_IGNORE
	column.add_child(icon)
	var title := HudKit.label("", 14, HudKit.PARCHMENT, HudKit.bold(), 3)
	title.name = "Title"
	title.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	title.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	title.custom_minimum_size = Vector2(WIDTH - 12, 0)
	title.mouse_filter = Control.MOUSE_FILTER_IGNORE
	column.add_child(title)
	return b

func _set_row(row: Button, text: String) -> void:
	var title := row.get_node("Column/Title") as Label
	if title.text != text:
		title.text = text
	var column := row.get_node("Column") as Control
	row.custom_minimum_size.y = column.get_combined_minimum_size().y + 16.0

func _process(delta: float) -> void:
	_poll -= delta
	if _poll <= 0.0:
		_poll = 0.5
		refresh()

func refresh() -> void:
	if _quest_row == null:
		return
	if has_node("/root/QuestManager"):
		if QuestManager.is_all_done():
			_set_row(_quest_row, "All quests complete")
			_quest_row.tooltip_text = "You have finished every quest."
		else:
			var q: Dictionary = QuestManager.current_quest()
			var n := mini(int(QuestManager.progress), int(q.get("count", 1)))
			_set_row(_quest_row, String(q.get("title", "")))
			_quest_row.tooltip_text = "%s  %d/%d\nClick to read the quest scroll" % [String(q.get("name", "")), n, int(q.get("count", 1))]
	else:
		_quest_row.visible = false
	if onboarding != null and is_instance_valid(onboarding) and not onboarding.is_complete():
		var total: int = onboarding.STEPS.size()
		var at: int = int(onboarding.current_index)
		_guide_row.visible = true
		_set_row(_guide_row, "Guide")
		_guide_row.tooltip_text = "%s  (%d/%d)\nClick (or J) for the training guide" % [String(onboarding.STEPS[at].title), at, total]
	else:
		_guide_row.visible = false
