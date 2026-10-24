extends CharacterBody3D

## 3D Wizard Player Controller (Metin2 MMO Style)
## Decoupled 3rd-person camera, animated 3D wizard model, wand combat, broom mount, and Ollivander auras

signal stats_changed(hp: int, max_hp: int, mana: int, max_mana: int, exp: int, max_exp: int, level: int)
signal target_changed(target_node: Node3D)
signal spell_cast_signal(spell_id: String, cooldown: float)
signal loot_collected_signal(item_id: String, amount: int)
signal mounted_changed(is_mounted: bool)
signal inventory_changed
signal equipment_changed
signal equipment_answer(result: Dictionary)
## Animation events (`footstep:<surface>`, `fx:wand_release`, ...) that
## Spell effects consumes for audio. Emitted from measured contact, never from a
## hardcoded frame number.
signal animation_event(event_name: String)
## A short player-facing notice ("Descend near level ground first"), shown by the
## HUD's notice banner instead of a floating world label that drifts away.
signal notice(text: String, kind: String)
## The timed effects on this body changed (a buff started, ended or refreshed).
signal buffs_changed
## A click landed on an NPC close enough to talk to (the world opens the dialogue,
## the same path as the interact key).
signal talk_requested(npc: Node3D)

## --------------------------------------------------------------- the rig body
## Measured from hero_wizard.glb (the Rigify hero, 1.75 m crown; art/hero). Every
## distance that depends on body size is derived from these, so a second resize
## is a constant change, not a hunt through the file. The capsule and camera are
## gameplay values and deliberately unchanged by the art swap.
## On-foot speed while webbed by a cavern spider (mobs.json ability `web`).
const WEBBED_FACTOR := 0.5
const HERO_CROWN_HEIGHT := 1.75
const CAMERA_HEIGHT := 1.55          # pivot at chest/eye level of the new body
const NAMEPLATE_HEIGHT := 2.09       # crown + 0.34 headroom for the label
const CAPSULE_RADIUS := 0.35         # art-direction section 2 silhouette
const CAPSULE_HEIGHT := 1.85
const CAST_ORIGIN_HEIGHT := 1.25     # wand hand height when standing
const INTERACT_RADIUS := 3.5         # NPC / object interaction reach
const PICKUP_RADIUS := 4.9           # loot reach (broom-length arm + lean)
const TARGET_RANGE := 35.0
const TARGET_AIM_HEIGHT := 1.15      # chest height of the taller silhouette
## Upper-body clip per step of the basic attack chain (see _play_cast_animation).
const BASIC_COMBO_CLIPS := ["Spellcast_Shoot", "Melee_Chop_A", "Spellcast_Heavy"]
const AIM_ASSIST_PX := 42.0          # cursor snap to a hostile, px at 1080p
const MOUNT_CLEAR_HEIGHT := 1.15     # headroom needed above the crown to take off
const MOUNT_LATERAL_LENGTH := 2.35   # broom footprint length when mounted
const MOUNT_LATERAL_WIDTH := 0.6
const DISMOUNT_CEILING := 2.15       # headroom required at the landing spot
const COMBAT_WINDOW := 2.0           # seconds after taking damage that mounting is refused

## Rig mount state machine. The authority owns the actual permission
## (`submit_mount`); these states only describe the rider's presentation.
enum MountState { GROUND = 0, MOUNTING = 1, FLYING = 2, LANDING = 3 }

var mount_state: int = MountState.GROUND
## Replicated presentation phase (HPProtocol.MountPhase) for remote riders.
var sim_mount_phase: int = 0
var camera_roll_limit := 6.0
var camera_roll := 0.0
var _combat_until := 0.0
var _rider_roll := 0.0
## Names of animation events this body has fired (tests read it; audio will).
var animation_events: Array[String] = []

# Player Info
@export var player_name: String = "Harry"
@export var house: String = "Gryffindor"
@export var wand_tier: int = 0
@export var is_local_player: bool = true

# Base Stats
var level: int = 1
var current_exp: int = 0
var max_exp: int = 200
var max_hp: int = 500
var current_hp: int = 500
var max_mana: int = 300
var current_mana: int = 300
var galleons: int = 500
## Reputation with this character's house (quest rewards only); HPRules turns it
## into the 1..7 house rank that gates content.
var house_rep: int = 0
## The quest log (HPRules.quests_open): progress per open quest {id: count},
## finished quests waiting to be claimed and claimed ones. Written by the
## authority only; a client body mirrors it from the stats payload (`quests`).
var quest_progress: Dictionary = {}
var quest_ready: Array = []
var quest_done: Array = []
## Trained spell levels {spell_id: level} (Metin2 skill training; a missing
## spell is level 0 = not learned, 10 is Master). Written by the authority,
## saved inside the `quests` object as `skills`; unspent points are derived.
var skill_levels: Dictionary = {}
## Extra skill points for characters from before skills had to be learned (they
## keep every spell and every point they had). Saved as `skill_bonus`.
var skill_bonus: int = 0
## Status points spent {vit|int|str|dex: points} (C window, combat.json
## attributes). Written by the authority, saved as `attributes`.
var attributes: Dictionary = {}
var attribute_points: int = 0
## Titles earned (dungeons.json first_clear_title ids, `quests.titles`); the
## newest is shown above the name.
var titles: Array = []
const TITLE_NAMES := {"fc_explorer": "Forbidden Corridor Explorer"}  # i18n
## An authority shove (knockback, a pixie's lift, Fluffy's breath): a velocity
## of its own that rides on top of the input-driven one and fades out.
var _shove := Vector3.ZERO
const SHOVE_DECAY := 26.0
var skill_points: int = 0
## The persisted `quests` object, kept whole so keys this build does not know
## survive a load/save round trip.
var _quest_state: Dictionary = {}
## Last house reputation this body announced (the authority may write
## `house_rep` before the stats payload arrives, so the delta is kept here).
var _shown_house_rep: int = -1
## False until the first stats payload carried `skills` (a load is not a level-up).
var _skills_seen := false
var inventory: Array[Dictionary] = []
var equipment: Dictionary = {}
var inventory_revision: int = 0
var base_max_hp: int = 500
var base_max_mana: int = 300
var equipment_version: int = 0
var derived_stats: Dictionary = {}
var _character_restored := false
var _wand_visual_key := ""

# Movement & Speeds
var walk_speed: float = 6.5
var mounted_speed: float = 12.0
var swim_speed: float = 4.2
var is_mounted: bool = false
var gravity: float = 24.0
## True while the body is inside the Black Lake swim volume. Set every physics
## frame; the animation state reads it to play a paddle instead of a fall.
var is_swimming: bool = false
var _was_swimming: bool = false
## Black Lake swimming: the water line is the grounds' datum (y = 0) and a body is
## in the water wherever GroundsLake says the bed is deep enough under it.
const WATER_SURFACE_Y := 0.0
## Where the swim buoyancy holds the body: a third of a metre under the
## waterline, so a swimmer is in the water rather than standing on it.
const SWIM_FLOAT_Y := -0.35
## Below the lake bed (-16 m) with margin; matches the grounds band in maps.json.
const KILL_PLANE_Y := -30.0
## Broom ceiling: at most this high above the ground under the rider, and never
## above the absolute cap (the castle interior map is authored from y = 185 up).
const FLIGHT_MAX_ABOVE_GROUND := 120.0
const FLIGHT_CEILING_Y := 175.0
## How tall a ledge the body can walk up. `move_and_slide` treats anything
## above the floor snap as a wall, so without this a 0.2 m stair tread stops the
## body dead: every authored flight (world and castle) relied on a separate ramp
## collider, and the doorsteps, dock edges and terrace links had none.
const STEP_UP_HEIGHT := 0.45
const STEP_UP_PROBE := 0.4
const STEP_UP_MIN_SPEED := 0.6
## A step is a WALL at foot height (a tread, a sill). A blocking surface whose
## normal points this far up is ground on a slope, never a step: lifting the body
## over it is what made climbing a hill hop, fall and slide back.
const STEP_WALL_MAX_NORMAL_Y := 0.35

## ----------------------------------------------------------- floor & slopes
## Walkable slope limit. Steeper ground is not floor: the body slides down it
## smoothly instead of standing, and cannot walk up it.
const FLOOR_MAX_ANGLE_DEG := 48.0
## How far the body is pulled down onto the ground while walking. Long enough
## to hold it on a descending terrain at full run speed (8.5 m/s down a 45°
## slope drops ~0.15 m per physics frame), so a run downhill never goes airborne.
const FLOOR_SNAP_LENGTH := 0.45
## Short gaps under the feet (a terrain crease, the frame a slope changes) are
## not a fall. The animation only leaves the ground state after this long in the
## air, or when the body is clearly rising (a jump).
const AIR_GRACE := 0.14
## Only a real fall earns the landing one-shot; a crease does not.
const LAND_MIN_AIR := 0.35
## Steep-slope sliding: downhill speed builds with this acceleration up to the cap.
const STEEP_SLIDE_ACCEL := 14.0
const STEEP_SLIDE_MAX := 7.5

# Decoupled Camera Orbit
var camera_rot_x: float = -20.0
var camera_rot_y: float = 0.0
var camera_distance: float = 8.0
var mouse_orbit_active: bool = false
## Right-button bookkeeping: a press that barely moves and is released quickly
## is a click (inspect a target); anything else was a camera orbit.
const RMB_CLICK_SLOP := 6.0
const RMB_CLICK_MS := 350
var _rmb_travel := 0.0
var _rmb_down_ms := 0

# Combat & Targeting
var current_target: Node3D = null
var spell_cooldowns: Dictionary = {}
var is_protego_active: bool = false
var is_casting_anim: bool = false
var basic_combo_index: int = 0
var basic_combo_timer: float = 0.0
var is_dead := false
var _regen_hp := 0.0
var _regen_mana := 0.0
var _cast_lock := 0.0
var _mount_lock := 0.0
var _mount_notice_cd := 0.0
var _queued_spell := ""
var _queue_time := 0.0
var _mount_blend := 0.0
var _flight_time := 0.0
var _cast_generation := 0
var _basic_held := false
var _hit_recovery := 0.0
var _was_airborne := false
## Seconds the body has been off the floor (0 while grounded).
var _air_time := 0.0
## Air time of the fall that just ended (read once by the landing check).
var _last_air_time := 0.0
## Normal of the too-steep ground the body is resting on, and how fresh it is.
var _steep_normal := Vector3.ZERO
var _steep_time := 0.0
var _slide_speed := 0.0
## Seconds the local body has been standing still (reconciliation settle window).
var _standing_time := 0.0
## Smoothed camera boom length: obstacles pull it in quickly and it eases back
## out, so foliage brushing the boom no longer makes the camera jump.
var _boom_length := 8.0
## Timed effects on this body, for the buff bar: id -> {until_ms (0 = while it
## lasts), duration, icon, title, desc}.
var active_buffs: Dictionary = {}
## Committed attacks: movement is explicitly restricted until this expires
## ("explicit movement restrictions for committed attacks").
var _committed_until := 0.0
## The yaw the body is currently turning to, and whether its facing is the
## movement's (auto-faced) rather than the camera's. The animation state machine
## classifies direction against this instead of the interpolated facing, which it
## has not reached yet.
var _facing_target_yaw := 0.0
var _auto_facing := false
## Spells whose recovery commits the caster in place.
const COMMITTED_SPELLS := {"bombarda": 0.35, "ultimate": 0.5}
## Spells cast with both hands (Spellcast_Heavy); every other cast is one-handed.
const HEAVY_CAST_SPELLS := ["bombarda", "ultimate"]
## Spells with their own retargeted clip (tools/blender/retarget_clip.py ->
## assets/animations/hero/, merged by HeroAnimation.merge_extra_clips).
## `release` is the clip fraction where the wand hand is furthest forward
## (written by the retarget script), `hold` how long the cast layer owns the arm,
## `aim` false for a swing that must keep its own arc (the wand is not held on
## the target). The basic chain is keyed per step: "basic_cast:<step>".
## Sources and trims: art/hero/motion_fal/*.json.
const SPELL_CLIPS := {
	"stupefy": {"clip": "Cast_Stupefy", "release": 0.226, "hold": 0.72},
	"incendio": {"clip": "Cast_Incendio", "release": 0.25, "hold": 0.66, "aim": false},
	# The stag leaves the wand like Incendio's cone: same thrust, silver.
	"patronum": {"clip": "Cast_Incendio", "release": 0.25, "hold": 0.7, "aim": false},
	"bombarda": {"clip": "Cast_Bombarda", "release": 0.182, "hold": 0.7},
	"expelliarmus": {"clip": "Cast_Expelliarmus", "release": 0.128, "hold": 0.6},
	"protego": {"clip": "Cast_Protego", "release": 0.128, "hold": 0.9, "aim": false},
	"ultimate": {"clip": "Cast_Ultimate", "release": 0.158, "hold": 0.85},
	"basic_cast:0": {"clip": "Cast_Basic1", "release": 0.182, "hold": 0.36},
	"basic_cast:1": {"clip": "Cast_Basic2", "release": 0.182, "hold": 0.4, "aim": false},
	"basic_cast:2": {"clip": "Cast_Basic3", "release": 0.179, "hold": 0.55},
}
const COMMITTED_MELEE := 0.45
## Deceleration (m/s^2) once a WALKING body's movement input is released. The
## authored value was `walk_speed * 12` = 102, which left 0.28 m of glide over 4
## frames after the key was let go - read as the character sliding on after it had
## stopped and already gone back to its idle clip. 180 m/s^2 stops in 0.20 m.
## Mounted and airborne bodies keep the authored value (see _physics_process).
const GROUND_STOP_DECEL := 180.0
## A standing body ignores a horizontal snapshot offset inside this radius: it is
## the server still catching up on the client's own deceleration, not a
## disagreement. Real discrepancies (walls, knockback, platforms, teleports) are
## larger than this and are corrected. The vertical axis is never tolerated.
const STANDING_TOLERANCE := 0.5
## How long after stopping a snapshot that lies on our own recent path is still
## treated as the server catching up (two snapshot intervals + a generous RTT).
const STANDING_SETTLE := 0.9
## Rolling history of local positions used for latency-tolerant reconciliation.
var _pos_history = preload("res://scripts/entities/prediction_history.gd").new()

var _cast_seq := 0
var _replicated_cast_id := -1
var _predicted_casts: Dictionary = {}   # cast_seq -> {spell_id, aim}
var _predicted_ward := false
## Server-side only: the latest movement intent this player sent. When
## `sim_server_controlled` is true the body is driven by that intent instead of
## local input - this is the node the authority simulates.
var sim_input: Dictionary = {}
var sim_server_controlled := false
## Client-side view of another player (or of a mob): follows replicated state.
var sim_puppet := false
var sim_target_pos := Vector3.ZERO
var sim_target_rot := 0.0
## Buffered snapshot interpolation for this view (game_world pushes every
## replicated sample; see ReplicaMotion).
var sim_motion := ReplicaMotion.new()
const CombatRules = preload("res://scripts/spells/combat_rules.gd")
const ParticleKit = preload("res://scripts/assets/particle_kit.gd")
const HeroAnimationScript = preload("res://scripts/entities/hero_animation.gd")
const BroomFlightScript = preload("res://scripts/entities/broom_flight.gd")
const BroomGripModifierScript = preload("res://scripts/entities/broom_grip_modifier.gd")
## Rig socket convention: one socket per attachment point, bound to the
## skeleton by bone name.
const SOCKET_BONES := {
	"Socket_Wand": "RightHand",
	"Socket_Hand_L": "LeftHand",
	"Socket_Hand_R": "RightHand",
	"Socket_Foot_L": "LeftFoot",
	"Socket_Foot_R": "RightFoot",
	"Socket_Torso": "UpperChest",
	"Socket_Head": "Head",
	"Socket_Hips": "Hips",
}

