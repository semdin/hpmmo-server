extends HudWindow
class_name HudCharacterWindow

## The character sheet (C), an MMO character window in three tabs so nothing
## ever scrolls: the header (crest, name, house and rank, the level medallion
## and the experience bar) stays put, and the page below switches between
##   Status      - health and mana gauges, the six core numbers, the purse;
##   Attributes  - the four status-point attributes, what a point gives, the
##                 total so far, and the "+" that spends one (Metin2: two per
##                 level, up to the cap in one attribute);
##   Properties  - the secondary stats in four groups, zeros dimmed.
## Everything is read off the live player (`derived_stats` is
## HPEquipment.stats, the same numbers the authority fights with); "+" only
## asks (SimNet.submit_attribute) and the answer arrives in the stats payload.

const ATTRIBUTES := [["vit", "Vitality"], ["int", "Intellect"], ["str", "Strength"], ["dex", "Agility"]]  # i18n
## [page id, tab caption]
const PAGES := [["status", "Status"], ["attrs", "Attributes"], ["props", "Properties"]]  # i18n
## [group caption, [[key, caption], ...]] for the Properties page.
# i18n-begin
const GROUPS := [
	["Attack", [["attack_speed", "Attack speed"], ["cast_speed", "Casting speed"], ["pierce", "Piercing hit"], ["life_steal", "Life drain"]]],
	["Defence", [["melee_res", "Melee resist"], ["projectile_res", "Projectile resist"], ["spell_res", "Spell resist"], ["block", "Block"], ["reflect", "Reflect"]]],
	["Regeneration", [["hp_regen", "Health regen"], ["mana_regen", "Mana regen"]]],
	["Movement and loot", [["move_speed", "Movement speed"], ["broom", "Broom speed"], ["exp_bonus", "Experience"], ["gold_bonus", "Galleons found"]]],
]
# i18n-end
const PAGE_H := 300.0

const WELL := Color("070b12")
const WELL_EDGE := Color("3a3122")
const FAINT := Color(0.435, 0.424, 0.400)
const ATTACK := Color(0.878, 0.541, 0.235)
const MAGIC := Color(0.655, 0.486, 0.941)
const DEFENCE := Color(0.561, 0.651, 0.769)

var player: Node3D = null
var _crest: TextureRect
var _name: Label
var _house: Label
var _rank: Label
var _medal: LevelMedal
var _exp_text: Label
var _exp_bar: FillBar
var _hp_bar: FillBar
var _mana_bar: FillBar
var _values: Dictionary = {}   # key -> Label
var _tabs: Dictionary = {}     # page id -> TabChip
var _pages: Dictionary = {}    # page id -> Control
var _page := "status"
var _badge: PanelContainer
var _badge_text: Label
var _points: Label
var _points_box: PanelContainer
var _coin_box: StyleBoxFlat
var _attr_cards: Dictionary = {}   # attribute id -> {card, value, total, bar, plus}
var _shown := ""
var _pulse := 0.0

func _init() -> void:
	super._init("Character", Vector2(470, 516))
	name = "CharacterWindow"

func _ready() -> void:
	super._ready()
	body.add_theme_constant_override("separation", 10)
	_build_head()
	_build_tabs()
	var holder := Control.new()
	holder.name = "Pages"
	holder.custom_minimum_size = Vector2(0, PAGE_H)
	holder.mouse_filter = Control.MOUSE_FILTER_IGNORE
	body.add_child(holder)
	for page in PAGES:
		var box := VBoxContainer.new()
		box.name = "Page_" + String(page[0])
		box.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
		box.mouse_filter = Control.MOUSE_FILTER_IGNORE
		holder.add_child(box)
		_pages[String(page[0])] = box
	_build_status(_pages["status"])
	_build_attributes(_pages["attrs"])
	_build_properties(_pages["props"])
	_show_page(_page)

# ------------------------------------------------------------------- header

