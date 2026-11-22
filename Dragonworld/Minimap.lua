-- Dragonworld - the buttons that open the addon: at the minimap and in the guild window
--
-- The button places itself on the edge of the minimap. A click opens the main window.
-- It blinks softly when something is new (Alerts.lua).
-- It can be dragged around the edge, and the position is remembered. It can be hidden under
-- Settings or with "/dw button".
--
-- In the game's guild window a Dragonworld tab appears below the other tabs on
-- the right side (see "The tab in the guild window"), in the Professions window shortcuts to
-- the Dragonworld tabs Professions and Materialer, in Looking For Group a
-- shortcut to Dungeons, and in the Legacy window a shortcut to Achievements (see
-- "Shortcuts under the game's side tabs").

local ADDON_NAME, DW = ...
local L = DW.L

local BUTTON_NAME = "DragonworldMinimapButton"
local DEFAULT_ANGLE = 215 -- degrees: 0 = straight right, 90 = straight up
local EDGE_OFFSET = 5     -- how far outside the minimap edge the button sits

local button
local settings = {} -- saved: settings.angle (number) and settings.hide (true/nil)

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
        -- Square minimap (from other addons): follow the edge of the square.
        local diagonalW = math.sqrt(2 * w ^ 2) - 10
        local diagonalH = math.sqrt(2 * h ^ 2) - 10
        x = math.max(-w, math.min(x * diagonalW, w))
        y = math.max(-h, math.min(y * diagonalH, h))
    end

    button:ClearAllPoints()
    button:SetPoint("CENTER", Minimap, "CENTER", x, y)
end

-- While the button is dragged: let it follow the cursor around the edge.
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

    -- When something is new (Alerts.lua) the round ring around the button blinks
    -- in a colour (a glowing copy of the ring, on top of it), with a soft halo around.
    -- The glow sits around the icon, not on top of it, so the colour doesn't
    -- vanish in the dark icon.
    b.glow = DW.PrepareGlow(b:CreateTexture(nil, "OVERLAY", nil, 7), nil, "Interface\\Minimap\\MiniMap-TrackingBorder")
    b.glow:SetSize(50, 50)
    b.glow:SetPoint("TOPLEFT", 0, 0)
    b.halo = DW.PrepareGlow(b:CreateTexture(nil, "BACKGROUND", nil, -8), "gamepad-hud-actionbar-casting-complete-glow",
        "Interface\\Minimap\\UI-Minimap-ZoomButton-Highlight")
    b.halo:SetSize(60, 60)
    b.halo:SetPoint("CENTER", 0, 0)
    DW.AddGlowTarget({ glows = { b.glow, b.halo } })

    -- If the button is blinking, the tab with the new thing opens.
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
        DW.AlertsHovered(GameTooltip) -- the list of what is new; now it is seen
        GameTooltip:Show()
    end)
    b:SetScript("OnLeave", function()
        GameTooltip:Hide()
    end)

    return b
end

-- The button is only shown for members of the guild, and only if it is not hidden
-- under Settings.
local function UpdateVisibility()
    if button then
        button:SetShown(DW.IsMember() and not settings.hide)
    end
end

-- Called from the core when saved data has been read in.
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

-- Shows or hides the button, and remembers the choice.
function DW.SetMinimapButtonShown(show)
    settings.hide = (not show) or nil
    UpdateVisibility()
end

-- Hides the button if it is shown, and the other way round. Returns true if it is shown.
function DW.ToggleMinimapButton()
    DW.SetMinimapButtonShown(settings.hide and true or false)
    return not settings.hide
end

