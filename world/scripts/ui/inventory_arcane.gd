extends Control

## The inventory (I): one vertical window in the Metin2 / Knight Online layout -
## the worn pieces on top, placed around the hero's silhouette (hat above the
## head, robe on the torso, boots at the feet, wand / hands / ring I left,
## focus / neck / ring II right, broom bottom right; an empty slot shows the
## faint outline of its kind and its name), the satchel below in pages of
## 5 x 8 (I, II, III - pages beyond HPEquipment.BAG_SLOTS stay locked), the
## purse at the bottom. Dropping an item on a page tab moves it to that page;
## holding a dragged item over a tab turns to it. The merchant opens beside it (left) for selling: drag a bag item
## onto the merchant, or right-click it while the merchant is open, then
## confirm the price. Delete throws the selected bag item away (after a yes/no
## question). Every change is a request to the authority
## (`SimNet.submit_equipment`); the window only shows what it answers.

# i18n-begin
const SLOT_LABELS := {"head":"Head", "chest":"Robes", "hands":"Hands", "feet":"Feet", "main_hand":"Wand", "off_hand":"Focus", "neck":"Neck", "ring_left":"Ring I", "ring_right":"Ring II", "broom":"Broom"}
const REASONS := {"in_combat":"Wait five seconds after combat.", "casting":"Finish casting first.", "dead":"You are defeated.", "mounted":"Dismount before changing your broom.", "level_too_low":"Your level is too low for that item.", "bag_full":"No room for the replaced item.", "wrong_slot":"That item does not fit.", "item_missing":"That item is no longer available.", "stale_inventory":"Inventory changed. Please try again.", "stale_request":"Action already handled.", "no_gold":"Not enough Oril.", "no_material":"Missing refinement material.", "no_wand":"Equip a wand first.", "max_tier":"Already fully refined.", "refined":"Refined!", "enchanted":"The enchantment holds!", "enchant_failed":"The weave slipped - the scroll is spent.", "no_scroll":"You have no such scroll.", "bonus_full":"This item cannot hold more enchantments.", "no_bonus":"There is nothing to reweave yet.", "not_enchantable":"That item cannot be enchanted.", "nothing_equipped":"Equip an item in that slot first.", "not_refinable":"That item cannot be refined.", "refinement_failed":"Refinement failed.", "save_conflict":"Inventory refreshed from your saved character.", "transfer_pending":"Wait until the map loads.", "invalid_state":"Equipment temporarily unavailable.", "resource_full":"That resource is already full.", "consumed":"", "sold":"", "not_sellable":"No merchant wants that.", "destroyed":"", "not_destroyable":"Take it off before destroying it."}
# i18n-end
const COLUMNS := 5
const ROWS := 8
const PAGE_CELLS := COLUMNS * ROWS
const PAGES := 3
const CELL_GAP := 2.0
## The equipment panel at its design size; it scales with the bag cells.
const DOLL_W := 268.0
const DOLL_H := 258.0
const DOLL_SLOT := 46.0
## slot -> [column ("l" / "c" / "r"), top at design size, outline icon of an empty slot]
const DOLL_SPOTS := {
	"head": ["c", 2.0, "hat_apprentice"], "chest": ["c", 92.0, "robe_apprentice"], "feet": ["c", 196.0, "boots_apprentice"],
	"main_hand": ["l", 8.0, "wand_ashwood"], "hands": ["l", 70.0, "gloves_apprentice"], "ring_left": ["l", 132.0, "ring_apprentice"],
	"off_hand": ["r", 8.0, "focus_apprentice"], "neck": ["r", 70.0, "pendant_apprentice"], "ring_right": ["r", 132.0, "ring_apprentice"],
	"broom": ["r", 194.0, "broom_nimbus2000"],
}
## The silhouette's box at design size (rendered by art/characters/hero_q/render_silhouette.py).
const FIG_TOP := 38.0
const FIG_H := 216.0
const SILHOUETTE := "res://assets/ui/inventory/hero_silhouette.png"
const MERCHANT_W := 320.0
## Sales shown in the merchant's log (this session, newest first).
const SALES_SHOWN := 4
## Width of the merchant's wrapping lines: before the window is laid out a
## wrapping label measures every word on its own line, and the first open came
## out as tall as the screen.
const MERCHANT_TEXT_W := MERCHANT_W - 36.0 - 26.0

var player: Node3D
var item_container: GridContainer
var galleons_label: Label
var close_button: Button
var _window: UIWindow
var _tooltip: ItemTooltip
var _doll_slots: Array[UISlot] = []
var _bag_slots: Array[UISlot] = []
## The page's cells, made once and refilled: every refresh (each time the bag
## opened, every bag change) freed and rebuilt 40 slots, ~37 ms.
var _bag_pool: Array[UISlot] = []
var _doll: Control
var _doll_fig: TextureRect
var _doll_labels: Dictionary = {}   # slot id -> Label under it
var _page := 0
var _page_tabs: Array = []
var _ring_menu: PopupMenu
var _ring_entry: Dictionary = {}
var _merchant_button: Button
var _footer: HBoxContainer
var _pending := false
var _pending_id := -1
var _last_operation := ""
var _selected_key := ""
var _presentation_layer: CanvasLayer
var _bag_px := 44.0
# Merchant
var _merchant: UIWindow
var _offer_box: VBoxContainer
var _offer_empty: Control
var _offer_slot: UISlot
var _offer_name: Label
var _offer_meta: Label
var _offer_warn: PanelContainer
var _offer_warn_text: Label
var _offer_each: HBoxContainer
var _offer_each_text: Label
var _offer_price: Label
var _sell_button: Button
var _cancel_button: Button
var _sales: Array = []   # [[item id, caption, galleons], ...] this session
var _sales_total: Label
var _sales_rows: VBoxContainer
var _sell_entry: Dictionary = {}
var _sold_price := 0
var _sold_entry: Array = []   # the sale asked for, logged when the answer comes
# Destroy (Delete key)
var _hover_slot: UISlot = null
var _destroy_window: UIWindow
var _destroy_text: Label
var _destroy_entry: Dictionary = {}
# Bag layout. The authority keeps the bag as a plain list, and drawing it in
# list order shifted every item up when one left (destroyed, sold, worn). The
# cell each item sits in is this client's own memory, per character (Metin2
# style): an emptied cell stays empty, the piece a wear swaps out takes the
# cell of the one put on, and an item dragged onto another cell moves there.
const LAYOUT_PATH := "user://bag_layout.json"
var _cells: Dictionary = {}       # item key -> cell index
var _cell_keys: Array = []        # cell index -> item key ("" = empty), as last drawn
var _cell_hint := -1              # the cell the next newcomer takes
var _layout_owner := ""

func _ready() -> void:
	theme = UITheme.get_theme()
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	_presentation_layer = CanvasLayer.new()
	_presentation_layer.layer = 10
	add_child(_presentation_layer)
	_build_inventory()
	_build_merchant()
	_build_destroy_confirm()
	_tooltip = ItemTooltip.new()
	_presentation_layer.add_child(_tooltip)
	_ring_menu = PopupMenu.new()
	_ring_menu.add_item(tr("Replace left ring"), 0)
	_ring_menu.add_item(tr("Replace right ring"), 1)
	_ring_menu.id_pressed.connect(func(id): _request("equip", "ring_left" if id == 0 else "ring_right", _ring_entry))
	add_child(_ring_menu)
	visibility_changed.connect(_on_visibility_changed)
	get_viewport().size_changed.connect(_layout)
	_layout()
	hide()

