-- Dragonworld - hovedvinduet
--
--   +--------------------------------------------------------------+
--   | [logo]  Dragonworld                                      [x] |
--   |--------------------------------------------------------------|
--   | [ Modul 1    ]  +------------------------------------------+ |
--   | [ Modul 2    ]  |                                          | |
--   |                 |   innholdet til den valgte modulen       | |
--   |                 |                                          | |
--   | [Innstillinger] +------------------------------------------+ |
--   +--------------------------------------------------------------+
--
-- Hver modul som har CreatePanel får en chip i venstre kant, i den rekkefølgen
-- spilleren velger under Innstillinger. Innstillinger er en egen side med
-- språkvalg, minimap-knappen, blinking, knappen til action bar, versjonen og
-- rekkefølgen på fanene. Første gang vinduet åpnes vises første oppsett i
-- stedet for modulene: språkvalget, og så blinking og action bar-knappen.

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

-- Pyntefonten spillet bruker i quest-titler. Finnes den ikke, beholder
-- teksten den vanlige skriften.
local TITLE_FONT = "Fonts\\MORPHEUS.TTF"
local SETTINGS_ICON = "Interface\\Icons\\Trade_Engineering"
local BODY_WIDTH = WIDTH - 2 * PAD
local BODY_HEIGHT = HEIGHT - HEADER_HEIGHT - 8 - PAD
local CONTENT_WIDTH = BODY_WIDTH - SIDEBAR_WIDTH - 10

local SETTINGS = "settings" -- siden for innstillinger; ikke en modul

local window
local moduleChips = {} -- chips for modulene, ovenfra og ned
local panels = {}      -- [modul-id eller SETTINGS] = rammen med innholdet
local selected         -- hva som vises nå
local pending          -- hva som skal åpnes når språk er valgt

-- Chips -----------------------------------------------------------------------

local CHIP_BACKDROP = {
    bgFile = "Interface\\Buttons\\WHITE8X8",
    edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border",
    edgeSize = 12,
    insets = { left = 3, right = 3, top = 3, bottom = 3 },
}

-- Samme ramme brukes av moduler som lager egne små ruter (f.eks. datovelgeren).
DW.PANEL_BACKDROP = CHIP_BACKDROP

local function PaintChip(chip)
    if chip.dimmed then
        -- Kan ikke velges (f.eks. en dag som allerede har vært).
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

-- En chip er en avrundet knapp med tekst, og eventuelt et ikon til venstre.
-- Den valgte får gullkant. Moduler kan bruke den samme til egne valg.
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

    -- Gråer chipen ut. Brukes sammen med SetEnabled(false) for valg som ikke
    -- er tilgjengelige.
    function chip:SetDimmed(isDimmed)
        self.dimmed = isDimmed and true or false
        PaintChip(self)
    end

    PaintChip(chip)
    return chip
end

-- Knapper ---------------------------------------------------------------------

-- Farger for knapper som gjør noe: rød for "kast", gull for hovedhandlingen.
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

-- En farget knapp i samme stil som chipene. style er "red" eller "gold".
-- Bruk button:SetActive(false) for å gråe den ut.
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

    PaintButton(button)
    return button
end

-- Rekkefølgen på fanene -----------------------------------------------------------

-- Spilleren velger selv rekkefølgen på modul-fanene under Innstillinger. Den
-- lagres i DragonworldDB.tabOrder (felles for alle karakterene på kontoen).

-- Rekkefølgen før spilleren har valgt selv (valgt av guildlederen).
local DEFAULT_TAB_ORDER = {
    "roster", "guildchat", "dungeons", "guildbank", "events", "professions", "materialer", "ryddesekk", "keybinds", "forslag",
}

-- Modulene som har en fane, i valgt rekkefølge (eller standardrekkefølgen).
-- En modul som mangler i spillerens lagrede rekkefølge (f.eks. fordi den er
-- ny), får plassen sin fra standardrekkefølgen: rett etter den som står foran
-- den der. Moduler som ikke er i standardrekkefølgen kommer nederst.
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
            -- Etter den nærmeste foran den i standardrekkefølgen som er med.
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

