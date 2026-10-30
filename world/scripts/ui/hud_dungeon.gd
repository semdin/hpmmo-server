extends HudWindow
class_name HudDungeon

## The dungeon gate window (interact at a dungeon door, protocol v30). Five
## difficulty tabs; for the chosen one it shows what the run will be for this
## party (reference level, creature levels, power, the party it needs, the gold
## medal time), the party at the gate with whether each can go in, and the
## leader's button that opens the ready check. A run of the party's that is
## still open offers its way back in instead. The authority decides everything
## (SimNet.dungeon_info / dungeon_start); the checks here only explain early
## what it would refuse. Its second page is the seal shop: Zindan Muhru from
## finished runs buys keys, runes and potions (equipment op `seal_buy`).

const COLOURS := {
	"easy": Color(0.44, 0.81, 0.55),
	"normal": Color(0.50, 0.70, 0.94),
	"hard": Color(0.94, 0.65, 0.34),
	"very_hard": Color(0.94, 0.48, 0.45),
	"legendary": Color(0.77, 0.61, 1.0),
}
const REFRESH_S := 1.5

var player: Node = null
var hud: Node = null
## Set by the map controller: walk back into the party's open run.
var on_rejoin: Callable

var portal_id := ""
var difficulty := "normal"
var _info: Dictionary = {}
var _refresh_t := 0.0

var _band: Label
var _pages: HBoxContainer
var _run_view: VBoxContainer
var _shop_view: VBoxContainer
var _seals: Label
var _shop_rows: VBoxContainer
var _buy_id := -1
var _tabs: HBoxContainer
var _facts: GridContainer
var _members: VBoxContainer
var _verdict: Label
var _start: Button
var _rejoin: Button

func _init() -> void:
	super._init("Dungeon", Vector2(560, 660))
	name = "DungeonGate"

func _ready() -> void:
	super._ready()
	body.add_theme_constant_override("separation", 10)
	_band = HudKit.label("", 13, HudKit.TEXT_DIM, HudKit.body(), 3)
	_band.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	body.add_child(_band)
	_pages = HBoxContainer.new()
	_pages.add_theme_constant_override("separation", 6)
	body.add_child(_pages)
	for page in [["run", tr("Dungeon")], ["shop", tr("Seal Shop")]]:
		var b := HudKit.button(String(page[1]), 13)
		b.name = "Page_" + String(page[0])
		b.toggle_mode = true
		b.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		b.pressed.connect(_show_page.bind(String(page[0])))
		_pages.add_child(b)
	_run_view = VBoxContainer.new()
	_run_view.add_theme_constant_override("separation", 10)
	_run_view.size_flags_vertical = Control.SIZE_EXPAND_FILL
	body.add_child(_run_view)
	_shop_view = _build_shop()
	body.add_child(_shop_view)
	_tabs = HBoxContainer.new()
	_tabs.add_theme_constant_override("separation", 6)
	_run_view.add_child(_tabs)
	for id in HPRules.DUNGEON_DIFFICULTIES:
		var tab := HudKit.button(I18n.t(String(HPRules.dungeon_difficulty(id).get("display", id))), 14)
		tab.name = "Tab_" + id
		tab.toggle_mode = true
		tab.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		tab.custom_minimum_size = Vector2(0, 34)
		var colour: Color = COLOURS[id]
		tab.add_theme_color_override("font_color", colour)
		tab.add_theme_color_override("font_pressed_color", Color.WHITE)
		tab.add_theme_color_override("font_hover_pressed_color", Color.WHITE)
		# The chosen difficulty wears its own colour.
		var chosen := HudKit.button_box("pressed").duplicate() as StyleBoxFlat
		chosen.bg_color = colour.darkened(0.62)
		chosen.border_color = colour
		chosen.set_border_width_all(2)
		tab.add_theme_stylebox_override("pressed", chosen)
		tab.add_theme_stylebox_override("hover_pressed", chosen)
		tab.pressed.connect(_pick.bind(String(id)))
		_tabs.add_child(tab)
	var card := PanelContainer.new()
	card.add_theme_stylebox_override("panel", HudFloo._card_box(HudKit.NAVY_LT, HudKit.GOLD_DK, 0.9))
	_run_view.add_child(card)
	_facts = GridContainer.new()
	_facts.columns = 2
	_facts.add_theme_constant_override("h_separation", 14)
	_facts.add_theme_constant_override("v_separation", 4)
	card.add_child(_facts)
	_run_view.add_child(section(tr("Party at the gate")))
	_members = VBoxContainer.new()
	_members.add_theme_constant_override("separation", 4)
	_members.size_flags_vertical = Control.SIZE_EXPAND_FILL
	_run_view.add_child(_members)
	_verdict = HudKit.label("", 14, HudKit.TEXT, HudKit.bold(), 3)
	_verdict.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_verdict.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_run_view.add_child(_verdict)
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 10)
	_run_view.add_child(row)
	_start = HudKit.button(tr("Ready check"), 15)
	_start.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_start.custom_minimum_size = Vector2(0, 40)
	_start.pressed.connect(_on_start)
	row.add_child(_start)
	_rejoin = HudKit.button(tr("Return to your run"), 15)
	_rejoin.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_rejoin.custom_minimum_size = Vector2(0, 40)
	_rejoin.pressed.connect(_on_rejoin)
	row.add_child(_rejoin)
	_show_page("run")
	SimAuthority.dungeon_event.connect(_on_event)

