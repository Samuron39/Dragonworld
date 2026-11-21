-- Dragonworld - knappene som åpner addonen: ved minimapet og i guildvinduet
--
-- Knappen legger seg selv på kanten av minimapet. Klikk åpner hovedvinduet.
-- Den blinker mildt når noe er nytt (Alerts.lua).
-- Den kan dras rundt kanten, og plasseringen huskes. Den kan skjules under
-- Innstillinger eller med "/dw knapp".
--
-- I spillets guildvindu kommer en Dragonworld-fane under de andre fanene på
-- høyre side (se "Fanen i guildvinduet"), i Professions-vinduet snarveier til
-- Dragonworld-fanene Professions og Materialer, og i Looking For Group en
-- snarvei til Dungeons (se "Snarveier under spillets sidefaner").

local ADDON_NAME, DW = ...
local L = DW.L

local BUTTON_NAME = "DragonworldMinimapButton"
local DEFAULT_ANGLE = 215 -- grader: 0 = rett til høyre, 90 = rett opp
local EDGE_OFFSET = 5     -- hvor langt utenfor minimap-kanten knappen ligger

local button
local settings = {} -- lagres: settings.angle (tall) og settings.hide (true/nil)

local function Place()
    if not button then
        return
    end

    local angle = math.rad(settings.angle or DEFAULT_ANGLE)
    local x, y = math.cos(angle), math.sin(angle)
    local w = Minimap:GetWidth() / 2 + EDGE_OFFSET
    local h = Minimap:GetHeight() / 2 + EDGE_OFFSET

    local shape = GetMinimapShape and GetMinimapShape() or "ROUND"
    if shape == "ROUND" then
        x, y = x * w, y * h
    else
        -- Firkantet minimap (fra andre addons): følg kanten av firkanten.
        local diagonalW = math.sqrt(2 * w ^ 2) - 10
        local diagonalH = math.sqrt(2 * h ^ 2) - 10
        x = math.max(-w, math.min(x * diagonalW, w))
        y = math.max(-h, math.min(y * diagonalH, h))
    end

    button:ClearAllPoints()
    button:SetPoint("CENTER", Minimap, "CENTER", x, y)
end

-- Mens knappen dras: la den følge musepekeren rundt kanten.
local function FollowCursor()
    local centerX, centerY = Minimap:GetCenter()
    local cursorX, cursorY = GetCursorPosition()
    local scale = Minimap:GetEffectiveScale()
    settings.angle = math.deg(math.atan2(cursorY / scale - centerY, cursorX / scale - centerX)) % 360
    Place()
end

