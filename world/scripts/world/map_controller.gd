extends Node

## MapController - the client half of server-authorized map transfer (plan.md
## Phase 8), plus the local map host.
##
## What the client owns here (the server owns the decision, never the client):
##   * portal trigger volumes and the "press F" doorway interaction;
##   * the fade and the loading indicator;
##   * loading the destination map and freeing the map being left;
##   * moving the local body to the spawn the server approved;
##   * acknowledging readiness so ownership can move.
##
## Contract it speaks (owned by the server workstream, synced into
## `addons/hpmmo_sim/` - verified against the synced copy):
##
##   SimNet.request_transfer(player, portal_id, to_map) -> Dictionary
##   SimNet.mark_transfer_ready(token) -> Dictionary
##   SimNet.abort_transfer(token) -> Dictionary
##   SimAuthority.transfer_granted(peer_id: int, token: int, map_id: String, spawn_id: String)
##   SimAuthority.transfer_committed(peer_id: int, token: int, map_id: String, pos: Vector3, spawn_id: String)
##   SimAuthority.transfer_refused(peer_id: int, reason: String)
##   SimAuthority.transfer_expired(peer_id: int, token: int, map_id: String, pos: Vector3)
##   SimAuthority.map_state(map_id: String, pos: Vector3, spawn_id: String)   # join, or a correction
##   SimAuthority.map_changed(uid: int, map_id: String, pos: Vector3)
##
## One contract, one shape: the signals are connected directly to handlers with
## exactly these signatures, so a revision that renamed a method or reordered a
## field is a startup error, never a silently normalised no-op. If the API is
## absent entirely the controller says so loudly and refuses door transfers
## instead of loading maps locally behind the server's back - offline play does
## not need a fallback, because the same SimNet entry points answer through the
## in-process authority in that role too.
##
## Map data (portals, spawn points) comes from the shared catalog through
## HPMaps. The constants below are the same values written out, used as a
## fallback when the catalog cannot answer.

const WorldBuilderScript = preload("res://scripts/world/world_builder.gd")
const INTERIOR_PATH := "res://scenes/world/castle_interior.tscn"
const STAIRCASE_PATH := "res://scenes/world/castle/staircase.tscn"
const MAPS_PATH := "res://addons/hpmmo_sim/maps.gd"

const MAP_GROUNDS := "grounds"
const MAP_INTERIOR := "castle_interior"

const FADE_TIME := 0.25
const PROMPT_KEY := "F"

## Fallback copy of addons/hpmmo_sim/data/maps.json (portals + spawn points).
const PORTALS := {
	"grounds": [{
		"id": "castle_door", "to_map": "castle_interior", "to_spawn": "vestibule",
		"center": Vector3(0.0, 1.1, -46.0), "radius": 2.5, "y_min": -1.0, "y_max": 5.0,
		"label": "Hogwarts Entrance",
	}],
	"castle_interior": [{
		"id": "vestibule_exit", "to_map": "grounds", "to_spawn": "castle_approach",
		"center": Vector3(0.0, 201.6, 30.0), "radius": 2.5, "y_min": 185.0, "y_max": 212.0,
		"label": "Grounds",
	}],
}

const SPAWN_POINTS := {
	"grounds": {
		"default": Vector3(0.0, 0.5, 5.0),
		"courtyard": Vector3(0.0, 0.5, 5.0),
		"castle_approach": Vector3(0.0, 0.6, -40.0),
		"castle_landing_pad": Vector3(0.0, 0.6, -36.0),
	},
	"castle_interior": {
		"default": Vector3(0.0, 200.5, 30.0),
		"vestibule": Vector3(0.0, 200.5, 30.0),
	},
}

## The broom landing area in front of the castle: the same circle the catalog
## authors for `castle_door.landing` and `castle_landing_pad`. Flight is refused
## indoors, so the pad is where a rider lands and dismounts; world_builder draws
## it. Kept collision-free so it cannot trip the approach route.
const LANDING_PAD_CENTRE := Vector3(0.0, 0.0, -40.0)
const LANDING_PAD_RADIUS := 4.0

