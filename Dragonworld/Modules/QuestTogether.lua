-- Dragonworld - Quest together
-- Shows the guild members who are online in your zone and have quests in
-- common with you, so you can whisper them or invite them and do the quests
-- together. Group, elite, dungeon and raid quests come first.
--
-- How it works:
--   * Your zone (the game's map ID) and the quest IDs in your quest log are
--     sent to the guild in a small addon message: at login, when you change
--     zone, and when your quests change. In cities (while resting) only the
--     zone is sent, not the quests.
--   * Others' messages are kept in memory only, never saved. Only members in
--     the same zone are shown; the titles, levels and tags come from YOUR
--     quest log.
--   * When you arrive in a zone, the message asks the others there for theirs
--     (ask = 1), and they answer once with their own (ask = 0).
--   * One checkbox turns it all off for the account: then nothing is sent
--     and nothing is shown, and an X tells the others to forget you.
--   * The buttons blink violet (Alerts.lua) when someone in your zone gets a
--     quest in common with you, unless you are set to "Do not disturb".
--
-- Messages (name DragonworldQt, fields separated by tab):
--   Q key map ask quests   key: the player's GUID ("Player-...") or "name:" ..
--                          name; map: the map ID (0 = unknown); ask: "1" asks
--                          the others in the zone for theirs; quests: the quest
--                          IDs in base 36, ascending, comma-separated, with a
--                          trailing "*" on completed ones (may be empty).
--   X key                  turned off: forget me
-- A message is only taken from the player it is about (the sender must be
-- the roster member with that key). The roster's online flag is not needed:
-- a message arriving proves the sender is online.
--
-- Saved (per account): DragonworldDB.modules.quest.off = true when turned off.
--
-- All text is in Locales.lua (the names that start with QT_, and AL_QUEST).

local ADDON_NAME, DW = ...
local L = DW.L

local MODULE_ID = "quest"
local PREFIX = "DragonworldQt" -- name of the messages; max 16 characters
local SEP = "\t"

local LOGIN_DELAY = 28     -- seconds after login before the first message
local ZONE_SETTLE = 8      -- after a zone change, wait until the map has settled
local QUEST_SETTLE = 6     -- after a quest change, wait for the next ones
local MIN_GAP = 15         -- at least this long between two messages (zone changes, asks)
local QUEST_GAP = 30       -- ...and this long when only the quests changed
local REPLY_FRESH = 60     -- no answer to an ask when our last message is this new (same map)
local REPLY_SOON = 5       -- a send already planned within this many seconds answers the ask
local MAX_TOKENS = 35      -- quests sent at most
local MAX_RECEIVE = 40     -- quests accepted at most in one message
local MAX_KEY = 60         -- longest key accepted
local MAX_MAP = 1000000    -- highest map ID accepted
local SEEN_ONLINE = 120    -- a message counts as "online" this long, before the roster catches up
local ROSTER_EVERY = 15    -- ask the game for a fresh roster at most this often
local ROSTER_MAX_AGE = 5   -- the cached roster is read again after this long
local DISPLAY_SETTLE = 1.2 -- the quest log is re-read for the list this long after a change

local ROW_HEIGHT = 44      -- a member with shared quests
local SMALL_ROW = 24       -- someone else in the zone
local HEADER_ROW = 22

local GROUP_COLOUR = "|cffff9933" -- group, elite, dungeon and raid quests
local DONE_COLOUR = "|cff40ff40"

-- The map types the zone walk-up looks at (Enum.UIMapType where it exists).
local MAP_ZONE = (Enum and Enum.UIMapType and Enum.UIMapType.Zone) or 3
local MAP_DUNGEON = (Enum and Enum.UIMapType and Enum.UIMapType.Dungeon) or 4
local MAP_MICRO = (Enum and Enum.UIMapType and Enum.UIMapType.Micro) or 5

-- Quest tags: hard-coded, with the game's constants (if any) as well. Tag 1
-- is "Group" in the modern API (Enum.QuestTag.Group); elite comes from
-- IsEliteQuest or the tag's isElite instead.
local TAG_GROUP = (Enum and Enum.QuestTag and type(Enum.QuestTag.Group) == "number" and Enum.QuestTag.Group) or 1
local TAG_RAID, TAG_DUNGEON = 62, 81
local TAG_CONSTS = Constants and Constants.QuestInfoLuaConsts

local settings -- this module's saved table (DW.modules.quest.db)

-- Small things ----------------------------------------------------------------------

local function PlainNumber(value)
    if type(value) == "number" and not DW.IsSecret(value) then
        return value
    end
    return nil
end

local function PlainString(value)
    if type(value) == "string" and not DW.IsSecret(value) then
        return value
    end
    return nil
end

local function PlainTrue(value)
    return not DW.IsSecret(value) and value == true
end

-- Calls fn(...) safely; nil if fn is missing or fails.
local function Safe(fn, ...)
    if type(fn) ~= "function" then
        return nil
    end
    local ok, a, b = pcall(fn, ...)
    if not ok then
        return nil
    end
    return a, b
end

-- The key a player is recognized by: the fixed ID, otherwise the name (the
-- same rule as Status.lua).
local function KeyOf(guid, name)
    if type(guid) == "string" and guid:find("^Player%-") then
        return guid
    end
    return "name:" .. DW.NameKey(name)
end

local function MyKey()
    local _, name = DW.CharacterKey()
    if not name then
        return nil
    end
    return KeyOf(DW.MyGUID(), name)
end

local DIGITS = "0123456789abcdefghijklmnopqrstuvwxyz"

local function ToBase36(number)
    local text = ""
    repeat
        local digit = number % 36
        text = DIGITS:sub(digit + 1, digit + 1) .. text
        number = math.floor(number / 36)
    until number == 0
    return text
end

local Invite = DW.InviteToGroup
local InMyGroup = DW.InMyGroup

local function On()
    return type(settings) == "table" and settings.off ~= true
end

local function IsRestingNow()
    return PlainTrue(Safe(IsResting))
end

local function ClassName(name, class)
    local colour = RAID_CLASS_COLORS and RAID_CLASS_COLORS[class]
    if colour and colour.r then
        local function Byte(value)
            return math.floor(math.max(0, math.min(1, value)) * 255 + 0.5)
        end
        return ("|cff%02x%02x%02x%s|r"):format(Byte(colour.r), Byte(colour.g), Byte(colour.b), name)
    end
    return name
end

local function StatusIcon(member)
    local code = DW.StatusOf(member)
    local status = code and DW.STATUS_BY_CODE[code]
    if status then
        return " |T" .. status.icon .. ":14|t", status, code
    end
    return "", nil, code
end

-- The roster -------------------------------------------------------------------------

-- The roster with lookups by GUID and by "name:" key. Read again after
-- GUILD_ROSTER_UPDATE, or when it is a few seconds old.
local roster = { dirty = true, at = 0 }

local function RosterIndex()
    local now = GetTime()
    if roster.dirty or not roster.list or now - roster.at > ROSTER_MAX_AGE then
        roster.list = DW.ReadGuildRoster()
        roster.byGuid, roster.byName = {}, {}
        for _, member in ipairs(roster.list) do
            if member.guid then
                roster.byGuid[member.guid] = member
            end
            roster.byName["name:" .. DW.NameKey(member.key)] = member
        end
        roster.dirty = false
        roster.at = now
    end
    return roster
end

local function MemberOf(key)
    if type(key) ~= "string" then
        return nil
    end
    local index = RosterIndex()
    if key:find("^Player%-") then
        return index.byGuid[key]
    end
    return index.byName[key]
end

-- The member a message is about, if the game says that member sent it. The
-- roster's online flag is NOT checked: it lags behind logins.
local function SenderIs(key, sender)
    if type(sender) ~= "string" then
        return nil
    end
    local member = MemberOf(key)
    if not member or not DW.SameCharacter(member.key, sender) then
        return nil
    end
    return member
end

local function IsMe(member)
    local guid = DW.MyGUID()
    if guid and member.guid then
        return member.guid == guid
    end
    local name = DW.CharacterKey()
    return name ~= nil and DW.SameCharacter(member.key, name)
end

local rosterAskedAt
local function RequestRoster()
    if not (C_GuildInfo and type(C_GuildInfo.GuildRoster) == "function") then
        return
    end
    local now = GetTime()
    if rosterAskedAt and now - rosterAskedAt < ROSTER_EVERY then
        return
    end
    rosterAskedAt = now
    pcall(C_GuildInfo.GuildRoster)
end

-- Where you are ------------------------------------------------------------------------

local myMap, rawMap, myZoneText = 0, 0, ""

local function MapInfo(id)
    if not (C_Map and type(C_Map.GetMapInfo) == "function") then
        return nil
    end
    local info = Safe(C_Map.GetMapInfo, id)
    if type(info) == "table" then
        return info
    end
    return nil
end

-- Your map: the game's best map for you. Outside instances a cave or a small
-- building inside a zone counts as the zone, so people in the mine and
-- outside it see each other. A cave that is not directly inside a zone keeps
-- its own map.
local function ReadMyMap()
    local id = 0
    if C_Map and type(C_Map.GetBestMapForUnit) == "function" then
        local value = PlainNumber(Safe(C_Map.GetBestMapForUnit, "player"))
        if value and value > 0 then
            id = math.floor(value)
        end
    end
    rawMap = id
    if id > 0 and not DW.InstanceInfo() then
        local current = id
        for _ = 1, 5 do
            local info = MapInfo(current)
            local mapType = info and PlainNumber(info.mapType)
            if mapType ~= MAP_DUNGEON and mapType ~= MAP_MICRO then
                break
            end
            local parentID = PlainNumber(info.parentMapID)
            local parent = parentID and parentID > 0 and MapInfo(parentID)
            if not parent or PlainNumber(parent.mapType) ~= MAP_ZONE then
                break
            end
            current = parentID
        end
        id = current
    end
    myMap = id
    myZoneText = PlainString(Safe(GetRealZoneText)) or ""
    return myMap
end

-- The name of your zone for the panel, or nil if the addon does not know it.
local function ZoneName()
    local info = myMap > 0 and MapInfo(myMap)
    local name = info and PlainString(info.name)
    if name and name ~= "" then
        return name
    end
    if myZoneText ~= "" then
        return myZoneText
    end
    return nil
end

-- Your quests ---------------------------------------------------------------------------

-- [questID] = { id, title, level, elite, groupSize, dungeon, raid, groupish, complete }
local myQuests = {}
local myQuestCount = 0

local function IsTag(tagID, fixed, constName)
    if tagID == fixed then
        return true
    end
    local const = TAG_CONSTS and PlainNumber(TAG_CONSTS[constName])
    return const ~= nil and tagID == const
end

local function ReadMyQuests()
    local list, count = {}, 0
    local log = C_QuestLog
    local entries = log and PlainNumber(Safe(log.GetNumQuestLogEntries)) or 0
    for index = 1, entries do
        local info = Safe(log.GetInfo, index)
        local id = type(info) == "table" and PlainNumber(info.questID)
        if id and id > 0 and not PlainTrue(info.isHeader) and not PlainTrue(info.isHidden) and not PlainTrue(info.isTask) then
            id = math.floor(id)
            local title = PlainString(info.title) or "?"
            local tag = Safe(log.GetQuestTagInfo, id)
            local tagID = type(tag) == "table" and PlainNumber(tag.tagID) or nil
            local eliteConst = TAG_CONSTS and PlainNumber(TAG_CONSTS.QUEST_INFO_ELITE_ID)
            local elite = PlainTrue(Safe(log.IsEliteQuest, id))
                or (type(tag) == "table" and PlainTrue(tag.isElite))
                or (tagID ~= nil and eliteConst ~= nil and eliteConst ~= TAG_GROUP and tagID == eliteConst)
            local group = tagID ~= nil and tagID == TAG_GROUP
            local dungeon = tagID ~= nil and IsTag(tagID, TAG_DUNGEON, "QUEST_INFO_DUNGEON_ID")
            local raid = tagID ~= nil and IsTag(tagID, TAG_RAID, "QUEST_INFO_RAID_ID")
            local suggested = PlainNumber(info.suggestedGroup) or 0
            local groupSize = suggested > 1 and suggested or (PlainNumber(Safe(log.GetSuggestedGroupSize, id)) or 0)
            if groupSize <= 1 then
                groupSize = 0
            end
            local level = PlainNumber(info.level) or 0
            if level <= 0 then
                level = PlainNumber(info.difficultyLevel) or 0
            end
            list[id] = {
                id = id, title = title, level = level, elite = elite and true or false,
                groupSize = groupSize, group = group, dungeon = dungeon, raid = raid,
                groupish = (elite or group or groupSize > 1 or dungeon or raid) and true or false,
                complete = PlainTrue(Safe(log.IsComplete, id)),
            }
            count = count + 1
        end
    end
    myQuests, myQuestCount = list, count
    return list
end

-- Groupish first, then the highest level, then by title.
local function QuestOrder(a, b)
    if a.groupish ~= b.groupish then
        return a.groupish
    end
    if a.level ~= b.level then
        return a.level > b.level
    end
    if a.title ~= b.title then
        return a.title < b.title
    end
    return a.id < b.id
end

-- The quests as message tokens: base 36, ascending, "*" for completed. At most
-- MAX_TOKENS: groupish quests are kept first.
local function QuestTokens()
    local all = {}
    for _, quest in pairs(myQuests) do
        all[#all + 1] = quest
    end
    table.sort(all, function(a, b)
        if a.groupish ~= b.groupish then
            return a.groupish
        end
        return a.id < b.id
    end)
    local kept = {}
    for index = 1, math.min(#all, MAX_TOKENS) do
        kept[index] = all[index]
    end
    table.sort(kept, function(a, b) return a.id < b.id end)
    local tokens = {}
    for index, quest in ipairs(kept) do
        tokens[index] = ToBase36(quest.id) .. (quest.complete and "*" or "")
    end
    return tokens
end

-- Sending ---------------------------------------------------------------------------------

local Send = DW.CreateSender(PREFIX)

-- One planned send at a time. A newer request is merged into it.
local plan = {
    gen = 0,            -- raised to cancel a planned send
    pending = false,
    due = 0,            -- GetTime() when it fires
    ask = "0",          -- "1" asks, "auto" asks if the map changed, "0" does not
    zone = false,       -- something else than the quests changed (MIN_GAP applies)
    force = false,      -- send even when nothing changed (an answer)
    hello = false,      -- the login message is planned; nothing moves it earlier
}
local helloDone = false
local replyPending = false
local askOwed = false -- an ask was held back while resting; the next send outside asks
local lastSentAt, lastSentSig, lastSentMap, lastLength
local Recompute

local function MergeAsk(old, new)
    if old == "1" or new == "1" then
        return "1"
    end
    if old == "auto" or new == "auto" then
        return "auto"
    end
    return "0"
end

local function Fire(gen)
    if gen ~= plan.gen then
        return
    end
    -- On a flight path every zone crossed would ask that zone: wait until
    -- the flight is over, keeping what was planned.
    if On() and PlainTrue(Safe(UnitOnTaxi, "player")) then
        plan.gen = plan.gen + 1
        plan.due = GetTime() + ZONE_SETTLE
        local again = plan.gen
        C_Timer.After(ZONE_SETTLE, function()
            Fire(again)
        end)
        return
    end
    local ask, force = plan.ask, plan.force
    plan.pending, plan.ask, plan.zone, plan.force, plan.hello = false, "0", false, false, false
    replyPending = false
    local key = MyKey()
    if not On() or not DW.IsMember() or not key then
        return
    end
    ReadMyMap()
    ReadMyQuests()
    local resting = IsRestingNow()
    local tokens = resting and {} or QuestTokens()
    local wanted = ask == "1" or (ask == "auto" and myMap ~= lastSentMap)
    if resting then
        -- Nobody is asked from a city, but the first send outside asks (logging
        -- in at an inn, then walking out into the zone).
        askOwed = askOwed or wanted
        ask = "0"
    elseif wanted or askOwed then
        ask = "1"
        askOwed = false
    else
        ask = "0"
    end
    local function Build()
        return table.concat({ "Q", key, ("%d"):format(myMap), ask, table.concat(tokens, ",") }, SEP)
    end
    local message = Build()
    while #message > 255 and #tokens > 0 do
        table.remove(tokens)
        message = Build()
    end
    local sig = myMap .. "|" .. table.concat(tokens, ",")
    if ask ~= "1" and not force and sig == lastSentSig then
        if Recompute then
            Recompute()
        end
        return
    end
    Send(message)
    lastSentAt, lastSentSig, lastSentMap, lastLength = GetTime(), sig, myMap, #message
    if Recompute then
        Recompute()
    end
end

-- Plans a send. ask: 1 asks the others, 0 does not, nil asks if the map has
-- changed. questOnly: only the quests changed (QUEST_GAP). force: send even
-- if nothing changed. The send never comes sooner than MIN_GAP (QUEST_GAP)
-- after the last one, and a planned send is only ever moved earlier.
local function ScheduleSend(ask, delay, questOnly, force)
    if not On() or not DW.IsMember() then
        return
    end
    plan.ask = MergeAsk(plan.pending and plan.ask or "0", ask == 1 and "1" or (ask == nil and "auto" or "0"))
    plan.zone = (plan.pending and plan.zone) or not questOnly
    plan.force = (plan.pending and plan.force) or (force and true or false)
    local now = GetTime()
    local wait = delay
    if lastSentAt then
        local gapLeft = lastSentAt + (plan.zone and MIN_GAP or QUEST_GAP) - now
        if gapLeft > wait then
            wait = gapLeft + 0.05
        end
    end
    local due = now + wait
    if plan.pending and (plan.hello or plan.due <= due) then
        return
    end
    plan.gen = plan.gen + 1
    plan.pending = true
    plan.due = due
    local gen = plan.gen
    C_Timer.After(wait, function()
        Fire(gen)
    end)
end

-- The login message, once per session.
local function PlanHello()
    if helloDone or not On() or not DW.IsMember() then
        return
    end
    helloDone = true
    ScheduleSend(1, LOGIN_DELAY)
    plan.hello = plan.pending
end

-- Others ---------------------------------------------------------------------------------

-- [key] = { map, quests = { [id] = completed }, count, at = GetTime() }; in memory only.
local known = {}
local buddySince = {} -- [key] = DW.AlertNow() when that member got a quest in common with you

-- Is the member in your zone? The map IDs when both are known, otherwise the
-- zone name in the roster.
local function InMyZone(member, data)
    if data and data.map ~= 0 and myMap ~= 0 then
        return data.map == myMap
    elseif myZoneText ~= "" then
        return member.zone == myZoneText
    end
    return false
end

-- The quests the member has in common with you: a sorted list of your quest
-- entries, and how many of them are groupish.
local function SharedWith(data)
    local shared, groupCount = {}, 0
    if not data then
        return shared, 0
    end
    for id in pairs(data.quests) do
        local quest = myQuests[id]
        if quest then
            shared[#shared + 1] = quest
            if quest.groupish then
                groupCount = groupCount + 1
            end
        end
    end
    table.sort(shared, QuestOrder)
    return shared, groupCount
end

local STATUS_RANK = { Q = 0, C = 2 }

local function NameOrder(a, b)
    local x, y = a.member.name:lower(), b.member.name:lower()
    if x ~= y then
        return x < y
    end
    return a.key < b.key
end

-- The two lists: members in your zone with quests in common (rows), and the
-- others in your zone (compact). Both empty when turned off.
local function Collect()
    local rows, compact = {}, {}
    if not On() or not DW.IsMember() then
        return rows, compact
    end
    local now = GetTime()
    for _, member in ipairs(RosterIndex().list) do
        if not IsMe(member) then
            local key = KeyOf(member.guid, member.key)
            local data = known[key]
            local online = member.online or (data ~= nil and now - data.at <= SEEN_ONLINE)
            if online and InMyZone(member, data) then
                local shared, groupCount = SharedWith(data)
                local entry = { member = member, key = key, data = data, shared = shared, groupCount = groupCount }
                if #shared > 0 then
                    local _, _, code = StatusIcon(member)
                    entry.statusRank = STATUS_RANK[code or ""] or 1
                    rows[#rows + 1] = entry
                else
                    compact[#compact + 1] = entry
                end
            end
        end
    end
    table.sort(rows, function(a, b)
        if a.statusRank ~= b.statusRank then
            return a.statusRank < b.statusRank
        end
        if a.groupCount ~= b.groupCount then
            return a.groupCount > b.groupCount
        end
        if #a.shared ~= #b.shared then
            return #a.shared > #b.shared
        end
        return NameOrder(a, b)
    end)
    table.sort(compact, function(a, b)
        if (a.data ~= nil) ~= (b.data ~= nil) then
            return a.data ~= nil
        end
        return NameOrder(a, b)
    end)
    return rows, compact
end

-- The panel ----------------------------------------------------------------------------

local panel
local memberRows, smallRows = {}, {}
local RefreshPanel
local refreshQueued = false

local function QueueRefresh()
    if refreshQueued or not panel or not panel:IsVisible() then
        return
    end
    refreshQueued = true
    C_Timer.After(0.25, function()
        refreshQueued = false
        RefreshPanel()
    end)
end

-- Forgets members who left the guild or went offline, notes who got quests
-- in common, and lets the blinking and the panel know.
Recompute = function()
    local now = GetTime()
    for key, data in pairs(known) do
        local member = MemberOf(key)
        if not member or (not member.online and now - data.at > SEEN_ONLINE) then
            known[key] = nil
        end
    end
    local rows = Collect()
    local still = {}
    for _, entry in ipairs(rows) do
        still[entry.key] = true
        if not buddySince[entry.key] then
            buddySince[entry.key] = DW.AlertNow()
        end
    end
    for key in pairs(buddySince) do
        if not still[key] then
            buddySince[key] = nil
        end
    end
    if DW.QueueAlertRefresh then
        DW.QueueAlertRefresh()
    end
    QueueRefresh()
end

-- "[24+] Title": the level (with + for elite) and the title.
local function QuestLabel(quest)
    if quest.level > 0 then
        return ("[%d%s] %s"):format(quest.level, quest.elite and "+" or "", quest.title)
    end
    return quest.title
end

local function QuestTags(quest)
    local tags = {}
    if quest.elite then
        tags[#tags + 1] = L.QT_TAG_ELITE
    end
    if quest.groupSize > 1 then
        tags[#tags + 1] = L.QT_TAG_GROUP:format(quest.groupSize)
    elseif quest.group then
        tags[#tags + 1] = L.QT_TAG_GROUP_ANY
    end
    if quest.dungeon then
        tags[#tags + 1] = L.QT_TAG_DUNGEON
    end
    if quest.raid then
        tags[#tags + 1] = L.QT_TAG_RAID
    end
    return table.concat(tags, ", ")
end

-- The second line of a row: the shared quests, groupish first in orange,
-- "(done)" in green when the member has completed it.
local function SharedLine(entry)
    local parts = {}
    for _, quest in ipairs(entry.shared) do
        local text = QuestLabel(quest)
        if quest.groupish then
            text = GROUP_COLOUR .. text .. "|r"
        end
        if entry.data and entry.data.quests[quest.id] then
            text = text .. " " .. DONE_COLOUR .. "(" .. L.QT_DONE .. ")|r"
        end
        parts[#parts + 1] = text
    end
    return table.concat(parts, ", ")
end

local function ShowRowTooltip(row)
    local entry = row.entry
    if not entry then
        return
    end
    local member = entry.member
    GameTooltip:SetOwner(row, "ANCHOR_RIGHT")
    GameTooltip:AddLine(ClassName(member.name, member.class))
    GameTooltip:AddLine(L.MC_INFO:format(member.level or 0, member.rank or ""), 1, 1, 1)
    local _, status = StatusIcon(member)
    if status then
        GameTooltip:AddLine(L[status.key], 1.00, 0.82, 0.00)
    end
    if #entry.shared > 0 then
        GameTooltip:AddLine(" ")
        GameTooltip:AddLine(L.QT_TIP_HEADER, 1.00, 0.82, 0.00)
        for _, quest in ipairs(entry.shared) do
            local r, g, b = 1, 1, 1
            if quest.groupish then
                r, g, b = 1.00, 0.60, 0.20
            end
            GameTooltip:AddDoubleLine(QuestLabel(quest), QuestTags(quest), r, g, b, 0.8, 0.8, 0.8)
            if entry.data and entry.data.quests[quest.id] then
                GameTooltip:AddLine("  " .. L.QT_TIP_THEY_DONE:format(member.name), 0.25, 1.00, 0.25)
            end
            if quest.complete then
                GameTooltip:AddLine("  " .. L.QT_TIP_YOU_DONE, 0.25, 1.00, 0.25)
            end
        end
    else
        GameTooltip:AddLine(entry.data and L.QT_NO_SHARED or L.QT_NO_ADDON, 0.6, 0.6, 0.6)
    end
    GameTooltip:Show()
end

local function WhisperRow(row)
    local entry = row.entry
    if not entry then
        return
    end
    DW.WhisperTo(entry.member.key)
    local first = entry.shared[1]
    if row.kind == "member" and first and type(GetQuestLink) == "function" then
        local link = PlainString(Safe(GetQuestLink, first.id))
        if link and link ~= "" then
            DW.InsertChatLink(link)
        end
    end
end

-- The parts both kinds of row have: name, level, Whisper, Invite.
local function BuildRow(parent, width, height, kind)
    local row = CreateFrame("Button", nil, parent)
    row:SetSize(width, height - 2)
    row:RegisterForClicks("LeftButtonUp")
    row:SetHighlightTexture("Interface\\QuestFrame\\UI-QuestTitleHighlight", "ADD")
    row.kind = kind

    row.name = row:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
    row.name:SetPoint("TOPLEFT", 4, -5)
    row.name:SetWidth(150)
    row.name:SetJustifyH("LEFT")
    row.name:SetWordWrap(false)

    row.level = row:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    row.level:SetPoint("TOPLEFT", 160, -6)
    row.level:SetWidth(30)
    row.level:SetJustifyH("RIGHT")

    row.info = row:CreateFontString(nil, "OVERLAY", kind == "member" and "GameFontNormalSmall" or "GameFontDisableSmall")
    row.info:SetPoint("TOPLEFT", 200, -6)
    row.info:SetWidth(kind == "member" and 180 or 210)
    row.info:SetJustifyH("LEFT")
    row.info:SetWordWrap(false)

    row.invite = DW.CreateButton(row, 70, 20, "gold")
    row.invite:SetPoint("TOPRIGHT", -4, -2)
    row.invite:SetScript("OnClick", function()
        if row.entry then
            Invite(row.entry.member.key)
        end
    end)
    row.invite:HookScript("OnEnter", function(self)
        if not self:IsEnabled() then
            GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
            GameTooltip:AddLine(L.QT_CANT_INVITE, 1, 1, 1, true)
            GameTooltip:Show()
        end
    end)
    row.invite:HookScript("OnLeave", function()
        GameTooltip:Hide()
    end)

    row.inGroup = row:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
    row.inGroup:SetPoint("TOPRIGHT", -4, -6)
    row.inGroup:SetJustifyH("RIGHT")

    row.whisper = DW.CreateChip(row, 70, 20)
    row.whisper:SetPoint("RIGHT", row.invite, "LEFT", -6, 0)
    row.whisper.label:SetJustifyH("CENTER")
    row.whisper:SetScript("OnClick", function()
        WhisperRow(row)
    end)

    row:SetScript("OnClick", function(self)
        if self.entry and DW.ShowMemberCard then
            -- A filled copy, so the card shows the member's professions too.
            local member = self.entry.member
            DW.ShowMemberCard(DW.AltCardRow and DW.AltCardRow(member) or (DW.RosterRowOf and DW.RosterRowOf(member)) or member)
        end
    end)
    row:SetScript("OnEnter", ShowRowTooltip)
    row:SetScript("OnLeave", function()
        GameTooltip:Hide()
    end)

    if kind == "member" then
        row.quests = row:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
        row.quests:SetPoint("BOTTOMLEFT", 4, 4)
        row.quests:SetWidth(width - 8)
        row.quests:SetJustifyH("LEFT")
        row.quests:SetWordWrap(false)
    end
    return row
end

local function FillRow(row, entry)
    row.entry = entry
    local member = entry.member
    row.name:SetText(ClassName(member.name, member.class) .. StatusIcon(member))
    row.level:SetText(tostring(member.level or 0))
    if row.kind == "member" then
        local count = #entry.shared
        row.info:SetText(count == 1 and L.QT_SHARED_ONE or L.QT_SHARED_MANY:format(count))
        row.quests:SetText(SharedLine(entry))
    else
        row.info:SetText(entry.data and L.QT_NO_SHARED or L.QT_NO_ADDON)
    end
    row.whisper.label:SetText(L.DG_WHISPER)
    row.invite.label:SetText(L.DG_INVITE)
    row.inGroup:SetText(L.QT_IN_GROUP)
    if InMyGroup(member) then
        row.invite:Hide()
        row.inGroup:Show()
    else
        row.inGroup:Hide()
        row.invite:Show()
        row.invite:SetActive(DW.CanInviteToGroup())
    end
end

local function GetRow(pool, index, kind)
    local row = pool[index]
    if not row then
        local height = kind == "member" and ROW_HEIGHT or SMALL_ROW
        row = BuildRow(panel.content, panel.content:GetWidth(), height, kind)
        pool[index] = row
    end
    return row
end

RefreshPanel = function()
    if not panel or not panel:IsVisible() then
        return
    end
    local f = panel
    f.title:SetText(L.QT_TITLE)
    f.shareLabel:SetText(L.QT_SHARE_CHECK)
    f.shareCheck:SetChecked(On())
    f.offText:SetText(L.QT_OFF_TEXT)
    f.turnOn.label:SetText(L.QT_TURN_ON)

    if not On() then
        f.scroll:Hide()
        f.zone:Hide()
        f.empty:Hide()
        f.offText:Show()
        f.turnOn:Show()
        return
    end
    f.offText:Hide()
    f.turnOn:Hide()
    f.scroll:Show()
    f.zone:Show()

    local zoneName = ZoneName()
    f.zone:SetText(zoneName and L.QT_ZONE:format(zoneName) or L.QT_ZONE_UNKNOWN)

    local rows, compact = Collect()
    local y = 0
    if #rows > 0 then
        f.sameHeader:ClearAllPoints()
        f.sameHeader:SetPoint("TOPLEFT", 4, y - 3)
        f.sameHeader:SetText(L.QT_SAME_HEADER:format(#rows))
        f.sameHeader:Show()
        y = y - HEADER_ROW
    else
        f.sameHeader:Hide()
    end
    for index, entry in ipairs(rows) do
        local row = GetRow(memberRows, index, "member")
        row:ClearAllPoints()
        row:SetPoint("TOPLEFT", 0, y)
        FillRow(row, entry)
        row:Show()
        y = y - ROW_HEIGHT
    end
    for index = #rows + 1, #memberRows do
        memberRows[index]:Hide()
        memberRows[index].entry = nil
    end
    if #compact > 0 then
        f.alsoHeader:ClearAllPoints()
        f.alsoHeader:SetPoint("TOPLEFT", 4, y - 3 - (#rows > 0 and 6 or 0))
        f.alsoHeader:SetText(L.QT_ALSO_HEADER:format(zoneName or "?", #compact))
        f.alsoHeader:Show()
        y = y - HEADER_ROW - (#rows > 0 and 6 or 0)
    else
        f.alsoHeader:Hide()
    end
    for index, entry in ipairs(compact) do
        local row = GetRow(smallRows, index, "small")
        row:ClearAllPoints()
        row:SetPoint("TOPLEFT", 0, y)
        FillRow(row, entry)
        row:Show()
        y = y - SMALL_ROW
    end
    for index = #compact + 1, #smallRows do
        smallRows[index]:Hide()
        smallRows[index].entry = nil
    end
    f.content:SetHeight(math.max(1, -y))

    if #rows == 0 and #compact == 0 then
        f.empty:SetText(L.QT_EMPTY:format(zoneName or "?"))
        f.empty:Show()
    else
        f.empty:Hide()
    end
end

-- Turning it on and off -------------------------------------------------------------------

local function SetOn(on)
    if type(settings) ~= "table" then
        return
    end
    if on then
        if settings.off ~= true then
            RefreshPanel()
            return
        end
        settings.off = nil
        helloDone = true
        ReadMyMap()
        ReadMyQuests()
        ScheduleSend(1, 0)
    else
        if settings.off == true then
            RefreshPanel()
            return
        end
        settings.off = true
        local key = MyKey()
        if key and DW.IsMember() then
            Send("X" .. SEP .. key)
        end
        -- Cancel what was planned, and forget the others.
        plan.gen = plan.gen + 1
        plan.pending, plan.ask, plan.zone, plan.force, plan.hello = false, "0", false, false, false
        replyPending, askOwed = false, false
        lastSentSig, lastSentMap = nil, nil
        known, buddySince = {}, {}
    end
    Recompute()
    RefreshPanel()
end

local function CreatePanel(parent)
    local f = CreateFrame("Frame", nil, parent)
    f:SetAllPoints(parent)
    panel = f

    f.title = f:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
    f.title:SetPoint("TOP", 0, -12)

    f.zone = f:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
    f.zone:SetPoint("TOPLEFT", 14, -44)
    f.zone:SetWidth(584)
    f.zone:SetJustifyH("LEFT")
    f.zone:SetWordWrap(false)

    local scroll = CreateFrame("ScrollFrame", "DragonworldQuestScroll", f, "ScrollFrameTemplate")
    scroll:SetPoint("TOPLEFT", 10, -68)
    scroll:SetPoint("BOTTOMRIGHT", -30, 40)
    f.scroll = scroll
    f.content = CreateFrame("Frame", nil, scroll)
    f.content:SetSize(parent:GetWidth() - 40, 1)
    scroll:SetScrollChild(f.content)

    f.sameHeader = f.content:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    f.alsoHeader = f.content:CreateFontString(nil, "OVERLAY", "GameFontNormal")

    f.empty = f:CreateFontString(nil, "OVERLAY", "GameFontDisable")
    f.empty:SetPoint("TOP", scroll, "TOP", 0, -40)
    f.empty:SetWidth(420)

    -- Turned off: what that means, and a button to turn it on.
    f.offText = f:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
    f.offText:SetPoint("TOP", 0, -120)
    f.offText:SetWidth(420)
    f.turnOn = DW.CreateButton(f, 160, 28, "gold")
    f.turnOn:SetPoint("TOP", f.offText, "BOTTOM", 0, -16)
    f.turnOn:SetScript("OnClick", function()
        SetOn(true)
    end)

    -- On or off for the account.
    f.shareCheck = CreateFrame("CheckButton", nil, f, "UICheckButtonTemplate")
    f.shareCheck:SetSize(22, 22)
    f.shareCheck:SetPoint("BOTTOMLEFT", 10, 8)
    f.shareLabel = f.shareCheck:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    f.shareLabel:SetPoint("LEFT", f.shareCheck, "RIGHT", 2, 0)
    f.shareLabel:SetWidth(520)
    f.shareLabel:SetJustifyH("LEFT")
    f.shareLabel:SetWordWrap(false)
    f.shareCheck:SetScript("OnClick", function(self)
        SetOn(self:GetChecked() and true or false)
    end)
    f.shareCheck:SetScript("OnEnter", function(self)
        GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
        GameTooltip:AddLine(L.QT_SHARE_CHECK, 1.00, 0.82, 0.00)
        GameTooltip:AddLine(L.QT_FOOTER, 1, 1, 1, true)
        GameTooltip:Show()
    end)
    f.shareCheck:SetScript("OnLeave", function()
        GameTooltip:Hide()
    end)

    f:SetScript("OnShow", function()
        -- A fresh roster, so "online" and the zones are right.
        RequestRoster()
        ReadMyMap()
        ReadMyQuests()
        Recompute()
        RefreshPanel()
    end)
    return f
end

-- Receiving ----------------------------------------------------------------------------------

-- The quests field of a Q: { [id] = completed }, count; nil if any part is broken.
local function ParseQuests(text)
    local quests, count = {}, 0
    if text == "" then
        return quests, 0
    end
    for token in (text .. ","):gmatch("([^,]*),") do
        count = count + 1
        if count > MAX_RECEIVE then
            return nil
        end
        local base, star = token:match("^(%w+)(%*?)$")
        if not base or #base > 6 then
            return nil
        end
        local id = tonumber(base, 36)
        if not id or id <= 0 then
            return nil
        end
        quests[id] = star == "*"
    end
    return quests, count
end

-- Someone in your zone asked: answer once with your own, unless your last
-- message is new enough and your map has not changed since. Someone we had
-- heard nothing from (just logged in) may have missed that message, so they
-- always get an answer.
local function ConsiderReply(member, data, wasKnown)
    if replyPending or IsRestingNow() then
        return
    end
    ReadMyMap()
    if not InMyZone(member, data) then
        return
    end
    if wasKnown and lastSentAt and GetTime() - lastSentAt < REPLY_FRESH and myMap == lastSentMap then
        return
    end
    replyPending = true
    if plan.pending and plan.due - GetTime() <= REPLY_SOON then
        plan.force = true
        return
    end
    ScheduleSend(0, 1.2 + math.random() * 4, false, true)
end

DW.OnGuildMessage(PREFIX, function(text, sender)
    if not On() then
        return
    end
    local fields = {}
    for field in (text .. SEP):gmatch("(.-)" .. SEP) do
        fields[#fields + 1] = field
    end
    local kind, key = fields[1], fields[2]
    if type(key) ~= "string" or #key < 1 or #key > MAX_KEY then
        return
    end
    if kind == "Q" and #fields >= 5 then
        local map = fields[3]:match("^%d+$") and tonumber(fields[3])
        local ask = fields[4]
        if not map or map > MAX_MAP or (ask ~= "0" and ask ~= "1") then
            return
        end
        local quests, count = ParseQuests(fields[5])
        if not quests then
            return
        end
        local member = SenderIs(key, sender)
        if not member then
            return
        end
        local wasKnown = known[key] ~= nil
        local data = { map = map, quests = quests, count = count, at = GetTime() }
        known[key] = data
        if ask == "1" then
            ConsiderReply(member, data, wasKnown)
        end
        Recompute()
    elseif kind == "X" then
        if not SenderIs(key, sender) then
            return
        end
        known[key] = nil
        buddySince[key] = nil
        Recompute()
    end
end)

-- Events ----------------------------------------------------------------------------------

local displayQueued = false

-- The list follows the quest log a moment after it changes (nothing is sent).
local function PlanDisplayRead()
    if displayQueued or not On() then
        return
    end
    displayQueued = true
    C_Timer.After(DISPLAY_SETTLE, function()
        displayQueued = false
        ReadMyQuests()
        Recompute()
    end)
end

local QUEST_EVENTS = { QUEST_ACCEPTED = true, QUEST_REMOVED = true, QUEST_TURNED_IN = true, QUEST_LOG_UPDATE = true }

local frame = CreateFrame("Frame")
frame:SetScript("OnEvent", function(self, event)
    if event == "GUILD_ROSTER_UPDATE" then
        roster.dirty = true
    end
    if not DW.IsMember() then
        return
    end
    if event == "PLAYER_ENTERING_WORLD" then
        if not helloDone then
            PlanHello()
        else
            ScheduleSend(nil, ZONE_SETTLE)
        end
    elseif event == "ZONE_CHANGED_NEW_AREA" then
        if On() then
            RequestRoster()
        end
        ScheduleSend(nil, ZONE_SETTLE)
    elseif QUEST_EVENTS[event] then
        -- In cities only the zone is sent, so quest changes change nothing there.
        if not IsRestingNow() then
            ScheduleSend(0, QUEST_SETTLE, true)
        end
        if event == "QUEST_LOG_UPDATE" then
            PlanDisplayRead()
        end
    elseif event == "PLAYER_UPDATE_RESTING" then
        ScheduleSend(nil, QUEST_SETTLE)
    elseif event == "GUILD_ROSTER_UPDATE" or event == "GROUP_ROSTER_UPDATE" then
        Recompute()
    end
end)
for _, event in ipairs({ "PLAYER_ENTERING_WORLD", "ZONE_CHANGED_NEW_AREA", "QUEST_LOG_UPDATE", "QUEST_ACCEPTED", "QUEST_REMOVED",
    "QUEST_TURNED_IN", "GUILD_ROSTER_UPDATE", "GROUP_ROSTER_UPDATE", "PLAYER_UPDATE_RESTING" }) do
    pcall(frame.RegisterEvent, frame, event)
end

DW.OnStatusChanged(function()
    Recompute()
end)

DW.OnMembershipChanged(function(member)
    roster.dirty = true
    if member then
        PlanHello()
    else
        known, buddySince = {}, {}
        -- Forget what was sent too, so that joining again says hello afresh.
        helloDone, askOwed, replyPending = false, false, false
        lastSentSig, lastSentMap = nil, nil
        plan.gen = plan.gen + 1
        plan.pending, plan.ask, plan.zone, plan.force, plan.hello = false, "0", false, false, false
    end
    Recompute()
end)

DW.OnLanguageChanged(function()
    RefreshPanel()
end)

-- Public --------------------------------------------------------------------------------

-- The members in your zone with quests in common, in the panel's order:
-- { { member, shared = { questID, ... }, groupCount }, ... }. Empty when off.
function DW.QuestBuddies()
    local list = {}
    for _, entry in ipairs((Collect())) do
        local ids = {}
        for index, quest in ipairs(entry.shared) do
            ids[index] = quest.id
        end
        list[#list + 1] = { member = entry.member, shared = ids, groupCount = entry.groupCount }
    end
    return list
end

function DW.IsQuestTogetherOn()
    return On()
end

-- Module ------------------------------------------------------------------------------------

DW.RegisterModule({
    id = MODULE_ID,
    titleKey = "QT_TITLE",
    notesKey = "QT_NOTES",
    icon = "Interface\\GossipFrame\\AvailableQuestIcon",

    -- Saved: only off (true when turned off).
    OnLoad = function(self, db)
        settings = db
        if db.off ~= true then
            db.off = nil
        end
    end,

    CreatePanel = function(self, parent)
        return CreatePanel(parent)
    end,
})

-- Debugging.
DW.AddDebug(MODULE_ID, function(add)
    local text = DW.DebugText
    add(("på: %s | kart: %d (rå %d) | sone: %s | hviler: %s | mine quests: %d"):format(
        text(On()), myMap, rawMap, myZoneText ~= "" and myZoneText or "-", text(IsRestingNow()), myQuestCount))
    add(("siste melding: %s byte, %s s siden | planlagt: %s | kjente: %d"):format(
        text(lastLength or 0), lastSentAt and tostring(math.floor(GetTime() - lastSentAt)) or "-", text(plan.pending),
        (function()
            local count = 0
            for _ in pairs(known) do
                count = count + 1
            end
            return count
        end)()))
    local shown = 0
    for key, data in pairs(known) do
        shown = shown + 1
        if shown > 8 then
            break
        end
        add(("  %s %d #%d"):format(key, data.map, data.count))
    end
end)

-- The buttons blink violet (Alerts.lua) when someone in your zone has got a
-- quest in common with you since you last looked. Quiet while you are set to
-- "Do not disturb".
local function NewBuddies(since)
    local list = {}
    if not On() or DW.GetMyStatus() == "C" then
        return list
    end
    for _, entry in ipairs((Collect())) do
        local at = buddySince[entry.key]
        if at and at > since then
            list[#list + 1] = entry
        end
    end
    return list
end

DW.RegisterAlert({
    kind = "quest",
    module = MODULE_ID,
    labelKey = "AL_QUEST",
    color = { 0.65, 0.50, 1.00 }, -- violet
    Check = function(since)
        if not On() or DW.GetMyStatus() == "C" then
            return false
        end
        for _, at in pairs(buddySince) do
            if at > since then
                return true
            end
        end
        return false
    end,
    Items = function(since)
        local items = {}
        for _, entry in ipairs(NewBuddies(since)) do
            local titles = {}
            for index, quest in ipairs(entry.shared) do
                if index > 3 then
                    break
                end
                titles[index] = quest.title
            end
            local text = table.concat(titles, ", ")
            if #entry.shared > 3 then
                text = text .. " +" .. (#entry.shared - 3)
            end
            local icons = DW.RoleIcons(DW.RolesOf and DW.RolesOf(entry.member))
            local who = entry.member.name .. (icons ~= "" and (" " .. icons) or "")
            items[#items + 1] = L.AL_QUEST_ITEM:format(who, text)
        end
        return items
    end,
})
