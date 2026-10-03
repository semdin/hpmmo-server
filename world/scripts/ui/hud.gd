extends Control

## Metin2-style HUD for HPMMO
## HP/Mana orbs & bars, EXP progress, spell hotbar with cooldowns, target frame, and chat

@onready var hp_bar: ProgressBar = $BottomBar/StatusBars/HpBar
@onready var hp_label: Label = $BottomBar/StatusBars/HpBar/HpLabel
@onready var mana_bar: ProgressBar = $BottomBar/StatusBars/ManaBar
@onready var mana_label: Label = $BottomBar/StatusBars/ManaBar/ManaLabel
@onready var exp_bar: ProgressBar = $ExpBar
@onready var exp_label: Label = $ExpBar/ExpLabel
@onready var level_label: Label = $BottomBar/StatusBars/LevelLabel

# Target Frame
@onready var target_panel: Panel = $TargetPanel
@onready var target_name_label: Label = $TargetPanel/TargetName
@onready var target_hp_bar: ProgressBar = $TargetPanel/TargetHpBar

# Hotbar Buttons & Cooldowns
@onready var slot_1: Button = $BottomBar/Hotbar/Slot1
@onready var slot_2: Button = $BottomBar/Hotbar/Slot2
@onready var slot_3: Button = $BottomBar/Hotbar/Slot3
@onready var slot_4: Button = $BottomBar/Hotbar/Slot4
@onready var slot_q: Button = $BottomBar/Hotbar/SlotQ
@onready var slot_e: Button = $BottomBar/Hotbar/SlotE

# Quick Bar
@onready var inventory_button: Button = $BottomBar/QuickBar/InvBtn
@onready var ollivander_button: Button = $BottomBar/QuickBar/OllivanderBtn
@onready var mount_button: Button = $BottomBar/QuickBar/MountBtn

# Chat
@onready var chat_history: RichTextLabel = $ChatContainer/ChatHistory
@onready var chat_input: LineEdit = $ChatContainer/ChatInput

var player: Node3D = null
var current_target: Node3D = null
var _currency: Label
var _last_galleons := -1

func _ready() -> void:
	target_panel.hide()
	_apply_theme()
	_currency = Label.new()
	_currency.position = Vector2(20, 16)
	_currency.add_theme_color_override("font_color", Color(1, 0.83, 0.43))
	_currency.add_theme_font_size_override("font_size", 16)
	_currency.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(_currency)
	chat_input.text_submitted.connect(_on_chat_submitted)
	NetworkManager.chat_message_received.connect(_on_chat_received)
	
	slot_1.pressed.connect(func(): _trigger_player_spell("stupefy"))
	slot_2.pressed.connect(func(): _trigger_player_spell("incendio"))
	slot_3.pressed.connect(func(): _trigger_player_spell("bombarda"))
	slot_4.pressed.connect(func(): _trigger_player_spell("expelliarmus"))
	slot_q.pressed.connect(func(): _trigger_player_spell("protego"))
	slot_e.pressed.connect(func(): _trigger_player_spell("ultimate"))
	
	mount_button.pressed.connect(func(): if is_instance_valid(player): player.toggle_broom_mount())
	
	_add_system_chat("Welcome to HPMMO! Cast spells with 1-4, Q, E. Shift mounts/dismounts. Space rises, Ctrl descends.")
	_add_system_chat("Target Dark Monoliths and mobs with Left Click or Tab. Destroy Monoliths for massive loot!")

func bind_player(p_player: Node3D) -> void:
	if player == p_player:
		player.emit_stats()
		return
	if is_instance_valid(player):
		player.stats_changed.disconnect(_on_stats_changed)
		player.target_changed.disconnect(_on_target_changed)
		player.spell_cast_signal.disconnect(_on_spell_cast)
		player.mounted_changed.disconnect(_on_mounted_changed)
		player.loot_collected_signal.disconnect(_on_loot_collected)
	player = p_player
	player.stats_changed.connect(_on_stats_changed)
	player.target_changed.connect(_on_target_changed)
	player.spell_cast_signal.connect(_on_spell_cast)
	player.mounted_changed.connect(_on_mounted_changed)
	player.loot_collected_signal.connect(_on_loot_collected)
	player.emit_stats()

