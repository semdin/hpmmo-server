shader_type particles;
// Process shader of an `embers` particle layer (spell_effect): real sparks.
// Each one is thrown into a cone, arcs under gravity and air drag, wanders on a
// little turbulence, bounces off the floor and lies there cooling - white-hot
// to the spell colour to a dull glow (the `ramp`) - instead of flying on a
// straight line. The particle's basis carries its look to the draw pass
// (ember_spark.gdshader): X = its size, Y = its velocity, stretched by
// `stretch` seconds of motion blur, so a fast spark is a short streak and a
// slow or resting one a dot. All on the GPU: a few hundred cost nothing.
render_mode disable_velocity, disable_force;

uniform vec3 dir = vec3(0.0, 1.0, 0.0);
uniform float spread_deg = 60.0;
uniform float speed_min = 2.0;
uniform float speed_max = 8.0;
uniform float gravity = 9.0;
uniform float drag = 1.0;
uniform float turbulence = 0.0;
uniform float turb_freq = 6.0;
uniform float floor_y = -100000.0;
uniform float bounce = 0.35;
uniform float friction = 0.55;
uniform float size_min = 0.008;
uniform float size_max = 0.02;
uniform float stretch = 0.012;
uniform float emit_radius = 0.05;
// How far the emitter moved this frame: a trailing layer spreads its births
// back along that path instead of clumping them where the frame left it.
uniform vec3 emit_motion = vec3(0.0);
uniform float energy = 1.0;
uniform sampler2D ramp : repeat_disable, filter_linear;

uint step_rng(inout uint s) {
	s = s * 747796405u + 2891336453u;
	uint w = ((s >> ((s >> 28u) + 4u)) ^ s) * 277803737u;
	return (w >> 22u) ^ w;
}

float rand(inout uint s) {
	return float(step_rng(s)) / 4294967295.0;
}

vec3 cone(vec3 axis, float spread, inout uint s) {
	float c = mix(cos(radians(spread)), 1.0, rand(s));
	float sn = sqrt(max(0.0, 1.0 - c * c));
	float phi = rand(s) * 6.2831853;
	vec3 a = normalize(axis);
	vec3 t = normalize(abs(a.y) < 0.99 ? cross(a, vec3(0.0, 1.0, 0.0)) : vec3(1.0, 0.0, 0.0));
	vec3 b = cross(a, t);
	return a * c + (t * cos(phi) + b * sin(phi)) * sn;
}

void start() {
	uint s = NUMBER * 9781u + RANDOM_SEED * 6271u + 17u;
	step_rng(s);
	CUSTOM.x = rand(s);
	CUSTOM.y = 0.0;
	// mostly fine sparks, a few fat ones
	CUSTOM.z = mix(size_min, size_max, pow(rand(s), 2.2));
	CUSTOM.w = mix(0.45, 1.0, rand(s));
	VELOCITY = cone(dir, spread_deg, s) * mix(speed_min, speed_max, pow(rand(s), 0.8));
	vec3 off = cone(vec3(0.0, 1.0, 0.0), 180.0, s) * emit_radius * rand(s);
	TRANSFORM = mat4(1.0);
	TRANSFORM[3].xyz = EMISSION_TRANSFORM[3].xyz + off - emit_motion * rand(s);
	COLOR = texture(ramp, vec2(0.0, 0.5));
}

void process() {
	CUSTOM.y += DELTA / max(0.01, LIFETIME * CUSTOM.w);
	if (CUSTOM.y >= 1.0) {
		ACTIVE = false;
	}
	vec3 p = TRANSFORM[3].xyz;
	vec3 v = VELOCITY;
	float seed = CUSTOM.x * 97.0;
	v.y -= gravity * DELTA;
	v /= 1.0 + drag * DELTA;
	if (turbulence > 0.0) {
		float k = TIME * turb_freq;
		v += turbulence * DELTA * vec3(
			sin(k * 1.3 + seed * 7.1 + p.y * 2.3),
			sin(k * 1.7 + seed * 3.3 + p.x * 2.1) * 0.6,
			cos(k * 1.1 + seed * 5.7 + p.z * 2.7));
	}
	p += v * DELTA;
	float r = CUSTOM.z;
	if (p.y < floor_y + r) {
		p.y = floor_y + r;
		if (v.y < 0.0) {
			v.y = -v.y * bounce;
			v.xz *= friction;
			if (v.y < 0.35) {
				v.y = 0.0;
				v.xz *= 0.8;
			}
		}
	}
	VELOCITY = v;
	float speed = length(v);
	vec3 y = speed > 0.001 ? v / speed : vec3(0.0, 1.0, 0.0);
	vec3 x = normalize(abs(y.y) < 0.99 ? cross(y, vec3(0.0, 1.0, 0.0)) : vec3(1.0, 0.0, 0.0));
	vec3 z = cross(x, y);
	TRANSFORM[0] = vec4(x * r, 0.0);
	TRANSFORM[1] = vec4(y * max(r, speed * stretch), 0.0);
	TRANSFORM[2] = vec4(z * r, 0.0);
	TRANSFORM[3] = vec4(p, 1.0);
	vec4 c = texture(ramp, vec2(clamp(CUSTOM.y, 0.0, 1.0), 0.5));
	float twinkle = 0.78 + 0.22 * sin(TIME * 31.0 + seed * 13.0);
	COLOR = vec4(c.rgb * energy * twinkle, c.a);
}
