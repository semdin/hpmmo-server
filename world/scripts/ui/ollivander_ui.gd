extends Control

## Ollivander's Wand Crafting & Upgrade Workshop (Metin2 Blacksmith equivalent)
## Handles +0 to +9 wand refinement, success rates, material checks, and failure risks

signal wand_upgraded(new_tier: int)

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
var _pending_id := -1

func _ready() -> void:
	theme = UITheme.get_theme()
	refine_button.theme_type_variation = &"ArcaneButton"
	UITheme.set_button_icon(refine_button, "ui_ollivander", 18.0)
	UITheme.set_button_icon(close_button, "ui_close")
	refine_button.pressed.connect(_on_refine_pressed)
	close_button.pressed.connect(hide)
	hide()

func open_for_player(p_player: Node3D) -> void:
	if is_instance_valid(player) and player != p_player and player.equipment_answer.is_connected(_equipment_answer):
		player.equipment_answer.disconnect(_equipment_answer)
		if player.equipment_changed.is_connected(_refresh_display): player.equipment_changed.disconnect(_refresh_display)
	player = p_player
	if not player.equipment_answer.is_connected(_equipment_answer): player.equipment_answer.connect(_equipment_answer)
	if not player.equipment_changed.is_connected(_refresh_display): player.equipment_changed.connect(_refresh_display)
	_refresh_display()
	show()

func _refresh_display() -> void:
	if not is_instance_valid(player):
		return
	
	var tier: int = player.wand_tier
	var next_tier := tier + 1
	var up_info: Dictionary = HPRules.combat().wand_tiers[tier]
	
	item_name_label.text = String(HPEquipment.item(String(player.equipment.get("main_hand", {}).get("id", ""))).get("name", "Equip a wand"))
	current_tier_label.text = "Current: %s +%d" % [item_name_label.text, tier]
	
	if tier >= 9:
		next_tier_label.text = "Target: [MAX TIER ACHIEVED]"
		success_chance_label.text = "Success Chance: 0%"
		cost_label.text = "Upgrade Cost: N/A"
		material_label.text = "Required Material: MASTERPIECE"
		refine_button.disabled = true
		return
	
	next_tier_label.text = "Target: Wand +%d (+%d%% Magic Power)" % [next_tier, int((HPRules.wand_multiplier(next_tier) - 1.0) * 100)]
	var chance: int = up_info.chance
	success_chance_label.text = "Success Rate: %d%%" % chance
	
	if chance >= 80:
		success_chance_label.modulate = Color(0.2, 0.9, 0.3)
	elif chance >= 50:
		success_chance_label.modulate = Color(1.0, 0.85, 0.2)
	elif chance >= 30:
		success_chance_label.modulate = Color(1.0, 0.5, 0.1)
	else:
		success_chance_label.modulate = Color(1.0, 0.2, 0.2)
	
	cost_label.text = "Cost: %d Galleons (You have: %d)" % [up_info.cost, player.galleons]
	material_label.text = "Required: %s ×%d" % [HPEquipment.item(up_info.material_id).get("name", "Material"), up_info.material_amount]
	
	# Check affordability
	refine_button.disabled = (_pending_id != -1 or player.galleons < up_info.cost or not player.equipment.has("main_hand"))

func _on_refine_pressed() -> void:
	if not is_instance_valid(player): return
	refine_button.disabled = true
	result_label.text = "Refining…"
	_pending_id = SimNet.submit_equipment(player, "refine", "main_hand")

func _equipment_answer(result: Dictionary) -> void:
	if int(result.get("request_id", -1)) != _pending_id: return
	_pending_id = -1
	var reason := String(result.get("reason", ""))
	result_label.text = String(preload("res://scripts/ui/inventory_arcane.gd").REASONS.get(reason, "Equipment updated."))
	if reason == "refined":
		QuestManager.add_refine()
		wand_upgraded.emit(player.wand_tier)
	_refresh_display()
