extends HudWindow
class_name HudDungeon

## The dungeon gate window (interact at a dungeon door, protocol v30). A banner
## with the dungeon's boss, its level band and the medal times; five
## difficulty cards (1-5 diamonds, each in its colour); for the chosen one the
## run for this party as chips (creature levels, power, what it needs, the gold
## medal, the final chest, the key) and this week's curses; the party at the
## gate with a status tag each (empty places up to the party cap); then the
## verdict and the leader's button that opens the ready check. A run of the
## party's that is still open offers its way back in instead. The authority
## decides everything (SimNet.dungeon_info / dungeon_start); the checks here
## only explain early what it would refuse. Its second tab is the seal shop:
## Zindan Muhru from finished runs buys keys, runes and potions (equipment op
## `seal_buy`).

const COLOURS := {
	"easy": Color(0.44, 0.81, 0.55),
	"normal": Color(0.50, 0.70, 0.94),
	"hard": Color(0.94, 0.65, 0.34),
	"very_hard": Color(0.94, 0.48, 0.45),
	"legendary": Color(0.77, 0.61, 1.0),
}
const MEDAL_COLOURS := {"gold": Color("e8c34a"), "silver": Color("c8ccd6"), "bronze": Color("c98a4a")}
const REFRESH_S := 1.5
const WELL := Color("070b12")
const GOOD := Color(0.498, 0.839, 0.478)
const BAD := Color(0.937, 0.416, 0.373)
const FAINT := Color(0.435, 0.424, 0.400)

var player: Node = null
var hud: Node = null
## Set by the map controller: walk back into the party's open run.
var on_rejoin: Callable

var portal_id := ""
var difficulty := "normal"
var _info: Dictionary = {}
var _refresh_t := 0.0

var _banner: DungeonBanner
var _page_tabs: Dictionary = {}   # page id -> HudCharacterWindow.TabChip
var _tab_seals: Label
var _run_view: VBoxContainer
var _shop_view: VBoxContainer
var _seals: Label
var _shop_grid: GridContainer
var _buy_id := -1
var _cards: Dictionary = {}   # difficulty -> DifficultyCard
var _detail: PanelContainer
var _chips: GridContainer
var _curses: HFlowContainer
var _members: VBoxContainer
var _verdict: Label
var _start: Button
var _rejoin: Button
var _buttons: HBoxContainer
## Asked before a new start when the player's last run here is still open.
var _confirm: HBoxContainer
var _run_at_ms := 0

func _init() -> void:
	super._init("Dungeon Gate", Vector2(600, 706))
	name = "DungeonGate"

func _ready() -> void:
	super._ready()
	body.add_theme_constant_override("separation", 10)
	_banner = DungeonBanner.new()
	body.add_child(_banner)
	_build_tabs()
	_run_view = VBoxContainer.new()
	_run_view.add_theme_constant_override("separation", 8)
	_run_view.size_flags_vertical = Control.SIZE_EXPAND_FILL
	body.add_child(_run_view)
	_shop_view = _build_shop()
	body.add_child(_shop_view)

	var cards := HBoxContainer.new()
	cards.add_theme_constant_override("separation", 6)
	_run_view.add_child(cards)
	var diamonds := 1
	for id in HPRules.DUNGEON_DIFFICULTIES:
		var card := DifficultyCard.new(I18n.t(String(HPRules.dungeon_difficulty(id).get("display", id))), COLOURS[id], diamonds)
		card.name = "Tab_" + id
		card.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		card.chosen.connect(_pick.bind(String(id)))
		cards.add_child(card)
		_cards[String(id)] = card
		diamonds += 1

	_detail = PanelContainer.new()
	_run_view.add_child(_detail)
	var detail_col := VBoxContainer.new()
	detail_col.add_theme_constant_override("separation", 8)
	_detail.add_child(detail_col)
	_chips = GridContainer.new()
	_chips.columns = 3
	_chips.add_theme_constant_override("h_separation", 6)
	_chips.add_theme_constant_override("v_separation", 6)
	detail_col.add_child(_chips)
	_curses = HFlowContainer.new()
	_curses.add_theme_constant_override("h_separation", 6)
	_curses.add_theme_constant_override("v_separation", 4)
	detail_col.add_child(_curses)

	_run_view.add_child(section(tr("Party at the gate")))
	_members = VBoxContainer.new()
	_members.add_theme_constant_override("separation", 3)
	_members.size_flags_vertical = Control.SIZE_EXPAND_FILL
	_run_view.add_child(_members)
	_verdict = HudKit.label("", 14, HudKit.TEXT, HudKit.bold(), 3)
	_verdict.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_verdict.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_run_view.add_child(_verdict)
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 10)
	_run_view.add_child(row)
	_buttons = row
	_start = HudKit.gold_button(tr("Ready check"))
	_start.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_start.pressed.connect(_on_start)
	row.add_child(_start)
	_rejoin = HudKit.button(tr("Return to the dungeon"), 15)
	_rejoin.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_rejoin.custom_minimum_size = Vector2(0, 44)
	_rejoin.pressed.connect(_on_rejoin)
	row.add_child(_rejoin)
	_build_confirm()
	_show_page("run")
	SimAuthority.dungeon_event.connect(_on_event)

