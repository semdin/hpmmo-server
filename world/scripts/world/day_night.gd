extends Node
class_name DayNight

## Day and night on the grounds, and the creature fill light everywhere.
##
## Time of day follows the server clock in GMT+3 (the players' time zone),
## read from the machine's UTC clock so every client agrees without a protocol
## field. Settings > General > Time of day can hold it at day or night instead
## (GameSettings.time_of_day: "system" | "day" | "night").
##
## The day runs night -> dawn (05-07:30) -> day -> dusk (17:30-20:30) -> night;
## each phase is a look (sun or moon, sky, ambient, fog, exposure, stars, lamp
## strength) and the hours between two looks blend them. Only the outdoor
## environment is touched: inside a map with its own atmosphere (the castle,
## the caverns - the environment then carries `outdoor_ambient`) nothing
## changes, and the outdoor values come back on the way out.
##
## Creature fill: a shadowless directional light from the camera that lights
## only render layer 2, where every creature and player body is put
## (`tag`). Dark bodies in a tree's or a cliff's shadow, and at night, stay
## readable without lifting the whole scene. Presentation only - never built on
## a dedicated server.

const QualityPreset = preload("res://scripts/world/quality_preset.gd")
const UTC_OFFSET_HOURS := 3.0
const CHARACTER_LAYER := 2   # render layer bit value (layer 2)
const UPDATE_PERIOD := 0.5

# i18n-begin
const CHOICES := {"system": "Server time (GMT+3)", "day": "Always day", "night": "Always night"}
# i18n-end

const DAY := {
	"sun_color": Color(1.0, 0.96, 0.89), "sun_energy": 0.95, "sun_rot": Vector2(-38, -30),
	"sky_top": Color(0.24, 0.35, 0.49), "sky_horizon": Color(0.60, 0.66, 0.72),
	"ground_bottom": Color(0.20, 0.23, 0.22), "ground_horizon": Color(0.46, 0.52, 0.55),
	"ambient_color": Color(1, 1, 1), "ambient_sky": 1.0, "ambient_energy": 0.62,
	"fog_color": Color(0.66, 0.73, 0.80), "exposure": 1.0, "stars": 0.0,
	"fill_energy": 0.55, "fill_color": Color(1.0, 0.97, 0.92), "torch": 1.0,
}
const DUSK := {
	"sun_color": Color(1.0, 0.62, 0.38), "sun_energy": 0.72, "sun_rot": Vector2(-12, -70),
	"sky_top": Color(0.20, 0.23, 0.40), "sky_horizon": Color(0.92, 0.58, 0.40),
	"ground_bottom": Color(0.15, 0.14, 0.15), "ground_horizon": Color(0.52, 0.40, 0.35),
	"ambient_color": Color(0.90, 0.72, 0.62), "ambient_sky": 0.8, "ambient_energy": 0.6,
	"fog_color": Color(0.78, 0.58, 0.50), "exposure": 1.0, "stars": 0.15,
	"fill_energy": 0.7, "fill_color": Color(1.0, 0.86, 0.76), "torch": 1.25,
}
const NIGHT := {
	"sun_color": Color(0.60, 0.70, 1.0), "sun_energy": 0.42, "sun_rot": Vector2(-55, 150),
	"sky_top": Color(0.012, 0.02, 0.05), "sky_horizon": Color(0.06, 0.09, 0.16),
	"ground_bottom": Color(0.02, 0.025, 0.03), "ground_horizon": Color(0.05, 0.07, 0.10),
	"ambient_color": Color(0.36, 0.44, 0.66), "ambient_sky": 0.35, "ambient_energy": 0.95,
	"fog_color": Color(0.08, 0.11, 0.18), "exposure": 1.12, "stars": 1.0,
	"fill_energy": 1.1, "fill_color": Color(0.74, 0.82, 1.0), "torch": 1.55,
}
## (hour, look): the looks between two keys blend linearly.
const KEYS := [[0.0, "night"], [5.0, "night"], [6.2, "dusk"], [7.5, "day"],
	[17.5, "day"], [19.0, "dusk"], [20.5, "night"], [24.0, "night"]]

var world: Node3D = null
var fill: DirectionalLight3D = null
## The look on screen now (eases towards the hour's look) and how far night it is.
var current: Dictionary = {}
var night_amount := 0.0
var _timer := 0.0
var _stars: Texture2D = null
var _sky_sig := ""

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
	fill = DirectionalLight3D.new()
	fill.name = "CharacterFill"
	fill.light_cull_mask = CHARACTER_LAYER
	fill.shadow_enabled = false
	fill.light_specular = 0.15
	fill.sky_mode = DirectionalLight3D.SKY_MODE_LIGHT_ONLY
	world.add_child.call_deferred(fill)
	get_tree().node_added.connect(_on_node_added)
	for root in [world.get_node_or_null("Players"), world.get_node_or_null("Mobs")]:
		if root != null:
			tag(root)
	current = look_at_hour(hour()).duplicate()
	_apply(true)

## The hour shown, 0-24 (fractional): GMT+3 from the UTC clock, or the setting's.
static func hour() -> float:
	# Captures pin an hour: --hour=21.5
	for arg in OS.get_cmdline_user_args():
		if arg.begins_with("--hour="):
			return fposmod(float(arg.trim_prefix("--hour=")), 24.0)
	match GameSettings.instance().time_of_day:
		"day":
			return 13.0
		"night":
			return 0.5
	return fposmod(Time.get_unix_time_from_system() / 3600.0 + UTC_OFFSET_HOURS, 24.0)

static func _look(name: String) -> Dictionary:
	return NIGHT if name == "night" else (DUSK if name == "dusk" else DAY)

