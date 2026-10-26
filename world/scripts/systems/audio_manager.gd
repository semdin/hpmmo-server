extends Node

## AudioManager - music, ambience, spell/creature/UI effects and the dynamic mix.
##
## Every sound is described by `assets/audio/sound_library.json` (bus, base gain,
## pitch variation, loop mode, positional or flat). The spell, basic-attack and
## creature cues come from ElevenLabs Sound Effects (art/audio_fal/sfx_spec.json);
## ambience, footsteps, interface, broom and the remaining creature cues from the
## same model, and the soundtrack from ElevenLabs Music
## (tools/audio/audio_spec.json, imported by tools/audio/import_audio_spec.py).
##
## What this provides:
##   * Music / SFX / UI / Ambience buses with independent, persisted volumes;
##   * spatial emitters with attenuation and a voice limit (combat warnings keep
##     a reserved slice), flat players for beds and interface sounds;
##   * a zone per place - the grounds split into meadow, courtyard, village,
##     forest, dark forest, moor, marsh and shore by hunting region, the castle
##     into great hall / library / corridors, and each dungeon its own - with
##     its own ambient beds, scattered one-shots, reverb and music pool;
##   * a music director: exploration tracks play once and give way to silence
##     before the next one (an MMO soundtrack that breathes instead of looping),
##     flight gets a soaring theme, combat and bosses take over with looping
##     battle music, and stingers mark a boss appearing, a boss falling and death;
##   * a tension mix: low health brings a heartbeat and muffles the world, a
##     dementor's despair adds an icy bed, combat ducks the ambience;
##   * broom flight: a wind bed that follows speed and a high-altitude wind
##     layer that replaces the ground ambience as the rider climbs;
##   * footsteps from the rig's own `footstep:<surface>` animation events.

const LIBRARY_PATH := "res://assets/audio/sound_library.json"
const SETTINGS_PATH := "user://audio_settings.json"
const BUSES := ["Music", "SFX", "UI", "Ambience"]

## Keys that must stay audible under heavy spell combinations.
const WARNING_PRIORITY := [
	"boss_slam_cast", "boss_slam_release", "boss_death",
	"spell_incendio_impact", "spell_bombarda_impact", "spell_ultimate_impact",
	"ui_hit", "spell_protego_impact",
]

## One-shot scatter sets, shared between zones. Each entry: keys, the gap
## between plays (seconds), and where it sounds (spatial ring around the
## listener, or flat).
const SCATTER := {
	"birds": {"keys": ["amb_bird_1", "amb_bird_2", "amb_bird_3", "amb_bird_4"], "gap": [7.0, 18.0], "spatial": true, "dist": [14.0, 32.0], "height": 6.0, "ground": true},
	"gusts": {"keys": ["amb_wind_gust_1", "amb_wind_gust_2"], "gap": [16.0, 34.0], "spatial": false},
	"leaves": {"keys": ["amb_leaf_rustle_1", "amb_leaf_rustle_2"], "gap": [10.0, 22.0], "spatial": true, "dist": [6.0, 16.0], "height": 2.5, "ground": true},
	"trees": {"keys": ["amb_tree_creak_1", "amb_tree_creak_2"], "gap": [12.0, 26.0], "spatial": true, "dist": [8.0, 22.0], "height": 5.0, "ground": true},
	"snap": {"keys": ["amb_branch_snap"], "gap": [28.0, 60.0], "spatial": true, "dist": [8.0, 16.0], "height": 0.5, "ground": true},
	"owls": {"keys": ["amb_owl_1", "amb_owl_2"], "gap": [18.0, 40.0], "spatial": true, "dist": [18.0, 34.0], "height": 7.0, "ground": true},
	"howl": {"keys": ["amb_wolf_howl"], "gap": [45.0, 90.0], "spatial": false},
	"crows": {"keys": ["amb_crow_1", "amb_crow_2"], "gap": [14.0, 32.0], "spatial": true, "dist": [16.0, 36.0], "height": 8.0, "ground": true},
	"frogs": {"keys": ["amb_frog_1", "amb_frog_2", "amb_bubble"], "gap": [6.0, 15.0], "spatial": true, "dist": [5.0, 15.0], "height": 0.3, "ground": true},
	"waves": {"keys": ["amb_wave"], "gap": [7.0, 14.0], "spatial": true, "dist": [8.0, 18.0], "height": 0.2, "ground": true},
	"castle": {"keys": ["amb_castle_door_far", "amb_castle_steps_far", "amb_portrait_whisper"], "gap": [14.0, 30.0], "spatial": true, "dist": [8.0, 22.0], "height": 2.0},
	"magic": {"keys": ["amb_magic_chime", "amb_ghost_laugh", "amb_owl_flutter"], "gap": [24.0, 50.0], "spatial": true, "dist": [6.0, 18.0], "height": 4.0},
	"hall": {"keys": ["amb_hall_laughter", "amb_owl_flutter", "amb_magic_chime"], "gap": [18.0, 38.0], "spatial": true, "dist": [8.0, 24.0], "height": 4.0},
	"library": {"keys": ["amb_library_page_1", "amb_library_page_2", "amb_quill"], "gap": [9.0, 20.0], "spatial": true, "dist": [3.0, 9.0], "height": 1.2},
	"drips": {"keys": ["amb_dungeon_drip_1", "amb_dungeon_drip_2", "amb_dungeon_drip_3"], "gap": [5.0, 12.0], "spatial": true, "dist": [4.0, 14.0], "height": 2.5},
	"deep": {"keys": ["amb_dungeon_rumble", "amb_dungeon_chains", "amb_dungeon_growl", "amb_dungeon_whisper_1", "amb_dungeon_whisper_2"], "gap": [16.0, 34.0], "spatial": true, "dist": [6.0, 18.0], "height": 2.0},
}

## Zone identities: ambient beds, scatter sets, reverb, and the music pool with
## the silence between its tracks.
const ZONES := {
	"grounds": {"beds": ["amb_grounds"], "scatter": ["birds", "gusts", "leaves"], "room_size": 0.2, "damping": 0.8, "wet": 0.05, "dry": 1.0,
		"music": ["music_grounds_a", "music_grounds_b"], "gap": [35.0, 80.0]},
	"courtyard": {"beds": ["amb_courtyard"], "scatter": ["birds", "gusts"], "room_size": 0.45, "damping": 0.6, "wet": 0.12, "dry": 1.0,
		"music": ["music_grounds_b", "music_grounds_a"], "gap": [30.0, 70.0]},
	"village": {"beds": ["amb_village"], "scatter": ["birds", "gusts"], "room_size": 0.3, "damping": 0.7, "wet": 0.08, "dry": 1.0,
		"music": ["music_village", "music_grounds_b"], "gap": [25.0, 60.0]},
	"forest": {"beds": ["amb_forest"], "scatter": ["birds", "trees", "leaves", "snap"], "room_size": 0.35, "damping": 0.7, "wet": 0.1, "dry": 1.0,
		"music": ["music_forest", "music_grounds_a"], "gap": [30.0, 70.0]},
	"forest_dark": {"beds": ["amb_forest_dark"], "scatter": ["owls", "trees", "snap", "howl"], "room_size": 0.4, "damping": 0.6, "wet": 0.12, "dry": 1.0,
		"music": ["music_wilds", "music_forest"], "gap": [20.0, 50.0]},
	"moor": {"beds": ["amb_moor"], "scatter": ["crows", "gusts", "howl"], "room_size": 0.25, "damping": 0.8, "wet": 0.06, "dry": 1.0,
		"music": ["music_wilds"], "gap": [25.0, 60.0]},
	"marsh": {"beds": ["amb_marsh"], "scatter": ["frogs", "crows"], "room_size": 0.3, "damping": 0.7, "wet": 0.08, "dry": 1.0,
		"music": ["music_wilds"], "gap": [25.0, 60.0]},
	"shore": {"beds": ["amb_shore"], "scatter": ["waves", "gusts", "crows"], "room_size": 0.3, "damping": 0.7, "wet": 0.08, "dry": 1.0,
		"music": ["music_wilds", "music_grounds_b"], "gap": [30.0, 70.0]},
	"great_hall": {"beds": ["amb_great_hall", "amb_fire"], "scatter": ["hall"], "room_size": 0.92, "damping": 0.35, "wet": 0.4, "dry": 0.88,
		"music": ["music_castle_a", "music_castle_b"], "gap": [30.0, 70.0]},
	"library": {"beds": ["amb_library"], "scatter": ["library", "magic"], "room_size": 0.35, "damping": 0.62, "wet": 0.18, "dry": 0.95,
		"music": ["music_castle_b"], "gap": [40.0, 90.0]},
	"interior": {"beds": ["amb_castle"], "scatter": ["castle", "magic"], "room_size": 0.7, "damping": 0.4, "wet": 0.3, "dry": 0.9,
		"music": ["music_castle_a", "music_castle_b"], "gap": [30.0, 70.0]},
	"dungeon": {"beds": ["amb_dungeon"], "scatter": ["drips", "deep"], "room_size": 0.75, "damping": 0.25, "wet": 0.38, "dry": 0.88,
		"music": ["music_dungeon"], "gap": [15.0, 35.0]},
	"corridor": {"beds": ["amb_corridor"], "scatter": ["drips", "deep"], "room_size": 0.8, "damping": 0.3, "wet": 0.4, "dry": 0.86,
		"music": ["music_corridor", "music_dungeon"], "gap": [12.0, 30.0]},
}

