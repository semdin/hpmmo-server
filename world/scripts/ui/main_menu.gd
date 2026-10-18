extends Control

## HPMMO login screen - the game's front door.
##
## The launcher only installs, updates and starts the game; signing in happens
## here. The screen is built in code from `UITheme` (the palette and faces the
## HUD uses), so the first thing a player sees and the world they enter read as
## one client.
##
## Flow: account login (or create an account, which then logs straight in) ->
## character list -> join the world server -> `character_select.tscn`.
##
## Maintenance: the account service answers `/api/login` with 503
## `code=maintenance` while a deployment holds the world, and `/api/status`
## reports it. The screen polls that status, shows a server pill, and turns a
## refused login into a clear "under maintenance" notice. A player who was
## disconnected by a maintenance cycle comes back here with the same notice
## (`LOGIN_NOTICE_META`, set by `MaintenanceUI`).
##
## Command line (tests, tools): --solo/--offline, --user U, --pass P,
## --autologin, --no-autologin, --ip/--server HOST, --port N, --api-port=N.

const DEFAULT_SERVER_IP := "213.250.145.75"
const DEFAULT_GAME_PORT := 7777
const DEFAULT_API_PORT := 8081
const STATUS_POLL_SECONDS := 15.0
const PREFS_PATH := "user://login_prefs.json"
## Root-node meta a scene sets before returning here, read once on `_ready`.
const LOGIN_NOTICE_META := "hpmmo_login_notice"
## Set by the Esc menu's "Change character": the login session is still valid,
## so skip the sign-in and rejoin the world straight to the character screen.
const REJOIN_META := "hpmmo_rejoin_characters"
const CARD_WIDTH := 430.0

const COLOR_ERROR := Color(0.96, 0.47, 0.42)
const COLOR_WARN := Color(1.0, 0.74, 0.36)

## Account-service port. Resolved once, in this order: an explicit
## `--api-port=N`; the port of `HPMMO_API_URL`; `api_port` in
## client_config.json; 8081.
var api_port: int = 0
var server_ip: String = DEFAULT_SERVER_IP
var server_port: int = DEFAULT_GAME_PORT

var register_mode := false
var busy := false
## ONLINE | MAINTENANCE (or a countdown state) | OFFLINE | UNKNOWN
var server_state := "UNKNOWN"
var characters_cache: Array = []

var username_input: LineEdit
var password_input: LineEdit
var confirm_input: LineEdit
var confirm_block: Control
var reveal_btn: Button
var remember_check: CheckBox
var submit_btn: Button
var login_tab: Button
var register_tab: Button
var status_label: Label
var notice_panel: PanelContainer
var notice_title: Label
var notice_body: Label
var server_pill: PanelContainer
var server_dot: Panel
var server_label: Label
var version_label: Label

var _status_timer: Timer
var _status_in_flight := false

func _ready() -> void:
	theme = UITheme.get_theme()
	_pin_menu_music()
	_build()
	_load_client_config()
	_load_prefs()
	_set_mode(false)
	_handle_cmdline_args()
	_consume_login_notice()
	_start_status_poll()
	if _consume_rejoin():
		return
	if username_input.text.is_empty():
		username_input.call_deferred("grab_focus")
	else:
		password_input.call_deferred("grab_focus")

## The front end owns a calm classical bed. Entering the world releases the
## pin: the AudioManager hands the soundtrack to the zone and combat logic as
## soon as it finds the local player.
func _pin_menu_music() -> void:
	var audio := get_node_or_null("/root/AudioManager")
	if audio != null and audio.has_method("set_music_state"):
		audio.call("set_music_state", "menu")

## ================================================================ layout

func _build() -> void:
	_build_backdrop()

	# The login column sits over the darkened left of the key art; the wizard
	# and the castle stay visible on the right.
	var column := VBoxContainer.new()
	column.name = "LoginColumn"
	column.set_anchors_preset(Control.PRESET_LEFT_WIDE)
	column.offset_left = 72.0
	column.offset_right = 72.0 + CARD_WIDTH
	column.alignment = BoxContainer.ALIGNMENT_CENTER
	column.add_theme_constant_override("separation", 18)
	add_child(column)

	column.add_child(_build_crest())
	column.add_child(_build_card())

	_build_server_pill()
	_build_footer()

func _build_backdrop() -> void:
	var bg := TextureRect.new()
	bg.name = "Background"
	bg.set_anchors_preset(Control.PRESET_FULL_RECT)
	bg.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	bg.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_COVERED
	bg.mouse_filter = Control.MOUSE_FILTER_IGNORE
	var art := "res://assets/branding/hpmmo_banner.jpg"
	if ResourceLoader.exists(art):
		bg.texture = load(art) as Texture2D
	add_child(bg)

	# Left-to-right shade: deep behind the form, clear over the hero.
	add_child(_gradient_rect("ShadeLeft", [
		[0.0, Color(0.02, 0.025, 0.04, 0.94)],
		[0.34, Color(0.02, 0.025, 0.04, 0.80)],
		[0.62, Color(0.02, 0.025, 0.04, 0.0)],
	], false))
	# Bottom fade, so the footer always has contrast.
	add_child(_gradient_rect("ShadeBottom", [
		[0.0, Color(0, 0, 0, 0)],
		[0.78, Color(0, 0, 0, 0)],
		[1.0, Color(0, 0, 0, 0.75)],
	], true))
	_build_embers()

