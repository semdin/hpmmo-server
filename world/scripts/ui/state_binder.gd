extends Node
class_name UIStateBinder

## Phase 13: the single subscription point between the authoritative state model
## and the HUD (plan.md Phase 13, task 1).
##
## Everything the HUD shows as gameplay state flows through here:
##   * `SimAuthority.stats_changed(uid, stats)` - the server's stat payload
##     (hp, max_hp, mana, max_mana, exp, max_exp, level, galleons, dead,
##     mounted). This is the primary source; it arrives both in the authority
##     roles (simulated in-process) and on a pure client (replicated).
##   * the local body's `stats_changed` - the stat MIRROR the authority writes
##     through `apply_authoritative_stats`. It carries the same numbers and is
##     what a HUD-only test can drive without a live simulation.
##   * entity deltas: `entity_health` (target frame), `entity_damaged`,
##     `entity_died` / `entity_respawned` (death and respawn state),
##     `cast_started` / `cast_released` / `cast_ack` (cast progress and
##     rejection reasons), `reward_granted` / `loot_taken` / `level_changed`
##     (loot and XP feedback), `maintenance_event`, `map_changed`.
##
## Lifecycle: `bind(player)` connects, `unbind()` disconnects, and the node
## disconnects on tree exit. Every connection is guarded by `is_connected`, and
## `listener_report()` returns the live connection counts for the checks that
## prove no stale duplicate listeners survive a death, a relog or a transfer.

signal stats_applied(stats: Dictionary)
signal target_changed(target: Object)
signal target_health_changed(uid: int, hp: int, max_hp: int)
signal death_changed(dead: bool)
signal mounted_changed(mounted: bool)
signal cast_started(cast_id: int, spell_id: String, release_tick: int)
signal cast_released(cast_id: int, spell_id: String)
signal cast_rejected(cast_seq: int, spell_id: String, reason: String)
signal damage_taken(amount: int, hp: int, max_hp: int, spell_id: String)
signal reward_granted(exp: int, galleons: int, items: Array)
signal loot_taken(item_id: String, amount: int)
signal level_changed(level: int)
signal maintenance_event(state: String, reason: String, seconds_remaining: int)
signal map_changed(uid: int, map_id: String, pos: Vector3)
signal bound(player: Node3D)

## Rebound with the local body: connected on `bind`, disconnected on `unbind`.
const AUTHORITY_SIGNALS := [
	"stats_changed", "entity_health", "entity_damaged", "entity_died",
	"entity_respawned", "cast_started", "cast_released", "cast_ack",
	"reward_granted", "loot_taken", "level_changed", "map_changed",
]
const PLAYER_SIGNALS := ["stats_changed", "target_changed", "mounted_changed"]
## Role-wide channels: connected once for the life of the node, in every role,
## bound player or not (a maintenance announcement must reach a player even
## before, between or after a body exists).
const PERSISTENT_SIGNALS := ["maintenance_event"]

var player: Node3D = null
var target: Object = null
var dead := false
var mounted := false
## Sequence of applied stat payloads (evidence the UI saw every transition).
var stat_updates: int = 0
## Set when a connect found an existing connection: a duplicate was refused.
var duplicate_connects: int = 0
var last_rejection_reason := ""
var last_rejection_spell := ""
## Every rejection seen, newest last (bounded).
var rejections: Array = []

var _target_uid: int = 0
var _target_hp: int = 0
var _target_max_hp: int = 0
var _has_target_health := false
var _subscribed := false

func _ready() -> void:
	# The maintenance channel exists in every role, bound player or not: a live
	# player must see the countdown before the world closes on them.
	for entry in PERSISTENT_SIGNALS:
		_connect_signal(SimAuthority, entry, _on_maintenance_event)

func _exit_tree() -> void:
	unbind()

## ------------------------------------------------------------------- binding

func bind(p_player: Node3D) -> void:
	if player == p_player and _subscribed:
		_refresh_from_mirror()
		return
	unbind()
	player = p_player
	if player == null or not is_instance_valid(player):
		return
	_target_uid = _uid_of(target)
	_connect_signal(SimAuthority, "stats_changed", _on_authority_stats)
	_connect_signal(SimAuthority, "entity_health", _on_entity_health)
	_connect_signal(SimAuthority, "entity_damaged", _on_entity_damaged)
	_connect_signal(SimAuthority, "entity_died", _on_entity_died)
	_connect_signal(SimAuthority, "entity_respawned", _on_entity_respawned)
	_connect_signal(SimAuthority, "cast_started", _on_cast_started)
	_connect_signal(SimAuthority, "cast_released", _on_cast_released)
	_connect_signal(SimAuthority, "cast_ack", _on_cast_ack)
	_connect_signal(SimAuthority, "reward_granted", _on_reward_granted)
	_connect_signal(SimAuthority, "loot_taken", _on_loot_taken)
	_connect_signal(SimAuthority, "level_changed", _on_level_changed)
	_connect_signal(SimAuthority, "map_changed", _on_map_changed)
	if player.has_signal("stats_changed"):
		_connect_signal(player, "stats_changed", _on_player_stats)
	if player.has_signal("target_changed"):
		_connect_signal(player, "target_changed", _on_player_target)
	if player.has_signal("mounted_changed"):
		_connect_signal(player, "mounted_changed", _on_player_mounted)
	_subscribed = true
	_refresh_from_mirror()
	bound.emit(player)