## The seal shop page: what the purse holds, then one row per ware.
func _build_shop() -> VBoxContainer:
	var view := VBoxContainer.new()
	view.add_theme_constant_override("separation", 8)
	view.size_flags_vertical = Control.SIZE_EXPAND_FILL
	var purse := PanelContainer.new()
	purse.add_theme_stylebox_override("panel", HudFloo._card_box(HudKit.NAVY_LT, HudKit.GOLD_DK, 0.9))
	view.add_child(purse)
	var line := HBoxContainer.new()
	line.add_theme_constant_override("separation", 10)
	purse.add_child(line)
	line.add_child(UITheme.icon_rect("dungeon_seal", 40))
	_seals = HudKit.label("", 17, HudKit.GOLD_HI, HudKit.bold(), 3)
	_seals.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_seals.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	line.add_child(_seals)
	var note := HudKit.label(tr("Every finished run pays seals; a medal pays more."), 12, HudKit.TEXT_DIM, HudKit.body(), 2)
	note.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	view.add_child(note)
	_shop_rows = VBoxContainer.new()
	_shop_rows.add_theme_constant_override("separation", 6)
	view.add_child(_shop_rows)
	for entry in HPRules.dungeon_rewards().get("shop", []):
		var card := PanelContainer.new()
		card.add_theme_stylebox_override("panel", HudFloo._card_box(HudKit.NAVY, HudKit.GOLD_DK, 0.8))
		_shop_rows.add_child(card)
		var row := HBoxContainer.new()
		row.add_theme_constant_override("separation", 10)
		card.add_child(row)
		var item_id := String(entry.get("item", ""))
		row.add_child(UITheme.icon_rect(item_id, 34))
		var amount := int(entry.get("amount", 1))
		var name_text := I18n.t(String(HPEquipment.item(item_id).get("name", item_id)))
		var label := HudKit.label(name_text if amount == 1 else "%s x%d" % [name_text, amount], 14, HudKit.PARCHMENT, HudKit.bold(), 2)
		label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		label.size_flags_vertical = Control.SIZE_SHRINK_CENTER
		row.add_child(label)
		var price := HudKit.label(tr("%d seals") % int(entry.get("seals", 1)), 13, HudKit.GOLD_LT, HudKit.body(), 2)
		price.size_flags_vertical = Control.SIZE_SHRINK_CENTER
		row.add_child(price)
		var buy := HudKit.button(tr("Buy"), 13)
		buy.custom_minimum_size = Vector2(70, 30)
		buy.size_flags_vertical = Control.SIZE_SHRINK_CENTER
		buy.set_meta("seals", int(entry.get("seals", 1)))
		buy.pressed.connect(_buy.bind(item_id))
		row.add_child(buy)
	return view

func _show_page(page: String) -> void:
	_run_view.visible = page == "run"
	_shop_view.visible = page == "shop"
	for b in _pages.get_children():
		(b as Button).set_pressed_no_signal(String(b.name) == "Page_" + page)
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
	_seals.text = tr("Dungeon Seals: %d") % seals
	for card in _shop_rows.get_children():
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
	var dungeon := _dungeon()
	set_title(String(dungeon.get("display", "Dungeon")))
	_ask()
	_refresh()
	open()

func _dungeon() -> Dictionary:
	return HPMaps.dungeon_for_map(String(HPMaps.portal(portal_id).get("to_map", "")))

func _ask() -> void:
	_refresh_t = REFRESH_S
	if is_instance_valid(player):
		SimNet.dungeon_info(player, portal_id)

func _process(delta: float) -> void:
	if not visible:
		return
	_refresh_t -= delta
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
			return I18n.t("%s is in another dungeon run.") % whom
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
	return I18n.t("The gate stays shut.")

static func _clock(seconds: float) -> String:
	var s := int(round(seconds))
	return "%d:%02d" % [s / 60, s % 60]

