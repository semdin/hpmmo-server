extends HudWindow
class_name HudCharacterWindow

## The character sheet (C), Metin2's "Character" window: the portrait plate
## (crest, name, house, level, experience), the core numbers (health, mana,
## attack and skill power, armour) and the secondary stats - all read off the
## live player (`derived_stats` is HPEquipment.stats, the same numbers the
## authority fights with). The attribute block is where attribute points (two
## per level) will be spent; it shows the four attributes already.

const ATTRIBUTES := [["vit", "Vitality"], ["int", "Intellect"], ["str", "Strength"], ["dex", "Agility"]]  # i18n

var player: Node3D = null
var _crest: TextureRect
var _name: Label
var _sub: Label
var _values: Dictionary = {}   # key -> Label
var _shown := ""

func _init() -> void:
	super._init("Character", Vector2(390, 600))
	name = "CharacterWindow"

var _content: VBoxContainer

func _ready() -> void:
	super._ready()
	# Everything scrolls inside the card on a short screen.
	var scroll := ScrollContainer.new()
	scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
	scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	body.add_child(scroll)
	_content = VBoxContainer.new()
	_content.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_content.add_theme_constant_override("separation", 6)
	scroll.add_child(_content)
	var head := HBoxContainer.new()
	head.add_theme_constant_override("separation", 12)
	_content.add_child(head)
	_crest = TextureRect.new()
	_crest.custom_minimum_size = Vector2(56, 56)
	_crest.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	_crest.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
	head.add_child(_crest)
	var names := VBoxContainer.new()
	names.alignment = BoxContainer.ALIGNMENT_CENTER
	names.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	head.add_child(names)
	_name = HudKit.label("", 20, HudKit.GOLD_HI, HudKit.title(), 3)
	names.add_child(_name)
	_sub = HudKit.label("", 14, HudKit.PARCHMENT, HudKit.body(), 2)
	names.add_child(_sub)
	var top := _grid(_content, 3)
	_cell(top, "level", tr("Level"))
	_cell(top, "exp", tr("Experience"))
	_cell(top, "exp_next", tr("Next level"))
	_section(tr("Status"))
	var status := _grid(_content, 2)
	_cell(status, "hp", tr("Health"))
	_cell(status, "mana", tr("Mana"))
	_cell(status, "attack", tr("Attack value"))
	_cell(status, "magic", tr("Magic attack value"))
	_cell(status, "armour", tr("Armour"))
	_cell(status, "crit", tr("Critical chance"))
	_cell(status, "spell_power", tr("Spell power"))
	_cell(status, "skill", tr("Skill power"))
	_section(tr("Attributes"))
	var attrs := _grid(_content, 2)
	for pair in ATTRIBUTES:
		_attribute(attrs, String(pair[0]), tr(String(pair[1])))
	_attr_points = HudKit.label("", 13, HudKit.TEXT_DIM, HudKit.body(), 0)
	_attr_points.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_content.add_child(_attr_points)
	_section(tr("Properties"))
	var props := _grid(_content, 2)
	_prop(props, "attack_speed", tr("Attack speed"))
	_prop(props, "cast_speed", tr("Casting speed"))
	_prop(props, "move_speed", tr("Movement speed"))
	_prop(props, "pierce", tr("Piercing hit"))
	_prop(props, "melee_res", tr("Melee resist"))
	_prop(props, "projectile_res", tr("Projectile resist"))
	_prop(props, "spell_res", tr("Spell resist"))
	_prop(props, "block", tr("Block"))
	_prop(props, "life_steal", tr("Life drain"))
	_prop(props, "reflect", tr("Reflect"))
	_prop(props, "hp_regen", tr("Health regen"))
	_prop(props, "mana_regen", tr("Mana regen"))
	_prop(props, "broom", tr("Broom speed"))
	_prop(props, "exp_bonus", tr("Experience"))
	_prop(props, "gold_bonus", tr("Galleons found"))
	_prop(props, "galleons", tr("Galleons"))

func _section(text: String) -> void:
	var label := HudKit.label(I18n.upper(text), 13, HudKit.GOLD_LT, HudKit.title(), 2)
	_content.add_child(UITheme.divider())
	_content.add_child(label)

func _grid(parent: Control, columns: int) -> GridContainer:
	var grid := GridContainer.new()
	grid.columns = columns
	grid.add_theme_constant_override("h_separation", 8)
	grid.add_theme_constant_override("v_separation", 6)
	parent.add_child(grid)
	return grid

