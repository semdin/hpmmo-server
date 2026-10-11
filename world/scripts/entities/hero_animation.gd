extends Node
class_name HeroAnimation

## Rig animation graph("Build an animation graph for idle, walk,
## run, strafe, turn, jump, fall, land, cast variants, hit, stun, death, revive,
## interact and mounted states. Use upper-body casting blends where appropriate,
## with explicit movement restrictions for committed attacks. Footsteps and wand
## release events should align with contact/motion.")
##
## Structure - one AnimationTree over the imported hero clips:
##
##   output
##     cast_blend   (Blend2: upper-body cast layer over the locomotion layer)
##       os_blend   (Blend2: one-shots such as hit/death/land over locomotion)
##         locomotion (crossfade between velocity blend space and authored states)
##         oneshot    (hit / death / stun / land / mount clips)
##       upper        (upper-body-only cast clip, no leg or hip tracks)
##
## The state machine below owns which clip the locomotion layer plays; the tree
## owns only the blending. Footstep events are read from the skeleton's own foot
## bones (a real contact test, not a guessed time), and the cast clip is seeked so
## its extension pose lands on the predicted/server-reported release moment.

signal event_fired(event_name: String)

const LOCO_LAYER := 0
const UPPER_LAYER := 1

## Clips that must loop. The list is the single declaration of loop modes - no
## caller has to guess, and every clip not listed is a one-shot.
const LOOPING := [
	"Idle", "Walk_A", "Running_A", "Walk_Back", "Strafe_L", "Strafe_R",
	"Fall", "Fall_Loop", "Cast_Idle", "Cast_Idle_Loop", "Sit_Chair_Idle",
	"Broom_Seated_Idle", "Broom_Cruise", "Broom_Accelerate",
	"Broom_Bank_L", "Broom_Bank_R", "Broom_Climb", "Broom_Dive", "Broom_Brake",
	"Stun_Loop",
]

## Clip aliases: the Godot glTF importer strips a trailing `_Loop` and turns it
## into the import's loop mode, so both spellings resolve here.
const ALIASES := {
	"Fall_Loop": "Fall",
	"Cast_Idle_Loop": "Cast_Idle",
	"Stun_Loop": "Stun",
}

## Nominal length used when a clip is missing entirely, so a machine-driven game
## loop never divides by zero on a bad import.
const FALLBACK_LENGTH := 0.5

var anim_player: AnimationPlayer
var tree: AnimationTree
var root: AnimationNodeBlendTree
var loco_transition: AnimationNodeTransition
var ground_space: AnimationNodeBlendSpace2D
var _loco_port := ""
var _ground_target := Vector2.ZERO
var _ground_blend := Vector2.ZERO
var _ground_speed := 0.0
var _ground_rate := 1.0
const WALK_BLEND := 0.42
const GROUND_BLEND_SECONDS := 0.18
const RUN_REFERENCE_SPEED := 5.5
var oneshot_node: AnimationNodeAnimation
var upper_node: AnimationNodeAnimation
var skeleton: Skeleton3D
## Masked upper-body cast layer (see cast_layer_modifier.gd for why the blend
## tree alone cannot do this).
var cast_layer: CastLayerModifier

var current_state := ""
var current_clip := ""
var oneshot_clip := ""
var oneshot_left := 0.0
var cast_left := 0.0
var cast_clip := ""
var _cast_weight := 0.0
var _cast_blend_in := 0.125
var _os_weight := 0.0
var _foot_min := {}
var _foot_low := {}
var _foot_high := {}
var _last_clip_played := ""
var enabled := true

