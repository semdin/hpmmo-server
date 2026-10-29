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
## The hero (art/characters/hero_q: the free Quaternius kit - Modular
## Character Outfits, the Universal Base Characters head and hairstyles, all on
## the Universal rig with GameRig bone names) is several skinned meshes on one
## skeleton: `Hero_Head`, `Hero_Eyes`, `Hero_Brows`, `Hero_Hair_<style>` and the
## outfit parts `Hero_<Outfit>_<part>`; the look picks which are shown. There is
## no trim/robe material to recolour yet; the tint stays keyed on material name,
## so a body that ships `Hero_Trim` / `Hero_Robe` slots (or a house-mask
## material) is tinted and the current one is left as authored.

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
## The wand leaves the fist between thumb and index and leans out along the
## hand: a pointer, not a hammer. Straight across the palm (pinky -> index) the
## aim had to bend the wrist ~70 degrees sideways to point it at a target.
const WAND_LEAN_DEG := 18.0
## The handle sits in the index end of the fist's tunnel: this far from the
## knuckles' centre toward the index (across the palm) and out of the palm,
## so the tip leaves between the thumb and the index knuckle, not through
## the curled fingers.
const WAND_SEAT := Vector2(0.018, 0.006)

static func wand_axis_in_wrist(skeleton: Skeleton3D) -> Vector3:
	var grip := RigIK.grip_frame(skeleton, "R")
	var lean := deg_to_rad(WAND_LEAN_DEG)
	return (grip.basis.x * cos(lean) + grip.basis.y * sin(lean)).normalized()

static func wand_grip_transform(skeleton: Skeleton3D) -> Transform3D:
	var grip := RigIK.grip_frame(skeleton, "R")
	var seat := grip.origin + grip.basis.x * WAND_SEAT.x + grip.basis.z * WAND_SEAT.y
	return Transform3D(Basis(Quaternion(Vector3.UP, wand_axis_in_wrist(skeleton))), seat)


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
	# A tiered wand names its own model (items.json `model`, authored in this
	# prop's frame by art/wands/scripts/build_wands.py); others keep the default.
	var model_path := String(HPEquipment.item(String(entry.get("id", ""))).get("model", ""))
	var scene: PackedScene = load(model_path) as PackedScene if model_path != "" and ResourceLoader.exists(model_path) else WAND
	var wand := scene.instantiate() as Node3D
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

## ---------------------------------------------------------------- cloak

const CLOAK_MODEL := "res://assets/models/cloaks/cloak_base.glb"
static var _cloak_materials: Dictionary = {}

## Draw the worn chest item's cloak, or none. Every cloak item shares one
## skinned mesh (art/cloaks/scripts/build_cloak_sim.py, bound to the same GameRig as
## the body) and names its own fabric (items.json `cloak_texture`). The mesh is
## moved under the body's Skeleton3D, where its skin binds by bone name, so it
## rides every clip, the cast layer and the broom grip like the body does.
static func show_cloak(root: Node, entry: Dictionary) -> void:
	var skeleton: Skeleton3D = _skeleton(root)
	if skeleton == null:
		return
	var texture_path := String(HPEquipment.item(String(entry.get("id", ""))).get("cloak_texture", ""))
	var current := skeleton.get_node_or_null("EquippedCloak") as MeshInstance3D
	if current != null and current.get_meta("cloak_texture", "") == texture_path:
		return
	if current != null:
		skeleton.remove_child(current)
		current.queue_free()
	if texture_path == "" or not ResourceLoader.exists(texture_path):
		return
	var scene := load(CLOAK_MODEL) as PackedScene
	if scene == null:
		return
	var source := scene.instantiate()
	var mesh := source.find_children("*", "MeshInstance3D", true, false)[0] as MeshInstance3D
	# the panel's chain bones come from the cloak model's own skeleton
	var chains := CloakDeformerScript.ensure_bones(skeleton, mesh.get_parent() as Skeleton3D)
	mesh.get_parent().remove_child(mesh)
	source.free()
	if not chains:
		mesh.free()
		return
	mesh.name = "EquippedCloak"
	mesh.set_meta("cloak_texture", texture_path)
	mesh.layers |= CHARACTER_LAYER
	skeleton.add_child(mesh)
	mesh.skeleton = NodePath("..")
	mesh.transform = Transform3D.IDENTITY
	mesh.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_ON
	mesh.material_override = _cloak_material(texture_path)
	# The deformer swings the panel's chain bones (spring bones, with the
	# legs, arms and back as colliders).
	var deformer := CloakDeformerScript.new()
	deformer.name = "CloakDeformer"
	mesh.add_child(deformer)

