shader_type spatial;
// Hero eyeballs. The eye texture holds the iris as a disc (or one per eye)
// around iris_a / iris_b; inside it the baked iris is re-coloured with the
// player's eye colour (its own shading kept), the sclera and pupil stay as
// authored. Wet: low roughness, a bright specular.
// Two-sided (some eyeballs face inwards); any transparent texel (a cornea
// shell's corner) is cut away by alpha scissor.
render_mode cull_disabled;

#include "res://assets/shaders/hero_instance.gdshaderinc"
uniform sampler2D albedo_tex : source_color, filter_linear_mipmap_anisotropic;

uniform vec2 iris_a = vec2(0.5, 0.5);
uniform vec2 iris_b = vec2(0.5, 0.5);
uniform float iris_radius = 0.105;

void fragment() {
	vec4 texel = texture(albedo_tex, UV);
	vec3 baked = texel.rgb;
	float d = min(distance(UV, iris_a), distance(UV, iris_b));
	float iris = 1.0 - smoothstep(iris_radius - 0.012, iris_radius + 0.002, d);
	// linear luminance (source_color): a brown iris is ~0.12, the pupil ~0.01
	float lum = dot(baked, vec3(0.299, 0.587, 0.114));
	vec3 tinted = clamp(iris_color * (lum / 0.12), vec3(0.0), vec3(1.0));
	// the pupil is dark: keep it out of the tint
	ALBEDO = mix(baked, tinted, iris * smoothstep(0.012, 0.04, lum));
	ROUGHNESS = 0.08;
	SPECULAR = 0.6;
	ALPHA = texel.a;
	ALPHA_SCISSOR_THRESHOLD = 0.5;
}
