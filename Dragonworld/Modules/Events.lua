-- Dragonworld - Guild-events
-- To ting i én modul:
--   1. Egne events med påmelding. Et medlem lager en event, alle i guilden som
--      har addonen får den, og hver enkelt svarer Kommer / Kanskje / Kommer ikke.
--   2. En oversikt over det som ligger i spillets egen kalender.
--
-- Slik deles events mellom medlemmene:
--   * Addonen sender små meldinger på guild-kanalen som bare andre addoner
--     ser. Ingenting vises i chatten.
--   * Hver event og hver påmelding har et tidsstempel. Kommer det to versjoner
--     av det samme, vinner den nyeste.
--   * Når du logger inn, sender addonen en kort liste over hva du har. De som
--     er pålogget svarer med det du mangler, og ber om det de selv mangler.
--     Den som var avlogget da en event ble laget, får den altså neste gang
--     vedkommende er pålogget samtidig med noen som har den.
--   * Spillet tillater omtrent én melding i sekundet og 255 tegn per melding.
--     Meldinger legges derfor i kø, og tittel og beskrivelse har makslengde.
--
-- Begrensninger det er greit å vite om:
--   * Bare den som laget en event kan slette den (i vinduet). Det er ingen
--     ekte tilgangskontroll: alle i guilden kan i prinsippet sende hva som helst.
--   * Events forsvinner fra listen 12 timer etter start, og glemmes helt etter
--     en uke.
--
-- All tekst ligger i Locales.lua (navnene som begynner med EV_).

local ADDON_NAME, DW = ...
local L = DW.L

local MODULE_ID = "events"
local PREFIX = "DragonworldEv" -- navnet på meldingene; maks 16 tegn
local SEP = "\t"               -- skiller feltene i en melding

local HOUR, DAY = 3600, 86400
local SHOW_AFTER_START = 12 * HOUR -- så lenge etter start vises en event
local KEEP_AFTER_START = 7 * DAY   -- så lenge etter start huskes og deles den
local MAX_TITLE_BYTES = 60
local MAX_NOTE_BYTES = 100
local MAX_MESSAGE_BYTES = 250      -- spillets grense er 255

local STATUSES = { "Y", "M", "N" } -- kommer, kanskje, kommer ikke
local STATUS_KEY = { Y = "EV_YES", M = "EV_MAYBE", N = "EV_NO" }

-- Lagrede data. Settes i OnLoad nederst.
--   db.events[id] = {
--       id, creator, title, note,
--       when     = tidspunktet eventen starter,
--       updated  = når den sist ble endret (nyeste versjon vinner),
--       deleted  = true hvis den er slettet (huskes så slettingen sprer seg),
--       signups  = { ["Navn-Realm"] = { status = "Y"/"M"/"N", updated, class } },
--       arrived  = når vi fikk den fra en annen (serverens klokke), til blinkingen
--   }
--   db.seq = teller som gjør hver id unik
local db = { events = {} }

-- Småting -----------------------------------------------------------------------

local function Num(value)
    return ("%d"):format(value)
end

local function MyKey()
    return (DW.CharacterKey())
end

local function ShortName(key)
    return (type(key) == "string" and key:match("^([^-]+)")) or tostring(key)
end

-- Kutter en tekst til et antall byte uten å etterlate et halvt tegn
-- (æ, ø og å er to byte hver).
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

-- Rydder tekst som skal sendes eller vises: fjerner linjeskift, tabulator og
-- tegnet | (som spillet bruker til farger og lenker), og kutter lengden.
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

-- En id ser slik ut: "Navn-Realm:tidspunkt:teller". Den som laget eventen står
-- altså først.
local function CreatorOf(id)
    return id:match("^(.+):%d+:%d+$")
end

-- Skal eventen fortsatt huskes og deles?
local function Syncable(event)
    return not event.stub and type(event.when) == "number" and event.when > time() - KEEP_AFTER_START
end

