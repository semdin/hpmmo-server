shader_type particles;
// Motes rising off a mark on the ground (a boss warning's embers, a target
// ring's sparks, a portal's lights): born on its boundary (a circle,
// or a cone's arc and its two sides) and a few inside it, they lift on the
// heat, sway, cool from white-hot to a dull red and wink out. Drawn by
// ember_spark.gdshader like every spark in the game (the particle's basis
// carries its size and its streak). `rate` thins them out before the
// countdown has built up.
render_mode disable_velocity, disable_force;

uniform float radius = 5.0;
uniform float sector = 4.0;      // a cone's half angle; 3.1 and up: the whole circle
uniform float rise_min = 0.5;
uniform float rise_max = 2.0;
uniform float size_min = 0.010;
uniform float size_max = 0.026;
uniform float stretch = 0.03;
uniform float energy = 1.0;
uniform float rate = 1.0;        // share of the particles alive (the countdown)
uniform sampler2D ramp : repeat_disable, filter_linear;

uint step_rng(inout uint s) {
	s = s * 747796405u + 2891336453u;
	uint w = ((s >> ((s >> 28u) + 4u)) ^ s) * 277803737u;
	return (w >> 22u) ^ w;
}

float rand(inout uint s) {
	return float(step_rng(s)) / 4294967295.0;
}

void start() {
	uint s = NUMBER * 9781u + RANDOM_SEED * 6271u + 17u;
	step_rng(s);
	CUSTOM.x = rand(s);
	CUSTOM.y = 0.0;
	CUSTOM.z = mix(size_min, size_max, pow(rand(s), 2.0));
	CUSTOM.w = mix(0.55, 1.0, rand(s));
	// where on the area: four in five on the boundary, the rest inside
	bool cone = sector < 3.1;
	float span = cone ? sector : PI;
	float a = (rand(s) * 2.0 - 1.0) * span;
	float dist = radius;
	if (rand(s) > 0.8) {
		dist = radius * sqrt(rand(s));
	} else if (cone && rand(s) < 0.45) {
		// one of the cone's straight sides
		a = (rand(s) < 0.5 ? -1.0 : 1.0) * sector;
		dist = radius * rand(s);
	}
	dist += (rand(s) - 0.5) * 0.3;
	vec3 at = vec3(sin(a) * dist, 0.05, cos(a) * dist);
	TRANSFORM = mat4(1.0);
	TRANSFORM[3].xyz = (EMISSION_TRANSFORM * vec4(at, 1.0)).xyz;
	VELOCITY = vec3((rand(s) - 0.5) * 0.5, mix(rise_min, rise_max, rand(s)), (rand(s) - 0.5) * 0.5);
	COLOR = texture(ramp, vec2(0.0, 0.5));
	// thinned while the countdown is young
	if (rand(s) > rate) {
		ACTIVE = false;
	}
}

void process() {
	CUSTOM.y += DELTA / max(0.01, LIFETIME * CUSTOM.w);
	if (CUSTOM.y >= 1.0) {
		ACTIVE = false;
	}
	vec3 p = TRANSFORM[3].xyz;
	vec3 v = VELOCITY;
	float seed = CUSTOM.x * 97.0;
	float k = TIME * 3.1;
	// the heat lifts it; the air shoves it about
	v.y += 0.5 * DELTA;
	v.xz /= 1.0 + 0.8 * DELTA;
	v += 1.6 * DELTA * vec3(sin(k * 1.3 + seed * 7.1 + p.y * 2.3), 0.0, cos(k * 1.1 + seed * 5.7 + p.y * 1.9));
	p += v * DELTA;
	VELOCITY = v;
	float r = CUSTOM.z * (1.0 - CUSTOM.y * CUSTOM.y * 0.6);
	float speed = length(v);
	vec3 y = speed > 0.001 ? v / speed : vec3(0.0, 1.0, 0.0);
	vec3 x = normalize(abs(y.y) < 0.99 ? cross(y, vec3(0.0, 1.0, 0.0)) : vec3(1.0, 0.0, 0.0));
	vec3 z = cross(x, y);
	TRANSFORM[0] = vec4(x * r, 0.0);
	TRANSFORM[1] = vec4(y * max(r, speed * stretch), 0.0);
	TRANSFORM[2] = vec4(z * r, 0.0);
	TRANSFORM[3] = vec4(p, 1.0);
	vec4 c = texture(ramp, vec2(clamp(CUSTOM.y, 0.0, 1.0), 0.5));
	float twinkle = 0.75 + 0.25 * sin(TIME * 27.0 + seed * 13.0);
	COLOR = vec4(c.rgb * energy * twinkle, c.a);
}
