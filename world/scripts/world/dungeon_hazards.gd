extends Node3D

## The weekly curses' ground hazards in the local player's dungeon copy
## (SimAuthority.dungeon_hazard, protocol v30), drawn with the boss warning
## effect: a ring that fills to its release tick and bursts (Bursting Dead,
## Storm Rain), or a held patch until it fades (Sticky Ground, the Queen's
## venom pools). Presentation only - the dungeon director resolves every
## hazard on the authority's clock.

const WARNING := preload("res://scenes/spells/fx_boss_warning.tscn")
const TINTS := {
	"burst": Color(1.0, 0.45, 0.12),
	"storm": Color(0.55, 0.75, 1.0),
	"sticky": Color(0.85, 0.85, 0.78),
	"pool": Color(0.55, 0.95, 0.2),
}

var _live: Array = []   # [{fx, data}]

func _ready() -> void:
	name = "DungeonHazards"
	SimAuthority.dungeon_hazard.connect(_on_hazard)

func _local_map() -> String:
	return String(SimAuthority.record_by_uid(SimAuthority.local_uid).get("map_id", ""))

func _on_hazard(map_id: String, data: Dictionary) -> void:
	if SimAuthority.local_uid != 0 and map_id != _local_map():
		return
	var fx = WARNING.instantiate()
	add_child(fx)
	fx.global_position = data.get("center", Vector3.ZERO) as Vector3
	fx.setup({"kind": "area", "radius": float(data.get("radius", 3.0)),
		"start_tick": int(data.get("start_tick", 0)), "release_tick": int(data.get("release_tick", data.get("start_tick", 0)))}
		if data.has("release_tick") else {"kind": "area", "radius": float(data.get("radius", 3.0))})
	fx.set_colour(TINTS.get(String(data.get("kind", "")), Color(1.0, 0.3, 0.1)))
	_live.append({"fx": fx, "data": data})

func _process(_delta: float) -> void:
	var now := SimAuthority.sim_tick
	for entry in _live.duplicate():
		var fx = entry["fx"]
		var data: Dictionary = entry["data"]
		if not is_instance_valid(fx):
			_live.erase(entry)
			continue
		if data.has("release_tick"):
			var start := int(data.get("start_tick", now))
			var release := int(data["release_tick"])
			fx.set_progress(float(now - start) / float(maxi(1, release - start)))
			if now >= release:
				fx.release()
				_free_later(fx)
				_live.erase(entry)
		else:
			fx.set_progress(0.6)
			if now >= int(data.get("until_tick", now)):
				fx.clear()
				_free_later(fx)
				_live.erase(entry)

func _free_later(fx: Node) -> void:
	get_tree().create_timer(1.0).timeout.connect(func():
		if is_instance_valid(fx):
			fx.queue_free())
