extends Node3D

## GameWorld - Hogwarts Valley MMO hub.
## Builds castle/village/forest/lake/pitch, NPCs, quests, overlay,
## leveled mob zones, monolith world bosses, and multiplayer replication.

@onready var players_container: Node3D = $Players
@onready var mobs_container: Node3D = $Mobs
@onready var monoliths_container: Node3D = $Monoliths
@onready var hud: Control = get_node_or_null("CanvasLayer/HUD")
@onready var inventory_ui: Control = get_node_or_null("CanvasLayer/InventoryUI")
@onready var ollivander_ui: Control = get_node_or_null("CanvasLayer/OllivanderUI")
## The chest window (built in code; opened by clicking a loot chest).
var loot_window: Control = null

const CavernColliders = preload("res://scripts/world/caverns/cavern_colliders.gd")
const PLAYER_SCENE = preload("res://scenes/entities/player/player.tscn")
const MONOLITH_SCENE = preload("res://scenes/entities/monolith/dark_monolith.tscn")
const INFERI_SCENE = preload("res://scenes/entities/mobs/mob_inferi.tscn")
const ACROMANTULA_SCENE = preload("res://scenes/entities/mobs/mob_acromantula.tscn")
const SNATCHER_SCENE = preload("res://scenes/entities/mobs/mob_darksnatcher.tscn")
const OVERLAY_SCRIPT = preload("res://scripts/ui/mmorpg_overlay.gd")
const MapControllerScript = preload("res://scripts/world/map_controller.gd")
const QualityPresetScript = preload("res://scripts/world/quality_preset.gd")
const NPCScript = preload("res://scripts/world/npc.gd")
const DummyScript = preload("res://scripts/world/training_dummy.gd")

var local_player: Node3D = null
## cast_id -> the travelling bolt view drawn for it (see _on_cast_landed).
var _bolt_views: Dictionary = {}
var overlay: CanvasLayer = null
## Client half of map transfer: portal interaction, fade and
## loading UI, loading the castle interior and unloading the outdoor world.
var map_controller: Node = null
var _candle_t: float = 0.0
var _particle_sweep: float = 1.0
var _views: Dictionary = {}          # sim uid -> view node (client role)
var _view_scenes: Dictionary = {}

const LOOT_SCENE = preload("res://scenes/entities/loot/loot_drop.tscn")

func _enter_tree() -> void:
	# Remove presentation before child _ready callbacks. Freeing it in our
	# _ready was too late: the headless world had already built all UI assets.
	if NetworkManager.is_dedicated_server:
		var canvas := get_node_or_null("CanvasLayer")
		if canvas:
			remove_child(canvas)
			canvas.free()

func _ready() -> void:
	if not NetworkManager.is_dedicated_server:
		_request_mob_scenes()
	GroundsBuilder.build(self)
	# Heightfield maps with creatures (the Blackweb Caverns) keep their ground
	# resident in every process: packs live there whether or not it is loaded.
	CavernColliders.ensure(self)
	SimAuthority.attach_world(self)
	var authority := SimAuthority.is_authority()
	if not NetworkManager.is_dedicated_server:
		_spawn_local_player()
		_setup_overlay()
		var hit_feedback := HitFeedback.ensure(self)
		if hit_feedback != null and is_instance_valid(local_player):
			hit_feedback.local_player = local_player
		_connect_ui_signals()
		_setup_map_controller()
		var canvas := get_node_or_null("CanvasLayer")
		if canvas != null:
			loot_window = LootWindow.new()
			loot_window.name = "LootWindow"
			canvas.add_child(loot_window)
		add_child(TargetRing.new())
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
	_drain_view_queue()
	if DisplayServer.get_name() == "headless":
		# Dedicated server / tests: nothing below is gameplay - it is candle,
		# torch and particle dressing, and the particle sweep walks the whole
		# tree (thousands of creatures) every second.
		return
	_candle_t += delta
	# Reduced-quality particle budget: effects spawn during play, so the preset
	# is re-applied on a slow sweep rather than once at build time.
	_particle_sweep -= delta
	if _particle_sweep <= 0.0:
		_particle_sweep = 1.0
		if QualityPresetScript.particle_scale() != 1.0:
			QualityPresetScript.tune_particles(self)
		# The player camera appears after the world is built (and on respawn).
		QualityPresetScript.apply_camera(get_viewport().get_camera_3d())
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
	# Each lamp breathes around its own authored energy on its own phase: the
	# old shared 9 Hz sine (one energy for every lamp) pulsed the whole valley
	# in step.
	for l in get_tree().get_nodes_in_group("torch_lights"):
		if l is OmniLight3D:
			var omni := l as OmniLight3D
			if not omni.has_meta("base_energy"):
				omni.set_meta("base_energy", omni.light_energy)
				omni.set_meta("flicker_phase", randf() * TAU)
			var ph := float(omni.get_meta("flicker_phase"))
			var wobble := sin(_candle_t * 7.3 + ph) * 0.6 + sin(_candle_t * 12.7 + ph * 1.7) * 0.4
			omni.light_energy = float(omni.get_meta("base_energy")) * (0.93 + 0.07 * wobble)
	for b in get_tree().get_nodes_in_group("castle_banners"):
		if b is MeshInstance3D:
			(b as MeshInstance3D).rotation.y = sin(_candle_t * 1.6) * 0.12

