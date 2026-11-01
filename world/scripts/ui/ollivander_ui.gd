extends Control

## Ollivander's workshop (O) - the Metin2 blacksmith. It works on ONE item put
## on its anvil: drag a wand, cloak, broom or accessory from the bag onto the
## slot, or right-click it in the bag while the workshop is open. The anvil
## header shows the item; below it two tabs:
##   Upgrade  - +N -> +N+1 with the stat lines now and after (gains in green),
##              the materials (one cell each, have/need) and the galleon cost,
##              the success chance and the downgrade risk, then UPGRADE
##              (combat.json `wand_tiers`, `upgrade_curves`);
##   Enchant  - the item's efsun slots (filled with grade, or empty) and the
##              two scrolls: imbue (chance by the current count) and reweave.
## With the anvil empty the page explains both instead of standing empty. The
## authority rolls every outcome; requests name the item by its instance uid.
##
## The workshop docks left of the inventory, which opens with it.

signal wand_upgraded(new_tier: int)
signal item_upgraded(slot: String, new_tier: int)

const WIDTH := 430.0
const HEIGHT := 600.0
const PAGE_H := 376.0
const MAT_CELL := 50.0

const WELL := Color("070b12")
const WELL_EDGE := Color("3a3122")
const FAINT := Color(0.435, 0.424, 0.400)
const GOOD := Color(0.498, 0.839, 0.478)
const BAD := Color(0.937, 0.416, 0.373)

var player: Node3D = null
## The instance on the anvil (its uid), 0 = empty.
var target_uid := 0
var _pending_id := -1
var _last_op := ""
var _layer: CanvasLayer
var _window: UIWindow
var _tooltip: ItemTooltip
var _slot: UISlot
var _slot_hint: AnvilHint
var _item_name: Label
var _item_plus: Label
var _item_meta: Label
var _empty_hint: Label
var _take: Button
var _tab_row: Control
var _tabs: Dictionary = {}    # page id -> HudCharacterWindow.TabChip
var _pages: Dictionary = {}   # page id -> VBoxContainer
var _page := "refine"
var _enchant_count: Label
var _refine: VBoxContainer
var _enchant: VBoxContainer
var _upgrade_button: Button
var _foot: Label

func _ready() -> void:
	theme = UITheme.get_theme()
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	_layer = CanvasLayer.new()
	_layer.layer = 10
	add_child(_layer)
	_window = ArcaneSkin.window(I18n.upper(tr("Ollivander")), Vector2(WIDTH, HEIGHT), "ui_ollivander")
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

# -------------------------------------------------------------------- build

func _build() -> void:
	var body := _window.body
	body.add_theme_constant_override("separation", 10)
	_build_anvil(body)
	# Tabs, the same strip as the character window.
	var strip := VBoxContainer.new()
	strip.add_theme_constant_override("separation", 0)
	body.add_child(strip)
	_tab_row = strip
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 4)
	strip.add_child(row)
	var pad := Control.new()
	pad.custom_minimum_size = Vector2(2, 0)
	row.add_child(pad)
	for page in [["refine", tr("Upgrade")], ["enchant", tr("Enchant")]]:
		var tab := HudCharacterWindow.TabChip.new(String(page[1]))
		tab.name = "Tab_" + String(page[0])
		tab.chosen.connect(_show_page.bind(String(page[0])))
		row.add_child(tab)
		_tabs[String(page[0])] = tab
	_enchant_count = HudKit.label("", 12, ItemTooltip.ENCHANT_COLOUR, HudKit.body(), 0)
	(_tabs["enchant"] as HudCharacterWindow.TabChip).row.add_child(_enchant_count)
	var rule := ColorRect.new()
	rule.color = HudKit.GOLD_DK
	rule.custom_minimum_size = Vector2(0, 1)
	strip.add_child(rule)

	var holder := Control.new()
	holder.custom_minimum_size = Vector2(0, PAGE_H)
	holder.mouse_filter = Control.MOUSE_FILTER_IGNORE
	body.add_child(holder)
	for id in ["intro", "refine", "enchant"]:
		var page := VBoxContainer.new()
		page.name = "Page_" + id
		page.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
		page.mouse_filter = Control.MOUSE_FILTER_IGNORE
		holder.add_child(page)
		_pages[id] = page
	_build_intro(_pages["intro"])
	_refine = _pages["refine"]
	_enchant = _pages["enchant"]

	_foot = HudKit.label(tr("Right-click an item in your bag or drag it here"), 12, FAINT, HudKit.body(), 0)
	_foot.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	body.add_child(_foot)

