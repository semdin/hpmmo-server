extends RefCounted
class_name HeroAppearance

## The hero body, and the one house-tint rule that dresses it.
##
## The in-game player and the character-select preview both spawn `MODEL` and
## tint it through here, so the wizard a player picks on the podium is the wizard
## they then play. Before this helper existed the preview loaded a different
## KayKit model (`wizard.glb`) and tinted a `Mage_Cape` node that only that model
## has, so the podium showed a character nobody could ever play.
##
## The tint is material-only and keyed on material name, so it survives a
## re-export of the GLB: `Hero_Trim` takes the house primary, `Hero_Robe` a
## darkened house primary. Nothing is duplicated onto the rig.

const MODEL := preload("res://assets/models/characters/hero_wizard.glb")
const WAND := preload("res://assets/models/props/wand.gltf")

## The prop's own units: `assets/models/props/wand.gltf` is a cylinder whose
## POSITION accessor spans y -0.2656934 .. +0.7004468 (0.9661 m long, 0.0803 m
## radius). The pivot is therefore 0.1063 m above the butt and 0.2802 m below the
## tip once WAND_SCALE is applied - the grip sits at the pivot, the butt clears
## the bottom of the fist and the tip leads it, which is how a wand is held.
const WAND_SCALE := 0.4
const WAND_TIP_LOCAL := Vector3(0.0, 0.7004468, 0.0)
## The finger bases that close around the handle. Their centroid is the fist, so
## placing the pivot there puts the handle inside the grip instead of on the
## wrist joint (which is where the identity transform used to park it).
const GRIP_BONES := ["Index1.R", "Middle1.R", "Ring1.R", "Pinky1.R", "Thumb1.R"]

## The wand's long axis in the Wrist.R bone's frame: the direction the prop
## leaves the fist, i.e. the hand's forward axis.
##
## The prop's own +Y is its long axis, and this is the axis it is mapped onto. It
## is derived from the rig rather than hardcoded: the wrist's rest origin is
## exactly the elbow -> wrist vector, and re-expressing it in the wrist's own
## frame gives the direction the hand continues the arm along. On this rig that
## comes out 6.0 deg from the wrist's own +Y - small, because the rig's wrist bone
## already points along the hand - but taking it from the rest means the grip does
## not silently depend on that coincidence, and it survives a re-export.
##
## The wand then rides the WRIST bone, so this axis is what an aim solver has to
## turn onto a target (see cast_layer_modifier.gd) - it is the wrist's rotation,
## not the forearm's, that decides where the wand points.
static func wand_axis_in_wrist(skeleton: Skeleton3D) -> Vector3:
	return RigIK.hand_axis(skeleton, "Wrist.R")


## The wand's grip transform in the Wrist.R bone's frame, derived from the rig's
## own rests so it holds on the live model, the inventory preview and the podium
## alike, and so it survives a re-export.
##
## It does two things:
##   * puts the pivot at the fist centroid. This is the load-bearing part: the
##     identity transform parked the pivot on the wrist JOINT, so the whole prop
##     sat beyond the fingers as if taped to the back of the hand. The finger
##     bases sit on the wrist's +Y at 0.0272 m, so the pivot moves 2.7 cm along
##     the hand and the closed fingers wrap the handle - and the butt, which is
##     0.106 m below the pivot, now clears the bottom of the fist.
##   * aims the prop's +Y down the hand's forward axis
##     (`wand_axis_in_wrist`) instead of trusting the bone's own +Y to be it.
##
## Roll about the wand's own axis is free (the prop is a cylinder) and is left at
## the minimal rotation from up to that axis.
static func wand_grip_transform(skeleton: Skeleton3D) -> Transform3D:
	var wrist := _bone_index(skeleton, "Wrist.R")
	if wrist < 0:
		return Transform3D(Basis(), Vector3.ZERO)
	var point_dir := wand_axis_in_wrist(skeleton)
	var fist := Vector3.ZERO
	var counted := 0
	var wrist_rest_global := skeleton.get_bone_global_rest(wrist)
	for bone in GRIP_BONES:
		var index := _bone_index(skeleton, bone)
		if index < 0:
			continue
		fist += (wrist_rest_global.inverse() * skeleton.get_bone_global_rest(index)).origin
		counted += 1
	if counted > 0:
		fist /= float(counted)
	# Unit scale: the grip is a POSITION and an ORIENTATION in the bone's space.
	# WAND_SCALE belongs to the prop node, so that particle effects hung off the
	# holder (the refinement aura) keep their own authored size.
	return Transform3D(Basis(Quaternion(Vector3.UP, point_dir)), fist)