## Containers in the grounds scene that hold live entities. They are hidden, not
## freed: their entity records are simulation state owned elsewhere.
const GROUNDS_ENTITY_NODES := ["Mobs", "Monoliths", "NPCs", "TrainingGrounds", "EncounterDirector"]

var world: Node3D = null
var local_player: Node3D = null
var current_map: String = MAP_GROUNDS
var busy: bool = false
var server_api: bool = false

var _interior: Node3D = null
var _hidden: Dictionary = {}
var _sun_disabled: Array = []
var _pending_portal: Dictionary = {}
var _active_portal: Dictionary = {}
var _active_label: String = ""
var _fade: float = 0.0
var _fade_target: float = 0.0
var _notice: String = ""
var _notice_t: float = 0.0
var _label_throttle: float = 0.0
## Set when the authority's transfer_committed arrives for this body: it means
## the authority already placed the body at the approved spawn.
var _commit_seen: bool = false

var _fade_rect: ColorRect = null
var _loading_label: Label = null
var _location_label: Label = null
var _prompt_label: Label = null
var _notice_label: Label = null

## Counts for the walkthrough evidence (nodes/resources before and after a
## transfer, so accumulation is visible instead of asserted).
var transfer_log: Array = []

func _ready() -> void:
	world = get_parent() as Node3D
	# One fail-fast check of the ONE shipped contract, made once at startup.
	# This is not a probe for an alternative shape: if any part is missing the
	# synced hpmmo_sim package is broken, and a door must refuse loudly rather
	# than swap maps locally behind the server's back.
	server_api = SimNet.has_method("request_transfer") \
		and SimNet.has_method("mark_transfer_ready") \
		and SimAuthority.has_signal("transfer_granted") \
		and SimAuthority.has_signal("transfer_committed") \
		and SimAuthority.has_signal("transfer_refused") \
		and SimAuthority.has_signal("transfer_expired") \
		and SimAuthority.has_signal("map_state") \
		and SimAuthority.has_signal("map_changed")
	if not server_api:
		push_error("[MapController] the synced hpmmo_sim map-transfer API " +
			"(SimNet.request_transfer/mark_transfer_ready and the transfer_*/map_* signals) " +
			"is not in this build. Doors are disabled; maps are NOT swapped locally, because " +
			"a local swap would hide a broken sim-package sync.")
	else:
		_connect_sim()
	_build_ui()
	current_map = _initial_map()
	call_deferred("_bind_player")

## The map this body belongs to, decided by where the body is: the catalog's
## y-band (the interior is authored above y=185) says which map a saved position
## is in, so a character that logged out inside the castle boots inside it. The
## authority's own answer is the fallback when there is no local body yet.
func _initial_map() -> String:
	var node: Node3D = null
	var parent := get_parent()
	if parent != null:
		node = parent.get("local_player")
	if node != null and is_instance_valid(node):
		var maps := _maps_script()
		if maps != null:
			var answer: String = maps.call("map_for_point", node.global_position)
			if answer != "":
				return answer
		return MAP_INTERIOR if node.global_position.y > 185.0 else MAP_GROUNDS
	# No local body (a dedicated server, where this controller is not created):
	# the outdoor map is the only sensible default.
	return MAP_GROUNDS

func _bind_player() -> void:
	world = get_parent() as Node3D
	local_player = world.get("local_player") if world != null else null
	if local_player == null and world != null:
		local_player = world.get_node_or_null("Players/P1")
	if is_instance_valid(local_player) and not local_player.mounted_changed.is_connected(_on_mounted_changed):
		local_player.mounted_changed.connect(_on_mounted_changed)

## --------------------------------------------------------------- sim hooks

## Signal wiring for the one shipped contract: direct, typed connections whose
## handler signatures are the signal signatures. A contract revision that
## reorders a field now fails at connect time instead of being normalised into
## whichever reading the lambda guessed.
func _connect_sim() -> void:
	SimAuthority.transfer_granted.connect(_on_transfer_granted)
	SimAuthority.transfer_committed.connect(_on_transfer_committed)
	SimAuthority.transfer_refused.connect(_on_transfer_refused)
	SimAuthority.transfer_expired.connect(_on_transfer_expired)
	SimAuthority.map_state.connect(_on_map_state)
	SimAuthority.map_changed.connect(_on_map_changed)

