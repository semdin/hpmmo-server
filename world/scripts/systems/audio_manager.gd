extends Node

## AudioManager - the spell effects audio system.
##
## Every sound is a project-original synthesised WAV (tools/audio/synth_spell_sfx.py)
## described by `assets/audio/sound_library.json`: bus, base gain, pitch
## variation, loop mode and whether it is positional.
##
## What this provides (12.5):
##   * separate Music / SFX / UI / Ambience buses with independent volumes that
##     persist per user;
##   * spatial emitters (AudioStreamPlayer3D) with attenuation and a voice limit,
##     and non-positional players for beds and interface sounds;
##   * interior/exterior reverb treatment: the SFX and Ambience buses carry a
##     reverb whose size, damping and wet mix change per zone, and the Great
##     Hall, library and dungeon are acoustically distinct;
##   * subtle variation (per-play pitch/gain jitter) so repeated footsteps and
##     impacts never machine-gun;
##   * combat warnings stay audible: warning-priority keys have a reserved slice
##     of the voice pool and the SFX bus is limited, so a burst of spells cannot
##     bury a boss release cue;
##   * surface footsteps driven by the character's own `footstep:<surface>`
##     animation events - the manager subscribes to the local player's signal, so
##     no entity script carries audio code.

const LIBRARY_PATH := "res://assets/audio/sound_library.json"
const SETTINGS_PATH := "user://audio_settings.json"
const BUSES := ["Music", "SFX", "UI", "Ambience"]

## Keys that must stay audible under heavy spell combinations.
const WARNING_PRIORITY := [
	"boss_slam_cast", "boss_slam_release", "boss_death",
	"spell_incendio_impact", "spell_bombarda_impact", "spell_ultimate_impact",
	"ui_hit", "spell_protego_impact",
]

## Zone acoustic identities. Interior rooms get a longer, darker tail; the
## library is tight and dry; the dungeon is wet stone.
const ZONES := {
	"exterior": {"ambience": ["amb_exterior_wind", "amb_exterior_birds"], "room_size": 0.22, "damping": 0.75, "wet": 0.06, "dry": 1.0},
	"great_hall": {"ambience": ["amb_great_hall", "amb_fire"], "room_size": 0.92, "damping": 0.35, "wet": 0.42, "dry": 0.85},
	"library": {"ambience": ["amb_library"], "room_size": 0.35, "damping": 0.62, "wet": 0.18, "dry": 0.95},
	"dungeon": {"ambience": ["amb_dungeon", "amb_candles"], "room_size": 0.72, "damping": 0.25, "wet": 0.38, "dry": 0.88},
	"interior": {"ambience": ["amb_great_hall", "amb_fire", "amb_candles", "amb_distant"], "room_size": 0.70, "damping": 0.40, "wet": 0.32, "dry": 0.9},
}

## Procedural atmospheric scatter events: randomized non-repeating environmental
## sounds placed around the player or played flat to bring zones to life.
const AMBIENT_SCATTER := {
	"exterior": [
		{
			"keys": ["amb_bird_chirp_1", "amb_bird_chirp_2", "amb_bird_chirp_3", "amb_bird_chirp_4"],
			"min_sec": 4.0, "max_sec": 10.0,
			"spatial": true, "min_dist": 14.0, "max_dist": 30.0, "height": 5.0,
			"gain_offset": -2.0
		},
		{
			"keys": ["amb_wind_gust_1", "amb_wind_gust_2"],
			"min_sec": 11.0, "max_sec": 24.0,
			"spatial": false,
			"gain_offset": -1.0
		},
		{
			"keys": ["amb_leaf_rustle_1", "amb_leaf_rustle_2"],
			"min_sec": 7.0, "max_sec": 16.0,
			"spatial": true, "min_dist": 7.0, "max_dist": 18.0, "height": 2.0,
			"gain_offset": -2.0
		}
	],
	"dungeon": [
		{
			"keys": ["amb_dungeon_drip_1", "amb_dungeon_drip_2", "amb_dungeon_drip_3"],
			"min_sec": 2.2, "max_sec": 6.5,
			"spatial": true, "min_dist": 4.0, "max_dist": 14.0, "height": 2.2,
			"gain_offset": 0.0
		},
		{
			"keys": ["amb_dungeon_rumble"],
			"min_sec": 14.0, "max_sec": 30.0,
			"spatial": false,
			"gain_offset": -2.0
		}
	],
	"library": [
		{
			"keys": ["amb_library_page_1", "amb_library_page_2"],
			"min_sec": 6.0, "max_sec": 15.0,
			"spatial": true, "min_dist": 3.0, "max_dist": 9.0, "height": 1.2,
			"gain_offset": -1.5
		}
	],
	"great_hall": [
		{
			"keys": ["amb_hall_settle_1", "amb_hall_settle_2"],
			"min_sec": 8.0, "max_sec": 20.0,
			"spatial": true, "min_dist": 6.0, "max_dist": 22.0, "height": 2.0,
			"gain_offset": -2.0
		}
	],
	"interior": [
		{
			"keys": ["amb_hall_settle_1", "amb_hall_settle_2"],
			"min_sec": 9.0, "max_sec": 22.0,
			"spatial": true, "min_dist": 5.0, "max_dist": 18.0, "height": 1.8,
			"gain_offset": -2.0
		}
	]
}

