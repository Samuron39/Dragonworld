-- Dragonworld - knappen på action bar
--
-- En addon kan ikke legge noe på action bar selv, men spilleren kan dra en
-- makro dit. Under Innstillinger (og i første oppsett) er det et ikon som
-- spilleren drar ned på action bar. Da lager addonen makroen "Dragonworld"
-- (kommandoen /dw) hvis den ikke finnes, og legger den på musepekeren.
--
-- Makroen får dragehodet fra spillets egne ikoner. Der den ligger på action
-- bar, legger addonen guildlogoen oppå, og en farget glød som blinker når noe
-- er nytt (Alerts.lua). Holder man musen over den, viser tooltipen en liste
-- over det nye, og blinkingen stopper. Det virker på spillets egne action
-- bars og på Bartender4, Dominos og ElvUI.
--
-- Makroen er felles for alle karakterene på kontoen. Den slettes aldri av
-- addonen; spilleren kan slette den selv i makrovinduet (/macro).

local ADDON_NAME, DW = ...
local L = DW.L

local MACRO_NAME = "Dragonworld"
local MACRO_BODY = "/dw"
local MACRO_ICON = "Interface\\Icons\\INV_Misc_Head_Dragon_01"
-- Spillets egen lysning når musen er over en knapp. Den finnes i Forever
-- (andre addons der bruker den); farget og pulserende blir den blinket.
local GLOW_TEXTURE = "Interface\\Buttons\\ButtonHilight-Square"
DW.ACTION_ICON = DW.MEDIA .. "button" -- guildlogoen som ikon (Media\button.tga)

-- Makroen -----------------------------------------------------------------------

local function MacroIndex()
    if not GetMacroIndexByName then
        return nil
    end
    local index = GetMacroIndexByName(MACRO_NAME)
    if type(index) == "number" and not DW.IsSecret(index) and index > 0 then
        return index
    end
    return nil
end

local function MacroIcon()
    local id = GetFileIDFromPath and GetFileIDFromPath(MACRO_ICON)
    if type(id) == "number" and not DW.IsSecret(id) and id > 0 then
        return id
    end
    return "INV_Misc_Head_Dragon_01"
end

-- Lager makroen hvis den mangler. Gir makroens nummer, eller nil og hvorfor.
local function EnsureMacro()
    if InCombatLockdown and InCombatLockdown() then
        return nil, L.AB_COMBAT
    end
    local index = MacroIndex()
    if index then
        return index
    end
    if not CreateMacro then
        return nil, L.AB_FAILED
    end
    local accountMacros = GetNumMacros and GetNumMacros()
    if type(accountMacros) == "number" and accountMacros >= (MAX_ACCOUNT_MACROS or 120) then
        return nil, L.AB_FULL
    end
    local ok, result = pcall(CreateMacro, MACRO_NAME, MacroIcon(), MACRO_BODY, false)
    if ok and type(result) == "number" and result > 0 then
        return result
    end
    return MacroIndex(), L.AB_FAILED
end

-- Legger knappen på musepekeren, klar til å slippes på action bar.
function DW.PickupActionButton()
    local index, problem = EnsureMacro()
    if not index then
        DW.Print(problem or L.AB_FAILED)
        return false
    end
    if PickupMacro then
        PickupMacro(index)
    end
    return true
end

-- Ikonet spilleren drar fra (Innstillinger og første oppsett).
function DW.CreateActionButtonSource(parent, size)
    local b = CreateFrame("Button", nil, parent)
    b:SetSize(size, size)
    b:RegisterForClicks("LeftButtonUp")
    b:RegisterForDrag("LeftButton")

    b.icon = b:CreateTexture(nil, "ARTWORK")
    b.icon:SetAllPoints(b)
    b.icon:SetTexture(DW.ACTION_ICON)

    b:SetHighlightTexture("Interface\\Buttons\\ButtonHilight-Square", "ADD")

    -- Både et klikk og et drag legger den på musepekeren.
    b:SetScript("OnDragStart", function()
        GameTooltip:Hide()
        DW.PickupActionButton()
    end)
    b:SetScript("OnClick", function()
        GameTooltip:Hide()
        DW.PickupActionButton()
    end)
    b:SetScript("OnEnter", function(self)
        GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
        GameTooltip:AddLine("Dragonworld")
        GameTooltip:AddLine(L.AB_TIP, 1, 1, 1, true)
        GameTooltip:Show()
    end)
    b:SetScript("OnLeave", function()
        GameTooltip:Hide()
    end)
    return b
