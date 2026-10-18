extends Node

## QuestManager — the client's VIEW of the quest log. The quests themselves are
## server-owned data (HPRules.quest_chain, addons/hpmmo_sim/data/quests.json)
## and every bit of progress is decided by the authority (SimAuthority
## quest_event: kill credit, refinement, range-checked talk, the body's own
## position). This node mirrors the bound player's log - `quest_progress`
## ({id: count}), `quest_ready` (finished, waiting to be claimed) and
## `quest_done` (claimed) - which arrive with the stats payload in every role,
## and turns changes into UI signals and sounds. Several quests are open at
## once (HPRules.quests_open); a finished one pays only when it is claimed.
##
## "New" is a view-only flag: a quest the player has not opened yet. It is kept
## per character under user:// so the blink survives a relog.

signal quest_updated
## A quest was claimed (the reward is paid).
signal quest_completed(quest_id: String)
## A quest reached its count and waits to be claimed.
signal quest_ready(quest_id: String)
## A quest opened (level reached, prerequisite claimed).
signal quest_new(quest_id: String)

const LEGACY_SAVE := "user://hpmmo_save.json"
const LEGACY_SAVE_OLD := "user://pottermetin_save.json"
const SEEN_PATH := "user://quest_seen.json"

var player_ref: Node3D = null
## Tests switch this off so the pre-authority local quest file is never read.
var persistence_enabled := true
var _synced := false
var _open_ids: Array = []
var _ready_ids: Array = []
var _done_ids: Array = []
var _level := 0
var _progress_key := ""
var _seen: Array = []

func bind_player(p: Node3D) -> void:
	if is_instance_valid(player_ref) and player_ref.stats_changed.is_connected(_on_player_stats):
		player_ref.stats_changed.disconnect(_on_player_stats)
	player_ref = p
	_synced = false
	_seen = _load_seen()
	if is_instance_valid(p) and not p.stats_changed.is_connected(_on_player_stats):
		p.stats_changed.connect(_on_player_stats)
	_sync()

func _on_player_stats(_hp: int, _max_hp: int, _mana: int, _max_mana: int, _exp: int, _max_exp: int, _level_now: int) -> void:
	_sync()

# ------------------------------------------------------------------ queries

func quests() -> Array:
	return HPRules.quest_chain()

## Open quests (not finished yet), in chain order.
func open_quests() -> Array:
	if not is_instance_valid(player_ref):
		return []
	return HPRules.quests_open(int(player_ref.level), player_ref.quest_done, player_ref.quest_ready)

## The log as the UI shows it: finished quests waiting for their reward first,
## then new (unread) ones, then the rest, each in chain order.
func log_entries() -> Array:
	var ready: Array = []
	var fresh: Array = []
	var rest: Array = []
	if not is_instance_valid(player_ref):
		return []
	for id in player_ref.quest_ready:
		var q := HPRules.quest_by_id(String(id))
		if not q.is_empty():
			ready.append(q)
	for q in open_quests():
		(fresh if is_new(String(q.get("id", ""))) else rest).append(q)
	return ready + fresh + rest

func progress_of(quest_id: String) -> int:
	if not is_instance_valid(player_ref):
		return 0
	if is_ready(quest_id):
		return int(HPRules.quest_by_id(quest_id).get("count", 1))
	return int(player_ref.quest_progress.get(quest_id, 0))

func is_ready(quest_id: String) -> bool:
	return is_instance_valid(player_ref) and player_ref.quest_ready.has(quest_id)

func is_new(quest_id: String) -> bool:
	return not _seen.has(quest_id) and not is_ready(quest_id)

## True while anything in the log wants attention (a reward or an unread quest).
func needs_attention() -> bool:
	if is_instance_valid(player_ref) and not player_ref.quest_ready.is_empty():
		return true
	for q in open_quests():
		if is_new(String(q.get("id", ""))):
			return true
	return false

func done_count() -> int:
	return player_ref.quest_done.size() if is_instance_valid(player_ref) else 0

func is_all_done() -> bool:
	return log_entries().is_empty()

## The quest the old single-quest views show: the top of the log.
func current_quest() -> Dictionary:
	var entries := log_entries()
	return entries[0] if not entries.is_empty() else {}

## "Defeat 6 Acromantulas  3/6" - the objective with its live count.
func objective_text(q: Dictionary) -> String:
	var id := String(q.get("id", ""))
	if is_ready(id):
		return "Complete! Click to claim your reward"
	var count := int(q.get("count", 1))
	if count <= 1:
		return String(q.get("name", ""))
	return "%s  %d/%d" % [String(q.get("name", "")), mini(progress_of(id), count), count]

