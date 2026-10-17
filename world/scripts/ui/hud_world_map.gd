extends HudWindow
class_name HudWorldMap

## The world map (M): the whole 2 x 2 km grounds as a painted atlas sheet
## (`assets/ui/world_map.jpg`, generated from the terrain heights and the layout
## by tools/ui/paint_world_map.py), with the place names, the people you can
## talk to, the Dark Monoliths and you - an arrow pointing the way you face with
## a light cone for where the camera looks. Wheel zooms around the cursor, drag
## pans, and it opens centred on you.

const MAP_TEXTURE := "res://assets/ui/world_map.jpg"
const WORLD_MIN := Vector2(-1024, -1024)
const WORLD_SIZE := 2048.0
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

var player: Node3D = null
var view: MapView
var _hint: Label
## The bestiary's "Show on map": one creature's packs (grounds x, z), its
## bosses, and its regions' names with their level bands.
var focus_name := ""
var focus_points: Array = []
var focus_bosses: Array = []
var focus_regions: Array = []

func _init() -> void:
	super._init("World Map", Vector2(620, 560))
	name = "WorldMap"
	modal = false

func _ready() -> void:
	super._ready()
	view = MapView.new()
	view.host = self
	view.size_flags_vertical = Control.SIZE_EXPAND_FILL
	view.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	if ResourceLoader.exists(MAP_TEXTURE):
		view.texture = load(MAP_TEXTURE)
	body.add_child(view)
	_hint = HudKit.label("", 13, HudKit.TEXT_DIM, HudKit.body(), 0)
	_hint.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	body.add_child(_hint)
	_update_hint()

func _update_hint() -> void:
	if _hint == null:
		return
	_hint.text = "Wheel: zoom  ·  Drag: move  ·  M / Esc: close  ·  B: bestiary"
	if focus_name != "":
		_hint.text = "Showing %s (red marks)  ·  " % focus_name + _hint.text

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
	_update_hint()
	super.open()
	if view == null:
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
	if view != null:
		await get_tree().process_frame
		view.centre_on_player()

func _process(_delta: float) -> void:
	if visible and view != null:
		view.queue_redraw()


class MapView extends Control:
	var host: HudWorldMap
	var texture: Texture2D
	## Map pixels per world metre on screen, and the world point at the centre.
	var zoom := 0.45
	var centre := Vector2.ZERO
	var _dragging := false

	func _init() -> void:
		clip_contents = true
		mouse_filter = Control.MOUSE_FILTER_STOP
		custom_minimum_size = Vector2(300, 300)

	func centre_on_player() -> void:
		var p := host.player
		if p != null and is_instance_valid(p):
			centre = Vector2(p.global_position.x, p.global_position.z)
		zoom = maxf(_min_zoom(), 0.45)
		_clamp()

	func _min_zoom() -> float:
		return minf(size.x, size.y) / HudWorldMap.WORLD_SIZE

	func world_to_screen(w: Vector2) -> Vector2:
		return size * 0.5 + (w - centre) * zoom

	func screen_to_world(s: Vector2) -> Vector2:
		return centre + (s - size * 0.5) / zoom

	func _clamp() -> void:
		zoom = clampf(zoom, _min_zoom(), 3.0)
		var half := size * 0.5 / zoom
		var lo := HudWorldMap.WORLD_MIN + half
		var hi := HudWorldMap.WORLD_MIN + Vector2.ONE * HudWorldMap.WORLD_SIZE - half
		centre.x = clampf(centre.x, minf(lo.x, 0.0), maxf(hi.x, 0.0))
		centre.y = clampf(centre.y, minf(lo.y, 0.0), maxf(hi.y, 0.0))

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
		elif event is InputEventMouseMotion and _dragging:
			centre -= event.relative / zoom
			_clamp()
			accept_event()

	## One of the minimap's painted markers, centred on `at`.
	func _draw_marker(id: String, at: Vector2, px: float) -> void:
		var tex := UITheme.chrome(id)
		if tex == null:
			draw_circle(at, px * 0.3, HudKit.GOLD_LT)
			return
		draw_texture_rect(tex, Rect2(at - Vector2(px, px) * 0.5, Vector2(px, px)), false)

	func _draw() -> void:
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
		# You.
		var p := host.player
		if p != null and is_instance_valid(p):
			var pp := world_to_screen(Vector2(p.global_position.x, p.global_position.z))
			var cam_yaw := deg_to_rad(float(p.get("camera_rot_y")))
			MapMarker.draw_view_cone(self, pp, Vector2(-sin(cam_yaw), -cos(cam_yaw)), 90.0)
			var visuals: Node3D = p.get("visuals")
			var yaw := visuals.rotation.y if visuals != null else 0.0
			MapMarker.draw_arrow(self, pp, Vector2(sin(yaw), cos(yaw)), 13.0)
		# Frame.
		draw_rect(Rect2(Vector2.ZERO, size), HudKit.GOLD.darkened(0.2), false, 2.0)
