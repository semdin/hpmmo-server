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
## The target card's parts beyond the scene's name label and bar.
var _target_level: Label = null
var _target_rank: Label = null
var _target_hp_text: Label = null
var _target_portrait: TargetPortrait = null
var _target_flow: GaugeFlow = null
var _last_galleons := -1

## The authoritative binding and the panels it feeds.
var binder: UIStateBinder = null
var feedback: CombatFeedback = null
var travel: TravelFeedback = null
var maintenance: MaintenanceUI = null
var onboarding: OnboardingUI = null
var settings: SettingsUI = null
## The MMO frame: unit frame, buff row, action bar with quick slots, centre
## notices, Metin2-style chat, the Esc menu, the world map and the quest scroll.
var unit_frame: HudUnitFrame = null
var buff_bar: HudBuffBar = null
var action_bar: HudActionBar = null
var notices: HudNotices = null
var chat: HudChat = null
var game_menu: HudGameMenu = null
var world_map: HudWorldMap = null
var quest_scroll: HudQuestScroll = null
var skill_window: HudSkillWindow = null
var _exp_ticks: Control = null
var _level := 1
## Last house rank shown; 0 until the first payload so a load is not a "rank up".
var _house_rank := 0

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
	chat_input.text_submitted.connect(_on_chat_submitted)
	chat = HudChat.new()
	chat.name = "Chat"
	add_child(chat)
	chat.setup($ChatContainer, chat_history, chat_input)

	slot_1.pressed.connect(func(): _trigger_player_spell("stupefy"))
	slot_2.pressed.connect(func(): _trigger_player_spell("incendio"))
	slot_3.pressed.connect(func(): _trigger_player_spell("bombarda"))
	slot_4.pressed.connect(func(): _trigger_player_spell("expelliarmus"))
	slot_q.pressed.connect(func(): _trigger_player_spell("protego"))
	slot_e.pressed.connect(func(): _trigger_player_spell("ultimate"))

	mount_button.pressed.connect(func(): if is_instance_valid(player): player.toggle_broom_mount())

	_setup_panels()
	_build_mmo_layout()
	_add_system_chat("Welcome to Hogwarts! Spells on 1-4, Q, E · potions on F1-F4 · Shift mounts the broom.")
	_add_system_chat("Enter to chat, start a line with ! to shout to everyone. M opens the map, Esc the menu.")

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

	notices = HudNotices.new()
	add_child(notices)
	feedback.notice_sink = show_notice

	unit_frame = HudUnitFrame.new()
	add_child(unit_frame)
	move_child(unit_frame, 0)   # behind the gauges it frames
	buff_bar = HudBuffBar.new()
	add_child(buff_bar)
	action_bar = HudActionBar.new()

	# Windows live on their own canvas layer above every HUD and overlay layer
	# (the minimap and tracker are on the overlay's layer), so a window is never
	# drawn under the map or a notice.
	var modal := CanvasLayer.new()
	modal.name = "Windows"
	modal.layer = 20
	add_child(modal)
	for window in [settings, onboarding]:
		remove_child(window)
		modal.add_child(window)
	world_map = HudWorldMap.new()
	modal.add_child(world_map)
	quest_scroll = HudQuestScroll.new()
	modal.add_child(quest_scroll)
	skill_window = HudSkillWindow.new()
	skill_window.hud = self
	modal.add_child(skill_window)
	game_menu = HudGameMenu.new()
	modal.add_child(game_menu)
	game_menu.settings_requested.connect(func(): settings.open())
	game_menu.map_requested.connect(func(): world_map.open())

	_add_quick_button("JournalBtn", "menu_journal", "Guide", "[J] Training guide", open_guide)
	_add_quick_button("SkillsBtn", "stupefy", "Skills", "[V] Skill training", func(): skill_window.toggle())
	_add_quick_button("MapBtn", "menu_map", "Map", "[M] World map", func(): world_map.toggle())
	_add_quick_button("MenuBtn", "menu_settings", "Menu", "[Esc] Menu - settings, change character, quit", func(): game_menu.toggle())
	_ensure_ui_action("toggle_onboarding", KEY_J)
	_ensure_ui_action("toggle_map", KEY_M)
	_ensure_ui_action("toggle_skills", KEY_V)

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
	button.set_meta("icon_id", icon_id)
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
	var focus := get_viewport().gui_get_focus_owner()
	if focus is LineEdit or focus is TextEdit:
		return
	if event.is_action_pressed("toggle_onboarding"):
		open_guide()
		get_viewport().set_input_as_handled()
	elif event.is_action_pressed("toggle_map"):
		if settings != null and settings.is_open():
			return
		world_map.toggle()
		get_viewport().set_input_as_handled()
	elif event.is_action_pressed("toggle_skills"):
		if settings != null and settings.is_open():
			return
		skill_window.toggle()
		get_viewport().set_input_as_handled()