## Hunting region -> grounds zone. Anything unlisted is open meadow.
const REGION_ZONES := {
	"village": "village", "hogsmeade_road": "village",
	"forest_sw": "forest", "forest_w": "forest", "forest_e": "forest", "pitch_woods": "forest", "lakeside_glade": "forest",
	"forest_deep": "forest_dark", "dark_thicket": "forest_dark", "spider_woods": "forest_dark", "crypt_gate": "forest_dark",
	"boss_w": "forest_dark", "boss_e": "forest_dark", "troll_hollow": "forest_dark",
	"highland_moor": "moor", "western_moor": "moor", "eastern_moor": "moor", "ridge_path": "moor", "stone_summit": "moor",
	"hogsmeade_heights": "moor", "southern_barrows": "moor", "fog_barrens": "moor",
	"grey_marsh": "marsh", "warden_barrow": "marsh",
	"misty_shore": "shore", "station_mist": "shore",
}

const MAX_SPATIAL_VOICES := 24
## Flat voices include the reserved bed/layer players (up to ~9 at once).
const MAX_NONPOSITIONAL_VOICES := 22

## Music states -> the representative bed (the checks and settings read this).
const MUSIC_STATES := {
	"menu": "music_menu",
	"map": "music_grounds_a",
	"castle": "music_castle_a",
	"dungeon": "music_dungeon",
	"flight": "music_flight",
	"combat": "music_combat",
	"boss": "music_boss",
}

const MUSIC_FADE_IN := 3.0
const MUSIC_FADE_COMBAT := 0.8
const MUSIC_FADE_OUT := 3.5
## After a fight the world is quiet for a moment before exploration music returns.
const AFTER_COMBAT_GAP := [6.0, 14.0]

## Combat music lingers this long after the last blow / cast / valid target.
const COMBAT_LINGER := 9.0
const BOSS_LINGER := 14.0
const COMBAT_TARGET_RANGE := 45.0
const COMBAT_SPELLS := ["basic_cast", "stupefy", "incendio", "bombarda", "expelliarmus", "ultimate", "protego", "patronum", "glacius"]

## Flight: the rider is "flying" for the soundtrack once this high above the
## ground for this long; the high wind layer fades in between these heights.
const FLIGHT_MUSIC_HEIGHT := 10.0
const FLIGHT_MUSIC_DELAY := 4.0
const HIGH_WIND_FROM := 8.0
const HIGH_WIND_FULL := 60.0

## Tension: health fraction where the heartbeat starts / is at full strength.
const LOW_HP_START := 0.3
const LOW_HP_FULL := 0.1

var library: Dictionary = {}
var volumes := {"Music": 0.7, "SFX": 1.0, "UI": 0.9, "Ambience": 0.8}
var zone := "grounds"
var autodetect_zone := true

var _spatial_pool: Array[AudioStreamPlayer3D] = []
var _flat_pool: Array[AudioStreamPlayer] = []
var _loops: Dictionary = {}          # key::owner_id -> player
var _last_played: Dictionary = {}    # key -> msec, for rate limiting
var _streams: Dictionary = {}        # path -> AudioStream
## Every key that has actually been played (a small ring), presentation only.
var played_log: Array[String] = []
var _local_player: Node = null
var _last_step := ""
var _scan_timer := 0.0
var _zone_candidate := ""
var _zone_candidate_count := 0
var _map_id := ""

## Ambient beds: key -> {"player", "target_db", "base_db"}. Volumes move toward
## their target every frame, so crossfades and the altitude mix share one path.
var _beds: Dictionary = {}
var _layers: Dictionary = {}         # dynamic layers: high wind, heartbeat, despair, broom wind
var _scatter_next: Dictionary = {}   # scatter set -> seconds left
var _scatter_last: Dictionary = {}   # scatter set -> last key
var _reverb_sfx: AudioEffectReverb
var _reverb_amb: AudioEffectReverb
var _limiter_sfx: AudioEffectLimiter
var _lowpass_music: AudioEffectLowPassFilter
var _lowpass_amb: AudioEffectLowPassFilter
var _duck_music: AudioEffectAmplify
var _duck_amb: AudioEffectAmplify

## Dynamic mix state (smoothed in _process).
var _altitude := 0.0
var _mounted := false
var _speed := 0.0
var _flight_time := 0.0
var _hp_frac := 1.0
var _was_dead := false
var _despair := false
var _stinger_duck_until := 0.0

## Music director.
var music_state := ""
var _music_pinned := false
var _music_active: AudioStreamPlayer = null
var _music_active_key := ""
var _music_players: Array[AudioStreamPlayer] = []
var _music_tweens: Array[Tween] = []
var _music_pool_id := ""
var _music_pool: Array = []
var _music_next_at := 0.0
var _music_last_key := ""
var _music_combat_until := 0.0
var _music_boss_until := 0.0
var _boss_uid := 0
var _stinger_player: AudioStreamPlayer = null
var _last_stinger: Dictionary = {}
## HPMMO_AUDIO_DEBUG=1 prints the mix state every five seconds.
var _debug := OS.get_environment("HPMMO_AUDIO_DEBUG") != ""
var _debug_timer := 0.0
## Headless with no sound library (the dedicated server): nothing to play, so
## no combat signal is even listened to.
var _silent := false


func _ready() -> void:
	process_mode = Node.PROCESS_MODE_ALWAYS
	_ensure_buses()
	_load_library()
	_load_settings()
	_apply_volumes()
	_setup_bus_effects()
	_connect_combat_signals()
	_apply_zone(zone, true)


func _notification(what: int) -> void:
	if what == NOTIFICATION_WM_CLOSE_REQUEST or what == NOTIFICATION_PREDELETE \
			or what == NOTIFICATION_EXIT_TREE:
		# Shutdown must release every stream: a stopped player that still holds a
		# stream keeps an AudioStreamWAV and its playback alive past exit.
		stop_everything()
		_release_streams()

# ------------------------------------------------------------------ buses

func _ensure_buses() -> void:
	for bus_name in BUSES:
		if AudioServer.get_bus_index(bus_name) == -1:
			AudioServer.add_bus()
			AudioServer.set_bus_name(AudioServer.bus_count - 1, bus_name)
		var index := AudioServer.get_bus_index(bus_name)
		AudioServer.set_bus_send(index, "Master")
	_set_bus_volume_linear("Master", 1.0)