func _gradient_rect(node_name: String, stops: Array, vertical: bool) -> TextureRect:
	var offsets := PackedFloat32Array()
	var colours := PackedColorArray()
	for stop in stops:
		offsets.append(float(stop[0]))
		colours.append(stop[1])
	var gradient := Gradient.new()
	gradient.offsets = offsets
	gradient.colors = colours
	var tex := GradientTexture2D.new()
	tex.gradient = gradient
	tex.width = 8 if vertical else 512
	tex.height = 512 if vertical else 8
	tex.fill_from = Vector2(0, 0)
	tex.fill_to = Vector2(0, 1) if vertical else Vector2(1, 0)
	var rect := TextureRect.new()
	rect.name = node_name
	rect.texture = tex
	rect.set_anchors_preset(Control.PRESET_FULL_RECT)
	rect.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	rect.stretch_mode = TextureRect.STRETCH_SCALE
	rect.mouse_filter = Control.MOUSE_FILTER_IGNORE
	return rect

## Slow embers drifting up from the bottom edge - the key art's own sparks.
func _build_embers() -> void:
	if DisplayServer.get_name() == "headless":
		return
	var embers := CPUParticles2D.new()
	embers.name = "Embers"
	embers.amount = 46
	embers.lifetime = 9.0
	embers.preprocess = 9.0
	embers.emission_shape = CPUParticles2D.EMISSION_SHAPE_RECTANGLE
	embers.emission_rect_extents = Vector2(900, 10)
	embers.position = Vector2(640, 760)
	embers.direction = Vector2(0, -1)
	embers.spread = 18.0
	embers.gravity = Vector2(0, -6)
	embers.initial_velocity_min = 18.0
	embers.initial_velocity_max = 46.0
	embers.scale_amount_min = 1.2
	embers.scale_amount_max = 3.0
	var ramp := Gradient.new()
	ramp.set_color(0, Color(1.0, 0.62, 0.25, 0.0))
	ramp.set_color(1, Color(1.0, 0.45, 0.15, 0.0))
	ramp.add_point(0.15, Color(1.0, 0.7, 0.3, 0.85))
	ramp.add_point(0.7, Color(1.0, 0.5, 0.2, 0.5))
	embers.color_ramp = ramp
	add_child(embers)
	resized.connect(func(): embers.position = Vector2(size.x * 0.5, size.y + 40.0))

func _build_crest() -> Control:
	var box := VBoxContainer.new()
	box.name = "Crest"
	box.alignment = BoxContainer.ALIGNMENT_CENTER
	box.add_theme_constant_override("separation", 2)
	box.mouse_filter = Control.MOUSE_FILTER_IGNORE

	var title := Label.new()
	title.name = "TitleLabel"
	title.text = "HPMMO"
	title.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	var deco := "res://assets/fonts/CinzelDecorative-Bold.ttf"
	title.add_theme_font_override("font", load(deco) as Font if ResourceLoader.exists(deco) else UITheme.font_title())
	title.add_theme_font_size_override("font_size", 64)
	title.add_theme_color_override("font_color", UITheme.c("gold_hi"))
	title.add_theme_color_override("font_outline_color", Color(0.12, 0.06, 0.02))
	title.add_theme_constant_override("outline_size", 10)
	title.add_theme_color_override("font_shadow_color", Color(1.0, 0.55, 0.15, 0.35))
	title.add_theme_constant_override("shadow_outline_size", 22)
	box.add_child(title)

	var subtitle := Label.new()
	subtitle.name = "SubtitleLabel"
	subtitle.text = "BÜYÜCÜLÜK DİYARI"
	subtitle.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	subtitle.add_theme_font_override("font", UITheme.font_title())
	subtitle.add_theme_font_size_override("font_size", 15)
	subtitle.add_theme_color_override("font_color", UITheme.c("gold_lt"))
	subtitle.add_theme_color_override("font_outline_color", Color(0, 0, 0))
	subtitle.add_theme_constant_override("outline_size", 4)
	box.add_child(subtitle)

	box.add_child(_ornament())
	return box

## A gold rule with a diamond at its centre.
func _ornament() -> Control:
	var row := HBoxContainer.new()
	row.alignment = BoxContainer.ALIGNMENT_CENTER
	row.add_theme_constant_override("separation", 8)
	row.mouse_filter = Control.MOUSE_FILTER_IGNORE
	row.custom_minimum_size = Vector2(0, 18)
	for i in 3:
		if i == 1:
			var gem := Panel.new()
			var gs := StyleBoxFlat.new()
			gs.bg_color = UITheme.c("gold_lt")
			gs.set_corner_radius_all(1)
			gem.add_theme_stylebox_override("panel", gs)
			gem.custom_minimum_size = Vector2(8, 8)
			gem.rotation_degrees = 45.0
			gem.pivot_offset = Vector2(4, 4)
			gem.size_flags_vertical = Control.SIZE_SHRINK_CENTER
			gem.mouse_filter = Control.MOUSE_FILTER_IGNORE
			row.add_child(gem)
		else:
			var line := Panel.new()
			var ls := StyleBoxFlat.new()
			ls.bg_color = UITheme.alpha("gold", 0.8)
			line.add_theme_stylebox_override("panel", ls)
			line.custom_minimum_size = Vector2(120, 1)
			line.size_flags_vertical = Control.SIZE_SHRINK_CENTER
			line.mouse_filter = Control.MOUSE_FILTER_IGNORE
			row.add_child(line)
	return row

