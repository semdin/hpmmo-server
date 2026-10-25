extends HBoxContainer
class_name HudBuffBar

## The row of timed effects under the unit frame. Each effect is an icon whose
## shadow grows clockwise as its time runs out, with the seconds left beneath it
## and a tooltip that names it. When the effect ends the icon goes away - the
## old status row kept the shield up forever because nothing cleared it.
##
## Sources: the body's own `active_buffs` (Protego, the broom, later potions and
## anything else that calls `player.add_buff`) and the authority's record for the
## debuffs only the server knows the end of (stun, throw, freeze, burn, bleed).

const ICON := 34.0

var player: Node3D = null
var binder: UIStateBinder = null
var _icons: Dictionary = {}   # id -> HudBuffIcon
var _poll := 0.0

func _init() -> void:
	name = "BuffBar"
	add_theme_constant_override("separation", 6)
	mouse_filter = Control.MOUSE_FILTER_IGNORE

func bind(p_player: Node3D, p_binder: UIStateBinder) -> void:
	player = p_player
	binder = p_binder
	_refresh()

func _process(delta: float) -> void:
	_poll -= delta
	if _poll <= 0.0:
		_poll = 0.1
		_refresh()

## The effects to show right now: id -> {icon, title, desc, remaining, duration, debuff}.
func current_effects() -> Dictionary:
	var out := {}
	if player == null or not is_instance_valid(player):
		return out
	var buffs: Dictionary = player.get("active_buffs") if "active_buffs" in player else {}
	for id in buffs:
		var b: Dictionary = buffs[id]
		var remaining: float = player.call("buff_remaining", id)
		out[id] = {"icon": b.get("icon", id), "title": b.get("title", id), "desc": b.get("desc", ""),
			"remaining": remaining, "duration": float(b.get("duration", 0.0)), "debuff": false}
	var record := binder.record_for_local() if binder != null else {}
	var tick := int(SimAuthority.sim_tick)
	var dt := float(HPProtocol.SIM_DT)
	if not record.is_empty():
		# i18n-begin
		var ward := int(record.get("ward_until_tick", 0))
		if ward > tick and not out.has("protego"):
			var spell: Dictionary = GameData.SPELLS.get("protego", {})
			out["protego"] = {"icon": "protego", "title": "Protego", "desc": "Reflects projectiles; other damage reduced by 60%.",
				"remaining": float(ward - tick) * dt, "duration": float(spell.get("duration_ms", 3500)) / 1000.0, "debuff": false}
		var stun := int(record.get("stun_until_tick", 0))
		if stun > tick:
			out["stun"] = {"icon": "status_stun", "title": "Stunned", "desc": "You cannot cast or move.",
				"remaining": float(stun - tick) * dt, "duration": maxf(1.0, float(stun - tick) * dt), "debuff": true}
		var knock := int(record.get("knock_until_tick", 0))
		if knock > tick:
			out["knocked"] = {"icon": "status_stun", "title": "Knocked back", "desc": "Thrown off your feet: no casting until you land.",
				"remaining": float(knock - tick) * dt, "duration": maxf(0.5, float(knock - tick) * dt), "debuff": true}
		var freeze := int(record.get("freeze_until_tick", 0))
		if freeze > tick:
			out["frozen"] = {"icon": "status_stun", "title": "Frozen", "desc": "Encased in ice: you cannot cast or move.",
				"remaining": float(freeze - tick) * dt, "duration": maxf(1.0, float(freeze - tick) * dt), "debuff": true}
		var bleed := int(record.get("bleed_until_tick", 0))
		if bleed > tick:
			out["bleed"] = {"icon": "status_burn", "title": "Bleeding", "desc": "Losing health over time.",
				"remaining": float(bleed - tick) * dt, "duration": maxf(1.0, float(bleed - tick) * dt), "debuff": true}
		var despair := int(record.get("despair_until_tick", 0))
		if despair > tick:
			out["despair"] = {"icon": "status_despair", "title": "Despair", "desc": "A dementor's cold: no natural health recovery.",
				"remaining": float(despair - tick) * dt, "duration": maxf(1.0, float(despair - tick) * dt), "debuff": true}
		var burn := int(record.get("burn_until_tick", 0))
		if burn > tick:
			if String(record.get("burn_kind", "burn")) == "poison":
				out["poison"] = {"icon": "status_burn", "title": "Poisoned", "desc": "Spider venom: damage over time.",
					"remaining": float(burn - tick) * dt, "duration": maxf(1.0, float(burn - tick) * dt), "debuff": true}
			else:
				out["burn"] = {"icon": "status_burn", "title": "Burning", "desc": "Taking fire damage over time.",
					"remaining": float(burn - tick) * dt, "duration": maxf(1.0, float(burn - tick) * dt), "debuff": true}
		var webbed := int(record.get("webbed_until_tick", 0))
		if webbed > tick:
			out["webbed"] = {"icon": "status_stun", "title": "Webbed", "desc": "Sticky silk: you move at half speed.",
				"remaining": float(webbed - tick) * dt, "duration": maxf(1.0, float(webbed - tick) * dt), "debuff": true}
		# i18n-end
	return out

