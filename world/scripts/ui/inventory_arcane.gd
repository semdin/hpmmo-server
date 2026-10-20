extends Control

## The inventory (I): one vertical window in the Metin2 / Knight Online layout -
## the equipment doll on top, the 5 x 8 satchel below, the purse at the
## bottom. The merchant opens beside it (left) for selling: drag a bag item
## onto the merchant, or right-click it while the merchant is open, then
## confirm the price. Delete throws the selected bag item away (after a yes/no
## question). Every change is a request to the authority
## (`SimNet.submit_equipment`); the window only shows what it answers.

const SLOT_LABELS := {"head":"Head", "chest":"Robes", "hands":"Hands", "feet":"Feet", "main_hand":"Wand", "off_hand":"Focus", "neck":"Neck", "ring_left":"Ring I", "ring_right":"Ring II", "broom":"Broom"}
const REASONS := {"in_combat":"Wait five seconds after combat.", "casting":"Finish casting first.", "dead":"You are defeated.", "mounted":"Dismount before changing your broom.", "level_too_low":"Your level is too low for that item.", "bag_full":"No room for the replaced item.", "wrong_slot":"That item does not fit.", "item_missing":"That item is no longer available.", "stale_inventory":"Inventory changed. Please try again.", "stale_request":"Action already handled.", "no_gold":"Not enough Galleons.", "no_material":"Missing refinement material.", "no_wand":"Equip a wand first.", "max_tier":"Already fully refined.", "refined":"Refined!", "enchanted":"The enchantment holds!", "enchant_failed":"The weave slipped - the scroll is spent.", "no_scroll":"You have no such scroll.", "bonus_full":"This item cannot hold more enchantments.", "no_bonus":"There is nothing to reweave yet.", "not_enchantable":"That item cannot be enchanted.", "nothing_equipped":"Equip an item in that slot first.", "not_refinable":"That item cannot be refined.", "refinement_failed":"Refinement failed.", "save_conflict":"Inventory refreshed from your saved character.", "transfer_pending":"Wait until the map loads.", "invalid_state":"Equipment temporarily unavailable.", "resource_full":"That resource is already full.", "consumed":"", "sold":"", "not_sellable":"No merchant wants that.", "destroyed":"", "not_destroyable":"Gear cannot be destroyed. Sell it to a merchant instead."}
const COLUMNS := 5
const ROWS := 8
const DOLL_LEFT := ["head", "chest", "hands", "feet", "main_hand"]
const DOLL_RIGHT := ["neck", "ring_left", "ring_right", "off_hand", "broom"]
const MERCHANT_W := 236.0

var player: Node3D
var item_container: GridContainer
var galleons_label: Label
var close_button: Button
var _window: UIWindow
var _tooltip: ItemTooltip
var _doll_slots: Array[UISlot] = []
var _bag_slots: Array[UISlot] = []
var _preview: CharacterPreview
var _ring_menu: PopupMenu
var _ring_entry: Dictionary = {}
var _merchant_button: Button
var _footer: HBoxContainer
var _pending := false
var _pending_id := -1
var _last_operation := ""
var _selected_key := ""
var _presentation_layer: CanvasLayer
var _bag_px := 44.0
var _doll_px := 38.0
# Merchant
var _merchant: UIWindow
var _offer_box: VBoxContainer
var _offer_slot: UISlot
var _offer_name: Label
var _offer_price: Label
var _offer_hint: Label
var _sell_button: Button
var _sell_entry: Dictionary = {}
var _sold_price := 0
# Destroy (Delete key)
var _hover_slot: UISlot = null
var _destroy_window: UIWindow
var _destroy_text: Label
var _destroy_entry: Dictionary = {}

