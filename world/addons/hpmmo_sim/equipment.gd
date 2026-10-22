extends RefCounted
class_name HPEquipment

## Server-owned item rules. Pure transformations also power client comparisons.
const SLOTS := ["head", "chest", "hands", "feet", "main_hand", "off_hand", "neck", "ring_left", "ring_right", "broom"]
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

## Gear (anything with an equipment slot) is never destroyed from the bag:
## the Delete key only throws away stacks and materials; gear is sold instead.
static func equippable(id: String) -> bool:
	return not (item(id).get("slots", []) as Array).is_empty()

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

## What a merchant pays for one piece: by rarity, +50% per refinement tier.
## Stackables (potions, materials) fetch a tenth - they drop by the dozen.
## items.json `sell_price` overrides the rarity rule.
const SELL_BY_RARITY := {"common": 40, "uncommon": 120, "rare": 300, "epic": 800, "legendary": 2000}

static func sell_price(id: String, tier: int = 0) -> int:
	var data := item(id)
	if data.is_empty():
		return 0
	var base := int(data.get("sell_price", SELL_BY_RARITY.get(String(data.get("rarity", "common")), 40)))
	if not data.has("sell_price") and stackable(id):
		base = maxi(1, base / 10)
	return int(round(float(base) * (1.0 + 0.5 * float(maxi(0, tier)))))

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
## combat.json upgrade_curves.refinable_types (every wearable kind).
static func refinable(id: String) -> bool:
	var curves: Dictionary = HPRules.combat().get("upgrade_curves", {})
	return String(item(id).get("type", "")) in curves.get("refinable_types", [])

## An upgrade curve value at `tier`: upgrade_curves[kind][key], or the flat
## list upgrade_curves[kind] when `key` is empty.
static func _curve(kind: String, key: String, tier: int) -> float:
	var entry: Variant = HPRules.combat().get("upgrade_curves", {}).get(kind, [])
	var values: Array = entry if entry is Array else (entry as Dictionary).get(key, [])
	return float(values[clampi(tier, 0, values.size() - 1)]) if not values.is_empty() else 0.0

## One item's effective fixed stats at refine level `tier` - the single place the
## upgrade curves apply, shared by derived stats, the tooltip and the upgrade
## window so they can never disagree. Wand ranges come back scaled for display
## (`attack_value` / `magic_attack`); damage scales the whole spell instead.
static func item_stats(id: String, tier: int) -> Dictionary:
	var data := item(id)
	var stat_mult := _curve("stat_mult", "", tier) if String(data.get("type", "")) != "mount" else 1.0
	var out := {"bonus_hp": int(round(int(data.get("bonus_hp", 0)) * stat_mult)),
		"bonus_mana": int(round(int(data.get("bonus_mana", 0)) * stat_mult)),
		"armor": int(round(float(data.get("armor", 0)) * _curve("armor_mult", "", tier))),
		"attack_value": _range(data.get("attack_value", []), HPRules.wand_multiplier(tier)),
		"magic_attack": _range(data.get("magic_attack", []), HPRules.wand_multiplier(tier)),
		"mount_speed": 0.0}
	for key in FIXED_PERCENT:
		out[key] = float(data.get(key, 0.0))
	if String(data.get("type", "")) == "mount":
		out.mount_speed = float(data.get("mount_speed", 16.0)) * _curve("mount", "speed_mult", tier)
	return out

## Fixed stats that are percentages or per-second rates: they never grow with +N.
const FIXED_PERCENT := ["attack_speed", "move_speed", "spell_power", "hp_regen", "mana_regen"]

static func _range(raw: Variant, mult: float) -> Array:
	if not (raw is Array) or (raw as Array).size() < 2:
		return []
	return [int(round(float(raw[0]) * mult)), int(round(float(raw[1]) * mult))]

