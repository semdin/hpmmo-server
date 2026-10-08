extends PanelContainer
class_name ItemTooltip

## The item hover card: name, kind, rarity, the item's real stat lines, and lore.
##
## Every number here comes from the running game, never from a mock-up:
## `GameData.ITEMS` supplies `type`, `rarity` and the type-specific fields, the
## player's wand tier comes from `player.wand_tier`, and the upgrade multiplier
## from `GameData.UPGRADE_TABLE`. If a field is absent for an item, its row is
## simply not built - the card never shows a placeholder dash.
##
## Style follows the reference: the name is tinted by rarity, the kind and rarity
## sit on one line, the stats are green, and the flavour text is a dim italic
## block at the bottom.

const KIND_LABEL := {
	"weapon": "One-Handed Wand",
	"armor": "Body Armour",
	"mount": "Broom mount",
	"consumable": "Consumable",
	"material": "Crafting material",
}

const RARITY_COLOUR := {
	"common": Color(0.88, 0.88, 0.88),
	"uncommon": Color(0.35, 0.82, 0.35),
	"rare": Color(0.36, 0.60, 0.94),
	"epic": Color(0.68, 0.40, 0.96),
	"legendary": Color(0.97, 0.66, 0.16),
}

const RARITY_NAME := {
	"common": "Common",
	"uncommon": "Uncommon",
	"rare": "Rare",
	"epic": "Epic",
	"legendary": "Legendary",
}

var _column: VBoxContainer = null
var _last_id := ""


## A `PanelContainer`, not a `Panel`, so the card is exactly as big as its
## content. A bare Panel with an anchored child reports a minimum size of zero,
## which draws an invisible card that only its (unclipped) labels can betray.
func _ready() -> void:
	theme = UITheme.get_theme()
	theme_type_variation = UITheme.V_TOOLTIP_CARD
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	z_index = 200
	hide()

	_column = VBoxContainer.new()
	_column.add_theme_constant_override("separation", 3)
	_column.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(_column)


static func rarity_of(item_id: String) -> String:
	if GameData.ITEMS.has(item_id):
		var r: Variant = GameData.ITEMS[item_id].get("rarity", "common")
		if r != null and String(r) != "":
			return String(r).to_lower()
	return "common"


## The rarity name for the top-right corner, e.g. "Unique" in the reference.
static func rarity_label(item_id: String) -> String:
	return RARITY_NAME.get(rarity_of(item_id), "Common")


## Build the card for `item_id`. `entry` is the player's inventory record, so a
## stacked or upgraded instance can show its own count and tier.
func show_item(item_id: String, entry: Dictionary = {}) -> void:
	if not GameData.ITEMS.has(item_id):
		hide()
		return
	_last_id = item_id
	for child in _column.get_children():
		child.queue_free()

	var data: Dictionary = GameData.ITEMS[item_id]
	var rarity := rarity_of(item_id)
	var tint: Color = RARITY_COLOUR.get(rarity, RARITY_COLOUR["common"])

	_add_name_row(String(data.get("name", item_id)), tint, rarity_label(item_id))
	_add_divider()
	_add_kind_row(item_id, data)

	var stats := _stat_rows(item_id, data, entry)
	for line in stats:
		_add_stat_row(line[0], line[1])
	if not stats.is_empty():
		_add_divider()

	var amount := int(entry.get("amount", 0))
	if amount > 1:
		_add_kv("Quantity", "x%d" % amount, UITheme.c("parchment"))
	var tier := int(entry.get("tier", 0))
	if _is_wand(item_id) and tier > 0:
		_add_kv("Refined", "+%d" % tier, UITheme.c("gold_lt"))

	var desc := String(data.get("desc", ""))
	if desc != "":
		_add_divider()
		_add_lore(desc)

	# The card must be sized before it is drawn; a container only recomputes on
	# the next layout pass, so force one now.
	set_anchors_preset(Control.PRESET_TOP_LEFT)
	custom_minimum_size = _column.get_combined_minimum_size() + Vector2(16, 16)
	reset_size()
	show()


func hide_item() -> void:
	hide()
	_last_id = ""


## Move the card next to the cursor, flipping to the other side of it when it
## would run off the right or bottom edge.
func follow_cursor() -> void:
	if not visible:
		return
	var vp := get_viewport()
	if vp == null:
		return
	var mouse := vp.get_mouse_position()
	var view := vp.get_visible_rect().size
	var at := mouse + Vector2(18, 12)
	if at.x + size.x > view.x - 6.0:
		at.x = mouse.x - size.x - 18.0
	if at.y + size.y > view.y - 6.0:
		at.y = maxf(6.0, view.y - size.y - 6.0)
	var delta := at - global_position
	offset_left += delta.x
	offset_right += delta.x
	offset_top += delta.y
	offset_bottom += delta.y


