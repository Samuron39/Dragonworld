-- Dragonworld - meldinger mellom medlemmer
--
-- Moduler som deler noe med resten av guilden (events, professions) sender
-- små meldinger på guild-kanalen som bare andre addoner ser. Denne filen tar
-- seg av det som er felles:
--   * køen som sørger for at vi ikke sender fortere enn spillet tillater
--   * mottak, med de sjekkene som alltid må gjøres først
--
-- Slik bruker en modul det:
--   local Send = DW.CreateSender("DragonworldXx")      -- navn på meldingene, maks 16 tegn
--   DW.OnGuildMessage("DragonworldXx", function(text, sender) ... end)
--   Send("tekst")                                       -- maks 255 tegn
--
-- Spillets regler: 255 tegn per melding, 10 meldinger "på konto" per navn, og
-- én ny i sekundet. Prøvekontoer får ikke sende i det hele tatt.

local ADDON_NAME, DW = ...
local L = DW.L

-- Er avsenderen av en melding karakteren du selv spiller? Spillet oppgir som
-- regel "Navn-Realm".
function DW.IsMe(sender)
    local key, name = DW.CharacterKey()
    if not key then
        return false
    end
    if sender == key or sender == name then
        return true
    end
    -- Navn kan komme med eller uten mellomrom, så sammenlign uten dem. Har
    -- avsenderen realm, må den også stemme.
    local function Plain(text)
        return (text:lower():gsub("%s+", ""))
    end
    if sender:find("-", 1, true) then
        return Plain(sender) == Plain(key)
    end
    return DW.NameKey(sender) == DW.NameKey(name)
end

-- Lager en sendefunksjon for ett meldingsnavn. Meldinger som ikke får plass
-- med en gang legges i kø og sendes etter hvert.
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
        -- I noen situasjoner sperrer spillet all sending. Vent og prøv igjen.
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
                queue = {} -- ikke i en guild
                return
            elseif result == 1 or result == 2 or result == 4 then
                table.remove(queue, 1) -- meldingen er ugyldig; den blir aldri sendt
            else
                tokens = 0 -- strupet eller sperret: vent litt
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
                return -- ligger allerede i køen
            end
        end
        queue[#queue + 1] = message
        Pump()
    end
end

-- Mottak ----------------------------------------------------------------------

local handlers = {} -- [meldingsnavn] = funksjon(tekst, avsender)

-- Til feilsøking: hvordan spillet skrev avsenderen på den siste meldingen fra
-- en annen, og på vårt eget siste ekko.
local lastSender, lastEcho

DW.AddDebug("meldinger", function(add)
    add("siste avsender: " .. DW.DebugText(lastSender) .. " | eget ekko: " .. DW.DebugText(lastEcho))
    add("C_ChatInfo.SendAddonMessage: " .. DW.DebugText(C_ChatInfo ~= nil and C_ChatInfo.SendAddonMessage ~= nil)
        .. " | sperret nå: " .. DW.DebugText(C_ChatInfo and C_ChatInfo.InChatMessagingLockdown and C_ChatInfo.InChatMessagingLockdown()))
end)

-- Registrerer hvem som skal ha meldingene med et bestemt navn. Funksjonen
-- kalles bare for meldinger fra andre guildmedlemmer, aldri for dine egne.
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
        return -- vårt eget ekko
    end
    lastSender = sender
    -- En ødelagt melding fra en annen skal aldri gi feil hos oss.
    local ok, problem = pcall(handler, text, sender)
    if not ok then
        DW.PrintError(L.ERROR, problem)
    end
end)

pcall(frame.RegisterEvent, frame, "CHAT_MSG_ADDON")

-- Hva vi har fått med oss ------------------------------------------------------
--
-- Profil og professions lagres hos alle, så de trenger ikke sendes på nytt
-- hver gang noen logger inn. Den som logger inn, spør derfor bare etter det
-- som er endret siden sist den var pålogget ("R <tid>"), og bare de som har
-- endret noe etter det, svarer. Første gang, og så én gang i uka, spør den
-- etter alt ("R"), i tilfelle en melding har gått tapt.
--
-- Lagret (for hele kontoen, som profilene og professions):
--   DragonworldDB.syncedUntil  servertid da vi sist logget ut etter å ha
--                              spurt og fått svar
--   DragonworldDB.fullSyncAt   servertid da vi sist spurte etter alt og fikk svar

local FULL_SYNC_EVERY = 7 * 24 * 3600
local SYNC_MARGIN = 5 * 60 -- spør litt lenger tilbake enn nødvendig, i tilfelle noe kom sent
local SYNC_SETTLE = 30     -- så lenge de andre får på seg å svare før økten regnes som hørt

-- Servertiden, som er lik for alle spillere. Tidene i "R <tid>" er servertid.
function DW.ServerNow()
    local now = GetServerTime and GetServerTime()
    if type(now) == "number" and not DW.IsSecret(now) then
        return now
    end
    return time()
end

local sessionSince -- nil = ikke bestemt ennå, false = spør etter alt, tall = spør fra da
local askedAt      -- GetTime() da vi sist spurte

-- Tiden de andre skal sende endringer fra (servertid), eller nil for alt.
-- Bestemmes første gang den kalles i en økt, så alle moduler spør likt.
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

-- Meldingen en modul sender for å be de andre om deres: "R" eller "R <tid>".
function DW.SyncRequest()
    askedAt = GetTime()
    local since = DW.SyncSince()
    return since and ("R\t%d"):format(since) or "R"
end

-- Fra en slik melding: tiden avsenderen vil ha endringer fra, 0 for alt.
-- Eldre versjoner sender bare "R", og de får alt, som før.
function DW.SyncRequestSince(text)
    return tonumber((type(text) == "string" and text:match("^R\t(%d+)$")) or "") or 0
end

-- Ved utlogging (og /reload): har vi spurt og gitt de andre tid til å svare,
-- har vi fått med oss alt fram til nå. Ellers spør vi fra samme sted neste
-- gang. En karakter utenfor guilden hører ingenting, og endrer ikke dette.
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
