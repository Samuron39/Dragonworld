-- Dragonworld - Dungeons
-- Viser alle i guilden som er pålogget og har sagt at de er åpne for
-- dungeons, med rolle (tank, healer, dps), hvilke dungeons de vil ta og
-- hvorfor (quest-run, loot, xp). Herfra kan man hviske til dem eller invitere
-- dem.
--
-- Her ligger også vinduet man får opp når man trykker "Dungeon" øverst i
-- hovedvinduet: der velger man rolle (én eller to), dungeons og formål, og
-- lagrer. Selve statusen, dungeon-listen og delingen med guilden ligger i
-- Status.lua.
--
-- All tekst ligger i Locales.lua (navnene som begynner med DG_).

local ADDON_NAME, DW = ...
local L = DW.L

local MODULE_ID = "dungeons"

local COLUMNS, PER_COLUMN = 3, 13 -- dungeonene i velgeren: tre kolonner
local CHECK_ROW = 22
local ROW_HEIGHT = 44

-- Småting -----------------------------------------------------------------------

local function MyLevel()
    local level = UnitLevel and UnitLevel("player")
    if type(level) == "number" and not DW.IsSecret(level) then
        return level
    end
    return 0
end

local function Fits(dungeon, level)
    return level >= dungeon.min and level <= dungeon.max
end

local function DungeonLabel(dungeon)
    local range = dungeon.min == dungeon.max and tostring(dungeon.min) or ("%d-%d"):format(dungeon.min, dungeon.max)
    if dungeon.raid then
        return L.DG_RAID_LABEL:format(dungeon.name, range)
    end
    return ("%s (%s)"):format(dungeon.name, range)
end

