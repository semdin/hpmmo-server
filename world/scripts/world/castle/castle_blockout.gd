extends RefCounted

## Presentation of the castle interior (docs/castle-interior.md, F1-F2).
##
## The geometry is art/castle/layout.json built by Blender: visual meshes merged
## per room and material, one convex collider per piece.
##   * assets/castle/castle_interior.glb - the Gothic build (F2): `kit_<slot>`
##     materials, resolved here to world-space PBR surfaces (no UVs needed);
##   * assets/castle/castle_blockout.glb - the grey blockout (F1): `bo_<kind>`
##     materials, shown as a 1 m / 4 m tinted grid so scale reads everywhere.
## The live map loads the Gothic build when the build carries it.
## Shared by the live map (castle_interior.gd) and the walk preview
## (tools/castle/castle_blockout_preview.gd).

const PBR = preload("res://scripts/assets/pbr_kit.gd")
const QualityPreset = preload("res://scripts/world/quality_preset.gd")

const GOTHIC := "res://assets/castle/castle_interior.glb"
const BLOCKOUT := "res://assets/castle/castle_blockout.glb"
const LAYOUT := "res://assets/castle/castle_layout.json"

const TINTS := {
	"floor": Color(0.62, 0.62, 0.63), "ceiling": Color(0.42, 0.42, 0.48), "wall": Color(0.80, 0.77, 0.71),
	"stair": Color(0.80, 0.58, 0.32), "rail": Color(0.33, 0.52, 0.82), "threshold": Color(0.66, 0.66, 0.66),
	"door_leaf": Color(0.45, 0.27, 0.14), "seal": Color(0.55, 0.22, 0.85), "furniture": Color(0.58, 0.38, 0.26),
	"dais": Color(0.68, 0.55, 0.42),
}

static var _grid: Texture2D = null


static func load_layout() -> Dictionary:
	var parsed: Variant = JSON.parse_string(FileAccess.get_file_as_string(LAYOUT))
	return parsed if parsed is Dictionary else {}


## The imported castle scene (Gothic unless `grey`), or null when this build
## carries neither.
static func instantiate(grey: bool = false) -> Node3D:
	var path := BLOCKOUT if grey or not ResourceLoader.exists(GOTHIC) else GOTHIC
	if not ResourceLoader.exists(path):
		return null
	var packed := load(path) as PackedScene
	return packed.instantiate() as Node3D if packed != null else null


## Drop every visual mesh, keeping the collision bodies (dedicated server).
static func strip_visuals(root: Node) -> void:
	for node in root.find_children("*", "MeshInstance3D", true, false):
		node.get_parent().remove_child(node)
		node.free()


## A 4 m tile with 1 m minor lines.
static func grid_texture() -> Texture2D:
	if _grid != null:
		return _grid
	var n := 256
	var img := Image.create(n, n, false, Image.FORMAT_RGB8)
	img.fill(Color(1, 1, 1))
	for i in n:
		for j in n:
			if i < 3 or j < 3:
				img.set_pixel(i, j, Color(0.55, 0.55, 0.55))
			elif i % 64 == 0 or j % 64 == 0:
				img.set_pixel(i, j, Color(0.82, 0.82, 0.82))
	img.generate_mipmaps()
	_grid = ImageTexture.create_from_image(img)
	return _grid


static func grid_material(color: Color) -> StandardMaterial3D:
	var m := StandardMaterial3D.new()
	m.albedo_color = color
	m.albedo_texture = grid_texture()
	m.uv1_triplanar = true
	m.uv1_world_triplanar = true
	m.uv1_scale = Vector3(0.25, 0.25, 0.25)
	m.roughness = 0.9
	return m


