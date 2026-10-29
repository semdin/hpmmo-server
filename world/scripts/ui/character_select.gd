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
## Appearance editing (LookEditor): -1 while a new wizard is being created,
## else the id of the wizard whose look is being changed; -2 when closed.
var _look_editor: LookEditor = null
var _look_char_id := -2
var _edit_look_btn: Button = null
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
	cancel_create_btn.pressed.connect(func():
		create_modal.hide()
		_close_look_editor()
		_update_slot_display(false))
	gryf_btn.pressed.connect(func(): _select_modal_house("Gryffindor"))
	slyth_btn.pressed.connect(func(): _select_modal_house("Slytherin"))
	raven_btn.pressed.connect(func(): _select_modal_house("Ravenclaw"))
	huff_btn.pressed.connect(func(): _select_modal_house("Hufflepuff"))

	# Connect NetworkManager signals
	NetworkManager.character_create_result.connect(_on_character_create_result)
	NetworkManager.character_select_result.connect(_on_character_select_result)
	NetworkManager.server_disconnected_signal.connect(_on_session_lost)

	_restyle()
	_build_look_editor()
	_select_modal_house("Gryffindor")
	create_modal.hide()
	create_modal.visibility_changed.connect(_layout)
	get_viewport().size_changed.connect(_layout)
	_layout()

	# Retrieve characters from NetworkManager cache
	_load_characters()

func _exit_tree() -> void:
	if NetworkManager.character_create_result.is_connected(_on_character_create_result):
		NetworkManager.character_create_result.disconnect(_on_character_create_result)
	if NetworkManager.character_select_result.is_connected(_on_character_select_result):
		NetworkManager.character_select_result.disconnect(_on_character_select_result)
	if NetworkManager.server_disconnected_signal.is_connected(_on_session_lost):
		NetworkManager.server_disconnected_signal.disconnect(_on_session_lost)

## The world session dropped while choosing (a newer login of this account, a
## server restart): this screen cannot bind anything any more, so go back to
## the login screen and say why.
func _on_session_lost() -> void:
	if not is_inside_tree():
		return
	var replaced := String(SimNet.get("session_end_reason")) == "replaced"
	get_tree().root.set_meta("hpmmo_login_notice", "replaced" if replaced else "disconnected")
	NetworkManager.disconnect_game()
	NetworkManager.forget_selected_character()
	get_tree().change_scene_to_file.call_deferred("res://scenes/main/main_menu.tscn")

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
	new_char_btn.text = tr("Create New Wizard")
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
	slot_label.text = tr("SLOT %d / 2") % [current_slot + 1]
	_refresh_roster()

	var has_character = current_slot < characters.size()
	var total_chars = characters.size()

	# Enforce max 2 characters per account (Section 3.2)
	if total_chars >= 2:
		new_char_btn.disabled = true
		new_char_btn.text = tr("Character Limit Reached (2/2)")
	else:
		new_char_btn.disabled = false
		new_char_btn.text = tr("Create New Wizard")

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
		char_house_label.text = c_house
		if GameData.HOUSES.has(c_house):
			var house_data = GameData.HOUSES[c_house]
			char_house_label.modulate = (house_data.primary_color as Color).lightened(0.3)
			_apply_rune_color(house_data.primary_color)
		if _crest != null:
			_crest.texture = UITheme.chrome("house_" + c_house.to_lower())
			_crest.visible = true

		char_stats_label.text = tr("Level %d\nHealth  %d / %d\nMana  %d / %d") % [c_level, c_hp, c_max_hp, c_mana, c_max_mana]
		char_wand_label.text = tr("Wand  +%d") % c_wand
		char_galleons_label.text = tr("Galleons  %d") % c_galleons
		char_location_label.text = tr("Hogwarts Valley")

		enter_world_btn.visible = true
		enter_world_btn.disabled = false
		enter_world_btn.text = tr("ENTER WORLD")
		enter_world_btn.icon = null

		_spawn_podium_character(c)
	else:
		char_name_label.text = tr("Empty Slot")
		char_house_label.text = tr("Create a new wizard")
		char_house_label.modulate = Color(0.7, 0.7, 0.7)
		if _crest != null:
			_crest.visible = false
		char_stats_label.text = "—"
		char_wand_label.text = ""
		char_galleons_label.text = ""
		char_location_label.text = ""

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
	HeroAppearance.apply_look(current_char_node, _look_of(c_data))
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
	var embers := get_node_or_null("Podium/EmbersParticles") as CPUParticles3D
	if embers != null:
		embers.color = col.lightened(0.35)
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
	_close_look_editor()
	# A look picked here travels with the join (game_world sends it).
	if HeroAppearance.has_pending_look(int(c.get("id", 0))):
		NetworkManager.pending_look = HeroAppearance.recall_look(int(c.get("id", 0)))
	var previous_text: String = enter_world_btn.text
	enter_world_btn.disabled = true
	enter_world_btn.text = tr("Loading World...")

	# The world session is joined before a character exists (the menu does it),
	# so the choice made here is what binds it: the server proves the character
	# belongs to this session's account before it binds anything. A refusal
	# (another account's character) keeps the player here instead of dropping
	# them into a session that would never save.
	NetworkManager.select_character(c)
	var result: Dictionary = await NetworkManager.bind_selected_character()
	var retries := 0
	while not bool(result.get("ok", false)) and String(result.get("reason", "")) == "save_pending" and retries < 8:
		retries += 1
		slot_label.text = tr("Saving character, please wait…")
		await get_tree().create_timer(0.75).timeout
		if not is_inside_tree():
			return
		result = await NetworkManager.bind_selected_character()

	if not bool(result.get("ok", false)):
		enter_world_btn.disabled = false
		enter_world_btn.text = previous_text
		slot_label.text = tr("Error: %s") % _bind_reason_text(String(result.get("reason", "")))
		return
	WorldLoader.enter_world(get_tree())

