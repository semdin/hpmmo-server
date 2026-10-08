extends Node

## SimAuthority - the authoritative gameplay engine.
##
## OWNER: server repository (synced to the client as part of hpmmo_sim).
##
## The same script runs in three places:
##   * the dedicated world server (role DEDICATED) - production,
##   * a hosting player's process (role HOST)        - LAN / play-testing,
##   * the client itself in single-player (role OFFLINE) - so single-player and
##     online share one rules implementation instead of two that drift.
## In role CLIENT the node is inert: it applies what the server sends and
## decides nothing.
##
## Entity identity, spawn sampling, the sim clock, combat resolution, status
## effects, rewards, death/respawn and persistence all live here. Clients send
## intents; this engine answers.

signal chat(text: String)
signal notice(text: String, color: Color)
signal entity_replicating(record: Dictionary)      # presentation: create a view
signal entity_despawned(uid: int)
signal entity_moved(uid: int, pos: Vector3, rot_y: float, flags: int)
signal entity_health(uid: int, hp: int, max_hp: int, flags: int)
signal stats_changed(uid: int, stats: Dictionary)
signal cast_started(uid: int, cast_id: int, spell_id: String, aim: Vector3, release_tick: int)
signal cast_finished(cast_id: int, accepted: bool, reason: String)
## Answer to one client cast request, matched by the client's own sequence number
## so it can confirm or remove its predicted feedback.
signal cast_ack(cast_seq: int, cast_id: int, ok: bool, reason: String)
signal cast_released(cast_id: int, caster_uid: int, spell_id: String, origin: Vector3, dir: Vector3)
signal cast_landed(cast_id: int, caster_uid: int, spell_id: String, hits: Array)
signal entity_damaged(uid: int, amount: int, hp: int, spell_id: String, attacker_uid: int)
signal entity_died(uid: int, killer_uid: int)
signal entity_respawned(uid: int)
signal loot_spawned(uid: int, item_id: String, amount: int, pos: Vector3)
## encounter lifecycle: a boss telegraph opened/closed, and a pack that
## leashed home reset its encounter (its pending reward credit was cancelled).
signal mob_telegraph(uid: int, data: Dictionary)
signal mob_telegraph_end(uid: int)
signal encounter_reset(pack_id: int, reason: String)
signal loot_taken(uid: int, character_id: int, item_id: String, amount: int, collector_peer_id: int)
signal reward_granted(uid: int, character_id: int, exp: int, galleons: int, items: Array, op_id: String)
signal level_changed(uid: int, level: int)
signal player_joined(uid: int, character_id: int, peer_id: int)
signal player_left(uid: int, character_id: int)
## Maintenance lifecycle. The dedicated server's admin
## controller emits this locally; clients receive it from the network layer
## (SimNet.sim_maintenance_event) and re-emit it here, so game code has one
## signal to listen to in every role.
signal maintenance_event(state: String, reason: String, seconds_remaining: int)

## Map transfer lifecycle. The authority is the only process
## that grants, commits or expires a transfer; every signal names the peer so the
## network layer can answer exactly one client. The shapes are the contract the
## client's map controller is written against:
##   grant    -> the client loads the destination map (spawn from the catalog)
##   commit   -> ownership moved; the body is at `pos`
##   refused  -> nothing changed; `reason` is one of the REJECT_* strings
##   expired  -> the reservation timed out; the body is back at `pos`
signal transfer_granted(peer_id: int, token: int, map_id: String, spawn_id: String)
signal transfer_committed(peer_id: int, token: int, map_id: String, pos: Vector3, spawn_id: String)
signal transfer_refused(peer_id: int, reason: String)
signal transfer_expired(peer_id: int, token: int, map_id: String, pos: Vector3)
## The local body's map changed (or was first assigned, at join). Presentation
## loads/unloads the map scene and moves the body to the server-approved spot.
signal map_state(map_id: String, pos: Vector3, spawn_id: String)
signal map_changed(uid: int, map_id: String, pos: Vector3)

enum Role { OFFLINE, HOST, DEDICATED, CLIENT }

const HPProtocol = preload("res://addons/hpmmo_sim/protocol.gd")
const MOB_GROUPS := ["mobs"]

var role: int = Role.OFFLINE
var world: Node3D = null
var seed_value: int = 0
var rng := RandomNumberGenerator.new()

var sim_tick: int = 0
var entities: Dictionary = {}        # uid -> record
var by_node: Dictionary = {}         # instance_id -> uid
var players_by_peer: Dictionary = {} # peer_id -> uid
var players_by_character: Dictionary = {} # character_id -> uid

var _next_uid: int = 1
var _next_cast_id: int = 1
var _next_death_seq: int = 1
var _accumulator: float = 0.0
var _regen_accumulator_ms: int = 0
var _autosave_accumulator_ms: int = 0
var casts: Dictionary = {}           # cast_id -> cast record
var projectiles: Array = []          # data-only swept projectiles (authoritative)
var casts_by_node: Dictionary = {}   # instance_id -> cast_id (casting entity)

## Map transfer reservations: token -> reservation record.
## Nothing about a transfer is client-owned: the token references a server-side
## reservation that expires on the sim clock.
var transfers: Dictionary = {}
var _next_transfer_token: int = 1

## Optional map provider (a client-side map controller, or a server-side map
## host). When present it answers `ensure_map_built(map_id)`, so a transfer is
## only reserved for a destination whose scene really exists in this build.
var map_provider: Node = null

## Map the local body belongs to (role CLIENT / HOST / OFFLINE presentation).
var local_map: String = HPProtocol.DEFAULT_MAP
## Set by the network layer when the server assigns a map to this client's
## entity, before the world scene exists (menus load it afterwards).
var pending_map_state: Dictionary = {}

func local_map_id() -> String:
	return local_map

const TICK_MS := 1000 / HPProtocol.SIM_HZ
const AUTOSAVE_INTERVAL_MS := 30000
const REGEN_INTERVAL_MS := 200
const PERSISTENCE_PENDING := "pending"

## Optional persistence bridge (server/host roles only). Assigned by the server
## entry point; the engine degrades to in-memory play when it is absent.
var persistence: Node = null

## Maintenance gate. The dedicated world server's admin
## controller (addons/hpmmo_sim/admin.gd) assigns itself here. Every other role
## - clients, offline play, a LAN host - leaves it null, which makes each check
## below inert and costs one null comparison per call.
var maintenance: Node = null

func maintenance_state() -> String:
	if maintenance == null or not is_instance_valid(maintenance):
		return ""
	return String(maintenance.call("state_name"))

## True from SAVING until the world is ONLINE again: no input, no cast, no
## mount, no pickup, and no damage/reward resolution.
func mutations_frozen() -> bool:
	if maintenance == null or not is_instance_valid(maintenance):
		return false
	return bool(maintenance.call("is_frozen"))

## True in MAINTENANCE: the simulation clock does no work at all.
func simulation_paused() -> bool:
	if maintenance == null or not is_instance_valid(maintenance):
		return false
	return bool(maintenance.call("is_paused"))

## False from ANNOUNCING until the world is ONLINE again.
func joins_allowed() -> bool:
	if maintenance == null or not is_instance_valid(maintenance):
		return true
	return bool(maintenance.call("accepts_joins"))

## Client-side (and test) entry point for a maintenance notification.
func on_maintenance_event(state: String, reason: String, seconds_remaining: int) -> void:
	emit_signal("maintenance_event", state, reason, seconds_remaining)

## Called when the save barrier starts: bodies stop moving on their last intent
## instead of gliding on it, because no further input frames will be accepted.
func halt_player_motion() -> void:
	if not is_authority():
		return
	for peer_id in players_by_peer.keys():
		var record := player_record(int(peer_id))
		if record.is_empty():
			continue
		var intent: Dictionary = record.get("input", {})
		if intent.is_empty():
			continue
		intent["move"] = Vector2.ZERO
		intent["jump"] = false
		intent["descend"] = false
		touch(record)


# --------------------------------------------------------------- role & boot

func is_authority() -> bool:
	return role != Role.CLIENT

func configure(new_role: int, world_seed: int = 0) -> void:
	role = new_role
	if world_seed == 0:
		world_seed = int(Time.get_unix_time_from_system()) & 0x7fffffff
	seed_value = world_seed
	rng.seed = world_seed
	print("[Authority] role=%s seed=%d sim=%dHz protocol=%s" % [
		Role.keys()[role], seed_value, HPProtocol.SIM_HZ, HPProtocol.version_string()])

func sim_time_ms() -> int:
	return sim_tick * TICK_MS

func attach_world(node: Node3D) -> void:
	world = node

# ------------------------------------------------------------------- registry

func _make_uid() -> int:
	var uid := _next_uid
	_next_uid += 1
	return uid

func register(kind: int, node: Node3D, extra: Dictionary = {}) -> int:
	if node == null or not is_instance_valid(node):
		return 0
	var uid := _make_uid()
	var position: Vector3 = node.global_position
	var map_id := String(extra.get("map_id", ""))
	if map_id == "":
		map_id = HPMaps.map_for_point(position)
	var record := {
		"uid": uid,
		"kind": kind,
		"node": node,
		"map_id": map_id,
		"zone_id": HPRules.zone_id_for_map(map_id, position),
		"pack_id": 0,
		"revision": 1,
		"damage_log": [],
		"dead": false,
	}
	record.merge(extra, true)
	entities[uid] = record
	by_node[node.get_instance_id()] = uid
	node.set_meta("sim_uid", uid)
	return uid

func unregister_node(node: Node3D) -> void:
	if node == null or not is_instance_valid(node):
		return
	var iid := node.get_instance_id()
	if not by_node.has(iid):
		return
	var uid: int = by_node[iid]
	by_node.erase(iid)
	entities.erase(uid)
	casts_by_node.erase(iid)
	emit_signal("entity_despawned", uid)

func record_for(node: Node) -> Dictionary:
	if node == null or not is_instance_valid(node):
		return {}
	var uid = node.get_meta("sim_uid", 0)
	if uid == 0 or not entities.has(uid):
		return {}
	return entities[uid]

func record_by_uid(uid: int) -> Dictionary:
	return entities.get(uid, {})

func touch(record: Dictionary) -> void:
	record["revision"] = int(record.get("revision", 0)) + 1

func _kind(node: Node) -> int:
	if node.is_in_group("players"):
		return HPProtocol.Kind.PLAYER
	if node.is_in_group("mobs"):
		return HPProtocol.Kind.MOB
	if node.is_in_group("dummies"):
		return HPProtocol.Kind.DUMMY
	if node.is_in_group("monoliths"):
		return HPProtocol.Kind.MONOLITH
	if node.is_in_group("loot"):
		return HPProtocol.Kind.LOOT
	return HPProtocol.Kind.NPC

# ------------------------------------------------------------------ lifecycle

func register_player(node: Node3D, character_id: int, peer_id: int, account_id: int = 0) -> int:
	var start_map := HPMaps.map_for_point(node.global_position)
	var uid := register(HPProtocol.Kind.PLAYER, node, {
		"character_id": character_id,
		"account_id": account_id,
		"peer_id": peer_id,
		"name": String(node.get("player_name")),
		"house": String(node.get("house")),
		"hp": int(node.get("current_hp")),
		"max_hp": int(node.get("max_hp")),
		"mana": int(node.get("current_mana")),
		"max_mana": int(node.get("max_mana")),
		"exp": int(node.get("current_exp")),
		"level": int(node.get("level")),
		"galleons": int(node.get("galleons")),
		"wand_tier": int(node.get("wand_tier")),
		"mounted": false,
		"ward_until_tick": 0,
		"stunned_until_tick": 0,
		"cast_lock_until_tick": 0,
		"cooldowns": {},
		"combo_index": 0,
		"combo_until_tick": 0,
		"cast_id": 0,
		"queued_spell": "",
		"queued_until_tick": 0,
		"last_cast_seq": -1,
		"map_id": start_map,
		## Last server-approved, grounded location. A transfer that never
		## completes returns the body here instead of stranding it between maps.
		"safe_spawn_map": start_map,
		"safe_spawn": node.global_position,
		"pending_transfer": 0,
		"transfer_count": 0,
		"input": {"move": Vector2.ZERO, "yaw": 0.0, "jump": false, "descend": false, "seq": -1},
	})
	refresh_equipment(entities[uid])
	players_by_peer[peer_id] = uid
	if character_id > 0:
		players_by_character[character_id] = uid
	# A player body the authority simulates is driven by that player's network
	# intent; the local body in offline/host play keeps reading its own keyboard.
	if node.get("is_local_player") != true:
		var player_record: Dictionary = entities[uid]
		node.set("sim_server_controlled", true)
		node.set("sim_input", player_record["input"])
	emit_signal("player_joined", uid, character_id, peer_id)
	return uid

