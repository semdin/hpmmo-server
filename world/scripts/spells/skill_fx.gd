extends RefCounted

## SkillFX - the spell effects facade over the layered effect scenes.
##
## Public API is unchanged since the prototype (`play_cast`, `play_impact`,
## `play_stun_stars`, `shake_camera`) so every existing call site - the
## projectile, mob attacks, the world's authoritative cast/impact hooks and the
## offline regression harness - keeps working, but every one of them now gets a
## layered effect built from `vfx_library.gd` instead of the old sphere/ring/
## cylinder kit.
##
## The rules this file enforces for every effect (12.4):
##   * emission origins sit on the ACTUAL animated wand socket when the caster
##     has one, and are pulled out of geometry for near-wall launches;
##   * zero-length directions and vertical aims are guarded (the collinear
##     `look_at` crash class from the baseline);
##   * effects are presentation: nothing here can produce a second hit;
##   * predicted feedback is registered by cast sequence so a rejection can
##     remove exactly what was predicted and nothing else.

const VFX = preload("res://scripts/spells/vfx_library.gd")
const SpellEffect = preload("res://scripts/spells/spell_effect.gd")
const QualityPreset = preload("res://scripts/world/quality_preset.gd")

const EFFECT_SCENES := {
	"basic_cast": "res://scenes/spells/fx_basic_cast.tscn",
	"stupefy": "res://scenes/spells/fx_stupefy.tscn",
	"incendio": "res://scenes/spells/fx_incendio.tscn",
	"bombarda": "res://scenes/spells/fx_bombarda.tscn",
	"expelliarmus": "res://scenes/spells/fx_expelliarmus.tscn",
	"protego": "res://scenes/spells/fx_protego.tscn",
	"ultimate": "res://scenes/spells/fx_ultimate.tscn",
}

const WARNING_SCENE := "res://scenes/spells/fx_boss_warning.tscn"
const TRAIL_SCENE := "res://scenes/spells/fx_broom_trail.tscn"

## Predicted casts, keyed "instance_id:cast_seq" -> effect node. A rejected cast
## removes its entry; nothing else is ever removed.
static var _predicted: Dictionary = {}
static var _active: Array = []


static func quality() -> String:
	return QualityPreset.current()


## ---------------------------------------------------------------- origins

## The wand socket of the animated rig, when the caster exposes one (player.gd
## builds `Socket_Wand` from the documented bone map). Falls back to a body
## offset so mobs and any rig without sockets still emit somewhere sane.
static func emission_origin(caster: Node3D, fallback: Vector3, dir: Vector3) -> Vector3:
	if caster == null or not is_instance_valid(caster):
		return fallback
	var origin := fallback
	# The equipped wand's own tip is the single definition of where a spell leaves
	# the caster: `HeroAppearance.wand_tip` marks it inside the prop, so it rides
	# the animation and the grip (hero_appearance.gd) instead of sitting at a
	# fixed scene coordinate. A wand-less caster - a mob, or a player with no main
	# hand - falls through to the wrist socket and then to the body offset.
	var tip: Node3D = HeroAppearance.wand_tip(caster)
	if tip != null and is_instance_valid(tip):
		origin = tip.global_position
	elif caster.has_method("socket"):
		var socket = caster.call("socket", "Socket_Wand")
		if socket is Node3D and is_instance_valid(socket):
			origin = (socket as Node3D).global_position + dir * 0.35
	elif caster.has_node("Visuals/WandTipMarker"):
		origin = (caster.get_node("Visuals/WandTipMarker") as Node3D).global_position
	# Near-wall launches: if the emitter is inside geometry, step it back along
	# the aim direction until it is clear. The effect must be visible even when
	# the player casts while hugging a wall.
	var space := caster.get_world_3d().direct_space_state
	var chest := caster.global_position + Vector3.UP * 1.2
	var query := PhysicsRayQueryParameters3D.create(chest, origin, 1)
	query.exclude = [caster.get_rid()] if caster is CollisionObject3D else []
	var hit := space.intersect_ray(query)
	if not hit.is_empty():
		origin = (hit["position"] as Vector3) - dir * 0.25
	return origin


## An aim direction that is never zero-length and never collinear with up.
static func safe_direction(raw: Vector3, fallback: Vector3 = Vector3.FORWARD) -> Vector3:
	var dir := raw
	if dir.length_squared() < 0.0001:
		dir = fallback
	if dir.length_squared() < 0.0001:
		dir = Vector3.FORWARD
	return dir.normalized()


## ---------------------------------------------------------------- spawning

static func spawn_stage(world: Node3D, spell_id: String, stage: String, origin: Vector3,
		dir: Vector3, caster: Node3D = null, opts: Dictionary = {}) -> Node3D:
	if not is_instance_valid(world) or not VFX.SPELLS.has(spell_id):
		return null
	var effect: Node3D = SpellEffect.new()
	world.add_child(effect)
	effect.call("setup", spell_id, stage, quality(), origin, safe_direction(dir), caster, opts)
	_track(effect)
	return effect


static func _track(effect: Node3D) -> void:
	_active.append(effect)
	if _active.size() > 128:
		_active = _active.slice(_active.size() - 64)