## Gothic kit slot -> world-space PBR surface. The dressing has no UVs, so every
## slot is triplanar (the kit's UV-mapped trim sheet and wood would smear).
static func kit_material(slot: String) -> Material:
	if slot.begins_with("portrait_"):
		var canvas := StandardMaterial3D.new()
		canvas.albedo_texture = load("res://assets/castle/textures/%s.jpg" % slot)
		canvas.roughness = 0.8
		return canvas
	match slot:
		# Grey-gold sandstone ashlar walls, dressed stone for every moulding,
		# limewashed vault webs, worn flagstones; the dungeons in cold grey.
		"stone":
			return PBR.surface("large_sandstone_blocks_01", Color(0.96, 0.92, 0.85))
		"stone_cold":
			return PBR.surface("medieval_blocks_03", Color(0.82, 0.86, 0.9))
		"stone_dark":
			return PBR.surface("medieval_blocks_03", Color(0.5, 0.5, 0.52))
		"stone_vault":
			return PBR.surface("plaster_grey_04", Color(1.0, 0.95, 0.86))
		"stone_vault_cold":
			return PBR.surface("plaster_grey_04", Color(0.72, 0.76, 0.8))
		"trim":
			return PBR.surface("sandstone_blocks_08", Color(1.0, 0.95, 0.88))
		"trim_cold":
			return PBR.surface("medieval_blocks_03", Color(0.95, 0.97, 1.0), {"metres": 2.0})
		"stone_floor":
			return PBR.surface("large_floor_tiles_02", Color(0.95, 0.92, 0.88))
		"wood":
			return PBR.surface("medieval_wood", Color(0.9, 0.82, 0.74))
		"wood_dark":
			return PBR.surface("medieval_wood", Color(0.55, 0.45, 0.4))
		"glass":
			# The moonlit highland vista beyond, behind diamond leaded quarries.
			var view := ShaderMaterial.new()
			view.shader = preload("res://assets/shaders/castle/window_view.gdshader")
			view.set_shader_parameter("vista", load("res://assets/castle/textures/window_vista_night.jpg"))
			view.set_shader_parameter("energy", 1.25)
			return view
		"banner_red", "banner_green", "banner_blue", "banner_yellow":
			var cloth := StandardMaterial3D.new()
			cloth.albedo_texture = load("res://assets/castle/textures/%s.png" % slot)
			cloth.cull_mode = BaseMaterial3D.CULL_DISABLED
			cloth.roughness = 0.92
			return cloth
		"stained_side", "stained_west":
			# Leaded light glowing with the dusk behind it.
			var pane := StandardMaterial3D.new()
			var tex: Texture2D = load("res://assets/castle/textures/%s.png" % slot)
			pane.albedo_texture = tex
			pane.albedo_color = Color(0.35, 0.35, 0.35)
			pane.emission_enabled = true
			pane.emission_texture = tex
			pane.emission_energy_multiplier = 1.4
			pane.roughness = 0.2
			return pane
		"glass_clear":
			var clear := StandardMaterial3D.new()
			clear.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
			clear.albedo_color = Color(0.85, 0.92, 1.0, 0.18)
			clear.roughness = 0.05
			clear.metallic_specular = 0.9
			clear.cull_mode = BaseMaterial3D.CULL_DISABLED
			return clear
		"brass":
			var brass := StandardMaterial3D.new()
			brass.albedo_color = Color(0.78, 0.6, 0.3)
			brass.metallic = 1.0
			brass.roughness = 0.32
			return brass
		"gem_red", "gem_green", "gem_blue", "gem_yellow":
			var colours := {"gem_red": Color(1.0, 0.12, 0.1), "gem_green": Color(0.1, 0.9, 0.35),
				"gem_blue": Color(0.15, 0.4, 1.0), "gem_yellow": Color(1.0, 0.8, 0.15)}
			var gem := StandardMaterial3D.new()
			gem.albedo_color = colours[slot]
			gem.emission_enabled = true
			gem.emission = colours[slot]
			gem.emission_energy_multiplier = 2.2
			gem.roughness = 0.15
			return gem
		"compass":
			var painted := StandardMaterial3D.new()
			painted.albedo_texture = load("res://assets/castle/textures/%s.%s" % [slot, "png" if slot == "compass" else "jpg"])
			if slot == "compass":
				# a round inlay: the texture's corners are cut away by its alpha
				painted.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA_SCISSOR
				painted.alpha_scissor_threshold = 0.5
			painted.roughness = 0.55 if slot == "compass" else 0.8
			painted.metallic = 0.25 if slot == "compass" else 0.0
			return painted
		"slate":
			var slate := StandardMaterial3D.new()
			slate.albedo_color = Color(0.07, 0.085, 0.075)
			slate.roughness = 0.95
			return slate
		"soot":
			var soot := StandardMaterial3D.new()
			soot.albedo_color = Color(0.04, 0.035, 0.03)
			soot.roughness = 1.0
			return soot
		"potion":
			var brew := StandardMaterial3D.new()
			brew.albedo_color = Color(0.2, 0.9, 0.35)
			brew.emission_enabled = true
			brew.emission = Color(0.25, 1.0, 0.4)
			brew.emission_energy_multiplier = 1.6
			brew.roughness = 0.1
			return brew
		"jar_green", "jar_amber", "jar_purple", "jar_blue":
			# murky old glass: dark bodies with a faint inner glow
			var tint := {"jar_green": Color(0.36, 0.52, 0.22), "jar_amber": Color(0.62, 0.38, 0.12),
				"jar_purple": Color(0.36, 0.2, 0.42), "jar_blue": Color(0.18, 0.3, 0.45)}[slot] as Color
			var jar := StandardMaterial3D.new()
			jar.albedo_color = tint
			jar.emission_enabled = true
			jar.emission = tint
			jar.emission_energy_multiplier = 0.12
			jar.roughness = 0.08
			jar.metallic_specular = 0.9
			return jar
		"books":
			var books := StandardMaterial3D.new()
			books.albedo_texture = load("res://assets/castle/textures/books.jpg")
			books.cull_mode = BaseMaterial3D.CULL_DISABLED
			books.roughness = 0.85
			return books
		"cloth_red", "cloth_blue", "cloth_green", "cloth_yellow", 				"cloth_red_dark", "cloth_blue_dark", "cloth_green_dark", "cloth_yellow_dark":
			var base := {"cloth_red": Color(0.55, 0.08, 0.07), "cloth_blue": Color(0.1, 0.18, 0.5),
				"cloth_green": Color(0.06, 0.3, 0.16), "cloth_yellow": Color(0.78, 0.58, 0.12)}
			var dark := slot.ends_with("_dark")
			var cloth := StandardMaterial3D.new()
			cloth.albedo_color = (base[slot.trim_suffix("_dark")] as Color) * (0.55 if dark else 1.0)
			cloth.roughness = 0.95
			return cloth
		"straw":
			var straw := StandardMaterial3D.new()
			straw.albedo_color = Color(0.72, 0.6, 0.32)
			straw.roughness = 1.0
			return straw
		"terracotta":
			var pot := StandardMaterial3D.new()
			pot.albedo_color = Color(0.62, 0.32, 0.18)
			pot.roughness = 0.9
			return pot
		"leaf":
			var leaf := StandardMaterial3D.new()
			leaf.albedo_color = Color(0.16, 0.38, 0.12)
			leaf.roughness = 0.8
			leaf.cull_mode = BaseMaterial3D.CULL_DISABLED
			return leaf
		"tapestry":
			var weave := StandardMaterial3D.new()
			weave.albedo_texture = load("res://assets/castle/textures/tapestry.jpg")
			weave.roughness = 0.95
			return weave
		"lake_window":
			var lake := ShaderMaterial.new()
			lake.shader = preload("res://assets/shaders/castle/lake_window.gdshader")
			return lake
		"gilt":
			var gilt := StandardMaterial3D.new()
			gilt.albedo_color = Color(0.83, 0.64, 0.3)
			gilt.metallic = 1.0
			gilt.roughness = 0.38
			return gilt
		"iron":
			var iron := StandardMaterial3D.new()
			iron.albedo_color = Color(0.12, 0.11, 0.11)
			iron.metallic = 0.85
			iron.roughness = 0.5
			return iron
		"sky_vault":
			var sky := ShaderMaterial.new()
			sky.shader = preload("res://assets/shaders/castle/enchanted_sky.gdshader")
			return sky
		"seal":
			var m := grid_material(TINTS["seal"])
			m.emission_enabled = true
			m.emission = Color(0.55, 0.2, 0.95)
			m.emission_energy_multiplier = 1.5
			return m
	return PBR.slot_material(slot)