end

-- Knappene på action bar -------------------------------------------------------------

-- Navnene på knappene til spillets action bars og til de vanligste addonene
-- som lager egne. Bare de som finnes, brukes.
local function CandidateButtons()
    local list = {}
    local function Add(name)
        local button = _G[name]
        if type(button) == "table" and button.CreateTexture then
            list[#list + 1] = button
        end
    end
    for _, prefix in ipairs({ "ActionButton", "MultiBarBottomLeftButton", "MultiBarBottomRightButton",
        "MultiBarRightButton", "MultiBarLeftButton", "MultiBar5Button", "MultiBar6Button", "MultiBar7Button" }) do
        for index = 1, 12 do
            Add(prefix .. index)
        end
    end
    for index = 1, 180 do
        Add("BT4Button" .. index)
    end
    for index = 1, 168 do
        Add("DominosActionButton" .. index)
    end
    for bar = 1, 15 do
        for index = 1, 12 do
            Add(("ElvUI_Bar%dButton%d"):format(bar, index))
        end
    end
    return list
end

-- Hvilken plass (1-180) knappen viser akkurat nå.
local function SlotOf(button)
    local slot = button.action
    if type(slot) ~= "number" and button._state_type == "action" then
        slot = button._state_action -- Bartender4 og ElvUI
    end
    if type(slot) ~= "number" and button.GetAttribute then
        local ok, value = pcall(button.GetAttribute, button, "action")
        slot = ok and tonumber(value) or nil
    end
    if type(slot) == "number" and not DW.IsSecret(slot) and slot >= 1 and slot <= 180 then
        return slot
    end
    return nil
end

local function HoldsMacro(slot, index)
    if not GetActionInfo then
        return false
    end
    local ok, kind, id = pcall(GetActionInfo, slot)
    if not ok or DW.IsSecret(kind) or kind ~= "macro" then
        return false
    end
    if not DW.IsSecret(id) and id == index then
        return true
    end
    local okText, text = pcall(GetActionText or function() end, slot)
    return okText and not DW.IsSecret(text) and text == MACRO_NAME
end

local overlays = {} -- [knapp] = { logo, glow, target }

-- Tooltip: når musen er over knappen med makroen, legges listen over det nye
-- under spillets egen tekst, og det regnes som sett (Alerts.lua). Spillet
-- tegner tooltipen på action bar på nytt flere ganger i sekundet med
-- SetAction, så listen legges til hver gang det skjer.
local hoverButton -- knappen musen er over nå, hvis den har makroen

local function OnButtonEnter(button)
    local overlay = overlays[button]
    if not overlay or overlay.target.hidden then
        return
    end
    if not GameTooltip:IsOwned(button) then
        GameTooltip:SetOwner(button, "ANCHOR_RIGHT")
        GameTooltip:AddLine("Dragonworld")
    end
    DW.AlertsHovered(GameTooltip)
    hoverButton = button
    GameTooltip:Show()
end

local function OnButtonLeave()
    hoverButton = nil
end

if hooksecurefunc and GameTooltip and GameTooltip.SetAction then
    hooksecurefunc(GameTooltip, "SetAction", function(tooltip)
        if hoverButton and tooltip:IsOwned(hoverButton) then
            DW.AddAlertLines(tooltip)
            tooltip:Show()
        end
    end)
end

-- Logoen og gløden på en knapp. Lages i selve knappen, så tastaturtegnet
-- (hotkey) fortsatt vises over logoen.
local function Overlay(button)
    local overlay = overlays[button]
    if overlay then
        return overlay
    end
    overlay = {}

    local icon = button.icon or button.Icon
    if not icon and button.GetName and button:GetName() then
        icon = _G[button:GetName() .. "Icon"]
    end
    if type(icon) == "table" and icon.GetDrawLayer then
        local layer, sublevel = icon:GetDrawLayer()
        overlay.logo = button:CreateTexture(nil, layer or "ARTWORK", nil, math.min(7, (tonumber(sublevel) or 0) + 1))
        overlay.logo:SetAllPoints(icon)
        overlay.logo:SetTexture(DW.ACTION_ICON)
        -- Spillets nyere knapper runder av hjørnene på ikonet med en maske.
        local mask = button.IconMask
        if mask and overlay.logo.AddMaskTexture then
            pcall(overlay.logo.AddMaskTexture, overlay.logo, mask)
        end
    end

    -- Gløden dekker ikonet og lyser det opp i fargen.
    overlay.glow = button:CreateTexture(nil, "OVERLAY", nil, 7)
    overlay.glow:SetTexture(GLOW_TEXTURE)
    overlay.glow:SetBlendMode("ADD")
    overlay.glow:SetAllPoints(type(icon) == "table" and icon.GetDrawLayer and icon or button)
    overlay.target = DW.AddGlowTarget({ glow = overlay.glow, hidden = true })

    -- Etter spillets egne skript, så tooltipen deres er laget først.
    button:HookScript("OnEnter", OnButtonEnter)
    button:HookScript("OnLeave", OnButtonLeave)

    overlays[button] = overlay
    return overlay
end

local waitingForCombat = false

-- Finner knappene som har makroen, og legger logo og glød på dem (og tar det
-- bort fra knapper som ikke har den lenger).
local function Scan()
    local index = MacroIndex()
    local inCombat = InCombatLockdown and InCombatLockdown()
    for _, button in ipairs(CandidateButtons()) do
        local slot = index and SlotOf(button)
        local holds = slot and HoldsMacro(slot, index)
        local overlay = overlays[button]
        if holds and not overlay and inCombat then
            waitingForCombat = true -- lag nye teksturer først etter kampen
        elseif holds then
            overlay = Overlay(button)
            overlay.target.hidden = nil
            if overlay.logo then
                overlay.logo:Show()
            end
        elseif overlay then
            overlay.target.hidden = true
            overlay.glow:Hide()
            if overlay.logo then
                overlay.logo:Hide()
            end
        end
    end
    DW.RefreshAlerts()
end

-- Mange endringer kommer samtidig (f.eks. sidebytte). Se etter én gang.
local scanQueued = false
local function QueueScan()
    if scanQueued or not (C_Timer and C_Timer.After) then
        return
    end
    scanQueued = true
    C_Timer.After(0.2, function()
        scanQueued = false
        Scan()
    end)
end
DW.ScanActionButtons = Scan -- til testene og feilsøking

local frame = CreateFrame("Frame")
frame:SetScript("OnEvent", function(self, event)
    if event == "PLAYER_REGEN_ENABLED" then
        if waitingForCombat then
            waitingForCombat = false
            QueueScan()
        end
        return
    end
    QueueScan()
end)
for _, event in ipairs({ "PLAYER_ENTERING_WORLD", "ACTIONBAR_SLOT_CHANGED", "ACTIONBAR_PAGE_CHANGED",
    "UPDATE_BONUS_ACTIONBAR", "UPDATE_MACROS", "PLAYER_REGEN_ENABLED" }) do
    pcall(frame.RegisterEvent, frame, event)
end

DW.AddDebug("action bar", function(add)
    local shown = 0
    for _, overlay in pairs(overlays) do
        if not overlay.target.hidden then
            shown = shown + 1
        end
    end
    add("makro: " .. DW.DebugText(MacroIndex()) .. " | ikon: " .. DW.DebugText(MacroIcon())
        .. " | knapper med makroen: " .. shown .. " | kandidater: " .. #CandidateButtons())
end)
