extends Control

## Main Menu for HPMMO
## Authentication (PostgreSQL/SQLite), Character Selection, Character Creation, & Solo Mode

# Panels
@onready var auth_panel: Control = $AuthPanel
@onready var char_select_panel: Control = $CharSelectPanel
@onready var char_create_panel: Control = $CharCreatePanel

# Auth Controls
@onready var username_input: LineEdit = $AuthPanel/Margin/VBox/UserRow/UsernameInput
@onready var password_input: LineEdit = $AuthPanel/Margin/VBox/PassRow/PasswordInput
@onready var ip_input: LineEdit = $AuthPanel/Margin/VBox/ServerRow/IpInput
@onready var port_input: LineEdit = $AuthPanel/Margin/VBox/ServerRow/PortInput
@onready var auth_status_label: Label = $AuthPanel/Margin/VBox/StatusLabel
@onready var login_btn: Button = $AuthPanel/Margin/VBox/ButtonsRow/LoginButton
@onready var register_btn: Button = $AuthPanel/Margin/VBox/ButtonsRow/RegisterButton
@onready var solo_btn: Button = $AuthPanel/Margin/VBox/SoloButton

# Character Selection Controls
@onready var char_list_container: VBoxContainer = $CharSelectPanel/Margin/VBox/CharListContainer
@onready var no_chars_label: Label = $CharSelectPanel/Margin/VBox/CharListContainer/NoCharsLabel
@onready var select_status_label: Label = $CharSelectPanel/Margin/VBox/SelectStatusLabel
@onready var enter_world_btn: Button = $CharSelectPanel/Margin/VBox/ButtonsRow/EnterWorldButton
@onready var new_char_btn: Button = $CharSelectPanel/Margin/VBox/ButtonsRow/NewCharButton
@onready var logout_btn: Button = $CharSelectPanel/Margin/VBox/ButtonsRow/LogoutButton

# Character Creation Controls
@onready var new_name_input: LineEdit = $CharCreatePanel/Margin/VBox/NameRow/NewCharNameInput
@onready var gryf_btn: Button = $CharCreatePanel/Margin/VBox/HouseButtons/GryffindorBtn
@onready var slyth_btn: Button = $CharCreatePanel/Margin/VBox/HouseButtons/SlytherinBtn
@onready var raven_btn: Button = $CharCreatePanel/Margin/VBox/HouseButtons/RavenclawBtn
@onready var huff_btn: Button = $CharCreatePanel/Margin/VBox/HouseButtons/HufflepuffBtn
@onready var house_desc_label: Label = $CharCreatePanel/Margin/VBox/HouseDescLabel
@onready var create_status_label: Label = $CharCreatePanel/Margin/VBox/CreateStatusLabel
@onready var confirm_create_btn: Button = $CharCreatePanel/Margin/VBox/ButtonsRow/ConfirmCreateBtn
@onready var cancel_create_btn: Button = $CharCreatePanel/Margin/VBox/ButtonsRow/CancelCreateBtn

var selected_house: String = "Gryffindor"
var selected_char_id: int = 0
var characters_cache: Array = []
var pending_auth: Dictionary = {} # {"action": "login"|"register", "user": "", "pass": ""}