func _setup_bus_effects() -> void:
	var sfx_index := AudioServer.get_bus_index("SFX")
	_limiter_sfx = AudioEffectLimiter.new()
	# A burst of spells must not clip over a combat warning.
	_limiter_sfx.ceiling_db = -1.0
	_limiter_sfx.threshold_db = -6.0
	_limiter_sfx.soft_clip_db = -2.0
	AudioServer.add_bus_effect(sfx_index, _limiter_sfx)
	_reverb_sfx = AudioEffectReverb.new()
	AudioServer.add_bus_effect(sfx_index, _reverb_sfx)
	var amb_index := AudioServer.get_bus_index("Ambience")
	_reverb_amb = AudioEffectReverb.new()
	AudioServer.add_bus_effect(amb_index, _reverb_amb)
	# The tension mix: a low-pass that muffles the world when hurt or dead, and
	# an amplify stage that ducks ambience under a fight and music under a stinger.
	_lowpass_amb = AudioEffectLowPassFilter.new()
	_lowpass_amb.cutoff_hz = 20000.0
	AudioServer.add_bus_effect(amb_index, _lowpass_amb)
	_duck_amb = AudioEffectAmplify.new()
	AudioServer.add_bus_effect(amb_index, _duck_amb)
	var music_index := AudioServer.get_bus_index("Music")
	_lowpass_music = AudioEffectLowPassFilter.new()
	_lowpass_music.cutoff_hz = 20000.0
	AudioServer.add_bus_effect(music_index, _lowpass_music)
	_duck_music = AudioEffectAmplify.new()
	AudioServer.add_bus_effect(music_index, _duck_music)


func _set_bus_volume_linear(bus_name: String, linear: float) -> void:
	var index := AudioServer.get_bus_index(bus_name)
	if index == -1:
		return
	AudioServer.set_bus_volume_db(index, linear_to_db(maxf(0.0001, clampf(linear, 0.0, 1.5))))


func _apply_volumes() -> void:
	for bus_name in volumes:
		_set_bus_volume_linear(bus_name, float(volumes[bus_name]))


## Independent music / SFX / UI / ambience volume controls.
func set_volume(bus_name: String, linear: float) -> void:
	if not volumes.has(bus_name):
		return
	volumes[bus_name] = clampf(linear, 0.0, 1.0)
	_apply_volumes()
	_save_settings()


func get_volume(bus_name: String) -> float:
	return float(volumes.get(bus_name, 1.0))

# ------------------------------------------------------------------ library

func _load_library() -> void:
	if not FileAccess.file_exists(LIBRARY_PATH):
		# A dedicated server legitimately ships no audio: say so on stdout.
		print("AudioManager: running without a sound library (headless server)")
		# Nothing to mix: the per-frame zone, flight and tension work would only
		# track some player body on the server.
		if DisplayServer.get_name() == "headless":
			set_process(false)
			_silent = true
		return
	var parsed = JSON.parse_string(FileAccess.get_file_as_string(LIBRARY_PATH))
	if typeof(parsed) != TYPE_DICTIONARY:
		print("AudioManager: sound library is not valid JSON")
		return
	library = parsed.get("sounds", {})


func has_sound(key: String) -> bool:
	return library.has(key)


func played_keys() -> Array:
	return played_log.duplicate()


func clear_played_log() -> void:
	played_log.clear()


func sound_count() -> int:
	return library.size()


func _stream(key: String) -> AudioStream:
	var entry: Dictionary = library.get(key, {})
	if entry.is_empty():
		return null
	var path := String(entry.get("path", ""))
	if path == "" or not ResourceLoader.exists(path):
		return null
	if not _streams.has(path):
		var stream: AudioStream = load(path)
		# MP3/OGG beds carry their loop flag at runtime (the library decides).
		if stream is AudioStreamMP3:
			(stream as AudioStreamMP3).loop = bool(entry.get("loop", false))
		elif stream is AudioStreamOggVorbis:
			(stream as AudioStreamOggVorbis).loop = bool(entry.get("loop", false))
		_streams[path] = stream
	return _streams[path]

# ------------------------------------------------------------------ playing

func _spatial_player() -> AudioStreamPlayer3D:
	for player in _spatial_pool:
		if is_instance_valid(player) and not player.playing:
			return player
	if _spatial_pool.size() < MAX_SPATIAL_VOICES:
		var created := AudioStreamPlayer3D.new()
		created.name = "Spatial%d" % _spatial_pool.size()
		created.max_distance = 45.0
		created.unit_size = 6.0
		created.attenuation_model = AudioStreamPlayer3D.ATTENUATION_INVERSE_DISTANCE
		created.finished.connect(_on_voice_finished.bind(created))
		add_child(created)
		_spatial_pool.append(created)
		return created
	# voice limit reached: steal the oldest non-priority voice
	var oldest: AudioStreamPlayer3D = null
	var oldest_time := INF
	for player in _spatial_pool:
		if bool(player.get_meta("priority", false)) or bool(player.get_meta("bed", false)):
			continue
		var started := float(player.get_meta("started", 0.0))
		if started < oldest_time:
			oldest_time = started
			oldest = player
	return oldest if oldest != null else _spatial_pool[0]


func _flat_player() -> AudioStreamPlayer:
	for player in _flat_pool:
		if not player.playing and not bool(player.get_meta("bed", false)):
			return player
	if _flat_pool.size() < MAX_NONPOSITIONAL_VOICES:
		var created := AudioStreamPlayer.new()
		created.name = "Flat%d" % _flat_pool.size()
		created.finished.connect(_on_voice_finished.bind(created))
		add_child(created)
		_flat_pool.append(created)
		return created
	for player in _flat_pool:
		if not bool(player.get_meta("bed", false)):
			return player
	return _flat_pool[0]


const BUS_NAMES := {"sfx": "SFX", "ui": "UI", "ambience": "Ambience", "music": "Music"}


## A voice that finished releases its stream (an idle player holding a stream
## keeps its playback alive and the dummy driver reports it as a leak).
func _on_voice_finished(player: Node) -> void:
	if is_instance_valid(player) and player.get("playing") == false and not bool(player.get_meta("bed", false)):
		player.set("stream", null)


func _bus_for(entry: Dictionary) -> String:
	return String(BUS_NAMES.get(String(entry.get("bus", "sfx")), "SFX"))


## Play one positional sound. `owner_node` is used only to key loops and to
## clean up; it never gates whether the sound plays.
## The dedicated server (world_server.gd) switches the whole mixer off: it
## ships the sound library, so "no library" never told it apart, and it ran the
## zone, flight and tension mix every frame and answered every combat signal.
func disable_for_server() -> void:
	_silent = true
	set_process(false)
	for connection in get_incoming_connections():
		var sig: Signal = connection["signal"]
		if sig.get_object() == SimAuthority:
			sig.disconnect(connection["callable"])
	stop_everything()

