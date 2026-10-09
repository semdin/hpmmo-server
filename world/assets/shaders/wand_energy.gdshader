shader_type spatial;
render_mode unshaded, blend_add, cull_disabled, depth_draw_never, shadows_disabled;

// Analytic light: no opaque carrier and no rectangular texture borders.
uniform vec4 tint : source_color = vec4(1.0, 0.6, 0.15, 1.0);
uniform float opacity = 1.0;
uniform float phase = 0.0;
uniform int shape = 0; // glow, directional bolt, expanding shock ring, flash
uniform vec3 aim = vec3(0.0, 0.0, -1.0);

void vertex() {
	vec3 right = INV_VIEW_MATRIX[0].xyz;
	vec3 up = INV_VIEW_MATRIX[1].xyz;
	vec3 forward = INV_VIEW_MATRIX[2].xyz;
	if (shape == 1) {
		vec3 projected = aim - forward * dot(aim, forward);
		if (length(projected) > 0.01) {
			right = normalize(projected);
			up = normalize(cross(forward, right));
		}
	}
	MODELVIEW_MATRIX = VIEW_MATRIX * mat4(
		vec4(right * length(MODEL_MATRIX[0].xyz), 0.0),
		vec4(up * length(MODEL_MATRIX[1].xyz), 0.0),
		vec4(forward, 0.0), MODEL_MATRIX[3]);
}

void fragment() {
	vec2 p = UV * 2.0 - 1.0;
	float r = length(p);
	float energy = exp(-r * r * 7.0);
	float core = exp(-r * r * 85.0);
	if (shape == 1) {
		// Head is at x=.55; the tapered wake reaches back along the aim.
		float width = mix(0.035, 0.24, smoothstep(-1.0, 0.55, p.x));
		float wake = exp(-pow(p.y / width, 2.0)) * smoothstep(-1.0, 0.35, p.x);
		wake *= 1.0 - smoothstep(0.52, 0.95, p.x);
		float head = exp(-dot(vec2((p.x - 0.52) * 3.0, p.y), vec2((p.x - 0.52) * 3.0, p.y)) * 23.0);
		energy = wake * 0.8 + head;
		core = head + wake * exp(-p.y * p.y * 1100.0) * 0.6;
	} else if (shape == 2) {
		float radius = mix(0.12, 0.87, phase);
		float ring = exp(-pow((r - radius) / mix(0.07, 0.025, phase), 2.0));
		float angle = atan(p.y, p.x);
		energy = ring * (0.72 + 0.28 * sin(angle * 7.0 + phase * 9.0));
		core = ring * 0.16;
	} else if (shape == 3) {
		float rays = exp(-abs(p.x * p.y) * 90.0) * pow(max(0.0, 1.0 - r), 2.0);
		energy += rays * 1.6;
		core += rays * 0.35;
	}
	float edge = 1.0 - smoothstep(0.86, 1.0, r);
	ALBEDO = tint.rgb * 1.8 + vec3(core * 1.6);
	ALPHA = clamp(energy * edge * opacity * tint.a, 0.0, 1.0);
}
