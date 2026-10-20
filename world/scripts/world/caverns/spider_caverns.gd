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
## node is presentation only: the shaded ground (Poly Haven CC0 cave sets), the
## baked props (stalagmites, egg clutches, cocoons, bone heaps, glowing
## mushrooms, the camp, the crypt gate), dew webs, venom pools and drifting
## spores/mist. A dedicated server never loads it.

const LAYOUT_PATH := "res://assets/maps/spider_caverns/cavern_layout.json"
const TERRAIN_PATH := "res://assets/maps/spider_caverns/cavern_terrain.glb"
const HEIGHT_PATH := "res://assets/maps/spider_caverns/cavern_height.res"
const GROUND_SHADER := preload("res://assets/shaders/cavern_ground.gdshader")
const WEB_SHADER := preload("res://assets/shaders/cobweb.gdshader")
const SLIME_SHADER := preload("res://assets/shaders/slime_pool.gdshader")
const WEB_TEX := "res://assets/vfx/tex/cobweb_1024.png"
## Baked cavern props (art/spider_caverns/concepts -> Hunyuan/Meshy -> prop_bake.py).
const PROP := "res://assets/models/caverns/cavern_%s.glb"
const MOTE_TEX := "res://assets/vfx/tex/soft_glow_512.png"
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
var _meshes: Dictionary = {}   # prop|glow -> Mesh

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
	_rock.albedo_texture = load(TEX % "cave_wall_alb_ht")
	_rock.albedo_color = Color(0.85, 0.82, 0.85)
	_rock.normal_enabled = true
	_rock.normal_texture = load(TEX % "cave_wall_nrm_rgh")
	_rock.uv1_triplanar = true
	_rock.uv1_world_triplanar = true
	_rock.uv1_scale = Vector3(0.3, 0.3, 0.3)
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
	mat.set_shader_parameter("rock_alb", load(TEX % "cave_wall_alb_ht"))
	mat.set_shader_parameter("rock_nrm", load(TEX % "cave_wall_nrm_rgh"))
	mat.set_shader_parameter("dust_alb", load(TEX % "cave_dust_alb_ht"))
	mat.set_shader_parameter("dust_nrm", load(TEX % "cave_dust_nrm_rgh"))
	mat.set_shader_parameter("gravel_alb", load(TEX % "cave_gravel_alb_ht"))
	mat.set_shader_parameter("gravel_nrm", load(TEX % "cave_gravel_nrm_rgh"))
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
	_crags(center, r, 6 if kind != "slime" else 4)
	_webs(center, r, 7 if kind == "web" else 3)
	_fungi(center, r, kind)
	_spores(center, r, kind)
	match kind:
		"bone":
			_bones(center, r * 0.7, 4)
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

## The mesh of a baked prop (assets/models/caverns, art/pipeline prop_bake.py),
## cached; with `glow` its materials also light up their own albedo.
func _prop_mesh(prop: String, glow: Color = Color(0, 0, 0, 0), energy: float = 1.0) -> Mesh:
	var key := "%s|%s" % [prop, glow]
	if _meshes.has(key):
		return _meshes[key]
	var path := PROP % prop
	var mesh: Mesh = null
	if ResourceLoader.exists(path):
		var scene: Node = (load(path) as PackedScene).instantiate()
		var found := scene.find_children("*", "MeshInstance3D", true, false)
		if not found.is_empty():
			mesh = (found[0] as MeshInstance3D).mesh
		scene.free()
	if mesh != null and glow.a > 0.0:
		mesh = mesh.duplicate()
		for i in mesh.get_surface_count():
			var src := mesh.surface_get_material(i) as BaseMaterial3D
			if src == null:
				continue
			var lit := src.duplicate() as BaseMaterial3D
			lit.emission_enabled = true
			lit.emission = glow
			lit.emission_texture = src.albedo_texture
			lit.emission_energy_multiplier = energy
			mesh.surface_set_material(i, lit)
	_meshes[key] = mesh
	return mesh

## One MultiMesh of a prop at `xforms`.
func _scatter(prop: String, xforms: Array, node_name: String, glow: Color = Color(0, 0, 0, 0), energy: float = 1.0) -> void:
	var mesh := _prop_mesh(prop, glow, energy)
	if mesh == null or xforms.is_empty():
		return
	var mm := MultiMesh.new()
	mm.transform_format = MultiMesh.TRANSFORM_3D
	mm.mesh = mesh
	mm.instance_count = xforms.size()
	for i in xforms.size():
		mm.set_instance_transform(i, xforms[i])
	var inst := MultiMeshInstance3D.new()
	inst.name = node_name
	inst.multimesh = mm
	inst.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	add_child(inst)

