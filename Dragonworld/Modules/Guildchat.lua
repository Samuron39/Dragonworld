-- Dragonworld - Guild chat and log
-- A tab with the guild chat, whispers and the game's guild log, right under
-- the Roster tab.
--
--   Chat:      the messages in the guild chat, with time of day and the name in
--              class color (click the name to whisper, as in normal chat).
--              The field at the bottom sends to the guild chat. At the top is
--              the message of the day (MOTD). The last 300 messages are kept.
--   Hvisking (whisper): the conversations you have by whisper with anyone,
--              guild member or not: a list on the left (newest on top, with the
--              number of unread), and the whole conversation with the one you
--              pick on the right, with date and time, so you can continue where
--              you left off. The field at the bottom replies. A conversation
--              can be deleted, or opened in its own small window that can be
--              moved and resized (Hviskevinduer, the whisper windows).
--              The last 50 conversations with up to 200 messages each are kept.
--   Logg (log): the game's guild log: who has been invited, joined, left, been
--              kicked out, promoted or demoted, and how long ago. The game
--              sends the log when asked (QueryGuildEventLog), and announces
--              with GUILD_EVENT_LOG_UPDATE.
--
-- Chat and whispers are kept account-wide, only on this PC (in
-- SavedVariables), and are never shared with anyone. Only what arrived while
-- the addon was on is included: the game gives addons no older chat. Whispers
-- via Battle.net are not included.
--
-- The game can make chat "secret" to addons in some situations (e.g. in
-- combat in instances). Such messages can't be read, and are skipped.
--
-- All text is in Locales.lua (the names starting with GC_).

local ADDON_NAME, DW = ...
local L = DW.L

local MODULE_ID = "guildchat"
local MAX_MESSAGES = 300
local MAX_CONVERSATIONS = 50
local MAX_WHISPERS = 200
local MAX_SEND_LETTERS = 255
local LIST_WIDTH = 180
local ROW_HEIGHT = 40

-- Saved data. Set in OnLoad at the bottom.
--   db.messages = { { t = time (local clock), from = "Name-Realm", text }, ... }, oldest first
--   db.whispers[key] = {
--       name   = the name as the game last gave it (used when you reply),
--       last   = the time of the last message, unread = number of unread,
--       messages = { { t, out = true if you sent it, me = your name, text }, ... },
--   }   (key = the name without realm and spaces, lowercase)
--   db.popouts[key] = { point, relativePoint, x, y, w, h, open = true } for own whisper windows
local db = { messages = {}, whispers = {}, popouts = {} }

local panel
local view = "chat"  -- "chat", "whisper" or "log"
local selectedKey    -- the conversation shown under Hvisking
local popouts = {}   -- [key] = a separate window with the conversation (see Hviskevinduer)
local UpdatePopout, ClosePopout

-- Is the conversation open in its own window now?
local function PopoutShown(key)
    return popouts[key] ~= nil and popouts[key]:IsShown()
end

-- Small things ------------------------------------------------------------------

-- A text the game has given us, or nil if it is missing or secret.
local function Plain(value)
    if type(value) == "string" and not DW.IsSecret(value) and value ~= "" then
        return value
    end
    return nil
end

local function ShortName(name)
    return name:match("^([^-]+)") or name
end

-- A member's class, from the member list (re-read at most every 30 seconds).
local classByName, classReadAt = {}, nil
local function ClassOf(name)
    if not classReadAt or GetTime() - classReadAt > 30 then
        classByName = {}
        for _, member in ipairs(DW.ReadGuildRoster()) do
            classByName[DW.NameKey(member.key)] = member.class
        end
        classReadAt = GetTime()
    end
    return classByName[DW.NameKey(name)]
end

-- A name in class color (gray if the class is unknown, e.g. outside the guild).
local function Colored(name)
    local color = RAID_CLASS_COLORS and RAID_CLASS_COLORS[ClassOf(name) or ""]
    local code = "ffc8c8c8"
    if color then
        code = ("ff%02x%02x%02x"):format(math.floor(color.r * 255 + 0.5), math.floor(color.g * 255 + 0.5), math.floor(color.b * 255 + 0.5))
    end
    return ("|c%s%s|r"):format(code, ShortName(name))
end

-- The color the game uses for a type of chat, or a fallback.
local function ChatColor(kind, r, g, b)
    local info = ChatTypeInfo and ChatTypeInfo[kind]
    if info and info.r then
        return info.r, info.g, info.b
    end
    return r, g, b
end

