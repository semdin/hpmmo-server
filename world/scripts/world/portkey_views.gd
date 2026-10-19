extends Node3D
class_name PortkeyViews

## Portkeys on the client (protocol v21): the boot the owner set down, its
## reach ring, the countdown over it and a thread of blue light to everyone
## holding on, from the `portkey_state` the authority sends to the owner and
## the owner's party. When it fires, a blue whirlwind takes the holders; a
## Portkey that fizzles just fades. The map controller asks `grab_candidate`
## which boot the local body could hold.

const BOOT := "res://assets/models/travel/portkey_boot.glb"
const BLUE := Color(0.45, 0.7, 1.0)

var _views: Dictionary = {}    # id -> {root, label, ring, links, state}
var _local_uid := 0

func _ready() -> void:
	name = "PortkeyViews"
	SimAuthority.portkey_state.connect(_on_state)

func _local() -> int:
	if int(SimNet.local_uid) != 0:
		return int(SimNet.local_uid)
	var world := get_parent()
	var player = world.get("local_player") if world != null else null
	return int(SimAuthority.record_for(player).get("uid", 0)) if player != null else 0

func _on_state(uid: int, state: Dictionary) -> void:
	if uid != _local():
		return   # the authority emits once per viewer; this client is one of them
	var id := int(state.get("id", 0))
	var phase := String(state.get("phase", ""))
	if phase == "placed":
		if not _views.has(id):
			_views[id] = _build(state)
			if int(state.get("owner", 0)) != uid:
				_notice("%s set down a Portkey to %s - grab hold! (F)" % [state.get("owner_name", "A party member"), state.get("label", "")])
		_views[id]["state"] = state
	elif phase == "fired":
		var at: Vector3 = state.get("pos", Vector3.ZERO)
		if (state.get("holders", []) as Array).is_empty():
			swirl(get_parent(), at)
		for holder in state.get("holders", []):
			var node = SimAuthority.record_by_uid(int(holder)).get("node")
			if node is Node3D and is_instance_valid(node):
				swirl(get_parent(), (node as Node3D).global_position, 1.2)
		_drop(id)
	elif phase == "gone":
		if int(state.get("owner", 0)) == uid:
			_notice("The Portkey fizzled - nobody was holding on. The boot is back in your bag.")
		_drop(id)

func _drop(id: int) -> void:
	var view: Dictionary = _views.get(id, {})
	if view.has("root") and is_instance_valid(view.root):
		(view.root as Node3D).queue_free()
	_views.erase(id)

func _notice(text: String) -> void:
	var hud = get_parent().get("hud") if get_parent() != null else null
	if hud != null and hud.has_method("show_notice"):
		hud.show_notice(text, "info")

func _build(state: Dictionary) -> Dictionary:
	var root := Node3D.new()
	root.name = "Portkey%d" % int(state.get("id", 0))
	add_child(root)
	root.global_position = state.get("pos", Vector3.ZERO)
	if ResourceLoader.exists(BOOT):
		var boot: Node3D = (load(BOOT) as PackedScene).instantiate()
		boot.scale = Vector3.ONE * 1.4
		boot.rotation.y = randf() * TAU
		root.add_child(boot)
	var light := OmniLight3D.new()
	light.light_color = BLUE
	light.light_energy = 1.4
	light.omni_range = 4.0
	light.position = Vector3(0, 0.5, 0)
	root.add_child(light)
	# The reach: a thin glowing ring on the ground.
	var ring := MeshInstance3D.new()
	var torus := TorusMesh.new()
	var r := float(state.get("radius", 3.0))
	torus.inner_radius = r - 0.06
	torus.outer_radius = r
	torus.rings = 48
	torus.ring_segments = 6
	var mat := StandardMaterial3D.new()
	mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	mat.albedo_color = Color(BLUE.r, BLUE.g, BLUE.b, 0.7)
	mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	mat.emission_enabled = true
	mat.emission = BLUE
	torus.material = mat
	ring.mesh = torus
	ring.position = Vector3(0, 0.08, 0)
	ring.scale = Vector3(1, 0.3, 1)
	root.add_child(ring)
	var label := Label3D.new()
	label.billboard = BaseMaterial3D.BILLBOARD_ENABLED
	label.font_size = 40
	label.outline_size = 10
	label.modulate = Color(0.75, 0.88, 1.0)
	label.position = Vector3(0, 1.6, 0)
	label.no_depth_test = true
	root.add_child(label)
	var links := MeshInstance3D.new()
	links.mesh = ImmediateMesh.new()
	var link_mat := StandardMaterial3D.new()
	link_mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	link_mat.albedo_color = Color(0.7, 0.85, 1.0)
	link_mat.emission_enabled = true
	link_mat.emission = BLUE
	links.material_override = link_mat
	root.add_child(links)
	return {"root": root, "label": label, "ring": ring, "links": links, "light": light, "state": state}

