-- Dragonworld - the main window
--
--   +--------------------------------------------------------------+
--   | [logo]  Dragonworld                                      [x] |
--   |--------------------------------------------------------------|
--   | [ Module 1   ]  +------------------------------------------+ |
--   | [ Module 2   ]  |                                          | |
--   |                 |   the content of the selected module     | |
--   |                 |                                          | |
--   | [  Settings  ]  +------------------------------------------+ |
--   +--------------------------------------------------------------+
--
-- Each module that has CreatePanel gets a chip on the left edge, in the order
-- the player chooses under Settings. Settings is a page of its own with
-- language choice, the minimap button, flashing, the action bar button, the
-- version and the order of the tabs. The first time the window is opened, the
-- first-time setup is shown instead of the modules: the language choice, and
-- then flashing and the action bar button.

local ADDON_NAME, DW = ...
local L = DW.L

local WINDOW_NAME = "DragonworldFrame"
local GUILD_NAME = "Dragonworld"

local WIDTH, HEIGHT = 840, 540
local PAD = 14
local HEADER_HEIGHT = 84
local LOGO_SIZE = 88
local SIDEBAR_WIDTH = 190
local CHIP_HEIGHT, CHIP_GAP = 40, 8
local LANGUAGE_CHIP_WIDTH = 80 -- seven languages side by side under Settings

-- The decorative font the game uses in quest titles. If it does not exist,
-- the text keeps the regular font.
local TITLE_FONT = "Fonts\\MORPHEUS.TTF"
local SETTINGS_ICON = "Interface\\Icons\\Trade_Engineering"
local BODY_WIDTH = WIDTH - 2 * PAD
local BODY_HEIGHT = HEIGHT - HEADER_HEIGHT - 8 - PAD
local CONTENT_WIDTH = BODY_WIDTH - SIDEBAR_WIDTH - 10

local SETTINGS = "settings" -- the settings page; not a module

local window
local moduleChips = {} -- chips for the modules, top to bottom
local panels = {}      -- [module id or SETTINGS] = the frame with the content
local selected         -- what is shown now
local pending          -- what to open when the language is chosen

-- Chips -----------------------------------------------------------------------

local CHIP_BACKDROP = {
    bgFile = "Interface\\Buttons\\WHITE8X8",
    edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border",
    edgeSize = 12,
    insets = { left = 3, right = 3, top = 3, bottom = 3 },
}

-- The same frame is used by modules that make their own small boxes (e.g. the date picker).
DW.PANEL_BACKDROP = CHIP_BACKDROP

local function PaintChip(chip)
    if chip.dimmed then
        -- Cannot be selected (e.g. a day that has already passed).
        chip:SetBackdropColor(0.06, 0.06, 0.07, 0.60)
        chip:SetBackdropBorderColor(0.25, 0.25, 0.25, 1)
        chip.label:SetTextColor(0.40, 0.40, 0.40)
    elseif chip.selected then
        chip:SetBackdropColor(0.30, 0.22, 0.05, 0.95)
        chip:SetBackdropBorderColor(1.00, 0.82, 0.00, 1)
        chip.label:SetTextColor(1.00, 0.82, 0.00)
    elseif chip.hovered then
        chip:SetBackdropColor(0.20, 0.20, 0.24, 0.95)
        chip:SetBackdropBorderColor(0.80, 0.80, 0.80, 1)
        chip.label:SetTextColor(1.00, 1.00, 1.00)
    else
        chip:SetBackdropColor(0.10, 0.10, 0.12, 0.90)
        chip:SetBackdropBorderColor(0.45, 0.45, 0.45, 1)
        chip.label:SetTextColor(0.90, 0.90, 0.90)
    end
end

-- A chip is a rounded button with text, and optionally an icon on the left.
-- The selected one gets a gold border. Modules can use the same for their own choices.
function DW.CreateChip(parent, width, height, icon)
    local chip = CreateFrame("Button", nil, parent, "BackdropTemplate")
    chip:SetSize(width, height)
    chip:SetBackdrop(CHIP_BACKDROP)

    chip.label = chip:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
    if icon then
        chip.icon = chip:CreateTexture(nil, "ARTWORK")
        chip.icon:SetSize(height - 14, height - 14)
        chip.icon:SetPoint("LEFT", 8, 0)
        chip.icon:SetTexture(icon)
        chip.icon:SetTexCoord(0.07, 0.93, 0.07, 0.93)
        chip.label:SetPoint("LEFT", chip.icon, "RIGHT", 8, 0)
    else
        chip.label:SetPoint("LEFT", 12, 0)
    end
    chip.label:SetPoint("RIGHT", -12, 0)
    chip.label:SetJustifyH("LEFT")
    chip.label:SetWordWrap(false)

    chip:SetScript("OnEnter", function(self)
        self.hovered = true
        PaintChip(self)
    end)
    chip:SetScript("OnLeave", function(self)
        self.hovered = false
        PaintChip(self)
    end)

    function chip:SetSelected(isSelected)
        self.selected = isSelected and true or false
        PaintChip(self)
    end

    -- Greys the chip out. Used together with SetEnabled(false) for choices that
    -- are not available.
    function chip:SetDimmed(isDimmed)
        self.dimmed = isDimmed and true or false
        PaintChip(self)
    end

    PaintChip(chip)
    return chip
end

-- Buttons ---------------------------------------------------------------------

-- Colors for buttons that do something: red for "Discard", gold for the main action.
local BUTTON_STYLES = {
    red = {
        normal = { 0.45, 0.06, 0.06 }, hover = { 0.65, 0.10, 0.10 },
        border = { 0.85, 0.30, 0.25 }, text = { 1.00, 0.90, 0.85 },
    },
    gold = {
        normal = { 0.55, 0.40, 0.06 }, hover = { 0.75, 0.56, 0.10 },
        border = { 1.00, 0.82, 0.00 }, text = { 1.00, 1.00, 1.00 },
    },
}