func _build_card() -> Control:
	var card := PanelContainer.new()
	card.name = "LoginCard"
	var sb := StyleBoxFlat.new()
	sb.bg_color = Color(0.043, 0.06, 0.094, 0.9)
	sb.border_color = UITheme.alpha("gold", 0.75)
	sb.set_border_width_all(1)
	sb.border_width_top = 2
	sb.set_corner_radius_all(8)
	sb.shadow_color = Color(0, 0, 0, 0.55)
	sb.shadow_size = 22
	sb.shadow_offset = Vector2(0, 8)
	sb.content_margin_left = 30
	sb.content_margin_right = 30
	sb.content_margin_top = 22
	sb.content_margin_bottom = 26
	card.add_theme_stylebox_override("panel", sb)

	var v := VBoxContainer.new()
	v.add_theme_constant_override("separation", 14)
	card.add_child(v)

	# Mode tabs.
	var tabs := HBoxContainer.new()
	tabs.add_theme_constant_override("separation", 0)
	login_tab = _tab_button("GİRİŞ YAP")
	register_tab = _tab_button("HESAP OLUŞTUR")
	login_tab.pressed.connect(func(): _set_mode(false))
	register_tab.pressed.connect(func(): _set_mode(true))
	tabs.add_child(login_tab)
	tabs.add_child(register_tab)
	v.add_child(tabs)

	username_input = _line_edit("Kullanıcı adın")
	username_input.name = "UsernameInput"
	username_input.max_length = 24
	v.add_child(_field("KULLANICI ADI", username_input))

	password_input = _line_edit("Şifren")
	password_input.name = "PasswordInput"
	password_input.secret = true
	password_input.max_length = 128
	reveal_btn = Button.new()
	reveal_btn.name = "RevealButton"
	reveal_btn.text = "Göster"
	reveal_btn.flat = true
	reveal_btn.focus_mode = Control.FOCUS_NONE
	reveal_btn.add_theme_font_size_override("font_size", 13)
	reveal_btn.add_theme_color_override("font_color", UITheme.c("text_dim"))
	reveal_btn.add_theme_color_override("font_hover_color", UITheme.c("gold_hi"))
	reveal_btn.pressed.connect(_toggle_reveal)
	var pass_row := HBoxContainer.new()
	pass_row.add_theme_constant_override("separation", 6)
	password_input.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	pass_row.add_child(password_input)
	pass_row.add_child(reveal_btn)
	v.add_child(_field("ŞİFRE", pass_row))

	confirm_input = _line_edit("Şifreni tekrar yaz")
	confirm_input.name = "ConfirmInput"
	confirm_input.secret = true
	confirm_input.max_length = 128
	confirm_block = _field("ŞİFRE (TEKRAR)", confirm_input)
	v.add_child(confirm_block)

	remember_check = CheckBox.new()
	remember_check.name = "RememberCheck"
	remember_check.text = "Kullanıcı adımı hatırla"
	remember_check.button_pressed = true
	remember_check.focus_mode = Control.FOCUS_NONE
	remember_check.add_theme_font_size_override("font_size", 14)
	remember_check.add_theme_color_override("font_color", UITheme.c("text_dim"))
	remember_check.add_theme_color_override("font_hover_color", UITheme.c("text"))
	remember_check.add_theme_color_override("font_pressed_color", UITheme.c("text"))
	remember_check.add_theme_color_override("font_hover_pressed_color", UITheme.c("text"))
	# The theme gives every Button-derived control a plate; a checkbox wants none.
	for state in ["normal", "hover", "pressed", "hover_pressed", "disabled", "focus"]:
		remember_check.add_theme_stylebox_override(state, StyleBoxEmpty.new())
	v.add_child(remember_check)

	notice_panel = _build_notice()
	v.add_child(notice_panel)

	submit_btn = _primary_button("OYUNA GİR")
	submit_btn.name = "SubmitButton"
	submit_btn.pressed.connect(_on_submit)
	v.add_child(submit_btn)

	status_label = Label.new()
	status_label.name = "StatusLabel"
	status_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	status_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	status_label.custom_minimum_size = Vector2(0, 40)
	status_label.add_theme_font_size_override("font_size", 14)
	v.add_child(status_label)

	username_input.text_submitted.connect(func(_t: String): password_input.grab_focus())
	password_input.text_submitted.connect(func(_t: String):
		if register_mode:
			confirm_input.grab_focus()
		else:
			_on_submit())
	confirm_input.text_submitted.connect(func(_t: String): _on_submit())
	return card

func _field(caption: String, input: Control) -> Control:
	var box := VBoxContainer.new()
	box.add_theme_constant_override("separation", 6)
	var label := Label.new()
	label.text = caption
	label.add_theme_font_override("font", UITheme.font_title())
	label.add_theme_font_size_override("font_size", 12)
	label.add_theme_color_override("font_color", UITheme.c("gold_lt"))
	label.mouse_filter = Control.MOUSE_FILTER_IGNORE
	box.add_child(label)
	box.add_child(input)
	return box

func _line_edit(placeholder: String) -> LineEdit:
	var edit := LineEdit.new()
	edit.placeholder_text = placeholder
	edit.custom_minimum_size = Vector2(0, 44)
	edit.add_theme_font_size_override("font_size", 17)
	edit.add_theme_color_override("font_color", UITheme.c("parchment"))
	edit.add_theme_color_override("font_placeholder_color", UITheme.alpha("text_dim", 0.6))
	edit.add_theme_color_override("caret_color", UITheme.c("gold_hi"))
	edit.add_theme_color_override("selection_color", UITheme.alpha("gold", 0.45))
	var normal := StyleBoxFlat.new()
	normal.bg_color = Color(0.02, 0.027, 0.043, 0.92)
	normal.border_color = UITheme.c("steel_lt")
	normal.set_border_width_all(1)
	normal.set_corner_radius_all(5)
	normal.content_margin_left = 14
	normal.content_margin_right = 14
	var focus := normal.duplicate() as StyleBoxFlat
	focus.border_color = UITheme.c("gold_lt")
	focus.shadow_color = UITheme.alpha("gold", 0.25)
	focus.shadow_size = 6
	var read_only := normal.duplicate() as StyleBoxFlat
	read_only.bg_color = Color(0.05, 0.055, 0.07, 0.8)
	edit.add_theme_stylebox_override("normal", normal)
	edit.add_theme_stylebox_override("focus", focus)
	edit.add_theme_stylebox_override("read_only", read_only)
	return edit

