extends Control

## InventoryUI - the bag: a grid of item cells beside an equipment doll, with a
## hover card carrying each item's real stats.
##
## Behaviour the rest of the game depends on, kept intact through the redesign:
##   * `open_for_player(player)` / `hide()` / `visible` - used by `game_world.gd`
##     and by the interface regression.
##   * `refresh()` - called on `player.inventory_changed`.
##   * `_on_item_clicked(item_data)` - consumes a potion out of a *Dictionary*
##     entry and heals exactly 150 HP, because `test_scenario.gd:196` and
##     `ui_regression.gd:137-139` both assert those exact numbers.
##   * `galleons_label.text == "Galleons: %d"` - asserted verbatim.
##
## Two player-facing changes drive the rebuild:
##
## 1. **The bag no longer stops the world.** The root is `MOUSE_FILTER_IGNORE`
##    and the window is a normal Control inside it, so clicks outside the card
##    still reach the world and movement keys are never gated - `player.gd`'s
##    `input_blocked()` no longer lists this panel. Previously simply opening the
##    bag froze walking, casting and mounting.
## 2. **The card is draggable** by its title bar (`UIWindow`), which writes
##    offsets rather than `position` so it stays correct at every stretch factor.
##
## The scene file is now just the root Control; the whole window is built here,
## the same way `mmorpg_overlay.gd` builds the overlay.

## Built in `_build()` rather than fetched with `@onready`, because the window
## is constructed at runtime. The names are unchanged: `galleons_label` is read
## by `test_scenario.gd:196`.
var item_container: GridContainer = null
var galleons_label: Label = null
var close_button: Button = null

var player: Node3D = null

## The equipment doll. There is no server-side equipment model (items persist as
## id/amount/tier only), so a slot shows the matching item the player *carries*
## rather than pretending to a save field that does not exist. When an
## authoritative equip slot lands, only `_equipped_for` has to change.
const EQUIP_SLOTS := [
	{"key": "weapon", "caption": "Wand"},
	{"key": "armor", "caption": "Robes"},
	{"key": "mount", "caption": "Broom"},
	{"key": "material", "caption": "Reagents"},
]

var _window: UIWindow = null
var _tooltip: ItemTooltip = null
var _doll_slots: Array[UISlot] = []
var _bag_slots: Array[UISlot] = []
var _empty_label: Label = null


func _ready() -> void:
	theme = UITheme.get_theme()
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	_build()
	visibility_changed.connect(_on_visibility_changed)
	hide()


# ------------------------------------------------------------------- build

func _build() -> void:
	_window = UIWindow.new("INVENTORY", Vector2(660, 432))
	_window.name = "Window"
	_window.closed.connect(func(): hide())
	add_child(_window)
	close_button = _window._close_button

	var top := HBoxContainer.new()
	top.add_theme_constant_override("separation", 12)
	top.size_flags_vertical = Control.SIZE_EXPAND_FILL
	_window.body.add_child(top)

	top.add_child(_build_doll())
	top.add_child(_build_bag())

	_window.body.add_child(_build_footer())

	_tooltip = ItemTooltip.new()
	_tooltip.name = "Tooltip"
	add_child(_tooltip)


func _build_doll() -> Control:
	var frame := PanelContainer.new()
	frame.custom_minimum_size = Vector2(258, 0)
	frame.size_flags_vertical = Control.SIZE_EXPAND_FILL

	var margin := MarginContainer.new()
	for side in ["left", "right", "top", "bottom"]:
		margin.add_theme_constant_override("margin_" + side, 8)
	frame.add_child(margin)

	var column := VBoxContainer.new()
	column.add_theme_constant_override("separation", 4)
	margin.add_child(column)

	column.add_child(UITheme.heading("EQUIPPED", UITheme.FS_SMALL, UITheme.c("text_dim")))
	column.add_child(UITheme.divider())

	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 4)
	row.size_flags_vertical = Control.SIZE_EXPAND_FILL
	column.add_child(row)

	var left := VBoxContainer.new()
	left.add_theme_constant_override("separation", 4)
	left.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	row.add_child(left)

	var doll := Control.new()
	doll.custom_minimum_size = Vector2(112, 190)
	doll.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	doll.mouse_filter = Control.MOUSE_FILTER_IGNORE
	row.add_child(doll)

	var right := VBoxContainer.new()
	right.add_theme_constant_override("separation", 4)
	right.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	row.add_child(right)

	for i in EQUIP_SLOTS.size():
		var slot := UISlot.new(Vector2(58, 58))
		slot.caption = String(EQUIP_SLOTS[i]["caption"])
		slot.tooltip_text = String(EQUIP_SLOTS[i]["caption"])
		slot.slot_entered.connect(_on_slot_entered)
		slot.slot_exited.connect(_on_slot_exited)
		slot.pressed.connect(func(): _on_slot_pressed(slot))
		_doll_slots.append(slot)
		( left if i % 2 == 0 else right ).add_child(slot)

	return frame


