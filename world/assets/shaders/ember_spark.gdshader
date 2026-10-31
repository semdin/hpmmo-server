shader_type spatial;
// Draw pass of an `embers` particle layer (ember_particles.gdshader sets each
// particle's basis: X length = its radius, Y = its velocity streak). Each spark
// is a soft capsule along its flight turned to the camera: a white-hot centre
// in its ramp colour with a faint glow, a streak while it flies and a dot once
// it rests. Never thinner than about a pixel, with its light spread to match,
// so a distant spark dims instead of shimmering in and out.
// Premultiplied blend: light added on a dark ground, and over a bright floor
// or sky the spark's own colour covers what is behind it - additive alone
// turned red sparks into white flecks in daylight.
render_mode unshaded, blend_premul_alpha, cull_disabled, depth_draw_never, shadows_disabled;

varying vec2 v_metres;
varying float v_radius;
varying float v_half;
varying float v_dim;
varying vec4 v_colour;

void vertex() {
	vec3 centre = MODEL_MATRIX[3].xyz;
	float radius = length(MODEL_MATRIX[0].xyz);
	vec3 along_v = MODEL_MATRIX[1].xyz;
	float streak = length(along_v);
	vec3 along = streak > 0.00001 ? along_v / streak : vec3(0.0, 1.0, 0.0);
	vec3 to_camera = normalize(CAMERA_POSITION_WORLD - centre);
	vec3 across = cross(along, to_camera);
	across = length(across) > 0.0001 ? normalize(across) : vec3(1.0, 0.0, 0.0);
	float dist = length(CAMERA_POSITION_WORLD - centre);
	float pixel = dist * 2.0 / (PROJECTION_MATRIX[1][1] * VIEWPORT_SIZE.y);
	float drawn = max(radius, pixel * 0.9);
	v_dim = clamp(radius / drawn, 0.25, 1.0);
	v_radius = drawn;
	v_half = max(0.0, streak - radius) * 0.5;
	float hx = drawn * 3.0;
	float hy = v_half + drawn * 3.0;
	v_metres = vec2(VERTEX.x * 2.0 * hx, VERTEX.y * 2.0 * hy);
	vec3 world = centre + across * v_metres.x + along * v_metres.y;
	POSITION = PROJECTION_MATRIX * VIEW_MATRIX * vec4(world, 1.0);
	v_colour = COLOR;
}

void fragment() {
	float d = length(vec2(v_metres.x, max(abs(v_metres.y) - v_half, 0.0))) / v_radius;
	float core = exp(-d * d * 2.2);
	float glow = exp(-d * 1.4) * 0.22;
	// a streak spreads the same light over its length
	float spread = v_radius / (v_radius + v_half * 0.6);
	float light = (core + glow) * v_colour.a * v_dim * mix(1.0, spread, 0.6);
	vec3 hot = v_colour.rgb * 2.4 + vec3(core * 0.35) * min(1.0, v_colour.a * 1.5);
	ALBEDO = hot * light;
	// only the spark's core covers the background; its glow stays pure light
	ALPHA = clamp(core * v_colour.a * v_dim * 0.85, 0.0, 1.0);
}
