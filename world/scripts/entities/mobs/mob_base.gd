extends CharacterBody3D

## Ordinary mob / boss body. Runs the AI on the authority (dedicated server,
## host, or the single-player client); on a client it is a PUPPET that renders
## the replicated state and never decides anything (the authority and creature replication).
##
## Creature pass AI contract:
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

## Explicit attack phases. `_windup`/`_recovery` are the
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
## The bolt a ranged creature throws (a spells.json id): a snatcher's wand
## Stupefy, a goblin hexer's wandless arcane blast.
@export var bolt_spell := "stupefy"
@export var pack_id := 0:
	set(value):
		if value == pack_id:
			return
		_pack_index_remove()
		pack_id = value
		if is_inside_tree():
			_pack_index_add()
@export var pack_anchor := Vector3.ZERO
@export var is_boss := false
@export var is_commander := false
## encounter metadata (set by the encounter director from server data).
@export var encounter_id := ""
@export var escort_count := 0
@export var boss_style := ""
@export var boss_arena_radius := 0.0
## Animation set this body's clips come from ("spider", "wizard", "generic").
@export var anim_set := "generic"
## Creature voice family for the move/alert/attack/death cues ("spider",
## "snatcher", "inferi"). Empty falls back to "spider".
@export var voice_set := ""
## Ground speed the walk cycle was authored for (0 = unknown, no scaling).
@export var walk_speed := 0.0
## Ground speed the run cycle was authored for (0 = scale it like the walk).
## A troll's charge cycle covers ~10 m/s; scaled by the walk speed it played
## three times too fast and the body seemed to run on the spot.
@export var run_speed := 0.0
## Creature catalog identity (mobs.json): species id, the elite roll, the
## resistance map and loot table the authority uses. The encounter director
## sets them; a mob spawned another way (monolith wave) fills them from the
## catalog by its scene name.
@export var species := ""
@export var is_elite := false
@export var resist: Dictionary = {}
@export var loot_table := ""
## Ordinary attack timing for heavy creatures (0 = the MELEE_/RANGED_
## defaults). The anticipation/attack clips are time-stretched to fit, so a
## troll's 1.5 s authored windup lands exactly on the server's release.
@export var attack_anticipation := 0.0
@export var attack_recovery := 0.0
## Special attacks (mobs.json `abilities`): telegraphed patterns an ordinary
## creature mixes in - `every` N attacks (troll slam, dementor kiss) or, with
## `max_range`, thrown at a target out of reach (troll boulder).
@export var abilities: Array = []
## Passive cold aura (mobs.json `aura`), resolved by the authority each
## regeneration beat while this creature fights.
@export var aura: Dictionary = {}
## D1 creature rules the authority reads at registration: an immune body takes
## no damage (a multi-part creature while its parts stand), a shield-bearer
## shrugs off `front_guard` of a blow from in front, a part pays no rewards.
@export var immune := false
@export var front_guard := 0.0
var no_rewards := false
var _attack_count := 0
var _ability_ready_tick: Dictionary = {}
var _boulder_tick := -1

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
## Slow efsun proc (authority): move and attack speed x _slow_factor while it runs.
var _slow_timer := 0.0
var _slow_factor := 1.0
## A throw (authority apply_launch: Bombarda, Expelliarmus): the body flies on
## its own velocity and the AI waits until it is down again.
var _airborne := false
var _launch_velocity := Vector3.ZERO
var _launch_time := 0.0
## Presentation pace from crowd control (StatusFX: 0 = frozen pose, the slowed
## share while slowed) on top of the clip speed the AI chose.
var cc_anim_scale := 1.0
var _anim_speed_base := 1.0
var _status_poll := 0.0
var _scan_timer := 0.0
var _stuck_timer := 0.0
var _last_pos := Vector3.ZERO
## Obstacle handling: a committed sidestep round something the steering could
## not see past (a trunk, a boulder), which side the mob is going round, and
## the body's half width for the probes.
var _detour_dir := Vector3.ZERO
var _detour_time := 0.0
var _steer_side := 1.0
var _body_radius := -1.0
## AI query throttles (see _steer, _sees_target and the zone check in
## _physics_process): the answers are reused for a fraction of a second.
const STEER_REFRESH := 0.1
const SIGHT_REFRESH := 0.2
const ZONE_CHECK_PERIOD := 0.25
var _steer_in := Vector3.ZERO
var _steer_out := Vector3.ZERO
var _steer_age := 1.0
var _sight_age := 1.0
var _sight_ok := false
var _sight_target: Node3D = null
var _zone_check_timer := 0.0
## Last replicated AI state a client view rendered (puppets only).
var _puppet_state := -1
## Last v14 mob-info revision a client view applied (puppets only).
var _info_rev := -1
## True when this node is a CLIENT'S VIEW of a mob the world server owns: it
## runs no AI, applies no damage, and just follows the replicated state.
var sim_puppet := false
var sim_target_pos := Vector3.ZERO
var sim_target_rot := 0.0
## Buffered snapshot interpolation for this view (game_world pushes every
## replicated sample; see ReplicaMotion).
var sim_motion := ReplicaMotion.new()
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
	# Meshy-rigged trolls (art/pipeline/scripts/meshy_merge_clips.py).
	"troll": {"idle": "Idle", "walk": "Walk", "run": "Run", "turn": "Walk",
		"anticipation": "Swing_Anticipation", "attack": "Swing_Attack", "hit": "Hit",
		"stun": "Hit", "death": "Death"},
	# Meshy-rigged wand casters (Dark Snatcher, art/creatures/snatcher): a short
	# charged wand thrust is the ordinary attack; Cast (quick draw) and Charge
	# stay in the GLB for patterns.
	"caster": {"idle": "Idle", "walk": "Walk", "run": "Run", "turn": "Walk",
		"anticipation": "Charge2_Anticipation", "attack": "Charge2_Attack", "hit": "Hit",
		"stun": "Hit", "death": "Death"},
	# Meshy-rigged Inferi (art/creatures/inferius): mummy stagger, two-handed
	# lunge, Roar = Zombie_Scream.
	"undead": {"idle": "Idle", "walk": "Walk", "run": "Run", "turn": "Walk",
		"anticipation": "Swing_Anticipation", "attack": "Swing_Attack", "hit": "Hit",
		"stun": "Hit", "death": "Death"},
	# Meshy-rigged Gringotts goblins (art/creatures/goblin): claw slash.
	"goblin": {"idle": "Idle", "walk": "Walk", "run": "Run", "turn": "Walk",
		"anticipation": "Swing_Anticipation", "attack": "Swing_Attack", "hit": "Hit",
		"stun": "Hit", "death": "Death"},
	# Goblin hexers (the Meshy goblin again, art/creatures/goblin/meshy_hexer):
	# a wandless two-handed push blast (mage_soell_cast_3) is the ordinary attack.
	"goblin_caster": {"idle": "Idle", "walk": "Walk", "run": "Run", "turn": "Walk",
		"anticipation": "Cast_Anticipation", "attack": "Cast_Attack", "hit": "Hit",
		"stun": "Hit", "death": "Death"},
	# Floating wraiths (art/pipeline/scripts/wraith_rig.py).
	"wraith": {"idle": "Idle", "walk": "Float", "run": "Float", "turn": "Float",
		"anticipation": "Reach_Anticipation", "attack": "Reach_Attack", "hit": "Hit",
		"stun": "Stun", "death": "Death"},
	# D1 Forbidden Corridor. Procedural rigs: hound_rig.py (Fluffy), snare_rig.py;
	# Meshy rigs: the armours (meshy_merge_clips.py --pole) and the pixie.
	"hound": {"idle": "Idle", "walk": "Walk", "run": "Run", "turn": "Walk",
		"anticipation": "Bite_Anticipation", "attack": "Bite_Attack", "hit": "Hit",
		"stun": "Sleep", "death": "Death"},
	"snare": {"idle": "Idle", "walk": "Idle", "run": "Idle", "turn": "Idle",
		"anticipation": "Lash_Anticipation", "attack": "Lash_Attack", "hit": "Hit",
		"stun": "Hit", "death": "Death"},
	"knight": {"idle": "Idle", "walk": "Walk", "run": "Run", "turn": "Walk",
		"anticipation": "Swing_Anticipation", "attack": "Swing_Attack", "hit": "Hit",
		"stun": "Hit", "death": "Death"},
	"pixie": {"idle": "Idle", "walk": "Run", "run": "Run", "turn": "Run",
		"anticipation": "Swing_Anticipation", "attack": "Swing_Attack", "hit": "Hit",
		"stun": "Hit", "death": "Death"},
	"generic": {"idle": "Idle", "walk": "Walking_A", "run": "Running_A", "turn": "Running_A",
		"anticipation": "1H_Melee_Attack_Chop", "attack": "1H_Melee_Attack_Chop",
		"hit": "Hit_A", "stun": "Hit_A", "death": "Death_A"},
}

