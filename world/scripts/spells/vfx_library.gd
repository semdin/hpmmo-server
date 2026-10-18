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

## Asset paths. Spell effects come from tools/vfx/build_spell_vfx.py (generated
## clips and stills, art/vfx/README.md); the noise fields, legacy masks and the
## meshes from tools/blender/spell_vfx.py + spell_meshes.py.
const ATLAS_DIR := "res://assets/vfx/atlases/"
const TEX_DIR := "res://assets/vfx/tex/"
const MESH_DIR := "res://assets/vfx/meshes/"

const ASSETS := {
	# --- generated flipbooks (8 x 8, row-major) ---
	"vfx_fire_burst": {"path": ATLAS_DIR + "fire_burst_8x8_2k.png", "grid": Vector2(8, 8), "frames": 64, "fps": 22, "loop": false, "colour": true},
	"vfx_flame_loop": {"path": ATLAS_DIR + "flame_loop_8x8_1k.png", "grid": Vector2(8, 8), "frames": 64, "fps": 22, "loop": true, "colour": true},
	"vfx_smoke_puff": {"path": ATLAS_DIR + "smoke_puff_8x8_1k.png", "grid": Vector2(8, 8), "frames": 64, "fps": 22, "loop": false, "colour": true},
	"vfx_broom_mist": {"path": ATLAS_DIR + "broom_mist_8x8_1k.png", "grid": Vector2(8, 8), "frames": 64, "fps": 22, "loop": false, "colour": true},
	"vfx_broom_motes": {"path": ATLAS_DIR + "broom_motes_8x8_1k.png", "grid": Vector2(8, 8), "frames": 64, "fps": 22, "loop": false, "colour": true},
	"vfx_explosion": {"path": ATLAS_DIR + "explosion_8x8_2k.png", "grid": Vector2(8, 8), "frames": 64, "fps": 22, "loop": false, "colour": true},
	"vfx_burst_gold": {"path": ATLAS_DIR + "burst_gold_8x8_1k.png", "grid": Vector2(8, 8), "frames": 64, "fps": 22, "loop": false, "colour": true},
	"vfx_burst_red": {"path": ATLAS_DIR + "burst_red_8x8_1k.png", "grid": Vector2(8, 8), "frames": 64, "fps": 24, "loop": false, "colour": true},
	"vfx_burst_crimson": {"path": ATLAS_DIR + "burst_crimson_8x8_1k.png", "grid": Vector2(8, 8), "frames": 64, "fps": 23, "loop": false, "colour": true},
	"vfx_burst_green": {"path": ATLAS_DIR + "burst_green_8x8_2k.png", "grid": Vector2(8, 8), "frames": 64, "fps": 27, "loop": false, "colour": true},
	"vfx_ripple_blue": {"path": ATLAS_DIR + "ripple_blue_8x8_1k.png", "grid": Vector2(8, 8), "frames": 64, "fps": 25, "loop": false, "colour": true},
	"vfx_shockwave": {"path": ATLAS_DIR + "shockwave_8x8_1k.png", "grid": Vector2(8, 8), "frames": 64, "fps": 23, "loop": false, "colour": true},
	"vfx_wand_flash": {"path": ATLAS_DIR + "wand_flash_8x8_1k.png", "grid": Vector2(8, 8), "frames": 64, "fps": 48, "loop": false, "colour": true},
	"vfx_spark_burst": {"path": ATLAS_DIR + "spark_burst_8x8_1k.png", "grid": Vector2(8, 8), "frames": 64, "fps": 33, "loop": false, "colour": true},
	"vfx_energy_orb": {"path": ATLAS_DIR + "energy_orb_8x8_1k.png", "grid": Vector2(8, 8), "frames": 64, "fps": 44, "loop": true, "colour": true},
	"vfx_fire_orb": {"path": ATLAS_DIR + "fire_orb_8x8_1k.png", "grid": Vector2(8, 8), "frames": 64, "fps": 48, "loop": true, "colour": true},
	# --- generated / procedural stills ---
	"vfx_rune_seal": {"path": TEX_DIR + "rune_seal_512.png", "grid": Vector2(1, 1), "frames": 1, "loop": false, "colour": true},
	"vfx_star_flare": {"path": TEX_DIR + "star_flare_256.png", "grid": Vector2(1, 1), "frames": 1, "loop": false, "colour": true},
	"vfx_lightning_strands": {"path": TEX_DIR + "lightning_strands_512.png", "grid": Vector2(1, 1), "frames": 1, "loop": false, "colour": true},
	"vfx_hex_shield": {"path": TEX_DIR + "hex_shield_512.png", "grid": Vector2(1, 1), "frames": 1, "loop": false, "colour": true},
	"vfx_scorch_decal": {"path": TEX_DIR + "scorch_decal_512.png", "grid": Vector2(1, 1), "frames": 1, "loop": false, "colour": true},
	"vfx_energy_streak": {"path": TEX_DIR + "energy_streak_1024x256.png", "grid": Vector2(1, 1), "frames": 1, "loop": false, "colour": true},
	# --- authored noise fields and masks (tools/blender/spell_vfx.py) ---
	"vfx_soft_glow": {"path": TEX_DIR + "soft_glow_512.png", "grid": Vector2(1, 1), "frames": 1, "loop": false, "colour": true},
	"vfx_noise_flow": {"path": TEX_DIR + "noise_flow_512.png", "grid": Vector2(1, 1), "frames": 1, "loop": false, "colour": false},
	"vfx_noise_erosion": {"path": TEX_DIR + "noise_erosion_512.png", "grid": Vector2(1, 1), "frames": 1, "loop": false, "colour": false},
	"vfx_distortion": {"path": TEX_DIR + "distortion_512.png", "grid": Vector2(1, 1), "frames": 1, "loop": false, "colour": false},
	"vfx_shield_fracture": {"path": TEX_DIR + "shield_fracture_512.png", "grid": Vector2(1, 1), "frames": 1, "loop": false, "colour": false},
	"vfx_ground_marks": {"path": ATLAS_DIR + "ground_marks_2x2_1k.png", "grid": Vector2(2, 2), "frames": 4, "loop": false, "colour": true},
	"vfx_rune_masks": {"path": ATLAS_DIR + "rune_masks_2x2_1k.png", "grid": Vector2(2, 2), "frames": 4, "loop": false, "colour": false},
	# Kenney Particle Pack ingredients (CC0): detail sprites only, never the effect.
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
	"ember_sparks": {"kind": "particles", "tex": "vfx_star_flare", "blend": "add", "core": false,
		"amount": 16, "life": 0.55, "speed": 4.0, "spread": 55.0, "gravity": -6.0, "size": 0.09},
	"ground_scorch": {"kind": "sprite", "atlas": "vfx_scorch_decal", "blend": "alpha", "optional": true,
		"flat": true, "lift": 0.04, "size": 3.0, "life": 4.0, "fade": "slow"},
}