func unbind() -> void:
	for entry in AUTHORITY_SIGNALS:
		_disconnect_signal(SimAuthority, entry)
	if player != null and is_instance_valid(player):
		for entry in PLAYER_SIGNALS:
			_disconnect_signal(player, entry)
	_subscribed = false
	player = null

## Re-read the mirror node so a freshly bound HUD is never blank.
func _refresh_from_mirror() -> void:
	if player == null or not is_instance_valid(player):
		return
	var stats := {
		"uid": local_uid(),
		"source": "mirror",
		"hp": int(player.get("current_hp")),
		"max_hp": int(player.get("max_hp")),
		"mana": int(player.get("current_mana")),
		"max_mana": int(player.get("max_mana")),
		"exp": int(player.get("current_exp")),
		"max_exp": int(player.get("max_exp")),
		"level": int(player.get("level")),
		"galleons": int(player.get("galleons")),
		"dead": bool(player.get("is_dead")),
		"mounted": bool(player.get("is_mounted")),
	}
	_apply_stats(stats, true)

## ------------------------------------------------------------------ helpers

func local_uid() -> int:
	if player != null and is_instance_valid(player):
		var uid := int(player.get_meta("sim_uid", 0))
		if uid != 0:
			return uid
	if int(SimNet.local_uid) != 0:
		return int(SimNet.local_uid)
	return int(SimAuthority.local_uid)

func _uid_of(node: Object) -> int:
	if node is Node and is_instance_valid(node):
		return int((node as Node).get_meta("sim_uid", 0))
	return 0

func record_for_local() -> Dictionary:
	if int(SimNet.local_uid) != 0:
		var by_uid: Dictionary = SimAuthority.record_by_uid(int(SimNet.local_uid))
		if not by_uid.is_empty():
			return by_uid
	if player != null and is_instance_valid(player):
		return SimAuthority.record_for(player)
	return {}

func _connect_signal(source: Object, signal_name: String, handler: Callable) -> void:
	if source == null or not source.has_signal(signal_name):
		return
	if source.is_connected(signal_name, handler):
		duplicate_connects += 1
		return
	source.connect(signal_name, handler)

func _disconnect_signal(source: Object, signal_name: String) -> void:
	if source == null or not is_instance_valid(source) or not source.has_signal(signal_name):
		return
	for connection in source.get_signal_connection_list(signal_name):
		var callable: Callable = connection["callable"]
		if callable.get_object() == self:
			source.disconnect(signal_name, callable)

## ------------------------------------------------------------------ handlers

func _on_authority_stats(uid: int, stats: Dictionary) -> void:
	if uid != local_uid():
		return
	stats["source"] = "authority"
	_apply_stats(stats, false)

func _on_player_stats(hp: int, max_hp: int, mana: int, max_mana: int, exp: int, max_exp: int, level: int) -> void:
	if player == null or not is_instance_valid(player):
		return
	# The mirror's own signal: same payload shape as the authority's, plus the
	# fields the mirror node owns (currency, mount, life state) so a HUD-only
	# flow still ends with the full picture.
	var stats := {
		"uid": local_uid(),
		"source": "mirror",
		"hp": hp, "max_hp": max_hp,
		"mana": mana, "max_mana": max_mana,
		"exp": exp, "max_exp": max_exp,
		"level": level,
		"galleons": int(player.get("galleons")),
		"dead": bool(player.get("is_dead")),
		"mounted": bool(player.get("is_mounted")),
	}
	_apply_stats(stats, false)

func _apply_stats(stats: Dictionary, quiet: bool) -> void:
	stat_updates += 1
	var was_dead := dead
	var was_mounted := mounted
	dead = bool(stats.get("dead", dead))
	mounted = bool(stats.get("mounted", mounted))
	stats_applied.emit(stats)
	if was_dead != dead:
		death_changed.emit(dead)
	if was_mounted != mounted:
		mounted_changed.emit(mounted)

func _on_entity_health(uid: int, hp: int, max_hp: int, _flags: int) -> void:
	# Only the target frame consumes health deltas here: the local body's own
	# numbers arrive as a stat payload (which also carries max/level/currency),
	# and this layer never writes gameplay state back onto the mirror node.
	if uid != 0 and uid == _target_uid:
		_target_hp = hp
		_target_max_hp = max_hp
		_has_target_health = true
		target_health_changed.emit(uid, hp, max_hp)

