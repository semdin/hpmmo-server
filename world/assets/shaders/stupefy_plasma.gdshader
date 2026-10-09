shader_type spatial;
render_mode unshaded, blend_mix, cull_disabled, depth_draw_never, shadows_disabled;

// Flow-map distortion + polar erosion. The spell clock, rather than TIME,
// keeps slow motion, pause, captures and cancellation on the same timeline.
uniform sampler2D flow_noise : repeat_enable, filter_linear_mipmap;
uniform float clock = 0.0;
uniform float phase = 0.0;
uniform float opacity = 1.0;
uniform int form = 0; // storm heart, torn impact corona, wand discharge
uniform vec4 tint : source_color = vec4(1.0, 0.015, 0.06, 1.0);

void vertex() {
	MODELVIEW_MATRIX = VIEW_MATRIX * mat4(
		INV_VIEW_MATRIX[0] * length(MODEL_MATRIX[0].xyz),
		INV_VIEW_MATRIX[1] * length(MODEL_MATRIX[1].xyz),
		INV_VIEW_MATRIX[2], MODEL_MATRIX[3]);
}

void fragment() {
	vec2 p = UV * 2.0 - 1.0;
	float r = length(p);
	float a = atan(p.y, p.x);
	vec2 flow = texture(flow_noise, UV * 1.6 + vec2(clock * -0.4, clock * 0.21)).rg - 0.5;
	float n = texture(flow_noise, UV * 2.7 + flow * 0.38 + vec2(clock * 0.31, -clock * 0.7)).b;
	float torn_r = r + (n - 0.5) * 0.22;
	float density = 0.0;
	float hot = 0.0;
	if (form == 0) {
		float spiral = sin(a * 3.0 - r * 22.0 + clock * 17.0 + n * 4.0);
		float veins = pow(max(0.0, spiral), 7.0);
		density = (veins * 0.7 + 0.18) * (1.0 - smoothstep(0.12, 0.93, torn_r));
		hot = exp(-r * r * 105.0) * 0.95;
		density += hot;
	} else if (form == 1) {
		float front = mix(0.12, 0.79, pow(phase, 0.48));
		float fragments = sin(a * 9.0 + n * 6.0 - clock * 5.0);
		float ridge = exp(-pow((torn_r - front) / 0.12, 2.0));
		float shards = pow(max(0.0, sin(a * 17.0 + n * 2.0)), 14.0);
		density = ridge * smoothstep(-0.55, 0.5, fragments);
		density += shards * smoothstep(0.05, 0.2, r) * (1.0 - smoothstep(front, front + 0.17, r)) * (1.0 - phase);
		hot = exp(-r * r * 40.0) * (1.0 - smoothstep(0.0, 0.3, phase));
		density += hot;
	} else {
		float whirl = pow(max(0.0, sin(a * 4.0 + r * 17.0 - clock * 24.0 + n * 3.0)), 9.0);
		density = whirl * (1.0 - smoothstep(0.1, 0.9, torn_r));
		hot = exp(-r * r * 65.0);
		density += hot;
	}
	float border = 1.0 - smoothstep(0.78, 1.0, r);
	ALBEDO = mix(tint.rgb, vec3(1.0, 0.6, 0.4), clamp(hot, 0.0, 1.0));
	EMISSION = tint.rgb * 0.7 + vec3(1.4, 0.6, 0.3) * hot;
	ALPHA = clamp(density * border * opacity, 0.0, 1.0);
}