func _ready() -> void:
	theme = UITheme.get_theme()
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	_presentation_layer = CanvasLayer.new()
	_presentation_layer.layer = 10
	add_child(_presentation_layer)
	_build_inventory()
	_build_merchant()
	_build_destroy_confirm()
	_tooltip = ItemTooltip.new()
	_presentation_layer.add_child(_tooltip)
	_ring_menu = PopupMenu.new()
	_ring_menu.add_item("Replace left ring", 0)
	_ring_menu.add_item("Replace right ring", 1)
	_ring_menu.id_pressed.connect(func(id): _request("equip", "ring_left" if id == 0 else "ring_right", _ring_entry))
	add_child(_ring_menu)
	visibility_changed.connect(_on_visibility_changed)
	get_viewport().size_changed.connect(_layout)
	_layout()
	hide()

func _make_window(title: String, icon: String, size: Vector2) -> UIWindow:
	var window := ArcaneSkin.window(title, size, icon)
	_presentation_layer.add_child(window)
	return window

func _build_inventory() -> void:
	_window = _make_window("INVENTORY", "ui_inventory", Vector2(272, 700))
	_window.name = "Window"
	_window.closed.connect(hide)
	close_button = _window._close_button
	# Equipment doll: five slots each side of the character.
	var doll := HBoxContainer.new()
	doll.add_theme_constant_override("separation", 8)
	_window.body.add_child(doll)
	var left := VBoxContainer.new()
	left.add_theme_constant_override("separation", 4)
	doll.add_child(left)
	_preview = CharacterPreview.new()
	_preview.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	doll.add_child(_preview)
	var right := VBoxContainer.new()
	right.add_theme_constant_override("separation", 4)
	doll.add_child(right)
	for slot_id in DOLL_LEFT + DOLL_RIGHT:
		var slot := _make_slot(Vector2(_doll_px, _doll_px))
		slot.equipment_slot = slot_id
		slot.caption = SLOT_LABELS[slot_id]
		(left if slot_id in DOLL_LEFT else right).add_child(slot)
		_doll_slots.append(slot)
	_window.body.add_child(UITheme.divider())
	# The satchel: always 5 x 8 cells, filled in bag order.
	item_container = GridContainer.new()
	item_container.name = "ItemGrid"
	item_container.columns = COLUMNS
	item_container.add_theme_constant_override("h_separation", 4)
	item_container.add_theme_constant_override("v_separation", 4)
	item_container.size_flags_horizontal = Control.SIZE_SHRINK_CENTER
	_window.body.add_child(item_container)
	_window.body.add_child(UITheme.divider())
	# Footer: the merchant toggle and the purse.
	var footer := HBoxContainer.new()
	_footer = footer
	footer.add_theme_constant_override("separation", 6)
	_window.body.add_child(footer)
	_merchant_button = Button.new()
	_merchant_button.text = "Merchant"
	_merchant_button.toggle_mode = true
	_merchant_button.focus_mode = Control.FOCUS_NONE
	_merchant_button.tooltip_text = "Open the merchant to sell items"
	_merchant_button.toggled.connect(func(on: bool): _set_merchant_open(on))
	footer.add_child(_merchant_button)
	var spacer := Control.new()
	spacer.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	footer.add_child(spacer)
	footer.add_child(_coin_icon(18))
	galleons_label = UITheme.body("0", UITheme.FS_LABEL, UITheme.c("gold_hi"))
	galleons_label.tooltip_text = "Galleons"
	galleons_label.mouse_filter = Control.MOUSE_FILTER_PASS
	footer.add_child(galleons_label)
	footer.add_child(UITheme.body("Galleons", UITheme.FS_SMALL, UITheme.c("gold_lt")))

