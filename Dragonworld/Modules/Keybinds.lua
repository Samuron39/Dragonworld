-- Dragonworld - Keybinds per spec
-- Lagrer tastebindingene dine for hver spec på karakteren, og henter dem igjen
-- når du vil, eller automatisk når du bytter spec.
--
-- I Forever er "spec" de to talentgruppene: hovedspec og sekundærspec.
--
-- Slik virker det:
--   * "Lagre" tar et bilde av alle tastebindingene du har nå, og legger det
--     på den spec-en du velger.
--   * "Hent" bytter ut tastebindingene dine med de lagrede.
--   * Med automatisk bytte på: når du bytter spec, lagres det du hadde på
--     spec-en du forlot, og det du har lagret for den nye hentes.
--   * Før hvert bytte tas en sikkerhetskopi, så "Angre" gir deg tilbake det
--     du hadde.
--
-- Spillet lar ikke addons endre tastebindinger i kamp. Skjer et bytte i kamp,
-- utsettes det til kampen er over.
--
-- All tekst ligger i Locales.lua (navnene som begynner med KB_).

local ADDON_NAME, DW = ...
local L = DW.L

local MODULE_ID = "keybinds"
local MAX_SPECS = 4

local Print = DW.Print

-- Lagrede data. Settes i OnLoad nederst.
--   db.characters["Navn-Realm"] = {
--       sets = { [specnummer] = { binds = { [kommando] = { tast, ... } }, count, time } },
--       auto = true hvis bindingene skal byttes automatisk ved spec-bytte,
--       current = specnummeret bindingene du har akkurat nå hører til,
--       backup = { binds, count, time }   det du hadde før siste bytte,
--   }
local db = { characters = {} }

local function CharacterData()
    local key = DW.CharacterKey()
    if not key then
        return nil
    end
    local character = db.characters[key]
    if type(character) ~= "table" then
        character = {}
        db.characters[key] = character
    end
    if type(character.sets) ~= "table" then
        character.sets = {}
    end
    return character
end

-- Spec ------------------------------------------------------------------------

local function ActiveSpec()
    local index
    if C_SpecializationInfo and C_SpecializationInfo.GetActiveSpecGroup then
        index = C_SpecializationInfo.GetActiveSpecGroup()
    elseif GetActiveSpecGroup then
        index = GetActiveSpecGroup()
    end
    if type(index) ~= "number" or DW.IsSecret(index) or index < 1 or index > MAX_SPECS then
        return 1
    end
    return index
end

local function NumSpecs()
    local count
    local getCount = GetNumSpecGroups or GetNumTalentGroups
    if getCount then
        local ok, value = pcall(getCount)
        if ok then
            count = value
        end
    end
    if type(count) ~= "number" or DW.IsSecret(count) or count < 1 then
        count = 1
    end
    -- Vis alltid minst den aktive, selv om tallet skulle være feil.
    return math.min(MAX_SPECS, math.max(count, ActiveSpec()))
end

local function SpecName(index)
    if index == 1 then
        return L.KB_SPEC_1
    elseif index == 2 then
        return L.KB_SPEC_2
    end
    return L.KB_SPEC_N:format(index)
end

-- Tastebindinger ----------------------------------------------------------------

local function Pack(...)
    return select("#", ...), { ... }
end