func bind_player(p_player: Node3D) -> void:
	if player == p_player and binder != null and binder.player == p_player:
		player.emit_stats()
		return
	if is_instance_valid(player) and player.has_signal("notice") and player.notice.is_connected(show_notice):
		player.notice.disconnect(show_notice)
	player = p_player
	if binder != null:
		binder.bind(player)
	if player.has_signal("notice") and not player.notice.is_connected(show_notice):
		player.notice.connect(show_notice)
	if action_bar != null:
		action_bar.bind(self, player)
	if buff_bar != null:
		buff_bar.bind(player, binder)
	if world_map != null:
		world_map.player = player
	if skill_window != null:
		skill_window.player = player
	if unit_frame != null:
		unit_frame.set_identity(String(player.player_name), String(player.house), int(player.level))
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
	_hp_stat.set_value(hp, max_hp)
	hp_label.text = "%d / %d" % [hp, max_hp]
	_mana_stat.set_value(mana, max_mana)
	mana_label.text = "%d / %d" % [mana, max_mana]
	_exp_stat.set_value(exp, max_exp)
	var exp_pct := (float(exp) / maxf(1.0, float(max_exp))) * 100.0
	_level = int(stats.get("level", _level))
	exp_label.text = "Level %d   ·   %d / %d EXP   ·   %.1f%%" % [_level, exp, max_exp, exp_pct]
	if unit_frame != null and is_instance_valid(player):
		unit_frame.set_identity(String(player.player_name), String(player.house), _level)
	_apply_house_standing(stats)
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

## House standing (quest reputation): the unit frame shows rank and progress, a
## rise past a threshold gets a notice. Payloads without the fields (the mirror
## path) fall back to the body's own reputation.
func _apply_house_standing(stats: Dictionary) -> void:
	if not is_instance_valid(player):
		return
	var rep := int(stats.get("house_rep", player.house_rep))
	var rank := HPRules.house_rank_for(rep)
	if unit_frame != null:
		unit_frame.set_house_standing(rank, rep)
	if _house_rank > 0 and rank > _house_rank:
		show_notice("%s Rank %d · %s" % [String(player.house), rank, HPRules.house_rank_title(rank)], "good")
		_play_ui("ui_levelup")
	_house_rank = rank

func _update_currency() -> void:
	if not is_instance_valid(player):
		return
	if unit_frame != null:
		unit_frame.set_galleons(_last_galleons)
	_currency.text = "%s · %s\n%d Galleons" % [player.player_name, player.house, _last_galleons]
	_house_crest.texture = UITheme.chrome("house_" + player.house.to_lower())

func _on_target_health(_uid: int, hp: int, max_hp: int) -> void:
	_target_stat.set_value(hp, max_hp)
	target_hp_bar.tooltip_text = "%d / %d" % [hp, max_hp]

func _on_cast_rejected(_cast_seq: int, _spell_id: String, _reason: String) -> void:
	_play_ui("ui_deny")

