extends RefCounted

## Client-side face of the authored protection volumes.
##
## Ownership moved to the server in the authority: the volumes live in
## `addons/hpmmo_sim/data/safe_zones.json` and are evaluated by
## `HPRules`. Clients use this for presentation (zone tinting, spawn previews);
## the world server is the only process whose answer decides damage.

static func is_protected_point(point: Vector3) -> bool:
	return HPRules.is_protected_point(point)

static func is_protected_node(node: Node) -> bool:
	return HPRules.is_protected_node(node)

static func is_spawn_blocked(point: Vector3) -> bool:
	return HPRules.is_spawn_blocked(point)

static func zone_id(point: Vector3) -> String:
	return HPRules.protection_id(point)

static func reload() -> void:
	HPRules.reload()
