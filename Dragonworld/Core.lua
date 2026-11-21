-- Dragonworld
-- Guild-addon for Dragonworld (WoW Forever, interface 16001).
--
-- Denne filen er kjernen. Den gjør tre ting:
--   1. Holder oversikt over modulene. Hver funksjon i addonen er en modul i
--      mappen Modules.
--   2. Gir hver modul sin egen lagringsplass som huskes mellom økter.
--   3. Gir kommandoen /dw.
--
-- De andre filene:
--   Locales.lua     all tekst, på engelsk, norsk og nederlandsk
--   MainWindow.lua  hovedvinduet: logo, guildnavn, modul-chips, innstillinger
--   Minimap.lua     knappen ved minimapet
--
-- Slik legger du til en ny modul:
--   1. Lag Modules\MinModul.lua og begynn den med:  local ADDON_NAME, DW = ...
--   2. Kall DW.RegisterModule({ id = "minmodul", ... })  (se under)
--   3. Skriv tekstene inn i Locales.lua på alle tre språk.
--   4. Legg til linjen Modules\MinModul.lua nederst i Dragonworld.toc

local ADDON_NAME, DW = ...
local L = DW.L

DW.modules = {}     -- [id] = modul
DW.moduleOrder = {} -- modulene i den rekkefølgen de ble registrert

-- Guild-logoen, laget fra bildet i mappen Iconer (ligger utenfor addonen).
--   ICON          hele skjoldet. Står også som IconTexture i Dragonworld.toc,
--                 så det vises i addon-listen.
--   MINIMAP_ICON  rundt utsnitt av dragehodet, til knappen ved minimapet.
local MEDIA = "Interface\\AddOns\\" .. ADDON_NAME .. "\\Media\\"
DW.MEDIA = MEDIA -- mappen med addonens egne bilder, for moduler som har egne ikoner
DW.ICON = MEDIA .. "icon"
DW.MINIMAP_ICON = MEDIA .. "minimap"

local PREFIX = "|cff33ff99Dragonworld:|r "

function DW.Print(message)
    print(PREFIX .. message)
end

function DW.PrintError(where, problem)
    DW.Print("|cffff5555" .. where .. "|r " .. tostring(problem))
end

-- Den moderne klienten kan gi "hemmelige" verdier som addons ikke får lov til
-- å sammenligne eller regne med. Moduler bruker denne til å hoppe over slike.
function DW.IsSecret(value)
    return type(issecretvalue) == "function" and issecretvalue(value)
end

-- Gir en nøkkel som er unik for karakteren du er logget inn på, f.eks.
-- "Anna-Stormrage", pluss navn og realm hver for seg. Brukes av moduler som
-- lagrer noe per karakter. Returnerer ingenting hvis navnet ikke er klart ennå.
function DW.CharacterKey()
    local name, realm = UnitFullName("player")
    if type(name) ~= "string" or DW.IsSecret(name) or name == "" then
        return nil
    end
    if type(realm) ~= "string" or DW.IsSecret(realm) or realm == "" then
        realm = (GetNormalizedRealmName and GetNormalizedRealmName()) or ""
        if type(realm) ~= "string" or DW.IsSecret(realm) then
            realm = ""
        end
    end
    return name .. "-" .. realm, name, realm
end

-- Karakterens faste ID i spillet (f.eks. "Player-1234-0ABCDEF1"). Brukes til å
-- kjenne igjen en spiller uansett hvordan navnet skrives. I Forever kan navn
-- ha mellomrom, og spillet oppgir dem ikke likt overalt, så ID-en er tryggest.
function DW.MyGUID()
    local guid = UnitGUID and UnitGUID("player")
    if type(guid) == "string" and not DW.IsSecret(guid) and guid ~= "" then
        return guid
    end
    return nil
end

-- Et navn i en form som kan sammenlignes: uten realm, uten mellomrom og med
-- små bokstaver. "Anna Berg-Stormrage" og "AnnaBerg" blir begge "annaberg".
function DW.NameKey(name)
    if type(name) ~= "string" or DW.IsSecret(name) then
        return ""
    end
    local short = name:match("^([^-]+)") or name
    return (short:lower():gsub("%s+", ""))
end

local function PlainNumber(value)
    if type(value) == "number" and not DW.IsSecret(value) then
        return value
    end
    return 0
end

local function PlainText(value)
    if type(value) == "string" and not DW.IsSecret(value) then
        return value
    end
    return ""
end

