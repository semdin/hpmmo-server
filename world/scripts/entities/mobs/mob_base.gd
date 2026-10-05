extends CharacterBody3D

## Ordinary mob / boss body. Runs the AI on the authority (dedicated server,
## host, or the single-player client); on a client it is a PUPPET that renders
## the replicated state and never decides anything (plan.md Phase 5 + 11).
##
## Phase 11 AI contract:
##   * reactive aggro: a valid hit activates the mob and its pack; proximity
##     alone never starts ordinary combat (`aggro_mode == "aggressive"` is the
##     explicit opt-in used by aggressive encounter data);
##   * chase = local obstacle avoidance (whisker steering + stuck sidestep),
##     local separation so five mobs do not occupy one point, attack slots so
##     only a bounded number melee the same target, line of sight, leash and
##     target validity;
##   * attacks are explicit phases: ANTICIPATION -> RELEASE -> RECOVERY, with
##     the facing locked when anticipation starts;
##   * boss patterns (directional + area) publish a telegraph whose release tick
##     the authority lands the damage on - the client only renders it;
##   * losing every valid target returns the pack home and resets the encounter
##     (the authority cancels the pending reward credit);
##   * death marks the body dead immediately, stops damage/collision, plays the
##     death animation, keeps a corpse matched to that animation, then fades;
##   * `_respawn()` restores every field, effect, target and signal - a respawn
##     must not leave one trace of the previous life.

enum State { IDLE, WANDER, CHASE, ATTACK, STUNNED, DEAD, RETURN }

## Explicit attack phases (plan.md Phase 11). `_windup`/`_recovery` are the
## countdowns; the phase is what the rest of the AI reads.
enum AttackPhase { NONE, ANTICIPATION, RELEASE, RECOVERY }

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
## Phase 11 encounter metadata (set by the encounter director from server data).
@export var encounter_id := ""
@export var escort_count := 0
@export var boss_style := ""
@export var boss_arena_radius := 0.0
## Animation set this body's clips come from ("spider", "wizard", "generic").
@export var anim_set := "generic"
## Ground speed the walk cycle was authored for (0 = unknown, no scaling).
@export var walk_speed := 0.0

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
var _recovery := 0.0
var attack_phase: AttackPhase = AttackPhase.NONE
var _attack_kind := ""
var _attack_center := Vector3.ZERO
var _attack_dir := Vector3.FORWARD
var _attack_plan: Dictionary = {}
var _pattern_index := 0
var _warning: MeshInstance3D
var _warning_fill: MeshInstance3D
var _corpse_time := 0.0
var _corpse_lifetime := 2.0
var _respawn_delay := 25.0
var _weaken_timer := 0.0
var _scan_timer := 0.0
var _stuck_timer := 0.0
var _last_pos := Vector3.ZERO
## Last replicated AI state a client view rendered (puppets only).
var _puppet_state := -1
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

## Which clip plays for each AI slot, per animation set. A clip the body does not
## have falls back through the alias table to Idle (never an error).
const ANIM_SETS := {
	"spider": {"idle": "Idle", "walk": "Walk", "run": "Walk", "turn": "Turn",
		"anticipation": "Bite_Anticipation", "attack": "Bite_Attack", "hit": "Hit",
		"stun": "Stun", "death": "Death"},
	"wizard": {"idle": "Idle", "walk": "Walk", "run": "Walk", "turn": "Walk",
		"anticipation": "Cast_Directional_Anticipation", "attack": "Cast_Directional_Attack",
		"hit": "Hit", "stun": "Stun", "death": "Death"},
	"generic": {"idle": "Idle", "walk": "Walking_A", "run": "Running_A", "turn": "Running_A",
		"anticipation": "1H_Melee_Attack_Chop", "attack": "1H_Melee_Attack_Chop",
		"hit": "Hit_A", "stun": "Hit_A", "death": "Death_A"},
}

## Ordinary attack timing (data-driven patterns replace this for bosses).
const MELEE_ANTICIPATION := 0.42
const MELEE_RECOVERY := 0.35
const RANGED_ANTICIPATION := 0.55
const RANGED_RECOVERY := 0.5

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
	_apply_boss_visual()
	_apply_lod()
	wander_timer = randf_range(1, 4)
	_scan_timer = randf_range(0, 0.4)
	_last_pos = global_position
	_play_slot("idle")
	_update_label()

