extends RefCounted

## Living dressing of the castle's hero rooms (docs/castle-interior.md, F3):
## what the static glb cannot carry because it moves, glows or depends on the
## quality preset.
##   * Great Hall: hundreds of floating candles (one MultiMesh for the wax, one
##     for the flames, bobbing in the shaders), a few warm lights standing in
##     for them, the enchanted ceiling (a material slot on the vault webs);
##   * Entrance Hall: two iron ring chandeliers with candles and a warm light;
##   * moonlight through the windows (a shadowed directional light the
##     volumetric fog turns into beams on medium and high).
## Client only - the dedicated server never builds it.

const QualityPreset = preload("res://scripts/world/quality_preset.gd")
const StaticMerge = preload("res://scripts/world/static_merge.gd")
const CANDLE_SHADER := preload("res://assets/shaders/castle/floating_candle.gdshader")
const FLAME_SHADER := preload("res://assets/shaders/castle/candle_flame.gdshader")

## Great Hall candle volume (layout space): above the four house tables.
const HALL_CANDLES := {"x": [-92.0, -24.0], "z": [44.0, 68.0], "y": [10.5, 16.5]}
const HALL_CANDLE_COUNT := {"low": 140, "medium": 260, "high": 420}


static func build(parent: Node3D, map_y: float, quality: String = "") -> Node3D:
	if quality == "":
		quality = QualityPreset.current()
	var root := Node3D.new()
	root.name = "CastleDecor"
	parent.add_child(root)
	_floating_candles(root, map_y, int(HALL_CANDLE_COUNT.get(quality, 260)))
	_hall_candle_lights(root, map_y)
	# Two shadowed omni lights re-render a cube shadow map every frame anyone
	# moves under them (~330 draw calls); low keeps the light, not its shadow.
	for z in [31.0, 52.0]:
		_chandelier(root, Vector3(0.0, map_y + 15.0, z), 3.2, 18, quality != "low")
	# Entrance Hall wall sconces: a torch per bay on both long walls.
	for z in [27.3, 42.0, 56.7]:
		for side in [-1.0, 1.0]:
			_sconce(root, Vector3(side * 17.6, map_y + 7.0, z), -side)
	_moonlight(root, quality)
	# Room light sources authored in the glb as FX_<kind>_<n> empties
	# (art/castle/scripts/castle_rooms.py).
	_build_fx(parent, root, quality)
	# Hero props (fal image-to-3D, assets/castle/props/): the golden owl lectern
	# at the front of the dais, two suits of armour guarding the Great Hall doors.
	_prop(root, "owl_lectern", Vector3(-96.2, map_y + 1.0, 56.0), 90.0, 1.75)
	for z in [49.6, 62.4]:
		_prop(root, "armour", Vector3(-17.15, map_y, z), 90.0, 2.45)
	_batch(root)
	return root


## The iron, glass and wax of every sconce, lantern and chandelier above are
## ~500 primitive meshes; batch them per material on a 16 m grid (a batch
## still culls with its room). Flames (shader cards that face the camera),
## candle MultiMeshes and the glb props stay as they are.
static func _batch(root: Node3D) -> void:
	var pieces: Array = []
	for node in root.find_children("*", "MeshInstance3D", true, false):
		var mi := node as MeshInstance3D
		if not (mi.mesh is PrimitiveMesh) or mi.mesh is QuadMesh:
			continue
		var plain := true
		for s in mi.mesh.get_surface_count():
			plain = plain and mi.get_active_material(s) is StandardMaterial3D
		if plain:
			pieces.append(mi)
	StaticMerge.merge(root, pieces, "DecorBatch", 16.0)


