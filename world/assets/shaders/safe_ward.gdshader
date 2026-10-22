shader_type spatial;
// Safe-zone border (grounds_builder.gd _ward_lines): a ring of slowly turning
// gold runes laid on the ground, and a low veil of light standing on it that
// fades upward and shows mostly at grazing angles. UV.x runs along the ring in
// metres / tile, UV.y across the band (0 inside -> 1 outside) or up the veil.
render_mode unshaded, blend_add, cull_disabled, depth_draw_never, shadows_disabled;

uniform sampler2D rune : source_color, repeat_enable, filter_linear_mipmap;
uniform vec4 tint : source_color = vec4(1.0, 0.8, 0.45, 1.0);
uniform bool veil = false;
uniform float strength = 1.0;

// Sine-free hash: sin() of the large column numbers round a 200 m ring loses
// precision differently per GPU, which lined every streak up on some cards.
float h(float x) { x = fract(x * 0.1031); x *= x + 33.33; x *= x + x; return fract(x); }

void fragment() {
	if (!veil) {
		float r = texture(rune, vec2(UV.x - TIME * 0.015, UV.y)).r;
		float edge = smoothstep(0.0, 0.12, UV.y) * smoothstep(1.0, 0.88, UV.y);
		float a = (r * 0.9 + 0.05) * edge;
		ALBEDO = max(tint.rgb * a * strength * (0.85 + 0.15 * sin(TIME * 1.3 + UV.x * 0.8)), vec3(0.0));
	} else {
		// Clamped: with MSAA the fragment can sit just past the veil's top edge,
		// UV.y > 1 there, and pow() of the negative base below is NaN, which
		// glow then smears into a row of white blobs along the ring.
		float up = clamp(UV.y, 0.0, 1.0);         // 0 at the ground
		float fall = pow(1.0 - up, 2.2);
		float col = floor(UV.x * 40.0);
		float streak = pow(fract(up * 0.8 - TIME * (0.12 + h(col) * 0.2) + h(col + 3.0)), 10.0) * step(0.6, h(col + 7.0));
		float graze = pow(max(1.0 - abs(dot(normalize(NORMAL), normalize(VIEW))), 0.0), 1.5);
		float a = (fall * 0.22 + streak * 0.35 * (1.0 - up)) * (0.35 + graze * 0.65);
		ALBEDO = max(tint.rgb * a * strength, vec3(0.0));
	}
}
