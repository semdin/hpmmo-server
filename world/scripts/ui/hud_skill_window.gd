extends HudWindow
class_name HudSkillWindow

## The skill window (V), laid out like an MMO spellbook: two columns of spell
## cards, each with the framed icon and its level plate ("1".."9", "M" for
## Master), the name, the grade, a ten-step progress row (the last step is the
## Master gem) and the "+" that spends a point. Spells that do not train
## (Expecto Patronum) sit in the same book, marked special. Every level the
## character gains is one skill point; "+" spends it, up to level 10 (Master).
## Cards drag onto the action bar to set the hotkeys.
##
## The tooltip is the window's own card, not Godot's: it opens beside the
## window, level with the hovered spell, after TIP_DELAY, and moving to another
## card swaps it at once.
##
## The window only asks: the authority checks the points and the cap
## (SimNet.submit_skill_up) and the result comes back in the stats payload,
## which this window reads off the player every frame it is open.

const ICON := 52.0
const COLUMNS := 2
const CARD_H := 70.0
const TIP_W := 300.0
## Seconds the pointer rests on a card before its tooltip opens.
const TIP_DELAY := 0.08
## Seconds the tooltip stays up once the pointer leaves a card, so crossing the
## gap to the next card swaps it instead of closing and reopening it.
const TIP_GRACE := 0.06
## Spells on the bar that do not train (shown last in the book, marked special).
const OTHER := ["patronum"]

const LINE := Color("2b3a55")
const FAINT := Color(0.435, 0.424, 0.400)
const RED_SOFT := Color(0.886, 0.404, 0.373)
const MANA := Color(0.612, 0.780, 1.0)
const NEXT := Color(0.55, 0.75, 1.0)
const NEXT_NUM := Color(0.78, 0.62, 1.0)
const EMBER := Color(1.0, 0.82, 0.45)

var player: Node3D = null
## The HUD, for notices (set by hud.gd).
var hud: Control = null
var _points: Label
var _points_box: PanelContainer
var _coin: PanelContainer
var _coin_box: StyleBoxFlat
var _cards: Dictionary = {}   # spell_id -> SkillCard
var _shown := ""
var _tip: PanelContainer
var _tip_body: VBoxContainer
var _tip_key := ""
var _hover_id := ""
var _hover_time := 0.0
var _away := 0.0
var _pulse := 0.0

func _init() -> void:
	super._init("Skills", Vector2(600, 458))
	name = "SkillWindow"
	modal = false

func _ready() -> void:
	super._ready()
	body.add_theme_constant_override("separation", 10)
	var head := HBoxContainer.new()
	head.add_theme_constant_override("separation", 8)
	body.add_child(head)
	head.add_child(_tab(tr("Spells")))
	var gap := Control.new()
	gap.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	gap.mouse_filter = Control.MOUSE_FILTER_IGNORE
	head.add_child(gap)
	head.add_child(_points_capsule())

	var book := PanelContainer.new()
	book.name = "Book"
	book.mouse_filter = Control.MOUSE_FILTER_IGNORE
	book.add_theme_stylebox_override("panel", _box(Color(0.016, 0.027, 0.051, 0.6), LINE, 4, 10))
	body.add_child(book)
	var grid := GridContainer.new()
	grid.columns = COLUMNS
	grid.add_theme_constant_override("h_separation", 8)
	grid.add_theme_constant_override("v_separation", 8)
	grid.mouse_filter = Control.MOUSE_FILTER_IGNORE
	book.add_child(grid)
	var ids: Array = HPRules.upgradeable_skills().duplicate()
	ids.append_array(OTHER.filter(func(id): return GameData.SPELLS.has(id) and not HPRules.skill_upgradeable(id)))
	for spell_id in ids:
		var card := SkillCard.new(self, String(spell_id))
		grid.add_child(card)
		_cards[String(spell_id)] = card

	var spacer := Control.new()
	spacer.size_flags_vertical = Control.SIZE_EXPAND_FILL
	spacer.mouse_filter = Control.MOUSE_FILTER_IGNORE
	body.add_child(spacer)
	var foot := HBoxContainer.new()
	foot.alignment = BoxContainer.ALIGNMENT_CENTER
	foot.add_theme_constant_override("separation", 6)
	body.add_child(foot)
	foot.add_child(_keycap(tr("Drag")))
	foot.add_child(HudKit.label(tr("onto the action bar"), 13, HudKit.TEXT_DIM, HudKit.body(), 0))
	var foot_gap := Control.new()
	foot_gap.custom_minimum_size = Vector2(16, 0)
	foot.add_child(foot_gap)
	foot.add_child(_keycap("+"))
	foot.add_child(HudKit.label(tr("spends a point"), 13, HudKit.TEXT_DIM, HudKit.body(), 0))

	# Added after the card, so it draws over the window.
	_tip = PanelContainer.new()
	_tip.name = "SkillTip"
	_tip.visible = false
	_tip.mouse_filter = Control.MOUSE_FILTER_IGNORE
	var tip_box := _box(Color(0.043, 0.067, 0.114, 0.98), HudKit.GOLD_DK, 4, 0)
	tip_box.content_margin_left = 13
	tip_box.content_margin_right = 13
	tip_box.content_margin_top = 11
	tip_box.content_margin_bottom = 10
	tip_box.shadow_color = Color(0, 0, 0, 0.6)
	tip_box.shadow_size = 10
	tip_box.shadow_offset = Vector2(0, 4)
	_tip.add_theme_stylebox_override("panel", tip_box)
	_tip_body = VBoxContainer.new()
	_tip_body.add_theme_constant_override("separation", 2)
	_tip_body.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_tip.add_child(_tip_body)
	add_child(_tip)