local function CreateButton()
    local b = CreateFrame("Button", BUTTON_NAME, Minimap)
    b:SetSize(31, 31)
    b:SetFrameStrata("MEDIUM")
    b:SetFrameLevel(8)
    b:RegisterForClicks("LeftButtonUp", "RightButtonUp")
    b:RegisterForDrag("LeftButton")
    b:SetHighlightTexture("Interface\\Minimap\\UI-Minimap-ZoomButton-Highlight")

    local background = b:CreateTexture(nil, "BACKGROUND")
    background:SetSize(24, 24)
    background:SetTexture("Interface\\Minimap\\UI-Minimap-Background")
    background:SetPoint("CENTER", 0, 1)

    b.icon = b:CreateTexture(nil, "ARTWORK")
    b.icon:SetSize(18, 18)
    b.icon:SetTexture(DW.MINIMAP_ICON)
    b.icon:SetPoint("CENTER", 0, 1)

    local border = b:CreateTexture(nil, "OVERLAY")
    border:SetSize(50, 50)
    border:SetTexture("Interface\\Minimap\\MiniMap-TrackingBorder")
    border:SetPoint("TOPLEFT", 0, 0)
    b.border = border

    -- Når noe er nytt (Alerts.lua) blinker den runde ringen rundt knappen i en
    -- farge (en lysende kopi av ringen, oppå den), med en myk glorie rundt.
    -- Gløden ligger rundt ikonet, ikke oppå det, så fargen ikke forsvinner i
    -- det mørke ikonet.
    b.glow = DW.PrepareGlow(b:CreateTexture(nil, "OVERLAY", nil, 7), nil, "Interface\\Minimap\\MiniMap-TrackingBorder")
    b.glow:SetSize(50, 50)
    b.glow:SetPoint("TOPLEFT", 0, 0)
    b.halo = DW.PrepareGlow(b:CreateTexture(nil, "BACKGROUND", nil, -8), "gamepad-hud-actionbar-casting-complete-glow",
        "Interface\\Minimap\\UI-Minimap-ZoomButton-Highlight")
    b.halo:SetSize(60, 60)
    b.halo:SetPoint("CENTER", 0, 0)
    DW.AddGlowTarget({ glows = { b.glow, b.halo } })

    -- Blinker knappen, åpnes fanen med det nye.
    b:SetScript("OnClick", function()
        DW.ClickOpen()
    end)

    b:SetScript("OnDragStart", function(self)
        GameTooltip:Hide()
        self:SetScript("OnUpdate", FollowCursor)
    end)
    b:SetScript("OnDragStop", function(self)
        self:SetScript("OnUpdate", nil)
    end)

    b:SetScript("OnEnter", function(self)
        GameTooltip:SetOwner(self, "ANCHOR_LEFT")
        GameTooltip:AddLine("Dragonworld")
        GameTooltip:AddLine(L.MINIMAP_CLICK, 1, 1, 1)
        GameTooltip:AddLine(L.MINIMAP_DRAG, 0.75, 0.75, 0.75)
        DW.AlertsHovered(GameTooltip) -- listen over det nye; nå er det sett
        GameTooltip:Show()
    end)
    b:SetScript("OnLeave", function()
        GameTooltip:Hide()
    end)

    return b
end

-- Knappen vises bare for medlemmer av guilden, og bare hvis den ikke er skjult
-- under Innstillinger.
local function UpdateVisibility()
    if button then
        button:SetShown(DW.IsMember() and not settings.hide)
    end
end

-- Kalles fra kjernen når lagrede data er lest inn.
function DW.InitMinimapButton(saved)
    settings = saved
    if not button then
        button = CreateButton()
    end
    Place()
    UpdateVisibility()
end

DW.OnMembershipChanged(UpdateVisibility)

function DW.IsMinimapButtonShown()
    return not settings.hide
end

-- Viser eller skjuler knappen, og husker valget.
function DW.SetMinimapButtonShown(show)
    settings.hide = (not show) or nil
    UpdateVisibility()
end

-- Skjuler knappen hvis den vises, og omvendt. Returnerer true hvis den vises.
function DW.ToggleMinimapButton()
    DW.SetMinimapButtonShown(settings.hide and true or false)
    return not settings.hide
end

-- Fanen i guildvinduet ------------------------------------------------------------
--
-- Spillets vindu "Guild & Communities" (CommunitiesFrame i Blizzard_Communities)
-- har faner på høyre side: chat, medlemmer, guild-info og så videre. Under den
-- nederste av dem legger vi en fane for Dragonworld, laget likt spillets egne
-- (RightSideTabTemplate i Blizzards kode for Forever): 32x32, rammen fra
-- SpellBook-SkillLineTab, ikonet og lys når musen er over, 20 punkter under
-- fanen over. Klikk gjør det samme som minimap-knappen: åpner Dragonworld,
-- eller fanen med det som er nytt. Den blinker også som de andre knappene.
-- Den vises bare når guilden (ikke en annen community) er valgt i vinduet.
--
-- Vinduet lastes først når det åpnes første gang, så fanen lages da. Vi
-- henger oss bare på spillets kode (hooksecurefunc), og endrer ikke den.

local GUILD_WINDOW_ADDON = "Blizzard_Communities"
-- Fanene i vinduet, nederste først.
local WINDOW_TABS = { "GuildPreferredPlaySettingsTab", "GuildInfoTab", "GuildBenefitsTab", "RosterTab", "ChatTab" }

local guildTab

local function LowestTab(window)
    for _, key in ipairs(WINDOW_TABS) do
        local tab = window[key]
        if type(tab) == "table" and tab ~= guildTab and tab.IsShown and tab:IsShown() then
            return tab
        end
    end
    return nil
