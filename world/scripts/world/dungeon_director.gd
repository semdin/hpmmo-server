extends Node

## Dungeon director - the scripted runs of instanced maps (dungeons.json).
##
## Authority only (dedicated server, host, offline client). A run starts when
## the authority opens a copy (`SimAuthority.instance_opened`, the first body
## arriving) and walks its steps in order: each waits for its trigger, then
## acts - spawn creatures (boss included), open/close gates, a message, a
## chest, completion. The state (step, open gates, message) is published to
## the players in that copy and applied to the copy's scene, so the gate a
## client sees and the gate the server collides with are the same fact.
## A torn-down copy (`instance_closed`) frees everything its run spawned.
##
## The run is scored (v30): the clock starts when the start gate opens and
## stops at completion; every creature that dies adds its role's `forces` to
## the clear; a death adds the difficulty's time penalty and spends a party
## life. A run completes when its last creature falls (the final step waits on
## `cleared:all`, not on the boss) or when its time runs out (medals `limit` x
## par): a full clear in time earns a medal (dungeons.json medals x the run's
## par), which the published `result` carries.
##
## A spawn entry with `count` is a group: count x the difficulty's `mobs` x the
## party size (HPRules.dungeon_spawn_count), spread round its `at`.
##
## Weekly curses (`params.affixes`, dungeons.json affixes): rage, bolstering,
## bursting dead, sticky ground and teeming change the creatures; chill and
## storm reach the players; the bleeding curse rides on elites' blows
## (SimAuthority.mob_melee). Ground hazards are resolved here on the run's own
## clock and published for the players to see (SimAuthority.dungeon_hazard).
##
## Spider lair extras (dungeons.json): a spawn entry's `hatch` breaks a still
## standing egg sac open into creatures; a step's `cocoon` wraps a player until
## the party breaks it; a step's `pools` are venom pools that hurt every second.
##
## Harder difficulties (dungeons.json difficulty + `min_difficulty` on steps and
## spawn entries): extra waves and twins only from a difficulty up, shorter
## telegraphs (`telegraph`), faster hazards (`hazard_mult`), bosses that enrage
## after `boss_enrage_s`, and per-entry `harp_scale` / `marks` (Fluffy's harp,
## the Queen's venom). Every run prints its step splits for balancing.

const TICK := 0.25
## Longest wait for the roster in the entry hall before the countdown starts.
const GATHER_S := 45.0

var runs: Dictionary = {}   # map_id -> run
var container: Node3D
var encounters: Node        # EncounterDirector: stat/boss configuration is shared
var _timer := 0.0
var _next_pack := 9000

func start(world: Node3D, encounter_director: Node) -> void:
	encounters = encounter_director
	container = Node3D.new()
	container.name = "DungeonMobs"   # not a grounds container: never hidden off-map
	world.add_child(container)
	if not SimAuthority.instance_opened.is_connected(open_run):
		SimAuthority.instance_opened.connect(open_run)
		SimAuthority.instance_closed.connect(close_run)

func open_run(map_id: String) -> void:
	var def := HPMaps.dungeon_for_map(map_id)
	if def.is_empty() or runs.has(map_id):
		return
	var params := _run_params(map_id, def)
	runs[map_id] = {"def": def, "params": params, "step": 0, "spawned": {}, "open": {}, "message": "",
		"complete": false, "origin": HPMaps.instance_origin(map_id), "done": {}, "lock": {}, "hazard_t": {},
		"phase": "gather", "phase_t": 0.0, "start_tick": -1, "end_tick": -1,
		"forces": 0, "forces_total": _total_forces(def, params), "pending": {}, "left": -1,
		"deaths": 0, "down": {},
		"lives_left": int(HPRules.dungeon_difficulty(String(params["difficulty"])).get("lives", -1)),
		"broken": false, "result": {}, "affixes": (params.get("affixes", []) as Array).duplicate(),
		"watch": {}, "hazards": [], "curse_t": {}, "hatching": [], "cocoons": [], "bosses_since": {}, "splits": []}
	print("[Dungeon] run '%s' opened in %s (%s, ref level %d, party %d)" % [def.get("id", "?"), map_id,
		params["difficulty"], int(params["ref_level"]), int(params["party_size"])])
	_publish(map_id, runs[map_id])

## What the run is built from, fixed for its lifetime: the dungeon gate puts
## them on the copy (instance `params`, with the roster). A copy without them
## runs the players inside on Normal.
func _run_params(map_id: String, def: Dictionary) -> Dictionary:
	var info := SimAuthority.instance_info(map_id)
	if info.has("params"):
		return info["params"]
	var levels: Array = []
	for record in _players(map_id, false):
		levels.append(SimAuthority._player_level(record))
	var params := HPRules.dungeon_run_params(def, "normal", levels)
	if not info.is_empty():
		info["params"] = params
	return params

## The start of a run: the roster gathers in the entry hall behind the start
## gate (everyone arrived, or GATHER_S passed), then a countdown, then the gate
## opens and the run's steps begin - nobody's loading screen is a head start.
func _tick_start(map_id: String, run: Dictionary, dt: float) -> void:
	run["phase_t"] = float(run["phase_t"]) + dt
	if run["phase"] == "gather":
		var roster: Array = run["params"].get("roster", [])
		var here := 0
		for record in _players(map_id, false):
			if roster.has(int(record.get("uid", 0))) and int(record.get("pending_transfer", 0)) == 0:
				here += 1
		if here < roster.size() and float(run["phase_t"]) < GATHER_S:
			return
		run["phase"] = "countdown"
		run["phase_t"] = 0.0
		_publish(map_id, run)
	elif float(run["phase_t"]) >= float(HPRules.dungeon_group().get("countdown_s", 10)):
		run["phase"] = "running"
		run["phase_t"] = 0.0
		run["start_tick"] = SimAuthority.sim_tick
		run["open"]["start"] = true
		advance(map_id)
		_publish(map_id, run)