## A binding refusal must say what happened; these are the server's own reasons.
func _bind_reason_text(reason: String) -> String:
	match reason:
		"character_not_found":
			return tr("This character was not found or does not belong to your account.")
		"character_in_session":
			return tr("This character is in another session right now.")
		"already_bound":
			return tr("This session is already bound to another character.")
		"save_pending":
			return tr("The character is still being saved from the previous session. Please try again in a few seconds.")
		"not_joined", "timeout", "no_character_selected":
			return tr("Could not reach the world server. Try again.")
		_:
			return reason

func _on_character_select_result(success: bool, message: String, _char_data: Dictionary) -> void:
	enter_world_btn.disabled = false
	if not success:
		slot_label.text = tr("Error: %s") % message
		return
	
	WorldLoader.enter_world(get_tree())

func _on_new_char_pressed() -> void:
	if characters.size() >= 2:
		return
	create_modal.show()
	modal_status_label.text = ""
	new_name_input.grab_focus()
	_open_look_editor(-1, HPRules.default_look())

func _select_modal_house(h_name: String) -> void:
	selected_house = h_name
	if GameData.HOUSES.has(h_name):
		var data = GameData.HOUSES[h_name]
		modal_house_desc.text = "%s - \"%s\"\n%s" % [data.name, data.motto, tr(String(data.trait))]
		modal_house_desc.modulate = (data.primary_color as Color).lightened(0.45)

	# the outfit's main cloth wears the house colour
	if is_instance_valid(current_char_node) and GameData.HOUSES.has(h_name):
		HeroAppearance.apply_house_tint(current_char_node, GameData.HOUSES[h_name].primary_color)
	gryf_btn.flat = (h_name != "Gryffindor")
	slyth_btn.flat = (h_name != "Slytherin")
	raven_btn.flat = (h_name != "Ravenclaw")
	huff_btn.flat = (h_name != "Hufflepuff")

func _on_confirm_create_pressed() -> void:
	var c_name = new_name_input.text.strip_edges()
	if c_name.length() < 2:
		modal_status_label.text = tr("A character name needs at least 2 letters!")
		return

	confirm_create_btn.disabled = true
	modal_status_label.text = tr("Creating wizard...")

	if DatabaseManager.session_active:
		DatabaseManager.create_character(DatabaseManager.session_account_id, c_name, selected_house, func(res: Dictionary):
			confirm_create_btn.disabled = false
			if bool(res.get("success", false)):
				modal_status_label.text = tr("Character created!")
				var new_char = res.get("character", {})
				HeroAppearance.remember_look(int(new_char.get("id", 0)), _look_editor.look, true)
				characters.append(new_char)
				current_slot = characters.size() - 1
				create_modal.hide()
				_close_look_editor()
				_update_slot_display(true)
			else:
				modal_status_label.text = tr("Error: %s") % str(res.get("message", tr("Could not be created")))
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
			# No position: a new wizard starts at the grounds spawn.
			"rot_y": PI,
			"inventory": [
				{"id": "wand_ashwood", "amount": 1, "tier": 0},
				{"id": "potion_health", "amount": 5, "tier": 0},
				{"id": "potion_mana", "amount": 5, "tier": 0}
			],
			"quests": {"look": _look_editor.look.duplicate()}
		}
		DatabaseManager.save_offline_character(new_char)
		characters.append(new_char)
		confirm_create_btn.disabled = false
		create_modal.hide()
		_close_look_editor()
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
	NetworkManager.forget_selected_character()
	get_tree().change_scene_to_file("res://scenes/main/main_menu.tscn")