-- Stiller fanene i venstre kant i valgt rekkefølge. Er det for mange til at
-- de får plass over Innstillinger, rykker de litt tettere sammen.
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

-- Flytter en modul ett steg opp (step = -1) eller ned (step = 1) og husker det.
-- Returnerer true hvis den ble flyttet.
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

-- En liten pilknapp (opp eller ned) med spillets egne pilbilder.
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

-- Innstillinger har to kolonner under språkvalget: knapper, blinking og
-- versjon til venstre, rekkefølgen på fanene til høyre.
local RIGHT_COLUMN, RIGHT_WIDTH = 330, 266
local ORDER_TOP, ORDER_ROW = -136, 24

-- Én linje i listen over fanene: ikon, navn, og pil opp og ned.
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

-- Innstillinger -----------------------------------------------------------------

-- En avkrysningsboks med tekst til høyre.
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

-- Valgene for blinking (Alerts.lua): én boks for alt, og med withKinds én boks
-- per ting det kan blinke for, med fargen som en liten firkant. Brukes både
-- under Innstillinger og i første oppsett.
local KIND_ROW = 22 -- avstanden mellom valgene for hva det blinker for

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

-- Et tekstfelt med lenken til nedlasting, så den kan kopieres med Ctrl+C.
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
            Select(self) -- teksten skal ikke kunne endres
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

    -- Introen og valgene fra første oppsett, en gang til.
    panel.introButton = DW.CreateChip(panel, 140, 24)
    panel.introButton:SetPoint("TOPRIGHT", -14, -10)
    panel.introButton.label:SetJustifyH("CENTER")
    panel.introButton:SetScript("OnClick", function()
        DW.ShowIntro()
    end)

    panel.languageChips = {}
    for index, language in ipairs(DW.LANGUAGES) do
        local chip = DW.CreateChip(panel, 150, CHIP_HEIGHT)
        chip:SetPoint("TOPLEFT", 16 + (index - 1) * 158, -40)
        chip.label:SetJustifyH("CENTER")
        chip.label:SetText(language.name)
        chip.code = language.code
        chip:SetScript("OnClick", function(self)
            DW.SetLanguage(self.code, true)
        end)
        panel.languageChips[index] = chip
    end

    -- Venstre kolonne: knappen ved minimapet og blinkingen.
    panel.minimapCheck = CreateCheck(panel, 14, -96, function(self)
        if DW.SetMinimapButtonShown then
            DW.SetMinimapButtonShown(self:GetChecked() and true or false)
        end
    end)
    panel.minimapLabel = panel.minimapCheck.label

    panel.blink = CreateBlinkChoices(panel, 14, -122, true)
    local y = -122 - #panel.blink.kinds * KIND_ROW - 32

    -- Knappen til action bar.
    panel.actionLabel = panel:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    panel.actionLabel:SetPoint("TOPLEFT", 16, y)
    panel.actionSource = DW.CreateActionButtonSource(panel, 32)
    panel.actionSource:SetPoint("TOPLEFT", 16, y - 18)
    panel.actionHint = panel:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    panel.actionHint:SetPoint("TOPLEFT", panel.actionSource, "TOPRIGHT", 10, -2)
    panel.actionHint:SetWidth(250)
    panel.actionHint:SetJustifyH("LEFT")
    y = y - 18 - 32 - 14

    -- Versjonen, og om det finnes en nyere (Update.lua).
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

    -- Høyre kolonne: rekkefølgen på fanene i venstre kant.
    panel.orderLabel = panel:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    panel.orderLabel:SetPoint("TOPLEFT", RIGHT_COLUMN, -96)
    panel.orderLabel:SetWidth(RIGHT_WIDTH)
    panel.orderLabel:SetJustifyH("LEFT")
    panel.orderRows = {}

    -- Skriver teksten på valgt språk og viser gjeldende valg.
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

