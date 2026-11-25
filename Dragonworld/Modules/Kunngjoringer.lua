-- Dragonworld - Kunngjoringer (announcements)
-- Officers write announcements to the whole guild: a heading and a message,
-- optionally pinned. They open in a window over the main window (no tab of
-- their own), the newest pinned one shows in a strip at the top of the main
-- window (MainWindow.lua), and everyone with the addon gets a gold banner,
-- live or at the next login. The Guild Master's "Officers: X and up" chip
-- (Admin.lua, DW.SetOfficerLimit) lives in the same window.
--
-- How announcements are shared (the same way as suggestions in Forslag.lua):
--   * Small messages on the guild channel that only other addons see.
--   * Each version has a server time; the newest wins. On the same time a
--     deletion wins, then the larger `by` (the officer of that version).
--   * When you log in, the addon sends a short list of what it has. Those who
--     are online send what you are missing (5 at a time), and ask for what they miss.
--   * The message can be longer than one addon message, and is then sent in pieces.
--
-- Trust: an announcement version is accepted when `by` (the officer who made
-- that version) is an officer, from any guild member (DW.WhenRelayedAction).
-- So every member passes announcements on, and members who log in while no
-- officer is online still get them. Versions undecided, or refused for the
-- version itself, are held (DW.NewHeldStore), so they are not asked for
-- again at every login, and tried again when the officers change. A deletion
-- is final. Rank decides only what is shown; records are purged by age and a
-- fixed cap.
--
-- Fakes: a member who changes their own addon could write an announcement in
-- an officer's name. Each client remembers the versions it made itself
-- (db.authored), so the officer's own client notices a version in their name
-- that they never made, deletes it at once and says so in chat (SelfHeal).
-- Only versions made after db.authored was started are judged, so a /reload
-- or a lost saved file never deletes a real one.
--
-- No flood: answers to a hello wait a random time, officers shorter than
-- members, and every version someone else sends meanwhile is not sent again
-- (MarkSeen/SeenCovers). When someone else has started answering, the rest
-- waits until they are done (RunBatch).
--
-- The message pieces (T) are taken from the one who sent us the version (A),
-- or from its officer or another officer.
--
-- The messages (name DragonworldAnn, fields separated by tab):
--   A id updated flags round parts by title   a version (flags: "-", or letters p pinned, d deleted)
--   T id updated index text                   a piece of the message ("~" is "~~", a line break "~n")
--   H id,updated,h ...   and then   Q          what I have (h: flags and a hash of `by`; "-" unknown)
--   G id ...                                  send me these
--
-- All text is in Locales.lua (the names that start with ANN_ and OFF_).

local ADDON_NAME, DW = ...
local L = DW.L

local MODULE_ID = "kunngjoringer"
local PREFIX = "DragonworldAnn" -- max 16 characters
local SEP = "\t"
local OVERLAY_NAME = "DragonworldAnnouncements"

local DAY = 86400
local MAX_TITLE_LETTERS = 60
local MAX_TITLE_BYTES = 120
local MAX_BODY_LETTERS = 500
local MAX_BODY_BYTES = 1000     -- encoded ("~" and line breaks count twice)
local MAX_PARTS = 8
local MAX_LINES = 8             -- extra line breaks become spaces
local MAX_PINNED = 3
local SHOW_DAYS = 30            -- unpinned: since it was written
local PIN_MAX_DAYS = 90         -- pinned: since the last change
local KEEP_DELETED = 30 * DAY
local MAX_ITEMS = 40            -- announcements that are not deleted
local MAX_ID_BYTES = 60         -- when we create one
local MAX_RECEIVED_ID_BYTES = 80
local MAX_BY_BYTES = 60
local MAX_ROUND = 99
local MAX_MESSAGE_BYTES = 250   -- the game's limit is 255
local HELLO_DELAY = 18          -- after login (other modules use other delays)
local PART_WAIT = 20            -- how long we wait for the rest of a message
local LOGIN_BANNER_DELAY = 34   -- after the hello
local LOGIN_SETTLE = 12         -- after each announcement taken in during the login exchange
local LOGIN_WINDOW = 120        -- the login banners come at most this long after the hello
local LIVE_SECONDS = 300        -- a live banner only for versions this fresh
local LOGIN_BANNERS = 2
local BANNER_RECENT = 14 * DAY  -- unpinned announcements older than this get no banner
local FUTURE = 600              -- how far ahead of the server clock a time may be
local BATCH = 5                 -- records per batch when answering
local MEMBER_WAIT = 3           -- members answer this much later than officers...
local MEMBER_SPREAD = 24        -- ...plus a random part of this (15 s in the tests)
local HEAL_NOTICE_EVERY = 30    -- at most one chat line about removed fakes this often

-- Saved data. Set in OnLoad at the bottom.
--   db.items[id] = {
--       id = "<author key>:<created>:<seq>", author, created,
--       title, body, pinned, deleted,
--       updated = server time of this version (the newest wins),
--       round   = banner round (1 when written; +1 when an officer asks to show it again),
--       by      = "Name-Realm" of the officer who made this version,
--       bodyParts = { count = n, [index] = piece } while the message is on its way,
--   }
--   db.bannered[id] = the round shown as a banner on this account
--   db.seq = counter that makes each id unique
--   db.held = versions held for trust reasons (DW.NewHeldStore)
--   db.authored[id] = { [updated] = true }: the versions made on this account
--       (by any of its characters; `by` tells which), forgotten when too old
--       to be taken in by anyone
--   db.authoredSince = server time db.authored was started: only versions
--       after it can be told apart as fakes
local db = { items = {}, bannered = {}, authored = {} }
local held = DW.NewHeldStore({}) -- replaced in OnLoad

-- Small things ------------------------------------------------------------------

local function Now()
    return DW.ServerNow()
end

local function Num(value)
    return ("%d"):format(value)
end

local function MyKey()
    return (DW.CharacterKey())
end

local function ShortName(key)
    return (type(key) == "string" and key:match("^([^-]+)")) or tostring(key)
end

local function IsWhole(value)
    return type(value) == "number" and value == math.floor(value)
end

local CHAR = "[%z\1-\127\194-\244][\128-\191]*"