func _build_head() -> void:
	var head := HBoxContainer.new()
	head.add_theme_constant_override("separation", 12)
	body.add_child(head)
	_crest = TextureRect.new()
	_crest.custom_minimum_size = Vector2(58, 58)
	_crest.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	_crest.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
	head.add_child(_crest)
	var names := VBoxContainer.new()
	names.alignment = BoxContainer.ALIGNMENT_CENTER
	names.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	names.add_theme_constant_override("separation", 2)
	head.add_child(names)
	_name = HudKit.label("", 21, HudKit.GOLD_HI, HudKit.title(), 3)
	names.add_child(_name)
	var sub := HBoxContainer.new()
	sub.add_theme_constant_override("separation", 0)
	names.add_child(sub)
	_house = HudKit.label("", 15, HudKit.PARCHMENT, HudKit.body(), 2)
	sub.add_child(_house)
	_rank = HudKit.label("", 15, HudKit.GOLD_LT, HudKit.body(), 2)
	sub.add_child(_rank)
	_medal = LevelMedal.new()
	_medal.caption = I18n.upper(tr("Level"))
	_medal.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	head.add_child(_medal)

	var exp_box := VBoxContainer.new()
	exp_box.add_theme_constant_override("separation", 3)
	body.add_child(exp_box)
	var row := HBoxContainer.new()
	exp_box.add_child(row)
	var caption := HudKit.label(tr("Experience"), 13, HudKit.TEXT_DIM, HudKit.body(), 0)
	caption.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	row.add_child(caption)
	_exp_text = HudKit.label("", 13, HudKit.PARCHMENT, HudKit.body(), 0)
	row.add_child(_exp_text)
	_exp_bar = FillBar.new(Color(0.949, 0.765, 0.353), Color(0.604, 0.416, 0.071), 12.0)
	exp_box.add_child(_exp_bar)

func _build_tabs() -> void:
	var strip := VBoxContainer.new()
	strip.add_theme_constant_override("separation", 0)
	body.add_child(strip)
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 4)
	strip.add_child(row)
	var pad := Control.new()
	pad.custom_minimum_size = Vector2(2, 0)
	row.add_child(pad)
	for page in PAGES:
		var tab := TabChip.new(tr(String(page[1])))
		tab.name = "Tab_" + String(page[0])
		tab.chosen.connect(_show_page.bind(String(page[0])))
		row.add_child(tab)
		_tabs[String(page[0])] = tab
	# The attributes tab carries the unspent points, so they show from any page.
	_badge = PanelContainer.new()
	_badge.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_badge.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	var badge_box := HudSkillWindow._box(Color(0.85, 0.62, 0.22), HudKit.GOLD_HI, 9, 0)
	badge_box.content_margin_left = 5
	badge_box.content_margin_right = 5
	_badge.add_theme_stylebox_override("panel", badge_box)
	_badge_text = HudKit.label("", 12, Color(0.165, 0.102, 0.016), HudKit.bold(), 0)
	_badge.add_child(_badge_text)
	(_tabs["attrs"] as TabChip).row.add_child(_badge)
	var rule := ColorRect.new()
	rule.color = HudKit.GOLD_DK
	rule.custom_minimum_size = Vector2(0, 1)
	rule.mouse_filter = Control.MOUSE_FILTER_IGNORE
	strip.add_child(rule)

func _show_page(page: String) -> void:
	_page = page
	for id in _pages:
		(_pages[id] as Control).visible = id == page
		(_tabs[id] as TabChip).selected = id == page

# ------------------------------------------------------------------- status

