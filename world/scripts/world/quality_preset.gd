extends RefCounted

## Graphics quality presets: low (integrated GPUs, the Intel iGPU profile),
## medium and high.
##
## The player picks one in Settings (or leaves it on Auto: integrated GPU ->
## low, discrete -> high, anything else -> medium). `--quality=low|medium|high`
## on the command line wins over both; headless runs always use low so checks
## exercise the reduced budget.
##
## What a preset sets, all presentation only (it can never alter the
## simulation: mobs, collision, routes and rewards are identical on every
## preset):
##   * 3D render resolution (FSR 1 upscaling below 100 %), anti-aliasing;
##   * sun shadow cascades, reach and atlas size;
##   * glow, SSAO;
##   * view distance (camera far plane) with fog density matched to it, so the
##     far plane always sits inside the haze instead of cutting the hills;
##   * vegetation: how much of the small stuff is drawn, how far every LOD
##     reaches (the last, far LOD has its own scale: distant impostors are
##     what cost draw calls) and which LODs cast shadows
##     (GroundsTerrain.apply_quality);
##   * terrain mesh detail (Terrain3D clipmap size);
##   * lamp light reach and fade distance, particle budget.
##
## `apply(world)` can run at any time: changing the preset in Settings applies
## it to the live world without a reload.

const NAMES := ["low", "medium", "high"]

const PRESETS := {
	"low": {
		"render_scale": 0.77,
		"msaa": 0,
		"taa": false,
		"fxaa": true,
		"sun_shadows": true,
		"shadow_max_distance": 45.0,
		"shadow_splits": DirectionalLight3D.SHADOW_PARALLEL_2_SPLITS,
		"shadow_atlas": 2048,
		"glow": false,
		"ssao": false,
		"ssr": false,
		"view_distance": 1600.0,
		"fog_density": 0.00060,
		"foliage_density": 0.5,
		"vegetation_lod_scale": 0.6,
		"vegetation_far_scale": 0.4,
		"vegetation_shadow_lod": 0,
		"small_plant_shadows": false,
		"terrain_mesh_size": 32,
		"particle_scale": 0.5,
		"torch_range_scale": 0.85,
		"lamp_fade_begin": 50.0,
		"tonemap_exposure": 0.86,
	},
	"medium": {
		"render_scale": 0.87,
		"msaa": 0,
		"taa": true,
		"fxaa": false,
		"sun_shadows": true,
		"shadow_max_distance": 90.0,
		"shadow_splits": DirectionalLight3D.SHADOW_PARALLEL_4_SPLITS,
		"shadow_atlas": 4096,
		"glow": true,
		"ssao": false,
		"ssr": false,
		"view_distance": 2600.0,
		"fog_density": 0.00042,
		"foliage_density": 0.8,
		"vegetation_lod_scale": 0.8,
		"vegetation_far_scale": 0.7,
		"vegetation_shadow_lod": 1,
		"small_plant_shadows": true,
		"terrain_mesh_size": 48,
		"particle_scale": 0.75,
		"torch_range_scale": 1.0,
		"lamp_fade_begin": 70.0,
		"tonemap_exposure": 0.86,
	},
	"high": {
		"render_scale": 1.0,
		"msaa": 2,
		"taa": true,
		"fxaa": false,
		"sun_shadows": true,
		"shadow_max_distance": 120.0,
		"shadow_splits": DirectionalLight3D.SHADOW_PARALLEL_4_SPLITS,
		"shadow_atlas": 4096,
		"glow": true,
		"ssao": true,
		"ssr": false,
		"view_distance": 3800.0,
		"fog_density": 0.00032,
		"foliage_density": 1.0,
		"vegetation_lod_scale": 1.0,
		"vegetation_far_scale": 1.0,
		"vegetation_shadow_lod": 1,
		"small_plant_shadows": true,
		"terrain_mesh_size": 48,
		"particle_scale": 1.0,
		"torch_range_scale": 1.0,
		"lamp_fade_begin": 90.0,
		"tonemap_exposure": 0.86,
	},
}

static var _current := "high"
static var _resolved := false

