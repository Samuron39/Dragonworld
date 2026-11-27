-- Dragonworld - Home ("While you were away")
--
-- The first tab. It shows what has changed in the guild since you last
-- played: announcements, a new message of the day, events, polls,
-- milestones, level-ups, members who joined or left, suggestions, the guild
-- bank's gold, and who is online now. Every line can be clicked: a member
-- opens the member card, anything else opens the right tab. A green dot
-- before a line means someone it is about is online now, so a Gratz! or a
-- whisper reaches them.
--
-- The sections come from the modules themselves (DW.RegisterHomeSection in
-- Core.lua): announcements in Kunngjoringer.lua, the message of the day in
-- Guildchat.lua, events in Events.lua, polls and suggestions in Forslag.lua,
-- milestones in Achievements.lua, the gold in Guildbank.lua. Levels, members
-- and who is online are made here, from the game's member list compared with
-- the one saved when you last logged out.
--
-- After three or more days away, one line in chat about 30 seconds after
-- login sums it up, with an [Open] link.
--
-- Nothing is sent to anyone, and nothing new is stored about others: only the
-- member list (level, name, class) and a few values from the modules, saved
-- at logout so the next session has something to compare with.
--
-- Saved (DragonworldDB.modules.home, shared by the whole account):
--   lastActive  server time of the last logout on a guild character
--   since       the time this session compares with (nil the first time)
--   snap        { at, roster = { [key] = { level, name, class } },
--                 sections = { [id] = value } }, written at logout
--   before      the snap that was current when this session started
--   chat        false when the chat summary is turned off
--   chatFor     the since value already summed up in chat
-- key is the member's GUID ("Player-...") or "name:" .. the name key.
--
-- All text is in Locales.lua (the names that start with HOME_).

local ADDON_NAME, DW = ...
local L = DW.L

local MODULE_ID = "home"
local SESSION_GAP = 600     -- offline this long (seconds) counts as a new session
local CHAT_DAYS = 3         -- the chat summary after this many days away
local CHAT_DELAY = 30       -- seconds after login
local CHAT_PARTS = 5        -- sections named in the chat line at most
local MAX_LINES = 6         -- lines per section before "...and N more"
local ROW = 24
local HEADER_GAP = 6
local TICK = 4              -- refresh while shown (the "time ago" texts)
local MAX_LEVEL = 60
local LINK = "addon:" .. ADDON_NAME .. ":home"

local db = {}
local newSession = false
local chatPlanned = false
local printedErrors = {}    -- [section id] = true once its error is printed this session
local providerErrors = {}   -- [section id] = the last error, for /dw debug
local expanded = {}         -- [section id] = true when all its lines are shown
local liveRoster = {}       -- the last member list read that was not empty
local byGuid, byName = {}, {}
local leftSuppressed = false
local linkSupported = false
local panel
local rows = {}
local Refresh

-- Small things ------------------------------------------------------------------

local function Now()
    return DW.ServerNow()
end

local function KeyOf(member)
    if type(member.guid) == "string" and member.guid:find("^Player%-") then
        return member.guid
    end
    return "name:" .. DW.NameKey(member.key)
end

local function IsMe(member)
    local guid = DW.MyGUID()
    if guid and member.guid == guid then
        return true
    end
    local name = DW.CharacterKey()
    return not member.guid and name ~= nil and DW.SameCharacter(member.key, name)
end

-- "5 min ago", "3 hours ago" ... or the date when it is a long time ago.
local function Ago(when)
    local seconds = math.max(0, Now() - (when or 0))
    if seconds < 60 then
        return L.GC_AGO_NOW
    elseif seconds < 3600 then
        return L.ACH_AGO_MINUTES:format(math.floor(seconds / 60))
    elseif seconds < 86400 then
        return L.GC_AGO_HOURS:format(math.floor(seconds / 3600))
    elseif seconds < 7 * 86400 then
        return L.GC_AGO_DAYS:format(math.floor(seconds / 86400))
    end
    return date("%d.%m.%Y", when)
end