## Place a prop glb scaled to `height` metres, standing on `at`, turned `yaw_deg`
## (0 = the model's front faces +z). A box collider keeps bodies out of it.
static func _prop(root: Node3D, prop_name: String, at: Vector3, yaw_deg: float, height: float) -> void:
	var path := "res://assets/castle/props/%s.glb" % prop_name
	if not ResourceLoader.exists(path):
		return
	var scene := (load(path) as PackedScene).instantiate() as Node3D
	var holder := Node3D.new()
	holder.name = prop_name.capitalize().replace(" ", "")
	root.add_child(holder)
	holder.add_child(scene)
	var box := _visual_aabb(scene)
	if box.size.y <= 0.001:
		return
	var s := height / box.size.y
	scene.scale = Vector3.ONE * s
	scene.position = -Vector3(box.get_center().x, box.position.y, box.get_center().z) * s
	holder.position = at
	holder.rotation_degrees.y = yaw_deg
	var body := StaticBody3D.new()
	var cs := CollisionShape3D.new()
	var shape := BoxShape3D.new()
	shape.size = Vector3(box.size.x * s * 0.8, height, box.size.z * s * 0.8)
	cs.shape = shape
	cs.position = Vector3(0, height * 0.5, 0)
	body.add_child(cs)
	holder.add_child(body)


static func _visual_aabb(node: Node3D) -> AABB:
	var out := AABB()
	var first := true
	for n in node.find_children("*", "MeshInstance3D", true, false):
		var mi := n as MeshInstance3D
		var local := node.global_transform.affine_inverse() * mi.global_transform if mi.is_inside_tree() else mi.transform
		var box: AABB = local * mi.get_aabb()
		out = box if first else out.merge(box)
		first = false
	return out


# --------------------------------------------------------------- candles

static func _floating_candles(root: Node3D, map_y: float, count: int) -> void:
	var rng := RandomNumberGenerator.new()
	rng.seed = 1997
	var body := CylinderMesh.new()
	body.top_radius = 0.07
	body.bottom_radius = 0.08
	body.height = 0.55
	body.radial_segments = 8
	body.rings = 1
	var wax := ShaderMaterial.new()
	wax.shader = CANDLE_SHADER
	body.material = wax
	var flame := QuadMesh.new()
	flame.size = Vector2(0.2, 0.38)
	var fire := ShaderMaterial.new()
	fire.shader = FLAME_SHADER
	flame.material = fire
	var bodies := _multimesh(body, count)
	var flames := _multimesh(flame, count)
	var xs: Array = HALL_CANDLES["x"]
	var zs: Array = HALL_CANDLES["z"]
	var ys: Array = HALL_CANDLES["y"]
	for i in count:
		var p := Vector3(rng.randf_range(xs[0], xs[1]), map_y + rng.randf_range(ys[0], ys[1]),
			rng.randf_range(zs[0], zs[1]))
		var phase := rng.randf()
		var scale := rng.randf_range(0.8, 1.35)
		var basis := Basis().scaled(Vector3(1.0, scale, 1.0))
		bodies.set_instance_transform(i, Transform3D(basis, p))
		bodies.set_instance_custom_data(i, Color(phase, 0, 0, 0))
		flames.set_instance_transform(i, Transform3D(Basis(), p + Vector3(0, 0.275 * scale + 0.14, 0)))
		flames.set_instance_custom_data(i, Color(phase, 0, 0, 0))
	for mm in [bodies, flames]:
		var mmi := MultiMeshInstance3D.new()
		mmi.multimesh = mm
		mmi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		mmi.name = "FloatingCandles" if mm == bodies else "CandleFlames"
		root.add_child(mmi)


static func _multimesh(mesh: Mesh, count: int) -> MultiMesh:
	var mm := MultiMesh.new()
	mm.transform_format = MultiMesh.TRANSFORM_3D
	mm.use_custom_data = true
	mm.mesh = mesh
	mm.instance_count = count
	return mm


## A handful of real lights stand in for hundreds of flames.
static func _hall_candle_lights(root: Node3D, map_y: float) -> void:
	for x in [-84.0, -66.0, -48.0, -30.0]:
		for z in [50.0, 62.0]:
			var light := OmniLight3D.new()
			light.light_color = Color(1.0, 0.72, 0.42)
			light.light_energy = 2.4
			light.omni_range = 22.0
			light.omni_attenuation = 1.2
			light.position = Vector3(x, map_y + 12.5, z)
			light.light_volumetric_fog_energy = 0.6
			root.add_child(light)


# --------------------------------------------------------------- chandeliers