func _make_window(title: String, icon: String, size: Vector2) -> UIWindow:
	var window := ArcaneSkin.window(I18n.upper(title), size, icon)
	_presentation_layer.add_child(window)
	return window

func _build_inventory() -> void:
	_window = _make_window(tr("Inventory"), "ui_inventory", Vector2(272, 700))
	_window.name = "Window"
	_window.closed.connect(hide)
	close_button = _window._close_button
	_window.body.add_theme_constant_override("separation", 10)
	# The worn pieces around the hero's silhouette.
	_doll = DollPanel.new()
	_doll.name = "Doll"
	_window.body.add_child(_doll)
	_doll_fig = TextureRect.new()
	_doll_fig.texture = load(SILHOUETTE) if ResourceLoader.exists(SILHOUETTE) else null
	_doll_fig.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	_doll_fig.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
	_doll_fig.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_doll_fig.texture_filter = CanvasItem.TEXTURE_FILTER_LINEAR_WITH_MIPMAPS
	_doll.add_child(_doll_fig)
	for slot_id in DOLL_SPOTS:
		var slot := _make_slot(Vector2(DOLL_SLOT, DOLL_SLOT))
		slot.equipment_slot = slot_id
		var ghost_id := String(DOLL_SPOTS[slot_id][2])
		slot.ready.connect(func(): _style_cell(slot, true, ghost_id))
		_doll.add_child(slot)
		_doll_slots.append(slot)
		var label := UITheme.body(tr(String(SLOT_LABELS[slot_id])), 10, Color(HudKit.GOLD_LT, 0.5))
		label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
		label.mouse_filter = Control.MOUSE_FILTER_IGNORE
		_doll.add_child(label)
		_doll_labels[slot_id] = label
	# The satchel: page tabs over a tray of 5 x 8 cells, one page at a time.
	var satchel := VBoxContainer.new()
	satchel.add_theme_constant_override("separation", 0)
	_window.body.add_child(satchel)
	var tabs := HBoxContainer.new()
	tabs.add_theme_constant_override("separation", 0)
	satchel.add_child(tabs)
	for page in PAGES:
		var tab := PageTab.new(self, page)
		tab.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		tabs.add_child(tab)
		_page_tabs.append(tab)
	var tray := PanelContainer.new()
	var tray_box := StyleBoxFlat.new()
	tray_box.bg_color = Color("05080e")
	tray_box.border_color = Color("3a3122")
	tray_box.set_border_width_all(1)
	tray_box.corner_radius_bottom_left = 4
	tray_box.corner_radius_bottom_right = 4
	tray_box.set_content_margin_all(6)
	tray.add_theme_stylebox_override("panel", tray_box)
	satchel.add_child(tray)
	item_container = GridContainer.new()
	item_container.name = "ItemGrid"
	item_container.columns = COLUMNS
	item_container.add_theme_constant_override("h_separation", int(CELL_GAP))
	item_container.add_theme_constant_override("v_separation", int(CELL_GAP))
	item_container.size_flags_horizontal = Control.SIZE_SHRINK_CENTER
	tray.add_child(item_container)
	# Footer: the merchant toggle and the purse.
	var footer := HBoxContainer.new()
	_footer = footer
	footer.add_theme_constant_override("separation", 6)
	_window.body.add_child(footer)
	_merchant_button = Button.new()
	_merchant_button.text = tr("Merchant")
	_merchant_button.toggle_mode = true
	_merchant_button.focus_mode = Control.FOCUS_NONE
	_merchant_button.tooltip_text = tr("Open the merchant to sell items")
	_merchant_button.toggled.connect(func(on: bool): _set_merchant_open(on))
	footer.add_child(_merchant_button)
	var spacer := Control.new()
	spacer.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	footer.add_child(spacer)
	footer.add_child(_coin_icon(18))
	galleons_label = UITheme.body("0", UITheme.FS_LABEL, UITheme.c("gold_hi"))
	galleons_label.tooltip_text = tr("Oril")
	galleons_label.mouse_filter = Control.MOUSE_FILTER_PASS
	footer.add_child(galleons_label)
	footer.add_child(UITheme.body(tr("Oril"), UITheme.FS_SMALL, UITheme.c("gold_lt")))

