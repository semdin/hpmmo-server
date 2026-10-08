extends CanvasLayer

## MMORPGOverlay — minimap, quest tracker, zone banner, boss bar,
## NPC dialogue box, low-HP vignette. Built at runtime so no .tscn edits.

## Screen-edge grid, in canvas (1280x720) pixels, shared with the HUD and the
## combat feedback through `UITheme` so all three surfaces line up.
const QUEST_TOP := 250.0
const QUEST_H := 104.0
const HELP_TOP := 362.0
const HELP_H := 82.0
## The controls card is a reference rather than a readout, so it is dropped as
## soon as the canvas is shorter than one full design height - which is what a
## UI scale above 1.0 produces. At that point it can no longer stay clear of the
## notification stack below it, and a stale key list is the least important thing
## on screen.
const HELP_MIN_CANVAS_H := 720.0

var _map: Control = null
var _map_view: SubViewport = null
var _map_cam: Camera3D = null
var _map_overlay: Control = null
var _map_zoom := 150.0
var _dots: Dictionary = {}
var _quest_panel: Panel = null
var _quest_title: Label = null
var _quest_label: Label = null
var _zone_label: Label = null
var _zone_timer: float = 0.0
var _boss_panel: Panel = null
var _boss_bar: ProgressBar = null
var _boss_name: Label = null
var _dialog_panel: Panel = null
var _dialog_text: Label = null
var _help_panel: Panel = null
var _vignette: ColorRect = null
var _player: Node3D = null
var _last_zone := ""
var _binder: UIStateBinder = null

func attach(player: Node3D) -> void:
	_player = player
	_build()
	_sync_help_visibility()
	get_viewport().size_changed.connect(_sync_help_visibility)
	if _map_view != null and player != null:
		# Share the player's World3D so the map camera sees the same terrain the
		# game camera does, rather than an empty private world.
		_map_view.world_3d = player.get_world_3d()
	if has_node("/root/QuestManager"):
		QuestManager.quest_updated.connect(_refresh_quest)
		_refresh_quest()

## Radius of the minimap disc, in canvas pixels.
const MAP_PX := 178
## World units across the minimap. Raised and lowered by the +/- buttons.
const MAP_ZOOM_MIN := 60.0
const MAP_ZOOM_MAX := 420.0