func _build_merchant() -> void:
	_merchant = _make_window("MERCHANT", "currency_galleons", Vector2(MERCHANT_W, 262))
	_merchant.name = "Merchant"
	_merchant.closed.connect(func():
		_merchant_button.set_pressed_no_signal(false)
		_clear_offer())
	_merchant.hide()
	_offer_hint = UITheme.body("Drag an item here, or right-click it in your bag.", UITheme.FS_SMALL, UITheme.c("text_dim"))
	_offer_hint.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_offer_hint.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_merchant.body.add_child(_offer_hint)
	# The drop zone holds the item being priced.
	var zone := PanelContainer.new()
	var zone_box := StyleBoxFlat.new()
	zone_box.bg_color = Color("0a111c")
	zone_box.border_color = UITheme.c("gold_dk")
	zone_box.set_border_width_all(1)
	zone_box.set_corner_radius_all(4)
	zone_box.set_content_margin_all(10)
	zone.add_theme_stylebox_override("panel", zone_box)
	zone.custom_minimum_size = Vector2(0, 140)
	zone.set_drag_forwarding(Callable(), _merchant_can_drop, _merchant_drop)
	_merchant.body.add_child(zone)
	_offer_box = VBoxContainer.new()
	_offer_box.alignment = BoxContainer.ALIGNMENT_CENTER
	_offer_box.add_theme_constant_override("separation", 6)
	_offer_box.mouse_filter = Control.MOUSE_FILTER_IGNORE
	zone.add_child(_offer_box)
	_offer_slot = UISlot.new(Vector2(52, 52))
	_offer_slot.size_flags_horizontal = Control.SIZE_SHRINK_CENTER
	_offer_slot.ready.connect(func():
		_offer_slot.theme_type_variation = &"ArcaneSlot"
		_offer_slot.mouse_filter = Control.MOUSE_FILTER_IGNORE)
	_offer_box.add_child(_offer_slot)
	_offer_name = UITheme.body("", UITheme.FS_BODY, UITheme.c("gold_hi"))
	_offer_name.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_offer_name.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_offer_box.add_child(_offer_name)
	var price_row := HBoxContainer.new()
	price_row.alignment = BoxContainer.ALIGNMENT_CENTER
	price_row.add_theme_constant_override("separation", 6)
	price_row.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_offer_box.add_child(price_row)
	price_row.add_child(_coin_icon(16))
	_offer_price = UITheme.body("", UITheme.FS_LABEL, UITheme.c("gold_hi"))
	price_row.add_child(_offer_price)
	var buttons := HBoxContainer.new()
	buttons.add_theme_constant_override("separation", 6)
	_merchant.body.add_child(buttons)
	_sell_button = Button.new()
	_sell_button.text = "Sell"
	_sell_button.focus_mode = Control.FOCUS_NONE
	_sell_button.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_sell_button.pressed.connect(_sell_offer)
	buttons.add_child(_sell_button)
	var cancel := Button.new()
	cancel.text = "Cancel"
	cancel.focus_mode = Control.FOCUS_NONE
	cancel.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	cancel.pressed.connect(_clear_offer)
	buttons.add_child(cancel)
	_clear_offer()

func _coin_icon(px: int) -> TextureRect:
	var coin := TextureRect.new()
	coin.texture = UITheme.icon_for("currency_galleons")
	coin.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	coin.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
	coin.custom_minimum_size = Vector2(px, px)
	coin.mouse_filter = Control.MOUSE_FILTER_IGNORE
	return coin

## 22874 -> "22,874"
static func galleon_text(amount: int) -> String:
	var digits := str(absi(amount))
	var out := ""
	while digits.length() > 3:
		out = "," + digits.substr(digits.length() - 3) + out
		digits = digits.substr(0, digits.length() - 3)
	return ("-" if amount < 0 else "") + digits + out

func _make_slot(minimum: Vector2) -> UISlot:
	var slot := UISlot.new(minimum)
	slot.equipment_interaction = true
	slot.activated.connect(_activate)
	slot.pressed.connect(func(): _select(slot))
	slot.slot_entered.connect(_on_slot_entered)
	slot.slot_exited.connect(_on_slot_exited)
	slot.dropped.connect(_drop)
	slot.drop_check = _can_drop
	slot.ready.connect(func(): slot.theme_type_variation = &"ArcaneSlot")
	return slot

func open_for_player(value: Node3D) -> void:
	if player != value and is_instance_valid(player):
		if player.inventory_changed.is_connected(_on_inventory_changed): player.inventory_changed.disconnect(_on_inventory_changed)
		if player.equipment_answer.is_connected(_answer): player.equipment_answer.disconnect(_answer)
	player = value
	if not player.inventory_changed.is_connected(_on_inventory_changed): player.inventory_changed.connect(_on_inventory_changed)
	if not player.equipment_answer.is_connected(_answer): player.equipment_answer.connect(_answer)
	refresh()
	show()
	_window.open()
	_layout()

