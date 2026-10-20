extends HudWindow
class_name HudWorldMap

## The map (M). Outdoors: the whole 2 x 2 km grounds as a painted atlas sheet
## (`assets/ui/world_map.jpg`, generated from the terrain heights and the layout
## by tools/ui/paint_world_map.py), with the place names, the people you can
## talk to, the Dark Monoliths and you - an arrow pointing the way you face with
## a light cone for where the camera looks. Inside Hogwarts: the castle's floor
## plans drawn from the layout (assets/castle/castle_layout.json) on parchment,
## one storey at a time, opening on yours.
## Right-click marks a waypoint (WaypointGuide): the route is drawn on the map
## and walked out in the world; right-click the mark again to clear it.
## Wheel zooms around the cursor, drag pans, and it opens centred on you.

const MAP_TEXTURE := "res://assets/ui/world_map.jpg"
const WORLD_MIN := Vector2(-1024, -1024)
const WORLD_SIZE := 2048.0
const CASTLE_MIN := Vector2(-118, -98)
const CASTLE_SIZE := 222.0
const PLACES := [
	["Hogwarts Castle", Vector2(30, -70), 1.25],
	["Black Lake", Vector2(0, 360), 1.15],
	["Forbidden Forest", Vector2(-650, 160), 1.2],
	["Hogsmeade", Vector2(680, -140), 1.0],
	["Northern Moors", Vector2(420, -720), 1.0],
	["Hagrid's Hut", Vector2(-330, -10), 0.8],
	["Greenhouses", Vector2(-190, -185), 0.8],
	["Courtyard", Vector2(0, 92), 0.75],
]
const FLOOR_NAMES := {-1: "Dungeons", 0: "Ground", 1: "1st", 2: "2nd", 3: "3rd", 4: "4th", 5: "5th", 6: "6th", 7: "7th"}
const PARCHMENT := Color(0.89, 0.81, 0.64)
const INK := Color(0.29, 0.18, 0.09)

var player: Node3D = null
var guide: WaypointGuide = null
var view: MapView
var _hint: Label
var _coords: Label
var _floors: HBoxContainer
var _floor_buttons := {}
## "grounds" or "castle"
var mode := "grounds"
var castle_level := 0
## The bestiary's "Show on map": one creature's packs (grounds x, z), its
## bosses, and its regions' names with their level bands.
var focus_name := ""
var focus_points: Array = []
var focus_bosses: Array = []
var focus_regions: Array = []

func _init() -> void:
	super._init("World Map", Vector2(660, 600))
	name = "WorldMap"
	modal = false

func _ready() -> void:
	super._ready()
	_floors = HBoxContainer.new()
	_floors.alignment = BoxContainer.ALIGNMENT_CENTER
	_floors.add_theme_constant_override("separation", 4)
	for lv in range(-1, 8):
		var b := HudKit.button(FLOOR_NAMES[lv], 13)
		b.toggle_mode = true
		b.custom_minimum_size = Vector2(54, 26)
		b.pressed.connect(func(): _show_level(lv))
		_floors.add_child(b)
		_floor_buttons[lv] = b
	body.add_child(_floors)
	view = MapView.new()
	view.host = self
	view.size_flags_vertical = Control.SIZE_EXPAND_FILL
	view.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	if ResourceLoader.exists(MAP_TEXTURE):
		view.texture = load(MAP_TEXTURE)
	body.add_child(view)
	_coords = HudKit.label("", 14, HudKit.PARCHMENT, HudKit.body(), 2)
	_coords.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	body.add_child(_coords)
	_hint = HudKit.label("", 13, HudKit.TEXT_DIM, HudKit.body(), 0)
	_hint.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	body.add_child(_hint)
	_apply_mode()

func _update_hint() -> void:
	if _hint == null:
		return
	_hint.text = "Right-click: set / clear waypoint  ·  Wheel: zoom  ·  Drag: move  ·  M / Esc: close"
	if mode == "grounds":
		_hint.text += "  ·  B: bestiary"
	if focus_name != "":
		_hint.text = "Showing %s (red marks)  ·  " % focus_name + _hint.text