## The merchant (sell only): who he is, the counter the item to sell lies on
## (its name in its rarity colour, the price per piece and the total, a
## warning for upgraded, enchanted or epic+ pieces), Sell / Cancel, and what
## was sold this session.
func _build_merchant() -> void:
	_merchant = _make_window(tr("Merchant"), "currency_galleons", Vector2(MERCHANT_W, 420))
	_merchant.name = "Merchant"
	_merchant.closed.connect(func():
		_merchant_button.set_pressed_no_signal(false)
		_clear_offer())
	_merchant.hide()
	var body := _merchant.body
	body.add_theme_constant_override("separation", 10)
	var who := HBoxContainer.new()
	who.add_theme_constant_override("separation", 10)
	body.add_child(who)
	var badge := PanelContainer.new()
	badge.custom_minimum_size = Vector2(40, 40)
	var badge_box := StyleBoxFlat.new()
	badge_box.bg_color = Color("1e1608")
	badge_box.border_color = UITheme.c("gold_dk")
	badge_box.set_border_width_all(1)
	badge_box.set_corner_radius_all(20)
	badge_box.set_content_margin_all(7)
	badge.add_theme_stylebox_override("panel", badge_box)
	badge.add_child(_coin_icon(26))
	who.add_child(badge)
	var names := VBoxContainer.new()
	names.add_theme_constant_override("separation", 0)
	names.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	who.add_child(names)
	names.add_child(UITheme.body(tr("Travelling Merchant"), UITheme.FS_BODY, UITheme.c("gold_hi")))
	names.add_child(UITheme.body(tr("Turns your items into Oril"), UITheme.FS_SMALL, UITheme.c("text_dim")))

	# The counter: the item being priced, or the hint while it is empty.
	var zone := PanelContainer.new()
	var zone_box := StyleBoxFlat.new()
	zone_box.bg_color = Color("070b12")
	zone_box.border_color = Color("3a3122")
	zone_box.set_border_width_all(1)
	zone_box.set_corner_radius_all(6)
	zone_box.set_content_margin_all(12)
	zone.add_theme_stylebox_override("panel", zone_box)
	zone.custom_minimum_size = Vector2(0, 168)
	zone.set_drag_forwarding(Callable(), _merchant_can_drop, _merchant_drop)
	body.add_child(zone)
	# Both views sit in the counter itself, so it grows with the taller one shown.
	_offer_empty = VBoxContainer.new()
	_offer_empty.alignment = BoxContainer.ALIGNMENT_CENTER
	_offer_empty.add_theme_constant_override("separation", 10)
	_offer_empty.mouse_filter = Control.MOUSE_FILTER_IGNORE
	zone.add_child(_offer_empty)
	var hint_icon := _coin_icon(42)
	hint_icon.modulate.a = 0.45
	hint_icon.size_flags_horizontal = Control.SIZE_SHRINK_CENTER
	_offer_empty.add_child(hint_icon)
	var hint := UITheme.body(tr("Drag the item you want to sell here, or right-click it in your bag."), UITheme.FS_SMALL, UITheme.c("text_dim"))
	hint.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	hint.custom_minimum_size.x = MERCHANT_TEXT_W
	hint.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_offer_empty.add_child(hint)
	var worn := UITheme.body(tr("Worn items cannot be sold."), UITheme.FS_TINY, Color(0.435, 0.424, 0.4))
	worn.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_offer_empty.add_child(worn)
	_offer_box = VBoxContainer.new()
	_offer_box.add_theme_constant_override("separation", 8)
	_offer_box.mouse_filter = Control.MOUSE_FILTER_IGNORE
	zone.add_child(_offer_box)
	var item_row := HBoxContainer.new()
	item_row.add_theme_constant_override("separation", 12)
	_offer_box.add_child(item_row)
	_offer_slot = UISlot.new(Vector2(58, 58))
	_offer_slot.ready.connect(func():
		_offer_slot.theme_type_variation = &"ArcaneSlot"
		_offer_slot.mouse_filter = Control.MOUSE_FILTER_IGNORE)
	item_row.add_child(_offer_slot)
	var item_words := VBoxContainer.new()
	item_words.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	item_words.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	item_words.add_theme_constant_override("separation", 2)
	item_row.add_child(item_words)
	_offer_name = UITheme.body("", UITheme.FS_BODY, UITheme.c("gold_hi"))
	_offer_name.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_offer_name.custom_minimum_size.x = MERCHANT_TEXT_W - 70.0
	item_words.add_child(_offer_name)
	_offer_meta = UITheme.body("", UITheme.FS_SMALL, UITheme.c("text_dim"))
	item_words.add_child(_offer_meta)
	_offer_warn = PanelContainer.new()
	var warn_box := StyleBoxFlat.new()
	warn_box.bg_color = Color(0.63, 0.39, 0.08, 0.14)
	warn_box.border_color = Color(0.91, 0.67, 0.31, 0.35)
	warn_box.set_border_width_all(1)
	warn_box.set_corner_radius_all(4)
	warn_box.set_content_margin_all(6)
	_offer_warn.add_theme_stylebox_override("panel", warn_box)
	_offer_box.add_child(_offer_warn)
	_offer_warn_text = UITheme.body("", UITheme.FS_SMALL, Color(1.0, 0.81, 0.54))
	_offer_warn_text.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_offer_warn_text.custom_minimum_size.x = MERCHANT_TEXT_W - 14.0
	_offer_warn.add_child(_offer_warn_text)
	var push := Control.new()
	push.size_flags_vertical = Control.SIZE_EXPAND_FILL
	push.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_offer_box.add_child(push)
	var rule := ColorRect.new()
	rule.color = Color(UITheme.c("gold"), 0.2)
	rule.custom_minimum_size = Vector2(0, 1)
	_offer_box.add_child(rule)
	_offer_each = HBoxContainer.new()
	_offer_box.add_child(_offer_each)
	var each_caption := UITheme.body(tr("Each"), UITheme.FS_SMALL, UITheme.c("text_dim"))
	each_caption.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_offer_each.add_child(each_caption)
	_offer_each_text = UITheme.body("", UITheme.FS_SMALL, UITheme.c("text"))
	_offer_each.add_child(_offer_each_text)
	var total := HBoxContainer.new()
	total.add_theme_constant_override("separation", 7)
	_offer_box.add_child(total)
	var total_caption := HudKit.label(I18n.upper(tr("Total")), 12, UITheme.c("gold_lt"), HudKit.title(), 0)
	total_caption.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	total_caption.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	total.add_child(total_caption)
	var coin := _coin_icon(18)
	coin.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	total.add_child(coin)
	_offer_price = UITheme.body("", 22, UITheme.c("gold_hi"))
	total.add_child(_offer_price)

	var buttons := HBoxContainer.new()
	buttons.add_theme_constant_override("separation", 8)
	body.add_child(buttons)
	_sell_button = HudKit.gold_button(I18n.upper(tr("Sell")), 40.0, 16)
	_sell_button.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_sell_button.size_flags_stretch_ratio = 2.0
	_sell_button.pressed.connect(_sell_offer)
	buttons.add_child(_sell_button)
	_cancel_button = Button.new()
	_cancel_button.text = tr("Cancel")
	_cancel_button.focus_mode = Control.FOCUS_NONE
	_cancel_button.custom_minimum_size = Vector2(0, 40)
	_cancel_button.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_cancel_button.pressed.connect(_clear_offer)
	buttons.add_child(_cancel_button)

	# What was sold this session (this client only).
	var log_head := HBoxContainer.new()
	log_head.add_theme_constant_override("separation", 5)
	body.add_child(log_head)
	var log_caption := HudKit.label(I18n.upper(tr("Sold this session")), 11, UITheme.c("gold_lt"), HudKit.title(), 0)
	log_caption.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	log_head.add_child(log_caption)
	log_head.add_child(_coin_icon(14))
	_sales_total = UITheme.body("0", UITheme.FS_SMALL, UITheme.c("gold_hi"))
	log_head.add_child(_sales_total)
	_sales_rows = VBoxContainer.new()
	_sales_rows.add_theme_constant_override("separation", 2)
	body.add_child(_sales_rows)
	_clear_offer()
	_refresh_sales()

## The session's sales: the total, then the newest few.
func _refresh_sales() -> void:
	if _sales_rows == null: return
	for child in _sales_rows.get_children():
		_sales_rows.remove_child(child)
		child.queue_free()
	var sum := 0
	for sale in _sales:
		sum += int(sale[2])
	_sales_total.text = galleon_text(sum)
	if _sales.is_empty():
		_sales_rows.add_child(UITheme.body(tr("Nothing sold yet."), UITheme.FS_SMALL, Color(0.435, 0.424, 0.4)))
		return
	for i in range(_sales.size() - 1, maxi(-1, _sales.size() - 1 - SALES_SHOWN), -1):
		var sale: Array = _sales[i]
		var row := HBoxContainer.new()
		row.add_theme_constant_override("separation", 8)
		row.custom_minimum_size = Vector2(0, 24)
		var icon := TextureRect.new()
		icon.texture = UITheme.icon_for(String(sale[0]))
		icon.custom_minimum_size = Vector2(20, 20)
		icon.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
		icon.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
		icon.size_flags_vertical = Control.SIZE_SHRINK_CENTER
		row.add_child(icon)
		var caption := UITheme.body(String(sale[1]), UITheme.FS_SMALL, UITheme.c("text_dim"))
		caption.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		caption.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
		caption.custom_minimum_size.x = 60
		row.add_child(caption)
		row.add_child(UITheme.body("+" + galleon_text(int(sale[2])), UITheme.FS_SMALL, UITheme.c("gold_lt")))
		_sales_rows.add_child(row)

func _coin_icon(px: int) -> TextureRect:
	var coin := TextureRect.new()
	coin.texture = UITheme.icon_for("currency_galleons")
	coin.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	coin.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
	coin.custom_minimum_size = Vector2(px, px)
	coin.mouse_filter = Control.MOUSE_FILTER_IGNORE
	return coin

## 22874 -> "22,874"
static func galleon_text(amount: int) -> String:
	var digits := str(absi(amount))
	var out := ""
	while digits.length() > 3:
		out = "," + digits.substr(digits.length() - 3) + out
		digits = digits.substr(0, digits.length() - 3)
	return ("-" if amount < 0 else "") + digits + out