func _ready() -> void:
	# Auth Buttons
	login_btn.pressed.connect(_on_login_pressed)
	register_btn.pressed.connect(_on_register_pressed)
	solo_btn.pressed.connect(_on_solo_pressed)
	
	# Character Select Buttons
	enter_world_btn.pressed.connect(_on_enter_world_pressed)
	new_char_btn.pressed.connect(_on_new_char_pressed)
	logout_btn.pressed.connect(_on_logout_pressed)
	
	# Character Create Buttons
	confirm_create_btn.pressed.connect(_on_confirm_create_pressed)
	cancel_create_btn.pressed.connect(_on_cancel_create_pressed)
	gryf_btn.pressed.connect(func(): _select_house("Gryffindor"))
	slyth_btn.pressed.connect(func(): _select_house("Slytherin"))
	raven_btn.pressed.connect(func(): _select_house("Ravenclaw"))
	huff_btn.pressed.connect(func(): _select_house("Hufflepuff"))
	
	# Network signals
	NetworkManager.connection_status_changed.connect(_on_network_status)
	NetworkManager.connection_succeeded.connect(_on_connection_succeeded)
	NetworkManager.connection_failed.connect(_on_connection_failed)
	NetworkManager.auth_register_result.connect(_on_auth_register_result)
	NetworkManager.auth_login_result.connect(_on_auth_login_result)
	NetworkManager.character_create_result.connect(_on_character_create_result)
	NetworkManager.character_select_result.connect(_on_character_select_result)
	
	# Dynamically load background banner safely without editor import dependency
	var bg_paths = ["res://assets/branding/hpmmo_banner.jpg", "res://launcher/assets/hpmmo_banner.jpg"]
	for p in bg_paths:
		if FileAccess.file_exists(p):
			var img = Image.load_from_file(ProjectSettings.globalize_path(p))
			if img and has_node("Background"):
				var tex = ImageTexture.create_from_image(img)
				$Background.texture = tex
				break
	
	_show_panel("auth")
	_select_house("Gryffindor")
	_load_client_config()
	_handle_cmdline_args()

func _exit_tree() -> void:
	if NetworkManager.connection_status_changed.is_connected(_on_network_status):
		NetworkManager.connection_status_changed.disconnect(_on_network_status)
	if NetworkManager.connection_succeeded.is_connected(_on_connection_succeeded):
		NetworkManager.connection_succeeded.disconnect(_on_connection_succeeded)
	if NetworkManager.connection_failed.is_connected(_on_connection_failed):
		NetworkManager.connection_failed.disconnect(_on_connection_failed)
	if NetworkManager.auth_register_result.is_connected(_on_auth_register_result):
		NetworkManager.auth_register_result.disconnect(_on_auth_register_result)
	if NetworkManager.auth_login_result.is_connected(_on_auth_login_result):
		NetworkManager.auth_login_result.disconnect(_on_auth_login_result)
	if NetworkManager.character_create_result.is_connected(_on_character_create_result):
		NetworkManager.character_create_result.disconnect(_on_character_create_result)
	if NetworkManager.character_select_result.is_connected(_on_character_select_result):
		NetworkManager.character_select_result.disconnect(_on_character_select_result)

func _show_panel(panel_name: String) -> void:
	auth_panel.visible = (panel_name == "auth")
	char_select_panel.visible = (panel_name == "select")
	char_create_panel.visible = (panel_name == "create")

func _select_house(h_name: String) -> void:
	selected_house = h_name
	if GameData.HOUSES.has(h_name):
		var data = GameData.HOUSES[h_name]
		house_desc_label.text = "%s - \"%s\"\n%s" % [data.name, data.motto, data.trait]
		house_desc_label.modulate = data.primary_color
	
	gryf_btn.flat = (h_name != "Gryffindor")
	slyth_btn.flat = (h_name != "Slytherin")
	raven_btn.flat = (h_name != "Ravenclaw")
	huff_btn.flat = (h_name != "Hufflepuff")

## -------------------------------------------------------------
## AUTHENTICATION ACTIONS
## -------------------------------------------------------------

func _on_login_pressed() -> void:
	var user = username_input.text.strip_edges()
	var pass_w = password_input.text.strip_edges()
	if user.is_empty() or pass_w.is_empty():
		auth_status_label.text = "Please enter both account username and password."
		return
	
	pending_auth = {"action": "login", "user": user, "pass": pass_w}
	_connect_to_server_if_needed()

func _on_register_pressed() -> void:
	var user = username_input.text.strip_edges()
	var pass_w = password_input.text.strip_edges()
	if user.length() < 3 or pass_w.length() < 4:
		auth_status_label.text = "Username must be >= 3 chars, password >= 4 chars."
		return
	
	pending_auth = {"action": "register", "user": user, "pass": pass_w}
	_connect_to_server_if_needed()