## kit_material for this run's quality: on low, the PBR surfaces take the
## shader's lite path (no roughness / AO reads), on a copy so the shared
## material cache - the grounds use it too - is untouched.
static func kit_material_for_quality(slot: String) -> Material:
	var m := kit_material(slot)
	if m is ShaderMaterial and QualityPreset.current() == "low" 			and (m as ShaderMaterial).shader == PBR.SHADER:
		m = m.duplicate()
		(m as ShaderMaterial).set_shader_parameter("lite", true)
	return m


static func restyle(root: Node) -> void:
	var cache := {}
	for node in root.find_children("*", "MeshInstance3D", true, false):
		var mi := node as MeshInstance3D
		for s in mi.mesh.get_surface_count():
			var src := mi.mesh.surface_get_material(s)
			var src_name := src.resource_name if src != null else "bo_wall"
			if src_name.begins_with("kit_"):
				var slot := src_name.trim_prefix("kit_")
				if slot in ["glass", "sky_vault", "glass_clear", "stained_side", "stained_west"] or slot.begins_with("banner_") or slot.begins_with("portrait_") or slot in ["compass", "tapestry", "lake_window", "leaf"]:
					# Glazing and the enchanted ceiling must not block the
					# moonlight (or the beams it draws in the fog).
					mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
				if not cache.has(src_name):
					cache[src_name] = kit_material_for_quality(slot)
				mi.set_surface_override_material(s, cache[src_name])
				continue
			var kind := src_name.trim_prefix("bo_")
			if not cache.has(kind):
				var m := grid_material(TINTS.get(kind, Color(0.7, 0.7, 0.7)))
				if kind == "seal":
					m.emission_enabled = true
					m.emission = Color(0.55, 0.2, 0.95)
					m.emission_energy_multiplier = 1.5
				cache[kind] = m
			mi.set_surface_override_material(s, cache[kind])


