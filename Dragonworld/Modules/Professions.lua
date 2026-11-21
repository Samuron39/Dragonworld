-- Dragonworld - Professions
-- En guide til raskeste vei opp i en profession (1-300), med det du fortsatt
-- trenger:
--   * Veien videre: stegene igjen fra der du er nå, hvilken oppskrift du lager,
--     hvor mange ganger, og hva det koster i materialer. Ferdige steg vises ikke.
--   * Handleliste: alt du må skaffe for resten av veien, minus det du allerede
--     har i baggene og i banken, så du ikke kjøper mer enn du trenger.
--     Mellomprodukter (bolts, powder, grinding stones ...) som du lager selv
--     underveis står for seg, og materialene til dem er regnet med.
--
-- Ruten er Wowhead sin "Tried & Tested in Forever" (se ProfessionData.lua, som
-- lages av tools\make_profession_data.js). Hvor mange crafts et steg tar regnes
-- ut fra fargen oppskriften har på din skill, med samme modell som Wowhead:
-- oransje gir alltid et poeng, fra gul synker sjansen jevnt til null ved grå.
--
-- Skill leses fra spillet (GetProfessions). Baggene leses når de endrer seg,
-- banken mens den er åpen (og huskes til neste gang). Alt lagres per karakter
-- for hele kontoen, så andre karakterer kan regnes med hvis du vil.
--
-- All tekst ligger i Locales.lua (navnene som begynner med PROF_).

local ADDON_NAME, DW = ...
local L = DW.L
local DATA = DW.ProfessionData

local MODULE_ID = "professions"
local MAX_SKILL = 300
local SAFE_Z = 1.2816 -- 9 av 10 har nok (normalfordeling)
local LAST_BAG = NUM_TOTAL_EQUIPPED_BAG_SLOTS or NUM_BAG_SLOTS or 4
local GetItemInfo = (C_Item and C_Item.GetItemInfo) or GetItemInfo
local FALLBACK_ICON = 134400 -- spørsmålstegn
local CHECK_ICON = "|TInterface\\RaidFrame\\ReadyCheck-Ready:14|t"

-- Lagrede data. Settes i OnLoad nederst.
--   db.characters["Navn-Realm"] = {
--       name, class,
--       bags = { [itemID] = antall }, bank = { [itemID] = antall }, bankTime,
--       known = { [oppskrift] = true },   oppskrifter vi har sett at du kan
--       selected = skillLine,              professionen som var valgt sist
--       targets = { [skillLine] = mål },   valgt mål per profession
--   }
--   db.safe = true   regn litt ekstra (9 av 10 har nok)
--   db.alts = true   regn med det de andre karakterene har
local db = { characters = {} }

local function Number(value)
    if type(value) == "number" and not DW.IsSecret(value) then
        return value
    end
    return nil
end

local function Text(value)
    if type(value) == "string" and not DW.IsSecret(value) then
        return value
    end
    return ""
end

-- Professions og oppskrifter --------------------------------------------------------

local NAME_TO_LINE = {}
for line, profession in pairs(DATA.professions) do
    NAME_TO_LINE[profession.name:lower()] = line
end

