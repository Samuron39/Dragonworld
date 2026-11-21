-- Dragonworld - Materialer
-- Holder oversikt over håndverksmaterialer på alle karakterene dine, både i
-- baggene og i banken, og viser dem samlet i hovedvinduet. Du kan filtrere på
-- hvor de ligger (alle, i bagger, i bank) og på karakter.
--
-- Slik samles tallene inn:
--   * Baggene leses når du logger inn og hver gang innholdet endrer seg.
--   * Banken kan bare leses mens den er åpen. Den leses da, og tallene huskes
--     til neste gang du åpner den.
--   * Alt lagres per karakter, felles for hele kontoen, så du ser de andre
--     karakterene dine også. En karakter kommer først med etter at du har vært
--     logget inn på den med addonen (og åpnet banken der).
--
-- Som "materiale" regnes gjenstander spillet selv kaller Trade Goods, ting det
-- har merket som håndverksmateriale, og ting en oppskrift bruker (se under).
--
-- Tooltipen på et materiale sier at det er et håndverksmateriale, og hvilke
-- professions som bruker det:
--   * Hver gang et håndverksvindu er åpent (ditt eget, eller en annens
--     profession du har åpnet fra Medlemmer), leser addonen oppskriftene i det
--     og husker hvilke materialer de bruker. Det huskes for hele kontoen.
--   * For materialer ingen åpnet profession har brukt ennå, gjetter vi ut fra
--     typen spillet gir dem (Cloth, Herb, Metal & Stone ...), og skriver
--     "som regel" foran.
--
-- All tekst ligger i Locales.lua (navnene som begynner med MAT_).

local ADDON_NAME, DW = ...
local L = DW.L

local MODULE_ID = "materialer"

local ITEM_CLASS_TRADEGOODS = (Enum and Enum.ItemClass and Enum.ItemClass.Tradegoods) or 7
local LAST_BAG = NUM_TOTAL_EQUIPPED_BAG_SLOTS or NUM_BAG_SLOTS or 4
local GetItemInfo = (C_Item and C_Item.GetItemInfo) or GetItemInfo

-- Lagrede data. Settes i OnLoad nederst.
--   db.characters["Navn-Realm"] = {
--       name, realm, class,
--       bags = { [itemID] = antall }, bagsTime = tidspunkt,
--       bank = { [itemID] = antall }, bankTime = tidspunkt eller nil,
--   }
--   db.items[itemID] = { name, quality }   navn vi har sett, så gjenstander på
--                                          andre karakterer kan vises med navn
--   db.reagents[itemID] = { [profession] = true }   hvilke professions som
--                                          bruker materialet, lest fra oppskrifter
local db = { characters = {}, items = {}, reagents = {} }

-- Hva materialene brukes til ------------------------------------------------------

-- Spillets nummer på hver profession, og det engelske navnet hvis spillet ikke
-- kan gi oss navnet selv.
local PROFESSION_NAMES = {
    [129] = "First Aid", [164] = "Blacksmithing", [165] = "Leatherworking", [171] = "Alchemy",
    [185] = "Cooking", [186] = "Mining", [197] = "Tailoring", [202] = "Engineering",
    [333] = "Enchanting", [755] = "Jewelcrafting", [773] = "Inscription",
}

-- Gjetningen ut fra typen (undertypen av Trade Goods): hvilke professions som
-- som regel bruker slike materialer. Typer som brukes av nesten alle
-- (Elemental, Other) er ikke med.
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

-- Innsamling ------------------------------------------------------------------

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

local materialCache = {} -- [itemID] = true/false, bare når vi vet sikkert

local function IsMaterial(itemID)
    if type(db.reagents[itemID]) == "table" and next(db.reagents[itemID]) then
        return true -- en oppskrift bruker den
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

    -- Resten krever at spillet har lastet gjenstanden. Har det ikke det ennå,
    -- sier vi nei nå uten å huske svaret, og prøver igjen ved neste lesing.
    local name = GetItemInfo(itemID)
    if type(name) ~= "string" then
        return false
    end
    local isCraftingReagent = select(17, GetItemInfo(itemID))
    materialCache[itemID] = (isCraftingReagent == true)
    return materialCache[itemID]
