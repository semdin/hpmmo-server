shader_type spatial;
// Flame card of a floating candle (MultiMesh, camera-facing, additive). Same
// bob as floating_candle.gdshader, plus a flicker in size and brightness.
render_mode unshaded, blend_add, depth_draw_never, cull_disabled, shadows_disabled, fog_disabled;

uniform float bob_height = 0.18;
uniform float bob_speed = 0.7;
uniform float intensity = 2.6;
// Colour of the flame (white = natural); the cauldron burners are green.
uniform vec3 tint : source_color = vec3(1.0, 1.0, 1.0);

varying float v_flicker;

void vertex() {
	float phase = INSTANCE_CUSTOM.x * 6.2831;
	float bob = sin(TIME * bob_speed + phase) * bob_height;
	v_flicker = 0.82 + 0.18 * sin(TIME * 11.0 + phase * 7.0) * sin(TIME * 7.3 + phase * 3.0);
	// Billboard about the instance origin, after the bob.
	vec3 origin = (MODEL_MATRIX * vec4(0.0, bob, 0.0, 1.0)).xyz;
	vec3 right = INV_VIEW_MATRIX[0].xyz;
	vec3 up = vec3(0.0, 1.0, 0.0);
	vec3 world = origin + right * VERTEX.x * v_flicker + up * VERTEX.y * (0.85 + 0.3 * v_flicker);
	POSITION = PROJECTION_MATRIX * VIEW_MATRIX * vec4(world, 1.0);
}

void fragment() {
	vec2 uv = UV * 2.0 - 1.0;
	// teardrop: narrower toward the tip
	float w = mix(1.0, 0.25, clamp(UV.y * -1.0 + 1.0, 0.0, 1.0));
	float d = length(vec2(uv.x / max(w, 0.05), uv.y * 0.9));
	float core = smoothstep(1.0, 0.0, d);
	vec3 col = mix(vec3(1.0, 0.45, 0.12), vec3(1.0, 0.92, 0.7), core * core);
	col = mix(col, tint * (0.6 + 0.6 * core), step(0.001, distance(tint, vec3(1.0))));
	ALBEDO = col * core * intensity * v_flicker;
}
