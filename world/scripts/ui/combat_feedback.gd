extends Control
class_name CombatFeedback

## Interface combat feedback (and 's screen
## effects): cast progress and recovery, the authority's refusal reasons,
## safe-area indication, loot/XP feedback, and a clear death/respawn state.
##
## Everything here is driven by the authoritative events the `UIStateBinder`
## forwards. Nothing in this file invents a reason: refusals are the server's
## `HPProtocol.REJECT_*` codes translated to player-facing words, and cast
## progress is measured on the simulation clock (`SimAuthority.sim_tick`), not
## on a local timer that could drift from the release the server scheduled.
##
## It also owns the two screen effects the settings screen scales independently:
## the damage flash and the camera shake. Both are presentation only and both
## are fully suppressed at intensity 0.

const BAR_WIDTH := 260.0
const TOASTS_MAX := 6
const STATUS_POLL := 0.2
## Height of the notification card, in canvas pixels. See `_build` for why it is
## pinned above the control deck rather than to a fixed y.
const TOAST_H := 120.0

## The authority's refusal vocabulary -> the words the player reads.
# i18n-begin
const REASONS := {
	"no_wand": "Equip a wand first",
	"no_broom": "Equip a broom first",
	HPProtocol.REJECT_NO_MANA: "Not enough Mana",
	HPProtocol.REJECT_RANGE: "Out of range - move closer",
	HPProtocol.REJECT_NO_TARGET: "No target selected",
	HPProtocol.REJECT_PROTECTED: "That ground is protected",
	HPProtocol.REJECT_LINE_OF_SIGHT: "No line of sight",
	HPProtocol.REJECT_MOUNTED: "Not while mounted",
	HPProtocol.REJECT_COOLDOWN: "Still recovering",
	HPProtocol.REJECT_DEAD: "You are defeated",
	HPProtocol.REJECT_UNKNOWN_SPELL: "Unknown spell",
	HPProtocol.REJECT_HOUSE_RANK: "Your house rank is too low",
	HPProtocol.REJECT_LEVEL: "Your level is too low for that spell",
	HPProtocol.REJECT_INPUT_BUFFER: "Queued behind the current cast",
	HPProtocol.REJECT_ZONE: "Wrong area for that",
	HPProtocol.REJECT_STATE: "Not right now",
	HPProtocol.REJECT_TRANSFER_PENDING: "The map is still loading",
	HPProtocol.REJECT_NO_FLIGHT: "The broom cannot fly here",
}
# i18n-end

var binder: UIStateBinder = null
var player: Node3D = null

var _cast_panel: Panel = null
var _cast_icon: TextureRect = null
var _cast_label: Label = null
var _cast_bar: ProgressBar = null
var _feedback_label: Label = null
var _status_row: HBoxContainer = null
var _status_icons: Dictionary = {}
var _status_label: Label = null
var _safe_row: HBoxContainer = null
var _safe_icon: TextureRect = null
var _safe_label: Label = null
var _toast_box: VBoxContainer = null
var _toast_panel: Panel = null
var _death_panel: ColorRect = null
var _death_label: Label = null
var _death_icon: TextureRect = null
var _revive_here: Button = null
var _revive_town: Button = null
var _respawn_sent := false
var _flash_rect: ColorRect = null

## The effects the local body can carry, in the order the row shows them: the
## icon id, and the word `status_text()` reports for that effect.
const STATUS_EFFECTS := [
	{"id": "status_dead", "token": "[DEFEATED]"},
	{"id": "status_ward", "token": "[WARD]"},
	{"id": "status_stun", "token": "[STUNNED]"},
	{"id": "status_burn", "token": "[BURNING]"},
]

## Live cast, in simulation-clock terms.
var cast_spell := ""
var cast_id: int = 0
var _cast_start_tick: int = 0
var _cast_release_tick: int = 0
var _recovery_until := 0.0
var _recovery_total := 0.0
var _recovery_spell := ""
var _feedback_until := 0.0
var _toasts: Array = []
var _status_timer := 0.0
var _death_started := 0.0
var _death_seconds := 0.0
var _shake_until := 0.0
var _shake_strength := 0.0
var last_reason_text := ""
## When set (by the HUD), refusals and warnings go to the centre notice banner
## instead of the old bottom label.
var notice_sink: Callable

