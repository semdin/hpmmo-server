extends Node3D

## 3D Character Selection Stage (Section 3.2 of.md)
## Interactive 3D stone podium with glowing runes, rim lighting, atmospheric embers,
## house-specific robes, wand tier aura, max 2 characters per account, and arrow-key navigation.

@onready var camera: Camera3D = $Camera3D
@onready var podium: Node3D = $Podium
@onready var podium_light: OmniLight3D = $Podium/PodiumLight
@onready var rune_ring: MeshInstance3D = $Podium/RuneRing
@onready var model_anchor: Node3D = $Podium/ModelAnchor

# 2D UI References
@onready var slot_label: Label = $CanvasLayer/TopBar/SlotLabel
@onready var char_name_label: Label = $CanvasLayer/InfoCard/Margin/VBox/CharNameLabel
@onready var char_house_label: Label = $CanvasLayer/InfoCard/Margin/VBox/HouseLabel
@onready var char_stats_label: Label = $CanvasLayer/InfoCard/Margin/VBox/StatsLabel
@onready var char_wand_label: Label = $CanvasLayer/InfoCard/Margin/VBox/WandLabel
@onready var char_galleons_label: Label = $CanvasLayer/InfoCard/Margin/VBox/GalleonsLabel
@onready var char_location_label: Label = $CanvasLayer/InfoCard/Margin/VBox/LocationLabel

@onready var enter_world_btn: Button = $CanvasLayer/BottomBar/EnterWorldBtn
@onready var new_char_btn: Button = $CanvasLayer/BottomBar/NewCharBtn
@onready var prev_slot_btn: Button = $CanvasLayer/NavButtons/PrevSlotBtn
@onready var next_slot_btn: Button = $CanvasLayer/NavButtons/NextSlotBtn
@onready var logout_btn: Button = $CanvasLayer/TopBar/LogoutBtn

# Create Character Modal
@onready var create_modal: PanelContainer = $CanvasLayer/CreateModal
@onready var new_name_input: LineEdit = $CanvasLayer/CreateModal/Margin/VBox/NameRow/NewNameInput
@onready var modal_status_label: Label = $CanvasLayer/CreateModal/Margin/VBox/ModalStatusLabel
@onready var confirm_create_btn: Button = $CanvasLayer/CreateModal/Margin/VBox/Buttons/ConfirmCreateBtn
@onready var cancel_create_btn: Button = $CanvasLayer/CreateModal/Margin/VBox/Buttons/CancelCreateBtn
@onready var modal_house_desc: Label = $CanvasLayer/CreateModal/Margin/VBox/HouseDescLabel
@onready var gryf_btn: Button = $CanvasLayer/CreateModal/Margin/VBox/HouseRow/GryfBtn
@onready var slyth_btn: Button = $CanvasLayer/CreateModal/Margin/VBox/HouseRow/SlythBtn
@onready var raven_btn: Button = $CanvasLayer/CreateModal/Margin/VBox/HouseRow/RavenBtn
@onready var huff_btn: Button = $CanvasLayer/CreateModal/Margin/VBox/HouseRow/HuffBtn

var characters: Array = []
var current_slot: int = 0 # 0 or 1 (max 2 characters)
var selected_house: String = "Gryffindor"
var current_char_node: Node3D = null
var current_anim_player: AnimationPlayer = null
var is_switching: bool = false

func _ready() -> void:
	# Connect UI buttons
	_apply_icons()
	_pin_menu_music()
	enter_world_btn.pressed.connect(_on_enter_world_pressed)
	new_char_btn.pressed.connect(_on_new_char_pressed)
	prev_slot_btn.pressed.connect(func(): _switch_slot((current_slot - 1 + 2) % 2))
	next_slot_btn.pressed.connect(func(): _switch_slot((current_slot + 1) % 2))
	logout_btn.pressed.connect(_on_logout_pressed)

	confirm_create_btn.pressed.connect(_on_confirm_create_pressed)
	cancel_create_btn.pressed.connect(func(): create_modal.hide())
	gryf_btn.pressed.connect(func(): _select_modal_house("Gryffindor"))
	slyth_btn.pressed.connect(func(): _select_modal_house("Slytherin"))
	raven_btn.pressed.connect(func(): _select_modal_house("Ravenclaw"))
	huff_btn.pressed.connect(func(): _select_modal_house("Hufflepuff"))

	# Connect NetworkManager signals
	NetworkManager.character_create_result.connect(_on_character_create_result)
	NetworkManager.character_select_result.connect(_on_character_select_result)

	_select_modal_house("Gryffindor")
	create_modal.hide()

	# Retrieve characters from NetworkManager cache
	_load_characters()