## Play the cast stage of a spell. Kept signature-compatible with the prototype.
static func play_cast(world: Node3D, caster: Node3D, spell_id: String, spawn_pos: Vector3, dir: Vector3) -> void:
	if not VFX.SPELLS.has(spell_id):
		return
	var aim := safe_direction(dir, Vector3.FORWARD)
	var origin := emission_origin(caster, spawn_pos, aim)
	# Incendio is a short-range cone: the burst starts at the caster and points
	# down the aim. Everything else is a cast flash at the emitter.
	spawn_stage(world, spell_id, "cast", origin, aim, caster)


## Play the impact stage. `victim` is optional: a burn sustain attaches to it.
static func play_impact(world: Node3D, pos: Vector3, spell_id: String, victim: Node3D = null) -> void:
	if not VFX.SPELLS.has(spell_id):
		return
	var opts := {"target_position": pos}
	if victim != null:
		opts["follow_target"] = victim
	var effect := spawn_stage(world, spell_id, "impact", pos, Vector3.UP, null, opts)
	if effect == null:
		return
	if spell_id == "incendio" and victim != null:
		# The burn is server-timed; the sustain runs for the authoritative burn
		# duration (spells.json: 3 ticks x 1000 ms) and no longer.
		play_burn(world, victim, 3.0)


## Burn sustain on a victim for `seconds` (the authoritative status duration).
static func play_burn(world: Node3D, victim: Node3D, seconds: float) -> Node3D:
	if not is_instance_valid(victim):
		return null
	var effect := spawn_stage(world, "incendio", "sustain", victim.global_position, Vector3.UP, null,
		{"follow_target": victim})
	if effect == null:
		return null
	effect.set_meta("duration_override", seconds)
	return effect


## The stun indicator, kept for compatibility with the prototype's API.
static func play_stun_stars(world: Node3D, target: Node3D) -> void:
	if not is_instance_valid(world) or not is_instance_valid(target):
		return
	spawn_stage(world, "stupefy", "sustain", target.global_position + Vector3.UP * 1.9,
		Vector3.UP, null, {"follow_target": target})


## ---------------------------------------------------------------- prediction

## Predicted cast presentation, played the moment the client sends the request.
## Registered by cast sequence so `cancel_predicted` removes exactly this one.
static func play_predicted_cast(caster: Node3D, spell_id: String, cast_seq: int) -> Node3D:
	if not is_instance_valid(caster) or not VFX.SPELLS.has(spell_id):
		return null
	var world := caster.get_parent()
	if world == null:
		return null
	var aim := safe_direction(caster.visuals.global_basis.z if "visuals" in caster else Vector3.FORWARD)
	var origin := emission_origin(caster, caster.global_position + Vector3.UP * 1.25, aim)
	var effect := spawn_stage(world, spell_id, "cast", origin, aim, caster)
	if effect != null:
		_predicted["%d:%d" % [caster.get_instance_id(), cast_seq]] = effect
	var manager := audio_manager()
	if manager != null:
		manager.call("play_sound_at", "spell_%s_cast" % spell_id, origin, caster)
	return effect


## The AudioManager autoload, or null when there is none (headless unit use).
static func audio_manager() -> Node:
	var loop := Engine.get_main_loop()
	if loop == null or not (loop is SceneTree):
		return null
	return (loop as SceneTree).root.get_node_or_null("AudioManager")


## A rejected cast removes its predicted feedback - and only its own.
static func cancel_predicted(caster: Node3D, cast_seq: int) -> void:
	if not is_instance_valid(caster):
		return
	var key := "%d:%d" % [caster.get_instance_id(), cast_seq]
	if not _predicted.has(key):
		return
	var effect = _predicted[key]
	_predicted.erase(key)
	if is_instance_valid(effect):
		effect.call("cancel", "rejected")


static func predicted_count() -> int:
	var live := 0
	for key in _predicted:
		if is_instance_valid(_predicted[key]):
			live += 1
	return live


## ---------------------------------------------------------------- lifecycle

## Cancel every live effect owned by a node (death, map transfer, shutdown).
static func cancel_all_of(owner: Node3D) -> int:
	var cancelled := 0
	for effect in _active:
		if not is_instance_valid(effect):
			continue
		if effect.get("caster") == owner:
			effect.call("cancel", "owner_gone")
			cancelled += 1
	return cancelled


static func active_count() -> int:
	var live := 0
	for effect in _active:
		if is_instance_valid(effect):
			live += 1
	return live


## Broom trail scene, instanced by broom_flight (the documented spell-effect hook).
static func make_trail(owner: Node3D) -> Node3D:
	if not ResourceLoader.exists(TRAIL_SCENE):
		return null
	var packed: PackedScene = load(TRAIL_SCENE)
	var trail := packed.instantiate()
	owner.add_child(trail)
	if trail.has_method("setup"):
		trail.call("setup", owner)
	return trail


static func shake_camera(caster: Node3D, strength: float) -> void:
	if not is_instance_valid(caster):
		return
	var cam := caster.get_node_or_null("CameraPivot/SpringArm3D/Camera3D") as Camera3D
	if cam == null:
		return
	if cam.has_meta("spell_shake"):
		return
	cam.set_meta("spell_shake", true)
	var orig_h := cam.h_offset
	var orig_v := cam.v_offset
	cam.h_offset = randf_range(-strength, strength) * 0.4
	cam.v_offset = randf_range(-strength, strength) * 0.4
	var tw := cam.create_tween()
	tw.tween_property(cam, "h_offset", orig_h, 0.3)
	tw.parallel().tween_property(cam, "v_offset", orig_v, 0.3)
	tw.tween_callback(func(): cam.remove_meta("spell_shake"))
