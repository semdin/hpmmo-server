extends RefCounted
class_name GameSettings

## Interface player settings ("Provide scalable UI at common
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
##     persisted;
##   * the graphics quality ("auto" or a QualityPreset name), read by
##     quality_preset.gd.
##
## Persistence is a ConfigFile per account: in an exported build it lives in
## the game's own install folder (`<install>/userdata/accounts/<account>/
## settings.cfg`, which updates leave alone), in the editor under `user://`. Before
## anyone signs in the shared `settings.cfg` applies; `use_account()` (called
## on login) switches to that account's file, seeding it from the current
## values the first time. Audio volumes are stored with it.
##
## The class is a lazily-created static singleton so any script (including the
## player controller, which only needs `mouse_sensitivity()`) can consult it
## without adding an autoload to project.godot.

const SETTINGS_PATH := "user://settings.cfg"
const SECTION_AUDIO := "audio"
## The signed-in account whose file is in use ("" = the shared file).
static var _account := ""
const SECTION_GENERAL := "general"
const SECTION_BINDINGS := "bindings"

const UI_SCALE_DEFAULT := 1.0
## What "100 %" means on screen: the canvas content scale a 1.0 setting applies.
## The layout was authored a touch large; 0.85 is the size that reads right, so
## that is now the baseline and the slider is relative to it.
const UI_SCALE_BASE := 0.85
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
const GRAPHICS_CHOICES := ["auto", "low", "medium", "high"]
const GRAPHICS_DEFAULT := "auto"

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
	"spell_5": KEY_5,
	"spell_6": KEY_6,
	"quickslot_1": KEY_F1,
	"quickslot_2": KEY_F2,
	"quickslot_3": KEY_F3,
	"quickslot_4": KEY_F4,
	"toggle_map": KEY_M,
	"toggle_character": KEY_C,
	"toggle_onboarding": KEY_J,
}

static var _instance: GameSettings = null

var ui_scale: float = UI_SCALE_DEFAULT
var mouse_sensitivity: float = SENSITIVITY_DEFAULT
var shake_intensity: float = SHAKE_DEFAULT
var flash_intensity: float = FLASH_DEFAULT
var graphics_quality: String = GRAPHICS_DEFAULT
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
	var root := _data_root()
	if _account == "":
		return root + "settings.cfg"
	return root + "accounts/%s/settings.cfg" % _account

## `<install>/userdata/` for an exported build when that folder is writable,
## else `user://`. The launcher runs each release from
## `<install>/versions/<version>/`, so the folder sits at the install root -
## beside `versions`, where an update never replaces it.
static func _data_root() -> String:
	if OS.has_feature("editor") or not OS.has_feature("template"):
		return "user://"
	var base := OS.get_executable_path().get_base_dir()
	if base.get_base_dir().get_file().to_lower() == "versions":
		base = base.get_base_dir().get_base_dir()
	var dir := base.path_join("userdata")
	if DirAccess.make_dir_recursive_absolute(dir) == OK:
		return dir + "/"
	return "user://"

## Switch to `account`'s settings (login). A first login keeps the values in
## use now, so nothing jumps; afterwards every account keeps its own.
static func use_account(account: String) -> void:
	var clean := account.strip_edges().to_lower().validate_filename()
	if clean == _account:
		return
	var settings := instance()
	_account = clean
	if FileAccess.file_exists(settings_path()):
		settings.load_from_disk()
	else:
		settings.save_to_disk()
	settings.apply_ui_scale()
	settings.apply_volumes()

static func settings_global_path() -> String:
	return ProjectSettings.globalize_path(settings_path())

## ------------------------------------------------------------------- load

