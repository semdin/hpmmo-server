extends StaticBody3D

## Dark Monolith - Metin2 Stone equivalent in the Harry Potter MMO
## A towering cursed obelisk that spawns aggressive waves of dark creatures as its HP is chipped away.
## On destruction, it drops massive loot (Galleons, Phoenix Ashes, Dragon Cores, Potions).

signal monolith_damaged(current_hp: int, max_hp: int)
signal monolith_destroyed

## spawn_tables.json monolith_types key: "dark" (the grounds' Dark Monolith)
## or "spider" (the Webbound Seal Stone of the Blackweb Caverns). The type
## decides name, level, health, reward, waves, loot and respawn.
@export var monolith_type := "dark"
@export var glow := Color(0.35, 1.0, 0.45)
@export var max_hp: int = 3000
var _cfg: Dictionary = {}
var current_hp: int = 3000
var _respawn_timer: Timer = null
var _base_albedo := Color(0.15, 0.05, 0.2)

## Where the stone was authored (spawn_tables.json). Every stone - the first
## and each one after a shatter - comes down somewhere within `roam` metres of
## it (the type's `roam`, else 30 m outside / 12 m in the caverns).
var home := Vector3.ZERO

var wave1_triggered: bool = false
var wave2_triggered: bool = false
var wave3_triggered: bool = false
var is_destroyed: bool = false

## The carved Dark Mark standing stone (art/monolith: gpt-image -> Hunyuan ->
## prop_prepare). The emerald runes and cracks are painted into its albedo;
## the breathing glow is the green light, not emission (an emission map lit
## the whole stone).
@onready var mesh: MeshInstance3D = $Model.find_children("*", "MeshInstance3D", true, false)[0]
@onready var hp_label: Label3D = $HpLabel3D
@onready var aura_particles: CPUParticles3D = $AuraParticles
@onready var dark_light: OmniLight3D = $OmniLight3D

const ACROMANTULA_SCENE = preload("res://scenes/entities/mobs/mob_acromantula.tscn")
const INFERI_SCENE = preload("res://scenes/entities/mobs/mob_inferi.tscn")
const SNATCHER_SCENE = preload("res://scenes/entities/mobs/mob_darksnatcher.tscn")
const SKILL_FX = preload("res://scripts/spells/skill_fx.gd")
const LOOT_SCENE = preload("res://scenes/entities/loot/loot_drop.tscn")

func _ready() -> void:
	add_to_group("monoliths")
	add_to_group("targetable")
	_cfg = HPRules.monolith_type(monolith_type)
	max_hp = int(_cfg.get("max_hp", max_hp))
	current_hp = max_hp
	if mesh.get_active_material(0):
		mesh.material_override = mesh.get_active_material(0).duplicate()
	var base_mat := mesh.material_override as StandardMaterial3D
	if base_mat:
		_base_albedo = base_mat.albedo_color
	if aura_particles:
		# Soft motes, not bare quads.
		var mote := aura_particles.mesh.surface_get_material(0) as StandardMaterial3D if aura_particles.mesh else null
		if mote:
			mote.albedo_texture = load("res://assets/vfx/spark_01.png")
	_add_sky_beam()
	_update_label()
	if SimAuthority.is_authority():
		# Registered as a killable entity with its own reward, so the shatterer's
		# EXP is paid exactly once through the normal reward path.
		SimAuthority.register(HPProtocol.Kind.MONOLITH, self, {
			"hp": current_hp, "max_hp": max_hp, "exp_reward": int(_cfg.get("exp_reward", 850)),
			"name": display_name(), "level": int(_cfg.get("level", 35)),
			"loot_table": String(_cfg.get("loot_table", "monolith")),
			# The body clients draw (HPProtocol.MOB_SCENES; 0 = the Dark Monolith).
			"variant": HPProtocol.MOB_VARIANT_SPIDER_STONE if scene_file_path == HPProtocol.mob_scene(HPProtocol.MOB_VARIANT_SPIDER_STONE) else 0,
		})

