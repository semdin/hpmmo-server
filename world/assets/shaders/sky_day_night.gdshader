shader_type sky;
// The grounds' sky through the day (DayNight): a gradient sky, the sun or
// the moon (light 0 - the scene's one sky light), drifting clouds and a
// starfield that comes out at night and twinkles behind gaps in the clouds.
// Everything is procedural (no textures). The radiance cubemap (ambient and
// reflections) takes the plain gradient and the discs only, so a moving sky
// never re-bakes more than that; DayNight runs the sky in incremental mode.

uniform vec3 top_color : source_color = vec3(0.24, 0.35, 0.49);
uniform vec3 horizon_color : source_color = vec3(0.60, 0.66, 0.72);
uniform vec3 ground_bottom : source_color = vec3(0.20, 0.23, 0.22);
uniform vec3 ground_horizon : source_color = vec3(0.46, 0.52, 0.55);
// 0 day .. 1 night: stars, moon look, darker clouds
uniform float night = 0.0;
// cloud amount (0.3 fair, 0.95 overcast), how storm-dark, their colours
uniform float cloud_cover = 0.38;
uniform float cloud_dark = 0.0;
uniform vec3 cloud_lit : source_color = vec3(1.0, 0.98, 0.95);
uniform vec3 cloud_shade : source_color = vec3(0.56, 0.62, 0.70);
uniform float wind = 0.006;
uniform float sun_size = 0.026;

float hash12(vec2 p) {
	vec3 p3 = fract(vec3(p.xyx) * 0.1031);
	p3 += dot(p3, p3.yzx + 33.33);
	return fract((p3.x + p3.y) * p3.z);
}

float hash13(vec3 p3) {
	p3 = fract(p3 * 0.1031);
	p3 += dot(p3, p3.zyx + 31.32);
	return fract((p3.x + p3.y) * p3.z);
}

float vnoise(vec2 p) {
	vec2 i = floor(p);
	vec2 f = fract(p);
	vec2 u = f * f * (3.0 - 2.0 * f);
	return mix(mix(hash12(i), hash12(i + vec2(1.0, 0.0)), u.x),
		mix(hash12(i + vec2(0.0, 1.0)), hash12(i + vec2(1.0, 1.0)), u.x), u.y);
}

float fbm(vec2 p) {
	float v = 0.0;
	float a = 0.5;
	for (int i = 0; i < 4; i++) {
		v += a * vnoise(p);
		p = p * 2.03 + vec2(17.1, 9.2);
		a *= 0.5;
	}
	return v;
}

// One star per cell of a 3D grid over the sky, a few percent of cells lit.
float stars(vec3 d) {
	vec3 p = d * 190.0;
	vec3 cell = floor(p);
	float h = hash13(cell);
	if (h < 0.955) {
		return 0.0;
	}
	vec3 jitter = vec3(hash13(cell + 11.0), hash13(cell + 23.0), hash13(cell + 37.0));
	float dist = length(p - (cell + jitter));
	float size = mix(0.16, 0.42, pow(hash13(cell + 5.0), 5.0));
	float twinkle = 0.65 + 0.35 * sin(TIME * (1.5 + h * 5.0) + h * 80.0);
	float bright = 0.35 + 1.4 * pow((h - 0.955) / 0.045, 2.0);
	return smoothstep(size, 0.0, dist) * bright * twinkle;
}

void sky() {
	vec3 d = EYEDIR;
	float h = d.y;
	vec3 col;
	if (h >= 0.0) {
		col = mix(horizon_color, top_color, pow(clamp(h, 0.0, 1.0), 0.5));
	} else {
		col = mix(ground_horizon, ground_bottom, clamp(-h * 3.0, 0.0, 1.0));
	}
	float cloud = 0.0;
	vec3 cloud_col = vec3(0.0);
	// Clouds on a plane above: denser near the horizon, drifting with the wind.
	if (h > 0.0) {
		vec2 p = d.xz / (h + 0.14) * 0.55 + vec2(TIME * wind, TIME * wind * 0.37);
		float n = fbm(p * 2.3);
		float fine = fbm(p * 6.0 - vec2(TIME * wind * 2.0, 0.0));
		float m = n * 0.8 + fine * 0.2;
		float c = smoothstep(0.66 - cloud_cover * 0.5, 0.86 - cloud_cover * 0.5, m);
		cloud = c * smoothstep(0.0, 0.1, h) * 0.95;
		float shade = clamp((n - 0.45) * 1.6 + cloud_dark, 0.0, 1.0);
		cloud_col = mix(cloud_lit, cloud_shade, shade);
	}
	if (LIGHT0_ENABLED) {
		float c = dot(d, LIGHT0_DIRECTION);
		float ang = acos(clamp(c, -1.0, 1.0));
		vec3 light = LIGHT0_COLOR;
		// sun: a glare and a wide warm halo; moon: a pale disc, a faint halo
		col += light * pow(max(c, 0.0), 8.0) * 0.18 * (1.0 - night) * (1.0 - cloud_dark);
		col += light * pow(max(c, 0.0), 300.0) * mix(1.6, 0.25, night);
		float disc = smoothstep(sun_size, sun_size * 0.8, ang);
		vec3 moon = vec3(0.86, 0.89, 0.96) * (0.82 + 0.18 * vnoise(d.xy * 180.0));
		vec3 disc_col = mix(light * 8.0, moon * 1.7, night);
		col = mix(col, disc_col, disc * (1.0 - cloud * 0.92));
		// the clouds catch the light round the sun / moon
		cloud_col += light * pow(max(c, 0.0), 6.0) * 0.35 * (1.0 - cloud_dark);
	}
	if (!AT_CUBEMAP_PASS) {
		if (h > 0.0 && night > 0.01) {
			col += vec3(0.92, 0.95, 1.0) * stars(d) * night * smoothstep(0.0, 0.2, h) * (1.0 - cloud);
			// a faint band of the Milky Way
			float band = exp(-pow(dot(d, normalize(vec3(0.35, 0.55, -0.76))) * 4.0, 2.0));
			col += vec3(0.25, 0.28, 0.4) * band * fbm(d.xz * 9.0) * 0.12 * night * (1.0 - cloud);
		}
		col = mix(col, cloud_col, cloud);
	} else {
		// ambient/reflections: the clouds' average tint only
		col = mix(col, cloud_col, cloud_cover * 0.35 * step(0.0, h));
	}
	COLOR = col;
}
