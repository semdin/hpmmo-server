extends RefCounted

## SkillFX — original MMORPG skill animation kit (Metin2-style feel, own art).

static func play_cast(world: Node3D, caster: Node3D, spell_id: String, spawn_pos: Vector3, dir: Vector3) -> void:
	if not is_instance_valid(world):
		return
	var col := Color(1.0, 0.85, 0.4)
	if GameData.SPELLS.has(spell_id):
		col = (GameData.SPELLS[spell_id] as Dictionary).get("color", col)
	_muzzle_flash(world, spawn_pos, dir, col)
	match spell_id:
		"incendio":
			_fire_cone(world, spawn_pos, dir, col)
		"bombarda":
			_shockwave(world, spawn_pos, col, 8.0)
			shake_camera(caster, 0.35)
		"stupefy":
			_bolt_ring(world, spawn_pos, col)
		"expelliarmus":
			_bolt_ring(world, spawn_pos, col)
			_arc_slash(world, spawn_pos, dir, col)
		"ultimate":
			_sky_beam(world, spawn_pos, col)
			_shockwave(world, spawn_pos, col, 14.0)
			shake_camera(caster, 0.6)
		"basic_cast":
			_bolt_ring(world, spawn_pos, col)
		"protego":
			pass # shield scene handles it; muzzle flash is enough

static func play_impact(world: Node3D, pos: Vector3, spell_id: String) -> void:
	if not is_instance_valid(world):
		return
	var col := Color(1.0, 0.6, 0.2)
	if GameData.SPELLS.has(spell_id):
		col = (GameData.SPELLS[spell_id] as Dictionary).get("color", col)
	match spell_id:
		"bombarda":
			_shockwave(world, pos, col, 10.0)
			_sparks(world, pos, col, 35)
			_flash_light(world, pos, col, 6.0, 14.0, 0.45)
		"ultimate":
			_sky_beam(world, pos, col)
			_shockwave(world, pos, col, 16.0)
			_sparks(world, pos, col, 50)
			_flash_light(world, pos, col, 8.0, 22.0, 0.6)
		"incendio":
			_shockwave(world, pos, col, 4.5)
			_sparks(world, pos, col, 28)
			_flash_light(world, pos, col, 4.0, 10.0, 0.4)
		"stupefy":
			_bolt_ring(world, pos, col)
			_sparks(world, pos, col, 18)
			_flash_light(world, pos, col, 3.5, 9.0, 0.3)
		"expelliarmus":
			_arc_slash(world, pos, Vector3.UP, col)
			_sparks(world, pos, col, 20)
			_flash_light(world, pos, col, 4.0, 10.0, 0.35)
		_:
			_sparks(world, pos, col, 14)
			_bolt_ring(world, pos, col)
			_flash_light(world, pos, col, 2.5, 6.0, 0.25)

static func play_stun_stars(world: Node3D, target: Node3D) -> void:
	if not is_instance_valid(world) or not is_instance_valid(target):
		return
	var rig := Node3D.new()
	rig.name = "StunStars"
	world.add_child(rig)
	rig.global_position = target.global_position + Vector3(0, 2.0, 0)
	var mat := StandardMaterial3D.new()
	mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	mat.albedo_color = Color(1.0, 0.85, 0.25)
	for i in range(3):
		var s := MeshInstance3D.new()
		var sm := SphereMesh.new()
		sm.radius = 0.09
		sm.height = 0.18
		sm.material = mat
		s.mesh = sm
		s.position = Vector3(cos(TAU * i / 3.0) * 0.55, 0, sin(TAU * i / 3.0) * 0.55)
		rig.add_child(s)
	var tw := rig.create_tween()
	tw.set_parallel(true)
	tw.tween_property(rig, "rotation:y", TAU * 2.0, 1.8).set_trans(Tween.TRANS_LINEAR)
	tw.chain().tween_callback(rig.queue_free).set_delay(1.8)

# ---------------------------------------------------------------- pieces

static func _unshaded(c: Color) -> StandardMaterial3D:
	var m := StandardMaterial3D.new()
	m.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	m.albedo_color = c
	m.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	return m

static func _flash_light(world: Node3D, pos: Vector3, col: Color, energy: float, range_r: float, life: float = 0.3) -> void:
	var l := OmniLight3D.new()
	l.light_color = col
	l.light_energy = energy
	l.omni_range = range_r
	world.add_child(l)
	l.global_position = pos
	var tw := l.create_tween()
	tw.tween_property(l, "light_energy", 0.0, life)
	tw.tween_callback(l.queue_free)

