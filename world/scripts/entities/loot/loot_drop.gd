extends Area3D

## A loot chest on the ground (v16): every kill drops ONE chest holding all of
## its item rolls (galleons go straight to the purse). Right-clicking it opens
## the chest window (`LootWindow`); Z takes everything that fits. A plain chest glows warm gold, a chest that holds an
## enchanted (efsun) piece sparkles violet.
## The glow is layered: a real (shadowless) light, a soft pool on the ground,
## a faint rising shaft, drifting motes and a fresnel rim on the model.

const CHEST_MODEL := preload("res://assets/models/environment/loot_chest.glb")
const RIM_SHADER := preload("res://assets/shaders/loot/chest_rim.gdshader")
const GLOW := {"chest": Color(1.0, 0.78, 0.36), "chest_rare": Color(0.66, 0.42, 1.0)}
## Per kind: light energy, pool, beam and rim strength, motes, pulse speed.
const LOOK := {
	"chest": {"light": 1.4, "pool": 1.1, "beam": 0.9, "rim": 0.25, "motes": 10, "speed": 1.6},
	"chest_rare": {"light": 1.8, "pool": 1.2, "beam": 1.2, "rim": 0.35, "motes": 18, "speed": 2.6},
}
const PICK_RANGE := 7.0

@export var item_id: String = "chest"
@export var item_name: String = "Chest"
@export var amount: int = 1
var items: Array = []

@onready var label: Label3D = $Label3D
@onready var particles: CPUParticles3D = $CPUParticles3D
@onready var model_root: Node3D = $Model
@onready var pool: MeshInstance3D = $GlowPool
@onready var beam: MeshInstance3D = $Beam
@onready var light: OmniLight3D = $Light

var is_collected: bool = false
var remaining_lifetime := 90.0
var _pickup_retry_at := 0
var _phase := 0.0
var _rim_meshes: Array = []

func _ready() -> void:
	_phase = randf() * TAU
	input_ray_pickable = false
	add_to_group("loot")
	var model := CHEST_MODEL.instantiate()
	model_root.add_child(model)
	_fit_model(model, 0.9)
	var rim := ShaderMaterial.new()
	rim.shader = RIM_SHADER
	for mesh in model.find_children("*", "MeshInstance3D", true, false):
		(mesh as MeshInstance3D).material_overlay = rim
		_rim_meshes.append(mesh)
	model_root.rotation.y = randf() * TAU
	_update_display()

## Scale an imported model to `width` metres across and stand it on the ground.
func _fit_model(model: Node3D, width: float) -> void:
	var box := AABB()
	var first := true
	for mesh in model.find_children("*", "MeshInstance3D", true, false):
		var local: AABB = (mesh as MeshInstance3D).get_aabb()
		var xf: Transform3D = model.global_transform.affine_inverse() * (mesh as MeshInstance3D).global_transform
		var b := xf * local
		box = b if first else box.merge(b)
		first = false
	if first or box.size.x <= 0.0:
		return
	var s := width / maxf(box.size.x, box.size.z)
	model.scale = Vector3.ONE * s
	model.position = -Vector3(box.get_center().x, box.position.y, box.get_center().z) * s

## Right click on the chest (player._inspect_click_target) opens its window.
func open_window(local_player: Node3D) -> void:
	if local_player == null or is_collected:
		return
	if global_position.distance_to(local_player.global_position) > PICK_RANGE:
		if local_player.has_method("_spawn_floating_text"):
			local_player.call("_spawn_floating_text", "Too far", Color(1.0, 0.85, 0.5), 1.0)
		return
	get_tree().call_group("loot_window", "open_chest", self)

## (Re)describe the chest - called on spawn and whenever a partial take
## changes what it holds.
func setup(p_item_id: String, p_amount: int = 1, p_items: Array = []) -> void:
	item_id = p_item_id if GLOW.has(p_item_id) else "chest"
	amount = p_amount
	items = p_items
	item_name = "Enchanted Chest" if item_id == "chest_rare" else "Chest"
	_update_display()

