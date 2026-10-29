shader_type spatial;
// Painted hero brows (Hero_BrowPaint, art/characters/hero_q/build_rig.py): a
// skin-hugging copy of the head's brow band whose UVs are the camera the brows
// were drawn through, textured with the five drawings side by side
// (brow_paint.png, white = brow). brow_paint picks the tile (1-5; 0 hides the
// patch in HeroAppearance.apply_look); the brow takes the hair colour.
render_mode blend_mix, depth_draw_never, cull_back;

#include "res://assets/shaders/hero_instance.gdshaderinc"
uniform sampler2D albedo_tex : hint_default_black, filter_linear_mipmap_anisotropic, repeat_disable;
uniform float tiles = 5.0;

void fragment() {
	float tile = clamp(round(brow_paint) - 1.0, 0.0, tiles - 1.0);
	vec2 uv = clamp(UV, vec2(0.0), vec2(1.0));
	float inside = step(0.0, UV.x) * step(UV.x, 1.0) * step(0.0, UV.y) * step(UV.y, 1.0);
	// the drawings' soft greys read as a faint, thin brow on the skin: firm them up
	float brow = smoothstep(0.06, 0.5, texture(albedo_tex, vec2((uv.x + tile) / tiles, uv.y)).r) * inside;
	ALBEDO = hair_color * 0.7;
	ALPHA = brow * 0.95;
	ROUGHNESS = 0.8;
	SPECULAR = 0.2;
}
