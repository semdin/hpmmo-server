extends Node3D
class_name PortkeyViews

## Portkeys on the client (protocol v21), from the `portkey_state` the
## authority sends to the owner and the owner's party:
##   * the owner reaches down and sets the boot on the ground (its Place clip;
##     the boot appears as the hand comes down);
##   * a soft blue aura (flipbook) and a slowly turning rune seal mark it, with
##     a countdown over it;
##   * everyone holding on kneels with a hand on the boot (the Hold loop) - on
##     every viewer's screen; moving away lets go;
##   * when it fires a blue-white vortex snaps the holders away; a Portkey
##     nobody holds just fades.
## The map controller asks `grab_candidate` which boot the local body could hold.

const BOOT := "res://assets/models/travel/portkey_boot.glb"
const RUNE := "res://assets/vfx/tex/rune_seal_512.png"
const BLUE := Color(0.5, 0.75, 1.0)
## The owner's hand reaches the ground this long into the Place clip.
const DROP_DELAY := 0.9

var _views: Dictionary = {}    # id -> {root, label, aura, state, holders}
var _letting_go := false

func _ready() -> void:
	name = "PortkeyViews"
	SimAuthority.portkey_state.connect(_on_state)

func _local() -> int:
	if int(SimNet.local_uid) != 0:
		return int(SimNet.local_uid)
	var world := get_parent()
	var player = world.get("local_player") if world != null else null
	return int(SimAuthority.record_for(player).get("uid", 0)) if player != null else 0

func _body(uid: int) -> Node3D:
	var node = SimAuthority.record_by_uid(uid).get("node")
	return node if node is Node3D and is_instance_valid(node) else null

func _on_state(uid: int, state: Dictionary) -> void:
	if uid != _local():
		return   # the authority emits once per viewer; this client is one of them
	var id := int(state.get("id", 0))
	var phase := String(state.get("phase", ""))
	var at: Vector3 = state.get("pos", Vector3.ZERO)
	if phase == "placed":
		if not _views.has(id):
			_views[id] = _build(state)
			if int(state.get("owner", 0)) != uid:
				_notice("%s set down a Portkey to %s - hold on to it! (F)" % [state.get("owner_name", "A party member"), state.get("label", "")])
		var view: Dictionary = _views[id]
		view["state"] = state
		_sync_holders(view, state.get("holders", []), at)
	elif phase == "fired":
		var view: Dictionary = _views.get(id, {})
		for holder in state.get("holders", []):
			var body := _body(int(holder))
			if body != null:
				FlipbookFX.play(get_parent(), body.global_position, [
					{"atlas": "portkey_vortex_8x8_2k", "size": 3.6, "height": 1.6, "fps": 26.0},
				], {"life": 3.0, "light": BLUE, "light_energy": 4.0})
		var audio := get_node_or_null("/root/AudioManager")
		if audio != null:
			audio.play_sound_at("portkey_whoosh", at, null, false)
		if not view.is_empty():
			_sync_holders(view, [], at)
		_drop(id)
	elif phase == "gone":
		if int(state.get("owner", 0)) == uid:
			_notice("The Portkey fizzled - nobody was holding on. The boot is back in your bag.")
		var view: Dictionary = _views.get(id, {})
		if not view.is_empty():
			_sync_holders(view, [], at)
		_drop(id)

## Kneel the bodies that hold on, stand up those that let go.
func _sync_holders(view: Dictionary, holders: Array, at: Vector3) -> void:
	var before: Array = view.get("holders", [])
	for uid in holders:
		if not before.has(uid):
			var body := _body(int(uid))
			if body != null and body.has_method("portkey_kneel"):
				body.call("portkey_kneel", at)
	for uid in before:
		if not holders.has(uid):
			var body := _body(int(uid))
			if body != null and body.has_method("portkey_release"):
				body.call("portkey_release")
	view["holders"] = holders.duplicate()
	if holders.has(_local()):
		_letting_go = false