end

-- Er gjenstanden et håndverksmateriale, og hvilke professions bruker det?
-- Returnerer nil hvis den ikke er et materiale, ellers:
--   professions = { "Blacksmithing", ... }, sortert (kan være tom)
--   usually     = true når listen er gjettet ut fra typen
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

-- Leser oppskriftene i håndverksvinduet som er åpent, og husker hvilke
-- materialer professionen bruker. Returnerer true hvis vi lærte noe nytt.
local readThisSession = {} -- [profession] = antall oppskrifter vi har lest

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
    -- Vinduet melder seg ofte (f.eks. for hver ting du lager). Les bare på
    -- nytt hvis det er kommet til oppskrifter.
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

local waitingForName = {} -- [itemID] = true mens vi venter på at spillet laster navnet

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

-- Teller materialene i de oppgitte plassene. Returnerer også hvor mange
-- plasser som fantes, så vi kan se forskjell på "tomt" og "ikke tilgjengelig".
local function CountMaterials(containers)
    local counts, slots = {}, 0
    for _, bag in ipairs(containers) do
        local size = C_Container.GetContainerNumSlots(bag) or 0
        slots = slots + size
        for slot = 1, size do
            local itemID = C_Container.GetContainerItemID(bag, slot)
            if itemID and IsMaterial(itemID) then
                local info = C_Container.GetContainerItemInfo and C_Container.GetContainerItemInfo(bag, slot)
                local count = (type(info) == "table" and info.stackCount) or 1
                counts[itemID] = (counts[itemID] or 0) + count
                RememberItem(itemID)
            end
        end
    end
    return counts, slots
end

-- Oppføringen for karakteren du er logget inn på. Lages hvis den mangler.
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

    character.bags = CountMaterials(BAG_CONTAINERS)
    character.bagsTime = time()

    if bankOpen then
        local counts, slots = CountMaterials(BankContainers())
        -- Fant vi ingen bankplasser, er banken ikke lesbar akkurat nå. Da
        -- beholder vi det vi husket, i stedet for å tro at den er tom.
        if slots > 0 then
            character.bank = counts
            character.bankTime = time()
        end
    end
end

-- Tooltip ---------------------------------------------------------------------

-- Klienten kan melde samme gjenstand to ganger for én tooltip. Her husker vi
-- hvilken gjenstand hver tooltip allerede har fått linjene for.
local shownItem = {}

local function OnTooltipItem(tooltip, data)
    if not DW.IsMember() then
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

-- Visning ---------------------------------------------------------------------

local ROW_HEIGHT = 24
local FALLBACK_ICON = 134400 -- spørsmålstegn

local panel -- lages første gang modulen velges i hovedvinduet
local rows = {}
local RefreshPanel

local filterSource = "all" -- "all", "bags" eller "bank"
local filterCharacter      -- nøkkelen til én karakter, eller nil for alle
local searchText = ""      -- det som står i søkefeltet

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

-- Bare navnet, med realm bak hvis to karakterer heter det samme.
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

-- Summerer materialene etter gjeldende filter. Én oppføring per gjenstand,
-- sortert på navn.
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
                Add(character.bags)
            end
            if filterSource ~= "bags" then
                Add(character.bank)
            end
        end
    end

    -- Søket ser bort fra store/små bokstaver og mellomrom foran og bak, og
    -- leter etter teksten hvor som helst i navnet.
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
                RememberItem(itemID) -- ber spillet laste navnet
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