func refresh() -> void:
	if not is_instance_valid(player): return
	galleons_label.text = galleon_text(int(player.galleons))
	for slot in _doll_slots:
		var entry: Dictionary = player.equipment.get(slot.equipment_slot, {})
		slot.set_item(String(entry.get("id", "")), entry)
		slot.selected = _selection_key(slot) == _selected_key
		slot.disabled = _pending
	for child in item_container.get_children():
		item_container.remove_child(child)
		child.queue_free()
	_bag_slots.clear()
	for entry in player.inventory:
		if int(entry.get("amount", 0)) <= 0: continue
		var slot := _make_slot(Vector2(_bag_px, _bag_px))
		slot.set_item(entry.id, entry)
		slot.selected = _selection_key(slot) == _selected_key
		slot.disabled = _pending or _locked(entry)
		if _locked(entry): slot.modulate = Color(1, 1, 1, 0.35)   # on Ollivander's anvil
		item_container.add_child(slot)
		_bag_slots.append(slot)
	while item_container.get_child_count() < COLUMNS * ROWS:
		item_container.add_child(_make_slot(Vector2(_bag_px, _bag_px)))
	_preview.show_player(player)
	# The staged sale may have left the bag (sold, equipped, consumed).
	if not _sell_entry.is_empty() and _bag_entry(_sell_entry).is_empty():
		_clear_offer()
	_sell_button.disabled = _pending or _sell_entry.is_empty()

func _on_inventory_changed() -> void:
	if visible: refresh()

func _select(slot: UISlot) -> void:
	if slot.item_id == "": return
	_selected_key = _selection_key(slot)
	for other in _doll_slots + _bag_slots: other.selected = _selection_key(other) == _selected_key

func _selection_key(slot: UISlot) -> String:
	return "%s:%s:%d:%d" % [slot.equipment_slot, slot.item_id, int(slot.entry.get("tier", 0)), int(slot.entry.get("uid", 0))]

## What changes if the item is worn - only the stats that actually move.
func _comparison(slot: UISlot, destination_override := "") -> String:
	var destinations: Array = HPEquipment.item(slot.item_id).get("slots", [])
	if destinations.is_empty(): return ""
	var destination: String = slot.equipment_slot if slot.equipment_slot != "" else destinations[0]
	if slot.equipment_slot == "" and "ring_left" in destinations and player.equipment.has("ring_left") and not player.equipment.has("ring_right"): destination = "ring_right"
	if destination_override != "": destination = destination_override
	var gear: Dictionary = player.equipment.duplicate(true)
	if slot.equipment_slot == "": gear[destination] = slot.entry
	else: gear.erase(destination)
	var before := HPEquipment.stats(player.base_max_hp, player.base_max_mana, player.equipment)
	var after := HPEquipment.stats(player.base_max_hp, player.base_max_mana, gear)
	var parts: Array = []
	var magic := _mid_attack(after, "magic_attack") - _mid_attack(before, "magic_attack")
	if absf(magic) >= 0.5: parts.append("Magic Attack %+.0f" % magic)
	var spell := float(after.spell_power) - float(before.spell_power)
	if absf(spell) >= 0.5: parts.append("Spell Power %+.0f%%" % spell)
	if after.max_hp != before.max_hp: parts.append("Health %+d" % (after.max_hp - before.max_hp))
	if after.max_mana != before.max_mana: parts.append("Mana %+d" % (after.max_mana - before.max_mana))
	if int(after.armor) != int(before.armor): parts.append("Armour %+d" % (int(after.armor) - int(before.armor)))
	if not is_equal_approx(after.move_speed, before.move_speed): parts.append("Move %+.0f%%" % (after.move_speed - before.move_speed))
	if not is_equal_approx(after.mount_speed, before.mount_speed): parts.append("Speed %+.0f" % (after.mount_speed - before.mount_speed))
	if parts.is_empty(): return ""
	return "%s: %s" % [SLOT_LABELS[destination], " · ".join(parts)]