func _build_status(page: VBoxContainer) -> void:
	page.add_theme_constant_override("separation", 9)
	_hp_bar = _gauge(page, "hp", tr("Health"), Color(1.0, 0.416, 0.353), Color(0.659, 0.075, 0.055))
	_mana_bar = _gauge(page, "mana", tr("Mana"), Color(0.416, 0.643, 1.0), Color(0.102, 0.263, 0.690))
	var tiles := GridContainer.new()
	tiles.columns = 2
	tiles.add_theme_constant_override("h_separation", 7)
	tiles.add_theme_constant_override("v_separation", 7)
	page.add_child(tiles)
	_tile(tiles, "attack", tr("Attack value"), ATTACK)
	_tile(tiles, "magic", tr("Magic attack value"), MAGIC)
	_tile(tiles, "armour", tr("Armour"), DEFENCE)
	_tile(tiles, "crit", tr("Critical chance"), HudKit.GOLD_LT)
	_tile(tiles, "spell_power", tr("Spell power"), MAGIC)
	_tile(tiles, "skill", tr("Skill power"), MAGIC)
	var purse := HBoxContainer.new()
	purse.alignment = BoxContainer.ALIGNMENT_END
	purse.add_theme_constant_override("separation", 8)
	page.add_child(purse)
	var coin := PanelContainer.new()
	coin.custom_minimum_size = Vector2(14, 14)
	coin.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	coin.add_theme_stylebox_override("panel", HudSkillWindow._box(Color(0.85, 0.62, 0.22), HudKit.GOLD_HI, 7, 0))
	purse.add_child(coin)
	purse.add_child(HudKit.label(tr("Galleons"), 14, HudKit.TEXT_DIM, HudKit.body(), 0))
	var galleons := HudKit.label("", 14, HudKit.GOLD_HI, HudKit.body(), 0)
	purse.add_child(galleons)
	_values["galleons"] = galleons

func _gauge(page: VBoxContainer, key: String, caption: String, top: Color, bottom: Color) -> FillBar:
	var box := VBoxContainer.new()
	box.add_theme_constant_override("separation", 3)
	page.add_child(box)
	var row := HBoxContainer.new()
	box.add_child(row)
	var label := HudKit.label(caption, 13, HudKit.TEXT_DIM, HudKit.body(), 0)
	label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	row.add_child(label)
	var value := HudKit.label("", 14, HudKit.PARCHMENT, HudKit.body(), 0)
	row.add_child(value)
	_values[key] = value
	var bar := FillBar.new(top, bottom, 14.0)
	box.add_child(bar)
	return bar

## A recessed value box with its caption over the number and a coloured edge
## for its family (attack, magic, defence, critical).
func _tile(grid: GridContainer, key: String, caption: String, accent: Color) -> void:
	var tile := StatTile.new(accent)
	tile.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	var sb := HudSkillWindow._box(WELL, Color("2a2a2a"), 4, 0)
	sb.content_margin_left = 13
	sb.content_margin_right = 10
	sb.content_margin_top = 5
	sb.content_margin_bottom = 6
	tile.add_theme_stylebox_override("panel", sb)
	grid.add_child(tile)
	var box := VBoxContainer.new()
	box.add_theme_constant_override("separation", 0)
	tile.add_child(box)
	box.add_child(HudKit.label(caption, 12, HudKit.TEXT_DIM, HudKit.body(), 0))
	var value := HudKit.label("", 17, HudKit.PARCHMENT, HudKit.body(), 0)
	box.add_child(value)
	_values[key] = value

# --------------------------------------------------------------- attributes

