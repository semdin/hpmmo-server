extends Node
class_name HPStaircaseNet

## ADDITIVE MODULE (plan.md Phase 8). Transport for HPStaircase.
##
## It is a tiny relay rather than a change to `net.gd`: RPCs are addressed by
## node path, and `net.gd`'s node is the `SimNet` autoload, present under the
## same path in both processes. This relay is created under `SimNet` under a
## fixed name, so `/root/SimNet/HPStaircaseNet` exists on the server and on every
## client, and `publish()` reaches all of them.
##
## The payload is the documented minimal authority shape (see `staircase.gd`).
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
func publish(payload: Dictionary) -> void:
	if not is_inside_tree():
		return
	if SimNet.is_client or not SimNet.has_peers():
		return
	sim_staircase_state.rpc(HPStaircase.OBJECT_ID, payload)

@rpc("authority", "call_remote", "reliable", HPProtocol.CH_EVENT)
func sim_staircase_state(object_id: int, payload: Dictionary) -> void:
	if not SimNet.is_client:
		return   # the authority does not accept world state from a peer
	state_received.emit(object_id, payload)