func load_from_disk() -> void:
	ui_scale = UI_SCALE_DEFAULT
	mouse_sensitivity = SENSITIVITY_DEFAULT
	shake_intensity = SHAKE_DEFAULT
	flash_intensity = FLASH_DEFAULT
	graphics_quality = GRAPHICS_DEFAULT
	bindings.clear()
	load_error = ""
	for action in BINDABLE_ACTIONS:
		bindings[action] = int(BINDABLE_ACTIONS[action])
	var config := ConfigFile.new()
	var error := config.load(settings_path())
	if error != OK:
		# No file yet is the normal first-launch state: keep the defaults.
		if error != ERR_FILE_NOT_FOUND:
			load_error = "could not read settings (error %d)" % error
		_apply_bindings_to_input_map()
		return
	if config.has_section_key(SECTION_GENERAL, "ui_scale_v2"):
		ui_scale = clampf(float(config.get_value(SECTION_GENERAL, "ui_scale_v2", UI_SCALE_DEFAULT)), UI_SCALE_MIN, UI_SCALE_MAX)
	else:
		# A pre-baseline save stored the raw content scale: convert it so the
		# interface keeps the size the player picked.
		var raw := float(config.get_value(SECTION_GENERAL, "ui_scale", UI_SCALE_BASE))
		ui_scale = clampf(snappedf(raw / UI_SCALE_BASE, 0.05), UI_SCALE_MIN, UI_SCALE_MAX)
	mouse_sensitivity = clampf(float(config.get_value(SECTION_GENERAL, "mouse_sensitivity", SENSITIVITY_DEFAULT)), SENSITIVITY_MIN, SENSITIVITY_MAX)
	shake_intensity = clampf(float(config.get_value(SECTION_GENERAL, "shake", SHAKE_DEFAULT)), INTENSITY_MIN, INTENSITY_MAX)
	flash_intensity = clampf(float(config.get_value(SECTION_GENERAL, "flash", FLASH_DEFAULT)), INTENSITY_MIN, INTENSITY_MAX)
	var quality := String(config.get_value(SECTION_GENERAL, "graphics_quality", GRAPHICS_DEFAULT))
	graphics_quality = quality if GRAPHICS_CHOICES.has(quality) else GRAPHICS_DEFAULT
	volumes.clear()
	# Volumes saved against the previous (synthesised) sound set are dropped
	# once, so the regenerated soundtrack is heard at its intended mix.
	var audio_current := int(config.get_value(SECTION_AUDIO, "version", 1)) >= AUDIO_SETTINGS_VERSION
	for bus in BUSES:
		if audio_current and config.has_section_key(SECTION_AUDIO, String(bus)):
			volumes[String(bus)] = clampf(float(config.get_value(SECTION_AUDIO, String(bus), 1.0)), 0.0, 1.0)
	for action in BINDABLE_ACTIONS:
		var stored := int(config.get_value(SECTION_BINDINGS, action, int(BINDABLE_ACTIONS[action])))
		if stored <= 0:
			stored = int(BINDABLE_ACTIONS[action])
		bindings[action] = stored
	_apply_bindings_to_input_map()

func save_to_disk() -> void:
	var config := ConfigFile.new()
	config.set_value(SECTION_GENERAL, "ui_scale_v2", ui_scale)
	config.set_value(SECTION_GENERAL, "mouse_sensitivity", mouse_sensitivity)
	config.set_value(SECTION_GENERAL, "shake", shake_intensity)
	config.set_value(SECTION_GENERAL, "flash", flash_intensity)
	config.set_value(SECTION_GENERAL, "graphics_quality", graphics_quality)
	for action in bindings:
		config.set_value(SECTION_BINDINGS, action, int(bindings[action]))
	for bus in BUSES:
		config.set_value(SECTION_AUDIO, String(bus), get_volume(String(bus)))
	config.set_value(SECTION_AUDIO, "version", AUDIO_SETTINGS_VERSION)
	DirAccess.make_dir_recursive_absolute(settings_path().get_base_dir())
	var error := config.save(settings_path())
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

## "auto" or a preset name; QualityPreset.choose() applies it to the live world.
func set_graphics_quality(choice: String) -> void:
	graphics_quality = choice if GRAPHICS_CHOICES.has(choice) else GRAPHICS_DEFAULT
	save_to_disk()

## The four audio buses are owned by AudioManager (Spell effects), which already
## persists them to user://audio_settings.json. The settings screen drives that
## one API instead of keeping a second copy of the same numbers.
func set_volume(bus_name: String, linear: float) -> void:
	if not BUSES.has(bus_name):
		return
	volumes[bus_name] = clampf(linear, 0.0, 1.0)
	var audio := _audio_manager()
	if audio != null:
		audio.call("set_volume", bus_name, clampf(linear, 0.0, 1.0))
	save_to_disk()

## Push the stored volumes into the AudioManager (after loading a file).
func apply_volumes() -> void:
	var audio := _audio_manager()
	if audio == null:
		return
	for bus in volumes:
		audio.call("set_volume", String(bus), float(volumes[bus]))

## Matches AudioManager.SETTINGS_VERSION: bumped when the sound set is replaced.
const AUDIO_SETTINGS_VERSION := 2

## The volumes this settings file holds (bus -> 0..1); empty until saved once.
var volumes: Dictionary = {}

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
		window.content_scale_factor = ui_scale * UI_SCALE_BASE

## --------------------------------------------------------------- bindings

func binding_keycode(action: String) -> int:
	return int(bindings.get(action, BINDABLE_ACTIONS.get(action, 0)))

## Replace an action's binding with one physical key. Refuses actions that are
## not in the bindable set, and refuses a key that already drives a different
## bindable action - the screen reports the conflict instead of silently
## creating a double-bound action.
func set_binding(action: String, keycode: int) -> String:
	if not BINDABLE_ACTIONS.has(action):
		return "unknown action"  # i18n
	if keycode <= 0:
		return "invalid key"  # i18n
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
		"path": settings_path(),
		"global_path": settings_global_path(),
		"ui_scale": ui_scale,
		"mouse_sensitivity": mouse_sensitivity,
		"shake": shake_intensity,
		"flash": flash_intensity,
		"graphics_quality": graphics_quality,
		"bindings": bindings.duplicate(),
		"volumes": volumes,
		"load_error": load_error,
	}
