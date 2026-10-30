extends CanvasLayer
class_name HitFeedback

## Damage numbers and hit feel, driven by the authority's `entity_hit` events.
##
## Every number on screen is a hit the server applied (offline play runs the
## same authority in-process), so nothing here can show damage that did not
## happen. The numbers are drawn on the 2D canvas at a projected anchor, like
## `WorldLabels`, so they stay crisp over fog, glow and any background.
##
## Styles: the local player's own hits are large warm white, a critical is
## bigger still, bright yellow with a red edge and a "CRITICAL" caption, a combo
## finisher is orange; damage the local player takes is red; other players' hits
## are small and grey.
##
## Hit feel for the local player's own hits: the side of the victim the spell
## came from lights up in its colour (hit_flash.gdshader) and the body recoils
## away from the blow, and a crit or finisher adds a very short hitstop (the
## camera shake lives in `CombatFeedback`, which owns the shake setting).

const RISE_PX := 90.0
const LIFETIME := 0.95
const CRIT_LIFETIME := 1.25
const MAX_NUMBERS := 48
const MAX_RANGE := 60.0
const FLASH_SECONDS := 0.16
## The flash and the recoil wait this long after the authority's word, so they
## land with the bolt that finishes its flight onto the body (spell_projectile
## `end_on_landed` rushes the last metre in a few frames).
const REACT_DELAY := 0.035
const FLASH_SHADER := preload("res://assets/shaders/hit_flash.gdshader")
const VFX = preload("res://scripts/spells/vfx_library.gd")
const SkillFX = preload("res://scripts/spells/skill_fx.gd")
const HITSTOP_SECONDS := 0.05
const HITSTOP_SCALE := 0.12

const COLOR_OUT := Color(1.0, 0.97, 0.9)
const COLOR_CRIT := Color(1.0, 0.92, 0.12)
const COLOR_CRIT_EDGE := Color(0.75, 0.08, 0.02)
const COLOR_FINISHER := Color(1.0, 0.6, 0.16)
const COLOR_TAKEN := Color(1.0, 0.27, 0.22)
const COLOR_OTHER := Color(0.78, 0.78, 0.78)
## Damage-over-time ticks (the local player's burn, bleed and poison on others).
const COLOR_DOT := {"burn": Color(1.0, 0.55, 0.2), "bleed": Color(0.95, 0.12, 0.14), "poison": Color(0.5, 0.95, 0.3)}

static var _instance: HitFeedback = null

var _numbers: Array = []
var _canvas: _Canvas = null
var _flash_material: ShaderMaterial = null
var _hitstop_until := 0.0
## The local body. Offline play has no network uid (`SimAuthority.local_uid`
## stays 0), so "is this my hit" is decided from this node's own sim uid.
var local_player: Node3D = null

## Evidence counters for the checks.
var numbers_shown: int = 0
var crits_shown: int = 0

static func enabled() -> bool:
	return DisplayServer.get_name() != "headless"

## The one hit-feedback layer of the running scene tree (created on first use).
static func ensure(from: Node) -> HitFeedback:
	if not enabled() or from == null or not from.is_inside_tree():
		return null
	if _instance != null and is_instance_valid(_instance) and not _instance.is_queued_for_deletion():
		return _instance
	_instance = HitFeedback.new()
	_instance.name = "HitFeedback"
	_instance.layer = 1
	from.get_tree().root.add_child.call_deferred(_instance)
	return _instance

func _ready() -> void:
	_canvas = _Canvas.new()
	_canvas.owner_layer = self
	_canvas.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_canvas.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	add_child(_canvas)
	_flash_material = flash_material()
	if SimAuthority.has_signal("entity_hit") and not SimAuthority.entity_hit.is_connected(_on_entity_hit):
		SimAuthority.entity_hit.connect(_on_entity_hit)

## The additive overlay a hit flashes over the victim (ShaderWarmup draws it too).
static func flash_material() -> ShaderMaterial:
	var mat := ShaderMaterial.new()
	mat.shader = FLASH_SHADER
	mat.set_shader_parameter("strength", 0.0)
	return mat

func _exit_tree() -> void:
	if _hitstop_until > 0.0:
		Engine.time_scale = 1.0
	if _instance == self:
		_instance = null