## The "Spells" page tab over the book.
func _tab(text: String) -> PanelContainer:
	var tab := PanelContainer.new()
	tab.mouse_filter = Control.MOUSE_FILTER_IGNORE
	var sb := _box(Color("1d2f4a"), HudKit.GOLD_DK, 4, 0)
	sb.corner_radius_bottom_left = 0
	sb.corner_radius_bottom_right = 0
	sb.content_margin_left = 14
	sb.content_margin_right = 14
	sb.content_margin_top = 4
	sb.content_margin_bottom = 5
	tab.add_theme_stylebox_override("panel", sb)
	tab.add_child(HudKit.label(text, 15, HudKit.GOLD_HI, HudKit.body(), 2))
	return tab

## The points counter: a coin with the count, lit and pulsing while there are
## points to spend.
func _points_capsule() -> PanelContainer:
	_points_box = PanelContainer.new()
	_points_box.name = "Points"
	_points_box.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_points_box.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 8)
	_points_box.add_child(row)
	_coin = PanelContainer.new()
	_coin.custom_minimum_size = Vector2(24, 24)
	_coin_box = _box(Color(0.12, 0.12, 0.12), Color(0.2, 0.2, 0.2), 12, 0)
	_coin_box.content_margin_left = 6   # a pill once the count has two digits
	_coin_box.content_margin_right = 6
	_coin.add_theme_stylebox_override("panel", _coin_box)
	row.add_child(_coin)
	_points = HudKit.label("0", 13, FAINT, HudKit.bold(), 0)
	_points.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_points.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	_coin.add_child(_points)
	row.add_child(HudKit.label(tr("Skill Points"), 13, HudKit.TEXT_DIM, HudKit.body(), 0))
	return _points_box

func _keycap(text: String) -> PanelContainer:
	var cap := PanelContainer.new()
	cap.mouse_filter = Control.MOUSE_FILTER_IGNORE
	cap.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	var sb := _box(Color("1a1409"), HudKit.GOLD_DK, 3, 0)
	sb.content_margin_left = 5
	sb.content_margin_right = 5
	cap.add_theme_stylebox_override("panel", sb)
	cap.add_child(HudKit.label(text, 11, HudKit.GOLD_LT, HudKit.bold(), 0))
	return cap

static func _box(bg: Color, border: Color, radius: int, margin: float) -> StyleBoxFlat:
	var sb := StyleBoxFlat.new()
	sb.bg_color = bg
	sb.border_color = border
	sb.set_border_width_all(1)
	sb.set_corner_radius_all(radius)
	sb.set_content_margin_all(margin)
	sb.anti_aliasing = true
	return sb

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
			HPProtocol.REJECT_LEVEL: tr("Your level is too low for this spell"),
		}
		if hud != null and hud.has_method("show_notice"):
			hud.show_notice(String(words.get(String(result.get("reason", "")), tr("Cannot train that now"))), "error")
	_refresh()
	return result

