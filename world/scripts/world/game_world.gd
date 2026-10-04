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
const MapControllerScript = preload("res://scripts/world/map_controller.gd")
const QualityPresetScript = preload("res://scripts/world/quality_preset.gd")
const NPCScript = preload("res://scripts/world/npc.gd")
const DummyScript = preload("res://scripts/world/training_dummy.gd")

var local_player: Node3D = null
var overlay: CanvasLayer = null
## Client half of map transfer (plan.md Phase 8): portal interaction, fade and
## loading UI, loading the castle interior and unloading the outdoor world.
var map_controller: Node = null
var _candle_t: float = 0.0
var _particle_sweep: float = 1.0
var _views: Dictionary = {}          # sim uid -> view node (client role)
var _view_scenes: Dictionary = {}

const LOOT_SCENE = preload("res://scenes/entities/loot/loot_drop.tscn")

func _ready() -> void:
	var old_front := get_node_or_null("CastleFront")
	if old_front:
		old_front.queue_free()
	WorldBuilderScript.build(self)
	SimAuthority.attach_world(self)
	var authority := SimAuthority.is_authority()
	if not NetworkManager.is_dedicated_server:
		_spawn_local_player()
		_setup_overlay()
		_connect_ui_signals()
		_setup_map_controller()
	else:
		print("[Dedicated Server] Headless world active (no local player/UI).")
		var cl = get_node_or_null("CanvasLayer")
		if cl:
			cl.queue_free()

	_setup_npcs()
	# Training dummies are static authored scenery at fixed spots: every process
	# builds the same ones, and only the authority registers them as entities.
	_setup_training_grounds()
	if authority:
		# The authority decides what exists: packs and monoliths are its spawn
		# decisions, sampled once and replicated. A client never rolls its own
		# encounter.
		_setup_monoliths_and_mobs()
	# Presentation listens to the same signals in every role; in authority roles
	# the entities already have nodes, so only the effect hooks fire.
	_setup_replication()

func _exit_tree() -> void:
	# Views belong to the world that made them.
	_views.clear()

func _process(delta: float) -> void:
	_candle_t += delta
	# Reduced-quality particle budget: effects spawn during play, so the preset
	# is re-applied on a slow sweep rather than once at build time.
	_particle_sweep -= delta
	if _particle_sweep <= 0.0:
		_particle_sweep = 1.0
		if QualityPresetScript.particle_scale() != 1.0:
			QualityPresetScript.tune_particles(self)
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
	
	# The authority owns this body from here on: register it before anything can
	# act on it (casts, damage, snapshots all resolve through the registry).
	if SimAuthority.is_authority():
		SimAuthority.register_player(local_player, int(NetworkManager.local_character_data.get("id", 0)),
			SimNet.local_peer_id)
	elif SimNet.joined_world:
		# The server answered the join before the world scene existed (menus load
		# this scene afterwards), so bind the uid it assigned now.
		SimAuthority.register_local_player(SimNet.local_uid, SimNet.pending_character)

	hud.bind_player(local_player)
	QuestManager.bind_player(local_player)
	_check_external_models()

func _notification(what: int) -> void:
	if what == NOTIFICATION_WM_CLOSE_REQUEST or what == NOTIFICATION_PREDELETE:
		_save_offline_state()

func _save_offline_state() -> void:
	if not is_instance_valid(local_player) or not local_player.is_inside_tree():
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

func _setup_map_controller() -> void:
	# One controller per world: it owns the portal trigger volumes, the transfer
	# fade/loading UI, the floor label, and the load/unload of a second map.
	map_controller = MapControllerScript.new()
	map_controller.name = "MapController"
	add_child(map_controller)

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
	var index := 0
	for entry in HPRules.spawn_tables().get("dummies", []):
		var d = DummyScript.new()
		d.name = "Dummy%d" % index
		index += 1
		grounds.add_child(d)
		var pos: Array = entry.get("pos", [-14.0, 0.0, -2.0])
		d.global_position = Vector3(float(pos[0]), float(pos[1]), float(pos[2]))
		d.setup()
		if SimAuthority.is_authority():
			SimAuthority.register(HPProtocol.Kind.DUMMY, d, {
				"hp": d.current_hp, "max_hp": d.max_hp, "dummy_id": int(entry.get("id", index)),
			})
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

## ------------------------------------------------------------------
## Replication. In a client-only process the world contains no gameplay
## entities of its own: views are created for entities the server announces and
## removed when it stops announcing them. In authority roles the same signals
## drive presentation for the entities the engine already simulated.
## ------------------------------------------------------------------

func _setup_replication() -> void:
	SimAuthority.entity_replicating.connect(_on_entity_replicating)
	SimAuthority.entity_despawned.connect(_on_entity_despawned)
	SimAuthority.entity_moved.connect(_on_entity_moved)
	SimAuthority.entity_health.connect(_on_entity_health)
	SimAuthority.cast_released.connect(_on_cast_released)
	SimAuthority.cast_landed.connect(_on_cast_landed)
	SimAuthority.loot_spawned.connect(_on_loot_spawned)
	SimAuthority.chat.connect(_on_chat)
	if is_instance_valid(local_player):
		SimAuthority.cast_ack.connect(local_player.on_cast_answer)