func _trigger_player_spell(spell_id: String) -> void:
	if is_instance_valid(player):
		player.cast_spell(spell_id)

func _on_stats_changed(hp: int, max_hp: int, mana: int, max_mana: int, exp: int, max_exp: int, level: int) -> void:
	hp_bar.max_value = max_hp
	hp_bar.value = hp
	hp_label.text = "%d / %d" % [hp, max_hp]
	
	mana_bar.max_value = max_mana
	mana_bar.value = mana
	mana_label.text = "%d / %d" % [mana, max_mana]
	
	exp_bar.max_value = max_exp
	exp_bar.value = exp
	var exp_pct = int((float(exp) / float(max_exp)) * 100.0)
	exp_label.text = "EXP: %d / %d (%d%%)" % [exp, max_exp, exp_pct]
	
	level_label.text = "Lv. %d" % level

func _on_target_changed(target: Node3D) -> void:
	current_target = target
	if not is_instance_valid(target):
		target_panel.hide()
		return
	
	target_panel.show()
	_update_target_frame()

func _process(delta: float) -> void:
	# Update target frame continuous HP
	if is_instance_valid(current_target) and target_panel.visible:
		_update_target_frame()
	elif not is_instance_valid(current_target) and target_panel.visible:
		target_panel.hide()
	
	# Update cooldown numbers on hotbar
	if is_instance_valid(player):
		if _last_galleons != player.galleons:
			_last_galleons = player.galleons
			_currency.text = "%s  •  %s  •  %d Galleons" % [player.player_name, player.house, player.galleons]
		_update_slot_cd(slot_1, "stupefy", "1")
		_update_slot_cd(slot_2, "incendio", "2")
		_update_slot_cd(slot_3, "bombarda", "3")
		_update_slot_cd(slot_4, "expelliarmus", "4")
		_update_slot_cd(slot_q, "protego", "Q")
		_update_slot_cd(slot_e, "ultimate", "E")

func _update_slot_cd(slot: Button, spell_id: String, key_hint: String) -> void:
	var cd = player.spell_cooldowns.get(spell_id, 0.0)
	slot.disabled = player.is_dead
	slot.tooltip_text = "%s\n%d mana • %.1fs cooldown\n%s" % [GameData.SPELLS[spell_id].name, GameData.SPELLS[spell_id].mana_cost, GameData.SPELLS[spell_id].cooldown, GameData.SPELLS[spell_id].desc]
	if cd > 0.0:
		slot.text = "[%s]\n%.1fs" % [key_hint, cd]
		slot.modulate = Color(0.6, 0.6, 0.6, 0.8)
	else:
		slot.text = "[%s]\n%s" % [key_hint, GameData.SPELLS[spell_id].name]
		slot.modulate = Color(1.0, 1.0, 1.0, 1.0)

