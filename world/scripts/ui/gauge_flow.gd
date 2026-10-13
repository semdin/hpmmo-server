extends Control
class_name GaugeFlow

## The living fill of a HUD gauge: a glossy body in the gauge's colour with
## slow, swirling energy flowing through it, a light sheen that sweeps across
## every few seconds and a bright leading edge where the fill ends.
##
## It is a child of the `ProgressBar` it decorates and only ever reads the bar:
## the bar keeps the authoritative value (and the checks keep reading it), this
## draws the filled part. The bar's own fill style is cleared so the two never
## double up.

const SHADER := """
shader_type canvas_item;

uniform vec4 base_color : source_color = vec4(0.8, 0.1, 0.1, 1.0);
uniform vec2 rect_size = vec2(200.0, 18.0);
uniform float flow_speed = 1.0;
uniform float seed = 0.0;

float hash(vec2 p) {
	p = fract(p * vec2(123.34, 456.21));
	p += dot(p, p + 45.32);
	return fract(p.x * p.y);
}

float vnoise(vec2 p) {
	vec2 i = floor(p);
	vec2 f = fract(p);
	vec2 u = f * f * (3.0 - 2.0 * f);
	return mix(mix(hash(i), hash(i + vec2(1.0, 0.0)), u.x),
		mix(hash(i + vec2(0.0, 1.0)), hash(i + vec2(1.0, 1.0)), u.x), u.y);
}

float fbm(vec2 p) {
	float v = 0.0;
	float a = 0.5;
	for (int i = 0; i < 4; i++) {
		v += a * vnoise(p);
		p = p * 2.03 + vec2(1.7, 9.2);
		a *= 0.5;
	}
	return v;
}

void fragment() {
	vec2 px = UV * rect_size;
	float y = UV.y;
	float t = TIME * flow_speed + seed;
	vec3 base = base_color.rgb;

	// Body: lit top, deep foot.
	vec3 col = base * mix(1.25, 0.50, smoothstep(0.05, 1.0, y));

	// Swirling energy, two layers drifting against each other.
	vec2 q = vec2(px.x / 26.0, y * 1.4);
	float n1 = fbm(q + vec2(-t * 0.55, t * 0.12));
	float n2 = fbm(q * 1.7 + vec2(t * 0.38, -t * 0.18) + 11.0);
	float wisp = smoothstep(0.42, 0.80, n1 * 0.65 + n2 * 0.45);
	float vein = smoothstep(0.03, 0.0, abs(n1 - n2 * 0.9 - 0.06)) * 0.8;
	col += base * wisp * 0.75 + vec3(wisp * 0.10);
	col += mix(base, vec3(1.0), 0.55) * vein * 0.45;

	// Glass: a gloss band on the upper half and a thin highlight on the rim.
	col += vec3(0.30) * smoothstep(0.52, 0.10, y) * 0.55;
	col += vec3(0.35) * (1.0 - smoothstep(0.0, 1.5 / rect_size.y, y));

	// A sheen sweeping left to right every few seconds.
	float span = rect_size.x + 160.0;
	float sx = mod(TIME * 85.0 + seed * 40.0, span + 400.0) - 80.0;
	float d = (px.x - sx) + (y - 0.5) * 14.0;
	col += vec3(0.40) * exp(-d * d / 180.0);

	// Leading edge: a bright seam where the fill ends.
	float edge = exp(-(rect_size.x - px.x) / 3.0);
	col += mix(base, vec3(1.0), 0.6) * edge * 0.9;

	// Foot shadow so the bar sits in its track.
	col *= mix(1.0, 0.65, smoothstep(0.80, 1.0, y));
	COLOR = vec4(col, base_color.a);
}
"""

static var _shader: Shader = null

var bar: ProgressBar = null
var colour := Color(0.8, 0.1, 0.1)
var _mat: ShaderMaterial = null
var _last_w := -1.0

static func attach(p_bar: ProgressBar, p_colour: Color, speed: float = 1.0) -> GaugeFlow:
	var existing := p_bar.get_node_or_null("Flow") as GaugeFlow
	if existing != null:
		existing.set_colour(p_colour)
		return existing
	var flow := GaugeFlow.new()
	flow.name = "Flow"
	flow.bar = p_bar
	flow.colour = p_colour
	p_bar.add_child(flow)
	p_bar.move_child(flow, 0)   # under the lag band and the numbers
	p_bar.add_theme_stylebox_override("fill", StyleBoxEmpty.new())
	flow._mat.set_shader_parameter("flow_speed", speed)
	return flow

func _init() -> void:
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	if _shader == null:
		_shader = Shader.new()
		_shader.code = SHADER
	_mat = ShaderMaterial.new()
	_mat.shader = _shader
	_mat.set_shader_parameter("seed", randf() * 10.0)
	material = _mat

func _ready() -> void:
	set_colour(colour)

func set_colour(c: Color) -> void:
	colour = c
	if _mat != null:
		_mat.set_shader_parameter("base_color", c)

func _process(_delta: float) -> void:
	if bar == null or not is_instance_valid(bar):
		return
	var ratio := clampf((bar.value - bar.min_value) / maxf(0.0001, bar.max_value - bar.min_value), 0.0, 1.0)
	var w := floorf(bar.size.x * ratio)
	position = Vector2.ZERO
	size = Vector2(w, bar.size.y)
	visible = w > 0.5
	if w != _last_w:
		_last_w = w
		_mat.set_shader_parameter("rect_size", Vector2(maxf(w, 1.0), bar.size.y))

func _draw() -> void:
	draw_rect(Rect2(Vector2.ZERO, size), Color.WHITE)
