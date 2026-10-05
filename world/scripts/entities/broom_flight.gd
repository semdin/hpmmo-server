extends Node3D
class_name BroomFlight

## Phase 9 flight broom (plan.md: shaped shaft, grip, bristles; one MountRoot and
## one SeatSocket with the model axes normalised in this single wrapper; a trail
## driven by speed/acceleration from the broom socket's own velocity).
##
## Socket convention (documented in docs/phase9-rig-and-sockets.md):
##   MountRoot  - the shaft point the rider's mount node attaches to
##   SeatSocket - where the rider's hips sit; coincides with the hero's Socket_Hips
##   GripSocket - the two-handed grip centre
##   TailSocket - bristle tip; the trail and thrust effects emit from here
## The model is authored with +Z forward and +Y up (art direction section 3), and
## this wrapper normalises that: `verify_axes()` measures the imported mesh, it
## does not assume it.

const TRAIL_SAMPLES := 24
const TRAIL_MAX_LENGTH := 7.0
const WISP_TEXTURE := "res://assets/vfx/flame_01.png"
const SPARK_TEXTURE := "res://assets/vfx/spark_01.png"

var player: Node3D
var visuals: Node3D
var mount_root: Node3D
var seat_socket: Node3D
var grip_socket: Node3D
var tail_socket: Node3D
var bristles: Node3D

## Textured translucent wisp particles (kept as CPUParticles3D with a QuadMesh
## because the offline harness asserts exactly that - no cube-like particles).
var particles: CPUParticles3D
var sparks: GPUParticles3D
var ribbon: MeshInstance3D
var _ribbon := ImmediateMesh.new()
var _tail_history: Array[Vector3] = []
var _trail_material: StandardMaterial3D
var _speed := 0.0
var _prev_speed := 0.0
var _accel := 0.0
var _flying := false
var _trail_time := 0.0
var model_root_ref: Node
## Phase 12 hook: the layered broom-trail effect scene (spells/broom_trail.gd).
## While it is present it owns the ribbon, wisps and sparks; the Phase 9
## primitives stay in the tree as a fallback if the scene cannot be built.
var trail: Node3D

func setup(player_body: Node3D, visuals_node: Node3D, wisp_particles: CPUParticles3D,
		model_root: Node3D = null) -> void:
	player = player_body
	visuals = visuals_node
	# The rig is a component attached to the broom node, so the authored parts
	# are searched from the model root (a sibling of this node), never assumed
	# to be our own children.
	var scope: Node = model_root if model_root != null else get_parent()
	if scope == null:
		scope = self
	mount_root = scope.find_child("MountRoot", true, false) as Node3D
	seat_socket = scope.find_child("SeatSocket", true, false) as Node3D
	grip_socket = scope.find_child("GripSocket", true, false) as Node3D
	tail_socket = scope.find_child("TailSocket", true, false) as Node3D
	bristles = scope.find_child("Bristles", true, false) as Node3D
	model_root_ref = scope
	particles = wisp_particles
	if particles:
		particles.local_coords = false
		particles.emitting = false
	_build_sparks()
	_build_ribbon()
	_attach_phase12_trail(scope)


## Phase 12 hook. The trail effect samples the authored trail_ribbon.glb taper
## profile and the tail socket's own motion history; nothing about flight state
## changes because the presentation is replaced.
func _attach_phase12_trail(scope: Node) -> void:
	var scene: PackedScene = load("res://scenes/spells/fx_broom_trail.tscn")
	if scene == null:
		return
	var instance := scene.instantiate()
	add_child(instance)
	if not instance.has_method("setup"):
		instance.queue_free()
		return
	instance.call("setup", player, scope)
	trail = instance
	if ribbon:
		ribbon.visible = false
	if particles:
		particles.emitting = false
	if sparks:
		sparks.emitting = false
	set_flying(_flying)

## ---------------------------------------------------------------- trail rig