func _connect_to_server_if_needed() -> void:
	if NetworkManager.is_connected_to_game and NetworkManager.multiplayer.has_multiplayer_peer():
		_execute_pending_auth()
		return
	
	var ip = ip_input.text.strip_edges()
	if ip.is_empty():
		ip = "127.0.0.1"
	var port = int(port_input.text) if not port_input.text.is_empty() else 7777
	
	auth_status_label.text = "Connecting to %s:%d..." % [ip, port]
	login_btn.disabled = true
	register_btn.disabled = true
	
	var err = NetworkManager.join_game(ip, port)
	if err != OK:
		login_btn.disabled = false
		register_btn.disabled = false
		auth_status_label.text = "Failed to open network socket to server."

func _on_connection_succeeded() -> void:
	login_btn.disabled = false
	register_btn.disabled = false
	auth_status_label.text = "Connected! Authenticating..."
	_execute_pending_auth()

func _execute_pending_auth() -> void:
	if pending_auth.is_empty():
		return
	var action = pending_auth.get("action", "")
	var user = pending_auth.get("user", "")
	var pass_w = pending_auth.get("pass", "")
	
	if action == "login":
		NetworkManager.request_login(user, pass_w)
	elif action == "register":
		NetworkManager.request_register(user, pass_w)
	pending_auth.clear()

func _on_connection_failed() -> void:
	login_btn.disabled = false
	register_btn.disabled = false
	auth_status_label.text = "Connection failed! Check server IP & firewall."

func _on_network_status(msg: String) -> void:
	auth_status_label.text = msg

func _on_auth_register_result(success: bool, message: String) -> void:
	auth_status_label.text = message
	if success:
		auth_status_label.text = "Account created! Now click 'Log In' to enter."

func _on_auth_login_result(success: bool, message: String, characters: Array) -> void:
	auth_status_label.text = message
	if not success:
		_show_panel("auth")
		return
	
	characters_cache = characters
	NetworkManager.local_character_data = {"characters": characters}
	
	# Transition directly to 3D Character Selection Stage (Section 3.1 & 3.2 of plan.md)
	if ResourceLoader.exists("res://scenes/main/character_select.tscn"):
		get_tree().change_scene_to_file("res://scenes/main/character_select.tscn")
	else:
		_render_character_list(characters)
		_show_panel("select")

## -------------------------------------------------------------
## CHARACTER SELECTION ACTIONS
## -------------------------------------------------------------

func _render_character_list(chars: Array) -> void:
	# Clean previous character buttons
	for child in char_list_container.get_children():
		if child != no_chars_label:
			child.queue_free()
	
	if chars.is_empty():
		no_chars_label.visible = true
		enter_world_btn.disabled = true
		selected_char_id = 0
		return
	
	no_chars_label.visible = false
	enter_world_btn.disabled = false
	selected_char_id = chars[0].get("id", 0)
	
	for c in chars:
		var btn = Button.new()
		var char_id: int = c.get("id", 0)
		var c_name: String = c.get("name", "Wizard")
		var c_house: String = c.get("house", "Gryffindor")
		var c_level: int = c.get("level", 1)
		var c_wand: int = c.get("wand_tier", 0)
		var c_galleons: int = c.get("galleons", 500)
		
		btn.custom_minimum_size = Vector2(0, 48)
		btn.text = "%s  |  [%s]  |  Lv.%d  |  +%d Wand  |  %d Galleons" % [
			c_name, c_house, c_level, c_wand, c_galleons
		]
		
		if GameData.HOUSES.has(c_house):
			btn.modulate = GameData.HOUSES[c_house].primary_color.lerp(Color.WHITE, 0.4)
		
		btn.pressed.connect(func():
			selected_char_id = char_id
			select_status_label.text = "Selected: %s [%s]" % [c_name, c_house]
			for b in char_list_container.get_children():
				if b is Button:
					b.flat = (b != btn)
		)
		char_list_container.add_child(btn)
	
	select_status_label.text = "Selected: %s" % chars[0].get("name", "Wizard")

