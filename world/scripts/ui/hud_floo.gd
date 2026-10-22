extends HudWindow
class_name HudFloo

## The Floo Network window (interact at a fireplace, data/travel.json). Lists
## every hearth of the network grouped by map: each can be travelled to for
## one pinch of Floo Powder; a hearth above the character's level carries a
## lock and says the level it needs. Floo Powder and
## the keeper's Portkey boots are sold right here. Everything is decided by the
## authority (SimNet.request_travel / the "buy" equipment operation); this
## window only asks and shows.

const POWDER := "floo_powder"
const BOOT := "portkey_boot"
const EMERALD := Color(0.36, 0.86, 0.5)
const EMERALD_DK := Color(0.07, 0.2, 0.13)
var _bought := POWDER

var player: Node = null
var node_id := ""
## Set by the map controller: plays the departure flames before the request.
var on_travel: Callable

var _powder_label: Label
var _price_label: Label
var _here_label: Label
var _list: VBoxContainer
var _buy_id := -1
var _travel_buttons: Array[Button] = []

func _init() -> void:
	super._init("Floo Network", Vector2(520, 620))
	name = "FlooNetwork"

func _ready() -> void:
	super._ready()
	body.add_theme_constant_override("separation", 8)
	_here_label = HudKit.label("", 13, HudKit.TEXT_DIM, HudKit.body(), 3)
	_here_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	body.add_child(_here_label)
	body.add_child(_powder_card())
	body.add_child(_section(tr("Destinations")))
	var scroll := ScrollContainer.new()
	scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
	scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	body.add_child(scroll)
	_list = VBoxContainer.new()
	_list.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_list.add_theme_constant_override("separation", 6)
	scroll.add_child(_list)
	body.add_child(_boot_row())

## The pouch: what you carry, the price, and the two buy buttons, on an
## emerald-rimmed card (the colour of the flames it makes).
func _powder_card() -> PanelContainer:
	var card := PanelContainer.new()
	card.add_theme_stylebox_override("panel", _card_box(EMERALD_DK, EMERALD, 0.95))
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 12)
	card.add_child(row)
	row.add_child(UITheme.icon_rect(POWDER, 52))
	var text := VBoxContainer.new()
	text.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	text.alignment = BoxContainer.ALIGNMENT_CENTER
	text.add_theme_constant_override("separation", 0)
	row.add_child(text)
	_powder_label = HudKit.label("", 17, HudKit.GOLD_HI, HudKit.bold())
	text.add_child(_powder_label)
	_price_label = HudKit.label("", 13, HudKit.PARCHMENT.darkened(0.15), HudKit.body(), 3)
	_price_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	text.add_child(_price_label)
	for amount in [1, 5]:
		var buy := HudKit.button(tr("Buy %d") % amount, 14)
		buy.custom_minimum_size = Vector2(64, 34)
		buy.size_flags_vertical = Control.SIZE_SHRINK_CENTER
		buy.pressed.connect(_buy.bind(amount))
		row.add_child(buy)
	return card

## A small heading with gold rules either side.
func _section(text: String) -> HBoxContainer:
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

## The keeper's other ware, quiet at the foot of the window.
func _boot_row() -> PanelContainer:
	var card := PanelContainer.new()
	card.add_theme_stylebox_override("panel", _card_box(HudKit.NAVY, HudKit.GOLD_DK, 0.7))
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 10)
	card.add_child(row)
	row.add_child(UITheme.icon_rect(BOOT, 34))
	var text := VBoxContainer.new()
	text.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	text.add_theme_constant_override("separation", 0)
	row.add_child(text)
	text.add_child(HudKit.label(tr("Old Boot (Portkey)"), 14, HudKit.PARCHMENT, HudKit.bold(), 3))
	var boot_note := HudKit.label(tr("%s Galleons - carries your party anywhere") % _galleons(int(HPEquipment.item(BOOT).get("buy_price", 0))), 12, HudKit.TEXT_DIM, HudKit.body(), 2)
	boot_note.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	text.add_child(boot_note)
	var buy := HudKit.button(tr("Buy"), 14)
	buy.custom_minimum_size = Vector2(70, 30)
	buy.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	buy.pressed.connect(_buy_item.bind(BOOT, 1))
	row.add_child(buy)
	return card

static func _card_box(bg: Color, rim: Color, alpha: float) -> StyleBoxFlat:
	var sb := StyleBoxFlat.new()
	sb.bg_color = Color(bg.r, bg.g, bg.b, alpha)
	sb.border_color = Color(rim.r, rim.g, rim.b, 0.8)
	sb.set_border_width_all(1)
	sb.set_corner_radius_all(6)
	sb.content_margin_left = 10
	sb.content_margin_right = 10
	sb.content_margin_top = 7
	sb.content_margin_bottom = 7
	sb.anti_aliasing = true
	return sb

## Open at the fireplace `at_node` for `who`.
func open_at(who: Node, at_node: String) -> void:
	player = who
	node_id = at_node
	set_title("Floo Network")  # i18n
	if _here_label != null:
		_here_label.text = tr("You stand at the hearth of %s") % I18n.t(String(HPMaps.travel_node(at_node).get("label", "")))
	if is_instance_valid(player) and player.has_signal("equipment_answer") \
			and not player.equipment_answer.is_connected(_answer):
		player.equipment_answer.connect(_answer)
	refresh()
	open()

func _process(_delta: float) -> void:
	if visible:
		_refresh_powder()