func _tab_button(text: String) -> Button:
	var b := Button.new()
	b.text = text
	b.toggle_mode = true
	b.focus_mode = Control.FOCUS_NONE
	b.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	b.custom_minimum_size = Vector2(0, 40)
	b.add_theme_font_override("font", UITheme.font_title())
	b.add_theme_font_size_override("font_size", 14)
	b.add_theme_color_override("font_color", UITheme.c("text_dim"))
	b.add_theme_color_override("font_hover_color", UITheme.c("parchment"))
	b.add_theme_color_override("font_pressed_color", UITheme.c("gold_hi"))
	b.add_theme_color_override("font_hover_pressed_color", UITheme.c("gold_hi"))
	var idle := StyleBoxFlat.new()
	idle.bg_color = Color(0, 0, 0, 0)
	idle.border_color = UITheme.alpha("steel_lt", 0.7)
	idle.border_width_bottom = 1
	var active := idle.duplicate() as StyleBoxFlat
	active.border_color = UITheme.c("gold_lt")
	active.border_width_bottom = 2
	active.bg_color = UITheme.alpha("gold", 0.06)
	b.add_theme_stylebox_override("normal", idle)
	b.add_theme_stylebox_override("hover", idle)
	b.add_theme_stylebox_override("pressed", active)
	b.add_theme_stylebox_override("hover_pressed", active)
	b.add_theme_stylebox_override("disabled", idle)
	return b

func _primary_button(text: String) -> Button:
	var b := Button.new()
	b.text = text
	b.custom_minimum_size = Vector2(0, 52)
	b.add_theme_font_override("font", UITheme.font_title())
	b.add_theme_font_size_override("font_size", 19)
	b.add_theme_color_override("font_color", UITheme.c("gold_hi"))
	b.add_theme_color_override("font_hover_color", Color(1, 0.97, 0.86))
	b.add_theme_color_override("font_pressed_color", UITheme.c("gold_lt"))
	b.add_theme_color_override("font_disabled_color", UITheme.alpha("text_dim", 0.7))
	b.add_theme_color_override("font_outline_color", Color(0.1, 0.02, 0.02))
	b.add_theme_constant_override("outline_size", 4)
	var normal := StyleBoxFlat.new()
	normal.bg_color = UITheme.c("blood")
	normal.border_color = UITheme.c("gold")
	normal.set_border_width_all(1)
	normal.border_width_top = 2
	normal.set_corner_radius_all(6)
	normal.shadow_color = Color(0, 0, 0, 0.45)
	normal.shadow_size = 6
	normal.shadow_offset = Vector2(0, 3)
	var hover := normal.duplicate() as StyleBoxFlat
	hover.bg_color = UITheme.c("blood_lt")
	hover.border_color = UITheme.c("gold_lt")
	hover.shadow_color = UITheme.alpha("gold", 0.3)
	hover.shadow_size = 10
	hover.shadow_offset = Vector2.ZERO
	var pressed := normal.duplicate() as StyleBoxFlat
	pressed.bg_color = UITheme.c("blood_dk")
	var disabled := normal.duplicate() as StyleBoxFlat
	disabled.bg_color = Color(0.13, 0.12, 0.13)
	disabled.border_color = UITheme.c("steel_lt")
	disabled.shadow_size = 0
	var focus := normal.duplicate() as StyleBoxFlat
	focus.draw_center = false
	focus.border_color = UITheme.c("gold_hi")
	b.add_theme_stylebox_override("normal", normal)
	b.add_theme_stylebox_override("hover", hover)
	b.add_theme_stylebox_override("pressed", pressed)
	b.add_theme_stylebox_override("disabled", disabled)
	b.add_theme_stylebox_override("focus", focus)
	return b

func _build_notice() -> PanelContainer:
	var panel := PanelContainer.new()
	panel.name = "MaintenanceNotice"
	var sb := StyleBoxFlat.new()
	sb.bg_color = Color(0.2, 0.09, 0.02, 0.92)
	sb.border_color = Color(1.0, 0.62, 0.22, 0.95)
	sb.set_border_width_all(1)
	sb.border_width_left = 3
	sb.set_corner_radius_all(5)
	sb.content_margin_left = 12
	sb.content_margin_right = 12
	sb.content_margin_top = 10
	sb.content_margin_bottom = 10
	panel.add_theme_stylebox_override("panel", sb)
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 12)
	panel.add_child(row)
	var lock := UITheme.icon_rect("ui_lock", 30.0)
	lock.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	row.add_child(lock)
	var texts := VBoxContainer.new()
	texts.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	texts.add_theme_constant_override("separation", 2)
	row.add_child(texts)
	notice_title = Label.new()
	notice_title.add_theme_font_override("font", UITheme.font_title())
	notice_title.add_theme_font_size_override("font_size", 15)
	notice_title.add_theme_color_override("font_color", Color(1.0, 0.8, 0.5))
	texts.add_child(notice_title)
	notice_body = Label.new()
	notice_body.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	notice_body.add_theme_font_size_override("font_size", 13)
	notice_body.add_theme_color_override("font_color", Color(1.0, 0.93, 0.84))
	texts.add_child(notice_body)
	panel.hide()
	return panel

