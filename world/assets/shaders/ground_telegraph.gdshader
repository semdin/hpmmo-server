shader_type spatial;
render_mode unshaded, blend_premul_alpha, depth_draw_never, depth_test_disabled, cull_front, shadows_disabled, fog_disabled;

// The ground where an attack will land, burning: the exact hit area (a circle,
// or a cone from its apex) charred and seamed with fire, a line of fire on
// its boundary, and a front of fire that crawls out from the centre and
// reaches the boundary on the release tick - the gap between the front and
// the edge is how long the player has.
//
// Nothing in it is a drawn line: every edge is cloud noise (the erosion map
// the spell effects burn with) drifting in world metres, so the front is
// ragged, the seams wander and flicker, and no two warnings look the same.
// It is the ground alone that burns: no flames stand on it. (Tried and thrown
// out on the way here: ruled lines with a flat fill - a court marking; flame
// sprites standing round this ground; and a red swirl of energy with a shock
// ring for the countdown.)
//
// Projected, not laid flat: the mesh (the telegraph's own disc, a CylinderMesh
// whose radius is the authoritative one, a couple of metres tall) is only the
// volume the mark may fall in. Each pixel looks up what was drawn there, finds
// where on the ground that is, and burns it - so it lies on a slope, steps
// over a kerb and is hidden by a wall. Only surfaces that face up take it:
// not a creature's legs.
// Premultiplied blend: the fire is light added to the ground, the char is the
// ground darkened under it (additive alone washed out on pale stone).

uniform sampler2D depth_texture : hint_depth_texture, repeat_disable, filter_nearest;
uniform sampler2D noise : repeat_enable, filter_linear_mipmap, hint_default_white;
uniform vec4 tint : source_color = vec4(1.0, 0.38, 0.08, 1.0);   // the fire's body colour
uniform float radius = 5.0;       // metres: the area's radius, or a cone's reach
uniform float sector = 4.0;       // a cone's half angle in radians; 3.1 and up: the whole circle
uniform float half_height = 1.2;  // metres above and below the centre the mark may fall
uniform float progress = 0.0;     // 0 at the start tick, 1 at the release tick
uniform float flash = 0.0;        // 1 on release, fading out
uniform float shock = 0.0;        // the release's blast running out to the boundary, 0 -> 1
uniform float held = 0.0;         // 1: a lasting patch (pool, sticky ground) - no countdown
uniform float fade = 1.0;

void vertex() {
	// the volume a little wide: the boundary's glow spills outside it
	VERTEX.xz *= 1.0 + 0.7 / max(radius, 1.0);
}

// Signed distance to a pie slice opening along +y (negative inside).
float pie(vec2 q, float half_angle, float reach) {
	vec2 c = vec2(sin(half_angle), cos(half_angle));
	q.x = abs(q.x);
	float l = length(q) - reach;
	float m = length(q - c * clamp(dot(q, c), 0.0, reach));
	return max(l, m * sign(c.y * q.x - c.x * q.y));
}