func _update_display() -> void:
	if not label:
		return
	var glow: Color = GLOW[item_id]
	label.text = item_name
	label.modulate = glow.lightened(0.35)
	var look: Dictionary = LOOK[item_id]
	light.light_color = glow
	for mesh in _rim_meshes:
		(mesh as GeometryInstance3D).set_instance_shader_parameter("tint", glow)
	pool.set_instance_shader_parameter("tint", glow)
	beam.set_instance_shader_parameter("tint", glow)
	_pulse(0.5)
	if particles:
		var rare := item_id == "chest_rare"
		var ramp := Gradient.new()
		ramp.offsets = PackedFloat32Array([0.0, 0.2, 0.7, 1.0])
		var hot := glow.lightened(0.3)
		ramp.colors = PackedColorArray([Color(hot, 0.0), Color(hot, 1.0), Color(glow, 0.7), Color(glow, 0.0)])
		particles.color_ramp = ramp
		particles.amount = look["motes"]
		particles.lifetime = 1.8 if rare else 2.2
		particles.emission_sphere_radius = 0.5 if rare else 0.38
		particles.initial_velocity_max = 0.45 if rare else 0.25
		particles.scale_amount_max = 1.5 if rare else 1.0

## Breathing glow, 0..1: the light, pool, shaft and rim swell together.
func _pulse(t: float) -> void:
	var look: Dictionary = LOOK[item_id]
	light.light_energy = look["light"] * (0.8 + 0.35 * t)
	pool.set_instance_shader_parameter("strength", look["pool"] * (0.75 + 0.35 * t))
	beam.set_instance_shader_parameter("strength", look["beam"] * (0.7 + 0.4 * t))
	for mesh in _rim_meshes:
		(mesh as GeometryInstance3D).set_instance_shader_parameter("strength", look["rim"] * (0.6 + 0.6 * t))

func _process(delta: float) -> void:
	remaining_lifetime -= delta
	if remaining_lifetime <= 0:
		queue_free()
		return
	if is_collected or light == null:
		return
	# A slow breathing glow; the enchanted one pulses faster.
	_pulse(0.5 + 0.5 * sin(Time.get_ticks_msec() * 0.001 * float(LOOK[item_id]["speed"]) + _phase))

## A take is a REQUEST (`slot` = one chest slot, -1 = everything that fits):
## the authority checks range and room, credits the character and answers
## with the updated chest - or removes it once empty.
func collect(collector: Node3D, slot: int = -1) -> bool:
	if is_collected or not is_instance_valid(collector) or not collector.has_method("add_loot"):
		return false
	if "is_local_player" in collector and (not collector.is_local_player or collector.is_dead):
		return false
	var uid: int = get_meta("sim_uid", 0)
	if uid == 0:
		return false
	if not SimAuthority.is_authority() and not SimNet.is_client:
		return false
	if not SimAuthority.is_authority() and Time.get_ticks_msec() < _pickup_retry_at:
		return false
	var result: Dictionary = SimNet.submit_pickup(collector, uid, slot)
	if not SimAuthority.is_authority():
		_pickup_retry_at = Time.get_ticks_msec() + 250
		return true
	return bool(result.get("ok", false)) or String(result.get("reason", "")) == "bag_full"

func despawn() -> void:
	if is_queued_for_deletion():
		return
	is_collected = true
	remove_from_group("loot")
	set_deferred("monitoring", false)
	set_deferred("monitorable", false)
	set_deferred("input_ray_pickable", false)
	if label:
		label.visible = false
	if particles:
		particles.emitting = false
	if light:
		light.visible = false
	var tween := create_tween().set_parallel(true)
	tween.tween_property(self, "scale", Vector3.ZERO, 0.25).set_ease(Tween.EASE_IN).set_trans(Tween.TRANS_BACK)
	tween.tween_property(self, "position:y", position.y + 0.4, 0.25)
	tween.chain().tween_callback(queue_free)
