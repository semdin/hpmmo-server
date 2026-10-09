shader_type spatial;
render_mode unshaded, blend_add, cull_disabled, depth_draw_never, shadows_disabled;

uniform sampler2D flow_noise : repeat_enable, filter_linear_mipmap;
uniform vec4 tint : source_color = vec4(0.16, 0.55, 1.0, 0.65);
uniform float clock = 0.0;
uniform float opacity = 1.0;
uniform float erode = 0.0;
uniform vec3 hit_point = vec3(0.0);
uniform float hit_age = 10.0;
varying vec3 world_position;

void vertex() { world_position = (MODEL_MATRIX * vec4(VERTEX, 1.0)).xyz; }

void fragment() {
	float rim = pow(1.0 - abs(dot(normalize(NORMAL), normalize(VIEW))), 2.6);
	vec2 uv = UV * vec2(24.0, 14.0);
	uv.x += mod(floor(uv.y), 2.0) * 0.5;
	vec2 cell = abs(fract(uv) - 0.5);
	float facets = smoothstep(0.46, 0.49, max(cell.x, cell.y));
	float noise = texture(flow_noise, UV * 3.0 + vec2(clock * 0.025, -clock * 0.04)).b;
	float scan = pow(max(0.0, sin(UV.y * 25.0 - clock * 2.0)), 22.0);
	float dist = distance(world_position, hit_point);
	float ripple = exp(-pow((dist - hit_age * 5.0) / 0.12, 2.0)) * (1.0 - smoothstep(0.0, 0.55, hit_age));
	float dissolve = 1.0 - smoothstep(noise - 0.06, noise + 0.06, erode);
	ALBEDO = mix(tint.rgb * 1.6, vec3(0.75, 0.95, 1.0), ripple);
	ALPHA = (rim * 0.5 + facets * 0.055 + scan * 0.055 + ripple * 0.85) * opacity * dissolve;
}