func _update_label() -> void:
	if hp_label:
		var pct := int((float(current_hp) / float(max_hp)) * 100.0)
		hp_label.text = "%s (Lv.%d)\n%d / %d (%d%%)" % [I18n.t(display_name()), int(_cfg.get("level", 35)), current_hp, max_hp, pct]
		if pct > 50:
			hp_label.modulate = Color(0.45, 1.0, 0.55)
		elif pct > 25:
			hp_label.modulate = Color(1.0, 0.5, 0.2)
		else:
			hp_label.modulate = Color(1.0, 0.2, 0.2)
		WorldLabels.track(hp_label, 16.0)

## Damage is resolved by the authority; this node reacts to the result. The wave
## thresholds are a consequence of the authoritative HP, so two clients can never
## disagree about how many waves have spawned.
func take_damage(amount: int, spell_type: String, attacker: Node3D) -> void:
	if is_destroyed:
		return
	SimAuthority.apply_damage(self, amount, spell_type, attacker)

func on_authoritative_damage(_spell: String, attacker: Node3D, _stun_ms: int, _weaken_ms: int) -> void:
	if is_destroyed:
		return
	if has_node("/root/AudioManager"):
		get_node("/root/AudioManager").play_hit()
	_update_label()
	emit_signal("monolith_damaged", current_hp, max_hp)
	_flash_red()
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

func on_authoritative_death(attacker: Node3D) -> void:
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
	NetworkManager.system_chat("%s: a wave of creatures answers its call! (Wave %d/3)" % [display_name(), wave_num])
	
	# Visual burst
	_burst = 6.0
	
	# Wave composition, spawn scatter and mob levels are server-owned data; the
	# authority's seeded RNG decides them so every client sees the same wave.
	var config: Dictionary = _cfg
	var thresholds: Array = config.get("wave_thresholds", [])
	var scenes: Dictionary = HPRules.spawn_tables().get("mob_scenes", {})
	var wave_entry: Dictionary = {}
	for entry in thresholds:
		if int(entry.get("wave", 0)) == wave_num:
			wave_entry = entry
			break
	var rng := SimAuthority.rng
	var dist_min := float(config.get("spawn_distance_min", 4.0))
	var dist_max := float(config.get("spawn_distance_max", 9.0))
	for group in wave_entry.get("spawns", []):
		var scene_res: PackedScene = load(String(scenes.get(String(group.get("mob", "")), "")))
		if scene_res == null:
			continue
		for _i in range(int(group.get("count", 0))):
			var mob = scene_res.instantiate()
			var angle := rng.randf() * TAU
			var dist := rng.randf_range(dist_min, dist_max)
			var spawn_pos := global_position + Vector3(cos(angle) * dist, 0.5, sin(angle) * dist)
			var ground := _ground_y(spawn_pos)
			if not is_nan(ground):
				spawn_pos.y = ground + 0.3
			mob.position = get_parent().to_local(spawn_pos)
			mob.summoned = true
			mob.level = int(group.get("level", 12))
			mob.pack_anchor = spawn_pos
			mob.pack_id = int(get_instance_id())
			mob.spawn_point = spawn_pos
			get_parent().add_child(mob)
			SimAuthority.register_mob(mob, mob.pack_id, String(HPRules.zone_id_for(spawn_pos)))
			# Immediate aggro onto attacking player (Metin2 pack aggro)
			if is_instance_valid(target_player) and mob.has_method("aggro_on"):
				mob.aggro_on(target_player, true)

func _destroy_monolith(shatterer: Node3D) -> void:
	is_destroyed = true
	emit_signal("monolith_destroyed")
	_shatter_fx()

	var shatterer_name := "A brave Wizard"  # i18n
	if is_instance_valid(shatterer) and "player_name" in shatterer:
		shatterer_name = shatterer.player_name
	# EXP and the loot shower are granted by the authority (one reward per kill);
	# this node only reports the event to the players nearby.
	NetworkManager.system_chat("The %s has been shattered by %s! Riches shower the realm!" % [display_name(), shatterer_name])

	# Disappear & schedule respawn through a child timer: it is freed with this
	# node, so a scene change can never resume a coroutine on a freed instance.
	hide()
	$CollisionShape3D.set_deferred("disabled", true)
	if _respawn_timer:
		_respawn_timer.queue_free()
	_respawn_timer = Timer.new()
	_respawn_timer.one_shot = true
	_respawn_timer.wait_time = float(_cfg.get("respawn_ms", 30000)) / 1000.0
	_respawn_timer.timeout.connect(_respawn)
	add_child(_respawn_timer)
	_respawn_timer.start()

