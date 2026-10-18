shader_type spatial;
render_mode unshaded, blend_add, depth_draw_never, cull_back, shadows_disabled, fog_disabled;

// Overlay on the chest model: a thin coloured fresnel rim with a slow wave
// running over it. Barely there on a plain chest; on an enchanted one it is
// the violet aura that tells you something magical is inside.
instance uniform vec4 tint : source_color = vec4(1.0, 0.8, 0.35, 1.0);
instance uniform float strength = 0.3;

varying vec3 local_pos;

void vertex() {
	local_pos = VERTEX;
}

void fragment() {
	float f = pow(1.0 - clamp(dot(NORMAL, VIEW), 0.0, 1.0), 3.0);
	float wave = 0.65 + 0.35 * sin(local_pos.y * 9.0 - TIME * 2.4);
	ALBEDO = tint.rgb;
	ALPHA = clamp(f * wave * strength, 0.0, 1.0);
}