var _offline_save_timer: float = 15.0

func _spawn_local_player() -> void:
	local_player = PLAYER_SCENE.instantiate()
	local_player.is_local_player = true
	local_player.player_name = NetworkManager.local_player_name
	local_player.house = NetworkManager.local_player_house
	players_container.add_child(local_player)
	
	if not NetworkManager.local_character_data.is_empty():
		var c: Dictionary = NetworkManager.local_character_data
		var fallback := HPMaps.default_spawn(HPProtocol.DEFAULT_MAP)
		var px: float = float(c.get("pos_x", fallback.x))
		var py: float = float(c.get("pos_y", fallback.y))
		var pz: float = float(c.get("pos_z", fallback.z))
		# The account service's sheet (what a bound session receives) carries the
		# position as `pos: [x, y, z]`; the offline save format uses pos_x/y/z.
		# Either way the body starts where the character last was, which is what
		# makes the map controller boot the interior for a castle logout.
		if c.get("pos") is Array and (c["pos"] as Array).size() == 3:
			var saved: Array = c["pos"]
			px = float(saved[0])
			py = float(saved[1])
			pz = float(saved[2])
		# A position from the old valley map (or a fresh sheet's database
		# default) lies inside the current grounds' hill: start at the spawn.
		var saved_at := Vector3(px, py, pz)
		local_player.global_position = SimAuthority.start_position(HPMaps.map_for_point(saved_at), saved_at)
		local_player.visuals.rotation.y = float(c.get("rot_y", PI))
		local_player.restore_character(c)
		print("[GameWorld] Restored character '%s' at %s, Level %d, Wand +%d, Galleons %d" % [
			local_player.player_name, local_player.global_position, local_player.level, local_player.wand_tier, local_player.galleons
		])
	else:
		local_player.global_position = HPMaps.default_spawn(HPProtocol.DEFAULT_MAP)
		local_player.visuals.rotation.y = 0.0
	
	# Offline play kept its quest chain in a local file before quests moved to
	# the authority; carry it into the character once.
	if SimAuthority.is_authority() and not local_player.has_quest_progress():
		var legacy: Dictionary = QuestManager.legacy_progress()
		if not legacy.is_empty():
			var quests: Dictionary = local_player.persisted_quests()
			quests.merge(legacy, true)
			local_player.restore_quest_state(quests)
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
	if local_player.has_signal("inventory_changed") and not local_player.inventory_changed.is_connected(_save_offline_state):
		local_player.inventory_changed.connect(_save_offline_state)
	if local_player.has_signal("equipment_changed") and not local_player.equipment_changed.is_connected(_save_offline_state):
		local_player.equipment_changed.connect(_save_offline_state)
	_check_external_models()

func _notification(what: int) -> void:
	if what == NOTIFICATION_WM_CLOSE_REQUEST or what == NOTIFICATION_PREDELETE:
		_save_offline_state()

