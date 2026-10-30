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
// Kinked mode (a spark's trail): no streak texture, one hairline filament that
// bends in sharp kinks across the strip, re-struck ~14 times a second. The strip
// is rebuilt along the bolt's real path, so the filament bends with its flight.
uniform bool kinked = false;
uniform float seed = 0.0;
// How often the kinks are re-struck; 0 holds the last shape (a retired wake).
uniform float strike_hz = 14.0;
uniform float strike_hold = 0.0;

varying float v_across;
varying float v_along;
varying float v_metres;
varying vec4 v_colour;

float hash11(float n) {
	return fract(sin(n * 127.1 + seed * 311.7) * 43758.5453);
}

// Piecewise-linear noise in -1..1: straight runs between sharp kinks.
float kinks(float x) {
	float i = floor(x);
	return mix(hash11(i), hash11(i + 1.0), fract(x)) * 2.0 - 1.0;
}

void vertex() {
	v_across = UV.y;
	v_along = UV.x;
	v_metres = UV2.x;   // metres back from the head (spell_effect._update_ribbon)
	v_colour = COLOR;
}

void fragment() {
	if (kinked) {
		float t = strike_hz > 0.0 ? floor(TIME * strike_hz) : strike_hold;
		// Pinned at the head, bending more further back.
		float bend = kinks(v_metres * 9.0 + t * 0.71) * 0.8 + kinks(v_metres * 30.0 + t * 1.3) * 0.2;
		float centre = 0.5 + bend * 0.28 * smoothstep(0.0, 0.2, v_metres);
		// Distance in screen pixels, so a steep kink stays one unbroken hairline
		// (a distance across the strip thinned it to gaps) and the line holds
		// its width at any range.
		float f = v_across - centre;
		float px = abs(f) / max(length(vec2(dFdx(f), dFdy(f))), 0.00001);
		float fil = exp(-px * px * 0.3) + exp(-px * px * 0.025) * 0.18;
		ALBEDO = tint.rgb * 1.6 + vec3(exp(-px * px * 1.1) * 0.8);
		ALPHA = clamp(fil * v_colour.a * opacity, 0.0, 1.0);
	} else {
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
}
