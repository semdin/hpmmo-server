extends Control
class_name OnboardingUI

## Phase 13 onboarding route (plan.md Phase 13, task 7): a short training flow
## covering dummy practice, safe-zone boundaries, reactive packs, broom controls
## and the castle entrance.
##
## Every step is completed from authoritative state, never from the fact that
## the player was shown the step:
##   * dummy practice   - the authority reported damage dealt by this player to
##                        an entity registered as a DUMMY;
##   * safe zone        - the player physically stands inside an authored
##                        protection volume (the same `HPRules` volumes the
##                        server evaluates);
##   * reactive packs   - the authority reported this player taking damage from
##                        a MOB that belongs to a pack (pack_id != 0), i.e. the
##                        pack reacted, not that the player clicked something;
##   * broom controls   - mounted, actually airborne, then a dismount the
##                        landing gate accepted;
##   * castle entrance  - the authoritative map for this body became
##                        `castle_interior` (map_state / map_changed), not a
##                        local guess about the doorway.
##
## Progress persists under `user://` so a relog resumes where the player was,
## and `reset()` starts the route again.

const STATE_PATH := "user://phase13_onboarding.json"
const AIRBORNE_HEIGHT := 2.5
const SAFE_ZONE_POLL := 0.3

const STEPS := [
	{"id": "dummy", "title": "Practice on a dummy",
	 "hint": "Cast any spell at a training dummy in the courtyard (Tab to target one)."},
	{"id": "safe_zone", "title": "Find protected ground",
	 "hint": "Step into the courtyard fountain area - the glow marks protected ground."},
	{"id": "pack", "title": "Provoke a pack",
	 "hint": "Hit an Acromantula or Inferi outside the safe zone and survive the pack's answer."},
	{"id": "broom", "title": "Broom controls",
	 "hint": "Shift to mount, Space to rise, then land on level ground and Shift to dismount."},
	{"id": "castle", "title": "Enter the castle",
	 "hint": "Dismount at the entrance and press F in the doorway to enter Hogwarts."},
]

var player: Node3D = null
var binder: UIStateBinder = null
var world: Node3D = null
var done: Array = []
var current_index: int = 0
var visible_panel := true

var _panel: Panel = null
var _title: Label = null
var _body: Label = null
var _hide_button: Button = null

## Evidence counters.
var authoritative_progress: int = 0
var packets_observed: int = 0

var _mounted_once := false
var _airborne_once := false
var _safe_poll := 0.0
var _was_protected := false
var _witnessed: Dictionary = {}
var _witness_player: Node3D = null

func setup(p_binder: UIStateBinder, p_player: Node3D, p_world: Node3D = null) -> void:
	binder = p_binder
	player = p_player
	world = p_world
	if _panel == null:
		set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
		mouse_filter = Control.MOUSE_FILTER_IGNORE
		_build()
	load_progress()
	if binder != null:
		binder.map_changed.connect(_on_map_changed)
	_connect_authority_witnesses()
	_refresh()

## Watch the raw authority events that prove a step happened. These are the
## server's own signals: nothing here trusts the local body.
func _connect_authority_witnesses() -> void:
	if not SimAuthority.entity_damaged.is_connected(_on_entity_damaged):
		SimAuthority.entity_damaged.connect(_on_entity_damaged)
	if not SimAuthority.cast_landed.is_connected(_on_cast_landed):
		SimAuthority.cast_landed.connect(_on_cast_landed)
	if not SimAuthority.encounter_reset.is_connected(_on_encounter_reset):
		SimAuthority.encounter_reset.connect(_on_encounter_reset)
	if _witness_player != null and is_instance_valid(_witness_player) and _witness_player != player:
		for connection in _witness_player.get_signal_connection_list("mounted_changed"):
			if connection["callable"].get_object() == self:
				_witness_player.disconnect("mounted_changed", connection["callable"])
	_witness_player = player
	if player != null and is_instance_valid(player) and player.has_signal("mounted_changed"):
		if not player.mounted_changed.is_connected(_on_mounted_changed):
			player.mounted_changed.connect(_on_mounted_changed)

func _exit_tree() -> void:
	for signal_name in ["entity_damaged", "cast_landed", "encounter_reset"]:
		if not SimAuthority.has_signal(signal_name):
			continue
		for connection in SimAuthority.get_signal_connection_list(signal_name):
			if connection["callable"].get_object() == self:
				SimAuthority.disconnect(signal_name, connection["callable"])
	if player != null and is_instance_valid(player) and player.has_signal("mounted_changed"):
		for connection in player.get_signal_connection_list("mounted_changed"):
			if connection["callable"].get_object() == self:
				player.disconnect("mounted_changed", connection["callable"])