-- Sends a chat message. "|" is removed: the game only accepts real links.
local function Send(text, chatType, target)
    text = (text or ""):gsub("|", "/"):gsub("^%s+", ""):gsub("%s+$", "")
    if text == "" then
        return false
    end
    local send = (C_ChatInfo and C_ChatInfo.SendChatMessage) or SendChatMessage
    if not send then
        return false
    end
    if C_ChatInfo and C_ChatInfo.InChatMessagingLockdown and C_ChatInfo.InChatMessagingLockdown() then
        DW.Print(L.GC_BLOCKED)
        return false
    end
    send(text, chatType, nil, target)
    return true
end

-- A pane with lines as in the chat window: links can be clicked, and the
-- mouse wheel scrolls.
local function CreateMessageFrame(parent, maxLines)
    local frame = CreateFrame("ScrollingMessageFrame", nil, parent)
    frame:SetFontObject(ChatFontNormal or "ChatFontNormal")
    frame:SetJustifyH("LEFT")
    frame:SetFading(false)
    frame:SetMaxLines(maxLines)
    frame:SetHyperlinksEnabled(true)
    frame:EnableMouseWheel(true)
    frame:SetScript("OnMouseWheel", function(self, delta)
        if delta > 0 then
            self:ScrollUp()
        else
            self:ScrollDown()
        end
    end)
    frame:SetScript("OnHyperlinkClick", function(self, link, text, button)
        SetItemRef(link, text, button, self)
    end)
    return frame
end

-- A text field for writing a message; Enter or the button sends.
local function CreateInput(parent, onSend)
    local box = CreateFrame("EditBox", nil, parent, "InputBoxTemplate")
    box:SetHeight(22)
    box:SetAutoFocus(false)
    box:SetMaxLetters(MAX_SEND_LETTERS)
    local function Submit()
        if onSend(box:GetText()) then
            box:SetText("")
        end
        box:ClearFocus()
    end
    box:SetScript("OnEnterPressed", Submit)
    box:SetScript("OnEscapePressed", function(self)
        self:ClearFocus()
    end)
    box.button = DW.CreateButton(parent, 96, 26, "gold")
    box.button:SetScript("OnClick", Submit)
    return box
end

-- Chat -----------------------------------------------------------------------------

-- One chat line: [20:15] [Name]: text. The name is a link as in normal chat.
local function FormatMessage(message)
    local link = ("|Hplayer:%s|h[%s]|h"):format(message.from, Colored(message.from))
    return ("|cff909090[%s]|r %s: %s"):format(date("%H:%M", message.t), link, message.text)
end

local function ShowMessages()
    if not panel then
        return
    end
    local frame = panel.chat
    frame:Clear()
    local r, g, b = ChatColor("GUILD", 0.25, 1.00, 0.25)
    for _, message in ipairs(db.messages) do
        frame:AddMessage(FormatMessage(message), r, g, b)
    end
    if #db.messages == 0 then
        frame:AddMessage(L.GC_EMPTY, 0.6, 0.6, 0.6)
    end
    frame:ScrollToBottom()
end

