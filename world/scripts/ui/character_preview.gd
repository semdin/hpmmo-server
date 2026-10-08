extends SubViewportContainer
class_name CharacterPreview

var view: SubViewport
var model: Node3D
var _key := ""

func _ready() -> void:
	custom_minimum_size = Vector2(130, 210)
	size_flags_horizontal = Control.SIZE_EXPAND_FILL
	size_flags_vertical = Control.SIZE_EXPAND_FILL
	stretch = true
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	view = SubViewport.new()
	view.size = Vector2i(260, 420)
	view.own_world_3d = true
	view.transparent_bg = true
	view.render_target_update_mode = SubViewport.UPDATE_DISABLED
	add_child(view)
	var camera := Camera3D.new()
	camera.position = Vector3(0, 1.0, 3.1)
	camera.projection = Camera3D.PROJECTION_ORTHOGONAL
	camera.size = 2.3
	camera.keep_aspect = Camera3D.KEEP_HEIGHT
	view.add_child(camera)
	var light := DirectionalLight3D.new()
	light.rotation_degrees = Vector3(-25, -25, 0)
	light.light_energy = 1.8
	view.add_child(light)
	var environment := WorldEnvironment.new()
	environment.environment = Environment.new()
	environment.environment.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
	environment.environment.ambient_light_color = Color(0.65, 0.73, 0.9)
	environment.environment.ambient_light_energy = 0.7
	view.add_child(environment)

func show_player(player: Node) -> void:
	if view == null or not is_instance_valid(player): return
	var key := "%s:%s" % [player.house, str(player.equipment)]
	if key == _key: return
	_key = key
	if is_instance_valid(model):
		view.remove_child(model)
		model.queue_free()
	# Build the presentation model in its own idle state; never duplicate the
	# gameplay animation graph, which may currently be casting, falling or mounted.
	model = Node3D.new()
	view.add_child(model)
	HeroAppearance.spawn(model,GameData.HOUSES[player.house].primary_color)
	HeroAppearance.show_equipped_wand(model,player.equipment.get("main_hand",{}))

func set_active(active: bool) -> void:
	if view != null:
		view.render_target_update_mode = SubViewport.UPDATE_ALWAYS if active else SubViewport.UPDATE_DISABLED