func close_run(map_id: String) -> void:
	var run: Dictionary = runs.get(map_id, {})
	runs.erase(map_id)
	for list in (run.get("spawned", {}) as Dictionary).values():
		for mob in list:
			if is_instance_valid(mob):
				SimAuthority.unregister_node(mob)
				mob.queue_free()

func _process(delta: float) -> void:
	if not SimAuthority.is_authority() or runs.is_empty():
		return
	_timer -= delta
	if _timer > 0.0:
		return
	_timer = TICK
	for map_id in runs.keys():
		var run: Dictionary = runs.get(map_id, {})
		if run.is_empty():
			continue
		if run["phase"] != "running":
			_tick_start(map_id, run, TICK)
			continue
		advance(map_id)
		run = runs.get(map_id, {})
		if not run.is_empty():
			if not bool(run["complete"]):
				_tick_curses(map_id, run, TICK)
				_tick_brood(map_id, run)
				_tick_boss_enrage(map_id, run)
				_tick_hazards_live(map_id, run)
				_tick_score(map_id, run)
				_tick_time_limit(map_id, run)
			_tick_lock(map_id, run)
			_tick_hazards(map_id, run, TICK)

## The living players in a copy (records with a body).
func _players(map_id: String, alive_only: bool = true) -> Array:
	var out: Array = []
	for uid in SimAuthority.players_by_peer.values():
		var record: Dictionary = SimAuthority.entities.get(uid, {})
		if int(record.get("kind", 0)) != HPProtocol.Kind.PLAYER or String(record.get("map_id", "")) != map_id:
			continue
		if alive_only and bool(record.get("dead", false)):
			continue
		var node = record.get("node")
		if node is Node3D and is_instance_valid(node):
			out.append(record)
	return out

## Wipe and retry: a boss step that shut gates behind the party holds them shut
## only while somebody alive stands past its trigger. When nobody does (the
## party died and respawned at the entrance, or walked out) the gates open so
## the way back is free - cleared rooms stay cleared, the boss has gone home
## and reset - and crossing the trigger line again seals them once more.
func _tick_lock(map_id: String, run: Dictionary) -> void:
	var lock: Dictionary = run["lock"]
	if lock.is_empty():
		return
	var bosses: Array = (run["spawned"] as Dictionary).get(String(lock["step"]), [])
	var alive := bosses.any(func(m): return is_instance_valid(m) and m.state != m.State.DEAD)
	if not alive:
		run["lock"] = {}
		return
	var origin: Vector3 = run["origin"]
	var inside := false
	for record in _players(map_id):
		if ((record["node"] as Node3D).global_position.z - origin.z) < float(lock["z"]):
			inside = true
			break
	if inside == bool(lock["sealed"]):
		return
	lock["sealed"] = inside
	for gate in lock["gates"]:
		if inside:
			run["open"].erase(String(gate))
		else:
			run["open"][String(gate)] = true
	run["message"] = String(lock["message"]) if inside else "The way back is open. Regroup and try again."  # i18n
	_publish(map_id, run)

## dungeons.json `hazards`: a periodic shove of every player inside a band of
## the copy (Fluffy's breath down the stair), between two steps of the run.
func _tick_hazards(map_id: String, run: Dictionary, dt: float) -> void:
	var origin: Vector3 = run["origin"]
	for hazard in run["def"].get("hazards", []):
		var h: Dictionary = hazard
		var id := String(h.get("id", ""))
		var done: Dictionary = run["done"]
		if not done.has(String(h.get("from_step", ""))) or done.has(String(h.get("until_step", ""))):
			continue
		var t := float(run["hazard_t"].get(id, 0.0)) + dt
		var every := float(h.get("every_s", 6.0)) \
			* float(HPRules.dungeon_difficulty(String(run["params"]["difficulty"])).get("hazard_mult", 1.0))
		var warn := float(h.get("warn_s", 1.0))
		var band: Array = h.get("z", [0.0, 0.0])
		var across: Array = h.get("x", [-INF, INF])
		var victims: Array = []
		for record in _players(map_id):
			var at: Vector3 = (record["node"] as Node3D).global_position - origin
			if at.z >= float(band[0]) and at.z <= float(band[1]) and at.x >= float(across[0]) and at.x <= float(across[1]):
				victims.append(record)
		if victims.is_empty():
			run["hazard_t"][id] = 0.0
			continue
		if t >= every - warn and t - dt < every - warn and h.has("message"):
			run["message"] = String(h["message"])
			_publish(map_id, run)
		if t >= every:
			t = 0.0
			var p: Array = h.get("push", [0, 0, 0])
			var force := Vector3(float(p[0]), float(h.get("lift", 0.0)), float(p[2]))
			for record in victims:
				SimAuthority.push_player(record, force)
		run["hazard_t"][id] = t

## Walk the run as far as its triggers allow. Side slots (`optional` steps)
## stand outside the chain: each fires once, on its own trigger.
func advance(map_id: String) -> void:
	var run: Dictionary = runs.get(map_id, {})
	if run.is_empty():
		return
	var steps: Array = run["def"].get("steps", [])
	var changed := false
	var difficulty := String(run["params"]["difficulty"])
	for step in steps:
		if bool(step.get("optional", false)) and not run["done"].has(String(step.get("id", ""))) \
				and HPRules.dungeon_active_on(step, difficulty) and _triggered(map_id, run, String(step.get("on", "enter"))):
			_act(map_id, run, step)
			changed = true
	while int(run["step"]) < steps.size():
		var step: Dictionary = steps[int(run["step"])]
		if bool(step.get("optional", false)) or not HPRules.dungeon_active_on(step, difficulty):
			run["step"] = int(run["step"]) + 1
			continue
		if not _triggered(map_id, run, String(step.get("on", "enter"))):
			if String(step.get("on", "")) == "cleared:all":
				changed = _call_stragglers(run) or changed
			break
		_act(map_id, run, step)
		run["step"] = int(run["step"]) + 1
		changed = true
	if changed:
		_publish(map_id, run)

