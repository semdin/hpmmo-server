shader_type spatial;
// A pool of the courtyard fountain (FountainWater): the water surface split off
// the model by art/grounds/scripts/split_fountain_water.py, so it has the
// basin's octagon and the bowls' outlines. Drifting ripples, rings where the
// streams land (`drops`, local xz), a soft band along the stone edge (`shape`
// 0 round / 1 octagon, `reach` metres from the centre to the inner wall),
// and the floor beneath seen through the water, bent by the ripples.
render_mode blend_mix, depth_draw_never, cull_disabled, shadows_disabled;

uniform sampler2D screen_tex : hint_screen_texture, filter_linear_mipmap;
uniform vec4 shallow : source_color = vec4(0.55, 0.75, 0.72, 1.0);
uniform vec4 deep : source_color = vec4(0.12, 0.32, 0.36, 1.0);
uniform vec4 foam : source_color = vec4(0.92, 0.97, 1.0, 1.0);
uniform float clarity = 0.5;      // 0 opaque colour .. 1 fully see-through
uniform float refraction = 0.0;   // screen-space bend of the bottom, 0 = off
uniform float ripple_scale = 3.5;
uniform float ripple_speed = 1.0;
uniform float ripple_strength = 9.0;
uniform float edge_foam = 0.4;
uniform float roughness = 0.05;
uniform float specular = 0.6;
uniform int shape = 0;
uniform float reach = 1.0;
uniform vec4 drops[4];
uniform int drop_count = 0;

varying vec3 v_local;

float hash(vec2 p) { return fract(sin(dot(p, vec2(127.1, 311.7))) * 43758.5453); }

float vnoise(vec2 p) {
	vec2 i = floor(p);
	vec2 f = fract(p);
	vec2 u = f * f * (3.0 - 2.0 * f);
	return mix(mix(hash(i), hash(i + vec2(1.0, 0.0)), u.x),
		mix(hash(i + vec2(0.0, 1.0)), hash(i + vec2(1.0, 1.0)), u.x), u.y);
}

void vertex() {
	v_local = VERTEX;
}

// The ripple height at a local point; `rings` gets the landing rings' crests.
float height(vec2 p, float t, out float rings) {
	// crossing sine swells (smooth slopes everywhere: value noise showed its
	// grid cells as squares through the clear water), a little noise on top
	vec2 q = p * ripple_scale;
	float h = 0.5
		+ 0.16 * sin(dot(q, vec2(0.83, 0.55)) * 2.1 + t * 1.7)
		+ 0.13 * sin(dot(q, vec2(-0.42, 0.91)) * 2.9 - t * 2.1)
		+ 0.09 * sin(dot(q, vec2(0.97, -0.24)) * 4.3 + t * 2.6)
		+ 0.06 * sin(dot(q, vec2(-0.71, -0.70)) * 6.1 - t * 3.1)
		+ (vnoise(q * 1.3 + vec2(t * 0.3, t * 0.2)) - 0.5) * 0.08;
	rings = 0.0;
	for (int i = 0; i < drop_count; i++) {
		float d = length(p - drops[i].xz);
		float wave = sin(d * 14.0 - TIME * 7.0) * exp(-d * 2.2);
		h += wave * 0.35;
		rings += max(0.0, wave) * exp(-d * 3.0);
	}
	return h;
}

void fragment() {
	vec2 p = v_local.xz;
	float t = TIME * ripple_speed;
	float rings;
	float h = height(p, t, rings);
	// The slope from local differences, not screen derivatives: the pools are
	// many small triangles, and dFdx/dFdy break at their edges (dotted seams).
	float unused;
	const float STEP = 0.02;
	float hx = height(p + vec2(STEP, 0.0), t, unused);
	float hz = height(p + vec2(0.0, STEP), t, unused);
	vec3 n = normalize(vec3(-(hx - h) / STEP * ripple_strength * 0.004, 1.0, -(hz - h) / STEP * ripple_strength * 0.004));
	NORMAL = normalize((VIEW_MATRIX * vec4(n, 0.0)).xyz);
	// metres to the stone edge
	vec2 a = abs(p);
	float out_d = shape == 1 ? max(max(a.x, a.y), (a.x + a.y) * 0.70710678) : length(p);
	float to_edge = max(reach - out_d, 0.0);
	float band = (1.0 - smoothstep(0.0, 0.22, to_edge)) * (0.6 + 0.4 * vnoise(p * 9.0 + t));
	float depth_mix = smoothstep(0.0, reach * 0.7, to_edge);
	vec3 water = mix(shallow.rgb, deep.rgb, depth_mix);
	float froth = clamp(rings * 0.9 + band * edge_foam, 0.0, 1.0);
	vec3 col = mix(water, foam.rgb, froth);
	if (refraction > 0.0) {
		vec2 bend = (n.xz) * refraction;
		vec3 under = textureLod(screen_tex, SCREEN_UV + bend, 0.0).rgb;
		// the bottom seen through the water, tinted by it and darker with depth
		col = mix(col, under * mix(shallow.rgb, deep.rgb, depth_mix) * 1.6, clarity * (1.0 - froth));
		ALPHA = 1.0;
	} else {
		ALPHA = clamp(1.0 - clarity + froth * 0.5, 0.0, 1.0);
	}
	ALBEDO = col;
	ROUGHNESS = roughness;
	METALLIC = 0.0;
	SPECULAR = specular;
}
