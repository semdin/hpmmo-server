shader_type spatial;
render_mode cull_disabled, diffuse_lambert, specular_disabled;

// Procedural orb web on a quad (Blackweb Caverns dressing): radial spokes +
// a wobbly spiral, torn by noise, thinner and fainter toward the rim.
// `seed` varies the spoke count/tear pattern per instance (INSTANCE_CUSTOM.x
// for MultiMesh, or the uniform for single meshes). Opaque + discard (no
// transparent pass: cheap on the iGPU).

uniform vec3 silk : source_color = vec3(0.82, 0.84, 0.86);
uniform float seed = 0.0;
uniform float spokes = 13.0;
uniform float rings = 11.0;
uniform float alpha_mul = 0.85;

varying float inst_seed;

void vertex() {
	inst_seed = INSTANCE_CUSTOM.x;
}

float hash(vec2 p) { return fract(sin(dot(p, vec2(127.1, 311.7))) * 43758.5453); }
float noise(vec2 p) {
	vec2 i = floor(p), f = fract(p);
	vec2 u = f * f * (3.0 - 2.0 * f);
	return mix(mix(hash(i), hash(i + vec2(1, 0)), u.x), mix(hash(i + vec2(0, 1)), hash(i + vec2(1, 1)), u.x), u.y);
}

void fragment() {
	float sd = seed + inst_seed * 17.0;
	vec2 p = (UV - 0.5) * 2.0;
	float r = length(p);
	float a = atan(p.y, p.x) / TAU + 0.5;
	float n_sp = floor(spokes + fract(sd * 3.1) * 6.0);
	float sp_a = fract(a * n_sp + noise(vec2(r * 3.0, sd)) * 0.15);
	float spoke = smoothstep(0.035 / max(r, 0.08), 0.0, min(sp_a, 1.0 - sp_a));
	float spiral = fract(r * rings - a * 1.0 + noise(vec2(a * 9.0, sd)) * 0.25);
	float ring = smoothstep(0.08, 0.0, min(spiral, 1.0 - spiral)) * step(0.06, r);
	float web = max(spoke, ring * 0.85);
	float tear = smoothstep(0.35, 0.55, noise(p * 3.5 + sd * 5.0));
	float rim = 1.0 - smoothstep(0.75, 1.0, r);
	float alpha = web * tear * rim * alpha_mul;
	if (alpha < 0.3) {
		discard;
	}
	ALBEDO = silk;
	BACKLIGHT = vec3(0.4);
	ROUGHNESS = 0.6;
}