func _on_death_sound(is_dead: bool) -> void:
	_play_ui("ui_death" if is_dead else "ui_respawn")

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

	# One card for every kind of target: what it is, how strong, and how much
	# of it is left. Bosses and monoliths used to get a second banner from the
	# overlay on top of this one; this card carries them now.
	var title := ""
	var rank := ""
	var lvl := -1
	var tint := HudKit.PARCHMENT
	var bar_colour := Color(0.80, 0.09, 0.08)
	var icon := "ui_target"
	if "mob_name" in current_target:
		var is_boss_target: bool = "is_boss" in current_target and current_target.is_boss
		var is_enraged_target: bool = "is_enraged" in current_target and current_target.is_enraged
		title = String(current_target.mob_name)
		lvl = int(current_target.level)
		if is_boss_target:
			rank = "World Boss"
			tint = Color(1.0, 0.84, 0.36)
			bar_colour = Color(0.86, 0.10, 0.06)
			icon = "ui_boss"
		elif is_enraged_target:
			rank = "Enraged"
			tint = Color(1.0, 0.52, 0.26)
			bar_colour = Color(0.92, 0.32, 0.06)
			icon = "status_enraged"
		else:
			rank = "Creature"
			tint = Color(1.0, 0.86, 0.80)
		if "is_commander" in current_target and current_target.is_commander and not is_boss_target:
			rank = "Pack Leader · Enraged" if is_enraged_target else "Pack Leader"
	elif current_target.is_in_group("monoliths"):
		title = "Dark Monolith"
		rank = "Ancient Monolith"
		lvl = 35
		tint = Color(0.86, 0.62, 1.0)
		bar_colour = Color(0.58, 0.20, 0.92)
		icon = "minimap_monolith"
	elif "current_hp" in current_target and "max_hp" in current_target:
		title = "Training Dummy"
		rank = "Practice target"
		tint = Color(0.78, 0.95, 0.78)
		bar_colour = Color(0.30, 0.66, 0.24)
	else:
		target_panel.hide()
		return
	var hp := _target_hp_value()
	var max_hp := maxi(1, _target_max_hp_value())
	_target_stat.set_value(hp, max_hp)
	target_name_label.text = title
	target_name_label.modulate = Color.WHITE
	target_name_label.add_theme_color_override("font_color", tint)
	target_hp_bar.modulate = Color.WHITE
	if _target_flow != null:
		_target_flow.set_colour(bar_colour)
	if _target_level != null:
		_target_level.text = ("Lv. %d" % lvl) if lvl > 0 else ""
	if _target_rank != null:
		_target_rank.text = rank.to_upper()
		_target_rank.add_theme_color_override("font_color", tint.darkened(0.12))
	if _target_hp_text != null:
		var pct := 100.0 * float(hp) / float(max_hp)
		var pct_text := ("%.1f" % pct) if pct < 10.0 and pct > 0.0 else str(int(round(pct)))
		_target_hp_text.text = "%s / %s   ·   %s%%" % [HudUnitFrame._thousands(hp), HudUnitFrame._thousands(max_hp), pct_text]
	if _target_portrait != null:
		_target_portrait.set_look(UITheme.chrome(icon), bar_colour.lerp(tint, 0.35))

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
	mount_button.tooltip_text = "[Shift] Dismount broom" if is_mounted else "[Shift] Mount broom"
	mount_button.modulate = UITheme.c("gold_hi") if is_mounted else Color.WHITE


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

## Chat entry points (game world -> HUD).
func open_chat() -> void:
	if chat != null:
		chat.open()
	else:
		chat_input.grab_focus()

func add_chat_line(channel: String, sender: String, house: String, text: String) -> void:
	if chat != null:
		chat.add_player_line(channel, sender, house, text)

func add_system_chat(msg: String) -> void:
	_add_system_chat(msg)

func _add_system_chat(msg: String) -> void:
	if chat != null:
		chat.add_system_line(msg)
	else:
		chat_history.append_text("%s\n" % msg)

## ------------------------------------------------------ notices, menus, Esc