func _save_offline_state() -> void:
	# Also reached from PREDELETE, when the body may already be out of the tree
	# (its global transform is then undefined).
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
			"equipment": local_player.equipment.duplicate(true),
			"equipment_version": 1,
			"inventory_revision": local_player.inventory_revision,
			"base_max_hp": local_player.base_max_hp,
			"base_max_mana": local_player.base_max_mana,
			"pos_x": local_player.global_position.x,
			"pos_y": local_player.global_position.y,
			"pos_z": local_player.global_position.z,
			"rot_y": local_player.visuals.rotation.y if local_player.get("visuals") != null else 0.0,
			"inventory": local_player.inventory,
			"quests": local_player.persisted_quests()
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
	# The objective tracker under the minimap opens the quest scroll and the
	# training guide in the HUD.
	if hud != null and overlay.get("tracker") != null:
		overlay.tracker.onboarding = hud.onboarding
		overlay.tracker.quest_opened.connect(hud.open_quest_scroll)
		overlay.tracker.guide_opened.connect(hud.open_guide)

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
		hud.open_chat()
		get_viewport().set_input_as_handled()
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
		# One Esc chain for the whole HUD: close the top-most open thing, or
		# open the game menu when nothing is open.
		if hud != null and hud.has_method("handle_escape"):
			hud.handle_escape(self)
		else:
			inventory_ui.hide()
			ollivander_ui.hide()
			if overlay:
				overlay._dialog_panel.hide()
		get_viewport().set_input_as_handled()

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
	_spawn_npc(npcs, "Professor Fig", _on_ground(-12, 72),
		["Ah, a new student! Hogwarts needs brave wizards.",
		"Acromantulas infest the Forbidden Forest to the west. Inferi haunt its edge, past Hagrid's hut.",
		"Break a Dark Monolith (follow the purple beams), refine your wand (O), then fly to the Quidditch Pitch (Shift to mount)."],
		Color(0.2, 0.25, 0.5))
	_spawn_npc(npcs, "Ollivander", _on_ground(16, 68.6),
		["Wands choose the wizard... but Galleons refine them!",
		"Press O anywhere to open my workshop. Bring Phoenix Ash, Heartstrings, Thestral Hair.",
		"+4 glows blue, +7 crackles gold, +9 burns with phoenix fire!"],
		Color(0.45, 0.3, 0.15))
	_spawn_npc(npcs, "Madam Rosmerta", _on_ground(684, -174),
		["Welcome to Hogsmeade, dearie! Rest here - the village square is safe.",
		"Buy Wiggenweld before heading to the Forbidden Forest. Trust me."],
		Color(0.5, 0.15, 0.2))
	_spawn_npc(npcs, "Hagrid", _on_ground(-278, -11),
		["Yeh shouldn' go into the forest alone... brave though!",
		"Inferi fear fire - hit 'em with Incendio (2). Stupefy (1) stuns 'em cold."],
		Color(0.25, 0.3, 0.15))
	_spawn_npc(npcs, "Madam Pince", _on_ground(-22, 20),
		["The library is inside, past the great doors. Mind the books.", "The Great Hall is through the entrance hall. Charms is across the hall."], Color(0.2, 0.15, 0.3))
	_spawn_npc(npcs, "Professor Flitwick", _on_ground(22, 20),
		["Welcome! Stupefy interrupts, Incendio burns, and Expelliarmus weakens attacks.", "Practise at the dummies east of the courtyard, then pull a pack together. Watch the boss's warning circle."], Color(0.1, 0.24, 0.4))

## A point on a non-grounds map's resident collider (a ray down from `at`).
func _on_map_ground(at: Vector3) -> Vector3:
	var query := PhysicsRayQueryParameters3D.create(at + Vector3.UP * 20.0, at - Vector3.UP * 30.0, 1)
	var hit := get_world_3d().direct_space_state.intersect_ray(query)
	return at if hit.is_empty() else (hit["position"] as Vector3)

## A point on the grounds terrain (the authored NPC spots are x, z only).
func _on_ground(x: float, z: float) -> Vector3:
	var h := GroundsTerrain.height_at(x, z)
	return Vector3(x, 0.0 if is_nan(h) else h + 0.05, z)

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
	# A local hint only: this used to be SENT as chat, so every player saw it as
	# a line spoken by whoever loaded the world.
	if hud != null and hud.has_method("add_system_chat"):
		hud.add_system_chat("Training dummies stand in the courtyard - practise your spells there safely.")

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
		print("[World] external models found: %s" % ", ".join(found))