-- Leser spillets egen medlemsliste. Den har alle i guilden, også de som er
-- avlogget. Hver oppføring har:
--   key       navnet slik spillet oppgir det (som regel "Navn-Realm")
--   name      navnet uten realm
--   guid      spillerens faste ID, hvis spillet oppgir den
--   level, class (f.eks. "MAGE"), rank, rankIndex, zone, note
--   online    true hvis pålogget nå
--   days, hours   hvor lenge siden sist, for dem som er avlogget
--   points    achievement-poengene spillet oppgir (12. verdi), 0 hvis ingen.
--             I Forever er Legacy-systemet spillets versjon av achievements,
--             så dette kan være legacy-poengene. Ikke sjekket i spillet ennå.
function DW.ReadGuildRoster()
    local members = {}
    if not (GetNumGuildMembers and GetGuildRosterInfo) then
        return members
    end

    for index = 1, PlainNumber(GetNumGuildMembers()) do
        local name, rankName, rankIndex, level, _, zone, note, _, isOnline, _, class, points, _, _, _, _, guid = GetGuildRosterInfo(index)
        if PlainText(name) ~= "" then
            local online = (not DW.IsSecret(isOnline)) and isOnline == true
            local days, hours = 0, 0
            if not online and GetGuildRosterLastOnline then
                local years, months, offlineDays, offlineHours = GetGuildRosterLastOnline(index)
                days = PlainNumber(years) * 365 + PlainNumber(months) * 30 + PlainNumber(offlineDays)
                hours = PlainNumber(offlineHours)
            end
            members[#members + 1] = {
                key = name,
                name = name:match("^([^-]+)") or name,
                guid = PlainText(guid) ~= "" and guid or nil,
                rank = PlainText(rankName),
                rankIndex = PlainNumber(rankIndex),
                level = PlainNumber(level),
                class = PlainText(class),
                zone = PlainText(zone),
                note = PlainText(note),
                online = online,
                days = days,
                hours = hours,
                points = PlainNumber(points),
            }
        end
    end
    return members
end

-- Feilsøking --------------------------------------------------------------------

-- "/dw debug" skriver ut det addonen ser hos akkurat denne spilleren: navn,
-- ID, guild, professions og så videre. Det er ment å sendes til den som
-- utvikler addonen når noe ikke virker. Moduler legger til sin egen del.
local debugSections = {}

