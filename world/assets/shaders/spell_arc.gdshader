shader_type spatial;
// An electric arc (spell_effect `arc` layers): a camera-facing strip laid along
// a jagged polyline that spell_effect re-strikes several times a second. The
// shape is in the geometry; this only draws its light across the strip - a
// white-hot filament in a coloured glow - in screen pixels, so the filament
// stays one unbroken line at any range. Additive: an arc is light.
render_mode unshaded, cull_disabled, depth_draw_never, shadows_disabled, blend_add;

uniform vec4 tint : source_color = vec4(1.0, 0.15, 0.15, 1.0);
uniform float opacity : hint_range(0.0, 2.0) = 1.0;
// Filament half-width in pixels (0: glow only); the glow is the rest of the strip.
uniform float core_px = 1.6;
uniform float glow = 0.55;

varying float v_across;
varying vec4 v_colour;

void vertex() {
	v_across = UV.y;
	v_colour = COLOR;
}

void fragment() {
	float f = v_across - 0.5;
	float px = abs(f) / max(fwidth(f), 0.00001);
	float core = core_px > 0.0 ? exp(-pow(px / core_px, 2.0)) : 0.0;
	float halo = exp(-f * f * 48.0);
	ALBEDO = tint.rgb * (1.4 + halo * 0.6) + vec3(core * 1.8);
	ALPHA = clamp((core + halo * glow) * v_colour.a * opacity * tint.a, 0.0, 1.0);
}