## A prop standing on the ground at `p`, turned `yaw`, sunk `sink` metres.
func _stand(p: Vector2, yaw: float, s: float, sink: float = 0.15, tilt: float = 0.0) -> Transform3D:
	var basis := Basis(Vector3.UP, yaw).scaled(Vector3.ONE * s)
	if tilt > 0.0:
		basis = Basis(Vector3(_rng.randf_range(-1, 1), 0, _rng.randf_range(-1, 1)).normalized(), tilt) * basis
	return Transform3D(basis, _on_ground(p.x, p.y) - Vector3(0, sink, 0))

## Stalagmite clumps along the rim: one big spire group and a small one.
func _crags(center: Vector2, r: float, count: int) -> void:
	var xforms: Array = []
	for i in count:
		var p := _rim_point(center, r, 3.5)
		xforms.append(_stand(p, _rng.randf() * TAU, _rng.randf_range(0.55, 1.05), 0.5, _rng.randf_range(0.0, 0.08)))
		var q := p + Vector2(_rng.randf_range(-4.0, 4.0), _rng.randf_range(-4.0, 4.0))
		xforms.append(_stand(q, _rng.randf() * TAU, _rng.randf_range(0.2, 0.35), 0.2, _rng.randf_range(0.0, 0.15)))
	_scatter("stalag", xforms, "Crags")

## Dew-beaded orb webs strung along the rim, facing the room's centre.
func _webs(center: Vector2, r: float, count: int) -> void:
	var mat := ShaderMaterial.new()
	mat.shader = WEB_SHADER
	mat.set_shader_parameter("web", load(WEB_TEX))
	var mm := MultiMesh.new()
	mm.transform_format = MultiMesh.TRANSFORM_3D
	mm.use_custom_data = true
	var quad := QuadMesh.new()
	quad.size = Vector2(1, 1)
	quad.material = mat
	mm.mesh = quad
	mm.instance_count = count
	for i in count:
		var p := _rim_point(center, r, 1.5)
		var s := _rng.randf_range(5.0, 10.0)
		var g := _on_ground(p.x, p.y)
		var to_center := Vector3(center.x - p.x, 0, center.y - p.y).normalized()
		var basis := Basis.looking_at(-to_center, Vector3.UP)
		basis = basis * Basis(Vector3.RIGHT, _rng.randf_range(-0.45, 0.1)) * Basis(Vector3.FORWARD, _rng.randf() * TAU)
		mm.set_instance_transform(i, Transform3D(basis.scaled_local(Vector3(s, s, 1)), g + Vector3(0, s * 0.5 + _rng.randf_range(0.5, 3.0), 0)))
		mm.set_instance_custom_data(i, Color(_rng.randf(), 0, 0, 0))
	var inst := MultiMeshInstance3D.new()
	inst.name = "Webs"
	inst.multimesh = mm
	inst.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	add_child(inst)

## Bioluminescent mushroom clumps at the room's edge; one carries a light.
func _fungi(center: Vector2, r: float, kind: String) -> void:
	var glow := Color(0.35, 1.0, 0.8) if kind != "egg" else Color(0.75, 0.5, 1.0)
	var xforms: Array = []
	for i in 4:
		var p := _rim_point(center, r, 3.0)
		xforms.append(_stand(p, _rng.randf() * TAU, _rng.randf_range(1.2, 2.2), 0.1))
		if i == 0:
			_light(_on_ground(p.x, p.y) + Vector3(0, 2.6, 0), glow, 1.2, 14.0)
	_scatter("mushrooms", xforms, "Fungi", glow, 0.14)

