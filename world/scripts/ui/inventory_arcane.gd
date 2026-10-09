extends Control

const SLOT_LABELS := {"head":"Head", "chest":"Robes", "hands":"Hands", "feet":"Feet", "main_hand":"Wand", "off_hand":"Focus", "neck":"Neck", "ring_left":"Ring I", "ring_right":"Ring II", "broom":"Broom"}
const REASONS := {"in_combat":"Wait five seconds after combat.", "casting":"Finish casting first.", "dead":"You are defeated.", "mounted":"Dismount before changing your broom.", "bag_full":"No room for the replaced item.", "wrong_slot":"That item does not fit.", "item_missing":"That item is no longer available.", "stale_inventory":"Inventory changed. Please try again.", "stale_request":"Action already handled.", "no_gold":"Not enough Galleons.", "no_material":"Missing refinement material.", "no_wand":"Equip a wand first.", "max_tier":"Already fully refined.", "refined":"Wand refined!", "refinement_failed":"Refinement failed.", "save_conflict":"Inventory refreshed from your saved character.", "transfer_pending":"Wait until the map loads.", "invalid_state":"Equipment temporarily unavailable.", "resource_full":"That resource is already full.", "consumed":"Potion used."}
var player: Node3D
var item_container: GridContainer
var galleons_label: Label
var close_button: Button
var _window: UIWindow
var _tooltip: ItemTooltip
var _doll_slots: Array[UISlot] = []
var _bag_slots: Array[UISlot] = []
var _tabs: TabContainer
var _columns: HBoxContainer
var _gear_page: VBoxContainer
var _bag_page: VBoxContainer
var _preview: CharacterPreview
var _stats: Label
var _details: Label
var _message: Label
var _ring_menu: PopupMenu
var _ring_entry: Dictionary = {}
var _pending := false
var _pending_id := -1
var _last_operation := ""
var _compact := false
var _selected_key := ""
var _presentation_layer: CanvasLayer

func _ready() -> void:
	theme = UITheme.get_theme()
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	_presentation_layer = CanvasLayer.new()
	_presentation_layer.layer = 10
	add_child(_presentation_layer)
	_window = UIWindow.new("CHARACTER & SATCHEL", Vector2(790, 490))
	_window.name = "Window"
	_window.header_icon = "ui_inventory"
	_window.closed.connect(hide)
	_presentation_layer.add_child(_window)
	_window.theme_type_variation = &"ArcaneWindow"
	ArcaneSkin.decorate(_window)
	close_button = _window._close_button
	_window._ribbon.add_theme_stylebox_override("panel", ArcaneSkin.surface())
	_columns = HBoxContainer.new()
	_columns.add_theme_constant_override("separation", 16)
	_columns.size_flags_vertical = Control.SIZE_EXPAND_FILL
	_window.body.add_child(_columns)
	_tabs = TabContainer.new()
	_tabs.size_flags_vertical = Control.SIZE_EXPAND_FILL
	_tabs.hide()
	_window.body.add_child(_tabs)
	_gear_page = VBoxContainer.new()
	_gear_page.name = "Equipment"
	_gear_page.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_columns.add_child(_gear_page)
	var doll := HBoxContainer.new()
	doll.size_flags_vertical = Control.SIZE_EXPAND_FILL
	_gear_page.add_child(doll)
	var left := VBoxContainer.new()
	doll.add_child(left)
	_preview = CharacterPreview.new()
	doll.add_child(_preview)
	var right := VBoxContainer.new()
	doll.add_child(right)
	var order := ["head", "chest", "hands", "feet", "main_hand", "neck", "ring_left", "ring_right", "off_hand", "broom"]
	for i in order.size():
		var slot := _make_slot(Vector2(48,48))
		slot.equipment_slot = order[i]
		slot.caption = SLOT_LABELS[order[i]]
		slot.tooltip_text = slot.caption
		(left if i < 5 else right).add_child(slot)
		_doll_slots.append(slot)
	_stats = UITheme.body("", 13)
	_stats.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_gear_page.add_child(_stats)
	_bag_page = VBoxContainer.new()
	_bag_page.name = "Bag"
	_bag_page.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_columns.add_child(_bag_page)
	_bag_page.add_child(UITheme.heading("SATCHEL", 18))
	var scroll := ScrollContainer.new()
	scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
	scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	_bag_page.add_child(scroll)
	item_container = GridContainer.new()
	item_container.name = "ItemGrid"
	item_container.columns = 6
	item_container.add_theme_constant_override("h_separation", 5)
	item_container.add_theme_constant_override("v_separation", 5)
	scroll.add_child(item_container)
	_details = UITheme.body("Select an item to inspect it.", 13)
	_details.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_details.custom_minimum_size.y = 42
	_bag_page.add_child(_details)
	galleons_label = UITheme.body("", 15, UITheme.c("gold_hi"))
	_window.body.add_child(galleons_label)
	_message = UITheme.body("Right-click / double-click to equip · Drag to a slot", 13)
	_message.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_window.body.add_child(_message)
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
	_window.open()
	show()
	_layout()
	if _compact: _tabs.current_tab = 0