-- Hører addonen om en nyere versjon mens Innstillinger er åpen, vises det.
DW.OnNewerVersion(function()
    if panels[SETTINGS] and panels[SETTINGS]:IsShown() then
        panels[SETTINGS]:Refresh()
    end
end)

-- Valg av side ------------------------------------------------------------------

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
        -- Skjul først, så OnShow alltid kjører når den vises under.
        panel:Hide()
        panels[id] = panel
    end
    panel:Show()

    -- Det som blinket for denne fanen, er nå sett (Alerts.lua).
    if DW.RefreshAlerts then
        DW.RefreshAlerts()
    end
end

-- Språkvalg første gang -----------------------------------------------------------

local ShowWindow

local function CreateLanguagePrompt(parent)
    local prompt = CreateFrame("Frame", nil, parent)
    prompt:SetPoint("TOPLEFT", PAD, -(HEADER_HEIGHT + 8))
    prompt:SetSize(BODY_WIDTH, BODY_HEIGHT)

    -- Samme setning på alle tre språk, siden vi ikke vet hvilket de kan.
    for index, language in ipairs(DW.LANGUAGES) do
        local line = prompt:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
        line:SetPoint("TOP", 0, -60 - (index - 1) * 24)
        line:SetText(DW.strings[language.code].PROMPT)
    end

    prompt.chips = {}
    for index, language in ipairs(DW.LANGUAGES) do
        local chip = DW.CreateChip(prompt, 180, 40)
        chip:SetPoint("TOP", (index - 2) * 196, -170)
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

-- Første oppsett, steg 2 og 3 -----------------------------------------------------

-- Etter språkvalget: en intro (hva addonen kan, og hva du bør åpne i spillet
-- så visningene fylles), og så valgene for hva knappene skal blinke for og
-- knappen til action bar. Vises én gang per konto. SETUP_VERSION økes når
-- oppsettet får noe nytt alle bør se; da får alle det én gang til. "Vis
-- introen" under Innstillinger viser det igjen. Alt kan endres senere.
local SETUP_VERSION = 2
local setupStep          -- "intro" eller "options" mens oppsettet vises
local forceSetup = false -- "Vis introen" er trykket

local function IsSetupDone()
    if forceSetup then
        return false
    end
    return type(DragonworldDB) == "table" and (tonumber(DragonworldDB.setupVersion) or 0) >= SETUP_VERSION
end

local function FinishSetup()
    if type(DragonworldDB) == "table" then
        DragonworldDB.setupDone = true -- eldre versjoner av addonen ser etter denne
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

-- Introen: fanene til venstre (ikon, navn og hva de gjør, i fanerekkefølgen),
-- "Kom i gang" til høyre.
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

-- Valgene: blinking (med hva det blinker for) og knappen til action bar.
local function CreateSetupPrompt(parent)
    local prompt = CreateFrame("Frame", nil, parent)
    prompt:SetPoint("TOPLEFT", PAD, -(HEADER_HEIGHT + 8))
    prompt:SetSize(BODY_WIDTH, BODY_HEIGHT)

    local LEFT = 190 -- valgene står i en blokk litt inn fra venstre

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

-- Status øverst til høyre -----------------------------------------------------------

-- Tre knapper ("pills") der spilleren viser hva de holder på med: quester,
-- åpen for dungeons, eller crafter / ikke forstyrr. Bare én kan være på. Et
-- klikk på den som er på slår den av. "Dungeon" åpner først et vindu der man
-- velger hvilke dungeons (Modules\Dungeons.lua). Selve statusen og delingen
-- ligger i Status.lua.
local PILL_WIDTH, PILL_HEIGHT, PILL_GAP = 134, 26, 6 -- bredt nok til "Do not disturb"

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
        pill.icon:SetSize(16, 16) -- litt større enn chipene ellers, så ikonet synes
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

-- Vinduet ---------------------------------------------------------------------