## The anvil: the slot, the item's name and kind, and the button that takes
## it off again (Metin2's Cancel).
func _build_anvil(body: VBoxContainer) -> void:
	var card := PanelContainer.new()
	var sb := _box(WELL, WELL_EDGE, 5, 12)
	card.add_theme_stylebox_override("panel", sb)
	card.custom_minimum_size = Vector2(0, 92)
	body.add_child(card)
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 14)
	card.add_child(row)
	_slot = UISlot.new(Vector2(66, 66))
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
	row.add_child(_slot)
	_slot_hint = AnvilHint.new()
	_slot_hint.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	_slot.add_child(_slot_hint)

	var info := VBoxContainer.new()
	info.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	info.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	info.add_theme_constant_override("separation", 2)
	row.add_child(info)
	var name_row := HBoxContainer.new()
	name_row.add_theme_constant_override("separation", 6)
	info.add_child(name_row)
	_item_plus = HudKit.label("", 17, HudKit.GOLD_HI, HudKit.title(), 2)
	name_row.add_child(_item_plus)
	_item_name = HudKit.label("", 17, Color.WHITE, HudKit.body(), 2)
	_item_name.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_item_name.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
	_item_name.custom_minimum_size.x = 60
	name_row.add_child(_item_name)
	_item_meta = HudKit.label("", 13, HudKit.TEXT_DIM, HudKit.body(), 0)
	info.add_child(_item_meta)
	_empty_hint = HudKit.label(tr("Drag the item you want to upgrade or enchant here, or right-click it in your bag."), 14, HudKit.TEXT_DIM, HudKit.body(), 0)
	_empty_hint.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_empty_hint.custom_minimum_size.x = 200
	info.add_child(_empty_hint)

	_take = Button.new()
	_take.name = "Take"
	_take.text = "×"
	_take.tooltip_text = tr("Take it off the anvil")
	_take.focus_mode = Control.FOCUS_NONE
	_take.custom_minimum_size = Vector2(26, 26)
	_take.size_flags_vertical = Control.SIZE_SHRINK_BEGIN
	_take.add_theme_font_override("font", HudKit.body())
	_take.add_theme_font_size_override("font_size", 16)
	_take.add_theme_color_override("font_color", HudKit.TEXT_DIM)
	_take.add_theme_color_override("font_hover_color", HudKit.GOLD_HI)
	for state in ["normal", "hover", "pressed"]:
		_take.add_theme_stylebox_override(state, _box(Color("0d1320"), HudKit.GOLD if state != "normal" else Color("3a4560"), 4, 0))
	_take.pressed.connect(clear_target)
	row.add_child(_take)

## What the workshop does, in place of empty pages while the anvil is empty.
func _build_intro(page: VBoxContainer) -> void:
	page.add_theme_constant_override("separation", 8)
	var top := Control.new()
	top.custom_minimum_size = Vector2(0, 4)
	page.add_child(top)
	page.add_child(_howto("mat_phoenix_ash", tr("Upgrade"),
			tr("Takes wands, cloaks, brooms and accessories from +0 to +9. Every step needs materials and galleons; the chance falls with each level, and from +%d a failure drops the item one level.")
			% int(HPRules.combat().get("upgrade_curves", {}).get("fail_downgrade_from", 4))))
	page.add_child(_howto("scroll_imbue", tr("Enchant"),
			tr("An item holds up to %d enchantments. An Imbue rune adds a new one (the more it has, the lower the chance); a Reweave rune rerolls them all.")
			% int(HPEquipment.enchant_rules().get("max_bonuses", 5))))
	var spacer := Control.new()
	spacer.size_flags_vertical = Control.SIZE_EXPAND_FILL
	page.add_child(spacer)
	var note := HudKit.label(tr("Worn items must be taken off first  ·  the item stays locked in the bag while on the anvil"), 12, FAINT, HudKit.body(), 0)
	note.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	note.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	page.add_child(note)

