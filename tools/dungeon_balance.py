"""Dungeon balance table: what a run asks of a party at each difficulty.

Reads the same data the authority uses (dungeons.json v2, spawn_tables.json
pack_tuning + boss_overrides, mobs.json) and mirrors HPRules' dungeon maths:
creature level = reference + difficulty offset + role + entry `lvl`; HP =
catalog base x pack_strength(level) x pack_tuning.hp_multiplier (bosses: their
override numbers scaled from stat_level), then x difficulty hp x party HP.

The workload is shown as "kills": the run's total hit points divided by one
ordinary open-world creature of the run level, per party member. With an
open-world kill rate (--kills-per-min, default 4) that gives an estimated clear
time to hold against the gold par.

    python server/tools/dungeon_balance.py [--dungeon forbidden_corridor] [--kills-per-min 4]
"""
import argparse
import json
import os

HERE = os.path.dirname(os.path.abspath(__file__))
DATA = os.path.join(HERE, '..', 'world', 'addons', 'hpmmo_sim', 'data')
SIZES = (1, 3, 5)


def load(name):
    return json.load(open(os.path.join(DATA, name), encoding='utf-8'))


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--dungeon', default='')
    parser.add_argument('--kills-per-min', type=float, default=4.0)
    args = parser.parse_args()

    dungeons = load('dungeons.json')
    spawns = load('spawn_tables.json')
    mobs = load('mobs.json')['mobs']
    tuning = spawns['pack_tuning']
    overrides = spawns['boss_overrides']
    group, roles, medals = dungeons['group'], dungeons['roles'], dungeons['medals']
    difficulties = [k for k in dungeons['difficulty'] if not k.startswith('_')]

    def strength(level):
        return max(tuning['hp_strength_floor'], tuning['hp_strength_base'] + level * tuning['hp_strength_per_level'])

    def mob_hp(species, level):
        return mobs[species]['base']['max_hp'] * strength(level) * tuning['hp_multiplier']

    # One ordinary open-world creature: the mean base HP of the region packs.
    bases = [mobs[p['mob']]['base']['max_hp'] for p in spawns['packs']
             if not p.get('boss') and p.get('mob') in mobs]
    ordinary_base = sum(bases) / len(bases)

    def entry_hp(entry, level):
        species = entry['mob']
        if 'boss_key' not in entry:
            return mob_hp(species, level)
        data = overrides.get(entry['boss_key'], {})
        ratio = strength(level) / strength(data.get('stat_level', level))
        body = data['hp'] * tuning['hp_multiplier'] * ratio if 'hp' in data else mob_hp(species, level)
        parts = mobs[species].get('parts')
        if parts and 'part_hp' in data:
            part_total = data['part_hp'] * ratio * len(parts['bones'])
            # Fluffy's body is the sum of its heads; the Snare has its own pool behind its vines.
            return part_total if species == 'fluffy' else body + part_total
        return body

    print('kill rate %.1f / min, ordinary creature base HP %.0f' % (args.kills_per_min, ordinary_base))
    for did, dungeon in dungeons['dungeons'].items():
        if args.dungeon and did != args.dungeon:
            continue
        lo, hi = dungeon['level_min'], dungeon['level_max']
        refs = sorted({lo, min(hi, lo + 10), min(hi, lo + 25)})
        ranks = {d: i for i, d in enumerate(difficulties)}

        def entries_on(diff_id):
            # Steps and entries with `min_difficulty` take part only from that difficulty up.
            def ok(item):
                return ranks.get(item.get('min_difficulty', difficulties[0]), 0) <= ranks[diff_id]
            return [e for s in dungeon['steps'] if ok(s) for e in s.get('spawn', []) if ok(e)]
        print('\n%s  (levels %d-%d, par %d s, %d spawns on Normal, %d on Legendary)' % (
            did, lo, hi, dungeon['par_s'], len(entries_on('normal')), len(entries_on(difficulties[-1]))))
        print('  %-10s %3s %4s %9s %10s %8s %8s %7s' % ('difficulty', 'n', 'ref', 'mob lv', 'total HP',
                                                       'kills/pl', 'est min', 'gold'))
        for diff_id in difficulties:
            diff = dungeons['difficulty'][diff_id]
            for ref in refs:
                for n in SIZES:
                    if n < diff['min_party']:
                        continue
                    total = 0.0
                    levels = []
                    for entry in entries_on(diff_id):
                        role = roles.get(entry.get('role', 'trash'), roles['trash'])
                        level = ref + diff['level_offset'] + role['lvl'] + entry.get('lvl', 0)
                        levels.append(level)
                        party = 1 + group['party_hp_' + role['party_hp']] * (n - 1)
                        total += entry_hp(entry, level) * diff['hp'] * party
                    run_level = ref + diff['level_offset']
                    ordinary = ordinary_base * strength(run_level) * tuning['hp_multiplier']
                    kills = total / ordinary / n
                    par = dungeon['par_s'] * diff['par_mult'] * medals['gold'] / 60.0
                    print('  %-10s %3d %4d %4d-%-4d %10.0f %8.1f %8.1f %7.1f' % (
                        diff_id, n, ref, min(levels), max(levels), total, kills, kills / args.kills_per_min, par))


if __name__ == '__main__':
    main()
