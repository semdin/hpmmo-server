extends RefCounted

## vfx library: the asset registry and the spell-by-spell composition
## table (12.3), plus the quality variants (12.4).
##
## Every effect scene builds its layers from this table - there is no second
## copy of the composition, so `run_vfx_checks.ps1` can assert the table
## against the inventory: each spell has cast/travel/impact/sustain/end where it
## needs them, each layer names an asset that exists, each layer picks its blend
## mode, and the low variant is a genuine reduction (fewer layers, no dynamic
## lights, coarser flipbook stepping) while keeping the layer that carries the
## gameplay information.
##
## Layer kinds
##   flipbook : one atlas cell on a quad (billboard or flat), animated by frame
##   sprite   : a single texture (glow, streak, ground mark, rune mask)
##   particles: textured quads emitted over time (embers, sparks, debris)
##   mesh     : authored geometry (shield shell, projectile core, shards)
##   ribbon   : tapered strip driven by a motion history (trail_ribbon.glb)
##   light    : a dynamic light with a curve
##   audio    : an event sound (11.5 names come from assets/audio/sound_library.json)
##
## Layer keys
##   core     : carries the gameplay information; NEVER dropped by a variant
##   optional : dropped at low
##   quality  : per-variant overrides {amount, lights, frame_step}

const QUALITY_LEVELS := ["low", "medium", "high"]

## Asset paths published by tools/blender/spell_vfx.py + spell_meshes.py.
const ATLAS_DIR := "res://assets/vfx/atlases/"
const TEX_DIR := "res://assets/vfx/tex/"
const MESH_DIR := "res://assets/vfx/meshes/"

const ASSETS := {
	"vfx_flame_loop": {"path": ATLAS_DIR + "flame_loop_8x8_2k.png", "grid": Vector2(8, 8), "frames": 64, "fps": 30, "loop": true, "colour": true},
	"vfx_fire_burst": {"path": ATLAS_DIR + "fire_burst_8x8_2k.png", "grid": Vector2(8, 8), "frames": 64, "fps": 40, "loop": false, "colour": true},
	"vfx_smoke_puff": {"path": ATLAS_DIR + "smoke_puff_8x8_2k.png", "grid": Vector2(8, 8), "frames": 64, "fps": 24, "loop": false, "colour": true},
	"vfx_energy_impact": {"path": ATLAS_DIR + "energy_impact_8x8_2k.png", "grid": Vector2(8, 8), "frames": 64, "fps": 40, "loop": false, "colour": true},
	"vfx_shield_ripple": {"path": ATLAS_DIR + "shield_ripple_4x4_1k.png", "grid": Vector2(4, 4), "frames": 16, "fps": 24, "loop": false, "colour": true},
	"vfx_ground_marks": {"path": ATLAS_DIR + "ground_marks_2x2_1k.png", "grid": Vector2(2, 2), "frames": 4, "loop": false, "colour": true},
	"vfx_rune_masks": {"path": ATLAS_DIR + "rune_masks_2x2_1k.png", "grid": Vector2(2, 2), "frames": 4, "loop": false, "colour": false},
	"vfx_lightning_branches": {"path": ATLAS_DIR + "lightning_branches_2x2_1k.png", "grid": Vector2(2, 2), "frames": 4, "loop": false, "colour": false},
	"vfx_soft_glow": {"path": TEX_DIR + "soft_glow_512.png", "grid": Vector2(1, 1), "frames": 1, "loop": false, "colour": true},
	"vfx_noise_flow": {"path": TEX_DIR + "noise_flow_512.png", "grid": Vector2(1, 1), "frames": 1, "loop": false, "colour": false},
	"vfx_noise_erosion": {"path": TEX_DIR + "noise_erosion_512.png", "grid": Vector2(1, 1), "frames": 1, "loop": false, "colour": false},
	"vfx_distortion": {"path": TEX_DIR + "distortion_512.png", "grid": Vector2(1, 1), "frames": 1, "loop": false, "colour": false},
	"vfx_energy_streak": {"path": TEX_DIR + "energy_streak_1024x256.png", "grid": Vector2(1, 1), "frames": 1, "loop": false, "colour": true},
	"vfx_shield_fracture": {"path": TEX_DIR + "shield_fracture_512.png", "grid": Vector2(1, 1), "frames": 1, "loop": false, "colour": false},
	# Kenney Particle PackStill ingredients (CC0): detail sprites only, never the effect.
	"vfx_flame_static": {"path": "res://assets/vfx/flame_01.png", "grid": Vector2(1, 1), "frames": 1, "loop": false, "colour": true},
	"vfx_spark_static": {"path": "res://assets/vfx/spark_01.png", "grid": Vector2(1, 1), "frames": 1, "loop": false, "colour": true},
	"vfx_trail_mesh": {"mesh": MESH_DIR + "trail_ribbon.glb", "tris": 48},
	"vfx_shield_mesh": {"mesh": MESH_DIR + "shield_shell.glb", "tris": 952},
	"vfx_projectile_mesh": {"mesh": MESH_DIR + "projectile_core.glb", "tris": 64},
	"vfx_shard_meshes": {"mesh": MESH_DIR + "shards.glb", "tris": 8, "variants": 4},
}