## Boss bodies are authored creatures, not a scaled-up ordinary mob: the scene
## carries `Visuals/NormalVariant` and `Visuals/BossVariant`, and the boss flag
## (set by the director on the server, replicated as FLAG_BOSS to clients)
## selects which one is visible and which AnimationPlayer drives the body.
func _apply_boss_visual() -> void:
	var boss_node := visuals.get_node_or_null("BossVariant")
	var normal := visuals.get_node_or_null("NormalVariant")
	if boss_node:
		boss_node.visible = is_boss
	if normal:
		normal.visible = not is_boss
	if boss_node != null and normal != null:
		var normal_shape := get_node_or_null("CollisionShape3D")
		var boss_shape := get_node_or_null("CollisionShape3DBoss")
		if normal_shape != null and boss_shape != null:
			(normal_shape as CollisionShape3D).set_deferred("disabled", is_boss)
			(boss_shape as CollisionShape3D).set_deferred("disabled", not is_boss)
	var active: Node = boss_node if is_boss and boss_node != null else normal
	if active != null:
		var found := active.find_child("AnimationPlayer", true, false)
		if found:
			anim_player = found
	elif boss_node == null and normal == null:
		# Legacy/procedural body (no variant split): keep its own animator.
		anim_player = visuals.find_child("AnimationPlayer", true, false)
	if anim_player:
		# Imported monster animations use different names from the wizard rig.
		for animation in anim_player.get_animation_list():
			var clip := anim_player.get_animation(animation)
			clip.loop_mode = Animation.LOOP_LINEAR if animation in ["Idle", "Walk", "Run", "Walking_A",
				"Running_A", "Stun", "Stun_Loop"] else Animation.LOOP_NONE

## LOD switch for bodies whose GLB ships a second skinned mesh (Phase 11
## creatures). Ordinary mobs use LOD1 only (art-direction §4).
## Both collision proxies exist so a boss body is not the ordinary mob's sphere:
## exactly one is active at a time, and a corpse has none.
func _set_collision_enabled(enabled: bool) -> void:
	var normal_shape := get_node_or_null("CollisionShape3D")
	var boss_shape := get_node_or_null("CollisionShape3DBoss")
	if boss_shape == null:
		# A body with no separate boss proxy (legacy scenes): the ordinary shape
		# serves both, and disabling it for a boss would drop it through the
		# world - the bug the 93-check harness caught.
		if normal_shape != null:
			(normal_shape as CollisionShape3D).set_deferred("disabled", not enabled)
		return
	if normal_shape != null:
		(normal_shape as CollisionShape3D).set_deferred("disabled", not enabled or is_boss)
	if boss_shape != null:
		(boss_shape as CollisionShape3D).set_deferred("disabled", not enabled or not is_boss)

## Authored creature cycles have a real ground speed; without this an authored
## body skates when it moves at the gameplay speed. Only the creature sets that
## publish `walk_speed` are scaled this way.
func _update_anim_speed() -> void:
	if not is_instance_valid(anim_player):
		return
	if walk_speed <= 0.0:
		anim_player.speed_scale = 1.0
		return
	anim_player.speed_scale = clampf(move_speed / walk_speed, 0.55, 3.0)

func _apply_lod() -> void:
	var lod1 := visuals.find_child("LOD1", true, false)
	if lod1 is GeometryInstance3D:
		(lod1 as GeometryInstance3D).visibility_range_begin = 26.0
		(lod1 as GeometryInstance3D).visibility_range_begin_margin = 2.0
	var lod0 := visuals.find_child("LOD0", true, false)
	if lod0 is GeometryInstance3D and lod1 != null:
		(lod0 as GeometryInstance3D).visibility_range_end = 26.0
		(lod0 as GeometryInstance3D).visibility_range_end_margin = 2.0

# ----------------------------------------------------------------- animation

func _clip_for(slot: String) -> String:
	var set_table: Dictionary = ANIM_SETS.get(anim_set, ANIM_SETS["generic"])
	var clip := String(set_table.get(slot, "Idle"))
	var aliases := {"Walking_A": "Walk", "Running_A": "Run", "1H_Melee_Attack_Chop": "Punch",
		"Spellcast_Shoot": "Weapon", "Spellcast_Raise": "Weapon", "Hit_A": "HitReact", "Death_A": "Death"}
	if anim_player and not anim_player.has_animation(clip):
		clip = String(aliases.get(clip, "Idle"))
	return clip

func _play_slot(slot: String, blend: float = 0.18) -> void:
	if not is_instance_valid(anim_player):
		return
	if slot in ["walk", "run"]:
		_update_anim_speed()
	var clip := _clip_for(slot)
	if anim_player.has_animation(clip) and (anim_player.current_animation != clip or not anim_player.is_playing()):
		anim_player.play(clip, blend)

## Attack clips: a boss pattern names its clip pair in data ("Slam" ->
## Slam_Anticipation / Slam_Attack, "Cast_Area" -> Cast_Area_Anticipation / ...),
## so the same code drives the spider matriarch and the dark wizard.
func _play_attack_clip(plan: Dictionary, phase: String, blend: float = 0.08) -> void:
	var base := String(plan.get("clip", ""))
	if base == "":
		_play_slot(phase, blend)
		return
	var suffix := "Anticipation" if phase == "anticipation" else "Attack"
	var clip := "%s_%s" % [base, suffix]
	if is_instance_valid(anim_player) and anim_player.has_animation(clip):
		if anim_player.current_animation != clip or not anim_player.is_playing():
			anim_player.play(clip, blend)
	else:
		_play_slot(phase, blend)

