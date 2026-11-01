shader_type spatial;
// Hero eyeballs. The eye texture holds the iris as a disc (or one per eye)
// around iris_a / iris_b; inside it the baked iris is re-coloured with the
// player's eye colour (its own shading kept), the sclera and pupil stay as
// authored. Wet: low roughness, a bright specular.
// Two-sided (some eyeballs face inwards); any transparent texel (a cornea
// shell's corner) is cut away by alpha scissor.
// The kit's iris is ~27 texels across with a painted highlight: inside the
// disc a 1024 px iris photo (HumanShaders by MatMADNESS, CC BY 4.0) takes
// its place, its fibres recoloured with the player's eye colour, the pupil
// widened a little and a dark limbal ring at its rim. The painted highlight
// goes with it; a catch light (the reflection of a soft light up-left of the
// camera, in view space) keeps the eyes alive under any scene light. One more
// texture read on a few hundred pixels.
render_mode cull_disabled;

#include "res://assets/shaders/hero_instance.gdshaderinc"
uniform sampler2D albedo_tex : source_color, filter_linear_mipmap_anisotropic;

uniform vec2 iris_a = vec2(0.5, 0.5);
uniform vec2 iris_b = vec2(0.5, 0.5);
uniform float iris_radius = 0.105;
uniform sampler2D iris_tex : source_color, filter_linear_mipmap_anisotropic, hint_default_black;
uniform bool has_iris = false;
// the iris photo's mean linear luminance between pupil and rim
uniform float iris_ref_luma = 0.085;

void fragment() {
	vec4 texel = texture(albedo_tex, UV);
	vec3 baked = texel.rgb;
	vec2 centre = distance(UV, iris_a) < distance(UV, iris_b) ? iris_a : iris_b;
	float d = distance(UV, centre);
	float iris = 1.0 - smoothstep(iris_radius - 0.012, iris_radius + 0.002, d);
	if (has_iris) {
		// the disc onto the photo's circle (its rim at the texture's edge)
		// r -> r^1.25 widens the pupil and keeps the rim
		vec2 o = (UV - centre) / iris_radius;
		o *= pow(length(o) + 1e-4, 0.25);
		vec3 photo = texture(iris_tex, 0.5 + 0.5 * o).rgb;
		float lum = dot(photo, vec3(0.299, 0.587, 0.114));
		vec3 tinted = clamp(iris_color * (lum / iris_ref_luma), vec3(0.0), vec3(1.0));
		float rim = smoothstep(0.72, 1.0, d / iris_radius);
		ALBEDO = mix(baked, tinted * (1.0 - 0.65 * rim), iris);
	} else {
		// linear luminance (source_color): a brown iris is ~0.12, the pupil ~0.01
		float lum = dot(baked, vec3(0.299, 0.587, 0.114));
		vec3 tinted = clamp(iris_color * (lum / 0.12), vec3(0.0), vec3(1.0));
		// the pupil is dark: keep it out of the tint
		ALBEDO = mix(baked, tinted, iris * smoothstep(0.012, 0.04, lum));
	}
	vec3 catch_dir = normalize(vec3(-0.35, 0.45, 1.0));
	float catch_light = pow(max(dot(reflect(-VIEW, NORMAL), catch_dir), 0.0), 150.0);
	EMISSION = vec3(catch_light * 0.9);
	ROUGHNESS = 0.08;
	SPECULAR = 0.6;
	ALPHA = texel.a;
	ALPHA_SCISSOR_THRESHOLD = 0.5;
}
