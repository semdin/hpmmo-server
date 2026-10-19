shader_type spatial;

// Blackweb Caverns ground (scripts/world/caverns/spider_caverns.gd).
// One mesh for floor and walls: steep faces are triplanar rock, flat ground
// blends three floor layers from the vertex colour splat
// (art/spider_caverns/scripts/cavern_heightfield.py: R web dust, G bone gravel,
// B slime). Textures are the grounds' packed Terrain3D sets (albedo+height,
// normal+roughness). Wall tops sink into darkness so the open roof reads as a
// cave ceiling lost in the gloom.

uniform sampler2D rock_alb : source_color, filter_linear_mipmap_anisotropic, repeat_enable;
uniform sampler2D rock_nrm : filter_linear_mipmap_anisotropic, repeat_enable;
uniform sampler2D dust_alb : source_color, filter_linear_mipmap_anisotropic, repeat_enable;
uniform sampler2D dust_nrm : filter_linear_mipmap_anisotropic, repeat_enable;
uniform sampler2D gravel_alb : source_color, filter_linear_mipmap_anisotropic, repeat_enable;
uniform sampler2D gravel_nrm : filter_linear_mipmap_anisotropic, repeat_enable;

uniform float rock_scale = 0.11;
uniform float floor_scale = 0.18;
uniform vec3 rock_tint : source_color = vec3(0.62, 0.6, 0.68);
uniform vec3 dust_tint : source_color = vec3(0.74, 0.7, 0.66);
uniform vec3 bone_tint : source_color = vec3(0.86, 0.80, 0.68);
uniform vec3 slime_tint : source_color = vec3(0.10, 0.20, 0.08);
uniform float base_y = 1550.0;
// Height above the floor beside it (metres) where the walls fade to black.
uniform float dark_from = 14.0;
uniform float dark_to = 40.0;

varying vec3 world_pos;
varying vec3 world_nrm;

void vertex() {
	world_pos = (MODEL_MATRIX * vec4(VERTEX, 1.0)).xyz;
	world_nrm = normalize((MODEL_MATRIX * vec4(NORMAL, 0.0)).xyz);
}

vec4 triplanar(sampler2D tex, vec3 p, vec3 w) {
	return texture(tex, p.zy) * w.x + texture(tex, p.xz) * w.y + texture(tex, p.xy) * w.z;
}

void fragment() {
	vec3 n = normalize(world_nrm);
	vec3 w = pow(abs(n), vec3(4.0));
	w /= (w.x + w.y + w.z);
	vec3 rp = world_pos * rock_scale;
	vec4 r_alb = triplanar(rock_alb, rp, w);
	vec4 r_nrm = triplanar(rock_nrm, rp, w);

	vec2 fp = world_pos.xz * floor_scale;
	vec4 d_alb = texture(dust_alb, fp);
	vec4 d_nrm = texture(dust_nrm, fp);
	vec4 g_alb = texture(gravel_alb, fp * 1.3);
	vec4 g_nrm = texture(gravel_nrm, fp * 1.3);

	vec3 s = COLOR.rgb;
	// Height-aware blend: gravel pokes through dust where its height is high.
	float g = clamp(s.g * 1.6 + (g_alb.a - 0.5) * 0.8, 0.0, 1.0) * step(0.02, s.g);
	float dust_luma = dot(d_alb.rgb, vec3(0.33));
	vec3 dust = mix(vec3(dust_luma), d_alb.rgb, 0.25) * dust_tint * 1.15;
	vec3 floor_col = mix(dust, g_alb.rgb * bone_tint, g);
	floor_col = mix(floor_col, slime_tint + d_alb.rgb * 0.08, s.b);
	vec4 floor_nrm = mix(d_nrm, g_nrm, g);
	float floor_rough = mix(mix(d_nrm.a, g_nrm.a, g), 0.18, s.b);

	// Rock on slopes (normal.y < ~0.75), with a noisy transition.
	float slope = smoothstep(0.86, 0.66, n.y + (r_alb.a - 0.5) * 0.12);
	vec3 col = mix(floor_col, r_alb.rgb * rock_tint, slope);
	vec4 nm = mix(floor_nrm, r_nrm, slope);
	float rough = mix(floor_rough, max(r_nrm.a, 0.6), slope);

	// Fade wall tops into the dark (the open roof).
	float above = world_pos.y - base_y;
	float local_floor = mix(-26.0, 0.0, step(-12.0, above)); // floors 1 (~0) and 2 (~-25)
	float fade = smoothstep(dark_from, dark_to, above - local_floor);
	col *= mix(1.0, 0.04, fade);

	ALBEDO = col;
	NORMAL_MAP = nm.rgb;
	NORMAL_MAP_DEPTH = mix(1.0, 1.6, slope);
	ROUGHNESS = rough;
	SPECULAR = mix(0.35, 0.7, s.b * (1.0 - slope));
}