## Layer presets shared by several spells, so a change lands once.
const LAYER_PRESETS := {
	"glow_flash": {"kind": "sprite", "tex": "vfx_soft_glow", "blend": "add", "core": true,
		"size": 0.9, "life": 0.22, "fade": "out", "light": {"energy": 2.6, "range": 6.0, "life": 0.25}},
	"impact_ring": {"kind": "flipbook", "atlas": "vfx_energy_impact", "blend": "add", "core": true,
		"size": 1.5, "life": 0.55, "speed": 1.0},
	"smoke_puff": {"kind": "flipbook", "atlas": "vfx_smoke_puff", "blend": "alpha", "core": false,
		"size": 1.4, "life": 0.9, "rise": 0.5, "optional": false},
	"ember_sparks": {"kind": "particles", "tex": "vfx_spark_static", "blend": "add", "core": false,
		"amount": 16, "life": 0.55, "speed": 4.0, "spread": 55.0, "gravity": -6.0, "size": 0.09},
	"ground_scorch": {"kind": "sprite", "atlas": "vfx_ground_marks", "frame": 0, "blend": "alpha",
		"flat": true, "lift": 0.05, "size": 3.0, "life": 4.0, "fade": "slow", "optional": true},
	"rune_ring": {"kind": "sprite", "atlas": "vfx_rune_masks", "frame": 0, "blend": "add", "flat": true,
		"lift": 0.06, "size": 1.0, "life": 1.0, "fade": "out", "core": true},
}