func setup(animation_player: AnimationPlayer, skeleton_node: Skeleton3D, host: Node = null) -> void:
	anim_player = animation_player
	skeleton = skeleton_node
	if anim_player == null:
		enabled = false
		return
	root = AnimationNodeBlendTree.new()
	tree = AnimationTree.new()
	tree.name = "HeroAnimationTree"
	tree.tree_root = root
	# The mixer must write BEFORE the skeleton runs its modifiers: the masked
	# cast layer is a SkeletonModifier3D that reads what the mixer wrote and
	# fills in the bones the locomotion clip does not own. Node processing is in
	# tree order, so the tree is inserted ahead of the model.
	if host:
		host.add_child(tree)
		host.move_child(tree, 0)
	else:
		add_child(tree)
	tree.anim_player = tree.get_path_to(anim_player)
	oneshot_node = AnimationNodeAnimation.new()
	upper_node = AnimationNodeAnimation.new()
	var os_blend := AnimationNodeBlend2.new()
	var cast_blend := AnimationNodeBlend2.new()
	_build_locomotion()
	root.add_node("oneshot", oneshot_node, Vector2(-200, 150))
	root.add_node("oneshot_seek", AnimationNodeTimeSeek.new())
	root.add_node("oneshot_speed", AnimationNodeTimeScale.new())
	root.connect_node("oneshot_seek", 0, "oneshot")
	root.connect_node("oneshot_speed", 0, "oneshot_seek")
	root.add_node("upper", upper_node, Vector2(-200, 300))
	# Godot blends a clip that does not animate a track toward the rest pose, so
	# an upper-body-only clip dragged through a plain Blend2 pulls the legs off
	# locomotion. A per-node filter restricts the layer to the paths it owns.
	_configure_upper_filter()
	root.add_node("os_blend", os_blend, Vector2(0, 60))
	root.add_node("cast_blend", cast_blend, Vector2(200, 120))
	root.connect_node("os_blend", 0, "locomotion")
	root.connect_node("os_blend", 1, "oneshot_speed")
	root.connect_node("cast_blend", 0, "os_blend")
	root.connect_node("cast_blend", 1, "upper")
	root.connect_node("output", 0, "cast_blend")
	tree.active = true
	if skeleton_node:
		cast_layer = CastLayerModifier.new()
		cast_layer.name = "CastLayerModifier"
		skeleton_node.add_child(cast_layer)
	_set_weight("os_blend", 0.0)
	_set_weight("cast_blend", 0.0)
	for name in LOOPING:
		var anim := _animation(name)
		if anim:
			anim.loop_mode = Animation.LOOP_LINEAR
	for one_shot in ["Jump_Start", "Land", "Mount_Broom", "Dismount_Broom", "Revive",
			"Death_A", "Hit_A", "Hit_B", "Interact", "Melee_Chop_A", "Melee_Chop_B",
			"Spellcast_Shoot", "Spellcast_Raise", "Cast_Exit", "Broom_Takeoff", "Broom_Land"]:
		var anim := _animation(one_shot)
		if anim:
			anim.loop_mode = Animation.LOOP_NONE
	# Finger bones must only rotate at knuckle joints, never translate away from parent joints.
	# Strip spurious translation tracks on fingers from all imported clips to prevent mesh distortion.
	if anim_player:
		for anim_name in anim_player.get_animation_list():
			var anim := anim_player.get_animation(anim_name)
			if anim:
				for t in range(anim.get_track_count() - 1, -1, -1):
					if anim.track_get_type(t) == Animation.TYPE_POSITION_3D:
						var path := String(anim.track_get_path(t))
						for f in ["Index", "Middle", "Ring", "Pinky", "Thumb"]:
							if f in path:
								anim.remove_track(t)
								break


## Restrict the cast layer to the bone paths an upper-body clip owns, so every
## other path passes through the locomotion layer untouched.
func _configure_upper_filter() -> void:
	upper_node.filter_enabled = true
	var prefix := "Skeleton3D:"
	var probe_clip := _animation("Spellcast_Shoot_Upper")
	if probe_clip and probe_clip.get_track_count() > 0:
		# Filters live in the same path space as the tracks; take the prefix from
		# the imported animation instead of hardcoding the node chain.
		var first := String(probe_clip.track_get_path(0))
		if first.contains(":"):
			prefix = first.split(":")[0] + ":"
	var bones: Array[String] = ["Abdomen", "Torso", "Chest", "Neck", "Head"]
	for side in ["L", "R"]:
		for bone in ["Shoulder", "UpperArm", "LowerArm", "Wrist"]:
			bones.append("%s_%s" % [bone, side])
			bones.append("%s.%s" % [bone, side])
		for finger in ["Index", "Middle", "Ring", "Pinky"]:
			for n in range(1, 5):
				bones.append("%s%d_%s" % [finger, n, side])
				bones.append("%s%d.%s" % [finger, n, side])
		for n in range(1, 4):
			bones.append("Thumb%d_%s" % [n, side])
			bones.append("Thumb%d.%s" % [n, side])
	for bone in bones:
		upper_node.set_filter_path(NodePath(prefix + bone), true)

