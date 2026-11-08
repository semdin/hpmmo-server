shader_type spatial;
// The courtyard fountain's falling streams (FountainWater; the pools are
// fountain_pool.gdshader): streaks running down the ribbon (UV.y = 0 at the
// lip), thinning and breaking up towards the bottom.
// Procedural noise only (no textures), cheap enough for the low preset.
render_mode blend_mix, depth_draw_never, cull_disabled, shadows_disabled;

uniform vec4 deep : source_color = vec4(0.18, 0.42, 0.55, 0.62);
uniform vec4 foam : source_color = vec4(0.86, 0.95, 1.0, 0.9);
uniform float flow_speed = 2.2;

float hash(vec2 p) {
	return fract(sin(dot(p, vec2(127.1, 311.7))) * 43758.5453);
}

float vnoise(vec2 p) {
	vec2 i = floor(p);
	vec2 f = fract(p);
	vec2 u = f * f * (3.0 - 2.0 * f);
	return mix(mix(hash(i), hash(i + vec2(1.0, 0.0)), u.x),
		mix(hash(i + vec2(0.0, 1.0)), hash(i + vec2(1.0, 1.0)), u.x), u.y);
}

void fragment() {
	float t = TIME * flow_speed;
	// streaks: noise stretched along the fall, scrolling down
	float s = vnoise(vec2(UV.x * 9.0, UV.y * 2.5 - t))
		* vnoise(vec2(UV.x * 17.0 + 3.1, UV.y * 4.0 - t * 1.3));
	float body = smoothstep(0.0, 0.25, UV.x) * smoothstep(1.0, 0.75, UV.x);
	float breakup = mix(1.0, smoothstep(0.15, 0.6, s + 0.25), smoothstep(0.35, 1.0, UV.y));
	ALBEDO = mix(deep.rgb * 1.6, foam.rgb, clamp(s * 2.0, 0.0, 1.0));
	EMISSION = foam.rgb * s * 0.35;
	ROUGHNESS = 0.1;
	SPECULAR = 0.8;
	ALPHA = clamp((0.5 + s * 1.1) * body * breakup, 0.0, 1.0) * foam.a;
}
