extends RefCounted
class_name GameSettings

## Phase 13 player settings (plan.md Phase 13, "Provide scalable UI at common
## aspect ratios and resolutions, readable contrast, key rebinding, sensitivity
## settings, and independent shake/flash/volume controls").
##
## What lives here:
##   * the UI scale (applied to the Window's content scale factor, so the whole
##     canvas - HUD, panels, prompts - scales together at any resolution or
##     aspect ratio the stretch mode supports);
##   * the mouse-look sensitivity the player controller multiplies its raw
##     relative motion by;
##   * independent screen-shake and screen-flash intensity (1.0 = authored,
##     0.0 = off, up to 1.5 = stronger), consumed by `screen_fx.gd`;
##   * key rebinding for the gameplay actions, applied to the live InputMap and
##     persisted.
##
## Persistence is a ConfigFile under `user://` - user data, never inside the
## versioned game files (res://). The game reads it back on the next launch.
##
## The class is a lazily-created static singleton so any script (including the
## player controller, which only needs `mouse_sensitivity()`) can consult it
## without adding an autoload to project.godot.

const SETTINGS_PATH := "user://phase13_settings.cfg"
const SECTION_GENERAL := "phase13"
const SECTION_BINDINGS := "bindings"

const UI_SCALE_DEFAULT := 1.0
const UI_SCALE_MIN := 0.75
const UI_SCALE_MAX := 1.75
const SENSITIVITY_DEFAULT := 1.0
const SENSITIVITY_MIN := 0.25
const SENSITIVITY_MAX := 3.0
const SHAKE_DEFAULT := 1.0
const FLASH_DEFAULT := 1.0
const INTENSITY_MIN := 0.0
const INTENSITY_MAX := 1.5
const BUSES := ["Music", "SFX", "UI", "Ambience"]

## Actions the settings screen may rebind, with the key GameData registers by
## default. Only these are offered: the screen never invents an action, and a
## rebind always replaces the whole event list so an action can never end up
## bound to two keys by accident.
const BINDABLE_ACTIONS := {
	"move_forward": KEY_W,
	"move_backward": KEY_S,
	"move_left": KEY_A,
	"move_right": KEY_D,
	"jump": KEY_SPACE,
	"flight_descend": KEY_CTRL,
	"mount_broom": KEY_SHIFT,
	"target_cycle": KEY_TAB,
	"pickup_loot": KEY_Z,
	"interact": KEY_F,
	"toggle_inventory": KEY_I,
	"toggle_ollivander": KEY_O,
	"toggle_chat": KEY_ENTER,
	"spell_1": KEY_1,
	"spell_2": KEY_2,
	"spell_3": KEY_3,
	"spell_4": KEY_4,
	"spell_q": KEY_Q,
	"spell_e": KEY_E,
}

static var _instance: GameSettings = null

var ui_scale: float = UI_SCALE_DEFAULT
var mouse_sensitivity: float = SENSITIVITY_DEFAULT
var shake_intensity: float = SHAKE_DEFAULT
var flash_intensity: float = FLASH_DEFAULT
var bindings: Dictionary = {}
var load_error: String = ""

## ---------------------------------------------------------------- singleton

static func instance() -> GameSettings:
	if _instance == null:
		_instance = GameSettings.new()
		_instance.load_from_disk()
	return _instance

## Drop every cached value and read the file again. The persistence check uses
## this: what a fresh process (or a reload) sees must equal what was saved.
## (Not named `reload()`: that name belongs to the Script resource itself and
## would never reach this static function.)
static func reload_from_disk() -> GameSettings:
	_instance = null
	return instance()

## ---------------------------------------------------------------- accessors

static func mouse_sensitivity_value() -> float:
	return instance().mouse_sensitivity

static func ui_scale_value() -> float:
	return instance().ui_scale

static func shake_value() -> float:
	return instance().shake_intensity

static func flash_value() -> float:
	return instance().flash_intensity

## The path settings are persisted to. Always `user://` (user data) - the checks
## assert the file is outside the versioned project tree.
static func settings_path() -> String:
	return SETTINGS_PATH

static func settings_global_path() -> String:
	return ProjectSettings.globalize_path(SETTINGS_PATH)

## ------------------------------------------------------------------- load

func load_from_disk() -> void:
	ui_scale = UI_SCALE_DEFAULT
	mouse_sensitivity = SENSITIVITY_DEFAULT
	shake_intensity = SHAKE_DEFAULT
	flash_intensity = FLASH_DEFAULT
	bindings.clear()
	load_error = ""
	for action in BINDABLE_ACTIONS:
		bindings[action] = int(BINDABLE_ACTIONS[action])
	var config := ConfigFile.new()
	var error := config.load(SETTINGS_PATH)
	if error != OK:
		# No file yet is the normal first-launch state: keep the defaults.
		if error != ERR_FILE_NOT_FOUND:
			load_error = "could not read settings (error %d)" % error
		_apply_bindings_to_input_map()
		return
	ui_scale = clampf(float(config.get_value(SECTION_GENERAL, "ui_scale", UI_SCALE_DEFAULT)), UI_SCALE_MIN, UI_SCALE_MAX)
	mouse_sensitivity = clampf(float(config.get_value(SECTION_GENERAL, "mouse_sensitivity", SENSITIVITY_DEFAULT)), SENSITIVITY_MIN, SENSITIVITY_MAX)
	shake_intensity = clampf(float(config.get_value(SECTION_GENERAL, "shake", SHAKE_DEFAULT)), INTENSITY_MIN, INTENSITY_MAX)
	flash_intensity = clampf(float(config.get_value(SECTION_GENERAL, "flash", FLASH_DEFAULT)), INTENSITY_MIN, INTENSITY_MAX)
	for action in BINDABLE_ACTIONS:
		var stored := int(config.get_value(SECTION_BINDINGS, action, int(BINDABLE_ACTIONS[action])))
		if stored <= 0:
			stored = int(BINDABLE_ACTIONS[action])
		bindings[action] = stored
	_apply_bindings_to_input_map()