## Tooltip / workshop lines for an item's fixed stats at refine level `tier`:
## [{text, negative}], in display order. One wording for every UI.
static func fixed_lines(id: String, tier: int) -> Array:
	var data := item(id)
	var n := item_stats(id, tier)
	var lines: Array = []
	if not (n.attack_value as Array).is_empty():
		lines.append({"text": _t("Attack Value %d - %d") % [n.attack_value[0], n.attack_value[1]], "negative": false})
	if not (n.magic_attack as Array).is_empty():
		lines.append({"text": _t("Magic Attack Value %d - %d") % [n.magic_attack[0], n.magic_attack[1]], "negative": false})
	if int(n.armor) > 0:
		lines.append({"text": _t("Armour %d") % int(n.armor), "negative": false})
	if int(n.bonus_hp) > 0:
		lines.append({"text": _t("Max Health +%d") % int(n.bonus_hp), "negative": false})
	if int(n.bonus_mana) > 0:
		lines.append({"text": _t("Max Mana +%d") % int(n.bonus_mana), "negative": false})
	# i18n-begin
	var labels := {"attack_speed": "Attack Speed %+d%%", "move_speed": "Movement Speed %+d%%", "spell_power": "Spell Power %+d%%",
		"hp_regen": "Health Regeneration %+d/s", "mana_regen": "Mana Regeneration %+d/s"}
	# i18n-end
	for key in FIXED_PERCENT:
		if not is_zero_approx(float(n[key])):
			lines.append({"text": _t(labels[key]) % int(n[key]), "negative": float(n[key]) < 0.0})
	if data.has("mount_speed"):
		lines.append({"text": _t("Mount Speed %.1f") % float(n.mount_speed), "negative": false})
	return lines

## The stat names an item already carries as fixed stats (never rolled as efsun).
static func fixed_stat_keys(id: String) -> Array:
	var data := item(id)
	var keys: Array = []
	for key in FIXED_PERCENT:
		if not is_zero_approx(float(data.get(key, 0.0))):
			keys.append(key)
	if int(data.get("bonus_hp", 0)) > 0: keys.append("max_hp")
	if int(data.get("bonus_mana", 0)) > 0: keys.append("max_mana")
	return keys

# ------------------------------------------------------------------ enchantments

static func enchant_rules() -> Dictionary:
	return HPRules.combat().get("enchant", {})

## What kind of piece an item is for enchanting ("wand", "cloak", "hat", ...):
## enchant.slot_kinds by the first slot it fits.
static func slot_kind(id: String) -> String:
	var slots: Array = item(id).get("slots", [])
	return String((enchant_rules().get("slot_kinds", {}) as Dictionary).get(String(slots[0]), "")) if not slots.is_empty() else ""

## The bonus pool for an item (empty when it cannot be enchanted).
static func enchant_pool(id: String) -> Array:
	return (enchant_rules().get("pools", {}) as Dictionary).get(slot_kind(id), [])

static func enchantable(id: String) -> bool:
	return not enchant_pool(id).is_empty()

## "Spell power +6%" - the one wording for a bonus line, shared by every UI.
static func bonus_text(bonus: Dictionary) -> String:
	var spec: Dictionary = (enchant_rules().get("stats", {}) as Dictionary).get(String(bonus.get("stat", "")), {})
	if bool(spec.get("flag", false)):
		return _t(String(spec.get("label", bonus.get("stat", "?"))))
	return "%s +%d%s" % [_t(String(spec.get("label", bonus.get("stat", "?")))), int(bonus.get("value", 0)), String(spec.get("unit", ""))]

## Player-facing text in the viewer's language (the client's catalogue). The
## world server runs in English, so its own copies of these lines stay English.
static func _t(text: String) -> String:
	return String(TranslationServer.translate(text)) if text != "" else text

