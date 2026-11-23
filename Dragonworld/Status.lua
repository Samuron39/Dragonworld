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
--   * "Open for dungeons" lasts one hour at a time (DUNGEON_LIFETIME): your
--     own turns itself off after an hour ("Keep me listed" in the Dungeons
--     tab starts the hour again, DW.TouchMyStatus), and when you go into a
--     dungeon or raid. Other members' "D" statuses older than an hour are
--     treated as gone everywhere (DW.StatusOf).
--   * DW.OnDungeonEntered(callback) tells other files when you go into a
--     dungeon or raid (Dungeons.lua closes your group post then).
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
local DUNGEON_LIFETIME = 3600   -- "open for dungeons" lasts this long at a time
local EXPIRY_CHECK = 30         -- seconds between checks while your own status is "D"
DW.DUNGEON_STATUS_LIFETIME = DUNGEON_LIFETIME

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
-- size is the group size a "Lead a group" post starts with: 5 for a dungeon
-- and 40 for a raid when it is left out. Use one of the sizes the form
-- offers (5, 10, 20, 25 or 40), e.g. size = 20 for a 20-man raid.
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
    { id = 101, name = "Molten Core", min = 60, max = 60, raid = true, size = 40 },
    { id = 102, name = "Onyxia's Lair", min = 60, max = 60, raid = true, size = 40 },
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
    if code == "D" then
        DW.PlanStatusExpiry()
    end
end

-- "Open for dungeons" for one hour at a time -----------------------------------------

local expiryScheduled = false

-- Seconds left of your own "open for dungeons" hour, or nil when it is not on.
function DW.MyStatusTimeLeft()
    local code, entry = DW.GetMyStatus()
    if code ~= "D" or not entry then
        return nil
    end
    return math.max(0, DUNGEON_LIFETIME - (Now() - (entry.time or 0)))
end

local function CheckExpiry()
    expiryScheduled = false
    local code, entry = DW.GetMyStatus()
    if code ~= "D" or not entry then
        return
    end
    if Now() - (entry.time or 0) > DUNGEON_LIFETIME then
        DW.SetMyStatus(nil)
        DW.Print(L.ST_EXPIRED)
        return
    end
    DW.PlanStatusExpiry()
end

-- Looks at your own status every 30 s while it is "D" (one timer at a time).
function DW.PlanStatusExpiry()
    if expiryScheduled or not (C_Timer and C_Timer.After) or DW.GetMyStatus() ~= "D" then
        return
    end
    expiryScheduled = true
    C_Timer.After(EXPIRY_CHECK, CheckExpiry)
end

