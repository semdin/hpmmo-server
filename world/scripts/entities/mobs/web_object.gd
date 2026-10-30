extends "res://scripts/entities/mobs/mob_base.gd"

## A still thing in a dungeon run that players break: an egg sac about to hatch
## or a web cocoon around a party member (dungeons.json `hatch` / `cocoon`; the
## dungeon director decides what its fate means). No AI, no attack, no rewards
## of its own - the run's clear and budget pay for it - and fire burns it best
## (mobs.json resist). Broken, it shrivels away.

var _withered := false

func _ready() -> void:
	no_rewards = true
	super()

func _physics_process(delta: float) -> void:
	if sim_puppet:
		super(delta)
	else:
		# Authority: it never moves, wanders or fights.
		velocity = Vector3.ZERO
		_publish_state()
	if state == State.DEAD and not _withered:
		_wither()

func on_authoritative_damage(_type: String, _attacker: Node3D, _stun_ms: int, _weaken_ms: int) -> void:
	_update_label()

func on_authoritative_death(_killer: Node3D) -> void:
	_set_state(State.DEAD)
	_publish_state()
	remove_from_group("targetable")
	_set_collision_enabled(false)
	died.emit(self)

func _wither() -> void:
	_withered = true
	if label:
		label.visible = false
	if visuals:
		var tween := create_tween()
		tween.tween_property(visuals, "scale", visuals.scale * Vector3(1.2, 0.05, 1.2), 0.45).set_trans(Tween.TRANS_BACK).set_ease(Tween.EASE_IN)
		tween.tween_callback(func(): visuals.visible = false)