## The chain waits on the last creatures: the message counts them down.
func _call_stragglers(run: Dictionary) -> bool:
	var left := _alive_mobs(run).size()
	if left == int(run["left"]):
		return false
	run["left"] = left
	if left > 0:
		run["message"] = "Creatures still stand - clear them all to finish the run."  # i18n
	return true

## A run past its time limit ends where it stands: no medal; the final chest
## only when every boss has fallen; the gates open for the way out.
func _tick_time_limit(map_id: String, run: Dictionary) -> void:
	var limit := float(HPMaps.dungeon_rules("medals").get("limit", 0.0))
	if limit <= 0.0 or _elapsed(run) < _par(run) * limit:
		return
	var steps: Array = run["def"].get("steps", [])
	var final: Dictionary = {}
	for step in steps:
		var each: Dictionary = step
		for gate in each.get("open", []) + each.get("close", []):
			run["open"][String(gate)] = true
		if bool(each.get("complete", false)):
			final = each
	run["step"] = steps.size()
	run["lock"] = {}
	run["complete"] = true
	_finish(map_id, run)
	run["result"]["timeout"] = true
	var bosses_down := _bosses(map_id, run).all(func(b): return bool(b["done"]))
	if bosses_down and final.has("chest"):
		var chest: Dictionary = final["chest"]
		var at: Vector3 = run["origin"] + _vec(chest.get("at", []))
		if not (run["params"].get("roster", []) as Array).is_empty():
			SimAuthority.grant_dungeon_rewards(map_id, run["params"], run["result"], String(chest.get("table", "")), at)
		else:
			SimAuthority.drop_loot_table(String(chest.get("table", "")), at, map_id)
		for record in _players(map_id, false):
			SimAuthority.quest_event(record, "dungeon", String(run["def"].get("id", "")))
	if bosses_down:
		run["message"] = "Time is up - the guardians fell, but not every creature did."  # i18n
	else:
		run["message"] = "Time is up - the run is over."  # i18n
	print("[Dungeon] %s timed out (bosses down: %s)" % [map_id, bosses_down])
	_publish(map_id, run)

# ------------------------------------------------------------------ curses

func _alive_mobs(run: Dictionary) -> Array:
	var out: Array = []
	for list in (run["spawned"] as Dictionary).values():
		for mob in list:
			if is_instance_valid(mob) and mob.state != mob.State.DEAD:
				out.append(mob)
	return out

## One curse tick: deaths feed bolstering, bursting and sticky ground; rage
## takes the wounded; chill and storm run on their own clocks; the ground
## hazards resolve.
func _tick_curses(map_id: String, run: Dictionary, dt: float) -> void:
	var affixes: Array = run["affixes"]
	if affixes.is_empty():
		return
	var watch: Dictionary = run["watch"]
	for id in watch.keys():
		var mob = instance_from_id(int(id))
		var gone: bool = mob == null or not is_instance_valid(mob) or mob.state == mob.State.DEAD
		if not gone:
			watch[id] = (mob as Node3D).global_position
			continue
		var at: Vector3 = watch[id]
		watch.erase(id)
		var boss: bool = mob != null and is_instance_valid(mob) and bool(mob.is_boss)
		if not boss:
			_on_creature_died(map_id, run, at)
	if affixes.has("enrage"):
		var rage := HPRules.dungeon_affix("enrage")
		for mob in _alive_mobs(run):
			if not mob.is_boss and not mob.has_meta("curse_raged") and mob.max_hp > 0 \
					and float(mob.current_hp) / float(mob.max_hp) < float(rage.get("below", 0.3)):
				mob.set_meta("curse_raged", true)
				mob.attack_power = int(float(mob.attack_power) * float(rage.get("damage", 1.5)))
				mob.move_speed *= float(rage.get("speed", 1.15))
	for id in ["chill", "storm"]:
		if affixes.has(id):
			var t := float(run["curse_t"].get(id, 0.0)) + dt
			if t >= float(HPRules.dungeon_affix(id).get("every_s", 30.0)):
				t = 0.0 if _curse_pulse(map_id, run, id) else t
			run["curse_t"][id] = t

