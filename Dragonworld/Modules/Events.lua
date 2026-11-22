-- Dragonworld - Guild events
-- Two things in one module:
--   1. Our own events with sign-ups. A member creates an event, everyone in the
--      guild who has the addon gets it, and each one answers Coming / Maybe /
--      Not coming.
--   2. An overview of what is in the game's own calendar.
--
-- How events are shared between members:
--   * The addon sends small messages on the guild channel that only other
--     addons see. Nothing shows up in chat.
--   * Every event and every sign-up has a timestamp. If two versions of the
--     same thing arrive, the newest wins.
--   * When you log in, the addon sends a short list of what you have. Those who
--     are online answer with what you are missing, and ask for what they are
--     missing themselves. Someone who was offline when an event was created
--     gets it the next time they are online at the same time as someone who
--     has it.
--   * The game allows about one message per second and 255 characters per
--     message. Messages are therefore queued, and title and description have
--     a maximum length.
--
-- Limitations worth knowing about:
--   * Only the one who created an event can delete it (in the window). There
--     is no real access control: anyone in the guild can in principle send
--     anything.
--   * Events disappear from the list 12 hours after the start, and are
--     forgotten completely after a week.
--
-- All text is in Locales.lua (the names that start with EV_).

local ADDON_NAME, DW = ...
local L = DW.L

local MODULE_ID = "events"
local PREFIX = "DragonworldEv" -- the name of the messages; max 16 characters
local SEP = "\t"               -- separates the fields in a message

local HOUR, DAY = 3600, 86400
local SHOW_AFTER_START = 12 * HOUR -- how long after the start an event is shown
local KEEP_AFTER_START = 7 * DAY   -- how long after the start it is remembered and shared
local MAX_TITLE_BYTES = 60
local MAX_NOTE_BYTES = 100
local MAX_MESSAGE_BYTES = 250      -- the game's limit is 255

local STATUSES = { "Y", "M", "N" } -- coming, maybe, not coming
local STATUS_KEY = { Y = "EV_YES", M = "EV_MAYBE", N = "EV_NO" }

-- Saved data. Set in OnLoad at the bottom.
--   db.events[id] = {
--       id, creator, title, note,
--       when     = the time the event starts,
--       updated  = when it was last changed (newest version wins),
--       deleted  = true if it is deleted (kept so the deletion spreads),
--       signups  = { ["Navn-Realm"] = { status = "Y"/"M"/"N", updated, class } },
--       arrived  = when we got it from someone else (server clock), for the blinking
--   }
--   db.seq = counter that makes every id unique
local db = { events = {} }

-- Small things ------------------------------------------------------------------

local function Num(value)
    return ("%d"):format(value)
end

local function MyKey()
    return (DW.CharacterKey())
end

local function ShortName(key)
    return (type(key) == "string" and key:match("^([^-]+)")) or tostring(key)
end

-- Cuts a text to a number of bytes without leaving half a character
-- (æ, ø and å are two bytes each).
local function Truncate(text, maxBytes)
    if #text <= maxBytes then
        return text
    end
    text = text:sub(1, maxBytes)
    while #text > 0 and text:byte(-1) >= 128 and text:byte(-1) < 192 do
        text = text:sub(1, -2)
    end
    if #text > 0 and text:byte(-1) >= 192 then
        text = text:sub(1, -2)
    end
    return text
end

-- Cleans text that is to be sent or shown: removes line breaks, tabs and the
-- character | (which the game uses for colors and links), and cuts the length.
local function Clean(text, maxBytes)
    text = tostring(text or "")
    text = text:gsub("[%c|]", " ")
    text = text:gsub("^%s+", "")
    text = text:gsub("%s+$", "")
    return Truncate(text, maxBytes)
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

-- An id looks like this: "Navn-Realm:time:counter". The one who created the
-- event is thus first.
local function CreatorOf(id)
    return id:match("^(.+):%d+:%d+$")
end

-- Should the event still be remembered and shared?
local function Syncable(event)
    return not event.stub and type(event.when) == "number" and event.when > time() - KEEP_AFTER_START
end

-- Number of sign-ups and the timestamp of the newest. Used to detect that
-- two members have different sign-ups for the same event.
local function Digest(event)
    local count, newest = 0, 0
    for _, signup in pairs(event.signups) do
        count = count + 1
        if signup.updated > newest then
            newest = signup.updated
        end
    end
    return count, newest
end

local function PurgeExpired()
    for id, event in pairs(db.events) do
        if type(event) ~= "table" or type(event.signups) ~= "table" or not Syncable(event) then
            db.events[id] = nil
        end
    end
end

-- Sending -----------------------------------------------------------------------

-- The queue and the pacing are in Comm.lua. Send queues a message to the guild.
local Send = DW.CreateSender(PREFIX)

-- Versions we have seen sent (by us or others) since someone last asked for them.
-- Used to avoid sending what someone else has already sent.
local seen = { events = {}, signups = {} }

local function MarkSeenEvent(id, updated)
    if updated > (seen.events[id] or -1) then
        seen.events[id] = updated
    end
end

local function MarkSeenSignup(id, player, updated)
    local players = seen.signups[id]
    if not players then
        players = {}
        seen.signups[id] = players
    end
    if updated > (players[player] or -1) then
        players[player] = updated
    end
end

local function CountKeys(tbl)
    local count = 0
    for _ in pairs(tbl or {}) do
        count = count + 1
    end
    return count
end

-- Who the event is for, as text in the message: "A" for all, "L20-40" for a
-- level range, "P7" for seven picked members (who they are is sent in separate
-- messages). In front is 0 if it should not go in the game's calendar, 1 if it
-- should, and 2 if it should, but the creator could not make a guild event
-- (then each member puts it in their own calendar).
local function MetaOf(event)
    local spec = "A"
    if event.aud == "L" then
        spec = ("L%d-%d"):format(event.min or 1, event.max or 99)
    elseif event.aud == "P" then
        spec = ("P%d"):format(event.invitedCount or CountKeys(event.invited))
    end
    return (event.cal and (event.own and "2" or "1") or "0") .. ":" .. spec
end