## The bone index for `bone`, accepting the importer's sanitised spelling
## (`Foot.L` -> `Foot_L`) so a renamed track cannot silently drop the grip.
static func _bone_index(skeleton: Skeleton3D, bone: String) -> int:
	var index := skeleton.find_bone(bone)
	if index < 0:
		index = skeleton.find_bone(bone.replace(".", "_"))
	if index < 0:
		index = skeleton.find_bone(bone.replace("_", "."))
	return index


## The tip of the equipped wand, as a live node that rides the animation, or null
## when no wand is equipped. Every emitter (spell flash, projectile, trail) reads
## this one definition, so "out of the wand's head" means the same thing
## everywhere.
static func wand_tip(root: Node) -> Node3D:
	if root == null:
		return null
	var attachment := root.find_child("EquippedWand", true, false)
	if attachment == null:
		return null
	return attachment.find_child("WandTip", true, false) as Node3D


## The existing prop follows the same wrist on both the live model and preview.
## This is presentation only: authority remains in HPEquipment.
static func show_equipped_wand(root: Node, entry: Dictionary) -> void:
	var previous := root.find_child("EquippedWand",true,false)
	if previous:
		# Stop the follower holding a reference to a node about to be freed.
		var follower := previous.get_parent().get_node_or_null("RigFollower")
		if follower is RigFollower:
			(follower as RigFollower).detach(previous)
		previous.get_parent().remove_child(previous)
		previous.queue_free()
	if entry.is_empty(): return
	var skeleton: Skeleton3D = _skeleton(root)
	if skeleton == null: return
	var bone := "Wrist.R"
	if skeleton.find_bone(bone) < 0: bone = "Wrist_R"
	if skeleton.find_bone(bone) < 0: return
	# A plain holder glued to the FINAL bone pose by the rig's follower, not a
	# BoneAttachment3D: an attachment follows the skeleton's own update, which runs
	# before the cast layer poses the arm, so the wand used to sit at the clip-only
	# pose while a cast aimed the hand elsewhere. See rig_follower.gd.
	var attachment := Node3D.new()
	attachment.name = "EquippedWand"
	skeleton.add_child(attachment)
	var grip := wand_grip_transform(skeleton)
	RigFollower.of(skeleton).attach(attachment, bone, grip)
	var wand := WAND.instantiate() as Node3D
	wand.transform = Transform3D(Basis().scaled(Vector3.ONE * WAND_SCALE), Vector3.ZERO)
	attachment.add_child(wand)
	# One definition of "the wand's tip", authored in the prop's own space so it
	# follows every pose and is inherited by the mesh's own scaling.
	var tip := Marker3D.new()
	tip.name = "WandTip"
	tip.position = WAND_TIP_LOCAL
	wand.add_child(tip)
	var tier := int(entry.get("tier", 0))
	if tier >= 4:
		var aura := CPUParticles3D.new()
		# The refinement aura belongs to the wand, so it is built here, at the tip,
		# and scales with the tier - a second, statically-placed aura in the player
		# scene used to sit wherever the scene put it, off the wand entirely.
		aura.amount = 20 if tier < 7 else (40 if tier < 9 else 70)
		aura.lifetime = 0.6
		aura.emission_shape = CPUParticles3D.EMISSION_SHAPE_SPHERE
		aura.emission_sphere_radius = 0.035
		aura.gravity = Vector3(0,0.12,0)
		aura.initial_velocity_min = 0.03
		aura.initial_velocity_max = 0.08
		aura.scale_amount_min = 0.012
		aura.scale_amount_max = 0.025
		aura.color = GameData.UPGRADE_TABLE[tier].aura
		# Anchored to the tip in the wand's space (the wand carries the 0.4 scale,
		# so WAND_TIP_LOCAL needs no separate scaling) rather than a guessed 0.28 m
		# up the bone, which pointed the aura away from the wand.
		aura.position = wand.transform * WAND_TIP_LOCAL
		attachment.add_child(aura)