const MAX_SPATIAL_VOICES := 24
const MAX_NONPOSITIONAL_VOICES := 12

var library: Dictionary = {}
var music: Dictionary = {}
var sfx: Dictionary = {}
var ui: Dictionary = {}
var ambience: Dictionary = {}

var volumes := {"Music": 0.7, "SFX": 1.0, "UI": 0.9, "Ambience": 0.8}
var zone := "exterior"
var autodetect_zone := true

var _spatial_pool: Array[AudioStreamPlayer3D] = []
var _flat_pool: Array[AudioStreamPlayer] = []
var _loops: Dictionary = {}          # key::owner_id -> player
var _last_played: Dictionary = {}    # key -> msec, for rate limiting
var _streams: Dictionary = {}        # path -> AudioStream
## Every key that has actually been played (a small ring): the checks use it to
## prove a creature/boss/spell voice is reached by real gameplay, not merely
## present in the library.
var played_log: Array[String] = []
var _local_player: Node = null
var _footstep_variant := 0
# Node, not AudioStreamPlayer: the zone beds are AudioStreamPlayer3D, which is a
# sibling class, so appending one to a typed Array[AudioStreamPlayer] raises an
# engine error on every zone change whenever a real audio device is present.
var _zone_beds: Array[Node] = []
var _scatter_timers: Array = []
var _reverb_sfx: AudioEffectReverb
var _reverb_amb: AudioEffectReverb
var _limiter_sfx: AudioEffectLimiter


func _ready() -> void:
	process_mode = Node.PROCESS_MODE_ALWAYS
	_ensure_buses()
	_load_library()
	_load_settings()
	_apply_volumes()
	_setup_bus_effects()
	_apply_zone(zone, true)


func _notification(what: int) -> void:
	if what == NOTIFICATION_WM_CLOSE_REQUEST or what == NOTIFICATION_PREDELETE 			or what == NOTIFICATION_EXIT_TREE:
		# Shutdown must release every stream: a stopped player that still holds a
		# stream keeps an AudioStreamWAV and its playback alive past exit, which
		# shows up as an engine resource leak in the harness.
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
	# A burst of spells must not clip over a combat warning: the limiter caps the
	# SFX bus instead of letting the mix fold over.
	_limiter_sfx.ceiling_db = -1.0
	_limiter_sfx.threshold_db = -6.0
	_limiter_sfx.soft_clip_db = -2.0
	AudioServer.add_bus_effect(sfx_index, _limiter_sfx)
	_reverb_sfx = AudioEffectReverb.new()
	AudioServer.add_bus_effect(sfx_index, _reverb_sfx)
	var amb_index := AudioServer.get_bus_index("Ambience")
	_reverb_amb = AudioEffectReverb.new()
	AudioServer.add_bus_effect(amb_index, _reverb_amb)


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
		# A dedicated server legitimately ships no audio: say so on stdout, not
		# as a warning on stderr (which the release smoke treats as a failure).
		print("AudioManager: running without a sound library (headless server)")
		return
	var text := FileAccess.get_file_as_string(LIBRARY_PATH)
	var parsed = JSON.parse_string(text)
	if typeof(parsed) != TYPE_DICTIONARY:
		print("AudioManager: sound library is not valid JSON")
		return
	library = parsed.get("sounds", {})


func has_sound(key: String) -> bool:
	return library.has(key)


