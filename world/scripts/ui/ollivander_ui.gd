extends Control

## Ollivander's workshop (O) - the Metin2 blacksmith. It works on ONE item put
## in its slot: drag a wand, cloak or broom from the bag or the equipment doll
## onto the slot, or right-click it in the bag while the workshop is open. The
## window then shows the item's refinement (+0..+9: chance, galleons,
## material from combat.json `wand_tiers`, bonus curve from `upgrade_curves`)
## and its enchantments (efsun: imbue / reweave scrolls). The authority rolls
## every outcome; requests name the item by its instance uid.
##
## The workshop docks left of the inventory, which opens with it.

signal wand_upgraded(new_tier: int)
signal item_upgraded(slot: String, new_tier: int)

const WIDTH := 300.0
const HEIGHT := 520.0

var player: Node3D = null
## The instance on the anvil (its uid), 0 = empty.
var target_uid := 0
var _pending_id := -1
var _last_op := ""
var _layer: CanvasLayer
var _window: UIWindow
var _slot: UISlot
var _card_lines: VBoxContainer
var _materials: VBoxContainer
var _chance: Label
var _cost: Label
var _refine_button: Button
var _clear_button: Button
var _bonus_label: Label
var _imbue_button: Button
var _reweave_button: Button
var _tooltip: ItemTooltip

func _ready() -> void:
	theme = UITheme.get_theme()
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	_layer = CanvasLayer.new()
	_layer.layer = 10
	add_child(_layer)
	_window = ArcaneSkin.window("OLLIVANDER", Vector2(WIDTH, HEIGHT), "ui_ollivander")
	_window.closed.connect(hide)
	_layer.add_child(_window)
	_build()
	_tooltip = ItemTooltip.new()
	_layer.add_child(_tooltip)
	visibility_changed.connect(func():
		_layer.visible = visible
		_refresh_bag()   # the anvil's lock on a bag slot follows the window
		if not visible and _tooltip != null: _tooltip.hide_item())
	hide()

## Metin2's upgrade window: the item card on top (the anvil slot and what the
## item becomes at the next +N), one row per required material, the chance
## and the cost, then OK / Cancel. Enchanting sits below it.
func _build() -> void:
	var body := _window.body
	body.add_theme_constant_override("separation", 6)
	var card := PanelContainer.new()
	card.add_theme_stylebox_override("panel", _inset())
	body.add_child(card)
	var top := HBoxContainer.new()
	top.add_theme_constant_override("separation", 10)
	card.add_child(top)
	_slot = UISlot.new(Vector2(56, 56))
	_slot.equipment_interaction = true
	_slot.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	_slot.drop_check = func(_s, payload): return _accepts(payload)
	_slot.dropped.connect(func(_s, payload): set_target(int(payload.get("uid", 0))))
	_slot.activated.connect(func(_s): clear_target())
	_slot.slot_entered.connect(func(s):
		if s.item_id != "":
			_tooltip.show_item(s.item_id, s.entry)
			_tooltip.follow_cursor())
	_slot.slot_exited.connect(func(_s): _tooltip.hide_item())
	_slot.ready.connect(func(): _slot.theme_type_variation = &"ArcaneSlot")
	top.add_child(_slot)
	_card_lines = VBoxContainer.new()
	_card_lines.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_card_lines.alignment = BoxContainer.ALIGNMENT_CENTER
	_card_lines.add_theme_constant_override("separation", 1)
	_card_lines.custom_minimum_size = Vector2(0, 96)
	top.add_child(_card_lines)
	_materials = VBoxContainer.new()
	_materials.add_theme_constant_override("separation", 4)
	body.add_child(_materials)
	_chance = _centred(UITheme.c("parchment"))
	_cost = _centred(UITheme.c("gold_hi"))
	body.add_child(_chance)
	body.add_child(_cost)
	var buttons := HBoxContainer.new()
	buttons.alignment = BoxContainer.ALIGNMENT_CENTER
	buttons.add_theme_constant_override("separation", 8)
	body.add_child(buttons)
	_refine_button = Button.new()
	_refine_button.text = "OK"
	_clear_button = Button.new()
	_clear_button.text = "Cancel"
	for b in [_refine_button, _clear_button]:
		b.focus_mode = Control.FOCUS_NONE
		b.custom_minimum_size = Vector2(100, 30)
		buttons.add_child(b)
	_refine_button.pressed.connect(_on_refine_pressed)
	_clear_button.pressed.connect(clear_target)
	body.add_child(UITheme.divider())
	_bonus_label = _centred(ItemTooltip.ENCHANT_COLOUR)
	body.add_child(_bonus_label)
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 6)
	body.add_child(row)
	_imbue_button = Button.new()
	_reweave_button = Button.new()
	for b in [_imbue_button, _reweave_button]:
		b.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		b.focus_mode = Control.FOCUS_NONE
		row.add_child(b)
	_imbue_button.pressed.connect(_on_enchant_pressed.bind("imbue_scroll"))
	_reweave_button.pressed.connect(_on_enchant_pressed.bind("reweave_scroll"))

