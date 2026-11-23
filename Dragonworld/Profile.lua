-- Dragonworld - profile
-- What the addon shares about each character, so it can be shown on the
-- member card (MemberCard.lua) and in the Roster tab:
--   * legacy points
--   * the gear the character is wearing
--   * the talents
--   * "about me": a short text the player writes about themselves, which
--     others see
--   * the role the character plays: tank, healer, dps, or two of them. It is
--     chosen the first time (MainWindow.lua) and can be changed on your own
--     card, and is shown with an icon in the Roster tab.
-- Each addon only sends its own, and only when something has changed. On
-- login it asks the others for what has changed since it was last online (see
-- "What we have received" in Comm.lua). Everyone
-- keeps what they receive (it is saved), so a member who is offline is shown
-- as they were the last time you were online at the same time.
--
-- Legacy points: the game has no documented function for them, but two addons
-- made by others (AltStable's Legacy plugin and LegacyNavigator, read
-- 21.11.2026) read them the same way: the points are the "renown" level of
-- faction 2802 (Legacy Track), and the maximum (65) is
-- C_Traits.GetMaxAvailableTraitCurrency(4225, false). That is what we use.
-- The achievement points (GetTotalAchievementPoints) were the wrong track:
-- they were 0 for someone who had 2 legacy points. If the renown function is
-- missing, the addon looks for a currency or a C_...Legacy... function (see
-- FindLegacy... below).
-- "/dw debug" shows where the number came from.
--
-- Versions 0.12.0 and 0.13.0 sent a wrong number as message "L". That
-- message and what was saved from it are no longer used; legacy points are
-- now sent as "P".
--
-- Talents: Forever does not have the old talent functions (GetTalentInfo
-- etc.). The talent window is the game's talent tree (C_Traits): one tree per
-- class, with the three talent trees as groups. DungeonJournal reads them the
-- same way.
--
-- Messages (name DragonworldPf, fields separated by tab):
--   P key time points max             legacy points ("2", "65"; max may be missing)
--   E key time no/count text          gear: "1=12345:0:0,5=..." (slot=item)
--   T key time no/count text          talents: "Navn~poeng~spell-rang,...;..."
--   A key time no/count text          the "about me" text (empty text = deleted)
--   O key time roles                  the role: "TH" (at most two of T, H, D; empty = none)
--   K guid time state list            main and alts (Alts.lua): state S (shown; list = the
--                                     characters that belong together, main first, as GUIDs
--                                     without "Player-", comma-separated, 1-12 including
--                                     the sender), H (this character hidden) or O (sharing
--                                     off), with an empty list. Only sent by an account that
--                                     has taken part; then at every login, after a change and
--                                     in answers to R (since only the character itself can
--                                     send it): to R for everything, when it is newer than
--                                     asked for, or when not sent for K_REPEAT seconds.
--                                     Accepted only from that character.
--   R time                            send me what you have changed after time (server time)
--   R                                 send me everything (the first time, and once a week)
-- The time in P/E/T/A/O/K is when that part was last changed. Older versions
-- do not know O and K and ignore them.
-- Long texts are split into pieces and put together again at the receiver.

local ADDON_NAME, DW = ...
local L = DW.L

local PREFIX = "DragonworldPf" -- the name of the messages; max 16 characters
local SEP = "\t"
local CHUNK_BYTES = 200
local MAX_PARTS = 8
local HELLO_DELAY = 11         -- after login
local CHANGE_DELAY = 20        -- collect changes before we send
local GEAR_SLOTS = 19

-- Small things ------------------------------------------------------------------

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

-- Saved: DragonworldDB.profiles[key] = {
--   legacy  = { points, time },
--   gear    = { time, items = { [slot] = "12345:0:0..." } },
--   talents = { time, trees = { { name, points, talents = { { spell, rank }, ... } }, ... } },
--   roles   = { time, text = "TH" },
-- }
-- Your own also has gear.raw and talents.raw (the text that is sent),
-- sent = { [P/E/T/A/O] = the time of what was last sent } and rolesAsked
-- (true once you have been asked about the role the first time, even if you
-- answered "later").
local function Profiles()
    if type(DragonworldDB) ~= "table" then
        return {}
    end
    if type(DragonworldDB.profiles) ~= "table" then
        DragonworldDB.profiles = {}
    end
    -- Legacy points saved by 0.12.0/0.13.0 were a wrong number (see the top). Removed.
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