func _map_available(map_id: String) -> bool:
	match map_id:
		MAP_GROUNDS:
			return true
		MAP_INTERIOR:
			return ResourceLoader.exists(INTERIOR_PATH)
	return false

# ------------------------------------------------------------------ process

func _process(delta: float) -> void:
	_fade = move_toward(_fade, _fade_target, delta / FADE_TIME)
	if _fade_rect != null:
		_fade_rect.color = Color(0.02, 0.02, 0.04, _fade)
	if _loading_label != null:
		_loading_label.visible = _fade > 0.45
	if _notice_t > 0.0:
		_notice_t = maxf(0.0, _notice_t - delta)
		if _notice_t == 0.0:
			_notice = ""
	if world == null or not is_instance_valid(world):
		return
	if not is_instance_valid(local_player):
		_bind_player()

	_label_throttle -= delta
	if _label_throttle <= 0.0:
		_label_throttle = 0.25
		_update_labels()

	if busy or not is_instance_valid(local_player):
		_active_portal = {}
		return
	# Portal volumes are checked against the local body every frame rather than
	# by Area3D entry: an Area fires on a physics step and a body that walked in
	# during a fade would be silently missed.
	var found: Dictionary = {}
	for portal in _portal_entries(current_map):
		if _portal_contains(portal, local_player.global_position):
			found = portal
			break
	_active_portal = found
	if found.is_empty():
		_active_label = ""
	elif _mounted():
		_active_label = "Mounted - the castle door is closed to broom flight. Dismount to enter."
	else:
		_active_label = "Press %s - %s" % [PROMPT_KEY, _portal_prompt(found)]

func _unhandled_input(event: InputEvent) -> void:
	if busy or _active_portal.is_empty() or not is_instance_valid(local_player):
		return
	if not event.is_action_pressed("interact"):
		return
	if player_input_blocked():
		return
	get_viewport().set_input_as_handled()
	_begin_transfer(_active_portal)

## The local body is mounted: entering the castle is refused (the authority
## refuses it too; this is the presentation half).
func _on_mounted_changed(is_mounted: bool) -> void:
	if not is_mounted or current_map != MAP_INTERIOR:
		return
	# Flight is prohibited indoors. The authority refuses the mount, so the
	# predicted one is rolled back here with a clear reason instead of leaving a
	# broom standing in the Great Hall until the next stats push.
	call_deferred("_refuse_indoor_mount")

func _refuse_indoor_mount() -> void:
	if not is_instance_valid(local_player) or not bool(local_player.get("is_mounted")):
		return
	if local_player.has_method("_apply_mount_state"):
		local_player.call("_apply_mount_state", false)
	if local_player.has_method("show_floating_text"):
		local_player.call("show_floating_text", "No flying inside the castle!", Color(1.0, 0.8, 0.4))
	_feedback("The broom cannot fly inside the castle - it stays stowed until you are outside.")

func _mounted() -> bool:
	return is_instance_valid(local_player) and bool(local_player.get("is_mounted"))

func player_input_blocked() -> bool:
	if is_instance_valid(local_player) and local_player.has_method("input_blocked"):
		return bool(local_player.call("input_blocked"))
	return false

# ------------------------------------------------------------- transfer flow

func _begin_transfer(portal: Dictionary) -> void:
	if busy:
		return
	if _mounted():
		_feedback("Dismount before entering - the broom cannot fly inside the castle.")
		return
	if not server_api:
		_feedback("Map transfers are unavailable: the synced map-transfer API is missing from this build.")
		return
	_pending_portal = portal
	# The client names only the portal it stands at: destination, spawn, token
	# and timing are the server's. In the authority roles (offline/host) the same
	# entry point answers locally through the in-process engine, so offline play
	# runs the identical validation.
	var result: Dictionary = SimNet.request_transfer(
		local_player, String(portal.get("id", "")), String(portal.get("to_map", "")))
	if not bool(result.get("ok", false)):
		_feedback(_reason_text(String(result.get("reason", ""))))
		return
	# "sent" (client role), or a local grant that was emitted synchronously
	# inside the call and has already started the load; either way the
	# transfer_* signal drives the rest, and nothing here may skip it.
	return