static func _chandelier(root: Node3D, centre: Vector3, radius: float, candles: int, shadowed: bool = true) -> void:
	var node := Node3D.new()
	node.name = "Chandelier"
	node.position = centre
	root.add_child(node)
	var iron := StandardMaterial3D.new()
	iron.albedo_color = Color(0.09, 0.08, 0.08)
	iron.metallic = 0.8
	iron.roughness = 0.45
	var ring := TorusMesh.new()
	ring.inner_radius = radius - 0.09
	ring.outer_radius = radius + 0.09
	ring.rings = 48
	ring.ring_segments = 8
	ring.material = iron
	var ring_mi := MeshInstance3D.new()
	ring_mi.mesh = ring
	node.add_child(ring_mi)
	# chains up to the vault
	for k in 4:
		var ang := k * TAU / 4.0
		var chain := MeshInstance3D.new()
		var cyl := CylinderMesh.new()
		cyl.top_radius = 0.03
		cyl.bottom_radius = 0.03
		cyl.height = 8.0
		cyl.material = iron
		chain.mesh = cyl
		var foot := Vector3(cos(ang) * radius, 0.0, sin(ang) * radius)
		var top := Vector3(0.0, 8.0, 0.0)
		chain.position = (foot + top) * 0.5
		chain.basis = Basis(Quaternion(Vector3.UP, (top - foot).normalized()))
		node.add_child(chain)
	var body := CylinderMesh.new()
	body.top_radius = 0.05
	body.bottom_radius = 0.055
	body.height = 0.32
	body.radial_segments = 8
	var wax := StandardMaterial3D.new()
	wax.albedo_color = Color(0.93, 0.89, 0.78)
	body.material = wax
	var flame := QuadMesh.new()
	flame.size = Vector2(0.1, 0.2)
	var fire := ShaderMaterial.new()
	fire.shader = FLAME_SHADER
	fire.set_shader_parameter("bob_height", 0.0)
	flame.material = fire
	var bodies := _multimesh(body, candles)
	var flames := _multimesh(flame, candles)
	for i in candles:
		var ang := i * TAU / candles
		var p := Vector3(cos(ang) * radius, 0.25, sin(ang) * radius)
		bodies.set_instance_transform(i, Transform3D(Basis(), p))
		flames.set_instance_transform(i, Transform3D(Basis(), p + Vector3(0, 0.25, 0)))
		bodies.set_instance_custom_data(i, Color(float(i) / candles, 0, 0, 0))
		flames.set_instance_custom_data(i, Color(float(i) / candles, 0, 0, 0))
	for mm in [bodies, flames]:
		var mmi := MultiMeshInstance3D.new()
		mmi.multimesh = mm
		mmi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		node.add_child(mmi)
	var light := OmniLight3D.new()
	light.light_color = Color(1.0, 0.74, 0.45)
	light.light_energy = 3.4
	light.omni_range = 26.0
	light.omni_attenuation = 1.1
	light.position = Vector3(0, 0.8, 0)
	light.shadow_enabled = shadowed
	if not shadowed:
		_fade(light, 60.0)
	node.add_child(light)


## A wall torch: iron bracket, a flame card and a warm light, facing `facing_x`.
static func _sconce(root: Node3D, at: Vector3, facing_x: float) -> void:
	var node := Node3D.new()
	node.name = "Sconce"
	node.position = at
	root.add_child(node)
	var iron := StandardMaterial3D.new()
	iron.albedo_color = Color(0.08, 0.07, 0.07)
	iron.metallic = 0.8
	iron.roughness = 0.5
	var arm := MeshInstance3D.new()
	var box := BoxMesh.new()
	box.size = Vector3(0.7, 0.08, 0.08)
	box.material = iron
	arm.mesh = box
	arm.position = Vector3(facing_x * 0.35, 0.0, 0.0)
	node.add_child(arm)
	var cup := MeshInstance3D.new()
	var cone := CylinderMesh.new()
	cone.top_radius = 0.16
	cone.bottom_radius = 0.06
	cone.height = 0.3
	cone.material = iron
	cup.mesh = cone
	cup.position = Vector3(facing_x * 0.7, 0.12, 0.0)
	node.add_child(cup)
	FireCard.make(node, Vector3(facing_x * 0.7, 0.55, 0.0), Vector2(0.42, 0.7))
	var light := OmniLight3D.new()
	light.light_color = Color(1.0, 0.62, 0.32)
	light.light_energy = 2.6
	light.omni_range = 14.0
	light.omni_attenuation = 1.3
	light.position = Vector3(facing_x * 1.0, 0.8, 0.0)
	node.add_child(light)


