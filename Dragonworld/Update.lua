-- Dragonworld - "oppdater addonen"
--
-- En addon får ikke lese fra internett eller skrive filer, så den kan ikke
-- selv hente en ny versjon. I stedet forteller addonene i guilden hverandre
-- hvilken versjon de har (DW.RELEASE fra Version.lua). Hører addonen om en
-- nyere versjon enn sin egen, vises et vindu:
--   * Med automatisk oppdatering (DW.AUTO_UPDATE, satt av Dragonworld
--     Updater) er den nye versjonen alt lastet ned i bakgrunnen: "Skriv
--     /reload", med en knapp som gjør det. Har den nye versjonen nye filer
--     eller bilder (DW.RESTART_RELEASE), må spillet startes helt på nytt i
--     stedet, og det står det.
--     Vinduet venter til versjonen har vært ute så lenge at bakgrunnsjobben
--     sikkert har hentet den (DW.RELEASED_AT + 20 minutter).
--   * Uten: "Oppdater Dragonworld!", med hvordan og lenken til nedlasting.
--
-- Slik går det til:
--   * Litt etter innlogging sier addonen hvilken versjon den har.
--   * Hører den en eldre versjon, svarer den med sin egen etter noen
--     sekunder, så den som er utdatert får vite det. Har en annen alt svart
--     med samme eller nyere versjon i mellomtiden, lar den være.
--   * Den nyeste versjonen den har hørt om huskes (DragonworldDB.update), så
--     vinduet kommer igjen ved neste innlogging til addonen er oppdatert, selv
--     om ingen med den nye versjonen er pålogget da.
--   * Vinduet vises ikke midt i en kamp, og høyst én gang per økt.
--
-- Meldinger (navn DragonworldVer, felter skilt med tabulator):
--   V versjon tocversjon omstart utlagt
--       versjon    min DW.RELEASE
--       tocversjon bare til feilsøking
--       omstart    min DW.RESTART_RELEASE (fra 0.15.2)
--       utlagt     min DW.RELEASED_AT     (fra 0.15.2)
--   Eldre versjoner sender bare de to første feltene, og leser bare dem.
--
-- All tekst ligger i Locales.lua (navnene som begynner med UP_).

local ADDON_NAME, DW = ...
local L = DW.L

local PREFIX = "DragonworldVer" -- navnet på meldingene; maks 16 tegn
local SEP = "\t"
local HELLO_DELAY = 12          -- sekunder etter innlogging
local POPUP_DELAY = 20          -- vinduet ved innlogging kommer litt etter
local REPLY_MIN, REPLY_SPREAD = 2, 8
local AUTO_DELAY = 20 * 60      -- så lenge etter utleggingen er den sikkert hentet i bakgrunnen (GitHub kan henge noen minutter, jobben går hvert 10.)

-- Versjonsnummer ----------------------------------------------------------------