func _on_entity_hit(uid: int, amount: int, _hp: int, spell_id: String, attacker_uid: int, flags: int) -> void:
	if amount <= 0:
		return
	var victim = SimAuthority.record_by_uid(uid).get("node")
	if victim == null or not is_instance_valid(victim) or not (victim is Node3D):
		return
	var local := _local_uid()
	var crit := flags & HPProtocol.HIT_CRIT != 0
	var finisher := flags & HPProtocol.HIT_FINISHER != 0
	var anchor := _anchor_of(victim as Node3D)
	if uid == local and local != 0:
		_spawn_number(anchor, str(amount), COLOR_TAKEN, 30.0, false)
		return
	if attacker_uid == local and local != 0 and COLOR_DOT.has(spell_id):
		# A tick of a burn or bleed the local player laid: small, in its colour.
		_spawn_number(anchor, str(amount), COLOR_DOT[spell_id], 26.0, false)
		return
	if attacker_uid == local and local != 0:
		if crit:
			_spawn_number(anchor, "%d!" % amount, COLOR_CRIT, 58.0 if not finisher else 64.0, true, I18n.upper(tr("Critical")), COLOR_CRIT_EDGE)
			crits_shown += 1
		elif finisher:
			_spawn_number(anchor, str(amount), COLOR_FINISHER, 44.0, true)
		else:
			_spawn_number(anchor, str(amount), COLOR_OUT, 36.0, false)
		var heavy := 1.6 if (crit or finisher) else 1.0
		var attacker = SimAuthority.record_by_uid(attacker_uid).get("node")
		var blow := Vector3.ZERO
		if attacker is Node3D and is_instance_valid(attacker):
			blow = (victim as Node3D).global_position - (attacker as Node3D).global_position
		var tint: Color = VFX.colours_for(spell_id, attacker)[0] if VFX.SPELLS.has(spell_id) else Color(1.0, 0.9, 0.7)
		get_tree().create_timer(REACT_DELAY, true, false, true).timeout.connect(func():
			if is_instance_valid(victim) and (victim as Node).is_inside_tree():
				_flash(victim as Node3D, 1.0 if heavy > 1.0 else 0.75, blow, tint)
				_recoil(victim as Node3D, heavy, blow))
		if crit or finisher:
			_hitstop(HITSTOP_SECONDS * (1.6 if crit and finisher else 1.0))
		if crit:
			var audio: Node = preload("res://scripts/spells/skill_fx.gd").audio_manager()
			if audio != null and audio.has_method("play_sound_at"):
				audio.call("play_sound_at", "ui_hit", (victim as Node3D).global_position, null, true)
		return
	_spawn_number(anchor, ("%d!" % amount) if crit else str(amount), COLOR_OTHER, 20.0, false)

## A crowd-control status that began on `victim` (StatusFX): its name, popped
## above the damage numbers. Efsun procs show the same way, from the status.
func show_status(victim: Node3D, text: String, colour: Color) -> void:
	if victim == null or not is_instance_valid(victim):
		return
	# A small label: the look on the body (stars, ice, blood) says it first.
	_spawn_number(_anchor_of(victim) + Vector3.UP * 0.45, text, colour, 15.0, false, "", Color(0.02, 0.02, 0.03))

func _local_uid() -> int:
	if local_player != null and is_instance_valid(local_player):
		var uid := int(local_player.get_meta("sim_uid", 0))
		if uid == 0:
			uid = int(SimAuthority.record_for(local_player).get("uid", 0))
		if uid != 0:
			return uid
	return int(SimAuthority.local_uid)

## Head height of a body: the nameplate/label if it has one, else ~2 m.
func _anchor_of(victim: Node3D) -> Vector3:
	for name in ["Label3D", "NameplateLabel3D", "DummyLabel", "HpLabel3D"]:
		var label := victim.get_node_or_null(name) as Node3D
		if label != null:
			return label.global_position - Vector3.UP * 0.25
	return victim.global_position + Vector3.UP * 2.0

func _spawn_number(at: Vector3, text: String, colour: Color, px: float, pop: bool, caption := "", edge := Color(0.03, 0.02, 0.01)) -> void:
	numbers_shown += 1
	if _numbers.size() >= MAX_NUMBERS:
		_numbers.pop_front()
	# Fan successive numbers out so a fast chain on one target does not stack
	# into a single unreadable blob.
	var drift := Vector2(randf_range(-34.0, 34.0), randf_range(-8.0, 8.0))
	_numbers.append({
		"at": at, "text": text, "colour": colour, "px": px, "pop": pop,
		"caption": caption, "drift": drift, "edge": edge,
		"born": _now(), "life": CRIT_LIFETIME if pop else LIFETIME,
	})

