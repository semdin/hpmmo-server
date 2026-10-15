extends RefCounted
class_name HPEquipment

## Server-owned item rules. Pure transformations also power client comparisons.
const SLOTS := ["head", "chest", "hands", "feet", "main_hand", "off_hand", "neck", "ring_left", "ring_right", "broom"]
const BASIC_ACCESSORIES := ["hat_apprentice", "gloves_apprentice", "boots_apprentice", "focus_apprentice", "pendant_apprentice", "ring_apprentice"]
## The broom every mount item without its own `model` flies on (the starter
## Nimbus and the Firebolt predate per-item broom models).
const DEFAULT_BROOM_MODEL := "res://assets/models/props/broom_flight.glb"
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

## The character level an item needs before it can be equipped (`required_level`
## in items.json; absent means anyone may wear it).
static func required_level(id: String) -> int:
	return maxi(1, int(item(id).get("required_level", 1)))

static func level_ok(id: String, level: int) -> bool:
	return level >= required_level(id)

## The broom scene a mount item is drawn with.
static func broom_model(id: String) -> String:
	var path := String(item(id).get("model", ""))
	return path if path != "" else DEFAULT_BROOM_MODEL

## Bag size in slots: a stack and an item instance take one slot each.
const BAG_SLOTS := 40
const MAX_STACK := 9999
static var _uid_rng: RandomNumberGenerator = null

## Potions and materials stack: one entry per (id, tier) carrying an amount.
## Everything else is an instance of its own - amount 1, a `uid` that names it
## for its whole life (equip, refine, enchantments) and its own `bonuses` - so
## two wands of the same kind can differ. items.json `stackable` overrides the
## type rule; an id the catalog no longer knows is kept exactly as stored.
static func stackable(id: String) -> bool:
	var data := item(id)
	if data.is_empty():
		return true
	if data.has("stackable"):
		return bool(data.stackable)
	return String(data.get("type", "")) in ["consumable", "material"]

## A fresh instance id: random, positive and below 2^53 so it survives JSON
## (numbers parse as doubles) and the database's bigint unchanged.
static func new_uid() -> int:
	if _uid_rng == null:
		_uid_rng = RandomNumberGenerator.new()
		_uid_rng.randomize()
	return ((_uid_rng.randi() & 0x1FFFFF) << 32 | _uid_rng.randi()) + 1

static func instance(id: String, tier: int, bonuses: Array = [], uid: int = 0) -> Dictionary:
	return {"id": id, "tier": tier, "amount": 1, "uid": uid if uid > 0 else new_uid(), "bonuses": bonuses.duplicate(true)}

## What a slot holds: the instance minus its bag-only amount.
static func worn(entry: Dictionary) -> Dictionary:
	return {"id": String(entry.id), "tier": int(entry.get("tier", 0)), "uid": int(entry.get("uid", 0)),
		"bonuses": (entry.get("bonuses", []) as Array).duplicate(true)}

static func add(bag: Array, id: String, tier: int, amount: int, bonuses: Array = []) -> void:
	if stackable(id):
		for entry in bag:
			if entry.id == id and int(entry.get("tier", 0)) == tier and int(entry.get("uid", 0)) == 0:
				entry.amount += amount
				return
		bag.append({"id": id, "tier": tier, "amount": amount})
		return
	for _i in amount:
		bag.append(instance(id, tier, bonuses))

## Remove `amount` of (id, tier) from wherever it is held - one stack or several
## instances. All or nothing.
static func take(bag: Array, id: String, tier: int, amount: int = 1) -> bool:
	var held := 0
	for entry in bag:
		if entry.id == id and int(entry.get("tier", 0)) == tier:
			held += int(entry.amount)
	if held < amount:
		return false
	var left := amount
	for entry in bag.duplicate():
		if left == 0:
			break
		if entry.id == id and int(entry.get("tier", 0)) == tier:
			var used := mini(left, int(entry.amount))
			entry.amount -= used
			left -= used
			if entry.amount == 0:
				bag.erase(entry)
	return true

## Remove and return the instance `uid` ({} when the bag does not hold it).
static func take_instance(bag: Array, uid: int) -> Dictionary:
	for entry in bag:
		if uid > 0 and int(entry.get("uid", 0)) == uid:
			bag.erase(entry)
			return entry
	return {}

static func capacity_ok(bag: Array) -> bool:
	for entry in bag:
		if int(entry.amount) > MAX_STACK or int(entry.amount) <= 0:
			return false
	return bag.size() <= BAG_SLOTS