## The flat cell look of the bag and the doll (no frame art): a dark well with a
## thin border, gold on hover; the icon fills it edge to edge. A doll slot also
## gets the faint outline of the kind of piece it takes, shown while empty.
func _style_cell(slot: UISlot, doll: bool, ghost_id: String = "") -> void:
	var looks := {"normal": Color("5a4a2c") if doll else Color("2a2a2a"), "hover": HudKit.GOLD_LT,
			"pressed": HudKit.GOLD, "disabled": Color("2a2a2a"), "focus": Color(0, 0, 0, 0)}
	for state in looks:
		var box := StyleBoxFlat.new()
		box.bg_color = Color("0b111c") if state != "focus" else Color(0, 0, 0, 0)
		box.border_color = looks[state]
		box.set_border_width_all(1)
		box.set_corner_radius_all(4 if doll else 3)
		slot.add_theme_stylebox_override(state, box)
	var inset := slot.get_child(0) as ColorRect
	if inset != null:
		inset.color = Color("0e1626")
		for side in ["offset_left", "offset_top"]:
			inset.set(side, 2.0)
		for side in ["offset_right", "offset_bottom"]:
			inset.set(side, -2.0)
	if slot._icon != null:
		slot._icon.offset_left = 3
		slot._icon.offset_top = 3
		slot._icon.offset_right = -3
		slot._icon.offset_bottom = -3
	if ghost_id != "":
		var ghost := TextureRect.new()
		ghost.name = "Ghost"
		ghost.texture = UITheme.icon_for(ghost_id)
		ghost.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
		ghost.offset_left = 7
		ghost.offset_top = 7
		ghost.offset_right = -7
		ghost.offset_bottom = -7
		ghost.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
		ghost.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
		ghost.mouse_filter = Control.MOUSE_FILTER_IGNORE
		ghost.material = _ghost_material()
		slot.add_child(ghost)
		slot.move_child(ghost, 1)
		ghost.visible = slot.item_id == ""

static var _ghost_mat: ShaderMaterial

## Grey and faint: the outline of the piece an empty doll slot takes.
static func _ghost_material() -> ShaderMaterial:
	if _ghost_mat == null:
		var shader := Shader.new()
		shader.code = "shader_type canvas_item;\nvoid fragment() {\n\tvec4 c = texture(TEXTURE, UV);\n\tfloat g = dot(c.rgb, vec3(0.3, 0.59, 0.11)) * 1.6;\n\tCOLOR = vec4(vec3(g), c.a * 0.24);\n}\n"
		_ghost_mat = ShaderMaterial.new()
		_ghost_mat.shader = shader
	return _ghost_mat

func _make_slot(minimum: Vector2) -> UISlot:
	var slot := UISlot.new(minimum)
	slot.equipment_interaction = true
	slot.activated.connect(_activate)
	slot.pressed.connect(func(): _select(slot))
	slot.slot_entered.connect(_on_slot_entered)
	slot.slot_exited.connect(_on_slot_exited)
	slot.dropped.connect(_drop)
	slot.drop_check = _can_drop
	slot.ready.connect(func(): slot.theme_type_variation = &"ArcaneSlot")
	return slot

func open_for_player(value: Node3D) -> void:
	prepare(value)
	show()
	_window.open()
	_layout()

## Bind the bag to `value` and fill it without showing it. The world loader
## calls this behind the loading screen: the first opening used to build the
## cells and load every item icon from disk on that frame (~130 ms).
func prepare(value: Node3D) -> void:
	if player != value and is_instance_valid(player):
		if player.inventory_changed.is_connected(_on_inventory_changed): player.inventory_changed.disconnect(_on_inventory_changed)
		if player.equipment_answer.is_connected(_answer): player.equipment_answer.disconnect(_answer)
	player = value
	if not player.inventory_changed.is_connected(_on_inventory_changed): player.inventory_changed.connect(_on_inventory_changed)
	if not player.equipment_answer.is_connected(_answer): player.equipment_answer.connect(_answer)
	refresh()

func refresh() -> void:
	if not is_instance_valid(player): return
	galleons_label.text = galleon_text(int(player.galleons))
	for slot in _doll_slots:
		var entry: Dictionary = player.equipment.get(slot.equipment_slot, {})
		slot.set_item(String(entry.get("id", "")), entry)
		slot.selected = _selection_key(slot) == _selected_key
		slot.disabled = _pending
		var ghost := slot.get_node_or_null("Ghost") as CanvasItem
		if ghost != null:
			ghost.visible = entry.is_empty()
		(_doll_labels[slot.equipment_slot] as Label).visible = entry.is_empty()
	_bag_slots.clear()
	var cells := _arrange_bag()
	_page = clampi(_page, 0, pages_open() - 1)
	for tab in _page_tabs:
		(tab as PageTab).refresh(cells)
	var first := _page * PAGE_CELLS
	var count := maxi(0, mini(first + PAGE_CELLS, cells.size()) - first)
	while _bag_pool.size() < count:
		var made := _make_slot(Vector2(_bag_px, _bag_px))
		made.ready.connect(func(): _style_cell(made, false))
		_bag_pool.append(made)
		item_container.add_child(made)
	for i in range(_bag_pool.size()):
		var slot: UISlot = _bag_pool[i]
		slot.visible = i < count
		slot.selected = false
		slot.disabled = false
		slot.modulate = Color.WHITE
		if i >= count:
			slot.set_item("", {})
			continue
		slot.set_meta("cell", first + i)
		var entry: Dictionary = cells[first + i]
		slot.set_item(String(entry.get("id", "")), entry)
		if not entry.is_empty():
			slot.selected = _selection_key(slot) == _selected_key
			slot.disabled = _pending or _locked(entry)
			if _locked(entry): slot.modulate = Color(1, 1, 1, 0.35)   # on Ollivander's anvil
			_bag_slots.append(slot)
	# The staged sale may have left the bag (sold, equipped, consumed).
	if not _sell_entry.is_empty() and _bag_entry(_sell_entry).is_empty():
		_clear_offer()
	_sell_button.disabled = _pending or _sell_entry.is_empty()
	# The cells are reused, so the slot under the cursor may hold another item
	# now (a right-click swapped the worn wand into it): its tooltip follows.
	if _tooltip != null and _tooltip.visible and is_instance_valid(_hover_slot):
		if _hover_slot.visible and _hover_slot.item_id != "":
			_on_slot_entered(_hover_slot)
		else:
			_tooltip.hide_item()

func _on_inventory_changed() -> void:
	if visible: refresh()

## A bag entry's identity across answers: its instance uid, or id and tier for
## a stack (the n-th such stack when there are several).
func _item_key(entry: Dictionary, seen: Dictionary) -> String:
	var uid := int(entry.get("uid", 0))
	if uid > 0:
		return "u%d" % uid
	var key := "s%s:%d" % [String(entry.get("id", "")), int(entry.get("tier", 0))]
	var n := int(seen.get(key, 0))
	seen[key] = n + 1
	return key if n == 0 else "%s#%d" % [key, n]