## Evidence counters for the checks.
var casts_shown: int = 0
var reasons_shown: int = 0
var toasts_shown: int = 0
var flashes: int = 0
var shakes: int = 0

func setup(p_binder: UIStateBinder, p_player: Node3D) -> void:
	binder = p_binder
	player = p_player
	set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	_build()
	if binder != null:
		binder.cast_started.connect(_on_cast_started)
		binder.cast_released.connect(_on_cast_released)
		binder.cast_rejected.connect(_on_cast_rejected)
		binder.death_changed.connect(_on_death_changed)
		binder.loot_taken.connect(_on_loot_taken)
		binder.reward_granted.connect(_on_reward_granted)
		binder.level_changed.connect(_on_level_changed)
		binder.damage_taken.connect(_on_damage_taken)
		binder.target_changed.connect(_on_target_changed)
	if SimAuthority.has_signal("entity_hit"):
		SimAuthority.entity_hit.connect(_on_entity_hit)
	_update_status()

func _build() -> void:
	_cast_panel = Panel.new()
	_cast_panel.name = "CastPanel"
	_cast_panel.set_anchors_preset(Control.PRESET_CENTER_BOTTOM)
	UILayout.place(_cast_panel, Vector2(-BAR_WIDTH * 0.5 - 10, -196), Vector2(BAR_WIDTH + 20, 46))
	_cast_panel.custom_minimum_size = Vector2(BAR_WIDTH + 20, 46)
	_cast_panel.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_cast_panel.theme = UITheme.get_theme()
	_cast_panel.theme_type_variation = UITheme.V_CARD
	# The hourglass, because this card is where the authority's windup and the
	# recovery tail are counted out.
	_cast_icon = UITheme.icon_rect("cooldown", 15.0)
	_cast_icon.name = "CastIcon"
	_cast_icon.position = Vector2(7, 3)
	_cast_panel.add_child(_cast_icon)
	_cast_label = _make_label(tr("Casting"), UITheme.FS_SMALL, UITheme.c("parchment"))
	_cast_label.position = Vector2(27, 4)
	_cast_panel.add_child(_cast_label)
	_cast_bar = ProgressBar.new()
	_cast_bar.name = "CastBar"
	_cast_bar.set_anchors_preset(Control.PRESET_BOTTOM_WIDE)
	_cast_bar.offset_left = 8
	_cast_bar.offset_right = -8
	_cast_bar.offset_top = -18
	_cast_bar.offset_bottom = -6
	_cast_bar.show_percentage = false
	_cast_bar.mouse_filter = Control.MOUSE_FILTER_IGNORE
	UITheme.role(_cast_bar, UITheme.V_MANA)
	_cast_panel.add_child(_cast_bar)
	_cast_panel.hide()
	add_child(_cast_panel)

	_feedback_label = _make_label("", UITheme.FS_LABEL, UITheme.c("gold_lt"))
	_feedback_label.set_anchors_preset(Control.PRESET_CENTER_BOTTOM)
	UILayout.place_centred(_feedback_label, Vector2(520, 26), Vector2(0, -246))
	_feedback_label.custom_minimum_size = Vector2(520, 26)
	_feedback_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_feedback_label.hide()
	add_child(_feedback_label)

	# Status effects (ward / burn / stun / mounted / defeated). Each one is its
	# icon the moment that file exists; the words `status_text()` reports stay the
	# fallback, so a checkout without the icons shows the row as it always did.
	_status_row = HBoxContainer.new()
	_status_row.name = "StatusRow"
	_status_row.set_anchors_preset(Control.PRESET_TOP_LEFT)
	_status_row.position = Vector2(20, 38)
	_status_row.add_theme_constant_override("separation", 4)
	_status_row.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(_status_row)
	for effect in STATUS_EFFECTS:
		var icon := UITheme.icon_rect(String(effect["id"]), 20.0)
		icon.name = String(effect["token"])
		icon.visible = false
		_status_row.add_child(icon)
		_status_icons[String(effect["id"])] = icon
	_status_label = _make_label("", UITheme.FS_SMALL, UITheme.c("parchment"))
	_status_label.custom_minimum_size = Vector2(0, 20)
	_status_label.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	_status_row.add_child(_status_label)

	# Safe-area indication.
	_safe_row = HBoxContainer.new()
	_safe_row.name = "SafeRow"
	_safe_row.set_anchors_preset(Control.PRESET_CENTER_BOTTOM)
	UILayout.place_centred(_safe_row, Vector2(400, 22), Vector2(0, -286))
	_safe_row.add_theme_constant_override("separation", 5)
	_safe_row.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(_safe_row)
	_safe_icon = UITheme.icon_rect("ui_safe_zone", 16.0)
	_safe_icon.name = "SafeIcon"
	_safe_icon.visible = false
	_safe_row.add_child(_safe_icon)
	_safe_label = _make_label("", UITheme.FS_SMALL, UITheme.c("good"))
	_safe_label.custom_minimum_size = Vector2(400, 22)
	_safe_label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_safe_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_safe_row.add_child(_safe_label)

	# Loot / XP / level toasts. The lowest card in the right rail: same width, same
	# right edge and same inset as the quest tracker and the controls card above
	# it, and pinned above the control deck rather than to a fixed y, so it clears
	# the deck at every canvas height.
	var toast_panel := Panel.new()
	toast_panel.name = "ToastPanel"
	toast_panel.set_anchors_preset(Control.PRESET_BOTTOM_RIGHT)
	UILayout.place(toast_panel,
		Vector2(-(UITheme.RIGHT_COL_W + UITheme.EDGE),
			-(UITheme.DECK_BOTTOM + UITheme.DECK_H + 8 + TOAST_H)),
		Vector2(UITheme.RIGHT_COL_W, TOAST_H))
	toast_panel.custom_minimum_size = Vector2(UITheme.RIGHT_COL_W, TOAST_H)
	toast_panel.mouse_filter = Control.MOUSE_FILTER_IGNORE
	toast_panel.theme = UITheme.get_theme()
	toast_panel.theme_type_variation = UITheme.V_CARD
	_toast_box = VBoxContainer.new()
	_toast_box.name = "Toasts"
	_toast_box.position = Vector2(9, 6)
	_toast_box.custom_minimum_size = Vector2(UITheme.RIGHT_COL_W - 18, TOAST_H - 12)
	_toast_box.add_theme_constant_override("separation", 2)
	toast_panel.add_child(_toast_box)
	toast_panel.hide()
	_toast_panel = toast_panel
	add_child(toast_panel)

	# Damage flash, above everything except the death panel.
	_flash_rect = ColorRect.new()
	_flash_rect.name = "DamageFlash"
	_flash_rect.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	_flash_rect.color = Color(0.75, 0.05, 0.05, 0.0)
	_flash_rect.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(_flash_rect)

	# Death / respawn state.
	_death_panel = ColorRect.new()
	_death_panel.name = "DeathPanel"
	_death_panel.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	_death_panel.color = Color(0.12, 0.0, 0.0, 0.55)
	_death_panel.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_death_panel.hide()
	var backdrop := ColorRect.new()
	backdrop.name = "Backdrop"
	backdrop.color = Color(0.03, 0.01, 0.01, 0.72)
	backdrop.mouse_filter = Control.MOUSE_FILTER_IGNORE
	backdrop.set_anchors_preset(Control.PRESET_CENTER)
	UILayout.place_centred(backdrop, Vector2(620, 290), Vector2(0, 8))
	_death_panel.add_child(backdrop)
	_death_label = _make_label("", UITheme.FS_BANNER, UITheme.c("blood_lt"))
	_death_label.set_anchors_preset(Control.PRESET_CENTER)
	UILayout.place_centred(_death_label, Vector2(640, 120))
	_death_label.custom_minimum_size = Vector2(640, 120)
	_death_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_death_label.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	_death_panel.add_child(_death_label)
	_death_icon = UITheme.icon_rect("status_dead", 72.0)
	_death_icon.name = "DeathIcon"
	_death_icon.set_anchors_preset(Control.PRESET_CENTER)
	UILayout.place_centred(_death_icon, Vector2(72, 72), Vector2(0, -104))
	_death_panel.add_child(_death_icon)
	# The death choice (v18): get up where you fell, or go back to town. The
	# panel itself ignores the mouse; only the buttons take clicks.
	var choices := HBoxContainer.new()
	choices.name = "DeathChoices"
	choices.alignment = BoxContainer.ALIGNMENT_CENTER
	choices.add_theme_constant_override("separation", 18)
	choices.set_anchors_preset(Control.PRESET_CENTER)
	UILayout.place_centred(choices, Vector2(460, 44), Vector2(0, 96))
	_death_panel.add_child(choices)
	_revive_here = HudKit.button(tr("Revive Here"), 16)
	_revive_here.name = "ReviveHere"
	_revive_here.custom_minimum_size = Vector2(210, 44)
	_revive_here.tooltip_text = tr("Get up where you fell with half health")
	_revive_here.pressed.connect(_request_respawn.bind(HPProtocol.RESPAWN_HERE))
	choices.add_child(_revive_here)
	_revive_town = HudKit.button(tr("Return to Town"), 16)
	_revive_town.name = "ReviveTown"
	_revive_town.custom_minimum_size = Vector2(210, 44)
	_revive_town.tooltip_text = tr("Wake at this map's respawn point with full health")
	_revive_town.pressed.connect(_request_respawn.bind(HPProtocol.RESPAWN_TOWN))
	choices.add_child(_revive_town)
	# Its own layer, above every HUD window (a window left open must not hide
	# the choice) and below the map loading screen (layer 90).
	var death_layer := CanvasLayer.new()
	death_layer.name = "DeathLayer"
	death_layer.layer = 80
	add_child(death_layer)
	death_layer.add_child(_death_panel)