func _build_sparks() -> void:
	sparks = GPUParticles3D.new()
	sparks.name = "TrailSparks"
	sparks.amount = 24
	sparks.lifetime = 0.9
	sparks.one_shot = false
	sparks.explosiveness = 0.0
	sparks.randomness = 0.6
	sparks.local_coords = false
	sparks.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	var mat := StandardMaterial3D.new()
	mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	mat.blend_mode = BaseMaterial3D.BLEND_MODE_ADD
	mat.vertex_color_use_as_albedo = true
	mat.billboard_mode = BaseMaterial3D.BILLBOARD_ENABLED
	mat.albedo_texture = load(SPARK_TEXTURE)
	var quad := QuadMesh.new()
	quad.size = Vector2(0.09, 0.09)
	quad.material = mat
	sparks.draw_pass_1 = quad
	var proc := ParticleProcessMaterial.new()
	proc.direction = Vector3(0, 0, 1)
	proc.spread = 26.0
	proc.initial_velocity_min = 1.5
	proc.initial_velocity_max = 4.5
	proc.gravity = Vector3(0, -1.2, 0)
	proc.scale_min = 0.5
	proc.scale_max = 1.2
	proc.color = Color(1.0, 0.85, 0.45, 0.9)
	sparks.process_material = proc
	add_child(sparks)
	sparks.emitting = false

func _build_ribbon() -> void:
	ribbon = MeshInstance3D.new()
	ribbon.name = "TrailRibbon"
	ribbon.mesh = _ribbon
	ribbon.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	_trail_material = StandardMaterial3D.new()
	_trail_material.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	_trail_material.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	_trail_material.blend_mode = BaseMaterial3D.BLEND_MODE_ADD
	_trail_material.vertex_color_use_as_albedo = true
	_trail_material.cull_mode = BaseMaterial3D.CULL_DISABLED
	_trail_material.albedo_texture = load(WISP_TEXTURE)
	_trail_material.uv1_scale = Vector3(1.0, 3.0, 1.0)
	_trail_material.uv1_offset = Vector3(0.0, 0.0, 0.0)
	ribbon.material_override = _trail_material
	# The ribbon is world-space: samples are socket positions, so it must not
	# inherit the broom's own transform.
	ribbon.top_level = true
	add_child(ribbon)
	ribbon.visible = false

## ---------------------------------------------------------------- state

func set_flying(flying: bool) -> void:
	_flying = flying
	if trail != null and is_instance_valid(trail):
		trail.call("set_flying", flying)
		return
	if particles:
		particles.emitting = flying
	if sparks:
		sparks.emitting = flying
	if ribbon:
		ribbon.visible = flying
	if not flying:
		_tail_history.clear()
		_ribbon.clear_surfaces()

func flying() -> bool:
	return _flying

## ---------------------------------------------------------------- per frame

func tick(delta: float) -> void:
	if player == null:
		return
	var vel: Vector3 = Vector3.ZERO
	if player is CharacterBody3D:
		vel = (player as CharacterBody3D).velocity
	_speed = Vector3(vel.x, 0, vel.z).length()
	_accel = (_speed - _prev_speed) / maxf(delta, 0.0001)
	_prev_speed = _speed
	_trail_time += delta
	if trail != null and is_instance_valid(trail):
		# Phase 12: the layered trail owns the per-frame ribbon and emission.
		# Speed and acceleration are measured from the same body velocity.
		trail.call("tick", delta)
		return
	if not _flying:
		return
	_scale_effects()
	if tail_socket:
		_tail_history.push_back(tail_socket.global_position)
		while _tail_history.size() > TRAIL_SAMPLES:
			_tail_history.pop_front()
		_rebuild_ribbon()

func _scale_effects() -> void:
	var ratio := clampf(_speed / 15.0, 0.0, 1.4)
	if particles:
		particles.amount = int(lerpf(24.0, 90.0, clampf(ratio, 0.0, 1.0)))
		particles.initial_velocity_min = 1.0 + ratio * 2.0
		particles.initial_velocity_max = 3.0 + ratio * 5.0
	if sparks:
		sparks.amount = int(lerpf(6.0, 40.0, clampf(ratio, 0.0, 1.0)))
		sparks.speed_scale = 0.6 + ratio
	if _trail_material:
		# hotter and longer with speed; brighter still when accelerating hard
		var heat := clampf(0.35 + ratio * 0.5 + maxf(0.0, _accel) * 0.02, 0.0, 1.0)
		_trail_material.albedo_color = Color(1.0, lerpf(0.55, 0.92, heat), lerpf(0.25, 0.6, heat),
			0.45 + 0.35 * clampf(ratio, 0.0, 1.0))
		_trail_material.uv1_offset.y = -_trail_time * (0.6 + ratio)