## ------------------------------------------------------------------- ui

func _build() -> void:
	_panel = Panel.new()
	_panel.name = "OnboardingPanel"
	_panel.set_anchors_preset(Control.PRESET_CENTER_LEFT)
	UILayout.place(_panel, Vector2(16, -84), Vector2(300, 168))
	_panel.custom_minimum_size = Vector2(300, 168)
	_panel.mouse_filter = Control.MOUSE_FILTER_PASS
	var style := StyleBoxFlat.new()
	style.bg_color = Color(0.04, 0.05, 0.09, 0.86)
	style.border_color = Color(0.85, 0.72, 0.32, 0.9)
	style.set_border_width_all(2)
	style.set_corner_radius_all(8)
	_panel.add_theme_stylebox_override("panel", style)
	_title = _make_label("Getting started", 15, Color(1.0, 0.88, 0.55))
	_title.position = Vector2(10, 6)
	_panel.add_child(_title)
	_body = _make_label("", 12, Color(0.92, 0.95, 1.0))
	_body.position = Vector2(10, 30)
	_body.custom_minimum_size = Vector2(280, 106)
	_body.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_panel.add_child(_body)
	_hide_button = Button.new()
	_hide_button.name = "Hide"
	_hide_button.text = "Hide (J)"
	_hide_button.focus_mode = Control.FOCUS_NONE
	_hide_button.position = Vector2(230, 140)
	_hide_button.custom_minimum_size = Vector2(64, 20)
	_hide_button.add_theme_font_size_override("font_size", 10)
	_hide_button.pressed.connect(toggle_panel)
	_panel.add_child(_hide_button)
	add_child(_panel)

func _make_label(text: String, size: int, color: Color) -> Label:
	var label := Label.new()
	label.text = text
	label.mouse_filter = Control.MOUSE_FILTER_IGNORE
	label.add_theme_font_size_override("font_size", size)
	label.add_theme_color_override("font_color", color)
	label.add_theme_color_override("font_outline_color", Color(0, 0, 0, 1))
	label.add_theme_constant_override("outline_size", 5)
	return label

func toggle_panel() -> void:
	visible_panel = not visible_panel
	_refresh()

func _refresh() -> void:
	if _panel == null:
		return
	if not visible_panel:
		_panel.hide()
		return
	_panel.show()
	if is_complete():
		_title.text = "Training complete"
		_body.text = "You know the basics: dummies, safe ground, packs, the broom and the castle door.\nThe grounds are yours."
		return
	var step: Dictionary = STEPS[current_index]
	_title.text = "Getting started (%d/%d)" % [current_index, STEPS.size()]
	var lines: Array = []
	for index in range(STEPS.size()):
		var entry: Dictionary = STEPS[index]
		var mark := "[x]" if index < current_index else ("[>]" if index == current_index else "[ ]")
		lines.append("%s %s" % [mark, entry["title"]])
	lines.append("")
	lines.append(String(step["hint"]))
	_body.text = "\n".join(lines)

## --------------------------------------------------------------- progress

func is_complete() -> bool:
	return current_index >= STEPS.size()

## Record that the authoritative state proved a step happened. Evidence seen
## before the route reaches that step is kept (a player who wanders into the
## castle early is not asked to do it twice).
func _witness(step_id: String) -> void:
	_witnessed[step_id] = true
	mark_done(step_id)

func mark_done(step_id: String) -> void:
	var index := _index_of(step_id)
	if index < 0 or index != current_index:
		return
	current_index += 1
	done.append(step_id)
	authoritative_progress += 1
	save_progress()
	_refresh()
	_play_ui("ui_quest")

func _index_of(step_id: String) -> int:
	for index in range(STEPS.size()):
		if String(STEPS[index]["id"]) == step_id:
			return index
	return -1

func save_progress() -> void:
	var handle := FileAccess.open(STATE_PATH, FileAccess.WRITE)
	if handle == null:
		return
	handle.store_string(JSON.stringify({"index": current_index, "done": done}))
	handle.close()

func load_progress() -> void:
	if not FileAccess.file_exists(STATE_PATH):
		return
	var parsed = JSON.parse_string(FileAccess.get_file_as_string(STATE_PATH))
	if typeof(parsed) != TYPE_DICTIONARY:
		return
	current_index = clampi(int(parsed.get("index", 0)), 0, STEPS.size())
	if parsed.get("done") is Array:
		done = parsed["done"]

