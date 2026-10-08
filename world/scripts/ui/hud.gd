extends Control

## Metin2-style HUD for HPMMO
## HP/Mana orbs & bars, EXP progress, spell hotbar with cooldowns, target frame, and chat
##
## The widget values are bound to the authoritative state model
## through `UIStateBinder` - one subscription point that connects to the
## authority's stat payloads and entity deltas and disconnects cleanly on
## rebind and tree exit. Bars keep an instant authoritative readout plus a
## tween-safe animation layer (`StatBar`), and the panels below add cast
## feedback, status and safe-area indication, death/respawn, travel and
## staircase state, the maintenance countdown, the onboarding route and the
## settings screen.

## Layout grid, in canvas (1280x720) pixels. See `UITheme` for the shared inset
## and column widths; the deck numbers come from there too so this file cannot
## drift from the overlay that has to sit clear of it.
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
@onready var chat_history: RichTextLabel = $ChatContainer/Margin/Chat/ChatHistory
@onready var chat_input: LineEdit = $ChatContainer/Margin/Chat/ChatInput

var player: Node3D = null
var current_target: Node3D = null
var _currency: Label
var _house_crest: TextureRect
var _target_icon: TextureRect = null
var _target_status_icon: TextureRect = null
var _last_galleons := -1

## The authoritative binding and the panels it feeds.
var binder: UIStateBinder = null
var feedback: CombatFeedback = null
var travel: TravelFeedback = null
var maintenance: MaintenanceUI = null
var onboarding: OnboardingUI = null
var settings: SettingsUI = null

var _hp_stat: StatBar = null
var _mana_stat: StatBar = null
var _exp_stat: StatBar = null
var _target_stat: StatBar = null
var _stats_seen: int = 0
## True once an authoritative payload has carried currency: the mirror's
## per-frame value is no longer allowed to overwrite it.
var _galleons_from_authority := false

func _ready() -> void:
	target_panel.hide()
	_apply_theme()
	_build_player_plate()
	_build_chat_badge()
	chat_input.text_submitted.connect(_on_chat_submitted)
	NetworkManager.chat_message_received.connect(_on_chat_received)

	slot_1.pressed.connect(func(): _trigger_player_spell("stupefy"))
	slot_2.pressed.connect(func(): _trigger_player_spell("incendio"))
	slot_3.pressed.connect(func(): _trigger_player_spell("bombarda"))
	slot_4.pressed.connect(func(): _trigger_player_spell("expelliarmus"))
	slot_q.pressed.connect(func(): _trigger_player_spell("protego"))
	slot_e.pressed.connect(func(): _trigger_player_spell("ultimate"))

	mount_button.pressed.connect(func(): if is_instance_valid(player): player.toggle_broom_mount())

	_setup_panels()
	_build_arcane_layout()
	_add_system_chat("Welcome to HPMMO! Cast spells with 1-4, Q, E. Shift mounts/dismounts. Space rises, Ctrl descends.")
	_add_system_chat("Target Dark Monoliths and mobs with Left Click or Tab. Destroy Monoliths for massive loot!")

