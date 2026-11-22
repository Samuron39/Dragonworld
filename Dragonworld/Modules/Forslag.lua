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
-- author is online). A deleted suggestion is remembered for a month, and then
-- forgotten.
--
-- Admin (Admin.lua, login with a code) can mark a suggestion as done or
-- rejected. It is then moved to the archive, with status, who and when; admin
-- can also reopen it. The status has its own timestamp, and the newest wins.
-- The others in the guild cannot check that the sender really is admin.
--
-- There is no real access control: everyone in the guild can in principle send
-- anything.
--
-- The messages (name DragonworldSug, fields separated by tab):
--   F id changed deleted type module parts title      a suggestion
--   N id changed no text                              a piece of the description
--   B id player,agree,time ...                        who agrees
--   S id status time who                              status: D done, R rejected, O open again
--   H id,changed,count,newest ...   and then   Q      what I have ("newest" includes the status)
--   G id ...                                          send me these
--
-- All text is in Locales.lua (the names that start with SUG_).

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
local db = { items = {} }

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
local function SayHello()
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
    SendList("H", entries)
    Send("Q")
    SendList("G", broken)
end

-- Receiving -------------------------------------------------------------------

-- Receives a suggestion. Returns true if something changed.
local function ApplyItem(id, updated, deleted, kind, module, parts, title)
    local author = AuthorOf(id)
    if not author or #id > 80 or updated > Now() + DAY or (kind ~= NEW and kind ~= IMPROVE) then
        return false
    end
    if parts < 0 or parts > MAX_PARTS then
        return false
    end
    if #module > 20 or not module:match("^[%l%d]*$") then
        module = ""
    end

    local item = db.items[id]
    -- The same version is accepted again only if we were missing parts of the description.
    if item and not item.stub and (updated < item.updated or (updated == item.updated and not item.noteParts)) then
        return false
    end
    if not item then
        item = { id = id, votes = {} }
        db.items[id] = item
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
    return author ~= nil and DW.NameKey(author) == DW.NameKey(sender)
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
        if id ~= "" and updated and parts and (not deleted or FromAuthor(id, sender)) then
            changed = ApplyItem(id, updated, deleted, fields[5], fields[6], parts, fields[8])
            -- If the rest of the description does not arrive, we ask for the suggestion again.
            local item = db.items[id]
            if changed and item.noteParts then
                C_Timer.After(NOTE_WAIT, function()
                    if db.items[id] == item and item.noteParts and item.updated == updated then
                        wanted[id] = true
                        ScheduleExchange()
                    end
                end)
            end
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

-- Actions ---------------------------------------------------------------------

local selectedID -- the suggestion shown on the right
local formOpen = false
local formKind = NEW
local formModule = ""
local filterKind -- nil for all, otherwise NEW or IMPROVE
local view = "active" -- "active" (open suggestions) or "archive" (done and rejected)

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

    panel.title:SetText(L.SUG_PANEL_TITLE)
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

local function CreatePanel(parent)
    local width, height = parent:GetWidth(), parent:GetHeight()
    local bodyHeight = height - 72

    local f = CreateFrame("Frame", nil, parent)
    f:SetAllPoints(parent)
    panel = f

    f.title = f:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
    f.title:SetPoint("TOP", 0, -12)

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

    -- Admin: log in with the code (Admin.lua), or out again.
    f.admin = DW.CreateChip(f, 110, 22)
    f.admin:SetPoint("TOPRIGHT", -10, -10)
    f.admin.label:SetJustifyH("CENTER")
    f.admin:SetScript("OnClick", function()
        if DW.IsAdmin() then
            DW.AdminLogout()
        else
            DW.ShowAdminLogin()
        end
    end)

    -- The list on the left.
    local scroll = CreateFrame("ScrollFrame", "DragonworldForslagScroll", f, "ScrollFrameTemplate")
    scroll:SetPoint("TOPLEFT", 10, -76)
    scroll:SetSize(LIST_WIDTH, bodyHeight - 50)
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

    f:SetScript("OnShow", function()
        RefreshPanel()
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

-- Logged in or out as admin: show or hide the buttons.
DW.OnAdminChanged(function()
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
    end,

    CreatePanel = function(self, parent)
        return CreatePanel(parent)
    end,
})
