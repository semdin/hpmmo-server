extends CharacterBody3D

## 3D Wizard Player Controller (Metin2 MMO Style)
## Decoupled 3rd-person camera, animated 3D wizard model, wand combat, broom mount, and Ollivander auras

signal stats_changed(hp: int, max_hp: int, mana: int, max_mana: int, exp: int, max_exp: int, level: int)
signal target_changed(target_node: Node3D)
signal spell_cast_signal(spell_id: String, cooldown: float)
signal loot_collected_signal(item_id: String, amount: int)
signal mounted_changed(is_mounted: bool)
signal inventory_changed

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
const CombatRules = preload("res://scripts/spells/combat_rules.gd")
const ParticleKit = preload("res://scripts/assets/particle_kit.gd")

# Node References
@onready var visuals: Node3D = get_node_or_null("Visuals")
@onready var anim_player: AnimationPlayer = _find_anim_player()
@onready var camera_pivot: Node3D = get_node_or_null("CameraPivot")
@onready var spring_arm: SpringArm3D = get_node_or_null("CameraPivot/SpringArm3D")
@onready var camera: Camera3D = get_node_or_null("CameraPivot/SpringArm3D/Camera3D")
@onready var broom_mesh: MeshInstance3D = get_node_or_null("Visuals/BroomMesh")
@onready var broom_particles: CPUParticles3D = get_node_or_null("Visuals/BroomMesh/BroomParticles")
@onready var wand_aura_particles: CPUParticles3D = get_node_or_null("Visuals/WandAuraParticles")
@onready var wand_tip: Marker3D = get_node_or_null("Visuals/WandTipMarker")
@onready var nameplate: Label3D = get_node_or_null("NameplateLabel3D")

func _find_anim_player() -> AnimationPlayer:
	if has_node("Visuals/wizard/AnimationPlayer"):
		return get_node("Visuals/wizard/AnimationPlayer") as AnimationPlayer
	var vis = get_node_or_null("Visuals")
	if vis:
		return vis.find_child("AnimationPlayer", true, false) as AnimationPlayer
	return null

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
		camera_pivot.global_position = global_position + Vector3(0, 1.4, 0)
		camera_pivot.rotation_degrees = Vector3(0, camera_rot_y, 0)
		spring_arm.rotation_degrees = Vector3(camera_rot_x, 0, 0)
		spring_arm.spring_length = camera_distance
	
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
	# Hide staff and closed spellbook, show 1H wand and cape
	var staff = visuals.get_node_or_null("wizard/Rig/Skeleton3D/handslot_r/2H_Staff")
	if staff:
		staff.hide()
	var spellbook = visuals.get_node_or_null("wizard/Rig/Skeleton3D/handslot_l/Spellbook")
	if spellbook:
		spellbook.hide()
	var spellbook_open = visuals.get_node_or_null("wizard/Rig/Skeleton3D/handslot_l/Spellbook_open")
	if spellbook_open:
		spellbook_open.hide()

