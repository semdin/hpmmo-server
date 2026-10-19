extends RefCounted

## Underground atmosphere (maps.json `atmosphere: "cavern"`), the cave twin of
## castle/castle_atmosphere.gd: the map controller hands the world's one
## Environment here on the way in and restores the saved values on the way out.
## No sky (the open roof must read as darkness), a cold green-violet ambient,
## depth fog that swallows the far walls, glow for the egg sacs and fungi.
## Low preset: plain distance fog only (no volumetrics, SSAO or SSIL).

const QualityPreset = preload("res://scripts/world/quality_preset.gd")

const KEYS := [
	"background_mode", "background_color", "background_energy_multiplier",
	"ambient_light_source", "ambient_light_color", "ambient_light_energy", "ambient_light_sky_contribution",
	"reflected_light_source",
	"fog_enabled", "fog_mode", "fog_light_color", "fog_light_energy", "fog_density", "fog_sky_affect",
	"fog_height", "fog_height_density", "fog_aerial_perspective",
	"volumetric_fog_enabled", "volumetric_fog_density", "volumetric_fog_albedo",
	"volumetric_fog_emission", "volumetric_fog_emission_energy", "volumetric_fog_anisotropy", "volumetric_fog_length",
	"volumetric_fog_gi_inject", "volumetric_fog_ambient_inject",
	"ssao_enabled", "ssao_radius", "ssao_intensity", "ssil_enabled", "ssil_radius", "ssil_intensity",
	"sdfgi_enabled", "glow_enabled", "glow_intensity", "glow_bloom", "glow_hdr_threshold",
	"tonemap_mode", "tonemap_exposure",
]

const FOG := Color(0.07, 0.1, 0.1)


static func apply(env: Environment, quality: String = "") -> Dictionary:
	if quality == "":
		quality = QualityPreset.current()
	var saved := {}
	for key in KEYS:
		saved[key] = env.get(key)
	var low := quality == "low"
	env.background_mode = Environment.BG_COLOR
	env.background_color = Color(0.008, 0.01, 0.012)
	env.background_energy_multiplier = 1.0
	env.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
	env.ambient_light_color = Color(0.46, 0.54, 0.56)
	env.ambient_light_energy = 1.5 if low else 1.25
	env.ambient_light_sky_contribution = 0.0
	env.reflected_light_source = Environment.REFLECTION_SOURCE_DISABLED
	env.fog_enabled = true
	env.fog_mode = Environment.FOG_MODE_EXPONENTIAL
	env.fog_light_color = FOG
	env.fog_light_energy = 1.0
	env.fog_density = 0.009
	env.fog_sky_affect = 1.0
	env.fog_height = -1000.0
	env.fog_height_density = 0.0
	env.fog_aerial_perspective = 0.0
	env.tonemap_mode = Environment.TONE_MAPPER_ACES
	env.tonemap_exposure = 1.15
	env.glow_enabled = true
	env.glow_intensity = 0.7
	env.glow_bloom = 0.06
	env.glow_hdr_threshold = 0.9
	env.ssao_enabled = not low
	env.ssao_radius = 2.0
	env.ssao_intensity = 2.0
	env.ssil_enabled = false
	env.sdfgi_enabled = false
	env.volumetric_fog_enabled = not low
	env.volumetric_fog_density = 0.02
	env.volumetric_fog_albedo = Color(0.55, 0.65, 0.6)
	env.volumetric_fog_emission = Color(0.0, 0.0, 0.0)
	env.volumetric_fog_emission_energy = 0.0
	env.volumetric_fog_anisotropy = 0.3
	env.volumetric_fog_length = 70.0
	env.volumetric_fog_gi_inject = 0.0
	env.volumetric_fog_ambient_inject = 0.35
	return saved


static func restore(env: Environment, saved: Dictionary) -> void:
	for key in saved:
		env.set(key, saved[key])
