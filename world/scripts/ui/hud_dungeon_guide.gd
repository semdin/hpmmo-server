extends HudWindow
class_name HudDungeonGuide

## The dungeon guide (K): every dungeon, and for the chosen one and difficulty
## what the character has done there (clear and medal, best time, final
## chests left today), whether the difficulty is open to them, this week's
## curses, and the week's fastest runs. The authority answers each choice with
## a `guide` dungeon event (SimNet.dungeon_guide); the curses and the rules
## come from the shared data.

const MEDAL_NAMES := {3: "Gold", 2: "Silver", 1: "Bronze", 0: "Cleared"}  # i18n

var player: Node = null
## Set by the HUD: "Show the way" lays the route to the dungeon's gate.
var waypoints: WaypointGuide = null
var dungeon_id := ""
var difficulty := "normal"
var _guide: Dictionary = {}

var _list: VBoxContainer
var _heading: Label
var _band: Label
var _tabs: HBoxContainer
var _facts: GridContainer
var _board: VBoxContainer

func _init() -> void:
	super._init("Dungeon Guide", Vector2(820, 620))
	name = "DungeonGuide"

func _ready() -> void:
	super._ready()
	var split := HBoxContainer.new()
	split.add_theme_constant_override("separation", 14)
	split.size_flags_vertical = Control.SIZE_EXPAND_FILL
	body.add_child(split)
	_list = VBoxContainer.new()
	_list.custom_minimum_size = Vector2(210, 0)
	_list.add_theme_constant_override("separation", 6)
	split.add_child(_list)
	for id in HPMaps.dungeons().keys():
		var dungeon: Dictionary = HPMaps.dungeons()[id]
		var b := HudKit.button("%s\n%s" % [I18n.t(String(dungeon.get("display", id))),
			tr("Levels %d-%d") % [int(dungeon.get("level_min", 1)), int(dungeon.get("level_max", 1))]], 14)
		b.name = "Dungeon_" + String(id)
		b.toggle_mode = true
		b.custom_minimum_size = Vector2(0, 54)
		b.pressed.connect(_pick_dungeon.bind(String(id)))
		_list.add_child(b)
	var right := VBoxContainer.new()
	right.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	right.add_theme_constant_override("separation", 8)
	split.add_child(right)
	_heading = HudKit.label("", 22, HudKit.GOLD_HI, HudKit.title(), 4)
	right.add_child(_heading)
	_band = HudKit.label("", 13, HudKit.TEXT_DIM, HudKit.body(), 3)
	right.add_child(_band)
	var way := HudKit.button(tr("Show the way to the gate"), 13)
	way.name = "ShowWay"
	way.size_flags_horizontal = Control.SIZE_SHRINK_BEGIN
	way.pressed.connect(_show_way)
	right.add_child(way)
	_tabs = HBoxContainer.new()
	_tabs.add_theme_constant_override("separation", 6)
	right.add_child(_tabs)
	for id in HPRules.DUNGEON_DIFFICULTIES:
		var tab := HudKit.button(I18n.t(String(HPRules.dungeon_difficulty(id).get("display", id))), 13)
		tab.name = "Tab_" + id
		tab.toggle_mode = true
		tab.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		var colour: Color = HudDungeon.COLOURS[id]
		tab.add_theme_color_override("font_color", colour)
		tab.add_theme_color_override("font_pressed_color", Color.WHITE)
		var chosen := HudKit.button_box("pressed").duplicate() as StyleBoxFlat
		chosen.bg_color = colour.darkened(0.62)
		chosen.border_color = colour
		chosen.set_border_width_all(2)
		tab.add_theme_stylebox_override("pressed", chosen)
		tab.add_theme_stylebox_override("hover_pressed", chosen)
		tab.pressed.connect(_pick_difficulty.bind(String(id)))
		_tabs.add_child(tab)
	var card := PanelContainer.new()
	card.add_theme_stylebox_override("panel", HudFloo._card_box(HudKit.NAVY_LT, HudKit.GOLD_DK, 0.9))
	right.add_child(card)
	_facts = GridContainer.new()
	_facts.columns = 2
	_facts.add_theme_constant_override("h_separation", 14)
	_facts.add_theme_constant_override("v_separation", 4)
	card.add_child(_facts)
	right.add_child(HudDungeon.section(tr("This week's fastest")))
	var scroll := ScrollContainer.new()
	scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
	scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	right.add_child(scroll)
	_board = VBoxContainer.new()
	_board.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_board.add_theme_constant_override("separation", 3)
	scroll.add_child(_board)
	var note := HudKit.label(tr("Curses and boards turn every Monday at 06:00."), 12, HudKit.TEXT_DIM, HudKit.body(), 2)
	right.add_child(note)
	SimAuthority.dungeon_event.connect(_on_event)