func open() -> void:
	super.open()
	_shown = ""
	_refresh()

func close() -> void:
	_hide_tip()
	super.close()

func _process(delta: float) -> void:
	if not visible:
		return
	_refresh()
	_update_tip(delta)
	if player != null and is_instance_valid(player) and int(player.skill_points) > 0:
		_pulse += delta
		_coin_box.shadow_size = int(round(2.0 + 4.0 * (0.5 + 0.5 * sin(_pulse * TAU / 1.8))))

func _refresh() -> void:
	if player == null or not is_instance_valid(player) or _points == null:
		return
	var levels: Dictionary = player.skill_levels
	var points: int = int(player.skill_points)
	var key := "%s|%d|%d" % [str(levels), points, int(player.level)]
	if key == _shown:
		return
	_shown = key
	_points.text = str(points)
	var has := points > 0
	_points.add_theme_color_override("font_color", Color(0.165, 0.102, 0.016) if has else FAINT)
	_coin_box.bg_color = Color(0.85, 0.62, 0.22) if has else Color(0.12, 0.12, 0.12)
	_coin_box.border_color = HudKit.GOLD_HI if has else Color(0.2, 0.2, 0.2)
	_coin_box.shadow_color = Color(1.0, 0.82, 0.47, 0.55) if has else Color(0, 0, 0, 0)
	_coin_box.shadow_size = 0
	var capsule := _box(Color(0.035, 0.051, 0.09), HudKit.GOLD_DK if has else LINE, 13, 0)
	capsule.content_margin_left = 4
	capsule.content_margin_right = 12
	capsule.content_margin_top = 3
	capsule.content_margin_bottom = 3
	_points_box.add_theme_stylebox_override("panel", capsule)
	for spell_id in _cards.keys():
		(_cards[spell_id] as SkillCard).refresh(points)

func _level(spell_id: String) -> int:
	if not HPRules.skill_upgradeable(spell_id):
		return 1 if int(player.level) >= HPRules.spell_required_level(spell_id) else 0
	return HPRules.skill_level_of(player.skill_levels, spell_id)

func _locked(spell_id: String) -> bool:
	return player != null and is_instance_valid(player) and int(player.level) < HPRules.spell_required_level(spell_id)

func _can_train(spell_id: String, points: int) -> bool:
	return HPRules.skill_upgradeable(spell_id) and points > 0 and not _locked(spell_id) \
			and _level(spell_id) < HPRules.skill_max_level()

# ----------------------------------------------------------------- tooltip

## Which card the pointer is on (respecting whatever window lies over this one),
## the hover delay, and the tooltip's place beside the window.
func _update_tip(delta: float) -> void:
	var id := ""
	if not get_viewport().gui_is_dragging():
		var over := get_viewport().gui_get_hovered_control()
		while over != null and over != self:
			if over is SkillCard:
				id = (over as SkillCard).spell_id
				break
			over = over.get_parent_control()
	for spell_id in _cards.keys():
		(_cards[spell_id] as SkillCard).hovered = spell_id == id
	if id == "":
		_away += delta
		if _away > TIP_GRACE:
			_hide_tip()
		return
	_away = 0.0
	if id != _hover_id:
		_hover_id = id
		_hover_time = TIP_DELAY if _tip.visible else 0.0
	else:
		_hover_time += delta
	if _hover_time < TIP_DELAY:
		return
	var key := id + "|" + _shown
	if key != _tip_key:
		_tip_key = key
		_fill_tip(id)
	_tip.visible = true
	_place_tip(_cards[id])

func _hide_tip() -> void:
	_hover_id = ""
	_hover_time = 0.0
	if _tip != null:
		_tip.visible = false