## ===================================================================== look
## The character screen in the HUD's frame language: the key art behind a dark
## stone dais lit in the house colour, the roster of your wizards on the left,
## the chosen wizard's sheet on the right and one clear "Enter world" button.
## The scene's nodes (and their paths) stay; this restyles and arranges them.

var _crest: TextureRect = null
var _roster: VBoxContainer = null
var _roster_title: Label = null
var _drag_turn := false

func _restyle() -> void:
	var canvas: CanvasLayer = $CanvasLayer
	# --- backdrop: key art behind the 3D stage
	var env_node := get_node_or_null("WorldEnvironment") as WorldEnvironment
	if env_node != null and env_node.environment != null:
		var env := env_node.environment.duplicate() as Environment
		env.background_mode = Environment.BG_CANVAS
		env.glow_enabled = true
		env.glow_intensity = 0.6
		env_node.environment = env
	var back := CanvasLayer.new()
	back.layer = -1
	add_child(back)
	var art_path := "res://assets/branding/hpmmo_banner.jpg"
	if ResourceLoader.exists(art_path):
		var art := TextureRect.new()
		art.texture = load(art_path)
		art.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
		art.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_COVERED
		art.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
		art.modulate = Color(0.42, 0.42, 0.5)
		back.add_child(art)
	var vignette := ColorRect.new()
	vignette.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	vignette.color = Color(0.0, 0.0, 0.02, 0.35)
	back.add_child(vignette)
	# --- the dais: dressed stone, a slim glowing rune ring
	var dais := get_node_or_null("Podium/PodiumMesh") as MeshInstance3D
	if dais != null:
		var cyl := CylinderMesh.new()
		cyl.top_radius = 1.35
		cyl.bottom_radius = 1.48
		cyl.height = 0.5
		cyl.radial_segments = 64
		dais.mesh = cyl
		var stone := StandardMaterial3D.new()
		var base := "res://assets/textures/pbr/floor_flagstone_01/floor_flagstone_01_"
		if ResourceLoader.exists(base + "albedo_2k.png"):
			stone.albedo_texture = load(base + "albedo_2k.png")
			stone.normal_enabled = true
			stone.normal_texture = load(base + "normal_2k.png")
			stone.uv1_triplanar = true
			stone.uv1_scale = Vector3(0.9, 0.9, 0.9)
		stone.albedo_color = Color(0.3, 0.29, 0.32)
		stone.roughness = 0.85
		dais.material_override = stone
	if rune_ring != null:
		var torus := TorusMesh.new()
		torus.inner_radius = 1.22
		torus.outer_radius = 1.27
		torus.rings = 96
		rune_ring.mesh = torus
		var glow := StandardMaterial3D.new()
		glow.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
		glow.emission_enabled = true
		glow.emission_energy_multiplier = 1.4
		rune_ring.set_surface_override_material(0, glow)
	if podium_light != null:
		podium_light.light_energy = 1.4
	# --- top: title and logout
	var top := $CanvasLayer/TopBar as Control
	var title := $CanvasLayer/TopBar/TitleLabel as Label
	title.text = "HOGWARTS"
	HudKit.style_label(title, 38, HudKit.GOLD_HI, HudKit.deco(), 8)
	title.add_theme_color_override("font_outline_color", Color(0.1, 0.06, 0.02, 0.9))
	HudKit.style_label(slot_label, 16, HudKit.PARCHMENT, HudKit.title(), 4)
	HudKit.style_button(logout_btn, 15)
	logout_btn.text = tr("Log Out")
	logout_btn.custom_minimum_size = Vector2(130, 40)
	top.offset_top = 22
	# --- roster on the left
	var roster_panel := PanelContainer.new()
	roster_panel.name = "Roster"
	roster_panel.add_theme_stylebox_override("panel", HudKit.panel(0.82, 8))
	roster_panel.set_anchors_preset(Control.PRESET_CENTER_LEFT)
	UILayout.place(roster_panel, Vector2(36, -170), Vector2(320, 0))
	canvas.add_child(roster_panel)
	_roster_panel = roster_panel
	_roster = VBoxContainer.new()
	_roster.add_theme_constant_override("separation", 10)
	roster_panel.add_child(_roster)
	_roster_title = HudKit.label(tr("YOUR WIZARDS"), 15, HudKit.GOLD, HudKit.title(), 3)
	_roster.add_child(_roster_title)
	# --- character sheet on the right
	var info := $CanvasLayer/InfoCard as PanelContainer
	info.add_theme_stylebox_override("panel", HudKit.panel(0.82, 8))
	info.set_anchors_preset(Control.PRESET_CENTER_RIGHT)
	UILayout.place(info, Vector2(-356, -170), Vector2(320, 300))
	HudKit.style_label(char_name_label, 30, HudKit.GOLD_HI, HudKit.deco(), 6)
	HudKit.style_label(char_house_label, 16, HudKit.PARCHMENT, HudKit.title(), 3)
	for l in [char_stats_label, char_wand_label, char_location_label]:
		HudKit.style_label(l, 16, HudKit.TEXT, HudKit.body(), 2)
	HudKit.style_label(char_galleons_label, 16, HudKit.GOLD_LT, HudKit.bold(), 2)
	char_stats_label.add_theme_constant_override("line_spacing", 4)
	var vbox := char_name_label.get_parent() as VBoxContainer
	var head := HBoxContainer.new()
	head.add_theme_constant_override("separation", 12)
	vbox.add_child(head)
	vbox.move_child(head, 0)
	_crest = TextureRect.new()
	_crest.custom_minimum_size = Vector2(56, 56)
	_crest.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	_crest.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
	head.add_child(_crest)
	var names := VBoxContainer.new()
	names.add_theme_constant_override("separation", 0)
	head.add_child(names)
	char_name_label.reparent(names)
	char_house_label.reparent(names)
	# --- enter world: one big gold button, bottom centre
	var bottom := $CanvasLayer/BottomBar as BoxContainer
	bottom.alignment = BoxContainer.ALIGNMENT_CENTER
	bottom.offset_top = -104
	bottom.offset_bottom = -40
	HudKit.style_button(enter_world_btn, 22)
	for state in ["normal", "hover", "pressed"]:
		var sb := HudKit.button_box(state).duplicate() as StyleBoxFlat
		sb.bg_color = Color(0.36, 0.25, 0.08) if state == "normal" else (Color(0.48, 0.34, 0.1) if state == "hover" else Color(0.26, 0.18, 0.06))
		sb.border_color = HudKit.GOLD_HI if state == "hover" else HudKit.GOLD_LT
		sb.set_border_width_all(2)
		sb.set_corner_radius_all(6)
		sb.shadow_color = Color(0, 0, 0, 0.5)
		sb.shadow_size = 8
		enter_world_btn.add_theme_stylebox_override(state, sb)
	enter_world_btn.add_theme_font_override("font", HudKit.title())
	enter_world_btn.add_theme_color_override("font_color", HudKit.GOLD_HI)
	enter_world_btn.custom_minimum_size = Vector2(380, 60)
	# Creating a wizard lives in the roster now.
	new_char_btn.visible = false
	# --- slot arrows: small round buttons beside the dais
	for b in [prev_slot_btn, next_slot_btn]:
		HudKit.style_button(b, 20)
		b.custom_minimum_size = Vector2(52, 52)
	# --- create modal
	create_modal.add_theme_stylebox_override("panel", HudKit.window())
	var modal_title := create_modal.get_node_or_null("Margin/VBox/ModalTitle") as Label
	if modal_title != null:
		modal_title.text = tr("New Wizard")
		HudKit.style_label(modal_title, 26, HudKit.GOLD_HI, HudKit.deco(), 5)
		modal_title.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	var name_lbl := create_modal.get_node_or_null("Margin/VBox/NameRow/NameLbl") as Label
	if name_lbl != null:
		HudKit.style_label(name_lbl, 16, HudKit.PARCHMENT, HudKit.body(), 2)
	var field := StyleBoxFlat.new()
	field.bg_color = Color(0.02, 0.027, 0.043, 0.9)
	field.border_color = HudKit.GOLD.darkened(0.2)
	field.set_border_width_all(1)
	field.set_corner_radius_all(4)
	field.content_margin_left = 10
	field.content_margin_top = 6
	field.content_margin_bottom = 6
	for state in ["normal", "focus"]:
		new_name_input.add_theme_stylebox_override(state, field)
	new_name_input.add_theme_font_override("font", HudKit.body())
	new_name_input.add_theme_font_size_override("font_size", 17)
	for b in [gryf_btn, slyth_btn, raven_btn, huff_btn]:
		HudKit.style_button(b, 14)
		b.custom_minimum_size = Vector2(110, 84)
		b.icon_alignment = HORIZONTAL_ALIGNMENT_CENTER
		b.vertical_icon_alignment = VERTICAL_ALIGNMENT_TOP
		b.expand_icon = false
	gryf_btn.icon = UITheme.chrome_at("house_gryffindor", 44.0)
	slyth_btn.icon = UITheme.chrome_at("house_slytherin", 44.0)
	raven_btn.icon = UITheme.chrome_at("house_ravenclaw", 44.0)
	huff_btn.icon = UITheme.chrome_at("house_hufflepuff", 44.0)
	HudKit.style_label(modal_house_desc, 15, HudKit.TEXT, HudKit.body(), 2)
	HudKit.style_button(confirm_create_btn, 16)
	HudKit.style_button(cancel_create_btn, 16)
	# The create card is the only thing on screen while it is open: a dim
	# backdrop behind it, roster and sheet hidden (on a 13-14" laptop the
	# three side by side overlapped).
	_modal_shade = ColorRect.new()
	_modal_shade.name = "ModalShade"
	_modal_shade.color = Color(0, 0, 0, 0.55)
	_modal_shade.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	_modal_shade.mouse_filter = Control.MOUSE_FILTER_STOP
	_modal_shade.hide()
	canvas.add_child(_modal_shade)
	canvas.move_child(_modal_shade, create_modal.get_index())
	var house_row := gryf_btn.get_parent() as HBoxContainer
	house_row.alignment = BoxContainer.ALIGNMENT_CENTER
	modal_house_desc.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	modal_house_desc.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	modal_status_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART

var _roster_panel: PanelContainer = null
var _modal_shade: ColorRect = null
## Side column width, from the canvas (canvas_items stretch keeps the height
## at 720, so a 16:10 or narrow window has less width to share).
var _side_w := 320.0

## Responsive layout: side columns shrink with the canvas, the create card is
## centred, clamped to the screen and shown alone over a dim backdrop.
func _layout() -> void:
	if _roster_panel == null:
		return
	var canvas := get_viewport().get_visible_rect().size
	_side_w = clampf(canvas.x * 0.24, 250.0, 320.0)
	var top := -minf(170.0, canvas.y * 0.5 - 90.0)
	UILayout.place(_roster_panel, Vector2(24.0 if canvas.x < 1200 else 36.0, top), Vector2(_side_w, 0))
	var info := $CanvasLayer/InfoCard as PanelContainer
	UILayout.place(info, Vector2(-_side_w - (24.0 if canvas.x < 1200 else 36.0), top), Vector2(_side_w, 300))
	for card in _roster.get_children():
		if card is Button: (card as Button).custom_minimum_size.x = _side_w - 30.0
	# The slot arrows sit beside the dais, inside the side columns.
	var nav := $CanvasLayer/NavButtons as Control
	var half := clampf(canvas.x * 0.5 - _side_w - 70.0, 170.0, 340.0)
	nav.offset_left = -half
	nav.offset_right = half
	var creating := create_modal.visible
	var editing := _look_editor != null and _look_editor.visible
	nav.visible = not creating and not editing
	# the podium stays lit: the look being picked is drawn on it
	_modal_shade.visible = false
	_roster_panel.visible = not creating and not editing
	info.visible = not creating
	if _edit_look_btn != null:
		_edit_look_btn.visible = not creating and not editing and current_slot < characters.size()
	if editing:
		var ew := clampf(canvas.x * 0.26, 280.0, 340.0)
		_look_editor.set_anchors_preset(Control.PRESET_TOP_LEFT)
		UILayout.place(_look_editor, Vector2(24.0, maxf(16.0, canvas.y * 0.5 - 330.0)), Vector2(ew, 0))
	if creating:
		var w := minf(560.0, canvas.x * 0.5 - 60.0)
		var house_w := clampf((w - 80.0) / 4.0, 84.0, 110.0)
		for b in [gryf_btn, slyth_btn, raven_btn, huff_btn]:
			b.custom_minimum_size = Vector2(house_w, 84)
		modal_house_desc.custom_minimum_size.x = w - 60.0
		var h := minf(400.0, canvas.y - 32.0)
		create_modal.set_anchors_preset(Control.PRESET_TOP_LEFT)
		var at := Vector2(canvas.x - w - 24.0, floorf((canvas.y - h) * 0.5))
		UILayout.place(create_modal, at, Vector2(w, h))

