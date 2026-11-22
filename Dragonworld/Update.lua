-- Dragonworld - "update the addon"
--
-- An addon can't read from the internet or write files, so it can't fetch a
-- new version itself. Instead the addons in the guild tell each other which
-- version they have (DW.RELEASE from Version.lua). If the addon hears about a
-- newer version than its own, a window is shown:
--   * With automatic update (DW.AUTO_UPDATE, set by Dragonworld Updater) the
--     new version is already downloaded in the background: "Skriv /reload"
--     (type /reload), with a button that does it. If the new version has new
--     files or images (DW.RESTART_RELEASE), the game has to be fully
--     restarted instead, and the window says so.
--     The window waits until the version has been out long enough that the
--     background job has surely fetched it (DW.RELEASED_AT + 20 minutes).
--   * Without it: "Oppdater Dragonworld!" (update Dragonworld), with how to do
--     it and the download link.
--
-- How it works:
--   * A little after login the addon announces which version it has.
--   * If it hears an older version, it replies with its own after a few
--     seconds, so the outdated one finds out. If someone else has already
--     replied with the same or a newer version meanwhile, it stays quiet.
--   * The newest version it has heard of is remembered (DragonworldDB.update),
--     so the window comes back at the next login until the addon is updated,
--     even if nobody with the new version is online then.
--   * The window is not shown in the middle of combat, and at most once per
--     session.
--   * What is new: every version carries a sentence or two about itself in
--     each language (DW.RELEASE_NEWS, written by release.ps1). The one who is
--     behind asks for it in its own language, someone with that version
--     answers, and the window shows it. After updating, the news of the
--     version you now have is put in chat once.
--
-- Messages (name DragonworldVer, fields separated by tab):
--   V version tocversion restart released
--       version    my DW.RELEASE
--       tocversion for debugging only
--       restart    my DW.RESTART_RELEASE (from 0.15.2)
--       released   my DW.RELEASED_AT     (from 0.15.2)
--   Older versions only send the first two fields, and only read those.
--   Q version language        what is new in this version? (from 0.24.0)
--   N version language text   the answer: DW.RELEASE_NEWS[language] (from 0.24.0)
--   Older versions ignore Q and N.
--
-- All text is in Locales.lua (the names starting with UP_).

local ADDON_NAME, DW = ...
local L = DW.L

local PREFIX = "DragonworldVer" -- name of the messages; max 16 characters
local SEP = "\t"
local HELLO_DELAY = 12          -- seconds after login
local POPUP_DELAY = 20          -- the window at login comes a little later
local REPLY_MIN, REPLY_SPREAD = 2, 8
local AUTO_DELAY = 20 * 60      -- this long after release it has surely been fetched in the background (GitHub can lag a few minutes, the job runs every 10th)
local ASK_AGAIN = 120           -- seconds before asking again for news nobody answered
local MAX_MESSAGE = 255         -- the game's limit for one message, in bytes

-- Version numbers ---------------------------------------------------------------

