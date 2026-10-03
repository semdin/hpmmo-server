extends Node

## GameData Autoload - Central Database for HPMMO
## Houses, Spells, Items, Ollivander Upgrade Logic, and Input Registration

# House Factions
var HOUSES: Dictionary = {
	"Gryffindor": {
		"name": "Gryffindor",
		"primary_color": Color(0.78, 0.08, 0.12),
		"secondary_color": Color(0.95, 0.77, 0.12),
		"trait": "Bravery: +15% Fire Spell Damage & +10% Critical Strike Chance",
		"motto": "Forti Animo Estote"
	},
	"Slytherin": {
		"name": "Slytherin",
		"primary_color": Color(0.08, 0.45, 0.18),
		"secondary_color": Color(0.75, 0.75, 0.78),
		"trait": "Ambition: +20% Dark Magic Damage & Life Leech",
		"motto": "Soli Fortes Praevalent"
	},
	"Ravenclaw": {
		"name": "Ravenclaw",
		"primary_color": Color(0.08, 0.28, 0.58),
		"secondary_color": Color(0.82, 0.55, 0.22),
		"trait": "Wisdom: -20% Spell Cooldowns & +25% Max Mana",
		"motto": "Sapientia Super Omnia"
	},
	"Hufflepuff": {
		"name": "Hufflepuff",
		"primary_color": Color(0.92, 0.72, 0.15),
		"secondary_color": Color(0.18, 0.18, 0.18),
		"trait": "Loyalty: +25% Max Health & +15% Physical/Magic Armor",
		"motto": "In Fidelitate Robur"
	}
}

# Spells Database
var SPELLS: Dictionary = {
	"basic_cast": {
		"id": "basic_cast",
		"name": "Basic Cast",
		"desc": "Quick wand flick releasing a spark of magic.",
		"damage": 35,
		"cooldown": 0.45,
		"mana_cost": 0,
		"range": 28.0,
		"projectile_speed": 40.0,
		"color": Color(1.0, 0.85, 0.4),
		"hotkey": "LMB"
	},
	"stupefy": {
		"id": "stupefy",
		"name": "Stupefy",
		"desc": "Stunning spell. Hits target, deals damage and stuns for 1.8 seconds.",
		"damage": 85,
		"cooldown": 3.0,
		"mana_cost": 25,
		"range": 30.0,
		"projectile_speed": 45.0,
		"color": Color(1.0, 0.15, 0.15),
		"stun_duration": 1.8,
		"hotkey": "1"
	},
	"incendio": {
		"id": "incendio",
		"name": "Incendio",
		"desc": "Cone blast of roaring magical fire. Burns enemies over 4 seconds. Extra damage to Inferi.",
		"damage": 120,
		"burn_damage": 30,
		"burn_ticks": 4,
		"cooldown": 5.0,
		"mana_cost": 40,
		"range": 16.0,
		"cone_angle": 60.0,
		"color": Color(1.0, 0.45, 0.05),
		"hotkey": "2"
	},
	"bombarda": {
		"id": "bombarda",
		"name": "Bombarda",
		"desc": "Detonates a violent concussive shockwave. Deals heavy AOE damage with knockback.",
		"damage": 160,
		"radius": 8.0,
		"cooldown": 7.0,
		"mana_cost": 55,
		"range": 26.0,
		"projectile_speed": 35.0,
		"color": Color(1.0, 0.7, 0.1),
		"knockback": 12.0,
		"hotkey": "3"
	},
	"expelliarmus": {
		"id": "expelliarmus",
		"name": "Expelliarmus",
		"desc": "Disarming charm. Knocks back enemy, interrupts casts and reduces target power by 30%.",
		"damage": 75,
		"cooldown": 4.5,
		"mana_cost": 30,
		"range": 32.0,
		"projectile_speed": 48.0,
		"color": Color(0.9, 0.2, 0.2),
		"hotkey": "4"
	},
	"protego": {
		"id": "protego",
		"name": "Protego",
		"desc": "Summons a shimmering magical dome shield that reflects incoming bolts and halves damage.",
		"damage": 0,
		"duration": 3.5,
		"cooldown": 10.0,
		"mana_cost": 45,
		"color": Color(0.2, 0.7, 1.0),
		"hotkey": "Q"
	},
	"ultimate": {
		"id": "ultimate",
		"name": "House Ultimate",
		"desc": "Signature high-tier spell (Avada Kedavra / Expecto Patronum).",
		"damage": 350,
		"cooldown": 25.0,
		"mana_cost": 100,
		"range": 35.0,
		"projectile_speed": 55.0,
		"color": Color(0.2, 1.0, 0.3),
		"hotkey": "E"
	}
}

