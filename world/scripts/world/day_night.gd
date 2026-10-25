extends Node
class_name DayNight

## Day, night and weather on the grounds, and the character fill everywhere.
##
## Time of day follows the server clock in GMT+3 (the players' time zone),
## read from the machine's UTC clock so every client agrees without a protocol
## field. Settings > General > Time of day can hold it at day or night instead
## (GameSettings.time_of_day: "system" or a held prayer time - "dawn", "noon",
## "afternoon", "sunset", "night").
##
## The day has its five prayer-time faces and the hours between blend them:
## sabah (dawn, pink and cold), öğle (noon, high white sun), ikindi (afternoon,
## warm gold), akşam (sunset, orange and red, then the blue hour) and yatsı
## (night, moon and stars). The sun crosses the sky from east to west between
## sunrise and sunset, the moon by night; each light fades out at the horizon,
## so the hand-over is never seen. The sky is assets/shaders/
## sky_day_night.gdshader: gradient, sun or moon disc, drifting clouds, stars.
##
## Weather is the server's (`SimAuthority.weather`, a GA's `/ga rain on`):
## rain thickens the clouds, darkens the light, thickens the fog and brings
## falling streaks round the camera and a rain loop.
##
## Only the outdoor environment is touched: inside a map with its own
## atmosphere (the castle, the caverns - the environment then carries
## `outdoor_ambient`) the light and the rain stop, and the outdoor values come
## back on the way out.
##
## Character fill: the shadowless light on the camera that lights only the
## character layer (HeroAppearance.add_character_fill / CHARACTER_LAYER, which
## creatures join in mob_base._enter_tree) is driven here by the hour, so dark
## bodies in a cliff's shadow and at night stay readable without lifting the
## whole scene. Presentation only - never built on a dedicated server.

const QualityPreset = preload("res://scripts/world/quality_preset.gd")
const SKY_SHADER := preload("res://assets/shaders/sky_day_night.gdshader")
const RAIN_SOUND := "res://assets/audio/ambience/rain.wav"
const UTC_OFFSET_HOURS := 3.0
const UPDATE_PERIOD := 0.25
## Sun up and down (GMT+3, the year's middle); the moon has the night.
const SUNRISE := 5.9
const SUNSET := 19.4
const SUN_MAX_ELEVATION := 62.0
const MOON_MAX_ELEVATION := 48.0

# i18n-begin
const CHOICES := {"system": "Server time (GMT+3)", "dawn": "Always dawn (Sabah)", "noon": "Always noon (Öğle)",
	"afternoon": "Always afternoon (İkindi)", "sunset": "Always sunset (Akşam)", "night": "Always night (Yatsı)"}
# i18n-end
## The hour each held choice shows: the sun just up, high, low and gold, on
## the horizon, and the moon.
const HELD_HOURS := {"dawn": 6.2, "noon": 12.5, "afternoon": 15.8, "sunset": 18.7, "night": 0.5}

