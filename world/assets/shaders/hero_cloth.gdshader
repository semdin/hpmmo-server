shader_type spatial;
// The hero's outfits (Hero_<Outfit>_* meshes, art/characters/hero_q). The
// texels of each outfit's main cloth (mask_tex, art/characters/hero_q/
// house_masks.py) take the wearer's house colour (house_color, an instance
// uniform set by HeroAppearance.apply_house_tint) at their own shading,
// relative to the cloth's key_color, so one texture dresses all four houses.

// Both faces: an open collar shows the inside of the garment, and with the
// inner faces culled the cloak behind the neck showed through the shirt.
render_mode cull_disabled;
#include "res://assets/shaders/hero_instance.gdshaderinc"
uniform sampler2D albedo_tex : source_color, filter_linear_mipmap_anisotropic;
uniform sampler2D normal_tex : hint_normal, filter_linear_mipmap_anisotropic;
uniform bool has_normal = false;
uniform sampler2D mask_tex : hint_default_black, filter_linear;
uniform vec3 key_color : source_color = vec3(0.5);
uniform float house_gain = 1.0;
uniform float roughness : hint_range(0.0, 1.0) = 0.85;
uniform float rim_amount = 0.1;

void fragment() {
	vec3 c = texture(albedo_tex, UV).rgb;
	vec3 w = vec3(0.2126, 0.7152, 0.0722);
	float lum = max(dot(c, w), 1e-4);
	float key_lum = max(dot(key_color, w), 1e-4);
	float mask = texture(mask_tex, UV).r;
	// a dyed-wool tone of the house colour (the raw primary is a banner colour),
	// shaded like the cloth it replaces
	vec3 dye = mix(vec3(dot(house_color, w)), house_color, 0.8) * house_gain;
	// the cloth's own shading, damped so painted mottling does not show as stains
	vec3 house = dye * mix(1.0, lum / key_lum, 0.6);
	ALBEDO = mix(c, clamp(house, vec3(0.0), vec3(1.0)), mask);
	if (has_normal) {
		NORMAL_MAP = texture(normal_tex, UV).rgb;
	}
	ROUGHNESS = roughness;
	RIM = rim_amount;
	RIM_TINT = 0.25;
}
