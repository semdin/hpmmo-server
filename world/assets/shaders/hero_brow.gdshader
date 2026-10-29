shader_type spatial;
// Hero eyebrows (MPFB alpha cards): the hair colour and the card's alpha, cut
// by scissor so they never enter the transparent sort.
render_mode cull_disabled;

#include "res://assets/shaders/hero_instance.gdshaderinc"
uniform sampler2D albedo_tex : source_color, filter_linear_mipmap_anisotropic;

void fragment() {
	// the card's colour is not trusted (its transparent texels carry light
	// colour into the mips): the shape comes from alpha, the colour is the hair's
	ALBEDO = hair_color * 0.8;
	ALPHA = texture(albedo_tex, UV).a;
	ALPHA_SCISSOR_THRESHOLD = 0.4;
	ROUGHNESS = 0.8;
}
