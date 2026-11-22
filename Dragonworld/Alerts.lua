-- Dragonworld - blinking when something is new
--
-- The minimap button and the action bar button (ActionButton.lua) blink
-- softly in a colour when something new has happened, e.g. someone in the
-- guild is looking for a dungeon or a new event has been posted. If there are
-- several things, the colour changes with every blink.
--
-- The blinking stops (the alerts count as seen) when the player
--   * holds the mouse over the button: the tooltip then shows a list of what is new, or
--   * opens the tab where the new thing is (a click on the button does that,
--     also right after the mouse has been over it).
--
-- The player can turn the blinking on and off under Settings and in the first
-- setup, and choose what it should blink for. It is on by default.
-- Saved in DragonworldDB.alerts (shared by the whole account):
--   blinkOff = true          the blinking is turned off
--   off[kind] = true         don't blink for this
--   seen[kind] = time        when the new thing was last seen (server clock)
--
-- This is how a module reports something that can blink (see Events.lua, Dungeons.lua):
--   DW.RegisterAlert({
--       kind = "event",           short name
--       module = "events",        the tab that opens and that "sees" the new thing
--       labelKey = "AL_EVENT",    the text in Settings
--       color = { r, g, b },      the colour of the blink and in the list
--       Check = function(since)   true if something is new since the time since
--       Items = function(since)   (optional) the new things as text lines for the list
--       defaultOff = true         (optional) off until the player turns it on
--       IsShown = function()      (optional) is the new thing shown now? Else: is the tab open
--       Open = function()         (optional) opens where the new thing is. Else: the tab
--   })
-- and calls DW.RefreshAlerts() when the data changes.

local ADDON_NAME, DW = ...
local L = DW.L

local PERIOD = 2.4       -- seconds per blink
local MAX_ALPHA = 1.00   -- how strongly it glows at most
local TINT = 0.55        -- how much a "tint" texture is coloured at most
local RECHECK = 30       -- seconds between each new check while something blinks

DW.ALERTS = {} -- in the order they were reported
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

-- Settings ------------------------------------------------------------------------

local function Now()
    local now = GetServerTime and GetServerTime()
    if type(now) == "number" and not DW.IsSecret(now) then
        return now
    end
    return time()
end
DW.AlertNow = Now -- same clock for modules that note when something came

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
    if type(settings.on) ~= "table" then
        settings.on = {} -- turned on by the player, for what is off by default
    end
    return settings
end

function DW.IsBlinkOn()
    local settings = Settings()
    return not (settings and settings.blinkOff)
end

function DW.IsAlertOn(kind)
    local settings = Settings()
    if settings and settings.off[kind] then
        return false
    end
    if settings and settings.on[kind] then
        return true
    end
    local alert = ALERT_BY_KIND[kind]
    return not (alert and alert.defaultOff)
end

function DW.AlertSeenTime(kind)
    local settings = Settings()
    return settings and tonumber(settings.seen[kind]) or 0
end

-- Blinking --------------------------------------------------------------------------

-- What can blink: { glow = texture, tint = texture or nil, hidden = true/nil }.
-- glow lights up in the colour; tint (the ring at the minimap) is coloured a little.
local targets = {}

-- A target can have several textures that glow: { glows = { ring, halo } }.
function DW.AddGlowTarget(target)
    assert(type(target) == "table" and (target.glow or target.glows), "AddGlowTarget: mangler glow")
    target.glows = target.glows or { target.glow }
    target.glow = target.glow or target.glows[1]
    targets[#targets + 1] = target
    for _, glow in ipairs(target.glows) do
        glow:Hide()
    end
    return target
end

-- Prepares one of the game's own images to glow in a colour: grey (so the
-- colour comes out clean) and added to the light below (ADD). atlas is the
-- game's name for the image; if it does not exist, the file fallback is used.
function DW.PrepareGlow(texture, atlas, fallback)
    local hasAtlas = atlas and texture.SetAtlas
        and (not (C_Texture and C_Texture.GetAtlasInfo) or C_Texture.GetAtlasInfo(atlas) ~= nil)
    if hasAtlas then
        texture:SetAtlas(atlas)
    else
        texture:SetTexture(fallback)
    end
    texture:SetDesaturated(true)
    texture:SetBlendMode("ADD")
    return texture
end

local active = {}   -- what is new now, and what should blink
local blinking = false
local changeListeners = {} -- DW.OnAlertsChanged
local clock, sinceCheck = 0, 0

local pulse = CreateFrame("Frame")
DW.alertPulse = pulse -- for the tests