## The authority approved the transfer: load the destination, then acknowledge.
func _on_transfer_granted(peer_id: int, token: int, map_id: String, spawn_id: String) -> void:
	if peer_id != SimNet.local_peer_id:
		return
	_start_transfer(map_id, spawn_id, token)

func _on_transfer_committed(peer_id: int, _token: int, map_id: String, pos: Vector3, _spawn_id: String) -> void:
	if peer_id != SimNet.local_peer_id:
		return
	current_map = map_id
	_commit_seen = true
	if is_instance_valid(local_player) and not busy:
		local_player.global_position = pos

func _on_transfer_refused(peer_id: int, reason: String) -> void:
	if peer_id != SimNet.local_peer_id:
		return
	_pending_portal = {}
	_feedback(_reason_text(reason))

func _on_transfer_expired(peer_id: int, _token: int, map_id: String, pos: Vector3) -> void:
	if peer_id != SimNet.local_peer_id:
		return
	_pending_portal = {}
	_feedback("The transfer timed out; you are back at your last safe spot.")
	if not busy:
		current_map = map_id
		if is_instance_valid(local_player):
			local_player.global_position = pos

## The authoritative answer to "which map is this body in": sent at join and on
## an interrupted transfer. It always wins.
func _on_map_state(map_id: String, pos: Vector3, _spawn_id: String) -> void:
	if busy:
		return
	if map_id == current_map and _map_loaded(map_id):
		if is_instance_valid(local_player):
			local_player.global_position = pos
		return
	_start_transfer(map_id, "default", 0, pos)

func _on_map_changed(uid: int, map_id: String, pos) -> void:
	if uid != SimAuthority.local_uid or busy or not (pos is Vector3):
		return
	if map_id != current_map:
		_start_transfer(map_id, "default", 0, pos)

func _start_transfer(map_id: String, spawn_id: String, token: int, forced_pos: Variant = null) -> void:
	if busy or map_id == "":
		return
	if not _map_available(map_id):
		_feedback("That map is not available in this build.")
		return
	busy = true
	_active_portal = {}
	_feedback("")
	_loading_label.text = _loading_text(map_id)
	_fade_target = 1.0
	await get_tree().create_timer(FADE_TIME + 0.05).timeout

	await _unload_map(current_map)
	var loaded := await _load_map(map_id)
	if not loaded:
		_feedback("The map failed to load; staying where you are.")
		await _load_map(current_map)
		_fade_target = 0.0
		busy = false
		# No acknowledgement: the server's reservation expires and returns the
		# body to its last safe spawn instead of stranding it between maps.
		return

	current_map = map_id
	# Acknowledge first: the authority commits on that ack and places the body at
	# the spawn it approved. The client only places the body itself when there is
	# no authority to do it (or the answer never arrives) - moving the body into
	# the destination's y-band before ownership moved would look like a fall to
	# the map's own out-of-band check.
	_commit_seen = false
	if token != 0:
		SimNet.mark_transfer_ready(token)
		await _await_commit(2.0)
	if not _commit_seen:
		var target: Vector3 = forced_pos if forced_pos is Vector3 else _spawn_point(map_id, spawn_id)
		_place_player(target)
	_fade_target = 0.0
	await get_tree().create_timer(FADE_TIME + 0.05).timeout
	busy = false
	_record_transfer(map_id, spawn_id, token)

func _await_commit(timeout: float) -> void:
	var waited := 0.0
	while not _commit_seen and waited < timeout:
		await get_tree().process_frame
		waited += get_process_delta_time()

func _place_player(pos: Vector3) -> void:
	if not is_instance_valid(local_player):
		return
	local_player.global_position = pos
	if "velocity" in local_player:
		local_player.set("velocity", Vector3.ZERO)
	# The camera pivot is a top-level node that eases toward the body; across a
	# 200 m map hop it must snap, or the first frames are seen from the old map.
	if "camera_pivot" in local_player:
		var pivot = local_player.get("camera_pivot")
		if pivot is Node3D and is_instance_valid(pivot):
			(pivot as Node3D).global_position = pos + Vector3(0, 1.4, 0)

