"""Quest standard: writes world/addons/hpmmo_sim/data/quests.json.

One linear main chain, two quests per character level from 1 to 50 (100 in all;
the tutorial puts three at level 1 and one at level 2).
Each quest names its level (it waits until the player reaches it), a size that
sets the reward from the level's experience threshold, a type the authority can
observe, and optional item rewards. Edit the CHAIN table below and re-run:

    python server/tools/gen_quests.py

Rewards (size -> share of exp_threshold(level), galleons, house reputation):
    s small   15%   level x 30 + 80     10 rep
    n normal  25%   level x 45 + 120    20 rep
    b big     35%   level x 70 + 200    35 rep
    B boss    45%   level x 110 + 400   60 rep   (bosses, dungeons, chapter ends)

The threshold is HPRules.exp_threshold: one ordinary creature's experience at
the level x the kills a level takes without quests (combat.json exp_curve).
"""
import json
import os
from collections import OrderedDict

HERE = os.path.dirname(os.path.abspath(__file__))
DATA = os.path.join(HERE, '..', 'world', 'addons', 'hpmmo_sim', 'data')

SIZES = {
    's': (0.15, 30, 80, 10),
    'n': (0.25, 45, 120, 20),
    'b': (0.35, 70, 200, 35),
    'B': (0.45, 110, 400, 60),
}

CHAPTERS = [
    (1, 'First Year', "Settle in at Kaf Castle, raised over the shard of the fallen World-Star Ithrel: your cloak, your first spells, your first broom."),
    (6, 'The Forest Edge', "Darkened shards fall into the Raven Woods and the creatures grow bolder; learn the forge and the trial."),
    (11, 'Roads to Orvell', 'Bandits prowl the roads; the village needs a wand it can trust.'),
    (16, 'Crypts and Trolls', "The dead stir in the crypts, the trolls come down from their hollow - and an old name turns up in the records: the Ash Priest."),
    (21, 'Barrows and Webs', "The dead rise in the barrows; deep in the caverns the Web Mother broods on a shard the Ash Priest gave her."),
    (27, 'The Moors', "Trolls and the Ash Priest's dark wizards hold the moors above Orvell."),
    (31, 'The Sealed Wing', "The castle's sealed wing hides a piece of an old gate to another realm - and something guards it."),
    (35, 'Stone and Storm', "Mountain trolls gather under Grak around a Dark Shard on the Stone Circle Summit."),
    (41, 'The Long Mist', "The mist of Morhal rolls in from the shore and the Pallids with it; only the Light of Ithrel will hold them back."),
]