local function CreateWindow()
    local f = CreateFrame("Frame", WINDOW_NAME, UIParent, "BackdropTemplate")
    f:SetSize(WIDTH, HEIGHT)
    f:SetFrameStrata("HIGH")
    -- Nesten helt tett bakgrunn, så tekst fra andre addons bak vinduet ikke
    -- skinner gjennom og blander seg med innholdet.
    f:SetBackdrop({
        bgFile = "Interface\\Buttons\\WHITE8X8",
        edgeFile = "Interface\\DialogFrame\\UI-DialogBox-Border",
        edgeSize = 16,
        insets = { left = 4, right = 4, top = 4, bottom = 4 },
    })
    f:SetBackdropColor(0.04, 0.04, 0.06, 0.95)
    f:SetBackdropBorderColor(0.90, 0.72, 0.30, 1) -- gulltone på kanten
    f:Hide()

    -- Husk hvor vinduet ble flyttet til.
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

    -- Escape lukker vinduet.
    table.insert(UISpecialFrames, WINDOW_NAME)

    -- Topp: skjoldet oppe til venstre, så stort at det stikker litt ut over
    -- hjørnet, med guildnavnet i store bokstaver ved siden av.
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

    -- Statusknappene øverst til høyre, på linje med guildnavnet.
    CreateStatusPills(f)

    local line = f:CreateTexture(nil, "ARTWORK")
    line:SetColorTexture(1.00, 0.82, 0.00, 0.35)
    line:SetHeight(1)
    line:SetPoint("TOPLEFT", PAD, -HEADER_HEIGHT)
    line:SetPoint("TOPRIGHT", -PAD, -HEADER_HEIGHT)

    -- Alt under toppen: chips til venstre, innhold til høyre.
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
    LayoutChips() -- i den rekkefølgen spilleren har valgt

    -- Innstillinger ligger nederst i samme kant.
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

-- Skriver chip-tekstene på valgt språk.
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

-- Slutter karakteren å være medlem mens vinduet er åpent, lukkes det.
DW.OnMembershipChanged(function(member)
    if not member and window then
        window:Hide()
    end
end)

-- Moduler som vil vise noe når vinduet åpnes (f.eks. en påminnelse første
-- gang) melder seg her. Funksjonen får vinduet, og kalles hver gang vinduet
-- åpnes med modulene synlige, altså etter at språk er valgt.
local openedCallbacks = {}

function DW.OnWindowOpened(callback)
    openedCallbacks[#openedCallbacks + 1] = callback
end

-- Viser vinduet. id er modulen (eller SETTINGS) som skal vises; uten id vises
-- det som sto sist, eller den første modulen.
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
        -- Spør om språk først. Husk hva som skulle åpnes.
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
        -- Steg 2 av første oppsett er introen, steg 3 valgene (blinking og
        -- knappen til action bar).
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
    window.body:Show()
    Select(id or selected or FirstModuleID())

    for _, callback in ipairs(openedCallbacks) do
        local ok, problem = pcall(callback, window)
        if not ok then
            DW.PrintError(L.ERROR, problem)
        end
    end
end

-- Offentlig ---------------------------------------------------------------------

-- Åpner hovedvinduet, eller lukker det hvis det er åpent.
function DW.ToggleMainWindow()
    if window and window:IsShown() then
        window:Hide()
    else
        ShowWindow()
    end
end

-- Åpner hovedvinduet på en bestemt modul.
function DW.OpenModule(id)
    ShowWindow(id)
end

-- Som OpenModule, men lukker vinduet hvis modulen alt vises.
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

-- Viser introen og valgene fra første oppsett igjen (knappen under Innstillinger).
function DW.ShowIntro()
    forceSetup = true
    setupStep = "intro"
    ShowWindow()
end

function DW.IsMainWindowShown()
    return window ~= nil and window:IsShown()
end

-- Vises denne modulen akkurat nå (vinduet åpent, oppsettet ferdig, fanen valgt)?
function DW.IsModuleShown(id)
    return window ~= nil and window:IsShown() and window.body:IsShown() and selected == id
end