func _howto(icon_id: String, title: String, text: String) -> PanelContainer:
	var card := PanelContainer.new()
	var sb := _box(Color(0.086, 0.141, 0.227, 0.45), Color("23324c"), 5, 11)
	sb.content_margin_left = 12
	card.add_theme_stylebox_override("panel", sb)
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 12)
	card.add_child(row)
	var icon := TextureRect.new()
	icon.texture = UITheme.icon_for(icon_id)
	icon.custom_minimum_size = Vector2(40, 40)
	icon.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	icon.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
	icon.size_flags_vertical = Control.SIZE_SHRINK_BEGIN
	row.add_child(icon)
	var col := VBoxContainer.new()
	col.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	col.add_theme_constant_override("separation", 3)
	row.add_child(col)
	col.add_child(HudKit.label(I18n.upper(title), 13, HudKit.GOLD_LT, HudKit.title(), 2))
	var body := HudKit.label(text, 13, HudKit.TEXT_DIM, HudKit.body(), 0)
	body.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	body.custom_minimum_size.x = 260
	col.add_child(body)
	return card

static func _box(bg: Color, border: Color, radius: int, margin: float) -> StyleBoxFlat:
	return HudSkillWindow._box(bg, border, radius, margin)

func _show_page(page: String) -> void:
	_page = page
	var has := not _find(target_uid).is_empty()
	_tab_row.visible = has
	for id in _pages:
		(_pages[id] as Control).visible = (id == page) if has else id == "intro"
	for id in _tabs:
		(_tabs[id] as HudCharacterWindow.TabChip).selected = id == page

func _clear(box: Container) -> void:
	for child in box.get_children():
		box.remove_child(child)
		child.queue_free()

func _gap(box: Container, px: float) -> void:
	var c := Control.new()
	c.custom_minimum_size = Vector2(0, px)
	c.mouse_filter = Control.MOUSE_FILTER_IGNORE
	box.add_child(c)

# --------------------------------------------------------------- the anvil

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
	at.y = clampf(at.y, 24.0, maxf(24.0, canvas.y - HEIGHT - 12.0))
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
	var id := String(_find(uid).get("id", ""))
	# Open on the page the item can use: enchant-only pieces skip Upgrade.
	_page = "enchant" if id != "" and not HPEquipment.refinable(id) else "refine"
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

## The materials one upgrade step asks for, as [[id, amount], ...]: a step may
## list several under `materials`, or name one with material_id/_amount.
static func _step_materials(step: Dictionary) -> Array:
	if step.has("materials"):
		return (step.materials as Array).map(func(m): return [String(m.get("id", "")), int(m.get("amount", 0))])
	if String(step.get("material_id", "")) == "":
		return []
	return [[String(step.material_id), int(step.material_amount)]]

