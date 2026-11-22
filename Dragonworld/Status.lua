-- Dragonworld - status
-- Each player can show what they are up to: questing, open for dungeons,
-- or crafting and not wanting to be disturbed. It is chosen with the buttons
-- at the top right of the main window, and shown:
--   * as a small icon by the name in the Roster tab,
--   * in the Dungeons tab, for those who are open for dungeons, with which
--     dungeons they want to run, why (quest, loot, xp) and which role (tank,
--     healer, dps; at most two).
--
-- How it is shared:
--   * The addon sends your status to the guild when you change it, and when
--     you log in. It then also asks the others for theirs.
--   * Other players' status is only shown while they are online.
--   * Your own is remembered across /reload, but forgotten if you have been
--     away for more than 4 hours, so you don't show as "open for dungeons"
--     the next day.
--
-- The dungeon list comes from the DungeonJournal addon (Data\Dungeons.lua,
-- version 2.1.2), with the levels it gives. Each dungeon has a fixed number
-- used in the messages; new ones get new numbers, old numbers must never change.
--
-- Messages (name DragonworldSt, fields separated by tab):
--   S key status time dungeons purposes roles
--                                          my status ("-" = none),
--                                          dungeons as "1,4,12", purposes as "QLX",
--                                          roles as "TH" (at most two of T, H, D).
--                                          The roles field is only sent when it
--                                          has something; older versions ignore it.
--   R                                     send me your status
--
-- All text is in Locales.lua (the names starting with ST_).

local ADDON_NAME, DW = ...
local L = DW.L

local PREFIX = "DragonworldSt" -- name of the messages; max 16 characters
local SEP = "\t"
local FORGET_AFTER = 4 * 3600   -- own status is forgotten after this long away
local HELLO_DELAY = 9           -- after login

-- The statuses, in the order the buttons appear.
DW.STATUSES = {
    { code = "Q", key = "ST_QUEST", tip = "ST_QUEST_TIP", icon = "Interface\\GossipFrame\\AvailableQuestIcon" },
    { code = "D", key = "ST_DUNGEON", tip = "ST_DUNGEON_TIP", icon = "Interface\\Icons\\Ability_DualWield" },
    { code = "C", key = "ST_BUSY", tip = "ST_BUSY_TIP", icon = "Interface\\Icons\\Trade_Tailoring" },
}
local STATUS_BY_CODE = {}
for _, status in ipairs(DW.STATUSES) do
    STATUS_BY_CODE[status.code] = status
end
DW.STATUS_BY_CODE = STATUS_BY_CODE

-- Why you want to run a dungeon. You can pick several.
DW.PURPOSES = {
    { code = "Q", key = "ST_PURPOSE_QUEST" },
    { code = "L", key = "ST_PURPOSE_LOOT" },
    { code = "X", key = "ST_PURPOSE_XP" },
}

-- Which role you can take in a dungeon. You pick one, or two (e.g. tank
-- and dps). coords is where the icon sits in the game's role image (64x64),
-- the same crop the game itself uses for the small round role icons.
DW.ROLES = {
    { code = "T", key = "ST_ROLE_TANK", coords = "0:19:22:41" },
    { code = "H", key = "ST_ROLE_HEALER", coords = "20:39:1:20" },
    { code = "D", key = "ST_ROLE_DPS", coords = "20:39:22:41" },
}
DW.MAX_ROLES = 2
local ROLE_TEXTURE = "Interface\\LFGFrame\\UI-LFG-ICON-PORTRAITROLES"

-- The icon for a role as text, so it can go in a line or a tooltip.
function DW.RoleIcon(role, size)
    size = size or 14
    return ("|T%s:%d:%d:0:0:64:64:%s|t"):format(ROLE_TEXTURE, size, size, role.coords)
end