## "Woolen Traveller's Cloak, Health Potion x5" for a quest's item rewards.
static func reward_items_text(q: Dictionary) -> String:
	var parts: Array = []
	for reward in q.get("reward_items", []):
		var name := String(HPEquipment.item(String(reward.get("id", ""))).get("name", reward.get("id", "")))
		parts.append(name if int(reward.get("amount", 1)) <= 1 else "%s x%d" % [name, int(reward.get("amount", 1))])
	return ", ".join(parts)

func tracker_text() -> String:
	var q := current_quest()
	if q.is_empty():
		return "No open quests - level up to unlock more."
	return "[%s]\n%s" % [q.get("title", ""), objective_text(q)]

# ------------------------------------------------------------------ actions

## Ask the authority for a finished quest's reward.
func claim(quest_id: String) -> void:
	if is_instance_valid(player_ref) and is_ready(quest_id):
		SimNet.submit_quest_claim(player_ref, quest_id)

## The player opened (read) a quest: it stops blinking.
func mark_seen(quest_id: String) -> void:
	if quest_id == "" or _seen.has(quest_id):
		return
	_seen.append(quest_id)
	_save_seen()
	emit_signal("quest_updated")

# ------------------------------------------------------------------ mirroring

## Mirror the body's log. The first read after binding is a load, not news;
## afterwards a quest that appears is new, one that moves to `ready` finished,
## one that moves to `done` was claimed.
func _sync() -> void:
	if not is_instance_valid(player_ref):
		return
	var open_ids: Array = open_quests().map(func(q): return String(q.get("id", "")))
	var ready_ids: Array = (player_ref.quest_ready as Array).duplicate()
	var done_ids: Array = (player_ref.quest_done as Array).duplicate()
	var key := str(player_ref.quest_progress)
	var level := int(player_ref.level)
	if _synced and open_ids == _open_ids and ready_ids == _ready_ids and done_ids == _done_ids \
			and key == _progress_key and level == _level:
		return
	var announce := _synced
	var fresh := open_ids.filter(func(id): return not _open_ids.has(id))
	var finished := ready_ids.filter(func(id): return not _ready_ids.has(id))
	var claimed := done_ids.filter(func(id): return not _done_ids.has(id))
	_open_ids = open_ids
	_ready_ids = ready_ids
	_done_ids = done_ids
	_progress_key = key
	_level = level
	_synced = true
	if announce:
		for id in claimed:
			emit_signal("quest_completed", String(id))
		for id in finished:
			emit_signal("quest_ready", String(id))
		for id in fresh:
			emit_signal("quest_new", String(id))
		var audio := get_node_or_null("/root/AudioManager")
		if audio != null:
			if not finished.is_empty():
				audio.play_sound_at("ui_quest_complete", Vector3.ZERO, null, true)
			elif not fresh.is_empty():
				audio.play_sound_at("ui_quest", Vector3.ZERO, null, true)
	emit_signal("quest_updated")

# ------------------------------------------------------------------ "new" flags

func _seen_key() -> String:
	if not is_instance_valid(player_ref):
		return ""
	var name = player_ref.get("player_name")
	return String(name) if name != null else ""

func _load_seen() -> Array:
	if not persistence_enabled or not FileAccess.file_exists(SEEN_PATH):
		return []
	var parsed: Variant = JSON.parse_string(FileAccess.get_file_as_string(SEEN_PATH))
	if parsed is Dictionary and (parsed as Dictionary).get(_seen_key()) is Array:
		return (parsed[_seen_key()] as Array).duplicate()
	return []

func _save_seen() -> void:
	if not persistence_enabled or _seen_key() == "":
		return
	var all: Dictionary = {}
	if FileAccess.file_exists(SEEN_PATH):
		var parsed: Variant = JSON.parse_string(FileAccess.get_file_as_string(SEEN_PATH))
		if parsed is Dictionary:
			all = parsed
	all[_seen_key()] = _seen
	var file := FileAccess.open(SEEN_PATH, FileAccess.WRITE)
	if file != null:
		file.store_string(JSON.stringify(all))

## The quest file offline play wrote before quests moved to the authority
## ({active, progress, done}), or {} when there is none. Read once, at offline
## character restore, to carry old progress into the character.
func legacy_progress() -> Dictionary:
	if not persistence_enabled:
		return {}
	var path := LEGACY_SAVE if FileAccess.file_exists(LEGACY_SAVE) else LEGACY_SAVE_OLD
	if not FileAccess.file_exists(path):
		return {}
	var parsed: Variant = JSON.parse_string(FileAccess.get_file_as_string(path))
	if not (parsed is Dictionary) or not (parsed as Dictionary).has("active"):
		return {}
	var legacy: Dictionary = parsed
	return {"done": legacy.get("done", []) if legacy.get("done") is Array else []}