# Node References
@onready var visuals: Node3D = get_node_or_null("Visuals")
@onready var anim_player: AnimationPlayer = _find_anim_player()
@onready var camera_pivot: Node3D = get_node_or_null("CameraPivot")
@onready var spring_arm: SpringArm3D = get_node_or_null("CameraPivot/SpringArm3D")
@onready var camera: Camera3D = get_node_or_null("CameraPivot/SpringArm3D/Camera3D")
@onready var broom_mesh: Node3D = get_node_or_null("Visuals/BroomMesh")
@onready var broom_particles: CPUParticles3D = get_node_or_null("Visuals/BroomMesh/BroomParticles")
## The nodes the broom GLB put under BroomMesh (captured before the rig and its
## effects join them); `_apply_broom_model` swaps exactly these for the equipped
## broom's own model and leaves the rig, particles and trail in place.
var _broom_model_parts: Array[Node] = []
var _broom_model_path := HPEquipment.DEFAULT_BROOM_MODEL
## The wand's own tip (a marker inside the equipped prop) is the only wand point
## this body exposes - see `wand_tip_position`. There is no scene-level marker or
## aura any more: both were fixed offsets that did not follow the wand.
@onready var wand_aura_particles: CPUParticles3D = null
@onready var nameplate: Label3D = get_node_or_null("NameplateLabel3D")
## The animation graph and the authored broom rig.
var hero_anim: HeroAnimation
var broom: BroomFlight
## Solves the rider's hands onto the broom shaft while mounted.
var broom_grip: BroomGripModifier
var sockets: Dictionary = {}

func _find_anim_player() -> AnimationPlayer:
	var vis = get_node_or_null("Visuals")
	if vis:
		var found := vis.find_child("AnimationPlayer", true, false)
		if found:
			return found as AnimationPlayer
	return null

func _find_skeleton() -> Skeleton3D:
	if visuals == null:
		return null
	return visuals.find_child("Skeleton3D", true, false) as Skeleton3D

const PROJECTILE_SCENE = preload("res://scenes/spells/spell_projectile.tscn")
const PROTEGO_SCENE = preload("res://scenes/spells/protego_shield.tscn")
const FT_SCENE = preload("res://scenes/ui/floating_text.tscn")

func _ready() -> void:
	add_to_group("players")
	floor_max_angle = deg_to_rad(FLOOR_MAX_ANGLE_DEG)
	floor_snap_length = FLOOR_SNAP_LENGTH
	floor_constant_speed = true
	floor_stop_on_slope = true
	floor_block_on_wall = true
	
	if is_local_player:
		var nm = get_node_or_null("/root/NetworkManager")
		if nm:
			player_name = nm.local_player_name
			house = nm.local_player_house
	
	# Decouple camera pivot from player rotation completely
	if camera_pivot and spring_arm:
		camera_pivot.top_level = true
		camera_pivot.global_position = global_position + Vector3(0, CAMERA_HEIGHT, 0)
		camera_pivot.rotation_degrees = Vector3(0, camera_rot_y, 0)
		spring_arm.rotation_degrees = Vector3(camera_rot_x, 0, 0)
		spring_arm.spring_length = camera_distance
	if nameplate:
		nameplate.position.y = NAMEPLATE_HEIGHT
	_setup_sockets()
	
	_setup_character_model()
	if is_local_player and camera:
		HeroAppearance.add_character_fill(camera)
	if broom_particles:
		ParticleKit.configure(broom_particles, true)
		broom_particles.amount = 55
		broom_particles.lifetime = 0.65
		broom_particles.direction = Vector3(0, -1, 0)
		broom_particles.spread = 12.0
		broom_particles.initial_velocity_min = 1.0
		broom_particles.initial_velocity_max = 3.0
		broom_particles.gravity = Vector3(0, 0.35, 0)
	if spring_arm:
		# The boom's own collision snapped its length every frame a branch or a
		# leaf card crossed it - the camera "shook" whenever the player stopped
		# among trees. The length is resolved here instead (see `_update_boom`).
		spring_arm.collision_mask = 0
		spring_arm.add_excluded_object(get_rid())
		_boom_length = camera_distance
	_apply_house_customization()
	_apply_wand_aura()
	_update_nameplate()
	if not _character_restored:
		_init_starter_inventory()
		_initialize_equipment()
	
	if not is_local_player:
		if camera:
			camera.current = false
		if camera_pivot:
			camera_pivot.hide()
	else:
		if camera:
			camera.current = true
		emit_stats()

func _setup_character_model() -> void:
	# Rig hero: the model, its animation graph and the broom rig. The
	# graph is a child of Visuals so it dies with the body and never leaks.
	var skeleton := _find_skeleton()
	if anim_player and skeleton:
		hero_anim = HeroAnimationScript.new()
		hero_anim.name = "HeroAnimation"
		visuals.add_child(hero_anim)
		hero_anim.setup(anim_player, skeleton, visuals)
		hero_anim.event_fired.connect(_on_animation_event)
	_setup_broom()

## Build the socket set once, from the documented bone map. Sockets are
## BoneAttachment3D nodes so they follow the skeleton without baking offsets into
## the GLB (the moved-body contract: change a bone name here, nowhere else).
func _setup_sockets() -> void:
	var skeleton := _find_skeleton()
	if skeleton == null or not sockets.is_empty():
		return
	for socket_name in SOCKET_BONES.keys():
		var bone: String = SOCKET_BONES[socket_name]
		if skeleton.find_bone(bone) < 0:
			push_warning("Hero skeleton has no bone %s for %s" % [bone, socket_name])
			continue
		var attachment := BoneAttachment3D.new()
		attachment.name = socket_name
		attachment.bone_name = bone
		skeleton.add_child(attachment)
		sockets[socket_name] = attachment

func socket(name: String) -> Node3D:
	return sockets.get(name, null)

func _setup_broom() -> void:
	if broom_mesh == null:
		return
	for part in broom_mesh.get_children():
		if part != broom_particles:
			_broom_model_parts.append(part)
	broom = BroomFlightScript.new()
	broom.name = "BroomRig"
	broom_mesh.add_child(broom)
	broom.setup(self, visuals, broom_particles, broom_mesh)
	# The rider is solved onto the broom while mounted (broom_grip_modifier.gd):
	# the authored seat pose never matched the hands to the shaft. Added after the
	# cast layer, so the grip wins the arms within the same modifier pass.
	var skeleton := _find_skeleton()
	if skeleton:
		broom_grip = BroomGripModifierScript.new()
		broom_grip.name = "BroomGripModifier"
		skeleton.add_child(broom_grip)
		broom_grip.setup(broom)
	if broom_mesh is Node3D:
		broom_mesh.rotation = Vector3.ZERO   # the authored GLB is already +Z forward
	_align_broom_to_hips()
	_apply_broom_model()   # equipment can arrive before the rig exists

## The equipped broom item names its model (items.json `model`). This runs
## wherever equipment is recalculated - the authority, the owner and every
## replica that receives the owner's stats - so everyone sees the same broom.
## Every broom GLB carries the same parts and sockets (BroomRoot > Broom_Shaft,
## Bristles, Grip/Mount/Seat/TailSocket), so only those nodes are replaced.
func _apply_broom_model() -> void:
	if broom == null or broom_mesh == null:
		return
	var path := HPEquipment.broom_model(String((equipment.get("broom", {}) as Dictionary).get("id", "")))
	if path == _broom_model_path:
		return
	var scene := load(path) as PackedScene
	if scene == null:
		push_warning("Broom model missing: %s" % path)
		return
	_broom_model_path = path
	for part in _broom_model_parts:
		if is_instance_valid(part):
			broom_mesh.remove_child(part)
			part.queue_free()
	_broom_model_parts.clear()
	var model := scene.instantiate()
	for part in model.get_children():
		model.remove_child(part)
		# The parts leave the GLB scene: drop its owner, or add_child warns
		# that the owner became inconsistent.
		part.owner = null
		broom_mesh.add_child(part)
		_broom_model_parts.append(part)
	model.free()
	broom.rebind_model(broom_mesh)
	_align_broom_to_hips()

## The single mount convention: the broom's SeatSocket is placed under the
## hero's Socket_Hips, so the rider sits on the saddle without per-clip fudging.
func _align_broom_to_hips() -> void:
	if broom == null or broom.seat_socket == null or visuals == null:
		return
	var hips := socket("Socket_Hips")
	if hips == null:
		return
	var target_local := visuals.to_local(hips.global_position)
	broom_mesh.position = target_local - broom.seat_offset()

## House variation is material-only (no duplicated rig): the robe family takes a
## darkened house tone and the trim family the house primary colour. The rule
## itself lives in `HeroAppearance`, which the character-select preview also
## calls, so the podium and the body cannot drift apart.
func _apply_house_customization() -> void:
	if not GameData.HOUSES.has(house):
		return
	HeroAppearance.apply_house_tint(visuals, GameData.HOUSES[house].primary_color)

	if _character_restored:
		return
	if house == "Hufflepuff":
		max_hp = 625
		current_hp = 625
	elif house == "Ravenclaw":
		max_mana = 375
		current_mana = 375

## MMO nameplate: the name on its own line in a clean bold face, and under it
## a smaller "Lv. 10 · Gryffindor" line in the house colour. Both are
## billboarded, outlined and drawn over the world so hair and hats never cut
## them; the local player's name is a soft gold, everyone else's is white.
var _nameplate_sub: Label3D = null
var _nameplate_title: Label3D = null

func _update_nameplate() -> void:
	if nameplate == null:
		return
	var bold_path := "res://assets/fonts/Marcellus-Regular.ttf"
	var font: Font = load(bold_path) if ResourceLoader.exists(bold_path) else null
	nameplate.text = player_name
	nameplate.position.y = NAMEPLATE_HEIGHT + 0.13
	nameplate.font_size = 46
	nameplate.outline_size = 12
	nameplate.pixel_size = 0.0034
	nameplate.no_depth_test = true
	nameplate.render_priority = 5
	nameplate.outline_render_priority = 4
	nameplate.outline_modulate = Color(0.04, 0.03, 0.02, 0.88)
	nameplate.modulate = Color(1.0, 0.88, 0.58) if is_local_player else Color(0.96, 0.96, 0.94)
	if font != null:
		nameplate.font = font
	if _nameplate_sub == null:
		_nameplate_sub = Label3D.new()
		_nameplate_sub.name = "NameplateSub"
		_nameplate_sub.billboard = BaseMaterial3D.BILLBOARD_ENABLED
		_nameplate_sub.double_sided = false
		_nameplate_sub.no_depth_test = true
		_nameplate_sub.render_priority = 5
		_nameplate_sub.outline_render_priority = 4
		# A child of the name, so hiding the nameplate hides both lines.
		nameplate.add_child(_nameplate_sub)
	_nameplate_sub.position = Vector3(0, -0.13, 0)
	_nameplate_sub.text = tr("Lv. %d  ·  %s") % [level, house]
	_nameplate_sub.font_size = 30
	_nameplate_sub.outline_size = 9
	_nameplate_sub.pixel_size = 0.0034
	_nameplate_sub.outline_modulate = Color(0.04, 0.03, 0.02, 0.85)
	var tint := Color(0.85, 0.85, 0.85)
	if GameData.HOUSES.has(house):
		tint = (GameData.HOUSES[house].primary_color as Color).lightened(0.42)
	_nameplate_sub.modulate = tint
	if font != null:
		_nameplate_sub.font = font
	WorldLabels.track(nameplate, 20.0)
	WorldLabels.track(_nameplate_sub, 14.0)
	# The newest title rides above the name.
	var title := String(TITLE_NAMES.get(titles[-1], titles[-1])) if not titles.is_empty() else ""
	if title != "" and _nameplate_title == null:
		_nameplate_title = Label3D.new()
		_nameplate_title.name = "NameplateTitle"
		_nameplate_title.billboard = BaseMaterial3D.BILLBOARD_ENABLED
		_nameplate_title.double_sided = false
		_nameplate_title.no_depth_test = true
		_nameplate_title.render_priority = 5
		_nameplate_title.outline_render_priority = 4
		_nameplate_title.font_size = 28
		_nameplate_title.outline_size = 8
		_nameplate_title.pixel_size = 0.0034
		_nameplate_title.outline_modulate = Color(0.04, 0.03, 0.02, 0.85)
		_nameplate_title.modulate = Color(1.0, 0.8, 0.42)
		_nameplate_title.position = Vector3(0, 0.15, 0)
		if font != null:
			_nameplate_title.font = font
		nameplate.add_child(_nameplate_title)
		WorldLabels.track(_nameplate_title, 14.0)
	if _nameplate_title != null:
		_nameplate_title.text = "« %s »" % title if title != "" else ""

func _init_starter_inventory() -> void:
	inventory.clear()
	# A new student starts with the basic wand only; the cloak, accessories and
	# the broom (level 5) are quest rewards (quests.json).
	inventory.append({"id": "wand_ashwood", "amount": 1, "tier": wand_tier})
	inventory.append({"id": "potion_health", "amount": 5, "tier": 0})
	inventory.append({"id": "potion_mana", "amount": 5, "tier": 0})
	HPEquipment.normalize(inventory, equipment)   # the wand becomes an instance

func _unhandled_input(event: InputEvent) -> void:
	if not is_local_player or is_dead or input_blocked():
		return
	
	# Mouse look on right-click hold (Classic MMO / Metin2 feel)
	if event is InputEventMouseButton:
		if event.button_index == MOUSE_BUTTON_RIGHT:
			mouse_orbit_active = event.pressed
			CursorKit.set_rotating(event.pressed)
			if event.pressed:
				_rmb_travel = 0.0
				_rmb_down_ms = Time.get_ticks_msec()
			elif _rmb_travel < RMB_CLICK_SLOP and Time.get_ticks_msec() - _rmb_down_ms < RMB_CLICK_MS:
				# A right CLICK (not an orbit drag) talks to an NPC under the cursor,
				# or inspects whatever else is there: it becomes the target, so its
				# card shows, without a cast.
				if not _click_npc():
					_inspect_click_target()
		elif event.button_index == MOUSE_BUTTON_WHEEL_UP:
			camera_distance = clamp(camera_distance - 0.8, 3.0, 16.0)
		elif event.button_index == MOUSE_BUTTON_WHEEL_DOWN:
			camera_distance = clamp(camera_distance + 0.8, 3.0, 16.0)
		elif event.button_index == MOUSE_BUTTON_LEFT and event.pressed:
			if _click_npc():
				return   # NPCs are talked to, never shot at
			_basic_held = true
			_try_click_target()
			cast_spell("basic_cast")
	
	elif event is InputEventMouseMotion and mouse_orbit_active:
		_rmb_travel += absf(event.relative.x) + absf(event.relative.y)
		# Interface hook: the mouse sensitivity slider scales the same raw
		# relative motion; 1.0 is the authored speed.
		var sensitivity: float = GameSettings.mouse_sensitivity_value()
		camera_rot_y -= event.relative.x * 0.28 * sensitivity
		camera_rot_x = clamp(camera_rot_x - event.relative.y * 0.25 * sensitivity, -70.0, 25.0)

