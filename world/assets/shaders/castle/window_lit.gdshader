shader_type spatial;
// The castle's windows seen from the grounds (castle_exterior.gd "glass"):
// diamond leaded glass that mirrors the sky by day, with candle-warm rooms
// behind some of the panes. Which windows are lit, and how warmly, comes from
// the per-window random ArchKit.window() writes in the vertex colour, so the
// facade never reads as a grid of identical orange slabs.
render_mode cull_back, shadows_disabled;

uniform vec3 sky_colour : source_color = vec3(0.55, 0.64, 0.76);
uniform vec3 warm : source_color = vec3(1.0, 0.62, 0.28);
uniform float lit_fraction = 0.55;
uniform float glow = 2.2;
uniform float quarry_m = 0.32;

varying vec3 world_pos;
varying vec3 world_normal;
varying vec2 pick;

void vertex() {
	pick = COLOR.rg;
	world_pos = (MODEL_MATRIX * vec4(VERTEX, 1.0)).xyz;
	world_normal = normalize((MODEL_MATRIX * vec4(NORMAL, 0.0)).xyz);
}

float h(vec2 p) { return fract(sin(dot(p, vec2(127.1, 311.7))) * 43758.5453); }

void fragment() {
	vec3 n = normalize(world_normal);
	// along-the-wall coordinate for any facing
	vec3 side = normalize(cross(vec3(0.0, 1.0, 0.0), n) + vec3(1e-4));
	vec2 p = vec2(dot(world_pos, side), world_pos.y) / quarry_m;
	vec2 r = vec2(p.x + p.y * 0.62, p.x - p.y * 0.62);
	vec2 f = abs(fract(r) - 0.5);
	float lead = smoothstep(0.40, 0.47, max(f.x, f.y));
	float roll = pick.r;
	float lit = step(roll, lit_fraction);
	float warmth = 0.45 + 0.55 * pick.g;
	float flicker = 0.9 + 0.1 * sin(TIME * (2.0 + roll * 3.0) + roll * 40.0);
	float fres = pow(1.0 - clamp(dot(n, normalize(VIEW)), 0.0, 1.0), 3.0);
	ALBEDO = mix(vec3(0.03, 0.035, 0.045), vec3(0.02), lead);
	ROUGHNESS = mix(0.08, 0.6, lead);
	METALLIC = 0.4 * (1.0 - lead);
	SPECULAR = 0.8;
	vec3 room = warm * glow * warmth * flicker * lit * (1.0 - lead);
	// unlit panes still pick up a cool sky sheen
	EMISSION = room + sky_colour * (0.06 + fres * 0.35) * (1.0 - lead) * (1.0 - lit * 0.7);
}
