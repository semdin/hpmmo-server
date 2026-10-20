extends HudWindow
class_name HudBestiary

## The bestiary (B): every creature of the realm with a portrait, a line of
## lore and a few short facts - where it is found, its boss, what it is weak
## to and what it shrugs off. "Show on map" opens the world map with that
## creature's packs marked. Everything is read from the same data the authority
## spawns from (spawn_tables.json, mobs.json, dungeons.json), so it never lies
## about where a creature lives.

const PORTRAITS := "res://assets/ui/bestiary/%s.png"
const LORE := {
	"inferi": "Corpses bewitched to serve a dark wizard. Slow, relentless and terrified of fire.",
	"acromantula": "Giant spiders of the Forbidden Forest, bred from Aragog's line. They hunt in packs.",
	"darksnatcher": "Wizards turned bounty hunters, roaming the roads in gangs. Some cast from range.",
	"troll_forest": "Hulking forest trolls with crude clubs. Slow to anger, slower to fall.",
	"troll_mountain": "The largest trolls, grey-skinned and thick-hided, guarding the high moors.",
	"dementor": "Soul-sucking guards of Azkaban. Their cold drains your will; only a Patronus truly drives them off.",
	"cornish_pixie": "Electric-blue pests that lift wizards off their feet and hurl them about.",
	"armour_guard": "Suits of armour enchanted to defend the forbidden third floor.",
	"armour_commander": "A cursed suit that commands the others. Its shield turns aside blows from the front.",
	"devils_snare": "A creeping plant that strangles whatever struggles. Burn its vines to reach the heart.",
	"fluffy": "Hagrid's three-headed dog, guarding the trapdoor. Music sends it to sleep.",
	"acromantula_venomfang": "Lean, long-legged hunters of the Blackweb Caverns. Their emerald venom burns for seconds after the bite.",
	"acromantula_broodguard": "Bone-plated giants that guard the egg caverns. Their armour turns blows from the front; their webs pin you down.",
}
const RESIST_NAMES := {"fire": "Fire (Incendio)", "stun": "Stuns", "force": "Force (Depulso)",
	"patronus": "Patronus", "arcane": "Arcane"}
## Dungeon entrances on the world map (grounds x, z) and how to reach them.
const DUNGEON_WHERE := {
	"trial": ["Trial Hall", "beside the courtyard", Vector2(18, 93)],
	"forbidden_corridor": ["The Forbidden Corridor", "Hogwarts Castle, third-floor east corridor", Vector2(65, -11)],
}

var world_map: HudWorldMap = null
var _entries: Array = []
var _list: VBoxContainer
var _detail: VBoxContainer
var _selected := ""

func _init() -> void:
	super._init("Bestiary", Vector2(760, 520))
	name = "Bestiary"

func _ready() -> void:
	super._ready()
	_entries = build_entries()
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 14)
	row.size_flags_vertical = Control.SIZE_EXPAND_FILL
	body.add_child(row)
	var list_scroll := ScrollContainer.new()
	list_scroll.custom_minimum_size = Vector2(260, 0)
	list_scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	row.add_child(list_scroll)
	_list = VBoxContainer.new()
	_list.add_theme_constant_override("separation", 4)
	_list.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	list_scroll.add_child(_list)
	var detail_scroll := ScrollContainer.new()
	detail_scroll.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	detail_scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	row.add_child(detail_scroll)
	_detail = VBoxContainer.new()
	_detail.add_theme_constant_override("separation", 8)
	_detail.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	detail_scroll.add_child(_detail)
	for entry in _entries:
		_list.add_child(_list_row(entry))
	if not _entries.is_empty():
		_show(String(_entries[0]["species"]))