-- Menyen for valg av karakter. data er nøkkelen, eller false for "alle".
local function OpenCharacterMenu(owner)
    local keys = SortedCharacterKeys()

    if not (MenuUtil and MenuUtil.CreateContextMenu) then
        -- Uten meny: gå til neste karakter for hvert klikk, og til slutt alle.
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

    -- Hold over raden for å se gjenstanden og hvor den ligger, per karakter.
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
            local inBags = (type(character.bags) == "table" and character.bags[entry.itemID]) or 0
            local inBank = (type(character.bank) == "table" and character.bank[entry.itemID]) or 0
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

    -- Karakteren som var valgt kan være borte fra lagringen.
    if filterCharacter and type(db.characters[filterCharacter]) ~= "table" then
        filterCharacter = nil
    end

    panel.title:SetText(L.MAT_PANEL_TITLE)
    panel.searchLabel:SetText(L.MAT_SEARCH)
    panel.headerItem:SetText(L.MAT_HEADER_ITEM)
    panel.headerCount:SetText(L.MAT_HEADER_COUNT)
    panel.empty:SetText(L.MAT_EMPTY)

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

    -- Nederst: når banken til denne karakteren sist ble lest.
    local character = CurrentCharacter()
    if character and character.bankTime then
        panel.footer:SetText(L.MAT_BANK_SEEN:format(date("%d.%m.%Y %H:%M", character.bankTime)))
    else
        panel.footer:SetText(L.MAT_BANK_NEVER)
    end
end

-- Kalles av hovedvinduet første gang modulen velges.
local function CreatePanel(parent)
    local f = CreateFrame("Frame", nil, parent)
    f:SetAllPoints(parent)

    f.title = f:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
    f.title:SetPoint("TOP", 0, -12)

    -- Filter: hvor materialene ligger.
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

    -- Filter: hvilken karakter.
    f.characterChip = DW.CreateChip(f, 230, 26)
    f.characterChip:SetPoint("TOPRIGHT", -14, -40)
    f.characterChip:SetScript("OnClick", function(self)
        OpenCharacterMenu(self)
    end)

    -- Søkefelt: listen snevres inn mens du skriver.
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
        -- Les baggene på nytt hver gang panelet åpnes, så tallene er ferske.
        if DW.IsMember() then
            Scan()
        end
        RefreshPanel()
    end)

    panel = f
    return f
end

-- Hendelser -------------------------------------------------------------------

-- Bag-endringer kommer ofte flere på rad. Samle dem opp og les én gang.
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
        if DW.IsMember() then
            Scan()
            RefreshPanel()
        end
    end)
end

local frame = CreateFrame("Frame")

frame:SetScript("OnEvent", function(self, event, itemID)
    if not DW.IsMember() then
        return
    end

    if event == "BANKFRAME_OPENED" then
        bankOpen = true
        QueueScan()
    elseif event == "BANKFRAME_CLOSED" then
        bankOpen = false
    elseif event == "GET_ITEM_INFO_RECEIVED" then
        -- Spillet har lastet en gjenstand vi ventet på navnet til.
        if type(itemID) == "number" and waitingForName[itemID] then
            RememberItem(itemID)
            QueueScan()
        end
    elseif event:find("^TRADE_SKILL_") then
        -- Et håndverksvindu er åpent: lær hvilke materialer oppskriftene bruker.
        -- Lærte vi noe nytt, kan flere ting i baggene nå regnes som materialer.
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
    "TRADE_SKILL_SHOW",
    "TRADE_SKILL_LIST_UPDATE",
    "TRADE_SKILL_DATA_SOURCE_CHANGED",
}) do
    pcall(frame.RegisterEvent, frame, event)
end

-- Blir karakteren medlem etter innlogging (guild-navnet lastes sent), les da.
DW.OnMembershipChanged(function(member)
    if member then
        QueueScan()
    end
end)

DW.OnLanguageChanged(function()
    RefreshPanel()
end)

-- Feilsøking: om spillet lar oss lese oppskrifter, og hva vi har lært.
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

-- Modul --------------------------------------------------------------------------

DW.RegisterModule({
    id = MODULE_ID,
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