-- "0.14.2" becomes { 0, 14, 2 }. Anything that doesn't look like a version number gives nil.
local function Parse(version)
    if type(version) ~= "string" or #version > 20 or not version:match("^%d+%.%d+[%.%d]*$") then
        return nil
    end
    local parts = {}
    for number in version:gmatch("%d+") do
        parts[#parts + 1] = tonumber(number)
    end
    return parts
end

-- -1 if a is older than b, 1 if newer, 0 if equal (or unknown).
function DW.CompareVersions(a, b)
    local pa, pb = Parse(a), Parse(b)
    if not pa or not pb then
        return 0
    end
    for index = 1, math.max(#pa, #pb) do
        local x, y = pa[index] or 0, pb[index] or 0
        if x ~= y then
            return x < y and -1 or 1
        end
    end
    return 0
end

local function MyVersion()
    return DW.RELEASE or "0"
end

local function Now()
    local now = GetServerTime and GetServerTime()
    if type(now) == "number" and not DW.IsSecret(now) then
        return now
    end
    return time()
end

-- The version in Dragonworld.toc (shown in the addon list). For debugging only.
local function TocVersion()
    local get = (C_AddOns and C_AddOns.GetAddOnMetadata) or GetAddOnMetadata
    if not get then
        return "?"
    end
    local ok, version = pcall(get, ADDON_NAME, "Version")
    if ok and type(version) == "string" and not DW.IsSecret(version) then
        return version
    end
    return "?"
end

-- What is remembered, shared across the account:
--   { newest = "0.16.0", from = "Name", restart = "0.16.0", releasedAt = time,
--     news = "text", newsFor = "0.16.0", newsLang = "nb",
--     running = "0.15.0" }   (the version that ran last time)
local function Store()
    if type(DragonworldDB) ~= "table" then
        return nil
    end
    if type(DragonworldDB.update) ~= "table" then
        DragonworldDB.update = {}
    end
    local store = DragonworldDB.update
    -- If we have updated since last time, what we remembered is no longer newer.
    if store.newest and DW.CompareVersions(store.newest, MyVersion()) <= 0 then
        store.newest, store.from, store.restart, store.releasedAt = nil, nil, nil, nil
        store.news, store.newsFor, store.newsLang = nil, nil, nil
    end
    return store
end

-- A version's news in one language, from a table like DW.RELEASE_NEWS.
-- English (or Norwegian) if that language is missing.
local function NewsIn(news, lang)
    if type(news) ~= "table" then
        return nil
    end
    for _, key in ipairs({ lang, "en", "nb", "nl" }) do
        local text = news[key]
        if type(text) == "string" and text ~= "" then
            return text
        end
    end
    return nil
end

-- Text from another addon may contain the game's colour and link codes;
-- doubled bars show them as plain text instead.
local function Plain(text)
    return (text:gsub("|", "||"))
end

-- What is new in the newest version, if someone with it has told us.
function DW.NewestNews()
    local store = Store()
    if store and store.newest and store.newsFor == store.newest and type(store.news) == "string" then
        return store.news
    end
    return nil
end

-- The newest version the addon knows of: someone else's, or our own.
function DW.NewestVersion()
    local store = Store()
    return (store and store.newest) or MyVersion()
end

-- Is there a newer version than the one we have?
function DW.IsOutdated()
    return DW.CompareVersions(MyVersion(), DW.NewestVersion()) < 0
end

-- Is /reload enough to get the newest? No if it or a version in
-- between has new files, or if we don't know.
function DW.UpdateNeedsRestart()
    local store = Store()
    local restart = store and store.restart
    if not Parse(restart) then
        return true
    end
    return DW.CompareVersions(MyVersion(), restart) < 0
end

-- Is automatic update turned on for this PC?
function DW.IsAutoUpdate()
    return DW.AUTO_UPDATE == true
end

local listeners = {}

-- Registers a function that is called when the addon hears about a newer version
-- (Innstillinger (settings) uses it to show that).
function DW.OnNewerVersion(callback)
    listeners[#listeners + 1] = callback
end

-- The window ----------------------------------------------------------------------

local popup
local shownFor -- the version the window was last shown for in this session

local function SelectLink(box)
    box:SetText(DW.DOWNLOAD_URL or "")
    box:HighlightText()
end

local function CreatePopup()
    local f = CreateFrame("Frame", "DragonworldUpdateNotice", UIParent, "BackdropTemplate")
    f:SetSize(440, 236)
    f:SetPoint("TOP", 0, -140)
    f:SetFrameStrata("DIALOG")
    f:SetBackdrop({
        bgFile = "Interface\\Buttons\\WHITE8X8",
        edgeFile = "Interface\\DialogFrame\\UI-DialogBox-Border",
        edgeSize = 16,
        insets = { left = 4, right = 4, top = 4, bottom = 4 },
    })
    f:SetBackdropColor(0.04, 0.04, 0.06, 0.97)
    f:SetBackdropBorderColor(0.90, 0.72, 0.30, 1)
    f:EnableMouse(true)
    f:SetMovable(true)
    f:SetClampedToScreen(true)
    f:RegisterForDrag("LeftButton")
    f:SetScript("OnDragStart", function(self)
        self:StartMoving()
    end)
    f:SetScript("OnDragStop", function(self)
        self:StopMovingOrSizing()
    end)
    f:Hide()
    table.insert(UISpecialFrames, "DragonworldUpdateNotice") -- Escape closes

    f.logo = f:CreateTexture(nil, "ARTWORK")
    f.logo:SetSize(56, 56)
    f.logo:SetPoint("TOPLEFT", 14, -12)
    f.logo:SetTexture(DW.ICON)

    f.title = f:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
    f.title:SetPoint("TOPLEFT", f.logo, "TOPRIGHT", 10, -6)
    f.title:SetPoint("RIGHT", -16, 0)
    f.title:SetJustifyH("LEFT")

    f.text = f:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
    f.text:SetPoint("TOPLEFT", f.title, "BOTTOMLEFT", 0, -6)
    f.text:SetPoint("RIGHT", -16, 0)
    f.text:SetJustifyH("LEFT")

    f.how = f:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    f.how:SetPoint("TOPLEFT", 18, -84)
    f.how:SetPoint("RIGHT", -18, 0)
    f.how:SetJustifyH("LEFT")

    -- The link in a text field, so it can be copied with Ctrl+C.
    f.link = CreateFrame("EditBox", nil, f, "InputBoxTemplate")
    f.link:SetSize(396, 22)
    f.link:SetPoint("TOPLEFT", 24, -146)
    f.link:SetAutoFocus(false)
    f.link:SetScript("OnEditFocusGained", SelectLink)
    f.link:SetScript("OnTextChanged", function(self, userInput)
        if userInput then
            SelectLink(self) -- the text must not be editable
        end
    end)
    f.link:SetScript("OnEscapePressed", function(self)
        self:ClearFocus()
    end)

    -- What is new, just above the buttons. The window grows to make room for it.
    f.news = f:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
    f.news:SetWidth(404)
    f.news:SetPoint("BOTTOMLEFT", 18, 54)
    f.news:SetJustifyH("LEFT")
    f.news:Hide()

    -- Gold: OK, or "Reload now" when a /reload is all that's needed.
    f.ok = DW.CreateButton(f, 130, 28, "gold")
    f.ok:SetPoint("BOTTOM", 0, 16)
    f.ok:SetScript("OnClick", function(self)
        f:Hide()
        if self.reload and ReloadUI then
            ReloadUI()
        end
    end)

    -- "Later", next to "Reload now".
    f.later = DW.CreateChip(f, 110, 28)
    f.later.label:SetJustifyH("CENTER")
    f.later:SetPoint("LEFT", f.ok, "RIGHT", 10, 0)
    f.later:SetScript("OnClick", function()
        f:Hide()
    end)

    return f
end

local sample = false -- true while the window shows an example (/dw nytt)

local function RefreshPopup()
    if not popup then
        return
    end
    -- The example looks like a real one with automatic updates, with our own
    -- version and its news.
    local newest = sample and MyVersion() or DW.NewestVersion()
    local auto = sample or DW.IsAutoUpdate()
    local reload = sample or (DW.IsAutoUpdate() and not DW.UpdateNeedsRestart())

    local news, newsHeight = DW.NewestNews(), 0
    if sample then
        news = NewsIn(DW.RELEASE_NEWS, DW.GetLanguage())
    end
    if news then
        popup.news:SetText(("|cffffd100%s|r %s"):format(L.UP_NEWS:format(newest), Plain(news)))
        popup.news:Show()
        newsHeight = math.ceil(popup.news:GetStringHeight() or 0) + 10
    else
        popup.news:SetText("")
        popup.news:Hide()
    end

    if auto then
        -- Everything is downloaded: only /reload or a restart remains.
        popup:SetHeight(160 + newsHeight)
        popup.title:SetText(L.UP_READY_TITLE)
        popup.text:SetText((reload and L.UP_READY_RELOAD or L.UP_READY_RESTART):format(newest))
        popup.how:Hide()
        popup.link:Hide()
    else
        popup:SetHeight(236 + newsHeight)
        popup.title:SetText(L.UP_TITLE)
        popup.text:SetText(L.UP_TEXT:format(newest, MyVersion()))
        popup.how:SetText(L.UP_HOW)
        popup.link:SetText(DW.DOWNLOAD_URL or "")
        popup.how:Show()
        popup.link:Show()
    end

    popup.ok.reload = reload and not sample -- the example's button only closes it
    popup.ok.label:SetText(reload and L.UP_RELOAD_NOW or L.UP_OK)
    popup.ok:ClearAllPoints()
    if reload then
        popup.ok:SetPoint("BOTTOM", -60, 16)
        popup.later.label:SetText(L.UP_LATER)
        popup.later:Show()
    else
        popup.ok:SetPoint("BOTTOM", 0, 16)
        popup.later:Hide()
    end
end

-- Shows the window. Also used by the button under Innstillinger.
function DW.ShowUpdatePopup()
    if not popup then
        popup = CreatePopup()
    end
    sample = false
    RefreshPopup()
    popup:Show()
end

-- "/dw nytt": what the window looks like when a new version is ready, with
-- the news of the version we have.
function DW.ShowUpdateSample()
    if not popup then
        popup = CreatePopup()
    end
    sample = true
    RefreshPopup()
    popup:Show()
end

local waitingForCombat = false
local waitingUntil -- the time the window waits for (automatic update)

-- When has the newest surely been fetched by the background job? nil = now.
local function ReadyAt()
    if not DW.IsAutoUpdate() then
        return nil
    end
    local store = Store()
    local releasedAt = store and tonumber(store.releasedAt)
    if not releasedAt then
        return nil
    end
    local ready = releasedAt + AUTO_DELAY
    return ready > Now() and ready or nil
end

-- Shows the window if the addon is outdated and it hasn't been shown for this
-- version in this session. Waits until combat is over, and with automatic
-- update until the new version has surely been downloaded.
local function MaybeShowPopup()
    if not DW.IsMember() or not DW.IsOutdated() then
        return
    end
    local newest = DW.NewestVersion()
    if shownFor == newest then
        return
    end
    local ready = ReadyAt()
    if ready then
        -- One pending check at a time; if it fires too early, it waits again.
        if waitingUntil ~= ready and C_Timer and C_Timer.After then
            waitingUntil = ready
            C_Timer.After(ready - Now() + 1, function()
                waitingUntil = nil
                MaybeShowPopup()
            end)
        end
        return
    end
    if InCombatLockdown and InCombatLockdown() then
        waitingForCombat = true
        return
    end
    shownFor = newest
    if DW.IsAutoUpdate() then
        DW.Print((DW.UpdateNeedsRestart() and L.UP_CHAT_RESTART or L.UP_CHAT_RELOAD):format(newest))
    else
        DW.Print(L.UP_CHAT:format(newest, MyVersion(), DW.DOWNLOAD_URL or ""))
    end
    DW.ShowUpdatePopup()
end

-- Messages ------------------------------------------------------------------------

local Send = DW.CreateSender(PREFIX)

local function SendMine()
    Send(table.concat({
        "V", MyVersion(), TocVersion(), DW.RESTART_RELEASE or MyVersion(), ("%d"):format(tonumber(DW.RELEASED_AT) or 0),
    }, SEP))
end

-- What's new: asking -------------------------------------------------------------

local askedAt = {} -- [version .. SEP .. language] = when we last asked

-- Asks for the news of the newest version, in our language, unless we have it
-- or asked a moment ago.
local function AskForNews()
    local store = Store()
    if not store or not store.newest or not DW.IsMember() then
        return
    end
    local lang = DW.GetLanguage()
    if store.newsFor == store.newest and store.newsLang == lang then
        return
    end
    local key = store.newest .. SEP .. lang
    if askedAt[key] and GetTime() - askedAt[key] < ASK_AGAIN then
        return
    end
    askedAt[key] = GetTime()
    Send(table.concat({ "Q", store.newest, lang }, SEP))
end

DW.OnLanguageChanged(function()
    RefreshPopup()
    AskForNews()
end)

-- What's new: answering ----------------------------------------------------------

local newsPlanned = {}  -- [language] = true while an answer is on its way
local newsHeardAt = {}  -- [version .. SEP .. language] = when someone last sent it

-- Cuts text to at most room bytes without splitting a letter (UTF-8).
local function Fit(text, room)
    if #text <= room then
        return text
    end
    local cut = room
    while cut > 0 do
        local byte = text:byte(cut + 1)
        if not byte or byte < 0x80 or byte >= 0xC0 then
            break -- the next byte starts a new letter
        end
        cut = cut - 1
    end
    return text:sub(1, cut)
end

-- Someone asked what is new in our version. Answer after a short, random delay,
-- unless someone else answered in the same language meanwhile.
local function PlanNews(lang)
    if newsPlanned[lang] or not (C_Timer and C_Timer.After) or not NewsIn(DW.RELEASE_NEWS, lang) then
        return
    end
    newsPlanned[lang] = true
    local planned = GetTime()
    C_Timer.After(REPLY_MIN + math.random() * REPLY_SPREAD, function()
        newsPlanned[lang] = nil
        local version = MyVersion()
        if not DW.IsMember() or (newsHeardAt[version .. SEP .. lang] or 0) >= planned then
            return
        end
        local head = table.concat({ "N", version, lang, "" }, SEP)
        Send(head .. Fit(NewsIn(DW.RELEASE_NEWS, lang), MAX_MESSAGE - #head))
    end)
end

-- After updating: the news of the version we now have, once, in chat. Not on
-- a first install (no language chosen yet, nothing remembered).
function DW.ShowInstalledNews()
    local store = Store()
    if not store then
        return
    end
    local before = store.running
    store.running = MyVersion()
    local updated
    if Parse(before) then
        updated = DW.CompareVersions(MyVersion(), before) > 0
    else
        updated = DW.HasChosenLanguage() -- from a version that did not remember this
    end
    local news = NewsIn(DW.RELEASE_NEWS, DW.GetLanguage())
    if updated and news then
        DW.Print(L.UP_INSTALLED:format(MyVersion(), Plain(news)))
    end
end

local replyPlanned = false
local heardAtLeastMine = 0 -- when someone last said a version equal to or newer than ours

-- Someone has an older version. Reply with ours after a short, random delay,
-- so not everyone replies at once. If someone else replied meanwhile, that's enough.
local function PlanReply()
    if replyPlanned or not (C_Timer and C_Timer.After) then
        return
    end
    replyPlanned = true
    local planned = GetTime()
    C_Timer.After(REPLY_MIN + math.random() * REPLY_SPREAD, function()
        replyPlanned = false
        if DW.IsMember() and heardAtLeastMine < planned then
            SendMine()
        end
    end)
end

local lastHeard -- for debugging: "Name: version"

DW.OnGuildMessage(PREFIX, function(text, sender)
    local fields = {}
    for field in (text .. SEP):gmatch("(.-)" .. SEP) do
        fields[#fields + 1] = field
    end
    local kind, version = fields[1], fields[2]
    if not Parse(version) then
        return
    end

    if kind == "Q" then
        local lang = fields[3]
        if version == MyVersion() and type(lang) == "string" and lang:match("^%a%a$") then
            PlanNews(lang)
        end
        return
    elseif kind == "N" then
        -- The text is everything after the third tab.
        local lang, news = text:match("^N\t[^\t]*\t(%a%a)\t(.+)$")
        if not lang then
            return
        end
        newsHeardAt[version .. SEP .. lang] = GetTime()
        local store = Store()
        if store and version == store.newest and lang == DW.GetLanguage() then
            store.news, store.newsFor, store.newsLang = news, version, lang
            RefreshPopup()
        end
        return
    elseif kind ~= "V" then
        return
    end
    lastHeard = sender .. ": " .. version

    local compared = DW.CompareVersions(version, MyVersion())
    if compared >= 0 then
        heardAtLeastMine = GetTime()
    end
    if compared < 0 then
        PlanReply()
    elseif compared > 0 then
        local store = Store()
        if store then
            local restart = Parse(fields[4]) and fields[4] or nil
            local releasedAt = tonumber(fields[5])
            if releasedAt and (releasedAt <= 0 or releasedAt > Now() + 86400) then
                releasedAt = nil
            end
            local newer = DW.CompareVersions(version, store.newest or MyVersion()) > 0
            if newer then
                store.newest = version
                store.from = (sender:match("^([^-]+)")) or sender
                store.restart, store.releasedAt = restart, releasedAt
            elseif version == store.newest then
                -- Same version from someone else: fill in what we were missing.
                store.restart = store.restart or restart
                store.releasedAt = store.releasedAt or releasedAt
            end
            if newer then
                for _, callback in ipairs(listeners) do
                    pcall(callback, version)
                end
            end
        end
        AskForNews()
        MaybeShowPopup()
    end
end)

-- Login -------------------------------------------------------------------------

local helloSent = false

local function PlanHello()
    if helloSent or not (C_Timer and C_Timer.After) then
        return
    end
    helloSent = true
    C_Timer.After(HELLO_DELAY, function()
        if DW.IsMember() then
            SendMine()
            DW.ShowInstalledNews()
            AskForNews() -- for a newer version we heard of last time
        else
            helloSent = false -- try again when the guild is known
        end
    end)
    -- If we already knew of a newer version, the window comes a little later.
    C_Timer.After(POPUP_DELAY, MaybeShowPopup)
end

local frame = CreateFrame("Frame")
frame:SetScript("OnEvent", function(self, event)
    if event == "PLAYER_REGEN_ENABLED" then
        if waitingForCombat then
            waitingForCombat = false
            MaybeShowPopup()
        end
    elseif DW.IsMember() then
        PlanHello()
    end
end)
pcall(frame.RegisterEvent, frame, "PLAYER_ENTERING_WORLD")
pcall(frame.RegisterEvent, frame, "PLAYER_REGEN_ENABLED")

DW.OnMembershipChanged(function(member)
    if member then
        PlanHello()
    end
end)

DW.AddDebug("versjon", function(add)
    local store = Store()
    add("min: " .. DW.DebugText(MyVersion()) .. " | toc: " .. DW.DebugText(TocVersion())
        .. " | automatisk: " .. DW.DebugText(DW.IsAutoUpdate()) .. " | omstart fra: " .. DW.DebugText(DW.RESTART_RELEASE)
        .. " | nyeste kjente: " .. DW.DebugText(DW.NewestVersion()) .. " | fra: " .. DW.DebugText(store and store.from)
        .. " | omstart: " .. DW.DebugText(store and store.restart) .. " | utlagt: " .. DW.DebugText(store and store.releasedAt)
        .. " | nytt for: " .. DW.DebugText(store and store.newsFor) .. " | sist hørt: " .. DW.DebugText(lastHeard))
end)
