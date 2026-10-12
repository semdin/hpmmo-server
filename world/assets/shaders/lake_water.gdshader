shader_type spatial;
// Black Lake surface for the 2 km grounds (water line y = 0).
//
// The depth of the water under each point is known in advance: the build writes
// the lake bed into `depth_map` (red = metres below the surface / depth_scale,
// covering `depth_rect` in world XZ). So colour, shore foam and edge fade come
// from real depth in every renderer, without reading the depth buffer (which a
// transparent surface cannot trust on the Compatibility renderer).
//
// Normals: two scrolling detail normal maps (generated noise) plus a broad
// swell, mixed by distance so the far lake does not shimmer.

render_mode blend_mix, depth_draw_always, cull_back, diffuse_burley, specular_schlick_ggx;

uniform sampler2D depth_map : hint_default_black, filter_linear, repeat_disable;
uniform vec4 depth_rect = vec4(-700.0, 0.0, 1400.0, 700.0);   // x, z, width, depth (world metres)
uniform float depth_scale = 20.0;

uniform sampler2D normal_a : hint_normal, filter_linear_mipmap, repeat_enable;
uniform sampler2D normal_b : hint_normal, filter_linear_mipmap, repeat_enable;
uniform float normal_scale_a = 0.045;
uniform float normal_scale_b = 0.11;
uniform vec2 flow_a = vec2(0.010, 0.006);
uniform vec2 flow_b = vec2(-0.007, 0.011);
uniform float normal_strength : hint_range(0.0, 2.0) = 0.35;

uniform vec3 shallow_color : source_color = vec3(0.22, 0.34, 0.30);
uniform vec3 mid_color : source_color = vec3(0.06, 0.14, 0.17);
uniform vec3 deep_color : source_color = vec3(0.015, 0.045, 0.07);
uniform float shallow_depth = 1.2;
uniform float deep_depth = 9.0;
uniform vec3 foam_color : source_color = vec3(0.82, 0.86, 0.84);
uniform float foam_band = 0.45;
uniform float edge_fade = 0.25;

uniform float roughness_near : hint_range(0.0, 1.0) = 0.06;
uniform float roughness_far : hint_range(0.0, 1.0) = 0.16;

varying vec3 world_pos;

void vertex() {
	world_pos = (MODEL_MATRIX * vec4(VERTEX, 1.0)).xyz;
	// A low swell; the surface is a grid, so this reads at the shore line.
	float t = TIME;
	VERTEX.y += sin(world_pos.x * 0.07 + t * 0.9) * 0.035 + sin(world_pos.z * 0.05 - t * 0.7) * 0.03;
}

float water_depth(vec2 xz) {
	vec2 uv = (xz - depth_rect.xy) / depth_rect.zw;
	if (uv.x < 0.0 || uv.y < 0.0 || uv.x > 1.0 || uv.y > 1.0) {
		return 0.0;
	}
	return texture(depth_map, uv).r * depth_scale;
}

void fragment() {
	float d = water_depth(world_pos.xz);
	float dist = length(world_pos - (INV_VIEW_MATRIX * vec4(0.0, 0.0, 0.0, 1.0)).xyz);
	float far_blend = smoothstep(40.0, 400.0, dist);

	vec2 uva = world_pos.xz * normal_scale_a + TIME * flow_a;
	vec2 uvb = world_pos.xz * normal_scale_b + TIME * flow_b;
	vec3 na = texture(normal_a, uva).xyz * 2.0 - 1.0;
	vec3 nb = texture(normal_b, uvb).xyz * 2.0 - 1.0;
	vec2 slope = (na.xy + nb.xy) * normal_strength * mix(1.0, 0.2, far_blend);
	vec3 wn = normalize(vec3(slope.x, 1.0, slope.y));
	NORMAL = normalize((VIEW_MATRIX * vec4(wn, 0.0)).xyz);

	vec3 col = mix(shallow_color, mid_color, smoothstep(0.0, shallow_depth * 2.5, d));
	col = mix(col, deep_color, smoothstep(shallow_depth * 2.0, deep_depth, d));

	// Foam: a thin band at the shore, broken up by the detail normals.
	float breakup = 0.5 + 0.5 * (na.x * nb.y);
	float foam = (1.0 - smoothstep(0.0, foam_band, d)) * smoothstep(0.25, 0.75, breakup + 0.25);
	col = mix(col, foam_color, foam * 0.55);

	float fresnel = pow(1.0 - clamp(dot(NORMAL, VIEW), 0.0, 1.0), 5.0);
	ALBEDO = col;
	ROUGHNESS = mix(roughness_near, roughness_far, far_blend);
	METALLIC = 0.0;
	SPECULAR = 0.5;
	// Shallow water shows the bed through it; depth and grazing angles go opaque.
	float clarity = 1.0 - smoothstep(0.0, 2.2, d);
	ALPHA = clamp(mix(0.97, 0.55, clarity) + fresnel * 0.4, 0.0, 1.0) * smoothstep(0.0, edge_fade, d + 0.05);
}
