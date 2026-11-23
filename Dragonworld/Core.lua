-- Dragonworld
-- Guild-addon for Dragonworld (WoW Forever, interface 16001).
--
-- This file is the core. It does three things:
--   1. Keeps track of the modules. Each feature of the addon is a module in
--      the Modules folder.
--   2. Gives each module its own storage that is remembered between sessions.
--   3. Provides the /dw command.
--
-- The other files:
--   Locales.lua     all text, in English, Norwegian and Dutch
--   MainWindow.lua  the main window: logo, guild name, module chips, settings
--   Minimap.lua     the minimap button
--
-- How to add a new module:
--   1. Create Modules\MinModul.lua and start it with:  local ADDON_NAME, DW = ...
--   2. Call DW.RegisterModule({ id = "minmodul", ... })  (see below)
--   3. Add the texts to Locales.lua in all three languages.
--   4. Add the line Modules\MinModul.lua at the bottom of Dragonworld.toc

local ADDON_NAME, DW = ...
local L = DW.L

DW.modules = {}     -- [id] = module
DW.moduleOrder = {} -- the modules in the order they were registered

-- The guild logo, made from the image in the Iconer folder (outside the addon).
--   ICON          the whole shield. Also set as IconTexture in Dragonworld.toc,
--                 so it shows in the addon list.
--   MINIMAP_ICON  a round crop of the dragon head, for the minimap button.
local MEDIA = "Interface\\AddOns\\" .. ADDON_NAME .. "\\Media\\"
DW.MEDIA = MEDIA -- the folder with the addon's own images, for modules that have their own icons
DW.ICON = MEDIA .. "icon"
DW.MINIMAP_ICON = MEDIA .. "minimap"

local PREFIX = "|cff33ff99Dragonworld:|r "

function DW.Print(message)
    print(PREFIX .. message)
end

function DW.PrintError(where, problem)
    DW.Print("|cffff5555" .. where .. "|r " .. tostring(problem))
end

-- The modern client can give "secret" values that addons are not allowed to
-- compare or do arithmetic on. Modules use this to skip such values.
function DW.IsSecret(value)
    return type(issecretvalue) == "function" and issecretvalue(value)
end

-- Gives a key that is unique to the character you are logged in on, e.g.
-- "Anna-Stormrage", plus name and realm separately. Used by modules that
-- store something per character. Returns nothing if the name is not ready yet.
function DW.CharacterKey()
    local name, realm = UnitFullName("player")
    if type(name) ~= "string" or DW.IsSecret(name) or name == "" then
        return nil
    end
    if type(realm) ~= "string" or DW.IsSecret(realm) or realm == "" then
        realm = (GetNormalizedRealmName and GetNormalizedRealmName()) or ""
        if type(realm) ~= "string" or DW.IsSecret(realm) then
            realm = ""
        end
    end
    return name .. "-" .. realm, name, realm
end

-- The character's permanent ID in the game (e.g. "Player-1234-0ABCDEF1"). Used
-- to recognize a player however the name is written. In Forever, names can
-- have spaces, and the game does not report them the same everywhere, so the
-- ID is the safest.
function DW.MyGUID()
    local guid = UnitGUID and UnitGUID("player")
    if type(guid) == "string" and not DW.IsSecret(guid) and guid ~= "" then
        return guid
    end
    return nil
end

-- A name in a form that can be compared: without realm, without spaces and in
-- lowercase. "Anna Berg-Stormrage" and "AnnaBerg" both become "annaberg".
function DW.NameKey(name)
    if type(name) ~= "string" or DW.IsSecret(name) then
        return ""
    end
    local short = name:match("^([^-]+)") or name
    return (short:lower():gsub("%s+", ""))
end

-- The realm you play on, lowercase and without spaces, or nil if not known.
local function MyRealmKey()
    local realm = GetNormalizedRealmName and GetNormalizedRealmName()
    if type(realm) ~= "string" or DW.IsSecret(realm) or realm == "" then
        return nil
    end
    return (realm:lower():gsub("%s+", ""))
