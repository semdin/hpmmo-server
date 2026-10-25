extends RefCounted

## Duels (v27). OWNER: server repository (synced to the client like the rest of
## the simulation package). Pure bookkeeping on player uids, like party.gd: the
## authority owns the instance, validates distances and maps, applies the
## results (the rules' foe table, the lethal-hit guard, replication) and drops
## a leaving player through `defeat`.
##
## A duel is two sides of player uids: one each for a 1v1, or the gathered
## members of two parties for a group duel. After a short countdown the sides
## may hurt each other (and only each other); a hit that would kill leaves the
## victim at 1 HP and out of the duel instead - no death, no penalty, no
## reward. The last side with someone standing wins.
##
## Commands arrive as chat lines (`/duel Name`, `/gduel Name`, `/daccept`,
## `/ddecline`, `/yield`), so the client needs no new intent.

## A request is answered within this many sim ticks (30 s at 20 Hz).
const REQUEST_TTL_TICKS := 600
## From the accept to the first blow (3 s at 20 Hz).
const COUNTDOWN_TICKS := 60
## A fight that runs this long ends in a draw (5 min).
const MAX_FIGHT_TICKS := 6000
## Who may be challenged: the other duelist (or leader) within this distance.
const CHALLENGE_RANGE := 30.0
## The arena: a circle round the midpoint of the two challengers. A duelist who
## leaves it (or the map) loses.
const ARENA_RADIUS := 40.0
## Party members within this of the arena centre join a group duel.
const GATHER_RADIUS := 40.0
## Player-versus-player hits are softened so a duel is a fight, not a one-shot.
const DAMAGE_MULTIPLIER := 0.5

var requests: Dictionary = {}  # invitee uid -> {"from": uid, "group": bool, "expires": tick}
var duels: Dictionary = {}     # duel_id -> {"id", "sides": [[uid], [uid]], "out": {uid: true}, "group",
                               #   "map_id", "center": Vector3, "fight_tick", "end_tick"}
var by_uid: Dictionary = {}    # uid -> duel_id
var _next_id := 1


func duel_of(uid: int) -> Dictionary:
	return duels.get(int(by_uid.get(uid, 0)), {})


func in_duel(uid: int) -> bool:
	return by_uid.has(uid)


## `from` challenges `to` (for a group duel, `to` is the other party's leader).
## Returns "" or a refusal reason. Distances and parties are the authority's.
func request(from: int, to: int, group: bool, tick: int) -> String:
	if from == to:
		return "self"
	if by_uid.has(from):
		return "busy"
	if by_uid.has(to):
		return "target_busy"
	requests[to] = {"from": from, "group": group, "expires": tick + REQUEST_TTL_TICKS}
	return ""


## `uid` answers its pending request: the request (popped) or {} when there is
## none or it ran out.
func take_request(uid: int, tick: int) -> Dictionary:
	var req: Dictionary = requests.get(uid, {})
	requests.erase(uid)
	if req.is_empty() or tick > int(req["expires"]):
		return {}
	return req


func decline(uid: int) -> int:
	var req: Dictionary = requests.get(uid, {})
	requests.erase(uid)
	return int(req.get("from", 0))


## Open a duel between two sides. Every uid must be free (the caller checked).
func start(side_a: Array, side_b: Array, group: bool, map_id: String, center: Vector3, tick: int) -> Dictionary:
	var duel := {"id": _next_id, "sides": [side_a.duplicate(), side_b.duplicate()], "out": {}, "group": group,
		"map_id": map_id, "center": center, "fight_tick": tick + COUNTDOWN_TICKS,
		"end_tick": tick + COUNTDOWN_TICKS + MAX_FIGHT_TICKS}
	_next_id += 1
	duels[duel["id"]] = duel
	for uid in side_a + side_b:
		by_uid[int(uid)] = duel["id"]
		requests.erase(int(uid))
	return duel


static func fighting(duel: Dictionary, tick: int) -> bool:
	return not duel.is_empty() and tick >= int(duel["fight_tick"])


## 0 or 1: the side `uid` fights on, or -1.
static func side_of(duel: Dictionary, uid: int) -> int:
	for i in 2:
		if (duel["sides"][i] as Array).has(uid):
			return i
	return -1


## The members of side `i` still standing.
static func standing(duel: Dictionary, i: int) -> Array:
	var out: Array = []
	for uid in duel["sides"][i]:
		if not (duel["out"] as Dictionary).has(int(uid)):
			out.append(int(uid))
	return out


## The standing foes of `uid` once the fight is on (empty before, or when
## `uid` is out).
func foes_of(uid: int, tick: int) -> Array:
	var duel := duel_of(uid)
	if not fighting(duel, tick) or (duel["out"] as Dictionary).has(uid):
		return []
	var side := side_of(duel, uid)
	return standing(duel, 1 - side) if side >= 0 else []


## `uid` is out (beaten, fled, gone). Returns the winning side (0/1) once one
## side has nobody standing, else -1.
func defeat(uid: int) -> int:
	var duel := duel_of(uid)
	if duel.is_empty():
		return -1
	duel["out"][uid] = true
	for i in 2:
		if standing(duel, i).is_empty():
			return 1 - i
	return -1


## Close a duel: every member is free again. Returns the members.
func finish(duel_id: int) -> Array:
	var duel: Dictionary = duels.get(duel_id, {})
	duels.erase(duel_id)
	if duel.is_empty():
		return []
	var members: Array = (duel["sides"][0] as Array) + (duel["sides"][1] as Array)
	for uid in members:
		by_uid.erase(int(uid))
	return members


func expire_requests(tick: int) -> void:
	for uid in requests.keys():
		if tick > int(requests[uid]["expires"]):
			requests.erase(uid)