## Bind a character sheet to a player that joined without one (the character-bind fix).
## The network layer has already proven the character belongs to this session's
## account through the service, so this only decides whether the body may take
## it: one character per session, one live session per character, and the saved
## position decides the map. The record the simulation and the autosave read is
## brought in step with the sheet, so from here the disconnect save and the
## periodic autosave write real progress. Returns "" on success, or a refusal
## reason from HPProtocol's BIND_* set.
func apply_character_binding(record: Dictionary, character: Dictionary) -> String:
	var character_id := int(character.get("id", 0))
	if record.is_empty():
		return HPProtocol.BIND_NOT_JOINED
	if character_id <= 0:
		return HPProtocol.BIND_NOT_FOUND
	var current := int(record.get("character_id", 0))
	if current == character_id:
		return ""                          # idempotent: already this character
	if current > 0:
		return HPProtocol.BIND_ALREADY     # a session does not change character
	if players_by_character.has(character_id):
		return HPProtocol.BIND_IN_SESSION  # another live session owns the body
	var node = record.get("node")
	if node == null or not is_instance_valid(node):
		return HPProtocol.BIND_NO_BODY
	# Where the character logged out is where it wakes: the sheet's map and
	# position win, and a map that is not resident yet is built before the body
	# rests on it (the server map host builds indoor collision only).
	var pos: Vector3 = (node as Node3D).global_position
	if character.get("pos") is Array and (character["pos"] as Array).size() == 3:
		var saved: Array = character["pos"]
		pos = Vector3(float(saved[0]), float(saved[1]), float(saved[2]))
	var saved_map := String(character.get("map_id", ""))
	var map_id := saved_map if HPMaps.map_exists(saved_map) else HPMaps.map_for_point(pos)
	map_provider_ready(map_id)
	pos = HPMaps.valid_position(map_id, pos)
	# The body's identity is the CHARACTER's, not the account username the
	# unbound body joined under: the nameplate, chat and roster all read these.
	if character.get("name") is String and String(character["name"]) != "":
		node.set("player_name", String(character["name"]))
		record["name"] = String(character["name"])
	if character.get("house") is String and String(character["house"]) != "":
		node.set("house", String(character["house"]))
		record["house"] = String(character["house"])
	node.call("restore_character", character)
	refresh_equipment(record)
	(node as Node3D).global_position = pos
	if "velocity" in node:
		node.set("velocity", Vector3.ZERO)
	# The record the sim reads: identity, position/map, and every stat the save
	# payload and the HUD are built from.
	record["character_id"] = character_id
	record["map_id"] = map_id
	record["zone_id"] = HPRules.zone_id_for_map(map_id, pos)
	record["safe_spawn_map"] = map_id
	record["safe_spawn"] = pos
	record["level"] = int(node.get("level"))
	record["exp"] = int(node.get("current_exp"))
	record["max_hp"] = int(node.get("max_hp"))
	record["hp"] = int(node.get("current_hp"))
	record["max_mana"] = int(node.get("max_mana"))
	record["mana"] = int(node.get("current_mana"))
	record["galleons"] = int(node.get("galleons"))
	record["wand_tier"] = int(node.get("wand_tier"))
	players_by_character[character_id] = int(record.get("uid", 0))
	touch(record)
	_push_stats(record)
	return ""

func register_mob(node: Node3D, pack_id: int, zone_id: String) -> int:
	var uid := register(HPProtocol.Kind.MOB, node, {
		"pack_id": pack_id,
		"zone_id": zone_id,
		"variant": HPProtocol.mob_variant(node.scene_file_path),
		"hp": int(node.get("current_hp")),
		"max_hp": int(node.get("max_hp")),
		"is_boss": node.get("is_boss") == true,
		"weak_to_fire": node.get("weak_to_fire") == true,
		"exp_reward": int(node.get("exp_reward")),
		"level": int(node.get("level")),
		"name": String(node.get("mob_name")),
		"burn_until_tick": 0,
		"burn_next_tick": 0,
		"burn_source_uid": 0,
		"weak_until_tick": 0,
		"stun_until_tick": 0,
	})
	return uid

## A mob came back (pack respawn, summoned lifecycle, monolith wave): clear its
## status effects and restore the record so replication reflects the new life.
func refresh_mob(node: Node3D) -> void:
	var record := record_for(node)
	if record.is_empty():
		return
	record["hp"] = int(node.get("current_hp") if node.get("current_hp") != null else 0)
	record["max_hp"] = int(node.get("max_hp") if node.get("max_hp") != null else 0)
	record["is_boss"] = node.get("is_boss") == true
	record["weak_to_fire"] = node.get("weak_to_fire") == true
	if node.get("exp_reward") != null:
		record["exp_reward"] = int(node.get("exp_reward"))
	if node.get("level") != null:
		record["level"] = int(node.get("level"))
	if node.get("mob_name") != null:
		record["name"] = String(node.get("mob_name"))
	record["dead"] = false
	record["burn_until_tick"] = 0
	record["burn_next_tick"] = 0
	record["stun_until_tick"] = 0
	record["weak_until_tick"] = 0
	# A respawned mob must not keep a stale boss telegraph (Creature pass:
	# pooling/resets clear every trace of the previous life).
	record.erase("telegraph")
	record["is_enraged"] = bool(node.get("is_enraged")) if node.get("is_enraged") != null else false
	record["damage_log"] = []
	touch(record)

# ------------------------------------------- encounter state & timing

## Mob AI state, mirrored into the snapshot's state byte so a client drives its
## presentation (anticipation pose, recovery, chase) from the authority's state
## instead of guessing. Values are HPProtocol.MobState.
func set_mob_state(node: Node3D, value: int) -> void:
	var record := record_for(node)
	if record.is_empty():
		return
	if int(record.get("state", 0)) == value:
		return
	record["state"] = value
	touch(record)

## Publishes a boss telegraph: start tick, release tick and the shape of the
## area. Clients render the warning from this data; the damage is applied by the
## authority when ITS OWN tick reaches `release_tick` (see mob_base), so the
## visible warning and the hit cannot disagree - the server owns the timing.
func begin_mob_telegraph(node: Node3D, pattern: Dictionary, release_tick: int,
		direction: Vector3, center: Vector3) -> void:
	var record := record_for(node)
	if record.is_empty():
		return
	var forward := direction
	forward.y = 0.0
	if forward.length_squared() < 0.0001:
		forward = Vector3.FORWARD
	var recovery_ticks := int(ceil(float(pattern.get("recovery", 0.0)) * float(HPProtocol.SIM_HZ)))
	var data := {
		"kind": String(pattern.get("kind", "area")),
		"clip": String(pattern.get("clip", "")),
		"start_tick": sim_tick,
		"release_tick": release_tick,
		"recovery_until_tick": release_tick + recovery_ticks,
		"center": center,
		"dir": forward.normalized(),
		"radius": float(pattern.get("radius", 0.0)),
		"range": float(pattern.get("range", 0.0)),
		"half_angle": float(pattern.get("half_angle", 0.0)),
		"pack_id": int(record.get("pack_id", 0)),
	}
	record["telegraph"] = data
	touch(record)
	emit_signal("mob_telegraph", int(record["uid"]), data)

func end_mob_telegraph(node: Node3D) -> void:
	var record := record_for(node)
	if record.is_empty() or not record.has("telegraph"):
		return
	record.erase("telegraph")
	touch(record)
	emit_signal("mob_telegraph_end", int(record["uid"]))

func mob_telegraph_for(node: Node) -> Dictionary:
	return record_for(node).get("telegraph", {})

## Leash break / every valid target lost: the pack goes home and the encounter
## resets. Reward credit its members accumulated is cancelled HERE, so a pull
## that never ended in a kill cannot be paid out by a later kill, and any
## lingering telegraph, burn or stun is cleared with it.
func reset_encounter(pack_id: int, reason: String) -> void:
	if pack_id <= 0:
		return
	var affected: Array = []
	for uid in entities.keys():
		var record: Dictionary = entities[uid]
		if int(record.get("kind", 0)) != HPProtocol.Kind.MOB:
			continue
		if int(record.get("pack_id", 0)) != pack_id or bool(record.get("dead", false)):
			continue
		record["damage_log"] = []
		record["burn_until_tick"] = 0
		record["burn_next_tick"] = 0
		record["burn_source_uid"] = 0
		record["stun_until_tick"] = 0
		record["weak_until_tick"] = 0
		record["is_enraged"] = false
		record.erase("telegraph")
		touch(record)
		affected.append(uid)
	if affected.is_empty():
		return
	print("[Authority] encounter %d reset (%s): reward credit cancelled for %d mob(s)" % [
		pack_id, reason, affected.size()])
	emit_signal("encounter_reset", pack_id, reason)

## Training dummies never die; at zero HP they snap back to full so every client
## sees the same bar.
func reset_dummy(node: Node3D) -> void:
	var record := record_for(node)
	if record.is_empty():
		return
	record["hp"] = int(record.get("max_hp", 0))
	node.set("current_hp", int(record.get("max_hp", 0)))
	touch(record)
	emit_signal("entity_health", int(record["uid"]), int(record["hp"]), int(record["max_hp"]), flags_for(record))

func register_loot(node: Node3D, item_id: String, amount: int) -> int:
	var uid := register(HPProtocol.Kind.LOOT, node, {"item_id": item_id, "amount": amount})
	emit_signal("loot_spawned", uid, item_id, amount, node.global_position)
	return uid

func remove_player(peer_id: int) -> void:
	if not players_by_peer.has(peer_id):
		return
	var uid: int = players_by_peer[peer_id]
	var record: Dictionary = entities.get(uid, {})
	players_by_peer.erase(peer_id)
	if not record.is_empty():
		if record.has("character_id"):
			players_by_character.erase(int(record["character_id"]))
		if int(record.get("pending_transfer", 0)) != 0:
			# A disconnect during a transfer: drop the reservation and put the
			# body back on its last valid safe spot before saving, so a relog can
			# never resume "between maps" and never spawn a duplicate elsewhere.
			cancel_transfer_for_uid(uid, "disconnect")
			_settle_to_safe_spawn(record)
			touch(record)
		# [staircase - ADDITIVE hook] world objects (the magical staircase)
		# resolve a body that is leaving mid-travel to a valid landing before the
		# final save, so a relog never resumes between floors. A no-op while the
		# group is empty.
		for resolver in get_tree().get_nodes_in_group(HPStaircase.GROUP_RESOLVER):
			if resolver.has_method("resolve_departing_player"):
				resolver.call("resolve_departing_player", record, "disconnect")
		var node = record.get("node")
		if persistence != null:
			persistence.save_player(record)   # last save on the way out
		unregister_node(node if node is Node3D else null)
		if node != null and is_instance_valid(node):
			# Free the body: otherwise it stays in the world as a ghost that
			# mobs keep chasing and that nothing can ever despawn.
			node.queue_free()
		emit_signal("player_left", uid, int(record.get("character_id", 0)))

func player_record(peer_id: int) -> Dictionary:
	if not players_by_peer.has(peer_id):
		return {}
	return entities.get(players_by_peer[peer_id], {})

# -------------------------------------------------------------- intent intake

## Movement input. The authority never accepts a claimed position - it stores the
## input vector and integrates it itself, so a forged teleport is not expressible.
func submit_input(peer_id: int, seq: int, move: Vector2, yaw: float, jump: bool, descend: bool) -> void:
	if not is_authority():
		return
	if mutations_frozen():
		return   # the save barrier owns the world from here on
	var record := player_record(peer_id)
	if record.is_empty() or bool(record.get("dead", false)):
		return
	if int(record.get("pending_transfer", 0)) != 0:
		return   # the body is owned by the transfer until it completes or expires
	var intent: Dictionary = record["input"]
	if seq < int(intent.get("seq", -1)):
		return
	# Mutated in place: the node being simulated holds this exact dictionary, so
	# replacing it would silently detach the body from its input.
	intent["move"] = HPRules.sanitize_input_vector(move)
	intent["yaw"] = yaw if is_finite(yaw) else 0.0
	intent["jump"] = jump
	intent["descend"] = descend
	intent["seq"] = seq
	touch(record)

## Cast request. Returns {ok, reason, cast_id}. Rejections are explicit so the
## client can drop its predicted feedback.
func request_cast(peer_id: int, spell_id: String, aim: Vector3, cast_seq: int) -> Dictionary:
	if not is_authority():
		return HPProtocol.reject(HPProtocol.REJECT_STATE)
	if mutations_frozen():
		return HPProtocol.reject(HPProtocol.REJECT_STATE)
	var record := player_record(peer_id)
	if record.is_empty():
		return HPProtocol.reject(HPProtocol.REJECT_STATE)
	return cast_for_record(record, spell_id, aim, cast_seq)

func cast_for_record(record: Dictionary, spell_id: String, aim: Vector3, cast_seq: int) -> Dictionary:
	if mutations_frozen():
		# Frozen: no new cast may start, no mana may be spent, no cooldown set.
		return HPProtocol.reject(HPProtocol.REJECT_STATE)
	if bool(record.get("dead", false)):
		return _reject_cast(record, cast_seq, HPProtocol.REJECT_DEAD)
	if int(record.get("pending_transfer", 0)) != 0:
		return _reject_cast(record, cast_seq, HPProtocol.REJECT_TRANSFER_PENDING)
	var data := HPRules.spell(spell_id)
	if data.is_empty():
		return _reject_cast(record, cast_seq, HPProtocol.REJECT_UNKNOWN_SPELL)
	var node: Node3D = record.get("node")
	if node == null or not is_instance_valid(node):
		return _reject_cast(record, cast_seq, HPProtocol.REJECT_STATE)
	if spell_id != "protego" and not node.equipment.has("main_hand"):
		return _reject_cast(record, cast_seq, "no_wand")
	if bool(record.get("mounted", false)) and spell_id != "protego":
		return _reject_cast(record, cast_seq, HPProtocol.REJECT_MOUNTED)
	if sim_tick < int(record.get("stunned_until_tick", 0)):
		return _reject_cast(record, cast_seq, HPProtocol.REJECT_STATE)

	# Bounded input buffer: a request inside the queue window is remembered and
	# replayed the moment recovery ends. Repeats stop spending mana because the
	# queue is a single slot keyed by cast_seq.
	var ready_tick := maxi(int(record.get("cast_lock_until_tick", 0)),
		int((record["cooldowns"] as Dictionary).get(spell_id, 0)))
	var remaining_ms := (ready_tick - sim_tick) * TICK_MS
	if remaining_ms > 0:
		if remaining_ms <= HPProtocol.CAST_QUEUE_MS and cast_seq != int(record.get("last_cast_seq", -1)):
			record["queued_spell"] = spell_id
			record["queued_until_tick"] = sim_tick + int(ceil(float(HPProtocol.CAST_QUEUE_MS) / TICK_MS))
			record["queued_aim"] = aim
			record["queued_seq"] = cast_seq
			return {"ok": true, "reason": "queued", "cast_id": 0}
		return _reject_cast(record, cast_seq, HPProtocol.REJECT_COOLDOWN)

	var cost := int(data.get("mana_cost", 0))
	if int(record.get("mana", 0)) < cost:
		return _reject_cast(record, cast_seq, HPProtocol.REJECT_NO_MANA)

	# Protection is NOT decided here: a caster inside a protected volume may still
	# cast (training dummies stay practiceable, and the core rule is enforced
	# per victim in `can_damage` at resolution time). Deciding it at cast time
	# would forbid attacking the courtyard dummies.

	record["mana"] = int(record.get("mana", 0)) - cost
	record["last_cast_seq"] = cast_seq
	record["queued_spell"] = ""
	var combo_mult := 1.0
	if spell_id == "basic_cast":
		combo_mult = _advance_combo(record)
	var cast_id := _begin_cast(record, spell_id, aim, combo_mult)
	_push_stats(record)
	return {"ok": true, "reason": HPProtocol.REJECT_OK, "cast_id": cast_id}