const CloakDeformerScript = preload("res://scripts/entities/cloak_deformer.gd")
const CLOAK_SHADER := preload("res://assets/shaders/cloak.gdshader")

static func _cloak_material(texture_path: String) -> ShaderMaterial:
	if _cloak_materials.has(texture_path):
		return _cloak_materials[texture_path]
	var mat := ShaderMaterial.new()   # cull_disabled: one sheet of cloth, both faces show
	mat.shader = CLOAK_SHADER
	mat.set_shader_parameter("albedo_tex", load(texture_path))
	mat.set_shader_parameter("roughness", 0.85)
	mat.set_shader_parameter("rim", CLOTH_RIM)
	mat.set_shader_parameter("rim_tint", CLOTH_RIM_TINT)
	_cloak_materials[texture_path] = mat
	return mat

static func _skeleton(root: Node) -> Skeleton3D:
	if root is Skeleton3D: return root
	for child in root.get_children():
		var found := _skeleton(child)
		if found: return found
	return null

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
	# On the character layer before it enters the world (see set_character_layer).
	set_character_layer(body)
	anchor.add_child(body)
	body.position = Vector3.ZERO
	body.rotation = Vector3.ZERO
	apply_house_tint(body, primary)
	# every hairstyle ships in the model: show the default look until the
	# owner's look arrives
	apply_look(body, HPRules.default_look())
	var player := find_anim_player(body)
	var clip := idle_clip(player)
	if clip != "":
		player.play(clip)
	return body


## Dress the hero under `visuals` in its house: the main cloth of every outfit
## takes `primary` (hero_cloth.gdshader `house_color`). The single definition of
## what a house looks like on the body; `visuals` may be the model root or any
## ancestor of it.
static func apply_house_tint(visuals: Node, primary: Color) -> void:
	if visuals == null:
		return
	dress_parts(visuals)
	for node in visuals.find_children("Hero_*", "MeshInstance3D", true, false):
		var part := String(node.name)
		for prefix: String in OUTFIT_PARTS.values():
			if part.begins_with(prefix):
				(node as MeshInstance3D).set_instance_shader_parameter("house_color", primary)


## ---------------------------------------------------------------- lighting

## Render layer (1-based 20) that only characters sit on, so a character light
## can brighten them without touching the world.
const CHARACTER_LAYER := 1 << 19
## The world's sky ambient is tuned for bright stone; dark clothing facing away
## from the sun reads as a black silhouette under it. A soft, shadowless light
## from the camera lifts only characters (light_cull_mask), the usual
## third-person "character fill".
const FILL_ENERGY := 0.28
const FILL_COLOR := Color(0.92, 0.95, 1.0)
## Woven cloth scatters light at grazing angles; a little rim gives the
## silhouette an edge against the background. Only the outfit gets it: on the
## face a rim of 0.3 washed the cheeks and brow out to a grey sheen.
const CLOTH_RIM := 0.1
const CLOTH_RIM_TINT := 0.25
## Parts drawn by the look shaders (colours per hero as instance uniforms).
const SKIN_SHADER := preload("res://assets/shaders/hero_skin.gdshader")
const HAIR_SHADER := preload("res://assets/shaders/hero_hair.gdshader")
const EYE_SHADER := preload("res://assets/shaders/hero_eye.gdshader")
const BROW_SHADER := preload("res://assets/shaders/hero_brow.gdshader")
const BROW_PAINT_SHADER := preload("res://assets/shaders/hero_brow_paint.gdshader")
const CLOTH_SHADER := preload("res://assets/shaders/hero_cloth.gdshader")
## Materials that are skin: the head's and the bare arms every outfit carries.
const SKIN_MATERIALS := ["MI_Superhero_Male", "MI_Regular_Male"]
## Each hairstyle texture's mean luminance in linear colour (hero_hair.gdshader
## divides by it, so every style shows the picked colour at the same depth).
const HAIR_REF_LUMA := {"SimpleParted": 0.2807, "Buzzed": 0.2807, "Long": 0.2692,
	"Wavy": 0.0275, "Tousled": 0.0127, "Neat": 0.0123, "Ponytail": 0.013, "Curly": 0.008,
	"Beard_Full": 0.2807}