func refresh() -> void:
	if not is_instance_valid(player): return
	galleons_label.text = "Galleons: %d" % player.galleons
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
		var slot := _make_slot(Vector2(48,48))
		slot.set_item(entry.id, entry)
		slot.selected = _selection_key(slot) == _selected_key
		slot.disabled = _pending
		item_container.add_child(slot)
		_bag_slots.append(slot)
	while item_container.get_child_count() < 24: item_container.add_child(_make_slot(Vector2(48,48)))
	var stats := HPEquipment.stats(player.base_max_hp, player.base_max_mana, player.equipment)
	_stats.text = "Health %d   Mana %d\nSpell power ×%.2f   Defense %.0f%%\nBroom speed %.0f" % [stats.max_hp, stats.max_mana, stats.weapon_multiplier * HPRules.wand_multiplier(stats.wand_tier), stats.defense, stats.mount_speed]
	_preview.show_player(player)

func _on_inventory_changed() -> void:
	if visible: refresh()

func _select(slot: UISlot) -> void:
	if slot.item_id == "": return
	_selected_key = _selection_key(slot)
	for other in _doll_slots + _bag_slots: other.selected = _selection_key(other) == _selected_key
	var data := HPEquipment.item(slot.item_id)
	_details.text = "%s\n%s" % [data.get("name", slot.item_id), _comparison(slot)]

func _selection_key(slot: UISlot) -> String:
	return "%s:%s:%d" % [slot.equipment_slot,slot.item_id,int(slot.entry.get("tier",0))]

func _comparison(slot: UISlot, destination_override := "") -> String:
	var destinations: Array = HPEquipment.item(slot.item_id).get("slots", [])
	if destinations.is_empty(): return String(HPEquipment.item(slot.item_id).get("desc", ""))
	var destination: String = slot.equipment_slot if slot.equipment_slot != "" else destinations[0]
	if slot.equipment_slot == "" and "ring_left" in destinations and player.equipment.has("ring_left") and not player.equipment.has("ring_right"): destination = "ring_right"
	if destination_override != "": destination = destination_override
	var gear: Dictionary = player.equipment.duplicate(true)
	if slot.equipment_slot == "": gear[destination] = slot.entry
	else: gear.erase(destination)
	var before := HPEquipment.stats(player.base_max_hp, player.base_max_mana, player.equipment)
	var after := HPEquipment.stats(player.base_max_hp, player.base_max_mana, gear)
	var power_before: float = before.weapon_multiplier * HPRules.wand_multiplier(before.wand_tier)
	var power_after: float = after.weapon_multiplier * HPRules.wand_multiplier(after.wand_tier)
	return "%s: HP %+d · Mana %+d · Power %+.2f · Defense %+.0f%% · Speed %+.0f" % [SLOT_LABELS[destination], after.max_hp-before.max_hp, after.max_mana-before.max_mana, power_after-power_before, after.defense-before.defense, after.mount_speed-before.mount_speed]