static func look_at_hour(h: float) -> Dictionary:
	for i in range(KEYS.size() - 1):
		var a: Array = KEYS[i]
		var b: Array = KEYS[i + 1]
		if h >= float(a[0]) and h <= float(b[0]):
			var t := 0.0 if float(b[0]) == float(a[0]) else (h - float(a[0])) / (float(b[0]) - float(a[0]))
			return _blend(_look(String(a[1])), _look(String(b[1])), smoothstep(0.0, 1.0, t))
	return DAY.duplicate()

static func _blend(a: Dictionary, b: Dictionary, t: float) -> Dictionary:
	var out := {}
	for key in a:
		var va = a[key]
		out[key] = lerp(va, b[key], t) if not (va is Color) else (va as Color).lerp(b[key], t)
	return out

## Put every mesh under `root` on the creature layer (the fill light's).
static func tag(root: Node) -> void:
	if root is GeometryInstance3D:
		(root as GeometryInstance3D).layers |= CHARACTER_LAYER
	for node in root.find_children("*", "GeometryInstance3D", true, false):
		(node as GeometryInstance3D).layers |= CHARACTER_LAYER

## Meshes added later (a respawned creature, a new cloak) join the layer when
## they sit under a creature or player body.
func _on_node_added(node: Node) -> void:
	if not (node is GeometryInstance3D) or node is Label3D:
		return
	var up := node.get_parent()
	for _i in range(8):
		if up == null:
			return
		if up.get("sim_puppet") != null:
			(node as GeometryInstance3D).layers |= CHARACTER_LAYER
			return
		up = up.get_parent()

func _process(delta: float) -> void:
	_aim_fill()
	_timer -= delta
	if _timer > 0.0:
		return
	_timer = UPDATE_PERIOD
	var target := look_at_hour(hour())
	# Ease over ~2 s so a settings switch fades instead of snapping.
	var t := clampf(UPDATE_PERIOD * 1.4, 0.0, 1.0)
	current = _blend(current, target, t)
	_apply(false)

## The fill shines along the view, from a little above the camera.
func _aim_fill() -> void:
	if fill == null or not fill.is_inside_tree():
		return
	var camera := get_viewport().get_camera_3d()
	if camera == null:
		return
	var basis := camera.global_transform.basis
	fill.global_transform = Transform3D(basis.rotated(basis.x.normalized(), deg_to_rad(-22.0)), camera.global_position)

func _apply(force: bool) -> void:
	night_amount = clampf(float(current.get("stars", 0.0)), 0.0, 1.0)
	if fill != null:
		fill.light_energy = float(current.fill_energy)
		fill.light_color = current.fill_color
	var env_node := world.get_node_or_null("WorldEnvironment") as WorldEnvironment
	if env_node == null or env_node.environment == null:
		return
	var env := env_node.environment
	if env.has_meta("outdoor_ambient"):
		return   # inside: the map's own atmosphere holds
	env.ambient_light_source = Environment.AMBIENT_SOURCE_SKY
	env.ambient_light_sky_contribution = float(current.ambient_sky)
	env.ambient_light_color = current.ambient_color
	env.ambient_light_energy = float(current.ambient_energy)
	env.fog_light_color = current.fog_color
	env.tonemap_exposure = float(QualityPreset.settings().get("tonemap_exposure", 0.86)) * float(current.exposure)
	var sky_mat := env.sky.sky_material as ProceduralSkyMaterial if env.sky != null else null
	if sky_mat != null:
		# The sky's radiance is re-baked whenever it changes: only when it
		# really moved.
		var sig := "%s%s%.2f" % [(current.sky_top as Color).to_html(), (current.sky_horizon as Color).to_html(), night_amount]
		if force or sig != _sky_sig:
			_sky_sig = sig
			sky_mat.sky_top_color = current.sky_top
			sky_mat.sky_horizon_color = current.sky_horizon
			sky_mat.ground_bottom_color = current.ground_bottom
			sky_mat.ground_horizon_color = current.ground_horizon
			if night_amount > 0.01:
				sky_mat.sky_cover = _star_texture()
				sky_mat.sky_cover_modulate = Color(1, 1, 1, night_amount)
			else:
				sky_mat.sky_cover = null
	var sun := world.get_node_or_null("DirectionalLight3D") as DirectionalLight3D
	if sun != null:
		sun.light_color = current.sun_color
		sun.light_energy = float(current.sun_energy)
		var rot: Vector2 = current.sun_rot
		sun.rotation_degrees = Vector3(rot.x, rot.y, 0.0)
	var torch := float(current.torch)
	for light in get_tree().get_nodes_in_group("torch_lights"):
		if light is Light3D:
			if not light.has_meta("day_energy"):
				light.set_meta("day_energy", (light as Light3D).light_energy)
			(light as Light3D).light_energy = float(light.get_meta("day_energy")) * torch

## A starfield for the night sky (equirectangular, upper half), made once.
func _star_texture() -> Texture2D:
	if _stars != null:
		return _stars
	var img := Image.create(2048, 1024, false, Image.FORMAT_RGB8)
	img.fill(Color(0, 0, 0))
	var rng := RandomNumberGenerator.new()
	rng.seed = 1977
	for _i in range(2600):
		var x := rng.randi_range(0, 2047)
		var y := int(pow(rng.randf(), 1.6) * 470.0)   # thicker overhead
		var b := pow(rng.randf(), 3.0) * 0.9 + 0.1
		var tint := Color(b * 0.9, b * 0.93, b)
		img.set_pixel(x, y, tint)
		if b > 0.75 and x < 2047 and y < 1023:
			img.set_pixel(x + 1, y, tint * 0.6)
			img.set_pixel(x, y + 1, tint * 0.6)
	_stars = ImageTexture.create_from_image(img)
	return _stars