func _refresh() -> void:
	if not is_instance_valid(player) or _slot == null: return
	if target_uid > 0 and _worn_slot(target_uid) != "":
		target_uid = 0   # the anvil only works bag items
	var item := _find(target_uid)
	if item.is_empty():
		target_uid = 0
	var id := String(item.get("id", ""))
	_slot.set_item(id, item)
	_slot_hint.visible = item.is_empty()
	_take.visible = not item.is_empty()
	_empty_hint.visible = item.is_empty()
	_foot.visible = not item.is_empty()   # the empty anvil already says it
	_item_plus.visible = not item.is_empty()
	_item_name.visible = not item.is_empty()
	_item_meta.visible = not item.is_empty()
	_clear(_refine)
	_clear(_enchant)
	_upgrade_button = null
	if not item.is_empty():
		var tier := int(item.get("tier", 0))
		var data := HPEquipment.item(id)
		_item_plus.text = "+%d" % tier
		_item_plus.visible = HPEquipment.refinable(id)
		_item_name.text = I18n.t(String(data.get("name", id)))
		_item_name.add_theme_color_override("font_color", ItemTooltip.RARITY_COLOUR.get(ItemTooltip.rarity_of(id), Color.WHITE))
		var kind := String(data.get("type", ""))
		var kind_text := tr(String(ItemTooltip.KIND_LABEL.get(kind, kind.capitalize())))
		if kind == "armor":
			kind_text = tr(String(data.get("slots", ["armor"])[0]).replace("_", " ").capitalize())
		_item_meta.text = "%s  ·  %s  ·  %s" % [kind_text, ItemTooltip.rarity_label(id), tr("Level %d") % HPEquipment.required_level(id)]
		_build_refine(id, tier)
		_build_enchant(id, item)
		_enchant_count.text = "%d/%d" % [(item.get("bonuses", []) as Array).size(), int(HPEquipment.enchant_rules().get("max_bonuses", 5))] \
				if HPEquipment.enchantable(id) else ""
	_show_page(_page)

# ------------------------------------------------------------------ upgrade

func _build_refine(id: String, tier: int) -> void:
	var page := _refine
	page.add_theme_constant_override("separation", 0)
	_gap(page, 14)
	if not HPEquipment.refinable(id):
		var label := HudKit.label(tr("Cannot be refined"), 15, HudKit.TEXT_DIM, HudKit.body(), 0)
		label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
		page.add_child(label)
		return
	var busy := _pending_id != -1
	var top_tier := 9
	var steps := HBoxContainer.new()
	steps.alignment = BoxContainer.ALIGNMENT_CENTER
	steps.add_theme_constant_override("separation", 14)
	page.add_child(steps)
	if tier >= top_tier:
		steps.add_child(StepBadge.new("+%d" % tier, true))
		_gap(page, 12)
		var done := HudKit.label(tr("Fully refined"), 16, HudKit.GOLD_HI, HudKit.body(), 2)
		done.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
		page.add_child(done)
		var sub := HudKit.label(tr("This item is at its highest level."), 13, HudKit.TEXT_DIM, HudKit.body(), 0)
		sub.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
		page.add_child(sub)
		_gap(page, 12)
		_compare(page, id, tier, tier)
		return
	steps.add_child(StepBadge.new("+%d" % tier, false))
	steps.add_child(ArrowMark.new())
	steps.add_child(StepBadge.new("+%d" % (tier + 1), true))
	_gap(page, 12)
	_compare(page, id, tier, tier + 1)

	var step: Dictionary = HPRules.combat().wand_tiers[tier]
	var cost := int(step.cost)
	var cost_ok := int(player.galleons) >= cost
	var head := HBoxContainer.new()
	page.add_child(head)
	_gap(page, 6)
	head.add_child(HudKit.label(I18n.upper(tr("Requirements")), 12, HudKit.GOLD_LT, HudKit.title(), 2))
	var head_gap := Control.new()
	head_gap.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	head.add_child(head_gap)
	head.add_child(_cost_pill(cost, cost_ok))
	var mats := HBoxContainer.new()
	mats.add_theme_constant_override("separation", 6)
	page.add_child(mats)
	var mats_ok := true
	for need in _step_materials(step):
		var have := _count(String(need[0]))
		mats_ok = mats_ok and have >= int(need[1])
		mats.add_child(_material_cell(String(need[0]), int(need[1]), have))

	_gap(page, 12)
	var chance := int(step.chance)
	var row := HBoxContainer.new()
	page.add_child(row)
	var caption := HudKit.label(tr("Success chance"), 13, HudKit.TEXT_DIM, HudKit.body(), 0)
	caption.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	row.add_child(caption)
	row.add_child(HudKit.label(tr("%d%%") % chance, 14, HudKit.PARCHMENT, HudKit.body(), 0))
	_gap(page, 4)
	var colour := GOOD if chance >= 75 else (HudKit.GOLD_LT if chance >= 40 else BAD)
	var bar := HudCharacterWindow.FillBar.new(colour.lightened(0.15), colour.darkened(0.25), 10.0)
	bar.fraction = chance / 100.0
	page.add_child(bar)
	_gap(page, 5)
	var floor_tier := int(HPRules.combat().get("upgrade_curves", {}).get("fail_downgrade_from", 4))
	var risky := tier >= floor_tier
	page.add_child(HudKit.label(tr("If it fails, the item drops to +%d") % (tier - 1) if risky else tr("A failure does not lower the level"),
			13, BAD if risky else FAINT, HudKit.body(), 0))

	var spacer := Control.new()
	spacer.size_flags_vertical = Control.SIZE_EXPAND_FILL
	page.add_child(spacer)
	_upgrade_button = HudKit.gold_button(I18n.upper(tr("Upgrade now")), 40.0, 16)
	_upgrade_button.disabled = busy or not cost_ok or not mats_ok
	_upgrade_button.pressed.connect(_on_refine_pressed)
	page.add_child(_upgrade_button)