func _apply_house_customization() -> void:
	if not GameData.HOUSES.has(house):
		return
	var h_data = GameData.HOUSES[house]
	var primary_col: Color = h_data.primary_color
	
	# Tint cape with Hogwarts house primary color
	var cape = visuals.get_node_or_null("wizard/Rig/Skeleton3D/chest/Mage_Cape")
	if cape and cape is MeshInstance3D:
		var mat = StandardMaterial3D.new()
		mat.albedo_color = primary_col
		mat.roughness = 0.5
		cape.set_surface_override_material(0, mat)
	
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
		camera_rot_y -= event.relative.x * 0.28
		camera_rot_x = clamp(camera_rot_x - event.relative.y * 0.25, -70.0, 25.0)

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
	_hit_recovery = maxf(0.0, _hit_recovery - delta)
	_mount_lock = maxf(0.0, _mount_lock - delta)
	_mount_notice_cd = maxf(0.0, _mount_notice_cd - delta)
	_queue_time = maxf(0.0, _queue_time - delta)
	_update_flight_pose(delta)
	if is_local_player and not is_dead:
		_tick_regeneration(delta)
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
	# World Boundaries & Safeguards: Infinite Fall Kill-Plane (Section 7.2 of plan.md)
	if is_local_player and global_position.y < -10.0:
		global_position = Vector3(0, 1.0, 5.0) # Courtyard Fountain
		velocity = Vector3.ZERO
		current_hp = max_hp
		_spawn_floating_text("Kadim Koruma Kalkanı Seni Kurtardı!", Color(0.3, 0.8, 1.0), 1.6)
		emit_stats()

	# Update decoupled camera pivot position & rotation smoothly
	if is_local_player and is_instance_valid(camera_pivot):
		camera_pivot.global_position = camera_pivot.global_position.lerp(global_position + Vector3(0, 1.4, 0), 1.0 - exp(-20.0 * delta))
		camera_pivot.rotation_degrees.y = camera_rot_y
		if spring_arm:
			spring_arm.rotation_degrees.x = camera_rot_x
	
	if not is_local_player:
		var peer_id := name.to_int()
		if peer_id > 0 and NetworkManager.remote_states.has(peer_id):
			var r_state: Dictionary = NetworkManager.remote_states[peer_id]
			var prev_pos := global_position
			global_position = global_position.lerp(r_state.get("pos", global_position), 15.0 * delta)
			visuals.rotation.y = lerp_angle(visuals.rotation.y, r_state.get("rot_y", visuals.rotation.y), 15.0 * delta)
			
			var rem_mounted: bool = r_state.get("mounted", false)
			if is_mounted != rem_mounted:
				is_mounted = rem_mounted
				if broom_mesh:
					broom_mesh.visible = is_mounted
				if broom_particles:
					broom_particles.emitting = is_mounted
			
			var rem_hp: int = r_state.get("hp", current_hp)
			var rem_lvl: int = r_state.get("level", level)
			if current_hp != rem_hp or level != rem_lvl:
				current_hp = rem_hp
				level = rem_lvl
				_update_nameplate()
			
			if not is_casting_anim and _hit_recovery <= 0 and is_instance_valid(anim_player):
				var moved_dist := (global_position - prev_pos).length()
				if moved_dist > 0.02 and not is_mounted:
					if anim_player.current_animation != "Running_A":
						anim_player.play("Running_A", 0.2)
				else:
					var remote_idle := "Sit_Chair_Idle" if is_mounted else "Idle"
					if anim_player.current_animation != remote_idle:
						anim_player.play(remote_idle, 0.35)
		return
	
	if is_dead:
		velocity = Vector3.ZERO
		return
	# Gravity & Mounting
	if not is_on_floor() and not is_mounted:
		velocity.y -= gravity * delta
	elif is_mounted:
		var vertical := 0.0
		if not input_blocked():
			vertical = float(Input.is_action_pressed("jump")) - float(Input.is_action_pressed("flight_descend"))
		var ground := _ground_below(3.0)
		if not ground.is_empty() and global_position.y - ground.position.y < 1.4 and vertical >= 0:
			vertical = 0.5
		if global_position.y > 45.0:
			vertical = minf(vertical, -0.5)
		velocity.y = move_toward(velocity.y, vertical * 7.0, delta * 18.0)
	elif not input_blocked() and Input.is_action_just_pressed("jump"):
		velocity.y = 8.0
	
	# Input direction relative to camera yaw
	var input_dir := Vector2.ZERO
	if Input.is_action_pressed("move_forward"):
		input_dir.y -= 1
	if Input.is_action_pressed("move_backward"):
		input_dir.y += 1
	if Input.is_action_pressed("move_left"):
		input_dir.x -= 1
	if Input.is_action_pressed("move_right"):
		input_dir.x += 1
	input_dir = Vector2.ZERO if input_blocked() else input_dir.normalized()
	
	var active_speed := mounted_speed if is_mounted else walk_speed
	var is_moving := input_dir.length_squared() > 0.01
	
	if is_moving:
		# Calculate movement vector relative to camera yaw
		var cam_yaw: float = deg_to_rad(camera_rot_y)
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
		
		if not is_casting_anim and _hit_recovery <= 0 and is_instance_valid(anim_player):
			var run_anim := "Running_A" if not is_mounted else "Sit_Chair_Idle"
			if anim_player.current_animation != run_anim:
				anim_player.play(run_anim, 0.2)
	else:
		velocity.x = move_toward(velocity.x, 0, active_speed * 12.0 * delta)
		velocity.z = move_toward(velocity.z, 0, active_speed * 12.0 * delta)
		
		# If holding right-click while standing, face camera direction
		if mouse_orbit_active:
			var cam_yaw: float = deg_to_rad(camera_rot_y)
			visuals.rotation.y = lerp_angle(visuals.rotation.y, cam_yaw, 10.0 * delta)
		
		if not is_casting_anim and _hit_recovery <= 0 and is_instance_valid(anim_player):
			var idle_anim := "Sit_Chair_Idle" if is_mounted else "Idle"
			if anim_player.current_animation != idle_anim:
				anim_player.play(idle_anim, 0.35)
	
	move_and_slide()

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
		if not can_dismount_safely():
			_spawn_floating_text("Descend near the ground first (Ctrl)", Color(1, 0.7, 0.3))
			return
		is_mounted = false
	else:
		if not is_on_floor():
			return
		is_mounted = true
		velocity.y = 3.0
	if broom_particles:
		broom_particles.emitting = is_mounted
	_basic_held = false
	_mount_lock = 0.3
	emit_signal("mounted_changed", is_mounted)

