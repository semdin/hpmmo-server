shader_type spatial;
// The hero's skin (Hero_Head and the outfits' bare arms, art/characters/hero_q).
// One material per skin texture, shared by every hero; each hero's skin tone
// arrives as an instance uniform (HeroAppearance.apply_look) and multiplies
// the painted skin. The head's scalp_tex holds one scalp mask per hairstyle
// (build_rig.py scalp/scalp_<style>.png, layers in HPRules.LOOK_HAIR_STYLES
// order): under the worn style the skin shows short hair in the hair colour
// (stretched strokes of the grain, a firm edge), so no bald skin shows between
// the locks and the generated styles' bare temples read as a short cut. Flat
// paint grown past the hairline read as a glowing halo (user, 2026-10-30):
// the masks now stop at the hair and the paint carries strokes.
// The head's face_masks.png R (build_rig.py) is the beard area: the stubble
// and short beard (beard_shade) paint it in the hair colour, broken a little
// by a fine grain (the approved Blender preview's mix, 2026-10-29).
// The kit's normal and roughness maps carry the face's modelling (jaw,
// cheekbones, brow ridge): without them the face lit flat, like plastic.

#include "res://assets/shaders/hero_instance.gdshaderinc"
uniform sampler2D albedo_tex : source_color, filter_linear_mipmap_anisotropic;
uniform sampler2D normal_tex : hint_normal, filter_linear_mipmap_anisotropic;
uniform sampler2D roughness_tex : hint_roughness_g, filter_linear_mipmap_anisotropic;
uniform sampler2D face_mask_tex : hint_default_black, filter_linear_mipmap;
uniform sampler2D grain_tex : hint_default_white, filter_linear_mipmap, repeat_enable;
uniform sampler2DArray scalp_tex : hint_default_black, filter_linear_mipmap;
uniform bool has_normal = false;
uniform bool has_roughness = false;
uniform bool has_scalp = false;
uniform bool has_face = false;
uniform float roughness : hint_range(0.0, 1.0) = 0.62;
uniform float grain_scale = 14.0;

void fragment() {
	vec3 skin = texture(albedo_tex, UV).rgb * skin_tint;
	float scalp = has_scalp && scalp_layer >= 0.0 ? texture(scalp_tex, vec3(UV, scalp_layer)).r : 0.0;
	float rough = has_roughness ? texture(roughness_tex, UV).g : roughness;
	float grain = texture(grain_tex, UV * grain_scale).r;
	float strokes = texture(grain_tex, UV * vec2(grain_scale * 3.0, grain_scale * 0.6)).r;
	scalp = smoothstep(0.35, 0.85, scalp) * (0.7 + 0.3 * strokes);
	vec3 short_hair = min(hair_color * (0.55 + 0.6 * strokes), vec3(0.75));
	vec3 colour = mix(skin, short_hair, scalp * 0.9);
	rough = mix(rough, 0.85, scalp);
	if (has_face) {
		float area = texture(face_mask_tex, UV).r;
		float beard = clamp(area * (0.62 + 0.45 * grain), 0.0, 1.0) * beard_shade;
		colour = mix(colour, hair_color, beard);
		rough = mix(rough, 0.8, beard);
	}
	ALBEDO = colour;
	ROUGHNESS = rough;
	SPECULAR = has_roughness ? 0.45 : 0.35;
	if (has_normal) {
		NORMAL_MAP = texture(normal_tex, UV).rgb;
	}
}