-- Tar et bilde av alle tastebindingene: binds[kommando] = { tast, tast, ... }.
-- Bare kommandoer som har minst én tast tas med.
local function Snapshot()
    local binds, count = {}, 0
    for index = 1, (GetNumBindings() or 0) do
        local n, values = Pack(GetBinding(index))
        local command = values[1]
        if type(command) == "string" then
            local keys = {}
            for i = 3, n do
                if type(values[i]) == "string" then
                    keys[#keys + 1] = values[i]
                end
            end
            if #keys > 0 then
                binds[command] = keys
                count = count + 1
            end
        end
    end
    return binds, count
end

local function InCombat()
    return InCombatLockdown and InCombatLockdown() and true or false
end

-- Bytter ut tastebindingene med et lagret sett. Returnerer true hvis det gikk.
local function Apply(binds)
    -- Et tomt sett ville fjernet alle tastene dine. Det gjør vi aldri.
    if type(binds) ~= "table" or next(binds) == nil then
        return false
    end
    if InCombat() then
        return false
    end

    -- Fjern først alle tastene som står på vanlige kommandoer nå ...
    for index = 1, (GetNumBindings() or 0) do
        local n, values = Pack(GetBinding(index))
        if type(values[1]) == "string" then
            for i = 3, n do
                if type(values[i]) == "string" then
                    SetBinding(values[i])
                end
            end
        end
    end
    -- ... og sett så de lagrede.
    for command, keys in pairs(binds) do
        if type(command) == "string" and type(keys) == "table" then
            for _, key in ipairs(keys) do
                if type(key) == "string" then
                    SetBinding(key, command)
                end
            end
        end
    end

    -- Lagre, ellers er endringen borte ved neste innlogging.
    SaveBindings(GetCurrentBindingSet())
    return true
end

-- Handlinger ------------------------------------------------------------------

local RefreshPanel

local function Save(index)
    local character = CharacterData()
    if not character then
        return
    end
    local binds, count = Snapshot()
    character.sets[index] = { binds = binds, count = count, time = time() }
    character.current = index
    Print(L.KB_MSG_SAVED:format(SpecName(index), count))
    RefreshPanel()
end

local function Load(index)
    local character = CharacterData()
    local set = character and character.sets[index]
    if not set then
        Print(L.KB_MSG_NOTHING:format(SpecName(index)))
        return
    end
    if InCombat() then
        Print(L.KB_MSG_COMBAT)
        return
    end

    local binds, count = Snapshot()
    if Apply(set.binds) then
        character.backup = { binds = binds, count = count, time = time() }
        character.current = index
        Print(L.KB_MSG_LOADED:format(SpecName(index)))
    end
    RefreshPanel()
end

local function Undo()
    local character = CharacterData()
    local backup = character and character.backup
    if not backup then
        return
    end
    if InCombat() then
        Print(L.KB_MSG_COMBAT)
        return
    end
    if Apply(backup.binds) then
        character.backup = nil
        character.current = nil
        Print(L.KB_MSG_UNDONE)
    end
    RefreshPanel()
end

-- Automatisk bytte --------------------------------------------------------------

local lastSpec      -- spec-en vi sist så karakteren i
local pendingSwitch -- { from, to } mens et bytte venter på at kampen tar slutt

local function TrySwitch()
    if not pendingSwitch or InCombat() then
        return
    end
    local from, to = pendingSwitch.from, pendingSwitch.to
    pendingSwitch = nil

    local character = CharacterData()
    if not character or not character.auto then
        return
    end

    -- Det du hadde satt opp hører til spec-en du forlot (eller til settet du
    -- sist hentet for hånd).
    local binds, count = Snapshot()
    local owner = character.current or from
    if owner then
        character.sets[owner] = { binds = binds, count = count, time = time() }
    end

    local set = character.sets[to]
    if set and type(set.binds) == "table" and next(set.binds) ~= nil then
        if Apply(set.binds) then
            character.backup = { binds = binds, count = count, time = time() }
            Print(L.KB_MSG_SWITCHED:format(SpecName(to)))
        end
    else
        -- Første gang i denne spec-en: begynn med de samme tastene.
        character.sets[to] = { binds = binds, count = count, time = time() }
        Print(L.KB_MSG_FIRST:format(SpecName(to)))
    end
    character.current = to
    RefreshPanel()
end

local function OnSpecMayHaveChanged()
    local now = ActiveSpec()
    if lastSpec == nil then
        lastSpec = now
        return
    end
    if now == lastSpec then
        return
    end
    pendingSwitch = { from = pendingSwitch and pendingSwitch.from or lastSpec, to = now }
    lastSpec = now
    TrySwitch()
    RefreshPanel()
end

-- Panelet i hovedvinduet --------------------------------------------------------

local panel -- lages første gang modulen velges i hovedvinduet
local specRows = {}

local function GetSpecRow(index)
    local row = specRows[index]
    if row then
        return row
    end

    row = CreateFrame("Frame", nil, panel)
    row:SetSize(panel:GetWidth() - 28, 46)
    row:SetPoint("TOPLEFT", 14, -112 - (index - 1) * 52)

    row.name = row:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    row.name:SetPoint("TOPLEFT", 2, -4)

    row.status = row:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    row.status:SetPoint("TOPLEFT", row.name, "BOTTOMLEFT", 0, -4)

    row.load = DW.CreateButton(row, 110, 28, "red")
    row.load:SetPoint("RIGHT", 0, 0)
    row.load:SetScript("OnClick", function()
        Load(index)
    end)

    row.save = DW.CreateButton(row, 130, 28, "gold")
    row.save:SetPoint("RIGHT", row.load, "LEFT", -8, 0)
    row.save:SetScript("OnClick", function()
        Save(index)
    end)

    specRows[index] = row
    return row
end

RefreshPanel = function()
    if not panel or not panel:IsVisible() then
        return
    end

    local character = CharacterData()
    local active = ActiveSpec()

    panel.title:SetText(L.KB_PANEL_TITLE)
    panel.hint:SetText(L.KB_HINT)
    panel.active:SetText(L.KB_ACTIVE:format(SpecName(active)))
    panel.autoLabel:SetText(L.KB_AUTO)
    panel.undo.label:SetText(L.KB_UNDO)

    local count = NumSpecs()
    for index = 1, count do
        local row = GetSpecRow(index)
        local set = character and character.sets[index]
        row.name:SetText(SpecName(index))
        if index == active then
            row.name:SetTextColor(1.00, 0.82, 0.00)
        else
            row.name:SetTextColor(0.90, 0.90, 0.90)
        end
        if set then
            row.status:SetText(L.KB_SAVED_INFO:format(date("%d.%m.%Y %H:%M", set.time or 0), set.count or 0))
        else
            row.status:SetText(L.KB_NOT_SAVED)
        end
        row.save.label:SetText(L.KB_SAVE)
        row.load.label:SetText(L.KB_LOAD)
        row.load:SetActive(set ~= nil)
        row:Show()
    end
    for index = count + 1, #specRows do
        specRows[index]:Hide()
    end

    panel.autoCheck:SetChecked(character ~= nil and character.auto == true)
    panel.undo:SetActive(character ~= nil and character.backup ~= nil)
end

-- Kalles av hovedvinduet første gang modulen velges.
local function CreatePanel(parent)
    local f = CreateFrame("Frame", nil, parent)
    f:SetAllPoints(parent)
    f:SetSize(parent:GetWidth(), parent:GetHeight())

    f.title = f:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
    f.title:SetPoint("TOP", 0, -12)

    f.hint = f:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    f.hint:SetPoint("TOPLEFT", 14, -38)
    f.hint:SetPoint("TOPRIGHT", -14, -38)
    f.hint:SetJustifyH("LEFT")

    f.active = f:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    f.active:SetPoint("TOPLEFT", 16, -84)

    f.autoCheck = CreateFrame("CheckButton", nil, f, "UICheckButtonTemplate")
    f.autoCheck:SetSize(24, 24)
    f.autoCheck:SetPoint("BOTTOMLEFT", 10, 12)
    f.autoCheck:SetScript("OnClick", function(self)
        local character = CharacterData()
        if character then
            character.auto = self:GetChecked() and true or nil
            -- Fra nå av hører tastene du har til spec-en du står i.
            if character.auto then
                character.current = ActiveSpec()
            end
        end
        RefreshPanel()
    end)

    f.autoLabel = f:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    f.autoLabel:SetPoint("LEFT", f.autoCheck, "RIGHT", 2, 0)

    f.undo = DW.CreateButton(f, 200, 28, "red")
    f.undo:SetPoint("BOTTOMRIGHT", -14, 12)
    f.undo:SetScript("OnClick", function()
        Undo()
    end)

    f:SetScript("OnShow", function()
        RefreshPanel()
    end)

    panel = f
    return f
end

-- Hendelser -------------------------------------------------------------------

local frame = CreateFrame("Frame")

frame:SetScript("OnEvent", function(self, event)
    if not DW.IsMember() then
        return
    end
    if event == "PLAYER_REGEN_ENABLED" then
        -- Kampen er over: gjør et bytte som måtte vente.
        TrySwitch()
        RefreshPanel()
    else
        OnSpecMayHaveChanged()
    end
end)

for _, event in ipairs({
    "PLAYER_ENTERING_WORLD",
    "ACTIVE_TALENT_GROUP_CHANGED",
    "PLAYER_REGEN_ENABLED",
}) do
    pcall(frame.RegisterEvent, frame, event)
end

DW.OnLanguageChanged(function()
    RefreshPanel()
end)

-- Guild-navnet kan komme sent etter innlogging. Noter da hvilken spec
-- karakteren står i, så første spec-bytte blir oppdaget.
DW.OnMembershipChanged(function(member)
    if member and lastSpec == nil then
        lastSpec = ActiveSpec()
    end
end)

-- Modul --------------------------------------------------------------------------

DW.RegisterModule({
    id = MODULE_ID,
    titleKey = "KB_TITLE",
    notesKey = "KB_NOTES",
    icon = "Interface\\Icons\\INV_Misc_Key_03",

    OnLoad = function(self, saved)
        if type(saved.characters) ~= "table" then
            saved.characters = {}
        end
        db = saved
    end,

    CreatePanel = function(self, parent)
        return CreatePanel(parent)
    end,
})