## The item's stat lines now and after the step, side by side; a line that
## grows shows its new value in green.
func _compare(page: VBoxContainer, id: String, from: int, to: int) -> void:
	var now := stat_lines(id, from)
	var later := stat_lines(id, to)
	page.add_child(_hair(0.25))
	var split := RegEx.create_from_string("^(.*?)\\s*([+\\-]?\\d.*)$")
	for i in now.size():
		var row := HBoxContainer.new()
		row.custom_minimum_size = Vector2(0, 28)
		row.add_theme_constant_override("separation", 8)
		page.add_child(row)
		var m := split.search(String(now[i]))
		var key := m.get_string(1) if m != null else String(now[i])
		var value := m.get_string(2) if m != null else ""
		var next_text := String(later[i]) if i < later.size() else String(now[i])
		var m2 := split.search(next_text)
		var next_value := m2.get_string(2) if m2 != null else next_text
		var k := HudKit.label(key, 14, HudKit.TEXT_DIM, HudKit.body(), 0)
		k.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		row.add_child(k)
		var v := HudKit.label(value, 14, HudKit.PARCHMENT, HudKit.body(), 0)
		v.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
		row.add_child(v)
		if from != to:
			var arrow := HudKit.label("›", 14, FAINT, HudKit.body(), 0)
			arrow.custom_minimum_size.x = 12
			arrow.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
			row.add_child(arrow)
			var n := HudKit.label(next_value, 14, FAINT if next_value == value else GOOD, HudKit.body(), 0)
			n.custom_minimum_size.x = 92
			n.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
			row.add_child(n)
		page.add_child(_hair(0.12))

func _hair(alpha: float) -> ColorRect:
	var line := ColorRect.new()
	line.color = Color(HudKit.GOLD, alpha)
	line.custom_minimum_size = Vector2(0, 1)
	line.mouse_filter = Control.MOUSE_FILTER_IGNORE
	return line

