extends Node3D

## Blackweb Caverns (maps.json `spider_caverns`): a shared Metin2-style
## grinding map under the crypt on the grounds (docs/spider-caverns-plan.md).
##
## The ground is a heightfield made from art/spider_caverns/layout.json
## (scripts/cavern_heightfield.py -> cavern_mesh_blender.py): a chunked render
## mesh (cavern_terrain.glb, LODs from the importer) and a HeightMapShape3D.
## The collider is NOT built here: every process keeps it resident from world
## start (CavernColliders, game_world.gd), because the packs living down here
## are placed and simulated whether or not anyone has the map loaded. This
## node is presentation only: the shaded ground, webs, crags, egg sacs, glowing
## fungi, the camp and the crypt stair. A dedicated server never loads it.

const LAYOUT_PATH := "res://assets/maps/spider_caverns/cavern_layout.json"
const TERRAIN_PATH := "res://assets/maps/spider_caverns/cavern_terrain.glb"
const HEIGHT_PATH := "res://assets/maps/spider_caverns/cavern_height.res"
const GROUND_SHADER := preload("res://assets/shaders/cavern_ground.gdshader")
const WEB_SHADER := preload("res://assets/shaders/cobweb.gdshader")
const TEX := "res://assets/terrain/textures/%s.png"

var map_id := ""
var collision_only := false
var base_y := 1550.0

var _layout: Dictionary = {}
var _heights: PackedFloat32Array
var _n := 0
var _rng := RandomNumberGenerator.new()
var _rock: StandardMaterial3D
var _lights := 0

func setup(p_map_id: String, p_collision_only: bool = false) -> void:
	map_id = p_map_id
	collision_only = p_collision_only
	set_meta("map_id", map_id)

func _ready() -> void:
	if collision_only:
		return
	var raw := FileAccess.get_file_as_string(LAYOUT_PATH)
	_layout = JSON.parse_string(raw) if raw != "" else {}
	base_y = float(_layout.get("meta", {}).get("base_y", 1550.0))
	var shape := load(HEIGHT_PATH) as HeightMapShape3D
	if shape != null:
		_heights = shape.map_data
		_n = shape.map_width
	_rng.seed = int(_layout.get("meta", {}).get("seed", 2410))
	_rock = StandardMaterial3D.new()
	_rock.albedo_texture = load(TEX % "cliff_rock_alb_ht")
	_rock.albedo_color = Color(0.62, 0.6, 0.68)
	_rock.uv1_triplanar = true
	_rock.uv1_world_triplanar = true
	_rock.uv1_scale = Vector3(0.25, 0.25, 0.25)
	_rock.roughness = 0.9
	_build_ground()
	for room in _layout.get("rooms", []):
		_dress_room(room as Dictionary)
	_build_crypt_stair()

## Name shown under the minimap: the floor by height.
func floor_display(y: float) -> String:
	var level := "Floor 1 - Webbed Galleries" if y > base_y - 12.0 else "Floor 2 - Egg Caverns"
	return "Blackweb Caverns - %s" % level

# ----------------------------------------------------------------- ground

func _build_ground() -> void:
	if not ResourceLoader.exists(TERRAIN_PATH):
		push_warning("[SpiderCaverns] %s missing" % TERRAIN_PATH)
		return
	var terrain: Node3D = (load(TERRAIN_PATH) as PackedScene).instantiate()
	terrain.name = "Ground"
	terrain.position = Vector3(0, base_y, 0)
	add_child(terrain)
	var mat := ShaderMaterial.new()
	mat.shader = GROUND_SHADER
	mat.set_shader_parameter("rock_alb", load(TEX % "cliff_rock_alb_ht"))
	mat.set_shader_parameter("rock_nrm", load(TEX % "cliff_rock_nrm_rgh"))
	mat.set_shader_parameter("dust_alb", load(TEX % "forest_floor_alb_ht"))
	mat.set_shader_parameter("dust_nrm", load(TEX % "forest_floor_nrm_rgh"))
	mat.set_shader_parameter("gravel_alb", load(TEX % "gravel_alb_ht"))
	mat.set_shader_parameter("gravel_nrm", load(TEX % "gravel_nrm_rgh"))
	mat.set_shader_parameter("base_y", base_y)
	for mesh in terrain.find_children("*", "MeshInstance3D", true, false):
		(mesh as MeshInstance3D).material_override = mat
		(mesh as MeshInstance3D).cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF

## Ground height (world y) at local x/z, bilinear on the collider's samples.
func ground_y(x: float, z: float) -> float:
	if _n == 0:
		return base_y
	var half := float(_n - 1) * 0.5
	var fx := clampf(x + half, 0.0, float(_n - 1) - 0.001)
	var fz := clampf(z + half, 0.0, float(_n - 1) - 0.001)
	var ix := int(fx)
	var iz := int(fz)
	var tx := fx - ix
	var tz := fz - iz
	var h00 := _heights[iz * _n + ix]
	var h10 := _heights[iz * _n + ix + 1]
	var h01 := _heights[(iz + 1) * _n + ix]
	var h11 := _heights[(iz + 1) * _n + ix + 1]
	return base_y + lerpf(lerpf(h00, h10, tx), lerpf(h01, h11, tx), tz)

func _on_ground(x: float, z: float) -> Vector3:
	return Vector3(x, ground_y(x, z), z)

# ---------------------------------------------------------------- dressing

func _dress_room(room: Dictionary) -> void:
	var c: Array = room.get("c", [0, 0])
	var center := Vector2(float(c[0]), float(c[1]))
	var r := float(room.get("r", 20.0))
	var kind := String(room.get("kind", "web"))
	if kind == "camp":
		_build_camp(center)
		return
	if kind == "stair":
		return
	_crags(center, r, 7 if kind != "slime" else 4)
	_webs(center, r, 7 if kind == "web" else 3)
	_fungi(center, r, kind)
	match kind:
		"bone":
			_bones(center, r * 0.7, 26)
		"egg":
			_egg_clusters(center, r, 3)
		"slime":
			_slime_pools(center, r)
	if String(room.get("id", "")) == "f1_cocoons":
		_cocoons(center, r, 9)

## A point near the rim of a room (inside it), angle random.
func _rim_point(center: Vector2, r: float, inset: float) -> Vector2:
	var a := _rng.randf() * TAU
	var d := r - inset - _rng.randf() * 3.0
	return center + Vector2(cos(a), sin(a)) * d

func _crags(center: Vector2, r: float, count: int) -> void:
	var mm := MultiMesh.new()
	mm.transform_format = MultiMesh.TRANSFORM_3D
	var cone := CylinderMesh.new()
	cone.top_radius = 0.0
	cone.bottom_radius = 1.0
	cone.height = 1.0
	cone.radial_segments = 7
	cone.rings = 1
	cone.material = _rock
	mm.mesh = cone
	mm.instance_count = count * 3
	var k := 0
	for i in count:
		var p := _rim_point(center, r, 4.0)
		# A clump: one tall spike and two small ones.
		for j in 3:
			var off: Vector2 = Vector2(_rng.randf_range(-2.2, 2.2), _rng.randf_range(-2.2, 2.2)) if j > 0 else Vector2.ZERO
			var h: float = _rng.randf_range(4.0, 9.0) if j == 0 else _rng.randf_range(1.5, 3.5)
			var w := h * _rng.randf_range(0.18, 0.28)
			var g := _on_ground(p.x + off.x, p.y + off.y)
			var basis := Basis(Vector3.UP, _rng.randf() * TAU) * Basis.from_scale(Vector3(w, h, w))
			basis = Basis(Vector3(_rng.randf_range(-1, 1), 0, _rng.randf_range(-1, 1)).normalized(), _rng.randf_range(0.0, 0.12)) * basis
			mm.set_instance_transform(k, Transform3D(basis, g + Vector3(0, h * 0.5 - 0.3, 0)))
			k += 1
	var inst := MultiMeshInstance3D.new()
	inst.name = "Crags"
	inst.multimesh = mm
	inst.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	add_child(inst)

## Orb webs stretched between the rim crags, facing the room's centre.
func _webs(center: Vector2, r: float, count: int) -> void:
	var mat := ShaderMaterial.new()
	mat.shader = WEB_SHADER
	var mm := MultiMesh.new()
	mm.transform_format = MultiMesh.TRANSFORM_3D
	mm.use_custom_data = true
	var quad := QuadMesh.new()
	quad.size = Vector2(1, 1)
	quad.material = mat
	mm.mesh = quad
	mm.instance_count = count
	for i in count:
		var p := _rim_point(center, r, 1.0)
		var s := _rng.randf_range(4.0, 9.0)
		var g := _on_ground(p.x, p.y)
		var to_center := Vector3(center.x - p.x, 0, center.y - p.y).normalized()
		var basis := Basis.looking_at(-to_center, Vector3.UP)
		basis = basis * Basis(Vector3.RIGHT, _rng.randf_range(-0.35, 0.15)) * Basis(Vector3.FORWARD, _rng.randf() * TAU)
		mm.set_instance_transform(i, Transform3D(basis.scaled_local(Vector3(s, s, 1)), g + Vector3(0, s * 0.55, 0)))
		mm.set_instance_custom_data(i, Color(_rng.randf(), 0, 0, 0))
	var inst := MultiMeshInstance3D.new()
	inst.name = "Webs"
	inst.multimesh = mm
	inst.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	add_child(inst)