func _process(_delta: float) -> void:
	for id in _views:
		var view: Dictionary = _views[id]
		var state: Dictionary = view.state
		var root: Node3D = view.root
		if not is_instance_valid(root):
			continue
		var left := maxf(0.0, float(int(state.get("ends_tick", 0)) - int(SimAuthority.sim_tick)) * HPProtocol.SIM_DT)
		var holders: Array = state.get("holders", [])
		(view.label as Label3D).text = "Portkey to %s\n%d   (%d holding)" % [state.get("label", ""), ceili(left), holders.size()]
		(view.light as OmniLight3D).light_energy = 1.2 + 1.8 * (1.0 - clampf(left / 10.0, 0.0, 1.0)) + 0.4 * sin(Time.get_ticks_msec() * 0.01)
		var mesh: ImmediateMesh = (view.links as MeshInstance3D).mesh
		mesh.clear_surfaces()
		var any := false
		for holder in holders:
			var node = SimAuthority.record_by_uid(int(holder)).get("node")
			if not (node is Node3D) or not is_instance_valid(node):
				continue
			if not any:
				mesh.surface_begin(Mesh.PRIMITIVE_LINES)
				any = true
			mesh.surface_add_vertex(Vector3(0, 0.25, 0))
			mesh.surface_add_vertex(root.to_local((node as Node3D).global_position + Vector3.UP * 0.9))
		if any:
			mesh.surface_end()

## The Portkey the local body could hold (or is holding) on `map_id`:
## {id, holding, label} or {}.
func grab_candidate(pos: Vector3, map_id: String) -> Dictionary:
	var me := _local()
	for id in _views:
		var state: Dictionary = _views[id].state
		if HPMaps.base_map(String(state.get("map", ""))) != HPMaps.base_map(map_id):
			continue
		var d: Vector3 = pos - (state.get("pos", Vector3.ZERO) as Vector3)
		if Vector2(d.x, d.z).length() > float(state.get("radius", 3.0)) or absf(d.y) > 3.0:
			continue
		return {"id": int(id), "holding": (state.get("holders", []) as Array).has(me), "label": String(state.get("label", ""))}
	return {}

## The Portkey whirlwind: a spinning column of blue-white light that snaps up
## and away (departure) or unfurls (arrival). Frees itself.
static func swirl(parent: Node, at: Vector3, seconds: float = 1.6) -> void:
	if parent == null:
		return
	var root := Node3D.new()
	root.name = "PortkeySwirl"
	parent.add_child(root)
	root.global_position = at
	var mat := StandardMaterial3D.new()
	mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	mat.blend_mode = BaseMaterial3D.BLEND_MODE_ADD
	mat.cull_mode = BaseMaterial3D.CULL_DISABLED
	mat.albedo_color = Color(0.55, 0.78, 1.0, 0.55)
	var spin := Node3D.new()
	root.add_child(spin)
	for k in 3:
		var band := MeshInstance3D.new()
		var cyl := CylinderMesh.new()
		cyl.top_radius = 0.9 - 0.2 * k
		cyl.bottom_radius = 0.3 + 0.15 * k
		cyl.height = 2.6
		cyl.cap_top = false
		cyl.cap_bottom = false
		cyl.radial_segments = 18
		cyl.rings = 1
		cyl.material = mat
		band.mesh = cyl
		band.position = Vector3(0, 1.3, 0)
		band.rotation = Vector3(0.12 * (k - 1), 0, 0.1 * k)
		spin.add_child(band)
	var sparks := CPUParticles3D.new()
	sparks.amount = 50
	sparks.lifetime = 1.0
	sparks.one_shot = true
	sparks.explosiveness = 0.5
	sparks.emission_shape = CPUParticles3D.EMISSION_SHAPE_RING
	sparks.emission_ring_radius = 0.8
	sparks.emission_ring_inner_radius = 0.3
	sparks.emission_ring_height = 2.0
	sparks.emission_ring_axis = Vector3.UP
	sparks.direction = Vector3.UP
	sparks.spread = 40.0
	sparks.initial_velocity_min = 1.5
	sparks.initial_velocity_max = 4.0
	sparks.orbit_velocity_min = 0.6
	sparks.orbit_velocity_max = 1.2
	sparks.scale_amount_min = 0.03
	sparks.scale_amount_max = 0.07
	var mote := SphereMesh.new()
	mote.radius = 0.5
	mote.height = 1.0
	mote.radial_segments = 6
	mote.rings = 3
	var mm := StandardMaterial3D.new()
	mm.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	mm.albedo_color = Color(0.85, 0.93, 1.0)
	mote.material = mm
	sparks.mesh = mote
	sparks.position = Vector3(0, 0.3, 0)
	root.add_child(sparks)
	sparks.emitting = true
	var light := OmniLight3D.new()
	light.light_color = BLUE
	light.light_energy = 4.0
	light.omni_range = 7.0
	light.position = Vector3(0, 1.3, 0)
	root.add_child(light)
	spin.scale = Vector3(0.2, 1.0, 0.2)
	var tw := root.create_tween()
	tw.set_parallel(true)
	tw.tween_property(spin, "rotation:y", TAU * 3.0, seconds)
	tw.tween_property(spin, "scale", Vector3(1.0, 1.0, 1.0), seconds * 0.3).set_ease(Tween.EASE_OUT)
	tw.chain().set_parallel(true)
	tw.tween_property(spin, "scale", Vector3(0.05, 2.2, 0.05), seconds * 0.4).set_ease(Tween.EASE_IN)
	tw.tween_property(light, "light_energy", 0.0, seconds * 0.4)
	tw.chain().tween_callback(root.queue_free)
	var audio := parent.get_node_or_null("/root/AudioManager")
	if audio != null and audio.has_method("play_sound_at"):
		audio.call("play_sound_at", "portkey_whoosh", at, null, false)