func save_to_disk() -> void:
	var config := ConfigFile.new()
	config.set_value(SECTION_GENERAL, "ui_scale", ui_scale)
	config.set_value(SECTION_GENERAL, "mouse_sensitivity", mouse_sensitivity)
	config.set_value(SECTION_GENERAL, "shake", shake_intensity)
	config.set_value(SECTION_GENERAL, "flash", flash_intensity)
	for action in bindings:
		config.set_value(SECTION_BINDINGS, action, int(bindings[action]))
	var error := config.save(SETTINGS_PATH)
	if error != OK:
		load_error = "could not write settings (error %d)" % error
		push_warning("[GameSettings] %s" % load_error)

## ---------------------------------------------------------------- setters

func set_ui_scale(value: float) -> void:
	ui_scale = clampf(value, UI_SCALE_MIN, UI_SCALE_MAX)
	apply_ui_scale()
	save_to_disk()

func set_mouse_sensitivity(value: float) -> void:
	mouse_sensitivity = clampf(value, SENSITIVITY_MIN, SENSITIVITY_MAX)
	save_to_disk()

func set_shake_intensity(value: float) -> void:
	shake_intensity = clampf(value, INTENSITY_MIN, INTENSITY_MAX)
	save_to_disk()

func set_flash_intensity(value: float) -> void:
	flash_intensity = clampf(value, INTENSITY_MIN, INTENSITY_MAX)
	save_to_disk()

## The four audio buses are owned by AudioManager (Phase 12), which already
## persists them to user://audio_settings.json. The settings screen drives that
## one API instead of keeping a second copy of the same numbers.
func set_volume(bus_name: String, linear: float) -> void:
	if not BUSES.has(bus_name):
		return
	var audio := _audio_manager()
	if audio != null:
		audio.call("set_volume", bus_name, clampf(linear, 0.0, 1.0))

func get_volume(bus_name: String) -> float:
	var audio := _audio_manager()
	if audio != null:
		return float(audio.call("get_volume", bus_name))
	return 1.0

func _audio_manager() -> Node:
	var tree := Engine.get_main_loop() as SceneTree
	if tree == null or tree.root == null:
		return null
	return tree.root.get_node_or_null("AudioManager")

## ------------------------------------------------------------- ui scaling

## Scale the whole interface at once. `content_scale_factor` multiplies the
## canvas stretch, so every Control - HUD bars, panels, fonts, anchors - scales
## together and stays anchored at any window size or aspect ratio.
func apply_ui_scale() -> void:
	var tree := Engine.get_main_loop() as SceneTree
	if tree == null or tree.root == null:
		return
	var window := tree.root as Window
	if window != null:
		window.content_scale_factor = ui_scale

## --------------------------------------------------------------- bindings

func binding_keycode(action: String) -> int:
	return int(bindings.get(action, BINDABLE_ACTIONS.get(action, 0)))

## Replace an action's binding with one physical key. Refuses actions that are
## not in the bindable set, and refuses a key that already drives a different
## bindable action - the screen reports the conflict instead of silently
## creating a double-bound action.
func set_binding(action: String, keycode: int) -> String:
	if not BINDABLE_ACTIONS.has(action):
		return "unknown action"
	if keycode <= 0:
		return "invalid key"
	for other in BINDABLE_ACTIONS:
		if other != action and binding_keycode(other) == keycode:
			return "already bound to %s" % other
	var event := InputEventKey.new()
	event.physical_keycode = keycode
	InputMap.action_erase_events(action)
	InputMap.action_add_event(action, event)
	bindings[action] = keycode
	save_to_disk()
	return ""

func reset_bindings() -> void:
	bindings.clear()
	for action in BINDABLE_ACTIONS:
		bindings[action] = int(BINDABLE_ACTIONS[action])
	_apply_bindings_to_input_map()
	save_to_disk()

func _apply_bindings_to_input_map() -> void:
	for action in bindings:
		var keycode := int(bindings[action])
		if keycode <= 0:
			continue
		if not InputMap.has_action(action):
			InputMap.add_action(action)
		var event := InputEventKey.new()
		event.physical_keycode = keycode
		if InputMap.action_has_event(action, event):
			continue
		InputMap.action_erase_events(action)
		InputMap.action_add_event(action, event)

## ------------------------------------------------------------------ report

func describe() -> Dictionary:
	var volumes := {}
	for bus_name in BUSES:
		volumes[bus_name] = get_volume(bus_name)
	return {
		"path": SETTINGS_PATH,
		"global_path": settings_global_path(),
		"ui_scale": ui_scale,
		"mouse_sensitivity": mouse_sensitivity,
		"shake": shake_intensity,
		"flash": flash_intensity,
		"bindings": bindings.duplicate(),
		"volumes": volumes,
		"load_error": load_error,
	}
