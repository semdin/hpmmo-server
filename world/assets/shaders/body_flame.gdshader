shader_type spatial;
// One tongue of fire licking off a burning body (StatusFX burn particles): a
// camera-facing particle that plays a cell of the flame_loop flipbook chosen by
// its animation phase (CPUParticles3D INSTANCE_CUSTOM.z), with its cell's hard
// edges and flat base feathered away so only the flame shows. Additive.
render_mode unshaded, blend_add, depth_draw_never, cull_disabled, shadows_disabled;

uniform sampler2D atlas : source_color, filter_linear_mipmap;
uniform float grid = 8.0;
uniform float opacity = 1.0;

varying vec2 cell_uv;
varying vec2 quad_uv;

void vertex() {
	mat4 world = mat4(normalize(INV_VIEW_MATRIX[0]), normalize(INV_VIEW_MATRIX[1]),
		normalize(INV_VIEW_MATRIX[2]), MODEL_MATRIX[3]);
	float a = INSTANCE_CUSTOM.x;   // the particle's tilt
	world = world * mat4(vec4(cos(a), -sin(a), 0.0, 0.0), vec4(sin(a), cos(a), 0.0, 0.0),
		vec4(0.0, 0.0, 1.0, 0.0), vec4(0.0, 0.0, 0.0, 1.0));
	MODELVIEW_MATRIX = VIEW_MATRIX * world;
	MODELVIEW_MATRIX = MODELVIEW_MATRIX * mat4(vec4(length(MODEL_MATRIX[0].xyz), 0.0, 0.0, 0.0),
		vec4(0.0, length(MODEL_MATRIX[1].xyz), 0.0, 0.0), vec4(0.0, 0.0, length(MODEL_MATRIX[2].xyz), 0.0),
		vec4(0.0, 0.0, 0.0, 1.0));
	MODELVIEW_NORMAL_MATRIX = mat3(MODELVIEW_MATRIX);
	float frames = grid * grid;
	float frame = floor(fract(INSTANCE_CUSTOM.z) * frames);
	vec2 cell = vec2(mod(frame, grid), floor(frame / grid));
	cell_uv = (UV + cell) / grid;
	quad_uv = UV;
}

void fragment() {
	vec4 c = texture(atlas, cell_uv);
	float side = smoothstep(0.0, 0.3, quad_uv.x) * smoothstep(1.0, 0.7, quad_uv.x);
	float base = smoothstep(1.0, 0.72, quad_uv.y);
	float top = smoothstep(0.0, 0.18, quad_uv.y);
	ALBEDO = c.rgb * COLOR.rgb * 1.25;
	ALPHA = clamp(c.a * side * base * top * COLOR.a * opacity, 0.0, 1.0);
}
