extends StaticBody3D

## TrainingDummy — safe skill target. Takes damage, shows numbers,
## never attacks back. Ideal for learning rotations (Metin2-style scarecrow).

var max_hp: int = 800
var current_hp: int = 800
var _t: float = 0.0
## The whole figure (post, sack, head) - it sways and rocks on a hit.
var _pole: Node3D = null

func setup() -> void:
	add_to_group("targetable")
	add_to_group("dummies")
	collision_layer = 2
	collision_mask = 1
	var col := CollisionShape3D.new()
	var cap := CylinderShape3D.new()
	cap.radius = 0.6
	cap.height = 2.0
	col.shape = cap
	col.position.y = 1.0
	add_child(col)

	_pole = Node3D.new()
	_pole.name = "Body"
	add_child(_pole)
	if not NetworkManager.is_dedicated_server:
		_build_body()

	var label := Label3D.new()
	label.name = "DummyLabel"
	label.billboard = BaseMaterial3D.BILLBOARD_ENABLED
	label.font_size = 32
	label.outline_size = 8
	label.outline_modulate = Color(0, 0, 0)
	label.modulate = Color(0.6, 1.0, 0.6)
	label.position = Vector3(0, 2.75, 0)
	add_child(label)
	_update_label()

func _process(delta: float) -> void:
	if NetworkManager.is_dedicated_server:
		set_process(false)   # the sway / glow below is for eyes only
		return
	_t += delta
	if _pole:
		_pole.rotation.x = sin(_t * 1.2) * 0.02

func _update_label() -> void:
	var label := get_node_or_null("DummyLabel") as Label3D
	if label:
		label.text = "Training Dummy\n%d / %d" % [current_hp, max_hp]
		WorldLabels.track(label, 15.0)

## Damage is requested from the authority (dummies keep the prototype exemption
## that makes them practiceable inside protected volumes).
func take_damage(amount: int, spell: String, attacker: Node3D) -> void:
	SimAuthority.apply_damage(self, amount, spell, attacker)

## Presentation after the engine applied damage. Dummies never die: at zero they
## reset, which the engine performs so every client sees the same full bar.
func on_authoritative_damage(_spell: String, _attacker: Node3D, _stun_ms: int, _weaken_ms: int) -> void:
	if current_hp <= 0:
		SimAuthority.reset_dummy(self)
		_update_label()
		var ft_scene = load("res://scenes/ui/floating_text.tscn")
		if ft_scene:
			var ft = ft_scene.instantiate()
			get_parent().add_child(ft)
			ft.global_position = global_position + Vector3(0, 2.4, 0)
			ft.setup("DUMMY RESET!", Color(0.5, 1.0, 0.5), 1.3)
	_update_label()
	# wobble feedback, never retaliates
	if _pole:
		var tw := create_tween()
		tw.tween_property(_pole, "rotation:z", 0.12, 0.06)
		tw.tween_property(_pole, "rotation:z", 0.0, 0.18)

# ------------------------------------------------------------------ the figure

const HESSIAN := "res://assets/textures/pbr/hessian_230/hessian_230_%s_1k.jpg"
const WOOD := "res://assets/textures/pbr/medieval_wood/medieval_wood_%s_2k.jpg"