end

-- A name in the form used to tell who someone is. Unlike DW.NameKey it keeps
-- the whole name: Forever can give first and last name as name and realm
-- ("Akro-Polis"), while the roster has "Akro Polis-Stormrage". So only the
-- realm you play on is dropped, then spaces and "-": both become "akropolis",
-- and "Akro Smith" stays apart from "Akro Polis". Use DW.SameCharacter to compare.
function DW.IdentityKey(name)
    if type(name) ~= "string" or DW.IsSecret(name) or name == "" then
        return ""
    end
    local text = name:lower():gsub("%s+", "")
    local realm = MyRealmKey()
    if realm then
        local base, suffix = text:match("^(.+)%-([^%-]+)$")
        if base and suffix == realm then
            text = base
        end
    end
    return (text:gsub("%-", ""))
end

-- Only the first name, lowercase: "Akro Polis-Stormrage" and "Akro-Polis"
-- both give "akro".
function DW.FirstNameKey(name)
    if type(name) ~= "string" or DW.IsSecret(name) then
        return ""
    end
    return (name:match("^[%s%-]*([^%s%-]+)") or ""):lower()
end

-- Chat --------------------------------------------------------------------------

-- Sends a chat message ("GUILD", "PARTY", "WHISPER" with a target, ...).
-- "|" becomes "/" (the game only accepts real links), and the text is cut to
-- 255 bytes without splitting a letter. The modern C_ChatInfo form comes
-- first: the old global exists only with the deprecation setting on.
-- Returns true if the game took the message.
function DW.SendChat(text, chatType, target)
    if type(text) ~= "string" or DW.IsSecret(text) or text == "" then
        return false
    end
    text = text:gsub("|", "/")
    if #text > 255 then
        local cut = 256
        -- Step back while the byte at the cut continues a UTF-8 letter.
        while cut > 1 do
            local byte = text:byte(cut)
            if not byte or byte < 0x80 or byte > 0xBF then
                break
            end
            cut = cut - 1
        end
        text = text:sub(1, cut - 1)
    end
    local send = (C_ChatInfo and C_ChatInfo.SendChatMessage) or SendChatMessage
    if type(send) ~= "function" then
        return false
    end
    if C_ChatInfo and type(C_ChatInfo.InChatMessagingLockdown) == "function" then
        local ok, locked = pcall(C_ChatInfo.InChatMessagingLockdown)
        if ok and not DW.IsSecret(locked) and locked == true then
            return false
        end
    end
    if target then
        return (pcall(send, text, chatType, nil, target))
    end
    return (pcall(send, text, chatType))
end

-- Opens a whisper to the player in the chat line.
function DW.WhisperTo(name)
    if ChatFrameUtil and type(ChatFrameUtil.SendTell) == "function" then
        ChatFrameUtil.SendTell(name)
    elseif type(ChatFrame_SendTell) == "function" then
        ChatFrame_SendTell(name)
    else
        DW.Print("/w " .. tostring(name))
    end
end

-- Puts a link in the open chat line. Returns what the game returns (true if
-- a chat line was open), or false. ChatEdit_InsertLink only exists with the
-- deprecation setting on.
function DW.InsertChatLink(link)
    if link == nil then
        return false
    end
    if ChatFrameUtil and type(ChatFrameUtil.InsertLink) == "function" then
        return ChatFrameUtil.InsertLink(link)
    elseif type(ChatEdit_InsertLink) == "function" then
        return ChatEdit_InsertLink(link)
    end
    return false
end

