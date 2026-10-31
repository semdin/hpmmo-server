extends HudWindow
class_name HudDungeonResult

## The end of a dungeon run: the medal (or none), the clock against the run's
## par, the clear and the deaths, and a replay - the leader starts another run
## on the same difficulty with the party still in the copy (the authority's
## ready check follows). Opened by HudDungeonRun from the run's `result`;
## what this player earned arrives as the authority's `rewards` event.

const MEDALS := {
	"gold": Color(0.92, 0.74, 0.30),
	"silver": Color(0.76, 0.80, 0.86),
	"bronze": Color(0.82, 0.54, 0.32),
	"": Color(0.45, 0.45, 0.50),
}

var player: Node = null
var _dungeon := ""
var _difficulty := "normal"
var _medal: MedalDisc
var _medal_name: Label
var _subtitle: Label
var _facts: GridContainer
var _earned: VBoxContainer
var _rewards: Dictionary = {}

func _init() -> void:
	super._init("Dungeon Complete", Vector2(460, 480))
	name = "DungeonResult"

func _ready() -> void:
	super._ready()
	var head := HBoxContainer.new()
	head.add_theme_constant_override("separation", 16)
	body.add_child(head)
	_medal = MedalDisc.new()
	head.add_child(_medal)
	var words := VBoxContainer.new()
	words.alignment = BoxContainer.ALIGNMENT_CENTER
	words.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	head.add_child(words)
	_medal_name = HudKit.label("", 30, HudKit.GOLD_HI, HudKit.title(), 4)
	words.add_child(_medal_name)
	_subtitle = HudKit.label("", 14, HudKit.TEXT_DIM, HudKit.body(), 3)
	_subtitle.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	words.add_child(_subtitle)
	_facts = GridContainer.new()
	_facts.columns = 2
	_facts.add_theme_constant_override("h_separation", 16)
	_facts.add_theme_constant_override("v_separation", 4)
	body.add_child(_facts)
	_earned = VBoxContainer.new()
	_earned.add_theme_constant_override("separation", 3)
	_earned.size_flags_vertical = Control.SIZE_EXPAND_FILL
	body.add_child(_earned)
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 10)
	body.add_child(row)
	var again := HudKit.button(tr("Run it again"), 15)
	again.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	again.custom_minimum_size = Vector2(0, 38)
	again.pressed.connect(_replay)
	row.add_child(again)
	var done := HudKit.button(tr("Close"), 15)
	done.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	done.custom_minimum_size = Vector2(0, 38)
	done.pressed.connect(close)
	row.add_child(done)
	SimAuthority.dungeon_event.connect(_on_event)

func _on_event(uid: int, event: Dictionary) -> void:
	if uid != SimAuthority.local_uid and SimAuthority.local_uid != 0:
		return
	match String(event.get("kind", "")):
		"launch":
			close()
			_rewards = {}
		"rewards":
			_rewards = event
			_show_rewards()

## Show the run's `state` (its `result` filled in).
func show_result(state: Dictionary) -> void:
	_dungeon = String(state.get("dungeon", ""))
	_difficulty = String(state.get("difficulty", "normal"))
	var result: Dictionary = state.get("result", {})
	var medal := String(result.get("medal", ""))
	var heading := "Time Is Up" if bool(result.get("timeout", false)) else "Dungeon Complete"  # i18n
	set_title(heading)
	var names := {"gold": tr("Gold"), "silver": tr("Silver"), "bronze": tr("Bronze"), "": tr("No medal")}
	_medal.tint = MEDALS.get(medal, MEDALS[""])
	_medal.queue_redraw()
	_medal_name.text = String(names.get(medal, names[""]))
	_medal_name.add_theme_color_override("font_color", MEDALS.get(medal, MEDALS[""]).lightened(0.2))
	var dungeon := HPMaps.dungeons().get(_dungeon, {}) as Dictionary
	_subtitle.text = "%s - %s" % [I18n.t(String(dungeon.get("display", ""))),
		I18n.t(String(HPRules.dungeon_difficulty(_difficulty).get("display", "")))]
	for child in _facts.get_children():
		child.queue_free()
	var medals := HPMaps.dungeon_rules("medals")
	var par := float(result.get("par_s", 0.0))
	_fact(tr("Time"), tr("%s (gold %s, silver %s, bronze %s)") % [HudDungeon._clock(float(result.get("time_s", 0.0))),
		HudDungeon._clock(par * float(medals.get("gold", 1.0))), HudDungeon._clock(par * float(medals.get("silver", 1.3))),
		HudDungeon._clock(par * float(medals.get("bronze", 1.6)))])
	_fact(tr("Clear"), tr("%d%%") % int(floor(float(result.get("clear", 0.0)) * 100.0)))
	_fact(tr("Deaths"), str(int(result.get("deaths", 0))))
	if medal == "":
		var why := tr("The run was too slow for a medal.")
		if bool(result.get("timeout", false)):
			why = tr("Time ran out (%s) - the run ended where it stood.") % HudDungeon._clock(par * float(medals.get("limit", 2.0)))
		elif float(result.get("clear", 0.0)) < 1.0:
			why = tr("A medal needs every creature cleared, side rooms included.")
		elif bool(state.get("broken", false)):
			why = tr("The party's lives ran out.")
		_fact("", why)
	_show_rewards()
	open()
	AudioManager.play_sound_at("ui_confirm" if medal != "" else "ui_open", Vector3.ZERO, null, true)