## The generated styles' temple shells (Hero_Hair_<style>_Temple, short
## strands): the strands' mean, so they shade like the locks.
const TEMPLE_REF_LUMA := 0.2218
## How far a face type (HPRules.LOOK_FACES) goes: MakeHuman's whole-face
## targets at full strength bloated the triangular and square faces.
const FACE_TYPE_WEIGHT := 0.7
## The head's scalp masks, one per hairstyle (build_rig.py), as one array.
const SCALP_DIR := "res://assets/models/characters/scalp/"
static var _scalp_masks: Texture2DArray = null
## The head's beard area (face_masks.png R; build_rig.py) and the fine grain
## that breaks the painted shade (art/characters/hero_q/skin_grain.py).
const FACE_MASKS := "res://assets/models/characters/face_masks.png"
const SKIN_GRAIN := "res://assets/models/characters/skin_grain.png"
## HPRules.LOOK_BEARDS -> the painted shade's strength (beard_shade) and the
## beard mesh shown ("" = none; the kit's beard).
const BEARDS := {
	"none": {"shade": 0.0, "mesh": ""},
	"stubble": {"shade": 0.5, "mesh": ""},
	"short": {"shade": 0.95, "mesh": ""},
	"full": {"shade": 0.0, "mesh": "Hero_Beard_Full"},
}
## HPRules.LOOK_BROWS -> a painted brow (its tile on Hero_BrowPaint, 1-5) or
## a brow mesh of the kit.
const BROWS := {
	"natural": {"paint": 1, "mesh": ""},
	"bushy": {"paint": 2, "mesh": ""},
	"arched": {"paint": 3, "mesh": ""},
	"thin": {"paint": 4, "mesh": ""},
	"angular": {"paint": 5, "mesh": ""},
	"classic": {"paint": 0, "mesh": "Hero_Brows"},
	"classic_straight": {"paint": 0, "mesh": "Hero_Brows_Regular"},
}
## The iris of the Quaternius eye texture: one disc in the middle.
const IRIS_CENTRE := Vector2(0.5, 0.5)
const IRIS_RADIUS := 0.105
## HPRules.LOOK_OUTFITS -> the mesh-name prefix of its parts.
const OUTFIT_PARTS := {"peasant": "Hero_Peasant_", "peasant_2": "Hero_Peasant_",
	"ranger": "Hero_Ranger_", "ranger_3": "Hero_Ranger_"}
## Per outfit: its texture (empty: the one in the model), the main cloth's
## colour and the dye's brightness; the dyed texels are mask_<outfit>.png
## (art/characters/hero_q/house_masks.py).
const OUTFIT_DIR := "res://assets/models/characters/outfits/"
const OUTFIT_LOOKS := {
	"peasant": {"texture": "", "key": Color("928b70"), "gain": 0.55},
	"peasant_2": {"texture": "T_Peasant_2_BaseColor.png", "key": Color("2e2416"), "gain": 0.55},
	"ranger": {"texture": "", "key": Color("3f5a22"), "gain": 0.75},
	"ranger_3": {"texture": "T_Ranger_3_BaseColor.png", "key": Color("5c5545"), "gain": 0.6},
}
## Height slider: +-5 % of the whole body (the skeleton scales, so props and
## sockets follow).
const LOOK_HEIGHT_SPAN := 0.05

## One dressed material per part surface, shared by every hero.
static var _dressed_materials := {}


## Put every hero part on the character layer and give each surface its look:
## skin, hair, eye and brow surfaces get the look shaders, cloth a little rim.
## Idempotent.
static func dress_parts(visuals: Node) -> void:
	for node in visuals.find_children("Hero_*", "MeshInstance3D", true, false):
		var mi := node as MeshInstance3D
		var part := String(mi.name)
		if mi.layers & CHARACTER_LAYER == 0:
			set_character_layer(mi)
		if mi.mesh == null:
			continue
		for surface in range(mi.mesh.get_surface_count()):
			var source := mi.mesh.surface_get_material(surface)
			if not (source is StandardMaterial3D) or mi.get_surface_override_material(surface) != null:
				continue
			var key := "%s/%d" % [part, surface]
			if not _dressed_materials.has(key):
				_dressed_materials[key] = _dressed(part, source as StandardMaterial3D)
			mi.set_surface_override_material(surface, _dressed_materials[key])


