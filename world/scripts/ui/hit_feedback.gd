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
## Hit feel for the local player's own hits: the victim flashes white and gives
## a short squash, and a crit or finisher adds a very short hitstop (the
## camera shake lives in `CombatFeedback`, which owns the shake setting).

const RISE_PX := 90.0
const LIFETIME := 0.95
const CRIT_LIFETIME := 1.25
const MAX_NUMBERS := 48
const MAX_RANGE := 60.0
const FLASH_SECONDS := 0.13
const HITSTOP_SECONDS := 0.05
const HITSTOP_SCALE := 0.12

const COLOR_OUT := Color(1.0, 0.97, 0.9)
const COLOR_CRIT := Color(1.0, 0.92, 0.12)
const COLOR_CRIT_EDGE := Color(0.75, 0.08, 0.02)
const COLOR_FINISHER := Color(1.0, 0.6, 0.16)
const COLOR_TAKEN := Color(1.0, 0.27, 0.22)
const COLOR_OTHER := Color(0.78, 0.78, 0.78)

static var _instance: HitFeedback = null

var _numbers: Array = []
var _canvas: _Canvas = null
var _flash_material: StandardMaterial3D = null
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
	_flash_material = StandardMaterial3D.new()
	_flash_material.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	_flash_material.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	_flash_material.blend_mode = BaseMaterial3D.BLEND_MODE_ADD
	_flash_material.albedo_color = Color(1, 1, 1, 0)
	if SimAuthority.has_signal("entity_hit") and not SimAuthority.entity_hit.is_connected(_on_entity_hit):
		SimAuthority.entity_hit.connect(_on_entity_hit)

func _exit_tree() -> void:
	if _hitstop_until > 0.0:
		Engine.time_scale = 1.0
	if _instance == self:
		_instance = null

func _on_entity_hit(uid: int, amount: int, _hp: int, _spell_id: String, attacker_uid: int, flags: int) -> void:
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
	if attacker_uid == local and local != 0:
		if crit:
			_spawn_number(anchor, "%d!" % amount, COLOR_CRIT, 58.0 if not finisher else 64.0, true, "CRITICAL", COLOR_CRIT_EDGE)
			crits_shown += 1
		elif finisher:
			_spawn_number(anchor, str(amount), COLOR_FINISHER, 44.0, true)
		else:
			_spawn_number(anchor, str(amount), COLOR_OUT, 36.0, false)
		_flash(victim as Node3D, 1.0 if (crit or finisher) else 0.7)
		_squash(victim as Node3D, 1.6 if (crit or finisher) else 1.0)
		if crit or finisher:
			_hitstop(HITSTOP_SECONDS * (1.6 if crit and finisher else 1.0))
		if crit:
			var audio: Node = preload("res://scripts/spells/skill_fx.gd").audio_manager()
			if audio != null and audio.has_method("play_sound_at"):
				audio.call("play_sound_at", "ui_hit", (victim as Node3D).global_position, null, true)
		return
	_spawn_number(anchor, ("%d!" % amount) if crit else str(amount), COLOR_OTHER, 20.0, false)

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

## A brief additive white flash over every mesh of the victim's body.
func _flash(victim: Node3D, strength: float) -> void:
	var meshes: Array = []
	_collect_meshes(victim, meshes)
	if meshes.is_empty():
		return
	var mat := _flash_material.duplicate() as StandardMaterial3D
	mat.albedo_color = Color(1.0, 0.95, 0.85, 0.55 * strength)
	for m in meshes:
		(m as GeometryInstance3D).material_overlay = mat
	var tw := victim.create_tween()
	tw.tween_property(mat, "albedo_color:a", 0.0, FLASH_SECONDS)
	tw.tween_callback(func():
		for m in meshes:
			if is_instance_valid(m) and (m as GeometryInstance3D).material_overlay == mat:
				(m as GeometryInstance3D).material_overlay = null)

func _collect_meshes(node: Node, out: Array) -> void:
	for child in node.get_children():
		if child is MeshInstance3D and (child as MeshInstance3D).visible:
			out.append(child)
		if out.size() < 24:
			_collect_meshes(child, out)

## A quick squash-and-recover of the victim's visual root (bosses barely move).
func _squash(victim: Node3D, strength: float) -> void:
	var visuals = victim.get("visuals")
	if visuals == null or not is_instance_valid(visuals) or not (visuals is Node3D):
		return
	var body := visuals as Node3D
	# The rest scale is remembered only while a squash is running, so a body that
	# is rescaled later (a pooled mob reused as another variant) is never reset
	# to a stale size.
	if not body.has_meta("hit_base_scale"):
		body.set_meta("hit_base_scale", body.scale)
	var base: Vector3 = body.get_meta("hit_base_scale")
	var amount := 0.07 * strength * (0.35 if victim.get("is_boss") == true else 1.0)
	var previous = body.get_meta("hit_tween", null)
	if previous is Tween and (previous as Tween).is_valid():
		(previous as Tween).kill()
	var tw := body.create_tween()
	body.set_meta("hit_tween", tw)
	body.scale = base * Vector3(1.0 + amount, 1.0 - amount, 1.0 + amount)
	tw.tween_property(body, "scale", base, 0.14).set_trans(Tween.TRANS_BACK).set_ease(Tween.EASE_OUT)
	tw.tween_callback(func():
		body.remove_meta("hit_base_scale")
		body.remove_meta("hit_tween"))

## A very short slow-down of the whole presentation on a heavy hit.
func _hitstop(seconds: float) -> void:
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