## The Dungeon / Seal Shop tabs (the character window's strip); the shop tab
## carries the seal count.
## "Your dungeon is still open": start a new one (the old one is given up) or
## go back to it. Takes the button row's place until answered.
func _build_confirm() -> void:
	# The question is worded on the verdict line; this row takes the buttons' place.
	_confirm = HBoxContainer.new()
	_confirm.add_theme_constant_override("separation", 10)
	_confirm.visible = false
	_run_view.add_child(_confirm)
	var row := _confirm
	var fresh := HudKit.gold_button(tr("Start a new dungeon"))
	fresh.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	fresh.pressed.connect(func():
		_hide_confirm()
		_send_start())
	row.add_child(fresh)
	var back := HudKit.button(tr("Return to the dungeon"), 15)
	back.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	back.custom_minimum_size = Vector2(0, 44)
	back.pressed.connect(func():
		_hide_confirm()
		_on_rejoin())
	row.add_child(back)
	var cancel := HudKit.button(tr("Cancel"), 15)
	cancel.custom_minimum_size = Vector2(110, 44)
	cancel.pressed.connect(_hide_confirm)
	row.add_child(cancel)

func _hide_confirm() -> void:
	if _confirm.visible:
		_confirm.visible = false
		_buttons.visible = true
		_refresh()

## Seconds the open run stays open to us, ticking down from the gate's answer
## (-1: no limit now).
func _run_left_s() -> float:
	var left := float((_info.get("run", {}) as Dictionary).get("left_s", -1.0))
	if left < 0.0:
		return -1.0
	return maxf(0.0, left - float(Time.get_ticks_msec() - _run_at_ms) / 1000.0)

func _build_tabs() -> void:
	var strip := VBoxContainer.new()
	strip.add_theme_constant_override("separation", 0)
	body.add_child(strip)
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 4)
	strip.add_child(row)
	var pad := Control.new()
	pad.custom_minimum_size = Vector2(2, 0)
	row.add_child(pad)
	for page in [["run", tr("Dungeon")], ["shop", tr("Seal Shop")]]:
		var tab := HudCharacterWindow.TabChip.new(String(page[1]))
		tab.name = "Page_" + String(page[0])
		tab.chosen.connect(_show_page.bind(String(page[0])))
		row.add_child(tab)
		_page_tabs[String(page[0])] = tab
	var shop_tab := _page_tabs["shop"] as HudCharacterWindow.TabChip
	shop_tab.row.add_child(UITheme.icon_rect("dungeon_seal", 16))
	_tab_seals = HudKit.label("", 12, HudKit.GOLD_LT, HudKit.body(), 0)
	shop_tab.row.add_child(_tab_seals)
	var rule := ColorRect.new()
	rule.color = HudKit.GOLD_DK
	rule.custom_minimum_size = Vector2(0, 1)
	strip.add_child(rule)

## The seal shop page: the purse, then the wares as a two-column card grid.
func _build_shop() -> VBoxContainer:
	var view := VBoxContainer.new()
	view.add_theme_constant_override("separation", 10)
	view.size_flags_vertical = Control.SIZE_EXPAND_FILL
	var purse := PanelContainer.new()
	purse.add_theme_stylebox_override("panel", _box(WELL, Color("3a3122"), 5, 10))
	view.add_child(purse)
	var line := HBoxContainer.new()
	line.add_theme_constant_override("separation", 12)
	purse.add_child(line)
	line.add_child(UITheme.icon_rect("dungeon_seal", 40))
	var words := VBoxContainer.new()
	words.add_theme_constant_override("separation", 0)
	words.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	line.add_child(words)
	_seals = HudKit.label("", 22, HudKit.GOLD_HI, HudKit.title(), 3)
	words.add_child(_seals)
	words.add_child(HudKit.label(tr("Dungeon Seals  ·  every finished run pays seals; a medal pays more"), 12, HudKit.TEXT_DIM, HudKit.body(), 0))
	_shop_grid = GridContainer.new()
	_shop_grid.columns = 2
	_shop_grid.add_theme_constant_override("h_separation", 6)
	_shop_grid.add_theme_constant_override("v_separation", 6)
	view.add_child(_shop_grid)
	for entry in HPRules.dungeon_rewards().get("shop", []):
		var card := PanelContainer.new()
		card.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		card.add_theme_stylebox_override("panel", _box(Color(0.086, 0.141, 0.227, 0.45), Color("23324c"), 5, 8))
		_shop_grid.add_child(card)
		var row := HBoxContainer.new()
		row.add_theme_constant_override("separation", 10)
		card.add_child(row)
		var item_id := String(entry.get("item", ""))
		row.add_child(UITheme.icon_rect(item_id, 38))
		var col := VBoxContainer.new()
		col.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		col.size_flags_vertical = Control.SIZE_SHRINK_CENTER
		col.add_theme_constant_override("separation", 2)
		row.add_child(col)
		var amount := int(entry.get("amount", 1))
		var name_text := I18n.t(String(HPEquipment.item(item_id).get("name", item_id)))
		var label := HudKit.label(name_text if amount == 1 else "%s ×%d" % [name_text, amount], 14, HudKit.PARCHMENT, HudKit.body(), 0)
		label.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
		label.custom_minimum_size.x = 60
		col.add_child(label)
		var price := HBoxContainer.new()
		price.add_theme_constant_override("separation", 4)
		col.add_child(price)
		price.add_child(UITheme.icon_rect("dungeon_seal", 15))
		price.add_child(HudKit.label(tr("%d seals") % int(entry.get("seals", 1)), 13, HudKit.GOLD_LT, HudKit.body(), 0))
		var buy := HudKit.gold_button_small(tr("Buy"))
		buy.set_meta("seals", int(entry.get("seals", 1)))
		buy.pressed.connect(_buy.bind(item_id))
		row.add_child(buy)
	return view