## Bioluminescent fungi clusters at the room's edge; a few carry a light.
func _fungi(center: Vector2, r: float, kind: String) -> void:
	var glow := Color(0.35, 1.0, 0.75) if kind != "egg" else Color(0.75, 0.45, 1.0)
	var cap := StandardMaterial3D.new()
	cap.albedo_color = glow.darkened(0.5)
	cap.emission_enabled = true
	cap.emission = glow
	cap.emission_energy_multiplier = 2.4
	var mm := MultiMesh.new()
	mm.transform_format = MultiMesh.TRANSFORM_3D
	var sphere := SphereMesh.new()
	sphere.radius = 0.5
	sphere.height = 0.5
	sphere.is_hemisphere = true
	sphere.radial_segments = 8
	sphere.rings = 3
	sphere.material = cap
	mm.mesh = sphere
	var clusters := 3
	mm.instance_count = clusters * 7
	var k := 0
	for i in clusters:
		var p := _rim_point(center, r, 2.5)
		for j in 7:
			var q := p + Vector2(_rng.randf_range(-1.6, 1.6), _rng.randf_range(-1.6, 1.6))
			var s := _rng.randf_range(0.25, 0.8)
			mm.set_instance_transform(k, Transform3D(Basis.from_scale(Vector3(s, s * 0.8, s)), _on_ground(q.x, q.y) + Vector3(0, s * 0.35, 0)))
			k += 1
		if i == 0:
			_light(_on_ground(p.x, p.y) + Vector3(0, 1.4, 0), glow, 1.6, 13.0)
	var inst := MultiMeshInstance3D.new()
	inst.name = "Fungi"
	inst.multimesh = mm
	inst.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	add_child(inst)

func _bones(center: Vector2, r: float, count: int) -> void:
	var bone := StandardMaterial3D.new()
	bone.albedo_color = Color(0.78, 0.74, 0.64)
	bone.roughness = 0.8
	var mm := MultiMesh.new()
	mm.transform_format = MultiMesh.TRANSFORM_3D
	var cap := CapsuleMesh.new()
	cap.radius = 0.06
	cap.height = 0.9
	cap.radial_segments = 6
	cap.rings = 1
	cap.material = bone
	mm.mesh = cap
	mm.instance_count = count
	for i in count:
		var a := _rng.randf() * TAU
		var d := sqrt(_rng.randf()) * r
		var p := center + Vector2(cos(a), sin(a)) * d
		var basis := Basis(Vector3.UP, _rng.randf() * TAU) * Basis(Vector3.RIGHT, PI * 0.5 + _rng.randf_range(-0.2, 0.2))
		mm.set_instance_transform(i, Transform3D(basis.scaled(Vector3.ONE * _rng.randf_range(0.7, 1.6)), _on_ground(p.x, p.y) + Vector3(0, 0.06, 0)))
	var inst := MultiMeshInstance3D.new()
	inst.name = "Bones"
	inst.multimesh = mm
	add_child(inst)

func _egg_clusters(center: Vector2, r: float, count: int) -> void:
	var egg := StandardMaterial3D.new()
	egg.albedo_color = Color(0.86, 0.82, 0.7)
	egg.roughness = 0.35
	egg.emission_enabled = true
	egg.emission = Color(0.55, 0.3, 0.75)
	egg.emission_energy_multiplier = 0.9
	egg.rim_enabled = true
	egg.rim = 0.6
	egg.subsurf_scatter_enabled = false
	for i in count:
		var p := _rim_point(center, r, 5.0)
		var root := Node3D.new()
		root.name = "EggSacs"
		root.position = _on_ground(p.x, p.y)
		add_child(root)
		for j in _rng.randi_range(5, 9):
			var m := MeshInstance3D.new()
			var s := SphereMesh.new()
			var rad := _rng.randf_range(0.45, 1.0)
			s.radius = rad
			s.height = rad * 2.3
			s.radial_segments = 12
			s.rings = 6
			m.mesh = s
			m.material_override = egg
			m.position = Vector3(_rng.randf_range(-1.8, 1.8), rad * 0.9, _rng.randf_range(-1.8, 1.8))
			m.rotation = Vector3(_rng.randf_range(-0.3, 0.3), 0, _rng.randf_range(-0.3, 0.3))
			root.add_child(m)
		_light(root.position + Vector3(0, 1.6, 0), Color(0.7, 0.4, 1.0), 1.8, 12.0)

