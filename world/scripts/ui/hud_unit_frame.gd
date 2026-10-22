extends Control
class_name HudUnitFrame

## The player's unit frame, top-left: a round portrait medallion (house crest in
## a gold ring) with the level badge under it, the name and house beside it, and
## the HP and mana gauges on a plate that fades out to the right. The gauges
## themselves are the HUD's own `HpBar` / `ManaBar` nodes (their paths are part
## of the HUD contract); this control draws the frame around them and places
## them.

const MEDALLION := 92.0

var player_name := ""
var house := ""
var level := 1
var house_rank := 0
var house_rep := 0
var crest: Texture2D = null
var galleons := -1
var _coin: Texture2D = null
var _ring: Texture2D = null

func _init() -> void:
	name = "UnitFrame"
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	custom_minimum_size = Vector2(350, 110)
	size = custom_minimum_size

func _ready() -> void:
	if ResourceLoader.exists("res://assets/ui/arcane/minimap.png"):
		_ring = ArcaneSkin.texture("minimap")
	_coin = UITheme.chrome_at("galleons", 16.0)

func set_galleons(amount: int) -> void:
	if amount != galleons:
		galleons = amount
		queue_redraw()

func set_identity(p_name: String, p_house: String, p_level: int) -> void:
	if p_name == player_name and p_house == house and p_level == level:
		return
	player_name = p_name
	house = p_house
	level = p_level
	crest = UITheme.chrome("house_" + house.to_lower()) if house != "" else null
	queue_redraw()

func set_house_standing(rank: int, rep: int) -> void:
	if rank == house_rank and rep == house_rep:
		return
	house_rank = rank
	house_rep = rep
	queue_redraw()

## Where the gauges go, in this control's coordinates.
func gauge_rect() -> Rect2:
	return Rect2(Vector2(MEDALLION + 14, 40), Vector2(size.x - MEDALLION - 26, 42))