## One card per slot: crest, name, level and house; the empty slot creates.
func _refresh_roster() -> void:
	if _roster == null:
		return
	for child in _roster.get_children():
		if child != _roster_title:
			child.queue_free()
	_roster_title.text = tr("YOUR WIZARDS  (%d / 2)") % characters.size()
	for i in range(2):
		var card := Button.new()
		card.focus_mode = Control.FOCUS_NONE
		card.custom_minimum_size = Vector2(_side_w - 30.0, 70)
		card.alignment = HORIZONTAL_ALIGNMENT_LEFT
		card.add_theme_constant_override("h_separation", 12)
		var selected := i == current_slot
		var normal := StyleBoxFlat.new()
		normal.bg_color = Color(0.09, 0.11, 0.17, 0.9) if selected else Color(0.05, 0.06, 0.09, 0.7)
		normal.border_color = HudKit.GOLD_LT if selected else Color(HudKit.GOLD.r, HudKit.GOLD.g, HudKit.GOLD.b, 0.35)
		normal.set_border_width_all(2 if selected else 1)
		normal.set_corner_radius_all(6)
		normal.content_margin_left = 12
		normal.content_margin_right = 10
		var hover := normal.duplicate() as StyleBoxFlat
		hover.border_color = HudKit.GOLD_HI
		card.add_theme_stylebox_override("normal", normal)
		card.add_theme_stylebox_override("hover", hover)
		card.add_theme_stylebox_override("pressed", hover)
		card.add_theme_stylebox_override("focus", HudKit.empty())
		card.add_theme_font_override("font", HudKit.bold())
		card.add_theme_font_size_override("font_size", 16)
		card.add_theme_color_override("font_color", HudKit.PARCHMENT)
		card.add_theme_color_override("font_hover_color", HudKit.GOLD_HI)
		if i < characters.size():
			var c: Dictionary = characters[i]
			var house := String(c.get("house", "Gryffindor"))
			card.icon = UITheme.chrome_at("house_" + house.to_lower(), 46.0)
			card.text = tr("%s\nLevel %d  ·  %s") % [String(c.get("name", "Wizard")), int(c.get("level", 1)), house]
			var index := i
			card.pressed.connect(func(): _switch_slot(index))
		else:
			card.icon = UITheme.chrome_at("minimap_zoom_in", 30.0)
			card.text = tr("Create New Wizard")
			card.add_theme_color_override("font_color", HudKit.GOLD_LT)
			card.pressed.connect(func():
				if current_slot != i and i < 2:
					current_slot = i
					_update_slot_display(false)
				_on_new_char_pressed())
		_roster.add_child(card)

