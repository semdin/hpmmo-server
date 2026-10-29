extends Node
class_name CloakDeformer

## Moves the worn cloak. The cloak mesh (art/cloaks/scripts/build_cloak_sim.py)
## is skinned to the body's GameRig at the collar and mantle and, below, to
## seven chains of Cloak_<c>_<k> bones hanging down the sheet. This node adds
## those bones to the body's Skeleton3D and swings them with a
## SpringBoneSimulator3D: the chains trail behind a run, sway, stream back on
## the broom, and capsules on the legs, arms, back and seat push them away.
## The mesh stays one skinned surface, so it bends but never tears (the old
## per-vertex capsule push in the shader ripped the hem into strips).
## Lives as a child of the EquippedCloak mesh, which sits under the Skeleton3D.

const CHAINS := 7
const CHAIN_BONES := 6          # joints per chain, the last one the hem tip
const CHAIN_PARENT := "UpperChest"
## The hips plane sits this much deeper than the seat joints: the pelvis tilts
## in the idle and the stride, and a plane right at the seat stood the hem off
## the calves like a board.
const HIPS_SLACK := 0.06
const SHAFT_PARKED := Vector3(0.0, -100.0, 0.0)

var mesh: MeshInstance3D
var skeleton: Skeleton3D
var rider: Node
var springs: SpringBoneSimulator3D
## The broom shaft while riding (parked far off on foot), so the streaming
## cloak lies over the wood instead of through it.
var shaft: SpringBoneCollisionCapsule3D
## The bristles (a fat capsule over the tail half): the thin shaft capsule let
## the fabric between two chains sink into the brush.
var bristles: SpringBoneCollisionCapsule3D
var _bones: Dictionary = {}
## The back planes and their on-foot offsets (parked while riding, see _park_planes).
var _planes: Array[SpringBoneCollisionPlane3D] = []
var _plane_offsets: Array[Vector3] = []
var _planes_parked := false
var _riding := 0.0
var _wind := 0.0
var _time := 0.0


## Add the cloak's chain bones (with their rest poses) from the cloak model's
## own skeleton to the body's, once; they stay when the cloak comes off (a
## Skeleton3D cannot drop bones) and nothing is skinned to them then.
static func ensure_bones(body: Skeleton3D, source: Skeleton3D) -> bool:
	if source == null:
		return false
	for i in source.get_bone_count():
		var bone_name := source.get_bone_name(i)
		if not bone_name.begins_with("Cloak_") or body.find_bone(bone_name) >= 0:
			continue
		var parent_name := source.get_bone_name(source.get_bone_parent(i))
		var parent := body.find_bone(parent_name)
		if parent < 0:
			return false
		var index := body.get_bone_count()
		body.add_bone(bone_name)
		body.set_bone_parent(index, parent)
		body.set_bone_rest(index, source.get_bone_rest(i))
		body.reset_bone_pose(index)
	return body.find_bone("Cloak_0_0") >= 0


func _ready() -> void:
	mesh = get_parent() as MeshInstance3D
	skeleton = mesh.get_parent() as Skeleton3D if mesh != null else null
	if skeleton == null or NetworkManager.is_dedicated_server or skeleton.find_bone("Cloak_0_0") < 0:
		set_process(false)
		return
	for bone in ["Hips", "Neck", "LeftUpperArm", "RightUpperArm"]:
		_bones[bone] = skeleton.find_bone(bone)
	var node: Node = skeleton
	while node != null and not ("is_mounted" in node):
		node = node.get_parent()
	rider = node
	process_priority = 100
	_build_springs()


func _exit_tree() -> void:
	if springs != null and is_instance_valid(springs):
		springs.queue_free()
	springs = null


func _rest(bone: String) -> Vector3:
	var index := skeleton.find_bone(bone)
	return skeleton.get_bone_global_rest(index).origin if index >= 0 else Vector3.ZERO