## A creature (not a boss) of the run died at `at`.
func _on_creature_died(map_id: String, run: Dictionary, at: Vector3) -> void:
	var affixes: Array = run["affixes"]
	if affixes.has("bolster"):
		var spec := HPRules.dungeon_affix("bolster")
		for mob in _alive_mobs(run):
			if mob.is_boss or (mob as Node3D).global_position.distance_to(at) > float(spec.get("radius", 15.0)):
				continue
			# Stacks add to the creature's own numbers, capped: compounding them
			# swelled a guard in a big pack past 50 000 health.
			var stacks := int(mob.get_meta("bolster_stacks", 0))
			if stacks >= int(spec.get("max_stacks", 5)):
				continue
			if stacks == 0:
				mob.set_meta("bolster_base", [mob.max_hp, mob.attack_power])
			stacks += 1
			mob.set_meta("bolster_stacks", stacks)
			var base: Array = mob.get_meta("bolster_base")
			var old_max := maxi(1, int(mob.max_hp))
			mob.max_hp = int(round(float(base[0]) * (1.0 + float(spec.get("hp", 0.15)) * stacks)))
			SimAuthority.set_mob_hp(mob, int(round(float(mob.current_hp) * float(mob.max_hp) / float(old_max))), mob.max_hp)
			mob.attack_power = int(round(float(base[1]) * (1.0 + float(spec.get("damage", 0.15)) * stacks)))
	if affixes.has("burst"):
		var spec := HPRules.dungeon_affix("burst")
		_add_hazard(map_id, run, {"kind": "burst", "center": at, "radius": float(spec.get("radius", 4.0)),
			"release_tick": SimAuthority.sim_tick + int(float(spec.get("warn_s", 2.0)) * HPProtocol.SIM_HZ),
			"hp_share": float(spec.get("hp_share", 0.12))})
	if affixes.has("sticky"):
		var spec := HPRules.dungeon_affix("sticky")
		_add_hazard(map_id, run, {"kind": "sticky", "center": at, "radius": float(spec.get("radius", 3.5)),
			"until_tick": SimAuthority.sim_tick + int(float(spec.get("duration_s", 6.0)) * HPProtocol.SIM_HZ)})

## Chill (despair on everyone) and storm (a strike under someone while the
## party fights). False when the pulse had nobody to touch (it waits).
func _curse_pulse(map_id: String, run: Dictionary, id: String) -> bool:
	var spec := HPRules.dungeon_affix(id)
	var players := _players(map_id)
	if players.is_empty():
		return false
	if id == "chill":
		for record in players:
			SimAuthority.apply_despair(int(record.get("uid", 0)), float(spec.get("despair_s", 6.0)))
		run["message"] = "A dementor's chill sweeps the halls - nobody recovers for a while."  # i18n
		_publish(map_id, run)
		return true
	var fighting := _alive_mobs(run).any(func(m): return is_instance_valid(m.target_player))
	if not fighting:
		return false
	var victim: Dictionary = players[randi() % players.size()]
	_add_hazard(map_id, run, {"kind": "storm", "center": (victim["node"] as Node3D).global_position,
		"radius": float(spec.get("radius", 3.5)),
		"release_tick": SimAuthority.sim_tick + int(float(spec.get("warn_s", 1.2)) * HPProtocol.SIM_HZ),
		"hp_share": float(spec.get("hp_share", 0.15))})
	return true

func _add_hazard(map_id: String, run: Dictionary, hazard: Dictionary) -> void:
	hazard["start_tick"] = SimAuthority.sim_tick
	(run["hazards"] as Array).append(hazard)
	SimAuthority.publish_dungeon_hazard(map_id, hazard)

## Rings burst on their release tick (a share of each victim's health);
## sticky patches slow whoever stands in them until they fade.
func _tick_hazards_live(map_id: String, run: Dictionary) -> void:
	var live: Array = run["hazards"]
	for hazard in live.duplicate():
		var center: Vector3 = hazard["center"]
		var radius := float(hazard["radius"])
		if hazard.has("release_tick"):
			if SimAuthority.sim_tick < int(hazard["release_tick"]):
				continue
			for record in _players(map_id):
				var node: Node3D = record["node"]
				if Vector2(node.global_position.x - center.x, node.global_position.z - center.z).length() <= radius:
					SimAuthority.apply_damage(node, maxi(1, int(round(float(record.get("max_hp", 100)) * float(hazard["hp_share"])))), "curse", null)
			live.erase(hazard)
		else:
			var pool := String(hazard["kind"]) == "pool"
			var bite: bool = pool and SimAuthority.sim_tick >= int(hazard.get("next_tick", 0))
			if bite:
				hazard["next_tick"] = SimAuthority.sim_tick + HPProtocol.SIM_HZ
			for record in _players(map_id):
				var node: Node3D = record["node"]
				if Vector2(node.global_position.x - center.x, node.global_position.z - center.z).length() > radius:
					continue
				if not pool:
					SimAuthority.apply_web(int(record.get("uid", 0)), 0.6)
				elif bite:
					SimAuthority.apply_damage(node, maxi(1, int(round(float(record.get("max_hp", 100)) * float(hazard["hp_share_s"])))), "curse", null)
			if SimAuthority.sim_tick >= int(hazard["until_tick"]):
				live.erase(hazard)

# --------------------------------------------------------------- enrage

## Bosses that have fought longer than the difficulty's `boss_enrage_s` enrage.
func _tick_boss_enrage(map_id: String, run: Dictionary) -> void:
	var limit := float(HPRules.dungeon_difficulty(String(run["params"]["difficulty"])).get("boss_enrage_s", 0.0))
	if limit <= 0.0:
		return
	var since: Dictionary = run["bosses_since"]
	for id in since.keys():
		var boss = instance_from_id(int(id))
		if boss == null or not is_instance_valid(boss) or boss.state == boss.State.DEAD:
			since.erase(id)
			continue
		if float(SimAuthority.sim_tick - int(since[id])) / float(HPProtocol.SIM_HZ) >= limit and not boss.is_enraged:
			boss.trigger_enrage()
			since.erase(id)
			run["message"] = "The guardian of this place flies into a rage - finish it now!"  # i18n
			_publish(map_id, run)

# ------------------------------------------------------------------ brood