# --------------------------------------------------------------- moonlight

## Cool moonlight from the south-west, low enough to come in through the long
## south windows of the Great Hall and the Entrance Hall's front lights.
static func _moonlight(root: Node3D, quality: String) -> void:
	var moon := DirectionalLight3D.new()
	moon.name = "Moonlight"
	moon.light_color = Color(0.62, 0.72, 1.0)
	moon.light_energy = 1.3
	moon.light_volumetric_fog_energy = 3.0
	moon.rotation_degrees = Vector3(-32.0, -20.0, 0.0)   # travels north-east
	# Shadowed on every preset: an unshadowed moon floods the floors evenly.
	moon.shadow_enabled = true
	moon.directional_shadow_mode = DirectionalLight3D.SHADOW_PARALLEL_2_SPLITS if quality == "low" \
		else DirectionalLight3D.SHADOW_PARALLEL_4_SPLITS
	moon.directional_shadow_max_distance = 60.0 if quality == "low" else 120.0
	moon.shadow_bias = 0.04
	root.add_child(moon)



# --------------------------------------------------------------- FX points

const FX_WARM := Color(1.0, 0.64, 0.34)
const FX_COLD := Color(0.62, 0.95, 0.82)

static func _build_fx(scan_root: Node, root: Node3D, quality: String) -> void:
	var green_count := 0
	var owls: Array = []
	for node in scan_root.find_children("FX_*", "Node3D", true, false):
		var n := node as Node3D
		var parts := String(n.name).split("_")
		if parts.size() < 3:
			continue
		var kind := "_".join(parts.slice(1, parts.size() - 1))
		var xf := n.global_transform
		var scale := xf.basis.get_scale().x
		var holder := Node3D.new()
		holder.name = "FX_" + kind
		root.add_child(holder)
		holder.global_transform = Transform3D(Basis(Vector3.UP, xf.basis.get_euler().y), xf.origin)
		match kind:
			"sconce":
				_fx_sconce(holder, FX_WARM)
			"sconce_cold":
				_fx_sconce(holder, FX_COLD)
			"fire":
				_fx_fire(holder, scale)
			"green_fire":
				_fx_green_fire(holder, green_count % 3 == 1 and quality != "low")
				green_count += 1
			"lamp":
				_fx_lamp(holder)
			"chandelier":
				_chandelier(holder, Vector3.ZERO, scale, int(scale * 7.0), false)
			"owl":
				owls.append(Transform3D(holder.global_transform.basis.scaled(Vector3.ONE * scale), holder.global_transform.origin))
				holder.queue_free()
	if not owls.is_empty():
		_owl_flock(root, owls)


static func _fade(light: Light3D, begin: float = 38.0) -> void:
	# Far torches cost nothing: they fade out instead of shading the far rooms.
	light.distance_fade_enabled = true
	light.distance_fade_begin = begin
	light.distance_fade_length = 10.0
	light.distance_fade_shadow = 20.0


## A flipbook flame (FireCard); `intensity` is the old card's scale, halved
## for the clip's own brightness.
static func _flame(parent: Node3D, pos: Vector3, size: Vector2, tint: Color = Color(1, 1, 1), intensity: float = 3.0) -> void:
	FireCard.make(parent, pos, size * Vector2(1.1, 1.15), tint, intensity * 0.5)


static func _iron() -> StandardMaterial3D:
	var iron := StandardMaterial3D.new()
	iron.albedo_color = Color(0.08, 0.07, 0.07)
	iron.metallic = 0.8
	iron.roughness = 0.5
	return iron


