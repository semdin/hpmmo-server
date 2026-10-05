extends Area3D

## 3D Loot Drop that spawns from shattered Dark Monoliths and defeated mobs
## Can be picked up by pressing Z (Metin2 pickup key) or walking near it

@export var item_id: String = "potion_health"
@export var item_name: String = "Wiggenweld Potion"
@export var amount: int = 1
@export var item_type: String = "consumable"

@onready var label: Label3D = $Label3D
@onready var mesh: MeshInstance3D = $MeshInstance3D
@onready var particles: CPUParticles3D = $CPUParticles3D

var float_offset: float = 0.0
var base_y: float = 0.0
var is_collected: bool = false
var remaining_lifetime := 90.0

func _ready() -> void:
	base_y = global_position.y
	float_offset = randf() * TAU
	body_entered.connect(_on_body_entered)
	input_event.connect(_on_input_event)
	add_to_group("loot")
	_update_display()
	call_deferred("_check_initial_overlap")

func _check_initial_overlap() -> void:
	if is_collected:
		return
	for body in get_overlapping_bodies():
		if body.is_in_group("players"):
			collect(body)
			break

func _on_input_event(_camera: Camera3D, event: InputEvent, _position: Vector3, _normal: Vector3, _shape_idx: int) -> void:
	if event is InputEventMouseButton and event.button_index == MOUSE_BUTTON_LEFT and event.pressed:
		var local_player = SimAuthority.local_player_node()
		if local_player and global_position.distance_to(local_player.global_position) <= 7.0:
			collect(local_player)

func setup(p_item_id: String, p_amount: int = 1) -> void:
	item_id = p_item_id
	amount = p_amount
	if GameData.ITEMS.has(item_id):
		var data: Dictionary = GameData.ITEMS[item_id]
		item_name = data.name
		item_type = data.type
		if mesh and data.has("icon_color"):
			var mat: StandardMaterial3D = mesh.get_active_material(0)
			if mat:
				mat = mat.duplicate()
				mesh.material_override = mat
				mat.albedo_color = data.icon_color
	elif item_id == "galleons":
		item_name = "Galleons"
		item_type = "currency"
	
	_update_display()

func _update_display() -> void:
	if not label:
		return
	if item_id == "galleons":
		label.text = "%d Galleons" % amount
		label.modulate = Color(1.0, 0.85, 0.2)
	elif amount > 1:
		label.text = "%s (x%d)" % [item_name, amount]
		label.modulate = Color(1.0, 1.0, 1.0)
	else:
		label.text = item_name
		label.modulate = Color(0.9, 0.9, 1.0)

func _process(delta: float) -> void:
	remaining_lifetime -= delta
	if remaining_lifetime <= 0:
		queue_free()
		return
	if is_collected:
		return
	# Gentle rotation and bobbing
	mesh.rotate_y(delta * 2.0)
	var bob := sin(Time.get_ticks_msec() * 0.003 + float_offset) * 0.15
	mesh.position.y = 0.4 + bob
	label.position.y = 1.0 + bob

## A pickup is a REQUEST: the authority checks the range, credits the item to
## the character and removes the drop. It answers with the item having left the
## ground, which is when this view disappears.
func collect(collector: Node3D) -> bool:
	if is_collected or not is_instance_valid(collector) or not collector.has_method("add_loot"):
		return false
	if "is_local_player" in collector and (not collector.is_local_player or collector.is_dead):
		return false
	var uid: int = get_meta("sim_uid", 0)
	if uid == 0:
		return false
	if not SimAuthority.is_authority() and not SimNet.is_client:
		return false
	var result: Dictionary = SimNet.submit_pickup(collector, uid)
	if not bool(result.get("ok", false)):
		return false
	is_collected = true
	if not SimAuthority.is_authority():
		collector.add_loot(item_id, amount)
	# Pickup feedback (the credit itself is authoritative).
	var ft_scene = load("res://scenes/ui/floating_text.tscn")
	if ft_scene:
		var ft = ft_scene.instantiate()
		get_parent().add_child(ft)
		ft.global_position = global_position + Vector3(0, 1.0, 0)
		ft.setup("+ " + label.text, Color(1.0, 0.9, 0.3), 1.2)
	if Engine.has_singleton("AudioManager"):
		var am = Engine.get_singleton("AudioManager")
		if am and am.has_method("play_loot"):
			am.play_loot()
	elif AudioManager and AudioManager.has_method("play_loot"):
		AudioManager.play_loot()
	despawn()
	return true

func despawn() -> void:
	if is_queued_for_deletion():
		return
	is_collected = true
	remove_from_group("loot")
	set_deferred("monitoring", false)
	set_deferred("monitorable", false)
	var col := get_node_or_null("CollisionShape3D") as CollisionShape3D
	if col:
		col.set_deferred("disabled", true)
	if label:
		label.visible = false
	if particles:
		particles.emitting = false
	var tween := create_tween().set_parallel(true)
	tween.tween_property(self, "scale", Vector3.ZERO, 0.2).set_ease(Tween.EASE_IN).set_trans(Tween.TRANS_BACK)
	tween.tween_property(self, "position:y", position.y + 0.6, 0.2)
	tween.chain().tween_callback(queue_free)

func _on_body_entered(body: Node3D) -> void:
	if body.is_in_group("players"):
		collect(body)
