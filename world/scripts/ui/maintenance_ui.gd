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
## Set once the transport dropped during a cycle: the player is sent back to the
## login screen (which then shows the maintenance notice) after a short pause.
var _return_at_ms := 0
const RETURN_TO_LOGIN_MS := 5000
const LOGIN_SCENE := "res://scenes/main/main_menu.tscn"

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
	UILayout.place_centred(_panel, Vector2(560, 64), Vector2(0, 150))
	_panel.custom_minimum_size = Vector2(560, 64)
	_panel.mouse_filter = Control.MOUSE_FILTER_IGNORE
	var style := StyleBoxFlat.new()
	style.bg_color = Color(0.18, 0.06, 0.02, 0.9)
	style.border_color = Color(1.0, 0.6, 0.2, 0.95)
	style.set_border_width_all(2)
	style.set_corner_radius_all(8)
	_panel.add_theme_stylebox_override("panel", style)
	_title = _make_label("Bakım", 19, Color(1.0, 0.75, 0.4))
	_title.position = Vector2(50, 6)
	_panel.add_child(_title)
	var lock := UITheme.icon_rect("ui_lock", 28.0)
	lock.name = "LockIcon"
	lock.position = Vector2(14, 14)
	_panel.add_child(lock)
	_detail = _make_label("", 13, Color(1.0, 0.92, 0.8))
	_detail.position = Vector2(50, 32)
	_detail.custom_minimum_size = Vector2(498, 20)
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
			_title.text = "Bakım iptal edildi"
			_detail.text = "Sunucu çevrimiçi kalmaya devam ediyor."
			_deadline_ms = Time.get_ticks_msec() + 4000
			active = true
		elif state == "ONLINE":
			_panel.hide()
		return
	var first_announcement := not active
	active = true
	_panel.show()
	_refresh_labels()
	if first_announcement and (state == "ANNOUNCING" or state == "DRAINING"):
		_post_chat_warning()

## The banner can be missed in a fight; the chat log keeps the warning.
func _post_chat_warning() -> void:
	var line := "Sunucu bakıma giriyor: %d saniye içinde herkes oyundan çıkarılacak. Güvenli bir yerde dur; ilerlemen kaydedilecek." % announced_seconds
	var hud := get_parent()
	var chat: Variant = hud.get("chat") if hud != null else null
	if chat is Object and (chat as Object).has_method("add_system_line"):
		(chat as Object).call("add_system_line", line)
	else:
		print("[Maintenance] " + line)

func _on_disconnected(disconnect_reason: String) -> void:
	if active and (TERMINAL_STATES.has(state) or state == "ANNOUNCING" or state == "DRAINING"):
		_title.text = "Bakım nedeniyle oyundan çıkarıldın"
		_detail.text = "İlerlemen kaydedildi. Giriş ekranına dönülüyor…"
		_panel.show()
		active = true
		state = "DISCONNECTED"
		if _return_at_ms == 0:
			_return_at_ms = Time.get_ticks_msec() + RETURN_TO_LOGIN_MS

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
			_title.text = "Sunucu bakımı: %s içinde oyundan çıkarılacaksın" % countdown_text()
			_detail.text = "Güvenli bir yerde dur ve işlemlerini bitir; ilerlemen otomatik kaydedilecek."
		"SAVING":
			_title.text = "Bakım - ilerleme kaydediliyor"
			_detail.text = "Karakterin kaydedilirken oyunu kapatma."
		"DISCONNECTING":
			_title.text = "Bakım - bağlantı kapatılıyor"
			_detail.text = "İlerlemen kaydedildi. Bakım bitince tekrar giriş yapabilirsin."
		"MAINTENANCE":
			_title.text = "Sunucu bakım için kapatıldı"
			_detail.text = "Bakım bitince tekrar giriş yapabilirsin."
		"DISCONNECTED":
			pass
		"FAILED":
			_title.text = "Bakım başarısız oldu"
			_detail.text = "Sunucu yeniden çevrimiçi oluyor. Birazdan tekrar bağlan."
		_:
			_title.text = "Bakım"
			_detail.text = reason

func _process(delta: float) -> void:
	if _panel == null:
		return
	if not active:
		if _panel.visible:
			_panel.hide()
		return
	if _return_at_ms > 0 and Time.get_ticks_msec() >= _return_at_ms:
		_return_at_ms = 0
		_return_to_login()
		return
	if _panel.visible:
		countdown_updates += 1
		_refresh_labels()
		if state == "ABORTED" and Time.get_ticks_msec() > _deadline_ms:
			active = false
			_panel.hide()

## Back to the login screen, which reads the notice and explains the closure.
func _return_to_login() -> void:
	if not is_inside_tree() or DisplayServer.get_name() == "headless":
		return
	var tree := get_tree()
	tree.root.set_meta("hpmmo_login_notice", "maintenance")
	var network := get_node_or_null("/root/NetworkManager")
	if network != null and network.has_method("disconnect_game"):
		network.call("disconnect_game")
	tree.change_scene_to_file(LOGIN_SCENE)

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