func _play_anim(name_hint: String, blend: float = 0.18) -> void:
	if not is_instance_valid(anim_player):
		return
	var aliases := {"Walking_A": "Walk", "Running_A": "Run", "1H_Melee_Attack_Chop": "Punch",
		"Spellcast_Shoot": "Weapon", "Spellcast_Raise": "Weapon", "Hit_A": "HitReact", "Death_A": "Death"}
	var clip: String = name_hint if anim_player.has_animation(name_hint) else aliases.get(name_hint, "Idle")
	if anim_player.has_animation(clip) and (anim_player.current_animation != clip or not anim_player.is_playing()):
		anim_player.play(clip, blend)

func _update_label() -> void:
	label.text = "[Lv.%d] %s%s\n%d / %d" % [level, mob_name, " • ENRAGED" if is_enraged else "", current_hp, max_hp]
	label.modulate = Color(1, 0.72, 0.25) if is_boss else Color(1, 0.6, 0.5)
	label.font_size = 26 if is_boss else 21
	label.visibility_range_end = 40

# ---------------------------------------------------------------- main tick

func _physics_process(delta: float) -> void:
	# Client view of a server-owned mob: no AI, no damage, no physics authority -
	# only interpolation towards the last replicated sample, presentation from
	# the replicated state byte, and the boss warning drawn from the server's
	# start/release ticks.
	if sim_puppet:
		_update_puppet(delta)
		_tick_corpse(delta)
		return
	# Phase 12 hook: an AUTHORITY body inside a client process (offline and
	# listen-host play) draws the boss warning from the same replicated ticks a
	# connected client uses, so single-player shows exactly what a client sees.
	# The dedicated server draws nothing.
	if is_boss and not NetworkManager.is_dedicated_server:
		var authored_record := SimAuthority.record_for(self)
		if not authored_record.is_empty():
			_draw_telegraph(authored_record)
	# Phase 12 hook: creature voices. Movement, bite and death cues come from the
	# sound library by creature type. Presentation only - nothing here can
	# change damage, AI or rewards.
	if not is_boss and state == State.CHASE:
		_voice_timer -= delta
		if _voice_timer <= 0.0:
			_voice_timer = randf_range(0.45, 0.9)
			_play_voice("spider_move_%d" % (randi() % 3 + 1))
	if state == State.DEAD:
		_tick_corpse(delta)
		return
	# Phase 1: enemies displaced inside a protected volume cancel the fight and
	# walk home instead of attacking through the boundary.
	if state != State.RETURN and SafeZone.is_protected_point(global_position) and not SafeZone.is_protected_point(spawn_point):
		_cancel_attack()
		target_player = null
		_set_state(State.RETURN)
	attack_timer = maxf(0, attack_timer - delta)
	_weaken_timer = maxf(0, _weaken_timer - delta)
	_publish_state()
	if state == State.STUNNED:
		stun_timer -= delta
		if stun_timer <= 0:
			if _valid_target():
				_set_state(State.CHASE)
			else:
				_break_fight("no_target")
		velocity.x = 0
		velocity.z = 0
	elif attack_phase != AttackPhase.NONE:
		_tick_attack(delta)
	else:
		match state:
			State.IDLE, State.WANDER:
				_idle_and_wander(delta)
			State.CHASE, State.ATTACK:
				_fight(delta)
			State.RETURN:
				_return_home(delta)
	velocity += knockback_velocity * delta * 8
	knockback_velocity = knockback_velocity.move_toward(Vector3.ZERO, delta * 30)
	if not is_on_floor():
		velocity.y -= 24 * delta
	else:
		velocity.y = 0
	move_and_slide()

func _set_state(next: State) -> void:
	if state == next:
		return
	state = next

## The byte the snapshots carry: the AI state with the attack phase folded in,
## so a client sees anticipation/recovery without a second field.
func _replicated_state() -> int:
	if state == State.DEAD:
		return HPProtocol.MobState.DEAD
	if state == State.STUNNED:
		return HPProtocol.MobState.STUNNED
	match attack_phase:
		AttackPhase.ANTICIPATION:
			return HPProtocol.MobState.ANTICIPATION
		AttackPhase.RECOVERY, AttackPhase.RELEASE:
			return HPProtocol.MobState.RECOVERY
	match state:
		State.ATTACK:
			return HPProtocol.MobState.ATTACK
		State.CHASE:
			return HPProtocol.MobState.CHASE
		State.RETURN:
			return HPProtocol.MobState.RETURN
		State.WANDER:
			return HPProtocol.MobState.WANDER
	return HPProtocol.MobState.IDLE

var _published_state := -1

func _publish_state() -> void:
	if not SimAuthority.is_authority():
		return
	var value := _replicated_state()
	if value == _published_state:
		return
	_published_state = value
	SimAuthority.set_mob_state(self, value)

# ------------------------------------------------------------- attack phases