func _reject_cast(record: Dictionary, cast_seq: int, reason: String) -> Dictionary:
	record["last_cast_seq"] = cast_seq
	return {"ok": false, "reason": reason, "cast_id": 0}

func _advance_combo(record: Dictionary) -> float:
	var multipliers: Array = HPRules.combo_multipliers("basic_cast")
	var window_ticks := int(ceil(HPRules.combo_window("basic_cast") * HPProtocol.SIM_HZ))
	if sim_tick > int(record.get("combo_until_tick", 0)):
		record["combo_index"] = 0
	var index := int(record.get("combo_index", 0)) % maxi(1, multipliers.size())
	record["combo_index"] = (index + 1) % maxi(1, multipliers.size())
	record["combo_until_tick"] = sim_tick + window_ticks
	return float(multipliers[index])

func _begin_cast(record: Dictionary, spell_id: String, aim: Vector3, combo_mult: float) -> int:
	var node: Node3D = record["node"]
	var cast_id := _next_cast_id
	_next_cast_id += 1
	var lock := HPRules.cast_lock(spell_id)
	var windup_ticks := maxi(1, int(round(lock * 0.5 * HPProtocol.SIM_HZ)))
	var recovery_ticks := maxi(1, int(ceil(lock * HPProtocol.SIM_HZ)) - windup_ticks)
	var origin: Vector3 = node.global_position + Vector3(0, 1.2, 0)
	var dir := (aim - origin)
	if dir.length_squared() < 0.0001:
		dir = Vector3(0, 0, 1)
	dir = dir.normalized()
	var cast := {
		"damage": int(HPRules.spell_damage(spell_id, int(record.get("wand_tier", 0)), String(record.get("house", "")), combo_mult) * float(record.get("weapon_multiplier", 1.0))),
		"cast_id": cast_id,
		"caster_uid": record["uid"],
		"spell_id": spell_id,
		"state": HPProtocol.CastState.WINDUP,
		"start_tick": sim_tick,
		"release_tick": sim_tick + windup_ticks,
		"end_tick": sim_tick + windup_ticks + recovery_ticks,
		"origin": origin,
		"dir": dir,
		"aim": aim,
		"combo_mult": combo_mult,
	}
	casts[cast_id] = cast
	record["cast_id"] = cast_id
	record["cast_lock_until_tick"] = cast["end_tick"]
	record["cooldowns"][spell_id] = sim_tick + int(ceil(HPRules.cooldown_for(spell_id, String(record.get("house", ""))) * HPProtocol.SIM_HZ))
	casts_by_node[node.get_instance_id()] = cast_id
	# Face the cast direction immediately, matching the client's aim behaviour.
	emit_signal("cast_started", int(record["uid"]), cast_id, spell_id, aim, int(cast["release_tick"]))
	return cast_id

func submit_mount(peer_id: int, mounted: bool) -> Dictionary:
	if not is_authority():
		return HPProtocol.reject(HPProtocol.REJECT_STATE)
	if mutations_frozen():
		return HPProtocol.reject(HPProtocol.REJECT_STATE)
	var record := player_record(peer_id)
	if record.is_empty():
		return HPProtocol.reject(HPProtocol.REJECT_STATE)
	if bool(record.get("dead", false)):
		return HPProtocol.reject(HPProtocol.REJECT_DEAD)
	if int(record.get("pending_transfer", 0)) != 0:
		return HPProtocol.reject(HPProtocol.REJECT_TRANSFER_PENDING)
	if int(record.get("cast_id", 0)) != 0:
		return HPProtocol.reject(HPProtocol.REJECT_STATE)
	var node: Node3D = record.get("node")
	if node == null or not is_instance_valid(node):
		return HPProtocol.reject(HPProtocol.REJECT_STATE)
	if mounted and not node.equipment.has("broom"):
		return HPProtocol.reject("no_broom")
	if mounted:
		# Broom flight is prohibited inside the castle slice.
		# The authority decides it from the map catalog: a client's own check is
		# presentation, never the rule.
		if not HPMaps.flight_allowed(String(record.get("map_id", HPProtocol.DEFAULT_MAP))):
			return HPProtocol.reject(HPProtocol.REJECT_NO_FLIGHT)
		# Only from the ground: the flight rule is a rule, not a client courtesy.
		if node.has_method("is_on_floor") and not node.is_on_floor():
			return HPProtocol.reject(HPProtocol.REJECT_STATE)
	elif node.has_method("can_dismount_safely") and not node.can_dismount_safely():
		return HPProtocol.reject(HPProtocol.REJECT_STATE)
	record["mounted"] = mounted
	touch(record)
	_push_stats(record)
	return HPProtocol.accept()

func submit_respawn(peer_id: int) -> Dictionary:
	if not is_authority():
		return HPProtocol.reject(HPProtocol.REJECT_STATE)
	if mutations_frozen():
		return HPProtocol.reject(HPProtocol.REJECT_STATE)
	var record := player_record(peer_id)
	if record.is_empty() or not bool(record.get("dead", false)):
		return HPProtocol.reject(HPProtocol.REJECT_STATE)
	_respawn_player(record)
	return HPProtocol.accept()

# ------------------------------------------------------------- map transfer
##
## Server-authorized map transfer. The sequence is fixed:
##
##   request -> validate -> reserve destination -> mark transfer pending
##   grant   -> the client loads the destination map
##   ready   -> transfer entity ownership -> spawn from a server-approved spot
##
## Nothing here is a client-side teleport: until the readiness acknowledgement
## arrives the entity keeps its old map, position and collision, no input is
## accepted, and every failure path (refusal, expiry, disconnect, death) leaves
## the character at a valid location with no duplicate entity.

func map_id_for_uid(uid: int) -> String:
	return String(entities.get(uid, {}).get("map_id", ""))

func map_id_of_peer(peer_id: int) -> String:
	var record := player_record(peer_id)
	if record.is_empty():
		return ""
	return String(record.get("map_id", ""))

func players_on_map(map_id: String) -> int:
	var count := 0
	for uid in entities.keys():
		var record: Dictionary = entities[uid]
		if int(record.get("kind", 0)) == HPProtocol.Kind.PLAYER \
				and String(record.get("map_id", "")) == map_id:
			count += 1
	return count

## Is the destination buildable in THIS process? The catalog is the baseline;
## a map provider (a map controller / server-side map host) can additionally
## answer for a scene that has not shipped yet, so a transfer is never reserved
## into empty space.
func map_provider_ready(map_id: String) -> bool:
	if not HPMaps.map_exists(map_id) or not HPMaps.map_available(map_id):
		return false
	if map_provider != null and is_instance_valid(map_provider) \
			and map_provider.has_method("ensure_map_built"):
		return bool(map_provider.call("ensure_map_built", map_id))
	return true

## A client's transfer request. `portal_id` names the doorway the client is
## standing at; `to_map` is the destination the client *believes* it leads to -
## checked against the catalog, never trusted. Everything else (spawn, token,
## expiry, whether the body moves at all) is decided here.
func request_transfer(peer_id: int, portal_id: String, to_map: String = "") -> Dictionary:
	if not is_authority():
		return HPProtocol.reject(HPProtocol.REJECT_STATE)
	if mutations_frozen():
		return HPProtocol.reject(HPProtocol.REJECT_STATE)
	var record := player_record(peer_id)
	if record.is_empty():
		return HPProtocol.reject(HPProtocol.REJECT_STATE)
	# One reservation at a time: a repeated request must not stack tokens.
	if int(record.get("pending_transfer", 0)) != 0:
		return _refuse_transfer(peer_id, HPProtocol.REJECT_TRANSFER_PENDING)
	# A dead or incapacitated body does not walk through doors.
	if bool(record.get("dead", false)):
		return _refuse_transfer(peer_id, HPProtocol.REJECT_DEAD)
	var from_map := String(record.get("map_id", HPProtocol.DEFAULT_MAP))
	var portal := HPMaps.portal(portal_id)
	if portal.is_empty() or String(portal.get("map_id", "")) != from_map:
		return _refuse_transfer(peer_id, HPProtocol.REJECT_NO_PORTAL)
	var destination := to_map_of(portal)
	if to_map != "" and to_map != destination:
		return _refuse_transfer(peer_id, HPProtocol.REJECT_WRONG_MAP)
	var node: Node3D = record.get("node")
	if node == null or not is_instance_valid(node):
		return _refuse_transfer(peer_id, HPProtocol.REJECT_STATE)
	# The body must actually stand at the portal it names: a request from
	# anywhere in the world is not a transfer. The authority checks its OWN
	# position, so a client cannot claim to be at the door.
	if not HPMaps.portal_contains(portal, node.global_position):
		return _refuse_transfer(peer_id, HPProtocol.REJECT_RANGE)
	# Broom flight is prohibited inside the initial castle slice: the authority
	# refuses the mounted entry and reports why (the client shows the notice).
	if bool(record.get("mounted", false)) and not HPMaps.flight_allowed(destination):
		return _refuse_transfer(peer_id, HPProtocol.REJECT_NO_FLIGHT)
	if destination == from_map or not map_provider_ready(destination):
		return _refuse_transfer(peer_id, HPProtocol.REJECT_MAP_UNAVAILABLE)
	var spawn_id := String(portal.get("to_spawn", "default"))
	if not HPMaps.has_spawn_point(destination, spawn_id):
		return _refuse_transfer(peer_id, HPProtocol.REJECT_MAP_UNAVAILABLE)
	if players_on_map(destination) >= HPMaps.capacity(destination):
		return _refuse_transfer(peer_id, HPProtocol.REJECT_MAP_FULL)

	# --- reserve the destination spawn
	var token := _next_transfer_token
	_next_transfer_token += 1
	var approval: Vector3 = HPMaps.spawn_point(destination, spawn_id)
	transfers[token] = {
		"uid": int(record["uid"]),
		"peer_id": peer_id,
		"from_map": from_map,
		"to_map": destination,
		"spawn_id": spawn_id,
		"pos": approval,
		"created_tick": sim_tick,
		"expires_tick": sim_tick + maxi(1, int(ceil(float(HPProtocol.transfer_timeout_ms()) / TICK_MS))),
	}
	# --- mark the transfer pending: no input, no cast, no mount, no pickup until
	# it completes or expires. Any cast in progress is cancelled (the combat
	# state machine's map-transfer transition).
	record["pending_transfer"] = token
	interrupt_cast(record)
	var intent: Dictionary = record.get("input", {})
	intent["move"] = Vector2.ZERO
	intent["jump"] = false
	intent["descend"] = false
	touch(record)
	emit_signal("transfer_granted", peer_id, token, destination, spawn_id)
	print("[Authority] transfer %d granted: peer %d %s -> %s (spawn %s)" % [
		token, peer_id, from_map, destination, spawn_id])
	return {"ok": true, "reason": HPProtocol.REJECT_OK, "token": token, "map_id": destination,
		"spawn_id": spawn_id, "pos": approval}

## The client finished loading the destination map. Ownership moves HERE and
## nowhere else: this is the only place `map_id` changes for a player.
func transfer_ready(peer_id: int, token: int) -> Dictionary:
	if not is_authority():
		return HPProtocol.reject(HPProtocol.REJECT_STATE)
	var record := player_record(peer_id)
	if record.is_empty():
		return _refuse_transfer(peer_id, HPProtocol.REJECT_STATE)
	if not transfers.has(token):
		return _refuse_transfer(peer_id, HPProtocol.REJECT_TRANSFER_TOKEN)
	var reservation: Dictionary = transfers[token]
	if int(reservation.get("uid", 0)) != int(record.get("uid", 0)) \
			or int(record.get("pending_transfer", 0)) != token:
		return _refuse_transfer(peer_id, HPProtocol.REJECT_TRANSFER_TOKEN)
	if sim_tick > int(reservation.get("expires_tick", 0)):
		_expire_transfer(token, "timeout")
		return _refuse_transfer(peer_id, HPProtocol.REJECT_TRANSFER_TOKEN)
	if mutations_frozen():
		# The save barrier owns the world: keep the reservation pending and
		# refuse the acknowledgement rather than moving a body mid-save.
		return _refuse_transfer(peer_id, HPProtocol.REJECT_STATE)
	_commit_transfer(record, reservation, token)
	transfers.erase(token)
	return {"ok": true, "reason": HPProtocol.REJECT_OK, "map_id": String(reservation["to_map"]),
		"spawn_id": String(reservation["spawn_id"]), "pos": reservation["pos"]}