func _make_label(text: String, size: int, color: Color) -> Label:
	var label := Label.new()
	label.text = text
	label.mouse_filter = Control.MOUSE_FILTER_IGNORE
	# These labels float over the world rather than sitting on a panel, so they do
	# need an edge - but 5 px of outline around 13 px glyphs is what made them read
	# as smudges. The bold cut carries the weight instead.
	label.add_theme_font_override("font", UITheme.font_body_bold())
	label.add_theme_font_size_override("font_size", size)
	label.add_theme_color_override("font_color", color)
	label.add_theme_color_override("font_outline_color", UITheme.c("shadow"))
	label.add_theme_constant_override("outline_size", 3)
	return label

## ------------------------------------------------------------ cast progress

func _on_cast_started(p_cast_id: int, spell_id: String, release_tick: int) -> void:
	cast_id = p_cast_id
	cast_spell = spell_id
	_cast_start_tick = int(SimAuthority.sim_tick)
	_cast_release_tick = release_tick
	_recovery_spell = ""
	casts_shown += 1
	# The windup/recovery bar is not shown to players: the action bar's own
	# cooldown sweep already says when a skill is ready again.
	_cast_label.text = tr("%s - casting... (%s)") % [_spell_name(spell_id), _dummy_countdown(SimAuthority.TICK_MS * maxi(1, _cast_release_tick - _cast_start_tick))]

