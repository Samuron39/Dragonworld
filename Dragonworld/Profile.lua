-- Dragonworld - profil
-- Det addonen deler om hver karakter, så det kan vises på medlemskortet
-- (MemberCard.lua) og i Medlemmer:
--   * legacy-poeng
--   * utstyret karakteren har på seg
--   * talentene
--   * "om meg": en kort tekst spilleren skriver om seg selv, som andre ser
-- Hver addon sender bare sitt eget: når du logger inn, og når noe endres.
-- Den ber også de andre om deres. Alle tar vare på det de får (det lagres),
-- så et medlem som er avlogget vises slik det var sist dere var pålogget
-- samtidig.
--
-- Legacy-poeng: spillet har ingen dokumentert funksjon for dem, men to
-- addons andre har laget (AltStable sin Legacy-plugin og LegacyNavigator,
-- lest 21.11.2026) leser dem likt: poengene er "renown"-nivået til
-- faction 2802 (Legacy Track), og maksimum (65) er
-- C_Traits.GetMaxAvailableTraitCurrency(4225, false). Det er det vi bruker.
-- Achievement-poengene (GetTotalAchievementPoints) var feil spor: de var 0
-- hos en som hadde 2 legacy-poeng. Mangler renown-funksjonen, leter addonen
-- etter en valuta eller en C_...Legacy...-funksjon (se FindLegacy... under).
-- "/dw debug" viser hvor tallet kom fra.
--
-- Versjon 0.12.0 og 0.13.0 sendte et feil tall som melding "L". Den
-- meldingen og det som ble lagret fra den, brukes ikke lenger; legacy-poeng
-- sendes nå som "P".
--
-- Talenter: Forever har ikke de gamle talentfunksjonene (GetTalentInfo osv.).
-- Talentvinduet er spillets talenttre (C_Traits): ett tre per klasse, med de
-- tre talenttrærne som grupper. DungeonJournal leser dem på samme måte.
--
-- Meldinger (navn DragonworldPf, felter skilt med tabulator):
--   P nøkkel tid poeng maks           legacy-poeng ("2", "65"; maks kan mangle)
--   E nøkkel tid nr/antall tekst      utstyr: "1=12345:0:0,5=..." (plass=gjenstand)
--   T nøkkel tid nr/antall tekst      talenter: "Navn~poeng~spell-rang,...;..."
--   A nøkkel tid nr/antall tekst      "om meg"-teksten (tom tekst = slettet)
--   R                                 send meg deres
-- Lange tekster deles i biter og settes sammen igjen hos mottakeren.

local ADDON_NAME, DW = ...
local L = DW.L

local PREFIX = "DragonworldPf" -- navnet på meldingene; maks 16 tegn
local SEP = "\t"
local CHUNK_BYTES = 200
local MAX_PARTS = 8
local HELLO_DELAY = 11         -- etter innlogging
local CHANGE_DELAY = 20        -- samle opp endringer før vi sender
local GEAR_SLOTS = 19

-- Småting -----------------------------------------------------------------------

local function Now()
    local now = GetServerTime and GetServerTime()
    if type(now) == "number" and not DW.IsSecret(now) then
        return now
    end
    return time()
end

local function Num(value)
    if type(value) == "number" and not DW.IsSecret(value) then
        return value
    end
    return nil
end

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

local function MemberKey(member)
    return KeyOf(member.guid, member.key)
end

-- Lagret: DragonworldDB.profiles[nøkkel] = {
--   legacy  = { points, time },
--   gear    = { time, items = { [plass] = "12345:0:0..." } },
--   talents = { time, trees = { { name, points, talents = { { spell, rank }, ... } }, ... } },
-- }
local function Profiles()
    if type(DragonworldDB) ~= "table" then
        return {}
    end
    if type(DragonworldDB.profiles) ~= "table" then
        DragonworldDB.profiles = {}
    end
    -- Legacy-poeng lagret av 0.12.0/0.13.0 var feil tall (se øverst). Fjernes.
    if not DragonworldDB.profilesCleaned then
        DragonworldDB.profilesCleaned = 1
        for _, profile in pairs(DragonworldDB.profiles) do
            if type(profile) == "table" then
                profile.legacy = nil
            end
        end
    end
    return DragonworldDB.profiles
