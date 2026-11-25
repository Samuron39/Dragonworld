-- Dragonworld - who can craft it?
-- Searches everything guild members can make, and shows who can craft it.
--   * A "Who crafts?" button in the Roster tab (and /dw craft <text>) opens a
--     window over the main window: type part of an item's or recipe's name,
--     and each thing that matches is listed with the members who can make it
--     (you first, then those you can reach now, then the others by when they
--     were last online). Click a name for the member card, the profession for
--     the recipe window, and Whisper to ask (with the item ready in the chat line).
--   * Item tooltips get a line with who in the guild can craft that item
--     (3 names at most, online first, you left out). A box in the window turns
--     it off.
--
-- Nothing new is sent between players: this reads the recipe lists members
-- already share (Roster.lua, C messages). A recipe is a spellID; which item it
-- makes is asked of the game (GetRecipeSchematic), then the Wowhead data in
-- ProfessionData.lua. What we learn is remembered between sessions, so the
-- game is asked once per recipe. A recipe whose item we never learn is still
-- found by its name (an item with exactly the recipe's name counts as made by it).
--
-- Linked characters (Alts.lua): a crafter who is offline but has a linked
-- character online counts as reachable ("online as X"), and Whisper goes to
-- that character.
--
-- All text is in Locales.lua (the names that start with CS_).

local ADDON_NAME, DW = ...
local L = DW.L

local MODULE_ID = "craft"
local OVERLAY_NAME = "DragonworldCraftSearch"
local CACHE_VERSION = 1
local MAX_CACHE = 6000        -- more remembered recipes than this: start over
local RESOLVE_BATCH = 60      -- recipes asked of the game per step
local RESOLVE_DELAY = 0.12    -- seconds between the steps
local BUILD_DELAY = 2         -- after a recipe list has changed
local LOGIN_DELAY = 15        -- the first build after login
local ROSTER_EVERY = 5        -- the member list is read at most this often (seconds)
local REFRESH_DELAY = 0.15    -- the window waits this long after typing
local ROW_HEIGHT = 20
local MAX_GROUPS = 25         -- things shown at most
local MAX_SEARCH_LETTERS = 40
local TIP_MAX_NAMES = 3
local ENCHANT_TYPE_FALLBACK = 3 -- Enum.TradeskillRecipeType.Enchant

-- Saved data (DragonworldDB.modules.craft), set in OnLoad:
--   v        CACHE_VERSION; anything else starts the cache over
--   items[spellID] = itemID the recipe makes (> 0), or 0 for a recipe the game
--            confirmed is an enchant (it makes no item). Only answers are stored.
--   tooltip  false when the tooltip line is turned off (nil = on)
local db = { items = {} }
local cacheCount = 0

-- What is known in this session (reset in OnLoad):
--   index.owners[spellID] = { { guid, profession }, ... }
--   index.itemOf[spellID] = itemID (> 0) or 0 (enchant), when known
--   index.byItem[itemID] = { spellIDs }
--   index.byName[lowercase recipe name] = { spellIDs } for recipes whose item is unknown
--   index.names[spellID] = the recipe's name (left out while the game has none)
--   index.recipes, index.members: how many different recipes, and from how many players
local index
local built, dirty = false, true
local pending, pendingSet = {}, {}  -- recipes still to ask the game about
local failed = {}                   -- recipes the game and the data had no answer for
local buildQueued, resolveQueued, loginPlanned = false, false, false

local overlay
local rows = {}
local searchText = ""
local refreshQueued = false
local waitingFor = {}               -- items we have asked the game to load
local Refresh

-- Small things -------------------------------------------------------------------

local function Number(value)
    if type(value) == "number" and not DW.IsSecret(value) then
        return value
    end
    return nil
end

local function Text(value)
    if type(value) == "string" and not DW.IsSecret(value) and value ~= "" then
        return value
    end
    return nil
end

-- Calls a game function safely: nothing happens if it does not exist or fails.
local function SafeCall(fn, ...)
    if type(fn) ~= "function" then
        return false
    end
    return pcall(fn, ...)
end

-- The search text without links, colour codes and line breaks, cut to 40
-- letters (without splitting one) and trimmed.
local function Clean(text)
    if type(text) ~= "string" or DW.IsSecret(text) then
        return ""
    end
    text = text:gsub("[|%c]", "")
    local letters, cut = 0, #text
    for position in text:gmatch("()[^\128-\191]") do
        letters = letters + 1
        if letters > MAX_SEARCH_LETTERS then
            cut = position - 1
            break
        end
    end
    text = text:sub(1, cut)
    text = text:gsub("^%s+", "")
    text = text:gsub("%s+$", "")
    return text
end

local function LetterCount(text)
    local count = 0
    for _ in text:gmatch("[^\128-\191]") do
        count = count + 1
    end
    return count
end

local function ItemName(itemID)
    if not (C_Item and C_Item.GetItemInfo) then
        return nil
    end
    local ok, name, link, quality = pcall(C_Item.GetItemInfo, itemID)
    if ok and Text(name) then
        return name, Text(link), Number(quality)
    end
    return nil
end

local function ListAdd(map, key, value)
    local list = map[key]
    if not list then
        list = {}
        map[key] = list
    end
    list[#list + 1] = value
end

local function ListRemove(map, key, value)
    local list = map[key]
    if not list then
        return
    end
    for position = #list, 1, -1 do
        if list[position] == value then
            table.remove(list, position)
        end
    end
    if #list == 0 then
        map[key] = nil
    end
end

-- Which item a recipe makes ------------------------------------------------------

local function Remember(spell, item)
    if db.items[spell] == nil then
        if cacheCount >= MAX_CACHE then
            return item
        end
        cacheCount = cacheCount + 1
    end
    db.items[spell] = item
    return item
end

-- The item a recipe makes (> 0), 0 for a confirmed enchant, or nil when nobody
-- knows. The answer is remembered; nil is only remembered for this session.
local function OutputItem(spell)
    local known = db.items[spell]
    if type(known) == "number" then
        return known
    end
    local ui = C_TradeSkillUI
    if type(ui) == "table" then
        -- 1. The game's own description of the recipe.
        local ok, schematic = SafeCall(ui.GetRecipeSchematic, spell, false)
        if ok and type(schematic) == "table" and not DW.IsSecret(schematic) then
            local item = Number(schematic.outputItemID)
            if item and item > 0 then
                return Remember(spell, item)
            end
            local enchant = (Enum and Enum.TradeskillRecipeType and Number(Enum.TradeskillRecipeType.Enchant)) or ENCHANT_TYPE_FALLBACK
            if Number(schematic.recipeType) == enchant and Text(schematic.name) then
                return Remember(spell, 0)
            end
        end
        -- 2. The game's answer for what comes out of it.
        local fine, data = SafeCall(ui.GetRecipeOutputItemData, spell)
        if fine and type(data) == "table" and not DW.IsSecret(data) then
            local item = Number(data.itemID)
            if item and item > 0 then
                return Remember(spell, item)
            end
        end
    end
    -- 3. The Wowhead data.
    local recipes = DW.ProfessionData and DW.ProfessionData.recipes
    local data = type(recipes) == "table" and recipes[spell]
    local creates = type(data) == "table" and Number(data.creates)
    if creates and creates > 0 then
        return Remember(spell, creates)
    end
    failed[spell] = true
    return nil
end

-- The index ----------------------------------------------------------------------

-- Files a recipe under the item it makes, or under its name while that is unknown.
local function Place(spell, item)
    local name = index.names[spell]
    if item == nil then
        if name then
            ListAdd(index.byName, name:lower(), spell)
        end
        return
    end
    if index.itemOf[spell] == nil and name then
        ListRemove(index.byName, name:lower(), spell)
    end
    index.itemOf[spell] = item
    if item > 0 then
        ListAdd(index.byItem, item, spell)
    end
end

local function QueueRefresh()
    if refreshQueued or not overlay or not overlay:IsShown() then
        return
    end
    if not (C_Timer and C_Timer.After) then
        Refresh()
        return
    end
    refreshQueued = true
    C_Timer.After(REFRESH_DELAY, function()
        refreshQueued = false
        Refresh()
    end)
end

-- Asks the game about the recipes we do not know yet, a few at a time.
local ResolvePending

local function ResolveStep()
    local done = 0
    while done < RESOLVE_BATCH and #pending > 0 do
        local spell = table.remove(pending) -- from the end: cheap, and the order does not matter
        pendingSet[spell] = nil
        done = done + 1
        if index and index.owners[spell] and index.itemOf[spell] == nil and not failed[spell] then
            local item = OutputItem(spell)
            if item then
                Place(spell, item)
            end
        end
    end
    if #pending > 0 then
        ResolvePending()
    else
        QueueRefresh()
    end
end

ResolvePending = function()
    if resolveQueued or #pending == 0 then
        return
    end
    if not (C_Timer and C_Timer.After) then
        while #pending > 0 do
            ResolveStep()
        end
        return
    end
    resolveQueued = true
    C_Timer.After(RESOLVE_DELAY, function()
        resolveQueued = false
        ResolveStep()
    end)
end

local function Build()
    index = { owners = {}, itemOf = {}, byItem = {}, byName = {}, names = {}, recipes = 0, members = 0 }
    local guids = {}
    if DW.EachRecipeList then
        DW.EachRecipeList(function(guid, profession, ids)
            if not guids[guid] then
                guids[guid] = true
                index.members = index.members + 1
            end
            for _, spell in ipairs(ids) do
                local owners = index.owners[spell]
                if not owners then
                    owners = {}
                    index.owners[spell] = owners
                    index.recipes = index.recipes + 1
                end
                owners[#owners + 1] = { guid = guid, profession = profession }
            end
        end)
    end

    local spells = {}
    for spell in pairs(index.owners) do
        spells[#spells + 1] = spell
    end
    table.sort(spells)
    pending, pendingSet = {}, {}
    for _, spell in ipairs(spells) do
        local name = DW.SpellName(spell)
        if type(name) == "string" and name:sub(1, 1) ~= "#" then
            index.names[spell] = name
        end
        local item = db.items[spell]
        if type(item) == "number" then
            Place(spell, item)
        else
            Place(spell, nil)
            if not failed[spell] then
                pending[#pending + 1] = spell
                pendingSet[spell] = true
            end
        end
    end
    built, dirty = true, false
    if #pending > 0 then
        ResolvePending()
    end
end

-- The index as it should be for a search: built now if it is old or missing.
local function EnsureIndex()
    if dirty or not built or not index then
        Build()
    end
    return index
end

-- A recipe list has arrived or changed: build again a little later.
local function MarkDirty()
    dirty = true
    if buildQueued or not (C_Timer and C_Timer.After) then
        return
    end
    buildQueued = true
    C_Timer.After(BUILD_DELAY, function()
        buildQueued = false
        if dirty and DW.IsMember() then
            Build()
            QueueRefresh()
        end
    end)
end

-- Members --------------------------------------------------------------------------

local rosterByGuid
local rosterDirty, rosterAt = true, 0

-- { [guid] = roster row }, read again only after the game has said the member
-- list changed, and at most every few seconds.
local function RosterByGUID()
    local now = GetTime and GetTime() or 0
    if rosterByGuid and (not rosterDirty or now - rosterAt < ROSTER_EVERY) then
        return rosterByGuid
    end
    rosterByGuid = {}
    for _, member in ipairs(DW.ReadGuildRoster()) do
        if member.guid then
            rosterByGuid[member.guid] = member
        end
    end
    rosterDirty, rosterAt = false, now
    return rosterByGuid
end

-- Can the member be asked now: online, or one of their linked characters is
-- (then the second value is that character). You are never the one to ask.
local function Reachable(member, group, me)
    if member.online then
        return true, nil
    end
    if group and group.online then
        for _, other in ipairs(group.members or {}) do
            if other.online and other.guid ~= me then
                return true, other
            end
        end
    end
    return false, nil
end

-- Is the member you, or one of your own linked characters?
local function IsMine(member, group, me)
    if not me then
        return false
    end
    if member.guid == me then
        return true
    end
    for _, other in ipairs(group and group.members or {}) do
        if other.guid == me then
            return true
        end
    end
    return false
end

local function SortCrafters(list)
    table.sort(list, function(a, b)
        if a.isMe ~= b.isMe then
            return a.isMe
        end
        if a.reachable ~= b.reachable then
            return a.reachable
        end
        local ageA = (a.member.days or 0) * 24 + (a.member.hours or 0)
        local ageB = (b.member.days or 0) * 24 + (b.member.hours or 0)
        if ageA ~= ageB then
            return ageA < ageB
        end
        if a.member.name ~= b.member.name then
            return a.member.name < b.member.name
        end
        return a.member.guid < b.member.guid
    end)
    return list
end

-- The current members who know any of the recipes, one entry per member.
-- Your own linked characters count as you: left out unless includeMe is set.
local function CraftersOfSpells(spells, includeMe)
    local roster = RosterByGUID()
    local me = DW.MyGUID()
    local seen, list = {}, {}
    for _, spell in ipairs(spells) do
        for _, owner in ipairs(index and index.owners[spell] or {}) do
            local member = roster[owner.guid]
            if member and not seen[owner.guid] then
                seen[owner.guid] = true
                local group = DW.AltGroupOf and DW.AltGroupOf(member)
                local mine = IsMine(member, group, me)
                if includeMe or not mine then
                    local reachable, via = Reachable(member, group, me)
                    list[#list + 1] = {
                        member = member,
                        profession = owner.profession,
                        spell = spell,
                        isMe = mine,
                        reachable = reachable,
                        via = via,
                    }
                end
            end
        end
    end
    return SortCrafters(list)
end

-- Who can make the item: recipes known to make it, and recipes with exactly
-- its name whose item is unknown.
local function CraftersOfItem(itemID, includeMe)
    if not index then
        return {}
    end
    local spells = {}
    for _, spell in ipairs(index.byItem[itemID] or {}) do
        spells[#spells + 1] = spell
    end
    local name = ItemName(itemID)
    if name then
        for _, spell in ipairs(index.byName[name:lower()] or {}) do
            spells[#spells + 1] = spell
        end
    end
    if #spells == 0 then
        return {}
    end
    return CraftersOfSpells(spells, includeMe)
end

-- How many recipes, and from how many players, among the current members.
local function KnownCounts()
    if not index then
        return 0, 0
    end
    local roster = RosterByGUID()
    local recipes, members = 0, {}
    local count = 0
    for _, owners in pairs(index.owners) do
        local any = false
        for _, owner in ipairs(owners) do
            if roster[owner.guid] then
                any = true
                if not members[owner.guid] then
                    members[owner.guid] = true
                    count = count + 1
                end
            end
        end
        if any then
            recipes = recipes + 1
        end
    end
    return recipes, count
end

-- Searching ----------------------------------------------------------------------

-- 1 = the whole name, 2 = the name starts with it, 3 = somewhere in it.
local function Rank(name, needle)
    if not name then
        return nil
    end
    local lower = name:lower()
    if lower == needle then
        return 1
    end
    local at = lower:find(needle, 1, true)
    if at == 1 then
        return 2
    elseif at then
        return 3
    end
    return nil
end

-- Things that match the text, with who can make them. Returns nil, "short"
-- for fewer than 2 letters. Each group: key, itemID or nil, spell, name,
-- rank, crafters, reachable (how many of them can be asked now).
local function Search(text)
    local needle = Clean(text):lower()
    if LetterCount(needle) < 2 then
        return nil, "short"
    end
    EnsureIndex()
    local byKey, groups = {}, {}
    for spell in pairs(index.owners) do
        local recipeName = index.names[spell]
        local item = index.itemOf[spell]
        local itemName = item and item > 0 and ItemName(item) or nil
        local rankA, rankB = Rank(recipeName, needle), Rank(itemName, needle)
        local rank = rankA and rankB and math.min(rankA, rankB) or rankA or rankB
        if rank then
            local crafters = CraftersOfSpells({ spell }, true)
            if #crafters > 0 then
                local key = (item and item > 0) and ("i" .. item) or ("s" .. spell)
                local group = byKey[key]
                if not group then
                    group = {
                        key = key, itemID = (item and item > 0) and item or nil, spell = spell,
                        name = itemName or recipeName or ("#" .. spell), rank = rank, crafters = {}, guids = {},
                    }
                    byKey[key] = group
                    groups[#groups + 1] = group
                elseif spell < group.spell then
                    group.spell = spell
                end
                group.rank = math.min(group.rank, rank)
                for _, crafter in ipairs(crafters) do
                    if not group.guids[crafter.member.guid] then
                        group.guids[crafter.member.guid] = true
                        group.crafters[#group.crafters + 1] = crafter
                    end
                end
            end
        end
    end
    for _, group in ipairs(groups) do
        SortCrafters(group.crafters)
        group.reachable = 0
        for _, crafter in ipairs(group.crafters) do
            if crafter.reachable then
                group.reachable = group.reachable + 1
            end
        end
    end
    table.sort(groups, function(a, b)
        if a.rank ~= b.rank then
            return a.rank < b.rank
        end
        if a.reachable ~= b.reachable then
            return a.reachable > b.reachable
        end
        local nameA, nameB = a.name:lower(), b.name:lower()
        if nameA ~= nameB then
            return nameA < nameB
        end
        return a.key < b.key
    end)
    return groups
end

-- The tooltip line -----------------------------------------------------------------

local function TooltipText(crafters)
    local names = {}
    for position = 1, math.min(TIP_MAX_NAMES, #crafters) do
        local crafter = crafters[position]
        if crafter.reachable then
            names[#names + 1] = "|cff40ff40" .. crafter.member.name .. " " .. L.CS_TIP_ONLINE .. "|r"
        else
            names[#names + 1] = "|cffffffff" .. crafter.member.name .. "|r"
        end
    end
    local list = table.concat(names, ", ")
    if #crafters > TIP_MAX_NAMES then
        list = list .. " " .. L.CS_TIP_MORE:format(#crafters - TIP_MAX_NAMES)
    end
    return L.CS_TIP_LINE:format(list)
end

-- The client can report the same item twice for one tooltip. Here we remember
-- which item each tooltip has already received the line for.
local shownItem = {}

local function OnTooltipItem(tooltip, data)
    if not DW.IsMember() or db.tooltip == false then
        return
    end
    if tooltip ~= GameTooltip and tooltip ~= ItemRefTooltip then
        return
    end
    local itemID = type(data) == "table" and data.id
    if type(itemID) ~= "number" or DW.IsSecret(itemID) or shownItem[tooltip] == itemID then
        return
    end
    -- A tooltip never builds the index itself: it would be too slow while hovering.
    if not built or not index then
        MarkDirty()
        return
    end
    local ok, crafters = pcall(CraftersOfItem, itemID, false)
    if not ok or type(crafters) ~= "table" or #crafters == 0 then
        return
    end
    shownItem[tooltip] = itemID
    tooltip:AddLine(TooltipText(crafters), 1.00, 0.82, 0.00, true)
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

-- The window -----------------------------------------------------------------------

local function LastOnlineText(member)
    if member.days >= 365 then
        return L.RO_YEARS:format(math.floor(member.days / 365))
    elseif member.days >= 30 then
        return L.RO_MONTHS:format(math.floor(member.days / 30))
    elseif member.days >= 1 then
        return L.RO_DAYS:format(member.days)
    end
    return L.RO_HOURS:format(member.hours)
end

-- The member's profession as the Roster tab knows it (with its level), or just the name.
local function ProfessionOf(member, name)
    for _, profession in ipairs(DW.ProfessionsOfMember and DW.ProfessionsOfMember(member) or {}) do
        if profession.name == name then
            return profession
        end
    end
    return { name = name, level = 0, max = 0 }
end

local function GroupLink(group)
    if not group or not DW.RecipeLink then
        return nil
    end
    return DW.RecipeLink(group.spell, { itemID = group.itemID })
end

local function ShiftClick()
    return (type(IsModifiedClick) == "function" and IsModifiedClick("CHATLINK"))
        or (type(IsShiftKeyDown) == "function" and IsShiftKeyDown())
end

local function ItemIcon(group)
    if group.itemID and C_Item and C_Item.GetItemInfoInstant then
        local ok, _, _, _, _, icon = pcall(C_Item.GetItemInfoInstant, group.itemID)
        if ok and icon and not DW.IsSecret(icon) then
            return icon
        end
    end
    if C_Spell and C_Spell.GetSpellTexture then
        local ok, texture = pcall(C_Spell.GetSpellTexture, group.spell)
        if ok and texture and not DW.IsSecret(texture) then
            return texture
        end
    end
    return 134400
end

local function OnRowEnter(row)
    GameTooltip:SetOwner(row, "ANCHOR_RIGHT")
    if row.kind == "item" then
        local group = row.group
        if group.itemID and GameTooltip.SetItemByID then
            GameTooltip:SetItemByID(group.itemID)
        elseif GameTooltip.SetSpellByID then
            GameTooltip:SetSpellByID(group.spell)
        else
            GameTooltip:AddLine(group.name, 1, 1, 1)
        end
        GameTooltip:AddLine(L.RC_TIP_LINK, 0.60, 0.60, 0.60, true)
    else
        GameTooltip:AddLine(row.crafter.member.name, 1, 1, 1)
        GameTooltip:AddLine(L.CS_TIP_CARD, 0.60, 0.60, 0.60, true)
    end
    GameTooltip:Show()
end

local function OnRowClick(row)
    if row.kind == "item" then
        if ShiftClick() then
            local link = GroupLink(row.group)
            if link and DW.LinkInChat then
                DW.LinkInChat(link)
            end
        end
        return
    end
    local member = row.crafter and row.crafter.member
    if member and DW.ShowMemberCard then
        overlay:Hide()
        DW.ShowMemberCard(DW.AltCardRow and DW.AltCardRow(member) or (DW.RosterRowOf and DW.RosterRowOf(member)) or member)
    end
end

-- What to search for in the recipe window, which only matches recipe names:
-- the search text when the recipe's name holds it (the item's name may differ,
-- as with "Smelt Iron" and "Iron Bar"), else the recipe's own name.
local function RecipeFilter(row)
    local text = Clean(searchText)
    local spell = row.crafter and row.crafter.spell or (row.group and row.group.spell)
    local name = index and spell and index.names[spell]
    if text == "" or (name and name:lower():find(text:lower(), 1, true)) then
        return text
    end
    return name
end

local function CreateRowParts(row)
    -- The item line.
    row.icon = row:CreateTexture(nil, "ARTWORK")
    row.icon:SetSize(16, 16)
    row.icon:SetPoint("LEFT", 4, 0)
    row.icon:SetTexCoord(0.07, 0.93, 0.07, 0.93)
    row.name = row:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
    row.name:SetPoint("LEFT", 26, 0)
    row.name:SetWidth(330)
    row.name:SetJustifyH("LEFT")
    row.name:SetWordWrap(false)
    row.count = row:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
    row.count:SetPoint("RIGHT", -4, 0)
    row.count:SetWidth(300)
    row.count:SetJustifyH("RIGHT")
    row.count:SetWordWrap(false)

    -- The crafter line.
    row.who = row:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
    row.who:SetPoint("LEFT", 30, 0)
    row.who:SetWidth(150)
    row.who:SetJustifyH("LEFT")
    row.who:SetWordWrap(false)

    row.prof = CreateFrame("Button", nil, row)
    row.prof:SetSize(170, ROW_HEIGHT)
    row.prof:SetPoint("LEFT", 30 + 150 + 8, 0)
    row.prof.text = row.prof:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    row.prof.text:SetPoint("LEFT", 0, 0)
    row.prof.text:SetWidth(170)
    row.prof.text:SetJustifyH("LEFT")
    row.prof.text:SetWordWrap(false)
    row.prof.text:SetTextColor(1.00, 0.82, 0.00)
    row.prof:SetScript("OnEnter", function(self)
        local crafter = row.crafter
        if not crafter then
            return
        end
        GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
        GameTooltip:AddLine(L.CS_TIP_RECIPES:format(crafter.member.name, crafter.profession), 1, 1, 1, true)
        GameTooltip:Show()
    end)
    row.prof:SetScript("OnLeave", function()
        GameTooltip:Hide()
    end)
    row.prof:SetScript("OnClick", function()
        local crafter = row.crafter
        if crafter and DW.ShowRecipes then
            local member = DW.RosterRowOf and DW.RosterRowOf(crafter.member) or crafter.member
            DW.ShowRecipes(member, ProfessionOf(crafter.member, crafter.profession), RecipeFilter(row))
        end
    end)

    row.last = row:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    row.last:SetPoint("LEFT", 30 + 150 + 8 + 170 + 8, 0)
    row.last:SetWidth(220)
    row.last:SetJustifyH("LEFT")
    row.last:SetWordWrap(false)

    row.whisper = DW.CreateChip(row, 80, 18)
    row.whisper:SetPoint("RIGHT", -4, 0)
    row.whisper.label:SetJustifyH("CENTER")
    row.whisper:SetScript("OnClick", function()
        local crafter = row.crafter
        if not crafter then
            return
        end
        DW.WhisperTo((crafter.via or crafter.member).key)
        local link = GroupLink(row.group)
        if link then
            DW.InsertChatLink(link)
        end
    end)
end

local function GetRow(position)
    local row = rows[position]
    if row then
        return row
    end
    row = CreateFrame("Button", nil, overlay.content)
    row:SetSize(overlay.content:GetWidth(), ROW_HEIGHT)
    row:SetPoint("TOPLEFT", 0, -(position - 1) * ROW_HEIGHT)
    row:RegisterForClicks("LeftButtonUp")
    row:SetHighlightTexture("Interface\\QuestFrame\\UI-QuestTitleHighlight", "ADD")
    CreateRowParts(row)
    row:SetScript("OnEnter", OnRowEnter)
    row:SetScript("OnLeave", function()
        GameTooltip:Hide()
    end)
    row:SetScript("OnClick", OnRowClick)
    rows[position] = row
    return row
end

local function ShowItemRow(row, group)
    row.kind, row.group, row.crafter = "item", group, nil
    local name, _, quality = nil, nil, nil
    if group.itemID then
        name, _, quality = ItemName(group.itemID)
        if not name and not waitingFor[group.itemID] and C_Item and C_Item.RequestLoadItemDataByID then
            waitingFor[group.itemID] = true
            pcall(C_Item.RequestLoadItemDataByID, group.itemID)
        end
    end
    row.icon:SetTexture(ItemIcon(group))
    row.name:SetText(name or group.name)
    local colour = ITEM_QUALITY_COLORS and quality and ITEM_QUALITY_COLORS[quality]
    if colour then
        row.name:SetTextColor(colour.r, colour.g, colour.b)
    else
        row.name:SetTextColor(1, 1, 1)
    end
    row.count:SetText(L.CS_ITEM_COUNT:format(#group.crafters, group.reachable))
    for _, part in ipairs({ row.icon, row.name, row.count }) do
        part:Show()
    end
    for _, part in ipairs({ row.who, row.prof, row.last, row.whisper }) do
        part:Hide()
    end
end

local function ShowCrafterRow(row, group, crafter)
    row.kind, row.group, row.crafter = "crafter", group, crafter
    local member = crafter.member
    local colour = RAID_CLASS_COLORS and RAID_CLASS_COLORS[member.class]
    row.who:SetText(member.name .. (crafter.isMe and (" |cff999999" .. L.CS_YOU .. "|r") or ""))
    if colour then
        row.who:SetTextColor(colour.r, colour.g, colour.b)
    else
        row.who:SetTextColor(1, 1, 1)
    end
    local profession = ProfessionOf(member, crafter.profession)
    if (profession.level or 0) > 0 then
        row.prof.text:SetText(("%s %d"):format(crafter.profession, profession.level))
    else
        row.prof.text:SetText(crafter.profession)
    end
    if member.online then
        row.last:SetText(L.RO_ONLINE)
        row.last:SetTextColor(0.25, 1.00, 0.25)
    elseif crafter.via then
        row.last:SetText(L.CS_ONLINE_AS:format(crafter.via.name))
        row.last:SetTextColor(0.25, 1.00, 0.25)
    else
        row.last:SetText(LastOnlineText(member))
        row.last:SetTextColor(0.75, 0.75, 0.75)
    end
    row.whisper.label:SetText(L.RC_WHISPER)
    row.whisper:SetShown(crafter.reachable and not crafter.isMe)
    for _, part in ipairs({ row.icon, row.name, row.count }) do
        part:Hide()
    end
    for _, part in ipairs({ row.who, row.prof, row.last }) do
        part:Show()
    end
end

Refresh = function()
    if not overlay or not overlay:IsShown() then
        return
    end
    overlay.title:SetText(L.CS_TITLE)
    overlay.searchLabel:SetText(L.RC_SEARCH)
    overlay.tooltipLabel:SetText(L.CS_TOOLTIP_CHECK)
    overlay.close.label:SetText(L.RC_CLOSE)
    overlay.tooltipCheck:SetChecked(db.tooltip ~= false)

    EnsureIndex()
    local recipes, members = KnownCounts()
    local groups, why = Search(searchText)
    groups = groups or {}

    local count = 0
    for position, group in ipairs(groups) do
        if position > MAX_GROUPS then
            break
        end
        count = count + 1
        ShowItemRow(GetRow(count), group)
        for _, crafter in ipairs(group.crafters) do
            count = count + 1
            ShowCrafterRow(GetRow(count), group, crafter)
        end
    end
    for position = 1, count do
        rows[position]:Show()
    end
    for position = count + 1, #rows do
        rows[position].group, rows[position].crafter = nil, nil
        rows[position]:Hide()
    end
    overlay.content:SetHeight(math.max(1, count * ROW_HEIGHT))

    if #groups > MAX_GROUPS then
        overlay.info:SetText(L.CS_MORE_ITEMS:format(MAX_GROUPS, #groups))
    else
        overlay.info:SetText(L.CS_INFO:format(recipes, members))
    end
    if recipes == 0 then
        overlay.empty:SetText(L.CS_NOTHING_SHARED)
    elseif why == "short" then
        overlay.empty:SetText(L.CS_HINT)
    else
        overlay.empty:SetText(L.CS_NO_MATCH:format(Clean(searchText)))
    end
    overlay.empty:SetShown(count == 0)
end

local function CreateOverlay()
    local window = _G.DragonworldFrame
    if type(window) ~= "table" then
        return nil
    end
    local f = CreateFrame("Frame", OVERLAY_NAME, window, "BackdropTemplate")
    f:SetPoint("TOPLEFT", 14, -92)
    f:SetSize(window:GetWidth() - 28, window:GetHeight() - 106)
    f:SetFrameStrata("DIALOG")
    -- Below the recipe window (+40), which opens from here; above the member card.
    f:SetFrameLevel(window:GetFrameLevel() + 30)
    f:EnableMouse(true)
    f:SetBackdrop(DW.PANEL_BACKDROP)
    f:SetBackdropColor(0.05, 0.05, 0.07, 1)
    f:SetBackdropBorderColor(1.00, 0.82, 0.00, 1)
    f.solid = f:CreateTexture(nil, "BACKGROUND")
    f.solid:SetPoint("TOPLEFT", 3, -3)
    f.solid:SetPoint("BOTTOMRIGHT", -3, 3)
    f.solid:SetColorTexture(0.05, 0.05, 0.07, 1)
    f:Hide()
    overlay = f
    DW.RegisterOverlay(OVERLAY_NAME)

    local closeX = CreateFrame("Button", nil, f, "UIPanelCloseButton")
    closeX:SetPoint("TOPRIGHT", -2, -2)

    f.title = f:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
    f.title:SetPoint("TOPLEFT", 16, -14)

    f.searchLabel = f:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    f.searchLabel:SetPoint("TOPLEFT", 16, -46)
    f.searchBox = CreateFrame("EditBox", nil, f, "InputBoxTemplate")
    f.searchBox:SetSize(260, 22)
    f.searchBox:SetPoint("LEFT", f.searchLabel, "RIGHT", 12, 0)
    f.searchBox:SetAutoFocus(false)
    f.searchBox:SetMaxLetters(MAX_SEARCH_LETTERS)
    f.searchBox:SetScript("OnEscapePressed", function(self)
        self:ClearFocus()
    end)
    f.searchBox:SetScript("OnEnterPressed", function(self)
        self:ClearFocus()
    end)
    f.searchBox:HookScript("OnTextChanged", function(self)
        searchText = self:GetText() or ""
        QueueRefresh()
    end)

    f.info = f:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    f.info:SetPoint("TOPLEFT", 16, -72)

    local scroll = CreateFrame("ScrollFrame", "DragonworldCraftScroll", f, "ScrollFrameTemplate")
    scroll:SetPoint("TOPLEFT", 16, -92)
    scroll:SetPoint("BOTTOMRIGHT", -34, 48)
    f.content = CreateFrame("Frame", nil, scroll)
    f.content:SetSize(f:GetWidth() - 16 - 34, 1)
    scroll:SetScrollChild(f.content)

    f.empty = f:CreateFontString(nil, "OVERLAY", "GameFontDisable")
    f.empty:SetPoint("TOP", scroll, "TOP", 0, -40)
    f.empty:SetWidth(460)

    f.tooltipCheck = CreateFrame("CheckButton", nil, f, "UICheckButtonTemplate")
    f.tooltipCheck:SetSize(24, 24)
    f.tooltipCheck:SetPoint("BOTTOMLEFT", 14, 12)
    f.tooltipCheck:SetScript("OnClick", function(self)
        -- nil = on (the default), false = off.
        if self:GetChecked() then
            db.tooltip = nil
        else
            db.tooltip = false
        end
    end)
    f.tooltipLabel = f:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
    f.tooltipLabel:SetPoint("LEFT", f.tooltipCheck, "RIGHT", 4, 0)
    f.tooltipLabel:SetJustifyH("LEFT")

    f.close = DW.CreateChip(f, 100, 26)
    f.close:SetPoint("BOTTOMRIGHT", -16, 12)
    f.close.label:SetJustifyH("CENTER")
    f.close:SetScript("OnClick", function()
        f:Hide()
    end)
    return f
end

-- Opens the window over the main window. A text searches for it at once;
-- without one, the last search is kept.
function DW.ShowCraftSearch(text)
    if not _G.DragonworldFrame or not DW.IsMember() then
        return
    end
    -- Laid out for the full window: the compact view becomes it first.
    DW.ExpandWindow()
    if not overlay and not CreateOverlay() then
        return
    end
    DW.HideOverlays(OVERLAY_NAME)
    local cleaned = Clean(text)
    if cleaned ~= "" then
        overlay.searchBox:SetText(cleaned)
        searchText = cleaned
    end
    if C_GuildInfo and C_GuildInfo.GuildRoster then
        pcall(C_GuildInfo.GuildRoster)
    end
    overlay:Show()
    Refresh()
    if Clean(overlay.searchBox:GetText()) == "" then
        overlay.searchBox:SetFocus()
    end
end

-- Events ---------------------------------------------------------------------------

local function PlanLoginBuild()
    if loginPlanned or not DW.IsMember() or not (C_Timer and C_Timer.After) then
        return
    end
    loginPlanned = true
    C_Timer.After(LOGIN_DELAY, function()
        if DW.IsMember() and (dirty or not built) then
            Build()
            QueueRefresh()
        end
    end)
end

-- The member list changed. Inside the few seconds it is not read again, an
-- open window gets one more refresh when they are over (the answer to the
-- roster request made on opening usually comes then).
local lateRefreshQueued = false
local function OnRosterUpdate()
    rosterDirty = true
    QueueRefresh()
    local wait = rosterAt + ROSTER_EVERY - (GetTime and GetTime() or 0)
    if wait > 0 and not lateRefreshQueued and overlay and overlay:IsShown() and C_Timer and C_Timer.After then
        lateRefreshQueued = true
        C_Timer.After(wait + 0.05, function()
            lateRefreshQueued = false
            QueueRefresh()
        end)
    end
end

local frame = CreateFrame("Frame")
frame:SetScript("OnEvent", function(self, event, itemID)
    if event == "GUILD_ROSTER_UPDATE" then
        OnRosterUpdate()
    elseif event == "PLAYER_ENTERING_WORLD" then
        PlanLoginBuild()
    elseif event == "GET_ITEM_INFO_RECEIVED" and type(itemID) == "number" and waitingFor[itemID] then
        waitingFor[itemID] = nil
        QueueRefresh()
    end
end)
for _, event in ipairs({ "PLAYER_ENTERING_WORLD", "GUILD_ROSTER_UPDATE", "GET_ITEM_INFO_RECEIVED" }) do
    pcall(frame.RegisterEvent, frame, event)
end

if DW.OnRecipesChanged then
    DW.OnRecipesChanged(MarkDirty)
end
DW.OnLanguageChanged(function()
    Refresh()
end)
DW.OnMembershipChanged(function(isMember)
    if isMember then
        PlanLoginBuild()
    elseif overlay then
        overlay:Hide()
    end
end)

-- For other files and the tests.
--   DW.CraftersOfItem(itemID, includeMe): who can make the item (see CraftersOfSpells)
--   DW.SearchCrafts(text): the groups, or nil, "short"
--   DW.CountCraftMatches(text): how many things match (0 when too short)
DW.CraftersOfItem = CraftersOfItem

function DW.SearchCrafts(text)
    return Search(text)
end

function DW.CountCraftMatches(text)
    local groups = Search(text)
    return groups and #groups or 0
end

DW.AddDebug(MODULE_ID, function(add)
    local text = DW.DebugText
    local items, enchants, unknown = 0, 0, 0
    if index then
        for spell in pairs(index.owners) do
            local item = index.itemOf[spell]
            if item == nil then
                unknown = unknown + 1
            elseif item > 0 then
                items = items + 1
            else
                enchants = enchants + 1
            end
        end
    end
    local failures = 0
    for _ in pairs(failed) do
        failures = failures + 1
    end
    add(("index: %d recipes from %d members | items: %d | enchants (0): %d | unknown: %d | pending: %d | failed: %d"):format(
        index and index.recipes or 0, index and index.members or 0, items, enchants, unknown, #pending, failures))
    local ui = C_TradeSkillUI
    local data = DW.ProfessionData and DW.ProfessionData.recipes
    local known = 0
    for _ in pairs(type(data) == "table" and data or {}) do
        known = known + 1
    end
    add("GetRecipeSchematic: " .. text(type(ui) == "table" and type(ui.GetRecipeSchematic) == "function")
        .. " | GetRecipeOutputItemData: " .. text(type(ui) == "table" and type(ui.GetRecipeOutputItemData) == "function")
        .. " | ProfessionData recipes: " .. known
        .. " | cache v: " .. text(db.v) .. ", entries: " .. cacheCount
        .. " | tooltip: " .. (db.tooltip == false and "off" or "on"))
end)

-- Module -----------------------------------------------------------------------------

DW.RegisterModule({
    id = MODULE_ID,
    titleKey = "CS_TITLE",
    notesKey = "CS_NOTES",

    OnLoad = function(self, saved)
        if saved.v ~= CACHE_VERSION or type(saved.items) ~= "table" then
            saved.items = {}
            saved.v = CACHE_VERSION
        end
        local count = 0
        for spell, item in pairs(saved.items) do
            if type(spell) ~= "number" or type(item) ~= "number" or item < 0 then
                saved.items[spell] = nil
            else
                count = count + 1
            end
        end
        if count > MAX_CACHE then
            saved.items = {}
            count = 0
        end
        db = saved
        cacheCount = count
        -- Start over in memory too (also lets the tests begin clean).
        index = nil
        pending, pendingSet, failed = {}, {}, {}
        built, dirty = false, true
    end,

    -- "/dw craft <text>": Roster with the search window open.
    OnSlash = function(self, message)
        DW.OpenModule("roster")
        if DW.IsModuleShown("roster") then
            DW.ShowCraftSearch(message)
        end
    end,
})