## Interface wiring: the animation layers, the authoritative binder and the
## panels. Built at runtime so the scene file keeps its node paths (other
## systems and the walkthrough depend on them).
func _setup_panels() -> void:
	_hp_stat = StatBar.new().attach(self, hp_bar)
	_mana_stat = StatBar.new().attach(self, mana_bar)
	_exp_stat = StatBar.new().attach(self, exp_bar)
	_target_stat = StatBar.new().attach(self, target_hp_bar)

	binder = UIStateBinder.new()
	binder.name = "StateBinder"
	add_child(binder)
	binder.stats_applied.connect(_on_binder_stats)
	binder.target_changed.connect(_on_target_changed)
	binder.target_health_changed.connect(_on_target_health)
	binder.cast_rejected.connect(_on_cast_rejected)
	binder.death_changed.connect(_on_death_sound)
	binder.level_changed.connect(_on_level_sound)

	feedback = CombatFeedback.new()
	feedback.name = "CombatFeedback"
	add_child(feedback)
	feedback.setup(binder, null)

	travel = TravelFeedback.new()
	travel.name = "TravelFeedback"
	add_child(travel)

	maintenance = MaintenanceUI.new()
	maintenance.name = "MaintenanceUI"
	add_child(maintenance)
	maintenance.setup(binder)

	onboarding = OnboardingUI.new()
	onboarding.name = "OnboardingUI"
	add_child(onboarding)

	settings = SettingsUI.new()
	settings.name = "SettingsUI"
	add_child(settings)

	_add_quick_button("SettingsBtn", "ui_settings", "Settings", "[F1] Settings", func(): settings.toggle())
	_add_quick_button("JournalBtn", "ui_journal", "Guide", "[J] Guide", func(): onboarding.toggle_panel())
	_ensure_ui_action("toggle_settings", KEY_F1)
	_ensure_ui_action("toggle_onboarding", KEY_J)

## Name, house and purse, on a small brass plate in the top-left corner.
## Previously a bare label that overlapped the chat log.
func _build_player_plate() -> void:
	var plate := PanelContainer.new()
	plate.name = "PlayerPlate"
	plate.mouse_filter = Control.MOUSE_FILTER_IGNORE
	plate.set_anchors_preset(Control.PRESET_TOP_LEFT)
	plate.offset_left = 14.0
	plate.offset_top = 12.0
	add_child(plate)

	var margin := MarginContainer.new()
	for side in ["left", "right", "top", "bottom"]:
		margin.add_theme_constant_override("margin_" + side, 5)
	margin.mouse_filter = Control.MOUSE_FILTER_IGNORE
	plate.add_child(margin)

	_currency = Label.new()
	_currency.add_theme_font_override("font", UITheme.font_body_bold())
	_currency.add_theme_color_override("font_color", UITheme.c("gold_lt"))
	_currency.add_theme_color_override("font_outline_color", UITheme.c("shadow"))
	_currency.add_theme_constant_override("outline_size", 4)
	_currency.add_theme_font_size_override("font_size", UITheme.FS_BODY)
	_currency.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_currency.text = "—"

	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 5)
	row.mouse_filter = Control.MOUSE_FILTER_IGNORE
	margin.add_child(row)
	_house_crest = UITheme.icon_rect("house_gryffindor", 28.0)
	row.add_child(_house_crest)
	row.add_child(_currency)


## The chat log's badge, pinned over the top-left corner of its frame so the box
## reads as the chat without adding a header row inside it (which would have to
## steal height from the log itself).
func _build_chat_badge() -> void:
	var chat := get_node_or_null("ChatContainer") as Control
	if chat == null:
		return
	var badge := UITheme.icon_rect("ui_chat", 18.0)
	badge.name = "ChatBadge"
	badge.set_anchors_preset(Control.PRESET_TOP_LEFT)
	badge.position = chat.position + Vector2(2.0, -9.0)
	add_child(badge)


## A quick action: the icon carries the meaning, the caption names it and the
## tooltip keeps the hotkey, which no longer has to fit inside the button.
func _add_quick_button(button_name: String, icon_id: String, text: String, tip: String, action: Callable) -> void:
	var quick := get_node_or_null("BottomBar/QuickBar")
	if quick == null:
		return
	var button := Button.new()
	button.name = button_name
	button.text = text
	button.tooltip_text = tip
	button.custom_minimum_size = Vector2(88, 26)
	button.add_theme_font_size_override("font_size", 12)
	button.focus_mode = Control.FOCUS_NONE
	button.pressed.connect(action)
	UITheme.set_button_icon(button, icon_id)
	quick.add_child(button)

