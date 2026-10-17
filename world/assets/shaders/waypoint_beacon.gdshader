shader_type spatial;
// The map waypoint's beacon: a tall column of gold light over the target,
// brightest at its foot, with rings rising through it. Also used (flat=true)
// for the air route's floating chevrons.
render_mode unshaded, blend_add, cull_disabled, depth_draw_never, shadows_disabled, fog_disabled;

uniform vec4 tint : source_color = vec4(1.0, 0.78, 0.38, 1.0);
uniform bool chevron = false;
uniform float strength = 1.0;

void fragment() {
	if (chevron) {
		// a ">" pointing along +UV.y (toward the target), with soft edges
		vec2 p = UV - vec2(0.5);
		float v = abs(p.x) * 0.9 + p.y;
		float band = smoothstep(0.0, 0.06, v + 0.1) * (1.0 - smoothstep(0.1, 0.18, v + 0.1));
		float fade = 1.0 - smoothstep(0.38, 0.5, abs(p.x));
		ALBEDO = tint.rgb * band * fade * 1.8 * strength;
	} else {
		float up = 1.0 - UV.y;
		float side = pow(sin(UV.x * 3.14159), 3.0) * 0.25 + 0.05;
		float rings = pow(fract(up * 12.0 - TIME * 0.6), 18.0) * 0.6;
		float fall = exp(-up * 3.0);
		ALBEDO = tint.rgb * (side + rings * fall + fall * 0.6) * (1.0 - up) * strength;
	}
}
