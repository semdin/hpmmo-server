shader_type spatial;
render_mode unshaded, blend_add, depth_draw_never, cull_disabled, shadows_disabled, fog_disabled;

// The floor of a way out: a pool of light turning on itself. The cloud map
// the spell effects use, wound into a spiral that tightens toward the middle
// and drains inward; a bright uneven rim; a core of light; and the Portkey's
// ripple clip beating out over it. Nothing ruled or drawn: it replaces a
// glowing tube (and then a clock-face of fine lines) lying on the floor.
// Additive: it glows on a dark floor and never hides it.

uniform sampler2D noise : repeat_enable, filter_linear_mipmap, hint_default_white;
uniform sampler2D ripple : source_color, filter_linear_mipmap, hint_default_black;   // 8x8 flipbook
uniform vec4 tint : source_color = vec4(0.42, 0.72, 1.0, 1.0);
uniform float energy = 1.0;
uniform float ripple_fps = 24.0;

vec4 ripple_frame(float index, vec2 uv) {
	index = mod(index, 64.0);
	vec2 cell = vec2(mod(index, 8.0), floor(index / 8.0));
	return texture(ripple, (cell + uv) / 8.0);
}

void fragment() {
	vec2 p = UV * 2.0 - 1.0;
	float r = length(p);
	float around = atan(p.y, p.x) / TAU;
	float t = TIME;
	// A spiral: the further in, the further round - and all of it draining
	// toward the middle. Whole turns round, a fixed level of detail (the wrap
	// would draw a seam otherwise).
	float twist = log(max(r, 0.02)) * 0.42;
	float n1 = textureLod(noise, vec2(around * 2.0 + twist - t * 0.035, r * 0.9 + t * 0.11), 1.0).r;
	float n2 = textureLod(noise, vec2(around * 5.0 + twist * 1.6 + t * 0.05, r * 1.7 + t * 0.19), 1.0).r;
	float swirl = n1 * 0.6 + n2 * 0.4;
	float arms = smoothstep(0.42, 0.82, swirl);

	float edge = smoothstep(1.0, 0.86, r);
	float body = arms * smoothstep(0.04, 0.35, r) * (0.25 + 0.55 * r);
	// The rim: a wavering band of light, not a circle.
	float off = r - 0.86 * (1.0 + (swirl - 0.5) * 0.06);
	float rim = exp(-(off * off) / 0.0009) * (0.7 + 0.3 * n2) + exp(-abs(off) / 0.07) * (0.25 + 0.45 * swirl);
	float core = exp(-r * r * 7.0) * (0.55 + 0.15 * sin(t * 2.1));
	float breathe = 0.88 + 0.12 * sin(t * 1.5);

	float light = (body * 0.55 + rim * 0.75 + core * 0.6) * edge * breathe;
	vec3 hot = mix(tint.rgb, vec3(0.92, 0.97, 1.0), 0.55);
	vec3 colour = mix(tint.rgb * tint.rgb, tint.rgb, smoothstep(0.0, 0.4, light));
	colour = mix(colour, hot, smoothstep(0.4, 1.0, light));
	// The ripple clip, beating outward over the pool.
	float f = t * ripple_fps;
	vec4 wave = mix(ripple_frame(floor(f), UV), ripple_frame(floor(f) + 1.0, UV), fract(f));
	ALBEDO = (colour * min(light, 1.0) + wave.rgb * wave.a * 0.55 * edge) * energy;
}