func _refresh() -> void:
	var effects := current_effects()
	for id in _icons.keys():
		if not effects.has(id):
			(_icons[id] as Node).queue_free()
			_icons.erase(id)
	for id in effects:
		var e: Dictionary = effects[id]
		var icon: HudBuffIcon = _icons.get(id)
		if icon == null:
			icon = HudBuffIcon.new()
			icon.custom_minimum_size = Vector2(ICON, ICON + 14)
			add_child(icon)
			_icons[id] = icon
		icon.texture = UITheme.icon_for(String(e.icon))
		icon.title = I18n.t(String(e.title))
		icon.tooltip_text = icon.title
		icon.desc = I18n.t(String(e.desc))
		icon.debuff = bool(e.debuff)
		# A duration is fixed at the moment the effect began; keep the largest
		# seen so the sweep never jumps backwards when the server corrects it.
		icon.duration = maxf(icon.duration, float(e.duration))
		icon.remaining = float(e.remaining)
		icon.queue_redraw()


class HudBuffIcon extends Control:
	var texture: Texture2D
	var title := ""
	var desc := ""
	var remaining := -1.0
	var duration := 0.0
	var debuff := false

	func _init() -> void:
		mouse_filter = Control.MOUSE_FILTER_STOP

	func _get_tooltip(_at: Vector2) -> String:
		var t := title
		if remaining > 0.0:
			t += "  (%ds)" % int(ceil(remaining))
		if desc != "":
			t += "\n" + desc
		return t

	func _make_custom_tooltip(for_text: String) -> Object:
		return HudKit.tooltip(for_text, HudKit.RED.lightened(0.3) if debuff else HudKit.GOLD_LT)

	func _draw() -> void:
		var s := minf(size.x, size.y - 14)
		var r := Rect2(Vector2((size.x - s) * 0.5, 0), Vector2(s, s))
		draw_rect(r, Color(0, 0, 0, 0.7))
		if texture != null:
			draw_texture_rect(texture, r.grow(-2), false)
		# Elapsed share shaded, growing clockwise from twelve.
		if duration > 0.0 and remaining >= 0.0:
			var elapsed := clampf(1.0 - remaining / duration, 0.0, 1.0)
			if elapsed > 0.0:
				var c := r.get_center()
				var pts := PackedVector2Array([c])
				var steps := maxi(3, int(40 * elapsed))
				for i in range(steps + 1):
					var a := -PI * 0.5 + TAU * elapsed * float(i) / float(steps)
					pts.append(c + Vector2(cos(a), sin(a)) * s)
				var sq := PackedVector2Array([r.grow(-2).position, Vector2(r.grow(-2).end.x, r.grow(-2).position.y), r.grow(-2).end, Vector2(r.grow(-2).position.x, r.grow(-2).end.y)])
				for poly in Geometry2D.intersect_polygons(pts, sq):
					draw_colored_polygon(poly, Color(0, 0, 0, 0.62))
		var edge := HudKit.RED if debuff else HudKit.GOLD
		draw_rect(r, edge, false, 1.5)
		# Seconds left under the icon (nothing for an effect without a timer).
		if remaining > 0.0:
			var txt := ("%.1f" % remaining) if remaining < 3.0 else "%ds" % int(ceil(remaining))
			var f := HudKit.bold()
			var fs := 12
			var w := f.get_string_size(txt, HORIZONTAL_ALIGNMENT_LEFT, -1, fs).x
			var p := Vector2((size.x - w) * 0.5, s + 12)
			draw_string_outline(f, p, txt, HORIZONTAL_ALIGNMENT_LEFT, -1, fs, 4, Color(0, 0, 0, 0.95))
			draw_string(f, p, txt, HORIZONTAL_ALIGNMENT_LEFT, -1, fs, HudKit.PARCHMENT if remaining > 3.0 else HudKit.GOLD_HI)
