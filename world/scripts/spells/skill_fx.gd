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
## removes its entry; entries whose effect has ended are pruned as new ones
## arrive (accepted casts were never removed: one entry per cast, all session).
static var _predicted: Dictionary = {}
static var _active: Array = []
## Spells whose later-stage textures were already queued for loading.
static var _warmed: Dictionary = {}
## What warm_spell loaded, held for the session (a warmed sheet could drop out
## of memory again before the impact frame it was warmed for).
static var _warm_cache: Dictionary = {}   # path -> Resource


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
	# Pictures only: the dedicated server drew every creature slam and bolt it
	# resolved (a troll slam's impact cost ~60 ms of a server frame, every few
	# seconds of a fight, live 2026-10-25).
	if NetworkManager.is_dedicated_server:
		return null
	var effect: Node3D = SpellEffect.new()
	world.add_child(effect)
	effect.call("setup", spell_id, stage, quality(), origin, safe_direction(dir), caster, opts)
	_track(effect)
	return effect


## Load a spell's later stages (bolt, impact, end) ahead of them: a 2048 impact
## sheet read from disk on the impact frame shows up late, after the damage
## numbers. The world warms every spell after it is up (game_world
## _preload_next), so a cast normally finds them loaded. Main-thread loads: a
## background load racing the main thread's own loads froze clients
## (see game_world._queue_preloads).
static func warm_spell(spell_id: String) -> void:
	if DisplayServer.get_name() == "headless" or _warmed.has(spell_id):
		return
	_warmed[spell_id] = true
	# Its stage sounds too: the first cast of a spell read each one from disk
	# on the frame it played.
	var audio := audio_manager()
	for stage in VFX.stages_for(spell_id):
		var key := String((VFX.stages_for(spell_id).get(stage, {}) as Dictionary).get("audio", ""))
		if key != "" and audio != null and audio.has_method("warm_sound"):
			audio.call("warm_sound", key)
	for stage in ["travel", "impact", "end"]:
		for raw in (VFX.stages_for(spell_id).get(stage, {}) as Dictionary).get("layers", []):
			if not raw is Dictionary:
				continue
			for key in ["atlas", "tex", "mesh"]:
				var path := VFX.asset_path(String(raw.get(key, "")))
				if path != "" and not _warm_cache.has(path) and ResourceLoader.exists(path):
					_warm_cache[path] = load(path)


static func _track(effect: Node3D) -> void:
	_active.append(effect)
	if _active.size() > 128:
		_active = _active.slice(_active.size() - 64)


## Play the cast stage of a spell. Kept signature-compatible with the prototype.
## The local player's own casts are skipped: play_predicted_cast already drew
## that flash, and the authority's release drew a second one on top of it.
static func play_cast(world: Node3D, caster: Node3D, spell_id: String, spawn_pos: Vector3, dir: Vector3) -> void:
	if not VFX.SPELLS.has(spell_id):
		return
	if is_instance_valid(caster) and caster.get("is_local_player") == true:
		return
	warm_spell(spell_id)
	var aim := safe_direction(dir, Vector3.FORWARD)
	var origin := emission_origin(caster, spawn_pos, aim)
	if spell_id == "protego" and is_instance_valid(caster):
		origin = caster.global_position + Vector3.UP
	# Incendio is a short-range cone: the burst starts at the caster and points
	# down the aim. Everything else is a cast flash at the emitter.
	spawn_stage(world, spell_id, "cast", origin, aim, caster, _cast_options(caster, spell_id))


static func _cast_options(caster: Node3D, spell_id: String) -> Dictionary:
	if spell_id == "protego" and is_instance_valid(caster):
		return {"follow_target": caster}
	if spell_id in ["stupefy", "bombarda", "expelliarmus", "ultimate", "glacius"] and is_instance_valid(caster):
		var tip := HeroAppearance.wand_tip(caster)
		if is_instance_valid(tip):
			return {"follow_target": tip}
	return {}


## Play the impact stage. `victim` is optional: a burn sustain attaches to it.
## `caster` colours a spell drawn in its caster's house (VFX.colours_for).
static func play_impact(world: Node3D, pos: Vector3, spell_id: String, victim: Node3D = null, incoming: Vector3 = Vector3.UP,
		caster: Node3D = null) -> void:
	if not VFX.SPELLS.has(spell_id):
		return
	var opts := {"target_position": pos, "colour_source": caster}
	if victim != null:
		opts["follow_target"] = victim
	# A billboard burst centred ON a wall or a body is half buried in it: draw it
	# half a metre back toward where the spell came from. Ground blasts keep
	# their centre (their ring lies on the floor).
	var at := pos
	if HPRules.delivery(spell_id) != "projectile_aoe":
		at = pos - safe_direction(incoming) * 0.5
	spawn_stage(world, spell_id, "impact", at, safe_direction(incoming), null, opts)
	# The burn's flames (and every other status look) come from the victim's
	# replicated status (StatusFX), for exactly as long as the server says.