func _ensure_ui_action(action: String, keycode: int) -> void:
	if InputMap.has_action(action):
		return
	InputMap.add_action(action)
	var event := InputEventKey.new()
	event.physical_keycode = keycode
	InputMap.action_add_event(action, event)

func _unhandled_input(event: InputEvent) -> void:
	if event.is_action_pressed("toggle_settings"):
		if settings != null:
			settings.toggle()
		get_viewport().set_input_as_handled()
	elif event.is_action_pressed("toggle_onboarding"):
		if onboarding != null:
			onboarding.toggle_panel()
		get_viewport().set_input_as_handled()

func bind_player(p_player: Node3D) -> void:
	if player == p_player and binder != null and binder.player == p_player:
		player.emit_stats()
		return
	player = p_player
	if binder != null:
		binder.bind(player)
	if feedback != null:
		feedback.player = player
	var world := _find_world()
	if travel != null:
		travel.setup(player, world)
	if onboarding != null:
		onboarding.setup(binder, player, world)
	# A fresh life starts from the server's numbers, never from the last body's
	# half-animated bar.
	if _hp_stat != null:
		_hp_stat.snap()
	if _mana_stat != null:
		_mana_stat.snap()
	if _exp_stat != null:
		_exp_stat.snap()
	if _target_stat != null:
		_target_stat.snap()
	_last_galleons = -1
	_galleons_from_authority = false
	player.emit_stats()

func _find_world() -> Node3D:
	var node: Node = get_parent()
	while node != null:
		if node is Node3D and "local_player" in node:
			return node as Node3D
		node = node.get_parent()
	return null

## Called cleanly when the world (and this HUD) goes away, and on rebind.
func _exit_tree() -> void:
	if binder != null and is_instance_valid(binder):
		binder.unbind()

func _trigger_player_spell(spell_id: String) -> void:
	if is_instance_valid(player):
		player.cast_spell(spell_id)

## ------------------------------------------------- the interface: authoritative

## One entry point for stat payloads: the authority's `stats_changed` (primary)
## and the mirror's own signal (same numbers) both land here, so the widgets
## only ever have one writer.
func _on_binder_stats(stats: Dictionary) -> void:
	_stats_seen += 1
	var hp := int(stats.get("hp", 0))
	var max_hp := int(stats.get("max_hp", 1))
	var mana := int(stats.get("mana", 0))
	var max_mana := int(stats.get("max_mana", 1))
	var exp := int(stats.get("exp", 0))
	var max_exp := int(stats.get("max_exp", 1))
	var level := int(stats.get("level", 1))
	_hp_stat.set_value(hp, max_hp)
	hp_label.text = "%d / %d" % [hp, max_hp]
	_mana_stat.set_value(mana, max_mana)
	mana_label.text = "%d / %d" % [mana, max_mana]
	_exp_stat.set_value(exp, max_exp)
	var exp_pct := int((float(exp) / maxf(1.0, float(max_exp))) * 100.0)
	exp_label.text = "EXP: %d / %d (%d%%)" % [exp, max_exp, exp_pct]
	level_label.text = "Lv. %d" % level
	var galleons := int(stats.get("galleons", -1))
	if String(stats.get("source", "")) == "authority":
		# Once the server has spoken about currency, its number is the one the
		# HUD shows; the per-frame mirror sync below is only for sessions where
		# no stat payload has arrived yet.
		_galleons_from_authority = true
	if galleons >= 0:
		_last_galleons = galleons
		_update_currency()
	# Mount and life state are applied by the mirror itself
	# (`apply_authoritative_stats` calls `_apply_mount_state` / the death and
	# respawn transitions before this signal fires), so the HUD only displays
	# them - it never writes gameplay state back onto the body.