end

-- Plasserer fanen under den nederste av spillets faner, og viser den når
-- spillet viser sine (og guilden er valgt).
local function UpdateGuildTab()
    if not guildTab then
        return
    end
    local window = guildTab:GetParent()
    local below = LowestTab(window)
    local roster, info = window.RosterTab, window.GuildInfoTab
    local show = DW.IsMember() and below ~= nil and type(roster) == "table" and roster:IsShown()
        and (type(info) ~= "table" or info:IsShown())
    if show then
        guildTab:ClearAllPoints()
        guildTab:SetPoint("TOPLEFT", below, "BOTTOMLEFT", 0, -20)
    end
    guildTab:SetShown(show and true or false)
end

local function CreateGuildTab(window)
    local tab = CreateFrame("Button", "DragonworldGuildTab", window)
    tab:SetSize(32, 32)
    local chat = window.ChatTab
    local level = type(chat) == "table" and chat.GetFrameLevel and chat:GetFrameLevel()
    if type(level) == "number" and not DW.IsSecret(level) then
        tab:SetFrameLevel(level)
    end
    tab:RegisterForClicks("LeftButtonUp")

    tab.border = tab:CreateTexture(nil, "BORDER")
    tab.border:SetTexture("Interface\\SpellBook\\SpellBook-SkillLineTab")
    tab.border:SetSize(64, 64)
    tab.border:SetPoint("TOPLEFT", -3, 11)

    tab.icon = tab:CreateTexture(nil, "ARTWORK", nil, 1)
    tab.icon:SetSize(30, 30)
    tab.icon:SetPoint("CENTER")
    tab.icon:SetTexture(DW.ACTION_ICON or DW.ICON)

    tab:SetHighlightTexture("Interface\\Buttons\\ButtonHilight-Square")

    -- Blinker som knappen på action bar (samme glød rundt firkanten).
    local square = DW.SQUARE_GLOW
    if square and DW.PrepareGlow and DW.AddGlowTarget then
        tab.glow = DW.PrepareGlow(tab:CreateTexture(nil, "OVERLAY", nil, 7), nil, square.texture)
        tab.glow:SetTexCoord(square.coords[1], square.coords[2], square.coords[3], square.coords[4])
        tab.glow:SetSize(32 * square.scale, 32 * square.scale)
        tab.glow:SetPoint("CENTER")
        DW.AddGlowTarget({ glow = tab.glow })
    end

    tab:SetScript("OnClick", function()
        if type(PlaySound) == "function" and SOUNDKIT and SOUNDKIT.IG_MAINMENU_OPTION_CHECKBOX_ON then
            pcall(PlaySound, SOUNDKIT.IG_MAINMENU_OPTION_CHECKBOX_ON)
        end
        DW.ClickOpen()
    end)
    tab:SetScript("OnEnter", function(self)
        GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
        GameTooltip:AddLine("Dragonworld")
        GameTooltip:AddLine(L.GUILD_TAB_TIP, 1, 1, 1, true)
        DW.AlertsHovered(GameTooltip)
        GameTooltip:Show()
    end)
    tab:SetScript("OnLeave", function()
        GameTooltip:Hide()
    end)
    tab:Hide()
    return tab
end

-- Lager fanen når guildvinduet finnes (det er lastet).
local function SetUpGuildTab()
    local window = _G.CommunitiesFrame
    if guildTab or type(window) ~= "table" or type(window.RosterTab) ~= "table" then
        return
    end
    guildTab = CreateGuildTab(window)
    if type(window.UpdateCommunitiesTabs) == "function" then
        hooksecurefunc(window, "UpdateCommunitiesTabs", UpdateGuildTab)
    end
    window:HookScript("OnShow", UpdateGuildTab)
    UpdateGuildTab()
end

DW.OnMembershipChanged(UpdateGuildTab)

