extends Node3D
class_name TravelNodes

## The Floo Network's fireplaces in the world (data/travel.json), client side:
## the hearth model with a small fire in it at every node, shown only while its
## map is the resident one, and the green Floo flames (`burst`) a traveller
## steps into and out of. The authority decides every trip
## (authority.gd request_travel); the map controller asks this node which
## hearth the local body stands at.

const FIREPLACE := "res://assets/models/travel/floo_fireplace.glb"
const FLAME_SHADER := preload("res://assets/shaders/castle/candle_flame.gdshader")
const QualityPreset = preload("res://scripts/world/quality_preset.gd")
const FLOO_GREEN := Color(0.35, 1.0, 0.45)
## The baked model is 2.7 m tall; a walk-in hearth reads better a bit larger.
const HEARTH_SCALE := 1.25

var _hearths: Dictionary = {}   # node id -> Node3D
var _map := ""

func _ready() -> void:
	name = "TravelNodes"
	var model: PackedScene = load(FIREPLACE) if ResourceLoader.exists(FIREPLACE) else null
	for id in HPMaps.travel_nodes().keys():
		var data: Dictionary = HPMaps.travel_nodes()[id]
		var root := Node3D.new()
		root.name = "Hearth_" + String(id)
		root.set_meta("map", String(data.get("map", "")))
		add_child(root)
		root.global_position = point(data)
		root.rotation.y = deg_to_rad(float(data.get("yaw", 0.0)))
		if model != null:
			var body: Node3D = model.instantiate()
			body.scale = Vector3.ONE * HEARTH_SCALE
			root.add_child(body)
		_hearth_fire(root)
		_hearths[String(id)] = root
	show_map(HPProtocol.DEFAULT_MAP)

## Where a node stands (the grounds' authored points are x/z on the terrain).
static func point(data: Dictionary) -> Vector3:
	var raw: Array = data.get("pos", [0.0, 0.0, 0.0])
	var at := Vector3(float(raw[0]), float(raw[1]), float(raw[2]))
	if String(data.get("map", "")) == HPProtocol.DEFAULT_MAP:
		var h := GroundsTerrain.height_at(at.x, at.z)
		if not is_nan(h):
			at.y = h
	return at

## Only the resident map's hearths are drawn (the maps share x/z).
func show_map(map_id: String) -> void:
	_map = HPMaps.base_map(map_id)
	for id in _hearths:
		var root: Node3D = _hearths[id]
		root.visible = String(root.get_meta("map", "")) == _map

## The fireplace the body stands at on `map_id`, or "".
func node_at(pos: Vector3, map_id: String) -> String:
	var radius := float(HPMaps.floo_rules().get("radius", 3.2))
	for id in _hearths:
		var root: Node3D = _hearths[id]
		if String(root.get_meta("map", "")) != HPMaps.base_map(map_id):
			continue
		var d := pos - root.global_position
		if Vector2(d.x, d.z).length() <= radius and absf(d.y) < 3.5:
			return String(id)
	return ""

## A low fire in the hearth: three flame cards and (not on low) a warm light.
func _hearth_fire(root: Node3D) -> void:
	for k in 3:
		_flame(root, Vector3((float(k) - 1.0) * 0.28, 0.42 + 0.06 * (k % 2), 0.05) * HEARTH_SCALE, Vector2(0.45, 0.7) * HEARTH_SCALE, Color(1, 1, 1), 3.4)
	if QualityPreset.current() != "low":
		var light := OmniLight3D.new()
		light.light_color = Color(1.0, 0.55, 0.25)
		light.light_energy = 1.6
		light.omni_range = 7.0
		light.position = Vector3(0, 0.8, 0.9)
		root.add_child(light)