end

local function ProfileFor(key, create)
    local profiles = Profiles()
    local profile = profiles[key]
    if type(profile) ~= "table" and create then
        profile = {}
        profiles[key] = profile
    end
    return type(profile) == "table" and profile or nil
end

local listeners = {}

-- Registrerer en funksjon som kalles når noe nytt om et medlem er kommet.
function DW.OnProfileChanged(callback)
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

-- Lesing av egen karakter ---------------------------------------------------------

-- Legacy-poeng. Se forklaringen øverst. legacySource sier hvor tallet kom fra
-- (for /dw debug); legacyReader er funksjonen vi fant, så vi bare leter én gang.
local legacySource, legacyReader, legacySearched

local function PlausiblePoints(value)
    value = Num(value)
    if value and value >= 0 and value < 100000 and value == math.floor(value) then
        return value
    end
    return nil
end

local function FindLegacyCurrency()
    local C = C_CurrencyInfo
    if type(C) ~= "table" or type(C.GetCurrencyListSize) ~= "function" or type(C.GetCurrencyListInfo) ~= "function" then
        return nil
    end
    local ok, size = pcall(C.GetCurrencyListSize)
    for index = 1, (ok and Num(size)) or 0 do
        local fine, info = pcall(C.GetCurrencyListInfo, index)
        if fine and type(info) == "table" and not info.isHeader and type(info.name) == "string" and not DW.IsSecret(info.name)
            and info.name:find("Legacy") and PlausiblePoints(info.quantity) then
            local name = info.name
            return function()
                local again, current = pcall(C.GetCurrencyListInfo, index)
                if again and type(current) == "table" and current.name == name then
                    return PlausiblePoints(current.quantity)
                end
                return nil
            end, "valuta " .. name
        end
    end
    return nil
end

-- Hvor godt et funksjonsnavn ser ut som "alle poengene du har tjent".
local function Score(field)
    if not field:find("^Get") or not field:find("Point") then
        return 0
    end
    if field:find("Spent") or field:find("Unspent") or field:find("Available") or field:find("Max") or field:find("Cap")
        or field:find("Cost") or field:find("Required") then
        return 0
    end
    if field:find("Total") or field:find("Earned") then
        return 2
    end
    return 1
end

local function FindLegacyFunction()
    local best, bestScore, bestSource
    for name, value in pairs(_G) do
        if type(name) == "string" and name:find("^C_") and name:find("Legacy") and type(value) == "table" then
            for field, fn in pairs(value) do
                if type(field) == "string" and type(fn) == "function" then
                    local score = Score(field)
                    if score > (bestScore or 0) then
                        local ok, result = pcall(fn)
                        if ok and PlausiblePoints(result) then
                            best, bestScore, bestSource = fn, score, name .. "." .. field .. "()"
                        end
                    end
                end
            end
        end
    end
    if best then
        return function()
            local ok, result = pcall(best)
            return ok and PlausiblePoints(result) or nil
        end, bestSource
    end
    return nil
end

local LEGACY_FACTION = 2802        -- Legacy Track; renown-nivået er poengene
local LEGACY_TRAIT_CURRENCY = 4225 -- poengene som talent-valuta, for maksimum

local function ReadRenown()
    local M = C_MajorFactions
    if type(M) ~= "table" or type(M.GetCurrentRenownLevel) ~= "function" then
        return nil
    end
    local ok, level = pcall(M.GetCurrentRenownLevel, LEGACY_FACTION)
    return ok and PlausiblePoints(level) or nil
end

-- Hvor mange legacy-poeng som finnes i alt (65 da Forever kom ut), eller nil.
local function ReadLegacyMax()
    if C_Traits and type(C_Traits.GetMaxAvailableTraitCurrency) == "function" then
        local ok, max = pcall(C_Traits.GetMaxAvailableTraitCurrency, LEGACY_TRAIT_CURRENCY, false)
        max = ok and PlausiblePoints(max)
        if max and max > 0 then
            return max
        end
    end
    return nil
end