static func _box(bg: Color, border: Color, radius: int, margin: float) -> StyleBoxFlat:
	return HudSkillWindow._box(bg, border, radius, margin)

func _show_page(page: String) -> void:
	_run_view.visible = page == "run"
	_shop_view.visible = page == "shop"
	for id in _page_tabs:
		(_page_tabs[id] as HudCharacterWindow.TabChip).selected = id == page
	_refresh_shop()

func _seal_count() -> int:
	var n := 0
	if is_instance_valid(player):
		for entry in player.get("inventory"):
			if String((entry as Dictionary).get("id", "")) == "dungeon_seal":
				n += int((entry as Dictionary).get("amount", 1))
	return n

func _refresh_shop() -> void:
	if _seals == null:
		return
	var seals := _seal_count()
	_seals.text = str(seals)
	_tab_seals.text = str(seals)
	for card in _shop_grid.get_children():
		var row := card.get_child(0)
		var buy := row.get_child(row.get_child_count() - 1) as Button
		buy.disabled = seals < int(buy.get_meta("seals", 1))

func _buy(item_id: String) -> void:
	if not is_instance_valid(player):
		return
	if player.has_signal("equipment_answer") and not player.equipment_answer.is_connected(_bought):
		player.equipment_answer.connect(_bought)
	_buy_id = SimNet.submit_equipment(player, "seal_buy", "", item_id, 1, 0)

func _bought(answer: Dictionary) -> void:
	if int(answer.get("request_id", -2)) != _buy_id:
		return
	_buy_id = -1
	var reasons := {"bought": tr("Bought."), "no_seals": tr("Not enough Dungeon Seals."), "bag_full": tr("Your bag is full."),
		"not_for_sale": tr("The seal shop is at the dungeon gates.")}
	var reason := String(answer.get("reason", ""))
	_notice(String(reasons.get(reason, tr("The gate keeper shakes his head."))), "good" if bool(answer.get("ok", false)) else "warn")
	if bool(answer.get("ok", false)):
		AudioManager.play_sound_at("ui_coin", Vector3.ZERO, null, true)
	_refresh_shop()

## A small heading with gold rules either side (the Floo window's).
static func section(text: String) -> HBoxContainer:
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 8)
	for i in 2:
		var rule := ColorRect.new()
		rule.color = Color(HudKit.GOLD.r, HudKit.GOLD.g, HudKit.GOLD.b, 0.45)
		rule.custom_minimum_size = Vector2(0, 1)
		rule.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		rule.size_flags_vertical = Control.SIZE_SHRINK_CENTER
		row.add_child(rule)
		if i == 0:
			row.add_child(HudKit.label(I18n.upper(text), 13, HudKit.GOLD_LT, HudKit.title(), 3))
	return row

## Open at the gate `at_portal` for `who`.
func open_at(who: Node, at_portal: String) -> void:
	player = who
	portal_id = at_portal
	_info = {}
	_hide_confirm()
	var dungeon := _dungeon()
	set_title(tr("Dungeon Gate"))
	_banner.setup(I18n.t(String(dungeon.get("display", "Dungeon"))), _boss_art(dungeon))
	_ask()
	_refresh()
	open()

func _dungeon() -> Dictionary:
	return HPMaps.dungeon_for_map(String(HPMaps.portal(portal_id).get("to_map", "")))

## The bestiary picture of the dungeon's boss (the first boss its steps spawn).
static func _boss_art(dungeon: Dictionary) -> Texture2D:
	for step in dungeon.get("steps", []):
		for spawn in (step as Dictionary).get("spawn", []):
			if String((spawn as Dictionary).get("role", "")) == "boss":
				var path := "res://assets/ui/bestiary/%s.png" % String(spawn.get("mob", ""))
				if ResourceLoader.exists(path):
					return load(path)
	return null

func _ask() -> void:
	_refresh_t = REFRESH_S
	if is_instance_valid(player):
		SimNet.dungeon_info(player, portal_id)