func _exit_tree() -> void:
	if NetworkManager.character_create_result.is_connected(_on_character_create_result):
		NetworkManager.character_create_result.disconnect(_on_character_create_result)
	if NetworkManager.character_select_result.is_connected(_on_character_select_result):
		NetworkManager.character_select_result.disconnect(_on_character_select_result)

## The front end owns a calm classical bed. Entering the world releases the
## pin: the AudioManager hands the soundtrack to the zone and combat logic as
## soon as it finds the local player.
func _pin_menu_music() -> void:
	var audio := get_node_or_null("/root/AudioManager")
	if audio != null and audio.has_method("set_music_state"):
		audio.call("set_music_state", "menu")

## The house crests on the create-character buttons, and the glyph the plus sign
## used to be. The captions stay: the crest says which house, the caption names it.
func _apply_icons() -> void:
	var crests := {
		gryf_btn: "house_gryffindor",
		slyth_btn: "house_slytherin",
		raven_btn: "house_ravenclaw",
		huff_btn: "house_hufflepuff",
	}
	for button in crests:
		UITheme.set_button_icon(button, crests[button], 18.0)
	new_char_btn.text = "Yeni Büyücü Oluştur"
	UITheme.set_button_icon(new_char_btn, "minimap_zoom_in", 16.0)

func _unhandled_input(event: InputEvent) -> void:
	if create_modal.visible:
		return
	
	if event is InputEventKey and event.pressed and not event.echo:
		if event.keycode == KEY_LEFT or event.keycode == KEY_A:
			_switch_slot((current_slot - 1 + 2) % 2)
		elif event.keycode == KEY_RIGHT or event.keycode == KEY_D:
			_switch_slot((current_slot + 1) % 2)
		elif event.keycode == KEY_ENTER or event.keycode == KEY_KP_ENTER:
			if enter_world_btn.visible and not enter_world_btn.disabled:
				_on_enter_world_pressed()

func _load_characters() -> void:
	# If characters were passed from login, use them
	if NetworkManager.local_character_data.has("characters"):
		characters = NetworkManager.local_character_data["characters"]
	else:
		# Check offline local character or peer character list
		var offline_char = DatabaseManager.load_offline_character()
		if not offline_char.is_empty():
			characters = [offline_char]
		else:
			characters = []

	current_slot = 0
	_update_slot_display(false)

func _switch_slot(new_slot: int) -> void:
	if is_switching or new_slot == current_slot:
		return
	is_switching = true
	current_slot = new_slot

	# Smooth podium 180-degree rotation animation
	var target_rot_y = podium.rotation.y + PI
	var tween = create_tween().set_parallel(true)
	tween.tween_property(podium, "rotation:y", target_rot_y, 0.45).set_trans(Tween.TRANS_CUBIC).set_ease(Tween.EASE_OUT)
	tween.tween_property(camera, "fov", 58.0, 0.22).set_trans(Tween.TRANS_SINE)
	tween.chain().tween_property(camera, "fov", 62.0, 0.23).set_trans(Tween.TRANS_SINE)
	
	await tween.finished
	is_switching = false
	_update_slot_display(true)