func _commit_transfer(record: Dictionary, reservation: Dictionary, token: int) -> void:
	var node: Node3D = record.get("node")
	var spawn_pos: Vector3 = reservation["pos"]
	record["map_id"] = String(reservation["to_map"])
	record["pending_transfer"] = 0
	record["transfer_count"] = int(record.get("transfer_count", 0)) + 1
	record["safe_spawn_map"] = String(reservation["to_map"])
	record["safe_spawn"] = spawn_pos
	if node != null and is_instance_valid(node):
		node.global_position = spawn_pos
		node.set("velocity", Vector3.ZERO)
	touch(record)
	emit_signal("transfer_committed", int(reservation["peer_id"]), token,
		String(reservation["to_map"]), spawn_pos, String(reservation["spawn_id"]))
	print("[Authority] transfer committed: uid=%d -> %s at (%.1f, %.1f, %.1f)" % [
		int(record["uid"]), reservation["to_map"], spawn_pos.x, spawn_pos.y, spawn_pos.z])

## The client could not load the destination (or the player cancelled): the
## reservation is released and the body returns to its last valid safe spawn.
func transfer_abort(peer_id: int, token: int) -> Dictionary:
	if not is_authority():
		return HPProtocol.reject(HPProtocol.REJECT_STATE)
	var record := player_record(peer_id)
	if record.is_empty():
		return HPProtocol.reject(HPProtocol.REJECT_STATE)
	var reservation: Dictionary = transfers.get(token, {})
	if reservation.is_empty() or int(record.get("pending_transfer", 0)) != token \
			or int(reservation.get("uid", 0)) != int(record.get("uid", 0)):
		return HPProtocol.reject(HPProtocol.REJECT_TRANSFER_TOKEN)
	transfers.erase(token)
	record["pending_transfer"] = 0
	_settle_to_safe_spawn(record)
	touch(record)
	emit_signal("transfer_refused", peer_id, HPProtocol.REJECT_ABORTED)
	return {"ok": true, "reason": HPProtocol.REJECT_ABORTED,
		"map_id": String(record.get("map_id", "")), "pos": record.get("safe_spawn", Vector3.ZERO)}

func _refuse_transfer(peer_id: int, reason: String) -> Dictionary:
	emit_signal("transfer_refused", peer_id, reason)
	return HPProtocol.reject(reason)

## Releases whatever reservation this entity holds (disconnect, death). The body
## itself is settled separately by the caller.
func cancel_transfer_for_uid(uid: int, reason: String) -> void:
	for token in transfers.keys():
		var reservation: Dictionary = transfers[token]
		if int(reservation.get("uid", 0)) != uid:
			continue
		transfers.erase(token)
		var record := record_by_uid(uid)
		if not record.is_empty() and int(record.get("pending_transfer", 0)) == int(token):
			record["pending_transfer"] = 0
			touch(record)
		print("[Authority] transfer token %d cancelled (%s): uid %d stays in %s" % [
			int(token), reason, uid, reservation.get("from_map", "")])

## A reservation that was never acknowledged expires on the sim clock (bounded):
## the character returns to its last valid safe spawn in the map it is really in
## - never left between maps, never duplicated.
func _expire_transfer(token: int, reason: String) -> void:
	if not transfers.has(token):
		return
	var reservation: Dictionary = transfers[token]
	transfers.erase(token)
	var uid := int(reservation.get("uid", 0))
	var record := record_by_uid(uid)
	if record.is_empty() or int(record.get("pending_transfer", 0)) != token:
		return
	record["pending_transfer"] = 0
	_settle_to_safe_spawn(record)
	touch(record)
	emit_signal("transfer_expired", int(reservation.get("peer_id", 0)), token,
		String(record.get("map_id", HPProtocol.DEFAULT_MAP)), record.get("safe_spawn", Vector3.ZERO))
	print("[Authority] transfer token %d expired (%s): uid %d returned to the last valid safe spawn in %s" % [
		token, reason, uid, record.get("map_id", "")])

func _check_transfers() -> void:
	for token in transfers.keys():
		if sim_tick > int((transfers[token] as Dictionary).get("expires_tick", 0)):
			_expire_transfer(int(token), "timeout")

## Puts a body back on its last server-approved grounded location (or the map's
## authored respawn when none is known). This is the one rescue path every
## interrupted transfer uses.
func _settle_to_safe_spawn(record: Dictionary) -> void:
	var map_id := String(record.get("map_id", HPProtocol.DEFAULT_MAP))
	var pos: Vector3 = HPMaps.respawn_point(map_id)
	var safe: Vector3 = record.get("safe_spawn", pos)
	if String(record.get("safe_spawn_map", "")) == map_id and HPMaps.contains_point(map_id, safe):
		pos = safe
	var node = record.get("node")
	if node != null and is_instance_valid(node):
		(node as Node3D).global_position = pos
		node.set("velocity", Vector3.ZERO)
	record["safe_spawn_map"] = map_id
	record["safe_spawn"] = pos

## The last valid safe spawn is refreshed while a body stands still on real
## ground in its own map: that is where a failed transfer returns it.
func _tick_safe_spawns() -> void:
	for uid in entities.keys():
		var record: Dictionary = entities[uid]
		if int(record.get("kind", 0)) != HPProtocol.Kind.PLAYER:
			continue
		if bool(record.get("dead", false)) or int(record.get("pending_transfer", 0)) != 0:
			continue
		if bool(record.get("mounted", false)):
			continue
		var node = record.get("node")
		if node == null or not is_instance_valid(node):
			continue
		var body := node as Node3D
		if body == null:
			continue
		if body.has_method("is_on_floor") and not body.is_on_floor():
			continue
		var map_id := String(record.get("map_id", HPProtocol.DEFAULT_MAP))
		if not HPMaps.contains_point(map_id, body.global_position):
			continue
		record["safe_spawn_map"] = map_id
		record["safe_spawn"] = body.global_position

func _respawn_position_for(record: Dictionary) -> Vector3:
	return HPMaps.respawn_point(String(record.get("map_id", HPProtocol.DEFAULT_MAP)))

static func to_map_of(portal: Dictionary) -> String:
	return String(portal.get("to_map", ""))

# ------------------------------------------------------------------ sim loop

func _physics_process(delta: float) -> void:
	if not is_authority():
		return
	if simulation_paused():
		return   # MAINTENANCE: the world is idle until the process is replaced
	_accumulator += delta
	var steps := 0
	while _accumulator >= HPProtocol.SIM_DT and steps < 5:
		_accumulator -= HPProtocol.SIM_DT
		_step()
		steps += 1

func _step() -> void:
	sim_tick += 1
	if mutations_frozen():
		# Frozen (SAVING/DISCONNECTING/MAINTENANCE/FAILED): the clock keeps its
		# own time, but no damage, reward, cast, burn, respawn or movement work
		# is advanced. The admin controller's own timers run on wall time, so the
		# save barrier still completes while this returns early.
		return
	_advance_casts()
	_advance_projectiles()
	_advance_effects()
	_check_respawns()
	_check_fall_protection()
	_check_transfers()
	_tick_safe_spawns()
	_tick_mount_phases()
	_regen_accumulator_ms += TICK_MS
	if _regen_accumulator_ms >= REGEN_INTERVAL_MS:
		_regen_accumulator_ms = 0
		_tick_regeneration()
	_autosave_accumulator_ms += TICK_MS
	if _autosave_accumulator_ms >= AUTOSAVE_INTERVAL_MS:
		_autosave_accumulator_ms = 0
		if persistence != null:
			persistence.autosave_all(entities, players_by_peer)

# ------------------------------------------------------------- mount phase
##
##  "Replicate mount state and animation phase to remote clients."
## The mount *state* already travels as FLAG_MOUNTED in every snapshot; this
## fills the same snapshot's unused `state` byte on PLAYER entities with the
## flight phase, derived here from authoritative input and the body's own speed,
## so every client renders the same phase for the same rider.
func _tick_mount_phases() -> void:
	for uid in entities.keys():
		var record: Dictionary = entities[uid]
		if int(record.get("kind", 0)) != HPProtocol.Kind.PLAYER:
			continue
		var mounted := bool(record.get("mounted", false))
		if not mounted:
			record["state"] = HPProtocol.MountPhase.NONE
			record["__mount_speed"] = 0.0
			continue
		var node = record.get("node")
		if node == null or not is_instance_valid(node):
			continue
		var lateral := 0.0
		var vertical := 0.0
		var input = record.get("input")
		if input is Dictionary:
			var move = input.get("move", null)
			if move is Vector2:
				lateral = (move as Vector2).x
			vertical += 1.0 if bool(input.get("jump", false)) else 0.0
			vertical -= 1.0 if bool(input.get("descend", false)) else 0.0
		var speed := 0.0
		if node is CharacterBody3D:
			speed = Vector2((node as CharacterBody3D).velocity.x, (node as CharacterBody3D).velocity.z).length()
		var top := float(node.get("mounted_speed")) if "mounted_speed" in node else 0.0
		if top <= 0.1:
			top = 15.0
		var previous := float(record.get("__mount_speed", 0.0))
		record["__mount_speed"] = speed
		record["state"] = HPProtocol.mount_phase_for(
			true, lateral, vertical, speed / top, (speed - previous) * HPProtocol.SIM_HZ)

# ------------------------------------------------------------- cast pipeline

func _advance_casts() -> void:
	var finished: Array = []
	for cast_id in casts.keys():
		var cast: Dictionary = casts[cast_id]
		var record: Dictionary = entities.get(cast["caster_uid"], {})
		if record.is_empty() or bool(record.get("dead", false)):
			finished.append(cast_id)
			continue
		if int(record.get("cast_id", 0)) != int(cast_id):
			# Interrupted by a later state change (stun, mount, death).
			finished.append(cast_id)
			continue
		if cast["state"] == HPProtocol.CastState.WINDUP and sim_tick >= int(cast["release_tick"]):
			cast["state"] = HPProtocol.CastState.RELEASE
			_resolve_cast(cast)
		if sim_tick >= int(cast["end_tick"]):
			finished.append(cast_id)
	for cast_id in finished:
		_end_cast(cast_id)

func _end_cast(cast_id: int) -> void:
	if not casts.has(cast_id):
		return
	var cast: Dictionary = casts[cast_id]
	var record: Dictionary = entities.get(cast["caster_uid"], {})
	if not record.is_empty() and int(record.get("cast_id", 0)) == cast_id:
		record["cast_id"] = 0
		var node = record.get("node")
		if node != null and is_instance_valid(node):
			casts_by_node.erase(node.get_instance_id())
		# Fire a queued cast (bounded input buffer) now that recovery ended.
		var queued := String(record.get("queued_spell", ""))
		if queued != "" and sim_tick <= int(record.get("queued_until_tick", 0)):
			var aim: Vector3 = record.get("queued_aim", Vector3.ZERO)
			var seq := int(record.get("queued_seq", -1))
			record["queued_spell"] = ""
			var result := cast_for_record(record, queued, aim, seq)
			if not bool(result.get("ok", false)):
				emit_signal("cast_finished", 0, false, String(result.get("reason", "")))
	casts.erase(cast_id)

## Interrupts: stun, disarm, death, mount. Damage is never applied by a cast that
## was interrupted before its release tick.
func interrupt_cast(record: Dictionary) -> void:
	var cast_id := int(record.get("cast_id", 0))
	if cast_id == 0:
		return
	record["cast_id"] = 0
	var node = record.get("node")
	if node != null and is_instance_valid(node):
		casts_by_node.erase((node as Node).get_instance_id())
	casts.erase(cast_id)

func _resolve_cast(cast: Dictionary) -> void:
	var caster: Dictionary = entities.get(cast["caster_uid"], {})
	if caster.is_empty():
		return
	var spell_id := String(cast["spell_id"])
	var delivery := HPRules.delivery(spell_id)
	var origin: Vector3 = caster["node"].global_position + Vector3(0, 1.2, 0)
	var dir: Vector3 = cast["dir"]
	emit_signal("cast_released", int(cast["cast_id"]), int(caster["uid"]), spell_id, origin, dir)
	emit_signal("cast_finished", int(cast["cast_id"]), true, HPProtocol.REJECT_OK)

	match delivery:
		"self":
			_apply_self_cast(caster, spell_id)
		"cone":
			_resolve_cone(caster, cast, origin, dir)
		"projectile":
			_spawn_projectile(caster, cast, origin, dir, false)
		"projectile_aoe":
			_spawn_projectile(caster, cast, origin, dir, true)

func _apply_self_cast(caster: Dictionary, spell_id: String) -> void:
	if spell_id != "protego":
		return
	var ticks := int(ceil(float(HPRules.ward_duration_ms(spell_id)) / TICK_MS))
	caster["ward_until_tick"] = sim_tick + ticks
	touch(caster)
	_push_stats(caster)