func _setup_monoliths_and_mobs() -> void:
	# Positions are the authority's data (spawn_tables.json "monoliths").
	# Each entry names its type (monolith_types: the type's scene); a stone on
	# another map (the caverns' seal stones) stands on that map's collider.
	for entry in HPRules.spawn_tables().get("monoliths", []):
		var raw: Array = entry.get("pos", [0.0, 0.0, 0.0])
		var pos := _on_ground(float(raw[0]), float(raw[2]))
		if float(raw[1]) > 185.0:
			pos = _on_map_ground(Vector3(float(raw[0]), float(raw[1]), float(raw[2])))
		var type := String(entry.get("type", "dark"))
		var path := String(HPRules.monolith_type(type).get("scene", ""))
		var scene: PackedScene = load(path) if path != "" and ResourceLoader.exists(path) else MONOLITH_SCENE
		var monolith = scene.instantiate()
		monoliths_container.add_child(monolith)
		monolith.global_position = pos
		# Each stone lands somewhere about its authored spot, not on it.
		monolith.home = pos
		monolith.global_position = monolith.pick_landing()

	var director := preload("res://scripts/world/encounter_director.gd").new()
	director.name = "EncounterDirector"
	add_child(director)
	director.start(mobs_container)
	# Scripted dungeon runs (instanced maps) share the encounter configuration.
	var dungeons := preload("res://scripts/world/dungeon_director.gd").new()
	dungeons.name = "DungeonDirector"
	add_child(dungeons)
	dungeons.start(self, director)

## ------------------------------------------------------------------
## Replication. In a client-only process the world contains no gameplay
## entities of its own: views are created for entities the server announces and
## removed when it stops announcing them. In authority roles the same signals
## drive presentation for the entities the engine already simulated.
## ------------------------------------------------------------------

func _map_mobs() -> Node3D:
	var node := get_node_or_null("MapMobs") as Node3D
	if node == null:
		node = Node3D.new()
		node.name = "MapMobs"
		add_child(node)
	return node

func _setup_replication() -> void:
	SimAuthority.entity_replicating.connect(_on_entity_replicating)
	SimAuthority.player_info.connect(_on_player_info)
	SimAuthority.map_changed.connect(_on_local_map_changed)
	SimAuthority.entity_despawned.connect(_on_entity_despawned)
	SimAuthority.entity_moved.connect(_on_entity_moved)
	SimAuthority.entity_health.connect(_on_entity_health)
	if not NetworkManager.is_dedicated_server:
		SimAuthority.entity_died.connect(_on_entity_died_view)
		SimAuthority.entity_respawned.connect(_on_entity_respawned_view)
	# Cast gestures, bolts and impacts are pictures only. A dedicated server
	# drew them too - an invisible bolt scene per cast and an impact per hit,
	# ~20 ms each, inside the sim tick: one player fighting held the server's
	# frame at 50-90 ms.
	if not NetworkManager.is_dedicated_server:
		SimAuthority.cast_started.connect(_on_cast_started)
		SimAuthority.cast_released.connect(_on_cast_released)
		SimAuthority.cast_landed.connect(_on_cast_landed)
	SimAuthority.loot_spawned.connect(_on_loot_spawned)
	SimAuthority.chat.connect(_on_chat)
	SimAuthority.world_event.connect(_on_world_event)
	SimAuthority.chat_line.connect(_on_chat_line)
	if is_instance_valid(local_player):
		SimAuthority.cast_ack.connect(local_player.on_cast_answer)
	# Catch up: snapshots keep arriving while the loading screen is up, and the
	# first sight of an entity (entity_replicating) fired with no world here to
	# hear it. Without this, a player who was already in range when we loaded
	# in had no body on screen until they left range and came back.
	if not SimAuthority.is_authority():
		for uid in SimAuthority.entities.keys():
			var record: Dictionary = SimAuthority.entities[uid]
			if bool(record.get("replica", false)) and not bool(record.get("local", false)) \
					and int(uid) != SimAuthority.local_uid and int(uid) != SimNet.local_uid \
					and record.get("node") == null:
				if int(record.get("kind", 0)) == HPProtocol.Kind.LOOT:
					_on_loot_spawned(int(uid), String(record.get("item_id", "")), int(record.get("amount", 1)),
						record.get("pos", Vector3.ZERO), record.get("items", []))
				else:
					_on_entity_replicating(record)

