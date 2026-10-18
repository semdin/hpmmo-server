extends Node

## QuestManager — the client's VIEW of the quest chain. The chain itself is
## server-owned data (HPRules.quest_chain, addons/hpmmo_sim/data/quests.json)
## and every bit of progress is decided by the authority (SimAuthority
## quest_event: kill credit, refinement, range-checked talk, the body's own
## position). This node only mirrors the bound player's `quest_active` /
## `quest_progress`, which arrive with the stats payload in every role, and
## turns changes into UI signals. Rewards (EXP, Galleons, house reputation)
## are paid by the authority with the completion.

signal quest_updated
signal quest_completed(quest_id: String)

const LEGACY_SAVE := "user://hpmmo_save.json"
const LEGACY_SAVE_OLD := "user://pottermetin_save.json"

var active_index: int = 0
var progress: int = 0
var player_ref: Node3D = null
## Tests switch this off so the pre-authority local quest file is never read.
var persistence_enabled := true
var _synced := false
var _level := 0

func quests() -> Array:
	return HPRules.quest_chain()

func current_quest() -> Dictionary:
	return HPRules.quest_at(active_index)

func is_all_done() -> bool:
	return active_index >= quests().size()

## The level the current quest waits for, or 0 when it can be worked now.
func level_needed() -> int:
	var need := int(current_quest().get("level", 1))
	var have := int(player_ref.level) if is_instance_valid(player_ref) else 1
	return need if need > have else 0

## "Max Health Potion x5, Woolen Traveller's Cloak" for a quest's item rewards.
static func reward_items_text(q: Dictionary) -> String:
	var parts: Array = []
	for reward in q.get("reward_items", []):
		var name := String(HPEquipment.item(String(reward.get("id", ""))).get("name", reward.get("id", "")))
		parts.append(name if int(reward.get("amount", 1)) <= 1 else "%s x%d" % [name, int(reward.get("amount", 1))])
	return ", ".join(parts)

func bind_player(p: Node3D) -> void:
	if is_instance_valid(player_ref) and player_ref.stats_changed.is_connected(_on_player_stats):
		player_ref.stats_changed.disconnect(_on_player_stats)
	player_ref = p
	_synced = false
	if is_instance_valid(p) and not p.stats_changed.is_connected(_on_player_stats):
		p.stats_changed.connect(_on_player_stats)
	_sync()

func _on_player_stats(_hp: int, _max_hp: int, _mana: int, _max_mana: int, _exp: int, _max_exp: int, _level: int) -> void:
	_sync()

## Mirror the body's chain position. The first read after binding is a load,
## not a completion; afterwards every step forward announces the quests passed.
func _sync() -> void:
	if not is_instance_valid(player_ref):
		return
	var index := int(player_ref.quest_active)
	var count := int(player_ref.quest_progress)
	var level := int(player_ref.level)
	if _synced and index == active_index and count == progress and level == _level:
		return
	_level = level   # a level-up can unlock the waiting quest
	var previous := active_index
	var announce := _synced and index > previous
	active_index = index
	progress = count
	_synced = true
	if announce:
		for i in range(previous, index):
			emit_signal("quest_completed", String(HPRules.quest_at(i).get("id", "")))
		if has_node("/root/AudioManager"):
			get_node("/root/AudioManager").play_quest()
	emit_signal("quest_updated")

func tracker_text() -> String:
	if is_all_done():
		return "All quests complete! You are a true graduate."
	var q: Dictionary = current_quest()
	if level_needed() > 0:
		return "[%s]\nReach level %d to begin" % [q["title"], level_needed()]
	return "[%s]\n%s\n(%d/%d)" % [q["title"], q["name"], mini(progress, int(q["count"])), int(q["count"])]

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
	return {"active": int(legacy.get("active", 0)), "progress": int(legacy.get("progress", 0)),
		"done": legacy.get("done", []) if legacy.get("done") is Array else []}
