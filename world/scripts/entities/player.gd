extends CharacterBody3D

## 3D Wizard Player Controller (Metin2 MMO Style)
## Decoupled 3rd-person camera, animated 3D wizard model, wand combat, broom mount, and Ollivander auras

signal stats_changed(hp: int, max_hp: int, mana: int, max_mana: int, exp: int, max_exp: int, level: int)
signal target_changed(target_node: Node3D)
signal spell_cast_signal(spell_id: String, cooldown: float)
signal loot_collected_signal(item_id: String, amount: int)
signal mounted_changed(is_mounted: bool)
signal inventory_changed
## Phase 9: animation events (`footstep:<surface>`, `fx:wand_release`, ...) that
## Phase 12 consumes for audio. Emitted from measured contact, never from a
## hardcoded frame number.
signal animation_event(event_name: String)

## --------------------------------------------------------------- Phase 9 body
## Measured from hero_wizard.glb (hooded adventurer, 1.835 m crown). Every
## distance that depends on body size is derived from these, so a second resize
## is a constant change, not a hunt through the file.
const HERO_CROWN_HEIGHT := 1.84
const CAMERA_HEIGHT := 1.55          # pivot at chest/eye level of the new body
const NAMEPLATE_HEIGHT := 2.18       # crown + 0.34 headroom for the label
const CAPSULE_RADIUS := 0.35         # art-direction section 2 silhouette
const CAPSULE_HEIGHT := 1.85
const CAST_ORIGIN_HEIGHT := 1.25     # wand hand height when standing
const INTERACT_RADIUS := 3.5         # NPC / object interaction reach
const PICKUP_RADIUS := 4.9           # loot reach (broom-length arm + lean)
const TARGET_RANGE := 35.0
const TARGET_AIM_HEIGHT := 1.15      # chest height of the taller silhouette
const MOUNT_CLEAR_HEIGHT := 1.15     # headroom needed above the crown to take off
const MOUNT_LATERAL_LENGTH := 2.35   # broom footprint length when mounted
const MOUNT_LATERAL_WIDTH := 0.6
const DISMOUNT_CEILING := 2.15       # headroom required at the landing spot
const COMBAT_WINDOW := 2.0           # seconds after taking damage that mounting is refused

## Phase 9 mount state machine. The authority owns the actual permission
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
var inventory: Array[Dictionary] = []

# Movement & Speeds
var walk_speed: float = 8.5
var mounted_speed: float = 15.0
var is_mounted: bool = false
var gravity: float = 24.0

# Decoupled Camera Orbit
var camera_rot_x: float = -20.0
var camera_rot_y: float = 0.0
var camera_distance: float = 8.0
var mouse_orbit_active: bool = false

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
## Committed attacks: movement is explicitly restricted until this expires
## (plan Phase 9 - "explicit movement restrictions for committed attacks").
var _committed_until := 0.0
## Spells whose recovery commits the caster in place.
const COMMITTED_SPELLS := {"bombarda": 0.35, "ultimate": 0.5}
const COMMITTED_MELEE := 0.45
## Rolling history of local positions used for latency-tolerant reconciliation.
var _pos_history: Array[Vector3] = []
const MAX_POS_HISTORY := 90

