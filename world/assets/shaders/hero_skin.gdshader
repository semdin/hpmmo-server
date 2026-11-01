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
// Skin light (light(), after HumanShaders by MatMADNESS, MIT): light goes a
// little under skin and comes out red, so the shading turns softer and
// warmer per channel - red sees a blurred normal (a low mip of the normal
// map) and wraps furthest past the terminator, blue sees the sharp one.
// The specular is two GGX lobes (the oily sheen and a broad one). Close up
// (under ~2.5 m) a tiling pore normal map (HumanShaders' skin_micro, CC BY
// 4.0) breaks the painted skin; further out it is not sampled at all. No
// screen-space SSS: Forward+ only and a full-screen pass on an iGPU.

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
uniform sampler2D micro_tex : hint_default_white, filter_linear_mipmap, repeat_enable;
uniform bool has_micro = false;
uniform float micro_scale = 26.0;
uniform float micro_strength = 0.35;
// how far past the terminator each channel's light wraps (red the most)
uniform vec3 skin_wrap = vec3(0.24, 0.12, 0.08);

// the blurred (low-mip) normal, view space: the red channel's light
varying vec3 soft_normal;

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
	soft_normal = NORMAL;
	vec3 nm = vec3(0.5, 0.5, 1.0);
	if (has_normal) {
		nm = texture(normal_tex, UV).rgb;
		// normal maps import as RG: z is rebuilt, as Godot does for NORMAL_MAP
		vec3 soft = vec3(textureLod(normal_tex, UV, 4.0).rg * 2.0 - 1.0, 0.0);
		soft.z = sqrt(max(0.0, 1.0 - dot(soft.xy, soft.xy)));
		soft_normal = normalize(TANGENT * soft.x + BINORMAL * soft.y + NORMAL * soft.z);
	}
	float near = has_micro ? 1.0 - smoothstep(1.2, 2.5, -VERTEX.z) : 0.0;
	if (near > 0.0) {
		vec3 micro = texture(micro_tex, UV * micro_scale).rgb;
		nm.xy += (micro.xy - 0.5) * micro_strength * near;
		AO = mix(1.0, micro.b, 0.2 * near);
		AO_LIGHT_AFFECT = 0.0;
	}
	NORMAL_MAP = nm;
}

float ggx(float n_dot_h, float n_dot_l, float n_dot_v, float alpha) {
	float a2 = alpha * alpha;
	float d = n_dot_h * n_dot_h * (a2 - 1.0) + 1.0;
	float vis = 0.5 / mix(2.0 * n_dot_l * n_dot_v, n_dot_l + n_dot_v, alpha);
	return a2 / (PI * d * d) * vis;
}

void light() {
	vec3 n_mid = normalize(soft_normal + NORMAL);
	vec3 n_dot_l = vec3(dot(soft_normal, LIGHT), dot(n_mid, LIGHT), dot(NORMAL, LIGHT));
	vec3 diffuse = clamp((n_dot_l + skin_wrap) / (1.0 + skin_wrap), 0.0, 1.0);
	// the shadow's edge goes a little red too
	vec3 shadow = vec3(sqrt(ATTENUATION), ATTENUATION, ATTENUATION * ATTENUATION);
	shadow = mix(vec3(ATTENUATION), shadow, 0.5);
	DIFFUSE_LIGHT += diffuse * shadow * LIGHT_COLOR / PI;

	float nl = clamp(n_dot_l.b, 0.0, 1.0);
	if (nl > 0.0) {
		vec3 h = normalize(VIEW + LIGHT);
		float nh = clamp(dot(NORMAL, h), 0.0, 1.0);
		float nv = clamp(dot(NORMAL, VIEW), 1e-3, 1.0);
		float alpha = ROUGHNESS * ROUGHNESS;
		float lobes = mix(ggx(nh, nl, nv, min(alpha + 0.3, 1.0)), ggx(nh, nl, nv, alpha), 0.6);
		float lh = clamp(dot(LIGHT, h), 0.0, 1.0);
		float f = 0.028 + 0.972 * pow(1.0 - lh, 5.0);
		SPECULAR_LIGHT += lobes * f * nl * ATTENUATION * LIGHT_COLOR * SPECULAR_AMOUNT;
	}
}
