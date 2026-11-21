-- Dragonworld - blinking når noe er nytt
--
-- Knappen ved minimapet og knappen på action bar (ActionButton.lua) blinker
-- mildt i en farge når det har skjedd noe nytt, f.eks. at noen i guilden ser
-- etter dungeon eller at det er lagt ut en ny event. Er det flere ting, bytter
-- fargen for hvert blink.
--
-- Blinkingen stopper (varslene regnes som sett) når spilleren
--   * holder musen over knappen: tooltipen viser da en liste over det nye, eller
--   * åpner fanen der det nye er (et klikk på knappen gjør det, også rett
--     etter at musen har vært over den).
--
-- Spilleren kan slå blinkingen av og på under Innstillinger og i første
-- oppsett, og velge hva det skal blinke for. Den er på som standard.
-- Lagres i DragonworldDB.alerts (felles for kontoen):
--   blinkOff = true          blinkingen er slått av
--   off[slag] = true         ikke blink for dette
--   seen[slag] = tid         sist det nye ble sett (serverens klokke)
--
-- Slik melder en modul inn noe som kan blinke (se Events.lua, Dungeons.lua):
--   DW.RegisterAlert({
--       kind = "event",           kort navn
--       module = "events",        fanen som åpnes og som "ser" det nye
--       labelKey = "AL_EVENT",    teksten i Innstillinger
--       color = { r, g, b },      fargen på blinket og i listen
--       Check = function(since)   true hvis noe er nytt siden tiden since
--       Items = function(since)   (valgfri) det nye som tekstlinjer til listen
--   })
-- og kaller DW.RefreshAlerts() når dataene endres.

local ADDON_NAME, DW = ...
local L = DW.L

local PERIOD = 2.4       -- sekunder per blink
local MAX_ALPHA = 0.75   -- så sterkt lyser det på det meste (mildt)
local TINT = 0.55        -- hvor mye rammen ved minimapet farges på det meste
local RECHECK = 30       -- sekunder mellom hver ny sjekk mens noe blinker

DW.ALERTS = {} -- i den rekkefølgen de er meldt inn
local ALERT_BY_KIND = {}