## A live top-down render of the world, clipped to a circle and ringed in brass.
##
## The previous map was a black disc with coloured squares on it - it told you
## where things were relative to nothing. This renders the actual ground, castle
## and trees through an orthographic camera above the player, so the markers sit
## on real terrain you can recognise.
func _build() -> void:
	_map = Control.new()
	_map.name = "Minimap"
	_map.custom_minimum_size = Vector2(MAP_PX, MAP_PX)
	_map.set_anchors_preset(Control.PRESET_TOP_RIGHT)
	_map.offset_left = -(MAP_PX + 16)
	_map.offset_top = 14.0
	_map.offset_right = -16.0
	_map.offset_bottom = 14.0 + MAP_PX
	_map.mouse_filter = Control.MOUSE_FILTER_IGNORE

	# The viewport has to exist under a Node that owns the world, so it is
	# parented to the overlay and pointed at the player's world in `attach`.
	_map_view = SubViewport.new()
	_map_view.name = "MinimapView"
	_map_view.size = Vector2i(int(MAP_PX), int(MAP_PX))
	_map_view.transparent_bg = false
	_map_view.render_target_update_mode = SubViewport.UPDATE_ALWAYS
	_map_view.msaa_3d = Viewport.MSAA_DISABLED
	_map.add_child(_map_view)

	_map_cam = Camera3D.new()
	_map_cam.projection = Camera3D.PROJECTION_ORTHOGONAL
	_map_cam.size = 150.0
	_map_cam.rotation_degrees = Vector3(-90.0, 0.0, 0.0)
	_map_cam.current = true
	_map_cam.far = 400.0
	_map_view.add_child(_map_cam)

	var disc := TextureRect.new()
	disc.name = "Disc"
	disc.texture = _map_view.get_texture()
	disc.set_anchors_preset(Control.PRESET_FULL_RECT)
	disc.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	disc.stretch_mode = TextureRect.STRETCH_SCALE
	disc.material = _disc_mask_material()
	disc.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_map.add_child(disc)

	_map_overlay = Control.new()
	_map_overlay.name = "Markers"
	_map_overlay.set_anchors_preset(Control.PRESET_FULL_RECT)
	_map_overlay.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_map.add_child(_map_overlay)

	# Fixed-aspect artwork sits over the existing circular map mask.
	var ring := TextureRect.new()
	ring.name = "Ring"
	ring.texture = ArcaneSkin.texture("minimap")
	ring.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	ring.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
	ring.set_anchors_preset(Control.PRESET_FULL_RECT)
	ring.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_map.add_child(ring)

	var title := UITheme.heading("HOGWARTS VALLEY", UITheme.FS_TINY, UITheme.c("gold_lt"))
	# Below the disc: at the top edge it collided with the ring and the compass,
	# and half of it fell outside the screen.
	title.set_anchors_preset(Control.PRESET_CENTER_BOTTOM)
	title.offset_left = -90.0
	title.offset_right = 90.0
	title.offset_top = 30.0
	title.offset_bottom = 46.0
	title.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	title.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_map.add_child(title)

	_build_map_buttons()
	add_child(_map)


	# --- quest tracker (right rail, under the minimap) ---
	_quest_panel = Panel.new()
	_quest_panel.name = "QuestTracker"
	_quest_panel.set_anchors_preset(Control.PRESET_TOP_RIGHT)
	UILayout.place(_quest_panel, Vector2(-(UITheme.RIGHT_COL_W + UITheme.EDGE), QUEST_TOP),
		Vector2(UITheme.RIGHT_COL_W, QUEST_H))
	_quest_panel.custom_minimum_size = Vector2(UITheme.RIGHT_COL_W, QUEST_H)
	_quest_panel.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_quest_panel.theme = UITheme.get_theme()
	_quest_panel.theme_type_variation = UITheme.V_CARD
	var quest_margin := MarginContainer.new()
	for side in ["left", "right", "top", "bottom"]:
		quest_margin.add_theme_constant_override("margin_" + side, 9)
	quest_margin.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_quest_panel.add_child(quest_margin)
	var quest_column := VBoxContainer.new()
	quest_column.add_theme_constant_override("separation", 4)
	quest_column.mouse_filter = Control.MOUSE_FILTER_IGNORE
	quest_margin.add_child(quest_column)
	# The caption is a caption, not the first line of the body: it gets the
	# title face while the objective keeps the reading face.
	_quest_title = UITheme.heading("QUEST", UITheme.FS_SMALL)
	quest_column.add_child(UITheme.icon_row("ui_quest", _quest_title, 18.0))
	quest_column.add_child(UITheme.divider())
	_quest_label = UITheme.body("", UITheme.FS_SMALL, UITheme.c("parchment"))
	_quest_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_quest_label.custom_minimum_size = Vector2(UITheme.RIGHT_COL_W - 18, 44)
	quest_column.add_child(_quest_label)
	add_child(_quest_panel)

	# --- zone banner (top center, above the target frame) ---
	_zone_label = Label.new()
	_zone_label.set_anchors_preset(Control.PRESET_CENTER_TOP)
	_zone_label.offset_left = -260.0
	_zone_label.offset_top = 6.0
	_zone_label.offset_right = 260.0
	_zone_label.offset_bottom = 32.0
	_zone_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_zone_label.add_theme_font_override("font", UITheme.font_title())
	_zone_label.add_theme_font_size_override("font_size", UITheme.FS_TITLE)
	_zone_label.add_theme_color_override("font_color", UITheme.c("gold_lt"))
	_zone_label.add_theme_color_override("font_outline_color", UITheme.c("shadow"))
	_zone_label.add_theme_constant_override("outline_size", 5)
	_zone_label.modulate.a = 0.0
	# TravelFeedback owns the single persistent location row.
	_zone_label.hide()
	add_child(_zone_label)

	# --- boss bar (top center under banner) ---
	_boss_panel = Panel.new()
	_boss_panel.set_anchors_preset(Control.PRESET_CENTER_TOP)
	UILayout.place(_boss_panel, Vector2(-220, 126), Vector2(440, 40))
	_boss_panel.custom_minimum_size = Vector2(440, 40)
	_boss_panel.hide()
	_boss_panel.theme = UITheme.get_theme()
	_boss_panel.theme_type_variation = UITheme.V_WINDOW
	_boss_name = Label.new()
	_boss_name.text = "Dark Monolith"
	_boss_name.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_boss_name.add_theme_font_override("font", UITheme.font_title())
	_boss_name.add_theme_font_size_override("font_size", UITheme.FS_BODY)
	_boss_name.add_theme_color_override("font_color", UITheme.c("magic"))
	_boss_name.set_anchors_preset(Control.PRESET_TOP_WIDE)
	_boss_panel.add_child(_boss_name)
	# The crown, at the left of the bar: the boss bar is the one place the game
	# says "world boss" without the target frame.
	var boss_icon := UITheme.icon_rect("ui_boss", 16.0)
	boss_icon.name = "BossIcon"
	boss_icon.position = Vector2(8, 3)
	_boss_panel.add_child(boss_icon)
	_boss_bar = ProgressBar.new()
	_boss_bar.set_anchors_preset(Control.PRESET_BOTTOM_WIDE)
	_boss_bar.offset_top = -16
	_boss_bar.offset_left = 8
	_boss_bar.offset_right = -8
	_boss_bar.offset_bottom = -6
	_boss_bar.show_percentage = false
	UITheme.role(_boss_bar, UITheme.V_BOSS)
	_boss_panel.add_child(_boss_bar)
	add_child(_boss_panel)

	# --- dialogue box (bottom center, clear of the cast bar and the deck) ---
	_dialog_panel = Panel.new()
	_dialog_panel.set_anchors_preset(Control.PRESET_CENTER_BOTTOM)
	UILayout.place_centred(_dialog_panel, Vector2(520, 100), Vector2(0, -400))
	_dialog_panel.custom_minimum_size = Vector2(520, 100)
	_dialog_panel.hide()
	_dialog_panel.theme = UITheme.get_theme()
	_dialog_panel.theme_type_variation = UITheme.V_WINDOW
	_dialog_text = Label.new()
	_dialog_text.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_dialog_text.custom_minimum_size = Vector2(470, 80)
	_dialog_text.position = Vector2(36, 10)
	_dialog_text.add_theme_color_override("font_color", UITheme.c("parchment"))
	_dialog_text.add_theme_font_size_override("font_size", UITheme.FS_BODY)
	add_child(_dialog_panel)
	_dialog_panel.add_child(_dialog_text)
	var dialog_icon := UITheme.icon_rect("ui_chat", 18.0)
	dialog_icon.name = "DialogIcon"
	dialog_icon.position = Vector2(11, 9)
	_dialog_panel.add_child(dialog_icon)

	# --- low hp vignette ---
	_vignette = ColorRect.new()
	_vignette.set_anchors_preset(Control.PRESET_FULL_RECT)
	_vignette.color = Color(0.8, 0.05, 0.05, 0.0)
	_vignette.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(_vignette)

	# --- controls reference (right rail, under the quest tracker) ---
	# It used to sit bottom-right as a five-line paragraph in the dimmest colour
	# in the palette, over a translucent flat box. It is a compact key list in
	# the reading face now, with the same card treatment as its neighbours.
	_help_panel = Panel.new()
	_help_panel.name = "ControlsCard"
	_help_panel.set_anchors_preset(Control.PRESET_TOP_RIGHT)
	UILayout.place(_help_panel, Vector2(-(UITheme.RIGHT_COL_W + UITheme.EDGE), HELP_TOP),
		Vector2(UITheme.RIGHT_COL_W, HELP_H))
	_help_panel.custom_minimum_size = Vector2(UITheme.RIGHT_COL_W, HELP_H)
	_help_panel.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_help_panel.theme = UITheme.get_theme()
	_help_panel.theme_type_variation = UITheme.V_CARD
	var help_label := UITheme.body(
		"WASD move · right-drag camera · wheel zoom\n"
		+ "LMB attack · 1–4 / Q / E skills · Tab target\n"
		+ "Shift mount · Space rise · Ctrl descend · F talk\n"
		+ "Z loot · I bag · O Ollivander · J guide · F1 settings",
		UITheme.FS_SMALL,
		UITheme.c("text"))
	help_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	help_label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	var help_row := UITheme.icon_row("ui_help", help_label, 18.0)
	help_row.position = Vector2(9, 5)
	help_row.custom_minimum_size = Vector2(UITheme.RIGHT_COL_W - 18, HELP_H - 10)
	_help_panel.add_child(help_row)
	add_child(_help_panel)