-- Antall påmeldinger og tidsstempelet på den nyeste. Brukes til å oppdage at
-- to medlemmer har ulike påmeldinger til samme event.
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

-- Køen og takten ligger i Comm.lua. Send legger en melding i kø til guilden.
local Send = DW.CreateSender(PREFIX)

-- Versjoner vi har sett sendt (av oss eller andre) siden noen sist ba om dem.
-- Brukes til å la være å sende det en annen allerede har sendt.
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

-- Hvem eventen gjelder, som tekst i meldingen: "A" for alle, "L20-40" for et
-- level-spenn, "P7" for sju utvalgte (hvem de er sendes i egne meldinger).
-- Foran står 0 hvis den ikke skal i spillets kalender, 1 hvis den skal, og 2
-- hvis den skal, men den som laget den ikke fikk laget en guild-event (da
-- legger hver enkelt den i sin egen kalender).
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
    -- En melding kan ikke være lengre enn spillet tillater. Er navnet på den
    -- som laget eventen langt, kortes beskrivelsen ned i meldingen.
    local note = event.note or ""
    local message = Build(note)
    if #message > MAX_MESSAGE_BYTES then
        message = Build(Truncate(note, math.max(0, #note - (#message - MAX_MESSAGE_BYTES))))
    end
    Send(message)
    MarkSeenEvent(event.id, event.updated)

    -- De utvalgte sendes for seg, så mange per melding som det er plass til.
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

-- Sender påmeldinger til en event, flere per melding så langt det er plass.
-- players er hvilke som skal med ({ [nøkkel] = true }), eller nil for alle.
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

-- Sender en liste med tekstbiter fordelt på så få meldinger som mulig.
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

-- Utveksling -------------------------------------------------------------------

local RefreshPanel

local hello = {}  -- [avsender] = { [id] = true } mens vi mottar listen deres
local offers = {} -- [id] = { event = true/false, signups = true/false }: det vi skal sende
local wanted = {} -- [id] = true: det vi skal be om
local exchangeScheduled = false

-- Noter at vi skal sende en event og/eller påmeldingene til den.
local function Offer(id, withEvent, withSignups)
    local offer = offers[id]
    if not offer then
        offer = {}
        offers[id] = offer
        -- Fra nå av teller vi hva andre rekker å sende før oss.
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

    -- Be om det vi mangler.
    local ids = SortedKeys(wanted)
    wanted = {}
    SendList("G", ids)

    -- Send det andre mangler, med mindre noen andre rakk det først.
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
    -- Tilfeldig ventetid, så ikke alle som er pålogget svarer samtidig.
    C_Timer.After(1 + math.random() * 3, RunExchange)
end

-- Forteller de andre hva vi har, så de kan sende det vi mangler.
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

-- Mottak ----------------------------------------------------------------------

-- Tar imot en event fra en annen. Returnerer true hvis noe ble endret.
local function ApplyEvent(id, updated, when, deleted, title, note, meta)
    local creator = CreatorOf(id)
    local now = time()
    if not creator or updated > now + DAY or when <= now - KEEP_AFTER_START then
        return false
    end

    local event = db.events[id]
    if event and not event.stub and updated <= event.updated then
        return false -- vi har samme eller nyere versjon
    end
    if not event or event.stub then
        -- Ny for oss: knappene blinker til fanen er åpnet (Alerts.lua).
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

    -- Hvem den gjelder, og om den skal i spillets kalender. Meldinger fra
    -- eldre versjoner har ikke dette feltet; da gjelder eventen alle.
    local cal, spec = tostring(meta or ""):match("^(%d):(.+)$")
    local low, high = (spec or ""):match("^L(%d+)%-(%d+)$")
    local picked = (spec or ""):match("^P(%d+)$")
    event.cal = (cal == "1" or cal == "2") or nil
    event.own = (cal == "2") or nil
    event.aud, event.min, event.max, event.invited, event.invitedCount = nil, nil, nil, nil, nil
    if low then
        event.aud, event.min, event.max = "L", tonumber(low), tonumber(high)
    elseif picked then
        -- Listen over de utvalgte kommer i egne meldinger rett etter.
        event.aud, event.invited, event.invitedCount = "P", {}, tonumber(picked)
    end
    return true
end

-- Tar imot en påmelding. Returnerer true hvis noe ble endret.
local function ApplySignup(id, player, status, updated, class)
    if not STATUS_KEY[status] or updated > time() + DAY or #player > 80 then
        return false
    end

    local event = db.events[id]
    if not event then
        -- Påmelding til en event vi ikke kjenner. Ta vare på den, og be om eventen.
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

            -- Gjelder den et utvalg, skal listen over hvem komme rett etter.
            -- Mangler noe av den om litt, ber vi om eventen på nytt.
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
        -- Hvem en event for utvalgte gjelder. Tas bare imot for den versjonen
        -- av eventen vi har.
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
        -- Listen over hva avsenderen har. Sammenlign med vårt eget.
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
        -- Listen er ferdig. Alt vi har som ikke sto på den, mangler avsenderen.
        local listed = hello[sender] or {}
        hello[sender] = nil
        for id, event in pairs(db.events) do
            if not listed[id] and Syncable(event) then
                Offer(id, true, true)
            end
        end

    elseif kind == "G" then
        -- Noen ber om bestemte events.
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

-- Handlinger ------------------------------------------------------------------

local selectedID -- eventen som vises til høyre
local formOpen = false

-- Det som er valgt i skjemaet for en ny event.
local formAudience = "A" -- hvem den gjelder: "A" alle, "L" level, "P" utvalgte
local formInvited = {}   -- de utvalgte: [nøkkel] = true
local membersOpen = false -- listen for å velge medlemmer er oppe
local memberSearch = ""

-- audience sier hvem eventen gjelder:
--   { aud = "A" }                        alle
--   { aud = "L", min = 20, max = 40 }    et level-spenn
--   { aud = "P", invited = { [nøkkel] = true } }   utvalgte medlemmer
-- og audience.cal = true hvis den også skal i spillets kalender.
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

-- Nøklene som kan stå for karakteren du spiller i en liste over utvalgte:
-- spillerens faste ID, og navnet uten mellomrom for klienter som ikke oppgir ID.
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

-- Gjelder eventen karakteren du spiller nå? Den som laget den ser den alltid.
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

-- Kort tekst om hvem eventen gjelder.
local function AudienceText(event)
    if event.aud == "L" then
        return L.EV_FOR_LEVEL:format(event.min or 1, event.max or 99)
    elseif event.aud == "P" then
        return L.EV_FOR_PICKED:format(event.invitedCount or CountKeys(event.invited))
    end
    return L.EV_FOR_ALL
end

-- Spillets kalender: legge inn ----------------------------------------------------

-- Legger eventen i spillets egen kalender. Må kalles direkte fra et klikk,
-- fordi spillet krever det for å lagre en kalender-event.
--   forGuild = true   en guild-event som alle i guilden ser i kalenderen sin
--   forGuild = false  en personlig oppføring som bare du ser
-- Returnerer true hvis kalenderen tok imot kallene. Gikk det galt, huskes
-- grunnen i calendarProblem, som /dw debug viser.
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
            calendar.EventSetType(4) -- typen "annet"
        end
        calendar.EventSetDate(when.month, when.day, when.year)
        calendar.EventSetTime(when.hour, when.min)
        calendar.AddEvent()
    end)
    calendarProblem = (not ok) and tostring(problem) or nil
    return ok
end

-- Hvilke events denne karakteren alt har lagt i kalenderen sin, så de ikke
-- legges inn to ganger.
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

-- Har denne karakteren lov til å lage guild-events i spillets kalender? Det
-- styres av rangen i guilden.
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

-- Skal eventen ligge i spillets kalender som én guild-event alle ser? Ellers
-- legger hver enkelt den i sin egen kalender.
local function IsGuildWide(event)
    return event.aud == nil and not event.own
end

-- Det siste vi prøvde å legge i kalenderen. Spillet sier fra om feil litt
-- etterpå, og da må vi vite hvilken event det gjaldt.
local lastCalendarTry

-- Legger eventen i spillets kalender én gang, og sier fra i chatten hvordan
-- det gikk.
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

-- Spillet avviste en kalender-event. Var det den vi nettopp la inn, sier vi
-- fra, og glemmer at den er lagt inn så den kan prøves på nytt.
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
        -- Alltid nyere enn forrige svar, selv om klokka står stille i ett sekund.
        updated = math.max(time(), previous and (previous.updated + 1) or 0),
        class = select(2, UnitClass("player")),
    }
    SendSignups(event, { [me] = true })
end

-- Legger eventen ut i guild-chatten som vanlig tekst, så også de uten addonen
-- ser den: én linje med overskrift og tidspunkt, én med beskrivelsen, og én
-- om addonen. Returnerer true hvis det ble sendt.
local lastShare = {} -- [id] = når eventen sist ble delt, så et dobbeltklikk ikke gir dobbel tekst

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

    -- En chatmelding kan være 255 tegn, så hver del sendes for seg.
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

-- Kalenderregning ----------------------------------------------------------------

local function DaysInMonth(year, month)
    if month == 2 then
        local leap = (year % 4 == 0 and year % 100 ~= 0) or (year % 400 == 0)
        return leap and 29 or 28
    end
    return (month == 4 or month == 6 or month == 9 or month == 11) and 30 or 31
end

-- Ukedagen for en dato: 1 = mandag ... 7 = søndag.
local MONTH_OFFSETS = { 0, 3, 2, 5, 0, 3, 5, 1, 4, 6, 2, 4 }

local function Weekday(year, month, day)
    if month < 3 then
        year = year - 1
    end
    local sundayFirst = (year + math.floor(year / 4) - math.floor(year / 100) + math.floor(year / 400)
        + MONTH_OFFSETS[month] + day) % 7
    return (sundayFirst + 6) % 7 + 1
end

-- Leser en dato skrevet som DD.MM.ÅÅÅÅ (eller DD.MM.ÅÅ). Returnerer år, måned
-- og dag, eller ingenting hvis datoen ikke finnes.
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

-- Leser dato og klokkeslett. Klokkeslettet kan skrives 20:00, 20.00, 2000
-- eller bare 20. Returnerer tidspunktet, eller ingenting hvis noe er feil.
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

-- Events som skal vises: ikke slettet, ikke for lenge siden, og bare de som
-- gjelder karakteren du spiller. Nærmeste først.
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

-- Spillets kalender ---------------------------------------------------------------

local CALENDAR_TYPE_KEY = {
    GUILD_EVENT = "EV_CAL_GUILD",
    GUILD_ANNOUNCEMENT = "EV_CAL_GUILD",
    PLAYER = "EV_CAL_PLAYER",
    HOLIDAY = "EV_CAL_HOLIDAY",
    COMMUNITY_EVENT = "EV_CAL_COMMUNITY",
}

-- Leser det som ligger i spillets kalender fra i dag og ut neste måned.
-- Returnerer en liste, eller ingenting hvis kalenderen ikke finnes.
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

    -- Kalenderen regner måneder ut fra den måneden som er valgt i den. Før den
    -- har vært åpnet i økten er det november 2004. Pek den på denne måneden,
    -- men ikke hvis spilleren har kalenderen åpen og blar i den.
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

-- Panelet i hovedvinduet --------------------------------------------------------

local LIST_WIDTH = 250
local EVENT_ROW_HEIGHT = 46
local CALENDAR_ROW_HEIGHT = 22

local panel -- lages første gang modulen velges i hovedvinduet
local view = "guild" -- "guild" eller "calendar"
local picker -- den lille månedsoversikten i skjemaet; lages første gang kalenderknappen trykkes
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

-- Listen for å velge medlemmer ----------------------------------------------------

local memberRows = {}
local RefreshMembers

-- Nøkkelen et medlem står under i listen over utvalgte: spillerens faste ID,
-- eller navnet uten mellomrom hvis klienten ikke oppgir ID.
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

    -- Valgt event kan være slettet eller utløpt. Velg da den første.
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

    -- Høyre side: skjema (eller listen for å velge medlemmer), valgt event,
    -- eller en tekst om at listen er tom.
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

    -- Hvem eventen gjelder.
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

    -- Datovelgeren hører til skjemaet. Lukk den når skjemaet ikke er oppe.
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
        -- Ber spillet hente kalenderen. Svaret kommer som en hendelse.
        C_Calendar.OpenCalendar()
    end
    RefreshPanel()
end

-- Et skrivefelt. Grensen oppgis enten som antall tegn (maxLetters) eller som
-- antall byte (maxBytes, for tekst som skal sendes til guilden).
local function CreateEditBox(parent, width, maxBytes, maxLetters)
    local box = CreateFrame("EditBox", nil, parent, "InputBoxTemplate")
    box:SetSize(width, 22)
    box:SetAutoFocus(false)
    if maxLetters then
        box:SetMaxLetters(maxLetters)
    else
        -- Spillet regner med ett tegn mer enn det slipper inn, så grensen må
        -- settes én høyere enn det vi vil ha plass til.
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

-- Datovelgeren ------------------------------------------------------------------

local pickerYear, pickerMonth -- måneden datovelgeren viser

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

    local blanks = Weekday(pickerYear, pickerMonth, 1) - 1 -- tomme ruter før den første
    local days = DaysInMonth(pickerYear, pickerMonth)
    for index = 1, 42 do
        local button = picker.days[index]
        local day = index - blanks
        if day >= 1 and day <= days then
            -- Dager som har vært kan ikke velges.
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
    p:SetFrameStrata("DIALOG") -- over resten av vinduet
    p:SetBackdrop(DW.PANEL_BACKDROP)
    p:SetBackdropColor(0.05, 0.05, 0.07, 0.98)
    p:SetBackdropBorderColor(0.90, 0.72, 0.30, 1)
    p:EnableMouse(true) -- klikk i ruten skal ikke treffe det som ligger under
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
                -- Skriv den valgte dagen inn i datofeltet og lukk.
                form.dateBox:SetText(("%02d.%02d.%04d"):format(self.day, pickerMonth, pickerYear))
                form.error:SetText("")
                p:Hide()
            end
        end)
        p.days[index] = chip
    end
    return p