func _resolve_cone(caster: Dictionary, cast: Dictionary, origin: Vector3, dir: Vector3) -> void:
	var spell_id := String(cast["spell_id"])
	var data := HPRules.spell(spell_id)
	var range_value := float(data.get("range", 0.0))
	var half_angle := deg_to_rad(float(data.get("cone_angle", 60.0)) * 0.5)
	var hits: Array = []
	for target_uid in _damageable_targets(caster["uid"]):
		var record: Dictionary = entities[target_uid]
		var node: Node3D = record["node"]
		if not HPRules.can_damage(caster["node"], node):
			continue
		var offset: Vector3 = node.global_position + Vector3.UP - origin
		if offset.length() > range_value:
			continue
		if offset.length() > 0.01 and dir.dot(offset.normalized()) < cos(half_angle):
			continue
		if not HPRules.has_line_of_sight(caster["node"], node):
			continue
		var raw := int(cast["damage"])
		var applied := _apply_damage(record, raw, spell_id, caster)
		if applied > 0:
			hits.append({"uid": target_uid, "amount": applied})
			_apply_burn(record, spell_id, caster)
	emit_signal("cast_landed", int(cast["cast_id"]), int(caster["uid"]), spell_id, hits)

func _spawn_projectile(caster: Dictionary, cast: Dictionary, origin: Vector3, dir: Vector3, aoe: bool) -> void:
	var spell_id := String(cast["spell_id"])
	var data := HPRules.spell(spell_id)
	var speed := float(data.get("projectile_speed", 40.0))
	var range_value := float(data.get("range", 36.0))
	projectiles.append({
		"cast_id": int(cast["cast_id"]),
		"caster_uid": int(caster["uid"]),
		"spell_id": spell_id,
		"pos": origin,
		"dir": dir,
		"speed": speed,
		"remaining": range_value,
		"aoe": aoe,
		"radius": float(data.get("radius", 0.0)),
		"combo_mult": float(cast["combo_mult"]),
		"flat_damage": int(cast["damage"]),
		"hit_uid": 0,
	})

func _advance_projectiles() -> void:
	if projectiles.is_empty():
		return
	var space: PhysicsDirectSpaceState3D = null
	if world != null and is_instance_valid(world):
		space = world.get_world_3d().direct_space_state
	var remaining: Array = []
	for projectile in projectiles:
		var step: float = float(projectile["speed"]) * HPProtocol.SIM_DT
		if step > float(projectile["remaining"]):
			step = float(projectile["remaining"])
		var from: Vector3 = projectile["pos"]
		var to: Vector3 = from + (projectile["dir"] as Vector3) * step
		projectile["remaining"] = float(projectile["remaining"]) - step
		projectile["pos"] = to
		var caster: Dictionary = entities.get(projectile["caster_uid"], {})
		if caster.is_empty() or bool(caster.get("dead", false)):
			continue
		var caster_node = caster.get("node")
		if caster_node == null or not is_instance_valid(caster_node):
			continue
		var impact_uid := 0
		var impact_pos := to
		if space != null:
			var query := PhysicsRayQueryParameters3D.create(from, to, 3)
			query.exclude = [(caster_node as CollisionObject3D).get_rid()]
			var hit: Dictionary = space.intersect_ray(query)
			if not hit.is_empty():
				var collider = hit.collider
				var uid = collider.get_meta("sim_uid", 0) if collider != null else 0
				if uid != 0:
					var victim: Dictionary = entities.get(uid, {})
					var victim_node = victim.get("node")
					# Same-faction bodies are not obstacles: a bolt flies through
					# them, exactly as it did before authority moved to the server.
					if victim_node == null or not HPRules.can_damage(caster_node, victim_node):
						if float(projectile["remaining"]) > 0.0:
							remaining.append(projectile)
						continue
					impact_uid = uid
					impact_pos = hit.position
				else:
					impact_uid = 0
					impact_pos = hit.position
		if impact_uid == 0 and float(projectile["remaining"]) > 0.0:
			remaining.append(projectile)
			continue
		# Protego: a projectile that reaches an active ward is REFLECTED - it
		# flips owner and direction and keeps flying (one rule, applied here, so
		# a reflected bolt can hit the original caster but never the warden).
		if impact_uid != 0 and not bool(projectile["aoe"]):
			var victim: Dictionary = entities.get(impact_uid, {})
			if not victim.is_empty() and int(victim.get("ward_until_tick", 0)) > sim_tick \
					and HPRules.ward_projectile_rule(String(projectile["spell_id"])) == "reflect":
				projectile["dir"] = -(projectile["dir"] as Vector3)
				projectile["pos"] = impact_pos + (projectile["dir"] as Vector3) * 0.4
				projectile["caster_uid"] = impact_uid
				projectile["speed"] = float(projectile["speed"]) * 1.1
				projectile["remaining"] = maxf(float(projectile["remaining"]), 8.0)
				remaining.append(projectile)
				emit_signal("cast_landed", int(projectile["cast_id"]), int(caster["uid"]),
					String(projectile["spell_id"]), [{"uid": impact_uid, "amount": 0, "reflected": true}])
				continue
		_projectile_impact(projectile, impact_uid, impact_pos, caster)
	projectiles = remaining

func _projectile_impact(projectile: Dictionary, impact_uid: int, impact_pos: Vector3, caster: Dictionary) -> void:
	var spell_id := String(projectile["spell_id"])
	var hits: Array = []
	if bool(projectile["aoe"]):
		var radius := float(projectile["radius"])
		var data := HPRules.spell(spell_id)
		var floor_ratio := float(data.get("falloff_floor", 0.4))
		for target_uid in _damageable_targets(projectile["caster_uid"]):
			var record: Dictionary = entities[target_uid]
			var node: Node3D = record["node"]
			if not HPRules.can_damage(caster["node"], node):
				continue
			var distance: float = node.global_position.distance_to(impact_pos)
			if distance > radius:
				continue
			if not HPRules.has_line_of_sight(caster["node"], node):
				continue
			var raw := int(float(_projectile_damage(projectile, caster)) * HPRules.aoe_falloff(distance, radius, floor_ratio))
			var applied := _apply_damage(record, raw, spell_id, caster)
			if applied > 0:
				hits.append({"uid": target_uid, "amount": applied})
	elif impact_uid != 0:
		var record: Dictionary = entities.get(impact_uid, {})
		if not record.is_empty():
			var raw := _projectile_damage(projectile, caster)
			var applied := _apply_damage(record, raw, spell_id, caster)
			if applied > 0:
				hits.append({"uid": impact_uid, "amount": applied})
	emit_signal("cast_landed", int(projectile["cast_id"]), int(caster["uid"]), spell_id, hits)


## A full spell hit on one target (damage + any status it applies), for callers
## that resolve a hit outside the cone/projectile paths - tests, and future traps
## or environmental effects. Same resolution as a real cast.
func apply_spell_hit(target: Node, spell_id: String, caster: Node) -> int:
	if not is_authority():
		return 0
	var target_record := record_for(target)
	if target_record.is_empty():
		return 0
	var caster_record := record_for(caster)
	var raw := HPRules.spell_damage(spell_id, int(caster_record.get("wand_tier", 0)),
		String(caster_record.get("house", "")), 1.0)
	raw = int(raw * float(caster_record.get("weapon_multiplier", 1.0)))
	var applied := _apply_damage(target_record, raw, spell_id, caster_record)
	if applied > 0:
		_apply_burn(target_record, spell_id, caster_record)
	return applied

## Area damage for a spell impact resolved outside a data projectile (a client's
## predicted explosion, a trap, an environmental blast). Same falloff and victim
## filtering as the projectile path.
func spell_area_impact(caster_node: Node, center: Vector3, radius: float, spell_id: String, flat_damage: int) -> Array:
	var hits: Array = []
	if not is_authority():
		return hits
	var caster := record_for(caster_node)
	var floor_ratio := float(HPRules.spell(spell_id).get("falloff_floor", 0.4))
	for uid in _damageable_targets(int(caster.get("uid", 0))):
		var record: Dictionary = entities[uid]
		var node = record.get("node")
		if node == null or not is_instance_valid(node):
			continue
		if not HPRules.can_damage(caster_node, node):
			continue
		var distance: float = (node as Node3D).global_position.distance_to(center)
		if distance > radius:
			continue
		if not caster.is_empty() and not HPRules.has_line_of_sight(caster_node as Node3D, node):
			continue
		var raw := int(float(flat_damage) * HPRules.aoe_falloff(distance, radius, floor_ratio))
		var applied := _apply_damage(record, raw, spell_id, caster)
		if applied > 0:
			hits.append({"uid": uid, "amount": applied})
	return hits

# --------------------------------------------------------------- damage paths

## Authoritative damage entry point. `raw` is pre-modifier damage; resistance,
## ward reduction and protection are applied here, once, for every source
## (projectile, cone, AoE, burn tick, mob melee, boss slam).
func apply_damage(target: Node, raw: int, spell_id: String, attacker: Node) -> int:
	if not is_authority():
		return 0
	var target_record := record_for(target)
	if target_record.is_empty():
		return 0
	var attacker_record := record_for(attacker)
	return _apply_damage(target_record, raw, spell_id, attacker_record)

## --- Mob attack helpers. Mob AI lives on the mob nodes (server side); these
## entry points are how it asks for damage to be resolved, so victim filtering,
## protection, wards and status effects all go through one implementation.

func mob_melee(attacker_node: Node, target_node: Node, raw: int) -> int:
	if not is_authority() or target_node == null:
		return 0
	if not HPRules.can_damage(attacker_node, target_node):
		return 0
	return apply_damage(target_node, raw, "melee", attacker_node)

func mob_area_attack(attacker_node: Node, center: Vector3, radius: float, raw: int, spell_id: String) -> Array:
	var hits: Array = []
	if not is_authority():
		return hits
	var attacker := record_for(attacker_node)
	var attacker_map := String(attacker.get("map_id", ""))
	for uid in entities.keys():
		var record: Dictionary = entities[uid]
		if int(record.get("kind", 0)) != HPProtocol.Kind.PLAYER or bool(record.get("dead", false)):
			continue
		if attacker_map != "" and String(record.get("map_id", HPProtocol.DEFAULT_MAP)) != attacker_map:
			continue
		var node = record.get("node")
		if node == null or not is_instance_valid(node):
			continue
		if not HPRules.can_damage(attacker_node, node):
			continue
		if (node as Node3D).global_position.distance_to(center) > radius:
			continue
		if not attacker.is_empty() and not HPRules.has_line_of_sight(attacker_node as Node3D, node):
			continue
		var applied := _apply_damage(record, raw, spell_id, attacker)
		if applied > 0:
			hits.append({"uid": uid, "amount": applied})
	return hits

## Directional boss attack: every player inside the cone (distance + facing
## angle + line of sight + protection gate) takes damage. The cone is described
## by the same `dir`/`half_angle`/`range` the telegraph published, so what the
## client warned about is exactly what the authority resolves.
func mob_cone_attack(attacker_node: Node, dir: Vector3, half_angle: float, radius: float,
		raw: int, spell_id: String) -> Array:
	var hits: Array = []
	if not is_authority():
		return hits
	var attacker := record_for(attacker_node)
	if attacker.is_empty():
		return hits
	var attacker_map := String(attacker.get("map_id", ""))
	var origin: Vector3 = (attacker_node as Node3D).global_position
	var forward := dir
	forward.y = 0.0
	if forward.length_squared() < 0.0001:
		return hits
	forward = forward.normalized()
	var cos_limit := cos(maxf(0.0, half_angle))
	for uid in entities.keys():
		var record: Dictionary = entities[uid]
		if int(record.get("kind", 0)) != HPProtocol.Kind.PLAYER or bool(record.get("dead", false)):
			continue
		if attacker_map != "" and String(record.get("map_id", HPProtocol.DEFAULT_MAP)) != attacker_map:
			continue
		var node = record.get("node")
		if node == null or not is_instance_valid(node):
			continue
		var to_target: Vector3 = (node as Node3D).global_position - origin
		to_target.y = 0.0
		var distance := to_target.length()
		if distance > radius:
			continue
		if distance > 0.01 and to_target.normalized().dot(forward) < cos_limit:
			continue
		if not HPRules.can_damage(attacker_node, node):
			continue
		if not HPRules.has_line_of_sight(attacker_node as Node3D, node):
			continue
		var applied := _apply_damage(record, raw, spell_id, attacker)
		if applied > 0:
			hits.append({"uid": uid, "amount": applied})
	return hits

func mob_projectile(attacker_node: Node, spell_id: String, dir: Vector3, raw: int) -> void:
	if not is_authority():
		return
	var attacker := record_for(attacker_node)
	if attacker.is_empty():
		return
	if HPRules.is_protected_node(attacker_node):
		return
	var origin: Vector3 = (attacker_node as Node3D).global_position + Vector3.UP * 1.2
	var data := HPRules.spell(spell_id)
	projectiles.append({
		"cast_id": 0,
		"caster_uid": int(attacker["uid"]),
		"spell_id": spell_id,
		"pos": origin,
		"dir": dir.normalized(),
		"speed": float(data.get("projectile_speed", 40.0)),
		"remaining": float(data.get("range", 30.0)),
		"aoe": false,
		"radius": 0.0,
		"combo_mult": 1.0,
		"flat_damage": raw,
		"hit_uid": 0,
	})

func _projectile_damage(projectile: Dictionary, caster: Dictionary) -> int:
	if projectile.has("flat_damage"):
		return int(projectile["flat_damage"])
	return HPRules.spell_damage(String(projectile["spell_id"]), int(caster.get("wand_tier", 0)),
		String(caster.get("house", "")), float(projectile["combo_mult"]))