func _place_tip(spell_card: Control) -> void:
	_tip.reset_size()
	var tsz := _tip.get_combined_minimum_size()
	_tip.size = tsz
	var area := get_global_rect()
	var win := card.get_global_rect()
	var r := spell_card.get_global_rect()
	var x := win.end.x + 10.0
	if x + tsz.x > area.end.x - 8.0:
		x = win.position.x - tsz.x - 10.0
	if x < area.position.x + 8.0:
		x = minf(r.end.x + 10.0, area.end.x - tsz.x - 8.0)
	var y := clampf(r.position.y - 6.0, area.position.y + 8.0, maxf(area.position.y + 8.0, area.end.y - tsz.y - 8.0))
	_tip.global_position = Vector2(x, y)

## The tooltip card: name and grade, mana and cooldown, what the spell does,
## its numbers now and (in blue) at the next level with the gain in green.
func _fill_tip(spell_id: String) -> void:
	for child in _tip_body.get_children():
		_tip_body.remove_child(child)
		child.queue_free()
	var spell: Dictionary = HPRules.spell(spell_id)
	var trainable := HPRules.skill_upgradeable(spell_id)
	var lv := _level(spell_id)
	var shown_lv := maxi(1, lv)
	var locked := _locked(spell_id)
	var master := trainable and HPRules.skill_is_master(lv)
	var rank: String
	if not trainable:
		rank = tr("Special spell")
	elif master:
		rank = tr("Master")
	else:
		rank = tr("Not learned") if lv <= 0 else tr("Level %d") % lv
	_tip_body.add_child(_pair(_tl(I18n.t(String(spell.get("name", spell_id))), 17, HudKit.GOLD_HI),
			_tl(rank, 13, HudKit.GOLD_HI if master else HudKit.GOLD_LT, HudKit.bold() if master else null)))
	_tip_body.add_child(_pair(_tl(tr("%d Mana") % int(spell.get("mana_cost", 0)), 13, MANA),
			_tl(tr("%.1f s cooldown") % _cooldown(spell_id, shown_lv), 13, HudKit.TEXT)))
	_tip_body.add_child(_gap(5))
	_tip_body.add_child(_tl(I18n.t(String(spell.get("desc", ""))), 13, HudKit.PARCHMENT, null, true))
	_tip_body.add_child(_gap(4))
	for line in _control_lines(spell_id, shown_lv):
		_tip_body.add_child(_tl("◆ " + line, 13, EMBER, HudKit.bold(), true))
	var now := _stat_row(spell_id, shown_lv, -1, HudKit.TEXT)
	if now != null:
		_tip_body.add_child(_gap(3))
		_tip_body.add_child(now)
	if locked:
		_tip_body.add_child(_tl(tr("Requires level %d") % HPRules.spell_required_level(spell_id), 13, RED_SOFT, HudKit.bold()))
	if trainable and lv < HPRules.skill_max_level():
		var next := lv + 1
		_tip_body.add_child(_rule())
		_tip_body.add_child(_tl(tr("Next: Master") if HPRules.skill_is_master(next) else tr("Next level: %d") % next, 13, NEXT, HudKit.bold()))
		var later := _stat_row(spell_id, next, lv, NEXT_NUM)
		if later == null:
			later = GridContainer.new()
			later.columns = 2
		var cd := _tl(tr("Cooldown %.1f s") % _cooldown(spell_id, next), 13, NEXT_NUM)
		later.add_child(cd)
		_tip_body.add_child(later)
	if not trainable and not locked:
		_tip_body.add_child(_gap(4))
		_tip_body.add_child(_tl(tr("This spell does not train with points."), 12, FAINT, null, true))
	elif not locked:
		_tip_body.add_child(_gap(4))
		_tip_body.add_child(_tl(tr("Drag it onto the action bar"), 12, FAINT, null, true))

