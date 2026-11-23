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
--   * The one who created an event, and officers (Admin.lua: by guild rank),
--     can delete it. A deletion names who deleted it (field 9 of E), and is
--     accepted from the creator, or from that person or an officer relaying
--     it when that person is the creator or an officer. Until DW.F6_CUTOFF,
--     deletions from before that time are also accepted from anyone when
--     field 9 is missing (older versions) or names the creator.
--     So only those pass deletions (and stopped weekly events) on. A deletion
--     may be at most 10 minutes ahead of the clock. Versions undecided, or
--     refused for the version itself (not only for who relayed it), are held
--     (DW.NewHeldStore). A deletion is final.
--   * A sign-up is taken from the player, or passed on by the creator or an
--     officer. Passed on by anyone else, it is taken only when we have no
--     answer from that player, and kept as weak: the player's own answer
--     replaces it. A Coming time before the event was made counts as that time.
--   * Events disappear from the list 12 hours after the start, and are
--     forgotten completely after a week.
--
-- Slots (optional): the creator can say how many tanks, healers and DPS are
-- needed, and a max. Those go in field 10 of E ("T2H3D5C10", plus "W1" for a
-- weekly event). Sign-ups then carry a role, when the player first said
-- Coming, and an optional comment, packed into the class field of S
-- ("CLASS;R;joined;comment"), which older versions store and pass on as it
-- is. Unslotted events without comments send exactly what older versions do.
-- With a max, the first Coming answers (by the time they first said Coming)
-- are in, the rest are on standby and move up when someone drops out.
--
-- Reminders: everyone who answered Coming or Maybe (on any character of the
-- account), and the organizer, gets a gold banner 15 minutes before and at the
-- start. Weekly events: when this week's event starts, the creator's account
-- makes next week's (same id shape, the start time in the id), with empty
-- sign-ups. Deleting one week keeps "W1" on the tombstone, so the series goes
-- on; Stop weekly sends the event without W1 and deletes later weeks without
-- it. The organizer (creator or officer) gets an Invite next button from an
-- hour before the start.
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
local ACTION_FUTURE = 600          -- how far ahead of the clock a deletion or stop may be
local MAX_TITLE_BYTES = 60
local MAX_NOTE_BYTES = 100
local MAX_MESSAGE_BYTES = 250      -- the game's limit is 255

-- Reminders, weekly events and Invite next.
local REMIND_BEFORE = 15 * 60      -- the "soon" reminder, before the start
local START_GRACE = 30 * 60        -- the "starts now" reminder can come this long after the start
local TICK = 30                    -- seconds between checks for reminders and weekly events
local INVITE_FROM = HOUR           -- Invite next shows from this long before the start
local INVITE_PENDING = 120         -- an invited person waits this long before coming back in line
local CONVERT_CHECK = 2.2          -- seconds before checking that Convert to raid worked
local REMIND_SOUND = (SOUNDKIT and SOUNDKIT.READY_CHECK) or 8960
local REMIND_SECONDS = 20          -- how long a reminder banner stays
local MAX_WEEK_STEPS = 520         -- guard when stepping a weekly event forward (10 years)

local STATUSES = { "Y", "M", "N" } -- coming, maybe, not coming
local STATUS_KEY = { Y = "EV_YES", M = "EV_MAYBE", N = "EV_NO" }

-- Saved data. Set in OnLoad at the bottom.
--   db.events[id] = {
--       id, creator, title, note,
--       when     = the time the event starts,
--       updated  = when it was last changed (newest version wins),
--       deleted  = true if it is deleted (kept so the deletion spreads),
--       deletedBy = "Name-Realm" of who deleted it (nil for old relayed deletions),
--       signups  = { ["Navn-Realm"] = { status = "Y"/"M"/"N", updated, class,
--                      role = "T"/"H"/"D" or nil,
--                      joined = server time of the first Coming in the current run of Coming answers, or nil,
--                      comment = short text or nil } },
--       need     = { T = n, H = n, D = n } or nil (nil when all are 0),
--       cap      = the max number of players (1-40) or nil,
--       weekly   = true for a weekly event (field 10 "W1"),
--       arrived  = when we got it from someone else (server clock), for the blinking
--       sentByMe = the updated value of the last version this account wrote
--                  and sent (a weekly series is only rebuilt from those)
--       stoppedBy = "Name-Realm" of who stopped a weekly event (field 9 on a
--                  version that is not deleted)
--   }
--   db.seq = counter that makes every id unique
--   db.held = deletions held for trust reasons (DW.NewHeldStore)
--   db.series[seriesKey] = weekly events this account makes the next week of:
--       { creator, seq, title, note, aud, min, max, invited, invitedCount, cal,
--         own, need, cap, lastWhen }, seriesKey = "<creator>:<seq of the id>"
--   db.reminded[id] = { soon = true, start = true }: reminders already shown
--       (account-wide, so another character is not reminded again)
--   db.remind = false when reminders are turned off (nil = on)
local db = { events = {} }
local held = DW.NewHeldStore({}) -- replaced in OnLoad

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

-- When the event was created (the time in its id).
local function CreatedOf(id)
    return tonumber(id:match("^.+:(%d+):%d+$"))
end

-- Slots, roles and comments -------------------------------------------------------

local MAX_SLOTS = 40
local MAX_COMMENT_BYTES = 40
local ROLE_BY_CODE = {}
for _, role in ipairs(DW.ROLES) do
    ROLE_BY_CODE[role.code] = role
end

-- Does the event have needed roles or a max?
local function IsSlotted(event)
    return event ~= nil and (event.need ~= nil or event.cap ~= nil)
end

local function ClampSlots(value)
    value = math.floor(tonumber(value) or 0)
    if value < 0 then
        return 0
    elseif value > MAX_SLOTS then
        return MAX_SLOTS
    end
    return value
end

-- { T, H, D } with each clamped to 0-40, or nil when all are 0.
local function NeedOf(tanks, healers, dps)
    tanks, healers, dps = ClampSlots(tanks), ClampSlots(healers), ClampSlots(dps)
    if tanks + healers + dps == 0 then
        return nil
    end
    return { T = tanks, H = healers, D = dps }
end

