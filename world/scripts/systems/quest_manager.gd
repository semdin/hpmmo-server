extends Node

## QuestManager — real MMORPG quest progression: intro chain, monolith hunts,
## mob slaying, wand refinement, broom trial. Persists to user://save.json.

signal quest_updated
signal quest_completed(quest_id: String)

const QUESTS := [
	{
		"id": "welcome",
		"title": "First-Year Orientation",
		"name": "Speak with Professor Fig in the courtyard",
		"desc": "Find Professor Fig near the fountain (gold ! marker).",
		"type": "talk", "target": "Professor Fig", "count": 1,
		"reward_exp": 120, "reward_gold": 150,
	},
	{
		"id": "rats",
		"title": "Acromantula Infestation",
		"name": "Defeat 4 Acromantulas",
		"desc": "Giant spiders nest west of the castle. Thin them out.",
		"type": "kill", "target": "Acromantula", "count": 4,
		"reward_exp": 350, "reward_gold": 300,
	},
	{
		"id": "inferi",
		"title": "Restless Inferi",
		"name": "Defeat 4 Inferi",
		"desc": "Inferi stalk the forest edge. Burn them — fire hurts them double.",
		"type": "kill", "target": "Inferi", "count": 4,
		"reward_exp": 400, "reward_gold": 350,
	},
	{
		"id": "monolith",
		"title": "Shatter the Darkness",
		"name": "Help destroy 1 Dark Monolith",
		"desc": "Join others at a Dark Monolith (purple beam) and break it.",
		"type": "monolith", "target": "Dark Monolith", "count": 1,
		"reward_exp": 900, "reward_gold": 800,
	},
	{
		"id": "refine",
		"title": "Ollivander's Favor",
		"name": "Refine your wand to +2",
		"desc": "Visit Ollivander's Forge (press O) and refine twice.",
		"type": "refine", "target": "wand", "count": 2,
		"reward_exp": 300, "reward_gold": 250,
	},
	{
		"id": "broom",
		"title": "Quidditch Tryouts",
		"name": "Mount your broom and visit the Quidditch Pitch",
		"desc": "Press Shift to mount, then fly to the golden hoops east.",
		"type": "visit", "target": "Quidditch Pitch", "count": 1,
		"reward_exp": 350, "reward_gold": 300,
	},
]

var active_index: int = 0
var progress: int = 0
var done_ids: Array = []
var player_ref: Node3D = null
var persistence_enabled := true

func _ready() -> void:
	load_progress()

func current_quest() -> Dictionary:
	if active_index < QUESTS.size():
		return QUESTS[active_index]
	return {}

func is_all_done() -> bool:
	return active_index >= QUESTS.size()

func bind_player(p: Node3D) -> void:
	player_ref = p
	emit_signal("quest_updated")

func add_kill(mob_name: String) -> void:
	if is_all_done():
		return
	var q: Dictionary = current_quest()
	if q.get("type") == "kill" and q.get("target") == mob_name:
		progress += 1
		_check_complete()

func add_talk(npc_name: String) -> void:
	if is_all_done():
		return
	var q: Dictionary = current_quest()
	if q.get("type") == "talk" and q.get("target") == npc_name:
		progress += 1
		_check_complete()

func add_monolith() -> void:
	if is_all_done():
		return
	var q: Dictionary = current_quest()
	if q.get("type") == "monolith":
		progress += 1
		_check_complete()

func add_refine() -> void:
	if is_all_done():
		return
	var q: Dictionary = current_quest()
	if q.get("type") == "refine":
		progress += 1
		_check_complete()

func add_visit(place: String) -> void:
	if is_all_done():
		return
	var q: Dictionary = current_quest()
	if q.get("type") == "visit" and q.get("target") == place:
		progress += 1
		_check_complete()

func _check_complete() -> void:
	var q: Dictionary = current_quest()
	if progress >= int(q.get("count", 1)):
		done_ids.append(q["id"])
		emit_signal("quest_completed", q["id"])
		if is_instance_valid(player_ref):
			player_ref.add_exp(int(q["reward_exp"]))
			player_ref.galleons += int(q["reward_gold"])
			if player_ref.has_method("emit_stats"):
				player_ref.emit_stats()
		if has_node("/root/AudioManager"):
			get_node("/root/AudioManager").play_quest()
		active_index += 1
		progress = 0
		save_progress()
	emit_signal("quest_updated")
	save_progress()

func tracker_text() -> String:
	if is_all_done():
		return "All quests complete! You are a true graduate."
	var q: Dictionary = current_quest()
	return "[%s]\n%s\n(%d/%d)" % [q["title"], q["name"], mini(progress, int(q["count"])), int(q["count"])]

func save_progress() -> void:
	if not persistence_enabled:
		return
	var f := FileAccess.open("user://hpmmo_save.json", FileAccess.WRITE)
	if f:
		f.store_string(JSON.stringify({"active": active_index, "progress": progress, "done": done_ids}))

func load_progress() -> void:
	var path_to_load := "user://hpmmo_save.json"
	if not FileAccess.file_exists(path_to_load) and FileAccess.file_exists("user://pottermetin_save.json"):
		path_to_load = "user://pottermetin_save.json"
	if not FileAccess.file_exists(path_to_load):
		return
	var f := FileAccess.open(path_to_load, FileAccess.READ)
	if f:
		var d: Dictionary = JSON.parse_string(f.get_as_text())
		if d.has("active"):
			active_index = int(d["active"])
		if d.has("progress"):
			progress = int(d["progress"])
		if d.has("done"):
			done_ids = d["done"]
