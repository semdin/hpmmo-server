shader_type spatial;
// The castle's clear windows seen from inside (castle_blockout.gd "glass"): the
// highland vista beyond, looked up by view direction so it shifts with the
// camera like a real distant landscape, behind diamond leaded quarries with a
// little old-glass wobble. Unshaded: the view is the window's own light.
render_mode unshaded, cull_disabled, fog_disabled, shadows_disabled;

// 3:1 panorama; its width covers 180 degrees of yaw (mirrored for the other
// half), so its height covers 60 degrees of pitch with the horizon centred.
uniform sampler2D vista : source_color, filter_linear_mipmap, repeat_enable;
uniform float energy = 1.0;
uniform vec3 glass_tint : source_color = vec3(0.92, 0.96, 1.0);
uniform vec3 lead_colour : source_color = vec3(0.025, 0.022, 0.02);
uniform vec2 quarries = vec2(6.0, 13.0);
uniform float lite = 0.0;

varying vec3 world_pos;

void vertex() {
	world_pos = (MODEL_MATRIX * vec4(VERTEX, 1.0)).xyz;
}

float h(vec2 p) { return fract(sin(dot(p, vec2(127.1, 311.7))) * 43758.5453); }

void fragment() {
	// diamond quarries in the window's own UV
	vec2 q = UV * quarries;
	vec2 r = vec2(q.x + q.y, q.x - q.y);
	vec2 cell = floor(r);
	vec2 f = abs(fract(r) - 0.5);
	float lead = smoothstep(0.43, 0.48, max(f.x, f.y));
	// each quarry is a slightly different piece of glass: a small tilt of the view
	vec2 tilt = (vec2(h(cell), h(cell + 17.0)) - 0.5) * 0.012 * (1.0 - lite);
	vec3 d = normalize(world_pos - CAMERA_POSITION_WORLD);
	float yaw = atan(d.x, -d.z);                   // 0 = north
	float u = yaw / PI + 1.0;                       // 0..2
	u = 1.0 - abs(1.0 - u);                         // mirrored 0..1..0
	float pitch = asin(clamp(d.y, -1.0, 1.0));
	float v = 0.5 - pitch / radians(60.0);
	vec3 view = texture(vista, vec2(u, clamp(v, 0.004, 0.996)) + tilt).rgb;
	// a faint sheen toward the quarry edges
	float sheen = pow(max(f.x, f.y) * 2.0, 6.0) * 0.08;
	vec3 col = view * glass_tint * energy + sheen;
	ALBEDO = mix(col, lead_colour, lead);
}
