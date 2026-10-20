extends Control
class_name HudActionBar

## The action bar: the seven spell slots (1-4, Q, E, 5) and, after a gap, four quick
## slots on F1-F4 that hold consumables - Wiggenweld and Mana Draught by default,
## any potion dragged onto them from the bag. A filled slot can be dragged onto
## another (move or swap) or out onto the world to empty it; right-click clears too.
## Spell slots are arranged the same way: drag one onto another to swap them, or
## drag a spell in from the skill window (V); the keys follow the slots
## (`spell_at`). Both are remembered per install (`user://quickslots.cfg`).
##
## Using a quick slot asks the authority to consume the item exactly like the
## bag does (`SimNet.submit_equipment(..., "consume", ...)`), so the server still
## decides whether it is allowed and what it restores.

const SLOT := 50.0
const GAP := 4.0
const GROUP_GAP := 18.0
const SPELLS := [
	["stupefy", "1"], ["incendio", "2"], ["bombarda", "3"],
	["expelliarmus", "4"], ["protego", "Q"], ["ultimate", "E"], ["patronum", "5"],
]
## The input action of each spell slot, in bar order.
const SPELL_ACTIONS := ["spell_1", "spell_2", "spell_3", "spell_4", "spell_q", "spell_e", "spell_5"]
const QUICK_KEYS := ["F1", "F2", "F3", "F4"]
const QUICK_ACTIONS := ["quickslot_1", "quickslot_2", "quickslot_3", "quickslot_4"]
const QUICK_DEFAULTS := ["potion_health", "potion_mana", "", ""]
const QUICK_COOLDOWN := 1.0
const SAVE_PATH := "user://quickslots.cfg"

var hud: Control = null
var player: Node3D = null
var spell_slots: Array[HudSlot] = []
var quick_slots: Array[HudSlot] = []
var quick_items: Array = ["", "", "", ""]
var _quick_cd: Array = [0.0, 0.0, 0.0, 0.0]
var _pending_slot := -1
## Which spell each slot holds (the player's hotkeys read it through spell_at).
static var spell_order: Array = []

## The spell on bar slot `index` (the default layout until the bar loads).
static func spell_at(index: int) -> String:
	if index >= 0 and index < spell_order.size():
		return String(spell_order[index])
	return String(SPELLS[index][0]) if index >= 0 and index < SPELLS.size() else ""

func _init() -> void:
	name = "ActionBar"
	mouse_filter = Control.MOUSE_FILTER_IGNORE

func _ready() -> void:
	_load_spells()
	for i in SPELLS.size():
		var s := HudSlot.new(SLOT)
		s.name = "SpellSlot%d" % (i + 1)
		s.key_text = String(SPELLS[i][1])
		s.accept_drop = _accept_spell_drop
		s.drag_slot_index = i
		s.drag_key = "spell_slot"
		s.keep_on_release = true
		s.item_dropped.connect(_on_spell_drop.bind(i))
		s.pressed.connect(func(): _cast(s.held_id))
		add_child(s)
		spell_slots.append(s)
	_show_spells()
	for i in range(4):
		var q := HudSlot.new(SLOT)
		q.name = "Quick%d" % (i + 1)
		q.key_text = QUICK_KEYS[i]
		q.empty_hint = "drop"
		q.accept_drop = _accept_quick_drop
		q.item_dropped.connect(_on_quick_drop.bind(i))
		q.cleared.connect(func(_s): _assign(i, ""))
		q.drag_slot_index = i
		q.drag_released.connect(func(_s): _assign(i, ""))
		var index := i
		q.pressed.connect(func(): use_quick(index))
		add_child(q)
		quick_slots.append(q)
	_load()
	for i in range(4):
		_ensure_action(QUICK_ACTIONS[i], [KEY_F1, KEY_F2, KEY_F3, KEY_F4][i])
	_layout()