func _process(delta: float) -> void:
	if not visible:
		return
	_refresh_t -= delta
	if _rejoin.visible:
		var left := _run_left_s()
		_rejoin.text = tr("Return to the dungeon") + (" (%s)" % _clock(left) if left > 0.0 else "")
	if _refresh_t <= 0.0:
		_ask()
		_refresh_shop()

func _pick(id: String) -> void:
	difficulty = id
	_refresh()

func _local_uid() -> int:
	return SimAuthority.local_uid

func _on_event(uid: int, event: Dictionary) -> void:
	if uid != _local_uid() and SimAuthority.local_uid != 0:
		return
	match String(event.get("kind", "")):
		"info":
			if String(event.get("portal", "")) == portal_id:
				_info = event
				_run_at_ms = Time.get_ticks_msec()
				if visible:
					_refresh()
		"ready":
			if visible:
				_info["check"] = event
				_refresh()
		"cancelled":
			_notice(tr("Ready check cancelled: %s") % reason_text(String(event.get("reason", "")),
				String(event.get("who", "")), 0), "warn")
			if visible:
				_ask()
		"refused":
			_notice(reason_text(String(event.get("reason", "")), String(event.get("who", "")),
				int(event.get("value", 0))), "warn")
		"launch":
			close()

func _notice(text: String, kind: String) -> void:
	if hud != null and hud.has_method("show_notice"):
		hud.show_notice(text, kind)

## Words for a refusal; `who` names the member it is about, `value` a number.
static func reason_text(reason: String, who: String, value: int) -> String:
	var whom := who if who != "" else I18n.t("A party member")
	match reason:
		HPProtocol.REJECT_NOT_LEADER:
			return I18n.t("Only the party leader can start the dungeon.")
		HPProtocol.REJECT_PARTY_SIZE:
			return I18n.t("This difficulty needs a party of at least %d.") % value
		HPProtocol.REJECT_LEVEL_SPREAD:
			return I18n.t("Party levels may differ by at most %d (now %d).") % [
				int(HPRules.dungeon_group().get("max_level_spread", 15)), value]
		HPProtocol.REJECT_LEVEL:
			return I18n.t("%s needs level %d for this difficulty.") % [whom, value]
		HPProtocol.REJECT_NOT_GATHERED:
			return I18n.t("%s is not at the gate.") % whom
		HPProtocol.REJECT_DEAD:
			return I18n.t("%s is dead.") % whom
		HPProtocol.REJECT_MOUNTED:
			return I18n.t("%s is on a broom.") % whom
		HPProtocol.REJECT_IN_DUEL:
			return I18n.t("%s is in a duel.") % whom
		HPProtocol.REJECT_IN_COMBAT:
			return I18n.t("%s is fighting.") % whom
		HPProtocol.REJECT_TRANSFER_PENDING:
			return I18n.t("%s is travelling.") % whom
		HPProtocol.REJECT_IN_RUN:
			return I18n.t("%s is still inside another dungeon.") % whom
		HPProtocol.REJECT_DIFFICULTY_LOCKED:
			return I18n.t("%s has not unlocked this difficulty yet.") % whom
		HPProtocol.REJECT_NO_KEY:
			return I18n.t("%s needs %d key(s) to open this difficulty.") % [whom, value]
		HPProtocol.REJECT_READY_PENDING:
			return I18n.t("A ready check is already under way.")
		HPProtocol.REJECT_DECLINED:
			return I18n.t("%s is not ready.") % whom
		HPProtocol.REJECT_READY_TIMEOUT:
			return I18n.t("No answer from %s.") % whom
		HPProtocol.REJECT_PARTY_CHANGED:
			return I18n.t("The party changed.")
		HPProtocol.REJECT_MAP_FULL:
			return I18n.t("Every copy of this dungeon is taken - try again shortly.")
		HPProtocol.REJECT_RANGE:
			return I18n.t("Stand at the gate.")
		HPProtocol.REJECT_USE_GATE:
			return I18n.t("Start the dungeon at its gate.")
		HPProtocol.REJECT_MAP_UNAVAILABLE:
			return I18n.t("The dungeon could not be prepared - try again in a moment.")
	return I18n.t("The gate stays shut.")

static func _clock(seconds: float) -> String:
	var s := int(round(seconds))
	return "%d:%02d" % [s / 60, s % 60]

