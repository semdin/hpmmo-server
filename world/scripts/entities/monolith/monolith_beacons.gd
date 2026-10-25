extends Node3D
class_name MonolithBeacons

## Where the Dark Monoliths come down, seen from across the grounds. A stone is
## only replicated to a client within interest range (about 70 m), so its own
## beam cannot guide anyone from afar: each authored spot (spawn_tables.json
## "monoliths" on the grounds) gets a tall emerald light column of its own,
## which steps aside once the real stone is in view and draws its own beam.
## Eyes only: never built on the dedicated server.

const BEAM_SHADER := """
shader_type spatial;
render_mode unshaded, blend_add, cull_disabled, depth_draw_never, shadows_disabled, fog_disabled;
uniform vec4 colour : source_color = vec4(0.35, 1.0, 0.45, 0.5);
uniform float strength = 1.0;
void fragment() {
	// UV.y runs top (0) to base (1): strongest at the ground, fading upward.
	float rise = pow(UV.y, 1.4);
	// Bright core, soft rim (the cylinder's side seen edge-on fades out).
	float core = pow(abs(dot(NORMAL, VIEW)), 1.6);
	// Slow pulses climbing the column.
	float pulse = 0.72 + 0.28 * sin(UV.y * 36.0 + TIME * 2.6);
	ALBEDO = colour.rgb;
	ALPHA = clamp(colour.a * strength * rise * core * pulse, 0.0, 1.0);
}
"""

static var _shader: Shader = null

## One light column: `height` metres tall from its base, `radius` at the base.
static func beam(colour: Color, height: float, radius: float, alpha: float) -> MeshInstance3D:
	if _shader == null:
		_shader = Shader.new()
		_shader.code = BEAM_SHADER
	var mesh := CylinderMesh.new()
	mesh.top_radius = radius * 0.35
	mesh.bottom_radius = radius
	mesh.height = height
	mesh.radial_segments = 16
	mesh.rings = 1
	mesh.cap_top = false
	mesh.cap_bottom = false
	var mat := ShaderMaterial.new()
	mat.shader = _shader
	mat.set_shader_parameter("colour", Color(colour.r, colour.g, colour.b, alpha))
	mesh.material = mat
	var mi := MeshInstance3D.new()
	mi.mesh = mesh
	mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	mi.position = Vector3(0, height * 0.5, 0)
	return mi

## The grounds' monolith spots: [[centre on the ground, roam metres], ...].
static func sites() -> Array:
	var out: Array = []
	for entry in HPRules.spawn_tables().get("monoliths", []):
		var raw: Array = entry.get("pos", [0.0, 0.0, 0.0])
		if float(raw[1]) > 185.0:
			continue   # another map (the caverns' seal stones)
		var cfg := HPRules.monolith_type(String(entry.get("type", "dark")))
		var ground := GroundsTerrain.height_at(float(raw[0]), float(raw[2]))
		var y := float(raw[1]) if is_nan(ground) else ground
		out.append([Vector3(float(raw[0]), y, float(raw[2])), float(cfg.get("roam", 30.0))])
	return out

const GLOW := Color(0.35, 1.0, 0.45)
var _beams: Array = []
var _poll := 0.0

func _ready() -> void:
	name = "MonolithBeacons"
	for site in sites():
		var b := beam(GLOW, 170.0, 3.6, 0.75)
		b.position += site[0]
		b.set_meta("site", site)
		add_child(b)
		_beams.append(b)

func _process(delta: float) -> void:
	_poll -= delta
	if _poll > 0.0:
		return
	_poll = 0.5
	var player := SimAuthority.local_player_node()
	# Outdoors only: the castle, the dungeons and the caverns sit far above.
	visible = player != null and (player as Node3D).global_position.y < 185.0
	if not visible:
		return
	var stones: Array = []
	for m in get_tree().get_nodes_in_group("monoliths"):
		if m is Node3D and is_instance_valid(m) and (m as Node3D).is_visible_in_tree() and not bool(m.get("is_destroyed")):
			stones.append((m as Node3D).global_position)
	for b in _beams:
		var site: Array = b.get_meta("site")
		var shown := true
		for at in stones:
			if Vector2(at.x, at.z).distance_to(Vector2(site[0].x, site[0].z)) < float(site[1]) + 15.0:
				shown = false
				break
		b.visible = shown