## ---------------------------------------------------------------- clip lookup## ---------------------------------------------------------------- clip lookup

func _animation(clip_name: String) -> Animation:
	if anim_player == null:
		return null
	var resolved := String(ALIASES.get(clip_name, clip_name))
	if anim_player.has_animation(resolved):
		return anim_player.get_animation(resolved)
	if anim_player.has_animation(clip_name):
		return anim_player.get_animation(clip_name)
	return null

func has_clip(clip_name: String) -> bool:
	return _animation(clip_name) != null

func clip_length(clip_name: String) -> float:
	var anim := _animation(clip_name)
	if anim == null:
		return FALLBACK_LENGTH
	return maxf(0.05, anim.length)

func _resolve_name(clip_name: String) -> String:
	var resolved := String(ALIASES.get(clip_name, clip_name))
	if anim_player != null and anim_player.has_animation(resolved):
		return resolved
	return clip_name

## ---------------------------------------------------------------- locomotion

## Ground motion has a continuous velocity blend. Other states retain their
## authored clips, with a real crossfade on entry and a reset on re-entry.
func _build_locomotion() -> void:
	ground_space = AnimationNodeBlendSpace2D.new()
	ground_space.sync_mode = AnimationNodeBlendSpace2D.SYNC_MODE_CYCLIC_MUTABLE
	var points := {"Idle": Vector2.ZERO, "Walk_A": Vector2(0, WALK_BLEND),
		"Running_A": Vector2(0, 1), "Walk_Back": Vector2(0, -1),
		"Strafe_L": Vector2(1, 0), "Strafe_R": Vector2(-1, 0)}
	for clip: String in points:
		var node := AnimationNodeAnimation.new()
		node.animation = _resolve_name(clip)
		ground_space.add_blend_point(node, points[clip], -1, clip)
	root.add_node("ground", ground_space)
	root.add_node("ground_speed", AnimationNodeTimeScale.new())
	root.connect_node("ground_speed", 0, "ground")
	loco_transition = AnimationNodeTransition.new()
	loco_transition.xfade_time = GROUND_BLEND_SECONDS
	loco_transition.allow_transition_to_self = true
	var clips := anim_player.get_animation_list()
	loco_transition.input_count = clips.size() + 1
	loco_transition.set_input_name(0, "ground")
	loco_transition.set_input_reset(0, false)
	root.add_node("locomotion", loco_transition, Vector2(-200, 0))
	root.connect_node("locomotion", 0, "ground_speed")
	for i in range(clips.size()):
		var node := AnimationNodeAnimation.new()
		node.animation = clips[i]
		var node_name := "clip_%d" % i
		root.add_node(node_name, node)
		loco_transition.set_input_name(i + 1, clips[i])
		loco_transition.set_input_reset(i + 1, true)
		root.connect_node("locomotion", i + 1, node_name)

## Velocity is in the character's facing space: x left, y forward. Project
## diagonals onto the blend diamond so they mix directions without adding idle.
func set_ground_motion(local_velocity: Vector2) -> void:
	if not enabled:
		return
	_ground_speed = local_velocity.length()
	var direction := local_velocity / maxf(0.001, absf(local_velocity.x) + absf(local_velocity.y))
	# Gait follows actual metres/second, not the current gameplay speed cap.
	var strength := clampf(_ground_speed / RUN_REFERENCE_SPEED, 0.0, 1.0)
	_ground_target = direction * strength if _ground_speed >= 0.25 else Vector2.ZERO
	current_state = "idle"
	current_clip = "Idle"
	if _ground_speed >= 0.25:
		if direction.y < -0.5:
			current_state = "walk_back"
			current_clip = "Walk_Back"
		elif direction.x > 0.5:
			current_state = "strafe_l"
			current_clip = "Strafe_L"
		elif direction.x < -0.5:
			current_state = "strafe_r"
			current_clip = "Strafe_R"
		else:
			current_state = "walk" if strength < WALK_BLEND else "run"
			current_clip = "Walk_A" if strength < WALK_BLEND else "Running_A"
	if _loco_port != "ground":
		tree.set("parameters/locomotion/transition_request", "ground")
		_loco_port = "ground"