-- "0.14.2" blir { 0, 14, 2 }. Alt som ikke ser ut som et versjonsnummer gir nil.
local function Parse(version)
    if type(version) ~= "string" or #version > 20 or not version:match("^%d+%.%d+[%.%d]*$") then
        return nil
    end
    local parts = {}
    for number in version:gmatch("%d+") do
        parts[#parts + 1] = tonumber(number)
    end
    return parts
end

-- -1 hvis a er eldre enn b, 1 hvis nyere, 0 hvis like (eller ukjent).
function DW.CompareVersions(a, b)
    local pa, pb = Parse(a), Parse(b)
    if not pa or not pb then
        return 0
    end
    for index = 1, math.max(#pa, #pb) do
        local x, y = pa[index] or 0, pb[index] or 0
        if x ~= y then
            return x < y and -1 or 1
        end
    end
    return 0
end

local function MyVersion()
    return DW.RELEASE or "0"
end

local function Now()
    local now = GetServerTime and GetServerTime()
    if type(now) == "number" and not DW.IsSecret(now) then
        return now
    end
    return time()
end

-- Versjonen i Dragonworld.toc (vises i addon-listen). Bare til feilsøking.
local function TocVersion()
    local get = (C_AddOns and C_AddOns.GetAddOnMetadata) or GetAddOnMetadata
    if not get then
        return "?"
    end
    local ok, version = pcall(get, ADDON_NAME, "Version")
    if ok and type(version) == "string" and not DW.IsSecret(version) then
        return version
    end
    return "?"
end

-- Det som huskes, felles for kontoen:
--   { newest = "0.16.0", from = "Navn", restart = "0.16.0", releasedAt = tid }
local function Store()
    if type(DragonworldDB) ~= "table" then
        return nil
    end
    if type(DragonworldDB.update) ~= "table" then
        DragonworldDB.update = {}
    end
    local store = DragonworldDB.update
    -- Har vi oppdatert siden sist, er det vi husket ikke nyere lenger.
    if store.newest and DW.CompareVersions(store.newest, MyVersion()) <= 0 then
        store.newest, store.from, store.restart, store.releasedAt = nil, nil, nil, nil
    end
    return store
end

-- Den nyeste versjonen addonen vet om: en annens, eller vår egen.
function DW.NewestVersion()
    local store = Store()
    return (store and store.newest) or MyVersion()
end

-- Finnes det en nyere versjon enn den vi har?
function DW.IsOutdated()
    return DW.CompareVersions(MyVersion(), DW.NewestVersion()) < 0
end

-- Holder det med /reload for å få den nyeste? Nei hvis den eller en
-- versjon i mellom har nye filer, eller hvis vi ikke vet det.
function DW.UpdateNeedsRestart()
    local store = Store()
    local restart = store and store.restart
    if not Parse(restart) then
        return true
    end
    return DW.CompareVersions(MyVersion(), restart) < 0
end

-- Er automatisk oppdatering slått på for denne PC-en?
function DW.IsAutoUpdate()
    return DW.AUTO_UPDATE == true
end

local listeners = {}

-- Registrerer en funksjon som kalles når addonen hører om en nyere versjon
-- (Innstillinger bruker det til å vise det).
function DW.OnNewerVersion(callback)
    listeners[#listeners + 1] = callback
end

-- Vinduet -------------------------------------------------------------------------

local popup
local shownFor -- versjonen vinduet sist ble vist for i denne økten

local function SelectLink(box)
    box:SetText(DW.DOWNLOAD_URL or "")
    box:HighlightText()
end

local function CreatePopup()
    local f = CreateFrame("Frame", "DragonworldUpdateNotice", UIParent, "BackdropTemplate")
    f:SetSize(440, 236)
    f:SetPoint("TOP", 0, -140)
    f:SetFrameStrata("DIALOG")
    f:SetBackdrop({
        bgFile = "Interface\\Buttons\\WHITE8X8",
        edgeFile = "Interface\\DialogFrame\\UI-DialogBox-Border",
        edgeSize = 16,
        insets = { left = 4, right = 4, top = 4, bottom = 4 },
    })
    f:SetBackdropColor(0.04, 0.04, 0.06, 0.97)
    f:SetBackdropBorderColor(0.90, 0.72, 0.30, 1)
    f:EnableMouse(true)
    f:SetMovable(true)
    f:SetClampedToScreen(true)
    f:RegisterForDrag("LeftButton")
    f:SetScript("OnDragStart", function(self)
        self:StartMoving()
    end)
    f:SetScript("OnDragStop", function(self)
        self:StopMovingOrSizing()
    end)
    f:Hide()
    table.insert(UISpecialFrames, "DragonworldUpdateNotice") -- Escape lukker

    f.logo = f:CreateTexture(nil, "ARTWORK")
    f.logo:SetSize(56, 56)
    f.logo:SetPoint("TOPLEFT", 14, -12)
    f.logo:SetTexture(DW.ICON)

    f.title = f:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
    f.title:SetPoint("TOPLEFT", f.logo, "TOPRIGHT", 10, -6)
    f.title:SetPoint("RIGHT", -16, 0)
    f.title:SetJustifyH("LEFT")

    f.text = f:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
    f.text:SetPoint("TOPLEFT", f.title, "BOTTOMLEFT", 0, -6)
    f.text:SetPoint("RIGHT", -16, 0)
    f.text:SetJustifyH("LEFT")

    f.how = f:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    f.how:SetPoint("TOPLEFT", 18, -84)
    f.how:SetPoint("RIGHT", -18, 0)
    f.how:SetJustifyH("LEFT")

    -- Lenken i et tekstfelt, så den kan kopieres med Ctrl+C.
    f.link = CreateFrame("EditBox", nil, f, "InputBoxTemplate")
    f.link:SetSize(396, 22)
    f.link:SetPoint("TOPLEFT", 24, -146)
    f.link:SetAutoFocus(false)
    f.link:SetScript("OnEditFocusGained", SelectLink)
    f.link:SetScript("OnTextChanged", function(self, userInput)
        if userInput then
            SelectLink(self) -- teksten skal ikke kunne endres
        end
    end)
    f.link:SetScript("OnEscapePressed", function(self)
        self:ClearFocus()
    end)

    -- Gull: OK, eller "Reload nå" når en /reload er alt som trengs.
    f.ok = DW.CreateButton(f, 130, 28, "gold")
    f.ok:SetPoint("BOTTOM", 0, 16)
    f.ok:SetScript("OnClick", function(self)
        f:Hide()
        if self.reload and ReloadUI then
            ReloadUI()
        end
    end)

    -- "Senere", ved siden av "Reload nå".
    f.later = DW.CreateChip(f, 110, 28)
    f.later.label:SetJustifyH("CENTER")
    f.later:SetPoint("LEFT", f.ok, "RIGHT", 10, 0)
    f.later:SetScript("OnClick", function()
        f:Hide()
    end)

    return f
end

local function RefreshPopup()
    if not popup then
        return
    end
    local newest = DW.NewestVersion()
    local reload = DW.IsAutoUpdate() and not DW.UpdateNeedsRestart()

    if DW.IsAutoUpdate() then
        -- Alt er lastet ned: bare /reload eller omstart igjen.
        popup:SetHeight(160)
        popup.title:SetText(L.UP_READY_TITLE)
        popup.text:SetText((reload and L.UP_READY_RELOAD or L.UP_READY_RESTART):format(newest))
        popup.how:Hide()
        popup.link:Hide()
    else
        popup:SetHeight(236)
        popup.title:SetText(L.UP_TITLE)
        popup.text:SetText(L.UP_TEXT:format(newest, MyVersion()))
        popup.how:SetText(L.UP_HOW)
        popup.link:SetText(DW.DOWNLOAD_URL or "")
        popup.how:Show()
        popup.link:Show()
    end

    popup.ok.reload = reload
    popup.ok.label:SetText(reload and L.UP_RELOAD_NOW or L.UP_OK)
    popup.ok:ClearAllPoints()
    if reload then
        popup.ok:SetPoint("BOTTOM", -60, 16)
        popup.later.label:SetText(L.UP_LATER)
        popup.later:Show()
    else
        popup.ok:SetPoint("BOTTOM", 0, 16)
        popup.later:Hide()
    end
end

-- Viser vinduet. Brukes også av knappen under Innstillinger.
function DW.ShowUpdatePopup()
    if not popup then
        popup = CreatePopup()
    end
    RefreshPopup()
    popup:Show()
end

local waitingForCombat = false
local waitingUntil -- tidspunktet vinduet venter på (automatisk oppdatering)

-- Når er den nyeste sikkert hentet av bakgrunnsjobben? nil = nå.
local function ReadyAt()
    if not DW.IsAutoUpdate() then
        return nil
    end
    local store = Store()
    local releasedAt = store and tonumber(store.releasedAt)
    if not releasedAt then
        return nil
    end
    local ready = releasedAt + AUTO_DELAY
    return ready > Now() and ready or nil
end

-- Viser vinduet hvis addonen er utdatert og det ikke er vist for denne
-- versjonen i denne økten. Venter til kampen er over, og med automatisk
-- oppdatering til den nye versjonen sikkert er lastet ned.
local function MaybeShowPopup()
    if not DW.IsMember() or not DW.IsOutdated() then
        return
    end
    local newest = DW.NewestVersion()
    if shownFor == newest then
        return
    end
    local ready = ReadyAt()
    if ready then
        -- Én ventende sjekk om gangen; kommer den for tidlig, venter den på nytt.
        if waitingUntil ~= ready and C_Timer and C_Timer.After then
            waitingUntil = ready
            C_Timer.After(ready - Now() + 1, function()
                waitingUntil = nil
                MaybeShowPopup()
            end)
        end
        return
    end
    if InCombatLockdown and InCombatLockdown() then
        waitingForCombat = true
        return
    end
    shownFor = newest
    if DW.IsAutoUpdate() then
        DW.Print((DW.UpdateNeedsRestart() and L.UP_CHAT_RESTART or L.UP_CHAT_RELOAD):format(newest))
    else
        DW.Print(L.UP_CHAT:format(newest, MyVersion(), DW.DOWNLOAD_URL or ""))
    end
    DW.ShowUpdatePopup()
end

DW.OnLanguageChanged(RefreshPopup)

-- Meldinger -----------------------------------------------------------------------

local Send = DW.CreateSender(PREFIX)

local function SendMine()
    Send(table.concat({
        "V", MyVersion(), TocVersion(), DW.RESTART_RELEASE or MyVersion(), ("%d"):format(tonumber(DW.RELEASED_AT) or 0),
    }, SEP))
end

local replyPlanned = false
local heardAtLeastMine = 0 -- når noen sist sa en versjon som er lik eller nyere enn vår

-- Noen har en eldre versjon. Svar med vår etter en liten, tilfeldig stund,
-- så ikke alle svarer samtidig. Har en annen svart i mellomtiden, er det nok.
local function PlanReply()
    if replyPlanned or not (C_Timer and C_Timer.After) then
        return
    end
    replyPlanned = true
    local planned = GetTime()
    C_Timer.After(REPLY_MIN + math.random() * REPLY_SPREAD, function()
        replyPlanned = false
        if DW.IsMember() and heardAtLeastMine < planned then
            SendMine()
        end
    end)
end

local lastHeard -- til feilsøking: "Navn: versjon"

DW.OnGuildMessage(PREFIX, function(text, sender)
    local fields = {}
    for field in (text .. SEP):gmatch("(.-)" .. SEP) do
        fields[#fields + 1] = field
    end
    local kind, version = fields[1], fields[2]
    if kind ~= "V" or not Parse(version) then
        return
    end
    lastHeard = sender .. ": " .. version

    local compared = DW.CompareVersions(version, MyVersion())
    if compared >= 0 then
        heardAtLeastMine = GetTime()
    end
    if compared < 0 then
        PlanReply()
    elseif compared > 0 then
        local store = Store()
        if store then
            local restart = Parse(fields[4]) and fields[4] or nil
            local releasedAt = tonumber(fields[5])
            if releasedAt and (releasedAt <= 0 or releasedAt > Now() + 86400) then
                releasedAt = nil
            end
            local newer = DW.CompareVersions(version, store.newest or MyVersion()) > 0
            if newer then
                store.newest = version
                store.from = (sender:match("^([^-]+)")) or sender
                store.restart, store.releasedAt = restart, releasedAt
            elseif version == store.newest then
                -- Samme versjon fra en annen: fyll inn det vi manglet.
                store.restart = store.restart or restart
                store.releasedAt = store.releasedAt or releasedAt
            end
            if newer then
                for _, callback in ipairs(listeners) do
                    pcall(callback, version)
                end
            end
        end
        MaybeShowPopup()
    end
end)

-- Innlogging --------------------------------------------------------------------

local helloSent = false

local function PlanHello()
    if helloSent or not (C_Timer and C_Timer.After) then
        return
    end
    helloSent = true
    C_Timer.After(HELLO_DELAY, function()
        if DW.IsMember() then
            SendMine()
        else
            helloSent = false -- prøv igjen når guilden er kjent
        end
    end)
    -- Visste vi om en nyere versjon fra før, kommer vinduet litt senere.
    C_Timer.After(POPUP_DELAY, MaybeShowPopup)
end

local frame = CreateFrame("Frame")
frame:SetScript("OnEvent", function(self, event)
    if event == "PLAYER_REGEN_ENABLED" then
        if waitingForCombat then
            waitingForCombat = false
            MaybeShowPopup()
        end
    elseif DW.IsMember() then
        PlanHello()
    end
end)
pcall(frame.RegisterEvent, frame, "PLAYER_ENTERING_WORLD")
pcall(frame.RegisterEvent, frame, "PLAYER_REGEN_ENABLED")

DW.OnMembershipChanged(function(member)
    if member then
        PlanHello()
    end
end)

DW.AddDebug("versjon", function(add)
    local store = Store()
    add("min: " .. DW.DebugText(MyVersion()) .. " | toc: " .. DW.DebugText(TocVersion())
        .. " | automatisk: " .. DW.DebugText(DW.IsAutoUpdate()) .. " | omstart fra: " .. DW.DebugText(DW.RESTART_RELEASE)
        .. " | nyeste kjente: " .. DW.DebugText(DW.NewestVersion()) .. " | fra: " .. DW.DebugText(store and store.from)
        .. " | omstart: " .. DW.DebugText(store and store.restart) .. " | utlagt: " .. DW.DebugText(store and store.releasedAt)
        .. " | sist hørt: " .. DW.DebugText(lastHeard))
end)