func _tick_attack(delta: float) -> void:
	# A leash broken mid-windup cancels the attack: the release must not land
	# from outside the pack's arena (plan.md Phase 11: "clear attacks ... return
	# home").
	if global_position.distance_to(pack_anchor) > _leash_limit():
		_break_fight("leash")
		return
	if attack_phase == AttackPhase.ANTICIPATION:
		# Anticipation: planted, facing locked on the direction chosen when the
		# attack began - the release uses this direction, not a live target read.
		velocity.x = 0
		velocity.z = 0
		_windup -= delta
		if _windup <= 0.0:
			_release_attack()
	elif attack_phase == AttackPhase.RECOVERY:
		velocity.x = 0
		velocity.z = 0
		_recovery -= delta
		if _recovery <= 0.0:
			attack_phase = AttackPhase.NONE
			_attack_plan = {}
			_publish_state()
			if _valid_target():
				_set_state(State.CHASE)
			else:
				# No valid target left: go home and reset the encounter instead of
				# standing in the field with a stale target (the authority cancels
				# the pack's pending reward credit).
				_break_fight("no_target")

## Begin an attack. Bosses walk a deterministic pattern list (directional ->
## area -> ...); ordinary mobs use the melee/ranged plan. The telegraph for a
## boss pattern is published HERE with the release tick the authority will land
## the damage on.
func _begin_attack(plan: Dictionary) -> void:
	_attack_plan = plan
	_attack_kind = String(plan.get("kind", "melee"))
	_attack_center = global_position
	_attack_dir = _direction_to_target()
	_windup = float(plan.get("anticipation", MELEE_ANTICIPATION))
	_recovery = float(plan.get("recovery", MELEE_RECOVERY))
	attack_phase = AttackPhase.ANTICIPATION
	_play_attack_clip(plan, "anticipation")
	_publish_state()
	if is_boss and bool(plan.get("telegraph", false)) and SimAuthority.is_authority():
		var release_tick := SimAuthority.sim_tick + maxi(1, int(round(_windup * float(HPProtocol.SIM_HZ))))
		SimAuthority.begin_mob_telegraph(self, plan, release_tick, _attack_dir, _attack_center)

func _release_attack() -> void:
	var plan := _attack_plan
	attack_phase = AttackPhase.RECOVERY
	_play_attack_clip(plan, "attack", 0.06)
	_set_state(State.ATTACK)
	_publish_state()
	if is_boss and bool(plan.get("telegraph", false)) and SimAuthority.is_authority():
		SimAuthority.end_mob_telegraph(self)
	# Phase 12 hook: the release cue fires on the authoritative release tick.
	if is_instance_valid(_warning_effect):
		_warning_effect.call("release")
	_resolve_attack(plan)

## Pick the next boss pattern (deterministic order, no RNG) or the ordinary
## melee/ranged plan.
func _choose_plan() -> Dictionary:
	if is_boss:
		var patterns: Array = HPRules.attack_patterns_for(boss_style)
		if not patterns.is_empty():
			var pattern: Dictionary = (patterns[_pattern_index % patterns.size()] as Dictionary).duplicate(true)
			_pattern_index += 1
			pattern["telegraph"] = true
			return pattern
		return {"kind": "melee", "anticipation": 1.1, "recovery": 0.9, "telegraph": true}
	return {"kind": "ranged" if is_ranged else "melee",
		"anticipation": RANGED_ANTICIPATION if is_ranged else MELEE_ANTICIPATION,
		"recovery": RANGED_RECOVERY if is_ranged else MELEE_RECOVERY}

func _direction_to_target() -> Vector3:
	if not is_instance_valid(target_player):
		return _attack_dir
	var dir: Vector3 = (target_player as Node3D).global_position - global_position
	dir.y = 0.0
	if dir.length_squared() < 0.0001:
		return _attack_dir
	return dir.normalized()

func _cancel_attack() -> void:
	attack_phase = AttackPhase.NONE
	_windup = 0.0
	_recovery = 0.0
	_attack_kind = ""
	_attack_plan = {}
	_cancel_warning()
	if is_boss and SimAuthority.is_authority():
		SimAuthority.end_mob_telegraph(self)

# ------------------------------------------------------------------ corpse

## Corpse lifetime is matched to the death animation (plan.md Phase 11): the
## body holds its collapse pose for the clip's length, then sinks and fades.
func _tick_corpse(delta: float) -> void:
	_corpse_time += delta
	if _corpse_time <= _corpse_lifetime:
		return
	var fade := _corpse_time - _corpse_lifetime
	if visuals:
		visuals.position.y = -minf(2.5, fade * 1.6)
	if fade > 1.4:
		hide()
		if summoned and not sim_puppet:
			queue_free()
	if not sim_puppet and not managed_respawn and not summoned and _corpse_time > _respawn_delay:
		_respawn()

func _death_animation_seconds() -> float:
	if is_instance_valid(anim_player):
		var clip := _clip_for("death")
		if anim_player.has_animation(clip):
			return maxf(1.0, anim_player.get_animation(clip).length)
	return 2.0