func _is_wand(item_id: String) -> bool:
	return item_id.begins_with("wand_")


func _stat_rows(item_id: String, data: Dictionary, entry: Dictionary) -> Array:
	"""The item's real numbers, in the reference's green '+' list."""
	var rows := []
	if _is_wand(item_id):
		var mult := float(data.get("base_multiplier", 1.0))
		var tier := int(entry.get("tier", 0))
		if GameData.UPGRADE_TABLE.has(tier):
			mult *= float(GameData.UPGRADE_TABLE[tier].get("multiplier", 1.0))
		rows.append(["+ %d%% Spell power" % int(round((mult - 1.0) * 100.0)), 1])
		if tier > 0 and GameData.UPGRADE_TABLE.has(tier):
			var chance := int(GameData.UPGRADE_TABLE[tier].get("chance", 0))
			if chance > 0:
				rows.append(["+ %d%% next refine chance" % chance, 1])
	if data.has("bonus_hp"):
		rows.append(["+ %d Max Health" % int(data["bonus_hp"]), 1])
	if data.has("bonus_defense"):
		rows.append(["+ %d%% Magic Armour" % int(data["bonus_defense"]), 1])
	if data.has("mount_speed"):
		rows.append(["+ %.1f Mount speed" % float(data["mount_speed"]), 1])
	if data.has("heal_hp"):
		rows.append(["+ %d Health restored" % int(data["heal_hp"]), 1])
	if data.has("heal_mana"):
		rows.append(["+ %d Mana restored" % int(data["heal_mana"]), 1])
	if data.has("upgrade_tier"):
		rows.append(["Refine stage +%d" % int(data["upgrade_tier"]), 1])
	return rows


# ------------------------------------------------------------------ rows

func _row() -> HBoxContainer:
	var h := HBoxContainer.new()
	h.add_theme_constant_override("separation", 10)
	h.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_column.add_child(h)
	return h


func _add_name_row(text: String, colour: Color, right: String) -> void:
	var h := _row()
	var name_label := Label.new()
	name_label.text = text
	name_label.add_theme_font_override("font", UITheme.font_title())
	name_label.add_theme_font_size_override("font_size", UITheme.FS_LABEL)
	name_label.add_theme_color_override("font_color", colour)
	name_label.add_theme_color_override("font_outline_color", UITheme.c("shadow"))
	name_label.add_theme_constant_override("outline_size", 3)
	name_label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	name_label.mouse_filter = Control.MOUSE_FILTER_IGNORE
	h.add_child(name_label)

	var rarity_label_node := Label.new()
	rarity_label_node.text = right
	rarity_label_node.add_theme_font_size_override("font_size", UITheme.FS_SMALL)
	rarity_label_node.add_theme_color_override("font_color", colour)
	rarity_label_node.vertical_alignment = VERTICAL_ALIGNMENT_BOTTOM
	rarity_label_node.mouse_filter = Control.MOUSE_FILTER_IGNORE
	h.add_child(rarity_label_node)


func _add_kind_row(item_id: String, data: Dictionary) -> void:
	var kind := String(data.get("type", ""))
	var text: String = KIND_LABEL.get(kind, kind.capitalize())
	_add_kv(kind.capitalize(), text, UITheme.c("text_dim"))


func _add_kv(left: String, right: String, colour: Color) -> void:
	var h := _row()
	var l := Label.new()
	l.text = left
	l.add_theme_font_size_override("font_size", UITheme.FS_SMALL)
	l.add_theme_color_override("font_color", UITheme.c("text_dim"))
	l.mouse_filter = Control.MOUSE_FILTER_IGNORE
	h.add_child(l)
	var spacer := Control.new()
	spacer.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	spacer.mouse_filter = Control.MOUSE_FILTER_IGNORE
	h.add_child(spacer)
	var r := Label.new()
	r.text = right
	r.add_theme_font_size_override("font_size", UITheme.FS_SMALL)
	r.add_theme_color_override("font_color", colour)
	r.mouse_filter = Control.MOUSE_FILTER_IGNORE
	h.add_child(r)


func _add_stat_row(text: String, _kind: int) -> void:
	var l := Label.new()
	l.text = text
	l.add_theme_font_size_override("font_size", UITheme.FS_SMALL)
	l.add_theme_color_override("font_color", UITheme.c("good"))
	l.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_column.add_child(l)


func _add_lore(text: String) -> void:
	var l := Label.new()
	l.text = text
	l.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	l.custom_minimum_size = Vector2(268, 0)
	l.add_theme_font_size_override("font_size", UITheme.FS_SMALL)
	l.add_theme_color_override("font_color", UITheme.c("text_dim"))
	l.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_column.add_child(l)


func _add_divider() -> void:
	_column.add_child(UITheme.divider())