func _input(event: InputEvent) -> void:
	# Releases must be observed even if a GUI panel consumes the event.
	if event is InputEventMouseButton and not event.pressed:
		if event.button_index == MOUSE_BUTTON_LEFT:
			_basic_held = false
		elif event.button_index == MOUSE_BUTTON_RIGHT:
			mouse_orbit_active = false
			if is_local_player:
				CursorKit.set_rotating(false)

func _process(delta: float) -> void:
	# Tick spell cooldowns
	for spell_id in spell_cooldowns.keys():
		spell_cooldowns[spell_id] = max(0.0, spell_cooldowns[spell_id] - delta)
	
	# Basic combo decay (Section 4.3 of.md)
	if basic_combo_timer > 0.0:
		basic_combo_timer -= delta
		if basic_combo_timer <= 0.0:
			basic_combo_index = 0
	
	_cast_lock = maxf(0.0, _cast_lock - delta)
	_committed_until = maxf(0.0, _committed_until - delta)
	_hit_recovery = maxf(0.0, _hit_recovery - delta)
	_mount_lock = maxf(0.0, _mount_lock - delta)
	_mount_notice_cd = maxf(0.0, _mount_notice_cd - delta)
	_queue_time = maxf(0.0, _queue_time - delta)
	_combat_until = maxf(0.0, _combat_until - delta)
	_expire_buffs()
	_update_flight_pose(delta)
	if hero_anim:
		hero_anim.tick(delta)
		# Keep a wand cast tracking its target: the aim point is the mouse (or the
		# locked target), which moves while the gesture plays. Only a cast that is
		# aiming is refreshed, so a melee swing is never overwritten.
		if is_local_player and not is_dead and hero_anim.cast_aiming():
			hero_anim.set_cast_aim(get_mouse_aim_point())
	if is_local_player and not is_dead:
		# Regeneration is authoritative (the world server ticks it and mirrors the
		# result back), so the local body no longer regenerates on its own.
		if not input_blocked():
			_handle_hotkeys()
			if _basic_held and _queued_spell == "" and _cast_lock <= 0 and float(spell_cooldowns.get("basic_cast", 0)) <= 0:
				cast_spell("basic_cast")
			if _queued_spell != "" and _cast_lock <= 0 and float(spell_cooldowns.get(_queued_spell, 0.0)) <= 0:
				var queued := _queued_spell
				_queued_spell = ""
				if _queue_time > 0:
					cast_spell(queued)
		else:
			_queued_spell = ""
			_basic_held = false
	if is_instance_valid(current_target) and "current_hp" in current_target and current_target.current_hp <= 0:
		set_target(null)

## Splash burst + expanding ripple ring at the waterline (entering or leaving the lake).
func _spawn_water_splash() -> void:
	if NetworkManager.is_dedicated_server:
		return
	if not is_inside_tree() or get_parent() == null:
		return
	var origin := Vector3(global_position.x, WATER_SURFACE_Y + 0.05, global_position.z)
	var fx := Node3D.new()
	get_parent().add_child(fx)
	fx.global_position = origin
	var p := CPUParticles3D.new()
	p.emitting = true
	p.one_shot = true
	p.explosiveness = 1.0
	p.amount = 36
	p.lifetime = 0.8
	p.direction = Vector3.UP
	p.spread = 55.0
	p.initial_velocity_min = 2.5
	p.initial_velocity_max = 5.0
	p.gravity = Vector3(0, -12.0, 0)
	p.scale_amount_min = 0.5
	p.scale_amount_max = 1.0
	var drop := SphereMesh.new()
	drop.radius = 0.07
	drop.height = 0.14
	var drop_mat := StandardMaterial3D.new()
	drop_mat.albedo_color = Color(0.75, 0.9, 1.0, 0.85)
	drop_mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	drop_mat.emission_enabled = true
	drop_mat.emission = Color(0.5, 0.75, 0.95)
	drop.material = drop_mat
	p.mesh = drop
	fx.add_child(p)
	var ring := MeshInstance3D.new()
	var tm := TorusMesh.new()
	tm.inner_radius = 0.45
	tm.outer_radius = 0.6
	var ring_mat := StandardMaterial3D.new()
	ring_mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	ring_mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	ring_mat.albedo_color = Color(0.85, 0.95, 1.0, 0.7)
	tm.material = ring_mat
	ring.mesh = tm
	ring.scale = Vector3(1.0, 0.1, 1.0)
	fx.add_child(ring)
	var tw := fx.create_tween()
	tw.set_parallel(true)
	tw.tween_property(ring, "scale", Vector3(5.0, 0.1, 5.0), 1.0)
	tw.tween_property(ring_mat, "albedo_color:a", 0.0, 1.0)
	tw.chain().tween_callback(fx.queue_free)

## Highest a rider may climb here: terrain-relative over the grounds, capped
## below the castle interior band.
func _flight_ceiling() -> float:
	var ground := GroundsTerrain.height_at(global_position.x, global_position.z)
	if is_nan(ground):
		return FLIGHT_CEILING_Y
	return minf(ground + FLIGHT_MAX_ABOVE_GROUND, FLIGHT_CEILING_Y)


func _physics_process(delta: float) -> void:
	# World Boundaries & Safeguards: the fall kill-plane sits below the grounds
	# band (the lake bed is -16 m, the water line 0), so swimming never triggers a
	# rescue; only a genuine void fall does.
	if is_local_player and SimAuthority.is_authority() and global_position.y < KILL_PLANE_Y:
		global_position = HPRules.respawn_position()
		velocity = Vector3.ZERO
		current_hp = max_hp
		_spawn_floating_text(tr("The Ancient Ward saved you!"), Color(0.3, 0.8, 1.0), 1.6)
		emit_stats()

	# Black Lake swim state: inside the lake rect and at/below water level.
	# The water surface now has collision, so the body stands on it instead of
	# falling through; buoyancy + drag here make it feel like water, not stone.
	is_swimming = not is_mounted and global_position.y < SWIM_FLOAT_Y + 0.7 \
		and global_position.y > WATER_SURFACE_Y - 3.0 \
		and GroundsLake.is_water_at(global_position.x, global_position.z)
	if is_swimming != _was_swimming:
		_was_swimming = is_swimming
		_spawn_water_splash()

	# Update decoupled camera pivot position & rotation smoothly
	if is_local_player and is_instance_valid(camera_pivot):
		camera_pivot.global_position = camera_pivot.global_position.lerp(global_position + Vector3(0, CAMERA_HEIGHT, 0), 1.0 - exp(-20.0 * delta))
		camera_pivot.rotation_degrees.y = camera_rot_y
		if spring_arm:
			spring_arm.rotation_degrees.x = camera_rot_x
			_update_boom(delta)

	if not is_local_player:
		# Another player's body. On a client it is a view that follows the
		# replicated state; on the authority it is the REAL body, simulated here
		# from the input that player sent, so it falls through to the movement
		# code below like any other body.
		if sim_puppet:
			var prev_pos := global_position
			if sim_motion.has_samples():
				var drawn := sim_motion.sample()
				global_position = drawn.pos
				if visuals:
					visuals.rotation.y = float(drawn.rot)
				if sim_motion.snapped:
					sim_motion.snapped = false
					prev_pos = global_position   # a teleport is not a sprint
			else:
				global_position = global_position.lerp(sim_target_pos, minf(1.0, 12.0 * delta))
				if visuals:
					visuals.rotation.y = lerp_angle(visuals.rotation.y, sim_target_rot, minf(1.0, 12.0 * delta))
			# Remote riders follow the replicated phase, not a local guess, so
			# every client shows the same animation phase for the same body.
			if is_mounted and sim_mount_phase > 0:
				if hero_anim:
					hero_anim.set_locomotion("mount%d" % sim_mount_phase, clip_for_mount_phase(sim_mount_phase))
			elif hero_anim:
				if is_dead:
					hero_anim.set_locomotion("dead", "Death_A")
				elif pose_override == "":
					var motion := (global_position - prev_pos) / maxf(delta, 0.001)
					_update_ground_animation(motion, visuals.rotation.y)
			return
	
	if is_dead:
		velocity = Vector3.ZERO
		return
	var grounded_now := is_on_floor() or is_mounted or is_swimming
	_was_airborne = _air_time > LAND_MIN_AIR and grounded_now
	if grounded_now:
		if _air_time > 0.0:
			_last_air_time = _air_time
		_air_time = 0.0
	else:
		_air_time += delta
	_steep_time = maxf(0.0, _steep_time - delta)
	var on_steep := _steep_time > 0.0 and not is_on_floor() and not is_mounted and not is_swimming
	# Gravity, swimming & mounting. Swimming overrides gravity with buoyancy:
	# the body floats toward SWIM_FLOAT_Y and paddles with jump, never sinks to
	# the lakebed.
	if is_swimming:
		var float_target := SWIM_FLOAT_Y
		if not input_blocked() and _intent_jump():
			float_target += 0.6
		velocity.y = move_toward(velocity.y, (float_target - global_position.y) * 4.0, gravity * 0.6 * delta)
		velocity.y = clampf(velocity.y, -3.0, 3.0)
	elif not is_on_floor() and not is_mounted:
		velocity.y -= gravity * delta
		# Coyote time / press buffer (see _jump_ready): airborne frames must see
		# the press too.
		if not input_blocked() and _jump_ready(delta):
			velocity.y = 8.0
	elif is_mounted:
		var vertical := 0.0
		if not input_blocked():
			vertical = float(_intent_jump()) - float(_intent_descend())
		var ground := _ground_below(3.0)
		if not ground.is_empty() and vertical >= 0:
			# Proportional hover instead of an on/off kick at 1.4 m: the on/off
			# version bobbed the rider every time the probe crossed the threshold
			# (or a branch below it), which read as jitter after stopping.
			var clearance: float = global_position.y - float(ground.position.y)
			vertical = maxf(vertical, clampf((1.45 - clearance) * 1.6, 0.0, 0.5))
		if global_position.y > _flight_ceiling():
			vertical = minf(vertical, -0.5)
		velocity.y = move_toward(velocity.y, vertical * 7.0, delta * 18.0)
	elif not input_blocked() and _jump_ready(delta) and not is_swimming:
		velocity.y = 8.0

	# Input direction relative to camera yaw
	var input_dir := _intent_move()

	# Item Movement Speed (boots, cloak penalty, efsun) applies on foot only.
	var walk := walk_speed * (1.0 + float(derived_stats.get("move_speed", 0.0)) / 100.0)
	# Webbed by a cavern spider (authority apply_web): the server body and the
	# owner's prediction both read the tick from the record (stats payload).
	if int(SimAuthority.record_for(self).get("webbed_until_tick", 0)) > SimAuthority.sim_tick:
		walk *= WEBBED_FACTOR
	var active_speed := mounted_speed if is_mounted else (swim_speed if is_swimming else walk)
	var is_moving := input_dir.length_squared() > 0.01

	if is_moving:
		# Calculate movement vector relative to camera yaw
		var cam_yaw: float = deg_to_rad(_intent_yaw())
		var forward := Vector3(-sin(cam_yaw), 0, -cos(cam_yaw))
		var right := Vector3(cos(cam_yaw), 0, -sin(cam_yaw))
		var move_vector := (right * input_dir.x + forward * -input_dir.y).normalized()

		var acceleration := 25.0 if is_mounted else (18.0 if is_swimming else 65.0)
		velocity.x = move_toward(velocity.x, move_vector.x * active_speed, acceleration * delta)
		velocity.z = move_toward(velocity.z, move_vector.z * active_speed, acceleration * delta)

		# Rotate ONLY visuals towards move direction (Camera remains independent!)
		var target_yaw := atan2(move_vector.x, move_vector.z)
		if _cast_lock <= 0.0:
			# The body is turning to `target_yaw`, and that - not the interpolated
			# facing it has not reached yet - is what the animation state is chosen
			# against. Classifying on the lagging yaw made the first ~0.1 s of every
			# direction change play Walk_Back or a strafe (measured: 1 frame of
			# Walk_Back and 5 of Strafe_R before Running_A on a forward press).
			_facing_target_yaw = target_yaw
			_auto_facing = true
			visuals.rotation.y = lerp_angle(visuals.rotation.y, target_yaw, minf(1, 14.0 * delta))

	else:
		if is_mounted or not is_on_floor():
			# Airborne and flying keep the authored deceleration: the broom is
			# supposed to coast and cutting its momentum mid-air would look wrong.
			velocity.x = move_toward(velocity.x, 0, active_speed * 12.0 * delta)
			velocity.z = move_toward(velocity.z, 0, active_speed * 12.0 * delta)
		else:
			velocity.x = move_toward(velocity.x, 0, GROUND_STOP_DECEL * delta)
			velocity.z = move_toward(velocity.z, 0, GROUND_STOP_DECEL * delta)
		# Orbiting the camera (right mouse held) never turns a standing body: the
		# view swings around the character, who keeps facing where they were.

	if on_steep:
		_apply_steep_slide(delta)
	else:
		_slide_speed = 0.0
	_step_up()
	var shoved := _shove != Vector3.ZERO
	if shoved:
		velocity.x += _shove.x
		velocity.z += _shove.z
	move_and_slide()
	if shoved:
		velocity.x -= _shove.x
		velocity.z -= _shove.z
		_shove = _shove.move_toward(Vector3.ZERO, SHOVE_DECAY * delta)
	_record_steep_contact()
	if is_local_player and not sim_server_controlled:
		var planar_speed := Vector2(velocity.x, velocity.z).length()
		if planar_speed < 0.25 and _intent_move().length_squared() < 0.01:
			_standing_time += delta
		else:
			_standing_time = 0.0
	if is_local_player:
		_pos_history.record(global_position)
	_update_animation_state()

const BOOM_PROBE_RADIUS := 0.22
## Resolve the camera boom against the world with a sphere cast, then ease the
## length: in fast (never let the camera sit inside a wall) and out slowly (a
## branch passing the boom no longer yanks the camera back and forth).
func _update_boom(delta: float) -> void:
	var wanted := camera_distance
	var space := get_world_3d().direct_space_state
	if space != null:
		var origin := camera_pivot.global_position
		var back := spring_arm.global_basis.z.normalized()
		var shape := SphereShape3D.new()
		shape.radius = BOOM_PROBE_RADIUS
		var params := PhysicsShapeQueryParameters3D.new()
		params.shape = shape
		params.transform = Transform3D(Basis.IDENTITY, origin)
		params.motion = back * camera_distance
		params.collision_mask = 1
		params.exclude = [get_rid()]
		var fractions := space.cast_motion(params)
		if fractions.size() == 2 and fractions[0] < 1.0:
			wanted = maxf(1.2, camera_distance * fractions[0] - 0.1)
	var rate := 18.0 if wanted < _boom_length else 3.5
	_boom_length = lerpf(_boom_length, wanted, 1.0 - exp(-rate * delta))
	spring_arm.spring_length = _boom_length

