extends HudWindow
class_name HudPortkey

## Where should the Portkey go? Opened by right-clicking an Old Boot in the
## bag; the authority places it (SimNet.portkey_place) at the owner's feet.

var player: Node = null
var _list: VBoxContainer

func _init() -> void:
	super._init("Portkey", Vector2(380, 360))
	name = "PortkeyPicker"

func _ready() -> void:
	super._ready()
	var hint := HudKit.label(tr("Set the boot down and choose where it goes. For ten seconds your party may grab hold; then everyone holding on is carried there together."), 13, HudKit.PARCHMENT)
	hint.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	body.add_child(hint)
	_list = VBoxContainer.new()
	_list.add_theme_constant_override("separation", 6)
	body.add_child(_list)

func open_for(who: Node) -> void:
	player = who
	for child in _list.get_children():
		child.queue_free()
	var level := int(player.get("level")) if is_instance_valid(player) else 1
	for id in HPMaps.portkey_rules().get("destinations", []):
		var dest := HPMaps.travel_node(String(id))
		if dest.is_empty():
			continue
		var row := HBoxContainer.new()
		_list.add_child(row)
		var name_label := HudKit.label(I18n.t(String(dest.get("label", id))), 16, HudKit.GOLD_HI)
		name_label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		row.add_child(name_label)
		var go := Button.new()
		go.focus_mode = Control.FOCUS_NONE
		go.custom_minimum_size = Vector2(110, 0)
		var need := int(dest.get("level_min", 1))
		if level < need:
			go.text = tr("Level %d") % need
			go.disabled = true
		else:
			go.text = tr("Set down")
			go.pressed.connect(_place.bind(String(id)))
		row.add_child(go)
	open()

func _place(dest_id: String) -> void:
	close()
	if is_instance_valid(player):
		SimNet.portkey_place(player, dest_id)