func _process(_delta: float) -> void:
	if _hitstop_until > 0.0 and _now() >= _hitstop_until:
		_hitstop_until = 0.0
		Engine.time_scale = 1.0
	var now := _now()
	var kept: Array = []
	for n in _numbers:
		if now - float(n.born) < float(n.life):
			kept.append(n)
	_numbers = kept
	if _canvas != null:
		_canvas.queue_redraw()

func _draw_numbers(canvas: CanvasItem) -> void:
	var cam := get_viewport().get_camera_3d()
	if cam == null:
		return
	var now := _now()
	var font: Font = HudKit.bold()
	for n in _numbers:
		var world: Vector3 = n.at
		if cam.is_position_behind(world) or cam.global_position.distance_to(world) > MAX_RANGE:
			continue
		var t := clampf((now - float(n.born)) / float(n.life), 0.0, 1.0)
		var dist := cam.global_position.distance_to(world)
		var k := clampf(9.0 / maxf(dist, 0.01), 0.75, 1.15)
		# Pop: a crit/finisher lands oversized and settles; a plain hit just
		# eases in. Then it rises with a slowing drift and fades at the end.
		var punch := 1.0
		if bool(n.pop):
			punch = lerpf(2.1, 1.0, ease(clampf(t / 0.18, 0.0, 1.0), 0.4))
		else:
			punch = lerpf(1.35, 1.0, clampf(t / 0.1, 0.0, 1.0))
		var px := maxi(10, int(round(float(n.px) * k * punch)))
		var rise := RISE_PX * ease(t, 0.45)
		var p := cam.unproject_position(world) + (n.drift as Vector2) * ease(t, 0.5) - Vector2(0, rise)
		var alpha := 1.0 - smoothstep(0.62, 1.0, t)
		_draw_text(canvas, font, String(n.text), p, px, n.colour, alpha, n.edge)
		if String(n.caption) != "":
			_draw_text(canvas, font, String(n.caption), p - Vector2(0, px * 0.92), maxi(10, int(px * 0.4)), n.colour, alpha, n.edge)

func _draw_text(canvas: CanvasItem, font: Font, text: String, centre: Vector2, px: int, colour: Color, alpha: float, edge := Color(0.03, 0.02, 0.01)) -> void:
	var w := font.get_string_size(text, HORIZONTAL_ALIGNMENT_LEFT, -1, px).x
	var pos := Vector2(roundf(centre.x - w * 0.5), roundf(centre.y))
	var ow := maxi(4, int(round(float(px) * 0.2)))
	canvas.draw_string(font, pos + Vector2(0, 3), text, HORIZONTAL_ALIGNMENT_LEFT, -1, px, Color(0, 0, 0, 0.5 * alpha))
	canvas.draw_string_outline(font, pos, text, HORIZONTAL_ALIGNMENT_LEFT, -1, px, ow, Color(edge, 0.95 * alpha))
	var c := colour
	c.a = alpha
	canvas.draw_string(font, pos, text, HORIZONTAL_ALIGNMENT_LEFT, -1, px, c)

## ------------------------------------------------------------- hit feel

## A brief flash of the spell's light over the struck side of the body.
func _flash(victim: Node3D, strength: float, blow: Vector3, tint: Color) -> void:
	var meshes: Array = []
	_collect_meshes(victim, meshes)
	if meshes.is_empty():
		return
	var mat := _flash_material.duplicate() as ShaderMaterial
	var dir := Vector3(blow.x, 0.0, blow.z)
	dir = dir.normalized() if dir.length_squared() > 0.0001 else Vector3.DOWN
	mat.set_shader_parameter("hit_dir", dir)
	mat.set_shader_parameter("hit_point", SkillFX.body_contact(victim, dir))
	mat.set_shader_parameter("reach", clampf(SkillFX.body_height(victim) * 0.4, 0.45, 1.4))
	mat.set_shader_parameter("tint", tint)
	mat.set_shader_parameter("strength", strength)
	# A status look on the body (StatusFX's ice, rime, poison, blood) stays on
	# under the flash: the flash is drawn as a pass after a copy of it, never
	# instead of it (the rime on frozen feet blinked off at every hit).
	var drawn: Dictionary = {}   # status look -> its copy carrying the flash
	for m in meshes:
		var look = (m as Node).get_meta("status_overlay") if (m as Node).has_meta("status_overlay") else null
		var overlay: Material = mat
		if look is Material:
			if not drawn.has(look):
				var copy := (look as Material).duplicate() as Material
				copy.next_pass = mat
				drawn[look] = copy
			overlay = drawn[look]
		(m as GeometryInstance3D).material_overlay = overlay
	var tw := victim.create_tween()
	tw.tween_method(func(v: float): mat.set_shader_parameter("strength", v), strength, 0.0, FLASH_SECONDS) \
		.set_ease(Tween.EASE_OUT).set_trans(Tween.TRANS_QUAD)
	# Back to the status look (StatusFX's ice, cold, poison or blood) if one runs.
	tw.tween_callback(func():
		for m in meshes:
			if not is_instance_valid(m):
				continue
			var current := (m as GeometryInstance3D).material_overlay
			if current == mat or (current != null and current.next_pass == mat):
				(m as GeometryInstance3D).material_overlay = (m as Node).get_meta("status_overlay") if (m as Node).has_meta("status_overlay") else null)