static func _skeleton(root: Node) -> Skeleton3D:
	if root is Skeleton3D: return root
	for child in root.get_children():
		var found := _skeleton(child)
		if found: return found
	return null

const BODY_SURFACE := "Hero_Body"
const MATERIAL_TRIM := "Hero_Trim"
const MATERIAL_ROBE := "Hero_Robe"

## A stationary hero's breathing clip, in preference order. The body carries
## `Idle`; the others are seat/loop fallbacks if the animation set changes.
const IDLE_CLIPS := ["Idle", "Cast_Idle_Loop", "Broom_Seated_Idle"]

## The clip an idle body should play, or "" when it carries none of them.
static func idle_clip(player: AnimationPlayer) -> String:
	if player == null:
		return ""
	for clip in IDLE_CLIPS:
		if player.has_animation(clip):
			return clip
	return ""


## Spawn the hero body under `anchor` and return it, already tinted with `primary`
## and (when the body carries one) playing its idle clip.
##
## `anchor` is any Node3D: the player's `Visuals`, or the podium's `ModelAnchor`.
## The caller resolves `primary` from the house, so this helper stays free of
## game data and is just as usable from a test.
static func spawn(anchor: Node3D, primary: Color) -> Node3D:
	var body := MODEL.instantiate() as Node3D
	if body == null:
		return null
	anchor.add_child(body)
	body.position = Vector3.ZERO
	body.rotation = Vector3.ZERO
	apply_house_tint(body, primary)
	var player := find_anim_player(body)
	var clip := idle_clip(player)
	if clip != "":
		player.play(clip)
	return body


## Tint the robe and trim surfaces of the `Hero_Body` mesh inside `visuals`.
##
## House variation is material-only, so this is the single definition of what a
## house looks like on the body. `visuals` may be the model root or any ancestor
## of it; the body node is found by name.
static func apply_house_tint(visuals: Node, primary: Color) -> void:
	if visuals == null:
		return
	var body := visuals.find_child(BODY_SURFACE, true, false)
	if not (body is MeshInstance3D):
		return
	var mesh_instance := body as MeshInstance3D
	var mesh: Mesh = mesh_instance.mesh
	if mesh == null:
		return
	for surface in range(mesh.get_surface_count()):
		var material := mesh.surface_get_material(surface)
		if not (material is StandardMaterial3D):
			continue
		var base := material as StandardMaterial3D
		match base.resource_name:
			MATERIAL_TRIM:
				var trim := base.duplicate() as StandardMaterial3D
				trim.albedo_color = primary
				trim.metallic = 0.35
				trim.roughness = 0.45
				mesh_instance.set_surface_override_material(surface, trim)
			MATERIAL_ROBE:
				var robe := base.duplicate() as StandardMaterial3D
				robe.albedo_color = primary.darkened(0.72)
				mesh_instance.set_surface_override_material(surface, robe)


## The body's animation player, wherever the importer put it.
static func find_anim_player(node: Node) -> AnimationPlayer:
	if node == null:
		return null
	var found := node.find_child("AnimationPlayer", true, false)
	if found is AnimationPlayer:
		return found as AnimationPlayer
	return null