-- The guild's message of the day as plain text, or "". GetGuildRosterMOTD is
-- only a deprecation fallback in Forever.
function DW.GuildMOTD()
    local read = (C_GuildInfo and type(C_GuildInfo.GetMOTD) == "function" and C_GuildInfo.GetMOTD)
        or (type(GetGuildRosterMOTD) == "function" and GetGuildRosterMOTD)
    if not read then
        return ""
    end
    local ok, motd = pcall(read)
    if ok and type(motd) == "string" and not DW.IsSecret(motd) then
        return motd
    end
    return ""
end

local function PlainNumber(value)
    if type(value) == "number" and not DW.IsSecret(value) then
        return value
    end
    return 0
end

local function PlainText(value)
    if type(value) == "string" and not DW.IsSecret(value) then
        return value
    end
    return ""
end

-- Reads the game's own member list. It has everyone in the guild, also those
-- who are offline. Each entry has:
--   key       the name as the game reports it (usually "Name-Realm")
--   name      the name without realm
--   guid      the player's permanent ID, if the game reports it
--   level, class (e.g. "MAGE"), rank, rankIndex (0 = Guild Master, nil if
--   unknown), zone, note
--   online    true if online now
--   days, hours   how long since last seen, for those who are offline
--   points    the achievement points the game reports (12th value), 0 if none.
--             In Forever the Legacy system is the game's version of
--             achievements, so this may be the legacy points. Not checked in
--             the game yet.
function DW.ReadGuildRoster()
    local members = {}
    if not (GetNumGuildMembers and GetGuildRosterInfo) then
        return members
    end

    for index = 1, PlainNumber(GetNumGuildMembers()) do
        local name, rankName, rankIndex, level, _, zone, note, _, isOnline, _, class, points, _, _, _, _, guid = GetGuildRosterInfo(index)
        if PlainText(name) ~= "" then
            local online = (not DW.IsSecret(isOnline)) and isOnline == true
            local days, hours = 0, 0
            if not online and GetGuildRosterLastOnline then
                local years, months, offlineDays, offlineHours = GetGuildRosterLastOnline(index)
                days = PlainNumber(years) * 365 + PlainNumber(months) * 30 + PlainNumber(offlineDays)
                hours = PlainNumber(offlineHours)
            end
            members[#members + 1] = {
                key = name,
                name = name:match("^([^-]+)") or name,
                guid = PlainText(guid) ~= "" and guid or nil,
                rank = PlainText(rankName),
                -- nil when the game gives no plain number: an unknown rank
                -- must never read as 0 (Guild Master).
                rankIndex = (type(rankIndex) == "number" and not DW.IsSecret(rankIndex)) and rankIndex or nil,
                level = PlainNumber(level),
                class = PlainText(class),
                zone = PlainText(zone),
                note = PlainText(note),
                online = online,
                days = days,
                hours = hours,
                points = PlainNumber(points),
            }
        end
    end
    return members
end

-- Debugging ---------------------------------------------------------------------

-- "/dw debug" prints what the addon sees for this exact player: name, ID,
-- guild, professions and so on. It is meant to be sent to whoever develops
-- the addon when something does not work. Modules add their own part.
local debugSections = {}

