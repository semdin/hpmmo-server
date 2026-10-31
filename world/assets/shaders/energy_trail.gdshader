shader_type spatial;
// A world-space trail (spell_effect `trail` layers): a camera-facing strip
// through points the bolt left behind, each living `life` seconds where it
// was dropped. UV.x is a point's age (0 new .. 1 dying), UV.y runs across,
// UV2.x is metres along the flight, so the noise is pinned to the world and
// the wisps stay where they formed instead of sliding with the bolt. With age
// the strip is eaten by noise from its edges in (erosion), so it breaks into
// wisps and dissolves rather than shrinking as one ribbon.
render_mode unshaded, blend_add, cull_disabled, depth_draw_never, shadows_disabled;

uniform vec4 tint : source_color = vec4(1.0, 0.12, 0.1, 1.0);
uniform float opacity = 1.0;
uniform sampler2D flow : filter_linear_mipmap, repeat_enable;
// White-hot share near the head; 0 for a soft haze trail.
uniform float hot = 0.6;
// How hard age eats the trail into wisps (0 = clean fade).
uniform float erosion = 0.8;
uniform float noise_scale = 1.2;
uniform float seed = 0.0;
uniform float soft_fade = 0.3;
uniform sampler2D depth_tex : hint_depth_texture, repeat_disable, filter_nearest;

varying float v_age;
varying float v_across;
varying float v_metres;
varying float v_alpha;

void vertex() {
	v_age = UV.x;
	v_across = UV.y;
	v_metres = UV2.x;
	v_alpha = COLOR.a;
}

void fragment() {
	float x = v_across * 2.0 - 1.0;
	float n1 = texture(flow, vec2(v_metres * 0.35 * noise_scale + seed, v_across * 0.7 + TIME * 0.4)).r;
	float n2 = texture(flow, vec2(v_metres * 0.9 * noise_scale - seed * 0.5, v_across * 1.3 - TIME * 0.7)).r;
	float n = n1 * 0.65 + n2 * 0.35;
	// the body: a soft core that the noise wobbles across the strip
	float wobble = (n1 - 0.5) * 0.5 * (0.3 + v_age);
	float body = exp(-pow((x - wobble) * 2.2, 2.0));
	float core = exp(-pow((x - wobble) * 7.0, 2.0)) * (1.0 - v_age);
	// erosion: an age-raised threshold on the noise, softened
	float cut = smoothstep(v_age * erosion - 0.15, v_age * erosion + 0.2, n * (0.55 + body * 0.6));
	float fade = pow(1.0 - v_age, 1.5) * v_alpha;
	float light = (body * 0.8 + core * 1.2) * cut * fade;
	vec3 colour = mix(tint.rgb * 1.6, vec3(1.0, 0.92, 0.88) * 2.2, core * hot)
		+ tint.rgb * body * 0.6;
	float soft = 1.0;
	if (soft_fade > 0.0) {
		float depth_raw = texture(depth_tex, SCREEN_UV).r;
		vec4 view = INV_PROJECTION_MATRIX * vec4(SCREEN_UV * 2.0 - 1.0, depth_raw, 1.0);
		float scene_dist = -view.z / max(1e-5, view.w);
		soft = clamp((scene_dist - (-VERTEX.z)) / soft_fade, 0.0, 1.0);
	}
	ALBEDO = colour;
	ALPHA = clamp(light * opacity * soft, 0.0, 1.0);
}