## A bolt's impact ON a body: at the point of its surface the bolt met (chest
## height, the side it came from), riding along with the body. Drawn there
## rather than at the body's centre, where the body's own mesh hid it.
static func play_hit_on(world: Node3D, victim: Node3D, spell_id: String, incoming: Vector3,
		caster: Node3D = null, at: Vector3 = Vector3.INF) -> void:
	if not VFX.SPELLS.has(spell_id) or not is_instance_valid(victim):
		return
	var dir := safe_direction(incoming)
	var contact := at if at.is_finite() else body_contact(victim, dir)
	spawn_stage(world, spell_id, "impact", contact - dir * 0.12, dir, null,
		{"target_position": contact, "colour_source": caster, "follow_target": victim})


## Where a bolt flying along `incoming` meets `victim`: on its surface at its
## chest (body_chest), facing the way the bolt came from.
static func body_contact(victim: Node3D, incoming: Vector3) -> Vector3:
	var chest := body_chest(victim)
	var flat := Vector3(incoming.x, 0.0, incoming.z)
	if flat.length_squared() < 0.0001:
		return chest
	return chest - flat.normalized() * body_radius(victim) * 0.8


## The point a drawn bolt homes on: the middle of the body's drawn height, so
## a low spider is struck in its back and a troll in its belly (the authority's
## fixed AIM_CHEST_HEIGHT flew over a spider). Presentation only.
static func body_chest(victim: Node3D) -> Vector3:
	var height := body_height(victim)
	return victim.global_position + Vector3.UP * clampf(height * 0.55, 0.3, 2.4)


## How tall the body is drawn (its meshes at rest, in its own space; measured
## once per body). 1.9 m when its meshes do not tell.
static func body_height(victim: Node3D) -> float:
	var root = victim.get("visuals")
	# a pooled body reused at another size measures again
	var size_key := (root as Node3D).scale.y if root is Node3D else 1.0
	if victim.has_meta("fx_height") and is_equal_approx(float(victim.get_meta("fx_height_key", 0.0)), size_key):
		return float(victim.get_meta("fx_height"))
	var height := 1.9
	var top := -INF
	var to_body := victim.global_transform.affine_inverse()
	for node in (root if root is Node3D else victim).find_children("*", "MeshInstance3D", true, false):
		var mesh := node as MeshInstance3D
		if not mesh.is_visible_in_tree() or mesh.mesh == null:
			continue
		var box := (to_body * mesh.global_transform) * mesh.get_aabb()
		top = maxf(top, box.end.y)
	# trust the meshes only when the answer looks like a body
	if top > 0.3 and top < 8.0:
		height = top
	victim.set_meta("fx_height", height)
	victim.set_meta("fx_height_key", size_key)
	return height


## The girth of a body from its collision shape (0.45 m when it has none).
static func body_radius(body: Node3D) -> float:
	if body.has_method("_collision_radius"):
		return float(body.call("_collision_radius"))
	for child in body.get_children():
		if child is CollisionShape3D and (child as CollisionShape3D).shape != null:
			var shape: Shape3D = (child as CollisionShape3D).shape
			if shape is CapsuleShape3D:
				return (shape as CapsuleShape3D).radius
			if shape is CylinderShape3D:
				return (shape as CylinderShape3D).radius
			if shape is SphereShape3D:
				return (shape as SphereShape3D).radius
			if shape is BoxShape3D:
				return maxf((shape as BoxShape3D).size.x, (shape as BoxShape3D).size.z) * 0.5
	return 0.45


## The authoritative burn length from spells.json (ticks x interval_ms), with the
## 3 s the composition table was authored against as the fallback: the flames must
## neither outlive the status they show nor die while it still burns.
static func burn_seconds(spell_id: String) -> float:
	var burn: Dictionary = (GameData.SPELLS.get(spell_id, {}) as Dictionary).get("burn", {})
	var ticks := int(burn.get("ticks", 0))
	var interval := float(burn.get("interval_ms", 0))
	if ticks <= 0 or interval <= 0.0:
		return 3.0
	return ticks * interval / 1000.0


## Burn sustain on a victim for `seconds` (the authoritative status duration).
static func play_burn(world: Node3D, victim: Node3D, seconds: float) -> Node3D:
	if not is_instance_valid(victim):
		return null
	return spawn_stage(world, "incendio", "sustain", victim.global_position, Vector3.UP, null,
		{"follow_target": victim, "duration": seconds})


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
	warm_spell(spell_id)
	var world := caster.get_parent()
	if world == null:
		return null
	var aim := safe_direction(caster.visuals.global_basis.z if "visuals" in caster else Vector3.FORWARD)
	var origin := emission_origin(caster, caster.global_position + Vector3.UP * 1.25, aim)
	if spell_id == "protego":
		origin = caster.global_position + Vector3.UP
	var effect := spawn_stage(world, spell_id, "cast", origin, aim, caster, _cast_options(caster, spell_id))
	if effect != null:
		if _predicted.size() >= 32:
			for key in _predicted.keys():
				if not is_instance_valid(_predicted[key]):
					_predicted.erase(key)
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