## Walk up a ledge instead of stopping dead against it. The body is pushed
## forward by its intent, so a tread, a doorstep, the shoreline shelf or the
## boathouse sill is a wall `move_and_slide` can never pass. When the way ahead
## is blocked at foot height, clear one step up, and there is ground to land on,
## the body takes the step. The server runs this same body, so prediction and
## authority take it together.
func _step_up() -> void:
	if not is_local_player and not sim_server_controlled:
		return
	if not is_on_floor() or is_mounted or is_swimming or is_dead:
		return
	var planar := Vector3(velocity.x, 0.0, velocity.z)
	var speed := planar.length()
	if speed < STEP_UP_MIN_SPEED:
		return
	var motion := planar / speed * STEP_UP_PROBE
	var probe := global_transform
	var blocker := KinematicCollision3D.new()
	if not test_move(probe, motion, blocker):
		return
	# Ground rising ahead (a slope) is not a ledge: floor snapping walks it, and
	# a slope too steep to walk must stay unclimbable.
	if blocker.get_normal().y > STEP_WALL_MAX_NORMAL_Y:
		return
	if test_move(probe.translated(Vector3(0.0, STEP_UP_HEIGHT, 0.0)), motion):
		return
	# Is there a surface to land on, one step up and one probe ahead?
	var landing := probe.translated(Vector3(0.0, STEP_UP_HEIGHT, 0.0)).translated(motion)
	var space := get_world_3d().direct_space_state
	var query := PhysicsRayQueryParameters3D.create(
		landing.origin + Vector3(0.0, 0.05, 0.0),
		landing.origin - Vector3(0.0, STEP_UP_HEIGHT + 0.3, 0.0),
		collision_mask)
	query.exclude = [get_rid()]
	var hit := space.intersect_ray(query)
	if hit.is_empty():
		return
	var rise: float = float(hit["position"].y) - global_position.y
	if rise <= 0.03 or rise > STEP_UP_HEIGHT:
		return
	# Only land on walkable ground.
	if (hit["normal"] as Vector3).y < cos(floor_max_angle):
		return
	# Take the step; the next slide crosses onto the ledge and gravity settles.
	global_position.y += rise + 0.02

## The state machine half of the animation graph: it selects the clip, the graph
## blends it. States are named so a test can assert which one is active.
func _update_animation_state() -> void:
	if hero_anim == null:
		return
	if is_dead:
		hero_anim.set_locomotion("dead", "Death_A")
		return
	if pose_override != "":
		return   # the reach-down / held one-shot owns the body
	if _hit_recovery > 0.0:
		hero_anim.set_locomotion("stun", "Stun_Loop")
		return
	if is_mounted:
		var phase := sim_mount_phase if sim_puppet else mount_phase()
		hero_anim.set_locomotion("mount%d" % phase, clip_for_mount_phase(phase))
		return
	if is_swimming:
		var hspeed := Vector2(velocity.x, velocity.z).length()
		if hspeed < 0.5:
			hero_anim.set_locomotion("swim_idle", "Idle")
		else:
			hero_anim.set_locomotion("swim", "Running_A")
		return
	if _is_airborne_for_animation():
		if velocity.y > 0.5:
			hero_anim.set_locomotion("air_up", "Jump_Start")
		else:
			hero_anim.set_locomotion("air_down", "Fall")
		return
	if _was_airborne:
		_was_airborne = false
		hero_anim.play_oneshot("Land")
	# Classify against the facing the body is heading FOR while it auto-faces its
	# movement (reaching it takes several frames at 14 rad/s), and against the real
	# facing when something else owns it - the camera during a right-click orbit, or
	# replication on a puppet. Using the lagging facing made a forward press start
	# with Walk_Back/Strafe_R frames.
	var yaw := _facing_target_yaw if _auto_facing else visuals.rotation.y
	_update_ground_animation(velocity, yaw)

## Airborne for the animation graph: a real jump or fall, never the frame a
## terrain crease or a slope change lifts the feet, and never a slide down a
## too-steep bank (that keeps the ground pose while the body slides).
func _is_airborne_for_animation() -> bool:
	if is_on_floor():
		return false
	if _steep_time > 0.0:
		return false
	if velocity.y > 1.0:
		return true
	if _air_time < AIR_GRACE:
		return false
	# Ground just under the feet: a step down or a slope edge, not a fall.
	var below := _ground_below(0.55)
	return below.is_empty()

## Too-steep ground under the body: no walking into it, and a smooth slide down
## its fall line that builds speed instead of the stutter of gravity, collision
## and snap fighting each frame.
func _apply_steep_slide(delta: float) -> void:
	var n := _steep_normal
	var across := Vector3(n.x, 0.0, n.z)
	if across.length_squared() < 0.0001:
		return
	across = across.normalized()   # points downhill, away from the bank
	var planar := Vector3(velocity.x, 0.0, velocity.z)
	var into := planar.dot(across)
	if into < 0.0:
		planar -= across * into     # cannot push uphill into the bank
	var downhill := (Vector3.DOWN - n * n.dot(Vector3.DOWN)).normalized()
	_slide_speed = minf(STEEP_SLIDE_MAX, _slide_speed + STEEP_SLIDE_ACCEL * delta)
	velocity = planar + downhill * _slide_speed

## Remember a too-steep contact from the last slide so the next frame can slide
## down it. Floors and walls are ignored: only ground that is too steep to stand.
func _record_steep_contact() -> void:
	if is_on_floor() or is_mounted or is_swimming:
		return
	var min_y := cos(floor_max_angle)
	for i in range(get_slide_collision_count()):
		var normal := get_slide_collision(i).get_normal()
		if normal.y > 0.2 and normal.y < min_y:
			_steep_normal = normal
			_steep_time = 0.15
			return
	# Sliding parallel to the bank often reports no contact for a frame; the
	# ground is still right under the feet, so keep the slide alive.
	if _steep_time > 0.0:
		var below := _ground_below(1.1)
		if not below.is_empty():
			var n: Vector3 = below.normal
			if n.y > 0.2 and n.y < min_y:
				_steep_normal = n
				_steep_time = 0.15

func _update_ground_animation(motion: Vector3, yaw: float) -> void:
	var forward := Vector3(sin(yaw), 0, cos(yaw))
	var left := Vector3(cos(yaw), 0, -sin(yaw))
	hero_anim.set_ground_motion(Vector2(motion.dot(left), motion.dot(forward)))

func _on_animation_event(event_name: String) -> void:
	animation_events.append(event_name)
	if animation_events.size() > 32:
		animation_events.pop_front()
	emit_signal("animation_event", event_name)

## ---------------------------------------------------------------
## Movement intent. A locally controlled body reads the keyboard; a body the
## authority simulates (the server's copy of a connected player) reads the
## intent that player's client sent. The same movement code runs in both cases.
## ---------------------------------------------------------------

func _intent_move() -> Vector2:
	if _committed_until > 0.0:
		# A committed attack roots the caster: intent is zero, not merely slow.
		return Vector2.ZERO
	if sim_server_controlled:
		return HPRules.sanitize_input_vector(sim_input.get("move", Vector2.ZERO))
	if SimNet.is_client and not SimNet.forced_intent.is_empty():
		# Headless probe: the intent it sends is the intent it predicts with.
		return HPRules.sanitize_input_vector(SimNet.forced_intent.get("move", Vector2.ZERO))
	if input_blocked() or pose_override == "floo":
		return Vector2.ZERO
	var input_dir := Vector2.ZERO
	if Input.is_action_pressed("move_forward"):
		input_dir.y -= 1
	if Input.is_action_pressed("move_backward"):
		input_dir.y += 1
	if Input.is_action_pressed("move_left"):
		input_dir.x -= 1
	if Input.is_action_pressed("move_right"):
		input_dir.x += 1
	return input_dir.normalized()

func _intent_yaw() -> float:
	if sim_server_controlled:
		return float(sim_input.get("yaw", 0.0))
	if SimNet.is_client and not SimNet.forced_intent.is_empty():
		return float(SimNet.forced_intent.get("yaw", camera_rot_y))
	return camera_rot_y

func _intent_jump() -> bool:
	if sim_server_controlled:
		return bool(sim_input.get("jump", false))
	return not input_blocked() and Input.is_action_pressed("jump")

func _intent_descend() -> bool:
	if sim_server_controlled:
		return bool(sim_input.get("descend", false))
	return not input_blocked() and Input.is_action_pressed("flight_descend")

var _prev_jump := false
## Seconds a jump press stays wanted (JUMP_BUFFER) - see _jump_ready.
var _jump_buffer := 0.0
## Input sends the jump bit still rides on after a press (see sim_input_intent).
var _jump_sends_left := 0
## A press is remembered this long, so a press a moment before touching down
## still jumps.
const JUMP_BUFFER := 0.2
## Just off the ground (a bump on a slope, a step down) still counts as ground.
const JUMP_COYOTE := 0.15

func _intent_jump_edge() -> bool:
	var jump := _intent_jump()
	var edge := jump and not _prev_jump
	_prev_jump = jump
	return edge

## Jump with a press buffer and coyote time. The client and the server run this
## same body, but the server sees the press up to an input tick later and its
## body bounces down a slope on its own frames: an edge that had to meet
## is_on_floor() in the very same frame jumped on one side and not the other,
## and the correction then dragged the player back down the slope.
func _jump_ready(delta: float) -> bool:
	if _intent_jump_edge():
		_jump_buffer = JUMP_BUFFER
		if is_local_player and not sim_server_controlled:
			_jump_sends_left = 2
	else:
		_jump_buffer = maxf(0.0, _jump_buffer - delta)
	if _jump_buffer <= 0.0 or velocity.y > 1.0:
		return false
	if not is_on_floor() and _air_time > JUMP_COYOTE:
		return false
	_jump_buffer = 0.0
	return true

## The intent this client is sending upstream (SimNet calls this each input tick).
func sim_input_intent() -> Dictionary:
	return {
		"move": _intent_move(),
		"yaw": camera_rot_y,
		"jump": _jump_bit(),
		"descend": Input.is_action_pressed("flight_descend") and not input_blocked(),
	}

## The jump bit of the next input send. Inputs travel unreliably at 20 Hz, so a
## tap between two sends, or one lost packet, used to lose the jump on the
## server while this client had already jumped. A press now rides on the next
## two sends (the server reacts to its rising edge only once).
func _jump_bit() -> bool:
	if input_blocked():
		return false
	var held := Input.is_action_pressed("jump")
	if _jump_sends_left > 0:
		_jump_sends_left -= 1
		return true
	return held

func _handle_hotkeys() -> void:
	# The keys cast whatever the player put on that bar slot (HudActionBar).
	for i in HudActionBar.SPELL_ACTIONS.size():
		if Input.is_action_just_pressed(HudActionBar.SPELL_ACTIONS[i]):
			cast_spell(HudActionBar.spell_at(i))
			return
	if Input.is_action_just_pressed("mount_broom"):
		toggle_broom_mount()
	elif Input.is_action_just_pressed("target_cycle"):
		cycle_nearest_target()
	elif Input.is_action_just_pressed("pickup_loot"):
		pickup_nearest_loot()

func toggle_broom_mount() -> void:
	if is_dead or _cast_lock > 0 or _mount_lock > 0:
		return
	if is_mounted:
		var dismount_reason := dismount_block_reason()
		if dismount_reason != "":
			if _mount_notice_cd <= 0.0:
				_mount_notice_cd = 0.8
				show_notice(dismount_reason)
				var audio := get_node_or_null("/root/AudioManager")
				if is_local_player and audio != null and audio.has_method("play_landing_blocked"):
					audio.call("play_landing_blocked")
			return
		_apply_mount_state(false)
	else:
		var mount_reason := mount_block_reason()
		if mount_reason != "":
			if _mount_notice_cd <= 0.0:
				_mount_notice_cd = 0.8
				show_notice(mount_reason)
			return
		_apply_mount_state(true)
		velocity.y = 3.0
	_basic_held = false
	_mount_lock = 0.3
	# Predicted locally for responsiveness (the clearance tests above are the
	# part a client can check for itself); the authority validates the same
	# request and its state wins on the next snapshot/stat event.
	SimNet.submit_mount(self, is_mounted)

## Why a mount request is refused, in player-facing words. Empty means allowed.
## Every rule here is mirrored by `SimAuthority.submit_mount`, which is the
## decider; this is the feedback path so a refusal is explainable.
func mount_block_reason() -> String:
	if is_dead:
		return tr("You are defeated!")
	if not equipment.has("broom"):
		return tr("You have no mount - equip a broom first.")
	if _hit_recovery > 0.0:
		return tr("You are stunned!")
	if _combat_until > 0.0:
		return tr("Not while in combat!")
	var record := SimAuthority.record_for(self)
	if not record.is_empty() and int(record.get("pending_transfer", 0)) != 0:
		return tr("The map is still loading!")
	if not is_on_floor():
		return tr("Take off from the ground!")
	var ground := _ground_below(1.2)
	if ground.is_empty() or ground.normal.dot(Vector3.UP) <= 0.7:
		return tr("The ground is too unstable to take off!")
	if not _flight_clearance_ok():
		return tr("Not enough room to take off here!")
	if not HPMaps.flight_allowed(current_map_id()):
		return tr("Flight is not allowed on this map!")
	return ""

## The map this body is on. The authority owns the field; the client reads it.
func current_map_id() -> String:
	var record := SimAuthority.record_for(self)
	if not record.is_empty() and record.has("map_id"):
		return String(record["map_id"])
	return HPProtocol.DEFAULT_MAP

## Landing checks, in the order the plan lists them: ground normal, capsule
## clearance, ceiling height and a safe dismount position.
func dismount_block_reason() -> String:
	var ground := _ground_below(3.0)
	if ground.is_empty() or ground.normal.dot(Vector3.UP) <= 0.7:
		return tr("Descend near level ground first (Ctrl)")
	var landing: Vector3 = ground.position
	var standing := _capsule_clear(landing + Vector3.UP * (CAPSULE_HEIGHT * 0.5 + 0.06))
	if not standing:
		return tr("No room to stand up here!")
	if not _ceiling_clear(landing, DISMOUNT_CEILING):
		return tr("The ceiling is too low to dismount!")
	return ""

func can_dismount_safely() -> bool:
	return dismount_block_reason() == ""

func _capsule_clear(at: Vector3) -> bool:
	var shape := CapsuleShape3D.new()
	shape.radius = CAPSULE_RADIUS
	shape.height = CAPSULE_HEIGHT
	var query := PhysicsShapeQueryParameters3D.new()
	query.shape = shape
	query.transform = Transform3D(Basis(), at)
	query.collision_mask = 1
	query.exclude = [get_rid()]
	return get_world_3d().direct_space_state.intersect_shape(query, 1).is_empty()

