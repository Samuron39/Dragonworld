-- Dragonworld - oppskriftsvindu
-- Klikk på en profession i Medlemmer (eller på medlemskortet), så kommer dette
-- vinduet opp over hovedvinduet med alt medlemmet kan lage i den professionen:
--   * hva oppskriften lager (ikon og navn i gjenstandens farge)
--   * hva den trenger
--   * søk i listen
-- Hold over en oppskrift for gjenstanden. Klikk for å hviske medlemmet om den
-- (med lenken klar i chatten), shift-klikk for å lenke den i chatten.
--
-- Listen kommer fra medlemmets egen addon (Roster.lua leser den når de åpner
-- professionen sin, og sender den til guilden), så den vises også når
-- medlemmet er avlogget. Spillets eget vindu kan åpnes med en knapp når
-- medlemmet har delt lenken til professionen, men mellom to spillere åpnet
-- den ingenting i Forever.
--
-- Hva en oppskrift lager og trenger spør vi spillet om først
-- (GetRecipeSchematic), så Wowhead-dataene i ProfessionData.lua, og til slutt
-- bare navnet på oppskriften.
--
-- All tekst ligger i Locales.lua (navnene som begynner med RC_).

local ADDON_NAME, DW = ...
local L = DW.L

local VIEW_NAME = "DragonworldRecipes"
local ROW_HEIGHT = 20
local NAME_WIDTH = 290
local MAX_SHOWN_REAGENTS = 4

local view
local member, profession -- det som vises
local rows = {}
local searchText = ""
local waitingFor = {}    -- gjenstander vi har bedt spillet laste

-- Gjenstander og oppskrifter -------------------------------------------------------

local function Data()
    return DW.ProfessionData or {}
end

-- Navn, kvalitet, ikon og lenke for en gjenstand. Navnet kan mangle til
-- spillet har lastet gjenstanden; da brukes Wowhead-navnet om vi har det.
local function ItemInfo(itemID)
    local name, link, quality
    if C_Item and C_Item.GetItemInfo then
        local ok, n, l, q = pcall(C_Item.GetItemInfo, itemID)
        if ok and type(n) == "string" and not DW.IsSecret(n) then
            name, link, quality = n, l, q
        end
    end
    local icon
    if C_Item and C_Item.GetItemInfoInstant then
        local ok, _, _, _, _, i = pcall(C_Item.GetItemInfoInstant, itemID)
        if ok then
            icon = i
        end
    end
    if not name then
        if not waitingFor[itemID] and C_Item and C_Item.RequestLoadItemDataByID then
            waitingFor[itemID] = true
            pcall(C_Item.RequestLoadItemDataByID, itemID)
        end
        local known = Data().items and Data().items[itemID]
        name = type(known) == "table" and known[1] or nil
        quality = type(known) == "table" and known[2] or nil
    end
    return name, quality, icon, link
end

local details = {} -- [oppskrift] = { name, icon, itemID, reagents = { { itemID, antall } } }