local function Paint(color, strength)
    for _, target in ipairs(targets) do
        if target.hidden or not color then
            for _, glow in ipairs(target.glows) do
                glow:Hide()
            end
            if target.tint then
                target.tint:SetVertexColor(1, 1, 1)
            end
        else
            for _, glow in ipairs(target.glows) do
                glow:SetVertexColor(color[1], color[2], color[3])
                glow:SetAlpha(MAX_ALPHA * strength)
                glow:Show()
            end
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
    -- Fade softly up and down (0 -> 1 -> 0) per blink, and the next colour for each blink.
    local cycle = math.floor(clock / PERIOD)
    local phase = (clock - cycle * PERIOD) / PERIOD
    local strength = 0.5 - 0.5 * math.cos(phase * 2 * math.pi)
    local alert = active[cycle % #active + 1]
    Paint(alert and alert.color, strength)
end

local testUntil -- GetTime() when the test blinking (/dw blink) ends

-- Blinks in all the colours for a few seconds, regardless of settings.
function DW.TestBlink(seconds)
    seconds = seconds or 15
    testUntil = GetTime() + seconds
    DW.RefreshAlerts()
    if C_Timer and C_Timer.After then
        C_Timer.After(seconds + 0.1, DW.RefreshAlerts)
    end
end

-- Looks for what is new, and starts or stops the blinking.
function DW.RefreshAlerts()
    local list = {}
    local settings = Settings()
    if settings and DW.IsMember() then
        for _, alert in ipairs(DW.ALERTS) do
            -- The new thing is shown now (usually: the tab is open): then it is seen.
            local shown
            if alert.IsShown then
                local ok, result = pcall(alert.IsShown)
                shown = ok and result
            else
                shown = alert.module and DW.IsModuleShown and DW.IsModuleShown(alert.module)
            end
            if shown then
                settings.seen[alert.kind] = Now()
            end
            if DW.IsAlertOn(alert.kind) then
                local ok, isNew = pcall(alert.Check, tonumber(settings.seen[alert.kind]) or 0)
                if ok and isNew then
                    list[#list + 1] = alert
                elseif not ok then
                    DW.PrintError(L.ERROR, isNew)
                end
            end
        end
    end
    -- "/dw blink": all the colours for a short while, so you can see how it looks.
    local testing = testUntil ~= nil and GetTime() < testUntil
    if testing then
        list = {}
        for index, alert in ipairs(DW.ALERTS) do
            list[index] = alert
        end
    end
    active = list

    local shouldBlink = #active > 0 and (DW.IsBlinkOn() or testing)
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
    for _, callback in ipairs(changeListeners) do
        local ok, problem = pcall(callback)
        if not ok then
            DW.PrintError(L.ERROR, problem)
        end
    end
end

-- What is new now, also when the blinking is off (for the tooltip).
function DW.ActiveAlerts()
    return active
end

-- For buttons that blink for just one thing (the Dungeons shortcut in Looking
-- For Group): is there something new of that kind, and is it blinking now?
function DW.IsAlertBlinking(kind)
    if not blinking then
        return false
    end
    for _, alert in ipairs(active) do
        if alert.kind == kind then
            return true
        end
    end
    return false
end

-- Registers a function that is called every time the addon has looked for what
-- is new (and the blinking may have started or stopped).
function DW.OnAlertsChanged(callback)
    changeListeners[#changeListeners + 1] = callback
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
        settings.on[kind] = on and true or nil
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

-- The list of what is new -----------------------------------------------------------

local MAX_ITEMS = 5     -- lines per kind in the list; the rest becomes "...and 3 more"
local CLICK_MEMORY = 60 -- for this long after the mouse was over the button, a click opens the tab with the new thing

local shownLines = {}   -- the lines in the tooltip while the mouse is over the button
local hovered           -- { alerts, at, blinking }: what was seen with the mouse last

-- The new things as lines: { { alert, text }, ... }, from the modules' Items(since).
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

-- The lines for the new things of one kind, in its colour, for a button that
-- only concerns that kind (without counting it as seen).
function DW.AddAlertLinesFor(tooltip, kind)
    local alert = ALERT_BY_KIND[kind]
    if not alert or not DW.IsAlertBlinking(kind) then
        return
    end
    tooltip:AddLine(" ")
    tooltip:AddLine(L.AL_HEADER, 1.00, 0.82, 0.00)
    local color = alert.color or { 1, 1, 1 }
    for _, line in ipairs(CollectLines({ alert })) do
        tooltip:AddLine(line.text, color[1], color[2], color[3], true)
    end
end

-- Puts the list (from when the mouse last came over the button) in the tooltip.
-- Also used when the game redraws the tooltip on the action bar button.
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

-- The mouse comes over the minimap button or the action bar button: show the
-- list of what is new in the tooltip, and count it as seen, so the blinking stops.
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

-- The buttons ---------------------------------------------------------------------

-- Click on the minimap button or the action bar button: if it is blinking (or
-- was blinking until the mouse just came over it), the tab with the new thing opens.
-- Otherwise the main window opens or closes as usual.
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
    if first and first.Open then
        first.Open()
    elseif first and first.module and DW.modules[first.module] then
        DW.OpenModule(first.module)
    else
        DW.ToggleMainWindow()
    end
end

-- Events ----------------------------------------------------------------------------

-- The game often reports the member list. Check at most once a second.
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