func _ceiling_clear(from: Vector3, height: float) -> bool:
	var query := PhysicsRayQueryParameters3D.create(from + Vector3.UP * 0.1, from + Vector3.UP * height, 1)
	query.exclude = [get_rid()]
	return get_world_3d().direct_space_state.intersect_ray(query).is_empty()

## Room for the broom itself: headroom above the crown plus the shaft's length
## swept at saddle height. Rejecting here is what stops a take-off inside a
## corridor from poking the broom through a wall.
func _flight_clearance_ok() -> bool:
	if not _ceiling_clear(global_position, HERO_CROWN_HEIGHT + MOUNT_CLEAR_HEIGHT):
		return false
	var yaw := visuals.rotation.y if visuals else rotation.y
	var basis := Basis(Vector3.UP, yaw)
	var shape := BoxShape3D.new()
	shape.size = Vector3(MOUNT_LATERAL_WIDTH, 0.5, MOUNT_LATERAL_LENGTH)
	var query := PhysicsShapeQueryParameters3D.new()
	query.shape = shape
	query.transform = Transform3D(basis, global_position + Vector3.UP * 0.95)
	query.collision_mask = 1
	query.exclude = [get_rid()]
	return get_world_3d().direct_space_state.intersect_shape(query, 1).is_empty()

func _apply_mount_state(mounted: bool) -> void:
	is_mounted = mounted
	mount_state = MountState.MOUNTING if mounted else MountState.LANDING
	if broom_particles:
		broom_particles.emitting = mounted
	if broom:
		broom.set_flying(mounted)
	_align_broom_to_hips()
	if mounted:
		add_buff("broom", 0.0, "broom_nimbus2000", "Broom Flight", "Space rises · Ctrl descends · Shift dismounts on level ground.")  # i18n
	else:
		remove_buff("broom")
	if mounted:
		if hero_anim:
			hero_anim.play_oneshot("Mount_Broom")
		mount_state = MountState.FLYING
	else:
		if hero_anim:
			hero_anim.play_oneshot("Dismount_Broom")
	emit_signal("mounted_changed", is_mounted)

## Presentation phase for this rider; the authority replicates it so remote
## clients animate the same phase (HPProtocol.MountPhase).
func mount_phase() -> int:
	if not is_mounted:
		return HPProtocol.MountPhase.NONE
	var lateral := 0.0
	if is_local_player and not input_blocked():
		lateral = Input.get_axis("move_right", "move_left")
	elif sim_server_controlled:
		lateral = float(sim_input.get("move", Vector2.ZERO).x)
	var vertical := 0.0
	if _intent_jump():
		vertical += 1.0
	if _intent_descend():
		vertical -= 1.0
	var speed_ratio := Vector2(velocity.x, velocity.z).length() / maxf(0.1, mounted_speed)
	return HPProtocol.mount_phase_for(true, -lateral, vertical, speed_ratio, 0.0)

## Mount clip for a given replicated phase (used by remote puppets).
static func clip_for_mount_phase(phase: int) -> String:
	match phase:
		HPProtocol.MountPhase.CLIMB:
			return "Broom_Climb"
		HPProtocol.MountPhase.DIVE:
			return "Broom_Dive"
		HPProtocol.MountPhase.BANK_L:
			return "Broom_Bank_L"
		HPProtocol.MountPhase.BANK_R:
			return "Broom_Bank_R"
		HPProtocol.MountPhase.BRAKE:
			return "Broom_Brake"
		HPProtocol.MountPhase.ACCELERATE:
			return "Broom_Accelerate"
		HPProtocol.MountPhase.CRUISE:
			return "Broom_Cruise"
		HPProtocol.MountPhase.TAKEOFF:
			return "Broom_Takeoff"
		HPProtocol.MountPhase.MOUNTING:
			return "Mount_Broom"
		HPProtocol.MountPhase.LANDING:
			return "Broom_Land"
		HPProtocol.MountPhase.DISMOUNT:
			return "Dismount_Broom"
		_:
			return "Broom_Seated_Idle"

func _ground_below(distance: float) -> Dictionary:
	var query := PhysicsRayQueryParameters3D.create(global_position + Vector3.UP * 0.1, global_position - Vector3.UP * distance, 1)
	return get_world_3d().direct_space_state.intersect_ray(query)

func input_blocked() -> bool:
	var focus := get_viewport().gui_get_focus_owner()
	if focus is LineEdit or focus is TextEdit:
		return true
	# Interface hook: any open panel that takes keyboard focus registers itself in
	# `UIFocus.GROUP` (client/scripts/ui/ui_focus.gd), so keys typed in a menu
	# cannot also cast a spell or mount the broom. Mouse clicks are consumed by
	# the Controls themselves before `_unhandled_input` ever sees them.
	if UIFocus.is_blocking(get_tree()):
		return true
	# Game windows (bag, Ollivander, V, B, M) are deliberately NOT listed: they
	# are non-modal side windows - only the card itself consumes clicks, and a
	# player rummaging while walking is the intended behaviour.
	return false

func _tick_regeneration(delta: float) -> void:
	var before := Vector2i(current_hp, current_mana)
	# Base rates plus enchanted regeneration (derived from the worn bonuses).
	_regen_hp += (4.0 + float(derived_stats.get("hp_regen", 0.0))) * delta
	_regen_mana += ((10.0 if house == "Slytherin" else 8.0) + float(derived_stats.get("mana_regen", 0.0))) * delta
	current_hp = mini(max_hp, current_hp + int(_regen_hp))
	current_mana = mini(max_mana, current_mana + int(_regen_mana))
	_regen_hp -= floorf(_regen_hp)
	_regen_mana -= floorf(_regen_mana)
	if before != Vector2i(current_hp, current_mana):
		emit_stats()

var _wand_grip_cache: Node = null
var _wand_node_cache: Node3D = null

func _update_flight_pose(delta: float) -> void:
	_flight_time += delta
	_mount_blend = move_toward(_mount_blend, 1.0 if is_mounted else 0.0, delta * 3.2)
	if broom_grip:
		# Fades in with the mount, and yields while a get-on/get-off one-shot plays
		# so the transition keeps the clip's own arms.
		var grip_target := _mount_blend
		if hero_anim and hero_anim.has_oneshot():
			grip_target = 0.0
		broom_grip.target_weight = grip_target
	# Two recursive tree searches per body per frame were most of this
	# function: keep the nodes until they leave the tree (a re-equip rebuilds
	# the wand holder, show_equipped_wand).
	if not is_instance_valid(_wand_grip_cache) or not _wand_grip_cache.is_inside_tree():
		_wand_grip_cache = visuals.find_child("WandGripModifier", true, false)
	if not is_instance_valid(_wand_node_cache) or not _wand_node_cache.is_inside_tree():
		_wand_node_cache = visuals.find_child("EquippedWand", true, false) as Node3D
	var wand_grip = _wand_grip_cache
	var wand_node := _wand_node_cache
	if wand_grip:
		wand_grip.target_weight = (1.0 - _mount_blend) if wand_node != null else 0.0
	if wand_node:
		wand_node.visible = _mount_blend < 0.5
	if broom_mesh:
		broom_mesh.visible = _mount_blend > 0.01

	if broom:
		broom.set_flying(is_mounted)
		broom.tick(delta)
		if broom_mesh.visible:
			_align_broom_to_hips()
	# The rider sits on the saddle: lift the visuals by the seat height instead of
	# the old 0.15 m placeholder, so the boots clear the ground while hovering.
	visuals.position.y = _mount_blend * (0.34 + sin(_flight_time * 3.0) * 0.05) + _emerge_lift
	var speed_ratio := Vector2(velocity.x, velocity.z).length() / mounted_speed
	visuals.rotation.x = lerpf(visuals.rotation.x, -0.2 * speed_ratio * _mount_blend, minf(1, delta * 5))
	var turn := 0.0 if not is_local_player or input_blocked() else Input.get_axis("move_right", "move_left")
	# Rider lean is blended with acceleration and banking; the camera roll is a
	# restrained, configurable fraction of the same bank.
	var bank_target := turn * 0.22 * _mount_blend
	visuals.rotation.z = lerpf(visuals.rotation.z, bank_target, minf(1, delta * 5))
	_rider_roll = lerpf(_rider_roll, bank_target, minf(1, delta * 4))
	var roll_deg := clampf(rad_to_deg(_rider_roll), -camera_roll_limit, camera_roll_limit)
	if camera_pivot:
		camera_pivot.rotation_degrees.z = lerpf(camera_pivot.rotation_degrees.z, roll_deg, minf(1, delta * 3))

func restore_character(data: Dictionary) -> void:
	_character_restored = true
	level = clampi(int(data.get("level", 1)), 1, 100)
	max_exp = HPRules.exp_threshold(level)
	current_exp = clampi(int(data.get("exp", 0)), 0, max_exp - 1)
	max_hp = maxi(1, int(data.get("max_hp", max_hp)))
	max_mana = maxi(1, int(data.get("max_mana", max_mana)))
	current_hp = clampi(int(data.get("current_hp", max_hp)), 1, max_hp)
	current_mana = clampi(int(data.get("current_mana", max_mana)), 0, max_mana)
	galleons = maxi(0, int(data.get("galleons", 500)))
	wand_tier = clampi(int(data.get("wand_tier", 0)), 0, 9)
	# JSON arrays are untyped. Copy validated entries into the typed inventory.
	if data.get("inventory") is Array:
		inventory.clear()
		for entry in data.inventory:
			# Retired/unknown catalog entries are still owned. Preserve them across
			# load/save; the equipment catalog decides whether they can be equipped.
			if entry is Dictionary and entry.get("id") is String and not String(entry.id).is_empty() and typeof(entry.get("amount")) in [TYPE_INT,TYPE_FLOAT] and int(entry.amount) > 0:
				var kept := {"id": entry.id, "amount": maxi(1, int(entry.get("amount", 1))), "tier": clampi(int(entry.get("tier", 0)), 0, 9)}
				if int(entry.get("uid", 0)) > 0:
					kept["uid"] = int(entry.uid)
					kept["bonuses"] = (entry.get("bonuses", []) as Array).duplicate(true)
				inventory.append(kept)
	base_max_hp = int(data.get("base_max_hp", max_hp))
	# Characters levelled before level_hp_gain rose (40 -> 45) catch up once.
	if data.has("level"):
		base_max_hp = maxi(base_max_hp, HPRules.base_max_hp(house) + (maxi(1, int(data.level)) - 1) * int(HPRules.combat().get("base_stats", {}).get("level_hp_gain", 40)))
	base_max_mana = int(data.get("base_max_mana", max_mana))
	equipment_version = int(data.get("equipment_version", 0))
	equipment = (data.get("equipment", {}) as Dictionary).duplicate(true)
	inventory_revision = int(data.get("inventory_revision", 0))
	restore_quest_state(data.get("quests", {}))
	_initialize_equipment()
	# Sheets saved before item instances (or legacy offline saves) carry stacked
	# wands and uid-less gear; the next save persists the normalized form. Only
	# the authority mints uids - a client adopts them from the stats snapshot.
	if SimAuthority.is_authority() and HPEquipment.normalize(inventory, equipment):
		inventory_revision += 1
	_apply_wand_aura()
	_update_nameplate()
	inventory_changed.emit()
	emit_stats()

## The saved `quests` object (character sheet or offline save) -> house
## standing, the quest log, learned skills and status points.
func restore_quest_state(quests: Variant) -> void:
	_quest_state = (quests as Dictionary).duplicate(true) if quests is Dictionary else {}
	house_rep = HPRules.clamp_house_rep(int(_quest_state.get("house_rep", 0)))
	_shown_house_rep = house_rep
	quest_done = []
	if _quest_state.get("done") is Array:
		for id in _quest_state["done"]:
			if id is String:
				quest_done.append(id)
	quest_ready = []
	if _quest_state.get("ready") is Array:
		for id in _quest_state["ready"]:
			if id is String and not HPRules.quest_by_id(id).is_empty() and not quest_done.has(id):
				quest_ready.append(id)
	# Saves from the linear chain kept one integer here; the log keeps a count
	# per open quest.
	quest_progress = {}
	if _quest_state.get("progress") is Dictionary:
		for id in _quest_state["progress"]:
			if not HPRules.quest_by_id(String(id)).is_empty():
				quest_progress[String(id)] = maxi(0, int(_quest_state["progress"][id]))
	skill_levels = HPRules.clean_skill_levels(_quest_state.get("skills", {}))
	skill_bonus = maxi(0, int(_quest_state.get("skill_bonus", 0)))
	if not bool(_quest_state.get("skills_v2", false)):
		# Before skills had to be learned every spell was level 1 for free. A
		# character that has played keeps all six and every point it had
		# (bonus = six free levels minus the one its first level pays); a brand
		# new one (level 1, nothing done) picks its first spell.
		if level > 1 or not quest_done.is_empty() or not skill_levels.is_empty():
			for spell_id in HPRules.upgradeable_skills():
				skill_levels[spell_id] = maxi(1, int(skill_levels.get(spell_id, 1)))
			skill_bonus = HPRules.upgradeable_skills().size() - 1
		_quest_state["skills_v2"] = true
	attributes = HPRules.clean_attributes(_quest_state.get("attributes", {}))
	titles = (_quest_state.get("titles", []) as Array).duplicate() if _quest_state.get("titles") is Array else []
	skill_points = HPRules.skill_points_available(level, skill_levels, skill_bonus)
	attribute_points = HPRules.attribute_points_available(level, attributes)

## True once the saved object carries quest state (used to import the
## pre-authority local quest file exactly once).
func has_quest_progress() -> bool:
	return _quest_state.has("active") or _quest_state.has("done")

## What the save writes into the character's `quests` column.
func persisted_quests() -> Dictionary:
	var out := _quest_state.duplicate(true)
	out.erase("active")
	out["house_rep"] = house_rep
	out["progress"] = quest_progress.duplicate()
	out["ready"] = quest_ready.duplicate()
	out["done"] = quest_done.duplicate()
	out["skills"] = skill_levels.duplicate()
	out["skill_bonus"] = skill_bonus
	out["skills_v2"] = true
	out["attributes"] = attributes.duplicate()
	out["titles"] = titles.duplicate()
	return out

## Dungeon runs started today (`quests.dungeons`, authority-written).
func dungeon_entries_on(dungeon_id: String, day: String) -> int:
	var entry: Dictionary = (_quest_state.get("dungeons", {}) as Dictionary).get(dungeon_id, {})
	return int(entry.get("entries", 0)) if String(entry.get("day", "")) == day else 0

func record_dungeon_entry(dungeon_id: String, day: String) -> void:
	var all: Dictionary = _quest_state.get("dungeons", {})
	all[dungeon_id] = {"day": day, "entries": dungeon_entries_on(dungeon_id, day) + 1}
	_quest_state["dungeons"] = all