func _build_attributes(page: VBoxContainer) -> void:
	page.add_theme_constant_override("separation", 5)
	var head := HBoxContainer.new()
	page.add_child(head)
	_points_box = PanelContainer.new()
	_points_box.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 8)
	_points_box.add_child(row)
	var coin := PanelContainer.new()
	coin.custom_minimum_size = Vector2(24, 24)
	_coin_box = HudSkillWindow._box(Color(0.12, 0.12, 0.12), Color(0.2, 0.2, 0.2), 12, 0)
	_coin_box.content_margin_left = 6
	_coin_box.content_margin_right = 6
	coin.add_theme_stylebox_override("panel", _coin_box)
	row.add_child(coin)
	_points = HudKit.label("0", 13, FAINT, HudKit.bold(), 0)
	_points.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_points.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	coin.add_child(_points)
	row.add_child(HudKit.label(tr("Status Points"), 13, HudKit.TEXT_DIM, HudKit.body(), 0))
	head.add_child(_points_box)
	var gap := Control.new()
	gap.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	head.add_child(gap)
	var rules := HPRules.attribute_rules()
	head.add_child(HudKit.label(tr("%d per level  ·  up to %d each") % [int(rules.get("points_per_level", 2)), int(rules.get("max", 90))], 12, FAINT, HudKit.body(), 0))
	var spacer := Control.new()
	spacer.custom_minimum_size = Vector2(0, 3)
	page.add_child(spacer)
	for pair in ATTRIBUTES:
		_attribute(page, String(pair[0]), tr(String(pair[1])))

func _attribute(page: VBoxContainer, key: String, caption: String) -> void:
	var card := PanelContainer.new()
	card.name = "Attr_" + key
	card.custom_minimum_size = Vector2(0, 60)
	page.add_child(card)
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 12)
	card.add_child(row)
	var value := HudKit.label("0", 22, HudKit.GOLD_HI, HudKit.title(), 2)
	value.custom_minimum_size.x = 44
	value.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	value.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	row.add_child(value)
	var mid := VBoxContainer.new()
	mid.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	mid.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	mid.add_theme_constant_override("separation", 1)
	row.add_child(mid)
	var top := HBoxContainer.new()
	mid.add_child(top)
	var name_label := HudKit.label(caption, 16, HudKit.GOLD_LT, HudKit.body(), 2)
	name_label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	top.add_child(name_label)
	var total := HudKit.label("", 12, HudKit.GREEN, HudKit.body(), 0)
	top.add_child(total)
	var desc_text := I18n.t(String((HPRules.attribute_rules().get("stats", {}) as Dictionary).get(key, {}).get("desc", "")))
	var desc := HudKit.label(desc_text, 12, HudKit.TEXT_DIM, HudKit.body(), 0)
	desc.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
	desc.custom_minimum_size.x = 60
	mid.add_child(desc)
	var bar := FillBar.new(Color(1.0, 0.906, 0.639), Color(0.753, 0.561, 0.216), 5.0)
	mid.add_child(bar)
	var plus := Button.new()
	plus.name = "Plus"
	plus.text = "+"
	plus.focus_mode = Control.FOCUS_NONE
	plus.custom_minimum_size = Vector2(30, 30)
	plus.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	plus.mouse_default_cursor_shape = Control.CURSOR_POINTING_HAND
	plus.tooltip_text = desc_text
	plus.add_theme_font_override("font", HudKit.body())
	plus.add_theme_font_size_override("font_size", 20)
	for colour_name in ["font_color", "font_hover_color", "font_pressed_color"]:
		plus.add_theme_color_override(colour_name, HudKit.GOLD_HI)
	plus.add_theme_color_override("font_disabled_color", Color("3b465c"))
	var looks := {"normal": Color("5a3e0e"), "hover": Color("8a611a"), "pressed": Color("44300a"), "disabled": Color("0d1320")}
	for state in looks:
		var box := HudSkillWindow._box(looks[state], Color("283247") if state == "disabled" else HudKit.GOLD_LT, 4, 0)
		if state != "disabled":
			box.shadow_color = Color(0.91, 0.78, 0.48, 0.25)
			box.shadow_size = 4
		plus.add_theme_stylebox_override(state, box)
	plus.pressed.connect(func():
		if is_instance_valid(player):
			SimNet.submit_attribute(player, key))
	row.add_child(plus)
	_attr_cards[key] = {"card": card, "value": value, "total": total, "bar": bar, "plus": plus, "hover": false}
	_style_attr(key, false)