## The circular clip. A shader is the only way to cut a Control to a circle;
## `clip_contents` and canvas groups can only do rectangles.
func _disc_mask_material() -> ShaderMaterial:
	var sh := Shader.new()
	sh.code = """
shader_type canvas_item;
void fragment() {
	vec2 p = UV - vec2(0.5);
	float d = length(p);
	float edge = 1.0 - smoothstep(0.487, 0.500, d);
	vec4 c = texture(TEXTURE, UV);
	c.a *= edge;
	// Slight vignette so the map sits inside the bezel rather than touching it.
	c.rgb *= mix(0.55, 1.0, smoothstep(0.50, 0.18, d));
	COLOR = c;
}
"""
	var mat := ShaderMaterial.new()
	mat.shader = sh
	return mat


## The three round buttons under the reference's map: zoom out, recentre, zoom in.
## The three round buttons under the reference's map: zoom out, recentre, zoom in.
func _build_map_buttons() -> void:
	var row := HBoxContainer.new()
	row.name = "MapButtons"
	row.add_theme_constant_override("separation", 2)
	row.set_anchors_preset(Control.PRESET_CENTER_BOTTOM)
	row.offset_left = -72.0
	row.offset_right = 72.0
	row.offset_top = -18.0
	row.offset_bottom = 26.0
	row.alignment = BoxContainer.ALIGNMENT_CENTER
	_map.add_child(row)

	# The three round buttons under the reference's map: zoom out, recentre, zoom in.
	# Each is its icon - the round chrome button has no room for a caption, and an
	# arrow says "zoom" better than a minus sign does.
	for spec in [["minimap_zoom_out", -1, "Zoom out"], ["minimap_player", 0, "Recentre on me"], ["minimap_zoom_in", 1, "Zoom in"]]:
		var b := UITheme.icon_button(String(spec[0]), String(spec[2]), 28.0)
		var dir: int = spec[1]
		b.pressed.connect(func(): _map_zoom_step(dir))
		row.add_child(b)