## Egg sacs still standing when their time comes break open into creatures
## (they join the sac's step, so its gate waits for them); a cocoon broken
## frees its player, one that outlasts its hold costs them a share of health.
func _tick_brood(map_id: String, run: Dictionary) -> void:
	var hatching: Array = run["hatching"]
	for egg in hatching.duplicate():
		if SimAuthority.sim_tick < int(egg["tick"]):
			continue
		hatching.erase(egg)
		var mob = instance_from_id(int(egg["mob"]))
		if mob == null or not is_instance_valid(mob) or mob.state == mob.State.DEAD:
			continue
		var at: Vector3 = (mob as Node3D).global_position - run["origin"]
		SimAuthority.apply_damage(mob, 1 << 30, "", null)
		var pack_id := _next_pack
		_next_pack += 1
		var list: Array = run["spawned"].get(String(egg["step"]), [])
		for i in (egg["into"] as Array).size():
			var entry: Dictionary = (egg["into"][i] as Dictionary).duplicate()
			var offset := Vector3(cos(float(i) * 2.4), 0.0, sin(float(i) * 2.4)) * 1.5
			entry["at"] = [at.x + offset.x, at.y, at.z + offset.z]
			var hatchling := _spawn(map_id, entry, run["origin"], pack_id)
			if hatchling != null:
				list.append(hatchling)
		run["spawned"][String(egg["step"])] = list
		run["message"] = "An egg sac splits open!"  # i18n
		_publish(map_id, run)
	var cocoons: Array = run["cocoons"]
	for wrap in cocoons.duplicate():
		var cocoon = instance_from_id(int(wrap["mob"]))
		var broken: bool = cocoon == null or not is_instance_valid(cocoon) or cocoon.state == cocoon.State.DEAD
		if not broken and SimAuthority.sim_tick < int(wrap["until_tick"]):
			continue
		cocoons.erase(wrap)
		var record: Dictionary = SimAuthority.entities.get(int(wrap["uid"]), {})
		if not broken:
			# Nobody cut them free in time: the web drains them and gives way.
			if not record.is_empty():
				SimAuthority.apply_damage(record.get("node"), maxi(1, int(round(float(record.get("max_hp", 100)) * float(wrap["hp_share"])))), "curse", null)
			SimAuthority.apply_damage(cocoon, 1 << 30, "", null)
		SimAuthority.release_player_stun(int(wrap["uid"]))

## Wrap a random living player of the run in a cocoon: held (stunned) until the
## party breaks it, for at most `hold_s`. A lone player has nobody to cut them
## free, so the Queen only wraps someone while two or more stand.
func _wrap_in_cocoon(map_id: String, run: Dictionary, spec: Dictionary, step_id: String) -> void:
	var players := _players(map_id)
	if players.size() < 2:
		return
	var victim: Dictionary = players[randi() % players.size()]
	var at: Vector3 = (victim["node"] as Node3D).global_position - run["origin"]
	var cocoon := _spawn(map_id, {"mob": String(spec.get("mob", "web_cocoon")), "role": "hatchling",
		"at": [at.x, at.y, at.z]}, run["origin"], _next_pack)
	_next_pack += 1
	if cocoon == null:
		return
	var hold := float(spec.get("hold_s", 12.0))
	SimAuthority.stun_player(int(victim.get("uid", 0)), hold)
	(run["cocoons"] as Array).append({"mob": cocoon.get_instance_id(), "uid": int(victim.get("uid", 0)),
		"until_tick": SimAuthority.sim_tick + int(hold * HPProtocol.SIM_HZ), "hp_share": float(spec.get("hp_share", 0.4))})
	var list: Array = run["spawned"].get(step_id, [])
	list.append(cocoon)
	run["spawned"][step_id] = list

# ------------------------------------------------------------------ score

## The clear's whole: every spawn entry's role forces (bosses count 0), groups
## at the run's size and Teeming's extra creatures included.
static func _total_forces(def: Dictionary, params: Dictionary) -> int:
	var total := 0
	var difficulty := String(params.get("difficulty", "normal"))
	for step in def.get("steps", []):
		if not HPRules.dungeon_active_on(step, difficulty):
			continue
		for entry in _with_teeming(_active_entries(step.get("spawn", []), params), params.get("affixes", [])):
			total += int(HPRules.dungeon_role(String(entry.get("role", "trash"))).get("forces", 0))
	return total

## A step's spawn entries that take part in a run (`min_difficulty`), groups
## expanded to one entry per creature: count from HPRules.dungeon_spawn_count,
## set on a sunflower spiral within `spread` metres of the entry's `at`.
static func _active_entries(spawn: Array, params: Dictionary) -> Array:
	var difficulty := String(params.get("difficulty", "normal"))
	var out: Array = []
	for raw in spawn:
		var entry: Dictionary = raw
		if not HPRules.dungeon_active_on(entry, difficulty):
			continue
		if not entry.has("count"):
			out.append(entry)
			continue
		var n := HPRules.dungeon_spawn_count(params, entry)
		var spread := float(entry.get("spread", 3.0))
		var at: Array = entry.get("at", [0, 0, 0])
		for i in n:
			var one := entry.duplicate(true)
			one.erase("count")
			var r := spread * sqrt((float(i) + 0.5) / float(n))
			var a := float(i) * 2.39996
			one["at"] = [float(at[0]) + cos(a) * r, float(at[1]), float(at[2]) + sin(a) * r]
			out.append(one)
	return out

## A step's spawn list under Teeming: one more ordinary creature for every
## four (rounded up), standing beside one of them.
static func _with_teeming(spawn: Array, affixes: Array) -> Array:
	if not affixes.has("teeming"):
		return spawn
	var out := spawn.duplicate()
	var trash := spawn.filter(func(e): return String(e.get("role", "trash")) == "trash")
	var extra := int(ceil(float(trash.size()) * float(HPRules.dungeon_affix("teeming").get("extra", 0.25))))
	for i in extra:
		var twin: Dictionary = (trash[i % trash.size()] as Dictionary).duplicate(true)
		var at: Array = twin.get("at", [0, 0, 0])
		twin["at"] = [float(at[0]) + 1.6, float(at[1]), float(at[2]) + 1.2]
		out.append(twin)
	return out

