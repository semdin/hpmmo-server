extends RefCounted

const MaterialKitScript = preload("res://scripts/assets/material_kit.gd")

## Builds real wizarding character models from primitives composed properly:
## robed wizard with hat/head/arms, spider with 8 legs, ghoul, snatcher.
## Called from existing player/mob scenes so .tscn files stay compatible.

static func upgrade_player(p: Node3D, house: String) -> void:
	# Hide the old capsule body, keep nodes for compatibility
	var body := p.get_node_or_null("BodyMesh") as MeshInstance3D
	if body:
		body.hide()
	# Model front is +Z (matches atan2(x,z) facing). Put the wand on the
	# front-right side so W never looks like moonwalking.
	var wand := p.get_node_or_null("WandMesh") as MeshInstance3D
	if wand:
		wand.position = Vector3(0.45, 1.35, 0.38)
		wand.rotation = Vector3(-0.5, 0.0, -0.15)
	var house_col := Color(0.5, 0.08, 0.1)
	if GameData.HOUSES.has(house):
		house_col = GameData.HOUSES[house].primary_color

	var rig := Node3D.new()
	rig.name = "WizardRig"
	p.add_child(rig)

	var robe_mat := 	MaterialKitScript.robe_material(house_col)
	var skin_mat := 	MaterialKitScript.skin_material()
	var dark_mat := StandardMaterial3D.new()
	dark_mat.albedo_color = Color(0.1, 0.1, 0.13)
	dark_mat.roughness = 0.85

	# robe: tapered cylinder (shoulders -> ground)
	var robe := MeshInstance3D.new()
	robe.name = "Robe"
	var robe_mesh := CylinderMesh.new()
	robe_mesh.top_radius = 0.32
	robe_mesh.bottom_radius = 0.62
	robe_mesh.height = 1.25
	robe_mesh.radial_segments = 12
	robe_mesh.material = robe_mat
	robe.mesh = robe_mesh
	robe.position = Vector3(0, 0.63, 0)
	rig.add_child(robe)

	# torso
	var torso := MeshInstance3D.new()
	var torso_mesh := CylinderMesh.new()
	torso_mesh.top_radius = 0.30
	torso_mesh.bottom_radius = 0.33
	torso_mesh.height = 0.55
	torso_mesh.material = robe_mat
	torso.mesh = torso_mesh
	torso.position = Vector3(0, 1.45, 0)
	rig.add_child(torso)

	# belt
	var belt := MeshInstance3D.new()
	var belt_mesh := CylinderMesh.new()
	belt_mesh.top_radius = 0.335
	belt_mesh.bottom_radius = 0.335
	belt_mesh.height = 0.09
	var gold := 	MaterialKitScript.gold_material()
	belt_mesh.material = gold
	belt.mesh = belt_mesh
	belt.position = Vector3(0, 1.2, 0)
	rig.add_child(belt)

	# head
	var head := MeshInstance3D.new()
	head.name = "Head"
	var head_mesh := SphereMesh.new()
	head_mesh.radius = 0.21
	head_mesh.height = 0.42
	head_mesh.material = skin_mat
	head.mesh = head_mesh
	head.position = Vector3(0, 1.95, 0)
	rig.add_child(head)

	# wizard hat: brim + cone
	var brim := MeshInstance3D.new()
	var brim_mesh := CylinderMesh.new()
	brim_mesh.top_radius = 0.42
	brim_mesh.bottom_radius = 0.42
	brim_mesh.height = 0.06
	brim_mesh.material = dark_mat
	brim.mesh = brim_mesh
	brim.position = Vector3(0, 2.12, 0)
	rig.add_child(brim)
	var cone := MeshInstance3D.new()
	var cone_mesh := CylinderMesh.new()
	cone_mesh.top_radius = 0.02
	cone_mesh.bottom_radius = 0.26
	cone_mesh.height = 0.5
	cone_mesh.material = dark_mat
	cone.mesh = cone_mesh
	cone.position = Vector3(0, 2.38, 0)
	cone.rotation.z = 0.08
	rig.add_child(cone)

	# arms (separate so we can swing them when walking / raise when casting)
	for side in [-1, 1]:
		var arm := MeshInstance3D.new()
		arm.name = "Arm_L" if side < 0 else "Arm_R"
		var am := CylinderMesh.new()
		am.top_radius = 0.09
		am.bottom_radius = 0.075
		am.height = 0.62
		am.material = robe_mat
		arm.mesh = am
		arm.position = Vector3(side * 0.42, 1.5, 0)
		arm.rotation.z = side * -0.18
		rig.add_child(arm)

	# house scarf stripe across torso
	var scarf := p.get_node_or_null("ScarfMesh") as MeshInstance3D
	if scarf:
		scarf.position = Vector3(0, 1.72, 0)
		scarf.scale = Vector3(0.8, 0.7, 0.8)

	rig.set_meta("house", house)