func _on_stats_changed(hp: int, max_hp: int, mana: int, max_mana: int, exp: int, max_exp: int, level: int) -> void:
	# Kept as the mirror's direct entry point (tests and other systems call
	# `emit_stats`); it applies exactly the same numbers to the same widgets.
	_on_binder_stats({
		"hp": hp, "max_hp": max_hp, "mana": mana, "max_mana": max_mana,
		"exp": exp, "max_exp": max_exp, "level": level,
		"galleons": int(player.galleons) if is_instance_valid(player) else -1,
		"dead": bool(player.is_dead) if is_instance_valid(player) else false,
		"mounted": bool(player.is_mounted) if is_instance_valid(player) else false,
	})

func _update_currency() -> void:
	if not is_instance_valid(player):
		return
	_currency.text = "%s · %s\n%d Galleons" % [player.player_name, player.house, _last_galleons]
	_house_crest.texture = UITheme.chrome("house_" + player.house.to_lower())

func _on_target_health(_uid: int, hp: int, max_hp: int) -> void:
	_target_stat.set_value(hp, max_hp)
	target_hp_bar.tooltip_text = "%d / %d" % [hp, max_hp]

func _on_cast_rejected(_cast_seq: int, _spell_id: String, _reason: String) -> void:
	_play_ui("ui_deny")

func _on_death_sound(is_dead: bool) -> void:
	if is_dead:
		_play_ui("ui_cancel")

func _on_level_sound(_level: int) -> void:
	_play_ui("ui_levelup")

func _play_ui(key: String) -> void:
	var audio := get_node_or_null("/root/AudioManager")
	if audio != null and audio.has_method("play_sound_at"):
		audio.call("play_sound_at", key, Vector3.ZERO, null, true)

## Cooldown remaining for a spell, preferring the authority's tick deadline
## over the locally predicted mirror.
func cooldown_remaining(spell_id: String) -> float:
	if binder != null:
		var record := binder.record_for_local()
		var cooldowns = record.get("cooldowns", {})
		if cooldowns is Dictionary:
			var until := int(cooldowns.get(spell_id, 0))
			if until > int(SimAuthority.sim_tick):
				return float(until - int(SimAuthority.sim_tick)) * float(HPProtocol.SIM_DT)
	if is_instance_valid(player):
		return float(player.spell_cooldowns.get(spell_id, 0.0))
	return 0.0

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
		if not _galleons_from_authority and _last_galleons != player.galleons:
			_last_galleons = player.galleons
			_update_currency()
		_update_slot_cd(slot_1, "stupefy", "1")
		_update_slot_cd(slot_2, "incendio", "2")
		_update_slot_cd(slot_3, "bombarda", "3")
		_update_slot_cd(slot_4, "expelliarmus", "4")
		_update_slot_cd(slot_q, "protego", "Q")
		_update_slot_cd(slot_e, "ultimate", "E")

## A hotbar cell shows the spell's icon and its hotkey, and veils itself while
## the spell is on cooldown. The spell's name and numbers live in the tooltip.
func _update_slot_cd(slot: Button, spell_id: String, key_hint: String) -> void:
	var cd := cooldown_remaining(spell_id)
	var spell: Dictionary = GameData.SPELLS[spell_id]
	var cell := slot as UISlot
	if cell != null:
		if cell.item_id != spell_id:
			cell.key_hint = key_hint
			cell.set_item(spell_id, {})
		cell.set_cooldown(cd, cd / maxf(float(spell.cooldown), 0.01))
	slot.disabled = player.is_dead
	slot.modulate = Color(0.62, 0.62, 0.62, 0.85) if player.is_dead else Color.WHITE
	slot.tooltip_text = "[%s] %s\n%d mana • %.1fs cooldown\n%s" % [
		key_hint, spell.name, spell.mana_cost, spell.cooldown, spell.desc]

