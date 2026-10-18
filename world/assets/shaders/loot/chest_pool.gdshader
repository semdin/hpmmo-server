shader_type spatial;
render_mode unshaded, blend_add, depth_draw_never, cull_disabled, shadows_disabled, fog_disabled;

// The soft pool of light on the ground under a loot chest: a smooth radial
// falloff (no hard edge) with a faint slow swirl, breathing with `strength`.
instance uniform vec4 tint : source_color = vec4(1.0, 0.8, 0.35, 1.0);
instance uniform float strength = 1.0;

void fragment() {
	vec2 p = UV * 2.0 - 1.0;
	float r = length(p);
	float a = atan(p.y, p.x);
	float fall = pow(clamp(1.0 - r, 0.0, 1.0), 2.4);
	float swirl = 0.85 + 0.15 * sin(a * 5.0 + r * 6.0 - TIME * 0.9);
	ALBEDO = tint.rgb;
	ALPHA = clamp(fall * swirl * strength * 0.85, 0.0, 1.0);
}