## Rebuild the view for the chosen difficulty from the dungeon data and the
## authority's last word on the party.
func _refresh() -> void:
	if _chips == null:
		return
	var dungeon := _dungeon()
	var rules := HPRules.dungeon_difficulty(difficulty)
	var group := HPRules.dungeon_group()
	var accent: Color = COLOURS.get(difficulty, HudKit.GOLD)
	var members: Array = _info.get("members", [])
	var levels: Array = []
	for m in members:
		levels.append(int((m as Dictionary).get("level", 1)))
	if levels.is_empty() and is_instance_valid(player):
		levels.append(int(player.get("level")))
	var params := HPRules.dungeon_run_params(dungeon, difficulty, levels)
	var low := HPRules.dungeon_mob_level(params, {"role": "trash"})
	var high := HPRules.dungeon_mob_level(params, {"role": "boss", "lvl": 1})
	var trash := HPRules.dungeon_stat_scale(params, {"role": "trash"})
	var need := int(dungeon.get("level_min", 1)) + int(rules.get("min_level_add", 0))
	var par := float(dungeon.get("par_s", 1200)) * float(rules.get("par_mult", 1.0))
	var medals := HPMaps.dungeon_rules("medals")
	_banner.band = tr("Levels %d-%d · 1-%d players") % [int(dungeon.get("level_min", 1)),
		int(dungeon.get("level_max", 1)), int(group.get("max_party", 5))]
	_banner.medals = [[MEDAL_COLOURS.gold, _clock(par * float(medals.get("gold", 1.0)))],
		[MEDAL_COLOURS.silver, _clock(par * float(medals.get("silver", 1.3)))],
		[MEDAL_COLOURS.bronze, _clock(par * float(medals.get("bronze", 1.6)))]]
	_banner.queue_redraw()
	var me := _me(members)
	for id in _cards:
		var card := _cards[id] as DifficultyCard
		card.selected = id == difficulty
		card.locked = not me.is_empty() and not (me.get("unlocked", []) as Array).has(id)

	for child in _chips.get_children():
		_chips.remove_child(child)
		child.queue_free()
	_chip(tr("Creatures"), tr("Lv %d–%d") % [low, high])
	_chip(tr("Health · damage"), "×%.2f · ×%.2f" % [float(trash["hp"]), float(rules.get("damage", 1.0))])
	_chip(tr("Needs"), tr("%d+ players · Lv %d+") % [int(rules.get("min_party", 1)), need],
		BAD if members.size() > 0 and members.size() < int(rules.get("min_party", 1)) else HudKit.PARCHMENT)
	_chip(tr("Gold medal"), tr("full clear within %s") % _clock(par * float(medals.get("gold", 1.0))))
	var left := int((me.get("rights", {}) as Dictionary).get(difficulty, -1))
	_chip(tr("Final chest"), tr("unlimited") if left < 0 else (tr("%d left today") % left if left > 0 else tr("none left - helper")),
		BAD if left == 0 else HudKit.PARCHMENT)
	var keys := int(rules.get("keys", 0))
	if keys > 0:
		var have := _key_count(String(dungeon.get("key", "")))
		_chip(tr("Key"), tr("%d needed · you have %d") % [keys, have], GOOD if have >= keys else BAD)
	else:
		var best: Dictionary = me.get("best", {})
		_chip(tr("Your best"), _clock(float(best[difficulty])) if best.has(difficulty) else "—")

	for child in _curses.get_children():
		_curses.remove_child(child)
		child.queue_free()
	# This week's curses on the chosen difficulty (the run keeps the ones it starts with).
	var curses := HPRules.dungeon_week_affixes(int(rules.get("affixes", 0)))
	if curses.is_empty():
		_curses.add_child(HudKit.label(tr("No curses on this difficulty."), 12, FAINT, HudKit.body(), 0))
	else:
		_curses.add_child(HudKit.label(tr("This week's curses:"), 12, HudKit.TEXT_DIM, HudKit.body(), 0))
		for id in curses:
			var curse := HPRules.dungeon_affix(String(id))
			_curses.add_child(_curse(I18n.t(String(curse.get("display", id))), I18n.t(String(curse.get("desc", "")))))
	_set_accent(accent)
	_fill_members(members, need, int(group.get("max_party", 5)))
	_judge(members, levels, rules, need)

## The detail panel's left edge in the chosen difficulty's colour.
func _set_accent(accent: Color) -> void:
	var box := StyleBoxFlat.new()
	box.bg_color = WELL
	box.border_color = accent
	box.border_width_left = 3
	box.set_corner_radius_all(5)
	box.content_margin_left = 12
	box.content_margin_right = 12
	box.content_margin_top = 10
	box.content_margin_bottom = 10
	_detail.add_theme_stylebox_override("panel", box)

## One fact as a small card: caption over value.
func _chip(caption: String, value: String, colour: Color = HudKit.PARCHMENT) -> void:
	var chip := PanelContainer.new()
	chip.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	chip.add_theme_stylebox_override("panel", _box(Color(0.114, 0.184, 0.29, 0.35), Color("1f2b40"), 4, 6))
	var col := VBoxContainer.new()
	col.add_theme_constant_override("separation", 0)
	chip.add_child(col)
	col.add_child(HudKit.label(caption, 11, HudKit.TEXT_DIM, HudKit.body(), 0))
	var v := HudKit.label(value, 14, colour, HudKit.body(), 0)
	v.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	v.custom_minimum_size.x = 140
	col.add_child(v)
	_chips.add_child(chip)