## A wall torch facing local +Z: bracket, cup, flame, light.
static func _fx_sconce(holder: Node3D, colour: Color) -> void:
	var iron := _iron()
	var arm := MeshInstance3D.new()
	var box := BoxMesh.new()
	box.size = Vector3(0.08, 0.08, 0.7)
	box.material = iron
	arm.mesh = box
	arm.position = Vector3(0, 0, 0.35)
	holder.add_child(arm)
	var cup := MeshInstance3D.new()
	var cone := CylinderMesh.new()
	cone.top_radius = 0.16
	cone.bottom_radius = 0.06
	cone.height = 0.3
	cone.material = iron
	cup.mesh = cone
	cup.position = Vector3(0, 0.12, 0.7)
	holder.add_child(cup)
	_flame(holder, Vector3(0, 0.55, 0.7), Vector2(0.36, 0.6),
		Color(1, 1, 1) if colour == FX_WARM else Color(0.55, 1.0, 0.75))
	var light := OmniLight3D.new()
	light.light_color = colour
	light.light_energy = 2.4
	light.omni_range = 13.0
	light.omni_attenuation = 1.3
	light.position = Vector3(0, 0.8, 1.0)
	_fade(light)
	holder.add_child(light)


## A hearth fire: a few flame cards across the hearth (`scale` ~ width / 4 m),
## staggered in depth and height so the fire has body from any angle.
static func _fx_fire(holder: Node3D, scale: float) -> void:
	for k in 4:
		var x := (float(k) - 1.5) * 0.24 * scale
		var z := 0.08 * float((k * 7) % 3 - 1)
		_flame(holder, Vector3(x, 0.3 + 0.08 * (k % 2), z), Vector2(0.6, 0.95) * (0.8 + 0.2 * scale) * (1.0 - 0.12 * (k % 2)), Color(1, 1, 1), 3.2)
	var light := OmniLight3D.new()
	light.light_color = Color(1.0, 0.55, 0.25)
	light.light_energy = 3.2
	light.omni_range = 11.0
	light.omni_attenuation = 1.2
	light.position = Vector3(0, 0.9, 0.9)
	_fade(light, 45.0)
	holder.add_child(light)


static func _fx_green_fire(holder: Node3D, with_light: bool) -> void:
	_flame(holder, Vector3(0, 0.12, 0), Vector2(0.28, 0.32), Color(0.4, 1.0, 0.5), 3.0)
	if with_light:
		var light := OmniLight3D.new()
		light.light_color = Color(0.45, 1.0, 0.55)
		light.light_energy = 1.6
		light.omni_range = 8.0
		light.position = Vector3(0, 0.8, 0)
		_fade(light, 30.0)
		holder.add_child(light)


## A hanging lantern: iron cage, chain, flame, warm light.
static func _fx_lamp(holder: Node3D) -> void:
	var iron := _iron()
	lantern(holder, Vector3.ZERO, 1.0)
	var chain := MeshInstance3D.new()
	var cyl := CylinderMesh.new()
	cyl.top_radius = 0.02
	cyl.bottom_radius = 0.02
	cyl.height = 4.0
	cyl.material = iron
	chain.mesh = cyl
	chain.position = Vector3(0, 2.25, 0)
	holder.add_child(chain)
	var light := OmniLight3D.new()
	light.light_color = Color(1.0, 0.72, 0.4)
	light.light_energy = 2.0
	light.omni_range = 10.0
	light.position = Vector3(0, -0.3, 0)
	_fade(light)
	holder.add_child(light)