## Creature voices per family: each species in the world gets its own material
## instead of every monster borrowing the spider's. Bosses use their own alert
## and death cue regardless of family.
const VOICE_SETS := {
	"troll": {"move": "troll_move_%d", "alert": "troll_alert", "attack": "troll_attack", "death": "troll_death"},
	"dementor": {"move": "dementor_move_%d", "alert": "dementor_alert", "attack": "dementor_attack", "death": "dementor_death"},
	"hound": {"move": "hound_move_%d", "alert": "hound_alert", "attack": "hound_attack", "death": "hound_death"},
	"pixie": {"move": "pixie_move_%d", "alert": "pixie_alert", "attack": "pixie_attack", "death": "pixie_death"},
	"armour": {"move": "armour_move_%d", "alert": "armour_alert", "attack": "armour_attack", "death": "armour_death"},
	"snare": {"move": "snare_move_%d", "alert": "snare_alert", "attack": "snare_attack", "death": "snare_death"},
	"spider": {"move": "spider_move_%d", "alert": "spider_alert", "attack": "spider_bite", "death": "spider_death"},
	"snatcher": {"move": "snatcher_move_%d", "alert": "snatcher_alert", "attack": "snatcher_attack", "death": "snatcher_death"},
	"inferi": {"move": "inferi_move_%d", "alert": "inferi_alert", "attack": "inferi_attack", "death": "inferi_death"},
	"goblin": {"move": "goblin_move_%d", "alert": "goblin_alert", "attack": "goblin_attack", "death": "goblin_death"},
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
	_fill_catalog_identity()
	if SimAuthority.is_authority():
		SimAuthority.refresh_mob(self)
	_apply_boss_visual()
	_apply_lod()
	wander_timer = randf_range(1, 4)
	_scan_timer = randf_range(0, 0.4)
	_last_pos = global_position
	_play_slot("idle")
	_update_label()

## A body nobody configured (monolith waves, test fixtures) still belongs to a
## species: take its resistances and loot table from the catalog entry its
## scene file names (`mob_<species>.tscn`).
func _fill_catalog_identity() -> void:
	if species == "" and scene_file_path != "":
		species = scene_file_path.get_file().get_basename().trim_prefix("mob_")
	var def := HPRules.mob_def(species)
	if def.is_empty():
		return
	if resist.is_empty():
		resist = (def.get("resist", {}) as Dictionary).duplicate()
	if loot_table == "":
		loot_table = String(def.get("loot_table", ""))
	if abilities.is_empty():
		abilities = (def.get("abilities", []) as Array).duplicate(true)
	if aura.is_empty():
		aura = (def.get("aura", {}) as Dictionary).duplicate()
	if front_guard <= 0.0:
		front_guard = float(def.get("front_guard", 0.0))

## Boss bodies are authored creatures, not a scaled-up ordinary mob: the scene
## carries `Visuals/NormalVariant` and `Visuals/BossVariant`, and the boss flag
## (set by the director on the server, replicated as FLAG_BOSS to clients)
## selects which one is visible and which AnimationPlayer drives the body.
func _apply_boss_visual() -> void:
	var boss_node := visuals.get_node_or_null("BossVariant")
	var normal := visuals.get_node_or_null("NormalVariant")
	if boss_node:
		boss_node.visible = is_boss
	if normal and boss_node:
		normal.visible = not is_boss   # one body serves both when there is no boss variant
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
	# The dedicated server never draws a creature: its skeletons need no posing
	# (1700 AnimationPlayers ticking cost the headless world most of its frame).
	if NetworkManager.is_dedicated_server and visuals:
		for player in visuals.find_children("*", "AnimationPlayer", true, false):
			(player as AnimationPlayer).active = false
		# Nor does it keep what only a screen needs: an ordinary creature drops its
		# unused boss body and every mesh (~0.1 MB a body, thousands of bodies).
		# Bosses keep theirs (multipart creatures read their skeleton).
		if not is_boss:
			if boss_node != null and normal != null:
				boss_node.free()
			for mesh in visuals.find_children("*", "MeshInstance3D", true, false):
				mesh.free()
	if anim_player:
		# Imported monster animations use different names from the wizard rig.
		for animation in anim_player.get_animation_list():
			var clip := anim_player.get_animation(animation)
			clip.loop_mode = Animation.LOOP_LINEAR if animation in ["Idle", "Walk", "Run", "Walking_A",
				"Running_A", "Stun", "Stun_Loop", "Float", "Sleep"] else Animation.LOOP_NONE

## LOD switch for bodies whose GLB ships a second skinned mesh (Creature pass
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
func _update_anim_speed(slot: String = "walk") -> void:
	if not is_instance_valid(anim_player):
		return
	# The ground speed the body really covers (_track_drawn_speed): a stroll,
	# a chase, a replica's interpolated glide.
	var speed := _drawn_speed
	if speed < 0.1:
		speed = move_speed
	if slot == "run" and run_speed > 0.0:
		_set_anim_speed(clampf(speed / run_speed, 0.4, 3.0))
		return
	if walk_speed <= 0.0:
		_set_anim_speed(1.0)
		return
	_set_anim_speed(clampf(speed / walk_speed, 0.55, 3.2))

func _set_anim_speed(speed: float) -> void:
	_anim_speed_base = speed
	if is_instance_valid(anim_player):
		anim_player.speed_scale = speed * cc_anim_scale

## StatusFX: hold the pose (0, frozen) or play at the slowed pace.
func set_cc_anim_scale(scale: float) -> void:
	cc_anim_scale = scale
	_set_anim_speed(_anim_speed_base)

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

## Smoothed planar speed the body covers, and whether that reads as moving
## (hysteresis, so a body on the threshold does not flicker idle/walk).
var _drawn_speed := 0.0
var _drawn_moving := false

func _track_drawn_speed(speed: float, delta: float) -> void:
	_drawn_speed = lerpf(_drawn_speed, speed, minf(1.0, delta * 8.0))
	_drawn_moving = _drawn_speed > (0.15 if _drawn_moving else 0.35)

## Walk/run only while the body really moves: a mob held up (its ring place
## reached, a crowd in front) stands instead of running on the spot, and a
## replica that strolls walks instead of gliding in its idle pose.
func _play_locomotion(moving_slot: String) -> void:
	_play_slot(moving_slot if _drawn_moving else "idle")

func _play_slot(slot: String, blend: float = 0.18) -> void:
	if not is_instance_valid(anim_player):
		return
	if slot in ["walk", "run"]:
		_update_anim_speed(slot)
	else:
		# The walk-cycle scale must not leak into attacks and reactions.
		_set_anim_speed(1.0)
	var clip := _clip_for(slot)
	if anim_player.has_animation(clip) and (anim_player.current_animation != clip or not anim_player.is_playing()):
		anim_player.play(clip, blend, _phase_speed(slot, clip))

## Time-stretch for an attack phase clip so it spans the authored phase
## (attack_anticipation / attack_recovery); 1.0 for everything else.
func _phase_speed(slot: String, clip: String) -> float:
	var span := attack_anticipation if slot == "anticipation" else (attack_recovery if slot == "attack" else 0.0)
	if span <= 0.0 or not anim_player.has_animation(clip):
		return 1.0
	return clampf(anim_player.get_animation(clip).length / span, 0.4, 3.0)

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
			# The run cycle's scale must not leak in (a boulder throw played at
			# 0.43x looked like slow motion); stretch the clip over its phase.
			_set_anim_speed(1.0)
			var span := float(plan.get("anticipation" if phase == "anticipation" else "recovery", 0.0))
			var speed := 1.0
			if span > 0.0:
				speed = clampf(anim_player.get_animation(clip).length / span, 0.5, 3.0)
				if phase != "anticipation":
					speed = maxf(1.0, speed)   # a follow-through only ever speeds up
			anim_player.play(clip, blend, speed)
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
	if NetworkManager.is_dedicated_server:
		return   # no screen: the nameplate text was re-laid-out on every hit
	if label == null:
		label = get_node_or_null("Label3D")
	if label == null:
		return
	label.text = "[Lv.%d] %s%s\n%d / %d" % [level, I18n.mob_name(mob_name), tr(" • ENRAGED") if is_enraged else "", current_hp, max_hp]
	if is_boss:
		label.modulate = Color(1, 0.72, 0.25)
	elif is_elite:
		label.modulate = Color(1.0, 0.9, 0.35)
	else:
		label.modulate = Color(1, 0.6, 0.5)
	label.font_size = 26 if is_boss else (23 if is_elite else 21)
	label.visibility_range_end = 40
	WorldLabels.track(label, 17.0 if is_boss else 14.0)

# ---------------------------------------------------------------- main tick

## Presentation LOD: a body far from the camera stops drawing and stops
## posing its skeleton. Offline play runs every pack on the map in this
## process (~170 skinned creatures), so this is what keeps an integrated GPU
## and its CPU out of the animation bill. AI, timers and the authority are
## untouched; the dedicated server draws nothing and never gets here.
const VISUAL_RANGE := 120.0
var _lod_timer := 0.0
var _visual_dormant := false

func _tick_visual_lod(delta: float) -> void:
	_lod_timer -= delta
	if _lod_timer > 0.0:
		return
	_lod_timer = 0.5 + randf() * 0.1
	var cam := get_viewport().get_camera_3d()
	var dormant := cam != null and cam.global_position.distance_to(global_position) > VISUAL_RANGE
	if dormant == _visual_dormant:
		return
	_visual_dormant = dormant
	visuals.visible = not dormant
	if is_instance_valid(anim_player):
		anim_player.active = not dormant

func _physics_process(delta: float) -> void:
	if not NetworkManager.is_dedicated_server:
		_tick_visual_lod(delta)
		# Crowd control and damage over time drawn on the body (stars, ice,
		# blood, flames), from the authority's status bits.
		_status_poll -= delta
		if _status_poll <= 0.0 and not _visual_dormant:
			_status_poll = 0.1
			StatusFX.update(self, SimAuthority.status_of(self))
	# Client view of a server-owned mob: no AI, no damage, no physics authority -
	# only interpolation towards the last replicated sample, presentation from
	# the replicated state byte, and the boss warning drawn from the server's
	# start/release ticks.
	if sim_puppet:
		_update_puppet(delta)
		if state == State.DEAD:
			_tick_corpse(delta)
		return
	# spell-effect hook: an AUTHORITY body inside a client process (offline and
	# listen-host play) draws the boss warning from the same replicated ticks a
	# connected client uses, so single-player shows exactly what a client sees.
	# The dedicated server draws nothing.
	if (is_boss or not abilities.is_empty()) and not NetworkManager.is_dedicated_server:
		var authored_record := SimAuthority.record_for(self)
		if not authored_record.is_empty():
			_draw_telegraph(authored_record)
	# spell-effect hook: creature voices. Movement, bite and death cues come from the
	# sound library by creature type. Presentation only - nothing here can
	# change damage, AI or rewards.
	if not is_boss and state == State.CHASE:
		_voice_timer -= delta
		if _voice_timer <= 0.0:
			_voice_timer = randf_range(0.45, 0.9)
			_play_voice(_voice_key("move", randi() % 3 + 1))
	if state == State.DEAD:
		_tick_corpse(delta)
		return
	# Enemies displaced inside a protected volume cancel the fight and
	# walk home instead of attacking through the boundary. Four times a second
	# is plenty for a body walking at a few metres per second.
	_zone_check_timer -= delta
	if _zone_check_timer <= 0.0:
		_zone_check_timer = ZONE_CHECK_PERIOD
		if state != State.RETURN and SafeZone.is_protected_point(global_position) and not SafeZone.is_protected_point(spawn_point):
			_cancel_attack()
			target_player = null
			_set_state(State.RETURN)
	_steer_age += delta
	_sight_age += delta
	attack_timer = maxf(0, attack_timer - delta * _speed_scale())
	_weaken_timer = maxf(0, _weaken_timer - delta)
	_slow_timer = maxf(0, _slow_timer - delta)
	_publish_state()
	if _airborne:
		stun_timer -= delta
		_tick_airborne(delta)
		return
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
	# A creature standing still on the ground has nothing to slide: skipping the
	# collision pass for idle bodies is most of a dense hunting ground's cost.
	var standing := state == State.IDLE and attack_phase == AttackPhase.NONE and is_on_floor() 		and velocity.x == 0.0 and velocity.z == 0.0 and knockback_velocity.length_squared() < 0.01
	if not standing:
		move_and_slide()
	var real := get_real_velocity() if not standing else Vector3.ZERO
	_track_drawn_speed(Vector2(real.x, real.z).length(), delta)
	if global_position.y < -10.0:
		global_position = spawn_point
		velocity = Vector3.ZERO

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
	# from outside the pack's arena ("clear attacks ... return
	# home").
	if global_position.distance_to(pack_anchor) > _leash_limit():
		_break_fight("leash")
		return
	if attack_phase == AttackPhase.ANTICIPATION:
		# Anticipation: planted, facing locked on the direction chosen when the
		# attack began - the release uses this direction, not a live target read.
		velocity.x = 0
		velocity.z = 0
		_press_heavy_swing(delta)
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

## A heavy brute (authored windup, e.g. a troll) keeps stepping after a target
## that backs off during its swing instead of whiffing in place: stepping out of
## reach is still the dodge, but a slow walk-back is not.
func _press_heavy_swing(delta: float) -> void:
	if _attack_kind != "melee" or attack_anticipation <= 0.0 or not _valid_target():
		return
	var to: Vector3 = (target_player as Node3D).global_position - global_position
	to.y = 0.0
	if to.length() <= attack_range * 0.7:
		return
	var dir := to.normalized()
	var speed := move_speed * 0.6 * _speed_scale()
	velocity.x = dir.x * speed
	velocity.z = dir.z * speed
	_face_direction(dir, delta)

## Melee reach checked on release. A heavy swing sweeps past its trigger
## range (the club travels well beyond the body), so brutes get the extra arc.
func _melee_reach() -> float:
	return attack_range + 0.4 + (attack_range * 0.35 if attack_anticipation > 0.0 else 0.0)

## Begin an attack. Bosses walk a deterministic pattern list (directional ->
## area -> ...); ordinary mobs use the melee/ranged plan. The telegraph for a
## boss pattern is published HERE with the release tick the authority will land
## the damage on.
func _begin_attack(plan: Dictionary) -> void:
	_attack_plan = plan
	_attack_kind = String(plan.get("kind", "melee"))
	_attack_center = global_position
	# A target-locked pattern lands where the target stood when it began:
	# the warning is under their feet and stepping out of it dodges.
	if bool(plan.get("at_target", false)) and _valid_target():
		_attack_center = (target_player as Node3D).global_position
	_attack_dir = _direction_to_target()
	# An area pattern can sit ahead of (or, negative, behind) the body: a big
	# creature's paw lands in front of it and its tail sweeps behind it.
	if plan.has("offset") and not bool(plan.get("at_target", false)):
		_attack_center = global_position + _attack_dir * float(plan["offset"])
	_windup = float(plan.get("anticipation", MELEE_ANTICIPATION))
	_recovery = float(plan.get("recovery", MELEE_RECOVERY))
	attack_phase = AttackPhase.ANTICIPATION
	_play_attack_clip(plan, "anticipation")
	_publish_state()
	if bool(plan.get("telegraph", false)) and SimAuthority.is_authority():
		var release_tick := SimAuthority.sim_tick + maxi(1, int(round(_windup * float(HPProtocol.SIM_HZ))))
		SimAuthority.begin_mob_telegraph(self, plan, release_tick, _attack_dir, _attack_center)

func _release_attack() -> void:
	var plan := _attack_plan
	attack_phase = AttackPhase.RECOVERY
	_play_attack_clip(plan, "attack", 0.06)
	_set_state(State.ATTACK)
	_publish_state()
	if bool(plan.get("telegraph", false)) and SimAuthority.is_authority():
		SimAuthority.end_mob_telegraph(self)
	# spell-effect hook: the release cue fires on the authoritative release tick.
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
	_attack_count += 1
	for ability in abilities:
		var every := int((ability as Dictionary).get("every", 0))
		if every > 0 and _attack_count % every == 0:
			var plan: Dictionary = (ability as Dictionary).duplicate(true)
			plan["telegraph"] = true
			return plan
	var anticipation := RANGED_ANTICIPATION if is_ranged else MELEE_ANTICIPATION
	var recovery := RANGED_RECOVERY if is_ranged else MELEE_RECOVERY
	return {"kind": "ranged" if is_ranged else "melee",
		"anticipation": attack_anticipation if attack_anticipation > 0.0 else anticipation,
		"recovery": attack_recovery if attack_recovery > 0.0 else recovery}

## A thrown ability whose range band holds `distance` and whose cooldown has
## run out (authority clock), or {}.
func _ranged_ability(distance: float) -> Dictionary:
	for ability in abilities:
		var a: Dictionary = ability
		if not a.has("max_range"):
			continue
		if distance < float(a.get("min_range", 0.0)) or distance > float(a.get("max_range", 0.0)):
			continue
		var id := String(a.get("id", ""))
		if SimAuthority.sim_tick < int(_ability_ready_tick.get(id, 0)):
			continue
		_ability_ready_tick[id] = SimAuthority.sim_tick + int(float(a.get("cooldown", 8.0)) * HPProtocol.SIM_HZ)
		var plan := a.duplicate(true)
		plan["telegraph"] = true
		return plan
	return {}

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
	# Any telegraphed attack (boss pattern or creature ability) ends with it.
	if SimAuthority.is_authority():
		SimAuthority.end_mob_telegraph(self)

# ------------------------------------------------------------------ corpse

## Corpse lifetime is matched to the death animation: the
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
		# the proximity trigger (prototype policy 3.3).
		if aggro_mode == "aggressive":
			for player in get_tree().get_nodes_in_group("players"):
				if Rules.can_damage(self, player) and global_position.distance_to(player.global_position) < aggro_radius and Rules.has_line_of_sight(self, player):
					aggro_on(player)
					return
	if state == State.WANDER:
		_move_to(wander_target, _wander_speed(), delta)
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
			# A real stroll round the camp, not two steps on the spot.
			wander_target = spawn_point + Vector3(cos(angle), 0, sin(angle)) * randf_range(2.5, 6.0)
			wander_timer = 7
			_set_state(State.WANDER)

## Stroll pace: a person's slow stroll (WANDER_PACE) or the walk cycle's own
## ground speed if that is brisker, at most 30% of the chase speed; the clip is
## played faster to match (_update_anim_speed). The inferi and goblin cycles are
## authored very slow (0.37-0.57 m/s): at their own pace a creature took two
## steps and seemed to stand still.
const WANDER_PACE := 1.1

func _wander_speed() -> float:
	if walk_speed > 0.0:
		return minf(move_speed * 0.3, maxf(walk_speed * 1.6, WANDER_PACE))
	return move_speed * 0.3

func aggro_on(player: Node3D, alert_pack: bool = true) -> void:
	if state in [State.DEAD, State.RETURN] or not Rules.can_damage(self, player):
		return
	wake()
	var newly_aggroed := state != State.CHASE and state != State.ATTACK
	target_player = player
	if state != State.STUNNED:
		_set_state(State.CHASE)
	if newly_aggroed:
		_play_voice("boss_alert" if is_boss else _voice_key("alert"))
	if alert_pack and pack_id > 0:
		for mob in pack_mates():
			if mob != self and is_instance_valid(mob) and global_position.distance_to(mob.global_position) <= assist_radius:
				mob.aggro_on(player, false)

func _valid_target() -> bool:
	# A despawn can free the last target before this AI frame. Guard before
	# passing it to a typed Node argument (the callee cannot validate it then).
	if not is_instance_valid(target_player) or not Rules.can_damage(self, target_player):
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
	# A target out of reach may be worth a thrown attack (troll boulder).
	if attack_phase == AttackPhase.NONE and attack_timer <= 0 and distance > attack_range:
		var thrown := _ranged_ability(distance)
		if not thrown.is_empty() and Rules.has_line_of_sight(self, target_player):
			_set_state(State.ATTACK)
			velocity.x = 0
			velocity.z = 0
			_face_direction(target_player.global_position - global_position, delta)
			attack_timer = attack_cooldown
			_begin_attack(thrown)
			return
	var reach := 15.0 if is_ranged else attack_range
	var engaged := _has_attack_slot()
	if distance > reach or not _sees_target() or not engaged:
		_set_state(State.CHASE)
		if not engaged and not is_ranged:
			# Attack slots: a bounded number of pack mates melee the same
			# target, the rest hold a spread ring instead of stacking on the
			# point.
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
	for mob in pack_mates():
		if mob == self or not is_instance_valid(mob) or mob.target_player != target_player:
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
	var to_slot := slot - global_position
	to_slot.y = 0.0
	if to_slot.length() < 0.6:
		# On its place: wait facing the fight instead of jittering round the point.
		velocity.x = 0
		velocity.z = 0
		_face_direction(target_player.global_position - global_position, delta)
		_play_locomotion("run")
		return
	_move_to(slot, move_speed * 0.7, delta)

## Evenly spread ring positions inside the pack: the members sort themselves by
## instance id, so every waiting mob picks a distinct slice of the ring.
func _ring_angle() -> float:
	var ids: Array = []
	for mob in pack_mates():
		if is_instance_valid(mob) and mob.state != State.DEAD:
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
	var wanted := direction
	if _detour_time > 0.0:
		_detour_time -= delta
		# The sidestep ends as soon as the way to the goal is open again - after
		# a short committed stretch: the probes see scenery only, so a body
		# wedged behind another creature had its sidestep cancelled on the very
		# next frame and stayed wedged.
		if _detour_time < 0.5 and _path_clear(wanted):
			_detour_time = 0.0
		else:
			direction = _detour_dir
	direction = _steer(direction)
	# Local separation: five mobs must not occupy one point - and a body in the
	# way (a pack mate, another pack's creature) is gone round, not queued behind.
	var push := _separation(direction) + _bump_steer(direction)
	if push.length_squared() > 0.0001:
		direction = (direction + push * float(HPRules.pack_tuning("separation_weight", 1.35))).normalized()
		direction = _steer(direction)
	speed *= _speed_scale()
	velocity.x = direction.x * speed
	velocity.z = direction.z * speed
	_face_direction(direction, delta)
	_play_locomotion("run" if state in [State.CHASE, State.RETURN] else "walk")
	_check_stuck(delta, wanted)

## Obstacle steering: probe the desired direction and fan out to either side,
## so a mob walks around architecture instead of into it. The world has no
## baked navigation mesh, so this is the obstacle-avoidance layer. The side it
## turned to last is tried first, so it keeps going round one way instead of
## flipping left and right in front of a trunk.
func _steer(direction: Vector3) -> Vector3:
	# Up to 27 rays per call, and a chasing body steers every physics frame:
	# the last answer stands for a moment while the wanted heading holds.
	if _steer_age < STEER_REFRESH and direction.dot(_steer_in) > 0.97:
		return _steer_out
	var out := direction
	for offset in [0.0, 0.5, -0.5, 1.0, -1.0, 1.5, -1.5, 2.1, -2.1]:
		var probe := direction.rotated(Vector3.UP, float(offset) * _steer_side)
		if _path_clear(probe):
			if offset != 0.0:
				_steer_side *= signf(offset)
			out = probe
			break
	_steer_in = direction
	_steer_out = out
	_steer_age = 0.0
	return out

## Line of sight to the target, re-cast a few times a second rather than on
## every physics frame of every fighting creature.
func _sees_target() -> bool:
	if _sight_age >= SIGHT_REFRESH or _sight_target != target_player:
		_sight_age = 0.0
		_sight_target = target_player
		_sight_ok = is_instance_valid(target_player) and Rules.has_line_of_sight(self, target_player)
	return _sight_ok

## Three rays, the body's width apart, low enough to see boulders. A hit on a
## walkable slope (the hill it is climbing) does not count as blocked.
func _path_clear(direction: Vector3) -> bool:
	if _body_radius < 0.0:
		_body_radius = _collision_radius()
	var space := get_world_3d().direct_space_state
	var side := direction.cross(Vector3.UP).normalized() * minf(_body_radius, 1.2) * 0.85
	var reach := _body_radius + 1.7
	for lateral in [Vector3.ZERO, side, -side]:
		var from: Vector3 = global_position + Vector3.UP * 0.55 + lateral
		var query := PhysicsRayQueryParameters3D.create(from, from + direction * reach, 1)
		var hit := space.intersect_ray(query)
		if not hit.is_empty() and (hit["normal"] as Vector3).y < 0.55:
			return false
	return true

func _collision_radius() -> float:
	var shape_node := get_node_or_null("CollisionShape3DBoss" if is_boss else "CollisionShape3D") as CollisionShape3D
	if shape_node == null:
		shape_node = get_node_or_null("CollisionShape3D") as CollisionShape3D
	if shape_node != null and shape_node.shape is CapsuleShape3D:
		return (shape_node.shape as CapsuleShape3D).radius
	if shape_node != null and shape_node.shape is SphereShape3D:
		return (shape_node.shape as SphereShape3D).radius
	if shape_node != null and shape_node.shape is CylinderShape3D:
		return (shape_node.shape as CylinderShape3D).radius
	if shape_node != null and shape_node.shape is BoxShape3D:
		var b := (shape_node.shape as BoxShape3D).size
		return maxf(b.x, b.z) * 0.5
	return 0.5

## A body that has barely moved while trying to is wedged on scenery the probes
## missed: it commits to a sidestep (square to where it wants to go) for a
## moment, the side that is open first; wedged again, it tries the other side.
func _check_stuck(delta: float, wanted: Vector3) -> void:
	var moved := global_position.distance_to(_last_pos)
	if moved < 0.02 * maxf(0.2, delta * 60.0):
		_stuck_timer += delta
	else:
		_stuck_timer = 0.0
	_last_pos = global_position
	if _stuck_timer > 0.35:
		_stuck_timer = 0.0
		if _detour_time > 0.0:
			_steer_side = -_steer_side
		var side := wanted.cross(Vector3.UP).normalized() * _steer_side
		if not _path_clear(side) and _path_clear(-side):
			side = -side
			_steer_side = -_steer_side
		# a little back from the obstacle as well as round it
		_detour_dir = (side - wanted * 0.35).normalized()
		_detour_time = 0.9

## Server-side sleep. An idle creature with no player within `awake_range`
## has its physics processing switched off entirely - 1700 creatures each
## running AI and move_and_slide 60 times a second (or even just a per-frame
## "am I asleep" check) is what dropped the world server to ~5 fps and made
## players rubber-band (their server body fell behind the client's). One pass
## twice a second (`wake_pass`, driven by the encounter director) decides for
## every creature; a hit or an aggro wakes a creature at once.
static var awake_range := 70.0
var _sleeping := false

## The pass is spread over frames: each call (every frame) visits the share of
## the creatures that the time since the last call is of WAKE_PERIOD_MS, so
## every creature is still decided about twice a second but no single frame
## pays for thousands of them - that burst was a 10+ ms hitch on the world
## server every half second, and a late frame is late network polling for
## every player. Sized by time, not frames: the very first pass (every
## creature awake after boot, frames slow) still covers everyone at once.
const WAKE_PERIOD_MS := 500.0
static var _wake_mobs: Array = []
static var _wake_cursor := 0
static var _wake_list_ms := -100000
static var _wake_last_ms := -1

static func wake_pass(tree: SceneTree) -> void:
	var now := Time.get_ticks_msec()
	if _wake_cursor >= _wake_mobs.size() and now - _wake_list_ms > 2000:
		_wake_mobs = tree.get_nodes_in_group("mobs")
		_wake_list_ms = now
		_wake_cursor = 0
	elif _wake_cursor >= _wake_mobs.size():
		_wake_cursor = 0
	if _wake_mobs.is_empty():
		return
	var share := 1.0 if _wake_last_ms < 0 else clampf(float(now - _wake_last_ms) / WAKE_PERIOD_MS, 0.0, 1.0)
	_wake_last_ms = now
	var players: Array = []
	for player in tree.get_nodes_in_group("players"):
		players.append((player as Node3D).global_position)
	var r2 := awake_range * awake_range
	var stop := mini(_wake_mobs.size(), _wake_cursor + maxi(1, ceili(float(_wake_mobs.size()) * share)))
	var batch := _wake_mobs.slice(_wake_cursor, stop)
	_wake_cursor = stop
	for mob in batch:
		if not is_instance_valid(mob) or mob.sim_puppet:
			continue
		var can_sleep: bool = mob.state == State.IDLE or mob.state == State.WANDER
		var near := false
		if can_sleep:
			var at: Vector3 = (mob as Node3D).global_position
			for p in players:
				if (p as Vector3).distance_squared_to(at) < r2:
					near = true
					break
		var sleep := can_sleep and not near
		if sleep != mob._sleeping:
			mob._sleeping = sleep
			# Disabled, not just paused: a disabled body leaves the physics space,
			# and 1700 idle bodies sitting in it were most of a quiet server's frame.
			mob.process_mode = Node.PROCESS_MODE_DISABLED if sleep else Node.PROCESS_MODE_INHERIT
			# A sleeping creature is out of every player's sight: its pose can wait.
			if is_instance_valid(mob.anim_player) and not NetworkManager.is_dedicated_server:
				mob.anim_player.active = not sleep
			if sleep:
				mob.velocity = Vector3.ZERO

func wake() -> void:
	if _sleeping:
		_sleeping = false
		process_mode = Node.PROCESS_MODE_INHERIT
		if is_instance_valid(anim_player) and not NetworkManager.is_dedicated_server:
			anim_player.active = true

## A creature only keeps its distance from its own pack (packs stand tens of
## metres apart), so separation is O(pack) instead of O(every creature).
func _separation(direction: Vector3) -> Vector3:
	var radius := float(HPRules.pack_tuning("separation_radius", 1.7))
	var side := direction.cross(Vector3.UP)
	var push := Vector3.ZERO
	for mob in pack_mates():
		if not is_instance_valid(mob) or mob._sleeping:
			continue
		if mob == self or mob.state == State.DEAD:
			continue
		var offset: Vector3 = global_position - (mob as Node3D).global_position
		offset.y = 0
		var distance := offset.length()
		if distance > 0.01 and distance < radius:
			var away := offset / distance
			var weight := 1.0 - distance / radius
			push += away * weight
			# A mate on the way: pushed straight back off it, a body queued behind
			# one already swinging at the target and never reached it (the crowd
			# that stood off while two or three fought). Go round it instead, on
			# the side it is not.
			var ahead := -away.dot(direction)
			if ahead > 0.35:
				var turn := signf(side.dot(away))
				push += side * (turn if turn != 0.0 else _steer_side) * ahead * weight * 1.5
	return push

## A body this mob walked into on its last move that is not its target (another
## pack's creature, a bystander): the way round it, square to the heading.
func _bump_steer(direction: Vector3) -> Vector3:
	for i in get_slide_collision_count():
		var hit := get_slide_collision(i)
		var other := hit.get_collider()
		if other == target_player or not (other is CharacterBody3D):
			continue
		var normal := hit.get_normal()
		normal.y = 0.0
		if normal.length_squared() < 0.01 or normal.normalized().dot(direction) > -0.3:
			continue
		var side := direction.cross(Vector3.UP)
		var turn := signf(side.dot(normal))
		return side * (turn if turn != 0.0 else _steer_side)
	return Vector3.ZERO

func _face_direction(direction: Vector3, delta: float) -> void:
	if Vector2(direction.x, direction.z).length_squared() > 0.001:
		visuals.rotation.y = lerp_angle(visuals.rotation.y, atan2(direction.x, direction.z), minf(1, delta * 10))

# ------------------------------------------------------------------ warning

## Server-side telegraph mesh (also the shape the client puppet draws). Built
## from the attack plan: a disc for an area attack, a stretched lune for a
## directional one. `_warning_fill` is the event horizon: it fills over the
## anticipation and is exactly full at the authoritative release tick.
## spell-effect hook: the layered boss-warning effect scene (spells/boss_warning.gd)
## is attached to the ground mask. The mask itself must stay a MeshInstance3D
## with a CylinderMesh: the multiplayer probe reads its `top_radius` to prove the
## replicated warning matches the authoritative hit area.
var _warning_effect: Node3D
var _voice_timer := 0.0


## Spell effects audio hook: play a creature voice at this body's position.
func _play_voice(key: String) -> void:
	if NetworkManager.is_dedicated_server:
		return
	var audio := get_node_or_null("/root/AudioManager")
	if audio == null:
		return
	audio.call("play_sound_at", key, global_position, self)


func _voice_family() -> String:
	return voice_set if VOICE_SETS.has(voice_set) else "spider"


## A key from the body's voice family; "" when the family has no such cue.
func _voice_key(kind: String, variant: int = 0) -> String:
	var pattern := String((VOICE_SETS[_voice_family()] as Dictionary).get(kind, ""))
	if pattern == "":
		return ""
	if pattern.contains("%d"):
		return pattern % maxi(1, variant)
	return pattern

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
	# The hit-area mask carries the rune/ground-mark texture so the
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


## spell-effect hook: layer the warning effect (edge ring, countdown ring, rim
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
		FX.play_impact(get_parent(), center, String(plan.get("impact_fx", "bombarda")))
		# AoE victims are chosen by the engine from its own entity table: a
		# protected player inside the circle simply is not a victim.
		var hits: Array = SimAuthority.mob_area_attack(self, center, radius, int(power * multiplier),
			String(plan.get("spell_id", "boss_area" if is_boss else "boss_slam")))
		_apply_riders(plan, hits)
	elif kind == "directional":
		var range_len := float(plan.get("range", 8.0))
		var half_angle := float(plan.get("half_angle", 0.6))
		FX.play_cast(get_parent(), self, "expelliarmus", global_position + Vector3.UP * 1.2, _attack_dir)
		var cone_hits: Array = SimAuthority.mob_cone_attack(self, _attack_dir, half_angle, range_len, int(power * multiplier), "boss_cone")
		_apply_riders(plan, cone_hits)
	elif kind == "ranged":
		if _valid_target() and Rules.has_line_of_sight(self, target_player):
			var dir := (target_player.global_position + Vector3.UP - (global_position + Vector3.UP * 1.2)).normalized()
			FX.play_cast(get_parent(), self, bolt_spell, global_position + Vector3.UP * 1.2, dir)
			SimAuthority.mob_projectile(self, bolt_spell, dir, power)
	elif _valid_target() and Rules.has_line_of_sight(self, target_player):
		if global_position.distance_to(target_player.global_position) <= _melee_reach():
			_play_voice(_voice_key("attack"))
			SimAuthority.mob_melee(self, target_player, power)

## What a pattern does beyond its damage: despair (no regeneration) on every
## victim, and a drain that heals the attacker by a share of what it dealt.
func _apply_riders(plan: Dictionary, hits: Array) -> void:
	var despair := float(plan.get("despair_s", 0.0))
	# Cavern spiders: venom (damage over time, a share of the attack power per
	# beat) and a web that halves the victim's speed.
	var poison: Dictionary = plan.get("poison", {})
	var web_s := float(plan.get("web_s", 0.0))
	var push := float(plan.get("push", 0.0))
	var lift := float(plan.get("lift", 0.0))
	# The troll's slam: the player is dazed (no casts, no steering).
	var stun_s := float(plan.get("stun_s", 0.0))
	var dealt := 0
	for hit in hits:
		dealt += int((hit as Dictionary).get("amount", 0))
		if stun_s > 0.0:
			SimAuthority.stun_player(int((hit as Dictionary).get("uid", 0)), stun_s)
		if despair > 0.0:
			SimAuthority.apply_despair(int((hit as Dictionary).get("uid", 0)), despair)
		if not poison.is_empty():
			SimAuthority.apply_poison(int((hit as Dictionary).get("uid", 0)),
				maxi(1, int(attack_power * float(poison.get("ratio", 0.15)))),
				int(poison.get("ticks", 6)), int(poison.get("interval_ms", 1000)), self)
		if web_s > 0.0:
			SimAuthority.apply_web(int((hit as Dictionary).get("uid", 0)), web_s)
		# A shove: away from the attacker, and up (the pixie's lift).
		if push > 0.0 or lift > 0.0:
			var victim := SimAuthority.record_by_uid(int((hit as Dictionary).get("uid", 0)))
			var vnode = victim.get("node")
			if vnode is Node3D and is_instance_valid(vnode):
				var away := (vnode as Node3D).global_position - global_position
				away.y = 0.0
				away = away.normalized() * push if away.length_squared() > 0.0001 else Vector3.ZERO
				SimAuthority.push_player(victim, away + Vector3.UP * lift)
	if dealt > 0 and float(plan.get("drain", 0.0)) > 0.0:
		SimAuthority.heal_mob(self, int(dealt * float(plan.get("drain", 0.0))))
		current_hp = int(SimAuthority.record_for(self).get("hp", current_hp))
		_update_label()

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

## Authority slow (slow efsun proc, Glacius' chill, the Patronus): `factor` of
## the move and attack speed for `ms`.
func apply_slow(ms: int, factor: float) -> void:
	if state == State.DEAD:
		return
	_slow_timer = maxf(_slow_timer, float(ms) / 1000.0)
	_slow_factor = clampf(factor, 0.1, 1.0)

func _speed_scale() -> float:
	return _slow_factor if _slow_timer > 0.0 else 1.0

## Authority death notification: the engine already paid the rewards and dropped
## the loot, so this is the body's part only.
func on_authoritative_death(killer: Node3D) -> void:
	_play_voice("boss_death" if is_boss else _voice_key("death"))
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
	for mob in pack_mates():
		if pack_id > 0 and mob != self and is_instance_valid(mob) and mob.is_commander:
			mob.trigger_enrage()
	died.emit(self)

## Authority interrupt (stun, disarm, death, leash-cancel): drop any windup.
func cancel_cast_action() -> void:
	_cancel_attack()

func apply_knockback(force: Vector3) -> void:
	if not is_boss and state != State.DEAD:
		knockback_velocity = force

## Thrown by a spell (authority, spells.json `launch`): `force` is the take-off
## velocity. The body flies its arc under gravity and lands where physics puts
## it; the authority holds it stunned (no AI) through the flight and the
## landing stun.
func apply_launch(force: Vector3) -> void:
	if is_boss or state == State.DEAD:
		return
	_cancel_attack()
	_airborne = true
	_launch_time = 0.0
	_launch_velocity = Vector3(force.x, 0.0, force.z)
	velocity = force
	knockback_velocity = Vector3.ZERO

func _tick_airborne(delta: float) -> void:
	_launch_time += delta
	velocity.x = _launch_velocity.x
	velocity.z = _launch_velocity.z
	_launch_velocity = _launch_velocity.move_toward(Vector3.ZERO, delta * 3.0)
	velocity.y -= HPRules.LAUNCH_GRAVITY * delta
	move_and_slide()
	_track_drawn_speed(0.0, delta)
	# Down again (a short guard: the take-off frame still touches the floor),
	# or a throw that never comes down (a ledge, a wall) ends anyway.
	if (_launch_time > 0.12 and is_on_floor()) or _launch_time > 3.0:
		_airborne = false
		_launch_velocity = Vector3.ZERO
		velocity = Vector3.ZERO
	if global_position.y < -10.0:
		global_position = spawn_point
		velocity = Vector3.ZERO
		_airborne = false

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
	if sim_puppet:
		var rec := SimAuthority.record_for(self)
		if not rec.is_empty():
			global_position = rec.get("pos", global_position)
			sim_target_pos = global_position
			sim_motion.clear()   # the old life's samples would glide it back
	else:
		global_position = spawn_point
	current_hp = max_hp
	attack_power = _base_attack
	move_speed = _base_speed
	attack_cooldown = _base_cooldown
	is_enraged = false
	target_player = null
	stun_timer = 0
	_slow_timer = 0.0
	_weaken_timer = 0
	knockback_velocity = Vector3.ZERO
	_airborne = false
	_launch_velocity = Vector3.ZERO
	velocity = Vector3.ZERO
	attack_timer = 1
	StatusFX.update(self, 0)
	# A fresh idle beat, like _ready: an expired timer from the previous life
	# would send the body wandering on its first frame back.
	wander_timer = randf_range(1, 4)
	_pattern_index = 0
	_attack_count = 0
	_ability_ready_tick.clear()
	_cancel_attack()
	_corpse_time = 0
	_stuck_timer = 0
	_detour_time = 0.0
	_drawn_speed = 0.0
	_drawn_moving = false
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

func _enter_tree() -> void:
	_pack_index_add()

func _exit_tree() -> void:
	_pack_index_remove()
	_cancel_attack()
	_cancel_warning()
	SimAuthority.unregister_node(self)

## Creatures by pack id, kept as they enter/leave the tree. Pack logic (assist,
## attack slots, ring places, separation, enrage) used to walk the "mobs" group -
## every creature in the world, ~4500 - per fighting mob per physics frame. With
## two or three packs engaged that was most of the server's frame: mobs froze,
## players were corrected back and casts waited on "still recovering".
static var _pack_index: Dictionary = {}

func _pack_index_add() -> void:
	(_pack_index.get_or_add(pack_id, []) as Array).append(self)

func _pack_index_remove() -> void:
	var members: Array = _pack_index.get(pack_id, [])
	members.erase(self)
	if members.is_empty():
		_pack_index.erase(pack_id)

## This creature's pack, itself included. Pack 0 means "no pack": nobody shares it.
func pack_mates() -> Array:
	if pack_id <= 0:
		return [self]
	return _pack_index.get(pack_id, [self])

# ------------------------------------------------------------------ puppets

## A client's view of a server-owned mob: position/rotation interpolation plus
## presentation chosen from the replicated state byte. No damage, no AI.
func _update_puppet(delta: float) -> void:
	var before := global_position
	if sim_motion.has_samples():
		var drawn := sim_motion.sample()
		global_position = drawn.pos
		sim_motion.snapped = false
		if visuals:
			visuals.rotation.y = float(drawn.rot)
	else:
		global_position = global_position.lerp(sim_target_pos, minf(1.0, 12.0 * delta))
		if visuals:
			visuals.rotation.y = lerp_angle(visuals.rotation.y, sim_target_rot, minf(1.0, 12.0 * delta))
	# A replica has no velocity of its own: its pace is the glide it is drawn
	# along (capped, so a respawn jump is not a sprint).
	var glide := Vector2(global_position.x - before.x, global_position.z - before.z).length() / maxf(delta, 0.001)
	_track_drawn_speed(minf(glide, maxf(move_speed, 1.0) * 1.5), delta)
	var record := SimAuthority.record_for(self)
	if record.is_empty():
		return
	_draw_telegraph(record)
	# v14: the server names the mob (catalog name, pack level, elite roll).
	var rev := int(record.get("meta_rev", -1))
	if rev != _info_rev and record.has("name"):
		_info_rev = rev
		mob_name = String(record.get("name", mob_name))
		level = int(record.get("level", level))
		is_elite = bool(record.get("is_elite", false))
		_update_label()
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
		_respawn()
		return
	if replicated != _puppet_state:
		_puppet_state = replicated
		_play_puppet_clip(replicated, record)
	# Locomotion follows the glide every frame: the server's wander used to
	# play the idle pose here (bodies slid over the grass), and a chaser held
	# up in the crowd ran on the spot.
	match replicated:
		HPProtocol.MobState.WANDER, HPProtocol.MobState.IDLE:
			_play_locomotion("walk")
		HPProtocol.MobState.CHASE, HPProtocol.MobState.RETURN:
			_play_locomotion("run")

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
	if String(data.get("fx", "")) == "boulder" and start_tick != _boulder_tick:
		_boulder_tick = start_tick
		_throw_boulder(data.get("center", global_position), release_tick)
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
	# spell-effect hook: the layered effect's countdown fill is driven by the same
	# authority ticks this fill is - never by a client-side guess.
	if is_instance_valid(_warning_effect) and _warning_effect.has_method("set_progress"):
		_warning_effect.call("set_progress", progress)

## The boulder a troll throws: lifted overhead, then flown on an arc so it
## lands on the authority's release tick (presentation only - the damage is the
## telegraphed area resolved by the server).
func _throw_boulder(target: Vector3, release_tick: int) -> void:
	var parent := get_parent()
	if parent == null:
		return
	var rock := _boulder_body()
	parent.add_child(rock)
	var start := global_position + Vector3.UP * 4.6
	rock.global_position = start
	var total := maxf(0.2, float(release_tick - SimAuthority.sim_tick) * HPProtocol.SIM_DT)
	var flight := minf(0.55, total)
	var tween := rock.create_tween()
	tween.tween_interval(total - flight)
	tween.tween_method(_fly_boulder.bind(rock, start, target), 0.0, 1.0, flight)
	tween.tween_callback(rock.queue_free)

const BOULDER_MODEL := "res://assets/models/vegetation/rock_boulder.glb"
const BOULDER_SIZE := 1.5

## The thrown rock: the grounds' boulder model sized to BOULDER_SIZE (a grey
## sphere when the model is missing).
func _boulder_body() -> Node3D:
	var scene := load(BOULDER_MODEL) as PackedScene
	if scene == null:
		var fallback := MeshInstance3D.new()
		var mesh := SphereMesh.new()
		mesh.radius = 0.75
		mesh.height = 1.3
		fallback.mesh = mesh
		return fallback
	var holder := Node3D.new()
	var model := scene.instantiate() as Node3D
	holder.add_child(model)
	var box := AABB()
	var first := true
	for child in model.find_children("*", "MeshInstance3D", true, false):
		var mi := child as MeshInstance3D
		mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_ON
		var xf := Transform3D.IDENTITY
		var node: Node = mi
		while node != null and node != model:
			if node is Node3D:
				xf = (node as Node3D).transform * xf
			node = node.get_parent()
		var local: AABB = xf * mi.get_aabb()
		box = local if first else box.merge(local)
		first = false
	var extent := maxf(0.01, maxf(box.size.x, maxf(box.size.y, box.size.z)))
	model.scale = Vector3.ONE * (BOULDER_SIZE / extent)
	model.position = -box.get_center() * model.scale
	return holder

func _fly_boulder(t: float, rock: Node3D, start: Vector3, target: Vector3) -> void:
	if is_instance_valid(rock):
		rock.global_position = start.lerp(target, t) + Vector3.UP * sin(t * PI) * 5.0
		rock.rotation.x = t * 7.0
		rock.rotation.z = t * 3.0