static func animate_wizard(p: Node3D, moving: bool, t: float) -> void:
	var rig := p.get_node_or_null("WizardRig")
	if rig == null:
		return
	# Cast pose overrides walk swing for a short window after casting.
	if rig.has_meta("cast_until") and Time.get_ticks_msec() < int(rig.get_meta("cast_until")):
		var arm_r := rig.get_node_or_null("Arm_R")
		if arm_r:
			arm_r.rotation.x = lerpf(float((arm_r as MeshInstance3D).rotation.x), -2.2, 0.35)
		var arm_l := rig.get_node_or_null("Arm_L")
		if arm_l:
			(arm_l as MeshInstance3D).rotation.x = lerpf(float((arm_l as MeshInstance3D).rotation.x), 0.3, 0.2)
		rig.position.y = lerpf(float((rig as Node3D).position.y), 0.03, 0.2)
		return
	if moving:
		rig.position.y = abs(sin(t * 9.0)) * 0.07
		rig.rotation.y = sin(t * 1.7) * 0.03
		var arm_l := rig.get_node_or_null("Arm_L")
		var arm_r := rig.get_node_or_null("Arm_R")
		if arm_l:
			(arm_l as MeshInstance3D).rotation.x = sin(t * 9.0) * 0.55
		if arm_r:
			(arm_r as MeshInstance3D).rotation.x = -sin(t * 9.0) * 0.55
	else:
		rig.position.y = lerpf(float((rig as Node3D).position.y), 0.0, 0.15)
		rig.rotation.y = lerpf(float((rig as Node3D).rotation.y), 0.0, 0.1)

static func play_cast_pose(p: Node3D, hold_ms: int = 450) -> void:
	var rig := p.get_node_or_null("WizardRig")
	if rig:
		rig.set_meta("cast_until", Time.get_ticks_msec() + hold_ms)

# ---------------------------------------------------------------- mobs

static func upgrade_mob(mob: Node3D) -> void:
	var mname: String = mob.get("mob_name")
	match mname:
		"Acromantula":
			_build_spider(mob)
		"Inferi":
			_build_inferi(mob)
		"Dark Snatcher":
			_build_snatcher(mob)
		_:
			_build_snatcher(mob)

static func _clear_old_mesh(mob: Node3D) -> void:
	var old := mob.get_node_or_null("MeshInstance3D") as MeshInstance3D
	if old:
		old.hide()

static func _build_spider(mob: Node3D) -> void:
	_clear_old_mesh(mob)
	for c in ["SpiderRig", "EyesMesh", "EyesMesh2"]:
		var n := mob.get_node_or_null(c)
		if n:
			n.queue_free()
	var rig := Node3D.new()
	rig.name = "SpiderRig"
	mob.add_child(rig)
	var chitin := StandardMaterial3D.new()
	chitin.albedo_color = Color(0.14, 0.09, 0.09)
	chitin.roughness = 0.35
	chitin.metallic = 0.3
	# abdomen + thorax
	var abd := MeshInstance3D.new()
	var abm := SphereMesh.new()
	abm.radius = 0.75
	abm.height = 1.5
	abm.material = chitin
	abd.mesh = abm
	abd.scale = Vector3(1.0, 0.75, 1.3)
	abd.position = Vector3(0, 0.55, 0.55)
	rig.add_child(abd)
	var thor := MeshInstance3D.new()
	var thm := SphereMesh.new()
	thm.radius = 0.5
	thm.height = 1.0
	thm.material = chitin
	thor.mesh = thm
	thor.position = Vector3(0, 0.6, -0.55)
	rig.add_child(thor)
	# 8 articulated legs
	var leg_mat := StandardMaterial3D.new()
	leg_mat.albedo_color = Color(0.08, 0.05, 0.05)
	leg_mat.roughness = 0.5
	for i in range(8):
		var side := -1.0 if i < 4 else 1.0
		var idx := i % 4
		var leg := MeshInstance3D.new()
		leg.name = "Leg%d" % i
		var lm := CylinderMesh.new()
		lm.top_radius = 0.06
		lm.bottom_radius = 0.035
		lm.height = 1.7
		lm.material = leg_mat
		leg.mesh = lm
		leg.position = Vector3(side * 0.7, 0.9, 0.5 - idx * 0.45)
		leg.rotation.z = side * 0.9
		leg.rotation.x = (idx - 1.5) * 0.35
		leg.set_meta("phase", float(i) * 0.8)
		rig.add_child(leg)
	# glowing red eyes
	var eye_mat := StandardMaterial3D.new()
	eye_mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	eye_mat.albedo_color = Color(1, 0.08, 0.08)
	for e in range(4):
		var eye := MeshInstance3D.new()
		var em := SphereMesh.new()
		em.radius = 0.07
		em.height = 0.14
		em.material = eye_mat
		eye.mesh = em
		eye.position = Vector3(-0.24 + e * 0.16, 0.75, -1.0)
		rig.add_child(eye)
	rig.set_meta("is_spider", true)

