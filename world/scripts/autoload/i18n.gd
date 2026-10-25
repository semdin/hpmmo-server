extends Node

## I18n autoload - the game's language.
##
## Source text is English everywhere (scripts, scenes, the data JSON): every
## English string is its own message id. A language is one gettext catalogue
## in `res://locale/<code>.po` listed under `internationalization/locale/
## translations` in project.godot; English needs no catalogue. Turkish is the
## default.
##
## Translating: nodes use `tr("English text")` (and `tr("Level %d") % level`
## for formatted text - translate the pattern, then format); static functions
## and data use `I18n.t()`. Content from the data JSON (item, mob, quest, map
## names) is translated where it is shown: `I18n.t(String(item.name))`.
## `tools/i18n/i18n.py` collects every message into locale/messages.pot and
## merges it into each catalogue; see docs/localization.md.
##
## The choice is per machine, not per account (the login screen needs it before
## anyone signs in): `<data root>/language.cfg`, beside the shared settings.
## The dedicated server always runs in English, so anything it composes reaches
## clients as message ids they translate themselves.

signal language_changed(code: String)

const DEFAULT_LANGUAGE := "tr"
const SOURCE_LANGUAGE := "en"
const CONFIG_FILE := "language.cfg"
## Each language's own name for itself (the picker shows these). A language
## missing here falls back to the engine's English name for the locale.
const NATIVE_NAMES := {
	"tr": "Türkçe",
	"en": "English",
	"de": "Deutsch",
	"fr": "Français",
	"es": "Español",
	"ru": "Русский",
	"pt": "Português",
}

var current := SOURCE_LANGUAGE

func _enter_tree() -> void:
	# Before any other autoload or the first scene builds a single label.
	# `--lang=<code>` wins everywhere (capture tools, headless checks).
	var forced := _cmdline_language()
	if forced != "":
		apply(forced, false)
	elif _is_server():
		TranslationServer.set_locale(SOURCE_LANGUAGE)
		current = SOURCE_LANGUAGE
	else:
		apply(_load_choice(), false)

## ------------------------------------------------------------------ query

## Every language the build can show: English plus each loaded catalogue,
## the default first. [{code, name}]
func languages() -> Array:
	var codes: Array = [SOURCE_LANGUAGE]
	for code in TranslationServer.get_loaded_locales():
		var short := String(code).get_slice("_", 0)
		if not codes.has(short):
			codes.append(short)
	codes.sort_custom(func(a, b):
		if a == DEFAULT_LANGUAGE or b == DEFAULT_LANGUAGE:
			return a == DEFAULT_LANGUAGE
		return a < b)
	return codes.map(func(code): return {"code": code, "name": native_name(code)})

func native_name(code: String) -> String:
	return String(NATIVE_NAMES.get(code, TranslationServer.get_locale_name(code)))

func is_turkish() -> bool:
	return current == "tr"

## ------------------------------------------------------------------ change

## Switch the language, remember it, and tell the screens that rebuild
## themselves (`language_changed`). Labels showing plain message ids follow on
## their own; text composed earlier keeps its language until it is rebuilt.
func set_language(code: String) -> void:
	apply(code, true)

func apply(code: String, persist: bool) -> void:
	var known: Array = languages().map(func(l): return String(l.code))
	if not known.has(code):
		code = DEFAULT_LANGUAGE if known.has(DEFAULT_LANGUAGE) else SOURCE_LANGUAGE
	var changed := code != current
	current = code
	TranslationServer.set_locale(code)
	if persist:
		_save_choice(code)
	if changed and is_inside_tree():
		language_changed.emit(code)

## ---------------------------------------------------------------- helpers

## Translate outside a node (static functions, data). `context` separates two
## meanings of the same English text (msgctxt in the catalogue).
static func t(message: String, context: String = "") -> String:
	if message.is_empty():
		return message
	return String(TranslationServer.translate(message, context))

## Text the world server composed in English (chat replies, boss and monolith
## lines, dungeon messages, creature names): a fixed line is its own message
## id; a line with a name or a number in it is matched against COMPOSED and
## rebuilt from the translated pattern, its pieces translated in turn.
func from_server(text: String) -> String:
	var exact := t(text)
	if exact != text or current == SOURCE_LANGUAGE or text.is_empty():
		return exact
	for pattern in COMPOSED:
		var found := _pattern_regex(pattern).search(text)
		if found == null:
			continue
		var kinds := _placeholders(pattern)
		var args: Array = []
		for i in range(1, found.get_group_count() + 1):
			var piece := found.get_string(i)
			# A title, a place or a creature; a player's name stays as it is.
			args.append(int(piece) if kinds[i - 1] == "d" else from_server(piece))
		return t(pattern) % args
	return text

## A creature's name as the server sends it (species, "Elite " + species, a
## boss part).
func mob_name(text: String) -> String:
	return from_server(text)