## "Damage 164%  Effect 136%" at skill level `lv`; with `was` >= 0 each figure
## carries its gain over level `was` in green. Null when the spell has neither.
func _stat_row(spell_id: String, lv: int, was: int, colour: Color) -> GridContainer:
	var spell: Dictionary = HPRules.spell(spell_id)
	var stats: Array = []
	if int(spell.get("damage", 0)) > 0:
		stats.append([tr("Damage %d%%"), HPRules.skill_damage_multiplier(lv), HPRules.skill_damage_multiplier(maxi(1, was))])
	if spell.has("duration_ms") or not _control_lines(spell_id, lv).is_empty():
		stats.append([tr("Effect %d%%"), HPRules.skill_effect_multiplier(lv), HPRules.skill_effect_multiplier(maxi(1, was))])
	if stats.is_empty():
		return null
	var grid := GridContainer.new()
	grid.columns = 2
	grid.add_theme_constant_override("h_separation", 18)
	grid.add_theme_constant_override("v_separation", 0)
	grid.mouse_filter = Control.MOUSE_FILTER_IGNORE
	for stat in stats:
		var row := HBoxContainer.new()
		row.add_theme_constant_override("separation", 5)
		row.mouse_filter = Control.MOUSE_FILTER_IGNORE
		var value := roundi(float(stat[1]) * 100.0)
		row.add_child(_tl(String(stat[0]) % value, 13, colour))
		if was >= 0:
			var gain := value - roundi(float(stat[2]) * 100.0)
			if gain > 0:
				row.add_child(_tl("+%d" % gain, 12, HudKit.GREEN))
		grid.add_child(row)
	return grid

func _cooldown(spell_id: String, lv: int) -> float:
	var house := String(player.house) if player != null and is_instance_valid(player) else ""
	var stats: Dictionary = player.derived_stats if player != null and is_instance_valid(player) else {}
	return HPRules.cooldown_for(spell_id, house, lv, stats)

func _tl(text: String, size: int, colour: Color, font: Font = null, wrap := false) -> Label:
	var l := HudKit.label(text, size, colour, font if font != null else HudKit.body(), 0)
	if wrap:
		l.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
		l.custom_minimum_size.x = TIP_W - 26.0
	return l

func _pair(left: Label, right: Label) -> HBoxContainer:
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 10)
	row.mouse_filter = Control.MOUSE_FILTER_IGNORE
	left.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	right.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	row.add_child(left)
	row.add_child(right)
	row.custom_minimum_size.x = TIP_W - 26.0
	return row

func _gap(px: float) -> Control:
	var c := Control.new()
	c.custom_minimum_size = Vector2(0, px)
	c.mouse_filter = Control.MOUSE_FILTER_IGNORE
	return c

## A thin gold rule that fades out at both ends.
func _rule() -> Control:
	var rule := RuleLine.new()
	rule.custom_minimum_size = Vector2(TIP_W - 26.0, 15)
	return rule


## What the spell does to an enemy besides damage (spells.json crowd control
## and damage over time), at skill level `lv`.
func _control_lines(spell_id: String, lv: int) -> Array:
	var spell: Dictionary = HPRules.spell(spell_id)
	var effect := HPRules.skill_effect_multiplier(lv)
	var out: Array = []
	if int(spell.get("stun_ms", 0)) > 0:
		out.append(tr("Stun %.1fs") % (float(spell.stun_ms) * effect / 1000.0))
	var launch: Dictionary = spell.get("launch", {})
	if not launch.is_empty():
		if int(launch.get("land_stun_ms", 0)) > 0:
			out.append(tr("Throws enemies, knocked down %.1fs") % (float(launch.land_stun_ms) * effect / 1000.0))
		else:
			out.append(tr("Knocks enemies back"))
	if int(spell.get("freeze_ms", 0)) > 0:
		out.append(tr("Freeze %.1fs") % (float(spell.freeze_ms) * effect / 1000.0))
	var slow: Dictionary = spell.get("slow", {})
	if not slow.is_empty():
		out.append(tr("Slow %d%% for %.1fs") % [roundi((1.0 - float(slow.get("factor", 1.0))) * 100.0), float(slow.get("ms", 0)) * effect / 1000.0])
	var bleed: Dictionary = spell.get("bleed", {})
	if not bleed.is_empty():
		out.append(tr("Bleed %d x %d") % [int(bleed.get("damage", 0)), int(bleed.get("ticks", 0))])
	var burn: Dictionary = spell.get("burn", {})
	if not burn.is_empty():
		out.append(tr("Burn %d x %d") % [int(burn.get("damage", 0)), int(burn.get("ticks", 0))])
	if int(spell.get("weaken_ms", 0)) > 0:
		out.append(tr("Disarm %.1fs") % (float(spell.weaken_ms) * effect / 1000.0))
	return out