-- Snarveier under spillets sidefaner ---------------------------------------------
--
-- Noen av spillets vinduer i Forever har store faner på høyre side, laget med
-- malen LargeSideTabButtonTemplate, 2 punkter fra hverandre:
--   * Professions (ProfessionsFrame i Blizzard_Professions): oversikten øverst
--     (ProfessionsOverviewTab), så én per profession (rightProfessionTabs),
--     vist og skjult av RefreshRightTabs.
--   * Looking For Group (LFGParentFrame i Blizzard_GroupFinder_VanillaStyle):
--     ListingTab, BrowsingTab og WhoListingTab, satt av UpdateTabs.
-- Under den nederste legger vi snarveier til Dragonworld-faner: Professions og
-- Materialer i Professions-vinduet, Dungeons i Looking For Group. De lages
-- med spillets egen mal, så de ser helt like ut, med et lite guild-skjold nede
-- i hjørnet så man ser at de er Dragonworld sine. Klikk åpner Dragonworld på
-- den fanen. Dungeons-snarveien blinker når noen i guilden er åpne for
-- dungeons på ditt level. Vinduene lastes først når de åpnes, så snarveiene
-- lages da.

local SIDE_WINDOWS = {
    {
        addon = "Blizzard_Professions", frame = "ProfessionsFrame", refresh = "RefreshRightTabs",
        gameTabs = function(window)
            local list = { window.ProfessionsOverviewTab }
            for _, tab in ipairs(type(window.rightProfessionTabs) == "table" and window.rightProfessionTabs or {}) do
                list[#list + 1] = tab
            end
            return list
        end,
        -- Materialer-fanen har ambolten som ikon, som også er ikonet til
        -- Blacksmithing i spillets faner. Her får den malm, så de ikke forveksles.
        shortcuts = {
            { module = "professions", icon = "Interface\\Icons\\INV_Misc_Book_09" },
            { module = "materialer", icon = "Interface\\Icons\\INV_Ore_Copper_01" },
        },
    },
    {
        addon = "Blizzard_GroupFinder_VanillaStyle", frame = "LFGParentFrame", refresh = "UpdateTabs",
        gameTabs = function(window)
            return { window.ListingTab, window.BrowsingTab, window.WhoListingTab }
        end,
        shortcuts = {
            -- Blinker når noen i guilden er åpne for dungeons på ditt level
            -- (varselet "dungeon" i Dungeons.lua, det samme som minimap-knappen).
            { module = "dungeons", icon = "Interface\\Icons\\Ability_DualWield", alert = "dungeon" },
        },
    },
}

-- En snarvei som hører til et varsel, lyser med spillets egen glød for
-- sidefaner (TabGlow, som pulserer), farget som varselet, så lenge det er nytt.
local function UpdateSideTabGlow(tab)
    if not tab.alert or not tab.SetTabGlowAnimationPlaying then
        return
    end
    local on = DW.IsMember() and DW.IsAlertBlinking and DW.IsAlertBlinking(tab.alert) or false
    if on ~= (tab.glowing or false) then
        tab.glowing = on
        tab:SetTabGlowAnimationPlaying(on)
    end
end

-- Den nederste av spillets faner som vises (de står ovenfra og ned i listen).
local function LowestShown(tabs)
    local lowest
    for _, tab in ipairs(tabs) do
        if type(tab) == "table" and tab.IsShown and tab:IsShown() then
            lowest = tab
        end
    end
    return lowest
end

local function UpdateSideTabs(side)
    local created = side.created
    if not created or not created[1] then
        return
    end
    local above = LowestShown(side.gameTabs(created[1]:GetParent()))
    local show = DW.IsMember() and above ~= nil
    for _, tab in ipairs(created) do
        if show and DW.modules[tab.module] then
            tab:ClearAllPoints()
            tab:SetPoint("TOPLEFT", above, "BOTTOMLEFT", 0, -2)
            tab:Show()
            above = tab
        else
            tab:Hide()
        end
        UpdateSideTabGlow(tab)
    end
end

local function CreateSideTab(window, first, shortcut)
    local ok, tab = pcall(CreateFrame, "Frame", nil, window, "LargeSideTabButtonTemplate")
    if not ok or type(tab) ~= "table" or type(tab.Icon) ~= "table" then
        return nil
    end
    tab.module = shortcut.module
    tab.alert = shortcut.alert
    tab:EnableMouse(true)
    local level = first.GetFrameLevel and first:GetFrameLevel()
    if type(level) == "number" and not DW.IsSecret(level) then
        tab:SetFrameLevel(level)
    end
    tab.Icon:SetTexture(shortcut.icon)
    -- Ikonet fyller fanen, som spillets egne (fillToInterior).
    tab.fillToInterior = true
    if tab.SetChecked then
        tab:SetChecked(false)
    end

    tab.badge = tab:CreateTexture(nil, "OVERLAY", nil, 7)
    tab.badge:SetSize(20, 20)
    tab.badge:SetPoint("BOTTOMLEFT", tab.Icon, "BOTTOMLEFT", -3, -3)
    tab.badge:SetTexture(DW.ICON)

    -- Gløden får varselets farge (gjort grå først, så fargen blir ren).
    if tab.alert and type(tab.TabGlow) == "table" then
        for _, alert in ipairs(DW.ALERTS or {}) do
            if alert.kind == tab.alert and alert.color then
                tab.TabGlow:SetDesaturated(true)
                tab.TabGlow:SetVertexColor(alert.color[1], alert.color[2], alert.color[3])
            end
        end
    end

    -- Tooltipen: "Dragonworld: Professions" og hva fanen gjør, på valgt språk,
    -- og for Dungeons hvem som er åpne nå (hvis det er nytt).
    tab.GetTooltipTextSetupFunction = function(self)
        return function(tooltip)
            local module = DW.modules[self.module]
            if not module then
                return false
            end
            tooltip:SetText("Dragonworld: " .. DW.ModuleTitle(module))
            tooltip:AddLine(DW.ModuleNotes(module), 1, 1, 1, true)
            if self.alert and DW.AddAlertLinesFor then
                DW.AddAlertLinesFor(tooltip, self.alert)
            end
            return true
        end
    end
    tab.tooltipText = "Dragonworld"

    if tab.SetCustomOnMouseUpHandler then
        tab:SetCustomOnMouseUpHandler(function(self, button, upInside)
            if button == "LeftButton" and upInside ~= false and DW.OpenModule and DW.IsMember() then
                DW.OpenModule(self.module)
            end
        end)
    end
    tab:Hide()
    return tab
end

-- Lager snarveiene i et vindu når det finnes (er lastet), én gang.
local function SetUpSideTabs(side)
    local window = _G[side.frame]
    if side.created or type(window) ~= "table" then
        return
    end
    local first = side.gameTabs(window)[1]
    if type(first) ~= "table" then
        return
    end
    side.created = {}
    for _, shortcut in ipairs(side.shortcuts) do
        side.created[#side.created + 1] = CreateSideTab(window, first, shortcut)
    end
    local function Update()
        UpdateSideTabs(side)
    end
    if type(window[side.refresh]) == "function" then
        hooksecurefunc(window, side.refresh, Update)
    end
    window:HookScript("OnShow", Update)
    Update()
end

DW.OnMembershipChanged(function()
    for _, side in ipairs(SIDE_WINDOWS) do
        UpdateSideTabs(side)
    end
end)

DW.OnAlertsChanged(function()
    for _, side in ipairs(SIDE_WINDOWS) do
        for _, tab in ipairs(side.created or {}) do
            UpdateSideTabGlow(tab)
        end
    end
end)

-- Andre addons kan gjøre minimapet firkantet. De er først ferdig lastet ved
-- innlogging, så knappen plasseres på nytt da. Guildvinduet og vinduene med
-- sidefaner lastes når de åpnes første gang (eller er alt lastet av en annen addon).
local frame = CreateFrame("Frame")
frame:RegisterEvent("PLAYER_LOGIN")
frame:RegisterEvent("ADDON_LOADED")
frame:SetScript("OnEvent", function(self, event, name)
    if event == "PLAYER_LOGIN" then
        Place()
        SetUpGuildTab()
    elseif name == GUILD_WINDOW_ADDON then
        SetUpGuildTab()
    end
    for _, side in ipairs(SIDE_WINDOWS) do
        if event == "PLAYER_LOGIN" or name == side.addon then
            SetUpSideTabs(side)
        end
    end
end)