func _damageable_targets(caster_uid: int) -> Array:
	var out: Array = []
	# A caster with no record (scripted/environmental damage) keeps the legacy
	# unfiltered behaviour; a real caster can only damage its own map, however
	# close two maps' coordinates happen to be.
	var caster_map := String(entities.get(caster_uid, {}).get("map_id", ""))
	for uid in entities.keys():
		var record: Dictionary = entities[uid]
		if uid == caster_uid or bool(record.get("dead", false)):
			continue
		if caster_map != "" and String(record.get("map_id", HPProtocol.DEFAULT_MAP)) != caster_map:
			continue
		var kind := int(record["kind"])
		if kind != HPProtocol.Kind.PLAYER and kind != HPProtocol.Kind.MOB \
				and kind != HPProtocol.Kind.DUMMY and kind != HPProtocol.Kind.MONOLITH:
			continue
		var node = record.get("node")
		if node == null or not is_instance_valid(node) or not node.has_method("take_damage"):
			continue
		out.append(uid)
	return out

func _apply_damage(target: Dictionary, raw: int, spell_id: String, attacker: Dictionary) -> int:
	if mutations_frozen():
		return 0   # the save barrier freezes damage, and therefore rewards
	if raw <= 0 or target.is_empty() or bool(target.get("dead", false)):
		return 0
	var target_node: Node = target.get("node")
	if target_node == null or not is_instance_valid(target_node):
		return 0
	# Protection is evaluated at RESOLUTION time, so a projectile in flight or a
	# burn tick that lands after the victim reached a safe volume deals nothing.
	# It applies to ATTACKS: damage with no attacker (falling, kill-planes,
	# scripted effects) is not an attack from a position and is not gated by it.
	if not attacker.is_empty():
		var protected_target := HPRules.is_protected_node(target_node)
		if protected_target and not target_node.is_in_group("dummies"):
			return 0
	# Faction gate (players cannot damage players, NPCs are immune, ...). The
	# protected-attacker rule is NOT applied here: attack paths ask
	# `HPRules.can_damage` before they ever reach this function, and applying it
	# here would also forbid direct damage (tools, tests, environmental effects)
	# from a protected position, which the core design never intended.
	if not attacker.is_empty():
		var attacker_node2: Node = attacker.get("node")
		if attacker_node2 != null and is_instance_valid(attacker_node2) and not HPRules.faction_ok(attacker_node2, target_node):
			return 0

	var amount := HPRules.damage_after_resistances(raw, spell_id, bool(target.get("weak_to_fire", false)))
	# Protego: projectiles are reflected (handled by the caller), everything else
	# is reduced by the authored multiplier.
	if int(target.get("ward_until_tick", 0)) > sim_tick and not _is_projectile_spell(spell_id):
		amount = int(float(amount) * HPRules.ward_other_multiplier("protego"))

	if not attacker.is_empty():
		amount = maxi(0, int(amount * (1.0 - clampf(float(target.get("defense", 0)), 0, 50) / 100.0)))
		if amount > 0:
			attacker["last_combat_tick"] = sim_tick
	if amount > 0: target["last_combat_tick"] = sim_tick
	target["hp"] = maxi(0, int(target.get("hp", 0)) - amount)
	target["last_damage"] = amount
	touch(target)
	if not attacker.is_empty():
		(target["damage_log"] as Array).append({
			"attacker_uid": int(attacker["uid"]),
			"attacker_character": int(attacker.get("character_id", 0)),
			"at_tick": sim_tick,
			"amount": amount,
		})
		_trim_damage_log(target)
	# The node's own hp has to be current BEFORE anything reacts to the hit: the
	# monolith decides its wave thresholds from its hp, and a mob's label shows
	# it, so a stale value here would spawn the wrong number of waves.
	_sync_node_health(target)
	_apply_status_on_hit(target, spell_id, attacker)
	_notify_damage(target, spell_id, attacker)
	emit_signal("entity_damaged", int(target["uid"]), amount, int(target["hp"]), spell_id, int(attacker.get("uid", 0)))
	emit_signal("entity_health", int(target["uid"]), int(target["hp"]), int(target.get("max_hp", 0)), flags_for(target))
	if int(target["hp"]) <= 0:
		_kill(target, attacker)
	# Knockback is a spell-data rule applied here (once) rather than by whichever
	# visual happened to hit.
	if not attacker.is_empty():
		var attacker_node = attacker.get("node")
		if attacker_node != null and is_instance_valid(attacker_node) and target_node is Node3D \
				and target_node.has_method("apply_knockback"):
			var force := HPRules.knockback_force(spell_id, (target_node as Node3D).global_position - (attacker_node as Node3D).global_position)
			if force != Vector3.ZERO:
				target_node.call("apply_knockback", force)

	return amount

func _is_projectile_spell(spell_id: String) -> bool:
	var delivery := HPRules.delivery(spell_id)
	return delivery == "projectile" or delivery == "projectile_aoe"

## Presentation-only notification. The numbers were applied above; the node is
## told what happened rather than asked to apply anything (no re-entry).
func _notify_damage(target: Dictionary, spell_id: String, attacker: Dictionary) -> void:
	var node = target.get("node")
	if node == null or not is_instance_valid(node) or not node.has_method("on_authoritative_damage"):
		return
	var stun := HPRules.stun_ms(spell_id, target.get("is_boss") == true)
	var weaken := HPRules.weaken_ms(spell_id)
	node.call("on_authoritative_damage", spell_id,
		attacker.get("node") if not attacker.is_empty() else null, stun, weaken)

func _trim_damage_log(target: Dictionary) -> void:
	var log: Array = target["damage_log"]
	var window := int(ceil(float(HPProtocol.KILL_CREDIT_MS) / TICK_MS))
	while log.size() > 64:
		log.pop_front()
	if log.size() > 0 and sim_tick - int(log[0].get("at_tick", 0)) > window * 2:
		var trimmed: Array = []
		for entry in log:
			if sim_tick - int(entry.get("at_tick", 0)) <= window:
				trimmed.append(entry)
		target["damage_log"] = trimmed

## Status effects are a property of the victim: stun and disarm land on mobs and
## never on players (the client's `is_protego_active` and the engine's ward cover
## players instead).
func _apply_status_on_hit(target: Dictionary, spell_id: String, attacker: Dictionary) -> void:
	if target.get("kind", 0) == HPProtocol.Kind.PLAYER:
		return
	var stun := HPRules.stun_ms(spell_id, target.get("is_boss") == true)
	if stun > 0:
		target["stun_until_tick"] = sim_tick + int(ceil(float(stun) / TICK_MS))
		interrupt_mob(target)
	var weaken := HPRules.weaken_ms(spell_id)
	if weaken > 0:
		target["weak_until_tick"] = sim_tick + int(ceil(float(weaken) / TICK_MS))

func _apply_burn(target: Dictionary, spell_id: String, attacker: Dictionary) -> void:
	var burn: Dictionary = HPRules.burn_spec(spell_id)
	if burn.is_empty():
		return
	var interval := int(burn.get("interval_ms", 1000))
	target["burn_until_tick"] = sim_tick + int(burn.get("ticks", 0)) * int(ceil(float(interval) / TICK_MS))
	target["burn_next_tick"] = sim_tick + int(ceil(float(interval) / TICK_MS))
	target["burn_damage"] = int(burn.get("damage", 0))
	target["burn_source_uid"] = int(attacker.get("uid", 0)) if not attacker.is_empty() else 0

func _advance_effects() -> void:
	var interval_ticks := maxi(1, int(ceil(1000.0 / TICK_MS)))
	for uid in entities.keys():
		var record: Dictionary = entities[uid]
		if bool(record.get("dead", false)):
			continue
		var burn_until := int(record.get("burn_until_tick", 0))
		if burn_until > 0:
			if sim_tick > burn_until:
				record["burn_until_tick"] = 0
			elif sim_tick >= int(record.get("burn_next_tick", 0)):
				# Burn ticks stay scheduled on the servant clock; protection is
				# re-checked inside _apply_damage, so a tick that lands after the
				# victim reached a safe volume deals nothing (the burn itself keeps
				# running, matching the core rule).
				record["burn_next_tick"] = sim_tick + interval_ticks
				var source: Dictionary = entities.get(int(record.get("burn_source_uid", 0)), {})
				_apply_damage(record, int(record.get("burn_damage", 0)), "burn", source)
		if int(record.get("ward_until_tick", 0)) != 0 and sim_tick >= int(record["ward_until_tick"]):
			record["ward_until_tick"] = 0
			touch(record)
			_push_stats(record)
		if sim_tick - int(record.get("spawned_tick", sim_tick)) > int(LOOT_LIFETIME_MS / TICK_MS) \
				and int(record.get("kind", 0)) == HPProtocol.Kind.LOOT:
			entities.erase(uid)
			emit_signal("entity_despawned", uid)

func interrupt_mob(record: Dictionary) -> void:
	var node = record.get("node")
	if node != null and is_instance_valid(node) and node.has_method("cancel_cast_action"):
		node.call("cancel_cast_action")

# --------------------------------------------------------------- death/reward

func _kill(target: Dictionary, killer: Dictionary) -> void:
	if bool(target.get("dead", false)):
		return
	# Death cancels a pending transfer: the reservation must not survive the
	# body it belonged to (the respawn puts the character on its own map).
	if int(target.get("pending_transfer", 0)) != 0:
		cancel_transfer_for_uid(int(target["uid"]), "death")
	target["dead"] = true
	target["hp"] = 0
	touch(target)
	var node = target.get("node")
	var killer_node = killer.get("node") if not killer.is_empty() else null
	emit_signal("entity_died", int(target["uid"]), int(killer.get("uid", 0)))
	if node != null and is_instance_valid(node):
		if node.has_method("on_authoritative_death"):
			node.call("on_authoritative_death", killer_node)
	if int(target.get("kind", 0)) == HPProtocol.Kind.PLAYER:
		_schedule_player_respawn(target)
		return
	_grant_kill_rewards(target)

func killer_uid_of(target: Dictionary) -> int:
	var last := 0
	for entry in target.get("damage_log", []):
		last = int(entry.get("attacker_uid", last))
	return last

func _grant_kill_rewards(target: Dictionary) -> void:
	var window := int(ceil(float(HPProtocol.KILL_CREDIT_MS) / TICK_MS))
	var eligible: Array = []
	for entry in target.get("damage_log", []):
		if sim_tick - int(entry.get("at_tick", 0)) > window:
			continue
		var uid := int(entry.get("attacker_uid", 0))
		if uid == 0 or eligible.has(uid):
			continue
		var attacker: Dictionary = entities.get(uid, {})
		if attacker.is_empty() or int(attacker.get("kind", 0)) != HPProtocol.Kind.PLAYER:
			continue
		eligible.append(uid)
	var death_seq := _next_death_seq
	_next_death_seq += 1
	print("[Authority] kill uid=%d by %d -> eligible %s (log %d entries, tick %d)" % [
		int(target["uid"]), int(killer_uid_of(target)), str(eligible), (target.get("damage_log", []) as Array).size(), sim_tick])
	var exp_reward := int(target.get("exp_reward", 0))
	for uid in eligible:
		var player: Dictionary = entities.get(uid, {})
		if player.is_empty():
			continue
		var character_id := int(player.get("character_id", 0))
		# Keyed by the player ENTITY, not the character: a session whose character
		# is unbound (dev join) still gets exactly one credit per death.
		var op_id := "kill:%d:%d:%d" % [int(target["uid"]), death_seq, int(uid)]
		# Each eligible player is credited exactly once per death: the death
		# sequence is part of the op id, so a re-run of this function for the
		# same death cannot pay twice even if it were called again.
		if _reward_already_granted(op_id):
			continue
		_grant_exp(player, exp_reward)
		emit_signal("reward_granted", int(uid), character_id, exp_reward, 0, [], op_id)
	# Loot is dropped once, server-side, for everyone to race for.
	_drop_loot(target)

var _granted_ops: Dictionary = {}

func _reward_already_granted(op_id: String) -> bool:
	if _granted_ops.has(op_id):
		return true
	_granted_ops[op_id] = true
	if _granted_ops.size() > 4096:
		_granted_ops.clear()
	return false

func _grant_exp(player: Dictionary, exp: int) -> void:
	if exp <= 0:
		return
	var node = player.get("node")
	var live := node != null and is_instance_valid(node)
	var level := int(node.get("level")) if live else int(player.get("level", 1))
	var current := (int(node.get("current_exp")) if live else int(player.get("exp", 0))) + exp
	var gains: Dictionary = HPRules.combat().get("base_stats", {})
	while level < HPRules.max_level() and current >= HPRules.exp_threshold(level):
		current -= HPRules.exp_threshold(level)
		level += 1
		if live:
			node.base_max_hp += int(gains.get("level_hp_gain", 40))
			node.base_max_mana += int(gains.get("level_mana_gain", 25))
		var new_max_hp := int(player.get("max_hp", 0) if not live else node.get("max_hp")) + int(gains.get("level_hp_gain", 40))
		var new_max_mana := int(player.get("max_mana", 0) if not live else node.get("max_mana")) + int(gains.get("level_mana_gain", 25))
		player["max_hp"] = new_max_hp
		player["hp"] = new_max_hp
		player["max_mana"] = new_max_mana
		player["mana"] = new_max_mana
		emit_signal("level_changed", int(player["uid"]), level)
		if live and node.has_method("apply_level"):
			node.call("apply_level", level, new_max_hp, new_max_mana)
	player["exp"] = current
	player["level"] = level
	if live:
		node.set("level", level)
		node.set("current_exp", current)
		node.set("max_exp", HPRules.exp_threshold(level))
	touch(player)
	_push_stats(player)

