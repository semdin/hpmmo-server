shader_type spatial;
// Phase 10 world-space PBR surface shader.
//
// Why triplanar: the castle is assembled from arbitrary-sized boxes and kit
// modules with no art-directed UVs, so a UV-mapped material would visibly
// stretch wherever a wall segment is not exactly one tile wide. Sampling in
// world space keeps texel density constant at 1 / metres_per_tile regardless
// of how a surface is scaled, which is the plan's "no visibly stretched walls"
// requirement solved structurally rather than per-piece.
//
// Texture colour space: albedo is declared `source_color` (sRGB -> linear);
// normal, roughness and AO are plain samplers and are used as raw data.
// Normal maps are OpenGL (+Y up) tangent-space maps, generated from height in
// `tools/blender/phase10_textures.py`. The per-axis tangent frames below are
// built right-handed against the surface normal (green is flipped where the
// sampling plane's (T, B) is left-handed versus the normal), which is what
// keeps a groove lit from the correct side on both walls and floors.

render_mode blend_mix, depth_draw_opaque, cull_back, diffuse_burley, specular_schlick_ggx;

uniform sampler2D albedo_tex : source_color, filter_linear_mipmap_anisotropic, repeat_enable;
uniform sampler2D normal_tex : hint_normal, filter_linear_mipmap, repeat_enable;
uniform sampler2D rough_tex : hint_default_white, filter_linear_mipmap, repeat_enable;
uniform sampler2D ao_tex : hint_default_white, filter_linear_mipmap, repeat_enable;

uniform vec3 tint : source_color = vec3(1.0, 1.0, 1.0);
uniform float world_scale = 0.125;      // texture repeats per metre (1 / metres per tile)
uniform float normal_strength : hint_range(0.0, 3.0) = 1.0;
uniform float rough_min : hint_range(0.0, 1.0) = 0.03;
uniform float rough_max : hint_range(0.0, 1.0) = 1.0;
uniform float ao_strength : hint_range(0.0, 1.0) = 1.0;
uniform float metallic_amount : hint_range(0.0, 1.0) = 0.0;
uniform bool use_baked_instance_ao = false;   // multiply by MultiMesh instance colour
uniform vec3 emission_color : source_color = vec3(0.0, 0.0, 0.0);
uniform float emission_energy = 0.0;
uniform vec3 rim_color : source_color = vec3(0.0, 0.0, 0.0);
uniform float rim_amount : hint_range(0.0, 1.0) = 0.0;

varying vec3 world_pos;
varying vec3 world_nrm;
varying vec3 vertex_color_factor;

void vertex() {
	world_pos = (MODEL_MATRIX * vec4(VERTEX, 1.0)).xyz;
	world_nrm = normalize((MODEL_MATRIX * vec4(NORMAL, 0.0)).xyz);
	// COLOR carries the baked per-instance ambient occlusion on batched
	// architecture (white when a mesh has none).
	vertex_color_factor = use_baked_instance_ao ? COLOR.rgb : vec3(1.0);
}

// Sample a map on the plane whose normal is the dominant axis, and rebuild the
// world-space normal from the map's tangent-space value.
vec3 sample_normal(vec2 uv, vec3 t, vec3 b, vec3 n) {
	vec3 tn = texture(normal_tex, uv).xyz * 2.0 - 1.0;
	tn.xy *= normal_strength;
	float handed = sign(dot(n, cross(t, b)));
	return normalize(tn.x * t + tn.y * b * handed + tn.z * n);
}

void fragment() {
	vec3 n = normalize(world_nrm);
	vec3 an = abs(n);
	vec2 uv;
	vec3 t;
	vec3 b;
	if (an.y >= an.x && an.y >= an.z) {
		uv = world_pos.xz * world_scale;
		t = vec3(1.0, 0.0, 0.0);
		b = vec3(0.0, 0.0, 1.0);
	} else if (an.x >= an.z) {
		uv = world_pos.zy * world_scale;
		t = vec3(0.0, 0.0, 1.0);
		b = vec3(0.0, 1.0, 0.0);
	} else {
		uv = world_pos.xy * world_scale;
		t = vec3(1.0, 0.0, 0.0);
		b = vec3(0.0, 1.0, 0.0);
	}
	vec3 albedo = texture(albedo_tex, uv).rgb * tint;
	float rough = texture(rough_tex, uv).r;
	float ao = texture(ao_tex, uv).r;

	ALBEDO = albedo * vertex_color_factor;
	NORMAL = sample_normal(uv, t, b, n);
	ROUGHNESS = clamp(rough, rough_min, rough_max);
	METALLIC = metallic_amount;
	AO = mix(1.0, ao, ao_strength);
	AO_LIGHT_AFFECT = 0.35;
	RIM = rim_amount;
	EMISSION = emission_color * emission_energy;
}
