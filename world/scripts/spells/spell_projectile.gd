extends Area3D

const SkillFX = preload("res://scripts/spells/skill_fx.gd")
const Rules = preload("res://scripts/spells/combat_rules.gd")
const VFX = preload("res://scripts/spells/vfx_library.gd")
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
@onready var travel_slot: Node3D = get_node_or_null("TravelFx")
## The travel stage (authored core mesh, tapered ribbon, wisps) is
## built by the effect scene and parented here, so it dies with the bolt.
var travel_effect: Node3D

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
	# The placeholder sphere is replaced by the authored carrier core;
	# the layered travel stage (ribbon + wisps) rides along with it.
	var core_scene := load(VFX.asset_path("vfx_projectile_mesh")) as PackedScene
	if core_scene != null:
		var core_node := core_scene.instantiate()
		var found := _find_mesh(core_node)
		if found != null:
			mesh.mesh = found.mesh
		core_node.free()
	var mat := StandardMaterial3D.new()
	mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	mat.blend_mode = BaseMaterial3D.BLEND_MODE_ADD
	mat.emission_enabled = true
	mat.emission = spell_color
	mat.emission_energy_multiplier = 2.0
	mat.albedo_color = spell_color
	mesh.material_override = mat
	_base_scale = Vector3(0.7, 0.7, 1.0) if id == "basic_cast" else Vector3(1.1, 1.1, 1.0)
	light.light_color = spell_color
	light.light_energy = 1.5
	light.omni_range = 4.0
	travel_effect = SkillFX.spawn_stage(travel_slot if travel_slot != null else get_parent(),
		id, "travel", global_position, direction, caster, {"follow_target": self})
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
			# out of range: the travel stage is cancelled, never left running
			if travel_effect != null and is_instance_valid(travel_effect):
				travel_effect.call("cancel", "out_of_range")
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
	# a gentle pulse, never an abrupt on/off
	mesh.scale = _base_scale * (1 + sin(lifetime * 18.0) * 0.06)

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

## The projectile is a VIEW. Damage is decided by the authority: this call is a
## report that the bolt reached something, and the engine answers with the
## numbers (and refuses when the target is protected, already dead, or the caster
## was not allowed to hit it in the first place).
func _handle_hit(target: Node) -> void:
	if spent:
		return
	spent = true
	if not visual_only and SimAuthority.is_authority():
		if spell_id in ["bombarda", "ultimate"]:
			var radius := float(GameData.SPELLS[spell_id].get("radius", 9))
			SimAuthority.spell_area_impact(caster, global_position, radius, spell_id, damage)
		elif Rules.can_damage(caster, target):
			SimAuthority.apply_damage(target, damage, spell_id, caster)
	SkillFX.play_impact(get_parent(), global_position, spell_id, target)
	if travel_effect != null and is_instance_valid(travel_effect):
		travel_effect.call("cancel", "spent")
	queue_free()


func _find_mesh(node: Node) -> MeshInstance3D:
	if node is MeshInstance3D and (node as MeshInstance3D).mesh != null:
		return node as MeshInstance3D
	for child in node.get_children():
		var found := _find_mesh(child)
		if found != null:
			return found
	return null