## The bag as cells: remembered items keep their cell, newcomers take the hint
## cell (a swap, a drop target) or the first free one.
func _arrange_bag() -> Array:
	_load_layout()
	var total := maxi(PAGE_CELLS * pages_open(), player.inventory.size())
	var cells: Array = []
	_cell_keys.clear()
	for _i in range(total):
		cells.append({})
		_cell_keys.append("")
	var present := {}
	var seen := {}
	var newcomers: Array = []
	for entry in player.inventory:
		if int(entry.get("amount", 0)) <= 0: continue
		var key := _item_key(entry, seen)
		present[key] = true
		var at := int(_cells.get(key, -1))
		if at >= 0 and at < total and _cell_keys[at] == "":
			cells[at] = entry
			_cell_keys[at] = key
		else:
			newcomers.append([key, entry])
	var changed := false
	for pair in newcomers:
		var at := _cell_keys.find("")
		if _cell_hint >= 0 and _cell_hint < total and _cell_keys[_cell_hint] == "":
			at = _cell_hint
		_cell_hint = -1
		cells[at] = pair[1]
		_cell_keys[at] = pair[0]
		_cells[pair[0]] = at
		changed = true
	for key in _cells.keys():
		if not present.has(key):
			_cells.erase(key)
			changed = true
	if changed:
		_save_layout()
	return cells

func _layout_owner_name() -> String:
	return String(player.get("player_name")) if is_instance_valid(player) else ""

func _load_layout() -> void:
	var owner := _layout_owner_name()
	if owner == _layout_owner:
		return
	_layout_owner = owner
	_cells = {}
	var mine = _read_layouts().get(owner, {})
	if mine is Dictionary:
		for key in mine:
			_cells[String(key)] = int(mine[key])

func _read_layouts() -> Dictionary:
	if not FileAccess.file_exists(LAYOUT_PATH):
		return {}
	var file := FileAccess.open(LAYOUT_PATH, FileAccess.READ)
	if file == null:
		return {}
	var data = JSON.parse_string(file.get_as_text())
	return data if data is Dictionary else {}

func _save_layout() -> void:
	if _layout_owner == "":
		return
	var all := _read_layouts()
	all[_layout_owner] = _cells
	var file := FileAccess.open(LAYOUT_PATH, FileAccess.WRITE)
	if file != null:
		file.store_string(JSON.stringify(all))

## Satchel pages the server's bag size opens (the rest of the PAGES show locked).
func pages_open() -> int:
	return clampi(ceili(float(HPEquipment.BAG_SLOTS) / PAGE_CELLS), 1, PAGES)

func show_page(page: int) -> void:
	if page == _page or page < 0 or page >= pages_open():
		return
	_page = page
	refresh()

## An item dropped on a page tab: into that page's first free cell (a worn
## piece taken off lands there too).
func drop_on_page(page: int, payload: Dictionary) -> void:
	if _pending or _locked(payload) or page >= pages_open():
		return
	var free := -1
	for cell in range(page * PAGE_CELLS, mini((page + 1) * PAGE_CELLS, _cell_keys.size())):
		if String(_cell_keys[cell]) == "":
			free = cell
			break
	if free < 0:
		return
	if String(payload.get("source_slot", "")) != "":
		_cell_hint = free
		_request("unequip", payload.source_slot)
	else:
		_move_cell(int(payload.get("cell", -1)), free)

## Drag inside the bag: the item moves to that cell (trading places with
## whatever sits there).
func _move_cell(from: int, to: int) -> void:
	if from < 0 or to < 0 or from >= _cell_keys.size() or to >= _cell_keys.size() or from == to:
		return
	var moving := String(_cell_keys[from])
	if moving == "":
		return
	var other := String(_cell_keys[to])
	_cells[moving] = to
	if other != "":
		_cells[other] = from
	_save_layout()
	refresh()

func _select(slot: UISlot) -> void:
	if slot.item_id == "": return
	_selected_key = _selection_key(slot)
	for other in _doll_slots + _bag_slots: other.selected = _selection_key(other) == _selected_key

func _selection_key(slot: UISlot) -> String:
	return "%s:%s:%d:%d" % [slot.equipment_slot, slot.item_id, int(slot.entry.get("tier", 0)), int(slot.entry.get("uid", 0))]

## What changes if the item is worn - only the stats that actually move.
func _comparison(slot: UISlot, destination_override := "") -> String:
	var destinations: Array = HPEquipment.item(slot.item_id).get("slots", [])
	if destinations.is_empty(): return ""
	var destination: String = slot.equipment_slot if slot.equipment_slot != "" else destinations[0]
	if slot.equipment_slot == "" and "ring_left" in destinations and player.equipment.has("ring_left") and not player.equipment.has("ring_right"): destination = "ring_right"
	if destination_override != "": destination = destination_override
	var gear: Dictionary = player.equipment.duplicate(true)
	if slot.equipment_slot == "": gear[destination] = slot.entry
	else: gear.erase(destination)
	var before := HPEquipment.stats(player.base_max_hp, player.base_max_mana, player.equipment)
	var after := HPEquipment.stats(player.base_max_hp, player.base_max_mana, gear)
	var parts: Array = []
	var magic := _mid_attack(after, "magic_attack") - _mid_attack(before, "magic_attack")
	if absf(magic) >= 0.5: parts.append(tr("Magic Attack %+.0f") % magic)
	var spell := float(after.spell_power) - float(before.spell_power)
	if absf(spell) >= 0.5: parts.append(tr("Spell Power %+.0f%%") % spell)
	if after.max_hp != before.max_hp: parts.append(tr("Health %+d") % (after.max_hp - before.max_hp))
	if after.max_mana != before.max_mana: parts.append(tr("Mana %+d") % (after.max_mana - before.max_mana))
	if int(after.armor) != int(before.armor): parts.append(tr("Armour %+d") % (int(after.armor) - int(before.armor)))
	if not is_equal_approx(after.move_speed, before.move_speed): parts.append(tr("Move %+.0f%%") % (after.move_speed - before.move_speed))
	if not is_equal_approx(after.mount_speed, before.mount_speed): parts.append(tr("Speed %+.0f") % (after.mount_speed - before.mount_speed))
	if parts.is_empty(): return ""
	return "%s: %s" % [tr(String(SLOT_LABELS[destination])), " · ".join(parts)]

## The middle of a wand range at its worn +N (derived stats keep the +0 range).
static func _mid_attack(stats: Dictionary, key: String) -> float:
	var span: Array = stats.get(key, [0, 0])
	return (float(span[0]) + float(span[1])) * 0.5 * HPRules.wand_multiplier(int(stats.get("wand_tier", 0)))

func _on_slot_entered(slot: UISlot) -> void:
	_hover_slot = slot
	if slot.item_id == "" or _tooltip == null: return
	_tooltip.show_item(slot.item_id, slot.entry)
	if slot != _offer_slot and is_instance_valid(player):
		if _merchant.visible and slot.equipment_slot == "":
			var price := _price_of(slot.entry)
			if price > 0: _tooltip._add_lore(tr("Sells for %s Oril") % galleon_text(price))
	_tooltip.follow_cursor()

func _on_slot_exited(slot: UISlot) -> void:
	if _hover_slot == slot: _hover_slot = null
	_tooltip.hide_item()