func _cost_pill(cost: int, ok: bool) -> PanelContainer:
	var pill := PanelContainer.new()
	pill.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	var sb := _box(WELL, Color("2f5a2c") if ok else Color("6a2622"), 12, 0)
	sb.content_margin_left = 10
	sb.content_margin_right = 9
	sb.content_margin_top = 2
	sb.content_margin_bottom = 2
	pill.add_theme_stylebox_override("panel", sb)
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 7)
	pill.add_child(row)
	row.add_child(HudKit.label(tr("Cost"), 12, HudKit.TEXT_DIM, HudKit.body(), 0))
	row.add_child(HudKit.label(preload("res://scripts/ui/inventory_arcane.gd").galleon_text(cost), 14, HudKit.GOLD_HI if ok else BAD, HudKit.body(), 0))
	var coin := PanelContainer.new()
	coin.custom_minimum_size = Vector2(15, 15)
	coin.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	coin.add_theme_stylebox_override("panel", _box(Color(0.85, 0.62, 0.22), HudKit.GOLD_HI, 8, 0))
	row.add_child(coin)
	return pill

## One material: its icon in a slot, "have/need" under it (green when there
## is enough), and its name on hover.
func _material_cell(id: String, need: int, have: int) -> Control:
	var cell := UISlot.new(Vector2(MAT_CELL, MAT_CELL))
	cell.set_item(id, {"amount": 1})
	cell.ready.connect(func(): cell.theme_type_variation = &"ArcaneSlot")
	cell.tooltip_text = tr("%s  ·  you have %d, need %d") % [I18n.t(String(HPEquipment.item(id).get("name", id))), have, need]
	var ok := have >= need
	if not ok:
		cell.self_modulate = Color(0.75, 0.7, 0.7)
	var count := HudKit.label("%d/%d" % [have, need], 12, GOOD if ok else BAD, HudKit.bold(), 4)
	count.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	count.set_anchors_and_offsets_preset(Control.PRESET_BOTTOM_WIDE)
	count.offset_top = -17
	count.offset_bottom = 1
	cell.add_child(count)
	cell.ready.connect(func(): cell.move_child(count, -1))   # over the icon UISlot adds in _ready
	return cell

# ------------------------------------------------------------------ enchant

func _build_enchant(id: String, item: Dictionary) -> void:
	var page := _enchant
	page.add_theme_constant_override("separation", 5)
	_gap(page, 9)
	if not HPEquipment.enchantable(id):
		var label := HudKit.label(tr("Cannot be enchanted"), 15, HudKit.TEXT_DIM, HudKit.body(), 0)
		label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
		page.add_child(label)
		return
	var rules := HPEquipment.enchant_rules()
	var held: Array = item.get("bonuses", [])
	var cap := int(rules.get("max_bonuses", 5))
	for i in cap:
		page.add_child(_bonus_row(i, held[i] if i < held.size() else {}))
	var spacer := Control.new()
	spacer.size_flags_vertical = Control.SIZE_EXPAND_FILL
	page.add_child(spacer)
	var busy := _pending_id != -1
	var imbue_id := String(rules.get("imbue_scroll", ""))
	var reweave_id := String(rules.get("reweave_scroll", ""))
	var chances: Array = rules.get("imbue_chance", [100])
	var imbue_chance := int(chances[clampi(held.size(), 0, chances.size() - 1)])
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 8)
	page.add_child(row)
	var full := held.size() >= cap
	var imbue := _scroll_card(imbue_id, tr("Imbue"),
			(tr("Slots full  ·  you have %d") % _count(imbue_id)) if full else (tr("Chance %d%%  ·  you have %d") % [imbue_chance, _count(imbue_id)]))
	imbue.name = "Imbue"
	imbue.disabled = busy or full or _count(imbue_id) == 0
	imbue.modulate.a = 0.45 if imbue.disabled else 1.0
	imbue.pressed.connect(_on_enchant_pressed.bind("imbue_scroll"))
	row.add_child(imbue)
	var reweave := _scroll_card(reweave_id, tr("Reweave"),
			(tr("No enchantments  ·  you have %d") % _count(reweave_id)) if held.is_empty() else (tr("Rerolls %d  ·  you have %d") % [held.size(), _count(reweave_id)]))
	reweave.name = "Reweave"
	reweave.disabled = busy or held.is_empty() or _count(reweave_id) == 0
	reweave.modulate.a = 0.45 if reweave.disabled else 1.0
	reweave.pressed.connect(_on_enchant_pressed.bind("reweave_scroll"))
	row.add_child(reweave)