func play_sound_at(key: String, position: Vector3, owner_node: Node = null, force_flat: bool = false) -> Node:
	if _silent:
		return null
	var entry: Dictionary = library.get(key, {})
	if entry.is_empty():
		return null
	var resolved_key := key
	if key == "spell_basic_cast_cast":
		var r := randi() % 3
		if r == 1 and has_sound("spell_basic_cast_cast_2"):
			resolved_key = "spell_basic_cast_cast_2"
		elif r == 2 and has_sound("spell_basic_cast_cast_3"):
			resolved_key = "spell_basic_cast_cast_3"
	elif key == "spell_basic_cast_impact":
		if randf() > 0.5 and has_sound("spell_basic_cast_impact_2"):
			resolved_key = "spell_basic_cast_impact_2"
	var stream := _stream(resolved_key)
	if stream == null:
		return null
	var flat_cue := not bool(entry.get("loop", false)) and (force_flat or not bool(entry.get("spatial", true)))
	if flat_cue:
		# Two listeners of one event must not stack the same flat sound on itself.
		var now := Time.get_ticks_msec()
		if now - int(_last_played.get(key, -100000)) < 80:
			return null
		_last_played[key] = now
	var bus_name := _bus_for(entry)
	played_log.append(key)
	if played_log.size() > 96:
		played_log.remove_at(0)
	var looping := bool(entry.get("loop", false))
	var variation := float(entry.get("pitch_variation", 0.0))
	var pitch := 1.0 if variation <= 0.0 else clampf(1.0 + randf_range(-variation, variation), 0.5, 2.0)
	if bool(entry.get("spatial", true)) and not force_flat:
		var player := _spatial_player()
		if player == null:
			return null
		_configure_player(player, key, stream, bus_name, float(entry.get("gain_db", 0.0)), pitch, looping)
		player.global_position = position
		_play_if_audible(player)
		return player
	var flat := _flat_player()
	_configure_player(flat, key, stream, bus_name, float(entry.get("gain_db", 0.0)), pitch, looping)
	_play_if_audible(flat)
	return flat


## Starting a stream is the one step that depends on there being an audio
## device; everything else runs identically headless.
func _play_if_audible(player: Node) -> void:
	if audio_available():
		player.call("play")


func _configure_player(player: Node, key: String, stream: AudioStream, bus_name: String, gain_db: float, pitch: float, looping: bool) -> void:
	player.stream = stream
	player.bus = bus_name
	player.pitch_scale = pitch
	player.volume_db = gain_db
	player.set_meta("key", key)
	player.set_meta("started", float(Time.get_ticks_msec()) / 1000.0)
	player.set_meta("priority", key in WARNING_PRIORITY)
	if looping and player is AudioStreamPlayer3D:
		(player as AudioStreamPlayer3D).max_distance = 60.0


## Start (or reuse) a looping sound for one owner. Returns the player.
func loop_sound(key: String, owner_node: Node, fade: float = 0.0) -> Node:
	var entry: Dictionary = library.get(key, {})
	if entry.is_empty():
		return null
	var loop_key := "%s::%d" % [key, owner_node.get_instance_id() if is_instance_valid(owner_node) else 0]
	if _loops.has(loop_key) and is_instance_valid(_loops[loop_key]):
		return _loops[loop_key]
	var player := play_sound_at(key, (owner_node as Node3D).global_position if owner_node is Node3D else Vector3.ZERO, owner_node)
	if player != null:
		_loops[loop_key] = player
		if fade > 0.0:
			player.volume_db = -60.0
			var tween := create_tween()
			tween.tween_property(player, "volume_db", float(entry.get("gain_db", 0.0)), fade)
	return player


## Keep a loop on its moving owner (a bolt in flight).
func move_loop(key: String, owner_node: Node, position: Vector3) -> void:
	var loop_key := "%s::%d" % [key, owner_node.get_instance_id() if is_instance_valid(owner_node) else 0]
	var player = _loops.get(loop_key)
	if player is AudioStreamPlayer3D and is_instance_valid(player) \
			and (player as AudioStreamPlayer3D).stream == _stream(key):
		(player as AudioStreamPlayer3D).global_position = position


func stop_sound(key: String, owner_node: Node) -> void:
	var loop_key := "%s::%d" % [key, owner_node.get_instance_id() if is_instance_valid(owner_node) else 0]
	if not _loops.has(loop_key):
		return
	var player = _loops[loop_key]
	_loops.erase(loop_key)
	stop_player(player)


func stop_player(player: Node) -> void:
	if player == null or not is_instance_valid(player):
		return
	if player is AudioStreamPlayer3D or player is AudioStreamPlayer:
		player.stop()


## Every effect and sound stops here: shutdown, map transfer, death. Music keeps
## its state: the poll re-arms the chosen bed as soon as the world is back.
func stop_everything() -> void:
	for player in _spatial_pool:
		if is_instance_valid(player):
			player.stop()
			player.stream = null
			player.set_meta("bed", false)
	for player in _flat_pool:
		if is_instance_valid(player):
			player.stop()
			player.stream = null
			player.set_meta("bed", false)
	_kill_music_tweens()
	for player in _music_players:
		if is_instance_valid(player):
			player.stop()
			player.stream = null
	if _stinger_player != null and is_instance_valid(_stinger_player):
		_stinger_player.stop()
		_stinger_player.stream = null
	_music_active = null
	_music_active_key = ""
	_music_pool_id = ""
	_loops.clear()
	_beds.clear()
	_layers.clear()
	_scatter_next.clear()


func _release_streams() -> void:
	_streams.clear()
	library.clear()
	for player in _spatial_pool:
		if is_instance_valid(player):
			player.stream = null
	for player in _flat_pool:
		if is_instance_valid(player):
			player.stream = null
	for player in _music_players:
		if is_instance_valid(player):
			player.stream = null
	_spatial_pool.clear()
	_flat_pool.clear()
	_beds.clear()
	_layers.clear()
	_loops.clear()
	_scatter_next.clear()
	_music_players.clear()
	_music_tweens.clear()
	_music_active = null
	_music_active_key = ""
	_stinger_player = null

# ------------------------------------------------------------------ zones

## Switch the ambient beds, scatter and reverb. `set_zone` is the explicit hook
## (it also turns autodetection off until `autodetect_zone` is set again).
func set_zone(name: String) -> void:
	if _silent:
		return
	if not ZONES.has(name) or name == zone:
		return
	_apply_zone(name, false)


func _apply_zone(name: String, immediate: bool) -> void:
	zone = name
	var config: Dictionary = ZONES.get(name, ZONES["grounds"])
	_apply_reverb(float(config["room_size"]), float(config["damping"]), float(config["wet"]), float(config["dry"]))
	_set_zone_beds(config["beds"], immediate)
	_reset_scatter(config["scatter"])
	_apply_music_state(immediate)


func _apply_reverb(room_size: float, damping: float, wet: float, dry: float) -> void:
	for effect in [_reverb_sfx, _reverb_amb]:
		if effect == null:
			continue
		effect.room_size = room_size
		effect.damping = damping
		effect.wet = wet
		effect.dry = dry
		effect.spread = 0.6


## True when there is an audio device that can actually play the beds.
func audio_available() -> bool:
	var driver := AudioServer.get_driver_name().to_lower()
	return driver != "" and driver != "dummy"


## Beds crossfade: beds the new zone keeps stay, the others fade to silence and
## stop, new ones fade in. The per-frame mixer does the fading.
func _set_zone_beds(keys: Array, immediate: bool) -> void:
	for key in _beds.keys():
		if not keys.has(key):
			(_beds[key] as Dictionary)["target_db"] = -60.0
	for key in keys:
		if _beds.has(key):
			var bed: Dictionary = _beds[key]
			bed["target_db"] = float(bed["base_db"])
			continue
		var player := _start_bed(String(key), immediate)
		if player != null:
			var base := float(library[key].get("gain_db", -18.0))
			_beds[key] = {"player": player, "target_db": base, "base_db": base}


## A bed player (flat or positional) reserved from the pool until it stops.
func _start_bed(key: String, immediate: bool) -> Node:
	if not audio_available():
		return null
	var entry: Dictionary = library.get(key, {})
	var stream := _stream(key)
	if entry.is_empty() or stream == null:
		return null
	var player: Node = _flat_player()
	player.stream = stream
	player.bus = _bus_for(entry)
	player.pitch_scale = 1.0
	player.volume_db = float(entry.get("gain_db", -18.0)) if immediate else -60.0
	player.set_meta("key", key)
	player.set_meta("bed", true)
	_play_if_audible(player)
	# Start somewhere inside the loop so two visits never open on the same bar.
	if stream.get_length() > 4.0:
		player.call("seek", randf_range(0.0, stream.get_length() * 0.8))
	return player