## The composition table (12.3). `colour` is the spell tint from
## data/json/spells.json; the tint is applied to the atlas layers so one atlas
## serves every spell while each keeps its own identity.
const SPELLS := {
	"basic_cast": {
		"colour": Color(1.0, 0.67, 0.22),
		"stages": {
			"cast": {"layers": [
				{"kind": "sprite", "energy_shape": 3, "blend": "add", "core": true, "colour": true, "size": 0.75, "life": 0.16}
			], "length": 0.3, "audio": "spell_basic_cast_cast", "core": "cast_snap"},
			"travel": {"layers": [
				{"kind": "sprite", "energy_shape": 1, "blend": "add", "core": true, "colour": true, "size": 0.36, "life": 0.0, "stretch": 4.0, "forward": -0.36},
				{"kind": "sprite", "energy_shape": 0, "blend": "add", "core": true, "colour": true, "size": 0.48, "life": 0.0, "opacity": 0.45},
				{"kind": "ribbon", "tex": "vfx_energy_streak", "blend": "add", "core": true, "colour": true, "width": 0.065, "length": 2.6, "life": 0.0, "follow": true},
				{"kind": "particles", "tex": "vfx_spark_static", "blend": "add", "colour": true, "amount": 12, "life": 0.18, "speed": 0.6, "size": 0.045, "spread": 150.0, "gravity": 0.0, "optional": true, "continuous": true}
			], "length": 0.0, "audio": "spell_basic_cast_travel", "loop_audio": true},
			"impact": {"layers": [
				{"kind": "sprite", "energy_shape": 3, "blend": "add", "core": true, "colour": true, "size": 1.05, "life": 0.16},
				{"kind": "sprite", "energy_shape": 2, "blend": "add", "core": true, "colour": true, "size": 1.3, "life": 0.26},
				{"kind": "particles", "tex": "vfx_spark_static", "blend": "add", "colour": true, "amount": 14, "life": 0.32, "speed": 3.2, "size": 0.05, "spread": 150.0, "gravity": -1.5}
			], "length": 0.4, "audio": "spell_basic_cast_impact", "core": "impact_fleck"},
			"end": {"layers": [
				{"kind": "sprite", "energy_shape": 0, "blend": "add", "core": true, "colour": true, "size": 0.45, "life": 0.2, "opacity": 0.4}
			], "length": 0.25, "audio": "spell_basic_cast_end"}
		},
	},
	"stupefy": {
		"colour": Color(1.0, 0.025, 0.075),
		"stages": {
			"cast": {"layers": [
				{"kind": "stupefy_energy", "core": true, "life": 0.32},
				{"kind": "particles", "tex": "vfx_spark_static", "blend": "add", "colour": true,
					"amount": 14, "life": 0.24, "speed": 2.4, "size": 0.045, "spread": 65.0, "gravity": 0.0, "forward": true, "optional": true},
				{"kind": "light", "colour": true, "energy": 2.6, "range": 3.0, "life": 0.22},
			], "length": 0.34, "audio": "spell_stupefy_cast", "core": "spiral_discharge"},
			"travel": {"layers": [
				{"kind": "stupefy_energy", "core": true, "life": 0.0},
				{"kind": "ribbon", "tex": "vfx_energy_streak", "blend": "add", "core": true, "colour": true,
					"width": 0.11, "length": 4.8, "life": 0.0, "follow": true},
				{"kind": "particles", "tex": "vfx_spark_static", "blend": "add", "colour": true,
					"amount": 32, "life": 0.22, "speed": 1.1, "size": 0.045, "spread": 150.0, "gravity": 0.0, "optional": true, "continuous": true},
			], "length": 0.0, "audio": "spell_stupefy_travel", "loop_audio": true},
			"impact": {"layers": [
				{"kind": "stupefy_energy", "core": true, "life": 0.72},
				{"kind": "particles", "tex": "vfx_spark_static", "blend": "add", "colour": true,
					"amount": 40, "life": 0.58, "speed": 4.8, "size": 0.055, "spread": 170.0, "gravity": -2.0, "optional": true},
				{"kind": "light", "colour": true, "energy": 3.2, "range": 4.0, "life": 0.28},
			], "length": 0.76, "audio": "spell_stupefy_impact", "core": "torn_energy_burst"},
			"sustain": {"layers": [
				{"kind": "sprite", "atlas": "vfx_rune_masks", "frame": 1, "blend": "add", "core": true, "colour": true,
					"size": 0.85, "life": 1.8, "fade": "hold"},
			], "length": 1.8, "audio": "spell_stupefy_end", "core": "stun_indicator"},
		},
	},
	"incendio": {
		"colour": Color(1.0, 0.27, 0.025),
		"stages": {
			"cast": {"layers": [
				{"kind": "signature", "core": true, "life": 0.7, "blend": "add"},
				{"kind": "flipbook", "atlas": "vfx_fire_burst", "blend": "alpha", "colour": true, "life": 0.4, "size": 0.9, "loop": false, "opacity": 0.3},
				{"kind": "particles", "tex": "vfx_spark_static", "blend": "add", "colour": true, "amount": 28, "life": 0.4, "speed": 5, "size": 0.06, "spread": 145.0, "gravity": -2.0, "optional": true},
				{"kind": "light", "colour": true, "energy": 3, "range": 5.0, "life": 0.45}
			], "length": 0.7, "audio": "spell_incendio_cast", "core": "incendio_cast"},
			"impact": {"layers": [
				{"kind": "signature", "core": true, "life": 0.6, "blend": "add"},
				{"kind": "particles", "tex": "vfx_spark_static", "blend": "add", "colour": true, "amount": 24, "life": 0.45, "speed": 3.5, "size": 0.06, "spread": 145.0, "gravity": -2.0, "optional": true},
				{"kind": "light", "colour": true, "energy": 2.5, "range": 5.0, "life": 0.3}
			], "length": 0.6, "audio": "spell_incendio_impact", "core": "incendio_impact"},
			"sustain": {"layers": [
				{"kind": "signature", "core": true, "life": 3.0, "blend": "add"},
				{"kind": "flipbook", "atlas": "vfx_flame_loop", "blend": "alpha", "colour": true, "life": 3.0, "size": 1.0, "loop": true, "opacity": 0.3},
				{"kind": "particles", "tex": "vfx_spark_static", "blend": "add", "colour": true, "amount": 12, "life": 0.6, "speed": 1.2, "size": 0.06, "spread": 145.0, "gravity": -2.0, "optional": true}
			], "length": 3.0, "audio": "spell_incendio_sustain", "core": "incendio_sustain", "loop_audio": true},
			"end": {"layers": [
				{"kind": "signature", "core": true, "life": 0.65, "blend": "add"},
				{"kind": "flipbook", "atlas": "vfx_smoke_puff", "blend": "alpha", "size": 2.6, "life": 0.65, "optional": true, "opacity": 0.3}
			], "length": 0.65, "audio": "spell_incendio_end", "core": "incendio_end"}
		},
	},
	"bombarda": {
		"colour": Color(1.0, 0.48, 0.035),
		"stages": {
			"cast": {"layers": [
				{"kind": "signature", "core": true, "life": 0.4, "blend": "add"},
				{"kind": "particles", "tex": "vfx_spark_static", "blend": "add", "colour": true, "amount": 10, "life": 0.3, "speed": 1.5, "size": 0.06, "spread": 145.0, "gravity": -2.0, "optional": true},
				{"kind": "light", "colour": true, "energy": 2.5, "range": 5.0, "life": 0.3}
			], "length": 0.4, "audio": "spell_bombarda_cast", "core": "bombarda_cast"},
			"travel": {"layers": [
				{"kind": "signature", "core": true, "life": 0.0, "blend": "add"},
				{"kind": "particles", "tex": "vfx_spark_static", "blend": "add", "colour": true, "amount": 18, "life": 0.25, "speed": 1.0, "size": 0.06, "spread": 145.0, "gravity": -2.0, "optional": true, "continuous": true}
			], "length": 0.0, "audio": "spell_bombarda_travel", "core": "bombarda_travel", "loop_audio": true},
			"impact": {"layers": [
				{"kind": "signature", "core": true, "life": 1.05, "blend": "add"},
				{"kind": "particles", "tex": "vfx_spark_static", "blend": "add", "colour": true, "amount": 38, "life": 0.7, "speed": 6.0, "size": 0.06, "spread": 145.0, "gravity": -2.0, "optional": true},
				{"kind": "flipbook", "atlas": "vfx_smoke_puff", "blend": "alpha", "size": 2.6, "life": 1.05, "optional": true, "opacity": 0.3},
				{"kind": "light", "colour": true, "energy": 4, "range": 5.0, "life": 0.45}
			], "length": 1.05, "audio": "spell_bombarda_impact", "core": "bombarda_impact", "aoe_radius": 9.0},
			"end": {"layers": [
				{"kind": "signature", "core": true, "life": 1.1, "blend": "add"},
				{"kind": "flipbook", "atlas": "vfx_smoke_puff", "blend": "alpha", "size": 2.6, "life": 1.1, "optional": true, "opacity": 0.3}
			], "length": 1.1, "audio": "spell_bombarda_end", "core": "bombarda_end"}
		},
	},
	"expelliarmus": {
		"colour": Color(1.0, 0.12, 0.38),
		"stages": {
			"cast": {"layers": [
				{"kind": "signature", "core": true, "life": 0.32, "blend": "add"},
				{"kind": "particles", "tex": "vfx_spark_static", "blend": "add", "colour": true, "amount": 10, "life": 0.25, "speed": 2.0, "size": 0.06, "spread": 145.0, "gravity": -2.0, "optional": true}
			], "length": 0.32, "audio": "spell_expelliarmus_cast", "core": "expelliarmus_cast"},
			"travel": {"layers": [
				{"kind": "signature", "core": true, "life": 0.0, "blend": "add"},
				{"kind": "particles", "tex": "vfx_spark_static", "blend": "add", "colour": true, "amount": 14, "life": 0.18, "speed": 0.5, "size": 0.06, "spread": 145.0, "gravity": -2.0, "optional": true, "continuous": true}
			], "length": 0.0, "audio": "spell_expelliarmus_travel", "core": "expelliarmus_travel", "loop_audio": true},
			"impact": {"layers": [
				{"kind": "signature", "core": true, "life": 0.55, "blend": "add"},
				{"kind": "particles", "tex": "vfx_spark_static", "blend": "add", "colour": true, "amount": 22, "life": 0.35, "speed": 3.0, "size": 0.06, "spread": 145.0, "gravity": -2.0, "optional": true},
				{"kind": "light", "colour": true, "energy": 2.5, "range": 5.0, "life": 0.2}
			], "length": 0.55, "audio": "spell_expelliarmus_impact", "core": "expelliarmus_impact"},
			"end": {"layers": [
				{"kind": "signature", "core": true, "life": 0.4, "blend": "add"}
			], "length": 0.4, "audio": "spell_expelliarmus_end", "core": "expelliarmus_end"}
		},
	},
	"protego": {
		"colour": Color(0.16, 0.55, 1.0),
		"stages": {
			"cast": {"layers": [
				{"kind": "signature", "core": true, "life": 0.35, "blend": "add"},
				{"kind": "light", "colour": true, "energy": 2.5, "range": 5.0, "life": 0.3}
			], "length": 0.35, "audio": "spell_protego_cast", "core": "protego_cast"},
			"sustain": {"layers": [
				{"kind": "mesh", "mesh": "vfx_shield_mesh", "blend": "add", "core": true, "colour": true, "size": Vector3(1.8, 1.8, 1.8), "life": 3.5, "ward": true},
				{"kind": "signature", "core": true, "life": 3.5, "blend": "add"}
			], "length": 3.5, "audio": "spell_protego_sustain", "core": "protego_sustain", "loop_audio": true},
			"impact": {"layers": [
				{"kind": "sprite", "energy_shape": 2, "core": true, "colour": true, "blend": "add", "size": 1.35, "life": 0.45, "at_hit": true},
				{"kind": "light", "colour": true, "energy": 2.5, "range": 5.0, "life": 0.2}
			], "length": 0.45, "audio": "spell_protego_impact", "core": "protego_impact"},
			"end": {"layers": [
				{"kind": "mesh", "mesh": "vfx_shield_mesh", "blend": "add", "core": true, "colour": true, "size": Vector3(1.8, 1.8, 1.8), "life": 0.5, "ward": true, "fracture": true},
				{"kind": "signature", "core": true, "life": 0.5, "blend": "add"}
			], "length": 0.5, "audio": "spell_protego_end", "core": "protego_end"}
		},
	},
	"ultimate": {
		"colour": Color(0.04, 1.0, 0.4),
		"stages": {
			"cast": {"layers": [
				{"kind": "signature", "core": true, "life": 0.6, "blend": "add"},
				{"kind": "particles", "tex": "vfx_spark_static", "blend": "add", "colour": true, "amount": 18, "life": 0.4, "speed": 1.7, "size": 0.06, "spread": 145.0, "gravity": -2.0, "optional": true},
				{"kind": "light", "colour": true, "energy": 3, "range": 5.0, "life": 0.4}
			], "length": 0.6, "audio": "spell_ultimate_cast", "core": "ultimate_cast"},
			"travel": {"layers": [
				{"kind": "signature", "core": true, "life": 0.0, "blend": "add"},
				{"kind": "particles", "tex": "vfx_spark_static", "blend": "add", "colour": true, "amount": 28, "life": 0.22, "speed": 1.2, "size": 0.06, "spread": 145.0, "gravity": -2.0, "optional": true, "continuous": true}
			], "length": 0.0, "audio": "spell_ultimate_travel", "core": "ultimate_travel", "loop_audio": true},
			"impact": {"layers": [
				{"kind": "signature", "core": true, "life": 1.1, "blend": "add"},
				{"kind": "particles", "tex": "vfx_spark_static", "blend": "add", "colour": true, "amount": 40, "life": 0.65, "speed": 5, "size": 0.06, "spread": 145.0, "gravity": -2.0, "optional": true},
				{"kind": "light", "colour": true, "energy": 4, "range": 5.0, "life": 0.45}
			], "length": 1.1, "audio": "spell_ultimate_impact", "core": "ultimate_impact", "aoe_radius": 12.0},
			"end": {"layers": [
				{"kind": "signature", "core": true, "life": 0.85, "blend": "add"},
				{"kind": "flipbook", "atlas": "vfx_smoke_puff", "blend": "alpha", "size": 2.6, "life": 0.85, "optional": true, "opacity": 0.3}
			], "length": 0.85, "audio": "spell_ultimate_end", "core": "ultimate_end"}
		},
	},
}