## One entry per creature: its catalog identity plus every place it lives.
static func build_entries() -> Array:
	var tables := HPRules.spawn_tables()
	var by_species := {}
	for pack in tables.get("packs", []):
		var species := String(pack.get("mob", ""))
		var e: Dictionary = by_species.get(species, {"species": species, "regions": {}, "bosses": [], "dungeons": [],
			"level_min": 999, "level_max": 0, "aggressive_from": 0})
		var level := int(pack.get("level", 1))
		if bool(pack.get("boss", false)):
			var key := String(pack.get("boss_key", ""))
			var name := String((tables.get("boss_overrides", {}) as Dictionary).get(key, {}).get("name", ""))
			if name == "":
				name = "Acromantula Matriarch" if species == "acromantula" else "Dark Snatcher Commander"
			var region := HPRules.region_by_id(String(pack.get("zone", "")))
			var area: Array = pack.get("area", [0, 0, 0, 0])
			e["bosses"].append({"name": name, "level": level, "world": bool(pack.get("world_boss", false)),
				"region": String(region.get("display", pack.get("zone", ""))),
				"at": Vector2(float(area[0]) + float(area[2]) * 0.5, float(area[1]) + float(area[3]) * 0.5)})
		else:
			var zone := String(pack.get("zone", ""))
			var r: Dictionary = e["regions"].get(zone, {"zone": zone, "packs": 0, "lo": 999, "hi": 0})
			r["packs"] = int(r["packs"]) + 1
			r["lo"] = mini(int(r["lo"]), level)
			r["hi"] = maxi(int(r["hi"]), level)
			e["regions"][zone] = r
			e["level_min"] = mini(int(e["level_min"]), level)
			e["level_max"] = maxi(int(e["level_max"]), level)
			if String(pack.get("aggro_mode", "")) == "aggressive":
				var from := int(e["aggressive_from"])
				e["aggressive_from"] = level if from == 0 else mini(from, level)
		by_species[species] = e
	for id in HPMaps.dungeons().keys():
		var dungeon: Dictionary = HPMaps.dungeons()[id]
		for step in dungeon.get("steps", []):
			for spawn in step.get("spawn", []):
				var species := String(spawn.get("mob", ""))
				var e: Dictionary = by_species.get(species, {"species": species, "regions": {}, "bosses": [], "dungeons": [],
					"level_min": 999, "level_max": 0, "aggressive_from": 0})
				var listed := false
				for d in e["dungeons"]:
					listed = listed or String(d["id"]) == String(id)
				if not listed:
					e["dungeons"].append({"id": String(id), "level_min": int(dungeon.get("level_min", 1)),
						"per_day": int(dungeon.get("entries_per_day", 0))})
				if e["regions"].is_empty():
					e["level_min"] = mini(int(e["level_min"]), int(spawn.get("level", 1)))
					e["level_max"] = maxi(int(e["level_max"]), int(spawn.get("level", 1)))
				by_species[species] = e
	var out: Array = []
	for species in by_species.keys():
		var def := HPRules.mob_def(String(species))
		if def.is_empty() or String(species) in ["snare_vine", "fluffy_head"]:
			continue
		var e: Dictionary = by_species[species]
		e["display"] = String(def.get("display", species))
		e["family"] = String(def.get("family", ""))
		e["role"] = String(def.get("role", ""))
		e["resist"] = def.get("resist", {})
		e["abilities"] = def.get("abilities", [])
		out.append(e)
	out.sort_custom(func(a, b): return int(a["level_min"]) < int(b["level_min"]))
	return out

func _portrait(species: String, px: int) -> TextureRect:
	var rect := TextureRect.new()
	rect.custom_minimum_size = Vector2(px, px)
	rect.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	rect.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
	var path := PORTRAITS % species
	if ResourceLoader.exists(path):
		rect.texture = load(path)
	return rect

func _list_row(entry: Dictionary) -> Button:
	var b := Button.new()
	b.name = "Row_" + String(entry["species"])
	b.toggle_mode = true
	b.focus_mode = Control.FOCUS_NONE
	b.custom_minimum_size = Vector2(0, 54)
	for state in ["normal", "hover", "pressed", "hover_pressed"]:
		b.add_theme_stylebox_override(state, HudKit.button_box("hover" if state != "normal" else "normal"))
	var row := HBoxContainer.new()
	row.mouse_filter = Control.MOUSE_FILTER_IGNORE
	row.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	row.add_theme_constant_override("separation", 8)
	b.add_child(row)
	var pic := _portrait(String(entry["species"]), 48)
	pic.mouse_filter = Control.MOUSE_FILTER_IGNORE
	row.add_child(pic)
	var col := VBoxContainer.new()
	col.mouse_filter = Control.MOUSE_FILTER_IGNORE
	col.alignment = BoxContainer.ALIGNMENT_CENTER
	col.add_theme_constant_override("separation", 0)
	col.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	col.clip_contents = true
	row.add_child(col)
	var title := HudKit.label(String(entry["display"]), 15, HudKit.GOLD_LT, HudKit.bold(), 3)
	title.mouse_filter = Control.MOUSE_FILTER_IGNORE
	title.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
	title.tooltip_text = String(entry["display"])
	col.add_child(title)
	var sub := HudKit.label(_level_text(entry) + ("  ·  dungeon" if entry["regions"].is_empty() else ""), 12, HudKit.TEXT_DIM, HudKit.body(), 2)
	sub.mouse_filter = Control.MOUSE_FILTER_IGNORE
	col.add_child(sub)
	b.pressed.connect(func(): _show(String(entry["species"])))
	return b