func _style_attr(key: String, hover: bool) -> void:
	var sb := HudSkillWindow._box(Color(0.149, 0.212, 0.314, 0.65) if hover else Color(0.09, 0.149, 0.231, 0.55),
			HudKit.GOLD if hover else Color("23324c"), 4, 0)
	sb.content_margin_left = 12
	sb.content_margin_right = 10
	(_attr_cards[key].card as PanelContainer).add_theme_stylebox_override("panel", sb)

## What `points` in attribute `key` add up to: "+24 Health", "+8 Attack  ·  +24 Health".
func _attribute_total(key: String, points: int) -> String:
	if points <= 0:
		return tr("No points yet")
	var gives: Dictionary = (HPRules.attribute_rules().get("stats", {}) as Dictionary).get(key, {})
	var words := {
		"max_hp": tr("+%s Health"), "max_mana": tr("+%s Mana"), "attack_value": tr("+%s Attack"),
		"magic_attack": tr("+%s Magic attack"), "attack_speed": tr("+%s%% speed"), "crit_chance": tr("+%s%% critical"),
	}
	var out: Array = []
	for stat in gives:
		if not words.has(stat):
			continue
		var amount := float(gives[stat]) * points
		var shown := str(roundi(amount)) if is_equal_approx(amount, roundf(amount)) else "%.1f" % amount
		out.append(String(words[stat]) % shown)
	return "  ·  ".join(out)

# --------------------------------------------------------------- properties

func _build_properties(page: VBoxContainer) -> void:
	var grid := GridContainer.new()
	grid.columns = 2
	grid.add_theme_constant_override("h_separation", 16)
	grid.add_theme_constant_override("v_separation", 12)
	page.add_child(grid)
	for group in GROUPS:
		var box := VBoxContainer.new()
		box.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		box.add_theme_constant_override("separation", 3)
		grid.add_child(box)
		box.add_child(HudKit.label(I18n.upper(tr(String(group[0]))), 12, HudKit.GOLD_LT, HudKit.title(), 2))
		var rule := ColorRect.new()
		rule.color = Color(HudKit.GOLD, 0.3)
		rule.custom_minimum_size = Vector2(0, 1)
		box.add_child(rule)
		for prop in group[1]:
			var row := HBoxContainer.new()
			box.add_child(row)
			var label := HudKit.label(tr(String(prop[1])), 13, HudKit.TEXT_DIM, HudKit.body(), 0)
			label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
			row.add_child(label)
			var value := HudKit.label("", 14, HudKit.PARCHMENT, HudKit.body(), 0)
			value.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
			row.add_child(value)
			_values[String(prop[0])] = value

# ------------------------------------------------------------------ refresh

func open() -> void:
	super.open()
	_shown = ""
	_refresh()

func _process(delta: float) -> void:
	if not visible:
		return
	_refresh()
	_hover_cards()
	if player != null and is_instance_valid(player) and int(player.attribute_points) > 0:
		_pulse += delta
		_coin_box.shadow_size = int(round(2.0 + 4.0 * (0.5 + 0.5 * sin(_pulse * TAU / 1.8))))

## The attribute card under the pointer lights its border.
func _hover_cards() -> void:
	var over := get_viewport().gui_get_hovered_control()
	var hovered := ""
	while over != null and over != self:
		if over.name.begins_with("Attr_"):
			hovered = over.name.substr(5)
			break
		over = over.get_parent_control()
	for key in _attr_cards:
		var on: bool = key == hovered
		if on != bool(_attr_cards[key].hover):
			_attr_cards[key].hover = on
			_style_attr(key, on)

## "273 - 321": a worn wand range at its +N.
static func _range_text(stats: Dictionary, key: String) -> String:
	var span: Array = stats.get(key, [0, 0])
	var mult := HPRules.wand_multiplier(int(stats.get("wand_tier", 0)))
	return "%d - %d" % [int(round(float(span[0]) * mult)), int(round(float(span[1]) * mult))]