local function PaintButton(button)
    local style = BUTTON_STYLES[button.style]
    if not button:IsEnabled() then
        button:SetBackdropColor(0.15, 0.15, 0.15, 0.90)
        button:SetBackdropBorderColor(0.35, 0.35, 0.35, 1)
        button.label:SetTextColor(0.50, 0.50, 0.50)
        return
    end
    local fill = button.hovered and style.hover or style.normal
    button:SetBackdropColor(fill[1], fill[2], fill[3], 0.95)
    button:SetBackdropBorderColor(style.border[1], style.border[2], style.border[3], 1)
    button.label:SetTextColor(style.text[1], style.text[2], style.text[3])
end

-- A colored button in the same style as the chips. style is "red" or "gold".
-- Use button:SetActive(false) to grey it out.
function DW.CreateButton(parent, width, height, style)
    local button = CreateFrame("Button", nil, parent, "BackdropTemplate")
    button:SetSize(width, height)
    button:SetBackdrop(CHIP_BACKDROP)
    button.style = style

    button.label = button:CreateFontString(nil, "OVERLAY", height >= 28 and "GameFontNormal" or "GameFontNormalSmall")
    button.label:SetPoint("LEFT", 6, 0)
    button.label:SetPoint("RIGHT", -6, 0)
    button.label:SetJustifyH("CENTER")
    button.label:SetWordWrap(false)

    button:HookScript("OnEnter", function(self)
        self.hovered = true
        PaintButton(self)
    end)
    button:HookScript("OnLeave", function(self)
        self.hovered = false
        PaintButton(self)
    end)

    function button:SetActive(active)
        self:SetEnabled(active and true or false)
        PaintButton(self)
    end

    -- For a button that lies over this one and takes the mouse (the secure
    -- "Reload now" button in Update.lua): light this one up as if hovered.
    function button:SetHovered(hovered)
        self.hovered = hovered and true or false
        PaintButton(self)
    end

    PaintButton(button)
    return button
end

-- Role choice -----------------------------------------------------------------