func _drop(id: int) -> void:
	var view: Dictionary = _views.get(id, {})
	if view.has("root") and is_instance_valid(view.root):
		var root: Node3D = view.root
		var tw := root.create_tween()
		tw.tween_property(root, "scale", Vector3(0.01, 0.01, 0.01), 0.35)
		tw.tween_callback(root.queue_free)
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
	var boot_holder := Node3D.new()
	root.add_child(boot_holder)
	if ResourceLoader.exists(BOOT):
		var boot: Node3D = (load(BOOT) as PackedScene).instantiate()
		boot.scale = Vector3.ONE * 1.25
		boot.rotation = Vector3(0.0, randf() * TAU, deg_to_rad(-8.0))
		boot_holder.add_child(boot)
	# The boot appears as the owner's hand comes down, with a little settle.
	boot_holder.scale = Vector3(0.01, 0.01, 0.01)
	var tw := root.create_tween()
	tw.tween_interval(DROP_DELAY)
	tw.tween_property(boot_holder, "scale", Vector3.ONE, 0.25).set_trans(Tween.TRANS_BACK).set_ease(Tween.EASE_OUT)
	var aura := FlipbookFX.play(root, root.global_position, [
		{"atlas": "portkey_aura_8x8_1k", "size": 2.0, "height": 0.85, "fps": 18.0, "loop": true, "delay": DROP_DELAY,
			"fade_in": 0.6},
		{"texture": RUNE, "size": float(state.get("radius", 3.0)) * 1.4, "flat": true, "offset": Vector3(0, 0.05, 0),
			"tint": Color(0.45, 0.7, 1.0), "opacity": 0.55, "spin": 0.35, "delay": DROP_DELAY, "fade_in": 0.8},
	], {"life": 0.0, "light": BLUE, "light_energy": 1.6, "light_range": 4.5, "light_height": 0.6, "name": "Aura"})
	var label := Label3D.new()
	label.billboard = BaseMaterial3D.BILLBOARD_ENABLED
	label.font = HudKit.deco()
	label.font_size = 30
	label.outline_size = 10
	label.outline_modulate = Color(0.02, 0.04, 0.1, 0.9)
	label.modulate = Color(0.78, 0.9, 1.0)
	label.position = Vector3(0, 1.9, 0)
	label.no_depth_test = true
	root.add_child(label)
	return {"root": root, "label": label, "aura": aura, "state": state, "holders": []}

func _process(_delta: float) -> void:
	var me := _local()
	for id in _views:
		var view: Dictionary = _views[id]
		var state: Dictionary = view.state
		if not is_instance_valid(view.root):
			continue
		var left := maxf(0.0, float(int(state.get("ends_tick", 0)) - int(SimAuthority.sim_tick)) * HPProtocol.SIM_DT)
		var holders: Array = state.get("holders", [])
		(view.label as Label3D).text = "Portkey to %s\n%d" % [state.get("label", ""), ceili(left)]
		# Moving away from the boot lets go of it (one request per release).
		if holders.has(me) and not _letting_go:
			var player = get_parent().get("local_player")
			if player is CharacterBody3D and is_instance_valid(player):
				var v: Vector3 = (player as CharacterBody3D).velocity
				if Vector2(v.x, v.z).length() > 1.2:
					_letting_go = true
					SimNet.portkey_grab(player, int(id), false)

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

## The arrival: a giant boot spins down out of a whirlwind beside the body,
## thumps onto the ground, bulges as if something is climbing out - and the
## body springs out of its mouth (player.portkey_emerge), after which the boot
## spins away into nothing. `body` is the local player; the boot stands
## `BOOT_GAP` metres off on the ground. Returns the boot's mouth (world).
const ARRIVAL_SCALE := 3.6
const BOOT_GAP := 1.9
## The shaft opening of portkey_boot.glb in its own space (0.39 m long, the
## shaft over +x, 0.42 m tall).
const BOOT_MOUTH := Vector3(0.095, 0.4, 0.0)

