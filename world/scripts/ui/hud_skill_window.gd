extends HudWindow
class_name HudSkillWindow

## The skill window (V): Metin2-style training. Every level the character gains
## is one skill point; "+" spends it on a spell, up to level 10 - Master, shown
## as "M" here and on the action bar. The window only asks: the authority checks
## the points and the cap (SimNet.submit_skill_up) and the result comes back in
## the stats payload, which this window reads off the player every frame it is
## open.

const ROW_ICON := 46.0

var player: Node3D = null
## The HUD, for notices (set by hud.gd).
var hud: Control = null
var _points: Label
var _rows: Dictionary = {}   # spell_id -> {level, pips, effect, button}
var _shown := ""

func _init() -> void:
	super._init("Skills", Vector2(580, 596))
	name = "SkillWindow"
	modal = false

func _ready() -> void:
	super._ready()
	var head := HBoxContainer.new()
	head.add_theme_constant_override("separation", 8)
	body.add_child(head)
	var caption := HudKit.label("Spells of the wand", 15, HudKit.TEXT_DIM, HudKit.body(), 0)
	caption.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	head.add_child(caption)
	_points = HudKit.label("", 16, HudKit.GOLD_LT, HudKit.bold(), 3)
	_points.name = "Points"
	head.add_child(_points)
	var scroll := ScrollContainer.new()
	scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
	scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	body.add_child(scroll)
	var list := VBoxContainer.new()
	list.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	list.add_theme_constant_override("separation", 6)
	scroll.add_child(list)
	for spell_id in HPRules.upgradeable_skills():
		list.add_child(_build_row(String(spell_id)))
	var hint := HudKit.label("One skill point per level gained  ·  Level 10 = Master  ·  V / Esc: close", 13, HudKit.TEXT_DIM, HudKit.body(), 0)
	hint.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	body.add_child(hint)

func _build_row(spell_id: String) -> Control:
	var spell: Dictionary = HPRules.spell(spell_id)
	var row := PanelContainer.new()
	row.name = "Row_" + spell_id
	var box := HudKit.panel(0.55, 5, 0.45).duplicate() as StyleBoxFlat
	box.content_margin_left = 8
	box.content_margin_right = 8
	box.content_margin_top = 6
	box.content_margin_bottom = 6
	row.add_theme_stylebox_override("panel", box)
	var line := HBoxContainer.new()
	line.add_theme_constant_override("separation", 10)
	row.add_child(line)
	var icon := HudSlot.new(ROW_ICON)
	icon.icon_texture = UITheme.spell_icon(spell_id)
	icon.mouse_filter = Control.MOUSE_FILTER_PASS
	icon.tooltip_text = "%s\n%s" % [spell.get("name", spell_id), spell.get("desc", "")]
	line.add_child(icon)
	var text := VBoxContainer.new()
	text.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	text.add_theme_constant_override("separation", 2)
	line.add_child(text)
	var title_row := HBoxContainer.new()
	title_row.add_theme_constant_override("separation", 8)
	text.add_child(title_row)
	title_row.add_child(HudKit.label(String(spell.get("name", spell_id)), 16, HudKit.PARCHMENT, HudKit.bold(), 3))
	var level := HudKit.label("", 15, HudKit.GOLD_LT, HudKit.bold(), 3)
	level.name = "Level"
	title_row.add_child(level)
	var pips := SkillPips.new()
	pips.custom_minimum_size = Vector2(0, 9)
	text.add_child(pips)
	var effect := HudKit.label("", 12, HudKit.TEXT_DIM, HudKit.body(), 0)
	effect.name = "Effect"
	text.add_child(effect)
	var plus := HudKit.button("+", 20)
	plus.name = "Train"
	plus.custom_minimum_size = Vector2(40, 40)
	plus.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	plus.pressed.connect(train.bind(spell_id))
	line.add_child(plus)
	_rows[spell_id] = {"icon": icon, "level": level, "pips": pips, "effect": effect, "button": plus}
	return row