-- Professionene i fast rekkefølge: crafting først, så Cooking og First Aid.
local ORDERED_LINES = {}
for line in pairs(DATA.professions) do
    ORDERED_LINES[#ORDERED_LINES + 1] = line
end
table.sort(ORDERED_LINES, function(a, b)
    local pa, pb = DATA.professions[a], DATA.professions[b]
    if pa.secondary ~= pb.secondary then
        return not pa.secondary
    end
    return pa.name < pb.name
end)

local waitingForItem = {}

local function RequestItem(itemID)
    if not waitingForItem[itemID] and C_Item and C_Item.RequestLoadItemDataByID then
        waitingForItem[itemID] = true
        pcall(C_Item.RequestLoadItemDataByID, itemID)
    end
end

-- Navn og kvalitet fra spillet (på spillets språk), ellers fra dataene.
local function ItemName(itemID)
    local name, _, quality = GetItemInfo(itemID)
    if type(name) == "string" and not DW.IsSecret(name) and name ~= "" then
        return name, quality
    end
    RequestItem(itemID)
    local known = DATA.items[itemID]
    if known then
        return known[1], known[2]
    end
    return "item:" .. itemID, 1
end

local function ItemLink(itemID)
    local _, link = GetItemInfo(itemID)
    if type(link) == "string" and not DW.IsSecret(link) then
        return link
    end
    return nil
end

local function ItemIcon(itemID)
    local _, _, _, _, icon = C_Item.GetItemInfoInstant(itemID)
    return icon or FALLBACK_ICON
end

local function Coloured(text, quality)
    local colour = ITEM_QUALITY_COLORS and quality and ITEM_QUALITY_COLORS[quality]
    if colour and colour.hex then
        return colour.hex .. text .. "|r"
    elseif colour and colour.r then
        return ("|cff%02x%02x%02x%s|r"):format(colour.r * 255, colour.g * 255, colour.b * 255, text)
    end
    return text
end

local function RecipeName(recipeID)
    if C_Spell and C_Spell.GetSpellName then
        local ok, name = pcall(C_Spell.GetSpellName, recipeID)
        if ok and Text(name) ~= "" then
            return name
        end
    end
    local recipe = DATA.recipes[recipeID]
    return recipe and recipe[1] or tostring(recipeID)
end

local function RecipeIcon(recipeID, fallback)
    local recipe = DATA.recipes[recipeID]
    if recipe and recipe.creates then
        local _, _, _, _, icon = C_Item.GetItemInfoInstant(recipe.creates)
        if icon then
            return icon
        end
    end
    if C_Spell and C_Spell.GetSpellTexture then
        local ok, icon = pcall(C_Spell.GetSpellTexture, recipeID)
        if ok and icon and not DW.IsSecret(icon) then
            return icon
        end
    end
    return fallback or FALLBACK_ICON
end

local function Money(copper)
    if type(copper) ~= "number" or copper <= 0 then
        return ""
    end
    if GetCoinTextureString then
        local ok, text = pcall(GetCoinTextureString, copper)
        if ok and type(text) == "string" then
            return text
        end
    end
    local gold, silver, rest = math.floor(copper / 10000), math.floor(copper / 100) % 100, copper % 100
    local parts = {}
    if gold > 0 then parts[#parts + 1] = gold .. "g" end
    if silver > 0 then parts[#parts + 1] = silver .. "s" end
    if rest > 0 then parts[#parts + 1] = rest .. "c" end
    return table.concat(parts, " ")
end

local function CurrencyName(id)
    if C_CurrencyInfo and C_CurrencyInfo.GetCurrencyInfo then
        local ok, info = pcall(C_CurrencyInfo.GetCurrencyInfo, id)
        if ok and type(info) == "table" and Text(info.name) ~= "" then
            return info.name
        end
    end
    return "currency " .. id
end

-- "A" for Alliance, "H" for Horde, nil hvis ukjent.
local function MySide()
    local faction = UnitFactionGroup and UnitFactionGroup("player")
    if faction == "Alliance" then
        return "A"
    elseif faction == "Horde" then
        return "H"
    end
    return nil
end

-- Vendorene som selger oppskriften, de for din side først. Hver er
-- { name, zone, price (tekst), limited }.
local function RecipeVendors(recipe)
    local list, side = {}, MySide()
    for _, entry in ipairs(recipe.vendors or {}) do
        local info = DATA.vendors[entry[1]]
        if info and (not side or info[2] == "N" or info[2] == side) then
            local price = Money(entry[2])
            if entry[3] and entry[3] > 0 then
                price = ((price ~= "" and price .. " + ") or "") .. entry[4] .. " " .. CurrencyName(entry[3])
            end
            list[#list + 1] = { name = info[1], zone = info[3], price = price, limited = entry[5] == 1 }
        end
    end
    return list
end

-- Lagring per karakter ---------------------------------------------------------------

local function CurrentCharacter()
    local key, name = DW.CharacterKey()
    if not key then
        return nil
    end
    local character = db.characters[key]
    if type(character) ~= "table" then
        character = {}
        db.characters[key] = character
    end
    character.name = name
    character.class = select(2, UnitClass("player"))
    for _, field in ipairs({ "bags", "bank", "known", "targets" }) do
        if type(character[field]) ~= "table" then
            character[field] = {}
        end
    end
    return character, key
end

-- Bagger og bank ----------------------------------------------------------------------

local TRACKED = {}
for itemID in pairs(DATA.items) do
    TRACKED[itemID] = true
end

local BAG_CONTAINERS = {}
for bag = 0, LAST_BAG do
    BAG_CONTAINERS[#BAG_CONTAINERS + 1] = bag
end

-- Bankens plasser. I Forever er det 6-14: selve banken og bagene i den.
local function BankContainers()
    local list = {}
    if Enum and Enum.BagIndex then
        for name, index in pairs(Enum.BagIndex) do
            if type(name) == "string" and type(index) == "number" and name:match("^CharacterBankTab_%d+$") then
                list[#list + 1] = index
            end
        end
    end
    if #list == 0 then
        for index = 6, 14 do
            list[#list + 1] = index
        end
    end
    table.sort(list)
    return list
end

-- Teller gjenstandene ruten bruker. Gir også hvor mange plasser som fantes,
-- så vi ser forskjell på "tomt" og "ikke tilgjengelig".
local function CountTracked(containers)
    local counts, slots = {}, 0
    for _, bag in ipairs(containers) do
        local size = Number(C_Container.GetContainerNumSlots(bag)) or 0
        slots = slots + size
        for slot = 1, size do
            local itemID = Number(C_Container.GetContainerItemID(bag, slot))
            if itemID and TRACKED[itemID] then
                local info = C_Container.GetContainerItemInfo and C_Container.GetContainerItemInfo(bag, slot)
                local count = (type(info) == "table" and Number(info.stackCount)) or 1
                counts[itemID] = (counts[itemID] or 0) + count
            end
        end
    end
    return counts, slots
end

local bankOpen = false
local version = 0 -- økes hver gang noe endrer seg, så utregninger kan huskes

local function Scan()
    local character = CurrentCharacter()
    if not character then
        return
    end
    character.bags = CountTracked(BAG_CONTAINERS)
    if bankOpen then
        local counts, slots = CountTracked(BankContainers())
        -- Fant vi ingen bankplasser, er banken ikke lesbar akkurat nå. Da
        -- beholder vi det vi husket, i stedet for å tro at den er tom.
        if slots > 0 then
            character.bank = counts
            character.bankTime = time()
        end
    end
    version = version + 1
end

-- Hva du har: din egen karakter, og de andre hvis det er valgt.
-- Gir owned[itemID] = antall, og mine = { bags = {}, bank = {} } for denne karakteren.
local function Owned()
    local owned = {}
    local me, myKey = CurrentCharacter()
    for key, character in pairs(db.characters) do
        if type(character) == "table" and (key == myKey or db.alts) then
            for _, where in ipairs({ "bags", "bank" }) do
                if type(character[where]) == "table" then
                    for itemID, count in pairs(character[where]) do
                        if type(itemID) == "number" and type(count) == "number" then
                            owned[itemID] = (owned[itemID] or 0) + count
                        end
                    end
                end
            end
        end
    end
    return owned, me or { bags = {}, bank = {} }, myKey
end

-- Dine professions -----------------------------------------------------------------

-- Gir mine[skillLine] = { level, max, icon } for professionene ruten har.
-- Leser karakterens egen liste, og håndverkssystemet hvis listen mangler noe.
local function ReadMyProfessions()
    local mine = {}
    local function Add(line, level, max, icon)
        line, level, max = Number(line), Number(level), Number(max)
        if not (line and DATA.professions[line] and level) then
            return
        end
        if mine[line] and mine[line].level >= level then
            return
        end
        mine[line] = { level = level, max = max or level, icon = icon }
    end

    if GetProfessions and GetProfessionInfo then
        local results = { pcall(GetProfessions) }
        if results[1] then
            for position, index in pairs(results) do
                if position > 1 and Number(index) then
                    local ok, name, icon, level, max, _, _, line = pcall(GetProfessionInfo, index)
                    if ok then
                        if not (Number(line) and DATA.professions[line]) then
                            line = NAME_TO_LINE[Text(name):lower()]
                        end
                        Add(line, level, max, (not DW.IsSecret(icon)) and icon or nil)
                    end
                end
            end
        end
    end

    if C_TradeSkillUI and C_TradeSkillUI.GetProfessionInfoBySkillLineID then
        for line in pairs(DATA.professions) do
            if not mine[line] then
                local ok, info = pcall(C_TradeSkillUI.GetProfessionInfoBySkillLineID, line)
                if ok and type(info) == "table" and (Number(info.skillLevel) or 0) > 0 then
                    Add(line, info.skillLevel, info.maxSkillLevel)
                end
            end
        end
    end
    return mine
end

-- Husker hvilke av ruteoppskriftene du kan, når ditt eget håndverksvindu er
-- åpent. (En annens profession du har åpnet fra Medlemmer teller ikke.)
local function LearnKnownRecipes()
    local ui = C_TradeSkillUI
    if not (ui and ui.GetAllRecipeIDs and ui.GetRecipeInfo) then
        return false
    end
    if ui.IsTradeSkillLinked then
        local ok, linked = pcall(ui.IsTradeSkillLinked)
        if ok and linked then
            return false
        end
    end
    if ui.GetTradeSkillListLink then
        local ok, link = pcall(ui.GetTradeSkillListLink)
        local owner = ok and type(link) == "string" and not DW.IsSecret(link) and link:match("|Htrade:([^:|]+)")
        if owner and owner ~= DW.MyGUID() then
            return false
        end
    end
    local character = CurrentCharacter()
    local ok, recipes = pcall(ui.GetAllRecipeIDs)
    if not (character and ok and type(recipes) == "table") then
        return false
    end
    local learned = false
    for _, recipeID in ipairs(recipes) do
        if DATA.recipes[recipeID] and not character.known[recipeID] then
            local fine, info = pcall(ui.GetRecipeInfo, recipeID)
            if fine and type(info) == "table" and info.learned == true then
                character.known[recipeID] = true
                learned = true
            end
        end
    end
    return learned
end

local function KnowsRecipe(recipeID)
    local character = CurrentCharacter()
    if character and character.known[recipeID] then
        return true
    end
    if IsPlayerSpell then
        local ok, known = pcall(IsPlayerSpell, recipeID)
        if ok and known == true then
            return true
        end
    end
    return false
end

-- Utregning ---------------------------------------------------------------------------

-- Sjansen for et skillpoeng når du har skill `skill`, med oppskriftens farger
-- { oransje, gul, grønn, grå }: alltid før gul, så jevnt ned til null ved grå.
local function Chance(colors, skill)
    local yellow, grey = colors[2], colors[4]
    if skill < yellow then
        return 1
    end
    if skill >= grey then
        return 0
    end
    return (grey - skill) / (grey - yellow)
end

-- Hvor mange crafts det tar å gå fra `from` til `to` med oppskriften. Med safe
-- regnes det slik at 9 av 10 rekker det, ellers gjennomsnittet.
local function StepCrafts(recipe, from, to, safe)
    local mean, variance, points = 0, 0, 0
    local up = recipe.up or 1
    local skill = from
    while skill < to do
        local p = math.max(Chance(recipe[3], skill), 0.05) -- grå skal ikke forekomme i ruten
        mean = mean + 1 / p
        variance = variance + (1 - p) / (p * p)
        points = points + 1
        skill = skill + up
    end
    local crafts
    if safe then
        crafts = math.ceil(mean + SAFE_Z * math.sqrt(variance) - 1e-6)
    else
        crafts = math.floor(mean + 0.5)
    end
    return math.max(points, crafts)
end
DW.ProfessionStepCrafts = StepCrafts -- for testene

-- Rekkefølgen målene kan velges i.
local function TargetChoices(skill)
    local list = {}
    for _, cap in ipairs({ 75, 150, 225, MAX_SKILL }) do
        if cap > skill then
            list[#list + 1] = cap
        end
    end
    return list
end

-- Lager hele planen for en profession fra skill `skill` opp til `target`:
--   plan.rows  stegene (kind "step") og rank-kravene (kind "gate") i rekkefølge
--   plan.shop  det du må skaffe, i den rekkefølgen ruten trenger det:
--              { itemID, need, have, missing, row }
--   plan.make  mellomprodukter du lager selv: { itemID, crafts, count, have, used }
--   plan.tools verktøy: { key, name, items, bags, bank, madeIn }
--   plan.crafts  crafts i alt
local function BuildPlan(line, skill, max, target, owned, safe)
    local profession = DATA.professions[line]
    local plan = { line = line, skill = skill, max = max, target = target, rows = {}, shop = {}, make = {}, tools = {}, crafts = 0 }

    local produced = {} -- laget i tidligere steg, kan brukes i senere
    local left = {}     -- det du har som ikke er brukt opp ennå
    for itemID, count in pairs(owned) do
        left[itemID] = count
    end
    local used, missing, extra, firstRow, order = {}, {}, {}, {}, {}
    local createdIn = {} -- [itemID] = raden som lager den

    local function Need(itemID, count, row, depth)
        if count <= 0 then
            return
        end
        if not firstRow[itemID] then
            firstRow[itemID] = row
            order[#order + 1] = itemID
        end
        local take = math.min(produced[itemID] or 0, count)
        produced[itemID] = (produced[itemID] or 0) - take
        count = count - take
        take = math.min(left[itemID] or 0, count)
        left[itemID] = (left[itemID] or 0) - take
        used[itemID] = (used[itemID] or 0) + take
        count = count - take
        if count <= 0 then
            return
        end
        local makerID = profession.makes[itemID]
        local maker = makerID and DATA.recipes[makerID]
        if maker and depth < 6 then
            local per = maker.makes or 1
            local crafts = math.ceil(count / per - 1e-6)
            extra[itemID] = (extra[itemID] or 0) + crafts
            produced[itemID] = (produced[itemID] or 0) + crafts * per - count
            for _, reagent in ipairs(maker[4]) do
                Need(reagent[1], reagent[2] * crafts, row, depth + 1)
            end
        else
            missing[itemID] = (missing[itemID] or 0) + count
        end
    end

    local toolSeen = {}
    local gateIndex = 1
    for _, step in ipairs(profession.steps) do
        local from, to = math.max(step[1], skill), math.min(step[2], target)
        if from < to then
            -- Rank-krav som må læres før dette steget kan fullføres.
            while profession.gates[gateIndex] and profession.gates[gateIndex][1] < to do
                local gate = profession.gates[gateIndex]
                if max <= gate[1] and gate[1] < target then
                    plan.rows[#plan.rows + 1] = { kind = "gate", rank = gateIndex, before = gate[1],
                        needSkill = gate[2], needLevel = gate[3], how = gate[4] }
                end
                gateIndex = gateIndex + 1
            end

            local recipeID = step[3]
            local recipe = recipeID ~= 0 and DATA.recipes[recipeID] or nil
            local row = { kind = "step", from = from, to = to, recipeID = recipeID, recipe = recipe,
                note = step.note, mats = {}, current = not plan.hasStep or nil }
            plan.hasStep = true
            local index = #plan.rows + 1
            plan.rows[index] = row
            if recipe then
                row.crafts = StepCrafts(recipe, from, to, safe)
                for _, reagent in ipairs(recipe[4]) do
                    row.mats[#row.mats + 1] = { reagent[1], reagent[2] * row.crafts, reagent[2] }
                    Need(reagent[1], reagent[2] * row.crafts, index, 0)
                end
                for _, key in ipairs(recipe.tools or {}) do
                    if not toolSeen[key] and DATA.tools[key] then
                        toolSeen[key] = true
                        local tool = DATA.tools[key]
                        local entry = { key = key, name = tool[1], items = tool[2], row = index, bags = 0, bank = 0 }
                        for _, itemID in ipairs(tool[2]) do
                            entry.madeIn = entry.madeIn or createdIn[itemID]
                        end
                        plan.tools[#plan.tools + 1] = entry
                    end
                end
                if recipe.creates then
                    produced[recipe.creates] = (produced[recipe.creates] or 0) + row.crafts * (recipe.makes or 1)
                    createdIn[recipe.creates] = createdIn[recipe.creates] or index
                end
            else
                row.crafts = to - from -- tekststeg (disenchant): ett poeng hver gang
            end
            plan.crafts = plan.crafts + row.crafts
        end
    end
    for _, itemID in ipairs(order) do
        if profession.makes[itemID] then
            local crafts = extra[itemID] or 0
            if crafts > 0 or (used[itemID] or 0) > 0 then
                local maker = DATA.recipes[profession.makes[itemID]]
                plan.make[#plan.make + 1] = { itemID = itemID, recipeID = profession.makes[itemID], crafts = crafts,
                    count = crafts * ((maker and maker.makes) or 1), have = owned[itemID] or 0, used = used[itemID] or 0, row = firstRow[itemID] }
            end
        else
            local need = (used[itemID] or 0) + (missing[itemID] or 0)
            if need > 0 then
                plan.shop[#plan.shop + 1] = { itemID = itemID, need = need, have = owned[itemID] or 0,
                    missing = missing[itemID] or 0, row = firstRow[itemID] }
            end
        end
    end
    return plan
end
DW.ProfessionBuildPlan = BuildPlan -- for testene

-- Valgt mål og profession ----------------------------------------------------------

local function TargetFor(line, skill)
    local character = CurrentCharacter()
    local target = character and Number(character.targets[line])
    if not target or target <= skill then
        target = MAX_SKILL
    end
    return target
end

-- Planene for dine egne professions, til tooltipen. Regnes på nytt bare når
-- noe har endret seg.
local tooltipPlans, tooltipVersion

local function MyPlans()
    if tooltipPlans and tooltipVersion == version then
        return tooltipPlans
    end
    tooltipPlans, tooltipVersion = {}, version
    local owned = Owned()
    for line, info in pairs(ReadMyProfessions()) do
        if info.level < MAX_SKILL then
            tooltipPlans[line] = BuildPlan(line, info.level, info.max, TargetFor(line, info.level), owned, db.safe)
        end
    end
    return tooltipPlans
end

-- Tooltip: hvor mange flere av en gjenstand du trenger, når du ser på den
-- (f.eks. i auksjonshuset).
local shownItem = {}

local function OnTooltipItem(tooltip, data)
    if not DW.IsMember() or (tooltip ~= GameTooltip and tooltip ~= ItemRefTooltip) then
        return
    end
    local itemID = data and data.id
    if type(itemID) ~= "number" or DW.IsSecret(itemID) or not TRACKED[itemID] or shownItem[tooltip] == itemID then
        return
    end
    local ok, plans = pcall(MyPlans)
    if not ok then
        return
    end
    for _, line in ipairs(ORDERED_LINES) do
        local plan = plans[line]
        for _, entry in ipairs(plan and plan.shop or {}) do
            if entry.itemID == itemID and entry.missing > 0 then
                shownItem[tooltip] = itemID
                tooltip:AddLine(L.PROF_TIP_ITEM:format(DATA.professions[line].name, entry.missing, entry.have), 1.00, 0.82, 0.00)
            end
        end
    end
end

for _, tooltip in ipairs({ GameTooltip, ItemRefTooltip }) do
    if tooltip and tooltip.HookScript then
        local function Forget(self)
            shownItem[self] = nil
        end
        pcall(tooltip.HookScript, tooltip, "OnTooltipCleared", Forget)
        pcall(tooltip.HookScript, tooltip, "OnHide", Forget)
    end
end

if TooltipDataProcessor and TooltipDataProcessor.AddTooltipPostCall and Enum and Enum.TooltipDataType then
    TooltipDataProcessor.AddTooltipPostCall(Enum.TooltipDataType.Item, OnTooltipItem)
end

-- Visning ---------------------------------------------------------------------------

local ROUTE_ROW, GATE_ROW, SHOP_ROW = 38, 24, 24
local DIFFICULTY = {
    { 1.00, 0.50, 0.25 }, -- oransje
    { 1.00, 1.00, 0.00 }, -- gul
    { 0.25, 0.75, 0.25 }, -- grønn
    { 0.50, 0.50, 0.50 }, -- grå
}

local panel
local rows = {}
local RefreshPanel
local view = "route" -- "route" eller "shop"
local selectedLine   -- professionen som vises
local currentPlan    -- siste plan som ble vist

local function RankName(index)
    return L["PROF_RANK_" .. index]
end

local function GateText(gate)
    local how = gate.how == "book" and L.PROF_GATE_BOOK or gate.how == "quest" and L.PROF_GATE_QUEST or L.PROF_GATE_TRAINER
    local needs = {}
    if (gate.needSkill or 0) > 0 then
        needs[#needs + 1] = L.PROF_GATE_SKILL:format(gate.needSkill)
    end
    if (gate.needLevel or 0) > 0 then
        needs[#needs + 1] = L.PROF_GATE_LEVEL:format(gate.needLevel)
    end
    local text = L.PROF_GATE:format(RankName(gate.rank), gate.before) .. " " .. how
    if #needs > 0 then
        text = text .. " - " .. L.PROF_GATE_NEEDS:format(table.concat(needs, ", "))
    end
    return text
end

-- Kan du lære ranken nå (skill og level holder)?
local function GateReady(gate, skill)
    local level = Number(UnitLevel and UnitLevel("player")) or 0
    return skill >= (gate.needSkill or 0) and level >= (gate.needLevel or 0)
end

local function NoteText(note)
    if not note then
        return nil
    end
    if note:match("^PROF_NOTE_") then
        return L[note]
    end
    return note
end

-- Kort tekst om hvor du får oppskriften.
local function SourceText(recipeID, recipe)
    if KnowsRecipe(recipeID) then
        return "|cff40ff40" .. L.PROF_SRC_KNOWN .. "|r"
    elseif recipe.starter then
        return L.PROF_SRC_STARTER
    elseif recipe.trainer then
        return L.PROF_SRC_TRAINER
    elseif recipe.vendors then
        local vendors = RecipeVendors(recipe)
        return vendors[1] and (L.PROF_SRC_VENDOR .. ": " .. vendors[1].name) or L.PROF_SRC_VENDOR
    elseif recipe.drop then
        return L.PROF_SRC_DROP
    elseif recipe.quest then
        return L.PROF_SRC_QUEST
    end
    return ""
end

local function CraftsText(row)
    if not row.recipe then
        return L.PROF_DISENCHANTS:format(row.crafts)
    end
    return row.crafts == 1 and L.PROF_CRAFT_ONE or L.PROF_CRAFTS:format(row.crafts)
end

local function InsertLink(link)
    if link and ChatEdit_InsertLink then
        pcall(ChatEdit_InsertLink, link)
    end
end

-- Tooltip for et steg i ruten.
local function ShowStepTooltip(owner, row)
    GameTooltip:SetOwner(owner, "ANCHOR_RIGHT")
    local owned = Owned()
    if not row.recipe then
        GameTooltip:AddLine(("%d - %d"):format(row.from, row.to), 1, 0.82, 0)
        GameTooltip:AddLine(NoteText(row.note) or "", 1, 1, 1, true)
        GameTooltip:Show()
        return
    end
    local recipe = row.recipe
    GameTooltip:AddLine(RecipeName(row.recipeID), 1, 0.82, 0)
    GameTooltip:AddLine(("%d - %d: %s"):format(row.from, row.to, CraftsText(row)), 1, 1, 1)
    local c = recipe[3]
    GameTooltip:AddLine(L.PROF_TIP_COLORS:format(c[2], c[3], c[4], c[4]), 0.75, 0.75, 0.75, true)
    if recipe.creates then
        local name, quality = ItemName(recipe.creates)
        local made = (recipe.makes or 1) ~= 1 and (" x" .. recipe.makes) or ""
        GameTooltip:AddLine(L.PROF_TIP_CREATES:format(Coloured(name, quality) .. made), 1, 1, 1)
    end

    GameTooltip:AddLine(" ")
    for _, mat in ipairs(row.mats) do
        local name, quality = ItemName(mat[1])
        GameTooltip:AddLine(L.PROF_TIP_MAT:format(mat[3], Coloured(name, quality), mat[2], owned[mat[1]] or 0), 1, 1, 1)
    end
    local extras = {}
    if recipe.tools then
        local names = {}
        for _, key in ipairs(recipe.tools) do
            names[#names + 1] = DATA.tools[key] and DATA.tools[key][1] or key
        end
        extras[#extras + 1] = L.PROF_TIP_TOOLS:format(table.concat(names, ", "))
    end
    if recipe.focus then
        extras[#extras + 1] = L.PROF_TIP_FOCUS:format(recipe.focus)
    end
    for _, text in ipairs(extras) do
        GameTooltip:AddLine(text, 0.75, 0.75, 0.75)
    end

    GameTooltip:AddLine(" ")
    if KnowsRecipe(row.recipeID) then
        GameTooltip:AddLine(L.PROF_SRC_KNOWN, 0.25, 1, 0.25)
    end
    if recipe.starter then
        GameTooltip:AddLine(L.PROF_SRC_STARTER, 1, 1, 1)
    end
    if recipe.trainer then
        local cost = Money(recipe.cost)
        GameTooltip:AddLine(L.PROF_SRC_TRAINER .. (cost ~= "" and (": " .. cost) or ""), 1, 1, 1)
    end
    for _, vendor in ipairs(RecipeVendors(recipe)) do
        local text = L.PROF_TIP_VENDOR:format(vendor.name, vendor.zone)
        if vendor.price ~= "" then
            text = text .. ": " .. vendor.price
        end
        if vendor.limited then
            text = text .. " (" .. L.PROF_TIP_LIMITED .. ")"
        end
        GameTooltip:AddLine(text, 1, 1, 1, true)
    end
    if recipe.drop then
        GameTooltip:AddLine(L.PROF_TIP_DROP, 1, 1, 1, true)
    end
    if recipe.quest and not recipe.vendors then
        GameTooltip:AddLine(L.PROF_TIP_QUEST, 1, 1, 1, true)
    end
    if recipe.rep then
        GameTooltip:AddLine(L.PROF_TIP_REP:format(recipe.rep[2], recipe.rep[1]), 1, 0.5, 0.25, true)
    end
    if recipe.spec then
        GameTooltip:AddLine(L.PROF_TIP_SPEC:format(recipe.spec), 1, 0.5, 0.25, true)
    end
    local note = NoteText(row.note)
    if note then
        GameTooltip:AddLine(" ")
        GameTooltip:AddLine(note, 1, 0.82, 0, true)
    end
    if recipe.creates then
        GameTooltip:AddLine(L.PROF_TIP_SHIFT, 0.5, 0.5, 0.5)
    end
    GameTooltip:Show()
end

local function KindText(itemID)
    local info = DATA.items[itemID]
    if not info then
        return ""
    end
    local kind, price = info[3], info[4]
    if kind == "vendor" or (price or 0) > 0 then
        local money = Money(price)
        return L.PROF_KIND_VENDOR .. (money ~= "" and (" (" .. money .. ")") or "")
    elseif kind == "prof" then
        return L.PROF_KIND_PROF:format(info[5] or "?")
    elseif kind == "gather" then
        return L.PROF_KIND_GATHER
    elseif kind == "craft" then
        return L.PROF_KIND_CRAFT
    end
    return L.PROF_KIND_OTHER
end

-- Tooltip for en gjenstand i handlelisten: gjenstanden selv, hvor den kommer
-- fra, og hvor mye som ligger hvor.
local function ShowItemTooltip(owner, entry)
    GameTooltip:SetOwner(owner, "ANCHOR_RIGHT")
    if GameTooltip.SetItemByID then
        GameTooltip:SetItemByID(entry.itemID)
    else
        GameTooltip:AddLine(ItemName(entry.itemID))
    end
    GameTooltip:AddLine(" ")
    GameTooltip:AddLine(KindText(entry.itemID), 0.75, 0.75, 0.75)
    local keys = {}
    for key in pairs(db.characters) do
        keys[#keys + 1] = key
    end
    table.sort(keys)
    for _, key in ipairs(keys) do
        local character = db.characters[key]
        local inBags = type(character.bags) == "table" and character.bags[entry.itemID] or 0
        local inBank = type(character.bank) == "table" and character.bank[entry.itemID] or 0
        if inBags + inBank > 0 then
            GameTooltip:AddLine(L.MAT_TOOLTIP_LINE:format(character.name or key, inBags, inBank), 0.75, 0.75, 0.75)
        end
    end
    GameTooltip:AddLine(L.PROF_TIP_SHIFT, 0.5, 0.5, 0.5)
    GameTooltip:Show()
end

local function GetRow(index)
    local row = rows[index]
    if row then
        return row
    end
    row = CreateFrame("Button", nil, panel.content)
    row:SetWidth(panel.content:GetWidth())
    row:EnableMouse(true)
    row:RegisterForClicks("LeftButtonUp")

    row.bg = row:CreateTexture(nil, "BACKGROUND")
    row.bg:SetAllPoints(row)
    row.bg:SetColorTexture(0, 0, 0, 0)

    row.range = row:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    row.range:SetPoint("TOPLEFT", 4, -4)
    row.range:SetWidth(70)
    row.range:SetJustifyH("LEFT")

    row.icon = row:CreateTexture(nil, "ARTWORK")
    row.icon:SetSize(20, 20)
    row.icon:SetTexCoord(0.07, 0.93, 0.07, 0.93)

    row.right = row:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
    row.right:SetJustifyH("RIGHT")
    row.right:SetWordWrap(false)

    row.name = row:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
    row.name:SetJustifyH("LEFT")
    row.name:SetWordWrap(false)

    row.detail = row:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    row.detail:SetJustifyH("LEFT")
    row.detail:SetWordWrap(false)

    row.source = row:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    row.source:SetJustifyH("RIGHT")
    row.source:SetWordWrap(false)

    row:SetScript("OnEnter", function(self)
        if self.step then
            ShowStepTooltip(self, self.step)
        elseif self.entry then
            ShowItemTooltip(self, self.entry)
        elseif self.tip then
            GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
            GameTooltip:AddLine(self.tip, 1, 1, 1, true)
            GameTooltip:Show()
        end
    end)
    row:SetScript("OnLeave", function()
        GameTooltip:Hide()
    end)
    row:SetScript("OnClick", function(self)
        if not (IsShiftKeyDown and IsShiftKeyDown()) then
            return
        end
        if self.step and self.step.recipe and self.step.recipe.creates then
            InsertLink(ItemLink(self.step.recipe.creates))
        elseif self.entry then
            InsertLink(ItemLink(self.entry.itemID))
        end
    end)

    rows[index] = row
    return row
end

-- Gjør en rad klar for en bestemt type innhold.
local function LayoutRow(row, kind, y, height)
    row:ClearAllPoints()
    row:SetPoint("TOPLEFT", 0, -y)
    row:SetHeight(height)
    row.step, row.entry, row.tip = nil, nil, nil
    row.bg:SetColorTexture(0, 0, 0, 0)
    row.range:SetText("")
    row.name:SetText("")
    row.detail:SetText("")
    row.source:SetText("")
    row.right:SetText("")
    row.icon:Hide()
    row.name:ClearAllPoints()
    row.right:ClearAllPoints()
    row.detail:ClearAllPoints()
    row.source:ClearAllPoints()
    row.icon:ClearAllPoints()

    if kind == "step" then
        row.icon:SetPoint("TOPLEFT", 74, -3)
        row.icon:Show()
        row.right:SetPoint("TOPRIGHT", -6, -4)
        row.right:SetWidth(110)
        row.name:SetPoint("TOPLEFT", 100, -4)
        row.name:SetPoint("RIGHT", row.right, "LEFT", -6, 0)
        row.source:SetPoint("BOTTOMRIGHT", -6, 5)
        row.source:SetWidth(170)
        row.detail:SetPoint("BOTTOMLEFT", 100, 5)
        row.detail:SetPoint("RIGHT", row.source, "LEFT", -6, 0)
    elseif kind == "item" then
        row.icon:SetPoint("LEFT", 6, 0)
        row.icon:Show()
        row.right:SetPoint("RIGHT", -6, 0)
        row.right:SetWidth(250)
        row.name:SetPoint("LEFT", 32, 0)
        row.name:SetPoint("RIGHT", row.right, "LEFT", -6, 0)
    else -- "gate", "header", "text"
        row.name:SetPoint("LEFT", 6, 0)
        row.name:SetPoint("RIGHT", -6, 0)
    end
end

local function MaterialsLine(row)
    if not row.recipe then
        return NoteText(row.note) or ""
    end
    local parts = {}
    for _, mat in ipairs(row.mats) do
        local name = ItemName(mat[1])
        parts[#parts + 1] = mat[2] .. " " .. name
    end
    local text = table.concat(parts, ", ")
    if row.note then
        text = "|cffffd100*|r " .. text
    end
    return text
end

local function FillRoute(plan, y)
    local count = 0
    local profession = DATA.professions[plan.line]
    for _, entry in ipairs(plan.rows) do
        count = count + 1
        local row = GetRow(count)
        if entry.kind == "gate" then
            LayoutRow(row, "gate", y, GATE_ROW)
            local ready = GateReady(entry, plan.skill)
            row.name:SetText(GateText(entry) .. (ready and (" - " .. L.PROF_GATE_READY) or ""))
            if ready then
                row.name:SetTextColor(0.25, 1, 0.25)
            else
                row.name:SetTextColor(1, 0.5, 0.25)
            end
            row.bg:SetColorTexture(0.25, 0.12, 0.02, 0.35)
            y = y + GATE_ROW
        else
            LayoutRow(row, "step", y, ROUTE_ROW)
            row.step = entry
            row.range:SetText(("%d - %d"):format(entry.from, entry.to))
            if entry.recipe then
                row.icon:SetTexture(RecipeIcon(entry.recipeID, profession.icon))
                row.name:SetText(RecipeName(entry.recipeID))
                row.source:SetText(SourceText(entry.recipeID, entry.recipe))
            else
                row.icon:SetTexture(profession.icon)
                row.name:SetText(L.PROF_TEXT_STEP)
            end
            row.name:SetTextColor(1, 1, 1)
            row.right:SetText(CraftsText(entry))
            row.detail:SetText(MaterialsLine(entry))
            row.detail:SetTextColor(0.75, 0.75, 0.75)
            if entry.current then
                row.bg:SetColorTexture(0.30, 0.22, 0.05, 0.55)
            elseif count % 2 == 0 then
                row.bg:SetColorTexture(1, 1, 1, 0.03)
            end
            y = y + ROUTE_ROW
        end
        row:Show()
    end
    return count, y
end

local function FillShop(plan, y)
    local count = 0
    local function Header(text)
        count = count + 1
        local row = GetRow(count)
        LayoutRow(row, "header", y, SHOP_ROW)
        row.name:SetText(text)
        row.name:SetTextColor(1, 0.82, 0)
        row:Show()
        y = y + SHOP_ROW
    end
    local function Item(itemID, right, entry, alt)
        count = count + 1
        local row = GetRow(count)
        LayoutRow(row, "item", y, SHOP_ROW)
        local name, quality = ItemName(itemID)
        row.icon:SetTexture(ItemIcon(itemID))
        row.name:SetText(Coloured(name, quality))
        row.name:SetTextColor(1, 1, 1)
        row.right:SetText(right)
        row.entry = entry
        if alt then
            row.bg:SetColorTexture(1, 1, 1, 0.03)
        end
        row:Show()
        y = y + SHOP_ROW
    end

    if #plan.shop > 0 then
        Header(L.PROF_SHOP_GET)
        for index, entry in ipairs(plan.shop) do
            local counts = L.PROF_SHOP_COUNTS:format(entry.need, entry.have)
            local status
            if entry.missing > 0 then
                status = "|cffff6060" .. L.PROF_SHOP_MISSING:format(entry.missing) .. "|r"
            else
                status = "|cff40ff40" .. L.PROF_SHOP_ENOUGH .. "|r " .. CHECK_ICON
            end
            Item(entry.itemID, counts .. "  " .. status, entry, index % 2 == 0)
        end
    end

    if #plan.make > 0 then
        Header(L.PROF_SHOP_MAKE)
        for index, entry in ipairs(plan.make) do
            local text
            if entry.crafts > 0 then
                text = L.PROF_SHOP_MAKE_LINE:format(entry.count)
                if entry.have > 0 then
                    text = text .. " (" .. L.PROF_SHOP_HAVE:format(entry.have) .. ")"
                end
            else
                text = "|cff40ff40" .. L.PROF_SHOP_ENOUGH .. "|r " .. CHECK_ICON .. " (" .. L.PROF_SHOP_HAVE:format(entry.have) .. ")"
            end
            Item(entry.itemID, text, entry, index % 2 == 0)
        end
    end

    if #plan.tools > 0 then
        Header(L.PROF_SHOP_TOOLS)
        local _, mine = Owned()
        for index, tool in ipairs(plan.tools) do
            local inBags, inBank = 0, 0
            for _, itemID in ipairs(tool.items) do
                inBags = inBags + (mine.bags[itemID] or 0)
                inBank = inBank + (mine.bank[itemID] or 0)
            end
            local text
            if inBags > 0 then
                text = "|cff40ff40" .. L.PROF_TOOL_HAVE .. "|r " .. CHECK_ICON
            elseif inBank > 0 then
                text = "|cffffd100" .. L.PROF_TOOL_BANK .. "|r"
            elseif tool.madeIn then
                text = L.PROF_TOOL_MADE
            else
                text = "|cffff6060" .. L.PROF_TOOL_MISSING .. "|r"
            end
            Item(tool.items[1], text, { itemID = tool.items[1] }, index % 2 == 0)
        end
    end

    if count == 0 then
        count = count + 1
        local row = GetRow(count)
        LayoutRow(row, "text", y, SHOP_ROW * 2)
        row.name:SetText(L.PROF_SHOP_EMPTY)
        row.name:SetTextColor(0.6, 0.6, 0.6)
        row:Show()
        y = y + SHOP_ROW * 2
    end
    return count, y
end

-- Velger hvilken profession som skal vises: den som var valgt sist, ellers
-- din første, ellers den første i listen.
local function ChooseLine(mine)
    if selectedLine and DATA.professions[selectedLine] then
        return selectedLine
    end
    local character = CurrentCharacter()
    local saved = character and Number(character.selected)
    if saved and DATA.professions[saved] then
        return saved
    end
    for _, line in ipairs(ORDERED_LINES) do
        if mine[line] then
            return line
        end
    end
    return ORDERED_LINES[1]
end

local function SelectLine(line)
    selectedLine = line
    local character = CurrentCharacter()
    if character then
        character.selected = line
    end
    RefreshPanel()
end

local function OpenProfessionMenu(owner, mine)
    if not (MenuUtil and MenuUtil.CreateContextMenu) then
        -- Uten meny: gå til neste profession for hvert klikk.
        local nextLine = ORDERED_LINES[1]
        for index, line in ipairs(ORDERED_LINES) do
            if line == selectedLine then
                nextLine = ORDERED_LINES[index % #ORDERED_LINES + 1]
            end
        end
        SelectLine(nextLine)
        return
    end
    MenuUtil.CreateContextMenu(owner, function(_, root)
        root:CreateTitle(L.PROF_CHOOSE)
        for _, line in ipairs(ORDERED_LINES) do
            local label = DATA.professions[line].name
            if mine[line] then
                label = label .. (" (%d)"):format(mine[line].level)
            end
            root:CreateRadio(label, function(data)
                return data == selectedLine
            end, function(data)
                SelectLine(data)
            end, line)
        end
    end)
end

local function OpenTargetMenu(owner, skill)
    local choices = TargetChoices(skill)
    local function Set(target)
        local character = CurrentCharacter()
        if character and selectedLine then
            character.targets[selectedLine] = target
        end
        version = version + 1
        RefreshPanel()
    end
    if not (MenuUtil and MenuUtil.CreateContextMenu) then
        local current = TargetFor(selectedLine, skill)
        local nextTarget = choices[1]
        for index, target in ipairs(choices) do
            if target == current then
                nextTarget = choices[index % #choices + 1]
            end
        end
        Set(nextTarget)
        return
    end
    MenuUtil.CreateContextMenu(owner, function(_, root)
        root:CreateTitle(L.PROF_TARGET_TITLE)
        for _, target in ipairs(choices) do
            root:CreateRadio(tostring(target), function(data)
                return data == TargetFor(selectedLine, skill)
            end, Set, target)
        end
    end)
end

RefreshPanel = function()
    if not panel or not panel:IsVisible() then
        return
    end

    local mine = ReadMyProfessions()
    local line = ChooseLine(mine)
    selectedLine = line
    local profession = DATA.professions[line]
    local info = mine[line]
    local skill = info and info.level or 1
    local max = info and info.max or 0
    local target = TargetFor(line, skill)
    local owned = Owned()
    local plan = BuildPlan(line, skill, max, target, owned, db.safe)
    currentPlan = plan

    -- Chips for dine egne professions, og en for å velge hvilken som helst.
    local chipIndex = 0
    for _, ownLine in ipairs(ORDERED_LINES) do
        if mine[ownLine] and chipIndex < #panel.professionChips then
            chipIndex = chipIndex + 1
            local chip = panel.professionChips[chipIndex]
            chip.line = ownLine
            chip.label:SetText(DATA.professions[ownLine].name)
            chip.icon:SetTexture(mine[ownLine].icon or DATA.professions[ownLine].icon)
            chip:SetSelected(ownLine == line)
            chip:Show()
        end
    end
    for index = chipIndex + 1, #panel.professionChips do
        panel.professionChips[index]:Hide()
    end
    -- Chipene deler bredden (584 punkter), men blir ikke bredere enn 140.
    local width = math.min(140, math.floor((584 - chipIndex * 4) / (chipIndex + 1)))
    for index = 1, chipIndex do
        local chip = panel.professionChips[index]
        chip:SetWidth(width)
        chip:ClearAllPoints()
        chip:SetPoint("TOPLEFT", 14 + (index - 1) * (width + 4), -6)
    end
    panel.otherChip:SetWidth(width)
    panel.otherChip:ClearAllPoints()
    panel.otherChip:SetPoint("TOPLEFT", 14 + chipIndex * (width + 4), -6)
    if mine[line] then
        panel.otherChip.label:SetText(chipIndex > 0 and L.PROF_OTHER or L.PROF_CHOOSE)
        panel.otherChip:SetSelected(false)
    else
        panel.otherChip.label:SetText(profession.name)
        panel.otherChip:SetSelected(true)
    end

    -- Status: skill og hva som er igjen.
    if info then
        local status = ("%s: %d / %d"):format(profession.name, skill, max)
        if skill >= target or plan.crafts == 0 then
            panel.status:SetText(status .. "  -  " .. L.PROF_DONE:format(target))
        else
            panel.status:SetText(status .. "  -  " .. L.PROF_STATUS_LEFT:format(plan.crafts, target))
        end
    else
        panel.status:SetText(L.PROF_NOT_LEARNED:format(profession.name) .. "  -  " .. L.PROF_STATUS_LEFT:format(plan.crafts, target))
    end

    -- Advarsel når du står fast på taket ditt.
    local warning = ""
    if info and skill >= max and max < MAX_SKILL then
        for index, gate in ipairs(profession.gates) do
            if gate[1] == max then
                local entry = { rank = index, before = gate[1], needSkill = gate[2], needLevel = gate[3], how = gate[4] }
                warning = L.PROF_AT_CAP:format(max, RankName(index))
                if not GateReady(entry, skill) then
                    warning = warning .. " " .. GateText(entry)
                end
            end
        end
    end
    panel.warning:SetText(warning)

    panel.routeChip.label:SetText(L.PROF_VIEW_ROUTE)
    panel.shopChip.label:SetText(L.PROF_VIEW_SHOP)
    panel.routeChip:SetSelected(view == "route")
    panel.shopChip:SetSelected(view == "shop")
    panel.targetChip.label:SetText(L.PROF_TARGET:format(target))
    panel.targetChip:SetEnabled(skill < MAX_SKILL)
    panel.safeCheck:SetChecked(db.safe and true or false)
    panel.safeCheck.label:SetText(L.PROF_SAFE)
    panel.altsCheck:SetChecked(db.alts and true or false)
    panel.altsCheck.label:SetText(L.PROF_ALTS)

    local count, height
    if view == "shop" then
        count, height = FillShop(plan, 0)
    else
        count, height = FillRoute(plan, 0)
        if count == 0 then
            count = 1
            local row = GetRow(1)
            LayoutRow(row, "text", 0, SHOP_ROW * 2)
            row.name:SetText(L.PROF_EMPTY_ROUTE)
            row.name:SetTextColor(0.6, 0.6, 0.6)
            row:Show()
            height = SHOP_ROW * 2
        end
    end
    for index = count + 1, #rows do
        rows[index].step, rows[index].entry, rows[index].tip = nil, nil, nil
        rows[index]:Hide()
    end
    panel.content:SetHeight(math.max(1, height))

    -- Nederst: hvor ruten kommer fra, og når banken sist ble lest.
    local character = CurrentCharacter()
    local updated = profession.updated or ""
    local y, m, d = updated:match("^(%d+)-(%d+)-(%d+)$")
    local footer = L.PROF_FOOTER:format(profession.guide, d and (("%d.%d.%s"):format(tonumber(d), tonumber(m), y)) or updated)
    if character and character.bankTime then
        footer = footer .. " " .. L.PROF_BANK_SEEN:format(date("%d.%m. %H:%M", character.bankTime))
    else
        footer = footer .. " " .. L.PROF_BANK_NEVER
    end
    panel.footer:SetText(footer)
end

-- Kalles av hovedvinduet første gang modulen velges.
local function CreatePanel(parent)
    local f = CreateFrame("Frame", nil, parent)
    f:SetAllPoints(parent)

    -- Øverst: dine professions, og en chip for å velge en annen.
    f.professionChips = {}
    for index = 1, 4 do
        local chip = DW.CreateChip(f, 140, 26, FALLBACK_ICON)
        chip:SetScript("OnClick", function(self)
            if self.line then
                SelectLine(self.line)
            end
        end)
        f.professionChips[index] = chip
    end
    f.otherChip = DW.CreateChip(f, 140, 26)
    f.otherChip:SetScript("OnClick", function(self)
        OpenProfessionMenu(self, ReadMyProfessions())
    end)

    f.status = f:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    f.status:SetPoint("TOPLEFT", 16, -40)
    f.status:SetPoint("RIGHT", -14, 0)
    f.status:SetJustifyH("LEFT")
    f.status:SetWordWrap(false)

    f.warning = f:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    f.warning:SetPoint("TOPLEFT", 16, -58)
    f.warning:SetPoint("RIGHT", -14, 0)
    f.warning:SetJustifyH("LEFT")
    f.warning:SetWordWrap(false)
    f.warning:SetTextColor(1, 0.5, 0.25)

    -- Visning, mål og valg.
    f.routeChip = DW.CreateChip(f, 104, 26)
    f.routeChip:SetPoint("TOPLEFT", 14, -76)
    f.routeChip.label:SetJustifyH("CENTER")
    f.routeChip:SetScript("OnClick", function()
        view = "route"
        RefreshPanel()
    end)
    f.shopChip = DW.CreateChip(f, 104, 26)
    f.shopChip:SetPoint("LEFT", f.routeChip, "RIGHT", 6, 0)
    f.shopChip.label:SetJustifyH("CENTER")
    f.shopChip:SetScript("OnClick", function()
        view = "shop"
        RefreshPanel()
    end)
    f.targetChip = DW.CreateChip(f, 90, 26)
    f.targetChip:SetPoint("LEFT", f.shopChip, "RIGHT", 6, 0)
    f.targetChip.label:SetJustifyH("CENTER")
    f.targetChip:SetScript("OnClick", function(self)
        local info = ReadMyProfessions()[selectedLine]
        OpenTargetMenu(self, info and info.level or 1)
    end)

    local function Check(x, setting, tipKey)
        local check = CreateFrame("CheckButton", nil, f, "UICheckButtonTemplate")
        check:SetSize(22, 22)
        check:SetPoint("TOPLEFT", x, -78)
        check.label = check:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
        check.label:SetPoint("LEFT", check, "RIGHT", 2, 0)
        check:SetScript("OnClick", function(self)
            db[setting] = self:GetChecked() and true or nil
            version = version + 1
            RefreshPanel()
        end)
        check:SetScript("OnEnter", function(self)
            GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
            GameTooltip:AddLine(L[tipKey], 1, 1, 1, true)
            GameTooltip:Show()
        end)
        check:SetScript("OnLeave", function()
            GameTooltip:Hide()
        end)
        return check
    end
    f.safeCheck = Check(334, "safe", "PROF_SAFE_TIP")
    f.altsCheck = Check(446, "alts", "PROF_ALTS_TIP")

    local scroll = CreateFrame("ScrollFrame", "DragonworldProfessionsScroll", f, "ScrollFrameTemplate")
    scroll:SetPoint("TOPLEFT", 10, -110)
    scroll:SetPoint("BOTTOMRIGHT", -30, 26)

    f.content = CreateFrame("Frame", nil, scroll)
    f.content:SetSize(parent:GetWidth() - 10 - 30, 1)
    scroll:SetScrollChild(f.content)

    f.footer = f:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
    f.footer:SetPoint("BOTTOMLEFT", 14, 8)
    f.footer:SetPoint("BOTTOMRIGHT", -14, 8)
    f.footer:SetJustifyH("LEFT")
    f.footer:SetWordWrap(false)

    f:SetScript("OnShow", function()
        if DW.IsMember() then
            Scan()
        end
        RefreshPanel()
    end)

    panel = f
    return f
end

-- Hendelser ---------------------------------------------------------------------------

-- Endringer kommer ofte flere på rad. Samle dem opp og gjør det én gang.
local queued = false

local function Queue()
    if queued then
        return
    end
    if not (C_Timer and C_Timer.After) then
        Scan()
        RefreshPanel()
        return
    end
    queued = true
    C_Timer.After(0.4, function()
        queued = false
        if DW.IsMember() then
            Scan()
            RefreshPanel()
        end
    end)
end

local frame = CreateFrame("Frame")

frame:SetScript("OnEvent", function(self, event, arg)
    if not DW.IsMember() then
        return
    end
    if event == "BANKFRAME_OPENED" then
        bankOpen = true
    elseif event == "BANKFRAME_CLOSED" then
        bankOpen = false
        return
    elseif event == "GET_ITEM_INFO_RECEIVED" then
        if not (type(arg) == "number" and waitingForItem[arg]) then
            return
        end
        waitingForItem[arg] = nil
    elseif event == "TRADE_SKILL_SHOW" or event == "TRADE_SKILL_LIST_UPDATE" or event == "NEW_RECIPE_LEARNED" then
        LearnKnownRecipes()
    end
    Queue()
end)

for _, event in ipairs({
    "PLAYER_ENTERING_WORLD",
    "BAG_UPDATE_DELAYED",
    "PLAYERBANKSLOTS_CHANGED",
    "BANKFRAME_OPENED",
    "BANKFRAME_CLOSED",
    "GET_ITEM_INFO_RECEIVED",
    "SKILL_LINES_CHANGED",
    "CHAT_MSG_SKILL",
    "PLAYER_LEVEL_UP",
    "TRADE_SKILL_SHOW",
    "TRADE_SKILL_LIST_UPDATE",
    "NEW_RECIPE_LEARNED",
    "LEARNED_SPELL_IN_TAB",
}) do
    pcall(frame.RegisterEvent, frame, event)
end

DW.OnMembershipChanged(function(member)
    if member then
        Queue()
    end
end)

DW.OnLanguageChanged(function()
    RefreshPanel()
end)

-- Feilsøking: hva addonen leser av professions, bagger og oppskrifter.
DW.AddDebug("professions", function(add)
    local text = DW.DebugText
    local parts = {}
    for line, info in pairs(ReadMyProfessions()) do
        parts[#parts + 1] = ("%s %d/%d"):format(DATA.professions[line].name, info.level, info.max)
    end
    table.sort(parts)
    add("med rute: " .. (#parts > 0 and table.concat(parts, ", ") or "ingen"))
    if GetProfessions and GetProfessionInfo then
        local results = { pcall(GetProfessions) }
        for position, index in pairs(results) do
            if position > 1 then
                local ok, name, _, level, max, _, _, line = pcall(GetProfessionInfo, index)
                add(("GetProfessionInfo(%s) = %s %s/%s line %s"):format(text(index), text(ok and name), text(level), text(max), text(line)))
            end
        end
    end
    local character = CurrentCharacter()
    if character then
        local bags, bank, known = 0, 0, 0
        for _ in pairs(character.bags) do bags = bags + 1 end
        for _ in pairs(character.bank) do bank = bank + 1 end
        for _ in pairs(character.known) do known = known + 1 end
        add(("rutegjenstander: %d i bagger, %d i bank | kjente ruteoppskrifter: %d"):format(bags, bank, known))
    end
    local ui = C_TradeSkillUI
    add("GetAllRecipeIDs: " .. text(ui ~= nil and ui.GetAllRecipeIDs ~= nil) .. " | GetRecipeInfo: " .. text(ui ~= nil and ui.GetRecipeInfo ~= nil)
        .. " | IsPlayerSpell: " .. text(IsPlayerSpell ~= nil) .. " | C_Spell.GetSpellName: " .. text(C_Spell ~= nil and C_Spell.GetSpellName ~= nil))
end)

-- Modul -------------------------------------------------------------------------------

DW.RegisterModule({
    id = MODULE_ID,
    titleKey = "PROF_TITLE",
    notesKey = "PROF_NOTES",
    icon = "Interface\\Icons\\INV_Misc_Book_09",

    OnLoad = function(self, saved)
        if type(saved.characters) ~= "table" then
            saved.characters = {}
        end
        db = saved
    end,

    CreatePanel = function(self, parent)
        return CreatePanel(parent)
    end,
})