## Drag on the stage to turn the wizard on the dais; the wheel there moves the
## camera in to the face and back out.
func _input(event: InputEvent) -> void:
	if create_modal.visible and not (_look_editor != null and _look_editor.visible):
		return
	var vp := get_viewport().get_visible_rect().size
	if event is InputEventMouseButton and event.button_index == MOUSE_BUTTON_LEFT:
		var x: float = event.position.x
		_drag_turn = event.pressed and x > vp.x * 0.3 and x < vp.x * 0.7 and event.position.y < vp.y - 120
	elif event is InputEventMouseButton and event.pressed and _on_stage(event.position, vp) 			and event.button_index in [MOUSE_BUTTON_WHEEL_UP, MOUSE_BUTTON_WHEEL_DOWN]:
		var step := 0.12 if event.button_index == MOUSE_BUTTON_WHEEL_UP else -0.12
		_zoom_target = clampf(_zoom_target + step, 0.0, 1.0)
	elif event is InputEventMouseMotion and _drag_turn and is_instance_valid(model_anchor):
		model_anchor.rotation.y += event.relative.x * 0.01


func _on_stage(at: Vector2, vp: Vector2) -> bool:
	return at.x > vp.x * 0.3 and at.x < vp.x * 0.7 and at.y < vp.y - 120