func _tick_ground(delta: float) -> void:
	# A bounded blend also finishes completely at rest, keeping planted idle feet.
	_ground_blend = _ground_blend.move_toward(_ground_target, delta / GROUND_BLEND_SECONDS)
	tree.set("parameters/ground/blend_position", _ground_blend)
	var gait := smoothstep(WALK_BLEND, 1.0, absf(_ground_blend.x) + absf(_ground_blend.y))
	var nominal_speed := lerpf(2.4, 5.5, gait)
	var rate := clampf(_ground_speed / nominal_speed, 0.55, 1.65)
	if _ground_target == Vector2.ZERO:
		rate = 1.0
	_ground_rate = lerpf(_ground_rate, rate, 1.0 - exp(-14.0 * delta))
	tree.set("parameters/ground_speed/scale", _ground_rate)

## Change the locomotion clip. `state` is the gameplay state name the caller
## owns; the same state AND clip are a no-op unless `restart` is set.
func set_locomotion(state: String, clip_name: String, restart := false) -> void:
	if not enabled or anim_player == null:
		return
	var resolved := _resolve_name(clip_name)
	if state == current_state and resolved == current_clip and not restart:
		return
	if not anim_player.has_animation(resolved):
		return
	current_state = state
	current_clip = resolved
	_last_clip_played = resolved
	if _loco_port != resolved or restart:
		tree.set("parameters/locomotion/transition_request", resolved)
		_loco_port = resolved

func has_oneshot() -> bool:
	return oneshot_left > 0.0

## Play a one-shot over the locomotion layer (hit, death, stun, land, mount).
func play_oneshot(clip_name: String, speed := 1.0) -> void:
	if not enabled or anim_player == null:
		return
	var resolved := _resolve_name(clip_name)
	if not anim_player.has_animation(resolved):
		return
	oneshot_node.animation = resolved
	tree.set("parameters/oneshot_seek/seek_request", 0.0)
	tree.set("parameters/oneshot_speed/scale", maxf(0.05, speed))
	oneshot_clip = resolved
	var anim := anim_player.get_animation(resolved)
	var length := (anim.length if anim else FALLBACK_LENGTH) / maxf(0.05, speed)
	oneshot_left = maxf(0.05, length)

func cancel_oneshot() -> void:
	oneshot_left = 0.0

## ---------------------------------------------------------------- cast layer

## Start an upper-body cast blend. `upper_clip` should be a clip that carries no
## leg or hip tracks (the `*_Upper` variants), so locomotion keeps driving the
## lower body while the spell plays above it.
func start_cast(upper_clip: String, hold_seconds: float) -> void:
	if not enabled or anim_player == null:
		return
	var resolved := _resolve_name(upper_clip)
	var clip := _animation(resolved)
	if clip == null:
		return
	upper_node.animation = ""
	cast_clip = resolved
	cast_left = maxf(0.05, hold_seconds)
	_cast_blend_in = 0.125
	if cast_layer:
		cast_layer.play(clip)

## Point the casting arm at `point` (world space) for the duration of the cast:
## the clip supplies the gesture, this makes it face the target. Call before
## `start_cast` (or any time during it); `end_cast` releases the aim.
func set_cast_aim(point: Vector3) -> void:
	if cast_layer:
		cast_layer.set_aim(point, true)

## Hand the casting arm back to the clip (a melee swing aims itself).
func clear_cast_aim() -> void:
	if cast_layer:
		cast_layer.set_aim(Vector3.ZERO, false)

func cast_aiming() -> bool:
	return cast_layer != null and cast_layer.aim_active()

func end_cast() -> void:
	cast_left = 0.0
	if cast_layer:
		cast_layer.stop()
		cast_layer.set_aim(Vector3.ZERO, false)

func casting() -> bool:
	return cast_left > 0.0

## Retime the clip's windup and recovery around the release beat. A seek alone
## cannot align a short clip to a longer windup without skipping preparation.
func align_cast(release_seconds_from_now: float, release_fraction := 0.45) -> float:
	if cast_clip == "" or anim_player == null:
		return release_fraction
	var anim := anim_player.get_animation(cast_clip)
	if anim == null:
		return release_fraction
	var fraction := clampf(release_fraction, 0.05, 0.95)
	_cast_blend_in = clampf(release_seconds_from_now * 0.65, 0.025, 0.125)
	if cast_layer:
		cast_layer.align_release(release_seconds_from_now, fraction, cast_left)
	return fraction

