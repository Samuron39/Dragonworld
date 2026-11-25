-- Dragonworld - messages between members
--
-- Modules that share something with the rest of the guild (events, professions)
-- send small messages on the guild channel that only other addons see. This
-- file handles what they have in common:
--   * the queue that makes sure we do not send faster than the game allows
--   * receiving, with the checks that must always be done first
--
-- How a module uses it:
--   local Send = DW.CreateSender("DragonworldXx")      -- message name, max 16 characters
--   DW.OnGuildMessage("DragonworldXx", function(text, sender) ... end)
--   Send("text")                                        -- max 255 characters
--
-- The game's rules: 255 characters per message, 10 messages "in the bank" per
-- name, and one new one per second. Trial accounts cannot send at all.
--
-- A module that talks to the party or raid you are in, instead of the guild,
-- uses DW.CreateGroupSender and DW.OnGroupMessage (further down).

local ADDON_NAME, DW = ...
local L = DW.L

-- Is the sender of a message the character you are playing yourself? The game
-- usually gives "Navn-Realm".
function DW.IsMe(sender)
    local key, name = DW.CharacterKey()
    if not key then
        return false
    end
    if sender == key or sender == name then
        return true
    end
    -- Names can come with or without spaces, so compare without them. If the
    -- sender has a realm, it must match too.
    local function Plain(text)
        return (text:lower():gsub("%s+", ""))
    end
    if sender:find("-", 1, true) then
        return Plain(sender) == Plain(key)
    end
    return DW.NameKey(sender) == DW.NameKey(name)
end