## A shove from the authority (its own copy and, via sim_push, the owner's
## prediction): horizontal as a fading extra velocity, vertical as a hop.
func apply_knockback(force: Vector3) -> void:
	if is_dead or is_mounted:
		return
	_shove += Vector3(force.x, 0.0, force.z)
	if force.y > 0.0:
		velocity.y = maxf(velocity.y, force.y)

## The Floo fireplaces this character can travel to (`quests.floo_known`,
## authority-written; travel.json `known_by_default` are always known).
func floo_known() -> Array:
	var known: Array = (HPMaps.floo_rules().get("known_by_default", []) as Array).duplicate()
	for id in _quest_state.get("floo_known", []):
		if not known.has(id):
			known.append(id)
	return known

## Learn a fireplace; true when it is new (the authority persists it).
func learn_floo(node_id: String) -> bool:
	if HPMaps.travel_node(node_id).is_empty() or floo_known().has(node_id):
		return false
	var mine: Array = (_quest_state.get("floo_known", []) as Array).duplicate()
	mine.append(node_id)
	_quest_state["floo_known"] = mine
	return true

## ------------------------------------------------------------- Portkey pose

## A whole-body pose that replaces locomotion while set (the Portkey kneel).
## Set on every client that sees the Portkey (its owner and party), so the
## holders kneel on each of their screens.
var pose_override := ""
var _pose_generation := 0

## Kneel at a Portkey at `boot_pos`: face it, reach down (the Place clip) and
## hold on - the clip frozen where the hand rests on the boot - until
## `portkey_release`.
const PORTKEY_HOLD_AT := 1.45

func portkey_kneel(boot_pos: Vector3) -> void:
	if hero_anim == null or pose_override != "":
		return
	_pose_generation += 1
	var generation := _pose_generation
	if visuals:
		var to := boot_pos - global_position
		to.y = 0.0
		if to.length_squared() > 0.01:
			visuals.rotation.y = atan2(to.x, to.z)
	hero_anim.play_oneshot("Portkey_Place")
	pose_override = "Portkey_Kneeling"
	await get_tree().create_timer(PORTKEY_HOLD_AT).timeout
	if generation != _pose_generation or not is_instance_valid(self):
		return
	hero_anim.hold_oneshot()
	pose_override = "Portkey_Hold"

## The body lets go (moved away, the Portkey fired or fizzled).
func portkey_release() -> void:
	if pose_override == "":
		return
	_pose_generation += 1
	pose_override = ""
	if hero_anim:
		hero_anim.cancel_oneshot()

## ------------------------------------------------------------- Floo walk

## Presentation only: the body stays where the authority has it while the
## visuals walk from `from_world` to `to_world` (into a hearth on departure, out
## of one on arrival) with the walk cycle playing. Movement keys are ignored
## while it runs; `end_at_body` puts the visuals back on the body at the end
## (arrival), otherwise they stay in the flames until floo_walk_reset (the
## loading screen covers the jump).
var _floo_tween: Tween = null

func floo_walk(from_world: Vector3, to_world: Vector3, seconds: float, end_at_body := true) -> void:
	if visuals == null:
		return
	if _floo_tween != null and _floo_tween.is_valid():
		_floo_tween.kill()
	var a := to_local(from_world)
	var b := to_local(to_world)
	var flat := Vector2(b.x - a.x, b.z - a.z)
	if flat.length_squared() > 0.0001:
		visuals.rotation.y = atan2(flat.x, flat.y)
	pose_override = "floo"
	if hero_anim != null:
		hero_anim.cancel_oneshot()
		hero_anim.set_ground_motion(Vector2(0.0, flat.length() / maxf(0.1, seconds)))
	visuals.position.x = a.x
	visuals.position.z = a.z
	_floo_tween = create_tween()
	_floo_tween.tween_method(func(t: float):
		if is_instance_valid(visuals):
			visuals.position.x = lerpf(a.x, b.x, t)
			visuals.position.z = lerpf(a.z, b.z, t)
	, 0.0, 1.0, seconds)
	_floo_tween.tween_callback(func():
		if hero_anim != null:
			hero_anim.set_ground_motion(Vector2.ZERO)
		if end_at_body:
			floo_walk_reset()
	)

func floo_walk_reset() -> void:
	if _floo_tween != null and _floo_tween.is_valid():
		_floo_tween.kill()
	_floo_tween = null
	if visuals != null:
		visuals.position.x = 0.0
		visuals.position.z = 0.0
	if pose_override == "floo":
		pose_override = ""

## ------------------------------------------------------- Portkey arrival

## Presentation only, like the Floo walk: the visuals spring out of the mouth
## of the arrival boot (`mouth_world`), small at first, arc up and over and
## land on the body where the authority set it down. Keys are ignored while
## it runs (pose "floo").
var _emerge_lift := 0.0

## Hidden while the loading screen lifts, until the boot lets the body out;
## shown again after a few seconds whatever happens to the boot.
func portkey_hide() -> void:
	if visuals == null:
		return
	pose_override = "floo"
	visuals.scale = Vector3.ONE * 0.01
	var generation := _pose_generation
	await get_tree().create_timer(3.0).timeout
	if is_instance_valid(self) and generation == _pose_generation and visuals.scale.x < 0.05:
		portkey_emerge_reset()

func portkey_emerge(mouth_world: Vector3, seconds := 0.75) -> void:
	if visuals == null:
		return
	if _floo_tween != null and _floo_tween.is_valid():
		_floo_tween.kill()
	_pose_generation += 1
	var a := to_local(mouth_world)
	var flat := Vector2(-a.x, -a.z)
	if flat.length_squared() > 0.0001:
		visuals.rotation.y = atan2(flat.x, flat.y)
	pose_override = "floo"
	if hero_anim != null:
		hero_anim.cancel_oneshot()
		hero_anim.set_locomotion("fall", "Fall_Loop")
	visuals.scale = Vector3.ONE * 0.12
	visuals.position.x = a.x
	visuals.position.z = a.z
	_emerge_lift = a.y
	_floo_tween = create_tween()
	_floo_tween.tween_method(func(t: float):
		if not is_instance_valid(visuals):
			return
		var grow := 1.0 - pow(1.0 - t, 3.0)
		visuals.scale = Vector3.ONE * lerpf(0.12, 1.0, grow)
		visuals.position.x = lerpf(a.x, 0.0, t)
		visuals.position.z = lerpf(a.z, 0.0, t)
		_emerge_lift = lerpf(a.y, 0.0, t) + sin(t * PI) * 1.3
	, 0.0, 1.0, seconds)
	_floo_tween.tween_callback(portkey_emerge_reset)
	_floo_tween.tween_callback(func():
		if hero_anim != null:
			hero_anim.play_oneshot("Land")
	)

func portkey_emerge_reset() -> void:
	_emerge_lift = 0.0
	if visuals != null:
		visuals.scale = Vector3.ONE
	floo_walk_reset()

## A title; true when it is new.
func grant_title(title_id: String) -> bool:
	if titles.has(title_id):
		return false
	titles.append(title_id)
	_quest_state["titles"] = titles.duplicate()
	_update_nameplate()
	return true

## This body's trained level of a spell (1 when untrained or not trainable).
func skill_level(spell_id: String) -> int:
	return HPRules.skill_level_of(skill_levels, spell_id)

func house_rank() -> int:
	return HPRules.house_rank_for(house_rep)

## Where this body's spell leaves it: the head of the equipped wand when one is
## held, otherwise the documented body offset. The wand tip is authored inside
## the prop (`HeroAppearance.wand_tip`), so it follows the grip and the cast
## animation - a spell fired from here genuinely leaves the wand.
func wand_tip_position() -> Vector3:
	var tip := HeroAppearance.wand_tip(visuals)
	if tip:
		return tip.global_position
	return global_position + Vector3(0, CAST_ORIGIN_HEIGHT, 0)

## Where a cast goes: exactly the point under the cursor. A locked target wins;
## a hostile under (or right beside) the cursor is aimed at its chest; otherwise
## the bolt goes to the ground or wall point the cursor shows, and the server
## ends it there (an area spell bursts there).
func get_mouse_aim_point() -> Vector3:
	if is_instance_valid(current_target) and CombatRules.can_damage(self, current_target):
		return current_target.global_position + Vector3.UP * TARGET_AIM_HEIGHT
	if not is_instance_valid(camera):
		return global_position + visuals.global_basis.z * 20.0 + Vector3.UP
	var mouse_pos := get_viewport().get_mouse_position()
	var origin := camera.project_ray_origin(mouse_pos)
	var ray := camera.project_ray_normal(mouse_pos)
	var body := _hostile_under_cursor(mouse_pos, origin, ray)
	if body != null:
		return body.global_position + Vector3.UP * TARGET_AIM_HEIGHT
	var query := PhysicsRayQueryParameters3D.create(origin, origin + ray * 200.0, 1)
	query.exclude = [get_rid()]
	var hit := get_world_3d().direct_space_state.intersect_ray(query)
	if not hit.is_empty():
		return hit.position
	var ground = Plane(Vector3.UP, global_position.y).intersects_ray(origin, ray)
	if ground is Vector3 and (ground as Vector3).distance_to(global_position) < 120.0:
		return ground
	# Cursor on the sky: keep its direction, from the caster's cast height.
	return origin + ray * 60.0

## The hostile body the cursor is on, or within AIM_ASSIST_PX of on screen
## (nearest to the cursor wins), so a click a hair beside a mob still aims at it.
func _hostile_under_cursor(mouse_pos: Vector2, origin: Vector3, ray: Vector3) -> Node3D:
	var query := PhysicsRayQueryParameters3D.create(origin, origin + ray * 100.0, 2)
	query.exclude = [get_rid()]
	var hit := get_world_3d().direct_space_state.intersect_ray(query)
	if not hit.is_empty() and hit.collider is Node3D and (hit.collider as Node3D).is_in_group("targetable") \
			and CombatRules.can_damage(self, hit.collider):
		return hit.collider
	var best: Node3D = null
	var best_px := AIM_ASSIST_PX * (get_viewport().get_visible_rect().size.y / 1080.0)
	for node in get_tree().get_nodes_in_group("targetable"):
		if not (node is Node3D) or node == self:
			continue
		var body := node as Node3D
		var chest := body.global_position + Vector3.UP * TARGET_AIM_HEIGHT
		if chest.distance_squared_to(global_position) > TARGET_RANGE * TARGET_RANGE or camera.is_position_behind(chest):
			continue
		var px := camera.unproject_position(chest).distance_to(mouse_pos)
		var feet_px := camera.unproject_position(body.global_position).distance_to(mouse_pos)
		px = minf(px, feet_px)
		if px < best_px and CombatRules.can_damage(self, body):
			best_px = px
			best = body
	return best

func cast_spell(spell_id: String) -> void:
	if is_dead or not GameData.SPELLS.has(spell_id):
		return
	# Prototype policy: offensive casting is disabled while mounted (Protego is
	# defensive and stays available); airborne combat is a later feature.
	# Held basic-attack repeats every frame, so drop the held input and
	# throttle the feedback instead of spawning a node per frame.
	if is_mounted and spell_id != "protego":
		_basic_held = false
		if _mount_notice_cd <= 0.0:
			_mount_notice_cd = 1.0
			show_notice(tr("Not while mounted!"))
		return

	var s_data: Dictionary = GameData.SPELLS[spell_id]
	if level < int(s_data.get("requires_level", 1)):
		if _mount_notice_cd <= 0.0:
			_mount_notice_cd = 0.8
			show_notice(tr("%s unlocks at level %d") % [I18n.t(String(s_data.get("name", spell_id))), int(s_data.get("requires_level", 1))])
		return
	if skill_level(spell_id) <= 0:
		if _mount_notice_cd <= 0.0:
			_mount_notice_cd = 0.8
			show_notice(tr("Learn %s first - press V and spend a skill point") % I18n.t(String(s_data.get("name", spell_id))))
		return
	var remaining := maxf(_cast_lock, float(spell_cooldowns.get(spell_id, 0.0)))
	if remaining > 0:
		if remaining <= 0.25:
			_queued_spell = spell_id
			_queue_time = 0.3
		return
	_queued_spell = ""

	var cost: int = int(s_data.get("mana_cost", 0))
	if current_mana < cost:
		if _mount_notice_cd <= 0.0:
			_mount_notice_cd = 0.6
			show_notice(tr("Not enough mana"), "mana")
		return

	# --- predicted feedback. The world server decides; everything below is the
	# client's guess at what it will say, and a rejection undoes it cleanly.
	# `aim_hit` is also the cast's aiming target: the animation turns the casting
	# arm onto it (see _play_cast_animation) and the spell leaves the wand's head
	# there (skill_fx.emission_origin reads the live tip).
	var aim_hit := get_mouse_aim_point()

	# Wizard instantly faces the mouse aim direction on ground
	var face_dir := (aim_hit - global_position)
	face_dir.y = 0.0
	if face_dir.length_squared() > 0.01:
		visuals.rotation.y = atan2(face_dir.x, face_dir.z)

	# Refined Basic Attack Chain (Section 4.3 of.md) - animation only; the
	# damage multiplier is the server's combo counter.
	# The chain is 3 steps (flick, backhand, overhead finisher); the window and
	# step count are the same data the server's `_advance_combo` reads, so the
	# predicted gesture matches the multiplier the server applies.
	var anim_name := "Spellcast_Shoot"
	var gesture_combo := 0
	var combo_before := basic_combo_index
	if spell_id == "basic_cast":
		var steps := maxi(1, HPRules.combo_multipliers("basic_cast").size())
		gesture_combo = basic_combo_index % steps
		basic_combo_timer = HPRules.combo_window("basic_cast")
		basic_combo_index = (gesture_combo + 1) % steps

	_cast_lock = float(s_data.get("cast_lock", 0.28))
	_committed_until = maxf(_committed_until, float(COMMITTED_SPELLS.get(spell_id, 0.0)))
	if anim_name.begins_with("1H_Melee") or anim_name == "Melee_Chop_A":
		_committed_until = maxf(_committed_until, COMMITTED_MELEE)
	_cast_seq += 1
	_predicted_casts[_cast_seq] = {"spell_id": spell_id, "aim": aim_hit, "combo_before": combo_before}
	_play_cast_animation(anim_name, aim_hit, spell_id, gesture_combo)
	if spell_id == "protego":
		_activate_protego_preview()
	# spell-effect hook: predicted PRESENTATION only (wand flash + cast sound), keyed
	# by cast_seq so a rejection removes exactly this and nothing else. It cannot
	# produce damage, a hit or a reward: the authority already owns those.
	preload("res://scripts/spells/skill_fx.gd").play_predicted_cast(self, spell_id, _cast_seq)

	SimNet.submit_cast(self, spell_id, aim_hit, _cast_seq)