func bind(p_hud: Control, p_player: Node3D) -> void:
	hud = p_hud
	if player != null and is_instance_valid(player) and player.equipment_answer.is_connected(_on_answer):
		player.equipment_answer.disconnect(_on_answer)
	player = p_player
	if player != null and not player.equipment_answer.is_connected(_on_answer):
		player.equipment_answer.connect(_on_answer)

func bar_width() -> float:
	return SLOT * float(SPELLS.size() + 4) + GAP * float(SPELLS.size() + 2) + GROUP_GAP

func _layout() -> void:
	custom_minimum_size = Vector2(bar_width(), SLOT)
	size = custom_minimum_size
	var x := 0.0
	for s in spell_slots:
		s.position = Vector2(x, 0)
		s.size = Vector2(SLOT, SLOT)
		x += SLOT + GAP
	x += GROUP_GAP - GAP
	for q in quick_slots:
		q.position = Vector2(x, 0)
		q.size = Vector2(SLOT, SLOT)
		x += SLOT + GAP

func _draw() -> void:
	# The deck plate: a dark bar with a lit gold top edge behind both groups.
	var plate := Rect2(Vector2(-12, -8), Vector2(size.x + 24, size.y + 16))
	draw_rect(plate, Color(0.02, 0.027, 0.043, 0.78))
	draw_rect(Rect2(plate.position, Vector2(plate.size.x, 1.5)), Color(HudKit.GOLD.r, HudKit.GOLD.g, HudKit.GOLD.b, 0.85))
	draw_rect(Rect2(Vector2(plate.position.x, plate.end.y - 1), Vector2(plate.size.x, 1)), Color(0, 0, 0, 0.8))
	# Divider between spells and quick slots.
	var dx := SLOT * SPELLS.size() + GAP * (SPELLS.size() - 1) + GROUP_GAP * 0.5
	draw_line(Vector2(dx, 2), Vector2(dx, size.y - 2), Color(HudKit.GOLD.r, HudKit.GOLD.g, HudKit.GOLD.b, 0.5), 1.0)
	# Corner studs.
	for p in [plate.position, Vector2(plate.end.x, plate.position.y)]:
		draw_circle(p + Vector2(0, 0.75), 3.0, HudKit.GOLD_LT)

func _process(delta: float) -> void:
	for i in range(4):
		_quick_cd[i] = maxf(0.0, float(_quick_cd[i]) - delta)
	if player == null or not is_instance_valid(player):
		return
	var dead: bool = player.is_dead
	for s in spell_slots:
		var spell_id := s.held_id
		var spell: Dictionary = GameData.SPELLS.get(spell_id, {})
		var cd: float = hud.cooldown_remaining(spell_id) if hud != null and hud.has_method("cooldown_remaining") else 0.0
		var trained: int = player.skill_level(spell_id)
		var total := maxf(0.01, HPRules.cooldown_for(spell_id, String(player.house), trained, player.derived_stats))
		s.set_cooldown(cd, cd / total)
		s.unusable = dead or int(player.current_mana) < int(spell.get("mana_cost", 0)) or trained <= 0
		s.badge_text = ("" if trained <= 0 else HPRules.skill_level_label(trained)) if HPRules.skill_upgradeable(spell_id) else ""
		var tip := _spell_tooltip(s.key_text, spell, trained, total)
		if s.tooltip_text != tip:
			s.tooltip_text = tip
	for i in range(4):
		var q := quick_slots[i]
		var id := String(quick_items[i])
		if q.held_id != id:
			q.held_id = id
			q.icon_texture = UITheme.icon_for(id) if id != "" else null
			q.tooltip_text = _item_tooltip(QUICK_KEYS[i], id)
		q.count = _count_of(id) if id != "" else -1
		q.unusable = dead or (id != "" and q.count <= 0)
		q.set_cooldown(float(_quick_cd[i]), float(_quick_cd[i]) / QUICK_COOLDOWN)