## The middle of a wand range at its worn +N (derived stats keep the +0 range).
static func _mid_attack(stats: Dictionary, key: String) -> float:
	var span: Array = stats.get(key, [0, 0])
	return (float(span[0]) + float(span[1])) * 0.5 * HPRules.wand_multiplier(int(stats.get("wand_tier", 0)))

func _on_slot_entered(slot: UISlot) -> void:
	_hover_slot = slot
	if slot.item_id == "" or _tooltip == null: return
	_tooltip.show_item(slot.item_id, slot.entry)
	if slot != _offer_slot and is_instance_valid(player):
		if _merchant.visible and slot.equipment_slot == "":
			var price := _price_of(slot.entry)
			if price > 0: _tooltip._add_lore("Sells for %s Galleons" % galleon_text(price))
	_tooltip.follow_cursor()

func _on_slot_exited(slot: UISlot) -> void:
	if _hover_slot == slot: _hover_slot = null
	_tooltip.hide_item()

func _activate(slot: UISlot) -> void:
	if _pending or slot.item_id == "": return
	if _locked(slot.entry): return
	if slot.equipment_slot != "":
		_request("unequip", slot.equipment_slot)
		return
	# With Ollivander open, right-click puts the item on his anvil.
	var workshop := _workshop()
	if workshop != null and workshop.visible and workshop._accepts(slot.entry.merged({"id": slot.item_id})):
		workshop.set_target(int(slot.entry.get("uid", 0)))
		return
	# With the merchant open, right-click prices the item instead of using it.
	if _merchant.visible:
		_offer(slot.entry)
		return
	var item_data := HPEquipment.item(slot.item_id)
	# An Old Boot is a Portkey: choose where it goes, the authority sets it down.
	if slot.item_id == String(HPMaps.portkey_rules().get("item", "portkey_boot")):
		var hud = get_parent().get_node_or_null("HUD") if get_parent() != null else null
		if hud != null and hud.get("portkey") != null:
			hud.portkey.open_for(player)
		return
	if item_data.get("type") == "consumable" or slot.item_id in ["potion_health", "potion_mana"]:
		_on_item_clicked(slot.entry)
		return
	var targets: Array = item_data.get("slots", [])
	if targets.is_empty(): return
	if "ring_left" in targets:
		for target in targets:
			if not player.equipment.has(target):
				_request("equip", target, slot.entry)
				return
		_ring_entry = slot.entry.duplicate(true)
		for index in 2:
			var destination: String = ["ring_left","ring_right"][index]
			var worn: Dictionary = player.equipment[destination]
			_ring_menu.set_item_text(index, "%s: replace %s" % [SLOT_LABELS[destination],HPEquipment.item(worn.id).get("name",worn.id)])
			_ring_menu.set_item_tooltip(index, _comparison(slot,destination))
		_ring_menu.position = DisplayServer.mouse_get_position()
		_ring_menu.popup()
	else: _request("equip", targets[0], slot.entry)

## A bag item on Ollivander's anvil stays put until it leaves the anvil.
func _locked(entry: Dictionary) -> bool:
	var workshop := _workshop()
	return workshop != null and workshop.has_method("holds") and workshop.holds(int(entry.get("uid", 0)))

func _can_drop(destination: UISlot, payload: Dictionary) -> bool:
	if _pending or _locked(payload): return false
	if destination.equipment_slot == "": return payload.get("source_slot", "") != ""
	return payload.get("source_slot", "") == "" and HPEquipment.fits(payload.id, destination.equipment_slot)

func _drop(destination: UISlot, payload: Dictionary) -> void:
	if not _can_drop(destination, payload): return
	if destination.equipment_slot == "": _request("unequip", payload.source_slot)
	else: _request("equip", destination.equipment_slot, payload)

# ------------------------------------------------------------------ merchant

func _workshop() -> Control:
	return get_parent().get_node_or_null("OllivanderUI") as Control if get_parent() != null else null

