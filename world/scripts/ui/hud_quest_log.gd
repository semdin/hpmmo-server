extends HudWindow
class_name HudQuestLog

## The quest log (J): every open quest and every finished one waiting for its
## reward, as small parchment cards three to a row (QuestManager.log_entries
## order - finished first, then new, then the rest). A card shows the title,
## the objective with its live count and the reward; a finished card carries a
## Claim button, any card opens the full scroll. Read-only: claiming asks the
## authority (QuestManager.claim).

const COLUMNS := 3
const CARD_W := 196.0

## Opens one quest on the parchment scroll (set by hud.gd).
var open_scroll: Callable
var _grid: GridContainer
var _summary: Label
var _empty: Label
var _shown := ""
var _cards: Array = []   # [{panel, id}]
var _t := 0.0

func _init() -> void:
	super._init("Quests", Vector2(COLUMNS * (CARD_W + 10) + 48, 560))
	name = "QuestLog"
	modal = false

func _ready() -> void:
	super._ready()
	_summary = HudKit.label("", 14, HudKit.TEXT_DIM, HudKit.body(), 0)
	body.add_child(_summary)
	var scroll := ScrollContainer.new()
	scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
	scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	body.add_child(scroll)
	_grid = GridContainer.new()
	_grid.columns = COLUMNS
	_grid.add_theme_constant_override("h_separation", 10)
	_grid.add_theme_constant_override("v_separation", 10)
	scroll.add_child(_grid)
	_empty = HudKit.label(tr("No open quests. Level up to unlock more."), 15, HudKit.TEXT_DIM, HudKit.body(), 0)
	_empty.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	body.add_child(_empty)
	var hint := HudKit.label(tr("Click a card to read it  ·  finished quests pay when you claim them  ·  J / Esc: close"), 13, HudKit.TEXT_DIM, HudKit.body(), 0)
	hint.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	body.add_child(hint)
	if has_node("/root/QuestManager"):
		QuestManager.quest_updated.connect(func(): _shown = "")

func open() -> void:
	super.open()
	_shown = ""
	_refresh()

func _process(delta: float) -> void:
	if not visible:
		return
	_t += delta
	_refresh()
	var pulse := 0.5 + 0.5 * sin(_t * 5.0)
	for card in _cards:
		var id := String(card.id)
		var box := (card.panel as PanelContainer).get_theme_stylebox("panel") as StyleBoxFlat
		if box == null:
			continue
		if QuestManager.is_ready(id):
			box.border_color = Color(HudTracker.READY_GLOW, 0.4 + 0.6 * pulse)
		elif QuestManager.is_new(id):
			box.border_color = Color(HudTracker.NEW_GLOW, 0.4 + 0.6 * pulse)
		else:
			box.border_color = Color(HudKit.GOLD.r, HudKit.GOLD.g, HudKit.GOLD.b, 0.35)

func _refresh() -> void:
	if _grid == null or not has_node("/root/QuestManager"):
		return
	var entries: Array = QuestManager.log_entries()
	var key := str(entries.map(func(q): return [q.id, QuestManager.progress_of(String(q.id)), QuestManager.is_ready(String(q.id))]))
	if key == _shown:
		return
	_shown = key
	for child in _grid.get_children():
		child.queue_free()
	_cards.clear()
	var ready := 0
	for q in entries:
		if QuestManager.is_ready(String(q.id)):
			ready += 1
		_grid.add_child(_card(q))
	_empty.visible = entries.is_empty()
	_summary.text = tr("%d open  ·  %d ready to claim  ·  %d completed") % [entries.size() - ready, ready, QuestManager.done_count()]

func _card(q: Dictionary) -> Control:
	var id := String(q.get("id", ""))
	var panel := PanelContainer.new()
	panel.custom_minimum_size = Vector2(CARD_W, 0)
	var box := StyleBoxFlat.new()
	box.bg_color = Color(0.86, 0.78, 0.6)   # parchment
	box.set_border_width_all(2)
	box.border_color = Color(HudKit.GOLD.r, HudKit.GOLD.g, HudKit.GOLD.b, 0.35)
	box.set_corner_radius_all(4)
	box.content_margin_left = 10
	box.content_margin_right = 10
	box.content_margin_top = 8
	box.content_margin_bottom = 8
	panel.add_theme_stylebox_override("panel", box)
	panel.mouse_filter = Control.MOUSE_FILTER_STOP
	panel.mouse_default_cursor_shape = Control.CURSOR_POINTING_HAND
	panel.gui_input.connect(func(e):
		if e is InputEventMouseButton and e.pressed and e.button_index == MOUSE_BUTTON_LEFT and open_scroll.is_valid():
			open_scroll.call(id))
	var col := VBoxContainer.new()
	col.add_theme_constant_override("separation", 4)
	col.mouse_filter = Control.MOUSE_FILTER_IGNORE
	panel.add_child(col)
	var ink := Color(0.22, 0.13, 0.05)
	var tag := I18n.upper(tr("Ready")) if QuestManager.is_ready(id) else (I18n.upper(tr("New")) if QuestManager.is_new(id) else tr("Lv. %d") % int(q.get("level", 1)))
	var head := _ink(tag + "  ·  " + I18n.t(String(q.get("chapter", ""))), 11, Color(0.42, 0.25, 0.08), HudKit.title())
	col.add_child(head)
	var title := _ink(I18n.t(String(q.get("title", ""))), 16, Color(0.36, 0.12, 0.05), HudKit.bold())
	col.add_child(title)
	col.add_child(_ink(QuestManager.objective_text(q), 13, ink, HudKit.body()))
	var reward := tr("%d EXP  ·  %d Galleons") % [int(q.get("reward_exp", 0)), int(q.get("reward_gold", 0))]
	var items := QuestManager.reward_items_text(q)
	if items != "":
		reward += "\n" + items
	col.add_child(_ink(reward, 12, Color(0.4, 0.28, 0.1), HudKit.body()))
	if QuestManager.is_ready(id):
		var claim := HudKit.button(tr("Claim reward"), 14)
		claim.focus_mode = Control.FOCUS_NONE
		claim.pressed.connect(func(): QuestManager.claim(id))
		col.add_child(claim)
	_cards.append({"panel": panel, "id": id})
	return panel

func _ink(text: String, size: int, colour: Color, font: Font) -> Label:
	var l := Label.new()
	l.text = text
	l.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	l.custom_minimum_size = Vector2(CARD_W - 20, 0)
	l.add_theme_font_override("font", font)
	l.add_theme_font_size_override("font_size", size)
	l.add_theme_color_override("font_color", colour)
	l.mouse_filter = Control.MOUSE_FILTER_IGNORE
	return l