func _map_zoom_step(direction: int) -> void:
	if direction == 0:
		_map_zoom = 150.0
	else:
		_map_zoom = clampf(_map_zoom * (0.72 if direction > 0 else 1.39),
			MAP_ZOOM_MIN, MAP_ZOOM_MAX)
	if _map_cam != null:
		_map_cam.size = _map_zoom


func show_dialogue(speaker: String, lines: Array) -> void:
	_dialog_panel.show()
	_dialog_text.text = "[%s]\n%s\n\n(Esc to close)" % [speaker, "\n".join(lines)]
	await get_tree().create_timer(6.0).timeout
	if is_instance_valid(_dialog_panel):
		_dialog_panel.hide()

func _refresh_quest() -> void:
	if _quest_label and has_node("/root/QuestManager"):
		_quest_label.text = QuestManager.tracker_text()


## The controls card yields to the notification stack when the canvas shrinks.
func _sync_help_visibility() -> void:
	if _help_panel != null: _help_panel.hide()
	_arcane_overlay_layout()
	return

func _legacy_help_visibility() -> void:
	if _help_panel == null:
		return
	var canvas := get_viewport().get_visible_rect().size
	_help_panel.visible = canvas.y >= HELP_MIN_CANVAS_H

func _process(_delta: float) -> void:
	if not is_instance_valid(_player):
		return
	_follow_minimap()
	_update_minimap()
	_update_zone()
	_update_boss()
	_update_vignette()


