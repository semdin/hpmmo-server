extends Area3D

## A loot chest on the ground (v16): every kill drops ONE chest holding all of
## its rolls. Clicking it opens the chest window (`LootWindow`); Z takes
## everything that fits. A plain chest glows warm gold, a chest that holds an
## enchanted (efsun) piece sparkles violet.

const CHEST_MODEL := preload("res://assets/models/environment/chest.glb")
const GLOW := {"chest": Color(1.0, 0.8, 0.32), "chest_rare": Color(0.72, 0.4, 1.0)}
const PICK_RANGE := 7.0

@export var item_id: String = "chest"
@export var item_name: String = "Chest"
@export var amount: int = 1
var items: Array = []

@onready var label: Label3D = $Label3D
@onready var particles: CPUParticles3D = $CPUParticles3D
@onready var model_root: Node3D = $Model
@onready var ring: MeshInstance3D = $GlowRing

var is_collected: bool = false
var remaining_lifetime := 90.0
var _pickup_retry_at := 0
var _phase := 0.0

func _ready() -> void:
	_phase = randf() * TAU
	input_event.connect(_on_input_event)
	add_to_group("loot")
	var model := CHEST_MODEL.instantiate()
	model_root.add_child(model)
	_fit_model(model, 0.75)
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

func _on_input_event(_camera: Camera3D, event: InputEvent, _position: Vector3, _normal: Vector3, _shape_idx: int) -> void:
	if event is InputEventMouseButton and event.button_index == MOUSE_BUTTON_LEFT and event.pressed:
		var local_player = SimAuthority.local_player_node()
		if local_player == null or is_collected:
			return
		if global_position.distance_to(local_player.global_position) > PICK_RANGE:
			if local_player.has_method("_spawn_floating_text"):
				local_player.call("_spawn_floating_text", "Too far", Color(1.0, 0.85, 0.5), 1.0)
			return
		get_viewport().set_input_as_handled()
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
	if ring:
		var mat := ring.material_override as StandardMaterial3D
		if mat == null:
			mat = (ring.mesh.surface_get_material(0) as StandardMaterial3D).duplicate()
			ring.material_override = mat
		mat.albedo_color = Color(glow, 0.55)
	if particles:
		var pmat := (particles.mesh.surface_get_material(0) as StandardMaterial3D).duplicate()
		pmat.albedo_color = glow
		particles.material_override = pmat
		var rare := item_id == "chest_rare"
		particles.amount = 22 if rare else 10
		particles.lifetime = 1.4 if rare else 1.1
		particles.emission_sphere_radius = 0.55 if rare else 0.4
		particles.scale_amount_max = 1.6 if rare else 1.0

func _process(delta: float) -> void:
	remaining_lifetime -= delta
	if remaining_lifetime <= 0:
		queue_free()
		return
	if is_collected or ring == null:
		return
	# A slow breathing glow under the chest; the enchanted one pulses faster.
	var speed := 4.0 if item_id == "chest_rare" else 2.0
	var pulse := 0.5 + 0.5 * sin(Time.get_ticks_msec() * 0.001 * speed + _phase)
	ring.scale = Vector3.ONE * (0.9 + 0.2 * pulse)
	(ring.material_override as StandardMaterial3D).albedo_color.a = 0.35 + 0.35 * pulse

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
	var tween := create_tween().set_parallel(true)
	tween.tween_property(self, "scale", Vector3.ZERO, 0.25).set_ease(Tween.EASE_IN).set_trans(Tween.TRANS_BACK)
	tween.tween_property(self, "position:y", position.y + 0.4, 0.25)
	tween.chain().tween_callback(queue_free)