## The server decides the windup. The bar fills on the simulation clock; if the
## release tick has passed and no release arrived yet (network gap), the bar
## holds full rather than inventing progress.
func cast_progress() -> float:
	if cast_id == 0 or _cast_release_tick <= _cast_start_tick:
		return 0.0
	var span := maxf(1.0, float(_cast_release_tick - _cast_start_tick))
	var elapsed := float(int(SimAuthority.sim_tick) - _cast_start_tick)
	return clampf(elapsed / span, 0.0, 1.0)

func _on_cast_released(p_cast_id: int, spell_id: String) -> void:
	if p_cast_id != cast_id and cast_id != 0:
		return
	cast_id = 0
	cast_spell = ""
	_cast_panel.hide()
	# Recovery, derived from the same rules data the authority used: the lock is
	# split half windup / half recovery, so the bar shows exactly the tail the
	# authority still holds the caster in.
	var lock := HPRules.cast_lock(spell_id)
	var recovery := maxf(0.0, lock - lock * 0.5)
	if recovery > 0.01:
		_recovery_spell = spell_id
		_recovery_total = recovery
		_recovery_until = _now() + recovery

func _on_cast_rejected(_cast_seq: int, spell_id: String, reason: String) -> void:
	if reason == "" or reason == "queued" or reason == "sent":
		return
	var text := reason_text(reason)
	if spell_id != "":
		text = "%s: %s" % [_spell_name(spell_id), text]
	show_feedback(text, Color(1.0, 0.72, 0.35))

## Player-facing words for one REJECT_* code.
static func reason_text(reason: String) -> String:
	if REASONS.has(reason):
		return I18n.t(String(REASONS[reason]))
	if reason == "":
		return I18n.t("Refused")
	return I18n.t("Refused (%s)") % reason