## Glowing spores drifting slowly up through the room's air (GPU motes).
func _spores(center: Vector2, r: float, kind: String) -> void:
	var tint := Color(0.55, 1.0, 0.8) if kind != "egg" else Color(0.85, 0.6, 1.0)
	var pm := ParticleProcessMaterial.new()
	pm.emission_shape = ParticleProcessMaterial.EMISSION_SHAPE_BOX
	pm.emission_box_extents = Vector3(r * 0.8, 3.0, r * 0.8)
	pm.direction = Vector3.UP
	pm.spread = 60.0
	pm.initial_velocity_min = 0.08
	pm.initial_velocity_max = 0.3
	pm.gravity = Vector3(0, 0.03, 0)
	pm.scale_min = 0.04
	pm.scale_max = 0.1
	var ramp := Gradient.new()
	ramp.set_color(0, Color(tint, 0.0))
	ramp.set_color(1, Color(tint, 0.0))
	ramp.add_point(0.25, tint)
	ramp.add_point(0.75, tint)
	var ramp_tex := GradientTexture1D.new()
	ramp_tex.gradient = ramp
	pm.color_ramp = ramp_tex
	var mote := StandardMaterial3D.new()
	mote.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	mote.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	mote.blend_mode = BaseMaterial3D.BLEND_MODE_ADD
	mote.billboard_mode = BaseMaterial3D.BILLBOARD_PARTICLES
	mote.vertex_color_use_as_albedo = true
	mote.albedo_texture = load(MOTE_TEX)
	var quad := QuadMesh.new()
	quad.material = mote
	var p := GPUParticles3D.new()
	p.name = "Spores"
	p.amount = int(r * 1.8)
	p.lifetime = 9.0
	p.preprocess = 9.0
	p.process_material = pm
	p.draw_pass_1 = quad
	p.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	p.visibility_aabb = AABB(Vector3(-r, -4.0, -r), Vector3(r * 2.0, 14.0, r * 2.0))
	p.position = _on_ground(center.x, center.y) + Vector3(0, 3.5, 0)
	add_child(p)

## Bone heaps scattered over the floor (the Kemik rooms).
func _bones(center: Vector2, r: float, count: int) -> void:
	var xforms: Array = []
	for i in count:
		var a := _rng.randf() * TAU
		var p := center + Vector2(cos(a), sin(a)) * sqrt(_rng.randf()) * r
		xforms.append(_stand(p, _rng.randf() * TAU, _rng.randf_range(0.8, 1.4), 0.05))
	_scatter("bones", xforms, "Bones")

## Silk-wrapped egg clutches with a faint violet pulse.
func _egg_clusters(center: Vector2, r: float, count: int) -> void:
	var xforms: Array = []
	for i in count:
		var p := _rim_point(center, r, 5.0)
		xforms.append(_stand(p, _rng.randf() * TAU, _rng.randf_range(1.0, 1.5), 0.1))
		var q := p + Vector2(_rng.randf_range(-3.5, 3.5), _rng.randf_range(-3.5, 3.5))
		xforms.append(_stand(q, _rng.randf() * TAU, _rng.randf_range(0.5, 0.75), 0.05))
		_light(_on_ground(p.x, p.y) + Vector3(0, 1.8, 0), Color(0.7, 0.4, 1.0), 1.8, 12.0)
	_scatter("eggs", xforms, "EggSacs", Color(0.55, 0.3, 0.8), 0.35)

## Venom pools: a shoreline-cut glossy quad each, a green mist over them.
func _slime_pools(center: Vector2, r: float) -> void:
	for i in 4:
		var a := _rng.randf() * TAU
		var p := center + Vector2(cos(a), sin(a)) * _rng.randf_range(0.0, r * 0.6)
		var rad := _rng.randf_range(3.0, 6.0)
		var mat := ShaderMaterial.new()
		mat.shader = SLIME_SHADER
		mat.set_shader_parameter("seed", _rng.randf() * 10.0)
		var quad := QuadMesh.new()
		quad.size = Vector2(rad * 2.0, rad * 2.0)
		quad.orientation = PlaneMesh.FACE_Y
		var m := MeshInstance3D.new()
		m.name = "VenomPool"
		m.mesh = quad
		m.material_override = mat
		m.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		m.scale = Vector3(1.0, 1.0, _rng.randf_range(0.65, 1.0))
		m.rotation.y = _rng.randf() * TAU
		m.position = _on_ground(p.x, p.y) + Vector3(0, 0.06, 0)
		add_child(m)
		FlipbookFX.play(self, m.position, [
			{"atlas": "toxic_mist_8x8_1k", "size": Vector2(rad * 2.2, rad * 1.1), "height": rad * 0.4, "fps": 9.0,
				"loop": true, "opacity": 0.28, "tint": Color(0.6, 1.0, 0.45), "delay": -_rng.randf() * 5.0, "fade_in": 0.01},
		], {"life": 0.0, "name": "VenomMist"})
	_light(_on_ground(center.x, center.y) + Vector3(0, 2.5, 0), Color(0.4, 1.0, 0.3), 1.6, 20.0)