func _stop_bed_player(player: Node) -> void:
	if player == null or not is_instance_valid(player):
		return
	player.call("stop")
	player.set("stream", null)
	player.set_meta("bed", false)


## Beds and dynamic layers glide toward their target volume each frame.
func _mix_beds(delta: float) -> void:
	# The ground beds give way to the high wind as the rider climbs.
	var ground_atten := -clampf((_altitude - HIGH_WIND_FROM) / (HIGH_WIND_FULL - HIGH_WIND_FROM), 0.0, 1.0) * 18.0 \
			if _is_outdoors() else 0.0
	for key in _beds.keys():
		var bed: Dictionary = _beds[key]
		var player: Node = bed["player"]
		if player == null or not is_instance_valid(player):
			_beds.erase(key)
			continue
		var target := float(bed["target_db"])
		if target > -59.0:
			target += ground_atten
		var current := float(player.get("volume_db"))
		player.set("volume_db", move_toward(current, target, delta * 30.0))
		if float(bed["target_db"]) <= -59.0 and current <= -58.0:
			_stop_bed_player(player)
			_beds.erase(key)
	for key in _layers.keys():
		var layer: Dictionary = _layers[key]
		var lp: Node = layer["player"]
		if lp == null or not is_instance_valid(lp):
			_layers.erase(key)
			continue
		var cur := float(lp.get("volume_db"))
		lp.set("volume_db", move_toward(cur, float(layer["target_db"]), delta * float(layer.get("rate", 24.0))))
		lp.set("pitch_scale", lerpf(float(lp.get("pitch_scale")), float(layer.get("pitch", 1.0)), minf(1.0, delta * 3.0)))
		if float(layer["target_db"]) <= -59.0 and cur <= -58.0:
			_stop_bed_player(lp)
			_layers.erase(key)


## A dynamic layer (high wind, heartbeat, despair chill, broom wind): `level`
## 0..1 maps silence..the library gain (+ `boost_db` at full).
func _set_layer(key: String, level: float, pitch: float = 1.0, boost_db: float = 0.0) -> void:
	if not has_sound(key):
		return
	var base := float(library[key].get("gain_db", -18.0))
	var target := -60.0 if level <= 0.01 else base + boost_db * level + linear_to_db(clampf(level, 0.02, 1.0))
	if _layers.has(key):
		(_layers[key] as Dictionary)["target_db"] = target
		(_layers[key] as Dictionary)["pitch"] = pitch
		return
	if target <= -59.0:
		return
	var player := _start_bed(key, false)
	if player != null:
		_layers[key] = {"player": player, "target_db": target, "pitch": pitch, "rate": 30.0}


func _reset_scatter(sets: Array) -> void:
	_scatter_next.clear()
	for set_name in sets:
		var cfg: Dictionary = SCATTER.get(set_name, {})
		if cfg.is_empty():
			continue
		var gap: Array = cfg["gap"]
		_scatter_next[set_name] = randf_range(float(gap[0]) * 0.3, float(gap[1]) * 0.6)


func _process_scatter(delta: float) -> void:
	if not audio_available() or _scatter_next.is_empty():
		return
	var listener := Vector3.ZERO
	if is_instance_valid(_local_player) and _local_player is Node3D:
		listener = (_local_player as Node3D).global_position
	if _local_player != null and bool(_local_player.get("is_dead")):
		return
	for set_name in _scatter_next.keys():
		_scatter_next[set_name] = float(_scatter_next[set_name]) - delta
		if float(_scatter_next[set_name]) > 0.0:
			continue
		var cfg: Dictionary = SCATTER[set_name]
		var gap: Array = cfg["gap"]
		# Fights and flight thin the scatter out: the world is busy elsewhere.
		var stretch := 1.6 if combat_music_active() else 1.0
		_scatter_next[set_name] = randf_range(float(gap[0]), float(gap[1])) * stretch
		if bool(cfg.get("ground", false)) and _altitude > 25.0:
			continue
		var choices: Array = []
		for key in cfg["keys"]:
			if has_sound(String(key)) and String(key) != String(_scatter_last.get(set_name, "")):
				choices.append(String(key))
		if choices.is_empty():
			continue
		var key: String = choices[randi() % choices.size()]
		_scatter_last[set_name] = key
		var node: Node = null
		if bool(cfg.get("spatial", false)) and listener != Vector3.ZERO:
			var dist_range: Array = cfg.get("dist", [10.0, 25.0])
			var angle := randf_range(0.0, TAU)
			var dist := randf_range(float(dist_range[0]), float(dist_range[1]))
			var h := randf_range(0.3, float(cfg.get("height", 3.0)))
			node = play_sound_at(key, listener + Vector3(cos(angle) * dist, h, sin(angle) * dist))
		else:
			node = play_sound_at(key, Vector3.ZERO, null, true)
			if node != null:
				node.set("bus", "Ambience")
		if node != null and is_instance_valid(node):
			node.set("volume_db", float(node.get("volume_db")) + randf_range(-2.5, 1.0))


func _is_outdoors() -> bool:
	return not (zone in ["great_hall", "library", "interior", "dungeon", "corridor"])


## Where the listener is: the map first (castle / dungeon / grounds), then the
## room or the hunting region. A new zone must hold for two polls (one second)
## so walking along a region edge does not flip the soundtrack back and forth.
func _autodetect_zone() -> void:
	if _local_player == null or not is_instance_valid(_local_player):
		return
	var pos: Vector3 = (_local_player as Node3D).global_position
	var map_id := HPMaps.base_map(HPMaps.map_for_point(pos))
	if _map_id != "" and map_id != _map_id and (map_id == "castle_interior" or _map_id == "castle_interior"):
		play_sound_at("door_open" if map_id == "castle_interior" else "door_close", Vector3.ZERO, null, true)
	_map_id = map_id
	var wanted := "grounds"
	if map_id == "castle_interior":
		if pos.z < -25.0 and pos.x < -10.0 and pos.y > 205.0:
			wanted = "library"
		elif pos.y < 199.0:
			wanted = "dungeon"
		elif pos.x < -20.0:
			wanted = "great_hall"
		else:
			wanted = "interior"
	elif map_id.begins_with("dng_forbidden"):
		wanted = "corridor"
	elif map_id.begins_with("dng_"):
		wanted = "dungeon"
	elif _altitude > 25.0 and _is_outdoors():
		# High above the grounds the region under the rider does not own the
		# soundscape (the high wind does): hold the zone instead of flipping
		# beds and music with every boundary crossed in flight.
		wanted = zone
	elif HPRules.is_protected_point(pos):
		wanted = "village" if pos.x > 300.0 else "courtyard"
	else:
		var region := HPRules.hunting_region_at(pos)
		wanted = String(REGION_ZONES.get(String(region.get("id", "")), "grounds"))
	if wanted == zone:
		_zone_candidate = ""
		return
	if wanted != _zone_candidate:
		_zone_candidate = wanted
		_zone_candidate_count = 0
	_zone_candidate_count += 1
	# Map changes (a door, a portal) switch at once; region edges wait a poll.
	var map_changed := (zone in ["great_hall", "library", "interior", "dungeon", "corridor"]) != (wanted in ["great_hall", "library", "interior", "dungeon", "corridor"])
	if map_changed or _zone_candidate_count >= 2:
		_zone_candidate = ""
		_apply_zone(wanted, false)

# ------------------------------------------------------------------ local player

