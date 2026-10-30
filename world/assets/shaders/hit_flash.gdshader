shader_type spatial;
// The hit flash over a struck body (HitFeedback): the spell's light on the body
// round the point it struck - hot where the faces turn to the blow, falling off
// over a short reach - instead of the whole body turning one flat colour.
// Additive: it is light on the body, never paint.
render_mode unshaded, blend_add, depth_draw_never, cull_back, shadows_disabled;

uniform vec4 tint : source_color = vec4(1.0, 0.85, 0.6, 1.0);
uniform float strength : hint_range(0.0, 2.0) = 0.0;
// World direction the blow travelled (from the attacker into the body).
uniform vec3 hit_dir = vec3(0.0, 0.0, -1.0);
// Where it struck (world) and how far its light reaches over the body.
uniform vec3 hit_point = vec3(0.0);
uniform float reach = 0.7;

varying vec3 v_world;

void vertex() {
	v_world = (MODEL_MATRIX * vec4(VERTEX, 1.0)).xyz;
}

void fragment() {
	vec3 n = normalize((INV_VIEW_MATRIX * vec4(NORMAL, 0.0)).xyz);
	float facing = clamp(dot(n, -normalize(hit_dir)), 0.0, 1.0);
	float d = length(v_world - hit_point) / reach;
	float near = exp(-d * d * 2.2);
	float halo = exp(-d * d * 0.5);
	vec3 hot = mix(tint.rgb, vec3(1.0, 0.97, 0.9), 0.4);
	ALBEDO = hot * (near * (0.5 + facing) * 1.4 + halo * facing * 0.25);
	ALPHA = clamp(strength, 0.0, 1.0);
}