## Called when the authority answers a cast request. Accepting only arms the UI
## feedback (mana and cooldowns are mirrored when the authority's stats arrive);
## rejecting removes every predicted effect of that cast.
func on_cast_answer(cast_seq: int, _cast_id: int, ok: bool, reason: String) -> void:
	if not _predicted_casts.has(cast_seq):
		return
	var prediction: Dictionary = _predicted_casts[cast_seq]
	_predicted_casts.erase(cast_seq)
	var spell_id := String(prediction.get("spell_id", ""))
	if ok:
		var cd := HPRules.cooldown_for(spell_id, house, skill_level(spell_id), derived_stats)
		if cd > 0.0:
			spell_cooldowns[spell_id] = cd
		emit_signal("spell_cast_signal", spell_id, cd)
		return
	# spell-effect hook: a rejected cast removes its predicted feedback.
	preload("res://scripts/spells/skill_fx.gd").cancel_predicted(self, cast_seq)
	# The server did not advance its chain for a refused cast, so neither do we.
	if spell_id == "basic_cast":
		basic_combo_index = int(prediction.get("combo_before", 0))
	if spell_id == "protego":
		_clear_protego_preview()
	_cast_generation += 1
	is_casting_anim = false
	if hero_anim:
		hero_anim.end_cast()
	_committed_until = 0.0
	_reject_feedback(reason)

func _reject_feedback(reason: String) -> void:
	# With a HUD attached, the combat feedback banner already words every
	# refusal; a second floating label on top of it was noise.
	if not notice.get_connections().is_empty():
		return
	match reason:
		"no_mana":
			_spawn_floating_text(tr("Not enough Mana!"), Color(0.3, 0.6, 1.0))
		"cooldown":
			pass
		"mounted":
			_spawn_floating_text(tr("Not while mounted!"), Color(1.0, 0.8, 0.4))
		"protected":
			_spawn_floating_text(tr("Protected ground!"), Color(0.4, 0.8, 1.0))
		"dead":
			pass
		_:
			if reason != "" and reason != "queued" and reason != "sent":
				_spawn_floating_text(tr("Cast refused"), Color(1.0, 0.6, 0.4))

## Cast presentation. The upper-body clip is blended OVER locomotion (so a
## moving caster keeps their footwork), the clip is seeked so its extension pose
## lands on the authority's release moment - `fx:wand_release` is only emitted
## then, never on a guessed frame - and the casting arm is then aimed at `aim`.
##
## `aim` defaults to the body's forward so the cast still points somewhere when a
## caller has no aim point (the vfx viewer calls this with no arguments).
func _play_cast_animation(anim_name: String = "Spellcast_Shoot", aim: Variant = null, spell: String = "", combo: int = 0, release_delay := -1.0) -> void:
	if hero_anim == null and not is_instance_valid(anim_player):
		return
	is_casting_anim = true
	_cast_generation += 1
	var generation := _cast_generation
	# A wand cast is one-handed (the wand hand). The power spells add the off
	# hand: wand raised back, both hands thrust together.
	if spell in HEAVY_CAST_SPELLS:
		anim_name = "Spellcast_Heavy"
	elif spell == "protego":
		anim_name = "Spellcast_Raise"
	elif spell == "basic_cast":
		# The basic chain is three different moves: a quick shot, a wand slash,
		# then a two-handed heavy finisher.
		anim_name = BASIC_COMBO_CLIPS[clampi(combo, 0, BASIC_COMBO_CLIPS.size() - 1)]
	var own: Dictionary = SPELL_CLIPS.get("basic_cast:%d" % clampi(combo, 0, 2) if spell == "basic_cast" else spell, {})
	var release_fraction := 0.45
	if not own.is_empty() and hero_anim != null and hero_anim.has_clip(String(own.clip) + "_Upper"):
		anim_name = String(own.clip)
		release_fraction = float(own.release)
	else:
		own = {}
	var upper := anim_name + "_Upper"
	var hold := 0.42
	if not own.is_empty():
		hold = float(own.hold)
	elif spell == "basic_cast":
		hold = [0.30, 0.36, 0.46][clampi(combo, 0, 2)]
	elif spell == "stupefy":
		hold = 0.48
	else:
		hold = float({"incendio": 0.65, "bombarda": 0.55, "expelliarmus": 0.42, "protego": 0.62, "ultimate": 0.72}.get(spell, hold))
	# Use the same tick-rounded windup as SimAuthority. Gesture recovery can be
	# longer than the gameplay lock, but extension must meet the actual release.
	var release := release_delay
	if release < 0.0:
		release = float(maxi(1, int(round(HPRules.cast_lock(spell) * 0.5 * HPProtocol.SIM_HZ)))) / HPProtocol.SIM_HZ \
			if GameData.SPELLS.has(spell) else hold * 0.6
	release = clampf(release, 0.01, hold - 0.02)
	if hero_anim:
		hero_anim.start_cast(upper if hero_anim.has_clip(upper) else anim_name, hold)
		if hero_anim.cast_layer:
			# A captured clip carries its own windup and snap; the procedural
			# gesture overlay is for the generic shoot clip only.
			hero_anim.cast_layer.set_gesture("" if not own.is_empty() else spell, combo, hold)
		hero_anim.align_cast(release, release_fraction)
		# A wand cast points the wand at the target; a melee chop is a SWING, so it
		# keeps the clip's own arm (holding it on the target would freeze it). The
		# aim lasts exactly as long as the cast - end_cast releases it.
		if anim_name.begins_with("Melee") or anim_name.begins_with("1H_Melee") or not bool(own.get("aim", true)):
			hero_anim.clear_cast_aim()
		else:
			hero_anim.set_cast_aim(aim if aim is Vector3 else global_position + visuals.global_basis.z * 12.0)
	elif anim_player:
		if anim_player.has_animation(anim_name):
			anim_player.play(anim_name, 0.08)
		elif anim_player.has_animation("Spellcast_Shoot"):
			anim_player.play("Spellcast_Shoot", 0.08)
	await get_tree().create_timer(release).timeout
	if generation != _cast_generation or is_dead:
		return
	_on_animation_event("fx:wand_release")
	await get_tree().create_timer(hold - release).timeout
	if generation == _cast_generation and not is_dead:
		is_casting_anim = false
		if hero_anim:
			hero_anim.end_cast()

## A replicated cast: another player's body plays the same gesture, aimed from the
## authority's origin and direction rather than from local input. The caster's own
## client already predicted this, so only other clients run it.
func present_replicated_cast_start(cast_id: int, aim: Vector3, spell: String, release_delay: float) -> void:
	if is_local_player or hero_anim == null or is_dead:
		return
	_replicated_cast_id = cast_id
	_play_cast_animation("Spellcast_Shoot", aim, spell, 0, release_delay)

func present_replicated_cast(origin: Vector3, dir: Vector3, spell: String = "", cast_id := -1) -> void:
	if is_local_player or hero_anim == null or is_dead:
		return
	if cast_id >= 0 and _replicated_cast_id == cast_id:
		return
	_play_cast_animation("Spellcast_Shoot", origin + dir * 20.0, spell)

func _activate_protego_preview() -> void:
	is_protego_active = true
	var p_shield = PROTEGO_SCENE.instantiate()
	p_shield.name = "ProtegoPreview"
	add_child(p_shield)
	p_shield.setup(self)
	# The ward ends when the shield does. Nothing cleared the flag before, so the
	# status icon outlived the effect forever.
	p_shield.tree_exited.connect(_on_protego_shield_gone)
	var spell: Dictionary = GameData.SPELLS.get("protego", {})
	var seconds := float(spell.get("duration_ms", 3500)) / 1000.0
	add_buff("protego", seconds, "protego", "Protego", "Reflects projectiles; other damage reduced by 60%.")  # i18n
	_spawn_floating_text(I18n.upper(tr("Protego!")), Color(0.2, 0.8, 1.0), 1.2)

func _on_protego_shield_gone() -> void:
	if not is_inside_tree():
		return
	var other := get_node_or_null("ProtegoPreview")
	if other != null and is_instance_valid(other) and not other.is_queued_for_deletion():
		return
	is_protego_active = false
	remove_buff("protego")

## ------------------------------------------------------------------- buffs

func add_buff(id: String, seconds: float, icon_id: String, title: String, desc: String) -> void:
	active_buffs[id] = {
		"until_ms": Time.get_ticks_msec() + int(seconds * 1000.0) if seconds > 0.0 else 0,
		"duration": seconds,
		"icon": icon_id,
		"title": title,
		"desc": desc,
	}
	buffs_changed.emit()

func remove_buff(id: String) -> void:
	if active_buffs.erase(id):
		buffs_changed.emit()

## Seconds left on a timed buff, 0 when it is gone, -1 for one with no timer.
func buff_remaining(id: String) -> float:
	if not active_buffs.has(id):
		return 0.0
	var until := int(active_buffs[id].get("until_ms", 0))
	if until == 0:
		return -1.0
	return maxf(0.0, float(until - Time.get_ticks_msec()) / 1000.0)

func _expire_buffs() -> void:
	if active_buffs.is_empty():
		return
	var now := Time.get_ticks_msec()
	for id in active_buffs.keys():
		var until := int(active_buffs[id].get("until_ms", 0))
		if until != 0 and now >= until:
			active_buffs.erase(id)
			if id == "protego":
				is_protego_active = false
			buffs_changed.emit()

## A player-facing notice. The HUD shows it as a banner; without a HUD listening
## (tests, the dedicated server) it falls back to the floating label.
func show_notice(text: String, kind: String = "warn") -> void:
	if notice.get_connections().is_empty():
		_spawn_floating_text(text, Color(1, 0.7, 0.3))
	else:
		notice.emit(text, kind)

func _clear_protego_preview() -> void:
	is_protego_active = false
	remove_buff("protego")
	var preview = get_node_or_null("ProtegoPreview")
	if preview and is_instance_valid(preview):
		preview.queue_free()

## Damage arrives from the authority only. A client may ask for its own damage
## (tests, falling) but the engine refuses anything it did not schedule.
func take_damage(amount: int, spell_type: String, attacker: Node3D) -> void:
	SimAuthority.apply_damage(self, amount, spell_type, attacker)

## Presentation hook: the engine has already applied the numbers.
func on_authoritative_damage(spell_type: String, attacker: Node3D, _stun_ms: int, _weaken_ms: int) -> void:
	if is_dead:
		return
	# Taking a hit starts the combat window that refuses mount requests.
	_combat_until = COMBAT_WINDOW
	var actual_dmg := 0
	var record := SimAuthority.record_for(self)
	if not record.is_empty():
		actual_dmg = int(record.get("last_damage", 0))
	if is_protego_active and actual_dmg > 0:
		_spawn_floating_text("BLOCKED 60%!", Color(0.3, 0.7, 1.0))
	elif actual_dmg > 0 and not HitFeedback.enabled():
		# On screen, HitFeedback draws every number (taken ones in red).
		_spawn_floating_text(str(actual_dmg), Color(1.0, 0.2, 0.2), 1.3)
	if not is_casting_anim and current_hp > 0 and actual_dmg > 0:
		if hero_anim:
			hero_anim.play_oneshot("Hit_A")
		elif is_instance_valid(anim_player):
			anim_player.play("Hit_A", 0.1)
		_hit_recovery = 0.22
	emit_stats()

## Reconciliation. Absorbs network propagation delay: server snapshots reflect
## where the client was RTT/2 in the past. We compare against recent trajectory
## history so normal movement never rubberbands, while true discrepancies,
## teleports, and wall collisions are authoritatively enforced.
func reset_prediction_history() -> void:
	_pos_history.clear()
	_standing_time = 0.0

func apply_authoritative_position(pos: Vector3, rot_y: float) -> void:
	if not is_local_player:
		return

	if is_dead:
		global_position = pos
		velocity = Vector3.ZERO
		_pos_history.clear()
		return

	var direct_dist := global_position.distance_to(pos)

	# No prediction yet (or an explicit map transfer cleared it): establish the
	# authoritative starting point. Large offsets are checked against history
	# below: a 0.5 s server stall already spans 7.5 m on the broom.
	if _pos_history.is_empty():
		global_position = pos
		velocity = Vector3.ZERO
		_pos_history.clear()
		if visuals:
			visuals.rotation.y = rot_y
		return

	# Find closest point along recent client trajectory to the authoritative position.
	# Because of network round-trip latency, `pos` naturally corresponds to where the
	# server simulated us tens to hundreds of milliseconds ago.
	var closest_pt: Vector3 = _pos_history.closest(pos, global_position)
	var min_path_dist := closest_pt.distance_to(pos)
	# Teleports and real large disagreements still snap immediately. A snapshot
	# on the recent path gets at most one second of grace; stale history expires,
	# so a wall or a stopped server cannot leave prediction running unchecked.
	if direct_dist > 6.0 and min_path_dist > 0.75:
		global_position = pos
		velocity = Vector3.ZERO
		_pos_history.clear()
		if visuals:
			visuals.rotation.y = rot_y
		return

	var is_standing := Vector2(velocity.x, velocity.z).length_squared() < 0.06 and _intent_move().length_squared() < 0.01

	if is_standing:
		# Vertical: a carriage, a lift or a fall rescue moves the body through the
		# server, and only the server knows where it went. On the floor a few
		# centimetres are terrain sampling and snapshot age, not disagreement -
		# pulling 25% toward them every snapshot is what made a body standing on
		# a slope tremble.
		var dy := pos.y - global_position.y
		var vertical_tolerance := 0.3 if (is_on_floor() or is_mounted) else 0.005
		if absf(dy) > vertical_tolerance:
			global_position.y = lerpf(global_position.y, pos.y, 0.25)
		# The server is still finishing the path we already walked (snapshot
		# age + its own deceleration): a snapshot that lies ON our recent path
		# inside the settle window is the past, not a correction. Pulling toward
		# it dragged the body back and then forward again - the stop "shudder",
		# worst on the broom where 15 m/s of lag is a couple of metres.
		if _standing_time < STANDING_SETTLE and min_path_dist < 0.75:
			return
		# Horizontally, a snapshot taken while we were still decelerating sits a
		# fraction of a metre behind us. Pulling 25% of the way toward it every
		# snapshot dragged the body on after the key was released, which is the
		# "keeps moving a moment after stopping" the player sees. The same inputs
		# through the same deceleration land both sides on the same point within a
		# few ticks, so a residual inside the stopping distance is latency, not
		# disagreement - correct only what is genuinely elsewhere.
		if direct_dist > 4.0:
			global_position = pos
			velocity = Vector3.ZERO
			_pos_history.clear()
		elif direct_dist > STANDING_TOLERANCE:
			global_position.x = lerpf(global_position.x, pos.x, 0.2)
			global_position.z = lerpf(global_position.z, pos.z, 0.2)
	else:
		# When moving:
		# If the server's snapshot position is along our recent path (within tolerance),
		# it is merely trailing due to network RTT latency. DO NOT pull the player backwards!
		if min_path_dist > 2.5:
			# Off-path discrepancy (e.g. server blocked by wall/obstacle or server-side knockback)
			global_position = pos
			velocity = Vector3.ZERO
			_pos_history.clear()
			if visuals:
				visuals.rotation.y = rot_y
		elif min_path_dist > 0.4:
			# Mild trajectory drift (sliding against slopes/edges): gently nudge without stalling velocity
			var drift := pos - closest_pt
			global_position += drift * 0.15