func _rebuild_ribbon() -> void:
	_ribbon.clear_surfaces()
	var count := _tail_history.size()
	if count < 3:
		return
	_ribbon.surface_begin(Mesh.PRIMITIVE_TRIANGLE_STRIP)
	var travelled := 0.0
	for i in range(count):
		var idx := count - 1 - i
		var point := _tail_history[idx]
		if i > 0:
			travelled += point.distance_to(_tail_history[idx + 1])
		var age := float(i) / float(count)
		var width := lerpf(0.16, 0.02, age) * lerpf(0.35, 1.0, clampf(_speed / 8.0, 0.0, 1.0))
		var dir := Vector3.FORWARD
		if i == 0:
			# Newest sample: the segment runs from the previous sample to this one.
			dir = (point - _tail_history[idx - 1]).normalized() if idx > 0 else Vector3.FORWARD
		else:
			dir = (point - _tail_history[idx + 1]).normalized()
		var side := dir.cross(Vector3.UP)
		if side.length_squared() < 0.0001:
			side = Vector3.RIGHT
		side = side.normalized() * width
		var fade := (1.0 - age) * (1.0 - clampf(travelled / TRAIL_MAX_LENGTH, 0.0, 1.0))
		_ribbon.surface_set_color(Color(1.0, 0.75, 0.4, fade))
		_ribbon.surface_set_uv(Vector2(0.0, age * 3.0))
		_ribbon.surface_add_vertex(point - side)
		_ribbon.surface_set_color(Color(1.0, 0.75, 0.4, fade))
		_ribbon.surface_set_uv(Vector2(1.0, age * 3.0))
		_ribbon.surface_add_vertex(point + side)
	_ribbon.surface_end()

## ---------------------------------------------------------------- measurement

## Measure the imported model instead of trusting the exporter: the nose must be
## ahead of the seat (+Z) and the bristles behind it (-Z), or the rider would be
## sitting backwards (the project has shipped a reversed rider before).
func verify_axes() -> Dictionary:
	var report := {"forward_ok": false, "bristles_ok": false, "seat_ok": false,
		"nose_z": 0.0, "tail_z": 0.0, "seat_y": 0.0}
	var mesh_span := _mesh_bounds()
	report["nose_z"] = mesh_span[1].z
	report["tail_z"] = mesh_span[0].z
	if seat_socket:
		report["seat_y"] = seat_socket.position.y
		report["seat_ok"] = seat_socket.position.y > 0.05
	report["forward_ok"] = mesh_span[1].z > 0.5
	report["bristles_ok"] = mesh_span[0].z < -0.5
	return report

func _mesh_bounds() -> Array:
	var min_v := Vector3(1e9, 1e9, 1e9)
	var max_v := Vector3(-1e9, -1e9, -1e9)
	var scope: Node = model_root_ref if model_root_ref != null else get_parent()
	if scope == null:
		scope = self
	for child in scope.find_children("*", "MeshInstance3D", true, false):
		var mesh_instance := child as MeshInstance3D
		if mesh_instance.mesh == null:
			continue
		var aabb := mesh_instance.get_aabb()
		for i in range(8):
			var local: Vector3 = to_local(mesh_instance.global_transform * aabb.get_endpoint(i))
			min_v = min_v.min(local)
			max_v = max_v.max(local)
	return [min_v, max_v]

## The broom's forward axis in world space (+Z of the authored model, measured
## in verify_axes rather than assumed).
func broom_forward() -> Vector3:
	return global_transform.basis.z.normalized()

func seat_offset() -> Vector3:
	return seat_socket.position if seat_socket else Vector3.ZERO