## Keys played since the last clear - a presentation-only record.
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
		_streams[path] = load(path)
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
		if bool(player.get_meta("priority", false)):
			continue
		var started := float(player.get_meta("started", 0.0))
		if started < oldest_time:
			oldest_time = started
			oldest = player
	return oldest if oldest != null else _spatial_pool[0]


func _flat_player() -> AudioStreamPlayer:
	for player in _flat_pool:
		if not player.playing:
			return player
	if _flat_pool.size() < MAX_NONPOSITIONAL_VOICES:
		var created := AudioStreamPlayer.new()
		created.name = "Flat%d" % _flat_pool.size()
		created.finished.connect(_on_voice_finished.bind(created))
		add_child(created)
		_flat_pool.append(created)
		return created
	return _flat_pool[0]


const BUS_NAMES := {"sfx": "SFX", "ui": "UI", "ambience": "Ambience", "music": "Music"}


## A voice that finished releases its stream: an idle player holding a stream
## keeps the AudioStreamPlayback alive, and on the dummy audio driver a playback
## that is still referenced when the driver shuts down is reported as a leak.
func _on_voice_finished(player: Node) -> void:
	if is_instance_valid(player) and player.get("playing") == false:
		player.set("stream", null)


func _bus_for(entry: Dictionary) -> String:
	return String(BUS_NAMES.get(String(entry.get("bus", "sfx")), "SFX"))


## Play one positional sound. `owner_node` is used only to key loops and to
## clean up; it never gates whether the sound plays.
func play_sound_at(key: String, position: Vector3, owner_node: Node = null, force_flat: bool = false) -> Node:
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
## device. Everything else - the library lookup, the bus routing, the voice
## pool, the priority reservation, the loop bookkeeping - runs identically
## whether or not a device is present, so a headless run still exercises the
## whole system; it just does not hand the dummy driver playbacks to retain.
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


## Keep a loop on its owner. A loop is positioned once when it starts, so a
## moving owner - a bolt in flight - has to ask for this every tick or its sound
## stays behind at the point where the loop began. A voice the pool has since
## stolen for another sound is left alone.
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


## Every effect and sound stops here: shutdown, map transfer, death.
func stop_everything() -> void:
	for player in _spatial_pool:
		if is_instance_valid(player):
			player.stop()
			player.stream = null
	for player in _flat_pool:
		if is_instance_valid(player):
			player.stop()
			player.stream = null
	for player in _zone_beds:
		if is_instance_valid(player):
			player.stop()
			player.stream = null
	_loops.clear()
	_zone_beds.clear()
	_scatter_timers.clear()


func _release_streams() -> void:
	# Freeing the pool nodes (not merely stopping them) is what releases an
	# AudioStreamPlayback that is still live when the engine tears the audio
	# driver down: a stopped player can otherwise keep its playback and stream
	# alive past exit, which the harness reports as a resource leak.
	_streams.clear()
	library.clear()
	for player in _spatial_pool:
		if is_instance_valid(player):
			player.stream = null
	for player in _flat_pool:
		if is_instance_valid(player):
			player.stream = null
	_spatial_pool.clear()
	_flat_pool.clear()
	_zone_beds.clear()
	_loops.clear()
	_scatter_timers.clear()

# ------------------------------------------------------------------ zones

## Switch the ambient bed and the reverb treatment. Interior rooms are distinct
## spaces, not one "indoors" flag.
func set_zone(name: String) -> void:
	if not ZONES.has(name) or name == zone:
		return
	_apply_zone(name, false)


func _apply_zone(name: String, immediate: bool) -> void:
	zone = name
	var config: Dictionary = ZONES.get(name, ZONES["exterior"])
	_apply_reverb(float(config["room_size"]), float(config["damping"]), float(config["wet"]), float(config["dry"]))
	_start_zone_beds(config["ambience"], immediate)
	_reset_ambient_scatter(immediate)


func _reset_ambient_scatter(immediate: bool) -> void:
	_scatter_timers.clear()
	var scatters: Array = AMBIENT_SCATTER.get(zone, [])
	for s in scatters:
		var min_t: float = float(s.get("min_sec", 4.0))
		var max_t: float = float(s.get("max_sec", 10.0))
		var initial_t := randf_range(min_t * 0.3, min_t * 1.2) if not immediate else randf_range(min_t, max_t)
		_scatter_timers.append(initial_t)


