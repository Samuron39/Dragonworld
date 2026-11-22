-- Dragonworld - Keybinds per spec
-- Saves your key bindings for each spec on the character, and gets them back
-- when you want, or automatically when you switch spec.
--
-- In Forever "spec" means the two talent groups: main spec and secondary spec.
--
-- This is how it works:
--   * "Save current" takes a snapshot of all the key bindings you have now, and
--     puts it on the spec you choose.
--   * "Load" replaces your key bindings with the saved ones.
--   * With automatic switching on: when you switch spec, what you had on the
--     spec you left is saved, and what you have saved for the new one is loaded.
--   * Before every switch a backup is made, so "Undo last change" gives you back
--     what you had.
--
-- The game does not let addons change key bindings in combat. If a switch
-- happens in combat, it is postponed until the combat is over.
--
-- All text is in Locales.lua (the names that start with KB_).

local ADDON_NAME, DW = ...
local L = DW.L

local MODULE_ID = "keybinds"
local MAX_SPECS = 4

local Print = DW.Print

-- Saved data. Set in OnLoad at the bottom.
--   db.characters["Name-Realm"] = {
--       sets = { [specnumber] = { binds = { [command] = { key, ... } }, count, time } },
--       auto = true if the bindings should be switched automatically on spec switch,
--       current = the spec number the bindings you have right now belong to,
--       backup = { binds, count, time }   what you had before the last switch,
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
    -- Always show at least the active one, even if the number should be wrong.
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

-- Key bindings ------------------------------------------------------------------

local function Pack(...)
    return select("#", ...), { ... }
end

-- Takes a snapshot of all the key bindings: binds[command] = { key, key, ... }.
-- Only commands that have at least one key are included.
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

-- Replaces the key bindings with a saved set. Returns true if it worked.
local function Apply(binds)
    -- An empty set would remove all your keys. We never do that.
    if type(binds) ~= "table" or next(binds) == nil then
        return false
    end
    if InCombat() then
        return false
    end

    -- First remove all the keys that are on regular commands now ...
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
    -- ... and then set the saved ones.
    for command, keys in pairs(binds) do
        if type(command) == "string" and type(keys) == "table" then
            for _, key in ipairs(keys) do
                if type(key) == "string" then
                    SetBinding(key, command)
                end
            end
        end
    end

    -- Save, otherwise the change is gone at the next login.
    SaveBindings(GetCurrentBindingSet())
    return true
end

-- Actions ---------------------------------------------------------------------

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

-- Automatic switching -----------------------------------------------------------

local lastSpec      -- the spec we last saw the character in
local pendingSwitch -- { from, to } while a switch waits for the combat to end

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

    -- What you had set up belongs to the spec you left (or to the set you
    -- last loaded by hand).
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
        -- First time in this spec: start with the same keys.
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

-- The panel in the main window --------------------------------------------------

local panel -- created the first time the module is chosen in the main window
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

-- Called by the main window the first time the module is chosen.
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
            -- From now on the keys you have belong to the spec you are in.
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

-- Events ----------------------------------------------------------------------

local frame = CreateFrame("Frame")

frame:SetScript("OnEvent", function(self, event)
    if not DW.HasAccess() then
        return
    end
    if event == "PLAYER_REGEN_ENABLED" then
        -- The combat is over: do a switch that had to wait.
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

-- The guild name can arrive late after login. Then note which spec the
-- character is in, so the first spec switch is detected.
DW.OnAccessChanged(function(access)
    if access and lastSpec == nil then
        lastSpec = ActiveSpec()
    end
end)

-- Module -------------------------------------------------------------------------

DW.RegisterModule({
    id = MODULE_ID,
    personal = true, -- alts outside the guild may use it (Core.lua)
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