## Rebuild the view for the chosen difficulty from the dungeon data and the
## authority's last word on the party.
func _refresh() -> void:
	if _facts == null:
		return
	var dungeon := _dungeon()
	var rules := HPRules.dungeon_difficulty(difficulty)
	var group := HPRules.dungeon_group()
	_band.text = tr("Levels %d-%d · 1-%d players") % [int(dungeon.get("level_min", 1)),
		int(dungeon.get("level_max", 1)), int(group.get("max_party", 5))]
	for tab in _tabs.get_children():
		(tab as Button).set_pressed_no_signal(String(tab.name) == "Tab_" + difficulty)
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
	var par := float(dungeon.get("par_s", 1200)) * float(rules.get("par_mult", 1.0)) * float(HPMaps.dungeon_rules("medals").get("gold", 1.0))
	for child in _facts.get_children():
		child.queue_free()
	_fact(tr("For your party"), tr("reference level %d - creatures level %d-%d") % [int(params["ref_level"]), low, high])
	_fact(tr("Power"), tr("health x%.2f, damage x%.2f") % [float(trash["hp"]), float(rules.get("damage", 1.0))])
	_fact(tr("Needs"), tr("%d+ players, level %d+") % [int(rules.get("min_party", 1)), need])
	_fact(tr("Gold medal"), tr("full clear within %s") % _clock(par))
	# This week's curses on the chosen difficulty (the run keeps the ones it starts with).
	for id in HPRules.dungeon_week_affixes(int(rules.get("affixes", 0))):
		var curse := HPRules.dungeon_affix(String(id))
		_fact(tr("Curse"), "%s - %s" % [I18n.t(String(curse.get("display", id))), I18n.t(String(curse.get("desc", "")))])
	var me := _me(members)
	var keys := int(rules.get("keys", 0))
	if keys > 0:
		_fact(tr("Key"), tr("the leader spends %d (you have %d)") % [keys, _key_count(String(dungeon.get("key", "")))])
	var left := int((me.get("rights", {}) as Dictionary).get(difficulty, -1))
	_fact(tr("Final chest"), tr("unlimited") if left < 0 else (tr("%d left today") % left if left > 0 else tr("none left today - you would go in as a helper")))
	var best: Dictionary = me.get("best", {})
	if best.has(difficulty):
		_fact(tr("Your best"), _clock(float(best[difficulty])))
	for tab in _tabs.get_children():
		var id := String(tab.name).trim_prefix("Tab_")
		tab.modulate.a = 1.0 if me.is_empty() or (me.get("unlocked", []) as Array).has(id) else 0.45
	_fill_members(members, need)
	_judge(members, levels, rules, need)

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

func _fact(key: String, value: String) -> void:
	_facts.add_child(HudKit.label(key, 13, HudKit.TEXT_DIM, HudKit.body(), 2))
	var v := HudKit.label(value, 14, HudKit.PARCHMENT, HudKit.bold(), 2)
	v.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	v.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_facts.add_child(v)

func _fill_members(members: Array, need: int) -> void:
	for child in _members.get_children():
		child.queue_free()
	var leader := int(_info.get("leader", 0))
	var check: Dictionary = _info.get("check", {})
	var ready: Dictionary = {}
	for m in check.get("members", []):
		if bool((m as Dictionary).get("ready", false)):
			ready[int(m["uid"])] = true
	for m in members:
		var row := HBoxContainer.new()
		row.add_theme_constant_override("separation", 10)
		_members.add_child(row)
		var who := String(m.get("name", "?"))
		if int(m.get("uid", 0)) == leader:
			who = "♛ " + who
		var name_label := HudKit.label(who, 15, HudKit.GOLD_HI, HudKit.bold(), 3)
		name_label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		row.add_child(name_label)
		var level := int(m.get("level", 1))
		row.add_child(HudKit.label(tr("Lv %d") % level, 14, HudKit.TEXT if level >= need else HudKit.RED, HudKit.body(), 2))
		var status := String(m.get("status", ""))
		var text := tr("at the gate")
		var colour := HudKit.GREEN
		if not check.is_empty():
			text = tr("ready") if ready.has(int(m.get("uid", 0))) else tr("answering...")
			colour = HudKit.GREEN if ready.has(int(m.get("uid", 0))) else HudKit.GOLD_LT
		elif status != "":
			text = _status_word(status)
			colour = HudKit.RED
		elif not (m.get("unlocked", HPRules.DUNGEON_DIFFICULTIES) as Array).has(difficulty):
			text = tr("locked")
			colour = HudKit.RED
		elif int((m.get("rights", {}) as Dictionary).get(difficulty, -1)) == 0:
			text = tr("helper (no chest)")
			colour = HudKit.GOLD_LT
		var status_label := HudKit.label(text, 13, colour, HudKit.body(), 2)
		status_label.custom_minimum_size = Vector2(150, 0)
		status_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
		row.add_child(status_label)

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
	_verdict.text = problem if blocked else (tr("Everyone is ready at the gate.") if members.size() > 1 else tr("The gate is open to you."))
	_verdict.add_theme_color_override("font_color", HudKit.GOLD_LT if not check.is_empty() else (HudKit.RED if blocked else HudKit.GREEN))
	_start.text = tr("Ready check") if members.size() > 1 else tr("Enter")
	_start.disabled = blocked
	_rejoin.visible = bool(_info.get("active", false))

func _on_start() -> void:
	if is_instance_valid(player):
		SimNet.dungeon_start(player, portal_id, difficulty)
		AudioManager.play_sound_at("ui_confirm", Vector3.ZERO, null, true)

func _on_rejoin() -> void:
	close()
	if on_rejoin.is_valid():
		on_rejoin.call(portal_id)