static func _dressed(part: String, base: StandardMaterial3D) -> Material:
	if _is_skin(base):
		var skin := _shader_material(SKIN_SHADER, base)
		skin.set_shader_parameter("has_normal", base.normal_enabled and base.normal_texture != null)
		if base.roughness_texture != null:
			skin.set_shader_parameter("roughness_tex", base.roughness_texture)
			skin.set_shader_parameter("has_roughness", true)
		# only the head carries the scalp masks and the beard areas
		skin.set_shader_parameter("has_scalp", part == "Hero_Head")
		if part == "Hero_Head":
			skin.set_shader_parameter("scalp_tex", _scalp_array())
		if part == "Hero_Head" and ResourceLoader.exists(FACE_MASKS):
			skin.set_shader_parameter("face_mask_tex", load(FACE_MASKS))
			skin.set_shader_parameter("grain_tex", load(SKIN_GRAIN))
			skin.set_shader_parameter("has_face", true)
		return skin
	if part.begins_with("Hero_Hair_") or part.begins_with("Hero_Beard_"):
		var hair := _shader_material(HAIR_SHADER, base)
		var luma := TEMPLE_REF_LUMA if part.ends_with("_Temple") else float(HAIR_REF_LUMA.get(part.trim_prefix("Hero_").trim_prefix("Hair_"), 0.28))
		hair.set_shader_parameter("ref_luma", luma)
		return hair
	if part == "Hero_Eyes":
		var eye := _shader_material(EYE_SHADER, base)
		eye.set_shader_parameter("iris_a", IRIS_CENTRE)
		eye.set_shader_parameter("iris_b", IRIS_CENTRE)
		eye.set_shader_parameter("iris_radius", IRIS_RADIUS)
		return eye
	if part == "Hero_BrowPaint":
		return _shader_material(BROW_PAINT_SHADER, base)
	if part.begins_with("Hero_Brows"):
		return _shader_material(BROW_SHADER, base)
	for outfit: String in OUTFIT_PARTS:
		if part.begins_with(String(OUTFIT_PARTS[outfit])):
			return _cloth_material(base, outfit)
	var cloth := base.duplicate() as StandardMaterial3D
	cloth.rim_enabled = true
	cloth.rim = CLOTH_RIM
	cloth.rim_tint = CLOTH_RIM_TINT
	return cloth


## The scalp masks of HPRules.LOOK_HAIR_STYLES as layers in style order (layer
## = style index); "none", or a style without a mask file, gets an empty layer.
static func _scalp_array() -> Texture2DArray:
	if _scalp_masks != null:
		return _scalp_masks
	var images: Array[Image] = []
	var size := 512
	for style: String in HPRules.LOOK_HAIR_STYLES:
		var path := SCALP_DIR + "scalp_%s.png" % style
		var img: Image = null
		if style != "none" and ResourceLoader.exists(path):
			img = (load(path) as Texture2D).get_image()
			if img.is_compressed():
				img.decompress()
			size = img.get_width()
		else:
			img = Image.create(size, size, false, Image.FORMAT_L8)
		img.convert(Image.FORMAT_L8)
		if img.get_width() != size:
			img.resize(size, size)
		if not img.has_mipmaps():
			img.generate_mipmaps()
		images.append(img)
	_scalp_masks = Texture2DArray.new()
	_scalp_masks.create_from_images(images)
	return _scalp_masks


## The cloth material of `outfit`'s texture variant over the model's own one.
static func _cloth_material(base: StandardMaterial3D, outfit: String) -> ShaderMaterial:
	var look: Dictionary = OUTFIT_LOOKS[outfit]
	var mat := _shader_material(CLOTH_SHADER, base)
	if String(look["texture"]) != "":
		mat.set_shader_parameter("albedo_tex", load(OUTFIT_DIR + String(look["texture"])))
	mat.set_shader_parameter("mask_tex", load(OUTFIT_DIR + "mask_%s.png" % outfit))
	mat.set_shader_parameter("has_normal", base.normal_enabled and base.normal_texture != null)
	mat.set_shader_parameter("key_color", look["key"])
	mat.set_shader_parameter("house_gain", float(look["gain"]))
	mat.set_shader_parameter("rim_amount", CLOTH_RIM)
	return mat


## Put `outfit`'s cloth material on a visible outfit part (its skin surfaces
## keep the skin shader).
static func _wear_variant(mi: MeshInstance3D, part: String, outfit: String) -> void:
	for surface in range(mi.mesh.get_surface_count()):
		var source := mi.mesh.surface_get_material(surface)
		if not (source is StandardMaterial3D) or _is_skin(source):
			continue
		var key := "%s/%d/%s" % [part, surface, outfit]
		if not _dressed_materials.has(key):
			_dressed_materials[key] = _cloth_material(source as StandardMaterial3D, outfit)
		mi.set_surface_override_material(surface, _dressed_materials[key])