-- Makes a send function for one message name. Messages that do not fit right
-- away are queued and sent as room allows.
function DW.CreateSender(prefix)
    if C_ChatInfo and C_ChatInfo.RegisterAddonMessagePrefix then
        pcall(C_ChatInfo.RegisterAddonMessagePrefix, prefix)
    end

    local queue = {}
    local tokens, lastRefill = 10, nil
    local scheduled = false
    local Pump

    local function Schedule(delay)
        if scheduled then
            return
        end
        scheduled = true
        C_Timer.After(delay, function()
            scheduled = false
            Pump()
        end)
    end

    Pump = function()
        if #queue == 0 then
            return
        end
        if not DW.IsMember() or not (C_ChatInfo and C_ChatInfo.SendAddonMessage) then
            queue = {}
            return
        end
        -- In some situations the game blocks all sending. Wait and try again.
        if C_ChatInfo.InChatMessagingLockdown and C_ChatInfo.InChatMessagingLockdown() then
            Schedule(5)
            return
        end

        local now = GetTime()
        tokens = math.min(10, tokens + (now - (lastRefill or now)))
        lastRefill = now

        while #queue > 0 and tokens >= 1 do
            local result = select(-1, C_ChatInfo.SendAddonMessage(prefix, queue[1], "GUILD"))
            if result == 0 or result == true then
                table.remove(queue, 1)
                tokens = tokens - 1
            elseif result == 10 then
                queue = {} -- not in a guild
                return
            elseif result == 1 or result == 2 or result == 4 then
                table.remove(queue, 1) -- the message is invalid; it will never be sent
            else
                tokens = 0 -- throttled or blocked: wait a bit
                break
            end
        end

        if #queue > 0 then
            Schedule(1.2)
        end
    end

    return function(message)
        if type(message) ~= "string" or #message > 255 then
            return
        end
        for _, waiting in ipairs(queue) do
            if waiting == message then
                return -- already in the queue
            end
        end
        queue[#queue + 1] = message
        Pump()
    end
end

-- Receiving -------------------------------------------------------------------

local handlers = {} -- [message name] = function(text, sender)

-- The same for messages from the group you are in (see "Messages to the
-- group" below), and the channels they may come on.
local groupHandlers = {} -- [message name] = function(text, sender, channel)
local GROUP_CHANNELS = { RAID = true, PARTY = true, INSTANCE_CHAT = true }

-- For debugging: how the game wrote the sender on the last message from
-- someone else, and on our own last echo.
local lastSender, lastEcho

DW.AddDebug("meldinger", function(add)
    add("siste avsender: " .. DW.DebugText(lastSender) .. " | eget ekko: " .. DW.DebugText(lastEcho))
    add("C_ChatInfo.SendAddonMessage: " .. DW.DebugText(C_ChatInfo ~= nil and C_ChatInfo.SendAddonMessage ~= nil)
        .. " | sperret nå: " .. DW.DebugText(C_ChatInfo and C_ChatInfo.InChatMessagingLockdown and C_ChatInfo.InChatMessagingLockdown()))
end)

-- Registers who gets the messages with a given name. The function is only
-- called for messages from other guild members, never for your own.
function DW.OnGuildMessage(prefix, handler)
    handlers[prefix] = handler
end

local frame = CreateFrame("Frame")

frame:SetScript("OnEvent", function(self, event, prefix, text, channel, sender)
    if type(prefix) ~= "string" or DW.IsSecret(prefix) then
        return
    end
    if type(channel) ~= "string" or DW.IsSecret(channel) then
        return
    end
    -- Guild messages are for members; group messages for everyone who may
    -- use the personal tabs (the group can hold people from outside the guild).
    local handler, fromGroup
    if channel == "GUILD" then
        handler = DW.IsMember() and handlers[prefix]
    elseif GROUP_CHANNELS[channel] then
        handler = DW.HasAccess() and groupHandlers[prefix]
        fromGroup = true
    end
    if not handler then
        return
    end
    if type(text) ~= "string" or type(sender) ~= "string" or DW.IsSecret(text) or DW.IsSecret(sender) then
        return
    end
    if DW.IsMe(sender) then
        lastEcho = sender
        return -- our own echo
    end
    lastSender = sender
    -- A broken message from someone else must never cause an error for us.
    local ok, problem
    if fromGroup then
        ok, problem = pcall(handler, text, sender, channel)
    else
        ok, problem = pcall(handler, text, sender)
    end
    if not ok then
        DW.PrintError(L.ERROR, problem)
    end
end)

pcall(frame.RegisterEvent, frame, "CHAT_MSG_ADDON")

-- Messages to the group ------------------------------------------------------------
--
-- For a module that talks to the party or raid you are in (Tactics). It works
-- like the guild messages above (255 characters, 10 in the bank and one more
-- per second, your own echo and secret values dropped, an error in the handler
-- caught), with these differences:
--   * A message goes out on "RAID" when you are in a raid, otherwise on
--     "PARTY"; in a group the game put together for an instance, when you
--     have no group of your own, on "INSTANCE_CHAT". Messages are taken only
--     from the channels RAID, PARTY and INSTANCE_CHAT.
--   * It is for everyone with DW.HasAccess(), not only for guild members.
--   * What is waiting is dropped when you are in no group.
--   * The game can refuse addon messages for a while (in a fight in an
--     instance: C_ChatInfo.InChatMessagingLockdown() is true, or
--     SendAddonMessage answers 11). Then what is waiting is kept and tried
--     again every 5 seconds. After 2 minutes of that it is dropped.
--
-- How a module uses it:
--   local Group = DW.CreateGroupSender("DragonworldXx")
--   DW.OnGroupMessage("DragonworldXx", function(text, sender, channel) ... end)
--
--   Group(text)            queues a message (the same as Group.Send(text)).
--                          Returns true if it was taken.
--   Group(text, true)      ...ahead of the ordinary ones that wait. Urgent
--                          messages keep their own order.
--   Group.Waiting()        how many messages wait. Group.Waiting(pattern)
--                          counts only those that match the Lua pattern.
--   Group.Locked()         true when the game refused the last attempt (see
--                          above). It turns false when a message goes out.
--   Group.LastResult()     the game's answer to the last attempt: 0 sent,
--                          3 and 8 slow down, 5 not in a group, 11 locked.
--                          false when nothing was attempted (the game is in its
--                          chat lockdown, or does not say whether you are in a
--                          group), nil before the first attempt or when the
--                          call failed.
--   Group.Clear()          drops what waits. Group.Clear(pattern) drops only
--                          the messages that match.
--   Group.OnChange(fn)     fn(what) is called after something changed:
--                            "sent"     one or more messages went out
--                            "locked"   the game started refusing; we keep trying
--                            "gaveup"   refused for 2 minutes: what waited was dropped
--                            "nogroup"  what waited was dropped: you are in no group

local LOCK_RETRY = 5      -- seconds between attempts while the game refuses
local LOCK_GIVE_UP = 120  -- seconds of refusing before what waits is dropped

-- What a game function answers, or nil when it is missing, fails or the
-- answer is secret.
local function GameSays(fn, ...)
    if type(fn) ~= "function" then
        return nil
    end
    local ok, value = pcall(fn, ...)
    if not ok or DW.IsSecret(value) then
        return nil
    end
    return value
end

-- The channel that reaches the group you are in. A group the game's group
-- finder made is an "instance group", with a channel of its own: RAID and
-- PARTY would answer "not in a group" there.
local function GroupChannel()
    local home, instance = LE_PARTY_CATEGORY_HOME, LE_PARTY_CATEGORY_INSTANCE
    if home and instance and GameSays(IsInGroup, instance) == true and GameSays(IsInGroup, home) == false then
        return "INSTANCE_CHAT"
    end
    return GameSays(IsInRaid) == true and "RAID" or "PARTY"
end

-- Sends one addon message and gives the game's answer (the last value it returns).
local function Attempt(prefix, message, channel)
    return (select(-1, C_ChatInfo.SendAddonMessage(prefix, message, channel)))
end

function DW.CreateGroupSender(prefix)
    if C_ChatInfo and C_ChatInfo.RegisterAddonMessagePrefix then
        pcall(C_ChatInfo.RegisterAddonMessagePrefix, prefix)
    end

    local urgent, queue = {}, {} -- the urgent messages go out first
    local tokens, lastRefill = 10, nil
    local scheduled = false
    local locked = false      -- the game refused the last attempt
    local lockedSince         -- GetTime() of the first refusal of what waits now
    local lastResult
    local listeners = {}
    local Pump

    local function Notify(what)
        for _, listener in ipairs(listeners) do
            local ok, problem = pcall(listener, what)
            if not ok then
                DW.PrintError(L.ERROR, problem)
            end
        end
    end

    local function Schedule(delay)
        if scheduled then
            return
        end
        scheduled = true
        C_Timer.After(delay, function()
            scheduled = false
            Pump()
        end)
    end

    local function Drop()
        urgent, queue = {}, {}
        lockedSince = nil
    end

    -- The game does not take addon messages right now.
    local function Refused()
        local now = GetTime()
        local wasLocked = locked
        locked = true
        lockedSince = lockedSince or now
        if now - lockedSince >= LOCK_GIVE_UP then
            Drop()
            Notify("gaveup")
        else
            Schedule(LOCK_RETRY)
            if not wasLocked then
                Notify("locked")
            end
        end
    end

    Pump = function()
        if #urgent + #queue == 0 then
            return
        end
        if not DW.HasAccess() or not (C_ChatInfo and C_ChatInfo.SendAddonMessage) then
            Drop()
            return
        end
        local inGroup = GameSays(IsInGroup)
        if inGroup == false then
            Drop()
            locked = false
            Notify("nogroup")
            return
        end
        -- (No plain answer about the group counts as refused too: keep and retry.)
        if inGroup ~= true or GameSays(C_ChatInfo.InChatMessagingLockdown) == true then
            lastResult = false
            Refused()
            return
        end

        local now = GetTime()
        tokens = math.min(10, tokens + (now - (lastRefill or now)))
        lastRefill = now

        local sent = false
        while #urgent + #queue > 0 and tokens >= 1 do
            local list = #urgent > 0 and urgent or queue
            local ok, result = pcall(Attempt, prefix, list[1], GroupChannel())
            if not ok or DW.IsSecret(result) then
                result = nil
            end
            lastResult = result
            if result == 0 or result == true then
                table.remove(list, 1)
                tokens = tokens - 1
                sent = true
                locked, lockedSince = false, nil
            elseif result == 5 then
                Drop() -- not in a group
                locked = false
                Notify("nogroup")
                return
            elseif result == 1 or result == 2 or result == 4 then
                table.remove(list, 1) -- the message is invalid; it will never be sent
            elseif result == 3 or result == 8 then
                tokens = 0 -- throttled: wait a bit
                break
            else
                -- 11 (the addon message lockdown), or an answer we do not
                -- know: the game did not take it.
                if sent then
                    Notify("sent")
                end
                Refused()
                return
            end
        end

        if #urgent + #queue > 0 then
            Schedule(1.2)
        else
            lockedSince = nil
        end
        if sent then
            Notify("sent")
        end
    end

    local function Send(message, first)
        if type(message) ~= "string" or #message > 255 then
            return false
        end
        for _, list in ipairs({ urgent, queue }) do
            for _, waiting in ipairs(list) do
                if waiting == message then
                    return true -- already in the queue
                end
            end
        end
        local list = first and urgent or queue
        list[#list + 1] = message
        -- While the game refuses, the next attempt is the planned one, not
        -- one more for every message that is queued.
        if not (locked and scheduled) then
            Pump()
        end
        return true
    end

    local function Waiting(pattern)
        if pattern == nil then
            return #urgent + #queue
        end
        local count = 0
        for _, list in ipairs({ urgent, queue }) do
            for _, waiting in ipairs(list) do
                if waiting:find(pattern) then
                    count = count + 1
                end
            end
        end
        return count
    end

    local function Clear(pattern)
        if pattern == nil then
            Drop()
            return
        end
        for _, list in ipairs({ urgent, queue }) do
            for index = #list, 1, -1 do
                if list[index]:find(pattern) then
                    table.remove(list, index)
                end
            end
        end
        if #urgent + #queue == 0 then
            lockedSince = nil
        end
    end

    return setmetatable({
        Send = Send,
        Waiting = Waiting,
        Clear = Clear,
        Locked = function()
            return locked
        end,
        LastResult = function()
            return lastResult
        end,
        OnChange = function(listener)
            if type(listener) == "function" then
                listeners[#listeners + 1] = listener
            end
        end,
    }, {
        __call = function(_, message, first)
            return Send(message, first)
        end,
    })
end

-- Registers who gets the group messages with a given name. The function is
-- only called for messages from someone else, on one of the group channels.
-- It must check itself that the sender is in the group, and what they may do.
function DW.OnGroupMessage(prefix, handler)
    groupHandlers[prefix] = handler
end

-- What we have received ----------------------------------------------------------
--
-- Profile and professions are stored by everyone, so they do not need to be
-- sent again every time someone logs in. The one who logs in therefore only
-- asks for what has changed since it was last online ("R <time>"), and only
-- those who have changed something since then answer. The first time, and then
-- once a week, it asks for everything ("R"), in case a message has been lost.
--
-- Saved (for the whole account, like the profiles and professions):
--   DragonworldDB.syncedUntil  server time when we last logged out after having
--                              asked and got an answer
--   DragonworldDB.fullSyncAt   server time when we last asked for everything and got an answer

local FULL_SYNC_EVERY = 7 * 24 * 3600
local SYNC_MARGIN = 5 * 60 -- ask a bit further back than necessary, in case something came late
local SYNC_SETTLE = 30     -- how long the others get to answer before the session counts as heard

-- The server time, which is the same for all players. The times in "R <tid>" are server time.
function DW.ServerNow()
    local now = GetServerTime and GetServerTime()
    if type(now) == "number" and not DW.IsSecret(now) then
        return now
    end
    return time()
end

local sessionSince -- nil = not decided yet, false = ask for everything, number = ask from then
local askedAt      -- GetTime() when we last asked

-- The time the others should send changes from (server time), or nil for everything.
-- Decided the first time it is called in a session, so all modules ask the same.
function DW.SyncSince()
    if sessionSince == nil then
        local db = type(DragonworldDB) == "table" and DragonworldDB or nil
        local heard = db and tonumber(db.syncedUntil)
        local full = db and tonumber(db.fullSyncAt)
        local now = DW.ServerNow()
        if not heard or not full or now - full > FULL_SYNC_EVERY then
            sessionSince = false
        else
            sessionSince = math.max(0, math.min(heard, now) - SYNC_MARGIN)
        end
    end
    return sessionSince or nil
end

-- The message a module sends to ask the others for theirs: "R" or "R <tid>".
function DW.SyncRequest()
    askedAt = GetTime()
    local since = DW.SyncSince()
    return since and ("R\t%d"):format(since) or "R"
end

-- From such a message: the time the sender wants changes from, 0 for everything.
-- Older versions only send "R", and they get everything, as before.
function DW.SyncRequestSince(text)
    return tonumber((type(text) == "string" and text:match("^R\t(%d+)$")) or "") or 0
end

-- On logout (and /reload): if we have asked and given the others time to
-- answer, we have received everything up to now. Otherwise we ask from the
-- same point next time. A character outside the guild hears nothing, and does
-- not change this.
local logout = CreateFrame("Frame")
logout:SetScript("OnEvent", function()
    if type(DragonworldDB) ~= "table" or not DW.IsMember() or not askedAt or GetTime() - askedAt < SYNC_SETTLE then
        return
    end
    local now = DW.ServerNow()
    DragonworldDB.syncedUntil = now
    if sessionSince == false then
        DragonworldDB.fullSyncAt = now
    end
end)
pcall(logout.RegisterEvent, logout, "PLAYER_LOGOUT")
