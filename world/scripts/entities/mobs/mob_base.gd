extends CharacterBody3D

enum State { IDLE, WANDER, CHASE, ATTACK, STUNNED, DEAD, RETURN }
signal died(mob: Node3D)
@export var mob_name := "Dark Creature"
@export var level := 10
@export var max_hp := 250
@export var attack_power := 25
@export var move_speed := 6.0
@export var aggro_radius := 12.0
## "reactive" (default): a valid hit activates the mob and its pack.
## "aggressive": proximity scan inside aggro_radius also activates.
@export var aggro_mode := "reactive"
@export var assist_radius := 16.0
@export var leash_distance := 26.0
@export var attack_range := 2.2
@export var attack_cooldown := 1.4
@export var exp_reward := 65
@export var weak_to_fire := false
@export var is_ranged := false
@export var pack_id := 0
@export var pack_anchor := Vector3.ZERO
@export var is_boss := false
@export var is_commander := false
var managed_respawn := false
var summoned := false
var is_enraged := false
var current_hp := 250
var state: State = State.IDLE
var target_player: Node3D
var spawn_point := Vector3.ZERO
var attack_timer := 0.0
var stun_timer := 0.0
var wander_timer := 0.0
var wander_target := Vector3.ZERO
var knockback_velocity := Vector3.ZERO
var anim_player: AnimationPlayer
var _base_attack := 25
var _base_speed := 6.0
var _base_cooldown := 1.4
var _windup := 0.0
var _attack_kind := ""
var _attack_center := Vector3.ZERO
var _warning: MeshInstance3D
var _corpse_time := 0.0
var _respawn_delay := 25.0
var _weaken_timer := 0.0
var _scan_timer := 0.0
## True when this node is a CLIENT'S VIEW of a mob the world server owns: it
## runs no AI, applies no damage, and just follows the replicated state.
var sim_puppet := false
var sim_target_pos := Vector3.ZERO
var sim_target_rot := 0.0
@onready var label: Label3D = $Label3D
@onready var visuals: Node3D = $Visuals
const Rules = preload("res://scripts/spells/combat_rules.gd")
const SafeZone = preload("res://scripts/world/safe_zone.gd")
const FX = preload("res://scripts/spells/skill_fx.gd")
const LOOT_SCENE = preload("res://scenes/entities/loot/loot_drop.tscn")
const PROJECTILE_SCENE = preload("res://scenes/spells/spell_projectile.tscn")

func _ready() -> void:
	add_to_group("mobs")
	add_to_group("targetable")
	current_hp = max_hp
	spawn_point = global_position
	_base_attack = attack_power
	_base_speed = move_speed
	_base_cooldown = attack_cooldown
	if SimAuthority.is_authority():
		SimAuthority.refresh_mob(self)
	anim_player = visuals.find_child("AnimationPlayer", true, false)
	if anim_player:
		# Imported monster animations use different names from the wizard rig.
		for animation in anim_player.get_animation_list():
			var clip := anim_player.get_animation(animation)
			clip.loop_mode = Animation.LOOP_LINEAR if animation in ["Idle", "Walk", "Run", "Walking_A", "Running_A"] else Animation.LOOP_NONE
	wander_timer = randf_range(1, 4)
	_scan_timer = randf_range(0, 0.4)
	_play_anim("Idle")
	_update_label()

func _play_anim(name_hint: String, blend: float = 0.18) -> void:
	if not is_instance_valid(anim_player):
		return
	var aliases := {"Walking_A": "Walk", "Running_A": "Run", "1H_Melee_Attack_Chop": "Punch", "Spellcast_Shoot": "Weapon", "Spellcast_Raise": "Weapon", "Hit_A": "HitReact", "Death_A": "Death"}
	var clip: String = name_hint if anim_player.has_animation(name_hint) else aliases.get(name_hint, "Idle")
	if anim_player.has_animation(clip) and (anim_player.current_animation != clip or not anim_player.is_playing()):
		anim_player.play(clip, blend)

