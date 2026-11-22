-- Dragonworld - data for the Professions tab
-- Made 2026-11-21 by tools\make_profession_data.js from Wowhead's guides for WoW Forever
-- (https://www.wowhead.com/forever/profession-leveling-guides/), the route "Tried & Tested in Forever".
-- DO NOT edit by hand: run the script again when Wowhead updates the guides.
--
-- professions[skillLine] = { name, icon, secondary, guide, version, updated,
--     gates = { { learn before skill, needs skill, needs level, "trainer"/"book"/"quest" }, ... },
--     steps = { { from skill, to skill, recipe (spell ID, 0 = text), note = Locales key }, ... },
--     makes = { [itemID] = the recipe the profession makes the intermediate product with } }
-- recipes[spellID] = { name, learned at skill, { orange, yellow, green, gray }, { { itemID, count }, ... },
--     creates = itemID, makes = count per craft (1 if not given), up = skill points per craft,
--     starter/trainer/drop/quest = true, cost = trainer price in copper,
--     vendors = { { npcID, price in copper, currencyID, currency amount, limited stock } },
--     recipeItem = itemID, rep = { faction, level }, spec, tools = { tool keys }, focus = station }
-- items[itemID] = { name, quality, kind, vendor price in copper, made with (professions) }
--     kind: "vendor" (bought), "craft" (made by the profession), "prof" (made by another
--     profession), "gather" (gathered, e.g. skinning), "other" (drops, farmed or AH)

local ADDON_NAME, DW = ...

DW.ProfessionData = {
    generated = "2026-11-21",
    professions = {
        [129] = {
            name = "First Aid", icon = "Interface\\Icons\\Spell_Holy_SealOfSacrifice", secondary = true,
            guide = "Tried & Tested in Forever", version = 1, updated = "2026-11-03",
            gates = { { 75, 50, 10, "trainer" }, { 150, 125, 0, "book" }, { 225, 0, 35, "quest" } },
            steps = {
                { 1, 40, 3275 }, -- Linen Bandage
                { 40, 80, 3276 }, -- Heavy Linen Bandage
                { 80, 115, 3277 }, -- Wool Bandage
                { 115, 150, 3278 }, -- Heavy Wool Bandage
                { 150, 180, 7928 }, -- Silk Bandage
                { 180, 210, 7929 }, -- Heavy Silk Bandage
                { 210, 240, 10840 }, -- Mageweave Bandage
                { 240, 260, 10841, note = "PROF_NOTE_FA_DOCTOR" }, -- Heavy Mageweave Bandage
                { 260, 290, 18629, note = "PROF_NOTE_FA_DOCTOR" }, -- Runecloth Bandage
                { 290, 300, 18630, note = "PROF_NOTE_FA_DOCTOR" }, -- Heavy Runecloth Bandage
            },
            makes = {  },
        },
        [164] = {
            name = "Blacksmithing", icon = "Interface\\Icons\\Trade_BlackSmithing", secondary = false,
            guide = "Tried & Tested in Forever", version = 2, updated = "2026-11-04",
            gates = { { 75, 50, 10, "trainer" }, { 150, 125, 20, "trainer" }, { 225, 200, 35, "trainer" } },
            steps = {
                { 1, 30, 2660 }, -- Rough Sharpening Stone
                { 30, 65, 3320, note = "PROF_NOTE_SAVE" }, -- Rough Grinding Stone
                { 65, 75, 2661 }, -- Copper Chain Belt
                { 75, 80, 19666 }, -- Silver Skeleton Key
                { 80, 90, 2668 }, -- Rough Bronze Leggings
                { 90, 100, 2666 }, -- Runed Copper Belt
                { 100, 105, 2674 }, -- Heavy Sharpening Stone
                { 105, 110, 2666 }, -- Runed Copper Belt
                { 110, 125, 2668 }, -- Rough Bronze Leggings
                { 125, 129, 8768 }, -- Iron Buckle
                { 129, 140, 9985 }, -- Bronze Warhammer
                { 140, 147, 2672 }, -- Patterned Bronze Bracers
                { 147, 155, 3501 }, -- Green Iron Bracers
                { 155, 165, 3506 }, -- Green Iron Leggings
                { 165, 183, 3501 }, -- Green Iron Bracers
                { 183, 190, 9928 }, -- Heavy Mithril Gauntlet
                { 190, 200, 7223 }, -- Golden Scale Bracers
                { 200, 205, 9928 }, -- Heavy Mithril Gauntlet
                { 205, 210, 9931 }, -- Mithril Plate Pants
                { 210, 215, 9928 }, -- Heavy Mithril Gauntlet
                { 215, 225, 9959 }, -- Heavy Mithril Breastplate
                { 225, 235, 16640 }, -- Dense Weightstone
                { 235, 240, 9961 }, -- Mithril Coif
                { 240, 246, 9968 }, -- Heavy Mithril Boots
                { 246, 250, 10001 }, -- Big Black Mace
                { 250, 257, 19669 }, -- Arcanite Skeleton Key
                { 257, 270, 10013 }, -- Ebon Shiv
                { 270, 275, 1252365 }, -- Bold Dirk
                { 275, 279, 16969 }, -- Ornate Thorium Handaxe
                { 279, 300, 1252365 }, -- Bold Dirk
            },
            makes = { [3470] = 3320, [3478] = 3326, [3486] = 3337, [7966] = 9920, [12644] = 16639 },
        },
        [165] = {
            name = "Leatherworking", icon = "Interface\\Icons\\Trade_LeatherWorking", secondary = false,
            guide = "Tried & Tested in Forever", version = 4, updated = "2026-11-04",
            gates = { { 75, 50, 10, "trainer" }, { 150, 125, 20, "trainer" }, { 225, 200, 35, "trainer" } },
            steps = {
                { 1, 30, 2881, note = "PROF_NOTE_SAVE" }, -- Light Leather
                { 30, 45, 2152 }, -- Light Armor Kit
                { 45, 55, 3816 }, -- Cured Light Hide
                { 55, 85, 3756 }, -- Embossed Leather Gloves
                { 85, 100, 3763, note = "PROF_NOTE_SAVE" }, -- Fine Leather Belt
                { 100, 115, 7135 }, -- Dark Leather Pants
                { 115, 118, 2167 }, -- Gray Leather Boots
                { 118, 125, 3766 }, -- Dark Leather Belt
                { 125, 135, 3818, note = "PROF_NOTE_SAVE" }, -- Cured Heavy Hide
                { 135, 143, 3766 }, -- Dark Leather Belt
                { 143, 145, 3818, note = "PROF_NOTE_SAVE" }, -- Cured Heavy Hide
                { 145, 155, 3770 }, -- Toughened Leather Gloves
                { 155, 160, 7151 }, -- Barbaric Shoulders
                { 160, 180, 3778 }, -- Gem-studded Leather Belt
                { 180, 185, 7151 }, -- Barbaric Shoulders
                { 185, 190, 3778 }, -- Gem-studded Leather Belt
                { 190, 200, 7156 }, -- Guardian Gloves
                { 200, 210, 10487 }, -- Thick Armor Kit
                { 210, 225, 10548 }, -- Nightscape Pants
                { 225, 230, 19047, note = "PROF_NOTE_SAVE" }, -- Cured Rugged Hide
                { 230, 240, 10548 }, -- Nightscape Pants
                { 240, 255, 19049 }, -- Wicked Leather Gauntlets
                { 255, 260, 19048 }, -- Heavy Scorpid Bracers
                { 260, 270, 19049 }, -- Wicked Leather Gauntlets
                { 270, 300, 19088 }, -- Heavy Scorpid Helm
            },
            makes = { [4233] = 3817, [4236] = 3818, [4246] = 3763, [15407] = 19047 },
        },
        [171] = {
            name = "Alchemy", icon = "Interface\\Icons\\Trade_Alchemy", secondary = false,
            guide = "Tried & Tested in Forever", version = 2, updated = "2026-11-03",
            gates = { { 75, 50, 10, "trainer" }, { 150, 125, 20, "trainer" }, { 225, 200, 35, "trainer" } },
            steps = {
                { 1, 12, 1245250 }, -- Elixir of Minor Force
                { 12, 55, 7183 }, -- Elixir of Minor Defense
                { 55, 65, 2331 }, -- Minor Mana Potion
                { 65, 90, 2334 }, -- Elixir of Minor Fortitude
                { 90, 120, 3171 }, -- Elixir of Wisdom
                { 120, 160, 3173 }, -- Lesser Mana Potion
                { 160, 195, 3452 }, -- Mana Potion
                { 195, 205, 11449 }, -- Elixir of Agility
                { 205, 225, 11448 }, -- Greater Mana Potion
                { 225, 226, 11459, note = "PROF_NOTE_PHILOSOPHER" }, -- Philosopher's Stone
                { 226, 240, 11448 }, -- Greater Mana Potion
                { 240, 260, 11460 }, -- Draught of Detect Undead
                { 260, 270, 17553 }, -- Superior Mana Potion
                { 270, 300, 1231583, note = "PROF_NOTE_DISCOLORED" }, -- Major Discolored Healing Potion
            },
            makes = {  },
        },
        [185] = {
            name = "Cooking", icon = "Interface\\Icons\\INV_Misc_Food_15", secondary = true,
            guide = "Tried & Tested in Forever", version = 2, updated = "2026-11-03",
            gates = { { 75, 50, 10, "trainer" }, { 150, 125, 0, "book" }, { 225, 0, 35, "quest" } },
            steps = {
                { 1, 50, 7751 }, -- Brilliant Smallfish
                { 50, 100, 7753 }, -- Longjaw Mud Snapper
                { 100, 175, 7755 }, -- Bristle Whisker Catfish
                { 175, 225, 20916 }, -- Mithril Headed Trout
                { 225, 275, 18238 }, -- Spotted Yellowtail
                { 275, 300, 18246 }, -- Mightfish Steak
            },
            makes = {  },
        },
        [197] = {
            name = "Tailoring", icon = "Interface\\Icons\\Trade_Tailoring", secondary = false,
            guide = "Tried & Tested in Forever", version = 2, updated = "2026-11-04",
            gates = { { 75, 50, 10, "trainer" }, { 150, 125, 20, "trainer" }, { 225, 200, 35, "trainer" } },
            steps = {
                { 1, 43, 2963, note = "PROF_NOTE_SAVE" }, -- Bolt of Linen Cloth
                { 43, 45, 2385 }, -- Brown Linen Vest
                { 45, 70, 8776 }, -- Linen Belt
                { 70, 75, 2397 }, -- Reinforced Linen Cape
                { 75, 81, 2964, note = "PROF_NOTE_SAVE" }, -- Bolt of Woolen Cloth
                { 81, 100, 2402 }, -- Woolen Cape
                { 100, 110, 3839, note = "PROF_NOTE_SAVE" }, -- Bolt of Silk Cloth
                { 110, 125, 3848 }, -- Double-stitched Woolen Shoulders
                { 125, 132, 8760 }, -- Azure Silk Hood
                { 132, 139, 6690 }, -- Lesser Wizard's Robe
                { 139, 140, 3871 }, -- Formal White Shirt
                { 140, 149, 3865, note = "PROF_NOTE_SAVE" }, -- Bolt of Mageweave
                { 149, 160, 8764 }, -- Earthen Vest
                { 160, 170, 8770 }, -- Robe of Power
                { 170, 180, 12048 }, -- Black Mageweave Vest
                { 180, 190, 12061 }, -- Orange Mageweave Shirt
                { 190, 205, 12053 }, -- Black Mageweave Gloves
                { 205, 214, 18401, note = "PROF_NOTE_SAVE" }, -- Bolt of Runecloth
                { 214, 234, 18402 }, -- Runecloth Belt
                { 234, 250, 18409 }, -- Runecloth Cloak
                { 250, 260, 18423 }, -- Runecloth Boots
                { 260, 280, 1257487 }, -- Runecloth Cuffs
                { 280, 285, 23662 }, -- Wisdom of the Timbermaw
                { 285, 292, 1297120 }, -- Venomspew Gloves
                { 292, 299, 1297121 }, -- Venomspew Cord
                { 299, 300, 1297122 }, -- Venomspew Footpads
            },
            makes = { [2996] = 2963, [2997] = 2964, [4305] = 3839, [4339] = 3865, [14048] = 18401 },
        },
        [202] = {
            name = "Engineering", icon = "Interface\\Icons\\Trade_Engineering", secondary = false,
            guide = "Tried & Tested in Forever", version = 2, updated = "2026-11-03",
            gates = { { 75, 50, 10, "trainer" }, { 150, 125, 20, "trainer" }, { 225, 200, 35, "trainer" } },
            steps = {
                { 1, 30, 3918, note = "PROF_NOTE_SAVE" }, -- Rough Blasting Powder
                { 30, 50, 3922, note = "PROF_NOTE_SAVE" }, -- Handful of Copper Bolts
                { 50, 51, 7430, note = "PROF_NOTE_SPANNER" }, -- Arclight Spanner
                { 51, 75, 3923 }, -- Rough Copper Bomb
                { 75, 90, 3929, note = "PROF_NOTE_SAVE" }, -- Coarse Blasting Powder
                { 90, 100, 3931 }, -- Coarse Dynamite
                { 100, 105, 3973 }, -- Silver Contact
                { 105, 125, 3938, note = "PROF_NOTE_SAVE" }, -- Bronze Tube
                { 125, 135, 3978 }, -- Standard Scope
                { 135, 150, 3942, note = "PROF_NOTE_SAVE" }, -- Whirring Bronze Gizmo
                { 150, 160, 3953, note = "PROF_NOTE_SAVE" }, -- Bronze Framework
                { 160, 175, 3955 }, -- Explosive Sheep
                { 175, 194, 12585, note = "PROF_NOTE_SAVE" }, -- Solid Blasting Powder
                { 194, 195, 12590, note = "PROF_NOTE_GYRO" }, -- Gyromatic Micro-Adjustor
                { 195, 200, 12589 }, -- Mithril Tube
                { 200, 215, 12591, note = "PROF_NOTE_SAVE" }, -- Unstable Trigger
                { 215, 238, 12599, note = "PROF_NOTE_SAVE" }, -- Mithril Casing
                { 238, 250, 12619 }, -- Hi-Explosive Bomb
                { 250, 260, 19788 }, -- Dense Blasting Powder
                { 260, 285, 19791 }, -- Thorium Widget
                { 285, 300, 19795 }, -- Thorium Tube
            },
            makes = { [4357] = 3918, [4359] = 3922, [4364] = 3929, [4371] = 3938, [4375] = 3942, [4377] = 3945, [4382] = 3953, [10505] = 12585, [10560] = 12591, [10561] = 12599 },
        },
        [333] = {
            name = "Enchanting", icon = "Interface\\Icons\\Trade_Engraving", secondary = false,
            guide = "Tried & Tested in Forever", version = 2, updated = "2026-11-03",
            gates = { { 75, 50, 10, "trainer" }, { 150, 125, 20, "trainer" }, { 225, 200, 35, "trainer" } },
            steps = {
                { 1, 2, 7421, note = "PROF_NOTE_FIRST_ROD" }, -- Runed Copper Rod
                { 2, 20, 0, note = "PROF_NOTE_DISENCHANT", text = true }, -- (text)
                { 20, 79, 14293 }, -- Lesser Magic Wand
                { 79, 90, 7426 }, -- Enchant Chest - Minor Absorption
                { 90, 100, 7457 }, -- Enchant Bracer - Minor Stamina
                { 100, 101, 7795, note = "PROF_NOTE_ROD_SILVER" }, -- Runed Silver Rod
                { 101, 110, 14807 }, -- Greater Magic Wand
                { 110, 135, 13419 }, -- Enchant Cloak - Minor Agility
                { 135, 155, 13501 }, -- Enchant Bracer - Lesser Stamina
                { 155, 156, 13628, note = "PROF_NOTE_ROD_GOLDEN" }, -- Runed Golden Rod
                { 156, 185, 13536 }, -- Enchant Bracer - Lesser Strength
                { 185, 200, 13661 }, -- Enchant Bracer - Strength
                { 200, 201, 13702, note = "PROF_NOTE_ROD_TRUESILVER" }, -- Runed Truesilver Rod
                { 201, 220, 13661 }, -- Enchant Bracer - Strength
                { 220, 225, 13746 }, -- Enchant Cloak - Greater Defense
                { 225, 230, 13815 }, -- Enchant Gloves - Agility
                { 230, 235, 13836 }, -- Enchant Boots - Stamina
                { 235, 250, 13858 }, -- Enchant Chest - Superior Stamina
                { 250, 265, 25127 }, -- Lesser Mana Oil
                { 265, 294, 20017 }, -- Enchant Shield - Greater Stamina
                { 294, 295, 20051, note = "PROF_NOTE_ROD_ARCANITE" }, -- Runed Arcanite Rod
                { 295, 300, 20015 }, -- Enchant Cloak - Superior Defense
            },
            makes = {  },
        },
    },
    recipes = {
        [2152] = { "Light Armor Kit", 1, { 1, 30, 45, 60 }, { { 2318, 1 } }, creates = 2304, starter = true },
        [2167] = { "Gray Leather Boots", 75, { 75, 100, 112, 125 }, { { 2319, 4 }, { 2321, 2 }, { 4340, 1 } }, creates = 2315, trainer = true, cost = 350 },
        [2331] = { "Minor Mana Potion", 25, { 25, 65, 85, 105 }, { { 785, 1 }, { 2447, 1 }, { 3371, 1 } }, creates = 2455, trainer = true, cost = 100 },
        [2334] = { "Elixir of Minor Fortitude", 50, { 50, 80, 100, 120 }, { { 2449, 2 }, { 2447, 1 }, { 3371, 1 } }, creates = 2458, trainer = true, cost = 250 },
        [2385] = { "Brown Linen Vest", 10, { 10, 45, 57, 70 }, { { 2996, 1 }, { 2320, 1 } }, creates = 2568, trainer = true, cost = 50 },
        [2397] = { "Reinforced Linen Cape", 35, { 35, 60, 77, 95 }, { { 2996, 2 }, { 2320, 3 } }, creates = 2580, trainer = true, cost = 200 },
        [2402] = { "Woolen Cape", 55, { 55, 80, 97, 115 }, { { 2997, 1 }, { 2321, 1 } }, creates = 2584, trainer = true, cost = 250 },
        [2660] = { "Rough Sharpening Stone", 1, { 1, 15, 35, 55 }, { { 2835, 1 } }, creates = 2862, starter = true },
        [2661] = { "Copper Chain Belt", 30, { 30, 70, 90, 110 }, { { 2840, 6 } }, creates = 2851, trainer = true, cost = 100, tools = { "c162" }, focus = "Anvil" },
        [2666] = { "Runed Copper Belt", 45, { 45, 85, 105, 125 }, { { 2840, 10 } }, creates = 2857, trainer = true, cost = 200, tools = { "c162" }, focus = "Anvil" },
        [2668] = { "Rough Bronze Leggings", 80, { 80, 120, 135, 150 }, { { 2841, 6 } }, creates = 2865, trainer = true, cost = 300, tools = { "c162" }, focus = "Anvil" },
        [2672] = { "Patterned Bronze Bracers", 95, { 95, 125, 140, 155 }, { { 2841, 5 }, { 3478, 2 } }, creates = 2868, trainer = true, cost = 500, tools = { "c162" }, focus = "Anvil" },
        [2674] = { "Heavy Sharpening Stone", 100, { 100, 100, 107, 115 }, { { 2838, 1 } }, creates = 2871, trainer = true, cost = 1000 },
        [2881] = { "Light Leather", 1, { 1, 20, 30, 40 }, { { 2934, 3 } }, creates = 2318, starter = true },
        [2963] = { "Bolt of Linen Cloth", 1, { 1, 25, 37, 50 }, { { 2589, 2 } }, creates = 2996, starter = true },
        [2964] = { "Bolt of Woolen Cloth", 55, { 55, 70, 77, 85 }, { { 2592, 3 } }, creates = 2997, trainer = true, cost = 100 },
        [3171] = { "Elixir of Wisdom", 90, { 90, 120, 140, 160 }, { { 785, 1 }, { 2450, 2 }, { 3371, 1 } }, creates = 3383, trainer = true, cost = 500 },
        [3173] = { "Lesser Mana Potion", 120, { 120, 145, 165, 185 }, { { 785, 1 }, { 3820, 1 }, { 3371, 1 } }, creates = 3385, trainer = true, cost = 1500 },
        [3275] = { "Linen Bandage", 1, { 1, 30, 45, 60 }, { { 2589, 1 } }, creates = 1251, starter = true },
        [3276] = { "Heavy Linen Bandage", 40, { 40, 50, 75, 100 }, { { 2589, 2 } }, creates = 2581, trainer = true, cost = 105 },
        [3277] = { "Wool Bandage", 80, { 80, 80, 115, 150 }, { { 2592, 1 } }, creates = 3530, trainer = true, cost = 250 },
        [3278] = { "Heavy Wool Bandage", 115, { 115, 115, 150, 185 }, { { 2592, 2 } }, creates = 3531, trainer = true, cost = 1000 },
        [3320] = { "Rough Grinding Stone", 25, { 25, 45, 65, 85 }, { { 2835, 2 } }, creates = 3470, trainer = true, cost = 100 },
        [3326] = { "Coarse Grinding Stone", 50, { 50, 50, 70, 90 }, { { 2836, 2 } }, creates = 3478, trainer = true, cost = 250 },
        [3337] = { "Heavy Grinding Stone", 100, { 100, 100, 112, 125 }, { { 2838, 3 } }, creates = 3486, trainer = true, cost = 1000 },
        [3452] = { "Mana Potion", 160, { 160, 180, 200, 220 }, { { 3820, 1 }, { 3356, 1 }, { 3372, 1 } }, creates = 3827, trainer = true, cost = 5000 },
        [3501] = { "Green Iron Bracers", 140, { 140, 165, 177, 190 }, { { 3575, 6 }, { 2605, 1 } }, creates = 3835, trainer = true, cost = 1000, tools = { "c162" }, focus = "Anvil" },
        [3506] = { "Green Iron Leggings", 130, { 130, 155, 167, 180 }, { { 3575, 8 }, { 3486, 1 }, { 2605, 1 } }, creates = 3842, trainer = true, cost = 5000, tools = { "c162" }, focus = "Anvil" },
        [3756] = { "Embossed Leather Gloves", 40, { 40, 70, 85, 100 }, { { 2318, 3 }, { 2320, 2 } }, creates = 4239, trainer = true, cost = 150 },
        [3763] = { "Fine Leather Belt", 55, { 55, 85, 100, 115 }, { { 2318, 6 }, { 2320, 2 } }, creates = 4246, trainer = true, cost = 300 },
        [3766] = { "Dark Leather Belt", 100, { 100, 125, 137, 150 }, { { 4246, 1 }, { 4233, 1 }, { 2321, 2 }, { 4340, 1 } }, creates = 4249, trainer = true, cost = 400 },
        [3770] = { "Toughened Leather Gloves", 110, { 110, 135, 147, 160 }, { { 2319, 4 }, { 4233, 2 }, { 3389, 2 }, { 3182, 2 }, { 2321, 2 } }, creates = 4253, trainer = true, cost = 500 },
        [3778] = { "Gem-studded Leather Belt", 160, { 160, 180, 190, 200 }, { { 4236, 4 }, { 5500, 2 }, { 1529, 2 }, { 3864, 1 }, { 2321, 1 } }, creates = 4262, drop = true, vendors = { { 2699, 3000, 0, 0, 1 }, { 12245, 3000, 0, 0, 1 } }, recipeItem = 14635, focus = "Tanning Rack" },
        [3816] = { "Cured Light Hide", 30, { 30, 50, 60, 70 }, { { 783, 1 }, { 4289, 1 } }, creates = 4231, trainer = true, cost = 50 },
        [3817] = { "Cured Medium Hide", 75, { 75, 90, 97, 105 }, { { 4232, 1 }, { 4289, 1 } }, creates = 4233, trainer = true, cost = 200 },
        [3818] = { "Cured Heavy Hide", 125, { 125, 135, 140, 145 }, { { 4235, 1 }, { 4289, 3 } }, creates = 4236, trainer = true, cost = 500 },
        [3839] = { "Bolt of Silk Cloth", 100, { 100, 110, 115, 120 }, { { 4306, 4 } }, creates = 4305, trainer = true, cost = 500 },
        [3848] = { "Double-stitched Woolen Shoulders", 85, { 85, 110, 127, 145 }, { { 2997, 3 }, { 2321, 2 } }, creates = 4314, trainer = true, cost = 500 },
        [3865] = { "Bolt of Mageweave", 140, { 140, 145, 147, 150 }, { { 4338, 5 } }, creates = 4339, trainer = true, cost = 1000 },
        [3871] = { "Formal White Shirt", 135, { 135, 145, 150, 155 }, { { 4305, 3 }, { 2324, 2 }, { 2321, 1 } }, creates = 4334, trainer = true, cost = 500 },
        [3918] = { "Rough Blasting Powder", 1, { 1, 20, 30, 40 }, { { 2835, 1 } }, creates = 4357, starter = true },
        [3922] = { "Handful of Copper Bolts", 30, { 30, 45, 52, 60 }, { { 2840, 1 } }, creates = 4359, trainer = true, cost = 115, tools = { "c162" }, focus = "Anvil" },
        [3923] = { "Rough Copper Bomb", 30, { 30, 60, 75, 90 }, { { 2840, 1 }, { 4359, 1 }, { 4357, 2 }, { 2589, 1 } }, creates = 4360, makes = 2, trainer = true, cost = 130, tools = { "c162" }, focus = "Anvil" },
        [3929] = { "Coarse Blasting Powder", 75, { 75, 85, 90, 95 }, { { 2836, 1 } }, creates = 4364, trainer = true, cost = 250 },
        [3931] = { "Coarse Dynamite", 75, { 75, 90, 97, 105 }, { { 4364, 3 }, { 2589, 1 } }, creates = 4365, makes = 2, trainer = true, cost = 250 },
        [3938] = { "Bronze Tube", 105, { 105, 105, 130, 155 }, { { 2841, 2 }, { 2880, 1 } }, creates = 4371, trainer = true, cost = 450, tools = { "c162" }, focus = "Anvil" },
        [3942] = { "Whirring Bronze Gizmo", 125, { 125, 125, 150, 175 }, { { 2841, 2 }, { 2592, 1 } }, creates = 4375, trainer = true, cost = 500, tools = { "c162", "c14" }, focus = "Anvil" },
        [3945] = { "Heavy Blasting Powder", 125, { 125, 125, 135, 145 }, { { 2838, 1 } }, creates = 4377, trainer = true, cost = 500 },
        [3953] = { "Bronze Framework", 145, { 145, 145, 170, 195 }, { { 2841, 2 }, { 2319, 1 }, { 2592, 1 } }, creates = 4382, trainer = true, cost = 600 },
        [3955] = { "Explosive Sheep", 150, { 150, 175, 187, 200 }, { { 4382, 1 }, { 4375, 1 }, { 4377, 2 }, { 2592, 2 } }, creates = 4384, trainer = true, cost = 750, tools = { "c162", "c14" }, focus = "Anvil" },
        [3973] = { "Silver Contact", 90, { 90, 110, 125, 140 }, { { 2842, 1 } }, creates = 4404, makes = 5, trainer = true, cost = 300 },
        [3978] = { "Standard Scope", 110, { 110, 135, 147, 160 }, { { 4371, 1 }, { 1206, 1 } }, creates = 4406, trainer = true, cost = 475, tools = { "c14" } },
        [6690] = { "Lesser Wizard's Robe", 110, { 110, 130, 145, 160 }, { { 4305, 2 }, { 2321, 2 }, { 3182, 2 } }, creates = 5766, trainer = true, cost = 1000 },
        [7135] = { "Dark Leather Pants", 90, { 90, 115, 127, 140 }, { { 2319, 12 }, { 4340, 1 }, { 2321, 1 } }, creates = 5961, trainer = true, cost = 400 },
        [7151] = { "Barbaric Shoulders", 150, { 150, 170, 180, 190 }, { { 4234, 8 }, { 4236, 1 }, { 2321, 2 } }, creates = 5964, trainer = true, cost = 1200 },
        [7156] = { "Guardian Gloves", 165, { 165, 185, 195, 205 }, { { 4234, 4 }, { 4236, 1 }, { 4291, 1 } }, creates = 5966, trainer = true, cost = 2400 },
        [7183] = { "Elixir of Minor Defense", 1, { 1, 55, 75, 95 }, { { 765, 1 }, { 2447, 1 }, { 3371, 1 } }, creates = 5997, starter = true },
        [7223] = { "Golden Scale Bracers", 160, { 160, 185, 197, 210 }, { { 3859, 5 }, { 3486, 2 } }, creates = 6040, trainer = true, cost = 1000, tools = { "c162" }, focus = "Anvil" },
        [7421] = { "Runed Copper Rod", 1, { 1, 5, 7, 10 }, { { 6217, 1 }, { 247786, 1 } }, creates = 6218, starter = true },
        [7426] = { "Enchant Chest - Minor Absorption", 40, { 40, 90, 110, 130 }, { { 10938, 1 } }, trainer = true, cost = 100, tools = { "c373" } },
        [7430] = { "Arclight Spanner", 50, { 50, 70, 80, 90 }, { { 2840, 6 } }, creates = 6219, trainer = true, cost = 150, tools = { "c162" }, focus = "Anvil" },
        [7457] = { "Enchant Bracer - Minor Stamina", 50, { 50, 100, 120, 140 }, { { 10940, 2 } }, trainer = true, cost = 250, tools = { "c373" } },
        [7751] = { "Brilliant Smallfish", 1, { 1, 45, 65, 85 }, { { 6291, 1 } }, creates = 6290, starter = true, vendors = { { 66, 38, 0, 0, 0 }, { 1684, 42, 0, 0, 0 }, { 3029, 38, 0, 0, 0 }, { 3550, 38, 0, 0, 0 }, { 4265, 42, 0, 0, 0 }, { 4574, 36, 0, 0, 0 }, { 5494, 38, 0, 0, 0 }, { 5940, 40, 0, 0, 0 }, { 8508, 42, 0, 0, 0 } }, recipeItem = 6325, focus = "Cooking Fire" },
        [7753] = { "Longjaw Mud Snapper", 50, { 50, 90, 110, 130 }, { { 6289, 1 } }, creates = 4592, vendors = { { 66, 423, 0, 0, 0 }, { 1684, 421, 0, 0, 0 }, { 3027, 378, 0, 0, 0 }, { 4265, 421, 0, 0, 0 }, { 4574, 360, 0, 0, 0 }, { 5162, 421, 0, 0, 0 }, { 5748, 400, 0, 0, 0 }, { 5940, 400, 0, 0, 0 } }, recipeItem = 6328, focus = "Cooking Fire" },
        [7755] = { "Bristle Whisker Catfish", 100, { 100, 140, 160, 180 }, { { 6308, 1 } }, creates = 4593, vendors = { { 2383, 1140, 0, 0, 0 }, { 2397, 1270, 0, 0, 0 }, { 3027, 1136, 0, 0, 0 }, { 3029, 1140, 0, 0, 0 }, { 3497, 1263, 0, 0, 0 }, { 4553, 1270, 0, 0, 0 }, { 5494, 1263, 0, 0, 0 }, { 260487, 1140, 0, 0, 0 } }, recipeItem = 6330, focus = "Cooking Fire" },
        [7795] = { "Runed Silver Rod", 100, { 100, 130, 150, 170 }, { { 6338, 1 }, { 10940, 3 }, { 10938, 4 }, { 1210, 1 } }, creates = 6339, trainer = true, cost = 1000 },
        [7928] = { "Silk Bandage", 150, { 150, 150, 180, 210 }, { { 4306, 1 } }, creates = 6450, trainer = true, cost = 5000 },
        [7929] = { "Heavy Silk Bandage", 180, { 180, 180, 210, 240 }, { { 4306, 2 } }, creates = 6451, vendors = { { 2805, 2090, 0, 0, 0 }, { 13476, 2090, 0, 0, 0 } }, recipeItem = 16112 },
        [8760] = { "Azure Silk Hood", 120, { 120, 130, 135, 140 }, { { 4305, 2 }, { 6260, 2 }, { 2321, 1 } }, creates = 7048, trainer = true, cost = 600 },
        [8764] = { "Earthen Vest", 135, { 135, 155, 170, 185 }, { { 4305, 3 }, { 7067, 1 }, { 2321, 2 } }, creates = 7051, trainer = true, cost = 900 },
        [8768] = { "Iron Buckle", 125, { 125, 125, 127, 130 }, { { 3575, 1 } }, creates = 7071, makes = 2, trainer = true, cost = 250, tools = { "c162" }, focus = "Anvil" },
        [8770] = { "Robe of Power", 155, { 155, 175, 190, 205 }, { { 4339, 2 }, { 7067, 2 }, { 7070, 2 }, { 7068, 2 }, { 7069, 2 }, { 4291, 2 } }, creates = 7054, trainer = true, cost = 1000, focus = "Spinning Wheel" },
        [8776] = { "Linen Belt", 15, { 15, 50, 67, 85 }, { { 2996, 1 }, { 2320, 1 } }, creates = 7026, trainer = true, cost = 50 },
        [9920] = { "Solid Grinding Stone", 175, { 175, 175, 180, 185 }, { { 7912, 4 } }, creates = 7966, trainer = true, cost = 2500 },
        [9928] = { "Heavy Mithril Gauntlet", 180, { 180, 200, 210, 220 }, { { 3860, 6 }, { 4338, 4 } }, creates = 7919, trainer = true, cost = 5000, tools = { "c162" }, focus = "Anvil" },
        [9931] = { "Mithril Plate Pants", 185, { 185, 205, 215, 225 }, { { 3860, 12 } }, creates = 7920, trainer = true, cost = 5000, tools = { "c162" }, focus = "Anvil" },
        [9959] = { "Heavy Mithril Breastplate", 205, { 205, 225, 235, 245 }, { { 3860, 16 } }, creates = 7930, trainer = true, cost = 15000, tools = { "c162" }, focus = "Anvil" },
        [9961] = { "Mithril Coif", 205, { 205, 225, 235, 245 }, { { 3860, 10 }, { 4338, 6 } }, creates = 7931, trainer = true, cost = 15000, tools = { "c162" }, focus = "Anvil" },
        [9968] = { "Heavy Mithril Boots", 210, { 210, 230, 240, 250 }, { { 3860, 14 }, { 4304, 4 } }, creates = 7933, trainer = true, cost = 20000, tools = { "c162" }, focus = "Anvil" },
        [9985] = { "Bronze Warhammer", 100, { 100, 155, 170, 185 }, { { 2841, 8 }, { 3466, 1 }, { 2319, 1 } }, creates = 7956, trainer = true, cost = 250, tools = { "c162" }, focus = "Anvil" },
        [10001] = { "Big Black Mace", 205, { 205, 230, 242, 255 }, { { 3860, 16 }, { 7971, 1 }, { 1210, 4 }, { 7966, 1 }, { 4304, 2 } }, creates = 7945, trainer = true, cost = 15000, tools = { "c162" }, focus = "Anvil" },
        [10013] = { "Ebon Shiv", 255, { 255, 255, 267, 280 }, { { 3860, 12 }, { 6037, 6 }, { 7910, 2 }, { 7966, 1 }, { 4304, 2 } }, creates = 7947, vendors = { { 11278, 10000, 0, 0, 0 } }, recipeItem = 8030, tools = { "c162" }, focus = "Anvil" },
        [10487] = { "Thick Armor Kit", 175, { 175, 195, 205, 215 }, { { 4304, 5 }, { 4291, 1 } }, creates = 8173, trainer = true, cost = 2000 },
        [10548] = { "Nightscape Pants", 205, { 205, 225, 235, 245 }, { { 4304, 14 }, { 4291, 4 } }, creates = 8193, trainer = true, cost = 4000 },
        [10840] = { "Mageweave Bandage", 210, { 210, 210, 240, 270 }, { { 4338, 1 } }, creates = 8544, vendors = { { 2805, 4750, 0, 0, 0 }, { 13476, 4750, 0, 0, 0 } }, recipeItem = 16113 },
        [10841] = { "Heavy Mageweave Bandage", 240, { 240, 240, 270, 300 }, { { 4338, 2 } }, creates = 8545, trainer = true },
        [11448] = { "Greater Mana Potion", 205, { 205, 220, 240, 260 }, { { 3358, 1 }, { 3821, 1 }, { 3372, 1 } }, creates = 6149, trainer = true, cost = 9000 },
        [11449] = { "Elixir of Agility", 185, { 185, 205, 225, 245 }, { { 3820, 1 }, { 3821, 1 }, { 3372, 1 } }, creates = 8949, trainer = true, cost = 6500 },
        [11459] = { "Philosopher's Stone", 225, { 225, 240, 260, 280 }, { { 3575, 4 }, { 9262, 1 }, { 8831, 4 }, { 4625, 4 } }, creates = 9149, vendors = { { 5594, 7600, 0, 0, 0 } }, recipeItem = 9303 },
        [11460] = { "Draught of Detect Undead", 230, { 230, 245, 265, 285 }, { { 8836, 1 }, { 8925, 1 } }, creates = 9154, trainer = true, cost = 5000 },
        [12048] = { "Black Mageweave Vest", 170, { 170, 185, 200, 215 }, { { 4339, 2 }, { 4291, 3 } }, creates = 9998, trainer = true, cost = 4000 },
        [12053] = { "Black Mageweave Gloves", 180, { 180, 195, 210, 225 }, { { 4339, 2 }, { 8343, 2 } }, creates = 10003, trainer = true, cost = 5000 },
        [12061] = { "Orange Mageweave Shirt", 180, { 180, 185, 190, 195 }, { { 4339, 1 }, { 6261, 1 }, { 8343, 1 } }, creates = 10056, trainer = true, cost = 2500 },
        [12585] = { "Solid Blasting Powder", 175, { 175, 175, 185, 195 }, { { 7912, 2 } }, creates = 10505, trainer = true, cost = 1000 },
        [12589] = { "Mithril Tube", 195, { 195, 195, 215, 235 }, { { 3860, 3 } }, creates = 10559, trainer = true, cost = 1300, tools = { "c162" }, focus = "Anvil" },
        [12590] = { "Gyromatic Micro-Adjustor", 175, { 175, 175, 195, 215 }, { { 3859, 4 } }, creates = 10498, trainer = true, cost = 1000, tools = { "c162" }, focus = "Anvil" },
        [12591] = { "Unstable Trigger", 200, { 200, 200, 220, 240 }, { { 3860, 1 }, { 4338, 1 }, { 10505, 1 } }, creates = 10560, trainer = true, cost = 1500, tools = { "c162", "c14" }, focus = "Anvil" },
        [12599] = { "Mithril Casing", 215, { 215, 215, 235, 255 }, { { 3860, 3 } }, creates = 10561, trainer = true, cost = 1800, tools = { "c162", "c14" }, focus = "Anvil" },
        [12619] = { "Hi-Explosive Bomb", 235, { 235, 235, 255, 275 }, { { 10561, 2 }, { 10560, 1 }, { 10505, 2 } }, creates = 10562, makes = 4, trainer = true, cost = 2400, tools = { "c162", "c14" }, focus = "Anvil" },
        [13419] = { "Enchant Cloak - Minor Agility", 110, { 110, 135, 155, 175 }, { { 10998, 1 } }, drop = true, vendors = { { 3954, 720, 0, 0, 0 }, { 12043, 757, 0, 0, 0 } }, recipeItem = 11039, tools = { "c374" } },
        [13501] = { "Enchant Bracer - Lesser Stamina", 130, { 130, 155, 175, 195 }, { { 11083, 1 } }, trainer = true, cost = 1500, tools = { "c374" } },
        [13536] = { "Enchant Bracer - Lesser Strength", 140, { 140, 165, 185, 205 }, { { 11083, 1 } }, vendors = { { 3954, 2250, 0, 0, 0 }, { 12043, 2368, 0, 0, 0 } }, recipeItem = 11101, tools = { "c374" } },
        [13628] = { "Runed Golden Rod", 150, { 150, 175, 195, 215 }, { { 11128, 1 }, { 5500, 1 }, { 11082, 1 }, { 11083, 1 } }, creates = 11130, trainer = true, cost = 2500 },
        [13661] = { "Enchant Bracer - Strength", 180, { 180, 200, 220, 240 }, { { 11137, 1 } }, trainer = true, cost = 3600, tools = { "c375" } },
        [13702] = { "Runed Truesilver Rod", 200, { 200, 220, 240, 260 }, { { 11144, 1 }, { 7971, 1 }, { 11135, 1 }, { 11137, 1 } }, creates = 11145, trainer = true, cost = 4000 },
        [13746] = { "Enchant Cloak - Greater Defense", 205, { 205, 225, 245, 265 }, { { 11137, 1 } }, trainer = true, cost = 4200, tools = { "c376" } },
        [13815] = { "Enchant Gloves - Agility", 210, { 210, 230, 250, 270 }, { { 11137, 1 } }, trainer = true, cost = 4400, tools = { "c376" } },
        [13836] = { "Enchant Boots - Stamina", 215, { 215, 235, 255, 275 }, { { 11137, 2 } }, trainer = true, cost = 4600, tools = { "c376" } },
        [13858] = { "Enchant Chest - Superior Stamina", 220, { 220, 240, 260, 280 }, { { 11137, 3 } }, trainer = true, cost = 4800, tools = { "c376" } },
        [14293] = { "Lesser Magic Wand", 10, { 10, 75, 95, 115 }, { { 4470, 1 }, { 10938, 1 } }, creates = 11287, trainer = true, cost = 50, tools = { "c373" } },
        [14807] = { "Greater Magic Wand", 70, { 70, 110, 130, 150 }, { { 4470, 1 }, { 10938, 2 } }, creates = 11288, trainer = true, cost = 200, tools = { "c373" } },
        [16639] = { "Dense Grinding Stone", 225, { 225, 230, 232, 235 }, { { 12365, 4 } }, creates = 12644, trainer = true, cost = 10000 },
        [16640] = { "Dense Weightstone", 225, { 225, 230, 232, 235 }, { { 12365, 1 } }, creates = 12643, trainer = true, cost = 10000 },
        [16969] = { "Ornate Thorium Handaxe", 275, { 275, 275, 287, 300 }, { { 12359, 20 }, { 12799, 2 }, { 12644, 2 }, { 8170, 4 } }, creates = 12773, vendors = { { 11278, 16000, 0, 0, 0 } }, recipeItem = 12819, tools = { "c162" }, focus = "Anvil" },
        [17553] = { "Superior Mana Potion", 260, { 260, 275, 295, 315 }, { { 8838, 2 }, { 8839, 2 }, { 8925, 1 } }, creates = 13443, vendors = { { 4226, 11400, 0, 0, 0 }, { 4610, 11368, 0, 0, 0 } }, recipeItem = 13477 },
        [18238] = { "Spotted Yellowtail", 225, { 225, 265, 285, 305 }, { { 4603, 1 } }, creates = 6887, vendors = { { 8137, 14400, 0, 0, 0 } }, recipeItem = 13939, focus = "Cooking Fire" },
        [18246] = { "Mightfish Steak", 275, { 275, 315, 335, 355 }, { { 13893, 1 }, { 2692, 1 }, { 3713, 1 } }, creates = 13934, vendors = { { 7947, 21176, 0, 0, 0 }, { 8145, 20000, 0, 0, 0 } }, recipeItem = 13948, focus = "Iron Oven" },
        [18401] = { "Bolt of Runecloth", 205, { 205, 210, 212, 215 }, { { 14047, 5 } }, creates = 14048, trainer = true, cost = 10000 },
        [18402] = { "Runecloth Belt", 210, { 210, 225, 240, 255 }, { { 14048, 3 }, { 14341, 1 } }, creates = 13856, trainer = true, cost = 10000 },
        [18409] = { "Runecloth Cloak", 220, { 220, 240, 255, 270 }, { { 14048, 4 }, { 14227, 1 }, { 14341, 1 } }, creates = 13860, vendors = { { 7940, 12000, 0, 0, 1 } }, recipeItem = 14472 },
        [18423] = { "Runecloth Boots", 235, { 235, 250, 265, 280 }, { { 14048, 4 }, { 14227, 2 }, { 8170, 4 }, { 14341, 1 } }, creates = 13864, vendors = { { 7940, 20000, 0, 0, 1 } }, recipeItem = 14488 },
        [18629] = { "Runecloth Bandage", 260, { 260, 260, 290, 320 }, { { 14047, 1 } }, creates = 14529, trainer = true },
        [18630] = { "Heavy Runecloth Bandage", 290, { 290, 290, 320, 350 }, { { 14047, 2 } }, creates = 14530, trainer = true },
        [19047] = { "Cured Rugged Hide", 225, { 225, 225, 230, 235 }, { { 8171, 1 }, { 15409, 1 } }, creates = 15407, makes = 2, trainer = true, cost = 5000, focus = "Tanning Rack" },
        [19048] = { "Heavy Scorpid Bracers", 255, { 255, 255, 260, 270 }, { { 8170, 4 }, { 15408, 4 }, { 14341, 1 } }, creates = 15077, vendors = { { 12956, 12000, 0, 0, 0 } }, recipeItem = 15724 },
        [19049] = { "Wicked Leather Gauntlets", 235, { 235, 255, 265, 275 }, { { 8170, 8 }, { 2325, 1 }, { 14341, 1 } }, creates = 15083, vendors = { { 12942, 12000, 0, 0, 1 }, { 12943, 12000, 0, 0, 1 } }, recipeItem = 15725 },
        [19088] = { "Heavy Scorpid Helm", 270, { 270, 290, 300, 310 }, { { 8170, 8 }, { 15408, 12 }, { 15407, 1 }, { 14341, 1 } }, creates = 15080, vendors = { { 12956, 25000, 0, 0, 0 } }, recipeItem = 15762 },
        [19666] = { "Silver Skeleton Key", 75, { 75, 75, 85, 95 }, { { 2842, 1 }, { 3470, 1 } }, creates = 15869, makes = 2, trainer = true, cost = 100, tools = { "c162" }, focus = "Anvil" },
        [19669] = { "Arcanite Skeleton Key", 250, { 250, 250, 255, 260 }, { { 12360, 1 }, { 12644, 1 } }, creates = 15872, makes = 2, trainer = true, cost = 10000, tools = { "c162" }, focus = "Anvil" },
        [19788] = { "Dense Blasting Powder", 250, { 250, 250, 255, 260 }, { { 12365, 2 } }, creates = 15992, trainer = true, cost = 4000 },
        [19791] = { "Thorium Widget", 260, { 260, 280, 290, 300 }, { { 12359, 3 }, { 14047, 1 } }, creates = 15994, vendors = { { 3413, 10800, 0, 0, 0 }, { 5175, 11368, 0, 0, 0 } }, recipeItem = 16042, tools = { "c162", "c14" }, focus = "Anvil" },
        [19795] = { "Thorium Tube", 275, { 275, 295, 305, 315 }, { { 12359, 6 } }, creates = 16000, vendors = { { 11185, 14400, 0, 0, 0 }, { 260565, 15200, 0, 0, 0 } }, recipeItem = 16047, tools = { "c162", "c14" }, focus = "Anvil" },
        [20015] = { "Enchant Cloak - Superior Defense", 285, { 285, 305, 325, 345 }, { { 16204, 8 } }, drop = true, vendors = { { 12022, 20000, 0, 0, 1 } }, recipeItem = 16224, tools = { "c376" } },
        [20017] = { "Enchant Shield - Greater Stamina", 265, { 265, 285, 305, 325 }, { { 11176, 6 } }, vendors = { { 4229, 12631, 0, 0, 1 }, { 4561, 12705, 0, 0, 1 } }, recipeItem = 16217, tools = { "c376" } },
        [20051] = { "Runed Arcanite Rod", 290, { 290, 310, 330, 350 }, { { 16206, 1 }, { 13926, 1 }, { 16204, 10 }, { 16203, 4 }, { 14343, 4 }, { 14344, 2 } }, creates = 16207, vendors = { { 12022, 23157, 0, 0, 0 } }, recipeItem = 16243 },
        [20916] = { "Mithril Headed Trout", 175, { 175, 215, 235, 255 }, { { 8365, 1 } }, creates = 8364, vendors = { { 2383, 2090, 0, 0, 0 }, { 2664, 2090, 0, 0, 0 }, { 3178, 2329, 0, 0, 0 }, { 3333, 2329, 0, 0, 0 }, { 4307, 2200, 0, 0, 0 }, { 4574, 1980, 0, 0, 0 }, { 5162, 2315, 0, 0, 0 }, { 12033, 2315, 0, 0, 0 }, { 12962, 2200, 0, 0, 0 } }, recipeItem = 17062, focus = "Cooking Fire" },
        [23662] = { "Wisdom of the Timbermaw", 255, { 255, 270, 285, 300 }, { { 14048, 8 }, { 7076, 3 }, { 12803, 3 }, { 14227, 2 } }, creates = 19047, vendors = { { 11557, 23157, 0, 0, 0 } }, recipeItem = 19215, rep = { "Timbermaw Hold", "Honored" }, focus = "Spinning Wheel" },
        [25127] = { "Lesser Mana Oil", 250, { 250, 260, 270, 280 }, { { 11176, 1 }, { 8831, 1 }, { 8925, 1 } }, creates = 20747, vendors = { { 12944, 11250, 0, 0, 0 }, { 15419, 9500, 0, 0, 0 } }, recipeItem = 20754, tools = { "c376" } },
        [1231583] = { "Major Discolored Healing Potion", 250, { 250, 290, 310, 330 }, { { 8925, 1 }, { 13466, 1 }, { 730, 1 } }, creates = 241650, trainer = true, cost = 10000 },
        [1245250] = { "Elixir of Minor Force", 1, { 1, 10, 12, 15 }, { { 765, 1 }, { 3371, 1 } }, creates = 247755, starter = true },
        [1252365] = { "Bold Dirk", 270, { 270, 290, 300, 310 }, { { 12359, 30 }, { 7082, 4 }, { 249726, 10 }, { 8170, 4 } }, creates = 250616, quest = true, vendors = { { 266901, 95000, 0, 0, 0 } }, recipeItem = 251468, tools = { "c162" }, focus = "Anvil" },
        [1257487] = { "Runecloth Cuffs", 250, { 250, 265, 280, 295 }, { { 14048, 5 }, { 14227, 1 }, { 14341, 1 } }, creates = 254123, quest = true, vendors = { { 266901, 95000, 0, 0, 0 } }, recipeItem = 254124 },
        [1297120] = { "Venomspew Gloves", 285, { 285, 290, 292, 295 }, { { 14048, 4 }, { 14343, 1 }, { 7082, 3 }, { 14341, 6 } }, creates = 275604, vendors = { { 15179, 75000, 0, 0, 0 } }, recipeItem = 275580, rep = { "Cenarion Circle", "Friendly" }, focus = "Loom" },
        [1297121] = { "Venomspew Cord", 290, { 290, 295, 297, 300 }, { { 14048, 6 }, { 14343, 1 }, { 7082, 3 }, { 14341, 6 } }, creates = 275605, vendors = { { 15179, 75000, 0, 0, 0 } }, recipeItem = 275581, rep = { "Cenarion Circle", "Honored" }, focus = "Loom" },
        [1297122] = { "Venomspew Footpads", 295, { 295, 295, 297, 300 }, { { 14048, 5 }, { 14343, 1 }, { 7082, 3 }, { 14341, 6 } }, creates = 275606, vendors = { { 15179, 75000, 0, 0, 0 } }, recipeItem = 275582, rep = { "Cenarion Circle", "Honored" }, focus = "Loom" },
    },
    items = {
        [730] = { "Murloc Eye", 1, "other", 0 },
        [765] = { "Silverleaf", 1, "other", 0 },
        [783] = { "Light Hide", 1, "gather", 0 },
        [785] = { "Mageroyal", 1, "other", 0 },
        [1206] = { "Moss Agate", 2, "other", 0 },
        [1210] = { "Shadowgem", 2, "other", 0 },
        [1251] = { "Linen Bandage", 1, "craft", 0 },
        [1529] = { "Jade", 2, "other", 0 },
        [2304] = { "Light Armor Kit", 1, "craft", 0 },
        [2315] = { "Gray Leather Boots", 2, "craft", 0 },
        [2318] = { "Light Leather", 1, "gather", 0 },
        [2319] = { "Medium Leather", 1, "gather", 0 },
        [2320] = { "Coarse Thread", 1, "vendor", 9 },
        [2321] = { "Fine Thread", 1, "vendor", 90 },
        [2324] = { "Bleach", 1, "vendor", 23 },
        [2325] = { "Black Dye", 1, "vendor", 900 },
        [2447] = { "Peacebloom", 1, "other", 0 },
        [2449] = { "Earthroot", 1, "other", 0 },
        [2450] = { "Briarthorn", 1, "other", 0 },
        [2455] = { "Minor Mana Potion", 1, "craft", 0 },
        [2458] = { "Elixir of Minor Fortitude", 1, "craft", 0 },
        [2568] = { "Brown Linen Vest", 1, "craft", 0 },
        [2580] = { "Reinforced Linen Cape", 2, "craft", 0 },
        [2581] = { "Heavy Linen Bandage", 1, "craft", 0 },
        [2584] = { "Woolen Cape", 2, "craft", 0 },
        [2589] = { "Linen Cloth", 1, "other", 0 },
        [2592] = { "Wool Cloth", 1, "gather", 0 },
        [2605] = { "Green Dye", 1, "vendor", 90 },
        [2692] = { "Hot Spices", 1, "vendor", 36 },
        [2835] = { "Rough Stone", 1, "other", 0 },
        [2836] = { "Coarse Stone", 1, "other", 0 },
        [2838] = { "Heavy Stone", 1, "other", 0 },
        [2840] = { "Copper Bar", 1, "prof", 0, "Mining" },
        [2841] = { "Bronze Bar", 1, "prof", 0, "Mining" },
        [2842] = { "Silver Bar", 2, "prof", 0, "Mining" },
        [2851] = { "Copper Chain Belt", 2, "craft", 0 },
        [2857] = { "Runed Copper Belt", 2, "craft", 0 },
        [2862] = { "Rough Sharpening Stone", 1, "craft", 0 },
        [2865] = { "Rough Bronze Leggings", 2, "craft", 0 },
        [2868] = { "Patterned Bronze Bracers", 2, "craft", 0 },
        [2871] = { "Heavy Sharpening Stone", 1, "craft", 0 },
        [2880] = { "Weak Flux", 1, "vendor", 88 },
        [2934] = { "Ruined Leather Scraps", 1, "gather", 0 },
        [2996] = { "Bolt of Linen Cloth", 1, "craft", 0 },
        [2997] = { "Bolt of Woolen Cloth", 1, "craft", 0 },
        [3182] = { "Spider's Silk", 1, "other", 0 },
        [3356] = { "Kingsblood", 1, "other", 0 },
        [3358] = { "Khadgar's Whisker", 1, "other", 0 },
        [3371] = { "Empty Vial", 1, "vendor", 17 },
        [3372] = { "Leaded Vial", 1, "vendor", 180 },
        [3383] = { "Elixir of Wisdom", 1, "craft", 0 },
        [3385] = { "Lesser Mana Potion", 1, "craft", 0 },
        [3389] = { "Elixir of Lesser Defense", 1, "prof", 0, "Alchemy" },
        [3466] = { "Strong Flux", 1, "vendor", 1777 },
        [3470] = { "Rough Grinding Stone", 1, "craft", 0 },
        [3478] = { "Coarse Grinding Stone", 1, "craft", 0 },
        [3486] = { "Heavy Grinding Stone", 1, "craft", 0 },
        [3530] = { "Wool Bandage", 1, "craft", 0 },
        [3531] = { "Heavy Wool Bandage", 1, "craft", 0 },
        [3575] = { "Iron Bar", 1, "prof", 0, "Mining" },
        [3713] = { "Soothing Spices", 1, "vendor", 144 },
        [3820] = { "Stranglekelp", 1, "other", 0 },
        [3821] = { "Goldthorn", 1, "other", 0 },
        [3827] = { "Mana Potion", 1, "craft", 0 },
        [3835] = { "Green Iron Bracers", 2, "craft", 0 },
        [3842] = { "Green Iron Leggings", 2, "craft", 0 },
        [3859] = { "Steel Bar", 1, "prof", 0, "Mining" },
        [3860] = { "Mithril Bar", 1, "prof", 0, "Mining" },
        [3864] = { "Citrine", 2, "other", 0 },
        [4231] = { "Cured Light Hide", 1, "craft", 0 },
        [4232] = { "Medium Hide", 1, "gather", 0 },
        [4233] = { "Cured Medium Hide", 1, "craft", 0 },
        [4234] = { "Heavy Leather", 1, "gather", 0 },
        [4235] = { "Heavy Hide", 1, "gather", 0 },
        [4236] = { "Cured Heavy Hide", 1, "craft", 0 },
        [4239] = { "Embossed Leather Gloves", 2, "craft", 0 },
        [4246] = { "Fine Leather Belt", 2, "craft", 0 },
        [4249] = { "Dark Leather Belt", 2, "craft", 0 },
        [4253] = { "Toughened Leather Gloves", 3, "craft", 0 },
        [4262] = { "Gem-studded Leather Belt", 3, "craft", 0 },
        [4289] = { "Salt", 1, "vendor", 45 },
        [4291] = { "Silken Thread", 1, "vendor", 450 },
        [4304] = { "Thick Leather", 1, "gather", 0 },
        [4305] = { "Bolt of Silk Cloth", 1, "craft", 0 },
        [4306] = { "Silk Cloth", 1, "other", 0 },
        [4314] = { "Double-Stitched Woolen Shoulders", 2, "craft", 0 },
        [4334] = { "Formal White Shirt", 1, "craft", 0 },
        [4338] = { "Mageweave Cloth", 1, "other", 0 },
        [4339] = { "Bolt of Mageweave", 1, "craft", 0 },
        [4340] = { "Gray Dye", 1, "vendor", 315 },
        [4357] = { "Rough Blasting Powder", 1, "craft", 0 },
        [4359] = { "Handful of Copper Bolts", 1, "craft", 0 },
        [4360] = { "Rough Copper Bomb", 1, "craft", 0 },
        [4364] = { "Coarse Blasting Powder", 1, "craft", 0 },
        [4365] = { "Coarse Dynamite", 1, "craft", 0 },
        [4371] = { "Bronze Tube", 1, "craft", 0 },
        [4375] = { "Whirring Bronze Gizmo", 1, "craft", 0 },
        [4377] = { "Heavy Blasting Powder", 1, "craft", 0 },
        [4382] = { "Bronze Framework", 1, "craft", 0 },
        [4384] = { "Explosive Sheep", 1, "craft", 0 },
        [4404] = { "Silver Contact", 1, "craft", 0 },
        [4406] = { "Standard Scope", 1, "craft", 0 },
        [4470] = { "Simple Wood", 1, "vendor", 34 },
        [4592] = { "Longjaw Mud Snapper", 1, "craft", 18 },
        [4593] = { "Bristle Whisker Catfish", 1, "craft", 470 },
        [4603] = { "Raw Spotted Yellowtail", 1, "other", 0 },
        [4625] = { "Firebloom", 1, "other", 0 },
        [5500] = { "Iridescent Pearl", 2, "other", 0 },
        [5766] = { "Lesser Wizard's Robe", 2, "craft", 0 },
        [5956] = { "Blacksmith Hammer", 1, "vendor", 15 },
        [5961] = { "Dark Leather Pants", 2, "craft", 0 },
        [5964] = { "Barbaric Shoulders", 2, "craft", 0 },
        [5966] = { "Guardian Gloves", 2, "craft", 0 },
        [5997] = { "Elixir of Minor Defense", 1, "craft", 0 },
        [6037] = { "Truesilver Bar", 2, "prof", 0, "Alchemy, Mining" },
        [6040] = { "Golden Scale Bracers", 2, "craft", 0 },
        [6149] = { "Greater Mana Potion", 1, "craft", 0 },
        [6217] = { "Copper Rod", 1, "vendor", 112, "Blacksmithing" },
        [6218] = { "Runed Copper Rod", 1, "craft", 0 },
        [6219] = { "Arclight Spanner", 1, "craft", 0 },
        [6260] = { "Blue Dye", 1, "vendor", 45 },
        [6261] = { "Orange Dye", 1, "vendor", 900 },
        [6289] = { "Raw Longjaw Mud Snapper", 1, "other", 0 },
        [6290] = { "Brilliant Smallfish", 1, "craft", 0 },
        [6291] = { "Raw Brilliant Smallfish", 1, "other", 0 },
        [6308] = { "Raw Bristle Whisker Catfish", 1, "other", 0 },
        [6338] = { "Silver Rod", 1, "prof", 0, "Blacksmithing" },
        [6339] = { "Runed Silver Rod", 1, "craft", 0 },
        [6450] = { "Silk Bandage", 1, "craft", 0 },
        [6451] = { "Heavy Silk Bandage", 1, "craft", 0 },
        [6887] = { "Spotted Yellowtail", 1, "craft", 0 },
        [7026] = { "Linen Belt", 1, "craft", 0 },
        [7048] = { "Azure Silk Hood", 2, "craft", 0 },
        [7051] = { "Earthen Vest", 2, "craft", 0 },
        [7054] = { "Robe of Power", 3, "craft", 0 },
        [7067] = { "Elemental Earth", 1, "other", 0 },
        [7068] = { "Elemental Fire", 1, "prof", 0, "Alchemy" },
        [7069] = { "Elemental Air", 1, "other", 0 },
        [7070] = { "Elemental Water", 1, "other", 0 },
        [7071] = { "Iron Buckle", 1, "craft", 0 },
        [7076] = { "Essence of Earth", 2, "prof", 0, "Alchemy" },
        [7082] = { "Essence of Air", 2, "prof", 0, "Alchemy" },
        [7910] = { "Star Ruby", 2, "other", 0 },
        [7912] = { "Solid Stone", 1, "other", 0 },
        [7919] = { "Heavy Mithril Gauntlet", 2, "craft", 0 },
        [7920] = { "Mithril Plate Pants", 2, "craft", 0 },
        [7930] = { "Heavy Mithril Breastplate", 2, "craft", 0 },
        [7931] = { "Mithril Coif", 2, "craft", 0 },
        [7933] = { "Heavy Mithril Boots", 2, "craft", 0 },
        [7945] = { "Big Black Mace", 2, "craft", 0 },
        [7947] = { "Ebon Shiv", 2, "craft", 0 },
        [7956] = { "Bronze Warhammer", 2, "craft", 0 },
        [7966] = { "Solid Grinding Stone", 1, "craft", 0 },
        [7971] = { "Black Pearl", 2, "other", 0 },
        [8170] = { "Rugged Leather", 1, "gather", 0 },
        [8171] = { "Rugged Hide", 1, "gather", 0 },
        [8173] = { "Thick Armor Kit", 1, "craft", 0 },
        [8193] = { "Nightscape Pants", 2, "craft", 0 },
        [8343] = { "Heavy Silken Thread", 1, "vendor", 1800 },
        [8364] = { "Mithril Head Trout", 1, "craft", 0 },
        [8365] = { "Raw Mithril Head Trout", 1, "other", 0 },
        [8544] = { "Mageweave Bandage", 1, "craft", 0 },
        [8545] = { "Heavy Mageweave Bandage", 1, "craft", 0 },
        [8831] = { "Purple Lotus", 1, "other", 0 },
        [8836] = { "Arthas' Tears", 1, "other", 0 },
        [8838] = { "Sungrass", 1, "other", 0 },
        [8839] = { "Blindweed", 1, "other", 0 },
        [8925] = { "Crystal Vial", 1, "vendor", 2250 },
        [8949] = { "Elixir of Agility", 1, "craft", 0 },
        [9149] = { "Philosopher's Stone", 1, "craft", 0 },
        [9154] = { "Draught of Detect Undead", 1, "craft", 0 },
        [9262] = { "Black Vitriol", 1, "other", 0 },
        [9998] = { "Black Mageweave Vest", 2, "craft", 0 },
        [10003] = { "Black Mageweave Gloves", 2, "craft", 0 },
        [10056] = { "Orange Mageweave Shirt", 1, "craft", 0 },
        [10498] = { "Gyromatic Micro-Adjustor", 1, "craft", 0 },
        [10505] = { "Solid Blasting Powder", 1, "craft", 0 },
        [10559] = { "Mithril Tube", 1, "craft", 0 },
        [10560] = { "Unstable Trigger", 1, "craft", 0 },
        [10561] = { "Mithril Casing", 1, "craft", 0 },
        [10562] = { "Hi-Explosive Bomb", 1, "craft", 0 },
        [10938] = { "Lesser Magic Essence", 2, "other", 0 },
        [10940] = { "Strange Dust", 1, "other", 0 },
        [10998] = { "Lesser Astral Essence", 2, "other", 0 },
        [11082] = { "Greater Astral Essence", 2, "prof", 0 },
        [11083] = { "Soul Dust", 1, "other", 0 },
        [11128] = { "Golden Rod", 1, "prof", 0, "Blacksmithing" },
        [11130] = { "Runed Golden Rod", 1, "craft", 0 },
        [11135] = { "Greater Mystic Essence", 2, "prof", 0 },
        [11137] = { "Vision Dust", 1, "other", 0 },
        [11144] = { "Truesilver Rod", 1, "prof", 0, "Blacksmithing" },
        [11145] = { "Runed Truesilver Rod", 1, "craft", 0 },
        [11176] = { "Dream Dust", 1, "other", 0 },
        [11287] = { "Lesser Magic Wand", 2, "craft", 0 },
        [11288] = { "Greater Magic Wand", 2, "craft", 0 },
        [12359] = { "Thorium Bar", 1, "prof", 0, "Mining" },
        [12360] = { "Arcanite Bar", 2, "prof", 0, "Alchemy" },
        [12365] = { "Dense Stone", 1, "other", 0 },
        [12643] = { "Dense Weightstone", 1, "craft", 0 },
        [12644] = { "Dense Grinding Stone", 1, "craft", 0 },
        [12773] = { "Ornate Thorium Handaxe", 2, "craft", 0 },
        [12799] = { "Large Opal", 2, "other", 0 },
        [12803] = { "Living Essence", 2, "prof", 0, "Alchemy" },
        [13443] = { "Superior Mana Potion", 1, "craft", 0 },
        [13466] = { "Plaguebloom", 1, "other", 0 },
        [13856] = { "Runecloth Belt", 2, "craft", 0 },
        [13860] = { "Runecloth Cloak", 2, "craft", 0 },
        [13864] = { "Runecloth Boots", 2, "craft", 0 },
        [13893] = { "Large Raw Mightfish", 1, "other", 0 },
        [13926] = { "Golden Pearl", 2, "other", 0 },
        [13934] = { "Mightfish Steak", 1, "craft", 0 },
        [14047] = { "Runecloth", 1, "other", 0 },
        [14048] = { "Bolt of Runecloth", 1, "craft", 0 },
        [14227] = { "Ironweb Spider Silk", 1, "other", 0 },
        [14341] = { "Rune Thread", 1, "vendor", 4500 },
        [14343] = { "Small Brilliant Shard", 3, "other", 0 },
        [14344] = { "Large Brilliant Shard", 3, "other", 0 },
        [14529] = { "Runecloth Bandage", 1, "craft", 0 },
        [14530] = { "Heavy Runecloth Bandage", 1, "craft", 0 },
        [15077] = { "Heavy Scorpid Bracers", 2, "craft", 0 },
        [15080] = { "Heavy Scorpid Helm", 2, "craft", 0 },
        [15083] = { "Wicked Leather Gauntlets", 2, "craft", 0 },
        [15407] = { "Cured Rugged Hide", 1, "craft", 0 },
        [15408] = { "Heavy Scorpid Scale", 1, "gather", 0 },
        [15409] = { "Refined Deeprock Salt", 1, "prof", 0 },
        [15869] = { "Silver Skeleton Key", 2, "craft", 0 },
        [15872] = { "Arcanite Skeleton Key", 2, "craft", 0 },
        [15992] = { "Dense Blasting Powder", 1, "craft", 0 },
        [15994] = { "Thorium Widget", 1, "craft", 0 },
        [16000] = { "Thorium Tube", 1, "craft", 0 },
        [16203] = { "Greater Eternal Essence", 2, "prof", 0 },
        [16204] = { "Illusion Dust", 1, "other", 0 },
        [16206] = { "Arcanite Rod", 1, "prof", 0, "Blacksmithing" },
        [16207] = { "Runed Arcanite Rod", 1, "craft", 0 },
        [19047] = { "Wisdom of the Timbermaw", 3, "craft", 0 },
        [20747] = { "Lesser Mana Oil", 1, "craft", 0 },
        [241650] = { "Major Discolored Healing Potion", 1, "craft", 0 },
        [247755] = { "Elixir of Minor Force", 1, "craft", 0 },
        [247786] = { "Mote of Magic", 1, "craft", 9 },
        [249726] = { "Azerothium Bar", 2, "prof", 0, "Mining" },
        [250616] = { "Bold Dirk", 2, "craft", 0 },
        [254123] = { "Runecloth Cuffs", 2, "craft", 0 },
        [275604] = { "Venomspew Gloves", 3, "craft", 0 },
        [275605] = { "Venomspew Cord", 3, "craft", 0 },
        [275606] = { "Venomspew Footpads", 3, "craft", 0 },
        [281665] = { "Twilight Forgehammer", 3, "other", 0 },
        [282550] = { "Combat Tuning Wrench", 2, "other", 0 },
        [285280] = { "Mithril Blacksmith Hammer", 2, "craft", 0 },
        [285281] = { "Arcanite Blacksmith Hammer", 3, "craft", 0 },
    },
    vendors = {
        [66] = { "Tharynn Bouden", "A", "Elwynn Forest" },
        [1684] = { "Khara Deepwater", "A", "Loch Modan" },
        [2383] = { "Lindea Rabonne", "A", "Hillsbrad Foothills" },
        [2397] = { "Derak Nightfall", "H", "Hillsbrad Foothills" },
        [2664] = { "Kelsey Yance", "N", "Stranglethorn Vale" },
        [2699] = { "Rikqiz", "N", "Stranglethorn Vale" },
        [2805] = { "Deneb Walker", "A", "Arathi Highlands" },
        [3027] = { "Naal Mistrunner", "H", "Thunder Bluff" },
        [3029] = { "Sewa Mistrunner", "H", "Thunder Bluff" },
        [3178] = { "Stuart Fleming", "A", "Wetlands" },
        [3333] = { "Shankys", "H", "Orgrimmar" },
        [3413] = { "Sovik", "H", "Orgrimmar" },
        [3497] = { "Kilxx", "N", "The Barrens" },
        [3550] = { "Martine Tramblay", "H", "Tirisfal Glades" },
        [3954] = { "Dalria", "A", "Ashenvale" },
        [4226] = { "Ulthir", "A", "Darnassus" },
        [4229] = { "Mythrin'dir", "A", "Darnassus" },
        [4265] = { "Nyoma", "A", "Teldrassil" },
        [4307] = { "Heldan Galesong", "A", "Darkshore" },
        [4553] = { "Ronald Burch", "H", "Undercity" },
        [4561] = { "Daniel Bartlett", "H", "Undercity" },
        [4574] = { "Lizbeth Cromwell", "H", "Undercity" },
        [4610] = { "Algernon", "H", "Undercity" },
        [5162] = { "Tansy Puddlefizz", "A", "Ironforge" },
        [5175] = { "Gearcutter Cogspinner", "A", "Ironforge" },
        [5494] = { "Catherine Leland", "A", "Stormwind City" },
        [5594] = { "Alchemist Pestlezugg", "N", "Tanaris" },
        [5748] = { "Killian Sanatha", "H", "Silverpine Forest" },
        [5940] = { "Harn Longcast", "H", "Mulgore" },
        [7940] = { "Darnall", "N", "Moonglade" },
        [7947] = { "Vivianna", "A", "Feralas" },
        [8137] = { "Gikkix", "N", "Tanaris" },
        [8145] = { "Sheendra Tallgrass", "H", "Feralas" },
        [8508] = { "Gretta Ganter", "A", "Dun Morogh" },
        [11185] = { "Xizzer Fizzbolt", "N", "Winterspring" },
        [11278] = { "Magnus Frostwake", "N", "Western Plaguelands" },
        [11557] = { "Meilosh", "N", "Felwood" },
        [12022] = { "Lorelae Wintersong", "N", "Moonglade" },
        [12033] = { "Wulan", "H", "Desolace" },
        [12043] = { "Kulwia", "H", "Stonetalon Mountains" },
        [12245] = { "Vendor-Tron 1000", "N", "Desolace" },
        [12942] = { "Leonard Porter", "A", "Western Plaguelands" },
        [12943] = { "Werg Thickblade", "H", "Tirisfal Glades" },
        [12944] = { "Lokhtos Darkbargainer", "N", "Blackrock Depths" },
        [12956] = { "Zannok Hidepiercer", "N", "Silithus" },
        [12962] = { "Wik'Tar", "H", "Ashenvale" },
        [13476] = { "Balai Lok'Wein", "H", "Dustwallow Marsh" },
        [15179] = { "Mishta", "N", "Silithus" },
        [15419] = { "Kania", "N", "Silithus" },
        [260487] = { "Gritta Chumwater", "N", "Riverglades" },
        [260565] = { "Kor'gar", "N", "Riverglades" },
        [266901] = { "Pexmit", "N", "Mount Hyjal" },
    },
    tools = {
        c162 = { "Blacksmith Hammer", { 5956, 285280, 281665, 285281 } },
        c373 = { "Runed Copper Rod", { 6218 } },
        c374 = { "Runed Silver Rod", { 6339 } },
        c375 = { "Runed Golden Rod", { 11130 } },
        c376 = { "Runed Truesilver Rod", { 11145 } },
        c14 = { "Arclight Spanner", { 6219, 282550 } },
    },
}