func _set_merchant_open(on: bool) -> void:
	_merchant_button.set_pressed_no_signal(on)
	if on:
		var workshop := _workshop()
		if workshop != null: workshop.hide()
		_merchant.open()
		_place_merchant()
	else:
		_merchant.hide()
		_clear_offer()

## The bag entry a payload / staged entry names (by uid, else id + tier).
func _bag_entry(entry: Dictionary) -> Dictionary:
	if not is_instance_valid(player): return {}
	var uid := int(entry.get("uid", 0))
	for held in player.inventory:
		if int(held.get("amount", 0)) <= 0: continue
		if uid > 0 and int(held.get("uid", 0)) == uid: return held
		if uid == 0 and String(held.id) == String(entry.get("id", "")) and int(held.get("tier", 0)) == int(entry.get("tier", 0)) and int(held.get("uid", 0)) == 0: return held
	return {}

## What the merchant pays for this bag entry (a stack sells whole).
func _price_of(entry: Dictionary) -> int:
	var each := HPEquipment.sell_price(String(entry.get("id", "")), int(entry.get("tier", 0)))
	return each * (1 if int(entry.get("uid", 0)) > 0 else maxi(1, int(entry.get("amount", 1))))

func _merchant_can_drop(_at: Vector2, payload: Variant) -> bool:
	return not _pending and payload is Dictionary and payload.get("arcane_item", false) and String(payload.get("source_slot", "")) == "" \
		and not _locked(payload)

func _merchant_drop(_at: Vector2, payload: Variant) -> void:
	if _merchant_can_drop(_at, payload): _offer(payload)

func _offer(entry: Dictionary) -> void:
	var held := _bag_entry(entry)
	if held.is_empty(): return
	var price := _price_of(held)
	if price <= 0:
		_notify(REASONS["not_sellable"], "warn")
		return
	_sell_entry = held.duplicate(true)
	_offer_slot.set_item(String(held.id), held)
	var name := String(HPEquipment.item(held.id).get("name", held.id))
	if int(held.get("tier", 0)) > 0: name += " +%d" % int(held.tier)
	if int(held.get("amount", 1)) > 1: name += "  x%d" % int(held.amount)
	_offer_name.text = name
	_offer_price.text = galleon_text(price)
	_offer_box.get_child(2).visible = true
	_offer_hint.text = "Sell this item?"
	_sell_button.disabled = _pending

func _clear_offer() -> void:
	_sell_entry = {}
	if _offer_slot == null: return
	_offer_slot.set_item("", {})
	_offer_name.text = ""
	_offer_price.text = ""
	_offer_box.get_child(2).visible = false
	_offer_hint.text = "Drag an item here, or right-click it in your bag."
	_sell_button.disabled = true

func _sell_offer() -> void:
	if _sell_entry.is_empty() or not is_instance_valid(player) or player.is_dead: return
	_sold_price = _price_of(_sell_entry)
	_request("sell", "", _sell_entry)

# ------------------------------------------------------------------ destroy

func _build_destroy_confirm() -> void:
	_destroy_window = _make_window("DESTROY ITEM", "ui_inventory", Vector2(340, 190))
	_destroy_window.name = "DestroyConfirm"
	_destroy_window.closed.connect(func(): _destroy_entry = {})
	_destroy_window.hide()
	_destroy_text = UITheme.body("", UITheme.FS_BODY, UITheme.c("parchment"))
	_destroy_text.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_destroy_text.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_destroy_text.size_flags_vertical = Control.SIZE_EXPAND_FILL
	_destroy_window.body.add_child(_destroy_text)
	var buttons := HBoxContainer.new()
	buttons.add_theme_constant_override("separation", 8)
	_destroy_window.body.add_child(buttons)
	for spec in [["Yes", _confirm_destroy], ["No", func(): _destroy_window.close()]]:
		var b := Button.new()
		b.text = spec[0]
		b.focus_mode = Control.FOCUS_NONE
		b.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		b.pressed.connect(spec[1])
		buttons.add_child(b)