static func _is_skin(material: Material) -> bool:
	for name: String in SKIN_MATERIALS:
		if String(material.resource_name).begins_with(name):
			return true
	return false


static func _shader_material(shader: Shader, base: StandardMaterial3D) -> ShaderMaterial:
	var mat := ShaderMaterial.new()
	mat.shader = shader
	mat.set_shader_parameter("albedo_tex", base.albedo_texture)
	if base.normal_enabled and base.normal_texture != null:
		mat.set_shader_parameter("normal_tex", base.normal_texture)
	return mat


## ---------------------------------------------------------------- look

## Draw `look` (HPRules.clean_look) on the hero under `visuals`: the outfit and
## hairstyle (which meshes show), hair/skin/eye colours (instance uniforms of
## the look shaders) and the height. Cheap enough to call on every change; a
## remote body gets it with each player info.
static func apply_look(visuals: Node, raw_look: Dictionary) -> void:
	if visuals == null:
		return
	dress_parts(visuals)
	var look := HPRules.clean_look(raw_look)
	var style := String(HPRules.LOOK_HAIR_STYLES[int(look["hair"])])
	var outfit := String(HPRules.LOOK_OUTFITS[int(look["outfit"])])
	var hair := Color.html(HPRules.LOOK_HAIR_COLORS[int(look["hair_color"])])
	var skin := Color.html(HPRules.LOOK_SKIN_TONES[int(look["skin"])])
	var iris := Color.html(HPRules.LOOK_EYE_COLORS[int(look["eyes"])])
	var beard: Dictionary = BEARDS[String(HPRules.LOOK_BEARDS[int(look["beard"])])]
	var brows: Dictionary = BROWS[String(HPRules.LOOK_BROWS[int(look["brows"])])]
	var scalp_layer := -1.0 if style == "none" else float(HPRules.LOOK_HAIR_STYLES.find(style))
	for node in visuals.find_children("Hero_*", "MeshInstance3D", true, false):
		var mi := node as MeshInstance3D
		var part := String(mi.name)
		if part.begins_with("Hero_Hair_"):
			mi.visible = part == "Hero_Hair_" + style or part == "Hero_Hair_" + style + "_Temple"
			mi.set_instance_shader_parameter("hair_color", hair)
		elif part == "Hero_Eyes":
			mi.set_instance_shader_parameter("iris_color", iris)
		elif part.begins_with("Hero_Beard_"):
			mi.visible = part == String(beard["mesh"])
			mi.set_instance_shader_parameter("hair_color", hair)
		elif part == "Hero_BrowPaint":
			mi.visible = int(brows["paint"]) > 0
			# blended, it still casts shadows as if opaque: the band over the
			# brows shadowed the upper eyelids dark
			mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
			mi.set_instance_shader_parameter("brow_paint", float(brows["paint"]))
			mi.set_instance_shader_parameter("hair_color", hair)
		elif part.begins_with("Hero_Brows"):
			mi.visible = part == String(brows["mesh"])
			mi.set_instance_shader_parameter("hair_color", hair)
		elif part == "Hero_Head":
			mi.set_instance_shader_parameter("hair_color", hair)
			mi.set_instance_shader_parameter("scalp_layer", scalp_layer)
			mi.set_instance_shader_parameter("beard_shade", float(beard["shade"]))
			# tuck_<style>: the ears drawn under a style's locks (build_rig.py)
			var head_mesh := mi.mesh as ArrayMesh
			for shape in range(mi.get_blend_shape_count() if head_mesh != null else 0):
				var shape_name := String(head_mesh.get_blend_shape_name(shape))
				if shape_name.begins_with("tuck_"):
					mi.set_blend_shape_value(shape, 1.0 if shape_name == "tuck_" + style else 0.0)
		var worn := String(OUTFIT_PARTS[outfit])
		for other: String in OUTFIT_PARTS.values():
			if part.begins_with(other):
				mi.visible = part.begins_with(worn)
				if mi.visible:
					_wear_variant(mi, part, outfit)
		if part == "Hero_Head" or part.ends_with("_Arms"):
			mi.set_instance_shader_parameter("skin_tint", skin)
	var skeleton := _skeleton(visuals)
	if skeleton != null:
		skeleton.scale = Vector3.ONE * (1.0 + LOOK_HEIGHT_SPAN * float(look.get("height", 0.0)))
	# face sliders: face_<key>_neg / _pos shape keys on the head and the parts
	# on the face (art/characters/hero_q/face_morphs.py)
	for node in visuals.find_children("Hero_*", "MeshInstance3D", true, false):
		var mi := node as MeshInstance3D
		if mi.get_blend_shape_count() == 0:
			continue
		for key: String in HPRules.LOOK_SLIDERS:
			if key == "height":
				continue
			var v := float(look.get(key, 0.0))
			var neg := mi.find_blend_shape_by_name("face_%s_neg" % key)
			var pos := mi.find_blend_shape_by_name("face_%s_pos" % key)
			if neg >= 0:
				mi.set_blend_shape_value(neg, maxf(0.0, -v))
			if pos >= 0:
				mi.set_blend_shape_value(pos, maxf(0.0, v))
		var face_type := String(HPRules.LOOK_FACES[int(look["face"])])
		for type_name: String in HPRules.LOOK_FACES:
			var k := mi.find_blend_shape_by_name("face_type_" + type_name)
			if k >= 0:
				mi.set_blend_shape_value(k, FACE_TYPE_WEIGHT if type_name == face_type else 0.0)