func _detect_mode() -> String:
	if guide != null and is_instance_valid(guide):
		return "castle" if guide.current_map() == "castle_interior" else "grounds"
	if player != null and is_instance_valid(player) and player.global_position.y > 185.0:
		return "castle"
	return "grounds"

func _apply_mode() -> void:
	mode = _detect_mode()
	if _title != null:
		_title.text = "Hogwarts Castle" if mode == "castle" else "World Map"
	if _floors != null:
		_floors.visible = mode == "castle"
	_update_hint()

func _show_level(lv: int) -> void:
	castle_level = lv
	for k in _floor_buttons:
		(_floor_buttons[k] as Button).button_pressed = k == lv
	if view != null:
		view.queue_redraw()

## Mark every pack of `species` (and its bosses and regions) and open centred
## on the nearest one.
func focus_species(species: String, display: String) -> void:
	focus_name = display
	focus_points.clear()
	focus_bosses.clear()
	focus_regions.clear()
	var bands := {}
	for pack in HPRules.spawn_tables().get("packs", []):
		if String(pack.get("mob", "")) != species:
			continue
		var area: Array = pack.get("area", [0, 0, 0, 0])
		var at := Vector2(float(area[0]) + float(area[2]) * 0.5, float(area[1]) + float(area[3]) * 0.5)
		if bool(pack.get("boss", false)):
			focus_bosses.append(at)
			continue
		focus_points.append(at)
		var zone := String(pack.get("zone", ""))
		var band: Vector2i = bands.get(zone, Vector2i(999, 0))
		bands[zone] = Vector2i(mini(band.x, int(pack.get("level", 1))), maxi(band.y, int(pack.get("level", 1))))
	for zone in bands.keys():
		var region := HPRules.region_by_id(String(zone))
		var c: Array = region.get("center", [0, 0])
		var band: Vector2i = bands[zone]
		focus_regions.append([String(region.get("display", zone)), Vector2(float(c[0]), float(c[1])),
			"Lv %d" % band.x if band.x == band.y else "Lv %d–%d" % [band.x, band.y]])
	super.open()
	_apply_mode()
	if view == null or mode != "grounds":
		return
	await get_tree().process_frame
	view.zoom = maxf(view._min_zoom(), 0.3)
	var from := Vector2.ZERO
	if player != null and is_instance_valid(player):
		from = Vector2(player.global_position.x, player.global_position.z)
	var best := from
	var best_d := INF
	for p in focus_points + focus_bosses:
		if (p as Vector2).distance_to(from) < best_d:
			best_d = (p as Vector2).distance_to(from)
			best = p
	view.centre = best
	view._clamp()

func close() -> void:
	super.close()
	focus_name = ""
	focus_points.clear()
	focus_bosses.clear()
	focus_regions.clear()
	_update_hint()

func open() -> void:
	super.open()
	_apply_mode()
	if mode == "castle" and player != null and is_instance_valid(player):
		_show_level(WaypointRouter.castle_level(player.global_position.y))
	if view != null:
		await get_tree().process_frame
		view.centre_on_player()

func _process(_delta: float) -> void:
	if visible and view != null:
		if _detect_mode() != mode:
			_apply_mode()
			view.centre_on_player()
		view.queue_redraw()
		_update_coords()

## One way to write a place everywhere (minimap, this map, the waypoint):
## whole metres, x then z.
static func coords_text(at: Vector2) -> String:
	return "%d, %d" % [roundi(at.x), roundi(at.y)]

