extends Control
class_name HudPlayerMenu

## The menu a right click on another player opens, at the cursor: invite to
## the party, challenge to a duel, call a group duel. Every entry sends the chat
## command the player could type (`/invite`, `/duel`, `/gduel`); the authority
## checks everything again and answers in the chat.
##
## Entries that cannot apply right now stay listed but dimmed, with the reason
## under them, so the options are always discoverable.

const MENU_W := 238.0
## Farther than this (or gone) and the menu closes by itself.
const KEEP_RANGE := 40.0
const DUEL_ACCENT := Color(1.0, 0.40, 0.32)
const GROUP_ACCENT := Color(1.0, 0.58, 0.24)
const PARTY_ACCENT := Color(0.46, 0.74, 1.0)

## Set by the HUD: the local player (range check, duel state) and the party
## frames (party membership and leadership).
var player: Node3D = null
var party_frames: HudParty = null

var _target: Node3D = null
var _panel: PanelContainer
var _column: VBoxContainer

func _init() -> void:
	name = "PlayerMenu"
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	visible = false

func _ready() -> void:
	set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	_panel = PanelContainer.new()
	_panel.name = "Panel"
	_panel.mouse_filter = Control.MOUSE_FILTER_STOP
	var box := StyleBoxFlat.new()
	box.bg_color = Color(0.031, 0.040, 0.067, 0.97)
	box.border_color = HudKit.GOLD
	box.set_border_width_all(1)
	box.set_corner_radius_all(8)
	box.shadow_color = Color(0, 0, 0, 0.6)
	box.shadow_size = 12
	box.shadow_offset = Vector2(0, 4)
	box.set_content_margin_all(6)
	box.anti_aliasing = true
	_panel.add_theme_stylebox_override("panel", box)
	add_child(_panel)
	_column = VBoxContainer.new()
	_column.add_theme_constant_override("separation", 2)
	_column.custom_minimum_size = Vector2(MENU_W, 0)
	_panel.add_child(_column)

## Open for `target` (another player's body) at the cursor.
func open(target: Node3D) -> void:
	if target == null or not is_instance_valid(target) or target == player:
		return
	_target = target
	for child in _column.get_children():
		child.queue_free()
	var who := String(target.get("player_name"))
	_column.add_child(_header(who, int(target.get("level")), String(target.get("house"))))
	var in_mine := _in_my_party(who)
	var in_duel := _local_in_duel()
	var duel_hint := tr("You are already in a duel.") if in_duel else ""
	_column.add_child(_entry(tr("Invite to Party"), PARTY_ACCENT, "/invite %s" % who,
		tr("Already in your party.") if in_mine else ""))
	_column.add_child(_entry(tr("Challenge to Duel"), DUEL_ACCENT, "/duel %s" % who, duel_hint))
	var group_hint := duel_hint
	if group_hint == "":
		if party_frames == null or not party_frames.in_party():
			group_hint = tr("You need a party.")
		elif not party_frames.is_leader():
			group_hint = tr("Only the party leader can call it.")
		elif in_mine:
			group_hint = tr("They are in your party.")
	_column.add_child(_entry(tr("Group Duel"), GROUP_ACCENT, "/gduel %s" % who, group_hint))
	visible = true
	_panel.modulate.a = 0.0   # placed once its size is known, next frame
	_panel.reset_size()
	await get_tree().process_frame
	if not visible:
		return
	var at := get_local_mouse_position() + Vector2(10, 6)
	var room := get_viewport_rect().size - _panel.size - Vector2(8, 8)
	_panel.position = Vector2(clampf(at.x, 8.0, maxf(8.0, room.x)), clampf(at.y, 8.0, maxf(8.0, room.y)))
	_panel.modulate.a = 1.0

func close() -> void:
	visible = false
	_target = null

func is_open() -> bool:
	return visible

func _process(_delta: float) -> void:
	if not visible:
		return
	if _target == null or not is_instance_valid(_target) or (is_instance_valid(player) \
			and player.global_position.distance_to(_target.global_position) > KEEP_RANGE):
		close()

func _input(event: InputEvent) -> void:
	if not visible:
		return
	if event is InputEventMouseButton and event.pressed \
			and not _panel.get_global_rect().has_point(event.position):
		close()   # a click anywhere else closes it (and still does its own thing)
	elif event is InputEventKey and event.pressed and event.keycode == KEY_ESCAPE:
		close()
		get_viewport().set_input_as_handled()

## The local player is in a duel (the HUD duel view knows; the rules' foe table
## only lists standing duelists once the fight is on).
func _local_in_duel() -> bool:
	var hud := get_parent()
	return hud != null and "duel_view" in hud and hud.duel_view != null and hud.duel_view.active()

