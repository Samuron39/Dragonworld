-- Dragonworld - Guildchat og logg
-- En fane med guildchatten, hviskinger og spillets guildlogg, rett under
-- Medlemmer.
--
--   Chat:      meldingene i guildchatten, med klokkeslett og navnet i
--              klassefarge (klikk på navnet for å hviske, som i vanlig chat).
--              Feltet nederst sender til guildchatten. Øverst står dagens
--              melding (MOTD). De siste 300 meldingene huskes.
--   Hvisking:  samtalene du har på hvisking med hvem som helst, guildmedlem
--              eller ikke: en liste til venstre (nyeste øverst, med antall
--              uleste), og hele samtalen med den du velger til høyre, med
--              dato og klokkeslett, så du kan fortsette der dere slapp. Feltet
--              nederst svarer. En samtale kan slettes. De siste 50 samtalene
--              med opptil 200 meldinger hver huskes.
--   Logg:      spillets guildlogg: hvem som er invitert, har blitt med,
--              sluttet, er kastet ut, forfremmet eller degradert, og hvor
--              lenge siden. Spillet sender loggen når den bes om
--              (QueryGuildEventLog), og sier fra med GUILD_EVENT_LOG_UPDATE.
--
-- Chat og hviskinger huskes felles for kontoen, bare på denne PC-en (i
-- SavedVariables), og deles aldri med noen. Bare det som kom mens addonen var
-- på er med: spillet gir ikke addons eldre chat. Hviskinger via Battle.net
-- er ikke med.
--
-- Spillet kan gjøre chat "hemmelig" for addons i noen situasjoner (f.eks. i
-- kamp i instanser). Slike meldinger kan ikke leses, og hoppes over.
--
-- All tekst ligger i Locales.lua (navnene som begynner med GC_).

local ADDON_NAME, DW = ...
local L = DW.L

local MODULE_ID = "guildchat"
local MAX_MESSAGES = 300
local MAX_CONVERSATIONS = 50
local MAX_WHISPERS = 200
local MAX_SEND_LETTERS = 255
local LIST_WIDTH = 180
local ROW_HEIGHT = 40

-- Lagrede data. Settes i OnLoad nederst.
--   db.messages = { { t = tid (lokal klokke), from = "Navn-Realm", text }, ... }, eldste først
--   db.whispers[nøkkel] = {
--       name   = navnet slik spillet sist oppga det (brukes når du svarer),
--       last   = tiden for siste melding, unread = antall uleste,
--       messages = { { t, out = true hvis du sendte den, me = ditt navn, text }, ... },
--   }   (nøkkel = navnet uten realm og mellomrom, små bokstaver)
local db = { messages = {}, whispers = {} }

local panel
local view = "chat"  -- "chat", "whisper" eller "log"
local selectedKey    -- samtalen som vises under Hvisking

-- Småting -----------------------------------------------------------------------

-- En tekst spillet har gitt oss, eller nil hvis den mangler eller er hemmelig.
local function Plain(value)
    if type(value) == "string" and not DW.IsSecret(value) and value ~= "" then
        return value
    end
    return nil
end

local function ShortName(name)
    return name:match("^([^-]+)") or name
end

-- Klassen til et medlem, fra medlemslisten (lest på nytt høyst hvert 30. sekund).
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

-- Et navn i klassefarge (grått hvis klassen er ukjent, f.eks. utenfor guilden).
local function Colored(name)
    local color = RAID_CLASS_COLORS and RAID_CLASS_COLORS[ClassOf(name) or ""]
    local code = "ffc8c8c8"
    if color then
        code = ("ff%02x%02x%02x"):format(math.floor(color.r * 255 + 0.5), math.floor(color.g * 255 + 0.5), math.floor(color.b * 255 + 0.5))
    end
    return ("|c%s%s|r"):format(code, ShortName(name))
end

-- Fargen spillet bruker for en type chat, eller en reserve.
local function ChatColor(kind, r, g, b)
    local info = ChatTypeInfo and ChatTypeInfo[kind]
    if info and info.r then
        return info.r, info.g, info.b
    end
    return r, g, b