## The preset this run uses. Order: `--quality=` on the command line, then
## headless (always low), then the player's Settings choice, then Auto.
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
	if RenderingServer.get_video_adapter_name() == "":
		# Headless / dummy renderer: exercise the reduced profile in checks.
		_current = "low"
		return _current
	var chosen := GameSettings.instance().graphics_quality
	_current = chosen if PRESETS.has(chosen) else detect()
	return _current

## Auto: what the adapter suggests.
static func detect() -> String:
	match RenderingServer.get_video_adapter_type():
		RenderingDevice.DEVICE_TYPE_INTEGRATED_GPU:
			return "low"
		RenderingDevice.DEVICE_TYPE_DISCRETE_GPU:
			return "high"
		RenderingDevice.DEVICE_TYPE_CPU:
			return "low"
	return "medium"

static func current() -> String:
	return resolve()

static func settings() -> Dictionary:
	return PRESETS[resolve()]

static func foliage_density() -> float:
	return float(settings()["foliage_density"])

static func particle_scale() -> float:
	return float(settings()["particle_scale"])

static func view_distance() -> float:
	return float(settings()["view_distance"])

static func forced(name: String) -> void:
	if PRESETS.has(name):
		_current = name
		_resolved = true

## Switch preset at runtime (the Settings screen): remember the choice
## ("auto" or a preset name) and apply the result to the live world.
static func choose(choice: String, world: Node3D = null) -> void:
	GameSettings.instance().set_graphics_quality(choice)
	_resolved = false
	resolve()
	if world != null and is_instance_valid(world):
		apply(world)

## Apply the preset to a built world: viewport, environment, sun, camera,
## terrain and vegetation, lamps, particles.
static func apply(world: Node3D) -> void:
	var preset := settings()
	var viewport := world.get_viewport()
	if viewport != null:
		viewport.msaa_3d = int(preset["msaa"])
		viewport.use_taa = bool(preset["taa"])
		viewport.screen_space_aa = Viewport.SCREEN_SPACE_AA_FXAA if bool(preset["fxaa"]) else Viewport.SCREEN_SPACE_AA_DISABLED
		var scale := float(preset["render_scale"])
		viewport.scaling_3d_mode = Viewport.SCALING_3D_MODE_FSR if scale < 1.0 else Viewport.SCALING_3D_MODE_BILINEAR
		viewport.scaling_3d_scale = scale
		apply_camera(viewport.get_camera_3d())
	RenderingServer.directional_shadow_atlas_set_size(int(preset["shadow_atlas"]), true)
	var env_node := world.get_node_or_null("WorldEnvironment")
	if env_node is WorldEnvironment:
		var env: Environment = (env_node as WorldEnvironment).environment
		if env != null:
			env.glow_enabled = bool(preset["glow"])
			env.ssao_enabled = bool(preset["ssao"])
			env.ssr_enabled = bool(preset["ssr"])
			env.tonemap_exposure = float(preset["tonemap_exposure"])
			if env.fog_enabled:
				env.fog_density = float(preset["fog_density"])
	var sun := world.get_node_or_null("DirectionalLight3D") as DirectionalLight3D
	if sun != null:
		sun.shadow_enabled = bool(preset["sun_shadows"])
		if bool(preset["sun_shadows"]):
			sun.directional_shadow_max_distance = float(preset["shadow_max_distance"])
			sun.directional_shadow_mode = int(preset["shadow_splits"])
	var terrain := GroundsTerrain.active()
	if terrain != null:
		terrain.apply_quality(preset)
	# Torch and lamp lights: reach and fade distance. The authored range is kept
	# in metadata so switching presets back and forth never compounds.
	var range_scale: float = float(preset["torch_range_scale"])
	var fade_begin: float = float(preset["lamp_fade_begin"])
	for light in world.get_tree().get_nodes_in_group("torch_lights"):
		if light is OmniLight3D:
			var omni := light as OmniLight3D
			if not omni.has_meta("base_range"):
				omni.set_meta("base_range", omni.omni_range)
			omni.omni_range = float(omni.get_meta("base_range")) * range_scale
			omni.distance_fade_enabled = true
			omni.distance_fade_begin = fade_begin
			omni.distance_fade_length = fade_begin * 0.35
	tune_particles(world)

## View distance on a camera (the player camera is created after the world, so
## game_world's sweep calls this too).
static func apply_camera(camera: Camera3D) -> void:
	if camera != null and is_instance_valid(camera):
		camera.far = view_distance()

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
