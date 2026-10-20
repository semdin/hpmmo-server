shader_type spatial;
// Marauder's-Map footprints for the map waypoint (scripts/world/waypoint_guide.gd).
// One quad per print, lying on the ground, UV.y = 0 at the toe. The prints
// from the player's feet along the next stretch of the route always show;
// INSTANCE_CUSTOM.x is how many steps ago a glow rippling forward passed this
// print (it brightens as the glow goes by), .y how far along the stretch it is
// (the far end fades out), .z its distance from the feet in steps (fades in).
render_mode unshaded, blend_mix, cull_disabled, depth_draw_never, shadows_disabled;

uniform vec4 ink : source_color = vec4(1.0, 0.82, 0.42, 1.0);
uniform float trail = 9.0;        // prints the ripple lights at once
uniform float base = 0.5;         // brightness of a print the ripple is not on
uniform float opacity = 1.0;

varying vec3 step_info;

void vertex() {
	step_info = INSTANCE_CUSTOM.xyz;
}

float ellipse(vec2 p, vec2 c, vec2 r) {
	vec2 d = (p - c) / r;
	return 1.0 - smoothstep(0.82, 1.0, dot(d, d));
}

void fragment() {
	vec2 p = UV;
	// a shoe print: the sole, the heel and a gap between them
	float sole = ellipse(p, vec2(0.5, 0.32), vec2(0.36, 0.3));
	float heel = ellipse(p, vec2(0.5, 0.78), vec2(0.27, 0.19));
	float shape = max(sole, heel);
	// a little ink texture inside the print
	float grain = 0.75 + 0.25 * fract(sin(dot(floor(p * 18.0), vec2(12.9898, 78.233))) * 43758.5453);
	float since = step_info.x;
	float glow = smoothstep(0.0, 0.6, since) * (1.0 - smoothstep(trail * 0.4, trail, since));
	float ends = smoothstep(0.2, 1.4, step_info.z) * (1.0 - smoothstep(0.7, 1.0, step_info.y));
	ALBEDO = ink.rgb * (1.1 + 0.3 * grain + 0.5 * glow);
	ALPHA = shape * grain * opacity * 0.9 * ends * mix(base, 1.0, glow);
}