## Delete: the selected bag item (else the one under the cursor). Gear (an
## item with an equipment slot) is refused - only stacks and materials go;
## an item on Ollivander's anvil stays.
func _unhandled_key_input(event: InputEvent) -> void:
	if not visible or not (event is InputEventKey) or not event.pressed or event.echo:
		return
	if _destroy_window.visible:
		if event.keycode in [KEY_ENTER, KEY_KP_ENTER, KEY_Y]:
			_confirm_destroy()
			get_viewport().set_input_as_handled()
		elif event.keycode in [KEY_ESCAPE, KEY_N]:
			_destroy_window.close()
			get_viewport().set_input_as_handled()
		return
	if event.keycode != KEY_DELETE:
		return
	var slot: UISlot = null
	for candidate in _bag_slots:
		if candidate.item_id != "" and _selection_key(candidate) == _selected_key:
			slot = candidate
	if slot == null and _hover_slot != null and is_instance_valid(_hover_slot) and _hover_slot in _bag_slots:
		slot = _hover_slot
	get_viewport().set_input_as_handled()
	if slot == null or slot.item_id == "":
		_notify("Select an item in your bag first.", "warn")
		return
	if _pending or _locked(slot.entry):
		return
	if HPEquipment.equippable(slot.item_id):
		_notify(REASONS["not_destroyable"], "warn")
		return
	_ask_destroy(slot.entry.merged({"id": slot.item_id}))

func _ask_destroy(entry: Dictionary) -> void:
	_destroy_entry = entry.duplicate(true)
	var name := String(HPEquipment.item(String(entry.get("id", ""))).get("name", entry.get("id", "")))
	var tier := int(entry.get("tier", 0))
	if tier > 0:
		name += " +%d" % tier
	var amount := int(entry.get("amount", 1))
	if amount > 1:
		name += " x%d" % amount
	_destroy_text.text = "Destroy %s?
It is gone for good." % name
	var canvas := get_viewport().get_visible_rect().size
	ArcaneSkin.place(_destroy_window, ((canvas - Vector2(340, 190)) * 0.5).floor(), Vector2(340, 190))
	_destroy_window.open()

func _confirm_destroy() -> void:
	if _destroy_entry.is_empty() or not is_instance_valid(player):
		_destroy_window.close()
		return
	var entry := _destroy_entry
	_destroy_window.close()
	if _bag_entry(entry).is_empty():
		return
	_selected_key = ""
	_request("destroy", "", entry)

# ------------------------------------------------------------------ requests

func _request(operation: String, slot: String, entry: Dictionary = {}) -> void:
	if _pending: return
	_pending = true
	_last_operation = operation
	_pending_id = SimNet.submit_equipment(player, operation, slot, String(entry.get("id", "")), int(entry.get("tier", 0)), int(entry.get("uid", 0)))
	refresh()

func _answer(answer: Dictionary) -> void:
	if int(answer.get("request_id", -1)) != _pending_id and int(answer.get("request_id", -1)) != -1: return
	_pending = false
	var ok: bool = answer.get("ok", false)
	var reason := String(answer.get("reason", ""))
	if ok and reason == "sold":
		_clear_offer()
		_notify("Sold for %s Galleons." % galleon_text(_sold_price), "good")
	elif ok and reason == "destroyed":
		_notify("Item destroyed.", "info")
	elif not ok:
		_notify(String(REASONS.get(reason, "Unable to change equipment.")), "warn")
	elif String(REASONS.get(reason, "")) != "":
		_notify(String(REASONS[reason]), "good")
	if ok:
		_play_feedback_sound(_last_operation)
	refresh()

## Feedback goes through the HUD's notice band (no status text in the window).
func _notify(text: String, kind: String) -> void:
	if text == "": return
	var hud := get_parent().get_node_or_null("HUD") if get_parent() != null else null
	if hud != null and hud.has_method("show_notice"):
		hud.show_notice(text, kind)