## A caption over a recessed value box (the Metin2 sheet's black fields).
func _cell(grid: GridContainer, key: String, caption: String) -> void:
	var cell := VBoxContainer.new()
	cell.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	cell.add_theme_constant_override("separation", 2)
	grid.add_child(cell)
	cell.add_child(HudKit.label(caption, 12, HudKit.TEXT_DIM, HudKit.body(), 0))
	var box := PanelContainer.new()
	var style := StyleBoxFlat.new()
	style.bg_color = Color("070b12")
	style.border_color = Color("3a3122")
	style.set_border_width_all(1)
	style.set_corner_radius_all(3)
	style.content_margin_left = 8
	style.content_margin_right = 8
	style.content_margin_top = 3
	style.content_margin_bottom = 3
	box.add_theme_stylebox_override("panel", style)
	cell.add_child(box)
	var value := HudKit.label("", 15, HudKit.PARCHMENT, HudKit.bold(), 0)
	value.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	box.add_child(value)
	_values[key] = value

## A compact "caption ..... value" line for the secondary properties.
func _prop(grid: GridContainer, key: String, caption: String) -> void:
	var row := HBoxContainer.new()
	row.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	grid.add_child(row)
	var label := HudKit.label(caption, 13, HudKit.TEXT_DIM, HudKit.body(), 0)
	label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	row.add_child(label)
	var value := HudKit.label("", 14, HudKit.PARCHMENT, HudKit.bold(), 0)
	value.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
	row.add_child(value)
	_values[key] = value

func _attribute(grid: GridContainer, key: String, caption: String) -> void:
	var row := HBoxContainer.new()
	row.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	row.add_theme_constant_override("separation", 6)
	grid.add_child(row)
	var label := HudKit.label(caption, 13, HudKit.PARCHMENT, HudKit.body(), 0)
	label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	row.add_child(label)
	var value := HudKit.label("0", 15, HudKit.GOLD_HI, HudKit.bold(), 0)
	value.custom_minimum_size.x = 28
	value.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
	row.add_child(value)
	_values[key] = value
	var plus := Button.new()
	plus.text = "+"
	plus.focus_mode = Control.FOCUS_NONE
	plus.custom_minimum_size = Vector2(26, 24)
	plus.tooltip_text = I18n.t(String((HPRules.attribute_rules().get("stats", {}) as Dictionary).get(key, {}).get("desc", "")))
	plus.pressed.connect(func():
		if is_instance_valid(player):
			SimNet.submit_attribute(player, key))
	row.add_child(plus)
	_plus[key] = plus

var _attr_points: Label
var _plus: Dictionary = {}

func open() -> void:
	super.open()
	_shown = ""
	_refresh()

func _process(_delta: float) -> void:
	if visible:
		_refresh()

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
	var text := {
		"level": str(player.level),
		"exp": str(player.current_exp),
		"exp_next": str(player.max_exp),
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
		"galleons": preload("res://scripts/ui/inventory_arcane.gd").galleon_text(int(player.galleons)),
		"vit": str(int(player.attributes.get("vit", 0))), "int": str(int(player.attributes.get("int", 0))),
		"str": str(int(player.attributes.get("str", 0))), "dex": str(int(player.attributes.get("dex", 0))),
		"attr_points": str(int(player.attribute_points)),
	}
	var key := str(text)
	if key == _shown:
		return
	_shown = key
	for k in text:
		if _values.has(k):
			(_values[k] as Label).text = String(text[k])
	var free := int(player.attribute_points)
	if _attr_points != null:
		_attr_points.text = tr("Status points: %d  ·  %d per level") % [free, int(HPRules.attribute_rules().get("points_per_level", 2))]
		_attr_points.add_theme_color_override("font_color", HudKit.GOLD_HI if free > 0 else HudKit.TEXT_DIM)
	for id in _plus:
		var plus := _plus[id] as Button
		plus.disabled = free <= 0 or int(player.attributes.get(id, 0)) >= int(HPRules.attribute_rules().get("max", 90))
		plus.modulate.a = 0.35 if plus.disabled else 1.0
	_name.text = String(player.player_name)
	var rank := HPRules.house_rank_for(int(player.get("house_rep") if player.get("house_rep") != null else 0))
	_sub.text = "%s  ·  %s" % [String(player.house), I18n.t(HPRules.house_rank_title(rank))]
	_crest.texture = UITheme.icon_for("house_" + String(player.house).to_lower())
