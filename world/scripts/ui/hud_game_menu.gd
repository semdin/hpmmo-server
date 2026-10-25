extends HudWindow
class_name HudGameMenu

## The Esc menu: what a player reaches when nothing else is open. Resume,
## Settings, World map, Change character (saves, leaves the world and returns to
## the character screen) and Quit (saves and closes the game).
##
## Leaving an online world is not instant: a short countdown (3 s, 5 s after
## recent combat) that any damage taken cancels, the usual MMORPG rule that
## keeps "log out to escape a fight" from working. Closing the menu cancels it
## too. The save itself does not depend on the countdown - the server writes
## the character when the session ends.

signal settings_requested
signal map_requested

const LEAVE_SECONDS := 3
const LEAVE_SECONDS_COMBAT := 5
## Damage dealt or taken this recently counts as "in combat".
const COMBAT_WINDOW_MS := 10000
const NOTE_IDLE := "Progress is saved when you leave."  # i18n

var _buttons: Dictionary = {}
var _note: Label
var _last_combat_ms := -COMBAT_WINDOW_MS
## Countdown state: "" when idle, else "character" or "quit".
var _leaving := ""
var _leave_at_ms := 0

func _init() -> void:
	super._init("Menu", Vector2(280, 350))
	name = "GameMenu"
	# A small card over the live game: no dimming, and the character can keep
	# moving while it is open.
	modal = false

func _ready() -> void:
	super._ready()
	body.add_theme_constant_override("separation", 7)
	body.alignment = BoxContainer.ALIGNMENT_CENTER
	# i18n-begin
	for spec in [
		["resume", "Resume"],
		["settings", "Settings"],
		["map", "World Map  (M)"],
		["character", "Change Character"],
		["quit", "Quit Game"],
	]:
	# i18n-end
		var b := HudKit.button(tr(String(spec[1])), 15)
		b.custom_minimum_size = Vector2(0, 34)
		b.pressed.connect(_on_pressed.bind(String(spec[0])))
		body.add_child(b)
		_buttons[String(spec[0])] = b
	_note = HudKit.label(tr(NOTE_IDLE), 12, HudKit.TEXT_DIM, HudKit.body(), 0)
	_note.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	# The countdown line ("Changing character in 5... (taking damage cancels)")
	# is wider than the card: unwrapped it pushed the buttons out of the frame.
	_note.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_note.custom_minimum_size = Vector2(1.0, 34.0)
	body.add_child(_note)
	SimAuthority.entity_damaged.connect(_on_entity_damaged)
	SimAuthority.entity_died.connect(_on_entity_died)
	closed.connect(func(): _cancel_leave(""))

func _on_pressed(id: String) -> void:
	match id:
		"resume":
			if _leaving != "":
				_cancel_leave("")
			close()
		"settings":
			close()
			settings_requested.emit()
		"map":
			close()
			map_requested.emit()
		"character", "quit":
			_begin_leave(id)

## Back to the character screen (the settings' language switch), through the
## same countdown the menu button uses.
func leave_to_characters() -> void:
	open()
	_begin_leave("character")

## Start the countdown (or leave at once offline, where nothing can hit you
## while the menu is open and the save is local).
func _begin_leave(kind: String) -> void:
	if _leaving != "":
		return
	if SimAuthority.role == SimAuthority.Role.OFFLINE:
		_leave_world(kind == "quit")
		return
	var player := SimAuthority.local_player_node()
	if player != null and bool(player.get("is_dead")):
		_note.text = tr("You cannot leave while defeated.")
		return
	var in_combat := Time.get_ticks_msec() - _last_combat_ms < COMBAT_WINDOW_MS
	var seconds := LEAVE_SECONDS_COMBAT if in_combat else LEAVE_SECONDS
	_leaving = kind
	_leave_at_ms = Time.get_ticks_msec() + seconds * 1000
	for id in _buttons:
		(_buttons[id] as Button).disabled = id != "resume"
	(_buttons["resume"] as Button).text = tr("Cancel")
	_refresh_countdown()

func _cancel_leave(reason: String) -> void:
	if _leaving == "":
		return
	_leaving = ""
	for b in _buttons.values():
		(b as Button).disabled = false
	(_buttons["resume"] as Button).text = tr("Resume")
	_note.text = reason if reason != "" else tr(NOTE_IDLE)

func _refresh_countdown() -> void:
	var left := maxi(0, int(ceil(float(_leave_at_ms - Time.get_ticks_msec()) / 1000.0)))
	var what := tr("Quitting") if _leaving == "quit" else tr("Changing character")
	_note.text = tr("%s in %d…  (taking damage cancels)") % [what, left]

func _process(_delta: float) -> void:
	if _leaving == "":
		return
	if Time.get_ticks_msec() >= _leave_at_ms:
		var quit := _leaving == "quit"
		_leaving = ""
		_leave_world(quit)
		return
	_refresh_countdown()

func _on_entity_damaged(uid: int, amount: int, _hp: int, _spell_id: String, attacker_uid: int) -> void:
	var me := SimAuthority.local_uid
	if me == 0 or amount <= 0:
		return
	if uid == me:
		_last_combat_ms = Time.get_ticks_msec()
		_cancel_leave(tr("Interrupted: you took damage."))
	elif attacker_uid == me:
		_last_combat_ms = Time.get_ticks_msec()

func _on_entity_died(uid: int, _killer_uid: int) -> void:
	if uid == SimAuthority.local_uid:
		_cancel_leave(tr("Interrupted: you were defeated."))

## Save, leave the session and either quit or return to the character screen.
## The server saves a character when its session ends; offline play writes the
## local save first.
func _leave_world(quit: bool) -> void:
	for b in _buttons.values():
		(b as Button).disabled = true
	_note.text = tr("Saving…")
	var world := get_tree().current_scene
	if world != null and world.has_method("_save_offline_state"):
		world.call("_save_offline_state")
	await get_tree().create_timer(0.25).timeout
	UIFocus.unblock(self)
	var offline: bool = SimAuthority.role == SimAuthority.Role.OFFLINE
	NetworkManager.disconnect_game()
	NetworkManager.forget_selected_character()
	if quit:
		get_tree().quit()
		return
	if offline and ResourceLoader.exists("res://scenes/main/character_select.tscn"):
		get_tree().change_scene_to_file("res://scenes/main/character_select.tscn")
	else:
		# An online session is bound to one character, so another one needs a
		# fresh world session - but not a new login: the front end rejoins with
		# the same account session and opens the character screen.
		get_tree().root.set_meta("hpmmo_rejoin_characters", true)
		get_tree().change_scene_to_file("res://scenes/main/main_menu.tscn")