func open() -> void:
	if dungeon_id == "" and not HPMaps.dungeons().is_empty():
		dungeon_id = String(HPMaps.dungeons().keys()[0])
	super.open()
	_ask()
	_refresh()

## The dungeon's gates (portals into its map from the shared world): the one
## fewest maps away, then the nearest, gets the waypoint route.
func _show_way() -> void:
	var dungeon := HPMaps.dungeons().get(dungeon_id, {}) as Dictionary
	if waypoints == null or not is_instance_valid(player) or dungeon.is_empty():
		return
	var here := waypoints.current_map()
	var best: Dictionary = {}
	var best_score := INF
	for entry in HPMaps.portals():
		var portal: Dictionary = entry
		if String(portal.get("to_map", "")) != String(dungeon.get("map", "")) or HPMaps.is_instanced(String(portal.get("map_id", ""))):
			continue
		var steps := WaypointGuide.hops(here, String(portal["map_id"]))
		if steps < 0:
			continue
		var c: Array = (portal.get("trigger", {}) as Dictionary).get("center", [0, 0, 0])
		var at := Vector3(float(c[0]), float(c[1]), float(c[2]))
		var score := float(steps) * 100000.0
		if steps == 0:
			score += (player as Node3D).global_position.distance_to(at)
		else:
			score += at.distance_to(HPMaps.spawn_point(String(portal["map_id"]), "default"))
		if score < best_score:
			best_score = score
			best = portal
	if best.is_empty():
		return
	var c: Array = (best.get("trigger", {}) as Dictionary).get("center", [0, 0, 0])
	waypoints.set_target(String(best["map_id"]), Vector3(float(c[0]), float(c[1]), float(c[2])))
	close()

func _pick_dungeon(id: String) -> void:
	dungeon_id = id
	_ask()
	_refresh()

func _pick_difficulty(id: String) -> void:
	difficulty = id
	_ask()
	_refresh()

func _ask() -> void:
	if is_instance_valid(player) and dungeon_id != "":
		SimNet.dungeon_guide(player, dungeon_id, difficulty)

func _on_event(uid: int, event: Dictionary) -> void:
	if uid != SimAuthority.local_uid and SimAuthority.local_uid != 0:
		return
	if String(event.get("kind", "")) != "guide":
		return
	if String(event.get("dungeon", "")) == dungeon_id and String(event.get("difficulty", "")) == difficulty:
		_guide = event
	elif not _guide.is_empty():
		_guide["records"] = event.get("records", {})
	if visible:
		_refresh()

