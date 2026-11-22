-- Dragonworld - Ryddesekk
-- Adds a line to the tooltip of quest items in the bag that says whether the
-- item is still needed or can be thrown away. In the main window it lists
-- what can be thrown away, with a checkbox for what you want to keep.
--
-- This is how it is decided, in this order:
--   1. If you have marked the item yourself, that applies.
--   2. If the item is mentioned in a quest in your quest log, it is still needed.
--   3. If it is a crafting material, it must not be thrown away. Which
--      professions use it is written by the Materialer module in the tooltip.
--   4. If it is not bound to you, it can be sold at the auction house or given
--      away, and must not be thrown away either.
--   5. If the item starts a quest you have already completed, it can be thrown away.
--   6. If it is a quest item that none of your quests mention, it can
--      probably be thrown away.
-- The game does not say which quest an item belongs to, so point 6 is an
-- educated guess. That is why it says "trolig" (probably).
--
-- All text is in Locales.lua (the names that start with RS_).

local ADDON_NAME, DW = ...
local L = DW.L

local MODULE_ID = "ryddesekk"

local STATUS_TRASH, STATUS_MAYBE, STATUS_UNSURE, STATUS_KEEP = 1, 2, 3, 4
local STATUS_MATERIAL, STATUS_SELLABLE = 5, 6

-- Text (the name in Locales.lua) and color for each status.
local DISPLAY = {
    [STATUS_TRASH]    = { key = "RS_STATUS_TRASH",    r = 0.25, g = 1.00, b = 0.25, hex = "40ff40" },
    [STATUS_MAYBE]    = { key = "RS_STATUS_MAYBE",    r = 1.00, g = 0.82, b = 0.00, hex = "ffd100" },
    [STATUS_UNSURE]   = { key = "RS_STATUS_UNSURE",   r = 1.00, g = 0.50, b = 0.25, hex = "ff8040" },
    [STATUS_KEEP]     = { key = "RS_STATUS_KEEP",     r = 0.40, g = 0.75, b = 1.00, hex = "66bfff" },
    [STATUS_SELLABLE] = { key = "RS_STATUS_SELLABLE", r = 0.40, g = 0.75, b = 1.00, hex = "66bfff" },
}

-- What can be thrown away from here. Everything else (keep, material, can be
-- sold) stays.
local function CanDiscard(status)
    return status == STATUS_TRASH or status == STATUS_MAYBE or status == STATUS_UNSURE
end

local ITEM_CLASS_QUEST = (Enum and Enum.ItemClass and Enum.ItemClass.Questitem) or 12
local ITEM_BIND_QUEST = 4
local QUALITY_UNCOMMON = 2
local LAST_BAG = NUM_TOTAL_EQUIPPED_BAG_SLOTS or NUM_BAG_SLOTS or 4

-- Forever does not have the old global GetItemInfo, only the C_Item version.
local GetItemInfo = (C_Item and C_Item.GetItemInfo) or GetItemInfo

-- The player's own marks, remembered between sessions. Set in OnLoad at the bottom.
--   marks[itemID] = "kast" or "behold"
-- (The values are the same in every language, so the marks survive a language change.)
local marks = {}

-- The module's saved choices. Set in OnLoad at the bottom.
--   settings.includeMaybe = true if the yellow button should also take what
--                           is only "probably safe". Off by default.
local settings = {}

-- Overview of active quests. Built the first time it is needed, and reset
-- every time the quest log changes.
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

            -- The quest objectives, e.g. "Kobold Candle: 3/8".
            local objectives = C_QuestLog.GetQuestObjectives(info.questID)
            if objectives then
                for _, objective in ipairs(objectives) do
                    AddText(parts, objective.text)
                end
            end

            -- The quest text itself. It catches things you only have to deliver,
            -- e.g. "Take the Sealed Note to ...".
            if GetQuestLogQuestText then
                local description, summary = GetQuestLogQuestText(index)
                AddText(parts, description)
                AddText(parts, summary)
            end

            -- Item used in the quest (the button next to the quest).
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

-- Is the item bound to you? true, false, or nil when the game does not say.
-- An item that is not bound can be sold at the auction house or traded.
local function IsBound(bag, slot, bindType)
    if bindType == ITEM_BIND_QUEST then
        return true -- "Quest Item" is always bound
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

