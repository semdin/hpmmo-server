shader_type spatial;
render_mode blend_mix, cull_disabled, depth_draw_never, unshaded, shadows_disabled;

// Orb web on a quad (Blackweb Caverns dressing): a dew-beaded web photo
// (assets/vfx/tex/cobweb_1024.png, white silk on black, rim already faded) used
// as alpha. INSTANCE_CUSTOM.x (MultiMesh) varies the brightness and a slow
// sway; the silk catches a little of the cave's coloured light through `tint`.

uniform sampler2D web : filter_linear_mipmap_anisotropic, repeat_disable;
uniform vec3 silk : source_color = vec3(0.86, 0.9, 0.95);
uniform vec3 tint : source_color = vec3(0.55, 0.85, 0.75);
uniform float opacity = 0.75;
uniform float glint = 0.35;

varying float inst_seed;

void vertex() {
	inst_seed = INSTANCE_CUSTOM.x;
	// A slow breathing sway, more toward the free middle.
	float r = length(UV - 0.5);
	VERTEX.z += sin(TIME * 0.9 + inst_seed * 40.0) * 0.04 * (1.0 - r * 2.0);
}

void fragment() {
	float a = texture(web, UV).r;
	// Dew beads twinkle a little.
	float tw = 0.75 + 0.25 * sin(TIME * 2.3 + (UV.x * 37.0 + UV.y * 23.0) + inst_seed * 20.0);
	vec3 col = mix(silk, tint, 0.35) * (0.55 + inst_seed * 0.3);
	ALBEDO = col + vec3(glint) * smoothstep(0.7, 1.0, a) * tw;
	ALPHA = clamp(a * 1.4, 0.0, 1.0) * opacity;
}