## The looks of this machine's own characters, by character id, so the
## character screen can draw each one (the account service's list carries no
## quests). Written whenever a look is known: the world join (the server's
## look) and the character screen (`pending`: picked here, not yet sent - the
## next world join sends it). Only a pending look is ever sent, so a stale
## entry on another machine can never overwrite the saved one.
const LOOK_CACHE := "user://character_looks.json"

static func remember_look(character_id: int, look: Dictionary, pending := false) -> void:
	if character_id <= 0:
		return
	var all := _read_look_cache()
	all[str(character_id)] = {"look": HPRules.clean_look(look), "pending": pending}
	var file := FileAccess.open(LOOK_CACHE, FileAccess.WRITE)
	if file != null:
		file.store_string(JSON.stringify(all))

static func recall_look(character_id: int) -> Dictionary:
	var entry = _read_look_cache().get(str(character_id), {})
	return HPRules.clean_look(entry.get("look", {}) if entry is Dictionary else {})

static func has_pending_look(character_id: int) -> bool:
	var entry = _read_look_cache().get(str(character_id), {})
	return entry is Dictionary and bool(entry.get("pending", false))

static func _read_look_cache() -> Dictionary:
	if not FileAccess.file_exists(LOOK_CACHE):
		return {}
	var parsed = JSON.parse_string(FileAccess.get_file_as_string(LOOK_CACHE))
	return parsed if parsed is Dictionary else {}


## Put every mesh under `root` (itself included) on the character layer.
##
## A mesh must get its layers BEFORE it enters the world: the renderer pairs it
## with the lights whose cull mask it matches when it enters, and a later layer
## change never re-pairs it - freeing it then printed "BUG, indexing did not
## unpair geometries from light" (Godot 4.7; a Label3D swaps its base with every
## text change, so a creature's health label printed it on each hit). A mesh
## already in the world is taken out and put back so it pairs afresh. Bodies
## call this from their _enter_tree, when their children have not entered yet.
static func set_character_layer(root: Node) -> void:
	var meshes: Array = root.find_children("*", "GeometryInstance3D", true, false)
	if root is GeometryInstance3D:
		meshes.append(root)
	for node in meshes:
		var gi := node as GeometryInstance3D
		# Labels and sprites change their base as their text or frame changes;
		# they take no light anyway, so they stay off the layer.
		if gi is Label3D or gi is SpriteBase3D or gi.layers & CHARACTER_LAYER != 0:
			continue
		if gi.is_inside_tree():
			var parent := gi.get_parent()
			var index := gi.get_index()
			parent.remove_child(gi)
			gi.layers |= CHARACTER_LAYER
			parent.add_child(gi)
			parent.move_child(gi, index)
		else:
			gi.layers |= CHARACTER_LAYER

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
	# No specular from the fill: a highlight that follows the camera is what made
	# the face look wet and plastic. Lift it from above-left so the face keeps
	# its modelling instead of being flattened by a light on the view axis.
	fill.light_specular = 0.0
	# A light for the characters, not a second sun in the sky.
	fill.sky_mode = DirectionalLight3D.SKY_MODE_LIGHT_ONLY
	fill.rotation_degrees = Vector3(-32, 28, 0)
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
