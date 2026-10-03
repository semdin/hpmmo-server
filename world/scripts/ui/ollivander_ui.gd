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

func _ready() -> void:
	refine_button.pressed.connect(_on_refine_pressed)
	close_button.pressed.connect(hide)
	hide()

func open_for_player(p_player: Node3D) -> void:
	player = p_player
	_refresh_display()
	show()

func _refresh_display() -> void:
	if not is_instance_valid(player):
		return
	
	var tier: int = player.wand_tier
	var next_tier := tier + 1
	var up_info: Dictionary = GameData.UPGRADE_TABLE.get(tier, {})
	
	item_name_label.text = "Ollivander's Wand Crafting"
	current_tier_label.text = "Current: Hawthorn Wand +%d" % tier
	
	if tier >= 9:
		next_tier_label.text = "Target: [MAX TIER ACHIEVED]"
		success_chance_label.text = "Success Chance: 0%"
		cost_label.text = "Upgrade Cost: N/A"
		material_label.text = "Required Material: MASTERPIECE"
		refine_button.disabled = true
		return
	
	next_tier_label.text = "Target: Hawthorn Wand +%d (+%d%% Magic Power)" % [next_tier, int((GameData.UPGRADE_TABLE[next_tier].multiplier - 1.0) * 100)]
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
	material_label.text = "Required: %s" % up_info.material
	
	# Check affordability
	refine_button.disabled = (player.galleons < up_info.cost)

func _on_refine_pressed() -> void:
	if not is_instance_valid(player) or player.wand_tier >= 9:
		return
	
	var tier: int = player.wand_tier
	var up_info: Dictionary = GameData.UPGRADE_TABLE.get(tier, {})
	
	# Deduct Galleons
	if player.galleons < up_info.cost:
		result_label.text = "Not enough Galleons to refine!"
		result_label.modulate = Color(1.0, 0.2, 0.2)
		return
	
	player.galleons -= up_info.cost
	
	# Roll success
	var roll := randf() * 100.0
	var audio := get_node_or_null("/root/AudioManager")
	if roll <= up_info.chance:
		# SUCCESS!
		player.upgrade_wand(tier + 1)
		QuestManager.add_refine()
		result_label.text = "REFINING SUCCEEDED! Your wand surges with arcane power!"
		result_label.modulate = Color(0.2, 1.0, 0.4)
		if audio:
			audio.play_upgrade_success()
	else:
		# FAILURE (Classic Metin2 risk!)
		if audio:
			audio.play_upgrade_fail()
		if tier >= 4:
			# Tier drop penalty
			player.upgrade_wand(tier - 1)
			result_label.text = "REFINING FAILED! The wood fractured, dropping to +%d!" % (tier - 1)
			result_label.modulate = Color(1.0, 0.2, 0.2)
		else:
			result_label.text = "REFINING FAILED! The refinement sputtered, but tier remains +%d." % tier
			result_label.modulate = Color(1.0, 0.6, 0.1)
	
	_refresh_display()
