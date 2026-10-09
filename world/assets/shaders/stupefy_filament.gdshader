shader_type spatial;
render_mode unshaded, blend_add, cull_disabled, depth_draw_never, shadows_disabled;

uniform float opacity = 1.0;
uniform float clock = 0.0;
varying vec4 strand_color;

void vertex() {
	strand_color = COLOR;
}

void fragment() {
	float cross_section = abs(UV.y * 2.0 - 1.0);
	float halo = exp(-cross_section * cross_section * 5.0);
	float hot = exp(-cross_section * cross_section * 85.0);
	float flow = 0.78 + 0.22 * sin(UV.x * 34.0 - clock * 36.0);
	ALBEDO = strand_color.rgb * (1.4 + hot * 1.3);
	ALPHA = (halo * 0.45 + hot * 0.55) * strand_color.a * opacity * flow;
}