-- Returns status and reason, or nothing if the addon has nothing to say
-- about the item (e.g. regular gear, or something you do not have in the bag).
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
        return -- Not loaded yet; try again on the next hover.
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

    -- Is it used by a quest you are working on?
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

    -- Crafting materials and things that can be sold are not thrown away.
    if DW.CraftingInfo and DW.CraftingInfo(itemID) then
        return STATUS_MATERIAL
    end
    if IsBound(bag, slot, bindType) == false then
        return STATUS_SELLABLE, L.RS_REASON_SELLABLE
    end

    -- Items that start a quest.
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

-- If something goes wrong (e.g. an API call is missing), the tooltip must not
-- be broken. The error is printed once in chat so it can be reported.
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

-- The client can report the same item twice for one tooltip. Here we remember
-- which item each tooltip has already got the line for.
local shownItem = {}

local function OnTooltipItem(tooltip, data)
    if not DW.HasAccess() then
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
        return -- materials get their own line from the Materialer module
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
    -- Older clients without TooltipDataProcessor.
    GameTooltip:HookScript("OnTooltipSetItem", function(tooltip)
        local _, link = tooltip:GetItem()
        local itemID = link and tonumber(link:match("item:(%d+)"))
        if itemID then
            OnTooltipItem(tooltip, { id = itemID })
            tooltip:Show()
        end
    end)
end

-- Candidates ------------------------------------------------------------------

-- Everything in the bags that the addon thinks can be thrown away, plus what
-- you have checked to keep (so the check can be removed again). One entry per
-- item, sorted by name so the order does not jump when you check something.
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

-- Discarding ------------------------------------------------------------------

-- Deletes one stack of the item, without a confirmation window. Cannot be undone.
--
-- The game only allows one deletion per mouse click or key press, so this
-- must be called directly from a click, and only once per click. That is why
-- there is no "discard all" button: each click discards one thing.
--
-- Returns true if the item was deleted.
local function DeleteOneStack(itemID)
    -- Find the item again right now. The bags may have changed since the list
    -- was drawn, and we must never delete whatever happens to be in an old
    -- slot.
    local bag, slot = FindInBags(itemID)
    if not bag then
        return false
    end
    local info = C_Container.GetContainerItemInfo and C_Container.GetContainerItemInfo(bag, slot)
    if type(info) == "table" and info.isLocked then
        return false
    end

    -- Clear the cursor first, and give up if something else is still on it.
    ClearCursor()
    if GetCursorInfo() ~= nil then
        return false
    end

    -- Pick it up, and check that what ended up on the cursor is the right thing.
    C_Container.PickupContainerItem(bag, slot)
    local kind, cursorItemID = GetCursorInfo()
    if IsSecret(kind) or kind ~= "item" or IsSecret(cursorItemID) or cursorItemID ~= itemID then
        ClearCursor() -- not what we expected: put it back untouched
        return false
    end

    DeleteCursorItem()
    if GetCursorInfo() ~= nil then
        ClearCursor() -- the game refused: put the item back in the bag
        return false
    end
    return true
end

-- Discards the item in an entry from the list, and prints in chat what
-- happened, so you have a log of what was thrown away.
local function Discard(entry)
    -- Evaluate again at the click. If you have just taken a quest that needs it,
    -- or checked it to keep, it must not be thrown away.
    local status = SafeEvaluate(entry.itemID)
    if not CanDiscard(status) then
        return false
    end

    local ok = DeleteOneStack(entry.itemID)
    Print((ok and L.RS_DISCARDED or L.RS_DISCARD_FAILED):format(entry.link))
    return ok
end

-- The panel in the main window -------------------------------------------------

local ROW_HEIGHT = 26
local FALLBACK_ICON = 134400 -- question mark

local panel -- created the first time the module is selected in the main window
local rows = {}
local RefreshPanel

-- The item that has had the first click on Kast (Discard) and is waiting for
-- "Sure?". Only applies to what the addon is unsure about.
local armedItem

