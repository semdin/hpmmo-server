extends Control
class_name HudDuel

## The local player's duel, drawn from `SimAuthority.duel_state` (v27):
##   - the countdown (3, 2, 1, Fight!) in the middle of the screen;
##   - a plaque at the top: the two sides (beaten duelists struck through) and
##     the time left;
##   - the arena: a glowing wall round the circle the authority judges, with a
##     warning when the player nears its edge (leaving it loses the duel);
##   - red names on the standing foes, grey on the beaten;
##   - the result banner (Victory / Defeat / Draw) and a chat line.
## Everything here is presentation: who may hit whom, the 1 HP rule and the
## arena check are the authority's (authority.gd, duel.gd).

const ARENA_HEIGHT := 7.0
const WARN_MARGIN := 7.0

var player: Node3D = null
## The HUD's chat sink: add_system_chat(text).
var chat_sink: Callable

var _state: Dictionary = {}
var _duel_id := 0
var _fight_at_ms := 0
var _ends_at_ms := 0
var _fight_shown := false
var _last_count := -1
var _marked: Dictionary = {}   # uid -> mark set on its body
var _mark_check_ms := 0
var _arena: MeshInstance3D = null
var _arena_mat: ShaderMaterial = null

var _count: Label
var _plaque: PanelContainer
var _plaque_title: Label
var _plaque_time: Label
var _plaque_sides: RichTextLabel
var _warn: Label
var _banner: Control
var _banner_title: Label
var _banner_sub: Label
var _banner_tween: Tween

const ARENA_SHADER := """
shader_type spatial;
render_mode unshaded, cull_disabled, depth_draw_never, blend_add, shadows_disabled, fog_disabled;
uniform vec4 tint : source_color = vec4(1.0, 0.36, 0.26, 1.0);
uniform float strength = 0.36;
uniform float height = 7.0;
varying float h01;
void vertex() {
	h01 = clamp(VERTEX.y / height + 0.5, 0.0, 1.0);
}
void fragment() {
	float fade = pow(1.0 - h01, 1.8);
	float runes = 0.62 + 0.38 * sin(UV.x * 6.2831 * 64.0 + TIME * 1.6);
	float sweep = 0.75 + 0.25 * sin(UV.x * 6.2831 * 3.0 - TIME * 0.9);
	float rim = smoothstep(0.0, 0.05, h01) * (1.0 + 2.2 * smoothstep(0.10, 0.0, abs(h01 - 0.16)));
	ALBEDO = tint.rgb;
	ALPHA = clamp(fade * runes * sweep * rim * strength, 0.0, 1.0);
}
"""

func _init() -> void:
	name = "Duel"
	mouse_filter = Control.MOUSE_FILTER_IGNORE

func _ready() -> void:
	set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	_build()
	SimAuthority.duel_state.connect(_on_duel_state)

## A duel is on (countdown or fight) for the local player.
func active() -> bool:
	return _duel_id != 0

func _is_local(uid: int) -> bool:
	return uid == SimAuthority.local_uid or SimAuthority.local_uid == 0

func _local_uid() -> int:
	if is_instance_valid(player):
		return int(player.get_meta("sim_uid", SimAuthority.local_uid))
	return SimAuthority.local_uid

# ------------------------------------------------------------------ state

func _on_duel_state(uid: int, state: Dictionary) -> void:
	if not _is_local(uid):
		return
	var id := int(state.get("duel_id", 0))
	if id == 0:
		if state.has("declined_by"):
			_chat(tr("%s declined your duel.") % String(state["declined_by"]))
		elif state.has("result"):
			_finish(state)
		return
	var now := Time.get_ticks_msec()
	if id != _duel_id:
		_duel_id = id
		_fight_shown = false
		_last_count = -1
		_build_arena(state.get("center", Vector3.ZERO), float(state.get("radius", 40.0)))
		_chat(tr("Duel accepted - the fight begins in %d seconds. Leaving the circle loses the duel.") % int(ceil(float(state.get("fight_in_ms", 0)) / 1000.0)))
	var was_out := (_state.get("out", []) as Array).has(_local_uid())
	_state = state
	_fight_at_ms = now + int(state.get("fight_in_ms", 0))
	_ends_at_ms = now + int(state.get("ends_in_ms", 0))
	if String(state.get("phase", "")) == "fight" and not _fight_shown:
		_show_fight()
	if not was_out and (state.get("out", []) as Array).has(_local_uid()):
		_chat(tr("You are out of the duel - your side fights on."))
	_apply_marks()
	_refresh_plaque()
	_plaque.visible = true
	if _arena_mat != null:
		_arena_mat.set_shader_parameter("tint", Color(1.0, 0.36, 0.26) if String(state.get("phase", "")) == "fight" else Color(1.0, 0.78, 0.36))

