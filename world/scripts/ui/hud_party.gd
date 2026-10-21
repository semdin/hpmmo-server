extends Control
class_name HudParty

## Party frames under the player's own frame, and the invitation prompt.
##
## Everything shown comes from the authority: `SimAuthority.party_state`
## (members, leader, live health and mana once a second) and `party_invited`. Answers
## travel as chat commands (`/accept`, `/decline`), so the prompt is a thin
## shortcut over what can also be typed.

const ROW_W := 190.0
const ROW_H := 46.0

var _rows: VBoxContainer
var _prompt: PanelContainer
var _prompt_text: Label
var _state: Dictionary = {"party_id": 0}

func _init() -> void:
	name = "PartyFrames"
	mouse_filter = Control.MOUSE_FILTER_IGNORE

func _ready() -> void:
	set_anchors_preset(Control.PRESET_TOP_LEFT)
	position = Vector2(14.0, 178.0)
	_rows = VBoxContainer.new()
	_rows.add_theme_constant_override("separation", 4)
	_rows.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(_rows)
	_build_prompt()
	SimAuthority.party_state.connect(_on_party_state)
	SimAuthority.party_invited.connect(_on_party_invited)

func _is_local(uid: int) -> bool:
	return uid == SimAuthority.local_uid or SimAuthority.local_uid == 0

func _on_party_state(uid: int, state: Dictionary) -> void:
	if not _is_local(uid):
		return
	_state = state
	_rebuild()

## The members other than the local player, leader first.
func shown_members() -> Array:
	var out: Array = []
	for m in _state.get("members", []):
		if int((m as Dictionary).get("uid", 0)) != SimAuthority.local_uid:
			out.append(m)
	out.sort_custom(func(a, b): return int(a["uid"]) == int(_state.get("leader", 0)) and int(b["uid"]) != int(_state.get("leader", 0)))
	return out

func _rebuild() -> void:
	for child in _rows.get_children():
		child.queue_free()
	if int(_state.get("party_id", 0)) == 0:
		return
	var local_map := String(SimAuthority.local_map)
	for m in shown_members():
		_rows.add_child(_member_row(m, int(m["uid"]) == int(_state.get("leader", 0)), String(m.get("map_id", "")) != local_map))

func _member_row(m: Dictionary, leader: bool, away: bool) -> Control:
	var panel := PanelContainer.new()
	panel.custom_minimum_size = Vector2(ROW_W, ROW_H)
	panel.add_theme_stylebox_override("panel", HudKit.panel(0.78, 5, 0.6))
	panel.mouse_filter = Control.MOUSE_FILTER_IGNORE
	var box := VBoxContainer.new()
	box.add_theme_constant_override("separation", 1)
	panel.add_child(box)
	var name_text := "%s%s  Lv %d" % ["* " if leader else "", String(m.get("name", "?")), int(m.get("level", 1))]
	var colour := HudKit.GOLD_HI if leader else HudKit.PARCHMENT
	var label := HudKit.label(name_text, 13, colour, HudKit.bold(), 3)
	box.add_child(label)
	var bar := ProgressBar.new()
	bar.show_percentage = false
	bar.custom_minimum_size = Vector2(ROW_W - 12.0, 9.0)
	bar.max_value = maxf(1.0, float(m.get("max_hp", 1)))
	bar.value = float(m.get("hp", 0))
	HudKit.style_gauge(bar, Color(0.75, 0.18, 0.16))
	box.add_child(bar)
	var mana := ProgressBar.new()
	mana.show_percentage = false
	mana.custom_minimum_size = Vector2(ROW_W - 12.0, 6.0)
	mana.max_value = maxf(1.0, float(m.get("max_mana", 1)))
	mana.value = float(m.get("mana", 0))
	HudKit.style_gauge(mana, Color(0.18, 0.42, 0.92))
	box.add_child(mana)
	if bool(m.get("dead", false)) or away:
		panel.modulate = Color(1, 1, 1, 0.45)
	return panel

func _build_prompt() -> void:
	_prompt = PanelContainer.new()
	_prompt.name = "PartyInvite"
	_prompt.add_theme_stylebox_override("panel", HudKit.window())
	_prompt.visible = false
	_prompt.position = Vector2(0.0, -6.0)
	add_child(_prompt)
	var box := VBoxContainer.new()
	box.add_theme_constant_override("separation", 6)
	_prompt.add_child(box)
	_prompt_text = HudKit.label("", 14, HudKit.PARCHMENT, HudKit.body(), 2)
	box.add_child(_prompt_text)
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 8)
	box.add_child(row)
	var yes := HudKit.button("Accept", 14)
	yes.pressed.connect(func(): answer(true))
	row.add_child(yes)
	var no := HudKit.button("Decline", 14)
	no.pressed.connect(func(): answer(false))
	row.add_child(no)

func _on_party_invited(uid: int, from_name: String) -> void:
	if not _is_local(uid):
		return
	_prompt_text.text = "%s invites you to a party." % from_name
	_prompt.visible = true

func answer(accept: bool) -> void:
	_prompt.visible = false
	NetworkManager.send_chat("/accept" if accept else "/decline")

func invite_pending() -> bool:
	return _prompt.visible