func _slime_pools(center: Vector2, r: float) -> void:
	var slime := StandardMaterial3D.new()
	slime.albedo_color = Color(0.04, 0.08, 0.03)
	slime.roughness = 0.05
	slime.metallic_specular = 1.0
	slime.emission_enabled = true
	slime.emission = Color(0.2, 0.7, 0.12)
	slime.emission_energy_multiplier = 0.12
	for i in 4:
		var a := _rng.randf() * TAU
		var p := center + Vector2(cos(a), sin(a)) * _rng.randf_range(0.0, r * 0.6)
		var m := MeshInstance3D.new()
		var cyl := CylinderMesh.new()
		var rad := _rng.randf_range(2.5, 5.5)
		cyl.top_radius = rad
		cyl.bottom_radius = rad
		cyl.height = 0.05
		cyl.radial_segments = 20
		m.mesh = cyl
		m.material_override = slime
		m.scale = Vector3(1.0, 1.0, _rng.randf_range(0.6, 1.0))
		m.rotation.y = _rng.randf() * TAU
		m.position = _on_ground(p.x, p.y) + Vector3(0, 0.08, 0)
		add_child(m)
	_light(_on_ground(center.x, center.y) + Vector3(0, 2.0, 0), Color(0.4, 1.0, 0.3), 1.2, 16.0)

## Silk-wrapped victims hanging from the dark above the room.
func _cocoons(center: Vector2, r: float, count: int) -> void:
	var silk := StandardMaterial3D.new()
	silk.albedo_color = Color(0.8, 0.8, 0.78)
	silk.roughness = 0.9
	for i in count:
		var a := _rng.randf() * TAU
		var p := center + Vector2(cos(a), sin(a)) * _rng.randf_range(4.0, r - 4.0)
		var m := MeshInstance3D.new()
		var cap := CapsuleMesh.new()
		cap.radius = 0.45
		cap.height = 2.1
		cap.radial_segments = 10
		cap.rings = 4
		m.mesh = cap
		m.material_override = silk
		var hang := _rng.randf_range(3.0, 6.0)
		m.position = _on_ground(p.x, p.y) + Vector3(0, hang, 0)
		m.rotation = Vector3(_rng.randf_range(-0.15, 0.15), _rng.randf() * TAU, _rng.randf_range(-0.15, 0.15))
		add_child(m)
		var thread := MeshInstance3D.new()
		var line := CylinderMesh.new()
		line.top_radius = 0.025
		line.bottom_radius = 0.025
		line.height = 20.0
		line.radial_segments = 4
		thread.mesh = line
		thread.material_override = silk
		thread.position = m.position + Vector3(0, 11.0, 0)
		add_child(thread)

# ------------------------------------------------------------------- camp

