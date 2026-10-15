shader_type spatial;
// The Slytherin common room's window under the lake (docs/castle-interior.md, F4):
// deep green water, slow caustic ripples and light falling from the surface
// above. Unshaded - it is the room's own light source.
render_mode unshaded, cull_disabled, fog_disabled;

uniform vec3 deep : source_color = vec3(0.01, 0.06, 0.05);
uniform vec3 shallow : source_color = vec3(0.10, 0.42, 0.32);
uniform vec3 caustic : source_color = vec3(0.55, 0.95, 0.75);
uniform float brightness = 1.3;

float h(vec2 p) {
	return fract(sin(dot(p, vec2(127.1, 311.7))) * 43758.5453);
}

float n2(vec2 p) {
	vec2 i = floor(p);
	vec2 f = fract(p);
	vec2 u = f * f * (3.0 - 2.0 * f);
	return mix(mix(h(i), h(i + vec2(1, 0)), u.x), mix(h(i + vec2(0, 1)), h(i + vec2(1, 1)), u.x), u.y);
}

void fragment() {
	vec2 uv = UV;
	// light from above: brighter toward the top of the window
	float depth = 1.0 - uv.y;
	vec3 col = mix(deep, shallow, smoothstep(0.0, 1.0, depth) * 0.85);
	// caustics: two drifting noise layers folded into thin bright lines
	vec2 p = uv * vec2(6.0, 3.0);
	float a = n2(p + vec2(TIME * 0.12, TIME * 0.05));
	float b = n2(p * 1.7 - vec2(TIME * 0.08, -TIME * 0.11));
	float c = pow(1.0 - abs(a - b), 9.0);
	col += caustic * c * (0.25 + 0.75 * depth);
	// a few dark weed silhouettes swaying at the bottom
	float sway = sin(TIME * 0.6 + uv.x * 18.0) * 0.015;
	float weed = smoothstep(0.02, 0.0, abs(fract((uv.x + sway * (1.0 - uv.y)) * 9.0) - 0.5) - 0.03)
		* smoothstep(0.45, 0.0, uv.y < 0.55 ? 0.55 - uv.y : 0.0) * step(0.55, uv.y);
	col = mix(col, deep * 0.5, weed * 0.8);
	ALBEDO = col * brightness;
}