## Seconds on the run's clock: from the start gate to completion (or now),
## with the death penalties added.
func _elapsed(run: Dictionary) -> float:
	if int(run["start_tick"]) < 0:
		return 0.0
	var end := int(run["end_tick"]) if int(run["end_tick"]) >= 0 else SimAuthority.sim_tick
	var penalty := float(run["deaths"]) * float(HPRules.dungeon_difficulty(String(run["params"]["difficulty"])).get("death_penalty_s", 0))
	return float(end - int(run["start_tick"])) / float(HPProtocol.SIM_HZ) + penalty

func _clear(run: Dictionary) -> float:
	var total := int(run["forces_total"])
	return 1.0 if total <= 0 else minf(1.0, float(run["forces"]) / float(total))

## The run's gold time: the dungeon's par x the difficulty's par_mult.
func _par(run: Dictionary) -> float:
	return float(run["def"].get("par_s", 1200)) \
		* float(HPRules.dungeon_difficulty(String(run["params"]["difficulty"])).get("par_mult", 1.0))

## Credit the clear for creatures that died (or are gone) and count the
## roster's deaths: each one costs time and, where the difficulty has them, a
## party life - the last one breaks the medal.
func _tick_score(map_id: String, run: Dictionary) -> void:
	var changed := false
	var pending: Dictionary = run["pending"]
	var credited := 0
	for id in pending.keys():
		var mob = instance_from_id(int(id))
		if mob == null or not is_instance_valid(mob) or mob.state == mob.State.DEAD:
			credited += int(pending[id])
			pending.erase(id)
	if credited > 0:
		run["forces"] = int(run["forces"]) + credited
		# The run's creatures pay out of its experience budget, not their own.
		SimAuthority.grant_dungeon_kill_exp(map_id, run["params"], credited, int(run["forces_total"]))
		changed = true
	var down: Dictionary = run["down"]
	for record in _players(map_id, false):
		var uid := int(record.get("uid", 0))
		if bool(record.get("dead", false)):
			if not down.has(uid):
				down[uid] = true
				run["deaths"] = int(run["deaths"]) + 1
				changed = true
				if int(run["lives_left"]) > 0:
					run["lives_left"] = int(run["lives_left"]) - 1
					if int(run["lives_left"]) == 0:
						run["broken"] = true
						run["message"] = "The party's lives are spent - no medal this run."  # i18n
		else:
			down.erase(uid)
	if changed:
		_publish(map_id, run)

## Completion: stop the clock and judge the run.
func _finish(map_id: String, run: Dictionary) -> void:
	_tick_score(map_id, run)
	run["end_tick"] = SimAuthority.sim_tick
	var elapsed := _elapsed(run)
	var clear := _clear(run)
	var par := _par(run)
	var medal := ""
	if clear >= 1.0 and not bool(run["broken"]):
		var medals := HPMaps.dungeon_rules("medals")
		for id in ["gold", "silver", "bronze"]:
			if elapsed <= par * float(medals.get(id, 0.0)):
				medal = id
				break
	run["result"] = {"medal": medal, "time_s": elapsed, "clear": clear, "deaths": int(run["deaths"]), "par_s": par}
	print("[Dungeon] %s complete: %.1f s, clear %d%%, %d death(s), medal '%s'" % [map_id, elapsed,
		int(round(clear * 100.0)), int(run["deaths"]), medal])
	# The splits behind the time (balancing par times): seconds at each step of the chain.
	var splits := PackedStringArray()
	for split in run["splits"]:
		splits.append("%s %.0f" % [split[0], float(split[1])])
	print("[Dungeon] %s splits (%s, party %d, ref %d): %s" % [map_id, run["params"]["difficulty"],
		int(run["params"]["party_size"]), int(run["params"]["ref_level"]), ", ".join(splits)])

## The bosses of the run in order, and which have fallen.
func _bosses(map_id: String, run: Dictionary) -> Array:
	var out: Array = []
	var overrides: Dictionary = HPRules.spawn_tables().get("boss_overrides", {})
	var difficulty := String(run["params"]["difficulty"])
	for step in run["def"].get("steps", []):
		if not HPRules.dungeon_active_on(step, difficulty):
			continue
		for entry in step.get("spawn", []):
			# A twin that only rises on a harder difficulty is not this run's boss.
			if entry.has("boss_key") and HPRules.dungeon_active_on(entry, difficulty):
				out.append({"name": String((overrides.get(String(entry["boss_key"]), {}) as Dictionary).get("name", entry.get("mob", ""))),
					"done": _triggered(map_id, run, "cleared:" + String(step.get("id", "")))})
	return out

func _triggered(map_id: String, run: Dictionary, on: String) -> bool:
	if on == "enter":
		return true
	if on == "cleared:all":
		# Every creature the run has put down is dead and no egg is still to hatch.
		return _alive_mobs(run).is_empty() and (run["hatching"] as Array).is_empty() \
			and (run["pending"] as Dictionary).is_empty()
	if on.begins_with("cleared:"):
		var list: Array = (run["spawned"] as Dictionary).get(on.substr(8), [])
		if list.is_empty():
			return false
		for mob in list:
			if is_instance_valid(mob) and mob.state != mob.State.DEAD:
				return false
		return true
	if on.begins_with("hp_below:"):
		# hp_below:<step id>:<fraction> - a creature that step spawned is down to
		# that share of its hit points (or already dead).
		var bits := on.split(":")
		var watched: Array = (run["spawned"] as Dictionary).get(bits[1] if bits.size() > 1 else "", [])
		var fraction := float(bits[2]) if bits.size() > 2 else 0.5
		for mob in watched:
			if not is_instance_valid(mob) or mob.state == mob.State.DEAD:
				return true
			if mob.max_hp > 0 and float(mob.current_hp) / float(mob.max_hp) < fraction:
				return true
		return false
	if on.begins_with("area:"):
		var z_below := float(on.substr(5))
		var origin: Vector3 = run["origin"]
		for uid in SimAuthority.players_by_peer.values():
			var record: Dictionary = SimAuthority.entities.get(uid, {})
			if int(record.get("kind", 0)) != HPProtocol.Kind.PLAYER or String(record.get("map_id", "")) != map_id:
				continue
			var node = record.get("node")
			if node != null and is_instance_valid(node) and (node as Node3D).global_position.z - origin.z < z_below:
				return true
		return false
	return false