## Subscribe to the local player's own events: footsteps, mount, casts, target.
func _find_local_player() -> void:
	if _local_player != null and is_instance_valid(_local_player):
		return
	for node in get_tree().get_nodes_in_group("players"):
		if node.has_signal("animation_event") and (node as Node).get("is_local_controlled") != false:
			_local_player = node
			_connect_once(node, "animation_event", "_on_animation_event")
			_connect_once(node, "spell_cast_signal", "_on_player_spell_cast")
			_connect_once(node, "target_changed", "_on_player_target_changed")
			_connect_once(node, "mounted_changed", "_on_player_mounted")
			_mounted = bool(node.get("is_mounted"))
			if _mounted:
				_set_layer("broom_wind", 0.4)
			# The world owns the soundtrack from here on.
			release_music_pin()
			return


func _connect_once(node: Node, signal_name: String, method: String) -> void:
	if node.has_signal(signal_name) and not node.is_connected(signal_name, Callable(self, method)):
		node.connect(signal_name, Callable(self, method))


func _on_animation_event(event_name: String) -> void:
	var text := String(event_name)
	var at: Vector3 = (_local_player as Node3D).global_position if is_instance_valid(_local_player) and _local_player is Node3D else Vector3.ZERO
	if text.begins_with("footstep:"):
		var surface := text.trim_prefix("footstep:")
		if not has_sound("step_%s_1" % surface):
			surface = "stone"
		# Four takes per surface, never the same one twice in a row.
		var key := _last_step
		for _i in 4:
			key = "step_%s_%d" % [surface, randi() % 4 + 1]
			if key != _last_step and has_sound(key):
				break
		_last_step = key
		_play_varied(key, at, 0.85)
	elif text == "oneshot_end:Broom_Land" or text.begins_with("landing"):
		play_sound_at("landing", at, _local_player)
	elif text.begins_with("robe"):
		_play_varied("robe_%d" % (randi() % 3 + 1), at, 0.7)


func _play_varied(key: String, at: Vector3, gain_scale: float) -> Node:
	var player := play_sound_at(key, at, _local_player)
	if player != null:
		player.volume_db += linear_to_db(maxf(0.05, gain_scale)) + randf_range(-1.5, 1.5)
	return player


func _on_player_mounted(mounted: bool) -> void:
	var at: Vector3 = (_local_player as Node3D).global_position if is_instance_valid(_local_player) and _local_player is Node3D else Vector3.ZERO
	play_mount(mounted, at, _local_player)


## Ride / dismount: the take-off or landing cue plus the broom wind bed.
func play_mount(mounted: bool, at: Vector3, owner_node: Node) -> void:
	_mounted = mounted
	_flight_time = 0.0
	play_sound_at("mount" if mounted else "dismount", at, owner_node)
	_set_layer("broom_wind", 0.4 if mounted else 0.0)


## Shift on the broom where landing is not possible: a soft refusal so the
## written reason also has a voice. Rate limited by the caller's notice cooldown.
func play_landing_blocked() -> void:
	play_sound_at("broom_land_blocked" if has_sound("broom_land_blocked") else "ui_deny", Vector3.ZERO, null, true)


func _process(delta: float) -> void:
	# A player freed by a map transfer, a character change or (on the server) a
	# logout: drop it before anything type-checks it.
	if _local_player != null and not is_instance_valid(_local_player):
		_local_player = null
	_process_scatter(delta)
	_process_flight(delta)
	_process_tension(delta)
	_mix_beds(delta)
	_scan_timer -= delta
	if _scan_timer > 0.0:
		return
	_scan_timer = 0.5
	_find_local_player()
	_measure_altitude()
	if autodetect_zone and _local_player != null:
		_autodetect_zone()
	# A map transfer or death stops every voice; the room tone comes back here.
	if _beds.is_empty() and audio_available():
		_set_zone_beds((ZONES.get(zone, ZONES["grounds"]) as Dictionary)["beds"], false)
		if _scatter_next.is_empty():
			_reset_scatter((ZONES.get(zone, ZONES["grounds"]) as Dictionary)["scatter"])
	_refresh_music()
	if _debug:
		_debug_timer -= 0.5
		if _debug_timer <= 0.0:
			_debug_timer = 5.0
			print("[Audio] ", describe(), " beds=", _beds.keys(), " played=", played_log.slice(-6))


## Height above the ground under the listener (0 indoors / unknown).
func _measure_altitude() -> void:
	_altitude = 0.0
	if not is_instance_valid(_local_player) or not (_local_player is Node3D) or not _is_outdoors():
		return
	var body := _local_player as Node3D
	if not body.is_inside_tree():
		return
	var space := body.get_world_3d().direct_space_state
	var query := PhysicsRayQueryParameters3D.create(body.global_position + Vector3.UP * 0.5, body.global_position + Vector3.DOWN * 150.0)
	if body is CollisionObject3D:
		query.exclude = [(body as CollisionObject3D).get_rid()]
	var hit := space.intersect_ray(query)
	_altitude = 150.0 if hit.is_empty() else maxf(0.0, body.global_position.y - (hit.position as Vector3).y)


## Broom wind follows speed; the high wind
## layer rises with altitude whether mounted or not.
func _process_flight(delta: float) -> void:
	var high := clampf((_altitude - HIGH_WIND_FROM) / (HIGH_WIND_FULL - HIGH_WIND_FROM), 0.0, 1.0) if _is_outdoors() else 0.0
	_set_layer("amb_high_wind", high)
	if not _mounted or not is_instance_valid(_local_player) or not (_local_player is CharacterBody3D):
		_flight_time = 0.0
		return
	var vel := (_local_player as CharacterBody3D).velocity
	var flat := Vector3(vel.x, 0.0, vel.z)
	_speed = flat.length()
	_flight_time = _flight_time + delta if _altitude > FLIGHT_MUSIC_HEIGHT else maxf(0.0, _flight_time - delta * 2.0)
	var ratio := clampf(_speed / 20.0, 0.0, 1.0)
	_set_layer("broom_wind", lerpf(0.35, 1.0, ratio), lerpf(0.85, 1.2, ratio), 4.0)
	# No one-shot swoosh on hard turns and dives: it fired as a sudden "whoop"
	# on every sharp bank (2026-10-21 playtest). The wind bed carries the speed.


## Low health, despair, combat and death shape the mix.
func _process_tension(delta: float) -> void:
	var dead := false
	if _local_player != null and is_instance_valid(_local_player):
		dead = bool(_local_player.get("is_dead"))
		var max_hp := maxf(1.0, float(_local_player.get("max_hp")))
		_hp_frac = clampf(float(_local_player.get("current_hp")) / max_hp, 0.0, 1.0) if not dead else 0.0
	else:
		_hp_frac = 1.0
	if dead and not _was_dead:
		_on_local_death()
	_was_dead = dead
	# Heartbeat: from LOW_HP_START down to LOW_HP_FULL, faster as it gets worse.
	var danger := 0.0 if dead else clampf((LOW_HP_START - _hp_frac) / (LOW_HP_START - LOW_HP_FULL), 0.0, 1.0)
	if _local_player != null:
		_set_layer("tension_heartbeat", danger, lerpf(0.95, 1.3, danger))
		if _scan_timer <= 0.0:
			_despair = _despair_active()
		_set_layer("amb_despair", 0.85 if _despair and not dead else 0.0)
	# Muffle: hurt -> 1.8 kHz, dead -> 700 Hz; despair takes the top off too.
	var cutoff := 20000.0
	if dead:
		cutoff = 700.0
	elif danger > 0.0:
		cutoff = lerpf(9000.0, 1800.0, danger)
	if _despair and not dead:
		cutoff = minf(cutoff, 4500.0)
	for filter in [_lowpass_music, _lowpass_amb]:
		if filter != null:
			var f := filter as AudioEffectLowPassFilter
			# glide in log space so the sweep sounds even
			f.cutoff_hz = exp(lerpf(log(f.cutoff_hz), log(cutoff), minf(1.0, delta * 2.5)))
	if _duck_amb != null:
		var amb_target := -5.0 if combat_music_active() else 0.0
		_duck_amb.volume_db = move_toward(_duck_amb.volume_db, amb_target, delta * 6.0)
	if _duck_music != null:
		var music_target := -9.0 if _now() < _stinger_duck_until else 0.0
		_duck_music.volume_db = move_toward(_duck_music.volume_db, music_target, delta * 18.0)