func _update_label() -> void:
	label.text = "[Lv.%d] %s%s\n%d / %d" % [level, mob_name, " • ENRAGED" if is_enraged else "", current_hp, max_hp]
	label.modulate = Color(1, 0.72, 0.25) if is_boss else Color(1, 0.6, 0.5)
	label.font_size = 26 if is_boss else 21
	label.visibility_range_end = 40

func _physics_process(delta: float) -> void:
	# Client view of a server-owned mob: no AI, no damage, no physics authority -
	# only interpolation towards the last replicated sample.
	if sim_puppet:
		global_position = global_position.lerp(sim_target_pos, minf(1.0, 12.0 * delta))
		if visuals:
			visuals.rotation.y = lerp_angle(visuals.rotation.y, sim_target_rot, minf(1.0, 12.0 * delta))
		_tick_corpse(delta)
		return
	if state == State.DEAD:
		_tick_corpse(delta)
		return
	# Phase 1: enemies displaced inside a protected volume cancel the fight and
	# walk home instead of attacking through the boundary.
	if state != State.RETURN and SafeZone.is_protected_point(global_position) and not SafeZone.is_protected_point(spawn_point):
		_cancel_attack()
		target_player = null
		state = State.RETURN
	attack_timer = maxf(0, attack_timer - delta)
	_weaken_timer = maxf(0, _weaken_timer - delta)
	if state == State.STUNNED:
		stun_timer -= delta
		if stun_timer <= 0:
			state = State.CHASE if _valid_target() else State.IDLE
		velocity.x = 0
		velocity.z = 0
	elif _windup > 0:
		velocity.x = 0
		velocity.z = 0
		_windup -= delta
		if _windup <= 0:
			_resolve_attack()
	else:
		match state:
			State.IDLE, State.WANDER:
				_idle_and_wander(delta)
			State.CHASE, State.ATTACK:
				_fight(delta)
			State.RETURN:
				_move_to(spawn_point, move_speed, delta)
				if global_position.distance_to(spawn_point) < 1.3:
					current_hp = max_hp
					state = State.IDLE
					_update_label()
	velocity += knockback_velocity * delta * 8
	knockback_velocity = knockback_velocity.move_toward(Vector3.ZERO, delta * 30)
	if not is_on_floor():
		velocity.y -= 24 * delta
	else:
		velocity.y = 0
	move_and_slide()

func _tick_corpse(delta: float) -> void:
	_corpse_time += delta
	if _corpse_time > 4:
		visuals.position.y = -minf(2.5, (_corpse_time - 4) * 0.8)
	if _corpse_time > 6:
		hide()
		if summoned and not sim_puppet:
			queue_free()
	if not sim_puppet and not managed_respawn and not summoned and _corpse_time > _respawn_delay:
		_respawn()

func _idle_and_wander(delta: float) -> void:
	_scan_timer -= delta
	if _scan_timer <= 0:
		_scan_timer = 0.35
		# Ordinary mobs are reactive: only explicit aggressive encounters use
		# the proximity trigger (plan Phase 1, gameplay policy 3.3).
		if aggro_mode == "aggressive":
			for player in get_tree().get_nodes_in_group("players"):
				if Rules.can_damage(self, player) and global_position.distance_to(player.global_position) < aggro_radius and Rules.has_line_of_sight(self, player):
					aggro_on(player)
					return
	if state == State.WANDER:
		_move_to(wander_target, move_speed * 0.3, delta)
		wander_timer -= delta
		if global_position.distance_to(wander_target) < 0.8 or wander_timer <= 0:
			state = State.IDLE
			wander_timer = randf_range(2, 5)
	else:
		velocity.x = 0
		velocity.z = 0
		_play_anim("Idle")
		wander_timer -= delta
		if wander_timer <= 0:
			var angle := randf() * TAU
			wander_target = spawn_point + Vector3(cos(angle), 0, sin(angle)) * randf_range(1, 3)
			wander_timer = 4
			state = State.WANDER

func aggro_on(player: Node3D, alert_pack: bool = true) -> void:
	if state in [State.DEAD, State.RETURN] or not Rules.can_damage(self, player):
		return
	target_player = player
	if state != State.STUNNED:
		state = State.CHASE
	if alert_pack and pack_id > 0:
		for mob in get_tree().get_nodes_in_group("mobs"):
			if mob != self and mob.pack_id == pack_id and global_position.distance_to(mob.global_position) <= assist_radius:
				mob.aggro_on(player, false)