func _on_enter_world_pressed() -> void:
	if selected_char_id <= 0:
		select_status_label.text = "Please select a character first!"
		return
	
	select_status_label.text = "Loading character into Hogwarts Valley..."
	enter_world_btn.disabled = true
	NetworkManager.request_select_character(selected_char_id)

func _on_character_select_result(success: bool, message: String, _char_data: Dictionary) -> void:
	enter_world_btn.disabled = false
	if not success:
		select_status_label.text = message
		return
	
	if is_inside_tree() and get_tree():
		get_tree().change_scene_to_file("res://scenes/world/game_world.tscn")

func _on_new_char_pressed() -> void:
	create_status_label.text = ""
	_show_panel("create")

func _on_logout_pressed() -> void:
	NetworkManager.disconnect_game()
	_show_panel("auth")
	auth_status_label.text = "Logged out."

## -------------------------------------------------------------
## CHARACTER CREATION ACTIONS
## -------------------------------------------------------------

func _on_confirm_create_pressed() -> void:
	var c_name = new_name_input.text.strip_edges()
	if c_name.length() < 2:
		create_status_label.text = "Character name must be at least 2 characters."
		return
	
	create_status_label.text = "Creating character '%s' [%s]..." % [c_name, selected_house]
	confirm_create_btn.disabled = true
	NetworkManager.request_create_character(c_name, selected_house)

func _on_character_create_result(success: bool, message: String, char_data: Dictionary) -> void:
	confirm_create_btn.disabled = false
	create_status_label.text = message
	if success:
		characters_cache.append(char_data)
		_render_character_list(characters_cache)
		_show_panel("select")

func _on_cancel_create_pressed() -> void:
	_show_panel("select")

## -------------------------------------------------------------
## SOLO / OFFLINE MODE (Local Save Persistence)
## -------------------------------------------------------------

func _on_solo_pressed() -> void:
	NetworkManager.disconnect_game()
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
		get_tree().change_scene_to_file("res://scenes/world/game_world.tscn")

func _load_client_config() -> void:
	var paths = ["res://client_config.json", "user://client_config.json"]
	for p in paths:
		if FileAccess.file_exists(p):
			var file = FileAccess.open(p, FileAccess.READ)
			if file:
				var json_res = JSON.parse_string(file.get_as_text())
				if json_res is Dictionary:
					if json_res.has("server_ip") and ip_input:
						ip_input.text = str(json_res["server_ip"])
					if json_res.has("server_port") and port_input:
						port_input.text = str(json_res["server_port"])
					if json_res.has("last_username") and username_input:
						username_input.text = str(json_res["last_username"])
					print("[MainMenu] Loaded client configuration from %s" % p)
					return

func _handle_cmdline_args() -> void:
	var args = OS.get_cmdline_args()
	if "--solo" in args or "--offline" in args:
		print("[MainMenu] Command-line flag --solo detected, starting offline mode...")
		call_deferred("_on_solo_pressed")
		return

	var user_val := ""
	var pass_val := ""
	var should_autologin := false

	for i in range(args.size()):
		var arg = args[i]
		if arg == "--user" and i + 1 < args.size():
			user_val = args[i + 1]
		elif arg == "--pass" and i + 1 < args.size():
			pass_val = args[i + 1]
		elif (arg == "--server" or arg == "--ip") and i + 1 < args.size():
			if ip_input:
				ip_input.text = args[i + 1]
		elif arg == "--port" and i + 1 < args.size():
			if port_input:
				port_input.text = args[i + 1]
		elif arg == "--autologin":
			should_autologin = true

	if not user_val.is_empty() and username_input:
		username_input.text = user_val
	if not pass_val.is_empty() and password_input:
		password_input.text = pass_val

	if (should_autologin or (not user_val.is_empty() and not pass_val.is_empty() and "--no-autologin" not in args)):
		print("[MainMenu] Command-line credentials supplied for '%s', initiating auto-login..." % user_val)
		_show_panel("none")
		auth_status_label.text = "Giriş yapılıyor... 3D Karakter Sahnesine bağlanılıyor..."
		call_deferred("_on_login_pressed")
