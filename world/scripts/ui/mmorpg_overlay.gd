extends CanvasLayer

## MMORPGOverlay — minimap, quest tracker, zone banner, boss bar,
## NPC dialogue box, low-HP vignette. Built at runtime so no .tscn edits.

var _map: Control = null
var _dots: Dictionary = {}
var _quest_label: Label = null
var _zone_label: Label = null
var _zone_timer: float = 0.0
var _boss_panel: Panel = null
var _boss_bar: ProgressBar = null
var _boss_name: Label = null
var _dialog_panel: Panel = null
var _dialog_text: Label = null
var _vignette: ColorRect = null
var _player: Node3D = null
var _last_zone := ""

func attach(player: Node3D) -> void:
	_player = player
	_build()
	if has_node("/root/QuestManager"):
		QuestManager.quest_updated.connect(_refresh_quest)
		_refresh_quest()

func _build() -> void:
	# --- minimap (top-right) ---
	_map = Control.new()
	_map.name = "Minimap"
	_map.custom_minimum_size = Vector2(170, 170)
	_map.set_anchors_preset(Control.PRESET_TOP_RIGHT)
	_map.position = Vector2(-186, 16)
	var bg := Panel.new()
	bg.set_anchors_preset(Control.PRESET_FULL_RECT)
	var sb := StyleBoxFlat.new()
	sb.bg_color = Color(0.04, 0.05, 0.08, 0.8)
	sb.border_color = Color(0.85, 0.7, 0.3)
	sb.set_border_width_all(2)
	sb.set_corner_radius_all(85)
	bg.add_theme_stylebox_override("panel", sb)
	_map.add_child(bg)
	var title := Label.new()
	title.text = "HOGWARTS VALLEY"
	title.add_theme_font_size_override("font_size", 10)
	title.add_theme_color_override("font_color", Color(1, 0.9, 0.5))
	title.set_anchors_preset(Control.PRESET_CENTER_TOP)
	title.position = Vector2(-52, 6)
	_map.add_child(title)
	add_child(_map)

	# --- quest tracker (right side) ---
	var qp := Panel.new()
	qp.set_anchors_preset(Control.PRESET_TOP_RIGHT)
	qp.position = Vector2(-206, 196)
	qp.custom_minimum_size = Vector2(190, 124)
	var qsb := StyleBoxFlat.new()
	qsb.bg_color = Color(0.06, 0.06, 0.1, 0.82)
	qsb.border_color = Color(0.9, 0.78, 0.3)
	qsb.set_border_width_all(2)
	qsb.set_corner_radius_all(6)
	qp.add_theme_stylebox_override("panel", qsb)
	_quest_label = Label.new()
	_quest_label.add_theme_font_size_override("font_size", 12)
	_quest_label.add_theme_color_override("font_color", Color(1, 0.92, 0.6))
	_quest_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_quest_label.custom_minimum_size = Vector2(174, 108)
	_quest_label.position = Vector2(8, 8)
	qp.add_child(_quest_label)
	add_child(qp)

	# --- zone banner (top center) ---
	_zone_label = Label.new()
	_zone_label.set_anchors_preset(Control.PRESET_CENTER_TOP)
	_zone_label.position = Vector2(-220, 24)
	_zone_label.custom_minimum_size = Vector2(440, 40)
	_zone_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_zone_label.add_theme_font_size_override("font_size", 26)
	_zone_label.add_theme_color_override("font_color", Color(1, 0.92, 0.6))
	_zone_label.add_theme_color_override("font_outline_color", Color(0, 0, 0))
	_zone_label.add_theme_constant_override("outline_size", 8)
	_zone_label.modulate.a = 0.0
	add_child(_zone_label)

	# --- boss bar (top center under banner) ---
	_boss_panel = Panel.new()
	_boss_panel.set_anchors_preset(Control.PRESET_CENTER_TOP)
	_boss_panel.position = Vector2(-220, 64)
	_boss_panel.custom_minimum_size = Vector2(440, 40)
	_boss_panel.hide()
	var bsb := StyleBoxFlat.new()
	bsb.bg_color = Color(0.05, 0.03, 0.08, 0.85)
	bsb.border_color = Color(0.7, 0.2, 1.0)
	bsb.set_border_width_all(2)
	bsb.set_corner_radius_all(6)
	_boss_panel.add_theme_stylebox_override("panel", bsb)
	_boss_name = Label.new()
	_boss_name.text = "Dark Monolith"
	_boss_name.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_boss_name.add_theme_font_size_override("font_size", 13)
	_boss_name.add_theme_color_override("font_color", Color(0.9, 0.5, 1.0))
	_boss_name.set_anchors_preset(Control.PRESET_TOP_WIDE)
	_boss_panel.add_child(_boss_name)
	_boss_bar = ProgressBar.new()
	_boss_bar.set_anchors_preset(Control.PRESET_BOTTOM_WIDE)
	_boss_bar.offset_top = -16
	_boss_bar.offset_left = 8
	_boss_bar.offset_right = -8
	_boss_bar.offset_bottom = -6
	_boss_bar.show_percentage = false
	var bfill := StyleBoxFlat.new()
	bfill.bg_color = Color(0.65, 0.15, 0.9)
	_boss_bar.add_theme_stylebox_override("fill", bfill)
	_boss_panel.add_child(_boss_bar)
	add_child(_boss_panel)

	# --- dialogue box (bottom center above hotbar) ---
	_dialog_panel = Panel.new()
	_dialog_panel.set_anchors_preset(Control.PRESET_CENTER_BOTTOM)
	_dialog_panel.position = Vector2(-260, -230)
	_dialog_panel.custom_minimum_size = Vector2(520, 110)
	_dialog_panel.hide()
	var dsb := StyleBoxFlat.new()
	dsb.bg_color = Color(0.05, 0.05, 0.1, 0.92)
	dsb.border_color = Color(0.9, 0.78, 0.3)
	dsb.set_border_width_all(2)
	dsb.set_corner_radius_all(8)
	_dialog_panel.add_theme_stylebox_override("panel", dsb)
	_dialog_text = Label.new()
	_dialog_text.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_dialog_text.custom_minimum_size = Vector2(500, 90)
	_dialog_text.position = Vector2(10, 10)
	_dialog_text.add_theme_font_size_override("font_size", 13)
	add_child(_dialog_panel)
	_dialog_panel.add_child(_dialog_text)

	# --- low hp vignette ---
	_vignette = ColorRect.new()
	_vignette.set_anchors_preset(Control.PRESET_FULL_RECT)
	_vignette.color = Color(0.8, 0.05, 0.05, 0.0)
	_vignette.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(_vignette)

	# --- controls hint (bottom-left): clears up WASD + passive rule ---
	var help := Panel.new()
	help.set_anchors_preset(Control.PRESET_TOP_RIGHT)
	help.position = Vector2(-296, 330)
	help.custom_minimum_size = Vector2(285, 106)
	var hsb := StyleBoxFlat.new()
	hsb.bg_color = Color(0.04, 0.05, 0.08, 0.75)
	hsb.border_color = Color(0.6, 0.65, 0.75)
	hsb.set_border_width_all(1)
	hsb.set_corner_radius_all(6)
	help.add_theme_stylebox_override("panel", hsb)
	var hl := Label.new()
	hl.text = "WASD move • Right-drag camera • Wheel zoom\nLMB attack • 1–4 / Q / E skills • Tab target\nShift mount / dismount • Space rise / jump\nCtrl descend • F talk • Z loot • I bag\nNorth: Great Hall, library and classroom"
	hl.add_theme_font_size_override("font_size", 11)
	hl.add_theme_color_override("font_color", Color(0.85, 0.88, 0.92))
	hl.position = Vector2(8, 6)
	hl.custom_minimum_size = Vector2(270, 96)
	hl.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	help.add_child(hl)
	add_child(help)