## Silk-wrapped victims hanging from the dark above the room.
func _cocoons(center: Vector2, r: float, count: int) -> void:
	var silk := StandardMaterial3D.new()
	silk.albedo_color = Color(0.75, 0.76, 0.74)
	silk.roughness = 0.9
	var xforms: Array = []
	for i in count:
		var a := _rng.randf() * TAU
		var p := center + Vector2(cos(a), sin(a)) * _rng.randf_range(4.0, r - 4.0)
		var s := _rng.randf_range(0.9, 1.25)
		var base := _on_ground(p.x, p.y) + Vector3(0, _rng.randf_range(2.5, 5.0), 0)
		var basis := Basis(Vector3.UP, _rng.randf() * TAU) * Basis(Vector3.RIGHT, _rng.randf_range(-0.12, 0.12))
		xforms.append(Transform3D(basis.scaled(Vector3.ONE * s), base))
		var thread := MeshInstance3D.new()
		var line := CylinderMesh.new()
		line.top_radius = 0.02
		line.bottom_radius = 0.03
		line.height = 20.0
		line.radial_segments = 4
		thread.mesh = line
		thread.material_override = silk
		thread.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		thread.position = base + Vector3(0, 2.3 * s + 10.0, 0)
		add_child(thread)
	_scatter("cocoon", xforms, "Cocoons")

# ------------------------------------------------------------------- camp

func _build_camp(center: Vector2) -> void:
	# The explorers' tent with its crates and barrels, facing the fire.
	var tent_at := center + Vector2(-9.0, -6.0)
	var to_fire := center - tent_at
	_scatter("camp", [_stand(tent_at, atan2(to_fire.x, to_fire.y), 1.0, 0.1)], "Camp")
	_scatter("bones", [_stand(center + Vector2(10.0, 9.0), 1.1, 0.9, 0.05)], "CampBones")
	# Campfire: stones, embers and a warm light.
	var fire_at := _on_ground(center.x, center.y)
	var ember := StandardMaterial3D.new()
	ember.albedo_color = Color(1.0, 0.45, 0.15)
	ember.emission_enabled = true
	ember.emission = Color(1.0, 0.45, 0.12)
	ember.emission_energy_multiplier = 1.6
	var coals := MeshInstance3D.new()
	var dome := SphereMesh.new()
	dome.radius = 0.6
	dome.height = 0.5
	dome.is_hemisphere = true
	coals.mesh = dome
	coals.material_override = ember
	coals.position = fire_at
	add_child(coals)
	# Flames over the coals: three flipbook cards of different heights.
	for k in 3:
		var off := Vector3(cos(TAU * k / 3.0), 0.0, sin(TAU * k / 3.0)) * 0.22
		FireCard.make(self, fire_at + off + Vector3(0, 0.55, 0), Vector2(0.75, 1.15) * (1.0 - 0.15 * k), Color(1, 1, 1), 1.5)
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
	var wood := StandardMaterial3D.new()
	wood.albedo_color = Color(0.3, 0.2, 0.12)
	wood.roughness = 0.9
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
		FireCard.make(self, g + Vector3(0, 2.52, 0), Vector2(0.34, 0.52), Color(1, 1, 1), 1.4)
		_light(g + Vector3(0, 2.4, 0), Color(1.0, 0.7, 0.4), 1.4, 11.0)

## The way back up: worn steps climbing north-west into the rock to the crypt's
## undercroft gate (the portal trigger is at the stair foot, maps.json
## `caverns_ascend`).
func _build_crypt_stair() -> void:
	var foot := Vector2(-209.0, -209.0)
	var dir := Vector2(-1, -1).normalized()
	var y0 := ground_y(foot.x, foot.y)
	var basis := Basis.looking_at(Vector3(dir.x, 0, dir.y), Vector3.UP)
	for i in 14:
		var p := foot + dir * (float(i) * 0.9)
		var step := MeshInstance3D.new()
		var box := BoxMesh.new()
		box.size = Vector3(5.0, 0.45 + float(i) * 0.42, 0.9)
		step.mesh = box
		step.material_override = _rock
		step.basis = basis
		step.position = Vector3(p.x, y0 + box.size.y * 0.5 - 0.2, p.y)
		add_child(step)
	# The crypt gate at the top (its front faces back down the stair) and a
	# faint daylight spill from above.
	var top := foot + dir * 13.5
	var top_y := y0 + 14.0 * 0.42 + 0.3
	# The gate's doorway meets the steps where they enter the rock face.
	var gate_at := foot + dir * 6.0
	var gate := Transform3D(basis, Vector3(gate_at.x, y0 + 1.7, gate_at.y))
	_scatter("arch", [gate], "CryptGate")
	_light(Vector3(top.x, top_y + 3.0, top.y) - Vector3(dir.x, 0, dir.y) * 2.0, Color(0.7, 0.78, 0.95), 2.2, 16.0)
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
