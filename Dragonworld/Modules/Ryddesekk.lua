-- Dragonworld - Ryddesekk
-- Legger til en linje i tooltipen på quest-gjenstander i baggen som forteller
-- om gjenstanden fortsatt trengs, eller om den kan kastes. I hovedvinduet
-- lister den det som kan kastes, med en avkrysningsboks for det du vil beholde.
--
-- Slik avgjøres det, i denne rekkefølgen:
--   1. Har du selv merket gjenstanden, gjelder det.
--   2. Nevnes gjenstanden i en quest du har i questloggen, trengs den fortsatt.
--   3. Er den et håndverksmateriale, skal den ikke kastes. Hvilke professions
--      som bruker den, skriver Materialer-modulen i tooltipen.
--   4. Er den ikke bundet til deg, kan den selges på auksjon eller gis bort,
--      og skal heller ikke kastes.
--   5. Starter gjenstanden en quest du allerede har fullført, kan den kastes.
--   6. Er det en quest-gjenstand som ingen av questene dine nevner, kan den
--      trolig kastes.
-- Spillet oppgir ikke hvilken quest en gjenstand hører til, så punkt 6 er et
-- kvalifisert gjett. Derfor står det "trolig".
--
-- All tekst ligger i Locales.lua (navnene som begynner med RS_).

local ADDON_NAME, DW = ...
local L = DW.L

local MODULE_ID = "ryddesekk"

local STATUS_TRASH, STATUS_MAYBE, STATUS_UNSURE, STATUS_KEEP = 1, 2, 3, 4
local STATUS_MATERIAL, STATUS_SELLABLE = 5, 6

-- Tekst (navnet i Locales.lua) og farge for hver status.
local DISPLAY = {
    [STATUS_TRASH]    = { key = "RS_STATUS_TRASH",    r = 0.25, g = 1.00, b = 0.25, hex = "40ff40" },
    [STATUS_MAYBE]    = { key = "RS_STATUS_MAYBE",    r = 1.00, g = 0.82, b = 0.00, hex = "ffd100" },
    [STATUS_UNSURE]   = { key = "RS_STATUS_UNSURE",   r = 1.00, g = 0.50, b = 0.25, hex = "ff8040" },
    [STATUS_KEEP]     = { key = "RS_STATUS_KEEP",     r = 0.40, g = 0.75, b = 1.00, hex = "66bfff" },
    [STATUS_SELLABLE] = { key = "RS_STATUS_SELLABLE", r = 0.40, g = 0.75, b = 1.00, hex = "66bfff" },
}

-- Det som kan kastes herfra. Alt annet (behold, materiale, kan selges) blir
-- liggende.
local function CanDiscard(status)
    return status == STATUS_TRASH or status == STATUS_MAYBE or status == STATUS_UNSURE
end

local ITEM_CLASS_QUEST = (Enum and Enum.ItemClass and Enum.ItemClass.Questitem) or 12
local ITEM_BIND_QUEST = 4
local QUALITY_UNCOMMON = 2
local LAST_BAG = NUM_TOTAL_EQUIPPED_BAG_SLOTS or NUM_BAG_SLOTS or 4

-- Forever har ikke den gamle globale GetItemInfo, bare C_Item-utgaven.
local GetItemInfo = (C_Item and C_Item.GetItemInfo) or GetItemInfo

-- Egne merker, som huskes mellom økter. Settes i OnLoad nederst.
--   marks[itemID] = "kast" eller "behold"
-- (Verdiene er de samme uansett språk, så merkene overlever et språkbytte.)
local marks = {}

-- Modulens lagrede valg. Settes i OnLoad nederst.
--   settings.includeMaybe = true hvis den gule knappen også skal ta det som
--                           bare er "trolig trygt". Av som standard.
local settings = {}

-- Oversikt over aktive quester. Bygges første gang den trengs, og nullstilles
-- hver gang questloggen endrer seg.
local questCache

local Print = DW.Print
local IsSecret = DW.IsSecret