func _level_text(entry: Dictionary) -> String:
	var lo := int(entry["level_min"])
	var hi := int(entry["level_max"])
	if lo > hi:
		return ""
	return "Lv %d" % lo if lo == hi else "Lv %d–%d" % [lo, hi]

func _entry(species: String) -> Dictionary:
	for e in _entries:
		if String(e["species"]) == species:
			return e
	return {}

func _show(species: String) -> void:
	_selected = species
	for row in _list.get_children():
		(row as Button).button_pressed = row.name == "Row_" + species
	for child in _detail.get_children():
		child.queue_free()
	var e := _entry(species)
	if e.is_empty():
		return
	var head := HBoxContainer.new()
	head.add_theme_constant_override("separation", 14)
	_detail.add_child(head)
	head.add_child(_portrait(species, 140))
	var id_col := VBoxContainer.new()
	id_col.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	id_col.alignment = BoxContainer.ALIGNMENT_CENTER
	head.add_child(id_col)
	id_col.add_child(HudKit.label(String(e["display"]), 24, HudKit.GOLD_HI, HudKit.title(), 4))
	id_col.add_child(HudKit.label("%s  ·  %s" % [_level_text(e), String(e["family"]).capitalize()],
		14, HudKit.TEXT_DIM, HudKit.body(), 2))
	var lore := HudKit.label(String(LORE.get(species, "")), 14, HudKit.TEXT, HudKit.body(), 2)
	lore.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	lore.custom_minimum_size = Vector2(300, 0)
	id_col.add_child(lore)
	if not (e["regions"] as Dictionary).is_empty() or not (e["bosses"] as Array).is_empty():
		var show := HudKit.button("Show on map", 14)
		show.focus_mode = Control.FOCUS_NONE
		show.size_flags_horizontal = Control.SIZE_SHRINK_BEGIN
		show.pressed.connect(_show_on_map)
		id_col.add_child(show)

	# Short and scannable: where (region names only), the boss, weak / strong.
	var regions: Array = (e["regions"] as Dictionary).values()
	regions.sort_custom(func(a, b): return int(a["lo"]) < int(b["lo"]))
	var names: Array = regions.map(func(r): return String(HPRules.region_by_id(String(r["zone"])).get("display", r["zone"])))
	if names.size() > 3:
		names = names.slice(0, 3) + ["+%d more" % (names.size() - 3)]
	for d in e["dungeons"]:
		names.append(String((DUNGEON_WHERE.get(String(d["id"]), [String(d["id"])]) as Array)[0]) + " (dungeon)")
	if not names.is_empty():
		_fact("Found", ", ".join(names))
	for boss in e["bosses"]:
		_fact("Boss", "%s  ·  Lv %d" % [String(boss["name"]), int(boss["level"])], HudKit.GOLD_LT)
	var weak: Array = []
	var strong: Array = []
	var resist: Dictionary = e["resist"]
	for k in resist.keys():
		var v := float(resist[k])
		var label := String(RESIST_NAMES.get(k, String(k).capitalize()))
		if v < 0.0:
			weak.append(label)
		elif v >= 0.3:
			strong.append(label)
	if not weak.is_empty():
		_fact("Weak", ", ".join(weak), Color(0.6, 1.0, 0.6))
	if not strong.is_empty():
		_fact("Resists", ", ".join(strong), Color(1.0, 0.75, 0.55))
	if int(e["aggressive_from"]) > 0:
		_fact("Aggressive", "from Lv %d" % int(e["aggressive_from"]), Color(1.0, 0.6, 0.5))

## One short labelled line: "Found   Village Outskirts, Pitch Woods".
func _fact(caption: String, text: String, colour: Color = HudKit.TEXT) -> void:
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 10)
	var c := HudKit.label(caption.to_upper(), 12, HudKit.GOLD, HudKit.bold(), 2)
	c.custom_minimum_size = Vector2(86, 0)
	row.add_child(c)
	var l := HudKit.label(text, 14, colour, HudKit.body(), 2)
	l.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	l.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	row.add_child(l)
	_detail.add_child(row)

func _show_on_map() -> void:
	if world_map == null or _selected == "":
		return
	var e := _entry(_selected)
	close()
	world_map.focus_species(_selected, String(e.get("display", _selected)))