end

-- Sender en chatmelding. "|" fjernes: spillet godtar bare ekte lenker.
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

-- En rute med linjer som i chatvinduet: lenker kan klikkes, og musehjulet
-- blar.
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

-- Et tekstfelt for å skrive en melding; Enter eller knappen sender.
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

-- Én chatlinje: [20:15] [Navn]: tekst. Navnet er en lenke som i vanlig chat.
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
            ShowMessages() -- tar bort "ingen meldinger ennå"
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

-- Hvisking ------------------------------------------------------------------------

local RefreshWhispers

-- Samtalene, nyeste først.
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

-- "Hvisking", med antall uleste i parentes når det er noen.
local function WhisperChipText()
    local unread = UnreadTotal()
    return unread > 0 and ("%s (%d)"):format(L.GC_VIEW_WHISPER, unread) or L.GC_VIEW_WHISPER
end

local function IsShowing(key)
    return panel ~= nil and panel:IsVisible() and view == "whisper" and selectedKey == key
end

-- Tar vare på en hvisking, inn (out = false) eller ut (out = true).
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
    if not out and not IsShowing(key) then
        conversation.unread = (conversation.unread or 0) + 1
    end

    -- Bare de 50 nyeste samtalene huskes.
    local list = SortedConversations()
    for index = MAX_CONVERSATIONS + 1, #list do
        db.whispers[list[index].key] = nil
    end

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

-- Én linje i en samtale: [21.11 20:15] [Navn]: tekst.
local function FormatWhisper(conversation, message)
    local name = message.out and (message.me or "?") or conversation.name
    local link = ("|Hplayer:%s|h[%s]|h"):format(name, Colored(name))
    return ("|cff909090[%s]|r %s: %s"):format(date("%d.%m %H:%M", message.t), link, message.text)
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
        selected.unread = 0 -- vises nå, så den er lest
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
    panel.whisperInput:SetShown(selected ~= nil)
    panel.whisperInput.button:SetShown(selected ~= nil)
    if selected then
        local r, g, b = ChatColor("WHISPER", 1.00, 0.50, 1.00)
        local outR, outG, outB = ChatColor("WHISPER_INFORM", 1.00, 0.50, 1.00)
        for _, message in ipairs(selected.messages) do
            if message.out then
                frame:AddMessage(FormatWhisper(selected, message), outR, outG, outB)
            else
                frame:AddMessage(FormatWhisper(selected, message), r, g, b)
            end
        end
    else
        frame:AddMessage(L.GC_WHISPER_EMPTY, 0.6, 0.6, 0.6)
    end
    frame:ScrollToBottom()
    panel.views.whisper.label:SetText(WhisperChipText())
end

local function DeleteConversation()
    if selectedKey then
        db.whispers[selectedKey] = nil
        selectedKey = nil
        RefreshWhispers()
    end
end

-- Logg -----------------------------------------------------------------------------

local LOG_TEXT = {
    invite = "GC_LOG_INVITE", join = "GC_LOG_JOIN", promote = "GC_LOG_PROMOTE",
    demote = "GC_LOG_DEMOTE", remove = "GC_LOG_REMOVE", quit = "GC_LOG_QUIT",
}

-- "3 dager siden" ut fra hvor lenge siden spillet sier det er.
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

-- Loggen fra spillet, eldste først: { { text, ago, index }, ... }, eller nil
-- hvis spillet ikke har funksjonene.
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

-- Ber spillet om loggen; den vises når spillet svarer.
local function RequestLog()
    if QueryGuildEventLog then
        QueryGuildEventLog()
    end
    ShowLog()
end