static func _inset() -> StyleBoxFlat:
	var box := StyleBoxFlat.new()
	box.bg_color = Color("0a111c")
	box.border_color = Color("5a4a2c")
	box.set_border_width_all(1)
	box.set_corner_radius_all(3)
	box.set_content_margin_all(8)
	return box

func _centred(colour: Color, size: int = UITheme.FS_SMALL) -> Label:
	var label := UITheme.body("", size, colour)
	label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	return label

func _card_line(text: String, colour: Color, size: int = UITheme.FS_SMALL) -> void:
	var label := _centred(colour, size)
	label.text = text
	_card_lines.add_child(label)

## One material row: its icon, then "Name x 02" on a bar - green when held.
func _material_row(id: String, need: int) -> void:
	var have := _count(id)
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 6)
	var icon := UISlot.new(Vector2(36, 36))
	icon.mouse_filter = Control.MOUSE_FILTER_IGNORE
	icon.set_item(id, {"amount": 1})
	icon.ready.connect(func(): icon.theme_type_variation = &"ArcaneSlot")
	row.add_child(icon)
	var bar := PanelContainer.new()
	var box := _inset()
	box.border_color = Color(0.35, 0.75, 0.35) if have >= need else Color(0.7, 0.3, 0.28)
	box.content_margin_top = 4
	box.content_margin_bottom = 4
	bar.add_theme_stylebox_override("panel", box)
	bar.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	bar.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	row.add_child(bar)
	var text := UITheme.body("%s x %02d" % [String(HPEquipment.item(id).get("name", id)), need], UITheme.FS_SMALL,
		UITheme.c("parchment") if have >= need else Color(1.0, 0.5, 0.45))
	text.tooltip_text = "You have %d" % have
	text.mouse_filter = Control.MOUSE_FILTER_PASS
	bar.add_child(text)
	_materials.add_child(row)

## The item's base lines at refine level `tier` (what the card shows).
static func stat_lines(id: String, tier: int) -> Array:
	return HPEquipment.fixed_lines(id, tier).map(func(line): return String(line.text))

func open_for_player(p_player: Node3D) -> void:
	if is_instance_valid(player) and player != p_player:
		if player.equipment_answer.is_connected(_equipment_answer): player.equipment_answer.disconnect(_equipment_answer)
		if player.inventory_changed.is_connected(_refresh): player.inventory_changed.disconnect(_refresh)
	player = p_player
	if not player.equipment_answer.is_connected(_equipment_answer): player.equipment_answer.connect(_equipment_answer)
	if not player.inventory_changed.is_connected(_refresh): player.inventory_changed.connect(_refresh)
	# The anvil opens empty: the player drags or right-clicks the item to work.
	target_uid = 0
	show()
	_window.open()
	# The bag opens alongside: it is where items are dragged from.
	var inventory := get_parent().get_node_or_null("InventoryUI") if get_parent() != null else null
	if inventory != null:
		if not inventory.visible: inventory.open_for_player(player)
		if inventory.has_method("_set_merchant_open"): inventory._set_merchant_open(false)
	_place(inventory)
	_refresh()