static func _flame(parent: Node3D, pos: Vector3, size: Vector2, tint: Color, intensity: float) -> MeshInstance3D:
	var mi := MeshInstance3D.new()
	var quad := QuadMesh.new()
	quad.size = size
	var fire := ShaderMaterial.new()
	fire.shader = FLAME_SHADER
	fire.set_shader_parameter("bob_height", 0.0)
	fire.set_shader_parameter("intensity", intensity)
	if tint != Color(1, 1, 1):
		fire.set_shader_parameter("tint", tint)
	quad.material = fire
	mi.mesh = quad
	mi.position = pos
	mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	parent.add_child(mi)
	return mi

## The Floo flames: a column of green fire roaring up around `at` (a body
## stepping into or out of a hearth), with sparks and a green flash. Frees
## itself after `seconds`.
static func burst(parent: Node, at: Vector3, seconds: float = 2.2) -> void:
	if parent == null:
		return
	var root := Node3D.new()
	root.name = "FlooFlames"
	parent.add_child(root)
	root.global_position = at
	var cards: Array = []
	for k in 6:
		var a := TAU * float(k) / 6.0
		var card := _flame(root, Vector3(cos(a) * 0.45, 1.1, sin(a) * 0.45), Vector2(1.3, 2.6), FLOO_GREEN, 6.0)
		card.rotation.y = -a
		card.scale = Vector3(0.1, 0.1, 0.1)
		cards.append(card)
	var core := _flame(root, Vector3(0, 1.0, 0), Vector2(1.6, 2.4), Color(0.75, 1.0, 0.7), 7.0)
	core.scale = Vector3(0.1, 0.1, 0.1)
	cards.append(core)
	var sparks := CPUParticles3D.new()
	sparks.amount = 60
	sparks.lifetime = 1.1
	sparks.one_shot = true
	sparks.explosiveness = 0.6
	sparks.emission_shape = CPUParticles3D.EMISSION_SHAPE_RING
	sparks.emission_ring_radius = 0.6
	sparks.emission_ring_inner_radius = 0.2
	sparks.emission_ring_height = 0.2
	sparks.emission_ring_axis = Vector3.UP
	sparks.direction = Vector3.UP
	sparks.spread = 25.0
	sparks.initial_velocity_min = 2.5
	sparks.initial_velocity_max = 5.5
	sparks.gravity = Vector3(0, -1.5, 0)
	sparks.scale_amount_min = 0.04
	sparks.scale_amount_max = 0.09
	var mote := SphereMesh.new()
	mote.radius = 0.5
	mote.height = 1.0
	mote.radial_segments = 6
	mote.rings = 3
	var mm := StandardMaterial3D.new()
	mm.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	mm.albedo_color = Color(0.6, 1.0, 0.55)
	mm.emission_enabled = true
	mm.emission = FLOO_GREEN
	mm.emission_energy_multiplier = 3.0
	mote.material = mm
	sparks.mesh = mote
	sparks.position = Vector3(0, 0.2, 0)
	root.add_child(sparks)
	sparks.emitting = true
	var light := OmniLight3D.new()
	light.light_color = FLOO_GREEN
	light.light_energy = 0.0
	light.omni_range = 9.0
	light.position = Vector3(0, 1.4, 0)
	root.add_child(light)
	var tw := root.create_tween()
	tw.set_parallel(true)
	for card in cards:
		tw.tween_property(card, "scale", Vector3.ONE, 0.35).set_trans(Tween.TRANS_BACK).set_ease(Tween.EASE_OUT)
	tw.tween_property(light, "light_energy", 5.0, 0.25)
	tw.chain().tween_interval(maxf(0.2, seconds - 0.9))
	tw.chain().set_parallel(true)
	for card in cards:
		tw.tween_property(card, "scale", Vector3(0.05, 1.4, 0.05), 0.55).set_ease(Tween.EASE_IN)
	tw.tween_property(light, "light_energy", 0.0, 0.55)
	tw.chain().tween_callback(root.queue_free)
	var audio := parent.get_node_or_null("/root/AudioManager")
	if audio != null and audio.has_method("play_sound_at"):
		audio.call("play_sound_at", "floo_whoosh", at, null, false)