# ------------------------------------------------------------------- states

func _idle_and_wander(delta: float) -> void:
	# A stale target (killed, protected, gone) must not leave the pack standing
	# in the field: it walks home and the encounter resets.
	if target_player != null:
		if _valid_target():
			_set_state(State.CHASE)
		else:
			_break_fight("no_target")
		return
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
			_set_state(State.IDLE)
			wander_timer = randf_range(2, 5)
	else:
		velocity.x = 0
		velocity.z = 0
		_play_slot("idle")
		wander_timer -= delta
		if wander_timer <= 0:
			var angle := randf() * TAU
			wander_target = spawn_point + Vector3(cos(angle), 0, sin(angle)) * randf_range(1, 3)
			wander_timer = 4
			_set_state(State.WANDER)

func aggro_on(player: Node3D, alert_pack: bool = true) -> void:
	if state in [State.DEAD, State.RETURN] or not Rules.can_damage(self, player):
		return
	target_player = player
	if state != State.STUNNED:
		_set_state(State.CHASE)
	if alert_pack and pack_id > 0:
		for mob in get_tree().get_nodes_in_group("mobs"):
			if mob != self and mob.pack_id == pack_id and global_position.distance_to(mob.global_position) <= assist_radius:
				mob.aggro_on(player, false)

func _valid_target() -> bool:
	if not Rules.can_damage(self, target_player):
		return false
	var record := SimAuthority.record_for(target_player) if SimAuthority.is_authority() else {}
	var own := SimAuthority.record_for(self) if SimAuthority.is_authority() else {}
	if not record.is_empty() and not own.is_empty():
		if String(record.get("map_id", "")) != String(own.get("map_id", "")):
			return false
	return true

## Effective leash: a boss is tethered to its arena when the encounter data
## defines one, everything else to its pack anchor.
func _leash_limit() -> float:
	if is_boss and boss_arena_radius > 0.0:
		return boss_arena_radius
	return leash_distance

func _fight(delta: float) -> void:
	if not _valid_target() or global_position.distance_to(pack_anchor) > _leash_limit():
		# Losing every valid target (or breaking the leash) resets the encounter:
		# the pack walks home and the authority cancels its reward credit.
		_break_fight("no_target" if _valid_target() == false else "leash")
		return
	var distance := global_position.distance_to(target_player.global_position)
	var reach := 15.0 if is_ranged else attack_range
	var engaged := _has_attack_slot()
	if distance > reach or not Rules.has_line_of_sight(self, target_player) or not engaged:
		_set_state(State.CHASE)
		if not engaged and not is_ranged:
			# Attack slots: a bounded number of pack mates melee the same
			# target, the rest hold a spread ring instead of stacking on the
			# point (plan.md Phase 11).
			_hold_attack_ring(delta)
			return
		_move_to(target_player.global_position, move_speed, delta)
	else:
		_set_state(State.ATTACK)
		velocity.x = 0
		velocity.z = 0
		_face_direction(target_player.global_position - global_position, delta)
		if attack_timer <= 0 and attack_phase == AttackPhase.NONE:
			attack_timer = attack_cooldown
			_begin_attack(_choose_plan())

## At most `attack_slots` pack mates may attack one target at a time; ties are
## broken by instance id so the choice is stable on every client.
func _has_attack_slot() -> bool:
	if is_boss or is_ranged or pack_id <= 0 or not is_instance_valid(target_player):
		return true
	var slots := int(HPRules.pack_tuning("attack_slots", 3.0))
	var mine := get_instance_id()
	var ahead := 0
	for mob in get_tree().get_nodes_in_group("mobs"):
		if mob == self or mob.pack_id != pack_id or mob.target_player != target_player:
			continue
		if mob.state == State.DEAD:
			continue
		if mob.get_instance_id() >= mine:
			continue
		if mob.attack_phase != AttackPhase.NONE \
				or (mob.global_position.distance_to(target_player.global_position) <= mob.attack_range + 0.8):
			ahead += 1
	return ahead < slots

## Wait on a ring around the target: separation keeps the ring spread out even
## when several members are waiting.
func _hold_attack_ring(delta: float) -> void:
	var ring := float(HPRules.pack_tuning("attack_slot_ring", 3.4))
	var slot := target_player.global_position + Vector3(cos(_ring_angle()), 0, sin(_ring_angle())) * ring
	_move_to(slot, move_speed * 0.7, delta)

## Evenly spread ring positions inside the pack: the members sort themselves by
## instance id, so every waiting mob picks a distinct slice of the ring.
func _ring_angle() -> float:
	var ids: Array = []
	for mob in get_tree().get_nodes_in_group("mobs"):
		if mob.pack_id == pack_id and mob.state != State.DEAD:
			ids.append(mob.get_instance_id())
	ids.sort()
	var index := ids.find(get_instance_id())
	return TAU * float(maxi(0, index)) / float(maxi(1, ids.size()))