## The stone bursting into shards (eyes only: never on the dedicated server).
func _shatter_fx() -> void:
	if NetworkManager.is_dedicated_server or not is_inside_tree() or get_parent() == null:
		return
	var shape := get_node_or_null("CollisionShape3D") as CollisionShape3D
	var height := 7.0
	if shape != null and shape.shape is CylinderShape3D:
		height = (shape.shape as CylinderShape3D).height
	MonolithShatter.play(get_parent(), global_position, glow, height)

## A client's view of a stone the server owns: it breaks when the replicated
## death arrives and stands again on the replicated respawn.
func present_death() -> void:
	if is_destroyed:
		return
	is_destroyed = true
	_shatter_fx()
	hide()

func present_respawn() -> void:
	if not is_destroyed:
		return
	is_destroyed = false
	current_hp = max_hp
	_update_label()
	# The new spot rides in the next snapshot: fall onto it a moment later.
	fall_in(0.25)

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
	if home != Vector3.ZERO:
		global_position = pick_landing()
	fall_in()
	$CollisionShape3D.set_deferred("disabled", false)
	_update_label()
	# The record has to come back to life with it, or the authority would still
	# consider this monolith dead and refuse damage on the next wave.
	if SimAuthority.is_authority():
		SimAuthority.refresh_mob(self)
	NetworkManager.system_chat("A new %s has manifested in the realm!" % display_name())

## A random open spot near `home` (authority): ground under it, no water, no
## roof or wall over it and a level footprint for the stone. Home when none.
func pick_landing() -> Vector3:
	var caverns := home.y > 185.0
	var roam := float(_cfg.get("roam", 12.0 if caverns else 30.0))
	if roam <= 0.0 or not is_inside_tree():
		return home
	var space := get_world_3d().direct_space_state
	for _attempt in 30:
		var angle := randf() * TAU
		var spot := home + Vector3(cos(angle), 0.0, sin(angle)) * sqrt(randf()) * roam
		var heights: Array = []
		for probe in [Vector3.ZERO, Vector3(2.2, 0, 0), Vector3(-2.2, 0, 0), Vector3(0, 0, 2.2), Vector3(0, 0, -2.2)]:
			var p: Vector3 = spot + probe
			var ray := PhysicsRayQueryParameters3D.create(Vector3(p.x, home.y + 14.0, p.z), Vector3(p.x, home.y - 10.0, p.z), 1)
			var hit := space.intersect_ray(ray)
			var y := float((hit["position"] as Vector3).y) if not hit.is_empty() else NAN
			if not caverns:
				var ground := GroundsTerrain.height_at(p.x, p.z)
				if is_nan(ground) or GroundsLake.is_water_at(p.x, p.z) or (not is_nan(y) and y > ground + 0.6):
					y = NAN
				else:
					y = ground
			if is_nan(y) or absf(y - home.y) > 5.0:
				heights.clear()
				break
			heights.append(y)
		if heights.size() == 5 and heights.max() - heights.min() < 1.2:
			return Vector3(spot.x, heights.min(), spot.z)
	return home

## The stone comes down out of the sky onto where it stands now: a falling
## streak of its glow, then the impact - shockwave, dust, a shake for anyone
## close. Eyes only; on the dedicated server it simply stands.
const FALL_HEIGHT := 70.0
const FALL_TIME := 0.85

func fall_in(delay := 0.0) -> void:
	if NetworkManager.is_dedicated_server or not is_inside_tree():
		show()
		return
	hide()
	if delay > 0.0:
		await get_tree().create_timer(delay).timeout
		if not is_instance_valid(self) or is_destroyed:
			return
	var model := get_node_or_null("Model") as Node3D
	show()
	if model == null:
		return
	hp_label.visible = false
	model.position.y = FALL_HEIGHT
	model.rotation.y = randf() * TAU
	var streak := _fall_streak()
	var tw := create_tween()
	tw.tween_property(model, "position:y", 0.0, FALL_TIME).set_trans(Tween.TRANS_QUAD).set_ease(Tween.EASE_IN)
	tw.parallel().tween_property(model, "rotation:y", model.rotation.y + 0.6, FALL_TIME)
	tw.tween_callback(func():
		streak.queue_free()
		_land()
	)
	# A little settle after the thump.
	tw.tween_property(model, "scale", Vector3(1.06, 0.9, 1.06), 0.07)
	tw.tween_property(model, "scale", Vector3.ONE, 0.25).set_trans(Tween.TRANS_ELASTIC).set_ease(Tween.EASE_OUT)
	tw.tween_callback(func(): hp_label.visible = true)