func show_notice(text: String, kind: String = "warn") -> void:
	if notices != null:
		notices.show_notice(text, kind)

## A realm-wide event (v14 `sim_world_event`): a line in the chat log, the
## centre band in the boss colour and the boss horn. Returns the text shown.
static func world_event_text(kind: String, data: Dictionary) -> String:
	var name := String(data.get("name", "A world boss"))
	var region := String(data.get("region", "the wilds"))
	match kind:
		"boss_soon":
			return "%s stirs at %s - %d seconds!" % [name, region, int(data.get("seconds", 60))]
		"boss_spawned":
			return "%s has appeared at %s (Lv %d)!" % [name, region, int(data.get("level", 1))]
		"boss_slain":
			var killer := String(data.get("killer", ""))
			return ("%s has been slain by %s!" % [name, killer]) if killer != "" else ("%s has fallen!" % name)
	return ""

func show_world_event(kind: String, data: Dictionary) -> String:
	var text := world_event_text(kind, data)
	if text == "":
		return ""
	_add_system_chat("[World] " + text)
	show_notice(text, "boss")
	if AudioManager.has_sound("boss_alert"):
		AudioManager.play_sound_at("boss_alert", Vector3.ZERO, null, true)
	return text

func open_guide() -> void:
	if onboarding != null:
		onboarding.toggle_panel()

func open_quest_scroll() -> void:
	if quest_scroll != null:
		quest_scroll.open()

## Esc closes the top-most thing that is open; with nothing open it opens the
## game menu. `world` supplies the game world's own windows (bag, forge,
## dialogue). Returns what it did, for the checks.
func handle_escape(world: Node = null) -> String:
	if chat != null and chat.is_open():
		chat.close()
		return "chat"
	if settings != null and settings.is_open():
		settings.close()
		return "settings"
	if game_menu != null and game_menu.is_open():
		game_menu.close()
		return "menu"
	if world_map != null and world_map.is_open():
		world_map.close()
		return "map"
	if skill_window != null and skill_window.is_open():
		skill_window.close()
		return "skills"
	if quest_scroll != null and quest_scroll.is_open():
		quest_scroll.close()
		return "quest"
	if onboarding != null and onboarding.expanded_guide:
		onboarding.toggle_panel()
		return "guide"
	if world != null:
		for key in ["inventory_ui", "ollivander_ui"]:
			var w = world.get(key)
			if w is CanvasItem and (w as CanvasItem).visible:
				(w as CanvasItem).hide()
				return key
		var overlay = world.get("overlay")
		if overlay != null and is_instance_valid(overlay) and overlay._dialog_panel != null and overlay._dialog_panel.visible:
			overlay._dialog_panel.hide()
			return "dialogue"
	if is_instance_valid(player) and player.get("current_target") != null and is_instance_valid(player.get("current_target")):
		player.set_target(null)
		return "target"
	if game_menu != null:
		game_menu.open()
	return "open_menu"

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
	for pair in [[inventory_button, "menu_inventory"], [ollivander_button, "menu_ollivander"], [mount_button, "menu_mount"]]:
		(pair[0] as Button).set_meta("icon_id", pair[1])
		UITheme.set_button_icon(pair[0], pair[1])
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



## A gauge's icon, in the left end of its track. The bars are anchored rather
## than containers, so the icon is placed by anchors and the readout centred in
## the bar never moves.
func _attach_bar_icon(bar: Control, id: String) -> void:
	var icon := UITheme.icon_rect(id, 13.0)
	icon.name = "Icon"
	icon.set_anchors_preset(Control.PRESET_CENTER_LEFT)
	icon.position = Vector2(4.0, -6.5)
	bar.add_child(icon)


var _player_frame: Panel