func _valid_target() -> bool:
	return Rules.can_damage(self, target_player)

func _fight(delta: float) -> void:
	if not _valid_target() or global_position.distance_to(pack_anchor) > leash_distance:
		_cancel_attack()
		target_player = null
		state = State.RETURN
		return
	var distance := global_position.distance_to(target_player.global_position)
	var reach := 15.0 if is_ranged else attack_range
	if distance > reach or not Rules.has_line_of_sight(self, target_player):
		state = State.CHASE
		_move_to(target_player.global_position, move_speed, delta)
	else:
		state = State.ATTACK
		velocity.x = 0
		velocity.z = 0
		_face_direction(target_player.global_position - global_position, delta)
		if attack_timer <= 0:
			attack_timer = attack_cooldown
			_attack_kind = "slam" if is_boss and randf() < 0.4 else ("ranged" if is_ranged else "melee")
			_windup = 1.1 if _attack_kind == "slam" else 0.42
			_attack_center = global_position
			_play_anim("Spellcast_Raise" if _attack_kind == "slam" else "1H_Melee_Attack_Chop", 0.08)
			if _attack_kind == "slam":
				_show_warning()

func _move_to(point: Vector3, speed: float, delta: float) -> void:
	var direction := point - global_position
	direction.y = 0
	direction = direction.normalized()
	# Short obstacle probe steers packs around architecture, rather than attacking through it.
	var query := PhysicsRayQueryParameters3D.create(global_position + Vector3.UP, global_position + Vector3.UP + direction * 2, 1)
	if not get_world_3d().direct_space_state.intersect_ray(query).is_empty():
		direction = direction.rotated(Vector3.UP, PI / 2)
	velocity.x = direction.x * speed
	velocity.z = direction.z * speed
	_face_direction(direction, delta)
	_play_anim("Running_A" if state in [State.CHASE, State.RETURN] else "Walking_A")

func _face_direction(direction: Vector3, delta: float) -> void:
	if Vector2(direction.x, direction.z).length_squared() > 0.001:
		visuals.rotation.y = lerp_angle(visuals.rotation.y, atan2(direction.x, direction.z), minf(1, delta * 10))

func _show_warning() -> void:
	_warning = MeshInstance3D.new()
	var disc := CylinderMesh.new()
	disc.top_radius = 5.5
	disc.bottom_radius = 5.5
	disc.height = 0.03
	var mat := StandardMaterial3D.new()
	mat.albedo_color = Color(1, 0.15, 0.06, 0.36)
	mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	disc.material = mat
	_warning.mesh = disc
	get_parent().add_child(_warning)
	_warning.global_position = _attack_center + Vector3.UP * 0.08

func _cancel_attack() -> void:
	_windup = 0
	_attack_kind = ""
	if is_instance_valid(_warning):
		_warning.queue_free()
	_warning = null

func _resolve_attack() -> void:
	var kind := _attack_kind
	var center := _attack_center
	_cancel_attack()
	var power := int(attack_power * (0.65 if _weaken_timer > 0 else 1.0))
	if kind == "slam":
		FX.play_impact(get_parent(), center, "bombarda")
		# AoE victims are chosen by the engine from its own entity table: a
		# protected player inside the circle simply is not a victim.
		SimAuthority.mob_area_attack(self, center, 5.5, int(power * 1.7), "boss_slam")
	elif _valid_target() and Rules.has_line_of_sight(self, target_player):
		if kind == "ranged":
			var dir := (target_player.global_position + Vector3.UP - (global_position + Vector3.UP * 1.2)).normalized()
			FX.play_cast(get_parent(), self, "stupefy", global_position + Vector3.UP * 1.2, dir)
			SimAuthority.mob_projectile(self, "stupefy", dir, power)
		elif global_position.distance_to(target_player.global_position) <= attack_range + 0.4:
			SimAuthority.mob_melee(self, target_player, power)

