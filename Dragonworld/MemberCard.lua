-- Dragonworld - medlemskort
-- Klikk på et medlem i Medlemmer, så kommer dette kortet opp over vinduet:
--   * navn, level, klasse, rank, status, hvor de er / når de sist var pålogget
--   * legacy-poeng
--   * rollen (tank, healer, dps; høyst to). På ditt eget kort velger du den.
--   * professions; de som er delt kan åpnes for å se hva medlemmet kan lage
--   * talenter (hvor mange poeng i hvert tre; hold over for alle)
--   * utstyret medlemmet har på seg (hold over en gjenstand for detaljer)
--   * "om meg": en tekst medlemmet har skrevet om seg selv, som alle med
--     addonen ser. På ditt eget kort skriver du din.
--   * dine egne notater om medlemmet. De lagres bare hos deg og deles ikke.
-- Knapper: Inspiser (spillets eget vindu, når medlemmet er target eller i
-- gruppen og i nærheten), Hvisk og Inviter.
--
-- Legacy-poeng, talenter og utstyr kommer fra medlemmets egen addon
-- (Profile.lua). Har medlemmet ikke addonen, eller har dere aldri vært
-- pålogget samtidig, står det at det ikke er delt ennå.
--
-- All tekst ligger i Locales.lua (navnene som begynner med MC_).

local ADDON_NAME, DW = ...
local L = DW.L

local CARD_NAME = "DragonworldMemberCard"
local LEFT_WIDTH, RIGHT_X = 380, 420
local GEAR_ROW = 18
local MAX_NOTE_LETTERS = 500
local MAX_ABOUT_LETTERS = 300

-- Spillets egne navn på plassene, i plass-rekkefølge (1 = hode, 19 = tabard).
local SLOT_NAMES = {
    "HEADSLOT", "NECKSLOT", "SHOULDERSLOT", "SHIRTSLOT", "CHESTSLOT", "WAISTSLOT", "LEGSSLOT", "FEETSLOT",
    "WRISTSLOT", "HANDSSLOT", "FINGER0SLOT", "FINGER1SLOT", "TRINKET0SLOT", "TRINKET1SLOT", "BACKSLOT",
    "MAINHANDSLOT", "SECONDARYHANDSLOT", "RANGEDSLOT", "TABARDSLOT",
}

local card
local current -- medlemmet som vises

-- Småting -----------------------------------------------------------------------

local function NoteKey(member)
    return member.guid or ("name:" .. DW.NameKey(member.key))
end

-- Dine notater: DragonworldDB.notes[nøkkel] = tekst. Felles for kontoen.
local function Notes()
    if type(DragonworldDB) ~= "table" then
        return {}
    end
    if type(DragonworldDB.notes) ~= "table" then
        DragonworldDB.notes = {}
    end
    return DragonworldDB.notes
end

local function IsMe(member)
    local guid = DW.MyGUID()
    if guid and member.guid then
        return member.guid == guid
    end
    local _, name = DW.CharacterKey()
    return name ~= nil and DW.NameKey(member.key) == DW.NameKey(name)
end

local function LastSeenText(member)
    if member.online then
        return member.zone ~= "" and L.MC_ONLINE_IN:format(member.zone) or L.MC_ONLINE
    end
    if (member.days or 0) > 0 then
        return L.MC_LAST_DAYS:format(member.days)
    end
    return L.MC_LAST_HOURS:format(member.hours or 0)
end

-- En gjenstand fra koden i profilen: navn, kvalitet og ikon (navnet kan mangle
-- til spillet har lastet gjenstanden).
local waitingFor = {}

local function ItemInfo(code)
    local itemID = tonumber(code:match("^(%d+)"))
    local name, _, quality = C_Item.GetItemInfo("item:" .. code)
    local icon = itemID and select(5, C_Item.GetItemInfoInstant(itemID))
    if type(name) ~= "string" and itemID and not waitingFor[itemID] then
        waitingFor[itemID] = true
        if C_Item.RequestLoadItemDataByID then
            C_Item.RequestLoadItemDataByID(itemID)
        end
    end
    return type(name) == "string" and name or ("item:" .. tostring(itemID)), quality, icon, itemID
end