## One spell in the book: framed icon with its level plate, name, grade line,
## progress pips and the "+" (or a star once mastered / for special spells).
## The whole card drags onto the action bar ({"id", "spell_slot": -1}).
class SkillCard extends PanelContainer:
	var window: HudSkillWindow
	var spell_id := ""
	var slot: HudSlot
	var lock: SkillMark
	var name_label: Label
	var grade: HBoxContainer
	var pips: SkillPips
	var train_button: Button
	var seal: SkillMark
	var locked := false
	var hovered := false:
		set(value):
			if value != hovered:
				hovered = value
				_restyle()

	func _init(p_window: HudSkillWindow, p_spell_id: String) -> void:
		window = p_window
		spell_id = p_spell_id
		name = "Card_" + p_spell_id
		custom_minimum_size = Vector2(0, HudSkillWindow.CARD_H)
		size_flags_horizontal = Control.SIZE_EXPAND_FILL
		mouse_filter = Control.MOUSE_FILTER_STOP
		mouse_default_cursor_shape = Control.CURSOR_DRAG
		var row := HBoxContainer.new()
		row.add_theme_constant_override("separation", 11)
		row.mouse_filter = Control.MOUSE_FILTER_IGNORE
		add_child(row)

		slot = HudSlot.new(HudSkillWindow.ICON)
		slot.name = "Icon"
		slot.mouse_filter = Control.MOUSE_FILTER_PASS   # the card drags and hovers
		slot.icon_texture = UITheme.spell_icon(p_spell_id)
		slot.held_id = p_spell_id
		slot.size_flags_vertical = Control.SIZE_SHRINK_CENTER
		row.add_child(slot)
		lock = SkillMark.new("lock")
		lock.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
		slot.add_child(lock)

		var info := VBoxContainer.new()
		info.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		info.size_flags_vertical = Control.SIZE_SHRINK_CENTER
		info.add_theme_constant_override("separation", 3)
		info.mouse_filter = Control.MOUSE_FILTER_IGNORE
		row.add_child(info)
		name_label = HudKit.label(I18n.t(String(HPRules.spell(p_spell_id).get("name", p_spell_id))), 16, HudKit.GOLD_LT, HudKit.body(), 2)
		name_label.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
		name_label.custom_minimum_size.x = 60
		info.add_child(name_label)
		grade = HBoxContainer.new()
		grade.add_theme_constant_override("separation", 6)
		grade.mouse_filter = Control.MOUSE_FILTER_IGNORE
		info.add_child(grade)
		pips = SkillPips.new()
		info.add_child(pips)

		train_button = Button.new()
		train_button.name = "Train"
		train_button.text = "+"
		train_button.focus_mode = Control.FOCUS_NONE
		train_button.custom_minimum_size = Vector2(28, 28)
		train_button.size_flags_vertical = Control.SIZE_SHRINK_CENTER
		train_button.mouse_default_cursor_shape = Control.CURSOR_POINTING_HAND
		train_button.add_theme_font_override("font", HudKit.body())
		train_button.add_theme_font_size_override("font_size", 20)
		train_button.add_theme_color_override("font_color", HudKit.GOLD_HI)
		train_button.add_theme_color_override("font_hover_color", HudKit.GOLD_HI)
		train_button.add_theme_color_override("font_pressed_color", HudKit.GOLD_HI)
		train_button.add_theme_color_override("font_disabled_color", Color("3b465c"))
		var looks := {"normal": Color("5a3e0e"), "hover": Color("8a611a"), "pressed": Color("44300a"), "disabled": Color("0d1320")}
		for state in looks:
			var box := HudSkillWindow._box(looks[state], Color("283247") if state == "disabled" else HudKit.GOLD_LT, 4, 0)
			if state != "disabled":
				box.shadow_color = Color(0.91, 0.78, 0.48, 0.25)
				box.shadow_size = 4
			train_button.add_theme_stylebox_override(state, box)
		train_button.pressed.connect(func(): window.train(spell_id))
		row.add_child(train_button)
		seal = SkillMark.new("star")
		seal.custom_minimum_size = Vector2(28, 28)
		seal.size_flags_vertical = Control.SIZE_SHRINK_CENTER
		row.add_child(seal)
		_restyle()

	func refresh(points: int) -> void:
		var trainable := HPRules.skill_upgradeable(spell_id)
		var lv := window._level(spell_id)
		var top := HPRules.skill_max_level()
		var master := trainable and HPRules.skill_is_master(lv)
		var was_locked := locked
		locked = window._locked(spell_id)
		var can := window._can_train(spell_id, points)
		slot.badge_text = HPRules.skill_level_label(lv) if trainable and not locked and lv > 0 else ""
		slot.unusable = locked or lv <= 0
		lock.visible = locked
		name_label.add_theme_color_override("font_color", Color(0.553, 0.541, 0.514) if locked else HudKit.GOLD_LT)
		for child in grade.get_children():
			grade.remove_child(child)
			child.queue_free()
		if locked:
			grade.add_child(HudKit.label(tr("Requires level %d") % HPRules.spell_required_level(spell_id), 13, HudSkillWindow.RED_SOFT, HudKit.body(), 0))
		elif not trainable:
			grade.add_child(_tag(I18n.upper(tr("Special"))))
			grade.add_child(HudKit.label(tr("Not trainable"), 13, HudKit.TEXT_DIM, HudKit.body(), 0))
		elif master:
			grade.add_child(HudKit.label(I18n.upper(tr("Master")), 13, HudKit.GOLD_HI, HudKit.bold(), 0))
		elif lv <= 0:
			grade.add_child(HudKit.label(tr("Not learned"), 13, HudKit.TEXT_DIM, HudKit.body(), 0))
		else:
			grade.add_child(HudKit.label(tr("Level %d") % lv, 13, HudKit.TEXT_DIM, HudKit.body(), 0))
			grade.add_child(HudKit.label("/ %d" % top, 13, HudSkillWindow.FAINT, HudKit.body(), 0))
		pips.visible = trainable
		pips.filled = 0 if locked else lv
		pips.top = top
		pips.glow = can
		train_button.visible = trainable and not master
		train_button.disabled = not can
		seal.visible = not locked and (master or not trainable)
		seal.modulate.a = 0.85 if master else 0.45
		if was_locked != locked:
			_restyle()

	func _tag(text: String) -> PanelContainer:
		var tag := PanelContainer.new()
		tag.mouse_filter = Control.MOUSE_FILTER_IGNORE
		tag.size_flags_vertical = Control.SIZE_SHRINK_CENTER
		var sb := HudSkillWindow._box(Color(0.235, 0.353, 0.549, 0.25), Color("3d5274"), 3, 0)
		sb.content_margin_left = 5
		sb.content_margin_right = 5
		tag.add_theme_stylebox_override("panel", sb)
		tag.add_child(HudKit.label(text, 10, Color("c8d4ea"), HudKit.bold(), 0))
		return tag

	func _restyle() -> void:
		var border := Color("23324c")
		var bg := Color(0.09, 0.149, 0.231, 0.55)
		if hovered:
			border = Color("4a4f5c") if locked else HudKit.GOLD
			bg = Color(0.149, 0.212, 0.314, 0.65)
		var sb := HudSkillWindow._box(bg, border, 4, 0)
		sb.content_margin_left = 9
		sb.content_margin_right = 10
		add_theme_stylebox_override("panel", sb)

	func _get_drag_data(_at: Vector2) -> Variant:
		if locked or window._level(spell_id) <= 0:
			return null
		var preview := TextureRect.new()
		preview.texture = slot.icon_texture
		preview.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
		preview.size = slot.size
		preview.position = -slot.size * 0.5
		preview.modulate = Color(1, 1, 1, 0.85)
		var holder := Control.new()
		holder.add_child(preview)
		set_drag_preview(holder)
		return {"id": spell_id, "spell_slot": -1}