## The MMO layout. Every HUD node keeps its scene path (the walkthroughs and
## other systems address them); this builds the new frame around them and
## places everything for the current canvas.
func _build_mmo_layout() -> void:
	_player_frame = Panel.new()
	_player_frame.name = "PlayerFrame"
	_player_frame.visible = false
	_player_frame.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(_player_frame)
	$BottomBar.mouse_filter = Control.MOUSE_FILTER_IGNORE
	$BottomBar.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	$PlayerPlate.visible = false
	# Gauges: glossy fills, numbers in the bold face.
	HudKit.style_gauge(hp_bar, Color(0.86, 0.13, 0.11))
	HudKit.style_gauge(mana_bar, Color(0.18, 0.42, 0.92))
	HudKit.style_gauge(exp_bar, Color(0.90, 0.66, 0.16))
	HudKit.style_gauge(target_hp_bar, Color(0.86, 0.13, 0.11))
	# Living fills: energy swirling through the health and mana, a slower drift
	# through the experience band.
	GaugeFlow.attach(hp_bar, Color(0.80, 0.09, 0.08))
	GaugeFlow.attach(mana_bar, Color(0.12, 0.36, 0.92), 0.9)
	GaugeFlow.attach(exp_bar, Color(0.86, 0.60, 0.12), 0.45)
	GaugeFlow.attach(target_hp_bar, Color(0.80, 0.09, 0.08))
	for label in [hp_label, mana_label]:
		HudKit.style_label(label, 13, Color(1, 1, 1), HudKit.bold(), 3)
		label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
		label.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	HudKit.style_label(exp_label, 11, HudKit.PARCHMENT, HudKit.bold(), 3)
	# The numbers above the lag band StatBar adds as a later child.
	for pair in [[hp_bar, hp_label], [mana_bar, mana_label], [exp_bar, exp_label]]:
		(pair[0] as Node).move_child(pair[1], -1)
	exp_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	exp_label.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	for bar in [hp_bar, mana_bar, exp_bar, target_hp_bar]:
		var bar_icon: Node = bar.get_node_or_null("Icon")
		if bar_icon is CanvasItem:
			(bar_icon as CanvasItem).visible = false
	(hp_bar.get_parent() as BoxContainer).add_theme_constant_override("separation", 4)
	# EXP segment ticks over the full-width bar.
	_exp_ticks = ExpTicks.new()
	_exp_ticks.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	exp_bar.add_child(_exp_ticks)
	exp_bar.move_child(_exp_ticks, 0)
	# Action bar replaces the old spell cells (kept, hidden, for their paths).
	var hotbar := $BottomBar/Hotbar as Control
	for slot in [slot_1, slot_2, slot_3, slot_4, slot_q, slot_e]:
		slot.visible = false
	hotbar.add_child(action_bar)
	action_bar.bind(self, player)
	# Menu buttons, bottom-right: the same framed square cells as the action
	# bar, each filled edge to edge by its painted icon.
	for button in $BottomBar/QuickBar.get_children():
		if button is Button:
			_style_menu_cell(button as Button)
	# Target card.
	_build_target_card()
	# Chat sits over the world now; no badge.
	if feedback != null:
		feedback._status_row.visible = false
		feedback._feedback_label.visible = false
		if feedback._toast_panel != null:
			feedback._toast_panel.add_theme_stylebox_override("panel", HudKit.panel(0.7, 6, 0.5))
		if feedback._cast_panel != null:
			feedback._cast_panel.add_theme_stylebox_override("panel", HudKit.panel(0.85, 5))
			if feedback._cast_bar != null:
				HudKit.style_gauge(feedback._cast_bar, Color(0.86, 0.66, 0.2))
	if onboarding != null:
		onboarding.compact_hidden = true
	chat_input.focus_entered.connect(_mmo_layout)
	chat_input.focus_exited.connect(_mmo_layout)
	get_viewport().size_changed.connect(_mmo_layout)
	_mmo_layout()

