extends HPStaircase

## Magical staircase scene root (plan.md Phase 8, "Magical staircase prototype").
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

func _ready() -> void:
	super()
	_build_presentation()

func _build_presentation() -> void:
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