func _unhandled_input(event: InputEvent) -> void:
	if player == null or not is_instance_valid(player) or not player.is_local_player:
		return
	if not (event is InputEventKey) or not event.pressed or event.echo:
		return
	var focus := get_viewport().gui_get_focus_owner()
	if focus is LineEdit or focus is TextEdit or UIFocus.is_blocking(get_tree()):
		return
	for i in range(4):
		if event.is_action_pressed(QUICK_ACTIONS[i]):
			use_quick(i)
			get_viewport().set_input_as_handled()
			return

func _cast(spell_id: String) -> void:
	if player != null and is_instance_valid(player):
		player.cast_spell(spell_id)

## ------------------------------------------------------------- spell slots

func _show_spells() -> void:
	for i in spell_slots.size():
		var s := spell_slots[i]
		var id := spell_at(i)
		if s.held_id != id:
			s.held_id = id
			s.icon_texture = UITheme.spell_icon(id)
			s.tooltip_text = ""

## A spell from another slot (swap) or from the skill window (V).
func _accept_spell_drop(_slot: HudSlot, payload: Dictionary) -> bool:
	return payload.has("spell_slot") and GameData.SPELLS.has(String(payload.get("id", "")))

func _on_spell_drop(_slot: HudSlot, payload: Dictionary, index: int) -> void:
	place_spell(String(payload.get("id", "")), index)

## Put `spell_id` on slot `index`; the spell that was there moves to the slot
## the dropped one came from, so every spell stays on the bar exactly once.
func place_spell(spell_id: String, index: int) -> void:
	var from := spell_order.find(spell_id)
	if from == index or index < 0 or index >= spell_order.size():
		return
	if from >= 0:
		spell_order[from] = spell_order[index]
	spell_order[index] = spell_id
	_show_spells()
	_save()

func _load_spells() -> void:
	var defaults: Array = SPELLS.map(func(spec): return String(spec[0]))
	spell_order = defaults.duplicate()
	var cfg := ConfigFile.new()
	if cfg.load(SAVE_PATH) != OK:
		return
	var saved = cfg.get_value("spells", "order", [])
	# Only a full permutation of today's spells is trusted (a new spell or a
	# removed one falls back to the default layout).
	if saved is Array and saved.size() == defaults.size():
		var sorted_saved: Array = (saved as Array).duplicate()
		var sorted_defaults: Array = defaults.duplicate()
		sorted_saved.sort()
		sorted_defaults.sort()
		if sorted_saved == sorted_defaults:
			spell_order = (saved as Array).duplicate()

## ------------------------------------------------------------- quick slots

func use_quick(index: int) -> void:
	if player == null or not is_instance_valid(player) or player.is_dead:
		return
	var id := String(quick_items[index])
	if id == "":
		_notice("Drag a potion from your bag onto %s" % QUICK_KEYS[index], "info")
		return
	if float(_quick_cd[index]) > 0.0:
		return
	var entry := _entry_of(id)
	if entry.is_empty():
		_notice("No %s left" % _item_name(id), "error")
		return
	var data: Dictionary = HPEquipment.item(id)
	if String(data.get("type", "")) != "consumable":
		return
	var hp_potion := data.has("heal_hp")
	if hp_potion and int(player.current_hp) >= int(player.max_hp):
		_notice("Health is already full", "info")
		return
	if data.has("heal_mana") and int(player.current_mana) >= int(player.max_mana):
		_notice("Mana is already full", "info")
		return
	_quick_cd[index] = QUICK_COOLDOWN
	_pending_slot = index
	SimNet.submit_equipment(player, "consume", "", id, int(entry.get("tier", 0)))

func _on_answer(answer: Dictionary) -> void:
	if _pending_slot < 0:
		return
	_pending_slot = -1
	var reason := String(answer.get("reason", ""))
	if bool(answer.get("ok", false)):
		var audio := get_node_or_null("/root/AudioManager")
		if audio != null:
			if audio.has_method("play_potion"):
				audio.play_potion()
			else:
				audio.play_sound_at("ui_potion", Vector3.ZERO, null, true)
		return
	var words := {"resource_full": "Already full", "item_missing": "None left", "casting": "Finish casting first",
		"dead": "You are defeated", "stale_inventory": "", "stale_request": "", "transfer_pending": "Wait until the map loads"}
	var text := String(words.get(reason, "Cannot use that now"))
	if text != "":
		_notice(text, "error")