local function AddText(parts, text)
    if type(text) == "string" and not IsSecret(text) and text ~= "" then
        parts[#parts + 1] = text
    end
end

local function BuildQuestCache()
    local cache = { byItemID = {}, quests = {} }

    for index = 1, (C_QuestLog.GetNumQuestLogEntries() or 0) do
        local info = C_QuestLog.GetInfo(index)
        if info and not info.isHeader and info.questID then
            local title = info.title or "?"
            local parts = {}

            -- Målene i questen, f.eks. "Kobold Candle: 3/8".
            local objectives = C_QuestLog.GetQuestObjectives(info.questID)
            if objectives then
                for _, objective in ipairs(objectives) do
                    AddText(parts, objective.text)
                end
            end

            -- Selve questteksten. Den fanger opp ting du bare skal levere,
            -- f.eks. "Take the Sealed Note to ...".
            if GetQuestLogQuestText then
                local description, summary = GetQuestLogQuestText(index)
                AddText(parts, description)
                AddText(parts, summary)
            end

            -- Gjenstand som brukes i questen (knappen ved siden av questen).
            if GetQuestLogSpecialItemInfo then
                local link = GetQuestLogSpecialItemInfo(index)
                if type(link) == "string" and not IsSecret(link) then
                    local itemID = tonumber(link:match("item:(%d+)"))
                    if itemID then
                        cache.byItemID[itemID] = title
                    end
                end
            end

            cache.quests[#cache.quests + 1] = {
                title = title,
                text = table.concat(parts, "\n"):lower(),
            }
        end
    end

    return cache
end

local function FindInBags(itemID)
    for bag = 0, LAST_BAG do
        for slot = 1, (C_Container.GetContainerNumSlots(bag) or 0) do
            if C_Container.GetContainerItemID(bag, slot) == itemID then
                return bag, slot
            end
        end
    end
end

-- Er gjenstanden bundet til deg? true, false, eller nil når spillet ikke sier
-- det. En gjenstand som ikke er bundet, kan selges på auksjon eller byttes.
local function IsBound(bag, slot, bindType)
    if bindType == ITEM_BIND_QUEST then
        return true -- "Quest Item" er alltid bundet
    end
    local info = C_Container.GetContainerItemInfo and C_Container.GetContainerItemInfo(bag, slot)
    if type(info) == "table" and type(info.isBound) == "boolean" then
        return info.isBound
    end
    if C_Item and C_Item.IsBound and ItemLocation and ItemLocation.CreateFromBagAndSlot then
        local ok, location = pcall(ItemLocation.CreateFromBagAndSlot, ItemLocation, bag, slot)
        if ok and location then
            local fine, bound = pcall(C_Item.IsBound, location)
            if fine and type(bound) == "boolean" then
                return bound
            end
        end
    end
    return nil
end

-- Returnerer status og begrunnelse, eller ingenting hvis addonen ikke har noe
-- å si om gjenstanden (f.eks. vanlig utstyr, eller noe du ikke har i baggen).
local function Evaluate(itemID, bag, slot)
    local mark = marks[itemID]
    if mark == "kast" then
        return STATUS_TRASH, L.RS_REASON_MARKED_TRASH
    elseif mark == "behold" then
        return STATUS_KEEP, L.RS_REASON_MARKED_KEEP
    end

    if not bag then
        bag, slot = FindInBags(itemID)
        if not bag then
            return
        end
    end

    local name, _, quality = GetItemInfo(itemID)
    if type(name) ~= "string" then
        return -- Ikke lastet ennå; prøv igjen ved neste hover.
    end
    local classID, _, bindType = select(12, GetItemInfo(itemID))

    local questInfo = C_Container.GetContainerItemQuestInfo(bag, slot)
    local startsQuestID = questInfo and questInfo.questID
    local isQuestItem = (questInfo and questInfo.isQuestItem)
        or startsQuestID ~= nil
        or classID == ITEM_CLASS_QUEST
        or bindType == ITEM_BIND_QUEST
    if not isQuestItem then
        return
    end

    -- Brukes den av en quest du holder på med?
    if not questCache then
        questCache = BuildQuestCache()
    end
    local usedBy = questCache.byItemID[itemID]
    if not usedBy then
        local needle = name:lower()
        for _, quest in ipairs(questCache.quests) do
            if quest.text:find(needle, 1, true) then
                usedBy = quest.title
                break
            end
        end
    end
    if usedBy then
        return STATUS_KEEP, L.RS_REASON_USED_BY:format(usedBy)
    end

    -- Håndverksmaterialer og ting som kan selges, kastes ikke.
    if DW.CraftingInfo and DW.CraftingInfo(itemID) then
        return STATUS_MATERIAL
    end
    if IsBound(bag, slot, bindType) == false then
        return STATUS_SELLABLE, L.RS_REASON_SELLABLE
    end

    -- Gjenstander som starter en quest.
    if startsQuestID then
        if questInfo.isActive then
            return STATUS_KEEP, L.RS_REASON_ACTIVE_STARTER
        elseif C_QuestLog.IsQuestFlaggedCompleted(startsQuestID) then
            return STATUS_TRASH, L.RS_REASON_STARTS_DONE
        end
        return STATUS_KEEP, L.RS_REASON_STARTS_NEW
    end

    if type(quality) == "number" and quality >= QUALITY_UNCOMMON then
        return STATUS_UNSURE, L.RS_REASON_UNSURE
    end
    return STATUS_MAYBE, L.RS_REASON_MAYBE
end

-- Skulle noe gå galt (f.eks. at et API-kall mangler), skal ikke tooltipen
-- ødelegges. Feilen skrives én gang i chatten så den kan rapporteres.
local reportedErrors = {}

local function SafeEvaluate(itemID, bag, slot)
    local ok, status, reason = pcall(Evaluate, itemID, bag, slot)
    if ok then
        return status, reason
    end
    local message = tostring(status)
    if not reportedErrors[message] then
        reportedErrors[message] = true
        DW.PrintError(L.ERROR, message)
    end
end

-- Tooltip ---------------------------------------------------------------------

-- Klienten kan melde samme gjenstand to ganger for én tooltip. Her husker vi
-- hvilken gjenstand hver tooltip allerede har fått linjen for.
local shownItem = {}

local function OnTooltipItem(tooltip, data)
    if not DW.IsMember() then
        return
    end
    if tooltip ~= GameTooltip and tooltip ~= ItemRefTooltip then
        return
    end
    local itemID = data and data.id
    if type(itemID) ~= "number" or IsSecret(itemID) then
        return
    end
    if shownItem[tooltip] == itemID then
        return
    end

    local status, reason = SafeEvaluate(itemID)
    if not status or status == STATUS_MATERIAL then
        return -- materialer får sin egen linje fra Materialer-modulen
    end
    shownItem[tooltip] = itemID

    local display = DISPLAY[status]
    tooltip:AddLine(" ")
    tooltip:AddLine(L[display.key], display.r, display.g, display.b)
    tooltip:AddLine(reason, 0.75, 0.75, 0.75, true)
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

if TooltipDataProcessor and TooltipDataProcessor.AddTooltipPostCall and Enum.TooltipDataType then
    TooltipDataProcessor.AddTooltipPostCall(Enum.TooltipDataType.Item, OnTooltipItem)
else
    -- Eldre klienter uten TooltipDataProcessor.
    GameTooltip:HookScript("OnTooltipSetItem", function(tooltip)
        local _, link = tooltip:GetItem()
        local itemID = link and tonumber(link:match("item:(%d+)"))
        if itemID then
            OnTooltipItem(tooltip, { id = itemID })
            tooltip:Show()
        end
    end)
end

-- Kandidater ------------------------------------------------------------------

-- Alt i baggene som addonen mener kan kastes, pluss det du selv har krysset av
-- for å beholde (slik at krysset kan fjernes igjen). Én oppføring per
-- gjenstand, sortert på navn så rekkefølgen ikke hopper når du krysser av.
local function CollectEntries()
    local entries, seen = {}, {}

    for bag = 0, LAST_BAG do
        for slot = 1, (C_Container.GetContainerNumSlots(bag) or 0) do
            local itemID = C_Container.GetContainerItemID(bag, slot)
            if itemID then
                local info = C_Container.GetContainerItemInfo and C_Container.GetContainerItemInfo(bag, slot)
                local count = (type(info) == "table" and info.stackCount) or 1
                local entry = seen[itemID]

                if entry == nil then
                    entry = false
                    local status, reason = SafeEvaluate(itemID, bag, slot)
                    if status and (CanDiscard(status) or marks[itemID] == "behold") then
                        local name, link, _, _, _, _, _, _, _, icon = GetItemInfo(itemID)
                        if type(name) ~= "string" then
                            name = "item:" .. itemID
                        end
                        entry = {
                            itemID = itemID,
                            bag = bag,
                            slot = slot,
                            status = status,
                            reason = reason,
                            name = name,
                            link = (type(link) == "string" and link) or name,
                            icon = icon,
                            count = count,
                        }
                        entries[#entries + 1] = entry
                    end
                    seen[itemID] = entry
                elseif entry then
                    entry.count = entry.count + count
                end
            end
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

-- Kasting ---------------------------------------------------------------------

-- Sletter én stabel av gjenstanden, uten bekreftelsesvindu. Kan ikke angres.
--
-- Spillet tillater bare én sletting per museklikk eller tastetrykk, så denne
-- må kalles direkte fra et klikk, og bare én gang per klikk. Derfor finnes det
-- ingen "kast alt"-knapp: hvert klikk kaster én ting.
--
-- Returnerer true hvis gjenstanden ble slettet.
local function DeleteOneStack(itemID)
    -- Finn gjenstanden på nytt akkurat nå. Baggene kan ha endret seg siden
    -- listen ble tegnet, og vi må aldri slette det som tilfeldigvis ligger i
    -- en gammel plass.
    local bag, slot = FindInBags(itemID)
    if not bag then
        return false
    end
    local info = C_Container.GetContainerItemInfo and C_Container.GetContainerItemInfo(bag, slot)
    if type(info) == "table" and info.isLocked then
        return false
    end

    -- Tøm musepekeren først, og gi opp hvis noe annet fortsatt henger på den.
    ClearCursor()
    if GetCursorInfo() ~= nil then
        return false
    end

    -- Plukk opp, og kontroller at det som havnet på pekeren er riktig ting.
    C_Container.PickupContainerItem(bag, slot)
    local kind, cursorItemID = GetCursorInfo()
    if IsSecret(kind) or kind ~= "item" or IsSecret(cursorItemID) or cursorItemID ~= itemID then
        ClearCursor() -- ikke det vi ventet: legg det tilbake urørt
        return false
    end

    DeleteCursorItem()
    if GetCursorInfo() ~= nil then
        ClearCursor() -- spillet nektet: legg gjenstanden tilbake i baggen
        return false
    end
    return true
end

-- Kaster gjenstanden i en oppføring fra listen, og skriver i chatten hva som
-- skjedde, så du har en logg over det som er kastet.
local function Discard(entry)
    -- Vurder på nytt i klikket. Har du nettopp tatt en quest som trenger den,
    -- eller krysset av for behold, skal den ikke kastes.
    local status = SafeEvaluate(entry.itemID)
    if not CanDiscard(status) then
        return false
    end

    local ok = DeleteOneStack(entry.itemID)
    Print((ok and L.RS_DISCARDED or L.RS_DISCARD_FAILED):format(entry.link))
    return ok
end

-- Panelet i hovedvinduet --------------------------------------------------------

local ROW_HEIGHT = 26
local FALLBACK_ICON = 134400 -- spørsmålstegn

local panel -- lages første gang modulen velges i hovedvinduet
local rows = {}
local RefreshPanel

-- Gjenstanden som har fått første klikk på Kast og venter på "Sikker?".
-- Gjelder bare det addonen er usikker på.
local armedItem

-- Hva den gule knappen nederst får lov til å kaste: alltid det som er sikkert,
-- og det som er "trolig trygt" hvis spilleren har krysset av for det. Det
-- addonen er usikker på tar den aldri.
local function ButtonTakes(status)
    return status == STATUS_TRASH or (status == STATUS_MAYBE and settings.includeMaybe == true)
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

    -- Avkrysning: på = behold, av = la addonen vurdere selv.
    row.check = CreateFrame("CheckButton", nil, row, "UICheckButtonTemplate")
    row.check:SetSize(24, 24)
    row.check:SetPoint("RIGHT", -8, 0)
    row.check:SetScript("OnClick", function(self)
        local entry = row.entry
        if not entry then
            return
        end
        marks[entry.itemID] = self:GetChecked() and "behold" or nil
        RefreshPanel()
    end)

    row.icon = row:CreateTexture(nil, "ARTWORK")
    row.icon:SetSize(20, 20)
    row.icon:SetPoint("LEFT", 2, 0)
    row.icon:SetTexCoord(0.07, 0.93, 0.07, 0.93)

    -- Kast-knapp: sletter gjenstanden med en gang, uten bekreftelsesvindu.
    row.discard = DW.CreateButton(row, 64, 20, "red")
    row.discard:SetPoint("RIGHT", row.check, "LEFT", -10, 0)
    row.discard:SetScript("OnClick", function()
        local entry = row.entry
        if not entry then
            return
        end
        -- Det addonen er usikker på krever to klikk: første klikk spør
        -- "Sikker?", andre klikk kaster.
        if entry.status == STATUS_UNSURE and armedItem ~= entry.itemID then
            armedItem = entry.itemID
            RefreshPanel()
            return
        end
        armedItem = nil
        Discard(entry)
        RefreshPanel()
    end)
    -- Flytter du musa bort fra knappen, angres første klikk.
    row.discard:HookScript("OnLeave", function()
        if armedItem then
            armedItem = nil
            RefreshPanel()
        end
    end)

    row.status = row:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    row.status:SetPoint("RIGHT", row.discard, "LEFT", -10, 0)
    row.status:SetWidth(160)
    row.status:SetJustifyH("RIGHT")

    row.name = row:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
    row.name:SetPoint("LEFT", row.icon, "RIGHT", 6, 0)
    row.name:SetPoint("RIGHT", row.status, "LEFT", -6, 0)
    row.name:SetJustifyH("LEFT")
    row.name:SetWordWrap(false)

    -- Hold over raden for å se gjenstandens tooltip, med begrunnelsen nederst.
    row:SetScript("OnEnter", function(self)
        local entry = self.entry
        if not entry then
            return
        end
        GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
        GameTooltip:SetBagItem(entry.bag, entry.slot)
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

    panel.title:SetText(L.RS_PANEL_TITLE)
    panel.hint:SetText(L.RS_HINT)
    panel.headerItem:SetText(L.RS_HEADER_ITEM)
    panel.headerKeep:SetText(L.RS_HEADER_KEEP)
    panel.empty:SetText(L.RS_EMPTY)

    local entries = CollectEntries()
    local nextSafe, safeCount = nil, 0

    for index, entry in ipairs(entries) do
        local row = GetRow(index)
        local display = DISPLAY[entry.status]
        local kept = marks[entry.itemID] == "behold"
        row.entry = entry
        row.icon:SetTexture(entry.icon or FALLBACK_ICON)
        row.name:SetText(entry.count > 1 and (entry.link .. " x" .. entry.count) or entry.link)
        row.status:SetText(L[display.key])
        row.status:SetTextColor(display.r, display.g, display.b)
        row.check:SetChecked(kept)
        -- Det du har krysset av for behold kan ikke kastes herfra.
        row.discard:SetShown(not kept)
        row.discard.label:SetText(armedItem == entry.itemID and L.RS_CONFIRM or L.RS_DISCARD)
        row:Show()

        if ButtonTakes(entry.status) then
            safeCount = safeCount + 1
            nextSafe = nextSafe or entry
        end
    end
    for index = #entries + 1, #rows do
        rows[index].entry = nil
        rows[index]:Hide()
    end

    panel.content:SetHeight(math.max(1, #entries * ROW_HEIGHT))
    panel.empty:SetShown(#entries == 0)

    -- Bunnlinjen: valget, neste gjenstand, og knappen som kaster den.
    panel.includeLabel:SetText(L.RS_INCLUDE_MAYBE)
    panel.includeCheck:SetChecked(settings.includeMaybe == true)
    panel.nextButton.label:SetText(L.RS_NEXT_BUTTON:format(safeCount))
    panel.nextButton:SetActive(nextSafe ~= nil)
    panel.nextLabel:SetText(nextSafe and L.RS_NEXT_LABEL:format(nextSafe.link) or L.RS_NEXT_NONE)
end

-- Questloggen kan melde endringer mange ganger i sekundet. Samle dem opp og
-- oppdater panelet én gang.
local refreshQueued = false

local function QueueRefresh()
    if refreshQueued or not panel or not panel:IsVisible() then
        return
    end
    if not (C_Timer and C_Timer.After) then
        RefreshPanel()
        return
    end
    refreshQueued = true
    C_Timer.After(0.1, function()
        refreshQueued = false
        RefreshPanel()
    end)
end

-- Kalles av hovedvinduet første gang modulen velges. parent er feltet til
-- høyre for chipene.
local function CreatePanel(parent)
    local f = CreateFrame("Frame", nil, parent)
    f:SetAllPoints(parent)

    f.title = f:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
    f.title:SetPoint("TOP", 0, -12)

    f.hint = f:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    f.hint:SetPoint("TOPLEFT", 14, -38)
    f.hint:SetPoint("TOPRIGHT", -14, -38)
    f.hint:SetJustifyH("LEFT")

    f.headerItem = f:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    f.headerItem:SetPoint("TOPLEFT", 14, -76)

    -- Midtstilt over avkrysningsboksene, uansett hvor langt ordet er.
    f.headerKeep = f:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    f.headerKeep:SetPoint("TOP", f, "TOPRIGHT", -50, -76)

    local scroll = CreateFrame("ScrollFrame", "DragonworldRyddesekkScroll", f, "ScrollFrameTemplate")
    scroll:SetPoint("TOPLEFT", 10, -92)
    scroll:SetPoint("BOTTOMRIGHT", -30, 78)

    -- Valg: skal den gule knappen også ta det som bare er "trolig trygt"?
    f.includeCheck = CreateFrame("CheckButton", nil, f, "UICheckButtonTemplate")
    f.includeCheck:SetSize(24, 24)
    f.includeCheck:SetPoint("BOTTOMLEFT", 10, 46)
    f.includeCheck:SetScript("OnClick", function(self)
        settings.includeMaybe = self:GetChecked() and true or nil
        RefreshPanel()
    end)

    f.includeLabel = f:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    f.includeLabel:SetPoint("LEFT", f.includeCheck, "RIGHT", 2, 0)

    -- Bunnlinjen. Knappen kaster én gjenstand per klikk; spillet tillater ikke
    -- flere. Teksten til venstre viser hvilken som står for tur.
    f.nextButton = DW.CreateButton(f, 250, 32, "gold")
    f.nextButton:SetPoint("BOTTOMRIGHT", -14, 12)
    f.nextButton:SetScript("OnClick", function()
        armedItem = nil
        -- Regn ut listen på nytt i klikket, så vi aldri går ut fra en gammel.
        for _, entry in ipairs(CollectEntries()) do
            if ButtonTakes(entry.status) then
                Discard(entry)
                break
            end
        end
        RefreshPanel()
    end)

    f.nextLabel = f:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    f.nextLabel:SetPoint("LEFT", f, "BOTTOMLEFT", 14, 28)
    f.nextLabel:SetPoint("RIGHT", f.nextButton, "LEFT", -10, 0)
    f.nextLabel:SetJustifyH("LEFT")
    f.nextLabel:SetWordWrap(false)

    f.content = CreateFrame("Frame", nil, scroll)
    f.content:SetSize(parent:GetWidth() - 10 - 30, 1)
    scroll:SetScrollChild(f.content)

    f.empty = f:CreateFontString(nil, "OVERLAY", "GameFontDisable")
    f.empty:SetPoint("TOP", scroll, "TOP", 0, -40)
    f.empty:SetWidth(320)

    f:SetScript("OnShow", function()
        RefreshPanel()
    end)
    f:SetScript("OnHide", function()
        armedItem = nil
    end)

    panel = f
    return f
end

-- Hendelser -------------------------------------------------------------------

local frame = CreateFrame("Frame")

frame:SetScript("OnEvent", function(self, event)
    -- Alt annet enn bag-endringer betyr at questloggen kan ha endret seg.
    if event ~= "BAG_UPDATE_DELAYED" then
        questCache = nil
    end
    QueueRefresh()
end)

for _, event in ipairs({
    "PLAYER_ENTERING_WORLD",
    "QUEST_LOG_UPDATE",
    "QUEST_ACCEPTED",
    "QUEST_REMOVED",
    "QUEST_TURNED_IN",
    "BAG_UPDATE_DELAYED",
}) do
    pcall(frame.RegisterEvent, frame, event)
end

-- Bytter spilleren språk mens panelet er åpent, skrives det på nytt.
DW.OnLanguageChanged(function()
    RefreshPanel()
end)

-- Kommandoer ------------------------------------------------------------------

local function ListBags()
    local lines = {}

    for _, entry in ipairs(CollectEntries()) do
        if CanDiscard(entry.status) then
            local display = DISPLAY[entry.status]
            lines[#lines + 1] = ("  %s |cff%s%s|r - %s"):format(entry.link, display.hex, L[display.key], entry.reason)
        end
    end

    if #lines == 0 then
        Print(L.RS_LIST_NONE)
        return
    end
    Print(L.RS_LIST_HEADER)
    for _, line in ipairs(lines) do
        print(line)
    end
end

local function PrintHelp()
    Print(L.HELP_HEADER)
    print("  " .. L.RS_HELP_OPEN)
    print("  " .. L.RS_HELP_LIST)
    print("  " .. L.RS_HELP_MARK)
    print("  " .. L.RS_HELP_KEEP)
    print("  " .. L.RS_HELP_REMOVE)
    print("  " .. L.RS_HELP_SHIFT)
end

-- Kommandoordene virker på alle tre språk, uansett hvilket som er valgt.
local COMMANDS = {
    list = "list", liste = "list", lijst = "list",
    mark = "mark", merk = "mark", markeer = "mark",
    keep = "keep", behold = "keep", bewaar = "keep",
    remove = "remove", fjern = "remove", verwijder = "remove",
}

local function HandleSlash(message)
    if not DW.Guard() then
        return
    end
    message = message or ""
    local word = (message:match("^%s*(%S+)") or ""):lower()

    if word == "" then
        DW.ToggleModule(MODULE_ID)
        return
    end

    local command = COMMANDS[word]
    if command == "list" then
        ListBags()
        return
    end
    if not command then
        PrintHelp()
        return
    end

    local itemID = tonumber(message:match("item:(%d+)"))
    if not itemID then
        Print(L.RS_NEED_ITEM:format(L.RS_SLASH, word))
        return
    end

    local link = message:match("|c.-|h|r") or ("item:" .. itemID)
    if command == "mark" then
        marks[itemID] = "kast"
        Print(L.RS_MARKED_TRASH:format(link))
    elseif command == "keep" then
        marks[itemID] = "behold"
        Print(L.RS_MARKED_KEEP:format(link))
    else
        marks[itemID] = nil
        Print(L.RS_MARK_REMOVED:format(link))
    end
    RefreshPanel()
end

-- Snarveier til "/dw ryddesekk", én per språk.
SLASH_DRAGONWORLD_RYDDESEKK1 = "/kast"
SLASH_DRAGONWORLD_RYDDESEKK2 = "/tidybag"
SLASH_DRAGONWORLD_RYDDESEKK3 = "/opruimtas"
SlashCmdList["DRAGONWORLD_RYDDESEKK"] = HandleSlash

-- Modul --------------------------------------------------------------------------

DW.RegisterModule({
    id = MODULE_ID,
    titleKey = "RS_TITLE",
    notesKey = "RS_NOTES",
    shortcutKey = "RS_SLASH",
    icon = "Interface\\Icons\\INV_Misc_Bag_08",

    OnLoad = function(self, db)
        if type(db.marks) ~= "table" then
            db.marks = {}
        end
        marks = db.marks
        settings = db
    end,

    OnSlash = function(self, message)
        HandleSlash(message)
    end,

    CreatePanel = function(self, parent)
        return CreatePanel(parent)
    end,
})