## A duelling-practice dummy: crossed oak planks for a foot, a weathered post,
## a stuffed hessian sack for a body cinched with rope at chest and waist, a
## crossbar through the shoulders in burlap sleeves with straw bursting from
## the ends, a tied sack head with stitched eyes, and a painted target on the
## chest and back. Built from primitives and lathed profiles with the CC0
## hessian and medieval wood textures (Poly Haven); eyes only.
func _build_body() -> void:
	var sack := _pbr(HESSIAN, Color(0.86, 0.76, 0.6), Vector3(2.0, 2.0, 1.0))
	var sack_dark := _pbr(HESSIAN, Color(0.62, 0.52, 0.38), Vector3(2.0, 2.0, 1.0))
	var wood := _pbr(WOOD, Color(0.72, 0.6, 0.48), Vector3(0.6, 1.5, 1.0))
	var rope := StandardMaterial3D.new()
	rope.albedo_color = Color(0.55, 0.45, 0.3)
	rope.roughness = 1.0
	var straw := StandardMaterial3D.new()
	straw.albedo_color = Color(0.86, 0.72, 0.38)
	straw.roughness = 0.9
	straw.cull_mode = BaseMaterial3D.CULL_DISABLED
	var paint_red := StandardMaterial3D.new()
	paint_red.albedo_color = Color(0.58, 0.1, 0.08)
	paint_red.roughness = 0.85
	var paint_cream := StandardMaterial3D.new()
	paint_cream.albedo_color = Color(0.9, 0.84, 0.68)
	paint_cream.roughness = 0.85
	var thread := StandardMaterial3D.new()
	thread.albedo_color = Color(0.12, 0.08, 0.06)

	# foot: two crossed planks and the post
	for yaw in [0.0, PI * 0.5]:
		var plank := _box(Vector3(1.3, 0.12, 0.2), wood)
		plank.position = Vector3(0, 0.06, 0)
		plank.rotation.y = yaw + 0.3
		add_child(plank)
	var post := _lathe([Vector2(0.095, 0.0), Vector2(0.085, 1.0), Vector2(0.08, 2.1), Vector2(0.06, 2.16)], wood, 10, Vector2(1.0, 2.0))
	_pole.add_child(post)
	# body: a stuffed sack, fullest at the chest
	var torso := _lathe([Vector2(0.0, 0.88), Vector2(0.2, 0.9), Vector2(0.3, 1.02), Vector2(0.34, 1.25),
		Vector2(0.36, 1.48), Vector2(0.33, 1.66), Vector2(0.22, 1.76), Vector2(0.11, 1.8)], sack, 18, Vector2(2.0, 1.0))
	_pole.add_child(torso)
	for band in [[1.08, 0.31], [1.6, 0.345]]:
		var ring := MeshInstance3D.new()
		var tm := TorusMesh.new()
		tm.inner_radius = float(band[1]) - 0.015
		tm.outer_radius = float(band[1]) + 0.025
		tm.rings = 24
		tm.ring_segments = 6
		tm.material = rope
		ring.mesh = tm
		ring.position.y = float(band[0])
		_pole.add_child(ring)
	# shoulders: the crossbar and its burlap sleeves, straw at the cuffs
	var bar := MeshInstance3D.new()
	var bm := CylinderMesh.new()
	bm.top_radius = 0.045
	bm.bottom_radius = 0.045
	bm.height = 1.5
	bm.radial_segments = 8
	bm.material = wood
	bar.mesh = bm
	bar.rotation.z = PI * 0.5
	bar.position.y = 1.62
	_pole.add_child(bar)
	for side in [-1.0, 1.0]:
		var sleeve := _lathe([Vector2(0.09, 0.0), Vector2(0.11, 0.12), Vector2(0.1, 0.38), Vector2(0.085, 0.46)], sack_dark, 10, Vector2(1.0, 1.0))
		sleeve.rotation.z = -side * PI * 0.5
		sleeve.position = Vector3(side * 0.24, 1.62, 0)
		_pole.add_child(sleeve)
		_tuft(straw, Vector3(side * 0.71, 1.62, 0), Vector3(side, 0, 0), 9, 0.2)
	_tuft(straw, Vector3(0, 0.9, 0), Vector3.DOWN, 12, 0.22)
	# head: a tied sack on the post
	var head := _lathe([Vector2(0.0, 1.84), Vector2(0.09, 1.85), Vector2(0.2, 1.94), Vector2(0.24, 2.08),
		Vector2(0.22, 2.22), Vector2(0.14, 2.31), Vector2(0.0, 2.34)], sack, 16, Vector2(1.5, 1.0))
	_pole.add_child(head)
	var tie := MeshInstance3D.new()
	var tt := TorusMesh.new()
	tt.inner_radius = 0.09
	tt.outer_radius = 0.13
	tt.ring_segments = 6
	tt.material = rope
	tie.mesh = tt
	tie.position.y = 1.86
	_pole.add_child(tie)
	_tuft(straw, Vector3(0, 1.82, 0), Vector3.UP, 8, 0.12)
	# stitched X eyes and a stitched mouth, on the side facing the courtyard
	for ex in [-0.085, 0.085]:
		for tilt in [0.75, -0.75]:
			var stitch := _box(Vector3(0.075, 0.012, 0.01), thread)
			stitch.position = Vector3(ex, 2.12, 0.225)
			stitch.rotation.z = tilt
			_pole.add_child(stitch)
	var mouth := _box(Vector3(0.12, 0.012, 0.01), thread)
	mouth.position = Vector3(0, 2.0, 0.232)
	_pole.add_child(mouth)
	# painted target, chest and back
	for z in [1.0, -1.0]:
		for ring in [[0.17, paint_red], [0.11, paint_cream], [0.05, paint_red]]:
			var disc := MeshInstance3D.new()
			var dm := CylinderMesh.new()
			dm.top_radius = float(ring[0])
			dm.bottom_radius = float(ring[0])
			dm.height = 0.01
			dm.radial_segments = 20
			dm.material = ring[1]
			disc.mesh = dm
			disc.rotation.x = PI * 0.5
			disc.position = Vector3(0, 1.36, z * (0.355 + (0.17 - float(ring[0])) * 0.03))
			_pole.add_child(disc)
	# face the courtyard the dummies stand in
	var yard := GroundsLayout.landmark("courtyard")
	if yard != Vector3.INF:
		var to := Vector2(yard.x - global_position.x, yard.z - global_position.z)
		if to.length() > 1.0:
			_pole.rotation.y = atan2(to.x, to.y)