function DW.AddDebug(title, provider)
    debugSections[#debugSections + 1] = { title = title, provider = provider }
end

-- Tekst av en verdi, uten å røre verdier spillet har gjort hemmelige.
function DW.DebugText(value)
    if DW.IsSecret(value) then
        return "<secret>"
    end
    return tostring(value)
end

function DW.PrintDebug()
    DW.Print("debug")
    for _, section in ipairs(debugSections) do
        local lines = {}
        local ok, problem = pcall(section.provider, function(text)
            lines[#lines + 1] = tostring(text)
        end)
        print("  [" .. section.title .. "]")
        for _, line in ipairs(lines) do
            print("    " .. line)
        end
        if not ok then
            print("    FEIL: " .. tostring(problem))
        end
    end
end

DW.AddDebug("identitet", function(add)
    local key, name, realm = DW.CharacterKey()
    local text = DW.DebugText
    add("CharacterKey: " .. text(key) .. " | name: " .. text(name) .. " | realm: " .. text(realm))
    add("UnitName: " .. text(UnitName and UnitName("player")) .. " | GUID: " .. text(DW.MyGUID()))
    add("level: " .. text(UnitLevel and UnitLevel("player")) .. " | class: " .. text(UnitClass and select(2, UnitClass("player"))))
    add("IsInGuild: " .. text(IsInGuild and IsInGuild()) .. " | guild: " .. text(GetGuildInfo and GetGuildInfo("player"))
        .. " | medlem: " .. text(DW.IsMember()))
    add("språk: " .. text(DW.GetLanguage()) .. " | interface: " .. text(GetBuildInfo and select(4, GetBuildInfo())))

    local roster = DW.ReadGuildRoster()
    add("medlemsliste: " .. #roster .. " medlemmer")
    local guid = DW.MyGUID()
    for _, member in ipairs(roster) do
        if (guid and member.guid == guid) or DW.NameKey(member.key) == DW.NameKey(name) then
            add("min rad: key=" .. text(member.key) .. " | guid=" .. text(member.guid) .. " | class=" .. text(member.class)
                .. " | level=" .. text(member.level))
        end
    end
end)

-- Medlemskap --------------------------------------------------------------------

-- Addonen virker bare for karakterer som er med i guilden. Dette er en enkel
-- sperre, ikke sikkerhet: koden er åpen for alle som har filene, og en guild
-- med samme navn på en annen realm slipper også gjennom.
--
-- Moduler som gjør noe av seg selv (tooltip, hendelser) må selv sjekke
-- DW.IsMember() først. Kommandoer bruker DW.Guard(), som også forklarer
-- spilleren hvorfor ingenting skjer.
DW.GUILD_NAME = "Dragonworld"

local isMember = false
local currentGuild -- navnet på guilden karakteren er i, hvis det er kjent
local memberListeners = {}

function DW.IsMember()
    return isMember
end

-- Registrerer en funksjon som kalles når karakteren blir eller slutter å være
-- medlem (f.eks. når guild-navnet er lastet etter innlogging).
function DW.OnMembershipChanged(callback)
    memberListeners[#memberListeners + 1] = callback
end

function DW.UpdateMembership()
    local member = isMember

    if not (IsInGuild and IsInGuild()) then
        currentGuild = nil
        member = false
    else
        local name = GetGuildInfo("player")
        if type(name) == "string" and not DW.IsSecret(name) then
            currentGuild = name
            -- Store og små bokstaver og mellomrom spiller ingen rolle, så
            -- "Dragon World" og "dragonworld" godtas også.
            local function Plain(text)
                return (text:lower():gsub("%s+", ""))
            end
            member = (Plain(name) == Plain(DW.GUILD_NAME))
        end
        -- Navnet kan mangle rett etter innlogging. Da beholder vi det vi
        -- visste, og spillet sier fra på nytt når det er klart.
    end

    if member ~= isMember then
        isMember = member
        for _, callback in ipairs(memberListeners) do
            local ok, problem = pcall(callback, member)
            if not ok then
                DW.PrintError(L.ERROR, problem)
            end
        end
    end
end

-- Forklarer i chatten hvorfor addonen er låst.
function DW.PrintLocked()
    DW.Print(L.LOCKED:format(DW.GUILD_NAME))
    DW.Print(currentGuild and L.LOCKED_GUILD:format(currentGuild) or L.LOCKED_NO_GUILD)
end

-- For kommandoer: true hvis karakteren er medlem, ellers skrives forklaringen.
function DW.Guard()
    if isMember then
        return true
    end
    DW.PrintLocked()
    return false
end

-- Registrerer en modul. Tabellen kan ha disse feltene:
--   id          (påkrevd) kort navn med små bokstaver uten mellomrom. Brukes
--               i "/dw <id>" og som nøkkel i lagringen, så ikke endre det.
--   titleKey    navnet på teksten i Locales.lua som er modulens navn.
--   notesKey    navnet på teksten som sier i én linje hva modulen gjør.
--   shortcutKey navnet på teksten som er modulens egen snarvei, f.eks. "/kast".
--   icon        ikonet på modulens chip i hovedvinduet (bane eller fil-ID).
--   OnLoad(self, db)          kalles når lagrede data er lest inn. db er
--                             modulens egen tabell, og alt i den huskes.
--   OnSlash(self, message)    kalles for "/dw <id> <message>".
--   CreatePanel(self, parent) lager modulens innhold i hovedvinduet og
--                             returnerer rammen. Kalles én gang, første gang
--                             modulen velges. Moduler som har denne får en
--                             chip i hovedvinduet.
-- (title og notes kan brukes i stedet for titleKey og notesKey hvis teksten
-- ikke skal oversettes.)
function DW.RegisterModule(module)
    assert(type(module) == "table", "RegisterModule: mangler modul")
    assert(type(module.id) == "string" and module.id:match("^[%l%d]+$"),
        "RegisterModule: id må være små bokstaver/tall uten mellomrom")
    assert(type(module.titleKey) == "string" or type(module.title) == "string",
        "RegisterModule: mangler titleKey")
    assert(not DW.modules[module.id], "RegisterModule: id er brukt fra før: " .. module.id)

    DW.modules[module.id] = module
    DW.moduleOrder[#DW.moduleOrder + 1] = module
    return module
end

-- Modulens navn og beskrivelse på valgt språk.
function DW.ModuleTitle(module)
    return (module.titleKey and L[module.titleKey]) or module.title or module.id
end

function DW.ModuleNotes(module)
    return (module.notesKey and L[module.notesKey]) or module.notes or ""
end

-- Lagring ---------------------------------------------------------------------

local frame = CreateFrame("Frame")
frame:RegisterEvent("ADDON_LOADED")
-- Guild-navnet er ikke alltid klart ved innlogging, så sjekk på nytt hver gang
-- spillet melder noe om guilden.
for _, event in ipairs({ "PLAYER_LOGIN", "PLAYER_ENTERING_WORLD", "PLAYER_GUILD_UPDATE", "GUILD_ROSTER_UPDATE" }) do
    pcall(frame.RegisterEvent, frame, event)
end

frame:SetScript("OnEvent", function(self, event, name)
    if event ~= "ADDON_LOADED" then
        DW.UpdateMembership()
        -- Guild-navnet kan komme litt etter innlogging uten at spillet sier
        -- fra. Sjekk derfor et par ganger til.
        if event == "PLAYER_ENTERING_WORLD" and not isMember and C_Timer and C_Timer.After then
            C_Timer.After(3, DW.UpdateMembership)
            C_Timer.After(10, DW.UpdateMembership)
        end
        return
    end
    if name ~= ADDON_NAME then
        return
    end
    self:UnregisterEvent("ADDON_LOADED")

    if type(DragonworldDB) ~= "table" then
        DragonworldDB = {}
    end
    if type(DragonworldDB.modules) ~= "table" then
        DragonworldDB.modules = {}
    end
    if type(DragonworldDB.minimap) ~= "table" then
        DragonworldDB.minimap = {}
    end

    -- Bruk språket spilleren valgte sist. Har de ikke valgt, gjelder engelsk
    -- til hovedvinduet har spurt.
    if DW.HasChosenLanguage() then
        DW.SetLanguage(DragonworldDB.language)
    end

    for _, module in ipairs(DW.moduleOrder) do
        local db = DragonworldDB.modules[module.id]
        if type(db) ~= "table" then
            db = {}
            DragonworldDB.modules[module.id] = db
        end
        module.db = db

        -- En feil i én modul skal ikke hindre de andre i å starte.
        if module.OnLoad then
            local ok, problem = pcall(module.OnLoad, module, db)
            if not ok then
                DW.PrintError(L.ERROR_IN:format(DW.ModuleTitle(module)), problem)
            end
        end
    end

    DW.UpdateMembership()

    -- Knappen ved minimapet (Minimap.lua).
    if DW.InitMinimapButton then
        local ok, problem = pcall(DW.InitMinimapButton, DragonworldDB.minimap)
        if not ok then
            DW.PrintError(L.ERROR, problem)
        end
    end
end)

-- Kommandoer ------------------------------------------------------------------

-- Ordene virker på alle tre språk, uansett hvilket som er valgt.
local BUTTON_WORDS = { button = true, knapp = true, knop = true }

function DW.PrintHelp()
    DW.Print(L.HELP_HEADER)
    print("  " .. L.HELP_OPEN)
    for _, module in ipairs(DW.moduleOrder) do
        local command = (module.shortcutKey and L[module.shortcutKey]) or ("/dw " .. module.id)
        print(("  %s - %s: %s"):format(command, DW.ModuleTitle(module), DW.ModuleNotes(module)))
    end
    print("  " .. L.HELP_BUTTON)
end

SLASH_DRAGONWORLD1 = "/dw"
SLASH_DRAGONWORLD2 = "/dragonworld"

SlashCmdList["DRAGONWORLD"] = function(message)
    local word, rest = (message or ""):match("^%s*(%S+)%s*(.-)%s*$")

    -- Feilsøking virker alltid, også når addonen er låst, så det går an å
    -- finne ut hvorfor den er det.
    if word and word:lower() == "debug" then
        DW.PrintDebug()
        return
    end

    if not DW.Guard() then
        return
    end

    -- Bare "/dw": åpne eller lukk hovedvinduet. Blinker knappen fordi noe
    -- er nytt, åpnes fanen med det nye (Alerts.lua). Knappen på action bar
    -- er en makro med nettopp "/dw".
    if not word then
        if DW.ClickOpen then
            DW.ClickOpen()
        elseif DW.ToggleMainWindow then
            DW.ToggleMainWindow()
        else
            DW.PrintHelp()
        end
        return
    end
    word = word:lower()

    -- "/dw <modul> ...": send resten til modulen, eller åpne den.
    local module = DW.modules[word]
    if module and module.OnSlash then
        module:OnSlash(rest)
        return
    end
    if module and module.CreatePanel and DW.OpenModule then
        DW.OpenModule(module.id)
        return
    end

    -- "/dw blink": vis hvordan blinkingen ser ut (Alerts.lua).
    if word == "blink" and DW.TestBlink then
        DW.TestBlink(15)
        DW.Print(L.BLINK_TEST)
        return
    end

    if BUTTON_WORDS[word] and DW.ToggleMinimapButton then
        DW.Print(DW.ToggleMinimapButton() and L.BUTTON_SHOWN or L.BUTTON_HIDDEN)
        return
    end

    DW.PrintHelp()
end
