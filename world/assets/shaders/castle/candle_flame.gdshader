shader_type spatial;
// Flame card of a candle (MultiMesh or single, camera-facing, additive). Same
// bob as floating_candle.gdshader. A small teardrop drawn in the middle of the
// card - blue at the wick, a white-hot core, a yellow body and an orange rim -
// whose tip sways on its own breath, inside a faint warm halo that fills the
// rest of the card.
render_mode unshaded, blend_add, depth_draw_never, cull_disabled, shadows_disabled, fog_disabled;

uniform float bob_height = 0.18;
uniform float bob_speed = 0.7;
uniform float intensity = 2.6;
// Colour of the flame (white = natural); the cauldron burners are green.
uniform vec3 tint : source_color = vec3(1.0, 1.0, 1.0);

varying float v_flicker;
varying float v_phase;

float hash13(vec3 p) {
	p = fract(p * 0.1031);
	p += dot(p, p.zyx + 31.32);
	return fract((p.x + p.y) * p.z);
}

void vertex() {
	vec3 anchor = MODEL_MATRIX[3].xyz;
	v_phase = fract(INSTANCE_CUSTOM.x + hash13(floor(anchor * 13.0))) * 6.2831;
	float bob = sin(TIME * bob_speed + INSTANCE_CUSTOM.x * 6.2831) * bob_height;
	v_flicker = 0.9 + 0.1 * sin(TIME * 9.0 + v_phase * 7.0) * sin(TIME * 4.3 + v_phase * 3.0);
	// Billboard about the instance origin, after the bob.
	vec3 origin = (MODEL_MATRIX * vec4(0.0, bob, 0.0, 1.0)).xyz;
	vec3 right = INV_VIEW_MATRIX[0].xyz;
	vec3 up = vec3(0.0, 1.0, 0.0);
	vec3 world = origin + right * VERTEX.x * 1.6 + up * VERTEX.y * (0.96 + 0.08 * v_flicker);
	POSITION = PROJECTION_MATRIX * VIEW_MATRIX * vec4(world, 1.0);
}

void fragment() {
	// y up, -1 (bottom) .. 1 (top); the card is 1.6 x wider than authored so
	// the halo has room, the flame keeps its old width.
	vec2 p = vec2((UV.x * 2.0 - 1.0) * 1.6, 1.0 - UV.y * 2.0);
	float h = clamp((p.y + 0.62) / 1.5, 0.0, 1.0);       // 0 at the wick, 1 at the tip
	float sway = sin(TIME * 2.3 + v_phase) * 0.6 + sin(TIME * 5.9 + v_phase * 2.3) * 0.4;
	p.x -= sway * 0.07 * h * h;
	// teardrop: round at the bottom, drawn to a point at the top
	float w = mix(0.36, 0.035, pow(h, 1.25));
	float d = length(vec2(p.x / w, (p.y + 0.12) / 0.78));
	float body = smoothstep(1.0, 0.55, d);
	float core = smoothstep(0.55, 0.0, length(vec2(p.x / (w * 0.55), (p.y + 0.28) / 0.42)));
	float wick = smoothstep(0.3, 0.0, length(vec2(p.x / 0.16, (p.y + 0.62) / 0.16)));
	vec3 rim = vec3(1.0, 0.36, 0.08);
	vec3 mid = vec3(1.0, 0.72, 0.3);
	vec3 hot = vec3(1.0, 0.96, 0.86);
	vec3 col = mix(rim, mid, body) * body;
	col = mix(col, hot * 1.4, core);
	col += vec3(0.2, 0.35, 1.0) * wick * 0.6;
	// a soft warm halo around the whole flame
	float halo = exp(-length(vec2(p.x * 1.4, (p.y + 0.15) * 0.9)) * 3.2) * 0.22;
	col += vec3(1.0, 0.55, 0.22) * halo;
	if (distance(tint, vec3(1.0)) > 0.001) {
		float lum = dot(col, vec3(0.3, 0.59, 0.11));
		col = tint * lum * 1.4 + vec3(lum * core * 0.4);
	}
	ALBEDO = col * intensity * 0.55 * v_flicker;
}