## One new bonus for `id`: a stat from its pool the item does not hold yet (nor
## as a fixed stat), skipping stats whose mechanic is not live (`disabled`) or
## whose theme the piece may not carry (enchant.slot_themes), and a weighted
## grade. {} when the pool is exhausted.
static func roll_bonus(id: String, held: Array, rng: RandomNumberGenerator) -> Dictionary:
	var taken := held.map(func(b): return String(b.get("stat", "")))
	taken.append_array(fixed_stat_keys(id))
	var specs: Dictionary = enchant_rules().get("stats", {})
	var themes: Array = (enchant_rules().get("slot_themes", {}) as Dictionary).get(slot_kind(id), [])
	var free := enchant_pool(id).filter(func(stat): return not stat in taken \
		and not bool((specs.get(stat, {}) as Dictionary).get("disabled", false)) \
		and String((specs.get(stat, {}) as Dictionary).get("theme", "")) in themes)
	if free.is_empty():
		return {}
	var stat: String = free[rng.randi_range(0, free.size() - 1)]
	var weights: Array = enchant_rules().get("grade_weights", [1])
	var total := 0
	for w in weights: total += int(w)
	var pick := rng.randi_range(1, maxi(1, total))
	var grade := 0
	for i in weights.size():
		pick -= int(weights[i])
		if pick <= 0:
			grade = i
			break
	var values: Array = ((enchant_rules().get("stats", {}) as Dictionary).get(stat, {}) as Dictionary).get("values", [0])
	return {"stat": stat, "value": int(values[clampi(grade, 0, values.size() - 1)]), "grade": grade}

## Use `scroll` on the instance `uid` (in the bag or worn). Imbue adds one bonus
## with the authored chance for the current count; reweave rerolls every bonus
## keeping the count. The scroll is spent whenever the attempt is made.
static func enchant(bag: Array, gear: Dictionary, scroll: String, uid: int, rng: RandomNumberGenerator) -> Dictionary:
	var rules := enchant_rules()
	var imbue := scroll == String(rules.get("imbue_scroll", ""))
	if not imbue and scroll != String(rules.get("reweave_scroll", "")):
		return {"ok": false, "reason": "invalid_operation"}
	var next_bag := bag.duplicate(true)
	var next_gear := gear.duplicate(true)
	var target: Dictionary = {}
	for entry in next_bag:
		if uid > 0 and int(entry.get("uid", 0)) == uid:
			target = entry
	for slot in next_gear:
		if uid > 0 and int(next_gear[slot].get("uid", 0)) == uid:
			target = next_gear[slot]
	if target.is_empty():
		return {"ok": false, "reason": "item_missing"}
	if not enchantable(String(target.id)):
		return {"ok": false, "reason": "not_enchantable"}
	var held: Array = (target.get("bonuses", []) as Array).duplicate(true)
	if imbue and held.size() >= int(rules.get("max_bonuses", 5)):
		return {"ok": false, "reason": "bonus_full"}
	if not imbue and held.is_empty():
		return {"ok": false, "reason": "no_bonus"}
	if not take(next_bag, scroll, 0, 1):
		return {"ok": false, "reason": "no_scroll"}
	var reason := "enchanted"
	if imbue:
		var chances: Array = rules.get("imbue_chance", [100])
		var chance := float(chances[clampi(held.size(), 0, chances.size() - 1)])
		if rng.randf() * 100.0 < chance:
			var bonus := roll_bonus(String(target.id), held, rng)
			if bonus.is_empty():
				return {"ok": false, "reason": "bonus_full"}
			held.append(bonus)
		else:
			reason = "enchant_failed"
	else:
		var count := held.size()
		held.clear()
		for _i in count:
			var bonus := roll_bonus(String(target.id), held, rng)
			if not bonus.is_empty():
				held.append(bonus)
	target["bonuses"] = held
	return {"ok": true, "reason": reason, "inventory": next_bag, "equipment": next_gear}

## Every worn bonus summed per stat.
static func bonus_totals(equipment: Dictionary) -> Dictionary:
	var totals := {}
	for slot in equipment:
		var entry: Dictionary = equipment[slot]
		if not fits(String(entry.get("id", "")), slot):
			continue
		for bonus in entry.get("bonuses", []):
			var stat := String(bonus.get("stat", ""))
			totals[stat] = float(totals.get(stat, 0.0)) + float(bonus.get("value", 0))
	return totals