## Broom trail and boss warning are effects too (12.3 last rows).
const BROOM_TRAIL := {
	"colour": Color(1.0, 0.72, 0.35),
	"layers": [
		{"kind": "ribbon", "tex": "vfx_energy_streak", "blend": "add", "core": true,
			"width": 0.22, "length": 7.0, "mesh": "vfx_trail_mesh"},
		{"kind": "particles", "tex": "vfx_flame_static", "blend": "add", "core": false,
			"amount": 28, "life": 0.55, "speed": 2.2, "spread": 22.0, "gravity": 0.6, "size": 0.42},
		{"kind": "particles", "tex": "vfx_spark_static", "blend": "add", "core": false, "optional": true,
			"amount": 18, "life": 0.7, "speed": 3.0, "spread": 30.0, "gravity": -1.5, "size": 0.08},
		{"kind": "light", "core": false, "colour": true, "energy": 1.4, "range": 5.0},
	],
}

const BOSS_WARNING := {
	"colour": Color(1.0, 0.25, 0.08),
	"layers": [
		# The ground mask IS the hit area - geometry is intentional here, and it
		# matches the authoritative shape (disc for area/slam, lune for
		# directional). Everything else is layered on top.
		{"kind": "sprite", "atlas": "vfx_rune_masks", "frame": 0, "blend": "add", "core": true,
			"flat": true, "lift": 0.08, "size": 1.0, "fade": "hold"},
		{"kind": "sprite", "atlas": "vfx_rune_masks", "frame": 1, "blend": "add", "core": true,
			"flat": true, "lift": 0.10, "size": 0.92, "fade": "hold"},
		{"kind": "sprite", "atlas": "vfx_ground_marks", "frame": 3, "blend": "alpha", "core": false,
			"flat": true, "lift": 0.06, "size": 1.1, "fade": "hold"},
		{"kind": "particles", "tex": "vfx_spark_static", "blend": "add", "core": false, "optional": true,
			"amount": 10, "life": 0.8, "speed": 0.5, "spread": 180.0, "gravity": 0.4, "size": 0.06,
			"edge_only": true},
		{"kind": "light", "core": false, "colour": true, "energy": 1.8, "range": 6.0},
	],
}

