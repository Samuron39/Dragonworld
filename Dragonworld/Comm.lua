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
    local handler = handlers[prefix]
    if not handler or channel ~= "GUILD" or not DW.IsMember() then
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
    local ok, problem = pcall(handler, text, sender)
    if not ok then
        DW.PrintError(L.ERROR, problem)
    end
end)

pcall(frame.RegisterEvent, frame, "CHAT_MSG_ADDON")

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