function DW.RegisterAlert(alert)
    assert(type(alert) == "table" and type(alert.kind) == "string" and type(alert.Check) == "function",
        "RegisterAlert: mangler kind eller Check")
    if ALERT_BY_KIND[alert.kind] then
        return
    end
    DW.ALERTS[#DW.ALERTS + 1] = alert
    ALERT_BY_KIND[alert.kind] = alert
end

-- Innstillinger -------------------------------------------------------------------

local function Now()
    local now = GetServerTime and GetServerTime()
    if type(now) == "number" and not DW.IsSecret(now) then
        return now
    end
    return time()
end
DW.AlertNow = Now -- samme klokke for moduler som merker når noe kom

local function Settings()
    if type(DragonworldDB) ~= "table" then
        return nil
    end
    local settings = DragonworldDB.alerts
    if type(settings) ~= "table" then
        settings = {}
        DragonworldDB.alerts = settings
    end
    if type(settings.seen) ~= "table" then
        settings.seen = {}
    end
    if type(settings.off) ~= "table" then
        settings.off = {}
    end
    return settings
end

function DW.IsBlinkOn()
    local settings = Settings()
    return not (settings and settings.blinkOff)
end

function DW.IsAlertOn(kind)
    local settings = Settings()
    return not (settings and settings.off[kind])
end

function DW.AlertSeenTime(kind)
    local settings = Settings()
    return settings and tonumber(settings.seen[kind]) or 0
end

-- Blinking --------------------------------------------------------------------------

-- Det som kan blinke: { glow = tekstur, tint = tekstur eller nil, hidden = true/nil }.
-- glow lyser opp i fargen; tint (rammen ved minimapet) farges litt.
local targets = {}

function DW.AddGlowTarget(target)
    assert(type(target) == "table" and target.glow, "AddGlowTarget: mangler glow")
    targets[#targets + 1] = target
    target.glow:Hide()
    return target
end

local active = {}   -- det som er nytt nå, og som det skal blinkes for
local blinking = false
local clock, sinceCheck = 0, 0

local pulse = CreateFrame("Frame")
DW.alertPulse = pulse -- til testene

local function Paint(color, strength)
    for _, target in ipairs(targets) do
        if target.hidden or not color then
            target.glow:Hide()
            if target.tint then
                target.tint:SetVertexColor(1, 1, 1)
            end
        else
            target.glow:SetVertexColor(color[1], color[2], color[3])
            target.glow:SetAlpha(MAX_ALPHA * strength)
            target.glow:Show()
            if target.tint then
                local mix = TINT * strength
                target.tint:SetVertexColor(1 + (color[1] - 1) * mix, 1 + (color[2] - 1) * mix, 1 + (color[3] - 1) * mix)
            end
        end
    end
end

local function OnUpdate(self, elapsed)
    clock = clock + elapsed
    sinceCheck = sinceCheck + elapsed
    if sinceCheck >= RECHECK then
        sinceCheck = 0
        DW.RefreshAlerts()
        if not blinking then
            return
        end
    end
    -- Mykt opp og ned (0 -> 1 -> 0) per blink, og neste farge for hvert blink.
    local cycle = math.floor(clock / PERIOD)
    local phase = (clock - cycle * PERIOD) / PERIOD
    local strength = 0.5 - 0.5 * math.cos(phase * 2 * math.pi)
    local alert = active[cycle % #active + 1]
    Paint(alert and alert.color, strength)
end

-- Ser etter hva som er nytt, og starter eller stopper blinkingen.
function DW.RefreshAlerts()
    local list = {}
    local settings = Settings()
    if settings and DW.IsMember() then
        for _, alert in ipairs(DW.ALERTS) do
            -- Fanen er åpen nå: da er det nye sett.
            if alert.module and DW.IsModuleShown and DW.IsModuleShown(alert.module) then
                settings.seen[alert.kind] = Now()
            end
            if not settings.off[alert.kind] then
                local ok, isNew = pcall(alert.Check, tonumber(settings.seen[alert.kind]) or 0)
                if ok and isNew then
                    list[#list + 1] = alert
                elseif not ok then
                    DW.PrintError(L.ERROR, isNew)
                end
            end
        end
    end
    active = list

    local shouldBlink = #active > 0 and DW.IsBlinkOn()
    if shouldBlink and not blinking then
        blinking = true
        clock, sinceCheck = 0, 0
        pulse:SetScript("OnUpdate", OnUpdate)
    elseif not shouldBlink and blinking then
        blinking = false
        pulse:SetScript("OnUpdate", nil)
    end
    if not blinking then
        Paint(nil, 0)
    end
end

-- Det som er nytt nå, også når blinkingen er av (til tooltip).
function DW.ActiveAlerts()
    return active
end

function DW.IsBlinking()
    return blinking
end

function DW.SetBlinkOn(on)
    local settings = Settings()
    if settings then
        settings.blinkOff = (not on) or nil
    end
    DW.RefreshAlerts()
end

function DW.SetAlertOn(kind, on)
    local settings = Settings()
    if settings then
        settings.off[kind] = (not on) or nil
    end
    DW.RefreshAlerts()
end

function DW.MarkAlertSeen(kind)
    local settings = Settings()
    if settings then
        settings.seen[kind] = Now()
    end
    DW.RefreshAlerts()
end

-- Listen over det nye ---------------------------------------------------------------

local MAX_ITEMS = 5     -- linjer per slag i listen; resten blir "...og 3 til"
local CLICK_MEMORY = 60 -- så lenge etter at musen var over knappen åpner et klikk fanen med det nye

local shownLines = {}   -- linjene i tooltipen mens musen er over knappen
local hovered           -- { alerts, at, blinking }: det som ble sett med musen sist

-- Det nye som linjer: { { alert, text }, ... }, fra modulenes Items(since).
local function CollectLines(list)
    local lines = {}
    for _, alert in ipairs(list) do
        local items
        if alert.Items then
            local ok, result = pcall(alert.Items, DW.AlertSeenTime(alert.kind))
            items = ok and type(result) == "table" and result or nil
        end
        if not items or #items == 0 then
            items = { L[alert.labelKey or alert.kind] }
        end
        for index, text in ipairs(items) do
            if index > MAX_ITEMS then
                lines[#lines + 1] = { alert = alert, text = L.AL_MORE:format(#items - MAX_ITEMS) }
                break
            end
            lines[#lines + 1] = { alert = alert, text = text }
        end
    end
    return lines
end

-- Legger listen (fra sist musen kom over knappen) i tooltipen. Brukes også
-- når spillet tegner tooltipen på action bar-knappen på nytt.
function DW.AddAlertLines(tooltip)
    if #shownLines == 0 then
        return
    end
    tooltip:AddLine(" ")
    tooltip:AddLine(L.AL_HEADER, 1.00, 0.82, 0.00)
    for _, line in ipairs(shownLines) do
        local color = line.alert.color or { 1, 1, 1 }
        tooltip:AddLine(line.text, color[1], color[2], color[3], true)
    end
end

-- Musen kommer over knappen ved minimapet eller på action bar: vis listen over
-- det nye i tooltipen, og regn det som sett, så blinkingen stopper.
function DW.AlertsHovered(tooltip)
    DW.RefreshAlerts()
    shownLines = CollectLines(active)
    if #active > 0 then
        hovered = { alerts = active, at = GetTime(), blinking = blinking }
        local settings = Settings()
        if settings then
            for _, alert in ipairs(active) do
                settings.seen[alert.kind] = Now()
            end
        end
        DW.RefreshAlerts()
    end
    if tooltip then
        DW.AddAlertLines(tooltip)
    end
end

-- Knappene ------------------------------------------------------------------------

-- Klikk på knappen ved minimapet eller på action bar: blinker den (eller
-- blinket den til musen kom over den nettopp), åpnes fanen med det nye.
-- Ellers åpnes eller lukkes hovedvinduet som vanlig.
function DW.ClickOpen()
    if DW.IsMainWindowShown and DW.IsMainWindowShown() then
        DW.ToggleMainWindow()
        return
    end
    DW.RefreshAlerts()
    local first = blinking and active[1]
    if not first and hovered and hovered.blinking and GetTime() - hovered.at <= CLICK_MEMORY then
        first = hovered.alerts[1]
    end
    hovered = nil
    if first and first.module and DW.modules[first.module] then
        DW.OpenModule(first.module)
    else
        DW.ToggleMainWindow()
    end
end

-- Hendelser -------------------------------------------------------------------------

-- Spillet melder ofte om medlemslisten. Sjekk høyst én gang i sekundet.
local queued = false
local function QueueRefresh()
    if queued or not (C_Timer and C_Timer.After) then
        return
    end
    queued = true
    C_Timer.After(1, function()
        queued = false
        DW.RefreshAlerts()
    end)
end
DW.QueueAlertRefresh = QueueRefresh

local frame = CreateFrame("Frame")
frame:SetScript("OnEvent", QueueRefresh)
for _, event in ipairs({ "PLAYER_ENTERING_WORLD", "GUILD_ROSTER_UPDATE", "PLAYER_LEVEL_UP" }) do
    pcall(frame.RegisterEvent, frame, event)
end

DW.OnStatusChanged(QueueRefresh)
DW.OnMembershipChanged(QueueRefresh)

DW.AddDebug("blinking", function(add)
    local names = {}
    for _, alert in ipairs(active) do
        names[#names + 1] = alert.kind
    end
    local seen = {}
    for _, alert in ipairs(DW.ALERTS) do
        seen[#seen + 1] = alert.kind .. "=" .. DW.AlertSeenTime(alert.kind) .. (DW.IsAlertOn(alert.kind) and "" or " (av)")
    end
    add("på: " .. DW.DebugText(DW.IsBlinkOn()) .. " | blinker: " .. DW.DebugText(blinking)
        .. " | nytt: " .. table.concat(names, ",") .. " | sett: " .. table.concat(seen, ", ") .. " | knapper: " .. #targets)
end)