func _spell_name(spell_id: String) -> String:
	if GameData.SPELLS.has(spell_id):
		return I18n.t(String(GameData.SPELLS[spell_id].name))
	return spell_id

func _dummy_countdown(ms: int) -> String:
	return "%.1fs" % (float(ms) / 1000.0)

func show_feedback(text: String, color: Color) -> void:
	last_reason_text = text
	reasons_shown += 1
	if notice_sink.is_valid():
		var kind := "mana" if text.to_lower().find("mana") >= 0 else "warn"
		notice_sink.call(text, kind)
		return
	_feedback_label.text = text
	_feedback_label.add_theme_color_override("font_color", color)
	_feedback_label.show()
	_feedback_until = _now() + 2.4

## ----------------------------------------------------------- death / respawn

func _on_death_changed(is_dead: bool) -> void:
	if is_dead:
		_death_started = _now()
		_death_seconds = _respawn_seconds()
		_respawn_sent = false
		_death_panel.show()
		_update_death_panel()
		show_feedback(tr("You were defeated."), Color(1.0, 0.4, 0.4))
	else:
		_death_panel.hide()
		show_feedback(tr("Back on your feet."), Color(0.5, 1.0, 0.6))
		_toast(tr("Respawned"), Color(0.5, 1.0, 0.6), "stat_health")

## Seconds until the automatic return to town (the authority's schedule).
func _respawn_seconds() -> float:
	return _ticks_until("respawn_tick", float(HPRules.auto_respawn_ms()) / 1000.0)

## Seconds until the death choice opens.
func _choice_seconds() -> float:
	return _ticks_until("respawn_ready_tick", 0.0)

func _ticks_until(key: String, fallback: float) -> float:
	var record := binder.record_for_local() if binder != null else {}
	var tick := int(record.get(key, 0))
	if tick > 0:
		return maxf(0.0, float(tick - int(SimAuthority.sim_tick)) * float(HPProtocol.SIM_DT))
	return fallback

func _update_death_panel() -> void:
	var wait := _choice_seconds()
	var ready := wait <= 0.0 and not _respawn_sent
	_revive_here.disabled = not ready
	_revive_town.disabled = not ready
	if wait > 0.0:
		_death_label.text = tr("DEFEATED\nYou can rise in %ds") % int(ceil(wait))
	else:
		var left := int(ceil(_respawn_seconds()))
		_death_label.text = tr("DEFEATED\nReturning to town in %d:%02d") % [left / 60, left % 60]

func _request_respawn(mode: int) -> void:
	if _respawn_sent or not is_instance_valid(player):
		return
	_respawn_sent = true
	SimNet.submit_respawn(player, mode)
	_update_death_panel()
	# A refused or lost request must not lock the buttons for good.
	get_tree().create_timer(2.0).timeout.connect(func(): _respawn_sent = false)

## ------------------------------------------------------------ loot and xp

func _on_loot_taken(item_id: String, amount: int) -> void:
	if item_id == "galleons":
		_toast(tr("+%d Galleons") % amount, Color(1.0, 0.85, 0.35), "galleons")
	elif GameData.ITEMS.has(item_id):
		_toast("+%s x%d" % [I18n.t(String(GameData.ITEMS[item_id].name)), amount], Color(0.75, 0.95, 0.75), item_id)
	else:
		_toast("+%s x%d" % [item_id, amount], Color(0.75, 0.95, 0.75), "ui_pickup")
	_play_ui("ui_loot")

func _on_reward_granted(exp: int, galleons: int, items: Array) -> void:
	if exp > 0:
		_toast(tr("+%d EXP") % exp, Color(0.5, 1.0, 0.6), "stat_exp")
	if galleons > 0:
		_toast(tr("+%d Galleons") % galleons, Color(1.0, 0.85, 0.35), "galleons")
		_play_ui("ui_coin")
	for entry in items:
		if entry is Dictionary:
			var item_id := String(entry.get("id", "item"))
			_toast("+%s x%d" % [I18n.t(String(GameData.ITEMS.get(item_id,{}).get("name",item_id))), int(entry.get("amount", 1))], Color(0.75, 0.95, 0.75), item_id)

func _on_level_changed(level: int) -> void:
	_toast("LEVEL %d!" % level, Color(1.0, 0.9, 0.3), "stat_level")
	_play_ui("ui_levelup")
	# the banner, pillar and chime are the level-up moment (scripts/fx/level_up_fx.gd)
	LevelUpFX.play(player, level, self)