-- Cuts a text to a number of letters and bytes without splitting a letter.
local function Cut(text, maxLetters, maxBytes)
    local out, letters, bytes = {}, 0, 0
    for char in text:gmatch(CHAR) do
        if (maxLetters and letters >= maxLetters) or bytes + #char > maxBytes then
            break
        end
        out[#out + 1] = char
        letters = letters + 1
        bytes = bytes + #char
    end
    return table.concat(out)
end

local function Truncate(text, maxBytes)
    return Cut(text, nil, maxBytes)
end

-- Headings: no line breaks, tabs or "|" (the game's colour and link code).
local function CleanTitle(text)
    text = tostring(text or "")
    text = text:gsub("[%c|]", " ")
    text = text:gsub("^%s+", "")
    text = text:gsub("%s+$", "")
    return Cut(text, MAX_TITLE_LETTERS, MAX_TITLE_BYTES)
end

-- Messages keep their line breaks (at most MAX_LINES lines); "|" and other
-- control characters become spaces. At most MAX_BODY_LETTERS letters and
-- MAX_BODY_BYTES bytes once encoded.
local function CleanBody(text)
    text = tostring(text or "")
    text = text:gsub("\r\n", "\n")
    text = text:gsub("\r", "\n")
    text = text:gsub("|", " ")
    text = text:gsub("[%z\1-\9\11-\31\127]", " ")
    text = text:gsub("^%s+", "")
    text = text:gsub("%s+$", "")
    local breaks = 0
    text = text:gsub("\n", function()
        breaks = breaks + 1
        return breaks < MAX_LINES and "\n" or " "
    end)
    local out, letters, bytes = {}, 0, 0
    for char in text:gmatch(CHAR) do
        local size = (char == "~" or char == "\n") and 2 or #char
        if letters >= MAX_BODY_LETTERS or bytes + size > MAX_BODY_BYTES then
            break
        end
        out[#out + 1] = char
        letters = letters + 1
        bytes = bytes + size
    end
    return (table.concat(out):gsub("%s+$", ""))
end

local function Encode(text)
    text = text:gsub("~", "~~")
    text = text:gsub("\n", "~n")
    return text
end

local function Decode(text)
    return (text:gsub("~(.?)", function(code)
        if code == "n" then
            return "\n"
        end
        return code -- "~~" gives "~"; a lone "~" at the end disappears
    end))
end

-- Splits an encoded text into pieces of at most room bytes, without splitting
-- a letter or a "~" escape.
local function Pieces(text, room)
    local list, current, index = {}, "", 1
    while index <= #text do
        local byte = text:byte(index)
        local size = 1
        if byte == 126 then
            size = 2
        elseif byte >= 0xF0 then
            size = 4
        elseif byte >= 0xE0 then
            size = 3
        elseif byte >= 0xC0 then
            size = 2
        end
        local token = text:sub(index, index + size - 1)
        index = index + size
        if #current + #token > room and current ~= "" then
            list[#list + 1] = current
            current = ""
        end
        current = current .. token
    end
    if current ~= "" then
        list[#list + 1] = current
    end
    return list
end

local function Split(text, separator)
    local pieces = {}
    for piece in (text .. separator):gmatch("(.-)" .. separator) do
        pieces[#pieces + 1] = piece
    end
    return pieces
end

local function SortedKeys(tbl)
    local keys = {}
    for key in pairs(tbl) do
        keys[#keys + 1] = key
    end
    table.sort(keys)
    return keys
end

-- An id looks like this: "Name-Realm:time:counter": who wrote it, and when.
local function AuthorOf(id)
    return id:match("^(.+):%d+:%d+$")
end

local function CreatedOf(id)
    return tonumber(id:match(":(%d+):%d+$")) or 0
end

local function FlagsOf(pinned, deleted)
    local flags = (pinned and "p" or "") .. (deleted and "d" or "")
    return flags ~= "" and flags or "-"
end

-- The "h" of the H list: the flags and a hash of `by`, so two versions with
-- the same time but different content are noticed.
local B36 = "0123456789abcdefghijklmnopqrstuvwxyz"
local function DigestOf(pinned, deleted, by)
    local sum = 0
    by = by or ""
    for index = 1, #by do
        sum = sum + by:byte(index)
    end
    sum = sum % 1296
    local high, low = math.floor(sum / 36) + 1, sum % 36 + 1
    return (pinned and "p" or "") .. (deleted and "d" or "") .. B36:sub(high, high) .. B36:sub(low, low)
end

local function Digest(item)
    return DigestOf(item.pinned and not item.deleted, item.deleted, item.by)
end

-- Rules ---------------------------------------------------------------------------
-- The same on every client. Rank never decides what is purged.

local function FreshEnough(deleted, pinned, updated, created, now)
    if deleted then
        return updated > now - KEEP_DELETED
    end
    return (pinned and updated > now - PIN_MAX_DAYS * DAY) or created > now - SHOW_DAYS * DAY
end

-- The ids that are remembered and shared: fresh enough, and among those not
-- deleted only the newest MAX_ITEMS (by when they were written).
local function SyncableSet()
    local now = Now()
    local set, live = {}, {}
    for id, item in pairs(db.items) do
        if FreshEnough(item.deleted, item.pinned, item.updated, item.created, now) then
            if item.deleted then
                set[id] = true
            else
                live[#live + 1] = item
            end
        end
    end
    table.sort(live, function(a, b)
        if a.created ~= b.created then
            return a.created > b.created
        end
        return a.id > b.id
    end)
    for index = 1, math.min(#live, MAX_ITEMS) do
        set[live[index].id] = true
    end
    return set
end

local function NewestFirst(a, b)
    if a.updated ~= b.updated then
        return a.updated > b.updated
    end
    return a.id > b.id
end

-- What is shown: syncable, not deleted, the whole message here, and made by
-- someone who is an officer now. Returns the syncable set, the shown records,
-- the shown-pinned set (the newest MAX_PINNED pinned by updated) and that list.
local function State()
    local set = SyncableSet()
    local shown, pinnedList, pinnedSet = {}, {}, {}
    for id in pairs(set) do
        local item = db.items[id]
        if not item.deleted and not item.bodyParts and DW.IsOfficerKey(item.by) == true then
            shown[#shown + 1] = item
            if item.pinned then
                pinnedList[#pinnedList + 1] = item
            end
        end
    end
    table.sort(pinnedList, NewestFirst)
    for index = #pinnedList, MAX_PINNED + 1, -1 do
        pinnedList[index] = nil
    end
    for _, item in ipairs(pinnedList) do
        pinnedSet[item.id] = true
    end
    return set, shown, pinnedSet, pinnedList
end

-- Shown-pinned first, then the newest change first.
local function Ordered(shown, pinnedSet)
    local list = {}
    for index, item in ipairs(shown) do
        list[index] = item
    end
    table.sort(list, function(a, b)
        local pa, pb = pinnedSet[a.id] == true, pinnedSet[b.id] == true
        if pa ~= pb then
            return pa
        end
        return NewestFirst(a, b)
    end)
    return list
end

local function Copy(item, pinnedSet)
    return {
        id = item.id, title = item.title, body = item.body, author = item.author, created = item.created,
        updated = item.updated, pinned = pinnedSet[item.id] == true, by = item.by,
    }
end

local function PurgeExpired()
    local set = SyncableSet()
    for id in pairs(db.items) do
        if not set[id] then
            db.items[id] = nil
        end
    end
    for id in pairs(db.bannered) do
        if not db.items[id] then
            db.bannered[id] = nil
        end
    end
    -- Our own versions are forgotten when no client would take them in any
    -- more (FreshEnough: nothing lives longer than PIN_MAX_DAYS after its
    -- last change), not when the record leaves our list: someone else may
    -- still send it back before they purge it too.
    local oldest = Now() - PIN_MAX_DAYS * DAY
    for id, versions in pairs(db.authored) do
        if type(versions) == "table" then
            for updated in pairs(versions) do
                if type(updated) ~= "number" or updated < oldest then
                    versions[updated] = nil
                end
            end
        end
        if type(versions) ~= "table" or next(versions) == nil then
            db.authored[id] = nil
        end
    end
    held:Purge()
end

-- The versions made on this account (see db.authored).
local function NoteAuthored(id, updated)
    local versions = db.authored[id]
    if type(versions) ~= "table" then
        versions = {}
        db.authored[id] = versions
    end
    versions[updated] = true
end

local function Authored(id, updated)
    local versions = db.authored[id]
    return type(versions) == "table" and versions[updated] == true
end

-- Listeners ---------------------------------------------------------------------

local listeners = {}
local QueueRefresh

-- Called after every change that may change what is shown.
function DW.OnAnnouncementsChanged(callback)
    listeners[#listeners + 1] = callback
end

local function Changed()
    for _, callback in ipairs(listeners) do
        local ok, problem = pcall(callback)
        if not ok then
            DW.PrintError(L.ERROR, problem)
        end
    end
    QueueRefresh()
end

-- Sending -----------------------------------------------------------------------

local Send = DW.CreateSender(PREFIX)

-- Versions we have seen sent (by us or others) since someone last asked:
-- seen[id] = { u = updated, h = { [digest] = true } }. Used to avoid sending
-- what someone else has already sent.
local seen = {}

local function MarkSeen(id, updated, h)
    local entry = seen[id]
    if not entry or updated > entry.u then
        seen[id] = { u = updated, h = { [h] = true } }
    elseif updated == entry.u then
        entry.h[h] = true
    end
end

local function SeenCovers(item)
    local entry = seen[item.id]
    return entry ~= nil and (entry.u > item.updated or (entry.u == item.updated and entry.h[Digest(item)] == true))
end

local function SendAnn(item)
    local pieces = {}
    if not item.deleted and (item.body or "") ~= "" then
        -- Room per piece, from the header of the T message (index 1-8: one digit).
        local header = table.concat({ "T", item.id, Num(item.updated), Num(MAX_PARTS), "" }, SEP)
        pieces = Pieces(Encode(item.body), MAX_MESSAGE_BYTES - #header)
        for index = #pieces, MAX_PARTS + 1, -1 do
            pieces[index] = nil
        end
    end
    local function Build(title)
        return table.concat({
            "A", item.id, Num(item.updated), FlagsOf(item.pinned, item.deleted), Num(item.round or 1), Num(#pieces), item.by or "", title,
        }, SEP)
    end
    local title = item.deleted and "" or (item.title or "")
    local message = Build(title)
    if #message > MAX_MESSAGE_BYTES then
        message = Build(Truncate(title, math.max(0, #title - (#message - MAX_MESSAGE_BYTES))))
    end
    Send(message)
    for index, piece in ipairs(pieces) do
        Send(table.concat({ "T", item.id, Num(item.updated), Num(index), piece }, SEP))
    end
    MarkSeen(item.id, item.updated, Digest(item))
end

-- Sends a list of text pieces spread over as few messages as possible.
local function SendList(kind, entries)
    local parts, size = { kind }, #kind
    for _, entry in ipairs(entries) do
        if size + 1 + #entry > MAX_MESSAGE_BYTES and #parts > 1 then
            Send(table.concat(parts, SEP))
            parts, size = { kind }, #kind
        end
        parts[#parts + 1] = entry
        size = size + 1 + #entry
    end
    if #parts > 1 then
        Send(table.concat(parts, SEP))
    end
end

-- Banners -----------------------------------------------------------------------

local helloAt      -- GetTime() of this session's hello
local loginDue     -- GetTime() when the login banners may be picked
local loginDone = false
local loginToken = 0

local function ShowAnnBanner(item)
    -- Its own box in the Achievements tab ("Banners for announcements and polls").
    if not DW.ShowBanner or (DW.NewsBannersOn and not DW.NewsBannersOn()) then
        return false
    end
    local id = item.id
    return DW.ShowBanner({
        key = "ann:" .. id,
        always = true,
        title = function()
            return L.ANN_BANNER
        end,
        text = function()
            return DW.BannerGold(item.title or "") .. "\n" .. L.ANN_BANNER_FROM:format(ShortName(item.author))
        end,
        button = function()
            return L.ANN_READ
        end,
        -- Remembered only when it is really shown, so a dropped banner comes at the next login.
        onShow = function()
            db.bannered[id] = item.round
        end,
        onClick = function()
            DW.ShowAnnouncements(id)
        end,
    })
end

-- Should this record give a banner on this account?
local function Eligible(item, set, pinnedSet)
    if not set[item.id] or item.deleted or item.bodyParts or DW.IsOfficerKey(item.by) ~= true then
        return false
    end
    if DW.SameCharacter(item.by, MyKey()) then
        return false
    end
    if (item.round or 0) <= (tonumber(db.bannered[item.id]) or 0) then
        return false
    end
    return pinnedSet[item.id] == true or item.created > Now() - BANNER_RECENT
end

local function LoginSelectionDone()
    return loginDone or (helloAt ~= nil and GetTime() - helloAt > LOGIN_WINDOW)
end

-- At login: the newest eligible announcements, at most LOGIN_BANNERS. The
-- rest wait in the window.
local function RunLoginSelection()
    loginDone = true
    if not DW.IsMember() then
        return
    end
    local set, _, pinnedSet = State()
    local list = {}
    for id in pairs(set) do
        local item = db.items[id]
        if Eligible(item, set, pinnedSet) then
            list[#list + 1] = item
        end
    end
    table.sort(list, NewestFirst)
    for index = 1, math.min(#list, LOGIN_BANNERS) do
        ShowAnnBanner(list[index])
    end
end

local function CheckLogin(token)
    if loginDone or token ~= loginToken then
        return
    end
    local now = GetTime()
    if now >= loginDue then
        RunLoginSelection()
    else
        C_Timer.After(loginDue - now + 0.05, function()
            CheckLogin(token)
        end)
    end
end

-- A record was taken in (or its message completed).
local function AfterApply(id)
    if not loginDone and helloAt then
        -- The login banners wait until the login exchange has settled.
        loginDue = math.min(helloAt + LOGIN_WINDOW, math.max(loginDue or 0, GetTime() + LOGIN_SETTLE))
    end
    local item = db.items[id]
    if item and Now() - item.updated <= LIVE_SECONDS and LoginSelectionDone() then
        local set, _, pinnedSet = State()
        if Eligible(item, set, pinnedSet) then
            ShowAnnBanner(item)
        end
    end
    Changed()
end

-- Exchange ---------------------------------------------------------------------

local hello = {}  -- [sender] = { [id] = true } while we receive their list
local offers = {} -- [id] = true: what we will send
local wanted = {} -- [id] = true: what we will ask for
local batchQueue = {} -- ids waiting to be sent, BATCH at a time
local exchangeScheduled, batchScheduled = false, false

local function Offer(id)
    if not offers[id] then
        offers[id] = true
        -- From now on we count what others manage to send before us.
        seen[id] = nil
    end
end

local function RunBatch()
    batchScheduled = false
    if not DW.IsMember() then
        batchQueue = {}
        return
    end
    -- The seen check is made again before every batch: what someone else has
    -- sent (or a newer version) meanwhile is dropped. Any member passes on
    -- what they have taken in.
    local set = SyncableSet()
    local keep, covered = {}, 0
    for _, id in ipairs(batchQueue) do
        local item = db.items[id]
        if item and set[id] and not item.bodyParts then
            if SeenCovers(item) then
                covered = covered + 1
            else
                keep[#keep + 1] = id
            end
        end
    end
    batchQueue = keep
    if covered > 0 and #batchQueue > 0 then
        -- Someone else is answering: let them finish, then look again.
        batchScheduled = true
        C_Timer.After(6 + math.random() * 2, RunBatch)
        return
    end
    for _ = 1, math.min(BATCH, #batchQueue) do
        SendAnn(db.items[table.remove(batchQueue, 1)])
    end
    if #batchQueue > 0 then
        batchScheduled = true
        C_Timer.After(6 + math.random() * 2, RunBatch)
    end
end

-- Officers answer at once (after the exchange wait); members wait longer, so
-- they mostly hear an officer's answer first and stay quiet. The random part
-- spreads the members out, so the first one's answer reaches the others
-- before they send.
local function StartBatch()
    if batchScheduled then
        return
    end
    if DW.IsOfficer() then
        RunBatch()
    else
        batchScheduled = true
        C_Timer.After(MEMBER_WAIT + math.random() * MEMBER_SPREAD, RunBatch)
    end
end

local function RunExchange()
    exchangeScheduled = false
    if not DW.IsMember() then
        offers, wanted, batchQueue = {}, {}, {}
        return
    end
    local ids = SortedKeys(wanted)
    wanted = {}
    SendList("G", ids)

    local list = {}
    for id in pairs(offers) do
        if db.items[id] then
            list[#list + 1] = db.items[id]
        end
    end
    offers = {}
    -- The newest first.
    table.sort(list, function(a, b)
        if a.created ~= b.created then
            return a.created > b.created
        end
        return a.id > b.id
    end)
    local inQueue = {}
    for _, id in ipairs(batchQueue) do
        inQueue[id] = true
    end
    for _, item in ipairs(list) do
        if not inQueue[item.id] then
            batchQueue[#batchQueue + 1] = item.id
        end
    end
    if #batchQueue > 0 then
        StartBatch()
    end
end

local function ScheduleExchange()
    if exchangeScheduled then
        return
    end
    exchangeScheduled = true
    -- Random wait, so not everyone who is online answers at the same time (2.9 s in the tests).
    C_Timer.After(1.4 + math.random() * 3, RunExchange)
end

-- Our H list ("id,updated,h"): every record we keep, whatever the rank of its
-- officer. A newer held version counts as one we have (its content unknown: "-").
-- Records missing parts of the message are asked for instead.
local function HelloLists()
    local set = SyncableSet()
    local entries, broken = {}, {}
    for _, id in ipairs(SortedKeys(db.items)) do
        local item = db.items[id]
        if item.bodyParts then
            broken[#broken + 1] = id
        elseif set[id] then
            local heldVersion = held:Version(id)
            if heldVersion and heldVersion > item.updated then
                entries[#entries + 1] = table.concat({ id, Num(heldVersion), "-" }, ",")
            else
                entries[#entries + 1] = table.concat({ id, Num(item.updated), Digest(item) }, ",")
            end
        end
    end
    return entries, broken
end

-- For the tests.
DW.AnnouncementHelloEntries = function()
    return (HelloLists())
end

local SelfHealAll -- below, with the receiving

local function SayHello()
    PurgeExpired()
    SelfHealAll()
    local entries, broken = HelloLists()
    SendList("H", entries)
    Send("Q")
    SendList("G", broken)
    helloAt = GetTime()
    loginDue = helloAt + LOGIN_BANNER_DELAY
    loginToken = loginToken + 1
    local token = loginToken
    C_Timer.After(LOGIN_BANNER_DELAY, function()
        CheckLogin(token)
    end)
end

-- Receiving -------------------------------------------------------------------

-- Would this version replace the record we have?
local function Wins(item, updated, deleted, by)
    -- A deletion is final, both ways: it beats a live version whatever the
    -- times (an officer may edit without having seen the deletion yet).
    if deleted and not item.deleted then
        return true
    end
    if item.deleted and not deleted then
        return false
    end
    if updated ~= item.updated then
        return updated > item.updated
    end
    if deleted ~= (item.deleted == true) then
        return deleted
    end
    if by ~= item.by then
        return by > (item.by or "")
    end
    return false
end

-- Would ApplyAnn take this version (before any trust check)?
local function WouldApply(id, updated, pinned, deleted, by)
    if not FreshEnough(deleted, pinned, updated, CreatedOf(id), Now()) then
        return false
    end
    local item = db.items[id]
    if not item then
        return true
    end
    if Wins(item, updated, deleted, by) then
        return true
    end
    -- The same version is taken again only while parts of the message are missing.
    return item.bodyParts ~= nil and updated == item.updated and deleted == (item.deleted == true) and by == item.by
end

-- Takes in a version that has passed the trust rules. Returns true if something changed.
local function ApplyAnn(id, updated, pinned, deleted, round, parts, by, title)
    if not WouldApply(id, updated, pinned, deleted, by) then
        return false
    end
    local item = db.items[id]
    local same = item ~= nil and item.updated == updated and item.by == by and (item.deleted == true) == deleted
    if not item then
        item = { id = id }
        db.items[id] = item
    end
    item.author = AuthorOf(id)
    item.created = CreatedOf(id)
    item.updated = updated
    item.deleted = deleted or nil
    item.pinned = (pinned and not deleted) or nil
    item.round = round
    item.by = by
    item.title = deleted and "" or CleanTitle(title)
    item.body = ""
    if deleted or parts == 0 then
        item.bodyParts = nil
    elseif not (same and item.bodyParts and item.bodyParts.count == parts) then
        item.bodyParts = { count = parts }
    end
    held:Clear(id, updated)
    -- If the rest of the message does not arrive, we ask for it again.
    if item.bodyParts then
        C_Timer.After(PART_WAIT, function()
            if db.items[id] == item and item.bodyParts and item.updated == updated then
                wanted[id] = true
                ScheduleExchange()
            end
        end)
    end
    return true
end

-- Receives a piece of the message. Returns true when all of it has arrived.
local function ApplyPiece(id, updated, index, text)
    local item = db.items[id]
    local parts = item and item.bodyParts
    if not parts or item.updated ~= updated or not IsWhole(index) or index < 1 or index > parts.count or parts[index] then
        return false
    end
    parts[index] = Truncate(text, MAX_MESSAGE_BYTES)
    for part = 1, parts.count do
        if not parts[part] then
            return false
        end
    end
    item.body = CleanBody(Decode(table.concat(parts, "", 1, parts.count)))
    item.bodyParts = nil
    return true
end

-- Self-healing against fakes ----------------------------------------------------

local DeleteAnnouncement -- set in the actions below
local healed = {}        -- [id] = true: deleted as a fake this session (once is enough)
local healNoticeAt       -- GetTime() of the last chat line about it

-- Is this record a version in my name (this character) that was never made
-- on this account? Only versions after db.authored was started count: older
-- ones cannot be told apart, so they are left alone.
local function IsFakeOfMine(item)
    local me = MyKey()
    return item ~= nil and not item.deleted and me ~= nil and DW.SameCharacter(item.by, me)
        and type(db.authoredSince) == "number" and item.updated >= db.authoredSince
        and not Authored(item.id, item.updated)
end

-- Deletes an accepted version in my name that I never made, and says so in
-- chat. A deletion is final, so this cannot go back and forth; each record
-- is tried once per session.
local function SelfHeal(id)
    local item = db.items[id]
    if healed[id] or not IsFakeOfMine(item) or not DW.IsOfficer() then
        return false
    end
    healed[id] = true
    DeleteAnnouncement(item)
    if not (healNoticeAt and GetTime() - healNoticeAt < HEAL_NOTICE_EVERY) then
        healNoticeAt = GetTime()
        DW.Print(L.ANN_FAKE_REMOVED)
    end
    return true
end

-- Looks through what we have (at the hello): a fake may have come in while
-- another character on this account was logged in.
SelfHealAll = function()
    for _, id in ipairs(SortedKeys(db.items)) do
        SelfHeal(id)
    end
end

local bodySources = {} -- [id] = name key of who sent the version that waits for its pieces

local function OnMessage(text, sender)
    local fields = Split(text, SEP)
    local kind = fields[1]
    -- Runs this message again (when the officers change, for a held version).
    local function replay()
        OnMessage(text, sender)
    end

    if kind == "A" and #fields >= 8 then
        local id, updated, flags, round, parts, by = fields[2], tonumber(fields[3]), fields[4], tonumber(fields[5]), tonumber(fields[6]), fields[7]
        if not (AuthorOf(id) and #id <= MAX_RECEIVED_ID_BYTES and CreatedOf(id) <= Now() + FUTURE
            and IsWhole(updated) and updated > 0 and updated <= Now() + FUTURE
            and IsWhole(parts) and parts >= 0 and parts <= MAX_PARTS and IsWhole(round) and round >= 0 and round <= MAX_ROUND
            and by ~= "" and #by <= MAX_BY_BYTES and flags:match("^[pd%-]+$")) then
            return
        end
        local deleted = flags:find("d", 1, true) ~= nil
        local pinned = not deleted and flags:find("p", 1, true) ~= nil
        local h = DigestOf(pinned, deleted, by)
        -- Sent by someone the receivers will take it from (any guild member,
        -- for a version by an officer), so we do not need to send the same
        -- version: a pending answer of ours for it is dropped. This counts
        -- also when we have the version already.
        if DW.MayRelay(sender, by) == true then
            MarkSeen(id, updated, h)
        end
        if WouldApply(id, updated, pinned, deleted, by) then
            local result = DW.WhenRelayedAction("ann:" .. id .. ":" .. Num(updated), sender, by, nil, function(ok)
                if ok then
                    if ApplyAnn(id, updated, pinned, deleted, round, parts, by, fields[8]) then
                        if db.items[id].bodyParts then
                            -- Its pieces are taken from the one who sent this version.
                            bodySources[id] = DW.IdentityKey(sender)
                        end
                        if SelfHeal(id) then
                            -- Deleted again at once: nothing to show.
                        elseif not db.items[id].bodyParts then
                            AfterApply(id)
                        else
                            Changed()
                        end
                    end
                    MarkSeen(id, updated, h)
                elseif DW.TrustedVersion(by) ~= true then
                    -- Not held when only the sender was the trouble (not in the
                    -- roster): the version itself is fine, and a copy from
                    -- someone else must still be asked for.
                    held:Hold(id, updated, replay, sender)
                end
            end)
            if result == nil and DW.TrustedVersion(by) ~= true then
                held:Hold(id, updated, replay, sender)
            end
        end

    elseif kind == "T" and #fields >= 5 then
        local id, updated, index = fields[2], tonumber(fields[3]), tonumber(fields[4])
        local item = db.items[id]
        -- From the one who sent us this version, or from its officer or another
        -- officer (after a /reload, when we no longer know who sent it). Pieces
        -- dropped here are asked for again.
        if item and updated and index and item.bodyParts
            and ((bodySources[id] ~= nil and bodySources[id] == DW.IdentityKey(sender)) or DW.MayActFor(sender, item.by) == true)
            and ApplyPiece(id, updated, index, fields[5]) then
            bodySources[id] = nil
            AfterApply(id)
        end

    elseif kind == "H" then
        -- The list of what the sender has. Compare with our own.
        local listed = hello[sender]
        if not listed then
            listed = {}
            hello[sender] = listed
        end
        for index = 2, #fields do
            local id, theirUpdated, theirDigest = fields[index]:match("^(.+),(%d+),([%w%-]+)$")
            theirUpdated = tonumber(theirUpdated)
            if id and theirUpdated and #id <= MAX_RECEIVED_ID_BYTES then
                listed[id] = true
                local mine = db.items[id]
                -- The very version we hold (refused or undecided) counts as one we
                -- have. Only that one: a held version with a later time (perhaps junk)
                -- must not stop us asking for real versions before it. Who lists
                -- it does not matter: a version is held for what it is, not for
                -- who sent it, so anyone's copy would be held again.
                local heldHas = held:Version(id) == theirUpdated
                -- Their flags, from h ("-" when they do not know the content).
                local theirDeleted = theirDigest ~= "-" and theirDigest:sub(1, -3):find("d", 1, true) ~= nil
                if mine and mine.bodyParts then
                    wanted[id] = true
                elseif mine and mine.deleted and theirDigest ~= "-" and not theirDeleted then
                    -- A deletion is final: they still have it live, whatever the times.
                    Offer(id)
                elseif mine and not mine.deleted and theirDeleted then
                    if not heldHas then
                        wanted[id] = true
                    end
                elseif not mine or theirUpdated > mine.updated then
                    if not heldHas then
                        wanted[id] = true
                    end
                elseif theirUpdated < mine.updated then
                    Offer(id)
                elseif theirDigest ~= "-" and theirDigest ~= Digest(mine) then
                    -- The same time, other content: both versions meet, and the rule picks one.
                    Offer(id)
                    if not heldHas then
                        wanted[id] = true
                    end
                end
            end
        end

    elseif kind == "Q" then
        -- The list is complete. Everything we have that was not on it, the sender is missing.
        local listed = hello[sender] or {}
        hello[sender] = nil
        for id in pairs(SyncableSet()) do
            if not listed[id] and not db.items[id].bodyParts then
                Offer(id)
            end
        end

    elseif kind == "G" then
        -- Someone asks for specific announcements.
        local set = SyncableSet()
        for index = 2, #fields do
            local id = fields[index]
            if set[id] and not db.items[id].bodyParts then
                Offer(id)
            end
        end
    end

    if next(wanted) ~= nil or next(offers) ~= nil then
        ScheduleExchange()
    end
end

DW.OnGuildMessage(PREFIX, OnMessage)

-- Actions (officers only, checked at the click) --------------------------------

-- May this record be pinned now? (At most MAX_PINNED are shown pinned.)
local function PinRoom(item)
    local _, _, pinnedSet, pinnedList = State()
    if item and pinnedSet[item.id] then
        return true
    end
    return #pinnedList < MAX_PINNED
end

-- Returns the new record, or nil and an error text.
local function CreateAnnouncement(title, body, pinned)
    if not DW.IsOfficer() then
        return nil
    end
    local me = MyKey()
    if not me then
        return nil
    end
    local now = Now()
    local id = ("%s:%d:%d"):format(me, now, (db.seq or 0) + 1)
    if #id > MAX_ID_BYTES then
        return nil, L.ANN_ID_TOO_LONG
    end
    if pinned and not PinRoom(nil) then
        return nil, L.ANN_TOO_MANY_PINNED:format(MAX_PINNED)
    end
    db.seq = (db.seq or 0) + 1
    local item = {
        id = id, author = me, created = now, updated = now,
        title = CleanTitle(title), body = CleanBody(body), pinned = pinned or nil,
        round = 1, by = me,
    }
    db.items[id] = item
    db.bannered[id] = 1 -- no banner for the one who wrote it
    NoteAuthored(id, now)
    SendAnn(item)
    Changed()
    return item
end

-- Any officer can edit any announcement. rebanner: show it as a banner to everyone again.
local function EditAnnouncement(item, title, body, pinned, rebanner)
    if not DW.IsOfficer() or item.deleted then
        return nil
    end
    if item.bodyParts then
        return nil, L.ANN_BODY_COMING
    end
    -- Room is checked for every record that is not shown pinned now (one flagged
    -- pinned beyond the newest MAX_PINNED shows as unpinned).
    if pinned and not PinRoom(item) then
        return nil, L.ANN_TOO_MANY_PINNED:format(MAX_PINNED)
    end
    local me = MyKey()
    if not me then
        return nil
    end
    item.title = CleanTitle(title)
    item.body = CleanBody(body)
    item.pinned = pinned or nil
    item.updated = math.max(Now(), item.updated + 1)
    item.by = me
    if rebanner then
        item.round = math.min(MAX_ROUND, (item.round or 1) + 1)
    end
    db.bannered[item.id] = math.max(tonumber(db.bannered[item.id]) or 0, item.round or 1)
    NoteAuthored(item.id, item.updated)
    SendAnn(item)
    Changed()
    return item
end

-- Goes by what the window shows: a record shown unpinned is pinned by the click.
local function TogglePin(item)
    local _, _, pinnedSet = State()
    local shownPinned = pinnedSet[item.id] == true
    if not shownPinned and not PinRoom(item) then
        DW.Print(L.ANN_TOO_MANY_PINNED:format(MAX_PINNED))
        return nil
    end
    local result, problem = EditAnnouncement(item, item.title, item.body, not shownPinned, false)
    if not result and problem then
        DW.Print(problem)
    end
    return result
end

DeleteAnnouncement = function(item)
    local me = MyKey()
    if not DW.IsOfficer() or not me or item.deleted then
        return
    end
    item.deleted = true
    item.pinned = nil
    item.title, item.body = "", ""
    item.bodyParts = nil
    item.by = me
    item.updated = math.max(Now(), item.updated + 1)
    NoteAuthored(item.id, item.updated)
    SendAnn(item)
    Changed()
end

local function ShareAnnouncement(item)
    if not DW.IsOfficer() or item.deleted then
        return
    end
    local body = (item.body or ""):gsub("\n", " ")
    local text = Truncate(L.ANN_CHAT:format(item.title or "", body), MAX_MESSAGE_BYTES)
    if not DW.SendChat(text, "GUILD") then
        DW.Print(L.GC_BLOCKED)
    end
end

-- Exports -------------------------------------------------------------------------

-- The announcements shown: shown-pinned first, then the newest change first.
-- Copies: { id, title, body, author, created, updated, pinned (shown pinned), by }.
function DW.Announcements()
    local _, shown, pinnedSet = State()
    local list = {}
    for index, item in ipairs(Ordered(shown, pinnedSet)) do
        list[index] = Copy(item, pinnedSet)
    end
    return list
end

-- The ones shown pinned, newest change first.
function DW.PinnedAnnouncements()
    local _, _, pinnedSet, pinnedList = State()
    local list = {}
    for index, item in ipairs(pinnedList) do
        list[index] = Copy(item, pinnedSet)
    end
    return list
end

-- For the tests: start the hello and the login banners again, as after a new login.
function DW.RestartAnnouncementHello()
    loginDone = false
    helloAt, loginDue = nil, nil
    loginToken = loginToken + 1
    if DW.IsMember() and C_Timer and C_Timer.After then
        C_Timer.After(HELLO_DELAY, function()
            if DW.IsMember() then
                SayHello()
            end
        end)
    end
end

-- The window -----------------------------------------------------------------------

local LIST_WIDTH = 250
local ROW_HEIGHT = 42
local DETAIL_X = 294
local DETAIL_WIDTH = 504

local overlay
local rows = {}
local selectedID
local formOpen, formEditID = false, nil
local RefreshOverlay

local function GetRow(index)
    local row = rows[index]
    if row then
        return row
    end
    row = DW.CreateChip(overlay.content, LIST_WIDTH, ROW_HEIGHT - 4)
    row:SetPoint("TOPLEFT", 0, -(index - 1) * ROW_HEIGHT)
    row.label:ClearAllPoints()
    row.label:SetPoint("TOPLEFT", 10, -6)
    row.label:SetPoint("TOPRIGHT", -10, -6)

    row.sub = row:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    row.sub:SetTextColor(0.65, 0.65, 0.65)
    row.sub:SetPoint("BOTTOMLEFT", 10, 6)
    row.sub:SetPoint("BOTTOMRIGHT", -10, 6)
    row.sub:SetJustifyH("LEFT")
    row.sub:SetWordWrap(false)

    row:SetScript("OnClick", function(self)
        selectedID = self.id
        formOpen, formEditID = false, nil
        RefreshOverlay()
    end)
    rows[index] = row
    return row
end

-- The Guild Master's menu: which ranks count as officers.
local function OpenLimitMenu(owner)
    if not DW.IsGuildMaster() then
        return
    end
    local top = math.min(9, DW.NumRanks() - 2)
    if top < 0 then
        return
    end
    if not (MenuUtil and MenuUtil.CreateContextMenu) then
        -- Without a menu: the next limit on each click.
        local nextLimit = DW.OfficerLimit() + 1
        if nextLimit > top then
            nextLimit = 0
        end
        DW.SetOfficerLimit(nextLimit)
        RefreshOverlay()
        return
    end
    MenuUtil.CreateContextMenu(owner, function(_, root)
        root:CreateTitle(L.OFF_MENU_TITLE)
        for rank = 0, top do
            root:CreateRadio(DW.RankName(rank), function(data)
                return DW.OfficerLimit() == data
            end, function(data)
                DW.SetOfficerLimit(data)
                RefreshOverlay()
            end, rank)
        end
    end)
end

local function ShowLimitTooltip(owner)
    GameTooltip:SetOwner(owner, "ANCHOR_BOTTOMLEFT")
    GameTooltip:AddLine(L.OFF_TIP_TITLE)
    GameTooltip:AddLine(L.OFF_TIP_TEXT, 1, 1, 1, true)
    local officers = DW.Officers()
    if #officers == 0 then
        GameTooltip:AddLine(L.OFF_TIP_NONE, 0.7, 0.7, 0.7, true)
    end
    for _, officer in ipairs(officers) do
        if officer.online then
            GameTooltip:AddLine(DW.OfficerBadge(officer) .. officer.name, 0.40, 0.90, 0.40)
        else
            GameTooltip:AddLine(DW.OfficerBadge(officer) .. officer.name, 0.75, 0.75, 0.75)
        end
    end
    if DW.IsGuildMaster() then
        GameTooltip:AddLine(L.OFF_TIP_GM, 1.00, 0.82, 0.00, true)
    end
    GameTooltip:Show()
end

local function OpenForm(editItem)
    local form = overlay.form
    formOpen = true
    formEditID = editItem and editItem.id or nil
    form.titleBox:SetText(editItem and editItem.title or "")
    form.bodyBox:SetText(editItem and editItem.body or "")
    -- Ticked for a new one, and for a record the window shows as pinned.
    local _, _, pinnedSet = State()
    form.pinCheck:SetChecked(editItem == nil or pinnedSet[editItem.id] == true)
    form.bannerCheck:SetChecked(false)
    form.error:SetText("")
end

local function SubmitForm()
    local form = overlay.form
    local title = CleanTitle(form.titleBox:GetText())
    if title == "" then
        form.error:SetText(L.ANN_NEED_TITLE)
        return
    end
    local pinned = form.pinCheck:GetChecked() and true or false
    local item, problem
    if formEditID then
        local existing = db.items[formEditID]
        if existing then
            item, problem = EditAnnouncement(existing, title, form.bodyBox:GetText(), pinned, form.bannerCheck:GetChecked() and true or false)
        end
    else
        item, problem = CreateAnnouncement(title, form.bodyBox:GetText(), pinned)
    end
    if not item then
        form.error:SetText(problem or "")
        RefreshOverlay()
        return
    end
    form.titleBox:SetText("")
    form.bodyBox:SetText("")
    form.error:SetText("")
    formOpen, formEditID = false, nil
    selectedID = item.id
    RefreshOverlay()
end

local function RefreshForm()
    local form = overlay.form
    form.heading:SetText(formEditID and L.ANN_FORM_EDIT or L.ANN_NEW)
    form.titleLabel:SetText(L.ANN_FORM_TITLE)
    form.bodyLabel:SetText(L.ANN_FORM_BODY)
    form.pinCheck.label:SetText(L.ANN_FORM_PIN)
    form.bannerCheck.label:SetText(L.ANN_FORM_BANNER)
    form.bannerCheck:SetShown(formEditID ~= nil)
    form.bannerCheck.label:SetShown(formEditID ~= nil)
    form.send.label:SetText(L.ANN_SEND)
    form.cancel.label:SetText(L.SUG_CANCEL)
end

local function RefreshDetail(item, pinnedSet, officer)
    local d = overlay.detail
    d.item = item
    d.title:SetText(item.title ~= "" and item.title or "?")
    local meta = L.ANN_META:format(DW.OfficerBadge(item.author) .. ShortName(item.author), date("%d.%m.%Y %H:%M", item.created))
    if pinnedSet[item.id] then
        meta = meta .. "  -  " .. L.ANN_PINNED
    end
    d.meta:SetText(meta)
    local changedBy = not DW.SameCharacter(item.by, item.author)
    if changedBy then
        d.changed:SetText(L.ANN_CHANGED_BY:format(ShortName(item.by)))
    end
    d.changed:SetShown(changedBy)

    d.body:SetText(item.bodyParts and L.ANN_BODY_COMING or item.body)
    d.bodyScroll:ClearAllPoints()
    d.bodyScroll:SetPoint("TOPLEFT", changedBy and d.changed or d.meta, "BOTTOMLEFT", 0, -12)
    d.bodyScroll:SetPoint("BOTTOMRIGHT", d, "BOTTOMRIGHT", -24, officer and 34 or 0)
    d.bodyContent:SetHeight(math.max(1, math.ceil(d.body:GetStringHeight())))

    local complete = item.bodyParts == nil
    d.edit.label:SetText(L.ANN_EDIT)
    d.pin.label:SetText(pinnedSet[item.id] and L.ANN_UNPIN or L.ANN_PIN)
    d.share.label:SetText(L.ANN_SHARE)
    d.delete.label:SetText(L.SUG_DELETE)
    d.edit:SetEnabled(complete)
    d.edit:SetDimmed(not complete)
    d.pin:SetActive(complete)
    for _, button in ipairs({ d.edit, d.pin, d.share, d.delete }) do
        button:SetShown(officer)
    end
end

local function RefreshChip()
    overlay.officers.label:SetText(L.OFF_CHIP:format(DW.RankName(DW.OfficerLimit())))
end

RefreshOverlay = function()
    if not overlay or not overlay:IsVisible() then
        return
    end
    local _, shown, pinnedSet = State()
    local list = Ordered(shown, pinnedSet)
    local officer = DW.IsOfficer()
    if not officer then
        formOpen, formEditID = false, nil
    end

    overlay.title:SetText(L.ANN_TITLE)
    RefreshChip()
    overlay.newButton.label:SetText(L.ANN_NEW)
    overlay.newButton:SetShown(officer)

    local selected
    for index, item in ipairs(list) do
        local row = GetRow(index)
        row.id = item.id
        row.label:SetText((pinnedSet[item.id] and ("|cffffd100" .. L.ANN_PIN_MARK .. "|r ") or "") .. (item.title ~= "" and item.title or "?"))
        row.sub:SetText(("%s  -  %s"):format(ShortName(item.author), date("%d.%m.%Y", item.created)))
        row:SetSelected(item.id == selectedID and not formOpen)
        row:Show()
        if item.id == selectedID then
            selected = item
        end
    end
    for index = #list + 1, #rows do
        rows[index]:Hide()
    end
    overlay.content:SetHeight(math.max(1, #list * ROW_HEIGHT))

    overlay.form:SetShown(formOpen)
    overlay.detail:SetShown(not formOpen and selected ~= nil)
    overlay.empty:SetShown(not formOpen and selected == nil)
    if formOpen then
        RefreshForm()
    elseif selected then
        RefreshDetail(selected, pinnedSet, officer)
    elseif #list == 0 then
        overlay.empty:SetText(officer and L.ANN_EMPTY or L.ANN_EMPTY_MEMBER)
    else
        overlay.empty:SetText(L.ANN_PICK)
    end
end

QueueRefresh = function()
    if not overlay or not overlay:IsVisible() or overlay.refreshQueued then
        return
    end
    overlay.refreshQueued = true
    C_Timer.After(0.2, function()
        overlay.refreshQueued = false
        RefreshOverlay()
    end)
end

local function CreateEditBox(parent, width, maxLetters)
    local box = CreateFrame("EditBox", nil, parent, "InputBoxTemplate")
    box:SetSize(width, 22)
    box:SetAutoFocus(false)
    box:SetMaxLetters(maxLetters)
    box:SetScript("OnEscapePressed", function(self)
        self:ClearFocus()
    end)
    box:SetScript("OnEnterPressed", function(self)
        self:ClearFocus()
    end)
    return box
end

local function CreateCheck(parent, y)
    local check = CreateFrame("CheckButton", nil, parent, "UICheckButtonTemplate")
    check:SetSize(24, 24)
    check:SetPoint("TOPLEFT", 0, y)
    check.label = parent:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
    check.label:SetPoint("LEFT", check, "RIGHT", 4, 0)
    check.label:SetJustifyH("LEFT")
    return check
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
    f:SetFrameLevel(window:GetFrameLevel() + 50)
    f:EnableMouse(true)
    f:SetBackdrop(DW.PANEL_BACKDROP)
    f:SetBackdropColor(0.05, 0.05, 0.07, 1)
    f:SetBackdropBorderColor(0.90, 0.72, 0.30, 1)
    overlay = f
    DW.RegisterOverlay(OVERLAY_NAME)

    f.close = CreateFrame("Button", nil, f, "UIPanelCloseButton")
    f.close:SetPoint("TOPRIGHT", -2, -2)
    f.close:SetScript("OnClick", function()
        f:Hide()
    end)

    f.title = f:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
    f.title:SetPoint("TOP", 0, -12)

    -- Who counts as an officer; the Guild Master can change it here.
    f.officers = DW.CreateChip(f, 240, 22)
    f.officers:SetPoint("TOPRIGHT", -34, -10)
    f.officers.label:SetJustifyH("CENTER")
    f.officers:SetScript("OnClick", function(self)
        GameTooltip:Hide()
        OpenLimitMenu(self)
    end)
    f.officers:HookScript("OnEnter", function(self)
        ShowLimitTooltip(self)
    end)
    f.officers:HookScript("OnLeave", function()
        GameTooltip:Hide()
    end)

    -- The list on the left.
    local scroll = CreateFrame("ScrollFrame", "DragonworldAnnScroll", f, "ScrollFrameTemplate")
    scroll:SetPoint("TOPLEFT", 10, -44)
    scroll:SetSize(LIST_WIDTH, 330)
    f.content = CreateFrame("Frame", nil, scroll)
    f.content:SetSize(LIST_WIDTH, 1)
    scroll:SetScrollChild(f.content)

    f.newButton = DW.CreateButton(f, LIST_WIDTH, 30, "gold")
    f.newButton:SetPoint("BOTTOMLEFT", 10, 12)
    f.newButton:SetScript("OnClick", function()
        if DW.IsOfficer() then
            OpenForm(nil)
        end
        RefreshOverlay()
    end)

    f.empty = f:CreateFontString(nil, "OVERLAY", "GameFontDisable")
    f.empty:SetPoint("TOPLEFT", DETAIL_X, -60)
    f.empty:SetWidth(500)
    f.empty:SetJustifyH("LEFT")

    -- The selected announcement.
    local d = CreateFrame("Frame", nil, f)
    d:SetPoint("TOPLEFT", DETAIL_X, -44)
    d:SetSize(DETAIL_WIDTH, 378)
    f.detail = d

    d.title = d:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
    d.title:SetPoint("TOPLEFT", 0, -2)
    d.title:SetWidth(DETAIL_WIDTH)
    d.title:SetJustifyH("LEFT")

    d.meta = d:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    d.meta:SetPoint("TOPLEFT", d.title, "BOTTOMLEFT", 0, -6)
    d.meta:SetWidth(DETAIL_WIDTH)
    d.meta:SetJustifyH("LEFT")

    d.changed = d:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    d.changed:SetPoint("TOPLEFT", d.meta, "BOTTOMLEFT", 0, -4)
    d.changed:SetWidth(DETAIL_WIDTH)
    d.changed:SetJustifyH("LEFT")
    d.changed:SetTextColor(0.65, 0.65, 0.65)

    -- The message scrolls when it does not fit above the buttons.
    d.bodyScroll = CreateFrame("ScrollFrame", "DragonworldAnnBodyScroll", d, "ScrollFrameTemplate")
    d.bodyContent = CreateFrame("Frame", nil, d.bodyScroll)
    d.bodyContent:SetSize(DETAIL_WIDTH - 26, 1)
    d.bodyScroll:SetScrollChild(d.bodyContent)
    d.body = d.bodyContent:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
    d.body:SetPoint("TOPLEFT", 0, 0)
    d.body:SetWidth(DETAIL_WIDTH - 26)
    d.body:SetJustifyH("LEFT")
    if d.body.SetSpacing then
        d.body:SetSpacing(2)
    end

    -- Officer tools in the bottom row.
    local function Selected()
        local item = d.item and db.items[d.item.id]
        if item and not item.deleted and DW.IsOfficer() then
            return item
        end
        return nil
    end
    d.edit = DW.CreateChip(d, 100, 26)
    d.edit:SetPoint("BOTTOMLEFT", 0, 0)
    d.edit.label:SetJustifyH("CENTER")
    d.edit:SetScript("OnClick", function()
        local item = Selected()
        if item and not item.bodyParts then
            OpenForm(item)
            RefreshOverlay()
        end
    end)
    d.pin = DW.CreateButton(d, 120, 26, "gold")
    d.pin:SetPoint("BOTTOMLEFT", 106, 0)
    d.pin:SetScript("OnClick", function()
        local item = Selected()
        if item and not item.bodyParts then
            TogglePin(item)
            RefreshOverlay()
        end
    end)
    d.share = DW.CreateChip(d, 150, 26)
    d.share:SetPoint("BOTTOMLEFT", 232, 0)
    d.share.label:SetJustifyH("CENTER")
    d.share:SetScript("OnClick", function()
        local item = Selected()
        if item then
            ShareAnnouncement(item)
        end
    end)
    -- No question first, as elsewhere in the addon.
    d.delete = DW.CreateButton(d, 100, 26, "red")
    d.delete:SetPoint("BOTTOMRIGHT", 0, 0)
    d.delete:SetScript("OnClick", function()
        local item = Selected()
        if item then
            DeleteAnnouncement(item)
            selectedID = nil
            RefreshOverlay()
        end
    end)

    -- The form for a new announcement, or for editing one.
    local form = CreateFrame("Frame", nil, f)
    form:SetPoint("TOPLEFT", DETAIL_X, -44)
    form:SetSize(DETAIL_WIDTH, 378)
    f.form = form

    form.heading = form:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
    form.heading:SetPoint("TOPLEFT", 0, -2)

    form.titleLabel = form:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    form.titleLabel:SetPoint("TOPLEFT", 0, -30)
    form.titleBox = CreateEditBox(form, DETAIL_WIDTH - 8, MAX_TITLE_LETTERS)
    form.titleBox:SetPoint("TOPLEFT", 6, -46)

    form.bodyLabel = form:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    form.bodyLabel:SetPoint("TOPLEFT", 0, -76)

    -- The message spans several lines, in a frame of its own.
    local holder = CreateFrame("Frame", nil, form, "BackdropTemplate")
    holder:SetPoint("TOPLEFT", 0, -92)
    holder:SetSize(DETAIL_WIDTH, 180)
    holder:SetBackdrop(DW.PANEL_BACKDROP)
    holder:SetBackdropColor(0, 0, 0, 0.6)
    holder:SetBackdropBorderColor(0.45, 0.45, 0.45, 1)
    -- A multi-line box grows with its text, so it sits in a scroll frame and
    -- cannot grow over the boxes below.
    form.bodyScroll = CreateFrame("ScrollFrame", "DragonworldAnnFormScroll", holder, "ScrollFrameTemplate")
    form.bodyScroll:SetPoint("TOPLEFT", 8, -6)
    form.bodyScroll:SetPoint("BOTTOMRIGHT", -28, 6)
    form.bodyBox = CreateFrame("EditBox", nil, form.bodyScroll)
    form.bodyBox:SetMultiLine(true)
    form.bodyBox:SetFontObject(ChatFontNormal or "ChatFontNormal")
    form.bodyBox:SetSize(DETAIL_WIDTH - 36, 168)
    form.bodyBox:SetAutoFocus(false)
    form.bodyBox:SetMaxLetters(MAX_BODY_LETTERS)
    form.bodyScroll:SetScrollChild(form.bodyBox)
    form.bodyBox:SetScript("OnEscapePressed", function(self)
        self:ClearFocus()
    end)
    -- Keeps the line being written in view.
    form.bodyBox:SetScript("OnCursorChanged", function(_, _, y, _, height)
        local scroll = form.bodyScroll
        if not (scroll.GetVerticalScroll and scroll.SetVerticalScroll and type(y) == "number") then
            return
        end
        if scroll.UpdateScrollChildRect then
            scroll:UpdateScrollChildRect()
        end
        local top, view, offset = -y, scroll:GetHeight(), scroll:GetVerticalScroll()
        height = height or 0
        if top < offset then
            scroll:SetVerticalScroll(math.max(0, top))
        elseif top + height > offset + view then
            scroll:SetVerticalScroll(math.max(0, top + height - view))
        end
    end)
    holder:EnableMouse(true)
    holder:SetScript("OnMouseDown", function()
        form.bodyBox:SetFocus()
    end)

    form.pinCheck = CreateCheck(form, -280)
    form.bannerCheck = CreateCheck(form, -306)

    form.error = form:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    form.error:SetTextColor(1.00, 0.35, 0.30)
    form.error:SetPoint("TOPLEFT", 0, -334)
    form.error:SetWidth(DETAIL_WIDTH)
    form.error:SetJustifyH("LEFT")

    form.send = DW.CreateButton(form, 150, 28, "gold")
    form.send:SetPoint("BOTTOMLEFT", 0, 0)
    form.send:SetScript("OnClick", SubmitForm)

    form.cancel = DW.CreateChip(form, 120, 28)
    form.cancel:SetPoint("BOTTOMRIGHT", 0, 0)
    form.cancel.label:SetJustifyH("CENTER")
    form.cancel:SetScript("OnClick", function()
        formOpen, formEditID = false, nil
        RefreshOverlay()
    end)

    f:SetScript("OnShow", function()
        RefreshOverlay()
    end)
    f:Hide()
    return f
end

-- Opens the announcements window over the main window. id: the one to show;
-- openForm: start a new one (officers).
function DW.ShowAnnouncements(id, openForm)
    if not DW.IsMember() then
        DW.Guard()
        return
    end
    -- Laid out for the full window: the compact view becomes it first.
    DW.ExpandWindow()
    if not DW.IsMainWindowShown() and DW.ToggleMainWindow then
        DW.ToggleMainWindow()
    end
    -- The language choice, the intro or the role question comes first.
    if not (DW.IsMainBodyShown and DW.IsMainBodyShown()) then
        return
    end
    if not overlay and not CreateOverlay() then
        return
    end
    DW.HideOverlays(OVERLAY_NAME)
    if id then
        selectedID = id
    else
        local _, shown, pinnedSet = State()
        local list = Ordered(shown, pinnedSet)
        local keep = false
        for _, item in ipairs(list) do
            if item.id == selectedID then
                keep = true
            end
        end
        if not keep then
            selectedID = list[1] and list[1].id or nil
        end
    end
    if openForm and DW.IsOfficer() then
        OpenForm(nil)
    else
        formOpen, formEditID = false, nil
    end
    overlay:Show()
    RefreshOverlay()
end

-- Events ----------------------------------------------------------------------

local helloSent = false

-- Once per session, a little after login: tell what we have.
local function PlanHello()
    if helloSent or not (C_Timer and C_Timer.After) then
        return
    end
    C_Timer.After(HELLO_DELAY, function()
        if not helloSent and DW.IsMember() then
            helloSent = true
            SayHello()
        end
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

DW.OnLanguageChanged(function()
    RefreshOverlay()
end)

-- Promoted, demoted or a new officer limit: try held versions again, and
-- show or hide what depends on rank.
DW.OnOfficersChanged(function()
    held:ReplayAll()
    Changed()
end)

DW.AddDebug(MODULE_ID, function(add)
    local set, shown, _, pinnedList = State()
    local stored, syncable, broken = 0, 0, 0
    for id, item in pairs(db.items) do
        stored = stored + 1
        if set[id] then
            syncable = syncable + 1
        end
        if item.bodyParts then
            broken = broken + 1
        end
    end
    add(("lagret: %d | delbare: %d | vises: %d | festet: %d | mangler deler: %d | holdt: %d"):format(
        stored, syncable, #shown, #pinnedList, broken, held:Count()))
    add("hilsen: " .. DW.DebugText(helloAt) .. " | bannere ved innlogging valgt: " .. (loginDone and "ja" or "nei")
        .. " | i sendekø: " .. #batchQueue)
end)

-- Module -------------------------------------------------------------------------

DW.RegisterModule({
    id = MODULE_ID,
    titleKey = "ANN_TITLE",
    notesKey = "ANN_NOTES",
    icon = "Interface\\Icons\\INV_Misc_Note_02",

    OnLoad = function(self, saved)
        if type(saved.items) ~= "table" then
            saved.items = {}
        end
        if type(saved.bannered) ~= "table" then
            saved.bannered = {}
        end
        if type(saved.authored) ~= "table" then
            saved.authored = {}
        end
        if type(saved.authoredSince) ~= "number" then
            -- Started now: versions in my name from before cannot be judged.
            saved.authoredSince = Now()
        end
        -- Clean out anything that does not look right (e.g. from a corrupted file).
        for id, item in pairs(saved.items) do
            if type(id) ~= "string" or type(item) ~= "table" or type(item.updated) ~= "number" or type(item.created) ~= "number" then
                saved.items[id] = nil
            else
                item.id = id
                item.author = type(item.author) == "string" and item.author or (AuthorOf(id) or "?")
                item.title = type(item.title) == "string" and item.title or ""
                item.body = type(item.body) == "string" and item.body or ""
                item.by = type(item.by) == "string" and item.by or item.author
                item.round = tonumber(item.round) or 1
                if type(item.bodyParts) ~= "table" or type(item.bodyParts.count) ~= "number" then
                    item.bodyParts = nil
                end
            end
        end
        db = saved
        held = DW.NewHeldStore(saved, MODULE_ID)
        PurgeExpired()
    end,

    -- "/dw kunngjoringer" opens the window. No tab of its own.
    OnSlash = function(self)
        DW.ShowAnnouncements()
    end,
})

-- The Home page (Modules\Home.lua): the pinned announcements, and the ones
-- written or changed since you last played (not your own).
DW.RegisterHomeSection({
    id = "ann",
    order = 10,
    titleKey = "HOME_SEC_ANN",
    icon = "Interface\\Icons\\INV_Misc_Note_02",
    Lines = function(ctx)
        local lines, me = {}, MyKey()
        for _, item in ipairs(DW.Announcements()) do
            local fresh = ctx.since ~= nil and item.updated > ctx.since and not DW.SameCharacter(item.by, me)
            local id = item.id
            local text
            if item.pinned then
                text = L.HOME_ANN_PINNED:format(item.title)
            elseif fresh then
                text = L.HOME_ANN_NEW:format(item.title, ShortName(item.author))
            end
            if text then
                lines[#lines + 1] = {
                    text = text, when = item.updated, changed = fresh, tab = MODULE_ID,
                    onClick = function()
                        DW.ShowAnnouncements(id)
                    end,
                }
            end
        end
        return lines
    end,
})

-- The Home page follows changes as they arrive.
if DW.RefreshHome then
    DW.OnAnnouncementsChanged(DW.RefreshHome)
end