-- Visning ---------------------------------------------------------------------

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
    panel.refresh.label:SetText(L.GC_REFRESH)

    -- Hver visning har sine egne deler; vis bare den valgte.
    for name, parts in pairs(panel.parts) do
        for _, part in ipairs(parts) do
            part:SetShown(view == name)
        end
    end
    -- Det som vises nå, er sett (blinkingen, Alerts.lua).
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

    -- Chat, hvisking eller logg.
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

    -- Chat: dagens melding, meldingene, og feltet som sender til guildchatten.
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

    -- Hvisking: samtalene til venstre, den valgte til høyre.
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

    -- Logg: linjene, og en knapp som ber spillet om dem på nytt.
    f.log = CreateMessageFrame(f, 500)
    f.log:SetPoint("TOPLEFT", 14, -48)
    f.log:SetPoint("BOTTOMRIGHT", -14, 14)

    f.refresh = DW.CreateChip(f, 110, 26)
    f.refresh:SetPoint("TOPRIGHT", -14, -12)
    f.refresh.label:SetJustifyH("CENTER")
    f.refresh:SetScript("OnClick", RequestLog)

    f.parts = {
        chat = { f.motd, f.chat, f.chatInput, f.chatInput.button },
        whisper = { scroll, f.whisperName, f.whisperChat, f.whisperDelete, f.whisperInput, f.whisperInput.button },
        log = { f.log, f.refresh },
    }

    f:SetScript("OnShow", RefreshPanel)
    return f
end

-- Hendelser -------------------------------------------------------------------

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
            AddWhisper(name, text, true) -- name er den du hvisket til
        end
    elseif event == "GUILD_EVENT_LOG_UPDATE" then
        if panel and panel:IsVisible() and view == "log" then
            ShowLog()
        end
    elseif event == "GUILD_MOTD" then
        if panel and panel:IsVisible() and view == "chat" then
            RefreshMotd()
        end
    end
end)
for _, event in ipairs({ "CHAT_MSG_GUILD", "CHAT_MSG_WHISPER", "CHAT_MSG_WHISPER_INFORM", "GUILD_EVENT_LOG_UPDATE", "GUILD_MOTD" }) do
    pcall(frame.RegisterEvent, frame, event)
end

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

-- Blinking (Alerts.lua) -----------------------------------------------------------

-- Kort utdrag av en melding til listen ved knappen (uten å kutte midt i en bokstav).
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

-- Hviskinger inn som er nyere enn since, nyeste først: { { conversation, message }, ... }
local function NewWhispers(since)
    local list = {}
    for _, conversation in pairs(db.whispers) do
        for index = #conversation.messages, 1, -1 do
            local message = conversation.messages[index]
            if not message.out and (message.at or 0) > since then
                list[#list + 1] = { conversation = conversation, message = message }
                break -- én linje per person: den nyeste
            end
        end
    end
    table.sort(list, function(a, b)
        return (a.message.at or 0) > (b.message.at or 0)
    end)
    return list
end

-- Meldinger i guildchatten fra andre som er nyere enn since, nyeste først.
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

-- Åpner fanen på en bestemt visning.
local function OpenView(name)
    view = name
    DW.OpenModule(MODULE_ID)
    RefreshPanel()
end

DW.RegisterAlert({
    kind = "whisper",
    module = MODULE_ID,
    labelKey = "AL_WHISPER",
    color = { 1.00, 0.45, 1.00 }, -- rosa, som hvisking i chatten
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

-- Av som standard: i en guild med mye prat ville den blinket hele tiden.
DW.RegisterAlert({
    kind = "guildchat",
    module = MODULE_ID,
    labelKey = "AL_GUILDCHAT",
    color = { 0.40, 0.85, 1.00 }, -- lyseblå
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

-- Modul --------------------------------------------------------------------------

DW.RegisterModule({
    id = MODULE_ID,
    titleKey = "GC_TITLE",
    notesKey = "GC_NOTES",
    icon = "Interface\\GossipFrame\\GossipGossipIcon",

    OnLoad = function(self, saved)
        if type(saved.messages) ~= "table" then
            saved.messages = {}
        end
        if type(saved.whispers) ~= "table" then
            saved.whispers = {}
        end
        -- Rydd bort noe som ikke ser riktig ut.
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