## A curse as a red tag; its description on hover.
func _curse(title: String, desc: String) -> PanelContainer:
	var tag := PanelContainer.new()
	tag.mouse_filter = Control.MOUSE_FILTER_STOP
	tag.tooltip_text = desc
	var sb := _box(Color(0.43, 0.1, 0.055, 0.25), Color("5a2a2a"), 11, 0)
	sb.content_margin_left = 9
	sb.content_margin_right = 9
	sb.content_margin_top = 2
	sb.content_margin_bottom = 2
	tag.add_theme_stylebox_override("panel", sb)
	tag.add_child(HudKit.label("☠ " + title, 12, Color("ffb4a8"), HudKit.body(), 0))
	return tag

## The local player's row in the gate's view ({} before the first answer).
func _me(members: Array) -> Dictionary:
	for m in members:
		if int((m as Dictionary).get("uid", 0)) == _local_uid() or SimAuthority.local_uid == 0:
			return m
	return {}

func _key_count(item_id: String) -> int:
	var n := 0
	if is_instance_valid(player) and item_id != "":
		for entry in player.get("inventory"):
			if String((entry as Dictionary).get("id", "")) == item_id:
				n += int((entry as Dictionary).get("amount", 1))
	return n

## One row per member (crown for the leader, level, a status tag), then
## dashed empty places up to the party cap.
func _fill_members(members: Array, need: int, cap: int) -> void:
	for child in _members.get_children():
		_members.remove_child(child)
		child.queue_free()
	var leader := int(_info.get("leader", 0))
	var check: Dictionary = _info.get("check", {})
	var ready: Dictionary = {}
	for m in check.get("members", []):
		if bool((m as Dictionary).get("ready", false)):
			ready[int(m["uid"])] = true
	for m in members:
		var card := PanelContainer.new()
		card.custom_minimum_size = Vector2(0, 34)
		card.add_theme_stylebox_override("panel", _box(Color(0.086, 0.141, 0.227, 0.45), Color("23324c"), 4, 0))
		_members.add_child(card)
		var row := HBoxContainer.new()
		row.add_theme_constant_override("separation", 10)
		var margin := MarginContainer.new()
		margin.add_theme_constant_override("margin_left", 12)
		margin.add_theme_constant_override("margin_right", 10)
		card.add_child(margin)
		margin.add_child(row)
		var who := String(m.get("name", "?"))
		if int(m.get("uid", 0)) == leader:
			who = "♛ " + who
		var name_label := HudKit.label(who, 15, HudKit.GOLD_HI, HudKit.body(), 2)
		name_label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		name_label.size_flags_vertical = Control.SIZE_SHRINK_CENTER
		row.add_child(name_label)
		var level := int(m.get("level", 1))
		var lv := HudKit.label(tr("Lv %d") % level, 14, HudKit.TEXT if level >= need else BAD, HudKit.body(), 0)
		lv.size_flags_vertical = Control.SIZE_SHRINK_CENTER
		row.add_child(lv)
		var status := String(m.get("status", ""))
		var text := tr("at the gate")
		var colour := GOOD
		if not check.is_empty():
			text = tr("ready") if ready.has(int(m.get("uid", 0))) else tr("answering...")
			colour = GOOD if ready.has(int(m.get("uid", 0))) else HudKit.GOLD_LT
		elif status != "":
			text = _status_word(status)
			colour = BAD
		elif level < need:
			text = tr("level too low")
			colour = BAD
		elif not (m.get("unlocked", HPRules.DUNGEON_DIFFICULTIES) as Array).has(difficulty):
			text = tr("locked")
			colour = BAD
		elif int((m.get("rights", {}) as Dictionary).get(difficulty, -1)) == 0:
			text = tr("helper (no chest)")
			colour = HudKit.GOLD_LT
		row.add_child(_pill(text, colour))
	for i in range(members.size(), cap):
		var empty := PanelContainer.new()
		empty.custom_minimum_size = Vector2(0, 30)
		empty.add_theme_stylebox_override("panel", _box(Color(0, 0, 0, 0), Color("1c2638"), 4, 0))
		var label := HudKit.label(tr("empty place"), 12, FAINT, HudKit.body(), 0)
		label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
		label.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
		empty.add_child(label)
		_members.add_child(empty)

## A status tag: its colour on a faint fill of the same.
func _pill(text: String, colour: Color) -> PanelContainer:
	var pill := PanelContainer.new()
	pill.custom_minimum_size = Vector2(110, 0)
	pill.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	var sb := _box(Color(colour, 0.14), Color(colour, 0.45), 11, 0)
	sb.content_margin_left = 10
	sb.content_margin_right = 10
	sb.content_margin_top = 1
	sb.content_margin_bottom = 2
	pill.add_theme_stylebox_override("panel", sb)
	var label := HudKit.label(text, 12, colour, HudKit.body(), 0)
	label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	pill.add_child(label)
	return pill

func _status_word(status: String) -> String:
	match status:
		HPProtocol.REJECT_NOT_GATHERED:
			return tr("away")
		HPProtocol.REJECT_DEAD:
			return tr("dead")
		HPProtocol.REJECT_MOUNTED:
			return tr("on a broom")
		HPProtocol.REJECT_IN_DUEL:
			return tr("duelling")
		HPProtocol.REJECT_IN_COMBAT:
			return tr("fighting")
		HPProtocol.REJECT_TRANSFER_PENDING:
			return tr("travelling")
		HPProtocol.REJECT_IN_RUN:
			return tr("in another run")
		HPProtocol.REJECT_DIFFICULTY_LOCKED:
			return tr("locked")
	return tr("busy")