func _return_home(delta: float) -> void:
	_move_to(spawn_point, move_speed, delta)
	if global_position.distance_to(spawn_point) < 1.3:
		current_hp = max_hp
		_set_state(State.IDLE)
		_update_label()

## Every member that has nothing left to fight walks home; when the last one is
## home the encounter resets (rewards cancelled by the authority).
func _break_fight(reason: String) -> void:
	_cancel_attack()
	target_player = null
	_set_state(State.RETURN)
	if SimAuthority.is_authority():
		SimAuthority.reset_encounter(pack_id, reason)

# ----------------------------------------------------------------- movement

func _move_to(point: Vector3, speed: float, delta: float) -> void:
	var direction := point - global_position
	direction.y = 0
	if direction.length_squared() < 0.0001:
		velocity.x = 0
		velocity.z = 0
		return
	direction = direction.normalized()
	direction = _steer(direction)
	# Local separation: five mobs must not occupy one point (plan.md Phase 11).
	var push := _separation()
	if push.length_squared() > 0.0001:
		direction = (direction + push * float(HPRules.pack_tuning("separation_weight", 1.35))).normalized()
	direction = _steer(direction)
	velocity.x = direction.x * speed
	velocity.z = direction.z * speed
	_face_direction(direction, delta)
	_play_slot("run" if state in [State.CHASE, State.RETURN] else "walk")
	_check_stuck(delta)

## Obstacle steering: probe the desired direction and fan out to either side,
## so a mob walks around architecture instead of into it. The world has no
## baked navigation mesh, so this is the obstacle-avoidance layer.
func _steer(direction: Vector3) -> Vector3:
	var offsets := [0.0, 0.5, -0.5, 1.0, -1.0, 1.5, -1.5]
	for offset in offsets:
		var probe := direction.rotated(Vector3.UP, float(offset))
		if _path_clear(probe):
			return probe
	return direction

func _path_clear(direction: Vector3) -> bool:
	var space := get_world_3d().direct_space_state
	var query := PhysicsRayQueryParameters3D.create(global_position + Vector3.UP,
		global_position + Vector3.UP + direction * 2.2, 1)
	return space.intersect_ray(query).is_empty()

## Nudges the body sideways when it has barely moved while trying to: a body
## wedged on scenery should slide along it, not vibrate in place.
func _check_stuck(delta: float) -> void:
	var moved := global_position.distance_to(_last_pos)
	if moved < 0.02 * maxf(0.2, delta * 60.0):
		_stuck_timer += delta
	else:
		_stuck_timer = 0.0
	_last_pos = global_position
	if _stuck_timer > 0.6:
		_stuck_timer = 0.0
		velocity = velocity.rotated(Vector3.UP, PI * 0.5) * 1.0

func _separation() -> Vector3:
	var radius := float(HPRules.pack_tuning("separation_radius", 1.7))
	var push := Vector3.ZERO
	for mob in get_tree().get_nodes_in_group("mobs"):
		if mob == self or mob.state == State.DEAD:
			continue
		var offset: Vector3 = global_position - (mob as Node3D).global_position
		offset.y = 0
		var distance := offset.length()
		if distance > 0.01 and distance < radius:
			push += (offset / distance) * (1.0 - distance / radius)
	return push

func _face_direction(direction: Vector3, delta: float) -> void:
	if Vector2(direction.x, direction.z).length_squared() > 0.001:
		visuals.rotation.y = lerp_angle(visuals.rotation.y, atan2(direction.x, direction.z), minf(1, delta * 10))

# ------------------------------------------------------------------ warning

## Server-side telegraph mesh (also the shape the client puppet draws). Built
## from the attack plan: a disc for an area attack, a stretched lune for a
## directional one. `_warning_fill` is the event horizon: it fills over the
## anticipation and is exactly full at the authoritative release tick.
## Phase 12 hook: the layered boss-warning effect scene (spells/boss_warning.gd)
## is attached to the ground mask. The mask itself must stay a MeshInstance3D
## with a CylinderMesh: the multiplayer probe reads its `top_radius` to prove the
## replicated warning matches the authoritative hit area.
var _warning_effect: Node3D
var _voice_timer := 0.0


## Phase 12 audio hook: play a creature voice at this body's position.
func _play_voice(key: String) -> void:
	var audio := get_node_or_null("/root/AudioManager")
	if audio == null:
		return
	audio.call("play_sound_at", key, global_position, self)

