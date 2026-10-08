extends Button
class_name UISlot

## One framed cell in a grid or an equipment doll.
##
## A Button with shared theme states and optional equipment gestures. The bag grid, the equipment
## doll and the spell hotbar all use this one widget, so a cell looks the same
## wherever it appears.
##
## Emits `slot_entered` / `slot_exited` rather than letting callers connect to
## the built-in `mouse_entered`, because a caller almost always wants the slot
## itself (to read `item_id` and `entry`) and not just the event.

signal slot_entered(slot: UISlot)
signal slot_exited(slot: UISlot)
signal activated(slot: UISlot)
signal dropped(destination: UISlot, payload: Dictionary)
var equipment_slot := ""
var equipment_interaction := false
var drop_check: Callable
var _accent: Panel
var selected := false:
	set(value):
		selected = value
		_update_accent()

## Item id this cell holds, or "" when empty.
var item_id := ""
## The player's inventory record for that item (id/amount/tier), backing the tooltip.
var entry: Dictionary = {}
## Small caption under the icon, used by the equipment doll ("Wand", "Robes").
var caption := "":
	set(value):
		caption = value
		if _caption_label != null:
			_caption_label.text = value
			_caption_label.visible = value != "" and item_id == ""
## Optional hotkey hint drawn in the top-left, used by the hotbar.
var key_hint := "":
	set(value):
		key_hint = value
		if _key_label != null:
			_key_label.text = value
			_key_label.visible = value != ""

var _icon: TextureRect = null
var _count_label: Label = null
var _caption_label: Label = null
var _key_label: Label = null
## Dim overlay used for a spell on cooldown.
var _cooldown: ColorRect = null
var _cooldown_label: Label = null


func _init(size := Vector2(52, 52)) -> void:
	custom_minimum_size = size
	clip_contents = true
	focus_mode = Control.FOCUS_NONE


func _ready() -> void:
	theme = UITheme.get_theme()
	theme_type_variation = UITheme.V_SLOT
	text = ""
	var inset := ColorRect.new()
	inset.color = Color("0b1423")
	inset.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	inset.offset_left = 5
	inset.offset_top = 5
	inset.offset_right = -5
	inset.offset_bottom = -5
	inset.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(inset)

	_icon = TextureRect.new()
	_icon.set_anchors_preset(Control.PRESET_FULL_RECT)
	_icon.offset_left = 6
	_icon.offset_top = 6
	_icon.offset_right = -6
	_icon.offset_bottom = -6
	_icon.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	_icon.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
	_icon.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(_icon)

	_cooldown = ColorRect.new()
	_cooldown.set_anchors_preset(Control.PRESET_FULL_RECT)
	_cooldown.color = Color(0.02, 0.02, 0.03, 0.62)
	_cooldown.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_cooldown.visible = false
	add_child(_cooldown)

	_count_label = Label.new()
	_count_label.set_anchors_preset(Control.PRESET_BOTTOM_RIGHT)
	_count_label.offset_left = -30
	_count_label.offset_top = -18
	_count_label.offset_right = -3
	_count_label.offset_bottom = -1
	_count_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
	_count_label.add_theme_font_size_override("font_size", UITheme.FS_SMALL)
	_count_label.add_theme_color_override("font_color", UITheme.c("parchment"))
	_count_label.add_theme_color_override("font_outline_color", UITheme.c("shadow"))
	_count_label.add_theme_constant_override("outline_size", 4)
	_count_label.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(_count_label)

	# The hotkey sits in the cell's top-left corner, in the bold reading face at
	# full strength: at FS_TINY in the muted metal it was drawn but invisible.
	_key_label = Label.new()
	_key_label.set_anchors_preset(Control.PRESET_TOP_LEFT)
	_key_label.offset_left = 5
	_key_label.offset_top = 1
	_key_label.offset_right = 30
	_key_label.offset_bottom = 17
	_key_label.add_theme_font_override("font", UITheme.font_body_bold())
	_key_label.add_theme_font_size_override("font_size", UITheme.FS_SMALL)
	_key_label.add_theme_color_override("font_color", UITheme.c("parchment"))
	_key_label.add_theme_color_override("font_outline_color", UITheme.c("shadow"))
	_key_label.add_theme_constant_override("outline_size", 4)
	_key_label.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_key_label.visible = key_hint != ""
	_key_label.text = key_hint
	add_child(_key_label)

	_cooldown_label = Label.new()
	_cooldown_label.set_anchors_preset(Control.PRESET_FULL_RECT)
	_cooldown_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_cooldown_label.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	_cooldown_label.add_theme_font_size_override("font_size", UITheme.FS_LABEL)
	_cooldown_label.add_theme_color_override("font_color", UITheme.c("parchment"))
	_cooldown_label.add_theme_color_override("font_outline_color", UITheme.c("shadow"))
	_cooldown_label.add_theme_constant_override("outline_size", 4)
	_cooldown_label.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_cooldown_label.visible = false
	add_child(_cooldown_label)

	_caption_label = Label.new()
	_caption_label.set_anchors_preset(Control.PRESET_BOTTOM_WIDE)
	_caption_label.offset_top = -16
	_caption_label.offset_bottom = -2
	_caption_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_caption_label.add_theme_font_size_override("font_size", UITheme.FS_TINY)
	_caption_label.add_theme_color_override("font_color", UITheme.c("text_dim"))
	_caption_label.add_theme_color_override("font_outline_color", UITheme.c("shadow"))
	_caption_label.add_theme_constant_override("outline_size", 4)
	_caption_label.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_caption_label.text = caption
	_caption_label.visible = caption != ""
	add_child(_caption_label)

	_accent = Panel.new()
	_accent.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	_accent.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(_accent)
	mouse_entered.connect(func(): slot_entered.emit(self))
	mouse_exited.connect(func(): slot_exited.emit(self))

	# A caller may have filled the slot before it entered the tree.
	_apply_item()