-- Dungeons and raids. The levels are the ones DungeonJournal gives (the game's
-- "Looking For Group" levels where it has them). The raids are not in
-- DungeonJournal yet; the two here are the ones the game's quests refer to.
DW.DUNGEONS = {
    { id = 1, name = "Hall of Thanes", min = 13, max = 20 },
    { id = 2, name = "Ragefire Chasm", min = 13, max = 18 },
    { id = 3, name = "Ruins of Lordaeron", min = 15, max = 22 },
    { id = 4, name = "The Deadmines", min = 17, max = 26 },
    { id = 5, name = "Wailing Caverns", min = 15, max = 24 },
    { id = 6, name = "Shadowfang Keep", min = 20, max = 30 },
    { id = 7, name = "Blackfathom Deeps", min = 24, max = 32 },
    { id = 8, name = "The Stockade", min = 24, max = 32 },
    { id = 9, name = "Excavation Site: Wetlands", min = 26, max = 33 },
    { id = 10, name = "City of Dalaran", min = 28, max = 35 },
    { id = 11, name = "Gnomeregan", min = 29, max = 38 },
    { id = 12, name = "Razorfen Kraul", min = 29, max = 38 },
    { id = 13, name = "Scarlet Monastery: Graveyard", min = 30, max = 38 },
    { id = 14, name = "Scarlet Monastery: Library", min = 33, max = 41 },
    { id = 15, name = "The Drowned City", min = 35, max = 42 },
    { id = 16, name = "Scarlet Monastery: Armory", min = 36, max = 44 },
    { id = 17, name = "Scarlet Monastery: Cathedral", min = 38, max = 46 },
    { id = 18, name = "Razorfen Downs", min = 37, max = 46 },
    { id = 19, name = "Krol'dok Stronghold", min = 40, max = 47 },
    { id = 20, name = "Uldaman", min = 41, max = 51 },
    { id = 21, name = "Zul'Farrak", min = 44, max = 54 },
    { id = 22, name = "Maraudon", min = 46, max = 55 },
    { id = 23, name = "Alcaz Prison", min = 48, max = 55 },
    { id = 24, name = "Sunken Temple", min = 50, max = 60 },
    { id = 25, name = "Blackrock Depths", min = 52, max = 60 },
    { id = 26, name = "Lower Blackrock Spire", min = 55, max = 60 },
    { id = 27, name = "Upper Blackrock Spire", min = 59, max = 60 },
    { id = 28, name = "Dire Maul: East", min = 54, max = 60 },
    { id = 29, name = "Dire Maul: West", min = 56, max = 60 },
    { id = 30, name = "Dire Maul: North", min = 56, max = 60 },
    { id = 31, name = "Blackmaw Hold", min = 55, max = 60 },
    { id = 32, name = "Stratholme: Living", min = 58, max = 60 },
    { id = 33, name = "Stratholme: Undead", min = 58, max = 60 },
    { id = 34, name = "Scholomance", min = 58, max = 60 },
    { id = 35, name = "Shaper's Terrace", min = 58, max = 60 },
    { id = 101, name = "Molten Core", min = 60, max = 60, raid = true },
    { id = 102, name = "Onyxia's Lair", min = 60, max = 60, raid = true },
}
local DUNGEON_BY_ID = {}
for _, dungeon in ipairs(DW.DUNGEONS) do
    DUNGEON_BY_ID[dungeon.id] = dungeon
end
DW.DUNGEON_BY_ID = DUNGEON_BY_ID

-- Small things ------------------------------------------------------------------

local function Now()
    local now = GetServerTime and GetServerTime()
    if type(now) == "number" and not DW.IsSecret(now) then
        return now
    end
    return time()
end

-- The key a player is recognized by: the fixed ID, otherwise the name.
local function KeyOf(guid, name)
    if type(guid) == "string" and guid:find("^Player%-") then
        return guid
    end
    return "name:" .. DW.NameKey(name)
end

local function MyStatusKey()
    local _, name = DW.CharacterKey()
    if not name then
        return nil
    end
    return KeyOf(DW.MyGUID(), name)
end

