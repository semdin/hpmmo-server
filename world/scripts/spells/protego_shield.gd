extends Area3D

## Protego Shield - Deflects incoming enemy spells and provides damage resistance

@export var duration: float = 3.5
var caster: Node3D = null
var elapsed: float = 0.0

@onready var mesh: MeshInstance3D = $MeshInstance3D
@onready var light: OmniLight3D = $OmniLight3D

func setup(p_caster: Node3D) -> void:
	caster = p_caster

func _process(delta: float) -> void:
	elapsed += delta
	if is_instance_valid(caster):
		global_position = caster.global_position + Vector3(0, 1.0, 0)
	
	rotate_y(delta * 1.5)
	
	if elapsed >= duration:
		queue_free()
	else:
		# Pulsing shield intensity
		var pulse := (sin(elapsed * 8.0) * 0.2) + 0.8
		if light:
			light.light_energy = 2.5 * pulse