func _in_my_party(who: String) -> bool:
	if party_frames == null:
		return false
	for m in party_frames.shown_members():
		if String((m as Dictionary).get("name", "")) == who:
			return true
	return false

func _header(who: String, level: int, house: String) -> Control:
	var box := VBoxContainer.new()
	box.add_theme_constant_override("separation", 0)
	box.mouse_filter = Control.MOUSE_FILTER_IGNORE
	var margin := MarginContainer.new()
	margin.add_theme_constant_override("margin_left", 8)
	margin.add_theme_constant_override("margin_right", 8)
	margin.add_theme_constant_override("margin_top", 4)
	margin.add_theme_constant_override("margin_bottom", 6)
	margin.mouse_filter = Control.MOUSE_FILTER_IGNORE
	margin.add_child(box)
	box.add_child(HudKit.label(who, 17, HudKit.GOLD_HI, HudKit.title(), 4))
	var sub := tr("Lv. %d  ·  %s") % [level, house] if house != "" else tr("Lv. %d") % level
	box.add_child(HudKit.label(sub, 13, HudKit.TEXT_DIM, HudKit.body(), 3))
	var rule := ColorRect.new()
	rule.color = Color(HudKit.GOLD.r, HudKit.GOLD.g, HudKit.GOLD.b, 0.45)
	rule.custom_minimum_size = Vector2(0, 1)
	rule.mouse_filter = Control.MOUSE_FILTER_IGNORE
	box.add_child(rule)
	return margin

## One entry: a coloured pip, the label, and (when it cannot apply) the reason.
func _entry(text: String, accent: Color, command: String, blocked: String) -> Control:
	var b := Button.new()
	b.focus_mode = Control.FOCUS_NONE
	b.alignment = HORIZONTAL_ALIGNMENT_LEFT
	b.text = text
	b.disabled = blocked != ""
	b.custom_minimum_size = Vector2(MENU_W, 50 if blocked != "" else 32)
	b.vertical_icon_alignment = VERTICAL_ALIGNMENT_TOP
	for state in ["normal", "hover", "pressed", "disabled", "focus"]:
		var sb := StyleBoxFlat.new()
		sb.set_corner_radius_all(5)
		sb.content_margin_left = 26
		sb.content_margin_right = 10
		sb.content_margin_top = 4
		sb.content_margin_bottom = 22 if blocked != "" else 4
		sb.anti_aliasing = true
		match state:
			"hover":
				sb.bg_color = Color(accent.r, accent.g, accent.b, 0.16)
				sb.border_color = Color(accent.r, accent.g, accent.b, 0.7)
				sb.border_width_left = 2
			"pressed":
				sb.bg_color = Color(accent.r, accent.g, accent.b, 0.26)
			"focus":
				sb.draw_center = false
			_:
				sb.bg_color = Color(0, 0, 0, 0)
		b.add_theme_stylebox_override(state, sb)
	b.add_theme_font_override("font", HudKit.bold())
	b.add_theme_font_size_override("font_size", 15)
	b.add_theme_color_override("font_color", HudKit.PARCHMENT)
	b.add_theme_color_override("font_hover_color", accent.lerp(Color.WHITE, 0.55))
	b.add_theme_color_override("font_pressed_color", accent)
	b.add_theme_color_override("font_disabled_color", Color(HudKit.TEXT_DIM.r, HudKit.TEXT_DIM.g, HudKit.TEXT_DIM.b, 0.7))
	b.add_theme_color_override("font_outline_color", Color(0, 0, 0, 0.8))
	b.add_theme_constant_override("outline_size", 3)
	var pip := Pip.new()
	pip.colour = accent if blocked == "" else Color(0.4, 0.4, 0.42)
	pip.position = Vector2(9, 10 if blocked == "" else 9)
	b.add_child(pip)
	if blocked != "":
		var why := HudKit.label(blocked, 12, Color(0.80, 0.62, 0.50), HudKit.body(), 2)
		why.position = Vector2(26, 29)
		b.add_child(why)
	b.pressed.connect(func():
		NetworkManager.send_chat(command)
		AudioManager.play_sound_at("ui_button", Vector3.ZERO, null, true)
		close())
	return b


## The entry's colour mark: a small diamond.
class Pip extends Control:
	var colour := HudKit.GOLD

	func _init() -> void:
		size = Vector2(10, 10)
		mouse_filter = Control.MOUSE_FILTER_IGNORE

	func _draw() -> void:
		var c := size * 0.5
		draw_colored_polygon(PackedVector2Array([c + Vector2(0, -5), c + Vector2(5, 0), c + Vector2(0, 5), c + Vector2(-5, 0)]), colour)
