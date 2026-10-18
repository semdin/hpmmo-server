extends HudWindow
class_name HudSkillPick

## Onboarding: a brand-new character learns no spell until it picks one. This
## window opens on its own while the character has learned nothing and holds a
## skill point (HPRules.skill_points_available counts the level-1 point for
## exactly this pick): one card per upgradeable spell, "Learn" spends the point
## through the same request as the skill window (SimNet.submit_skill_up). The
## basic attack needs no pick.

const CARD_W := 170.0

var player: Node3D = null
var hud: Control = null
var _offered := false

func _init() -> void:
	super._init("Choose Your First Spell", Vector2(3 * (CARD_W + 12) + 48, 470))
	name = "SkillPick"
	modal = false

func _ready() -> void:
	super._ready()
	var intro := HudKit.label("Every wizard starts with one spell of their own. Pick it now - every level after this earns a skill point to learn or train more (V).",
		15, HudKit.PARCHMENT, HudKit.body(), 0)
	intro.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	intro.custom_minimum_size = Vector2(3 * (CARD_W + 12), 0)
	body.add_child(intro)
	var grid := GridContainer.new()
	grid.columns = 3
	grid.add_theme_constant_override("h_separation", 12)
	grid.add_theme_constant_override("v_separation", 12)
	body.add_child(grid)
	for spell_id in HPRules.upgradeable_skills():
		grid.add_child(_card(String(spell_id)))

func _card(spell_id: String) -> Control:
	var spell: Dictionary = HPRules.spell(spell_id)
	var panel := PanelContainer.new()
	panel.custom_minimum_size = Vector2(CARD_W, 0)
	var box := HudKit.panel(0.6, 5, 0.5).duplicate() as StyleBoxFlat
	box.set_content_margin_all(8)
	panel.add_theme_stylebox_override("panel", box)
	var col := VBoxContainer.new()
	col.add_theme_constant_override("separation", 6)
	panel.add_child(col)
	var icon := HudSlot.new(48.0)
	icon.icon_texture = UITheme.spell_icon(spell_id)
	icon.size_flags_horizontal = Control.SIZE_SHRINK_CENTER
	col.add_child(icon)
	var name_label := HudKit.label(String(spell.get("name", spell_id)), 16, HudKit.GOLD_LT, HudKit.bold(), 3)
	name_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	col.add_child(name_label)
	var desc := HudKit.label(String(spell.get("desc", "")), 12, HudKit.TEXT_DIM, HudKit.body(), 0)
	desc.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	desc.custom_minimum_size = Vector2(CARD_W - 16, 0)
	col.add_child(desc)
	var learn := HudKit.button("Learn", 15)
	learn.focus_mode = Control.FOCUS_NONE
	learn.pressed.connect(_learn.bind(spell_id))
	col.add_child(learn)
	return panel

func _learn(spell_id: String) -> void:
	if not is_instance_valid(player):
		return
	var result: Dictionary = SimNet.submit_skill_up(player, spell_id)
	if bool(result.get("ok", false)):
		close()
		if hud != null and hud.has_method("show_notice"):
			hud.show_notice("You learned %s! Train it further with V." % String(HPRules.spell(spell_id).get("name", spell_id)), "good")

## Open once per session while the character still has to pick.
func _process(_delta: float) -> void:
	if _offered or not is_instance_valid(player) or not bool(player.get("is_local_player")):
		return
	if (player.skill_levels as Dictionary).is_empty() and int(player.skill_points) > 0 and int(player.level) >= 1:
		_offered = true
		open()
