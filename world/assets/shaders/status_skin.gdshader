shader_type spatial;
// What a status does to a body's skin (StatusFX overlay): one shader, one look
// per mode, laid over the body's own materials.
//   0 burn    a little soot and the fire's flickering glow on the rim
//   1 ice     a frozen shell: clear blue ice, frosted streaks, a bright rim
//   2 frost   rime creeping up from the feet to `reach` metres (slowed)
//   3 poison  a faint sickly green sheen that pulses
//   4 blood   wet dark stains running down from the wounds
// Patterns live in the body's own space (world position minus the mesh's
// origin), so they ride with the body instead of swimming over it.
render_mode blend_mix, depth_draw_never, cull_back, shadows_disabled;

uniform int mode = 0;
uniform sampler2D noise : filter_linear_mipmap, repeat_enable;
uniform float reach = 0.9;
uniform float grow = 0.0;

varying vec3 v_body;

void vertex() {
	VERTEX += NORMAL * grow;
	v_body = (MODEL_MATRIX * vec4(VERTEX, 1.0)).xyz - NODE_POSITION_WORLD;
}

float field(vec3 p) {
	float a = texture(noise, p.xz * 0.9 + vec2(p.y * 0.37, p.y * 0.21)).r;
	float b = texture(noise, p.xy * 1.7 + vec2(0.31, 0.17) + p.z * 0.29).r;
	return a * 0.6 + b * 0.4;
}

void fragment() {
	float fres = pow(1.0 - clamp(dot(NORMAL, VIEW), 0.0, 1.0), 2.5);
	float n = field(v_body * 1.4);
	if (mode == 0) {
		float flick = 0.75 + 0.25 * sin(TIME * 13.0) * sin(TIME * 7.3 + 1.0);
		ALBEDO = vec3(0.05, 0.035, 0.03);
		ROUGHNESS = 1.0;
		SPECULAR = 0.1;
		EMISSION = vec3(1.0, 0.42, 0.1) * fres * 1.1 * flick;
		ALPHA = clamp(0.16 + fres * 0.35, 0.0, 0.6);
	} else if (mode == 1) {
		float streak = smoothstep(0.55, 0.8, field(v_body * vec3(3.0, 0.8, 3.0)));
		float crack = 1.0 - smoothstep(0.0, 0.03, abs(n - 0.5));
		ALBEDO = mix(vec3(0.32, 0.6, 0.85), vec3(0.9, 0.96, 1.0), max(streak * 0.7, crack));
		ROUGHNESS = 0.05 + streak * 0.3;
		SPECULAR = 0.9;
		EMISSION = vec3(0.15, 0.4, 0.75) * fres * 1.2 + vec3(0.6, 0.8, 1.0) * crack * 0.4;
		ALPHA = clamp(0.3 + fres * 0.45 + streak * 0.18 + crack * 0.3, 0.0, 0.85);
	} else if (mode == 2) {
		float edge = reach + (n - 0.5) * 0.4;
		float cover = 1.0 - smoothstep(edge - 0.15, edge, v_body.y);
		float rime = smoothstep(0.32, 0.72, field(v_body * 3.1));
		ALBEDO = mix(vec3(0.55, 0.74, 0.9), vec3(0.92, 0.97, 1.0), rime);
		ROUGHNESS = 0.4 - rime * 0.25;
		SPECULAR = 0.7;
		EMISSION = vec3(0.12, 0.28, 0.5) * fres * 0.7;
		ALPHA = clamp(cover * (0.25 + rime * 0.45) + fres * 0.15, 0.0, 0.8);
	} else if (mode == 3) {
		float pulse = 0.6 + 0.4 * sin(TIME * 2.6);
		ALBEDO = vec3(0.12, 0.2, 0.05);
		ROUGHNESS = 0.4;
		EMISSION = vec3(0.25, 0.75, 0.1) * fres * 0.6 * pulse;
		ALPHA = clamp(0.08 + fres * 0.35 * pulse, 0.0, 0.5);
	} else {
		float run = field(vec3(v_body.x * 2.6, v_body.y * 0.55, v_body.z * 2.6) + vec3(3.1, 0.0, 1.7));
		float stain = smoothstep(0.64, 0.8, run);
		ALBEDO = vec3(0.16, 0.0, 0.01);
		ROUGHNESS = 0.12;
		SPECULAR = 0.75;
		ALPHA = stain * 0.7;
	}
}
