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
const HEIGHT := 470.0

var player: Node3D = null
## The instance on the anvil (its uid), 0 = empty.
var target_uid := 0
var _pending_id := -1
var _last_op := ""
var _layer: CanvasLayer
var _window: UIWindow
var _slot: UISlot
var _name: Label
var _hint: Label
var _now: Label
var _next: Label
var _chance: Label
var _cost: Label
var _material: Label
var _refine_button: Button
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
		if not visible and _tooltip != null: _tooltip.hide_item())
	hide()

func _build() -> void:
	var body := _window.body
	# The anvil: the slot that takes the item.
	var top := HBoxContainer.new()
	top.add_theme_constant_override("separation", 10)
	body.add_child(top)
	_slot = UISlot.new(Vector2(60, 60))
	_slot.equipment_interaction = true
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
	var head := VBoxContainer.new()
	head.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	head.alignment = BoxContainer.ALIGNMENT_CENTER
	top.add_child(head)
	_name = UITheme.body("", UITheme.FS_LABEL, UITheme.c("gold_hi"))
	_name.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	head.add_child(_name)
	_hint = UITheme.body("", UITheme.FS_SMALL, UITheme.c("text_dim"))
	_hint.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	head.add_child(_hint)
	body.add_child(UITheme.divider())
	body.add_child(_section("REFINE"))
	_now = _line(UITheme.c("text"))
	_next = _line(UITheme.c("good"))
	_chance = _line(UITheme.c("text"))
	_cost = _line(UITheme.c("gold_hi"))
	_material = _line(UITheme.c("text"))
	for label in [_now, _next, _chance, _cost, _material]: body.add_child(label)
	_refine_button = Button.new()
	_refine_button.text = "Refine"
	_refine_button.focus_mode = Control.FOCUS_NONE
	_refine_button.pressed.connect(_on_refine_pressed)
	body.add_child(_refine_button)
	body.add_child(UITheme.divider())
	body.add_child(_section("ENCHANTMENTS"))
	_bonus_label = _line(UITheme.c("magic"))
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

func _section(text: String) -> Label:
	var label := UITheme.body(text, UITheme.FS_SMALL, UITheme.c("gold_lt"))
	return label

func _line(colour: Color) -> Label:
	var label := UITheme.body("", UITheme.FS_SMALL, colour)
	label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	return label

func open_for_player(p_player: Node3D) -> void:
	if is_instance_valid(player) and player != p_player:
		if player.equipment_answer.is_connected(_equipment_answer): player.equipment_answer.disconnect(_equipment_answer)
		if player.inventory_changed.is_connected(_refresh): player.inventory_changed.disconnect(_refresh)
	player = p_player
	if not player.equipment_answer.is_connected(_equipment_answer): player.equipment_answer.connect(_equipment_answer)
	if not player.inventory_changed.is_connected(_refresh): player.inventory_changed.connect(_refresh)
	# Start on the worn wand when nothing is on the anvil yet.
	if _find(target_uid).is_empty():
		target_uid = int(player.equipment.get("main_hand", {}).get("uid", 0))
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

## Workable items: refinable or enchantable instances.
func _accepts(payload: Dictionary) -> bool:
	var id := String(payload.get("id", ""))
	return int(payload.get("uid", 0)) > 0 and (HPEquipment.refinable(id) or HPEquipment.enchantable(id))

func set_target(uid: int) -> void:
	target_uid = uid
	_refresh()

func clear_target() -> void:
	target_uid = 0
	_refresh()

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

## The bonus line for an item at `tier`, in the words of its kind.
static func effect_text(id: String, tier: int) -> String:
	var numbers := HPEquipment.item_stats(id, tier)
	match String(HPEquipment.item(id).get("type", "")):
		"weapon":
			return "+%d%% Spell power" % int(round((float(numbers.spell_power) - 1.0) * 100.0))
		"armor":
			return "+%d Max Health · +%d%% Magic Armour" % [int(numbers.bonus_hp), int(numbers.bonus_defense)]
		"mount":
			return "%.1f Mount speed" % float(numbers.mount_speed)
	return ""

func _refresh() -> void:
	if not is_instance_valid(player) or _slot == null: return
	var item := _find(target_uid)
	var id := String(item.get("id", ""))
	_slot.set_item(id, item)
	var busy := _pending_id != -1
	for label in [_now, _next, _chance, _cost, _material, _bonus_label]: label.text = ""
	if item.is_empty():
		target_uid = 0
		_name.text = "Empty anvil"
		_hint.text = "Drag a wand, cloak or broom here, or right-click it in your bag."
		_refine_button.disabled = true
		_imbue_button.disabled = true
		_reweave_button.disabled = true
		_imbue_button.text = "Imbue"
		_reweave_button.text = "Reweave"
		return
	var tier := int(item.get("tier", 0))
	_name.text = "%s +%d" % [String(HPEquipment.item(id).get("name", id)), tier]
	var where := _worn_slot(target_uid)
	_hint.text = "Equipped" if where != "" else "In your bag"
	# Refinement.
	_refine_button.disabled = true
	if not HPEquipment.refinable(id):
		_now.text = "This item cannot be refined."
	elif tier >= 9:
		_now.text = "Now: %s" % effect_text(id, tier)
		_next.text = "Fully refined (+9)."
	else:
		var step: Dictionary = HPRules.combat().wand_tiers[tier]
		var chance := int(step.chance)
		var floor_tier := int(HPRules.combat().get("upgrade_curves", {}).get("fail_downgrade_from", 4))
		_now.text = "Now: %s" % effect_text(id, tier)
		_next.text = "+%d: %s" % [tier + 1, effect_text(id, tier + 1)]
		_chance.text = "Success %d%%%s" % [chance, "  ·  failure drops to +%d" % (tier - 1) if tier >= floor_tier else ""]
		_chance.add_theme_color_override("font_color", Color(0.4, 0.9, 0.45) if chance >= 80 else (Color(1.0, 0.85, 0.3) if chance >= 50 else Color(1.0, 0.45, 0.35)))
		_cost.text = "Cost  %s Galleons" % preload("res://scripts/ui/inventory_arcane.gd").galleon_text(int(step.cost))
		var have := _count(String(step.material_id))
		_material.text = "%s  %d / %d" % [String(HPEquipment.item(step.material_id).get("name", "Material")), have, int(step.material_amount)]
		_material.add_theme_color_override("font_color", UITheme.c("text") if have >= int(step.material_amount) else Color(1.0, 0.45, 0.35))
		_refine_button.text = "Refine to +%d" % (tier + 1)
		_refine_button.disabled = busy or player.galleons < int(step.cost) or have < int(step.material_amount)
	# Enchantments.
	var rules := HPEquipment.enchant_rules()
	var imbue_id := String(rules.get("imbue_scroll", ""))
	var reweave_id := String(rules.get("reweave_scroll", ""))
	var held: Array = item.get("bonuses", [])
	var cap := int(rules.get("max_bonuses", 5))
	var enchantable := HPEquipment.enchantable(id)
	if not enchantable:
		_bonus_label.text = "This item cannot be enchanted."
	elif held.is_empty():
		_bonus_label.text = "No enchantments yet (0/%d)." % cap
	else:
		_bonus_label.text = "\n".join(held.map(func(b): return HPEquipment.bonus_text(b))) + "\n(%d/%d)" % [held.size(), cap]
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