func _despair_active() -> bool:
	if not is_instance_valid(SimAuthority) or _local_player == null:
		return false
	var record: Dictionary = SimAuthority.record_for(_local_player)
	return not record.is_empty() and int(record.get("despair_until_tick", 0)) > int(SimAuthority.sim_tick)


func _on_local_death() -> void:
	_music_combat_until = 0.0
	_music_boss_until = 0.0
	_stop_music(1.2)
	play_stinger("stinger_death")

# ------------------------------------------------------------------ music

## A pinned state (the front menu) owns the soundtrack until the world is found.
func set_music_state(state: String) -> void:
	if not MUSIC_STATES.has(state):
		return
	music_state = state
	_music_pinned = true
	_apply_music_state(false)


func release_music_pin() -> void:
	if not _music_pinned:
		return
	_music_pinned = false
	music_state = ""
	_apply_music_state(false)


func get_music_state() -> String:
	return music_state


## The zone that owns a room -> the state its bed represents.
func music_state_for_zone(zone_name: String) -> String:
	if zone_name in ["great_hall", "library", "interior"]:
		return "castle"
	if zone_name in ["dungeon", "corridor"]:
		return "dungeon"
	return "map"


## A fight started near the local body: raise or extend the combat override.
func notify_combat(seconds: float = COMBAT_LINGER) -> void:
	_music_combat_until = maxf(_music_combat_until, _now() + maxf(0.0, seconds))
	_apply_music_state(false)


func notify_boss(uid: int = 0, seconds: float = BOSS_LINGER) -> void:
	if _music_boss_until < _now():
		play_stinger("stinger_boss")
	_music_boss_until = maxf(_music_boss_until, _now() + seconds)
	if uid != 0:
		_boss_uid = uid
	notify_combat(seconds)


func combat_music_active() -> bool:
	return _music_combat_until > _now()


## A short musical cue over the soundtrack; the music ducks under it.
func play_stinger(key: String) -> void:
	if _silent:
		return
	if not has_sound(key) or not audio_available():
		return
	# Stingers are rare punctuation: never two within a few seconds (a login
	# that replays several world events, a boss hit that re-arms the boss state).
	if _now() - float(_last_stinger.get(key, -1000.0)) < 30.0 or _now() < _stinger_duck_until:
		return
	_last_stinger[key] = _now()
	var stream := _stream(key)
	if stream == null:
		return
	if _stinger_player == null or not is_instance_valid(_stinger_player):
		_stinger_player = AudioStreamPlayer.new()
		_stinger_player.name = "Stinger"
		_stinger_player.process_mode = Node.PROCESS_MODE_ALWAYS
		add_child(_stinger_player)
	_stinger_player.stream = stream
	_stinger_player.bus = "UI"
	_stinger_player.volume_db = float(library[key].get("gain_db", -9.0))
	_stinger_player.play()
	_stinger_duck_until = _now() + stream.get_length()
	played_log.append(key)


func _now() -> float:
	return float(Time.get_ticks_msec()) / 1000.0


func _connect_combat_signals() -> void:
	if _silent or not is_instance_valid(SimAuthority):
		return
	if SimAuthority.has_signal("cast_started"):
		SimAuthority.cast_started.connect(_on_sim_cast_started)
	if SimAuthority.has_signal("entity_damaged"):
		SimAuthority.entity_damaged.connect(_on_sim_entity_damaged)
	if SimAuthority.has_signal("entity_died"):
		SimAuthority.entity_died.connect(_on_sim_entity_died)


func _local_uid() -> int:
	return int(SimAuthority.local_uid) if is_instance_valid(SimAuthority) else 0


func _on_sim_cast_started(uid: int, _cast_id: int, spell_id: String, _aim: Vector3, _release_tick: int) -> void:
	if uid == _local_uid() and spell_id in COMBAT_SPELLS:
		notify_combat()


func _on_sim_entity_damaged(uid: int, _amount: int, _hp: int, _spell_id: String, attacker_uid: int) -> void:
	var local := _local_uid()
	if local == 0 or (uid != local and attacker_uid != local):
		return
	var other := attacker_uid if uid == local else uid
	var node = SimAuthority.record_by_uid(other).get("node") if SimAuthority.has_method("record_by_uid") else null
	if node is Node and is_instance_valid(node) and bool((node as Node).get("is_boss")):
		notify_boss(other)
	else:
		notify_combat()


func _on_sim_entity_died(uid: int, _killer_uid: int) -> void:
	if uid != 0 and uid == _boss_uid:
		_boss_uid = 0
		_music_boss_until = 0.0
		_music_combat_until = minf(_music_combat_until, _now() + 1.0)
		play_stinger("stinger_victory")


func _on_player_spell_cast(spell_id: String, _cooldown: float) -> void:
	if spell_id in COMBAT_SPELLS:
		notify_combat()


func _on_player_target_changed(_target: Node3D) -> void:
	if _combat_target() != null:
		notify_combat()


## A live hostile in reach is combat intent even before the first blow.
func _combat_target() -> Node3D:
	if _local_player == null or not is_instance_valid(_local_player):
		return null
	var target = _local_player.get("current_target")
	if target == null or not is_instance_valid(target) or not (target is Node3D):
		return null
	if target.get("is_dead"):
		return null
	if not (target.is_in_group("mobs") or target.is_in_group("targetable")):
		return null
	var here: Vector3 = (_local_player as Node3D).global_position
	if here.distance_to((target as Node3D).global_position) > COMBAT_TARGET_RANGE:
		return null
	return target


func _combat_target_present() -> bool:
	return _combat_target() != null


## What should be sounding: a state and its pool.
func _music_target() -> Dictionary:
	if _music_pinned:
		return {"state": music_state, "pool": [String(MUSIC_STATES.get(music_state, ""))], "loop": true}
	if _local_player == null or not is_instance_valid(_local_player):
		return {"state": "", "pool": []}
	if bool(_local_player.get("is_dead")):
		return {"state": "dead", "pool": []}
	if _music_boss_until > _now():
		return {"state": "boss", "pool": ["music_boss"], "loop": true}
	if combat_music_active():
		return {"state": "combat", "pool": ["music_combat"], "loop": true}
	if _mounted and _flight_time > FLIGHT_MUSIC_DELAY and _is_outdoors():
		return {"state": "flight", "pool": ["music_flight"], "gap": [20.0, 45.0]}
	var config: Dictionary = ZONES.get(zone, ZONES["grounds"])
	return {"state": music_state_for_zone(zone), "pool": config["music"], "gap": config["gap"]}


## Poll-time refresh: keep the combat window honest and the right music going.
func _refresh_music() -> void:
	var target := _combat_target()
	if combat_music_active() and target != null:
		if target.get("is_boss") == true:   # a dummy or a monolith has no is_boss
			notify_boss(int(target.get("uid")) if "uid" in target else 0)
		else:
			notify_combat()
	_apply_music_state(false)