## Fill the cell from an inventory record, or clear it with an empty id.
##
## Safe to call before the slot is in the tree - callers build a grid by
## creating a slot, filling it and only then adding it as a child, and the
## children it needs do not exist until `_ready`. The pending item is applied
## there instead of being dropped.
func set_item(p_id: String, p_entry: Dictionary = {}) -> void:
	item_id = p_id
	entry = p_entry
	if _icon == null:
		return
	_apply_item()


func _apply_item() -> void:
	_update_accent()
	var p_id := item_id
	var p_entry := entry
	var tex: Texture2D = null
	if p_id != "":
		tex = UITheme.icon_for(p_id)
	_icon.texture = tex
	_icon.visible = tex != null
	var amount := int(p_entry.get("amount", 0))
	_count_label.text = ("x%d" % amount) if (amount > 1 and p_id != "") else ""
	var tier := int(p_entry.get("tier", 0))
	if p_id != "" and tier > 0:
		_count_label.text = "+%d  %s" % [tier, _count_label.text]
	if _caption_label != null:
		_caption_label.visible = caption != "" and p_id == ""


## Draw the cooldown veil. `remaining` in seconds, `fraction` 0..1 of the bar.
func set_cooldown(remaining: float, fraction: float) -> void:
	if _cooldown == null:
		return
	var active := remaining > 0.0
	_cooldown.visible = active
	_cooldown_label.visible = active
	if active:
		# The veil is anchored full-rect, so its extent is an offset, not a size:
		# writing `size` here is overwritten by the next layout pass.
		_cooldown.offset_top = 0.0
		_cooldown.offset_left = 0.0
		_cooldown.offset_right = 0.0
		_cooldown.offset_bottom = -size.y * clampf(fraction, 0.0, 1.0)
		_cooldown_label.text = ("%.1f" % remaining) if remaining < 10.0 else "%d" % int(remaining)


func clear() -> void:
	set_item("", {})

func _gui_input(event: InputEvent) -> void:
	if not equipment_interaction or disabled: return
	if event is InputEventMouseButton and event.pressed:
		if event.button_index == MOUSE_BUTTON_RIGHT or (event.button_index == MOUSE_BUTTON_LEFT and event.double_click):
			activated.emit(self)
			accept_event()

func _get_drag_data(_at: Vector2) -> Variant:
	if not equipment_interaction or disabled or item_id == "": return null
	var payload := {"arcane_item": true, "id": item_id, "tier": int(entry.get("tier", 0)), "source_slot": equipment_slot}
	var preview := TextureRect.new()
	preview.texture = UITheme.icon_for(item_id)
	preview.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	preview.custom_minimum_size = Vector2(44,44)
	set_drag_preview(preview)
	return payload

func _can_drop_data(_at: Vector2, payload: Variant) -> bool:
	return equipment_interaction and not disabled and payload is Dictionary and payload.get("arcane_item", false) and drop_check.is_valid() and drop_check.call(self, payload)

func _drop_data(_at: Vector2, payload: Variant) -> void:
	if _can_drop_data(_at, payload): dropped.emit(self, payload)

func _update_accent() -> void:
	if _accent == null: return
	var border := StyleBoxFlat.new()
	border.bg_color = Color.TRANSPARENT
	border.set_corner_radius_all(4)
	var rarity: String = HPEquipment.item(item_id).get("rarity", "common")
	border.border_color = Color("6bcde0") if selected else ItemTooltip.RARITY_COLOUR.get(rarity,Color.WHITE) * Color(1,1,1,0.55)
	border.set_border_width_all(2 if selected else 0)
	if not selected and item_id != "" and not HPEquipment.item(item_id).is_empty(): border.border_width_bottom = 2
	_accent.add_theme_stylebox_override("panel", border)
