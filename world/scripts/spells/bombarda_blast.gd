extends Area3D

## Bombarda AOE Explosion - High damage blast with area knockback
## Currently unreferenced (SkillFX handles live impacts); kept gated so it
## cannot bypass faction/safe-zone rules if it is ever wired up again.

const Rules = preload("res://scripts/spells/combat_rules.gd")

var caster: Node3D = null
var base_damage: int = 160
var radius: float = 8.0
var elapsed: float = 0.0

@onready var particles: CPUParticles3D = $CPUParticles3D
@onready var light: OmniLight3D = $OmniLight3D

func setup(p_caster: Node3D, p_damage: int) -> void:
	caster = p_caster
	base_damage = p_damage

func _ready() -> void:
	# Trigger damage on all overlapping bodies
	await get_tree().physics_frame
	var bodies := get_overlapping_bodies()
	for body in bodies:
		if body == caster:
			continue
		if body.has_method("take_damage") and Rules.can_damage(caster, body):
			var dist := global_position.distance_to(body.global_position)
			var falloff: float = clamp(1.0 - (dist / radius), 0.4, 1.0)
			var dmg := int(base_damage * falloff)
			body.take_damage(dmg, "bombarda", caster)
			
			# Knockback
			if body is CharacterBody3D:
				var push_dir := (body.global_position - global_position).normalized()
				push_dir.y = 0.4
				if body.has_method("apply_knockback"):
					body.apply_knockback(push_dir * 14.0)

func _process(delta: float) -> void:
	elapsed += delta
	if light:
		light.light_energy = max(0.0, 5.0 * (1.0 - (elapsed / 0.6)))
	if elapsed >= 1.2:
		queue_free()