func _play_feedback_sound(op: String) -> void:
	var audio := get_node_or_null("/root/AudioManager")
	if audio == null: return
	match op:
		"equip":
			if audio.has_method("play_equip"): audio.play_equip()
			else: audio.play_sound_at("ui_equip", Vector3.ZERO, null, true)
		"unequip":
			if audio.has_method("play_unequip"): audio.play_unequip()
			else: audio.play_sound_at("ui_unequip", Vector3.ZERO, null, true)
		"consume":
			if audio.has_method("play_potion"): audio.play_potion()
			else: audio.play_sound_at("ui_potion", Vector3.ZERO, null, true)
		"sell":
			audio.play_sound_at("ui_coin", Vector3.ZERO, null, true)

func _on_visibility_changed() -> void:
	if _presentation_layer: _presentation_layer.visible = visible
	if _preview: _preview.set_active(visible)
	if not visible:
		if _tooltip: _tooltip.hide_item()
		if _ring_menu: _ring_menu.hide()
		if _merchant: _set_merchant_open(false)
		if _destroy_window: _destroy_window.close()

func _process(_delta: float) -> void:
	if visible and _tooltip.visible: _tooltip.follow_cursor()
	# Galleons arrive with the stats payload (auto-collected coin, quest pay),
	# not as a bag change, so the footer follows the live number.
	if visible and is_instance_valid(player) and galleons_label != null:
		var text := galleon_text(int(player.galleons))
		if galleons_label.text != text: galleons_label.text = text

## Size the cells to the screen (8 rows must fit), then dock the window on the
## right edge, vertically centred; the merchant sits to its left.
func _layout() -> void:
	if _window == null: return
	var canvas := get_viewport().get_visible_rect().size
	_bag_px = clampf(floorf((canvas.y - 360.0) / ROWS) - 4.0, 30.0, 44.0)
	_doll_px = clampf(_bag_px - 6.0, 28.0, 38.0)
	for slot in _bag_slots: slot.custom_minimum_size = Vector2(_bag_px, _bag_px)
	for slot in item_container.get_children(): (slot as Control).custom_minimum_size = Vector2(_bag_px, _bag_px)
	for slot in _doll_slots: slot.custom_minimum_size = Vector2(_doll_px, _doll_px)
	_preview.custom_minimum_size = Vector2(0, _doll_px * 5 + 16)
	var width := COLUMNS * _bag_px + (COLUMNS - 1) * 4.0 + 36.0
	width = maxf(width, _footer.get_combined_minimum_size().x + 36.0)
	var height := (RIBBON_TOP + 16.0) + (_doll_px * 5 + 16.0) + ROWS * _bag_px + (ROWS - 1) * 4.0 + 34.0 + 6.0 * 4 + 12.0
	height = minf(height, canvas.y - 24.0)
	_window.custom_minimum_size = Vector2(width, height)
	_window.size = Vector2(width, height)
	_window._ribbon.offset_left = -width * 0.5 + 10
	_window._ribbon.offset_right = width * 0.5 - 10
	var x := canvas.x - width - 24.0
	var y := floorf((canvas.y - height) * 0.5)
	_window.offset_left = x
	_window.offset_top = y
	_window.offset_right = x + width
	_window.offset_bottom = y + height
	_place_merchant()

const RIBBON_TOP := UIWindow.RIBBON_H - UIWindow.RIBBON_OVERHANG + 10.0

func _place_merchant() -> void:
	if _merchant == null or _window == null: return
	var h := 262.0
	_merchant.size = Vector2(MERCHANT_W, h)
	var x := maxf(8.0, _window.offset_left - MERCHANT_W - 12.0)
	var y := _window.offset_top + 40.0
	_merchant.offset_left = x
	_merchant.offset_top = y
	_merchant.offset_right = x + MERCHANT_W
	_merchant.offset_bottom = y + h
	_merchant._ribbon.offset_left = -MERCHANT_W * 0.5 + 10
	_merchant._ribbon.offset_right = MERCHANT_W * 0.5 - 10

func _on_item_clicked(item_data: Dictionary) -> void:
	if is_instance_valid(player) and not player.is_dead:
		_request("consume", "", item_data)
