-- Dragonworld - Forslag
-- A place where everyone in the guild can suggest new things for the addon, or
-- improvements to what exists, and agree with other people's suggestions.
--
-- This is how the suggestions are shared (same way as guild events):
--   * Small messages on the guild channel that only other addons see.
--   * Each suggestion and each "enig" (agree) has a timestamp from the
--     server's clock. If two versions of the same thing arrive, the newest wins.
--   * When you log in, the addon sends a short list of the suggestions you have.
--     Those who are online send what you are missing, and ask for what they miss.
--   * The description can be longer than one message allows, and is then sent in pieces.
--
-- Only the one who wrote a suggestion can delete it: the button is only shown
-- to them, and a deletion is only accepted when it comes directly from the
-- one who wrote the suggestion (not forwarded by others; it spreads when the
-- author is online). A deletion is final: a later version that is not
-- deleted is ignored. A deleted suggestion is remembered for a month, and
-- then forgotten. (A test build once added a 9th field to deleted F
-- messages; it is ignored.)
--
-- Admin (Admin.lua, login with a code; only the guild leader has it) can mark
-- a suggestion as done or rejected. It is then moved to the archive, with
-- status, who and when; admin can also reopen it. The status has its own
-- timestamp, and the newest wins. Officer ranks give no rights here. The
-- others in the guild cannot check that the sender really is admin.
--
-- There is no real access control for suggestions: everyone in the guild can
-- in principle send anything.
--
-- The messages (name DragonworldSug, fields separated by tab):
--   F id changed deleted type module parts title      a suggestion
--   N id changed no text                              a piece of the description
--   B id player,agree,time ...                        who agrees
--   S id status time who                              status: D done, R rejected, O open again
--   H id,changed,count,newest ...   and then   Q      what I have ("newest" includes the status)
--   G id ...                                          send me these
--
-- The tab also holds the guild's polls (the "Polls" chip at the top). They
-- are described and shared in the "Polls" part below, on their own message
-- name (DragonworldPoll).
--
-- All text is in Locales.lua (the names that start with SUG_ and POLL_).

local ADDON_NAME, DW = ...
local L = DW.L

local MODULE_ID = "forslag"
local PREFIX = "DragonworldSug" -- the name of the messages; max 16 characters
local SEP = "\t"

local DAY = 86400
local KEEP_DELETED = 30 * DAY
local MAX_TITLE_LETTERS = 60
local MAX_TITLE_BYTES = 120
local MAX_NOTE_LETTERS = 300
local MAX_NOTE_BYTES = 600
local NOTE_CHUNK_BYTES = 180
local MAX_PARTS = 5
local MAX_MESSAGE_BYTES = 250 -- the game's limit is 255
local HELLO_DELAY = 12        -- after login
local NOTE_WAIT = 20          -- how long we wait for the rest of a description

local NEW, IMPROVE = "N", "I" -- the types: new thing, improvement of something that exists
local DONE, REJECTED, OPEN = "D", "R", "O" -- the statuses admin can set

-- Saved data. Set in OnLoad at the bottom.
--   db.items[id] = {
--       id, author ("Name-Realm"), kind = "N" or "I",
--       module = the id of the module the suggestion is about, or "" for the whole addon,
--       title, note,
--       updated  = when it was last changed (newest version wins),
--       deleted  = true if it is deleted,
--       votes    = { ["Name-Realm"] = { v = 1 (agree) or 0 (withdrawn), updated } },
--       noteParts = the pieces of the description while they are on their way,
--       status   = "D" (done), "R" (rejected) or "O"/nil (open),
--       statusAt = when the status was last set, statusBy = the name of the admin,
--   }
--   db.seq = counter that makes each id unique
local db = { items = {}, polls = {}, pollBannered = {}, pollAuthored = {} }

-- Small things ------------------------------------------------------------------

local function Now()
    local now = GetServerTime and GetServerTime()
    if type(now) == "number" and not DW.IsSecret(now) then
        return now
    end
    return time()
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

-- Cuts a text to a number of bytes without splitting a character in the middle.
local function Truncate(text, maxBytes)
    local out = ""
    for char in text:gmatch("[%z\1-\127\194-\244][\128-\191]*") do
        if #out + #char > maxBytes then
            break
        end
        out = out .. char
    end
    return out
end

-- Cleans text: removes line breaks, tabs and the character | (which the game
-- uses for colors and links), and cuts the length.
local function Clean(text, maxBytes)
    text = tostring(text or "")
    text = text:gsub("[%c|]", " ")
    text = text:gsub("^%s+", "")
    text = text:gsub("%s+$", "")
    return Truncate(text, maxBytes)
end