func _build_bag() -> Control:
	var frame := PanelContainer.new()
	frame.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	frame.size_flags_vertical = Control.SIZE_EXPAND_FILL

	var margin := MarginContainer.new()
	for side in ["left", "right", "top", "bottom"]:
		margin.add_theme_constant_override("margin_" + side, 8)
	frame.add_child(margin)

	var column := VBoxContainer.new()
	column.add_theme_constant_override("separation", 4)
	margin.add_child(column)

	var head := HBoxContainer.new()
	column.add_child(head)
	head.add_child(UITheme.heading("SATCHEL", UITheme.FS_SMALL, UITheme.c("text_dim")))
	_empty_label = Label.new()
	_empty_label.text = "empty"
	_empty_label.add_theme_font_size_override("font_size", UITheme.FS_SMALL)
	_empty_label.add_theme_color_override("font_color", UITheme.c("text_dim"))
	_empty_label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_empty_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
	head.add_child(_empty_label)
	column.add_child(UITheme.divider())

	var scroll := ScrollContainer.new()
	scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
	scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	column.add_child(scroll)

	item_container = GridContainer.new()
	item_container.name = "ItemGrid"
	item_container.columns = 6
	item_container.add_theme_constant_override("h_separation", 4)
	item_container.add_theme_constant_override("v_separation", 4)
	item_container.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	scroll.add_child(item_container)

	return frame


func _build_footer() -> Control:
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 8)

	var coin := Panel.new()
	var coin_sb := StyleBoxFlat.new()
	coin_sb.bg_color = UITheme.c("gold")
	coin_sb.set_corner_radius_all(11)
	coin.add_theme_stylebox_override("panel", coin_sb)
	coin.custom_minimum_size = Vector2(18, 18)
	coin.mouse_filter = Control.MOUSE_FILTER_IGNORE
	row.add_child(coin)

	galleons_label = Label.new()
	galleons_label.name = "GalleonsLabel"
	galleons_label.text = "Galleons: 0"
	galleons_label.add_theme_font_size_override("font_size", UITheme.FS_BODY)
	galleons_label.add_theme_color_override("font_color", UITheme.c("gold_lt"))
	galleons_label.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	row.add_child(galleons_label)

	var spacer := Control.new()
	spacer.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	spacer.mouse_filter = Control.MOUSE_FILTER_IGNORE
	row.add_child(spacer)

	var hint := Label.new()
	hint.text = "Click a potion to drink  •  I or Esc closes"
	hint.add_theme_font_size_override("font_size", UITheme.FS_SMALL)
	hint.add_theme_color_override("font_color", UITheme.c("text_dim"))
	hint.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	row.add_child(hint)

	return row


# ------------------------------------------------------------------ public

func open_for_player(p_player: Node3D) -> void:
	player = p_player
	if not player.inventory_changed.is_connected(_on_inventory_changed):
		player.inventory_changed.connect(_on_inventory_changed)
	refresh()
	_window.open()
	show()


## Rebuild the currency row, the equipment doll and the bag grid.
##
## The currency line is written before the dead check on purpose: a player who
## dies while looting must still see the coins they picked up, and
## `test_scenario.gd:196` reads the label right after an `add_loot` that fires
## `inventory_changed`.
func refresh() -> void:
	if not is_instance_valid(player):
		return
	if galleons_label != null:
		galleons_label.text = "Galleons: %d" % player.galleons
	if player.is_dead:
		return
	_refresh_equipment()
	_refresh_bag()


func _on_inventory_changed() -> void:
	if visible:
		refresh()


func _process(_delta: float) -> void:
	if not visible or _tooltip == null:
		return
	if _tooltip.visible:
		_tooltip.follow_cursor()


# --------------------------------------------------------------- equipment