func _build_springs() -> void:
	springs = SpringBoneSimulator3D.new()
	springs.name = "CloakSprings"
	# after every other modifier: the chains hang from the final upper chest
	skeleton.add_child(springs)
	springs.setting_count = CHAINS
	for c in CHAINS:
		springs.set_root_bone_name(c, "Cloak_%d_0" % c)
		springs.set_end_bone_name(c, "Cloak_%d_%d" % [c, CHAIN_BONES - 1])
		springs.set_extend_end_bone(c, false)
		springs.set_radius(c, 0.03)
		# stiffer at the top (it holds the drape), freer toward the hem
		springs.set_stiffness(c, 3.0)
		springs.set_stiffness_damping_curve(c, _curve(1.0, 0.3))
		springs.set_drag(c, 0.3)
		springs.set_gravity(c, 4.0)
		# the top segments run down and back over the shoulder blades: full
		# gravity swung them toward vertical, into the back
		springs.set_gravity_damping_curve(c, _curve(0.2, 1.0))
	# Collisions. Each chain gets two planes behind the body (on the upper
	# chest and on the hips) at its own rest depth: a joint can never get in
	# front of them, however hard a sudden stop whips the cloak forward
	# (capsules let a fast chain tunnel through and come out the front, inside
	# the body). The limbs are capsules (the strides and the arm swing push
	# the fabric aside).
	var up := (_rest("Neck") - _rest("Hips")).normalized()
	var back := (_rest("RightUpperArm") - _rest("LeftUpperArm")).normalized().cross(up).normalized()
	var limbs: Array[Node] = []
	for s in ["Left", "Right"]:
		limbs.append(_capsule(s + "UpperLeg", _rest(s + "UpperLeg"), _rest(s + "LowerLeg"), 0.085))
		limbs.append(_capsule(s + "LowerLeg", _rest(s + "LowerLeg"), _rest(s + "Foot"), 0.065))
		# fat enough that the fabric between two chains clears the elbow and
		# the hand when the arms swing back
		limbs.append(_capsule(s + "UpperArm", _rest(s + "UpperArm"), _rest(s + "LowerArm"), 0.075))
		# down past the wrist to the fingertips: the hand swinging back in the
		# run cut through the fabric below a capsule that stopped at the wrist
		var wrist := _rest(s + "Hand")
		var fingertips := wrist + (wrist - _rest(s + "LowerArm")).normalized() * 0.17
		limbs.append(_capsule(s + "LowerArm", _rest(s + "LowerArm"), fingertips, 0.07))
	shaft = _capsule("Hips", Vector3.ZERO, Vector3.UP, 0.05)
	shaft.position_offset = SHAFT_PARKED
	limbs.append(shaft)
	bristles = _capsule("Hips", Vector3.ZERO, Vector3.UP, 0.15)
	bristles.position_offset = SHAFT_PARKED
	limbs.append(bristles)
	for c in CHAINS:
		# The upper-chest plane at the shoulder-blade joints' depth, the hips
		# plane at the seat joint's (the rest drape slopes in toward the calves
		# below the seat - the hem would set a plane deep inside the back).
		var blades := minf(_rest("Cloak_%d_1" % c).dot(back), _rest("Cloak_%d_2" % c).dot(back))
		var seat := _rest("Cloak_%d_3" % c).dot(back)
		var x := Vector3(_rest("Cloak_%d_3" % c).x, 0.0, 0.0)
		# the chain's own spring radius plus a few millimetres
		var gap := 0.03 + 0.008
		var hits := limbs.duplicate()
		hits.append(_plane("UpperChest", x + back * (blades - gap) + up * _rest("UpperChest").dot(up), back))
		hits.append(_plane("Hips", x + back * (seat - gap - HIPS_SLACK) + up * _rest("Hips").dot(up), back))
		springs.set_enable_all_child_collisions(c, false)
		springs.set_collision_count(c, hits.size())
		for i in hits.size():
			springs.set_collision_path(c, i, springs.get_path_to(hits[i]))


## A plane through `point` (skeleton space, rest pose) facing `normal`, glued
## to `bone`; joints are kept on its `normal` side.
func _plane(bone: String, point: Vector3, normal: Vector3) -> Node:
	var place := Transform3D(Basis(Quaternion(Vector3.UP, normal)), point)
	var local := skeleton.get_bone_global_rest(skeleton.find_bone(bone)).affine_inverse() * place
	var shape := SpringBoneCollisionPlane3D.new()
	shape.name = "Back_" + bone
	shape.bone_name = bone
	shape.position_offset = local.origin
	shape.rotation_offset = local.basis.get_rotation_quaternion()
	springs.add_child(shape)
	_planes.append(shape)
	_plane_offsets.append(shape.position_offset)
	return shape


## Seated, the back planes tilt with the forward-leaning chest and the rolled
## pelvis until they face up, and the chains had to lie on them: the cape
## stood out level from the shoulders, hovering or not. On the broom the rider
## leans away from the cape and the limb and shaft capsules are enough, so the
## planes move out of the way (50 m to their open side).
func _park_planes(parked: bool) -> void:
	if parked == _planes_parked:
		return
	_planes_parked = parked
	for i in _planes.size():
		var plane := _planes[i]
		plane.position_offset = _plane_offsets[i] - (plane.rotation_offset * Vector3.UP) * (50.0 if parked else 0.0)


func _curve(top: float, bottom: float) -> Curve:
	var curve := Curve.new()
	curve.add_point(Vector2(0.0, top))
	curve.add_point(Vector2(1.0, bottom))
	return curve


## A capsule from a to b (skeleton space, rest pose) glued to `bone`.
func _capsule(bone: String, a: Vector3, b: Vector3, radius: float) -> Node:
	var index := skeleton.find_bone(bone)
	var axis := (b - a).normalized()
	var place := Transform3D(Basis(Quaternion(Vector3.UP, axis)), (a + b) * 0.5)
	var local := skeleton.get_bone_global_rest(index).affine_inverse() * place
	var shape := SpringBoneCollisionCapsule3D.new()
	shape.name = "Hit_" + bone
	shape.radius = radius
	shape.height = a.distance_to(b) + radius * 2.0
	shape.bone_name = bone
	shape.position_offset = local.origin
	shape.rotation_offset = local.basis.get_rotation_quaternion()
	springs.add_child(shape)
	return shape


