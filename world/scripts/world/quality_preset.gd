extends RefCounted

## Art pass quality presets ("provide reduced particles,
## shadows, and postprocessing for the Intel integrated GPU profile").
##
## The target machine records an Intel integrated GPU, so
## `auto` resolves to the `low` preset there: no sun shadows, no glow, no SSAO,
## no MSAA, and roughly half the vegetation and particle density. Visual
## capture runs pass `--quality=high` explicitly.
##
## Everything the preset changes is presentation only. It can never alter the
## simulation: mobs, collision, routes and rewards are identical on both.

const PRESETS := {
	"low": {
		"sun_shadows": false,
		"shadow_max_distance": 0.0,
		"glow": false,
		"ssao": false,
		"msaa": 0,
		"ssr": false,
		"foliage_density": 0.55,
		"particle_scale": 0.5,
		"torch_range_scale": 0.85,
		"tonemap_exposure": 1.12,
	},
	"high": {
		"sun_shadows": true,
		"shadow_max_distance": 150.0,
		"glow": true,
		"ssao": true,
		"msaa": 2,
		"ssr": false,
		"foliage_density": 1.0,
		"particle_scale": 1.0,
		"torch_range_scale": 1.0,
		"tonemap_exposure": 1.12,
	},
}

static var _current := "high"
static var _resolved := false

## The preset this build should run at. `--quality=low|high` on the command
## line wins; otherwise an Intel/unknown adapter gets the reduced preset.
static func resolve() -> String:
	if _resolved:
		return _current
	_resolved = true
	for arg in OS.get_cmdline_user_args():
		if arg.begins_with("--quality="):
			var wanted := arg.trim_prefix("--quality=").to_lower()
			if PRESETS.has(wanted):
				_current = wanted
				return _current
	var adapter := RenderingServer.get_video_adapter_name().to_lower()
	if adapter.contains("intel") or adapter.contains("uhd") or adapter.contains("iris"):
		_current = "low"
	elif adapter == "":
		# Headless / dummy renderer: report the low preset so the checks scene
		# asserts the same configuration the target machine runs.
		_current = "low"
	else:
		_current = "high"
	return _current

static func current() -> String:
	return resolve()

static func settings() -> Dictionary:
	return PRESETS[resolve()]

static func foliage_density() -> float:
	return float(settings()["foliage_density"])

static func particle_scale() -> float:
	return float(settings()["particle_scale"])

static func forced(name: String) -> void:
	if PRESETS.has(name):
		_current = name
		_resolved = true

## Apply the preset to a built world (environment + sun + viewport MSAA).
static func apply(world: Node3D) -> void:
	var preset := settings()
	var env_node := world.get_node_or_null("WorldEnvironment")
	if env_node is WorldEnvironment:
		var env: Environment = (env_node as WorldEnvironment).environment
		if env != null:
			env.glow_enabled = bool(preset["glow"])
			env.ssao_enabled = bool(preset["ssao"])
			env.ssr_enabled = bool(preset["ssr"])
	var sun := world.get_node_or_null("DirectionalLight3D") as DirectionalLight3D
	if sun != null:
		sun.shadow_enabled = bool(preset["sun_shadows"])
		if bool(preset["sun_shadows"]):
			sun.directional_shadow_max_distance = float(preset["shadow_max_distance"])
	var viewport := world.get_viewport()
	if viewport != null:
		viewport.msaa_3d = int(preset["msaa"])
	# Torch and lamp lights: shorten the reach a little on low so fewer
	# transparent/lighted pixels are shaded.
	var range_scale: float = float(preset["torch_range_scale"])
	if range_scale != 1.0:
		for light in world.get_tree().get_nodes_in_group("torch_lights"):
			if light is OmniLight3D and not light.has_meta("base_range"):
				light.set_meta("base_range", light.omni_range)
				light.omni_range = float(light.get_meta("base_range")) * range_scale
	tune_particles(world)

## Particle budget: presentation only, applied to every particle system in the
## tree (spawns included) by scaling `amount_ratio` on GPU particles. Effects
## created later are caught by the throttled sweep in game_world.gd.
static func tune_particles(root: Node) -> int:
	if not is_instance_valid(root):
		return 0
	var ratio := particle_scale()
	var count := 0
	for node in root.find_children("*", "GPUParticles3D", true, false):
		var particles := node as GPUParticles3D
		particles.amount_ratio = ratio
		count += 1
	for node in root.find_children("*", "CPUParticles3D", true, false):
		var particles := node as CPUParticles3D
		if not particles.has_meta("base_amount"):
			particles.set_meta("base_amount", particles.amount)
		particles.amount = maxi(1, int(round(float(particles.get_meta("base_amount")) * ratio)))
		count += 1
	return count
