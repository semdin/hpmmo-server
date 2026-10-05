shader_type spatial;
// Phase 12 spell effect layer (alpha-blended variant).
//
// One billboard/flat quad reads ONE cell of a flipbook atlas. The layer's blend
// mode is chosen per layer by picking this shader (alpha) or
// spell_layer_add.gdshader (additive) - the plan requires a per-layer choice,
// and smoke that reads as glowing white light is a failure.
//
// Atlas metadata contract (assets/vfx/metadata.json): frames run row-major from
// the top-left cell; every cell carries a zero-alpha padding gutter so
// mipmapping cannot bleed a neighbour's content in.
render_mode unshaded, cull_disabled, depth_draw_never, shadows_disabled;

uniform sampler2D atlas : filter_linear_mipmap;
uniform vec2 grid = vec2(8.0, 8.0);
uniform float frame : hint_range(0.0, 255.0) = 0.0;
uniform bool billboard = true;
uniform vec4 tint : source_color = vec4(1.0, 1.0, 1.0, 1.0);
uniform float opacity : hint_range(0.0, 1.0) = 1.0;
// Soft-particle depth fade: hides the hard intersection where a quad meets
// geometry (near-wall launches, indoor casts). 0 disables the depth read.
uniform float soft_fade : hint_range(0.0, 2.0) = 0.0;
// Dissolve: erodes the sprite with the shared erosion noise (shield expiry).
uniform sampler2D erosion;
// Godot 4.7: soft-particle depth comes from a hint_depth_texture uniform
// (the old DEPTH_TEXTURE built-in was removed).
uniform sampler2D depth_tex : hint_depth_texture, repeat_disable, filter_nearest;
uniform float erode : hint_range(0.0, 1.0) = 0.0;
uniform float emission_boost : hint_range(0.0, 8.0) = 1.0;

varying vec2 uv_frame;

void vertex() {
	if (billboard) {
		MODELVIEW_MATRIX = VIEW_MATRIX * mat4(
			INV_VIEW_MATRIX[0], INV_VIEW_MATRIX[1], INV_VIEW_MATRIX[2], MODEL_MATRIX[3]);
	}
	vec2 cell = vec2(1.0) / grid;
	float idx = floor(frame + 0.5);
	vec2 origin = vec2(mod(idx, grid.x), floor(idx / grid.x)) * cell;
	uv_frame = origin + UV * cell;
}

void fragment() {
	vec4 c = texture(atlas, uv_frame);
	float a = c.a * opacity * tint.a;
	if (erode > 0.0) {
		float e = texture(erosion, UV).r;
		a *= clamp((a - erode * e) / 0.15, 0.0, 1.0);
	}
	if (soft_fade > 0.0) {
		float depth_raw = texture(depth_tex, SCREEN_UV).r;
		vec4 view = INV_PROJECTION_MATRIX * vec4(SCREEN_UV * 2.0 - 1.0, depth_raw, 1.0);
		float scene_dist = -view.z / max(1e-5, view.w);
		a *= clamp((scene_dist - (-VERTEX.z)) / soft_fade, 0.0, 1.0);
	}
	ALBEDO = c.rgb * tint.rgb * emission_boost;
	ALPHA = clamp(a, 0.0, 1.0);
}
