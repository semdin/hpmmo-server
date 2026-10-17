shader_type spatial;
// The floor threshold in front of a staircase gate: a rune strip with chevrons
// that run toward the flight while it may be boarded, and lie dim and still
// (in the sealed colour) while it may not.
render_mode unshaded, blend_add, cull_disabled, depth_draw_never, shadows_disabled, fog_disabled;

uniform sampler2D rune : source_color, repeat_enable, filter_linear_mipmap;
uniform vec4 tint : source_color = vec4(1.0, 0.75, 0.35, 1.0);
uniform float open = 0.0;
uniform float width_m = 3.0;

void fragment() {
	// UV.y = 0 at the gate edge, 1 away from the flight
	float edge = smoothstep(0.0, 0.12, UV.x) * smoothstep(1.0, 0.88, UV.x);
	float runes = texture(rune, vec2(UV.x * width_m / 2.6, UV.y)).r;
	float chev_v = fract(UV.y * 3.0 + abs(UV.x - 0.5) * 1.6 + TIME * 0.9 * open);
	float chevron = smoothstep(0.0, 0.08, chev_v) * smoothstep(0.24, 0.14, chev_v);
	float fade = smoothstep(1.0, 0.55, UV.y);
	float a = (runes * (0.25 + 0.55 * open) + chevron * open * 0.7 + 0.06) * edge * fade;
	ALBEDO = tint.rgb * a * 1.5;
}