## One efsun slot: its number, the bonus in violet and its grade (1-5), or a
## dim empty slot.
func _bonus_row(index: int, bonus: Dictionary) -> PanelContainer:
	var row := PanelContainer.new()
	row.custom_minimum_size = Vector2(0, 34)
	var empty := bonus.is_empty()
	var sb := _box(Color(0, 0, 0, 0) if empty else WELL, Color("2a3346") if empty else Color("2c2a3c"), 4, 0)
	sb.content_margin_left = 10
	sb.content_margin_right = 10
	row.add_theme_stylebox_override("panel", sb)
	var line := HBoxContainer.new()
	line.add_theme_constant_override("separation", 10)
	row.add_child(line)
	var number := HudKit.label(str(index + 1), 12, FAINT, HudKit.body(), 0)
	number.custom_minimum_size.x = 14
	number.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	line.add_child(number)
	var text := HudKit.label(tr("Empty enchantment slot") if empty else HPEquipment.bonus_text(bonus),
			13 if empty else 15, FAINT if empty else ItemTooltip.ENCHANT_COLOUR, HudKit.body(), 0)
	text.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	line.add_child(text)
	if not empty:
		var grade := GradePips.new(clampi(int(bonus.get("grade", 1)), 1, 5))
		grade.tooltip_text = tr("Grade %d/5") % grade.grade
		line.add_child(grade)
	return row

## A scroll as a button card: its icon, the action, and chance / count.
func _scroll_card(scroll_id: String, title: String, detail: String) -> Button:
	var button := Button.new()
	button.focus_mode = Control.FOCUS_NONE
	button.custom_minimum_size = Vector2(0, 60)
	button.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	button.tooltip_text = I18n.t(String(HPEquipment.item(scroll_id).get("desc", "")))
	var looks := {"normal": [Color(0.17, 0.13, 0.28, 0.75), Color("5a4a8a")], "hover": [Color(0.23, 0.18, 0.38, 0.85), ItemTooltip.ENCHANT_COLOUR],
			"pressed": [Color(0.13, 0.1, 0.22, 0.9), ItemTooltip.ENCHANT_COLOUR], "disabled": [Color(0.08, 0.07, 0.12, 0.6), Color("3a3550")]}
	for state in looks:
		button.add_theme_stylebox_override(state, _box(looks[state][0], looks[state][1], 5, 0))
	var row := HBoxContainer.new()
	row.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	row.offset_left = 10
	row.offset_right = -8
	row.add_theme_constant_override("separation", 10)
	row.mouse_filter = Control.MOUSE_FILTER_IGNORE
	button.add_child(row)
	var icon := TextureRect.new()
	icon.texture = UITheme.icon_for(scroll_id)
	icon.custom_minimum_size = Vector2(38, 38)
	icon.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	icon.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
	icon.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	icon.mouse_filter = Control.MOUSE_FILTER_IGNORE
	row.add_child(icon)
	var col := VBoxContainer.new()
	col.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	col.alignment = BoxContainer.ALIGNMENT_CENTER
	col.add_theme_constant_override("separation", 1)
	col.mouse_filter = Control.MOUSE_FILTER_IGNORE
	row.add_child(col)
	col.add_child(HudKit.label(title, 15, HudKit.GOLD_HI, HudKit.body(), 2))
	var small := HudKit.label(detail, 12, HudKit.TEXT_DIM, HudKit.body(), 0)
	small.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	small.custom_minimum_size.x = 100
	col.add_child(small)
	return button

# ---------------------------------------------------------------- requests

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
	var text := I18n.t(String(preload("res://scripts/ui/inventory_arcane.gd").REASONS.get(reason, tr("Equipment updated."))))
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