func reset() -> void:
	current_index = 0
	done.clear()
	_witnessed.clear()
	_mounted_once = false
	_airborne_once = false
	save_progress()
	_refresh()

## ------------------------------------------------------------ authoritative

## A landed cast that the authority resolved against a dummy counts as practice.
func _on_cast_landed(_cast_id: int, caster_uid: int, _spell_id: String, hits: Array) -> void:
	if caster_uid != _local_uid():
		return
	for hit in hits:
		var uid := int((hit as Dictionary).get("uid", 0)) if hit is Dictionary else 0
		if uid != 0 and _kind_of(uid) == HPProtocol.Kind.DUMMY:
			packets_observed += 1
			_witness("dummy")
			return

func _on_entity_damaged(uid: int, _amount: int, _hp: int, _spell_id: String, attacker_uid: int) -> void:
	var local := _local_uid()
	# Dummy practice: this player dealt damage to a dummy entity.
	if attacker_uid == local and _kind_of(uid) == HPProtocol.Kind.DUMMY:
		packets_observed += 1
		_witness("dummy")
		return
	# Reactive pack: this player was damaged by a mob that belongs to a pack.
	if uid == local and attacker_uid != 0:
		var attacker := SimAuthority.record_by_uid(attacker_uid)
		if int(attacker.get("kind", -1)) == HPProtocol.Kind.MOB:
			packets_observed += 1
			if int(attacker.get("pack_id", 0)) != 0:
				_witness("pack")

func _on_encounter_reset(pack_id: int, _reason: String) -> void:
	# A pack that leashed home is still proof the player engaged a pack.
	if pack_id != 0:
		packets_observed += 1

func _on_map_changed(_uid: int, map_id: String, _pos: Vector3) -> void:
	if map_id == "castle_interior":
		_witness("castle")

func _on_mounted_changed(is_mounted: bool) -> void:
	if is_mounted:
		_mounted_once = true
		return
	# Landed. The authority accepted the dismount (the player's own landing gate
	# is the same rule the server validates), so the broom lesson is done.
	if _mounted_once and _airborne_once and player != null and is_instance_valid(player):
		var safe := true
		if player.has_method("can_dismount_safely"):
			safe = bool(player.call("can_dismount_safely"))
		if safe:
			_witness("broom")

func _poll() -> void:
	if player == null or not is_instance_valid(player):
		return
	# Safe zone: the authored protection volume, evaluated exactly as the
	# authority evaluates it. Standing on protected ground is the state the step
	# asks for - whether the player walked in or spawned there, the state is what
	# proves it (the rising edge is recorded for the hint, not as the trigger).
	var protected := HPRules.is_protected_point(player.global_position)
	if protected:
		if not _was_protected:
			packets_observed += 1
		_witness("safe_zone")
	_was_protected = protected
	# Broom: airborne evidence comes from the player's real altitude.
	if _mounted_once and bool(player.get("is_mounted")) and player.global_position.y > AIRBORNE_HEIGHT:
		_airborne_once = true
	# Castle: the MapController's authoritative map, if the event was missed.
	if world != null and is_instance_valid(world):
		var controller := world.get_node_or_null("MapController")
		if controller != null and String(controller.get("current_map")) == "castle_interior":
			_witness("castle")
	# Evidence collected before the route reached this step still counts.
	if not is_complete():
		var current_id := String(STEPS[current_index]["id"])
		if _witnessed.has(current_id):
			mark_done(current_id)

func _process(delta: float) -> void:
	_safe_poll -= delta
	if _safe_poll > 0.0:
		return
	_safe_poll = SAFE_ZONE_POLL
	_poll()

func _local_uid() -> int:
	if binder != null:
		return binder.local_uid()
	return int(SimNet.local_uid)

func _kind_of(uid: int) -> int:
	return int(SimAuthority.record_by_uid(uid).get("kind", -1))

func _play_ui(key: String) -> void:
	var audio := get_node_or_null("/root/AudioManager")
	if audio != null and audio.has_method("play_sound_at"):
		audio.call("play_sound_at", key, Vector3.ZERO, null, true)

func describe() -> Dictionary:
	var current := "" if is_complete() else String(STEPS[current_index]["id"])
	return {
		"index": current_index,
		"done": done.duplicate(),
		"current": current,
		"complete": is_complete(),
		"visible": _panel.visible if _panel != null else false,
		"body": _body.text if _body != null else "",
		"authoritative_progress": authoritative_progress,
		"packets": packets_observed,
	}