func _update_target_frame() -> void:
	if not is_instance_valid(current_target) or ("current_hp" in current_target and current_target.current_hp <= 0):
		target_panel.hide()
		return
	if _target_status_icon != null:
		_target_status_icon.visible = _target_is_weakened()

	if "mob_name" in current_target:
		var is_boss_target: bool = "is_boss" in current_target and current_target.is_boss
		var is_enraged_target: bool = "is_enraged" in current_target and current_target.is_enraged
		if is_boss_target:
			target_name_label.text = "[WORLD BOSS] %s (Lv.%d)" % [current_target.mob_name, current_target.level]
			target_name_label.modulate = Color(1.0, 0.85, 0.2)
			target_hp_bar.modulate = Color(1.0, 0.15, 0.15)
			_set_target_icon("ui_boss")
		elif is_enraged_target:
			target_name_label.text = "[ENRAGED] %s (Lv.%d)" % [current_target.mob_name, current_target.level]
			target_name_label.modulate = Color(1.0, 0.3, 0.1)
			target_hp_bar.modulate = Color(1.0, 0.3, 0.1)
			_set_target_icon("status_enraged")
		else:
			target_name_label.text = "[Lv.%d] %s" % [current_target.level, current_target.mob_name]
			target_name_label.modulate = Color(1.0, 1.0, 1.0)
			target_hp_bar.modulate = Color(1.0, 0.3, 0.3)
			_set_target_icon("ui_target")
		_target_stat.set_value(_target_hp_value(), _target_max_hp_value())
	elif current_target.is_in_group("monoliths"):
		target_name_label.text = "Dark Monolith (Lv.35)"
		target_name_label.modulate = Color(0.8, 0.4, 1.0)
		target_hp_bar.modulate = Color(0.8, 0.4, 1.0)
		_set_target_icon("minimap_monolith")
		_target_stat.set_value(_target_hp_value(), _target_max_hp_value())
	elif "current_hp" in current_target and "max_hp" in current_target:
		target_name_label.text = "Training Dummy"
		target_name_label.modulate = Color(0.8, 0.9, 0.8)
		_set_target_icon("ui_target")
		_target_stat.set_value(_target_hp_value(), _target_max_hp_value())

## Prefer the authority's health delta for this target; fall back to the node
## only when the authority has not spoken about it (a local dummy in a test).
func _target_hp_value() -> int:
	if binder != null and binder.has_target_health():
		return binder.target_hp()
	if "current_hp" in current_target:
		return int(current_target.current_hp)
	return 0

func _target_max_hp_value() -> int:
	if binder != null and binder.has_target_health():
		return binder.target_max_hp()
	if "max_hp" in current_target:
		return int(current_target.max_hp)
	return 1

func _on_mounted_changed(is_mounted: bool) -> void:
	mount_button.text = "Dismount" if is_mounted else "Mount"


## The target frame's icon: a crown for a world boss, the enraged eye for an
## angry elite, the crosshair for anything else, the monolith spike for a
## monolith. One holder, swapped as the target changes.
func _set_target_icon(id: String) -> void:
	if _target_icon != null:
		_target_icon.texture = UITheme.chrome(id)


## True while Expelliarmus still has the target's attack power cut. The mirror
## carries the timer on the body; anything without it simply is not weakened.
func _target_is_weakened() -> bool:
	if not is_instance_valid(current_target):
		return false
	if "_weaken_timer" in current_target:
		return float(current_target.get("_weaken_timer")) > 0.0
	return false

func _on_loot_collected(item_id: String, amount: int) -> void:
	if item_id == "galleons":
		_add_system_chat("Collected %d Galleons." % amount)
	elif GameData.ITEMS.has(item_id):
		_add_system_chat("Obtained %s (x%d)." % [GameData.ITEMS[item_id].name, amount])

func _on_spell_cast(spell_id: String, cd: float) -> void:
	pass