func _act(map_id: String, run: Dictionary, step: Dictionary) -> void:
	var origin: Vector3 = run["origin"]
	var id := String(step.get("id", ""))
	if step.has("spawn"):
		var list: Array = []
		var pack_id := _next_pack
		_next_pack += 1
		for entry in _with_teeming(_active_entries(step["spawn"], run["params"]), run["affixes"]):
			var mob := _spawn(map_id, entry as Dictionary, origin, pack_id)
			if mob != null:
				list.append(mob)
				if (entry as Dictionary).has("hatch"):
					(run["hatching"] as Array).append({"mob": mob.get_instance_id(), "step": id,
						"tick": SimAuthority.sim_tick + int(float(entry["hatch"].get("after_s", 45.0)) * HPProtocol.SIM_HZ),
						"into": entry["hatch"].get("into", [])})
		run["spawned"][id] = list
	if step.has("cocoon"):
		_wrap_in_cocoon(map_id, run, step["cocoon"], id)
	for pool in step.get("pools", []):
		var spec: Dictionary = pool
		if String(spec.get("kind", "venom")) == "web":
			_add_hazard(map_id, run, {"kind": "sticky", "center": origin + _vec(spec.get("at", [])), "radius": float(spec.get("radius", 4.0)),
				"until_tick": SimAuthority.sim_tick + int(float(spec.get("duration_s", 20.0)) * HPProtocol.SIM_HZ)})
			continue
		_add_hazard(map_id, run, {"kind": "pool", "center": origin + _vec(spec.get("at", [])), "radius": float(spec.get("radius", 4.0)),
			"until_tick": SimAuthority.sim_tick + int(float(spec.get("duration_s", 20.0)) * HPProtocol.SIM_HZ),
			"hp_share_s": float(spec.get("hp_share_s", 0.04)), "next_tick": SimAuthority.sim_tick + HPProtocol.SIM_HZ})
	for gate in step.get("open", []):
		run["open"][String(gate)] = true
	for gate in step.get("close", []):
		run["open"].erase(String(gate))
	if step.has("message"):
		run["message"] = String(step["message"])
	if bool(step.get("complete", false)):
		run["complete"] = true
		_finish(map_id, run)
	if step.has("chest"):
		var chest: Dictionary = step["chest"]
		var at: Vector3 = origin + _vec(chest.get("at", []))
		# A scored run pays its members (experience, record, personal final
		# chests); a bare chest step is just a table.
		if bool(run["complete"]) and not (run["params"].get("roster", []) as Array).is_empty():
			SimAuthority.grant_dungeon_rewards(map_id, run["params"], run["result"], String(chest.get("table", "")), at)
		else:
			SimAuthority.drop_loot_table(String(chest.get("table", "")), at, map_id)
	if bool(step.get("complete", false)):
		_grant_title(map_id, run)
		for record in _players(map_id, false):
			SimAuthority.quest_event(record, "dungeon", String(run["def"].get("id", "")))
	run["done"][id] = true
	if not bool(step.get("optional", false)):
		(run["splits"] as Array).append([id, _elapsed(run)])
	# A boss behind shut gates: remembered so a wipe can reopen them.
	var on := String(step.get("on", ""))
	if not (step.get("close", []) as Array).is_empty() and on.begins_with("area:"):
		run["lock"] = {"step": id, "gates": (step["close"] as Array).duplicate(), "z": float(on.substr(5)),
			"sealed": true, "message": String(step.get("message", ""))}
	print("[Dungeon] %s step '%s'" % [map_id, id])

## dungeons.json first_clear_title: everyone in the copy when the run completes.
func _grant_title(map_id: String, run: Dictionary) -> void:
	var title: Dictionary = run["def"].get("first_clear_title", {})
	if title.is_empty():
		return
	for record in _players(map_id, false):
		if SimAuthority.grant_title(record, String(title.get("id", ""))):
			SimNet._tell(record, "New title earned: %s!" % String(title.get("name", "")))