static func _muzzle_flash(world: Node3D, pos: Vector3, dir: Vector3, col: Color) -> void:
	if dir.length_squared() < 0.000001:
		dir = Vector3.FORWARD
	_flash_light(world, pos, col, 3.0, 7.0, 0.25)
	var orb := MeshInstance3D.new()
	var sm := SphereMesh.new()
	sm.radius = 0.22
	sm.height = 0.44
	sm.material = _unshaded(Color(col.r, col.g, col.b, 0.9))
	orb.mesh = sm
	world.add_child(orb)
	orb.global_position = pos
	var tw := orb.create_tween()
	tw.set_parallel(true)
	tw.tween_property(orb, "scale", Vector3.ONE * 2.6, 0.22).set_trans(Tween.TRANS_QUAD).set_ease(Tween.EASE_OUT)
	tw.tween_property(orb, "transparency", 1.0, 0.22)
	tw.chain().tween_callback(orb.queue_free).set_delay(0.25)
	# short directional streak
	var streak := MeshInstance3D.new()
	var cm := CylinderMesh.new()
	cm.top_radius = 0.05
	cm.bottom_radius = 0.12
	cm.height = 1.4
	cm.material = _unshaded(Color(col.r, col.g, col.b, 0.7))
	streak.mesh = cm
	world.add_child(streak)
	streak.global_position = pos + dir * 0.8
	streak.look_at_from_position(streak.global_position, pos + dir * 3.0, preload("res://scripts/spells/combat_rules.gd").safe_up(dir))
	var tw2 := streak.create_tween()
	tw2.set_parallel(true)
	tw2.tween_property(streak, "scale", Vector3(1.6, 1.0, 1.6), 0.2)
	tw2.tween_property(streak, "transparency", 1.0, 0.2)
	tw2.chain().tween_callback(streak.queue_free).set_delay(0.22)

static func _bolt_ring(world: Node3D, pos: Vector3, col: Color) -> void:
	var ring := MeshInstance3D.new()
	var tm := TorusMesh.new()
	tm.inner_radius = 0.25
	tm.outer_radius = 0.4
	tm.material = _unshaded(Color(col.r, col.g, col.b, 0.85))
	ring.mesh = tm
	world.add_child(ring)
	ring.global_position = pos
	ring.look_at_from_position(pos, pos + Vector3.UP, Vector3.FORWARD)
	var tw := ring.create_tween()
	tw.set_parallel(true)
	tw.tween_property(ring, "scale", Vector3.ONE * 3.2, 0.3).set_trans(Tween.TRANS_QUAD).set_ease(Tween.EASE_OUT)
	tw.tween_property(ring, "transparency", 1.0, 0.3)
	tw.chain().tween_callback(ring.queue_free).set_delay(0.32)

static func _fire_cone(world: Node3D, pos: Vector3, dir: Vector3, col: Color) -> void:
	if dir.length_squared() < 0.000001:
		dir = Vector3.FORWARD
	_flash_light(world, pos + dir * 2.0, col, 2.0, 10.0, 0.45)
	var flame := CPUParticles3D.new()
	preload("res://scripts/assets/particle_kit.gd").configure(flame, true)
	flame.amount = 95
	flame.lifetime = 0.55
	flame.one_shot = true
	flame.explosiveness = 0.3
	flame.direction = dir
	flame.spread = 24
	flame.initial_velocity_min = 20
	flame.initial_velocity_max = 32
	flame.gravity = Vector3(0, 1.5, 0)
	flame.scale_amount_min = 1.4
	flame.scale_amount_max = 3.0
	world.add_child(flame)
	flame.global_position = pos
	flame.emitting = true
	flame.finished.connect(flame.queue_free)

static func _arc_slash(world: Node3D, pos: Vector3, dir: Vector3, col: Color) -> void:
	if dir.length_squared() < 0.000001:
		dir = Vector3.FORWARD
	var arc := MeshInstance3D.new()
	var tm := TorusMesh.new()
	tm.inner_radius = 0.9
	tm.outer_radius = 1.1
	tm.material = _unshaded(Color(col.r, col.g, col.b, 0.8))
	arc.mesh = tm
	world.add_child(arc)
	arc.global_position = pos + dir * 1.2
	arc.look_at_from_position(arc.global_position, arc.global_position + dir, preload("res://scripts/spells/combat_rules.gd").safe_up(dir))
	var tw := arc.create_tween()
	tw.set_parallel(true)
	tw.tween_property(arc, "scale", Vector3.ONE * 2.2, 0.3)
	tw.tween_property(arc, "transparency", 1.0, 0.3)
	tw.chain().tween_callback(arc.queue_free).set_delay(0.32)

