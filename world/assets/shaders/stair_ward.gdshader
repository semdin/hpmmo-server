shader_type spatial;
// The magical staircases' boarding ward (scripts/world/castle/magical_staircase.gd):
// a curtain of light across a gate that sinks into the floor when the flight
// may be boarded and rises again, slowly, during the boarding warning.
//   closed 0..1 - how far the curtain stands (0 = sunk, gate open)
//   tint        - state colour (gold open / amber warning / violet sealed)
// QuadMesh UV: x across the gate, y = 0 at the top.
render_mode unshaded, blend_add, cull_disabled, depth_draw_never, shadows_disabled, fog_disabled;

uniform sampler2D rune : source_color, repeat_enable, filter_linear_mipmap;
uniform vec4 tint : source_color = vec4(1.0, 0.75, 0.35, 1.0);
uniform float closed = 1.0;
uniform float pulse = 0.0;
uniform float width_m = 3.0;
uniform float height_m = 1.6;

float h(vec2 p) { return fract(sin(dot(p, vec2(127.1, 311.7))) * 43758.5453); }

void fragment() {
	float up = 1.0 - UV.y;                       // 0 at the floor, 1 at the top
	float top = closed;                          // the curtain's current crest
	float body = step(up, top);
	float crest = exp(-pow((up - top) / 0.035, 2.0)) * step(0.02, closed);
	// rune band riding a little below the crest, drifting sideways
	float band_v = (top - up) / 0.42;
	vec2 ruv = vec2(UV.x * width_m / (0.42 * 5.14) + TIME * 0.06, clamp(band_v, 0.0, 1.0));
	float runes = texture(rune, ruv).r * step(0.0, band_v) * step(band_v, 1.0);
	// rising motes / streaks
	float col_id = floor(UV.x * width_m * 6.0);
	float streak = pow(fract(up * 1.3 - TIME * (0.35 + h(vec2(col_id, 3.0)) * 0.4) + h(vec2(col_id, 7.0))), 14.0);
	streak *= step(0.55, h(vec2(col_id, 11.0)));
	// soft floor glow and side posts of light
	float base = exp(-up * 5.0) * 0.55;
	float sides = exp(-min(UV.x, 1.0 - UV.x) * width_m * 7.0);
	float fade = smoothstep(0.0, 0.08, closed);
	float a = body * (0.06 + runes * 0.8 + streak * 0.35 + base + sides * 0.45) + crest * 1.2;
	a *= fade * (0.75 + 0.25 * sin(TIME * 2.0)) * (1.0 + pulse * 0.9);
	ALBEDO = tint.rgb * a * 1.6;
}