## Equip the instance `uid` (or, without one, the first matching entry) into
## `slot`; whatever the slot held goes back to the bag with its uid and bonuses.
static func swap(bag: Array, equipment: Dictionary, slot: String, id: String = "", tier: int = 0, uid: int = 0) -> Dictionary:
	if slot not in SLOTS or (id != "" and not fits(id, slot)):
		return {"ok": false, "reason": "wrong_slot"}
	var next_bag := bag.duplicate(true)
	var next_gear := equipment.duplicate(true)
	var picked := {}
	if id != "":
		if uid > 0:
			picked = take_instance(next_bag, uid)
			if picked.is_empty() or String(picked.id) != id:
				return {"ok": false, "reason": "item_missing"}
		else:
			for entry in next_bag:
				if entry.id == id and int(entry.get("tier", 0)) == tier:
					picked = entry.duplicate(true)
					break
			if picked.is_empty() or not take(next_bag, id, tier):
				return {"ok": false, "reason": "item_missing"}
			if int(picked.get("uid", 0)) <= 0:
				picked = instance(id, tier)
	var old: Dictionary = next_gear.get(slot, {})
	if not old.is_empty():
		next_bag.append(instance(String(old.id), int(old.get("tier", 0)), old.get("bonuses", []), int(old.get("uid", 0))))
	next_gear.erase(slot)
	if id != "":
		next_gear[slot] = worn(picked)
	if not capacity_ok(next_bag):
		return {"ok": false, "reason": "bag_full"}
	return {"ok": true, "reason": "", "inventory": next_bag, "equipment": next_gear}

## Bring stored ownership up to the instance model: a non-stackable entry with
## amount N (saved before instances existed) becomes N instances, and every
## instance - in the bag or worn - gets a uid and a bonuses list. Idempotent; a
## normalized bag and its gear come back unchanged. Returns true on any change.
static func normalize(bag: Array, gear: Dictionary) -> bool:
	var changed := false
	var seen := {}
	var out: Array = []
	for entry in bag:
		var id := String(entry.id)
		var tier := int(entry.get("tier", 0))
		if stackable(id) and int(entry.get("uid", 0)) == 0:
			out.append(entry)
			continue
		var count := maxi(1, int(entry.get("amount", 1)))
		changed = changed or count > 1 or not entry.has("bonuses")
		for i in count:
			var uid := int(entry.get("uid", 0)) if i == 0 else 0
			if uid <= 0 or seen.has(uid):
				uid = new_uid()
				changed = true
			seen[uid] = true
			out.append(instance(id, tier, entry.get("bonuses", []), uid))
	for slot in gear:
		var worn_entry: Dictionary = gear[slot]
		var uid := int(worn_entry.get("uid", 0))
		if uid <= 0 or seen.has(uid):
			uid = new_uid()
			changed = true
		seen[uid] = true
		if not worn_entry.has("bonuses"):
			changed = true
		gear[slot] = worn({"id": worn_entry.id, "tier": worn_entry.get("tier", 0), "uid": uid, "bonuses": worn_entry.get("bonuses", [])})
	bag.assign(out)
	return changed

## Whether an item can be refined (+0..+9): its type is listed in
## combat.json upgrade_curves.refinable_types (wands, robes, brooms).
static func refinable(id: String) -> bool:
	var curves: Dictionary = HPRules.combat().get("upgrade_curves", {})
	return String(item(id).get("type", "")) in curves.get("refinable_types", [])

static func _curve(kind: String, key: String, tier: int) -> float:
	var values: Array = (HPRules.combat().get("upgrade_curves", {}).get(kind, {}) as Dictionary).get(key, [])
	return float(values[clampi(tier, 0, values.size() - 1)]) if not values.is_empty() else 0.0

## One item's effective numbers at refine level `tier` - the single place the
## upgrade curves apply, shared by derived stats, the tooltip and the upgrade
## window so they can never disagree.
static func item_stats(id: String, tier: int) -> Dictionary:
	var data := item(id)
	var out := {"bonus_hp": int(data.get("bonus_hp", 0)), "bonus_mana": int(data.get("bonus_mana", 0)),
		"bonus_defense": float(data.get("bonus_defense", 0)), "spell_power": 1.0, "mount_speed": 0.0}
	match String(data.get("type", "")):
		"weapon":
			out.spell_power = float(data.get("base_multiplier", 1.0)) * HPRules.wand_multiplier(tier)
		"armor":
			out.bonus_hp = int(round(out.bonus_hp * _curve("armor", "hp_mult", tier)))
			out.bonus_defense += _curve("armor", "defense_add", tier)
		"mount":
			out.mount_speed = float(data.get("mount_speed", 16.0)) * _curve("mount", "speed_mult", tier)
	return out

static func stats(base_hp: int, base_mana: int, equipment: Dictionary) -> Dictionary:
	var result := {"max_hp": base_hp, "max_mana": base_mana, "defense": 0.0, "weapon_multiplier": 1.0, "wand_tier": 0, "mount_speed": 0.0}
	for slot in equipment:
		var entry: Dictionary = equipment[slot]
		if not fits(String(entry.get("id", "")), slot):
			continue
		var tier := int(entry.get("tier", 0))
		var numbers := item_stats(String(entry.id), tier)
		result.max_hp += int(numbers.bonus_hp)
		result.max_mana += int(numbers.bonus_mana)
		result.defense += float(numbers.bonus_defense)
		if slot == "main_hand":
			# Spell damage applies wand_multiplier(wand_tier) itself (HPRules.spell_
			# multiplier), so the weapon multiplier stays the item's base here.
			result.weapon_multiplier = float(item(entry.id).get("base_multiplier", 1.0))
			result.wand_tier = tier
		if slot == "broom":
			result.mount_speed = float(numbers.mount_speed)
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
