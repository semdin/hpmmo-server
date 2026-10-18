shader_type spatial;
render_mode unshaded, blend_add, depth_draw_never, cull_disabled, shadows_disabled, fog_disabled;

// A faint shaft of light rising from a loot chest: a camera-facing (Y-locked)
// quad, brightest at the chest and fading upward, with slow rising streaks so
// it shimmers instead of reading as a flat card. Colour/strength per chest.
instance uniform vec4 tint : source_color = vec4(1.0, 0.8, 0.35, 1.0);
instance uniform float strength = 1.0;

void vertex() {
	// Cylindrical billboard that keeps the node's scale (despawn shrinks it).
	vec3 up = vec3(0.0, 1.0, 0.0);
	vec3 side = normalize(cross(up, INV_VIEW_MATRIX[2].xyz));
	vec3 fwd = normalize(cross(side, up));
	mat4 bb = mat4(vec4(side * length(MODEL_MATRIX[0].xyz), 0.0),
		vec4(up * length(MODEL_MATRIX[1].xyz), 0.0),
		vec4(fwd * length(MODEL_MATRIX[2].xyz), 0.0), MODEL_MATRIX[3]);
	MODELVIEW_MATRIX = VIEW_MATRIX * bb;
}

void fragment() {
	float x = abs(UV.x - 0.5) * 2.0;
	float across = pow(clamp(1.0 - x, 0.0, 1.0), 2.2);
	// UV.y: 0 at the top, 1 at the chest. Soft at both ends.
	float along = pow(UV.y, 1.8) * smoothstep(1.0, 0.9, UV.y);
	float streak = 0.7 + 0.3 * sin(UV.x * 23.0 + sin(UV.y * 5.0 - TIME * 0.7) * 2.0);
	float rise = 0.8 + 0.2 * sin(UV.y * 14.0 - TIME * 2.2);
	ALBEDO = tint.rgb;
	ALPHA = clamp(across * along * streak * rise * strength * 0.55, 0.0, 1.0);
}