-- Field 10 of E: "T2H3D5C10W1", only the values above 0. "" for none.
local function ExtraText(event)
    local parts = {}
    local need = type(event.need) == "table" and event.need or {}
    for _, role in ipairs(DW.ROLES) do
        local count = ClampSlots(need[role.code])
        if count > 0 then
            parts[#parts + 1] = role.code .. Num(count)
        end
    end
    local cap = ClampSlots(event.cap)
    if cap > 0 then
        parts[#parts + 1] = "C" .. Num(cap)
    end
    if event.weekly then
        parts[#parts + 1] = "W1"
    end
    return table.concat(parts)
end

-- Reads field 10 of E. Returns need, cap and weekly. Unknown letters are ignored.
local function ParseExtra(extra)
    local counts = { T = 0, H = 0, D = 0 }
    local cap, weekly
    for letter, digits in tostring(extra or ""):gmatch("(%u)(%d+)") do
        if counts[letter] then
            counts[letter] = ClampSlots(digits)
        elseif letter == "C" then
            local value = ClampSlots(digits)
            cap = (value > 0) and value or nil
        elseif letter == "W" and digits == "1" then
            weekly = true
        end
    end
    return NeedOf(counts.T, counts.H, counts.D), cap, weekly
end

-- The class field of a sign-up in S. Just the class, as older versions send,
-- unless the sign-up has a role, a joined time (only for Coming) or a comment:
-- "CLASS;role;joined;comment". It follows what the sign-up carries, not our
-- copy of the event, so a copy that lacks the slots still passes them on.
-- Your own sign-ups get a role and a joined time only for slotted events
-- (SetSignup), so unslotted events still send just the class.
local function ClassField(signup)
    local class = signup.class or ""
    local role = ROLE_BY_CODE[signup.role or ""] and signup.role or ""
    local joined = (signup.status == "Y" and type(signup.joined) == "number") and Num(signup.joined) or ""
    local comment = signup.comment or ""
    if role == "" and joined == "" and comment == "" then
        return class
    end
    return table.concat({ class, role, joined, comment }, ";")
end

-- Reads the class field of a sign-up for the event id. Returns class, role,
-- joined and comment; an invalid role or time is dropped.
local function ParseClassField(field, id)
    local class, role, joined, comment = field:match("^([^;]*);([^;]*);([^;]*);(.*)$")
    -- A class is a short token ("WARRIOR"); anything else is dropped, so a
    -- relayed sign-up always fits in a message.
    local function Class(text)
        return (#text <= 12 and text:match("^[A-Z]+$")) and text or ""
    end
    if not class then
        return Class(field)
    end
    class = Class(class)
    role = ROLE_BY_CODE[role] and role or nil
    joined = joined:match("^%d+$") and tonumber(joined) or nil
    if joined then
        -- Not in the future, and not long before the event was made, so a
        -- made-up time cannot jump the standby queue. A generated weekly
        -- event has its start time in the id, a week after it was made, so
        -- eight days are allowed.
        local created = CreatedOf(id)
        if not created or joined > DW.ServerNow() + 600 or joined < created - 8 * DAY then
            joined = nil
        end
    end
    comment = Clean(comment, MAX_COMMENT_BYTES)
    return class, role, joined, (comment ~= "" and comment) or nil
end

-- Who is in, on standby, maybe and not coming, in that order, and how the
-- roles are filled.
--   coming, standby, maybe, no = lists of sign-up keys
--   roleIn    = { T, H, D, ["?"] } counts among those who are in ("?" = no role)
--   roleMaybe = the same among the Maybe answers
--   missing   = { T, H, D }: needed minus in, at least 0
-- Coming answers are ordered by when they first said Coming; answers from
-- older versions (no time) come after, by when they answered. With a max the
-- first ones are in and the rest on standby. Unslotted events keep the old
-- order (by name).
local function Lineup(event)
    local result = {
        coming = {}, standby = {}, maybe = {}, no = {},
        roleIn = { T = 0, H = 0, D = 0, ["?"] = 0 },
        roleMaybe = { T = 0, H = 0, D = 0, ["?"] = 0 },
        missing = { T = 0, H = 0, D = 0 },
    }
    local signups = event.signups or {}
    local yes = {}
    for _, key in ipairs(SortedKeys(signups)) do
        local status = signups[key].status
        if status == "Y" then
            yes[#yes + 1] = key
        elseif status == "M" then
            result.maybe[#result.maybe + 1] = key
        elseif status == "N" then
            result.no[#result.no + 1] = key
        end
    end
    if IsSlotted(event) then
        -- Nobody said Coming before the event was made: an earlier time is
        -- counted as that time, so a made-up one cannot jump the queue. A
        -- weekly event's id has its start time, about a week after it was
        -- made, so for those a week (and a day) before that.
        local created = event.id and CreatedOf(event.id)
        local floor = created and (event.weekly and created - 8 * DAY or created) or nil
        local function JoinedOf(signup)
            if type(signup.joined) ~= "number" then
                return nil
            end
            return floor and math.max(signup.joined, floor) or signup.joined
        end
        table.sort(yes, function(a, b)
            local sa, sb = signups[a], signups[b]
            local ja = JoinedOf(sa)
            local jb = JoinedOf(sb)
            if ja and jb then
                if ja ~= jb then
                    return ja < jb
                end
            elseif ja or jb then
                return ja ~= nil
            elseif sa.updated ~= sb.updated then
                return sa.updated < sb.updated
            end
            return a < b
        end)
    end
    local cap = event.cap
    for index, key in ipairs(yes) do
        if cap and index > cap then
            result.standby[#result.standby + 1] = key
        else
            result.coming[#result.coming + 1] = key
            local role = signups[key].role
            role = ROLE_BY_CODE[role or ""] and role or "?"
            result.roleIn[role] = result.roleIn[role] + 1
        end
    end
    for _, key in ipairs(result.maybe) do
        local role = signups[key].role
        role = ROLE_BY_CODE[role or ""] and role or "?"
        result.roleMaybe[role] = result.roleMaybe[role] + 1
    end
    local need = type(event.need) == "table" and event.need or {}
    for _, role in ipairs(DW.ROLES) do
        result.missing[role.code] = math.max(0, (need[role.code] or 0) - result.roleIn[role.code])
    end
    result.inCount = #result.coming
    return result
end

-- "1 Tank, 2 DPS": the roles still missing, or "" when none are.
local function MissingList(lineup)
    local items = {}
    for _, role in ipairs(DW.ROLES) do
        local count = lineup.missing[role.code]
        if count > 0 then
            items[#items + 1] = ("%d %s"):format(count, L[role.key])
        end
    end
    return table.concat(items, ", ")
end

-- Does the event need any role?
local function NeedsRoles(event)
    if type(event.need) ~= "table" then
        return false
    end
    for _, role in ipairs(DW.ROLES) do
        if (event.need[role.code] or 0) > 0 then
            return true
        end
    end
    return false
end

-- Place in the standby queue (1 = next in), or nil when not on standby.
local function StandbyPosition(event, key)
    for index, other in ipairs(Lineup(event).standby) do
        if other == key then
            return index
        end
    end
    return nil
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
    if type(db.reminded) == "table" then
        for id in pairs(db.reminded) do
            if db.events[id] == nil then
                db.reminded[id] = nil
            end
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

-- authored = true when this account wrote this version (made, changed or
-- deleted it here), not when it only passes on a stored copy.
local function SendEvent(event, authored)
    if authored then
        event.sentByMe = event.updated
    end
    -- Field 10: slots and weekly ("" when there is nothing to send). It is
    -- part of the message length below, so the note is cut to make room.
    local extra = ExtraText(event)
    local function Build(note)
        local fields = {
            "E", event.id, Num(event.updated), Num(event.when), event.deleted and "1" or "0",
            event.title or "", note, MetaOf(event),
        }
        -- Field 9: who deleted it, written when deleted (or when field 10
        -- follows). On a weekly event that was stopped (not deleted) it is
        -- who stopped it. Ordinary events still send exactly 8 fields.
        if event.deleted or extra ~= "" or event.stoppedBy then
            if event.deleted then
                fields[9] = event.deletedBy or event.creator or ""
            else
                fields[9] = event.stoppedBy or ""
            end
        end
        if extra ~= "" then
            fields[10] = extra
        end
        return table.concat(fields, SEP)
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
            local entry = table.concat({ player, signup.status, Num(signup.updated), ClassField(signup) }, ",")
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

-- May we pass this event on? A deletion or a stopped weekly event is an
-- officer action: receivers take it only from the one who did it, the
-- creator, or an officer (deletions from before officer ranks from anyone,
-- until DW.F6_CUTOFF). Anything else, any member may pass on.
local function MayRelay(event)
    if not (event.deleted or event.stoppedBy) then
        return true
    end
    local actor = event.deleted and event.deletedBy or event.stoppedBy
    local me = MyKey()
    if DW.IsOfficer() or DW.SameCharacter(me, event.creator) or (actor and DW.SameCharacter(me, actor)) then
        return true
    end
    return event.deleted and (actor == nil or DW.SameCharacter(actor, event.creator))
        and event.updated < DW.F6_CUTOFF and DW.ServerNow() < DW.F6_CUTOFF or false
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
            if offer.event and (seen.events[id] or -1) < event.updated and MayRelay(event) then
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
-- A held version counts as one we have.
local function SayHello()
    PurgeExpired()
    held:Purge()
    local entries = {}
    for _, id in ipairs(SortedKeys(db.events)) do
        local event = db.events[id]
        if Syncable(event) then
            local count, newest = Digest(event)
            -- A held version from the future (perhaps forged) is not claimed.
            local heldVersion = held:Version(id)
            if heldVersion and heldVersion > math.max(time(), DW.ServerNow()) + ACTION_FUTURE then
                heldVersion = nil
            end
            local updated = math.max(event.updated, heldVersion or 0)
            entries[#entries + 1] = table.concat({ id, Num(updated), Num(count), Num(newest) }, ",")
        end
    end
    SendList("H", entries)
    Send("Q")
end

-- Receiving -------------------------------------------------------------------

-- Is this the version we hold, with the slots (field 10) that our copy lacks?
-- Older versions pass an event on with only 8 fields at the same updated, so
-- a member can end up with the event but not its slots. The full copy then
-- fills them in.
local function FillsExtra(event, updated, deleted, extra)
    if updated ~= event.updated or (event.deleted and true or false) ~= (deleted and true or false) then
        return false
    end
    if event.need or event.cap or event.weekly then
        return false
    end
    -- A version this account wrote is complete as we have it: nobody can add
    -- slots or W1 to it at the same time (a forged W1 would start a series).
    if event.sentByMe ~= nil and event.sentByMe == event.updated then
        return false
    end
    local need, cap, weekly = ParseExtra(extra)
    return (need or cap or weekly) and true or false
end

-- Would ApplyEvent take this version (before any trust check)?
-- actor: field 9. A deletion, or a version naming who stopped a weekly
-- event, may be at most ACTION_FUTURE ahead of the clock (others a day, for
-- slow clocks), so a forged far-future one cannot be held and block real versions.
local function WouldApplyEvent(id, updated, when, deleted, extra, actor)
    local now = time()
    if not CreatorOf(id) or updated > now + DAY or when <= now - KEEP_AFTER_START then
        return false
    end
    if (deleted or actor) and updated > math.max(now, DW.ServerNow()) + ACTION_FUTURE then
        return false
    end
    local event = db.events[id]
    if event and not event.stub then
        if FillsExtra(event, updated, deleted, extra) then
            return true
        end
        if updated <= event.updated then
            return false -- we have the same or a newer version
        end
        if event.deleted and not deleted then
            return false -- a deletion is final
        end
    end
    return true
end

-- Receives an event from someone else. Returns true if anything changed.
-- deletedBy is field 9: who deleted it (for deleted versions, when known) or
-- who stopped a weekly event (for others), and extra is field 10 (slots and
-- weekly; nil from older versions, which clears them).
local function ApplyEvent(id, updated, when, deleted, title, note, meta, deletedBy, extra)
    if not WouldApplyEvent(id, updated, when, deleted, extra, deletedBy) then
        return false
    end
    local creator = CreatorOf(id)
    local now = time()

    local event = db.events[id]
    if event and not event.stub and updated == event.updated then
        -- The same version: only the slots were missing (FillsExtra).
        event.need, event.cap, event.weekly = ParseExtra(extra)
        return true
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
    event.deletedBy = deleted and (deletedBy or event.deletedBy) or nil
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
    event.need, event.cap, event.weekly = ParseExtra(extra)
    -- On a version that is not deleted, field 9 names who stopped the weekly
    -- event (kept so it is passed on; trust was checked in OnMessage).
    event.stoppedBy = (not deleted and not event.weekly and deletedBy) or nil
    return true
end

-- Receives a sign-up. Returns true if anything changed.
-- weak: passed on by someone who may not speak for the player (see OnMessage
-- S); a later answer that is not weak replaces it whatever its time.
local function ApplySignup(id, player, status, updated, class, role, joined, comment, weak)
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
    if current and updated <= current.updated and not (current.weak and not weak) then
        return false
    end
    if current and weak and not current.weak then
        return false
    end
    event.signups[player] = {
        status = status, updated = updated, class = (class ~= "" and class) or nil,
        role = role, joined = joined, comment = comment, weak = weak or nil,
    }
    return true
end

-- Moving up from standby. Memory only: standbyState[id] = my place in the
-- standby queue (0 = in) for events with a max where I said Coming. The first
-- look at an event is silent; going from standby to in says so in chat.
local standbyState, standbyFor = {}, nil

local function CheckPromotion()
    local me = MyKey()
    if not me then
        return
    end
    if standbyFor ~= me then
        standbyState, standbyFor = {}, me
    end
    for id, event in pairs(db.events) do
        local mine = type(event) == "table" and not event.stub and not event.deleted and event.cap
            and type(event.signups) == "table" and event.signups[me]
        if mine and mine.status == "Y" then
            local place = StandbyPosition(event, me) or 0
            local before = standbyState[id]
            standbyState[id] = place
            if before and before > 0 and place == 0 then
                DW.Print(L.EV_PROMOTED:format(event.title or "?"))
            end
        else
            standbyState[id] = nil
        end
    end
end

local function AfterChange()
    CheckPromotion()
    RefreshPanel()
    if DW.QueueAlertRefresh then
        DW.QueueAlertRefresh()
    end
end

local function OnMessage(text, sender)
    local fields = Split(text, SEP)
    local kind = fields[1]
    local changed = false

    if kind == "E" and #fields >= 7 then
        local id, updated, when = fields[2], tonumber(fields[3]), tonumber(fields[4])
        if id ~= "" and updated and when then
            local deleted = fields[5] == "1"
            local existing = db.events[id]
            local creator = CreatorOf(id)
            -- Field 9: who deleted it, or who stopped a weekly event.
            local actor = (fields[9] ~= nil and fields[9] ~= "") and fields[9] or nil
            -- A newer version that is not deleted but takes W1 away from a
            -- weekly event we have stops the series: an officer action, like
            -- a deletion.
            local _, _, weeklyIn = ParseExtra(fields[10])
            local stops = not deleted and creator ~= nil and existing ~= nil and not existing.stub and not existing.deleted
                and existing.weekly and not weeklyIn and updated > existing.updated
            -- Would the others take this deletion or stop from this sender?
            -- The same rules as below.
            local function Trusted()
                if creator == nil then
                    return true
                end
                if DW.SameCharacter(sender, creator) and (actor == nil or DW.SameCharacter(actor, creator)) then
                    return true
                end
                if deleted and (actor == nil or DW.SameCharacter(actor, creator))
                    and updated < DW.F6_CUTOFF and DW.ServerNow() < DW.F6_CUTOFF then
                    return true
                end
                if actor == nil then
                    return false
                end
                local actorOk = DW.SameCharacter(actor, creator) or DW.IsOfficerKey(actor) == true
                return actorOk and DW.MayActFor(sender, actor) == true
            end
            -- An older version passes our version on without the slots. Then
            -- it does not count as sent, so our full copy still goes out. Nor
            -- does a deletion or stop the others will refuse from this sender.
            local ours = (existing and not existing.stub and existing.updated == updated) and ExtraText(existing) or ""
            if (ours == "" or (fields[10] or "") == ours) and (not (deleted or stops) or Trusted()) then
                MarkSeenEvent(id, updated)
            end
            local function Apply(deletedBy)
                local applied = ApplyEvent(id, updated, when, deleted, fields[6], fields[7], fields[8], deletedBy, fields[10])
                if applied then
                    held:Clear(id, updated)
                end
                return applied
            end
            -- Keeps a refused or undecided version, so it is tried again when
            -- the officers change. Not when only the relayer was refused: the
            -- version itself is fine, and a copy from the creator or an
            -- officer must still be asked for.
            local function Hold()
                if actor and (DW.SameCharacter(actor, creator) or DW.IsOfficerKey(actor) == true)
                    and DW.MayActFor(sender, actor) == false then
                    return
                end
                if WouldApplyEvent(id, updated, when, deleted, fields[10], actor) then
                    held:Hold(id, updated, function()
                        OnMessage(text, sender)
                    end, sender)
                end
            end
            if stops then
                if DW.SameCharacter(sender, creator) and (actor == nil or DW.SameCharacter(actor, creator)) then
                    changed = Apply(creator)
                elseif actor then
                    local result = DW.WhenOfficerAction("events:W:" .. id .. ":" .. updated, sender, actor, creator, function(ok)
                        if ok then
                            if Apply(actor) then
                                AfterChange()
                            end
                        else
                            Hold()
                        end
                    end)
                    if result == nil then
                        Hold()
                    end
                else
                    Hold()
                end
            elseif not deleted or (existing and not existing.stub and existing.deleted) or not creator then
                -- Not a deletion (or already deleted for us): as before.
                changed = Apply((not deleted) and actor or nil)
            else
                local deleter = actor
                local byCreator = deleter ~= nil and DW.SameCharacter(deleter, creator)
                if DW.SameCharacter(sender, creator) and (deleter == nil or byCreator) then
                    -- Directly from the creator.
                    changed = Apply(creator)
                elseif (deleter == nil or byCreator) and updated < DW.F6_CUTOFF and DW.ServerNow() < DW.F6_CUTOFF then
                    -- A deletion from before officer ranks, relayed by anyone
                    -- (as before) while old deletions still count. Updated
                    -- versions name the creator in field 9 when re-sending one.
                    changed = Apply(byCreator and creator or nil)
                elseif deleter then
                    -- The deleter is the creator or an officer, and the sender
                    -- is the deleter or an officer relaying it.
                    local result = DW.WhenOfficerAction("events:E:" .. id .. ":" .. updated, sender, deleter, creator, function(ok)
                        if ok then
                            if Apply(deleter) then
                                AfterChange()
                            end
                        else
                            Hold()
                        end
                    end)
                    if result == nil then
                        Hold()
                    end
                else
                    Hold()
                end
            end

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
                local player, status, updated, field = fields[index]:match("^([^,]+),(%a),(%d+),([^,]*)$")
                updated = tonumber(updated)
                if player and updated then
                    -- From the player, or passed on by the creator or an officer:
                    -- taken as any newer answer. Passed on by anyone else (any
                    -- member could write it): taken only when we have no answer
                    -- from that player, and kept as weak, so the player's own
                    -- answer always replaces it.
                    local trusted = DW.SameCharacter(player, sender) or DW.SameCharacter(sender, CreatorOf(id))
                        or DW.IsOfficerKey(sender) == true
                    if trusted then
                        MarkSeenSignup(id, player, updated)
                    end
                    local current = db.events[id] and db.events[id].signups[player]
                    if trusted or not current then
                        -- Role, joined and comment ride inside the class field.
                        local class, role, joined, comment = ParseClassField(field, id)
                        if ApplySignup(id, player, status, updated, class, role, joined, comment, not trusted) then
                            changed = true
                        end
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
                -- The very version we hold (refused or undecided) counts as one we
                -- have. Only that one: a held version with a later time (perhaps
                -- forged) must not stop us asking for real versions before it. The
                -- creator or an officer can send a copy we accept, so from them we
                -- ask all the same.
                local heldEvent = held:Version(id) == theirUpdated and DW.IsOfficerKey(sender) ~= true
                    and not DW.SameCharacter(sender, CreatorOf(id))
                if not mine or mine.stub then
                    if not heldEvent then
                        wanted[id] = true
                    end
                else
                    if theirUpdated > mine.updated then
                        if not heldEvent then
                            wanted[id] = true
                        end
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
        CheckPromotion()
        RefreshPanel()
        if DW.QueueAlertRefresh then
            DW.QueueAlertRefresh()
        end
    end
end

-- Actions ---------------------------------------------------------------------

local selectedID -- the event shown on the right
local forcedID   -- an event opened from a reminder, shown even if not in the list for this character
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
-- audience.need = { T, H, D } and audience.cap = n give the slots (optional).
-- audience.weekly = true makes it repeat every week.
local CreateEvent

-- Weekly events -----------------------------------------------------------------

-- The series an event belongs to: "<creator>:<the counter at the end of the id>".
-- Every week of a weekly event has the same creator and counter.
local function SeriesKeyOf(id)
    local creator, seq = tostring(id):match("^(.+):%d+:(%d+)$")
    if not creator then
        return nil
    end
    return creator .. ":" .. seq, creator, seq
end

-- The same time of day a week later (date and time() keep the clock time
-- across a change to or from summer time).
local function NextWeek(when)
    local t = date("*t", when)
    return time({ year = t.year, month = t.month, day = t.day + 7, hour = t.hour, min = t.min, sec = 0 })
end

local function CopySet(set)
    if type(set) ~= "table" then
        return nil
    end
    local copy = {}
    for key, value in pairs(set) do
        copy[key] = value
    end
    return copy
end

-- Fills a series template from one week of it.
local function FillTemplate(template, event)
    local _, creator, seq = SeriesKeyOf(event.id)
    template.creator, template.seq = creator, seq
    template.title, template.note = event.title, event.note
    template.aud, template.min, template.max = event.aud, event.min, event.max
    template.invited, template.invitedCount = CopySet(event.invited), event.invitedCount
    template.cal, template.own = event.cal, event.own
    template.need, template.cap = CopySet(event.need), event.cap
    template.lastWhen = event.when
    return template
end

-- The latest week of a series by start time, deleted weeks included.
local function LatestOfSeries(key)
    local latest
    for id, event in pairs(db.events) do
        if type(event) == "table" and not event.stub and type(event.when) == "number" and SeriesKeyOf(id) == key then
            if not latest or event.when > latest.when or (event.when == latest.when and id > latest.id) then
                latest = event
            end
        end
    end
    return latest
end

-- Makes next week's event for every series this account owns, when this
-- week's has started. Follows the latest week first: a week that is no longer
-- weekly means the series was stopped (here or by an officer); a deleted week
-- that is still weekly was only cancelled. Never fills in weeks that were missed.
local function GenerateDue()
    if not DW.IsMember() or type(db.series) ~= "table" then
        return
    end
    local now = time()
    for _, key in ipairs(SortedKeys(db.series)) do
        local template = db.series[key]
        local latest = LatestOfSeries(key)
        local stopped = false
        if latest and latest.when >= template.lastWhen then
            if not latest.weekly then
                stopped = true
            elseif latest.deleted or latest.sentByMe ~= latest.updated then
                -- Cancelled this week, or a week this account did not write
                -- (only our own weeks may change what later weeks look like).
                template.lastWhen = latest.when
            else
                FillTemplate(template, latest)
            end
        end
        if stopped then
            db.series[key] = nil
        elseif now >= template.lastWhen then
            local nextWhen, steps = NextWeek(template.lastWhen), 0
            while nextWhen <= now and steps < MAX_WEEK_STEPS do
                nextWhen, steps = NextWeek(nextWhen), steps + 1
            end
            local id = ("%s:%d:%s"):format(template.creator, nextWhen, template.seq)
            local existing = db.events[id]
            if not existing or existing.stub then
                local event = {
                    id = id,
                    creator = template.creator,
                    title = template.title,
                    note = template.note,
                    when = nextWhen,
                    updated = now,
                    -- Sign-ups that came before the event itself are kept.
                    signups = existing and existing.signups or {},
                    cal = template.cal,
                    own = template.own,
                    aud = template.aud,
                    min = template.min,
                    max = template.max,
                    invited = CopySet(template.invited),
                    invitedCount = template.invitedCount,
                    need = CopySet(template.need),
                    cap = template.cap,
                    weekly = true,
                }
                if event.aud == "P" and not event.invited then
                    event.invited = {}
                end
                db.events[id] = event
                SendEvent(event, true)
            end
            template.lastWhen = nextWhen
        end
    end
end

-- A series whose template is gone (saved data from before, or lost) is built
-- again from its latest week, but only from weeks this account made and sent
-- itself. A weekly version received from someone else never starts a series.
local function RecoverSeries()
    local me = MyKey()
    if not me or type(db.series) ~= "table" then
        return
    end
    for id, event in pairs(db.events) do
        local key, creator = SeriesKeyOf(id)
        if type(event) == "table" and not event.stub and event.weekly and creator == me and not db.series[key]
            and event.sentByMe ~= nil and event.updated == event.sentByMe then
            db.series[key] = FillTemplate({}, LatestOfSeries(key) or event)
        end
    end
end

CreateEvent = function(title, note, when, audience)
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
    local need = type(audience.need) == "table" and audience.need or {}
    event.need = NeedOf(need.T, need.H, need.D)
    local cap = ClampSlots(audience.cap)
    event.cap = (cap > 0) and cap or nil
    event.weekly = audience.weekly and true or nil
    db.events[event.id] = event
    if event.weekly and type(db.series) == "table" then
        db.series[SeriesKeyOf(event.id)] = FillTemplate({}, event)
    end
    SendEvent(event, true)
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

-- The creator and officers may delete an event.
local function CanDelete(event)
    return event ~= nil and (event.creator == MyKey() or DW.IsOfficer())
end

local function DeleteEvent(event)
    if not CanDelete(event) then
        return
    end
    -- A weekly event keeps W1 on its tombstone: only this week is gone.
    event.deleted = true
    event.deletedBy = MyKey()
    event.updated = math.max(time(), event.updated + 1)
    SendEvent(event, true)
end

-- The creator and officers organize an event: Invite next, Stop weekly.
local function CanOrganize(event)
    return event ~= nil and (event.creator == MyKey() or DW.IsOfficer())
end

-- Ends a weekly series: this week is sent without W1, and every later week
-- is deleted with a tombstone without W1. The creator's account then sees a
-- latest week that is not weekly and drops its template (GenerateDue).
local function StopWeekly(event)
    if not CanOrganize(event) or event.deleted then
        return
    end
    local key = SeriesKeyOf(event.id)
    local me = MyKey()
    event.weekly = nil
    event.stoppedBy = me -- field 9, so others can check that I may stop it
    event.updated = math.max(time(), event.updated + 1)
    SendEvent(event, true)
    for _, id in ipairs(SortedKeys(db.events)) do
        local other = db.events[id]
        if other ~= event and type(other) == "table" and not other.stub and not other.deleted
            and type(other.when) == "number" and other.when > event.when and SeriesKeyOf(id) == key then
            other.deleted = true
            other.deletedBy = me
            other.weekly = nil
            other.updated = math.max(time(), other.updated + 1)
            SendEvent(other, true)
        end
    end
    if key and type(db.series) == "table" then
        db.series[key] = nil
    end
    DW.Print(L.EV_STOPPED:format(event.title or "?"))
end

-- The roles you play, in DW.ROLES order: from your profile, or else from your
-- dungeon status.
local function MyRoleChoices()
    local set = DW.GetMyRoles and DW.GetMyRoles() or {}
    if type(set) ~= "table" or next(set) == nil then
        local _, entry = DW.GetMyStatus()
        set = (entry and type(entry.roles) == "table") and entry.roles or {}
    end
    local codes = {}
    for _, role in ipairs(DW.ROLES) do
        if set[role.code] then
            codes[#codes + 1] = role.code
        end
    end
    return codes
end

-- The role 'Coming' fills in for you: your only role, or of your roles the
-- one the event lacks most (counted without your own sign-up), ties in
-- DW.ROLES order. nil when you have not chosen a role.
local function AutoRole(event)
    local codes = MyRoleChoices()
    if #codes <= 1 then
        return codes[1]
    end
    local me = MyKey()
    local others = {}
    for key, signup in pairs(event.signups) do
        if key ~= me then
            others[key] = signup
        end
    end
    local lineup = Lineup({ signups = others, need = event.need, cap = event.cap })
    local need = type(event.need) == "table" and event.need or {}
    local best, bestGap
    for _, code in ipairs(codes) do
        local gap = (need[code] or 0) - lineup.roleIn[code]
        if not bestGap or gap > bestGap then
            best, bestGap = code, gap
        end
    end
    return best
end

local function SetSignup(event, status)
    local me = MyKey()
    if not me then
        return
    end
    local previous = event.signups[me]
    local slotted = IsSlotted(event)
    -- Role and comment stay from the previous answer. Not coming has no role,
    -- and unslotted events have neither a role nor a joined time, so their
    -- sign-ups still send just the class.
    local role = slotted and previous and previous.role or nil
    if status == "N" then
        role = nil
    elseif slotted and not role then
        role = AutoRole(event)
    end
    -- Your place in the queue is kept while you keep saying Coming.
    local joined
    if slotted and status == "Y" then
        joined = (previous and previous.status == "Y" and previous.joined) or DW.ServerNow()
    end
    event.signups[me] = {
        status = status,
        -- Always newer than the previous answer, even if the clock stands still for a second.
        updated = math.max(time(), previous and (previous.updated + 1) or 0),
        class = select(2, UnitClass("player")),
        role = role,
        joined = joined,
        comment = previous and previous.comment or nil,
    }
    SendSignups(event, { [me] = true })
    if slotted and status ~= "N" and not role then
        DW.Print(L.EV_PICK_ROLE)
    end
    if status == "Y" then
        local place = StandbyPosition(event, me)
        if place then
            DW.Print(L.EV_STANDBY_PRINT:format(place))
        end
    end
    CheckPromotion()
end

-- Changes one field of your own sign-up (role or comment) as a new version:
-- newer time, the same answer and the same place in the queue.
local function ChangeMySignup(event, field, value)
    local me = MyKey()
    local previous = me and event.signups[me]
    if not previous or previous[field] == value then
        return false
    end
    local copy = {}
    for key, old in pairs(previous) do
        copy[key] = old
    end
    copy[field] = value
    copy.updated = math.max(time(), previous.updated + 1)
    event.signups[me] = copy
    SendSignups(event, { [me] = true })
    CheckPromotion()
    return true
end

local function SetMyRole(event, code)
    if not ROLE_BY_CODE[code or ""] then
        return false
    end
    return ChangeMySignup(event, "role", code)
end

local function CleanComment(text)
    -- Commas separate the sign-ups in a message.
    local comment = (Clean(text, MAX_COMMENT_BYTES):gsub(",", ";"))
    return (comment ~= "" and comment) or nil
end

local function SetMyComment(event, text)
    return ChangeMySignup(event, "comment", CleanComment(text))
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
    -- Roles still missing, as plain text (no icons in guild chat).
    if NeedsRoles(event) then
        local missing = MissingList(Lineup(event))
        if missing ~= "" then
            head = head .. " - " .. L.EV_MISSING:format(missing)
        end
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

-- Reminders -----------------------------------------------------------------------

-- Your answer to an event: the character you play first, then another
-- character on the account that is in the guild, preferring one that said
-- Coming or Maybe. Returns signup and its key.
local function MySignupFor(event)
    local me = MyKey()
    if me and event.signups[me] then
        return event.signups[me], me
    end
    local characters = type(DragonworldDB) == "table" and DragonworldDB.memberCharacters
    local other, otherKey
    if type(characters) == "table" then
        for _, key in ipairs(SortedKeys(characters)) do
            local signup = key ~= me and event.signups[key]
            if signup then
                if signup.status == "Y" or signup.status == "M" then
                    return signup, key
                end
                other, otherKey = other or signup, otherKey or key
            end
        end
    end
    return other, otherKey
end

-- Shows a reminder: the gold banner (always, whatever the banner setting in
-- Achievements says; reminders have their own box) and a line in chat.
--   kind = "soon" or "start"; key = the character that answered (or nil);
--   organizer = true adds what the organizer should do on the start banner.
local function ShowReminder(event, kind, key, organizer, now)
    local id, title = event.id, event.title or "?"
    local minutes = math.max(1, math.ceil((event.when - (now or time())) / 60))
    local function Main()
        if kind == "soon" then
            return L.EV_REMIND_SOON:format(title, minutes)
        end
        return L.EV_REMIND_START:format(title)
    end
    local function Text()
        local lines = { Main() }
        if key and key ~= MyKey() then
            lines[#lines + 1] = L.EV_REMIND_ON_ALT:format(ShortName(key))
        end
        if organizer and kind == "start" then
            -- What is missing comes first: the banner shows at most three
            -- lines, and the organizer text wraps to two.
            if NeedsRoles(event) then
                local missing = MissingList(Lineup(event))
                if missing ~= "" then
                    lines[#lines + 1] = L.EV_MISSING:format(missing)
                end
            end
            lines[#lines + 1] = L.EV_REMIND_ORGANIZER
        end
        return table.concat(lines, "\n")
    end
    DW.Print(Main())
    if DW.ShowBanner then
        DW.ShowBanner({
            key = "ev:" .. id .. ":" .. kind,
            always = true,
            -- Time-critical, and marked as done once asked for: it goes first
            -- in the queue, even when the queue is full.
            urgent = true,
            title = function() return L.EV_REMIND_TITLE end,
            text = Text,
            button = function() return L.EV_REMIND_OPEN end,
            onClick = function()
                if DW.ShowEvent then
                    DW.ShowEvent(id)
                end
            end,
            sound = REMIND_SOUND,
            seconds = REMIND_SECONDS,
        })
    end
end

-- Looks for reminders that are due: 15 minutes before, and at the start (for
-- up to 30 minutes after). For everyone who answered Coming or Maybe on a
-- character of the account, and for the event's creator. Officers are
-- reminded only through their own answer. Each is shown once per account.
-- Not limited to events for the character you play, since the answer may
-- come from another one (the Open button then shows it anyway, DW.ShowEvent).
local function CheckReminders()
    if db.remind == false or not DW.IsMember() or type(db.reminded) ~= "table" then
        return
    end
    local now = time()
    for _, id in ipairs(SortedKeys(db.events)) do
        local event = db.events[id]
        local when = type(event) == "table" and not event.stub and not event.deleted and event.when
        if type(when) == "number" and now >= when - REMIND_BEFORE and now < when + START_GRACE
            and type(event.signups) == "table" then
            local signup, key = MySignupFor(event)
            local organizer = event.creator ~= nil and event.creator == MyKey()
            if (signup and (signup.status == "Y" or signup.status == "M")) or organizer then
                local done = db.reminded[id] or {}
                if now >= when and not done.start then
                    done.start, done.soon = true, true
                    db.reminded[id] = done
                    ShowReminder(event, "start", key, organizer, now)
                elseif now < when and not done.soon then
                    done.soon = true
                    db.reminded[id] = done
                    -- An answer given inside the last 15 minutes needs no reminder.
                    if not (signup and type(signup.updated) == "number" and signup.updated >= when - REMIND_BEFORE) then
                        ShowReminder(event, "soon", key, organizer, now)
                    end
                end
            end
        end
    end
end

-- "/dw events test": a sample reminder for the first event in the list (or a
-- made-up one). Ignores the setting and marks nothing as reminded.
local sampleCount = 0
local function ShowSampleReminder()
    local first = VisibleEvents()[1]
    local now = time()
    sampleCount = sampleCount + 1
    local sample = {
        id = "sample" .. sampleCount, -- a new banner key each time
        title = first and first.title or "Molten Core",
        when = now + REMIND_BEFORE,
        signups = {},
    }
    ShowReminder(sample, "soon", nil, false, now)
end

-- Invite next ---------------------------------------------------------------------

local pendingInvites = {} -- [NameKey] = { at = GetTime(), member = roster row }: invites sent
local skipped = {}        -- [event id .. "|" .. NameKey] = true: skipped with a right-click (this session)
local convertPending      -- GetTime() of a Convert to raid that is not confirmed yet

local function InRaid()
    if type(IsInRaid) ~= "function" then
        return false
    end
    local ok, raid = pcall(IsInRaid)
    return ok and not DW.IsSecret(raid) and raid == true
end

-- How many invites are still waiting for an answer: sent less than two
-- minutes ago, and the person is not in the group yet. Older ones expire, so
-- a refused invite puts the person back in line.
local function PendingCount()
    local count, now = 0, GetTime()
    for key, pending in pairs(pendingInvites) do
        if now - pending.at >= INVITE_PENDING then
            pendingInvites[key] = nil
        elseif not DW.InMyGroup(pending.member) then
            count = count + 1
        end
    end
    return count
end

-- Who to invite, in order: Coming within the max, then standby, then Maybe
-- (earliest answer first). Each sign-up is matched to the guild roster by
-- name. Left out: no roster row, yourself, already in your group, skipped,
-- or invited less than two minutes ago. Returns the queue (each entry
-- { key = sign-up key, member = roster row, nameKey }) and the names of those
-- left out because they are offline.
local function InviteQueue(event)
    local lineup = Lineup(event)
    local maybe = {}
    for _, key in ipairs(lineup.maybe) do
        maybe[#maybe + 1] = key
    end
    table.sort(maybe, function(a, b)
        local ua, ub = event.signups[a].updated or 0, event.signups[b].updated or 0
        if ua ~= ub then
            return ua < ub
        end
        return a < b
    end)
    local order = {}
    for _, list in ipairs({ lineup.coming, lineup.standby, maybe }) do
        for _, key in ipairs(list) do
            order[#order + 1] = key
        end
    end

    local byName = {}
    for _, member in ipairs(DW.ReadGuildRoster()) do
        local nameKey = DW.NameKey(member.key)
        if nameKey ~= "" and not byName[nameKey] then
            byName[nameKey] = member
        end
    end
    local _, myName = DW.CharacterKey()
    local myNameKey, myGuid = DW.NameKey(myName), DW.MyGUID()
    local now = GetTime()

    local queue, offline, used = {}, {}, {}
    for _, key in ipairs(order) do
        local nameKey = DW.NameKey(key)
        local member = byName[nameKey]
        local pending = pendingInvites[nameKey]
        if member and not used[nameKey] and nameKey ~= myNameKey and not (myGuid and member.guid == myGuid)
            and not skipped[event.id .. "|" .. nameKey] and not (pending and now - pending.at < INVITE_PENDING)
            and not DW.InMyGroup(member) then
            used[nameKey] = true
            if member.online then
                queue[#queue + 1] = { key = key, member = member, nameKey = nameKey }
            else
                offline[#offline + 1] = member.name
            end
        end
    end
    return queue, offline
end

-- What the Invite next button shows and does now:
-- { text, enabled, action = "invite"/"convert"/nil, queue, offline }.
local function InviteState(event)
    local queue, offline = InviteQueue(event)
    local state = { queue = queue, offline = offline, enabled = false }
    local size = DW.GroupSize()
    local raid = InRaid()
    if size > 1 and not DW.CanInviteToGroup() then
        state.text = L.EV_INVITE_NOT_LEADER
    elseif #queue == 0 then
        state.text = L.EV_INVITE_DONE
    elseif raid and size + PendingCount() >= 40 then
        -- Full, or full once the open invites are answered.
        state.text = (size >= 40) and L.EV_INVITE_FULL or L.EV_INVITE_WAIT
    elseif not raid and size + PendingCount() >= 5 then
        if size < 2 then
            state.text = L.EV_INVITE_WAIT
        elseif not DW.CanConvertToRaid() then
            state.text = L.EV_INVITE_NOT_LEADER
        else
            state.text, state.enabled, state.action = L.EV_CONVERT_RAID, true, "convert"
        end
    else
        state.text = L.EV_INVITE_NEXT:format(queue[1].member.name or ShortName(queue[1].key))
        state.enabled, state.action = true, "invite"
    end
    return state
end

-- After Convert to raid: the game may block the call without an error, so
-- whether it worked is seen a moment later (or on GROUP_ROSTER_UPDATE).
local function CheckConvert()
    if not convertPending then
        return
    end
    convertPending = nil
    if not InRaid() then
        DW.Print(L.EV_CONVERT_FAILED)
    end
    RefreshPanel()
end

-- One click on Invite next: one invite, or one Convert to raid.
local function InviteClick(event)
    local state = InviteState(event)
    if not state.enabled then
        return
    end
    if state.action == "convert" then
        if DW.ConvertToRaid() then
            convertPending = GetTime()
            C_Timer.After(CONVERT_CHECK, CheckConvert)
        else
            DW.Print(L.EV_CONVERT_FAILED)
        end
    elseif state.action == "invite" then
        local first = state.queue[1]
        if DW.InviteToGroup(first.member.key) then
            pendingInvites[first.nameKey] = { at = GetTime(), member = first.member }
            DW.Print(L.EV_INVITED:format(first.member.name or ShortName(first.key)))
        end
    end
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

-- A name in the sign-up lists: just the name, as before, for an unslotted
-- event without a comment; otherwise role icon, name and the comment in grey.
local function SignupName(event, key, slotted)
    local signup = event.signups[key]
    if not slotted and not signup.comment then
        return ShortName(key)
    end
    local role = ROLE_BY_CODE[signup.role or ""]
    return (role and DW.RoleIcon(role, 12) or "") .. ShortName(key)
        .. (signup.comment and (" |cffaaaaaa(" .. signup.comment .. ")|r") or "")
end

local function NameList(event, keys, slotted)
    local names = {}
    for _, key in ipairs(keys) do
        names[#names + 1] = SignupName(event, key, slotted)
    end
    return names
end

-- "Roles: [T]1/1 [H]0/2 (+1) [D]2/3 ? 1   3/10"
local function SlotsText(event, lineup)
    local parts = {}
    local need = type(event.need) == "table" and event.need or {}
    for _, role in ipairs(DW.ROLES) do
        local wanted, count, maybe = need[role.code] or 0, lineup.roleIn[role.code], lineup.roleMaybe[role.code]
        local part
        if wanted > 0 then
            part = DW.RoleIcon(role, 12) .. count .. "/" .. wanted
        elseif count > 0 or maybe > 0 then
            part = DW.RoleIcon(role, 12) .. count
        end
        if part then
            if maybe > 0 then
                part = part .. " (+" .. maybe .. ")"
            end
            parts[#parts + 1] = part
        end
    end
    if lineup.roleIn["?"] > 0 then
        parts[#parts + 1] = "? " .. lineup.roleIn["?"]
    end
    local text = L.EV_SLOTS:format(table.concat(parts, "  "))
    if event.cap then
        text = text .. "   " .. lineup.inCount .. "/" .. event.cap
    end
    return text
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
    -- An event opened from a reminder (DW.ShowEvent) may be for another
    -- character of the account: it is shown although it is not in the list.
    if not selected and forcedID and forcedID == selectedID then
        local event = db.events[forcedID]
        if event and not event.stub and not event.deleted and type(event.when) == "number"
            and event.when > time() - SHOW_AFTER_START then
            selected = event
        end
    end
    if not selected then
        forcedID = nil
        selected = events[1]
        selectedID = selected and selected.id or nil
    end

    for index, event in ipairs(events) do
        local row = GetEventRow(index)
        local lineup = Lineup(event)
        local mine = me and event.signups[me]
        -- With a max the Coming count shows as in/max.
        local yes = event.cap and (lineup.inCount .. "/" .. event.cap) or Num(#lineup.coming + #lineup.standby)
        row.eventID = event.id
        row.label:SetText(event.title)
        row.sub:SetText(("%s   %s / %d / %d%s"):format(
            date("%d.%m.%Y %H:%M", event.when), yes, #lineup.maybe, #lineup.no,
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
    form.needLabel:SetText(L.EV_FORM_NEED)
    form.capLabel:SetText(L.EV_FORM_CAP)
    form.weeklyLabel:SetText(L.EV_FORM_WEEKLY)

    if formOpen and membersOpen then
        RefreshMembers()
    end

    if selected and not formOpen then
        local lineup = Lineup(selected)
        local slotted = IsSlotted(selected)
        local mine = me and selected.signups[me]
        d.title:SetText(selected.title)
        d.when:SetText(L.EV_WHEN_BY:format(date("%d.%m.%Y %H:%M", selected.when), ShortName(selected.creator)))
        d.audience:SetText(AudienceText(selected) .. (selected.weekly and (" - " .. L.EV_WEEKLY_TAG) or ""))
        d.note:SetText(selected.note or "")

        -- Everything below the audience line is stacked from the top, each
        -- under the last one shown, so long titles and notes push it down.
        local last = d.audience
        local function Stack(region, gap, shown)
            region:SetShown(shown)
            if shown then
                region:ClearAllPoints()
                region:SetPoint("TOPLEFT", last, "BOTTOMLEFT", 0, -gap)
                last = region
            end
        end
        Stack(d.note, 8, (selected.note or "") ~= "")

        d.slots:SetText(slotted and SlotsText(selected, lineup) or "")
        Stack(d.slots, 6, slotted)

        local missing = MissingList(lineup)
        if missing ~= "" then
            d.missing:SetText(L.EV_MISSING:format(missing))
            d.missing:SetTextColor(1, 0.6, 0.2)
        else
            d.missing:SetText(L.EV_ALL_FILLED)
            d.missing:SetTextColor(0.4, 1, 0.4)
        end
        Stack(d.missing, 4, NeedsRoles(selected))

        -- The answer chips sit side by side under the last line.
        local counts = { Y = #lineup.coming + #lineup.standby, M = #lineup.maybe, N = #lineup.no }
        for index, status in ipairs(STATUSES) do
            local chip = d.chips[status]
            chip:ClearAllPoints()
            chip:SetPoint("TOPLEFT", last, "BOTTOMLEFT", (index - 1) * (d.chipWidth + 6), -6)
            if status == "Y" and selected.cap then
                chip.label:SetText(("%s (%d/%d)"):format(L.EV_YES, lineup.inCount, selected.cap))
            else
                chip.label:SetText(("%s (%d)"):format(L[STATUS_KEY[status]], counts[status]))
            end
            chip:SetSelected(mine ~= nil and mine.status == status)
        end
        last = d.chips.Y

        -- Your role, for slotted events you said Coming or Maybe to.
        d.roleRow.label:SetText(L.EV_MY_ROLE)
        for _, role in ipairs(DW.ROLES) do
            local chip = d.roleRow.chips[role.code]
            chip.label:SetText(DW.RoleIcon(role, 14) .. " " .. L[role.key])
            chip:SetSelected(mine ~= nil and mine.role == role.code)
        end
        Stack(d.roleRow, 6, slotted and mine ~= nil and (mine.status == "Y" or mine.status == "M"))

        -- Your comment, once you have answered. The box is filled from your
        -- sign-up only when another event is selected, so typing is not lost.
        d.commentRow.label:SetText(L.EV_COMMENT)
        if d.commentFor ~= selected.id then
            d.commentFor = selected.id
            d.commentRow.box:SetText(mine and mine.comment or "")
        end
        Stack(d.commentRow, 4, mine ~= nil)

        -- The organizer's row over the buttons: Invite next (from an hour
        -- before the start) and Stop weekly. The sign-up lists end above it.
        local organizer = CanOrganize(selected)
        local inviteShown = organizer and time() >= selected.when - INVITE_FROM
        local stopShown = organizer and selected.weekly == true
        d.organizer:SetShown(inviteShown or stopShown)
        d.signupBottom = (inviteShown or stopShown) and 62 or 34
        d.invite:SetShown(inviteShown)
        if inviteShown then
            local state = InviteState(selected)
            d.invite.label:SetText(state.text)
            d.invite:SetActive(state.enabled)
        end
        -- A refresh resets "Sure?", except a fresh one on the same event (the
        -- 30-second tick must not eat the first of the two clicks).
        local stop = d.stopWeekly
        stop:SetShown(stopShown)
        if not (stopShown and stop.armedAt and stop.armedFor == selected.id and GetTime() - stop.armedAt <= 5) then
            stop.armedAt, stop.armedFor = nil, nil
        end
        stop.label:SetText(stop.armedAt and L.EV_STOP_SURE or L.EV_STOP_WEEKLY)

        -- The sign-up lists scroll between the rows above and the buttons.
        local scroll = d.signupScroll
        scroll:ClearAllPoints()
        scroll:SetPoint("TOPLEFT", last, "BOTTOMLEFT", 0, -8)
        scroll:SetPoint("BOTTOMLEFT", d, "BOTTOMLEFT", 0, d.signupBottom or 34)
        local function ListText(label, keys)
            local names = NameList(selected, keys, slotted)
            return ("%s: %s"):format(label, #names > 0 and table.concat(names, ", ") or "-")
        end
        d.lists.Y:SetText(ListText(L.EV_YES, lineup.coming))
        d.lists.B:SetText(#lineup.standby > 0 and ListText(L.EV_STANDBY, lineup.standby) or "")
        d.lists.M:SetText(ListText(L.EV_MAYBE, lineup.maybe))
        d.lists.N:SetText(ListText(L.EV_NO, lineup.no))
        local above, height = nil, 0
        for _, key in ipairs({ "Y", "B", "M", "N" }) do
            local list = d.lists[key]
            local shown = key ~= "B" or #lineup.standby > 0
            list:SetShown(shown)
            if shown then
                list:ClearAllPoints()
                if above then
                    list:SetPoint("TOPLEFT", above, "BOTTOMLEFT", 0, -8)
                    height = height + 8
                else
                    list:SetPoint("TOPLEFT", d.signupContent, "TOPLEFT", 0, 0)
                end
                height = height + list:GetStringHeight()
                above = list
            end
        end
        d.signupContent:SetHeight(math.max(1, height))

        d.share.label:SetText(L.EV_SHARE)
        d.delete.label:SetText(L.EV_DELETE)
        d.delete:SetShown(CanDelete(selected))
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
    panel.remindLabel:SetText(L.EV_REMIND_SETTING)
    panel.remindCheck:SetChecked(db.remind ~= false)
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

    -- Slots: each box empty or 0-40, and a max at least the roles together.
    local function SlotNumber(box)
        local text = (box:GetText():gsub("%s", ""))
        if text == "" then
            return 0
        end
        local value = text:match("^%d+$") and tonumber(text)
        if not value or value > MAX_SLOTS then
            return nil
        end
        return value
    end
    local need = {}
    for _, role in ipairs(DW.ROLES) do
        need[role.code] = SlotNumber(form.needBoxes[role.code])
        if not need[role.code] then
            form.error:SetText(L.EV_ERR_SLOTS)
            return
        end
    end
    local cap = SlotNumber(form.capBox)
    if not cap then
        form.error:SetText(L.EV_ERR_SLOTS)
        return
    end
    if cap > 0 and cap < need.T + need.H + need.D then
        form.error:SetText(L.EV_ERR_CAP)
        return
    end
    audience.need = need
    audience.cap = (cap > 0) and cap or nil
    audience.weekly = form.weeklyCheck:GetChecked() and true or nil

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
    form.weeklyCheck:SetChecked(false)
    for _, box in pairs(form.needBoxes) do
        box:SetText("")
    end
    form.capBox:SetText("")
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

    -- Reminders on or off (for the whole account), at the top right.
    f.remindCheck = CreateFrame("CheckButton", nil, f, "UICheckButtonTemplate")
    f.remindCheck:SetSize(24, 24)
    f.remindCheck:SetPoint("TOPRIGHT", -14, -42)
    f.remindCheck:SetScript("OnClick", function(self)
        if self:GetChecked() then
            db.remind = nil
        else
            db.remind = false
        end
    end)
    f.remindLabel = f:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    f.remindLabel:SetPoint("RIGHT", f.remindCheck, "LEFT", -2, 0)
    f.remindLabel:SetWidth(width - 360 - 14 - 24 - 12)
    f.remindLabel:SetJustifyH("RIGHT")
    f.remindLabel:SetWordWrap(false)

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
    d.title:SetWordWrap(true) -- a long title takes two lines; the rest moves down

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

    -- Below the note everything is placed in RefreshGuildView, each under the
    -- last one shown: slots, missing roles, answer chips, your role, your
    -- comment and the sign-up lists.

    -- "Roles: [T]1/1 [H]0/2 ...", only for slotted events.
    d.slots = d:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    d.slots:SetWidth(rightWidth)
    d.slots:SetJustifyH("LEFT")

    -- "Missing: 2 Healer" in orange, or "All roles are filled." in green.
    d.missing = d:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    d.missing:SetWidth(rightWidth)
    d.missing:SetJustifyH("LEFT")

    -- The answer buttons: one click signs you up, or changes your answer.
    d.chips, d.lists = {}, {}
    local chipWidth = math.floor((rightWidth - 12) / 3)
    d.chipWidth = chipWidth
    for index, status in ipairs(STATUSES) do
        local chip = DW.CreateChip(d, chipWidth, 28)
        chip:SetPoint("TOPLEFT", d.note, "BOTTOMLEFT", (index - 1) * (chipWidth + 6), -6)
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

    -- Your role in a slotted event: three chips, the selected one is yours.
    local roleRow = CreateFrame("Frame", nil, d)
    roleRow:SetSize(rightWidth, 26)
    roleRow.label = roleRow:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    roleRow.label:SetPoint("LEFT", 0, 0)
    roleRow.label:SetWidth(70)
    roleRow.label:SetJustifyH("LEFT")
    roleRow.label:SetWordWrap(false)
    roleRow.chips = {}
    for index, role in ipairs(DW.ROLES) do
        local chip = DW.CreateChip(roleRow, 74, 22)
        chip:SetPoint("LEFT", 72 + (index - 1) * 77, 0)
        -- Small font and narrow insets, so icon and role name fit.
        chip.label:SetFontObject("GameFontHighlightSmall")
        chip.label:ClearAllPoints()
        chip.label:SetPoint("LEFT", 4, 0)
        chip.label:SetPoint("RIGHT", -4, 0)
        chip.label:SetJustifyH("CENTER")
        chip:SetScript("OnClick", function()
            local event = selectedID and db.events[selectedID]
            if event and not event.deleted then
                SetMyRole(event, role.code)
                RefreshPanel()
            end
        end)
        roleRow.chips[role.code] = chip
    end
    roleRow:Hide()
    d.roleRow = roleRow

    -- A short comment on your answer ("15 min late"). Saved with Enter or
    -- when the box loses focus, if it changed.
    local commentRow = CreateFrame("Frame", nil, d)
    commentRow:SetSize(rightWidth, 28)
    commentRow.label = commentRow:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    commentRow.label:SetPoint("LEFT", 0, 0)
    commentRow.label:SetWidth(70)
    commentRow.label:SetJustifyH("LEFT")
    commentRow.label:SetWordWrap(false)
    commentRow.box = CreateEditBox(commentRow, rightWidth - 80, MAX_COMMENT_BYTES)
    commentRow.box:SetPoint("LEFT", 76, 0)
    local function SaveComment(box)
        local event = selectedID and db.events[selectedID]
        local me = MyKey()
        local mine = event and me and event.signups[me]
        if mine and not event.deleted and CleanComment(box:GetText()) ~= mine.comment then
            SetMyComment(event, box:GetText())
            box:SetText(event.signups[me].comment or "")
            RefreshPanel()
        end
    end
    commentRow.box:SetScript("OnEnterPressed", function(self)
        SaveComment(self)
        self:ClearFocus()
    end)
    commentRow.box:SetScript("OnEditFocusLost", function(self)
        SaveComment(self)
    end)
    commentRow.box:SetScript("OnEnter", function(self)
        GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
        GameTooltip:AddLine(L.EV_COMMENT_HINT, 1, 1, 1, true)
        GameTooltip:Show()
    end)
    commentRow.box:SetScript("OnLeave", function()
        GameTooltip:Hide()
    end)
    commentRow:Hide()
    d.commentRow = commentRow

    -- The sign-up lists (Coming, Standby, Maybe, Not coming) scroll from under
    -- the rows above down to just over the buttons.
    local signupScroll = CreateFrame("ScrollFrame", "DragonworldEventSignupsScroll", d, "ScrollFrameTemplate")
    signupScroll:SetWidth(rightWidth - 24)
    signupScroll:SetPoint("TOPLEFT", d.chips.Y, "BOTTOMLEFT", 0, -8)
    signupScroll:SetPoint("BOTTOMLEFT", d, "BOTTOMLEFT", 0, 34)
    d.signupContent = CreateFrame("Frame", nil, signupScroll)
    d.signupContent:SetSize(rightWidth - 24, 1)
    signupScroll:SetScrollChild(d.signupContent)
    d.signupScroll = signupScroll
    d.signupBottom = 34

    for _, key in ipairs({ "Y", "B", "M", "N" }) do
        local list = d.signupContent:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
        list:SetPoint("TOPLEFT", 0, 0)
        list:SetWidth(rightWidth - 24)
        list:SetJustifyH("LEFT")
        d.lists[key] = list
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
        -- Only the one who created the event, or an officer, can delete it.
        if event and not event.deleted and CanDelete(event) then
            DeleteEvent(event)
            selectedID = nil
            RefreshPanel()
        end
    end)
    -- On a weekly event, Delete removes only this week.
    d.delete:HookScript("OnEnter", function(self)
        local event = selectedID and db.events[selectedID]
        if event and event.weekly then
            GameTooltip:SetOwner(self, "ANCHOR_TOP")
            GameTooltip:AddLine(L.EV_DELETE_WEEKLY_TIP, 1, 1, 1, true)
            GameTooltip:Show()
        end
    end)
    d.delete:HookScript("OnLeave", function()
        GameTooltip:Hide()
    end)

    -- The organizer's row, just over Post in guild chat and Delete.
    local organizerRow = CreateFrame("Frame", nil, d)
    organizerRow:SetPoint("BOTTOMLEFT", 0, 32)
    organizerRow:SetSize(rightWidth, 24)
    organizerRow:Hide()
    d.organizer = organizerRow

    -- Invite next: left-click invites the next person in line (or converts
    -- the party to a raid when it is full); right-click skips that person.
    d.invite = DW.CreateButton(organizerRow, 190, 24, "gold")
    d.invite:SetPoint("LEFT", 0, 0)
    d.invite:RegisterForClicks("LeftButtonUp", "RightButtonUp")
    d.invite:SetScript("OnClick", function(self, button)
        local event = selectedID and db.events[selectedID]
        if not event or event.deleted or not CanOrganize(event) then
            return
        end
        if button == "RightButton" then
            local first = InviteQueue(event)[1]
            if first then
                skipped[event.id .. "|" .. first.nameKey] = true
            end
        else
            InviteClick(event)
        end
        RefreshPanel()
    end)
    d.invite:HookScript("OnEnter", function(self)
        local event = selectedID and db.events[selectedID]
        if not event then
            return
        end
        local queue, offline = InviteQueue(event)
        GameTooltip:SetOwner(self, "ANCHOR_TOP")
        GameTooltip:AddLine(L.EV_INVITE_TIP_HEAD)
        for index = 1, math.min(5, #queue) do
            local signup = event.signups[queue[index].key]
            local role = signup and ROLE_BY_CODE[signup.role or ""]
            GameTooltip:AddLine((role and DW.RoleIcon(role, 12) or "") .. (queue[index].member.name or ShortName(queue[index].key)), 1, 1, 1)
        end
        if #offline > 0 then
            GameTooltip:AddLine(L.EV_INVITE_SKIPPED:format(table.concat(offline, ", ")), 0.7, 0.7, 0.7, true)
        end
        GameTooltip:AddLine(L.EV_INVITE_SKIP_TIP, 0.5, 0.8, 1, true)
        GameTooltip:Show()
    end)
    d.invite:HookScript("OnLeave", function()
        GameTooltip:Hide()
    end)

    -- Stop weekly: red, and needs a second click within 5 seconds.
    d.stopWeekly = DW.CreateButton(organizerRow, 108, 24, "red")
    d.stopWeekly:SetPoint("RIGHT", 0, 0)
    d.stopWeekly:SetScript("OnClick", function(self)
        local event = selectedID and db.events[selectedID]
        if not event or event.deleted or not event.weekly or not CanOrganize(event) then
            return
        end
        if self.armedAt and self.armedFor == event.id and GetTime() - self.armedAt <= 5 then
            self.armedAt, self.armedFor = nil, nil
            StopWeekly(event)
            RefreshPanel()
        else
            self.armedAt, self.armedFor = GetTime(), event.id
            self.label:SetText(L.EV_STOP_SURE)
        end
    end)
    d.stopWeekly:HookScript("OnLeave", function(self)
        self.armedAt, self.armedFor = nil, nil
        self.label:SetText(L.EV_STOP_WEEKLY)
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

    -- How many tanks, healers and DPS are needed, and a max. Empty = 0 / no max.
    form.needLabel = Label(0, -224)
    form.needIcons, form.needBoxes = {}, {}
    for index, role in ipairs(DW.ROLES) do
        local x = 70 + (index - 1) * 54
        local icon = form:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
        icon:SetPoint("TOPLEFT", x, -223)
        icon:SetText(DW.RoleIcon(role, 16))
        local box = CreateEditBox(form, 28, nil, 2)
        box:SetPoint("TOPLEFT", x + 18, -220)
        form.needIcons[role.code], form.needBoxes[role.code] = icon, box
    end
    form.capLabel = Label(236, -224)
    form.capBox = CreateEditBox(form, 30, nil, 2)
    form.capBox:SetPoint("TOPLEFT", 270, -220)

    -- Should the event also be put in the game's own calendar?
    form.calendarCheck = CreateFrame("CheckButton", nil, form, "UICheckButtonTemplate")
    form.calendarCheck:SetSize(24, 24)
    form.calendarCheck:SetPoint("TOPLEFT", -4, -248)
    form.calendarCheck:SetChecked(true)

    form.calendarLabel = form:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    form.calendarLabel:SetPoint("LEFT", form.calendarCheck, "RIGHT", 2, 0)

    -- Repeat every week: next week's event is made when this one starts.
    form.weeklyCheck = CreateFrame("CheckButton", nil, form, "UICheckButtonTemplate")
    form.weeklyCheck:SetSize(24, 24)
    form.weeklyCheck:SetPoint("TOPLEFT", -4, -272)
    form.weeklyCheck:SetChecked(false)

    form.weeklyLabel = form:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    form.weeklyLabel:SetPoint("LEFT", form.weeklyCheck, "RIGHT", 2, 0)

    form.save = DW.CreateButton(form, 130, 28, "gold")
    form.save:SetPoint("TOPLEFT", 0, -320)
    form.save:SetScript("OnClick", SubmitForm)

    -- The error sits right above the buttons and grows upwards, so a long
    -- message on two lines (French, German) does not run into them.
    form.error = form:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    form.error:SetPoint("BOTTOMLEFT", form.save, "TOPLEFT", 0, 2)
    form.error:SetWidth(rightWidth)
    form.error:SetJustifyH("LEFT")
    form.error:SetTextColor(1.00, 0.35, 0.30)

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

-- Opens the Guild events tab with this event selected (if we have it), also
-- when it is not in the list for this character (an answer on an alt).
function DW.ShowEvent(id)
    view, formOpen, membersOpen = "guild", false, false
    local event = id and db.events[id]
    if event and not event.stub and not event.deleted then
        selectedID, forcedID = id, id
    end
    DW.OpenModule(MODULE_ID)
    RefreshPanel()
end

-- Game events -----------------------------------------------------------------

-- Messages from other members. Comm.lua has already checked that they come on
-- the guild channel, from another member, and catches errors in broken messages.
DW.OnGuildMessage(PREFIX, OnMessage)

local helloSent = false
local tickStarted = false

-- Every 30 seconds: reminders that are due, next week's weekly events,
-- moving up from standby, and the panel (Invite next follows the clock).
-- One timer is always waiting once it has started: the next one is planned
-- first, so an error in one check does not stop the rest of the session.
local function Tick()
    C_Timer.After(TICK, Tick)
    if DW.IsMember() then
        CheckReminders()
        GenerateDue()
        CheckPromotion()
    end
    RefreshPanel()
end

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
            CheckPromotion() -- where I stand now, so a later move up is noticed
            RecoverSeries()
            -- Next week's events are made by the first tick, 30 s from now,
            -- when the answers to the hello have come: an officer may have
            -- stopped a series while we were away.
            if not tickStarted then
                tickStarted = true
                C_Timer.After(TICK, Tick)
            end
        end
    end)
end

-- For the tests: a new hello, as after a new login (the tick keeps running).
-- It runs RecoverSeries; the next tick runs GenerateDue.
function DW.RestartEventHello()
    helloSent = false
    PlanHello()
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
    elseif event == "GROUP_ROSTER_UPDATE" then
        -- The party became a raid: Convert to raid worked.
        if convertPending and InRaid() then
            convertPending = nil
        end
        if view == "guild" then
            RefreshPanel()
        end
    else
        PlanHello()
    end
end)

for _, event in ipairs({ "PLAYER_ENTERING_WORLD", "CALENDAR_UPDATE_EVENT_LIST", "CALENDAR_UPDATE_ERROR", "GROUP_ROSTER_UPDATE" }) do
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

-- Promoted, demoted or a new officer limit: try held deletions again, and
-- show or hide the delete button.
DW.OnOfficersChanged(function()
    held:ReplayAll()
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
    local leader = UnitIsGroupLeader and select(2, pcall(UnitIsGroupLeader, "player"))
    add(("serier: %d | påminnelser: %d | påminn på: %s | ShowBanner: %s | gruppe: %d raid=%s leder=%s | ConvertToRaid: %s"):format(
        CountKeys(db.series), CountKeys(db.reminded), text(db.remind ~= false), text(DW.ShowBanner ~= nil),
        DW.GroupSize(), text(InRaid()), text(leader),
        text(C_PartyInfo ~= nil and C_PartyInfo.ConvertToRaid ~= nil or type(ConvertToRaid) == "function")))
end)

-- The events you answered that are still to come and shown for the character
-- you play (answers on another character of the account count):
-- { { id, title, when, status, role }, ... }, soonest first.
function DW.MyEventAnswers()
    local list, now = {}, time()
    for _, event in ipairs(VisibleEvents()) do
        local signup = event.when > now and MySignupFor(event)
        if signup then
            list[#list + 1] = { id = event.id, title = event.title, when = event.when, status = signup.status, role = signup.role }
        end
    end
    return list
end

local SAMPLE_WORDS = { test = true, eksempel = true, voorbeeld = true, example = true }

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
        if type(saved.series) ~= "table" then
            saved.series = {}
        end
        if type(saved.reminded) ~= "table" then
            saved.reminded = {}
        end
        for key, template in pairs(saved.series) do
            if type(template) ~= "table" or type(template.lastWhen) ~= "number" or type(template.creator) ~= "string"
                or type(template.seq) ~= "string" or not template.seq:match("^%d+$") then
                saved.series[key] = nil
            end
        end
        db = saved
        held = DW.NewHeldStore(saved, MODULE_ID)
        PurgeExpired()
    end,

    CreatePanel = function(self, parent)
        return CreatePanel(parent)
    end,

    -- "/dw events test" shows a sample reminder; anything else opens the tab.
    OnSlash = function(self, message)
        local word = ((message or ""):match("^%s*(%S+)") or ""):lower()
        if SAMPLE_WORDS[word] then
            ShowSampleReminder()
        elseif DW.OpenModule then
            DW.OpenModule(MODULE_ID)
        end
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

-- The Home page (Modules\Home.lua): your events in the coming week, and new
-- ones you have not answered. Start times use time() (the events' own clock);
-- arrived is server time.
DW.RegisterHomeSection({
    id = "events",
    order = 20,
    titleKey = "HOME_SEC_EVENTS",
    icon = "Interface\\Icons\\INV_Scroll_03",
    Lines = function(ctx)
        local lines, now, me = {}, time(), MyKey()
        for _, event in ipairs(VisibleEvents()) do
            if event.when > now - 3600 then
                local id = event.id
                local function Open()
                    DW.ShowEvent(id)
                end
                local signup = MySignupFor(event)
                local starts = date("%d.%m %H:%M", event.when)
                if signup and (signup.status == "Y" or signup.status == "M") and event.when <= now + 7 * 86400 then
                    lines[#lines + 1] = { text = L.HOME_EV_SOON:format(event.title or "?", starts, L[STATUS_KEY[signup.status]]),
                        changed = false, onClick = Open, tab = MODULE_ID }
                elseif not signup and event.creator ~= me and ctx.since and (event.arrived or 0) > ctx.since then
                    lines[#lines + 1] = { text = L.HOME_EV_NEW:format(event.title or "?", starts, ShortName(event.creator)),
                        when = event.arrived, changed = true, tip = L.HOME_EV_NEW_TIP, onClick = Open, tab = MODULE_ID }
                end
            end
        end
        return lines
    end,
})