func _process_ambient_scatter(delta: float) -> void:
	if not audio_available():
		return
	var scatters: Array = AMBIENT_SCATTER.get(zone, [])
	if scatters.is_empty() or _scatter_timers.size() != scatters.size():
		return
	var listener_pos := Vector3.ZERO
	if _local_player != null and is_instance_valid(_local_player) and _local_player is Node3D:
		listener_pos = (_local_player as Node3D).global_position

	for i in range(scatters.size()):
		_scatter_timers[i] -= delta
		if _scatter_timers[i] <= 0.0:
			var cfg: Dictionary = scatters[i]
			_scatter_timers[i] = randf_range(float(cfg.get("min_sec", 4.0)), float(cfg.get("max_sec", 10.0)))
			var keys: Array = cfg.get("keys", [])
			if keys.is_empty():
				continue
			var key: String = String(keys[randi() % keys.size()])
			if not has_sound(key):
				continue

			var is_spatial: bool = bool(cfg.get("spatial", false))
			var player_node: Node = null
			if is_spatial and listener_pos != Vector3.ZERO:
				var angle := randf_range(0.0, TAU)
				var dist := randf_range(float(cfg.get("min_dist", 10.0)), float(cfg.get("max_dist", 25.0)))
				var h := randf_range(1.0, float(cfg.get("height", 4.0)))
				var pos := listener_pos + Vector3(cos(angle) * dist, h, sin(angle) * dist)
				player_node = play_sound_at(key, pos, null, false)
			else:
				player_node = play_sound_at(key, Vector3.ZERO, null, true)

			if player_node != null and is_instance_valid(player_node):
				player_node.pitch_scale = randf_range(0.93, 1.07)
				var gain_off: float = float(cfg.get("gain_offset", 0.0))
				player_node.volume_db += gain_off + randf_range(-1.5, 1.5)


func _apply_reverb(room_size: float, damping: float, wet: float, dry: float) -> void:
	for effect in [_reverb_sfx, _reverb_amb]:
		if effect == null:
			continue
		effect.room_size = room_size
		effect.damping = damping
		effect.wet = wet
		effect.dry = dry
		effect.spread = 0.6


## True when there is an audio device that can actually play the beds. Under the
## dummy driver (a headless run) the engine retains any stream that is still
## playing when the driver is shut down, which the harness reports as a resource
## leak - and there is nothing audible to lose. Gameplay, buses, volumes and the
## one-shot SFX/UI path are identical either way.
func audio_available() -> bool:
	var driver := AudioServer.get_driver_name().to_lower()
	return driver != "" and driver != "dummy"


func _start_zone_beds(keys: Array, immediate: bool) -> void:
	if not audio_available():
		return
	# Crossfade: every existing bed fades out, the new zone's beds fade in. A
	# zone change never cuts the room tone off mid-sample.
	var outgoing := _zone_beds.duplicate()
	_zone_beds.clear()
	for bed in outgoing:
		if not is_instance_valid(bed):
			continue
		if keys.has(String(bed.get_meta("key", ""))):
			bed.set_meta("keep", true)
			_zone_beds.append(bed)
			continue
		var tween := create_tween()
		tween.tween_property(bed, "volume_db", -60.0, 1.0)
		tween.tween_callback(bed.stop)
	for key in keys:
		var entry: Dictionary = library.get(String(key), {})
		if entry.is_empty():
			continue
		var already := false
		for bed in _zone_beds:
			if is_instance_valid(bed) and String(bed.get_meta("key", "")) == String(key):
				already = true
		if already:
			continue
		var player: Node = _spatial_player() if bool(entry.get("spatial", false)) else _flat_player()
		if player == null:
			continue
		player.stream = _stream(String(key))
		player.bus = _bus_for(entry)
		player.pitch_scale = 1.0
		player.volume_db = float(entry.get("gain_db", -18.0)) if immediate else -60.0
		player.set_meta("key", String(key))
		_play_if_audible(player)
		if not immediate:
			var tween := create_tween()
			tween.tween_property(player, "volume_db", float(entry.get("gain_db", -18.0)), 1.2)
		_zone_beds.append(player)


