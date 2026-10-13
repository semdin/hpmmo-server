extends RefCounted

## Indoor atmosphere of the castle (docs/castle-interior.md, F3).
##
## The world keeps one Environment; the map controller hands it here on the way
## in and gets the outdoor values back on the way out. Inside: a dim warm
## ambient (candles and moonlight do the lighting), screen-space AO and
## indirect light, volumetric fog for the moonbeams through the windows, glow
## for the flames, and SDFGI on high. Every feature follows the quality preset:
## low keeps the plain dim ambient only.

const QualityPreset = preload("res://scripts/world/quality_preset.gd")

## Environment properties this module changes, saved before and restored after.
const KEYS := [
	"ambient_light_source", "ambient_light_color", "ambient_light_energy",
	"fog_enabled", "volumetric_fog_enabled", "volumetric_fog_density", "volumetric_fog_albedo",
	"volumetric_fog_emission", "volumetric_fog_anisotropy", "volumetric_fog_length",
	"volumetric_fog_gi_inject", "volumetric_fog_ambient_inject",
	"ssao_enabled", "ssao_radius", "ssao_intensity", "ssil_enabled", "ssil_radius", "ssil_intensity",
	"sdfgi_enabled", "sdfgi_use_occlusion", "sdfgi_cascades", "sdfgi_min_cell_size", "sdfgi_energy",
	"glow_enabled", "glow_intensity", "glow_bloom", "glow_hdr_threshold",
	"tonemap_mode", "tonemap_exposure",
]


static func apply(env: Environment, quality: String = "") -> Dictionary:
	if quality == "":
		quality = QualityPreset.current()
	var saved := {}
	for key in KEYS:
		saved[key] = env.get(key)
	var low := quality == "low"
	var high := quality == "high"
	env.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
	env.ambient_light_color = Color(0.34, 0.32, 0.36)
	env.ambient_light_energy = 0.6 if low else 0.42
	env.fog_enabled = false
	env.tonemap_mode = Environment.TONE_MAPPER_ACES
	env.tonemap_exposure = 1.05
	env.glow_enabled = true
	env.glow_intensity = 0.55
	env.glow_bloom = 0.04
	env.glow_hdr_threshold = 1.1
	env.ssao_enabled = not low
	env.ssao_radius = 1.6
	env.ssao_intensity = 1.6
	env.ssil_enabled = not low
	env.ssil_radius = 6.0
	env.ssil_intensity = 0.9
	env.volumetric_fog_enabled = not low
	env.volumetric_fog_density = 0.012
	env.volumetric_fog_albedo = Color(0.85, 0.82, 0.78)
	env.volumetric_fog_emission = Color(0.0, 0.0, 0.0)
	env.volumetric_fog_anisotropy = 0.55
	env.volumetric_fog_length = 80.0
	env.volumetric_fog_gi_inject = 0.6
	env.volumetric_fog_ambient_inject = 0.25
	env.sdfgi_enabled = high
	env.sdfgi_use_occlusion = true
	env.sdfgi_cascades = 4
	env.sdfgi_min_cell_size = 0.4
	env.sdfgi_energy = 0.9
	return saved


static func restore(env: Environment, saved: Dictionary) -> void:
	for key in saved:
		env.set(key, saved[key])