# (level, size, type, target, count, title, objective, story, giver, extra)
# extra: reward items [(id, amount)], 'boss': True, 'mounted': True
CHAIN = [
    # ---------------------------------------------------------------- 1-5 First Year
    (1, 's', 'talk', 'Master Teral Venn', 1, 'First-Year Orientation', 'Speak with Master Teral Venn by the fountain',
     'Master Teral Venn waits beside the courtyard fountain (the bobbing gold arrow). Walk up and click him or press F to talk.', 'Master Teral Venn',
     {'items': [('cloak_wool', 1)]}),
    (1, 's', 'equip', 'chest', 1, 'Dressed for the Grounds', "Wear the Woolen Traveller's Cloak",
     'Open your bag with I and right-click the cloak Master Teral Venn gave you. It costs a little speed and buys a lot of armour.', 'Master Teral Venn',
     {'items': [('potion_health', 5)]}),
    (1, 's', 'dummy', '', 5, 'Wand Drills', 'Hit a training dummy 5 times',
     'Three training dummies stand by the east road, just outside the courtyard wall - they never hit back. Left-click to cast; spells hurt nothing inside the safe courtyard.', 'Master Teral Venn',
     {'items': [('hat_apprentice', 1)]}),
    (2, 'n', 'kill', 'acromantula', 6, 'Spiders at the Gate', 'Defeat 6 Black Weavers',
     'Leave the courtyard for the Village Outskirts or the Pitch Outskirts. Hit one spider and its pack answers - keep moving.', 'Master Teral Venn',
     {'items': [('gloves_apprentice', 1)]}),
    (3, 'n', 'kill', 'inferi', 6, 'Restless Dead', 'Defeat 6 Drowned Ones',
     'Drowned Ones stalk the Forest Edge past Borin\'s hut. Fire (Flame Wave) hurts them twice as much.', 'Borin',
     {'items': [('boots_apprentice', 1)]}),
    (3, 's', 'talk', 'Borin', 1, "Borin's Hut", 'Report to Borin at his hut',
     'Borin Ashgrove, the forest warden, keeps watch from his hut west of the castle.', 'Borin',
     {'items': [('focus_apprentice', 1)]}),
    (4, 'n', 'kill', 'acromantula', 10, 'Thinning the Brood', 'Defeat 10 Black Weavers',
     'The spiders breed faster than anyone can count. Greenhouse Meadow is crawling with them.', 'Borin',
     {'items': [('pendant_apprentice', 1)]}),
    (4, 's', 'enter_map', 'castle_interior', 1, 'Through the Great Doors', 'Enter Kaf Castle',
     'Walk up the castle approach and press F in the doorway to go inside.', 'Archivist Emrel Sav',
     {'items': [('ring_apprentice', 1)]}),
    (5, 'b', 'talk', 'Flight Master Kaelen Rook', 1, 'Your First Broom', 'Collect your broom from Flight Master Kaelen Rook',
     'At level 5 every student gets a broom. Flight Master Kaelen Rook waits at the castle approach.', 'Flight Master Kaelen Rook',
     {'items': [('broom_ashwood', 1)]}),
    (5, 'n', 'visit', 'Skyring Pitch', 1, 'Skyring Tryouts', 'Fly to the Skyring Pitch on your broom',
     'Equip the broom, press Shift to mount, Space to rise and Ctrl to descend. Land on level ground and press Shift to dismount.', 'Flight Master Kaelen Rook',
     {'mounted': True, 'items': [('potion_mana', 5)]}),
    # ---------------------------------------------------------------- 6-10 The Forest Edge
    (6, 'n', 'kill', 'inferi', 12, 'Ash and Bone', 'Defeat 12 Drowned Ones',
     'The Drowned Ones gather again at the Forest Edge and in Greenhouse Meadow.', 'Borin',
     {'items': [('mat_phoenix_ash', 3)]}),
    (6, 's', 'talk', 'Kestrin', 1, "Kestrin's Forge", 'Speak with Kestrin',
     'Kestrin works his anvil in the courtyard. He can make a wand stronger, at a price.', 'Kestrin', {}),
    (7, 'n', 'refine', '', 1, 'A Stronger Wand', 'Refine your wand once at Kestrin',
     'Press O to open Kestrin\'s workshop, drag your wand onto the anvil and refine it with Velkar Ash and Oril.', 'Kestrin',
     {'items': [('scroll_imbue', 2)]}),
    (7, 'n', 'kill', 'acromantula', 12, 'The Eastern Road', 'Defeat 12 Black Weavers',
     'Merchants on the Eastern Road are turning back. Clear the spiders from the verges.', 'Bessa Tull', {}),
    (8, 'n', 'enchant', '', 1, 'Woven Magic', 'Enchant an item at Kestrin',
     'Put any piece of gear on the anvil and use an Imbue Scroll. A failed weave still spends the scroll.', 'Kestrin',
     {'items': [('scroll_reweave', 1)]}),
    (8, 'n', 'kill', 'inferi', 14, 'The Long Road Home', 'Defeat 14 Drowned Ones',
     'Drowned Ones wander onto the Eastern Road at dusk. Keep the road open.', 'Bessa Tull', {}),
    (9, 'b', 'kill', 'acromantula', 16, 'Weaver Thicket', 'Defeat 16 Black Weavers',
     'West of the forest edge the spiders grow to the size of carts. Bring potions.', 'Borin',
     {'items': [('mat_phoenix_ash', 3)]}),
    (9, 'b', 'monolith', '', 1, 'Shatter the Darkness', 'Help destroy a Dark Shard',
     "The Ash Priest drags darkened star shards out of the Void and they fall in the western forests: at the Forest Edge past Borin's hut, in the Weaver Thicket beyond it, in Bandit Woods to the north-west and in Crypt Hollow far to the west. Close by, a green light rises over the trees. Break one with others before its waves overrun you.", 'Master Teral Venn', {}),
    (10, 'B', 'dungeon', 'trial', 1, 'The Trial Hall', 'Complete the Trial Hall',
     'The Trial Hall portal is the glowing arch on the courtyard lawn, beside the lake walk. Step into it and press F, clear the corridor, then defeat the Trial Warden. Up to five can go in together.', 'Master Teral Venn',
     {'items': [('wand_runebound', 1)]}),
    (10, 's', 'equip', 'main_hand', 1, 'A Wand Worth Keeping', 'Equip the Runebound Walnut Wand',
     'Your new wand rolls a far higher Attack and Magic Attack Value. Equip it from your bag.', 'Kestrin',
     {'items': [('potion_health', 10)]}),
    # ---------------------------------------------------------------- 11-15 Roads to Hogsmeade
    (11, 'n', 'kill', 'darksnatcher', 10, 'Bandits on the Road', 'Defeat 10 Bandits',
     'Bandits waylay travellers on the Orvell Road. They cast back - keep your distance.', 'Bessa Tull', {}),
    (11, 's', 'talk', 'Bessa Tull', 1, 'The Red Lantern', 'Speak with Bessa Tull in Orvell',
     'Fly east along the Orvell Road. Bessa Tull knows every rumour in the valley.', 'Bessa Tull', {}),
    (12, 'n', 'kill', 'acromantula', 15, 'Pitch Woods', 'Defeat 15 Black Weavers',
     'The woods behind the Skyring Pitch are thick with webs.', 'Flight Master Kaelen Rook',
     {'items': [('cloak_runed', 1)]}),
    (12, 'n', 'kill', 'inferi', 15, 'Lakeside Glade', 'Defeat 15 Drowned Ones',
     'Drowned Ones crawl out of Lake Lunra at the Lakeside Glade.', 'Borin', {}),
    (13, 'n', 'kill', 'darksnatcher', 14, 'Bandit Woods', 'Defeat 14 Bandits',
     'The bandits have a camp in the woods north-west of the castle. Drive them out.', 'Bessa Tull',
     {'items': [('mat_dragon_heartstring', 2)]}),
    (13, 's', 'visit', 'Lakeside Glade', 1, 'Survey the Lake', 'Visit the Lakeside Glade',
     'Borin wants to know how far the Drowned Ones have spread along the shore.', 'Borin', {}),
    (14, 'n', 'kill', 'acromantula', 18, 'Webs in the Glade', 'Defeat 18 Black Weavers',
     'Spiders and dead share the Lakeside Glade now. Clear the spiders first.', 'Borin', {}),
    (14, 'n', 'refine', '', 2, 'Steel for the Road', 'Refine any item twice',
     'Kestrin can refine cloaks, accessories and brooms as well as wands.', 'Kestrin',
     {'items': [('scroll_imbue', 2)]}),
    (15, 'b', 'kill', 'darksnatcher', 18, 'Breaking the Ring', 'Defeat 18 Bandits',
     'Bessa has heard the bandits answer to a captain. Weaken them before he moves.', 'Bessa Tull',
     {'items': [('broom_runebound', 1)]}),
    (15, 'n', 'kill', 'inferi', 18, 'Crypt Hollow', 'Defeat 18 Drowned Ones',
     'Deeper in the forest an old crypt has opened. The Drowned Ones pour out of Crypt Hollow.', 'Archivist Emrel Sav', {}),
    # ---------------------------------------------------------------- 16-20 Crypts and Trolls
    (16, 'n', 'talk', 'Archivist Emrel Sav', 1, 'Records of the Crypt', 'Speak with Archivist Emrel Sav',
     "Archivist Emrel Sav keeps the records of every grave in the valley - and one old entry names the Ash Priest, who once tried to open the gate of Morhal. She waits at the castle approach.", 'Archivist Emrel Sav', {}),
    (16, 'n', 'kill', 'troll_forest', 6, 'Troll Hollow', 'Defeat 6 Forest Trolls',
     'Forest trolls hit hard and slowly. Watch for the slam and step out of it.', 'Borin', {}),
    (17, 'n', 'kill', 'inferi', 20, 'Sealing the Crypt', 'Defeat 20 Drowned Ones',
     'Keep the Drowned Ones in Crypt Hollow from reaching the forest paths.', 'Archivist Emrel Sav',
     {'items': [('mat_phoenix_ash', 5)]}),
    (17, 'n', 'kill', 'darksnatcher', 16, 'Dark Thicket', 'Defeat 16 Bandits',
     'The bandits fell back into the Dark Thicket, far to the west.', 'Bessa Tull', {}),
    (18, 'b', 'kill', 'troll_forest', 10, 'Hollow Drums', 'Defeat 10 Forest Trolls',
     'The trolls beat drums every night. Silence them.', 'Borin',
     {'items': [('scroll_imbue', 2)]}),
    (18, 'n', 'kill', 'acromantula', 20, 'Spider Woods', 'Defeat 20 Black Weavers',
     'Larger spiders hunt in the Spider Woods; something is feeding them.', 'Borin', {}),
    (19, 'n', 'kill', 'inferi', 22, 'The Southern Barrows', 'Defeat 22 Drowned Ones',
     'The barrows south of the lake have broken open.', 'Archivist Emrel Sav', {}),
    (19, 's', 'visit', "Smugglers' Camp", 1, "The Smugglers' Camp", "Scout the Smugglers' Camp",
     'Find the bandit captain\'s camp deep in the northern woods, past Bandit Woods. Do not engage alone.', 'Bessa Tull', {}),
    (20, 'B', 'kill', 'darksnatcher', 1, 'The Bandit Chief', "Defeat the captain at the Smugglers' Camp",
     'Gather friends and defeat the Bandit Chief in his camp.', 'Bessa Tull',
     {'boss': True, 'items': [('wand_silverthorn', 1)]}),
    (20, 'n', 'kill', 'troll_forest', 10, 'Last of the Hollow', 'Defeat 10 Forest Trolls',
     'Without the bandits\' coin the trolls of the hollow will scatter. Finish them.', 'Borin',
     {'items': [('mat_dragon_heartstring', 2)]}),
    # ---------------------------------------------------------------- 21-26 Barrows and Webs
    (21, 'n', 'kill', 'darksnatcher', 20, 'Ridge Path', 'Defeat 20 Bandits',
     'The captain\'s men fled up the Ridge Path. Hunt them down.', 'Bessa Tull', {}),
    (21, 'n', 'kill', 'inferi', 24, 'Barrow Watch', 'Defeat 24 Drowned Ones',
     'Hold the Southern Barrows while Archivist Emrel Sav searches her records.', 'Archivist Emrel Sav', {}),
    (22, 'n', 'kill', 'acromantula', 22, 'Brood of the Woods', 'Defeat 22 Black Weavers',
     'Every spider in the Spider Woods answers to one mother.', 'Borin',
     {'items': [('cloak_thornveil', 1)]}),
    (22, 'n', 'kill', 'inferi', 24, 'Crypt Gate', 'Defeat 24 Drowned Ones',
     'The Crypt Gate to the west is the source. Thin the dead around it.', 'Archivist Emrel Sav', {}),
    (23, 'n', 'enchant', '', 2, 'Weaving for War', 'Enchant items twice',
     'Kestrin says no one should face the Black Widow with bare robes.', 'Kestrin',
     {'items': [('scroll_reweave', 2)]}),
    (23, 'n', 'kill', 'darksnatcher', 22, 'Ridge Ambush', 'Defeat 22 Bandits',
     'The bandits ambush anyone who climbs the Ridge Path.', 'Bessa Tull', {}),
    (24, 'b', 'kill', 'acromantula', 26, "The Black Widow's Guard", 'Defeat 26 Black Weavers',
     'Clear the spiders that guard the way to Spider Hollow.', 'Borin',
     {'items': [('mat_thestral_hair', 1)]}),
    (24, 's', 'visit', 'Spider Hollow', 1, 'Spider Hollow', 'Find Spider Hollow',
     'The Black Widow nests in Spider Hollow in the far south-west, beyond the Spider Woods.', 'Borin', {}),
    (25, 'B', 'kill', 'acromantula', 1, 'The Black Widow', 'Defeat the Black Widow',
     'Bring a party. The Black Widow\'s bite poisons and her brood answers her call.', 'Borin',
     {'boss': True, 'items': [('broom_silverthorn', 1)]}),
    (25, 'n', 'kill', 'inferi', 26, 'Gate of Bones', 'Defeat 26 Drowned Ones',
     'With the Black Widow gone, Archivist Emrel Sav can finally seal the Crypt Gate.', 'Archivist Emrel Sav', {}),
    (26, 'n', 'refine', '', 3, "The Forge's Fire", 'Refine any item three times',
     'The moors are harder still. Kestrin will not let you go up there half-made.', 'Kestrin',
     {'items': [('mat_dragon_heartstring', 3)]}),
    (26, 'b', 'kill', 'troll_forest', 12, 'Western Moor', 'Defeat 12 Forest Trolls',
     'Forest trolls have climbed onto the Western Moor.', 'Borin', {}),
    # ---------------------------------------------------------------- 27-30 The Moors
    (27, 'n', 'talk', 'Flight Master Kaelen Rook', 1, 'Moorland Orders', 'Speak with Flight Master Kaelen Rook',
     'Kaelen Rook is organising the students who go up to the moors.', 'Flight Master Kaelen Rook', {}),
    (27, 'n', 'kill', 'troll_forest', 12, 'Trolls on the Heath', 'Defeat 12 Forest Trolls',
     'Push the forest trolls off the Western Moor.', 'Flight Master Kaelen Rook', {}),
    (28, 'n', 'kill', 'darksnatcher', 22, 'Orvell Heights', 'Defeat 22 Bandits',
     'The heights above Orvell are crawling with dark wizards.', 'Bessa Tull', {}),
    (28, 'n', 'kill', 'darksnatcher', 24, 'Watchers on the Heights', 'Defeat 24 Bandits',
     'They are watching the village. Make them stop.', 'Bessa Tull',
     {'items': [('scroll_imbue', 3)]}),
    (29, 'b', 'kill', 'darksnatcher', 26, 'Clearing the Heights', 'Defeat 26 Bandits',
     'One last push and Orvell can sleep again.', 'Bessa Tull', {}),
    (29, 's', 'visit', 'Highland Moor', 1, 'The Highland Moor', 'Reach the Highland Moor',
     'Mountain trolls have been seen on the Highland Moor, north of the pitch.', 'Flight Master Kaelen Rook', {}),
    (30, 'n', 'kill', 'troll_mountain', 8, 'Mountain Trolls', 'Defeat 8 Mountain Trolls',
     'Mountain trolls throw boulders as well as fists. Keep moving.', 'Flight Master Kaelen Rook', {}),
    (30, 'b', 'kill', 'troll_mountain', 10, 'Boulder Throwers', 'Defeat 10 Mountain Trolls',
     'Every troll you fell is one less marching on the castle.', 'Flight Master Kaelen Rook',
     {'items': [('mat_thestral_hair', 1)]}),
    # ---------------------------------------------------------------- 31-34 The Forbidden Corridor
    (31, 'n', 'talk', 'Archivist Emrel Sav', 1, 'Out of Bounds', 'Speak with Archivist Emrel Sav about the sealed wing',
     "Archivist Emrel Sav has found a note: the sealed wing hides a piece of an old gate to another realm - and it is guarded.", 'Archivist Emrel Sav', {}),
    (31, 'n', 'kill', 'cornish_pixie', 8, 'Pests of the Sealed Wing', 'Defeat 8 Fidgetlings',
     'Enter the Sealed Wing from the castle. The fidgetlings swarm and lift you off your feet.', 'Archivist Emrel Sav', {}),
    (32, 'n', 'kill', 'armour_guard', 6, 'Living Armour', 'Defeat 6 Suits of Armour',
     'Enchanted suits of armour guard the corridor. Force spells shake them apart.', 'Flight Master Kaelen Rook', {}),
    (32, 'B', 'kill', 'armour_commander', 1, 'The Cursed Commander', 'Defeat the Cursed Commander',
     'The commander of the armour stands at the corridor\'s first gate.', 'Flight Master Kaelen Rook',
     {'boss': True, 'items': [('mat_elder_core', 1)]}),
    (33, 'B', 'kill', 'devils_snare', 1, "Strangling Vine", "Burn the root of the Strangling Vine",
     'Fire is the answer. Burn the vines, then the root.', 'Archivist Emrel Sav',
     {'boss': True, 'items': [('scroll_reweave', 2)]}),
    (33, 'n', 'kill', 'cornish_pixie', 10, 'More Fidgetlings', 'Defeat 10 Fidgetlings',
     'The fidgetlings on the stairs beyond the snare are worse than the first lot.', 'Archivist Emrel Sav', {}),
    (34, 'B', 'kill', 'fluffy', 1, 'Threehead', 'Defeat Threehead',
     'Ring the sleep chime to lull the heads, then strike while they doze.', 'Borin',
     {'boss': True, 'items': [('mat_thestral_hair', 2)]}),
    (34, 'B', 'dungeon', 'forbidden_corridor', 1, 'The Corridor Cleared', 'Complete the Sealed Wing',
     'Run the corridor from the fidgetlings to the stone hatch in one go.', 'Flight Master Kaelen Rook',
     {'items': [('scroll_imbue', 3)]}),
    # ---------------------------------------------------------------- 35-40 Stone and Storm
    (35, 'n', 'talk', 'Kestrin', 1, 'A Wand for the Storm', 'Speak with Kestrin',
     'Kestrin has finished a wand worthy of what comes next.', 'Kestrin',
     {'items': [('wand_emberwing', 1)]}),
    (35, 'n', 'kill', 'troll_mountain', 12, 'Eastern Moor', 'Defeat 12 Mountain Trolls',
     'Grak\'s trolls hold the Eastern Moor.', 'Flight Master Kaelen Rook', {}),
    (36, 'n', 'kill', 'darksnatcher', 26, "Grak's Allies", 'Defeat 26 Bandits',
     'Dark wizards march with the trolls on the Eastern Moor.', 'Bessa Tull', {}),
    (36, 'n', 'kill', 'troll_mountain', 14, 'The Troll Muster', 'Defeat 14 Mountain Trolls',
     'Break the muster before it reaches the summit.', 'Flight Master Kaelen Rook',
     {'items': [('mat_dragon_heartstring', 3)]}),
    (37, 'n', 'kill', 'darksnatcher', 28, 'Storm Riders', 'Defeat 28 Bandits',
     'The dark wizards ride the storm clouds over the moor.', 'Bessa Tull',
     {'items': [('cloak_phoenix', 1)]}),
    (37, 'n', 'enchant', '', 3, 'Velkar Weave', 'Enchant items three times',
     'A Velkar Regalia deserves its weave. Make the most of it.', 'Kestrin', {}),
    (38, 's', 'visit', 'Stone Circle Summit', 1, 'Stone Circle Summit', 'Climb to the Stone Circle Summit',
     "Grak, the Mountain Troll Chieftain, waits at the summit, where his clans worship a fallen Dark Shard.", 'Flight Master Kaelen Rook', {}),
    (38, 'B', 'kill', 'troll_mountain', 1, 'Grak the Chieftain', 'Defeat Grak, Mountain Troll Chieftain',
     'Grak only appears every so often. Gather a party and be ready.', 'Flight Master Kaelen Rook',
     {'boss': True, 'items': [('mat_elder_core', 1)]}),
    (39, 'b', 'kill', 'troll_mountain', 16, 'Scattering the Clans', 'Defeat 16 Mountain Trolls',
     'Without their chieftain the clans fight among themselves. Finish them.', 'Borin', {}),
    (39, 'n', 'kill', 'darksnatcher', 28, 'Deserters', 'Defeat 28 Bandits',
     'The dark wizards who marched with Grak are fleeing across the Eastern Moor.', 'Bessa Tull',
     {'items': [('scroll_imbue', 2)]}),
    (40, 'n', 'monolith', '', 1, 'Stones Still Standing', 'Destroy a Dark Shard or a Webbound Seal Stone',
     "Grak is gone, but the Ash Priest keeps pulling shards down. Break a Dark Shard in the western forests or a Webbound Seal Stone in the Blackweb Caverns, with others.", 'Master Teral Venn', {}),
    (40, 'b', 'refine', '', 3, 'Masterwork', 'Refine any item three times',
     'Pallids are coming. Kestrin wants every piece you own at its best.', 'Kestrin',
     {'items': [('broom_emberwing', 1)]}),
    # ---------------------------------------------------------------- 41-50 The Long Mist
    (41, 'n', 'talk', 'Master Teral Venn', 1, 'Light of Ithrel', 'Speak with Master Teral Venn about the Light of Ithrel',
     "Master Teral Venn says Pallids fear nothing but the Light of Ithrel, a guardian spirit drawn from the World-Star's light. Learn it in your spell book (V) - it opens at level 40.", 'Master Teral Venn', {}),
    (41, 'n', 'kill', 'dementor', 10, 'The Misty Shore', 'Defeat 10 Pallids',
     'Pallids drift in from the Misty Shore. Their aura stops your health from recovering.', 'Master Teral Venn', {}),
    (42, 'n', 'kill', 'dementor', 12, 'Station Mist', 'Defeat 12 Pallids',
     'The old station is lost in the mist.', 'Master Teral Venn', {}),
    (42, 'n', 'kill', 'dementor', 12, 'Cold Platform', 'Defeat 12 more Pallids',
     'Hold the platform until the mist lifts.', 'Master Teral Venn',
     {'items': [('mat_thestral_hair', 2)]}),
    (43, 'n', 'kill', 'dementor', 14, 'Shoreline Vigil', 'Defeat 14 Pallids',
     'Keep the Misty Shore clear for the boats.', 'Borin', {}),
    (43, 'n', 'enchant', '', 3, 'Warmth Against the Cold', 'Enchant items three times',
     'Kestrin has a theory about weaves that resist despair.', 'Kestrin',
     {'items': [('scroll_imbue', 3)]}),
    (44, 'n', 'kill', 'dementor', 14, 'Fog Barrens', 'Defeat 14 Pallids',
     'South of the castle the Fog Barrens have swallowed the road.', 'Master Teral Venn', {}),
    (44, 's', 'visit', 'Fog Barrens', 1, 'Into the Fog', 'Reach the Fog Barrens',
     'Mark the edge of the fog so the others can follow.', 'Flight Master Kaelen Rook', {}),
    (45, 'b', 'kill', 'dementor', 16, 'Shades of the Barrens', 'Defeat 16 Pallids',
     'The deeper you go, the colder it gets.', 'Master Teral Venn',
     {'items': [('mat_elder_core', 1)]}),
    (45, 'n', 'kill', 'dementor', 16, 'Lights in the Fog', 'Defeat 16 more Pallids',
     'Every Light of Ithrel you cast lights the way for someone else.', 'Master Teral Venn', {}),
    (46, 'n', 'kill', 'dementor', 16, 'Grey Marsh', 'Defeat 16 Pallids',
     'The Grey Marsh is where the mist begins.', 'Borin', {}),
    (46, 'n', 'refine', '', 3, 'The Last Polish', 'Refine any item three times',
     'Kestrin wants one more look at your gear before the end.', 'Kestrin', {}),
    (47, 'n', 'kill', 'dementor', 18, 'Marsh Wardens', 'Defeat 18 Pallids',
     'Pallids circle a barrow at the far end of the marsh.', 'Borin', {}),
    (47, 'n', 'kill', 'dementor', 18, 'Breaking the Circle', 'Defeat 18 more Pallids',
     'Break their circle and the barrow is exposed.', 'Master Teral Venn',
     {'items': [('mat_thestral_hair', 3)]}),
    (48, 'b', 'kill', 'dementor', 20, 'The Cold Heart', 'Defeat 20 Pallids',
     'Something at the heart of the marsh calls them.', 'Master Teral Venn', {}),
    (48, 's', 'visit', "Warden's Barrow", 1, "Warden's Barrow", "Find Warden's Barrow",
     'The Morhal Warden sleeps in a barrow in the marsh.', 'Master Teral Venn', {}),
    (49, 'b', 'kill', 'dementor', 22, 'Before the Storm', 'Defeat 22 Pallids',
     'Clear the way to the barrow for your party.', 'Master Teral Venn',
     {'items': [('scroll_reweave', 3)]}),
    (49, 'n', 'talk', 'Master Teral Venn', 1, 'Final Preparations', 'Speak with Master Teral Venn',
     "Master Teral Venn has one last piece of advice before you face the Warden of Morhal, the jailer the Ash Priest turned to his side.", 'Master Teral Venn', {}),
    (50, 'B', 'kill', 'dementor', 1, 'The Morhal Warden', 'Defeat the Morhal Warden',
     'Gather your strongest friends. The Warden drains hope itself.', 'Master Teral Venn',
     {'boss': True, 'items': [('wand_moonveil', 1)]}),
    (50, 'B', 'talk', 'Master Teral Venn', 1, 'Graduation', 'Report your victory to Master Teral Venn',
     "The valley is safe - for now. The Ash Priest has fled through a rift into another realm. Master Teral Venn is waiting to congratulate you.", 'Master Teral Venn',
     {'items': [('cloak_moonveil', 1)]}),
]

