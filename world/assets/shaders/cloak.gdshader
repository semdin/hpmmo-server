shader_type spatial;
// The hero cloak (art/cloaks/scripts/build_cloak_sim.py): a plain two-sided
// fabric. It moves by its skin alone - the collar and mantle ride the torso,
// the panel rides the Cloak_* chain bones CloakDeformer swings with a
// SpringBoneSimulator3D (scripts/entities/cloak_deformer.gd).
render_mode cull_disabled;

uniform sampler2D albedo_tex : source_color, filter_linear_mipmap_anisotropic;
uniform float roughness : hint_range(0.0, 1.0) = 0.85;
uniform float rim : hint_range(0.0, 1.0) = 0.3;
uniform float rim_tint : hint_range(0.0, 1.0) = 0.5;

void fragment() {
	vec4 c = texture(albedo_tex, UV);
	ALBEDO = c.rgb;
	ROUGHNESS = roughness;
	RIM = rim;
	RIM_TINT = rim_tint;
}