func _show_warning(plan: Dictionary = {}) -> void:
	if is_instance_valid(_warning):
		_warning.queue_free()
	var kind := String(plan.get("kind", "slam" if _attack_kind == "slam" else _attack_kind))
	var radius := float(plan.get("radius", 5.5))
	var length := float(plan.get("range", 8.0))
	var width := maxf(2.0, 2.0 * length * sin(float(plan.get("half_angle", 0.6))))
	var mesh := CylinderMesh.new()
	if kind == "directional":
		mesh.top_radius = length
		mesh.bottom_radius = length
		mesh.height = 0.03
	else:
		mesh.top_radius = radius
		mesh.bottom_radius = radius
		mesh.height = 0.03
	var mat := StandardMaterial3D.new()
	mat.albedo_color = Color(1, 0.15, 0.06, 0.36)
	mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	# Phase 12: the hit-area mask carries the rune/ground-mark texture so the
	# area itself reads as magic rather than as a flat red disc.
	mat.albedo_texture = load("res://assets/vfx/atlases/rune_masks_2x2_1k.png")
	# cell 0 of the 2x2 rune atlas (the telegraph circle)
	mat.uv1_scale = Vector3(0.5, 0.5, 1.0)
	mat.uv1_offset = Vector3(0.0, 0.0, 0.0)
	mesh.material = mat
	_warning = MeshInstance3D.new()
	_warning.mesh = mesh
	if kind == "directional":
		_warning.scale = Vector3(1.0, 1.0, width / maxf(0.01, length))
	get_parent().add_child(_warning)
	_warning.global_position = _attack_center + Vector3.UP * 0.08
	if kind == "directional":
		_warning.rotation.y = atan2(_attack_dir.x, _attack_dir.z)
	_attach_warning_effect(plan, kind, radius, length, width)


## Phase 12 hook: layer the warning effect (edge ring, countdown ring, rim
## motes, pulse light, charge/release cues) on the authoritative mask. Its
## timing comes from the telegraph's own start/release ticks.
func _attach_warning_effect(plan: Dictionary, kind: String, radius: float, length: float, width: float) -> void:
	if _warning == null or not is_instance_valid(_warning):
		return
	var scene: PackedScene = load("res://scenes/spells/fx_boss_warning.tscn")
	if scene == null:
		return
	var effect := scene.instantiate()
	_warning.add_child(effect)
	if not effect.has_method("setup"):
		effect.queue_free()
		return
	_warning_effect = effect
	var data := plan.duplicate(true)
	data["kind"] = kind
	data["radius"] = radius
	data["range"] = length
	data["half_angle"] = float(plan.get("half_angle", 0.6))
	data.erase("telegraph")
	effect.call("setup", data)


func _cancel_warning() -> void:
	if is_instance_valid(_warning):
		_warning.queue_free()
	_warning = null
	_warning_fill = null
	_warning_effect = null

# ---------------------------------------------------------------- resolution

func _resolve_attack(plan: Dictionary) -> void:
	var kind := String(plan.get("kind", _attack_kind))
	if kind == "":
		kind = _attack_kind
	var center := _attack_center
	var power := int(attack_power * (0.65 if _weaken_timer > 0 else 1.0))
	var multiplier := float(plan.get("damage_multiplier", 1.0))
	if kind == "area" or kind == "slam":
		var radius := float(plan.get("radius", 5.5))
		FX.play_impact(get_parent(), center, "bombarda")
		# AoE victims are chosen by the engine from its own entity table: a
		# protected player inside the circle simply is not a victim.
		SimAuthority.mob_area_attack(self, center, radius, int(power * multiplier), "boss_area" if is_boss else "boss_slam")
	elif kind == "directional":
		var range_len := float(plan.get("range", 8.0))
		var half_angle := float(plan.get("half_angle", 0.6))
		FX.play_cast(get_parent(), self, "expelliarmus", global_position + Vector3.UP * 1.2, _attack_dir)
		SimAuthority.mob_cone_attack(self, _attack_dir, half_angle, range_len, int(power * multiplier), "boss_cone")
	elif kind == "ranged":
		if _valid_target() and Rules.has_line_of_sight(self, target_player):
			var dir := (target_player.global_position + Vector3.UP - (global_position + Vector3.UP * 1.2)).normalized()
			FX.play_cast(get_parent(), self, "stupefy", global_position + Vector3.UP * 1.2, dir)
			SimAuthority.mob_projectile(self, "stupefy", dir, power)
	elif _valid_target() and Rules.has_line_of_sight(self, target_player):
		if global_position.distance_to(target_player.global_position) <= attack_range + 0.4:
			_play_voice("spider_bite")
			SimAuthority.mob_melee(self, target_player, power)

# ------------------------------------------------------------------- damage

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
	if stun_ms > 0:
		_cancel_attack()
		_set_state(State.STUNNED)
		stun_timer = float(stun_ms) / 1000.0
	if weaken_ms > 0:
		_weaken_timer = float(weaken_ms) / 1000.0
	_update_label()

## Authority death notification: the engine already paid the rewards and dropped
## the loot, so this is the body's part only.
func on_authoritative_death(killer: Node3D) -> void:
	_play_voice("boss_death" if is_boss else "spider_death")
	_cancel_attack()
	_cancel_warning()
	_set_state(State.DEAD)
	_publish_state()
	velocity = Vector3.ZERO
	remove_from_group("targetable")
	_set_collision_enabled(false)
	_corpse_lifetime = _death_animation_seconds()
	_play_slot("death", 0.08)
	var spider := visuals.get_node_or_null("SpiderRig")
	if spider and spider.has_method("die"):
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

