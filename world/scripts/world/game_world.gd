extends Node3D

## GameWorld - Hogwarts Valley MMO hub.
## Builds castle/village/forest/lake/pitch, NPCs, quests, overlay,
## leveled mob zones, monolith world bosses, and multiplayer replication.

@onready var players_container: Node3D = $Players
@onready var mobs_container: Node3D = $Mobs
@onready var monoliths_container: Node3D = $Monoliths
@onready var hud: Control = $CanvasLayer/HUD
@onready var inventory_ui: Control = $CanvasLayer/InventoryUI
@onready var ollivander_ui: Control = $CanvasLayer/OllivanderUI

const PLAYER_SCENE = preload("res://scenes/entities/player/player.tscn")
const MONOLITH_SCENE = preload("res://scenes/entities/monolith/dark_monolith.tscn")
const INFERI_SCENE = preload("res://scenes/entities/mobs/mob_inferi.tscn")
const ACROMANTULA_SCENE = preload("res://scenes/entities/mobs/mob_acromantula.tscn")
const SNATCHER_SCENE = preload("res://scenes/entities/mobs/mob_darksnatcher.tscn")
const OVERLAY_SCRIPT = preload("res://scripts/ui/mmorpg_overlay.gd")
const WorldBuilderScript = preload("res://scripts/world/world_builder.gd")
const NPCScript = preload("res://scripts/world/npc.gd")
const DummyScript = preload("res://scripts/world/training_dummy.gd")

var local_player: Node3D = null
var overlay: CanvasLayer = null
var _candle_t: float = 0.0

func _ready() -> void:
	var old_front := get_node_or_null("CastleFront")
	if old_front:
		old_front.queue_free()
	WorldBuilderScript.build(self)
	if not NetworkManager.is_dedicated_server:
		_spawn_local_player()
		_setup_overlay()
		_connect_ui_signals()
	else:
		print("[Dedicated Server] Headless world active (no local player/UI).")
		var cl = get_node_or_null("CanvasLayer")
		if cl:
			cl.queue_free()
	
	_setup_npcs()
	_setup_training_grounds()
	_setup_monoliths_and_mobs()

	NetworkManager.player_connected_signal.connect(_on_remote_player_connected)
	NetworkManager.player_disconnected_signal.connect(_on_remote_player_disconnected)
	NetworkManager.remote_spell_cast.connect(_on_remote_spell)

	for peer_id in NetworkManager.connected_players.keys():
		if peer_id != 1 and peer_id != multiplayer.get_unique_id():
			_spawn_remote_player(peer_id, NetworkManager.connected_players[peer_id])

func _process(delta: float) -> void:
	_candle_t += delta
	var candles := get_node_or_null("FloatingCandles")
	if candles:
		for c in candles.get_children():
			if c is MeshInstance3D and c.has_meta("base_y"):
				c.position.y = float(c.get_meta("base_y")) + sin(_candle_t * 1.5 + float(c.get_meta("phase"))) * 0.35
	_offline_save_timer -= delta
	if _offline_save_timer <= 0:
		_offline_save_timer = 15.0
		_save_offline_state()
	for candle in get_tree().get_nodes_in_group("floating_candles"):
		if candle.has_meta("base_y"):
			candle.position.y = float(candle.get_meta("base_y")) + sin(_candle_t * 1.2 + float(candle.get_meta("phase"))) * 0.15
	# Torch flicker + banner wave + lake shimmer (cheap life).
	for l in get_tree().get_nodes_in_group("torch_lights"):
		if l is OmniLight3D:
			(l as OmniLight3D).light_energy = 1.25 + sin(_candle_t * 9.0 + float((l as Node3D).get_index())) * 0.18
	for f in get_tree().get_nodes_in_group("torch_flames"):
		if f is MeshInstance3D:
			(f as MeshInstance3D).scale = Vector3.ONE * (1.0 + sin(_candle_t * 11.0) * 0.12)
	for b in get_tree().get_nodes_in_group("castle_banners"):
		if b is MeshInstance3D:
			(b as MeshInstance3D).rotation.y = sin(_candle_t * 1.6) * 0.12
	var lake := get_node_or_null("BlackLake")
	if lake:
		lake.position.y = sin(_candle_t * 0.8) * 0.05

var _offline_save_timer: float = 15.0