func _update_slot_display(_animated: bool = true) -> void:
	slot_label.text = "BÜYÜCÜ SEÇİMİ — YUVA %d / 2" % [current_slot + 1]

	var has_character = current_slot < characters.size()
	var total_chars = characters.size()

	# Enforce max 2 characters per account (Section 3.2)
	if total_chars >= 2:
		new_char_btn.disabled = true
		new_char_btn.text = "Maksimum Karakter (2/2)"
	else:
		new_char_btn.disabled = false
		new_char_btn.text = "Yeni Büyücü Oluştur"

	if has_character:
		var c = characters[current_slot]
		var c_name: String = c.get("name", "Wizard")
		var c_house: String = c.get("house", "Gryffindor")
		var c_level: int = c.get("level", 1)
		var c_wand: int = c.get("wand_tier", 0)
		var c_galleons: int = c.get("galleons", 500)
		var c_hp: int = c.get("current_hp", 500)
		var c_max_hp: int = c.get("max_hp", 500)
		var c_mana: int = c.get("current_mana", 300)
		var c_max_mana: int = c.get("max_mana", 300)

		char_name_label.text = c_name
		char_house_label.text = "[ %s ]" % c_house
		if GameData.HOUSES.has(c_house):
			var house_data = GameData.HOUSES[c_house]
			char_house_label.modulate = house_data.primary_color
			_apply_rune_color(house_data.primary_color)
		
		char_stats_label.text = "Seviye: %d  |  Can: %d/%d  |  Mana: %d/%d" % [c_level, c_hp, c_max_hp, c_mana, c_max_mana]
		char_wand_label.text = "Asa: +%d Büyü Gücü" % c_wand
		char_galleons_label.text = "Servet: %d Galleon" % c_galleons
		char_location_label.text = "Konum: Hogwarts Avlusu"

		enter_world_btn.visible = true
		enter_world_btn.disabled = false
		enter_world_btn.text = "'%s' İLE DÜNYAYA GİR" % c_name
		UITheme.set_button_icon(enter_world_btn, "ui_portal", 20.0)

		_spawn_podium_character(c)
	else:
		char_name_label.text = "[ BOŞ YUVA ]"
		char_house_label.text = "Yeni bir büyücü oluşturun"
		char_house_label.modulate = Color(0.7, 0.7, 0.7)
		char_stats_label.text = "Seviye: —  |  HP: —  |  Mana: —"
		char_wand_label.text = "Asa: Yok"
		char_galleons_label.text = "Galleon: 0"
		char_location_label.text = "Konum: Henüz Başlanmadı"

		enter_world_btn.visible = false
		_clear_podium_character()
		_apply_rune_color(Color(0.4, 0.5, 0.7, 0.6))

func _spawn_podium_character(c_data: Dictionary) -> void:
	_clear_podium_character()

	var c_house: String = c_data.get("house", "Gryffindor")
	var primary := Color(0.6, 0.6, 0.6)
	if GameData.HOUSES.has(c_house):
		primary = GameData.HOUSES[c_house].primary_color

	# The same body and the same house tint the world uses, so the wizard on the
	# podium is the wizard the player is about to play.
	current_char_node = HeroAppearance.spawn(model_anchor, primary)
	if current_char_node == null:
		return
	current_anim_player = HeroAppearance.find_anim_player(current_char_node)
	# The podium wizard holds the same wand the world wizard does, built by the same
	# helper - so the grip, the tip and the refinement aura cannot drift apart from
	# the body the player is about to control. The wand's aura comes with it; the
	# old scene-level particle node sat at a fixed offset that was not the wand.
	HeroAppearance.show_equipped_wand(model_anchor,
		{"tier": int(c_data.get("wand_tier", 0))})

func _clear_podium_character() -> void:
	if is_instance_valid(current_char_node):
		current_char_node.queue_free()
		current_char_node = null
	current_anim_player = null

func _apply_rune_color(col: Color) -> void:
	if podium_light:
		podium_light.light_color = col
	if rune_ring and rune_ring.get_surface_override_material(0):
		var mat = rune_ring.get_surface_override_material(0)
		if mat is StandardMaterial3D:
			mat.albedo_color = col
			mat.emission = col