local function Trim(text)
    return ((tostring(text or "")):gsub("^%s+", ""):gsub("%s+$", ""))
end

-- The member list -----------------------------------------------------------------

-- Reads the game's member list. An empty answer (the list is not loaded
-- yet) keeps the last one, so nobody seems to have left.
local function ReadRoster()
    if not DW.IsMember() then
        return
    end
    local list = DW.ReadGuildRoster()
    if #list == 0 then
        return
    end
    liveRoster = list
    byGuid, byName = {}, {}
    for _, member in ipairs(list) do
        if member.guid then
            byGuid[member.guid] = member
        end
        byName[DW.NameKey(member.key)] = byName[DW.NameKey(member.key)] or member
    end
end

-- A roster row by "Player-" GUID, "name:x" or "Name-Realm".
local function Member(key)
    if type(key) ~= "string" or key == "" then
        return nil
    end
    if key:find("^Player%-") then
        return byGuid[key]
    end
    local nameKey = key:match("^name:(.+)$")
    return byName[nameKey or DW.NameKey(key)]
end

-- The roster row a member's player is on right now: the member's own row, or
-- the linked character (Alts.lua) they are playing. nil when they are
-- offline, and for yourself.
local function OnlineRow(member)
    if type(member) ~= "table" then
        return nil
    end
    local row = member.online == true and member or nil
    if not row then
        local group = DW.AltGroupOf and DW.AltGroupOf(member)
        row = group and group.online and group.recent or nil
    end
    if not row or IsMe(row) then
        return nil
    end
    return row
end

