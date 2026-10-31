extends Node

## RenderCompat autoload - keeps the game drawable on GPU drivers that break a
## renderer. First in the autoload list: it may restart the game before any
## other autoload runs.
##
## NVK (Mesa's open Vulkan driver for NVIDIA cards, Fedora's default when the
## proprietary driver is not installed): Forward+ draws every lit surface black
## (terrain, castle, characters, even the character-select pedestal; only the
## sky and the UI survive) without logging an error. The Mobile renderer draws
## correctly, so an exported game on NVK writes `override.cfg` beside the
## executable (Godot reads it at startup, before any renderer exists) and
## restarts itself once with `--rendering-method mobile`; later starts of that
## version open in Mobile directly. When the driver is no longer NVK (the
## proprietary driver was installed) the file is removed again and the next
## start is Forward+.
##
## Mobile on NVK has one more trap: Mesa's NAK shader compiler (26.0) panics on
## a half-precision derivative (`assertion failed: intrin.def.bit_size() ==
## 32`), and Godot's Mobile renderer takes `fwidth` of the half alpha for alpha
## antialiasing (scene_forward_aa_inc.glsl). Every pipeline with an alpha
## antialiasing edge then fails to build and its meshes vanish: hairstyles,
## beards, tree leaves and impostors. Under Mobile that edge is turned off:
## hero_hair.gdshader sets it for Forward+ only, and the cooked vegetation
## materials (StandardMaterial3D) are patched here at startup and kept loaded,
## so every mesh that loads them later shares the patched copy.
##
## `--rendering-method` or `--rendering-driver` on the command line is the
## player's own choice and is never overridden.

const OVERRIDE_FILE := "override.cfg"
const OVERRIDE_MARK := "; HPMMO RenderCompat"
const VEGETATION_DIR := "res://assets/terrain/vegetation"

## Patched materials stay referenced, so the resource cache keeps serving them.
var _patched: Array[Material] = []

func _ready() -> void:
	if RenderingServer.get_video_adapter_name() == "":
		return  # headless / dedicated server
	var method := RenderingServer.get_current_rendering_method()
	if method == "forward_plus" and _is_nvk() and _may_restart():
		_restart_in_mobile()
		return
	if method == "mobile":
		if not _is_nvk():
			_remove_override()
		_strip_alpha_antialiasing()

static func _is_nvk() -> bool:
	return RenderingServer.get_video_adapter_name().contains("(NVK ")

## Only an exported game restarts, and never against the player's own flags.
static func _may_restart() -> bool:
	if not OS.has_feature("template"):
		return false
	for arg in OS.get_cmdline_args():
		if arg.begins_with("--rendering-method") or arg.begins_with("--rendering-driver"):
			return false
	return true

static func _override_path() -> String:
	return OS.get_executable_path().get_base_dir().path_join(OVERRIDE_FILE)

func _restart_in_mobile() -> void:
	print("[RenderCompat] %s: Forward+ draws black on NVK, restarting with the Mobile renderer" % RenderingServer.get_video_adapter_name())
	var file := FileAccess.open(_override_path(), FileAccess.WRITE)
	if file != null:
		file.store_string("%s: this GPU driver (NVK) draws Forward+ black.\n[rendering]\n\nrenderer/rendering_method=\"mobile\"\n" % OVERRIDE_MARK)
		file.close()
	var args := OS.get_cmdline_args()
	args.append_array(["--rendering-method", "mobile"])
	var user_args := OS.get_cmdline_user_args()
	if not user_args.is_empty():
		args.append("--")
		args.append_array(user_args)
	if OS.create_process(OS.get_executable_path(), args) <= 0:
		push_warning("[RenderCompat] restart failed; staying on Forward+")
		return
	# The child inherited the environment, the launcher's single-use
	# HPMMO_TICKET included. Stop here, before DatabaseManager redeems the
	# ticket or the menu logs in: a quit() would only land after this frame.
	OS.kill(OS.get_process_id())

## Remove our own override (a hand-written override.cfg is left alone).
static func _remove_override() -> void:
	var path := _override_path()
	if not OS.has_feature("template") or not FileAccess.file_exists(path):
		return
	if FileAccess.get_file_as_string(path).begins_with(OVERRIDE_MARK):
		DirAccess.remove_absolute(path)
		print("[RenderCompat] driver is not NVK: Forward+ again from the next start")

func _strip_alpha_antialiasing() -> void:
	for file in ResourceLoader.list_directory(VEGETATION_DIR):
		if not file.ends_with(".tres"):
			continue
		var material := load(VEGETATION_DIR.path_join(file)) as BaseMaterial3D
		if material != null and material.alpha_antialiasing_mode != BaseMaterial3D.ALPHA_ANTIALIASING_OFF:
			material.alpha_antialiasing_mode = BaseMaterial3D.ALPHA_ANTIALIASING_OFF
			_patched.append(material)
	print("[RenderCompat] Mobile renderer: alpha antialiasing off on %d materials" % _patched.size())