-- Finner en "unit" for medlemmet, så spillet kan inspisere: target, den du
-- holder musa over, eller noen i gruppen.
local function UnitFor(member)
    if type(UnitExists) ~= "function" or type(UnitGUID) ~= "function" or not member.guid then
        return nil
    end
    local units = { "target", "mouseover" }
    for index = 1, 4 do
        units[#units + 1] = "party" .. index
    end
    for index = 1, 40 do
        units[#units + 1] = "raid" .. index
    end
    for _, unit in ipairs(units) do
        if UnitExists(unit) and UnitGUID(unit) == member.guid then
            return unit
        end
    end
    return nil
end

local function Inspect(member)
    local unit = UnitFor(member)
    if unit and type(InspectUnit) == "function" and (type(CanInspect) ~= "function" or CanInspect(unit)) then
        InspectUnit(unit)
        return true
    end
    DW.Print(L.MC_INSPECT_HINT:format(member.name))
    return false
end

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

-- Visning ---------------------------------------------------------------------

local function Heading(parent, x, y)
    local text = parent:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    text:SetPoint("TOPLEFT", x, y)
    return text
end

local function GetGearRow(index)
    local row = card.gearRows[index]
    if row then
        return row
    end
    row = CreateFrame("Frame", nil, card)
    row:SetSize(card:GetWidth() - RIGHT_X - 16, GEAR_ROW)
    row:SetPoint("TOPLEFT", RIGHT_X, -36 - (index - 1) * GEAR_ROW)
    row:EnableMouse(true)

    row.slot = row:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
    row.slot:SetPoint("LEFT", 0, 0)
    row.slot:SetWidth(84)
    row.slot:SetJustifyH("LEFT")
    row.slot:SetWordWrap(false)

    row.icon = row:CreateTexture(nil, "ARTWORK")
    row.icon:SetSize(16, 16)
    row.icon:SetPoint("LEFT", row.slot, "RIGHT", 4, 0)
    row.icon:SetTexCoord(0.07, 0.93, 0.07, 0.93)

    row.name = row:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    row.name:SetPoint("LEFT", row.icon, "RIGHT", 6, 0)
    row.name:SetPoint("RIGHT", 0, 0)
    row.name:SetJustifyH("LEFT")
    row.name:SetWordWrap(false)

    row:SetScript("OnEnter", function(self)
        if not self.code then
            return
        end
        GameTooltip:SetOwner(self, "ANCHOR_LEFT")
        if GameTooltip.SetHyperlink then
            GameTooltip:SetHyperlink("item:" .. self.code)
        else
            GameTooltip:SetItemByID(self.itemID)
        end
        GameTooltip:Show()
    end)
    row:SetScript("OnLeave", function()
        GameTooltip:Hide()
    end)

    card.gearRows[index] = row
    return row
end

-- Professions står i to kolonner (to rader), eller i tre kolonner med
-- mindre skrift når medlemmet har flere enn fire.
local MAX_CARD_PROFESSIONS = 6

local function GetProfessionChip(index)
    local chip = card.professionChips[index]
    if chip then
        return chip
    end
    chip = DW.CreateChip(card, 100, 22)
    chip:SetScript("OnClick", function(self)
        if not (current and self.profession and self.linked) then
            return
        end
        if DW.ShowMemberProfession then
            DW.ShowMemberProfession(current, self.profession)
        elseif DW.OpenMemberProfession then
            DW.OpenMemberProfession(current, self.profession)
        end
    end)
    chip:HookScript("OnEnter", function(self)
        GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
        if self.fullText then
            GameTooltip:AddLine(self.fullText, 1.00, 0.82, 0.00)
        end
        local text = L.MC_PROFESSION_NOT_SHARED
        if self.linked then
            text = L.MC_PROFESSION_OPEN
        elseif self.gathering then
            text = L.RO_TIP_GATHER
        end
        GameTooltip:AddLine(text, 1, 1, 1, true)
        GameTooltip:Show()
    end)
    chip:HookScript("OnLeave", function()
        GameTooltip:Hide()
    end)
    card.professionChips[index] = chip
    return chip
end

local function RefreshCard()
    if not card or not card:IsShown() or not current then
        return
    end
    local member = current
    local colour = RAID_CLASS_COLORS and RAID_CLASS_COLORS[member.class]
    card.name:SetText(member.name)
    if colour then
        card.name:SetTextColor(colour.r, colour.g, colour.b)
    else
        card.name:SetTextColor(1, 1, 1)
    end
    card.info:SetText(L.MC_INFO:format(member.level, member.rank))

    local statusCode = member.online and DW.StatusOf and DW.StatusOf(member)
    local status = statusCode and DW.STATUS_BY_CODE[statusCode]
    card.seen:SetText(LastSeenText(member) .. (status and ("  -  " .. L[status.key]) or ""))

    -- Legacy-poeng, som i spillets eget vindu: "2 / 65".
    local points, max = DW.LegacyPointsOf(member)
    local pointsText = points and (max and ("%d / %d"):format(points, max) or tostring(points)) or L.MC_UNKNOWN
    card.legacy:SetText(L.MC_LEGACY:format(pointsText))

    -- Rollen.
    card.rolesLabel:SetText(L.MC_ROLE)
    if IsMe(member) then
        card.roleChoice:SetRoles(DW.GetMyRoles())
        card.roleChoice:Show()
        card.rolesText:Hide()
    else
        local roles = DW.RolesOf(member)
        card.rolesText:SetText(roles and DW.RoleNames(roles) or L.MC_ROLE_NONE)
        if roles then
            card.rolesText:SetTextColor(1, 1, 1)
        else
            card.rolesText:SetTextColor(0.55, 0.55, 0.55)
        end
        card.roleChoice:Hide()
        card.rolesText:Show()
    end

    -- Professions.
    card.professionsLabel:SetText(L.MC_PROFESSIONS)
    local professions = member.professions or {}
    local shown = math.min(#professions, MAX_CARD_PROFESSIONS)
    local columns = shown > 4 and 3 or 2
    local width = math.floor((LEFT_WIDTH - (columns - 1) * 6) / columns)
    for index = 1, shown do
        local profession = professions[index]
        local chip = GetProfessionChip(index)
        local linked
        if DW.CanShowMemberProfession then
            linked = DW.CanShowMemberProfession(member, profession) and true or false
        else
            linked = DW.CanOpenMemberProfession and DW.CanOpenMemberProfession(member, profession) or false
        end
        local full = (profession.max or 0) > 0 and ("%s %d/%d"):format(profession.name, profession.level, profession.max)
            or ("%s %d"):format(profession.name, profession.level)
        chip.profession = profession
        chip.linked = linked
        chip.gathering = DW.IsGatheringProfession ~= nil and DW.IsGatheringProfession(profession)
        chip.fullText = full
        chip:SetSize(width, 22)
        chip:ClearAllPoints()
        chip:SetPoint("TOPLEFT", 16 + ((index - 1) % columns) * (width + 6), -148 - math.floor((index - 1) / columns) * 26)
        -- Med tre kolonner er det ikke plass til "/150": den står i tooltipen.
        chip.label:SetFontObject(columns == 3 and "GameFontHighlightSmall" or "GameFontHighlight")
        chip.label:SetText(columns == 3 and ("%s %d"):format(profession.name, profession.level) or full)
        chip:SetDimmed(not linked)
        chip:Show()
    end
    for index = shown + 1, #card.professionChips do
        card.professionChips[index]:Hide()
    end
    card.noProfessions:SetText(L.MC_NO_PROFESSIONS)
    card.noProfessions:SetShown(#professions == 0)

    local profile = DW.ProfileOf(member) or {}

    -- Talenter: poeng per tre. Hold over for alle talentene.
    card.talentsLabel:SetText(L.MC_TALENTS)
    local trees = type(profile.talents) == "table" and profile.talents.trees
    if type(trees) == "table" and #trees > 0 then
        local parts = {}
        for _, tree in ipairs(trees) do
            parts[#parts + 1] = ("%s %d"):format(tree.name, tree.points or 0)
        end
        card.talents:SetText(table.concat(parts, "  /  "))
        card.talentsHover.trees = trees
    else
        card.talents:SetText(L.MC_NOT_SHARED)
        card.talentsHover.trees = nil
    end

    -- Utstyr.
    card.gearLabel:SetText(L.MC_GEAR)
    local items = type(profile.gear) == "table" and type(profile.gear.items) == "table" and profile.gear.items or {}
    local index = 0
    for slot = 1, #SLOT_NAMES do
        local code = items[slot]
        if type(code) == "string" then
            index = index + 1
            local row = GetGearRow(index)
            local name, quality, icon, itemID = ItemInfo(code)
            local qualityColour = ITEM_QUALITY_COLORS and quality and ITEM_QUALITY_COLORS[quality]
            row.code, row.itemID = code, itemID
            row.slot:SetText(_G[SLOT_NAMES[slot]] or tostring(slot))
            row.icon:SetTexture(icon or 134400)
            row.name:SetText(name)
            if qualityColour then
                row.name:SetTextColor(qualityColour.r, qualityColour.g, qualityColour.b)
            else
                row.name:SetTextColor(1, 1, 1)
            end
            row:Show()
        end
    end
    for rest = index + 1, #card.gearRows do
        card.gearRows[rest].code = nil
        card.gearRows[rest]:Hide()
    end
    card.noGear:SetShown(index == 0)
    card.noGear:SetText(L.MC_GEAR_NOT_SHARED)
    if type(profile.gear) == "table" and profile.gear.time then
        card.gearWhen:SetText(L.MC_SHARED_WHEN:format(date("%d.%m.%Y %H:%M", profile.gear.time)))
    else
        card.gearWhen:SetText("")
    end

    -- Om meg.
    if IsMe(member) then
        card.aboutLabel:SetText(L.MC_ABOUT_ME)
        card.aboutBox:Show()
        card.aboutText:Hide()
    else
        local about = type(profile.about) == "table" and profile.about.text or ""
        card.aboutLabel:SetText(L.MC_ABOUT_OTHER:format(member.name))
        card.aboutBox:Hide()
        card.aboutText:SetText(about ~= "" and about or L.MC_ABOUT_EMPTY)
        if about ~= "" then
            card.aboutText:SetTextColor(1, 1, 1)
        else
            card.aboutText:SetTextColor(0.55, 0.55, 0.55)
        end
        card.aboutText:Show()
    end

    -- Notater.
    card.notesLabel:SetText(L.MC_NOTES)

    -- Knapper.
    local me = IsMe(member)
    card.inspect.label:SetText(L.MC_INSPECT)
    card.whisper.label:SetText(L.MC_WHISPER)
    card.invite.label:SetText(L.MC_INVITE)
    card.close.label:SetText(L.MC_CLOSE)
    card.inspect:SetShown(not me)
    card.whisper:SetShown(not me and member.online)
    card.invite:SetShown(not me and member.online)
end

local function CreateCard(window)
    local c = CreateFrame("Frame", CARD_NAME, window, "BackdropTemplate")
    c:SetPoint("TOPLEFT", 14, -92)
    c:SetSize(window:GetWidth() - 28, window:GetHeight() - 92 - 14)
    c:SetFrameStrata("DIALOG")
    c:EnableMouse(true)
    c:SetBackdrop(DW.PANEL_BACKDROP)
    c:SetBackdropColor(0.05, 0.05, 0.07, 1)
    c:SetBackdropBorderColor(1.00, 0.82, 0.00, 1)
    -- Helt tett bakgrunn innenfor kanten, så listen bak ikke skinner gjennom.
    c.solid = c:CreateTexture(nil, "BACKGROUND")
    c.solid:SetPoint("TOPLEFT", 3, -3)
    c.solid:SetPoint("BOTTOMRIGHT", -3, 3)
    c.solid:SetColorTexture(0.05, 0.05, 0.07, 1)
    c.gearRows, c.professionChips = {}, {}
    card = c

    -- Venstre: hvem, legacy, professions, talenter, notater.
    c.name = c:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
    c.name:SetPoint("TOPLEFT", 16, -14)

    c.info = c:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
    c.info:SetPoint("TOPLEFT", 16, -40)
    c.info:SetWidth(LEFT_WIDTH)
    c.info:SetJustifyH("LEFT")

    c.seen = c:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    c.seen:SetPoint("TOPLEFT", 16, -58)
    c.seen:SetWidth(LEFT_WIDTH)
    c.seen:SetJustifyH("LEFT")

    c.legacy = c:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    c.legacy:SetPoint("TOPLEFT", 16, -80)

    -- Rollen: på ditt eget kort velger du den her (lagres med en gang og
    -- sendes til guilden), ellers står rollen medlemmet har valgt.
    c.rolesLabel = Heading(c, 16, -104)
    c.rolesText = c:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
    c.rolesText:SetPoint("TOPLEFT", 80, -104)
    c.rolesText:SetWidth(LEFT_WIDTH - 64)
    c.rolesText:SetJustifyH("LEFT")
    c.roleChoice = DW.CreateRoleChoice(c, 92, 22, 14, function(roles)
        if current and IsMe(current) then
            DW.SetMyRoles(roles)
        end
    end)
    c.roleChoice:SetPoint("TOPLEFT", 80, -99)

    c.professionsLabel = Heading(c, 16, -128)
    c.noProfessions = c:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
    c.noProfessions:SetPoint("TOPLEFT", 16, -148)

    c.talentsLabel = Heading(c, 16, -204)
    c.talents = c:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
    c.talents:SetPoint("TOPLEFT", 16, -222)
    c.talents:SetWidth(LEFT_WIDTH)
    c.talents:SetJustifyH("LEFT")
    c.talents:SetWordWrap(false)
    -- Usynlig felt over talentlinjen: hold over for å se alle talentene.
    c.talentsHover = CreateFrame("Frame", nil, c)
    c.talentsHover:SetPoint("TOPLEFT", 16, -218)
    c.talentsHover:SetSize(LEFT_WIDTH, 20)
    c.talentsHover:EnableMouse(true)
    c.talentsHover:SetScript("OnEnter", function(self)
        if not self.trees then
            return
        end
        GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
        for _, tree in ipairs(self.trees) do
            GameTooltip:AddLine(("%s (%d)"):format(tree.name, tree.points or 0), 1.00, 0.82, 0.00)
            for _, talent in ipairs(tree.talents or {}) do
                GameTooltip:AddLine(("  %s %d"):format(DW.SpellName(talent.spell), talent.rank), 1, 1, 1)
            end
        end
        GameTooltip:Show()
    end)
    c.talentsHover:SetScript("OnLeave", function()
        GameTooltip:Hide()
    end)

    -- "Om meg": på ditt eget kort et felt du skriver i, ellers teksten
    -- medlemmet har skrevet om seg selv.
    c.aboutLabel = Heading(c, 16, -248)
    local aboutHolder = CreateFrame("Frame", nil, c, "BackdropTemplate")
    aboutHolder:SetPoint("TOPLEFT", 16, -264)
    aboutHolder:SetSize(LEFT_WIDTH, 50)
    aboutHolder:SetBackdrop(DW.PANEL_BACKDROP)
    aboutHolder:SetBackdropColor(0, 0, 0, 0.6)
    aboutHolder:SetBackdropBorderColor(0.45, 0.45, 0.45, 1)
    c.aboutText = aboutHolder:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    c.aboutText:SetPoint("TOPLEFT", 8, -6)
    c.aboutText:SetWidth(LEFT_WIDTH - 16)
    c.aboutText:SetJustifyH("LEFT")
    c.aboutBox = CreateFrame("EditBox", nil, aboutHolder)
    c.aboutBox:SetMultiLine(true)
    c.aboutBox:SetFontObject(ChatFontNormal or "ChatFontNormal")
    c.aboutBox:SetPoint("TOPLEFT", 8, -6)
    c.aboutBox:SetSize(LEFT_WIDTH - 16, 38)
    c.aboutBox:SetAutoFocus(false)
    c.aboutBox:SetMaxLetters(MAX_ABOUT_LETTERS)
    c.aboutBox:SetScript("OnEscapePressed", function(self)
        self:ClearFocus()
    end)
    c.aboutBox:HookScript("OnTextChanged", function(self)
        if current and IsMe(current) and not c.loadingNote then
            DW.SetMyAbout(self:GetText() or "")
        end
    end)
    -- Ferdig å skrive: send det til guilden.
    c.aboutBox:SetScript("OnEditFocusLost", function()
        DW.PublishProfile()
    end)
    aboutHolder:EnableMouse(true)
    aboutHolder:SetScript("OnMouseDown", function()
        if c.aboutBox:IsShown() then
            c.aboutBox:SetFocus()
        end
    end)

    c.notesLabel = Heading(c, 16, -322)
    local holder = CreateFrame("Frame", nil, c, "BackdropTemplate")
    holder:SetPoint("TOPLEFT", 16, -338)
    holder:SetSize(LEFT_WIDTH, 52)
    holder:SetBackdrop(DW.PANEL_BACKDROP)
    holder:SetBackdropColor(0, 0, 0, 0.6)
    holder:SetBackdropBorderColor(0.45, 0.45, 0.45, 1)
    c.notes = CreateFrame("EditBox", nil, holder)
    c.notes:SetMultiLine(true)
    c.notes:SetFontObject(ChatFontNormal or "ChatFontNormal")
    c.notes:SetPoint("TOPLEFT", 8, -6)
    c.notes:SetSize(LEFT_WIDTH - 16, 40)
    c.notes:SetAutoFocus(false)
    c.notes:SetMaxLetters(MAX_NOTE_LETTERS)
    c.notes:SetScript("OnEscapePressed", function(self)
        self:ClearFocus()
    end)
    -- Lagres mens du skriver.
    c.notes:HookScript("OnTextChanged", function(self)
        if current and not c.loadingNote then
            local text = self:GetText() or ""
            Notes()[NoteKey(current)] = text ~= "" and text or nil
        end
    end)
    holder:EnableMouse(true)
    holder:SetScript("OnMouseDown", function()
        c.notes:SetFocus()
    end)

    -- Høyre: utstyr.
    c.gearLabel = Heading(c, RIGHT_X, -14)
    c.gearWhen = c:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
    c.gearWhen:SetPoint("LEFT", c.gearLabel, "RIGHT", 10, 0)
    c.noGear = c:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
    c.noGear:SetPoint("TOPLEFT", RIGHT_X, -40)
    c.noGear:SetWidth(c:GetWidth() - RIGHT_X - 16)
    c.noGear:SetJustifyH("LEFT")

    local closeX = CreateFrame("Button", nil, c, "UIPanelCloseButton")
    closeX:SetPoint("TOPRIGHT", -2, -2)

    -- Knapper nederst.
    c.inspect = DW.CreateChip(c, 110, 26)
    c.inspect:SetPoint("BOTTOMLEFT", 16, 12)
    c.inspect.label:SetJustifyH("CENTER")
    c.inspect:SetScript("OnClick", function()
        if current then
            Inspect(current)
        end
    end)
    c.whisper = DW.CreateChip(c, 110, 26)
    c.whisper:SetPoint("LEFT", c.inspect, "RIGHT", 8, 0)
    c.whisper.label:SetJustifyH("CENTER")
    c.whisper:SetScript("OnClick", function()
        if current then
            Whisper(current.key)
        end
    end)
    c.invite = DW.CreateButton(c, 110, 26, "gold")
    c.invite:SetPoint("LEFT", c.whisper, "RIGHT", 8, 0)
    c.invite:SetScript("OnClick", function()
        if current then
            Invite(current.key)
        end
    end)
    c.close = DW.CreateChip(c, 100, 26)
    c.close:SetPoint("BOTTOMRIGHT", -16, 12)
    c.close.label:SetJustifyH("CENTER")
    c.close:SetScript("OnClick", function()
        c:Hide()
    end)

    -- Lukkes kortet, sendes det du har skrevet om deg selv (om noe er endret).
    c:SetScript("OnHide", function()
        DW.PublishProfile()
    end)

    return c
end

-- Viser kortet for et medlem (en rad fra Medlemmer, eller fra DW.ReadGuildRoster()).
function DW.ShowMemberCard(member)
    local window = _G.DragonworldFrame
    if not window or type(member) ~= "table" then
        return
    end
    if not card then
        CreateCard(window)
    end
    -- Bare ett slikt vindu oppå om gangen.
    if _G.DragonworldDungeonPicker then
        _G.DragonworldDungeonPicker:Hide()
    end
    current = member
    card.loadingNote = true
    card.notes:SetText(Notes()[NoteKey(member)] or "")
    card.aboutBox:SetText(IsMe(member) and DW.GetMyAbout() or "")
    card.loadingNote = false
    card:Show()
    RefreshCard()
end

-- Hendelser -------------------------------------------------------------------

local frame = CreateFrame("Frame")
frame:SetScript("OnEvent", function(self, event, itemID)
    if event == "GET_ITEM_INFO_RECEIVED" and type(itemID) == "number" and waitingFor[itemID] then
        waitingFor[itemID] = nil
        RefreshCard()
    end
end)
pcall(frame.RegisterEvent, frame, "GET_ITEM_INFO_RECEIVED")

DW.OnProfileChanged(RefreshCard)
DW.OnStatusChanged(RefreshCard)
DW.OnLanguageChanged(RefreshCard)
DW.OnMembershipChanged(function(member)
    if not member and card then
        card:Hide()
    end
end)
