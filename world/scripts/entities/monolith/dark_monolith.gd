extends StaticBody3D

const MaterialKitScript = preload("res://scripts/assets/material_kit.gd")

## Dark Monolith - Metin2 Stone equivalent in the Harry Potter MMO
## A towering cursed obelisk that spawns aggressive waves of dark creatures as its HP is chipped away.
## On destruction, it drops massive loot (Galleons, Phoenix Ashes, Dragon Cores, Potions).

signal monolith_damaged(current_hp: int, max_hp: int)
signal monolith_destroyed

@export var max_hp: int = 3000
var current_hp: int = 3000
var _respawn_timer: Timer = null
var _base_albedo := Color(0.15, 0.05, 0.2)

var wave1_triggered: bool = false
var wave2_triggered: bool = false
var wave3_triggered: bool = false
var is_destroyed: bool = false

@onready var mesh: MeshInstance3D = $MeshInstance3D
@onready var hp_label: Label3D = $HpLabel3D
@onready var aura_particles: CPUParticles3D = $AuraParticles
@onready var dark_light: OmniLight3D = $OmniLight3D

const ACROMANTULA_SCENE = preload("res://scenes/entities/mobs/mob_acromantula.tscn")
const INFERI_SCENE = preload("res://scenes/entities/mobs/mob_inferi.tscn")
const SNATCHER_SCENE = preload("res://scenes/entities/mobs/mob_darksnatcher.tscn")
const LOOT_SCENE = preload("res://scenes/entities/loot/loot_drop.tscn")

func _ready() -> void:
	add_to_group("monoliths")
	add_to_group("targetable")
	current_hp = max_hp
	if mesh.get_active_material(0):
		mesh.material_override = mesh.get_active_material(0).duplicate()
	var base_mat := mesh.material_override as StandardMaterial3D
	if base_mat:
		_base_albedo = base_mat.albedo_color
	_add_sky_beam()
	_update_label()

func _update_label() -> void:
	if hp_label:
		var pct := int((float(current_hp) / float(max_hp)) * 100.0)
		hp_label.text = "Dark Monolith (Lv.35)\n%d / %d (%d%%)" % [current_hp, max_hp, pct]
		if pct > 50:
			hp_label.modulate = Color(0.9, 0.4, 1.0)
		elif pct > 25:
			hp_label.modulate = Color(1.0, 0.5, 0.2)
		else:
			hp_label.modulate = Color(1.0, 0.2, 0.2)

func take_damage(amount: int, spell_type: String, attacker: Node3D) -> void:
	if is_destroyed:
		return
	if has_node("/root/AudioManager"):
		get_node("/root/AudioManager").play_hit()
	
	current_hp = max(0, current_hp - amount)
	_update_label()
	emit_signal("monolith_damaged", current_hp, max_hp)
	
	# Flash mesh on hit
	_flash_red()
	
	# Check wave milestones
	var ratio := float(current_hp) / float(max_hp)
	if ratio <= 0.75 and not wave1_triggered:
		wave1_triggered = true
		_spawn_wave.call_deferred(1, attacker)
	if ratio <= 0.50 and not wave2_triggered:
		wave2_triggered = true
		_spawn_wave.call_deferred(2, attacker)
	if ratio <= 0.25 and not wave3_triggered:
		wave3_triggered = true
		_spawn_wave.call_deferred(3, attacker)
	
	if current_hp <= 0:
		_destroy_monolith(attacker)

func _flash_red() -> void:
	if not mesh:
		return
	var mat: StandardMaterial3D = mesh.get_active_material(0)
	if mat == null:
		return
	mat.albedo_color = Color(1.0, 0.2, 0.3)
	# Tween instead of await: the tween is bound to this node, so no coroutine
	# can resume on a freed instance after a scene change, and the authored
	# albedo is restored instead of a hardcoded colour.
	var tw := create_tween()
	tw.tween_interval(0.08)
	tw.tween_callback(func():
		if is_instance_valid(mat):
			mat.albedo_color = _base_albedo
	)

func _spawn_wave(wave_num: int, target_player: Node3D) -> void:
	# Zone notification
	NetworkManager.send_chat("[Dark Monolith] A wave of dark creatures emerges from the ground! (Wave %d/3)" % wave_num)
	
	# Visual burst
	if dark_light:
		dark_light.light_energy = 8.0
	
	var mob_configs := []
	if wave_num == 1:
		mob_configs = [
			{"scene": ACROMANTULA_SCENE, "count": 3},
			{"scene": INFERI_SCENE, "count": 2}
		]
	elif wave_num == 2:
		mob_configs = [
			{"scene": INFERI_SCENE, "count": 4},
			{"scene": SNATCHER_SCENE, "count": 2}
		]
	else:
		mob_configs = [
			{"scene": ACROMANTULA_SCENE, "count": 4},
			{"scene": INFERI_SCENE, "count": 4},
			{"scene": SNATCHER_SCENE, "count": 2}
		]
	
	for group in mob_configs:
		var scene_res: PackedScene = group["scene"]
		var count: int = group["count"]
		for i in range(count):
			var mob = scene_res.instantiate()
			var angle := randf() * TAU
			var dist := randf_range(4.0, 9.0)
			var spawn_pos := global_position + Vector3(cos(angle) * dist, 0.5, sin(angle) * dist)
			mob.position = get_parent().to_local(spawn_pos)
			mob.summoned = true
			mob.pack_anchor = spawn_pos
			mob.pack_id = int(get_instance_id())
			get_parent().add_child(mob)
			# Immediate aggro onto attacking player (Metin2 pack aggro)
			if is_instance_valid(target_player) and mob.has_method("aggro_on"):
				mob.aggro_on(target_player, true)

