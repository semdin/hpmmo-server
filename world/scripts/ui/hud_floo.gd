extends HudWindow
class_name HudFloo

## The Floo Network window (interact at a fireplace, data/travel.json). Lists
## every hearth of the network: the ones this character has visited can be
## travelled to for one pinch of Floo Powder, the rest are greyed "not yet
## visited". Floo Powder is sold right here. Everything is decided by the
## authority (SimNet.request_travel / the "buy" equipment operation); this
## window only asks and shows.

const POWDER := "floo_powder"
const BOOT := "portkey_boot"
var _bought := POWDER

var player: Node = null
var node_id := ""
## Set by the map controller: plays the departure flames before the request.
var on_travel: Callable

var _powder_label: Label
var _list: VBoxContainer
var _buy_id := -1

func _init() -> void:
	super._init("Floo Network", Vector2(440, 520))
	name = "FlooNetwork"

func _ready() -> void:
	super._ready()
	var top := HBoxContainer.new()
	top.add_theme_constant_override("separation", 10)
	body.add_child(top)
	var icon := TextureRect.new()
	icon.texture = UITheme.item_icon(POWDER)
	icon.custom_minimum_size = Vector2(44, 44)
	icon.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	icon.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
	top.add_child(icon)
	_powder_label = HudKit.label("", 16, HudKit.PARCHMENT)
	_powder_label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	top.add_child(_powder_label)
	for amount in [1, 5]:
		var buy := Button.new()
		buy.text = "Buy %d" % amount
		buy.focus_mode = Control.FOCUS_NONE
		buy.pressed.connect(_buy.bind(amount))
		top.add_child(buy)
	# The fireplace keeper also sells old boots made into Portkeys.
	var boot_row := HBoxContainer.new()
	boot_row.add_theme_constant_override("separation", 10)
	body.add_child(boot_row)
	var boot_icon := TextureRect.new()
	boot_icon.texture = UITheme.item_icon(BOOT)
	boot_icon.custom_minimum_size = Vector2(36, 36)
	boot_icon.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	boot_icon.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
	boot_row.add_child(boot_icon)
	var boot_label := HudKit.label("Old Boot (Portkey) - %s Galleons" % _galleons(int(HPEquipment.item(BOOT).get("buy_price", 0))), 14, HudKit.PARCHMENT)
	boot_label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	boot_row.add_child(boot_label)
	var buy_boot := Button.new()
	buy_boot.text = "Buy"
	buy_boot.focus_mode = Control.FOCUS_NONE
	buy_boot.pressed.connect(_buy_item.bind(BOOT, 1))
	boot_row.add_child(buy_boot)
	var hint := HudKit.label("Step into the flames and speak your destination clearly.", 13, HudKit.PARCHMENT.darkened(0.25))
	hint.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	body.add_child(hint)
	var scroll := ScrollContainer.new()
	scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
	scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	body.add_child(scroll)
	_list = VBoxContainer.new()
	_list.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_list.add_theme_constant_override("separation", 6)
	scroll.add_child(_list)

## Open at the fireplace `at_node` for `who`.
func open_at(who: Node, at_node: String) -> void:
	player = who
	node_id = at_node
	set_title("Floo Network - %s" % String(HPMaps.travel_node(at_node).get("label", "")))
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
	_powder_label.text = "Floo Powder: %d\n%s Galleons a pinch" % [_powder_count(), _galleons(price)]

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
	_refresh_powder()
	for child in _list.get_children():
		child.queue_free()
	var known: Array = player.call("floo_known") if is_instance_valid(player) and player.has_method("floo_known") else []
	var level := int(player.get("level")) if is_instance_valid(player) else 1
	var cost := int(HPMaps.floo_rules().get("cost", 1))
	for id in HPMaps.travel_nodes().keys():
		var dest: Dictionary = HPMaps.travel_nodes()[id]
		if String(id) == node_id or String(dest.get("kind", "")) != "floo":
			continue
		var row := HBoxContainer.new()
		row.add_theme_constant_override("separation", 8)
		_list.add_child(row)
		var name_label := HudKit.label(String(dest.get("label", id)), 16, HudKit.GOLD_HI)
		name_label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		row.add_child(name_label)
		var where := HudKit.label(HPMaps.display_name(String(dest.get("map", ""))), 12, HudKit.PARCHMENT.darkened(0.3))
		row.add_child(where)
		var go := Button.new()
		go.focus_mode = Control.FOCUS_NONE
		go.custom_minimum_size = Vector2(110, 0)
		var need := int(dest.get("level_min", 1))
		if not known.has(String(id)):
			go.text = "Not visited"
			go.disabled = true
			name_label.modulate = Color(1, 1, 1, 0.45)
		elif level < need:
			go.text = "Level %d" % need
			go.disabled = true
		else:
			go.text = "Travel (%d)" % cost
			go.disabled = _powder_count() < cost
			go.pressed.connect(_travel.bind(String(id)))
		row.add_child(go)

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
	var fails := {"no_gold": "Not enough Galleons.", "bag_full": "Your bag is full."}
	var text := "%s bought." % String(HPEquipment.item(_bought).get("name", _bought))
	if not bool(answer.get("ok", false)):
		text = String(fails.get(reason, "The fireplace keeper shakes his head."))
	if hud != null and hud.has_method("show_notice"):
		hud.show_notice(text, "good" if bool(answer.get("ok", false)) else "warn")
	var audio := get_node_or_null("/root/AudioManager")
	if audio != null and bool(answer.get("ok", false)):
		audio.play_sound_at("ui_coin", Vector3.ZERO, null, true)
	refresh()
