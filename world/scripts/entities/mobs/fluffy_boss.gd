extends "res://scripts/entities/mobs/multipart_boss.gd"

## Fluffy - the three-headed dog at the end of the Forbidden Corridor.
##
## Each head is a separate target (boss_part, `part_hp` each); the body is
## immune, shows the heads' summed hit points and dies with the last head.
## Phases: 1 all heads; 2 once a head faints (Roar, Pounce join the patterns);
## 3 below a quarter of its total (the harp lulls for less). Enrages after
## `enrage_s` of fighting.
##
## The harp (`harp_point`, set by the dungeon run): a player who stands at it
## for HARP_CHANNEL seconds without taking a hit plays it - Fluffy falls
## asleep (HARP_SLEEP s, 5 in phase 3) and every head takes +50% damage. The
## harp then needs HARP_COOLDOWN to be played again. All server-side; the run
## shows the messages.

const HARP_RADIUS := 2.6
const HARP_CHANNEL := 6.0
const HARP_SLEEP := 10.0
const HARP_SLEEP_LATE := 5.0
const HARP_COOLDOWN := 45.0
const SLEEP_DAMAGE_MULT := 1.5

var harp_point := Vector3.INF
var phase := 1
var _harp_uid := 0
var _harp_progress := 0.0
var _harp_combat_tick := 0
var _harp_ready_at := 0.0
var _fight_time := 0.0
var _enrage_at := 0.0

func _ready() -> void:
	droop_chains = {"L": ["Neck.L", "Head.L"], "M": ["Neck.M", "Head.M"], "R": ["Neck.R", "Head.R"]}
	droop_degrees = 28.0
	hp_is_sum = true
	super()

func _physics_process(delta: float) -> void:
	super(delta)
	if sim_puppet or not SimAuthority.is_authority() or state == State.DEAD or not _parts_spawned:
		return
	if state in [State.CHASE, State.ATTACK, State.STUNNED]:
		_fight_time += delta
		if _enrage_at <= 0.0:
			_enrage_at = float(_boss_data().get("enrage_s", 480.0))
		if not is_enraged and _fight_time >= _enrage_at:
			trigger_enrage()
			dungeon_message.emit("Fluffy is enraged!")
	_update_phase()
	_tick_harp(delta)

func _update_phase() -> void:
	var next := 1
	if not parts_down.is_empty():
		next = 2
	if max_hp > 0 and float(current_hp) / float(max_hp) < 0.25:
		next = 3
	if next != phase:
		phase = next
		dungeon_message.emit("Fluffy howls in fury!" if phase == 2 else "Fluffy is frenzied - the harp holds it only briefly!")

func _on_reset() -> void:
	phase = 1
	_fight_time = 0.0
	_harp_uid = 0
	_harp_progress = 0.0
	_harp_ready_at = 0.0
	if is_enraged:
		is_enraged = false
		attack_power = _base_attack
		move_speed = _base_speed
		attack_cooldown = _base_cooldown

func _on_part_down(key: String) -> void:
	var side: String = {"L": "left", "M": "middle", "R": "right"}.get(key, key)
	dungeon_message.emit("Fluffy's %s head slumps!" % side)

func _all_parts_down() -> void:
	SimAuthority.force_kill(self, parts.values())

# ---------------------------------------------------------------- patterns

## Patterns in authored order, skipping the ones a later phase unlocks.
func _choose_plan() -> Dictionary:
	var patterns: Array = HPRules.attack_patterns_for(boss_style)
	var usable: Array = []
	for p in patterns:
		if int((p as Dictionary).get("min_phase", 1)) <= phase:
			usable.append(p)
	if usable.is_empty():
		return super()
	var plan: Dictionary = (usable[_pattern_index % usable.size()] as Dictionary).duplicate(true)
	_pattern_index += 1
	plan["telegraph"] = true
	# The bite comes from every head still awake: fewer heads, a narrower cone.
	if bool(plan.get("per_part", false)):
		var awake := living_parts().size()
		plan["half_angle"] = 0.2 + 0.17 * awake
		plan["damage_multiplier"] = float(plan.get("damage_multiplier", 1.0)) * (0.6 + 0.2 * awake)
	return plan

# ------------------------------------------------------------------- harp

func _tick_harp(delta: float) -> void:
	if harp_point == Vector3.INF:
		return
	var now := float(Time.get_ticks_msec()) / 1000.0
	if now < _harp_ready_at:
		return
	var player := _harp_player()
	if player.is_empty():
		if _harp_uid != 0:
			_harp_uid = 0
			_harp_progress = 0.0
		return
	var uid := int(player["uid"])
	if uid != _harp_uid:
		_harp_uid = uid
		_harp_progress = 0.0
		_harp_combat_tick = int(player.get("last_combat_tick", 0))
		dungeon_message.emit("%s begins to play the harp..." % String(player.get("name", "Someone")))
		return
	# Any hit taken (or dealt) breaks the tune.
	if int(player.get("last_combat_tick", 0)) != _harp_combat_tick:
		_harp_uid = 0
		_harp_progress = 0.0
		dungeon_message.emit("The music breaks off!")
		return
	_harp_progress += delta
	if _harp_progress >= HARP_CHANNEL:
		_harp_uid = 0
		_harp_progress = 0.0
		_harp_ready_at = now + HARP_COOLDOWN
		lull(HARP_SLEEP_LATE if phase >= 3 else HARP_SLEEP)

## The living player standing at the harp (on this copy), or {}.
func _harp_player() -> Dictionary:
	var map_id := String(SimAuthority.record_for(self).get("map_id", ""))
	for uid in SimAuthority.players_by_peer.values():
		var record: Dictionary = SimAuthority.entities.get(uid, {})
		if int(record.get("kind", 0)) != HPProtocol.Kind.PLAYER or bool(record.get("dead", false)):
			continue
		if String(record.get("map_id", "")) != map_id:
			continue
		var node = record.get("node")
		if node is Node3D and is_instance_valid(node) and (node as Node3D).global_position.distance_to(harp_point) <= HARP_RADIUS:
			return record
	return {}

## Sleep: no attacks for `seconds`, every head takes extra damage.
func lull(seconds: float) -> void:
	_cancel_attack()
	_set_state(State.STUNNED)
	stun_timer = seconds
	_play_slot("stun", 0.3)
	for part in living_parts():
		SimAuthority.set_mob_vulnerable(part, SLEEP_DAMAGE_MULT, seconds)
	_publish_state()
	dungeon_message.emit("The music lulls Fluffy to sleep! Its heads take more damage.")

func harp_progress() -> float:
	return _harp_progress / HARP_CHANNEL