-- Registers a function that is called when something new about a member has arrived.
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

-- Reading your own character ------------------------------------------------------

-- Legacy points. See the explanation at the top. legacySource says where the
-- number came from (for /dw debug); legacyReader is the function we found, so
-- we only search once.
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

-- How well a function name looks like "all the points you have earned".
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

local LEGACY_FACTION = 2802        -- Legacy Track; the renown level is the points
local LEGACY_TRAIT_CURRENCY = 4225 -- the points as a talent currency, for the maximum

local function ReadRenown()
    local M = C_MajorFactions
    if type(M) ~= "table" or type(M.GetCurrentRenownLevel) ~= "function" then
        return nil
    end
    local ok, level = pcall(M.GetCurrentRenownLevel, LEGACY_FACTION)
    return ok and PlausiblePoints(level) or nil
end

-- How many legacy points exist in total (65 when Forever came out), or nil.
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
    -- Without it: search ourselves. If we found nothing, we try again after a
    -- minute, because the game may have loaded it late after login.
    if not legacyReader and (not legacySearched or GetTime() - legacySearched > 60) then
        legacySearched = GetTime()
        legacyReader, legacySource = FindLegacyCurrency()
        if not legacyReader then
            legacyReader, legacySource = FindLegacyFunction()
        end
    end
    return legacyReader and legacyReader() or nil
end

-- The gear as text: "1=12345:0:0,5=6789". The item is the game's item
-- code (what comes after "item:" in a link), without empty fields at the end.
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

-- The talents from the talent tree: one group per talent tree, with name,
-- points and the talents that have points (spell and rank), sorted from top
-- to bottom.
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

-- The "about me" text: without tab and the character | (line breaks become
-- spaces), cut without splitting a character.
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

-- Sharing -----------------------------------------------------------------------

local Send = DW.CreateSender(PREFIX)
local rolesQueued = false -- the role was just changed and is sent shortly (DW.SetMyRoles)

-- Sends a text, split into pieces that fit in a message.
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

local function CopyList(list)
    local copy = {}
    for i, value in ipairs(list) do
        copy[i] = value
    end
    return copy
end

-- Main and alts: characters that have sent their record (K) in this session.
-- A new character on the account is a new login, so it sends again.
local altSentThisSession = {} -- [key] = GetTime() of the last K sent this session
local K_REPEAT = 300          -- an unchanged K goes in an answer to R at most this often