# ------------------------------------------------------------------- maps

func _map_loaded(map_id: String) -> bool:
	if map_id == MAP_GROUNDS:
		return world != null and world.has_node("HogwartsCastle")
	return _interior != null and is_instance_valid(_interior)

func _unload_map(map_id: String) -> void:
	if map_id == MAP_INTERIOR:
		await _free_interior()
		return
	# Grounds: free the scenery WorldBuilder created and hide the entity
	# containers. Terrain (the ground collider) and the sim entities stay: they
	# are the world's collision/state, not its map resources.
	WorldBuilderScript.teardown(world)
	for node_name in GROUNDS_ENTITY_NODES:
		var node := world.get_node_or_null(node_name)
		if node is Node3D and (node as Node3D).visible:
			_hidden[node_name] = true
			(node as Node3D).visible = false
	for light in _directional_lights(world):
		if light.visible:
			_sun_disabled.append(light)
			light.visible = false

func _load_map(map_id: String) -> bool:
	if map_id == MAP_GROUNDS:
		# Rebuild the outdoor scenery. build() is idempotent and cheap (it only
		# runs when the castle node is absent, which teardown guarantees).
		WorldBuilderScript.build(world)
		for node_name in _hidden.keys():
			var node := world.get_node_or_null(String(node_name))
			if node is Node3D:
				(node as Node3D).visible = true
		_hidden.clear()
		for light in _sun_disabled:
			if is_instance_valid(light):
				light.visible = true
		_sun_disabled.clear()
		return true
	if map_id != MAP_INTERIOR:
		return false
	var packed := await _load_threaded(INTERIOR_PATH)
	if packed == null:
		return false
	_interior = packed.instantiate()
	_interior.name = "CastleInterior"
	world.add_child(_interior)
	if _interior.has_method("attach_staircase"):
		var attached: bool = _interior.call("attach_staircase")
		if not attached:
			print("[MapController] StaircaseSlot left empty: %s is not present in this build " % STAIRCASE_PATH +
				"(owned by the staircase workstream; no file was created or edited here).")
	return true

func _free_interior() -> void:
	if _interior == null or not is_instance_valid(_interior):
		_interior = null
		return
	if _interior.has_method("teardown"):
		_interior.call("teardown")
	if _interior.get_parent() != null:
		_interior.get_parent().remove_child(_interior)
	_interior.queue_free()
	_interior = null
	await get_tree().process_frame

## Threaded load (plan.md Phase 8: poll the request instead of blocking the
## loading screen). Falls back to a blocking load if the request is refused.
func _load_threaded(path: String) -> PackedScene:
	if not ResourceLoader.exists(path):
		return null
	var error := ResourceLoader.load_threaded_request(path)
	if error != OK:
		return load(path) as PackedScene
	while true:
		var status := ResourceLoader.load_threaded_get_status(path)
		match status:
			ResourceLoader.THREAD_LOAD_IN_PROGRESS:
				await get_tree().process_frame
			ResourceLoader.THREAD_LOAD_LOADED:
				var resource := ResourceLoader.load_threaded_get(path)
				return resource as PackedScene
			_:
				return null
	return null

func _directional_lights(root: Node) -> Array:
	var out: Array = []
	for child in root.get_children():
		if child is DirectionalLight3D:
			out.append(child)
	return out

# ------------------------------------------------------------ portal data

func _portal_entries(map_id: String) -> Array:
	var maps := _maps_script()
	if maps != null:
		var out: Array = []
		var portals: Array = maps.call("portals_for_map", map_id)
		for entry in portals:
			if not entry is Dictionary:
				continue
			var trigger: Dictionary = entry.get("trigger", {})
			var centre: Array = trigger.get("center", [])
			if centre.size() != 3:
				continue
			out.append({
				"id": String(entry.get("id", "")),
				"to_map": String(entry.get("to_map", "")),
				"to_spawn": String(entry.get("to_spawn", "default")),
				"label": String(entry.get("label", "")),
				"center": Vector3(float(centre[0]), float(centre[1]), float(centre[2])),
				"radius": float(trigger.get("radius", 2.0)),
				"y_min": float(trigger.get("y_min", -1000.0)),
				"y_max": float(trigger.get("y_max", 1000.0)),
			})
		if not out.is_empty():
			return out
	return PORTALS.get(map_id, [])