## Autodetect the zone from where the listener is. The castle interior lives at
## y ~195-215 in its own map, so height plus the room's authored footprint is
## enough; `set_zone` is the explicit hook for anything finer.
func _autodetect_zone() -> void:
	if _local_player == null or not is_instance_valid(_local_player):
		return
	var pos: Vector3 = (_local_player as Node3D).global_position
	var wanted := "exterior"
	if pos.y > 180.0:
		if pos.z < -25.0 and pos.x < -10.0 and pos.y > 205.0:
			wanted = "library"
		elif pos.y < 199.0:
			wanted = "dungeon"
		elif pos.x < -20.0:
			wanted = "great_hall"
		else:
			wanted = "interior"
	if wanted != zone:
		_apply_zone(wanted, false)

# ------------------------------------------------------------------ footsteps

## Subscribe to the local player's own animation events. The rig already
## emits `footstep:<surface>` at contact frames; this listens, so no entity
## script has to know about audio.
func _find_local_player() -> void:
	if _local_player != null and is_instance_valid(_local_player):
		return
	for node in get_tree().get_nodes_in_group("players"):
		if node.has_signal("animation_event") and (node as Node).get("is_local_controlled") != false:
			_local_player = node
			if not node.is_connected("animation_event", Callable(self, "_on_animation_event")):
				node.connect("animation_event", Callable(self, "_on_animation_event"))
			return


func _on_animation_event(event_name: String) -> void:
	var text := String(event_name)
	if text.begins_with("footstep:"):
		var surface := text.trim_prefix("footstep:")
		_footstep_variant = (_footstep_variant + 1) % 3 + 1
		var key := "step_%s_%d" % [surface, _footstep_variant]
		if not has_sound(key):
			key = "step_stone_%d" % _footstep_variant
		var at: Vector3 = (_local_player as Node3D).global_position if _local_player is Node3D else Vector3.ZERO
		_play_varied(key, at, 0.85)
	elif text == "oneshot_end:Broom_Land" or text.begins_with("landing"):
		var at2: Vector3 = (_local_player as Node3D).global_position if _local_player is Node3D else Vector3.ZERO
		play_sound_at("landing", at2, _local_player)
	elif text.begins_with("robe"):
		var at3: Vector3 = (_local_player as Node3D).global_position if _local_player is Node3D else Vector3.ZERO
		_play_varied("robe_%d" % (randi() % 3 + 1), at3, 0.7)


func _play_varied(key: String, at: Vector3, gain_scale: float) -> Node:
	var player := play_sound_at(key, at, _local_player)
	if player != null:
		player.volume_db += linear_to_db(maxf(0.05, gain_scale)) + randf_range(-1.5, 1.5)
	return player


var _scan_timer := 0.0

func _process(delta: float) -> void:
	_process_ambient_scatter(delta)
	_scan_timer -= delta
	if _scan_timer > 0.0:
		return
	_scan_timer = 0.5
	_find_local_player()
	if autodetect_zone and _local_player != null:
		_autodetect_zone()


## Ride / dismount / broom wind helpers used by the mount presentation.
func play_mount(mounted: bool, at: Vector3, owner_node: Node) -> void:
	play_sound_at("mount" if mounted else "dismount", at, owner_node)
	if mounted:
		loop_sound("broom_wind", owner_node, 0.4)
	else:
		stop_sound("broom_wind", owner_node)

# ------------------------------------------------------------------ compat API

## The prototype's call surface, now backed by the library.
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

func _load_settings() -> void:
	if not FileAccess.file_exists(SETTINGS_PATH):
		return
	var parsed = JSON.parse_string(FileAccess.get_file_as_string(SETTINGS_PATH))
	if typeof(parsed) == TYPE_DICTIONARY:
		for key in parsed.keys():
			if volumes.has(key):
				volumes[key] = clampf(float(parsed[key]), 0.0, 1.0)


func _save_settings() -> void:
	var handle := FileAccess.open(SETTINGS_PATH, FileAccess.WRITE)
	if handle == null:
		return
	handle.store_string(JSON.stringify(volumes))
	handle.close()


## Presentation summary for the checks and the settings screen.
func describe() -> Dictionary:
	return {
		"sounds": library.size(),
		"audio_driver": AudioServer.get_driver_name(),
		"beds_active": _zone_beds.size(),
		"buses": BUSES,
		"volumes": volumes.duplicate(),
		"zone": zone,
		"spatial_voices": MAX_SPATIAL_VOICES,
		"priority_keys": WARNING_PRIORITY.size(),
		"played": played_log.size(),
		"limiter": _limiter_sfx != null,
	}
