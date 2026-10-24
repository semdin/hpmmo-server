extends StaticBody3D

const MaterialKitScript = preload("res://scripts/assets/material_kit.gd")

## Quest NPC — robed professor / shopkeeper with nameplate, idle bob,
## click-to-talk (F or a click), dialogue panel, and a bobbing quest arrow while
## a talk quest points at them.

## NPCs with a body of their own (generated mesh on the hero's GameRig, built by
## art/characters/<name>/scripts; see art/pipeline/CHARACTER_PIPELINE.md);
## everyone else wears the tinted KayKit wizard. Height and radius are metres at
## scale 1 and size the capsule, nameplate and marker.
const BODIES := {
	"Borin": {"model": "res://assets/models/characters/borin.glb", "scale": 1.0, "height": 2.72, "radius": 0.55},
}
const LOOPING_CLIPS := ["Idle", "Talk", "Walk_A"]
## How long a custom body keeps gesturing after the player talks to it.
const TALK_SECONDS := 4.0

var npc_name: String = "Professor Fig"
var dialogue: Array = ["Welcome to Hogwarts, young wizard."]
var shop_items: Array = []
var _marker: Node3D = null
var _t: float = 0.0
var _rig: Node3D = null
var _marker_height: float = 3.1
var _bob: float = 0.03
var _anim: AnimationPlayer = null
var _talk_left: float = 0.0

func setup(p_name: String, p_dialogue: Array, robe_color: Color) -> void:
	npc_name = p_name
	dialogue = p_dialogue
	_build(robe_color)
	_update_label()

func _build(robe_color: Color) -> void:
	add_to_group("npcs")
	add_to_group("targetable")
	collision_layer = 2
	collision_mask = 1
	var body: Dictionary = BODIES.get(npc_name, {})
	var size := float(body.get("scale", 1.0))
	# Nameplate and marker float a fixed gap above the crown.
	var crown := float(body.get("height", 2.25)) * size
	var col := CollisionShape3D.new()
	var cap := CapsuleShape3D.new()
	cap.radius = float(body.get("radius", 0.45)) * size
	cap.height = float(body.get("height", 1.8)) * size
	col.shape = cap
	col.position.y = cap.height * 0.5
	add_child(col)

	_rig = Node3D.new()
	add_child(_rig)
	var model: Node3D
	if body.has("model") and ResourceLoader.exists(body["model"]):
		model = (load(body["model"]) as PackedScene).instantiate()
		model.scale = Vector3.ONE * size
		_rig.add_child(model)
		_bob = 0.0   # the hero rig's Idle already breathes; a bob lifts the boots
	else:
		model = preload("res://assets/models/characters/wizard.glb").instantiate()
		_rig.add_child(model)
		for path in ["Rig/Skeleton3D/handslot_r/2H_Staff", "Rig/Skeleton3D/handslot_l/Spellbook", "Rig/Skeleton3D/handslot_l/Spellbook_open"]:
			var accessory := model.get_node_or_null(path) as Node3D
			if accessory:
				accessory.hide()
		var cape := model.get_node_or_null("Rig/Skeleton3D/chest/Mage_Cape") as MeshInstance3D
		if cape:
			cape.material_override = MaterialKitScript.robe_material(robe_color)
	var animation := model.find_child("AnimationPlayer", true, false) as AnimationPlayer
	if animation:
		for clip in LOOPING_CLIPS:
			if animation.has_animation(clip):
				animation.get_animation(clip).loop_mode = Animation.LOOP_LINEAR
		if animation.has_animation("Idle"):
			animation.play("Idle")
		_anim = animation

	var label := Label3D.new()
	label.name = "NpcLabel"
	label.billboard = BaseMaterial3D.BILLBOARD_ENABLED
	label.font_size = 36
	label.outline_size = 8
	label.outline_modulate = Color(0, 0, 0)
	label.position = Vector3(0, crown + 0.45, 0)
	add_child(label)

	# Golden arrow pointing down at the NPC while a quest asks the player to
	# talk to them; it bobs so it reads from across the grounds.
	_marker = Node3D.new()
	_marker.name = "QuestArrow"
	var gold := MaterialKitScript.gold_material()
	var shaft := MeshInstance3D.new()
	var shaft_mesh := CylinderMesh.new()
	shaft_mesh.top_radius = 0.07
	shaft_mesh.bottom_radius = 0.07
	shaft_mesh.height = 0.34
	shaft_mesh.material = gold
	shaft.mesh = shaft_mesh
	shaft.position.y = 0.37
	_marker.add_child(shaft)
	var head := MeshInstance3D.new()
	var head_mesh := CylinderMesh.new()
	head_mesh.top_radius = 0.22
	head_mesh.bottom_radius = 0.0
	head_mesh.height = 0.3
	head_mesh.material = gold
	head.mesh = head_mesh
	head.position.y = 0.05
	_marker.add_child(head)
	var glow := OmniLight3D.new()
	glow.light_color = Color(1.0, 0.85, 0.3)
	glow.light_energy = 0.8
	glow.omni_range = 5.0
	glow.position.y = 0.25
	_marker.add_child(glow)
	_marker_height = crown + 0.8
	_marker.position = Vector3(0, _marker_height, 0)
	add_child(_marker)
	if not NetworkManager.is_dedicated_server:
		QuestManager.quest_updated.connect(_update_quest_arrow)
	_update_quest_arrow()

func _update_quest_arrow() -> void:
	if _marker:
		_marker.visible = QuestManager.npc_wants_talk(npc_name)

func _update_label() -> void:
	var label := get_node_or_null("NpcLabel") as Label3D
	if label:
		label.text = tr("%s\n< click to talk >") % I18n.t(npc_name)
		label.modulate = Color(1.0, 0.9, 0.5)
		WorldLabels.track(label, 16.0)

func _process(delta: float) -> void:
	if NetworkManager.is_dedicated_server:
		set_process(false)   # the sway / glow below is for eyes only
		return
	_t += delta
	if _rig:
		_rig.position.y = sin(_t * 2.0) * _bob
	if _talk_left > 0.0:
		_talk_left -= delta
		if _talk_left <= 0.0 and _anim and _anim.has_animation("Idle"):
			_anim.play("Idle", 0.4)
	if _marker and _marker.visible:
		_marker.position.y = _marker_height + sin(_t * 4.0) * 0.18
		_marker.rotation.y += delta * 1.5

## The dialogue is presentation; the quest credit for talking is the
## authority's decision (range-checked against this NPC on the server).
func talk(player: Node3D) -> Array:
	if is_instance_valid(player):
		SimNet.submit_talk(player, npc_name)
	if _anim and _anim.has_animation("Talk"):
		_anim.play("Talk", 0.3)
		_talk_left = TALK_SECONDS
	return dialogue

func take_damage(_amount: int, _spell: String, _attacker: Node3D) -> void:
	pass # NPCs are peaceful