func show_dialogue(speaker: String, lines: Array) -> void:
	_dialog_panel.show()
	_dialog_text.text = "[%s]\n%s\n\n(Esc to close)" % [speaker, "\n".join(lines)]
	await get_tree().create_timer(6.0).timeout
	if is_instance_valid(_dialog_panel):
		_dialog_panel.hide()

func _refresh_quest() -> void:
	if _quest_label and has_node("/root/QuestManager"):
		_quest_label.text = "QUEST\n" + QuestManager.tracker_text()

func _process(_delta: float) -> void:
	if not is_instance_valid(_player):
		return
	_update_minimap()
	_update_zone()
	_update_boss()
	_update_vignette()

func _world_to_map(pos: Vector3) -> Vector2:
	# world 200x200 -> 150px circle
	var cx: float = clamp(pos.x / 110.0, -1.0, 1.0) * 62.0 + 85.0
	var cy: float = clamp(pos.z / 110.0, -1.0, 1.0) * 62.0 + 85.0
	return Vector2(cx, cy)

func _dot(key: String, color: Color, size: float = 6.0) -> ColorRect:
	if not _dots.has(key):
		var r := ColorRect.new()
		r.custom_minimum_size = Vector2(size, size)
		r.color = color
		_map.add_child(r)
		_dots[key] = r
	var d: ColorRect = _dots[key]
	d.color = color
	return d

