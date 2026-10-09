extends RefCounted

## Procedural PBR asset kit — generates real tiled textures at runtime
## (grass, cobble, stone, bark, roof, water, robe fabric) so the world
## no longer looks like flat colored primitives. Textures are cached.

static var _cache: Dictionary = {}

static func clear_cache() -> void:
	_cache.clear()

static func _noise_tex(base: Color, variation: Color, size: int = 128, scale_cells: int = 8, seed_val: int = 1) -> ImageTexture:
	var key := "%s_%s_%d_%d_%d" % [base.to_html(), variation.to_html(), size, scale_cells, seed_val]
	if _cache.has(key):
		return _cache[key]
	var rng := RandomNumberGenerator.new()
	rng.seed = seed_val
	var img := Image.create(size, size, false, Image.FORMAT_RGBA8)
	var noise := FastNoiseLite.new()
	noise.seed = seed_val
	noise.frequency = 0.025
	noise.fractal_octaves = 4
	for y in range(size):
		for x in range(size):
			var t := clampf(noise.get_noise_2d(x, y) * 0.8 + 0.5 + rng.randf_range(-0.035, 0.035), 0, 1)
			img.set_pixel(x, y, base.lerp(variation, t))
	img.generate_mipmaps()
	var tex := ImageTexture.create_from_image(img)
	_cache[key] = tex
	return tex

static func _mat(albedo_tex: Texture2D, tint: Color, rough: float, metallic: float = 0.0, emission: Color = Color(0,0,0), e_energy: float = 0.0) -> StandardMaterial3D:
	var m := StandardMaterial3D.new()
	m.albedo_texture = albedo_tex
	m.albedo_color = tint
	m.roughness = rough
	m.metallic = metallic
	m.texture_filter = BaseMaterial3D.TEXTURE_FILTER_LINEAR_WITH_MIPMAPS_ANISOTROPIC
	m.uv1_scale = Vector3(6, 6, 6)
	if e_energy > 0.0:
		m.emission_enabled = true
		m.emission = emission
		m.emission_energy_multiplier = e_energy
	return m

static func grass_material() -> StandardMaterial3D:
	var t := _noise_tex(Color(0.23, 0.42, 0.20), Color(0.13, 0.28, 0.12), 128, 10, 11)
	var m := _mat(t, Color(1,1,1), 0.95)
	m.uv1_scale = Vector3(24, 24, 24)
	return m

static func meadow_material() -> StandardMaterial3D:
	var t := _noise_tex(Color(0.32, 0.47, 0.22), Color(0.20, 0.33, 0.15), 128, 7, 12)
	var m := _mat(t, Color(1,1,1), 0.95)
	m.uv1_scale = Vector3(18, 18, 18)
	return m

static func cobble_material() -> StandardMaterial3D:
	var t := _noise_tex(Color(0.52, 0.51, 0.53), Color(0.30, 0.29, 0.31), 128, 8, 21)
	var m := _mat(t, Color(1,1,1), 0.75)
	m.uv1_scale = Vector3(10, 10, 10)
	return m

static func castle_wall_material() -> StandardMaterial3D:
	var t := _noise_tex(Color(0.62, 0.58, 0.52), Color(0.38, 0.35, 0.32), 128, 9, 31)
	var m := _mat(t, Color(1,1,1), 0.8)
	m.uv1_scale = Vector3(6, 6, 6)
	return m

static func castle_roof_material() -> StandardMaterial3D:
	var t := _noise_tex(Color(0.25, 0.32, 0.45), Color(0.12, 0.16, 0.26), 128, 8, 41)
	var m := _mat(t, Color(1,1,1), 0.55, 0.15)
	return m

static func wood_material() -> StandardMaterial3D:
	var t := _noise_tex(Color(0.45, 0.30, 0.16), Color(0.24, 0.15, 0.08), 128, 6, 51)
	var m := _mat(t, Color(1,1,1), 0.6)
	return m

static func bark_material() -> StandardMaterial3D:
	var t := _noise_tex(Color(0.33, 0.22, 0.13), Color(0.15, 0.10, 0.06), 128, 9, 52)
	var m := _mat(t, Color(1,1,1), 0.9)
	return m

static func leaf_material() -> StandardMaterial3D:
	var t := _noise_tex(Color(0.16, 0.38, 0.14), Color(0.07, 0.20, 0.08), 128, 10, 61)
	var m := _mat(t, Color(1,1,1), 0.9)
	return m

static func water_material() -> Material:
	var shader := load("res://assets/shaders/water_pbr.gdshader") as Shader
	if shader != null:
		var mat := ShaderMaterial.new()
		mat.shader = shader
		return mat
	# Fallback when the shader is missing: bright lake blue with emission so it
	# never reads as a dark hole.
	var m := StandardMaterial3D.new()
	m.albedo_color = Color(0.23, 0.50, 0.62, 0.82)
	m.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	m.roughness = 0.12
	m.metallic = 0.05
	m.emission_enabled = true
	m.emission = Color(0.12, 0.30, 0.42)
	m.emission_energy_multiplier = 0.5
	return m

static func robe_material(house_color: Color) -> StandardMaterial3D:
	var t := _noise_tex(house_color.darkened(0.55), house_color.darkened(0.25), 64, 5, 71)
	return _mat(t, Color(1,1,1), 0.85)

static func skin_material() -> StandardMaterial3D:
	var t := _noise_tex(Color(0.92, 0.76, 0.62), Color(0.82, 0.63, 0.48), 64, 4, 81)
	return _mat(t, Color(1,1,1), 0.6)

static func gold_material() -> StandardMaterial3D:
	var m := StandardMaterial3D.new()
	m.albedo_color = Color(0.95, 0.75, 0.25)
	m.metallic = 0.9
	m.roughness = 0.25
	m.emission_enabled = true
	m.emission = Color(0.8, 0.6, 0.15)
	m.emission_energy_multiplier = 0.6
	return m

static func obsidian_material() -> StandardMaterial3D:
	var t := _noise_tex(Color(0.16, 0.07, 0.22), Color(0.05, 0.02, 0.08), 128, 7, 91)
	var m := _mat(t, Color(1,1,1), 0.25, 0.8, Color(0.55, 0.1, 0.9), 1.4)
	m.rim_enabled = true
	m.rim = 0.7
	return m
