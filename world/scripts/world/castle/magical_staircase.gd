extends HPStaircase

## Magical staircase scene root ("Magical staircase prototype").
##
## The scene is self-contained and position-independent: all of its geometry is
## built from the shared spec in `hpmmo_sim/staircase.gd`, in the scene's own
## local space, so it works wherever a `StaircaseSlot` marker places it (the
## grand staircase hall instantiates it; nothing here knows that hall).
##
## All gameplay behaviour - the four states, the travel time, the chosen
## destination, the boarding rule, the rider carry and the failure-case landing -
## lives in `HPStaircase` and is owned by the authority. This script only adds
## what a client needs on top:
##   * a greybox state board so a human can see what the authority decided,
##   * the "entry refused" feedback the server sends,
##   * the same deck clamp the authority applies, so the local prediction does
##     not drift away from the deck while it moves (the server still corrects).
##
## Greybox only: untextured boxes, no art pass.

var _board: Label3D = null
var _flash_until := 0.0

const PBR = preload("res://scripts/assets/pbr_kit.gd")

func _ready() -> void:
	super()
	_build_presentation()

## The moving flight is the one piece of Hogwarts the player rides, and the
## greybox materials shipped with it made it read as a black wedge wedged into
## the hall (measured: deck albedo 0.42 under a dim interior ambient). The
## authority's geometry is untouched; this only dresses the boxes it built.
func _polish_geometry() -> void:
	if platform == null or not is_instance_valid(platform):
		return
	var stone := PBR.surface("stone_ashlar_01", Color(0.88, 0.86, 0.82), {"metres": 3.0})
	var wood := PBR.surface("dark_wooden_planks")
	var rail := PBR.surface("dark_wooden_planks", Color(0.62, 0.56, 0.5))
	for node in find_children("*", "MeshInstance3D", true, false):
		var mesh_instance := node as MeshInstance3D
		var label := String(mesh_instance.name)
		if label.begins_with("Deck") or label.begins_with("Step"):
			mesh_instance.material_override = stone
		elif label.begins_with("Rail"):
			mesh_instance.material_override = rail
		elif label.begins_with("Gate"):
			mesh_instance.material_override = wood
	# A travelling enchantment: an emissive line along both deck edges, the one
	# part of the ride that reads at a glance from the hall floor.
	var glow := StandardMaterial3D.new()
	glow.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	glow.albedo_color = Color(0.55, 0.85, 1.0, 0.9)
	glow.emission_enabled = true
	glow.emission = Color(0.35, 0.7, 1.0)
	glow.emission_energy_multiplier = 1.6
	var flight: Dictionary = spec.get("flight", {})
	var rise_v := float(flight.get("rise", 6.0))
	var run_v := float(flight.get("run", 12.0))
	var width := float(flight.get("width", 3.0))
	var angle := atan2(rise_v, run_v)
	var ramp_length := sqrt(rise_v * rise_v + run_v * run_v)
	var mid := Vector3(0.0, rise_v * 0.5, run_v * 0.5)
	for side in [-1.0, 1.0]:
		var line := MeshInstance3D.new()
		line.name = "EdgeGlow%d" % int(side)
		var box := BoxMesh.new()
		box.size = Vector3(0.08, 0.05, ramp_length)
		box.material = glow
		line.mesh = box
		line.position = mid + Vector3(side * (width * 0.5 - 0.04), 0.18, 0.0)
		line.rotation.x = -angle
		platform.add_child(line)
	# Read as a stair, not a ramp: tread strips laid across the deck at the
	# authored rise. The authority's collision stays the smooth ramp.
	var treads := maxi(8, int(round(rise_v / 0.42)))
	var tread_mat := PBR.surface("dark_wooden_planks", Color(0.78, 0.66, 0.48))
	var along := Vector3(0.0, sin(angle), cos(angle))
	var normal_v := Vector3(0.0, cos(angle), -sin(angle))
	for step in range(treads):
		var s := (float(step) + 0.5) / float(treads) * ramp_length
		var tread := MeshInstance3D.new()
		tread.name = "Tread%02d" % step
		var tread_box := BoxMesh.new()
		tread_box.size = Vector3(width * 0.97, 0.07, ramp_length / float(treads) * 0.5)
		tread_box.material = tread_mat
		tread.mesh = tread_box
		tread.position = mid + along * (s - ramp_length * 0.5) + normal_v * 0.12
		tread.rotation.x = -angle
		platform.add_child(tread)

func _build_presentation() -> void:
	_polish_geometry()
	_board = Label3D.new()
	_board.name = "StateBoard"
	_board.billboard = BaseMaterial3D.BILLBOARD_ENABLED
	_board.font_size = 48
	_board.outline_size = 10
	_board.outline_modulate = Color(0, 0, 0, 1)
	_board.position = Vector3(0.0, rise() + 3.2, run_length() * 0.5)
	add_child(_board)
	SimAuthority.notice.connect(_on_notice)
	_update_board()

func _on_notice(text: String, _color: Color) -> void:
	if not text.begins_with(NOTICE_LOCKED):
		return
	_flash_until = Time.get_ticks_msec() / 1000.0 + 1.5
	_update_board()

func _update_board() -> void:
	if _board == null:
		return
	var destination := dock_id(to_index)
	var suffix := ""
	if Time.get_ticks_msec() / 1000.0 < _flash_until:
		suffix = "\n[entry refused while %s]" % state
	_board.text = "Magical staircase: %s -> %s%s" % [state, destination, suffix]
	_board.modulate = Color(1.0, 0.55, 0.35) if not entry_allowed() else Color(0.85, 0.95, 1.0)

func _physics_process(delta: float) -> void:
	super(delta)
	if is_authority_runtime:
		_update_board()
		return
	# Client: the same clamp the authority applies, as prediction. The next
	# authoritative position still wins if the two ever disagree.
	_carry_local_prediction()
	_update_board()

func _carry_local_prediction() -> void:
	var player := SimAuthority.local_player_node()
	if player == null or not is_instance_valid(player):
		return
	# Generous above / tight below: the local body can be a snapshot ahead of the
	# transform this client is showing, while a body standing on the ground under a
	# raised flight is metres below the ramp surface and must not be swept up.
	if not on_deck(player.global_position, SimAuthority.sim_tick, 3.2, 0.9):
		return
	var xform := platform_world_transform(SimAuthority.sim_tick)
	var local := xform.affine_inverse() * player.global_position
	local.x = clampf(local.x, -half_width() + 0.35, half_width() - 0.35)
	local.z = clampf(local.z, 0.3, run_length() - 0.3)
	var surface := deck_surface_y(local.z)
	if local.y < surface + 0.05:
		local.y = surface + 0.05
	local.y = minf(local.y, surface + 2.4)
	player.global_position = xform * local