func _update_minimap() -> void:
	if _map == null:
		return
	var pd := _dot("__player", Color(0.3, 1.0, 0.4), 8.0)
	pd.position = _world_to_map(_player.global_position) - Vector2(4, 4)
	# mobs red
	for m in get_tree().get_nodes_in_group("mobs"):
		if not is_instance_valid(m):
			continue
		var d := _dot("mob_%d" % m.get_instance_id(), Color(1, 0.25, 0.25), 5.0)
		d.visible = m.state != 5
		d.position = _world_to_map(m.global_position) - Vector2(2.5, 2.5)
	# monoliths purple
	for mo in get_tree().get_nodes_in_group("monoliths"):
		if not is_instance_valid(mo):
			continue
		var d := _dot("mon_%d" % mo.get_instance_id(), Color(0.75, 0.3, 1.0), 9.0)
		d.position = _world_to_map(mo.global_position) - Vector2(4.5, 4.5)
	# npcs gold
	for n in get_tree().get_nodes_in_group("npcs"):
		if not is_instance_valid(n):
			continue
		var d := _dot("npc_%d" % n.get_instance_id(), Color(1.0, 0.85, 0.25), 7.0)
		d.position = _world_to_map(n.global_position) - Vector2(3.5, 3.5)
	# cleanup dead dots (cheap: every frame ok for <200 dots)
	for key in _dots.keys():
		if key.begins_with("mob_") or key.begins_with("mon_") or key.begins_with("npc_"):
			var object_id := int(key.get_slice("_", 1))
			if not is_instance_id_valid(object_id):
				_dots[key].queue_free()
				_dots.erase(key)

func zone_at(pos: Vector3) -> String:
	if pos.z < -47 and pos.z > -102 and absf(pos.x) < 38:
		return "Hogwarts Library" if pos.x < -20 else ("Charms Classroom" if pos.x > 20 else "Hogwarts • Great Hall")
	if pos.distance_to(Vector3(35, 0, 17)) < 22.0:
		return "Hogsmeade Village"
	if pos.x < -35.0 and pos.z < -8.0:
		return "Forbidden Forest"
	if pos.distance_to(Vector3(-38, 0, 30)) < 20.0:
		return "Black Lake"
	if pos.distance_to(Vector3(52, 0, 26)) < 24.0:
		return "Quidditch Pitch"
	if pos.distance_to(Vector3(0, 0, 5)) < 20.0:
		return "Hogwarts Courtyard"
	return "Hogwarts Grounds"

func _update_zone() -> void:
	var z := zone_at(_player.global_position)
	if z != _last_zone:
		_last_zone = z
		_zone_label.text = z
		_zone_timer = 3.0
		_zone_label.modulate.a = 1.0
		if z == "Quidditch Pitch" and has_node("/root/QuestManager"):
			QuestManager.add_visit("Quidditch Pitch")
	if _zone_timer > 0.0:
		_zone_timer -= get_process_delta_time()
		if _zone_timer <= 0.0:
			_zone_label.modulate.a = 0.0
	else:
		_zone_label.modulate.a = maxf(0.0, _zone_label.modulate.a - get_process_delta_time() * 0.8)

func _update_boss() -> void:
	var t: Node = _player.get("current_target") as Node
	if is_instance_valid(t) and (t.is_in_group("monoliths") or ("is_boss" in t and t.is_boss)) and t.current_hp > 0:
		_boss_panel.show()
		_boss_name.text = "DARK MONOLITH — Lv.35" if t.is_in_group("monoliths") else "%s • Lv.%d" % [t.mob_name, t.level]
		_boss_bar.max_value = (t as Node3D).get("max_hp")
		_boss_bar.value = (t as Node3D).get("current_hp")
	else:
		_boss_panel.hide()

func _update_vignette() -> void:
	var hp: int = int(_player.get("current_hp"))
	var max_hp: int = int(_player.get("max_hp"))
	if max_hp > 0:
		var missing: float = 1.0 - float(hp) / float(max_hp)
		var target_a: float = clamp((missing - 0.55) * 1.2, 0.0, 0.45)
		_vignette.color.a = lerpf(_vignette.color.a, target_a, 0.1)