## Replicated entities entering range become views a few per frame: a dense
## hunting ground (or the first snapshot after joining) brings dozens of
## creatures at once, and instantiating every skinned body in one frame was a
## visible hitch. Players are never queued. Creature scenes are requested on a
## background thread at startup so the first of a kind does not load from disk.
const VIEWS_PER_FRAME := 3
var _view_queue: Array = []        # uids, oldest first
var _queued: Dictionary = {}       # uid -> true
var _mob_scenes_requested := false

func _request_mob_scenes() -> void:
	if _mob_scenes_requested:
		return
	_mob_scenes_requested = true
	for path in HPProtocol.MOB_SCENES.values():
		if ResourceLoader.exists(String(path)):
			# No sub-threads: that mode can deadlock against a main-thread load of a
			# shared dependency (the creature view below waits on these).
			ResourceLoader.load_threaded_request(String(path), "PackedScene", false)

## Creature scenes stay loaded for the life of the world. Nothing else held
## them: once the last troll of a pack despawned the PackedScene was freed, and
## the next troll in sight loaded it from disk again - live logs showed the same
## troll scene opened 120+ times in a session, each a frame hitch (and a ping
## spike, as the ping includes the client's frame) right as a fight began.
var _mob_scene_cache: Dictionary = {}   # path -> PackedScene

func _mob_scene(variant: int) -> PackedScene:
	var path := HPProtocol.mob_scene(variant)
	var cached: PackedScene = _mob_scene_cache.get(path)
	if cached != null:
		return cached
	var scene: PackedScene = null
	if ResourceLoader.load_threaded_get_status(path) != ResourceLoader.THREAD_LOAD_INVALID_RESOURCE:
		scene = ResourceLoader.load_threaded_get(path) as PackedScene
	else:
		scene = load(path) as PackedScene
	if scene != null:
		_mob_scene_cache[path] = scene
	return scene

func _on_entity_replicating(record: Dictionary) -> void:
	var uid := int(record["uid"])
	if _views.has(uid) or record.get("node") != null or _queued.has(uid):
		return   # already on screen (authority roles own their nodes) or on its way
	if int(record.get("kind", 0)) == HPProtocol.Kind.PLAYER:
		_create_view(record)
		return
	_queued[uid] = true
	_view_queue.append(uid)

func _drain_view_queue() -> void:
	var made := 0
	while made < VIEWS_PER_FRAME and not _view_queue.is_empty():
		var uid := int(_view_queue.pop_front())
		_queued.erase(uid)
		var record: Dictionary = SimAuthority.entities.get(uid, {})
		if record.is_empty() or _views.has(uid) or record.get("node") != null:
			continue   # despawned (or claimed) while it waited
		_create_view(record)
		made += 1