-- The lists as text in messages, and back.
local function DungeonsText(set)
    local ids = {}
    for id in pairs(set or {}) do
        if DUNGEON_BY_ID[id] then
            ids[#ids + 1] = id
        end
    end
    table.sort(ids)
    return table.concat(ids, ",")
end

local function ParseDungeons(text)
    local set = {}
    for id in (text or ""):gmatch("%d+") do
        id = tonumber(id)
        if DUNGEON_BY_ID[id] then
            set[id] = true
        end
    end
    return set
end

local function PurposesText(set)
    local out = ""
    for _, purpose in ipairs(DW.PURPOSES) do
        if set and set[purpose.code] then
            out = out .. purpose.code
        end
    end
    return out
end

local function ParsePurposes(text)
    local set = {}
    for _, purpose in ipairs(DW.PURPOSES) do
        if (text or ""):find(purpose.code, 1, true) then
            set[purpose.code] = true
        end
    end
    return set
end

-- Roles as text ("TH") and back. Also used by Profile.lua.
local function RolesText(set)
    local out = ""
    for _, role in ipairs(DW.ROLES) do
        if type(set) == "table" and set[role.code] then
            out = out .. role.code
        end
    end
    return out
end
DW.RolesToText = RolesText

-- At most two roles, even if a message has more.
local function ParseRoles(text)
    local set, count = {}, 0
    for _, role in ipairs(DW.ROLES) do
        if count < DW.MAX_ROLES and tostring(text or ""):find(role.code, 1, true) then
            set[role.code] = true
            count = count + 1
        end
    end
    return set
end
DW.RolesFromText = ParseRoles

-- The roles with icon and name: "[icon] Tank, [icon] Healer". Empty with no roles.
function DW.RoleNames(set, size)
    local parts = {}
    for _, role in ipairs(DW.ROLES) do
        if type(set) == "table" and set[role.code] then
            parts[#parts + 1] = DW.RoleIcon(role, size) .. " " .. L[role.key]
        end
    end
    return table.concat(parts, ", ")
end

-- Only the icons: "[icon] [icon]". Empty with no roles.
function DW.RoleIcons(set, size)
    local parts = {}
    for _, role in ipairs(DW.ROLES) do
        if type(set) == "table" and set[role.code] then
            parts[#parts + 1] = DW.RoleIcon(role, size)
        end
    end
    return table.concat(parts, " ")
end

-- Listening -------------------------------------------------------------------

local listeners = {}

-- Registers a function that is called when a status (yours or someone else's) changes.
function DW.OnStatusChanged(callback)
    listeners[#listeners + 1] = callback
end

local function Changed()
    for _, callback in ipairs(listeners) do
        local ok, problem = pcall(callback)
        if not ok then
            DW.PrintError(L.ERROR, problem)
        end
    end
end

-- Your own status ----------------------------------------------------------------

-- Saved per character: DragonworldDB.status["Name-Realm"] =
--   { code, time, dungeons = { [id] = true }, purposes = { [code] = true },
--     roles = { [code] = true } }
-- The roles are also remembered when the status is off, so they are already chosen next time.
local function MyEntry()
    if type(DragonworldDB) ~= "table" then
        return nil
    end
    if type(DragonworldDB.status) ~= "table" then
        DragonworldDB.status = {}
    end
    local key = DW.CharacterKey()
    if not key then
        return nil
    end
    local entry = DragonworldDB.status[key]
    if type(entry) ~= "table" then
        entry = {}
        DragonworldDB.status[key] = entry
    end
    if type(entry.dungeons) ~= "table" then
        entry.dungeons = {}
    end
    if type(entry.purposes) ~= "table" then
        entry.purposes = {}
    end
    if type(entry.roles) ~= "table" then
        entry.roles = {}
    end
    if not STATUS_BY_CODE[entry.code or ""] then
        entry.code = nil
    end
    return entry
end

-- Your status now: the code ("Q", "D", "C") or nil, and the whole entry.
function DW.GetMyStatus()
    local entry = MyEntry()
    return entry and entry.code, entry
end

local Send = DW.CreateSender(PREFIX)

local function SendMine()
    local key = MyStatusKey()
    local entry = MyEntry()
    if not key or not entry then
        return
    end
    local fields = {
        "S", key, entry.code or "-", ("%d"):format(entry.time or Now()),
        entry.code == "D" and DungeonsText(entry.dungeons) or "",
        entry.code == "D" and PurposesText(entry.purposes) or "",
    }
    local roles = entry.code == "D" and RolesText(entry.roles) or ""
    if roles ~= "" then
        fields[#fields + 1] = roles
    end
    Send(table.concat(fields, SEP))
end

-- Sets your status (code = nil turns it off). For "D", wish can give which
-- dungeons, purposes and roles:
--   { dungeons = { [id] = true }, purposes = { [code] = true }, roles = { [code] = true } }.
function DW.SetMyStatus(code, wish)
    local entry = MyEntry()
    if not entry then
        return
    end
    if code ~= nil and not STATUS_BY_CODE[code] then
        return
    end
    entry.code = code
    entry.time = math.max(Now(), (entry.time or 0) + 1)
    if wish then
        entry.dungeons = ParseDungeons(DungeonsText(wish.dungeons))
        entry.purposes = ParsePurposes(PurposesText(wish.purposes))
        if wish.roles then
            entry.roles = ParseRoles(RolesText(wish.roles))
        end
    end
    SendMine()
    Changed()
end

-- Others' status -----------------------------------------------------------------

local others = {} -- [key] = { code, time, dungeons, purposes, roles }; in memory only

-- The status of a member from DW.ReadGuildRoster(): the code and the entry, or
-- nil. For yourself it is your own.
function DW.StatusOf(member)
    if type(member) ~= "table" then
        return nil
    end
    local myGUID = DW.MyGUID()
    local _, myName = DW.CharacterKey()
    if (myGUID and member.guid == myGUID) or (not member.guid and myName and DW.NameKey(member.key) == DW.NameKey(myName)) then
        local code, entry = DW.GetMyStatus()
        return code, entry
    end
    local entry = others[KeyOf(member.guid, member.key)]
    if entry and entry.code then
        return entry.code, entry
    end
    return nil
end

-- The members who are online and have a given status (you too), with
-- the entry: { { member = ..., entry = ... }, ... }.
function DW.MembersWithStatus(code)
    local list = {}
    for _, member in ipairs(DW.ReadGuildRoster()) do
        if member.online then
            local found, entry = DW.StatusOf(member)
            if found == code then
                list[#list + 1] = { member = member, entry = entry }
            end
        end
    end
    return list
end

-- Receiving ---------------------------------------------------------------------

local replyScheduled = false

DW.OnGuildMessage(PREFIX, function(text)
    local fields = {}
    for field in (text .. SEP):gmatch("(.-)" .. SEP) do
        fields[#fields + 1] = field
    end
    if fields[1] == "S" then
        local key, code, when = fields[2], fields[3], tonumber(fields[4])
        if type(key) ~= "string" or key == "" or #key > 60 or not when or when > Now() + 86400 then
            return
        end
        if code ~= "-" and not STATUS_BY_CODE[code or ""] then
            return
        end
        local known = others[key]
        if known and known.time >= when then
            return
        end
        others[key] = {
            code = (code ~= "-") and code or nil,
            time = when,
            dungeons = ParseDungeons(fields[5]),
            purposes = ParsePurposes(fields[6]),
            roles = ParseRoles(fields[7]),
        }
        Changed()
    elseif fields[1] == "R" then
        -- Someone asks for our status. Reply after a short, random delay so
        -- not everyone replies at once, and only if we have one.
        if replyScheduled or not DW.GetMyStatus() then
            return
        end
        replyScheduled = true
        C_Timer.After(1 + math.random() * 5, function()
            replyScheduled = false
            if DW.IsMember() and DW.GetMyStatus() then
                SendMine()
            end
        end)
    end
end)

-- Login -------------------------------------------------------------------------

local helloSent = false

-- A little after login: forget an old status, announce our own, and ask for
-- the others'.
local function PlanHello()
    if helloSent or not (C_Timer and C_Timer.After) then
        return
    end
    C_Timer.After(HELLO_DELAY, function()
        if helloSent or not DW.IsMember() then
            return
        end
        helloSent = true
        local code, entry = DW.GetMyStatus()
        if code and Now() - (entry.time or 0) > FORGET_AFTER then
            entry.code = nil
            entry.time = Now()
            Changed()
        end
        SendMine()
        Send("R")
    end)
end

local frame = CreateFrame("Frame")
frame:SetScript("OnEvent", function()
    if DW.IsMember() then
        PlanHello()
    end
end)
pcall(frame.RegisterEvent, frame, "PLAYER_ENTERING_WORLD")

DW.OnMembershipChanged(function(member)
    if member then
        PlanHello()
    end
end)

-- Debugging.
DW.AddDebug("status", function(add)
    local code, entry = DW.GetMyStatus()
    add("min status: " .. DW.DebugText(code) .. " | nøkkel: " .. DW.DebugText(MyStatusKey())
        .. " | dungeons: " .. (entry and DungeonsText(entry.dungeons) or "") .. " | formål: " .. (entry and PurposesText(entry.purposes) or "")
        .. " | roller: " .. (entry and RolesText(entry.roles) or ""))
    local count = 0
    for key, known in pairs(others) do
        if known.code then
            count = count + 1
            if count <= 10 then
                add(("  %s: %s %s %s"):format(key, known.code, DungeonsText(known.dungeons), RolesText(known.roles)))
            end
        end
    end
    add("andre med status: " .. count)
end)
