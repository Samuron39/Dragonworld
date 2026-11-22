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
--   level, class (e.g. "MAGE"), rank, rankIndex, zone, note
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
                rankIndex = PlainNumber(rankIndex),
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
    add("UnitName: " .. text(UnitName and UnitName("player")) .. " | GUID: " .. text(DW.MyGUID()))
    add("level: " .. text(UnitLevel and UnitLevel("player")) .. " | class: " .. text(UnitClass and select(2, UnitClass("player"))))
    add("IsInGuild: " .. text(IsInGuild and IsInGuild()) .. " | guild: " .. text(GetGuildInfo and GetGuildInfo("player"))
        .. " | medlem: " .. text(DW.IsMember()))
    add("språk: " .. text(DW.GetLanguage()) .. " | interface: " .. text(GetBuildInfo and select(4, GetBuildInfo())))

    local roster = DW.ReadGuildRoster()
    add("medlemsliste: " .. #roster .. " medlemmer")
    local guid = DW.MyGUID()
    for _, member in ipairs(roster) do
        if (guid and member.guid == guid) or DW.NameKey(member.key) == DW.NameKey(name) then
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
-- Modules that do something on their own (tooltip, events) must check
-- DW.IsMember() themselves first. Commands use DW.Guard(), which also explains
-- to the player why nothing happens.
DW.GUILD_NAME = "Dragonworld"

local isMember = false
local currentGuild -- the name of the guild the character is in, if known
local memberListeners = {}

function DW.IsMember()
    return isMember
end

-- Registers a function that is called when the character becomes or stops
-- being a member (e.g. when the guild name has loaded after login).
function DW.OnMembershipChanged(callback)
    memberListeners[#memberListeners + 1] = callback
end

function DW.UpdateMembership()
    local member = isMember

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
        end
        -- The name can be missing right after login. Then we keep what we
        -- knew, and the game notifies us again when it is ready.
    end

    if member ~= isMember then
        isMember = member
        for _, callback in ipairs(memberListeners) do
            local ok, problem = pcall(callback, member)
            if not ok then
                DW.PrintError(L.ERROR, problem)
            end
        end
    end
end

-- Explains in chat why the addon is locked.
function DW.PrintLocked()
    DW.Print(L.LOCKED:format(DW.GUILD_NAME))
    DW.Print(currentGuild and L.LOCKED_GUILD:format(currentGuild) or L.LOCKED_NO_GUILD)
end

-- For commands: true if the character is a member, otherwise the explanation is printed.
function DW.Guard()
    if isMember then
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

    if not DW.Guard() then
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