## Listener evidence for the interface checks: every subscription this HUD holds
## through its binder, plus the panel-owned ones.
## Layout evidence: where each the interface panel actually sits, at the current
## window size. Used by the captures and by the scalable-UI check.
func layout_report() -> Dictionary:
	var panel_list := {
		"cast": feedback._cast_panel if feedback != null else null,
		"feedback": feedback._feedback_label if feedback != null else null,
		"status": feedback._status_label if feedback != null else null,
		"toasts": feedback._toast_box.get_parent() if feedback != null and feedback._toast_box != null else null,
		"location": travel._location_label if travel != null else null,
		"portal": travel._portal_panel if travel != null else null,
		"stairs": travel._stairs_panel if travel != null else null,
		"mounted": travel._mounted_panel if travel != null else null,
		"maintenance": maintenance._panel if maintenance != null else null,
		"onboarding": onboarding._panel if onboarding != null else null,
		"settings": settings.panel if settings != null else null,
	}
	var out := {}
	for key in panel_list:
		var control = panel_list[key]
		if control is Control and is_instance_valid(control):
			out[key] = Rect2((control as Control).global_position, (control as Control).size)
	return out

func listener_report() -> Dictionary:
	var report := {"binder": {}, "total": 0}
	if binder != null:
		report["binder"] = binder.listener_report()
		report["total"] = int(report["binder"].get("total", 0))
	return report

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

## Every HUD surface draws through `UITheme`, so the bars, the frames and the
## hotbar cells are the same generated kit the bag and the menus use. The
## hotbar slots are `UISlot`s now and carry a real skill icon instead of the
## spell's name as button text.
func _apply_theme() -> void:
	theme = UITheme.get_theme()

	# ---- status bars: the theme supplies the recessed track and the fills
	UITheme.role(hp_bar, UITheme.V_HP)
	UITheme.role(mana_bar, UITheme.V_MANA)
	UITheme.role(exp_bar, UITheme.V_EXP)
	UITheme.role(target_hp_bar, UITheme.V_HP)
	hp_bar.custom_minimum_size = Vector2(0, 18)
	mana_bar.custom_minimum_size = Vector2(0, 18)
	exp_bar.custom_minimum_size = Vector2(0, 18)

	# The level badge and the target nameplate are captions, so they take the
	# theme's title role and only override the size the layout needs.
	UITheme.role(level_label, UITheme.V_TITLE)
	level_label.add_theme_font_size_override("font_size", UITheme.FS_SMALL)
	level_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER

	for label in [hp_label, mana_label, exp_label]:
		# A bar's own numbers are the one place a player reads at a glance, so
		# they get the bold cut and a tight outline: enough edge to survive the
		# fill behind them, not so much that 13 px text turns into a blob.
		label.add_theme_font_override("font", UITheme.font_body_bold())
		label.add_theme_font_size_override("font_size", UITheme.FS_SMALL)
		label.add_theme_color_override("font_color", UITheme.c("parchment"))
		label.add_theme_constant_override("outline_size", 3)

	# ---- target frame: the window frame, shrunk to a nameplate
	UITheme.role(target_panel, UITheme.V_WINDOW)
	UITheme.role(target_name_label, UITheme.V_TITLE)
	target_name_label.add_theme_font_size_override("font_size", UITheme.FS_BODY)

	for button in [inventory_button, ollivander_button, mount_button]:
		button.focus_mode = Control.FOCUS_NONE
	for slot in [slot_1, slot_2, slot_3, slot_4, slot_q, slot_e]:
		slot.focus_mode = Control.FOCUS_NONE
	for control in [hp_bar, mana_bar, exp_bar, target_panel]:
		control.mouse_filter = Control.MOUSE_FILTER_IGNORE

	# ---- icons. Each one sits beside its readout rather than replacing it: the
	# numbers and captions the interface checks assert stay verbatim, and the
	# picture is what makes them readable at a glance.
	_attach_bar_icon(hp_bar, "stat_health")
	_attach_bar_icon(mana_bar, "stat_mana")
	_attach_bar_icon(exp_bar, "stat_exp")
	_attach_bar_icon(target_hp_bar, "stat_health")
	UITheme.set_button_icon(inventory_button, "ui_inventory")
	UITheme.set_button_icon(ollivander_button, "ui_ollivander")
	UITheme.set_button_icon(mount_button, "ui_mount")
	inventory_button.tooltip_text = "[I] Bag - the potions you carry"
	ollivander_button.tooltip_text = "[O] Ollivander - forge the wand higher"
	mount_button.tooltip_text = "[Shift] Mount or dismount the broom"
	_target_icon = UITheme.icon_rect("ui_target", 15.0)
	_target_icon.name = "Icon"
	_target_icon.set_anchors_preset(Control.PRESET_TOP_LEFT)
	_target_icon.position = Vector2(9.0, 5.0)
	target_panel.add_child(_target_icon)

	# A disarmed target hits softer for five seconds; that is worth seeing while
	# it lasts, so it gets a marker of its own rather than replacing the type icon.
	_target_status_icon = UITheme.icon_rect("status_weakened", 13.0)
	_target_status_icon.name = "StatusIcon"
	_target_status_icon.set_anchors_preset(Control.PRESET_TOP_RIGHT)
	_target_status_icon.position = Vector2(-24.0, 6.0)
	_target_status_icon.visible = false
	target_panel.add_child(_target_status_icon)

	_frame_level_badge()