static func _shockwave(world: Node3D, pos: Vector3, col: Color, max_r: float) -> void:
	_flash_light(world, pos, col, 5.0, 16.0, 0.4)
	var ring := MeshInstance3D.new()
	var tm := TorusMesh.new()
	tm.inner_radius = 0.5
	tm.outer_radius = 0.7
	tm.material = _unshaded(Color(col.r, col.g, col.b, 0.9))
	ring.mesh = tm
	world.add_child(ring)
	ring.global_position = pos + Vector3(0, 0.4, 0)
	ring.rotation.x = 0.0
	var tw := ring.create_tween()
	tw.set_parallel(true)
	tw.tween_property(ring, "scale", Vector3.ONE * (max_r / 1.2), 0.5).set_trans(Tween.TRANS_QUAD).set_ease(Tween.EASE_OUT)
	tw.tween_property(ring, "transparency", 1.0, 0.5)
	tw.chain().tween_callback(ring.queue_free).set_delay(0.55)
	# rising dust pillar
	var pillar := MeshInstance3D.new()
	var cm := CylinderMesh.new()
	cm.top_radius = 1.2
	cm.bottom_radius = 2.0
	cm.height = 3.0
	cm.material = _unshaded(Color(col.r, col.g, col.b, 0.35))
	pillar.mesh = cm
	world.add_child(pillar)
	pillar.global_position = pos + Vector3(0, 1.5, 0)
	var tw2 := pillar.create_tween()
	tw2.set_parallel(true)
	tw2.tween_property(pillar, "scale", Vector3(1.6, 1.4, 1.6), 0.5)
	tw2.tween_property(pillar, "transparency", 1.0, 0.5)
	tw2.chain().tween_callback(pillar.queue_free).set_delay(0.55)

static func _sky_beam(world: Node3D, pos: Vector3, col: Color) -> void:
	var beam := MeshInstance3D.new()
	var cm := CylinderMesh.new()
	cm.top_radius = 1.0
	cm.bottom_radius = 1.6
	cm.height = 30.0
	cm.material = _unshaded(Color(col.r, col.g, col.b, 0.5))
	beam.mesh = cm
	world.add_child(beam)
	beam.global_position = pos + Vector3(0, 15.0, 0)
	_flash_light(world, pos + Vector3(0, 2, 0), col, 6.0, 20.0, 0.6)
	var tw := beam.create_tween()
	tw.set_parallel(true)
	tw.tween_property(beam, "scale", Vector3(2.2, 1.0, 2.2), 0.55).set_trans(Tween.TRANS_QUAD).set_ease(Tween.EASE_OUT)
	tw.tween_property(beam, "transparency", 1.0, 0.6)
	tw.chain().tween_callback(beam.queue_free).set_delay(0.65)

static func _sparks(world: Node3D, pos: Vector3, col: Color, count: int) -> void:
	var parts := CPUParticles3D.new()
	preload("res://scripts/assets/particle_kit.gd").configure(parts)
	parts.amount = count
	parts.lifetime = 0.5
	parts.one_shot = true
	parts.explosiveness = 0.9
	parts.emission_shape = CPUParticles3D.EMISSION_SHAPE_SPHERE
	parts.emission_sphere_radius = 0.4
	parts.direction = Vector3(0, 1, 0)
	parts.spread = 60.0
	parts.initial_velocity_min = 4.0
	parts.initial_velocity_max = 9.0
	parts.gravity = Vector3(0, -9, 0)
	parts.color = col
	world.add_child(parts)
	parts.global_position = pos
	parts.emitting = true
	var t := world.get_tree().create_timer(1.2)
	t.timeout.connect(parts.queue_free)

static func shake_camera(caster: Node3D, strength: float) -> void:
	if not is_instance_valid(caster):
		return
	var cam := caster.get_node_or_null("CameraPivot/SpringArm3D/Camera3D") as Camera3D
	if cam == null:
		return
	var orig_h := cam.h_offset
	var orig_v := cam.v_offset
	cam.h_offset = randf_range(-strength, strength) * 0.4
	cam.v_offset = randf_range(-strength, strength) * 0.4
	var tw := cam.create_tween()
	tw.tween_property(cam, "h_offset", orig_h, 0.3)
	tw.parallel().tween_property(cam, "v_offset", orig_v, 0.3)