local function RecipeDetails(id)
    if details[id] then
        return details[id]
    end
    local info = { reagents = {} }

    -- 1. Spillet selv.
    local ui = C_TradeSkillUI
    if ui and ui.GetRecipeSchematic then
        local ok, schematic = pcall(ui.GetRecipeSchematic, id, false)
        if ok and type(schematic) == "table" then
            if type(schematic.name) == "string" and schematic.name ~= "" and not DW.IsSecret(schematic.name) then
                info.name = schematic.name
            end
            if (type(schematic.icon) == "number" or type(schematic.icon) == "string") and not DW.IsSecret(schematic.icon) then
                info.icon = schematic.icon
            end
            if type(schematic.outputItemID) == "number" and schematic.outputItemID > 0 then
                info.itemID = schematic.outputItemID
            end
            for _, slot in ipairs(type(schematic.reagentSlotSchematics) == "table" and schematic.reagentSlotSchematics or {}) do
                local reagent = type(slot) == "table" and type(slot.reagents) == "table" and slot.reagents[1]
                if type(reagent) == "table" and type(reagent.itemID) == "number" and type(slot.quantityRequired) == "number"
                    and slot.quantityRequired > 0 and slot.required ~= false then
                    info.reagents[#info.reagents + 1] = { reagent.itemID, slot.quantityRequired }
                end
            end
        end
    end

    -- 2. Wowhead-dataene (ProfessionData.lua).
    local data = Data().recipes and Data().recipes[id]
    if type(data) == "table" then
        info.name = info.name or data[1]
        info.itemID = info.itemID or data.creates
        if #info.reagents == 0 and type(data[4]) == "table" then
            for _, reagent in ipairs(data[4]) do
                info.reagents[#info.reagents + 1] = { reagent[1], reagent[2] }
            end
        end
    end

    -- 3. Navnet på oppskriften.
    local spellName = DW.SpellName(id)
    info.name = info.name or spellName
    if not info.icon and C_Spell and C_Spell.GetSpellTexture then
        local ok, texture = pcall(C_Spell.GetSpellTexture, id)
        if ok and texture and not DW.IsSecret(texture) then
            info.icon = texture
        end
    end

    -- Et navn spillet ikke hadde ennå ("#1234") huskes ikke, så det prøves igjen.
    if info.name:sub(1, 1) ~= "#" then
        details[id] = info
    end
    return info
end

-- "6 Copper Bar, 2 Rough Grit"
local function ReagentText(reagents)
    local parts = {}
    for index, reagent in ipairs(reagents) do
        if index > MAX_SHOWN_REAGENTS then
            parts[#parts + 1] = "..."
            break
        end
        local name = ItemInfo(reagent[1]) or ("#" .. reagent[1])
        parts[#parts + 1] = ("%d %s"):format(reagent[2], name)
    end
    return table.concat(parts, ", ")
end

-- Lenken til det oppskriften lager (eller til oppskriften selv).
local function RecipeLink(id, info)
    if info.itemID then
        local _, _, _, link = ItemInfo(info.itemID)
        if type(link) == "string" then
            return link
        end
    end
    if C_Spell and C_Spell.GetSpellLink then
        local ok, link = pcall(C_Spell.GetSpellLink, id)
        if ok and type(link) == "string" and not DW.IsSecret(link) then
            return link
        end
    end
    return nil
end

-- Chatten ---------------------------------------------------------------------

local function InsertLink(link)
    if ChatFrameUtil and ChatFrameUtil.InsertLink then
        return ChatFrameUtil.InsertLink(link)
    elseif ChatEdit_InsertLink then
        return ChatEdit_InsertLink(link)
    end
    return false
end

-- Legger lenken i chatten; er ingen chatlinje åpen, åpnes en.
local function LinkInChat(link)
    if InsertLink(link) then
        return
    end
    if ChatFrameUtil and ChatFrameUtil.OpenChat then
        ChatFrameUtil.OpenChat(link)
    elseif ChatFrame_OpenChat then
        ChatFrame_OpenChat(link)
    end
end

local function IsMe(who)
    local guid = DW.MyGUID()
    return guid ~= nil and who.guid == guid
end

local function CanWhisper(who)
    return who.online and not IsMe(who)
end

local function Whisper(name)
    if ChatFrameUtil and ChatFrameUtil.SendTell then
        ChatFrameUtil.SendTell(name)
    elseif ChatFrame_SendTell then
        ChatFrame_SendTell(name)
    else
        DW.Print("/w " .. name)
    end
end

-- Visning ---------------------------------------------------------------------

local function ProfessionLabel(p)
    if (p.max or 0) > 0 then
        return ("%s %d/%d"):format(p.name, p.level or 0, p.max)
    end
    return ("%s %d"):format(p.name, p.level or 0)
end

local Refresh

local function GetRow(index)
    local row = rows[index]
    if row then
        return row
    end
    row = CreateFrame("Button", nil, view.content)
    row:SetSize(view.content:GetWidth(), ROW_HEIGHT)
    row:SetPoint("TOPLEFT", 0, -(index - 1) * ROW_HEIGHT)
    row:RegisterForClicks("LeftButtonUp")
    row:SetHighlightTexture("Interface\\QuestFrame\\UI-QuestTitleHighlight", "ADD")

    row.icon = row:CreateTexture(nil, "ARTWORK")
    row.icon:SetSize(16, 16)
    row.icon:SetPoint("LEFT", 4, 0)
    row.icon:SetTexCoord(0.07, 0.93, 0.07, 0.93)

    row.name = row:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
    row.name:SetPoint("LEFT", row.icon, "RIGHT", 6, 0)
    row.name:SetWidth(NAME_WIDTH)
    row.name:SetJustifyH("LEFT")
    row.name:SetWordWrap(false)

    row.reagents = row:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
    row.reagents:SetPoint("LEFT", row.name, "RIGHT", 10, 0)
    row.reagents:SetPoint("RIGHT", -4, 0)
    row.reagents:SetJustifyH("LEFT")
    row.reagents:SetWordWrap(false)

    row:SetScript("OnEnter", function(self)
        local info = self.info
        if not info then
            return
        end
        GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
        if info.itemID and GameTooltip.SetItemByID then
            GameTooltip:SetItemByID(info.itemID)
        elseif GameTooltip.SetSpellByID then
            GameTooltip:SetSpellByID(self.recipe)
        else
            GameTooltip:AddLine(info.name, 1, 1, 1)
        end
        if #info.reagents > 0 then
            GameTooltip:AddLine(" ")
            GameTooltip:AddLine(L.RC_REAGENTS, 1.00, 0.82, 0.00)
            for _, reagent in ipairs(info.reagents) do
                GameTooltip:AddLine(("%d x %s"):format(reagent[2], ItemInfo(reagent[1]) or ("#" .. reagent[1])), 1, 1, 1)
            end
        end
        GameTooltip:AddLine(" ")
        if member and CanWhisper(member) then
            GameTooltip:AddLine(L.RC_TIP_WHISPER:format(member.name), 0.60, 0.60, 0.60, true)
        end
        GameTooltip:AddLine(L.RC_TIP_LINK, 0.60, 0.60, 0.60, true)
        GameTooltip:Show()
    end)
    row:SetScript("OnLeave", function()
        GameTooltip:Hide()
    end)
    row:SetScript("OnClick", function(self)
        local info = self.info
        if not info or not member then
            return
        end
        local link = RecipeLink(self.recipe, info)
        local shift = (type(IsModifiedClick) == "function" and IsModifiedClick("CHATLINK"))
            or (type(IsShiftKeyDown) == "function" and IsShiftKeyDown())
        if shift then
            if link then
                LinkInChat(link)
            end
        elseif CanWhisper(member) then
            -- Hvisk medlemmet, med det du vil ha laget klart i chatlinjen.
            Whisper(member.key)
            if link then
                InsertLink(link)
            end
        end
    end)

    rows[index] = row
    return row
end

Refresh = function()
    if not view or not view:IsShown() or not member or not profession then
        return
    end

    view.title:SetText(L.RC_TITLE:format(member.name, ProfessionLabel(profession)))
    view.searchLabel:SetText(L.RC_SEARCH)
    view.gameButton.label:SetText(L.RC_OPEN_GAME)
    view.whisper.label:SetText(L.RC_WHISPER)
    view.close.label:SetText(L.RC_CLOSE)
    view.gameButton:SetShown(DW.CanOpenMemberProfession ~= nil and DW.CanOpenMemberProfession(member, profession))
    view.whisper:SetShown(CanWhisper(member))

    local ids, changed = nil, nil
    if DW.MemberRecipes then
        ids, changed = DW.MemberRecipes(member, profession)
    end

    -- Oppskriftene som passer søket, sortert på navn.
    local needle = searchText:lower():gsub("^%s+", ""):gsub("%s+$", "")
    local list = {}
    for _, id in ipairs(ids or {}) do
        local info = RecipeDetails(id)
        if needle == "" or info.name:lower():find(needle, 1, true) then
            list[#list + 1] = { id = id, info = info }
        end
    end
    table.sort(list, function(a, b)
        if a.info.name ~= b.info.name then
            return a.info.name < b.info.name
        end
        return a.id < b.id
    end)

    if ids then
        view.info:SetText(L.RC_COUNT:format(#ids, date("%d.%m.%Y %H:%M", changed or 0)))
    else
        view.info:SetText("")
    end

    for index, entry in ipairs(list) do
        local row = GetRow(index)
        local info = entry.info
        row.recipe, row.info = entry.id, info
        local itemName, quality, itemIcon
        if info.itemID then
            itemName, quality, itemIcon = ItemInfo(info.itemID)
        end
        row.icon:SetTexture(itemIcon or info.icon or 134400)
        row.name:SetText(info.name)
        local colour = ITEM_QUALITY_COLORS and quality and ITEM_QUALITY_COLORS[quality]
        if colour then
            row.name:SetTextColor(colour.r, colour.g, colour.b)
        else
            row.name:SetTextColor(1, 1, 1)
        end
        row.reagents:SetText(ReagentText(info.reagents))
        row:Show()
    end
    for index = #list + 1, #rows do
        rows[index].recipe, rows[index].info = nil, nil
        rows[index]:Hide()
    end
    view.content:SetHeight(math.max(1, #list * ROW_HEIGHT))

    if not ids then
        view.empty:SetText(L.RC_NONE:format(member.name, profession.name))
    elseif #list == 0 then
        view.empty:SetText(L.RC_NO_MATCH)
    end
    view.empty:SetShown(not ids or #list == 0)
end

local function CreateView(window)
    local f = CreateFrame("Frame", VIEW_NAME, window, "BackdropTemplate")
    f:SetPoint("TOPLEFT", 14, -92)
    f:SetSize(window:GetWidth() - 28, window:GetHeight() - 92 - 14)
    f:SetFrameStrata("DIALOG")
    -- Over medlemskortet, som det ofte åpnes fra.
    f:SetFrameLevel(window:GetFrameLevel() + 40)
    f:EnableMouse(true)
    f:SetBackdrop(DW.PANEL_BACKDROP)
    f:SetBackdropColor(0.05, 0.05, 0.07, 1)
    f:SetBackdropBorderColor(1.00, 0.82, 0.00, 1)
    f.solid = f:CreateTexture(nil, "BACKGROUND")
    f.solid:SetPoint("TOPLEFT", 3, -3)
    f.solid:SetPoint("BOTTOMRIGHT", -3, 3)
    f.solid:SetColorTexture(0.05, 0.05, 0.07, 1)
    f:Hide()
    view = f

    f.title = f:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
    f.title:SetPoint("TOPLEFT", 16, -14)
    f.title:SetWidth(f:GetWidth() - 16 - 300) -- søkefeltet står til høyre
    f.title:SetJustifyH("LEFT")
    f.title:SetWordWrap(false)

    f.info = f:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    f.info:SetPoint("TOPLEFT", 16, -40)

    -- Søk i listen mens du skriver.
    f.searchBox = CreateFrame("EditBox", nil, f, "InputBoxTemplate")
    f.searchBox:SetSize(180, 22)
    f.searchBox:SetPoint("TOPRIGHT", -40, -16)
    f.searchBox:SetAutoFocus(false)
    f.searchBox:SetMaxLetters(40)
    f.searchBox:SetScript("OnEscapePressed", function(self)
        self:ClearFocus()
    end)
    f.searchBox:SetScript("OnEnterPressed", function(self)
        self:ClearFocus()
    end)
    f.searchBox:HookScript("OnTextChanged", function(self)
        searchText = self:GetText() or ""
        Refresh()
    end)
    f.searchLabel = f:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    f.searchLabel:SetPoint("RIGHT", f.searchBox, "LEFT", -10, 0)

    local scroll = CreateFrame("ScrollFrame", "DragonworldRecipeScroll", f, "ScrollFrameTemplate")
    scroll:SetPoint("TOPLEFT", 16, -64)
    scroll:SetPoint("BOTTOMRIGHT", -34, 48)
    f.content = CreateFrame("Frame", nil, scroll)
    f.content:SetSize(f:GetWidth() - 16 - 34, 1)
    scroll:SetScrollChild(f.content)

    f.empty = f:CreateFontString(nil, "OVERLAY", "GameFontDisable")
    f.empty:SetPoint("TOP", scroll, "TOP", 0, -40)
    f.empty:SetWidth(460)

    local closeX = CreateFrame("Button", nil, f, "UIPanelCloseButton")
    closeX:SetPoint("TOPRIGHT", -2, -2)

    -- Knapper nederst.
    f.gameButton = DW.CreateChip(f, 170, 26)
    f.gameButton:SetPoint("BOTTOMLEFT", 16, 12)
    f.gameButton.label:SetJustifyH("CENTER")
    f.gameButton:SetScript("OnClick", function()
        if member and profession and DW.OpenMemberProfession then
            DW.OpenMemberProfession(member, profession)
        end
    end)
    f.gameButton:HookScript("OnEnter", function(self)
        GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
        GameTooltip:AddLine(L.RC_OPEN_GAME_TIP, 1, 1, 1, true)
        GameTooltip:Show()
    end)
    f.gameButton:HookScript("OnLeave", function()
        GameTooltip:Hide()
    end)

    f.whisper = DW.CreateChip(f, 110, 26)
    f.whisper:SetPoint("BOTTOMLEFT", 194, 12)
    f.whisper.label:SetJustifyH("CENTER")
    f.whisper:SetScript("OnClick", function()
        if member then
            Whisper(member.key)
        end
    end)

    f.close = DW.CreateChip(f, 100, 26)
    f.close:SetPoint("BOTTOMRIGHT", -16, 12)
    f.close.label:SetJustifyH("CENTER")
    f.close:SetScript("OnClick", function()
        f:Hide()
    end)

    return f
end

-- Viser hva et medlem kan lage i en profession. member er en rad fra
-- Medlemmer (med professions og det som er delt), profession én av dem.
function DW.ShowRecipes(who, which)
    local window = _G.DragonworldFrame
    if not window or type(who) ~= "table" or type(which) ~= "table" then
        return
    end
    if not view then
        CreateView(window)
    end
    if _G.DragonworldDungeonPicker then
        _G.DragonworldDungeonPicker:Hide()
    end
    member, profession = who, which
    searchText = ""
    view.searchBox:SetText("")
    view:Show()
    Refresh()
end

-- Hendelser -------------------------------------------------------------------

local refreshQueued = false

local function QueueRefresh()
    if refreshQueued or not view or not view:IsShown() then
        return
    end
    refreshQueued = true
    C_Timer.After(0.2, function()
        refreshQueued = false
        Refresh()
    end)
end

local frame = CreateFrame("Frame")
frame:SetScript("OnEvent", function(self, event, itemID)
    if event == "GET_ITEM_INFO_RECEIVED" and type(itemID) == "number" and waitingFor[itemID] then
        waitingFor[itemID] = nil
        QueueRefresh()
    end
end)
pcall(frame.RegisterEvent, frame, "GET_ITEM_INFO_RECEIVED")

if DW.OnRecipesChanged then
    DW.OnRecipesChanged(QueueRefresh)
end
DW.OnLanguageChanged(Refresh)
DW.OnMembershipChanged(function(isMember)
    if not isMember and view then
        view:Hide()
    end
end)
