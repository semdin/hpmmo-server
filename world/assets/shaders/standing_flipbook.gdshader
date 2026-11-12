shader_type spatial;
// A flipbook clip standing on the ground: cards that turn about Y to face the
// camera, each on its instance origin (the quad's base, not its centre), on
// one MultiMesh - one draw call for a whole ring of them. Each card starts on
// its own frame and plays at its own rate, so a row of them never beats in
// step. The light standing over a portal is this (the Portkey's aura clip);
// `grow` and `intensity` let a mark raise and fade its cards.
// INSTANCE_CUSTOM: x = phase, y = mirrored (0/1).
render_mode unshaded, blend_add, depth_draw_never, cull_disabled, shadows_disabled, fog_disabled;

uniform sampler2D flipbook : source_color, filter_linear_mipmap, hint_default_black;
uniform float frames_x = 8.0;
uniform float frames_y = 8.0;
uniform float fps = 22.0;
// White keeps the clip's own colours; any other tint recolours it by its
// brightness (a storm's cold fire).
uniform vec3 tint : source_color = vec3(1.0, 1.0, 1.0);
uniform float grow = 1.0;
uniform float intensity = 1.0;
// How much each card's height licks up and down on its own (flames: a lot).
uniform float lick = 0.24;

varying float v_phase;
varying float v_mirror;
varying float v_flicker;

void vertex() {
	vec3 origin = MODEL_MATRIX[3].xyz;
	v_phase = INSTANCE_CUSTOM.x;
	v_mirror = INSTANCE_CUSTOM.y;
	float t = TIME * (1.0 + v_phase);
	v_flicker = 0.84 + 0.16 * sin(t * 11.0 + v_phase * 40.0) * sin(t * 5.3 + v_phase * 17.0);
	vec3 right = vec3(INV_VIEW_MATRIX[0].x, 0.0, INV_VIEW_MATRIX[0].z);
	right = length(right) > 0.001 ? normalize(right) : vec3(1.0, 0.0, 0.0);
	float sway = 1.0 - lick * 0.5 + lick * sin(t * 2.7 + v_phase * 23.0);
	float sx = length(MODEL_MATRIX[0].xyz) * mix(0.65, 1.0, min(grow, 1.0));
	float sy = length(MODEL_MATRIX[1].xyz) * grow * sway;
	vec3 world = origin + right * VERTEX.x * sx + vec3(0.0, 1.0, 0.0) * VERTEX.y * sy;
	POSITION = PROJECTION_MATRIX * VIEW_MATRIX * vec4(world, 1.0);
}

vec4 frame(float index, vec2 uv) {
	float total = frames_x * frames_y;
	index = mod(index, total);
	vec2 cell = vec2(mod(index, frames_x), floor(index / frames_x));
	return texture(flipbook, (cell + uv) / vec2(frames_x, frames_y));
}

void fragment() {
	vec2 uv = vec2(mix(UV.x, 1.0 - UV.x, step(0.5, v_mirror)), UV.y);
	float t = TIME * fps * (0.85 + 0.3 * v_phase) + v_phase * 64.0;
	float f = floor(t);
	vec4 c = mix(frame(f, uv), frame(f + 1.0, uv), fract(t));
	vec3 col = c.rgb * c.a;
	if (distance(tint, vec3(1.0)) > 0.001) {
		float lum = dot(col, vec3(0.3, 0.59, 0.11));
		col = tint * lum * 1.7 + vec3(lum * lum * 0.35);
	}
	// Fade the card's edges so no frame border shows, and melt the base into
	// the ground it stands on.
	float edge = smoothstep(0.0, 0.08, uv.x) * smoothstep(1.0, 0.92, uv.x) * smoothstep(0.0, 0.06, UV.y)
		* smoothstep(1.0, 0.80, UV.y);
	ALBEDO = col * intensity * v_flicker * edge;
}