## Dock left of the inventory window, top-aligned with it.
func _place(inventory: Node) -> void:
	var canvas := get_viewport().get_visible_rect().size
	var at := ((canvas - Vector2(WIDTH, HEIGHT)) * 0.5).floor()
	if inventory != null and inventory.get("_window") != null:
		var inv: UIWindow = inventory._window
		at = Vector2(maxf(8.0, inv.offset_left - WIDTH - 12.0), inv.offset_top + 40.0)
	ArcaneSkin.place(_window, at, Vector2(WIDTH, minf(HEIGHT, canvas.y - at.y - 12.0)))

## Workable items: refinable or enchantable instances in the bag. Worn pieces
## must be taken off first.
func _accepts(payload: Dictionary) -> bool:
	var id := String(payload.get("id", ""))
	var uid := int(payload.get("uid", 0))
	if uid <= 0 or String(payload.get("source_slot", "")) != "" or (is_instance_valid(player) and _worn_slot(uid) != ""):
		return false
	return HPEquipment.refinable(id) or HPEquipment.enchantable(id)

## True while the instance `uid` sits on the anvil: the bag keeps it in place
## (no moving, equipping or selling) until it is taken off or the window closes.
func holds(uid: int) -> bool:
	return visible and uid > 0 and target_uid == uid

func set_target(uid: int) -> void:
	target_uid = uid
	_refresh()
	_refresh_bag()

func clear_target() -> void:
	target_uid = 0
	_refresh()
	_refresh_bag()

func _refresh_bag() -> void:
	var inventory := get_parent().get_node_or_null("InventoryUI") if get_parent() != null else null
	if inventory != null and inventory.visible and inventory.has_method("refresh"):
		inventory.refresh()

## The instance `uid` in the bag or worn ({} when gone), plus where it is.
func _find(uid: int) -> Dictionary:
	if uid <= 0 or not is_instance_valid(player): return {}
	for entry in player.inventory:
		if int(entry.get("uid", 0)) == uid: return entry
	for slot in player.equipment:
		if int(player.equipment[slot].get("uid", 0)) == uid: return player.equipment[slot]
	return {}

func _worn_slot(uid: int) -> String:
	for slot in player.equipment:
		if int(player.equipment[slot].get("uid", 0)) == uid: return String(slot)
	return ""

func _count(id: String) -> int:
	var have := 0
	for entry in player.inventory:
		if entry.id == id and int(entry.get("tier", 0)) == 0: have += int(entry.amount)
	return have