## Authority death notification: presentation only - the engine schedules the
## respawn and calls `on_authoritative_respawn` when it fires.
func on_authoritative_death(_killer: Node3D) -> void:
	if is_dead:
		return
	is_dead = true
	is_casting_anim = true
	_cast_generation += 1
	_queued_spell = ""
	_basic_held = false
	_predicted_casts.clear()
	_clear_protego_preview()
	_apply_mount_state(false)
	_committed_until = 0.0
	_pos_history.clear()
	velocity = Vector3.ZERO
	if hero_anim:
		hero_anim.set_locomotion("dead", "Death_A", true)
	elif is_instance_valid(anim_player):
		anim_player.play("Death_A", 0.1)
	_spawn_floating_text(I18n.upper(tr("Defeated!")), Color(1.0, 0.0, 0.0), 2.0)
	emit_stats()

## The body is not moved here: the authority places it (town or where it fell,
## the player's choice) and a client follows the next snapshot.
func on_authoritative_respawn() -> void:
	velocity = Vector3.ZERO
	_committed_until = 0.0
	_pos_history.clear()
	is_dead = false
	is_casting_anim = false
	if hero_anim:
		hero_anim.play_oneshot("Revive")
		hero_anim.set_locomotion("idle", "Idle", true)
	elif is_instance_valid(anim_player):
		anim_player.play("Idle", 0.2)
	emit_stats()

## Authority level-up notification.
func apply_level(new_level: int, new_max_hp: int, new_max_mana: int) -> void:
	level = new_level
	max_exp = HPRules.exp_threshold(new_level)
	max_hp = new_max_hp
	max_mana = new_max_mana
	current_hp = max_hp
	current_mana = max_mana
	_update_nameplate()
	_spawn_floating_text(tr("LEVEL UP! (Lv.%d)") % level, Color(1.0, 0.85, 0.2), 1.8)
	emit_stats()

## Authority stat mirror: the engine owns these numbers, the node displays them.
func apply_authoritative_stats(stats: Dictionary) -> void:
	# Ownership is revisioned independently of the live combat/progression feed.
	if stats.has("equipment"):
		apply_equipment_snapshot(stats)
	current_hp = clampi(int(stats.get("hp", current_hp)), 0, maxi(1, int(stats.get("max_hp", max_hp))))
	max_hp = maxi(1, int(stats.get("max_hp", max_hp)))
	current_mana = clampi(int(stats.get("mana", current_mana)), 0, maxi(1, int(stats.get("max_mana", max_mana))))
	max_mana = maxi(1, int(stats.get("max_mana", max_mana)))
	current_exp = int(stats.get("exp", current_exp))
	max_exp = int(stats.get("max_exp", max_exp))
	level = int(stats.get("level", level))
	galleons = int(stats.get("galleons", galleons))
	house_rep = int(stats.get("house_rep", house_rep))
	if stats.get("quests") is Dictionary:
		var log: Dictionary = stats["quests"]
		quest_progress = (log.get("progress", {}) as Dictionary).duplicate() if log.get("progress") is Dictionary else {}
		quest_ready = (log.get("ready", []) as Array).duplicate() if log.get("ready") is Array else []
		quest_done = (log.get("done", []) as Array).duplicate() if log.get("done") is Array else quest_done
	if stats.get("attributes") is Dictionary:
		var fresh_attributes := HPRules.clean_attributes(stats["attributes"])
		if fresh_attributes != attributes:
			attributes = fresh_attributes
			_recalculate_equipment()
	attribute_points = int(stats.get("attribute_points", attribute_points))
	if stats.get("floo_known") is Array:
		_quest_state["floo_known"] = (stats["floo_known"] as Array).duplicate()
	if stats.get("titles") is Array and stats["titles"] != titles:
		var fresh: Array = (stats["titles"] as Array).filter(func(t): return not titles.has(t))
		titles = (stats["titles"] as Array).duplicate()
		_update_nameplate()
		if is_local_player and _skills_seen:
			for t in fresh:
				_spawn_floating_text(tr("New title: %s") % tr(String(TITLE_NAMES.get(t, t))), Color(1.0, 0.82, 0.4), 1.6)
	if stats.get("skills") is Dictionary:
		var trained := HPRules.clean_skill_levels(stats["skills"])
		if is_local_player and _skills_seen:
			for spell_id in trained.keys():
				var now := int(trained[spell_id])
				if now > HPRules.skill_level_of(skill_levels, spell_id):
					var spell_name := I18n.t(String(HPRules.spell(spell_id).get("name", spell_id)))
					var text := tr("%s mastered!") % spell_name if HPRules.skill_is_master(now) else tr("%s Lv.%d") % [spell_name, now]
					_spawn_floating_text(text, Color(0.55, 0.85, 1.0), 1.3)
		skill_levels = trained
		_skills_seen = true
	skill_points = int(stats.get("skill_points", HPRules.skill_points_available(level, skill_levels, skill_bonus)))
	if _shown_house_rep >= 0 and house_rep > _shown_house_rep and is_local_player:
		_spawn_floating_text(tr("+%d %s Reputation") % [house_rep - _shown_house_rep, house], Color(1.0, 0.78, 0.35), 1.1)
	_shown_house_rep = house_rep
	var was_mounted := is_mounted
	var now_mounted := bool(stats.get("mounted", is_mounted))
	if was_mounted != now_mounted:
		_apply_mount_state(now_mounted)
	if bool(stats.get("dead", is_dead)) != is_dead:
		if bool(stats.get("dead", is_dead)):
			on_authoritative_death(null)
		else:
			on_authoritative_respawn()
	_update_nameplate()
	emit_stats()

## EXP grants come from the authority (kill credit, quests). In a client-only
## role the server sends the resulting stats instead, so this is a no-op there.
func add_exp(amount: int) -> void:
	if not SimAuthority.is_authority():
		return
	SimAuthority.grant_exp(self, amount)
	_spawn_floating_text(tr("+%d EXP") % amount, Color(0.3, 1.0, 0.5), 1.2)

## House reputation, granted by the authority like EXP (quests are the source;
## the floating text comes with the stats payload in every role).
func add_house_rep(amount: int) -> void:
	if not SimAuthority.is_authority() or amount <= 0:
		return
	SimAuthority.grant_house_rep(self, amount)

func add_loot(item_id: String, amount: int, tier: int = 0) -> void:
	if not SimAuthority.is_authority() or amount <= 0:
		return
	if item_id == "galleons":
		galleons += amount
		inventory_revision += 1
		emit_signal("loot_collected_signal", "galleons", amount)
		inventory_changed.emit()
		return
	
	HPEquipment.add(inventory, item_id, tier, amount)   # stacks merge, instances stay apart
	inventory_revision += 1
	
	emit_signal("loot_collected_signal", item_id, amount)
	inventory_changed.emit()

func pickup_nearest_loot() -> void:
	var loot_nodes = get_tree().get_nodes_in_group("loot")
	var nearest_loot: Area3D = null
	var min_dist: float = maxf(PICKUP_RADIUS, 6.0)
	for loot in loot_nodes:
		if is_instance_valid(loot) and not bool(loot.get("is_collected")):
			var dist = global_position.distance_to(loot.global_position)
			if dist < min_dist:
				min_dist = dist
				nearest_loot = loot
	if nearest_loot and nearest_loot.has_method("collect"):
		nearest_loot.collect(self)

func cycle_nearest_target() -> void:
	var targets: Array[Node3D] = []
	for target in get_tree().get_nodes_in_group("targetable"):
		if CombatRules.can_damage(self, target) and global_position.distance_to(target.global_position) < TARGET_RANGE:
			targets.append(target)
	if targets.is_empty():
		set_target(null)
		return
	targets.sort_custom(func(a: Node3D, b: Node3D): return global_position.distance_squared_to(a.global_position) < global_position.distance_squared_to(b.global_position))
	var index := targets.find(current_target)
	set_target(targets[(index + 1) % targets.size()])

func set_target(node: Node3D) -> void:
	if node != null and not is_instance_valid(node):
		node = null
	if node == self:
		node = null   # clicking yourself selects nothing
	if is_instance_valid(current_target) and current_target.tree_exiting.is_connected(_on_target_exiting):
		current_target.tree_exiting.disconnect(_on_target_exiting)
	current_target = node
	# A view freed while targeted (out of range after a respawn or a map hop, a
	# corpse cleared) must not stay referenced: a release build dereferences the
	# freed pointer in every reader's `is` check and the client crashes.
	if node != null and not node.tree_exiting.is_connected(_on_target_exiting):
		node.tree_exiting.connect(_on_target_exiting)
	emit_signal("target_changed", current_target)

func _on_target_exiting() -> void:
	set_target(null)

func _try_click_target() -> bool:
	var mouse_pos := get_viewport().get_mouse_position()
	var from := camera.project_ray_origin(mouse_pos)
	var to := from + camera.project_ray_normal(mouse_pos) * 60.0
	var space := get_world_3d().direct_space_state
	var query := PhysicsRayQueryParameters3D.create(from, to)
	query.collision_mask = 2
	var result := space.intersect_ray(query)
	if result:
		var collider = result.collider
		if collider.is_in_group("targetable") and CombatRules.can_damage(self, collider):
			set_target(collider)
			return true
	set_target(null)
	return false

## A click on an NPC: in talking range (the authority's quest_talk_radius, less
## a little for latency) it asks the world to open the dialogue; farther away the
## NPC only becomes the target and a notice says to come closer. True when the
## cursor was on an NPC, so the click casts nothing.
func _click_npc() -> bool:
	if camera == null:
		return false
	var mouse_pos := get_viewport().get_mouse_position()
	var from := camera.project_ray_origin(mouse_pos)
	var query := PhysicsRayQueryParameters3D.create(from, from + camera.project_ray_normal(mouse_pos) * 80.0)
	query.collision_mask = 2
	var hit := get_world_3d().direct_space_state.intersect_ray(query)
	if hit.is_empty() or not (hit.collider is Node3D) or not (hit.collider as Node3D).is_in_group("npcs"):
		return false
	var npc := hit.collider as Node3D
	if npc.global_position.distance_to(global_position) <= HPRules.quest_talk_radius() - 0.5:
		talk_requested.emit(npc)
	else:
		set_target(npc)
		show_notice(tr("Come closer to talk."), "info")
	return true

## Right-click selection: anything targetable under the cursor - a mob, a boss, a
## monolith, a dummy - becomes the target so its card shows, hostile or not, and
## nothing is cast. Clicking empty ground leaves the current target alone.
func _inspect_click_target() -> bool:
	if camera == null:
		return false
	var mouse_pos := get_viewport().get_mouse_position()
	var from := camera.project_ray_origin(mouse_pos)
	var to := from + camera.project_ray_normal(mouse_pos) * 80.0
	# A loot chest under the cursor opens (right click, Knight Online style).
	var chest_query := PhysicsRayQueryParameters3D.create(from, to, 8)
	chest_query.collide_with_areas = true
	chest_query.collide_with_bodies = false
	var chest := get_world_3d().direct_space_state.intersect_ray(chest_query)
	if chest and chest.collider is Node3D and (chest.collider as Node3D).has_method("open_window"):
		(chest.collider as Node3D).call("open_window", self)
		return true
	var query := PhysicsRayQueryParameters3D.create(from, to)
	query.collision_mask = 2
	var result := get_world_3d().direct_space_state.intersect_ray(query)
	if result and result.collider is Node3D and (result.collider as Node3D).is_in_group("targetable"):
		set_target(result.collider)
		return true
	return false

func upgrade_wand(_new_tier: int) -> void:
	# Compatibility entry point: the authority determines the resulting tier.
	SimNet.submit_equipment(self, "refine", "main_hand")

## Re-attach the equipped wand whenever what is held changes. The head of the
## wand, its tip marker and the refinement aura are all built inside that one
## call, so they cannot drift apart from the grip or from each other.
func _apply_wand_aura() -> void:
	if not is_instance_valid(visuals):
		return
	var key := str(equipment.get("main_hand",{}))
	if key != _wand_visual_key:
		_wand_visual_key = key
		HeroAppearance.show_equipped_wand(visuals,equipment.get("main_hand",{}))
	# The worn cloak (chest item with a `cloak_texture`); idempotent per fabric.
	HeroAppearance.show_cloak(visuals, equipment.get("chest", {}))

func _spawn_floating_text(text: String, col: Color, scale_mult: float = 1.0) -> void:
	if NetworkManager.is_dedicated_server:
		return   # nobody looks: it was a Label3D scene per hit a player took
	if FT_SCENE:
		var ft = FT_SCENE.instantiate()
		get_parent().add_child(ft)
		ft.global_position = global_position + Vector3(0, NAMEPLATE_HEIGHT + 0.1, 0)
		ft.setup(text, col, scale_mult)

## Public single-line feedback hook (potions, UI events).
func show_floating_text(text: String, col: Color, scale_mult: float = 1.0) -> void:
	_spawn_floating_text(text, col, scale_mult)

func emit_stats() -> void:
	emit_signal("stats_changed", current_hp, max_hp, current_mana, max_mana, current_exp, max_exp, level)

func _initialize_equipment() -> void:
	if equipment_version == 0:
		base_max_hp = max_hp
		base_max_mana = max_mana
		var migrated := HPEquipment.migrate(inventory, wand_tier)
		inventory.assign(migrated.inventory)
		equipment = migrated.equipment
		equipment_version = 1
	_recalculate_equipment()

func _recalculate_equipment() -> void:
	derived_stats = HPEquipment.stats(base_max_hp, base_max_mana, equipment, attributes)
	max_hp = int(derived_stats.max_hp)
	max_mana = int(derived_stats.max_mana)
	current_hp = mini(current_hp, max_hp)
	current_mana = mini(current_mana, max_mana)
	wand_tier = int(derived_stats.wand_tier)
	mounted_speed = maxf(0.1, float(derived_stats.mount_speed))
	_apply_wand_aura()
	_apply_broom_model()

## Another player's worn gear as the server announces it (v22 sim_player_info
## `gear`: slot -> {id, tier}). A remote view draws the wand, cloak and broom
## from it; its bag and bonuses never reach this client.
var _appearance: Dictionary = {}

func apply_appearance(gear: Dictionary) -> void:
	if is_local_player or gear == _appearance:
		return
	if not is_node_ready():
		# _ready dresses a fresh body with the starter kit; the announced gear
		# goes on after it, not under it.
		ready.connect(apply_appearance.bind(gear.duplicate(true)), CONNECT_ONE_SHOT)
		return
	_appearance = gear.duplicate(true)
	equipment = gear.duplicate(true)
	_recalculate_equipment()

func apply_equipment_snapshot(snapshot: Dictionary) -> void:
	var revision := int(snapshot.get("inventory_revision", -1))
	if revision < inventory_revision:
		return
	var changed: bool = equipment != snapshot.get("equipment", equipment) or inventory != snapshot.get("inventory", inventory)
	inventory_revision = revision
	equipment = (snapshot.get("equipment", equipment) as Dictionary).duplicate(true)
	if snapshot.get("inventory") is Array:
		inventory.assign(snapshot.inventory)
	base_max_hp = int(snapshot.get("base_max_hp", base_max_hp))
	base_max_mana = int(snapshot.get("base_max_mana", base_max_mana))
	equipment_version = 1
	_recalculate_equipment()
	if changed:
		inventory_changed.emit()
		equipment_changed.emit()