# i18n-begin
const COMPOSED := [
	"%s is now a GA.",
	"%s is no longer a GA.",
	"GAs: %s",
	"No player called '%s' is online.",
	"You invited %s to your party.",
	"%s was removed from the party.",
	"%s now leads the party.",
	"%s is already in a duel.",
	"%s is not in a party.",
	"%s is too far away to duel.",
	"You challenged %s's party to a group duel.",
	"You challenged %s to a duel.",
	"New title earned: %s!",
	"Elite %s",
	"Fluffy's %s Head",
	"Snare %s Vine",
	"Fluffy's %s head slumps!",
	"%s begins to play the harp...",
	"A vine shrivels in the flames! %d left.",
	"%s: a wave of creatures answers its call! (Wave %d/3)",
	"The %s has been shattered by %s! Riches shower the realm!",
	"A new %s has manifested in the realm!",
]
## Fixed server lines, listed so the catalogue carries them.
const SERVER_LINES := [
	"Rain started.",
	"Rain stopped.",
	"Only a GA can use /ga.",
	"Usage: /ga add Name",
	"Usage: /ga remove Name",
	"GA: /ga rain on|off, /ga add Name, /ga remove Name, /ga list",
	"There is no party invitation to accept.",
	"You joined the party.",
	"Invitation declined.",
	"You left the party.",
	"You are not in a party.",
	"You cannot invite yourself.",
	"That player is already in a party.",
	"Only the party leader can do that.",
	"The party is full (5).",
	"That player is not in your party.",
	"That did not work.",
	"Unknown command. Party: /invite Name, /accept, /decline, /leave, /kick Name, /promote Name, /p text. Duel: /duel Name, /gduel Name, /daccept, /ddecline, /yield",
	"Usage: /duel Name",
	"Usage: /gduel Name",
	"You cannot duel yourself.",
	"You are already in a duel.",
	"Both duelists must be alive.",
	"You need a party for a group duel.",
	"Only the party leader can call a group duel.",
	"You cannot duel your own party.",
	"There is no duel challenge to accept.",
	"The challenger is no longer here.",
	"One of you is already in a duel.",
	"You are too far apart to duel.",
	"The parties changed - challenge again.",
	"Duel declined.",
	"You are not in a duel.",
]
# i18n-end

var _pattern_cache: Dictionary = {}

func _pattern_regex(pattern: String) -> RegEx:
	if not _pattern_cache.has(pattern):
		var source := "^"
		var i := 0
		while i < pattern.length():
			var two := pattern.substr(i, 2)
			if two == "%s" or two == "%d":
				source += "(.+?)" if two == "%s" else "(-?\\d+)"
				i += 2
				continue
			var ch := pattern[i]
			source += ("\\" + ch) if ".^$*+?()[]{}|\\/".contains(ch) else ch
			i += 1
		_pattern_cache[pattern] = RegEx.create_from_string(source + "$")
	return _pattern_cache[pattern]

## "s" / "d" for each placeholder of `pattern`, in order.
static func _placeholders(pattern: String) -> Array:
	var kinds: Array = []
	var at := pattern.find("%")
	while at >= 0 and at + 1 < pattern.length():
		var kind := pattern[at + 1]
		if kind == "s" or kind == "d":
			kinds.append(kind)
		at = pattern.find("%", at + 2)
	return kinds

## Upper case that knows the Turkish dotted/dotless i (i -> İ, ı -> I); the
## engine's to_upper() would print "BILGI" for "Bilgi".
static func upper(text: String) -> String:
	if TranslationServer.get_locale().begins_with("tr"):
		text = text.replace("i", "İ").replace("ı", "I")
	return text.to_upper()

## Lower case counterpart of upper() (I -> ı, İ -> i in Turkish).
static func lower(text: String) -> String:
	if TranslationServer.get_locale().begins_with("tr"):
		text = text.replace("I", "ı").replace("İ", "i")
	return text.to_lower()

## ---------------------------------------------------------------- storage

func _is_server() -> bool:
	return "--server" in OS.get_cmdline_user_args() or "--server" in OS.get_cmdline_args() \
		or OS.has_feature("dedicated_server") or DisplayServer.get_name() == "headless"

func _config_path() -> String:
	return GameSettings._data_root() + CONFIG_FILE

func _cmdline_language() -> String:
	for arg in OS.get_cmdline_user_args() + OS.get_cmdline_args():
		if String(arg).begins_with("--lang="):
			return String(arg).substr(7)
	return ""

func _load_choice() -> String:
	var config := ConfigFile.new()
	if config.load(_config_path()) != OK:
		return DEFAULT_LANGUAGE
	return String(config.get_value("general", "language", DEFAULT_LANGUAGE))

func _save_choice(code: String) -> void:
	var config := ConfigFile.new()
	config.set_value("general", "language", code)
	DirAccess.make_dir_recursive_absolute(_config_path().get_base_dir())
	var error := config.save(_config_path())
	if error != OK:
		push_warning("[I18n] could not save the language (error %d)" % error)