func _on_entity_damaged(uid: int, amount: int, hp: int, spell_id: String, attacker_uid: int) -> void:
	if uid == local_uid():
		damage_taken.emit(amount, hp, max(1, int(player.get("max_hp"))), spell_id)
	elif uid == _target_uid:
		_target_hp = hp
		_has_target_health = true
		target_health_changed.emit(uid, hp, _target_max_hp)

func _on_entity_died(uid: int, _killer_uid: int) -> void:
	if uid == local_uid() and not dead:
		dead = true
		death_changed.emit(true)

func _on_entity_respawned(uid: int) -> void:
	if uid == local_uid() and dead:
		dead = false
		death_changed.emit(false)

func _on_cast_started(uid: int, cast_id: int, spell_id: String, _aim: Vector3, release_tick: int) -> void:
	if uid != local_uid():
		return
	cast_started.emit(cast_id, spell_id, release_tick)

func _on_cast_released(cast_id: int, caster_uid: int, spell_id: String, _origin: Vector3, _dir: Vector3) -> void:
	if caster_uid != local_uid():
		return
	cast_released.emit(cast_id, spell_id)

func _on_cast_ack(cast_seq: int, _cast_id: int, ok: bool, reason: String) -> void:
	if ok:
		return
	var spell_id := ""
	if player != null and is_instance_valid(player):
		var predicted = player.get("_predicted_casts")
		if predicted is Dictionary and predicted.has(cast_seq):
			spell_id = String((predicted[cast_seq] as Dictionary).get("spell_id", ""))
	last_rejection_reason = reason
	last_rejection_spell = spell_id
	rejections.append({"spell": spell_id, "reason": reason})
	if rejections.size() > 16:
		rejections.pop_front()
	cast_rejected.emit(cast_seq, spell_id, reason)

func _on_reward_granted(uid: int, _character_id: int, exp: int, galleons: int, items: Array, _op_id: String) -> void:
	if uid != local_uid():
		return
	reward_granted.emit(exp, galleons, items)

func _on_loot_taken(_uid: int, character_id: int, item_id: String, amount: int, _collector_peer_id: int = 0) -> void:
	# Loot pickups are broadcast for every player on the map; only the local
	# character's own pickup is UI feedback.
	if character_id != local_character_id():
		return
	loot_taken.emit(item_id, amount)

func local_character_id() -> int:
	var id := int(NetworkManager.local_character_data.get("id", 0))
	if id != 0:
		return id
	return int(record_for_local().get("character_id", 0))

func _on_level_changed(uid: int, level: int) -> void:
	if uid != local_uid():
		return
	level_changed.emit(level)

func _on_maintenance_event(state: String, reason: String, seconds_remaining: int) -> void:
	maintenance_event.emit(state, reason, seconds_remaining)

func _on_map_changed(uid: int, map_id: String, pos: Vector3) -> void:
	if uid != local_uid():
		return
	map_changed.emit(uid, map_id, pos)

func _on_player_target(p_target: Object) -> void:
	target = p_target
	_target_uid = _uid_of(p_target)
	_has_target_health = false
	if p_target is Node3D and is_instance_valid(p_target) and "current_hp" in p_target:
		_target_hp = int(p_target.get("current_hp"))
		_target_max_hp = int(p_target.get("max_hp"))
		_has_target_health = true
	target_changed.emit(p_target)

func _on_player_mounted(is_mounted: bool) -> void:
	if mounted == is_mounted:
		return
	mounted = is_mounted
	mounted_changed.emit(is_mounted)

## --------------------------------------------------------------- target api

func has_target_health() -> bool:
	return _has_target_health and _target_uid != 0

func target_uid() -> int:
	return _target_uid

func target_hp() -> int:
	return _target_hp

func target_max_hp() -> int:
	return _target_max_hp

## --------------------------------------------------------- listener evidence

## Live connection count for one of our subscriptions.
func listener_count(signal_name: String) -> int:
	var total := 0
	if SimAuthority.has_signal(signal_name):
		total += _count_for(SimAuthority, signal_name)
	if player != null and is_instance_valid(player) and player.has_signal(signal_name):
		total += _count_for(player, signal_name)
	return total

func _count_for(source: Object, signal_name: String) -> int:
	var count := 0
	for connection in source.get_signal_connection_list(signal_name):
		if connection["callable"].get_object() == self:
			count += 1
	return count

## Every subscription this binder currently holds, for the leak checks: after a
## death, a relog or a transfer the totals must not grow.
func listener_report() -> Dictionary:
	var report := {}
	var total := 0
	for entry in PERSISTENT_SIGNALS + AUTHORITY_SIGNALS:
		var count := _count_for(SimAuthority, entry)
		if count > 0:
			report["SimAuthority.%s" % entry] = count
		total += count
	if player != null and is_instance_valid(player):
		for entry in PLAYER_SIGNALS:
			if not player.has_signal(entry):
				continue
			var count := _count_for(player, entry)
			if count > 0:
				report["player.%s" % entry] = count
			total += count
	report["total"] = total
	return report

func listener_total() -> int:
	return int(listener_report().get("total", 0))