## Ask the authority to spend one point on `spell_id`. Returns the immediate
## answer (always ok for a network client; the server's verdict arrives later).
func train(spell_id: String) -> Dictionary:
	if player == null or not is_instance_valid(player):
		return HPProtocol.reject(HPProtocol.REJECT_STATE)
	var result: Dictionary = SimNet.submit_skill_up(player, spell_id)
	if not bool(result.get("ok", false)):
		var words := {
			HPProtocol.REJECT_NO_SKILL_POINTS: "No skill points left - gain a level",
			HPProtocol.REJECT_SKILL_MAX: "Already mastered",
		}
		if hud != null and hud.has_method("show_notice"):
			hud.show_notice(String(words.get(String(result.get("reason", "")), "Cannot train that now")), "error")
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
	_points.text = "Skill points: %d" % points
	_points.add_theme_color_override("font_color", HudKit.GOLD_HI if points > 0 else HudKit.TEXT_DIM)
	for spell_id in _rows.keys():
		var row: Dictionary = _rows[spell_id]
		var lv := HPRules.skill_level_of(levels, spell_id)
		var master := HPRules.skill_is_master(lv)
		(row.icon as HudSlot).badge_text = HPRules.skill_level_label(lv)
		var level_label := row.level as Label
		level_label.text = "MASTER" if master else "Lv. %d" % lv
		level_label.add_theme_color_override("font_color", HudKit.GOLD_HI if master else HudKit.GOLD_LT)
		(row.pips as SkillPips).set_level(lv, HPRules.skill_max_level())
		(row.effect as Label).text = _effect_text(spell_id, lv)
		var b := row.button as Button
		b.disabled = master or lv >= HPRules.skill_max_level() or points <= 0
		b.modulate.a = 0.3 if b.disabled else 1.0
		b.tooltip_text = "Mastered" if master else ("Spend 1 point: Lv. %d -> %s" % [lv, HPRules.skill_level_label(lv + 1)] if points > 0 else "Gain a level to earn a skill point")

## Current numbers, and what the next point changes.
func _effect_text(spell_id: String, lv: int) -> String:
	var out := "  ·  ".join(_effect_parts(spell_id, lv))
	if lv < HPRules.skill_max_level():
		var label := "Master" if HPRules.skill_is_master(lv + 1) else "Next"
		out += "\n%s: %s" % [label, "  ·  ".join(_effect_parts(spell_id, lv + 1))]
	return out

func _effect_parts(spell_id: String, lv: int) -> Array:
	var spell: Dictionary = HPRules.spell(spell_id)
	var parts: Array = []
	if int(spell.get("damage", 0)) > 0:
		parts.append("Damage x%.2f" % HPRules.skill_damage_multiplier(lv))
	parts.append("Cooldown %.1fs" % HPRules.cooldown_for(spell_id, String(player.house), lv))
	if spell.has("duration_ms") or spell.has("stun_ms") or spell.has("weaken_ms"):
		parts.append("Effect x%.2f" % HPRules.skill_effect_multiplier(lv))
	return parts


## Ten small diamonds: lit up to the trained level, the last one is Master.
class SkillPips extends Control:
	var level := 1
	var max_level := 10

	func set_level(p_level: int, p_max: int) -> void:
		if p_level != level or p_max != max_level:
			level = p_level
			max_level = p_max
			queue_redraw()

	func _draw() -> void:
		var step := 14.0
		for i in range(max_level):
			var c := Vector2(5.0 + i * step, size.y * 0.5)
			var r := 4.0 if i < max_level - 1 else 5.0
			var pts := PackedVector2Array([c + Vector2(0, -r), c + Vector2(r, 0), c + Vector2(0, r), c + Vector2(-r, 0)])
			var lit := i < level
			var col := (HudKit.GOLD_HI if i == max_level - 1 else HudKit.GOLD_LT) if lit else Color(1, 1, 1, 0.12)
			draw_colored_polygon(pts, col)
			pts.append(pts[0])
			draw_polyline(pts, Color(0, 0, 0, 0.7), 1.0, true)