func _create_view(record: Dictionary) -> void:
	var uid := int(record["uid"])
	var kind := int(record.get("kind", 0))
	var scene: PackedScene = null
	match kind:
		HPProtocol.Kind.PLAYER:
			scene = PLAYER_SCENE
		HPProtocol.Kind.MOB:
			scene = _mob_scene(int(record.get("variant", HPProtocol.MOB_VARIANT_INFERI)))
		HPProtocol.Kind.MONOLITH:
			# The variant names the stone's body (v19): the caverns' seal stone,
			# else the Dark Monolith.
			scene = MONOLITH_SCENE
			if int(record.get("variant", 0)) == HPProtocol.MOB_VARIANT_SPIDER_STONE:
				scene = _mob_scene(HPProtocol.MOB_VARIANT_SPIDER_STONE)
		HPProtocol.Kind.DUMMY:
			_bind_dummy(record)
			return
		_:
			return
	if scene == null:
		return
	var view: Node3D = scene.instantiate()
	view.name = "View%d" % uid
	if kind == HPProtocol.Kind.MOB:
		# A replicated mob is a puppet: no AI, no damage, follows the snapshots.
		view.sim_puppet = true
		# The legacy boss bodies (matriarch, commander) were scaled-up ordinary
		# models; newer creatures carry their own boss body (BossVariant).
		var legacy := int(record.get("variant", 0)) <= HPProtocol.MOB_VARIANT_DARKSATCHER
		if legacy and (int(record.get("flags", 0)) & HPProtocol.FLAG_BOSS) != 0:
			var is_commander := int(record.get("variant", 0)) == HPProtocol.MOB_VARIANT_DARKSATCHER
			var visuals := view.get_node_or_null("Visuals")
			if visuals:
				visuals.scale = Vector3.ONE * (1.65 if is_commander else 2.0)
			var label := view.get_node_or_null("Label3D")
			if label:
				label.position.y = 4.2
		# Grounds creatures live in the grounds container (hidden off-map);
		# creatures of any other map (a dungeon copy) get one that stays shown.
		if String(record.get("map_id", HPProtocol.DEFAULT_MAP)) == HPProtocol.DEFAULT_MAP:
			mobs_container.add_child(view)
		else:
			_map_mobs().add_child(view)
	elif kind == HPProtocol.Kind.PLAYER:
		view.is_local_player = false
		_apply_player_info(view, record)
		# Another player's body is a VIEW here: it follows the replicated state
		# and never reads this client's keyboard.
		view.sim_puppet = true
		players_container.add_child(view)
	else:
		add_child(view)
	_views[uid] = view
	var spawn_pos: Vector3 = record.get("pos", Vector3.ZERO)
	view.global_position = spawn_pos
	SimAuthority.attach_view_node(uid, view)
	# A creature's health is level-scaled on the server: the scene's own number
	# (220 for any Inferi) stood on the label until the first hit.
	if kind != HPProtocol.Kind.PLAYER and int(record.get("max_hp", 0)) > 0 and "max_hp" in view:
		view.max_hp = int(record["max_hp"])
		view.current_hp = int(record.get("hp", view.max_hp))
		if view.has_method("_update_label"):
			view.call("_update_label")
	if "sim_target_pos" in view:
		view.sim_target_pos = spawn_pos
	if "sim_target_rot" in view:
		view.sim_target_rot = float(record.get("rot_y", 0.0))
	if "visuals" in view and view.visuals:
		view.visuals.rotation.y = float(record.get("rot_y", 0.0))

## The local body changed map: every other player's replica belongs to the map
## it left. They are dropped here (the server forgets them as well and
## re-announces whoever is on the new map), so nothing stale - a body left over
## from before the hop, or a late snapshot of it - can stand in for a player who
## is really here. Snapshots older than the hop are refused for a moment.
func _on_local_map_changed(uid: int, _map_id: String, _pos: Vector3) -> void:
	if SimAuthority.is_authority() or uid != SimAuthority.local_uid:
		return
	for other in SimAuthority.entities.keys():
		var record: Dictionary = SimAuthority.entities[other]
		if int(other) == SimAuthority.local_uid or bool(record.get("local", false)):
			continue
		if int(record.get("kind", 0)) != HPProtocol.Kind.PLAYER:
			continue
		SimAuthority.note_despawn(int(other), int(SimAuthority.sim_tick) + 10)
		_on_entity_despawned(int(other))

## v18: another player's name, house and level (sim_player_info). Without it a
## remote body kept the scene's default name.
func _on_player_info(uid: int, _info: Dictionary) -> void:
	var view = _views.get(uid)
	if is_instance_valid(view):
		_apply_player_info(view, SimAuthority.entities.get(uid, {}))

func _apply_player_info(view: Node, record: Dictionary) -> void:
	if String(record.get("name", "")) == "":
		return
	view.player_name = String(record["name"])
	if String(record.get("house", "")) != "":
		view.house = String(record["house"])
	view.level = int(record.get("level", view.level))
	if view.is_inside_tree() and view.has_method("_update_nameplate"):
		view._update_nameplate()

## Dummies are authored scenery in every process: a client never builds one
## from a record, it binds the replicated record to its own dummy at that spot,
## so the authority's hits show (numbers, health bar, wobble) on it.
func _bind_dummy(record: Dictionary) -> void:
	var pos: Vector3 = record.get("pos", Vector3.ZERO)
	var best: Node3D = null
	var best_d := 3.0
	for node in get_tree().get_nodes_in_group("dummies"):
		var d: float = (node as Node3D).global_position.distance_to(pos)
		if d < best_d:
			best_d = d
			best = node
	if best == null:
		return
	_views[int(record["uid"])] = best
	SimAuthority.attach_view_node(int(record["uid"]), best)
	best.current_hp = int(record.get("hp", best.current_hp))
	best.max_hp = int(record.get("max_hp", best.max_hp))
	best._update_label()