func _destroy_monolith(shatterer: Node3D) -> void:
	is_destroyed = true
	emit_signal("monolith_destroyed")
	if has_node("/root/QuestManager"):
		QuestManager.add_monolith()
	
	var shatterer_name := "A brave Wizard"
	if is_instance_valid(shatterer) and "player_name" in shatterer:
		shatterer_name = shatterer.player_name
		if shatterer.has_method("add_exp"):
			shatterer.add_exp(850)
	
	NetworkManager.send_chat("[Server] The Dark Monolith has been shattered by %s! Riches shower the realm!" % shatterer_name)
	
	# Shower massive loot around monolith base
	_drop_loot.call_deferred()
	
	# Disappear & schedule respawn through a child timer: it is freed with this
	# node, so a scene change can never resume a coroutine on a freed instance.
	hide()
	$CollisionShape3D.set_deferred("disabled", true)
	if _respawn_timer:
		_respawn_timer.queue_free()
	_respawn_timer = Timer.new()
	_respawn_timer.one_shot = true
	_respawn_timer.wait_time = 30.0
	_respawn_timer.timeout.connect(_respawn)
	add_child(_respawn_timer)
	_respawn_timer.start()

func _drop_loot() -> void:
	var drops := [
		{"id": "galleons", "amount": randi_range(600, 1800)},
		{"id": "galleons", "amount": randi_range(400, 1200)},
		{"id": "mat_phoenix_ash", "amount": randi_range(2, 4)},
		{"id": "mat_dragon_heartstring", "amount": randi_range(1, 3)},
		{"id": "mat_thestral_hair", "amount": randi_range(1, 2)},
		{"id": "potion_health", "amount": randi_range(3, 6)},
		{"id": "potion_mana", "amount": randi_range(3, 6)},
	]
	
	# 25% chance of rare Elder core
	if randf() < 0.25:
		drops.append({"id": "mat_elder_core", "amount": 1})
	
	for drop_data in drops:
		var loot = LOOT_SCENE.instantiate()
		get_parent().add_child(loot)
		var angle := randf() * TAU
		var dist := randf_range(2.0, 7.5)
		loot.global_position = global_position + Vector3(cos(angle) * dist, 0.4, sin(angle) * dist)
		loot.setup(drop_data["id"], drop_data["amount"])

func _respawn() -> void:
	if is_queued_for_deletion():
		return
	if _respawn_timer:
		_respawn_timer.queue_free()
		_respawn_timer = null
	current_hp = max_hp
	wave1_triggered = false
	wave2_triggered = false
	wave3_triggered = false
	is_destroyed = false
	show()
	$CollisionShape3D.set_deferred("disabled", false)
	_update_label()
	NetworkManager.send_chat("[Dark Monolith] A new Dark Monolith has manifested in the realm!")

func _add_sky_beam() -> void:
	# tall purple beacon so players can find world bosses from anywhere
	var beam := MeshInstance3D.new()
	beam.name = "SkyBeam"
	var cm := CylinderMesh.new()
	cm.top_radius = 0.08
	cm.bottom_radius = 0.18
	cm.height = 32.0
	var bm := StandardMaterial3D.new()
	bm.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	bm.albedo_color = Color(0.55, 0.28, 0.85, 0.14)
	bm.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	cm.material = bm
	beam.mesh = cm
	beam.position = Vector3(0, 16, 0)
	add_child(beam)
	# floating rune rocks orbiting base
	for i in range(5):
		var rock := MeshInstance3D.new()
		var rm := BoxMesh.new()
		rm.size = Vector3(0.5, 0.5, 0.5)
		rm.material = 	MaterialKitScript.obsidian_material()
		rock.mesh = rm
		var ang := TAU * float(i) / 5.0
		rock.position = Vector3(cos(ang) * 2.4, 0.6, sin(ang) * 2.4)
		rock.set_meta("orbit_ang", ang)
		rock.set_meta("orbit_speed", randf_range(0.5, 1.0))
		rock.add_to_group("monolith_orbits")
		add_child(rock)

func _process(delta: float) -> void:
	for child in get_children():
		if child.is_in_group("monolith_orbits") and child is MeshInstance3D:
			var ang: float = child.get_meta("orbit_ang") + delta * float(child.get_meta("orbit_speed"))
			child.set_meta("orbit_ang", ang)
			child.position = Vector3(cos(ang) * 2.4, 0.6 + sin(Time.get_ticks_msec() * 0.002 + ang) * 0.3, sin(ang) * 2.4)
			child.rotation.y += delta * 2.0