func _activate(slot: UISlot) -> void:
	if _pending or slot.item_id == "": return
	if _locked(slot.entry): return
	if slot.equipment_slot != "":
		_request("unequip", slot.equipment_slot)
		return
	# With Ollivander open, right-click puts the item on his anvil.
	var workshop := _workshop()
	if workshop != null and workshop.visible and workshop._accepts(slot.entry.merged({"id": slot.item_id})):
		workshop.set_target(int(slot.entry.get("uid", 0)))
		return
	# With the merchant open, right-click prices the item instead of using it.
	if _merchant.visible:
		_offer(slot.entry)
		return
	var item_data := HPEquipment.item(slot.item_id)
	# An Old Boot is a Portkey: choose where it goes, the authority sets it down.
	if slot.item_id == String(HPMaps.portkey_rules().get("item", "portkey_boot")):
		var hud = get_parent().get_node_or_null("HUD") if get_parent() != null else null
		if hud != null and hud.get("portkey") != null:
			hud.portkey.open_for(player)
		return
	if item_data.get("type") == "consumable" or slot.item_id in ["potion_health", "potion_mana"]:
		_on_item_clicked(slot.entry)
		return
	var targets: Array = item_data.get("slots", [])
	if targets.is_empty(): return
	# The piece this one replaces comes back into the cell it leaves.
	_cell_hint = int(slot.get_meta("cell", -1))
	if "ring_left" in targets:
		for target in targets:
			if not player.equipment.has(target):
				_request("equip", target, slot.entry)
				return
		_ring_entry = slot.entry.duplicate(true)
		for index in 2:
			var destination: String = ["ring_left","ring_right"][index]
			var worn: Dictionary = player.equipment[destination]
			_ring_menu.set_item_text(index, tr("%s: replace %s") % [tr(String(SLOT_LABELS[destination])), I18n.t(String(HPEquipment.item(worn.id).get("name",worn.id)))])
			_ring_menu.set_item_tooltip(index, _comparison(slot,destination))
		_ring_menu.position = DisplayServer.mouse_get_position()
		_ring_menu.popup()
	else: _request("equip", targets[0], slot.entry)

## A bag item on Ollivander's anvil stays put until it leaves the anvil.
func _locked(entry: Dictionary) -> bool:
	var workshop := _workshop()
	return workshop != null and workshop.has_method("holds") and workshop.holds(int(entry.get("uid", 0)))

func _can_drop(destination: UISlot, payload: Dictionary) -> bool:
	if _pending or _locked(payload): return false
	if destination.equipment_slot == "":
		if payload.get("source_slot", "") != "": return true   # take it off, into this cell
		var from := int(payload.get("cell", -1))
		return from >= 0 and from != int(destination.get_meta("cell", -1))
	return payload.get("source_slot", "") == "" and HPEquipment.fits(payload.id, destination.equipment_slot)

func _drop(destination: UISlot, payload: Dictionary) -> void:
	if not _can_drop(destination, payload): return
	var cell := int(destination.get_meta("cell", -1))
	if destination.equipment_slot == "":
		if payload.get("source_slot", "") == "":
			_move_cell(int(payload.get("cell", -1)), cell)
			return
		if cell >= 0 and cell < _cell_keys.size() and String(_cell_keys[cell]) == "":
			_cell_hint = cell
		_request("unequip", payload.source_slot)
	else:
		_cell_hint = int(payload.get("cell", -1))
		_request("equip", destination.equipment_slot, payload)

# ------------------------------------------------------------------ merchant

func _workshop() -> Control:
	return get_parent().get_node_or_null("OllivanderUI") as Control if get_parent() != null else null

func _set_merchant_open(on: bool) -> void:
	_merchant_button.set_pressed_no_signal(on)
	if on:
		var workshop := _workshop()
		if workshop != null: workshop.hide()
		_merchant.open()
		_place_merchant()
	else:
		_merchant.hide()
		_clear_offer()

## The bag entry a payload / staged entry names (by uid, else id + tier).
func _bag_entry(entry: Dictionary) -> Dictionary:
	if not is_instance_valid(player): return {}
	var uid := int(entry.get("uid", 0))
	for held in player.inventory:
		if int(held.get("amount", 0)) <= 0: continue
		if uid > 0 and int(held.get("uid", 0)) == uid: return held
		if uid == 0 and String(held.id) == String(entry.get("id", "")) and int(held.get("tier", 0)) == int(entry.get("tier", 0)) and int(held.get("uid", 0)) == 0: return held
	return {}

## What the merchant pays for this bag entry (a stack sells whole).
func _price_of(entry: Dictionary) -> int:
	var each := HPEquipment.sell_price(String(entry.get("id", "")), int(entry.get("tier", 0)))
	return each * (1 if int(entry.get("uid", 0)) > 0 else maxi(1, int(entry.get("amount", 1))))

func _merchant_can_drop(_at: Vector2, payload: Variant) -> bool:
	return not _pending and payload is Dictionary and payload.get("arcane_item", false) and String(payload.get("source_slot", "")) == "" \
		and not _locked(payload)

func _merchant_drop(_at: Vector2, payload: Variant) -> void:
	if _merchant_can_drop(_at, payload): _offer(payload)

func _offer(entry: Dictionary) -> void:
	var held := _bag_entry(entry)
	if held.is_empty(): return
	var price := _price_of(held)
	if price <= 0:
		_notify(tr(REASONS["not_sellable"]), "warn")
		return
	_sell_entry = held.duplicate(true)
	var id := String(held.id)
	var data := HPEquipment.item(id)
	var tier := int(held.get("tier", 0))
	var amount := int(held.get("amount", 1))
	var bonuses := (held.get("bonuses", []) as Array).size()
	_offer_slot.set_item(id, held)
	_offer_name.text = ("+%d " % tier if tier > 0 else "") + I18n.t(String(data.get("name", id)))
	_offer_name.add_theme_color_override("font_color", ItemTooltip.RARITY_COLOUR.get(ItemTooltip.rarity_of(id), UITheme.c("gold_hi")))
	var kind := String(data.get("type", ""))
	_offer_meta.text = "%s  ·  %s" % [tr(String(ItemTooltip.KIND_LABEL.get(kind, kind.capitalize()))), ItemTooltip.rarity_label(id)]
	# Selling cannot be undone: say so for the pieces worth keeping.
	var worth: Array = []
	if tier > 0: worth.append("+%d" % tier)
	if bonuses > 0: worth.append(tr("%d enchantments") % bonuses)
	if not worth.is_empty():
		_offer_warn_text.text = tr("This item is %s. It cannot be bought back once sold.") % ", ".join(worth)
	elif ItemTooltip.rarity_of(id) in ["epic", "legendary"]:
		_offer_warn_text.text = tr("A %s item. It cannot be bought back once sold.") % ItemTooltip.rarity_label(id)
	_offer_warn.visible = not worth.is_empty() or ItemTooltip.rarity_of(id) in ["epic", "legendary"]
	_offer_each.visible = int(held.get("uid", 0)) <= 0 and amount > 1
	_offer_each_text.text = tr("%s Oril × %d") % [galleon_text(HPEquipment.sell_price(id, tier)), amount]
	_offer_price.text = galleon_text(price)
	_offer_box.visible = true
	_offer_empty.visible = false
	_sell_button.disabled = _pending
	_cancel_button.disabled = false
	_place_merchant()

func _clear_offer() -> void:
	_sell_entry = {}
	if _offer_slot == null: return
	_offer_slot.set_item("", {})
	_offer_box.visible = false
	_offer_empty.visible = true
	_sell_button.disabled = true
	_cancel_button.disabled = true

func _sell_offer() -> void:
	if _sell_entry.is_empty() or not is_instance_valid(player) or player.is_dead: return
	_sold_price = _price_of(_sell_entry)
	var amount := int(_sell_entry.get("amount", 1))
	var name := I18n.t(String(HPEquipment.item(_sell_entry.id).get("name", _sell_entry.id)))
	_sold_entry = [String(_sell_entry.id), name if amount <= 1 else "%s ×%d" % [name, amount], _sold_price]
	_request("sell", "", _sell_entry)

# ------------------------------------------------------------------ destroy