## The item the player carries for a slot type, newest first. Derived, not
## authoritative - see the EQUIP_SLOTS comment.
func _equipped_for(type_key: String) -> Dictionary:
	if not is_instance_valid(player):
		return {}
	var inventory: Array = player.inventory
	for entry in inventory:
		var id := String(entry.get("id", ""))
		if id == "" or not GameData.ITEMS.has(id):
			continue
		if String(GameData.ITEMS[id].get("type", "")) == type_key:
			return {"id": id, "entry": entry}
	return {}


func _refresh_equipment() -> void:
	for i in _doll_slots.size():
		var slot := _doll_slots[i]
		var found := _equipped_for(String(EQUIP_SLOTS[i]["key"]))
		if found.is_empty():
			slot.set_item("", {})
		else:
			slot.set_item(String(found["id"]), found["entry"])


# --------------------------------------------------------------------- bag

func _refresh_bag() -> void:
	if item_container == null:
		return
	for child in item_container.get_children():
		child.queue_free()
	_bag_slots.clear()

	var items: Array = player.inventory
	for entry in items:
		var id := String(entry.get("id", ""))
		if id == "":
			continue
		var slot := _make_bag_slot()
		slot.set_item(id, entry)
		item_container.add_child(slot)

	# Pad the grid with empty cells so the bag reads as a bag rather than as a
	# ragged list, and so a nearly-empty inventory still looks like a container.
	var columns := item_container.columns
	var shown := items.size()
	var filler := maxi(0, int(ceil(float(maxi(shown, 18)) / columns)) * columns - shown)
	for _i in filler:
		item_container.add_child(_make_bag_slot())

	if _empty_label != null:
		_empty_label.text = "empty" if shown == 0 else "%d / %d slots" % [shown, shown + filler]


func _make_bag_slot() -> UISlot:
	var slot := UISlot.new(Vector2(50, 50))
	slot.slot_entered.connect(_on_slot_entered)
	slot.slot_exited.connect(_on_slot_exited)
	slot.pressed.connect(func(): _on_slot_pressed(slot))
	_bag_slots.append(slot)
	return slot


func _on_slot_entered(slot: UISlot) -> void:
	if slot.item_id == "" or _tooltip == null:
		return
	_tooltip.show_item(slot.item_id, slot.entry)
	_tooltip.follow_cursor()


func _on_slot_exited(_slot: UISlot) -> void:
	if _tooltip != null:
		_tooltip.hide_item()


func _on_slot_pressed(slot: UISlot) -> void:
	if slot.item_id == "" or slot.entry.is_empty():
		return
	_on_item_clicked(slot.entry)


## Consume a potion from an inventory entry.
##
## The heal is a hardcoded 150 even though `data/json/items.json` advertises 180
## for the Wiggenweld Potion. That mismatch is a known defect (## M44), but two harness checks pin the current number - `test_scenario.gd`
## expects `player.current_hp == 350` from 200 - so it is deliberately left
## alone here; fixing it is a balance change, not a reskin.
func _on_item_clicked(item_data: Dictionary) -> void:
	if not is_instance_valid(player) or player.is_dead:
		return

	var item_id := String(item_data.get("id", ""))
	var amount := int(item_data.get("amount", 0))

	if item_id == "potion_health":
		if player.current_hp < player.max_hp and amount > 0:
			var healed: int = mini(player.max_hp - player.current_hp, 150)
			item_data["amount"] = amount - 1
			player.current_hp = mini(player.max_hp, player.current_hp + 150)
			player.emit_stats()
			player.show_floating_text("+%d" % healed, Color(0.4, 1.0, 0.4))
			if int(item_data["amount"]) <= 0:
				player.inventory.erase(item_data)
			refresh()
	elif item_id == "potion_mana":
		if player.current_mana < player.max_mana and amount > 0:
			var restored: int = mini(player.max_mana - player.current_mana, 120)
			item_data["amount"] = amount - 1
			player.current_mana = mini(player.max_mana, player.current_mana + 120)
			player.emit_stats()
			player.show_floating_text("+%d" % restored, Color(0.4, 0.7, 1.0))
			if int(item_data["amount"]) <= 0:
				player.inventory.erase(item_data)
			refresh()


## Hiding the bag has to clear a hover card the cursor is no longer over -
## `mouse_exited` never fires when the whole panel disappears underneath it.
func _on_visibility_changed() -> void:
	if not visible and _tooltip != null:
		_tooltip.hide_item()