-- Three chips side by side: Tank, Healer, DPS, with the game's role icons. You
-- choose one or two; with two chosen, the third is grey until you remove one.
-- onChange(roles) is called after each click with { T = true, ... }.
-- Used in the first-time setup (below) and on your own member card.
function DW.CreateRoleChoice(parent, chipWidth, chipHeight, iconSize, onChange)
    local box = CreateFrame("Frame", nil, parent)
    local gap = 6
    box:SetSize(#DW.ROLES * chipWidth + (#DW.ROLES - 1) * gap, chipHeight)
    box.roles = {}
    box.chips = {}

    function box:Refresh()
        local count = 0
        for _ in pairs(self.roles) do
            count = count + 1
        end
        for _, chip in ipairs(self.chips) do
            local chosen = self.roles[chip.role.code] and true or false
            local open = chosen or count < DW.MAX_ROLES
            chip.label:SetText(DW.RoleIcon(chip.role, iconSize) .. " " .. L[chip.role.key])
            chip:SetSelected(chosen)
            chip:SetEnabled(open)
            chip:SetDimmed(not open)
        end
    end

    function box:SetRoles(set)
        self.roles = {}
        for code in pairs(DW.RolesFromText(DW.RolesToText(set))) do
            self.roles[code] = true
        end
        self:Refresh()
    end

    function box:GetRoles()
        local copy = {}
        for code in pairs(self.roles) do
            copy[code] = true
        end
        return copy
    end

    for index, role in ipairs(DW.ROLES) do
        local chip = DW.CreateChip(box, chipWidth, chipHeight)
        chip:SetPoint("LEFT", (index - 1) * (chipWidth + gap), 0)
        chip.label:SetJustifyH("CENTER")
        chip.role = role
        chip:SetScript("OnClick", function(self)
            if box.roles[role.code] then
                box.roles[role.code] = nil
            else
                local count = 0
                for _ in pairs(box.roles) do
                    count = count + 1
                end
                if count >= DW.MAX_ROLES then
                    return
                end
                box.roles[role.code] = true
            end
            box:Refresh()
            if onChange then
                onChange(box:GetRoles())
            end
        end)
        box.chips[index] = chip
    end

    box:Refresh()
    return box
end

-- The order of the tabs ---------------------------------------------------------

-- The player chooses the order of the module tabs under Settings. It is
-- saved in DragonworldDB.tabOrder (shared by all characters on the account).

-- The order before the player has chosen (chosen by the guild leader).
local DEFAULT_TAB_ORDER = {
    "roster", "guildchat", "dungeons", "guildbank", "events", "achievements", "professions", "materialer", "ryddesekk", "keybinds", "forslag",
}

-- The modules that have a tab, in the chosen order (or the default order).
-- A module that is missing from the player's saved order (e.g. because it is
-- new) gets its place from the default order: right after the one that comes
-- before it there. Modules that are not in the default order come last.
local function OrderedModuleIDs()
    local list, used = {}, {}
    local saved = type(DragonworldDB) == "table" and DragonworldDB.tabOrder
    if type(saved) ~= "table" then
        saved = DEFAULT_TAB_ORDER
    end
    for _, id in ipairs(saved) do
        local module = type(id) == "string" and DW.modules[id]
        if module and module.CreatePanel and not used[id] then
            list[#list + 1] = id
            used[id] = true
        end
    end
    for index, id in ipairs(DEFAULT_TAB_ORDER) do
        local module = DW.modules[id]
        if module and module.CreatePanel and not used[id] then
            -- After the nearest one before it in the default order that is included.
            local at = 1
            for back = index - 1, 1, -1 do
                local before = DEFAULT_TAB_ORDER[back]
                if used[before] then
                    for position, listed in ipairs(list) do
                        if listed == before then
                            at = position + 1
                        end
                    end
                    break
                end
            end
            table.insert(list, at, id)
            used[id] = true
        end
    end
    for _, module in ipairs(DW.moduleOrder) do
        if module.CreatePanel and not used[module.id] then
            list[#list + 1] = module.id
            used[module.id] = true
        end
    end
    return list
end

-- Lays out the tabs on the left edge in the chosen order. If there are too many
-- to fit above Settings, they move a little closer together.
local function LayoutChips()
    local position = {}
    for index, id in ipairs(OrderedModuleIDs()) do
        position[id] = index
    end
    table.sort(moduleChips, function(a, b)
        return (position[a.id] or 999) < (position[b.id] or 999)
    end)
    local room = BODY_HEIGHT - CHIP_HEIGHT - CHIP_GAP
    local step = math.min(CHIP_HEIGHT + CHIP_GAP, math.floor(room / math.max(1, #moduleChips)))
    local height = math.min(CHIP_HEIGHT, step - 2)
    for index, chip in ipairs(moduleChips) do
        chip:ClearAllPoints()
        chip:SetPoint("TOPLEFT", 0, -(index - 1) * step)
        chip:SetHeight(height)
    end
end

-- Moves a module one step up (step = -1) or down (step = 1) and remembers it.
-- Returns true if it was moved.
function DW.MoveModule(id, step)
    local list = OrderedModuleIDs()
    for index, current in ipairs(list) do
        if current == id then
            local other = index + step
            if other < 1 or other > #list then
                return false
            end
            list[index], list[other] = list[other], list[index]
            if type(DragonworldDB) == "table" then
                DragonworldDB.tabOrder = list
            end
            LayoutChips()
            if panels[SETTINGS] then
                panels[SETTINGS]:Refresh()
            end
            return true
        end
    end
    return false
end

-- A small arrow button (up or down) with the game's own arrow images.
local function CreateArrowButton(parent, direction)
    local button = CreateFrame("Button", nil, parent)
    button:SetSize(22, 22)
    local base = "Interface\\Buttons\\UI-ScrollBar-Scroll" .. direction .. "Button-"
    button:SetNormalTexture(base .. "Up")
    button:SetPushedTexture(base .. "Down")
    button:SetDisabledTexture(base .. "Disabled")
    button:SetHighlightTexture(base .. "Highlight", "ADD")
    return button
end

-- Settings has two columns under the language choice: buttons, flashing and
-- version on the left, the order of the tabs on the right.
local RIGHT_COLUMN, RIGHT_WIDTH = 330, 266
local ORDER_TOP, ORDER_ROW = -136, 24

-- One line in the list of tabs: icon, name, and arrow up and down.
local function GetOrderRow(panel, index)
    local row = panel.orderRows[index]
    if row then
        return row
    end
    row = CreateFrame("Frame", nil, panel)
    row:SetSize(RIGHT_WIDTH, ORDER_ROW - 2)
    row:SetPoint("TOPLEFT", RIGHT_COLUMN, ORDER_TOP - (index - 1) * ORDER_ROW)

    row.icon = row:CreateTexture(nil, "ARTWORK")
    row.icon:SetSize(20, 20)
    row.icon:SetPoint("LEFT", 0, 0)
    row.icon:SetTexCoord(0.07, 0.93, 0.07, 0.93)

    row.down = CreateArrowButton(row, "Down")
    row.down:SetPoint("RIGHT", 0, 0)
    row.down:SetScript("OnClick", function()
        DW.MoveModule(row.id, 1)
    end)
    row.up = CreateArrowButton(row, "Up")
    row.up:SetPoint("RIGHT", row.down, "LEFT", -4, 0)
    row.up:SetScript("OnClick", function()
        DW.MoveModule(row.id, -1)
    end)

    row.name = row:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
    row.name:SetPoint("LEFT", row.icon, "RIGHT", 8, 0)
    row.name:SetPoint("RIGHT", row.up, "LEFT", -8, 0)
    row.name:SetJustifyH("LEFT")
    row.name:SetWordWrap(false)

    panel.orderRows[index] = row
    return row
end

-- Settings ----------------------------------------------------------------------

-- A checkbox with text on the right.
local function CreateCheck(parent, x, y, onClick)
    local check = CreateFrame("CheckButton", nil, parent, "UICheckButtonTemplate")
    check:SetSize(24, 24)
    check:SetPoint("TOPLEFT", x, y)
    check:SetScript("OnClick", onClick)
    check.label = parent:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
    check.label:SetPoint("LEFT", check, "RIGHT", 4, 0)
    check.label:SetJustifyH("LEFT")
    return check
end

-- The flashing choices (Alerts.lua): one box for everything, and with withKinds
-- one box per thing it can flash for, with the color as a small square. Used
-- both under Settings and in the first-time setup.
local KIND_ROW = 22 -- the distance between the choices for what it flashes for

local function CreateBlinkChoices(parent, x, y, withKinds)
    local group = { kinds = {} }

    group.main = CreateCheck(parent, x, y, function(self)
        DW.SetBlinkOn(self:GetChecked() and true or false)
        group:Refresh()
    end)

    if withKinds then
        for index, alert in ipairs(DW.ALERTS) do
            local check = CreateCheck(parent, x + 20, y - index * KIND_ROW, function(self)
                DW.SetAlertOn(self.alert.kind, self:GetChecked() and true or false)
            end)
            check.alert = alert
            local color = alert.color or { 1, 1, 1 }
            check.swatch = parent:CreateTexture(nil, "ARTWORK")
            check.swatch:SetSize(10, 10)
            check.swatch:SetPoint("LEFT", check, "RIGHT", 4, 0)
            check.swatch:SetColorTexture(color[1], color[2], color[3], 1)
            check.label:ClearAllPoints()
            check.label:SetPoint("LEFT", check.swatch, "RIGHT", 6, 0)
            group.kinds[index] = check
        end
    end

    function group:Refresh()
        local on = DW.IsBlinkOn()
        self.main:SetChecked(on)
        self.main.label:SetText(L.BLINK_ON)
        for _, check in ipairs(self.kinds) do
            check:SetChecked(DW.IsAlertOn(check.alert.kind))
            check:SetEnabled(on)
            check.label:SetText(L[check.alert.labelKey or check.alert.kind])
            if on then
                check.label:SetTextColor(1.00, 1.00, 1.00)
            else
                check.label:SetTextColor(0.50, 0.50, 0.50)
            end
        end
    end

    return group
end

-- A text field with the download link, so it can be copied with Ctrl+C.
local function CreateLinkBox(parent, width)
    local box = CreateFrame("EditBox", nil, parent, "InputBoxTemplate")
    box:SetSize(width, 22)
    box:SetAutoFocus(false)
    local function Select(self)
        self:SetText(DW.DOWNLOAD_URL or "")
        self:HighlightText()
    end
    box:SetScript("OnEditFocusGained", Select)
    box:SetScript("OnTextChanged", function(self, userInput)
        if userInput then
            Select(self) -- the text must not be editable
        end
    end)
    box:SetScript("OnEscapePressed", function(self)
        self:ClearFocus()
    end)
    return box
end

local function CreateSettingsPanel(parent)
    local panel = CreateFrame("Frame", nil, parent)
    panel:SetAllPoints(parent)

    panel.languageLabel = panel:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    panel.languageLabel:SetPoint("TOPLEFT", 16, -16)

    -- The intro and the choices from the first-time setup, once more.
    panel.introButton = DW.CreateChip(panel, 140, 24)
    panel.introButton:SetPoint("TOPRIGHT", -14, -10)
    panel.introButton.label:SetJustifyH("CENTER")
    panel.introButton:SetScript("OnClick", function()
        DW.ShowIntro()
    end)

    -- All the languages in one row: narrow chips, with less space around the name.
    panel.languageChips = {}
    for index, language in ipairs(DW.LANGUAGES) do
        local chip = DW.CreateChip(panel, LANGUAGE_CHIP_WIDTH, CHIP_HEIGHT)
        chip:SetPoint("TOPLEFT", 16 + (index - 1) * (LANGUAGE_CHIP_WIDTH + 4), -40)
        chip.label:ClearAllPoints()
        chip.label:SetPoint("LEFT", 4, 0)
        chip.label:SetPoint("RIGHT", -4, 0)
        chip.label:SetJustifyH("CENTER")
        chip.label:SetText(language.name)
        chip.code = language.code
        chip:SetScript("OnClick", function(self)
            DW.SetLanguage(self.code, true)
        end)
        panel.languageChips[index] = chip
    end

    -- Left column: the minimap button and the flashing.
    panel.minimapCheck = CreateCheck(panel, 14, -96, function(self)
        if DW.SetMinimapButtonShown then
            DW.SetMinimapButtonShown(self:GetChecked() and true or false)
        end
    end)
    panel.minimapLabel = panel.minimapCheck.label

    panel.blink = CreateBlinkChoices(panel, 14, -122, true)
    local y = -122 - #panel.blink.kinds * KIND_ROW - 32

    -- The action bar button.
    panel.actionLabel = panel:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    panel.actionLabel:SetPoint("TOPLEFT", 16, y)
    panel.actionSource = DW.CreateActionButtonSource(panel, 32)
    panel.actionSource:SetPoint("TOPLEFT", 16, y - 18)
    panel.actionHint = panel:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    panel.actionHint:SetPoint("TOPLEFT", panel.actionSource, "TOPRIGHT", 10, -2)
    panel.actionHint:SetWidth(250)
    panel.actionHint:SetJustifyH("LEFT")
    y = y - 18 - 32 - 14

    -- The version, and whether a newer one exists (Update.lua).
    panel.versionLabel = panel:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    panel.versionLabel:SetPoint("TOPLEFT", 16, y)
    panel.versionText = panel:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
    panel.versionText:SetPoint("TOPLEFT", 16, y - 18)
    panel.versionStatus = panel:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    panel.versionStatus:SetPoint("TOPLEFT", 16, y - 34)
    panel.link = CreateLinkBox(panel, 270)
    panel.link:SetPoint("TOPLEFT", 22, y - 50)
    panel.linkHint = panel:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
    panel.linkHint:SetPoint("TOPLEFT", 16, y - 76)
    panel.autoText = panel:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    panel.autoText:SetPoint("TOPLEFT", 16, y - 92)
    panel.autoText:SetWidth(290)
    panel.autoText:SetJustifyH("LEFT")

    -- Right column: the order of the tabs on the left edge.
    panel.orderLabel = panel:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    panel.orderLabel:SetPoint("TOPLEFT", RIGHT_COLUMN, -96)
    panel.orderLabel:SetWidth(RIGHT_WIDTH)
    panel.orderLabel:SetJustifyH("LEFT")
    panel.orderRows = {}

    -- Writes the text in the chosen language and shows the current choices.
    function panel:Refresh()
        self.languageLabel:SetText(L.LANGUAGE)
        self.introButton.label:SetText(L.SHOW_INTRO)
        self.minimapLabel:SetText(L.SHOW_MINIMAP_BUTTON)
        for _, chip in ipairs(self.languageChips) do
            chip:SetSelected(chip.code == DW.GetLanguage())
        end
        self.minimapCheck:SetChecked(DW.IsMinimapButtonShown and DW.IsMinimapButtonShown() or false)
        self.blink:Refresh()

        self.actionLabel:SetText(L.AB_LABEL)
        self.actionHint:SetText(L.AB_HINT)

        self.versionLabel:SetText(L.UP_LABEL)
        self.versionText:SetText(L.UP_YOURS:format(DW.RELEASE or "?"))
        if DW.IsOutdated() then
            local text = L.UP_OUTDATED
            if DW.IsAutoUpdate() then
                text = DW.UpdateNeedsRestart() and L.UP_OUTDATED_RESTART or L.UP_OUTDATED_RELOAD
            end
            self.versionStatus:SetText(text:format(DW.NewestVersion()))
            self.versionStatus:SetTextColor(1.00, 0.35, 0.30)
        else
            self.versionStatus:SetText(L.UP_IS_NEWEST)
            self.versionStatus:SetTextColor(0.40, 0.90, 0.40)
        end
        self.link:SetText(DW.DOWNLOAD_URL or "")
        self.linkHint:SetText(L.UP_LINK_HINT)
        self.autoText:SetText(DW.IsAutoUpdate() and L.UP_AUTO_ON or L.UP_AUTO_OFF)

        self.orderLabel:SetText(L.TAB_ORDER)
        local ids = OrderedModuleIDs()
        for index, id in ipairs(ids) do
            local row = GetOrderRow(self, index)
            local module = DW.modules[id]
            row.id = id
            row.icon:SetTexture(module.icon or DW.ICON)
            row.name:SetText(DW.ModuleTitle(module))
            row.up:SetEnabled(index > 1)
            row.down:SetEnabled(index < #ids)
            row:Show()
        end
        for index = #ids + 1, #self.orderRows do
            self.orderRows[index]:Hide()
        end
    end

    panel:SetScript("OnShow", function(self)
        self:Refresh()
    end)
    return panel
end

-- If the addon hears about a newer version while Settings is open, it is shown.
DW.OnNewerVersion(function()
    if panels[SETTINGS] and panels[SETTINGS]:IsShown() then
        panels[SETTINGS]:Refresh()
    end
end)

-- Page selection ----------------------------------------------------------------

local function FirstModuleID()
    return moduleChips[1] and moduleChips[1].id or SETTINGS
end

local function Select(id)
    local module = DW.modules[id]
    if id ~= SETTINGS and not (module and module.CreatePanel) then
        id = FirstModuleID()
        module = DW.modules[id]
    end
    selected = id

    for _, chip in ipairs(moduleChips) do
        chip:SetSelected(chip.id == id)
    end
    window.settingsChip:SetSelected(id == SETTINGS)

    for panelID, panel in pairs(panels) do
        if panelID ~= id then
            panel:Hide()
        end
    end

    local panel = panels[id]
    if not panel then
        if id == SETTINGS then
            panel = CreateSettingsPanel(window.content)
        else
            local ok, result = pcall(module.CreatePanel, module, window.content)
            if not ok or type(result) ~= "table" then
                DW.PrintError(L.ERROR_IN:format(DW.ModuleTitle(module)), result)
                return
            end
            panel = result
        end
        -- Hide first, so OnShow always runs when it is shown below.
        panel:Hide()
        panels[id] = panel
    end
    panel:Show()

    -- What was flashing for this tab has now been seen (Alerts.lua).
    if DW.RefreshAlerts then
        DW.RefreshAlerts()
    end
end

-- Language choice the first time --------------------------------------------------

local ShowWindow

local function CreateLanguagePrompt(parent)
    local prompt = CreateFrame("Frame", nil, parent)
    prompt:SetPoint("TOPLEFT", PAD, -(HEADER_HEIGHT + 8))
    prompt:SetSize(BODY_WIDTH, BODY_HEIGHT)

    -- The same sentence in every language, since we do not know which they know.
    local count = #DW.LANGUAGES
    for index, language in ipairs(DW.LANGUAGES) do
        local line = prompt:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
        line:SetPoint("TOP", 0, -36 - (index - 1) * 22)
        line:SetText(DW.strings[language.code].PROMPT)
    end

    -- The choices under them, at most four in a row, each row centred.
    local perRow = 4
    local top = -36 - count * 22 - 24
    prompt.chips = {}
    for index, language in ipairs(DW.LANGUAGES) do
        local row = math.floor((index - 1) / perRow)
        local inRow = math.min(perRow, count - row * perRow)
        local column = (index - 1) % perRow
        local chip = DW.CreateChip(prompt, 180, 40)
        chip:SetPoint("TOP", (column - (inRow - 1) / 2) * 196, top - row * 50)
        chip.label:SetJustifyH("CENTER")
        chip.label:SetText(language.name)
        chip.code = language.code
        chip:SetScript("OnClick", function(self)
            DW.SetLanguage(self.code, true)
            local open = pending
            pending = nil
            ShowWindow(open)
        end)
        prompt.chips[index] = chip
    end

    return prompt
end

-- First-time setup, steps 2 and 3 -------------------------------------------------

-- After the language choice: an intro (what the addon can do, and what you
-- should open in the game so the views get filled), and then the choices for
-- what the buttons should flash for and the action bar button. Shown once per
-- account. SETUP_VERSION is raised when the setup gets something new everyone
-- should see; then everyone gets it once more. "Show the intro"
-- under Settings shows it again. Everything can be changed later.
local SETUP_VERSION = 2
local setupStep          -- "intro" or "options" while the setup is shown
local forceSetup = false -- "Vis introen" has been pressed

local function IsSetupDone()
    if forceSetup then
        return false
    end
    return type(DragonworldDB) == "table" and (tonumber(DragonworldDB.setupVersion) or 0) >= SETUP_VERSION
end

local function FinishSetup()
    if type(DragonworldDB) == "table" then
        DragonworldDB.setupDone = true -- older versions of the addon look for this
        DragonworldDB.setupVersion = SETUP_VERSION
    end
    forceSetup = false
    setupStep = nil
    local open = pending
    pending = nil
    ShowWindow(open)
end

local INTRO_TIPS = { "INTRO_TIP_BANK", "INTRO_TIP_PROFESSIONS", "INTRO_TIP_GUILDBANK", "INTRO_TIP_STATUS", "INTRO_TIP_BUTTON" }
local INTRO_ROW = 26

-- The intro: the tabs on the left (icon, name and what they do, in tab order),
-- "Getting started" on the right.
local function CreateIntroPrompt(parent)
    local prompt = CreateFrame("Frame", nil, parent)
    prompt:SetPoint("TOPLEFT", PAD, -(HEADER_HEIGHT + 8))
    prompt:SetSize(BODY_WIDTH, BODY_HEIGHT)

    prompt.title = prompt:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
    prompt.title:SetPoint("TOP", 0, -12)

    prompt.canHeading = prompt:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    prompt.canHeading:SetPoint("TOPLEFT", 20, -42)
    prompt.rows = {}

    prompt.startHeading = prompt:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    prompt.startHeading:SetPoint("TOPLEFT", 450, -42)
    prompt.tips = {}
    for index in ipairs(INTRO_TIPS) do
        local tip = prompt:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
        if index == 1 then
            tip:SetPoint("TOPLEFT", 450, -66)
        else
            tip:SetPoint("TOPLEFT", prompt.tips[index - 1], "BOTTOMLEFT", 0, -10)
        end
        tip:SetWidth(340)
        tip:SetJustifyH("LEFT")
        prompt.tips[index] = tip
    end

    prompt.next = DW.CreateButton(prompt, 200, 34, "gold")
    prompt.next:SetPoint("BOTTOM", 0, 16)
    prompt.next:SetScript("OnClick", function()
        setupStep = "options"
        ShowWindow()
    end)

    function prompt:Refresh()
        self.title:SetText(L.INTRO_TITLE)
        self.canHeading:SetText(L.INTRO_CAN)
        self.startHeading:SetText(L.INTRO_START)
        for index, key in ipairs(INTRO_TIPS) do
            self.tips[index]:SetText("- " .. L[key])
        end
        self.next.label:SetText(L.INTRO_NEXT)

        local ids = OrderedModuleIDs()
        for index, id in ipairs(ids) do
            local row = self.rows[index]
            if not row then
                row = {}
                row.icon = self:CreateTexture(nil, "ARTWORK")
                row.icon:SetSize(20, 20)
                row.icon:SetPoint("TOPLEFT", 20, -64 - (index - 1) * INTRO_ROW)
                row.icon:SetTexCoord(0.07, 0.93, 0.07, 0.93)
                row.text = self:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
                row.text:SetPoint("TOPLEFT", row.icon, "TOPRIGHT", 8, 0)
                row.text:SetWidth(380)
                row.text:SetJustifyH("LEFT")
                self.rows[index] = row
            end
            local module = DW.modules[id]
            row.icon:SetTexture(module.icon or DW.ICON)
            row.text:SetText(("|cffffd100%s|r  %s"):format(DW.ModuleTitle(module), DW.ModuleNotes(module)))
            row.icon:Show()
            row.text:Show()
        end
        for index = #ids + 1, #self.rows do
            self.rows[index].icon:Hide()
            self.rows[index].text:Hide()
        end
    end

    return prompt
end

-- The choices: flashing (with what it flashes for) and the action bar button.
local function CreateSetupPrompt(parent)
    local prompt = CreateFrame("Frame", nil, parent)
    prompt:SetPoint("TOPLEFT", PAD, -(HEADER_HEIGHT + 8))
    prompt:SetSize(BODY_WIDTH, BODY_HEIGHT)

    local LEFT = 190 -- the choices sit in a block a bit in from the left

    prompt.title = prompt:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
    prompt.title:SetPoint("TOP", 0, -24)

    prompt.text = prompt:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
    prompt.text:SetPoint("TOP", 0, -54)
    prompt.text:SetWidth(560)

    prompt.blink = CreateBlinkChoices(prompt, LEFT, -96, true)
    local y = -96 - #prompt.blink.kinds * KIND_ROW - 30
    prompt.blinkHint = prompt:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    prompt.blinkHint:SetPoint("TOPLEFT", LEFT + 4, y)
    prompt.blinkHint:SetWidth(440)
    prompt.blinkHint:SetJustifyH("LEFT")
    prompt.blinkHint:SetTextColor(0.75, 0.75, 0.75)

    prompt.actionSource = DW.CreateActionButtonSource(prompt, 40)
    prompt.actionSource:SetPoint("TOPLEFT", LEFT, y - 48)
    prompt.actionText = prompt:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
    prompt.actionText:SetPoint("TOPLEFT", prompt.actionSource, "TOPRIGHT", 12, -2)
    prompt.actionText:SetWidth(400)
    prompt.actionText:SetJustifyH("LEFT")

    prompt.done = DW.CreateButton(prompt, 200, 34, "gold")
    prompt.done:SetPoint("BOTTOM", 0, 24)
    prompt.done:SetScript("OnClick", FinishSetup)

    function prompt:Refresh()
        self.title:SetText(L.SETUP_TITLE)
        self.text:SetText(L.SETUP_TEXT)
        self.blink:Refresh()
        self.blinkHint:SetText(L.BLINK_HINT)
        self.actionText:SetText(L.AB_SETUP)
        self.done.label:SetText(L.SETUP_DONE)
    end

    return prompt
end

-- The role, the first time on each character -----------------------------------

-- After the setup above (which is shared by the account), each character is
-- asked once which role it plays: tank, healer, dps, or two of them. It is
-- shown with an icon in the Roster tab, and can be changed on your own card.
-- "Later" skips it, and does not ask again. The role itself is saved in
-- Profile.lua.
local function CreateRolePrompt(parent)
    local prompt = CreateFrame("Frame", nil, parent)
    prompt:SetPoint("TOPLEFT", PAD, -(HEADER_HEIGHT + 8))
    prompt:SetSize(BODY_WIDTH, BODY_HEIGHT)

    prompt.title = prompt:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
    prompt.title:SetPoint("TOP", 0, -40)

    prompt.text = prompt:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
    prompt.text:SetPoint("TOP", 0, -76)
    prompt.text:SetWidth(560)

    local function Changed(roles)
        prompt.save:SetActive(next(roles) ~= nil)
    end
    prompt.choice = DW.CreateRoleChoice(prompt, 170, 48, 24, Changed)
    prompt.choice:SetPoint("TOP", 0, -170)

    prompt.save = DW.CreateButton(prompt, 200, 34, "gold")
    prompt.save:SetPoint("BOTTOM", -106, 40)
    prompt.save:SetScript("OnClick", function()
        local roles = prompt.choice:GetRoles()
        if next(roles) then
            DW.SetMyRoles(roles)
            ShowWindow()
        end
    end)

    prompt.later = DW.CreateChip(prompt, 200, 34)
    prompt.later:SetPoint("BOTTOM", 106, 40)
    prompt.later.label:SetJustifyH("CENTER")
    prompt.later:SetScript("OnClick", function()
        DW.SkipRoleChoice()
        ShowWindow()
    end)

    -- Starts with the role you may already have chosen for dungeons.
    function prompt:Load()
        local _, entry = DW.GetMyStatus()
        self.choice:SetRoles(entry and entry.roles or {})
        Changed(self.choice:GetRoles())
    end

    function prompt:Refresh()
        local _, name = DW.CharacterKey()
        self.title:SetText(L.ROLE_TITLE)
        self.text:SetText(L.ROLE_TEXT:format(name or ""))
        self.choice:Refresh()
        self.save.label:SetText(L.ROLE_SAVE)
        self.later.label:SetText(L.ROLE_LATER)
    end

    -- Hidden until it is to be shown, so the choices load the first time it is shown.
    prompt:Hide()
    return prompt
end

-- Status at the top right -----------------------------------------------------------

-- Three buttons ("pills") where the player shows what they are up to: questing,
-- open for dungeons, or crafter / do not disturb. Only one can be on. A click
-- on the one that is on turns it off. "Dungeon" first opens a window where you
-- choose which dungeons (Modules\Dungeons.lua). The status itself and the
-- sharing are in Status.lua.
local PILL_WIDTH, PILL_HEIGHT, PILL_GAP = 134, 26, 6 -- wide enough for "Do not disturb"

local function RefreshStatusPills()
    if not window or not window.statusPills then
        return
    end
    local current = DW.GetMyStatus()
    for _, pill in ipairs(window.statusPills) do
        pill.label:SetText(L[pill.status.key])
        pill:SetSelected(pill.status.code == current)
    end
end

local function CreateStatusPills(f)
    f.statusPills = {}
    local count = #DW.STATUSES
    for index, status in ipairs(DW.STATUSES) do
        local pill = DW.CreateChip(f, PILL_WIDTH, PILL_HEIGHT, status.icon)
        pill.icon:SetSize(16, 16) -- a bit larger than in other chips, so the icon is visible
        pill:SetPoint("TOPRIGHT", -46 - (count - index) * (PILL_WIDTH + PILL_GAP), -30)
        pill.status = status
        pill:SetScript("OnClick", function(self)
            GameTooltip:Hide()
            if self.status.code == "D" and DW.OpenDungeonPicker then
                DW.OpenDungeonPicker()
            elseif DW.GetMyStatus() == self.status.code then
                DW.SetMyStatus(nil)
            else
                DW.SetMyStatus(self.status.code)
            end
        end)
        pill:HookScript("OnEnter", function(self)
            GameTooltip:SetOwner(self, "ANCHOR_BOTTOM")
            GameTooltip:AddLine(L[self.status.key])
            GameTooltip:AddLine(L[self.status.tip], 1, 1, 1, true)
            GameTooltip:Show()
        end)
        pill:HookScript("OnLeave", function()
            GameTooltip:Hide()
        end)
        f.statusPills[index] = pill
    end
end

DW.OnStatusChanged(RefreshStatusPills)

-- The window ------------------------------------------------------------------

local function CreateWindow()
    local f = CreateFrame("Frame", WINDOW_NAME, UIParent, "BackdropTemplate")
    f:SetSize(WIDTH, HEIGHT)
    f:SetFrameStrata("HIGH")
    -- An almost fully opaque background, so text from other addons behind the
    -- window does not shine through and mix with the content.
    f:SetBackdrop({
        bgFile = "Interface\\Buttons\\WHITE8X8",
        edgeFile = "Interface\\DialogFrame\\UI-DialogBox-Border",
        edgeSize = 16,
        insets = { left = 4, right = 4, top = 4, bottom = 4 },
    })
    f:SetBackdropColor(0.04, 0.04, 0.06, 0.95)
    f:SetBackdropBorderColor(0.90, 0.72, 0.30, 1) -- gold tone on the border
    f:Hide()

    -- Remember where the window was moved to.
    local saved = type(DragonworldDB) == "table" and DragonworldDB.window
    if type(saved) == "table" and type(saved.point) == "string" then
        f:SetPoint(saved.point, UIParent, saved.relativePoint or saved.point, saved.x or 0, saved.y or 0)
    else
        f:SetPoint("CENTER")
    end
    f:SetMovable(true)
    f:SetClampedToScreen(true)
    f:EnableMouse(true)
    f:RegisterForDrag("LeftButton")
    f:SetScript("OnDragStart", function(self)
        self:StartMoving()
    end)
    f:SetScript("OnDragStop", function(self)
        self:StopMovingOrSizing()
        local point, _, relativePoint, x, y = self:GetPoint(1)
        if point and type(DragonworldDB) == "table" then
            DragonworldDB.window = { point = point, relativePoint = relativePoint, x = x, y = y }
        end
    end)

    -- Escape closes the window.
    table.insert(UISpecialFrames, WINDOW_NAME)

    -- Top: the shield at the top left, so large that it sticks out a little
    -- past the corner, with the guild name in capital letters next to it.
    f.logo = f:CreateTexture(nil, "OVERLAY")
    f.logo:SetSize(LOGO_SIZE, LOGO_SIZE)
    f.logo:SetPoint("TOPLEFT", 8, 18)
    f.logo:SetTexture(DW.ICON)

    f.title = f:CreateFontString(nil, "OVERLAY", "GameFontNormalHuge")
    f.title:SetPoint("TOPLEFT", f.logo, "TOPRIGHT", 12, -30)
    pcall(f.title.SetFont, f.title, TITLE_FONT, 32, "")
    f.title:SetText(GUILD_NAME:upper())

    f.subtitle = f:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
    f.subtitle:SetPoint("TOPLEFT", f.title, "BOTTOMLEFT", 2, -2)
    pcall(f.subtitle.SetFont, f.subtitle, TITLE_FONT, 16, "")
    f.subtitle:SetTextColor(0.85, 0.70, 0.35)

    local close = CreateFrame("Button", nil, f, "UIPanelCloseButton")
    close:SetPoint("TOPRIGHT", -2, -2)

    -- The status buttons at the top right, in line with the guild name.
    CreateStatusPills(f)

    local line = f:CreateTexture(nil, "ARTWORK")
    line:SetColorTexture(1.00, 0.82, 0.00, 0.35)
    line:SetHeight(1)
    line:SetPoint("TOPLEFT", PAD, -HEADER_HEIGHT)
    line:SetPoint("TOPRIGHT", -PAD, -HEADER_HEIGHT)

    -- Everything below the top: chips on the left, content on the right.
    f.body = CreateFrame("Frame", nil, f)
    f.body:SetPoint("TOPLEFT", PAD, -(HEADER_HEIGHT + 8))
    f.body:SetSize(BODY_WIDTH, BODY_HEIGHT)

    for _, module in ipairs(DW.moduleOrder) do
        if module.CreatePanel then
            local chip = DW.CreateChip(f.body, SIDEBAR_WIDTH, CHIP_HEIGHT, module.icon or DW.ICON)
            chip.id = module.id
            chip:SetScript("OnClick", function(self)
                Select(self.id)
            end)
            moduleChips[#moduleChips + 1] = chip
        end
    end
    LayoutChips() -- in the order the player has chosen

    -- Settings sits at the bottom of the same edge.
    f.settingsChip = DW.CreateChip(f.body, SIDEBAR_WIDTH, CHIP_HEIGHT, SETTINGS_ICON)
    f.settingsChip:SetPoint("BOTTOMLEFT", 0, 0)
    f.settingsChip:SetScript("OnClick", function()
        Select(SETTINGS)
    end)

    f.content = CreateFrame("Frame", nil, f.body, "BackdropTemplate")
    f.content:SetPoint("TOPLEFT", SIDEBAR_WIDTH + 10, 0)
    f.content:SetSize(CONTENT_WIDTH, BODY_HEIGHT)
    f.content:SetBackdrop(CHIP_BACKDROP)
    f.content:SetBackdropColor(0.00, 0.00, 0.00, 0.45)
    f.content:SetBackdropBorderColor(0.45, 0.45, 0.45, 1)

    return f
end

-- Writes the chip texts in the chosen language.
local function ApplyLanguage()
    if not window then
        return
    end
    for _, chip in ipairs(moduleChips) do
        chip.label:SetText(DW.ModuleTitle(DW.modules[chip.id]))
    end
    window.settingsChip.label:SetText(L.SETTINGS)
    window.subtitle:SetText(L.SUBTITLE:upper())
    RefreshStatusPills()
    if panels[SETTINGS] then
        panels[SETTINGS]:Refresh()
    end
end

DW.OnLanguageChanged(ApplyLanguage)

-- If the character stops being a member while the window is open, it closes.
DW.OnMembershipChanged(function(member)
    if not member and window then
        window:Hide()
    end
end)

-- Modules that want to show something when the window opens (e.g. a reminder
-- the first time) register here. The function gets the window, and is called
-- every time the window opens with the modules visible, that is, after the
-- language is chosen.
local openedCallbacks = {}

function DW.OnWindowOpened(callback)
    openedCallbacks[#openedCallbacks + 1] = callback
end

-- Shows the window. id is the module (or SETTINGS) to show; without id it
-- shows what was shown last, or the first module.
ShowWindow = function(id)
    if not DW.Guard() then
        return
    end
    if not window then
        window = CreateWindow()
        ApplyLanguage()
    end
    window:Show()

    if not DW.HasChosenLanguage() then
        -- Ask about language first. Remember what was to be opened.
        pending = id or pending
        if not window.prompt then
            window.prompt = CreateLanguagePrompt(window)
        end
        window.body:Hide()
        window.prompt:Show()
        return
    end

    if window.prompt then
        window.prompt:Hide()
    end

    if not IsSetupDone() then
        -- Step 2 of the first-time setup is the intro, step 3 the choices
        -- (flashing and the action bar button).
        pending = id or pending
        if not window.intro then
            window.intro = CreateIntroPrompt(window)
            window.setup = CreateSetupPrompt(window)
        end
        window.body:Hide()
        local page = (setupStep == "options") and window.setup or window.intro
        local other = (page == window.setup) and window.intro or window.setup
        other:Hide()
        page:Refresh()
        page:Show()
        return
    end

    if window.intro then
        window.intro:Hide()
        window.setup:Hide()
    end

    if DW.NeedsRoleChoice and DW.NeedsRoleChoice() then
        -- The role, the first time on this character.
        pending = id or pending
        if not window.rolePrompt then
            window.rolePrompt = CreateRolePrompt(window)
        end
        if not window.rolePrompt:IsShown() then
            window.rolePrompt:Load()
        end
        window.body:Hide()
        window.rolePrompt:Refresh()
        window.rolePrompt:Show()
        return
    end
    if window.rolePrompt and window.rolePrompt:IsShown() then
        window.rolePrompt:Hide()
        id = id or pending
        pending = nil
    end
    window.body:Show()
    Select(id or selected or FirstModuleID())

    for _, callback in ipairs(openedCallbacks) do
        local ok, problem = pcall(callback, window)
        if not ok then
            DW.PrintError(L.ERROR, problem)
        end
    end
end

-- Public ------------------------------------------------------------------------

-- Opens the main window, or closes it if it is open.
function DW.ToggleMainWindow()
    if window and window:IsShown() then
        window:Hide()
    else
        ShowWindow()
    end
end

-- Opens the main window on a specific module.
function DW.OpenModule(id)
    ShowWindow(id)
end

-- Like OpenModule, but closes the window if the module is already shown.
function DW.ToggleModule(id)
    if DW.IsModuleShown(id) then
        window:Hide()
    else
        ShowWindow(id)
    end
end

function DW.OpenSettings()
    ShowWindow(SETTINGS)
end

-- Shows the intro and the choices from the first-time setup again (the button under Settings).
function DW.ShowIntro()
    forceSetup = true
    setupStep = "intro"
    ShowWindow()
end

function DW.IsMainWindowShown()
    return window ~= nil and window:IsShown()
end

-- Is this module shown right now (window open, setup done, tab selected)?
function DW.IsModuleShown(id)
    return window ~= nil and window:IsShown() and window.body:IsShown() and selected == id
end