-- "Keep me listed": starts the hour again. Returns true when your status is "D".
function DW.TouchMyStatus()
    local code, entry = DW.GetMyStatus()
    if code ~= "D" or not entry then
        return false
    end
    entry.time = math.max(Now(), (entry.time or 0) + 1)
    SendMine()
    Changed()
    DW.PlanStatusExpiry()
    return true
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
    local myName = DW.CharacterKey()
    if (myGUID and member.guid == myGUID) or (not member.guid and myName and DW.SameCharacter(member.key, myName)) then
        local code, entry = DW.GetMyStatus()
        return code, entry
    end
    local entry = others[KeyOf(member.guid, member.key)]
    if entry and entry.code then
        -- "Open for dungeons" lasts an hour; an older one is stale (the
        -- member's addon may be older and never turn it off).
        if entry.code == "D" and Now() - (entry.time or 0) > DUNGEON_LIFETIME then
            return nil
        end
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

-- Group, instance and invites ------------------------------------------------------

-- Every call below is guarded (the function may be missing, or fail), and
-- every value the game returns is checked with DW.IsSecret before it is
-- compared or used in a condition.

-- Calls fn(...) if it is a function; returns its results, or nothing if it
-- is missing or failed.
local function Pack(...)
    return select("#", ...), { ... }
end

local function SafeCall(fn, ...)
    if type(fn) ~= "function" then
        return nil
    end
    local count, result = Pack(pcall(fn, ...))
    if not result[1] then
        return nil
    end
    return (table.unpack or unpack)(result, 2, count)
end

local function PlainTrue(value)
    return not DW.IsSecret(value) and value == true
end

local function PlainBool(value)
    return not DW.IsSecret(value) and type(value) == "boolean"
end

local function PlainString(value)
    if type(value) == "string" and not DW.IsSecret(value) then
        return value
    end
    return nil
end

local function PlainCount(value)
    if type(value) == "number" and not DW.IsSecret(value) then
        return value
    end
    return 0
end

-- The unit tokens of the OTHER members of your group (not you). Empty when solo.
function DW.GroupUnits()
    local units = {}
    if not PlainTrue(SafeCall(IsInGroup)) then
        return units
    end
    local count = PlainCount(SafeCall(GetNumGroupMembers))
    if PlainTrue(SafeCall(IsInRaid)) then
        for index = 1, count do
            local unit = "raid" .. index
            local ok, isMe = pcall(UnitIsUnit, unit, "player")
            -- A unit we cannot tell apart from ourselves is left out.
            if ok and not DW.IsSecret(isMe) and isMe ~= true then
                units[#units + 1] = unit
            end
        end
    else
        for index = 1, count - 1 do
            units[#units + 1] = "party" .. index
        end
    end
    return units
end

-- A set of keys for the other group members: [guid] = true, and
-- ["name:" .. DW.NameKey(name)] = true. Forever's UnitName gives first and
-- last name as name and realm, so both the first name and the full name are in it.
function DW.GroupMemberKeys()
    local set = {}
    for _, unit in ipairs(DW.GroupUnits()) do
        local guid = PlainString(SafeCall(UnitGUID, unit))
        if guid and guid ~= "" then
            set[guid] = true
        end
        local name, realm = SafeCall(UnitName, unit)
        name, realm = PlainString(name), PlainString(realm)
        if name and name ~= "" then
            set["name:" .. DW.NameKey(name)] = true
            if realm and realm ~= "" then
                set["name:" .. DW.NameKey(name .. realm)] = true
            end
        end
    end
    return set
end

-- True if the member (a row from DW.ReadGuildRoster) is in your group.
function DW.InMyGroup(member)
    if type(member) ~= "table" then
        return false
    end
    if member.guid and C_PartyInfo and PlainTrue(SafeCall(C_PartyInfo.IsGUIDInGroup, member.guid)) then
        return true
    end
    local set = DW.GroupMemberKeys()
    if member.guid and set[member.guid] then
        return true
    end
    local key = DW.NameKey(member.key or member.name)
    return key ~= "" and set["name:" .. key] == true
end

-- The number of people in your group, yourself included (1 when solo).
function DW.GroupSize()
    return math.max(1, PlainCount(SafeCall(GetNumGroupMembers)))
end

-- True if you may invite someone to your group now.
function DW.CanInviteToGroup()
    if C_PartyInfo and type(C_PartyInfo.CanInvite) == "function" then
        local can = SafeCall(C_PartyInfo.CanInvite)
        if PlainBool(can) then
            return can
        end
    end
    if not PlainTrue(SafeCall(IsInGroup)) then
        return true
    end
    if PlainTrue(SafeCall(UnitIsGroupLeader, "player")) then
        return true
    end
    return PlainTrue(SafeCall(IsInRaid)) and PlainTrue(SafeCall(UnitIsGroupAssistant, "player"))
end

-- Invites a player to your group. Returns true when the invite was ATTEMPTED;
-- that does not mean it went out (a refusal arrives later as a system
-- message). InviteUnit is not click-only (no HasRestrictions), but the game
-- may ask for confirmation when the party would turn into a raid.
function DW.InviteToGroup(name)
    if type(name) ~= "string" or name == "" then
        return false
    end
    local invite = (C_PartyInfo and C_PartyInfo.InviteUnit) or InviteUnit
    if type(invite) ~= "function" then
        return false
    end
    return (pcall(invite, name))
end

-- True if you may turn your party into a raid.
function DW.CanConvertToRaid()
    if C_PartyInfo and type(C_PartyInfo.AllowedToDoPartyConversion) == "function" then
        local allowed = SafeCall(C_PartyInfo.AllowedToDoPartyConversion, true)
        if PlainBool(allowed) then
            return allowed
        end
        return false
    end
    return PlainTrue(SafeCall(UnitIsGroupLeader, "player"))
end

-- Turns the party into a raid. Returns true when ATTEMPTED. The call has
-- HasRestrictions: when blocked, the game shows "Interface action failed
-- because of an AddOn" without a Lua error, so callers must check IsInRaid()
-- after the next GROUP_ROSTER_UPDATE. Only ever call it from a click.
function DW.ConvertToRaid()
    local convert = (C_PartyInfo and C_PartyInfo.ConvertToRaid) or ConvertToRaid
    if type(convert) ~= "function" then
        return false
    end
    return (pcall(convert))
end

-- Where you are: inside (bool), instance type ("none" if unknown), the
-- instance name (or "") and its map ID (or 0).
function DW.InstanceInfo()
    local inside, itype = SafeCall(IsInInstance)
    inside = PlainTrue(inside)
    itype = PlainString(itype) or "none"
    local info = { SafeCall(GetInstanceInfo) }
    local name = PlainString(info[1]) or ""
    if itype == "none" and PlainString(info[2]) then
        itype = info[2]
    end
    local mapID = info[8]
    if type(mapID) ~= "number" or DW.IsSecret(mapID) then
        mapID = 0
    end
    return inside, itype, name, mapID
end

-- True inside a dungeon or a raid.
function DW.InDungeonInstance()
    local inside, itype = DW.InstanceInfo()
    return inside and (itype == "party" or itype == "raid")
end

-- Receiving ---------------------------------------------------------------------

local replyScheduled = false

-- May sender (given by the server) set the status under key? Only for
-- themselves: the roster member with that GUID (or name) must be the sender.
-- While the roster is not read yet, nothing can be checked and it is taken.
local function SenderOwnsKey(key, sender)
    if type(sender) ~= "string" or DW.IsSecret(sender) or sender == "" then
        return false
    end
    local name = key:match("^name:(.+)$")
    if name then
        return name == DW.NameKey(sender) or name == DW.IdentityKey(sender)
    end
    local roster = DW.ReadGuildRoster()
    if #roster == 0 then
        return true
    end
    for _, member in ipairs(roster) do
        if member.guid == key then
            return DW.SameCharacter(member.key, sender)
        end
    end
    return false
end

DW.OnGuildMessage(PREFIX, function(text, sender)
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
        if not SenderOwnsKey(key, sender) then
            return
        end
        local known = others[key]
        if known and known.time >= when then
            return
        end
        local entry = {
            code = (code ~= "-") and code or nil,
            time = when,
            dungeons = ParseDungeons(fields[5]),
            purposes = ParsePurposes(fields[6]),
            roles = ParseRoles(fields[7]),
        }
        -- since: when this "open for dungeons" began. "Keep me listed" only
        -- renews the hour of an unchanged one, which is not news (no alert).
        entry.since = when
        if known and entry.code == "D" and known.code == "D" and when - known.time <= DUNGEON_LIFETIME
            and DungeonsText(entry.dungeons) == DungeonsText(known.dungeons)
            and PurposesText(entry.purposes) == PurposesText(known.purposes)
            and RolesText(entry.roles) == RolesText(known.roles) then
            entry.since = known.since or known.time
        end
        others[key] = entry
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
        elseif code == "D" and Now() - (entry.time or 0) > DUNGEON_LIFETIME then
            -- "Open for dungeons" from more than an hour ago: off, quietly.
            entry.code = nil
            entry.time = Now()
            Changed()
        end
        SendMine()
        Send("R")
        DW.PlanStatusExpiry()
    end)
end

-- Going into a dungeon or raid ----------------------------------------------------

local enteredListeners = {}

-- Registers a function that is called when you go into a dungeon or a raid.
function DW.OnDungeonEntered(callback)
    enteredListeners[#enteredListeners + 1] = callback
end

-- nil until the first look after login (then it is only recorded), then
-- whether you were inside a dungeon or raid the last time we looked.
local lastInInstance

-- (A login or /reload sets lastInInstance back to nil first: see the frame below.)
local function CheckInstance()
    local inside = DW.InDungeonInstance() and true or false
    local was = lastInInstance
    lastInInstance = inside
    if was ~= false or not inside then
        return
    end
    if DW.GetMyStatus() == "D" then
        DW.SetMyStatus(nil)
        DW.Print(L.ST_EXPIRED_INSTANCE)
    end
    for _, callback in ipairs(enteredListeners) do
        local ok, problem = pcall(callback)
        if not ok then
            DW.PrintError(L.ERROR, problem)
        end
    end
end

local frame = CreateFrame("Frame")
frame:SetScript("OnEvent", function(self, event, ...)
    local isInitialLogin, isReloadingUi = ...
    if event == "PLAYER_ENTERING_WORLD" and (isInitialLogin == true or isReloadingUi == true) then
        -- A login or /reload: what we knew is gone, also before we know the guild.
        lastInInstance = nil
    end
    if DW.IsMember() then
        if event == "PLAYER_ENTERING_WORLD" then
            PlanHello()
        end
        CheckInstance()
    end
end)
pcall(frame.RegisterEvent, frame, "PLAYER_ENTERING_WORLD")
pcall(frame.RegisterEvent, frame, "ZONE_CHANGED_NEW_AREA")

DW.OnMembershipChanged(function(member)
    if member then
        PlanHello()
        -- The guild name can come after the login's PLAYER_ENTERING_WORLD:
        -- record where we are now, so walking into a dungeon later counts.
        if lastInInstance == nil then
            lastInInstance = DW.InDungeonInstance() and true or false
        end
    end
end)

-- Debugging.
DW.AddDebug("status", function(add)
    local code, entry = DW.GetMyStatus()
    add("min status: " .. DW.DebugText(code) .. " | nøkkel: " .. DW.DebugText(MyStatusKey())
        .. " | dungeons: " .. (entry and DungeonsText(entry.dungeons) or "") .. " | formål: " .. (entry and PurposesText(entry.purposes) or "")
        .. " | roller: " .. (entry and RolesText(entry.roles) or "")
        .. " | dungeon-tid igjen: " .. DW.DebugText(DW.MyStatusTimeLeft()))
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
