shader_type spatial;
// The hero cloak (art/cloaks/scripts/build_cloak.py). The mesh is a rigid
// skinned shell, so on its own the swinging arms and the broom shaft pass
// through it. CloakDeformer (scripts/entities/cloak_deformer.gd) feeds the arm
// and shaft capsules in skeleton space every frame; this shader pushes the
// fabric out of them along the direction away from the spine, and while riding
// sweeps the panel back from the shoulders so it streams over the broom.
render_mode cull_disabled;

uniform sampler2D albedo_tex : source_color, filter_linear_mipmap_anisotropic;
uniform float roughness : hint_range(0.0, 1.0) = 0.85;
uniform float rim : hint_range(0.0, 1.0) = 0.3;
uniform float rim_tint : hint_range(0.0, 1.0) = 0.5;

// Capsules: a.xyz / b.xyz end points, a.w radius (0 = off). Skeleton space,
// which is the cloak's model space (the mesh sits under the Skeleton3D).
instance uniform vec4 arm_l_a;
instance uniform vec3 arm_l_b;
instance uniform vec4 fore_l_a;
instance uniform vec3 fore_l_b;
instance uniform vec4 arm_r_a;
instance uniform vec3 arm_r_b;
instance uniform vec4 fore_r_a;
instance uniform vec3 fore_r_b;
instance uniform vec4 shaft_a;
instance uniform vec3 shaft_b;
// Spine line (hips -> neck): the push direction is away from it.
instance uniform vec3 spine_a;
instance uniform vec3 spine_b;
// hinge.xyz: the shoulder line the riding sweep pivots on, hinge.w: riding 0..1.
instance uniform vec4 hinge;
// back.xyz: the body's backward direction, back.w: cloak length (hinge to hem).
instance uniform vec4 back;
instance uniform float wind = 0.0;

vec3 closest_on(vec3 p, vec3 a, vec3 b) {
	vec3 ab = b - a;
	float t = clamp(dot(p - a, ab) / max(dot(ab, ab), 1e-6), 0.0, 1.0);
	return a + ab * t;
}

// Move v along dir until it leaves the capsule (a, b, r).
vec3 push_out(vec3 v, vec3 a, vec3 b, float r, vec3 dir) {
	if (r <= 0.0) {
		return v;
	}
	vec3 ab = b - a;
	float len2 = max(dot(ab, ab), 1e-6);
	float t = dot(v - a, ab) / len2;
	vec3 p = a + ab * clamp(t, 0.0, 1.0);
	vec3 w = v - p;
	vec3 d = dir;
	if (t > 0.0 && t < 1.0) {
		// Inside the cylinder part: work in the plane across the axis.
		vec3 ax = ab * inversesqrt(len2);
		w -= ax * dot(w, ax);
		d -= ax * dot(d, ax);
	}
	float c = dot(w, w) - r * r;
	if (c >= 0.0) {
		return v;
	}
	float qa = dot(d, d);
	if (qa < 1e-5) {
		return v;
	}
	float qb = 2.0 * dot(w, d);
	float s = (-qb + sqrt(max(qb * qb - 4.0 * qa * c, 0.0))) / (2.0 * qa);
	return v + dir * s;
}

vec3 rotate_about(vec3 v, vec3 k, float angle) {
	float c = cos(angle);
	float s = sin(angle);
	return v * c + cross(k, v) * s + k * dot(k, v) * (1.0 - c);
}

void vertex() {
	vec3 v = VERTEX;
	vec3 up = normalize(spine_b - spine_a + vec3(0.0, 1e-4, 0.0));
	float riding = hinge.w;
	if (riding > 0.001 && back.w > 0.0) {
		// Stream back from the shoulders: the further down the panel, the more
		// it lifts, with a travelling flutter that grows with speed.
		vec3 rel = v - hinge.xyz;
		float fall = clamp(-dot(rel, up) / back.w, 0.0, 1.0);
		vec3 axis = normalize(cross(back.xyz, up));
		float flutter = sin(TIME * (6.0 + 4.0 * wind) - fall * 6.0) * (0.03 + 0.06 * wind) * fall * fall;
		float angle = riding * (fall * (0.8 + 0.25 * wind) + flutter);
		v = hinge.xyz + rotate_about(rel, axis, angle);
	}
	vec3 from_spine = v - closest_on(v, spine_a, spine_b);
	vec3 out_dir = normalize(from_spine + back.xyz * 0.15);
	v = push_out(v, arm_l_a.xyz, arm_l_b, arm_l_a.w, out_dir);
	v = push_out(v, fore_l_a.xyz, fore_l_b, fore_l_a.w, out_dir);
	v = push_out(v, arm_r_a.xyz, arm_r_b, arm_r_a.w, out_dir);
	v = push_out(v, fore_r_a.xyz, fore_r_b, fore_r_a.w, out_dir);
	if (shaft_a.w > 0.0) {
		// The shaft lies along the body's back axis: leave it across that axis,
		// upward for fabric above it.
		vec3 across = v - closest_on(v, shaft_a.xyz, shaft_b);
		across -= normalize(shaft_b - shaft_a.xyz) * dot(across, normalize(shaft_b - shaft_a.xyz));
		vec3 dir = normalize(across + up * 0.35);
		v = push_out(v, shaft_a.xyz, shaft_b, shaft_a.w, dir);
	}
	VERTEX = v;
}

void fragment() {
	vec4 c = texture(albedo_tex, UV);
	ALBEDO = c.rgb;
	ROUGHNESS = roughness;
	RIM = rim;
	RIM_TINT = rim_tint;
}