const LOOKS := {
	"dawn": {
		"sun_color": Color(1.0, 0.70, 0.55), "sun_energy": 0.62,
		"sky_top": Color(0.20, 0.25, 0.44), "sky_horizon": Color(0.95, 0.64, 0.60),
		"ground_bottom": Color(0.14, 0.14, 0.17), "ground_horizon": Color(0.52, 0.44, 0.47),
		"ambient_color": Color(0.86, 0.76, 0.82), "ambient_sky": 0.8, "ambient_energy": 0.62,
		"fog_color": Color(0.78, 0.66, 0.68), "exposure": 1.05, "stars": 0.25,
		"cloud_lit": Color(1.0, 0.74, 0.70), "cloud_shade": Color(0.44, 0.38, 0.50),
		"fill_energy": 0.65, "fill_color": Color(1.0, 0.88, 0.86), "torch": 1.3,
	},
	"morning": {
		"sun_color": Color(1.0, 0.93, 0.82), "sun_energy": 0.9,
		"sky_top": Color(0.25, 0.39, 0.57), "sky_horizon": Color(0.66, 0.73, 0.81),
		"ground_bottom": Color(0.20, 0.23, 0.22), "ground_horizon": Color(0.47, 0.53, 0.57),
		"ambient_color": Color(1, 1, 1), "ambient_sky": 1.0, "ambient_energy": 0.62,
		"fog_color": Color(0.68, 0.75, 0.82), "exposure": 1.0, "stars": 0.0,
		"cloud_lit": Color(1.0, 0.98, 0.95), "cloud_shade": Color(0.60, 0.66, 0.74),
		"fill_energy": 0.55, "fill_color": Color(1.0, 0.97, 0.94), "torch": 1.0,
	},
	"noon": {
		"sun_color": Color(1.0, 0.97, 0.91), "sun_energy": 1.0,
		"sky_top": Color(0.22, 0.36, 0.54), "sky_horizon": Color(0.60, 0.68, 0.76),
		"ground_bottom": Color(0.20, 0.23, 0.22), "ground_horizon": Color(0.46, 0.52, 0.55),
		"ambient_color": Color(1, 1, 1), "ambient_sky": 1.0, "ambient_energy": 0.62,
		"fog_color": Color(0.66, 0.73, 0.80), "exposure": 1.0, "stars": 0.0,
		"cloud_lit": Color(1.0, 1.0, 1.0), "cloud_shade": Color(0.62, 0.67, 0.74),
		"fill_energy": 0.55, "fill_color": Color(1.0, 0.97, 0.92), "torch": 1.0,
	},
	"afternoon": {
		"sun_color": Color(1.0, 0.86, 0.64), "sun_energy": 0.92,
		"sky_top": Color(0.24, 0.35, 0.52), "sky_horizon": Color(0.78, 0.73, 0.64),
		"ground_bottom": Color(0.20, 0.21, 0.19), "ground_horizon": Color(0.52, 0.50, 0.47),
		"ambient_color": Color(1.0, 0.95, 0.88), "ambient_sky": 0.92, "ambient_energy": 0.62,
		"fog_color": Color(0.74, 0.72, 0.68), "exposure": 1.0, "stars": 0.0,
		"cloud_lit": Color(1.0, 0.93, 0.80), "cloud_shade": Color(0.60, 0.58, 0.60),
		"fill_energy": 0.58, "fill_color": Color(1.0, 0.94, 0.85), "torch": 1.05,
	},
	"sunset": {
		"sun_color": Color(1.0, 0.55, 0.30), "sun_energy": 0.75,
		"sky_top": Color(0.20, 0.21, 0.38), "sky_horizon": Color(0.98, 0.52, 0.32),
		"ground_bottom": Color(0.15, 0.13, 0.14), "ground_horizon": Color(0.55, 0.38, 0.32),
		"ambient_color": Color(0.92, 0.70, 0.60), "ambient_sky": 0.8, "ambient_energy": 0.62,
		"fog_color": Color(0.80, 0.56, 0.46), "exposure": 1.02, "stars": 0.1,
		"cloud_lit": Color(1.0, 0.60, 0.40), "cloud_shade": Color(0.42, 0.30, 0.38),
		"fill_energy": 0.72, "fill_color": Color(1.0, 0.84, 0.74), "torch": 1.3,
	},
	"blue_hour": {
		"sun_color": Color(0.70, 0.70, 0.90), "sun_energy": 0.4,
		"sky_top": Color(0.07, 0.10, 0.24), "sky_horizon": Color(0.34, 0.30, 0.46),
		"ground_bottom": Color(0.05, 0.05, 0.07), "ground_horizon": Color(0.20, 0.19, 0.26),
		"ambient_color": Color(0.52, 0.52, 0.72), "ambient_sky": 0.5, "ambient_energy": 0.85,
		"fog_color": Color(0.24, 0.24, 0.34), "exposure": 1.14, "stars": 0.55,
		"cloud_lit": Color(0.46, 0.42, 0.58), "cloud_shade": Color(0.16, 0.16, 0.24),
		"fill_energy": 1.1, "fill_color": Color(0.84, 0.84, 1.0), "torch": 1.45,
	},
	"night": {
		"sun_color": Color(0.62, 0.72, 1.0), "sun_energy": 0.5,
		"sky_top": Color(0.012, 0.02, 0.05), "sky_horizon": Color(0.07, 0.10, 0.17),
		"ground_bottom": Color(0.02, 0.025, 0.03), "ground_horizon": Color(0.05, 0.07, 0.10),
		"ambient_color": Color(0.38, 0.46, 0.68), "ambient_sky": 0.35, "ambient_energy": 1.1,
		"fog_color": Color(0.09, 0.12, 0.20), "exposure": 1.22, "stars": 1.0,
		"cloud_lit": Color(0.20, 0.23, 0.32), "cloud_shade": Color(0.05, 0.06, 0.09),
		"fill_energy": 1.45, "fill_color": Color(0.74, 0.82, 1.0), "torch": 1.55,
	},
}
## (hour, look): the hours between two keys blend them.
const KEYS := [[0.0, "night"], [4.6, "night"], [5.6, "dawn"], [7.2, "morning"], [12.0, "noon"],
	[15.3, "afternoon"], [18.3, "sunset"], [19.4, "blue_hour"], [20.6, "night"], [24.0, "night"]]