func _drop_loot(target: Dictionary) -> void:
	var is_boss := bool(target.get("is_boss", false))
	var drops: Array = []
	if int(target.get("kind", 0)) == HPProtocol.Kind.MONOLITH:
		drops = HPRules.monolith_loot(rng)
	else:
		drops = HPRules.mob_loot(is_boss, rng)
	if int(target.get("kind", 0)) == HPProtocol.Kind.MONOLITH:
		if rng.randf() < 0.25: drops.append({"id": "ring_adept", "amount": 1})
	elif is_boss or rng.randf() < 0.2:
		drops.append({"id": HPEquipment.BASIC_ACCESSORIES[rng.randi_range(0, 5)], "amount": 1})
	var node = target.get("node")
	var origin: Vector3 = node.global_position if node != null and is_instance_valid(node) else Vector3.ZERO
	var map_id := String(target.get("map_id", HPMaps.map_for_point(origin)))
	for drop in drops:
		_spawn_loot_node(String(drop["id"]), int(drop["amount"]), origin, map_id)

## Spawned by the authority; in the dedicated server the loot node is a plain
## replicated marker, on the host/offline it is the real pickup scene.
func _spawn_loot_node(item_id: String, amount: int, origin: Vector3, map_id: String = "") -> void:
	var uid := _make_uid()
	if map_id == "":
		map_id = HPMaps.map_for_point(origin)
	entities[uid] = {
		"uid": uid,
		"kind": HPProtocol.Kind.LOOT,
		"node": null,
		"map_id": map_id,
		"zone_id": HPRules.zone_id_for_map(map_id, origin),
		"pack_id": 0,
		"revision": 1,
		"dead": false,
		"item_id": item_id,
		"amount": amount,
		"pos": origin + _loot_scatter(),
		"spawned_tick": sim_tick,
	}
	emit_signal("loot_spawned", uid, item_id, amount, entities[uid]["pos"])

func _loot_scatter() -> Vector3:
	var angle := rng.randf() * TAU
	var distance := rng.randf_range(-1.0, 1.0)
	return Vector3(cos(angle) * distance, 0.3, sin(angle) * distance)

const LOOT_LIFETIME_MS := 90000

## Pickup request from a player. Range-checked, then granted through the
## authority so the item cannot be duplicated by replaying the request.
func request_pickup(peer_id: int, loot_uid: int) -> Dictionary:
	if not is_authority():
		return HPProtocol.reject(HPProtocol.REJECT_STATE)
	if mutations_frozen():
		return HPProtocol.reject(HPProtocol.REJECT_STATE)
	var player := player_record(peer_id)
	if player.is_empty():
		return HPProtocol.reject(HPProtocol.REJECT_STATE)
	if int(player.get("pending_transfer", 0)) != 0:
		return HPProtocol.reject(HPProtocol.REJECT_TRANSFER_PENDING)
	if bool(player.get("persistence_conflict", false)) or bool(player.get("dead", false)):
		return HPProtocol.reject(HPProtocol.REJECT_STATE)
	var loot: Dictionary = entities.get(loot_uid, {})
	if loot.is_empty() or int(loot.get("kind", 0)) != HPProtocol.Kind.LOOT:
		return HPProtocol.reject(HPProtocol.REJECT_NO_TARGET)
	if String(loot.get("map_id", HPProtocol.DEFAULT_MAP)) != String(player.get("map_id", HPProtocol.DEFAULT_MAP)):
		return HPProtocol.reject(HPProtocol.REJECT_NO_TARGET)
	var node: Node3D = player["node"]
	if node.global_position.distance_to(loot["pos"]) > LOOT_PICKUP_RANGE:
		return HPProtocol.reject(HPProtocol.REJECT_RANGE)
	var bag: Array = node.inventory.duplicate(true)
	if String(loot.item_id) != "galleons":
		HPEquipment.add(bag, String(loot.item_id), 0, int(loot.amount))
		if not HPEquipment.capacity_ok(bag): return HPProtocol.reject("bag_full")
	_collect_loot(loot, player)
	return HPProtocol.accept()

const LOOT_PICKUP_RANGE := 7.0

func _collect_loot(loot: Dictionary, player: Dictionary) -> void:
	var loot_uid := int(loot["uid"])
	var item_id := String(loot["item_id"])
	var amount := int(loot["amount"])
	var character_id := int(player.get("character_id", 0))
	var op_id := "loot:%d:%d" % [loot_uid, character_id]
	if _reward_already_granted(op_id):
		entities.erase(loot_uid)
		emit_signal("entity_despawned", loot_uid)
		return
	var node = loot.get("node")
	if node != null and is_instance_valid(node):
		by_node.erase((node as Node).get_instance_id())
		node.queue_free()
	var pnode = player.get("node")
	if pnode != null and is_instance_valid(pnode) and pnode.has_method("add_loot"):
		pnode.call("add_loot", item_id, amount)
		# Keep the record in step: the record is what stats pushes are built from,
		# so a stale record would take the gold back on the next tick.
		if "galleons" in pnode:
			player["galleons"] = int(pnode.get("galleons"))
		touch(player)
		_push_stats(player)
	# The world server is the single writer of a character during its session
	# (persistence.gd): the loot is already in the body and in the record, so
	# the periodic autosave and the disconnect save persist it. It must NOT also
	# go through the reward ledger: the ledger's incremental /api/reward lands
	# on top of the save that already carried the galleons, so the same pickup
	# was credited twice whenever the ledger request outlived the session's last
	# save (the character-bind fix measured 500 -> 554 in session, then 608 reloaded for
	# a single 54-galleon drop). Unbound sessions (character_id <= 0) have no
	# save path at all, and queue_reward is a no-op for them anyway.
	emit_signal("loot_taken", loot_uid, character_id, item_id, amount, int(player.get("peer_id", 0)))
	emit_signal("entity_despawned", loot_uid)
	entities.erase(loot_uid)

func _schedule_player_respawn(record: Dictionary) -> void:
	# Death is final until the respawn request (or the automatic timer when the
	# client is gone). Nothing about the death depends on client timing.
	record["respawn_tick"] = sim_tick + int(ceil(float(HPRules.respawn_ms()) / TICK_MS))

func _respawn_player(record: Dictionary) -> void:
	record["dead"] = false
	record["hp"] = int(record.get("max_hp", 1))
	record["mana"] = int(record.get("max_mana", 0))
	record["ward_until_tick"] = 0
	record["stun_until_tick"] = 0
	record["burn_until_tick"] = 0
	record["cast_id"] = 0
	record["respawn_tick"] = 0
	var node = record.get("node")
	if node != null and is_instance_valid(node):
		if node.has_method("on_authoritative_respawn"):
			# The node's own handler resets to the legacy single-map spawn; the
			# authority then places the body at the respawn point of ITS map, so
			# a character that dies inside the castle does not wake up outdoors.
			node.call("on_authoritative_respawn")
		var respawn_pos := _respawn_position_for(record)
		node.global_position = respawn_pos
		node.set("velocity", Vector3.ZERO)
		record["safe_spawn_map"] = String(record.get("map_id", HPProtocol.DEFAULT_MAP))
		record["safe_spawn"] = respawn_pos
	touch(record)
	_push_stats(record)
	emit_signal("entity_respawned", int(record["uid"]))

# --------------------------------------------------------------- regeneration

func _tick_regeneration() -> void:
	for uid in entities.keys():
		var record: Dictionary = entities[uid]
		if int(record.get("kind", 0)) != HPProtocol.Kind.PLAYER or bool(record.get("dead", false)):
			continue
		var node = record.get("node")
		if node != null and is_instance_valid(node) and node.has_method("_tick_regeneration"):
			# The node holds the live values in every role, so the engine asks it
			# to tick (one arithmetic path, no duplicate implementation).
			node.call("_tick_regeneration", float(REGEN_INTERVAL_MS) / 1000.0)
			record["hp"] = int(node.get("current_hp"))
			record["mana"] = int(node.get("current_mana"))
			touch(record)
			_push_stats(record)
			continue
		var seconds := float(REGEN_INTERVAL_MS) / 1000.0
		var hp := mini(int(record.get("max_hp", 0)), int(record.get("hp", 0)) + int(HPRules.regen_hp_per_second() * seconds))
		var mana := mini(int(record.get("max_mana", 0)), int(record.get("mana", 0)) + int(HPRules.regen_mana_per_second(String(record.get("house", ""))) * seconds))
		if hp != int(record.get("hp", 0)) or mana != int(record.get("mana", 0)):
			record["hp"] = hp
			record["mana"] = mana
			touch(record)
			_push_stats(record)

## Respawn timers are checked on the sim clock (never on client timing), which
## is also what keeps a disconnected player from staying dead forever.
func _check_respawns() -> void:
	for uid in entities.keys():
		var record: Dictionary = entities[uid]
		if int(record.get("kind", 0)) != HPProtocol.Kind.PLAYER:
			continue
		var respawn_tick := int(record.get("respawn_tick", 0))
		if respawn_tick > 0 and sim_tick >= respawn_tick and bool(record.get("dead", false)):
			_respawn_player(record)

## The kill-plane rule belongs to the authority: a body that falls out of its
## map is returned to that map's respawn point by the same process that owns
## every other position, so it can never be a client-side rescue that other
## players never see. The floor is per map, which is also what
## keeps a body inside an empty greybox map at a valid location.
func _check_fall_protection() -> void:
	for uid in entities.keys():
		var record: Dictionary = entities[uid]
		if int(record.get("kind", 0)) != HPProtocol.Kind.PLAYER:
			continue
		var node = record.get("node")
		if node == null or not is_instance_valid(node):
			continue
		var map_id := String(record.get("map_id", HPProtocol.DEFAULT_MAP))
		if (node as Node3D).global_position.y >= HPMaps.y_min(map_id):
			continue
		(node as Node3D).global_position = _respawn_position_for(record)
		node.set("velocity", Vector3.ZERO)
		record["hp"] = int(record.get("max_hp", 1))
		touch(record)
		_push_stats(record)
		# Rate-limited: a floorless greybox map (before its scene ships) bounces
		# its bodies at the spawn point and must not flood the server log.
		if sim_tick - int(record.get("last_fall_warn_tick", -1000)) > 10 * HPProtocol.SIM_HZ:
			record["last_fall_warn_tick"] = sim_tick
			print("[Authority] player %d fell out of %s; returned to its spawn" % [uid, map_id])

## Public EXP grant (kills, quests, monoliths). Level-up rules live here so the
## client cannot level itself.
func grant_exp(node: Node, amount: int) -> void:
	if not is_authority():
		return
	var record := record_for(node)
	if record.is_empty():
		return
	_grant_exp(record, amount)

# ------------------------------------------------------- node/state mirroring

func _sync_node_health(record: Dictionary) -> void:
	var node = record.get("node")
	if node == null or not is_instance_valid(node):
		return
	if "current_hp" in node:
		node.current_hp = int(record["hp"])

func _push_stats(record: Dictionary) -> void:
	var stats := build_stats(record)
	var node = record.get("node")
	if node != null and is_instance_valid(node) and node.has_method("apply_authoritative_stats"):
		node.call("apply_authoritative_stats", stats)
	emit_signal("stats_changed", int(record["uid"]), stats)

func build_stats(record: Dictionary) -> Dictionary:
	var result := {
		"uid": int(record.get("uid", 0)),
		"hp": int(record.get("hp", 0)),
		"max_hp": int(record.get("max_hp", 0)),
		"mana": int(record.get("mana", 0)),
		"max_mana": int(record.get("max_mana", 0)),
		"exp": int(record.get("exp", 0)),
		"max_exp": HPRules.exp_threshold(int(record.get("level", 1))),
		"level": int(record.get("level", 1)),
		"galleons": int(record.get("galleons", 0)),
		"dead": bool(record.get("dead", false)),
		"mounted": bool(record.get("mounted", false)),
	}

	result.merge(equipment_snapshot(record))
	return result

func flags_for(record: Dictionary) -> int:
	var flags := 0
	if bool(record.get("dead", false)):
		flags |= HPProtocol.FLAG_DEAD
	if bool(record.get("mounted", false)):
		flags |= HPProtocol.FLAG_MOUNTED
	if int(record.get("cast_id", 0)) != 0:
		flags |= HPProtocol.FLAG_CASTING
	if int(record.get("stun_until_tick", 0)) > sim_tick:
		flags |= HPProtocol.FLAG_STUNNED
	if int(record.get("ward_until_tick", 0)) > sim_tick:
		flags |= HPProtocol.FLAG_WARDED
	if bool(record.get("is_boss", false)):
		flags |= HPProtocol.FLAG_BOSS
	if bool(record.get("is_enraged", false)):
		flags |= HPProtocol.FLAG_ENRAGED
	var node = record.get("node")
	if node != null and is_instance_valid(node) and HPRules.is_protected_node(node):
		flags |= HPProtocol.FLAG_PROTECTED
	return flags

## Called by the network layer on the client to mirror a server stat payload.
func apply_stats_payload(uid: int, stats: Dictionary) -> void:
	var record: Dictionary = entities.get(uid, {})
	if record.is_empty():
		return
	var node = record.get("node")
	if is_instance_valid(node) and stats.has("equipment") and int(stats.get("inventory_revision",-1)) < node.inventory_revision:
		return
	for key in stats.keys():
		record[key] = stats[key]
	_sync_node_health(record)
	# Replica state must come directly from the received snapshot. Rebuilding
	# through build_stats() here would merge the client's old bag back over it.
	if is_instance_valid(node) and node.has_method("apply_authoritative_stats"):
		node.apply_authoritative_stats(stats)
	emit_signal("stats_changed",uid,stats)

# ------------------------------------------------------------ spawn helpers