## The first thing the authority would refuse, worded; the buttons follow it.
func _judge(members: Array, levels: Array, rules: Dictionary, need: int) -> void:
	var problem := ""
	var leader := int(_info.get("leader", 0))
	var i_lead := leader == 0 or leader == _local_uid() or SimAuthority.local_uid == 0
	var check: Dictionary = _info.get("check", {})
	if _info.is_empty():
		problem = tr("Asking the gate...")
	elif not check.is_empty():
		problem = tr("Ready check under way: %d / %d ready") % [
			(check.get("members", []) as Array).filter(func(m): return bool(m.get("ready", false))).size(),
			(check.get("members", []) as Array).size()]
	elif not i_lead:
		problem = tr("The party leader starts the dungeon.")
	elif members.size() < int(rules.get("min_party", 1)):
		problem = reason_text(HPProtocol.REJECT_PARTY_SIZE, "", int(rules.get("min_party", 1)))
	elif HPRules.dungeon_level_spread(levels) > int(HPRules.dungeon_group().get("max_level_spread", 15)):
		problem = reason_text(HPProtocol.REJECT_LEVEL_SPREAD, "", HPRules.dungeon_level_spread(levels))
	else:
		for m in members:
			if String(m.get("status", "")) != "":
				problem = reason_text(String(m["status"]), String(m.get("name", "")), 0)
				break
			if int(m.get("level", 1)) < need:
				problem = reason_text(HPProtocol.REJECT_LEVEL, String(m.get("name", "")), need)
				break
			if not (m.get("unlocked", HPRules.DUNGEON_DIFFICULTIES) as Array).has(difficulty):
				problem = reason_text(HPProtocol.REJECT_DIFFICULTY_LOCKED, String(m.get("name", "")), 0)
				break
		var keys := int(rules.get("keys", 0))
		if problem == "" and keys > 0 and _key_count(String(_dungeon().get("key", ""))) < keys:
			problem = reason_text(HPProtocol.REJECT_NO_KEY, tr("You"), keys)
	var blocked := problem != ""
	if _confirm.visible and blocked:
		_hide_confirm()   # the start is refused now anyway (a member went in, a check began)
		return
	if not _confirm.visible:   # the open-dungeon question holds the line until answered
		_verdict.text = problem if blocked else (tr("Everyone is ready at the gate.") if members.size() > 1 else tr("The gate is open to you."))
		_verdict.add_theme_color_override("font_color", HudKit.GOLD_LT if not check.is_empty() else (BAD if blocked else GOOD))
	_start.text = I18n.upper(tr("Ready check") if members.size() > 1 else tr("Enter"))
	_start.disabled = blocked
	_rejoin.visible = bool(_info.get("active", false))

func _on_start() -> void:
	# The last run here is still open (walked out, or died and came round
	# outside): a new start gives it up, so ask first.
	var run: Dictionary = _info.get("run", {})
	if not run.is_empty() and not bool(run.get("complete", false)):
		var total := int(run.get("forces_total", 0))
		var share := 0 if total <= 0 else int(floor(100.0 * minf(1.0, float(run.get("forces", 0)) / float(total))))
		var left := _run_left_s()
		var text := tr("You still have an open dungeon here: %s, %d%% cleared.") % [
			I18n.t(String(HPRules.dungeon_difficulty(String(run.get("difficulty", "normal"))).get("display", ""))), share]
		if left > 0.0:
			text += " " + tr("It stays open for %s more.") % _clock(left)
		_verdict.text = text + "\n" + tr("A new dungeon closes that one for good.")
		_verdict.add_theme_color_override("font_color", HudKit.GOLD_LT)
		_confirm.visible = true
		_buttons.visible = false
		return
	_send_start()

func _send_start() -> void:
	if is_instance_valid(player):
		SimNet.dungeon_start(player, portal_id, difficulty)
		AudioManager.play_sound_at("ui_confirm", Vector3.ZERO, null, true)

func _on_rejoin() -> void:
	close()
	if on_rejoin.is_valid():
		on_rejoin.call(portal_id)