## Full reset for a new life. Everything the previous life touched is cleared:
## health, statuses, target, attack phase, warning, corpse pose, animation,
## collision and group membership - a respawned (or pooled) body must not
## remember who it was fighting.
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
	_pattern_index = 0
	_cancel_attack()
	_corpse_time = 0
	_stuck_timer = 0
	_published_state = -1
	_puppet_state = -1
	_set_state(State.IDLE)
	visuals.position = Vector3.ZERO
	visuals.rotation = Vector3.ZERO
	var spider := visuals.get_node_or_null("SpiderRig")
	if spider and spider.has_method("reset_pose"):
		spider.reset_pose()
	show()
	add_to_group("targetable")
	_set_collision_enabled(true)
	_play_slot("idle")
	_update_label()
	if SimAuthority.is_authority():
		SimAuthority.refresh_mob(self)

func _exit_tree() -> void:
	_cancel_attack()
	_cancel_warning()
	SimAuthority.unregister_node(self)

# ------------------------------------------------------------------ puppets

## A client's view of a server-owned mob: position/rotation interpolation plus
## presentation chosen from the replicated state byte. No damage, no AI.
func _update_puppet(delta: float) -> void:
	global_position = global_position.lerp(sim_target_pos, minf(1.0, 12.0 * delta))
	if visuals:
		visuals.rotation.y = lerp_angle(visuals.rotation.y, sim_target_rot, minf(1.0, 12.0 * delta))
	var record := SimAuthority.record_for(self)
	if record.is_empty():
		return
	_draw_telegraph(record)
	var replicated := int(record.get("state", HPProtocol.MobState.IDLE))
	# A replica learns it is a boss from the replicated flag, not from the
	# scene: swap in the boss body the first time the flag is seen.
	if not is_boss and (int(record.get("flags", 0)) & HPProtocol.FLAG_BOSS) != 0:
		is_boss = true
		_apply_boss_visual()
	var dead := bool(record.get("dead", false))
	if dead:
		if state != State.DEAD:
			_enter_puppet_death(record)
		return
	if state == State.DEAD:
		return
	if replicated != _puppet_state:
		_puppet_state = replicated
		_play_puppet_clip(replicated, record)

func _enter_puppet_death(record: Dictionary) -> void:
	_cancel_warning()
	state = State.DEAD
	_corpse_lifetime = _death_animation_seconds()
	_corpse_time = 0.0
	velocity = Vector3.ZERO
	remove_from_group("targetable")
	_set_collision_enabled(false)
	_play_slot("death", 0.08)

func _play_puppet_clip(replicated: int, record: Dictionary) -> void:
	match replicated:
		HPProtocol.MobState.CHASE, HPProtocol.MobState.RETURN:
			_play_slot("run")
		HPProtocol.MobState.ANTICIPATION:
			var telegraph: Dictionary = record.get("telegraph", {})
			if telegraph.is_empty():
				_play_slot("anticipation", 0.08)
			else:
				_play_attack_clip(telegraph, "anticipation")
		HPProtocol.MobState.ATTACK:
			_play_slot("attack", 0.06)
		HPProtocol.MobState.RECOVERY:
			_play_slot("idle")
		HPProtocol.MobState.STUNNED:
			_play_slot("stun", 0.1)
		HPProtocol.MobState.WANDER, HPProtocol.MobState.IDLE:
			_play_slot("idle")
		_:
			pass

## Draw the boss warning from the authoritative telegraph. The shape and the
## fill are the server's data; the client never decides when the hit lands.
func _draw_telegraph(record: Dictionary) -> void:
	var data: Dictionary = record.get("telegraph", {})
	if data.is_empty():
		if is_instance_valid(_warning):
			_cancel_warning()
		return
	var release_tick := int(data.get("release_tick", 0))
	var start_tick := int(data.get("start_tick", release_tick))
	if SimAuthority.sim_tick > int(data.get("recovery_until_tick", release_tick)) + 2:
		_cancel_warning()
		return
	if not is_instance_valid(_warning):
		_show_warning(data)
	if not is_instance_valid(_warning):
		return
	_warning.global_position = (data.get("center", global_position) as Vector3) + Vector3.UP * 0.08
	var span := maxf(1.0, float(release_tick - start_tick))
	var progress := clampf(float(SimAuthority.sim_tick - start_tick) / span, 0.0, 1.0)
	var mat := (_warning.mesh as CylinderMesh).material as StandardMaterial3D
	if mat:
		mat.albedo_color = Color(1.0, 0.15 + 0.35 * progress, 0.06, 0.22 + 0.3 * progress)
	# Phase 12 hook: the layered effect's countdown fill is driven by the same
	# authority ticks this fill is - never by a client-side guess.
	if is_instance_valid(_warning_effect) and _warning_effect.has_method("set_progress"):
		_warning_effect.call("set_progress", progress)