-- The K message for a record, at most 255 bytes: should long GUIDs not fit,
-- characters are left out from the end, but never the sender.
local function AltMessage(key, record)
    if not key:find("^Player%-") then
        return nil
    end
    local short = {}
    for _, guid in ipairs(record.list) do
        short[#short + 1] = guid:sub(8)
    end
    local function Build()
        return table.concat({ "K", key, ("%d"):format(record.time), record.state, table.concat(short, ",") }, SEP)
    end
    local message = Build()
    local mine = key:sub(8)
    while #message > 255 and #short > 1 do
        local drop = #short
        if short[drop] == mine then
            drop = drop - 1
        end
        table.remove(short, drop)
        message = Build()
    end
    return #message <= 255 and message or nil
end

-- Reads your own character and keeps it. The time on each part is when it
-- was last changed, not when it was last sent, so the same profile has the
-- same time for everyone. Sends what has changed and not been sent yet, and
-- with since also everything changed after that time (0 = everything), to
-- someone who has asked for it. What has been sent is remembered in
-- profile.sent, also after logout.
local function Publish(since)
    local key = MyKey()
    if not key then
        return
    end
    local profile = ProfileFor(key, true)
    local changed = false

    -- Always newer than last time, even if the clock stands still for a second:
    -- otherwise a change right after a send would look like already sent.
    local function Stamp(old)
        local before = old and tonumber(old.time)
        return math.max(Now(), before and (before + 1) or 0)
    end

    local points = ReadLegacy()
    if points then
        local max = ReadLegacyMax()
        local old = type(profile.lp) == "table" and profile.lp or nil
        if not old or old.points ~= points or not old.time or (max and old.max ~= max) then
            profile.lp = { points = points, max = max or (old and old.max), time = Stamp(old) }
            changed = true
        end
    end

    local gear = ReadGear()
    if gear and gear ~= "" then
        local old = type(profile.gear) == "table" and profile.gear or nil
        if not old or old.raw ~= gear or not old.time then
            profile.gear = { time = Stamp(old), items = ParseGear(gear), raw = gear }
            changed = true
        end
    end

    local talents = TalentsText(ReadTalentTrees())
    if talents and talents ~= "" then
        local old = type(profile.talents) == "table" and profile.talents or nil
        if not old or old.raw ~= talents or not old.time then
            profile.talents = { time = Stamp(old), trees = ParseTalents(talents), raw = talents }
            changed = true
        end
    end

    -- Main and alts (Alts.lua): what this character says now. nil when the
    -- account never took part; then nothing is kept or sent.
    local altRecord = DW.MyAltRecord and DW.MyAltRecord()
    if altRecord then
        local old = type(profile.alts) == "table" and profile.alts or nil
        if not old or old.time ~= altRecord.time or old.state ~= altRecord.state
            or table.concat(type(old.list) == "table" and old.list or {}, ",") ~= table.concat(altRecord.list, ",") then
            profile.alts = { time = altRecord.time, state = altRecord.state, list = CopyList(altRecord.list) }
            changed = true
        end
    end

    -- Send each part that has not been sent with this time, or that is newer
    -- than what the one asking has.
    local sent = type(profile.sent) == "table" and profile.sent or {}
    profile.sent = sent
    local function Due(kind, part)
        if type(part) ~= "table" or type(part.time) ~= "number" then
            return false
        end
        return sent[kind] ~= part.time or (since ~= nil and part.time > since)
    end

    if Due("P", profile.lp) then
        local lp = profile.lp
        sent.P = lp.time
        Send(table.concat({ "P", key, ("%d"):format(lp.time), ("%d"):format(lp.points), lp.max and ("%d"):format(lp.max) or "" }, SEP))
    end
    if Due("E", profile.gear) and profile.gear.raw then
        sent.E = profile.gear.time
        SendText("E", key, profile.gear.time, profile.gear.raw)
    end
    if Due("T", profile.talents) and profile.talents.raw then
        sent.T = profile.talents.time
        SendText("T", key, profile.talents.time, profile.talents.raw)
    end
    -- "About me": written by the player themselves (DW.SetMyAbout). The time is
    -- when it was written, so the newest text wins for everyone. An empty text
    -- (deleted) is not sent to someone who asks for everything; they have
    -- nothing to delete.
    local about = profile.about
    if Due("A", about) and type(about.text) == "string" and not (since == 0 and about.text == "" and sent.A == about.time) then
        sent.A = about.time
        SendText("A", key, about.time, about.text)
    end
    -- The role: chosen by the player themselves (DW.SetMyRoles), sent as for
    -- "about me". While the player is clicking (rolesQueued), it waits until
    -- the clicks are done, unless someone has asked for it.
    local roles = profile.roles
    if Due("O", roles) and type(roles.text) == "string" and not (since == 0 and roles.text == "" and sent.O == roles.time)
        and not (rolesQueued and since == nil) then
        sent.O = roles.time
        Send(table.concat({ "O", key, ("%d"):format(roles.time), roles.text }, SEP))
    end
    -- Main and alts: only this character can send its record. It goes out at
    -- the first send of each character's session (its login), after a change,
    -- and in answers to R: for everything, when newer than asked for, or when
    -- not sent for K_REPEAT seconds (not in every answer of a login wave).
    local lastK = altSentThisSession[key]
    local askedK = since ~= nil and (since == 0 or (altRecord and altRecord.time > since)
        or not lastK or GetTime() - lastK >= K_REPEAT)
    if altRecord and (askedK or not lastK or sent.K ~= altRecord.time) then
        local message = AltMessage(key, altRecord)
        if message then
            altSentThisSession[key] = GetTime()
            sent.K = altRecord.time
            Send(message)
        end
    end

    if changed then
        Changed()
    end
end

-- Receiving ---------------------------------------------------------------------

local incoming = {} -- [sender + type] = a text on its way, piece by piece
local replyScheduled = false
local replySince     -- the earliest time anyone has asked for changes from

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

-- Main and alts: K messages whose sender could not be checked yet, because
-- the character is not in our copy of the guild roster. Retried when the
-- roster changes; at most 50, each for 120 seconds. One per character and
-- sender, so a message from someone else cannot push out the real one.
local MAX_PENDING_K = 50
local PENDING_K_SECONDS = 120
local pendingK = {} -- [guid .. tab .. sender's name key] = { guid, text, sender, at = GetTime() }

local function Fields(text)
    local fields = {}
    for field in (text .. SEP):gmatch("(.-)" .. SEP) do
        fields[#fields + 1] = field
    end
    return fields
end

-- A K message's guid, time, state and list (full GUIDs), or nil when anything
-- in it is wrong.
local function ParseAltMessage(fields)
    local guid, when, state, list = fields[2], tonumber(fields[3]), fields[4], fields[5]
    if #fields ~= 5 or type(guid) ~= "string" or #guid > 60 or not guid:find("^Player%-[%w]+%-[%w]+$") then
        return nil
    end
    if not when or when <= 0 or when ~= math.floor(when) or when > Now() + 600 then
        return nil
    end
    if state ~= "S" and state ~= "H" and state ~= "O" then
        return nil
    end
    local entries, seen = {}, {}
    if list ~= "" then
        for part in (list .. ","):gmatch("([^,]*),") do
            local full = "Player-" .. part
            if #part > 24 or not part:find("^[%w]+%-[%w]+$") or seen[full] then
                return nil
            end
            seen[full] = true
            entries[#entries + 1] = full
        end
    end
    if state == "S" then
        if #entries < 1 or #entries > (DW.ALT_MAX or 12) or not seen[guid] then
            return nil
        end
    elseif #entries > 0 then
        return nil
    end
    return guid, when, state, entries
end

local function DropOldPendingK()
    local now = GetTime()
    for slot, entry in pairs(pendingK) do
        if now - entry.at > PENDING_K_SECONDS then
            pendingK[slot] = nil
        end
    end
end

local function ReceiveAltMessage(fields, text, sender)
    local guid, when, state, list = ParseAltMessage(fields)
    if not guid then
        return
    end
    local slot = guid .. SEP .. DW.NameKey(sender)
    if not (DW.AltSenderMatches and DW.AltSenderMatches(guid, sender)) then
        -- Maybe the roster has not got this character yet: wait for it.
        DropOldPendingK()
        if not pendingK[slot] then
            local count, oldest = 0, nil
            for other, entry in pairs(pendingK) do
                count = count + 1
                if not oldest or entry.at < pendingK[oldest].at or (entry.at == pendingK[oldest].at and other < oldest) then
                    oldest = other
                end
            end
            if count >= MAX_PENDING_K and oldest then
                pendingK[oldest] = nil
            end
        end
        pendingK[slot] = { guid = guid, text = text, sender = sender, at = GetTime() }
        return
    end
    pendingK[slot] = nil
    local profile = ProfileFor(guid, true)
    if type(profile.alts) == "table" and (tonumber(profile.alts.time) or 0) >= when then
        return
    end
    profile.alts = { time = when, state = state, list = list }
    Changed()
end

-- The roster has changed: try the K messages that waited for it again.
local function RetryPendingK()
    DropOldPendingK()
    if not next(pendingK) then
        return
    end
    if DW.InvalidateAltRoster then
        DW.InvalidateAltRoster()
    end
    local waiting = {}
    for slot, entry in pairs(pendingK) do
        waiting[#waiting + 1] = { slot = slot, entry = entry }
    end
    table.sort(waiting, function(a, b) return a.slot < b.slot end)
    for _, item in ipairs(waiting) do
        if DW.AltSenderMatches and DW.AltSenderMatches(item.entry.guid, item.entry.sender) then
            pendingK[item.slot] = nil
            ReceiveAltMessage(Fields(item.entry.text), item.entry.text, item.entry.sender)
        end
    end
end

DW.OnGuildMessage(PREFIX, function(text, sender)
    local fields = Fields(text)
    local kind, key, when = fields[1], fields[2], tonumber(fields[3])

    if kind == "K" then
        ReceiveAltMessage(fields, text, sender)
        return
    end

    if kind == "R" then
        -- Someone asks for what has changed after a time (or everything).
        -- Several asking at the same time get one reply, from the earliest time.
        local since = DW.SyncRequestSince(text)
        replySince = math.min(replySince or since, since)
        if replyScheduled then
            return
        end
        replyScheduled = true
        C_Timer.After(1 + math.random() * 6, function()
            replyScheduled = false
            local from = replySince or 0
            replySince = nil
            if DW.IsMember() then
                Publish(from)
            end
        end)
        return
    end

    if type(key) ~= "string" or key == "" or #key > 60 or not when or when > Now() + 86400 then
        return
    end

    if kind == "O" then
        local text = fields[4] or ""
        if #text <= 3 and not text:find("[^THD]") then
            local profile = ProfileFor(key, true)
            if type(profile.roles) ~= "table" or (profile.roles.time or 0) < when then
                profile.roles = { time = when, text = DW.RolesToText(DW.RolesFromText(text)) }
                Changed()
            end
        end
    elseif kind == "P" then
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

-- For other files -----------------------------------------------------------------

local function IsMe(member)
    local guid = DW.MyGUID()
    if guid and member.guid then
        return member.guid == guid
    end
    local name = DW.CharacterKey()
    return name ~= nil and DW.SameCharacter(member.key, name)
end

-- All we know about a member from DW.ReadGuildRoster(): { legacy, gear, talents },
-- or nil. For yourself it is read again first.
function DW.ProfileOf(member)
    if type(member) ~= "table" then
        return nil
    end
    if IsMe(member) and DW.IsMember() then
        Publish()
        local key = MyKey()
        return key and ProfileFor(key)
    end
    return ProfileFor(MemberKey(member))
end

-- A member's legacy points, and how many exist in total (can be nil): for
-- yourself straight from the game, otherwise what the member's addon has said.
-- nil if we do not know.
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

-- "About me": what you have written about yourself, which others see on your card.
function DW.GetMyAbout()
    local key = MyKey()
    local profile = key and ProfileFor(key)
    return profile and type(profile.about) == "table" and profile.about.text or ""
end

-- Saves the "about me" text. It is sent to the guild with DW.PublishProfile()
-- (when you are done writing), and otherwise when you log in.
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

-- Main and alts: the record a character has published ({ time, state, list
-- of full GUIDs }), or nil. For yourself it is what you send.
function DW.AltRecordOf(guid)
    if type(guid) ~= "string" then
        return nil
    end
    local profile = ProfileFor(guid)
    local record = profile and profile.alts
    if type(record) == "table" and type(record.time) == "number" and type(record.list) == "table"
        and (record.state == "S" or record.state == "H" or record.state == "O") then
        return record
    end
    return nil
end

-- For /dw debug [alts]: the time of the K this character last sent, how many
-- records are stored, and how many K messages wait for the roster.
function DW.AltProfileStats()
    local key = MyKey()
    local profile = key and ProfileFor(key)
    local stored = 0
    for _, other in pairs(Profiles()) do
        if type(other) == "table" and type(other.alts) == "table" then
            stored = stored + 1
        end
    end
    local buffered = 0
    for _ in pairs(pendingK) do
        buffered = buffered + 1
    end
    return profile and type(profile.sent) == "table" and profile.sent.K or nil, stored, buffered
end

-- Sends what has changed in your own profile now.
function DW.PublishProfile()
    if DW.IsMember() then
        Publish()
    end
end

-- The role --------------------------------------------------------------------

local function RolesIn(profile)
    if profile and type(profile.roles) == "table" and type(profile.roles.text) == "string" then
        return DW.RolesFromText(profile.roles.text)
    end
    return nil
end

-- The role you have chosen for this character: { T = true, ... } (empty if none).
function DW.GetMyRoles()
    local key = MyKey()
    return RolesIn(key and ProfileFor(key)) or {}
end

-- A member's role from DW.ReadGuildRoster(), or nil if we do not know
-- (no addon, or not chosen). For yourself it is your own.
function DW.RolesOf(member)
    if type(member) ~= "table" then
        return nil
    end
    local key = IsMe(member) and MyKey() or MemberKey(member)
    local roles = RolesIn(key and ProfileFor(key))
    if roles and next(roles) then
        return roles
    end
    return nil
end

-- Saves your role (at most two) and sends it to the guild a little later, so
-- several clicks right after each other become one message.
function DW.SetMyRoles(set)
    local key = MyKey()
    if not key then
        return
    end
    local profile = ProfileFor(key, true)
    profile.rolesAsked = true
    local text = DW.RolesToText(DW.RolesFromText(DW.RolesToText(set)))
    local old = type(profile.roles) == "table" and profile.roles or nil
    if (old and old.text == text) or (not old and text == "") then
        return
    end
    profile.roles = { text = text, time = math.max(Now(), old and ((old.time or 0) + 1) or 0) }
    -- Schedule the send before the views are updated: the card reads the
    -- profile again (DW.ProfileOf), and it must not send the role in the
    -- middle of the clicking.
    if not rolesQueued and C_Timer and C_Timer.After then
        rolesQueued = true
        C_Timer.After(2, function()
            rolesQueued = false
            if DW.IsMember() then
                Publish()
            end
        end)
    end
    Changed()
end

-- Should we ask about the role? The first time on each character, until it
-- is chosen or the player has answered "later".
function DW.NeedsRoleChoice()
    local key = MyKey()
    if not key or not DW.IsMember() then
        return false
    end
    local profile = ProfileFor(key)
    if profile and (profile.rolesAsked or (RolesIn(profile) and next(RolesIn(profile)))) then
        return false
    end
    return true
end

-- "Later": do not ask again. The role can be chosen on your card.
function DW.SkipRoleChoice()
    local key = MyKey()
    if key then
        ProfileFor(key, true).rolesAsked = true
    end
end

-- The name of a talent (a spell), if the game has it.
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

-- Events ----------------------------------------------------------------------

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
            -- Only what has changed since last time. Those who were offline
            -- then get it when they log in and ask.
            Publish()
            Send(DW.SyncRequest())
            -- Check again a little later: the game may have loaded the legacy
            -- points (and the talents) after we first read.
            PlanChange()
        end
    end)
end

-- Gear, talents or points have changed. Send it, but not too often.
PlanChange = function()
    if changeQueued or not helloSent then
        return
    end
    changeQueued = true
    C_Timer.After(CHANGE_DELAY, function()
        changeQueued = false
        if DW.IsMember() then
            Publish()
        end
    end)
end

-- Main and alts: a character of an account that takes part sends its record
-- at its login, also when the hello of this session has already been sent
-- (another character logged in on the account since then).
local altHelloQueued = false

local function PlanAltHello()
    local key = MyKey()
    if altHelloQueued or not helloSent or not key or altSentThisSession[key] or not (DW.MyAltRecord and DW.MyAltRecord()) then
        return
    end
    altHelloQueued = true
    C_Timer.After(HELLO_DELAY, function()
        altHelloQueued = false
        if DW.IsMember() then
            Publish()
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
        PlanAltHello()
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
    "MAJOR_FACTION_RENOWN_LEVEL_CHANGED", -- the legacy points are renown (see the top)
}) do
    pcall(frame.RegisterEvent, frame, event)
end

-- Its own frame: the events above plan a send, this one must not.
local rosterFrame = CreateFrame("Frame")
rosterFrame:SetScript("OnEvent", function()
    if next(pendingK) and DW.IsMember() then
        RetryPendingK()
    end
end)
rosterFrame:RegisterEvent("GUILD_ROSTER_UPDATE")

DW.OnMembershipChanged(function(member)
    if member then
        PlanHello()
        PlanAltHello()
    end
end)

-- Debugging: what the game reports, especially about legacy points, which is not checked.
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
    -- Everything the game has with "Legacy" in the name, so we can find the right function.
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
    -- The currencies the game has, so we can see if the legacy points are one of them.
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
