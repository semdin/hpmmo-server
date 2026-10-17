shader_type spatial;
render_mode unshaded, blend_mix, depth_draw_never, cull_disabled, shadows_disabled;

// The selection ring under the current target: a glowing band with three
// spiral arms sweeping round it, a bright rim and a dark halo just outside it
// so it reads on light stone as well as on grass.
uniform vec4 tint : source_color = vec4(1.0, 0.78, 0.32, 1.0);
uniform float speed = 1.6;

void fragment() {
	vec2 p = UV * 2.0 - 1.0;
	float r = length(p);
	float a = atan(p.y, p.x);
	float band = smoothstep(0.95, 0.84, r) * smoothstep(0.5, 0.68, r);
	float arms = pow(0.5 + 0.5 * sin(a * 3.0 + r * 9.0 - TIME * speed * 3.0), 2.0);
	float rim = smoothstep(0.045, 0.0, abs(r - 0.88));
	float glow = clamp(band * (0.3 + 0.7 * arms) + rim, 0.0, 1.0);
	float halo = smoothstep(1.0, 0.92, r) * smoothstep(0.86, 0.92, r) * 0.45;
	ALBEDO = mix(vec3(0.02, 0.015, 0.0), tint.rgb * 1.35, glow / max(glow + halo, 0.001));
	ALPHA = clamp(glow * 0.95 + halo, 0.0, 1.0) * tint.a;
}
