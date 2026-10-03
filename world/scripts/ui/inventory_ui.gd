extends Control

## Inventory UI - Metin2 grid style item viewer and potion consumable consumption

@onready var item_container: GridContainer = $Panel/ScrollContainer/ItemGrid
@onready var galleons_label: Label = $Panel/GalleonsLabel
@onready var close_button: Button = $Panel/CloseButton

var player: Node3D = null

func _ready() -> void:
	close_button.pressed.connect(hide)
	hide()

func open_for_player(p_player: Node3D) -> void:
	player = p_player
	if not player.inventory_changed.is_connected(_on_inventory_changed):
		player.inventory_changed.connect(_on_inventory_changed)
	refresh()
	show()

func _on_inventory_changed() -> void:
	if visible:
		refresh()

func refresh() -> void:
	if not is_instance_valid(player) or player.is_dead:
		return
	
	galleons_label.text = "Galleons: %d" % player.galleons
	
	# Clear old items
	for child in item_container.get_children():
		child.queue_free()
	
	# Populate inventory items
	for item in player.inventory:
		var item_id = item.id
		var count = item.amount
		var tier = item.get("tier", 0)
		
		var btn = Button.new()
		btn.custom_minimum_size = Vector2(90, 60)
		var item_title = item_id
		if GameData.ITEMS.has(item_id):
			item_title = GameData.ITEMS[item_id].name
		
		if tier > 0:
			btn.text = "%s +%d\n(x%d)" % [item_title, tier, count]
		else:
			btn.text = "%s\n(x%d)" % [item_title, count]
		
		btn.add_theme_font_size_override("font_size", 10)
		
		# Button click handler
		btn.pressed.connect(func(): _on_item_clicked(item))
		item_container.add_child(btn)

func _on_item_clicked(item_data: Dictionary) -> void:
	if not is_instance_valid(player) or player.is_dead:
		return
	
	var item_id = item_data.id
	if item_id == "potion_health":
		if player.current_hp < player.max_hp and item_data.amount > 0:
			var healed: int = mini(player.max_hp - player.current_hp, 150)
			item_data.amount -= 1
			player.current_hp = min(player.max_hp, player.current_hp + 150)
			player.emit_stats()
			player.show_floating_text("+%d" % healed, Color(0.4, 1.0, 0.4))
			if item_data.amount <= 0:
				player.inventory.erase(item_data)
			refresh()
	elif item_id == "potion_mana":
		if player.current_mana < player.max_mana and item_data.amount > 0:
			var restored: int = mini(player.max_mana - player.current_mana, 120)
			item_data.amount -= 1
			player.current_mana = min(player.max_mana, player.current_mana + 120)
			player.emit_stats()
			player.show_floating_text("+%d" % restored, Color(0.4, 0.7, 1.0))
			if item_data.amount <= 0:
				player.inventory.erase(item_data)
			refresh()