func _on_entity_despawned(uid: int) -> void:
	_queued.erase(uid)
	SimAuthority.drop_replica(uid)
	if not _views.has(uid):
		return
	var view = _views[uid]
	_views.erase(uid)
	if is_instance_valid(view) and view.is_in_group("dummies"):
		return   # scenery stays; it rebinds when the record comes back
	if is_instance_valid(view):
		if view.has_method("despawn"):
			view.despawn()
		else:
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
		# The replicated flight phase rides in the record's `state` byte,
		# so a remote rider animates the phase the authority chose, not a guess.
		if "sim_mount_phase" in view:
			view.sim_mount_phase = int(SimAuthority.entities.get(uid, {}).get("state", 0))
		if "is_mounted" in view:
			var replicated_mount := (flags & HPProtocol.FLAG_MOUNTED) != 0
			if replicated_mount != bool(view.is_mounted):
				view.is_mounted = replicated_mount
				if view.has_method("_apply_mount_state"):
					view._apply_mount_state(replicated_mount)
	elif view.is_in_group("monoliths"):
		view.global_position = pos   # stones never slide: a new one stands elsewhere
	else:
		view.global_position = view.global_position.lerp(pos, 0.4)
		if "visuals" in view and view.visuals:
			view.visuals.rotation.y = rot_y

## A replicated Metin stone shatters (and stands again) on the server's word.
func _on_entity_died_view(uid: int, _killer_uid: int) -> void:
	var view = _views.get(uid)
	if is_instance_valid(view) and view.is_in_group("monoliths") and view.has_method("present_death"):
		view.call("present_death")

func _on_entity_respawned_view(uid: int) -> void:
	var view = _views.get(uid)
	if is_instance_valid(view) and view.is_in_group("monoliths") and view.has_method("present_respawn"):
		view.call("present_respawn")

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

func _on_cast_started(caster_uid: int, cast_id: int, spell_id: String, aim: Vector3, release_tick: int) -> void:
	var caster = SimAuthority.record_by_uid(caster_uid).get("node")
	if is_instance_valid(caster) and caster.has_method("present_replicated_cast_start"):
		var delay := maxf(0.01, float(release_tick - SimAuthority.sim_tick) / HPProtocol.SIM_HZ)
		caster.call("present_replicated_cast_start", cast_id, aim, spell_id, delay)

func _on_cast_released(cast_id: int, caster_uid: int, spell_id: String, origin: Vector3, dir: Vector3) -> void:
	var caster = SimAuthority.record_by_uid(caster_uid).get("node")
	# Another player's body plays the gesture too, aimed from the authority's
	# direction, so a replicated cast reads the same as the caster's prediction.
	if caster != null and is_instance_valid(caster) and caster.has_method("present_replicated_cast"):
		caster.call("present_replicated_cast", origin, dir, spell_id, cast_id)
	# Cones (Incendio, Patronum) and self casts (Protego) draw at the caster;
	# everything else flies as a bolt.
	if String(HPRules.spell(spell_id).get("delivery", "")) in ["cone", "self"]:
		preload("res://scripts/spells/skill_fx.gd").play_cast(self, caster if caster is Node3D else null, spell_id, origin, dir)
		return
	var proj = preload("res://scenes/spells/spell_projectile.tscn").instantiate()
	add_child(proj)
	# Presentation only: the bolt on screen leaves the caster's wand head when one
	# is held, while `origin` (the authority's body-centred launch point, which
	# decided the damage) is left exactly as it was.
	proj.global_position = _presentation_cast_origin(caster, origin)
	# The bolt on screen is a VIEW: the authority already decided what it hits.
	proj.visual_only = true
	proj.setup(caster if caster is Node3D else null, spell_id, dir, null, 1.0)
	_bolt_views[cast_id] = proj

