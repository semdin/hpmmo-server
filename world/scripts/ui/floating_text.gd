extends Node3D

## Floating Combat Text for Metin2-style damage numbers and notifications
@onready var label: Label3D = $Label3D

var velocity: Vector3 = Vector3(0, 2.5, 0)
var duration: float = 1.0
var elapsed: float = 0.0

func setup(text: String, color: Color = Color.WHITE, scale_mult: float = 1.0) -> void:
	if not is_inside_tree():
		await ready
	label.text = text
	label.modulate = color
	label.scale = Vector3.ONE * scale_mult
	# Add slight horizontal scatter
	velocity.x = randf_range(-0.8, 0.8)
	velocity.z = randf_range(-0.8, 0.8)

func _process(delta: float) -> void:
	elapsed += delta
	position += velocity * delta
	velocity.y -= 1.5 * delta # gentle deceleration
	
	if elapsed >= duration:
		queue_free()
	else:
		var alpha := 1.0 - (elapsed / duration)
		label.modulate.a = alpha