## The dungeon's banner: a dark red glow behind its boss on the right, the
## name, the level band and the three medal times on the left.
class DungeonBanner extends Control:
	var title := ""
	var band := ""
	var medals: Array = []   # [[colour, "15:00"], ...] gold, silver, bronze
	var art: Texture2D

	func _init() -> void:
		custom_minimum_size = Vector2(0, 100)
		mouse_filter = Control.MOUSE_FILTER_IGNORE
		clip_contents = true

	func setup(p_title: String, p_art: Texture2D) -> void:
		title = p_title
		art = p_art
		queue_redraw()

	func _draw() -> void:
		var r := Rect2(Vector2.ZERO, size)
		draw_rect(r, Color("0a0f1a"))
		# The glow: rings of warm red, fading out from behind the boss.
		var glow_c := Vector2(size.x * 0.8, size.y * 0.5)
		for i in 12:
			var t := 1.0 - float(i) / 12.0
			draw_circle(glow_c, size.y * (0.4 + 1.6 * t), Color(0.55, 0.16, 0.12, 0.035))
		if art != null:
			var h := size.y * 1.45
			var w := h * art.get_width() / art.get_height()
			draw_texture_rect(art, Rect2(size.x - w + 10.0, size.y - h + 20.0, w, h), false, Color(1, 1, 1, 0.9))
		# Fade the art into the dark on its left.
		var fade := 180.0
		for i in 18:
			var t := float(i) / 18.0
			draw_rect(Rect2(size.x * 0.52 + fade * t, 0, fade / 18.0 + 1.0, size.y), Color(0.04, 0.06, 0.1, 0.9 * (1.0 - t)))
		draw_rect(Rect2(0, 0, size.x * 0.52, size.y), Color(0.04, 0.06, 0.1, 0.9))
		var deco := HudKit.deco()
		draw_string_outline(deco, Vector2(18, 38), title, HORIZONTAL_ALIGNMENT_LEFT, -1, 26, 4, Color(0, 0, 0, 0.8))
		draw_string(deco, Vector2(18, 38), title, HORIZONTAL_ALIGNMENT_LEFT, -1, 26, HudKit.GOLD_HI)
		draw_string(HudKit.body(), Vector2(18, 60), band, HORIZONTAL_ALIGNMENT_LEFT, -1, 14, HudKit.PARCHMENT)
		var x := 18.0
		for medal in medals:
			draw_circle(Vector2(x + 6.0, 80.0), 6.0, medal[0])
			draw_arc(Vector2(x + 6.0, 80.0), 6.0, 0.0, TAU, 16, Color(0, 0, 0, 0.6), 1.0, true)
			draw_string(HudKit.body(), Vector2(x + 16.0, 85.0), String(medal[1]), HORIZONTAL_ALIGNMENT_LEFT, -1, 13, HudKit.TEXT_DIM)
			x += 74.0
		draw_rect(r, Color("3a3122"), false, 1.0)


## A difficulty to pick: 1-5 diamonds and the name in its colour; the chosen
## one fills with a dark shade of it and glows; a locked one dims with a lock.
class DifficultyCard extends Control:
	signal chosen
	var caption := ""
	var colour := Color.WHITE
	var diamonds := 1
	var selected := false:
		set(value):
			selected = value
			queue_redraw()
	var locked := false:
		set(value):
			locked = value
			modulate.a = 0.45 if value else 1.0
			queue_redraw()
	var _hover := false

	func _init(p_caption: String, p_colour: Color, p_diamonds: int) -> void:
		caption = p_caption
		colour = p_colour
		diamonds = p_diamonds
		custom_minimum_size = Vector2(0, 58)
		mouse_filter = Control.MOUSE_FILTER_STOP
		mouse_default_cursor_shape = Control.CURSOR_POINTING_HAND
		mouse_entered.connect(func(): _hover = true; queue_redraw())
		mouse_exited.connect(func(): _hover = false; queue_redraw())

	func _gui_input(event: InputEvent) -> void:
		if event is InputEventMouseButton and event.pressed and event.button_index == MOUSE_BUTTON_LEFT:
			chosen.emit()
			accept_event()

	func _draw() -> void:
		var r := Rect2(Vector2.ZERO, size)
		var box := StyleBoxFlat.new()
		box.set_corner_radius_all(5)
		box.set_border_width_all(1)
		if selected:
			box.bg_color = colour.darkened(0.72)
			box.border_color = colour
			box.shadow_color = Color(colour, 0.3)
			box.shadow_size = 8
		else:
			box.bg_color = Color(0.067, 0.11, 0.18, 0.8)
			box.border_color = colour if _hover else Color("23324c")
		draw_style_box(box, r)
		var y := size.y * 0.36
		var step := 12.0
		var x0 := size.x * 0.5 - step * 2.0
		for i in 5:
			var c := Vector2(x0 + step * i, y)
			var pts := PackedVector2Array([c + Vector2(0, -4.5), c + Vector2(4.5, 0), c + Vector2(0, 4.5), c + Vector2(-4.5, 0)])
			if i < diamonds:
				draw_colored_polygon(pts, colour)
			else:
				pts.append(pts[0])
				draw_polyline(pts, Color(colour, 0.35), 1.0, true)
		var font := HudKit.body()
		var w := font.get_string_size(caption, HORIZONTAL_ALIGNMENT_LEFT, -1, 14).x
		draw_string(font, Vector2((size.x - w) * 0.5, size.y * 0.78), caption, HORIZONTAL_ALIGNMENT_LEFT, -1, 14, Color.WHITE if selected else colour)
		if locked:
			var lock := UITheme.icon_for("ui_lock")
			if lock != null:
				draw_texture_rect(lock, Rect2(size.x - 17.0, 5.0, 12.0, 12.0), false)