var _cast_seq := 0
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
const CombatRules = preload("res://scripts/spells/combat_rules.gd")
const ParticleKit = preload("res://scripts/assets/particle_kit.gd")
const HeroAnimationScript = preload("res://scripts/entities/hero_animation.gd")
const BroomFlightScript = preload("res://scripts/entities/broom_flight.gd")
## Phase 9 socket convention: one socket per attachment point, bound to the
## skeleton by bone name (docs/phase9-rig-and-sockets.md).
const SOCKET_BONES := {
	"Socket_Wand": "Wrist.R",
	"Socket_Hand_L": "Wrist.L",
	"Socket_Hand_R": "Wrist.R",
	"Socket_Foot_L": "Foot.L",
	"Socket_Foot_R": "Foot.R",
	"Socket_Torso": "Chest",
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
@onready var wand_aura_particles: CPUParticles3D = get_node_or_null("Visuals/WandAuraParticles")
@onready var wand_tip: Marker3D = get_node_or_null("Visuals/WandTipMarker")
@onready var nameplate: Label3D = get_node_or_null("NameplateLabel3D")
## Phase 9: the animation graph and the authored broom rig.
var hero_anim: HeroAnimation
var broom: BroomFlight
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
		spring_arm.collision_mask = 1
		spring_arm.add_excluded_object(get_rid())
	_apply_house_customization()
	_apply_wand_aura()
	_update_nameplate()
	if inventory.is_empty():
		_init_starter_inventory()
	
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
	# Phase 9 hero: the model, its animation graph and the broom rig. The
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
			# Godot sanitises dots in bone names (`Foot.L` -> `Foot_L`); accept
			# either spelling rather than silently missing a socket.
			var dotted := bone.replace("_L", ".L").replace("_R", ".R")
			if skeleton.find_bone(dotted) >= 0:
				bone = dotted
			else:
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
	broom = BroomFlightScript.new()
	broom.name = "BroomRig"
	broom_mesh.add_child(broom)
	broom.setup(self, visuals, broom_particles, broom_mesh)
	if broom_mesh is Node3D:
		broom_mesh.rotation = Vector3.ZERO   # the authored GLB is already +Z forward
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
## darkened house tone and the trim family the house primary colour.
func _apply_house_customization() -> void:
	if not GameData.HOUSES.has(house):
		return
	var h_data = GameData.HOUSES[house]
	var primary_col: Color = h_data.primary_color
	var body := visuals.find_child("Hero_Body", true, false)
	if body is MeshInstance3D:
		var mesh: Mesh = (body as MeshInstance3D).mesh
		for i in range(mesh.get_surface_count()):
			var mat := mesh.surface_get_material(i)
			if mat is StandardMaterial3D:
				var named := (mat as StandardMaterial3D).resource_name
				if named == "Hero_Trim":
					var trim := (mat as StandardMaterial3D).duplicate() as StandardMaterial3D
					trim.albedo_color = primary_col
					trim.metallic = 0.35
					trim.roughness = 0.45
					(body as MeshInstance3D).set_surface_override_material(i, trim)
				elif named == "Hero_Robe":
					var robe := (mat as StandardMaterial3D).duplicate() as StandardMaterial3D
					robe.albedo_color = primary_col.darkened(0.72)
					(body as MeshInstance3D).set_surface_override_material(i, robe)

	if house == "Hufflepuff":
		max_hp = 625
		current_hp = 625
	elif house == "Ravenclaw":
		max_mana = 375
		current_mana = 375

func _update_nameplate() -> void:
	if nameplate:
		nameplate.text = "[%s]\n%s (Lv.%d)" % [house, player_name, level]
		if GameData.HOUSES.has(house):
			nameplate.modulate = GameData.HOUSES[house].secondary_color

func _init_starter_inventory() -> void:
	inventory.clear()
	inventory.append({"id": "wand_hawthorn", "amount": 1, "tier": wand_tier})
	inventory.append({"id": "robe_apprentice", "amount": 1, "tier": 0})
	inventory.append({"id": "broom_nimbus2000", "amount": 1, "tier": 0})
	inventory.append({"id": "mat_phoenix_ash", "amount": 5, "tier": 0})
	inventory.append({"id": "mat_dragon_heartstring", "amount": 2, "tier": 0})
	inventory.append({"id": "potion_health", "amount": 5, "tier": 0})
	inventory.append({"id": "potion_mana", "amount": 5, "tier": 0})

func _unhandled_input(event: InputEvent) -> void:
	if not is_local_player or is_dead or input_blocked():
		return
	
	# Mouse look on right-click hold (Classic MMO / Metin2 feel)
	if event is InputEventMouseButton:
		if event.button_index == MOUSE_BUTTON_RIGHT:
			mouse_orbit_active = event.pressed
		elif event.button_index == MOUSE_BUTTON_WHEEL_UP:
			camera_distance = clamp(camera_distance - 0.8, 3.0, 16.0)
			spring_arm.spring_length = camera_distance
		elif event.button_index == MOUSE_BUTTON_WHEEL_DOWN:
			camera_distance = clamp(camera_distance + 0.8, 3.0, 16.0)
			spring_arm.spring_length = camera_distance
		elif event.button_index == MOUSE_BUTTON_LEFT and event.pressed:
			_basic_held = true
			_try_click_target()
			cast_spell("basic_cast")
	
	elif event is InputEventMouseMotion and mouse_orbit_active:
		# Phase 13 hook: the mouse sensitivity slider scales the same raw
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

func _process(delta: float) -> void:
	# Tick spell cooldowns
	for spell_id in spell_cooldowns.keys():
		spell_cooldowns[spell_id] = max(0.0, spell_cooldowns[spell_id] - delta)
	
	# Basic combo decay (Section 4.3 of plan.md)
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
	_update_flight_pose(delta)
	if hero_anim:
		hero_anim.tick(delta)
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

func _physics_process(delta: float) -> void:
	# World Boundaries & Safeguards: Infinite Fall Kill-Plane (Section 7.2 of plan.md).
	# Only the authority rescues a body: a client that rescued itself would be
	# teleporting somewhere the server never agreed to.
	if is_local_player and SimAuthority.is_authority() and global_position.y < -10.0:
		global_position = Vector3(0, 1.0, 5.0) # Courtyard Fountain
		velocity = Vector3.ZERO
		current_hp = max_hp
		_spawn_floating_text("Kadim Koruma Kalkanı Seni Kurtardı!", Color(0.3, 0.8, 1.0), 1.6)
		emit_stats()

	# Update decoupled camera pivot position & rotation smoothly
	if is_local_player and is_instance_valid(camera_pivot):
		camera_pivot.global_position = camera_pivot.global_position.lerp(global_position + Vector3(0, CAMERA_HEIGHT, 0), 1.0 - exp(-20.0 * delta))
		camera_pivot.rotation_degrees.y = camera_rot_y
		if spring_arm:
			spring_arm.rotation_degrees.x = camera_rot_x

	if not is_local_player:
		# Another player's body. On a client it is a view that follows the
		# replicated state; on the authority it is the REAL body, simulated here
		# from the input that player sent, so it falls through to the movement
		# code below like any other body.
		if sim_puppet:
			var prev_pos := global_position
			global_position = global_position.lerp(sim_target_pos, minf(1.0, 12.0 * delta))
			if visuals:
				visuals.rotation.y = lerp_angle(visuals.rotation.y, sim_target_rot, minf(1.0, 12.0 * delta))
			# Remote riders follow the replicated phase, not a local guess, so
			# every client shows the same animation phase for the same body.
			if is_mounted and sim_mount_phase > 0:
				if hero_anim:
					hero_anim.set_locomotion("mount%d" % sim_mount_phase, clip_for_mount_phase(sim_mount_phase))
			elif hero_anim:
				var moved_dist := (global_position - prev_pos).length()
				if moved_dist > 0.02:
					hero_anim.set_locomotion("remote_run", "Running_A")
				else:
					hero_anim.set_locomotion("remote_idle", "Idle")
			return
	
	if is_dead:
		velocity = Vector3.ZERO
		return
	_was_airborne = not is_on_floor() and not is_mounted
	# Gravity & Mounting
	if not is_on_floor() and not is_mounted:
		velocity.y -= gravity * delta
	elif is_mounted:
		var vertical := 0.0
		if not input_blocked():
			vertical = float(_intent_jump()) - float(_intent_descend())
		var ground := _ground_below(3.0)
		if not ground.is_empty() and global_position.y - ground.position.y < 1.4 and vertical >= 0:
			vertical = 0.5
		if global_position.y > 45.0:
			vertical = minf(vertical, -0.5)
		velocity.y = move_toward(velocity.y, vertical * 7.0, delta * 18.0)
	elif not input_blocked() and _intent_jump_edge():
		velocity.y = 8.0

	# Input direction relative to camera yaw
	var input_dir := _intent_move()

	var active_speed := mounted_speed if is_mounted else walk_speed
	var is_moving := input_dir.length_squared() > 0.01

	if is_moving:
		# Calculate movement vector relative to camera yaw
		var cam_yaw: float = deg_to_rad(_intent_yaw())
		var forward := Vector3(-sin(cam_yaw), 0, -cos(cam_yaw))
		var right := Vector3(cos(cam_yaw), 0, -sin(cam_yaw))
		var move_vector := (right * input_dir.x + forward * -input_dir.y).normalized()
		
		var acceleration := 25.0 if is_mounted else 65.0
		velocity.x = move_toward(velocity.x, move_vector.x * active_speed, acceleration * delta)
		velocity.z = move_toward(velocity.z, move_vector.z * active_speed, acceleration * delta)
		
		# Rotate ONLY visuals towards move direction (Camera remains independent!)
		var target_yaw := atan2(move_vector.x, move_vector.z)
		if _cast_lock <= 0.0:
			visuals.rotation.y = lerp_angle(visuals.rotation.y, target_yaw, minf(1, 14.0 * delta))
		
	else:
		velocity.x = move_toward(velocity.x, 0, active_speed * 12.0 * delta)
		velocity.z = move_toward(velocity.z, 0, active_speed * 12.0 * delta)

		# If holding right-click while standing, face camera direction
		if mouse_orbit_active:
			var cam_yaw: float = deg_to_rad(_intent_yaw())
			visuals.rotation.y = lerp_angle(visuals.rotation.y, cam_yaw, 10.0 * delta)

	move_and_slide()
	if is_local_player:
		_pos_history.append(global_position)
		if _pos_history.size() > MAX_POS_HISTORY:
			_pos_history.pop_front()
	_update_animation_state()

## The state machine half of the animation graph: it selects the clip, the graph
## blends it. States are named so a test can assert which one is active.
func _update_animation_state() -> void:
	if hero_anim == null:
		return
	if is_dead:
		hero_anim.set_locomotion("dead", "Death_A")
		return
	if _hit_recovery > 0.0:
		hero_anim.set_locomotion("stun", "Stun_Loop")
		return
	if is_mounted:
		var phase := sim_mount_phase if sim_puppet else mount_phase()
		hero_anim.set_locomotion("mount%d" % phase, clip_for_mount_phase(phase))
		return
	if not is_on_floor():
		hero_anim.set_locomotion("air_up", "Jump_Start" if velocity.y > 0.5 else "Fall")
		return
	if _was_airborne:
		hero_anim.play_oneshot("Land")
	var horizontal := Vector2(velocity.x, velocity.z).length()
	if horizontal < 0.25:
		hero_anim.set_locomotion("idle", "Idle")
		return
	var yaw := visuals.rotation.y
	var forward := Vector3(sin(yaw), 0, cos(yaw))
	var left := Vector3(cos(yaw), 0, -sin(yaw))
	var dir := Vector3(velocity.x, 0, velocity.z).normalized()
	var along := dir.dot(forward)
	var lateral := dir.dot(left)
	if along < -0.5:
		hero_anim.set_locomotion("walk_back", "Walk_Back")
	elif lateral > 0.5:
		hero_anim.set_locomotion("strafe_l", "Strafe_L")
	elif lateral < -0.5:
		hero_anim.set_locomotion("strafe_r", "Strafe_R")
	elif horizontal < walk_speed * 0.55:
		hero_anim.set_locomotion("walk", "Walk_A")
	else:
		hero_anim.set_locomotion("run", "Running_A")

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
	if input_blocked():
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

func _intent_jump_edge() -> bool:
	var jump := _intent_jump()
	var edge := jump and not _prev_jump
	_prev_jump = jump
	return edge

## The intent this client is sending upstream (SimNet calls this each input tick).
func sim_input_intent() -> Dictionary:
	return {
		"move": _intent_move(),
		"yaw": camera_rot_y,
		"jump": Input.is_action_pressed("jump") and not input_blocked(),
		"descend": Input.is_action_pressed("flight_descend") and not input_blocked(),
	}

func _handle_hotkeys() -> void:
	if Input.is_action_just_pressed("spell_1"):
		cast_spell("stupefy")
	elif Input.is_action_just_pressed("spell_2"):
		cast_spell("incendio")
	elif Input.is_action_just_pressed("spell_3"):
		cast_spell("bombarda")
	elif Input.is_action_just_pressed("spell_4"):
		cast_spell("expelliarmus")
	elif Input.is_action_just_pressed("spell_q"):
		cast_spell("protego")
	elif Input.is_action_just_pressed("spell_e"):
		cast_spell("ultimate")
	elif Input.is_action_just_pressed("mount_broom"):
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
			_spawn_floating_text(dismount_reason, Color(1, 0.7, 0.3))
			return
		_apply_mount_state(false)
	else:
		var mount_reason := mount_block_reason()
		if mount_reason != "":
			if _mount_notice_cd <= 0.0:
				_mount_notice_cd = 0.8
				_spawn_floating_text(mount_reason, Color(1, 0.7, 0.3))
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
		return "You are defeated!"
	if _hit_recovery > 0.0:
		return "You are stunned!"
	if _combat_until > 0.0:
		return "Not while in combat!"
	var record := SimAuthority.record_for(self)
	if not record.is_empty() and int(record.get("pending_transfer", 0)) != 0:
		return "The map is still loading!"
	if not is_on_floor():
		return "Take off from the ground!"
	var ground := _ground_below(1.2)
	if ground.is_empty() or ground.normal.dot(Vector3.UP) <= 0.7:
		return "The ground is too unstable to take off!"
	if not _flight_clearance_ok():
		return "Not enough room to take off here!"
	if not HPMaps.flight_allowed(current_map_id()):
		return "Flight is not allowed on this map!"
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
		return "Descend near level ground first (Ctrl)"
	var landing: Vector3 = ground.position
	var standing := _capsule_clear(landing + Vector3.UP * (CAPSULE_HEIGHT * 0.5 + 0.06))
	if not standing:
		return "No room to stand up here!"
	if not _ceiling_clear(landing, DISMOUNT_CEILING):
		return "The ceiling is too low to dismount!"
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
	# Phase 13 hook: any open panel that takes keyboard focus registers itself in
	# `UIFocus.GROUP` (client/scripts/ui/ui_focus.gd), so keys typed in a menu
	# cannot also cast a spell or mount the broom. Mouse clicks are consumed by
	# the Controls themselves before `_unhandled_input` ever sees them.
	if UIFocus.is_blocking(get_tree()):
		return true
	var world := get_parent().get_parent()
	for path in ["CanvasLayer/InventoryUI", "CanvasLayer/OllivanderUI"]:
		var panel := world.get_node_or_null(path) as Control
		if panel and panel.visible:
			return true
	return false

func _tick_regeneration(delta: float) -> void:
	var before := Vector2i(current_hp, current_mana)
	_regen_hp += 4.0 * delta
	_regen_mana += (10.0 if house == "Slytherin" else 8.0) * delta
	current_hp = mini(max_hp, current_hp + int(_regen_hp))
	current_mana = mini(max_mana, current_mana + int(_regen_mana))
	_regen_hp -= floorf(_regen_hp)
	_regen_mana -= floorf(_regen_mana)
	if before != Vector2i(current_hp, current_mana):
		emit_stats()

func _update_flight_pose(delta: float) -> void:
	_flight_time += delta
	_mount_blend = move_toward(_mount_blend, 1.0 if is_mounted else 0.0, delta * 3.2)
	if broom_mesh:
		broom_mesh.visible = _mount_blend > 0.01
	if broom:
		broom.set_flying(is_mounted)
		broom.tick(delta)
		if broom_mesh.visible:
			_align_broom_to_hips()
	# The rider sits on the saddle: lift the visuals by the seat height instead of
	# the old 0.15 m placeholder, so the boots clear the ground while hovering.
	visuals.position.y = _mount_blend * (0.34 + sin(_flight_time * 3.0) * 0.05)
	var speed_ratio := Vector2(velocity.x, velocity.z).length() / mounted_speed
	visuals.rotation.x = lerpf(visuals.rotation.x, -0.2 * speed_ratio * _mount_blend, minf(1, delta * 5))
	var turn := 0.0 if not is_local_player or input_blocked() else Input.get_axis("move_right", "move_left")
	# Rider lean is blended with acceleration and banking; the camera roll is a
	# restrained, configurable fraction of the same bank (plan Phase 9).
	var bank_target := turn * 0.22 * _mount_blend
	visuals.rotation.z = lerpf(visuals.rotation.z, bank_target, minf(1, delta * 5))
	_rider_roll = lerpf(_rider_roll, bank_target, minf(1, delta * 4))
	var roll_deg := clampf(rad_to_deg(_rider_roll), -camera_roll_limit, camera_roll_limit)
	if camera_pivot:
		camera_pivot.rotation_degrees.z = lerpf(camera_pivot.rotation_degrees.z, roll_deg, minf(1, delta * 3))

func restore_character(data: Dictionary) -> void:
	level = clampi(int(data.get("level", 1)), 1, 100)
	max_exp = 200
	for _i in range(level - 1):
		max_exp = mini(2000000000, int(max_exp * 1.5))
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
			if entry is Dictionary and entry.get("id") is String and GameData.ITEMS.has(entry.id):
				inventory.append({"id": entry.id, "amount": maxi(1, int(entry.get("amount", 1))), "tier": clampi(int(entry.get("tier", 0)), 0, 9)})
	_apply_wand_aura()
	_update_nameplate()
	inventory_changed.emit()
	emit_stats()

func get_mouse_aim_point() -> Vector3:
	if is_instance_valid(current_target) and CombatRules.can_damage(self, current_target):
		return current_target.global_position + Vector3.UP * TARGET_AIM_HEIGHT
	if not is_instance_valid(camera):
		return global_position + visuals.global_basis.z * 20.0 + Vector3.UP
	var mouse_pos := get_viewport().get_mouse_position()
	var origin := camera.project_ray_origin(mouse_pos)
	var ray := camera.project_ray_normal(mouse_pos)
	var query := PhysicsRayQueryParameters3D.create(origin, origin + ray * 100, 3)
	query.exclude = [get_rid()]
	var hit := get_world_3d().direct_space_state.intersect_ray(query)
	if not hit.is_empty():
		return hit.position + (Vector3.UP * 0.8 if hit.normal.y > 0.7 else Vector3.ZERO)
	return origin + ray * 40.0

func cast_spell(spell_id: String) -> void:
	if is_dead or not GameData.SPELLS.has(spell_id):
		return
	# Plan Phase 1: offensive casting is disabled while mounted (Protego is
	# defensive and stays available); airborne combat is a later feature.
	# Held basic-attack repeats every frame, so drop the held input and
	# throttle the feedback instead of spawning a node per frame.
	if is_mounted and spell_id != "protego":
		_basic_held = false
		if _mount_notice_cd <= 0.0:
			_mount_notice_cd = 1.0
			_spawn_floating_text("Not while mounted!", Color(1.0, 0.8, 0.4))
		return

	var s_data: Dictionary = GameData.SPELLS[spell_id]
	var remaining := maxf(_cast_lock, float(spell_cooldowns.get(spell_id, 0.0)))
	if remaining > 0:
		if remaining <= 0.25:
			_queued_spell = spell_id
			_queue_time = 0.3
		return
	_queued_spell = ""

	var cost: int = int(s_data.get("mana_cost", 0))
	if current_mana < cost:
		_spawn_floating_text("Not enough Mana!", Color(0.3, 0.6, 1.0))
		return

	# --- predicted feedback. The world server decides; everything below is the
	# client's guess at what it will say, and a rejection undoes it cleanly.
	var aim_hit := get_mouse_aim_point()
	var spawn_pos := global_position + Vector3(0, CAST_ORIGIN_HEIGHT, 0)
	var cast_dir := (aim_hit - spawn_pos).normalized()
	if cast_dir.length_squared() < 0.01:
		cast_dir = visuals.global_basis.z

	# Wizard instantly faces the mouse aim direction on ground
	var face_dir := (aim_hit - global_position)
	face_dir.y = 0.0
	if face_dir.length_squared() > 0.01:
		visuals.rotation.y = atan2(face_dir.x, face_dir.z)

	# Refined Basic Attack Chain (Section 4.3 of plan.md) - animation only; the
	# damage multiplier is the server's combo counter.
	var anim_name := "Spellcast_Shoot"
	if spell_id == "basic_cast":
		basic_combo_timer = 1.2
		if basic_combo_index == 0:
			anim_name = "Spellcast_Shoot"
			basic_combo_index = 1
		elif basic_combo_index == 1:
			anim_name = "Spellcast_Raise"
			basic_combo_index = 2
		else:
			anim_name = "1H_Melee_Attack_Chop"
			basic_combo_index = 0
			_spawn_floating_text("3-HIT COMBO!", Color(1.0, 0.85, 0.2), 1.4)

	_cast_lock = float(s_data.get("cast_lock", 0.28))
	_committed_until = maxf(_committed_until, float(COMMITTED_SPELLS.get(spell_id, 0.0)))
	if anim_name.begins_with("1H_Melee") or anim_name == "Melee_Chop_A":
		_committed_until = maxf(_committed_until, COMMITTED_MELEE)
	_cast_seq += 1
	_predicted_casts[_cast_seq] = {"spell_id": spell_id, "aim": aim_hit}
	_play_cast_animation(anim_name)
	if spell_id == "protego":
		_activate_protego_preview()
	# Phase 12 hook: predicted PRESENTATION only (wand flash + cast sound), keyed
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
		var cd := HPRules.cooldown_for(spell_id, house)
		if cd > 0.0:
			spell_cooldowns[spell_id] = cd
		emit_signal("spell_cast_signal", spell_id, cd)
		return
	# Phase 12 hook: a rejected cast removes its predicted feedback.
	preload("res://scripts/spells/skill_fx.gd").cancel_predicted(self, cast_seq)
	if spell_id == "protego":
		_clear_protego_preview()
	_cast_generation += 1
	is_casting_anim = false
	_committed_until = 0.0
	_reject_feedback(reason)

func _reject_feedback(reason: String) -> void:
	match reason:
		"no_mana":
			_spawn_floating_text("Not enough Mana!", Color(0.3, 0.6, 1.0))
		"cooldown":
			pass
		"mounted":
			_spawn_floating_text("Not while mounted!", Color(1.0, 0.8, 0.4))
		"protected":
			_spawn_floating_text("Protected ground!", Color(0.4, 0.8, 1.0))
		"dead":
			pass
		_:
			if reason != "" and reason != "queued" and reason != "sent":
				_spawn_floating_text("Cast refused", Color(1.0, 0.6, 0.4))

## Cast presentation. The upper-body clip is blended OVER locomotion (so a
## moving caster keeps their footwork), and the clip is seeked so its extension
## pose lands on the authority's release moment - `fx:wand_release` is only
## emitted then, never on a guessed frame.
func _play_cast_animation(anim_name: String = "Spellcast_Shoot") -> void:
	if hero_anim == null and not is_instance_valid(anim_player):
		return
	is_casting_anim = true
	_cast_generation += 1
	var generation := _cast_generation
	var upper := anim_name + "_Upper"
	var hold := 0.42
	if hero_anim:
		hero_anim.start_cast(upper if hero_anim.has_clip(upper) else anim_name, hold)
		hero_anim.align_cast(hold * 0.6, 0.45)
	elif anim_player:
		if anim_player.has_animation(anim_name):
			anim_player.play(anim_name, 0.08)
		elif anim_player.has_animation("Spellcast_Shoot"):
			anim_player.play("Spellcast_Shoot", 0.08)
	await get_tree().create_timer(hold * 0.6).timeout
	if animation_events.size() < 32:
		_on_animation_event("fx:wand_release")
	await get_tree().create_timer(hold * 0.4).timeout
	if generation == _cast_generation and not is_dead:
		is_casting_anim = false
		if hero_anim:
			hero_anim.end_cast()

func _activate_protego_preview() -> void:
	is_protego_active = true
	var p_shield = PROTEGO_SCENE.instantiate()
	p_shield.name = "ProtegoPreview"
	add_child(p_shield)
	p_shield.setup(self)
	_spawn_floating_text("PROTEGO!", Color(0.2, 0.8, 1.0), 1.2)

func _clear_protego_preview() -> void:
	is_protego_active = false
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
	elif actual_dmg > 0:
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
func apply_authoritative_position(pos: Vector3, rot_y: float) -> void:
	if not is_local_player:
		return

	if is_dead:
		global_position = pos
		velocity = Vector3.ZERO
		_pos_history.clear()
		return

	var direct_dist := global_position.distance_to(pos)

	# Massive displacement (teleport, respawn, map transfer, infinite fall rescue):
	# Snap immediately and clear trajectory history.
	if direct_dist > 6.0 or _pos_history.is_empty():
		global_position = pos
		velocity = Vector3.ZERO
		_pos_history.clear()
		if visuals:
			visuals.rotation.y = rot_y
		return

	# Find closest point along recent client trajectory to the authoritative position.
	# Because of network round-trip latency, `pos` naturally corresponds to where the
	# server simulated us tens to hundreds of milliseconds ago.
	var min_path_dist := 999999.0
	var closest_pt := global_position
	for pt in _pos_history:
		var d := pt.distance_to(pos)
		if d < min_path_dist:
			min_path_dist = d
			closest_pt = pt

	if direct_dist < min_path_dist:
		min_path_dist = direct_dist
		closest_pt = global_position

	var is_standing := velocity.length_squared() < 0.04 and _intent_move().length_squared() < 0.01

	if is_standing:
		# When standing still, client and server converge to the same point.
		if direct_dist > 2.0:
			global_position = pos
			velocity = Vector3.ZERO
			_pos_history.clear()
		elif direct_dist > 0.05:
			global_position = global_position.lerp(pos, 0.25)
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
	_spawn_floating_text("DEFEATED!", Color(1.0, 0.0, 0.0), 2.0)
	emit_stats()

func on_authoritative_respawn() -> void:
	global_position = HPRules.respawn_position()
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
	_spawn_floating_text("LEVEL UP! (Lv.%d)" % level, Color(1.0, 0.85, 0.2), 1.8)
	emit_stats()

## Authority stat mirror: the engine owns these numbers, the node displays them.
func apply_authoritative_stats(stats: Dictionary) -> void:
	current_hp = clampi(int(stats.get("hp", current_hp)), 0, maxi(1, int(stats.get("max_hp", max_hp))))
	max_hp = maxi(1, int(stats.get("max_hp", max_hp)))
	current_mana = clampi(int(stats.get("mana", current_mana)), 0, maxi(1, int(stats.get("max_mana", max_mana))))
	max_mana = maxi(1, int(stats.get("max_mana", max_mana)))
	current_exp = int(stats.get("exp", current_exp))
	max_exp = int(stats.get("max_exp", max_exp))
	level = int(stats.get("level", level))
	galleons = int(stats.get("galleons", galleons))
	var was_mounted := is_mounted
	var now_mounted := bool(stats.get("mounted", is_mounted))
	if was_mounted != now_mounted:
		_apply_mount_state(now_mounted)
	if bool(stats.get("dead", false)) != is_dead:
		if bool(stats.get("dead", false)):
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
	_spawn_floating_text("+%d EXP" % amount, Color(0.3, 1.0, 0.5), 1.2)

func add_loot(item_id: String, amount: int) -> void:
	if amount <= 0:
		return
	if item_id == "galleons":
		galleons += amount
		emit_signal("loot_collected_signal", "galleons", amount)
		inventory_changed.emit()
		return
	
	var found := false
	for item in inventory:
		if item.id == item_id:
			item.amount += amount
			found = true
			break
	if not found:
		inventory.append({"id": item_id, "amount": amount, "tier": 0})
	
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
	current_target = node
	emit_signal("target_changed", current_target)

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

func upgrade_wand(new_tier: int) -> void:
	wand_tier = clamp(new_tier, 0, 9)
	for item in inventory:
		if str(item.id).begins_with("wand_"):
			item.tier = wand_tier
	_apply_wand_aura()
	_spawn_floating_text("WAND REFINED TO +%d!" % wand_tier, Color(1.0, 0.9, 0.2), 1.6)
	inventory_changed.emit()

func _apply_wand_aura() -> void:
	if not wand_aura_particles:
		return
	var up_info = GameData.UPGRADE_TABLE.get(wand_tier, {})
	var aura_color: Color = up_info.get("aura", Color.TRANSPARENT)
	if wand_tier >= 4:
		wand_aura_particles.emitting = true
		wand_aura_particles.color = aura_color
		wand_aura_particles.amount = 20 if wand_tier < 7 else (40 if wand_tier < 9 else 70)
	else:
		wand_aura_particles.emitting = false

func _spawn_floating_text(text: String, col: Color, scale_mult: float = 1.0) -> void:
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