-- Splits a text into pieces of at most maxBytes, without splitting a character.
local function Chunks(text, maxBytes)
    local list, current = {}, ""
    for char in text:gmatch("[%z\1-\127\194-\244][\128-\191]*") do
        if #current + #char > maxBytes then
            list[#list + 1] = current
            current = ""
        end
        current = current .. char
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

-- An id looks like this: "Name-Realm:time:counter". The one who wrote the
-- suggestion comes first, and the time is when it was written.
local function AuthorOf(id)
    return id:match("^(.+):%d+:%d+$")
end

local function CreatedOf(id)
    return tonumber(id:match(":(%d+):%d+$")) or 0
end

-- Should the suggestion still be remembered and shared?
local function Syncable(item)
    return not item.stub and (not item.deleted or item.updated > Now() - KEEP_DELETED)
end

-- The number of "enig" (agree) entries and the timestamp of the newest of
-- them and of the status. Used to detect that two members have different
-- votes or a different status on the same suggestion. (The status is included
-- in "newest", so older versions of the addon, which do not know it,
-- read the list the same way.)
local function Digest(item)
    local count, newest = 0, tonumber(item.statusAt) or 0
    for _, vote in pairs(item.votes) do
        count = count + 1
        if vote.updated > newest then
            newest = vote.updated
        end
    end
    return count, newest
end

-- Is the suggestion fully handled (in the archive)?
local function IsArchived(item)
    return item.status == DONE or item.status == REJECTED
end

-- How many agree, and who (sorted).
local function Agreeing(item)
    local names = {}
    for player, vote in pairs(item.votes) do
        if vote.v == 1 then
            names[#names + 1] = ShortName(player)
        end
    end
    table.sort(names)
    return #names, names
end

local function PurgeExpired()
    for id, item in pairs(db.items) do
        if type(item) ~= "table" or type(item.votes) ~= "table" or not Syncable(item) then
            db.items[id] = nil
        end
    end
end

-- The name of the module a suggestion is about, in the chosen language.
local function ModuleName(id)
    if id == nil or id == "" then
        return L.SUG_WHOLE_ADDON
    end
    local module = DW.modules[id]
    return module and DW.ModuleTitle(module) or id
end

local function KindText(item)
    if item.kind == IMPROVE then
        return L.SUG_KIND_IMPROVE_OF:format(ModuleName(item.module))
    end
    return L.SUG_KIND_NEW
end

-- Sending -----------------------------------------------------------------------

local Send = DW.CreateSender(PREFIX)

-- Versions we have seen sent (by us or others) since someone last asked for them.
-- Used to avoid sending what someone else has already sent.
local seen = { items = {}, votes = {}, status = {} }

local function MarkSeenItem(id, updated)
    if updated > (seen.items[id] or -1) then
        seen.items[id] = updated
    end
end

local function MarkSeenStatus(id, statusAt)
    if statusAt > (seen.status[id] or -1) then
        seen.status[id] = statusAt
    end
end

local function MarkSeenVote(id, player, updated)
    local players = seen.votes[id]
    if not players then
        players = {}
        seen.votes[id] = players
    end
    if updated > (players[player] or -1) then
        players[player] = updated
    end
end

local function SendItem(item)
    local parts = (item.deleted or item.note == "") and {} or Chunks(item.note, NOTE_CHUNK_BYTES)
    local function Build(title)
        return table.concat({
            "F", item.id, Num(item.updated), item.deleted and "1" or "0", item.kind, item.module or "", Num(#parts), title,
        }, SEP)
    end
    local title = item.deleted and "" or (item.title or "")
    local message = Build(title)
    if #message > MAX_MESSAGE_BYTES then
        message = Build(Truncate(title, math.max(0, #title - (#message - MAX_MESSAGE_BYTES))))
    end
    Send(message)
    for index, part in ipairs(parts) do
        Send(table.concat({ "N", item.id, Num(item.updated), Num(index), part }, SEP))
    end
    MarkSeenItem(item.id, item.updated)
end

-- Sends who agrees, several per message as far as there is room.
-- players is which ones to include ({ [key] = true }), or nil for all.
local function SendVotes(item, players)
    local parts, size = { "B", item.id }, 2 + #item.id
    local function Flush()
        if #parts > 2 then
            Send(table.concat(parts, SEP))
        end
        parts, size = { "B", item.id }, 2 + #item.id
    end
    for _, player in ipairs(SortedKeys(item.votes)) do
        if not players or players[player] then
            local vote = item.votes[player]
            local entry = table.concat({ player, Num(vote.v), Num(vote.updated) }, ",")
            if size + 1 + #entry > MAX_MESSAGE_BYTES then
                Flush()
            end
            parts[#parts + 1] = entry
            size = size + 1 + #entry
            MarkSeenVote(item.id, player, vote.updated)
        end
    end
    Flush()
end

-- Sends the status (done, rejected, open again), if the suggestion has got one.
local function SendStatus(item)
    if not item.statusAt then
        return
    end
    Send(table.concat({ "S", item.id, item.status or OPEN, Num(item.statusAt), item.statusBy or "" }, SEP))
    MarkSeenStatus(item.id, item.statusAt)
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

-- Exchange ---------------------------------------------------------------------

local QueueRefresh

local hello = {}  -- [sender] = { [id] = true } while we receive their list
local offers = {} -- [id] = { item = true/false, votes = true/false }: what we will send
local wanted = {} -- [id] = true: what we will ask for
local exchangeScheduled = false

local function Offer(id, withItem, withVotes)
    local offer = offers[id]
    if not offer then
        offer = {}
        offers[id] = offer
        -- From now on we count what others manage to send before us.
        seen.items[id] = nil
        seen.votes[id] = nil
        seen.status[id] = nil
    end
    offer.item = offer.item or withItem
    offer.votes = offer.votes or withVotes
end

local function RunExchange()
    exchangeScheduled = false
    if not DW.IsMember() then
        offers, wanted = {}, {}
        return
    end

    local ids = SortedKeys(wanted)
    wanted = {}
    SendList("G", ids)

    for _, id in ipairs(SortedKeys(offers)) do
        local offer, item = offers[id], db.items[id]
        if item and not item.stub and not item.noteParts then
            if offer.item and (seen.items[id] or -1) < item.updated then
                SendItem(item)
            end
            if offer.votes then
                local players, any = {}, false
                local seenPlayers = seen.votes[id] or {}
                for player, vote in pairs(item.votes) do
                    if (seenPlayers[player] or -1) < vote.updated then
                        players[player] = true
                        any = true
                    end
                end
                if any then
                    SendVotes(item, players)
                end
                if item.statusAt and (seen.status[id] or -1) < item.statusAt then
                    SendStatus(item)
                end
            end
        end
    end
    offers = {}
end

local function ScheduleExchange()
    if exchangeScheduled then
        return
    end
    exchangeScheduled = true
    -- Random wait, so not everyone who is online answers at the same time.
    C_Timer.After(1 + math.random() * 3, RunExchange)
end

-- Tells the others what we have, so they can send what we are missing. Also
-- asks for suggestions where we only received parts of the description.
local function HelloLists()
    PurgeExpired()
    local entries, broken = {}, {}
    for _, id in ipairs(SortedKeys(db.items)) do
        local item = db.items[id]
        if item.noteParts then
            broken[#broken + 1] = id
        elseif Syncable(item) then
            local count, newest = Digest(item)
            entries[#entries + 1] = table.concat({ id, Num(item.updated), Num(count), Num(newest) }, ",")
        end
    end
    return entries, broken
end
-- The entries of our H list ("id,changed,count,newest"), for the tests.
DW.ForslagHelloEntries = function()
    return (HelloLists())
end

local function SayHello()
    local entries, broken = HelloLists()
    SendList("H", entries)
    Send("Q")
    SendList("G", broken)
end

-- Receiving -------------------------------------------------------------------

-- Would ApplyItem take this version?
local function WouldApplyItem(id, updated, deleted, kind, parts)
    if not AuthorOf(id) or #id > 80 or updated > Now() + DAY or (kind ~= NEW and kind ~= IMPROVE) then
        return false
    end
    if parts < 0 or parts > MAX_PARTS then
        return false
    end
    local item = db.items[id]
    if item and not item.stub then
        -- A deletion is final.
        if item.deleted and not deleted then
            return false
        end
        -- The same version is accepted again only if we were missing parts of the description.
        if updated < item.updated or (updated == item.updated and not item.noteParts) then
            return false
        end
    end
    return true
end

-- Receives a suggestion. Returns true if something changed.
local function ApplyItem(id, updated, deleted, kind, module, parts, title)
    if not WouldApplyItem(id, updated, deleted, kind, parts) then
        return false
    end
    local author = AuthorOf(id)
    if #module > 20 or not module:match("^[%l%d]*$") then
        module = ""
    end

    local item = db.items[id]
    if not item then
        item = { id = id, votes = {} }
        db.items[id] = item
        item.arrived = Now() -- when we first got it (the Home page)
    elseif item.stub then
        item.arrived = item.arrived or Now()
    end
    item.stub = nil
    item.author = author
    item.updated = updated
    item.deleted = deleted or nil
    item.kind = kind
    item.module = module
    item.title = Clean(title, MAX_TITLE_BYTES)
    item.note = ""
    item.noteParts = (parts > 0 and not deleted) and { count = parts } or nil
    return true
end

-- Receives a piece of the description. Returns true when all of it has arrived.
local function ApplyNote(id, updated, index, text)
    local item = db.items[id]
    local noteParts = item and item.noteParts
    if not noteParts or item.updated ~= updated or index < 1 or index > noteParts.count or noteParts[index] then
        return false
    end
    -- No trimming here: a space at the joint between two pieces must stay.
    noteParts[index] = Truncate((text:gsub("[%c|]", " ")), NOTE_CHUNK_BYTES + 20)
    for part = 1, noteParts.count do
        if not noteParts[part] then
            return false
        end
    end
    item.note = Truncate(table.concat(noteParts, "", 1, noteParts.count), MAX_NOTE_BYTES)
    item.noteParts = nil
    return true
end

-- Receives an "enig" (agree, v = 1) or one that has been withdrawn (v = 0).
local function ApplyVote(id, player, v, updated)
    if (v ~= 0 and v ~= 1) or updated > Now() + DAY or #player > 80 then
        return false
    end
    local item = db.items[id]
    if not item then
        -- A vote on a suggestion we do not know. Keep it, and ask for the suggestion.
        item = { id = id, stub = true, updated = 0, votes = {} }
        db.items[id] = item
        wanted[id] = true
    end
    local current = item.votes[player]
    if current and updated <= current.updated then
        return false
    end
    item.votes[player] = { v = v, updated = updated }
    return true
end

-- Receives a status from admin. Returns true if something changed.
local function ApplyStatus(id, status, statusAt, by)
    if (status ~= DONE and status ~= REJECTED and status ~= OPEN) or statusAt > Now() + DAY or #by > 40 or #id > 80 then
        return false
    end
    local item = db.items[id]
    if not item then
        -- A status on a suggestion we do not know. Keep it, and ask for the suggestion.
        item = { id = id, stub = true, updated = 0, votes = {} }
        db.items[id] = item
        wanted[id] = true
    end
    if item.statusAt and statusAt <= item.statusAt then
        return false
    end
    item.status = (status ~= OPEN) and status or nil
    item.statusAt = statusAt
    item.statusBy = Clean(by, 40)
    return true
end

-- Does the message come from the one who wrote the suggestion?
local function FromAuthor(id, sender)
    local author = AuthorOf(id)
    return author ~= nil and DW.SameCharacter(author, sender)
end

-- Takes in a suggestion version. Returns true if something changed.
local function AcceptItem(fields)
    local id, updated, parts = fields[2], tonumber(fields[3]), tonumber(fields[7])
    local changed = ApplyItem(id, updated, fields[4] == "1", fields[5], fields[6], parts, fields[8])
    if not changed then
        return false
    end
    -- If the rest of the description does not arrive, we ask for the suggestion again.
    local item = db.items[id]
    if item.noteParts then
        C_Timer.After(NOTE_WAIT, function()
            if db.items[id] == item and item.noteParts and item.updated == updated then
                wanted[id] = true
                ScheduleExchange()
            end
        end)
    end
    return true
end

local function OnMessage(text, sender)
    local fields = Split(text, SEP)
    local kind = fields[1]
    local changed = false

    if kind == "F" and #fields >= 8 then
        local id, updated, parts = fields[2], tonumber(fields[3]), tonumber(fields[7])
        local deleted = fields[4] == "1"
        if id ~= "" and updated and parts then
            -- Sent by someone, so we do not need to send the same version.
            MarkSeenItem(id, updated)
        end
        -- A deletion is only accepted from the one who wrote the suggestion.
        -- (A 9th field, from a test build, is ignored.)
        if id ~= "" and updated and parts and (not deleted or FromAuthor(id, sender)) then
            changed = AcceptItem(fields)
        end

    elseif kind == "N" and #fields >= 5 then
        local updated, index = tonumber(fields[3]), tonumber(fields[4])
        if updated and index then
            changed = ApplyNote(fields[2], updated, index, fields[5])
        end

    elseif kind == "B" and #fields >= 3 then
        local id = fields[2]
        if id ~= "" then
            for index = 3, #fields do
                local player, v, updated = fields[index]:match("^([^,]+),(%d),(%d+)$")
                v, updated = tonumber(v), tonumber(updated)
                if player and v and updated then
                    MarkSeenVote(id, player, updated)
                    if ApplyVote(id, player, v, updated) then
                        changed = true
                    end
                end
            end
        end

    elseif kind == "S" and #fields >= 4 then
        local id, statusAt = fields[2], tonumber(fields[4])
        if id ~= "" and statusAt then
            MarkSeenStatus(id, statusAt)
            changed = ApplyStatus(id, fields[3], statusAt, fields[5] or "")
        end

    elseif kind == "H" then
        -- The list of what the sender has. Compare with our own.
        local listed = hello[sender]
        if not listed then
            listed = {}
            hello[sender] = listed
        end
        for index = 2, #fields do
            local id, theirUpdated, theirCount, theirNewest = fields[index]:match("^(.+),(%d+),(%d+),(%d+)$")
            theirUpdated, theirCount, theirNewest = tonumber(theirUpdated), tonumber(theirCount), tonumber(theirNewest)
            if id and theirUpdated and theirCount and theirNewest then
                listed[id] = true
                local mine = db.items[id]
                if not mine or mine.stub or mine.noteParts then
                    wanted[id] = true
                else
                    if theirUpdated > mine.updated then
                        wanted[id] = true
                    elseif theirUpdated < mine.updated then
                        Offer(id, true, false)
                    end
                    local myCount, myNewest = Digest(mine)
                    if theirNewest > myNewest or theirCount > myCount then
                        wanted[id] = true
                    end
                    if myNewest > theirNewest or myCount > theirCount then
                        Offer(id, false, true)
                    end
                end
            end
        end

    elseif kind == "Q" then
        -- The list is complete. Everything we have that was not on it, the sender is missing.
        local listed = hello[sender] or {}
        hello[sender] = nil
        for id, item in pairs(db.items) do
            if not listed[id] and Syncable(item) and not item.noteParts then
                Offer(id, true, true)
            end
        end

    elseif kind == "G" then
        -- Someone asks for specific suggestions.
        for index = 2, #fields do
            local item = db.items[fields[index]]
            if item and Syncable(item) then
                Offer(fields[index], true, true)
            end
        end
    end

    if next(wanted) ~= nil or next(offers) ~= nil then
        ScheduleExchange()
    end
    if changed then
        QueueRefresh()
    end
end

DW.OnGuildMessage(PREFIX, OnMessage)

-- Polls -----------------------------------------------------------------------------
-- Every guild member can make polls: a question, 2 to 6 answers, open for 1
-- to 14 days. A member may have at most 2 open polls at a time (officers have
-- no limit). Everyone votes once per character, and can change or take back
-- the vote until the poll ends. Votes are not secret. Ended polls are kept 30
-- days. The one who made a poll, and officers, can end it early, delete it
-- and post it in guild chat.
--
-- Shared like the suggestions, on their own message name (DragonworldPoll):
--   P id updated endsAt flags count by question   a version (flags "-", or "d" deleted)
--   O id first option option ...                  the answers (fixed when the poll is made)
--   V id voter,choice,time ...                    votes (choice 0 = taken back)
--   H id,updated,votes,newest,f ...   then   Q    what I have (f: l live, d deleted, - content unknown)
--   G id ...                                      send me these
--
-- Trust: a poll version is accepted from any guild member when `by` is the
-- author (and the author is in the guild) or an officer
-- (DW.WhenRelayedAction). So every member passes polls on, also when the
-- author and the officers are offline. A member's open polls are counted on
-- receive too (at most 2). Refused or undecided versions are held
-- (DW.NewHeldStore). A vote is accepted only from the voter, or relayed by an
-- officer. A deletion is final. Rank decides only what is shown; polls are
-- purged by age and a fixed cap.
--
-- Fakes: a member who changes their own addon could make a poll in someone
-- else's name. Each client remembers the versions it made itself
-- (db.pollAuthored), so the named player's own client notices a version in
-- their name that they never made, deletes it at once and says so in chat
-- (PollSelfHeal). Only versions after db.pollAuthoredSince are judged.
--
-- No flood: answers to a hello wait a random time, officers and the author
-- shorter than other members, and what someone else sends meanwhile is not
-- sent again; when someone else has started answering, the rest waits until
-- they are done (RunPollBatch).

local Poll = {} -- the poll engine, used by the panel further down

do
    local POLL_PREFIX = "DragonworldPoll" -- max 16 characters
    local MAX_QUESTION_LETTERS, MAX_QUESTION_BYTES = 70, 140
    local MAX_OPTION_LETTERS, MAX_OPTION_BYTES = 30, 60
    local MIN_OPTIONS, MAX_OPTIONS = 2, 6
    local KEEP_ENDED = 30 * DAY
    local KEEP_POLL_DELETED = 30 * DAY
    local STUB_KEEP = DAY            -- votes for a poll we do not know
    local VOTE_GRACE = 300           -- votes this long after the end still count
    local MAX_POLLS = 40             -- polls that are not deleted
    local MAX_STUBS = 40             -- placeholders for votes on polls we do not know
    local MAX_ID_BYTES = 60          -- when we make one
    local MAX_RECEIVED_ID_BYTES = 80
    local MAX_BY_BYTES = 60
    local MAX_VOTER_BYTES = 80
    local MAX_LENGTH = 15 * DAY      -- the longest a poll can be open
    local FUTURE = 600               -- how far ahead of the server clock a time may be
    local POLL_HELLO_DELAY = 22      -- after login (other modules use other delays)
    local POLL_LOGIN_BANNER = 36     -- after the hello
    local LOGIN_SETTLE = 12          -- after each poll taken in during the login exchange
    local LOGIN_WINDOW = 120         -- the login banner comes at most this long after the hello
    local LIVE_SECONDS = 300         -- a live banner only for versions this fresh
    local LIVE_PER_AUTHOR = 600      -- at most one live banner per author this often
    local MAX_OPEN_PER_MEMBER = 2    -- open polls a member who is not an officer may have
    local OPTION_WAIT = 20           -- how long we wait for the answers
    local BATCH = 5                  -- polls per batch when answering
    local MEMBER_WAIT = 3            -- other members answer this much later than officers and authors...
    local MEMBER_SPREAD = 24         -- ...plus a random part of this (15 s in the tests)
    local HEAL_NOTICE_EVERY = 30     -- at most one chat line about removed fakes this often
    local AUTHORED_KEEP = 60 * DAY   -- longer than any poll version is taken in (made + 15 days open + 30 kept)

    Poll.DURATIONS = { 1, 2, 3, 5, 7, 14 }
    Poll.DEFAULT_DAYS = 3
    Poll.MAX_OPTIONS = MAX_OPTIONS
    Poll.MAX_QUESTION_LETTERS = MAX_QUESTION_LETTERS
    Poll.MAX_OPTION_LETTERS = MAX_OPTION_LETTERS
    Poll.MAX_OPEN_PER_MEMBER = MAX_OPEN_PER_MEMBER

    -- Saved data, inside the forslag table (set in Poll.Load):
    --   db.polls[id] = {
    --       id = "<author key>:<created>:<seq>", author, created, question,
    --       options = { "answer", ... }, count, endsAt, updated, deleted,
    --       by = who made this version,
    --       votes = { ["Name-Realm"] = { c = 0..6 (0 = taken back), updated, direct = true when heard from the voter } },
    --       optionParts = { count = n } while the answers are on their way,
    --       stub = true (with stubAt) for votes on a poll we do not know yet,
    --       arrived = when we first got it,
    --   }
    --   db.pollSeq, db.pollBannered[id] = true, db.pollHeld (DW.NewHeldStore)
    --   db.pollAuthored[id] = { [updated] = true }: versions made on this account
    --       (by any of its characters; `by` tells which), forgotten when too old
    --       to be taken in by anyone
    --   db.pollAuthoredSince = server time db.pollAuthored was started
    local pollHeld = DW.NewHeldStore({}) -- replaced in Poll.Load

    local function IsWhole(value)
        return type(value) == "number" and value == math.floor(value)
    end

    -- Cuts a text to a number of letters and bytes without splitting a letter.
    local function Cut(text, maxLetters, maxBytes)
        local out, letters, bytes = {}, 0, 0
        for char in text:gmatch("[%z\1-\127\194-\244][\128-\191]*") do
            if letters >= maxLetters or bytes + #char > maxBytes then
                break
            end
            out[#out + 1] = char
            letters = letters + 1
            bytes = bytes + #char
        end
        return (table.concat(out):gsub("%s+$", ""))
    end

    local function CleanQuestion(text)
        return Cut(Clean(text, 1000), MAX_QUESTION_LETTERS, MAX_QUESTION_BYTES)
    end

    local function CleanOption(text)
        return Cut(Clean(text, 1000), MAX_OPTION_LETTERS, MAX_OPTION_BYTES)
    end

    local function IsOpen(poll)
        return not poll.deleted and (poll.endsAt or 0) > Now()
    end

    local function OptionsComplete(poll)
        for index = 1, poll.count or 0 do
            if poll.options[index] == nil then
                return false
            end
        end
        return true
    end

    -- Drops votes cast too late, or for an answer the poll does not have.
    local function PruneVotes(poll)
        if not poll.endsAt then
            return
        end
        for voter, vote in pairs(poll.votes) do
            if vote.updated > poll.endsAt + VOTE_GRACE or vote.c > (poll.count or MAX_OPTIONS) then
                poll.votes[voter] = nil
            end
        end
    end

    -- One vote per character: keys that name the same character
    -- (DW.SameCharacter) count as one. Returns the key that character's
    -- vote is stored under in this poll, or nil.
    local function VoteKeyFor(poll, voter)
        if poll.votes[voter] then
            return voter
        end
        if DW.IdentityKey(voter) == "" then
            return nil
        end
        for key in pairs(poll.votes) do
            if DW.SameCharacter(key, voter) then
                return key
            end
        end
        return nil
    end

    -- Stores a vote under key, unless that character already has one as new or
    -- newer (under any key). Older votes of the same character are removed.
    -- Returns true if the vote was stored.
    local function StoreVote(poll, key, c, updated, direct)
        if DW.IdentityKey(key) == "" then
            return false
        end
        for other, vote in pairs(poll.votes) do
            if DW.SameCharacter(other, key) then
                if vote.updated >= updated then
                    if vote.updated == updated and direct and not vote.direct then
                        vote.direct = true
                    end
                    return false
                end
                poll.votes[other] = nil -- clearing a field during pairs is allowed
            end
        end
        poll.votes[key] = { c = c, updated = updated, direct = direct or nil }
        return true
    end

    -- Keeps one vote per character (for saved data): the newest, then one heard
    -- from the voter, then the first key in sorted order.
    local function DedupeVotes(poll)
        local best = {} -- [name key] = vote key
        for _, key in ipairs(SortedKeys(poll.votes)) do
            local nameKey = DW.IdentityKey(key)
            local vote, keep = poll.votes[key], best[nameKey]
            if nameKey == "" then
                poll.votes[key] = nil
            elseif not keep then
                best[nameKey] = key
            else
                local kept = poll.votes[keep]
                if vote.updated > kept.updated or (vote.updated == kept.updated and vote.direct and not kept.direct) then
                    poll.votes[keep] = nil
                    best[nameKey] = key
                else
                    poll.votes[key] = nil
                end
            end
        end
    end

    -- The number of votes (taken back ones too) and the newest of them, for H.
    local function VoteDigest(poll)
        local count, newest = 0, 0
        for _, vote in pairs(poll.votes) do
            if not poll.endsAt or vote.updated <= poll.endsAt + VOTE_GRACE then
                count = count + 1
                newest = math.max(newest, vote.updated)
            end
        end
        return count, newest
    end

    local function MyChoice(poll)
        local me = MyKey()
        local key = me and VoteKeyFor(poll, me)
        local vote = key and poll.votes[key]
        return vote and vote.c or 0
    end

    -- Votes per answer, the voters' names per answer (sorted) and the total.
    local function Tally(poll)
        local counts, names, total = {}, {}, 0
        for index = 1, poll.count or 0 do
            counts[index], names[index] = 0, {}
        end
        for voter, vote in pairs(poll.votes) do
            if vote.c >= 1 and counts[vote.c] then
                counts[vote.c] = counts[vote.c] + 1
                names[vote.c][#names[vote.c] + 1] = ShortName(voter)
                total = total + 1
            end
        end
        for _, list in pairs(names) do
            table.sort(list)
        end
        return counts, names, total
    end

    local function FreshPoll(deleted, updated, endsAt, now)
        if deleted then
            return updated > now - KEEP_POLL_DELETED
        end
        return endsAt > now - KEEP_ENDED
    end

    local function NewestCreated(a, b)
        if (a.created or 0) ~= (b.created or 0) then
            return (a.created or 0) > (b.created or 0)
        end
        return a.id > b.id
    end

    -- The ids that are remembered and shared (no rank involved): not a stub,
    -- fresh enough, and among those not deleted only the newest MAX_POLLS.
    local function SyncableSet()
        local now = Now()
        local set, live = {}, {}
        for id, poll in pairs(db.polls) do
            if not poll.stub and FreshPoll(poll.deleted, poll.updated, poll.endsAt, now) then
                if poll.deleted then
                    set[id] = true
                else
                    live[#live + 1] = poll
                end
            end
        end
        table.sort(live, NewestCreated)
        for index = 1, math.min(#live, MAX_POLLS) do
            set[live[index].id] = true
        end
        return set
    end

    local function SameName(a, b)
        return DW.SameCharacter(a, b)
    end

    -- A version as its author made it: not deleted, by the author, and not
    -- changed since. Counted against the author's limit of open polls.
    local function IsCreation(id, updated, deleted, by)
        local author = AuthorOf(id)
        return not deleted and author ~= nil and SameName(by, author) and updated == CreatedOf(id)
    end

    -- Shown: syncable, not deleted, all the answers here, and this version by
    -- its author or by someone who is an officer now.
    local function Displayable(poll, set)
        return set[poll.id] == true and not poll.deleted and not poll.optionParts
            and (SameName(poll.by, poll.author) or DW.IsOfficerKey(poll.by) == true)
    end

    -- May I end, delete or share this poll? Its author and officers may.
    local function MayManage(poll)
        local me = MyKey()
        return me ~= nil and DW.IsMember() and (SameName(poll.author, me) or DW.IsOfficer())
    end

    local function DisplayableList()
        local set, list = SyncableSet(), {}
        for _, poll in pairs(db.polls) do
            if Displayable(poll, set) then
                list[#list + 1] = poll
            end
        end
        return list, set
    end

    -- Removes the oldest placeholders until at most max are left. Returns the
    -- ids removed.
    local function TrimStubs(max)
        local stubs = {}
        for _, poll in pairs(db.polls) do
            if poll.stub then
                stubs[#stubs + 1] = poll
            end
        end
        table.sort(stubs, function(a, b)
            if (a.stubAt or 0) ~= (b.stubAt or 0) then
                return (a.stubAt or 0) < (b.stubAt or 0)
            end
            return a.id < b.id
        end)
        local removed = {}
        for index = 1, #stubs - max do
            db.polls[stubs[index].id] = nil
            removed[#removed + 1] = stubs[index].id
        end
        return removed
    end

    local function PollPurge()
        TrimStubs(MAX_STUBS)
        local set, now = SyncableSet(), Now()
        for id, poll in pairs(db.polls) do
            if poll.stub then
                if (poll.stubAt or 0) < now - STUB_KEEP then
                    db.polls[id] = nil
                end
            elseif not set[id] then
                db.polls[id] = nil
            end
        end
        for id in pairs(db.pollBannered) do
            if not db.polls[id] then
                db.pollBannered[id] = nil
            end
        end
        -- Our own versions are forgotten when no client would take them in
        -- any more (FreshPoll: no version lives longer than AUTHORED_KEEP),
        -- not when the poll leaves our list: someone else may still send it
        -- back before they purge it too.
        local oldest = now - AUTHORED_KEEP
        for id, versions in pairs(db.pollAuthored) do
            if type(versions) == "table" then
                for updated in pairs(versions) do
                    if type(updated) ~= "number" or updated < oldest then
                        versions[updated] = nil
                    end
                end
            end
            if type(versions) ~= "table" or next(versions) == nil then
                db.pollAuthored[id] = nil
            end
        end
        pollHeld:Purge()
    end

    -- The versions made on this account (see db.pollAuthored).
    local function NotePollAuthored(id, updated)
        local versions = db.pollAuthored[id]
        if type(versions) ~= "table" then
            versions = {}
            db.pollAuthored[id] = versions
        end
        versions[updated] = true
    end

    local function PollAuthored(id, updated)
        local versions = db.pollAuthored[id]
        return type(versions) == "table" and versions[updated] == true
    end

    -- Sending ---------------------------------------------------------------------

    local SendPollMessage = DW.CreateSender(POLL_PREFIX)

    -- Versions sent by someone the receivers trust, since someone last asked.
    local seenPoll = {}  -- [id] = updated
    local seenVotes = {} -- [id] = { [voter] = updated }

    local function MarkSeenPoll(id, updated)
        if updated > (seenPoll[id] or -1) then
            seenPoll[id] = updated
        end
    end

    local function MarkSeenPollVote(id, voter, updated)
        local voters = seenVotes[id]
        if not voters then
            voters = {}
            seenVotes[id] = voters
        end
        if updated > (voters[voter] or -1) then
            voters[voter] = updated
        end
    end

    -- withoutOptions: only the P (End now; the answers never change).
    local function SendPoll(poll, withoutOptions)
        local function Build(question)
            return table.concat({
                "P", poll.id, Num(poll.updated), Num(poll.endsAt), poll.deleted and "d" or "-", Num(poll.count), poll.by or "", question,
            }, SEP)
        end
        local question = poll.deleted and "" or (poll.question or "")
        local message = Build(question)
        if #message > MAX_MESSAGE_BYTES then
            message = Build(Truncate(question, math.max(0, #question - (#message - MAX_MESSAGE_BYTES))))
        end
        SendPollMessage(message)
        -- The answers, as many per message as fit.
        if not poll.deleted and not poll.optionParts and not withoutOptions then
            local index = 1
            while index <= poll.count do
                local parts = { "O", poll.id, Num(index) }
                local size = #table.concat(parts, SEP)
                repeat
                    local option = poll.options[index] or "?"
                    if #parts > 3 and size + 1 + #option > MAX_MESSAGE_BYTES then
                        break
                    end
                    parts[#parts + 1] = option
                    size = size + 1 + #option
                    index = index + 1
                until index > poll.count
                SendPollMessage(table.concat(parts, SEP))
            end
        end
        MarkSeenPoll(poll.id, poll.updated)
    end

    -- Sends votes, several per message. voters: which ones ({ [voter] = true }),
    -- or nil for all. Others refuse votes relayed by members, so a member only
    -- sends their own. Returns how many were sent.
    local function SendPollVotes(poll, voters)
        local officer = DW.IsOfficer()
        local me = MyKey()
        local parts, size, sent = { "V", poll.id }, 2 + #poll.id, 0
        local function Flush()
            if #parts > 2 then
                SendPollMessage(table.concat(parts, SEP))
            end
            parts, size = { "V", poll.id }, 2 + #poll.id
        end
        for _, voter in ipairs(SortedKeys(poll.votes)) do
            if (not voters or voters[voter]) and (officer or DW.SameCharacter(voter, me)) then
                local vote = poll.votes[voter]
                local entry = table.concat({ voter, Num(vote.c), Num(vote.updated) }, ",")
                if size + 1 + #entry > MAX_MESSAGE_BYTES then
                    Flush()
                end
                parts[#parts + 1] = entry
                size = size + 1 + #entry
                sent = sent + 1
                MarkSeenPollVote(poll.id, voter, vote.updated)
            end
        end
        Flush()
        return sent
    end

    local function SendPollList(kind, entries)
        local parts, size = { kind }, #kind
        for _, entry in ipairs(entries) do
            if size + 1 + #entry > MAX_MESSAGE_BYTES and #parts > 1 then
                SendPollMessage(table.concat(parts, SEP))
                parts, size = { kind }, #kind
            end
            parts[#parts + 1] = entry
            size = size + 1 + #entry
        end
        if #parts > 1 then
            SendPollMessage(table.concat(parts, SEP))
        end
    end

    -- Banners ---------------------------------------------------------------------

    local pollHelloAt  -- GetTime() of this session's poll hello
    local pollLoginDue -- GetTime() when the login banner may be picked
    local pollLoginDone = false
    local pollLoginToken = 0
    local liveBannerAt = {} -- [author name key] = GetTime() of the last live banner for one of their polls

    local function ShowPollBanner(poll)
        -- Its own box in the Achievements tab ("Banners for announcements and polls").
        if not DW.ShowBanner or (DW.NewsBannersOn and not DW.NewsBannersOn()) then
            return false
        end
        local id = poll.id
        return DW.ShowBanner({
            key = "poll:" .. id,
            always = true,
            title = function()
                return L.POLL_BANNER
            end,
            text = function()
                return DW.BannerGold(poll.question or "") .. "\n" .. L.POLL_BANNER_ENDS:format(date("%d.%m.%Y %H:%M", poll.endsAt))
            end,
            button = function()
                return L.POLL_VOTE
            end,
            -- Remembered only when it is really shown, so a dropped banner comes at the next login.
            onShow = function()
                db.pollBannered[id] = true
            end,
            onClick = function()
                DW.OpenPoll(id)
            end,
        })
    end

    -- Should this poll give a banner on this account?
    local function PollEligible(poll, set)
        if not Displayable(poll, set) or not IsOpen(poll) or db.pollBannered[poll.id] then
            return false
        end
        if DW.SameCharacter(poll.by, MyKey()) then
            return false
        end
        return MyChoice(poll) == 0
    end

    local function PollLoginSelectionDone()
        return pollLoginDone or (pollHelloAt ~= nil and GetTime() - pollHelloAt > LOGIN_WINDOW)
    end

    -- At login: the newest eligible poll gets a banner, at most one. The rest
    -- wait in the Forslag tab.
    local function RunPollLoginSelection()
        pollLoginDone = true
        if not DW.IsMember() then
            return
        end
        local list, set = DisplayableList()
        local best
        for _, poll in ipairs(list) do
            if PollEligible(poll, set) and (not best or poll.updated > best.updated or (poll.updated == best.updated and poll.id > best.id)) then
                best = poll
            end
        end
        if best then
            ShowPollBanner(best)
        end
    end

    local function CheckPollLogin(token)
        if pollLoginDone or token ~= pollLoginToken then
            return
        end
        local now = GetTime()
        if now >= pollLoginDue then
            RunPollLoginSelection()
        else
            C_Timer.After(pollLoginDue - now + 0.05, function()
                CheckPollLogin(token)
            end)
        end
    end

    -- A poll was taken in (or its answers completed).
    local function AfterPollApply(id)
        if not pollLoginDone and pollHelloAt then
            -- The login banner waits until the login exchange has settled.
            pollLoginDue = math.min(pollHelloAt + LOGIN_WINDOW, math.max(pollLoginDue or 0, GetTime() + LOGIN_SETTLE))
        end
        local poll = db.polls[id]
        if poll and not poll.stub and Now() - poll.updated <= LIVE_SECONDS and PollLoginSelectionDone() then
            -- At most one live banner per author every LIVE_PER_AUTHOR seconds.
            local authorKey = DW.IdentityKey(poll.author)
            local last = liveBannerAt[authorKey]
            if PollEligible(poll, SyncableSet()) and not (last and GetTime() - last < LIVE_PER_AUTHOR) then
                if ShowPollBanner(poll) ~= false then
                    liveBannerAt[authorKey] = GetTime()
                end
            end
        end
        QueueRefresh()
    end

    -- Exchange --------------------------------------------------------------------

    local optionSources = {} -- [id] = name key of who sent the version that waits for its answers
    local pollHello = {}  -- [sender] = { [id] = true } while we receive their list
    local pollOffers = {} -- [id] = { poll = true/false, votes = true/false }
    local pollWanted = {} -- [id] = true: what we will ask for
    local pollQueue = {}  -- { id, poll, votes } waiting to be sent, BATCH at a time
    local pollExchangeScheduled, pollBatchScheduled = false, false

    local function OfferPoll(id, withPoll, withVotes)
        local offer = pollOffers[id]
        if not offer then
            offer = {}
            pollOffers[id] = offer
            -- From now on we count what others manage to send before us.
            seenPoll[id] = nil
            seenVotes[id] = nil
        end
        offer.poll = offer.poll or withPoll
        offer.votes = offer.votes or withVotes
    end

    -- What of an offered poll is still ours to send: the poll itself (unless
    -- someone has sent this version or a newer one meanwhile; any member
    -- passes on what they have taken in), and the votes we may pass on that
    -- nobody has sent yet (a member passes on only their own: others refuse
    -- votes relayed by members). Also tells whether someone else has sent a
    -- part of it since we last looked (each part is counted once: the entry
    -- remembers what it has heard).
    local function StillToSend(entry, set)
        local poll = db.polls[entry.id]
        if not poll or poll.stub or poll.optionParts or not set[entry.id] then
            return false, nil, false
        end
        local covered = false
        local sendPoll = false
        if entry.poll then
            if (seenPoll[entry.id] or -1) < poll.updated then
                sendPoll = true
            else
                entry.poll = false
                covered = true
            end
        end
        local voters
        if entry.votes and not poll.deleted then
            local officer, me = DW.IsOfficer(), MyKey()
            local seenVoters = seenVotes[entry.id] or {}
            for voter, vote in pairs(poll.votes) do
                if officer or DW.SameCharacter(voter, me) then
                    if (seenVoters[voter] or -1) < vote.updated then
                        voters = voters or {}
                        voters[voter] = true
                    elseif not (entry.heard and entry.heard[voter]) then
                        entry.heard = entry.heard or {}
                        entry.heard[voter] = true
                        covered = true
                    end
                end
            end
        end
        return sendPoll, voters, covered
    end

    -- Sends one offered poll. Returns true if something was sent.
    local function SendOffered(entry, set)
        local sendPoll, voters = StillToSend(entry, set)
        local any = false
        if sendPoll then
            SendPoll(db.polls[entry.id])
            any = true
        end
        if voters and SendPollVotes(db.polls[entry.id], voters) > 0 then
            any = true
        end
        return any
    end

    local function RunPollBatch()
        pollBatchScheduled = false
        if not DW.IsMember() then
            pollQueue = {}
            return
        end
        -- The seen check is made again before every batch: what someone else
        -- has sent meanwhile is dropped.
        local set = SyncableSet()
        local keep, covered = {}, false
        for _, entry in ipairs(pollQueue) do
            local sendPoll, voters, partly = StillToSend(entry, set)
            covered = covered or partly
            if sendPoll or voters then
                keep[#keep + 1] = entry
            end
        end
        pollQueue = keep
        if covered and #pollQueue > 0 then
            -- Someone else is answering: let them finish, then look again.
            pollBatchScheduled = true
            C_Timer.After(6 + math.random() * 2, RunPollBatch)
            return
        end
        local sent = 0
        while #pollQueue > 0 and sent < BATCH do
            if SendOffered(table.remove(pollQueue, 1), set) then
                sent = sent + 1
            end
        end
        if #pollQueue > 0 then
            pollBatchScheduled = true
            C_Timer.After(6 + math.random() * 2, RunPollBatch)
        end
    end

    -- Officers, and the author of a poll in the queue, answer at once (after
    -- the exchange wait); other members wait longer, so they mostly hear that
    -- answer first and stay quiet. The random part spreads the members out.
    local function StartPollBatch()
        if pollBatchScheduled then
            return
        end
        local fast = DW.IsOfficer()
        local me = MyKey()
        for _, entry in ipairs(pollQueue) do
            local poll = db.polls[entry.id]
            if not fast and poll and (SameName(poll.author, me) or SameName(poll.by, me)) then
                fast = true
            end
        end
        if fast then
            RunPollBatch()
        else
            pollBatchScheduled = true
            C_Timer.After(MEMBER_WAIT + math.random() * MEMBER_SPREAD, RunPollBatch)
        end
    end

    local function RunPollExchange()
        pollExchangeScheduled = false
        if not DW.IsMember() then
            pollOffers, pollWanted, pollQueue = {}, {}, {}
            return
        end
        local ids = SortedKeys(pollWanted)
        pollWanted = {}
        SendPollList("G", ids)

        local list = {}
        for id, offer in pairs(pollOffers) do
            local poll = db.polls[id]
            if poll then
                list[#list + 1] = { id = id, created = poll.created or 0, poll = offer.poll, votes = offer.votes }
            end
        end
        pollOffers = {}
        -- The newest first.
        table.sort(list, NewestCreated)
        local queued = {}
        for _, entry in ipairs(pollQueue) do
            queued[entry.id] = entry
        end
        for _, entry in ipairs(list) do
            local waiting = queued[entry.id]
            if waiting then
                waiting.poll = waiting.poll or entry.poll
                waiting.votes = waiting.votes or entry.votes
            else
                pollQueue[#pollQueue + 1] = entry
            end
        end
        if #pollQueue > 0 then
            StartPollBatch()
        end
    end

    local function SchedulePollExchange()
        if pollExchangeScheduled then
            return
        end
        pollExchangeScheduled = true
        -- Random wait, so not everyone who is online answers at the same time (2.7 s in the tests).
        C_Timer.After(1.2 + math.random() * 3, RunPollExchange)
    end

    -- Our H list: every poll we keep, whatever the rank of its maker. A newer
    -- held version counts as one we have (its content unknown: "-"). Polls
    -- missing answers, and votes for polls we lack, are asked for instead.
    local function PollHelloLists()
        local set = SyncableSet()
        local entries, broken = {}, {}
        for _, id in ipairs(SortedKeys(db.polls)) do
            local poll = db.polls[id]
            if poll.stub or poll.optionParts then
                broken[#broken + 1] = id
            elseif set[id] then
                local count, newest = VoteDigest(poll)
                local heldVersion = pollHeld:Version(id)
                if heldVersion and heldVersion > poll.updated then
                    entries[#entries + 1] = table.concat({ id, Num(heldVersion), Num(count), Num(newest), "-" }, ",")
                else
                    entries[#entries + 1] = table.concat({ id, Num(poll.updated), Num(count), Num(newest), poll.deleted and "d" or "l" }, ",")
                end
            end
        end
        return entries, broken
    end

    local function PollHello()
        PollPurge()
        Poll.SelfHealAll()
        local entries, broken = PollHelloLists()
        SendPollList("H", entries)
        SendPollMessage("Q")
        SendPollList("G", broken)
        pollHelloAt = GetTime()
        pollLoginDue = pollHelloAt + POLL_LOGIN_BANNER
        pollLoginToken = pollLoginToken + 1
        local token = pollLoginToken
        C_Timer.After(POLL_LOGIN_BANNER, function()
            CheckPollLogin(token)
        end)
    end

    -- Receiving -------------------------------------------------------------------

    -- Would this version replace the poll we have?
    local function PollWins(poll, updated, deleted, by)
        -- A deletion is final, both ways.
        if deleted and not poll.deleted then
            return true
        end
        if poll.deleted and not deleted then
            return false
        end
        if updated ~= poll.updated then
            return updated > poll.updated
        end
        if by ~= poll.by then
            return by > (poll.by or "")
        end
        return false
    end

    -- Would ApplyPoll take this version (before any trust check)?
    local function WouldApplyPoll(id, updated, endsAt, deleted, by)
        if not FreshPoll(deleted, updated, endsAt, Now()) then
            return false
        end
        local poll = db.polls[id]
        if not poll or poll.stub then
            return true
        end
        if PollWins(poll, updated, deleted, by) then
            return true
        end
        -- The same version is taken again only while answers are missing.
        return poll.optionParts ~= nil and updated == poll.updated and deleted == (poll.deleted == true) and by == poll.by
    end

    -- Takes in a version that has passed the trust rules. Returns true if something changed.
    local function ApplyPoll(id, updated, endsAt, deleted, count, by, question)
        if not WouldApplyPoll(id, updated, endsAt, deleted, by) then
            return false
        end
        local poll = db.polls[id]
        if not poll then
            poll = { id = id, votes = {} }
            db.polls[id] = poll
        end
        local isNew = poll.stub or poll.arrived == nil
        -- The answers never change after a poll is made: keep them when we have them all.
        local complete = not poll.stub and not poll.optionParts and type(poll.options) == "table" and poll.count == count
        poll.stub, poll.stubAt = nil, nil
        poll.author = AuthorOf(id)
        poll.created = CreatedOf(id)
        poll.updated = updated
        poll.deleted = deleted or nil
        poll.by = by
        poll.question = deleted and "" or CleanQuestion(question)
        if isNew then
            poll.arrived = Now()
        end
        if deleted then
            poll.options, poll.optionParts, poll.votes = {}, nil, {}
            poll.count = count
        elseif not complete then
            if type(poll.options) ~= "table" or poll.count ~= count then
                poll.options = {}
            end
            poll.count = count
            poll.optionParts = { count = count }
            if OptionsComplete(poll) then
                poll.optionParts = nil
            end
        end
        poll.endsAt = endsAt
        PruneVotes(poll)
        pollHeld:Clear(id, updated)
        -- If the answers do not arrive, we ask for the poll again.
        if poll.optionParts then
            C_Timer.After(OPTION_WAIT, function()
                if db.polls[id] == poll and poll.optionParts and poll.updated == updated then
                    pollWanted[id] = true
                    SchedulePollExchange()
                end
            end)
        end
        return true
    end

    -- Would a new poll by this author (id not counted) go over the limit of
    -- open polls for a member? Checked on receive too, not only by the
    -- author's own client. Officers (or anyone we cannot tell yet) have no limit.
    local function TooManyOpen(author, id)
        if DW.IsOfficerKey(author) ~= false then
            return false
        end
        local count = 0
        for otherId, poll in pairs(db.polls) do
            if otherId ~= id and not poll.stub and IsOpen(poll) and SameName(poll.author, author) then
                count = count + 1
            end
        end
        return count >= MAX_OPEN_PER_MEMBER
    end

    -- Self-healing against fakes: a version in my name (this character) that
    -- was never made on this account is deleted at once, with a line in chat.
    -- Only versions after db.pollAuthoredSince count: older ones cannot be
    -- told apart. A deletion is final, so this cannot go back and forth; each
    -- poll is tried once per session.
    local pollHealed = {}  -- [id] = true
    local pollHealNoticeAt -- GetTime() of the last chat line about it

    local function PollSelfHeal(id)
        local poll = db.polls[id]
        local me = MyKey()
        if pollHealed[id] or not poll or poll.stub or poll.deleted or not me or not SameName(poll.by, me)
            or type(db.pollAuthoredSince) ~= "number" or poll.updated < db.pollAuthoredSince
            or PollAuthored(id, poll.updated) or not MayManage(poll) then
            return false
        end
        pollHealed[id] = true
        Poll.Delete(poll)
        if not (pollHealNoticeAt and GetTime() - pollHealNoticeAt < HEAL_NOTICE_EVERY) then
            pollHealNoticeAt = GetTime()
            DW.Print(L.POLL_FAKE_REMOVED)
        end
        return true
    end

    -- At the hello: a fake may have come in while another character on this
    -- account was logged in.
    local function PollSelfHealAll()
        for _, id in ipairs(SortedKeys(db.polls)) do
            PollSelfHeal(id)
        end
    end
    Poll.SelfHealAll = PollSelfHealAll

    local function OnP(fields, sender, replay)
        local id, updated, endsAt, flags, count, by = fields[2], tonumber(fields[3]), tonumber(fields[4]), fields[5], tonumber(fields[6]), fields[7]
        local created = AuthorOf(id) and CreatedOf(id)
        local now = Now()
        if not (created and #id <= MAX_RECEIVED_ID_BYTES and created <= now + FUTURE
            and IsWhole(updated) and updated > 0 and updated <= now + FUTURE
            and IsWhole(endsAt) and endsAt >= created and endsAt <= created + MAX_LENGTH
            and IsWhole(count) and count >= MIN_OPTIONS and count <= MAX_OPTIONS
            and (flags == "-" or flags == "d") and by ~= "" and #by <= MAX_BY_BYTES) then
            return
        end
        local deleted = flags == "d"
        local author = AuthorOf(id)
        local creation = IsCreation(id, updated, deleted, by)
        -- Sent by someone the receivers will take it from (any guild member,
        -- for a version by its author or an officer), so we need not send the
        -- same version: a pending answer of ours for it is dropped. This
        -- counts also when we have the version already.
        if DW.MayRelay(sender, by, author) == true then
            MarkSeenPoll(id, updated)
        end
        if not WouldApplyPoll(id, updated, endsAt, deleted, by) then
            return
        end
        local function finish(ok)
            if ok and creation and TooManyOpen(author, id) then
                -- The author's own client keeps to the limit; more than that is
                -- not taken (nor held: the author can send it again later).
                return
            end
            if ok then
                if ApplyPoll(id, updated, endsAt, deleted, count, by, fields[8] or "") then
                    if db.polls[id].optionParts then
                        -- Its answers are taken from the one who sent this version.
                        optionSources[id] = DW.IdentityKey(sender)
                    end
                    if PollSelfHeal(id) then
                        QueueRefresh()
                    elseif db.polls[id].optionParts then
                        QueueRefresh()
                    else
                        AfterPollApply(id)
                    end
                end
                MarkSeenPoll(id, updated)
                if next(pollWanted) ~= nil then
                    SchedulePollExchange()
                end
            elseif DW.TrustedVersion(by, author) ~= true then
                -- Not held when only the sender was the trouble (not in the
                -- roster): the version itself is fine, and a copy from someone
                -- else must still be asked for.
                pollHeld:Hold(id, updated, replay, sender)
            end
        end
        -- By the author (a new poll, or ended early or deleted by them) or by an
        -- officer, from them or passed on by any guild member. A new poll from
        -- its author is taken at once.
        local result = DW.WhenRelayedAction("poll:P:" .. id .. ":" .. Num(updated), sender, by, author, finish)
        if result == nil and DW.TrustedVersion(by, author) ~= true then
            pollHeld:Hold(id, updated, replay, sender)
        end
    end

    -- Answers: only for a poll waiting for them, from the one who sent us that
    -- version, or from the one who made it or an officer (after a /reload,
    -- when we no longer know who sent it). Returns true when all have arrived.
    local function OnO(fields, sender)
        local poll = db.polls[fields[2]]
        local first = tonumber(fields[3])
        if not (poll and poll.optionParts and IsWhole(first) and first >= 1 and first <= poll.count) then
            return false
        end
        local fromSource = optionSources[poll.id] ~= nil and optionSources[poll.id] == DW.IdentityKey(sender)
        if not fromSource and DW.MayActFor(sender, poll.by) ~= true then
            return false
        end
        for field = 4, #fields do
            local index = first + field - 4
            if index > poll.count then
                break
            end
            if poll.options[index] == nil then
                local text = CleanOption(fields[field])
                poll.options[index] = text ~= "" and text or "?"
            end
        end
        if not OptionsComplete(poll) then
            return false
        end
        poll.optionParts = nil
        optionSources[poll.id] = nil
        PruneVotes(poll)
        return true
    end

    -- Votes: from the voter, or relayed by an officer. Returns true if something changed.
    local function OnV(fields, sender)
        local id = fields[2]
        if not (AuthorOf(id) and #id <= MAX_RECEIVED_ID_BYTES) then
            return false
        end
        local senderOfficer -- looked up once, when needed
        local changed = false
        local limit = Now() + FUTURE
        for index = 3, #fields do
            local voter, c, updated = fields[index]:match("^([^,]+),(%d+),(%d+)$")
            c, updated = tonumber(c), tonumber(updated)
            if voter and c and updated and #voter <= MAX_VOTER_BYTES and updated > 0 and updated <= limit and c <= MAX_OPTIONS then
                local poll = db.polls[id]
                local known = poll ~= nil and not poll.stub
                local valid = not (known and (poll.deleted or c > poll.count or updated > poll.endsAt + VOTE_GRACE))
                local direct = DW.SameCharacter(voter, sender)
                if valid and not direct and senderOfficer == nil then
                    senderOfficer = DW.IsOfficerKey(sender) == true
                end
                if valid and (direct or senderOfficer) then
                    -- A direct vote is stored under the name the game gave the
                    -- sender, not the one written in the message.
                    local key = voter
                    if direct then
                        key = (sender:find("-", 1, true) or voter:match("^[^-]+") ~= sender) and sender or voter
                    end
                    if not poll then
                        -- A vote for a poll we do not know. Keep it (the oldest
                        -- placeholder goes when there are too many), and ask for the poll.
                        for _, removed in ipairs(TrimStubs(MAX_STUBS - 1)) do
                            pollWanted[removed] = nil
                        end
                        poll = { id = id, stub = true, stubAt = Now(), updated = 0, votes = {} }
                        db.polls[id] = poll
                        pollWanted[id] = true
                    end
                    if StoreVote(poll, key, c, updated, direct) then
                        changed = true
                    end
                    MarkSeenPollVote(id, VoteKeyFor(poll, key) or key, updated)
                end
            end
        end
        return changed
    end

    -- The list of what the sender has. Compare with our own.
    local function OnH(fields, sender)
        local listed = pollHello[sender]
        if not listed then
            listed = {}
            pollHello[sender] = listed
        end
        for index = 2, #fields do
            local id, theirUpdated, theirCount, theirNewest, flag = fields[index]:match("^(.+),(%d+),(%d+),(%d+),([ld%-])$")
            theirUpdated, theirCount, theirNewest = tonumber(theirUpdated), tonumber(theirCount), tonumber(theirNewest)
            if id and theirUpdated and theirCount and theirNewest and #id <= MAX_RECEIVED_ID_BYTES then
                listed[id] = true
                local mine = db.polls[id]
                -- The very version we hold (refused or undecided) counts as one we
                -- have, whoever lists it: a version is held for what it is, not
                -- for who sent it, so anyone's copy would be held again.
                local heldHas = pollHeld:Version(id) == theirUpdated
                if mine and mine.optionParts then
                    pollWanted[id] = true
                elseif not mine or mine.stub then
                    if not heldHas then
                        pollWanted[id] = true
                    end
                else
                    if mine.deleted and flag == "l" then
                        -- A deletion is final: they still have it live, whatever the times.
                        OfferPoll(id, true, false)
                    elseif not mine.deleted and flag == "d" then
                        if not heldHas then
                            pollWanted[id] = true
                        end
                    elseif theirUpdated > mine.updated then
                        if not heldHas then
                            pollWanted[id] = true
                        end
                    elseif theirUpdated < mine.updated then
                        OfferPoll(id, true, false)
                    end
                    if not mine.deleted then
                        local myCount, myNewest = VoteDigest(mine)
                        if theirCount > myCount or theirNewest > myNewest then
                            pollWanted[id] = true
                        end
                        if myNewest > theirNewest or myCount > theirCount then
                            OfferPoll(id, false, true)
                        end
                    end
                end
            end
        end
    end

    local function OnPollMessage(text, sender)
        local fields = Split(text, SEP)
        local kind = fields[1]
        -- Runs this message again (when the officers change, for a held version).
        local function replay()
            OnPollMessage(text, sender)
        end

        if kind == "P" and #fields >= 8 then
            OnP(fields, sender, replay)
        elseif kind == "O" and #fields >= 4 then
            if OnO(fields, sender) then
                AfterPollApply(fields[2])
            end
        elseif kind == "V" and #fields >= 3 then
            if OnV(fields, sender) then
                QueueRefresh()
            end
        elseif kind == "H" then
            OnH(fields, sender)
        elseif kind == "Q" then
            -- The list is complete. Everything we have that was not on it, the sender is missing.
            local listed = pollHello[sender] or {}
            pollHello[sender] = nil
            for id in pairs(SyncableSet()) do
                if not listed[id] and not db.polls[id].optionParts then
                    OfferPoll(id, true, true)
                end
            end
        elseif kind == "G" then
            local set = SyncableSet()
            for index = 2, #fields do
                local poll = db.polls[fields[index]]
                if poll and set[poll.id] and not poll.optionParts then
                    OfferPoll(poll.id, true, true)
                end
            end
        end

        if next(pollWanted) ~= nil or next(pollOffers) ~= nil then
            SchedulePollExchange()
        end
    end

    DW.OnGuildMessage(POLL_PREFIX, OnPollMessage)

    -- Actions ---------------------------------------------------------------------

    -- My open polls (shown ones).
    local function MyOpenCount()
        local me, count = MyKey(), 0
        for _, poll in ipairs((DisplayableList())) do
            if IsOpen(poll) and SameName(poll.author, me) then
                count = count + 1
            end
        end
        return count
    end

    -- Any guild member. Returns the new poll, or nil and an error text.
    function Poll.Create(questionText, optionTexts, days)
        local me = MyKey()
        if not me or not DW.IsMember() then
            return nil
        end
        if not DW.IsOfficer() and MyOpenCount() >= MAX_OPEN_PER_MEMBER then
            return nil, L.POLL_TOO_MANY:format(MAX_OPEN_PER_MEMBER)
        end
        local question = CleanQuestion(questionText)
        if question == "" then
            return nil, L.POLL_NEED_QUESTION
        end
        -- Empty boxes are skipped, and the same answer twice counts once.
        local options, known = {}, {}
        for index = 1, MAX_OPTIONS do
            local option = CleanOption(optionTexts[index] or "")
            if option ~= "" and not known[option:lower()] then
                known[option:lower()] = true
                options[#options + 1] = option
            end
        end
        if #options < MIN_OPTIONS then
            return nil, L.POLL_NEED_OPTIONS
        end
        local now = Now()
        local id = ("%s:%d:%d"):format(me, now, (db.pollSeq or 0) + 1)
        if #id > MAX_ID_BYTES then
            return nil, L.POLL_ID_TOO_LONG
        end
        local length = Poll.DEFAULT_DAYS
        for _, choice in ipairs(Poll.DURATIONS) do
            if choice == days then
                length = days
            end
        end
        db.pollSeq = (db.pollSeq or 0) + 1
        local poll = {
            id = id, author = me, created = now, updated = now, endsAt = now + length * DAY, arrived = now,
            question = question, options = options, count = #options, by = me, votes = {},
        }
        db.polls[id] = poll
        db.pollBannered[id] = true -- no banner for the one who made it
        NotePollAuthored(id, now)
        SendPoll(poll)
        QueueRefresh()
        return poll
    end

    -- Anyone, while the poll is open: vote for answer index, or take the vote
    -- back by choosing the same answer again.
    function Poll.Vote(poll, index)
        local me = MyKey()
        if not me or not IsOpen(poll) or poll.optionParts or index < 1 or index > poll.count then
            return
        end
        local key = VoteKeyFor(poll, me)
        local current = key and poll.votes[key]
        local c = (current and current.c == index) and 0 or index
        local updated = math.max(Now(), current and (current.updated + 1) or 0)
        StoreVote(poll, me, c, updated, true) -- newer than current, so it replaces it
        SendPollVotes(poll, { [me] = true })
    end

    -- The author or an officer: ends an open poll now.
    function Poll.EndNow(poll)
        local me = MyKey()
        if not MayManage(poll) or not IsOpen(poll) then
            return
        end
        local now = Now()
        poll.endsAt = math.max(poll.created or now, now)
        poll.updated = math.max(now, poll.updated + 1)
        poll.by = me
        PruneVotes(poll)
        NotePollAuthored(poll.id, poll.updated)
        SendPoll(poll, true)
    end

    -- The author or an officer: deletes a poll (a tombstone is kept for a month).
    function Poll.Delete(poll)
        local me = MyKey()
        if not MayManage(poll) or poll.deleted then
            return
        end
        poll.deleted = true
        poll.question, poll.options, poll.optionParts, poll.votes = "", {}, nil, {}
        poll.by = me
        poll.updated = math.max(Now(), poll.updated + 1)
        NotePollAuthored(poll.id, poll.updated)
        SendPoll(poll)
    end

    -- The author or an officer: posts the poll in guild chat.
    function Poll.Share(poll)
        if not MayManage(poll) or poll.deleted or poll.optionParts then
            return
        end
        local answers = {}
        for index = 1, poll.count do
            answers[index] = ("%d) %s"):format(index, poll.options[index] or "?")
        end
        local ends = IsOpen(poll) and L.POLL_ENDS_AT or L.POLL_ENDED_AT
        local text = Truncate(L.POLL_CHAT:format(poll.question or "", table.concat(answers, "  "),
            ends:format(date("%d.%m.%Y %H:%M", poll.endsAt))), MAX_MESSAGE_BYTES)
        if not DW.SendChat(text, "GUILD") then
            DW.Print(L.GC_BLOCKED)
        end
    end

    -- For the panel ---------------------------------------------------------------

    Poll.IsOpen = IsOpen
    Poll.MyChoice = MyChoice
    Poll.Tally = Tally
    Poll.Displayable = DisplayableList
    Poll.MayManage = MayManage

    function Poll.Get(id)
        local poll = id and db.polls[id]
        if poll and not poll.stub then
            return poll
        end
        return nil
    end

    function Poll.PlanHello()
        if Poll.helloPlanned or not (C_Timer and C_Timer.After) then
            return
        end
        Poll.helloPlanned = true
        C_Timer.After(POLL_HELLO_DELAY, function()
            if DW.IsMember() then
                PollHello()
            else
                Poll.helloPlanned = false
            end
        end)
    end

    function Poll.ReplayHeld()
        pollHeld:ReplayAll()
    end

    function Poll.Load(saved)
        if type(saved.polls) ~= "table" then
            saved.polls = {}
        end
        if type(saved.pollBannered) ~= "table" then
            saved.pollBannered = {}
        end
        if type(saved.pollHeld) ~= "table" then
            saved.pollHeld = {}
        end
        if type(saved.pollAuthored) ~= "table" then
            saved.pollAuthored = {}
        end
        if type(saved.pollAuthoredSince) ~= "number" then
            -- Started now: versions in my name from before cannot be judged.
            saved.pollAuthoredSince = Now()
        end
        -- Clean out anything that does not look right (e.g. from a corrupted file).
        for id, poll in pairs(saved.polls) do
            local ok = type(id) == "string" and type(poll) == "table" and type(poll.votes) == "table" and type(poll.updated) == "number"
            if ok and not poll.stub then
                ok = type(poll.endsAt) == "number" and type(poll.count) == "number" and type(poll.options) == "table"
            end
            if not ok then
                saved.polls[id] = nil
            else
                poll.id = id
                if not poll.stub then
                    poll.author = type(poll.author) == "string" and poll.author or (AuthorOf(id) or "?")
                    poll.created = tonumber(poll.created) or CreatedOf(id)
                    poll.question = type(poll.question) == "string" and poll.question or ""
                    poll.by = type(poll.by) == "string" and poll.by or poll.author
                    if type(poll.optionParts) ~= "table" then
                        poll.optionParts = nil
                    end
                end
                for voter, vote in pairs(poll.votes) do
                    if type(voter) ~= "string" or type(vote) ~= "table" or type(vote.c) ~= "number" or type(vote.updated) ~= "number" then
                        poll.votes[voter] = nil
                    end
                end
                DedupeVotes(poll)
            end
        end
        pollHeld = DW.NewHeldStore(saved.pollHeld, MODULE_ID .. "-polls")
        PollPurge()
    end

    -- Displayable polls, as copies: { id, question, options, count, endsAt,
    -- author, arrived, created, open, myChoice, total }.
    function DW.Polls()
        local list = {}
        for _, poll in ipairs((DisplayableList())) do
            local options = {}
            for index = 1, poll.count do
                options[index] = poll.options[index]
            end
            local _, _, total = Tally(poll)
            list[#list + 1] = {
                id = poll.id, question = poll.question, options = options, count = poll.count, endsAt = poll.endsAt,
                author = poll.author, arrived = poll.arrived, created = poll.created, open = IsOpen(poll),
                myChoice = MyChoice(poll), total = total,
            }
        end
        table.sort(list, function(a, b)
            if a.endsAt ~= b.endsAt then
                return a.endsAt > b.endsAt
            end
            return a.id > b.id
        end)
        return list
    end

    -- For the tests: our H list, and a new hello plus login banner choice, as after a new login.
    DW.PollHelloEntries = function()
        return (PollHelloLists())
    end

    function DW.RestartPollHello()
        pollLoginDone = false
        pollHelloAt, pollLoginDue = nil, nil
        pollLoginToken = pollLoginToken + 1
        if DW.IsMember() and C_Timer and C_Timer.After then
            C_Timer.After(POLL_HELLO_DELAY, function()
                if DW.IsMember() then
                    PollHello()
                end
            end)
        end
    end

    DW.AddDebug(MODULE_ID, function(add)
        local list = DisplayableList()
        local stored, stubs, broken = 0, 0, 0
        for _, poll in pairs(db.polls) do
            stored = stored + 1
            if poll.stub then
                stubs = stubs + 1
            elseif poll.optionParts then
                broken = broken + 1
            end
        end
        add(("avstemninger lagret: %d | vises: %d | bare stemmer: %d | mangler svar: %d | holdt: %d | i sendekø: %d"):format(
            stored, #list, stubs, broken, pollHeld:Count(), #pollQueue))
    end)
end

-- Actions ---------------------------------------------------------------------

local selectedID -- the suggestion shown on the right
local formOpen = false
local formKind = NEW
local formModule = ""
local filterKind -- nil for all, otherwise NEW or IMPROVE
local view = "active" -- "active" (open suggestions) or "archive" (done and rejected)
local mode = "suggestions" -- the tab shows "suggestions" or "polls"
local PollUI = {}          -- the polls part of the panel (made further down)

-- Creates a new suggestion, agrees with it itself, and sends it to the guild.
local function CreateSuggestion(kind, module, title, note)
    local me = MyKey()
    if not me then
        return nil
    end
    db.seq = (db.seq or 0) + 1
    local now = Now()
    local item = {
        id = ("%s:%d:%d"):format(me, now, db.seq),
        author = me,
        kind = kind,
        module = (kind == IMPROVE) and module or "",
        title = Clean(title, MAX_TITLE_BYTES),
        note = Clean(note, MAX_NOTE_BYTES),
        updated = now,
        votes = { [me] = { v = 1, updated = now } },
    }
    db.items[item.id] = item
    SendItem(item)
    SendVotes(item)
    return item
end

-- Only the one who wrote it may delete a suggestion.
local function DeleteSuggestion(item)
    if item.author ~= MyKey() then
        return
    end
    item.deleted = true
    item.updated = math.max(Now(), item.updated + 1)
    item.title, item.note = "", ""
    SendItem(item)
end

-- Admin: marks the suggestion as done (DONE), rejected (REJECTED) or open
-- again (OPEN), and sends it to the guild.
local function SetStatus(item, status)
    if not DW.IsAdmin() then
        return
    end
    local _, name = DW.CharacterKey()
    item.status = (status ~= OPEN) and status or nil
    item.statusAt = math.max(Now(), (item.statusAt or 0) + 1)
    item.statusBy = name or "?"
    SendStatus(item)
end

-- Agrees, or withdraws the agreement.
local function ToggleVote(item)
    local me = MyKey()
    if not me then
        return
    end
    local current = item.votes[me]
    local v = (current and current.v == 1) and 0 or 1
    local updated = math.max(Now(), current and (current.updated + 1) or 0)
    item.votes[me] = { v = v, updated = updated }
    SendVotes(item, { [me] = true })
end

-- The suggestions that are shown. Open: the ones most people agree with on top, then the newest.
-- Archive: last handled on top.
local function VisibleItems(whichView)
    local archive = (whichView or view) == "archive"
    local list = {}
    for _, item in pairs(db.items) do
        if type(item) == "table" and not item.stub and not item.deleted and IsArchived(item) == archive
            and (filterKind == nil or item.kind == filterKind) then
            list[#list + 1] = item
        end
    end
    local agree = {}
    for _, item in ipairs(list) do
        agree[item] = Agreeing(item)
    end
    table.sort(list, function(a, b)
        if archive and (a.statusAt or 0) ~= (b.statusAt or 0) then
            return (a.statusAt or 0) > (b.statusAt or 0)
        end
        if agree[a] ~= agree[b] then
            return agree[a] > agree[b]
        end
        local ca, cb = CreatedOf(a.id), CreatedOf(b.id)
        if ca ~= cb then
            return ca > cb
        end
        return a.id < b.id
    end)
    return list
end

-- Display ---------------------------------------------------------------------

local LIST_WIDTH = 250
local ROW_HEIGHT = 42

local panel
local rows = {}
local RefreshPanel

local function GetRow(index)
    local row = rows[index]
    if row then
        return row
    end
    row = DW.CreateChip(panel.content, LIST_WIDTH, ROW_HEIGHT - 4)
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
        formOpen = false
        RefreshPanel()
    end)
    rows[index] = row
    return row
end

local function RefreshForm()
    local form = panel.form
    form.heading:SetText(L.SUG_NEW_BUTTON)
    form.hint:SetText(L.SUG_FORM_HINT)
    form.kindNew.label:SetText(L.SUG_KIND_NEW)
    form.kindImprove.label:SetText(L.SUG_KIND_IMPROVE)
    form.kindNew:SetSelected(formKind == NEW)
    form.kindImprove:SetSelected(formKind == IMPROVE)
    form.module.label:SetText(L.SUG_FORM_MODULE:format(ModuleName(formModule)))
    form.module:SetEnabled(formKind == IMPROVE)
    form.module:SetDimmed(formKind ~= IMPROVE)
    form.titleLabel:SetText(L.SUG_FORM_HEADING)
    form.noteLabel:SetText(L.SUG_FORM_NOTE)
    form.send.label:SetText(L.SUG_SEND)
    form.cancel.label:SetText(L.SUG_CANCEL)
end

local function RefreshDetail(item)
    local d = panel.detail
    d.title:SetText(item.title ~= "" and item.title or "?")
    d.meta:SetText(("%s  -  %s  -  %s"):format(KindText(item), ShortName(item.author), date("%d.%m.%Y", CreatedOf(item.id))))
    local count, names = Agreeing(item)
    d.votes:SetText(count > 0 and L.SUG_AGREE_NAMES:format(count, table.concat(names, ", ")) or L.SUG_AGREE_NONE)
    d.note:SetText(item.noteParts and L.SUG_NOTE_COMING or (item.note ~= "" and item.note or L.SUG_NO_NOTE))

    -- Status (in the archive): done in green, rejected in red, with who and when.
    local archived = IsArchived(item)
    if archived then
        d.status:SetText(L.SUG_STATUS_LINE:format(item.status == DONE and L.SUG_STATUS_DONE or L.SUG_STATUS_REJECTED,
            item.statusBy or "?", date("%d.%m.%Y", item.statusAt or 0)))
        if item.status == DONE then
            d.status:SetTextColor(0.40, 0.90, 0.40)
        else
            d.status:SetTextColor(1.00, 0.40, 0.35)
        end
    end
    d.status:SetShown(archived)

    local me = MyKey()
    local mine = me and item.votes[me]
    d.vote.label:SetText((mine and mine.v == 1) and L.SUG_UNVOTE or L.SUG_VOTE)
    d.vote.item = item
    d.vote:SetShown(not archived)
    d.delete.label:SetText(L.SUG_DELETE)
    d.delete.item = item
    d.delete:SetShown(item.author == me)

    -- Admin: mark as done or reject; in the archive: reopen.
    local admin = DW.IsAdmin()
    d.done.item, d.reject.item, d.reopen.item = item, item, item
    d.done.label:SetText(L.SUG_MARK_DONE)
    d.reject.label:SetText(L.SUG_REJECT)
    d.reopen.label:SetText(L.SUG_REOPEN)
    d.done:SetShown(admin and not archived)
    d.reject:SetShown(admin and not archived)
    d.reopen:SetShown(admin and archived)
end

RefreshPanel = function()
    if not panel or not panel:IsVisible() then
        return
    end

    -- Suggestions or polls: the two chips at the top.
    local polls = mode == "polls"
    panel.modes.suggestions.label:SetText(L.SUG_TITLE)
    panel.modes.polls.label:SetText(L.POLL_MODE:format(PollUI.OpenCount()))
    panel.modes.suggestions:SetSelected(not polls)
    panel.modes.polls:SetSelected(polls)
    for _, chip in pairs(panel.filters) do
        chip:SetShown(not polls)
    end
    for _, chip in pairs(panel.views) do
        chip:SetShown(not polls)
    end
    panel.newButton:SetShown(not polls)
    panel.scroll:SetShown(not polls)
    panel.admin:SetShown(not polls)
    PollUI.SetShown(polls)
    if polls then
        panel.form:Hide()
        panel.detail:Hide()
        PollUI.Refresh()
        return
    end

    panel.filters.all.label:SetText(L.SUG_FILTER_ALL)
    panel.filters.new.label:SetText(L.SUG_FILTER_NEW)
    panel.filters.improve.label:SetText(L.SUG_FILTER_IMPROVE)
    panel.filters.all:SetSelected(filterKind == nil)
    panel.filters.new:SetSelected(filterKind == NEW)
    panel.filters.improve:SetSelected(filterKind == IMPROVE)
    panel.newButton.label:SetText(L.SUG_NEW_BUTTON)
    panel.views.active.label:SetText(L.SUG_VIEW_ACTIVE)
    panel.views.archive.label:SetText(L.SUG_VIEW_ARCHIVE:format(#VisibleItems("archive")))
    panel.views.active:SetSelected(view == "active")
    panel.views.archive:SetSelected(view == "archive")
    panel.admin.label:SetText(DW.IsAdmin() and L.SUG_ADMIN_LOGOUT or L.SUG_ADMIN)

    local items = VisibleItems()
    local selected
    for index, item in ipairs(items) do
        local row = GetRow(index)
        row.id = item.id
        row.label:SetText(item.title ~= "" and item.title or "?")
        local count = Agreeing(item)
        local kindText = item.kind == IMPROVE and ModuleName(item.module) or L.SUG_KIND_NEW
        if IsArchived(item) then
            -- In the archive: the status first, in color.
            local status = item.status == DONE and ("|cff66e666" .. L.SUG_STATUS_DONE .. "|r") or ("|cffff6659" .. L.SUG_STATUS_REJECTED .. "|r")
            kindText = status .. "  -  " .. kindText
        end
        row.sub:SetText(("%s  -  %s"):format(kindText, L.SUG_AGREE_COUNT:format(count)))
        row:SetSelected(item.id == selectedID and not formOpen)
        row:Show()
        if item.id == selectedID then
            selected = item
        end
    end
    for index = #items + 1, #rows do
        rows[index]:Hide()
    end
    panel.content:SetHeight(math.max(1, #items * ROW_HEIGHT))

    -- On the right: the form, the selected suggestion, or an explanation.
    panel.form:SetShown(formOpen)
    panel.detail:SetShown(not formOpen and selected ~= nil)
    panel.empty:SetShown(not formOpen and selected == nil)
    if formOpen then
        RefreshForm()
    elseif selected then
        RefreshDetail(selected)
    else
        local any = false
        for _, item in pairs(db.items) do
            if type(item) == "table" and not item.stub and not item.deleted then
                any = true
            end
        end
        if view == "archive" and #items == 0 then
            panel.empty:SetText(L.SUG_ARCHIVE_EMPTY)
        elseif not any then
            panel.empty:SetText(L.SUG_EMPTY)
        elseif #items == 0 then
            panel.empty:SetText(L.SUG_EMPTY_FILTER)
        else
            panel.empty:SetText(L.SUG_PICK)
        end
    end
end

QueueRefresh = function()
    if not panel or not panel:IsVisible() or panel.refreshQueued then
        return
    end
    panel.refreshQueued = true
    C_Timer.After(0.2, function()
        panel.refreshQueued = false
        RefreshPanel()
    end)
end

local function OpenModuleMenu(owner)
    local ids = { "" }
    for _, module in ipairs(DW.moduleOrder) do
        if module.CreatePanel then
            ids[#ids + 1] = module.id
        end
    end
    local function Choose(id)
        formModule = id
        RefreshPanel()
    end
    if not (MenuUtil and MenuUtil.CreateContextMenu) then
        -- Without a menu: go to the next one on each click.
        local nextID = ids[1]
        for index, id in ipairs(ids) do
            if id == formModule then
                nextID = ids[index + 1] or ids[1]
            end
        end
        Choose(nextID)
        return
    end
    MenuUtil.CreateContextMenu(owner, function(_, root)
        root:CreateTitle(L.SUG_MODULE_MENU)
        for _, id in ipairs(ids) do
            root:CreateRadio(ModuleName(id), function(data)
                return formModule == data
            end, Choose, id)
        end
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

local function SubmitForm()
    local form = panel.form
    local title = Clean(form.titleBox:GetText(), MAX_TITLE_BYTES)
    if title == "" then
        form.error:SetText(L.SUG_NEED_TITLE)
        return
    end
    local item = CreateSuggestion(formKind, formModule, title, form.noteBox:GetText())
    if not item then
        return
    end
    form.titleBox:SetText("")
    form.noteBox:SetText("")
    form.error:SetText("")
    formOpen = false
    selectedID = item.id
    RefreshPanel()
end

-- The polls part of the panel ---------------------------------------------------

do
    local OPTION_HEIGHT = 34
    local OPTION_STEP = 38
    local TICK = 61 -- seconds between updates of "time left" while the tab is shown

    local pollView = "open" -- "open" or "ended"
    local selectedPollID
    local pollFormOpen = false
    local formDays = Poll.DEFAULT_DAYS
    local pollRows = {}
    local ticking = false
    local optionWidth = 284 -- set in Create

    -- The open polls first to end on top; ended ones last ended on top.
    local function Lists()
        local openList, endedList = {}, {}
        for _, poll in ipairs((Poll.Displayable())) do
            if Poll.IsOpen(poll) then
                openList[#openList + 1] = poll
            else
                endedList[#endedList + 1] = poll
            end
        end
        table.sort(openList, function(a, b)
            if a.endsAt ~= b.endsAt then
                return a.endsAt < b.endsAt
            end
            return a.id < b.id
        end)
        table.sort(endedList, function(a, b)
            if a.endsAt ~= b.endsAt then
                return a.endsAt > b.endsAt
            end
            return a.id > b.id
        end)
        return openList, endedList
    end

    function PollUI.OpenCount()
        local openList = Lists()
        return #openList
    end

    function PollUI.CloseForm()
        pollFormOpen = false
    end

    local function TimeText(poll)
        local left = poll.endsAt - Now()
        if left <= 0 then
            return L.POLL_ENDED_AT:format(date("%d.%m.%Y", poll.endsAt))
        elseif left >= DAY then
            return L.POLL_LEFT_DAYS:format(math.floor(left / DAY))
        elseif left >= 3600 then
            return L.POLL_LEFT_HOURS:format(math.floor(left / 3600))
        end
        return L.POLL_LEFT_SOON
    end

    local function GetPollRow(index)
        local row = pollRows[index]
        if row then
            return row
        end
        row = DW.CreateChip(panel.pollContent, LIST_WIDTH, ROW_HEIGHT - 4)
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
            selectedPollID = self.id
            pollFormOpen = false
            RefreshPanel()
        end)
        pollRows[index] = row
        return row
    end

    local function RefreshPollForm()
        local pf = panel.pollForm
        pf.heading:SetText(L.POLL_NEW)
        pf.hint:SetText(L.POLL_FORM_HINT)
        pf.qLabel:SetText(L.POLL_FORM_QUESTION)
        pf.oLabel:SetText(L.POLL_FORM_OPTIONS)
        pf.lenLabel:SetText(L.POLL_FORM_LENGTH)
        for index, days in ipairs(Poll.DURATIONS) do
            pf.days[index].label:SetText(L.POLL_DAYS_SHORT:format(days))
            pf.days[index]:SetSelected(formDays == days)
        end
        pf.endsText:SetText(L.POLL_FORM_ENDS:format(date("%d.%m.%Y %H:%M", Now() + formDays * DAY)))
        pf.send.label:SetText(L.POLL_SEND)
        pf.cancel.label:SetText(L.SUG_CANCEL)
    end

    local function RefreshPollDetail(poll)
        local pd = panel.pollDetail
        pd.pollID = poll.id
        local open = Poll.IsOpen(poll)
        local counts, names, total = Poll.Tally(poll)
        local mine = Poll.MyChoice(poll)
        pd.question:SetText(poll.question ~= "" and poll.question or "?")
        local when = open and L.POLL_ENDS_AT or L.POLL_ENDED_AT
        pd.meta:SetText(L.POLL_META:format(DW.OfficerBadge(poll.author) .. ShortName(poll.author),
            when:format(date("%d.%m.%Y %H:%M", poll.endsAt)), total))
        pd.notice:SetText(L.POLL_NOT_SECRET)
        for index, chip in ipairs(pd.options) do
            if index <= poll.count then
                local n = counts[index]
                local share = total > 0 and n / total or 0
                chip.index, chip.open = index, open
                chip.optionText = poll.options[index] or "?"
                chip.allNames = #names[index] > 0 and table.concat(names[index], ", ") or "-"
                chip.tip = (mine == index and L.POLL_TIP_UNVOTE) or (mine ~= 0 and L.POLL_TIP_CHANGE) or L.POLL_TIP_VOTE
                chip.label:SetText(chip.optionText)
                chip.count:SetText(L.POLL_COUNT:format(n, total > 0 and math.floor(n * 100 / total + 0.5) or 0))
                chip.names:SetText(chip.allNames)
                chip.fill:SetWidth(math.max(1, (optionWidth - 6) * share))
                chip:SetSelected(mine == index)
                chip:SetEnabled(open)
                chip:Show()
            else
                chip:Hide()
            end
        end
        pd.optionContent:SetHeight(math.max(1, poll.count * OPTION_STEP))

        -- The author and officers: end now, share, delete.
        local manage = Poll.MayManage(poll)
        pd.endNow.label:SetText(L.POLL_END_NOW)
        pd.share.label:SetText(L.ANN_SHARE)
        pd.delete.label:SetText(L.SUG_DELETE)
        pd.endNow:SetShown(manage and open)
        pd.share:SetShown(manage)
        pd.delete:SetShown(manage)
    end

    function PollUI.Refresh()
        local f = panel
        local openList, endedList = Lists()
        local member = DW.IsMember()
        if not member then
            pollFormOpen = false
        end
        f.pollViews.open.label:SetText(L.POLL_VIEW_OPEN:format(#openList))
        f.pollViews.ended.label:SetText(L.POLL_VIEW_ENDED:format(#endedList))
        f.pollViews.open:SetSelected(pollView == "open")
        f.pollViews.ended:SetSelected(pollView == "ended")
        f.newPoll.label:SetText(L.POLL_NEW)
        f.newPoll:SetShown(member)

        local list = pollView == "open" and openList or endedList
        local selected
        for index, poll in ipairs(list) do
            local row = GetPollRow(index)
            row.id = poll.id
            local mark = (Poll.IsOpen(poll) and Poll.MyChoice(poll) == 0) and "|cffffd100*|r " or ""
            row.label:SetText(mark .. (poll.question ~= "" and poll.question or "?"))
            local _, _, total = Poll.Tally(poll)
            row.sub:SetText(L.POLL_ROW_SUB:format(TimeText(poll), total))
            row:SetSelected(poll.id == selectedPollID and not pollFormOpen)
            row:Show()
            if poll.id == selectedPollID then
                selected = poll
            end
        end
        for index = #list + 1, #pollRows do
            pollRows[index]:Hide()
        end
        f.pollContent:SetHeight(math.max(1, #list * ROW_HEIGHT))

        f.pollForm:SetShown(pollFormOpen)
        f.pollDetail:SetShown(not pollFormOpen and selected ~= nil)
        f.empty:SetShown(not pollFormOpen and selected == nil)
        if pollFormOpen then
            RefreshPollForm()
        elseif selected then
            RefreshPollDetail(selected)
        elseif #openList + #endedList == 0 or (pollView == "open" and #list == 0) then
            f.empty:SetText(L.POLL_EMPTY)
        elseif #list == 0 then
            f.empty:SetText(L.POLL_ENDED_EMPTY)
        else
            f.empty:SetText(L.POLL_PICK)
        end
    end

    function PollUI.SetShown(shown)
        local f = panel
        f.pollViews.open:SetShown(shown)
        f.pollViews.ended:SetShown(shown)
        f.pollScroll:SetShown(shown)
        if not shown then
            f.newPoll:Hide()
            f.pollDetail:Hide()
            f.pollForm:Hide()
        end
    end

    -- Keeps "time left" right while the tab is shown; stops when it is hidden.
    function PollUI.StartTicking()
        if ticking then
            return
        end
        ticking = true
        local function Tick()
            if not panel or not panel:IsVisible() then
                ticking = false
                return
            end
            RefreshPanel()
            C_Timer.After(TICK, Tick)
        end
        C_Timer.After(TICK, Tick)
    end

    -- Opens the Forslag tab on the polls, with the poll id selected.
    function DW.OpenPoll(id)
        DW.OpenModule(MODULE_ID)
        mode = "polls"
        formOpen = false
        pollFormOpen = false
        local poll = Poll.Get(id)
        if poll then
            pollView = Poll.IsOpen(poll) and "open" or "ended"
            selectedPollID = poll.id
        end
        RefreshPanel()
    end

    local function SelectedPoll()
        local pd = panel.pollDetail
        local poll = Poll.Get(pd.pollID)
        if poll and not poll.deleted then
            return poll
        end
        return nil
    end

    local function SubmitPollForm()
        local pf = panel.pollForm
        local texts = {}
        for index, box in ipairs(pf.optBoxes) do
            texts[index] = box:GetText()
        end
        local poll, problem = Poll.Create(pf.qBox:GetText(), texts, formDays)
        if not poll then
            pf.error:SetText(problem or "")
            return
        end
        pf.qBox:SetText("")
        for _, box in ipairs(pf.optBoxes) do
            box:SetText("")
        end
        pf.error:SetText("")
        pollFormOpen = false
        pollView = "open"
        selectedPollID = poll.id
        RefreshPanel()
    end

    local function ShowOptionTip(chip)
        GameTooltip:SetOwner(chip, "ANCHOR_RIGHT")
        GameTooltip:AddLine(chip.optionText or "?", 1, 1, 1, true)
        GameTooltip:AddLine(chip.allNames or "-", 0.75, 0.75, 0.75, true)
        if chip.open then
            GameTooltip:AddLine(chip.tip, 0.40, 0.90, 0.40, true)
        end
        GameTooltip:Show()
    end

    local function CreateOption(content, index)
        local chip = DW.CreateChip(content, optionWidth, OPTION_HEIGHT)
        chip:SetPoint("TOPLEFT", 0, -(index - 1) * OPTION_STEP)
        -- How many voted for it, as a bar behind the text.
        chip.fill = chip:CreateTexture(nil, "BACKGROUND", nil, 1)
        chip.fill:SetColorTexture(1, 0.82, 0, 0.18)
        chip.fill:SetPoint("LEFT", 3, 0)
        chip.fill:SetHeight(OPTION_HEIGHT - 6)
        chip.label:ClearAllPoints()
        chip.label:SetPoint("TOPLEFT", 10, -4)
        chip.label:SetPoint("TOPRIGHT", -70, -4)
        chip.count = chip:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
        chip.count:SetPoint("TOPRIGHT", -10, -4)
        chip.count:SetJustifyH("RIGHT")
        chip.names = chip:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
        chip.names:SetTextColor(0.70, 0.70, 0.70)
        chip.names:SetPoint("BOTTOMLEFT", 10, 4)
        chip.names:SetPoint("BOTTOMRIGHT", -10, 4)
        chip.names:SetJustifyH("LEFT")
        chip.names:SetWordWrap(false)
        chip:SetScript("OnClick", function(self)
            local poll = SelectedPoll()
            if poll and self.index then
                Poll.Vote(poll, self.index)
                RefreshPanel()
                if self:IsMouseOver() then
                    ShowOptionTip(self)
                end
            end
        end)
        chip:HookScript("OnEnter", ShowOptionTip)
        chip:HookScript("OnLeave", function()
            GameTooltip:Hide()
        end)
        return chip
    end

    local function CreateDetail(f, rightX, width)
        local pd = CreateFrame("Frame", nil, f)
        pd:SetPoint("TOPLEFT", rightX, -76)
        pd:SetSize(width, 346)
        f.pollDetail = pd

        -- Each part hangs under the one above, so a long question pushes the rest down.
        pd.question = pd:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
        pd.question:SetPoint("TOPLEFT", 0, -2)
        pd.question:SetWidth(width)
        pd.question:SetJustifyH("LEFT")

        pd.meta = pd:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
        pd.meta:SetPoint("TOPLEFT", pd.question, "BOTTOMLEFT", 0, -6)
        pd.meta:SetWidth(width)
        pd.meta:SetJustifyH("LEFT")

        pd.notice = pd:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
        pd.notice:SetPoint("TOPLEFT", pd.meta, "BOTTOMLEFT", 0, -4)
        pd.notice:SetWidth(width)
        pd.notice:SetJustifyH("LEFT")
        pd.notice:SetTextColor(0.70, 0.70, 0.70)

        -- The answers scroll if they do not fit above the buttons.
        pd.optionScroll = CreateFrame("ScrollFrame", "DragonworldPollOptions", pd, "ScrollFrameTemplate")
        pd.optionScroll:SetPoint("TOPLEFT", pd.notice, "BOTTOMLEFT", 0, -6)
        pd.optionScroll:SetPoint("BOTTOMRIGHT", pd, "BOTTOMRIGHT", -(width - optionWidth), 32)
        pd.optionContent = CreateFrame("Frame", nil, pd.optionScroll)
        pd.optionContent:SetSize(optionWidth, 1)
        pd.optionScroll:SetScrollChild(pd.optionContent)
        pd.options = {}
        for index = 1, Poll.MAX_OPTIONS do
            pd.options[index] = CreateOption(pd.optionContent, index)
        end

        -- Tools for the author and officers in the bottom row. No question
        -- first, as elsewhere in the addon.
        -- Widths at 304 px: End now 0-96, Share 100-224, Delete 232-304.
        pd.endNow = DW.CreateButton(pd, 96, 26, "gold")
        pd.endNow:SetPoint("BOTTOMLEFT", 0, 0)
        pd.endNow:SetScript("OnClick", function()
            local poll = SelectedPoll()
            if poll then
                Poll.EndNow(poll)
                if not Poll.IsOpen(poll) then
                    pollView = "ended"
                end
                RefreshPanel()
            end
        end)
        pd.share = DW.CreateChip(pd, 124, 26)
        pd.share:SetPoint("BOTTOMLEFT", 100, 0)
        -- The small font and narrow insets, so "Im Gildenchat posten" fits.
        pd.share.label:SetFontObject("GameFontHighlightSmall")
        pd.share.label:ClearAllPoints()
        pd.share.label:SetPoint("LEFT", 4, 0)
        pd.share.label:SetPoint("RIGHT", -4, 0)
        pd.share.label:SetJustifyH("CENTER")
        pd.share:SetScript("OnClick", function()
            local poll = SelectedPoll()
            if poll then
                Poll.Share(poll)
            end
        end)
        pd.delete = DW.CreateButton(pd, 72, 26, "red")
        pd.delete:SetPoint("BOTTOMRIGHT", 0, 0)
        pd.delete:SetScript("OnClick", function()
            local poll = SelectedPoll()
            if poll then
                Poll.Delete(poll)
                selectedPollID = nil
                RefreshPanel()
            end
        end)
    end

    local function CreateForm(f, rightX, width, height)
        local pf = CreateFrame("Frame", nil, f)
        pf:SetPoint("TOPLEFT", rightX, -76)
        pf:SetSize(width, height)
        f.pollForm = pf

        pf.heading = pf:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
        pf.heading:SetPoint("TOPLEFT", 0, -2)

        pf.hint = pf:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
        pf.hint:SetPoint("TOPLEFT", 0, -24)
        pf.hint:SetWidth(width)
        pf.hint:SetJustifyH("LEFT")

        pf.qLabel = pf:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
        pf.qLabel:SetPoint("TOPLEFT", 0, -62)
        pf.qBox = CreateEditBox(pf, width - 8, Poll.MAX_QUESTION_LETTERS)
        pf.qBox:SetPoint("TOPLEFT", 6, -78)

        pf.oLabel = pf:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
        pf.oLabel:SetPoint("TOPLEFT", 0, -106)
        pf.optBoxes = {}
        local half = math.floor((width - 16) / 2)
        for index = 1, Poll.MAX_OPTIONS do
            local box = CreateEditBox(pf, half, Poll.MAX_OPTION_LETTERS)
            box:SetPoint("TOPLEFT", 6 + ((index - 1) % 2) * (half + 8), -122 - math.floor((index - 1) / 2) * 24)
            pf.optBoxes[index] = box
        end

        pf.lenLabel = pf:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
        pf.lenLabel:SetPoint("TOPLEFT", 0, -200)
        pf.days = {}
        for index, days in ipairs(Poll.DURATIONS) do
            local chip = DW.CreateChip(pf, 48, 24)
            chip:SetPoint("TOPLEFT", (index - 1) * 51, -216)
            chip.label:ClearAllPoints()
            chip.label:SetPoint("LEFT", 2, 0)
            chip.label:SetPoint("RIGHT", -2, 0)
            chip.label:SetJustifyH("CENTER")
            chip:SetScript("OnClick", function()
                formDays = days
                RefreshPanel()
            end)
            pf.days[index] = chip
        end

        pf.endsText = pf:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
        pf.endsText:SetPoint("TOPLEFT", 0, -246)
        pf.endsText:SetWidth(width)
        pf.endsText:SetJustifyH("LEFT")

        pf.error = pf:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
        pf.error:SetTextColor(1.00, 0.35, 0.30)
        pf.error:SetPoint("TOPLEFT", 0, -264)
        pf.error:SetWidth(width)
        pf.error:SetJustifyH("LEFT")

        pf.send = DW.CreateButton(pf, 150, 28, "gold")
        pf.send:SetPoint("BOTTOMLEFT", 0, 0)
        pf.send:SetScript("OnClick", SubmitPollForm)

        pf.cancel = DW.CreateChip(pf, 120, 28)
        pf.cancel:SetPoint("BOTTOMRIGHT", 0, 0)
        pf.cancel.label:SetJustifyH("CENTER")
        pf.cancel:SetScript("OnClick", function()
            pollFormOpen = false
            RefreshPanel()
        end)
    end

    function PollUI.Create(f, rightX, width, bodyHeight)
        optionWidth = width - 20 -- room for the scroll bar on the right

        f.pollViews = {}
        for index, name in ipairs({ "open", "ended" }) do
            local chip = DW.CreateChip(f, 130, 26)
            chip:SetPoint("TOPLEFT", 14 + (index - 1) * 136, -40)
            chip.label:SetJustifyH("CENTER")
            chip:SetScript("OnClick", function()
                pollView = name
                pollFormOpen = false
                RefreshPanel()
            end)
            f.pollViews[name] = chip
        end

        local scroll = CreateFrame("ScrollFrame", "DragonworldPollScroll", f, "ScrollFrameTemplate")
        scroll:SetPoint("TOPLEFT", 10, -76)
        scroll:SetSize(LIST_WIDTH, bodyHeight - 50)
        f.pollContent = CreateFrame("Frame", nil, scroll)
        f.pollContent:SetSize(LIST_WIDTH, 1)
        scroll:SetScrollChild(f.pollContent)
        f.pollScroll = scroll

        f.newPoll = DW.CreateButton(f, LIST_WIDTH, 30, "gold")
        f.newPoll:SetPoint("BOTTOMLEFT", 10, 12)
        f.newPoll:SetScript("OnClick", function()
            if DW.IsMember() then
                pollFormOpen = true
                f.pollForm.error:SetText("")
            end
            RefreshPanel()
        end)

        CreateDetail(f, rightX, width)
        CreateForm(f, rightX, width, bodyHeight - 16)
        PollUI.SetShown(false)
    end
end

local function CreatePanel(parent)
    local width, height = parent:GetWidth(), parent:GetHeight()
    local bodyHeight = height - 72

    local f = CreateFrame("Frame", nil, parent)
    f:SetAllPoints(parent)
    panel = f

    -- Suggestions or polls.
    f.modes = {}
    for index, name in ipairs({ "suggestions", "polls" }) do
        local chip = DW.CreateChip(f, 160, 26)
        chip:SetPoint("TOPLEFT", 14 + (index - 1) * 166, -8)
        chip.label:SetJustifyH("CENTER")
        chip:SetScript("OnClick", function()
            mode = name
            formOpen = false
            PollUI.CloseForm()
            RefreshPanel()
        end)
        f.modes[name] = chip
    end

    -- Admin: log in with the code (Admin.lua), or out again. Top right, clear
    -- of the mode chips; shown with the suggestions only.
    f.admin = DW.CreateChip(f, 110, 26)
    f.admin:SetPoint("TOPRIGHT", -14, -8)
    f.admin.label:SetJustifyH("CENTER")
    f.admin:SetScript("OnClick", function()
        if DW.IsAdmin() then
            DW.AdminLogout()
        else
            DW.ShowAdminLogin()
        end
    end)

    -- Filter: all, new things, improvements.
    f.filters = {}
    for index, name in ipairs({ "all", "new", "improve" }) do
        local chip = DW.CreateChip(f, 120, 26)
        chip:SetPoint("TOPLEFT", 14 + (index - 1) * 126, -40)
        chip.label:SetJustifyH("CENTER")
        chip:SetScript("OnClick", function()
            filterKind = (name == "new" and NEW) or (name == "improve" and IMPROVE) or nil
            RefreshPanel()
        end)
        f.filters[name] = chip
    end

    -- Open suggestions, or the archive with the done and rejected ones.
    f.views = {}
    for index, name in ipairs({ "active", "archive" }) do
        local chip = DW.CreateChip(f, 100, 26)
        chip:SetPoint("TOPLEFT", 14 + 3 * 126 + (index - 1) * 106, -40)
        chip.label:SetJustifyH("CENTER")
        chip:SetScript("OnClick", function()
            view = name
            formOpen = false
            RefreshPanel()
        end)
        f.views[name] = chip
    end

    -- The list on the left.
    local scroll = CreateFrame("ScrollFrame", "DragonworldForslagScroll", f, "ScrollFrameTemplate")
    scroll:SetPoint("TOPLEFT", 10, -76)
    scroll:SetSize(LIST_WIDTH, bodyHeight - 50)
    f.scroll = scroll
    f.content = CreateFrame("Frame", nil, scroll)
    f.content:SetSize(LIST_WIDTH, 1)
    scroll:SetScrollChild(f.content)

    f.newButton = DW.CreateButton(f, LIST_WIDTH, 30, "gold")
    f.newButton:SetPoint("BOTTOMLEFT", 10, 12)
    f.newButton:SetScript("OnClick", function()
        formOpen = true
        f.form.error:SetText("")
        RefreshPanel()
    end)

    local rightX = 10 + LIST_WIDTH + 34
    local rightWidth = width - rightX - 14

    f.empty = f:CreateFontString(nil, "OVERLAY", "GameFontDisable")
    f.empty:SetPoint("TOPLEFT", rightX, -106)
    f.empty:SetWidth(rightWidth)
    f.empty:SetJustifyH("LEFT")

    -- The selected suggestion.
    local d = CreateFrame("Frame", nil, f)
    d:SetPoint("TOPLEFT", rightX, -76)
    d:SetSize(rightWidth, bodyHeight - 16)
    f.detail = d

    d.title = d:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
    d.title:SetPoint("TOPLEFT", 0, -2)
    d.title:SetWidth(rightWidth)
    d.title:SetJustifyH("LEFT")

    d.meta = d:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    d.meta:SetPoint("TOPLEFT", d.title, "BOTTOMLEFT", 0, -6)
    d.meta:SetWidth(rightWidth)
    d.meta:SetJustifyH("LEFT")

    d.votes = d:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    d.votes:SetPoint("TOPLEFT", d.meta, "BOTTOMLEFT", 0, -4)
    d.votes:SetWidth(rightWidth)
    d.votes:SetJustifyH("LEFT")

    d.note = d:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
    d.note:SetPoint("TOPLEFT", d.votes, "BOTTOMLEFT", 0, -10)
    d.note:SetWidth(rightWidth)
    d.note:SetJustifyH("LEFT")

    d.vote = DW.CreateButton(d, 170, 28, "gold")
    d.vote:SetPoint("BOTTOMLEFT", 0, 0)
    d.vote:SetScript("OnClick", function(self)
        if self.item then
            ToggleVote(self.item)
            RefreshPanel()
        end
    end)

    -- Delete: only for the one who wrote the suggestion. No question first, as
    -- elsewhere in the addon.
    d.delete = DW.CreateButton(d, 100, 28, "red")
    d.delete:SetPoint("BOTTOMRIGHT", 0, 0)
    d.delete:SetScript("OnClick", function(self)
        if self.item then
            DeleteSuggestion(self.item)
            selectedID = nil
            RefreshPanel()
        end
    end)

    -- The status in the archive: "Done by X, date".
    d.status = d:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    d.status:SetPoint("BOTTOMLEFT", 0, 70)
    d.status:SetWidth(rightWidth)
    d.status:SetJustifyH("LEFT")

    -- Admin: done or rejected (moved to the archive), or reopen.
    local function StatusButton(button, status)
        button:SetScript("OnClick", function(self)
            if self.item then
                SetStatus(self.item, status)
                RefreshPanel()
            end
        end)
        return button
    end
    d.done = StatusButton(DW.CreateButton(d, 145, 26, "gold"), DONE)
    d.done:SetPoint("BOTTOMLEFT", 0, 34)
    d.reject = StatusButton(DW.CreateButton(d, 145, 26, "red"), REJECTED)
    d.reject:SetPoint("BOTTOMRIGHT", 0, 34)
    d.reopen = StatusButton(DW.CreateButton(d, 170, 26, "gold"), OPEN)
    d.reopen:SetPoint("BOTTOMLEFT", 0, 34)

    -- The form for a new suggestion.
    local form = CreateFrame("Frame", nil, f)
    form:SetPoint("TOPLEFT", rightX, -76)
    form:SetSize(rightWidth, bodyHeight - 16)
    f.form = form

    form.heading = form:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
    form.heading:SetPoint("TOPLEFT", 0, -2)

    form.hint = form:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    form.hint:SetPoint("TOPLEFT", 0, -26)
    form.hint:SetWidth(rightWidth)
    form.hint:SetJustifyH("LEFT")

    local half = math.floor((rightWidth - 6) / 2)
    form.kindNew = DW.CreateChip(form, half, 26)
    form.kindNew:SetPoint("TOPLEFT", 0, -62)
    form.kindNew.label:SetJustifyH("CENTER")
    form.kindNew:SetScript("OnClick", function()
        formKind = NEW
        RefreshPanel()
    end)
    form.kindImprove = DW.CreateChip(form, half, 26)
    form.kindImprove:SetPoint("TOPLEFT", half + 6, -62)
    form.kindImprove.label:SetJustifyH("CENTER")
    form.kindImprove:SetScript("OnClick", function()
        formKind = IMPROVE
        RefreshPanel()
    end)

    form.module = DW.CreateChip(form, rightWidth, 26)
    form.module:SetPoint("TOPLEFT", 0, -94)
    form.module:SetScript("OnClick", function(self)
        OpenModuleMenu(self)
    end)

    form.titleLabel = form:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    form.titleLabel:SetPoint("TOPLEFT", 0, -130)
    form.titleBox = CreateEditBox(form, rightWidth - 8, MAX_TITLE_LETTERS)
    form.titleBox:SetPoint("TOPLEFT", 6, -146)

    form.noteLabel = form:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    form.noteLabel:SetPoint("TOPLEFT", 0, -176)

    -- The description spans several lines, in a frame of its own.
    local holder = CreateFrame("Frame", nil, form, "BackdropTemplate")
    holder:SetPoint("TOPLEFT", 0, -192)
    holder:SetSize(rightWidth, 84)
    holder:SetBackdrop(DW.PANEL_BACKDROP)
    holder:SetBackdropColor(0, 0, 0, 0.6)
    holder:SetBackdropBorderColor(0.45, 0.45, 0.45, 1)
    form.noteBox = CreateFrame("EditBox", nil, holder)
    form.noteBox:SetMultiLine(true)
    form.noteBox:SetFontObject(ChatFontNormal or "ChatFontNormal")
    form.noteBox:SetPoint("TOPLEFT", 8, -6)
    form.noteBox:SetSize(rightWidth - 16, 72)
    form.noteBox:SetAutoFocus(false)
    form.noteBox:SetMaxLetters(MAX_NOTE_LETTERS)
    form.noteBox:SetScript("OnEscapePressed", function(self)
        self:ClearFocus()
    end)
    holder:EnableMouse(true)
    holder:SetScript("OnMouseDown", function()
        form.noteBox:SetFocus()
    end)

    form.error = form:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    form.error:SetTextColor(1.00, 0.35, 0.30)
    form.error:SetPoint("TOPLEFT", 0, -282)
    form.error:SetWidth(rightWidth)
    form.error:SetJustifyH("LEFT")

    form.send = DW.CreateButton(form, 150, 28, "gold")
    form.send:SetPoint("BOTTOMLEFT", 0, 0)
    form.send:SetScript("OnClick", SubmitForm)

    form.cancel = DW.CreateChip(form, 120, 28)
    form.cancel:SetPoint("BOTTOMRIGHT", 0, 0)
    form.cancel.label:SetJustifyH("CENTER")
    form.cancel:SetScript("OnClick", function()
        formOpen = false
        RefreshPanel()
    end)

    -- The polls: their list, the selected poll and the form.
    PollUI.Create(f, rightX, rightWidth, bodyHeight)

    f:SetScript("OnShow", function()
        RefreshPanel()
        PollUI.StartTicking()
    end)
    return f
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
    -- The polls say hello a little later, on their own message name.
    Poll.PlanHello()
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
    RefreshPanel()
end)

-- Logged in or out as admin: show or hide the status buttons.
DW.OnAdminChanged(function()
    RefreshPanel()
end)

-- Promoted, demoted or a new officer limit: try held polls again, and show or
-- hide the officer tools on polls.
DW.OnOfficersChanged(function()
    Poll.ReplayHeld()
    RefreshPanel()
end)

-- Module -------------------------------------------------------------------------

DW.RegisterModule({
    id = MODULE_ID,
    titleKey = "SUG_TITLE",
    notesKey = "SUG_NOTES",
    icon = "Interface\\Icons\\INV_Misc_Note_01",

    OnLoad = function(self, saved)
        if type(saved.items) ~= "table" then
            saved.items = {}
        end
        -- Clean out anything that does not look right (e.g. from a corrupted file).
        for id, item in pairs(saved.items) do
            if type(id) ~= "string" or type(item) ~= "table" or type(item.votes) ~= "table" or type(item.updated) ~= "number" then
                saved.items[id] = nil
            end
        end
        db = saved
        -- Left by a test build (statuses and deletions held for trust reasons).
        saved.held = nil
        Poll.Load(saved)
    end,

    CreatePanel = function(self, parent)
        return CreatePanel(parent)
    end,
})

-- The Home page (Modules\Home.lua) ------------------------------------------------

-- Polls: new ones since you last played, and open ones you have not voted in.
DW.RegisterHomeSection({
    id = "polls",
    order = 25,
    titleKey = "HOME_SEC_POLLS",
    icon = "Interface\\Icons\\INV_Misc_Note_01",
    Lines = function(ctx)
        local lines, me = {}, MyKey()
        for _, poll in ipairs(DW.Polls()) do
            if poll.open then
                local ends = date("%d.%m %H:%M", poll.endsAt)
                local arrived = poll.arrived or poll.created or 0
                local open = function()
                    DW.OpenPoll(poll.id)
                end
                if ctx.since and arrived > ctx.since and poll.author ~= me then
                    lines[#lines + 1] = { text = L.HOME_POLL_NEW:format(poll.question or "?", ends), when = arrived, changed = true,
                        onClick = open, tab = MODULE_ID }
                elseif (poll.myChoice or 0) == 0 then
                    lines[#lines + 1] = { text = L.HOME_POLL_OPEN:format(poll.question or "?", ends), changed = false,
                        onClick = open, tab = MODULE_ID }
                end
            end
        end
        return lines
    end,
})

-- Suggestions: new ones from others, and a status set on one of yours.
DW.RegisterHomeSection({
    id = "suggestions",
    order = 60,
    titleKey = "HOME_SEC_SUGGESTIONS",
    icon = "Interface\\Icons\\INV_Misc_Note_01",
    Lines = function(ctx)
        local since = ctx.since
        if not since then
            return {}
        end
        local lines, me = {}, MyKey()
        for _, item in pairs(db.items) do
            if type(item) == "table" and not item.stub and not item.deleted then
                local archived = IsArchived(item)
                local created = tonumber(item.id:match(":(%d+):%d+$")) or 0
                local text, when
                if item.author ~= me and not archived and (created > since or (item.arrived or 0) > since) then
                    when = math.max(created, item.arrived or 0)
                    text = L.HOME_SUG_NEW:format(ShortName(item.author), item.title ~= "" and item.title or "?")
                elseif item.author == me and archived and (item.statusAt or 0) > since then
                    when = item.statusAt
                    text = L.HOME_SUG_STATUS:format(item.title ~= "" and item.title or "?",
                        item.status == DONE and L.SUG_STATUS_DONE or L.SUG_STATUS_REJECTED, item.statusBy or "?")
                end
                if text then
                    local id = item.id
                    lines[#lines + 1] = {
                        text = text, when = when, changed = true, tab = MODULE_ID, id = id,
                        onClick = function()
                            local target = db.items[id]
                            mode, formOpen, filterKind = "suggestions", false, nil
                            view = (target and IsArchived(target)) and "archive" or "active"
                            selectedID = id
                            DW.OpenModule(MODULE_ID)
                            RefreshPanel()
                        end,
                    }
                end
            end
        end
        table.sort(lines, function(a, b)
            if a.when ~= b.when then
                return a.when > b.when
            end
            return a.id < b.id
        end)
        return lines
    end,
})