local function ReadLegacy()
    local renown = ReadRenown()
    if renown then
        legacySource = "C_MajorFactions.GetCurrentRenownLevel(" .. LEGACY_FACTION .. ")"
        return renown
    end
    -- Uten den: let selv. Fant vi ingenting, prøver vi igjen etter et minutt,
    -- for spillet kan ha lastet det sent etter innlogging.
    if not legacyReader and (not legacySearched or GetTime() - legacySearched > 60) then
        legacySearched = GetTime()
        legacyReader, legacySource = FindLegacyCurrency()
        if not legacyReader then
            legacyReader, legacySource = FindLegacyFunction()
        end
    end
    return legacyReader and legacyReader() or nil
end

-- Utstyret som tekst: "1=12345:0:0,5=6789". Gjenstanden er spillets
-- gjenstandskode (det som står etter "item:" i en lenke), uten tomme felt bakerst.
local function ReadGear()
    if type(GetInventoryItemLink) ~= "function" then
        return nil
    end
    local parts = {}
    for slot = 1, GEAR_SLOTS do
        local ok, link = pcall(GetInventoryItemLink, "player", slot)
        if ok and type(link) == "string" and not DW.IsSecret(link) then
            local code = link:match("|Hitem:([%d:%-]+)|h") or link:match("^item:([%d:%-]+)$")
            if code then
                code = code:gsub(":+$", "")
                if code ~= "" and #code <= 150 then
                    parts[#parts + 1] = slot .. "=" .. code
                end
            end
        end
    end
    return table.concat(parts, ",")
end

local function ParseGear(text)
    local items = {}
    for slot, code in (text or ""):gmatch("(%d+)=([%d:%-]+)") do
        slot = tonumber(slot)
        if slot and slot >= 1 and slot <= GEAR_SLOTS then
            items[slot] = code
        end
    end
    return items
end

-- Talentene fra talenttreet: én gruppe per talenttre, med navn, poeng og
-- talentene som har poeng (spell og rang), sortert ovenfra og ned.
local function ReadTalentTrees()
    local T = C_Traits
    if type(T) ~= "table" or type(T.GetConfigInfo) ~= "function" or type(T.GetTreeNodes) ~= "function"
        or type(T.GetNodeInfo) ~= "function" or type(T.GetGroupDisplayInfoByTreeID) ~= "function" then
        return nil
    end
    local configID
    if C_ClassTalents and type(C_ClassTalents.GetActiveConfigID) == "function" then
        local ok, id = pcall(C_ClassTalents.GetActiveConfigID)
        configID = ok and Num(id)
    end
    local S = C_SpecializationInfo
    if not configID and type(S) == "table" and type(S.GetActiveSpecGroup) == "function" and type(S.GetCombatConfigIDForSpecGroup) == "function" then
        local ok, group = pcall(S.GetActiveSpecGroup)
        if ok and Num(group) then
            local fine, id = pcall(S.GetCombatConfigIDForSpecGroup, group)
            configID = fine and Num(id)
        end
    end
    if not configID then
        return nil
    end
    local okC, config = pcall(T.GetConfigInfo, configID)
    local treeID = okC and type(config) == "table" and type(config.treeIDs) == "table" and Num(config.treeIDs[1])
    if not treeID then
        return nil
    end
    local okD, displays = pcall(T.GetGroupDisplayInfoByTreeID, treeID)
    if not okD or type(displays) ~= "table" then
        return nil
    end
    local groups, index = {}, {}
    for _, display in ipairs(displays) do
        if type(display) == "table" and Num(display.groupID) then
            local name = type(display.displayName) == "string" and not DW.IsSecret(display.displayName) and display.displayName or "?"
            groups[#groups + 1] = { id = display.groupID, order = Num(display.orderIndex) or #groups, name = name, points = 0, talents = {} }
        end
    end
    if #groups == 0 then
        return nil
    end
    table.sort(groups, function(a, b) return a.order < b.order end)
    for i, group in ipairs(groups) do
        index[group.id] = i
    end

    local function SpellOf(info)
        if type(T.GetEntryInfo) ~= "function" or type(T.GetDefinitionInfo) ~= "function" then
            return nil
        end
        local entryID = type(info.activeEntry) == "table" and Num(info.activeEntry.entryID)
            or type(info.entryIDs) == "table" and Num(info.entryIDs[1])
        if not entryID then
            return nil
        end
        local okE, entry = pcall(T.GetEntryInfo, configID, entryID)
        local definitionID = okE and type(entry) == "table" and Num(entry.definitionID)
        if not definitionID then
            return nil
        end
        local okF, definition = pcall(T.GetDefinitionInfo, definitionID)
        if not okF or type(definition) ~= "table" then
            return nil
        end
        return Num(definition.spellID) or Num(definition.overriddenSpellID)
    end

    local okN, nodeIDs = pcall(T.GetTreeNodes, treeID)
    if not okN or type(nodeIDs) ~= "table" then
        return nil
    end
    for _, nodeID in ipairs(nodeIDs) do
        local okI, info = pcall(T.GetNodeInfo, configID, nodeID)
        if okI and type(info) == "table" and info.isVisible ~= false then
            local rank = Num(info.ranksPurchased) or 0
            if rank <= 0 then
                rank = Num(info.activeRank) or 0
            end
            local group
            for _, groupID in ipairs(type(info.groupIDs) == "table" and info.groupIDs or {}) do
                group = group or (index[groupID] and groups[index[groupID]])
            end
            local spell = rank > 0 and group and SpellOf(info)
            if spell then
                group.talents[#group.talents + 1] = { spell = spell, rank = rank, y = Num(info.posY) or 0, x = Num(info.posX) or 0 }
                group.points = group.points + rank
            end
        end
    end
    local trees = {}
    for _, group in ipairs(groups) do
        table.sort(group.talents, function(a, b)
            if a.y ~= b.y then
                return a.y < b.y
            end
            return a.x < b.x
        end)
        local talents = {}
        for i, talent in ipairs(group.talents) do
            talents[i] = { spell = talent.spell, rank = talent.rank }
        end
        trees[#trees + 1] = { name = group.name, points = group.points, talents = talents }
    end
    return trees
end

local function CleanName(text)
    text = tostring(text):gsub("[%c|~;,]", " ")
    return text:sub(1, 40)
end

local function TalentsText(trees)
    if not trees then
        return nil
    end
    local parts = {}
    for _, tree in ipairs(trees) do
        local talents = {}
        for _, talent in ipairs(tree.talents) do
            talents[#talents + 1] = talent.spell .. "-" .. talent.rank
        end
        parts[#parts + 1] = CleanName(tree.name) .. "~" .. tree.points .. "~" .. table.concat(talents, ",")
    end
    return table.concat(parts, ";")
end

local function ParseTalents(text)
    local trees = {}
    for piece in (text or ""):gmatch("[^;]+") do
        local name, points, list = piece:match("^([^~]*)~(%d+)~(.*)$")
        if name and #trees < 5 then
            local tree = { name = name, points = tonumber(points), talents = {} }
            for spell, rank in list:gmatch("(%d+)%-(%d+)") do
                if #tree.talents < 60 then
                    tree.talents[#tree.talents + 1] = { spell = tonumber(spell), rank = tonumber(rank) }
                end
            end
            trees[#trees + 1] = tree
        end
    end
    return trees
end

local MAX_ABOUT_BYTES = 600

-- "Om meg"-teksten: uten tabulator og tegnet | (linjeskift blir mellomrom),
-- kuttet uten å dele et tegn.
local function CleanAbout(text)
    text = tostring(text or ""):gsub("[%c|]", " ")
    text = text:gsub("^%s+", "")
    text = text:gsub("%s+$", "")
    local out = ""
    for char in text:gmatch("[%z\1-\127\194-\244][\128-\191]*") do
        if #out + #char > MAX_ABOUT_BYTES then
            break
        end
        out = out .. char
    end
    return out
end

-- Deling ------------------------------------------------------------------------

local Send = DW.CreateSender(PREFIX)
local lastSent = {} -- [type] = teksten vi sist sendte, så vi ikke gjentar oss

-- Sender en tekst, delt i biter som får plass i en melding.
local function SendText(kind, key, when, text)
    local chunks = {}
    for start = 1, math.max(1, #text), CHUNK_BYTES do
        chunks[#chunks + 1] = text:sub(start, start + CHUNK_BYTES - 1)
    end
    if #chunks > MAX_PARTS then
        return
    end
    for index, chunk in ipairs(chunks) do
        Send(table.concat({ kind, key, ("%d"):format(when), index .. "/" .. #chunks, chunk }, SEP))
    end
end

-- Leser egen karakter, tar vare på det, og sender det som er endret (eller
-- alt, med force).
local function Publish(force)
    local key = MyKey()
    if not key then
        return
    end
    local profile = ProfileFor(key, true)
    local now = Now()
    local changed = false

    local points = ReadLegacy()
    if points and (force or lastSent.P ~= points) then
        local max = ReadLegacyMax()
        profile.lp = { points = points, max = max, time = now }
        lastSent.P = points
        Send(table.concat({ "P", key, ("%d"):format(now), ("%d"):format(points), max and ("%d"):format(max) or "" }, SEP))
        changed = true
    end

    local gear = ReadGear()
    if gear and gear ~= "" and (force or lastSent.E ~= gear) then
        profile.gear = { time = now, items = ParseGear(gear) }
        lastSent.E = gear
        SendText("E", key, now, gear)
        changed = true
    end

    local talents = TalentsText(ReadTalentTrees())
    if talents and talents ~= "" and (force or lastSent.T ~= talents) then
        profile.talents = { time = now, trees = ParseTalents(talents) }
        lastSent.T = talents
        SendText("T", key, now, talents)
        changed = true
    end

    -- "Om meg": skrevet av spilleren selv (DW.SetMyAbout). Tidspunktet er når
    -- det ble skrevet, så den nyeste teksten vinner hos alle.
    local about = type(profile.about) == "table" and profile.about or nil
    local aboutText = about and about.text or ""
    if about and ((force and aboutText ~= "") or aboutText ~= (lastSent.A or "")) then
        lastSent.A = aboutText
        SendText("A", key, about.time or now, aboutText)
    end

    if changed then
        Changed()
    end
end

-- Mottak ------------------------------------------------------------------------

local incoming = {} -- [avsender + type] = en tekst som er på vei, bit for bit
local replyScheduled = false

local function Store(kind, key, when, text)
    local profile = ProfileFor(key, true)
    if kind == "E" then
        if type(profile.gear) == "table" and (profile.gear.time or 0) >= when then
            return
        end
        profile.gear = { time = when, items = ParseGear(text) }
    elseif kind == "T" then
        if type(profile.talents) == "table" and (profile.talents.time or 0) >= when then
            return
        end
        profile.talents = { time = when, trees = ParseTalents(text) }
    elseif kind == "A" then
        if type(profile.about) == "table" and (profile.about.time or 0) >= when then
            return
        end
        profile.about = { time = when, text = CleanAbout(text) }
    end
    Changed()
end

DW.OnGuildMessage(PREFIX, function(text, sender)
    local fields = {}
    for field in (text .. SEP):gmatch("(.-)" .. SEP) do
        fields[#fields + 1] = field
    end
    local kind, key, when = fields[1], fields[2], tonumber(fields[3])

    if kind == "R" then
        if replyScheduled then
            return
        end
        replyScheduled = true
        C_Timer.After(1 + math.random() * 6, function()
            replyScheduled = false
            if DW.IsMember() then
                Publish(true)
            end
        end)
        return
    end

    if type(key) ~= "string" or key == "" or #key > 60 or not when or when > Now() + 86400 then
        return
    end

    if kind == "P" then
        local points, max = tonumber(fields[4]), tonumber(fields[5] or "")
        if points and points >= 0 and points < 100000 then
            local profile = ProfileFor(key, true)
            if type(profile.lp) ~= "table" or (profile.lp.time or 0) < when then
                profile.lp = { points = points, max = (max and max > 0 and max < 100000) and max or nil, time = when }
                Changed()
            end
        end
    elseif kind == "E" or kind == "T" or kind == "A" then
        local index, count = (fields[4] or ""):match("^(%d+)/(%d+)$")
        index, count = tonumber(index), tonumber(count)
        if not index or not count or count < 1 or count > MAX_PARTS or index < 1 or index > count or not fields[5] then
            return
        end
        local slot = sender .. SEP .. kind
        local entry = incoming[slot]
        if not entry or entry.key ~= key or entry.time ~= when or entry.count ~= count then
            entry = { key = key, time = when, count = count, parts = {}, got = 0 }
            incoming[slot] = entry
        end
        if not entry.parts[index] then
            entry.parts[index] = fields[5]
            entry.got = entry.got + 1
        end
        if entry.got == entry.count then
            incoming[slot] = nil
            Store(kind, key, when, table.concat(entry.parts, "", 1, entry.count))
        end
    end
end)

-- For andre filer -----------------------------------------------------------------

local function IsMe(member)
    local guid = DW.MyGUID()
    if guid and member.guid then
        return member.guid == guid
    end
    local _, name = DW.CharacterKey()
    return name ~= nil and DW.NameKey(member.key) == DW.NameKey(name)
end

-- Alt vi vet om et medlem fra DW.ReadGuildRoster(): { legacy, gear, talents },
-- eller nil. For deg selv leses det på nytt først.
function DW.ProfileOf(member)
    if type(member) ~= "table" then
        return nil
    end
    if IsMe(member) and DW.IsMember() then
        Publish(false)
        local key = MyKey()
        return key and ProfileFor(key)
    end
    return ProfileFor(MemberKey(member))
end

-- Legacy-poengene til et medlem, og hvor mange som finnes i alt (kan være
-- nil): for deg selv rett fra spillet, ellers det medlemmets addon har sagt.
-- nil hvis vi ikke vet.
function DW.LegacyPointsOf(member)
    if type(member) ~= "table" then
        return nil
    end
    if IsMe(member) then
        local points = ReadLegacy()
        if points then
            return points, ReadLegacyMax()
        end
    end
    local profile = ProfileFor(MemberKey(member))
    if profile and type(profile.lp) == "table" and type(profile.lp.points) == "number" then
        return profile.lp.points, profile.lp.max or ReadLegacyMax()
    end
    return nil
end

-- "Om meg": det du har skrevet om deg selv, som andre ser på kortet ditt.
function DW.GetMyAbout()
    local key = MyKey()
    local profile = key and ProfileFor(key)
    return profile and type(profile.about) == "table" and profile.about.text or ""
end

-- Lagrer "om meg"-teksten. Den sendes til guilden med DW.PublishProfile()
-- (når du er ferdig å skrive), og ellers når du logger inn.
function DW.SetMyAbout(text)
    local key = MyKey()
    if not key then
        return
    end
    local profile = ProfileFor(key, true)
    text = CleanAbout(text)
    local old = type(profile.about) == "table" and profile.about or nil
    if old and old.text == text then
        return
    end
    if not old and text == "" then
        return
    end
    profile.about = { text = text, time = math.max(Now(), old and ((old.time or 0) + 1) or 0) }
end

-- Sender det som er endret i din egen profil nå.
function DW.PublishProfile()
    if DW.IsMember() then
        Publish(false)
    end
end

-- Navnet på en talent (en spell), hvis spillet har det.
function DW.SpellName(spell)
    if C_Spell and type(C_Spell.GetSpellName) == "function" then
        local ok, name = pcall(C_Spell.GetSpellName, spell)
        if ok and type(name) == "string" and not DW.IsSecret(name) then
            return name
        end
    end
    if type(GetSpellInfo) == "function" then
        local ok, name = pcall(GetSpellInfo, spell)
        if ok and type(name) == "string" and not DW.IsSecret(name) then
            return name
        end
    end
    return "#" .. tostring(spell)
end

-- Hendelser -------------------------------------------------------------------

local helloSent = false
local changeQueued = false
local PlanChange

local function PlanHello()
    if helloSent or not (C_Timer and C_Timer.After) then
        return
    end
    C_Timer.After(HELLO_DELAY, function()
        if not helloSent and DW.IsMember() then
            helloSent = true
            Publish(true)
            Send("R")
            -- Se etter igjen litt senere: spillet kan ha lastet legacy-poengene
            -- (og talentene) etter at vi leste første gang.
            PlanChange()
        end
    end)
end

-- Utstyr, talenter eller poeng er endret. Send det, men ikke for ofte.
PlanChange = function()
    if changeQueued or not helloSent then
        return
    end
    changeQueued = true
    C_Timer.After(CHANGE_DELAY, function()
        changeQueued = false
        if DW.IsMember() then
            Publish(false)
        end
    end)
end

local frame = CreateFrame("Frame")
frame:SetScript("OnEvent", function(self, event)
    if not DW.IsMember() then
        return
    end
    if event == "PLAYER_ENTERING_WORLD" then
        PlanHello()
    else
        PlanChange()
    end
end)
for _, event in ipairs({
    "PLAYER_ENTERING_WORLD",
    "PLAYER_EQUIPMENT_CHANGED",
    "TRAIT_CONFIG_UPDATED",
    "ACTIVE_TALENT_GROUP_CHANGED",
    "PLAYER_TALENT_UPDATE",
    "ACHIEVEMENT_EARNED",
    "MAJOR_FACTION_RENOWN_LEVEL_CHANGED", -- legacy-poengene er renown (se øverst)
}) do
    pcall(frame.RegisterEvent, frame, event)
end

DW.OnMembershipChanged(function(member)
    if member then
        PlanHello()
    end
end)

-- Feilsøking: hva spillet oppgir, særlig om legacy-poeng, som ikke er sjekket.
DW.AddDebug("profil", function(add)
    local text = DW.DebugText
    local legacy = ReadLegacy()
    add("legacy-poeng: " .. text(legacy) .. " av " .. text(ReadLegacyMax()) .. " | fra: " .. text(legacy and legacySource or "ingenting funnet"))
    local points
    if type(GetTotalAchievementPoints) == "function" then
        local ok, value = pcall(GetTotalAchievementPoints)
        points = ok and value or "feil"
    end
    add("GetTotalAchievementPoints: " .. text(points))
    local guid = DW.MyGUID()
    for _, member in ipairs(DW.ReadGuildRoster()) do
        if guid and member.guid == guid then
            add("poeng i medlemslisten (12. verdi): " .. text(member.points))
        end
    end
    -- Alt spillet har med "Legacy" i navnet, så vi kan finne riktig funksjon.
    local found = {}
    for name, value in pairs(_G) do
        if type(name) == "string" and name:find("Legacy") and #found < 25 then
            if type(value) == "table" and name:find("^C_") then
                local functions = {}
                for field, inner in pairs(value) do
                    if type(inner) == "function" and #functions < 12 then
                        functions[#functions + 1] = tostring(field)
                    end
                end
                table.sort(functions)
                found[#found + 1] = name .. " {" .. table.concat(functions, ", ") .. "}"
            elseif type(value) == "function" then
                found[#found + 1] = name .. "()"
            end
        end
    end
    table.sort(found)
    add("Legacy i spillet: " .. (#found > 0 and table.concat(found, " | ") or "ingenting"))
    local trees = ReadTalentTrees()
    local summary = {}
    for _, tree in ipairs(trees or {}) do
        summary[#summary + 1] = tree.name .. " " .. tree.points .. " (" .. #tree.talents .. ")"
    end
    add("talenter: " .. (trees and table.concat(summary, ", ") or "kunne ikke leses"))
    local gear = ReadGear()
    add("utstyr: " .. (gear and select(2, gear:gsub("=", "")) or 0) .. " plasser")
    -- Valutaene spillet har, så vi ser om legacy-poengene er en av dem.
    local C = C_CurrencyInfo
    if type(C) == "table" and type(C.GetCurrencyListSize) == "function" and type(C.GetCurrencyListInfo) == "function" then
        local names = {}
        local ok, size = pcall(C.GetCurrencyListSize)
        for index = 1, math.min((ok and Num(size)) or 0, 30) do
            local fine, info = pcall(C.GetCurrencyListInfo, index)
            if fine and type(info) == "table" and type(info.name) == "string" and not DW.IsSecret(info.name) then
                names[#names + 1] = info.name .. (info.isHeader and "" or ("=" .. text(info.quantity)))
            end
        end
        add("valutaer: " .. (#names > 0 and table.concat(names, ", ") or "ingen"))
    else
        add("valutaer: C_CurrencyInfo finnes ikke")
    end
end)
