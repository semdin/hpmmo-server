extends "res://scripts/entities/mobs/multipart_boss.gd"

## The Devil's Snare - a rooted plant whose heart hides behind three thorned
## vines. Each vine is a separate target (boss_part, weak to fire: Incendio
## burns it at double damage, as in the film); the heart is immune until all
## three are gone and then fights on with its own hit points. A burned vine
## withers on its bones (part_droop, shrunk). It never moves.

func _ready() -> void:
	droop_chains = {
		"L": ["VineL1", "VineL2", "VineL3", "VineL4"],
		"R": ["VineR1", "VineR2", "VineR3", "VineR4"],
		"T": ["VineT1", "VineT2", "VineT3", "VineT4"],
	}
	droop_degrees = 16.0
	droop_shrink = 0.82
	hp_is_sum = false
	super()

func _on_part_down(_key: String) -> void:
	var left := living_parts().size()
	if left > 0:
		dungeon_message.emit("A vine shrivels in the flames! %d left." % left)

func _all_parts_down() -> void:
	SimAuthority.set_mob_immune(self, false)
	dungeon_message.emit("The vines are gone - the Snare's heart is exposed!")