-- The tab in the guild window -----------------------------------------------------
--
-- The game's window "Guild & Communities" (CommunitiesFrame in Blizzard_Communities)
-- has tabs on the right side: chat, members, guild info and so on. Below the
-- lowest of them we add a tab for Dragonworld, made like the game's own
-- (RightSideTabTemplate in Blizzard's code for Forever): 32x32, the frame from
-- SpellBook-SkillLineTab, the icon and highlight when the mouse is over, 20 points below
-- the tab above. A click does the same as the minimap button: opens Dragonworld,
-- or the tab with what is new. It also blinks like the other buttons.
-- Below it comes one more, made the same way, that opens the Achievements tab
-- (with the guild shield in the corner, so you can see it is Dragonworld's).
-- They are only shown when the guild (not another community) is chosen in the window.
--
-- The window is only loaded when it is first opened, so the tab is made then. We
-- only hook into the game's code (hooksecurefunc), and don't change it.

local GUILD_WINDOW_ADDON = "Blizzard_Communities"
-- The tabs in the window, lowest first.
local WINDOW_TABS = { "GuildPreferredPlaySettingsTab", "GuildInfoTab", "GuildBenefitsTab", "RosterTab", "ChatTab" }

local guildTab, achievementsTab
local ACHIEVEMENTS_ICON = "Interface\\Icons\\Achievement_Level_60" -- the same as the module's

local function LowestTab(window)
    for _, key in ipairs(WINDOW_TABS) do
        local tab = window[key]
        if type(tab) == "table" and tab ~= guildTab and tab.IsShown and tab:IsShown() then
            return tab
        end
    end
    return nil
end

-- Places the tab below the lowest of the game's tabs, and shows it when
-- the game shows its own (and the guild is chosen).
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

    if achievementsTab then
        local achievements = show and DW.modules.achievements ~= nil
        if achievements then
            achievementsTab:ClearAllPoints()
            achievementsTab:SetPoint("TOPLEFT", guildTab, "BOTTOMLEFT", 0, -20)
        end
        achievementsTab:SetShown(achievements and true or false)
    end
end

local function PlayClickSound()
    if type(PlaySound) == "function" and SOUNDKIT and SOUNDKIT.IG_MAINMENU_OPTION_CHECKBOX_ON then
        pcall(PlaySound, SOUNDKIT.IG_MAINMENU_OPTION_CHECKBOX_ON)
    end
end

-- A tab that looks like the game's own: the frame, the icon, the highlight.
local function CreateSquareTab(window, name, icon)
    local tab = CreateFrame("Button", name, window)
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
    tab.icon:SetTexture(icon)

    tab:SetHighlightTexture("Interface\\Buttons\\ButtonHilight-Square")
    tab:SetScript("OnLeave", function()
        GameTooltip:Hide()
    end)
    tab:Hide()
    return tab
end

-- The Achievements tab: opens Dragonworld on that tab.
local function CreateAchievementsTab(window)
    local tab = CreateSquareTab(window, "DragonworldGuildAchievementsTab", ACHIEVEMENTS_ICON)
    tab.badge = tab:CreateTexture(nil, "OVERLAY", nil, 7)
    tab.badge:SetSize(14, 14)
    tab.badge:SetPoint("BOTTOMLEFT", tab.icon, "BOTTOMLEFT", -2, -2)
    tab.badge:SetTexture(DW.ICON)

    tab:SetScript("OnClick", function()
        PlayClickSound()
        if DW.OpenModule and DW.IsMember() then
            DW.OpenModule("achievements")
        end
    end)
    tab:SetScript("OnEnter", function(self)
        local module = DW.modules.achievements
        if not module then
            return
        end
        GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
        GameTooltip:AddLine("Dragonworld: " .. DW.ModuleTitle(module))
        GameTooltip:AddLine(DW.ModuleNotes(module), 1, 1, 1, true)
        GameTooltip:Show()
    end)
    return tab
end

local function CreateGuildTab(window)
    local tab = CreateSquareTab(window, "DragonworldGuildTab", DW.ACTION_ICON or DW.ICON)

    -- Blinks like the action bar button (the same glow around the square).
    local square = DW.SQUARE_GLOW
    if square and DW.PrepareGlow and DW.AddGlowTarget then
        tab.glow = DW.PrepareGlow(tab:CreateTexture(nil, "OVERLAY", nil, 7), nil, square.texture)
        tab.glow:SetTexCoord(square.coords[1], square.coords[2], square.coords[3], square.coords[4])
        tab.glow:SetSize(32 * square.scale, 32 * square.scale)
        tab.glow:SetPoint("CENTER")
        DW.AddGlowTarget({ glow = tab.glow })
    end

    tab:SetScript("OnClick", function()
        PlayClickSound()
        DW.ClickOpen()
    end)
    tab:SetScript("OnEnter", function(self)
        GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
        GameTooltip:AddLine("Dragonworld")
        GameTooltip:AddLine(L.GUILD_TAB_TIP, 1, 1, 1, true)
        DW.AlertsHovered(GameTooltip)
        GameTooltip:Show()
    end)
    return tab
end

-- Creates the tab when the guild window exists (it is loaded).
local function SetUpGuildTab()
    local window = _G.CommunitiesFrame
    if guildTab or type(window) ~= "table" or type(window.RosterTab) ~= "table" then
        return
    end
    guildTab = CreateGuildTab(window)
    achievementsTab = CreateAchievementsTab(window)
    if type(window.UpdateCommunitiesTabs) == "function" then
        hooksecurefunc(window, "UpdateCommunitiesTabs", UpdateGuildTab)
    end
    window:HookScript("OnShow", UpdateGuildTab)
    UpdateGuildTab()
end

DW.OnMembershipChanged(UpdateGuildTab)

-- Shortcuts under the game's side tabs --------------------------------------------
--
-- Some of the game's windows in Forever have large tabs on the right side, made with
-- the template LargeSideTabButtonTemplate, 2 points apart:
--   * Professions (ProfessionsFrame in Blizzard_Professions): the overview on top
--     (ProfessionsOverviewTab), then one per profession (rightProfessionTabs),
--     shown and hidden by RefreshRightTabs.
--   * Looking For Group (LFGParentFrame in Blizzard_GroupFinder_VanillaStyle):
--     ListingTab, BrowsingTab and WhoListingTab, set by UpdateTabs.
--   * Legacy (LegacySystemFrame in Blizzard_LegacySystem): LegacyRewardTrackTab
--     (Progress Track), LegacyChallengeTab and LegacyTreeTab, always shown.
-- Below the lowest one we add shortcuts to Dragonworld tabs: Professions and
-- Materialer in the Professions window, Dungeons in Looking For Group, Achievements
-- in the Legacy window. They are made
-- with the game's own template, so they look exactly the same, with a small guild shield
-- in the corner so you can see they are Dragonworld's. A click opens Dragonworld on
-- that tab. The Dungeons shortcut blinks when someone in the guild is open to
-- dungeons at your level. The windows are only loaded when they are opened, so the
-- shortcuts are made then.

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
        -- The Materialer tab has the anvil as icon, which is also the icon of
        -- Blacksmithing in the game's tabs. Here it gets ore, so they aren't confused.
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
            -- Blinks when someone in the guild is open to dungeons at your level
            -- (the alert "dungeon" in Dungeons.lua, the same as the minimap button).
            { module = "dungeons", icon = "Interface\\Icons\\Ability_DualWield", alert = "dungeon" },
        },
    },
    {
        -- The Legacy window (Progress Track, Legacy Challenges, Legacy Tree).
        -- Its tabs never hide, and SelectPage runs on every change of page.
        addon = "Blizzard_LegacySystem", frame = "LegacySystemFrame", refresh = "SelectPage",
        gameTabs = function(window)
            return { window.LegacyRewardTrackTab, window.LegacyChallengeTab, window.LegacyTreeTab }
        end,
        shortcuts = {
            { module = "achievements", icon = ACHIEVEMENTS_ICON },
        },
    },
}