## A lantern body centred on `at`: iron cap and base, four corner posts, smoky
## amber glass panes you can see the candle through, and the candle flame. The
## old one was a solid glowing box.
static func lantern(parent: Node3D, at: Vector3, s: float = 1.0) -> void:
	var iron := _iron()
	var glass := StandardMaterial3D.new()
	glass.albedo_color = Color(0.95, 0.72, 0.4, 0.22)
	glass.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	glass.roughness = 0.15
	glass.emission_enabled = true
	glass.emission = Color(1.0, 0.62, 0.3)
	glass.emission_energy_multiplier = 0.35
	glass.cull_mode = BaseMaterial3D.CULL_DISABLED
	var pane := MeshInstance3D.new()
	var pb := BoxMesh.new()
	pb.size = Vector3(0.3, 0.4, 0.3) * s
	pb.material = glass
	pane.mesh = pb
	pane.position = at
	pane.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	parent.add_child(pane)
	for spec in [[Vector3(0.38, 0.05, 0.38), 0.225], [Vector3(0.34, 0.05, 0.34), -0.225]]:
		var plate := MeshInstance3D.new()
		var b := BoxMesh.new()
		b.size = (spec[0] as Vector3) * s
		b.material = iron
		plate.mesh = b
		plate.position = at + Vector3(0, float(spec[1]) * s, 0)
		parent.add_child(plate)
	var cap := MeshInstance3D.new()
	var cone := CylinderMesh.new()
	cone.top_radius = 0.03 * s
	cone.bottom_radius = 0.22 * s
	cone.height = 0.14 * s
	cone.radial_segments = 4
	cone.material = iron
	cap.mesh = cone
	cap.position = at + Vector3(0, 0.32 * s, 0)
	cap.rotation.y = PI * 0.25
	parent.add_child(cap)
	for c in [Vector2(1, 1), Vector2(-1, 1), Vector2(1, -1), Vector2(-1, -1)]:
		var post := MeshInstance3D.new()
		var pbox := BoxMesh.new()
		pbox.size = Vector3(0.025, 0.42, 0.025) * s
		pbox.material = iron
		post.mesh = pbox
		post.position = at + Vector3(c.x * 0.155, 0.0, c.y * 0.155) * s
		parent.add_child(post)
	var candle := MeshInstance3D.new()
	var wax := CylinderMesh.new()
	wax.top_radius = 0.035 * s
	wax.bottom_radius = 0.04 * s
	wax.height = 0.14 * s
	wax.radial_segments = 8
	var wax_mat := StandardMaterial3D.new()
	wax_mat.albedo_color = Color(0.93, 0.89, 0.78)
	wax_mat.emission_enabled = true
	wax_mat.emission = Color(1.0, 0.6, 0.3)
	wax_mat.emission_energy_multiplier = 0.25
	wax.material = wax_mat
	candle.mesh = wax
	candle.position = at + Vector3(0, -0.13 * s, 0)
	parent.add_child(candle)
	var flame := MeshInstance3D.new()
	var quad := QuadMesh.new()
	quad.size = Vector2(0.1, 0.18) * s
	var fire := ShaderMaterial.new()
	fire.shader = FLAME_SHADER
	fire.set_shader_parameter("bob_height", 0.0)
	fire.set_shader_parameter("intensity", 2.4)
	quad.material = fire
	flame.mesh = quad
	flame.position = at + Vector3(0, 0.0, 0)
	flame.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	parent.add_child(flame)



## Every owl in one MultiMesh (the fal image-to-3D owl, height-normalised so an
## FX point's scale is the bird's height in metres).
static func _owl_flock(root: Node3D, transforms: Array) -> void:
	var path := "res://assets/castle/props/owl.glb"
	if not ResourceLoader.exists(path):
		return
	var scene := (load(path) as PackedScene).instantiate() as Node3D
	var mi := scene.find_children("*", "MeshInstance3D", true, false)
	if mi.is_empty():
		scene.free()
		return
	var src := mi[0] as MeshInstance3D
	var mesh := src.mesh
	var box := mesh.get_aabb()
	var norm := Transform3D(Basis().scaled(Vector3.ONE / maxf(box.size.y, 0.001)),
		-Vector3(box.get_center().x, box.position.y, box.get_center().z) / maxf(box.size.y, 0.001))
	var mm := MultiMesh.new()
	mm.transform_format = MultiMesh.TRANSFORM_3D
	mm.mesh = mesh
	mm.instance_count = transforms.size()
	for i in transforms.size():
		mm.set_instance_transform(i, root.global_transform.affine_inverse() * (transforms[i] as Transform3D) * norm)
	var flock := MultiMeshInstance3D.new()
	flock.name = "Owls"
	flock.multimesh = mm
	root.add_child(flock)
	scene.free()
