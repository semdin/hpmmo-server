shader_type spatial;
// A living flame card for torches, hearths and braziers: the generated
// flame_loop flipbook (fal Wan clip, 8x8, assets/vfx/atlases) played on a quad
// that turns about Y to face the camera. Each flame picks its own start frame
// and speed from its world position (and INSTANCE_CUSTOM.x in a MultiMesh), so
// a row of torches never burns in step; neighbouring frames are cross-faded so
// the clip stays smooth at any rate. Additive: the clip's black is nothing.
render_mode unshaded, blend_add, depth_draw_never, cull_disabled, shadows_disabled, fog_disabled;

uniform sampler2D flipbook : source_color, filter_linear_mipmap, hint_default_black;
uniform float frames_x = 8.0;
uniform float frames_y = 8.0;
uniform float fps = 20.0;
uniform float intensity = 1.5;
// White keeps the clip's own colours; any other tint recolours the flame by
// its brightness (the green cauldron burners, the cold sconces).
uniform vec3 tint : source_color = vec3(1.0, 1.0, 1.0);
uniform float flicker = 0.14;

varying float v_phase;
varying float v_flicker;

float hash13(vec3 p) {
	p = fract(p * 0.1031);
	p += dot(p, p.zyx + 31.32);
	return fract((p.x + p.y) * p.z);
}

void vertex() {
	vec3 origin = MODEL_MATRIX[3].xyz;
	v_phase = fract(INSTANCE_CUSTOM.x + hash13(floor(origin * 11.0)));
	float t = TIME * (1.0 + v_phase);
	v_flicker = 1.0 - flicker + flicker * (0.55 + 0.45 * sin(t * 13.0 + v_phase * 40.0) * sin(t * 5.7 + v_phase * 17.0));
	vec3 right = vec3(INV_VIEW_MATRIX[0].x, 0.0, INV_VIEW_MATRIX[0].z);
	right = length(right) > 0.001 ? normalize(right) : vec3(1.0, 0.0, 0.0);
	float sx = length(MODEL_MATRIX[0].xyz);
	float sy = length(MODEL_MATRIX[1].xyz);
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
	float t = TIME * fps * (0.85 + 0.3 * v_phase) + v_phase * 64.0;
	float f = floor(t);
	vec4 c = mix(frame(f, UV), frame(f + 1.0, UV), fract(t));
	vec3 col = c.rgb * c.a;
	if (distance(tint, vec3(1.0)) > 0.001) {
		float lum = dot(col, vec3(0.3, 0.59, 0.11));
		col = tint * lum * 1.7 + vec3(lum * lum * 0.35);
	}
	// Fade the card's edges so no frame border shows, and melt the base (the
	// clip's flames are cut flat at the bottom of each frame).
	float edge = smoothstep(0.0, 0.06, UV.x) * smoothstep(1.0, 0.94, UV.x) * smoothstep(0.0, 0.05, UV.y)
		* smoothstep(1.0, 0.84, UV.y);
	ALBEDO = col * intensity * v_flicker * edge;
}