## A gauge's icon, in the left end of its track. The bars are anchored rather
## than containers, so the icon is placed by anchors and the readout centred in
## the bar never moves.
func _attach_bar_icon(bar: Control, id: String) -> void:
	var icon := UITheme.icon_rect(id, 13.0)
	icon.name = "Icon"
	icon.set_anchors_preset(Control.PRESET_CENTER_LEFT)
	icon.position = Vector2(4.0, -6.5)
	bar.add_child(icon)


## "Lv. 5" was a bare label floating over the deck; give it a badge so the left
## column reads as one stack. It is left-aligned now, so it sits over the gauges
## it labels instead of centred across them.
func _frame_level_badge() -> void:
	var parent := level_label.get_parent()
	if parent == null or parent.get_node_or_null("LevelBadge") != null:
		return
	var badge := PanelContainer.new()
	badge.name = "LevelBadge"
	badge.size_flags_horizontal = Control.SIZE_SHRINK_BEGIN
	badge.mouse_filter = Control.MOUSE_FILTER_IGNORE
	var index := level_label.get_index()
	parent.remove_child(level_label)
	parent.add_child(badge)
	parent.move_child(badge, index)
	var margin := MarginContainer.new()
	for side in ["left", "right"]:
		margin.add_theme_constant_override("margin_" + side, 8)
	margin.add_theme_constant_override("margin_top", 1)
	margin.add_theme_constant_override("margin_bottom", 1)
	margin.mouse_filter = Control.MOUSE_FILTER_IGNORE
	badge.add_child(margin)
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 5)
	row.mouse_filter = Control.MOUSE_FILTER_IGNORE
	margin.add_child(row)
	row.add_child(UITheme.icon_rect("stat_level", 14.0))
	row.add_child(level_label)




var _player_frame: Panel

func _build_arcane_layout() -> void:
	_player_frame = Panel.new()
	_player_frame.name = "PlayerFrame"
	_player_frame.theme_type_variation = &"ArcaneCard"
	_player_frame.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(_player_frame)
	move_child(_player_frame, 0)
	ArcaneSkin.decorate(_player_frame)
	$BottomBar.mouse_filter = Control.MOUSE_FILTER_IGNORE
	$BottomBar.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	$PlayerPlate.add_theme_stylebox_override("panel", StyleBoxEmpty.new())
	mount_button.text = "Mount"
	_currency.add_theme_font_size_override("font_size", 13)
	_currency.add_theme_constant_override("outline_size", 0)
	for slot in [slot_1, slot_2, slot_3, slot_4, slot_q, slot_e]:
		slot.theme_type_variation = &"ArcaneSlot"
	target_panel.theme_type_variation = &"ArcaneCard"
	for button in $BottomBar/QuickBar.get_children():
		if button is Button: button.theme_type_variation = &"ArcaneButton"
	chat_input.focus_entered.connect(_arcane_layout)
	chat_input.focus_exited.connect(_arcane_layout)
	get_viewport().size_changed.connect(_arcane_layout)
	_arcane_layout()

