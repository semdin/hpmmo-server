extends RefCounted

## Parties. OWNER: server repository (synced to the client like the rest of the
## simulation package). Pure bookkeeping on player uids: the authority owns the
## instance, applies the results (experience sharing, notices, replication) and
## drops a leaving player through `leave`. Parties live for the session only.
##
## Commands arrive as chat lines (`/invite Name`, `/accept`, `/decline`,
## `/leave`, `/kick Name`, `/promote Name`, `/p text`), so the client needs no
## new intent: the authority's chat router hands them here.

const MAX_SIZE := 5
## An invitation is answered within this many sim ticks (30 s at 20 Hz).
const INVITE_TTL_TICKS := 600
## Party members inside this radius of a kill share its experience.
const SHARE_RADIUS := 40.0
## Experience bonus per extra member in range (Metin2 style), capped.
const BONUS_PER_MEMBER := 0.1
const BONUS_CAP := 0.4

var parties: Dictionary = {}   # party_id -> {"id", "leader": uid, "members": [uid]}
var by_uid: Dictionary = {}    # uid -> party_id
var invites: Dictionary = {}   # invitee uid -> {"party_id", "from": uid, "expires": tick}
var _next_id := 1


func party_of(uid: int) -> Dictionary:
	return parties.get(int(by_uid.get(uid, 0)), {})


func members_of(uid: int) -> Array:
	return (party_of(uid).get("members", []) as Array).duplicate()


## Experience multiplier for `n` members of one party sharing a kill.
static func share_bonus(n: int) -> float:
	return 1.0 + minf(BONUS_CAP, BONUS_PER_MEMBER * float(maxi(0, n - 1)))


## `from` invites `to`. Returns "" or a refusal reason.
func invite(from: int, to: int, tick: int) -> String:
	if from == to:
		return "self"
	if by_uid.has(to):
		return "already_in_party"
	var party := party_of(from)
	if not party.is_empty():
		if int(party["leader"]) != from:
			return "not_leader"
		if (party["members"] as Array).size() >= MAX_SIZE:
			return "party_full"
	invites[to] = {"party_id": int(party.get("id", 0)), "from": from, "expires": tick + INVITE_TTL_TICKS}
	return ""


## `uid` accepts its pending invitation. Returns the party joined or {}.
func accept(uid: int, tick: int) -> Dictionary:
	var inv: Dictionary = invites.get(uid, {})
	invites.erase(uid)
	if inv.is_empty() or tick > int(inv["expires"]) or by_uid.has(uid):
		return {}
	var from := int(inv["from"])
	var party := party_of(from)
	if party.is_empty():
		# The inviter had no party yet: the invitation founds one.
		if by_uid.has(from):
			return {}
		party = {"id": _next_id, "leader": from, "members": [from]}
		_next_id += 1
		parties[party["id"]] = party
		by_uid[from] = party["id"]
	if (party["members"] as Array).size() >= MAX_SIZE:
		return {}
	(party["members"] as Array).append(uid)
	by_uid[uid] = party["id"]
	return party


func decline(uid: int) -> int:
	var inv: Dictionary = invites.get(uid, {})
	invites.erase(uid)
	return int(inv.get("from", 0))


## `uid` leaves (or is removed). Returns the uids that remain in its party
## (empty when the party dissolved). A leader's departure promotes the next
## member; a party of one dissolves.
func leave(uid: int) -> Array:
	invites.erase(uid)
	var party := party_of(uid)
	by_uid.erase(uid)
	if party.is_empty():
		return []
	var members: Array = party["members"]
	members.erase(uid)
	if members.size() <= 1:
		for other in members:
			by_uid.erase(other)
		parties.erase(party["id"])
		return members.duplicate()
	if int(party["leader"]) == uid:
		party["leader"] = members[0]
	return members.duplicate()


func kick(leader: int, target: int) -> String:
	var party := party_of(leader)
	if party.is_empty() or int(party["leader"]) != leader:
		return "not_leader"
	if not (party["members"] as Array).has(target) or target == leader:
		return "not_member"
	leave(target)
	return ""


func promote(leader: int, target: int) -> String:
	var party := party_of(leader)
	if party.is_empty() or int(party["leader"]) != leader:
		return "not_leader"
	if not (party["members"] as Array).has(target):
		return "not_member"
	party["leader"] = target
	return ""


func expire_invites(tick: int) -> void:
	for uid in invites.keys():
		if tick > int(invites[uid]["expires"]):
			invites.erase(uid)