func _build_destroy_confirm() -> void:
	_destroy_window = _make_window(tr("Destroy Item"), "ui_inventory", Vector2(340, 190))
	_destroy_window.name = "DestroyConfirm"
	_destroy_window.closed.connect(func(): _destroy_entry = {})
	_destroy_window.hide()
	_destroy_text = UITheme.body("", UITheme.FS_BODY, UITheme.c("parchment"))
	_destroy_text.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_destroy_text.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_destroy_text.size_flags_vertical = Control.SIZE_EXPAND_FILL
	_destroy_window.body.add_child(_destroy_text)
	var buttons := HBoxContainer.new()
	buttons.add_theme_constant_override("separation", 8)
	_destroy_window.body.add_child(buttons)
	for spec in [[tr("Yes"), _confirm_destroy], [tr("No"), func(): _destroy_window.close()]]:
		var b := Button.new()
		b.text = spec[0]
		b.focus_mode = Control.FOCUS_NONE
		b.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		b.pressed.connect(spec[1])
		buttons.add_child(b)

## Delete: the selected bag item (else the one under the cursor) - anything in
## the bag, gear included; what is worn is never in the bag, so it cannot be
## destroyed. An item on Ollivander's anvil stays.
func _unhandled_key_input(event: InputEvent) -> void:
	if not visible or not (event is InputEventKey) or not event.pressed or event.echo:
		return
	if _destroy_window.visible:
		if event.keycode in [KEY_ENTER, KEY_KP_ENTER, KEY_Y]:
			_confirm_destroy()
			get_viewport().set_input_as_handled()
		elif event.keycode in [KEY_ESCAPE, KEY_N]:
			_destroy_window.close()
			get_viewport().set_input_as_handled()
		return
	if event.keycode != KEY_DELETE:
		return
	var slot: UISlot = null
	for candidate in _bag_slots:
		if candidate.item_id != "" and _selection_key(candidate) == _selected_key:
			slot = candidate
	if slot == null and _hover_slot != null and is_instance_valid(_hover_slot) and _hover_slot in _bag_slots:
		slot = _hover_slot
	get_viewport().set_input_as_handled()
	if slot == null or slot.item_id == "":
		_notify(tr("Select an item in your bag first."), "warn")
		return
	if _pending or _locked(slot.entry):
		return
	_ask_destroy(slot.entry.merged({"id": slot.item_id}))

func _ask_destroy(entry: Dictionary) -> void:
	_destroy_entry = entry.duplicate(true)
	var name := I18n.t(String(HPEquipment.item(String(entry.get("id", ""))).get("name", entry.get("id", ""))))
	var tier := int(entry.get("tier", 0))
	if tier > 0:
		name += " +%d" % tier
	var amount := int(entry.get("amount", 1))
	if amount > 1:
		name += " x%d" % amount
	_destroy_text.text = tr("Destroy %s?\nIt is gone for good.") % name
	var canvas := get_viewport().get_visible_rect().size
	ArcaneSkin.place(_destroy_window, ((canvas - Vector2(340, 190)) * 0.5).floor(), Vector2(340, 190))
	_destroy_window.open()

func _confirm_destroy() -> void:
	if _destroy_entry.is_empty() or not is_instance_valid(player):
		_destroy_window.close()
		return
	var entry := _destroy_entry
	_destroy_window.close()
	if _bag_entry(entry).is_empty():
		return
	_selected_key = ""
	_request("destroy", "", entry)

# ------------------------------------------------------------------ requests

func _request(operation: String, slot: String, entry: Dictionary = {}) -> void:
	if _pending: return
	_pending = true
	_last_operation = operation
	_pending_id = SimNet.submit_equipment(player, operation, slot, String(entry.get("id", "")), int(entry.get("tier", 0)), int(entry.get("uid", 0)))
	refresh()

func _answer(answer: Dictionary) -> void:
	if int(answer.get("request_id", -1)) != _pending_id and int(answer.get("request_id", -1)) != -1: return
	_pending = false
	var ok: bool = answer.get("ok", false)
	var reason := String(answer.get("reason", ""))
	if not ok:
		_cell_hint = -1
	if ok and reason == "sold":
		_clear_offer()
		if not _sold_entry.is_empty():
			_sales.append(_sold_entry)
			_sold_entry = []
			_refresh_sales()
			_place_merchant()
		_notify(tr("Sold for %s Oril.") % galleon_text(_sold_price), "good")
	elif ok and reason == "destroyed":
		_notify(tr("Item destroyed."), "info")
	elif not ok:
		_notify(I18n.t(String(REASONS.get(reason, tr("Unable to change equipment.")))), "warn")
	elif String(REASONS.get(reason, "")) != "":
		_notify(I18n.t(String(REASONS[reason])), "good")
	if ok:
		_play_feedback_sound(_last_operation)
	refresh()

## Feedback goes through the HUD's notice band (no status text in the window).
func _notify(text: String, kind: String) -> void:
	if text == "": return
	var hud := get_parent().get_node_or_null("HUD") if get_parent() != null else null
	if hud != null and hud.has_method("show_notice"):
		hud.show_notice(text, kind)

func _play_feedback_sound(op: String) -> void:
	var audio := get_node_or_null("/root/AudioManager")
	if audio == null: return
	match op:
		"equip":
			if audio.has_method("play_equip"): audio.play_equip()
			else: audio.play_sound_at("ui_equip", Vector3.ZERO, null, true)
		"unequip":
			if audio.has_method("play_unequip"): audio.play_unequip()
			else: audio.play_sound_at("ui_unequip", Vector3.ZERO, null, true)
		"consume":
			if audio.has_method("play_potion"): audio.play_potion()
			else: audio.play_sound_at("ui_potion", Vector3.ZERO, null, true)
		"sell":
			audio.play_sound_at("ui_coin", Vector3.ZERO, null, true)

func _on_visibility_changed() -> void:
	if _presentation_layer: _presentation_layer.visible = visible
	if not visible:
		if _tooltip: _tooltip.hide_item()
		if _ring_menu: _ring_menu.hide()
		if _merchant: _set_merchant_open(false)
		if _destroy_window: _destroy_window.close()

func _process(_delta: float) -> void:
	if visible and _tooltip.visible: _tooltip.follow_cursor()
	# Galleons arrive with the stats payload (auto-collected coin, quest pay),
	# not as a bag change, so the footer follows the live number.
	if visible and is_instance_valid(player) and galleons_label != null:
		var text := galleon_text(int(player.galleons))
		if galleons_label.text != text: galleons_label.text = text

## Size the cells to the screen (8 rows must fit), then dock the window on the
## right edge, vertically centred; the merchant sits to its left.
func _layout() -> void:
	if _window == null: return
	var canvas := get_viewport().get_visible_rect().size
	# Everything but the cells, then the cells: the doll scales with the tray
	# width (5 cells + gaps + padding), so it grows with the cell size too.
	var fixed := RIBBON_TOP + 16.0 + 10.0 * 2 + PageTab.HEIGHT + 12.0 + (ROWS - 1) * CELL_GAP + 30.0
	var per_px := ROWS + DOLL_H * COLUMNS / DOLL_W
	var spare := canvas.y - 24.0 - fixed - DOLL_H * ((COLUMNS - 1) * CELL_GAP + 12.0) / DOLL_W
	_bag_px = clampf(floorf(spare / per_px), 32.0, 50.0)
	for slot in item_container.get_children(): (slot as Control).custom_minimum_size = Vector2(_bag_px, _bag_px)
	var tray_w := COLUMNS * _bag_px + (COLUMNS - 1) * CELL_GAP + 12.0
	_layout_doll(tray_w)
	var width := tray_w + 36.0
	width = maxf(width, _footer.get_combined_minimum_size().x + 36.0)
	var height := fixed + _doll.custom_minimum_size.y + ROWS * _bag_px
	height = minf(height, canvas.y - 24.0)
	_window.custom_minimum_size = Vector2(width, height)
	_window.size = Vector2(width, height)
	_window._ribbon.offset_left = -width * 0.5 + 10
	_window._ribbon.offset_right = width * 0.5 - 10
	var x := canvas.x - width - 24.0
	var y := floorf((canvas.y - height) * 0.5)
	_window.offset_left = x
	_window.offset_top = y
	_window.offset_right = x + width
	_window.offset_bottom = y + height
	_place_merchant()

