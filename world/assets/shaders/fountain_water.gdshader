shader_type spatial;
// The courtyard fountain's moving water, laid over the baked (still) model:
//   mode 0 - a pool surface: two drifting ripple fields plus rings spreading
//            from where the streams land (`drops`, xz in local space);
//   mode 1 - a falling stream: streaks running down the ribbon (UV.y = 0 at
//            the lip), thinning and breaking up towards the bottom.
// Procedural noise only (no textures), cheap enough for the low preset.
render_mode blend_mix, depth_draw_never, cull_disabled, shadows_disabled;

uniform int mode = 0;
uniform vec4 deep : source_color = vec4(0.18, 0.42, 0.55, 0.62);
uniform vec4 foam : source_color = vec4(0.86, 0.95, 1.0, 0.9);
uniform float flow_speed = 2.2;
uniform float ripple_scale = 3.5;
uniform vec4 drops[4];
uniform int drop_count = 0;
uniform float radius = 1.0;

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

varying vec3 v_local;

void vertex() {
	v_local = VERTEX;
}

void fragment() {
	if (mode == 0) {
		vec2 p = v_local.xz;
		float t = TIME;
		// height field from two drifting noise layers and the landing rings
		float h = vnoise(p * ripple_scale + vec2(t * 0.35, t * 0.22)) * 0.6
			+ vnoise(p * ripple_scale * 2.1 - vec2(t * 0.5, -t * 0.3)) * 0.4;
		float rings = 0.0;
		for (int i = 0; i < drop_count; i++) {
			float d = length(p - drops[i].xz);
			float wave = sin(d * 14.0 - t * 7.0) * exp(-d * 2.2);
			h += wave * 0.35;
			rings += max(0.0, wave) * exp(-d * 3.0);
		}
		// normal from the height field's screen-space slope
		vec3 n = normalize(vec3(-dFdx(h) * 9.0, 1.0, -dFdy(h) * 9.0));
		NORMAL = normalize((VIEW_MATRIX * vec4(n, 0.0)).xyz);
		float edge = smoothstep(radius, radius * 0.86, length(p));
		ALBEDO = mix(deep.rgb, foam.rgb, clamp(rings * 0.9 + (h - 0.5) * 0.25, 0.0, 1.0));
		ROUGHNESS = 0.06;
		METALLIC = 0.0;
		SPECULAR = 0.9;
		ALPHA = deep.a * edge + rings * 0.25;
	} else {
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
}
