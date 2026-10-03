shader_type spatial;
render_mode cull_back;
uniform vec4 stone_color : source_color = vec4(0.52, 0.5, 0.45, 1.0);
uniform vec4 mortar_color : source_color = vec4(0.33, 0.32, 0.29, 1.0);
uniform float tile_scale = 1.3;
varying vec3 world_pos;
varying vec3 world_normal;
float hash(vec2 p) { return fract(sin(dot(p, vec2(127.1,311.7)))*43758.5453); }
void vertex() {
	world_pos = (MODEL_MATRIX * vec4(VERTEX, 1.0)).xyz;
	world_normal = normalize(MODEL_NORMAL_MATRIX * NORMAL);
}
void fragment() {
	vec3 n = abs(world_normal);
	vec2 uv = n.y > 0.7 ? world_pos.xz : (n.x > n.z ? world_pos.zy : world_pos.xy);
	uv *= vec2(0.75, 1.8) * tile_scale;
	uv.x += mod(floor(uv.y), 2.0) * 0.5;
	vec2 tile = floor(uv);
	vec2 f = fract(uv);
	vec2 aa = fwidth(uv) * 1.1;
	float edge = smoothstep(0.008, 0.022 + aa.x, min(f.x, 1.0-f.x)) * smoothstep(0.012, 0.028 + aa.y, min(f.y, 1.0-f.y));
	float grain = hash(floor(uv * 110.0));
	vec3 stone = stone_color.rgb * (0.84 + hash(tile) * 0.25 + grain * 0.06);
	ALBEDO = mix(mortar_color.rgb, stone, edge);
	ROUGHNESS = 0.86;
}