local function SendEvent(event)
    local function Build(note)
        return table.concat({
            "E", event.id, Num(event.updated), Num(event.when), event.deleted and "1" or "0",
            event.title or "", note, MetaOf(event),
        }, SEP)
    end
    -- A message cannot be longer than the game allows. If the name of the
    -- creator is long, the description is shortened in the message.
    local note = event.note or ""
    local message = Build(note)
    if #message > MAX_MESSAGE_BYTES then
        message = Build(Truncate(note, math.max(0, #note - (#message - MAX_MESSAGE_BYTES))))
    end
    Send(message)
    MarkSeenEvent(event.id, event.updated)

    -- The picked members are sent separately, as many per message as fit.
    if event.aud == "P" and not event.deleted and type(event.invited) == "table" then
        local head = table.concat({ "I", event.id, Num(event.updated) }, SEP) .. SEP
        local chunk = ""
        for _, key in ipairs(SortedKeys(event.invited)) do
            if chunk ~= "" and #head + #chunk + 1 + #key > MAX_MESSAGE_BYTES then
                Send(head .. chunk)
                chunk = ""
            end
            chunk = (chunk == "" and key) or (chunk .. ";" .. key)
        end
        if chunk ~= "" then
            Send(head .. chunk)
        end
    end
end

-- Sends sign-ups for an event, several per message as far as there is room.
-- players is which ones to include ({ [key] = true }), or nil for all.
local function SendSignups(event, players)
    local parts, size = { "S", event.id }, 2 + #event.id
    local function Flush()
        if #parts > 2 then
            Send(table.concat(parts, SEP))
        end
        parts, size = { "S", event.id }, 2 + #event.id
    end

    for _, player in ipairs(SortedKeys(event.signups)) do
        if not players or players[player] then
            local signup = event.signups[player]
            local entry = table.concat({ player, signup.status, Num(signup.updated), signup.class or "" }, ",")
            if size + 1 + #entry > MAX_MESSAGE_BYTES then
                Flush()
            end
            parts[#parts + 1] = entry
            size = size + 1 + #entry
            MarkSeenSignup(event.id, player, signup.updated)
        end
    end
    Flush()
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

local RefreshPanel

local hello = {}  -- [sender] = { [id] = true } while we receive their list
local offers = {} -- [id] = { event = true/false, signups = true/false }: what we will send
local wanted = {} -- [id] = true: what we will ask for
local exchangeScheduled = false

-- Note that we will send an event and/or its sign-ups.
local function Offer(id, withEvent, withSignups)
    local offer = offers[id]
    if not offer then
        offer = {}
        offers[id] = offer
        -- From now on we count what others manage to send before us.
        seen.events[id] = nil
        seen.signups[id] = nil
    end
    offer.event = offer.event or withEvent
    offer.signups = offer.signups or withSignups
end

local function RunExchange()
    exchangeScheduled = false
    if not DW.IsMember() then
        offers, wanted = {}, {}
        return
    end

    -- Ask for what we are missing.
    local ids = SortedKeys(wanted)
    wanted = {}
    SendList("G", ids)

    -- Send what others are missing, unless someone else got there first.
    for _, id in ipairs(SortedKeys(offers)) do
        local offer, event = offers[id], db.events[id]
        if event and not event.stub then
            if offer.event and (seen.events[id] or -1) < event.updated then
                SendEvent(event)
            end
            if offer.signups then
                local players, any = {}, false
                local seenPlayers = seen.signups[id] or {}
                for player, signup in pairs(event.signups) do
                    if (seenPlayers[player] or -1) < signup.updated then
                        players[player] = true
                        any = true
                    end
                end
                if any then
                    SendSignups(event, players)
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
    -- Random delay, so not everyone who is online answers at the same time.
    C_Timer.After(1 + math.random() * 3, RunExchange)
end

-- Tells the others what we have, so they can send what we are missing.
local function SayHello()
    PurgeExpired()
    local entries = {}
    for _, id in ipairs(SortedKeys(db.events)) do
        local event = db.events[id]
        if Syncable(event) then
            local count, newest = Digest(event)
            entries[#entries + 1] = table.concat({ id, Num(event.updated), Num(count), Num(newest) }, ",")
        end
    end
    SendList("H", entries)
    Send("Q")
end

-- Receiving -------------------------------------------------------------------

-- Receives an event from someone else. Returns true if anything changed.
local function ApplyEvent(id, updated, when, deleted, title, note, meta)
    local creator = CreatorOf(id)
    local now = time()
    if not creator or updated > now + DAY or when <= now - KEEP_AFTER_START then
        return false
    end

    local event = db.events[id]
    if event and not event.stub and updated <= event.updated then
        return false -- we have the same or a newer version
    end
    if not event or event.stub then
        -- New to us: the buttons blink until the tab is opened (Alerts.lua).
        event = event or { id = id, signups = {} }
        db.events[id] = event
        event.arrived = DW.AlertNow and DW.AlertNow() or now
    end
    event.stub = nil
    event.creator = creator
    event.updated = updated
    event.when = when
    event.deleted = deleted or nil
    event.title = Clean(title, MAX_TITLE_BYTES)
    event.note = Clean(note, MAX_NOTE_BYTES)

    -- Who it is for, and whether it goes in the game's calendar. Messages from
    -- older versions do not have this field; then the event is for everyone.
    local cal, spec = tostring(meta or ""):match("^(%d):(.+)$")
    local low, high = (spec or ""):match("^L(%d+)%-(%d+)$")
    local picked = (spec or ""):match("^P(%d+)$")
    event.cal = (cal == "1" or cal == "2") or nil
    event.own = (cal == "2") or nil
    event.aud, event.min, event.max, event.invited, event.invitedCount = nil, nil, nil, nil, nil
    if low then
        event.aud, event.min, event.max = "L", tonumber(low), tonumber(high)
    elseif picked then
        -- The list of picked members comes in separate messages right after.
        event.aud, event.invited, event.invitedCount = "P", {}, tonumber(picked)
    end
    return true
end

-- Receives a sign-up. Returns true if anything changed.
local function ApplySignup(id, player, status, updated, class)
    if not STATUS_KEY[status] or updated > time() + DAY or #player > 80 then
        return false
    end

    local event = db.events[id]
    if not event then
        -- Sign-up for an event we do not know. Keep it, and ask for the event.
        event = { id = id, stub = true, updated = 0, signups = {} }
        db.events[id] = event
        wanted[id] = true
    end
    local current = event.signups[player]
    if current and updated <= current.updated then
        return false
    end
    event.signups[player] = { status = status, updated = updated, class = (class ~= "" and class) or nil }
    return true
end

local function OnMessage(text, sender)
    local fields = Split(text, SEP)
    local kind = fields[1]
    local changed = false

    if kind == "E" and #fields >= 7 then
        local id, updated, when = fields[2], tonumber(fields[3]), tonumber(fields[4])
        if id ~= "" and updated and when then
            MarkSeenEvent(id, updated)
            changed = ApplyEvent(id, updated, when, fields[5] == "1", fields[6], fields[7], fields[8])

            -- If it is for a selection, the list of who comes right after.
            -- If part of it is missing after a while, we ask for the event again.
            local event = db.events[id]
            if changed and event.aud == "P" and (event.invitedCount or 0) > 0 then
                C_Timer.After(20, function()
                    if db.events[id] == event and event.aud == "P" and CountKeys(event.invited) < (event.invitedCount or 0) then
                        wanted[id] = true
                        ScheduleExchange()
                    end
                end)
            end
        end

    elseif kind == "I" and #fields >= 4 then
        -- Who an event for picked members is for. Only accepted for the version
        -- of the event we have.
        local event = db.events[fields[2]]
        if event and not event.stub and event.aud == "P" and tonumber(fields[3]) == event.updated then
            event.invited = event.invited or {}
            for key in fields[4]:gmatch("[^;]+") do
                if #key <= 80 and not event.invited[key] then
                    event.invited[key] = true
                    changed = true
                end
            end
        end

    elseif kind == "S" and #fields >= 3 then
        local id = fields[2]
        if id ~= "" then
            for index = 3, #fields do
                local player, status, updated, class = fields[index]:match("^([^,]+),(%a),(%d+),([^,]*)$")
                updated = tonumber(updated)
                if player and updated then
                    MarkSeenSignup(id, player, updated)
                    if ApplySignup(id, player, status, updated, class) then
                        changed = true
                    end
                end
            end
        end

    elseif kind == "H" then
        -- List of what the sender has. Compare with our own.
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
                local mine = db.events[id]
                if not mine or mine.stub then
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
        -- The list is finished. Everything we have that was not on it, the sender is missing.
        local listed = hello[sender] or {}
        hello[sender] = nil
        for id, event in pairs(db.events) do
            if not listed[id] and Syncable(event) then
                Offer(id, true, true)
            end
        end

    elseif kind == "G" then
        -- Someone asks for specific events.
        for index = 2, #fields do
            local event = db.events[fields[index]]
            if event and Syncable(event) then
                Offer(fields[index], true, true)
            end
        end
    end

    if next(wanted) ~= nil or next(offers) ~= nil then
        ScheduleExchange()
    end
    if changed then
        RefreshPanel()
        if DW.QueueAlertRefresh then
            DW.QueueAlertRefresh()
        end
    end
end

-- Actions ---------------------------------------------------------------------

local selectedID -- the event shown on the right
local formOpen = false

-- What is selected in the form for a new event.
local formAudience = "A" -- who it is for: "A" all, "L" level, "P" picked
local formInvited = {}   -- the picked members: [key] = true
local membersOpen = false -- the list for choosing members is open
local memberSearch = ""

-- audience says who the event is for:
--   { aud = "A" }                        everyone
--   { aud = "L", min = 20, max = 40 }    a level range
--   { aud = "P", invited = { [key] = true } }   picked members
-- and audience.cal = true if it should also go in the game's calendar.
local function CreateEvent(title, note, when, audience)
    local me = MyKey()
    if not me then
        return nil
    end
    audience = audience or {}
    db.seq = (db.seq or 0) + 1
    local now = time()
    local event = {
        id = ("%s:%d:%d"):format(me, now, db.seq),
        creator = me,
        title = title,
        note = note,
        when = when,
        updated = now,
        signups = {},
        cal = audience.cal or nil,
        own = (audience.cal and audience.own) or nil,
    }
    if audience.aud == "L" then
        event.aud, event.min, event.max = "L", audience.min, audience.max
    elseif audience.aud == "P" then
        event.aud, event.invited = "P", {}
        for key in pairs(audience.invited or {}) do
            event.invited[key] = true
        end
        event.invitedCount = CountKeys(event.invited)
    end
    db.events[event.id] = event
    SendEvent(event)
    return event
end

-- The keys that can stand for the character you play in a list of picked members:
-- the player's permanent ID, and the name without spaces for clients that give no ID.
local function MyInviteKeys()
    local keys = {}
    local guid = DW.MyGUID()
    if guid then
        keys[#keys + 1] = guid
    end
    local _, name = DW.CharacterKey()
    if name then
        keys[#keys + 1] = "name:" .. DW.NameKey(name)
    end
    return keys
end

-- Is the event for the character you are playing now? Its creator always sees it.
local function AppliesToMe(event)
    if not event.aud or event.aud == "A" or event.creator == MyKey() then
        return true
    end
    if event.aud == "L" then
        local level = UnitLevel and UnitLevel("player")
        if type(level) ~= "number" or DW.IsSecret(level) then
            return true
        end
        return level >= (event.min or 1) and level <= (event.max or 99)
    end
    for _, key in ipairs(MyInviteKeys()) do
        if event.invited and event.invited[key] then
            return true
        end
    end
    return false
end

-- Short text about who the event is for.
local function AudienceText(event)
    if event.aud == "L" then
        return L.EV_FOR_LEVEL:format(event.min or 1, event.max or 99)
    elseif event.aud == "P" then
        return L.EV_FOR_PICKED:format(event.invitedCount or CountKeys(event.invited))
    end
    return L.EV_FOR_ALL
end

-- The game's calendar: adding ----------------------------------------------------

-- Puts the event in the game's own calendar. Must be called directly from a
-- click, because the game requires that to save a calendar event.
--   forGuild = true   a guild event that everyone in the guild sees in their calendar
--   forGuild = false  a personal entry that only you see
-- Returns true if the calendar accepted the calls. If it went wrong, the reason
-- is remembered in calendarProblem, which /dw debug shows.
local calendarProblem

local function AddToGameCalendar(event, forGuild)
    local calendar = C_Calendar
    if not (calendar and calendar.AddEvent and calendar.EventSetTitle and calendar.EventSetDate and calendar.EventSetTime) then
        calendarProblem = "spillet mangler kalender-funksjonene"
        return false
    end
    local create = (forGuild and calendar.CreateGuildSignUpEvent) or calendar.CreatePlayerEvent
    local when = date("*t", event.when)
    if not create or type(when) ~= "table" then
        calendarProblem = "kan ikke opprette event, eller date('*t') ga ikke en tabell"
        return false
    end
    local ok, problem = pcall(function()
        create()
        calendar.EventSetTitle(event.title)
        if calendar.EventSetDescription then
            calendar.EventSetDescription((event.note and event.note ~= "") and event.note or event.title)
        end
        if calendar.EventSetType then
            calendar.EventSetType(4) -- the type "other"
        end
        calendar.EventSetDate(when.month, when.day, when.year)
        calendar.EventSetTime(when.hour, when.min)
        calendar.AddEvent()
    end)
    calendarProblem = (not ok) and tostring(problem) or nil
    return ok
end

-- Which events this character has already put in its calendar, so they are not
-- added twice.
local function CalendarLog()
    local me = MyKey()
    if not me then
        return {}
    end
    if type(db.inCalendar) ~= "table" then
        db.inCalendar = {}
    end
    if type(db.inCalendar[me]) ~= "table" then
        db.inCalendar[me] = {}
    end
    return db.inCalendar[me]
end

-- Is this character allowed to make guild events in the game's calendar? That
-- is controlled by the rank in the guild.
local function CanMakeGuildEvent()
    if not (C_Calendar and C_Calendar.CreateGuildSignUpEvent) then
        return false
    end
    if type(CanEditGuildEvent) == "function" then
        local ok, allowed = pcall(CanEditGuildEvent)
        if ok and not allowed then
            return false
        end
    end
    return true
end

-- Should the event be in the game's calendar as one guild event everyone sees?
-- Otherwise each member puts it in their own calendar.
local function IsGuildWide(event)
    return event.aud == nil and not event.own
end

-- The last thing we tried to put in the calendar. The game reports errors a
-- little later, and then we need to know which event it was about.
local lastCalendarTry

-- Puts the event in the game's calendar once, and says in chat how it went.
local function PutInGameCalendar(event, forGuild)
    local log = CalendarLog()
    if log[event.id] then
        return
    end
    if AddToGameCalendar(event, forGuild) then
        log[event.id] = true
        lastCalendarTry = { id = event.id, at = GetTime() }
        DW.Print(forGuild and L.EV_CAL_ADDED_GUILD or L.EV_CAL_ADDED)
    else
        DW.Print(L.EV_CAL_FAILED)
    end
end

-- The game rejected a calendar event. If it was the one we just added, we say
-- so, and forget that it was added so it can be tried again.
local function OnCalendarError(reason)
    if not lastCalendarTry or GetTime() - lastCalendarTry.at > 5 then
        return
    end
    CalendarLog()[lastCalendarTry.id] = nil
    lastCalendarTry = nil
    if type(reason) == "string" and not DW.IsSecret(reason) and reason ~= "" then
        calendarProblem = reason
        DW.Print(L.EV_CAL_FAILED .. " (" .. reason .. ")")
    else
        calendarProblem = "spillet avviste eventen"
        DW.Print(L.EV_CAL_FAILED)
    end
end

local function DeleteEvent(event)
    event.deleted = true
    event.updated = math.max(time(), event.updated + 1)
    SendEvent(event)
end

local function SetSignup(event, status)
    local me = MyKey()
    if not me then
        return
    end
    local previous = event.signups[me]
    event.signups[me] = {
        status = status,
        -- Always newer than the previous answer, even if the clock stands still for a second.
        updated = math.max(time(), previous and (previous.updated + 1) or 0),
        class = select(2, UnitClass("player")),
    }
    SendSignups(event, { [me] = true })
end

-- Posts the event in guild chat as plain text, so those without the addon see
-- it too: one line with title and time, one with the description, and one
-- about the addon. Returns true if it was sent.
local lastShare = {} -- [id] = when the event was last shared, so a double click does not post twice

local function ShareToGuildChat(event)
    local send = (C_ChatInfo and C_ChatInfo.SendChatMessage) or SendChatMessage
    if not send then
        return false
    end
    if C_ChatInfo and C_ChatInfo.InChatMessagingLockdown and C_ChatInfo.InChatMessagingLockdown() then
        DW.Print(L.EV_SHARE_BLOCKED)
        return false
    end
    local now = GetTime()
    if lastShare[event.id] and now - lastShare[event.id] < 10 then
        return false
    end
    lastShare[event.id] = now

    -- A chat message can be 255 characters, so each part is sent separately.
    local head = L.EV_SHARE_HEAD:format(event.title, date("%d.%m.%Y %H:%M", event.when))
    if event.aud then
        head = head .. " (" .. AudienceText(event) .. ")"
    end
    send(Truncate(head, 250), "GUILD")
    if event.note and event.note ~= "" then
        send(Truncate(event.note, 250), "GUILD")
    end
    send(Truncate(L.EV_SHARE_ADDON, 250), "GUILD")
    return true
end

-- Calendar arithmetic ------------------------------------------------------------

local function DaysInMonth(year, month)
    if month == 2 then
        local leap = (year % 4 == 0 and year % 100 ~= 0) or (year % 400 == 0)
        return leap and 29 or 28
    end
    return (month == 4 or month == 6 or month == 9 or month == 11) and 30 or 31
end

-- The weekday of a date: 1 = Monday ... 7 = Sunday.
local MONTH_OFFSETS = { 0, 3, 2, 5, 0, 3, 5, 1, 4, 6, 2, 4 }

local function Weekday(year, month, day)
    if month < 3 then
        year = year - 1
    end
    local sundayFirst = (year + math.floor(year / 4) - math.floor(year / 100) + math.floor(year / 400)
        + MONTH_OFFSETS[month] + day) % 7
    return (sundayFirst + 6) % 7 + 1
end

-- Reads a date written as DD.MM.YYYY (or DD.MM.YY). Returns year, month and
-- day, or nothing if the date does not exist.
local function ParseDate(dateText)
    local day, month, year = tostring(dateText):match("^%s*(%d%d?)[%./%-](%d%d?)[%./%-](%d%d%d?%d?)%s*$")
    day, month, year = tonumber(day), tonumber(month), tonumber(year)
    if not (day and month and year) then
        return nil
    end
    if year < 100 then
        year = year + 2000
    end
    if year < 2000 or month < 1 or month > 12 or day < 1 or day > DaysInMonth(year, month) then
        return nil
    end
    return year, month, day
end

-- Reads date and time of day. The time can be written 20:00, 20.00, 2000 or
-- just 20. Returns the timestamp, or nothing if something is wrong.
local function ParseWhen(dateText, timeText)
    local year, month, day = ParseDate(dateText)
    if not year then
        return nil
    end

    local clock = tostring(timeText):gsub("%s+", "")
    local hour, minute = clock:match("^(%d%d?)[:%.](%d%d)$")
    if not hour then
        hour, minute = clock:match("^(%d%d)(%d%d)$")
    end
    if not hour then
        hour = clock:match("^(%d%d?)$")
        minute = hour and "00"
    end
    hour, minute = tonumber(hour), tonumber(minute)
    if not (hour and minute) or hour > 23 or minute > 59 then
        return nil
    end
    return time({ year = year, month = month, day = day, hour = hour, min = minute, sec = 0 })
end

-- Events that should be shown: not deleted, not too long ago, and only those
-- that apply to the character you are playing. Nearest first.
local function VisibleEvents()
    local list = {}
    local limit = time() - SHOW_AFTER_START
    for _, event in pairs(db.events) do
        if not event.stub and not event.deleted and type(event.when) == "number" and event.when > limit
            and AppliesToMe(event) then
            list[#list + 1] = event
        end
    end
    table.sort(list, function(a, b)
        if a.when ~= b.when then
            return a.when < b.when
        end
        return a.id < b.id
    end)
    return list
end

-- The game's calendar -------------------------------------------------------------

local CALENDAR_TYPE_KEY = {
    GUILD_EVENT = "EV_CAL_GUILD",
    GUILD_ANNOUNCEMENT = "EV_CAL_GUILD",
    PLAYER = "EV_CAL_PLAYER",
    HOLIDAY = "EV_CAL_HOLIDAY",
    COMMUNITY_EVENT = "EV_CAL_COMMUNITY",
}

-- Reads what is in the game's calendar from today to the end of next month.
-- Returns a list, or nothing if the calendar does not exist.
local function ReadCalendar()
    if not (C_Calendar and C_Calendar.GetMonthInfo and C_Calendar.GetNumDayEvents and C_Calendar.GetDayEvent
            and C_DateAndTime and C_DateAndTime.GetCurrentCalendarTime) then
        return nil
    end
    local today = C_DateAndTime.GetCurrentCalendarTime()
    local selected = C_Calendar.GetMonthInfo(0)
    if type(today) ~= "table" or type(selected) ~= "table" or DW.IsSecret(today.month) or DW.IsSecret(selected.month) then
        return nil
    end

    -- The calendar counts months from the month selected in it. Before it has
    -- been opened in the session that is November 2004. Point it at this month,
    -- but not if the player has the calendar open and is browsing it.
    local offset = (today.year - selected.year) * 12 + (today.month - selected.month)
    if offset ~= 0 and C_Calendar.SetAbsMonth and not (CalendarFrame and CalendarFrame:IsShown()) then
        C_Calendar.SetAbsMonth(today.month, today.year)
        offset = 0
    end

    local list = {}
    for step = 0, 1 do
        local info = C_Calendar.GetMonthInfo(offset + step)
        if type(info) == "table" and type(info.numDays) == "number" then
            for day = (step == 0 and today.monthDay or 1), info.numDays do
                local count = C_Calendar.GetNumDayEvents(offset + step, day)
                if type(count) ~= "number" or DW.IsSecret(count) then
                    count = 0
                end
                for index = 1, count do
                    local event = C_Calendar.GetDayEvent(offset + step, day, index)
                    if type(event) == "table" and type(event.title) == "string" and not DW.IsSecret(event.title) then
                        local kind = event.calendarType
                        local holidayRepeat = kind == "HOLIDAY" and event.sequenceType ~= "START" and event.sequenceType ~= ""
                        if kind ~= "RAID_LOCKOUT" and kind ~= "RAID_RESET" and not holidayRepeat then
                            local start = type(event.startTime) == "table" and event.startTime or {}
                            list[#list + 1] = {
                                title = Clean(event.title, 80),
                                kind = kind,
                                when = ("%02d.%02d %02d:%02d"):format(day, info.month or 0, start.hour or 0, start.minute or 0),
                            }
                        end
                    end
                end
            end
        end
    end
    return list
end

-- The panel in the main window ---------------------------------------------------

local LIST_WIDTH = 250
local EVENT_ROW_HEIGHT = 46
local CALENDAR_ROW_HEIGHT = 22

local panel -- created the first time the module is selected in the main window
local view = "guild" -- "guild" or "calendar"
local picker -- the small month overview in the form; created the first time the calendar button is pressed
local RefreshPicker
local eventRows, calendarRows = {}, {}

local function GetEventRow(index)
    local row = eventRows[index]
    if row then
        return row
    end

    row = DW.CreateChip(panel.guild.content, LIST_WIDTH, EVENT_ROW_HEIGHT - 4)
    row:SetPoint("TOPLEFT", 0, -(index - 1) * EVENT_ROW_HEIGHT)
    row.label:ClearAllPoints()
    row.label:SetPoint("TOPLEFT", 10, -7)
    row.label:SetPoint("TOPRIGHT", -10, -7)

    row.sub = row:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    row.sub:SetPoint("BOTTOMLEFT", 10, 7)
    row.sub:SetPoint("BOTTOMRIGHT", -10, 7)
    row.sub:SetJustifyH("LEFT")
    row.sub:SetWordWrap(false)
    row.sub:SetTextColor(0.75, 0.75, 0.75)

    row:SetScript("OnClick", function(self)
        selectedID = self.eventID
        formOpen = false
        RefreshPanel()
    end)

    eventRows[index] = row
    return row
end

local function GetCalendarRow(index)
    local row = calendarRows[index]
    if row then
        return row
    end

    row = CreateFrame("Frame", nil, panel.calendar.content)
    row:SetSize(panel.calendar.content:GetWidth(), CALENDAR_ROW_HEIGHT)
    row:SetPoint("TOPLEFT", 0, -(index - 1) * CALENDAR_ROW_HEIGHT)

    row.when = row:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    row.when:SetPoint("LEFT", 4, 0)
    row.when:SetWidth(90)
    row.when:SetJustifyH("LEFT")

    row.kind = row:CreateFontString(nil, "OVERLAY", "GameFontDisable")
    row.kind:SetPoint("RIGHT", -8, 0)
    row.kind:SetWidth(100)
    row.kind:SetJustifyH("RIGHT")

    row.title = row:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
    row.title:SetPoint("LEFT", row.when, "RIGHT", 6, 0)
    row.title:SetPoint("RIGHT", row.kind, "LEFT", -6, 0)
    row.title:SetJustifyH("LEFT")
    row.title:SetWordWrap(false)

    calendarRows[index] = row
    return row
end

-- The list for choosing members --------------------------------------------------

local memberRows = {}
local RefreshMembers

-- The key a member is stored under in the list of picked members: the player's
-- permanent ID, or the name without spaces if the client gives no ID.
local function MemberKey(member)
    return member.guid or ("name:" .. DW.NameKey(member.key))
end

local function GetMemberRow(index)
    local row = memberRows[index]
    if row then
        return row
    end
    local content = panel.guild.members.content

    row = CreateFrame("Frame", nil, content)
    row:SetSize(content:GetWidth(), 22)
    row:SetPoint("TOPLEFT", 0, -(index - 1) * 22)

    row.check = CreateFrame("CheckButton", nil, row, "UICheckButtonTemplate")
    row.check:SetSize(22, 22)
    row.check:SetPoint("LEFT", 0, 0)
    row.check:SetScript("OnClick", function(self)
        if row.key then
            formInvited[row.key] = self:GetChecked() and true or nil
            RefreshMembers()
        end
    end)

    row.level = row:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    row.level:SetPoint("RIGHT", -6, 0)
    row.level:SetWidth(30)
    row.level:SetJustifyH("RIGHT")

    row.name = row:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
    row.name:SetPoint("LEFT", row.check, "RIGHT", 4, 0)
    row.name:SetPoint("RIGHT", row.level, "LEFT", -6, 0)
    row.name:SetJustifyH("LEFT")
    row.name:SetWordWrap(false)

    memberRows[index] = row
    return row
end

RefreshMembers = function()
    local m = panel.guild.members
    m.title:SetText(L.EV_MEMBERS_TITLE)
    m.searchLabel:SetText(L.RO_SEARCH)
    m.done.label:SetText(L.EV_MEMBERS_DONE:format(CountKeys(formInvited)))

    local needle = memberSearch:lower()
    needle = needle:gsub("^%s+", "")
    needle = needle:gsub("%s+$", "")

    local roster = DW.ReadGuildRoster()
    table.sort(roster, function(a, b)
        if a.name ~= b.name then
            return a.name < b.name
        end
        return a.key < b.key
    end)

    local shown = 0
    for _, member in ipairs(roster) do
        if needle == "" or member.name:lower():find(needle, 1, true) then
            shown = shown + 1
            local row = GetMemberRow(shown)
            local colour = RAID_CLASS_COLORS and RAID_CLASS_COLORS[member.class]
            row.key = MemberKey(member)
            row.name:SetText(member.name)
            if colour then
                row.name:SetTextColor(colour.r, colour.g, colour.b)
            else
                row.name:SetTextColor(1, 1, 1)
            end
            row.level:SetText(tostring(member.level))
            row.check:SetChecked(formInvited[row.key] == true)
            row:Show()
        end
    end
    for index = shown + 1, #memberRows do
        memberRows[index].key = nil
        memberRows[index]:Hide()
    end
    m.content:SetHeight(math.max(1, shown * 22))
end

local function CountByStatus(event)
    local counts, names = { Y = 0, M = 0, N = 0 }, { Y = {}, M = {}, N = {} }
    for _, player in ipairs(SortedKeys(event.signups)) do
        local status = event.signups[player].status
        if counts[status] then
            counts[status] = counts[status] + 1
            names[status][#names[status] + 1] = ShortName(player)
        end
    end
    return counts, names
end

local function RefreshGuildView()
    local g = panel.guild
    local me = MyKey()
    local events = VisibleEvents()

    -- The selected event may be deleted or expired. Then choose the first one.
    local selected
    for _, event in ipairs(events) do
        if event.id == selectedID then
            selected = event
        end
    end
    if not selected then
        selected = events[1]
        selectedID = selected and selected.id or nil
    end

    for index, event in ipairs(events) do
        local row = GetEventRow(index)
        local counts = CountByStatus(event)
        local mine = me and event.signups[me]
        row.eventID = event.id
        row.label:SetText(event.title)
        row.sub:SetText(("%s   %d / %d / %d%s"):format(
            date("%d.%m.%Y %H:%M", event.when), counts.Y, counts.M, counts.N,
            mine and ("   " .. L[STATUS_KEY[mine.status]]) or ""))
        row:SetSelected(not formOpen and event.id == selectedID)
        row:Show()
    end
    for index = #events + 1, #eventRows do
        eventRows[index].eventID = nil
        eventRows[index]:Hide()
    end
    g.content:SetHeight(math.max(1, #events * EVENT_ROW_HEIGHT))
    g.newButton.label:SetText(L.EV_NEW)

    -- Right side: form (or the list for choosing members), selected event,
    -- or a text saying the list is empty.
    local d, form = g.detail, g.form
    form:SetShown(formOpen and not membersOpen)
    g.members:SetShown(formOpen and membersOpen)
    d:SetShown(not formOpen and selected ~= nil)
    g.empty:SetShown(not formOpen and selected == nil)
    g.empty:SetText(L.EV_EMPTY)

    form.titleLabel:SetText(L.EV_FORM_TITLE)
    form.dateLabel:SetText(L.EV_FORM_DATE)
    form.timeLabel:SetText(L.EV_FORM_TIME)
    form.noteLabel:SetText(L.EV_FORM_NOTE)
    form.save.label:SetText(L.EV_SAVE)
    form.cancel.label:SetText(L.EV_CANCEL)

    -- Who the event is for.
    form.audienceLabel:SetText(L.EV_FORM_AUDIENCE)
    form.audienceChips.A.label:SetText(L.EV_AUD_ALL)
    form.audienceChips.L.label:SetText(L.EV_AUD_LEVEL)
    form.audienceChips.P.label:SetText(L.EV_AUD_PICKED)
    for key, chip in pairs(form.audienceChips) do
        chip:SetSelected(key == formAudience)
    end
    form.levelRow:SetShown(formAudience == "L")
    form.levelLabel:SetText(L.EV_FORM_LEVEL)
    form.levelTo:SetText(L.EV_FORM_LEVEL_TO)
    form.membersButton:SetShown(formAudience == "P")
    form.membersButton.label:SetText(L.EV_FORM_MEMBERS:format(CountKeys(formInvited)))
    form.calendarLabel:SetText(L.EV_FORM_CALENDAR)

    if formOpen and membersOpen then
        RefreshMembers()
    end

    if selected and not formOpen then
        local counts, names = CountByStatus(selected)
        local mine = me and selected.signups[me]
        d.title:SetText(selected.title)
        d.when:SetText(L.EV_WHEN_BY:format(date("%d.%m.%Y %H:%M", selected.when), ShortName(selected.creator)))
        d.audience:SetText(AudienceText(selected))
        d.note:SetText(selected.note or "")
        for _, status in ipairs(STATUSES) do
            d.chips[status].label:SetText(("%s (%d)"):format(L[STATUS_KEY[status]], counts[status]))
            d.chips[status]:SetSelected(mine ~= nil and mine.status == status)
            d.lists[status]:SetText(("%s: %s"):format(L[STATUS_KEY[status]],
                #names[status] > 0 and table.concat(names[status], ", ") or "-"))
        end
        d.share.label:SetText(L.EV_SHARE)
        d.delete.label:SetText(L.EV_DELETE)
        d.delete:SetShown(selected.creator == me)
    end
end

local function RefreshCalendarView()
    local c = panel.calendar
    local list = ReadCalendar()

    for index, entry in ipairs(list or {}) do
        local row = GetCalendarRow(index)
        row.when:SetText(entry.when)
        row.title:SetText(entry.title)
        row.kind:SetText(CALENDAR_TYPE_KEY[entry.kind] and L[CALENDAR_TYPE_KEY[entry.kind]] or "")
        row:Show()
    end
    for index = #(list or {}) + 1, #calendarRows do
        calendarRows[index]:Hide()
    end
    c.content:SetHeight(math.max(1, #(list or {}) * CALENDAR_ROW_HEIGHT))

    c.empty:SetShown(list == nil or #list == 0)
    c.empty:SetText(list == nil and L.EV_CAL_MISSING or L.EV_CAL_EMPTY)
end

RefreshPanel = function()
    if not panel or not panel:IsVisible() then
        return
    end

    -- The date picker belongs to the form. Close it when the form is not open.
    if picker and (view ~= "guild" or not formOpen) then
        picker:Hide()
    end
    RefreshPicker()

    panel.title:SetText(L.EV_PANEL_TITLE)
    panel.tabs.guild.label:SetText(L.EV_TAB_GUILD)
    panel.tabs.calendar.label:SetText(L.EV_TAB_CALENDAR)
    panel.tabs.guild:SetSelected(view == "guild")
    panel.tabs.calendar:SetSelected(view == "calendar")

    panel.guild:SetShown(view == "guild")
    panel.calendar:SetShown(view == "calendar")
    if view == "guild" then
        RefreshGuildView()
    else
        RefreshCalendarView()
    end
end

local function SetView(newView)
    view = newView
    formOpen = false
    if view == "calendar" and C_Calendar and C_Calendar.OpenCalendar then
        -- Ask the game to fetch the calendar. The answer comes as an event.
        C_Calendar.OpenCalendar()
    end
    RefreshPanel()
end

-- A text field. The limit is given either as a number of characters
-- (maxLetters) or as a number of bytes (maxBytes, for text sent to the guild).
local function CreateEditBox(parent, width, maxBytes, maxLetters)
    local box = CreateFrame("EditBox", nil, parent, "InputBoxTemplate")
    box:SetSize(width, 22)
    box:SetAutoFocus(false)
    if maxLetters then
        box:SetMaxLetters(maxLetters)
    else
        -- The game counts one character more than it lets in, so the limit must
        -- be set one higher than what we want room for.
        box:SetMaxBytes(maxBytes + 1)
    end
    box:SetScript("OnEscapePressed", function(self)
        self:ClearFocus()
    end)
    box:SetScript("OnEnterPressed", function(self)
        self:ClearFocus()
    end)
    return box
end

-- The date picker ---------------------------------------------------------------

local pickerYear, pickerMonth -- the month the date picker shows

local function Today()
    return ParseDate(date("%d.%m.%Y"))
end

RefreshPicker = function()
    if not picker or not picker:IsShown() then
        return
    end

    local todayYear, todayMonth, todayDay = Today()
    local chosenYear, chosenMonth, chosenDay = ParseDate(panel.guild.form.dateBox:GetText())

    picker.title:SetText(("%s %d"):format(L["MONTH_" .. pickerMonth], pickerYear))
    for index = 1, 7 do
        picker.weekdays[index]:SetText(L["WEEKDAY_" .. index])
    end

    local blanks = Weekday(pickerYear, pickerMonth, 1) - 1 -- empty cells before the first
    local days = DaysInMonth(pickerYear, pickerMonth)
    for index = 1, 42 do
        local button = picker.days[index]
        local day = index - blanks
        if day >= 1 and day <= days then
            -- Days that have passed cannot be chosen.
            local past = todayYear ~= nil and (pickerYear < todayYear
                or (pickerYear == todayYear and (pickerMonth < todayMonth
                    or (pickerMonth == todayMonth and day < todayDay))))
            button.day = day
            button.label:SetText(tostring(day))
            button:SetEnabled(not past)
            button:SetDimmed(past)
            button:SetSelected(not past and day == chosenDay and pickerMonth == chosenMonth and pickerYear == chosenYear)
            button:Show()
        else
            button.day = nil
            button:Hide()
        end
    end
end

local function StepMonth(step)
    pickerMonth = pickerMonth + step
    if pickerMonth > 12 then
        pickerMonth, pickerYear = 1, pickerYear + 1
    elseif pickerMonth < 1 then
        pickerMonth, pickerYear = 12, pickerYear - 1
    end
    RefreshPicker()
end

local function CreatePicker()
    local form = panel.guild.form
    local CELL_WIDTH, CELL_HEIGHT = 32, 26

    local p = CreateFrame("Frame", nil, panel, "BackdropTemplate")
    p:SetSize(7 * CELL_WIDTH + 20, 56 + 6 * CELL_HEIGHT + 10)
    p:SetPoint("TOPLEFT", form.dateBox, "BOTTOMLEFT", -6, -4)
    p:SetFrameStrata("DIALOG") -- above the rest of the window
    p:SetBackdrop(DW.PANEL_BACKDROP)
    p:SetBackdropColor(0.05, 0.05, 0.07, 0.98)
    p:SetBackdropBorderColor(0.90, 0.72, 0.30, 1)
    p:EnableMouse(true) -- clicks in the box must not hit what is underneath
    p:Hide()

    p.title = p:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    p.title:SetPoint("TOP", 0, -12)

    local function Arrow(text, step, point, x)
        local chip = DW.CreateChip(p, 26, 22)
        chip:SetPoint(point, x, -8)
        chip.label:ClearAllPoints()
        chip.label:SetPoint("CENTER", 0, 0)
        chip.label:SetText(text)
        chip:SetScript("OnClick", function()
            StepMonth(step)
        end)
        return chip
    end
    p.previous = Arrow("<", -1, "TOPLEFT", 10)
    p.next = Arrow(">", 1, "TOPRIGHT", -10)

    p.weekdays, p.days = {}, {}
    for column = 1, 7 do
        local label = p:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
        label:SetPoint("TOP", p, "TOPLEFT", 10 + (column - 1) * CELL_WIDTH + CELL_WIDTH / 2, -38)
        p.weekdays[column] = label
    end
    for index = 1, 42 do
        local column, row = (index - 1) % 7, math.floor((index - 1) / 7)
        local chip = DW.CreateChip(p, CELL_WIDTH - 2, CELL_HEIGHT - 2)
        chip:SetPoint("TOPLEFT", 10 + column * CELL_WIDTH, -56 - row * CELL_HEIGHT)
        chip.label:ClearAllPoints()
        chip.label:SetPoint("CENTER", 0, 0)
        chip:SetScript("OnClick", function(self)
            if self.day then
                -- Write the chosen day into the date field and close.
                form.dateBox:SetText(("%02d.%02d.%04d"):format(self.day, pickerMonth, pickerYear))
                form.error:SetText("")
                p:Hide()
            end
        end)
        p.days[index] = chip
    end
    return p
end

-- Opens the date picker on the month in the date field (or this month), or
-- closes it if it is already open.
local function TogglePicker()
    if not picker then
        picker = CreatePicker()
    end
    if picker:IsShown() then
        picker:Hide()
        return
    end
    local year, month = ParseDate(panel.guild.form.dateBox:GetText())
    if not year then
        year, month = Today()
    end
    pickerYear, pickerMonth = year or 2026, month or 1
    picker:Show()
    RefreshPicker()
end

local function SubmitForm()
    local form = panel.guild.form
    local title = Clean(form.titleBox:GetText(), MAX_TITLE_BYTES)
    local note = Clean(form.noteBox:GetText(), MAX_NOTE_BYTES)
    local when = ParseWhen(form.dateBox:GetText(), form.timeBox:GetText())

    if title == "" then
        form.error:SetText(L.EV_ERR_TITLE)
        return
    end
    if not when then
        form.error:SetText(L.EV_ERR_WHEN)
        return
    end
    if when < time() - HOUR then
        form.error:SetText(L.EV_ERR_PAST)
        return
    end

    -- Who it is for.
    local audience = { aud = formAudience, cal = form.calendarCheck:GetChecked() and true or nil }
    -- If you are not allowed to make guild events, each member puts it in their
    -- own calendar instead.
    audience.own = (audience.cal and formAudience == "A" and not CanMakeGuildEvent()) or nil
    if formAudience == "L" then
        local low, high = tonumber(form.levelMin:GetText()), tonumber(form.levelMax:GetText())
        if not (low and high) or low < 1 or high > 99 or low > high then
            form.error:SetText(L.EV_ERR_LEVEL)
            return
        end
        audience.min, audience.max = low, high
    elseif formAudience == "P" then
        if next(formInvited) == nil then
            form.error:SetText(L.EV_ERR_PICK)
            return
        end
        audience.invited = formInvited
    end

    local event = CreateEvent(title, note, when, audience)
    if not event then
        return
    end

    -- The game's calendar. For everyone it becomes a guild event that the whole
    -- guild sees. If it is for a selection, it goes in your own calendar now,
    -- and for the others when they answer that they are coming.
    if event.cal then
        PutInGameCalendar(event, IsGuildWide(event))
    end

    form.error:SetText("")
    form.titleBox:SetText("")
    form.noteBox:SetText("")
    form.calendarCheck:SetChecked(true)
    formAudience, formInvited, membersOpen, memberSearch = "A", {}, false, ""
    selectedID = event.id
    formOpen = false
    RefreshPanel()
end

-- Called by the main window the first time the module is selected.
local function CreatePanel(parent)
    local width, height = parent:GetWidth(), parent:GetHeight()
    local bodyHeight = height - 72

    local f = CreateFrame("Frame", nil, parent)
    f:SetAllPoints(parent)

    f.title = f:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
    f.title:SetPoint("TOP", 0, -12)

    -- The tabs: our own events, or the game's calendar.
    f.tabs = {}
    for index, name in ipairs({ "guild", "calendar" }) do
        local chip = DW.CreateChip(f, 170, 26)
        chip:SetPoint("TOPLEFT", 14 + (index - 1) * 176, -40)
        chip.label:SetJustifyH("CENTER")
        chip:SetScript("OnClick", function()
            SetView(name)
        end)
        f.tabs[name] = chip
    end

    -- Our own events: the list on the left, selected event or form on the right.
    local g = CreateFrame("Frame", nil, f)
    g:SetPoint("TOPLEFT", 0, -72)
    g:SetSize(width, bodyHeight)
    f.guild = g

    local scroll = CreateFrame("ScrollFrame", "DragonworldEventsScroll", g, "ScrollFrameTemplate")
    scroll:SetPoint("TOPLEFT", 10, 0)
    scroll:SetSize(LIST_WIDTH, bodyHeight - 54)
    g.content = CreateFrame("Frame", nil, scroll)
    g.content:SetSize(LIST_WIDTH, 1)
    scroll:SetScrollChild(g.content)

    g.newButton = DW.CreateButton(g, LIST_WIDTH, 30, "gold")
    g.newButton:SetPoint("BOTTOMLEFT", 10, 12)
    g.newButton:SetScript("OnClick", function()
        formOpen, membersOpen = true, false
        g.form.error:SetText("")
        if g.form.dateBox:GetText() == "" then
            g.form.dateBox:SetText(date("%d.%m.%Y"))
        end
        if g.form.timeBox:GetText() == "" then
            g.form.timeBox:SetText("20:00")
        end
        RefreshPanel()
    end)

    local rightX = 10 + LIST_WIDTH + 34
    local rightWidth = width - rightX - 14

    g.empty = g:CreateFontString(nil, "OVERLAY", "GameFontDisable")
    g.empty:SetPoint("TOPLEFT", rightX, -30)
    g.empty:SetWidth(rightWidth)
    g.empty:SetJustifyH("LEFT")

    -- The selected event.
    local d = CreateFrame("Frame", nil, g)
    d:SetPoint("TOPLEFT", rightX, 0)
    d:SetSize(rightWidth, bodyHeight - 12)
    g.detail = d

    d.title = d:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
    d.title:SetPoint("TOPLEFT", 0, -2)
    d.title:SetWidth(rightWidth)
    d.title:SetJustifyH("LEFT")
    d.title:SetWordWrap(false)

    d.when = d:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    d.when:SetPoint("TOPLEFT", d.title, "BOTTOMLEFT", 0, -6)
    d.when:SetWidth(rightWidth)
    d.when:SetJustifyH("LEFT")

    -- Who the event is for: everyone, a level range or picked members.
    d.audience = d:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    d.audience:SetPoint("TOPLEFT", d.when, "BOTTOMLEFT", 0, -4)
    d.audience:SetWidth(rightWidth)
    d.audience:SetJustifyH("LEFT")

    d.note = d:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
    d.note:SetPoint("TOPLEFT", d.audience, "BOTTOMLEFT", 0, -8)
    d.note:SetWidth(rightWidth)
    d.note:SetJustifyH("LEFT")

    -- The answer buttons: one click signs you up, or changes your answer.
    d.chips, d.lists = {}, {}
    local chipWidth = math.floor((rightWidth - 12) / 3)
    for index, status in ipairs(STATUSES) do
        local chip = DW.CreateChip(d, chipWidth, 28)
        chip:SetPoint("TOPLEFT", (index - 1) * (chipWidth + 6), -126)
        chip.label:SetJustifyH("CENTER")
        chip:SetScript("OnClick", function()
            local event = selectedID and db.events[selectedID]
            if event and not event.deleted then
                SetSignup(event, status)
                -- An event for a selection is put in your own calendar in the
                -- game when you answer that you are coming or maybe coming.
                -- (Events for everyone are already there, as a guild event.)
                -- If you created it yourself and the game said no the first
                -- time, it is tried again.
                if status ~= "N" and event.cal then
                    if event.creator == MyKey() then
                        PutInGameCalendar(event, IsGuildWide(event))
                    elseif not IsGuildWide(event) then
                        PutInGameCalendar(event, false)
                    end
                end
                RefreshPanel()
            end
        end)
        d.chips[status] = chip
    end

    local anchor
    for _, status in ipairs(STATUSES) do
        local list = d:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
        if anchor then
            list:SetPoint("TOPLEFT", anchor, "BOTTOMLEFT", 0, -8)
        else
            list:SetPoint("TOPLEFT", 0, -166)
        end
        list:SetWidth(rightWidth)
        list:SetJustifyH("LEFT")
        d.lists[status] = list
        anchor = list
    end

    -- Posts the event in guild chat, for those who do not have the addon.
    d.share = DW.CreateButton(d, 160, 26, "gold")
    d.share:SetPoint("BOTTOMLEFT", 0, 0)
    d.share:SetScript("OnClick", function()
        local event = selectedID and db.events[selectedID]
        if event and not event.deleted then
            ShareToGuildChat(event)
        end
    end)

    d.delete = DW.CreateButton(d, 110, 26, "red")
    d.delete:SetPoint("BOTTOMRIGHT", 0, 0)
    d.delete:SetScript("OnClick", function()
        local event = selectedID and db.events[selectedID]
        -- Only the one who created the event can delete it.
        if event and event.creator == MyKey() then
            DeleteEvent(event)
            selectedID = nil
            RefreshPanel()
        end
    end)

    -- The form for a new event.
    local form = CreateFrame("Frame", nil, g)
    form:SetPoint("TOPLEFT", rightX, 0)
    form:SetSize(rightWidth, bodyHeight - 12)
    g.form = form

    local function Label(x, y)
        local label = form:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
        label:SetPoint("TOPLEFT", x, y)
        return label
    end

    form.titleLabel = Label(0, -2)
    form.titleBox = CreateEditBox(form, rightWidth - 12, MAX_TITLE_BYTES)
    form.titleBox:SetPoint("TOPLEFT", 6, -16)

    form.dateLabel = Label(0, -48)
    form.dateBox = CreateEditBox(form, 110, nil, 10) -- "20.11.2026" is ten characters
    form.dateBox:SetPoint("TOPLEFT", 6, -62)

    -- The calendar button: opens a month overview where you click the day.
    form.calendarButton = CreateFrame("Button", nil, form)
    form.calendarButton:SetSize(24, 24)
    form.calendarButton:SetPoint("LEFT", form.dateBox, "RIGHT", 6, 0)
    form.calendarButton:SetNormalTexture(DW.MEDIA .. "calendar")
    form.calendarButton:SetHighlightTexture("Interface\\Buttons\\ButtonHilight-Square")
    form.calendarButton:SetScript("OnClick", function()
        TogglePicker()
    end)
    form.calendarButton:SetScript("OnEnter", function(self)
        GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
        GameTooltip:AddLine(L.EV_PICK_DATE)
        GameTooltip:Show()
    end)
    form.calendarButton:SetScript("OnLeave", function()
        GameTooltip:Hide()
    end)

    form.timeLabel = Label(166, -48)
    form.timeBox = CreateEditBox(form, 70, nil, 5) -- "20:00" is five characters
    form.timeBox:SetPoint("TOPLEFT", 172, -62)

    form.noteLabel = Label(0, -94)
    form.noteBox = CreateEditBox(form, rightWidth - 12, MAX_NOTE_BYTES)
    form.noteBox:SetPoint("TOPLEFT", 6, -108)

    -- Who the event is for: everyone, a level range or picked members.
    form.audienceLabel = Label(0, -140)
    form.audienceChips = {}
    local audienceWidth = math.floor((rightWidth - 12) / 3)
    for index, key in ipairs({ "A", "L", "P" }) do
        local chip = DW.CreateChip(form, audienceWidth, 26)
        chip:SetPoint("TOPLEFT", (index - 1) * (audienceWidth + 6), -156)
        chip.label:SetJustifyH("CENTER")
        chip:SetScript("OnClick", function()
            formAudience = key
            RefreshPanel()
        end)
        form.audienceChips[key] = chip
    end

    -- The level range. Only shown when "by level" is selected.
    form.levelRow = CreateFrame("Frame", nil, form)
    form.levelRow:SetPoint("TOPLEFT", 0, -190)
    form.levelRow:SetSize(rightWidth, 24)

    form.levelLabel = form.levelRow:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    form.levelLabel:SetPoint("LEFT", 0, 0)
    form.levelMin = CreateEditBox(form.levelRow, 36, nil, 2)
    form.levelMin:SetPoint("LEFT", form.levelLabel, "RIGHT", 12, 0)
    form.levelMin:SetText("1")
    form.levelTo = form.levelRow:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    form.levelTo:SetPoint("LEFT", form.levelMin, "RIGHT", 8, 0)
    form.levelMax = CreateEditBox(form.levelRow, 36, nil, 2)
    form.levelMax:SetPoint("LEFT", form.levelTo, "RIGHT", 12, 0)
    form.levelMax:SetText("60")

    -- The button that opens the list for choosing members. Only shown when
    -- "picked" is selected.
    form.membersButton = DW.CreateButton(form, 220, 24, "gold")
    form.membersButton:SetPoint("TOPLEFT", 0, -190)
    form.membersButton:SetScript("OnClick", function()
        membersOpen = true
        if picker then
            picker:Hide()
        end
        RefreshPanel()
    end)

    -- Should the event also be put in the game's own calendar?
    form.calendarCheck = CreateFrame("CheckButton", nil, form, "UICheckButtonTemplate")
    form.calendarCheck:SetSize(24, 24)
    form.calendarCheck:SetPoint("TOPLEFT", -4, -220)
    form.calendarCheck:SetChecked(true)

    form.calendarLabel = form:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    form.calendarLabel:SetPoint("LEFT", form.calendarCheck, "RIGHT", 2, 0)

    form.error = form:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    form.error:SetPoint("TOPLEFT", 0, -250)
    form.error:SetWidth(rightWidth)
    form.error:SetJustifyH("LEFT")
    form.error:SetTextColor(1.00, 0.35, 0.30)

    form.save = DW.CreateButton(form, 130, 28, "gold")
    form.save:SetPoint("TOPLEFT", 0, -278)
    form.save:SetScript("OnClick", SubmitForm)

    form.cancel = DW.CreateButton(form, 110, 28, "red")
    form.cancel:SetPoint("LEFT", form.save, "RIGHT", 8, 0)
    form.cancel:SetScript("OnClick", function()
        formOpen, membersOpen = false, false
        RefreshPanel()
    end)

    -- The list for choosing members. It covers the form while you choose.
    local m = CreateFrame("Frame", nil, g)
    m:SetPoint("TOPLEFT", rightX, 0)
    m:SetSize(rightWidth, bodyHeight - 12)
    g.members = m

    m.title = m:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    m.title:SetPoint("TOPLEFT", 0, -2)

    m.searchLabel = m:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    m.searchLabel:SetPoint("TOPLEFT", 0, -30)

    m.searchBox = CreateEditBox(m, 180, nil, 30)
    m.searchBox:SetPoint("LEFT", m.searchLabel, "RIGHT", 12, 0)
    m.searchBox:HookScript("OnTextChanged", function(self)
        memberSearch = self:GetText() or ""
        if membersOpen then
            RefreshMembers()
        end
    end)

    local memberScroll = CreateFrame("ScrollFrame", "DragonworldEventMembersScroll", m, "ScrollFrameTemplate")
    memberScroll:SetPoint("TOPLEFT", 0, -54)
    memberScroll:SetSize(rightWidth - 24, bodyHeight - 12 - 54 - 40)
    m.content = CreateFrame("Frame", nil, memberScroll)
    m.content:SetSize(rightWidth - 24, 1)
    memberScroll:SetScrollChild(m.content)

    m.done = DW.CreateButton(m, 200, 28, "gold")
    m.done:SetPoint("BOTTOMLEFT", 0, 0)
    m.done:SetScript("OnClick", function()
        membersOpen = false
        RefreshPanel()
    end)

    -- The game's calendar.
    local c = CreateFrame("Frame", nil, f)
    c:SetPoint("TOPLEFT", 0, -72)
    c:SetSize(width, bodyHeight)
    f.calendar = c

    local calendarScroll = CreateFrame("ScrollFrame", "DragonworldCalendarScroll", c, "ScrollFrameTemplate")
    calendarScroll:SetPoint("TOPLEFT", 10, 0)
    calendarScroll:SetPoint("BOTTOMRIGHT", -30, 12)
    c.content = CreateFrame("Frame", nil, calendarScroll)
    c.content:SetSize(width - 10 - 30, 1)
    calendarScroll:SetScrollChild(c.content)

    c.empty = c:CreateFontString(nil, "OVERLAY", "GameFontDisable")
    c.empty:SetPoint("TOP", 0, -40)
    c.empty:SetWidth(380)

    f:SetScript("OnShow", function()
        RefreshPanel()
    end)
    f:SetScript("OnHide", function()
        if picker then
            picker:Hide()
        end
    end)

    panel = f
    return f
end

-- Game events -----------------------------------------------------------------

-- Messages from other members. Comm.lua has already checked that they come on
-- the guild channel, from another member, and catches errors in broken messages.
DW.OnGuildMessage(PREFIX, OnMessage)

local helloSent = false

-- Say what we have, once per session, a little after login when the game has
-- finished loading and the guild name is known.
local function PlanHello()
    if helloSent or not (C_Timer and C_Timer.After) then
        return
    end
    C_Timer.After(8, function()
        if not helloSent and DW.IsMember() then
            helloSent = true
            SayHello()
        end
    end)
end

local frame = CreateFrame("Frame")

frame:SetScript("OnEvent", function(self, event, arg1)
    if not DW.IsMember() then
        return
    end

    if event == "CALENDAR_UPDATE_EVENT_LIST" then
        if view == "calendar" then
            RefreshPanel()
        end
    elseif event == "CALENDAR_UPDATE_ERROR" then
        OnCalendarError(arg1)
    else
        PlanHello()
    end
end)

for _, event in ipairs({ "PLAYER_ENTERING_WORLD", "CALENDAR_UPDATE_EVENT_LIST", "CALENDAR_UPDATE_ERROR" }) do
    pcall(frame.RegisterEvent, frame, event)
end

-- The guild name can arrive late after login. Then announce when it is ready.
DW.OnMembershipChanged(function(member)
    if member then
        PlanHello()
    end
end)

DW.OnLanguageChanged(function()
    RefreshPanel()
end)

-- Debugging: what we have saved, and whether the game's calendar is available.
DW.AddDebug("events", function(add)
    local text = DW.DebugText
    local total, visible = 0, #VisibleEvents()
    for _ in pairs(db.events) do
        total = total + 1
    end
    add(("lagret: %d events, %d vises for denne karakteren"):format(total, visible))
    add("C_Calendar: " .. text(C_Calendar ~= nil)
        .. " | AddEvent: " .. text(C_Calendar ~= nil and C_Calendar.AddEvent ~= nil)
        .. " | guild-event: " .. text(C_Calendar ~= nil and C_Calendar.CreateGuildSignUpEvent ~= nil)
        .. " | CanAddEvent: " .. text(C_Calendar and C_Calendar.CanAddEvent and select(2, pcall(C_Calendar.CanAddEvent))))
    local when = date("*t", time())
    add("date('*t'): " .. (type(when) == "table" and ("%s.%s.%s %s:%s"):format(text(when.day), text(when.month), text(when.year), text(when.hour), text(when.min)) or text(when)))
    add("lov til guild-events: " .. text(CanMakeGuildEvent()) .. " | siste kalenderfeil: " .. text(calendarProblem))
end)

-- Module -------------------------------------------------------------------------

DW.RegisterModule({
    id = MODULE_ID,
    titleKey = "EV_TITLE",
    notesKey = "EV_NOTES",
    icon = "Interface\\Icons\\INV_Scroll_03",

    OnLoad = function(self, saved)
        if type(saved.events) ~= "table" then
            saved.events = {}
        end
        db = saved
        PurgeExpired()
    end,

    CreatePanel = function(self, parent)
        return CreatePanel(parent)
    end,
})

-- The buttons blink (Alerts.lua) when someone else has posted an event that
-- applies to you, and you have not opened the tab since it arrived.
local function NewEvents(since)
    local list = {}
    local me = MyKey()
    for _, event in ipairs(VisibleEvents()) do
        if event.arrived and event.arrived > since and event.creator ~= me then
            list[#list + 1] = event
        end
    end
    return list
end

DW.RegisterAlert({
    kind = "event",
    module = MODULE_ID,
    labelKey = "AL_EVENT",
    color = { 1.00, 0.70, 0.15 }, -- gold
    Check = function(since)
        return #NewEvents(since) > 0
    end,
    -- The lines in the list at the button: title, when, and who posted it.
    Items = function(since)
        local items = {}
        for _, event in ipairs(NewEvents(since)) do
            items[#items + 1] = L.AL_EVENT_ITEM:format(event.title or "?", date("%d.%m.%Y %H:%M", event.when), ShortName(event.creator))
        end
        return items
    end,
})
