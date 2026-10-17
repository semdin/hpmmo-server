extends HudWindow
class_name HudGameMenu

## The Esc menu: what a player reaches when nothing else is open. Resume,
## Settings, World map, Change character (saves, leaves the world and returns to
## the character screen) and Quit (saves and closes the game).

signal settings_requested
signal map_requested

var _buttons: Dictionary = {}
var _note: Label

func _init() -> void:
	super._init("Menu", Vector2(260, 318))
	name = "GameMenu"
	# A small card over the live game: no dimming, and the character can keep
	# moving while it is open.
	modal = false

func _ready() -> void:
	super._ready()
	body.add_theme_constant_override("separation", 7)
	body.alignment = BoxContainer.ALIGNMENT_CENTER
	for spec in [
		["resume", "Resume"],
		["settings", "Settings"],
		["map", "World Map  (M)"],
		["character", "Change Character"],
		["quit", "Quit Game"],
	]:
		var b := HudKit.button(String(spec[1]), 15)
		b.custom_minimum_size = Vector2(0, 34)
		b.pressed.connect(_on_pressed.bind(String(spec[0])))
		body.add_child(b)
		_buttons[String(spec[0])] = b
	_note = HudKit.label("Progress is saved when you leave.", 12, HudKit.TEXT_DIM, HudKit.body(), 0)
	_note.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	body.add_child(_note)

func _on_pressed(id: String) -> void:
	match id:
		"resume":
			close()
		"settings":
			close()
			settings_requested.emit()
		"map":
			close()
			map_requested.emit()
		"character":
			_leave_world(false)
		"quit":
			_leave_world(true)

## Save, leave the session and either quit or return to the character screen.
## The server saves a character when its session ends; offline play writes the
## local save first.
func _leave_world(quit: bool) -> void:
	for b in _buttons.values():
		(b as Button).disabled = true
	_note.text = "Saving…"
	var world := get_tree().current_scene
	if world != null and world.has_method("_save_offline_state"):
		world.call("_save_offline_state")
	await get_tree().create_timer(0.25).timeout
	UIFocus.unblock(self)
	if quit:
		NetworkManager.disconnect_game()
		get_tree().quit()
		return
	var offline: bool = SimAuthority.role == SimAuthority.Role.OFFLINE
	NetworkManager.disconnect_game()
	if offline and ResourceLoader.exists("res://scenes/main/character_select.tscn"):
		get_tree().change_scene_to_file("res://scenes/main/character_select.tscn")
	else:
		# An online session is bound to one character, so another one needs a
		# fresh world session - but not a new login: the front end rejoins with
		# the same account session and opens the character screen.
		get_tree().root.set_meta("hpmmo_rejoin_characters", true)
		get_tree().change_scene_to_file("res://scenes/main/main_menu.tscn")