## Quality variants (12.4): reduce layers, atlas use and dynamic lights,
## but never the layer that carries the gameplay information.
const QUALITY := {
	"low": {"max_layers": 3, "lights": false, "particles": 0.5, "frame_step": 2, "atlas_scale": 0.5, "sprite_scale": 0.5},
	"medium": {"max_layers": 5, "lights": true, "particles": 0.8, "frame_step": 1, "atlas_scale": 0.75, "sprite_scale": 0.75},
	"high": {"max_layers": 99, "lights": true, "particles": 1.0, "frame_step": 1, "atlas_scale": 1.0, "sprite_scale": 1.0},
}


static func asset(id: String) -> Dictionary:
	return ASSETS.get(id, {})


static func asset_path(id: String) -> String:
	var entry := asset(id)
	return String(entry.get("path", entry.get("mesh", "")))


static func asset_exists(id: String) -> bool:
	var path := asset_path(id)
	return path != "" and ResourceLoader.exists(path)


static func spell_ids() -> Array:
	return SPELLS.keys()


static func stages_for(spell_id: String) -> Dictionary:
	return (SPELLS.get(spell_id, {}) as Dictionary).get("stages", {})


static func spell_colour(spell_id: String) -> Color:
	return (SPELLS.get(spell_id, {}) as Dictionary).get("colour", Color.WHITE)