func trigger_enrage() -> void:
	if is_enraged or state == State.DEAD:
		return
	is_enraged = true
	attack_power = int(_base_attack * 1.3)
	move_speed = _base_speed * 1.25
	attack_cooldown = _base_cooldown * 0.8
	_update_label()

## Damage requests are decided by the authority; this node never subtracts HP on
## its own. Clients calling this only ask - the engine answers (and in a
## client-only process the answer is "no", because the server sends the result).
func take_damage(amount: int, type: String, attacker: Node3D) -> void:
	if sim_puppet or state in [State.DEAD, State.RETURN]:
		return
	SimAuthority.apply_damage(self, amount, type, attacker)

## Presentation hook after the authority applied damage: reaction state only.
func on_authoritative_damage(type: String, attacker: Node3D, stun_ms: int, weaken_ms: int) -> void:
	if state in [State.DEAD, State.RETURN]:
		return
	if is_instance_valid(attacker):
		aggro_on(attacker)
	if stun_ms > 0 and not is_boss:
		_cancel_attack()
		state = State.STUNNED
		stun_timer = float(stun_ms) / 1000.0
	elif stun_ms > 0:
		_cancel_attack()
		state = State.STUNNED
		stun_timer = float(stun_ms) / 1000.0
	if weaken_ms > 0:
		_weaken_timer = float(weaken_ms) / 1000.0
	_update_label()

## Authority death notification: the engine already paid the rewards and dropped
## the loot, so this is the body's part only.
func on_authoritative_death(killer: Node3D) -> void:
	_cancel_attack()
	state = State.DEAD
	velocity = Vector3.ZERO
	remove_from_group("targetable")
	$CollisionShape3D.set_deferred("disabled", true)
	_play_anim("Death_A", 0.08)
	var spider := visuals.get_node_or_null("SpiderRig")
	if spider:
		spider.die()
	_corpse_time = 0
	_respawn_delay = float(HPRules.respawn_delay_ms(is_boss, SimAuthority.rng)) / 1000.0
	for mob in get_tree().get_nodes_in_group("mobs"):
		if pack_id > 0 and mob != self and mob.pack_id == pack_id and mob.is_commander:
			mob.trigger_enrage()
	died.emit(self)

## Authority interrupt (stun, disarm, death, leash-cancel): drop any windup.
func cancel_cast_action() -> void:
	_cancel_attack()

func apply_knockback(force: Vector3) -> void:
	if not is_boss and state != State.DEAD:
		knockback_velocity = force

func _drop_mob_loot() -> void:
	var drops := [{"id": "galleons", "amount": randi_range(250, 600) if is_boss else randi_range(30, 95)}]
	if randf() < 0.5:
		drops.append({"id": "mat_phoenix_ash", "amount": randi_range(1, 3)})
	if randf() < 0.3:
		drops.append({"id": "potion_health", "amount": 1})
	if is_boss:
		drops.append({"id": "mat_dragon_heartstring", "amount": 2})
	for drop in drops:
		var loot := LOOT_SCENE.instantiate()
		get_parent().add_child(loot)
		loot.global_position = global_position + Vector3(randf_range(-1, 1), 0.3, randf_range(-1, 1))
		loot.setup(drop.id, drop.amount)

func _respawn() -> void:
	global_position = spawn_point
	current_hp = max_hp
	attack_power = _base_attack
	move_speed = _base_speed
	attack_cooldown = _base_cooldown
	is_enraged = false
	target_player = null
	stun_timer = 0
	_weaken_timer = 0
	knockback_velocity = Vector3.ZERO
	velocity = Vector3.ZERO
	attack_timer = 1
	_cancel_attack()
	state = State.IDLE
	visuals.position = Vector3.ZERO
	visuals.rotation = Vector3.ZERO
	var spider := visuals.get_node_or_null("SpiderRig")
	if spider:
		spider.reset_pose()
	show()
	add_to_group("targetable")
	$CollisionShape3D.set_deferred("disabled", false)
	_play_anim("Idle")
	_update_label()
	if SimAuthority.is_authority():
		SimAuthority.refresh_mob(self)

func _exit_tree() -> void:
	_cancel_attack()
	SimAuthority.unregister_node(self)
