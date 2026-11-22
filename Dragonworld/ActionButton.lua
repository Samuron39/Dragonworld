-- Dragonworld - the button on the action bar
--
-- An addon can't put anything on the action bar itself, but the player can
-- drag a macro there. Under Settings (and in the first setup) there is an icon
-- the player drags down onto the action bar. The addon then creates the macro
-- "Dragonworld" (the command /dw) if it doesn't exist, and puts it on the cursor.
--
-- The macro gets the dragon head from the game's own icons. Where it sits on
-- the action bar, the addon puts the guild logo on top, and a coloured glow
-- around it that blinks when something is new (Alerts.lua). If you hold the
-- mouse over it, the tooltip shows a list of what is new, and the blinking
-- stops. It works on the game's own action bars and on Bartender4, Dominos and ElvUI.
--
-- The macro is shared by all the characters on the account. The addon never
-- deletes it; the player can delete it themselves in the macro window (/macro).

local ADDON_NAME, DW = ...
local L = DW.L

local MACRO_NAME = "Dragonworld"
local MACRO_BODY = "/dw"
local MACRO_ICON = "Interface\\Icons\\INV_Misc_Head_Dragon_01"
-- The glow around the button: the frame from the game's own "proc" glow (the
-- soft square in IconAlert), made grey and coloured, a bit larger than the
-- button. It exists in Forever (GlowingBars uses it there).
local GLOW_TEXTURE = "Interface\\SpellActivationOverlay\\IconAlert"
local GLOW_COORDS = { 0.0078125, 0.5078125, 0.27734375, 0.52734375 }
local GLOW_SCALE = 1.4
DW.ACTION_ICON = DW.MEDIA .. "button" -- the guild logo as icon (Media\button.tga)
-- The same glow is used by the tab in the guild window (Minimap.lua).
DW.SQUARE_GLOW = { texture = GLOW_TEXTURE, coords = GLOW_COORDS, scale = GLOW_SCALE }

-- The macro ---------------------------------------------------------------------

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

-- Creates the macro if it is missing. Gives the macro's number, or nil and why.
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

-- Puts the button on the cursor, ready to be dropped on the action bar.
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

-- The icon the player drags from (Settings and first setup).
function DW.CreateActionButtonSource(parent, size)
    local b = CreateFrame("Button", nil, parent)
    b:SetSize(size, size)
    b:RegisterForClicks("LeftButtonUp")
    b:RegisterForDrag("LeftButton")

    b.icon = b:CreateTexture(nil, "ARTWORK")
    b.icon:SetAllPoints(b)
    b.icon:SetTexture(DW.ACTION_ICON)

    b:SetHighlightTexture("Interface\\Buttons\\ButtonHilight-Square", "ADD")

    -- Both a click and a drag put it on the cursor.
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

-- The buttons on the action bar ------------------------------------------------------

-- The names of the buttons of the game's action bars and of the most common
-- addons that make their own. Only the ones that exist are used.
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

-- Which slot (1-180) the button shows right now. The game's buttons have it in
-- GetPagedID / CalculateAction (newer clients) or in .action; the attribute
-- "action" is only the base slot 1-12 on the main bar, so it comes last.
-- (The same order GlowingBars uses in Forever.)
local function Valid(slot)
    if DW.IsSecret(slot) then
        return nil
    end
    slot = tonumber(slot)
    if slot and slot >= 1 and slot <= 180 then
        return slot
    end
    return nil
end

local function SlotOf(button)
    for _, method in ipairs({ "GetPagedID", "CalculateAction" }) do
        if type(button[method]) == "function" then
            local ok, value = pcall(button[method], button)
            if ok and Valid(value) then
                return Valid(value)
            end
        end
    end
    if Valid(button.action) then
        return Valid(button.action)
    end
    if button._state_type == "action" and Valid(button._state_action) then
        return Valid(button._state_action) -- Bartender4 and ElvUI
    end
    if button.GetAttribute then
        local ok, value = pcall(button.GetAttribute, button, "action")
        if ok then
            return Valid(value)
        end
    end
    return nil
end

-- The name of the macro in a slot. Newer clients have it in C_ActionBar.
local function ActionText(slot)
    local get = (C_ActionBar and C_ActionBar.GetActionText) or GetActionText
    if not get then
        return nil
    end
    local ok, text = pcall(get, slot)
    if ok and type(text) == "string" and not DW.IsSecret(text) then
        return text
    end
    return nil
end

-- What is in a slot: type and number (for debugging too).
local function ActionInfo(slot)
    if not GetActionInfo then
        return nil
    end
    local ok, kind, id = pcall(GetActionInfo, slot)
    if not ok or DW.IsSecret(kind) then
        return nil
    end
    return kind, (not DW.IsSecret(id)) and id or nil
