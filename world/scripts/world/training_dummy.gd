extends StaticBody3D

## TrainingDummy — safe skill target. Takes damage, shows numbers,
## never attacks back. Ideal for learning rotations (Metin2-style scarecrow).

var max_hp: int = 800
var current_hp: int = 800
var _t: float = 0.0
var _pole: MeshInstance3D = null

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

	var straw := StandardMaterial3D.new()
	straw.albedo_color = Color(0.72, 0.58, 0.32)
	straw.roughness = 0.95
	var wood_mat := StandardMaterial3D.new()
	wood_mat.albedo_color = Color(0.4, 0.27, 0.14)
	wood_mat.roughness = 0.7

	# post
	_pole = MeshInstance3D.new()
	var pm := CylinderMesh.new()
	pm.top_radius = 0.09
	pm.bottom_radius = 0.11
	pm.height = 2.0
	pm.material = wood_mat
	_pole.mesh = pm
	_pole.position.y = 1.0
	add_child(_pole)
	# straw body
	var torso := MeshInstance3D.new()
	var tm := SphereMesh.new()
	tm.radius = 0.45
	tm.height = 0.9
	tm.material = straw
	torso.mesh = tm
	torso.position.y = 1.5
	add_child(torso)
	# crossbar arms
	var arms := MeshInstance3D.new()
	var am := CylinderMesh.new()
	am.top_radius = 0.07
	am.bottom_radius = 0.07
	am.height = 1.4
	am.material = wood_mat
	arms.mesh = am
	arms.rotation.z = PI * 0.5
	arms.position.y = 1.55
	add_child(arms)
	# head sack
	var head := MeshInstance3D.new()
	var hm := SphereMesh.new()
	hm.radius = 0.28
	hm.height = 0.56
	hm.material = straw
	head.mesh = hm
	head.position.y = 2.15
	add_child(head)

	var label := Label3D.new()
	label.name = "DummyLabel"
	label.billboard = BaseMaterial3D.BILLBOARD_ENABLED
	label.font_size = 32
	label.outline_size = 8
	label.outline_modulate = Color(0, 0, 0)
	label.modulate = Color(0.6, 1.0, 0.6)
	label.position = Vector3(0, 2.8, 0)
	add_child(label)
	_update_label()

func _process(delta: float) -> void:
	_t += delta
	if _pole:
		_pole.rotation.y = sin(_t * 1.2) * 0.05

func _update_label() -> void:
	var label := get_node_or_null("DummyLabel") as Label3D
	if label:
		label.text = "Training Dummy\n%d / %d" % [current_hp, max_hp]

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