func _portal_contains(portal: Dictionary, point: Vector3) -> bool:
	if point.y < float(portal.get("y_min", -1000.0)) or point.y > float(portal.get("y_max", 1000.0)):
		return false
	var centre: Vector3 = portal.get("center", Vector3.ZERO)
	var dx := point.x - centre.x
	var dz := point.z - centre.z
	var radius := float(portal.get("radius", 0.0))
	return (dx * dx + dz * dz) <= radius * radius

func _portal_prompt(portal: Dictionary) -> String:
	var label := String(portal.get("label", "the destination"))
	if String(portal.get("to_map", "")) == MAP_INTERIOR:
		return "Enter %s" % label
	return "Travel to the %s" % label

func _loading_text(map_id: String) -> String:
	if map_id == MAP_INTERIOR:
		return "Entering Hogwarts Castle..."
	return "Returning to the Grounds..."

func _spawn_point(map_id: String, spawn_id: String) -> Vector3:
	var maps := _maps_script()
	if maps != null and bool(maps.call("map_exists", map_id)):
		var point: Vector3 = maps.call("spawn_point", map_id, spawn_id)
		if point != Vector3.ZERO:
			return point
	var table: Dictionary = SPAWN_POINTS.get(map_id, {})
	if table.has(spawn_id):
		return table[spawn_id]
	return table.get("default", Vector3(0, 0.5, 5))

## Floor-aware location label. The shared catalog carries no floor plan yet, so
## the interior's own floor table answers (castle_interior.gd::FLOORS); when the
## interior map is not loaded the level is derived from the same authored
## heights.
func floor_display(map_id: String, y: float) -> String:
	if map_id != MAP_INTERIOR:
		return "Hogwarts Grounds"
	if _interior != null and is_instance_valid(_interior) and _interior.has_method("floor_display"):
		return String(_interior.call("floor_display", y))
	var name := "Ground Floor"
	for level in [[212.0, "Second Floor"], [206.0, "First Floor"], [200.0, "Ground Floor"], [194.0, "Dungeon Level"]]:
		if y >= float(level[0]) - 0.6:
			name = String(level[1])
			break
	return "Hogwarts Castle - %s" % name

## The shared map catalog, when the Phase 8 sync has landed. Loaded by path so
## a build without maps.gd still runs.
func _maps_script() -> GDScript:
	if not ResourceLoader.exists("res://addons/hpmmo_sim/maps.gd"):
		return null
	return load("res://addons/hpmmo_sim/maps.gd") as GDScript

# --------------------------------------------------------------------- ui

func _build_ui() -> void:
	var layer := CanvasLayer.new()
	layer.name = "MapStatusUI"
	layer.layer = 20
	world.add_child(layer)

	_fade_rect = ColorRect.new()
	_fade_rect.name = "Fade"
	_fade_rect.color = Color(0.02, 0.02, 0.04, 0.0)
	_fade_rect.anchor_right = 1.0
	_fade_rect.anchor_bottom = 1.0
	_fade_rect.mouse_filter = Control.MOUSE_FILTER_IGNORE
	layer.add_child(_fade_rect)

	_loading_label = _make_label("Loading", 26, Color(0.95, 0.9, 0.75))
	_loading_label.anchor_right = 1.0
	_loading_label.anchor_bottom = 1.0
	_loading_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_loading_label.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	_loading_label.visible = false
	layer.add_child(_loading_label)

	_location_label = _make_label("Location", 22, Color(1.0, 0.9, 0.62))
	_location_label.anchor_right = 1.0
	_location_label.offset_top = 8.0
	_location_label.offset_bottom = 40.0
	_location_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	layer.add_child(_location_label)

	_prompt_label = _make_label("Prompt", 20, Color(0.92, 0.96, 1.0))
	_prompt_label.anchor_top = 1.0
	_prompt_label.anchor_right = 1.0
	_prompt_label.anchor_bottom = 1.0
	_prompt_label.offset_top = -168.0
	_prompt_label.offset_bottom = -136.0
	_prompt_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	layer.add_child(_prompt_label)

	_notice_label = _make_label("Notice", 20, Color(1.0, 0.78, 0.4))
	_notice_label.anchor_top = 1.0
	_notice_label.anchor_right = 1.0
	_notice_label.anchor_bottom = 1.0
	_notice_label.offset_top = -208.0
	_notice_label.offset_bottom = -176.0
	_notice_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	layer.add_child(_notice_label)

