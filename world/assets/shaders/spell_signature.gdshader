shader_type spatial;
render_mode unshaded, blend_mix, cull_disabled, depth_draw_never, shadows_disabled;

uniform sampler2D flow_noise : repeat_enable, filter_linear_mipmap;
uniform vec4 tint : source_color = vec4(1.0, 0.3, 0.02, 1.0);
uniform float clock = 0.0;
uniform float phase = 0.0;
uniform float opacity = 1.0;
uniform float turn = 0.0;
uniform int form = 0; // flame, molten charge, crescent, lightning corona, ash
uniform bool burst = false;
uniform vec3 aim = vec3(0.0, 1.0, 0.0);

void vertex() {
	vec3 up = INV_VIEW_MATRIX[1].xyz;
	vec3 right = INV_VIEW_MATRIX[0].xyz;
	if (form == 0) {
		vec3 forward = INV_VIEW_MATRIX[2].xyz;
		vec3 projected = aim - forward * dot(aim, forward);
		if (length(projected) > 0.01) {
			up = normalize(projected);
			right = normalize(cross(up, forward));
		}
	}
	MODELVIEW_MATRIX = VIEW_MATRIX * mat4(
		vec4(right * length(MODEL_MATRIX[0].xyz), 0.0),
		vec4(up * length(MODEL_MATRIX[1].xyz), 0.0),
		INV_VIEW_MATRIX[2], MODEL_MATRIX[3]);
}

void fragment() {
	vec2 p = UV * 2.0 - 1.0;
	p = mat2(vec2(cos(turn), sin(turn)), vec2(-sin(turn), cos(turn))) * p;
	float r = length(p);
	float angle = atan(p.y, p.x);
	vec2 warp = texture(flow_noise, UV * 1.8 + vec2(clock * 0.17, clock * 0.3)).rg - 0.5;
	float n = texture(flow_noise, UV * 3.1 + warp * 0.5 + vec2(clock * -0.13, clock * 0.75)).b;
	float density = 0.0;
	float hot = 0.0;
	if (form == 0) {
		float height = (1.0 - p.y) * 0.5;
		float width = mix(0.62, 0.04, height);
		float tongue = abs(p.x + warp.x * 0.3 + sin(height * 9.0 - clock * 13.0) * 0.08);
		float body = 1.0 - smoothstep(width * 0.2, width + 0.12, tongue);
		density = body * smoothstep(0.0, 0.16, height) * (1.0 - smoothstep(0.65, 1.0, height + n * 0.18));
		density *= smoothstep(0.12, 0.55, n + body * 0.42);
		hot = pow(body, 4.0) * (1.0 - height) * 0.8;
	} else if (form == 1) {
		float front = burst ? mix(0.2, 0.88, pow(phase, 0.4)) : 0.55;
		float edge = r + (n - 0.5) * 0.28;
		float cracks = pow(max(0.0, sin(angle * 6.0 + n * 8.0 + clock * 4.0)), 5.0);
		density = (1.0 - smoothstep(front - 0.25, front + 0.1, edge)) * (0.6 + cracks * 0.4);
		hot = exp(-r * r * 20.0) + cracks * 0.32;
	} else if (form == 2) {
		float crescent = exp(-pow((r - 0.61) / 0.045, 2.0));
		float cut = smoothstep(-0.65, 0.7, p.x);
		density = crescent * cut + exp(-r * r * 65.0) * 0.5;
		hot = crescent * cut * 0.8;
	} else if (form == 3) {
		float bolts = pow(max(0.0, cos(angle * 7.0 + n * 8.0)), 22.0);
		float field = (1.0 - smoothstep(0.2, 0.9, r + (n - 0.5) * 0.35));
		density = bolts * field + field * 0.1;
		hot = exp(-r * r * 80.0) + bolts * 0.4;
	} else {
		density = (1.0 - smoothstep(0.2, 0.95, r + (n - 0.5) * 0.35)) * n * 0.45;
	}
	density *= 1.0 - smoothstep(0.88, 1.0, r);
	vec3 core = form == 3 ? vec3(0.65, 1.0, 0.85) : (form == 2 ? vec3(1.0, 0.78, 0.9) : vec3(1.0, 0.8, 0.3));
	ALBEDO = mix(tint.rgb, core, clamp(hot, 0.0, 1.0));
	EMISSION = form == 4 ? vec3(0.0) : tint.rgb * 0.65 + core * hot * 1.2;
	ALPHA = clamp(density * opacity * tint.a, 0.0, 0.95);
}