## A glowing comet tail that rides above the falling stone.
func _fall_streak() -> Node3D:
	var tail := MeshInstance3D.new()
	tail.name = "FallStreak"
	var cm := CylinderMesh.new()
	cm.top_radius = 0.05
	cm.bottom_radius = 1.1
	cm.height = 26.0
	var mat := StandardMaterial3D.new()
	mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	mat.blend_mode = BaseMaterial3D.BLEND_MODE_ADD
	mat.cull_mode = BaseMaterial3D.CULL_DISABLED
	mat.albedo_color = Color(glow.r, glow.g, glow.b, 0.35)
	cm.material = mat
	tail.mesh = cm
	tail.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	var model := get_node("Model") as Node3D
	model.add_child(tail)
	tail.position = Vector3(0, 7.0 + 13.0, 0)
	return tail

func _land() -> void:
	var height := 7.0
	var shape := get_node_or_null("CollisionShape3D") as CollisionShape3D
	if shape != null and shape.shape is CylinderShape3D:
		height = (shape.shape as CylinderShape3D).height
	FlipbookFX.play(get_parent(), global_position, [
		{"atlas": "shockwave_8x8_1k", "size": height * 3.0, "flat": true, "height": 0.15, "fps": 26.0, "tint": glow},
		{"atlas": "smoke_puff_8x8_1k", "size": height * 1.6, "height": 1.4, "fps": 16.0, "opacity": 0.7,
			"tint": Color(0.5, 0.48, 0.44)},
	], {"life": 2.6, "light": glow, "light_energy": 7.0, "light_range": 20.0, "light_height": height * 0.4,
		"sound": "spell_bombarda_impact"})
	_burst = 4.0
	for player in get_tree().get_nodes_in_group("players"):
		if bool(player.get("is_local_player")) and (player as Node3D).global_position.distance_to(global_position) < 45.0:
			SKILL_FX.shake_camera(player, 0.6)

func display_name() -> String:
	return String(_cfg.get("name", "Dark Monolith"))  # i18n

## Ground height under a wave spawn: the grounds terrain outside, a ray onto
## the map's collider elsewhere (the caverns' stones).
func _ground_y(at: Vector3) -> float:
	if global_position.y < 185.0:
		return GroundsTerrain.height_at(at.x, at.z)
	var query := PhysicsRayQueryParameters3D.create(Vector3(at.x, global_position.y + 12.0, at.z),
		Vector3(at.x, global_position.y - 12.0, at.z), 1)
	var hit := get_world_3d().direct_space_state.intersect_ray(query)
	return NAN if hit.is_empty() else float((hit["position"] as Vector3).y)

func _add_sky_beam() -> void:
	# A tall, faint emerald beacon so players can find the stone from afar
	# (the Dark Mark's colour, not the old placeholder purple).
	var beam := MeshInstance3D.new()
	beam.name = "SkyBeam"
	var cm := CylinderMesh.new()
	cm.top_radius = 0.03
	cm.bottom_radius = 0.1
	cm.height = 34.0
	var bm := StandardMaterial3D.new()
	bm.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	bm.albedo_color = Color(glow.r * 0.5, glow.g * 0.5, glow.b * 0.5, 0.05)
	bm.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	bm.blend_mode = BaseMaterial3D.BLEND_MODE_ADD
	bm.cull_mode = BaseMaterial3D.CULL_DISABLED
	cm.material = bm
	beam.mesh = cm
	beam.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	beam.position = Vector3(0, 7.0 + 17.0, 0)
	add_child(beam)

var _burst := 0.0

func _process(delta: float) -> void:
	if NetworkManager.is_dedicated_server:
		set_process(false)   # the sway / glow below is for eyes only
		return
	# The runes breathe: a slow pulse on the green light.
	var pulse := 0.5 + 0.5 * sin(Time.get_ticks_msec() * 0.0021)
	_burst = maxf(0.0, _burst - delta * 5.0)
	if dark_light:
		dark_light.light_energy = 1.2 + 0.8 * pulse + _burst