func _make_label(title: String, size: int, color: Color) -> Label:
	var label := Label.new()
	label.name = title
	label.mouse_filter = Control.MOUSE_FILTER_IGNORE
	label.add_theme_font_size_override("font_size", size)
	label.add_theme_color_override("font_color", color)
	label.add_theme_color_override("font_outline_color", Color(0, 0, 0, 1))
	label.add_theme_constant_override("outline_size", 6)
	return label

func _update_labels() -> void:
	if _location_label == null:
		return
	var y: float = local_player.global_position.y if is_instance_valid(local_player) else 0.0
	var text := floor_display(current_map, y)
	# The broom landing area is the one piece of grounds furniture the player is
	# asked to use, so it is announced when they stand on it.
	if current_map == MAP_GROUNDS and is_instance_valid(local_player):
		var flat := Vector2(local_player.global_position.x - LANDING_PAD_CENTRE.x,
			local_player.global_position.z - LANDING_PAD_CENTRE.z)
		if flat.length() <= LANDING_PAD_RADIUS and absf(y) < 4.0:
			text += "   |   Broom landing pad"
	_location_label.text = text
	_prompt_label.text = _active_label
	_notice_label.text = _notice

func _feedback(text: String) -> void:
	_notice = text
	_notice_t = 4.0 if text != "" else 0.0
	if _notice_label != null:
		_notice_label.text = text

func _reason_text(reason: String) -> String:
	match reason:
		"no_flight":
			return "The broom cannot fly inside the castle - dismount on the landing pad first."
		"no_portal":
			return "There is no doorway here."
		"wrong_map":
			return "That door does not lead there."
		"map_unavailable":
			return "The destination map is unavailable."
		"map_full":
			return "The destination is full right now."
		"transfer_pending":
			return "A transfer is already in progress."
		"bad_transfer_token":
			return "The transfer expired; try the door again."
		"aborted":
			return "The transfer was cancelled."
		"range":
			return "Stand closer to the door."
		"transfer_expired":
			return "The transfer timed out; you are back at your last safe spot."
		_:
			return "Transfer refused (%s)." % reason if reason != "" else ""

# ------------------------------------------------------------- evidence

## One line per completed transfer, with the node/resource counts either side of
## it. The walkthrough scene reads this to prove old maps really go away.
func _record_transfer(map_id: String, spawn_id: String, token: int) -> void:
	var entry := {
		"map_id": map_id,
		"spawn_id": spawn_id,
		"token": token,
		"server_api": server_api,
		"nodes": Performance.get_monitor(Performance.OBJECT_NODE_COUNT),
		"orphans": Performance.get_monitor(Performance.OBJECT_ORPHAN_NODE_COUNT),
		"resources": Performance.get_monitor(Performance.OBJECT_RESOURCE_COUNT),
		"staticmethod": Performance.get_monitor(Performance.MEMORY_STATIC),
	}
	transfer_log.append(entry)
	print("[MapController] transfer -> %s (spawn %s, token %d) nodes=%d orphans=%d resources=%d" % [
		map_id, spawn_id, token, int(entry["nodes"]), int(entry["orphans"]), int(entry["resources"])])

func map_stats() -> Dictionary:
	return {
		"map": current_map,
		"nodes": Performance.get_monitor(Performance.OBJECT_NODE_COUNT),
		"orphans": Performance.get_monitor(Performance.OBJECT_ORPHAN_NODE_COUNT),
		"resources": Performance.get_monitor(Performance.OBJECT_RESOURCE_COUNT),
		"staticmethod": Performance.get_monitor(Performance.MEMORY_STATIC),
	}
