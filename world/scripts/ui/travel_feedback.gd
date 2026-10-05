extends Control
class_name TravelFeedback

## Phase 13 location and transition UI (plan.md Phase 13, task 3): indoor
## floor/area labels, portal/loading progress, moving-staircase warnings,
## mounted controls and invalid-landing feedback.
##
## Sources, none of them invented here:
##   * the floor name comes from `map_controller.floor_display()` - the same
##     authored floor table the walkthrough uses;
##   * the outdoor area name comes from `HPRules.zone_id_for()`, the authored
##     spawn region;
##   * the transfer bar follows `map_controller.busy` (the transfer is a real
##     load/unload cycle, not a fake timer);
##   * the staircase state is the `HPStaircase` state machine's own
##     `state_label()` / `entry_allowed()` / `is_riding()`;
##   * the landing verdict is the player controller's own authoritative gate
##     (`dismount_block_reason()`), the same rule the authority validates.

const LOCATION_POLL := 0.25
const MOUNTED_POLL := 0.25

var player: Node3D = null
var world: Node3D = null

var _location_label: Label = null
var _portal_panel: Panel = null
var _portal_label: Label = null
var _portal_bar: ProgressBar = null
var _stairs_panel: Panel = null
var _stairs_label: Label = null
var _mounted_panel: Panel = null
var _mounted_label: Label = null

var _location_timer := 0.0
var _mounted_timer := 0.0
var _portal_busy_seen := false
var _portal_progress := 0.0
var _portal_hide_at := 0.0
var _stairs_node: Node = null
var _stairs_seen_state := ""
var last_landing_reason := ""
var last_floor_text := ""
var last_stairs_text := ""
var last_mounted_text := ""

## Evidence counters.
var floor_updates: int = 0
var stairs_warnings_shown: int = 0
var invalid_landing_warnings: int = 0
var portals_seen: int = 0

func setup(p_player: Node3D, p_world: Node3D) -> void:
	player = p_player
	world = p_world
	if _location_label != null:
		# Already built (a rebind): only the references change.
		_stairs_node = null
		_consolidate_location_labels()
		return
	set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	_build()
	_consolidate_location_labels()

## Phase 13 presentation consolidation: the Phase 8 map controller already owns
## a top-centre location label with the same text this panel shows (plus the
## landing-pad hint and the outdoor region). Two overlapping copies of the same
## line is not "continuously understandable", so the controller's label keeps its
## text (the walkthrough reads it) but is hidden while this panel is present.
func _consolidate_location_labels() -> void:
	if world == null or not is_instance_valid(world):
		return
	var legacy := world.get_node_or_null("MapStatusUI/Location")
	if legacy is CanvasItem:
		(legacy as CanvasItem).visible = false

func _build() -> void:
	# Location / floor line, top centre under the zone banner.
	_location_label = _make_label("", 15, Color(1.0, 0.9, 0.62))
	_location_label.set_anchors_preset(Control.PRESET_CENTER_TOP)
	UILayout.place_centred(_location_label, Vector2(480, 22), Vector2(0, 84))
	_location_label.custom_minimum_size = Vector2(480, 22)
	_location_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	add_child(_location_label)

	# Portal / loading progress.
	_portal_panel = Panel.new()
	_portal_panel.name = "PortalProgress"
	_portal_panel.set_anchors_preset(Control.PRESET_CENTER)
	UILayout.place_centred(_portal_panel, Vector2(340, 56), Vector2(0, -70))
	_portal_panel.custom_minimum_size = Vector2(340, 56)
	_portal_panel.mouse_filter = Control.MOUSE_FILTER_IGNORE
	var style := StyleBoxFlat.new()
	style.bg_color = Color(0.03, 0.04, 0.07, 0.9)
	style.border_color = Color(0.9, 0.78, 0.3, 0.9)
	style.set_border_width_all(1)
	style.set_corner_radius_all(8)
	_portal_panel.add_theme_stylebox_override("panel", style)
	_portal_label = _make_label("Loading...", 15, Color(0.95, 0.9, 0.75))
	_portal_label.position = Vector2(10, 6)
	_portal_panel.add_child(_portal_label)
	_portal_bar = ProgressBar.new()
	_portal_bar.name = "PortalBar"
	_portal_bar.set_anchors_preset(Control.PRESET_BOTTOM_WIDE)
	_portal_bar.offset_left = 10
	_portal_bar.offset_right = -10
	_portal_bar.offset_top = -22
	_portal_bar.offset_bottom = -10
	_portal_bar.show_percentage = false
	_portal_bar.mouse_filter = Control.MOUSE_FILTER_IGNORE
	var fill := StyleBoxFlat.new()
	fill.bg_color = Color(0.9, 0.78, 0.3)
	_portal_bar.add_theme_stylebox_override("fill", fill)
	_portal_panel.add_child(_portal_bar)
	_portal_panel.hide()
	add_child(_portal_panel)

	# Staircase warning.
	_stairs_panel = Panel.new()
	_stairs_panel.name = "StaircaseWarning"
	_stairs_panel.set_anchors_preset(Control.PRESET_CENTER_TOP)
	UILayout.place_centred(_stairs_panel, Vector2(480, 30), Vector2(0, 120))
	_stairs_panel.custom_minimum_size = Vector2(480, 30)
	_stairs_panel.mouse_filter = Control.MOUSE_FILTER_IGNORE
	var stair_style := StyleBoxFlat.new()
	stair_style.bg_color = Color(0.16, 0.08, 0.03, 0.82)
	stair_style.border_color = Color(1.0, 0.55, 0.35, 0.9)
	stair_style.set_border_width_all(1)
	stair_style.set_corner_radius_all(6)
	_stairs_panel.add_theme_stylebox_override("panel", stair_style)
	_stairs_label = _make_label("", 14, Color(1.0, 0.7, 0.45))
	_stairs_label.position = Vector2(10, 5)
	_stairs_panel.add_child(_stairs_label)
	_stairs_panel.hide()
	add_child(_stairs_panel)

	# Mounted controls + landing verdict.
	_mounted_panel = Panel.new()
	_mounted_panel.name = "MountedControls"
	_mounted_panel.set_anchors_preset(Control.PRESET_TOP_LEFT)
	UILayout.place(_mounted_panel, Vector2(16, 70), Vector2(275, 78))
	_mounted_panel.custom_minimum_size = Vector2(275, 78)
	_mounted_panel.mouse_filter = Control.MOUSE_FILTER_IGNORE
	var mount_style := StyleBoxFlat.new()
	mount_style.bg_color = Color(0.04, 0.06, 0.1, 0.82)
	mount_style.border_color = Color(0.3, 0.9, 1.0, 0.8)
	mount_style.set_border_width_all(1)
	mount_style.set_corner_radius_all(6)
	_mounted_panel.add_theme_stylebox_override("panel", mount_style)
	_mounted_label = _make_label("", 12, Color(0.8, 0.95, 1.0))
	_mounted_label.position = Vector2(8, 6)
	_mounted_label.custom_minimum_size = Vector2(258, 66)
	_mounted_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_mounted_panel.add_child(_mounted_label)
	_mounted_panel.hide()
	add_child(_mounted_panel)