func _mmo_layout() -> void:
	if unit_frame == null:
		return
	var canvas := get_viewport().get_visible_rect().size
	var compact := canvas.x < 1000 or canvas.y < 560
	# Unit frame + gauges, top-left.
	unit_frame.position = Vector2(12, 8)
	var gauges := unit_frame.gauge_rect()
	var status := $BottomBar/StatusBars as Control
	status.set_anchors_preset(Control.PRESET_TOP_LEFT)
	status.custom_minimum_size = Vector2.ZERO
	UILayout.place(status, unit_frame.position + gauges.position, Vector2(gauges.size.x, 40))
	# Health and mana are equals: the same height, one above the other.
	hp_bar.custom_minimum_size = Vector2(0, 18)
	mana_bar.custom_minimum_size = Vector2(0, 18)
	# Buffs under the frame.
	buff_bar.position = unit_frame.position + Vector2(HudUnitFrame.MEDALLION + 14, 112)
	# EXP across the bottom edge.
	exp_bar.set_anchors_preset(Control.PRESET_BOTTOM_WIDE)
	exp_bar.offset_left = 0
	exp_bar.offset_right = 0
	exp_bar.offset_top = -14
	exp_bar.offset_bottom = 0
	exp_bar.custom_minimum_size = Vector2(0, 14)
	# Action bar, centred above it.
	var hotbar := $BottomBar/Hotbar as Control
	hotbar.set_anchors_preset(Control.PRESET_CENTER_BOTTOM)
	var bw := action_bar.bar_width()
	UILayout.place(hotbar, Vector2(-bw * 0.5, -14 - 12 - HudActionBar.SLOT), Vector2(bw, HudActionBar.SLOT))
	action_bar.queue_redraw()
	# Menu buttons, bottom-right.
	var quick := $BottomBar/QuickBar as GridContainer
	var n := 0
	for b in quick.get_children():
		if b is Button and b.visible:
			n += 1
	quick.columns = n if not compact else 3
	quick.add_theme_constant_override("h_separation", 4)
	quick.set_anchors_preset(Control.PRESET_BOTTOM_RIGHT)
	var qw := float(quick.columns) * (MENU_CELL + 4.0)
	var qh: float = MENU_CELL * ceilf(float(n) / float(quick.columns)) + (4.0 if compact else 0.0)
	UILayout.place(quick, Vector2(-qw - 14, -14 - 12 - qh), Vector2(qw, qh))
	# Chat, bottom-left.
	var chat_box := $ChatContainer as Control
	chat_box.set_anchors_preset(Control.PRESET_BOTTOM_LEFT)
	var chat_w := 280.0 if compact else 360.0
	var chat_h := (240.0 if not compact else 170.0) if chat_input.has_focus() else (110.0 if compact else 170.0)
	UILayout.place(chat_box, Vector2(12, -14 - 14 - chat_h), Vector2(chat_w, chat_h))
	chat_history.custom_minimum_size.y = 0
	# Target card, top centre.
	var card_w := 300.0 if compact else 360.0
	UILayout.place(target_panel, Vector2(-card_w * 0.5, 10), Vector2(card_w, TARGET_CARD_H))
	# Notices, top centre under the zone banner.
	notices.position = Vector2(canvas.x * 0.5, 186 if not compact else 120)
	if feedback != null:
		feedback._safe_label.custom_minimum_size = Vector2.ZERO
		feedback._safe_label.size_flags_horizontal = Control.SIZE_SHRINK_CENTER
		feedback._safe_row.alignment = BoxContainer.ALIGNMENT_CENTER
		HudKit.style_label(feedback._safe_label, 14, Color(0.6, 0.95, 0.6), HudKit.bold(), 4)
		UILayout.place_centred(feedback._safe_row, Vector2(320, 22), Vector2(0, -14 - 12 - HudActionBar.SLOT - 52))
		feedback._cast_panel.custom_minimum_size = Vector2.ZERO
		UILayout.place(feedback._cast_panel, Vector2(-150, -14 - 12 - HudActionBar.SLOT - 26 - 46), Vector2(300, 42))
		if feedback._toast_panel != null:
			feedback._toast_panel.custom_minimum_size = Vector2.ZERO
			var tw := 200.0 if compact else 250.0
			UILayout.place(feedback._toast_panel, Vector2(-tw - 14, -14 - 12 - qh - 12 - 120), Vector2(tw, 120))
			feedback._toast_box.custom_minimum_size = Vector2(tw - 18, 0)
			feedback._toast_box.size.x = tw - 18
			feedback._toast_panel.clip_contents = true