func _ground_below(distance: float) -> Dictionary:
	var query := PhysicsRayQueryParameters3D.create(global_position + Vector3.UP * 0.1, global_position - Vector3.UP * distance, 1)
	return get_world_3d().direct_space_state.intersect_ray(query)

func can_dismount_safely() -> bool:
	var ground := _ground_below(3.0)
	if ground.is_empty() or ground.normal.dot(Vector3.UP) <= 0.7:
		return false
	# Reject landings without capsule clearance (low ceilings, walls, props).
	var shape := CapsuleShape3D.new()
	shape.radius = 0.45
	shape.height = 1.8
	var query := PhysicsShapeQueryParameters3D.new()
	query.shape = shape
	query.transform = Transform3D(Basis(), ground.position + Vector3.UP * 0.91)
	query.collision_mask = 1
	query.exclude = [get_rid()]
	return get_world_3d().direct_space_state.intersect_shape(query, 1).is_empty()

func input_blocked() -> bool:
	var focus := get_viewport().gui_get_focus_owner()
	if focus is LineEdit or focus is TextEdit:
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
	visuals.position.y = _mount_blend * (0.15 + sin(_flight_time * 3.0) * 0.06)
	var speed_ratio := Vector2(velocity.x, velocity.z).length() / mounted_speed
	visuals.rotation.x = lerpf(visuals.rotation.x, -0.2 * speed_ratio * _mount_blend, minf(1, delta * 5))
	var turn := 0.0 if not is_local_player or input_blocked() else Input.get_axis("move_right", "move_left")
	visuals.rotation.z = lerpf(visuals.rotation.z, turn * 0.22 * _mount_blend, minf(1, delta * 5))

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
		return current_target.global_position + Vector3.UP
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
	
	var cost: int = s_data.mana_cost
	if current_mana < cost:
		_spawn_floating_text("Not enough Mana!", Color(0.3, 0.6, 1.0))
		return
	
	_cast_lock = 0.18 if spell_id == "basic_cast" else 0.28
	current_mana -= cost
	var cd: float = s_data.cooldown
	if house == "Ravenclaw":
		cd *= 0.8
	spell_cooldowns[spell_id] = cd
	
	emit_signal("spell_cast_signal", spell_id, cd)
	emit_stats()
	
	# Mouse-Aim Raycast & Skillshot Direction (Section 4.1 & 4.2 of plan.md)
	var aim_hit := get_mouse_aim_point()
	var spawn_pos := global_position + Vector3(0, 1.2, 0)
	var cast_dir := (aim_hit - spawn_pos).normalized()
	if cast_dir.length_squared() < 0.01:
		cast_dir = visuals.global_basis.z
	
	# Wizard instantly faces the mouse aim direction on ground
	var face_dir := (aim_hit - global_position)
	face_dir.y = 0.0
	if face_dir.length_squared() > 0.01:
		visuals.rotation.y = atan2(face_dir.x, face_dir.z)
	
	# Refined Basic Attack Chain (Section 4.3 of plan.md)
	var anim_name := "Spellcast_Shoot"
	var combo_mult := 1.0
	if spell_id == "basic_cast":
		basic_combo_timer = 1.2
		if basic_combo_index == 0:
			anim_name = "Spellcast_Shoot"
			combo_mult = 1.0
			basic_combo_index = 1
		elif basic_combo_index == 1:
			anim_name = "Spellcast_Raise"
			combo_mult = 1.15
			basic_combo_index = 2
		else:
			anim_name = "1H_Melee_Attack_Chop"
			combo_mult = 1.5
			basic_combo_index = 0
			_spawn_floating_text("3-HIT COMBO!", Color(1.0, 0.85, 0.2), 1.4)
	
	_play_cast_animation(anim_name)
	
	# Multipliers
	var upgrade_info = GameData.UPGRADE_TABLE.get(wand_tier, {})
	var damage_mult: float = upgrade_info.get("multiplier", 1.0) * combo_mult
	if house == "Gryffindor" and spell_id == "incendio":
		damage_mult *= 1.15
	elif house == "Slytherin" and (spell_id == "ultimate" or spell_id == "expelliarmus"):
		damage_mult *= 1.20
	
	if spell_id == "protego":
		_activate_protego()
	elif spell_id == "incendio":
		preload("res://scripts/spells/skill_fx.gd").play_cast(get_parent(), self, spell_id, spawn_pos, cast_dir)
		for enemy in get_tree().get_nodes_in_group("targetable"):
			if not CombatRules.can_damage(self, enemy):
				continue
			var offset: Vector3 = enemy.global_position + Vector3.UP - spawn_pos
			if offset.length() <= float(s_data.get("range", 18)) and cast_dir.dot(offset.normalized()) >= cos(deg_to_rad(30)) and CombatRules.has_line_of_sight(self, enemy):
				enemy.take_damage(int(s_data.damage * damage_mult), spell_id, self)
		NetworkManager.broadcast_spell(spell_id, spawn_pos, cast_dir)
	else:
		var proj = PROJECTILE_SCENE.instantiate()
		get_parent().add_child(proj)
		proj.global_position = spawn_pos
		proj.setup(self, spell_id, cast_dir, null, damage_mult)
		
		# Replicate spell launch in multiplayer
		NetworkManager.broadcast_spell(spell_id, spawn_pos, cast_dir)