static func stage_length(spell_id: String, stage: String) -> float:
	return float((stages_for(spell_id).get(stage, {}) as Dictionary).get("length", 0.6))


## Expand preset names and apply the quality variant. Returns the layer list the
## effect scene should build, in draw order.
static func layers_for(spell_id: String, stage: String, quality: String = "high") -> Array:
	var stage_data: Dictionary = stages_for(spell_id).get(stage, {})
	if stage_data.is_empty():
		return []
	var preset: Dictionary = QUALITY.get(quality, QUALITY["high"])
	var expanded: Array = []
	for raw in stage_data.get("layers", []):
		expanded.append(_expand(raw))
	# Additive/alpha order matters: alpha layers (smoke, fire body) draw first so
	# additive light on top of them reads as light, not as a wash.
	expanded.sort_custom(func(a, b): return _blend_rank(a) < _blend_rank(b))
	var out: Array = []
	var budget := int(preset["max_layers"])
	var kept_core := 0
	var dropped_optional := 0
	for layer in expanded:
		var is_core: bool = bool(layer.get("core", false))
		var optional: bool = bool(layer.get("optional", false))
		if quality == "low" and optional and not is_core:
			dropped_optional += 1
			continue
		if layer.get("kind", "") == "light" and not bool(preset["lights"]) and not is_core:
			continue
		out.append(_tune(layer, preset))
	if out.size() > budget:
		# Trim from the end, but never below the core layers.
		var core_layers: Array = []
		var extras: Array = []
		for layer in out:
			if bool(layer.get("core", false)):
				core_layers.append(layer)
			else:
				extras.append(layer)
		out = core_layers + extras.slice(0, maxi(0, budget - core_layers.size()))
	return out