-- A shortcut that belongs to an alert glows with the game's own glow for
-- side tabs (TabGlow, which pulses), coloured like the alert, as long as it is new.
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

-- The lowest of the game's tabs that is shown (they are in the list from top to bottom).
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
    -- The icon fills the tab, like the game's own (fillToInterior).
    tab.fillToInterior = true
    if tab.SetChecked then
        tab:SetChecked(false)
    end

    tab.badge = tab:CreateTexture(nil, "OVERLAY", nil, 7)
    tab.badge:SetSize(20, 20)
    tab.badge:SetPoint("BOTTOMLEFT", tab.Icon, "BOTTOMLEFT", -3, -3)
    tab.badge:SetTexture(DW.ICON)

    -- The glow gets the alert's colour (made grey first, so the colour comes out clean).
    if tab.alert and type(tab.TabGlow) == "table" then
        for _, alert in ipairs(DW.ALERTS or {}) do
            if alert.kind == tab.alert and alert.color then
                tab.TabGlow:SetDesaturated(true)
                tab.TabGlow:SetVertexColor(alert.color[1], alert.color[2], alert.color[3])
            end
        end
    end

    -- The tooltip: "Dragonworld: Professions" and what the tab does, in the chosen language,
    -- and for Dungeons who is open now (if it is new).
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

-- Creates the shortcuts in a window when it exists (is loaded), once.
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

-- Other addons can make the minimap square. They are only fully loaded at
-- login, so the button is placed again then. The guild window and the windows with
-- side tabs are loaded when they are first opened (or are already loaded by another addon).
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