## Park the map camera over the player. It only renders while the overlay is on
## screen: the viewport is a second pass over the whole 3D scene, and the perf
## captures hide this layer, so paying for it then would be pure waste.
func _follow_minimap() -> void:
	if _map_cam == null:
		return
	_map_cam.global_position = _player.global_position + Vector3.UP * 120.0
	if _map_view != null:
		# `CanvasLayer` is a Node, not a CanvasItem, so it has `visible` but no
		# `is_visible_in_tree`.
		var wanted := SubViewport.UPDATE_ALWAYS if visible else SubViewport.UPDATE_DISABLED
		if _map_view.render_target_update_mode != wanted:
			_map_view.render_target_update_mode = wanted

## World position -> pixel inside the map disc.
##
## The map camera is orthographic and looks straight down, so the projection is
## a plain scale around the player. With `rotation_degrees = (-90, 0, 0)` the
## camera's up axis is -Z, which puts world +X to the right and world +Z down -
## the same handedness a top-down map is read with.
func _world_to_map(pos: Vector3) -> Vector2:
	if not is_instance_valid(_player):
		return Vector2.ZERO
	var centre := _player.global_position
	var span := maxf(_map_zoom, 1.0)
	var half := MAP_PX * 0.5
	return Vector2(
		half + (pos.x - centre.x) / span * MAP_PX,
		half + (pos.z - centre.z) / span * MAP_PX
	)

## A map marker: one of the minimap icons in a fixed box. The player is the
## arrow, a mob the red shard, a boss the crown, an NPC the figure and a monolith
## the purple spike, so the map says what a marker is and not only where it is.
func _dot(key: String, icon_id: String, size: float) -> Control:
	if not _dots.has(key):
		var marker := TextureRect.new()
		marker.name = key
		marker.texture = UITheme.chrome(icon_id)
		marker.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
		marker.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
		marker.mouse_filter = Control.MOUSE_FILTER_IGNORE
		_map_overlay.add_child(marker)
		_dots[key] = marker
	var d: Control = _dots[key]
	d.custom_minimum_size = Vector2(size, size)
	d.size = Vector2(size, size)
	return d

func _update_minimap() -> void:
	if _map == null:
		return
	var player_size := 16.0
	var pd := _dot("__player", "minimap_player", player_size)
	pd.position = _world_to_map(_player.global_position) - Vector2(player_size, player_size) * 0.5
	# mobs: the crown for a world boss, the shard for the rest
	for m in get_tree().get_nodes_in_group("mobs"):
		if not is_instance_valid(m):
			continue
		var boss: bool = "is_boss" in m and bool(m.is_boss)
		var size := 14.0 if boss else 10.0
		var d := _dot("mob_%d" % m.get_instance_id(), "minimap_boss" if boss else "minimap_mob", size)
		d.visible = m.state != 5
		d.position = _world_to_map(m.global_position) - Vector2(size, size) * 0.5
	# monoliths
	for mo in get_tree().get_nodes_in_group("monoliths"):
		if not is_instance_valid(mo):
			continue
		var size := 14.0
		var d := _dot("mon_%d" % mo.get_instance_id(), "minimap_monolith", size)
		d.position = _world_to_map(mo.global_position) - Vector2(size, size) * 0.5
	# npcs
	for n in get_tree().get_nodes_in_group("npcs"):
		if not is_instance_valid(n):
			continue
		var size := 12.0
		var d := _dot("npc_%d" % n.get_instance_id(), "minimap_npc", size)
		d.position = _world_to_map(n.global_position) - Vector2(size, size) * 0.5
	# Clip icon extents to the disc, not merely to its rectangular Control.
	for key in _dots:
		var dot: Control = _dots[key]
		var radius := MAP_PX * 0.5 - dot.size.length() * 0.5 - 4.0
		var inside := (dot.position + dot.size*0.5 - Vector2.ONE*MAP_PX*0.5).length() <= radius
		if key.begins_with("mob_"):
			dot.visible = dot.visible and inside
		else: dot.visible = inside
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