static func _blend_rank(layer: Dictionary) -> int:
	var blend := String(layer.get("blend", "alpha"))
	if layer.get("kind", "") == "particles":
		return 2
	return 1 if blend == "add" else 0


static func _expand(raw) -> Dictionary:
	if typeof(raw) == TYPE_STRING and LAYER_PRESETS.has(raw):
		var base: Dictionary = (LAYER_PRESETS[raw] as Dictionary).duplicate(true)
		base["preset"] = raw
		return base
	if typeof(raw) == TYPE_DICTIONARY:
		return (raw as Dictionary).duplicate(true)
	return {}


static func _tune(layer: Dictionary, preset: Dictionary) -> Dictionary:
	var out := layer.duplicate(true)
	match String(out.get("kind", "")):
		"particles":
			out["amount"] = maxi(1, int(round(float(out.get("amount", 12)) * float(preset["particles"]))))
		"flipbook":
			out["frame_step"] = int(preset["frame_step"])
			out["size"] = float(out.get("size", 1.0)) * (1.0 if bool(out.get("core", false)) else float(preset["atlas_scale"]))
		"sprite":
			out["size"] = float(out.get("size", 1.0)) * (1.0 if bool(out.get("core", false)) else float(preset["sprite_scale"]))
		"mesh":
			out["size"] = (out.get("size", Vector3.ONE) as Vector3) * (1.0 if bool(out.get("core", false)) else float(preset["atlas_scale"]))
		"ribbon":
			out["width"] = float(out.get("width", 0.1)) * (1.0 if bool(out.get("core", false)) else float(preset["atlas_scale"]))
		"light":
			out["energy"] = float(out.get("energy", 2.0)) * float(preset["particles"])
	return out