func _play_cast_animation(anim_name: String = "Spellcast_Shoot") -> void:
	if not is_instance_valid(anim_player):
		return
	is_casting_anim = true
	_cast_generation += 1
	var generation := _cast_generation
	if anim_player.has_animation(anim_name):
		anim_player.play(anim_name, 0.08)
	else:
		anim_player.play("Spellcast_Shoot", 0.08)
	await get_tree().create_timer(0.35).timeout
	if generation == _cast_generation and not is_dead:
		is_casting_anim = false

func _activate_protego() -> void:
	is_protego_active = true
	var p_shield = PROTEGO_SCENE.instantiate()
	add_child(p_shield)
	p_shield.setup(self)
	_spawn_floating_text("PROTEGO!", Color(0.2, 0.8, 1.0), 1.2)
	await get_tree().create_timer(3.5).timeout
	is_protego_active = false

func take_damage(amount: int, spell_type: String, attacker: Node3D) -> void:
	if is_dead or not is_local_player:
		return
	var actual_dmg := maxi(0, amount)
	if is_protego_active:
		actual_dmg = int(amount * 0.4)
		_spawn_floating_text("BLOCKED 60%!", Color(0.3, 0.7, 1.0))
	
	current_hp = max(0, current_hp - actual_dmg)
	_spawn_floating_text(str(actual_dmg), Color(1.0, 0.2, 0.2), 1.3)
	
	if is_instance_valid(anim_player) and not is_casting_anim and current_hp > 0:
		anim_player.play("Hit_A", 0.1)
		_hit_recovery = 0.22
	
	emit_stats()
	if current_hp <= 0:
		_die()

func _die() -> void:
	is_dead = true
	is_casting_anim = true
	_cast_generation += 1
	_queued_spell = ""
	_basic_held = false
	is_mounted = false
	if broom_particles:
		broom_particles.emitting = false
	mounted_changed.emit(false)
	velocity = Vector3.ZERO
	if is_instance_valid(anim_player):
		anim_player.play("Death_A", 0.1)
	_spawn_floating_text("DEFEATED!", Color(1.0, 0.0, 0.0), 2.0)
	await get_tree().create_timer(2.5).timeout
	global_position = Vector3(0, 0.5, 5.0)
	current_hp = max_hp
	current_mana = max_mana
	is_dead = false
	is_casting_anim = false
	if is_instance_valid(anim_player):
		anim_player.play("Idle", 0.2)
	emit_stats()

func add_exp(amount: int) -> void:
	current_exp += amount
	_spawn_floating_text("+%d EXP" % amount, Color(0.3, 1.0, 0.5), 1.2)
	while current_exp >= max_exp:
		current_exp -= max_exp
		level += 1
		max_exp = mini(2000000000, int(max_exp * 1.5))
		max_hp += 40
		current_hp = max_hp
		max_mana += 25
		current_mana = max_mana
		_update_nameplate()
		_spawn_floating_text("LEVEL UP! (Lv.%d)" % level, Color(1.0, 0.85, 0.2), 1.8)
	emit_stats()

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
	var min_dist: float = 7.0
	for loot in loot_nodes:
		if is_instance_valid(loot):
			var dist = global_position.distance_to(loot.global_position)
			if dist < min_dist:
				min_dist = dist
				nearest_loot = loot
	if nearest_loot and nearest_loot.has_method("collect"):
		nearest_loot.collect(self)

func cycle_nearest_target() -> void:
	var targets: Array[Node3D] = []
	for target in get_tree().get_nodes_in_group("targetable"):
		if CombatRules.can_damage(self, target) and global_position.distance_to(target.global_position) < 35:
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
		ft.global_position = global_position + Vector3(0, 2.2, 0)
		ft.setup(text, col, scale_mult)

## Public single-line feedback hook (potions, UI events).
func show_floating_text(text: String, col: Color, scale_mult: float = 1.0) -> void:
	_spawn_floating_text(text, col, scale_mult)

func emit_stats() -> void:
	emit_signal("stats_changed", current_hp, max_hp, current_mana, max_mana, current_exp, max_exp, level)