func _build_camp(center: Vector2) -> void:
	var canvas := StandardMaterial3D.new()
	canvas.albedo_color = Color(0.55, 0.47, 0.36)
	canvas.roughness = 0.95
	var wood := StandardMaterial3D.new()
	wood.albedo_color = Color(0.3, 0.2, 0.12)
	wood.roughness = 0.9
	# Tent: a prism.
	var tent := MeshInstance3D.new()
	var prism := PrismMesh.new()
	prism.size = Vector3(4.2, 2.6, 5.0)
	tent.mesh = prism
	tent.material_override = canvas
	tent.position = _on_ground(center.x - 9.0, center.y - 6.0) + Vector3(0, 1.3, 0)
	tent.rotation.y = 0.5
	add_child(tent)
	# Crates and barrels.
	for i in 6:
		var b := MeshInstance3D.new()
		var box := BoxMesh.new()
		var s := _rng.randf_range(0.7, 1.1)
		box.size = Vector3(s, s, s)
		b.mesh = box
		b.material_override = wood
		var p := center + Vector2(_rng.randf_range(2.0, 7.0), _rng.randf_range(-9.0, -5.0))
		b.position = _on_ground(p.x, p.y) + Vector3(0, s * 0.5, 0)
		b.rotation.y = _rng.randf() * TAU
		add_child(b)
	# Campfire: stones, embers and a warm flickerless light.
	var fire_at := _on_ground(center.x, center.y)
	var ember := StandardMaterial3D.new()
	ember.albedo_color = Color(1.0, 0.45, 0.15)
	ember.emission_enabled = true
	ember.emission = Color(1.0, 0.45, 0.12)
	ember.emission_energy_multiplier = 4.0
	var coals := MeshInstance3D.new()
	var dome := SphereMesh.new()
	dome.radius = 0.6
	dome.height = 0.5
	dome.is_hemisphere = true
	coals.mesh = dome
	coals.material_override = ember
	coals.position = fire_at
	add_child(coals)
	for i in 8:
		var a := TAU * float(i) / 8.0
		var st := MeshInstance3D.new()
		var sm := SphereMesh.new()
		sm.radius = 0.28
		sm.height = 0.4
		st.mesh = sm
		st.material_override = _rock
		st.position = fire_at + Vector3(cos(a) * 0.95, 0.12, sin(a) * 0.95)
		add_child(st)
	_light(fire_at + Vector3(0, 1.2, 0), Color(1.0, 0.62, 0.32), 3.0, 22.0)
	# The camp hearth is the Floo Network fireplace (TravelNodes, travel.json).
	# Lanterns on posts around the camp.
	for a in [0.6, 2.4, 4.1]:
		var p := center + Vector2(cos(a), sin(a)) * 13.0
		var g := _on_ground(p.x, p.y)
		var post := MeshInstance3D.new()
		var cyl := CylinderMesh.new()
		cyl.top_radius = 0.07
		cyl.bottom_radius = 0.09
		cyl.height = 2.4
		post.mesh = cyl
		post.material_override = wood
		post.position = g + Vector3(0, 1.2, 0)
		add_child(post)
		var lamp := MeshInstance3D.new()
		var ls := SphereMesh.new()
		ls.radius = 0.16
		ls.height = 0.32
		lamp.mesh = ls
		lamp.material_override = ember
		lamp.position = g + Vector3(0, 2.45, 0)
		add_child(lamp)
		_light(g + Vector3(0, 2.4, 0), Color(1.0, 0.7, 0.4), 1.4, 11.0)

## The way back up: worn steps climbing north-west into the rock to the crypt's
## undercroft door (the portal trigger is at the stair foot, maps.json
## `caverns_ascend`).
func _build_crypt_stair() -> void:
	var foot := Vector2(-209.0, -209.0)
	var dir := Vector2(-1, -1).normalized()
	var stone := StandardMaterial3D.new()
	stone.albedo_color = Color(0.36, 0.35, 0.34)
	stone.roughness = 0.9
	var y0 := ground_y(foot.x, foot.y)
	var basis := Basis.looking_at(Vector3(dir.x, 0, dir.y), Vector3.UP)
	for i in 14:
		var p := foot + dir * (float(i) * 0.9)
		var step := MeshInstance3D.new()
		var box := BoxMesh.new()
		box.size = Vector3(5.0, 0.45 + float(i) * 0.42, 0.9)
		step.mesh = box
		step.material_override = stone
		step.basis = basis
		step.position = Vector3(p.x, y0 + box.size.y * 0.5 - 0.2, p.y)
		add_child(step)
	# Door frame and a faint daylight spill from above.
	var top := foot + dir * 13.5
	var top_y := y0 + 14.0 * 0.42 + 0.3
	for side in [-1.0, 1.0]:
		var pillar := MeshInstance3D.new()
		var pb := BoxMesh.new()
		pb.size = Vector3(0.8, 4.2, 0.8)
		pillar.mesh = pb
		pillar.material_override = stone
		var off: Vector3 = Vector3(dir.y, 0, -dir.x) * 2.6 * float(side)
		pillar.position = Vector3(top.x, top_y + 2.1, top.y) + off
		add_child(pillar)
	var lintel := MeshInstance3D.new()
	var lb := BoxMesh.new()
	lb.size = Vector3(6.0, 0.7, 0.9)
	lintel.mesh = lb
	lintel.material_override = stone
	lintel.basis = basis
	lintel.position = Vector3(top.x, top_y + 4.5, top.y)
	add_child(lintel)
	_light(Vector3(top.x, top_y + 3.0, top.y), Color(0.7, 0.78, 0.95), 2.2, 16.0)
	_light(Vector3(foot.x, y0 + 2.5, foot.y), Color(1.0, 0.66, 0.38), 1.4, 10.0)

func _light(at: Vector3, color: Color, energy: float, reach: float) -> void:
	var l := OmniLight3D.new()
	l.light_color = color
	l.light_energy = energy
	l.omni_range = reach
	l.omni_attenuation = 1.4
	l.shadow_enabled = false
	l.position = at
	add_child(l)
	_lights += 1