func _on_enter_world_pressed() -> void:
	if current_slot >= characters.size():
		return

	var c = characters[current_slot]
	var previous_text: String = enter_world_btn.text
	enter_world_btn.disabled = true
	enter_world_btn.text = "Dünya Yükleniyor..."

	# The world session is joined before a character exists (the menu does it),
	# so the choice made here is what binds it: the server proves the character
	# belongs to this session's account before it binds anything. A refusal
	# (another account's character) keeps the player here instead of dropping
	# them into a session that would never save.
	NetworkManager.select_character(c)
	var result: Dictionary = await NetworkManager.bind_selected_character()
	var retries := 0
	while not bool(result.get("ok", false)) and String(result.get("reason", "")) == "save_pending" and retries < 4:
		retries += 1
		slot_label.text = "Karakter kaydediliyor, lütfen bekleyin (%d/4)..." % retries
		await get_tree().create_timer(1.2).timeout
		result = await NetworkManager.bind_selected_character()

	if not bool(result.get("ok", false)):
		enter_world_btn.disabled = false
		enter_world_btn.text = previous_text
		slot_label.text = "Hata: %s" % _bind_reason_text(String(result.get("reason", "")))
		return
	get_tree().change_scene_to_file("res://scenes/world/game_world.tscn")

## A binding refusal must say what happened; these are the server's own reasons.
func _bind_reason_text(reason: String) -> String:
	match reason:
		"character_not_found":
			return "Bu karakter bulunamadı veya hesabınıza ait değil."
		"character_in_session":
			return "Bu karakter şu anda başka bir oturumda."
		"already_bound":
			return "Bu oturum zaten başka bir karaktere bağlı."
		"save_pending":
			return "Karakter önceki oturumdan kaydediliyor. Lütfen birkaç saniye sonra tekrar deneyin."
		"not_joined", "timeout", "no_character_selected":
			return "Dünya sunucusuna ulaşılamadı. Tekrar deneyin."
		_:
			return reason

func _on_character_select_result(success: bool, message: String, _char_data: Dictionary) -> void:
	enter_world_btn.disabled = false
	if not success:
		slot_label.text = "Hata: %s" % message
		return
	
	get_tree().change_scene_to_file("res://scenes/world/game_world.tscn")

func _on_new_char_pressed() -> void:
	if characters.size() >= 2:
		return
	create_modal.show()
	modal_status_label.text = ""
	new_name_input.grab_focus()

func _select_modal_house(h_name: String) -> void:
	selected_house = h_name
	if GameData.HOUSES.has(h_name):
		var data = GameData.HOUSES[h_name]
		modal_house_desc.text = "%s - \"%s\"\n%s" % [data.name, data.motto, data.trait]
		modal_house_desc.modulate = data.primary_color

	gryf_btn.flat = (h_name != "Gryffindor")
	slyth_btn.flat = (h_name != "Slytherin")
	raven_btn.flat = (h_name != "Ravenclaw")
	huff_btn.flat = (h_name != "Hufflepuff")

func _on_confirm_create_pressed() -> void:
	var c_name = new_name_input.text.strip_edges()
	if c_name.length() < 2:
		modal_status_label.text = "Karakter adı en az 2 harften oluşmalıdır!"
		return

	confirm_create_btn.disabled = true
	modal_status_label.text = "Büyücü oluşturuluyor..."

	if DatabaseManager.session_active:
		DatabaseManager.create_character(DatabaseManager.session_account_id, c_name, selected_house, func(res: Dictionary):
			confirm_create_btn.disabled = false
			if bool(res.get("success", false)):
				modal_status_label.text = "Karakter oluşturuldu!"
				var new_char = res.get("character", {})
				characters.append(new_char)
				current_slot = characters.size() - 1
				create_modal.hide()
				_update_slot_display(true)
			else:
				modal_status_label.text = "Hata: %s" % str(res.get("message", "Oluşturulamadı"))
		)
	else:
		# Offline create
		var new_char = {
			"id": characters.size() + 1,
			"name": c_name,
			"house": selected_house,
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
		DatabaseManager.save_offline_character(new_char)
		characters.append(new_char)
		confirm_create_btn.disabled = false
		create_modal.hide()
		current_slot = characters.size() - 1
		_update_slot_display(true)

func _on_character_create_result(success: bool, message: String, char_data: Dictionary) -> void:
	confirm_create_btn.disabled = false
	if success:
		characters.append(char_data)
		create_modal.hide()
		current_slot = characters.size() - 1
		_update_slot_display(true)
	else:
		modal_status_label.text = message

func _on_logout_pressed() -> void:
	NetworkManager.disconnect_game()
	get_tree().change_scene_to_file("res://scenes/main/main_menu.tscn")
