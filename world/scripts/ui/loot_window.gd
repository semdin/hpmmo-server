extends Control
class_name LootWindow

## The small chest window (Knight Online style): clicking a chest on the ground
## opens its slots here. Click a slot to take that item, or "Take all".
##
## The window only ever shows what the authority says the chest holds - the
## chest record's `items` (replicated by `sim_loot_event`, re-sent after every
## partial take). A take is a request; the slot empties when the authority
## answers with the updated chest, and the window closes with the chest.

const COLUMNS := 5
const SLOT_PX := 48.0
## Walk further than this from the chest and the window closes.
const CLOSE_RANGE := 9.0

var _window: UIWindow
var _grid: GridContainer
var _take_all: Button
var _status: Label
var _tooltip: ItemTooltip
var _layer: CanvasLayer
var _chest_uid := 0
var _chest: Node3D = null
var _slots: Array[UISlot] = []


func _ready() -> void:
	theme = UITheme.get_theme()
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_to_group("loot_window")
	_layer = CanvasLayer.new()
	_layer.layer = 11
	add_child(_layer)
	_window = ArcaneSkin.window(I18n.upper(tr("Chest")), Vector2(COLUMNS * (SLOT_PX + 5) + 44, 214), "ui_inventory")
	_window.closed.connect(close)
	_layer.add_child(_window)
	_grid = GridContainer.new()
	_grid.columns = COLUMNS
	_grid.add_theme_constant_override("h_separation", 5)
	_grid.add_theme_constant_override("v_separation", 5)
	_grid.size_flags_horizontal = Control.SIZE_SHRINK_CENTER
	_window.body.add_child(_grid)
	_status = UITheme.body("", 12, UITheme.c("text_dim"))
	_status.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_window.body.add_child(_status)
	_take_all = Button.new()
	_take_all.text = tr("Take all")
	_take_all.focus_mode = Control.FOCUS_NONE
	_take_all.pressed.connect(func(): _take(-1))
	_window.body.add_child(_take_all)
	_tooltip = ItemTooltip.new()
	_layer.add_child(_tooltip)
	SimAuthority.loot_spawned.connect(_on_loot_spawned)
	SimAuthority.entity_despawned.connect(_on_despawned)
	visibility_changed.connect(func(): _layer.visible = visible)
	hide()


## Open (or re-target) the window on a chest view.
func open_chest(chest: Node3D) -> void:
	_chest = chest
	_chest_uid = int(chest.get_meta("sim_uid", 0))
	_status.text = ""
	refresh()
	if not visible:
		var view := get_viewport().get_visible_rect().size
		var at := Vector2(view.x * 0.5 + 140.0, view.y * 0.32).floor()
		_window.offset_left = minf(at.x, view.x - _window.custom_minimum_size.x - 12.0)
		_window.offset_top = at.y
		_window.offset_right = _window.offset_left + _window.custom_minimum_size.x
		_window.offset_bottom = _window.offset_top + _window.custom_minimum_size.y
	show()
	_window.open()
	_play("ui_open")


func close() -> void:
	_chest = null
	_chest_uid = 0
	if _tooltip != null:
		_tooltip.hide_item()
	hide()


func is_open() -> bool:
	return visible


func refresh() -> void:
	var record: Dictionary = SimAuthority.entities.get(_chest_uid, {})
	var items: Array = record.get("items", [])
	var rare := String(record.get("item_id", "chest")) == "chest_rare"
	_window.title = I18n.upper(tr("Enchanted Chest") if rare else tr("Chest"))
	for child in _grid.get_children():
		_grid.remove_child(child)
		child.queue_free()
	_slots.clear()
	var cells := maxi(COLUMNS * 2, int(ceil(float(items.size()) / COLUMNS)) * COLUMNS)
	for index in cells:
		var slot := UISlot.new(Vector2(SLOT_PX, SLOT_PX))
		slot.equipment_interaction = true
		slot.ready.connect(func(): slot.theme_type_variation = &"ArcaneSlot")
		slot.set_meta("chest_slot", index)
		if index < items.size() and int(items[index].get("amount", 0)) > 0:
			var entry: Dictionary = items[index]
			slot.set_item(String(entry.id), entry)
			slot.tooltip_text = ""
			slot.pressed.connect(func(): _take(index))
			slot.activated.connect(func(_s): _take(index))
			slot.slot_entered.connect(_on_slot_entered)
			slot.slot_exited.connect(func(_s): _tooltip.hide_item())
		_grid.add_child(slot)
		_slots.append(slot)
		# Galleons read as a sum ("88"), not a stack count ("x88").
		if slot.item_id == "galleons" and slot._count_label != null:
			slot._count_label.text = str(int(slot.entry.get("amount", 0)))
	_take_all.disabled = items.is_empty()


func _take(slot: int) -> void:
	if not is_instance_valid(_chest) or not _chest.has_method("collect"):
		close()
		return
	var player = SimAuthority.local_player_node()
	if player == null:
		return
	if _chest.collect(player, slot):
		_play("ui_loot")
	else:
		_status.text = tr("Too far away.") if player.global_position.distance_to(_chest.global_position) > 7.0 else ""


func _on_loot_spawned(uid: int, _item_id: String, _amount: int, _pos: Vector3, _items: Array) -> void:
	if visible and uid == _chest_uid:
		refresh()


func _on_despawned(uid: int) -> void:
	if visible and uid == _chest_uid:
		close()


func _on_slot_entered(slot: UISlot) -> void:
	if slot.item_id == "" or slot.item_id == "galleons":
		return
	_tooltip.show_item(slot.item_id, slot.entry)
	_tooltip.follow_cursor()


func _process(_delta: float) -> void:
	if not visible:
		return
	if _tooltip.visible:
		_tooltip.follow_cursor()
	var player = SimAuthority.local_player_node()
	if not is_instance_valid(_chest) or player == null \
			or player.global_position.distance_to(_chest.global_position) > CLOSE_RANGE:
		close()


func _play(sound: String) -> void:
	var audio := get_node_or_null("/root/AudioManager")
	if audio != null and audio.has_method("play_sound_at"):
		audio.play_sound_at(sound, Vector3.ZERO, null, true)
