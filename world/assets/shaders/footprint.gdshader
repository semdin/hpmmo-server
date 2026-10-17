shader_type spatial;
// Marauder's-Map footprints for the map waypoint (scripts/world/waypoint_guide.gd).
// One quad per print, lying on the ground, UV.y = 0 at the toe. An invisible
// walker strides along the route (the script moves it); INSTANCE_CUSTOM.x is how
// many steps ago it passed this print, so each print inks in as the walker
// reaches it and fades away behind it.
render_mode unshaded, blend_mix, cull_disabled, depth_draw_never, shadows_disabled;

uniform vec4 ink : source_color = vec4(1.0, 0.82, 0.42, 1.0);
uniform float trail = 9.0;        // prints visible behind the walker
uniform float opacity = 1.0;

varying float step_no;

void vertex() {
	step_no = INSTANCE_CUSTOM.x;
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
	float since = step_no;
	float vis = smoothstep(0.0, 0.35, since) * (1.0 - smoothstep(trail * 0.5, trail, since));
	ALBEDO = ink.rgb * (1.2 + 0.3 * grain);
	ALPHA = shape * vis * grain * opacity * 0.9;
}