func _make_label(text: String, size: int, color: Color) -> Label:
	var label := Label.new()
	label.text = text
	label.mouse_filter = Control.MOUSE_FILTER_IGNORE
	label.add_theme_font_size_override("font_size", size)
	label.add_theme_color_override("font_color", color)
	label.add_theme_color_override("font_outline_color", Color(0, 0, 0, 1))
	label.add_theme_constant_override("outline_size", 5)
	return label

## ------------------------------------------------------------ location

func location_text() -> String:
	if player == null or not is_instance_valid(player):
		return ""
	var controller := _map_controller()
	var map_id := "grounds"
	var y: float = player.global_position.y
	if controller != null:
		map_id = String(controller.get("current_map"))
		if controller.has_method("floor_display"):
			var floor_text := String(controller.call("floor_display", map_id, y))
			if map_id == "castle_interior":
				return floor_text
	if map_id == "castle_interior":
		return "Hogwarts Castle"
	var region := HPRules.zone_id_for_map(map_id, player.global_position)
	if region == "":
		return "Hogwarts Grounds"
	return "Hogwarts Grounds - %s" % region

func _update_location() -> void:
	var text := location_text()
	if text != last_floor_text:
		last_floor_text = text
		floor_updates += 1
	_location_label.text = text

## ------------------------------------------------------------ portal progress

## The transfer's own busy flag drives the bar: it appears when the load begins
## and disappears when the commit lands. Progress ramps while busy and snaps to
## full when the transfer ends, so the bar always reflects a real phase.
func _update_portal(delta: float) -> void:
	var controller := _map_controller()
	var busy := controller != null and bool(controller.get("busy"))
	if busy:
		if not _portal_busy_seen:
			_portal_busy_seen = true
			_portal_progress = 0.0
			_portal_hide_at = 0.0
			portals_seen += 1
			var target := String(controller.get("current_map"))
			_portal_label.text = "Travelling..." if target == "" else "Loading %s..." % target
			_portal_panel.show()
			_play_ui("map_transition")
		_portal_progress = minf(0.92, _portal_progress + delta * 0.7)
	elif _portal_busy_seen:
		_portal_busy_seen = false
		_portal_progress = 1.0
		_portal_bar.value = 100.0
		_portal_label.text = "Arrived."
		_portal_hide_at = _now() + 0.4
	elif _portal_hide_at > 0.0 and _now() >= _portal_hide_at:
		_portal_hide_at = 0.0
		_portal_panel.hide()
	if _portal_panel.visible:
		_portal_bar.value = _portal_progress * 100.0

func _now() -> float:
	return float(Time.get_ticks_msec()) / 1000.0

## ------------------------------------------------------------ staircase

