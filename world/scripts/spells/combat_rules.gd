extends RefCounted

const SafeZone = preload("res://scripts/world/safe_zone.gd")

## One faction check shared by bolts, cones, explosions and enemy attacks.
static func can_damage(caster: Node, target: Node) -> bool:
	if not is_instance_valid(target) or target == caster or not target.has_method("take_damage"):
		return false
	if target.is_in_group("npcs"):
		return false
	if "current_hp" in target and target.current_hp <= 0:
		return false
	if "is_destroyed" in target and target.is_destroyed:
		return false
	if not is_instance_valid(caster):
		return false
	var faction_ok := false
	if caster.is_in_group("players"):
		faction_ok = not target.is_in_group("players")
	else:
		faction_ok = target.is_in_group("players")
	if not faction_ok:
		return false
	# Phase 1 protected volumes: training dummies stay practiceable, but any
	# other protected participant blocks the attack. This stops mobs attacking
	# from or into the courtyard and stops protected players sniping outdoors.
	if target.is_in_group("dummies"):
		return true
	if SafeZone.is_protected_node(caster) or SafeZone.is_protected_node(target):
		return false
	return true

static func has_line_of_sight(source: Node3D, target: Node3D) -> bool:
	var query := PhysicsRayQueryParameters3D.create(source.global_position + Vector3.UP, target.global_position + Vector3.UP, 1)
	return source.get_world_3d().direct_space_state.intersect_ray(query).is_empty()

static func safe_up(direction: Vector3) -> Vector3:
	return Vector3.FORWARD if absf(direction.normalized().dot(Vector3.UP)) > 0.98 else Vector3.UP