# Story links: a quest opens only after the listed quests were claimed
# (quest number -> numbers). Everything else opens on its level alone, so quests
# accumulate in the log and none has to be done in order.
REQUIRES = {
    2: [1],      # wear the cloak Fig gave you
    10: [9],     # fly the broom Flitwick gave you
    13: [12],    # refine after meeting Ollivander
    15: [13],    # enchant with the scrolls the refine quest paid
    20: [19],    # equip the wand the Trial Hall paid
    39: [38],    # the Snatcher Captain after scouting his camp
    49: [48],    # the Matriarch after finding Spider Hollow
    62: [61],    # the Forbidden Corridor after Madam Pince's note
    76: [75],    # Grak after climbing the summit
    99: [96],    # the Warden after finding the barrow
    100: [99],   # graduation after the Warden
}

PLACES = OrderedDict([('Skyring Pitch', {'map': 'grounds', 'center': [330, -330], 'radius': 85})])


def _round_half_up(x):
    return int(x + 0.5)


def exp_threshold(combat, level, tuning=None):
    """Mirror of HPRules.exp_threshold (and pack_exp_reward)."""
    base = combat['base_stats']
    curve = base.get('exp_curve')
    if curve and tuning is not None:
        mob = _round_half_up(float(tuning.get('exp_base', 25)) + level * float(tuning.get('exp_per_level', 6))
                             + level * level * float(tuning.get('exp_per_level_sq', 0.0)))
        kills = float(curve.get('kills_base', 10)) + float(curve.get('kills_per_level', 10)) * (level - 1)
        return min(int(combat['limits'].get('max_exp', 2000000000)), _round_half_up(mob * kills / 10.0) * 10)
    value = float(base.get('exp_base', 200))
    cap = float(combat['limits'].get('max_exp', 2000000000))
    for _ in range(max(0, level - 1)):
        value = min(cap, value * float(base.get('exp_growth', 1.5)))
    return int(value)