func _on_entity_replicating(record: Dictionary) -> void:
	var uid := int(record["uid"])
	if _views.has(uid) or record.get("node") != null:
		return   # already on screen (authority roles own their nodes)
	var kind := int(record.get("kind", 0))
	var scene: PackedScene = null
	match kind:
		HPProtocol.Kind.PLAYER:
			scene = PLAYER_SCENE
		HPProtocol.Kind.MOB:
			scene = load(HPProtocol.mob_scene(int(record.get("variant", HPProtocol.MOB_VARIANT_INFERI))))
		HPProtocol.Kind.MONOLITH:
			scene = MONOLITH_SCENE
		_:
			return   # dummies are authored scenery in every process
	if scene == null:
		return
	var view: Node3D = scene.instantiate()
	view.name = "View%d" % uid
	if kind == HPProtocol.Kind.MOB:
		# A replicated mob is a puppet: no AI, no damage, follows the snapshots.
		view.sim_puppet = true
		if (int(record.get("flags", 0)) & HPProtocol.FLAG_BOSS) != 0:
			var is_commander := int(record.get("variant", 0)) == HPProtocol.MOB_VARIANT_DARKSATCHER
			var visuals := view.get_node_or_null("Visuals")
			if visuals:
				visuals.scale = Vector3.ONE * (1.65 if is_commander else 2.0)
			var label := view.get_node_or_null("Label3D")
			if label:
				label.position.y = 4.2
	elif kind == HPProtocol.Kind.PLAYER:
		view.is_local_player = false
		# Another player's body is a VIEW here: it follows the replicated state
		# and never reads this client's keyboard.
		view.sim_puppet = true
		players_container.add_child(view)
	_views[uid] = view
	if kind != HPProtocol.Kind.PLAYER:
		add_child(view)
	SimAuthority.attach_view_node(uid, view)
	view.global_position = record.get("pos", view.global_position)

func _on_entity_despawned(uid: int) -> void:
	SimAuthority.drop_replica(uid)
	if not _views.has(uid):
		return
	var view = _views[uid]
	_views.erase(uid)
	if is_instance_valid(view):
		view.queue_free()

func _on_entity_moved(uid: int, pos: Vector3, rot_y: float, flags: int) -> void:
	if uid == SimAuthority.local_uid and is_instance_valid(local_player):
		# The local body is predicted, not puppeted: it reconciles instead.
		local_player.apply_authoritative_position(pos, rot_y)
		return
	if not _views.has(uid):
		return
	var view = _views[uid]
	if not is_instance_valid(view):
		return
	if "sim_target_pos" in view:
		view.sim_target_pos = pos
		view.sim_target_rot = rot_y
		# Phase 9: the replicated flight phase rides in the record's `state` byte,
		# so a remote rider animates the phase the authority chose, not a guess.
		if "sim_mount_phase" in view:
			view.sim_mount_phase = int(SimAuthority.entities.get(uid, {}).get("state", 0))
		if "is_mounted" in view:
			var replicated_mount := (flags & HPProtocol.FLAG_MOUNTED) != 0
			if replicated_mount != bool(view.is_mounted):
				view.is_mounted = replicated_mount
				if view.has_method("_apply_mount_state"):
					view._apply_mount_state(replicated_mount)
	else:
		view.global_position = view.global_position.lerp(pos, 0.4)
		if "visuals" in view and view.visuals:
			view.visuals.rotation.y = rot_y

func _on_entity_health(uid: int, hp: int, max_hp: int, _flags: int) -> void:
	if not _views.has(uid):
		return
	var view = _views[uid]
	if not is_instance_valid(view):
		return
	if "current_hp" in view:
		view.current_hp = hp
	if "max_hp" in view:
		view.max_hp = max_hp
	if view.has_method("_update_label"):
		view.call("_update_label")

func _on_cast_released(_cast_id: int, caster_uid: int, spell_id: String, origin: Vector3, dir: Vector3) -> void:
	var caster = SimAuthority.record_by_uid(caster_uid).get("node")
	if spell_id in ["incendio", "protego"]:
		preload("res://scripts/spells/skill_fx.gd").play_cast(self, caster if caster is Node3D else null, spell_id, origin, dir)
		return
	var proj = preload("res://scenes/spells/spell_projectile.tscn").instantiate()
	add_child(proj)
	proj.global_position = origin
	# The bolt on screen is a VIEW: the authority already decided what it hits.
	proj.visual_only = true
	proj.setup(caster if caster is Node3D else null, spell_id, dir, null, 1.0)

func _on_cast_landed(_cast_id: int, _caster_uid: int, spell_id: String, hits: Array) -> void:
	for hit in hits:
		var victim = SimAuthority.record_by_uid(int(hit.get("uid", 0))).get("node")
		if victim == null or not is_instance_valid(victim):
			continue
		if bool(hit.get("reflected", false)):
			preload("res://scripts/spells/skill_fx.gd").play_impact(self, (victim as Node3D).global_position + Vector3.UP, "protego")
			if victim.has_method("_spawn_floating_text"):
				victim.call("_spawn_floating_text", "REFLECTED!", Color(0.3, 0.8, 1.0), 1.3)
			continue
		preload("res://scripts/spells/skill_fx.gd").play_impact(self, (victim as Node3D).global_position + Vector3.UP, spell_id)

func _on_loot_spawned(uid: int, item_id: String, amount: int, pos: Vector3) -> void:
	var node = LOOT_SCENE.instantiate()
	add_child(node)
	node.global_position = pos
	node.setup(item_id, amount)
	SimAuthority.attach_view_node(uid, node)
	_views[uid] = node

func _on_chat(text: String) -> void:
	NetworkManager.chat_message_received.emit("[Server]", "", text)
