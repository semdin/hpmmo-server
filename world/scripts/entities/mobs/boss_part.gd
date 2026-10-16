extends "res://scripts/entities/mobs/mob_base.gd"

## One targetable part of a multi-part creature (Fluffy's heads, the Devil's
## Snare's vines): its own entity with its own hit points and label, no AI and
## no rewards. On the authority it rides its body's bone every frame
## (multipart_boss.gd moves it); a client puppet just follows the snapshots.
## A hit on the part wakes the body; its death is the body's business.

## Set by the body before the part enters the tree.
var owner_body: Node3D
var part_key := ""
var bone_name := ""
func _ready() -> void:
	# Parts never pay out: the body's death credits whoever hit any of its parts.
	no_rewards = true
	super()
	if visuals:
		visuals.visible = false

func _physics_process(delta: float) -> void:
	if sim_puppet:
		super(delta)
		return
	# Authority: no wandering, chasing or attacking - the body does that.
	velocity = Vector3.ZERO
	_publish_state()
	if state == State.DEAD:
		_corpse_time += delta

func on_authoritative_damage(type: String, attacker: Node3D, stun_ms: int, weaken_ms: int) -> void:
	_update_label()
	if is_instance_valid(owner_body) and is_instance_valid(attacker) and owner_body.state != State.DEAD:
		owner_body.aggro_on(attacker)

func on_authoritative_death(_killer: Node3D) -> void:
	_set_state(State.DEAD)
	_publish_state()
	remove_from_group("targetable")
	_set_collision_enabled(false)
	if label:
		label.visible = false
	died.emit(self)

func _respawn() -> void:
	# A part lives once; a puppet that sees it alive again just shows it.
	if sim_puppet:
		super()
		if label:
			label.visible = true