## 0 = the whole wizard on the dais (the scene's camera), 1 = the face close up.
var _zoom := 0.0
var _zoom_target := 0.0
var _camera_far := Transform3D()

func _process(delta: float) -> void:
	if not is_instance_valid(camera) or not is_instance_valid(model_anchor):
		return
	if _camera_far == Transform3D():
		_camera_far = camera.transform
	_zoom = lerpf(_zoom, _zoom_target, 1.0 - exp(-10.0 * delta))
	if absf(_zoom - _zoom_target) < 0.001 and _zoom_target == 0.0 and _zoom < 0.001:
		camera.transform = _camera_far
		return
	var face := camera.get_parent_node_3d().to_local(model_anchor.global_position + Vector3(0, 1.6, 0))
	var far_look := _camera_far.origin - _camera_far.basis.z * 3.0
	var t := smoothstep(0.0, 1.0, _zoom)
	var look := far_look.lerp(face, t)
	var near_origin := face + (_camera_far.origin - face).normalized() * 0.85
	var origin := _camera_far.origin.lerp(near_origin, t)
	camera.transform = Transform3D(Basis.looking_at(look - origin, Vector3.UP), origin)


## ---------------------------------------------------------------- appearance

## The look a wizard is drawn with here: an offline sheet carries it in its
## quests; an online one comes from this machine's look cache (the account
## list has no quests), default until first played.
func _look_of(c: Dictionary) -> Dictionary:
	var quests = c.get("quests", {})
	if quests is Dictionary and (quests as Dictionary).has("look"):
		return HPRules.clean_look(quests["look"])
	return HeroAppearance.recall_look(int(c.get("id", 0)))


func _build_look_editor() -> void:
	_look_editor = LookEditor.new()
	_look_editor.name = "LookEditor"
	_look_editor.hide()
	$CanvasLayer.add_child(_look_editor)
	_look_editor.look_changed.connect(_preview_look)
	_look_editor.confirmed.connect(_save_look)
	_look_editor.cancelled.connect(func():
		_close_look_editor()
		_update_slot_display(false))
	_look_editor.visibility_changed.connect(_layout)
	_edit_look_btn = Button.new()
	_edit_look_btn.text = tr("Edit Appearance")
	_edit_look_btn.focus_mode = Control.FOCUS_NONE
	HudKit.style_button(_edit_look_btn, 15)
	_edit_look_btn.pressed.connect(func():
		if current_slot < characters.size():
			_open_look_editor(int(characters[current_slot].get("id", 0)), _look_of(characters[current_slot])))
	enter_world_btn.get_parent().add_child(_edit_look_btn)
	enter_world_btn.get_parent().move_child(_edit_look_btn, enter_world_btn.get_index())


## `char_id` -1: the wizard being created (a fresh body on the dais).
func _open_look_editor(char_id: int, look: Dictionary) -> void:
	_look_char_id = char_id
	_look_editor.set_edit_buttons(char_id != -1)
	_look_editor.set_look(look)
	_look_editor.show()
	if char_id == -1:
		_spawn_podium_character({"house": selected_house, "quests": {"look": look}})
	_preview_look(look)
	_layout()


func _close_look_editor() -> void:
	_look_char_id = -2
	if _look_editor != null:
		_look_editor.hide()
	_layout()


func _preview_look(look: Dictionary) -> void:
	if is_instance_valid(current_char_node):
		HeroAppearance.apply_look(current_char_node, look)


## Save an existing wizard's new look: offline sheets keep it in their quests;
## online it waits in the look cache and goes with the next world join.
func _save_look(look: Dictionary) -> void:
	if current_slot < characters.size():
		var c: Dictionary = characters[current_slot]
		if not DatabaseManager.session_active:
			var quests = c.get("quests", {})
			if not (quests is Dictionary):
				quests = {}
			quests["look"] = HPRules.clean_look(look)
			c["quests"] = quests
			DatabaseManager.save_offline_character(c)
		else:
			HeroAppearance.remember_look(int(c.get("id", 0)), look, true)
	_close_look_editor()
	_update_slot_display(false)