## The ten-step progress row: nine bars, then the Master gem. The step the
## next point would buy pulses while it can be bought.
class SkillPips extends Control:
	const BAR := Vector2(10, 5)
	const STEP := 13.0
	const GEM := 9.0
	var filled := 0:
		set(value):
			if value != filled:
				filled = value
				queue_redraw()
	var top := 10
	var glow := false:
		set(value):
			if value != glow:
				glow = value
				queue_redraw()
	var _t := 0.0

	func _init() -> void:
		custom_minimum_size = Vector2(STEP * 9.0 + GEM + 6.0, 10)
		mouse_filter = Control.MOUSE_FILTER_IGNORE

	func _process(delta: float) -> void:
		if glow and is_visible_in_tree():
			_t += delta
			queue_redraw()

	func _draw() -> void:
		var pulse := 0.5 + 0.5 * sin(_t * TAU / 1.2)
		var y := (size.y - BAR.y) * 0.5
		for i in range(1, top):
			var r := Rect2(Vector2((i - 1) * STEP, y), BAR)
			_step(r, i, pulse, false)
		var c := Vector2((top - 1) * STEP + 3.0 + GEM * 0.5, size.y * 0.5)
		_step(Rect2(c - Vector2.ONE * GEM * 0.5, Vector2.ONE * GEM), top, pulse, true)

	func _step(r: Rect2, i: int, pulse: float, gem: bool) -> void:
		var on := i <= filled
		var next := glow and i == filled + 1
		var fill := Color(0.039, 0.059, 0.098)
		var edge := Color(0.173, 0.227, 0.322)
		if on:
			fill = Color(0.88, 0.69, 0.33)
			edge = Color(0.914, 0.788, 0.478)
		elif next:
			fill = Color(1.0, 0.86, 0.55, 0.45 * pulse)
			edge = HudKit.GOLD_LT
		if gem:
			var c := r.get_center()
			var h := r.size.x * 0.62
			var pts := PackedVector2Array([c + Vector2(0, -h), c + Vector2(h, 0), c + Vector2(0, h), c + Vector2(-h, 0)])
			if on:
				draw_circle(c, h * 1.4, Color(1.0, 0.82, 0.47, 0.25))
			draw_colored_polygon(pts, fill)
			pts.append(pts[0])
			draw_polyline(pts, edge, 1.0, true)
		else:
			draw_rect(r, fill)
			draw_rect(r, edge, false, 1.0)
			if on:
				draw_line(r.position + Vector2(1, 1), r.position + Vector2(r.size.x - 1, 1), Color(1, 0.95, 0.75, 0.8))