end

-- Åpner datovelgeren på måneden som står i datofeltet (eller denne måneden),
-- eller lukker den hvis den alt er åpen.
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

    -- Hvem den gjelder.
    local audience = { aud = formAudience, cal = form.calendarCheck:GetChecked() and true or nil }
    -- Har du ikke lov til å lage guild-events, legger hver enkelt den i sin
    -- egen kalender i stedet.
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

    -- Spillets kalender. For alle blir det en guild-event som hele guilden
    -- ser. Gjelder den et utvalg, legges den i din egen kalender nå, og hos
    -- de andre når de svarer at de kommer.
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

-- Kalles av hovedvinduet første gang modulen velges.
local function CreatePanel(parent)
    local width, height = parent:GetWidth(), parent:GetHeight()
    local bodyHeight = height - 72

    local f = CreateFrame("Frame", nil, parent)
    f:SetAllPoints(parent)

    f.title = f:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
    f.title:SetPoint("TOP", 0, -12)

    -- Fanene: egne events, eller spillets kalender.
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

    -- Egne events: listen til venstre, valgt event eller skjema til høyre.
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

    -- Valgt event.
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

    -- Hvem eventen gjelder: alle, et level-spenn eller utvalgte.
    d.audience = d:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    d.audience:SetPoint("TOPLEFT", d.when, "BOTTOMLEFT", 0, -4)
    d.audience:SetWidth(rightWidth)
    d.audience:SetJustifyH("LEFT")

    d.note = d:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
    d.note:SetPoint("TOPLEFT", d.audience, "BOTTOMLEFT", 0, -8)
    d.note:SetWidth(rightWidth)
    d.note:SetJustifyH("LEFT")

    -- Svarknappene: ett klikk melder deg på, eller endrer svaret ditt.
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
                -- En event for et utvalg legges i din egen kalender i spillet
                -- når du svarer at du kommer eller kanskje kommer. (Events
                -- for alle ligger der allerede, som guild-event.) Laget du
                -- den selv og spillet sa nei første gang, prøves det på nytt.
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

    -- Legger eventen ut i guild-chatten, for dem som ikke har addonen.
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
        -- Bare den som laget eventen kan slette den.
        if event and event.creator == MyKey() then
            DeleteEvent(event)
            selectedID = nil
            RefreshPanel()
        end
    end)

    -- Skjemaet for ny event.
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
    form.dateBox = CreateEditBox(form, 110, nil, 10) -- "20.11.2026" er ti tegn
    form.dateBox:SetPoint("TOPLEFT", 6, -62)

    -- Kalenderknappen: åpner en månedsoversikt der du klikker på dagen.
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
    form.timeBox = CreateEditBox(form, 70, nil, 5) -- "20:00" er fem tegn
    form.timeBox:SetPoint("TOPLEFT", 172, -62)

    form.noteLabel = Label(0, -94)
    form.noteBox = CreateEditBox(form, rightWidth - 12, MAX_NOTE_BYTES)
    form.noteBox:SetPoint("TOPLEFT", 6, -108)

    -- Hvem eventen gjelder: alle, et level-spenn eller utvalgte medlemmer.
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

    -- Level-spennet. Vises bare når "etter level" er valgt.
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

    -- Knappen som åpner listen for å velge medlemmer. Vises bare når
    -- "utvalgte" er valgt.
    form.membersButton = DW.CreateButton(form, 220, 24, "gold")
    form.membersButton:SetPoint("TOPLEFT", 0, -190)
    form.membersButton:SetScript("OnClick", function()
        membersOpen = true
        if picker then
            picker:Hide()
        end
        RefreshPanel()
    end)

    -- Skal eventen også legges i spillets egen kalender?
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

    -- Listen for å velge medlemmer. Den legger seg over skjemaet mens du velger.
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

    -- Spillets kalender.
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

