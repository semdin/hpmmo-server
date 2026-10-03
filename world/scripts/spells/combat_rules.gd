extends RefCounted

## Client-side face of the shared combat rules.
##
## The rules themselves live in the server-owned simulation package
## (`addons/hpmmo_sim/rules.gd`, synced by `dev.ps1 sync-sim`). This shim exists
## so presentation code keeps a stable API and so there is exactly ONE
## implementation of faction/protection gating in the whole project - the same
## one the world server executes.

static func can_damage(caster: Node, target: Node) -> bool:
	return HPRules.can_damage(caster, target)

static func has_line_of_sight(source: Node3D, target: Node3D) -> bool:
	return HPRules.has_line_of_sight(source, target)

static func safe_up(direction: Vector3) -> Vector3:
	return HPRules.safe_up(direction)