func _draw() -> void:
	var m := MEDALLION
	var c := Vector2(m * 0.5 + 4, m * 0.5 + 4)
	# Plate behind name and gauges: navy glass fading to nothing on the right.
	var plate := Rect2(Vector2(c.x, 16), Vector2(size.x - c.x, 92))
	# Smooth horizontal fade (vertex colours, no banding).
	var x0 := plate.position.x
	var x1 := plate.end.x
	var y0 := plate.position.y
	var y1 := plate.end.y
	var mid := x0 + plate.size.x * 0.62
	var body := Color(0.035, 0.047, 0.075, 0.82)
	var clear := Color(0.035, 0.047, 0.075, 0.0)
	draw_polygon(PackedVector2Array([Vector2(x0, y0), Vector2(mid, y0), Vector2(mid, y1), Vector2(x0, y1)]), PackedColorArray([body, body, body, body]))
	draw_polygon(PackedVector2Array([Vector2(mid, y0), Vector2(x1, y0), Vector2(x1, y1), Vector2(mid, y1)]), PackedColorArray([body, clear, clear, body]))
	var gold := Color(HudKit.GOLD.r, HudKit.GOLD.g, HudKit.GOLD.b, 0.9)
	var gold_clear := Color(gold.r, gold.g, gold.b, 0.0)
	for yy in [y0, y1 - 1.5]:
		draw_polygon(PackedVector2Array([Vector2(x0, yy), Vector2(x1, yy), Vector2(x1, yy + 1.5), Vector2(x0, yy + 1.5)]), PackedColorArray([gold, gold_clear, gold_clear, gold]))
	# Medallion: dark disc, crest, ring.
	draw_circle(c, m * 0.5 - 2, Color(0.024, 0.031, 0.051, 0.96))
	draw_circle(c, m * 0.5 - 8, Color(0.075, 0.098, 0.153, 1.0))
	if crest != null:
		var cs := m * 0.62
		draw_texture_rect(crest, Rect2(c - Vector2(cs, cs) * 0.5, Vector2(cs, cs)), false)
	if _ring != null:
		draw_texture_rect(_ring, Rect2(c - Vector2(m, m) * 0.5, Vector2(m, m)), false)
	else:
		draw_arc(c, m * 0.5 - 3, 0, TAU, 64, HudKit.GOLD, 3.0, true)
	# Level badge.
	var bc := c + Vector2(0, m * 0.5 - 4)
	draw_circle(bc, 15, Color(0, 0, 0, 0.6))
	draw_circle(bc, 13.5, Color(0.10, 0.07, 0.04))
	draw_arc(bc, 13.5, 0, TAU, 40, HudKit.GOLD_LT, 2.0, true)
	var lv := str(level)
	var lf := HudKit.bold()
	var ls := 15 if lv.length() < 3 else 12
	var lw := lf.get_string_size(lv, HORIZONTAL_ALIGNMENT_LEFT, -1, ls).x
	var lp := bc + Vector2(-lw * 0.5, ls * 0.36)
	draw_string_outline(lf, lp, lv, HORIZONTAL_ALIGNMENT_LEFT, -1, ls, 3, Color(0, 0, 0))
	draw_string(lf, lp, lv, HORIZONTAL_ALIGNMENT_LEFT, -1, ls, HudKit.GOLD_HI)
	# Name and house.
	var nf := HudKit.title()
	var np := Vector2(MEDALLION + 14, 34)
	draw_string_outline(nf, np, player_name, HORIZONTAL_ALIGNMENT_LEFT, 170, 18, 4, Color(0, 0, 0, 0.9))
	draw_string(nf, np, player_name, HORIZONTAL_ALIGNMENT_LEFT, 170, 18, HudKit.GOLD_HI)
	if house != "":
		var hcol := HudKit.TEXT
		if GameData.HOUSES.has(house):
			hcol = (GameData.HOUSES[house].primary_color as Color).lightened(0.35)
		var hf := HudKit.bold()
		var hw := hf.get_string_size(house, HORIZONTAL_ALIGNMENT_LEFT, -1, 12).x
		var hp := Vector2(size.x - hw - 14, 33)
		draw_string_outline(hf, hp, house, HORIZONTAL_ALIGNMENT_LEFT, -1, 12, 3, Color(0, 0, 0, 0.9))
		draw_string(hf, hp, house, HORIZONTAL_ALIGNMENT_LEFT, -1, 12, hcol)
		if house_rank > 0:
			_draw_house_standing(hcol)
	# Purse, under the gauges.
	if galleons >= 0:
		var gtext := _thousands(galleons)
		var gf := HudKit.bold()
		var gp := Vector2(MEDALLION + 34, 100)
		if _coin != null:
			draw_texture_rect(_coin, Rect2(Vector2(MEDALLION + 14, 87), Vector2(16, 16)), false)
		draw_string_outline(gf, gp, gtext, HORIZONTAL_ALIGNMENT_LEFT, -1, 13, 3, Color(0, 0, 0, 0.9))
		draw_string(gf, gp, gtext, HORIZONTAL_ALIGNMENT_LEFT, -1, 13, HudKit.GOLD_LT)

## Rank title and a thin reputation bar, right-aligned on the purse line.
func _draw_house_standing(hcol: Color) -> void:
	var text := tr("Rank %d · %s") % [house_rank, I18n.t(HPRules.house_rank_title(house_rank))]
	var f := HudKit.bold()
	var w := f.get_string_size(text, HORIZONTAL_ALIGNMENT_LEFT, -1, 12).x
	var right := size.x - 14
	var p := Vector2(right - w, 98)
	draw_string_outline(f, p, text, HORIZONTAL_ALIGNMENT_LEFT, -1, 12, 3, Color(0, 0, 0, 0.9))
	draw_string(f, p, text, HORIZONTAL_ALIGNMENT_LEFT, -1, 12, hcol)
	var lo := HPRules.house_rank_threshold(house_rank)
	var hi := HPRules.house_rank_threshold(house_rank + 1)
	var pct := 1.0 if house_rank >= HPRules.max_house_rank() else clampf(float(house_rep - lo) / maxf(1.0, float(hi - lo)), 0.0, 1.0)
	var bar := Rect2(Vector2(right - w, 102), Vector2(w, 3))
	draw_rect(bar, Color(0, 0, 0, 0.6))
	draw_rect(Rect2(bar.position, Vector2(bar.size.x * pct, bar.size.y)), hcol)

static func _thousands(v: int) -> String:
	var s := str(absi(v))
	var out := ""
	while s.length() > 3:
		out = "," + s.substr(s.length() - 3) + out
		s = s.substr(0, s.length() - 3)
	return ("-" if v < 0 else "") + s + out