## You, the cursor and the waypoint, in world coordinates.
func _update_coords() -> void:
	if _coords == null:
		return
	var parts: Array = []
	if player != null and is_instance_valid(player):
		parts.append("You  " + coords_text(Vector2(player.global_position.x, player.global_position.z)))
	if view.hovering:
		parts.append("Cursor  " + coords_text(view.hover))
	if guide != null and is_instance_valid(guide) and guide.has_target():
		var mark := "Waypoint  " + coords_text(Vector2(guide.target.x, guide.target.z))
		if player != null and is_instance_valid(player):
			mark += "  (%d m)" % roundi(Vector2(player.global_position.x, player.global_position.z).distance_to(Vector2(guide.target.x, guide.target.z)))
		parts.append(mark)
	var text := "   ·   ".join(parts)
	if _coords.text != text:
		_coords.text = text

## Right-click on the map at world (x, z): set the waypoint there, or clear it
## when the click is on the current one.
func waypoint_click(w: Vector2, screen_hit_existing: bool) -> void:
	if guide == null or not is_instance_valid(guide):
		return
	if screen_hit_existing:
		guide.clear()
		return
	if mode == "castle":
		var y := float(castle_level) * 10.0
		var snapped := _snap_to_plate(w, y)
		guide.set_target("castle_interior", Vector3(snapped.x, WaypointRouter.CASTLE_Y + y + 0.1, snapped.y))
	else:
		var h := GroundsTerrain.height_at(w.x, w.y)
		guide.set_target("grounds", Vector3(w.x, 0.0 if is_nan(h) else h, w.y))

## The nearest point that stands on a floor of this storey.
func _snap_to_plate(w: Vector2, y: float) -> Vector2:
	var best := w
	var best_d := INF
	for plate in WaypointRouter.castle_plates():
		if absf(float(plate[1]) - y) > 1.0:
			continue
		var r: Array = plate[0]
		var p := Vector2(clampf(w.x, float(r[0]) + 0.5, float(r[1]) - 0.5), clampf(w.y, float(r[2]) + 0.5, float(r[3]) - 0.5))
		var d := p.distance_to(w)
		if d < best_d:
			best_d = d
			best = p
	return best