func _spawn_local_player() -> void:
	local_player = PLAYER_SCENE.instantiate()
	local_player.is_local_player = true
	local_player.player_name = NetworkManager.local_player_name
	local_player.house = NetworkManager.local_player_house
	players_container.add_child(local_player)
	
	if not NetworkManager.local_character_data.is_empty():
		var c: Dictionary = NetworkManager.local_character_data
		var px: float = float(c.get("pos_x", 0.0))
		var py: float = float(c.get("pos_y", 0.5))
		var pz: float = float(c.get("pos_z", 5.0))
		local_player.global_position = Vector3(px, py, pz)
		local_player.visuals.rotation.y = float(c.get("rot_y", PI))
		local_player.restore_character(c)
		print("[GameWorld] Restored character '%s' at %s, Level %d, Wand +%d, Galleons %d" % [
			local_player.player_name, local_player.global_position, local_player.level, local_player.wand_tier, local_player.galleons
		])
	else:
		local_player.global_position = Vector3(0, 0.5, 5.0)
		local_player.visuals.rotation.y = PI
	
	hud.bind_player(local_player)
	QuestManager.bind_player(local_player)
	_check_external_models()

func _notification(what: int) -> void:
	if what == NOTIFICATION_WM_CLOSE_REQUEST or what == NOTIFICATION_PREDELETE:
		_save_offline_state()

func _save_offline_state() -> void:
	if not is_instance_valid(local_player):
		return
	if NetworkManager.is_server and not NetworkManager.is_dedicated_server:
		var save_data := {
			"id": 1,
			"name": local_player.player_name,
			"house": local_player.house,
			"level": local_player.level,
			"exp": local_player.current_exp,
			"max_hp": local_player.max_hp,
			"current_hp": local_player.current_hp,
			"max_mana": local_player.max_mana,
			"current_mana": local_player.current_mana,
			"galleons": local_player.galleons,
			"wand_tier": local_player.wand_tier,
			"pos_x": local_player.global_position.x,
			"pos_y": local_player.global_position.y,
			"pos_z": local_player.global_position.z,
			"rot_y": local_player.visuals.rotation.y,
			"inventory": local_player.inventory,
			"quests": {}
		}
		DatabaseManager.save_offline_character(save_data)

func _setup_overlay() -> void:
	overlay = CanvasLayer.new()
	overlay.name = "MMOOverlay"
	overlay.set_script(OVERLAY_SCRIPT)
	add_child(overlay)
	overlay.attach(local_player)

func _connect_ui_signals() -> void:
	hud.inventory_button.pressed.connect(_toggle_inventory)
	hud.ollivander_button.pressed.connect(_toggle_ollivander)

func _unhandled_input(event: InputEvent) -> void:
	if not is_instance_valid(local_player):
		return
	var focus := get_viewport().gui_get_focus_owner()
	if focus is LineEdit or focus is TextEdit:
		return
	if event.is_action_pressed("toggle_inventory"):
		_toggle_inventory()
	elif event.is_action_pressed("toggle_ollivander"):
		_toggle_ollivander()
	elif event.is_action_pressed("toggle_chat"):
		hud.chat_input.grab_focus()
	elif event.is_action_pressed("interact"):
		var nearest: Node3D = null
		var distance := 4.0
		for npc in get_tree().get_nodes_in_group("npcs"):
			var candidate: float = npc.global_position.distance_to(local_player.global_position)
			if candidate < distance:
				distance = candidate
				nearest = npc
		if nearest and not local_player.is_dead:
			overlay.show_dialogue(nearest.npc_name, nearest.talk(local_player))
	elif event.is_action_pressed("ui_cancel"):
		inventory_ui.hide()
		ollivander_ui.hide()
		if overlay:
			overlay._dialog_panel.hide()

func _toggle_inventory() -> void:
	if inventory_ui.visible:
		inventory_ui.hide()
	else:
		inventory_ui.open_for_player(local_player)

func _toggle_ollivander() -> void:
	if ollivander_ui.visible:
		ollivander_ui.hide()
	else:
		ollivander_ui.open_for_player(local_player)

func _setup_npcs() -> void:
	var npcs := Node3D.new()
	npcs.name = "NPCs"
	add_child(npcs)
	_spawn_npc(npcs, "Professor Fig", Vector3(-6, 0, 8),
		["Ah, a new student! Hogwarts needs brave wizards.",
		"Acromantulas infest the west woods. Inferi haunt the forest edge.",
		"Break a Dark Monolith (follow the purple beams), refine your wand (O), then fly to the Quidditch Pitch (Shift to mount)."],
		Color(0.2, 0.25, 0.5))
	_spawn_npc(npcs, "Ollivander", Vector3(10.5, 0, 5),
		["Wands choose the wizard... but Galleons refine them!",
		"Press O anywhere to open my workshop. Bring Phoenix Ash, Heartstrings, Thestral Hair.",
		"+4 glows blue, +7 crackles gold, +9 burns with phoenix fire!"],
		Color(0.45, 0.3, 0.15))
	_spawn_npc(npcs, "Madam Rosmerta", Vector3(35, 0, 20),
		["Welcome to Hogsmeade, dearie! Rest here — low levels are safe near the village.",
		"Buy Wiggenweld before heading to the Forbidden Forest. Trust me."],
		Color(0.5, 0.15, 0.2))
	_spawn_npc(npcs, "Hagrid", Vector3(-48, 0, -18),
		["Yeh shouldn' be this deep in the forest... brave though!",
		"Inferi fear fire — hit 'em with Incendio (2). Stupefy (1) stuns 'em cold."],
		Color(0.25, 0.3, 0.15))
	_spawn_npc(npcs, "Madam Pince", Vector3(-31, 0.08, -82),
		["Welcome to the library. Keep the cross aisle clear, and mind the books.", "The Great Hall is through the eastern passage. Charms is across the hall."], Color(0.2, 0.15, 0.3))
	_spawn_npc(npcs, "Professor Flitwick", Vector3(26, 0.08, -84),
		["Welcome to Charms! Stupefy interrupts, Incendio burns, and Expelliarmus weakens attacks.", "Practice at the courtyard dummies, then pull a pack together. Watch the boss's warning circle."], Color(0.1, 0.24, 0.4))

