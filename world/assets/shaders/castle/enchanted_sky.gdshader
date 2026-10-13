shader_type spatial;
// The Great Hall's enchanted ceiling (docs/castle-interior.md, F3).
//
// Painted on the vault webs between the stone ribs. The sky is sampled by the
// view direction, not by the surface position, so the webs read as openings
// onto a sky at infinity: it does not swim with the vault's curvature and the
// ribs stand in front of it. Dusk gradient, a star field that twinkles, slow
// drifting clouds lit warm from the horizon.
render_mode unshaded, cull_back, fog_disabled;

uniform vec3 zenith : source_color = vec3(0.025, 0.04, 0.12);
uniform vec3 mid_sky : source_color = vec3(0.10, 0.10, 0.28);
uniform vec3 horizon : source_color = vec3(0.55, 0.30, 0.32);
uniform vec3 cloud_lit : source_color = vec3(0.95, 0.62, 0.48);
uniform vec3 cloud_shade : source_color = vec3(0.16, 0.14, 0.26);
uniform float star_density = 0.55;
uniform float star_brightness = 2.4;
uniform float cloud_cover : hint_range(0.0, 1.0) = 0.42;
uniform float cloud_speed = 0.006;
uniform float brightness = 1.0;

float hash12(vec2 p) {
	vec3 p3 = fract(vec3(p.xyx) * 0.1031);
	p3 += dot(p3, p3.yzx + 33.33);
	return fract((p3.x + p3.y) * p3.z);
}

float noise(vec2 p) {
	vec2 i = floor(p);
	vec2 f = fract(p);
	vec2 u = f * f * (3.0 - 2.0 * f);
	return mix(mix(hash12(i), hash12(i + vec2(1.0, 0.0)), u.x),
		mix(hash12(i + vec2(0.0, 1.0)), hash12(i + vec2(1.0, 1.0)), u.x), u.y);
}

float fbm(vec2 p) {
	float v = 0.0;
	float a = 0.5;
	for (int i = 0; i < 5; i++) {
		v += a * noise(p);
		p = p * 2.03 + vec2(17.1, 9.2);
		a *= 0.5;
	}
	return v;
}

void fragment() {
	vec3 world_pos = (INV_VIEW_MATRIX * vec4(VERTEX, 1.0)).xyz;
	vec3 dir = normalize(world_pos - CAMERA_POSITION_WORLD);
	float up = clamp(dir.y, 0.0, 1.0);
	// Gradient: horizon glow low, deep blue overhead.
	vec3 sky = mix(horizon, mid_sky, smoothstep(0.0, 0.35, up));
	sky = mix(sky, zenith, smoothstep(0.35, 0.95, up));
	// Project onto a sky dome plane for clouds and stars.
	vec2 plane = dir.xz / max(dir.y, 0.08);
	// Stars: one candidate per cell, twinkling, hidden by clouds.
	vec2 cell = floor(plane * 38.0);
	float h = hash12(cell);
	float star = 0.0;
	if (h > 1.0 - star_density * 0.08) {
		vec2 centre = cell + vec2(hash12(cell + 3.7), hash12(cell + 9.1));
		float d = length(plane * 38.0 - centre);
		float twinkle = 0.65 + 0.35 * sin(TIME * (1.0 + h * 3.0) + h * 40.0);
		star = smoothstep(0.32, 0.0, d) * twinkle * star_brightness * (0.4 + 0.6 * fract(h * 13.0));
	}
	// Clouds: drifting fbm, lit warm toward the horizon.
	vec2 drift = vec2(TIME * cloud_speed, TIME * cloud_speed * 0.4);
	float c = fbm(plane * 0.9 + drift);
	float cloud = smoothstep(1.0 - cloud_cover, 1.0 - cloud_cover + 0.32, c);
	vec3 cloud_col = mix(cloud_lit, cloud_shade, smoothstep(0.0, 0.7, up));
	vec3 col = sky + vec3(star) * (1.0 - cloud);
	col = mix(col, cloud_col, cloud * 0.85);
	ALBEDO = col * brightness;
}