static func _build_inferi(mob: Node3D) -> void:
	_clear_old_mesh(mob)
	var rig := Node3D.new()
	rig.name = "InferiRig"
	mob.add_child(rig)
	var flesh := StandardMaterial3D.new()
	flesh.albedo_color = Color(0.55, 0.6, 0.55)
	flesh.roughness = 0.9
	var rag := StandardMaterial3D.new()
	rag.albedo_color = Color(0.2, 0.22, 0.25)
	rag.roughness = 0.95
	# hunched torso
	var torso := MeshInstance3D.new()
	var tm := BoxMesh.new()
	tm.size = Vector3(0.7, 0.9, 0.4)
	tm.material = rag
	torso.mesh = tm
	torso.position = Vector3(0, 1.0, 0)
	torso.rotation.x = 0.25
	rig.add_child(torso)
	var head := MeshInstance3D.new()
	var hm := SphereMesh.new()
	hm.radius = 0.22
	hm.height = 0.44
	hm.material = flesh
	head.mesh = hm
	head.position = Vector3(0, 1.65, -0.15)
	rig.add_child(head)
	# glowing pale eyes
	var eye_mat := StandardMaterial3D.new()
	eye_mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	eye_mat.albedo_color = Color(0.6, 0.95, 1.0)
	for side in [-1, 1]:
		var eye := MeshInstance3D.new()
		var em := SphereMesh.new()
		em.radius = 0.05
		em.height = 0.1
		em.material = eye_mat
		eye.mesh = em
		eye.position = Vector3(side * 0.09, 1.68, -0.34)
		rig.add_child(eye)
	# dangling arms
	for side in [-1, 1]:
		var arm := MeshInstance3D.new()
		arm.name = "Arm%d" % side
		var am := CylinderMesh.new()
		am.top_radius = 0.09
		am.bottom_radius = 0.07
		am.height = 0.8
		am.material = flesh
		arm.mesh = am
		arm.position = Vector3(side * 0.45, 1.0, -0.1)
		arm.rotation.x = -0.9
		arm.set_meta("phase", float(side))
		rig.add_child(arm)

static func _build_snatcher(mob: Node3D) -> void:
	_clear_old_mesh(mob)
	var rig := Node3D.new()
	rig.name = "SnatcherRig"
	mob.add_child(rig)
	var cloak := StandardMaterial3D.new()
	cloak.albedo_color = Color(0.12, 0.12, 0.16)
	cloak.roughness = 0.85
	var mask := StandardMaterial3D.new()
	mask.albedo_color = Color(0.75, 0.75, 0.78)
	mask.metallic = 0.6
	mask.roughness = 0.3
	var robe := MeshInstance3D.new()
	var rm := CylinderMesh.new()
	rm.top_radius = 0.3
	rm.bottom_radius = 0.55
	rm.height = 1.5
	rm.material = cloak
	robe.mesh = rm
	robe.position = Vector3(0, 0.85, 0)
	rig.add_child(robe)
	var head := MeshInstance3D.new()
	var hm := SphereMesh.new()
	hm.radius = 0.2
	hm.height = 0.4
	hm.material = mask
	head.mesh = hm
	head.position = Vector3(0, 1.85, 0)
	rig.add_child(head)
	# hood cone
	var hood := MeshInstance3D.new()
	var cm := CylinderMesh.new()
	cm.top_radius = 0.03
	cm.bottom_radius = 0.3
	cm.height = 0.45
	cm.material = cloak
	hood.mesh = cm
	hood.position = Vector3(0, 2.1, 0.03)
	rig.add_child(hood)

static func animate_mob(mob: Node3D, t: float) -> void:
	var rig := mob.get_node_or_null("SpiderRig")
	if rig:
		for child in rig.get_children():
			if child is MeshInstance3D and (child as MeshInstance3D).name.begins_with("Leg"):
				var phase: float = child.get_meta("phase")
				child.rotation.y = sin(t * 6.0 + phase) * 0.3
		rig.position.y = abs(sin(t * 5.0)) * 0.06
		return
	var irig := mob.get_node_or_null("InferiRig")
	if irig:
		irig.rotation.z = sin(t * 2.2) * 0.06
		irig.position.y = sin(t * 3.0) * 0.04
		for child in irig.get_children():
			if child is MeshInstance3D and (child as MeshInstance3D).name.begins_with("Arm"):
				var ph: float = child.get_meta("phase")
				child.rotation.x = -0.9 + sin(t * 2.5 + ph) * 0.25
