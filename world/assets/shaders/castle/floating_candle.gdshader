shader_type spatial;
// Wax body of a floating candle (MultiMesh). Each instance bobs on its own
// phase (INSTANCE_CUSTOM.x), the flame shader uses the same formula so the
// flame stays on its wick. docs/castle-interior.md, F3.

uniform vec3 wax : source_color = vec3(0.93, 0.89, 0.78);
uniform float bob_height = 0.18;
uniform float bob_speed = 0.7;

varying float v_glow;

void vertex() {
	float phase = INSTANCE_CUSTOM.x * 6.2831;
	VERTEX.y += sin(TIME * bob_speed + phase) * bob_height;
	// warmer, translucent-looking wax toward the lit top
	v_glow = clamp(VERTEX.y / 0.35 + 0.5, 0.0, 1.0);
}

void fragment() {
	ALBEDO = wax;
	ROUGHNESS = 0.55;
	EMISSION = vec3(1.0, 0.62, 0.3) * v_glow * v_glow * 0.35;
}