func _build_server_pill() -> void:
	server_pill = PanelContainer.new()
	server_pill.name = "ServerPill"
	server_pill.set_anchors_preset(Control.PRESET_TOP_RIGHT)
	server_pill.grow_horizontal = Control.GROW_DIRECTION_BEGIN
	server_pill.offset_left = -260.0
	server_pill.offset_right = -28.0
	server_pill.offset_top = 24.0
	var sb := StyleBoxFlat.new()
	sb.bg_color = Color(0.03, 0.04, 0.06, 0.78)
	sb.border_color = UITheme.alpha("gold_dk", 0.9)
	sb.set_border_width_all(1)
	sb.set_corner_radius_all(16)
	sb.content_margin_left = 14
	sb.content_margin_right = 16
	sb.content_margin_top = 7
	sb.content_margin_bottom = 7
	server_pill.add_theme_stylebox_override("panel", sb)
	var row := HBoxContainer.new()
	row.alignment = BoxContainer.ALIGNMENT_END
	row.add_theme_constant_override("separation", 9)
	server_pill.add_child(row)
	server_dot = Panel.new()
	server_dot.custom_minimum_size = Vector2(10, 10)
	server_dot.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	row.add_child(server_dot)
	server_label = Label.new()
	server_label.add_theme_font_size_override("font_size", 14)
	server_label.add_theme_color_override("font_color", UITheme.c("text"))
	row.add_child(server_label)
	add_child(server_pill)
	_render_server_state()

func _build_footer() -> void:
	version_label = Label.new()
	version_label.name = "VersionLabel"
	version_label.set_anchors_preset(Control.PRESET_BOTTOM_LEFT)
	version_label.offset_left = 24.0
	version_label.offset_top = -34.0
	version_label.offset_bottom = -12.0
	version_label.grow_vertical = Control.GROW_DIRECTION_BEGIN
	version_label.text = "HPMMO  %s" % _client_version()
	version_label.add_theme_font_size_override("font_size", 12)
	version_label.add_theme_color_override("font_color", UITheme.alpha("text_dim", 0.8))
	add_child(version_label)

	var quit := Button.new()
	quit.name = "QuitButton"
	quit.text = "Oyundan Çık"
	quit.flat = true
	quit.focus_mode = Control.FOCUS_NONE
	quit.set_anchors_preset(Control.PRESET_BOTTOM_RIGHT)
	quit.grow_horizontal = Control.GROW_DIRECTION_BEGIN
	quit.grow_vertical = Control.GROW_DIRECTION_BEGIN
	quit.offset_left = -160.0
	quit.offset_right = -24.0
	quit.offset_top = -48.0
	quit.offset_bottom = -14.0
	quit.add_theme_font_size_override("font_size", 14)
	quit.add_theme_color_override("font_color", UITheme.c("text_dim"))
	quit.add_theme_color_override("font_hover_color", UITheme.c("parchment"))
	UITheme.set_button_icon(quit, "ui_close", 14.0)
	quit.pressed.connect(func(): get_tree().quit())
	add_child(quit)

func _client_version() -> String:
	var v := OS.get_environment("HPMMO_CLIENT_VERSION").strip_edges()
	if v.is_empty():
		v = str(ProjectSettings.get_setting("application/config/version", ""))
	return ("v" + v) if not v.is_empty() else "geliştirme sürümü"

## ================================================================ state

func _set_mode(p_register: bool) -> void:
	register_mode = p_register
	login_tab.set_pressed_no_signal(not register_mode)
	register_tab.set_pressed_no_signal(register_mode)
	confirm_block.visible = register_mode
	submit_btn.text = "HESABI OLUŞTUR" if register_mode else "OYUNA GİR"
	password_input.placeholder_text = "En az 8 karakter, harf ve rakam" if register_mode else "Şifren"
	confirm_input.text = ""
	_set_status("")

func _toggle_reveal() -> void:
	password_input.secret = not password_input.secret
	confirm_input.secret = password_input.secret
	reveal_btn.text = "Gizle" if not password_input.secret else "Göster"

func _set_busy(value: bool, message: String = "") -> void:
	busy = value
	submit_btn.disabled = value
	login_tab.disabled = value
	register_tab.disabled = value
	username_input.editable = not value
	password_input.editable = not value
	confirm_input.editable = not value
	if not message.is_empty():
		_set_status(message, "progress")

## kind: info | progress | error | warn | ok
func _set_status(message: String, kind: String = "info") -> void:
	if status_label == null:
		return
	status_label.text = message
	var colour: Color = UITheme.c("text_dim")
	match kind:
		"progress": colour = UITheme.c("gold_lt")
		"error": colour = COLOR_ERROR
		"warn": colour = COLOR_WARN
		"ok": colour = UITheme.c("good")
	status_label.add_theme_color_override("font_color", colour)

func _show_maintenance_notice(show_it: bool, detail: String = "") -> void:
	if notice_panel == null:
		return
	notice_panel.visible = show_it
	if show_it:
		notice_title.text = "Sunucu bakımda"
		notice_body.text = detail if not detail.is_empty() else \
			"Oyun şu anda güncelleniyor. Birkaç dakika sonra tekrar giriş yapabilirsin."

## ================================================================ server status

func _start_status_poll() -> void:
	_status_timer = Timer.new()
	_status_timer.wait_time = STATUS_POLL_SECONDS
	_status_timer.timeout.connect(_poll_status)
	add_child(_status_timer)
	_status_timer.start()
	_poll_status()

