extends Area3D

const SkillFX = preload("res://scripts/spells/skill_fx.gd")
const Rules = preload("res://scripts/spells/combat_rules.gd")
const ParticleKit = preload("res://scripts/assets/particle_kit.gd")
@export var speed := 40.0
@export var damage := 40
@export var spell_id := "basic_cast"
@export var spell_color := Color(1, 0.85, 0.4)
@export var max_lifetime := 4.0
var direction := Vector3.FORWARD
var caster: Node3D
var target_node: Node3D
var lifetime := 0.0
var spent := false
var visual_only := false
var _base_scale := Vector3.ONE
var _reflection_grace := 0.0
@onready var mesh: MeshInstance3D = $MeshInstance3D
@onready var light: OmniLight3D = $OmniLight3D
@onready var particles: CPUParticles3D = $CPUParticles3D

func _ready() -> void:
	body_entered.connect(_on_body_entered)
	area_entered.connect(_on_area_entered)
	collision_mask = 3

func setup(source: Node3D, id: String, aim: Vector3, target: Node3D = null, bonus_mult: float = 1.0) -> void:
	caster = source
	spell_id = id
	direction = aim.normalized() if aim.length_squared() > 0.001 else Vector3.FORWARD
	target_node = target
	var data: Dictionary = GameData.SPELLS.get(id, {})
	damage = int(data.get("damage", 40) * bonus_mult)
	speed = float(data.get("projectile_speed", 40))
	max_lifetime = float(data.get("range", 36)) / speed
	spell_color = data.get("color", Color.WHITE)
	var mat := StandardMaterial3D.new()
	mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	mat.albedo_color = spell_color
	mesh.material_override = mat
	_base_scale = Vector3(0.7, 0.7, 1.8) if id == "basic_cast" else Vector3(1.1, 1.1, 2.4)
	light.light_color = spell_color
	light.light_energy = 1.5
	light.omni_range = 4.0
	ParticleKit.configure(particles, id == "incendio")
	particles.color = spell_color
	SkillFX.play_cast(get_parent(), caster, id, global_position, direction)

func _physics_process(delta: float) -> void:
	if spent:
		return
	lifetime += delta
	_reflection_grace = maxf(0, _reflection_grace - delta)
	if lifetime >= max_lifetime:
		if spell_id in ["bombarda", "ultimate"]:
			_handle_hit(null)
		else:
			queue_free()
		return
	var next := global_position + direction * speed * delta
	# Swept ray prevents fast spells tunnelling through thin walls/enemies.
	var query := PhysicsRayQueryParameters3D.create(global_position, next, 3)
	var excluded: Array[RID] = [get_rid()]
	for npc in get_tree().get_nodes_in_group("npcs"):
		excluded.append(npc.get_rid())
	for player in get_tree().get_nodes_in_group("players"):
		if player == caster or (is_instance_valid(caster) and caster.is_in_group("players")):
			excluded.append(player.get_rid())
	if is_instance_valid(caster) and caster is CollisionObject3D:
		excluded.append(caster.get_rid())
	if is_instance_valid(caster) and caster.is_in_group("mobs"):
		for mob in get_tree().get_nodes_in_group("mobs"):
			excluded.append(mob.get_rid())
	query.exclude = excluded
	var hit := get_world_3d().direct_space_state.intersect_ray(query)
	if not hit.is_empty():
		global_position = hit.position
		_on_body_entered(hit.collider)
	else:
		global_position = next
	look_at(global_position + direction, Rules.safe_up(direction))
	mesh.scale = _base_scale * (1 + sin(lifetime * 25) * 0.1)

func _on_body_entered(body: Node3D) -> void:
	if spent or body == caster:
		return
	if body.has_method("take_damage") and not Rules.can_damage(caster, body):
		return
	if "is_protego_active" in body and body.is_protego_active:
		_reflect_projectile(body)
		return
	_handle_hit(body)

func _on_area_entered(area: Area3D) -> void:
	if area.is_in_group("shields") and Rules.can_damage(caster, area.get_parent()):
		_reflect_projectile(area.get_parent())

func _reflect_projectile(owner_node: Node3D) -> void:
	if spent or _reflection_grace > 0:
		return
	direction = -direction
	caster = owner_node
	_reflection_grace = 0.12
	speed *= 1.1

func _handle_hit(target: Node) -> void:
	if spent:
		return
	spent = true
	if not visual_only:
		if spell_id in ["bombarda", "ultimate"]:
			var radius := float(GameData.SPELLS[spell_id].get("radius", 9))
			for enemy in get_tree().get_nodes_in_group("targetable"):
				if not Rules.can_damage(caster, enemy):
					continue
				var distance: float = global_position.distance_to(enemy.global_position + Vector3.UP)
				if distance <= radius and Rules.has_line_of_sight(self, enemy):
					_damage_target(enemy, int(damage * clampf(1 - distance / radius, 0.4, 1)))
		elif Rules.can_damage(caster, target):
			_damage_target(target, damage)
	SkillFX.play_impact(get_parent(), global_position, spell_id)
	queue_free()

func _damage_target(target: Node3D, amount: int) -> void:
	target.take_damage(amount, spell_id, caster)
	if spell_id in ["bombarda", "expelliarmus"] and target.has_method("apply_knockback"):
		var push := (target.global_position - global_position).normalized()
		target.apply_knockback(Vector3(push.x, 0.15, push.z) * 10)
	var text := preload("res://scenes/ui/floating_text.tscn").instantiate()
	get_parent().add_child(text)
	text.global_position = target.global_position + Vector3(0, 1.8, 0)
	text.setup(str(amount), spell_color, 1.2)
