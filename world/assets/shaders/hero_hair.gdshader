shader_type spatial;
// Hero hairstyles (Hero_Hair_<style>, art/characters/hero_q). Any alpha in the
// texture cuts strands (scissor, both sides: a card is seen from behind too);
// its colour is reduced to its shading
// (luminance over the style's mean, ref_luma) and re-coloured with the
// player's hair colour, so every style takes every colour from black to
// platinum without a texture per colour.
// The generated styles carry their distance to the open edge in COLOR.r
// (build_rig.py mark_hair_edge: 0 at the edge .. 1 at 6 mm in; meshes without
// it read 1): over that band the strands thin out, darker strands first, so
// the hairline and the lock tips end in strands, not in the polygon edge.
render_mode cull_disabled;

#include "res://assets/shaders/hero_instance.gdshaderinc"
uniform sampler2D albedo_tex : source_color, filter_linear_mipmap_anisotropic;
uniform sampler2D normal_tex : hint_normal, filter_linear_mipmap_anisotropic;
uniform float ref_luma = 0.12;
uniform float roughness : hint_range(0.0, 1.0) = 0.72;

void fragment() {
	vec4 texel = texture(albedo_tex, UV);
	vec3 baked = texel.rgb;
	// the baked highlights would blow out light colours: keep the shading but
	// squeeze its range around the colour
	float shade = dot(baked, vec3(0.299, 0.587, 0.114)) / max(ref_luma, 0.001);
	shade = clamp(1.0 + (shade - 1.0) * 0.55, 0.35, 1.45);
	// real white hair reflects ~80 %: at 1.0 platinum and white locks glowed
	ALBEDO = clamp(hair_color * shade, vec3(0.0), vec3(0.8));
	NORMAL_MAP = texture(normal_tex, UV).rgb;
	ROUGHNESS = roughness;
	SPECULAR = 0.4;
	float strand = clamp(1.0 - (shade - 0.35) / 1.1, 0.0, 1.0);
	float thin = 0.15 + 0.7 * strand + 0.15 * fract(sin(dot(floor(UV * 1024.0), vec2(12.9898, 78.233))) * 43758.5453);
	ALPHA = texel.a * smoothstep(thin - 0.08, thin + 0.08, COLOR.r);
	ALPHA_SCISSOR_THRESHOLD = 0.5;
#if CURRENT_RENDERER == RENDERER_FORWARD_PLUS
	// not under Mobile: its half-precision fwidth crashes Mesa's NVK compiler
	// and the hair disappears (scripts/autoload/render_compat.gd)
	ALPHA_ANTIALIASING_EDGE = 0.3;
#endif
}
