extends Control
class_name MaintenanceUI

## Interface maintenance countdown ().
##
## The authority announces a maintenance cycle as
## `SimAuthority.maintenance_event(state, reason, seconds_remaining)` - until now
## nothing in the client listened, so a live player was disconnected with no
## explanation. This panel listens in every role and turns the announcement into
## a countdown the player can act on: time to find a safe spot and save.
##
## The countdown is shown from the deadline the authority published and ticks
## locally between announcements, then latches on the terminal states
## (SAVING / DISCONNECTING / MAINTENANCE) so the reason for the disconnect stays
## on screen even after the transport drops.

const TERMINAL_STATES := ["SAVING", "DISCONNECTING", "MAINTENANCE", "FAILED"]
const CLOSED_STATES := ["ONLINE", "ABORTED"]

var state := ""
var reason := ""
var announced_seconds := 0
var active := false

var _panel: Panel = null
var _title: Label = null
var _detail: Label = null
var _deadline_ms := 0

## Evidence counters.
var events_seen: int = 0
var countdown_updates: int = 0

func setup(binder: UIStateBinder) -> void:
	set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	_build()
	if binder != null:
		binder.maintenance_event.connect(_on_maintenance_event)
	# If the transport drops while a cycle is running, say why instead of
	# leaving the player on a silent black screen. Both the sim transport and
	# the client manager are watched: either can be the one that notices.
	if SimNet.has_signal("disconnected"):
		SimNet.connect("disconnected", _on_disconnected)
	var network := get_node_or_null("/root/NetworkManager")
	if network != null and network.has_signal("server_disconnected_signal"):
		network.connect("server_disconnected_signal", _on_server_disconnected)

func _build() -> void:
	_panel = Panel.new()
	_panel.name = "MaintenancePanel"
	_panel.set_anchors_preset(Control.PRESET_CENTER_TOP)
	UILayout.place_centred(_panel, Vector2(520, 58), Vector2(0, 160))
	_panel.custom_minimum_size = Vector2(520, 58)
	_panel.mouse_filter = Control.MOUSE_FILTER_IGNORE
	var style := StyleBoxFlat.new()
	style.bg_color = Color(0.18, 0.06, 0.02, 0.9)
	style.border_color = Color(1.0, 0.6, 0.2, 0.95)
	style.set_border_width_all(2)
	style.set_corner_radius_all(8)
	_panel.add_theme_stylebox_override("panel", style)
	_title = _make_label("Maintenance", 18, Color(1.0, 0.75, 0.4))
	_title.position = Vector2(12, 6)
	_panel.add_child(_title)
	_detail = _make_label("", 13, Color(1.0, 0.92, 0.8))
	_detail.position = Vector2(12, 32)
	_detail.custom_minimum_size = Vector2(496, 20)
	_panel.add_child(_detail)
	_panel.hide()
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

## ------------------------------------------------------------------ events

func _on_maintenance_event(p_state: String, p_reason: String, seconds_remaining: int) -> void:
	events_seen += 1
	state = p_state
	reason = p_reason
	announced_seconds = maxi(0, seconds_remaining)
	_deadline_ms = Time.get_ticks_msec() + announced_seconds * 1000
	if CLOSED_STATES.has(state):
		active = false
		if state == "ABORTED":
			_panel.show()
			_title.text = "Maintenance cancelled"
			_detail.text = "The world is back online."
			_deadline_ms = Time.get_ticks_msec() + 4000
			active = true
		elif state == "ONLINE":
			_panel.hide()
		return
	active = true
	_panel.show()
	_refresh_labels()

func _on_disconnected(disconnect_reason: String) -> void:
	if active and (TERMINAL_STATES.has(state) or state == "ANNOUNCING" or state == "DRAINING"):
		_title.text = "Disconnected for maintenance"
		_detail.text = "The world is closed for maintenance (%s). Your progress was saved." % (reason if reason != "" else disconnect_reason)
		_panel.show()
		active = true

func _on_server_disconnected() -> void:
	_on_disconnected("the server closed the connection")

## ------------------------------------------------------------------ countdown

## Seconds left until the announced deadline (0 once it has passed).
func countdown_seconds() -> int:
	if not active:
		return 0
	return maxi(0, int(ceil(float(_deadline_ms - Time.get_ticks_msec()) / 1000.0)))

func countdown_text() -> String:
	var seconds := countdown_seconds()
	return "%d:%02d" % [seconds / 60, seconds % 60]

func status_text() -> String:
	if not active:
		return ""
	return _detail.text if _detail != null else ""

func _refresh_labels() -> void:
	if _title == null:
		return
	match state:
		"ANNOUNCING", "DRAINING":
			_title.text = "Server maintenance in %s" % countdown_text()
			_detail.text = "Find a safe spot and save your progress. %s" % (reason if reason != "" else "The world will close shortly.")
		"SAVING":
			_title.text = "Maintenance - saving progress"
			_detail.text = "Do not close the game while your character is saved."
		"DISCONNECTING":
			_title.text = "Maintenance - disconnecting"
			_detail.text = "You are being disconnected for maintenance. Your progress was saved."
		"MAINTENANCE":
			_title.text = "World closed for maintenance"
			_detail.text = "The server is down for maintenance. Reconnect after it returns."
		"FAILED":
			_title.text = "Maintenance failed"
			_detail.text = "The world is coming back online. Reconnect in a moment."
		_:
			_title.text = "Maintenance"
			_detail.text = reason

func _process(delta: float) -> void:
	if _panel == null:
		return
	if not active:
		if _panel.visible:
			_panel.hide()
		return
	if _panel.visible:
		countdown_updates += 1
		_refresh_labels()
		if state == "ABORTED" and Time.get_ticks_msec() > _deadline_ms:
			active = false
			_panel.hide()

func describe() -> Dictionary:
	return {
		"state": state,
		"reason": reason,
		"active": active,
		"visible": _panel.visible if _panel != null else false,
		"countdown": countdown_seconds(),
		"countdown_text": countdown_text(),
		"title": _title.text if _title != null else "",
		"detail": _detail.text if _detail != null else "",
		"events_seen": events_seen,
	}