-- Hendelser -------------------------------------------------------------------

-- Meldinger fra andre medlemmer. Comm.lua har alt sjekket at de kommer på
-- guild-kanalen, fra et annet medlem, og fanger feil i ødelagte meldinger.
DW.OnGuildMessage(PREFIX, OnMessage)

local helloSent = false

-- Si fra om hva vi har, én gang per økt, litt etter innlogging når spillet er
-- ferdig med å laste og guild-navnet er kjent.
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

-- Guild-navnet kan komme sent etter innlogging. Si da fra når det er klart.
DW.OnMembershipChanged(function(member)
    if member then
        PlanHello()
    end
end)

DW.OnLanguageChanged(function()
    RefreshPanel()
end)

-- Feilsøking: hva vi har lagret, og om spillets kalender er tilgjengelig.
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

-- Modul --------------------------------------------------------------------------

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

-- Knappene blinker (Alerts.lua) når en annen har lagt ut en event som gjelder
-- deg, og du ikke har åpnet fanen siden den kom.
DW.RegisterAlert({
    kind = "event",
    module = MODULE_ID,
    labelKey = "AL_EVENT",
    color = { 1.00, 0.70, 0.15 }, -- gull
    Check = function(since)
        local me = MyKey()
        for _, event in ipairs(VisibleEvents()) do
            if event.arrived and event.arrived > since and event.creator ~= me then
                return true
            end
        end
        return false
    end,
})