## The empty anvil slot: the workshop's mark, dim, inside a dashed outline
## that breathes, inviting a drop.
class AnvilHint extends Control:
	var _t := 0.0
	var _mark: Texture2D

	func _init() -> void:
		mouse_filter = Control.MOUSE_FILTER_IGNORE
		_mark = UITheme.icon_for("ui_ollivander")

	func _process(delta: float) -> void:
		if is_visible_in_tree():
			_t += delta
			queue_redraw()

	func _draw() -> void:
		var pulse := 0.5 + 0.5 * sin(_t * TAU / 2.2)
		if _mark != null:
			var s := size.x * 0.46
			draw_texture_rect(_mark, Rect2((size - Vector2(s, s)) * 0.5, Vector2(s, s)), false, Color(1, 1, 1, 0.45))
		var r := Rect2(Vector2(8, 8), size - Vector2(16, 16))
		var colour := Color(HudKit.GOLD_LT, 0.35 + 0.45 * pulse)
		var dash := 4.0
		for edge in [[r.position, Vector2(r.end.x, r.position.y)], [Vector2(r.end.x, r.position.y), r.end],
				[r.end, Vector2(r.position.x, r.end.y)], [Vector2(r.position.x, r.end.y), r.position]]:
			var a: Vector2 = edge[0]
			var b: Vector2 = edge[1]
			var length := a.distance_to(b)
			var dir := (b - a) / length
			var d := 0.0
			while d < length:
				draw_line(a + dir * d, a + dir * minf(d + dash, length), colour, 1.0)
				d += dash * 2.0


## A round "+N" badge; the step the upgrade reaches is lit.
class StepBadge extends Control:
	var text := ""
	var lit := false

	func _init(p_text: String, p_lit: bool) -> void:
		text = p_text
		lit = p_lit
		custom_minimum_size = Vector2(46, 46)
		mouse_filter = Control.MOUSE_FILTER_IGNORE

	func _draw() -> void:
		var c := size * 0.5
		var r := minf(size.x, size.y) * 0.5 - 1.0
		if lit:
			draw_circle(c, r + 2.0, Color(0.91, 0.78, 0.48, 0.18))
		draw_circle(c, r, HudKit.GOLD if lit else Color("4a5570"))
		draw_circle(c, r - 2.0, Color("141d30"))
		var font := HudKit.title()
		var w := font.get_string_size(text, HORIZONTAL_ALIGNMENT_LEFT, -1, 18).x
		draw_string(font, Vector2(c.x - w * 0.5, c.y + 6.5), text, HORIZONTAL_ALIGNMENT_LEFT, -1, 18, HudKit.GOLD_HI if lit else HudKit.PARCHMENT)


## The arrow between the two step badges.
class ArrowMark extends Control:
	func _init() -> void:
		custom_minimum_size = Vector2(22, 46)
		mouse_filter = Control.MOUSE_FILTER_IGNORE

	func _draw() -> void:
		var y := size.y * 0.5
		draw_line(Vector2(2, y), Vector2(size.x - 4, y), HudKit.GOLD, 2.0, true)
		draw_colored_polygon(PackedVector2Array([Vector2(size.x - 1, y), Vector2(size.x - 8, y - 5), Vector2(size.x - 8, y + 5)]), HudKit.GOLD)


## An enchantment's grade as five small bars, the first `grade` lit.
class GradePips extends Control:
	var grade := 1

	func _init(p_grade: int) -> void:
		grade = p_grade
		custom_minimum_size = Vector2(5 * 8 - 2, 12)
		size_flags_vertical = Control.SIZE_SHRINK_CENTER
		mouse_filter = Control.MOUSE_FILTER_STOP

	func _draw() -> void:
		for i in 5:
			var r := Rect2(Vector2(i * 8, 1), Vector2(6, 10))
			var on := i < grade
			draw_rect(r, ItemTooltip.ENCHANT_COLOUR if on else Color("1c1a2a"))
			draw_rect(r, Color("d6c6ff") if on else Color("3a3550"), false, 1.0)
