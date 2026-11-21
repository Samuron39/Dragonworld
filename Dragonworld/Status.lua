-- Dragonworld - status
-- Hver spiller kan vise hva de holder på med: quester, er åpen for dungeons,
-- eller crafter og vil ikke forstyrres. Det velges med knappene øverst til
-- høyre i hovedvinduet, og vises:
--   * som et lite ikon ved navnet i Medlemmer,
--   * i fanen Dungeons, for dem som er åpne for dungeons, med hvilke dungeons
--     de vil ta, hvorfor (quest, loot, xp) og hvilken rolle (tank, healer,
--     dps; høyst to).
--
-- Slik deles det:
--   * Addonen sender statusen din til guilden når du endrer den, og når du
--     logger inn. Da ber den også de andre om deres.
--   * Statusen til andre vises bare mens de er pålogget.
--   * Din egen huskes over /reload, men glemmes om du har vært borte i mer
--     enn 4 timer, så du ikke står som "åpen for dungeons" neste dag.
--
-- Dungeon-listen er hentet fra addonen DungeonJournal (Data\Dungeons.lua,
-- versjon 2.1.2), med nivåene den oppgir. Hver dungeon har et fast nummer som
-- brukes i meldingene; nye får nye numre, gamle numre skal aldri endres.
--
-- Meldinger (navn DragonworldSt, felter skilt med tabulator):
--   S nøkkel status tid dungeons formål roller
--                                          min status ("-" = ingen),
--                                          dungeons som "1,4,12", formål som "QLX",
--                                          roller som "TH" (høyst to av T, H, D).
--                                          Rollefeltet sendes bare når det har
--                                          noe; eldre versjoner leser det ikke.
--   R                                     send meg statusen deres
--
-- All tekst ligger i Locales.lua (navnene som begynner med ST_).

local ADDON_NAME, DW = ...
local L = DW.L

local PREFIX = "DragonworldSt" -- navnet på meldingene; maks 16 tegn
local SEP = "\t"
local FORGET_AFTER = 4 * 3600   -- egen status glemmes etter så lang tid borte
local HELLO_DELAY = 9           -- etter innlogging

-- Statusene, i den rekkefølgen knappene står.
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

-- Hvorfor man vil ta en dungeon. Man kan velge flere.
DW.PURPOSES = {
    { code = "Q", key = "ST_PURPOSE_QUEST" },
    { code = "L", key = "ST_PURPOSE_LOOT" },
    { code = "X", key = "ST_PURPOSE_XP" },
}

-- Hvilken rolle man kan ta i en dungeon. Man velger én, eller to (f.eks. tank
-- og dps). coords er hvor ikonet ligger i spillets rolle-bilde (64x64), samme
-- utsnitt som spillet selv bruker for de små runde rolleikonene.
DW.ROLES = {
    { code = "T", key = "ST_ROLE_TANK", coords = "0:19:22:41" },
    { code = "H", key = "ST_ROLE_HEALER", coords = "20:39:1:20" },
    { code = "D", key = "ST_ROLE_DPS", coords = "20:39:22:41" },
}
DW.MAX_ROLES = 2
local ROLE_TEXTURE = "Interface\\LFGFrame\\UI-LFG-ICON-PORTRAITROLES"

-- Ikonet for en rolle som tekst, så det kan stå i en linje eller et verktøytips.
function DW.RoleIcon(role, size)
    size = size or 14
    return ("|T%s:%d:%d:0:0:64:64:%s|t"):format(ROLE_TEXTURE, size, size, role.coords)
end

-- Dungeons og raids. Nivåene er dem DungeonJournal oppgir (spillets
-- "Looking For Group"-nivåer der den har dem). Raidene er ikke i
-- DungeonJournal ennå; de to her er dem spillets quester viser til.
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

-- Småting -----------------------------------------------------------------------

local function Now()
    local now = GetServerTime and GetServerTime()
    if type(now) == "number" and not DW.IsSecret(now) then
        return now
    end
    return time()
end

-- Nøkkelen en spiller kjennes igjen på: den faste ID-en, ellers navnet.
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

-- Listene som tekst i meldinger, og tilbake.
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

-- Roller som tekst ("TH") og tilbake. Brukes også av Profile.lua.
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

-- Høyst to roller, også om en melding skulle ha flere.
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

-- Rollene med ikon og navn: "[ikon] Tank, [ikon] Healer". Tomt uten roller.
function DW.RoleNames(set, size)
    local parts = {}
    for _, role in ipairs(DW.ROLES) do
        if type(set) == "table" and set[role.code] then
            parts[#parts + 1] = DW.RoleIcon(role, size) .. " " .. L[role.key]
        end
    end
    return table.concat(parts, ", ")
end

-- Bare ikonene: "[ikon] [ikon]". Tomt uten roller.
function DW.RoleIcons(set, size)
    local parts = {}
    for _, role in ipairs(DW.ROLES) do
        if type(set) == "table" and set[role.code] then
            parts[#parts + 1] = DW.RoleIcon(role, size)
        end
    end
    return table.concat(parts, " ")
end

-- Lytting ---------------------------------------------------------------------

local listeners = {}

-- Registrerer en funksjon som kalles når en status (din eller andres) endres.
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

-- Din egen status -----------------------------------------------------------------

-- Lagret per karakter: DragonworldDB.status["Navn-Realm"] =
--   { code, time, dungeons = { [id] = true }, purposes = { [kode] = true },
--     roles = { [kode] = true } }
-- Rollene huskes også når statusen er av, så de er valgt neste gang.
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

-- Statusen din nå: koden ("Q", "D", "C") eller nil, og hele oppføringen.
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

-- Setter statusen din (code = nil slår den av). For "D" kan wish gi hvilke
-- dungeons, formål og roller:
--   { dungeons = { [id] = true }, purposes = { [kode] = true }, roles = { [kode] = true } }.
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

-- Andres status ------------------------------------------------------------------

local others = {} -- [nøkkel] = { code, time, dungeons, purposes, roles }; bare i minnet

-- Statusen til et medlem fra DW.ReadGuildRoster(): koden og oppføringen, eller
-- nil. For deg selv er det din egen.
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

-- Medlemmene som er pålogget og har en bestemt status (deg selv også), med
-- oppføringen: { { member = ..., entry = ... }, ... }.
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

-- Mottak ------------------------------------------------------------------------

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
        -- Noen ber om statusen vår. Svar etter en liten, tilfeldig stund, så
        -- ikke alle svarer samtidig, og bare hvis vi har en.
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

-- Innlogging --------------------------------------------------------------------

local helloSent = false

-- Litt etter innlogging: glem en gammel status, si fra om vår egen, og be om
-- de andres.
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

-- Feilsøking.
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
