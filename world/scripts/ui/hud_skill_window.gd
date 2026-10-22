extends HudWindow
class_name HudSkillWindow

## The skill window (V), laid out like Metin2's: a small grid of spell icons,
## each with its level plate ("1".."9", "M" for Master) and, while there are
## points to spend, a "+" in the corner. Everything else - what the spell does,
## its numbers now and at the next level - is in the dark tooltip over the
## icon. Every level the character gains is one skill point; "+" spends it, up
## to level 10 (Master). Icons drag onto the action bar to set the hotkeys.
##
## The window only asks: the authority checks the points and the cap
## (SimNet.submit_skill_up) and the result comes back in the stats payload,
## which this window reads off the player every frame it is open.

const ICON := 54.0
const COLUMNS := 3
## Spells on the bar that do not train (shown below the trainable grid).
const OTHER := ["patronum"]

var player: Node3D = null
## The HUD, for notices (set by hud.gd).
var hud: Control = null
var _points: Label
var _cells: Dictionary = {}   # spell_id -> {slot, plus, name}
var _shown := ""

func _init() -> void:
	super._init("Skills", Vector2(380, 400))
	name = "SkillWindow"
	modal = false

func _ready() -> void:
	super._ready()
	var head := HBoxContainer.new()
	body.add_child(head)
	var caption := HudKit.label(tr("Spells"), 15, HudKit.GOLD_LT, HudKit.bold(), 2)
	caption.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	head.add_child(caption)
	_points = HudKit.label("", 15, HudKit.GOLD_HI, HudKit.bold(), 3)
	_points.name = "Points"
	head.add_child(_points)
	body.add_child(_grid(HPRules.upgradeable_skills()))
	var other: Array = OTHER.filter(func(id): return GameData.SPELLS.has(id) and not HPRules.skill_upgradeable(id))
	if not other.is_empty():
		body.add_child(HudKit.label(tr("Other spells"), 13, HudKit.TEXT_DIM, HudKit.bold(), 2))
		body.add_child(_grid(other))
	var spacer := Control.new()
	spacer.size_flags_vertical = Control.SIZE_EXPAND_FILL
	body.add_child(spacer)
	var hint := HudKit.label(tr("Drag a spell onto the bar  ·  + spends a point"), 12, HudKit.TEXT_DIM, HudKit.body(), 0)
	hint.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	body.add_child(hint)

func _grid(spell_ids: Array) -> GridContainer:
	var grid := GridContainer.new()
	grid.columns = COLUMNS
	grid.add_theme_constant_override("h_separation", 6)
	grid.add_theme_constant_override("v_separation", 10)
	grid.size_flags_horizontal = Control.SIZE_SHRINK_CENTER
	for spell_id in spell_ids:
		grid.add_child(_cell(String(spell_id)))
	return grid

func _cell(spell_id: String) -> Control:
	var col := VBoxContainer.new()
	col.name = "Cell_" + spell_id
	col.alignment = BoxContainer.ALIGNMENT_CENTER
	col.add_theme_constant_override("separation", 3)
	col.custom_minimum_size = Vector2(106, 0)
	var slot := SkillIcon.new(ICON)
	slot.window = self
	slot.spell_id = spell_id
	slot.held_id = spell_id
	slot.icon_texture = UITheme.spell_icon(spell_id)
	slot.size_flags_horizontal = Control.SIZE_SHRINK_CENTER
	slot.tooltip_text = spell_id   # any text: the card itself is built on hover
	col.add_child(slot)
	# Metin2's little "+" seal on the icon's corner.
	var plus := Button.new()
	plus.name = "Train"
	plus.text = "+"
	plus.focus_mode = Control.FOCUS_NONE
	plus.add_theme_font_override("font", HudKit.bold())
	plus.add_theme_font_size_override("font_size", 14)
	for state in ["normal", "hover", "pressed"]:
		var box := StyleBoxFlat.new()
		box.bg_color = Color(0.45, 0.3, 0.06) if state == "normal" else Color(0.7, 0.5, 0.12)
		box.border_color = HudKit.GOLD_LT
		box.set_border_width_all(1)
		box.set_corner_radius_all(3)
		box.set_content_margin_all(0)
		plus.add_theme_stylebox_override(state, box)
	plus.add_theme_color_override("font_color", HudKit.GOLD_HI)
	plus.custom_minimum_size = Vector2(17, 17)
	plus.size = Vector2(17, 17)
	plus.position = Vector2(ICON - 15, -2)
	plus.pressed.connect(train.bind(spell_id))
	slot.add_child(plus)
	var label := HudKit.label(I18n.t(String(HPRules.spell(spell_id).get("name", spell_id))), 12, HudKit.PARCHMENT, HudKit.body(), 2)
	label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	label.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
	label.custom_minimum_size = Vector2(106, 0)
	col.add_child(label)
	_cells[spell_id] = {"slot": slot, "plus": plus, "name": label}
	return col

## Ask the authority to spend one point on `spell_id`. Returns the immediate
## answer (always ok for a network client; the server's verdict arrives later).
func train(spell_id: String) -> Dictionary:
	if player == null or not is_instance_valid(player):
		return HPProtocol.reject(HPProtocol.REJECT_STATE)
	var result: Dictionary = SimNet.submit_skill_up(player, spell_id)
	if not bool(result.get("ok", false)):
		var words := {
			HPProtocol.REJECT_NO_SKILL_POINTS: tr("No skill points left - gain a level"),
			HPProtocol.REJECT_SKILL_MAX: tr("Already mastered"),
		}
		if hud != null and hud.has_method("show_notice"):
			hud.show_notice(String(words.get(String(result.get("reason", "")), tr("Cannot train that now"))), "error")
	_refresh()
	return result

