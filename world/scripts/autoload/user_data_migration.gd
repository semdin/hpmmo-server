extends Node

## UserDataMigration autoload - first in the autoload list, and its work runs
## in _init: every other autoload is instantiated after it, so none reads
## user:// before the copy below is done.
##
## user:// is named after application/config/name. Until the game was renamed
## that was "HPMMO" (…/app_userdata/HPMMO); now it is "Thousand Realms"
## (…/app_userdata/Thousand Realms). On the first start under the new name
## everything the player had there - settings, the saved login, quick slots,
## bag layout, character looks, onboarding and quest-seen state - is copied
## across. A file already present under the new name is never overwritten;
## logs and the renderer's caches are left behind (they regenerate). The old
## folder stays where it is: a rollback to an HPMMO build still finds it.
## A marker file makes this a one-time copy.

const LEGACY_NAME := "HPMMO"
const MARKER := "user://.migrated_from_hpmmo"
## Top-level folders not worth carrying over: logs, GPU caches, and the
## developer captures some tools write.
const SKIP_DIRS := ["logs", "shader_cache", "vulkan"]
const SKIP_DIR_SUFFIXES := ["_shots", "_probe"]

func _init() -> void:
	migrate()

static func migrate() -> void:
	if FileAccess.file_exists(MARKER):
		return
	var current := OS.get_user_data_dir()
	var legacy := current.get_base_dir().path_join(LEGACY_NAME)
	if legacy == current or not DirAccess.dir_exists_absolute(legacy):
		return
	var copied := _copy_tree(legacy, current, true)
	var marker := FileAccess.open(MARKER, FileAccess.WRITE)
	if marker != null:
		marker.store_string("copied %d file(s) from %s\n" % [copied, legacy])
		marker.close()
	print("[UserData] copied %d file(s) from %s" % [copied, legacy])

static func _copy_tree(from: String, to: String, top_level: bool) -> int:
	var dir := DirAccess.open(from)
	if dir == null:
		return 0
	DirAccess.make_dir_recursive_absolute(to)
	var copied := 0
	dir.include_hidden = true
	for name in dir.get_files():
		var target := to.path_join(name)
		if FileAccess.file_exists(target):
			continue
		if DirAccess.copy_absolute(from.path_join(name), target) == OK:
			copied += 1
	for name in dir.get_directories():
		if top_level and _skipped(name):
			continue
		copied += _copy_tree(from.path_join(name), to.path_join(name), false)
	return copied

static func _skipped(name: String) -> bool:
	if name in SKIP_DIRS:
		return true
	for suffix in SKIP_DIR_SUFFIXES:
		if name.ends_with(suffix):
			return true
	return false