func _on_slot_entered(slot: UISlot) -> void:
	if slot.item_id == "" or _tooltip == null: return
	_tooltip.show_item(slot.item_id, slot.entry)
	_tooltip._add_lore(_comparison(slot))
	_tooltip.follow_cursor()

func _on_slot_exited(_slot: UISlot) -> void:
	_tooltip.hide_item()

func _activate(slot: UISlot) -> void:
	if _pending or slot.item_id == "": return
	if slot.equipment_slot != "":
		_request("unequip", slot.equipment_slot)
		return
	var item_data := HPEquipment.item(slot.item_id)
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

func _can_drop(destination: UISlot, payload: Dictionary) -> bool:
	if _pending: return false
	if destination.equipment_slot == "": return payload.get("source_slot", "") != ""
	return payload.get("source_slot", "") == "" and HPEquipment.fits(payload.id, destination.equipment_slot)

func _drop(destination: UISlot, payload: Dictionary) -> void:
	if not _can_drop(destination, payload): return
	if destination.equipment_slot == "": _request("unequip", payload.source_slot)
	else: _request("equip", destination.equipment_slot, payload)

func _request(operation: String, slot: String, entry: Dictionary = {}) -> void:
	if _pending: return
	_pending = true
	_last_operation = operation
	_message.text = "Updating equipment…"
	_pending_id = SimNet.submit_equipment(player, operation, slot, String(entry.get("id", "")), int(entry.get("tier", 0)))
	refresh()

func _answer(answer: Dictionary) -> void:
	if int(answer.get("request_id", -1)) != _pending_id and int(answer.get("request_id", -1)) != -1: return
	_pending = false
	var ok: bool = answer.get("ok", false)
	_message.text = String(REASONS.get(answer.get("reason", ""), "Equipment updated." if ok else "Unable to change equipment."))
	if ok:
		_play_feedback_sound(_last_operation)
	refresh()

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

func _on_visibility_changed() -> void:
	if _presentation_layer: _presentation_layer.visible = visible
	if _preview: _preview.set_active(visible)
	if not visible and _tooltip: _tooltip.hide_item()
	if not visible and _ring_menu: _ring_menu.hide()

func _process(_delta: float) -> void:
	if visible and _tooltip.visible: _tooltip.follow_cursor()

func _layout() -> void:
	if _window == null: return
	var canvas := get_viewport().get_visible_rect().size
	var compact := canvas.x < 880 or canvas.y < 560
	if compact != _compact:
		_compact = compact
		for page in [_gear_page, _bag_page]: page.reparent(_tabs if compact else _columns)
		_columns.visible = not compact
		_tabs.visible = compact
		if compact: _tabs.current_tab = 0
		else:
			_gear_page.show()
			_bag_page.show()
	var extent := Vector2(minf(790, canvas.x-32), minf(490, canvas.y-44))
	_window.custom_minimum_size = Vector2.ZERO
	_window.size = extent
	_window._ribbon.offset_left = -extent.x * 0.5 + 10
	_window._ribbon.offset_right = extent.x * 0.5 - 10
	_window.place_centred(extent)
	item_container.columns = maxi(3, mini(6, int((extent.x-48 if compact else (extent.x-64)*0.5)/53)))
	for slot in _doll_slots: slot.custom_minimum_size = Vector2(32,32) if canvas.y < 480 else Vector2(48,48)
	_preview.custom_minimum_size.y = 130 if canvas.y < 480 else 210

func _on_item_clicked(item_data: Dictionary) -> void:
	if is_instance_valid(player) and not player.is_dead:
		_request("consume", "", item_data)