func _powder_count() -> int:
	var n := 0
	if is_instance_valid(player):
		for entry in player.get("inventory"):
			if String((entry as Dictionary).get("id", "")) == POWDER:
				n += int((entry as Dictionary).get("amount", 1))
	return n

func _refresh_powder() -> void:
	if _powder_label == null:
		return
	var price := int(HPEquipment.item(POWDER).get("buy_price", 0))
	var count := _powder_count()
	_powder_label.text = (tr("Floo Powder: %d pinch") if count == 1 else tr("Floo Powder: %d pinches")) % count
	_price_label.text = tr("%s Galleons a pinch, one per journey") % _galleons(price)
	var cost := int(HPMaps.floo_rules().get("cost", 1))
	for button in _travel_buttons:
		if is_instance_valid(button):
			button.disabled = count < cost

static func _galleons(n: int) -> String:
	var s := str(n)
	var out := ""
	while s.length() > 3:
		out = "," + s.right(3) + out
		s = s.left(s.length() - 3)
	return s + out

func refresh() -> void:
	if _list == null:
		return
	for child in _list.get_children():
		child.queue_free()
	_travel_buttons.clear()
	var level := int(player.get("level")) if is_instance_valid(player) else 1
	# Group the hearths by map, in the order travel.json lists them.
	var groups: Dictionary = {}
	for id in HPMaps.travel_nodes().keys():
		var dest: Dictionary = HPMaps.travel_nodes()[id]
		if String(id) == node_id or String(dest.get("kind", "")) != "floo":
			continue
		var map_id := String(dest.get("map", ""))
		if not groups.has(map_id):
			groups[map_id] = []
		(groups[map_id] as Array).append(String(id))
	for map_id in groups:
		var heading := HudKit.label(HPMaps.display_name(String(map_id)), 12, HudKit.GOLD, HudKit.bold(), 3)
		_list.add_child(heading)
		for id in groups[map_id]:
			_list.add_child(_destination(String(id), level))
	_refresh_powder()

## One hearth: a card with its name, a line saying what it takes, and the
## Travel button (or the level it waits for).
func _destination(id: String, level: int) -> PanelContainer:
	var dest := HPMaps.travel_node(id)
	var need := int(dest.get("level_min", 1))
	var open_to_travel := level >= need
	var card := PanelContainer.new()
	card.add_theme_stylebox_override("panel", _card_box(HudKit.NAVY_LT if open_to_travel else HudKit.INK,
		EMERALD if open_to_travel else HudKit.GOLD_DK, 0.92 if open_to_travel else 0.75))
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 10)
	card.add_child(row)
	var glyph := UITheme.icon_rect("ui_portal" if open_to_travel else "ui_lock", 30)
	if not open_to_travel:
		glyph.modulate = Color(1, 1, 1, 0.55)
	row.add_child(glyph)
	var text := VBoxContainer.new()
	text.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	text.add_theme_constant_override("separation", 0)
	row.add_child(text)
	var name_label := HudKit.label(I18n.t(String(dest.get("label", id))), 16,
		HudKit.GOLD_HI if open_to_travel else HudKit.TEXT_DIM, HudKit.bold(), 3)
	name_label.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
	name_label.clip_text = true
	text.add_child(name_label)
	var note := tr("1 pinch of Floo Powder")
	if level < need:
		note = tr("Requires level %d (you are %d)") % [need, level]
	var note_label := HudKit.label(note, 12, EMERALD.darkened(0.1) if open_to_travel else HudKit.TEXT_DIM.darkened(0.15), HudKit.body(), 2)
	note_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	text.add_child(note_label)
	if not open_to_travel:
		var badge := HudKit.label(tr("Lv %d") % need, 14, Color(0.9, 0.45, 0.35), HudKit.bold(), 3)
		badge.size_flags_vertical = Control.SIZE_SHRINK_CENTER
		row.add_child(badge)
	else:
		var go := HudKit.button(tr("Travel"), 14)
		go.custom_minimum_size = Vector2(92, 34)
		go.size_flags_vertical = Control.SIZE_SHRINK_CENTER
		go.pressed.connect(_travel.bind(id))
		row.add_child(go)
		_travel_buttons.append(go)
	return card

func _travel(dest_id: String) -> void:
	if not is_instance_valid(player):
		return
	close()
	if on_travel.is_valid():
		on_travel.call(node_id, dest_id)
	else:
		SimNet.request_travel(player, node_id, dest_id)

func _buy(amount: int) -> void:
	_buy_item(POWDER, amount)

func _buy_item(item_id: String, amount: int) -> void:
	if not is_instance_valid(player):
		return
	_bought = item_id
	_buy_id = SimNet.submit_equipment(player, "buy", "", item_id, amount, 0)

func _answer(answer: Dictionary) -> void:
	if not visible or int(answer.get("request_id", -2)) != _buy_id:
		return
	_buy_id = -1
	var hud: Node = get_parent().get_parent() if get_parent() != null else null
	var reason := String(answer.get("reason", ""))
	var fails := {"no_gold": tr("Not enough Galleons."), "bag_full": tr("Your bag is full.")}
	var text := tr("%s bought.") % I18n.t(String(HPEquipment.item(_bought).get("name", _bought)))
	if not bool(answer.get("ok", false)):
		text = String(fails.get(reason, tr("The fireplace keeper shakes his head.")))
	if hud != null and hud.has_method("show_notice"):
		hud.show_notice(text, "good" if bool(answer.get("ok", false)) else "warn")
	var audio := get_node_or_null("/root/AudioManager")
	if audio != null and bool(answer.get("ok", false)):
		audio.play_sound_at("ui_coin", Vector3.ZERO, null, true)
	refresh()