func _collect_meshes(node: Node, out: Array) -> void:
	for child in node.get_children():
		if child.name == "StatusFX":
			continue   # the stars and the ice are not the body
		if child is MeshInstance3D and (child as MeshInstance3D).visible:
			out.append(child)
		if out.size() < 24:
			_collect_meshes(child, out)

## The body takes the blow: its visual root rocks back away from the attacker
## (pivoting on the feet, so the head moves most) with a slight squash, then
## springs back. Bosses barely move; a frozen body only shudders. A player's
## visual root is steered every frame (broom lean), so a player only squashes.
func _recoil(victim: Node3D, strength: float, blow: Vector3) -> void:
	var visuals = victim.get("visuals")
	if visuals == null or not is_instance_valid(visuals) or not (visuals is Node3D):
		return
	var body := visuals as Node3D
	# The rest pose is remembered only while a recoil is running, so a body that
	# is rescaled later (a pooled mob reused as another variant) is never reset
	# to a stale size.
	if not body.has_meta("hit_base_scale"):
		body.set_meta("hit_base_scale", body.scale)
	var base: Vector3 = body.get_meta("hit_base_scale")
	var weight := 0.3 if victim.get("is_boss") == true else 1.0
	var frozen := (victim.get_node_or_null("StatusFX") as StatusFX) != null \
		and int((victim.get_node("StatusFX") as StatusFX).bits) & HPProtocol.STATUS_FREEZE != 0
	if frozen:
		weight *= 0.25
	var amount := 0.05 * strength * weight
	var previous = body.get_meta("hit_tween") if body.has_meta("hit_tween") else null
	if previous is Tween and (previous as Tween).is_valid():
		(previous as Tween).kill()
	var tw := body.create_tween()
	body.set_meta("hit_tween", tw)
	body.scale = base * Vector3(1.0 + amount, 1.0 - amount, 1.0 + amount)
	tw.set_parallel(true)
	tw.tween_property(body, "scale", base, 0.18).set_trans(Tween.TRANS_BACK).set_ease(Tween.EASE_OUT)
	var flat := Vector3(blow.x, 0.0, blow.z)
	if victim.is_in_group("mobs") and flat.length_squared() > 0.0001:
		# Euler YXZ: +x tips the top toward local +z, +z tips it toward local -x.
		var local := flat.normalized().rotated(Vector3.UP, -body.rotation.y)
		var lean := 0.13 * strength * weight
		var rest_x := 0.0
		var rest_z := 0.0
		body.rotation.x = local.z * lean
		body.rotation.z = -local.x * lean
		tw.tween_property(body, "rotation:x", rest_x, 0.32).set_trans(Tween.TRANS_ELASTIC).set_ease(Tween.EASE_OUT)
		tw.tween_property(body, "rotation:z", rest_z, 0.32).set_trans(Tween.TRANS_ELASTIC).set_ease(Tween.EASE_OUT)
	tw.chain().tween_callback(func():
		body.remove_meta("hit_base_scale")
		body.remove_meta("hit_tween"))

## A very short slow-down of the whole presentation on a heavy hit.
func _hitstop(seconds: float) -> void:
	# A remote authority keeps running during a hit. Slowing the whole client
	# changes prediction and network input cadence, not just the hit animation.
	# Online hits already have squash, flash, damage-number pop and camera shake.
	if SimNet.is_client or SimNet.has_peers():
		return
	if GameSettings.instance().shake_intensity <= 0.0:
		return
	_hitstop_until = maxf(_hitstop_until, _now() + seconds)
	Engine.time_scale = HITSTOP_SCALE

func _now() -> float:
	return float(Time.get_ticks_msec()) / 1000.0


class _Canvas extends Control:
	var owner_layer: HitFeedback = null
	func _draw() -> void:
		if owner_layer != null:
			owner_layer._draw_numbers(self)