## The banner announces the place the player actually is. Indoors the
## outdoor zones do not apply, so the floor name from the map controller's
## authored floor table is announced instead of a stale "Hogwarts Grounds".
func location_for_banner() -> String:
	var controller := _map_controller()
	if controller != null and String(controller.get("current_map")) == "castle_interior" \
			and controller.has_method("floor_display"):
		return String(controller.call("floor_display", "castle_interior", _player.global_position.y))
	return zone_at(_player.global_position)

func _map_controller() -> Node:
	var world := get_parent()
	if world == null:
		return null
	return world.get_node_or_null("MapController")

func _update_zone() -> void:
	var z := location_for_banner()
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
		# The authority's health delta for the target wins over the
		# node's own copy (which is the snapshot mirror when the boss is a
		# replicated view).
		var binder := _resolve_binder()
		if binder != null and binder.has_target_health():
			_boss_bar.max_value = binder.target_max_hp()
			_boss_bar.value = binder.target_hp()
		else:
			_boss_bar.max_value = (t as Node3D).get("max_hp")
			_boss_bar.value = (t as Node3D).get("current_hp")
	else:
		_boss_panel.hide()

## The HUD's authoritative binder, when the HUD is present (it is created before
## the overlay). Kept optional so the overlay still runs in a bare test scene.
func _resolve_binder() -> UIStateBinder:
	if _binder != null and is_instance_valid(_binder):
		return _binder
	var world := get_parent()
	if world == null:
		return null
	var hud := world.get_node_or_null("CanvasLayer/HUD")
	if hud != null and "binder" in hud:
		_binder = hud.binder
	return _binder

func _update_vignette() -> void:
	var hp: int = int(_player.get("current_hp"))
	var max_hp: int = int(_player.get("max_hp"))
	if max_hp > 0:
		var missing: float = 1.0 - float(hp) / float(max_hp)
		var target_a: float = clamp((missing - 0.55) * 1.2, 0.0, 0.45)
		_vignette.color.a = lerpf(_vignette.color.a, target_a, 0.1)

func _arcane_overlay_layout() -> void:
	if _map == null: return
	var canvas := get_viewport().get_visible_rect().size
	var compact := canvas.x < 1000 or canvas.y < 560
	var scale_factor := 0.70 if compact else 1.0
	_map.scale = Vector2.ONE * scale_factor
	_map.offset_left = -16 - MAP_PX * scale_factor
	_map.offset_right = _map.offset_left + MAP_PX
	if _quest_panel != null:
		_quest_panel.custom_minimum_size = Vector2.ZERO
		UILayout.place(_quest_panel, Vector2(-226 if compact else -276,182 if compact else 250), Vector2(210 if compact else 260,84 if compact else 126))
		_quest_panel.theme_type_variation = &"ArcaneCard"
		_quest_label.custom_minimum_size = Vector2(186 if compact else 236,0)
		_quest_label.max_lines_visible = 2 if compact else 4
		_quest_label.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
		_quest_panel.clip_contents = true
	if _boss_panel != null:
		_boss_panel.custom_minimum_size = Vector2.ZERO
		UILayout.place(_boss_panel, Vector2(-120 if compact else -180,102), Vector2(240 if compact else 360,40))
