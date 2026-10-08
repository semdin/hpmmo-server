shader_type spatial;
// the spell effects tapered ribbon (broom trail, projectile streaks, Expelliarmus arc).
//
// The strip is rebuilt each frame along a motion history; the authored UV layout
// and taper profile come from assets/vfx/meshes/trail_ribbon.glb
// (U runs 0 at the emitter -> 1 at the tip, V across; alpha = taper profile, see
// assets/vfx/meshes/meshes_metadata.json). The shader scrolls a streak texture
// along U, fades both edges and adds a soft tip falloff. Additive: a trail is
// light, never a surface.
render_mode unshaded, cull_disabled, depth_draw_never, shadows_disabled, blend_add;

uniform sampler2D streak : filter_linear_mipmap;
uniform vec4 tint : source_color = vec4(1.0, 0.8, 0.45, 1.0);
uniform float scroll : hint_range(-8.0, 8.0) = 0.0;
uniform float opacity : hint_range(0.0, 2.0) = 1.0;
uniform float edge_softness : hint_range(0.0, 1.0) = 0.55;

varying float v_across;
varying float v_along;
varying vec4 v_colour;

void vertex() {
	v_across = UV.y;
	v_along = UV.x;
	v_colour = COLOR;
}

void fragment() {
	vec2 uv = vec2(fract(v_along - scroll * fract(v_along)), v_across);
	// Tile the streak texture along the length so a long trail does not stretch.
	vec2 tiled = vec2(fract(v_along * 4.0 - scroll), v_across);
	vec4 s = texture(streak, tiled);
	float across = 1.0 - pow(abs(v_across * 2.0 - 1.0), mix(4.0, 0.7, edge_softness));
	float tip = 1.0 - smoothstep(0.72, 1.0, v_along);
	float a = s.a * across * tip * v_colour.a * opacity;
	ALBEDO = s.rgb * tint.rgb * v_colour.rgb;
	ALPHA = clamp(a, 0.0, 1.0);
}