## What this player earned: experience, galleons, the final chest's contents
## (it waits at the end of the dungeon), a difficulty newly opened.
func _show_rewards() -> void:
	if _earned == null:
		return
	for child in _earned.get_children():
		child.queue_free()
	if _rewards.is_empty():
		return
	_line(I18n.upper(tr("Your rewards")), HudKit.GOLD_LT)
	if bool(_rewards.get("helper", false)):
		_line(tr("You came as a helper: no final chest today."), HudKit.GOLD_LT)
	else:
		_line(tr("+%d EXP") % int(_rewards.get("exp", 0)), Color(0.5, 1.0, 0.6))
		_line(tr("+%d Galleons") % int(_rewards.get("galleons", 0)), Color(1.0, 0.85, 0.35))
		var parts: Array[String] = []
		for item in _rewards.get("items", []):
			var item_name := I18n.t(String(HPEquipment.item(String(item.get("id", ""))).get("name", item.get("id", ""))))
			if int(item.get("bonuses", 0)) > 0:
				item_name += " " + tr("(%d enchantments)") % int(item["bonuses"])
			parts.append(item_name if int(item.get("amount", 1)) == 1 else "%s x%d" % [item_name, int(item["amount"])])
		if not parts.is_empty():
			_line(tr("In your chest: %s") % ", ".join(PackedStringArray(parts)), HudKit.PARCHMENT)
	for id in _rewards.get("unlocked", []):
		_line(tr("Unlocked: %s") % I18n.t(String(HPRules.dungeon_difficulty(String(id)).get("display", id))), HudDungeon.COLOURS.get(String(id), HudKit.GREEN))

func _line(text: String, colour: Color) -> void:
	var label := HudKit.label(text, 14, colour, HudKit.bold(), 2)
	label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_earned.add_child(label)

func _fact(key: String, value: String) -> void:
	_facts.add_child(HudKit.label(key, 14, HudKit.TEXT_DIM, HudKit.body(), 2))
	var v := HudKit.label(value, 15, HudKit.PARCHMENT, HudKit.bold(), 2)
	v.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	v.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_facts.add_child(v)

## Another run of the same dungeon and difficulty from inside the finished copy.
func _replay() -> void:
	if not is_instance_valid(player):
		return
	var map := String((HPMaps.dungeons().get(_dungeon, {}) as Dictionary).get("map", ""))
	for portal in HPMaps.portals():
		if String(portal.get("to_map", "")) == map and not HPMaps.is_instanced(String(portal.get("map_id", ""))):
			SimNet.dungeon_start(player, String(portal.get("id", "")), _difficulty)
			return


## The medal: a struck disc in its metal with a ring and a star.
class MedalDisc extends Control:
	var tint := Color(0.92, 0.74, 0.30)

	func _init() -> void:
		custom_minimum_size = Vector2(84, 84)
		mouse_filter = Control.MOUSE_FILTER_IGNORE

	func _draw() -> void:
		var c := size * 0.5
		var r := minf(size.x, size.y) * 0.5 - 4.0
		draw_circle(c, r + 4.0, Color(tint.r, tint.g, tint.b, 0.25))
		draw_circle(c, r, tint.darkened(0.35))
		draw_circle(c + Vector2(-r * 0.15, -r * 0.18), r * 0.8, tint)
		draw_arc(c, r - 5.0, 0.0, TAU, 48, tint.lightened(0.45), 2.0, true)
		var points := PackedVector2Array()
		for i in 10:
			var a := -PI * 0.5 + TAU * float(i) / 10.0
			points.append(c + Vector2(cos(a), sin(a)) * (r * (0.5 if i % 2 == 0 else 0.22)))
		draw_colored_polygon(points, tint.lightened(0.55))