## A notification line. The icon is the loot itself when there is one (an item
## id resolves through the same namespace a bag cell uses), so "+Wiggenweld
## Potion x3" shows the bottle it means.
func _toast(text: String, color: Color, icon_id: String = "ui_pickup") -> void:
	toasts_shown += 1
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 5)
	row.mouse_filter = Control.MOUSE_FILTER_IGNORE
	var icon := UITheme.icon_rect(icon_id, 16.0)
	icon.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	row.add_child(icon)
	var label := _make_label(text, UITheme.FS_SMALL, color)
	label.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
	label.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
	label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	label.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	row.add_child(label)
	_toast_box.add_child(row)
	if _toast_panel != null:
		_toast_panel.show()
	_toasts.append({"label": label, "row": row, "until": _now() + 4.0})
	var canvas := get_viewport().get_visible_rect().size
	var capacity := 2 if canvas.x < 1000 or canvas.y < 560 else TOASTS_MAX
	while _toasts.size() > capacity:
		var oldest: Dictionary = _toasts.pop_front()
		if is_instance_valid(oldest["row"]):
			(oldest["row"] as Node).queue_free()

## -------------------------------------------------------- screen effects

func _on_damage_taken(_amount: int, _hp: int, _max_hp: int, _spell_id: String) -> void:
	var settings := GameSettings.instance()
	if settings.flash_intensity > 0.0:
		_flash_rect.color.a = maxf(_flash_rect.color.a, 0.30 * settings.flash_intensity)
		flashes += 1
	if settings.shake_intensity > 0.0:
		_shake_until = _now() + 0.35
		_shake_strength = 0.16 * settings.shake_intensity
		shakes += 1

## The local player's own heavy hits (a critical or a combo finisher) kick the
## camera a little - shorter and lighter than taking damage.
func _on_entity_hit(_uid: int, amount: int, _hp: int, _spell_id: String, attacker_uid: int, flags: int) -> void:
	if amount <= 0 or binder == null or attacker_uid == 0 or attacker_uid != binder.local_uid():
		return
	if flags & (HPProtocol.HIT_CRIT | HPProtocol.HIT_FINISHER) == 0:
		return
	var settings := GameSettings.instance()
	if settings.shake_intensity <= 0.0:
		return
	var strength := (0.11 if flags & HPProtocol.HIT_CRIT != 0 else 0.07) * settings.shake_intensity
	if _now() >= _shake_until or strength > _shake_strength:
		_shake_strength = strength
	_shake_until = maxf(_shake_until, _now() + 0.16)
	shakes += 1

func _on_target_changed(_target: Object) -> void:
	_update_status()

## ------------------------------------------------------------- status icons

func status_text() -> String:
	return " ".join(status_tokens())

## The words for the effects the local body carries, in display order. This is
## the evidence the checks read; the status row renders the same list as icons.
func status_tokens() -> Array[String]:
	var tokens: Array[String] = []
	if player == null or not is_instance_valid(player):
		return tokens
	var record := binder.record_for_local() if binder != null else {}
	var tick := int(SimAuthority.sim_tick)
	if bool(record.get("dead", false)) or bool(player.get("is_dead")):
		tokens.append("[DEFEATED]")
	if int(record.get("ward_until_tick", 0)) > tick or bool(player.get("is_protego_active")):
		tokens.append("[WARD]")
	if int(record.get("stun_until_tick", 0)) > tick or float(player.get("_hit_recovery")) > 0.0:
		tokens.append("[STUNNED]")
	if int(record.get("burn_until_tick", 0)) > tick:
		tokens.append("[BURNING]")
	if bool(player.get("is_mounted")):
		tokens.append("[MOUNTED]")
	return tokens


## One icon per active effect, and the words only for the effects whose icon file
## is missing - a new row that never blanks a status the player needs to see.
func _status_fallback_text() -> String:
	var active := status_tokens()
	var missing: Array[String] = []
	for effect in STATUS_EFFECTS:
		var token := String(effect["token"])
		var icon: TextureRect = _status_icons.get(String(effect["id"]))
		var on := active.has(token)
		icon.visible = on and icon.texture != null
		if on and icon.texture == null:
			missing.append(token)
	return " ".join(missing)