local function PurposesText(purposes)
    local parts = {}
    for _, purpose in ipairs(DW.PURPOSES) do
        if purposes and purposes[purpose.code] then
            parts[#parts + 1] = L[purpose.key]
        end
    end
    return #parts > 0 and table.concat(parts, ", ") or L.DG_ANY_REASON
end

-- Rolleikonene til en oppføring, f.eks. tank + dps. Tomt om de ikke har valgt
-- noen (eldre versjon av addonen).
local RoleIcons = DW.RoleIcons

-- Rollene med ikon og navn, til verktøytips: "[ikon] Tank, [ikon] Healer".
local RolesText = DW.RoleNames

local function CountOf(set)
    local count = 0
    for _ in pairs(set or {}) do
        count = count + 1
    end
    return count
end

local function MyWish()
    local code, entry = DW.GetMyStatus()
    if code == "D" and entry then
        return entry.dungeons
    end
    return nil
end

-- Dungeonene i en oppføring, i fast rekkefølge, med dem du selv også vil ta i
-- grønt.
local function DungeonsText(dungeons, separator)
    local mine = MyWish() or {}
    local parts = {}
    for _, dungeon in ipairs(DW.DUNGEONS) do
        if dungeons and dungeons[dungeon.id] then
            parts[#parts + 1] = mine[dungeon.id] and ("|cff40ff40" .. dungeon.name .. "|r") or dungeon.name
        end
    end
    return table.concat(parts, separator or ", ")
end

local function SharedCount(dungeons)
    local mine = MyWish() or {}
    local count = 0
    for id in pairs(dungeons or {}) do
        if mine[id] then
            count = count + 1
        end
    end
    return count
end

local function IsMe(member)
    local guid = DW.MyGUID()
    if guid and member.guid then
        return member.guid == guid
    end
    local _, name = DW.CharacterKey()
    return name ~= nil and DW.NameKey(member.key) == DW.NameKey(name)
end

-- Hviske og invitere: spillets egne funksjoner, den nyere først.
local function Whisper(name)
    if ChatFrameUtil and ChatFrameUtil.SendTell then
        ChatFrameUtil.SendTell(name)
    elseif ChatFrame_SendTell then
        ChatFrame_SendTell(name)
    else
        DW.Print("/w " .. name)
    end
end

local function Invite(name)
    local invite = (C_PartyInfo and C_PartyInfo.InviteUnit) or InviteUnit
    if invite then
        invite(name)
    end
end

-- Velgeren ------------------------------------------------------------------------

local picker
local pickDungeons, pickPurposes, pickRoles = {}, {}, {}
local OpenTab -- åpner fanen etter at man har lagret

local function RefreshPicker()
    if not picker then
        return
    end
    local level = MyLevel()
    picker.title:SetText(L.DG_PICK_TITLE)
    picker.hint:SetText(L.DG_PICK_HINT:format(level))
    picker.roleLabel:SetText(L.DG_ROLE)
    -- Har man valgt to roller, går den tredje ikke an før man fjerner en.
    local full = CountOf(pickRoles) >= DW.MAX_ROLES
    for _, check in ipairs(picker.roleChecks) do
        local chosen = pickRoles[check.role.code] and true or false
        check.label:SetText(DW.RoleIcon(check.role, 16) .. " " .. L[check.role.key])
        check:SetChecked(chosen)
        check:SetEnabled(chosen or not full)
        if chosen or not full then
            check.label:SetTextColor(1, 1, 1)
        else
            check.label:SetTextColor(0.55, 0.55, 0.55)
        end
    end
    picker.whyLabel:SetText(L.DG_WHY)
    for _, check in ipairs(picker.purposeChecks) do
        check.label:SetText(L[check.purpose.key])
        check:SetChecked(pickPurposes[check.purpose.code] and true or false)
    end
    for _, check in ipairs(picker.dungeonChecks) do
        local dungeon = check.dungeon
        check.label:SetText(DungeonLabel(dungeon))
        if Fits(dungeon, level) then
            check.label:SetTextColor(1, 1, 1)
        else
            check.label:SetTextColor(0.55, 0.55, 0.55)
        end
        check:SetChecked(pickDungeons[dungeon.id] and true or false)
    end
    picker.fitting.label:SetText(L.DG_PICK_FITTING)
    picker.clear.label:SetText(L.DG_PICK_CLEAR)
    picker.save.label:SetText(L.DG_PICK_SAVE)
    picker.cancel.label:SetText(L.DG_PICK_CANCEL)
    picker.off.label:SetText(L.DG_PICK_OFF)
    picker.off:SetShown(DW.GetMyStatus() == "D")
end

local function CreatePicker(window)
    local p = CreateFrame("Frame", "DragonworldDungeonPicker", window, "BackdropTemplate")
    p:SetPoint("TOPLEFT", 14, -92)
    p:SetSize(window:GetWidth() - 28, window:GetHeight() - 92 - 14)
    p:SetFrameStrata("DIALOG")
    p:EnableMouse(true)
    p:SetBackdrop(DW.PANEL_BACKDROP)
    p:SetBackdropColor(0.05, 0.05, 0.07, 1)
    p:SetBackdropBorderColor(1.00, 0.82, 0.00, 1)
    -- Helt tett bakgrunn innenfor kanten, så det bak ikke skinner gjennom.
    p.solid = p:CreateTexture(nil, "BACKGROUND")
    p.solid:SetPoint("TOPLEFT", 3, -3)
    p.solid:SetPoint("BOTTOMRIGHT", -3, 3)
    p.solid:SetColorTexture(0.05, 0.05, 0.07, 1)
    local width = p:GetWidth()

    p.title = p:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
    p.title:SetPoint("TOPLEFT", 16, -12)

    p.hint = p:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    p.hint:SetPoint("TOPLEFT", 16, -36)
    p.hint:SetWidth(width - 32)
    p.hint:SetJustifyH("LEFT")

    -- Rolle: tank, healer, dps. Én eller to.
    p.roleLabel = p:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    p.roleLabel:SetPoint("TOPLEFT", 16, -62)
    p.roleChecks = {}
    for index, role in ipairs(DW.ROLES) do
        local check = CreateFrame("CheckButton", nil, p, "UICheckButtonTemplate")
        check:SetSize(22, 22)
        check:SetPoint("TOPLEFT", 76 + (index - 1) * 100, -58)
        check.role = role
        check.label = check:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
        check.label:SetPoint("LEFT", check, "RIGHT", 2, 0)
        check:SetScript("OnClick", function(self)
            if self:GetChecked() and CountOf(pickRoles) < DW.MAX_ROLES then
                pickRoles[self.role.code] = true
            else
                pickRoles[self.role.code] = nil
            end
            p.error:SetText("")
            RefreshPicker()
        end)
        p.roleChecks[index] = check
    end

    -- Hvorfor: quest-run, loot, xp. Man kan krysse av flere.
    p.whyLabel = p:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    p.whyLabel:SetPoint("TOPLEFT", 400, -62)
    p.purposeChecks = {}
    for index, purpose in ipairs(DW.PURPOSES) do
        local check = CreateFrame("CheckButton", nil, p, "UICheckButtonTemplate")
        check:SetSize(22, 22)
        check:SetPoint("TOPLEFT", 474 + (index - 1) * 110, -58)
        check.purpose = purpose
        check.label = check:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
        check.label:SetPoint("LEFT", check, "RIGHT", 2, 0)
        check:SetScript("OnClick", function(self)
            pickPurposes[self.purpose.code] = self:GetChecked() and true or nil
        end)
        p.purposeChecks[index] = check
    end

    -- Dungeonene, i tre kolonner.
    p.dungeonChecks = {}
    local columnWidth = math.floor((width - 32) / COLUMNS)
    for index, dungeon in ipairs(DW.DUNGEONS) do
        local column = math.floor((index - 1) / PER_COLUMN)
        local line = (index - 1) % PER_COLUMN
        local check = CreateFrame("CheckButton", nil, p, "UICheckButtonTemplate")
        check:SetSize(20, 20)
        check:SetPoint("TOPLEFT", 16 + column * columnWidth, -92 - line * CHECK_ROW)
        check.dungeon = dungeon
        check.label = check:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
        check.label:SetPoint("LEFT", check, "RIGHT", 2, 0)
        check.label:SetWidth(columnWidth - 28)
        check.label:SetJustifyH("LEFT")
        check.label:SetWordWrap(false)
        check:SetScript("OnClick", function(self)
            pickDungeons[self.dungeon.id] = self:GetChecked() and true or nil
            p.error:SetText("")
        end)
        p.dungeonChecks[index] = check
    end

    p.error = p:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    p.error:SetPoint("BOTTOMLEFT", 16, 46)
    p.error:SetTextColor(1.00, 0.35, 0.30)

    -- Knappene nederst.
    p.fitting = DW.CreateChip(p, 190, 28)
    p.fitting:SetPoint("BOTTOMLEFT", 16, 12)
    p.fitting.label:SetJustifyH("CENTER")
    p.fitting:SetScript("OnClick", function()
        local level = MyLevel()
        for _, dungeon in ipairs(DW.DUNGEONS) do
            if Fits(dungeon, level) then
                pickDungeons[dungeon.id] = true
            end
        end
        p.error:SetText("")
        RefreshPicker()
    end)

    p.clear = DW.CreateChip(p, 110, 28)
    p.clear:SetPoint("LEFT", p.fitting, "RIGHT", 8, 0)
    p.clear.label:SetJustifyH("CENTER")
    p.clear:SetScript("OnClick", function()
        pickDungeons = {}
        RefreshPicker()
    end)

    p.cancel = DW.CreateChip(p, 100, 28)
    p.cancel:SetPoint("BOTTOMRIGHT", -16, 12)
    p.cancel.label:SetJustifyH("CENTER")
    p.cancel:SetScript("OnClick", function()
        p:Hide()
    end)

    p.save = DW.CreateButton(p, 130, 28, "gold")
    p.save:SetPoint("RIGHT", p.cancel, "LEFT", -8, 0)
    p.save:SetScript("OnClick", function()
        if not next(pickDungeons) then
            p.error:SetText(L.DG_NEED_DUNGEON)
            return
        end
        if not next(pickRoles) then
            p.error:SetText(L.DG_NEED_ROLE)
            return
        end
        DW.SetMyStatus("D", { dungeons = pickDungeons, purposes = pickPurposes, roles = pickRoles })
        p:Hide()
        if OpenTab then
            OpenTab()
        end
    end)

    -- Bare når man allerede er åpen for dungeons.
    p.off = DW.CreateButton(p, 150, 28, "red")
    p.off:SetPoint("RIGHT", p.save, "LEFT", -8, 0)
    p.off:SetScript("OnClick", function()
        DW.SetMyStatus(nil)
        p:Hide()
    end)

    return p
end

-- Åpner velgeren, med det du valgte sist allerede krysset av.
function DW.OpenDungeonPicker()
    local window = _G.DragonworldFrame
    if not window or not DW.IsMember() then
        return
    end
    if not picker then
        picker = CreatePicker(window)
    end
    -- Bare ett slikt vindu oppå om gangen.
    if _G.DragonworldMemberCard then
        _G.DragonworldMemberCard:Hide()
    end
    local _, entry = DW.GetMyStatus()
    pickDungeons, pickPurposes, pickRoles = {}, {}, {}
    for id in pairs(entry and entry.dungeons or {}) do
        pickDungeons[id] = true
    end
    for code in pairs(entry and entry.purposes or {}) do
        pickPurposes[code] = true
    end
    for code in pairs(entry and entry.roles or {}) do
        pickRoles[code] = true
    end
    -- Første gang: rollen du har valgt i profilen din (Medlemmer).
    if not next(pickRoles) and DW.GetMyRoles then
        for code in pairs(DW.GetMyRoles()) do
            pickRoles[code] = true
        end
    end
    picker.error:SetText("")
    RefreshPicker()
    picker:Show()
end

-- Fanen -----------------------------------------------------------------------

local panel
local rows = {}
local RefreshPanel
local filterDungeon -- id-en til én dungeon, eller nil for alle
local filterRole    -- koden til én rolle ("T", "H", "D"), eller nil for alle

local ROLE_BY_CODE = {}
for _, role in ipairs(DW.ROLES) do
    ROLE_BY_CODE[role.code] = role
end

local function Matches(entry)
    if filterDungeon ~= nil and not (entry.dungeons and entry.dungeons[filterDungeon]) then
        return false
    end
    -- De som ikke har valgt rolle (eldre versjon) vises ikke når man filtrerer
    -- på rolle.
    if filterRole ~= nil and not (entry.roles and entry.roles[filterRole]) then
        return false
    end
    return true
end

local function Collect()
    local list = DW.MembersWithStatus("D")
    local shown = {}
    for _, found in ipairs(list) do
        if Matches(found.entry) then
            found.me = IsMe(found.member)
            found.shared = SharedCount(found.entry.dungeons)
            shown[#shown + 1] = found
        end
    end
    table.sort(shown, function(a, b)
        if a.me ~= b.me then
            return a.me
        end
        if a.shared ~= b.shared then
            return a.shared > b.shared
        end
        return a.member.name < b.member.name
    end)
    return shown, list
end

local function OpenFilterMenu(owner)
    local _, everyone = Collect()
    local used = {}
    for _, found in ipairs(everyone) do
        for id in pairs(found.entry.dungeons or {}) do
            used[id] = true
        end
    end
    local function IsSelected(data)
        return (filterDungeon or false) == data
    end
    local function Select(data)
        filterDungeon = data or nil
        RefreshPanel()
    end
    if not (MenuUtil and MenuUtil.CreateContextMenu) then
        filterDungeon = nil
        RefreshPanel()
        return
    end
    MenuUtil.CreateContextMenu(owner, function(_, root)
        root:CreateTitle(L.DG_FILTER_TITLE)
        root:CreateRadio(L.DG_ALL, IsSelected, Select, false)
        for _, dungeon in ipairs(DW.DUNGEONS) do
            if used[dungeon.id] then
                root:CreateRadio(dungeon.name, IsSelected, Select, dungeon.id)
            end
        end
    end)
end

-- Filter på rolle: alle tre står alltid i menyen.
local function OpenRoleMenu(owner)
    local function IsSelected(data)
        return (filterRole or false) == data
    end
    local function Select(data)
        filterRole = data or nil
        RefreshPanel()
    end
    if not (MenuUtil and MenuUtil.CreateContextMenu) then
        filterRole = nil
        RefreshPanel()
        return
    end
    MenuUtil.CreateContextMenu(owner, function(_, root)
        root:CreateTitle(L.DG_ROLE_FILTER_TITLE)
        root:CreateRadio(L.DG_ALL, IsSelected, Select, false)
        for _, role in ipairs(DW.ROLES) do
            root:CreateRadio(DW.RoleIcon(role) .. " " .. L[role.key], IsSelected, Select, role.code)
        end
    end)
end

local function GetRow(index)
    local row = rows[index]
    if row then
        return row
    end
    local width = panel.content:GetWidth()
    row = CreateFrame("Frame", nil, panel.content)
    row:SetSize(width, ROW_HEIGHT - 4)
    row:SetPoint("TOPLEFT", 0, -(index - 1) * ROW_HEIGHT)
    row:EnableMouse(true)

    row.name = row:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
    row.name:SetPoint("TOPLEFT", 4, -4)
    row.name:SetWidth(134)
    row.name:SetJustifyH("LEFT")
    row.name:SetWordWrap(false)

    -- Rolleikonene (én eller to) mellom navnet og leveln.
    row.roles = row:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
    row.roles:SetPoint("TOPLEFT", 140, -3)
    row.roles:SetWidth(40)
    row.roles:SetJustifyH("LEFT")
    row.roles:SetWordWrap(false)

    row.level = row:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    row.level:SetPoint("TOPLEFT", 178, -6)
    row.level:SetWidth(30)
    row.level:SetJustifyH("RIGHT")

    row.why = row:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    row.why:SetPoint("TOPLEFT", 222, -6)
    row.why:SetWidth(200)
    row.why:SetJustifyH("LEFT")
    row.why:SetWordWrap(false)

    row.invite = DW.CreateButton(row, 70, 20, "gold")
    row.invite:SetPoint("TOPRIGHT", -4, -2)
    row.invite:SetScript("OnClick", function(self)
        if row.found then
            Invite(row.found.member.key)
        end
    end)

    row.whisper = DW.CreateChip(row, 70, 20)
    row.whisper:SetPoint("RIGHT", row.invite, "LEFT", -6, 0)
    row.whisper.label:SetJustifyH("CENTER")
    row.whisper:SetScript("OnClick", function()
        if row.found then
            Whisper(row.found.member.key)
        end
    end)

    row.dungeons = row:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    row.dungeons:SetPoint("BOTTOMLEFT", 4, 4)
    row.dungeons:SetWidth(width - 8)
    row.dungeons:SetJustifyH("LEFT")
    row.dungeons:SetWordWrap(false)

    -- Hold over raden for å se alle dungeonene medlemmet vil ta.
    row:SetScript("OnEnter", function(self)
        local found = self.found
        if not found then
            return
        end
        GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
        GameTooltip:AddLine(found.member.name)
        if next(found.entry.roles or {}) then
            GameTooltip:AddLine(RolesText(found.entry.roles), 1, 1, 1)
        end
        GameTooltip:AddLine(PurposesText(found.entry.purposes), 1.00, 0.82, 0.00)
        for _, dungeon in ipairs(DW.DUNGEONS) do
            if found.entry.dungeons and found.entry.dungeons[dungeon.id] then
                local mine = MyWish() or {}
                if mine[dungeon.id] then
                    GameTooltip:AddLine(DungeonLabel(dungeon), 0.25, 1.00, 0.25)
                else
                    GameTooltip:AddLine(DungeonLabel(dungeon), 1, 1, 1)
                end
            end
        end
        GameTooltip:Show()
    end)
    row:SetScript("OnLeave", function()
        GameTooltip:Hide()
    end)

    rows[index] = row
    return row
end

RefreshPanel = function()
    if not panel or not panel:IsVisible() then
        return
    end
    panel.title:SetText(L.DG_PANEL_TITLE)
    panel.mine.label:SetText(DW.GetMyStatus() == "D" and L.DG_CHANGE or L.DG_JOIN)
    if filterDungeon and not DW.DUNGEON_BY_ID[filterDungeon] then
        filterDungeon = nil
    end
    panel.filter.label:SetText(L.DG_FILTER:format(filterDungeon and DW.DUNGEON_BY_ID[filterDungeon].name or L.DG_ALL))
    local role = filterRole and ROLE_BY_CODE[filterRole]
    panel.roleFilter.label:SetText(L.DG_ROLE_FILTER:format(role and (DW.RoleIcon(role) .. " " .. L[role.key]) or L.DG_ALL))
    panel.footer:SetText(L.DG_FOOTER)

    local shown, everyone = Collect()
    for index, found in ipairs(shown) do
        local row = GetRow(index)
        local member = found.member
        local colour = RAID_CLASS_COLORS and RAID_CLASS_COLORS[member.class]
        row.found = found
        row.name:SetText(found.me and L.DG_ME:format(member.name) or member.name)
        if colour then
            row.name:SetTextColor(colour.r, colour.g, colour.b)
        else
            row.name:SetTextColor(1, 1, 1)
        end
        row.roles:SetText(RoleIcons(found.entry.roles, 16))
        row.level:SetText(tostring(member.level))
        row.why:SetText(PurposesText(found.entry.purposes))
        row.dungeons:SetText(DungeonsText(found.entry.dungeons))
        row.whisper.label:SetText(L.DG_WHISPER)
        row.invite.label:SetText(L.DG_INVITE)
        row.whisper:SetShown(not found.me)
        row.invite:SetShown(not found.me)
        row:Show()
    end
    for index = #shown + 1, #rows do
        rows[index].found = nil
        rows[index]:Hide()
    end
    panel.content:SetHeight(math.max(1, #shown * ROW_HEIGHT))

    if #everyone == 0 then
        panel.empty:SetText(L.DG_EMPTY)
    else
        panel.empty:SetText(L.DG_EMPTY_FILTER)
    end
    panel.empty:SetShown(#shown == 0)
end

local refreshQueued = false

local function QueueRefresh()
    if refreshQueued or not panel or not panel:IsVisible() then
        return
    end
    refreshQueued = true
    C_Timer.After(0.25, function()
        refreshQueued = false
        RefreshPanel()
    end)
end

local function CreatePanel(parent)
    local f = CreateFrame("Frame", nil, parent)
    f:SetAllPoints(parent)
    panel = f

    f.title = f:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
    f.title:SetPoint("TOP", 0, -12)

    -- Bli med selv, eller endre hva du har valgt.
    f.mine = DW.CreateButton(f, 200, 26, "gold")
    f.mine:SetPoint("TOPLEFT", 14, -40)
    f.mine:SetScript("OnClick", function()
        DW.OpenDungeonPicker()
    end)

    -- Filter: bare dem som vil ta en bestemt dungeon.
    f.filter = DW.CreateChip(f, 236, 26)
    f.filter:SetPoint("TOPRIGHT", -14, -40)
    f.filter:SetScript("OnClick", function(self)
        OpenFilterMenu(self)
    end)

    -- Filter: bare dem som kan ta en bestemt rolle.
    f.roleFilter = DW.CreateChip(f, 130, 26)
    f.roleFilter:SetPoint("RIGHT", f.filter, "LEFT", -8, 0)
    f.roleFilter:SetScript("OnClick", function(self)
        OpenRoleMenu(self)
    end)

    local scroll = CreateFrame("ScrollFrame", "DragonworldDungeonsScroll", f, "ScrollFrameTemplate")
    scroll:SetPoint("TOPLEFT", 10, -78)
    scroll:SetPoint("BOTTOMRIGHT", -30, 34)
    f.content = CreateFrame("Frame", nil, scroll)
    f.content:SetSize(parent:GetWidth() - 10 - 30, 1)
    scroll:SetScrollChild(f.content)

    f.empty = f:CreateFontString(nil, "OVERLAY", "GameFontDisable")
    f.empty:SetPoint("TOP", scroll, "TOP", 0, -40)
    f.empty:SetWidth(420)

    f.footer = f:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    f.footer:SetPoint("BOTTOMLEFT", 14, 12)
    f.footer:SetPoint("BOTTOMRIGHT", -14, 12)
    f.footer:SetJustifyH("LEFT")
    f.footer:SetWordWrap(false)

    f:SetScript("OnShow", function()
        -- Be spillet om fersk medlemsliste, så "pålogget" stemmer.
        if C_GuildInfo and C_GuildInfo.GuildRoster then
            C_GuildInfo.GuildRoster()
        end
        RefreshPanel()
    end)
    return f
end

OpenTab = function()
    if DW.OpenModule then
        DW.OpenModule(MODULE_ID)
    end
end

-- Hendelser -------------------------------------------------------------------

local frame = CreateFrame("Frame")
frame:SetScript("OnEvent", function()
    if DW.IsMember() then
        QueueRefresh()
    end
end)
pcall(frame.RegisterEvent, frame, "GUILD_ROSTER_UPDATE")

DW.OnStatusChanged(function()
    QueueRefresh()
    RefreshPicker()
end)

DW.OnLanguageChanged(function()
    RefreshPanel()
    RefreshPicker()
end)

-- Modul --------------------------------------------------------------------------

DW.RegisterModule({
    id = MODULE_ID,
    titleKey = "DG_TITLE",
    notesKey = "DG_NOTES",
    icon = "Interface\\Icons\\Ability_DualWield",

    CreatePanel = function(self, parent)
        return CreatePanel(parent)
    end,
})

-- Knappene blinker (Alerts.lua) når noen andre er åpne for en dungeon som
-- passer ditt level (2 levels slingringsmonn), eller ikke har valgt noen, og
-- du ikke har åpnet fanen siden. Står du selv som "Ikke forstyrr", blinker
-- det ikke.
local SLACK = 2

local function WantsMyLevel(entry)
    local level = MyLevel()
    if level <= 0 or not entry.dungeons or next(entry.dungeons) == nil then
        return true
    end
    for id in pairs(entry.dungeons) do
        local dungeon = DW.DUNGEON_BY_ID[id]
        if dungeon and level >= dungeon.min - SLACK and level <= dungeon.max + SLACK then
            return true
        end
    end
    return false
end

-- De som er nye siden tiden since: { { member, entry }, ... }.
local function NewWishes(since)
    local list = {}
    if DW.GetMyStatus() == "C" then
        return list
    end
    for _, found in ipairs(DW.MembersWithStatus("D")) do
        local entry = found.entry
        if not IsMe(found.member) and entry and (entry.time or 0) > since and WantsMyLevel(entry) then
            list[#list + 1] = found
        end
    end
    return list
end

-- Én linje i listen ved knappen: hvem, og de av dungeonene deres som passer
-- ditt level (høyst tre), og hvorfor.
local function WishLine(found)
    local entry, level = found.entry, MyLevel()
    local names = {}
    for _, dungeon in ipairs(DW.DUNGEONS) do
        if entry.dungeons and entry.dungeons[dungeon.id] and level >= dungeon.min - SLACK and level <= dungeon.max + SLACK then
            names[#names + 1] = dungeon.name
        end
    end
    local who = found.member.name
    if next(entry.roles or {}) then
        who = who .. " " .. RoleIcons(entry.roles)
    end
    if #names == 0 then
        return L.AL_DUNGEON_ANY:format(who)
    end
    if #names > 3 then
        names = { names[1], names[2], names[3], "+" .. (#names - 3) }
    end
    local text = L.AL_DUNGEON_ITEM:format(who, table.concat(names, ", "))
    if entry.purposes and next(entry.purposes) then
        text = text .. " (" .. PurposesText(entry.purposes) .. ")"
    end
    return text
end

DW.RegisterAlert({
    kind = "dungeon",
    module = MODULE_ID,
    labelKey = "AL_DUNGEON",
    color = { 0.30, 1.00, 0.45 }, -- grønn
    Check = function(since)
        return #NewWishes(since) > 0
    end,
    Items = function(since)
        local items = {}
        for _, found in ipairs(NewWishes(since)) do
            items[#items + 1] = WishLine(found)
        end
        return items
    end,
})
