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
    (1, 'First Year', 'Settle in at Hogwarts: your cloak, your first spells, your first broom.'),
    (6, 'The Forest Edge', 'The creatures at the forest edge grow bolder; learn the forge and the trial.'),
    (11, 'Roads to Hogsmeade', 'Snatchers prowl the roads; the village needs a wand it can trust.'),
    (16, 'Crypts and Trolls', 'Something stirs in the crypts and the trolls come down from their hollow.'),
    (21, 'Barrows and Webs', 'The dead rise in the barrows and the Matriarch spins in her hollow.'),
    (27, 'The Moors', 'Trolls and dark wizards hold the moors above Hogsmeade.'),
    (31, 'The Forbidden Corridor', 'The third-floor corridor is out of bounds - and something guards it.'),
    (35, 'Stone and Storm', 'Mountain trolls gather under Grak at the Stone Circle Summit.'),
    (41, 'The Long Mist', 'Dementors drift in from the shore; only a Patronus will hold them back.'),
]

# (level, size, type, target, count, title, objective, story, giver, extra)
# extra: reward items [(id, amount)], 'boss': True, 'mounted': True
CHAIN = [
    # ---------------------------------------------------------------- 1-5 First Year
    (1, 's', 'talk', 'Professor Fig', 1, 'First-Year Orientation', 'Speak with Professor Fig by the fountain',
     'Professor Fig waits beside the courtyard fountain (the bobbing gold arrow). Walk up and click him or press F to talk.', 'Professor Fig',
     {'items': [('cloak_wool', 1)]}),
    (1, 's', 'equip', 'chest', 1, 'Dressed for the Grounds', "Wear the Woolen Traveller's Cloak",
     'Open your bag with I and right-click the cloak Professor Fig gave you. It costs a little speed and buys a lot of armour.', 'Professor Fig',
     {'items': [('potion_health', 5)]}),
    (1, 's', 'dummy', '', 5, 'Wand Drills', 'Hit a training dummy 5 times',
     'Three training dummies stand by the east road, just outside the courtyard wall - they never hit back. Left-click to cast; spells hurt nothing inside the safe courtyard.', 'Professor Fig',
     {'items': [('hat_apprentice', 1)]}),
    (2, 'n', 'kill', 'acromantula', 6, 'Spiders at the Gate', 'Defeat 6 Acromantulas',
     'Leave the courtyard for the Village Outskirts or the Pitch Outskirts. Hit one spider and its pack answers - keep moving.', 'Professor Fig',
     {'items': [('gloves_apprentice', 1)]}),
    (3, 'n', 'kill', 'inferi', 6, 'Restless Dead', 'Defeat 6 Inferi',
     'Inferi stalk the Forest Edge past Borin\'s hut. Fire (Incendio) hurts them twice as much.', 'Borin',
     {'items': [('boots_apprentice', 1)]}),
    (3, 's', 'talk', 'Borin', 1, "Borin's Hut", 'Report to Borin at his hut',
     'Borin Ashgrove, the forest warden, keeps watch from his hut west of the castle.', 'Borin',
     {'items': [('focus_apprentice', 1)]}),
    (4, 'n', 'kill', 'acromantula', 10, 'Thinning the Brood', 'Defeat 10 Acromantulas',
     'The spiders breed faster than anyone can count. Greenhouse Meadow is crawling with them.', 'Borin',
     {'items': [('pendant_apprentice', 1)]}),
    (4, 's', 'enter_map', 'castle_interior', 1, 'Through the Great Doors', 'Enter Hogwarts Castle',
     'Walk up the castle approach and press F in the doorway to go inside.', 'Madam Pince',
     {'items': [('ring_apprentice', 1)]}),
    (5, 'b', 'talk', 'Professor Flitwick', 1, 'Your First Broom', 'Collect your broom from Professor Flitwick',
     'At level 5 every student gets a broom. Professor Flitwick waits at the castle approach.', 'Professor Flitwick',
     {'items': [('broom_ashwood', 1)]}),
    (5, 'n', 'visit', 'Quidditch Pitch', 1, 'Quidditch Tryouts', 'Fly to the Quidditch Pitch on your broom',
     'Equip the broom, press Shift to mount, Space to rise and Ctrl to descend. Land on level ground and press Shift to dismount.', 'Professor Flitwick',
     {'mounted': True, 'items': [('potion_mana', 5)]}),
    # ---------------------------------------------------------------- 6-10 The Forest Edge
    (6, 'n', 'kill', 'inferi', 12, 'Ash and Bone', 'Defeat 12 Inferi',
     'The Inferi gather again at the Forest Edge and in Greenhouse Meadow.', 'Borin',
     {'items': [('mat_phoenix_ash', 3)]}),
    (6, 's', 'talk', 'Ollivander', 1, "Ollivander's Forge", 'Speak with Ollivander',
     'Ollivander works his anvil in the courtyard. He can make a wand stronger, at a price.', 'Ollivander', {}),
    (7, 'n', 'refine', '', 1, 'A Stronger Wand', 'Refine your wand once at Ollivander',
     'Press O to open Ollivander\'s workshop, drag your wand onto the anvil and refine it with Phoenix Ash and Galleons.', 'Ollivander',
     {'items': [('scroll_imbue', 2)]}),
    (7, 'n', 'kill', 'acromantula', 12, 'The Eastern Road', 'Defeat 12 Acromantulas',
     'Merchants on the Eastern Road are turning back. Clear the spiders from the verges.', 'Madam Rosmerta', {}),
    (8, 'n', 'enchant', '', 1, 'Woven Magic', 'Enchant an item at Ollivander',
     'Put any piece of gear on the anvil and use an Imbue Scroll. A failed weave still spends the scroll.', 'Ollivander',
     {'items': [('scroll_reweave', 1)]}),
    (8, 'n', 'kill', 'inferi', 14, 'The Long Road Home', 'Defeat 14 Inferi',
     'Inferi wander onto the Eastern Road at dusk. Keep the road open.', 'Madam Rosmerta', {}),
    (9, 'b', 'kill', 'acromantula', 16, 'Acromantula Thicket', 'Defeat 16 Acromantulas',
     'West of the forest edge the spiders grow to the size of carts. Bring potions.', 'Borin',
     {'items': [('mat_phoenix_ash', 3)]}),
    (9, 'b', 'monolith', '', 1, 'Shatter the Darkness', 'Help destroy a Dark Monolith',
     'Dark Monoliths fall in the western forests (Forest Edge, Acromantula Thicket, Snatcher Woods, Crypt Hollow). Follow the tall green light or find them on your map (M), then break one with others before its waves overrun you.', 'Professor Fig', {}),
    (10, 'B', 'dungeon', 'trial', 1, 'The Trial Hall', 'Complete the Trial Hall',
     'The Trial Hall portal is the glowing arch on the courtyard lawn, beside the lake walk. Step into it and press F, clear the corridor, then defeat the Trial Warden. Up to five can go in together.', 'Professor Fig',
     {'items': [('wand_runebound', 1)]}),
    (10, 's', 'equip', 'main_hand', 1, 'A Wand Worth Keeping', 'Equip the Runebound Walnut Wand',
     'Your new wand rolls a far higher Attack and Magic Attack Value. Equip it from your bag.', 'Ollivander',
     {'items': [('potion_health', 10)]}),
    # ---------------------------------------------------------------- 11-15 Roads to Hogsmeade
    (11, 'n', 'kill', 'darksnatcher', 10, 'Snatchers on the Road', 'Defeat 10 Snatchers',
     'Snatchers waylay travellers on the Hogsmeade Road. They cast back - keep your distance.', 'Madam Rosmerta', {}),
    (11, 's', 'talk', 'Madam Rosmerta', 1, 'The Three Broomsticks', 'Speak with Madam Rosmerta in Hogsmeade',
     'Fly east along the Hogsmeade Road. Madam Rosmerta knows every rumour in the valley.', 'Madam Rosmerta', {}),
    (12, 'n', 'kill', 'acromantula', 15, 'Pitch Woods', 'Defeat 15 Acromantulas',
     'The woods behind the Quidditch Pitch are thick with webs.', 'Professor Flitwick',
     {'items': [('cloak_runed', 1)]}),
    (12, 'n', 'kill', 'inferi', 15, 'Lakeside Glade', 'Defeat 15 Inferi',
     'Inferi crawl out of the Black Lake at the Lakeside Glade.', 'Borin', {}),
    (13, 'n', 'kill', 'darksnatcher', 14, 'Snatcher Woods', 'Defeat 14 Snatchers',
     'The snatchers have a camp in the woods north-west of the castle. Drive them out.', 'Madam Rosmerta',
     {'items': [('mat_dragon_heartstring', 2)]}),
    (13, 's', 'visit', 'Lakeside Glade', 1, 'Survey the Lake', 'Visit the Lakeside Glade',
     'Borin wants to know how far the Inferi have spread along the shore.', 'Borin', {}),
    (14, 'n', 'kill', 'acromantula', 18, 'Webs in the Glade', 'Defeat 18 Acromantulas',
     'Spiders and dead share the Lakeside Glade now. Clear the spiders first.', 'Borin', {}),
    (14, 'n', 'refine', '', 2, 'Steel for the Road', 'Refine any item twice',
     'Ollivander can refine cloaks, accessories and brooms as well as wands.', 'Ollivander',
     {'items': [('scroll_imbue', 2)]}),
    (15, 'b', 'kill', 'darksnatcher', 18, 'Breaking the Ring', 'Defeat 18 Snatchers',
     'Rosmerta has heard the snatchers answer to a captain. Weaken them before he moves.', 'Madam Rosmerta',
     {'items': [('broom_runebound', 1)]}),
    (15, 'n', 'kill', 'inferi', 18, 'Crypt Hollow', 'Defeat 18 Inferi',
     'Deeper in the forest an old crypt has opened. The Inferi pour out of Crypt Hollow.', 'Madam Pince', {}),
    # ---------------------------------------------------------------- 16-20 Crypts and Trolls
    (16, 'n', 'talk', 'Madam Pince', 1, 'Records of the Crypt', 'Speak with Madam Pince',
     'Madam Pince keeps the records of every grave on the grounds. She waits at the castle approach.', 'Madam Pince', {}),
    (16, 'n', 'kill', 'troll_forest', 6, 'Troll Hollow', 'Defeat 6 Forest Trolls',
     'Forest trolls hit hard and slowly. Watch for the slam and step out of it.', 'Borin', {}),
    (17, 'n', 'kill', 'inferi', 20, 'Sealing the Crypt', 'Defeat 20 Inferi',
     'Keep the Inferi in Crypt Hollow from reaching the forest paths.', 'Madam Pince',
     {'items': [('mat_phoenix_ash', 5)]}),
    (17, 'n', 'kill', 'darksnatcher', 16, 'Dark Thicket', 'Defeat 16 Snatchers',
     'The snatchers fell back into the Dark Thicket, far to the west.', 'Madam Rosmerta', {}),
    (18, 'b', 'kill', 'troll_forest', 10, 'Hollow Drums', 'Defeat 10 Forest Trolls',
     'The trolls beat drums every night. Silence them.', 'Borin',
     {'items': [('scroll_imbue', 2)]}),
    (18, 'n', 'kill', 'acromantula', 20, 'Spider Woods', 'Defeat 20 Acromantulas',
     'Larger spiders hunt in the Spider Woods; something is feeding them.', 'Borin', {}),
    (19, 'n', 'kill', 'inferi', 22, 'The Southern Barrows', 'Defeat 22 Inferi',
     'The barrows south of the lake have broken open.', 'Madam Pince', {}),
    (19, 's', 'visit', "Smugglers' Camp", 1, "The Smugglers' Camp", "Scout the Smugglers' Camp",
     'Find the snatcher captain\'s camp deep in the northern woods, past Snatcher Woods. Do not engage alone.', 'Madam Rosmerta', {}),
    (20, 'B', 'kill', 'darksnatcher', 1, 'The Snatcher Captain', "Defeat the captain at the Smugglers' Camp",
     'Gather friends and defeat the Snatcher Captain in his camp.', 'Madam Rosmerta',
     {'boss': True, 'items': [('wand_silverthorn', 1)]}),
    (20, 'n', 'kill', 'troll_forest', 10, 'Last of the Hollow', 'Defeat 10 Forest Trolls',
     'Without the snatchers\' coin the trolls of the hollow will scatter. Finish them.', 'Borin',
     {'items': [('mat_dragon_heartstring', 2)]}),
    # ---------------------------------------------------------------- 21-26 Barrows and Webs
    (21, 'n', 'kill', 'darksnatcher', 20, 'Ridge Path', 'Defeat 20 Snatchers',
     'The captain\'s men fled up the Ridge Path. Hunt them down.', 'Madam Rosmerta', {}),
    (21, 'n', 'kill', 'inferi', 24, 'Barrow Watch', 'Defeat 24 Inferi',
     'Hold the Southern Barrows while Madam Pince searches her records.', 'Madam Pince', {}),
    (22, 'n', 'kill', 'acromantula', 22, 'Brood of the Woods', 'Defeat 22 Acromantulas',
     'Every spider in the Spider Woods answers to one mother.', 'Borin',
     {'items': [('cloak_thornveil', 1)]}),
    (22, 'n', 'kill', 'inferi', 24, 'Crypt Gate', 'Defeat 24 Inferi',
     'The Crypt Gate to the west is the source. Thin the dead around it.', 'Madam Pince', {}),
    (23, 'n', 'enchant', '', 2, 'Weaving for War', 'Enchant items twice',
     'Ollivander says no one should face the Matriarch with bare robes.', 'Ollivander',
     {'items': [('scroll_reweave', 2)]}),
    (23, 'n', 'kill', 'darksnatcher', 22, 'Ridge Ambush', 'Defeat 22 Snatchers',
     'The snatchers ambush anyone who climbs the Ridge Path.', 'Madam Rosmerta', {}),
    (24, 'b', 'kill', 'acromantula', 26, "The Matriarch's Guard", 'Defeat 26 Acromantulas',
     'Clear the spiders that guard the way to Spider Hollow.', 'Borin',
     {'items': [('mat_thestral_hair', 1)]}),
    (24, 's', 'visit', 'Spider Hollow', 1, 'Spider Hollow', 'Find Spider Hollow',
     'The Matriarch nests in Spider Hollow in the far south-west, beyond the Spider Woods.', 'Borin', {}),
    (25, 'B', 'kill', 'acromantula', 1, 'The Matriarch', 'Defeat the Acromantula Matriarch',
     'Bring a party. The Matriarch\'s bite poisons and her brood answers her call.', 'Borin',
     {'boss': True, 'items': [('broom_silverthorn', 1)]}),
    (25, 'n', 'kill', 'inferi', 26, 'Gate of Bones', 'Defeat 26 Inferi',
     'With the Matriarch gone, Madam Pince can finally seal the Crypt Gate.', 'Madam Pince', {}),
    (26, 'n', 'refine', '', 3, "The Forge's Fire", 'Refine any item three times',
     'The moors are harder still. Ollivander will not let you go up there half-made.', 'Ollivander',
     {'items': [('mat_dragon_heartstring', 3)]}),
    (26, 'b', 'kill', 'troll_forest', 12, 'Western Moor', 'Defeat 12 Forest Trolls',
     'Forest trolls have climbed onto the Western Moor.', 'Borin', {}),
    # ---------------------------------------------------------------- 27-30 The Moors
    (27, 'n', 'talk', 'Professor Flitwick', 1, 'Moorland Orders', 'Speak with Professor Flitwick',
     'Flitwick is organising the students who go up to the moors.', 'Professor Flitwick', {}),
    (27, 'n', 'kill', 'troll_forest', 12, 'Trolls on the Heath', 'Defeat 12 Forest Trolls',
     'Push the forest trolls off the Western Moor.', 'Professor Flitwick', {}),
    (28, 'n', 'kill', 'darksnatcher', 22, 'Hogsmeade Heights', 'Defeat 22 Snatchers',
     'The heights above Hogsmeade are crawling with dark wizards.', 'Madam Rosmerta', {}),
    (28, 'n', 'kill', 'darksnatcher', 24, 'Watchers on the Heights', 'Defeat 24 Snatchers',
     'They are watching the village. Make them stop.', 'Madam Rosmerta',
     {'items': [('scroll_imbue', 3)]}),
    (29, 'b', 'kill', 'darksnatcher', 26, 'Clearing the Heights', 'Defeat 26 Snatchers',
     'One last push and Hogsmeade can sleep again.', 'Madam Rosmerta', {}),
    (29, 's', 'visit', 'Highland Moor', 1, 'The Highland Moor', 'Reach the Highland Moor',
     'Mountain trolls have been seen on the Highland Moor, north of the pitch.', 'Professor Flitwick', {}),
    (30, 'n', 'kill', 'troll_mountain', 8, 'Mountain Trolls', 'Defeat 8 Mountain Trolls',
     'Mountain trolls throw boulders as well as fists. Keep moving.', 'Professor Flitwick', {}),
    (30, 'b', 'kill', 'troll_mountain', 10, 'Boulder Throwers', 'Defeat 10 Mountain Trolls',
     'Every troll you fell is one less marching on the castle.', 'Professor Flitwick',
     {'items': [('mat_thestral_hair', 1)]}),
    # ---------------------------------------------------------------- 31-34 The Forbidden Corridor
    (31, 'n', 'talk', 'Madam Pince', 1, 'Out of Bounds', 'Speak with Madam Pince about the third floor',
     'Madam Pince has found a note: the third-floor corridor is out of bounds - and guarded.', 'Madam Pince', {}),
    (31, 'n', 'kill', 'cornish_pixie', 8, 'Pests of the Third Floor', 'Defeat 8 Cornish Pixies',
     'Enter the Forbidden Corridor from the castle. The pixies swarm and lift you off your feet.', 'Madam Pince', {}),
    (32, 'n', 'kill', 'armour_guard', 6, 'Living Armour', 'Defeat 6 Suits of Armour',
     'Enchanted suits of armour guard the corridor. Force spells shake them apart.', 'Professor Flitwick', {}),
    (32, 'B', 'kill', 'armour_commander', 1, 'The Cursed Commander', 'Defeat the Cursed Commander',
     'The commander of the armour stands at the corridor\'s first gate.', 'Professor Flitwick',
     {'boss': True, 'items': [('mat_elder_core', 1)]}),
    (33, 'B', 'kill', 'devils_snare', 1, "Devil's Snare", "Burn the root of the Devil's Snare",
     'Fire is the answer. Burn the vines, then the root.', 'Madam Pince',
     {'boss': True, 'items': [('scroll_reweave', 2)]}),
    (33, 'n', 'kill', 'cornish_pixie', 10, 'More Pixies', 'Defeat 10 Cornish Pixies',
     'The pixies on the stairs beyond the snare are worse than the first lot.', 'Madam Pince', {}),
    (34, 'B', 'kill', 'fluffy', 1, 'The Three-Headed Dog', 'Defeat Fluffy',
     'Use the harp to lull the heads to sleep, then strike while they doze.', 'Borin',
     {'boss': True, 'items': [('mat_thestral_hair', 2)]}),
    (34, 'B', 'dungeon', 'forbidden_corridor', 1, 'The Corridor Cleared', 'Complete the Forbidden Corridor',
     'Run the corridor from the pixies to the trapdoor in one go.', 'Professor Flitwick',
     {'items': [('scroll_imbue', 3)]}),
    # ---------------------------------------------------------------- 35-40 Stone and Storm
    (35, 'n', 'talk', 'Ollivander', 1, 'A Wand for the Storm', 'Speak with Ollivander',
     'Ollivander has finished a wand worthy of what comes next.', 'Ollivander',
     {'items': [('wand_emberwing', 1)]}),
    (35, 'n', 'kill', 'troll_mountain', 12, 'Eastern Moor', 'Defeat 12 Mountain Trolls',
     'Grak\'s trolls hold the Eastern Moor.', 'Professor Flitwick', {}),
    (36, 'n', 'kill', 'darksnatcher', 26, "Grak's Allies", 'Defeat 26 Snatchers',
     'Dark wizards march with the trolls on the Eastern Moor.', 'Madam Rosmerta', {}),
    (36, 'n', 'kill', 'troll_mountain', 14, 'The Troll Muster', 'Defeat 14 Mountain Trolls',
     'Break the muster before it reaches the summit.', 'Professor Flitwick',
     {'items': [('mat_dragon_heartstring', 3)]}),
    (37, 'n', 'kill', 'darksnatcher', 28, 'Storm Riders', 'Defeat 28 Snatchers',
     'The dark wizards ride the storm clouds over the moor.', 'Madam Rosmerta',
     {'items': [('cloak_phoenix', 1)]}),
    (37, 'n', 'enchant', '', 3, 'Phoenix Weave', 'Enchant items three times',
     'A Phoenix Regalia deserves its weave. Make the most of it.', 'Ollivander', {}),
    (38, 's', 'visit', 'Stone Circle Summit', 1, 'Stone Circle Summit', 'Climb to the Stone Circle Summit',
     'Grak, the Mountain Troll Chieftain, waits at the summit.', 'Professor Flitwick', {}),
    (38, 'B', 'kill', 'troll_mountain', 1, 'Grak the Chieftain', 'Defeat Grak, Mountain Troll Chieftain',
     'Grak only appears every so often. Gather a party and be ready.', 'Professor Flitwick',
     {'boss': True, 'items': [('mat_elder_core', 1)]}),
    (39, 'b', 'kill', 'troll_mountain', 16, 'Scattering the Clans', 'Defeat 16 Mountain Trolls',
     'Without their chieftain the clans fight among themselves. Finish them.', 'Borin', {}),
    (39, 'n', 'kill', 'darksnatcher', 28, 'Deserters', 'Defeat 28 Snatchers',
     'The dark wizards who marched with Grak are fleeing across the Eastern Moor.', 'Madam Rosmerta',
     {'items': [('scroll_imbue', 2)]}),
    (40, 'n', 'monolith', '', 1, 'Stones Still Standing', 'Destroy a Dark Monolith or a Webbound Seal Stone',
     'Grak is gone, but the stones keep falling. Break a Dark Monolith in the western forests or a Webbound Seal Stone in the Blackweb Caverns, with others.', 'Professor Fig', {}),
    (40, 'b', 'refine', '', 3, 'Masterwork', 'Refine any item three times',
     'Dementors are coming. Ollivander wants every piece you own at its best.', 'Ollivander',
     {'items': [('broom_emberwing', 1)]}),
    # ---------------------------------------------------------------- 41-50 The Long Mist
    (41, 'n', 'talk', 'Professor Fig', 1, 'Expecto Patronum', 'Speak with Professor Fig about the Patronus',
     'Professor Fig says Dementors fear nothing but the Patronus Charm. Learn Expecto Patronum in your spell book (V) - it opens at level 40.', 'Professor Fig', {}),
    (41, 'n', 'kill', 'dementor', 10, 'The Misty Shore', 'Defeat 10 Dementors',
     'Dementors drift in from the Misty Shore. Their aura stops your health from recovering.', 'Professor Fig', {}),
    (42, 'n', 'kill', 'dementor', 12, 'Station Mist', 'Defeat 12 Dementors',
     'The old station is lost in the mist.', 'Professor Fig', {}),
    (42, 'n', 'kill', 'dementor', 12, 'Cold Platform', 'Defeat 12 more Dementors',
     'Hold the platform until the mist lifts.', 'Professor Fig',
     {'items': [('mat_thestral_hair', 2)]}),
    (43, 'n', 'kill', 'dementor', 14, 'Shoreline Vigil', 'Defeat 14 Dementors',
     'Keep the Misty Shore clear for the boats.', 'Borin', {}),
    (43, 'n', 'enchant', '', 3, 'Warmth Against the Cold', 'Enchant items three times',
     'Ollivander has a theory about weaves that resist despair.', 'Ollivander',
     {'items': [('scroll_imbue', 3)]}),
    (44, 'n', 'kill', 'dementor', 14, 'Fog Barrens', 'Defeat 14 Dementors',
     'South of the castle the Fog Barrens have swallowed the road.', 'Professor Fig', {}),
    (44, 's', 'visit', 'Fog Barrens', 1, 'Into the Fog', 'Reach the Fog Barrens',
     'Mark the edge of the fog so the others can follow.', 'Professor Flitwick', {}),
    (45, 'b', 'kill', 'dementor', 16, 'Shades of the Barrens', 'Defeat 16 Dementors',
     'The deeper you go, the colder it gets.', 'Professor Fig',
     {'items': [('mat_elder_core', 1)]}),
    (45, 'n', 'kill', 'dementor', 16, 'Lights in the Fog', 'Defeat 16 more Dementors',
     'Every Patronus you cast lights the way for someone else.', 'Professor Fig', {}),
    (46, 'n', 'kill', 'dementor', 16, 'Grey Marsh', 'Defeat 16 Dementors',
     'The Grey Marsh is where the mist begins.', 'Borin', {}),
    (46, 'n', 'refine', '', 3, 'The Last Polish', 'Refine any item three times',
     'Ollivander wants one more look at your gear before the end.', 'Ollivander', {}),
    (47, 'n', 'kill', 'dementor', 18, 'Marsh Wardens', 'Defeat 18 Dementors',
     'Dementors circle a barrow at the far end of the marsh.', 'Borin', {}),
    (47, 'n', 'kill', 'dementor', 18, 'Breaking the Circle', 'Defeat 18 more Dementors',
     'Break their circle and the barrow is exposed.', 'Professor Fig',
     {'items': [('mat_thestral_hair', 3)]}),
    (48, 'b', 'kill', 'dementor', 20, 'The Cold Heart', 'Defeat 20 Dementors',
     'Something at the heart of the marsh calls them.', 'Professor Fig', {}),
    (48, 's', 'visit', "Warden's Barrow", 1, "Warden's Barrow", "Find Warden's Barrow",
     'The Azkaban Warden sleeps in a barrow in the marsh.', 'Professor Fig', {}),
    (49, 'b', 'kill', 'dementor', 22, 'Before the Storm', 'Defeat 22 Dementors',
     'Clear the way to the barrow for your party.', 'Professor Fig',
     {'items': [('scroll_reweave', 3)]}),
    (49, 'n', 'talk', 'Professor Fig', 1, 'Final Preparations', 'Speak with Professor Fig',
     'Professor Fig has one last piece of advice before you face the Warden.', 'Professor Fig', {}),
    (50, 'B', 'kill', 'dementor', 1, 'The Azkaban Warden', 'Defeat the Azkaban Warden',
     'Gather your strongest friends. The Warden drains hope itself.', 'Professor Fig',
     {'boss': True, 'items': [('wand_moonveil', 1)]}),
    (50, 'B', 'talk', 'Professor Fig', 1, 'Graduation', 'Report your victory to Professor Fig',
     'The valley is safe - for now. Professor Fig is waiting to congratulate you.', 'Professor Fig',
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

PLACES = OrderedDict([('Quidditch Pitch', {'map': 'grounds', 'center': [330, -330], 'radius': 85})])


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
