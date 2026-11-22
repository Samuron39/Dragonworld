-- Dragonworld - Materialer
-- Keeps track of crafting materials on all your characters, both in the
-- bags and in the bank, and shows them together in the main window. You can
-- filter on where they are (all, in bags, in bank) and by character.
-- "Everything" shows all items instead of only the materials, and the gold
-- on each character is shown too, so you can see what your alts are holding.
--
-- How the numbers are collected:
--   * The bags are read when you log in and every time their contents change.
--   * The bank can only be read while it is open. It is read then, and the
--     numbers are remembered until the next time you open it.
--   * Everything is saved per character, shared across the account, so you
--     see your other characters too. A character only shows up after you have
--     logged in on it with the addon (and opened the bank there).
--
-- Items count as "materials" if the game itself calls them Trade Goods, if it
-- has marked them as crafting materials, or if a recipe uses them (see below).
--
-- The tooltip on a material says that it is a crafting material, and which
-- professions use it:
--   * Every time a crafting window is open (your own, or someone else's
--     profession you opened from the Roster tab), the addon reads the recipes in it
--     and remembers which materials they use. This is remembered account-wide.
--   * For materials no opened profession has used yet, we guess from the
--     type the game gives them (Cloth, Herb, Metal & Stone ...), and put
--     "usually" in front.
--
-- All text is in Locales.lua (the names starting with MAT_).

local ADDON_NAME, DW = ...
local L = DW.L

local MODULE_ID = "materialer"

local ITEM_CLASS_TRADEGOODS = (Enum and Enum.ItemClass and Enum.ItemClass.Tradegoods) or 7
local LAST_BAG = NUM_TOTAL_EQUIPPED_BAG_SLOTS or NUM_BAG_SLOTS or 4
local GetItemInfo = (C_Item and C_Item.GetItemInfo) or GetItemInfo

-- Saved data. Set in OnLoad at the bottom.
--   db.characters["Name-Realm"] = {
--       name, realm, class,
--       bags = { [itemID] = count }, bagsTime = time,
--       bank = { [itemID] = count }, bankTime = time or nil,
--       (bags and bank hold only the materials)
--       allBags, allBank = { [itemID] = count }   every item
--       money = copper, moneyTime = time
--   }
--   db.kind = "all" when "Everything" is chosen
--   db.items[itemID] = { name, quality }   names we have seen, so items on
--                                          other characters can be shown by name
--   db.reagents[itemID] = { [profession] = true }   which professions
--                                          use the material, read from recipes
local db = { characters = {}, items = {}, reagents = {} }

-- What the materials are used for -------------------------------------------------

-- The game's number for each profession, and the English name if the game
-- can't give us the name itself.
local PROFESSION_NAMES = {
    [129] = "First Aid", [164] = "Blacksmithing", [165] = "Leatherworking", [171] = "Alchemy",
    [185] = "Cooking", [186] = "Mining", [197] = "Tailoring", [202] = "Engineering",
    [333] = "Enchanting", [755] = "Jewelcrafting", [773] = "Inscription",
}

-- The guess from the type (the subtype of Trade Goods): which professions
-- usually use such materials. Types used by almost everyone
-- (Elemental, Other) are not included.
local USUAL_PROFESSIONS = {
    [1] = { 202 },           -- Parts
    [4] = { 755 },           -- Jewelcrafting
    [5] = { 197, 129 },      -- Cloth
    [6] = { 165 },           -- Leather
    [7] = { 164, 202, 186 }, -- Metal & Stone
    [8] = { 185 },           -- Cooking
    [9] = { 171 },           -- Herb
    [12] = { 333 },          -- Enchanting
    [16] = { 773 },          -- Inscription
}

local function ProfessionName(line)
    if C_TradeSkillUI and C_TradeSkillUI.GetTradeSkillDisplayName then
        local ok, name = pcall(C_TradeSkillUI.GetTradeSkillDisplayName, line)
        if ok and type(name) == "string" and not DW.IsSecret(name) and name ~= "" then
            return name
        end
    end
    return PROFESSION_NAMES[line]