func _refresh() -> void:
	if player == null or not is_instance_valid(player) or _name == null:
		return
	var stats: Dictionary = player.derived_stats
	if stats.is_empty():
		stats = HPEquipment.stats(int(player.base_max_hp), int(player.base_max_mana), player.equipment)
	var levels: Dictionary = player.skill_levels
	var skill_sum := 0.0
	var skills: Array = HPRules.upgradeable_skills()
	for spell_id in skills:
		skill_sum += HPRules.skill_damage_multiplier(HPRules.skill_level_of(levels, String(spell_id)))
	var galleon_text: Callable = preload("res://scripts/ui/inventory_arcane.gd").galleon_text
	var exp_now := int(player.current_exp)
	var exp_max := maxi(1, int(player.max_exp))
	var text := {
		"exp": "%s / %s  ·  %.1f%%" % [galleon_text.call(exp_now), galleon_text.call(exp_max), 100.0 * exp_now / exp_max],
		"hp": "%d / %d" % [player.current_hp, player.max_hp],
		"mana": "%d / %d" % [player.current_mana, player.max_mana],
		"attack": _range_text(stats, "attack_value"),
		"magic": _range_text(stats, "magic_attack"),
		"spell_power": "+%d%%" % int(stats.get("spell_power", 0.0)),
		"skill": "x%.2f" % (skill_sum / maxf(1.0, float(skills.size()))),
		"armour": str(int(stats.get("armor", 0))),
		"crit": "%d%%" % int(HPRules.crit_chance(float(stats.get("crit_chance", 0.0)), false)),
		"attack_speed": "%+d%%" % int(stats.get("attack_speed", 0.0)),
		"cast_speed": "%+d%%" % int(stats.get("cast_speed", 0.0)),
		"move_speed": "%+d%%" % int(stats.get("move_speed", 0.0)),
		"pierce": "%d%%" % int(stats.get("pierce_chance", 0.0)),
		"melee_res": "%d%%" % int(stats.get("melee_resist", 0.0)),
		"projectile_res": "%d%%" % int(stats.get("projectile_resist", 0.0)),
		"spell_res": "%d%%" % int(stats.get("spell_resist", 0.0)),
		"block": "%d%%" % int(stats.get("block_chance", 0.0)),
		"life_steal": "%d%%" % int(stats.get("life_steal", 0.0)),
		"reflect": "%d%%" % int(stats.get("reflect", 0.0)),
		"hp_regen": "+%d /s" % int(stats.get("hp_regen", 0.0)),
		"mana_regen": "+%d /s" % int(stats.get("mana_regen", 0.0)),
		"broom": "%.1f" % float(stats.get("mount_speed", 0.0)),
		"exp_bonus": "+%d%%" % int(stats.get("exp_bonus", 0.0)),
		"gold_bonus": "+%d%%" % int(stats.get("galleon_bonus", 0.0)),
		"galleons": galleon_text.call(int(player.galleons)),
	}
	var free := int(player.attribute_points)
	var key := "%s|%d|%s|%d" % [str(text), free, str(player.attributes), int(player.level)]
	if key == _shown:
		return
	_shown = key
	# A property at zero reads dim, so what the character actually has stands out.
	var zero := {
		"attack_speed": stats.get("attack_speed", 0.0), "cast_speed": stats.get("cast_speed", 0.0),
		"move_speed": stats.get("move_speed", 0.0), "pierce": stats.get("pierce_chance", 0.0),
		"melee_res": stats.get("melee_resist", 0.0), "projectile_res": stats.get("projectile_resist", 0.0),
		"spell_res": stats.get("spell_resist", 0.0), "block": stats.get("block_chance", 0.0),
		"life_steal": stats.get("life_steal", 0.0), "reflect": stats.get("reflect", 0.0),
		"hp_regen": stats.get("hp_regen", 0.0), "mana_regen": stats.get("mana_regen", 0.0),
		"broom": stats.get("mount_speed", 0.0), "exp_bonus": stats.get("exp_bonus", 0.0),
		"gold_bonus": stats.get("galleon_bonus", 0.0),
	}
	for k in text:
		if _values.has(k):
			var label := _values[k] as Label
			label.text = String(text[k])
			if zero.has(k):
				label.add_theme_color_override("font_color", FAINT if int(zero[k]) == 0 else HudKit.PARCHMENT)
	_exp_text.text = String(text.exp)
	_exp_bar.fraction = float(exp_now) / float(exp_max)
	_hp_bar.fraction = float(player.current_hp) / maxf(1.0, float(player.max_hp))
	_mana_bar.fraction = float(player.current_mana) / maxf(1.0, float(player.max_mana))
	_medal.level = int(player.level)

	var cap := int(HPRules.attribute_rules().get("max", 90))
	_badge.visible = free > 0
	_badge_text.text = str(free)
	_points.text = str(free)
	_points.add_theme_color_override("font_color", Color(0.165, 0.102, 0.016) if free > 0 else FAINT)
	_coin_box.bg_color = Color(0.85, 0.62, 0.22) if free > 0 else Color(0.12, 0.12, 0.12)
	_coin_box.border_color = HudKit.GOLD_HI if free > 0 else Color(0.2, 0.2, 0.2)
	_coin_box.shadow_color = Color(1.0, 0.82, 0.47, 0.55) if free > 0 else Color(0, 0, 0, 0)
	_coin_box.shadow_size = 0
	var capsule := HudSkillWindow._box(Color(0.035, 0.051, 0.09), HudKit.GOLD_DK if free > 0 else Color("2b3a55"), 13, 0)
	capsule.content_margin_left = 4
	capsule.content_margin_right = 12
	capsule.content_margin_top = 3
	capsule.content_margin_bottom = 3
	_points_box.add_theme_stylebox_override("panel", capsule)
	for id in _attr_cards:
		var card: Dictionary = _attr_cards[id]
		var points := int(player.attributes.get(id, 0))
		(card.value as Label).text = str(points)
		(card.value as Label).add_theme_color_override("font_color", HudKit.GOLD_HI if points > 0 else FAINT)
		(card.total as Label).text = _attribute_total(id, points)
		(card.total as Label).add_theme_color_override("font_color", HudKit.GREEN if points > 0 else FAINT)
		(card.bar as FillBar).fraction = float(points) / float(maxi(1, cap))
		(card.plus as Button).disabled = free <= 0 or points >= cap

	_name.text = String(player.player_name)
	var rank := HPRules.house_rank_for(int(player.get("house_rep") if player.get("house_rep") != null else 0))
	_house.text = "%s  ·  " % String(player.house)
	_rank.text = I18n.t(HPRules.house_rank_title(rank))
	_crest.texture = UITheme.icon_for("house_" + String(player.house).to_lower())