func _update_target_frame() -> void:
	if not is_instance_valid(current_target) or ("current_hp" in current_target and current_target.current_hp <= 0):
		target_panel.hide()
		return
	
	if "mob_name" in current_target:
		var is_boss_target: bool = "is_boss" in current_target and current_target.is_boss
		var is_enraged_target: bool = "is_enraged" in current_target and current_target.is_enraged
		if is_boss_target:
			target_name_label.text = "👑 [WORLD BOSS] %s (Lv.%d)" % [current_target.mob_name, current_target.level]
			target_name_label.modulate = Color(1.0, 0.85, 0.2)
			target_hp_bar.modulate = Color(1.0, 0.15, 0.15)
		elif is_enraged_target:
			target_name_label.text = "🔥 [ENRAGED] %s (Lv.%d)" % [current_target.mob_name, current_target.level]
			target_name_label.modulate = Color(1.0, 0.3, 0.1)
			target_hp_bar.modulate = Color(1.0, 0.3, 0.1)
		else:
			target_name_label.text = "[Lv.%d] %s" % [current_target.level, current_target.mob_name]
			target_name_label.modulate = Color(1.0, 1.0, 1.0)
			target_hp_bar.modulate = Color(1.0, 0.3, 0.3)
		target_hp_bar.max_value = current_target.max_hp
		target_hp_bar.value = current_target.current_hp
	elif current_target.is_in_group("monoliths"):
		target_name_label.text = "Dark Monolith (Lv.35)"
		target_name_label.modulate = Color(0.8, 0.4, 1.0)
		target_hp_bar.modulate = Color(0.8, 0.4, 1.0)
		target_hp_bar.max_value = current_target.max_hp
		target_hp_bar.value = current_target.current_hp
	elif "current_hp" in current_target and "max_hp" in current_target:
		target_name_label.text = "Training Dummy"
		target_name_label.modulate = Color(0.8, 0.9, 0.8)
		target_hp_bar.max_value = current_target.max_hp
		target_hp_bar.value = current_target.current_hp

func _on_mounted_changed(is_mounted: bool) -> void:
	mount_button.text = "Dismount" if is_mounted else "Nimbus"

func _on_loot_collected(item_id: String, amount: int) -> void:
	if item_id == "galleons":
		_add_system_chat("Collected %d Galleons." % amount)
	elif GameData.ITEMS.has(item_id):
		_add_system_chat("Obtained %s (x%d)." % [GameData.ITEMS[item_id].name, amount])

func _on_spell_cast(spell_id: String, cd: float) -> void:
	pass

func _on_chat_submitted(text: String) -> void:
	if text.strip_edges().is_empty():
		chat_input.release_focus()
		return
	NetworkManager.send_chat(text)
	chat_input.clear()
	chat_input.release_focus()

func _on_chat_received(sender_name: String, sender_house: String, message: String) -> void:
	var color_hex = "ffffff"
	if GameData.HOUSES.has(sender_house):
		color_hex = GameData.HOUSES[sender_house].primary_color.to_html(false)
	
	var line = "[color=#%s][%s] %s:[/color] %s\n" % [color_hex, sender_house, sender_name, message]
	chat_history.append_text(line)

func _add_system_chat(msg: String) -> void:
	chat_history.append_text("[color=#e6b800][System] %s[/color]\n" % msg)

func _apply_theme() -> void:
	var theme := Theme.new()
	var panel := StyleBoxFlat.new()
	panel.bg_color = Color(0.025, 0.04, 0.065, 0.94)
	panel.border_color = Color(0.5, 0.41, 0.24, 0.8)
	panel.set_border_width_all(1)
	panel.set_corner_radius_all(6)
	panel.content_margin_left = 8
	panel.content_margin_right = 8
	panel.content_margin_top = 6
	panel.content_margin_bottom = 6
	theme.set_stylebox("normal", "Button", panel)
	var hover := panel.duplicate() as StyleBoxFlat
	hover.bg_color = Color(0.14, 0.18, 0.23, 0.97)
	hover.border_color = Color(0.95, 0.76, 0.4)
	theme.set_stylebox("hover", "Button", hover)
	theme.set_stylebox("pressed", "Button", hover)
	theme.set_stylebox("disabled", "Button", panel)
	theme.set_color("font_color", "Button", Color(0.96, 0.9, 0.75))
	theme.set_font_size("font_size", "Button", 12)
	self.theme = theme
	for slot in [slot_1, slot_2, slot_3, slot_4, slot_q, slot_e]:
		slot.remove_theme_stylebox_override("normal")
		slot.focus_mode = Control.FOCUS_NONE
	for control in [hp_bar, mana_bar, exp_bar, target_panel]:
		control.mouse_filter = Control.MOUSE_FILTER_IGNORE