var world: Node3D = null
## The look on screen now (eases towards the hour's look).
var current: Dictionary = {}
var night_amount := 0.0
## 0..1, eased towards the server's weather.
var rain_amount := 0.0
var _timer := 0.0
var _sky: ShaderMaterial = null
var _rain: GPUParticles3D = null
var _rain_sound: AudioStreamPlayer = null

static func create(p_world: Node3D) -> DayNight:
	var node := DayNight.new()
	node.name = "DayNight"
	node.world = p_world
	p_world.add_child(node)
	return node

func _ready() -> void:
	if NetworkManager.is_dedicated_server or DisplayServer.get_name() == "headless":
		set_process(false)
		return
	current = look_at_hour(hour()).duplicate()
	rain_amount = 1.0 if _raining() else 0.0
	_apply()

## The hour shown, 0-24 (fractional): GMT+3 from the UTC clock, or the setting's.
static func hour() -> float:
	# Captures pin an hour: --hour=21.5
	for arg in OS.get_cmdline_user_args():
		if arg.begins_with("--hour="):
			return fposmod(float(arg.trim_prefix("--hour=")), 24.0)
	var held := String(GameSettings.instance().time_of_day)
	if HELD_HOURS.has(held):
		return float(HELD_HOURS[held])
	return fposmod(Time.get_unix_time_from_system() / 3600.0 + UTC_OFFSET_HOURS, 24.0)

static func look_at_hour(h: float) -> Dictionary:
	for i in range(KEYS.size() - 1):
		var a: Array = KEYS[i]
		var b: Array = KEYS[i + 1]
		if h >= float(a[0]) and h <= float(b[0]):
			var t := 0.0 if float(b[0]) == float(a[0]) else (h - float(a[0])) / (float(b[0]) - float(a[0]))
			return _blend(LOOKS[String(a[1])], LOOKS[String(b[1])], smoothstep(0.0, 1.0, t))
	return (LOOKS["noon"] as Dictionary).duplicate()

static func _blend(a: Dictionary, b: Dictionary, t: float) -> Dictionary:
	var out := {}
	for key in a:
		var va = a[key]
		out[key] = (va as Color).lerp(b[key], t) if va is Color else lerp(va, b[key], t)
	return out

## Where the sky light is at hour `h`: {rot (degrees for the DirectionalLight),
## elevation (degrees), moon (bool)}. The sun rises in the east and sets in the
## west; the moon takes the opposite arc through the night.
static func sky_light(h: float) -> Dictionary:
	var moon := h < SUNRISE or h > SUNSET
	var t := 0.0
	var max_elev := SUN_MAX_ELEVATION
	if moon:
		var night_len := 24.0 - SUNSET + SUNRISE
		t = fposmod(h - SUNSET, 24.0) / night_len
		max_elev = MOON_MAX_ELEVATION
	else:
		t = (h - SUNRISE) / (SUNSET - SUNRISE)
	var elevation := sin(PI * clampf(t, 0.0, 1.0)) * max_elev
	var yaw := lerpf(-100.0, 100.0, t) + (180.0 if moon else 0.0)
	return {"rot": Vector3(-maxf(elevation, 4.0), yaw, 0.0), "elevation": elevation, "moon": moon}

func _raining() -> bool:
	if "--rain" in OS.get_cmdline_user_args():
		return true   # captures
	return bool((SimAuthority.weather as Dictionary).get("rain", false))