## ---------------------------------------------------------------- per-frame

func tick(delta: float) -> void:
	if not enabled:
		return
	_tick_ground(delta)
	if oneshot_left > 0.0:
		oneshot_left = maxf(0.0, oneshot_left - delta)
		if oneshot_left <= 0.0 and oneshot_clip != "":
			event_fired.emit("oneshot_end:%s" % oneshot_clip)
			oneshot_clip = ""
	if cast_left > 0.0:
		cast_left = maxf(0.0, cast_left - delta)
		if cast_left <= 0.0 and cast_clip != "":
			cast_clip = ""
			if cast_layer:
				cast_layer.stop()
	var os_target := 1.0 if oneshot_left > 0.0 else 0.0
	var cast_target := 1.0 if cast_left > 0.0 else 0.0
	_os_weight = move_toward(_os_weight, os_target, delta * 6.0)
	_cast_weight = move_toward(_cast_weight, cast_target,
		delta / (_cast_blend_in if cast_target > 0.0 else 0.18))
	_set_weight("os_blend", _os_weight)
	_set_weight("cast_blend", 0.0)
	if cast_layer:
		cast_layer.weight = _cast_weight
	if skeleton:
		_scan_footsteps(delta)

func _set_weight(node_name: String, value: float) -> void:
	if tree:
		tree.set("parameters/%s/blend_amount" % node_name, clampf(value, 0.0, 1.0))

func oneshot_weight() -> float:
	return _os_weight

func cast_weight() -> float:
	return _cast_weight

## ---------------------------------------------------------------- footsteps

## Contact detection from the rig, not from a guessed time: a footstep fires
## when a foot bone enters the lowest part of its own recent vertical range while
## the body is actually moving. The range is tracked per foot, so it works
## whether a stride lifts the ankle 5 mm or 20 cm, and it survives a replaced or
## retimed clip.
const FOOTSTEP_MOVE_SPEED := 0.6
const FOOTSTEP_BAND := 0.25
const FOOTSTEP_ENVELOPE_DECAY := 0.0004

func _scan_footsteps(delta: float) -> void:
	var body := owner_body()
	if body is CharacterBody3D:
		var horizontal := Vector2((body as CharacterBody3D).velocity.x, (body as CharacterBody3D).velocity.z).length()
		if horizontal < FOOTSTEP_MOVE_SPEED or not (body as CharacterBody3D).is_on_floor() \
				or _loco_port != "ground":
			_foot_low.clear()
			_foot_min.clear()
			_foot_high.clear()
			return
	for side in ["L", "R"]:
		var idx := skeleton.find_bone("Foot_%s" % side)
		if idx < 0:
			idx = skeleton.find_bone("Foot.%s" % side)
		if idx < 0:
			continue
		var y := skeleton.get_bone_global_pose(idx).origin.y
		var lo: float = _foot_min.get(side, y)
		var hi: float = _foot_high.get(side, y)
		lo = minf(y, lo + FOOTSTEP_ENVELOPE_DECAY * delta * 60.0)
		hi = maxf(y, hi - FOOTSTEP_ENVELOPE_DECAY * delta * 60.0)
		_foot_min[side] = lo
		_foot_high[side] = hi
		var band := lo + (hi - lo) * FOOTSTEP_BAND
		var inside: bool = _foot_low.get(side, false)
		if y <= band and not inside:
			_foot_low[side] = true
			event_fired.emit("footstep:stone")
		elif y > band:
			_foot_low[side] = false

## The body this graph poses (a sibling of the model inside Visuals).
func owner_body() -> Node:
	var node := get_parent()
	while node != null and not (node is CharacterBody3D):
		node = node.get_parent()
	return node

## ---------------------------------------------------------------- queries

## Names of every clip this graph can reach, for tooling and tests.
func clip_names() -> Array:
	if anim_player == null:
		return []
	var out: Array = []
	for lib in anim_player.get_animation_library_list():
		out.append_array(anim_player.get_animation_library(lib).get_animation_list())
	return out