func _finish(state: Dictionary) -> void:
	_duel_id = 0
	_state = {}
	_count.visible = false
	_plaque.visible = false
	_warn.visible = false
	_clear_marks()
	_free_arena()
	var result := String(state.get("result", "draw"))
	var sub := _result_line(state)
	var title := tr("Victory") if result == "won" else (tr("Defeat") if result == "lost" else tr("Draw"))
	var colour := HudKit.GOLD_HI if result == "won" else (Color(1.0, 0.40, 0.34) if result == "lost" else HudKit.PARCHMENT)
	_show_banner(I18n.upper(title), sub, colour)
	if result == "won":
		AudioManager.play_stinger("stinger_victory")
	else:
		AudioManager.play_sound_at("ui_upgrade_fail" if result == "lost" else "ui_confirm", Vector3.ZERO, null, true)
	var head := tr("Duel won") if result == "won" else (tr("Duel lost") if result == "lost" else tr("Duel drawn"))
	_chat("%s: %s" % [head, sub])

func _names(list: Array) -> String:
	var out: PackedStringArray = []
	for entry in list:
		out.append(String((entry as Dictionary).get("name", "?")))
	return ", ".join(out)

## How the duel ended, from the local player's side.
func _result_line(state: Dictionary) -> String:
	var me := String(player.get("player_name")) if is_instance_valid(player) else ""
	var last := String(state.get("last", ""))
	var by := String(state.get("by", ""))
	var group := bool(state.get("group", false))
	var result := String(state.get("result", "draw"))
	match String(state.get("reason", "")):
		"defeat":
			if group:
				return tr("Your party won the group duel.") if result == "won" else tr("Your party lost the group duel.")
			return tr("You defeated %s.") % last if result == "won" else tr("%s defeated you.") % (by if by != "" else _names(state.get("foes", [])))
		"fled":
			return tr("You left the duel circle.") if last == me else tr("%s left the duel circle.") % last
		"left":
			return tr("%s left the game.") % last
		"yield":
			return tr("You yielded.") if last == me else tr("%s yielded.") % last
		"died":
			return tr("You died.") if last == me else tr("%s died.") % last
		"timeout":
			return tr("Time ran out.")
	return tr("The duel is over.")

# ------------------------------------------------------------------ frame

func _process(_delta: float) -> void:
	if _duel_id == 0:
		return
	var now := Time.get_ticks_msec()
	# The countdown: whole seconds to the first blow, then "Fight!".
	if String(_state.get("phase", "")) == "countdown":
		var left := int(ceil(float(_fight_at_ms - now) / 1000.0))
		if left > 0 and left != _last_count:
			_last_count = left
			_pop_count(str(left), HudKit.GOLD_HI)
			AudioManager.play_sound_at("ui_button", Vector3.ZERO, null, true)
		elif left <= 0 and not _fight_shown:
			_show_fight()   # the authority's "fight" state follows within a tick
	var secs := maxi(0, int(ceil(float(_ends_at_ms - now) / 1000.0)))
	_plaque_time.text = "%d:%02d" % [secs / 60, secs % 60]
	# The edge of the arena.
	var near_edge := false
	if is_instance_valid(player) and _state.has("center"):
		var c: Vector3 = _state["center"]
		var p := player.global_position
		var d := Vector2(p.x - c.x, p.z - c.z).length()
		near_edge = d > float(_state.get("radius", 40.0)) - WARN_MARGIN \
			and not (_state.get("out", []) as Array).has(_local_uid())
	_warn.visible = near_edge
	if near_edge:
		_warn.modulate.a = 0.6 + 0.4 * sin(now * 0.012)
	# Foe bodies that entered view after the last state get their marks.
	if now >= _mark_check_ms:
		_mark_check_ms = now + 500
		_apply_marks()

func _show_fight() -> void:
	_fight_shown = true
	_pop_count(I18n.upper(tr("Fight!")), Color(1.0, 0.44, 0.32), 1.1)
	AudioManager.play_sound_at("ui_confirm", Vector3.ZERO, null, true)

# ------------------------------------------------------------------ marks

func _apply_marks() -> void:
	var out: Array = _state.get("out", [])
	var want: Dictionary = {}
	for foe in _state.get("foes", []):
		var uid := int((foe as Dictionary).get("uid", 0))
		want[uid] = 2 if out.has(uid) else 1   # player.gd DUEL_OUT / DUEL_FOE
	for uid in want:
		var node = SimAuthority.record_by_uid(int(uid)).get("node")
		if node != null and is_instance_valid(node) and node.has_method("set_duel_mark"):
			node.call("set_duel_mark", int(want[uid]))
			_marked[uid] = node

