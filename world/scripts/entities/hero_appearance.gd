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
## The body (art/hero, Rigify-rigged) is ONE baked PBR surface, `Hero_Body`, so
## there is no separate trim/robe material to recolour. The tint stays keyed on
## material name: a body that ships `Hero_Trim` / `Hero_Robe` slots (or a future
## house-mask material) is tinted, and the current body is left as authored.

const MODEL := preload("res://assets/models/characters/hero_wizard.glb")
const WAND := preload("res://assets/models/props/wand.gltf")
const WandGripModifierScript = preload("res://scripts/entities/wand_grip_modifier.gd")

## The prop's own units: `assets/models/props/wand.gltf` is a cylinder whose
## POSITION accessor spans y -0.2656934 .. +0.7004468 (0.9661 m long, 0.0803 m
## radius). The pivot is therefore 0.1063 m above the butt and 0.2802 m below the
## tip once WAND_SCALE is applied - the grip sits at the pivot, the butt clears
## the bottom of the fist and the tip leads it, which is how a wand is held.
const WAND_SCALE := 0.4
const WAND_TIP_LOCAL := Vector3(0.0, 0.7004468, 0.0)
## The handle crosses the palm from pinky to index, not down the forearm.
static func wand_axis_in_wrist(skeleton: Skeleton3D) -> Vector3:
	return RigIK.grip_frame(skeleton, "R").basis.x

static func wand_grip_transform(skeleton: Skeleton3D) -> Transform3D:
	var grip := RigIK.grip_frame(skeleton, "R")
	return Transform3D(Basis(Quaternion(Vector3.UP, grip.basis.x)), grip.origin)


static func _bone_index(skeleton: Skeleton3D, bone: String) -> int:
	return RigIK.bone_index(skeleton, bone)


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
	var wand_grip = root.find_child("WandGripModifier", true, false)
	if entry.is_empty():
		if wand_grip:
			wand_grip.target_weight = 0.0
			wand_grip.weight = 0.0
		return
	var skeleton: Skeleton3D = _skeleton(root)
	if skeleton == null: return
	var bone := HeroBones.hand("R")
	if RigIK.bone_index(skeleton, bone) < 0: return

	# Curl fingers of right hand to firmly grasp the wand
	if wand_grip == null:
		wand_grip = WandGripModifierScript.new()
		wand_grip.name = "WandGripModifier"
		skeleton.add_child(wand_grip)
	wand_grip.target_weight = 1.0
	wand_grip.weight = 1.0

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
	dress_body(mesh_instance)
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
				trim.metallic = 0.0
				trim.roughness = 0.87
				mesh_instance.set_surface_override_material(surface, trim)
			MATERIAL_ROBE:
				var robe := base.duplicate() as StandardMaterial3D
				robe.albedo_color = Color("242936").lerp(primary.darkened(0.65), 0.16)
				mesh_instance.set_surface_override_material(surface, robe)


## ---------------------------------------------------------------- lighting

## Render layer (1-based 20) that only characters sit on, so a character light
## can brighten them without touching the world.
const CHARACTER_LAYER := 1 << 19
## The world's sky ambient is tuned for bright stone; dark clothing facing away
## from the sun reads as a black silhouette under it. A soft, shadowless light
## from the camera lifts only characters (light_cull_mask), the usual
## third-person "character fill".
const FILL_ENERGY := 0.4
const FILL_COLOR := Color(0.92, 0.95, 1.0)
## Woven cloth scatters light at grazing angles; a little rim gives the
## silhouette an edge against the background.
const CLOTH_RIM := 0.3
const CLOTH_RIM_TINT := 0.5

static var _dressed_material: StandardMaterial3D = null


## Put the body on the character layer and give its material the cloth rim.
## Idempotent; every hero shares one dressed material.
static func dress_body(body: MeshInstance3D) -> void:
	body.layers |= CHARACTER_LAYER
	var source := body.mesh.surface_get_material(0) if body.mesh else null
	if not (source is StandardMaterial3D) or body.mesh.get_surface_count() != 1:
		return
	if _dressed_material == null:
		_dressed_material = (source as StandardMaterial3D).duplicate()
		_dressed_material.rim_enabled = true
		_dressed_material.rim = CLOTH_RIM
		_dressed_material.rim_tint = CLOTH_RIM_TINT
	if body.get_surface_override_material(0) == null:
		body.set_surface_override_material(0, _dressed_material)


## Attach the character fill to `camera` (once) and return it.
static func add_character_fill(camera: Camera3D) -> DirectionalLight3D:
	var existing := camera.get_node_or_null("CharacterFill")
	if existing is DirectionalLight3D:
		return existing
	var fill := DirectionalLight3D.new()
	fill.name = "CharacterFill"
	fill.light_cull_mask = CHARACTER_LAYER
	fill.light_energy = FILL_ENERGY
	fill.light_color = FILL_COLOR
	fill.shadow_enabled = false
	fill.light_specular = 0.2
	fill.rotation_degrees = Vector3(-12, 18, 0)
	camera.add_child(fill)
	return fill


## The body's animation player, wherever the importer put it.
static func find_anim_player(node: Node) -> AnimationPlayer:
	if node == null:
		return null
	var found := node.find_child("AnimationPlayer", true, false)
	if found is AnimationPlayer:
		return found as AnimationPlayer
	return null