func _apply_music_state(immediate: bool) -> void:
	var want := _music_target()
	var pool: Array = want.get("pool", [])
	var state := String(want.get("state", ""))
	var pool_id := "%s:%s" % [state, ",".join(pool)]
	var playing := _music_active != null and is_instance_valid(_music_active) and _music_active.playing
	if pool_id != _music_pool_id:
		var previous_state := _music_pool_id.get_slice(":", 0)
		_music_pool_id = pool_id
		_music_pool = pool
		if pool.is_empty():
			_stop_music(0.0 if immediate else (1.2 if state == "dead" else MUSIC_FADE_OUT))
			return
		# The track already sounding belongs to the new pool: let it play on.
		if playing and pool.has(_music_active_key):
			return
		# Landing mid flight-theme: let the theme play out, then the place's
		# own music returns after the usual gap (no cut on every touch-down).
		if playing and previous_state == "flight" and not (state in ["combat", "boss", "dead", "menu"]):
			return
		var into_fight := state == "combat" or state == "boss"
		if into_fight or state == "menu" or state == "flight" or not playing and previous_state == "":
			_start_music(_pick_track(pool), 0.0 if immediate else (MUSIC_FADE_COMBAT if into_fight else MUSIC_FADE_IN))
		else:
			# Out of a fight / into a new place: let the old track fade, then a
			# breath of silence before the new one (longer after a fight).
			_stop_music(0.0 if immediate else MUSIC_FADE_OUT)
			var after_fight := previous_state == "combat" or previous_state == "boss"
			var gap := randf_range(AFTER_COMBAT_GAP[0], AFTER_COMBAT_GAP[1]) if after_fight else randf_range(2.0, 5.0)
			_music_next_at = _now() + (0.0 if immediate else gap)
		return
	if playing or pool.is_empty():
		return
	if _now() >= _music_next_at:
		_start_music(_pick_track(pool), 0.0 if immediate else MUSIC_FADE_IN)


func _pick_track(pool: Array) -> String:
	var options: Array = []
	for key in pool:
		if has_sound(String(key)) and String(key) != _music_last_key:
			options.append(String(key))
	if options.is_empty():
		for key in pool:
			if has_sound(String(key)):
				options.append(String(key))
	return "" if options.is_empty() else String(options[randi() % options.size()])


func _start_music(key: String, fade: float) -> void:
	if key == "":
		return
	_music_active_key = key
	_music_last_key = key
	if not audio_available():
		return
	var stream := _stream(key)
	if stream == null:
		return
	_ensure_music_players()
	var outgoing := _music_active
	var incoming: AudioStreamPlayer = _music_players[0]
	if outgoing == _music_players[0]:
		incoming = _music_players[1]
	_kill_music_tweens()
	for player in _music_players:
		if player == incoming or not is_instance_valid(player) or not player.playing:
			continue
		if fade > 0.0 and player == outgoing:
			var fade_tween := create_tween()
			fade_tween.tween_property(player, "volume_db", -60.0, minf(fade * 1.5, MUSIC_FADE_OUT))
			fade_tween.tween_callback(player.stop)
			_music_tweens.append(fade_tween)
		else:
			player.stop()
	incoming.stream = stream
	incoming.bus = "Music"
	incoming.pitch_scale = 1.0
	var target_db := float(library.get(key, {}).get("gain_db", -12.0))
	incoming.volume_db = target_db if fade <= 0.0 else -50.0
	incoming.set_meta("key", key)
	_play_if_audible(incoming)
	if fade > 0.0:
		var in_tween := create_tween()
		in_tween.tween_property(incoming, "volume_db", target_db, fade)
		_music_tweens.append(in_tween)
	_music_active = incoming


func _stop_music(fade: float) -> void:
	_kill_music_tweens()
	for player in _music_players:
		if not is_instance_valid(player) or not player.playing:
			continue
		if fade > 0.0:
			var tween := create_tween()
			tween.tween_property(player, "volume_db", -60.0, fade)
			tween.tween_callback(player.stop)
			_music_tweens.append(tween)
		else:
			player.stop()
	_music_active = null
	_music_active_key = ""


## A track that played out leaves silence; the next one comes after the pool's gap.
func _on_music_finished(player: AudioStreamPlayer) -> void:
	if player != _music_active:
		return
	_music_active = null
	_music_active_key = ""
	var want := _music_target()
	var gap: Array = want.get("gap", [20.0, 50.0])
	_music_next_at = _now() + randf_range(float(gap[0]), float(gap[1]))


func _ensure_music_players() -> void:
	while _music_players.size() < 2:
		var player := AudioStreamPlayer.new()
		player.name = "Music%d" % _music_players.size()
		player.bus = "Music"
		player.process_mode = Node.PROCESS_MODE_ALWAYS
		player.finished.connect(_on_music_finished.bind(player))
		add_child(player)
		_music_players.append(player)


func _kill_music_tweens() -> void:
	for tween in _music_tweens:
		if tween != null and tween.is_valid():
			tween.kill()
	_music_tweens.clear()


## The track sounding right now ("" between tracks or before the world settles).
func current_music_key() -> String:
	return _music_active_key

# ------------------------------------------------------------------ compat API

func play_spell(spell_id: String) -> void:
	play_sound_at("spell_%s_cast" % spell_id, Vector3.ZERO, null, true)


func play_hit() -> void:
	play_sound_at("ui_hit", Vector3.ZERO, null, true)


func play_levelup() -> void:
	play_sound_at("ui_levelup", Vector3.ZERO, null, true)


func play_loot() -> void:
	play_sound_at("ui_loot", Vector3.ZERO, null, true)


func play_quest() -> void:
	play_sound_at("ui_quest", Vector3.ZERO, null, true)


func play_upgrade_success() -> void:
	play_sound_at("ui_upgrade_success", Vector3.ZERO, null, true)


func play_upgrade_fail() -> void:
	play_sound_at("ui_upgrade_fail", Vector3.ZERO, null, true)


func play_map_transition() -> void:
	play_sound_at("map_transition", Vector3.ZERO, null, true)


func play_equip() -> void:
	play_sound_at("ui_equip", Vector3.ZERO, null, true)


func play_unequip() -> void:
	play_sound_at("ui_unequip", Vector3.ZERO, null, true)


func play_potion() -> void:
	play_sound_at("ui_potion", Vector3.ZERO, null, true)

# ------------------------------------------------------------------ settings

## Bumped when the sound set is replaced: volumes saved against an older set
## (often turned right down because it was unpleasant) go back to the defaults once.
const SETTINGS_VERSION := 2


func _load_settings() -> void:
	if not FileAccess.file_exists(SETTINGS_PATH):
		return
	var parsed = JSON.parse_string(FileAccess.get_file_as_string(SETTINGS_PATH))
	if typeof(parsed) == TYPE_DICTIONARY and int(parsed.get("version", 1)) < SETTINGS_VERSION:
		_save_settings()
		return
	if typeof(parsed) == TYPE_DICTIONARY:
		for key in parsed.keys():
			if volumes.has(key):
				volumes[key] = clampf(float(parsed[key]), 0.0, 1.0)


func _save_settings() -> void:
	var handle := FileAccess.open(SETTINGS_PATH, FileAccess.WRITE)
	if handle == null:
		return
	var data := volumes.duplicate()
	data["version"] = SETTINGS_VERSION
	handle.store_string(JSON.stringify(data))
	handle.close()


## Presentation summary for the checks and the settings screen.
func describe() -> Dictionary:
	return {
		"sounds": library.size(),
		"audio_driver": AudioServer.get_driver_name(),
		"beds_active": _beds.size(),
		"layers": _layers.keys(),
		"buses": BUSES,
		"volumes": volumes.duplicate(),
		"zone": zone,
		"altitude": snappedf(_altitude, 0.1),
		"spatial_voices": MAX_SPATIAL_VOICES,
		"priority_keys": WARNING_PRIORITY.size(),
		"played": played_log.size(),
		"limiter": _limiter_sfx != null,
		"music_state": _music_pool_id.get_slice(":", 0),
		"music_key": _music_active_key,
		"music_playing": _music_active != null and is_instance_valid(_music_active) and _music_active.playing,
		"music_tracks": MUSIC_STATES.size(),
		"combat_music": combat_music_active(),
		"hp_fraction": _hp_frac,
		"despair": _despair,
	}