## The moving staircase has no signal; its `HPStaircase` state machine is the
## authoritative answer and is polled here (the same state the server
## replicates). `state != docked` is exactly the window entry is refused.
func _find_staircase() -> Node:
	if _stairs_node != null and is_instance_valid(_stairs_node):
		return _stairs_node
	if world == null or not is_instance_valid(world):
		return null
	var slot := world.get_node_or_null("CastleInterior/StaircaseSlot")
	if slot == null:
		return null
	for child in slot.get_children():
		if child.has_method("state_label") and child.has_method("entry_allowed"):
			_stairs_node = child
			return child
	return null

func staircase_text() -> String:
	var stairs := _find_staircase()
	if stairs == null:
		return ""
	var state := String(stairs.get("state"))
	var state_text := String(stairs.call("state_label"))
	var destination := ""
	if stairs.has_method("dock_count") and int(stairs.call("dock_count")) > 0:
		var to_index := int(stairs.get("to_index"))
		if state == "docked":
			to_index = int(stairs.get("dock_index"))
		destination = String(stairs.call("dock_id", to_index))
	var riding := false
	if player != null and is_instance_valid(player) and stairs.has_method("is_riding"):
		riding = bool(stairs.call("is_riding", _player_uid()))
	var suffix := ""
	if riding:
		suffix = "  [RIDING]"
	if destination != "":
		suffix += "  -> %s" % destination
	if state != _stairs_seen_state:
		_stairs_seen_state = state
		stairs_warnings_shown += 1
	return "Magical staircase: %s%s" % [state_text, suffix]

func _update_staircase() -> void:
	var stairs := _find_staircase()
	if stairs == null:
		_stairs_panel.hide()
		last_stairs_text = ""
		return
	var text := staircase_text()
	last_stairs_text = text
	var state := String(stairs.get("state"))
	var riding := player != null and is_instance_valid(player) and stairs.has_method("is_riding") and bool(stairs.call("is_riding", _player_uid()))
	if state == "docked" and not riding:
		_stairs_panel.hide()
		return
	if state != "docked":
		var entry_open := bool(stairs.call("entry_allowed"))
		if entry_open:
			_stairs_label.text = "%s  (boarding closes in a moment)" % text
		else:
			_stairs_label.text = "%s  (entry closed - hold position)" % text
	else:
		_stairs_label.text = text
	_stairs_panel.show()

## ------------------------------------------------------------ mounted controls

func mounted_text() -> String:
	if player == null or not is_instance_valid(player) or not bool(player.get("is_mounted")):
		return ""
	var altitude: float = player.global_position.y
	var speed := 0.0
	if "velocity" in player:
		var velocity: Vector3 = player.get("velocity")
		speed = Vector2(velocity.x, velocity.z).length()
	var landing := ""
	var reason := ""
	if player.has_method("dismount_block_reason"):
		reason = String(player.call("dismount_block_reason"))
	if reason == "":
		landing = "Landing here: OK (Shift to dismount)"
	else:
		landing = "Cannot land here: %s" % reason
	last_landing_reason = reason
	return "Nimbus - Space rise / Ctrl descend / Shift dismount\nAltitude %.1f m - speed %.1f m/s\n%s" % [altitude, speed, landing]

func _update_mounted() -> void:
	if player == null or not is_instance_valid(player) or not bool(player.get("is_mounted")):
		if _mounted_panel.visible:
			_mounted_panel.hide()
		last_mounted_text = ""
		return
	var text := mounted_text()
	if text.find("Cannot land here") >= 0 and last_mounted_text.find("Cannot land here") < 0:
		invalid_landing_warnings += 1
		_play_ui("ui_deny")
	last_mounted_text = text
	_mounted_label.text = text
	_mounted_panel.show()

## ------------------------------------------------------------ helpers

func _map_controller() -> Node:
	if world == null or not is_instance_valid(world):
		return null
	return world.get_node_or_null("MapController")

func _player_uid() -> int:
	if player != null and is_instance_valid(player):
		return int(player.get_meta("sim_uid", 0))
	return int(SimNet.local_uid)

func _play_ui(key: String) -> void:
	var audio := get_node_or_null("/root/AudioManager")
	if audio != null and audio.has_method("play_sound_at"):
		audio.call("play_sound_at", key, Vector3.ZERO, null, true)

func _process(delta: float) -> void:
	_location_timer -= delta
	if _location_timer <= 0.0:
		_location_timer = LOCATION_POLL
		_update_location()
		_update_staircase()
	_mounted_timer -= delta
	if _mounted_timer <= 0.0:
		_mounted_timer = MOUNTED_POLL
		_update_mounted()
	_update_portal(delta)

func describe() -> Dictionary:
	return {
		"location": last_floor_text,
		"floor_updates": floor_updates,
		"stairs": last_stairs_text,
		"stairs_warnings": stairs_warnings_shown,
		"mounted": last_mounted_text,
		"landing_reason": last_landing_reason,
		"invalid_landings": invalid_landing_warnings,
		"portals_seen": portals_seen,
	}