func _process(delta: float) -> void:
	_follow_camera()
	_timer -= delta
	if _timer > 0.0:
		return
	_timer = UPDATE_PERIOD
	var target := look_at_hour(hour())
	# Ease so a settings switch fades instead of snapping (~2 s).
	current = _blend(current, target, 0.3)
	rain_amount = move_toward(rain_amount, 1.0 if _raining() else 0.0, UPDATE_PERIOD / 6.0)
	_apply()

## The camera's character fill (the local player's camera, or whichever camera
## draws the world).
func _fill() -> DirectionalLight3D:
	var camera := get_viewport().get_camera_3d()
	if camera == null:
		return null
	var fill := camera.get_node_or_null("CharacterFill") as DirectionalLight3D
	if fill == null:
		fill = HeroAppearance.add_character_fill(camera)
	return fill

func _outdoors(env: Environment) -> bool:
	return env != null and not env.has_meta("outdoor_ambient")

func _apply() -> void:
	night_amount = clampf(float(current.get("stars", 0.0)), 0.0, 1.0)
	var fill := _fill()
	if fill != null:
		fill.light_energy = float(current.fill_energy) * (1.0 + rain_amount * 0.15)
		fill.light_color = current.fill_color
	var env_node := world.get_node_or_null("WorldEnvironment") as WorldEnvironment
	var env := env_node.environment if env_node != null else null
	var outside := _outdoors(env)
	_update_rain(outside)
	if not outside:
		return   # inside: the map's own atmosphere holds
	var wet := rain_amount
	var grey := Color(0.36, 0.39, 0.43)
	env.ambient_light_source = Environment.AMBIENT_SOURCE_SKY
	env.ambient_light_sky_contribution = float(current.ambient_sky)
	env.ambient_light_color = (current.ambient_color as Color).lerp(grey * 1.6, wet * 0.5)
	env.ambient_light_energy = float(current.ambient_energy) * (1.0 - wet * 0.15)
	env.fog_light_color = (current.fog_color as Color).lerp((current.fog_color as Color).lerp(grey, 0.6), wet)
	var preset := QualityPreset.settings()
	env.tonemap_exposure = float(preset.get("tonemap_exposure", 0.86)) * float(current.exposure)
	if env.fog_enabled:
		env.fog_density = float(preset.get("fog_density", 0.00032)) * (1.0 + wet * 2.5)
	_update_sky(env, wet, grey)
	var sun := world.get_node_or_null("DirectionalLight3D") as DirectionalLight3D
	if sun != null:
		var light := sky_light(hour())
		sun.rotation_degrees = light.rot
		# Each light fades out over its last degrees above the horizon, so the
		# sun-to-moon hand-over happens in the dark of the blue hour.
		var fade := smoothstep(0.0, 9.0, float(light.elevation))
		sun.light_color = current.sun_color
		sun.light_energy = float(current.sun_energy) * fade * (1.0 - wet * 0.55)
	var torch := float(current.torch) * (1.0 + wet * 0.2)
	for node in get_tree().get_nodes_in_group("torch_lights"):
		if node is Light3D:
			if not node.has_meta("day_energy"):
				node.set_meta("day_energy", (node as Light3D).light_energy)
			(node as Light3D).light_energy = float(node.get_meta("day_energy")) * torch

func _update_sky(env: Environment, wet: float, grey: Color) -> void:
	if env.sky == null:
		env.sky = Sky.new()
	if _sky == null:
		_sky = ShaderMaterial.new()
		_sky.shader = SKY_SHADER
	if env.sky.sky_material != _sky:
		# grounds_builder authors a ProceduralSkyMaterial; this one moves.
		env.sky.sky_material = _sky
		env.sky.process_mode = Sky.PROCESS_MODE_INCREMENTAL
		env.sky.radiance_size = Sky.RADIANCE_SIZE_64
	var storm := grey * (0.55 + 0.45 * (1.0 - night_amount))
	_sky.set_shader_parameter("top_color", (current.sky_top as Color).lerp(storm * 0.8, wet * 0.75))
	_sky.set_shader_parameter("horizon_color", (current.sky_horizon as Color).lerp(storm, wet * 0.75))
	_sky.set_shader_parameter("ground_bottom", current.ground_bottom)
	_sky.set_shader_parameter("ground_horizon", (current.ground_horizon as Color).lerp(storm * 0.7, wet * 0.5))
	_sky.set_shader_parameter("night", night_amount * (1.0 - wet * 0.8))
	_sky.set_shader_parameter("cloud_cover", lerpf(0.42, 1.0, wet))
	_sky.set_shader_parameter("cloud_dark", wet * 0.55)
	_sky.set_shader_parameter("cloud_lit", (current.cloud_lit as Color).lerp(storm * 1.3, wet * 0.7))
	_sky.set_shader_parameter("cloud_shade", (current.cloud_shade as Color).lerp(storm * 0.6, wet * 0.7))
	_sky.set_shader_parameter("wind", 0.006 + wet * 0.012)