static func arrival(parent: Node3D, body: Node3D) -> void:
	if parent == null or body == null or not ResourceLoader.exists(BOOT):
		if body != null and body.has_method("portkey_emerge_reset"):
			body.call("portkey_emerge_reset")
		return
	var dir := Vector3(randf_range(-1.0, 1.0), 0.0, randf_range(-1.0, 1.0))
	if dir.length_squared() < 0.01:
		dir = Vector3.FORWARD
	var at := body.global_position + dir.normalized() * BOOT_GAP
	var space := body.get_world_3d().direct_space_state
	var ray := PhysicsRayQueryParameters3D.create(at + Vector3.UP * 3.0, at - Vector3.UP * 4.0, 1)
	var hit := space.intersect_ray(ray)
	if not hit.is_empty():
		at = hit["position"]
	var root := Node3D.new()
	root.name = "PortkeyArrival"
	parent.add_child(root)
	root.global_position = at
	# Lying open toward the body: the shaft (+x) points at it, tipped back so
	# the mouth gapes up and out.
	var toward := body.global_position - at
	toward.y = 0.0
	root.rotation.y = atan2(-toward.z, toward.x) if toward.length_squared() > 0.01 else 0.0
	var spin := Node3D.new()
	root.add_child(spin)
	var boot: Node3D = (load(BOOT) as PackedScene).instantiate()
	boot.rotation = Vector3(0.0, 0.0, deg_to_rad(-12.0))
	spin.add_child(boot)
	spin.scale = Vector3.ONE * 0.01
	spin.position = Vector3(0, 2.2, 0)
	var light := OmniLight3D.new()
	light.light_color = BLUE
	light.light_energy = 0.0
	light.omni_range = 6.0
	light.position = Vector3(0, 1.4, 0)
	root.add_child(light)
	FlipbookFX.play(parent, at, [
		{"atlas": "portkey_vortex_8x8_2k", "size": 4.2, "height": 1.8, "fps": 28.0},
	], {"life": 2.4, "light": BLUE, "light_energy": 3.0, "sound": "portkey_whoosh"})
	var s := ARRIVAL_SCALE
	var tw := root.create_tween()
	# Down out of the whirlwind, turning.
	tw.tween_property(spin, "scale", Vector3.ONE * s, 0.38).set_trans(Tween.TRANS_BACK).set_ease(Tween.EASE_OUT)
	tw.parallel().tween_property(spin, "position", Vector3.ZERO, 0.38).set_trans(Tween.TRANS_QUAD).set_ease(Tween.EASE_IN)
	tw.parallel().tween_property(spin, "rotation:y", TAU * 1.5, 0.38).from(0.0)
	tw.parallel().tween_property(light, "light_energy", 3.5, 0.3)
	# Thump, then the bulge as something climbs out.
	tw.tween_property(spin, "scale", Vector3(s * 1.15, s * 0.8, s * 1.15), 0.08)
	tw.tween_property(spin, "scale", Vector3.ONE * s, 0.12)
	tw.tween_property(spin, "scale", Vector3(s * 0.9, s * 1.25, s * 0.9), 0.14).set_trans(Tween.TRANS_SINE)
	tw.tween_callback(func():
		if is_instance_valid(body) and is_instance_valid(boot):
			var mouth: Vector3 = boot.global_transform * BOOT_MOUTH
			FlipbookFX.play(parent, mouth, [
				{"atlas": "portkey_aura_8x8_1k", "size": 1.6, "height": 0.4, "fps": 30.0},
			], {"life": 1.0, "light": BLUE, "light_energy": 2.5})
			if body.has_method("portkey_emerge"):
				body.call("portkey_emerge", mouth, 0.75)
	)
	tw.tween_property(spin, "scale", Vector3.ONE * s, 0.3).set_trans(Tween.TRANS_ELASTIC).set_ease(Tween.EASE_OUT)
	# The boot has done its job: a last turn and it is gone.
	tw.tween_interval(0.9)
	tw.tween_property(spin, "rotation:y", TAU * 2.0, 0.45).as_relative()
	tw.parallel().tween_property(spin, "scale", Vector3.ONE * 0.01, 0.45).set_trans(Tween.TRANS_BACK).set_ease(Tween.EASE_IN)
	tw.parallel().tween_property(light, "light_energy", 0.0, 0.45)
	tw.tween_callback(root.queue_free)

## The Portkey whirlwind at one spot (arrival).
static func swirl(parent: Node, at: Vector3, _seconds: float = 1.6) -> void:
	FlipbookFX.play(parent, at, [
		{"atlas": "portkey_vortex_8x8_2k", "size": 3.6, "height": 1.6, "fps": 30.0},
	], {"life": 2.4, "light": BLUE, "light_energy": 4.0, "sound": "portkey_whoosh"})
