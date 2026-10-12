extends VBoxContainer
class_name HudTracker

## The objective tracker under the minimap (Metin2 style): a collapsible header
## and one compact row per objective - a scroll for the active quest, a book for
## the training guide. A row shows the name and the progress only; clicking it
## opens the full text (the quest on a parchment scroll, the guide in its
## window). Collapsed, only the header remains, so nothing sits on screen that
## the player has not asked for. The collapsed state is remembered.

signal quest_opened
signal guide_opened

const WIDTH := 250.0
const STATE_PATH := "user://tracker.cfg"

var onboarding: Node = null
var collapsed := false
var _header: Button
var _rows: VBoxContainer
var _quest_row: Button
var _guide_row: Button
var _poll := 0.0

func _init() -> void:
	name = "Tracker"
	add_theme_constant_override("separation", 4)
	custom_minimum_size = Vector2(WIDTH, 0)
	mouse_filter = Control.MOUSE_FILTER_IGNORE

func _ready() -> void:
	var cfg := ConfigFile.new()
	if cfg.load(STATE_PATH) == OK:
		collapsed = bool(cfg.get_value("tracker", "collapsed", false))
	_header = Button.new()
	_header.name = "Header"
	_header.flat = true
	_header.focus_mode = Control.FOCUS_NONE
	_header.alignment = HORIZONTAL_ALIGNMENT_LEFT
	_header.custom_minimum_size = Vector2(WIDTH, 26)
	_header.add_theme_font_override("font", HudKit.title())
	_header.add_theme_font_size_override("font_size", 14)
	_header.add_theme_color_override("font_color", HudKit.GOLD_LT)
	_header.add_theme_color_override("font_hover_color", HudKit.GOLD_HI)
	_header.add_theme_color_override("font_outline_color", Color(0, 0, 0, 0.9))
	_header.add_theme_constant_override("outline_size", 4)
	_header.tooltip_text = "Show or hide the objectives"
	_header.pressed.connect(toggle_collapsed)
	add_child(_header)
	_rows = VBoxContainer.new()
	_rows.add_theme_constant_override("separation", 4)
	add_child(_rows)
	_quest_row = _make_row("ui_quest")
	_quest_row.pressed.connect(func(): quest_opened.emit())
	_rows.add_child(_quest_row)
	_guide_row = _make_row("ui_journal")
	_guide_row.pressed.connect(func(): guide_opened.emit())
	_rows.add_child(_guide_row)
	if has_node("/root/QuestManager"):
		QuestManager.quest_updated.connect(refresh)
	refresh()

func _make_row(icon_id: String) -> Button:
	var b := Button.new()
	b.focus_mode = Control.FOCUS_NONE
	b.custom_minimum_size = Vector2(WIDTH, 46)
	b.clip_text = true
	b.alignment = HORIZONTAL_ALIGNMENT_LEFT
	b.icon = UITheme.chrome_at(icon_id, 30.0)
	b.add_theme_constant_override("h_separation", 8)
	var normal := StyleBoxFlat.new()
	normal.bg_color = Color(0.031, 0.043, 0.071, 0.55)
	normal.border_color = Color(HudKit.GOLD.r, HudKit.GOLD.g, HudKit.GOLD.b, 0.35)
	normal.border_width_left = 2
	normal.set_corner_radius_all(3)
	normal.content_margin_left = 8
	normal.content_margin_right = 6
	normal.content_margin_top = 4
	normal.content_margin_bottom = 4
	var hover := normal.duplicate() as StyleBoxFlat
	hover.bg_color = Color(0.063, 0.082, 0.129, 0.78)
	hover.border_color = HudKit.GOLD_LT
	b.add_theme_stylebox_override("normal", normal)
	b.add_theme_stylebox_override("hover", hover)
	b.add_theme_stylebox_override("pressed", hover)
	b.add_theme_stylebox_override("focus", HudKit.empty())
	b.add_theme_font_override("font", HudKit.bold())
	b.add_theme_font_size_override("font_size", 14)
	b.add_theme_color_override("font_color", HudKit.PARCHMENT)
	b.add_theme_color_override("font_hover_color", HudKit.GOLD_HI)
	b.add_theme_color_override("font_outline_color", Color(0, 0, 0, 0.85))
	b.add_theme_constant_override("outline_size", 3)
	return b

func toggle_collapsed() -> void:
	collapsed = not collapsed
	var cfg := ConfigFile.new()
	cfg.set_value("tracker", "collapsed", collapsed)
	cfg.save(STATE_PATH)
	refresh()

func _process(delta: float) -> void:
	_poll -= delta
	if _poll <= 0.0:
		_poll = 0.5
		refresh()

func refresh() -> void:
	if _header == null:
		return
	_header.text = ("▸  OBJECTIVES" if collapsed else "▾  OBJECTIVES")
	_rows.visible = not collapsed
	# Quest row.
	if has_node("/root/QuestManager"):
		if QuestManager.is_all_done():
			_quest_row.text = "All quests complete"
			_quest_row.tooltip_text = "You have finished every quest."
		else:
			var q: Dictionary = QuestManager.current_quest()
			var n := mini(int(QuestManager.progress), int(q.get("count", 1)))
			var goal := String(q.get("name", ""))
			if goal.length() > 24:
				goal = goal.substr(0, 23).strip_edges() + "…"
			_quest_row.text = "%s\n%s  %d/%d" % [q.get("title", ""), goal, n, int(q.get("count", 1))]
			_quest_row.tooltip_text = "Click to read the quest scroll"
	else:
		_quest_row.visible = false
	# Guide row.
	if onboarding != null and is_instance_valid(onboarding):
		var total: int = onboarding.STEPS.size()
		var at: int = int(onboarding.current_index)
		if onboarding.is_complete():
			_guide_row.visible = false
		else:
			_guide_row.visible = true
			_guide_row.text = "Guide  (%d/%d)\n%s" % [at, total, String(onboarding.STEPS[at].title)]
			_guide_row.tooltip_text = "Click (or J) for the training guide"
	else:
		_guide_row.visible = false