void fragment() {
	// The surface behind this pixel, in the disc's own space (metres; +z is
	// the attack direction).
	float depth_raw = texture(depth_texture, SCREEN_UV).r;
	vec4 view_pos = INV_PROJECTION_MATRIX * vec4(SCREEN_UV * 2.0 - 1.0, depth_raw, 1.0);
	view_pos.xyz /= view_pos.w;
	vec3 world = (INV_VIEW_MATRIX * vec4(view_pos.xyz, 1.0)).xyz;
	vec3 local = transpose(mat3(MODEL_MATRIX)) * (world - MODEL_MATRIX[3].xyz);
	vec3 facing = normalize(cross(dFdx(world), dFdy(world)));
	float ground = smoothstep(0.45, 0.75, abs(facing.y))
		* (1.0 - smoothstep(half_height * 0.7, half_height, abs(local.y)));
	vec2 p = local.xz;

	float r = length(p);
	float d = sector < 3.1 ? pie(p, sector, radius) : r - radius;
	float aa = clamp(fwidth(d), 0.004, 0.08);
	float inside = smoothstep(aa, -aa, d);

	// Three octaves of the cloud map drifting across the ground, in metres.
	float t = TIME;
	float n1 = texture(noise, p * 0.085 + vec2(t * 0.013, -t * 0.021)).r;
	float n2 = texture(noise, p * 0.23 + vec2(-t * 0.034, t * 0.027) + n1 * 0.15).r;
	float n3 = texture(noise, p * 0.61 + vec2(t * 0.05, t * 0.043)).r;
	float cloud = n1 * 0.55 + n2 * 0.45;

	// The fire's reach: a ragged front crawling outward.
	float counting = 1.0 - held;
	float reach = mix(-0.5, radius + 0.6, progress) + (cloud - 0.5) * 1.4 * smoothstep(0.0, 0.2, progress);
	float cover = mix(smoothstep(0.25, -0.25, r - reach), 1.0, held) * inside;
	float front = exp(-abs(r - reach) * 4.2) * inside * counting
		* smoothstep(0.0, 0.06, progress) * smoothstep(1.0, 0.92, progress);

	// Burning ground behind the front: glowing seams between a cooler crust,
	// and patches that flare and sink.
	float seams = 1.0 - smoothstep(0.0, 0.065, abs(n2 - 0.5 + (n3 - 0.5) * 0.3));
	float patches = smoothstep(0.62, 0.9, cloud + (n3 - 0.5) * 0.3);
	float flicker = 0.72 + 0.28 * sin(t * 6.0 + n1 * 25.0);
	float bed = cover * (seams * 0.8 + patches * 0.55) * flicker;

	// The boundary: a line of fire, hot at its core and glowing to both sides.
	float rim_core = smoothstep(0.045 + aa, 0.045 - aa, abs(d + 0.045)) * (0.65 + 0.35 * n3);
	float rim_glow = exp(-abs(d) * mix(2.8, 5.5, step(0.0, d))) * (0.5 + 0.5 * n2);
	float urgency = 0.8 + 0.2 * sin(t * (4.0 + 14.0 * progress * counting));

	// The release: the fire flashes and a blast runs out to the boundary.
	float blast = exp(-abs(r - radius * mix(0.15, 1.05, shock)) * 2.6) * (1.0 - shock) * step(0.001, shock) * inside;

	// (strongest just behind the front: the fire has only now passed there)
	float fresh = 0.45 + 0.55 * smoothstep(reach - 2.2, reach, r);
	float heat = bed * (0.3 + 0.5 * mix(progress, 0.7, held)) * mix(fresh, 1.0, held)
		+ front * 1.1
		+ rim_glow * 0.5 * urgency + rim_core * urgency
		+ inside * 0.03 * (0.5 + n2)
		+ inside * flash * (0.25 + 0.5 * cloud) + blast * 1.2;
	// Fire's colours from the tint: a deep ember, the tint, yellow-hot.
	// (yellow before white: a hot red that only brightens turns pink)
	vec3 deep = tint.rgb * tint.rgb * 0.75;
	vec3 hot = mix(tint.rgb, vec3(1.0, 0.80, 0.40), 0.75);
	float h = clamp(heat, 0.0, 1.0);
	vec3 fire = mix(deep, tint.rgb, smoothstep(0.0, 0.45, h));
	fire = mix(fire, hot, smoothstep(0.45, 0.95, h));
	fire = mix(fire, vec3(1.0, 0.93, 0.72), smoothstep(1.0, 1.6, heat) * 0.6);

	// Char: the ground darkens under it, most where the fire has passed, with
	// a sooty edge just outside the line.
	float charred = inside * (0.14 + 0.36 * cover) * (0.6 + 0.4 * n1)
		+ (1.0 - inside) * exp(-max(d, 0.0) * 8.0) * 0.22;

	float k = fade * tint.a * ground;
	ALBEDO = fire * min(heat, 1.0) * k;
	ALPHA = clamp(charred, 0.0, 0.72) * k;
}