func safe_area_text() -> String:
	if player == null or not is_instance_valid(player):
		return ""
	var here := HPRules.is_protected_point(player.global_position)
	var lines: Array = []
	if here:
		var zone := HPRules.protection_id(player.global_position)
		lines.append(tr("Protected ground - combat is disabled here%s") % (" (%s)" % zone if zone != "" else ""))
	var target = binder.target if binder != null else null
	if target is Node3D and is_instance_valid(target) and HPRules.is_protected_node(target):
		lines.append(tr("Target is on protected ground - attacks will be refused"))
	return "\n".join(lines)

func _update_status() -> void:
	_status_label.text = _status_fallback_text()
	_safe_label.text = tr("Safe area · Combat disabled") if safe_area_text() != "" else ""
	# A duel's fight goes on inside safe ground (the foes agreed to it).
	if _safe_label.text != "" and player != null and is_instance_valid(player) \
			and HPRules.duel_foes.has(int(player.get_meta("sim_uid", -1))):
		_safe_label.text = tr("Safe area · Duel in progress")
	_safe_icon.visible = _safe_label.text != ""

## ------------------------------------------------------------------ process

func _process(delta: float) -> void:
	var now := _now()
	# Cast bar: fill while the authority's windup is running, hold at full if the
	# release is late, hide when the answer lands.
	if cast_id != 0:
		var progress := cast_progress()
		_cast_bar.value = progress * 100.0
		if progress < 1.0:
			_cast_label.text = tr("%s - casting... %.0f%%") % [_spell_name(cast_spell), progress * 100.0]
		else:
			_cast_label.text = tr("%s - releasing...") % _spell_name(cast_spell)
	elif _recovery_until > now and _recovery_total > 0.0:
		var remaining := _recovery_until - now
		var ratio := clampf(remaining / _recovery_total, 0.0, 1.0)
		_cast_label.text = tr("%s - recovering... %.1fs") % [_spell_name(_recovery_spell), remaining]
		_cast_bar.value = (1.0 - ratio) * 100.0
	else:
		if _recovery_spell != "":
			_recovery_spell = ""
			_recovery_until = 0.0
		if _cast_panel.visible and cast_id == 0:
			_cast_panel.hide()

	if _feedback_until > 0.0 and now > _feedback_until:
		_feedback_until = 0.0
		_feedback_label.hide()

	for toast in _toasts.duplicate():
		if not is_instance_valid(toast["label"]):
			_toasts.erase(toast)
		elif now > float(toast["until"]):
			(toast["row"] as Node).queue_free()
			_toasts.erase(toast)
	if _toast_panel != null and _toasts.is_empty() and _toast_panel.visible:
		_toast_panel.hide()

	if _death_panel.visible:
		_update_death_panel()

	_update_flash(delta)
	_update_shake(delta)

	_status_timer -= delta
	if _status_timer <= 0.0:
		_status_timer = STATUS_POLL
		_update_status()

func _update_flash(delta: float) -> void:
	if _flash_rect.color.a > 0.0:
		_flash_rect.color.a = maxf(0.0, _flash_rect.color.a - delta * 1.6)

func _update_shake(_delta: float) -> void:
	var camera: Camera3D = null
	if player != null and is_instance_valid(player):
		camera = player.get("camera") as Camera3D
	if camera == null:
		return
	if _now() < _shake_until and _shake_strength > 0.0:
		camera.h_offset = randf_range(-_shake_strength, _shake_strength)
		camera.v_offset = randf_range(-_shake_strength, _shake_strength)
	elif camera.h_offset != 0.0 or camera.v_offset != 0.0:
		camera.h_offset = 0.0
		camera.v_offset = 0.0

func _now() -> float:
	return float(Time.get_ticks_msec()) / 1000.0

func _play_ui(key: String) -> void:
	var audio := get_node_or_null("/root/AudioManager")
	if audio != null and audio.has_method("play_sound_at"):
		audio.call("play_sound_at", key, Vector3.ZERO, null, true)

## Evidence summary for the checks.
func describe() -> Dictionary:
	return {
		"casts_shown": casts_shown,
		"reasons_shown": reasons_shown,
		"toasts_shown": toasts_shown,
		"flashes": flashes,
		"shakes": shakes,
		"last_reason": last_reason_text,
		"death_visible": _death_panel.visible,
		"cast_visible": _cast_panel.visible,
		"status": status_text(),
		"safe_area": safe_area_text(),
	}