func _accept_quick_drop(_slot: HudSlot, payload: Dictionary) -> bool:
	var id := String(payload.get("id", ""))
	return id != "" and String(HPEquipment.item(id).get("type", "")) == "consumable"

func _on_quick_drop(_slot: HudSlot, payload: Dictionary, index: int) -> void:
	var from := int(payload.get("quick_slot", -1))
	if from >= 0 and from < 4:
		move_quick(from, index)
		return
	_assign(index, String(payload.get("id", "")))

## Drag between quick slots: the item moves, and whatever the target held goes
## back to the source slot (a swap), so nothing is ever lost from the bar.
func move_quick(from: int, to: int) -> void:
	if from == to:
		return
	var moving := String(quick_items[from])
	quick_items[from] = quick_items[to]
	quick_items[to] = moving
	var cd = _quick_cd[from]
	_quick_cd[from] = _quick_cd[to]
	_quick_cd[to] = cd
	_save()

func _assign(index: int, id: String) -> void:
	# One item per bar: dropping it on a new slot moves it.
	if id != "":
		for i in range(4):
			if i != index and String(quick_items[i]) == id:
				quick_items[i] = ""
	quick_items[index] = id
	_save()

func _count_of(id: String) -> int:
	var total := 0
	if player == null:
		return 0
	for e in player.inventory:
		if String(e.get("id", "")) == id:
			total += int(e.get("amount", 1))
	return total

func _entry_of(id: String) -> Dictionary:
	for e in player.inventory:
		if String(e.get("id", "")) == id and int(e.get("amount", 1)) > 0:
			return e
	return {}

func _item_name(id: String) -> String:
	return String(HPEquipment.item(id).get("name", id))

func _notice(text: String, kind: String) -> void:
	if hud != null and hud.has_method("show_notice"):
		hud.show_notice(text, kind)

func _spell_tooltip(key: String, spell: Dictionary, trained: int = 1, cooldown: float = -1.0) -> String:
	if spell.is_empty():
		return ""
	var grade := "Master" if HPRules.skill_is_master(trained) else "Level %d" % trained
	return "[%s] %s  ·  %s\n%d mana · %.1fs cooldown\n%s\nDrag onto another slot to swap  ·  [V] Skills" % [key, spell.get("name", ""), grade,
		int(spell.get("mana_cost", 0)), cooldown if cooldown >= 0.0 else float(spell.get("cooldown", 0.0)), spell.get("desc", "")]

func _item_tooltip(key: String, id: String) -> String:
	if id == "":
		return "[%s] Quick slot\nDrag a potion here from your bag (I).\nDrag a slot onto another to swap, or off the bar to clear it." % key
	var data: Dictionary = HPEquipment.item(id)
	return "[%s] %s\n%s\nDrag to move or swap; drag off the bar or right-click to clear." % [key, data.get("name", id), data.get("desc", "")]

func _ensure_action(action: String, keycode: int) -> void:
	if not InputMap.has_action(action):
		InputMap.add_action(action)
	if InputMap.action_get_events(action).is_empty():
		var ev := InputEventKey.new()
		ev.physical_keycode = keycode
		InputMap.action_add_event(action, ev)

func _load() -> void:
	var cfg := ConfigFile.new()
	if cfg.load(SAVE_PATH) == OK:
		for i in range(4):
			quick_items[i] = String(cfg.get_value("quick", "slot%d" % (i + 1), QUICK_DEFAULTS[i]))
	else:
		quick_items = QUICK_DEFAULTS.duplicate()

func _save() -> void:
	var cfg := ConfigFile.new()
	for i in range(4):
		cfg.set_value("quick", "slot%d" % (i + 1), quick_items[i])
	cfg.set_value("spells", "order", spell_order)
	cfg.save(SAVE_PATH)
