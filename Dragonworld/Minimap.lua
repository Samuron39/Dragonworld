-- Dragonworld - knappen ved minimapet
--
-- Knappen legger seg selv på kanten av minimapet. Klikk åpner hovedvinduet.
-- Den blinker mildt når noe er nytt (Alerts.lua).
-- Den kan dras rundt kanten, og plasseringen huskes. Den kan skjules under
-- Innstillinger eller med "/dw knapp".

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

    -- Gløden som blinker mildt i en farge når noe er nytt (Alerts.lua), over
    -- ikonet. Rammen rundt farges litt i takt med den.
    b.glow = b:CreateTexture(nil, "ARTWORK", nil, 1)
    b.glow:SetSize(28, 28)
    b.glow:SetPoint("CENTER", 0, 1)
    b.glow:SetTexture("Interface\\Minimap\\UI-Minimap-ZoomButton-Highlight")
    b.glow:SetBlendMode("ADD")
    DW.AddGlowTarget({ glow = b.glow, tint = border })

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
        DW.AddAlertLines(GameTooltip) -- hva som er nytt, hvis noe
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

-- Andre addons kan gjøre minimapet firkantet. De er først ferdig lastet ved
-- innlogging, så knappen plasseres på nytt da.
local frame = CreateFrame("Frame")
frame:RegisterEvent("PLAYER_LOGIN")
frame:SetScript("OnEvent", Place)