func _poll_status() -> void:
	if _status_in_flight or not is_inside_tree():
		return
	_status_in_flight = true
	DatabaseManager.get_server_status(_on_status)

func _on_status(status: Dictionary) -> void:
	_status_in_flight = false
	if not is_inside_tree():
		return
	var maintenance := bool(status.get("maintenance", false))
	server_state = "MAINTENANCE" if maintenance else str(status.get("state", "UNKNOWN")).to_upper()
	_render_server_state()
	if maintenance:
		_show_maintenance_notice(true)
	elif notice_panel.visible and server_state == "ONLINE":
		_show_maintenance_notice(false)
		if not busy:
			_set_status("Sunucu yeniden çevrimiçi. Giriş yapabilirsin.", "ok")

func _render_server_state() -> void:
	if server_label == null:
		return
	var colour := UITheme.c("text_dim")
	var text := "Sunucu durumu kontrol ediliyor…"
	match server_state:
		"ONLINE":
			colour = UITheme.c("good")
			text = "Sunucu çevrimiçi"
		"MAINTENANCE":
			colour = COLOR_WARN
			text = "Sunucu bakımda"
		"OFFLINE":
			colour = COLOR_ERROR
			text = "Sunucuya ulaşılamıyor"
	server_label.text = text
	var dot := StyleBoxFlat.new()
	dot.bg_color = colour
	dot.set_corner_radius_all(5)
	dot.shadow_color = Color(colour.r, colour.g, colour.b, 0.6)
	dot.shadow_size = 4
	server_dot.add_theme_stylebox_override("panel", dot)

## A scene that sends the player back here can leave a reason on the root.
func _consume_rejoin() -> bool:
	var root := get_tree().root
	if not root.has_meta(REJOIN_META):
		return false
	root.remove_meta(REJOIN_META)
	if DatabaseManager.session_token == "":
		return false
	if NetworkManager.last_server.size() == 2:
		server_ip = String(NetworkManager.last_server[0])
		server_port = int(NetworkManager.last_server[1])
	call_deferred("_enter_world_with_session")
	return true

func _consume_login_notice() -> void:
	var root := get_tree().root
	if not root.has_meta(LOGIN_NOTICE_META):
		return
	var notice := str(root.get_meta(LOGIN_NOTICE_META))
	root.remove_meta(LOGIN_NOTICE_META)
	if notice == "maintenance":
		_show_maintenance_notice(true,
			"Sunucu bakıma alındı ve oyundan çıkarıldın. İlerlemen kaydedildi; bakım bitince tekrar giriş yapabilirsin.")
		_set_status("Bakım tamamlanınca giriş yapabilirsin.", "warn")
	elif notice == "disconnected":
		_set_status("Sunucu bağlantısı koptu. Lütfen tekrar giriş yap.", "warn")

## ================================================================ auth

func _on_submit() -> void:
	if busy:
		return
	var user := username_input.text.strip_edges()
	var pass_w := password_input.text
	if user.is_empty() or pass_w.is_empty():
		_set_status("Lütfen kullanıcı adını ve şifreni gir.", "error")
		(username_input if user.is_empty() else password_input).grab_focus()
		return
	_apply_api_url()
	if register_mode:
		_do_register(user, pass_w)
	else:
		_do_login(user, pass_w)

func _do_register(user: String, pass_w: String) -> void:
	if user.length() < 3 or user.length() > 24:
		_set_status("Kullanıcı adı 3-24 karakter olmalı.", "error")
		return
	if pass_w.length() < 8:
		_set_status("Şifre en az 8 karakter olmalı.", "error")
		return
	if pass_w != confirm_input.text:
		_set_status("Şifreler eşleşmiyor.", "error")
		confirm_input.grab_focus()
		return
	_set_busy(true, "Hesap oluşturuluyor…")
	DatabaseManager.register_account(user, pass_w, func(res: Dictionary):
		if not is_inside_tree():
			return
		if bool(res.get("success", false)):
			# Straight in: nobody wants to type the password they just chose twice more.
			_set_busy(false)
			_set_mode(false)
			_set_status("Hesabın oluşturuldu! Giriş yapılıyor…", "ok")
			_do_login(user, pass_w)
			return
		_set_busy(false)
		_set_status(_error_text(res, "Hesap oluşturulamadı."), "error")
		if str(res.get("code", "")) == "maintenance":
			_show_maintenance_notice(true)
	)

func _do_login(user: String, pass_w: String) -> void:
	_set_busy(true, "Giriş yapılıyor…")
	DatabaseManager.login_account(user, pass_w, func(res: Dictionary):
		if not is_inside_tree():
			return
		if not bool(res.get("success", false)):
			_set_busy(false)
			if str(res.get("code", "")) == "maintenance":
				server_state = "MAINTENANCE"
				_render_server_state()
				_show_maintenance_notice(true)
				_set_status("Sunucu şu an bakımda. Lütfen biraz sonra tekrar dene.", "warn")
			else:
				_set_status(_error_text(res, "Giriş başarısız."), "error")
				password_input.select_all()
				password_input.grab_focus()
			return

		_save_prefs(user)
		GameSettings.use_account(user)   # this account's own settings from now on
		_show_maintenance_notice(false)
		DatabaseManager.session_token = str(res.get("token", ""))
		DatabaseManager.session_account_id = int(res.get("account_id", 0))
		DatabaseManager.session_active = true

		_set_status("Karakterlerin yükleniyor…", "progress")
		DatabaseManager.get_characters(DatabaseManager.session_account_id, func(char_res: Dictionary):
			if not is_inside_tree():
				return
			if not bool(char_res.get("success", false)):
				_set_busy(false)
				_set_status(_error_text(char_res, "Karakterler alınamadı."), "error")
				return
			characters_cache = char_res.get("characters", [])
			NetworkManager.local_character_data = {"characters": characters_cache}
			_enter_world_with_session()
		)
	)

