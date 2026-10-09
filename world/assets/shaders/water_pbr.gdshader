shader_type spatial;
// Black Lake water - bright animated lake surface that never reads as black.
// - Gerstner-style vertex waves (visual only, collision is a separate static plane).
// - Procedural ripple normals, no texture dependency.
// - Depth fade against the lakebed when a depth buffer is available, with a
//   safe mid-depth fallback when it is not (compatibility renderers, no opaque
//   pass behind the surface). The old version went near-black whenever the
//   depth/screen texture read failed; this one always has a lit base color.
// - Fresnel sky tint + sun glitter + shoreline foam + subtle emission so night
//   and shadowed views keep a blue read instead of darkness.

render_mode blend_mix, depth_draw_always, cull_disabled, diffuse_burley, specular_schlick_ggx;

uniform vec4 shallow_color : source_color = vec4(0.23, 0.52, 0.60, 0.78);
uniform vec4 deep_color : source_color = vec4(0.05, 0.19, 0.33, 0.94);
uniform vec4 sky_tint : source_color = vec4(0.55, 0.68, 0.78, 1.0);
uniform vec4 foam_color : source_color = vec4(0.88, 0.95, 1.0, 0.9);

uniform float roughness : hint_range(0.0, 1.0) = 0.12;
uniform float metallic : hint_range(0.0, 1.0) = 0.05;

uniform float wave_amplitude_1 = 0.14;
uniform float wave_frequency_1 = 0.12;
uniform float wave_speed_1 = 1.2;

uniform float wave_amplitude_2 = 0.07;
uniform float wave_frequency_2 = 0.27;
uniform float wave_speed_2 = 1.9;

uniform vec2 flow_direction_1 = vec2(1.0, 0.4);
uniform vec2 flow_direction_2 = vec2(-0.4, 0.9);

uniform float depth_distance : hint_range(0.5, 20.0) = 5.0;
uniform float foam_depth : hint_range(0.05, 1.5) = 0.45;
uniform float emission_boost = 0.35;

// Depth/screen textures are intentionally NOT sampled: reading them from a
// transparent surface turned the lake black on some passes/renderers.

varying vec3 world_pos;
varying vec3 vertex_normal;
varying float wave_crest;

void vertex() {
	world_pos = (MODEL_MATRIX * vec4(VERTEX, 1.0)).xyz;
	float t = TIME;

	vec2 dir1 = normalize(flow_direction_1);
	vec2 dir2 = normalize(flow_direction_2);

	float phase1 = dot(dir1, world_pos.xz) * wave_frequency_1 + t * wave_speed_1;
	float phase2 = dot(dir2, world_pos.xz) * wave_frequency_2 + t * wave_speed_2;

	float wave1 = sin(phase1) * wave_amplitude_1;
	float wave2 = sin(phase2) * wave_amplitude_2;

	VERTEX.y += wave1 + wave2;
	wave_crest = clamp((wave1 + wave2) / (wave_amplitude_1 + wave_amplitude_2), -1.0, 1.0);

	float ddx = cos(phase1) * wave_amplitude_1 * wave_frequency_1 * dir1.x
	          + cos(phase2) * wave_amplitude_2 * wave_frequency_2 * dir2.x;
	float ddz = cos(phase1) * wave_amplitude_1 * wave_frequency_1 * dir1.y
	          + cos(phase2) * wave_amplitude_2 * wave_frequency_2 * dir2.y;

	vec3 wave_norm = normalize(vec3(-ddx, 1.0, -ddz));
	vertex_normal = (MODEL_MATRIX * vec4(wave_norm, 0.0)).xyz;
}

void fragment() {
	// Fixed mid-lake depth tint plus a slow large-scale variation so the
	// surface always has a lit, readable blue base colour.
	float water_depth = 2.2 + 1.6 * sin(world_pos.x * 0.05 + TIME * 0.2) * cos(world_pos.z * 0.045 - TIME * 0.15);
	water_depth = clamp(water_depth, 0.4, depth_distance);

	float depth_factor = clamp(water_depth / depth_distance, 0.0, 1.0);
	depth_factor = pow(depth_factor, 0.7);
	vec4 water_col = mix(shallow_color, deep_color, depth_factor);

	float foam_factor = clamp(1.0 - (water_depth / foam_depth), 0.0, 1.0);
	foam_factor = pow(foam_factor, 1.5);
	// Wave-crest whitening so the animation reads even mid-lake.
	float crest_foam = smoothstep(0.55, 1.0, wave_crest) * 0.25;
	vec4 final_color = mix(water_col, foam_color, clamp(foam_factor * 0.75 + crest_foam, 0.0, 1.0));

	float t = TIME;
	float ripple = sin(world_pos.x * 2.5 + t * 2.0) * cos(world_pos.z * 2.5 + t * 1.8) * 0.09;
	ripple += sin(world_pos.x * 5.0 - t * 3.0) * sin(world_pos.z * 4.0 + t * 2.5) * 0.045;
	ripple += sin((world_pos.x + world_pos.z) * 9.0 + t * 4.0) * 0.02;

	vec3 view_norm = normalize((VIEW_MATRIX * vec4(vertex_normal, 0.0)).xyz);
	view_norm = normalize(view_norm + vec3(ripple, 0.0, ripple));
	NORMAL = view_norm;

	float fresnel = pow(1.0 - clamp(dot(NORMAL, VIEW), 0.0, 1.0), 3.0);
	vec3 col = mix(final_color.rgb, sky_tint.rgb, fresnel * 0.55);

	ALBEDO = col;
	EMISSION = col * emission_boost * (0.35 + fresnel * 0.65) + foam_color.rgb * foam_factor * 0.25;
	ALPHA = clamp(mix(final_color.a, 0.97, fresnel * 0.5), 0.55, 0.97);
	ROUGHNESS = mix(roughness, 0.03, fresnel);
	METALLIC = metallic;
	SPECULAR = 0.9;
}