## Occlusion culling for the castle: one box occluder per large wall, floor and
## ceiling piece (from the glb's collision bodies - W_*, F_*, C_* pieces), so
## a room hides what is behind its walls and the storeys above and below it.
## Window and door gaps stay open: walls are already split around them.
## Needs rendering/occlusion_culling/use_occlusion_culling (project setting).
static func add_occluders(structure: Node3D) -> int:
	var count := 0
	for node in structure.find_children("*", "StaticBody3D", true, false):
		var body := node as StaticBody3D
		var tag := String(body.name).left(2)
		if not (tag == "W_" or tag == "F_" or tag == "C_"):
			continue
		for child in body.get_children():
			var cs := child as CollisionShape3D
			if cs == null or not (cs.shape is ConvexPolygonShape3D):
				continue
			var pts: PackedVector3Array = (cs.shape as ConvexPolygonShape3D).points
			if pts.is_empty():
				continue
			var box := AABB(pts[0], Vector3.ZERO)
			for p in pts:
				box = box.expand(p)
			var dims := [box.size.x, box.size.y, box.size.z]
			dims.sort()
			if dims[0] < 0.35 or dims[1] < 3.0 or dims[2] < 3.0:
				continue
			var occ := OccluderInstance3D.new()
			var shape := BoxOccluder3D.new()
			shape.size = (box.size - Vector3(0.1, 0.1, 0.1)).max(Vector3(0.05, 0.05, 0.05))
			occ.occluder = shape
			occ.transform = cs.global_transform * Transform3D(Basis(), box.get_center())
			structure.add_child(occ)
			occ.global_transform = cs.global_transform * Transform3D(Basis(), box.get_center())
			count += 1
	return count


## One warm light per 24 m bay of every room (hung at 70 % of the room height,
## never above 12 m), plus one per Grand Staircase gallery.
static func add_room_lights(parent: Node3D, layout: Dictionary, map_y: float, energy: float = 1.6) -> void:
	for r in layout.get("rooms", []):
		var rect: Array = r["rect"]
		var y := float(r["y"])
		var h := float(r["h"])
		var w := float(rect[1]) - float(rect[0])
		var d := float(rect[3]) - float(rect[2])
		var nx := maxi(1, int(ceil(w / 24.0)))
		var nz := maxi(1, int(ceil(d / 24.0)))
		for i in nx:
			for j in nz:
				var light := OmniLight3D.new()
				light.light_color = Color(1.0, 0.86, 0.66)
				light.omni_range = maxf(w / nx, d / nz) * 0.95 + minf(h, 12.0) * 0.6
				light.light_energy = energy
				light.omni_attenuation = 0.6
				light.position = Vector3(float(rect[0]) + (i + 0.5) * w / nx, map_y + y + minf(h * 0.7, 12.0),
					float(rect[2]) + (j + 0.5) * d / nz)
				parent.add_child(light)
	var ms: Dictionary = layout.get("moving_stairs", {})
	var axis: Array = ms.get("axis", [0.0, 0.0])
	var levels: Dictionary = layout.get("levels", {})
	for k in levels:
		if float(levels[k]) > 0.0:
			var light := OmniLight3D.new()
			light.light_color = Color(1.0, 0.9, 0.75)
			light.omni_range = 30.0
			light.light_energy = 1.2
			light.position = Vector3(float(axis[0]), map_y + float(levels[k]) + 6.0, float(axis[1]))
			parent.add_child(light)