-- What the green dot's tooltip says when someone the line is about is online
-- now, or nil when nobody is (no dot). A line names its people in member (one
-- roster row) or members (several).
local function OnlineText(line)
    if line.noDot then
        return nil
    end
    if type(line.members) == "table" then
        local names = {}
        for _, member in ipairs(line.members) do
            if OnlineRow(member) then
                names[#names + 1] = tostring(member.name or "?")
            end
        end
        return #names > 0 and L.HOME_ONLINE_WHO:format(table.concat(names, ", ")) or nil
    end
    local row = OnlineRow(line.member)
    if not row then
        return nil
    elseif row == line.member then
        return L.HOME_SEC_ONLINE
    end
    return L.MC_ONLINE_AS:format(tostring(row.name or "?"))
end

local function Baseline()
    local before = db.before
    if type(before) == "table" and type(before.roster) == "table" and next(before.roster) ~= nil then
        return before.roster
    end
    return nil
end

-- Name -> GUID key for the baseline entries saved under a "Player-" GUID,
-- built once per Lines call.
local function BaselineNames(baseline)
    local names = {}
    for key, entry in pairs(baseline) do
        if type(key) == "string" and key:find("^Player%-") and type(entry) == "table" then
            local name = DW.NameKey(entry[2])
            if name ~= "" then
                names[name] = key
            end
        end
    end
    return names
end

-- The baseline key a live member was saved under: the same key, or the name
-- when one of the two was saved without a GUID (either side).
local function BaselineKey(baseline, member, names)
    local key = KeyOf(member)
    if baseline[key] then
        return key
    end
    local nameKey = DW.NameKey(member.key)
    local byNameKey = "name:" .. nameKey
    if baseline[byNameKey] then
        return byNameKey
    end
    -- The live row has no GUID (not given, or a secret value) but the
    -- member was saved under one.
    if names and nameKey ~= "" and not (type(member.guid) == "string" and member.guid:find("^Player%-")) then
        return names[nameKey]
    end
    return nil
end

local function Context(section)
    local before = db.before
    local sections = type(before) == "table" and type(before.sections) == "table" and before.sections or nil
    return {
        since = db.since,
        now = Now(),
        before = sections and sections[section.id],
        hasRosterBaseline = Baseline() ~= nil,
        Member = Member,
    }
end

-- Home's own sections ---------------------------------------------------------------

local function LevelLines(ctx)
    local baseline = Baseline()
    if not baseline then
        return {}
    end
    local lines = {}
    local names = BaselineNames(baseline)
    for _, member in ipairs(liveRoster) do
        local key = not IsMe(member) and BaselineKey(baseline, member, names)
        local old = key and baseline[key][1]
        if old and old > 0 and member.level > old then
            local new = tostring(member.level)
            if member.level >= MAX_LEVEL then
                new = "|cffffd100" .. new .. "|r"
            end
            lines[#lines + 1] = {
                text = L.HOME_LEVEL:format(DW.ColoredName(member.name, member.class), tostring(old), new),
                member = member, changed = true, level = member.level, name = member.name,
            }
        end
    end
    table.sort(lines, function(a, b)
        if a.level ~= b.level then
            return a.level > b.level
        end
        return a.name < b.name
    end)
    return lines
end

local function MemberLines(ctx)
    local baseline = Baseline()
    if not baseline then
        return {}
    end
    local joined, left, matched = {}, {}, {}
    local names = BaselineNames(baseline)
    for _, member in ipairs(liveRoster) do
        local key = BaselineKey(baseline, member, names)
        if key then
            matched[key] = true
        elseif not IsMe(member) then
            joined[#joined + 1] = {
                text = L.HOME_JOINED:format(DW.ColoredName(member.name, member.class), member.level),
                member = member, changed = true, name = member.name,
                tip = Trim((member.rank or "") .. " " .. (member.note or "")),
                button = DW.WelcomeButtonFor and DW.WelcomeButtonFor(member) or nil,
            }
        end
    end
    -- A list that is still loading (or cut short) must not make half the
    -- guild seem to have left.
    local total, missing = 0, {}
    for key, entry in pairs(baseline) do
        total = total + 1
        if not matched[key] then
            missing[#missing + 1] = entry
        end
    end
    leftSuppressed = #liveRoster == 0 or #missing > math.max(5, math.floor(0.2 * total))
    if not leftSuppressed then
        for _, entry in ipairs(missing) do
            left[#left + 1] = {
                text = L.HOME_LEFT:format(DW.ColoredName(entry[2], entry[3])),
                muted = true, changed = true, name = entry[2],
            }
        end
    end
    local function ByName(a, b)
        return a.name < b.name
    end
    table.sort(joined, ByName)
    table.sort(left, ByName)
    for _, line in ipairs(left) do
        joined[#joined + 1] = line
    end
    return joined
end

local function OnlineLines(ctx)
    local lines = {}
    for _, member in ipairs(liveRoster) do
        if member.online and not IsMe(member) then
            local name = DW.ColoredName(member.name, member.class)
            local main = DW.MainOf and DW.MainOf(member)
            if type(main) == "table" and main ~= member and main.guid ~= member.guid then
                name = L.HOME_ALT_OF:format(name, main.name)
            end
            local code = DW.StatusOf and DW.StatusOf(member)
            local status = code and DW.STATUS_BY_CODE and DW.STATUS_BY_CODE[code]
            local icon = status and ("|T" .. status.icon .. ":14:14|t ") or ""
            local text
            if member.zone ~= "" then
                text = L.HOME_ONLINE_ROW:format(name, member.level, member.zone)
            else
                text = L.HOME_ONLINE_ROW_NOZONE:format(name, member.level)
            end
            -- No dot here: everyone in this section is online.
            lines[#lines + 1] = { text = icon .. text, member = member, changed = false, name = member.name, noDot = true }
        end
    end
    table.sort(lines, function(a, b)
        return a.name < b.name
    end)
    if #lines == 0 then
        lines[1] = { text = L.HOME_NONE_ONLINE, muted = true, placeholder = true }
    end
    return lines
end

DW.RegisterHomeSection({ id = "levels", order = 40, titleKey = "HOME_SEC_LEVELS", icon = "Interface\\GossipFrame\\TrainerGossipIcon", Lines = LevelLines })
DW.RegisterHomeSection({ id = "members", order = 50, titleKey = "HOME_SEC_MEMBERS", icon = "Interface\\Icons\\INV_Banner_02", Lines = MemberLines })
DW.RegisterHomeSection({ id = "online", order = 90, titleKey = "HOME_SEC_ONLINE", icon = "Interface\\FriendsFrame\\StatusIcon-Online", Lines = OnlineLines })

-- Collecting the sections -------------------------------------------------------------

local function SortedSections()
    local list = {}
    for _, section in ipairs(DW.HOME_SECTIONS) do
        list[#list + 1] = section
    end
    table.sort(list, function(a, b)
        if (a.order or 999) ~= (b.order or 999) then
            return (a.order or 999) < (b.order or 999)
        end
        return a.id < b.id
    end)
    return list
end

-- Each section's lines: { { section, lines }, ... }, without the empty ones.
-- A section whose Lines fails is left out, and its error is printed once per
-- session.
local function Collect()
    local result = {}
    for _, section in ipairs(SortedSections()) do
        local ok, lines = pcall(section.Lines, Context(section))
        if not ok then
            providerErrors[section.id] = lines
            if not printedErrors[section.id] then
                printedErrors[section.id] = true
                DW.PrintError(L.ERROR, lines)
            end
        elseif type(lines) == "table" then
            local valid = {}
            for _, line in ipairs(lines) do
                if type(line) == "table" and type(line.text) == "string" then
                    valid[#valid + 1] = line
                end
            end
            if #valid > 0 then
                result[#result + 1] = { section = section, lines = valid }
            end
        end
    end
    return result
end

local function ChangedCount(lines)
    local count = 0
    for _, line in ipairs(lines) do
        if line.changed == true then
            count = count + 1
        end
    end
    return count
end

-- The panel -----------------------------------------------------------------------

local function Tooltip(row)
    local line = row.line
    if not line then
        return
    end
    local text = line.tip
    if not text or text == "" then
        if line.member then
            text = L.HOME_TIP_CARD
        elseif line.tab and DW.modules[line.tab] then
            text = L.HOME_TIP_TAB:format(DW.ModuleTitle(DW.modules[line.tab]))
        end
    end
    local hasText = text ~= nil and text ~= ""
    if hasText or row.onlineText then
        GameTooltip:SetOwner(row, "ANCHOR_RIGHT")
        if row.onlineText then
            GameTooltip:AddLine(row.onlineText, 0.25, 1.00, 0.25, true)
        end
        if hasText then
            GameTooltip:AddLine(text, 1, 1, 1, true)
        end
        GameTooltip:Show()
    end
end

local function ClickRow(row)
    if row.more then
        expanded[row.more] = true
    elseif row.line and not row.line.muted then
        local line = row.line
        if line.member then
            if DW.ShowMemberCard then
                DW.ShowMemberCard(DW.AltCardRow and DW.AltCardRow(line.member) or line.member)
            end
        elseif type(line.onClick) == "function" then
            line.onClick()
        end
    end
    Refresh()
end

local function GetRow(index)
    local row = rows[index]
    if row then
        return row
    end
    row = CreateFrame("Button", nil, panel.content)
    row:SetSize(panel.content:GetWidth(), ROW)

    row.hover = row:CreateTexture(nil, "BACKGROUND")
    row.hover:SetAllPoints(row)
    row.hover:SetColorTexture(1, 1, 1, 0.06)
    row.hover:Hide()

    row.icon = row:CreateTexture(nil, "ARTWORK")

    -- The green dot, in the margin before the line: someone it is about is
    -- online now.
    row.dot = row:CreateTexture(nil, "ARTWORK")
    row.dot:SetSize(12, 12)
    row.dot:SetPoint("LEFT", 6, 0)
    row.dot:SetTexture("Interface\\FriendsFrame\\StatusIcon-Online")
    row.dot:Hide()

    row.button = DW.CreateButton(row, 74, 20, "gold")
    row.button:SetPoint("RIGHT", -4, 0)
    row.button:SetScript("OnClick", function(self)
        local line = self:GetParent().line
        if line and line.button and type(line.button.onClick) == "function" then
            line.button.onClick()
        end
        Refresh()
    end)

    row.when = row:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
    row.when:SetWidth(100)
    row.when:SetJustifyH("RIGHT")
    row.when:SetWordWrap(false)

    row.text = row:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
    row.text:SetJustifyH("LEFT")
    row.text:SetWordWrap(false)

    row:SetScript("OnEnter", function(self)
        if self.clickable then
            self.hover:Show()
            Tooltip(self)
        end
    end)
    row:SetScript("OnLeave", function(self)
        self.hover:Hide()
        GameTooltip:Hide()
    end)
    row:SetScript("OnClick", function(self)
        if self.clickable then
            ClickRow(self)
        end
    end)

    rows[index] = row
    return row
end

-- Places one row: kind is "header", "line", "more" or "nothing".
local function FillRow(index, y, kind, data)
    local row = GetRow(index)
    row:ClearAllPoints()
    row:SetPoint("TOPLEFT", 0, -y)
    row.kind, row.line, row.more, row.section = kind, nil, nil, nil
    row.onlineText = nil
    row.dot:Hide()
    row.hover:Hide()
    row.icon:ClearAllPoints()
    row.text:ClearAllPoints()
    row.when:ClearAllPoints()
    row.when:SetText("")
    row.button:Hide()

    local left = 22
    local right = -4
    if kind == "header" then
        row.section = data.section.id
        row.icon:SetSize(18, 18)
        row.icon:SetPoint("LEFT", 0, 0)
        row.icon:SetTexCoord(0, 1, 0, 1)
        row.icon:SetTexture(data.section.icon or DW.ICON)
        row.icon:Show()
        left = 24
        local count = 0
        for _, line in ipairs(data.lines) do
            if not line.placeholder then
                count = count + 1
            end
        end
        row.text:SetText(L.HOME_SEC_COUNT:format(data.section.titleKey and L[data.section.titleKey] or data.section.id, count))
        row.text:SetTextColor(1.00, 0.82, 0.00)
        row.clickable = false
    elseif kind == "line" then
        local line = data
        row.line = line
        row.onlineText = OnlineText(line)
        row.dot:SetShown(row.onlineText ~= nil)
        if line.icon then
            row.icon:SetSize(16, 16)
            row.icon:SetPoint("LEFT", 22, 0)
            row.icon:SetTexCoord(0.07, 0.93, 0.07, 0.93)
            row.icon:SetTexture(line.icon)
            row.icon:Show()
            left = 42
        else
            row.icon:Hide()
        end
        if line.button and type(line.button.text) == "string" then
            row.button.label:SetText(line.button.text)
            row.button:Show()
            right = -84 -- the time moves left of the button
        end
        if type(line.when) == "number" then
            row.when:SetPoint("RIGHT", right, 0)
            row.when:SetText(Ago(line.when))
            right = right - 104
        end
        row.text:SetText(line.text)
        if line.muted then
            row.text:SetTextColor(0.6, 0.6, 0.6)
        else
            row.text:SetTextColor(1, 1, 1)
        end
        row.clickable = not line.muted and (line.member ~= nil or type(line.onClick) == "function")
    elseif kind == "more" then
        row.more = data.id
        row.icon:Hide()
        row.text:SetText(L.HOME_MORE:format(data.count))
        row.text:SetTextColor(0.80, 0.80, 0.80)
        row.clickable = true
    else
        row.icon:Hide()
        row.text:SetText(L.HOME_NOTHING)
        row.text:SetTextColor(0.6, 0.6, 0.6)
        row.clickable = false
    end
    row.text:SetPoint("LEFT", left, 0)
    row.text:SetPoint("RIGHT", right, 0)
    row:Show()
    -- A refresh under a resting mouse: OnEnter does not fire again, so keep
    -- the highlight, and show the tooltip of the line the row holds now.
    if row:IsMouseOver() then
        if row.clickable then
            row.hover:Show()
            if GameTooltip:IsOwned(row) then
                Tooltip(row)
            end
        elseif GameTooltip:IsOwned(row) then
            GameTooltip:Hide()
        end
    end
    return row
end

Refresh = function()
    if not panel or not panel:IsVisible() then
        return
    end
    panel.title:SetText(L.HOME_PANEL_TITLE)
    if db.since then
        panel.since:SetText(L.HOME_SINCE:format(date("%d.%m.%Y %H:%M", db.since), Ago(db.since)))
    else
        panel.since:SetText(L.HOME_FIRST)
    end
    panel.chatCheck:SetChecked(db.chat ~= false)
    panel.chatLabel:SetText(L.HOME_CHAT_OPTION:format(CHAT_DAYS))

    local collected = Collect()
    local index, y = 0, 0
    local anyChanged = false
    for _, item in ipairs(collected) do
        if ChangedCount(item.lines) > 0 then
            anyChanged = true
        end
    end
    if db.since and not anyChanged then
        index = index + 1
        FillRow(index, y, "nothing")
        y = y + ROW
    end
    for position, item in ipairs(collected) do
        if position > 1 or index > 0 then
            y = y + HEADER_GAP
        end
        index = index + 1
        FillRow(index, y, "header", item)
        y = y + ROW
        local count = #item.lines
        local shown = (expanded[item.section.id] or count <= MAX_LINES) and count or MAX_LINES
        for lineIndex = 1, shown do
            index = index + 1
            FillRow(index, y, "line", item.lines[lineIndex])
            y = y + ROW
        end
        if shown < count then
            index = index + 1
            FillRow(index, y, "more", { id = item.section.id, count = count - shown })
            y = y + ROW
        end
    end
    for extra = index + 1, #rows do
        rows[extra]:Hide()
        rows[extra].line, rows[extra].more = nil, nil
    end
    panel.content:SetHeight(math.max(1, y))
end

local refreshQueued = false

-- A refresh a moment from now, when the page is shown (several changes at
-- once give one refresh).
function DW.RefreshHome()
    if refreshQueued or not panel or not panel:IsVisible() or not (C_Timer and C_Timer.After) then
        return
    end
    refreshQueued = true
    C_Timer.After(0.25, function()
        refreshQueued = false
        Refresh()
    end)
end

local ticking = false

-- Keeps the "time ago" texts and who is online right while the page is shown.
local function StartTicking()
    if ticking or not (C_Timer and C_Timer.After) then
        return
    end
    ticking = true
    local function Tick()
        if not panel or not panel:IsVisible() then
            ticking = false
            return
        end
        Refresh()
        C_Timer.After(TICK, Tick)
    end
    C_Timer.After(TICK, Tick)
end

local function CreatePanel(parent)
    local f = CreateFrame("Frame", nil, parent)
    f:SetAllPoints(parent)
    panel = f

    f.title = f:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
    f.title:SetPoint("TOP", 0, -12)

    f.since = f:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    f.since:SetPoint("TOP", 0, -34)

    local scroll = CreateFrame("ScrollFrame", "DragonworldHomeScroll", f, "ScrollFrameTemplate")
    scroll:SetPoint("TOPLEFT", 10, -56)
    scroll:SetPoint("BOTTOMRIGHT", -30, 42)
    f.scroll = scroll
    f.content = CreateFrame("Frame", nil, scroll)
    f.content:SetSize(parent:GetWidth() - 10 - 30, 1)
    scroll:SetScrollChild(f.content)

    -- The chat summary on/off.
    f.chatCheck = CreateFrame("CheckButton", nil, f, "UICheckButtonTemplate")
    f.chatCheck:SetSize(24, 24)
    f.chatCheck:SetPoint("BOTTOMLEFT", 12, 10)
    f.chatCheck:SetScript("OnClick", function(self)
        if self:GetChecked() then
            db.chat = nil
        else
            db.chat = false
        end
    end)
    f.chatLabel = f:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
    f.chatLabel:SetPoint("LEFT", f.chatCheck, "RIGHT", 4, 0)
    f.chatLabel:SetJustifyH("LEFT")

    f:SetScript("OnShow", function()
        expanded = {}
        ReadRoster()
        if C_GuildInfo and C_GuildInfo.GuildRoster then
            C_GuildInfo.GuildRoster()
        end
        Refresh()
        StartTicking()
    end)
    return f
end

-- The chat summary ------------------------------------------------------------------

local function ChatLink()
    if linkSupported then
        return "|cffffd100|H" .. LINK .. "|h[" .. L.HOME_CHAT_OPEN .. "]|h|r"
    end
    return "(/dw " .. MODULE_ID .. ")"
end

local function FireChat()
    local now = Now()
    local since = db.since
    if not DW.IsMember() or not newSession or db.chat == false or type(since) ~= "number"
        or now - since < CHAT_DAYS * 86400 or db.chatFor == since then
        return
    end
    ReadRoster()
    local parts = {}
    for _, item in ipairs(Collect()) do
        local count = ChangedCount(item.lines)
        if count > 0 and #parts < CHAT_PARTS then
            parts[#parts + 1] = L.HOME_SUM:format(item.section.titleKey and L[item.section.titleKey] or item.section.id, count)
        end
    end
    if #parts == 0 then
        return
    end
    DW.Print(L.HOME_CHAT:format(math.floor((now - since) / 86400), table.concat(parts, ", ")) .. " " .. ChatLink())
    db.chatFor = since
end

local function PlanChat()
    if chatPlanned or not (C_Timer and C_Timer.After) then
        return
    end
    chatPlanned = true
    C_Timer.After(CHAT_DELAY, FireChat)
end

-- The [Open] link: the game's addon links ("|Haddon:...|h") are announced
-- through EventRegistry's "SetItemRef" with the bare link (checked in the
-- Forever UI source). Without it the line ends in "(/dw home)".
if EventRegistry and type(EventRegistry.RegisterCallback) == "function" then
    local homeOwner = {}
    local ok = pcall(EventRegistry.RegisterCallback, EventRegistry, "SetItemRef", function(_, link)
        if link == LINK and DW.IsMember() and DW.OpenModule then
            DW.OpenModule(MODULE_ID)
        end
    end, homeOwner)
    linkSupported = ok
end

-- Events ----------------------------------------------------------------------------

local rosterQueued, rosterRefreshQueued = false, false

local function QueueRosterRead()
    if rosterQueued or not (C_Timer and C_Timer.After) then
        return
    end
    rosterQueued = true
    C_Timer.After(1.5, function()
        rosterQueued = false
        ReadRoster()
        Refresh() -- only when the page is shown
    end)
end

local function SaveSnapshot()
    local now = Now()
    db.lastActive = now
    local old = type(db.snap) == "table" and db.snap or {}
    local snap = { at = now, roster = old.roster, sections = {} }
    if #liveRoster > 0 then
        snap.roster = {}
        for _, member in ipairs(liveRoster) do
            snap.roster[KeyOf(member)] = { member.level, member.name, member.class }
        end
    end
    for _, section in ipairs(DW.HOME_SECTIONS) do
        if type(section.Snapshot) == "function" then
            local ok, value = pcall(section.Snapshot)
            -- A provider with nothing yet (for example the message of the day
            -- not read this session) keeps the last session's value.
            if ok and value == nil and type(old.sections) == "table" then
                value = old.sections[section.id]
            end
            if ok then
                snap.sections[section.id] = value
            end
        end
    end
    db.snap = snap
end

local frame = CreateFrame("Frame")
frame:SetScript("OnEvent", function(self, event)
    if not DW.IsMember() then
        return
    end
    if event == "PLAYER_LOGOUT" then
        SaveSnapshot()
    elseif event == "GUILD_ROSTER_UPDATE" then
        QueueRosterRead()
        if panel and panel:IsVisible() and not rosterRefreshQueued and C_Timer and C_Timer.After then
            rosterRefreshQueued = true
            C_Timer.After(0.6, function()
                rosterRefreshQueued = false
                Refresh()
            end)
        end
    elseif event == "PLAYER_ENTERING_WORLD" then
        ReadRoster()
        PlanChat()
    end
end)
for _, event in ipairs({ "PLAYER_LOGOUT", "GUILD_ROSTER_UPDATE", "PLAYER_ENTERING_WORLD" }) do
    pcall(frame.RegisterEvent, frame, event)
end

DW.OnMembershipChanged(function(member)
    if member then
        ReadRoster()
        PlanChat()
    end
end)

DW.OnLanguageChanged(function()
    Refresh()
end)

DW.AddDebug("hjem", function(add)
    local text = DW.DebugText
    local function Count(set)
        local count = 0
        for _ in pairs(type(set) == "table" and set or {}) do
            count = count + 1
        end
        return count
    end
    local snap, before = db.snap, db.before
    add(("lastActive: %s | since: %s | ny økt: %s | snap.at: %s | before.at: %s"):format(text(db.lastActive), text(db.since),
        text(newSession), text(type(snap) == "table" and snap.at), text(type(before) == "table" and before.at)))
    add(("medlemsliste: lagret %d, grunnlag %d, nå %d | forlot skjult: %s"):format(Count(type(snap) == "table" and snap.roster),
        Count(type(before) == "table" and before.roster), #liveRoster, text(leftSuppressed)))
    local parts = {}
    for _, item in ipairs(Collect()) do
        parts[#parts + 1] = ("%s %d/%d"):format(item.section.id, ChangedCount(item.lines), #item.lines)
    end
    add("seksjoner (nye/linjer): " .. (#parts > 0 and table.concat(parts, ", ") or "ingen"))
    local problems = {}
    for id, problem in pairs(providerErrors) do
        problems[#problems + 1] = id .. ": " .. tostring(problem)
    end
    table.sort(problems)
    add("feil: " .. (#problems > 0 and table.concat(problems, " | ") or "ingen"))
    add(("chat: %s | chatFor: %s | linkSupported: %s"):format(text(db.chat ~= false), text(db.chatFor), text(linkSupported)))
end)

-- Module ------------------------------------------------------------------------------

DW.RegisterModule({
    id = MODULE_ID,
    titleKey = "HOME_TITLE",
    notesKey = "HOME_NOTES",
    icon = "Interface\\Icons\\INV_Misc_PocketWatch_01",

    -- Also called by the tests to act as a new login.
    OnLoad = function(self, saved)
        db = saved
        newSession, chatPlanned = false, false
        printedErrors, expanded = {}, {}
        if type(saved.snap) ~= "table" then
            saved.snap = nil
        end
        if type(saved.before) ~= "table" then
            saved.before = nil
        end
        for _, snap in ipairs({ saved.snap or false, saved.before or false }) do
            if snap then
                if type(snap.roster) ~= "table" then
                    snap.roster = nil
                else
                    for key, entry in pairs(snap.roster) do
                        if type(key) ~= "string" or type(entry) ~= "table" or type(entry[1]) ~= "number"
                            or type(entry[2]) ~= "string" or type(entry[3]) ~= "string" then
                            snap.roster[key] = nil
                        end
                    end
                end
                if type(snap.sections) ~= "table" then
                    snap.sections = {}
                end
            end
        end
        if type(saved.since) ~= "number" then
            saved.since = nil
        end
        local now = Now()
        local syncedUntil = type(DragonworldDB) == "table" and DragonworldDB.syncedUntil
        if type(saved.lastActive) == "number" then
            if now - saved.lastActive >= SESSION_GAP then
                saved.since = saved.lastActive
                saved.before = saved.snap
                newSession = true
            end
            -- Otherwise a /reload or a quick relog: the same session (a clock
            -- that went backwards counts as the same session too).
        elseif type(syncedUntil) == "number" and now - syncedUntil >= SESSION_GAP then
            -- Older versions only knew when the last sync ended.
            saved.since = syncedUntil
            saved.before = nil
            newSession = true
        else
            saved.since = nil
            saved.before = nil
        end
    end,

    CreatePanel = function(self, parent)
        return CreatePanel(parent)
    end,
})