def main():
    combat = json.load(open(os.path.join(DATA, 'combat.json'), encoding='utf-8'))
    items = json.load(open(os.path.join(DATA, 'items.json'), encoding='utf-8'))
    spawns = json.load(open(os.path.join(DATA, 'spawn_tables.json'), encoding='utf-8'))
    mobs = json.load(open(os.path.join(DATA, 'mobs.json'), encoding='utf-8'))['mobs']
    dungeons = json.load(open(os.path.join(DATA, 'dungeons.json'), encoding='utf-8'))['dungeons']
    for region in spawns['regions']:
        if region.get('display'):
            PLACES[region['display']] = {'map': region.get('map', 'grounds'), 'center': region['center'],
                                         'radius': region['radius']}

    assert len(CHAIN) == 100, len(CHAIN)
    chain = []
    seen = set()
    per_level = {}
    for index, row in enumerate(CHAIN):
        level, size, kind, target, count, title, name, desc, giver, extra = row
        per_level[level] = per_level.get(level, 0) + 1
        share, gold_per, gold_base, rep = SIZES[size]
        chapter = [c for c in CHAPTERS if c[0] <= level][-1]
        qid = 'q%03d' % (index + 1)
        assert qid not in seen
        seen.add(qid)
        if kind == 'kill':
            assert target in mobs, target
        if kind == 'visit':
            assert target in PLACES, target
        if kind == 'dungeon':
            assert target in dungeons, target
        q = OrderedDict()
        q['id'] = qid
        q['chapter'] = chapter[1]
        q['level'] = level
        q['title'] = title
        q['name'] = name
        q['desc'] = desc
        q['giver'] = giver
        q['type'] = kind
        q['target'] = target
        q['count'] = count
        if extra.get('boss'):
            q['boss'] = True
        if extra.get('mounted'):
            q['mounted'] = True
        if index + 1 in REQUIRES:
            q['requires'] = ['q%03d' % n for n in REQUIRES[index + 1]]
            assert all(n < index + 1 for n in REQUIRES[index + 1])
        q['reward_exp'] = _round_half_up(exp_threshold(combat, level, spawns.get('pack_tuning', {})) * share)
        q['reward_gold'] = level * gold_per + gold_base
        q['reward_house_rep'] = rep
        rewards = []
        for item_id, amount in extra.get('items', []):
            assert item_id in items, item_id
            rewards.append(OrderedDict([('id', item_id), ('amount', amount)]))
        if rewards:
            q['reward_items'] = rewards
        chain.append(q)
    # Two per level, except the tutorial: three at level 1 (nothing there needs
    # experience), one at level 2.
    assert sorted(per_level) == list(range(1, 51)) and all(n == 2 for l, n in per_level.items() if l > 2), per_level
    levels = [q['level'] for q in chain]
    assert levels == sorted(levels)

    out = OrderedDict()
    out['_comment'] = (
        "Quest log, decided by the authority (SimAuthority quest_event). Generated by server/tools/gen_quests.py - edit the "
        "table there and re-run. Two quests per level 1-50. A quest is open once the player reached its `level` and claimed "
        "every quest in `requires`; open quests accumulate and progress independently. A finished quest waits in `ready` until "
        "the player claims it (sim_quest_claim), which pays the reward. Types: talk (target = NPC name, within talk_radius), kill (target = mob species from its scene; "
        "`boss` counts only boss kills), dummy (hits on a training dummy), equip (target = equipment slot), refine (a successful "
        "refinement), enchant (a successful imbue), monolith, dungeon (target = dungeons.json id, the run completes), enter_map "
        "(target = map id), visit (target = a place below; `mounted` requires the broom). Rewards: reward_exp (a share of the "
        "level's experience threshold by size), reward_gold, reward_house_rep, reward_items [{id, amount}] (bag, or a personal "
        "chest at the player's feet when it is full). Progress persists in the character's `quests` object (progress, "
        "ready, done).")
    out['chapters'] = [OrderedDict([('level', c[0]), ('title', c[1]), ('desc', c[2])]) for c in CHAPTERS]
    out['talk_radius'] = 6.0
    out['places'] = PLACES
    out['chain'] = chain
    path = os.path.join(DATA, 'quests.json')
    open(path, 'w', encoding='utf-8', newline='\n').write(json.dumps(out, indent=2, ensure_ascii=False) + '\n')
    print('wrote %d quests to %s' % (len(chain), path))


if __name__ == '__main__':
    main()