func open() -> void:
	super.open()
	_shown = ""
	_refresh()

func _process(_delta: float) -> void:
	if visible:
		_refresh()

func _refresh() -> void:
	if player == null or not is_instance_valid(player) or _points == null:
		return
	var levels: Dictionary = player.skill_levels
	var points: int = int(player.skill_points)
	var key := "%s|%d|%d" % [str(levels), points, int(player.level)]
	if key == _shown:
		return
	_shown = key
	_points.text = tr("Points  %d") % points
	_points.add_theme_color_override("font_color", HudKit.GOLD_HI if points > 0 else HudKit.TEXT_DIM)
	for spell_id in _cells.keys():
		var cell: Dictionary = _cells[spell_id]
		var slot := cell.slot as HudSlot
		var plus := cell.plus as Button
		var trainable := HPRules.skill_upgradeable(spell_id)
		var lv := _level(spell_id)
		slot.badge_text = HPRules.skill_level_label(lv) if trainable and lv > 0 else ""
		slot.unusable = lv <= 0
		plus.visible = trainable and points > 0 and lv < HPRules.skill_max_level()

func _level(spell_id: String) -> int:
	if not HPRules.skill_upgradeable(spell_id):
		return 1 if int(player.level) >= HPRules.spell_required_level(spell_id) else 0
	return HPRules.skill_level_of(player.skill_levels, spell_id)

## The Metin2 card over an icon: name, grade, what it does, the numbers now
## and (in blue) at the next level.
func tooltip_for(spell_id: String) -> Control:
	var spell: Dictionary = HPRules.spell(spell_id)
	var card := PanelContainer.new()
	var sb := HudKit.panel(0.97, 4).duplicate() as StyleBoxFlat
	sb.set_content_margin_all(10)
	card.add_theme_stylebox_override("panel", sb)
	var box := VBoxContainer.new()
	box.add_theme_constant_override("separation", 2)
	card.add_child(box)
	var add := func(text: String, size: int, colour: Color, font: Font) -> void:
		var l := HudKit.label(text, size, colour, font, 2)
		l.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
		l.custom_minimum_size.x = 250
		l.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
		box.add_child(l)
	add.call(I18n.t(String(spell.get("name", spell_id))), 16, HudKit.GOLD_HI, HudKit.bold())
	var trainable := HPRules.skill_upgradeable(spell_id)
	var lv := _level(spell_id) if player != null and is_instance_valid(player) else 0
	if trainable:
		add.call(tr("Master") if HPRules.skill_is_master(lv) else (tr("Not learned") if lv <= 0 else tr("Level %d") % lv), 13, HudKit.GOLD_LT, HudKit.body())
	add.call(I18n.t(String(spell.get("desc", ""))), 13, HudKit.TEXT, HudKit.body())
	var shown_lv := maxi(1, lv)
	box.add_child(HSeparator.new())
	if lv > 0 or not trainable:
		for line in _numbers(spell_id, shown_lv):
			add.call(line, 13, HudKit.PARCHMENT, HudKit.body())
	var required := HPRules.spell_required_level(spell_id)
	if required > 1 and player != null and int(player.level) < required:
		add.call(tr("Requires level %d") % required, 13, HudKit.RED, HudKit.body())
	if trainable and lv < HPRules.skill_max_level():
		var next := lv + 1
		add.call((tr("Master") if HPRules.skill_is_master(next) else tr("Next level: %d") % next), 13, Color(0.55, 0.75, 1.0), HudKit.bold())
		for line in _numbers(spell_id, next):
			add.call(line, 13, Color(0.78, 0.62, 1.0), HudKit.body())
	return card

func _numbers(spell_id: String, lv: int) -> Array:
	var spell: Dictionary = HPRules.spell(spell_id)
	var house := String(player.house) if player != null and is_instance_valid(player) else ""
	var stats: Dictionary = player.derived_stats if player != null and is_instance_valid(player) else {}
	var out: Array = []
	if int(spell.get("damage", 0)) > 0:
		out.append(tr("Damage %d%%") % roundi(HPRules.skill_damage_multiplier(lv) * 100.0))
	if spell.has("duration_ms") or spell.has("stun_ms") or spell.has("weaken_ms"):
		out.append(tr("Effect %d%%") % roundi(HPRules.skill_effect_multiplier(lv) * 100.0))
	out.append(tr("Mana %d  ·  Cooldown %.1fs") % [int(spell.get("mana_cost", 0)), HPRules.cooldown_for(spell_id, house, lv, stats)])
	return out


## A spell icon in the window: drags onto the action bar (the bar's spell slots
## take {"id", "spell_slot"}) and shows the window's Metin2 card on hover.
class SkillIcon extends HudSlot:
	var window: HudSkillWindow
	var spell_id := ""

	func _make_custom_tooltip(_for_text: String) -> Object:
		return window.tooltip_for(spell_id) if window != null else null

	func _get_drag_data(_at: Vector2) -> Variant:
		if unusable or spell_id == "":
			return null
		var preview := TextureRect.new()
		preview.texture = icon_texture
		preview.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
		preview.size = size
		preview.position = -size * 0.5
		preview.modulate = Color(1, 1, 1, 0.85)
		var holder := Control.new()
		holder.add_child(preview)
		set_drag_preview(holder)
		return {"id": spell_id, "spell_slot": -1}