local function AddMessage(message)
    if DW.QueueAlertRefresh then
        DW.QueueAlertRefresh()
    end
    db.messages[#db.messages + 1] = message
    while #db.messages > MAX_MESSAGES do
        table.remove(db.messages, 1)
    end
    if panel and panel:IsVisible() and view == "chat" then
        if #db.messages == 1 then
            ShowMessages() -- removes "No messages yet"
        else
            local r, g, b = ChatColor("GUILD", 0.25, 1.00, 0.25)
            panel.chat:AddMessage(FormatMessage(message), r, g, b)
        end
    end
end

local function RefreshMotd()
    if not panel then
        return
    end
    local motd = Plain(GetGuildRosterMOTD and GetGuildRosterMOTD())
    panel.motd:SetText(motd and L.GC_MOTD:format(motd) or "")
end

-- Whispers ------------------------------------------------------------------------

local RefreshWhispers

-- The conversations, newest first.
local function SortedConversations()
    local list = {}
    for key, conversation in pairs(db.whispers) do
        list[#list + 1] = { key = key, conversation = conversation }
    end
    table.sort(list, function(a, b)
        if a.conversation.last ~= b.conversation.last then
            return a.conversation.last > b.conversation.last
        end
        return a.key < b.key
    end)
    return list
end

local function UnreadTotal()
    local total = 0
    for _, conversation in pairs(db.whispers) do
        total = total + (conversation.unread or 0)
    end
    return total
end

-- "Hvisking" (whisper), with the number of unread in parentheses when there are any.
local function WhisperChipText()
    local unread = UnreadTotal()
    return unread > 0 and ("%s (%d)"):format(L.GC_VIEW_WHISPER, unread) or L.GC_VIEW_WHISPER
end

local function IsShowing(key)
    return panel ~= nil and panel:IsVisible() and view == "whisper" and selectedKey == key
end

-- Stores a whisper, incoming (out = false) or outgoing (out = true).
local function AddWhisper(name, text, out)
    local key = DW.NameKey(name)
    if key == "" then
        return
    end
    if DW.QueueAlertRefresh then
        DW.QueueAlertRefresh()
    end
    local conversation = db.whispers[key]
    if not conversation then
        conversation = { messages = {}, unread = 0 }
        db.whispers[key] = conversation
    end
    local _, me = DW.CharacterKey()
    local now = time()
    conversation.name = name
    conversation.last = now
    conversation.messages[#conversation.messages + 1] = {
        t = now, at = DW.AlertNow and DW.AlertNow() or now, out = out or nil, me = out and me or nil, text = text,
    }
    while #conversation.messages > MAX_WHISPERS do
        table.remove(conversation.messages, 1)
    end
    if not out and not IsShowing(key) and not PopoutShown(key) then
        conversation.unread = (conversation.unread or 0) + 1
    end

    -- Only the 50 newest conversations are kept.
    local list = SortedConversations()
    for index = MAX_CONVERSATIONS + 1, #list do
        ClosePopout(list[index].key)
        db.whispers[list[index].key] = nil
    end
    UpdatePopout(key)

    if panel and panel:IsVisible() then
        if view == "whisper" then
            if not selectedKey then
                selectedKey = key
            end
            RefreshWhispers()
        else
            panel.views.whisper.label:SetText(WhisperChipText())
        end
    end
end

-- One line in a conversation: [21.11 20:15] [Name]: text.
local function FormatWhisper(conversation, message)
    local name = message.out and (message.me or "?") or conversation.name
    local link = ("|Hplayer:%s|h[%s]|h"):format(name, Colored(name))
    return ("|cff909090[%s]|r %s: %s"):format(date("%d.%m %H:%M", message.t), link, message.text)
end

-- The whole conversation in a message pane, newest at the bottom.
local function ShowConversation(frame, conversation)
    frame:Clear()
    local r, g, b = ChatColor("WHISPER", 1.00, 0.50, 1.00)
    local outR, outG, outB = ChatColor("WHISPER_INFORM", 1.00, 0.50, 1.00)
    for _, message in ipairs(conversation.messages) do
        if message.out then
            frame:AddMessage(FormatWhisper(conversation, message), outR, outG, outB)
        else
            frame:AddMessage(FormatWhisper(conversation, message), r, g, b)
        end
    end
    frame:ScrollToBottom()
end

local function GetRow(index)
    local rows = panel.whisperRows
    local row = rows[index]
    if row then
        return row
    end
    row = DW.CreateChip(panel.whisperContent, LIST_WIDTH, ROW_HEIGHT - 4)
    row:SetPoint("TOPLEFT", 0, -(index - 1) * ROW_HEIGHT)
    row.label:ClearAllPoints()
    row.label:SetPoint("TOPLEFT", 8, -5)
    row.label:SetPoint("TOPRIGHT", -8, -5)
    row.sub = row:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    row.sub:SetTextColor(0.65, 0.65, 0.65)
    row.sub:SetPoint("BOTTOMLEFT", 8, 5)
    row.sub:SetPoint("BOTTOMRIGHT", -8, 5)
    row.sub:SetJustifyH("LEFT")
    row.sub:SetWordWrap(false)
    row:SetScript("OnClick", function(self)
        selectedKey = self.key
        RefreshWhispers()
    end)
    rows[index] = row
    return row
end

RefreshWhispers = function()
    if not panel or not panel:IsVisible() or view ~= "whisper" then
        return
    end
    local list = SortedConversations()
    if not (selectedKey and db.whispers[selectedKey]) then
        selectedKey = list[1] and list[1].key or nil
    end
    local selected = selectedKey and db.whispers[selectedKey]
    if selected then
        selected.unread = 0 -- is shown now, so it is read
    end

    local today = date("%d.%m.%Y", time())
    for index, entry in ipairs(list) do
        local row = GetRow(index)
        local conversation = entry.conversation
        row.key = entry.key
        local unread = conversation.unread or 0
        row.label:SetText((unread > 0 and ("|cffffd100(" .. unread .. ")|r ") or "") .. Colored(conversation.name))
        local lastMessage = conversation.messages[#conversation.messages]
        local when = date("%d.%m.%Y", conversation.last) == today and date("%H:%M", conversation.last) or date("%d.%m", conversation.last)
        local preview = lastMessage and ((lastMessage.out and L.GC_YOU or "") .. lastMessage.text) or ""
        row.sub:SetText(when .. "  " .. preview)
        row:SetSelected(entry.key == selectedKey)
        row:Show()
    end
    for index = #list + 1, #panel.whisperRows do
        panel.whisperRows[index]:Hide()
    end
    panel.whisperContent:SetHeight(math.max(1, #list * ROW_HEIGHT))

    local frame = panel.whisperChat
    frame:Clear()
    panel.whisperName:SetText(selected and Colored(selected.name) or "")
    panel.whisperDelete:SetShown(selected ~= nil)
    panel.whisperPopout:SetShown(selected ~= nil)
    panel.whisperInput:SetShown(selected ~= nil)
    panel.whisperInput.button:SetShown(selected ~= nil)
    if selected then
        ShowConversation(frame, selected)
    else
        frame:AddMessage(L.GC_WHISPER_EMPTY, 0.6, 0.6, 0.6)
        frame:ScrollToBottom()
    end
    panel.views.whisper.label:SetText(WhisperChipText())
end

local function DeleteConversation()
    if selectedKey then
        ClosePopout(selectedKey)
        db.whispers[selectedKey] = nil
        selectedKey = nil
        RefreshWhispers()
    end
end

-- Hviskevinduer (whisper windows) ---------------------------------------------
-- A conversation can be opened in its own small window ("Own window"),
-- so you can chat while doing other things. The window can be dragged
-- anywhere, and made larger or smaller with the handle at the bottom right.
-- Position and size are remembered per conversation (db.popouts), and windows
-- that were open open again after /reload and the next login. Messages in an
-- open conversation are read, and don't flash.

local POPOUT_W, POPOUT_H = 320, 220
local POPOUT_MIN_W, POPOUT_MIN_H, POPOUT_MAX_W, POPOUT_MAX_H = 220, 140, 700, 520

local function SavePopout(key)
    local f = popouts[key]
    if not f then
        return
    end
    local saved = db.popouts[key] or {}
    db.popouts[key] = saved
    local point, _, relativePoint, x, y = f:GetPoint(1)
    if point then
        saved.point, saved.relativePoint, saved.x, saved.y = point, relativePoint, x, y
    end
    saved.w, saved.h = f:GetWidth(), f:GetHeight()
    saved.open = f:IsShown() or nil
end

local function Clamp(value, low, high)
    value = tonumber(value) or low
    return math.max(low, math.min(high, value))
end

local function CreatePopout(key)
    local f = CreateFrame("Frame", nil, UIParent, "BackdropTemplate")
    f:SetFrameStrata("MEDIUM")
    f:SetClampedToScreen(true)
    f:SetBackdrop(DW.PANEL_BACKDROP)
    f:SetBackdropColor(0.04, 0.04, 0.06, 0.88)
    f:SetBackdropBorderColor(0.90, 0.72, 0.30, 1)
    f:EnableMouse(true)
    f:SetMovable(true)
    f:SetResizable(true)
    if f.SetResizeBounds then
        f:SetResizeBounds(POPOUT_MIN_W, POPOUT_MIN_H, POPOUT_MAX_W, POPOUT_MAX_H)
    elseif f.SetMinResize then
        f:SetMinResize(POPOUT_MIN_W, POPOUT_MIN_H)
    end
    f:RegisterForDrag("LeftButton")
    f:SetScript("OnDragStart", function(self)
        self:StartMoving()
    end)
    f:SetScript("OnDragStop", function(self)
        self:StopMovingOrSizing()
        SavePopout(key)
    end)

    local saved = db.popouts[key] or {}
    if saved.point then
        f:SetPoint(saved.point, UIParent, saved.relativePoint or saved.point, tonumber(saved.x) or 0, tonumber(saved.y) or 0)
    else
        -- New windows slightly offset, so they don't pile up on top of each other.
        local count = 0
        for _ in pairs(popouts) do
            count = count + 1
        end
        f:SetPoint("CENTER", UIParent, "CENTER", 260 + count * 24, -60 - count * 24)
    end
    f:SetSize(Clamp(saved.w or POPOUT_W, POPOUT_MIN_W, POPOUT_MAX_W), Clamp(saved.h or POPOUT_H, POPOUT_MIN_H, POPOUT_MAX_H))

    f.title = f:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    f.title:SetPoint("TOPLEFT", 12, -9)
    f.title:SetPoint("RIGHT", -28, 0)
    f.title:SetJustifyH("LEFT")

    f.close = CreateFrame("Button", nil, f, "UIPanelCloseButton")
    f.close:SetPoint("TOPRIGHT", 2, 2)
    f.close:SetScript("OnClick", function()
        ClosePopout(key)
    end)

    f.chat = CreateMessageFrame(f, MAX_WHISPERS + 20)
    f.chat:SetPoint("TOPLEFT", 10, -28)
    f.chat:SetPoint("BOTTOMRIGHT", -10, 36)

    -- Reply: Enter sends to the one you are chatting with.
    f.input = CreateFrame("EditBox", nil, f, "InputBoxTemplate")
    f.input:SetPoint("BOTTOMLEFT", 16, 9)
    f.input:SetPoint("BOTTOMRIGHT", -24, 9)
    f.input:SetHeight(22)
    f.input:SetAutoFocus(false)
    f.input:SetMaxLetters(MAX_SEND_LETTERS)
    f.input:SetScript("OnEnterPressed", function(self)
        local conversation = db.whispers[key]
        if conversation and Send(self:GetText(), "WHISPER", conversation.name) then
            self:SetText("")
        end
        self:ClearFocus()
    end)
    f.input:SetScript("OnEscapePressed", function(self)
        self:ClearFocus()
    end)

    -- The handle at the bottom right: drag to resize.
    f.grip = CreateFrame("Button", nil, f)
    f.grip:SetSize(16, 16)
    f.grip:SetPoint("BOTTOMRIGHT", -3, 3)
    f.grip:SetNormalTexture("Interface\\ChatFrame\\UI-ChatIM-SizeGrabber-Up")
    f.grip:SetPushedTexture("Interface\\ChatFrame\\UI-ChatIM-SizeGrabber-Down")
    f.grip:SetHighlightTexture("Interface\\ChatFrame\\UI-ChatIM-SizeGrabber-Highlight")
    f.grip:SetScript("OnMouseDown", function()
        f:StartSizing("BOTTOMRIGHT")
    end)
    f.grip:SetScript("OnMouseUp", function()
        f:StopMovingOrSizing()
        SavePopout(key)
    end)

    return f
end

-- Redraws the conversation in the window (when it is open), and counts it as read.
UpdatePopout = function(key)
    local f = popouts[key]
    local conversation = db.whispers[key]
    if not f or not f:IsShown() or not conversation then
        return
    end
    f.title:SetText(Colored(conversation.name))
    ShowConversation(f.chat, conversation)
    conversation.unread = 0
end

local function OpenPopout(key)
    if not db.whispers[key] then
        return
    end
    if not popouts[key] then
        popouts[key] = CreatePopout(key)
    end
    popouts[key]:Show()
    UpdatePopout(key)
    SavePopout(key)
    if DW.RefreshAlerts then
        DW.RefreshAlerts()
    end
    RefreshWhispers()
end
DW.OpenWhisperWindow = OpenPopout

ClosePopout = function(key)
    if popouts[key] then
        popouts[key]:Hide()
    end
    if db.popouts[key] then
        db.popouts[key].open = nil
    end
end

-- Opens the windows that were open last time (after /reload and at login).
local function RestorePopouts()
    for key, saved in pairs(db.popouts) do
        if saved.open and db.whispers[key] then
            OpenPopout(key)
        end
    end
end
DW.RestoreWhisperWindows = RestorePopouts

local restored = false
local function RestoreOnce()
    if not restored and DW.IsMember() then
        restored = true
        RestorePopouts()
    end
end

-- Log ------------------------------------------------------------------------------

local LOG_TEXT = {
    invite = "GC_LOG_INVITE", join = "GC_LOG_JOIN", promote = "GC_LOG_PROMOTE",
    demote = "GC_LOG_DEMOTE", remove = "GC_LOG_REMOVE", quit = "GC_LOG_QUIT",
}

-- "3 dager siden" (3 days ago) from how long ago the game says it is.
local function Ago(years, months, days, hours)
    if years > 0 then
        return L.GC_AGO_YEARS:format(years)
    elseif months > 0 then
        return L.GC_AGO_MONTHS:format(months)
    elseif days > 0 then
        return L.GC_AGO_DAYS:format(days)
    elseif hours > 0 then
        return L.GC_AGO_HOURS:format(hours)
    end
    return L.GC_AGO_NOW
end

local function Number(value)
    if type(value) == "number" and not DW.IsSecret(value) then
        return value
    end
    return 0
end

-- The log from the game, oldest first: { { text, ago, index }, ... }, or nil
-- if the game doesn't have the functions.
local function ReadLog()
    if not (GetNumGuildEvents and GetGuildEventInfo) then
        return nil
    end
    local entries = {}
    for index = 1, Number(GetNumGuildEvents()) do
        local kind, player1, player2, rank, years, months, days, hours = GetGuildEventInfo(index)
        kind, player1, player2, rank = Plain(kind), Plain(player1), Plain(player2), Plain(rank)
        years, months, days, hours = Number(years), Number(months), Number(days), Number(hours)
        if kind and player1 then
            local key = LOG_TEXT[kind]
            local text
            if key then
                text = L[key]:format(Colored(player1), player2 and Colored(player2) or "?", rank or "?")
            else
                text = ("%s: %s %s"):format(kind, Colored(player1), player2 and Colored(player2) or "")
            end
            entries[#entries + 1] = {
                text = ("|cff909090[%s]|r %s"):format(Ago(years, months, days, hours), text),
                ago = ((years * 12 + months) * 30 + days) * 24 + hours,
                index = index,
            }
        end
    end
    table.sort(entries, function(a, b)
        if a.ago ~= b.ago then
            return a.ago > b.ago
        end
        return a.index < b.index
    end)
    return entries
end

local function ShowLog()
    if not panel then
        return
    end
    local frame = panel.log
    frame:Clear()
    local entries = ReadLog()
    if not entries then
        frame:AddMessage(L.GC_LOG_UNAVAILABLE, 0.6, 0.6, 0.6)
    elseif #entries == 0 then
        frame:AddMessage(L.GC_LOG_EMPTY, 0.6, 0.6, 0.6)
    else
        for _, entry in ipairs(entries) do
            frame:AddMessage(entry.text, 1, 1, 1)
        end
    end
    frame:ScrollToBottom()
end

-- Asks the game for the log; it is shown when the game answers.
local function RequestLog()
    if QueryGuildEventLog then
        QueryGuildEventLog()
    end
    ShowLog()
end

-- Display ---------------------------------------------------------------------

local function RefreshPanel()
    if not panel or not panel:IsVisible() then
        return
    end
    panel.views.chat.label:SetText(L.GC_VIEW_CHAT)
    panel.views.whisper.label:SetText(WhisperChipText())
    panel.views.log.label:SetText(L.GC_VIEW_LOG)
    for name, chip in pairs(panel.views) do
        chip:SetSelected(view == name)
    end
    panel.chatInput.button.label:SetText(L.GC_SEND)
    panel.whisperInput.button.label:SetText(L.GC_SEND)
    panel.whisperDelete.label:SetText(L.GC_DELETE_CONVERSATION)
    panel.whisperPopout.label:SetText(L.GC_POPOUT)
    panel.refresh.label:SetText(L.GC_REFRESH)

    -- Each view has its own parts; show only the selected one.
    for name, parts in pairs(panel.parts) do
        for _, part in ipairs(parts) do
            part:SetShown(view == name)
        end
    end
    -- What is shown now has been seen (the flashing, Alerts.lua).
    if DW.RefreshAlerts then
        DW.RefreshAlerts()
    end
    if view == "chat" then
        RefreshMotd()
        ShowMessages()
    elseif view == "whisper" then
        RefreshWhispers()
    else
        RequestLog()
    end
end

local function CreatePanel(parent)
    local f = CreateFrame("Frame", nil, parent)
    f:SetAllPoints(parent)
    panel = f

    -- Chat, whisper or log.
    f.views = {}
    for index, name in ipairs({ "chat", "whisper", "log" }) do
        local chip = DW.CreateChip(f, 120, 26)
        chip:SetPoint("TOPLEFT", 14 + (index - 1) * 126, -12)
        chip.label:SetJustifyH("CENTER")
        chip:SetScript("OnClick", function()
            view = name
            RefreshPanel()
        end)
        f.views[name] = chip
    end

    -- Chat: the message of the day, the messages, and the field that sends to the guild chat.
    f.motd = f:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    f.motd:SetPoint("TOPLEFT", 16, -46)
    f.motd:SetPoint("RIGHT", -16, 0)
    f.motd:SetJustifyH("LEFT")

    f.chat = CreateMessageFrame(f, MAX_MESSAGES + 20)
    f.chat:SetPoint("TOPLEFT", 14, -66)
    f.chat:SetPoint("BOTTOMRIGHT", -14, 46)

    f.chatInput = CreateInput(f, function(text)
        return Send(text, "GUILD")
    end)
    f.chatInput:SetPoint("BOTTOMLEFT", 22, 14)
    f.chatInput:SetPoint("RIGHT", -120, 0)
    f.chatInput.button:SetPoint("BOTTOMRIGHT", -14, 12)

    -- Whisper: the conversations on the left, the selected one on the right.
    local scroll = CreateFrame("ScrollFrame", "DragonworldWhisperScroll", f, "ScrollFrameTemplate")
    scroll:SetPoint("TOPLEFT", 14, -48)
    scroll:SetPoint("BOTTOMLEFT", 14, 14)
    scroll:SetWidth(LIST_WIDTH)
    f.whisperContent = CreateFrame("Frame", nil, scroll)
    f.whisperContent:SetSize(LIST_WIDTH, 1)
    scroll:SetScrollChild(f.whisperContent)
    f.whisperRows = {}

    local rightX = 14 + LIST_WIDTH + 30
    f.whisperName = f:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
    f.whisperName:SetPoint("TOPLEFT", rightX, -50)

    f.whisperDelete = DW.CreateButton(f, 130, 22, "red")
    f.whisperDelete:SetPoint("TOPRIGHT", -14, -48)
    f.whisperDelete:SetScript("OnClick", DeleteConversation)

    -- The conversation in its own window.
    f.whisperPopout = DW.CreateChip(f, 110, 22)
    f.whisperPopout:SetPoint("RIGHT", f.whisperDelete, "LEFT", -8, 0)
    f.whisperPopout.label:SetJustifyH("CENTER")
    f.whisperPopout:SetScript("OnClick", function()
        if selectedKey then
            OpenPopout(selectedKey)
        end
    end)
    f.whisperPopout:HookScript("OnEnter", function(self)
        GameTooltip:SetOwner(self, "ANCHOR_BOTTOM")
        GameTooltip:AddLine(L.GC_POPOUT)
        GameTooltip:AddLine(L.GC_POPOUT_TIP, 1, 1, 1, true)
        GameTooltip:Show()
    end)
    f.whisperPopout:HookScript("OnLeave", function()
        GameTooltip:Hide()
    end)

    f.whisperChat = CreateMessageFrame(f, MAX_WHISPERS + 20)
    f.whisperChat:SetPoint("TOPLEFT", rightX, -76)
    f.whisperChat:SetPoint("BOTTOMRIGHT", -14, 46)

    f.whisperInput = CreateInput(f, function(text)
        local conversation = selectedKey and db.whispers[selectedKey]
        return conversation ~= nil and Send(text, "WHISPER", conversation.name)
    end)
    f.whisperInput:SetPoint("BOTTOMLEFT", rightX + 8, 14)
    f.whisperInput:SetPoint("RIGHT", -120, 0)
    f.whisperInput.button:SetPoint("BOTTOMRIGHT", -14, 12)

    -- Log: the lines, and a button that asks the game for them again.
    f.log = CreateMessageFrame(f, 500)
    f.log:SetPoint("TOPLEFT", 14, -48)
    f.log:SetPoint("BOTTOMRIGHT", -14, 14)

    f.refresh = DW.CreateChip(f, 110, 26)
    f.refresh:SetPoint("TOPRIGHT", -14, -12)
    f.refresh.label:SetJustifyH("CENTER")
    f.refresh:SetScript("OnClick", RequestLog)

    f.parts = {
        chat = { f.motd, f.chat, f.chatInput, f.chatInput.button },
        whisper = { scroll, f.whisperName, f.whisperChat, f.whisperDelete, f.whisperPopout, f.whisperInput, f.whisperInput.button },
        log = { f.log, f.refresh },
    }

    f:SetScript("OnShow", RefreshPanel)
    return f
end

-- Events ----------------------------------------------------------------------

local frame = CreateFrame("Frame")
frame:SetScript("OnEvent", function(self, event, ...)
    if not DW.IsMember() then
        return
    end
    local text, name = Plain((...)), Plain((select(2, ...)))
    if event == "CHAT_MSG_GUILD" then
        if text and name then
            AddMessage({ t = time(), at = DW.AlertNow and DW.AlertNow() or time(), from = name, text = text })
        end
    elseif event == "CHAT_MSG_WHISPER" then
        if text and name then
            AddWhisper(name, text, false)
        end
    elseif event == "CHAT_MSG_WHISPER_INFORM" then
        if text and name then
            AddWhisper(name, text, true) -- name is the one you whispered to
        end
    elseif event == "GUILD_EVENT_LOG_UPDATE" then
        if panel and panel:IsVisible() and view == "log" then
            ShowLog()
        end
    elseif event == "PLAYER_ENTERING_WORLD" then
        RestoreOnce()
    elseif event == "GUILD_MOTD" then
        if panel and panel:IsVisible() and view == "chat" then
            RefreshMotd()
        end
    end
end)
for _, event in ipairs({ "CHAT_MSG_GUILD", "CHAT_MSG_WHISPER", "CHAT_MSG_WHISPER_INFORM", "GUILD_EVENT_LOG_UPDATE", "GUILD_MOTD", "PLAYER_ENTERING_WORLD" }) do
    pcall(frame.RegisterEvent, frame, event)
end

-- The guild name can arrive after login; open the windows when it is ready.
DW.OnMembershipChanged(function(member)
    if member then
        RestoreOnce()
    end
end)

DW.OnLanguageChanged(function()
    RefreshPanel()
end)

DW.AddDebug("guildchat", function(add)
    local conversations = 0
    for _ in pairs(db.whispers) do
        conversations = conversations + 1
    end
    add("meldinger lagret: " .. #db.messages .. " | samtaler: " .. conversations .. " | uleste: " .. UnreadTotal()
        .. " | logg-funksjoner: " .. DW.DebugText(GetGuildEventInfo ~= nil and GetNumGuildEvents ~= nil and QueryGuildEventLog ~= nil)
        .. " | i loggen nå: " .. DW.DebugText(GetNumGuildEvents and GetNumGuildEvents()))
end)

-- Flashing (Alerts.lua) -----------------------------------------------------------

-- Short excerpt of a message for the list at the button (without cutting in the middle of a letter).
local function Excerpt(text)
    if #text <= 60 then
        return text
    end
    return (text:sub(1, 57):gsub("[\192-\255][\128-\191]*$", "")) .. "..."
end

local function MyNameKey()
    local _, name = DW.CharacterKey()
    return name and DW.NameKey(name) or ""
end

-- Incoming whispers newer than since, newest first: { { conversation, message }, ... }
local function NewWhispers(since)
    local list = {}
    for key, conversation in pairs(db.whispers) do
        -- A conversation that is open in its own window is already seen.
        for index = #conversation.messages, 1, -1 do
            local message = conversation.messages[index]
            if PopoutShown(key) then
                break
            end
            if not message.out and (message.at or 0) > since then
                list[#list + 1] = { conversation = conversation, message = message }
                break -- one line per person: the newest
            end
        end
    end
    table.sort(list, function(a, b)
        return (a.message.at or 0) > (b.message.at or 0)
    end)
    return list
end

-- Messages in the guild chat from others newer than since, newest first.
local function NewGuildMessages(since)
    local list, me = {}, MyNameKey()
    for index = #db.messages, 1, -1 do
        local message = db.messages[index]
        if (message.at or 0) <= since then
            break
        end
        if DW.NameKey(message.from) ~= me then
            list[#list + 1] = message
        end
    end
    return list
end

-- Opens the tab on a specific view.
local function OpenView(name)
    view = name
    DW.OpenModule(MODULE_ID)
    RefreshPanel()
end

DW.RegisterAlert({
    kind = "whisper",
    module = MODULE_ID,
    labelKey = "AL_WHISPER",
    color = { 1.00, 0.45, 1.00 }, -- pink, like whispers in chat
    Check = function(since)
        return #NewWhispers(since) > 0
    end,
    Items = function(since)
        local items = {}
        for _, found in ipairs(NewWhispers(since)) do
            items[#items + 1] = ShortName(found.conversation.name) .. ": " .. Excerpt(found.message.text)
        end
        return items
    end,
    IsShown = function()
        return panel ~= nil and panel:IsVisible() and view == "whisper"
    end,
    Open = function()
        local newest = NewWhispers(0)[1]
        if newest then
            selectedKey = DW.NameKey(newest.conversation.name)
        end
        OpenView("whisper")
    end,
})

-- Off by default: in a guild with a lot of chatter it would flash all the time.
DW.RegisterAlert({
    kind = "guildchat",
    module = MODULE_ID,
    labelKey = "AL_GUILDCHAT",
    color = { 0.40, 0.85, 1.00 }, -- light blue
    defaultOff = true,
    Check = function(since)
        return #NewGuildMessages(since) > 0
    end,
    Items = function(since)
        local items = {}
        for _, message in ipairs(NewGuildMessages(since)) do
            items[#items + 1] = ShortName(message.from) .. ": " .. Excerpt(message.text)
        end
        return items
    end,
    IsShown = function()
        return panel ~= nil and panel:IsVisible() and view == "chat"
    end,
    Open = function()
        OpenView("chat")
    end,
})

-- Module -------------------------------------------------------------------------

DW.RegisterModule({
    id = MODULE_ID,
    titleKey = "GC_TITLE",
    notesKey = "GC_NOTES",
    icon = "Interface\\GossipFrame\\GossipGossipIcon",

    OnLoad = function(self, saved)
        if type(saved.messages) ~= "table" then
            saved.messages = {}
        end
        if type(saved.popouts) ~= "table" then
            saved.popouts = {}
        end
        for key, popout in pairs(saved.popouts) do
            if type(key) ~= "string" or type(popout) ~= "table" then
                saved.popouts[key] = nil
            end
        end
        if type(saved.whispers) ~= "table" then
            saved.whispers = {}
        end
        -- Clean up anything that doesn't look right.
        local function Valid(message)
            return type(message) == "table" and type(message.text) == "string" and type(message.t) == "number"
        end
        for index = #saved.messages, 1, -1 do
            if not Valid(saved.messages[index]) or type(saved.messages[index].from) ~= "string" then
                table.remove(saved.messages, index)
            end
        end
        for key, conversation in pairs(saved.whispers) do
            if type(conversation) ~= "table" or type(conversation.name) ~= "string" or type(conversation.messages) ~= "table"
                or type(conversation.last) ~= "number" then
                saved.whispers[key] = nil
            else
                for index = #conversation.messages, 1, -1 do
                    if not Valid(conversation.messages[index]) then
                        table.remove(conversation.messages, index)
                    end
                end
            end
        end
        db = saved
    end,

    CreatePanel = function(self, parent)
        return CreatePanel(parent)
    end,
})