func _refresh() -> void:
	if _facts == null:
		return
	var dungeon := HPMaps.dungeons().get(dungeon_id, {}) as Dictionary
	_heading.text = I18n.t(String(dungeon.get("display", dungeon_id)))
	_band.text = tr("Levels %d-%d · 1-%d players") % [int(dungeon.get("level_min", 1)),
		int(dungeon.get("level_max", 1)), int(HPRules.dungeon_group().get("max_party", 5))]
	for b in _list.get_children():
		(b as Button).set_pressed_no_signal(String(b.name) == "Dungeon_" + dungeon_id)
	for tab in _tabs.get_children():
		(tab as Button).set_pressed_no_signal(String(tab.name) == "Tab_" + difficulty)
	var mine: Dictionary = (_guide.get("records", {}) as Dictionary).get(dungeon_id, {})
	var cleared: Dictionary = mine.get("cleared", {})
	for tab in _tabs.get_children():
		var id := String(tab.name).trim_prefix("Tab_")
		tab.modulate.a = 1.0 if HPRules.dungeon_unlocked(cleared, id) else 0.45
	for child in _facts.get_children():
		child.queue_free()
	var rules := HPRules.dungeon_difficulty(difficulty)
	if not HPRules.dungeon_unlocked(cleared, difficulty):
		var after := String(rules.get("unlock_after", ""))
		var need := I18n.t(String(HPRules.dungeon_difficulty(after).get("display", after)))
		var medal := String(rules.get("unlock_medal", ""))
		_fact(tr("Locked"), (tr("clear %s with a %s medal first") % [need, tr(medal.capitalize())]) if medal != "" \
			else (tr("clear %s first") % need), HudKit.RED)
	var rank := int(cleared.get(difficulty, -1))
	_fact(tr("Your clear"), tr(String(MEDAL_NAMES.get(rank, "Not yet"))) if rank >= 0 else tr("Not yet"),
		HudDungeonRun.MEDAL_TINTS.get({3: "gold", 2: "silver", 1: "bronze"}.get(rank, ""), HudKit.PARCHMENT))
	var best: Dictionary = mine.get("best", {})
	_fact(tr("Your best"), HudDungeon._clock(float(best[difficulty])) if best.has(difficulty) else "-")
	var left := int((mine.get("rights", {}) as Dictionary).get(difficulty, -1))
	_fact(tr("Final chest"), tr("unlimited") if left < 0 else tr("%d left today") % left)
	var par := float(dungeon.get("par_s", 1200)) * float(rules.get("par_mult", 1.0))
	_fact(tr("Gold medal"), tr("full clear within %s") % HudDungeon._clock(par))
	for id in HPRules.dungeon_week_affixes(int(rules.get("affixes", 0))):
		var curse := HPRules.dungeon_affix(String(id))
		_fact(tr("Curse"), "%s - %s" % [I18n.t(String(curse.get("display", id))), I18n.t(String(curse.get("desc", "")))],
			Color(0.86, 0.62, 1.0))
	_fill_board(_guide.get("runs", []) if String(_guide.get("dungeon", "")) == dungeon_id and String(_guide.get("difficulty", "")) == difficulty else [])

func _fact(key: String, value: String, colour: Color = HudKit.PARCHMENT) -> void:
	_facts.add_child(HudKit.label(key, 13, HudKit.TEXT_DIM, HudKit.body(), 2))
	var v := HudKit.label(value, 14, colour, HudKit.bold(), 2)
	v.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	v.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_facts.add_child(v)

func _fill_board(runs: Array) -> void:
	for child in _board.get_children():
		child.queue_free()
	if runs.is_empty():
		_board.add_child(HudKit.label(tr("No full clear this week yet - the first one sets the record."), 13, HudKit.TEXT_DIM, HudKit.body(), 2))
		return
	for i in runs.size():
		var run: Dictionary = runs[i]
		var row := HBoxContainer.new()
		row.add_theme_constant_override("separation", 10)
		_board.add_child(row)
		var tint: Color = HudDungeonRun.MEDAL_TINTS.get(String(run.get("medal", "")), HudKit.TEXT)
		row.add_child(_cell("%d." % (i + 1), 34, HudKit.GOLD_HI if i == 0 else HudKit.TEXT))
		row.add_child(_cell(HudDungeon._clock(float(run.get("seconds", 0.0))), 60, tint))
		var names: Array[String] = []
		for p in run.get("party", []):
			names.append("%s (%d)" % [String(p.get("name", "?")), int(p.get("level", 1))])
		var who := _cell(", ".join(PackedStringArray(names)), 0, HudKit.PARCHMENT)
		who.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		who.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
		row.add_child(who)
		row.add_child(_cell(tr("%d deaths") % int(run.get("deaths", 0)), 70, HudKit.TEXT_DIM))

func _cell(text: String, width: float, colour: Color) -> Label:
	var label := HudKit.label(text, 14, colour, HudKit.body(), 2)
	label.custom_minimum_size = Vector2(width, 0)
	return label