## Where the client draws a spell from. The authority's `origin` stays the
## body-centred launch point that decided the hit geometry; only the drawn bolt
## is re-anchored, and only for a caster that actually carries a wand.
func _presentation_cast_origin(caster: Node, origin: Vector3) -> Vector3:
	if caster == null or not is_instance_valid(caster) or not (caster is Node3D):
		return origin
	var tip: Node3D = HeroAppearance.wand_tip(caster)
	if tip != null and is_instance_valid(tip):
		return tip.global_position
	return origin

func _on_cast_landed(cast_id: int, _caster_uid: int, spell_id: String, hits: Array) -> void:
	var view = _bolt_views.get(cast_id)
	_bolt_views.erase(cast_id)
	# A single-target bolt that the authority says hit ends now, even if its view
	# has not reached the body yet; area blasts and misses draw their own end.
	if not hits.is_empty() and spell_id not in ["bombarda", "ultimate"] 			and view != null and is_instance_valid(view) and view.has_method("end_on_landed"):
		view.end_on_landed()
	if _bolt_views.size() > 64:
		for key in _bolt_views.keys():
			if not is_instance_valid(_bolt_views[key]):
				_bolt_views.erase(key)
	for hit in hits:
		var victim = SimAuthority.record_by_uid(int(hit.get("uid", 0))).get("node")
		if victim == null or not is_instance_valid(victim):
			continue
		if bool(hit.get("reflected", false)):
			preload("res://scripts/spells/skill_fx.gd").play_impact(self, (victim as Node3D).global_position + Vector3.UP, "protego")
			if victim.has_method("_spawn_floating_text"):
				victim.call("_spawn_floating_text", "REFLECTED!", Color(0.3, 0.8, 1.0), 1.3)
			continue
		# The travelling view draws one area blast at its collision point. Drawing
		# another full-radius blast on every victim duplicates the affected area.
		if spell_id in ["bombarda", "ultimate"]:
			continue
		preload("res://scripts/spells/skill_fx.gd").play_impact(self, (victim as Node3D).global_position + Vector3.UP, spell_id)

func _on_loot_spawned(uid: int, item_id: String, amount: int, pos: Vector3, items: Array = []) -> void:
	# One chest, one marker. A chest that lands while the player is watching
	# arrives twice - the spawn broadcast and the interest scan's first-sight
	# send - and a second view would be untracked: the despawn removes only the
	# tracked node, so a copy would stay on the ground. A re-announce of a
	# known chest (a partial take changed it) only updates its view.
	if is_instance_valid(_views.get(uid)):
		if _views[uid].has_method("setup"):
			_views[uid].setup(item_id, amount, items)
		return
	# Personal loot (a dungeon drop, v15) is drawn for its owner only.
	var owner := int(SimAuthority.entities.get(uid, {}).get("owner_uid", 0))
	if owner != 0 and SimAuthority.local_uid > 0 and owner != SimAuthority.local_uid:
		return
	var node = LOOT_SCENE.instantiate()
	add_child(node)
	node.global_position = pos
	node.setup(item_id, amount, items)
	node.set_meta("sim_uid", uid)
	SimAuthority.attach_view_node(uid, node)
	_views[uid] = node

func _on_world_event(kind: String, data: Dictionary) -> void:
	if hud != null and hud.has_method("show_world_event"):
		hud.show_world_event(kind, data)

func _on_chat(text: String) -> void:
	if hud != null and hud.has_method("add_system_chat"):
		hud.add_system_chat(text)
	else:
		NetworkManager.chat_message_received.emit("", "", text)

## A routed player line: into the chat log, and - for local speech - over the
## speaker's head as a bubble everyone nearby sees.
func _on_chat_line(channel: String, uid: int, sender: String, house: String, text: String) -> void:
	if hud != null and hud.has_method("add_chat_line"):
		hud.add_chat_line(channel, sender, house, text)
	NetworkManager.chat_message_received.emit(sender, house, text)
	if channel != "local":
		return
	var speaker: Node3D = null
	if uid == SimAuthority.local_uid and is_instance_valid(local_player):
		speaker = local_player
	elif _views.has(uid) and is_instance_valid(_views[uid]):
		speaker = _views[uid]
	else:
		var record: Dictionary = SimAuthority.entities.get(uid, {})
		var node = record.get("node")
		if node is Node3D and is_instance_valid(node):
			speaker = node
	if speaker != null:
		SpeechBubble.say(speaker, text, 2.62)