const MENU_CELL := 42.0

## A bottom-right menu button as an action-bar cell: dark recess, a thin gold
## bevel that lights on hover, and the full-bleed icon inside it.
func _style_menu_cell(button: Button) -> void:
	button.theme_type_variation = &""
	button.text = ""
	button.flat = false
	button.icon_alignment = HORIZONTAL_ALIGNMENT_CENTER
	button.vertical_icon_alignment = VERTICAL_ALIGNMENT_CENTER
	button.expand_icon = true
	button.custom_minimum_size = Vector2(MENU_CELL, MENU_CELL)
	# Full-size art: the captioned style had pre-shrunk the icon to 15 px.
	var id := String(button.get_meta("icon_id", ""))
	if id != "":
		button.icon = UITheme.chrome_at(id, 128.0)
	for state in ["normal", "hover", "pressed", "focus", "disabled"]:
		var sb := StyleBoxFlat.new()
		sb.bg_color = Color(0.031, 0.039, 0.058, 0.95)
		sb.set_border_width_all(1)
		sb.border_color = HudKit.GOLD.darkened(0.15)
		sb.set_corner_radius_all(3)
		sb.set_content_margin_all(3)
		sb.shadow_color = Color(0, 0, 0, 0.55)
		sb.shadow_size = 3
		match state:
			"hover":
				sb.border_color = HudKit.GOLD_HI
				sb.set_border_width_all(2)
			"pressed":
				sb.border_color = HudKit.GOLD_LT
				sb.set_content_margin_all(4)
			"focus":
				sb.draw_center = false
				sb.border_color = Color(0, 0, 0, 0)
		button.add_theme_stylebox_override(state, sb)
	button.add_theme_color_override("icon_hover_color", Color(1.12, 1.08, 0.98))
	button.add_theme_color_override("icon_pressed_color", Color(0.85, 0.85, 0.85))

const TARGET_CARD_H := 74.0

## The target card: a round portrait (crown, crosshair, monolith spike) on the
## left; the name, the level badge and the rank line; and a wide health gauge
## with the exact numbers and the percentage in it.
func _build_target_card() -> void:
	target_panel.theme_type_variation = &""
	var sb := HudKit.panel(0.9, 8).duplicate() as StyleBoxFlat
	sb.border_color = Color(HudKit.GOLD.r, HudKit.GOLD.g, HudKit.GOLD.b, 0.9)
	sb.border_width_bottom = 2
	target_panel.add_theme_stylebox_override("panel", sb)
	if _target_icon != null:
		_target_icon.visible = false
	_target_portrait = TargetPortrait.new()
	_target_portrait.name = "Portrait"
	_target_portrait.position = Vector2(-12, (TARGET_CARD_H - 66.0) * 0.5)
	_target_portrait.size = Vector2(66, 66)
	target_panel.add_child(_target_portrait)
	var left := 64.0
	# Name: left-aligned beside the portrait.
	HudKit.style_label(target_name_label, 17, HudKit.PARCHMENT, HudKit.title(), 4)
	target_name_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_LEFT
	target_name_label.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	target_name_label.set_anchors_preset(Control.PRESET_TOP_WIDE)
	target_name_label.offset_left = left
	target_name_label.offset_right = -70
	target_name_label.offset_top = 6
	target_name_label.offset_bottom = 28
	target_name_label.clip_text = true
	target_name_label.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
	# Level badge, top-right.
	_target_level = HudKit.label("", 15, HudKit.GOLD_HI, HudKit.bold(), 3)
	_target_level.name = "Level"
	_target_level.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
	_target_level.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	_target_level.set_anchors_preset(Control.PRESET_TOP_RIGHT)
	_target_level.offset_left = -76
	_target_level.offset_right = -12
	_target_level.offset_top = 7
	_target_level.offset_bottom = 27
	target_panel.add_child(_target_level)
	# Rank line, small caps under the name.
	_target_rank = HudKit.label("", 11, HudKit.TEXT_DIM, HudKit.bold(), 2)
	_target_rank.name = "Rank"
	_target_rank.set_anchors_preset(Control.PRESET_TOP_WIDE)
	_target_rank.offset_left = left + 1
	_target_rank.offset_right = -40
	_target_rank.offset_top = 27
	_target_rank.offset_bottom = 41
	target_panel.add_child(_target_rank)
	# Health gauge with numbers and percentage.
	target_hp_bar.set_anchors_preset(Control.PRESET_BOTTOM_WIDE)
	target_hp_bar.offset_left = left
	target_hp_bar.offset_right = -12
	target_hp_bar.offset_top = -27
	target_hp_bar.offset_bottom = -9
	_target_flow = target_hp_bar.get_node_or_null("Flow") as GaugeFlow
	_target_hp_text = HudKit.label("", 12, Color(1, 1, 1), HudKit.bold(), 3)
	_target_hp_text.name = "HpText"
	_target_hp_text.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	_target_hp_text.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_target_hp_text.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	target_hp_bar.add_child(_target_hp_text)
	if _target_status_icon != null:
		_target_status_icon.set_anchors_preset(Control.PRESET_TOP_RIGHT)
		_target_status_icon.position = Vector2(-30, 28)
		_target_status_icon.custom_minimum_size = Vector2(14, 14)
		_target_status_icon.size = Vector2(14, 14)