## A player-facing sentence for a failed account-service call.
func _error_text(res: Dictionary, fallback: String) -> String:
	var code := str(res.get("code", ""))
	var status := int(res.get("http_status", 0))
	var message := str(res.get("message", ""))
	if code == "unreachable":
		return "Sunucuya ulaşılamadı. Sunucu güncelleniyor olabilir ya da bağlantın kopmuş olabilir; biraz sonra tekrar dene."
	if code == "maintenance":
		return "Sunucu şu an bakımda. Lütfen biraz sonra tekrar dene."
	match status:
		401:
			return "Kullanıcı adı veya şifre hatalı."
		409:
			return "Bu kullanıcı adı zaten alınmış."
		429:
			return "Çok fazla deneme yaptın. Biraz bekleyip tekrar dene."
		503:
			return "Sunucu şu an hizmet veremiyor. Biraz sonra tekrar dene."
		400:
			var known := {
				"Password must be at least 8 characters.": "Şifre en az 8 karakter olmalı.",
				"Password is too long (max 128).": "Şifre çok uzun (en fazla 128 karakter).",
				"Password must contain letters and digits.": "Şifre hem harf hem rakam içermeli.",
				"Username must be 3-24 characters.": "Kullanıcı adı 3-24 karakter olmalı.",
				"Username may contain only letters, digits, '_' and '-'.": "Kullanıcı adı yalnızca harf, rakam, '_' ve '-' içerebilir.",
			}
			if known.has(message):
				return known[message]
	if message.is_empty():
		return fallback
	return "%s (%s)" % [fallback, message]

## ================================================================ world entry

func _enter_world_with_session() -> void:
	_set_busy(true, "Dünyaya bağlanılıyor…")
	var err := NetworkManager.join_game(server_ip, server_port)
	if err != OK:
		_set_busy(false)
		_set_status("Oyun sunucusuna bağlanılamadı (hata %d)." % err, "error")
		return

	# The world refuses a join during a maintenance cycle with reason
	# "maintenance"; hear it instead of waiting for the timeout.
	var refusal := {"reason": ""}
	var on_joined := func(ok: bool, reason: String, _character: Dictionary) -> void:
		if not ok:
			refusal["reason"] = reason
	if SimNet.has_signal("joined"):
		SimNet.joined.connect(on_joined)
	var connected: bool = await _await_game_connection(8.0, refusal)
	if SimNet.has_signal("joined") and SimNet.joined.is_connected(on_joined):
		SimNet.joined.disconnect(on_joined)
	if not is_inside_tree():
		return
	if not connected:
		_set_busy(false)
		if str(refusal["reason"]) == "maintenance":
			NetworkManager.disconnect_game()
			server_state = "MAINTENANCE"
			_render_server_state()
			_show_maintenance_notice(true)
			_set_status("Sunucu şu an bakımda. Lütfen biraz sonra tekrar dene.", "warn")
		else:
			_set_status("Oyun sunucusu yanıt vermedi. Biraz sonra tekrar dene.", "error")
		_poll_status()
		return

	get_tree().change_scene_to_file("res://scenes/main/character_select.tscn")

func _await_game_connection(timeout_seconds: float, refusal: Dictionary = {}) -> bool:
	var waited := 0.0
	while waited < timeout_seconds:
		if NetworkManager.is_connected_to_game:
			return true
		if str(refusal.get("reason", "")) != "":
			return false
		await get_tree().create_timer(0.1).timeout
		waited += 0.1
	return NetworkManager.is_connected_to_game

## ================================================================ solo / offline

func _on_solo_pressed() -> void:
	NetworkManager.disconnect_game()
	GameSettings.use_account("offline")
	NetworkManager.start_offline()

	# Load existing offline saved character or use defaults
	var local_char = DatabaseManager.load_offline_character()
	if not local_char.is_empty():
		NetworkManager.local_character_data = local_char
		NetworkManager.local_player_name = local_char.get("name", "Wizard")
		NetworkManager.local_player_house = local_char.get("house", "Gryffindor")
		print("[MainMenu] Loaded saved offline character '%s' [Lv.%d]" % [NetworkManager.local_player_name, local_char.get("level", 1)])
	else:
		NetworkManager.local_player_name = "Wizard"
		NetworkManager.local_player_house = "Gryffindor"
		NetworkManager.local_character_data = {
			"name": "Wizard",
			"house": "Gryffindor",
			"level": 1,
			"exp": 0,
			"max_hp": 500,
			"current_hp": 500,
			"max_mana": 300,
			"current_mana": 300,
			"galleons": 500,
			"wand_tier": 0,
			"pos_x": 0.0,
			"pos_y": 0.5,
			"pos_z": 5.0,
			"rot_y": PI,
			"inventory": [
				{"id": "wand_hawthorn", "amount": 1, "tier": 0},
				{"id": "robe_apprentice", "amount": 1, "tier": 0},
				{"id": "broom_nimbus2000", "amount": 1, "tier": 0},
				{"id": "mat_phoenix_ash", "amount": 5, "tier": 0},
				{"id": "mat_dragon_heartstring", "amount": 2, "tier": 0},
				{"id": "potion_health", "amount": 5, "tier": 0},
				{"id": "potion_mana", "amount": 5, "tier": 0}
			],
			"quests": {}
		}

	if is_inside_tree() and get_tree():
		WorldLoader.enter_world(get_tree())

