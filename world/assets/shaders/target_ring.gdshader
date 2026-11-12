shader_type spatial;
render_mode unshaded, blend_premul_alpha, depth_draw_never, depth_test_disabled, cull_front, shadows_disabled, fog_disabled;

// The mark under the current target: a ring of energy on the ground. A thin
// hot core, light that spills to both sides of it, and the cloud map the
// spell effects burn with run round it in two layers against each other -
// so the ring wavers, throws tongues inward and never holds still. No drawn
// shapes: the first version was a reticle of ruled lines and arrowheads, an
// interface mark laid on the grass. `snap` runs 1 -> 0 when a target is
// taken: the ring closes in on it from wide, bright.
//
// Projected like the boss warning (ground_telegraph.gdshader): the mesh is a
// box round the target's feet, and the ring is drawn on whatever ground shows
// through it, so it lies on a slope instead of cutting into it.
// Premultiplied blend: light added, with a little shade under it so it holds
// on pale stone.

uniform sampler2D depth_texture : hint_depth_texture, repeat_disable, filter_nearest;
uniform sampler2D noise : repeat_enable, filter_linear_mipmap, hint_default_white;
uniform vec4 tint : source_color = vec4(1.0, 0.78, 0.32, 1.0);
uniform float radius = 1.2;       // metres: the ring's radius
uniform float half_height = 0.7;  // metres above and below the feet the mark may fall
uniform float snap = 0.0;

void fragment() {
	float depth_raw = texture(depth_texture, SCREEN_UV).r;
	vec4 view_pos = INV_PROJECTION_MATRIX * vec4(SCREEN_UV * 2.0 - 1.0, depth_raw, 1.0);
	view_pos.xyz /= view_pos.w;
	vec3 world = (INV_VIEW_MATRIX * vec4(view_pos.xyz, 1.0)).xyz;
	vec3 local = world - MODEL_MATRIX[3].xyz;
	vec3 facing = normalize(cross(dFdx(world), dFdy(world)));
	float ground = smoothstep(0.45, 0.75, abs(facing.y))
		* (1.0 - smoothstep(half_height * 0.7, half_height, abs(local.y)));

	float grow = 1.0 + 0.42 * snap * snap;
	float r = length(local.xz) / grow;
	float around = atan(local.z, local.x) / TAU;   // -0.5 .. 0.5 round the ring
	float t = TIME;
	// The cloud map wrapped round the ring (whole turns, so it meets itself)
	// at a fixed level of detail: the wrap would otherwise draw a seam.
	float along = r / radius;
	float n1 = textureLod(noise, vec2(around * 3.0 + t * 0.10, along * 0.8 - t * 0.05), 1.0).r;
	float n2 = textureLod(noise, vec2(around * 7.0 - t * 0.16, along * 1.9 + t * 0.07), 1.0).r;
	float flow = n1 * 0.6 + n2 * 0.4;

	// The ring wavers with the flow.
	float off = r - radius * (1.0 + (flow - 0.5) * 0.05);
	float width = radius * 0.016 + 0.012;
	float core = exp(-(off * off) / (width * width));
	float spill = exp(-abs(off) / (radius * 0.10)) * (0.3 + 0.7 * flow);
	// Tongues of it reaching in toward the target where the flow runs strong.
	float tongues = smoothstep(0.55, 0.9, flow) * exp(-max(-off, 0.0) / (radius * 0.24)) * step(off, 0.0);
	float haze = smoothstep(radius, radius * 0.35, r) * step(r, radius) * 0.05 * (0.4 + flow);

	float heat = (core * (0.8 + 0.2 * n2) + spill * 0.55 + tongues * 0.38 + haze) * (1.0 + 1.3 * snap);
	vec3 deep = tint.rgb * tint.rgb * 0.8;
	vec3 hot = mix(tint.rgb, vec3(1.0, 0.95, 0.8), 0.6);
	float h = clamp(heat, 0.0, 1.0);
	vec3 light = mix(deep, tint.rgb, smoothstep(0.0, 0.4, h));
	light = mix(light, hot, smoothstep(0.4, 1.0, h));

	float shade = exp(-abs(off) / (radius * 0.2)) * 0.28;
	float k = tint.a * ground * (1.0 - 0.3 * snap);
	ALBEDO = light * min(heat, 1.0) * k;
	ALPHA = shade * k;
}