## The target card's portrait: a dark disc, the target's icon and a ring in the
## target's colour, hanging over the card's left edge like the unit frame's.
class TargetPortrait extends Control:
	var icon: Texture2D = null
	var ring := HudKit.GOLD
	func _init() -> void:
		mouse_filter = Control.MOUSE_FILTER_IGNORE
	func set_look(p_icon: Texture2D, p_ring: Color) -> void:
		if p_icon != icon or p_ring != ring:
			icon = p_icon
			ring = p_ring
			queue_redraw()
	func _draw() -> void:
		var c := size * 0.5
		var r := minf(size.x, size.y) * 0.5
		draw_circle(c + Vector2(0, 2), r, Color(0, 0, 0, 0.45))
		draw_circle(c, r - 1, Color(0.024, 0.031, 0.051, 1.0))
		draw_circle(c, r - 5, Color(0.07, 0.085, 0.13, 1.0))
		if icon != null:
			var s := (r - 7) * 2.0 * 0.86
			draw_texture_rect(icon, Rect2(c - Vector2(s, s) * 0.5, Vector2(s, s)), false)
		draw_arc(c, r - 2.5, 0, TAU, 64, HudKit.GOLD_DK, 4.0, true)
		draw_arc(c, r - 2.5, 0, TAU, 64, Color(ring.r, ring.g, ring.b, 0.95), 2.0, true)
		draw_arc(c, r - 5.5, PI * 1.1, PI * 1.9, 24, Color(1, 1, 1, 0.18), 1.5, true)


## Ten segment ticks over the experience bar, the MMO way of reading progress.
class ExpTicks extends Control:
	func _init() -> void:
		mouse_filter = Control.MOUSE_FILTER_IGNORE
	func _draw() -> void:
		for i in range(1, 10):
			var x := floorf(size.x * float(i) / 10.0)
			draw_line(Vector2(x, 2), Vector2(x, size.y - 1), Color(0, 0, 0, 0.55), 2.0)
			draw_line(Vector2(x + 1, 2), Vector2(x + 1, size.y - 1), Color(1, 0.9, 0.6, 0.18), 1.0)
		draw_line(Vector2(0, 0.5), Vector2(size.x, 0.5), Color(HudKit.GOLD.r, HudKit.GOLD.g, HudKit.GOLD.b, 0.8), 1.0)