## ================================================================ config

## The port carried by an account-service URL, or 0 when it does not carry one.
func _api_port_from_url(url: String) -> int:
	var trimmed := url.strip_edges()
	if trimmed.is_empty():
		return 0
	var colon := trimmed.rfind(":")
	if colon < 0:
		return 0
	var tail := trimmed.substr(colon + 1)
	if not tail.is_valid_int():
		return 0
	return int(tail)

## The account-service port, resolved with the documented default. The URL the
## autoload already resolved (HPMMO_API_URL) is the first authority.
func _resolve_api_port() -> int:
	if api_port <= 0:
		api_port = _api_port_from_url(DatabaseManager.api_base_url)
	if api_port <= 0:
		api_port = DEFAULT_API_PORT
	return api_port

## Points the account service at the configured host, unless the environment
## (launcher/tests) already chose a URL.
func _apply_api_url() -> void:
	if OS.has_environment("HPMMO_API_URL"):
		DatabaseManager.api_base_url = OS.get_environment("HPMMO_API_URL").strip_edges().rstrip("/")
	else:
		DatabaseManager.api_base_url = "http://%s:%d" % [server_ip, _resolve_api_port()]

func _load_client_config() -> void:
	for p in ["res://client_config.json", "user://client_config.json"]:
		if not FileAccess.file_exists(p):
			continue
		var file := FileAccess.open(p, FileAccess.READ)
		if file == null:
			continue
		var parsed = JSON.parse_string(file.get_as_text())
		if not (parsed is Dictionary):
			continue
		server_ip = str(parsed.get("server_ip", DEFAULT_SERVER_IP))
		server_port = int(parsed.get("server_port", DEFAULT_GAME_PORT))
		if api_port == 0:
			api_port = int(parsed.get("api_port", DEFAULT_API_PORT))
		if parsed.has("last_username"):
			username_input.text = str(parsed["last_username"])
		print("[MainMenu] Loaded client configuration from %s" % p)
		break
	_apply_api_url()

## Only the username is remembered - never the password.
func _load_prefs() -> void:
	if not FileAccess.file_exists(PREFS_PATH):
		return
	var file := FileAccess.open(PREFS_PATH, FileAccess.READ)
	if file == null:
		return
	var parsed = JSON.parse_string(file.get_as_text())
	if not (parsed is Dictionary):
		return
	var remember := bool(parsed.get("remember", true))
	remember_check.button_pressed = remember
	if remember and str(parsed.get("username", "")) != "":
		username_input.text = str(parsed["username"])

func _save_prefs(user: String) -> void:
	var remember := remember_check.button_pressed
	var file := FileAccess.open(PREFS_PATH, FileAccess.WRITE)
	if file == null:
		return
	file.store_string(JSON.stringify({"remember": remember, "username": user if remember else ""}))

func _handle_cmdline_args() -> void:
	var args := OS.get_cmdline_args()
	if "--solo" in args or "--offline" in args:
		print("[MainMenu] Command-line flag --solo detected, starting offline mode...")
		call_deferred("_on_solo_pressed")
		return

	var user_val := ""
	var pass_val := ""
	var should_autologin := false

	# The account-service port first, so `--ip` anywhere on the line uses it.
	for arg in args:
		if arg.begins_with("--api-port="):
			api_port = int(arg.substr("--api-port=".length()))

	for i in range(args.size()):
		var arg: String = args[i]
		if arg == "--user" and i + 1 < args.size():
			user_val = args[i + 1]
		elif (arg == "--pass" or arg == "--password") and i + 1 < args.size():
			pass_val = args[i + 1]
		elif (arg == "--server" or arg == "--ip") and i + 1 < args.size():
			server_ip = args[i + 1]
		elif arg == "--port" and i + 1 < args.size():
			server_port = int(args[i + 1])
		elif arg == "--autologin":
			should_autologin = true
	_apply_api_url()

	if not user_val.is_empty():
		username_input.text = user_val
	if not pass_val.is_empty():
		password_input.text = pass_val

	if "--no-autologin" in args:
		return
	if should_autologin:
		print("[MainMenu] Auto-login requested for '%s'..." % user_val)
		if DatabaseManager.session_active or DatabaseManager.is_session_pending():
			_begin_launcher_session()
		elif not user_val.is_empty() and not pass_val.is_empty():
			call_deferred("_on_submit")
		else:
			_begin_launcher_session()

## A session handed over by an older launcher (HPMMO_TICKET).
func _begin_launcher_session() -> void:
	_set_busy(true, "Oturum doğrulanıyor…")
	if DatabaseManager.session_active:
		_on_launcher_session_ready(true, DatabaseManager.session_account_id)
	elif DatabaseManager.is_session_pending():
		DatabaseManager.session_established.connect(_on_launcher_session_ready, CONNECT_ONE_SHOT)
	else:
		_on_launcher_session_ready(false, 0)

func _on_launcher_session_ready(success: bool, _account_id: int) -> void:
	if not success:
		_set_busy(false)
		_set_status("Lütfen giriş yap.")
		return
	_set_status("Karakterlerin yükleniyor…", "progress")
	DatabaseManager.get_characters(0, func(res: Dictionary):
		if not bool(res.get("success", false)):
			_set_busy(false)
			_set_status(_error_text(res, "Karakterler alınamadı."), "error")
			return
		characters_cache = res.get("characters", [])
		NetworkManager.local_character_data = {"characters": characters_cache}
		_enter_world_with_session()
	)