func _arcane_layout() -> void:
	if _player_frame == null: return
	var canvas := get_viewport().get_visible_rect().size
	var compact := canvas.x < 1000 or canvas.y < 560
	var rail := 210.0 if compact else 280.0
	UILayout.place(_player_frame, Vector2(16,12), Vector2(rail,136))
	UILayout.place($PlayerPlate, Vector2(22,17), Vector2(rail-12,45))
	var status := $BottomBar/StatusBars as Control
	status.set_anchors_preset(Control.PRESET_TOP_LEFT)
	status.custom_minimum_size.x = 0
	UILayout.place(status, Vector2(28,63), Vector2(rail-24,74))
	var hotbar := $BottomBar/Hotbar as Control
	hotbar.set_anchors_preset(Control.PRESET_CENTER_BOTTOM)
	UILayout.place(hotbar, Vector2(-166,-88), Vector2(332,54))
	for slot in [slot_1,slot_2,slot_3,slot_4,slot_q,slot_e]: slot.custom_minimum_size = Vector2(48,48)
	UILayout.place(exp_bar, Vector2(-166,-26), Vector2(332,14))
	var quick := $BottomBar/QuickBar as GridContainer
	quick.columns = 2 if compact else 3
	quick.set_anchors_preset(Control.PRESET_BOTTOM_RIGHT)
	for button in quick.get_children():
		if button is Button:
			button.custom_minimum_size = Vector2(76 if compact else 88,26)
	UILayout.place(quick, Vector2(-176 if compact else -292,-92), Vector2(160 if compact else 276,80))
	var chat := $ChatContainer as Control
	chat.set_anchors_preset(Control.PRESET_BOTTOM_LEFT)
	var chat_h := 180.0 if chat_input.has_focus() else (86.0 if compact else 120.0)
	UILayout.place(chat, Vector2(16,-104-chat_h), Vector2(rail,chat_h))
	chat_history.custom_minimum_size.y = 0
	if has_node("ChatBadge"): $ChatBadge.position = chat.position + Vector2(4,-9)
	UILayout.place(target_panel, Vector2(-120 if compact else -160,42), Vector2(240 if compact else 320,50))
	if feedback != null:
		feedback._status_row.position = Vector2(rail-100,72)
		feedback._safe_label.custom_minimum_size = Vector2.ZERO
		feedback._safe_label.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
		UILayout.place_centred(feedback._safe_row,Vector2(230,22),Vector2(0,-198))
		feedback._feedback_label.custom_minimum_size = Vector2.ZERO
		feedback._feedback_label.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
		feedback._cast_panel.custom_minimum_size = Vector2.ZERO
		UILayout.place(feedback._cast_panel, Vector2(-140,-144), Vector2(280,46))
		UILayout.place_centred(feedback._feedback_label, Vector2(minf(460,canvas.x-32),26), Vector2(0,-164))
		if feedback._toast_panel != null:
			feedback._toast_panel.custom_minimum_size = Vector2.ZERO
			UILayout.place(feedback._toast_panel, Vector2(-196 if compact else -rail-16,-140 if compact else -230), Vector2(180 if compact else rail,40 if compact else 120))
			feedback._toast_box.custom_minimum_size = Vector2(162 if compact else rail-18,0)
			feedback._toast_box.size.x = 162 if compact else rail-18
			feedback._toast_panel.clip_contents = true