# Ollivander +0 to +9 Upgrade Table
# Success rates, Galleon cost, required items, damage multipliers, and aura visual styles
const UPGRADE_TABLE = {
	0: {"next": 1, "chance": 100, "cost": 100, "material": "Phoenix Ash x1", "multiplier": 1.00, "aura": Color(0.7, 0.7, 0.7, 0.0)},
	1: {"next": 2, "chance": 100, "cost": 250, "material": "Phoenix Ash x1", "multiplier": 1.12, "aura": Color(0.7, 0.7, 0.7, 0.0)},
	2: {"next": 3, "chance": 95, "cost": 500, "material": "Phoenix Ash x2", "multiplier": 1.25, "aura": Color(0.7, 0.7, 0.7, 0.0)},
	3: {"next": 4, "chance": 85, "cost": 1000, "material": "Phoenix Ash x3", "multiplier": 1.40, "aura": Color(0.3, 0.7, 1.0, 0.4)}, # Subtle blue
	4: {"next": 5, "chance": 75, "cost": 2000, "material": "Dragon Heartstring x1", "multiplier": 1.60, "aura": Color(0.2, 0.8, 1.0, 0.6)},
	5: {"next": 6, "chance": 60, "cost": 4000, "material": "Dragon Heartstring x2", "multiplier": 1.85, "aura": Color(0.1, 0.9, 1.0, 0.8)},
	6: {"next": 7, "chance": 45, "cost": 8000, "material": "Thestral Hair x1", "multiplier": 2.15, "aura": Color(1.0, 0.85, 0.2, 0.9)}, # Golden Lightning
	7: {"next": 8, "chance": 30, "cost": 15000, "material": "Thestral Hair x2", "multiplier": 2.50, "aura": Color(1.0, 0.6, 0.1, 1.0)}, # Flame sparks
	8: {"next": 9, "chance": 15, "cost": 30000, "material": "Elder Wood Core x1", "multiplier": 3.00, "aura": Color(0.9, 0.2, 1.0, 1.0)}, # Legendary Phoenix/Elder Aura
	9: {"next": 9, "chance": 0, "cost": 0, "material": "MAX TIER", "multiplier": 3.50, "aura": Color(1.0, 0.9, 0.4, 1.0)}
}

# Items Database
var ITEMS: Dictionary = {
	"wand_hawthorn": {
		"id": "wand_hawthorn",
		"name": "Hawthorn Wand",
		"type": "weapon",
		"base_damage": 30,
		"level": 0,
		"icon_color": Color(0.65, 0.45, 0.25),
		"desc": "A supple wand made of hawthorn with unicorn hair core."
	},
	"wand_elder": {
		"id": "wand_elder",
		"name": "Elder Wand Replica",
		"type": "weapon",
		"base_damage": 55,
		"level": 0,
		"icon_color": Color(0.85, 0.75, 0.35),
		"desc": "Carved from ancient elder wood, thrumming with arcane energy."
	},
	"robe_apprentice": {
		"id": "robe_apprentice",
		"name": "Hogwarts Student Robes",
		"type": "armor",
		"defense": 15,
		"level": 0,
		"icon_color": Color(0.2, 0.2, 0.25),
		"desc": "Standard enchanted robes offering basic spell deflection."
	},
	"broom_nimbus2000": {
		"id": "broom_nimbus2000",
		"name": "Nimbus 2000",
		"type": "mount",
		"speed_bonus": 1.8,
		"icon_color": Color(0.8, 0.4, 0.1),
		"desc": "Sleek mahogany racing broom. Press Shift to mount or dismount (Ctrl descends while flying)."
	},
	"mat_phoenix_ash": {
		"id": "mat_phoenix_ash",
		"name": "Phoenix Ash",
		"type": "material",
		"stack": 1,
		"icon_color": Color(1.0, 0.4, 0.1),
		"desc": "Warm glowing ash required by Ollivander to refine items up to +4."
	},
	"mat_dragon_heartstring": {
		"id": "mat_dragon_heartstring",
		"name": "Dragon Heartstring",
		"type": "material",
		"stack": 1,
		"icon_color": Color(0.9, 0.1, 0.3),
		"desc": "Vibrant dragon essence used for +5 to +6 Ollivander wand upgrades."
	},
	"mat_thestral_hair": {
		"id": "mat_thestral_hair",
		"name": "Thestral Hair",
		"type": "material",
		"stack": 1,
		"icon_color": Color(0.6, 0.6, 0.8),
		"desc": "Ethereal core fiber required for high tier (+7 to +8) wand forging."
	},
	"mat_elder_core": {
		"id": "mat_elder_core",
		"name": "Elder Wood Core",
		"type": "material",
		"stack": 1,
		"icon_color": Color(1.0, 0.85, 0.2),
		"desc": "The rarest catalyst in the wizarding world. Forges +9 mastercraft."
	},
	"potion_health": {
		"id": "potion_health",
		"name": "Wiggenweld Potion",
		"type": "consumable",
		"heal_amount": 150,
		"stack": 1,
		"icon_color": Color(0.2, 0.8, 0.3),
		"desc": "Healing draught that restores 150 Health instantly."
	},
	"potion_mana": {
		"id": "potion_mana",
		"name": "Pepperup Potion",
		"type": "consumable",
		"mana_amount": 120,
		"stack": 1,
		"icon_color": Color(0.1, 0.4, 0.95),
		"desc": "Steaming potion that restores 120 Mana."
	}
}

