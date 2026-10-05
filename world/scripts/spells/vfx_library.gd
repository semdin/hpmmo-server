extends RefCounted

## Phase 12 VFX library: the asset registry and the spell-by-spell composition
## table (plan.md 12.3), plus the quality variants (plan.md 12.4).
##
## Every effect scene builds its layers from this table - there is no second
## copy of the composition, so `run_phase12_checks.ps1` can assert the table
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

## Asset paths published by tools/blender/phase12_vfx.py + phase12_meshes.py.
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

## The composition table (plan.md 12.3). `colour` is the spell tint from
## data/json/spells.json; the tint is applied to the atlas layers so one atlas
## serves every spell while each keeps its own identity.
const SPELLS := {
	"basic_cast": {
		"colour": Color(1.0, 0.847, 0.4),
		"stages": {
			"cast": {"layers": ["glow_flash"], "length": 0.3,
				"audio": "spell_basic_cast_cast", "core": "cast_snap"},
			"travel": {"layers": [
				{"kind": "mesh", "mesh": "vfx_projectile_mesh", "blend": "add", "core": true,
					"size": Vector3(0.13, 0.13, 0.42), "life": 0.0, "follow": true, "colour": true},
				{"kind": "ribbon", "tex": "vfx_energy_streak", "blend": "add", "core": false,
					"width": 0.07, "length": 2.2, "life": 0.0, "follow": true},
				{"kind": "particles", "tex": "vfx_spark_static", "blend": "add", "core": false, "optional": true,
					"amount": 10, "life": 0.3, "speed": 1.2, "spread": 18.0, "gravity": 0.0, "size": 0.06},
			], "length": 0.0, "audio": "spell_basic_cast_travel", "loop_audio": true},
			"impact": {"layers": ["impact_ring", "ember_sparks", "glow_flash"], "length": 0.7,
				"audio": "spell_basic_cast_impact", "core": "impact_fleck"},
			"end": {"layers": [
				{"kind": "sprite", "tex": "vfx_soft_glow", "blend": "add", "core": true,
					"size": 0.7, "life": 0.35, "fade": "out"},
			], "length": 0.4, "audio": "spell_basic_cast_end"},
		},
	},
	"stupefy": {
		"colour": Color(1.0, 0.133, 0.2),
		"stages": {
			"cast": {"layers": [
				"glow_flash",
				{"kind": "flipbook", "atlas": "vfx_energy_impact", "blend": "add", "core": true,
					"size": 0.8, "life": 0.35, "colour": true},
			], "length": 0.4, "audio": "spell_stupefy_cast", "core": "cast_buildup"},
			"travel": {"layers": [
				{"kind": "mesh", "mesh": "vfx_projectile_mesh", "blend": "add", "core": true,
					"size": Vector3(0.16, 0.16, 0.62), "life": 0.0, "follow": true, "colour": true},
				{"kind": "ribbon", "tex": "vfx_energy_streak", "blend": "add", "core": false,
					"width": 0.10, "length": 2.8, "life": 0.0, "follow": true},
			], "length": 0.0, "audio": "spell_stupefy_travel", "loop_audio": true},
			"impact": {"layers": [
				"impact_ring",
				{"kind": "flipbook", "atlas": "vfx_energy_impact", "blend": "add", "core": false, "optional": true,
					"size": 2.2, "life": 0.5, "colour": true},
				"glow_flash",
			], "length": 0.8, "audio": "spell_stupefy_impact", "core": "impact_stun"},
			"sustain": {"layers": [
				{"kind": "sprite", "atlas": "vfx_rune_masks", "frame": 1, "blend": "add", "core": true,
					"billboard": true, "size": 1.6, "life": 1.8, "fade": "hold"},
			], "length": 1.8, "audio": "spell_stupefy_end", "core": "stun_indicator"},
		},
	},
	"incendio": {
		"colour": Color(1.0, 0.4, 0.0),
		"stages": {
			"cast": {
				# The authoritative shape is a short-range CONE burst, not a
				# projectile (spells.json + phase5-authority section 6), and the
				# presentation is a flame burst down the aim direction.
				"layers": [
					{"kind": "flipbook", "atlas": "vfx_fire_burst", "blend": "alpha", "core": true,
						"size": 2.6, "life": 0.75, "forward": 1.1, "colour": true},
					{"kind": "flipbook", "atlas": "vfx_flame_loop", "blend": "alpha", "core": true,
						"size": 2.2, "life": 1.0, "forward": 1.7, "loop": true, "colour": true},
					"ember_sparks",
					"smoke_puff",
					{"kind": "particles", "tex": "vfx_flame_static", "blend": "add", "core": false,
						"amount": 26, "life": 0.5, "speed": 9.0, "spread": 26.0, "gravity": 2.0,
						"size": 0.45, "forward": true, "colour": true},
					{"kind": "light", "core": false, "colour": true, "energy": 3.4, "range": 9.0, "life": 0.8},
					"ground_scorch",
				],
				"length": 1.1, "audio": "spell_incendio_cast", "core": "cone_burst"},
			"impact": {"layers": [
				{"kind": "flipbook", "atlas": "vfx_fire_burst", "blend": "alpha", "core": true,
					"size": 1.8, "life": 0.7, "colour": true},
				"ember_sparks", "smoke_puff",
				{"kind": "light", "core": false, "colour": true, "energy": 2.4, "range": 7.0, "life": 0.6},
			], "length": 0.9, "audio": "spell_incendio_impact", "core": "burn_hit"},
			"sustain": {"layers": [
				{"kind": "flipbook", "atlas": "vfx_flame_loop", "blend": "alpha", "core": true,
					"size": 1.1, "life": 3.0, "loop": true, "colour": true},
				{"kind": "particles", "tex": "vfx_flame_static", "blend": "alpha", "core": false, "optional": true,
					"amount": 14, "life": 0.7, "speed": 1.4, "spread": 40.0, "gravity": 1.0,
					"size": 0.35, "colour": true},
			], "length": 3.0, "audio": "spell_incendio_sustain", "loop_audio": true, "core": "burn_loop"},
			"end": {"layers": [
				{"kind": "flipbook", "atlas": "vfx_flame_loop", "blend": "alpha", "core": true,
					"size": 1.6, "life": 1.0, "loop": true, "colour": true},
				"smoke_puff",
			], "length": 1.2, "audio": "spell_incendio_end", "core": "extinguish"},
		},
	},
	"bombarda": {
		"colour": Color(1.0, 0.667, 0.133),
		"stages": {
			"cast": {"layers": [
				"glow_flash",
				{"kind": "flipbook", "atlas": "vfx_flame_loop", "blend": "alpha", "core": true,
					"size": 0.7, "life": 0.45, "colour": true},
			], "length": 0.45, "audio": "spell_bombarda_cast", "core": "charge"},
			"travel": {"layers": [
				{"kind": "mesh", "mesh": "vfx_projectile_mesh", "blend": "add", "core": true,
					"size": Vector3(0.26, 0.26, 0.7), "life": 0.0, "follow": true, "colour": true},
				{"kind": "ribbon", "tex": "vfx_energy_streak", "blend": "add", "core": false,
					"width": 0.16, "length": 2.4, "life": 0.0, "follow": true},
				{"kind": "particles", "tex": "vfx_flame_static", "blend": "add", "core": false, "optional": true,
					"amount": 12, "life": 0.35, "speed": 1.6, "spread": 30.0, "gravity": -1.0, "size": 0.2},
			], "length": 0.0, "audio": "spell_bombarda_travel", "loop_audio": true},
			"impact": {
				# The radius on screen is the authoritative AoE radius (9 m): the
				# dust ring is scaled to it so the telegraph is honest.
				"layers": [
					{"kind": "flipbook", "atlas": "vfx_fire_burst", "blend": "alpha", "core": true,
						"size": 4.0, "life": 0.8, "colour": true},
					"impact_ring", "smoke_puff", "ember_sparks",
					{"kind": "mesh", "mesh": "vfx_shard_meshes", "blend": "alpha", "core": false,
						"amount": 8, "size": Vector3(0.3, 0.3, 0.3), "life": 1.4, "burst": true},
					{"kind": "sprite", "atlas": "vfx_ground_marks", "frame": 0, "blend": "alpha", "core": true,
						"flat": true, "lift": 0.05, "size": 6.0, "life": 6.0, "fade": "slow"},
					{"kind": "light", "core": false, "colour": true, "energy": 5.5, "range": 14.0, "life": 0.7},
				],
				"length": 1.4, "audio": "spell_bombarda_impact", "core": "aoe_blast", "aoe_radius": 9.0},
			"end": {"layers": [
				{"kind": "flipbook", "atlas": "vfx_smoke_puff", "blend": "alpha", "core": true,
					"size": 3.0, "life": 1.6, "rise": 0.8},
			], "length": 1.6, "audio": "spell_bombarda_end", "core": "debris_settle"},
		},
	},
	"expelliarmus": {
		"colour": Color(0.933, 0.2, 0.333),
		"stages": {
			"cast": {"layers": ["glow_flash"], "length": 0.3,
				"audio": "spell_expelliarmus_cast", "core": "wand_sweep"},
			"travel": {"layers": [
				{"kind": "ribbon", "tex": "vfx_energy_streak", "blend": "add", "core": true,
					"width": 0.18, "length": 4.5, "life": 0.0, "follow": true},
				{"kind": "mesh", "mesh": "vfx_projectile_mesh", "blend": "add", "core": false,
					"size": Vector3(0.12, 0.12, 0.5), "life": 0.0, "follow": true, "colour": true},
				{"kind": "particles", "tex": "vfx_spark_static", "blend": "add", "core": false, "optional": true,
					"amount": 10, "life": 0.4, "speed": 1.0, "spread": 24.0, "gravity": 0.0, "size": 0.07},
			], "length": 0.0, "audio": "spell_expelliarmus_travel", "loop_audio": true},
			"impact": {"layers": [
				{"kind": "flipbook", "atlas": "vfx_energy_impact", "blend": "add", "core": true,
					"size": 1.8, "life": 0.6, "stretch": 1.6},
				"glow_flash",
				{"kind": "sprite", "atlas": "vfx_lightning_branches", "frame": 1, "blend": "add", "core": false,
					"size": 1.4, "life": 0.3, "spin": true},
			], "length": 0.7, "audio": "spell_expelliarmus_impact", "core": "weaken_cue"},
			"end": {"layers": [
				{"kind": "sprite", "tex": "vfx_soft_glow", "blend": "add", "core": true,
					"size": 0.8, "life": 0.45, "fade": "out"},
			], "length": 0.5, "audio": "spell_expelliarmus_end", "core": "interrupt_cue"},
		},
	},
	"protego": {
		"colour": Color(0.267, 0.667, 1.0),
		# The ONE place a mesh shell is correct. Rule, tooltip and VFX agree:
		# projectiles are reflected, all other damage is reduced by 60%.
		"stages": {
			"cast": {"layers": [
				{"kind": "mesh", "mesh": "vfx_shield_mesh", "blend": "alpha", "core": true,
					"size": Vector3(1.8, 1.8, 1.8), "life": 0.6, "grow": true, "flow": true},
				{"kind": "sprite", "tex": "vfx_soft_glow", "blend": "add", "core": false, "optional": true,
					"size": 2.4, "life": 0.5, "colour": true},
				{"kind": "light", "core": false, "colour": true, "energy": 2.2, "range": 6.0, "life": 0.6},
			], "length": 0.6, "audio": "spell_protego_cast", "core": "shield_raise"},
			"sustain": {"layers": [
				{"kind": "mesh", "mesh": "vfx_shield_mesh", "blend": "alpha", "core": true,
					"size": Vector3(1.8, 1.8, 1.8), "life": 3.5, "flow": true, "rim": true},
				{"kind": "sprite", "atlas": "vfx_rune_masks", "frame": 3, "blend": "add", "core": false,
					"flat": true, "lift": 0.04, "size": 4.2, "life": 3.5, "fade": "hold"},
			], "length": 3.5, "audio": "spell_protego_sustain", "loop_audio": true, "core": "ward"},
			"impact": {"layers": [
				{"kind": "flipbook", "atlas": "vfx_shield_ripple", "blend": "add", "core": true,
					"size": 0.9, "life": 0.65, "at_hit": true},
				{"kind": "light", "core": false, "colour": true, "energy": 1.6, "range": 4.0, "life": 0.3},
			], "length": 0.7, "audio": "spell_protego_impact", "core": "deflect_ping"},
			"end": {"layers": [
				{"kind": "mesh", "mesh": "vfx_shield_mesh", "blend": "add", "core": true,
					"size": Vector3(1.8, 1.8, 1.8), "life": 0.7, "fracture": true},
				{"kind": "sprite", "tex": "vfx_shield_fracture", "blend": "add", "core": false,
					"size": 3.2, "life": 0.6},
			], "length": 0.8, "audio": "spell_protego_end", "core": "ward_collapse"},
		},
	},
	"ultimate": {
		"colour": Color(0.0, 1.0, 0.467),
		"stages": {
			"cast": {
				# A readable warning before damage: anticipation field first, and
				# the strike is a separate stage. Limited bloom and shake.
				"layers": [
					{"kind": "sprite", "atlas": "vfx_rune_masks", "frame": 0, "blend": "add", "core": true,
						"flat": true, "lift": 0.05, "size": 5.0, "life": 0.7, "fade": "in"},
					{"kind": "sprite", "atlas": "vfx_rune_masks", "frame": 1, "blend": "add", "core": true,
						"billboard": true, "size": 2.2, "life": 0.7, "spin": true},
					{"kind": "flipbook", "atlas": "vfx_flame_loop", "blend": "add", "core": false,
						"size": 1.0, "life": 0.7, "loop": true, "colour": true},
					{"kind": "light", "core": false, "colour": true, "energy": 3.0, "range": 10.0, "life": 0.7},
				],
				"length": 0.8, "audio": "spell_ultimate_cast", "core": "anticipation_field"},
			"travel": {"layers": [
				{"kind": "flipbook", "atlas": "vfx_energy_impact", "blend": "add", "core": true,
					"size": 1.4, "life": 0.5, "colour": true},
				{"kind": "ribbon", "tex": "vfx_energy_streak", "blend": "add", "core": false,
					"width": 0.3, "length": 5.0, "life": 0.0, "follow": true},
			], "length": 0.0, "audio": "spell_ultimate_travel", "loop_audio": true},
			"impact": {"layers": [
				{"kind": "sprite", "atlas": "vfx_lightning_branches", "frame": 3, "blend": "add", "core": true,
					"size": 7.0, "life": 0.28, "flicker": true},
				{"kind": "sprite", "atlas": "vfx_lightning_branches", "frame": 0, "blend": "add", "core": false,
					"size": 5.4, "life": 0.22, "spin": true, "optional": true},
				"impact_ring",
				{"kind": "flipbook", "atlas": "vfx_fire_burst", "blend": "alpha", "core": false,
					"size": 3.2, "life": 0.7, "colour": true},
				{"kind": "sprite", "atlas": "vfx_ground_marks", "frame": 3, "blend": "alpha", "core": true,
					"flat": true, "lift": 0.05, "size": 8.0, "life": 5.0, "fade": "slow"},
				"ember_sparks", "smoke_puff",
				{"kind": "light", "core": false, "colour": true, "energy": 7.0, "range": 18.0, "life": 0.75},
			], "length": 1.5, "audio": "spell_ultimate_impact", "core": "strike"},
			"end": {"layers": [
				{"kind": "flipbook", "atlas": "vfx_flame_loop", "blend": "alpha", "core": true,
					"size": 2.0, "life": 1.4, "loop": true, "colour": true},
				"smoke_puff",
			], "length": 1.5, "audio": "spell_ultimate_end", "core": "tail"},
		},
	},
}

## Broom trail and boss warning are effects too (plan.md 12.3 last rows).
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

## Quality variants (plan.md 12.4): reduce layers, atlas use and dynamic lights,
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
## the high one while keeping the core layers. Used by the Phase 12 checks.
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