func _pos(bone: String) -> Vector3:
	var index: int = _bones.get(bone, -1)
	return skeleton.get_bone_global_pose(index).origin if index >= 0 else Vector3.ZERO


func _process(delta: float) -> void:
	if springs == null or not mesh.is_visible_in_tree():
		return
	# later modifiers (wand grip, broom grip, cast layer) are added as the
	# hero dresses: keep the springs last so they hang from the final pose
	if springs.get_index() != skeleton.get_child_count() - 1:
		skeleton.move_child(springs, -1)
	var mounted := rider != null and bool(rider.get("is_mounted"))
	_riding = move_toward(_riding, 1.0 if mounted else 0.0, delta * 2.5)
	var speed := 0.0
	if rider is CharacterBody3D:
		var v: Vector3 = (rider as CharacterBody3D).velocity
		speed = Vector2(v.x, v.z).length() / maxf(1.0, float(rider.get("mounted_speed")) if mounted else 8.0)
	_wind = lerpf(_wind, clampf(speed, 0.0, 1.0), minf(1.0, delta * 3.0))
	# The drag already trails the chains behind a moving body; the wind of
	# the run (and, riding, the airstream) blows them further back and up over
	# the broom. World space, from the body's back direction.
	var up := (_pos("Neck") - _pos("Hips")).normalized()
	var right := (_pos("RightUpperArm") - _pos("LeftUpperArm")).normalized()
	var back := skeleton.global_basis * right.cross(up).normalized()
	back.y = 0.0
	back = back.normalized() if back.length() > 0.01 else Vector3.ZERO
	_place_shaft(mounted)
	_park_planes(_riding > 0.5)
	# Riding, the airstream holds the cape out behind the rider, above the
	# brush but below the horizontal; hovering it still lifts off the broom
	# (hanging slack, it lay in the bristles).
	springs.external_force = back * (_wind * 0.15 * (1.0 - _riding) + _riding * (1.6 + 3.0 * _wind)) + Vector3.UP * (_riding * (0.7 + 1.3 * _wind))
	_flutter(delta, back)


## The cloth never hangs dead in the air: each chain's gravity tilts across
## the fabric on its own phase, so a ripple runs from one edge to the other
## (the springs carry it down to the hem). Strong on the broom - hovering too -
## and faster with speed; on foot only a breath of it in a run.
func _flutter(delta: float, back: Vector3) -> void:
	_time += delta
	var amount := _riding * (0.3 + 0.5 * _wind) + (1.0 - _riding) * 0.15 * _wind
	# hanging, the fabric faces back; streaming behind a fast broom it lies
	# flat and faces up
	var stream := _riding * _wind
	var across := (back * (1.0 - 0.6 * stream) + Vector3.UP * (0.8 * stream)).normalized()
	var rate := 3.2 + 4.0 * _wind
	for c in CHAINS:
		var phase := _time * rate - float(c) * 0.75
		var wave := sin(phase) * 0.65 + sin(phase * 1.73 + float(c) * 1.3) * 0.35
		springs.set_gravity_direction(c, (Vector3.DOWN + across * (wave * amount)).normalized())


## Lay the shaft capsule along the broom from the grip to the tail (in the
## hips bone's space, where the springs read it next update).
func _place_shaft(mounted: bool) -> void:
	var broom = rider.get("broom") if mounted and rider != null else null
	var grip: Node3D = broom.get("grip_socket") if broom != null and is_instance_valid(broom) else null
	var tail: Node3D = broom.get("tail_socket") if broom != null and is_instance_valid(broom) else null
	if grip == null or tail == null or not is_instance_valid(grip) or not is_instance_valid(tail):
		shaft.position_offset = SHAFT_PARKED
		bristles.position_offset = SHAFT_PARKED
		return
	var to_skeleton := skeleton.global_transform.affine_inverse()
	var a := to_skeleton * grip.global_position
	var b := to_skeleton * tail.global_position
	_lay(shaft, a, b)
	# the brush: from a little behind the middle of the broom to the tip
	_lay(bristles, a.lerp(b, 0.62), b.lerp(a, 0.08))


## A capsule from a to b (skeleton space, the current pose), in the hips
## bone's space where the springs read it next update.
func _lay(capsule: SpringBoneCollisionCapsule3D, a: Vector3, b: Vector3) -> void:
	var axis := (b - a).normalized()
	var place := Transform3D(Basis(Quaternion(Vector3.UP, axis)), (a + b) * 0.5)
	var local := skeleton.get_bone_global_pose(skeleton.find_bone("Hips")).affine_inverse() * place
	capsule.height = a.distance_to(b) + capsule.radius * 2.0
	capsule.position_offset = local.origin
	capsule.rotation_offset = local.basis.get_rotation_quaternion()