## Small drawn marks: "lock" over a spell the character's level has not
## reached, "star" where a mastered or special spell would have its "+".
class SkillMark extends Control:
	var kind := ""

	func _init(p_kind: String) -> void:
		kind = p_kind
		mouse_filter = Control.MOUSE_FILTER_IGNORE

	func _draw() -> void:
		var c := size * 0.5
		if kind == "lock":
			var colour := Color(0.79, 0.76, 0.69)
			draw_rect(Rect2(c + Vector2(-7, -1), Vector2(14, 10)), colour)
			draw_arc(c + Vector2(0, -2), 4.5, PI, TAU, 12, colour, 2.0, true)
			draw_line(c + Vector2(-4.5, -2), c + Vector2(-4.5, -1), colour, 2.0)
			draw_line(c + Vector2(4.5, -2), c + Vector2(4.5, -1), colour, 2.0)
		else:
			var pts := PackedVector2Array()
			for i in 10:
				var radius := 9.0 if i % 2 == 0 else 4.0
				var a := -PI * 0.5 + i * PI / 5.0
				pts.append(c + Vector2(cos(a), sin(a)) * radius)
			draw_colored_polygon(pts, HudKit.GOLD)


## The tooltip's divider: a 1 px gold line fading out at both ends.
class RuleLine extends Control:
	func _init() -> void:
		mouse_filter = Control.MOUSE_FILTER_IGNORE

	func _draw() -> void:
		var y := size.y * 0.5
		var steps := 24
		for i in steps:
			var t := (i + 0.5) / steps
			var a := 1.0 - absf(t - 0.5) * 2.0
			draw_line(Vector2(size.x * i / steps, y), Vector2(size.x * (i + 1) / steps, y), Color(HudKit.GOLD_DK, a), 1.0)