end

local function HoldsMacro(slot, index)
    local kind, id = ActionInfo(slot)
    if kind ~= "macro" then
        return false
    end
    return id == index or ActionText(slot) == MACRO_NAME
end

local overlays = {} -- [button] = { logo, glow, target }

-- Tooltip: when the mouse is over the button with the macro, the list of what
-- is new is added below the game's own text, and it counts as seen (Alerts.lua).
-- The game redraws the tooltip on the action bar several times a second with
-- SetAction, so the list is added every time that happens.
local hoverButton -- the button the mouse is over now, if it has the macro

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

-- The logo and the glow on a button. Created in the button itself, so the
-- keyboard character (hotkey) is still shown over the logo.
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
        -- The game's newer buttons round off the corners of the icon with a mask.
        local mask = button.IconMask
        if mask and overlay.logo.AddMaskTexture then
            pcall(overlay.logo.AddMaskTexture, overlay.logo, mask)
        end
    end

    -- The glow covers the icon and lights it up in the colour.
    local width = button:GetWidth()
    if type(width) ~= "number" or DW.IsSecret(width) or width <= 0 then
        width = 36
    end
    -- In a separate frame over the button (like the game's own proc glow), so it
    -- sits above everything the button draws itself, also the cooldown and the border around the icon.
    overlay.frame = CreateFrame("Frame", nil, button)
    overlay.frame:SetAllPoints(button)
    local level = button.GetFrameLevel and button:GetFrameLevel()
    overlay.frame:SetFrameLevel((type(level) == "number" and not DW.IsSecret(level) and level or 0) + 10)
    overlay.glow = DW.PrepareGlow(overlay.frame:CreateTexture(nil, "OVERLAY", nil, 7), nil, GLOW_TEXTURE)
    overlay.glow:SetTexCoord(GLOW_COORDS[1], GLOW_COORDS[2], GLOW_COORDS[3], GLOW_COORDS[4])
    overlay.glow:SetSize(width * GLOW_SCALE, width * GLOW_SCALE)
    overlay.glow:SetPoint("CENTER", button, "CENTER", 0, 0)
    overlay.target = DW.AddGlowTarget({ glow = overlay.glow, hidden = true })

    -- After the game's own scripts, so their tooltip is made first.
    button:HookScript("OnEnter", OnButtonEnter)
    button:HookScript("OnLeave", OnButtonLeave)

    overlays[button] = overlay
    return overlay
end

local waitingForCombat = false

-- Finds the buttons that have the macro, and puts logo and glow on them (and
-- removes it from buttons that no longer have it).
local function Scan()
    local index = MacroIndex()
    local inCombat = InCombatLockdown and InCombatLockdown()
    for _, button in ipairs(CandidateButtons()) do
        local slot = index and SlotOf(button)
        local holds = slot and HoldsMacro(slot, index)
        local overlay = overlays[button]
        if holds and not overlay and inCombat then
            waitingForCombat = true -- make new textures only after the combat
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

-- Many changes come at the same time (e.g. page switch). Look once.
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
DW.ScanActionButtons = Scan -- for the tests and debugging

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
        .. " | knapper med makroen: " .. shown .. " | kandidater: " .. #CandidateButtons()
        .. " | C_ActionBar.GetActionText: " .. DW.DebugText(C_ActionBar ~= nil and C_ActionBar.GetActionText ~= nil)
        .. " | GetActionText: " .. DW.DebugText(GetActionText ~= nil))
    -- The buttons that have a macro on them: where, which, and whether they have the glow.
    local listed = 0
    for _, button in ipairs(CandidateButtons()) do
        local slot = SlotOf(button)
        local kind, id = ActionInfo(slot or 0)
        if slot and kind == "macro" and listed < 6 then
            listed = listed + 1
            local overlay = overlays[button]
            add(("  %s: plass %s, makro nr %s, navn %s%s"):format(button.GetName and button:GetName() or "?", DW.DebugText(slot),
                DW.DebugText(id), DW.DebugText(ActionText(slot)), (overlay and not overlay.target.hidden) and ", har gløden" or ""))
        end
    end
    if listed == 0 then
        local first = _G.ActionButton1
        add("  ingen knapp med en makro funnet. ActionButton1: plass " .. DW.DebugText(first and SlotOf(first))
            .. " | .action " .. DW.DebugText(first and first.action) .. " | GetPagedID " .. DW.DebugText(first and first.GetPagedID ~= nil))
    end
end)