func _spawn(map_id: String, entry: Dictionary, origin: Vector3, pack_id: int) -> Node3D:
	var species := String(entry.get("mob", ""))
	var path := HPRules.mob_scene_path(species)
	if path == "" or not ResourceLoader.exists(path):
		push_error("[Dungeon] %s: no scene for '%s'" % [map_id, species])
		return null
	var mob = (load(path) as PackedScene).instantiate()
	var at: Vector3 = origin + _vec(entry.get("at", []))
	mob.position = at
	mob.pack_anchor = at
	mob.pack_id = pack_id
	mob.managed_respawn = true   # a dungeon creature stays dead
	mob.encounter_id = "dng:%s:%d" % [map_id, pack_id]
	# The run's level, not a fixed one: reference + difficulty + role (dungeons.json v2).
	var params: Dictionary = (runs.get(map_id, {}) as Dictionary).get("params", {})
	var level := HPRules.dungeon_mob_level(params, entry)
	mob.level = level
	var pack := {"mob": species, "level": level}
	if encounters != null:
		encounters._configure_member(mob, pack, false, species)
	mob.aggro_mode = "aggressive"
	mob.assist_radius = float(entry.get("assist", 22.0))
	mob.leash_distance = 70.0
	var strength := 1.0
	if entry.has("boss_key") and encounters != null:
		var boss_key := String(entry["boss_key"])
		encounters._apply_boss(mob, {"boss_key": boss_key,
			"template": HPRules.encounter_template(String(entry.get("template", "boss_solo")))})
		mob.set_meta("boss_key", boss_key)
		# Authored boss numbers belong to the override's stat_level; they follow
		# the run's level the way pack stats do.
		var data: Dictionary = (HPRules.spawn_tables().get("boss_overrides", {}) as Dictionary).get(boss_key, {})
		var stat_level := int(data.get("stat_level", level))
		strength = HPRules.level_strength_ratio(stat_level, level)
		mob.attack_power = int(float(mob.attack_power) * strength)
		mob.exp_reward = int(float(mob.exp_reward) * HPRules.level_exp_ratio(stat_level, level))
		mob.max_hp = int(float(mob.max_hp) * strength)
	# Experience comes from the run's budget (SimAuthority.grant_dungeon_kill_exp);
	# drops follow the difficulty; the run's many ordinary creatures roll at
	# rewards.creature_drop of that (bosses keep their full drop).
	mob.exp_reward = 0
	var drop := float(HPRules.dungeon_difficulty(String(params.get("difficulty", ""))).get("drop", 1.0))
	if not mob.is_boss:
		drop *= float(HPRules.dungeon_rewards().get("creature_drop", 1.0))
	mob.set_meta("dungeon_drop", drop)
	if (params.get("affixes", []) as Array).has("bleed") and String(entry.get("role", "")) == "elite":
		mob.set_meta("curse_bleed", true)
	var difficulty := String(params.get("difficulty", "normal"))
	mob.telegraph_scale = float(HPRules.dungeon_difficulty(difficulty).get("telegraph", 1.0))
	if entry.has("harp_scale") and "harp_scale" in mob:
		mob.harp_scale = float((entry["harp_scale"] as Dictionary).get(difficulty, 1.0))
	for mark in (entry.get("marks", {}) as Dictionary).get(difficulty, []):
		mob.set_meta(String(mark), true)
	if entry.has("boss_key") and runs.has(map_id):
		runs[map_id]["bosses_since"][mob.get_instance_id()] = SimAuthority.sim_tick
	var scale := HPRules.dungeon_stat_scale(params, entry)
	mob.max_hp = maxi(1, int(float(mob.max_hp) * float(scale["hp"])))
	mob.attack_power = maxi(1, int(float(mob.attack_power) * float(scale["damage"])))
	if "part_hp_scale" in mob:
		mob.part_hp_scale = strength * float(scale["hp"])
	if entry.has("harp") and "harp_point" in mob:
		mob.harp_point = origin + _vec(entry["harp"])
	# A boss with its own beats (Fluffy's harp, a head fainting) speaks through
	# the run's message line.
	if mob.has_signal("dungeon_message"):
		mob.dungeon_message.connect(func(text: String) -> void:
			var live: Dictionary = runs.get(map_id, {})
			if not live.is_empty():
				live["message"] = text
				_publish(map_id, live))
	container.add_child(mob)
	SimAuthority.register_mob(mob, pack_id, "")
	var forces := int(HPRules.dungeon_role(String(entry.get("role", "trash"))).get("forces", 0))
	if forces > 0 and runs.has(map_id):
		runs[map_id]["pending"][mob.get_instance_id()] = forces
	if runs.has(map_id) and not (runs[map_id]["affixes"] as Array).is_empty():
		runs[map_id]["watch"][mob.get_instance_id()] = mob.global_position
	return mob

func _publish(map_id: String, run: Dictionary) -> void:
	var steps: Array = run["def"].get("steps", [])
	# The chain's last step taken (side slots are not the chain).
	var index := mini(int(run["step"]), steps.size()) - 1
	while index >= 0 and bool((steps[index] as Dictionary).get("optional", false)):
		index -= 1
	var countdown := 0.0
	if run["phase"] == "countdown":
		countdown = float(HPRules.dungeon_group().get("countdown_s", 10)) - float(run["phase_t"])
	var state := {"dungeon": String(run["def"].get("id", "")),
		"step": String((steps[index] as Dictionary).get("id", "")) if index >= 0 else "",
		"open": (run["open"] as Dictionary).keys(), "message": String(run["message"]),
		"complete": bool(run["complete"]), "difficulty": String(run["params"]["difficulty"]),
		"ref_level": int(run["params"]["ref_level"]), "phase": String(run["phase"]), "countdown_s": countdown,
		# The clock: seconds so far (death penalties in), ticking on the client
		# while `phase` is running and the run is not complete.
		"elapsed_s": _elapsed(run), "par_s": _par(run), "forces": int(run["forces"]),
		"forces_total": int(run["forces_total"]), "deaths": int(run["deaths"]),
		"lives_left": int(run["lives_left"]), "broken": bool(run["broken"]), "bosses": _bosses(map_id, run),
		"left": int(run["left"]),
		"result": run["result"], "affixes": run["affixes"]}
	for node in get_tree().get_nodes_in_group("dungeon_instance"):
		if String(node.get_meta("map_id", "")) == map_id and node.has_method("apply_state"):
			node.apply_state(state)
	SimAuthority.publish_dungeon_state(map_id, state)

## Test/debug surface.
func run_state(map_id: String) -> Dictionary:
	return runs.get(map_id, {})

static func _vec(raw: Array) -> Vector3:
	return Vector3(float(raw[0]), float(raw[1]), float(raw[2])) if raw.size() == 3 else Vector3.ZERO