static var _mats: Dictionary = {}

func _pbr(pattern: String, tint: Color, uv: Vector3) -> StandardMaterial3D:
	var key := pattern + tint.to_html()
	if _mats.has(key):
		return _mats[key]
	var m := StandardMaterial3D.new()
	m.albedo_color = tint
	var diff := pattern % "diff"
	if ResourceLoader.exists(diff):
		m.albedo_texture = load(diff)
	var nor := pattern % "nor_gl"
	if ResourceLoader.exists(nor):
		m.normal_enabled = true
		m.normal_texture = load(nor)
	var rough := pattern % "rough"
	if ResourceLoader.exists(rough):
		m.roughness_texture = load(rough)
	m.roughness = 1.0
	m.uv1_scale = uv
	_mats[key] = m
	return m

func _box(size: Vector3, mat: Material) -> MeshInstance3D:
	var mi := MeshInstance3D.new()
	var b := BoxMesh.new()
	b.size = size
	b.material = mat
	mi.mesh = b
	return mi

## A surface of revolution about Y from (radius, height) points, bottom to
## top, with U around and V along the profile.
func _lathe(profile: Array, mat: Material, sides: int, uv_scale: Vector2) -> MeshInstance3D:
	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)
	var length := 0.0
	var vs: Array[float] = [0.0]
	for i in range(1, profile.size()):
		length += (profile[i] as Vector2).distance_to(profile[i - 1])
		vs.append(length)
	for i in profile.size() - 1:
		var a: Vector2 = profile[i]
		var b: Vector2 = profile[i + 1]
		var slope := Vector2(b.y - a.y, -(b.x - a.x)).normalized()   # outward normal in (r, y)
		for k in sides:
			var t0 := TAU * float(k) / float(sides)
			var t1 := TAU * float(k + 1) / float(sides)
			var quad := [[a, t0, vs[i]], [b, t0, vs[i + 1]], [b, t1, vs[i + 1]], [a, t1, vs[i]]]
			for idx in [0, 2, 1, 0, 3, 2]:
				var q: Array = quad[idx]
				var pr: Vector2 = q[0]
				var th: float = q[1]
				st.set_normal(Vector3(cos(th) * slope.x, slope.y, sin(th) * slope.x).normalized())
				st.set_uv(Vector2(th / TAU * uv_scale.x, float(q[2]) / maxf(length, 0.001) * uv_scale.y))
				st.add_vertex(Vector3(cos(th) * pr.x, pr.y, sin(th) * pr.x))
	var mi := MeshInstance3D.new()
	var mesh := st.commit()
	mesh.surface_set_material(0, mat)
	mi.mesh = mesh
	return mi

## A burst of straw: thin blades fanning out along `dir`.
func _tuft(mat: Material, at: Vector3, dir: Vector3, count: int, reach: float) -> void:
	var rng := RandomNumberGenerator.new()
	rng.seed = int(at.x * 100.0) * 31 + int(at.y * 100.0) + count
	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)
	var basis := Basis.looking_at(-dir, Vector3.FORWARD if absf(dir.y) > 0.9 else Vector3.UP)
	for i in count:
		var spread := Vector3(rng.randf_range(-0.7, 0.7), rng.randf_range(-0.7, 0.7), -1.0).normalized()
		var tip := basis * spread * reach * rng.randf_range(0.6, 1.2)
		var side := tip.cross(Vector3.UP if absf(dir.y) < 0.9 else Vector3.RIGHT).normalized() * 0.022
		for v in [-side, side, tip]:
			st.set_normal(Vector3.UP)
			st.add_vertex(at + v)
	var mi := MeshInstance3D.new()
	var mesh := st.commit()
	mesh.surface_set_material(0, mat)
	mi.mesh = mesh
	mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	_pole.add_child(mi)