end

-- Collecting ------------------------------------------------------------------

local BAG_CONTAINERS = {}
for bag = 0, LAST_BAG do
    BAG_CONTAINERS[#BAG_CONTAINERS + 1] = bag
end

-- The bank's slots. In Forever it is 6-14: the bank itself and the bags in it.
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

local materialCache = {} -- [itemID] = true/false, only when we know for sure

local function IsMaterial(itemID)
    if type(db.reagents[itemID]) == "table" and next(db.reagents[itemID]) then
        return true -- a recipe uses it
    end
    local known = materialCache[itemID]
    if known ~= nil then
        return known
    end

    local _, _, _, _, _, classID = C_Item.GetItemInfoInstant(itemID)
    if classID == ITEM_CLASS_TRADEGOODS then
        materialCache[itemID] = true
        return true
    end

    -- The rest requires the game to have loaded the item. If it hasn't yet,
    -- we say no for now without remembering the answer, and try again at the next read.
    local name = GetItemInfo(itemID)
    if type(name) ~= "string" then
        return false
    end
    local isCraftingReagent = select(17, GetItemInfo(itemID))
    materialCache[itemID] = (isCraftingReagent == true)
    return materialCache[itemID]
end

-- Is the item a crafting material, and which professions use it?
-- Returns nil if it is not a material, otherwise:
--   professions = { "Blacksmithing", ... }, sorted (may be empty)
--   usually     = true when the list is guessed from the type
function DW.CraftingInfo(itemID)
    if type(itemID) ~= "number" or DW.IsSecret(itemID) or not IsMaterial(itemID) then
        return nil
    end
    local names = {}
    local learned = db.reagents[itemID]
    if type(learned) == "table" then
        for name in pairs(learned) do
            names[#names + 1] = name
        end
    end
    local usually = false
    if #names == 0 then
        local _, _, _, _, _, classID, subclassID = C_Item.GetItemInfoInstant(itemID)
        if classID == ITEM_CLASS_TRADEGOODS then
            for _, line in ipairs(USUAL_PROFESSIONS[subclassID] or {}) do
                names[#names + 1] = ProfessionName(line)
            end
            usually = #names > 0
        end
    end
    table.sort(names)
    return { professions = names, usually = usually }
end

-- Reads the recipes in the crafting window that is open, and remembers which
-- materials the profession uses. Returns true if we learned something new.
local readThisSession = {} -- [profession] = number of recipes we have read

local function LearnReagents()
    local ui = C_TradeSkillUI
    if not (ui and ui.GetBaseProfessionInfo and ui.GetAllRecipeIDs and ui.GetRecipeSchematic) then
        return false
    end
    local ok, info = pcall(ui.GetBaseProfessionInfo)
    local profession = ok and type(info) == "table" and info.professionName
    if type(profession) ~= "string" or DW.IsSecret(profession) then
        return false
    end
    profession = profession:gsub("[%c|]", ""):sub(1, 40)
    if profession == "" then
        return false
    end

    local fine, recipes = pcall(ui.GetAllRecipeIDs)
    if not fine or type(recipes) ~= "table" or #recipes == 0 then
        return false
    end
    -- The window fires often (e.g. for every item you craft). Only read
    -- again if recipes have been added.
    if readThisSession[profession] == #recipes then
        return false
    end
    readThisSession[profession] = #recipes

    local learnedSomething = false
    for _, recipeID in ipairs(recipes) do
        local good, schematic = pcall(ui.GetRecipeSchematic, recipeID, false)
        local slots = good and type(schematic) == "table" and schematic.reagentSlotSchematics
        for _, slot in ipairs(type(slots) == "table" and slots or {}) do
            local reagents = type(slot) == "table" and slot.reagents
            for _, reagent in ipairs(type(reagents) == "table" and reagents or {}) do
                local itemID = type(reagent) == "table" and reagent.itemID
                if type(itemID) == "number" and not DW.IsSecret(itemID) then
                    if type(db.reagents[itemID]) ~= "table" then
                        db.reagents[itemID] = {}
                    end
                    if not db.reagents[itemID][profession] then
                        db.reagents[itemID][profession] = true
                        learnedSomething = true
                    end
                end
            end
        end
    end
    return learnedSomething
end

local waitingForName = {} -- [itemID] = true while we wait for the game to load the name

local function RememberItem(itemID)
    local name, _, quality = GetItemInfo(itemID)
    if type(name) == "string" then
        db.items[itemID] = { name = name, quality = quality }
        waitingForName[itemID] = nil
    elseif not waitingForName[itemID] then
        waitingForName[itemID] = true
        if C_Item and C_Item.RequestLoadItemDataByID then
            C_Item.RequestLoadItemDataByID(itemID)
        end
    end
end

-- Counts the items in the given slots: the materials, and everything. Also
-- returns how many slots existed, so we can tell "empty" from "not available".
local function CountItems(containers)
    local materials, all, slots = {}, {}, 0
    for _, bag in ipairs(containers) do
        local size = C_Container.GetContainerNumSlots(bag) or 0
        slots = slots + size
        for slot = 1, size do
            local itemID = C_Container.GetContainerItemID(bag, slot)
            if type(itemID) == "number" and not DW.IsSecret(itemID) then
                local info = C_Container.GetContainerItemInfo and C_Container.GetContainerItemInfo(bag, slot)
                local count = (type(info) == "table" and info.stackCount) or 1
                all[itemID] = (all[itemID] or 0) + count
                if IsMaterial(itemID) then
                    materials[itemID] = (materials[itemID] or 0) + count
                end
                RememberItem(itemID)
            end
        end
    end
    return materials, all, slots
end

local function ReadMoney(character)
    local money = GetMoney and GetMoney()
    if type(money) == "number" and not DW.IsSecret(money) then
        character.money = money
        character.moneyTime = time()
    end
end

-- The entry for the character you are logged in on. Created if missing.
local function CurrentCharacter()
    local key, name, realm = DW.CharacterKey()
    if not key then
        return nil
    end
    local character = db.characters[key]
    if type(character) ~= "table" then
        character = {}
        db.characters[key] = character
    end
    character.name, character.realm = name, realm
    character.class = select(2, UnitClass("player"))
    if type(character.bags) ~= "table" then
        character.bags = {}
    end
    if type(character.bank) ~= "table" then
        character.bank = {}
    end
    return character, key
end

local bankOpen = false

local function Scan()
    local character = CurrentCharacter()
    if not character then
        return
    end

    character.bags, character.allBags = CountItems(BAG_CONTAINERS)
    character.bagsTime = time()
    ReadMoney(character)

    if bankOpen then
        local materials, all, slots = CountItems(BankContainers())
        -- If we found no bank slots, the bank is not readable right now. Then
        -- we keep what we remembered, instead of assuming it is empty.
        if slots > 0 then
            character.bank, character.allBank = materials, all
            character.bankTime = time()
        end
    end
end

-- Tooltip ---------------------------------------------------------------------

-- The client can report the same item twice for one tooltip. Here we remember
-- which item each tooltip has already received the lines for.
local shownItem = {}

local function OnTooltipItem(tooltip, data)
    if not DW.HasAccess() then
        return
    end
    if tooltip ~= GameTooltip and tooltip ~= ItemRefTooltip then
        return
    end
    local itemID = data and data.id
    if type(itemID) ~= "number" or DW.IsSecret(itemID) or shownItem[tooltip] == itemID then
        return
    end
    local ok, info = pcall(DW.CraftingInfo, itemID)
    if not ok or not info then
        return
    end
    shownItem[tooltip] = itemID

    tooltip:AddLine(" ")
    tooltip:AddLine(L.MAT_TIP_MATERIAL, 0.30, 0.85, 0.80)
    if #info.professions > 0 then
        local list = table.concat(info.professions, ", ")
        tooltip:AddLine((info.usually and L.MAT_TIP_USUALLY or L.MAT_TIP_USED_IN):format(list), 0.75, 0.75, 0.75, true)
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

-- Display ---------------------------------------------------------------------

local ROW_HEIGHT = 24
local FALLBACK_ICON = 134400 -- question mark

local panel -- created the first time the module is selected in the main window
local rows = {}
local RefreshPanel

local filterSource = "all" -- "all", "bags" or "bank"
local filterCharacter      -- the key of one character, or nil for all
local searchText = ""      -- what is in the search box

local function SortedCharacterKeys()
    local keys = {}
    for key, character in pairs(db.characters) do
        if type(character) == "table" then
            keys[#keys + 1] = key
        end
    end
    table.sort(keys)
    return keys
end

-- Just the name, with the realm after it if two characters share the name.
local function DisplayName(key)
    local character = db.characters[key]
    local name = character and character.name
    if type(name) ~= "string" then
        return key
    end
    for otherKey, other in pairs(db.characters) do
        if otherKey ~= key and type(other) == "table" and other.name == name then
            return key
        end
    end
    return name
end

-- db.kind is "all" when "Everything" is chosen, otherwise only materials are shown.
local function ShowsAll()
    return db.kind == "all"
end

-- What the character has in the bags or the bank ("bags" or "bank"), by the
-- current filter. Characters read before "Everything" existed only have the
-- materials until they log in again.
local function Counts(character, where)
    local counts
    if ShowsAll() then
        counts = character[where == "bags" and "allBags" or "allBank"]
    end
    if type(counts) ~= "table" then
        counts = character[where]
    end
    return type(counts) == "table" and counts or {}
end

local function Money(copper)
    if type(copper) ~= "number" or copper < 0 then
        return "?"
    end
    if GetCoinTextureString then
        local ok, text = pcall(GetCoinTextureString, copper)
        if ok and type(text) == "string" and text ~= "" then
            return text
        end
    end
    local gold, silver, rest = math.floor(copper / 10000), math.floor(copper / 100) % 100, copper % 100
    local parts = {}
    if gold > 0 then parts[#parts + 1] = gold .. "g" end
    if silver > 0 then parts[#parts + 1] = silver .. "s" end
    if rest > 0 or #parts == 0 then parts[#parts + 1] = rest .. "c" end
    return table.concat(parts, " ")
end

-- The gold of the chosen character, or of all of them together.
local function TotalMoney()
    local total = 0
    for key, character in pairs(db.characters) do
        if type(character) == "table" and (filterCharacter == nil or filterCharacter == key)
            and type(character.money) == "number" then
            total = total + character.money
        end
    end
    return total
end

-- Sums the items by the current filter. One entry per item,
-- sorted by name.
local function Collect()
    local totals = {}
    local function Add(counts)
        if type(counts) == "table" then
            for itemID, count in pairs(counts) do
                if type(itemID) == "number" and type(count) == "number" then
                    totals[itemID] = (totals[itemID] or 0) + count
                end
            end
        end
    end

    for key, character in pairs(db.characters) do
        if type(character) == "table" and (filterCharacter == nil or filterCharacter == key) then
            if filterSource ~= "bank" then
                Add(Counts(character, "bags"))
            end
            if filterSource ~= "bags" then
                Add(Counts(character, "bank"))
            end
        end
    end

    -- The search ignores upper/lower case and spaces before and after, and
    -- looks for the text anywhere in the name.
    local needle = searchText:lower()
    needle = needle:gsub("^%s+", "")
    needle = needle:gsub("%s+$", "")

    local entries = {}
    for itemID, count in pairs(totals) do
        local known = db.items[itemID]
        local name, quality = known and known.name, known and known.quality
        if type(name) ~= "string" then
            local loadedName, _, loadedQuality = GetItemInfo(itemID)
            if type(loadedName) == "string" then
                name, quality = loadedName, loadedQuality
                db.items[itemID] = { name = name, quality = quality }
            else
                name = "item:" .. itemID
                RememberItem(itemID) -- asks the game to load the name
            end
        end
        if needle == "" or name:lower():find(needle, 1, true) then
            local _, _, _, _, icon = C_Item.GetItemInfoInstant(itemID)
            entries[#entries + 1] = { itemID = itemID, count = count, name = name, quality = quality, icon = icon }
        end
    end

    table.sort(entries, function(a, b)
        if a.name ~= b.name then
            return a.name < b.name
        end
        return a.itemID < b.itemID
    end)
    return entries
end

local function SetSource(source)
    filterSource = source
    RefreshPanel()
end

local function SetCharacter(key)
    filterCharacter = key
    RefreshPanel()
end

-- The menu for choosing a character. data is the key, or false for "all".
local function OpenCharacterMenu(owner)
    local keys = SortedCharacterKeys()

    if not (MenuUtil and MenuUtil.CreateContextMenu) then
        -- Without a menu: go to the next character on each click, and finally all.
        local nextKey = keys[1]
        for index, key in ipairs(keys) do
            if key == filterCharacter then
                nextKey = keys[index + 1]
            end
        end
        SetCharacter(nextKey)
        return
    end

    local function IsSelected(data)
        return (filterCharacter or false) == data
    end
    local function Select(data)
        SetCharacter(data or nil)
    end

    MenuUtil.CreateContextMenu(owner, function(_, root)
        root:CreateTitle(L.MAT_CHARACTER)
        root:CreateRadio(L.MAT_ALL_CHARACTERS, IsSelected, Select, false)
        for _, key in ipairs(keys) do
            root:CreateRadio(DisplayName(key), IsSelected, Select, key)
        end
    end)
end

local function GetRow(index)
    local row = rows[index]
    if row then
        return row
    end

    row = CreateFrame("Frame", nil, panel.content)
    row:SetSize(panel.content:GetWidth(), ROW_HEIGHT)
    row:SetPoint("TOPLEFT", 0, -(index - 1) * ROW_HEIGHT)
    row:EnableMouse(true)

    row.icon = row:CreateTexture(nil, "ARTWORK")
    row.icon:SetSize(18, 18)
    row.icon:SetPoint("LEFT", 2, 0)
    row.icon:SetTexCoord(0.07, 0.93, 0.07, 0.93)

    row.count = row:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
    row.count:SetPoint("RIGHT", -8, 0)
    row.count:SetWidth(80)
    row.count:SetJustifyH("RIGHT")

    row.name = row:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
    row.name:SetPoint("LEFT", row.icon, "RIGHT", 6, 0)
    row.name:SetPoint("RIGHT", row.count, "LEFT", -6, 0)
    row.name:SetJustifyH("LEFT")
    row.name:SetWordWrap(false)

    -- Hover over the row to see the item and where it is, per character.
    row:SetScript("OnEnter", function(self)
        local entry = self.entry
        if not entry then
            return
        end
        GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
        if GameTooltip.SetItemByID then
            GameTooltip:SetItemByID(entry.itemID)
        else
            GameTooltip:AddLine(entry.name)
        end
        GameTooltip:AddLine(" ")
        for _, key in ipairs(SortedCharacterKeys()) do
            local character = db.characters[key]
            local inBags = Counts(character, "bags")[entry.itemID] or 0
            local inBank = Counts(character, "bank")[entry.itemID] or 0
            if inBags + inBank > 0 then
                GameTooltip:AddLine(L.MAT_TOOLTIP_LINE:format(DisplayName(key), inBags, inBank), 0.75, 0.75, 0.75)
            end
        end
        GameTooltip:Show()
    end)
    row:SetScript("OnLeave", function()
        GameTooltip:Hide()
    end)

    rows[index] = row
    return row
end

RefreshPanel = function()
    if not panel or not panel:IsVisible() then
        return
    end

    -- The character that was selected may be gone from the saved data.
    if filterCharacter and type(db.characters[filterCharacter]) ~= "table" then
        filterCharacter = nil
    end

    local all = ShowsAll()
    panel.title:SetText(all and L.MAT_PANEL_TITLE_ALL or L.MAT_PANEL_TITLE)
    panel.searchLabel:SetText(L.MAT_SEARCH)
    panel.headerItem:SetText(all and L.MAT_HEADER_ITEM_ALL or L.MAT_HEADER_ITEM)
    panel.headerCount:SetText(L.MAT_HEADER_COUNT)
    panel.empty:SetText(all and L.MAT_EMPTY_ALL or L.MAT_EMPTY)
    panel.kindChips.materials.label:SetText(L.MAT_KIND_MATERIALS)
    panel.kindChips.all.label:SetText(L.MAT_KIND_ALL)
    panel.kindChips.materials:SetSelected(not all)
    panel.kindChips.all:SetSelected(all)
    panel.gold:SetText(L.MAT_GOLD:format(Money(TotalMoney())))

    panel.sourceChips.all.label:SetText(L.MAT_SOURCE_ALL)
    panel.sourceChips.bags.label:SetText(L.MAT_SOURCE_BAGS)
    panel.sourceChips.bank.label:SetText(L.MAT_SOURCE_BANK)
    for source, chip in pairs(panel.sourceChips) do
        chip:SetSelected(source == filterSource)
    end
    panel.characterChip.label:SetText(L.MAT_CHARACTER_LABEL:format(
        filterCharacter and DisplayName(filterCharacter) or L.MAT_ALL_CHARACTERS))

    local entries = Collect()
    for index, entry in ipairs(entries) do
        local row = GetRow(index)
        local colour = ITEM_QUALITY_COLORS and entry.quality and ITEM_QUALITY_COLORS[entry.quality]
        row.entry = entry
        row.icon:SetTexture(entry.icon or FALLBACK_ICON)
        row.name:SetText(entry.name)
        if colour then
            row.name:SetTextColor(colour.r, colour.g, colour.b)
        else
            row.name:SetTextColor(1, 1, 1)
        end
        row.count:SetText(tostring(entry.count))
        row:Show()
    end
    for index = #entries + 1, #rows do
        rows[index].entry = nil
        rows[index]:Hide()
    end

    panel.content:SetHeight(math.max(1, #entries * ROW_HEIGHT))
    panel.empty:SetShown(#entries == 0)

    -- At the bottom: when this character's bank was last read.
    local character = CurrentCharacter()
    if character and character.bankTime then
        panel.footer:SetText(L.MAT_BANK_SEEN:format(date("%d.%m.%Y %H:%M", character.bankTime)))
    else
        panel.footer:SetText(L.MAT_BANK_NEVER)
    end
end

-- Called by the main window the first time the module is selected.
local function CreatePanel(parent)
    local f = CreateFrame("Frame", nil, parent)
    f:SetAllPoints(parent)

    f.title = f:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
    f.title:SetPoint("TOP", 0, -12)

    -- Filter: where the materials are.
    f.sourceChips = {}
    for index, source in ipairs({ "all", "bags", "bank" }) do
        local chip = DW.CreateChip(f, 100, 26)
        chip:SetPoint("TOPLEFT", 14 + (index - 1) * 106, -40)
        chip.label:SetJustifyH("CENTER")
        chip:SetScript("OnClick", function()
            SetSource(source)
        end)
        f.sourceChips[source] = chip
    end

    -- Filter: which character.
    f.characterChip = DW.CreateChip(f, 230, 26)
    f.characterChip:SetPoint("TOPRIGHT", -14, -40)
    f.characterChip:SetScript("OnClick", function(self)
        OpenCharacterMenu(self)
    end)

    -- Search box: the list narrows as you type.
    f.searchLabel = f:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    f.searchLabel:SetPoint("TOPLEFT", 14, -80)

    f.searchBox = CreateFrame("EditBox", nil, f, "InputBoxTemplate")
    f.searchBox:SetSize(260, 22)
    f.searchBox:SetPoint("LEFT", f.searchLabel, "RIGHT", 12, 0)
    f.searchBox:SetAutoFocus(false)
    f.searchBox:SetMaxBytes(40)
    f.searchBox:SetScript("OnEscapePressed", function(self)
        self:ClearFocus()
    end)
    f.searchBox:SetScript("OnEnterPressed", function(self)
        self:ClearFocus()
    end)
    f.searchBox:HookScript("OnTextChanged", function(self)
        searchText = self:GetText() or ""
        RefreshPanel()
    end)

    f.headerItem = f:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    f.headerItem:SetPoint("TOPLEFT", 14, -108)

    f.headerCount = f:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    f.headerCount:SetPoint("TOPRIGHT", -38, -108)

    -- What to show: only the materials, or everything.
    f.kindChips = {}
    for index, kind in ipairs({ "all", "materials" }) do
        local chip = DW.CreateChip(f, 100, 26)
        chip:SetPoint("TOPRIGHT", -14 - (index - 1) * 106, -76)
        chip.label:SetJustifyH("CENTER")
        chip:SetScript("OnClick", function()
            db.kind = (kind == "all") and "all" or nil
            RefreshPanel()
        end)
        f.kindChips[kind] = chip
    end

    -- The gold, in the header row. Hover to see it per character.
    f.goldBox = CreateFrame("Frame", nil, f)
    f.goldBox:SetSize(260, 16)
    f.goldBox:SetPoint("TOPRIGHT", -130, -106)
    f.goldBox:EnableMouse(true)
    f.gold = f.goldBox:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    f.gold:SetAllPoints(f.goldBox)
    f.gold:SetJustifyH("RIGHT")
    f.goldBox:SetScript("OnEnter", function(self)
        GameTooltip:SetOwner(self, "ANCHOR_BOTTOM")
        GameTooltip:AddLine(L.MAT_GOLD_TITLE)
        local unknown = false
        for _, key in ipairs(SortedCharacterKeys()) do
            local money = db.characters[key].money
            if type(money) == "number" then
                GameTooltip:AddDoubleLine(DisplayName(key), Money(money), 1, 1, 1, 1, 1, 1)
            else
                unknown = true
            end
        end
        if unknown then
            GameTooltip:AddLine(L.MAT_GOLD_UNKNOWN, 0.75, 0.75, 0.75, true)
        end
        GameTooltip:Show()
    end)
    f.goldBox:SetScript("OnLeave", function()
        GameTooltip:Hide()
    end)

    local scroll = CreateFrame("ScrollFrame", "DragonworldMaterialerScroll", f, "ScrollFrameTemplate")
    scroll:SetPoint("TOPLEFT", 10, -124)
    scroll:SetPoint("BOTTOMRIGHT", -30, 34)

    f.content = CreateFrame("Frame", nil, scroll)
    f.content:SetSize(parent:GetWidth() - 10 - 30, 1)
    scroll:SetScrollChild(f.content)

    f.empty = f:CreateFontString(nil, "OVERLAY", "GameFontDisable")
    f.empty:SetPoint("TOP", scroll, "TOP", 0, -40)
    f.empty:SetWidth(360)

    f.footer = f:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    f.footer:SetPoint("BOTTOMLEFT", 14, 12)
    f.footer:SetPoint("BOTTOMRIGHT", -14, 12)
    f.footer:SetJustifyH("LEFT")
    f.footer:SetWordWrap(false)

    f:SetScript("OnShow", function()
        -- Read the bags again every time the panel opens, so the numbers are fresh.
        if DW.HasAccess() then
            Scan()
        end
        RefreshPanel()
    end)

    panel = f
    return f
end

-- Events ----------------------------------------------------------------------

-- Bag changes often come several in a row. Collect them and read once.
local scanQueued = false

local function QueueScan()
    if scanQueued then
        return
    end
    if not (C_Timer and C_Timer.After) then
        Scan()
        RefreshPanel()
        return
    end
    scanQueued = true
    C_Timer.After(0.3, function()
        scanQueued = false
        if DW.HasAccess() then
            Scan()
            RefreshPanel()
        end
    end)
end

local frame = CreateFrame("Frame")

frame:SetScript("OnEvent", function(self, event, itemID)
    if not DW.HasAccess() then
        return
    end

    if event == "PLAYER_MONEY" then
        local character = CurrentCharacter()
        if character then
            ReadMoney(character)
            RefreshPanel()
        end
    elseif event == "BANKFRAME_OPENED" then
        bankOpen = true
        QueueScan()
    elseif event == "BANKFRAME_CLOSED" then
        bankOpen = false
    elseif event == "GET_ITEM_INFO_RECEIVED" then
        -- The game has loaded an item we were waiting for the name of.
        if type(itemID) == "number" and waitingForName[itemID] then
            RememberItem(itemID)
            QueueScan()
        end
    elseif event:find("^TRADE_SKILL_") then
        -- A crafting window is open: learn which materials the recipes use.
        -- If we learned something new, more items in the bags may now count as materials.
        if LearnReagents() then
            QueueScan()
        end
    else
        QueueScan()
    end
end)

for _, event in ipairs({
    "PLAYER_ENTERING_WORLD",
    "BAG_UPDATE_DELAYED",
    "PLAYERBANKSLOTS_CHANGED",
    "BANKFRAME_OPENED",
    "BANKFRAME_CLOSED",
    "GET_ITEM_INFO_RECEIVED",
    "PLAYER_MONEY",
    "TRADE_SKILL_SHOW",
    "TRADE_SKILL_LIST_UPDATE",
    "TRADE_SKILL_DATA_SOURCE_CHANGED",
}) do
    pcall(frame.RegisterEvent, frame, event)
end

-- If the tab is unlocked after login (the guild name loads late), read then.
DW.OnAccessChanged(function(access)
    if access then
        QueueScan()
    end
end)

DW.OnLanguageChanged(function()
    RefreshPanel()
end)

-- Debugging: whether the game lets us read recipes, and what we have learned.
DW.AddDebug("materialer", function(add)
    local text = DW.DebugText
    local ui = C_TradeSkillUI
    add("GetAllRecipeIDs: " .. text(ui ~= nil and ui.GetAllRecipeIDs ~= nil)
        .. " | GetRecipeSchematic: " .. text(ui ~= nil and ui.GetRecipeSchematic ~= nil))
    local items, perProfession = 0, {}
    for _, professions in pairs(db.reagents) do
        if type(professions) == "table" then
            items = items + 1
            for name in pairs(professions) do
                perProfession[name] = (perProfession[name] or 0) + 1
            end
        end
    end
    local parts = {}
    for name, count in pairs(perProfession) do
        parts[#parts + 1] = ("%s %d"):format(name, count)
    end
    table.sort(parts)
    add(("materialer lært fra oppskrifter: %d (%s)"):format(items, #parts > 0 and table.concat(parts, ", ") or "ingen"))
end)

-- Module -------------------------------------------------------------------------

DW.RegisterModule({
    id = MODULE_ID,
    personal = true, -- alts outside the guild may use it (Core.lua)
    titleKey = "MAT_TITLE",
    notesKey = "MAT_NOTES",
    icon = "Interface\\Icons\\Trade_BlackSmithing",

    OnLoad = function(self, saved)
        if type(saved.characters) ~= "table" then
            saved.characters = {}
        end
        if type(saved.items) ~= "table" then
            saved.items = {}
        end
        if type(saved.reagents) ~= "table" then
            saved.reagents = {}
        end
        db = saved
    end,

    CreatePanel = function(self, parent)
        return CreatePanel(parent)
    end,
})