## Everything worn, summed: fixed item stats plus enchantments. Keys are the
## stat names of combat.json enchant.stats (each 0 unless worn) plus max_hp,
## max_mana, armor, defense (legacy %), weapon_multiplier (1 + spell power),
## wand_tier, attack_value / magic_attack (the wand's +0 ranges; damage applies
## the +N multiplier), attack_speed, cast_speed, move_speed, mount_speed.
static func stats(base_hp: int, base_mana: int, equipment: Dictionary, attributes: Dictionary = {}) -> Dictionary:
	var result := {}
	for key in (enchant_rules().get("stats", {}) as Dictionary):
		result[key] = 0.0
	result.merge({"max_hp": base_hp, "max_mana": base_mana, "armor": 0, "defense": 0.0, "weapon_multiplier": 1.0,
		"wand_tier": 0, "attack_value": [0, 0], "magic_attack": [0, 0], "mount_speed": 0.0}, true)
	for slot in equipment:
		var entry: Dictionary = equipment[slot]
		if not fits(String(entry.get("id", "")), slot):
			continue
		var tier := int(entry.get("tier", 0))
		var data := item(String(entry.id))
		var numbers := item_stats(String(entry.id), tier)
		result.max_hp += int(numbers.bonus_hp)
		result.max_mana += int(numbers.bonus_mana)
		result.armor += int(numbers.armor)
		for key in FIXED_PERCENT:
			result[key] = float(result.get(key, 0.0)) + float(numbers[key])
		if slot == "main_hand":
			result.wand_tier = tier
			if data.has("attack_value"): result.attack_value = _range(data.attack_value, 1.0)
			if data.has("magic_attack"): result.magic_attack = _range(data.magic_attack, 1.0)
		if slot == "broom":
			result.mount_speed = float(numbers.mount_speed)
	var bonus := bonus_totals(equipment)
	for stat in bonus:
		match String(stat):
			"max_hp": result.max_hp += int(bonus[stat])
			"max_mana": result.max_mana += int(bonus[stat])
			"mount_speed": result.mount_speed *= 1.0 + float(bonus[stat]) / 100.0   # legacy broom efsun
			_: result[stat] = float(result.get(stat, 0.0)) + float(bonus[stat])
	# Status points (combat.json attributes): flat health/mana, both ends of the
	# wand ranges, percent speed / crit / spell power.
	var attribute_specs: Dictionary = HPRules.attribute_rules().get("stats", {})
	for id in attributes:
		var spec: Dictionary = attribute_specs.get(id, {})
		var points := int(attributes[id])
		for key in spec:
			if key in ["label", "desc"]:
				continue
			var add := float(spec[key]) * points
			match String(key):
				"max_hp": result.max_hp += int(round(add))
				"max_mana": result.max_mana += int(round(add))
				"attack_value", "magic_attack":
					var span: Array = result[key]
					result[key] = [int(span[0]) + int(round(add)), int(span[1]) + int(round(add))]
				_: result[key] = float(result.get(key, 0.0)) + add
	result.weapon_multiplier = 1.0 + float(result.spell_power) / 100.0
	var rules := HPRules.item_rules()
	result.move_speed = clampf(float(result.move_speed), float(rules.get("move_speed_min", -20)), float(rules.get("move_speed_max", 40)))
	result.attack_speed = clampf(float(result.attack_speed), 0.0, float(rules.get("attack_speed_cap", 100)))
	result.cast_speed = clampf(float(result.cast_speed), 0.0, float(rules.get("cast_speed_cap", 40)))
	result.defense = clampf(float(result.defense), 0.0, 50.0)
	return result

static func migrate(bag: Array, legacy_tier: int) -> Dictionary:
	var next := bag.duplicate(true)
	var gear := {}
	for slot in ["main_hand", "chest", "broom"]:
		var preferred: String = {"main_hand": "wand_ashwood", "chest": "robe_apprentice", "broom": "broom_nimbus2000"}[slot]
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