## Spawn the authored world (packs, dummies, monoliths). Authority roles only;
## a client in role CLIENT receives these from the server instead.
func spawn_world(world_node: Node3D) -> void:
	attach_world(world_node)
	if not is_authority():
		return
	var director_script = load("res://scripts/world/encounter_director.gd")
	if director_script != null:
		var director = director_script.new()
		director.name = "EncounterDirector"
		world_node.add_child(director)
		director.start(world_node.get_node("Mobs"))

# ------------------------------------------------------------ client replicas

## Local player binding (role CLIENT). The server assigned this uid at join; the
## node stays the client's own predicted body, corrected by reconciliation.
func register_local_player(uid: int, character: Dictionary) -> void:
	local_uid = uid
	var node := local_player_node()
	if node == null:
		return
	if not character.is_empty(): node.restore_character(character)
	record_local_player(uid, node, character)

func record_local_player(uid: int, node: Node3D, character: Dictionary) -> void:
	var peer_id := SimNet.local_peer_id if SimNet != null else 1
	var assigned_map := HPMaps.map_for_point(node.global_position)
	if not pending_map_state.is_empty():
		assigned_map = String(pending_map_state.get("map_id", assigned_map))
	local_map = assigned_map
	entities[uid] = {
		"uid": uid,
		"kind": HPProtocol.Kind.PLAYER,
		"node": node,
		"local": true,
		"replica": true,
		"map_id": assigned_map,
		"zone_id": HPRules.zone_id_for_map(assigned_map, node.global_position),
		"pack_id": 0,
		"revision": 0,
		"dead": false,
		"character_id": int(character.get("id", 0)),
		"level": int(character.get("level", 1)),
		"hp": int(character.get("current_hp", 1)),
		"max_hp": int(character.get("max_hp", 1)),
		"mana": int(character.get("current_mana", 0)),
		"max_mana": int(character.get("max_mana", 0)),
		"exp": int(character.get("exp", 0)),
		"galleons": int(character.get("galleons", 0)),
	}
	by_node[node.get_instance_id()] = uid
	node.set_meta("sim_uid", uid)
	players_by_peer[peer_id] = uid
	if int(character.get("id", 0)) > 0:
		players_by_character[int(character["id"])] = uid

## Client-side: the server assigned this body a map. Stored until the body is
## bound if the world scene does not exist yet, then applied (the map controller
## loads the scene and the body is placed at the server-approved position).
func note_map_state(map_id: String, pos: Vector3, spawn_id: String) -> void:
	pending_map_state = {"map_id": map_id, "spawn_id": spawn_id, "pos": pos}
	if local_uid != 0 and entities.has(local_uid):
		apply_map_state(local_uid, map_id, pos, spawn_id)
	else:
		emit_signal("map_state", map_id, pos, spawn_id)

func apply_map_state(uid: int, map_id: String, pos: Vector3, spawn_id: String) -> void:
	pending_map_state = {"map_id": map_id, "spawn_id": spawn_id, "pos": pos}
	var record: Dictionary = entities.get(uid, {})
	if not record.is_empty():
		var changed := String(record.get("map_id", "")) != map_id
		record["map_id"] = map_id
		touch(record)
		if bool(record.get("local", false)) or uid == local_uid:
			local_map = map_id
			var node = record.get("node")
			if node != null and is_instance_valid(node) and node is Node3D:
				(node as Node3D).global_position = pos
				node.set("velocity", Vector3.ZERO)
			if changed:
				emit_signal("map_changed", uid, map_id, pos)
	emit_signal("map_state", map_id, pos, spawn_id)

var local_uid: int = 0

func local_player_node() -> Node3D:
	if world == null or not is_instance_valid(world):
		return null
	var node = world.get("local_player")
	if node is Node3D and is_instance_valid(node):
		return node
	for candidate in get_tree().get_nodes_in_group("players"):
		if candidate.get("is_local_player") == true:
			return candidate
	return null

## Client-side replica update from a snapshot. Creates the record on first
## sight (presentation is asked to build a view) and refreshes it afterwards.
func upsert_replica(uid: int, kind: int, pos: Vector3, rot_y: float, hp: int, max_hp: int, flags: int, state: int, variant: int = 0, pack_id: int = 0) -> void:
	var record: Dictionary = entities.get(uid, {})
	var is_new := record.is_empty()
	if is_new:
		record = {
			"uid": uid,
			"kind": kind,
			"node": null,
			"replica": true,
			# Everything the server sends a client is on that client's map (the
			# interest filter is map-scoped), so the replica inherits it.
			"map_id": local_map,
			"zone_id": HPRules.zone_id_for(pos),
			"revision": 0,
			"variant": variant,
			"pack_id": pack_id,
			"dead": (flags & HPProtocol.FLAG_DEAD) != 0,
		}
		entities[uid] = record
	var previous_hp := int(record.get("hp", hp))
	var previous_flags := int(record.get("flags", 0))
	var previous_record_dead := bool(record.get("dead", false))
	record["pos"] = pos
	record["rot_y"] = rot_y
	record["hp"] = hp
	record["max_hp"] = max_hp
	record["flags"] = flags
	record["state"] = state
	record["variant"] = variant
	record["pack_id"] = pack_id
	record["dead"] = (flags & HPProtocol.FLAG_DEAD) != 0
	record["mounted"] = (flags & HPProtocol.FLAG_MOUNTED) != 0
	record["casting"] = (flags & HPProtocol.FLAG_CASTING) != 0
	record["warded"] = (flags & HPProtocol.FLAG_WARDED) != 0
	var was_dead := bool(previous_record_dead)
	if is_new:
		emit_signal("entity_replicating", record)
	else:
		emit_signal("entity_moved", uid, pos, rot_y, flags)
	if hp != previous_hp or flags != previous_flags:
		emit_signal("entity_health", uid, hp, max_hp, flags)
	# Death and respawn are read off the replicated flag, so a client that
	# joined late still sees them (it has no event history to replay).
	if record["dead"] and not was_dead:
		emit_signal("entity_died", uid, 0)
	elif was_dead and not record["dead"]:
		emit_signal("entity_respawned", uid)

## A replica the server stopped announcing is gone: forget it, or the client
## accumulates records (and node ids) for entities that no longer exist.
func drop_replica(uid: int) -> void:
	var record: Dictionary = entities.get(uid, {})
	if record.is_empty():
		return
	var node = record.get("node")
	if node != null and is_instance_valid(node):
		by_node.erase((node as Node).get_instance_id())
	entities.erase(uid)

func attach_view_node(uid: int, node: Node3D) -> void:
	if node == null:
		return
	var record: Dictionary = entities.get(uid, {})
	if not record.is_empty():
		record["node"] = node
	by_node[node.get_instance_id()] = uid
	node.set_meta("sim_uid", uid)

func on_loot_event(uid: int, item_id: String, amount: int, pos: Vector3) -> void:
	entities[uid] = {
		"uid": uid,
		"kind": HPProtocol.Kind.LOOT,
		"node": null,
		"replica": true,
		"map_id": local_map,
		"item_id": item_id,
		"amount": amount,
		"pos": pos,
		"dead": false,
	}
	emit_signal("loot_spawned", uid, item_id, amount, pos)

func on_cast_result(cast_seq: int, cast_id: int, ok: bool, reason: String) -> void:
	emit_signal("cast_ack", cast_seq, cast_id, ok, reason)

func on_damage_event(uid: int, amount: int, hp: int, spell_id: String, attacker_uid: int) -> void:
	var record: Dictionary = entities.get(uid, {})
	if record.is_empty():
		return
	var max_hp := int(record.get("max_hp", 0))
	record["hp"] = hp
	_sync_node_health(record)
	emit_signal("entity_damaged", uid, amount, hp, spell_id, attacker_uid)
	emit_signal("entity_health", uid, hp, max_hp, flags_for(record))

func on_death_event(uid: int, killer_uid: int) -> void:
	var record: Dictionary = entities.get(uid, {})
	if record.is_empty():
		return
	record["dead"] = true
	record["hp"] = 0
	_sync_node_health(record)
	emit_signal("entity_died", uid, killer_uid)

func on_respawn_event(uid: int) -> void:
	var record: Dictionary = entities.get(uid, {})
	if record.is_empty():
		return
	record["dead"] = false
	var node = record.get("node")
	if node != null and is_instance_valid(node) and node.has_method("on_authoritative_respawn"):
		node.call("on_authoritative_respawn")
	emit_signal("entity_respawned", uid)

func equipment_snapshot(record: Dictionary) -> Dictionary:
	var node = record.get("node")
	if not is_instance_valid(node): return {}
	return {"inventory": node.inventory.duplicate(true), "equipment": node.equipment.duplicate(true),
		"inventory_revision": node.inventory_revision, "base_max_hp": node.base_max_hp,
		"base_max_mana": node.base_max_mana, "derived_stats": node.derived_stats.duplicate(true)}

func refresh_equipment(record: Dictionary) -> void:
	var node = record.get("node")
	if not is_instance_valid(node): return
	node._recalculate_equipment()
	for key in ["max_hp", "max_mana", "wand_tier", "galleons"]:
		record[key] = node.get(key)
	record["hp"] = node.current_hp
	record["mana"] = node.current_mana
	record["defense"] = node.derived_stats.defense
	record["weapon_multiplier"] = node.derived_stats.weapon_multiplier

func request_equipment(peer_id: int, request_id: int, revision: int, operation: String, slot: String, item_id: String, tier: int) -> Dictionary:
	var record := player_record(peer_id)
	if not is_authority() or record.is_empty(): return {"ok": false, "reason": "invalid_state", "request_id": request_id}
	var node = record.get("node")
	if not is_instance_valid(node): return {"ok": false, "reason": "invalid_state", "request_id": request_id}
	var previous: Dictionary = record.get("equipment_reply", {})
	if request_id == int(previous.get("request_id", -1)): return previous
	if request_id <= int(record.get("equipment_seq", -1)):
		return {"ok": false, "reason": "stale_request", "request_id": request_id, "snapshot": build_stats(record)}
	var reason := ""
	if mutations_frozen() or bool(record.get("persistence_conflict", false)): reason = "invalid_state"
	elif revision != node.inventory_revision: reason = "stale_inventory"
	elif bool(record.get("dead", false)): reason = "dead"
	elif int(record.get("pending_transfer", 0)) != 0: reason = "transfer_pending"
	elif int(record.get("cast_id", 0)) != 0 or sim_tick < int(record.get("cast_lock_until_tick", 0)): reason = "casting"
	elif operation != "consume" and sim_tick - int(record.get("last_combat_tick", -100000)) < 5 * HPProtocol.SIM_HZ: reason = "in_combat"
	elif slot == "broom" and bool(record.get("mounted", false)): reason = "mounted"
	var result := {"ok": false, "reason": reason}
	if reason == "":
		if operation in ["equip", "unequip"]:
			result = HPEquipment.swap(node.inventory, node.equipment, slot, item_id if operation == "equip" else "", tier)
		elif operation == "refine":
			result = _refine_equipped(node)
		elif operation == "consume":
			result = _consume_item(node, item_id, tier)
		else:
			result.reason = "invalid_operation"
		if bool(result.ok):
			if result.has("inventory"): node.inventory.assign(result.inventory)
			if result.has("equipment"): node.equipment = result.equipment
			node.inventory_revision += 1
			refresh_equipment(record)
			touch(record)
			node.inventory_changed.emit()
			node.equipment_changed.emit()
			_push_stats(record)
			if persistence != null: persistence.save_player(record)
	result["request_id"] = request_id
	result["snapshot"] = build_stats(record)
	record["equipment_seq"] = maxi(request_id, int(record.get("equipment_seq", -1)))
	record["equipment_reply"] = result.duplicate(true)
	return result

func _consume_item(node: Node, item_id: String, tier: int) -> Dictionary:
	if item_id not in ["potion_health", "potion_mana"]:
		return {"ok": false, "reason": "invalid_operation"}
	var hp := item_id == "potion_health"
	var current := int(node.current_hp if hp else node.current_mana)
	var maximum := int(node.max_hp if hp else node.max_mana)
	if current >= maximum: return {"ok": false, "reason": "resource_full"}
	var bag: Array = node.inventory.duplicate(true)
	if not HPEquipment.take(bag, item_id, tier): return {"ok": false, "reason": "item_missing"}
	var restored := mini(maximum - current, int(HPEquipment.item(item_id).get("heal_hp" if hp else "heal_mana", 150 if hp else 120)))
	if hp: node.current_hp += restored
	else: node.current_mana += restored
	return {"ok": true, "reason": "consumed", "inventory": bag, "restored": restored}

func _refine_equipped(node: Node) -> Dictionary:
	var wand: Dictionary = node.equipment.get("main_hand", {})
	if wand.is_empty(): return {"ok": false, "reason": "no_wand"}
	var tier := int(wand.get("tier", 0))
	if tier >= 9: return {"ok": false, "reason": "max_tier"}
	var spec: Dictionary = HPRules.combat().wand_tiers[tier]
	if node.galleons < int(spec.cost): return {"ok": false, "reason": "no_gold"}
	var bag: Array = node.inventory.duplicate(true)
	if not HPEquipment.take(bag, spec.material_id, 0, int(spec.material_amount)):
		return {"ok": false, "reason": "no_material"}
	var gear: Dictionary = node.equipment.duplicate(true)
	var success := rng.randf() * 100.0 < float(spec.chance)
	gear.main_hand.tier = tier + 1 if success else (tier - 1 if tier >= 4 else tier)
	node.galleons -= int(spec.cost)
	return {"ok": true, "reason": "refined" if success else "refinement_failed", "inventory": bag, "equipment": gear}