const RIBBON_TOP := UIWindow.RIBBON_H - UIWindow.RIBBON_OVERHANG + 10.0

## Place the silhouette, the doll slots and their captions for a panel `w` wide
## (DOLL_SPOTS at design size, scaled).
func _layout_doll(w: float) -> void:
	var k := w / DOLL_W
	_doll.custom_minimum_size = Vector2(w, DOLL_H * k)
	var fig_h := FIG_H * k
	var fig_w := fig_h * 420.0 / 780.0
	_doll_fig.position = Vector2((w - fig_w) * 0.5, FIG_TOP * k)
	_doll_fig.size = Vector2(fig_w, fig_h)
	var px := DOLL_SLOT * k
	for slot in _doll_slots:
		var spot: Array = DOLL_SPOTS[slot.equipment_slot]
		var x := {"l": 10.0 * k, "c": (w - px) * 0.5, "r": w - px - 10.0 * k}[String(spot[0])] as float
		slot.custom_minimum_size = Vector2(px, px)
		slot.position = Vector2(x, float(spot[1]) * k)
		slot.size = Vector2(px, px)
		var label := _doll_labels[slot.equipment_slot] as Label
		label.position = Vector2(x - 10.0, slot.position.y + px)
		label.size = Vector2(px + 20.0, 13.0)

func _place_merchant() -> void:
	if _merchant == null or _window == null: return
	var h := _merchant.body.get_combined_minimum_size().y + RIBBON_TOP + 16.0
	_merchant.custom_minimum_size = Vector2(MERCHANT_W, h)
	_merchant.size = Vector2(MERCHANT_W, h)
	var x := maxf(8.0, _window.offset_left - MERCHANT_W - 12.0)
	var y := _window.offset_top + 40.0
	_merchant.offset_left = x
	_merchant.offset_top = y
	_merchant.offset_right = x + MERCHANT_W
	_merchant.offset_bottom = y + h
	_merchant._ribbon.offset_left = -MERCHANT_W * 0.5 + 10
	_merchant._ribbon.offset_right = MERCHANT_W * 0.5 - 10

func _on_item_clicked(item_data: Dictionary) -> void:
	if is_instance_valid(player) and not player.is_dead:
		_request("consume", "", item_data)


## The equipment panel's backdrop: a dark well, a faint gold diamond lattice
## and a darker rim.
class DollPanel extends Control:
	func _init() -> void:
		mouse_filter = Control.MOUSE_FILTER_IGNORE
		clip_contents = true

	func _draw() -> void:
		var r := Rect2(Vector2.ZERO, size)
		draw_rect(r, Color("080d17"))
		var lattice := Color(0.75, 0.6, 0.3, 0.05)
		var step := 14.0
		var d := -size.y
		while d < size.x:
			draw_line(Vector2(d, 0), Vector2(d + size.y, size.y), lattice, 1.0)
			draw_line(Vector2(d, size.y), Vector2(d + size.y, 0), lattice, 1.0)
			d += step
		# A soft cool glow behind the figure.
		draw_circle(size * Vector2(0.5, 0.45), size.x * 0.32, Color(0.24, 0.31, 0.47, 0.12))
		draw_rect(r, Color("3a3122"), false, 1.0)


## A satchel page tab (I, II, III): gold while shown, a lock past the open
## pages. Takes a dragged bag item (to that page's first free cell) and turns
## to its page when a drag rests on it.
class PageTab extends Control:
	const HEIGHT := 26.0
	const ROMAN := ["I", "II", "III"]
	const TURN_AFTER := 0.6
	var inventory: Node
	var page := 0
	var _used := 0
	var _hover := false
	var _drag_wait := 0.0

	func _init(p_inventory: Node, p_page: int) -> void:
		inventory = p_inventory
		page = p_page
		custom_minimum_size = Vector2(0, HEIGHT)
		mouse_filter = Control.MOUSE_FILTER_STOP
		mouse_entered.connect(func(): _hover = true; queue_redraw())
		mouse_exited.connect(func(): _hover = false; _drag_wait = 0.0; queue_redraw())

	func open() -> bool:
		return page < inventory.pages_open()

	func refresh(cells: Array) -> void:
		_used = 0
		for cell in range(page * PAGE_CELLS, mini((page + 1) * PAGE_CELLS, cells.size())):
			if not (cells[cell] as Dictionary).is_empty():
				_used += 1
		tooltip_text = (tr("Page %s  ·  %d/%d") % [ROMAN[page], _used, PAGE_CELLS]) if open() else (tr("Page %s  ·  opens soon") % ROMAN[page])
		mouse_default_cursor_shape = Control.CURSOR_POINTING_HAND if open() else Control.CURSOR_ARROW
		queue_redraw()

	func _gui_input(event: InputEvent) -> void:
		if open() and event is InputEventMouseButton and event.pressed and event.button_index == MOUSE_BUTTON_LEFT:
			inventory.show_page(page)
			accept_event()

	func _process(delta: float) -> void:
		if _hover and open() and get_viewport().gui_is_dragging():
			_drag_wait += delta
			if _drag_wait >= TURN_AFTER:
				_drag_wait = -INF   # once per hover
				inventory.show_page(page)

	func _can_drop_data(_at: Vector2, data: Variant) -> bool:
		return open() and data is Dictionary and (data.has("cell") or String(data.get("source_slot", "")) != "")

	func _drop_data(_at: Vector2, data: Variant) -> void:
		inventory.drop_on_page(page, data)

	func _draw() -> void:
		var on: bool = inventory._page == page
		var r := Rect2(Vector2.ZERO, size)
		draw_rect(r, Color("2a1e0b") if on else Color("101826"))
		draw_rect(Rect2(0, 0, size.x, size.y * 0.5), Color(1, 1, 1, 0.03))
		draw_rect(r, Color("3a3122"), false, 1.0)
		var font := HudKit.title()
		var text: String = ROMAN[page]
		var colour := HudKit.GOLD_HI if on else (Color("4a5068") if not open() else (HudKit.PARCHMENT if _hover else HudKit.TEXT_DIM))
		var w := font.get_string_size(text, HORIZONTAL_ALIGNMENT_LEFT, -1, 13).x
		draw_string(font, Vector2((size.x - w) * 0.5, size.y * 0.5 + 5.0), text, HORIZONTAL_ALIGNMENT_LEFT, -1, 13, colour)
		if not open():
			var lock := UITheme.icon_for("ui_lock")
			if lock != null:
				draw_texture_rect(lock, Rect2(size.x - 20.0, 6.0, 13.0, 13.0), false, Color(1, 1, 1, 0.5))
