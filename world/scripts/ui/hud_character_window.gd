extends HudWindow
class_name HudCharacterWindow

## The character sheet (C), Metin2's "Character" window: the portrait plate
## (crest, name, house, level, experience), the core numbers (health, mana,
## attack and skill power, armour) and the secondary stats - all read off the
## live player (`derived_stats` is HPEquipment.stats, the same numbers the
## authority fights with). The attribute block is where attribute points (two
## per level) will be spent; it shows the four attributes already.

const ATTRIBUTES := [["vit", "Vitality"], ["int", "Intellect"], ["str", "Strength"], ["dex", "Agility"]]

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
	_cell(top, "level", "Level")
	_cell(top, "exp", "Experience")
	_cell(top, "exp_next", "Next level")
	_section("STATUS")
	var status := _grid(_content, 2)
	_cell(status, "hp", "Health")
	_cell(status, "mana", "Mana")
	_cell(status, "attack", "Attack power")
	_cell(status, "skill", "Skill power")
	_cell(status, "armour", "Magic armour")
	_cell(status, "crit", "Critical chance")
	_section("ATTRIBUTES")
	var attrs := _grid(_content, 2)
	for pair in ATTRIBUTES:
		_attribute(attrs, String(pair[0]), String(pair[1]))
	var points := HudKit.label("Attribute points: 0  ·  two per level (coming soon)", 12, HudKit.TEXT_DIM, HudKit.body(), 0)
	points.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_content.add_child(points)
	_section("PROPERTIES")
	var props := _grid(_content, 2)
	_prop(props, "creature_dmg", "Vs creatures")
	_prop(props, "creature_res", "Creature resist")
	_prop(props, "hp_regen", "Health regen")
	_prop(props, "mana_regen", "Mana regen")
	_prop(props, "broom", "Broom speed")
	_prop(props, "exp_bonus", "Experience")
	_prop(props, "gold_bonus", "Galleons found")
	_prop(props, "galleons", "Galleons")

func _section(text: String) -> void:
	var label := HudKit.label(text, 13, HudKit.GOLD_LT, HudKit.title(), 2)
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
	plus.disabled = true
	plus.focus_mode = Control.FOCUS_NONE
	plus.custom_minimum_size = Vector2(26, 24)
	plus.tooltip_text = "Attribute points arrive in a later update"
	row.add_child(plus)

func open() -> void:
	super.open()
	_shown = ""
	_refresh()

func _process(_delta: float) -> void:
	if visible:
		_refresh()

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
		"attack": "x%.2f" % (float(stats.get("weapon_multiplier", 1.0)) * HPRules.wand_multiplier(int(stats.get("wand_tier", 0)))),
		"skill": "x%.2f" % (skill_sum / maxf(1.0, float(skills.size()))),
		"armour": "%d%%" % int(stats.get("defense", 0.0)),
		"crit": "%d%%" % int(stats.get("crit_chance", 0.0)),
		"creature_dmg": "+%d%%" % int(stats.get("monster_damage", 0.0)),
		"creature_res": "%d%%" % int(stats.get("creature_resist", 0.0)),
		"hp_regen": "+%d /s" % int(stats.get("hp_regen", 0.0)),
		"mana_regen": "+%d /s" % int(stats.get("mana_regen", 0.0)),
		"broom": "%.1f" % float(stats.get("mount_speed", 0.0)),
		"exp_bonus": "+%d%%" % int(stats.get("exp_bonus", 0.0)),
		"gold_bonus": "+%d%%" % int(stats.get("galleon_bonus", 0.0)),
		"galleons": preload("res://scripts/ui/inventory_arcane.gd").galleon_text(int(player.galleons)),
		"vit": "0", "int": "0", "str": "0", "dex": "0",
	}
	var key := str(text)
	if key == _shown:
		return
	_shown = key
	for k in text:
		if _values.has(k):
			(_values[k] as Label).text = String(text[k])
	_name.text = String(player.player_name)
	var rank := HPRules.house_rank_for(int(player.get("house_rep") if player.get("house_rep") != null else 0))
	_sub.text = "%s  ·  %s" % [String(player.house), HPRules.house_rank_title(rank)]
	_crest.texture = UITheme.icon_for("house_" + String(player.house).to_lower())
