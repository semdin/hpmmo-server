shader_type spatial;
// The hero's skin (Hero_Head and the outfits' bare arms, art/characters/hero_q).
// One material per skin texture, shared by every hero; each hero's skin tone
// arrives as an instance uniform (HeroAppearance.apply_look) and multiplies
// the painted skin. The head's vertex colour holds one scalp mask per
// hairstyle (build_rig.py: R G B in HPRules.LOOK_HAIR_STYLES order): the worn
// style's mask takes the hair colour, so no bald skin shows between locks.

#include "res://assets/shaders/hero_instance.gdshaderinc"
uniform sampler2D albedo_tex : source_color, filter_linear_mipmap_anisotropic;
uniform float roughness : hint_range(0.0, 1.0) = 0.62;
uniform bool has_scalp = false;

void fragment() {
	vec3 skin = texture(albedo_tex, UV).rgb * skin_tint;
	float scalp = has_scalp ? clamp(dot(COLOR.rgb, scalp_select), 0.0, 1.0) : 0.0;
	ALBEDO = mix(skin, hair_color * 0.8, scalp);
	ROUGHNESS = mix(roughness, 0.85, scalp);
	SPECULAR = 0.35;
}
