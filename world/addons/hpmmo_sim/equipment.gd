extends RefCounted
class_name HPEquipment

## Server-owned item rules. Pure transformations also power client comparisons.
const SLOTS := ["head", "chest", "hands", "feet", "main_hand", "off_hand", "neck", "ring_left", "ring_right", "broom"]
const BASIC_ACCESSORIES := ["hat_apprentice", "gloves_apprentice", "boots_apprentice", "focus_apprentice", "pendant_apprentice", "ring_apprentice"]
static var _items: Dictionary = {}

static func catalog() -> Dictionary:
	if _items.is_empty():
		var parsed: Variant = JSON.parse_string(FileAccess.get_file_as_string("res://addons/hpmmo_sim/data/items.json"))
		if parsed is Dictionary:
			_items = parsed
	return _items

static func item(id: String) -> Dictionary:
	return catalog().get(id, {})

static func fits(id: String, slot: String) -> bool:
	return slot in SLOTS and slot in item(id).get("slots", [])

static func add(bag: Array, id: String, tier: int, amount: int) -> void:
	for entry in bag:
		if entry.id == id and int(entry.get("tier", 0)) == tier:
			entry.amount += amount
			return
	bag.append({"id": id, "tier": tier, "amount": amount})

static func take(bag: Array, id: String, tier: int, amount: int = 1) -> bool:
	for entry in bag:
		if entry.id == id and int(entry.get("tier", 0)) == tier and int(entry.amount) >= amount:
			entry.amount -= amount
			if entry.amount == 0:
				bag.erase(entry)
			return true
	return false

static func capacity_ok(bag: Array) -> bool:
	var kinds := {}
	for entry in bag:
		kinds[entry.id] = true
		if int(entry.amount) > 9999 or int(entry.amount) <= 0:
			return false
	return kinds.size() <= 40

static func swap(bag: Array, equipment: Dictionary, slot: String, id: String = "", tier: int = 0) -> Dictionary:
	if slot not in SLOTS or (id != "" and not fits(id, slot)):
		return {"ok": false, "reason": "wrong_slot"}
	var next_bag := bag.duplicate(true)
	var next_gear := equipment.duplicate(true)
	if id != "" and not take(next_bag, id, tier):
		return {"ok": false, "reason": "item_missing"}
	var old: Dictionary = next_gear.get(slot, {})
	if not old.is_empty():
		add(next_bag, old.id, int(old.get("tier", 0)), 1)
	next_gear.erase(slot)
	if id != "":
		next_gear[slot] = {"id": id, "tier": tier}
	if not capacity_ok(next_bag):
		return {"ok": false, "reason": "bag_full"}
	return {"ok": true, "reason": "", "inventory": next_bag, "equipment": next_gear}

static func stats(base_hp: int, base_mana: int, equipment: Dictionary) -> Dictionary:
	var result := {"max_hp": base_hp, "max_mana": base_mana, "defense": 0.0, "weapon_multiplier": 1.0, "wand_tier": 0, "mount_speed": 0.0}
	for slot in equipment:
		var entry: Dictionary = equipment[slot]
		if not fits(String(entry.get("id", "")), slot):
			continue
		var data := item(entry.id)
		result.max_hp += int(data.get("bonus_hp", 0))
		result.max_mana += int(data.get("bonus_mana", 0))
		result.defense += float(data.get("bonus_defense", 0))
		if slot == "main_hand":
			result.weapon_multiplier = float(data.get("base_multiplier", 1.0))
			result.wand_tier = int(entry.get("tier", 0))
		if slot == "broom":
			result.mount_speed = float(data.get("mount_speed", 16.0))
	result.defense = clampf(result.defense, 0.0, 50.0)
	return result

static func migrate(bag: Array, legacy_tier: int) -> Dictionary:
	var next := bag.duplicate(true)
	var gear := {}
	for slot in ["main_hand", "chest", "broom"]:
		var preferred: String = {"main_hand": "wand_hawthorn", "chest": "robe_apprentice", "broom": "broom_nimbus2000"}[slot]
		var candidates := next.filter(func(e): return fits(String(e.get("id", "")), slot) and int(e.get("amount", 0)) > 0)
		candidates.sort_custom(func(a, b):
			if (a.id == preferred) != (b.id == preferred): return a.id == preferred
			if a.id != b.id: return a.id < b.id
			return int(a.get("tier", 0)) < int(b.get("tier", 0)))
		if candidates.is_empty():
			continue
		var chosen: Dictionary = candidates[0]
		var id: String = chosen.id
		var tier := int(chosen.get("tier", 0))
		take(next, id, tier)
		gear[slot] = {"id": id, "tier": maxi(tier, legacy_tier) if slot == "main_hand" else tier}
	return {"inventory": next, "equipment": gear}
