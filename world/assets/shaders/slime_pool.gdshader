shader_type spatial;
render_mode cull_back, shadows_disabled;

// Venom pool (Blackweb Caverns, Zehir Gölleri): a flat quad cut to a lumpy
// shoreline by noise, a dark glossy body with slowly drifting luminous green
// veins and bubbles, and a pale crusted rim where it dries on the rock.
// Opaque + discard (cheap on the iGPU).

uniform float seed = 0.0;
uniform vec3 deep : source_color = vec3(0.015, 0.05, 0.02);
uniform vec3 glow : source_color = vec3(0.35, 1.0, 0.2);
uniform vec3 crust : source_color = vec3(0.32, 0.36, 0.2);
uniform float glow_energy = 1.4;

float hash(vec2 p) { return fract(sin(dot(p, vec2(127.1, 311.7))) * 43758.5453); }
float noise(vec2 p) {
	vec2 i = floor(p), f = fract(p);
	vec2 u = f * f * (3.0 - 2.0 * f);
	return mix(mix(hash(i), hash(i + vec2(1, 0)), u.x), mix(hash(i + vec2(0, 1)), hash(i + vec2(1, 1)), u.x), u.y);
}
float fbm(vec2 p) {
	float v = 0.0, a = 0.5;
	for (int i = 0; i < 4; i++) { v += noise(p) * a; p *= 2.03; a *= 0.5; }
	return v;
}

void fragment() {
	vec2 p = (UV - 0.5) * 2.0;
	float r = length(p);
	float edge = r + (fbm(p * 2.2 + seed * 7.0) - 0.5) * 0.55;
	if (edge > 0.92) {
		discard;
	}
	float rim = smoothstep(0.72, 0.9, edge);
	vec2 q = p * 3.0 + seed * 3.0;
	float t = TIME * 0.06;
	float veins = fbm(q + vec2(fbm(q + t), fbm(q - t * 1.3)) * 1.6);
	float vein = smoothstep(0.52, 0.62, veins) * (1.0 - smoothstep(0.62, 0.74, veins));
	float bub = smoothstep(0.86, 0.95, noise(p * 14.0 + vec2(0.0, TIME * 0.25) + seed));
	float pulse = 0.75 + 0.25 * sin(TIME * 1.3 + seed * 10.0);
	vec3 body = deep + glow * 0.04;
	ALBEDO = mix(body, crust, rim);
	ROUGHNESS = mix(0.06, 0.85, rim);
	SPECULAR = mix(0.9, 0.3, rim);
	EMISSION = glow * (vein * 0.9 + bub * 1.4 + 0.05) * pulse * glow_energy * (1.0 - rim);
}
