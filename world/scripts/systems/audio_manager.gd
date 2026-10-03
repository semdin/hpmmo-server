extends Node

## AudioManager — procedural spell / UI sounds synthesized at runtime.
## No audio files needed: generates AudioStreamWAV with envelopes.

var _players: Array[AudioStreamPlayer] = []
var _cache: Dictionary = {}

func _notification(what: int) -> void:
	if what == NOTIFICATION_WM_CLOSE_REQUEST or what == NOTIFICATION_PREDELETE:
		_cache.clear()

func _ready() -> void:
	for i in range(8):
		var pl := AudioStreamPlayer.new()
		pl.bus = "Master"
		add_child(pl)
		_players.append(pl)

func _tone(freq_start: float, freq_end: float, duration: float, wave: String, volume: float) -> AudioStreamWAV:
	var key := "%s_%d_%d_%s" % [wave, int(freq_start), int(freq_end), str(duration)]
	if _cache.has(key):
		return _cache[key]
	var rate := 22050
	var frames := int(rate * duration)
	var data := PackedByteArray()
	data.resize(frames * 2)
	var phase := 0.0
	for i in range(frames):
		var t := float(i) / float(rate)
		var k := float(i) / float(frames)
		var freq := lerpf(freq_start, freq_end, k)
		phase += TAU * freq / float(rate)
		var s := 0.0
		match wave:
			"sine":
				s = sin(phase)
			"square":
				s = 1.0 if sin(phase) > 0.0 else -1.0
				s *= 0.5
			"saw":
				s = fmod(phase / TAU, 1.0) * 2.0 - 1.0
				s *= 0.6
			"noise":
				s = randf_range(-1.0, 1.0)
		# envelope: fast attack, exp decay
		var env := minf(1.0, t / 0.02) * exp(-3.0 * k)
		var v := int(clampf(s * env * volume, -1.0, 1.0) * 32767.0)
		data.encode_s16(i * 2, v)
	var stream := AudioStreamWAV.new()
	stream.format = AudioStreamWAV.FORMAT_16_BITS
	stream.mix_rate = rate
	stream.stereo = false
	stream.data = data
	_cache[key] = stream
	return stream

func _play(stream: AudioStreamWAV, pitch: float = 1.0) -> void:
	for pl in _players:
		if not pl.playing:
			pl.stream = stream
			pl.pitch_scale = pitch
			pl.play()
			return
	# all busy: steal first
	_players[0].stream = stream
	_players[0].pitch_scale = pitch
	_players[0].play()

func play_spell(spell_id: String) -> void:
	match spell_id:
		"basic_cast":
			_play(_tone(880, 440, 0.18, "sine", 0.5))
		"stupefy":
			_play(_tone(300, 90, 0.35, "saw", 0.6))
		"incendio":
			_play(_tone(200, 900, 0.4, "noise", 0.45))
			_play(_tone(150, 600, 0.4, "saw", 0.3))
		"bombarda":
			_play(_tone(120, 40, 0.6, "noise", 0.8))
			_play(_tone(90, 35, 0.6, "sine", 0.8))
		"expelliarmus":
			_play(_tone(1200, 300, 0.3, "square", 0.35))
		"protego":
			_play(_tone(400, 900, 0.45, "sine", 0.5))
		"ultimate":
			_play(_tone(150, 1400, 0.8, "saw", 0.6))
			_play(_tone(1200, 200, 0.8, "sine", 0.4))
		_:
			_play(_tone(600, 300, 0.2, "sine", 0.4))

func play_hit() -> void:
	_play(_tone(250, 120, 0.15, "noise", 0.4), randf_range(0.9, 1.15))

func play_levelup() -> void:
	_play(_tone(440, 880, 0.5, "sine", 0.55))
	_play(_tone(660, 1320, 0.6, "sine", 0.4))

func play_loot() -> void:
	_play(_tone(900, 1500, 0.18, "sine", 0.45))

func play_upgrade_success() -> void:
	_play(_tone(500, 1500, 0.5, "sine", 0.55))

func play_upgrade_fail() -> void:
	_play(_tone(400, 120, 0.5, "saw", 0.5))

func play_quest() -> void:
	_play(_tone(523, 784, 0.4, "sine", 0.5))
