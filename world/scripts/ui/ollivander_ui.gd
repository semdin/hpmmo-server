extends Control

## Ollivander's upgrade workshop (the Metin2 blacksmith): refines the worn wand,
## robe or broom from +0 to +9. Every kind shares one step table
## (combat.json `wand_tiers`: chance, galleons, material, failure) and has its
## own bonus curve (`upgrade_curves`); the numbers shown here come from
## `HPEquipment.item_stats`, the same function the derived stats use, and the
## authority decides the outcome (`refine` on the chosen slot).

signal wand_upgraded(new_tier: int)
signal item_upgraded(slot: String, new_tier: int)

## The workshop's tabs: slot -> label. Order is the tab order.
const KINDS := [["main_hand", "Wand"], ["chest", "Robe"], ["broom", "Broom"]]

@onready var item_name_label: Label = $Panel/VBoxContainer/ItemNameLabel
@onready var current_tier_label: Label = $Panel/VBoxContainer/CurrentTierLabel
@onready var next_tier_label: Label = $Panel/VBoxContainer/NextTierLabel
@onready var success_chance_label: Label = $Panel/VBoxContainer/SuccessChanceLabel
@onready var cost_label: Label = $Panel/VBoxContainer/CostLabel
@onready var material_label: Label = $Panel/VBoxContainer/MaterialLabel
@onready var result_label: Label = $Panel/VBoxContainer/ResultLabel
@onready var refine_button: Button = $Panel/VBoxContainer/RefineButton
@onready var close_button: Button = $Panel/CloseButton

var player: Node3D = null
var slot := "main_hand"
var _pending_id := -1
var _tabs: Array[Button] = []

func _ready() -> void:
	theme = UITheme.get_theme()
	refine_button.theme_type_variation = &"ArcaneButton"
	UITheme.set_button_icon(refine_button, "ui_ollivander", 18.0)
	UITheme.set_button_icon(close_button, "ui_close")
	refine_button.pressed.connect(_on_refine_pressed)
	close_button.pressed.connect(hide)
	_build_tabs()
	hide()

func _build_tabs() -> void:
	var row := HBoxContainer.new()
	row.name = "KindTabs"
	row.alignment = BoxContainer.ALIGNMENT_CENTER
	row.add_theme_constant_override("separation", 8)
	var group := ButtonGroup.new()
	for pair in KINDS:
		var tab := Button.new()
		tab.text = pair[1]
		tab.toggle_mode = true
		tab.button_group = group
		tab.custom_minimum_size = Vector2(96, 32)
		tab.button_pressed = pair[0] == slot
		tab.pressed.connect(select_slot.bind(String(pair[0])))
		row.add_child(tab)
		_tabs.append(tab)
	var box := $Panel/VBoxContainer
	box.add_child(row)
	box.move_child(row, item_name_label.get_index() + 1)

## Show the workshop for `which` worn slot (main_hand / chest / broom).
func select_slot(which: String) -> void:
	slot = which
	for i in _tabs.size():
		_tabs[i].set_pressed_no_signal(KINDS[i][0] == slot)
	result_label.text = ""
	_refresh_display()

func open_for_player(p_player: Node3D) -> void:
	if is_instance_valid(player) and player != p_player and player.equipment_answer.is_connected(_equipment_answer):
		player.equipment_answer.disconnect(_equipment_answer)
		if player.equipment_changed.is_connected(_refresh_display): player.equipment_changed.disconnect(_refresh_display)
	player = p_player
	if not player.equipment_answer.is_connected(_equipment_answer): player.equipment_answer.connect(_equipment_answer)
	if not player.equipment_changed.is_connected(_refresh_display): player.equipment_changed.connect(_refresh_display)
	_refresh_display()
	show()

func _kind_label() -> String:
	for pair in KINDS:
		if pair[0] == slot: return String(pair[1])
	return "Item"

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

func _refresh_display() -> void:
	if not is_instance_valid(player):
		return
	var worn: Dictionary = player.equipment.get(slot, {})
	var id := String(worn.get("id", ""))
	result_label.modulate = Color.WHITE
	refine_button.text = "REFINE %s" % _kind_label().to_upper()
	if id == "" or not HPEquipment.refinable(id):
		item_name_label.text = "Equip a %s" % _kind_label().to_lower()
		current_tier_label.text = "Nothing to refine in this slot."
		for label in [next_tier_label, success_chance_label, cost_label, material_label]:
			label.text = ""
		refine_button.disabled = true
		return
	var tier := int(worn.get("tier", 0))
	var name := String(HPEquipment.item(id).get("name", id))
	item_name_label.text = "%s +%d" % [name, tier]
	current_tier_label.text = "Now: %s" % effect_text(id, tier)
	if tier >= 9:
		next_tier_label.text = "Fully refined (+9)."
		for label in [success_chance_label, cost_label, material_label]:
			label.text = ""
		refine_button.disabled = true
		return
	var step: Dictionary = HPRules.combat().wand_tiers[tier]
	next_tier_label.text = "+%d: %s" % [tier + 1, effect_text(id, tier + 1)]
	var chance := int(step.chance)
	var floor_tier := int(HPRules.combat().get("upgrade_curves", {}).get("fail_downgrade_from", 4))
	success_chance_label.text = "Success Rate: %d%%%s" % [chance, "  ·  failure drops to +%d" % (tier - 1) if tier >= floor_tier else ""]
	if chance >= 80:
		success_chance_label.modulate = Color(0.2, 0.9, 0.3)
	elif chance >= 50:
		success_chance_label.modulate = Color(1.0, 0.85, 0.2)
	elif chance >= 30:
		success_chance_label.modulate = Color(1.0, 0.5, 0.1)
	else:
		success_chance_label.modulate = Color(1.0, 0.2, 0.2)
	cost_label.text = "Cost: %d Galleons (You have: %d)" % [int(step.cost), player.galleons]
	var have := 0
	for entry in player.inventory:
		if entry.id == step.material_id and int(entry.get("tier", 0)) == 0:
			have += int(entry.amount)
	material_label.text = "Required: %s ×%d (You have: %d)" % [HPEquipment.item(step.material_id).get("name", "Material"), int(step.material_amount), have]
	refine_button.disabled = _pending_id != -1 or player.galleons < int(step.cost) or have < int(step.material_amount)

func _on_refine_pressed() -> void:
	if not is_instance_valid(player): return
	refine_button.disabled = true
	result_label.text = "Refining…"
	_pending_id = SimNet.submit_equipment(player, "refine", slot)

func _equipment_answer(result: Dictionary) -> void:
	if int(result.get("request_id", -1)) != _pending_id: return
	_pending_id = -1
	var reason := String(result.get("reason", ""))
	result_label.text = String(preload("res://scripts/ui/inventory_arcane.gd").REASONS.get(reason, "Equipment updated."))
	result_label.modulate = Color(0.45, 1.0, 0.5) if reason == "refined" else (Color(1.0, 0.45, 0.4) if reason == "refinement_failed" else Color.WHITE)
	if reason == "refined":
		var tier := int(player.equipment.get(slot, {}).get("tier", 0))
		item_upgraded.emit(slot, tier)
		if slot == "main_hand":
			wand_upgraded.emit(player.wand_tier)
	_refresh_display()