## One page tab: caption (and, for attributes, the points badge) on a lit
## plate when selected; the plate opens into the rule under the tab row.
class TabChip extends PanelContainer:
	signal chosen
	var row: HBoxContainer
	var _label: Label
	var _hover := false
	var selected := false:
		set(value):
			selected = value
			_restyle()

	func _init(caption: String) -> void:
		mouse_filter = Control.MOUSE_FILTER_STOP
		mouse_default_cursor_shape = Control.CURSOR_POINTING_HAND
		row = HBoxContainer.new()
		row.add_theme_constant_override("separation", 7)
		row.mouse_filter = Control.MOUSE_FILTER_IGNORE
		add_child(row)
		_label = HudKit.label(caption, 15, HudKit.TEXT_DIM, HudKit.body(), 0)
		row.add_child(_label)
		mouse_entered.connect(func(): _hover = true; _restyle())
		mouse_exited.connect(func(): _hover = false; _restyle())
		_restyle()

	func _gui_input(event: InputEvent) -> void:
		if event is InputEventMouseButton and event.pressed and event.button_index == MOUSE_BUTTON_LEFT:
			chosen.emit()
			accept_event()

	func _restyle() -> void:
		var sb := StyleBoxFlat.new()
		sb.bg_color = Color("1d2f4a") if selected else Color(0, 0, 0, 0)
		sb.border_color = HudKit.GOLD_DK if selected else Color(0, 0, 0, 0)
		sb.set_border_width_all(1)
		sb.border_width_bottom = 0
		sb.corner_radius_top_left = 5
		sb.corner_radius_top_right = 5
		sb.content_margin_left = 16
		sb.content_margin_right = 16
		sb.content_margin_top = 6
		sb.content_margin_bottom = 7
		add_theme_stylebox_override("panel", sb)
		if _label != null:
			_label.add_theme_color_override("font_color", HudKit.GOLD_HI if selected else (HudKit.PARCHMENT if _hover else HudKit.TEXT_DIM))


