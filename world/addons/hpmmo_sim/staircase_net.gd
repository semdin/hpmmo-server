extends Node
class_name HPStaircaseNet

## ADDITIVE MODULE. Transport for HPStaircase.
##
## It is a tiny relay rather than a change to `net.gd`: RPCs are addressed by
## node path, and `net.gd`'s node is the `SimNet` autoload, present under the
## same path in both processes. This relay is created under `SimNet` under a
## fixed name, so `/root/SimNet/HPStaircaseNet` exists on the server and on every
## client, and `publish()` reaches all of them.
##
## The payload is the documented minimal authority shape (see `staircase.gd`);
## every staircase on a map has its own object id and each replica keeps only
## the payloads addressed to it.
## If the addon owner replaces the staircase runtime, this relay can be dropped
## along with it - nothing else references it.

const NODE_NAME := "HPStaircaseNet"
const HPProtocol = preload("res://addons/hpmmo_sim/protocol.gd")

signal state_received(object_id: int, payload: Dictionary)

## Idempotent: whichever process needs the relay first creates it under SimNet;
## every later caller gets the same node. Returns null before the autoloads
## exist (never in a running project).
static func ensure() -> Node:
	var loop := Engine.get_main_loop()
	if loop == null or not (loop is SceneTree):
		return null
	var sim_net := (loop as SceneTree).root.get_node_or_null("SimNet")
	if sim_net == null:
		return null
	var existing := sim_net.get_node_or_null(NODE_NAME)
	if existing != null:
		return existing
	var relay: Node = HPStaircaseNet.new()
	relay.name = NODE_NAME
	sim_net.add_child(relay)
	return relay

## Authority -> every client. Reliable: a missed state change would leave a
## client showing a platform that is not where the server says it is.
##
## `map_id`: only the players on that map receive it (a client on another map
## has no staircase - nor this relay - loaded, and maps do not leak state into
## each other). Empty: every peer, as before.
func publish(payload: Dictionary, object_id: int = HPStaircase.OBJECT_ID, map_id: String = "") -> void:
	if not is_inside_tree():
		return
	if SimNet.is_client or not SimNet.has_peers():
		return
	if map_id == "":
		sim_staircase_state.rpc(object_id, payload)
		return
	for peer_id in SimAuthority.players_by_peer.keys():
		var record := SimAuthority.player_record(int(peer_id))
		if String(record.get("map_id", HPProtocol.DEFAULT_MAP)) == map_id:
			sim_staircase_state.rpc_id(int(peer_id), object_id, payload)

@rpc("authority", "call_remote", "reliable", HPProtocol.CH_EVENT)
func sim_staircase_state(object_id: int, payload: Dictionary) -> void:
	if not SimNet.is_client:
		return   # the authority does not accept world state from a peer
	state_received.emit(object_id, payload)