# ------------------------------------------------------------------ rain

## Streaks falling round the camera, and the rain loop, while it rains outside.
func _update_rain(outside: bool) -> void:
	var show := rain_amount * (1.0 if outside else 0.0)
	if show <= 0.01:
		if _rain != null:
			_rain.emitting = false
		if _rain_sound != null:
			# indoors the rain is still heard, softly
			_rain_sound.volume_db = linear_to_db(maxf(0.0001, rain_amount * 0.25))
			if rain_amount <= 0.01:
				_rain_sound.stop()
		return
	if _rain == null:
		_build_rain()
	_rain.emitting = true
	_rain.amount_ratio = clampf(show, 0.05, 1.0)
	if _rain_sound != null:
		if not _rain_sound.playing:
			_rain_sound.play()
		_rain_sound.volume_db = linear_to_db(maxf(0.0001, show * 0.8))

func _build_rain() -> void:
	_rain = GPUParticles3D.new()
	_rain.name = "Rain"
	var low := QualityPreset.current() == "low"
	_rain.amount = 1800 if low else 4000
	_rain.lifetime = 1.1
	_rain.preprocess = 1.0
	_rain.local_coords = false
	_rain.visibility_aabb = AABB(Vector3(-40, -40, -40), Vector3(80, 60, 80))
	_rain.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	var process := ParticleProcessMaterial.new()
	process.emission_shape = ParticleProcessMaterial.EMISSION_SHAPE_BOX
	process.emission_box_extents = Vector3(24, 1, 24)
	process.direction = Vector3(0.12, -1, 0.05)
	process.spread = 2.0
	process.initial_velocity_min = 24.0
	process.initial_velocity_max = 30.0
	process.gravity = Vector3(0, -9.8, 0)
	_rain.process_material = process
	var quad := QuadMesh.new()
	quad.size = Vector2(0.022, 0.75)
	var mat := StandardMaterial3D.new()
	mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	mat.billboard_mode = BaseMaterial3D.BILLBOARD_FIXED_Y
	mat.billboard_keep_scale = true
	mat.albedo_color = Color(0.78, 0.84, 0.92, 0.42)
	mat.disable_receive_shadows = true
	# Drops right at the lens would be white bars across the screen: they fade
	# in from a few metres out.
	mat.distance_fade_mode = BaseMaterial3D.DISTANCE_FADE_PIXEL_ALPHA
	mat.distance_fade_min_distance = 1.5
	mat.distance_fade_max_distance = 6.0
	quad.material = mat
	_rain.draw_pass_1 = quad
	world.add_child(_rain)
	if ResourceLoader.exists(RAIN_SOUND):
		var stream = load(RAIN_SOUND)
		if stream is AudioStreamWAV:
			var wav := (stream as AudioStreamWAV).duplicate() as AudioStreamWAV
			wav.loop_mode = AudioStreamWAV.LOOP_FORWARD
			wav.loop_end = int(wav.get_length() * wav.mix_rate)
			stream = wav
		_rain_sound = AudioStreamPlayer.new()
		_rain_sound.name = "RainSound"
		_rain_sound.stream = stream
		_rain_sound.bus = "Ambience" if AudioServer.get_bus_index("Ambience") >= 0 else "Master"
		_rain_sound.volume_db = -60.0
		add_child(_rain_sound)

## The rain falls from above the camera wherever it goes.
func _follow_camera() -> void:
	if _rain == null or not _rain.emitting:
		return
	var camera := get_viewport().get_camera_3d()
	if camera != null:
		_rain.global_position = camera.global_position + Vector3(0, 16, 0)