var QUESTS: Dictionary = {}

## Protected volumes (Phase 1) loaded from res://data/json/safe_zones.json.
## Consumed by scripts/world/safe_zone.gd.
var SAFE_ZONES: Dictionary = {}

func _ready() -> void:
	_load_json_data()
	_register_input_actions()

func _load_json_data() -> void:
	var spells_json = _read_json_file("res://data/json/spells.json")
	if spells_json is Dictionary and not spells_json.is_empty():
		for k in spells_json:
			var s = spells_json[k]
			if s.has("color") and s["color"] is String:
				s["color"] = Color.from_string(s["color"], Color.WHITE)
			SPELLS[k] = s
	
	var items_json = _read_json_file("res://data/json/items.json")
	if items_json is Dictionary and not items_json.is_empty():
		for k in items_json:
			ITEMS[k] = items_json[k]

	var houses_json = _read_json_file("res://data/json/houses.json")
	if houses_json is Dictionary and not houses_json.is_empty():
		for k in houses_json:
			var h = houses_json[k]
			if h.has("primary_color") and h["primary_color"] is String:
				h["primary_color"] = Color.from_string(h["primary_color"], Color.WHITE)
			if h.has("secondary_color") and h["secondary_color"] is String:
				h["secondary_color"] = Color.from_string(h["secondary_color"], Color.WHITE)
			HOUSES[k] = h

	var quests_json = _read_json_file("res://data/json/quests.json")
	if quests_json is Dictionary and not quests_json.is_empty():
		QUESTS = quests_json

	var zones_json = _read_json_file("res://data/json/safe_zones.json")
	if zones_json is Dictionary and not zones_json.is_empty():
		SAFE_ZONES = zones_json
	print("[GameData] Static JSON configs loaded into RAM: %d Spells, %d Items, %d Houses, %d Quests, %d Safe Zones" % [
		SPELLS.size(), ITEMS.size(), HOUSES.size(), QUESTS.size(), (SAFE_ZONES.get("zones", []) as Array).size()
	])

func _read_json_file(path: String) -> Variant:
	if not FileAccess.file_exists(path):
		return null
	var file := FileAccess.open(path, FileAccess.READ)
	if not file:
		return null
	var content := file.get_as_text()
	var json := JSON.new()
	var err := json.parse(content)
	if err == OK:
		return json.data
	return null

## Automatically register inputs so WASD, Tab, Space, 1-4, Q, E, Z, I, O work reliably
func _register_input_actions() -> void:
	_ensure_action("move_forward", [KEY_W, KEY_UP])
	_ensure_action("move_backward", [KEY_S, KEY_DOWN])
	_ensure_action("move_left", [KEY_A, KEY_LEFT])
	_ensure_action("move_right", [KEY_D, KEY_RIGHT])
	_ensure_action("jump", [KEY_SPACE])
	_ensure_action("flight_descend", [KEY_CTRL])
	_ensure_action("mount_broom", [KEY_SHIFT])
	_ensure_action("target_cycle", [KEY_TAB])
	_ensure_action("pickup_loot", [KEY_Z, KEY_QUOTELEFT])
	_ensure_action("toggle_inventory", [KEY_I])
	_ensure_action("toggle_ollivander", [KEY_O])
	_ensure_action("toggle_chat", [KEY_ENTER])
	_ensure_action("interact", [KEY_F])
	
	# Spell Hotkeys
	_ensure_action("spell_1", [KEY_1])
	_ensure_action("spell_2", [KEY_2])
	_ensure_action("spell_3", [KEY_3])
	_ensure_action("spell_4", [KEY_4])
	_ensure_action("spell_q", [KEY_Q])
	_ensure_action("spell_e", [KEY_E])

func _ensure_action(action_name: String, key_codes: Array) -> void:
	if not InputMap.has_action(action_name):
		InputMap.add_action(action_name)
	for key in key_codes:
		var event := InputEventKey.new()
		event.physical_keycode = key
		if not InputMap.action_has_event(action_name, event):
			InputMap.action_add_event(action_name, event)