class MapView extends Control:
	var host: HudWorldMap
	var texture: Texture2D
	## Map pixels per world metre on screen, and the world point at the centre.
	var zoom := 0.45
	var centre := Vector2.ZERO
	var _dragging := false
	## The world point under the mouse while it is over the map.
	var hover := Vector2.ZERO
	var hovering := false
	var _hover_px := Vector2.ZERO

	func _init() -> void:
		clip_contents = true
		mouse_filter = Control.MOUSE_FILTER_STOP
		custom_minimum_size = Vector2(300, 300)

	func _bounds_min() -> Vector2:
		return HudWorldMap.CASTLE_MIN if host.mode == "castle" else HudWorldMap.WORLD_MIN

	func _bounds_size() -> float:
		return HudWorldMap.CASTLE_SIZE if host.mode == "castle" else HudWorldMap.WORLD_SIZE

	func centre_on_player() -> void:
		var p := host.player
		if p != null and is_instance_valid(p):
			centre = Vector2(p.global_position.x, p.global_position.z)
		zoom = maxf(_min_zoom(), 3.2 if host.mode == "castle" else 0.45)
		_clamp()

	func _min_zoom() -> float:
		return minf(size.x, size.y) / _bounds_size()

	func world_to_screen(w: Vector2) -> Vector2:
		return size * 0.5 + (w - centre) * zoom

	func screen_to_world(s: Vector2) -> Vector2:
		return centre + (s - size * 0.5) / zoom

	func _clamp() -> void:
		zoom = clampf(zoom, _min_zoom(), 3.0 if host.mode == "grounds" else 12.0)
		var half := size * 0.5 / zoom
		var lo := _bounds_min() + half
		var hi := _bounds_min() + Vector2.ONE * _bounds_size() - half
		var mid := _bounds_min() + Vector2.ONE * _bounds_size() * 0.5
		centre.x = clampf(centre.x, minf(lo.x, mid.x), maxf(hi.x, mid.x))
		centre.y = clampf(centre.y, minf(lo.y, mid.y), maxf(hi.y, mid.y))

	func _gui_input(event: InputEvent) -> void:
		if event is InputEventMouseButton:
			if event.button_index == MOUSE_BUTTON_WHEEL_UP or event.button_index == MOUSE_BUTTON_WHEEL_DOWN:
				var before := screen_to_world(event.position)
				zoom *= 1.18 if event.button_index == MOUSE_BUTTON_WHEEL_UP else 1.0 / 1.18
				_clamp()
				centre += before - screen_to_world(event.position)
				_clamp()
				accept_event()
			elif event.button_index == MOUSE_BUTTON_LEFT:
				_dragging = event.pressed
				accept_event()
			elif event.button_index == MOUSE_BUTTON_RIGHT and event.pressed:
				var hit := false
				var g := host.guide
				if g != null and is_instance_valid(g) and g.has_target():
					hit = world_to_screen(Vector2(g.target.x, g.target.z)).distance_to(event.position) < 14.0
				host.waypoint_click(screen_to_world(event.position), hit)
				accept_event()
		elif event is InputEventMouseMotion:
			if _dragging:
				centre -= event.relative / zoom
				_clamp()
				accept_event()
			_hover_px = event.position
			hover = screen_to_world(event.position)
			hovering = true

	func _notification(what: int) -> void:
		if what == NOTIFICATION_MOUSE_EXIT:
			hovering = false

	## One of the minimap's painted markers, centred on `at`.
	func _draw_marker(id: String, at: Vector2, px: float) -> void:
		var tex := UITheme.chrome(id)
		if tex == null:
			draw_circle(at, px * 0.3, HudKit.GOLD_LT)
			return
		draw_texture_rect(tex, Rect2(at - Vector2(px, px) * 0.5, Vector2(px, px)), false)

	func _draw() -> void:
		if host.mode == "castle":
			_draw_castle()
		else:
			_draw_grounds()
		_draw_route()
		_draw_player()
		_draw_cursor_coords()
		draw_rect(Rect2(Vector2.ZERO, size), HudKit.GOLD.darkened(0.2), false, 2.0)

	## A small dark tag beside the cursor with the world point under it.
	func _draw_cursor_coords() -> void:
		if not hovering or _dragging:
			return
		hover = screen_to_world(_hover_px)
		var f := HudKit.bold()
		var txt := HudWorldMap.coords_text(hover)
		var tw := f.get_string_size(txt, HORIZONTAL_ALIGNMENT_LEFT, -1, 13).x
		var at := _hover_px + Vector2(14, 18)
		at.x = minf(at.x, size.x - tw - 12.0)
		at.y = minf(at.y, size.y - 8.0)
		draw_rect(Rect2(at - Vector2(5, 15), Vector2(tw + 10, 20)), Color(0.02, 0.03, 0.05, 0.82))
		draw_rect(Rect2(at - Vector2(5, 15), Vector2(tw + 10, 20)), Color(HudKit.GOLD, 0.6), false, 1.0)
		draw_string(f, at, txt, HORIZONTAL_ALIGNMENT_LEFT, -1, 13, HudKit.GOLD_HI)

	func _draw_grounds() -> void:
		draw_rect(Rect2(Vector2.ZERO, size), Color(0.05, 0.05, 0.06))
		if texture != null:
			var tl := world_to_screen(HudWorldMap.WORLD_MIN)
			draw_texture_rect(texture, Rect2(tl, Vector2.ONE * HudWorldMap.WORLD_SIZE * zoom), false)
		# Place names.
		for spec in HudWorldMap.PLACES:
			var p := world_to_screen(spec[1])
			var fs := int(clampf(15.0 * float(spec[2]) * (0.75 + zoom * 0.6), 11.0, 30.0))
			var f := HudKit.deco()
			var txt := String(spec[0])
			var w := f.get_string_size(txt, HORIZONTAL_ALIGNMENT_LEFT, -1, fs).x
			var at := p - Vector2(w * 0.5, 0)
			draw_string_outline(f, at, txt, HORIZONTAL_ALIGNMENT_LEFT, -1, fs, 5, Color(0.98, 0.94, 0.84, 0.85))
			draw_string(f, at, txt, HORIZONTAL_ALIGNMENT_LEFT, -1, fs, Color(0.22, 0.13, 0.06))
		# The bestiary's creature: its packs, bosses and regions.
		if host.focus_name != "":
			var dot := clampf(2.2 + zoom * 2.2, 2.5, 6.0)
			for w in host.focus_points:
				var sp := world_to_screen(w)
				draw_circle(sp, dot + 1.2, Color(0.1, 0.02, 0.02, 0.9))
				draw_circle(sp, dot, Color(0.92, 0.2, 0.14))
			for w in host.focus_bosses:
				var bp := world_to_screen(w)
				draw_circle(bp, dot * 2.0 + 2.0, Color(0.1, 0.02, 0.02, 0.9))
				draw_circle(bp, dot * 2.0, Color(1.0, 0.78, 0.25))
			var rf := HudKit.bold()
			for spec in host.focus_regions:
				var rp := world_to_screen(spec[1]) + Vector2(0, -14)
				var txt := "%s  %s" % [spec[0], spec[2]]
				var w2 := rf.get_string_size(txt, HORIZONTAL_ALIGNMENT_LEFT, -1, 14).x
				draw_string_outline(rf, rp - Vector2(w2 * 0.5, 0), txt, HORIZONTAL_ALIGNMENT_LEFT, -1, 14, 5, Color(0, 0, 0, 0.9))
				draw_string(rf, rp - Vector2(w2 * 0.5, 0), txt, HORIZONTAL_ALIGNMENT_LEFT, -1, 14, Color(1.0, 0.82, 0.7))
		var tree := get_tree()
		# People to talk to.
		for n in tree.get_nodes_in_group("npcs"):
			if n is Node3D and is_instance_valid(n):
				var sp := world_to_screen(Vector2(n.global_position.x, n.global_position.z))
				_draw_marker("minimap_npc", sp, 20.0)
				if zoom > 0.7 and "npc_name" in n:
					var nf := HudKit.bold()
					draw_string_outline(nf, sp + Vector2(8, 4), String(n.npc_name), HORIZONTAL_ALIGNMENT_LEFT, -1, 13, 4, Color(0, 0, 0, 0.85))
					draw_string(nf, sp + Vector2(8, 4), String(n.npc_name), HORIZONTAL_ALIGNMENT_LEFT, -1, 13, HudKit.GOLD_HI)
		for m in tree.get_nodes_in_group("monoliths"):
			if m is Node3D and is_instance_valid(m) and m.visible:
				var mp := world_to_screen(Vector2(m.global_position.x, m.global_position.z))
				_draw_marker("minimap_monolith", mp, 24.0)

	## A Marauder's-Map style plan of one storey: parchment, inked walls, room
	## names, doors and the stairs that leave this floor.
	func _draw_castle() -> void:
		draw_rect(Rect2(Vector2.ZERO, size), HudWorldMap.PARCHMENT)
		# a little foxing so the sheet is not flat
		for i in 40:
			var hp := Vector2(fposmod(sin(i * 12.9898) * 43758.5, 1.0), fposmod(sin(i * 78.233) * 12345.6, 1.0)) * size
			draw_circle(hp, 18.0 + fposmod(i * 7.3, 30.0), Color(0.55, 0.4, 0.2, 0.035))
		var y := float(host.castle_level) * 10.0
		var d := WaypointRouter.castle_layout()
		var ink := HudWorldMap.INK
		var thin := maxf(1.0, zoom * 0.18)
		var fills := Color(0.95, 0.88, 0.72)
		# floors first (galleries, tongues, balconies), then rooms on top
		for f in d.get("floors", []):
			if absf(float(f["y"]) - y) > 1.0:
				continue
			_plate(f["rect"], fills.darkened(0.04), Color(ink, 0.55), thin)
		var labels: Array = []
		for r in d.get("rooms", []):
			if absf(float(r["y"]) - y) > 1.0 and not (float(r["y"]) < y and float(r["y"]) + float(r.get("h", 9)) > y + 1.0 and String(r["id"]) in ["grand_staircase", "service_stair"]):
				continue
			_plate(r["rect"], fills, ink, thin * 2.2)
			labels.append(r)
		# doors on this storey: a gap in the ink
		for door in d.get("doors", []):
			if absf(float(door["y"]) - y) > 1.0:
				continue
			var at: Array = door["at"]
			var c := world_to_screen(Vector2(float(at[0]), float(at[1])))
			var half := float(door.get("w", 3)) * 0.5 * zoom
			draw_rect(Rect2(c - Vector2(half, half), Vector2(half, half) * 2.0), fills)
			draw_circle(c, maxf(2.0, zoom * 0.5), Color(ink, 0.7))
		# stairs that start or end here
		for st in d.get("stairs", []):
			var a: Array = st["from"]
			var b: Array = st["to"]
			var here_a := absf(float(a[1]) - y) < 1.0
			var here_b := absf(float(b[1]) - y) < 1.0
			if not (here_a or here_b):
				continue
			var pa := world_to_screen(Vector2(float(a[0]), float(a[2])))
			var pb := world_to_screen(Vector2(float(b[0]), float(b[2])))
			var w := float(st.get("w", 3)) * zoom
			var dir := (pb - pa).normalized()
			var n := Vector2(-dir.y, dir.x)
			var steps := int(pa.distance_to(pb) / maxf(4.0, zoom * 0.8))
			for k in steps + 1:
				var p := pa.lerp(pb, float(k) / maxf(1, steps))
				draw_line(p - n * w * 0.5, p + n * w * 0.5, Color(ink, 0.45), 1.0)
			var up := float(b[1]) > float(a[1])
			var tip := pb if here_a else pa
			var arrow := "▲" if (here_a and up) or (here_b and not up) else "▼"
			_text(arrow, tip, 13, Color(ink, 0.85), HudKit.body())
		# the moving staircases' well
		var ms: Dictionary = d.get("moving_stairs", {})
		if ms.has("axis") and host.castle_level >= 0:
			var ax: Array = ms["axis"]
			var e := float(ms.get("edge", 10))
			var c := world_to_screen(Vector2(float(ax[0]), float(ax[1])))
			draw_arc(c, e * zoom, 0.0, TAU, 48, Color(ink, 0.5), thin, true)
			_text("moving stairs", c, 11, Color(ink, 0.6), HudKit.body())
		for r in labels:
			var rect: Array = r["rect"]
			var c := world_to_screen(Vector2((float(rect[0]) + float(rect[1])) * 0.5, (float(rect[2]) + float(rect[3])) * 0.5))
			var fs := int(clampf(6.0 + zoom * 2.2, 10.0, 22.0))
			_text(String(r.get("label", r["id"])), c, fs, ink, HudKit.deco())
		var title := "%s floor" % HudWorldMap.FLOOR_NAMES[host.castle_level] if host.castle_level >= 0 else "The Dungeons"
		var tf := HudKit.deco()
		var tw := tf.get_string_size(title, HORIZONTAL_ALIGNMENT_LEFT, -1, 17).x
		draw_rect(Rect2(Vector2(8, 8), Vector2(tw + 20, 28)), Color(HudWorldMap.PARCHMENT, 0.92))
		draw_rect(Rect2(Vector2(8, 8), Vector2(tw + 20, 28)), Color(ink, 0.6), false, 1.0)
		draw_string(tf, Vector2(18, 28), title, HORIZONTAL_ALIGNMENT_LEFT, -1, 17, Color(ink, 0.9))

	func _plate(rect: Array, fill: Color, line: Color, width: float) -> void:
		var a := world_to_screen(Vector2(float(rect[0]), float(rect[2])))
		var b := world_to_screen(Vector2(float(rect[1]), float(rect[3])))
		draw_rect(Rect2(a, b - a), fill)
		draw_rect(Rect2(a, b - a), line, false, width)

	func _text(txt: String, at: Vector2, fs: int, colour: Color, font: Font, centred := true) -> void:
		var w := font.get_string_size(txt, HORIZONTAL_ALIGNMENT_LEFT, -1, fs).x
		var pos := at - Vector2(w * 0.5, -fs * 0.35) if centred else at - Vector2(w * 0.5, 0)
		draw_string(font, pos, txt, HORIZONTAL_ALIGNMENT_LEFT, -1, fs, colour)

	## The waypoint's route as a dotted trail of footprints, and its pin.
	func _draw_route() -> void:
		var g := host.guide
		if g == null or not is_instance_valid(g) or not g.has_target():
			return
		var castle := host.mode == "castle"
		var on_map := (g.target_map == "castle_interior") == castle
		var pts := g.route()
		var colour := Color(0.55, 0.12, 0.06) if castle else Color(1.0, 0.85, 0.35)
		var shadow := Color(0, 0, 0, 0.0 if castle else 0.6)
		if pts.size() > 1:
			var spacing := 9.0
			var carry := 0.0
			var flip := false
			for i in pts.size() - 1:
				var a := pts[i]
				var b := pts[i + 1]
				if castle:
					var y := float(host.castle_level) * 10.0 + WaypointRouter.CASTLE_Y
					if absf(a.y - y) > 2.5 and absf(b.y - y) > 2.5:
						continue
				var sa := world_to_screen(Vector2(a.x, a.z))
				var sb := world_to_screen(Vector2(b.x, b.z))
				var seg := sa.distance_to(sb)
				var dir := (sb - sa).normalized() if seg > 0.01 else Vector2.UP
				var n := Vector2(-dir.y, dir.x)
				var t := carry
				while t < seg:
					var p := sa + dir * t + n * (2.2 if flip else -2.2)
					draw_circle(p, 2.6, shadow)
					draw_circle(p, 1.9, colour)
					flip = not flip
					t += spacing
				carry = t - seg
		if on_map:
			var pin := world_to_screen(Vector2(g.target.x, g.target.z))
			if castle and absf(g.target.y - WaypointRouter.CASTLE_Y - float(host.castle_level) * 10.0) > 2.5:
				colour = Color(colour, 0.45)
			draw_circle(pin + Vector2(0, -14), 7.5, Color(0, 0, 0, 0.55))
			draw_colored_polygon(PackedVector2Array([pin, pin + Vector2(-6, -12), pin + Vector2(6, -12)]), colour.darkened(0.2))
			draw_circle(pin + Vector2(0, -14), 6.5, colour)
			draw_circle(pin + Vector2(0, -14), 2.4, Color(1, 1, 1, 0.9))
			# the mark's coordinates over the pin
			var f := HudKit.bold()
			var txt := HudWorldMap.coords_text(Vector2(g.target.x, g.target.z))
			var tw := f.get_string_size(txt, HORIZONTAL_ALIGNMENT_LEFT, -1, 12).x
			var tp := pin + Vector2(-tw * 0.5, -26)
			draw_string_outline(f, tp, txt, HORIZONTAL_ALIGNMENT_LEFT, -1, 12, 4, Color(0, 0, 0, 0.9))
			draw_string(f, tp, txt, HORIZONTAL_ALIGNMENT_LEFT, -1, 12, Color(1.0, 0.92, 0.7))

	func _draw_player() -> void:
		var p := host.player
		if p == null or not is_instance_valid(p):
			return
		if host.mode == "castle" and WaypointRouter.castle_level(p.global_position.y) != host.castle_level:
			return
		var pp := world_to_screen(Vector2(p.global_position.x, p.global_position.z))
		var cam_yaw := deg_to_rad(float(p.get("camera_rot_y")))
		MapMarker.draw_view_cone(self, pp, Vector2(-sin(cam_yaw), -cos(cam_yaw)), 90.0)
		var visuals: Node3D = p.get("visuals")
		var yaw := visuals.rotation.y if visuals != null else 0.0
		MapMarker.draw_arrow(self, pp, Vector2(sin(yaw), cos(yaw)), 13.0)
