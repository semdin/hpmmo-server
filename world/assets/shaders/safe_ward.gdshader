shader_type spatial;
// Safe-zone border (grounds_builder.gd _ward_lines): a thin ring of slowly
// turning gold runes laid on the ground, and a low soft veil standing on it
// that fades upward, shows mostly at grazing angles and only within a few
// metres of the camera. UV.x runs along the ring in tiles, UV.y across the band
// (0 inside -> 1 outside) or up the veil.
render_mode unshaded, blend_add, cull_disabled, depth_draw_never, shadows_disabled;

uniform sampler2D rune : source_color, repeat_enable, filter_linear_mipmap;
uniform vec4 tint : source_color = vec4(1.0, 0.8, 0.45, 1.0);
uniform bool veil = false;
uniform float strength = 1.0;
// The veil's camera distance: full below x metres, gone beyond y.
uniform vec2 near_fade = vec2(7.0, 16.0);
varying vec3 world_pos;

void vertex() {
	world_pos = (MODEL_MATRIX * vec4(VERTEX, 1.0)).xyz;
}

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
		float graze = pow(max(1.0 - abs(dot(normalize(NORMAL), normalize(VIEW))), 0.0), 1.5);
		float near = 1.0 - smoothstep(near_fade.x, near_fade.y, distance(world_pos, CAMERA_POSITION_WORLD));
		float a = pow(1.0 - up, 1.6) * 0.3 * (0.4 + graze * 0.6) * near;
		ALBEDO = max(tint.rgb * a * strength, vec3(0.0));
	}
}