func _spawn_npc(parent: Node3D, npc_name: String, pos: Vector3, dialogue: Array, robe: Color) -> void:
	var npc = NPCScript.new()
	npc.name = npc_name.replace(" ", "")
	parent.add_child(npc)
	npc.global_position = pos
	npc.setup(npc_name, dialogue, robe)

func _setup_training_grounds() -> void:
	# Safe courtyard dummies: practice rotations, they never fight back.
	var grounds := Node3D.new()
	grounds.name = "TrainingGrounds"
	add_child(grounds)
	for i in range(3):
		var d = DummyScript.new()
		d.name = "Dummy%d" % i
		grounds.add_child(d)
		d.global_position = Vector3(-14 + i * 3.0, 0, -2)
		d.setup()
	# Update Fig's hint to mention dummies
	NetworkManager.send_chat("[System] Training dummies placed in the courtyard — practice skills safely!")

func _check_external_models() -> void:
	# Drop-in CC0 model support: put .glb/.gltf in assets/models/ (see README).
	# We only announce here; WorldBuilder stays procedural so the game boots
	# with zero downloads. Future: auto-swap rigs when files appear.
	var dir := DirAccess.open("res://assets/models")
	if dir == null:
		return
	var found: Array = []
	dir.list_dir_begin()
	var f := dir.get_next()
	while f != "":
		if f.ends_with(".glb") or f.ends_with(".gltf"):
			found.append(f)
		f = dir.get_next()
	dir.list_dir_end()
	if found.size() > 0:
		NetworkManager.send_chat("[System] External models found: %s (procedural rigs kept for stability)" % ", ".join(found))

func _setup_monoliths_and_mobs() -> void:
	var monolith_locations = [
		Vector3(44, 0, -76.0),
		Vector3(45.0, 0, -25.0),
		Vector3(-45.0, 0, -28.0),
		Vector3(-58, 0, -50), # deep forest boss
	]
	for pos in monolith_locations:
		var monolith = MONOLITH_SCENE.instantiate()
		monoliths_container.add_child(monolith)
		monolith.global_position = pos

	var director := preload("res://scripts/world/encounter_director.gd").new()
	director.name = "EncounterDirector"
	add_child(director)
	director.start(mobs_container)

func _on_remote_player_connected(peer_id: int, info: Dictionary) -> void:
	_spawn_remote_player(peer_id, info)

func _spawn_remote_player(peer_id: int, info: Dictionary) -> void:
	var existing = players_container.get_node_or_null(str(peer_id))
	if existing:
		return
	var remote_p = PLAYER_SCENE.instantiate()
	remote_p.name = str(peer_id)
	remote_p.is_local_player = false
	remote_p.player_name = info.get("name", "Wizard")
	remote_p.house = info.get("house", "Gryffindor")
	players_container.add_child(remote_p)
	remote_p.global_position = Vector3(randf_range(-2, 2), 0.5, randf_range(3, 7))
	NetworkManager.send_chat("[Server] %s [%s] joined the realm!" % [remote_p.player_name, remote_p.house])

func _on_remote_player_disconnected(peer_id: int) -> void:
	var node = players_container.get_node_or_null(str(peer_id))
	if node:
		node.queue_free()

func _on_remote_spell(_peer_id: int, spell_id: String, from_pos: Vector3, dir: Vector3) -> void:
	# Show other players' spells as visual-only projectiles
	var proj_scene: PackedScene = load("res://scenes/spells/spell_projectile.tscn")
	var proj = proj_scene.instantiate()
	add_child(proj)
	proj.global_position = from_pos
	# find any caster (not critical for visuals)
	proj.visual_only = true
	proj.setup(players_container.get_node_or_null(str(_peer_id)), spell_id, dir, null, 1.0)