## A recessed value tile with a coloured edge on the left.
class StatTile extends PanelContainer:
	var accent := Color.WHITE

	func _init(p_accent: Color) -> void:
		accent = p_accent
		mouse_filter = Control.MOUSE_FILTER_IGNORE

	func _draw() -> void:
		draw_rect(Rect2(Vector2(0, 6), Vector2(3, size.y - 12)), accent)


## A gauge: dark well, two-tone fill with a lit top half.
class FillBar extends Control:
	var top := Color.WHITE
	var bottom := Color.WHITE
	var fraction := 0.0:
		set(value):
			value = clampf(value, 0.0, 1.0)
			if not is_equal_approx(value, fraction):
				fraction = value
				queue_redraw()

	func _init(p_top: Color, p_bottom: Color, height: float) -> void:
		top = p_top
		bottom = p_bottom
		custom_minimum_size = Vector2(0, height)
		mouse_filter = Control.MOUSE_FILTER_IGNORE

	func _draw() -> void:
		var r := Rect2(Vector2.ZERO, size)
		draw_rect(r, HudCharacterWindow.WELL)
		if fraction > 0.0:
			var fill := Rect2(Vector2(1, 1), Vector2(maxf(2.0, (size.x - 2.0) * fraction), size.y - 2.0))
			draw_rect(fill, bottom)
			draw_rect(Rect2(fill.position, Vector2(fill.size.x, fill.size.y * 0.45)), top.lerp(bottom, 0.25))
		draw_rect(r, HudCharacterWindow.WELL_EDGE, false, 1.0)


## The round level medallion in the header.
class LevelMedal extends Control:
	var caption := ""
	var level := 0:
		set(value):
			if value != level:
				level = value
				queue_redraw()

	func _init() -> void:
		custom_minimum_size = Vector2(60, 60)
		mouse_filter = Control.MOUSE_FILTER_IGNORE

	func _draw() -> void:
		var c := size * 0.5
		var r := minf(size.x, size.y) * 0.5 - 1.0
		draw_circle(c, r + 1.0, Color(0.91, 0.78, 0.48, 0.15))
		draw_circle(c, r, HudKit.GOLD)
		draw_circle(c, r - 2.0, Color("0b1120"))
		draw_circle(c, r - 4.0, Color("1a2338"))
		var small := HudKit.body()
		var cw := small.get_string_size(caption, HORIZONTAL_ALIGNMENT_LEFT, -1, 9).x
		draw_string(small, Vector2(c.x - cw * 0.5, c.y - 9.0), caption, HORIZONTAL_ALIGNMENT_LEFT, -1, 9, HudKit.TEXT_DIM)
		var big := HudKit.title()
		var txt := str(level)
		var tw := big.get_string_size(txt, HORIZONTAL_ALIGNMENT_LEFT, -1, 22).x
		draw_string(big, Vector2(c.x - tw * 0.5, c.y + 15.0), txt, HORIZONTAL_ALIGNMENT_LEFT, -1, 22, HudKit.GOLD_HI)