-- What the yellow button at the bottom is allowed to discard: always what is
-- certain, and what is "probably safe" if the player has
-- checked that option. It never takes what the addon is unsure about.
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

    -- Checkbox: on = keep, off = let the addon decide.
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

    -- Kast (discard) button: deletes the item at once, without a confirmation window.
    row.discard = DW.CreateButton(row, 64, 20, "red")
    row.discard:SetPoint("RIGHT", row.check, "LEFT", -10, 0)
    row.discard:SetScript("OnClick", function()
        local entry = row.entry
        if not entry then
            return
        end
        -- What the addon is unsure about takes two clicks: the first click asks
        -- "Sure?", the second click discards.
        if entry.status == STATUS_UNSURE and armedItem ~= entry.itemID then
            armedItem = entry.itemID
            RefreshPanel()
            return
        end
        armedItem = nil
        Discard(entry)
        RefreshPanel()
    end)
    -- If you move the mouse away from the button, the first click is undone.
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

    -- Hover over the row to see the item's tooltip, with the reason at the bottom.
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
        -- What you have checked to keep cannot be discarded from here.
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

    -- The bottom row: the option, the next item, and the button that discards it.
    panel.includeLabel:SetText(L.RS_INCLUDE_MAYBE)
    panel.includeCheck:SetChecked(settings.includeMaybe == true)
    panel.nextButton.label:SetText(L.RS_NEXT_BUTTON:format(safeCount))
    panel.nextButton:SetActive(nextSafe ~= nil)
    panel.nextLabel:SetText(nextSafe and L.RS_NEXT_LABEL:format(nextSafe.link) or L.RS_NEXT_NONE)
end

-- The quest log can report changes many times a second. Collect them and
-- update the panel once.
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

-- Called by the main window the first time the module is selected. parent is
-- the area to the right of the chips.
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

    -- Centered over the checkboxes, however long the word is.
    f.headerKeep = f:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    f.headerKeep:SetPoint("TOP", f, "TOPRIGHT", -50, -76)

    local scroll = CreateFrame("ScrollFrame", "DragonworldRyddesekkScroll", f, "ScrollFrameTemplate")
    scroll:SetPoint("TOPLEFT", 10, -92)
    scroll:SetPoint("BOTTOMRIGHT", -30, 78)

    -- Option: should the yellow button also take what is only "probably safe"?
    f.includeCheck = CreateFrame("CheckButton", nil, f, "UICheckButtonTemplate")
    f.includeCheck:SetSize(24, 24)
    f.includeCheck:SetPoint("BOTTOMLEFT", 10, 46)
    f.includeCheck:SetScript("OnClick", function(self)
        settings.includeMaybe = self:GetChecked() and true or nil
        RefreshPanel()
    end)

    f.includeLabel = f:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    f.includeLabel:SetPoint("LEFT", f.includeCheck, "RIGHT", 2, 0)

    -- The bottom row. The button discards one item per click; the game does not
    -- allow more. The text on the left shows which one is next.
    f.nextButton = DW.CreateButton(f, 250, 32, "gold")
    f.nextButton:SetPoint("BOTTOMRIGHT", -14, 12)
    f.nextButton:SetScript("OnClick", function()
        armedItem = nil
        -- Recompute the list at the click, so we never rely on an old one.
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

-- Events ----------------------------------------------------------------------

local frame = CreateFrame("Frame")

frame:SetScript("OnEvent", function(self, event)
    -- Anything other than bag changes means the quest log may have changed.
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

-- If the player changes language while the panel is open, it is redrawn.
DW.OnLanguageChanged(function()
    RefreshPanel()
end)

-- Commands --------------------------------------------------------------------

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

-- The command words work in all three languages, whichever is chosen.
local COMMANDS = {
    list = "list", liste = "list", lijst = "list",
    mark = "mark", merk = "mark", markeer = "mark",
    keep = "keep", behold = "keep", bewaar = "keep",
    remove = "remove", fjern = "remove", verwijder = "remove",
}

local function HandleSlash(message)
    if not DW.GuardPersonal() then
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

-- Shortcuts to "/dw ryddesekk", one per language.
SLASH_DRAGONWORLD_RYDDESEKK1 = "/kast"
SLASH_DRAGONWORLD_RYDDESEKK2 = "/tidybag"
SLASH_DRAGONWORLD_RYDDESEKK3 = "/opruimtas"
SlashCmdList["DRAGONWORLD_RYDDESEKK"] = HandleSlash

-- Module -------------------------------------------------------------------------

DW.RegisterModule({
    id = MODULE_ID,
    personal = true, -- alts outside the guild may use it (Core.lua)
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