func _clear_marks() -> void:
	for uid in _marked:
		var node = _marked[uid]
		if node != null and is_instance_valid(node) and node.has_method("set_duel_mark"):
			node.call("set_duel_mark", 0)
	_marked.clear()

# ------------------------------------------------------------------ arena

func _build_arena(center: Vector3, radius: float) -> void:
	_free_arena()
	if not is_instance_valid(player) or player.get_parent() == null:
		return
	var mesh := CylinderMesh.new()
	mesh.top_radius = radius
	mesh.bottom_radius = radius
	mesh.height = ARENA_HEIGHT
	mesh.radial_segments = 96
	mesh.rings = 1
	mesh.cap_top = false
	mesh.cap_bottom = false
	var shader := Shader.new()
	shader.code = ARENA_SHADER
	_arena_mat = ShaderMaterial.new()
	_arena_mat.shader = shader
	_arena_mat.set_shader_parameter("height", ARENA_HEIGHT)
	_arena_mat.set_shader_parameter("tint", Color(1.0, 0.78, 0.36))
	_arena = MeshInstance3D.new()
	_arena.name = "DuelArena"
	_arena.mesh = mesh
	_arena.material_override = _arena_mat
	_arena.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	player.get_parent().add_child(_arena)
	# A metre and a half into the ground, so slopes inside the circle still meet it.
	_arena.global_position = center + Vector3(0, ARENA_HEIGHT * 0.5 - 1.5, 0)

func _free_arena() -> void:
	if _arena != null and is_instance_valid(_arena):
		_arena.queue_free()
	_arena = null
	_arena_mat = null

func _exit_tree() -> void:
	_free_arena()

# ------------------------------------------------------------------ widgets

func _build() -> void:
	_count = HudKit.label("", 96, HudKit.GOLD_HI, HudKit.deco(), 10)
	_count.name = "Countdown"
	_count.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_count.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	_count.set_anchors_preset(Control.PRESET_CENTER)
	_count.custom_minimum_size = Vector2(700, 140)
	_count.offset_left = -350
	_count.offset_right = 350
	_count.offset_top = -190
	_count.offset_bottom = -50
	_count.pivot_offset = Vector2(350, 70)
	_count.visible = false
	add_child(_count)

	_plaque = PanelContainer.new()
	_plaque.name = "DuelPlaque"
	_plaque.mouse_filter = Control.MOUSE_FILTER_IGNORE
	var box := StyleBoxFlat.new()
	box.bg_color = Color(0.031, 0.040, 0.067, 0.92)
	box.border_color = Color(1.0, 0.40, 0.32).lerp(HudKit.GOLD, 0.5)
	box.set_border_width_all(1)
	box.border_width_bottom = 2
	box.set_corner_radius_all(8)
	box.shadow_color = Color(0, 0, 0, 0.5)
	box.shadow_size = 8
	box.content_margin_left = 16
	box.content_margin_right = 16
	box.content_margin_top = 6
	box.content_margin_bottom = 8
	_plaque.add_theme_stylebox_override("panel", box)
	# The right rail under the minimap: the top centre belongs to the target
	# card and the zone banner, which a duel crosses often.
	_plaque.set_anchors_preset(Control.PRESET_TOP_RIGHT)
	_plaque.grow_horizontal = Control.GROW_DIRECTION_BEGIN
	_plaque.offset_right = -UITheme.EDGE
	_plaque.offset_left = -UITheme.EDGE - UITheme.RIGHT_COL_W
	_plaque.offset_top = 272
	_plaque.visible = false
	add_child(_plaque)
	var column := VBoxContainer.new()
	column.add_theme_constant_override("separation", 2)
	column.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_plaque.add_child(column)
	var top := HBoxContainer.new()
	top.add_theme_constant_override("separation", 12)
	top.mouse_filter = Control.MOUSE_FILTER_IGNORE
	column.add_child(top)
	_plaque_title = HudKit.label("", 14, Color(1.0, 0.62, 0.50), HudKit.title(), 4)
	_plaque_title.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	top.add_child(_plaque_title)
	_plaque_time = HudKit.label("", 14, HudKit.PARCHMENT, HudKit.bold(), 3)
	top.add_child(_plaque_time)
	var rule := ColorRect.new()
	rule.color = Color(HudKit.GOLD.r, HudKit.GOLD.g, HudKit.GOLD.b, 0.4)
	rule.custom_minimum_size = Vector2(0, 1)
	rule.mouse_filter = Control.MOUSE_FILTER_IGNORE
	column.add_child(rule)
	_plaque_sides = RichTextLabel.new()
	_plaque_sides.bbcode_enabled = true
	_plaque_sides.fit_content = true
	_plaque_sides.scroll_active = false
	_plaque_sides.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_plaque_sides.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_plaque_sides.custom_minimum_size = Vector2(UITheme.RIGHT_COL_W - 32, 0)
	_plaque_sides.add_theme_font_override("normal_font", HudKit.bold())
	_plaque_sides.add_theme_font_size_override("normal_font_size", 15)
	_plaque_sides.add_theme_color_override("font_outline_color", Color(0, 0, 0, 0.85))
	_plaque_sides.add_theme_constant_override("outline_size", 3)
	column.add_child(_plaque_sides)

	_warn = HudKit.label(tr("Stay inside the duel circle - leaving it loses the duel!"), 18, Color(1.0, 0.42, 0.34), HudKit.bold(), 5)
	_warn.name = "DuelEdgeWarning"
	_warn.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_warn.set_anchors_preset(Control.PRESET_CENTER)
	_warn.offset_left = -360
	_warn.offset_right = 360
	_warn.offset_top = 40
	_warn.offset_bottom = 70
	_warn.visible = false
	add_child(_warn)

	_banner = VBoxContainer.new()
	_banner.name = "DuelResult"
	_banner.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_banner.set_anchors_preset(Control.PRESET_CENTER)
	_banner.offset_left = -400
	_banner.offset_right = 400
	_banner.offset_top = -220
	_banner.offset_bottom = -90
	_banner.alignment = BoxContainer.ALIGNMENT_CENTER
	_banner.add_theme_constant_override("separation", 4)
	_banner.visible = false
	add_child(_banner)
	_banner_title = HudKit.label("", 72, HudKit.GOLD_HI, HudKit.deco(), 10)
	_banner_title.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_banner.add_child(_banner_title)
	var underline := ColorRect.new()
	underline.color = Color(HudKit.GOLD.r, HudKit.GOLD.g, HudKit.GOLD.b, 0.7)
	underline.custom_minimum_size = Vector2(360, 2)
	underline.size_flags_horizontal = Control.SIZE_SHRINK_CENTER
	_banner.add_child(underline)
	_banner_sub = HudKit.label("", 20, HudKit.PARCHMENT, HudKit.bold(), 5)
	_banner_sub.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_banner.add_child(_banner_sub)