## True when the table is internally consistent: every layer names a real asset,
## every spell has the stages 12.3 asks for, and the low variant is lighter than
## the high one while keeping the core layers. Used by the spell effects checks.
static func validate_table() -> Array:
	var problems: Array = []
	for spell_id in SPELLS:
		var stages := stages_for(spell_id)
		var expected: Array = []
		match spell_id:
			"basic_cast":
				expected = ["cast", "travel", "impact", "end"]
			"stupefy":
				expected = ["cast", "travel", "impact", "sustain"]
			"incendio":
				expected = ["cast", "impact", "sustain", "end"]
			"bombarda":
				expected = ["cast", "travel", "impact", "end"]
			"expelliarmus":
				expected = ["cast", "travel", "impact", "end"]
			"protego":
				expected = ["cast", "sustain", "impact", "end"]
			"ultimate":
				expected = ["cast", "travel", "impact", "end"]
		for stage in expected:
			if not stages.has(stage):
				problems.append("%s is missing its '%s' stage" % [spell_id, stage])
		for stage in stages:
			var stage_data: Dictionary = stages[stage]
			if String(stage_data.get("audio", "")) == "":
				problems.append("%s/%s has no audio event" % [spell_id, stage])
			for layer in layers_for(spell_id, String(stage), "high"):
				var kind := String(layer.get("kind", ""))
				if kind in ["flipbook", "sprite"]:
					var atlas := String(layer.get("atlas", layer.get("tex", "")))
					if atlas != "" and not ASSETS.has(atlas):
						problems.append("%s/%s layer names unknown asset '%s'" % [spell_id, stage, atlas])
				elif kind in ["mesh", "ribbon"] and layer.has("mesh"):
					if not ASSETS.has(String(layer["mesh"])):
						problems.append("%s/%s mesh layer names unknown asset '%s'" % [spell_id, stage, layer["mesh"]])
		for stage in stages:
			var high: Array = layers_for(spell_id, String(stage), "high")
			var low: Array = layers_for(spell_id, String(stage), "low")
			if low.size() > high.size():
				problems.append("%s/%s low variant has MORE layers than high" % [spell_id, stage])
			for layer in low:
				if String(layer.get("kind", "")) == "light":
					problems.append("%s/%s low variant still has a dynamic light" % [spell_id, stage])
			var core_missing := false
			for layer in high:
				if bool(layer.get("core", false)):
					var found := false
					for low_layer in low:
						if String(low_layer.get("kind", "")) == String(layer.get("kind", "")) \
								and bool(low_layer.get("core", false)):
							found = true
					if not found:
						core_missing = true
			if core_missing:
				problems.append("%s/%s low variant drops a gameplay-information layer" % [spell_id, stage])
	return problems