function DW.AddDebug(title, provider)
    debugSections[#debugSections + 1] = { title = title, provider = provider }
end

-- Text of a value, without touching values the game has made secret.
function DW.DebugText(value)
    if DW.IsSecret(value) then
        return "<secret>"
    end
    return tostring(value)
end

function DW.PrintDebug()
    DW.Print("debug")
    for _, section in ipairs(debugSections) do
        local lines = {}
        local ok, problem = pcall(section.provider, function(text)
            lines[#lines + 1] = tostring(text)
        end)
        print("  [" .. section.title .. "]")
        for _, line in ipairs(lines) do
            print("    " .. line)
        end
        if not ok then
            print("    FEIL: " .. tostring(problem))
        end
    end
end

DW.AddDebug("identitet", function(add)
    local key, name, realm = DW.CharacterKey()
    local text = DW.DebugText
    add("CharacterKey: " .. text(key) .. " | name: " .. text(name) .. " | realm: " .. text(realm))
    add("IdentityKey: " .. text(DW.IdentityKey(key)) .. " | realm (normalized): "
        .. text(GetNormalizedRealmName and GetNormalizedRealmName()))
    add("UnitName: " .. text(UnitName and UnitName("player")) .. " | GUID: " .. text(DW.MyGUID()))
    add("level: " .. text(UnitLevel and UnitLevel("player")) .. " | class: " .. text(UnitClass and select(2, UnitClass("player"))))
    add("IsInGuild: " .. text(IsInGuild and IsInGuild()) .. " | guild: " .. text(GetGuildInfo and GetGuildInfo("player"))
        .. " | medlem: " .. text(DW.IsMember()) .. " | personlig: " .. text(DW.HasAccess())
        .. " | guild-alt: " .. text(DW.MemberAlt()))
    add("språk: " .. text(DW.GetLanguage()) .. " | interface: " .. text(GetBuildInfo and select(4, GetBuildInfo())))

    local roster = DW.ReadGuildRoster()
    add("medlemsliste: " .. #roster .. " medlemmer")
    local guid = DW.MyGUID()
    for _, member in ipairs(roster) do
        if (guid and member.guid == guid) or (key and DW.SameCharacter and DW.SameCharacter(member.key, key)) then
            add("min rad: key=" .. text(member.key) .. " | guid=" .. text(member.guid) .. " | class=" .. text(member.class)
                .. " | level=" .. text(member.level))
        end
    end
end)

-- Membership --------------------------------------------------------------------

-- The addon only works for characters that are in the guild. This is a simple
-- lock, not security: the code is open to anyone who has the files, and a
-- guild with the same name on another realm gets through too.
--
-- Alts outside the guild: the saved data is shared by all characters on the
-- account, so we remember which of them are in the guild. When one of them is,
-- the other characters get the personal tabs (modules with personal = true:
-- bags, bank, gold, professions, keybinds). Nothing from the guild is shown
-- or sent on them. A character that is seen outside the guild is forgotten.
--
-- Modules that do something on their own (tooltip, events) must check
-- DW.IsMember() (guild modules) or DW.HasAccess() (personal modules) first.
-- Commands use DW.Guard() or DW.GuardPersonal(), which also explain to the
-- player why nothing happens.
DW.GUILD_NAME = "Dragonworld"

local isMember = false
local hasAccess = false
local currentGuild -- the name of the guild the character is in, if known
local memberListeners = {}
local accessListeners = {}

function DW.IsMember()
    return isMember
end

-- True if the personal tabs may be used: the character is a member, or
-- another character on the account is.
function DW.HasAccess()
    return hasAccess
end

-- True if the module (id or table) may be used on this character.
function DW.CanUseModule(module)
    if type(module) == "string" then
        module = DW.modules[module]
    end
    if isMember then
        return true
    end
    return hasAccess and type(module) == "table" and module.personal == true
end

-- Registers a function that is called when the character becomes or stops
-- being a member (e.g. when the guild name has loaded after login).
function DW.OnMembershipChanged(callback)
    memberListeners[#memberListeners + 1] = callback
end

-- Like OnMembershipChanged, for DW.HasAccess().
function DW.OnAccessChanged(callback)
    accessListeners[#accessListeners + 1] = callback
end

-- DragonworldDB.memberCharacters["Name-Realm"] = time last seen in the guild
local function MemberCharacters()
    if type(DragonworldDB) ~= "table" then
        return nil
    end
    if type(DragonworldDB.memberCharacters) ~= "table" then
        DragonworldDB.memberCharacters = {}
    end
    return DragonworldDB.memberCharacters
end

-- The name of another character on the account that is in the guild, if any.
function DW.MemberAlt()
    local list = MemberCharacters()
    local myKey = DW.CharacterKey()
    local best, bestTime
    for key, seen in pairs(list or {}) do
        if key ~= myKey and type(key) == "string" and (not bestTime or (tonumber(seen) or 0) > bestTime) then
            best, bestTime = key, tonumber(seen) or 0
        end
    end
    return best and (best:match("^(.-)%-") or best)
end

local function Notify(listeners, value)
    for _, callback in ipairs(listeners) do
        local ok, problem = pcall(callback, value)
        if not ok then
            DW.PrintError(L.ERROR, problem)
        end
    end
end

function DW.UpdateMembership()
    local member = isMember
    local known = true -- whether we know if this character is in Dragonworld

    if not (IsInGuild and IsInGuild()) then
        currentGuild = nil
        member = false
    else
        local name = GetGuildInfo("player")
        if type(name) == "string" and not DW.IsSecret(name) then
            currentGuild = name
            -- Case and spaces do not matter, so
            -- "Dragon World" and "dragonworld" are accepted too.
            local function Plain(text)
                return (text:lower():gsub("%s+", ""))
            end
            member = (Plain(name) == Plain(DW.GUILD_NAME))
        else
            -- The name can be missing right after login. Then we keep what we
            -- knew, and the game notifies us again when it is ready.
            known = false
        end
    end

    local list = MemberCharacters()
    local key = DW.CharacterKey()
    if list and key and known then
        list[key] = member and (time and time() or true) or nil
    end
    local access = member or (list ~= nil and next(list) ~= nil)

    if member ~= isMember then
        isMember = member
        Notify(memberListeners, member)
    end
    if access ~= hasAccess then
        hasAccess = access
        Notify(accessListeners, access)
    end
end

-- Explains in chat why the addon (or this part of it) is locked.
function DW.PrintLocked()
    DW.Print(L.LOCKED:format(DW.GUILD_NAME))
    DW.Print(currentGuild and L.LOCKED_GUILD:format(currentGuild) or L.LOCKED_NO_GUILD)
    local alt = hasAccess and DW.MemberAlt()
    if alt then
        DW.Print(L.LOCKED_PERSONAL:format(alt))
    end
end

-- For commands: true if the character is a member, otherwise the explanation is printed.
function DW.Guard()
    if isMember then
        return true
    end
    DW.PrintLocked()
    return false
end

-- For commands of personal modules: true if DW.HasAccess(), otherwise the
-- explanation is printed.
function DW.GuardPersonal()
    if hasAccess then
        return true
    end
    DW.PrintLocked()
    return false
end

-- Registers a module. The table can have these fields:
--   id          (required) short lowercase name without spaces. Used in
--               "/dw <id>" and as the key in storage, so do not change it.
--   titleKey    the name of the text in Locales.lua that is the module's name.
--   notesKey    the name of the text that says in one line what the module does.
--   shortcutKey the name of the text that is the module's own shortcut, e.g. "/kast".
--   icon        the icon on the module's chip in the main window (path or file ID).
--   personal    true if the module only uses this account's own characters
--               (no guild data), so alts outside the guild may use it too.
--   OnLoad(self, db)          called when saved data has been read. db is
--                             the module's own table, and everything in it is saved.
--   OnSlash(self, message)    called for "/dw <id> <message>".
--   CreatePanel(self, parent) creates the module's content in the main window
--                             and returns the frame. Called once, the first
--                             time the module is selected. Modules that have
--                             this get a chip in the main window.
-- (title and notes can be used instead of titleKey and notesKey if the text
-- should not be translated.)
function DW.RegisterModule(module)
    assert(type(module) == "table", "RegisterModule: mangler modul")
    assert(type(module.id) == "string" and module.id:match("^[%l%d]+$"),
        "RegisterModule: id må være små bokstaver/tall uten mellomrom")
    assert(type(module.titleKey) == "string" or type(module.title) == "string",
        "RegisterModule: mangler titleKey")
    assert(not DW.modules[module.id], "RegisterModule: id er brukt fra før: " .. module.id)

    DW.modules[module.id] = module
    DW.moduleOrder[#DW.moduleOrder + 1] = module
    return module
end

-- Sections of the Home page ("While you were away", Modules\Home.lua). Any
-- file may register one; Home shows them sorted by order, then id.
--   id          (required) short unique name
--   order       where it goes (lower first)
--   titleKey    the text in Locales.lua that is the section's heading
--   icon        the heading's icon
--   Lines(ctx)  (required) returns a list of lines. ctx = { since, now,
--               before (this section's Snapshot value from the previous
--               session), hasRosterBaseline, Member(key) }. since is nil the
--               first time. Member takes a "Player-" GUID, "name:x" or
--               "Name-Realm" and gives the roster row, or nil.
--   Snapshot()  optional: a small saveable value, kept at logout and given
--               back as ctx.before next session. It must return a value it
--               already has, not call the game (the game may be gone).
-- A line is { text (required), icon, when (server time, shown as time ago),
-- changed (true: counts as new and goes in the chat summary), member (a
-- roster row: a click opens the card), onClick (when there is no member),
-- tab (module id, for the tooltip), tip, muted, button = { text, onClick } }.
DW.HOME_SECTIONS = {}

function DW.RegisterHomeSection(section)
    assert(type(section) == "table", "RegisterHomeSection: mangler seksjon")
    assert(type(section.id) == "string" and section.id ~= "", "RegisterHomeSection: mangler id")
    assert(type(section.Lines) == "function", "RegisterHomeSection: mangler Lines")
    for _, existing in ipairs(DW.HOME_SECTIONS) do
        if existing.id == section.id then
            return existing
        end
    end
    DW.HOME_SECTIONS[#DW.HOME_SECTIONS + 1] = section
    return section
end

-- A name in its class colour ("MAGE", "PRIEST", ...), or as it is when the
-- class is unknown.
function DW.ColoredName(name, class)
    local colour = RAID_CLASS_COLORS and RAID_CLASS_COLORS[class]
    if colour and colour.r then
        local function Byte(value)
            return math.floor(math.max(0, math.min(1, value)) * 255 + 0.5)
        end
        return ("|cff%02x%02x%02x%s|r"):format(Byte(colour.r), Byte(colour.g), Byte(colour.b), name)
    end
    return name
end

-- The module's name and description in the chosen language.
function DW.ModuleTitle(module)
    return (module.titleKey and L[module.titleKey]) or module.title or module.id
end

function DW.ModuleNotes(module)
    return (module.notesKey and L[module.notesKey]) or module.notes or ""
end

-- Storage ---------------------------------------------------------------------

local frame = CreateFrame("Frame")
frame:RegisterEvent("ADDON_LOADED")
-- The guild name is not always ready at login, so check again every time
-- the game reports something about the guild.
for _, event in ipairs({ "PLAYER_LOGIN", "PLAYER_ENTERING_WORLD", "PLAYER_GUILD_UPDATE", "GUILD_ROSTER_UPDATE" }) do
    pcall(frame.RegisterEvent, frame, event)
end

frame:SetScript("OnEvent", function(self, event, name)
    if event ~= "ADDON_LOADED" then
        DW.UpdateMembership()
        -- The guild name can arrive a bit after login without the game
        -- saying so. So check a couple more times.
        if event == "PLAYER_ENTERING_WORLD" and not isMember and C_Timer and C_Timer.After then
            C_Timer.After(3, DW.UpdateMembership)
            C_Timer.After(10, DW.UpdateMembership)
        end
        return
    end
    if name ~= ADDON_NAME then
        return
    end
    self:UnregisterEvent("ADDON_LOADED")

    if type(DragonworldDB) ~= "table" then
        DragonworldDB = {}
    end
    if type(DragonworldDB.modules) ~= "table" then
        DragonworldDB.modules = {}
    end
    if type(DragonworldDB.minimap) ~= "table" then
        DragonworldDB.minimap = {}
    end

    -- Use the language the player chose last. If they have not chosen, English
    -- applies until the main window has asked.
    if DW.HasChosenLanguage() then
        DW.SetLanguage(DragonworldDB.language)
    end

    for _, module in ipairs(DW.moduleOrder) do
        local db = DragonworldDB.modules[module.id]
        if type(db) ~= "table" then
            db = {}
            DragonworldDB.modules[module.id] = db
        end
        module.db = db

        -- An error in one module must not stop the others from starting.
        if module.OnLoad then
            local ok, problem = pcall(module.OnLoad, module, db)
            if not ok then
                DW.PrintError(L.ERROR_IN:format(DW.ModuleTitle(module)), problem)
            end
        end
    end

    DW.UpdateMembership()

    -- The minimap button (Minimap.lua).
    if DW.InitMinimapButton then
        local ok, problem = pcall(DW.InitMinimapButton, DragonworldDB.minimap)
        if not ok then
            DW.PrintError(L.ERROR, problem)
        end
    end
end)

-- Commands --------------------------------------------------------------------

-- The words work in all three languages, whichever is chosen.
local BUTTON_WORDS = { button = true, knapp = true, knop = true }

function DW.PrintHelp()
    DW.Print(L.HELP_HEADER)
    print("  " .. L.HELP_OPEN)
    for _, module in ipairs(DW.moduleOrder) do
        local command = (module.shortcutKey and L[module.shortcutKey]) or ("/dw " .. module.id)
        print(("  %s - %s: %s"):format(command, DW.ModuleTitle(module), DW.ModuleNotes(module)))
    end
    print("  " .. L.HELP_BUTTON)
end

SLASH_DRAGONWORLD1 = "/dw"
SLASH_DRAGONWORLD2 = "/dragonworld"

SlashCmdList["DRAGONWORLD"] = function(message)
    local word, rest = (message or ""):match("^%s*(%S+)%s*(.-)%s*$")

    -- Debugging always works, also when the addon is locked, so it is possible
    -- to find out why it is.
    if word and word:lower() == "debug" then
        DW.PrintDebug()
        return
    end

    -- An alt outside the guild may open the window (with the personal tabs),
    -- the personal modules and the minimap button. The rest is for members.
    local lower = word and word:lower()
    local personal = not word or BUTTON_WORDS[lower] or DW.CanUseModule(lower)
    if not (personal and DW.GuardPersonal() or (not personal and DW.Guard())) then
        return
    end

    -- Just "/dw": open or close the main window. If the button is flashing
    -- because something is new, the tab with the new thing opens (Alerts.lua).
    -- The action bar button is a macro with exactly "/dw".
    if not word then
        if DW.ClickOpen then
            DW.ClickOpen()
        elseif DW.ToggleMainWindow then
            DW.ToggleMainWindow()
        else
            DW.PrintHelp()
        end
        return
    end
    word = word:lower()

    -- "/dw <module> ...": pass the rest to the module, or open it.
    local module = DW.modules[word]
    if module and module.OnSlash then
        module:OnSlash(rest)
        return
    end
    if module and module.CreatePanel and DW.OpenModule then
        DW.OpenModule(module.id)
        return
    end

    -- "/dw blink": show what the flashing looks like (Alerts.lua).
    if word == "blink" and DW.TestBlink then
        DW.TestBlink(15)
        DW.Print(L.BLINK_TEST)
        return
    end

    -- "/dw nytt": the update window as it looks with this version's news (Update.lua).
    if (word == "nytt" or word == "news" or word == "nieuw") and DW.ShowUpdateSample then
        DW.ShowUpdateSample()
        return
    end

    if BUTTON_WORDS[word] and DW.ToggleMinimapButton then
        DW.Print(DW.ToggleMinimapButton() and L.BUTTON_SHOWN or L.BUTTON_HIDDEN)
        return
    end

    DW.PrintHelp()
end