func _refresh_plaque() -> void:
	var group := bool(_state.get("group", false))
	_plaque_title.text = I18n.upper(tr("Group Duel") if group else tr("Duel"))
	var out: Array = _state.get("out", [])
	var ally_col := Color(0.62, 0.84, 1.0).to_html(false)
	var foe_col := Color(1.0, 0.46, 0.38).to_html(false)
	var line := "[center]%s\n[color=#%s]%s[/color]\n%s[/center]" % [
		_side_text(_state.get("allies", []), out, ally_col), HudKit.GOLD.to_html(false),
		I18n.upper(tr("vs")), _side_text(_state.get("foes", []), out, foe_col)]
	_plaque_sides.text = line
	_plaque.reset_size()

func _side_text(list: Array, out: Array, colour: String) -> String:
	var parts: PackedStringArray = []
	for entry in list:
		var e := entry as Dictionary
		var who := String(e.get("name", "?")).replace("[", "[lb]")
		if out.has(int(e.get("uid", 0))):
			parts.append("[color=#7d7670][s]%s[/s][/color]" % who)
		else:
			parts.append("[color=#%s]%s[/color]" % [colour, who])
	return ", ".join(parts)

func _pop_count(text: String, colour: Color, hold := 0.8) -> void:
	_count.text = text
	_count.add_theme_color_override("font_color", colour)
	_count.visible = true
	_count.scale = Vector2(1.6, 1.6)
	_count.modulate.a = 1.0
	var tween := create_tween()
	tween.tween_property(_count, "scale", Vector2.ONE, 0.22).set_trans(Tween.TRANS_BACK).set_ease(Tween.EASE_OUT)
	tween.tween_interval(hold * 0.6)
	tween.tween_property(_count, "modulate:a", 0.0, hold * 0.4)

func _show_banner(title: String, sub: String, colour: Color) -> void:
	_banner_title.text = title
	_banner_title.add_theme_color_override("font_color", colour)
	_banner_sub.text = sub
	_banner.visible = true
	_banner.modulate.a = 0.0
	if _banner_tween != null and _banner_tween.is_valid():
		_banner_tween.kill()
	_banner_tween = create_tween()
	_banner_tween.tween_property(_banner, "modulate:a", 1.0, 0.25)
	_banner_tween.tween_interval(3.2)
	_banner_tween.tween_property(_banner, "modulate:a", 0.0, 0.6)
	_banner_tween.tween_callback(func(): _banner.visible = false)

func _chat(text: String) -> void:
	if chat_sink.is_valid():
		chat_sink.call(text)