## The composition table (12.3). Every spell is built from the generated
## flipbooks: a wand flash at the tip, a looping orb core with a ribbon wake in
## flight, a signature burst on impact and a smoke/ember tail. `colour: true`
## tints a white (mono) asset with the spell colour; the coloured clips (fire,
## the bursts) keep their own colour. `fit` plays the whole flipbook over the
## layer's life, `grow` scales it over life, `roll` gives each copy a random
## rotation so two copies never read as clones.
const SPELLS := {
	"basic_cast": {
		"colour": Color(1.0, 0.72, 0.28),
		"stages": {
			"cast": {"layers": [
				{"kind": "flipbook", "atlas": "vfx_wand_flash", "blend": "add", "core": true, "colour": true,
					"size": 0.7, "life": 0.2, "fit": true, "roll": true, "grow": [0.7, 1.2]},
				{"kind": "particles", "tex": "vfx_star_flare", "blend": "add", "colour": true, "optional": true,
					"amount": 8, "life": 0.3, "speed": 3.0, "size": 0.07, "spread": 30.0, "gravity": -1.0, "forward": true},
				{"kind": "light", "colour": true, "energy": 1.6, "range": 2.5, "life": 0.14},
			], "length": 0.25, "audio": "spell_basic_cast_cast", "core": "cast_snap"},
			"travel": {"layers": [
				{"kind": "flipbook", "atlas": "vfx_energy_orb", "blend": "add", "core": true, "colour": true,
					"size": 0.8, "life": 0.0, "loop": true, "roll": true},
				{"kind": "ribbon", "tex": "vfx_energy_streak", "blend": "add", "core": true, "colour": true,
					"width": 0.2, "length": 3.0, "life": 0.0, "follow": true},
				{"kind": "particles", "tex": "vfx_star_flare", "blend": "add", "colour": true, "optional": true,
					"amount": 14, "life": 0.35, "speed": 0.4, "size": 0.05, "spread": 180.0, "gravity": -0.5, "continuous": true},
			], "length": 0.0, "audio": "spell_basic_cast_travel", "loop_audio": true},
			"impact": {"layers": [
				{"kind": "flipbook", "atlas": "vfx_burst_gold", "blend": "add", "core": true,
					"size": 1.6, "life": 0.55, "fit": true, "roll": true},
				{"kind": "flipbook", "atlas": "vfx_spark_burst", "blend": "add", "colour": true, "optional": true,
					"size": 1.2, "life": 0.35, "fit": true, "roll": true},
				{"kind": "light", "colour": true, "energy": 2.4, "range": 3.5, "life": 0.2},
			], "length": 0.55, "audio": "spell_basic_cast_impact", "core": "impact_fleck"},
			"end": {"layers": [
				{"kind": "flipbook", "atlas": "vfx_spark_burst", "blend": "add", "core": true, "colour": true,
					"size": 0.6, "life": 0.25, "fit": true, "opacity": 0.6},
			], "length": 0.25, "audio": "spell_basic_cast_end"},
		},
	},
	"stupefy": {
		"colour": Color(1.0, 0.12, 0.12),
		"stages": {
			"cast": {"layers": [
				{"kind": "flipbook", "atlas": "vfx_wand_flash", "blend": "add", "core": true, "colour": true,
					"size": 1.0, "life": 0.24, "fit": true, "roll": true, "grow": [0.6, 1.3]},
				{"kind": "particles", "tex": "vfx_star_flare", "blend": "add", "colour": true, "optional": true,
					"amount": 14, "life": 0.3, "speed": 3.4, "size": 0.06, "spread": 40.0, "gravity": 0.0, "forward": true},
				{"kind": "light", "colour": true, "energy": 2.6, "range": 3.0, "life": 0.22},
			], "length": 0.3, "audio": "spell_stupefy_cast", "core": "spiral_discharge"},
			"travel": {"layers": [
				{"kind": "flipbook", "atlas": "vfx_energy_orb", "blend": "add", "core": true, "colour": true,
					"size": 1.15, "life": 0.0, "loop": true, "roll": true},
				{"kind": "ribbon", "tex": "vfx_energy_streak", "blend": "add", "core": true, "colour": true,
					"width": 0.3, "length": 5.5, "life": 0.0, "follow": true},
				{"kind": "sprite", "atlas": "vfx_lightning_strands", "blend": "add", "colour": true, "optional": true,
					"size": 1.1, "life": 0.0, "flicker": true, "opacity": 0.7},
				{"kind": "particles", "tex": "vfx_star_flare", "blend": "add", "colour": true, "optional": true,
					"amount": 24, "life": 0.25, "speed": 1.0, "size": 0.05, "spread": 180.0, "gravity": 0.0, "continuous": true},
			], "length": 0.0, "audio": "spell_stupefy_travel", "loop_audio": true},
			"impact": {"layers": [
				{"kind": "flipbook", "atlas": "vfx_burst_red", "blend": "add", "core": true,
					"size": 2.4, "life": 0.7, "fit": true, "roll": true},
				{"kind": "flipbook", "atlas": "vfx_spark_burst", "blend": "add", "colour": true, "optional": true,
					"size": 1.8, "life": 0.4, "fit": true, "roll": true},
				{"kind": "light", "colour": true, "energy": 3.2, "range": 4.0, "life": 0.28},
			], "length": 0.72, "audio": "spell_stupefy_impact", "core": "torn_energy_burst"},
			"sustain": {"layers": [
				{"kind": "sprite", "atlas": "vfx_rune_seal", "blend": "add", "core": true, "colour": true,
					"size": 0.9, "life": 1.8, "fade": "hold", "flat": true, "lift": 0.0, "spin": true},
			], "length": 1.8, "audio": "spell_stupefy_end", "core": "stun_indicator"},
		},
	},
	"incendio": {
		"colour": Color(1.0, 0.42, 0.06),
		"stages": {
			# The cone: four rolling fire bursts marching along the aim, each a
			# beat later and larger, plus embers thrown the full length.
			"cast": {"layers": [
				# core: three bursts spanning the cone (all that the low preset keeps)
				{"kind": "flipbook", "atlas": "vfx_fire_burst", "blend": "add", "core": true,
					"size": 2.0, "forward": 1.0, "life": 0.6, "fit": true, "roll": true, "grow": [0.6, 1.15]},
				{"kind": "flipbook", "atlas": "vfx_fire_burst", "blend": "add", "core": true,
					"size": 3.2, "forward": 3.1, "life": 0.62, "delay": 0.05, "fit": true, "roll": true, "grow": [0.6, 1.2]},
				{"kind": "flipbook", "atlas": "vfx_fire_burst", "blend": "add", "core": true,
					"size": 4.4, "forward": 5.6, "life": 0.62, "delay": 0.1, "fit": true, "roll": true, "grow": [0.6, 1.25]},
				# fill: between and beyond, for a continuous jet on medium/high
				{"kind": "flipbook", "atlas": "vfx_fire_burst", "blend": "add", "optional": true,
					"size": 2.6, "forward": 2.0, "life": 0.6, "delay": 0.03, "fit": true, "roll": true, "grow": [0.6, 1.15]},
				{"kind": "flipbook", "atlas": "vfx_fire_burst", "blend": "add", "optional": true,
					"size": 3.8, "forward": 4.3, "life": 0.62, "delay": 0.08, "fit": true, "roll": true, "grow": [0.6, 1.2]},
				{"kind": "flipbook", "atlas": "vfx_fire_burst", "blend": "add", "optional": true,
					"size": 4.8, "forward": 7.2, "life": 0.58, "delay": 0.14, "fit": true, "roll": true, "grow": [0.6, 1.25]},
				{"kind": "particles", "tex": "vfx_flame_static", "blend": "add", "colour": true, "optional": true,
					"amount": 30, "life": 0.7, "speed": 14.0, "size": 0.35, "spread": 24.0, "gravity": 1.5, "forward": true},
				{"kind": "light", "colour": true, "energy": 3.4, "range": 7.0, "life": 0.55},
			], "length": 0.8, "audio": "spell_incendio_cast", "core": "incendio_cast"},
			"impact": {"layers": [
				{"kind": "flipbook", "atlas": "vfx_fire_burst", "blend": "add", "core": true,
					"size": 1.8, "life": 0.55, "fit": true, "roll": true},
				{"kind": "particles", "tex": "vfx_star_flare", "blend": "add", "colour": true, "optional": true,
					"amount": 16, "life": 0.5, "speed": 3.5, "size": 0.06, "spread": 150.0, "gravity": -3.0},
				{"kind": "light", "colour": true, "energy": 2.5, "range": 4.0, "life": 0.3},
			], "length": 0.6, "audio": "spell_incendio_impact", "core": "incendio_impact"},
			"sustain": {"layers": [
				{"kind": "flipbook", "atlas": "vfx_flame_loop", "blend": "add", "core": true,
					"size": 1.6, "life": 3.0, "loop": true, "fade": "hold"},
				{"kind": "particles", "tex": "vfx_flame_static", "blend": "add", "colour": true, "optional": true,
					"amount": 10, "life": 0.8, "speed": 1.2, "size": 0.18, "spread": 30.0, "gravity": 2.0},
			], "length": 3.0, "audio": "spell_incendio_sustain", "core": "incendio_sustain", "loop_audio": true},
			"end": {"layers": [
				{"kind": "flipbook", "atlas": "vfx_smoke_puff", "blend": "alpha", "core": true,
					"size": 2.2, "life": 0.9, "fit": true, "roll": true, "opacity": 0.55},
			], "length": 0.9, "audio": "spell_incendio_end", "core": "incendio_end"},
		},
	},
	# Expecto Patronum: a silver charge down a wide cone - rippling moonlight
	# rings marching along the aim, star dust thrown the full length.
	"patronum": {
		"colour": Color(0.82, 0.9, 1.0),
		"stages": {
			"cast": {"layers": [
				{"kind": "flipbook", "atlas": "vfx_ripple_blue", "blend": "add", "core": true,
					"size": 2.4, "forward": 1.6, "life": 0.6, "fit": true, "roll": true, "grow": [0.6, 1.2]},
				{"kind": "flipbook", "atlas": "vfx_ripple_blue", "blend": "add", "core": true,
					"size": 3.8, "forward": 5.4, "life": 0.65, "delay": 0.08, "fit": true, "roll": true, "grow": [0.6, 1.3]},
				{"kind": "flipbook", "atlas": "vfx_ripple_blue", "blend": "add", "optional": true,
					"size": 5.0, "forward": 9.5, "life": 0.65, "delay": 0.16, "fit": true, "roll": true, "grow": [0.6, 1.35]},
				{"kind": "particles", "tex": "vfx_star_flare", "blend": "add", "colour": true, "optional": true,
					"amount": 40, "life": 0.9, "speed": 18.0, "size": 0.12, "spread": 22.0, "gravity": 0.0, "forward": true},
				{"kind": "light", "colour": true, "energy": 4.0, "range": 9.0, "life": 0.7},
			], "length": 0.9, "audio": "spell_patronum_cast", "core": "patronum_charge"},
			"impact": {"layers": [
				{"kind": "flipbook", "atlas": "vfx_ripple_blue", "blend": "add", "core": true,
					"size": 2.0, "life": 0.5, "fit": true, "roll": true},
				{"kind": "particles", "tex": "vfx_star_flare", "blend": "add", "colour": true, "optional": true,
					"amount": 18, "life": 0.6, "speed": 3.0, "size": 0.07, "spread": 160.0, "gravity": -2.0},
			], "length": 0.6, "audio": "spell_patronum_impact", "core": "patronum_impact"},
			# The stag dissolves into drifting silver mist.
			"end": {"layers": [
				{"kind": "flipbook", "atlas": "vfx_smoke_puff", "blend": "add", "core": true,
					"size": 2.6, "life": 1.0, "fit": true, "roll": true, "opacity": 0.35},
				{"kind": "particles", "tex": "vfx_star_flare", "blend": "add", "colour": true, "optional": true,
					"amount": 10, "life": 1.0, "speed": 0.8, "size": 0.05, "spread": 180.0, "gravity": -0.6},
			], "length": 1.0, "audio": "spell_basic_cast_end", "core": "patronum_fade"},
		},
	},
	"bombarda": {
		"colour": Color(1.0, 0.55, 0.12),
		"stages": {
			"cast": {"layers": [
				{"kind": "flipbook", "atlas": "vfx_wand_flash", "blend": "add", "core": true, "colour": true,
					"size": 1.2, "life": 0.26, "fit": true, "roll": true, "grow": [0.6, 1.4]},
				{"kind": "particles", "tex": "vfx_flame_static", "blend": "add", "colour": true, "optional": true,
					"amount": 10, "life": 0.35, "speed": 3.0, "size": 0.2, "spread": 40.0, "gravity": 1.0, "forward": true},
				{"kind": "light", "colour": true, "energy": 2.5, "range": 4.0, "life": 0.3},
			], "length": 0.35, "audio": "spell_bombarda_cast", "core": "bombarda_cast"},
			"travel": {"layers": [
				{"kind": "flipbook", "atlas": "vfx_fire_orb", "blend": "add", "core": true,
					"size": 1.3, "life": 0.0, "loop": true, "roll": true},
				{"kind": "ribbon", "tex": "vfx_energy_streak", "blend": "add", "core": true, "colour": true,
					"width": 0.4, "length": 4.0, "life": 0.0, "follow": true},
				{"kind": "particles", "tex": "vfx_flame_static", "blend": "add", "colour": true, "optional": true,
					"amount": 22, "life": 0.4, "speed": 0.6, "size": 0.22, "spread": 180.0, "gravity": 1.5, "continuous": true},
			], "length": 0.0, "audio": "spell_bombarda_travel", "core": "bombarda_travel", "loop_audio": true},
			"impact": {"layers": [
				{"kind": "flipbook", "atlas": "vfx_explosion", "blend": "add", "core": true,
					"forward": -1.6, "size": 6.0, "life": 1.0, "fit": true, "roll": true},
				{"kind": "flipbook", "atlas": "vfx_shockwave", "blend": "add", "core": true, "colour": true,
					"flat": true, "lift": 0.08, "size": 2.0, "life": 0.6, "fit": true},
				{"kind": "flipbook", "atlas": "vfx_smoke_puff", "blend": "alpha", "optional": true,
					"forward": -1.6, "size": 5.0, "life": 1.4, "delay": 0.25, "fit": true, "roll": true, "opacity": 0.5},
				"ground_scorch",
				{"kind": "light", "colour": true, "energy": 4.5, "range": 9.0, "life": 0.5},
			], "length": 1.4, "audio": "spell_bombarda_impact", "core": "bombarda_impact", "aoe_radius": 9.0},
			"end": {"layers": [
				{"kind": "flipbook", "atlas": "vfx_smoke_puff", "blend": "alpha", "core": true,
					"size": 3.6, "life": 1.1, "fit": true, "roll": true, "opacity": 0.45},
			], "length": 1.1, "audio": "spell_bombarda_end", "core": "bombarda_end"},
		},
	},
	"expelliarmus": {
		"colour": Color(1.0, 0.18, 0.5),
		"stages": {
			"cast": {"layers": [
				{"kind": "flipbook", "atlas": "vfx_wand_flash", "blend": "add", "core": true, "colour": true,
					"size": 0.9, "life": 0.22, "fit": true, "roll": true, "grow": [0.6, 1.25]},
				{"kind": "particles", "tex": "vfx_star_flare", "blend": "add", "colour": true, "optional": true,
					"amount": 10, "life": 0.28, "speed": 3.0, "size": 0.06, "spread": 35.0, "gravity": 0.0, "forward": true},
				{"kind": "light", "colour": true, "energy": 2.2, "range": 3.0, "life": 0.2},
			], "length": 0.28, "audio": "spell_expelliarmus_cast", "core": "expelliarmus_cast"},
			"travel": {"layers": [
				{"kind": "flipbook", "atlas": "vfx_energy_orb", "blend": "add", "core": true, "colour": true,
					"size": 0.95, "life": 0.0, "loop": true, "roll": true, "spin": true},
				{"kind": "ribbon", "tex": "vfx_energy_streak", "blend": "add", "core": true, "colour": true,
					"width": 0.24, "length": 4.2, "life": 0.0, "follow": true},
				{"kind": "particles", "tex": "vfx_star_flare", "blend": "add", "colour": true, "optional": true,
					"amount": 16, "life": 0.22, "speed": 0.6, "size": 0.05, "spread": 180.0, "gravity": 0.0, "continuous": true},
			], "length": 0.0, "audio": "spell_expelliarmus_travel", "core": "expelliarmus_travel", "loop_audio": true},
			"impact": {"layers": [
				{"kind": "flipbook", "atlas": "vfx_burst_crimson", "blend": "add", "core": true,
					"size": 2.2, "life": 0.6, "fit": true, "roll": true},
				{"kind": "flipbook", "atlas": "vfx_spark_burst", "blend": "add", "colour": true, "optional": true,
					"size": 1.6, "life": 0.4, "fit": true, "roll": true},
				{"kind": "light", "colour": true, "energy": 2.6, "range": 4.0, "life": 0.22},
			], "length": 0.6, "audio": "spell_expelliarmus_impact", "core": "expelliarmus_impact"},
			"end": {"layers": [
				{"kind": "flipbook", "atlas": "vfx_spark_burst", "blend": "add", "core": true, "colour": true,
					"size": 0.7, "life": 0.3, "fit": true, "opacity": 0.6},
			], "length": 0.3, "audio": "spell_expelliarmus_end", "core": "expelliarmus_end"},
		},
	},
	"protego": {
		"colour": Color(0.25, 0.62, 1.0),
		"stages": {
			"cast": {"layers": [
				{"kind": "flipbook", "atlas": "vfx_ripple_blue", "blend": "add", "core": true,
					"size": 2.8, "life": 0.5, "fit": true},
				{"kind": "light", "colour": true, "energy": 2.5, "range": 5.0, "life": 0.3},
			], "length": 0.5, "audio": "spell_protego_cast", "core": "protego_cast"},
			"sustain": {"layers": [
				{"kind": "mesh", "mesh": "vfx_shield_mesh", "blend": "add", "core": true, "colour": true,
					"size": Vector3(1.8, 1.8, 1.8), "life": 3.5, "ward": true, "hex": "vfx_hex_shield"},
				{"kind": "particles", "tex": "vfx_star_flare", "blend": "add", "colour": true, "optional": true,
					"amount": 12, "life": 1.2, "speed": 0.3, "size": 0.05, "spread": 180.0, "gravity": 0.3, "continuous": true},
			], "length": 3.5, "audio": "spell_protego_sustain", "core": "protego_sustain", "loop_audio": true},
			"impact": {"layers": [
				{"kind": "flipbook", "atlas": "vfx_ripple_blue", "blend": "add", "core": true,
					"size": 1.5, "life": 0.45, "fit": true, "at_hit": true},
				{"kind": "light", "colour": true, "energy": 2.5, "range": 4.0, "life": 0.2},
			], "length": 0.45, "audio": "spell_protego_impact", "core": "protego_impact"},
			"end": {"layers": [
				{"kind": "mesh", "mesh": "vfx_shield_mesh", "blend": "add", "core": true, "colour": true,
					"size": Vector3(1.8, 1.8, 1.8), "life": 0.5, "ward": true, "hex": "vfx_hex_shield", "fracture": true},
				{"kind": "flipbook", "atlas": "vfx_spark_burst", "blend": "add", "colour": true, "optional": true,
					"size": 2.4, "life": 0.45, "fit": true, "roll": true},
			], "length": 0.5, "audio": "spell_protego_end", "core": "protego_end"},
		},
	},
	"ultimate": {
		"colour": Color(0.15, 1.0, 0.45),
		"stages": {
			"cast": {"layers": [
				{"kind": "flipbook", "atlas": "vfx_wand_flash", "blend": "add", "core": true, "colour": true,
					"size": 1.6, "life": 0.32, "fit": true, "roll": true, "grow": [0.6, 1.5]},
				{"kind": "sprite", "atlas": "vfx_lightning_strands", "blend": "add", "colour": true, "optional": true,
					"size": 1.8, "life": 0.35, "flicker": true},
				{"kind": "light", "colour": true, "energy": 3.2, "range": 5.0, "life": 0.4},
			], "length": 0.45, "audio": "spell_ultimate_cast", "core": "ultimate_cast"},
			"travel": {"layers": [
				{"kind": "flipbook", "atlas": "vfx_energy_orb", "blend": "add", "core": true, "colour": true,
					"size": 1.8, "life": 0.0, "loop": true, "roll": true},
				{"kind": "ribbon", "tex": "vfx_energy_streak", "blend": "add", "core": true, "colour": true,
					"width": 0.5, "length": 5.0, "life": 0.0, "follow": true},
				{"kind": "sprite", "atlas": "vfx_lightning_strands", "blend": "add", "colour": true, "optional": true,
					"size": 2.2, "life": 0.0, "flicker": true, "opacity": 0.85},
				{"kind": "particles", "tex": "vfx_star_flare", "blend": "add", "colour": true, "optional": true,
					"amount": 28, "life": 0.3, "speed": 1.4, "size": 0.07, "spread": 180.0, "gravity": 0.0, "continuous": true},
			], "length": 0.0, "audio": "spell_ultimate_travel", "core": "ultimate_travel", "loop_audio": true},
			"impact": {"layers": [
				{"kind": "flipbook", "atlas": "vfx_burst_green", "blend": "add", "core": true,
					"forward": -2.0, "size": 8.0, "life": 1.1, "fit": true, "roll": true},
				{"kind": "flipbook", "atlas": "vfx_shockwave", "blend": "add", "core": true, "colour": true,
					"flat": true, "lift": 0.08, "size": 2.0, "life": 0.7, "fit": true},
				{"kind": "flipbook", "atlas": "vfx_smoke_puff", "blend": "alpha", "optional": true,
					"forward": -2.0, "size": 6.0, "life": 1.5, "delay": 0.3, "fit": true, "roll": true, "opacity": 0.4},
				"ground_scorch",
				{"kind": "light", "colour": true, "energy": 5.0, "range": 12.0, "life": 0.6},
			], "length": 1.5, "audio": "spell_ultimate_impact", "core": "ultimate_impact", "aoe_radius": 12.0},
			"end": {"layers": [
				{"kind": "sprite", "atlas": "vfx_lightning_strands", "blend": "add", "core": true, "colour": true,
					"size": 3.0, "life": 0.6, "flicker": true, "opacity": 0.6},
				{"kind": "flipbook", "atlas": "vfx_smoke_puff", "blend": "alpha", "optional": true,
					"size": 4.0, "life": 0.9, "fit": true, "roll": true, "opacity": 0.4},
			], "length": 0.9, "audio": "spell_ultimate_end", "core": "ultimate_end"},
		},
	},
}

## Broom trail and boss warning are effects too (12.3 last rows).
const BROOM_TRAIL := {
	"colour": Color(0.82, 0.88, 1.0),
	"layers": [
		{"kind": "ribbon", "tex": "vfx_energy_streak", "blend": "add", "core": true,
			"width": 0.16, "length": 7.0, "mesh": "vfx_trail_mesh"},
		{"kind": "particles", "tex": "vfx_broom_mist", "blend": "alpha", "core": true,
			"amount": 14, "life": 1.5, "size": 0.55},
		{"kind": "particles", "tex": "vfx_broom_motes", "blend": "add", "core": false,
			"amount": 7, "life": 1.3, "size": 0.5},
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
			"patronum":
				expected = ["cast", "impact", "end"]
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
