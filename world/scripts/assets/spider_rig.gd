extends Node3D

## Original articulated acromantula: eight two-segment legs, plated abdomen,
## fangs, eyes and a readable collapse animation instead of a static primitive.
var legs: Array[Node3D] = []
var _phase := 0.0
var dying := false

func _ready() -> void:
	var chitin := StandardMaterial3D.new()
	chitin.albedo_color = Color(0.12, 0.15, 0.17)
	chitin.metallic = 0.35
	chitin.roughness = 0.36
	var plates := chitin.duplicate() as StandardMaterial3D
	plates.albedo_color = Color(0.28, 0.22, 0.18)
	var glow := StandardMaterial3D.new()
	glow.albedo_color = Color(1, 0.3, 0.06)
	glow.emission_enabled = true
	glow.emission = glow.albedo_color
	glow.emission_energy_multiplier = 2
	_sphere(self, Vector3(0, 0.9, -0.55), Vector3(0.85, 0.7, 1.25), chitin)
	_sphere(self, Vector3(0, 0.75, 0.5), Vector3(0.65, 0.5, 0.65), plates)
	for band in range(5):
		var ring := TorusMesh.new()
		ring.inner_radius = 0.51 - band * 0.035
		ring.outer_radius = 0.59 - band * 0.035
		var segment := MeshInstance3D.new()
		segment.mesh = ring
		segment.material_override = plates
		segment.position = Vector3(0, 0.95, -0.4 - band * 0.23)
		segment.rotation.x = PI / 2
		segment.scale.y = 0.55
		add_child(segment)
	for side in [-1.0, 1.0]:
		for i in range(4):
			var hip := Node3D.new()
			hip.position = Vector3(side * 0.45, 0.75, -0.8 + i * 0.4)
			hip.set_meta("side", side)
			hip.set_meta("phase", float(i) * PI * 0.6 + side * PI * 0.5)
			add_child(hip)
			legs.append(hip)
			var knee := Vector3(side * (0.95 + sin(i) * 0.2), 0.45, (i - 1.5) * 0.48)
			_bone(hip, Vector3.ZERO, knee, 0.11, plates)
			_sphere(hip, knee, Vector3.ONE * 0.16, chitin)
			_bone(hip, knee, knee + Vector3(side * 0.58, -1.2, (i - 1.5) * 0.2), 0.075, chitin)
		for i in range(3):
			_sphere(self, Vector3(side * (0.16 + i * 0.14), 0.82 + i * 0.045, 1.06 - i * 0.1), Vector3.ONE * (0.095 - i * 0.018), glow)
		_bone(self, Vector3(side * 0.27, 0.52, 1), Vector3(side * 0.17, 0.23, 1.48), 0.12, plates)

func _process(delta: float) -> void:
	if dying:
		return
	var mob := get_parent().get_parent() as CharacterBody3D
	var moving := mob.velocity.length() > 0.3
	_phase += delta * (10 if moving else 1.2)
	for leg in legs:
		var phase: float = leg.get_meta("phase")
		leg.rotation.y = sin(_phase + phase) * (0.28 if moving else 0.02)
		leg.rotation.z = cos(_phase + phase) * (0.17 if moving else 0.01)
	position.y = sin(_phase * 2) * (0.04 if moving else 0.015)

func die() -> void:
	dying = true
	var tween := create_tween().set_parallel(true)
	tween.tween_property(self, "position:y", -0.35, 0.65)
	tween.tween_property(self, "rotation:z", 0.3, 0.65)
	for leg in legs:
		tween.tween_property(leg, "rotation:z", float(leg.get_meta("side")) * 1.2, 0.7).set_trans(Tween.TRANS_BACK)

func reset_pose() -> void:
	dying = false
	position = Vector3.ZERO
	rotation = Vector3.ZERO

func _sphere(parent: Node3D, pos: Vector3, dimensions: Vector3, mat: Material) -> void:
	var node := MeshInstance3D.new()
	var sphere := SphereMesh.new()
	sphere.radius = 1
	sphere.height = 2
	sphere.radial_segments = 20
	sphere.rings = 10
	node.mesh = sphere
	node.material_override = mat
	node.position = pos
	node.scale = dimensions
	parent.add_child(node)

func _bone(parent: Node3D, from: Vector3, to: Vector3, radius: float, mat: Material) -> void:
	var mesh := CylinderMesh.new()
	mesh.top_radius = radius * 0.45
	mesh.bottom_radius = radius
	mesh.height = from.distance_to(to)
	mesh.radial_segments = 10
	var node := MeshInstance3D.new()
	node.mesh = mesh
	node.material_override = mat
	node.position = (from + to) * 0.5
	node.quaternion = Quaternion(Vector3.UP, (to - from).normalized())
	parent.add_child(node)