func _refresh() -> void:
	if not is_instance_valid(player) or _slot == null: return
	if target_uid > 0 and _worn_slot(target_uid) != "":
		target_uid = 0   # the anvil only works bag items
	var item := _find(target_uid)
	var id := String(item.get("id", ""))
	_slot.set_item(id, item)
	var busy := _pending_id != -1
	for child in _card_lines.get_children() + _materials.get_children():
		child.get_parent().remove_child(child)
		child.queue_free()
	_chance.text = ""
	_cost.text = ""
	_refine_button.disabled = true
	_clear_button.disabled = item.is_empty()
	if item.is_empty():
		target_uid = 0
		_card_line("Drag an item here", UITheme.c("text_dim"))
		_card_line("or right-click it in your bag", UITheme.c("text_dim"))
		_bonus_label.text = ""
		_imbue_button.disabled = true
		_reweave_button.disabled = true
		_imbue_button.text = "Imbue"
		_reweave_button.text = "Reweave"
		return
	var tier := int(item.get("tier", 0))
	var tint: Color = ItemTooltip.RARITY_COLOUR.get(ItemTooltip.rarity_of(id), Color.WHITE)
	var name := String(HPEquipment.item(id).get("name", id))
	if not HPEquipment.refinable(id):
		_card_line(name, tint, UITheme.FS_BODY)
		_card_line("Cannot be refined", UITheme.c("text_dim"))
	elif tier >= 9:
		_card_line("%s +9" % name, tint, UITheme.FS_BODY)
		_card_line("From Level: %d" % HPEquipment.required_level(id), UITheme.c("parchment"))
		for line in stat_lines(id, 9): _card_line(line, ItemTooltip.STAT_COLOUR)
		_chance.text = "Fully refined"
	else:
		# The card shows the item as it will be after a successful upgrade.
		var step: Dictionary = HPRules.combat().wand_tiers[tier]
		_card_line("%s +%d" % [name, tier + 1], tint, UITheme.FS_BODY)
		_card_line("From Level: %d" % HPEquipment.required_level(id), UITheme.c("parchment"))
		for line in stat_lines(id, tier + 1): _card_line(line, ItemTooltip.STAT_COLOUR)
		_material_row(String(step.material_id), int(step.material_amount))
		var floor_tier := int(HPRules.combat().get("upgrade_curves", {}).get("fail_downgrade_from", 4))
		_chance.text = "Chance of upgrade %d%%%s" % [int(step.chance), "  (failure: +%d)" % (tier - 1) if tier >= floor_tier else ""]
		_cost.text = "Cost of the upgrade: %s Galleons" % preload("res://scripts/ui/inventory_arcane.gd").galleon_text(int(step.cost))
		_cost.add_theme_color_override("font_color", UITheme.c("gold_hi") if player.galleons >= int(step.cost) else Color(1.0, 0.45, 0.4))
		_refine_button.disabled = busy or player.galleons < int(step.cost) or _count(String(step.material_id)) < int(step.material_amount)
	# Enchantments.
	var rules := HPEquipment.enchant_rules()
	var imbue_id := String(rules.get("imbue_scroll", ""))
	var reweave_id := String(rules.get("reweave_scroll", ""))
	var held: Array = item.get("bonuses", [])
	var cap := int(rules.get("max_bonuses", 5))
	var enchantable := HPEquipment.enchantable(id)
	if not enchantable:
		_bonus_label.text = "Cannot be enchanted"
	elif held.is_empty():
		_bonus_label.text = "No enchantments (0/%d)" % cap
	else:
		_bonus_label.text = "\n".join(held.map(func(b): return HPEquipment.bonus_text(b)))
	var chances: Array = rules.get("imbue_chance", [100])
	var imbue_chance := int(chances[clampi(held.size(), 0, chances.size() - 1)])
	_imbue_button.text = "Imbue %d%%  ·  %d" % [imbue_chance, _count(imbue_id)]
	_reweave_button.text = "Reweave  ·  %d" % _count(reweave_id)
	_imbue_button.tooltip_text = String(HPEquipment.item(imbue_id).get("desc", ""))
	_reweave_button.tooltip_text = String(HPEquipment.item(reweave_id).get("desc", ""))
	_imbue_button.disabled = busy or not enchantable or held.size() >= cap or _count(imbue_id) == 0
	_reweave_button.disabled = busy or not enchantable or held.is_empty() or _count(reweave_id) == 0

func _on_refine_pressed() -> void:
	if not is_instance_valid(player) or target_uid == 0: return
	_last_op = "refine"
	_pending_id = SimNet.submit_equipment(player, "refine", _worn_slot(target_uid), "", 0, target_uid)
	_refresh()

func _on_enchant_pressed(which: String) -> void:
	if not is_instance_valid(player) or target_uid == 0: return
	_last_op = "enchant"
	_pending_id = SimNet.submit_equipment(player, "enchant", "", String(HPEquipment.enchant_rules().get(which, "")), 0, target_uid)
	_refresh()

func _equipment_answer(result: Dictionary) -> void:
	if int(result.get("request_id", -1)) != _pending_id: return
	_pending_id = -1
	var reason := String(result.get("reason", ""))
	var text := String(preload("res://scripts/ui/inventory_arcane.gd").REASONS.get(reason, "Equipment updated."))
	var good := reason in ["refined", "enchanted"]
	var hud := get_parent().get_node_or_null("HUD") if get_parent() != null else null
	if hud != null and hud.has_method("show_notice") and text != "":
		hud.show_notice(text, "good" if good else "warn")
	var audio := get_node_or_null("/root/AudioManager")
	if audio != null and reason in ["refined", "refinement_failed", "enchanted", "enchant_failed"]:
		audio.play_sound_at("ui_upgrade_success" if good else "ui_upgrade_fail", Vector3.ZERO, null, true)
	if reason == "refined":
		var slot := _worn_slot(target_uid)
		var tier := int(_find(target_uid).get("tier", 0))
		item_upgraded.emit(slot, tier)
		if slot == "main_hand":
			wand_upgraded.emit(player.wand_tier)
	_refresh()

func _process(_delta: float) -> void:
	if visible and _tooltip != null and _tooltip.visible:
		_tooltip.follow_cursor()
