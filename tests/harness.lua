-- Test harness: fakes the parts of the WoW API that Dragonworld uses, loads the
-- addon the way the game does, and checks languages, the main window, the
-- minimap button, slash commands and the Ryddesekk module.
-- ADDON_FILES / ADDON_FOLDER are injected by run.js.
--
-- The widget fakes only implement methods that exist on the real widgets, so a
-- misspelled method name in the addon fails here instead of in the game.

local failures, checks = 0, 0
local function check(label, cond, extra)
    checks = checks + 1
    if not cond then
        failures = failures + 1
        io.write("FAIL  ", label, extra ~= nil and ("  -> " .. tostring(extra)) or "", "\n")
    else
        io.write("ok    ", label, "\n")
    end
end

-- Captured chat output ---------------------------------------------------------
local chat = {}
function print(...)
    local parts = {}
    for i = 1, select("#", ...) do parts[#parts + 1] = tostring((select(i, ...))) end
    chat[#chat + 1] = table.concat(parts, " ")
end
-- The game's bit library (32-bit, results as unsigned numbers). This VM's whole
-- numbers are 32-bit and signed, so values are folded into that range first.
do
    local function toBits(x) x = x % 4294967296.0; if x >= 2147483648.0 then x = x - 4294967296.0 end; return math.tointeger(x) end
    local function fromBits(x) return x % 4294967296.0 end
    bit = {
        band = function(a, b) return fromBits(toBits(a) & toBits(b)) end,
        bor = function(a, b) return fromBits(toBits(a) | toBits(b)) end,
        bxor = function(a, b) return fromBits(toBits(a) ~ toBits(b)) end,
        bnot = function(a) return fromBits(~toBits(a)) end,
        rshift = function(a, n) assert(n >= 0 and n < 32); return fromBits(toBits(a) >> n) end,
        lshift = function(a, n) assert(n >= 0 and n < 32); return fromBits(toBits(a) << n) end,
    }
end
local function chatText() return table.concat(chat, "\n") end
local function clearChat() chat = {} end
local function has(text) return chatText():find(text, 1, true) ~= nil end

-- Secret values ----------------------------------------------------------------
local SECRET = setmetatable({}, { __tostring = function() return "<secret>" end })
function issecretvalue(v) return v == SECRET end

-- Items ------------------------------------------------------------------------
local ITEMS = {
    [1]  = { name = "Sealed Note",        quality = 1, classID = 12, bind = 4 },
    [2]  = { name = "Kobold Candle",      quality = 1, classID = 12, bind = 4 },
    [3]  = { name = "Old Journal",        quality = 1, classID = 12, bind = 4 },
    [4]  = { name = "Mysterious Map",     quality = 1, classID = 12, bind = 4 },
    [5]  = { name = "Faded Letter",       quality = 1, classID = 12, bind = 4 },
    [6]  = { name = "Qiraji Bindings",    quality = 4, classID = 12, bind = 1 },
    [7]  = { name = "Iron Sword",         quality = 1, classID = 2,  bind = 0 },
    [8]  = { name = "Banked Quest Thing", quality = 1, classID = 12, bind = 4 },
    [9]  = { name = "Totem of Testing",   quality = 1, classID = 12, bind = 4 },
    [10] = { name = "Unloaded Thing",     quality = 1, classID = 12, bind = 4, unloaded = true },
    [11] = { name = "Bind Only Scroll",   quality = 1, classID = 15, bind = 4 },
    [12] = { name = "Active Starter",     quality = 1, classID = 12, bind = 4 },
    -- crafting materials (class 7 = trade goods, sub = the kind: 5 cloth,
    -- 7 metal & stone, 12 enchanting), for the Materialer module
    [20] = { name = "Copper Ore",         quality = 1, classID = 7,  sub = 7,  bind = 0 },
    [21] = { name = "Linen Cloth",        quality = 1, classID = 7,  sub = 5,  bind = 0 },
    [22] = { name = "Strange Dust",       quality = 2, classID = 7,  sub = 12, bind = 0 },
    [23] = { name = "Empty Vial",         quality = 1, classID = 0,  bind = 0, reagent = true },   -- flagged as reagent, not class 7
    [24] = { name = "Unloaded Ore",       quality = 1, classID = 7,  sub = 7,  bind = 0, unloaded = true },
    -- quest items that should not be thrown away
    [30] = { name = "Incendicite Ore",    quality = 1, classID = 12, bind = 0 },   -- quest class, but not bound: can be sold
    [31] = { name = "Glowing Shard",      quality = 1, classID = 12, bind = 4 },   -- bound quest item that a recipe turns out to use
}
local function link(id)
    return ("|cnIQ1:|Hitem:%d::::::::60:::::|h[%s]|h|r"):format(id, ITEMS[id].name)
end

C_Item = {
    GetItemInfo = function(id)
        -- Like the game, it also takes an item string or link ("item:20:0:...").
        if type(id) == "string" then id = tonumber(id:match("item:(%d+)")) end
        local it = ITEMS[id]
        if not it or it.unloaded then return nil end
        return it.name, link(id), it.quality, 1, 1, "Type", "Sub", 1, "", 1000 + id, 0, it.classID, 0, it.bind, 0, nil, it.reagent or false
    end,
    -- Works without the item being loaded, like in the game.
    GetItemInfoInstant = function(id)
        local it = ITEMS[id]
        if not it then return nil end
        return id, "Type", "Sub", "", 1000 + id, it.classID, it.sub or 0
    end,
    RequestLoadItemDataByID = function(id) assert(type(id) == "number") end,
}
ITEM_QUALITY_COLORS = { [0] = { r = 0.6, g = 0.6, b = 0.6 }, [1] = { r = 1, g = 1, b = 1 }, [2] = { r = 0.12, g = 1, b = 0 },
                        [3] = { r = 0, g = 0.44, b = 0.87 }, [4] = { r = 0.64, g = 0.21, b = 0.93 } }
GetItemInfo = nil -- Forever has no global GetItemInfo.

-- Bags -------------------------------------------------------------------------
local BAGS = {
    [0] = { 1, 2, 3, 4 },
    [1] = { 5, 6, 7, false, 9 },
    [2] = { 10, 11, 12 },
}
local STACKS = {}                                        -- "bag:slot" -> stack size
local LOCKED = {}                                        -- "bag:slot" -> item is locked (being moved)
local STARTS = { [3] = 100, [4] = 101, [12] = 102 }     -- item -> quest it starts
local ACTIVE_STARTED = { [102] = true }
local COMPLETED = { [100] = true }
local questInfoThrows = false

-- Bank containers (6 and up) can only be read while the bank window is open.
local bankIsOpen = false

NUM_TOTAL_EQUIPPED_BAG_SLOTS = 5
C_Container = {
    GetContainerNumSlots = function(bag)
        if bag >= 6 and not bankIsOpen then return 0 end
        return BAGS[bag] and #BAGS[bag] or 0
    end,
    GetContainerItemID = function(bag, slot)
        local id = BAGS[bag] and BAGS[bag][slot]
        return id or nil
    end,
    GetContainerItemInfo = function(bag, slot)
        local id = BAGS[bag] and BAGS[bag][slot]
        if not id then return nil end
        -- Bound: bind-on-pickup (1) and quest items (4). BOUND_UNKNOWN makes
        -- the game leave the field out, like an older client.
        local it = ITEMS[id]
        local isBound = it ~= nil and (it.bind == 1 or it.bind == 4)
        if BOUND_UNKNOWN then isBound = nil end
        return { itemID = id, stackCount = STACKS[bag .. ":" .. slot] or 1, iconFileID = 1000 + id, hyperlink = link(id),
                 isLocked = LOCKED[bag .. ":" .. slot] or false, isBound = isBound }
    end,
    GetContainerItemQuestInfo = function(bag, slot)
        if questInfoThrows then error("boom from GetContainerItemQuestInfo") end
        local id = BAGS[bag] and BAGS[bag][slot]
        local questID = STARTS[id]
        local it = ITEMS[id]
        return {
            -- wiki: items that start quests are apparently not flagged isQuestItem
            isQuestItem = (it and it.classID == 12 and not questID) or nil,
            questID = questID,
            isActive = questID and ACTIVE_STARTED[questID] or false,
        }
    end,
}

-- Guild bank ---------------------------------------------------------------------
-- The client only knows what is in a tab after asking the server
-- (QueryGuildBankTab) and the answer has arrived (GUILDBANKBAGSLOTS_CHANGED, which
-- does not say which tab). Until then every slot reads as empty, exactly like
-- an empty tab. GBANK.loaded is what the client has received.
-- GBANK.tabs[n] = { name, icon, viewable, slots = { [slot] = { itemID, count } } }
-- (Global, like SERVER_NOW below: the main chunk is at Lua's limit of 200 locals.)
GBANK = { tabs = {}, current = 1, money = 0, loaded = {}, queries = {}, asked = {} }
function GetNumGuildBankTabs() return #GBANK.tabs end
function GetGuildBankTabInfo(tab)
    local t = GBANK.tabs[tab]
    if not t then return nil end
    return t.name, t.icon, t.viewable ~= false, true, 0, 0, false
end
function GetCurrentGuildBankTab() return GBANK.current end
function QueryGuildBankTab(tab)
    assert(type(tab) == "number" and GBANK.tabs[tab], "QueryGuildBankTab: no such tab")
    GBANK.queries[#GBANK.queries + 1] = tab
    GBANK.asked[#GBANK.asked + 1] = tab
end
function GetGuildBankItemLink(tab, slot)
    assert(type(slot) == "number" and slot >= 1 and slot <= 98, "guild bank slot out of range")
    local t = GBANK.tabs[tab]
    local s = t and GBANK.loaded[tab] and t.slots[slot]
    return s and link(s[1]) or nil
end
function GetGuildBankItemInfo(tab, slot)
    assert(type(slot) == "number" and slot >= 1 and slot <= 98, "guild bank slot out of range")
    local t = GBANK.tabs[tab]
    local s = t and GBANK.loaded[tab] and t.slots[slot]
    if not s then return nil, 0 end
    return 1000 + s[1], s[2], false, false, ITEMS[s[1]].quality
end
function GetGuildBankMoney() return GBANK.money end

-- Cursor and deleting ------------------------------------------------------------
-- Models the game's rule: DeleteCursorItem only works during a hardware event
-- (a click), and only once per event. hardwareBudget is how many deletions the
-- current "click" still allows; outside a click it is 0.
local cursorItem                                         -- { bag, slot, id } held on the cursor
local hardwareBudget = 0
local deleted = {}                                       -- item ids, in the order they were destroyed
function ClearCursor() cursorItem = nil end
function GetCursorInfo()
    if cursorItem then return "item", cursorItem.id, link(cursorItem.id) end
end
C_Container.PickupContainerItem = function(bag, slot)
    assert(type(bag) == "number" and type(slot) == "number", "PickupContainerItem needs bag and slot")
    assert(cursorItem == nil, "picked up an item while the cursor already held one")
    local id = BAGS[bag] and BAGS[bag][slot]
    if id and not LOCKED[bag .. ":" .. slot] then cursorItem = { bag = bag, slot = slot, id = id } end
end
function DeleteCursorItem()
    if not cursorItem or hardwareBudget < 1 then return end      -- refused: item stays on the cursor
    hardwareBudget = hardwareBudget - 1
    BAGS[cursorItem.bag][cursorItem.slot] = false
    deleted[#deleted + 1] = cursorItem.id
    cursorItem = nil
end

-- Quest log --------------------------------------------------------------------
local LOG = {
    { isHeader = true, title = "Elwynn Forest" },
    { questID = 200, title = "Note to William",
      objectives = {},
      description = "Deliver this to my brother.",
      summary = "Take the Sealed Note to William Pestle in Goldshire." },
    { questID = 201, title = "Kobold Candles",
      objectives = { { text = "Kobold Candle: 3/8", type = "item" } },
      description = "Bring me candles.", summary = "Bring 8 Kobold Candles to William." },
    { questID = 202, title = "Totemic Trials",
      objectives = { { text = "Spirits appeased: 0/1", type = "event" }, { text = SECRET } },
      description = nil, summary = nil,
      special = 9 },
}
C_QuestLog = {
    GetNumQuestLogEntries = function() return #LOG, #LOG - 1 end,
    GetInfo = function(i)
        local q = LOG[i]
        if not q then return nil end
        return { isHeader = q.isHeader or false, title = q.title, questID = q.questID or 0 }
    end,
    GetQuestObjectives = function(questID)
        for _, q in ipairs(LOG) do
            if q.questID == questID then return q.objectives end
        end
    end,
    IsQuestFlaggedCompleted = function(questID) return COMPLETED[questID] == true end,
}
function GetQuestLogQuestText(i)
    local q = LOG[i]
    if not q then return nil end
    return q.description, q.summary
end
function GetQuestLogSpecialItemInfo(i)
    local q = LOG[i]
    if q and q.special then return link(q.special), 134400, 0, false end
end

-- Guild, character, clock ----------------------------------------------------------
local guild = { inGuild = true, name = "Dragonworld" }
function IsInGuild() return guild.inGuild end
-- Whether this character's guild rank may make guild events in the calendar.
function CanEditGuildEvent() return not guild.cannotMakeEvents end
function GetGuildInfo(unit)
    assert(unit == "player")
    if guild.inGuild and guild.name then return guild.name, "Member", guild.rankIndex or 3, nil end
end

-- The guild roster as the game reports it: name, rank, rank index, level, class
-- name, zone, public note, officer note, online, status, class token. `last`
-- is how long ago an offline member was on: years, months, days, hours.
-- `guid` is the player's fixed id (the 17th value the game returns). Cedric has
-- none, to cover a client that does not report it.
local ROSTER = {
    { "Tester-Stormrage", "Guild Master", 0, 60, "Paladin", "Ironforge", "Founder", "", true, 0, "PALADIN", guid = "Player-1-Tester" },
    { "Altine-Stormrage", "Officer", 1, 58, "Mage", "Stormwind", "", "", true, 0, "MAGE", guid = "Player-1-Altine" },
    { "Borin-Stormrage", "Member", 3, 42, "Warrior", "Westfall", "Alt of Tester", "", false, 0, "WARRIOR", last = { 0, 0, 3, 5 }, guid = "Player-1-Borin" },
    { "Cedric-Stormrage", "Member", 3, 20, "Rogue", "Elwynn Forest", "", "", false, 0, "ROGUE", last = { 0, 2, 4, 0 } },
    { "Dagny-Stormrage", "Initiate", 4, 60, "Priest", "Darnassus", "", "", false, 0, "PRIEST", last = { 1, 1, 0, 0 }, guid = "Player-1-Dagny" },
    { "Eira-Stormrage", "Member", 3, 35, "Hunter", "The Barrens", "", "", false, 0, "HUNTER", last = { 0, 0, 0, 6 }, guid = "Player-1-Eira" },
}
local rosterRequests = 0
function GetNumGuildMembers()
    local online = 0
    for _, member in ipairs(ROSTER) do
        if member[9] then online = online + 1 end
    end
    return #ROSTER, online
end
function GetGuildRosterInfo(index)
    local m = ROSTER[index]
    if m then return m[1], m[2], m[3], m[4], m[5], m[6], m[7], m[8], m[9], m[10], m[11], m.points or 0, 0, false, false, 0, m.guid end
end
function GetGuildRosterLastOnline(index)
    local member = ROSTER[index]
    if member and member.last then return table.unpack(member.last) end
end
C_GuildInfo = { GuildRoster = function() rosterRequests = rosterRequests + 1 end }
RAID_CLASS_COLORS = {
    PALADIN = { r = 0.96, g = 0.55, b = 0.73 }, MAGE = { r = 0.25, g = 0.78, b = 0.92 }, WARRIOR = { r = 0.78, g = 0.61, b = 0.43 },
    ROGUE = { r = 1.00, g = 0.96, b = 0.41 }, PRIEST = { r = 1.00, g = 1.00, b = 1.00 }, HUNTER = { r = 0.67, g = 0.83, b = 0.45 },
}

-- This character's own professions: GetProfessions gives slot numbers (some
-- missing), GetProfessionInfo gives name, icon, skill, max skill, ..., skill line.
local MY_PROFESSIONS = {
    [1] = { "Mining", 136248, 225, 300, 0, 0, 186 },
    [2] = { "Engineering", 136243, 210, 225, 0, 0, 202 },
    [5] = { "Cooking", 133971, 150, 225, 0, 0, 185 },
}
function GetProfessions() return 1, 2, nil, nil, 5 end
function GetProfessionInfo(index)
    local profession = MY_PROFESSIONS[index]
    if profession then return table.unpack(profession) end
end

local character = { name = "Tester", realm = "Stormrage", class = "PALADIN" }
function UnitFullName(unit) assert(unit == "player"); return character.name, character.realm end
function UnitName(unit) assert(unit == "player"); return character.name end
function UnitLevel(unit) assert(unit == "player"); return character.level or 60 end
-- The player's fixed id. Unless a test gives one, it is made from the name.
function UnitGUID(unit) assert(unit == "player"); return character.guid or ("Player-1-" .. (character.name:gsub("%s", ""))) end
function GetBuildInfo() return "1.60.1", "71037", "Nov 1 2026", 16001 end
function GetNormalizedRealmName() return character.realm end
function UnitClass(unit) assert(unit == "player"); return "Class", character.class, 2 end

-- A made-up clock that is easy to reason about: time({year=..}) and time() use
-- the same scale, so "22.11.2026 20:00" really is two days and an hour after NOW.
-- Counted from the year 2000: this Lua has 32-bit whole numbers, and counting
-- from year 0 does not fit in them.
local function fakeEpoch(t)
    return ((((t.year - 2000) * 12 + t.month) * 31 + t.day) * 24 + (t.hour or 0)) * 3600 + (t.min or 0) * 60
end
local NOW = fakeEpoch({ year = 2026, month = 11, day = 20, hour = 19, min = 0 })
function time(t)
    if t ~= nil then assert(type(t) == "table", "time() takes a table or nothing"); return fakeEpoch(t) end
    return NOW
end

-- Seconds since the client started, for throttling.
local clock = 1000.0
function GetTime() return clock end

-- The server's clock, which every player shares. Tests move it forward.
SERVER_NOW = NOW
function GetServerTime() return SERVER_NOW end

-- Addon messages and ordinary chat -----------------------------------------------------
local wire = {}                                          -- addon messages that went out
local guildChat = {}                                     -- ordinary chat lines that went out
local prefixes = {}
local sendResult = 0                                     -- what the game answers to SendAddonMessage (0 = ok)
local chatLock = false                                   -- the game's "no chat messaging right now" state
C_ChatInfo = {
    RegisterAddonMessagePrefix = function(prefix) assert(type(prefix) == "string" and #prefix <= 16, "prefix too long"); prefixes[prefix] = true; return 0 end,
    SendAddonMessage = function(prefix, message, chatType)
        assert(prefixes[prefix], "sending on a prefix that was never registered")
        assert(type(message) == "string" and #message <= 255 and not message:find("\0", 1, true), "bad addon message")
        assert(not chatLock, "sent an addon message while the game had chat locked")
        if sendResult == 0 then wire[#wire + 1] = { prefix = prefix, message = message, chatType = chatType } end
        return sendResult
    end,
    InChatMessagingLockdown = function() return chatLock end,
    SendChatMessage = function(text, chatType, language, target)
        assert(type(text) == "string" and #text <= 255 and not text:find("|", 1, true), "bad chat message")
        assert(not chatLock, "sent a chat message while the game had chat locked")
        assert(chatType ~= "WHISPER" or (type(target) == "string" and target ~= ""), "a whisper needs someone to go to")
        guildChat[#guildChat + 1] = { text = text, chatType = chatType, target = target }
    end,
}
math.random = function() return 0.5 end                  -- no surprises in the tests

-- The game's own calendar ----------------------------------------------------------
-- Months are counted from the month selected in the calendar, which is
-- November 2004 until the calendar has been opened in the session.
local calendar = { selected = { month = 11, year = 2004 }, opened = 0, events = {} }
local function calendarMonth(offset)
    local index = calendar.selected.year * 12 + (calendar.selected.month - 1) + offset
    return math.floor(index / 12), index % 12 + 1
end
local function calendarDay(offset, day)
    local year, month = calendarMonth(offset)
    return calendar.events[year .. "-" .. month .. "-" .. day]
end
C_DateAndTime = { GetCurrentCalendarTime = function() return { year = 2026, month = 11, monthDay = 20, weekday = 6, hour = 19, minute = 0 } end }
C_Calendar = {
    OpenCalendar = function() calendar.opened = calendar.opened + 1 end,
    SetAbsMonth = function(month, year) assert(type(month) == "number" and type(year) == "number"); calendar.selected = { month = month, year = year } end,
    GetMonthInfo = function(offset)
        local year, month = calendarMonth(offset or 0)
        return { month = month, year = year, numDays = (month == 12) and 31 or 30, firstWeekday = 1 }
    end,
    GetNumDayEvents = function(offset, day) local list = calendarDay(offset, day); return list and #list or 0 end,
    GetDayEvent = function(offset, day, index) local list = calendarDay(offset, day); return list and list[index] end,
}

-- Creating an event in the game's calendar: start a candidate, set its fields,
-- then AddEvent. The game only accepts AddEvent during a hardware event (a
-- click). Timers are not clicks, so inHardwareEvent is false while they run.
local inHardwareEvent = true
local candidate
calendar.created = {}
function C_Calendar.CreatePlayerEvent() candidate = { kind = "PLAYER" } end
function C_Calendar.CreateGuildSignUpEvent() candidate = { kind = "GUILD" } end
function C_Calendar.EventSetTitle(title) assert(candidate, "no calendar event is being created"); assert(type(title) == "string" and title ~= ""); candidate.title = title end
function C_Calendar.EventSetDescription(text) assert(candidate and type(text) == "string"); candidate.description = text end
function C_Calendar.EventSetType(kind) assert(candidate and type(kind) == "number" and kind >= 0 and kind <= 5); candidate.type = kind end
function C_Calendar.EventSetDate(month, day, year)
    assert(candidate, "no calendar event is being created")
    assert(month >= 1 and month <= 12 and day >= 1 and day <= 31 and year >= 2026, "EventSetDate takes month, day, year")
    candidate.month, candidate.day, candidate.year = month, day, year
end
function C_Calendar.EventSetTime(hour, minute)
    assert(candidate and hour >= 0 and hour <= 23 and minute >= 0 and minute <= 59, "EventSetTime takes hour, minute")
    candidate.hour, candidate.minute = hour, minute
end
function C_Calendar.CanAddEvent() return true end
function C_Calendar.AddEvent()
    assert(candidate and candidate.title and candidate.month and candidate.hour, "AddEvent needs a title, a date and a time first")
    assert(inHardwareEvent, "AddEvent called outside a click; the game would refuse it")
    calendar.created[#calendar.created + 1] = candidate
    candidate = nil
end
-- date(format, t) shows as "DATE(t)" so tests can see which moment was formatted.
-- date("%d.%m.%Y") with no time is today's date: 20 November 2026, a Friday.
function date(format, t)
    assert(type(format) == "string")
    if format == "*t" then
        -- The parts of a moment, undoing fakeEpoch above.
        local minutes = (t or NOW) // 60
        local hours = minutes // 60
        local days = hours // 24
        local months = days // 31
        local day = days % 31
        if day == 0 then day, months = 31, months - 1 end
        local year, month = months // 12, months % 12
        if month == 0 then month, year = 12, year - 1 end
        return { year = year + 2000, month = month, day = day, hour = hours % 24, min = minutes % 60 }
    end
    if t == nil then
        assert(format == "%d.%m.%Y", "date() without a time is only modelled for today's date")
        return "20.11.2026"
    end
    return "DATE(" .. tostring(t) .. ")"
end

-- Key bindings ---------------------------------------------------------------------
-- Each entry: { command, category, key, key, ... }
local BINDINGS = {
    { "MOVEFORWARD", "MOVEMENT", "W", "UP" },
    { "JUMP", "MOVEMENT", "SPACE" },
    { "ACTIONBUTTON1", "ACTIONBAR", "1" },
    { "ACTIONBUTTON2", "ACTIONBAR", "2" },
    { "TOGGLEBAGS", "INTERFACE" },
}
local inCombat = false
local bindingsSaved = {}                                 -- each SaveBindings(which) call
function InCombatLockdown() return inCombat end

-- Macros and action bar slots (ActionButton.lua). Globals, since the main chunk is out of locals.
MACROS = {}                                              -- account macros: { name, icon, body, perCharacter }
ACTION_SLOTS = {}                                        -- [slot] = { kind, id }, as GetActionInfo gives them
MAX_ACCOUNT_MACROS = 120
function GetMacroIndexByName(name)
    for index, macro in ipairs(MACROS) do if macro.name == name then return index end end
    return 0
end
function GetNumMacros() return #MACROS, 0 end
function CreateMacro(name, icon, body, perCharacter)
    assert(not inCombat, "CreateMacro during combat")
    assert(type(name) == "string" and #name <= 16 and (type(icon) == "number" or type(icon) == "string") and type(body) == "string", "CreateMacro arguments")
    MACROS[#MACROS + 1] = { name = name, icon = icon, body = body, perCharacter = perCharacter }
    return #MACROS
end
function PickupMacro(index) assert(MACROS[index], "PickupMacro: no such macro"); CURSOR_MACRO = index end
function GetFileIDFromPath(path) if path == "Interface\\Icons\\INV_Misc_Head_Dragon_01" then return 134153 end end
function GetActionInfo(slot) local a = ACTION_SLOTS[slot]; if a then return a[1], a[2] end end
function ReloadUI() RELOADS = (RELOADS or 0) + 1 end

-- The guild's message of the day, and its event log ({ type, player1, player2, rank, years, months, days, hours }).
GUILD_MOTD_TEXT = "Raid fredag kl 20!"
function GetGuildRosterMOTD() return GUILD_MOTD_TEXT end
GUILD_LOG, GUILD_LOG_QUERIES = {}, 0
function QueryGuildEventLog() GUILD_LOG_QUERIES = GUILD_LOG_QUERIES + 1 end
function GetNumGuildEvents() return #GUILD_LOG end
function GetGuildEventInfo(index) local e = GUILD_LOG[index]; if e then return table.unpack(e, 1, 8) end end
ChatTypeInfo = { GUILD = { r = 0.25, g = 1.0, b = 0.25 } }
C_Texture = { GetAtlasInfo = function(name) if ATLASES[name] then return { width = 64, height = 64 } end end }
function GetActionText(slot)
    local a = ACTION_SLOTS[slot]
    if a and a[1] == "macro" and MACROS[a[2]] then return MACROS[a[2]].name end
end
function GetNumBindings() return #BINDINGS end
function GetBinding(index) return table.unpack(BINDINGS[index]) end
function GetCurrentBindingSet() return 2 end
function SaveBindings(which) assert(which == 1 or which == 2, "SaveBindings(which)"); bindingsSaved[#bindingsSaved + 1] = which end
function SetBinding(key, command)
    assert(type(key) == "string", "SetBinding needs a key")
    assert(not inCombat, "SetBinding called in combat (the game blocks this)")
    for _, binding in ipairs(BINDINGS) do                 -- a key can only be on one command
        for i = #binding, 3, -1 do
            if binding[i] == key then table.remove(binding, i) end
        end
    end
    if command == nil then return 1 end
    for _, binding in ipairs(BINDINGS) do
        if binding[1] == command then binding[#binding + 1] = key; return 1 end
    end
    return nil                                            -- unknown command
end
local function keysOf(command)
    for _, binding in ipairs(BINDINGS) do
        if binding[1] == command then return table.concat(binding, ",", 3) end
    end
end

-- Spec (the two talent groups) --------------------------------------------------------
local activeSpec = 1
C_SpecializationInfo = { GetActiveSpecGroup = function() return activeSpec end }
function GetNumSpecGroups() return 2 end

-- Context menu ---------------------------------------------------------------------
local lastMenu
MenuUtil = {
    CreateContextMenu = function(owner, generator)
        assert(type(owner) == "table" and type(generator) == "function")
        local menu = { owner = owner, titles = {}, radios = {}, buttons = {} }
        local root = {}
        function root:CreateTitle(text) assert(type(text) == "string"); menu.titles[#menu.titles + 1] = text end
        function root:CreateButton(text, callback)
            assert(type(text) == "string" and type(callback) == "function")
            local entry = { text = text, enabled = true, click = callback }
            function entry:SetEnabled(enabled) self.enabled = enabled and true or false end
            menu.buttons[#menu.buttons + 1] = entry
            return entry
        end
        function root:CreateRadio(text, isSelected, setSelected, data)
            assert(type(text) == "string" and type(isSelected) == "function" and type(setSelected) == "function")
            menu.radios[#menu.radios + 1] = { text = text, selected = function() return isSelected(data) end, click = function() setSelected(data) end }
        end
        generator(owner, root)
        lastMenu = menu
    end,
}

-- Clicking a link in chat: the game calls SetItemRef(link, text, button, frame).
-- A profession link then opens that player's profession window.
local itemRefs = {}
local function realSetItemRef(link, text, button, frame)
    assert(type(link) == "string" and type(text) == "string" and button == "LeftButton", "SetItemRef(link, text, button)")
    assert(text:find("|H" .. link .. "|h", 1, true), "the text must contain the link it is for")
    itemRefs[#itemRefs + 1] = { link = link, text = text }
end
SetItemRef = realSetItemRef

-- Widgets ------------------------------------------------------------------------
local frames = {}
local TEMPLATES = { BackdropTemplate = true, UIPanelCloseButton = true, UICheckButtonTemplate = true, ScrollFrameTemplate = true, InputBoxTemplate = true }
local FRAME_TYPES = { Frame = true, Button = true, CheckButton = true, ScrollFrame = true, GameTooltip = true, EditBox = true, ScrollingMessageFrame = true }
local FONTS = { GameFontNormal = true, GameFontNormalSmall = true, GameFontNormalLarge = true, GameFontNormalHuge = true,
                GameFontHighlight = true, GameFontHighlightSmall = true, GameFontDisable = true, GameFontDisableSmall = true }

local Region = {}
Region.__index = Region
function Region:SetSize(w, h) assert(type(w) == "number" and type(h) == "number"); self.width, self.height = w, h end
function Region:SetWidth(w) assert(type(w) == "number"); self.width = w end
function Region:SetHeight(h) assert(type(h) == "number"); self.height = h end
function Region:GetWidth() return self.width or 0 end
function Region:GetHeight() return self.height or 0 end
function Region:SetPoint(point, a, b, c, d)
    assert(type(point) == "string", "SetPoint needs a point name")
    local relTo, relPoint, x, y
    if a == nil or type(a) == "number" then
        relPoint, x, y = point, a or 0, b or 0
    else
        assert(type(a) == "table", "SetPoint relativeTo must be a region")
        relTo, relPoint, x, y = a, b or point, c or 0, d or 0
    end
    self.points = self.points or {}
    self.points[#self.points + 1] = { point, relTo, relPoint, x, y }
end
function Region:SetAllPoints(relTo) assert(relTo == nil or type(relTo) == "table"); self.allPoints = relTo or true end
function Region:GetPoint(i)
    local p = self.points and self.points[i or 1]
    if p then return p[1], p[2], p[3], p[4], p[5] end
end
function Region:ClearAllPoints() self.points = nil end
function Region:Fire(script, ...)
    local fn = self.scripts and self.scripts[script]
    if fn then fn(self, ...) end
    for _, hook in ipairs(self.hooks and self.hooks[script] or {}) do hook(self, ...) end
end
-- Like the game: OnShow/OnHide fire when a frame actually becomes visible or
-- hidden, including when that happens because a parent was shown or hidden.
function Region:IsShown() return self.shown end
function Region:IsVisible() return self.shown and (self.parent == nil or self.parent:IsVisible()) end
function Region:VisibilityChanged(visible)
    if visible then self:Fire("OnShow") end
    for _, child in ipairs(self.children or {}) do
        if child.shown then child:VisibilityChanged(visible) end
    end
    if not visible then self:Fire("OnHide") end
end
function Region:Show()
    if not self.shown then
        self.shown = true
        if self:IsVisible() then self:VisibilityChanged(true) end
    end
end
function Region:Hide()
    if self.shown then
        local wasVisible = self:IsVisible()
        self.shown = false
        if wasVisible then self:VisibilityChanged(false) end
    end
end
function Region:SetShown(shown) if shown then self:Show() else self:Hide() end end
function Region:GetCenter() local c = self.center or { 0, 0 }; return c[1], c[2] end
function Region:GetParent() return self.parent end
function Region:GetName() return self.name end

local FontString = setmetatable({}, { __index = Region })
FontString.__index = FontString
function FontString:SetText(text) assert(type(text) == "string", "SetText needs a string"); self.text = text end
function FontString:GetText() return self.text end
function FontString:SetTextColor(r, g, b) assert(r and g and b); self.color = { r, g, b } end
function FontString:SetJustifyH(j) assert(j == "LEFT" or j == "RIGHT" or j == "CENTER"); self.justifyH = j end
function FontString:SetWordWrap(wrap) end
-- How wide the text is drawn. Here every character is 6 wide.
function FontString:GetStringWidth() return #(self.text or "") * 6 end
function FontString:SetFont(path, size, flags)
    assert(type(path) == "string" and type(size) == "number" and type(flags) == "string", "SetFont(path, size, flags)")
    self.font = { path, size }
    return true
end

local Texture = setmetatable({}, { __index = Region })
Texture.__index = Texture
function Texture:SetTexture(t) assert(t ~= nil, "SetTexture(nil)"); self.texture = t end
function Texture:SetColorTexture(r, g, b, a) assert(r and g and b); self.texture = "color" end
function Texture:SetTexCoord(...) assert(select("#", ...) == 4) end
local BLEND_MODES = { DISABLE = true, BLEND = true, ALPHAKEY = true, ADD = true, MOD = true }
function Texture:SetBlendMode(mode) assert(BLEND_MODES[mode], "SetBlendMode: unknown mode " .. tostring(mode)); self.blend = mode end
function Texture:SetVertexColor(r, g, b, a) assert(type(r) == "number" and type(g) == "number" and type(b) == "number", "SetVertexColor"); self.vertexColor = { r, g, b } end
function Texture:SetAlpha(alpha) assert(type(alpha) == "number" and alpha >= 0 and alpha <= 1, "SetAlpha out of range"); self.alpha = alpha end
function Texture:GetDrawLayer() return self.layer or "ARTWORK", self.sublevel or 0 end
function Texture:AddMaskTexture(mask) assert(mask ~= nil, "AddMaskTexture(nil)"); self.mask = mask end
function Texture:SetDesaturated(on) self.desaturated = on and true or false end
ATLASES = { ["gamepad-hud-actionbar-casting-complete-glow"] = true, ["gamepad-actionbar-circleslot-border-hover"] = true }
function Texture:SetAtlas(name) assert(type(name) == "string" and ATLASES[name], "unknown atlas " .. tostring(name)); self.atlas = name; self.texture = nil; return true end

local Frame = setmetatable({}, { __index = Region })
Frame.__index = Frame
function Frame:SetScript(name, fn) assert(fn == nil or type(fn) == "function", "SetScript needs a function"); self.scripts[name] = fn end
function Frame:HookScript(name, fn)
    assert(type(fn) == "function")
    self.hooks[name] = self.hooks[name] or {}
    table.insert(self.hooks[name], fn)
end
function Frame:RegisterEvent(event) self.events[event] = true end
function Frame:UnregisterEvent(event) self.events[event] = nil end
function Frame:SetFrameStrata(strata) self.strata = strata end
function Frame:SetFrameLevel(level) assert(type(level) == "number"); self.level = level end
function Frame:GetFrameLevel() return self.level or 1 end
function Frame:GetEffectiveScale() return self.scale or 1 end
function Frame:SetBackdrop(t) assert(self.template == "BackdropTemplate", "SetBackdrop needs BackdropTemplate"); self.backdrop = t end
function Frame:SetBackdropColor(r, g, b, a) assert(self.backdrop, "SetBackdropColor before SetBackdrop"); assert(r and g and b); self.backdropColor = { r, g, b, a } end
function Frame:SetBackdropBorderColor(r, g, b, a) assert(self.backdrop, "SetBackdropBorderColor before SetBackdrop"); assert(r and g and b); self.borderColor = { r, g, b, a } end
function Frame:SetMovable(m) self.movable = m end
function Frame:SetClampedToScreen(c) end
function Frame:EnableMouse(e) self.mouse = e end
function Frame:RegisterForDrag(button) end
function Frame:RegisterForClicks(...) assert(self.kind == "Button" or self.kind == "CheckButton", "RegisterForClicks on non-button"); assert(select("#", ...) > 0) end
function Frame:SetHighlightTexture(t) assert(self.kind == "Button" or self.kind == "CheckButton", "SetHighlightTexture on non-button"); assert(t ~= nil) end
function Frame:SetEnabled(enabled) assert(self.kind == "Button" or self.kind == "CheckButton", "SetEnabled on non-button"); self.enabled = enabled and true or false end
function Frame:IsEnabled() assert(self.kind == "Button" or self.kind == "CheckButton", "IsEnabled on non-button"); return self.enabled ~= false end
function Frame:StartMoving() assert(self.movable, "StartMoving on a frame that is not movable"); self.moving = true end
function Frame:StopMovingOrSizing() self.moving = false end
function Frame:CreateFontString(name, layer, template)
    assert(template == nil or FONTS[template], "unknown font " .. tostring(template))
    local fs = setmetatable({ parent = self, shown = true, fontTemplate = template }, FontString)
    self.fontStrings[#self.fontStrings + 1] = fs
    return fs
end
-- The game allows sublevels -8 to 7 within a draw layer.
function Frame:CreateTexture(name, layer, template, sublevel)
    assert(sublevel == nil or (type(sublevel) == "number" and sublevel >= -8 and sublevel <= 7), "texture sublevel out of range")
    local texture = setmetatable({ parent = self, shown = true, layer = layer, sublevel = sublevel }, Texture)
    self.textures = self.textures or {}
    self.textures[#self.textures + 1] = texture
    return texture
end
function Frame:SetScrollChild(child) assert(self.kind == "ScrollFrame", "SetScrollChild on non-ScrollFrame"); self.scrollChild = child end
-- Edit boxes (the text fields in the new-event form).
-- The game's limits, including its quirk: SetMaxBytes(n) only lets n - 1 bytes
-- in, while SetMaxLetters(n) lets exactly n characters in. Text that is too
-- long is cut, whether it was typed or set by code.
local function limitText(box, text)
    if box.maxBytes and box.maxBytes > 0 and #text > box.maxBytes - 1 then text = text:sub(1, box.maxBytes - 1) end
    if box.maxLetters and box.maxLetters > 0 and #text > box.maxLetters then text = text:sub(1, box.maxLetters) end
    return text
end
-- Like the game, OnTextChanged runs for text set by code (userInput = false) as well as for typing.
function Frame:SetText(text)
    assert(self.kind == "EditBox", "SetText on a frame that is not an EditBox")
    assert(type(text) == "string")
    self.text = limitText(self, text)
    self:Fire("OnTextChanged", false)
end
-- Test helper, not a game method: the player types this text into the box.
function Frame:TypeText(text)
    assert(self.kind == "EditBox" and self:IsVisible(), "typing into something that is not a visible text field")
    self.text = limitText(self, text)
    self:Fire("OnTextChanged", true)
end
function Frame:SetMaxLetters(letters) assert(self.kind == "EditBox" and type(letters) == "number", "SetMaxLetters"); self.maxLetters = letters end
function Frame:SetNormalTexture(t) assert(self.kind == "Button" or self.kind == "CheckButton", "SetNormalTexture on non-button"); assert(t ~= nil); self.normalTexture = t end
function Frame:GetText() assert(self.kind == "EditBox", "GetText on a frame that is not an EditBox"); return self.text or "" end
function Frame:SetAutoFocus(auto) assert(self.kind == "EditBox", "SetAutoFocus on non-EditBox") end
function Frame:SetMaxBytes(bytes) assert(self.kind == "EditBox" and type(bytes) == "number", "SetMaxBytes"); self.maxBytes = bytes end
function Frame:ClearFocus() assert(self.kind == "EditBox", "ClearFocus on non-EditBox") end
function Frame:SetPushedTexture(t) assert(self.kind == "Button" or self.kind == "CheckButton", "SetPushedTexture on non-button"); assert(t ~= nil); self.pushedTexture = t end
function Frame:SetDisabledTexture(t) assert(self.kind == "Button" or self.kind == "CheckButton", "SetDisabledTexture on non-button"); assert(t ~= nil); self.disabledTexture = t end
-- A text field over several lines needs a font of its own when it has no template.
function Frame:SetMultiLine(multi) assert(self.kind == "EditBox", "SetMultiLine on non-EditBox"); self.multiLine = multi and true or false end
function Frame:SetFontObject(font) assert(self.kind == "EditBox" or self.kind == "Button" or self.kind == "ScrollingMessageFrame", "SetFontObject"); assert(font ~= nil); self.fontObject = font end
-- A ScrollingMessageFrame (lines like the chat window). Lines are kept in .messages.
local function isSMF(self, method) assert(self.kind == "ScrollingMessageFrame", method .. " on a frame that is not a ScrollingMessageFrame") end
function Frame:SetFading(on) isSMF(self, "SetFading"); self.fading = on end
function Frame:SetMaxLines(n) isSMF(self, "SetMaxLines"); assert(type(n) == "number" and n > 0); self.maxLines = n end
function Frame:SetHyperlinksEnabled(on) isSMF(self, "SetHyperlinksEnabled"); self.hyperlinks = on end
function Frame:SetJustifyH(j) isSMF(self, "SetJustifyH"); assert(j == "LEFT" or j == "RIGHT" or j == "CENTER"); self.justifyH = j end
function Frame:AddMessage(text, r, g, b)
    isSMF(self, "AddMessage"); assert(type(text) == "string", "AddMessage needs a string")
    self.messages = self.messages or {}
    self.messages[#self.messages + 1] = { text = text, r = r, g = g, b = b }
    if self.maxLines and #self.messages > self.maxLines then table.remove(self.messages, 1) end
    self.atBottom = false
end
function Frame:Clear() isSMF(self, "Clear"); self.messages = {} end
function Frame:GetNumMessages() isSMF(self, "GetNumMessages"); return #(self.messages or {}) end
function Frame:ScrollUp() isSMF(self, "ScrollUp"); self.atBottom = false end
function Frame:ScrollDown() isSMF(self, "ScrollDown") end
function Frame:ScrollToBottom() isSMF(self, "ScrollToBottom"); self.atBottom = true end
function Frame:EnableMouseWheel(on) self.mouseWheel = on and true or false end
function Frame:SetTextInsets(l, r, t, b) assert(self.kind == "EditBox", "SetTextInsets on non-EditBox"); assert(l and r and t and b) end
function Frame:SetFocus() assert(self.kind == "EditBox", "SetFocus on non-EditBox"); self.focused = true end
function Frame:HighlightText() assert(self.kind == "EditBox", "HighlightText on non-EditBox"); self.highlighted = true end
function Frame:SetPassword(on) assert(self.kind == "EditBox", "SetPassword on non-EditBox"); self.password = on and true or false end
function Frame:SetChecked(v) assert(self.kind == "CheckButton", "SetChecked on non-CheckButton"); self.checked = v and true or false end
function Frame:GetChecked() assert(self.kind == "CheckButton", "GetChecked on non-CheckButton"); return self.checked end

function CreateFrame(kind, name, parent, template)
    assert(FRAME_TYPES[kind], "unexpected frame type " .. tostring(kind))
    assert(template == nil or TEMPLATES[template], "unexpected template " .. tostring(template))
    assert(parent == nil or type(parent) == "table", "parent must be a frame")
    local f = setmetatable({
        kind = kind, name = name, parent = parent, template = template,
        shown = true, scripts = {}, hooks = {}, events = {}, children = {}, fontStrings = {},
    }, Frame)
    if name then
        assert(_G[name] == nil, "duplicate global frame name " .. name)
        _G[name] = f
    end
    if parent then table.insert(parent.children, f) end
    frames[#frames + 1] = f
    return f
end

UIParent = CreateFrame("Frame", "UIParent")
UISpecialFrames = {}

Minimap = CreateFrame("Frame", "Minimap", UIParent)
Minimap:SetSize(140, 140)
Minimap.center = { 500, 500 }
local cursor = { 0, 0 }
function GetCursorPosition() return cursor[1], cursor[2] end
math.atan2 = math.atan2 or math.atan      -- WoW is Lua 5.1 (has atan2); this VM is 5.3

local function fire(event, ...)
    for _, f in ipairs(frames) do
        if f.events[event] and f.scripts.OnEvent then f.scripts.OnEvent(f, event, ...) end
    end
end

local timers = {}
C_Timer = { After = function(delay, fn) assert(type(delay) == "number" and type(fn) == "function"); timers[#timers + 1] = { delay = delay, fn = fn } end }
-- Runs every waiting timer, without letting any time pass.
local function flushNow()
    local due = timers
    timers = {}
    inHardwareEvent = false               -- a timer firing is not the player clicking
    for _, timer in ipairs(due) do timer.fn() end
    inHardwareEvent = true
end
-- Lets a minute pass, then runs every waiting timer. A minute is enough for
-- the send queue (about one message a second) to have room again.
local function flush()
    clock = clock + 60
    flushNow()
end
-- How many timers of a given delay are waiting. Ryddesekk batches its panel
-- refresh with 0.1 s, Materialer batches its bag reading with 0.3 s.
local function queued(delay)
    local count = 0
    for _, timer in ipairs(timers) do
        if timer.delay == delay then count = count + 1 end
    end
    return count
end

-- Tooltips ---------------------------------------------------------------------
Enum = { ItemClass = { Questitem = 12 }, TooltipDataType = { Item = 0 }, PlayerInteractionType = { Banker = 8, GuildBanker = 10 } }

-- Like the game, every module that asks gets called, in the order they asked.
TOOLTIP_CALLBACKS = {}
TooltipDataProcessor = {
    AddTooltipPostCall = function(dataType, fn)
        assert(dataType == Enum.TooltipDataType.Item, "wrong tooltip data type")
        assert(type(fn) == "function")
        TOOLTIP_CALLBACKS[#TOOLTIP_CALLBACKS + 1] = fn
    end,
}
local function tooltipCallback(tooltip, data)
    for _, fn in ipairs(TOOLTIP_CALLBACKS) do fn(tooltip, data) end
end

local function newTooltip(name)
    local t = CreateFrame("GameTooltip", name)
    t.lines = {}
    t.colors = {}
    t.shown = false
    function t:AddLine(text, r, g, b, wrap)
        assert(type(text) == "string")
        self.lines[#self.lines + 1] = text
        self.colors[#self.lines] = r and { r, g, b } or nil
    end
    function t:Reset() self.lines = {}; self.colors = {}; self:Fire("OnTooltipCleared") end
    function t:SetOwner(owner, anchor) assert(type(owner) == "table" and type(anchor) == "string"); self.owner = owner; self:Reset() end
    function t:IsOwned(frame) return self.owner == frame end
    -- An action bar slot: the game writes what is there (a macro's name).
    function t:SetAction(slot)
        assert(type(slot) == "number")
        self:Reset()
        self.lines[1] = GetActionText(slot) or "?"
        self:Show()
        return true
    end
    function t:SetBagItem(bag, slot)
        assert(type(bag) == "number" and type(slot) == "number")
        self.bagItem = { bag, slot }
        self:Reset()
        local id = C_Container.GetContainerItemID(bag, slot)
        if id then tooltipCallback(self, { id = id }) end
    end
    function t:SetItemByID(id)
        assert(type(id) == "number")
        self:Reset()
        self.lines[1] = ITEMS[id] and ITEMS[id].name or "?"
        tooltipCallback(self, { id = id })
    end
    return t
end
-- Like the game: the hook runs after the original, with the same arguments.
function hooksecurefunc(tbl, name, hook)
    if type(tbl) == "string" then tbl, name, hook = _G, tbl, name end
    local original = tbl[name]
    assert(type(original) == "function" and type(hook) == "function", "hooksecurefunc: nothing to hook")
    tbl[name] = function(...)
        local results = table.pack(original(...))
        hook(...)
        return table.unpack(results, 1, results.n)
    end
end
GameTooltip = newTooltip("GameTooltip")
ItemRefTooltip = newTooltip("ItemRefTooltip")
local OtherTooltip = newTooltip("OtherTooltip")

SlashCmdList = {}

-- Load the addon -----------------------------------------------------------------
-- Saved data as left by the previous version: marks and positions, but no
-- language yet. This is what an existing user has when they update.
DragonworldDB = {
    modules = {
        ryddesekk = {
            marks = { [7] = "kast" },
            window = { point = "TOPLEFT", relativePoint = "TOPLEFT", x = 5, y = -5 },   -- old, now unused
        },
    },
    minimap = { angle = 90 },
    window = { point = "TOPLEFT", relativePoint = "TOPLEFT", x = 100, y = -200 },
}

local ns = {}
for _, file in ipairs(ADDON_FILES) do
    local chunk, err = load(file.source, "@" .. file.name)
    if not chunk then error("SYNTAX ERROR: " .. tostring(err)) end
    chunk(ADDON_FOLDER, ns)
end
io.write("loaded: ", ADDON_FOLDER, " (", #ADDON_FILES, " files)\n")

local function kast(message) return SlashCmdList.DRAGONWORLD_RYDDESEKK(message) end
local function dw(message) return SlashCmdList.DRAGONWORLD(message) end
local function saved() return DragonworldDB.modules.ryddesekk end
local function colour(c, r, g, b) return c and c[1] == r and c[2] == g and c[3] == b end
local function isGold(c) return colour(c, 1.00, 0.82, 0.00) end

local function hover(id, tooltip)
    tooltip = tooltip or GameTooltip
    tooltip:Reset()
    tooltipCallback(tooltip, { id = id })
    return tooltip.lines
end
local function verdict(id, tooltip)
    local lines = hover(id, tooltip)
    return lines[2], lines[3], #lines
end

check("tooltip callbacks registered: Ryddesekk's verdict, Materialer's crafting line and Professions' shopping line", #TOOLTIP_CALLBACKS == 3, #TOOLTIP_CALLBACKS)
check("slash /dw registered", SLASH_DRAGONWORLD1 == "/dw" and SLASH_DRAGONWORLD2 == "/dragonworld" and type(SlashCmdList.DRAGONWORLD) == "function")
check("Ryddesekk shortcut registered in all three languages",
    SLASH_DRAGONWORLD_RYDDESEKK1 == "/kast" and SLASH_DRAGONWORLD_RYDDESEKK2 == "/tidybag" and SLASH_DRAGONWORLD_RYDDESEKK3 == "/opruimtas"
    and type(SlashCmdList.DRAGONWORLD_RYDDESEKK) == "function")
check("no windows or buttons are built at load", DragonworldFrame == nil and DragonworldRyddesekkScroll == nil and DragonworldMinimapButton == nil)

-- ================================ languages =====================================
do
    local missing, mismatched = {}, {}
    for key, english in pairs(ns.strings.en) do
        for _, code in ipairs({ "nb", "nl" }) do
            local text = ns.strings[code][key]
            if type(text) ~= "string" or text == "" then
                missing[#missing + 1] = code .. "." .. key
            else
                local _, a = english:gsub("%%[sd]", "")
                local _, b = text:gsub("%%[sd]", "")
                if a ~= b then mismatched[#mismatched + 1] = code .. "." .. key end
            end
        end
    end
    for _, code in ipairs({ "nb", "nl" }) do
        for key in pairs(ns.strings[code]) do
            if ns.strings.en[key] == nil then missing[#missing + 1] = "en." .. key end
        end
    end
    local count = 0
    for _ in pairs(ns.strings.en) do count = count + 1 end
    check("every one of the " .. count .. " texts exists in English, Norwegian and Dutch", #missing == 0, table.concat(missing, ", "))
    check("the %s placeholders match in all three languages", #mismatched == 0, table.concat(mismatched, ", "))
end
check("languages offered: English, Norsk, Nederlands",
    #ns.LANGUAGES == 3 and ns.LANGUAGES[1].name == "English" and ns.LANGUAGES[2].name == "Norsk" and ns.LANGUAGES[3].name == "Nederlands")
check("a text name that does not exist shows as its own name", ns.L.FINNES_IKKE == "FINNES_IKKE")
check("unknown language code is refused", ns.SetLanguage("xx") == false and ns.GetLanguage() == "en")

-- ================================ core ==========================================
check("ryddesekk registered itself as a module", ns.modules.ryddesekk ~= nil and ns.moduleOrder[1] == ns.modules.ryddesekk)
check("duplicate module id is refused", not pcall(ns.RegisterModule, { id = "ryddesekk", title = "X" }))
check("module id with spaces/capitals is refused", not pcall(ns.RegisterModule, { id = "Min Modul", title = "X" }))
check("module without a name is refused", not pcall(ns.RegisterModule, { id = "utennavn" }))

-- Extra modules: one whose OnLoad blows up, one with a panel, one whose panel blows up.
local laterLoadedWith, etterPanel
local etterPanelsBuilt = 0
ns.RegisterModule({ id = "boom", title = "Boom", notes = "kaster feil", OnLoad = function() error("kaboom") end })
ns.RegisterModule({ id = "etter", title = "Etter", notes = "lastes etter Boom",
    OnLoad = function(self, db) laterLoadedWith = db end,
    CreatePanel = function(self, parent)
        etterPanelsBuilt = etterPanelsBuilt + 1
        etterPanel = CreateFrame("Frame", nil, parent)
        etterPanel:SetAllPoints(parent)
        etterPanel.timesShown = 0
        etterPanel:SetScript("OnShow", function(f) f.timesShown = f.timesShown + 1 end)
        return etterPanel
    end })
ns.RegisterModule({ id = "kaputt", title = "Kaputt", CreatePanel = function() error("panel kaboom") end })

fire("ADDON_LOADED", "SomeOtherAddon")
check("saved mark not applied before our ADDON_LOADED", verdict(7) == nil)
fire("ADDON_LOADED", "Dragonworld")
check("a failing module is reported by name (English until a language is chosen)", has("Error in Boom:") and has("kaboom"), chatText())
check("modules after the failing one still load, with their own storage",
    laterLoadedWith ~= nil and laterLoadedWith == DragonworldDB.modules.etter and ns.modules.etter.db == laterLoadedWith)
check("minimap button is still created after a module failed", DragonworldMinimapButton ~= nil)
clearChat()
fire("PLAYER_LOGIN")
fire("PLAYER_ENTERING_WORLD")

local mm = DragonworldMinimapButton

-- ====================== first run: no language chosen yet ========================
check("no language chosen yet: English is used", ns.GetLanguage() == "en" and not ns.HasChosenLanguage())
local label, reason, n = verdict(5)
check("tooltips are English until a language is chosen", label == "Probably safe to discard" and reason == "None of your quests mention this." and n == 3, tostring(label))
do
    -- Every verdict a player can be told to act on must say what the action is.
    local bare = {}
    for code, words in pairs({ en = "discard", nb = "kast", nl = "weg" }) do
        for _, key in ipairs({ "RS_STATUS_TRASH", "RS_STATUS_MAYBE", "RS_STATUS_UNSURE" }) do
            if not ns.strings[code][key]:lower():find(words, 1, true) then bare[#bare + 1] = code .. "." .. key end
        end
    end
    check("every verdict except Keep mentions discarding, in every language", #bare == 0, table.concat(bare, ", "))
    local repeated = {}
    for _, language in ipairs(ns.LANGUAGES) do
        local t = ns.strings[language.code]
        if t.RS_REASON_UNSURE:lower():find(t.RS_STATUS_UNSURE:lower(), 1, true) then repeated[#repeated + 1] = language.code end
    end
    check("the 'check first' verdict is not repeated inside its own explanation", #repeated == 0, table.concat(repeated, ", "))
end
mm.scripts.OnEnter(mm)
check("minimap tooltip is English until a language is chosen",
    GameTooltip.lines[1] == "Dragonworld" and GameTooltip.lines[2] == "Click to open Dragonworld." and GameTooltip.lines[3] == "Drag to move the button.",
    table.concat(GameTooltip.lines, " / "))
mm.scripts.OnLeave(mm)

mm.scripts.OnClick(mm, "LeftButton")
local win = DragonworldFrame
check("clicking the minimap button opens the main window", win ~= nil and win:IsShown())
do
    local point, relTo, relPoint, x, y = win:GetPoint(1)
    check("main window restored its saved position", point == "TOPLEFT" and relTo == UIParent and relPoint == "TOPLEFT" and x == 100 and y == -200,
        table.concat({ tostring(point), tostring(x), tostring(y) }, ","))
end
check("Escape closes it (registered in UISpecialFrames)", UISpecialFrames[1] == "DragonworldFrame" and #UISpecialFrames == 1)
check("window background is close to opaque, so things behind it do not show through", win.backdropColor ~= nil and win.backdropColor[4] >= 0.9, win.backdropColor and win.backdropColor[4])
do
    local point, relTo, _, x, y = win.logo:GetPoint(1)
    check("guild shield is large and overlaps the top-left corner",
        win.logo.texture == "Interface\\AddOns\\Dragonworld\\Media\\icon" and point == "TOPLEFT" and relTo == nil and x == 8 and y > 0 and win.logo:GetWidth() == 88,
        tostring(x) .. "," .. tostring(y))
    local tPoint, tRelTo, tRelPoint = win.title:GetPoint(1)
    check("guild name in capitals at the top, next to the shield", win.title.text == "DRAGONWORLD" and tPoint == "TOPLEFT" and tRelTo == win.logo and tRelPoint == "TOPRIGHT", win.title.text)
    check("title uses the decorative font, with a normal font to fall back on", win.title.font ~= nil and win.title.font[1] == "Fonts\\MORPHEUS.TTF" and win.title.fontTemplate == "GameFontNormalHuge")
    check("subtitle under the name (English until a language is chosen)", win.subtitle.text == "GUILD ADDON" and select(2, win.subtitle:GetPoint(1)) == win.title, win.subtitle.text)
    check("window border is tinted gold", win.borderColor ~= nil and win.borderColor[1] > 0.8 and win.borderColor[3] < 0.5)
end

local prompt = win.prompt
check("first time: the language question is shown instead of the modules", prompt ~= nil and prompt:IsVisible() and not win.body:IsVisible())
check("the question is written in all three languages",
    #prompt.fontStrings == 3 and prompt.fontStrings[1].text == ns.strings.en.PROMPT and prompt.fontStrings[2].text == ns.strings.nb.PROMPT and prompt.fontStrings[3].text == ns.strings.nl.PROMPT)
check("three language choices: English, Norsk, Nederlands",
    #prompt.chips == 3 and prompt.chips[1].label.text == "English" and prompt.chips[2].label.text == "Norsk" and prompt.chips[3].label.text == "Nederlands")
check("no module content is built while asking", DragonworldRyddesekkScroll == nil and etterPanelsBuilt == 0)

dw("")
check("/dw closes the window", not win:IsShown())
dw("")
check("reopening without having chosen asks again", win:IsShown() and prompt:IsVisible() and not win.body:IsVisible() and DragonworldDB.language == nil)
kast("")
check("/kast before choosing still asks first", win:IsShown() and prompt:IsVisible() and DragonworldRyddesekkScroll == nil)

-- Choose Dutch.
prompt.chips[3].scripts.OnClick(prompt.chips[3])
check("choosing saves the language", DragonworldDB.language == "nl" and ns.GetLanguage() == "nl" and ns.HasChosenLanguage())

-- Step 2 of the first-time setup: what the addon can do, and what to open in the game.
do
    local intro = win.intro
    check("after choosing, the question goes away and an intro comes, in that language",
        not prompt:IsVisible() and intro ~= nil and intro:IsVisible() and not win.setup:IsVisible() and not win.body:IsVisible()
        and intro.title.text == "Welkom bij Dragonworld!" and intro.canHeading.text == "Wat je kunt doen" and intro.startHeading.text == "Aan de slag"
        and intro.next.label.text == "Volgende" and #intro.tips == 5 and intro.tips[1].text == "- " .. ns.strings.nl.INTRO_TIP_BANK
        and intro.tips[2].text == "- " .. ns.strings.nl.INTRO_TIP_PROFESSIONS and intro.tips[3].text == "- " .. ns.strings.nl.INTRO_TIP_GUILDBANK)
    check("the intro lists every tab in tab order, with its icon, name and what it does",
        #intro.rows == 12 and intro.rows[1].icon.texture == ns.modules.roster.icon
        and intro.rows[1].text.text == "|cffffd100" .. ns.ModuleTitle(ns.modules.roster) .. "|r  " .. ns.ModuleNotes(ns.modules.roster)
        and intro.rows[2].text.text:find(ns.strings.nl.GC_TITLE, 1, true) ~= nil, intro.rows[1] and intro.rows[1].text.text)
    intro.next.scripts.OnClick(intro.next)
end
-- Step 3: what the buttons blink for, and the action bar button.
local setup = win.setup
check("Next leads to the choices, in that language",
    not win.intro:IsVisible() and setup:IsVisible() and not prompt:IsVisible() and not win.body:IsVisible()
    and setup.title.text == "Bijna klaar!" and setup.done.label.text == "Doorgaan" and setup.blink.main.label.text == ns.strings.nl.BLINK_ON
    and setup.blinkHint.text == ns.strings.nl.BLINK_HINT and setup.actionText.text == ns.strings.nl.AB_SETUP)
check("blinking is on by default, with a choice for each thing; guild chat is off by default (a busy guild would blink all the time)",
    setup.blink.main.checked == true and ns.IsBlinkOn() and #setup.blink.kinds == 4
    and setup.blink.kinds[1].checked and setup.blink.kinds[2].checked and not setup.blink.kinds[3].checked and setup.blink.kinds[4].checked
    and setup.blink.kinds[2].label.text == ns.strings.nl.AL_WHISPER and setup.blink.kinds[3].label.text == ns.strings.nl.AL_GUILDCHAT)
setup.blink.kinds[3].checked = true
setup.blink.kinds[3].scripts.OnClick(setup.blink.kinds[3])
check("ticking guild chat turns it on, and remembers that", ns.IsAlertOn("guildchat") and DragonworldDB.alerts.on.guildchat == true)
setup.blink.kinds[3].checked = false
setup.blink.kinds[3].scripts.OnClick(setup.blink.kinds[3])
check("...and unticking turns it off again", not ns.IsAlertOn("guildchat") and DragonworldDB.alerts.off.guildchat == true)
check("the icon to drag onto the action bar is the guild's dragon", setup.actionSource.icon.texture == "Interface\\AddOns\\Dragonworld\\Media\\button")
check("the professions reminder waits until the setup is done", DragonworldShareNotice == nil)
dw("")
dw("")
check("closing and reopening comes back to the choices, not the language or the intro",
    win:IsShown() and setup:IsVisible() and not win.intro:IsVisible() and not prompt:IsVisible() and not win.body:IsVisible())
setup.blink.main.checked = false
setup.blink.main.scripts.OnClick(setup.blink.main)
check("unticking turns blinking off and saves it", not ns.IsBlinkOn() and DragonworldDB.alerts.blinkOff == true)
setup.blink.main.checked = true
setup.blink.main.scripts.OnClick(setup.blink.main)
check("ticking it again turns it back on", ns.IsBlinkOn() and DragonworldDB.alerts.blinkOff == nil)
setup.done.scripts.OnClick(setup.done)
check("Continue remembers the setup, and the modules appear",
    DragonworldDB.setupDone == true and DragonworldDB.setupVersion == 2 and not setup:IsVisible() and win.body:IsVisible() and win:IsShown())

-- Right after the language is chosen: a reminder to open your professions.
local shareNotice = DragonworldShareNotice
check("after the language is chosen, a box asks the player to open their professions, in that language",
    shareNotice ~= nil and shareNotice:IsVisible() and shareNotice.parent == win and shareNotice.title.text == "Deel je beroepen"
    and shareNotice.text.text == ns.strings.nl.RO_SHARE_TEXT and shareNotice.listHeader.text == "Tot nu toe gevonden op dit personage:"
    and shareNotice.note.text == ns.strings.nl.RO_SHARE_NOTE and shareNotice.ok.label.text == "OK")
check("it lists the professions the addon knows of, none of them opened yet",
    shareNotice.list.text == "Cooking 150 - nog niet geopend\nEngineering 210 - nog niet geopend\nMining 225 - nog niet geopend", shareNotice.list.text)
dw("")
dw("")
check("it comes back until the player has pressed OK", win:IsShown() and shareNotice:IsVisible())
shareNotice.ok.scripts.OnClick(shareNotice.ok)
check("OK closes it and remembers that this character has seen it",
    not shareNotice:IsShown() and DragonworldDB.modules.roster.reminded["Tester-Stormrage"] == true)
dw("")
dw("")
check("after that it stays away", win:IsShown() and not shareNotice:IsShown())

local rsPanel = DragonworldRyddesekkScroll and DragonworldRyddesekkScroll.parent
local chipByID = {}
local chipOrder = {}
for _, child in ipairs(win.body.children) do
    if child.kind == "Button" and child.id then chipByID[child.id] = child; chipOrder[#chipOrder + 1] = child end
end
local rsChip, etterChip, kaputtChip = chipByID.ryddesekk, chipByID.etter, chipByID.kaputt
local matChip, kbChip, evChip, roChip = chipByID.materialer, chipByID.keybinds, chipByID.events, chipByID.roster
check("the module asked for (/kast) is the one that opens", rsPanel ~= nil and rsPanel:IsVisible() and rsChip.selected and isGold(rsChip.borderColor))
check("one chip per module that has content, top to bottom in order",
    #chipOrder == 12 and chipOrder[1] == rsChip and chipOrder[2] == matChip and chipOrder[3] == kbChip and chipOrder[4] == evChip
    and chipOrder[5] == roChip and chipOrder[6] == chipByID.guildchat and chipOrder[7] == chipByID.guildbank and chipOrder[8] == chipByID.forslag
    and chipOrder[9] == chipByID.dungeons and chipOrder[10] == chipByID.professions and chipOrder[11] == etterChip and chipOrder[12] == kaputtChip
    and chipByID.boom == nil, #chipOrder)
do
    local ok = true
    -- The default order (the guild leader's choice), test modules last.
    local position = { roster = 1, guildchat = 2, dungeons = 3, guildbank = 4, events = 5, professions = 6, materialer = 7, ryddesekk = 8, keybinds = 9, forslag = 10, etter = 11, kaputt = 12 }
    for _, chip in ipairs(chipOrder) do
        local index = position[chip.id] or 99
        local point, relTo, _, x, y = chip:GetPoint(1)
        -- Twelve tabs (ten modules and two test ones) do not fit 48 apart above
        -- Settings (434 - 48 = 386 high), so they move to 32 apart and get 30 tall.
        if not (point == "TOPLEFT" and x == 0 and y == -(index - 1) * 32 and chip:GetWidth() == 190 and chip:GetHeight() == 30
            and (index - 1) * 32 + 30 <= 434 - 40) then ok = false end
    end
    local sPoint, _, _, sx, sy = win.settingsChip:GetPoint(1)
    check("chips are stacked down the left side, Settings at the bottom", ok and sPoint == "BOTTOMLEFT" and sx == 0 and sy == 0)
    local cPoint, _, _, cx = win.content:GetPoint(1)
    check("module content is to the right of the chips", cPoint == "TOPLEFT" and cx == 200 and win.content:GetWidth() == 612, win.content:GetWidth())
    check("each chip has an icon: the module's own, or the guild shield if it has none",
        rsChip.icon.texture == "Interface\\Icons\\INV_Misc_Bag_08" and etterChip.icon.texture == ns.ICON and win.settingsChip.icon.texture == "Interface\\Icons\\Trade_Engineering",
        tostring(rsChip.icon and rsChip.icon.texture))
    check("subtitle follows the chosen language", win.subtitle.text == "GUILD-ADDON", win.subtitle.text)
end
check("chip and settings texts are Dutch", rsChip.label.text == "Opruimtas" and etterChip.label.text == "Etter" and win.settingsChip.label.text == "Instellingen",
    tostring(rsChip.label.text) .. " / " .. tostring(win.settingsChip.label.text))
check("Ryddesekk panel text is Dutch",
    rsPanel.title.text == "Quest-voorwerpen die weg kunnen" and rsPanel.hint.text == ns.strings.nl.RS_HINT
    and rsPanel.headerItem.text == "Voorwerp" and rsPanel.headerKeep.text == "Bewaren")
check("tooltip is Dutch", verdict(5) == "Kan waarschijnlijk weg", (verdict(5)))

local function visibleRows()
    local out = {}
    for _, row in ipairs(DragonworldRyddesekkScroll.scrollChild.children) do
        if row:IsShown() then out[#out + 1] = row end
    end
    return out
end
local function describe()
    local parts = {}
    for _, row in ipairs(visibleRows()) do
        local text = row.name.text
        parts[#parts + 1] = (text:match("%[(.-)%]") or text) .. (text:match("|r( x%d+)$") or "")
            .. "=" .. row.status.text .. (row.check.checked and "*" or "")
    end
    return table.concat(parts, " | ")
end
local function rowFor(name)
    for _, row in ipairs(visibleRows()) do
        if row.name.text:find("[" .. name .. "]", 1, true) then return row end
    end
end
local function click(row, checked)
    row.check.checked = checked           -- the client flips the box, then runs OnClick
    row.check.scripts.OnClick(row.check)
end
check("rows are Dutch too", rowFor("Faded Letter").status.text == "Kan waarschijnlijk weg" and rowFor("Old Journal").status.text == "Kan weg", describe())

-- Settings: the place to change language later.
win.settingsChip.scripts.OnClick(win.settingsChip)
local settings
for _, child in ipairs(win.content.children) do
    if child.languageChips then settings = child end
end
check("Settings opens in the content area and replaces the module", settings ~= nil and settings:IsVisible() and not rsPanel:IsVisible())
check("Settings chip is highlighted, module chip is not", win.settingsChip.selected and not rsChip.selected and isGold(win.settingsChip.borderColor) and not isGold(rsChip.borderColor))
check("Settings is Dutch and shows Dutch as the current language",
    settings.languageLabel.text == "Taal" and settings.minimapLabel.text == "Knop bij de minimap tonen"
    and settings.languageChips[3].selected and not settings.languageChips[1].selected and not settings.languageChips[2].selected)

settings.languageChips[2].scripts.OnClick(settings.languageChips[2])           -- Norsk
check("picking Norsk in Settings saves it", DragonworldDB.language == "nb" and ns.GetLanguage() == "nb")
check("everything on screen switches to Norwegian at once",
    settings.languageLabel.text == "Språk" and settings.minimapLabel.text == "Vis knappen ved minimapet"
    and win.settingsChip.label.text == "Innstillinger" and rsChip.label.text == "Ryddesekk"
    and settings.languageChips[2].selected and not settings.languageChips[3].selected)
check("tooltip is Norwegian", verdict(5) == "Kan trolig kastes", (verdict(5)))

check("minimap checkbox shows the button is on", settings.minimapCheck.checked == true)
settings.minimapCheck.checked = false
settings.minimapCheck.scripts.OnClick(settings.minimapCheck)
check("unticking hides the minimap button and remembers it", not mm:IsShown() and DragonworldDB.minimap.hide == true)
settings.minimapCheck.checked = true
settings.minimapCheck.scripts.OnClick(settings.minimapCheck)
check("ticking shows it again", mm:IsShown() and DragonworldDB.minimap.hide == nil)

-- Chips switch between modules.
etterChip.scripts.OnEnter(etterChip)
check("hovering a chip lights it up", etterChip.hovered and colour(etterChip.borderColor, 0.80, 0.80, 0.80))
etterChip.scripts.OnLeave(etterChip)
check("leaving a chip dims it again", not etterChip.hovered and colour(etterChip.borderColor, 0.45, 0.45, 0.45))
etterChip.scripts.OnClick(etterChip)
check("clicking a chip shows that module and hides the previous page",
    etterPanel ~= nil and etterPanel:IsVisible() and etterPanel.timesShown == 1 and not settings:IsVisible() and etterChip.selected and not win.settingsChip.selected)
rsChip.scripts.OnClick(rsChip)
check("clicking back shows Ryddesekk again, in Norwegian", rsPanel:IsVisible() and not etterPanel:IsVisible() and rsChip.selected and not etterChip.selected
    and rsPanel.headerKeep.text == "Behold" and rowFor("Faded Letter").status.text == "Kan trolig kastes")
etterChip.scripts.OnClick(etterChip)
check("a module's content is built once and reused", etterPanelsBuilt == 1 and etterPanel.timesShown == 2)

clearChat()
kaputtChip.scripts.OnClick(kaputtChip)
check("a module whose content fails is reported, and the window survives", has("Feil i Kaputt:") and has("panel kaboom") and win:IsShown(), chatText())
rsChip.scripts.OnClick(rsChip)
check("other modules still open after that", rsPanel:IsVisible() and rsChip.selected)
clearChat()

-- Switching language while a module is open rewrites it.
ns.SetLanguage("en", true)
check("switching language rewrites the open module", rsPanel.headerKeep.text == "Keep" and rowFor("Old Journal").status.text == "Safe to discard" and rsChip.label.text == "Tidy Bag")
ns.SetLanguage("nb", true)
check("...and back", rsPanel.headerKeep.text == "Behold" and rowFor("Old Journal").status.text == "Kan kastes" and rsChip.label.text == "Ryddesekk")

dw("")
check("window closed before the tooltip tests", not win:IsShown() and not rsPanel:IsVisible())

-- ============================ tooltip verdicts ==================================
label, reason, n = verdict(7)
check("saved mark 'kast' from the old version still applies", label == "Kan kastes" and n == 3, label)
kast("fjern " .. link(7))
check("fjern removes mark; plain sword has no line", verdict(7) == nil)
check("fjern wrote through to saved variables", saved().marks[7] == nil)

label, reason = verdict(1)
check("delivery item mentioned in quest text -> Behold", label == "Behold" and reason:find("Note to William", 1, true), tostring(label) .. " / " .. tostring(reason))
label, reason = verdict(2)
check("objective item -> Behold", label == "Behold" and reason:find("Kobold Candles", 1, true), tostring(label) .. " / " .. tostring(reason))
label, reason = verdict(3)
check("starts a completed quest -> Kan kastes", label == "Kan kastes" and reason:find("fullført", 1, true), tostring(label) .. " / " .. tostring(reason))
label, reason = verdict(4)
check("starts a quest not yet taken -> Behold", label == "Behold" and reason:find("ikke har tatt", 1, true), tostring(label) .. " / " .. tostring(reason))
label, reason = verdict(12)
check("starts a quest that is active -> Behold", label == "Behold" and reason:find("holder på med", 1, true), tostring(label) .. " / " .. tostring(reason))
label, reason = verdict(5)
check("leftover quest item, no quest mentions it -> Kan trolig kastes", label == "Kan trolig kastes", tostring(label) .. " / " .. tostring(reason))
label = verdict(11)
check("bind-type quest item (not class 12) -> Kan trolig kastes", label == "Kan trolig kastes", label)
label = verdict(6)
check("epic quest item with no quest -> Sjekk før du kaster", label == "Sjekk før du kaster", label)
label, reason = verdict(9)
check("quest special (usable) item -> Behold", label == "Behold" and reason:find("Totemic Trials", 1, true), tostring(label) .. " / " .. tostring(reason))

check("non-quest item -> no line", verdict(7) == nil)
check("quest item not in bags -> no line", verdict(8) == nil)
check("item info not loaded -> no line", verdict(10) == nil)
check("secret item id -> no line", verdict(SECRET) == nil)
check("nil data -> no line", (function() GameTooltip:Reset(); tooltipCallback(GameTooltip, nil); return #GameTooltip.lines == 0 end)())
check("other tooltips are ignored", verdict(5, OtherTooltip) == nil)
check("ItemRefTooltip gets the line", verdict(5, ItemRefTooltip) == "Kan trolig kastes")
check("no error reports in chat so far", not has("Feil"), chatText())

GameTooltip:Reset()
tooltipCallback(GameTooltip, { id = 5 })
tooltipCallback(GameTooltip, { id = 5 })
check("duplicate announcement adds lines once", #GameTooltip.lines == 3, #GameTooltip.lines)
GameTooltip:Reset()
tooltipCallback(GameTooltip, { id = 5 })
check("lines come back after tooltip is cleared", #GameTooltip.lines == 3, #GameTooltip.lines)
GameTooltip.lines = {}
GameTooltip:Fire("OnHide")
tooltipCallback(GameTooltip, { id = 5 })
check("lines come back after tooltip is hidden", #GameTooltip.lines == 3, #GameTooltip.lines)

table.remove(LOG, 2)                      -- "Note to William" turned in / abandoned
check("stale cache still says Behold before the event", verdict(1) == "Behold")
fire("QUEST_REMOVED", 200)
check("after QUEST_REMOVED the note is Kan trolig kastes", verdict(1) == "Kan trolig kastes", (verdict(1)))
check("quest events queue no refresh while the window is closed", queued(0.1) == 0, queued(0.1))

-- ============================ slash commands ====================================
clearChat()
kast("behold " .. link(5))
label, reason = verdict(5)
check("/kast behold -> Behold", label == "Behold" and reason:find("selv merket", 1, true), label)
check("/kast behold confirms in chat with the link", has("[Faded Letter]") and has("behold"), chatText())
kast("MERK " .. link(7))
check("/kast MERK (any case) -> Kan kastes on a non-quest item", verdict(7) == "Kan kastes")
check("marks stored in saved variables", saved().marks[5] == "behold" and saved().marks[7] == "kast")
kast("remove " .. link(5))
check("command words work in English too (remove)", saved().marks[5] == nil)
kast("bewaar " .. link(5))
check("...and in Dutch (bewaar)", saved().marks[5] == "behold")
clearChat()
kast("merk")
check("/kast merk without item explains what to do", has("Skriv /kast merk og shift-klikk"), chatText())
clearChat()
kast("tull")
check("unknown command prints the module's help", has("Kommandoer:") and has("/kast liste") and has("/kast behold [gjenstand]"), chatText())
clearChat()
kast(link(5))
check("bare link prints help rather than erroring", has("Kommandoer:"), chatText())

clearChat()
kast("liste")
local listing = chatText()
io.write("---- /kast liste ----\n", listing, "\n---------------------\n")
check("list includes sure trash (Old Journal)", listing:find("[Old Journal]", 1, true))
check("list includes probable trash (Sealed Note)", listing:find("[Sealed Note]", 1, true))
check("list includes unsure (Qiraji Bindings)", listing:find("[Qiraji Bindings]", 1, true))
check("list includes manually marked sword", listing:find("[Iron Sword]", 1, true))
check("list excludes kept items", not listing:find("[Kobold Candle]", 1, true) and not listing:find("[Faded Letter]", 1, true) and not listing:find("[Mysterious Map]", 1, true))
check("/kast liste did not open the window", not win:IsShown())

-- ============================ Ryddesekk panel ===================================
etterChip.scripts.OnClick(etterChip)      -- leave another module selected, window closed
clearChat()
kast("")
check("/kast opens the main window straight on Ryddesekk", win:IsShown() and rsPanel:IsVisible() and rsChip.selected and not etterPanel:IsVisible())
check("opening the window prints nothing", chatText() == "", chatText())

local expected = "Bind Only Scroll=Kan trolig kastes | Faded Letter=Behold* | Iron Sword=Kan kastes | Old Journal=Kan kastes | Qiraji Bindings=Sjekk før du kaster | Sealed Note=Kan trolig kastes"
check("panel lists candidates A-Z, kept one ticked, auto-kept ones left out", describe() == expected, describe())
check("empty text hidden while there are rows", not rsPanel.empty:IsShown())
check("scroll content is as tall as its rows", rsPanel.content:GetHeight() == 6 * 26, rsPanel.content:GetHeight())
check("rows are as wide as the list area", rowFor("Old Journal"):GetWidth() == 612 - 40, rowFor("Old Journal"):GetWidth())
check("row icon set from item info", rowFor("Old Journal").icon.texture == 1003, rowFor("Old Journal").icon.texture)
check("status text is coloured", type(rowFor("Old Journal").status.color) == "table")

click(rowFor("Old Journal"), true)
check("ticking stores the mark", saved().marks[3] == "behold")
check("ticked row stays in place and now says Behold",
    describe() == "Bind Only Scroll=Kan trolig kastes | Faded Letter=Behold* | Iron Sword=Kan kastes | Old Journal=Behold* | Qiraji Bindings=Sjekk før du kaster | Sealed Note=Kan trolig kastes", describe())
check("tooltip agrees after ticking", verdict(3) == "Behold")

click(rowFor("Old Journal"), false)
check("unticking clears the mark", saved().marks[3] == nil)
check("unticked row is back to Kan kastes", rowFor("Old Journal").status.text == "Kan kastes" and not rowFor("Old Journal").check.checked)

click(rowFor("Faded Letter"), false)
check("unticking a slash-marked item clears it and keeps the row", saved().marks[5] == nil and rowFor("Faded Letter").status.text == "Kan trolig kastes", describe())

click(rowFor("Iron Sword"), true)
check("ticking a 'kast'-marked item flips it to behold", saved().marks[7] == "behold" and rowFor("Iron Sword").status.text == "Behold")
click(rowFor("Iron Sword"), false)
check("unticking it drops the item from the list (plain sword, no verdict)", rowFor("Iron Sword") == nil and #visibleRows() == 5, describe())

do
    local row = rowFor("Qiraji Bindings")
    row.scripts.OnEnter(row)
    check("row hover shows that bag item's tooltip", GameTooltip.owner == row and GameTooltip.bagItem[1] == 1 and GameTooltip.bagItem[2] == 2 and GameTooltip:IsShown())
    check("row tooltip carries the verdict", GameTooltip.lines[2] == "Sjekk før du kaster", GameTooltip.lines[2])
    row.scripts.OnLeave(row)
    check("leaving the row hides the tooltip", not GameTooltip:IsShown())
end

BAGS[1][4] = 11                           -- a second stack of Bind Only Scroll
STACKS["1:4"] = 3
BAGS[0][1] = false                        -- Sealed Note thrown away
fire("BAG_UPDATE_DELAYED")
fire("BAG_UPDATE_DELAYED")
check("bag events are batched into one refresh", queued(0.1) == 1, queued(0.1))
check("nothing changes until the batch runs", rowFor("Sealed Note") ~= nil)
flush()
check("after the refresh: stack total shown, thrown item gone",
    describe() == "Bind Only Scroll x4=Kan trolig kastes | Faded Letter=Kan trolig kastes | Old Journal=Kan kastes | Qiraji Bindings=Sjekk før du kaster", describe())
check("leftover row is hidden, not left stale", #DragonworldRyddesekkScroll.scrollChild.children == 6 and #visibleRows() == 4)

table.insert(LOG, { questID = 203, title = "Scroll Run", objectives = {}, description = "x", summary = "Carry the Bind Only Scroll north." })
fire("QUEST_ACCEPTED", 203)
flush()
check("item needed by a newly accepted quest leaves the list", rowFor("Bind Only Scroll") == nil and #visibleRows() == 3, describe())

kast("behold " .. link(6))
check("slash mark updates the open panel at once", rowFor("Qiraji Bindings").check.checked and rowFor("Qiraji Bindings").status.text == "Behold")
kast("fjern " .. link(6))

-- While another module is showing, Ryddesekk does not refresh in the background.
etterChip.scripts.OnClick(etterChip)
fire("BAG_UPDATE_DELAYED")
check("no refresh is queued while another module is showing", queued(0.1) == 0, queued(0.1))
rsChip.scripts.OnClick(rsChip)

-- Moving the window saves its position.
win.scripts.OnDragStart(win)
check("dragging starts a move", win.moving == true)
win:ClearAllPoints()
win:SetPoint("CENTER", UIParent, "CENTER", 30, 40)   -- where the client leaves it
win.scripts.OnDragStop(win)
check("drop saves the new position", DragonworldDB.window.point == "CENTER" and DragonworldDB.window.relativePoint == "CENTER"
    and DragonworldDB.window.x == 30 and DragonworldDB.window.y == 40 and win.moving == false)

kast("  ")
check("/kast again closes the window", not win:IsShown())
BAGS[0][3] = false                        -- Old Journal thrown away while closed
fire("BAG_UPDATE_DELAYED")
check("no refresh is queued while the window is closed", queued(0.1) == 0, queued(0.1))
kast(nil)
check("/kast (nil message) reopens the same window", win:IsShown() and DragonworldFrame == win and rsPanel:IsVisible())
check("reopening refreshes the list", describe() == "Faded Letter=Kan trolig kastes | Qiraji Bindings=Sjekk før du kaster", describe())

local savedBags = BAGS
BAGS = {}
fire("BAG_UPDATE_DELAYED")
flush()
check("empty bags: no rows, empty text shown", #visibleRows() == 0 and rsPanel.empty:IsShown() and rsPanel.empty.text == ns.strings.nb.RS_EMPTY and rsPanel.content:GetHeight() == 1)
clearChat()
kast("liste")
check("empty bags: /kast liste says 'fant ingenting'", has("Fant ingenting"), chatText())
BAGS = savedBags
fire("BAG_UPDATE_DELAYED")
flush()
check("rows come back when the bags fill again", #visibleRows() == 2 and not rsPanel.empty:IsShown(), describe())

-- ================================ discarding ====================================
-- A real click: one hardware event, so the game allows exactly one deletion.
-- Afterwards the bags report the change and the panel redraws.
local function press(button)
    assert(button:IsVisible(), "pressing a button that is not on screen")
    if not button:IsEnabled() then return false end       -- a greyed-out button does not react
    hardwareBudget = 1
    button.scripts.OnClick(button, "LeftButton")
    hardwareBudget = 0
    fire("BAG_UPDATE_DELAYED")
    flush()
    return true
end
local function redraw() fire("BAG_UPDATE_DELAYED"); flush() end
local function deletedList() return table.concat(deleted, ",") end
local nextButton, nextLabel = rsPanel.nextButton, rsPanel.nextLabel

-- Old Journal in two stacks (sure), Iron Sword marked by hand (sure), Faded
-- Letter (probably), Qiraji Bindings (check first), Bind Only Scroll (needed
-- by a quest) and Kobold Candle (needed by a quest).
BAGS = { [0] = { 3, 5, 6, 7 }, [1] = { 11, 3, 2 }, [2] = {} }
STACKS = {}
kast("merk " .. link(7))
clearChat()
redraw()
check("list before discarding", describe() == "Faded Letter=Kan trolig kastes | Iron Sword=Kan kastes | Old Journal x2=Kan kastes | Qiraji Bindings=Sjekk før du kaster", describe())
check("every row has a red Discard button, in the chosen language",
    rowFor("Faded Letter").discard:IsVisible() and rowFor("Faded Letter").discard.label.text == "Kast" and rowFor("Faded Letter").discard.style == "red")
check("bottom button counts the sure ones and names the next", nextButton:IsEnabled() and nextButton.style == "gold"
    and nextButton.label.text == "Kast neste (2)" and nextLabel.text == "Neste: " .. link(7), nextButton.label.text .. " / " .. tostring(nextLabel.text))

press(nextButton)
check("one click on the bottom button discards exactly one item: the one it named", deletedList() == "7" and BAGS[0][4] == false, deletedList())
check("what was discarded is logged in chat, with the item link", #chat == 1 and has("Kastet " .. link(7) .. "."), chatText())
check("the button moves on to the next sure item", nextButton.label.text == "Kast neste (1)" and nextLabel.text == "Neste: " .. link(3) and rowFor("Iron Sword") == nil)

press(nextButton)
check("an item in two stacks loses one stack per click", deletedList() == "7,3" and describe():find("Old Journal=Kan kastes", 1, true) and nextButton.label.text == "Kast neste (1)", describe())
press(nextButton)
check("...and the second click takes the other stack", deletedList() == "7,3,3" and rowFor("Old Journal") == nil)
check("with no sure items left the bottom button greys out", not nextButton:IsEnabled() and nextButton.label.text == "Kast neste (0)" and nextLabel.text == "Ingenting knappen kan kaste.", nextButton.label.text)
check("a greyed-out button does not react", press(nextButton) == false and deletedList() == "7,3,3")
hardwareBudget = 1
nextButton.scripts.OnClick(nextButton, "LeftButton")      -- even if it somehow ran:
hardwareBudget = 0
check("the bottom button never touches 'probably' or 'check first' items", deletedList() == "7,3,3" and BAGS[0][2] == 5 and BAGS[0][3] == 6, deletedList())
check("items needed by quests are untouched so far", BAGS[1][1] == 11 and BAGS[1][3] == 2)

-- A 'check first' item needs two clicks; moving the mouse away cancels.
local qRow = rowFor("Qiraji Bindings")
press(qRow.discard)
check("first click on a 'check first' item only asks", deletedList() == "7,3,3" and BAGS[0][3] == 6 and rowFor("Qiraji Bindings").discard.label.text == "Sikker?")
check("the question is on that row only", rowFor("Faded Letter").discard.label.text == "Kast")
qRow.discard:Fire("OnLeave")
check("moving the mouse away cancels the question", rowFor("Qiraji Bindings").discard.label.text == "Kast")
press(qRow.discard)
press(qRow.discard)
check("two clicks in a row discard it", deletedList() == "7,3,3,6" and BAGS[0][3] == false and rowFor("Qiraji Bindings") == nil, deletedList())

-- A 'probably' item goes with a single click.
clearChat()
press(rowFor("Faded Letter").discard)
check("a 'probably safe' item is discarded with one click on its row", deletedList() == "7,3,3,6,5" and has("Kastet " .. link(5) .. ".") and #visibleRows() == 0, deletedList())
check("needed quest items are still in the bags", BAGS[1][1] == 11 and BAGS[1][3] == 2)

-- The player chooses whether the bottom button may also take 'probably safe' items.
BAGS[0][1] = 5
BAGS[0][3] = 6
redraw()
check("off by default: the bottom button ignores 'probably safe' items",
    saved().includeMaybe == nil and not rsPanel.includeCheck.checked and not nextButton:IsEnabled()
    and rsPanel.includeLabel.text == ns.strings.nb.RS_INCLUDE_MAYBE)
rsPanel.includeCheck.checked = true
rsPanel.includeCheck.scripts.OnClick(rsPanel.includeCheck)
check("ticking the choice is remembered, and the button now offers the 'probably safe' item",
    saved().includeMaybe == true and nextButton:IsEnabled() and nextButton.label.text == "Kast neste (1)" and nextLabel.text == "Neste: " .. link(5),
    nextButton.label.text)
press(nextButton)
check("the button then discards it", deleted[#deleted] == 5 and BAGS[0][1] == false and deletedList() == "7,3,3,6,5,5", deletedList())
check("...but still never a 'check first' item", not nextButton:IsEnabled() and BAGS[0][3] == 6 and rowFor("Qiraji Bindings") ~= nil)
rsPanel.includeCheck.checked = false
rsPanel.includeCheck.scripts.OnClick(rsPanel.includeCheck)
check("unticking turns it off again", saved().includeMaybe == nil and not rsPanel.includeCheck.checked)
BAGS[0][3] = false
redraw()

-- Keep protects an item.
BAGS[0][1] = 5
redraw()
click(rowFor("Faded Letter"), true)
check("ticking Keep removes the Discard button from that row", not rowFor("Faded Letter").discard:IsShown())
hardwareBudget = 1
rowFor("Faded Letter").discard.scripts.OnClick(rowFor("Faded Letter").discard, "LeftButton")
hardwareBudget = 0
check("a kept item is not discarded even if its button were clicked", deletedList() == "7,3,3,6,5,5" and BAGS[0][1] == 5, deletedList())
click(rowFor("Faded Letter"), false)
check("unticking Keep brings the Discard button back", rowFor("Faded Letter").discard:IsShown())

-- The game refuses the deletion (no hardware event left).
clearChat()
hardwareBudget = 0
rowFor("Faded Letter").discard.scripts.OnClick(rowFor("Faded Letter").discard, "LeftButton")
check("if the game refuses, nothing is lost and the item is not left on the cursor", BAGS[0][1] == 5 and cursorItem == nil and deletedList() == "7,3,3,6,5,5", deletedList())
check("...and the player is told", has("Fikk ikke kastet " .. link(5) .. ". Prøv igjen."), chatText())

-- The list on screen is out of date: the letter moved, and a needed quest item
-- now sits where the letter used to be.
BAGS[0][1] = 2                            -- Kobold Candle (needed) in the letter's old slot
BAGS[2][1] = 5                            -- the letter itself moved here
hardwareBudget = 1
rowFor("Faded Letter").discard.scripts.OnClick(rowFor("Faded Letter").discard, "LeftButton")   -- no redraw first
hardwareBudget = 0
check("a stale list never discards what now lies in the old slot", BAGS[0][1] == 2 and BAGS[2][1] == false and deletedList() == "7,3,3,6,5,5,5", deletedList())
redraw()

-- Something else is already on the mouse cursor.
BAGS[0][2] = 5
redraw()
cursorItem = { bag = 0, slot = 1, id = 2 }                -- the player is holding the Kobold Candle
press(rowFor("Faded Letter").discard)
check("an item already held on the cursor is put back, not discarded", BAGS[0][1] == 2 and BAGS[0][2] == false and deleted[#deleted] == 5 and cursorItem == nil)

-- A locked item (in the middle of being moved).
BAGS[0][2] = 5
LOCKED["0:2"] = true
redraw()
clearChat()
press(rowFor("Faded Letter").discard)
check("a locked item is left alone", BAGS[0][2] == 5 and has("Fikk ikke kastet"), chatText())
LOCKED = {}

-- A quest that needs the item was accepted after the list was drawn.
table.insert(LOG, { questID = 204, title = "Old Letters", objectives = {}, description = "x", summary = "Bring the Faded Letter to the archivist." })
fire("QUEST_ACCEPTED", 204)               -- refresh is queued but has not run: the row still shows Discard
local staleRow = rowFor("Faded Letter")
local before = #deleted
hardwareBudget = 1
staleRow.discard.scripts.OnClick(staleRow.discard, "LeftButton")
hardwareBudget = 0
check("an item a new quest needs is not discarded from a stale row", #deleted == before and BAGS[0][2] == 5)
flush()
check("...and it then leaves the list", rowFor("Faded Letter") == nil)
table.remove(LOG)
fire("QUEST_REMOVED", 204)
flush()

-- Leaving the panel cancels a pending question.
BAGS[0][3] = 6
redraw()
press(rowFor("Qiraji Bindings").discard)
check("question pending", rowFor("Qiraji Bindings").discard.label.text == "Sikker?")
etterChip.scripts.OnClick(etterChip)
rsChip.scripts.OnClick(rsChip)
check("switching module cancels a pending question", rowFor("Qiraji Bindings").discard.label.text == "Kast" and BAGS[0][3] == 6)

-- Back to a state the remaining tests expect.
kast("fjern " .. link(7))
clearChat()
BAGS = { [0] = { false, 2, false, 4 }, [1] = { 5, 6, 7, 11, 9 }, [2] = { 10, 11, 12 } }
redraw()
check("list restored for the remaining tests", describe() == "Faded Letter=Kan trolig kastes | Qiraji Bindings=Sjekk før du kaster", describe())

-- ================================ Materialer ====================================
local function matDB() return DragonworldDB.modules.materialer end
local testerBags = BAGS

-- Tester has materials in the bags and in the bank (containers 6 and 7).
BAGS = { [0] = { 20, 21, 5, 20, 23 }, [1] = {}, [2] = {}, [6] = { 22, 20 }, [7] = { 21 } }
STACKS = { ["0:1"] = 10, ["0:2"] = 5, ["0:4"] = 3, ["6:1"] = 7, ["6:2"] = 40, ["7:1"] = 20 }
flush()
fire("BAG_UPDATE_DELAYED")
fire("BAG_UPDATE_DELAYED")
check("bag changes are batched into one reading", queued(0.3) == 1, queued(0.3))
flush()
local me = matDB().characters["Tester-Stormrage"]
check("materials in the bags are counted per item, with stacks added up",
    me ~= nil and me.bags[20] == 13 and me.bags[21] == 5 and me.name == "Tester" and me.realm == "Stormrage" and me.class == "PALADIN" and me.bagsTime == NOW,
    me and tostring(me.bags[20]))
check("an item the game flags as a crafting reagent counts as a material too", me.bags[23] == 1)
check("things that are not materials are left out", me.bags[5] == nil)
check("the bank is not read while it is closed", next(me.bank) == nil and me.bankTime == nil)

bankIsOpen = true
fire("BANKFRAME_OPENED")
flush()
check("opening the bank reads every bank container", me.bank[22] == 7 and me.bank[20] == 40 and me.bank[21] == 20 and me.bankTime == NOW)
bankIsOpen = false
fire("BANKFRAME_CLOSED")
fire("BAG_UPDATE_DELAYED")
flush()
check("after closing, the bank numbers are remembered", me.bank[20] == 40 and me.bags[20] == 13)
fire("BANKFRAME_OPENED")                  -- the game says open, but the slots cannot be read
flush()
check("an unreadable bank is not mistaken for an empty one", me.bank[20] == 40 and me.bank[22] == 7)
fire("BANKFRAME_CLOSED")

-- Log in on another character.
character = { name = "Altine", realm = "Stormrage", class = "MAGE" }
BAGS = { [0] = { 21, 24 }, [1] = {}, [2] = {} }
STACKS = { ["0:1"] = 2 }
fire("PLAYER_ENTERING_WORLD")
flush()
local alt = matDB().characters["Altine-Stormrage"]
check("another character gets its own record, and the first one is kept",
    alt ~= nil and alt.bags[21] == 2 and alt.bags[24] == 1 and alt.class == "MAGE" and me.bags[20] == 13 and me.bank[20] == 40)

matChip.scripts.OnClick(matChip)
local matPanel = DragonworldMaterialerScroll.parent
local function matDescribe()
    local parts = {}
    for _, row in ipairs(DragonworldMaterialerScroll.scrollChild.children) do
        if row:IsShown() then parts[#parts + 1] = row.name.text .. "=" .. row.count.text end
    end
    return table.concat(parts, " | ")
end
local function matRow(name)
    for _, row in ipairs(DragonworldMaterialerScroll.scrollChild.children) do
        if row:IsShown() and row.name.text == name then return row end
    end
end
check("Materialer opens from its chip", matPanel:IsVisible() and matChip.selected and matChip.label.text == "Materialer" and matChip.icon.texture == "Interface\\Icons\\Trade_BlackSmithing")
check("panel text is Norwegian",
    matPanel.title.text == "Håndverksmaterialer på karakterene dine" and matPanel.headerItem.text == "Materiale" and matPanel.headerCount.text == "Antall"
    and matPanel.sourceChips.all.label.text == "Alle" and matPanel.sourceChips.bags.label.text == "I bagger" and matPanel.sourceChips.bank.label.text == "I bank"
    and matPanel.characterChip.label.text == "Karakter: Alle")
check("every material once, A-Z, summed over characters, bags and bank",
    matDescribe() == "Copper Ore=53 | Empty Vial=1 | Linen Cloth=27 | Strange Dust=7 | item:24=1", matDescribe())
check("'All' is the selected filter to begin with", matPanel.sourceChips.all.selected and not matPanel.sourceChips.bags.selected and not matPanel.sourceChips.bank.selected)
check("names are coloured by item quality", colour(matRow("Strange Dust").name.color, 0.12, 1, 0) and colour(matRow("Copper Ore").name.color, 1, 1, 1))
check("rows show the item icon", matRow("Copper Ore").icon.texture == 1020)

ITEMS[24].unloaded = nil                  -- the game finishes loading that item
fire("GET_ITEM_INFO_RECEIVED", 24, true)
flush()
check("a name that was not loaded appears once the game has it",
    matDescribe() == "Copper Ore=53 | Empty Vial=1 | Linen Cloth=27 | Strange Dust=7 | Unloaded Ore=1" and matDB().items[24].name == "Unloaded Ore", matDescribe())

-- The search box narrows the list while the player types.
local function typeInto(box, text)
    box:TypeText(text)
end
local everything = "Copper Ore=53 | Empty Vial=1 | Linen Cloth=27 | Strange Dust=7 | Unloaded Ore=1"
check("there is an empty search box, labelled in the chosen language", matPanel.searchBox ~= nil and matPanel.searchBox:GetText() == "" and matPanel.searchLabel.text == "Søk:")
typeInto(matPanel.searchBox, "o")
check("the list narrows from the first letter typed", matDescribe() == "Copper Ore=53 | Linen Cloth=27 | Unloaded Ore=1", matDescribe())
typeInto(matPanel.searchBox, "ORE")
check("capitals do not matter, and the text can be anywhere in the name", matDescribe() == "Copper Ore=53 | Unloaded Ore=1", matDescribe())
typeInto(matPanel.searchBox, "  linen ")
check("spaces before and after the search text do not matter", matDescribe() == "Linen Cloth=27", matDescribe())
matPanel.sourceChips.bags.scripts.OnClick(matPanel.sourceChips.bags)
check("search works together with the other filters, and stays when they change", matDescribe() == "Linen Cloth=7" and matPanel.searchBox:GetText() == "  linen ", matDescribe())
matPanel.sourceChips.all.scripts.OnClick(matPanel.sourceChips.all)
typeInto(matPanel.searchBox, "dragon")
check("no match: the list is empty and says so", matDescribe() == "" and matPanel.empty:IsShown() and matPanel.empty.text == "Fant ingen materialer med dette filteret.")
clearChat()
typeInto(matPanel.searchBox, "%a+[(")
check("special characters in the search are taken literally and cause no error", matDescribe() == "" and chatText() == "", chatText())
typeInto(matPanel.searchBox, "")
check("clearing the search shows everything again", matDescribe() == everything and not matPanel.empty:IsShown(), matDescribe())
matPanel.searchBox:SetText("vial")
check("text put in the box by code filters too", matDescribe() == "Empty Vial=1")
matPanel.searchBox:SetText("")

matPanel.sourceChips.bags.scripts.OnClick(matPanel.sourceChips.bags)
check("filter 'in bags'", matDescribe() == "Copper Ore=13 | Empty Vial=1 | Linen Cloth=7 | Unloaded Ore=1" and matPanel.sourceChips.bags.selected and not matPanel.sourceChips.all.selected, matDescribe())
matPanel.sourceChips.bank.scripts.OnClick(matPanel.sourceChips.bank)
check("filter 'in bank'", matDescribe() == "Copper Ore=40 | Linen Cloth=20 | Strange Dust=7", matDescribe())

lastMenu = nil
matPanel.characterChip.scripts.OnClick(matPanel.characterChip)
check("the character button opens a menu with 'all' and each character",
    lastMenu ~= nil and lastMenu.owner == matPanel.characterChip and lastMenu.titles[1] == "Karakter" and #lastMenu.radios == 3
    and lastMenu.radios[1].text == "Alle" and lastMenu.radios[2].text == "Altine" and lastMenu.radios[3].text == "Tester"
    and lastMenu.radios[1].selected() and not lastMenu.radios[2].selected())
lastMenu.radios[2].click()                -- Altine, still filtered on bank
check("one character + bank: nothing, and the panel says so",
    matDescribe() == "" and matPanel.empty:IsShown() and matPanel.empty.text == "Fant ingen materialer med dette filteret."
    and matPanel.characterChip.label.text == "Karakter: Altine")
matPanel.sourceChips.all.scripts.OnClick(matPanel.sourceChips.all)
check("one character, everything", matDescribe() == "Linen Cloth=2 | Unloaded Ore=1" and not matPanel.empty:IsShown(), matDescribe())
matPanel.characterChip.scripts.OnClick(matPanel.characterChip)
check("the menu marks the chosen character", lastMenu.radios[2].selected() and not lastMenu.radios[1].selected())
lastMenu.radios[1].click()
check("back to all characters", matPanel.characterChip.label.text == "Karakter: Alle" and matDescribe():find("Copper Ore=53", 1, true) ~= nil)

do
    local row = matRow("Linen Cloth")
    row.scripts.OnEnter(row)
    local text = table.concat(GameTooltip.lines, " / ")
    check("hovering a material shows where it is, per character",
        GameTooltip:IsShown() and GameTooltip.lines[1] == "Linen Cloth" and text:find("Altine: 2 i bagger, 0 i bank", 1, true) and text:find("Tester: 5 i bagger, 20 i bank", 1, true), text)
    row.scripts.OnLeave(row)
end
check("footer says this character's bank has not been read", matPanel.footer.text == ns.strings.nb.MAT_BANK_NEVER)

-- Two characters with the same name on different realms are told apart.
matDB().characters["Tester-Other"] = { name = "Tester", realm = "Other", bags = { [20] = 1 }, bank = {} }
matPanel.characterChip.scripts.OnClick(matPanel.characterChip)
check("same name on two realms: the realm is shown", lastMenu.radios[3].text == "Tester-Other" and lastMenu.radios[4].text == "Tester-Stormrage", lastMenu.radios[3].text)
matDB().characters["Tester-Other"] = nil

-- Without the menu API, the button steps through the characters.
do
    local savedMenuUtil = MenuUtil
    MenuUtil = nil
    matPanel.characterChip.scripts.OnClick(matPanel.characterChip)
    local first = matPanel.characterChip.label.text
    matPanel.characterChip.scripts.OnClick(matPanel.characterChip)
    local second = matPanel.characterChip.label.text
    matPanel.characterChip.scripts.OnClick(matPanel.characterChip)
    check("without the menu API the button steps Altine -> Tester -> all",
        first == "Karakter: Altine" and second == "Karakter: Tester" and matPanel.characterChip.label.text == "Karakter: Alle", first .. " / " .. second)
    MenuUtil = savedMenuUtil
end

ns.SetLanguage("en", true)
check("Materialer follows the language", matPanel.title.text == "Crafting materials on your characters" and matChip.label.text == "Materials" and matPanel.sourceChips.bank.label.text == "In bank")
ns.SetLanguage("nb", true)

-- Back on Tester, with the bags the remaining tests expect.
character = { name = "Tester", realm = "Stormrage", class = "PALADIN" }
BAGS = testerBags
STACKS = {}
fire("PLAYER_ENTERING_WORLD")
flush()
check("footer shows when this character's bank was last read", matPanel.footer.text == ns.strings.nb.MAT_BANK_SEEN:format("DATE(" .. NOW .. ")"), matPanel.footer.text)
check("bags are re-read on login; the bank numbers stay", me.bags[20] == nil and me.bank[20] == 40)

-- ===================== crafting materials are not thrown away ====================
;(function()
    local savedTradeSkill = C_TradeSkillUI
    C_TradeSkillUI = nil
    table.insert(BAGS[2], 30)               -- Incendicite Ore: quest class, not bound
    table.insert(BAGS[2], 31)               -- Glowing Shard: bound quest item

    local lines = hover(30)
    check("a quest item that is not bound to you is not called safe to discard: it can be sold",
        lines[2] == "Kan selges - ikke kast" and lines[3] == ns.strings.nb.RS_REASON_SELLABLE and #lines == 3, table.concat(lines, " / "))
    check("a bound quest item no quest mentions is still probably safe to discard", hover(31)[2] == "Kan trolig kastes")
    clearChat()
    kast("liste")
    check("things that can be sold are left out of the discard list", has("Glowing Shard") and not has("Incendicite Ore"), chatText())

    -- The game does not say whether it is bound: then it is judged as before.
    BOUND_UNKNOWN = true
    check("when the game does not say whether it is bound, it is judged as before", hover(30)[2] == "Kan trolig kastes")
    ItemLocation = { CreateFromBagAndSlot = function(self, bag, slot) assert(self == ItemLocation); return { bag = bag, slot = slot } end }
    C_Item.IsBound = function(location)
        assert(type(location) == "table" and type(location.bag) == "number", "IsBound(itemLocation)")
        return ITEMS[C_Container.GetContainerItemID(location.bag, location.slot)].bind == 4
    end
    check("...unless the game can tell in another way", hover(30)[2] == "Kan selges - ikke kast")
    BOUND_UNKNOWN, ItemLocation, C_Item.IsBound = nil, nil, nil

    -- Crafting materials say so in the tooltip, with the professions that
    -- usually use that kind of material.
    lines = hover(20)
    check("a crafting material is marked as one, with the professions that usually use it",
        #lines == 3 and lines[1] == " " and lines[2] == "Håndverksmateriale - ikke kast"
        and lines[3] == "Brukes som regel i: Blacksmithing, Engineering, Mining", table.concat(lines, " / "))
    check("cloth goes with tailoring and first aid", hover(21)[3] == "Brukes som regel i: First Aid, Tailoring", hover(21)[3])
    lines = hover(23)
    check("a material of no particular kind is just marked as a material", #lines == 2 and lines[2] == "Håndverksmateriale - ikke kast", table.concat(lines, " / "))
    check("things that are not materials get no such line", #hover(7) == 0)
    C_TradeSkillUI = { GetTradeSkillDisplayName = function(line) return ({ [197] = "Kleskunst", [129] = "Førstehjelp" })[line] end }
    check("profession names come from the game when it has them", hover(21)[3] == "Brukes som regel i: Førstehjelp, Kleskunst", hover(21)[3])

    -- Opening a profession window teaches the addon what its recipes use. Here
    -- it is a guild member's Enchanting, opened from the roster.
    local schematicCalls = 0
    local RECIPES = {
        [501] = { { reagents = { { itemID = 31 } } }, { reagents = { { itemID = 22 } } } },
        [502] = { { reagents = { { itemID = 23 }, { currencyID = 5 } } }, { reagents = { { itemID = SECRET } } } },
    }
    local window = { name = "Enchanting", recipes = { 501, 502 } }
    C_TradeSkillUI = {
        GetBaseProfessionInfo = function() return { professionName = window.name, skillLevel = 120, maxSkillLevel = 150 } end,
        GetAllRecipeIDs = function() return window.recipes end,
        GetRecipeSchematic = function(id, isRecraft)
            assert(type(id) == "number" and isRecraft == false, "GetRecipeSchematic(recipeID, false)")
            schematicCalls = schematicCalls + 1
            return { recipeID = id, reagentSlotSchematics = RECIPES[id] or {} }
        end,
        IsTradeSkillLinked = function() return true end,
    }
    fire("TRADE_SKILL_SHOW")
    lines = hover(31)
    check("a quest item a recipe uses becomes a crafting material: no discard verdict, but the profession that uses it",
        #lines == 3 and lines[2] == "Håndverksmateriale - ikke kast" and lines[3] == "Brukes i: Enchanting", table.concat(lines, " / "))
    check("what the recipes say replaces the guess", hover(22)[3] == "Brukes i: Enchanting" and hover(23)[3] == "Brukes i: Enchanting", hover(22)[3])
    check("money-like reagents and hidden values are skipped",
        matDB().reagents[SECRET] == nil and schematicCalls == 2 and DragonworldDB.modules.roster.seen["Player-1-Tester"] == nil)
    clearChat()
    kast("liste")
    check("a crafting material is left out of the discard list", not has("Glowing Shard"), chatText())
    flush()
    check("...and is now counted among your materials", me.bags[31] == 1, tostring(me.bags[31]))

    fire("TRADE_SKILL_LIST_UPDATE")
    check("the same window is not read again and again", schematicCalls == 2)
    window.name, window.recipes = "Alchemy", { 502 }
    fire("TRADE_SKILL_SHOW")
    check("each profession that uses a material is listed", hover(23)[3] == "Brukes i: Alchemy, Enchanting", hover(23)[3])

    clearChat()
    dw("debug")
    check("/dw debug tells what has been learned from recipes",
        has("GetAllRecipeIDs: true | GetRecipeSchematic: true") and has("materialer lært fra oppskrifter: 3 (Alchemy 1, Enchanting 3)"), chatText())
    ns.SetLanguage("en", true)
    lines = hover(23)
    check("the lines follow the language", lines[2] == "Crafting material - don't discard" and lines[3] == "Used in: Alchemy, Enchanting", table.concat(lines, " / "))
    ns.SetLanguage("nb", true)

    -- Tidy up for the tests that follow.
    clearChat()
    matDB().reagents = {}
    C_TradeSkillUI = savedTradeSkill
    table.remove(BAGS[2])
    table.remove(BAGS[2])
    fire("BAG_UPDATE_DELAYED")
    flush()
    check("back to the bags from before", #BAGS[2] == 3 and me.bags[31] == nil)
end)()

-- ================================= Keybinds =====================================
kbChip.scripts.OnClick(kbChip)
local kbPanel
for _, child in ipairs(win.content.children) do
    if child.autoCheck then kbPanel = child end
end
local function kbDB() return DragonworldDB.modules.keybinds.characters["Tester-Stormrage"] end
local function specRows()
    local out = {}
    for _, child in ipairs(kbPanel.children) do
        if child.save and child:IsShown() then out[#out + 1] = child end
    end
    return out
end
local ATGC = "ACTIVE_TALENT_GROUP_CHANGED"
check("Keybinds opens from its chip", kbPanel ~= nil and kbPanel:IsVisible() and kbChip.selected and kbChip.icon.texture == "Interface\\Icons\\INV_Misc_Key_03")
local row1, row2 = specRows()[1], specRows()[2]
check("panel text is Norwegian, and names the active spec",
    kbPanel.title.text == "Keybinds per spec" and kbPanel.active.text == "Aktiv nå: Hovedspec" and kbPanel.hint.text == ns.strings.nb.KB_HINT
    and kbPanel.autoLabel.text == ns.strings.nb.KB_AUTO and kbPanel.undo.label.text == "Angre siste bytte")
check("one row per spec, the active one in gold",
    #specRows() == 2 and row1.name.text == "Hovedspec" and row2.name.text == "Sekundærspec" and isGold(row1.name.color) and not isGold(row2.name.color))
check("nothing saved yet: Load and Undo are greyed out, automatic switching is off",
    row1.status.text == "Ingenting lagret ennå" and not row1.load:IsEnabled() and row1.save:IsEnabled() and not kbPanel.undo:IsEnabled() and not kbPanel.autoCheck.checked)

clearChat()
row1.save.scripts.OnClick(row1.save)
check("Save stores every command that has keys, per character",
    kbDB() ~= nil and kbDB().sets[1].count == 4 and table.concat(kbDB().sets[1].binds.MOVEFORWARD, ",") == "W,UP" and kbDB().sets[1].binds.TOGGLEBAGS == nil)
check("...says so", has("Lagret tastebindingene dine for Hovedspec (4 kommandoer)."), chatText())
check("...and the row shows it", row1.status.text == "Lagret DATE(" .. NOW .. "), 4 kommandoer med taster" and row1.load:IsEnabled() and not row2.load:IsEnabled(), row1.status.text)
check("saving does not touch the keys themselves", keysOf("ACTIONBUTTON1") == "1" and #bindingsSaved == 0)

-- The player sets the keys up differently and saves that for the other spec.
SetBinding("Q", "ACTIONBUTTON1")
SetBinding("1")
SetBinding("E", "ACTIONBUTTON2")
SetBinding("2")
SetBinding("B", "TOGGLEBAGS")
row2.save.scripts.OnClick(row2.save)
check("a second set is saved separately", kbDB().sets[2].count == 5 and kbDB().sets[2].binds.ACTIONBUTTON1[1] == "Q" and kbDB().sets[1].binds.ACTIONBUTTON1[1] == "1")

clearChat()
row1.load.scripts.OnClick(row1.load)
check("Load puts the saved keys back", keysOf("ACTIONBUTTON1") == "1" and keysOf("ACTIONBUTTON2") == "2" and keysOf("MOVEFORWARD") == "W,UP" and keysOf("JUMP") == "SPACE",
    tostring(keysOf("ACTIONBUTTON1")) .. " " .. tostring(keysOf("MOVEFORWARD")))
check("...and takes away keys the saved set did not have", keysOf("TOGGLEBAGS") == "")
check("...and saves them to the game so they survive a relog", #bindingsSaved == 1 and bindingsSaved[1] == 2)
check("...says so, and Undo becomes available", has("Hentet tastebindingene for Hovedspec.") and kbPanel.undo:IsEnabled())

clearChat()
kbPanel.undo.scripts.OnClick(kbPanel.undo)
check("Undo brings back what was there before the load",
    keysOf("ACTIONBUTTON1") == "Q" and keysOf("ACTIONBUTTON2") == "E" and keysOf("TOGGLEBAGS") == "B" and has("forrige tastebindingene dine er tilbake")
    and not kbPanel.undo:IsEnabled() and kbDB().backup == nil)

inCombat = true
clearChat()
row1.load.scripts.OnClick(row1.load)
check("in combat nothing is changed, and the player is told", keysOf("ACTIONBUTTON1") == "Q" and has("kan ikke endres i kamp"), chatText())
inCombat = false

do
    local good = kbDB().sets[1]
    kbDB().sets[1] = { binds = {}, count = 0, time = NOW }
    row1.load.scripts.OnClick(row1.load)
    check("an empty saved set is refused instead of clearing every key", keysOf("ACTIONBUTTON1") == "Q" and keysOf("MOVEFORWARD") == "W,UP" and keysOf("JUMP") == "SPACE")
    kbDB().sets[1] = good
end

-- Automatic switching is opt-in.
check("automatic switching is off unless the player turns it on", kbDB().auto == nil)
activeSpec = 2
fire(ATGC, 2, 1)
check("with it off, changing spec leaves the keys alone but the panel follows",
    keysOf("ACTIONBUTTON1") == "Q" and kbPanel.active.text == "Aktiv nå: Sekundærspec" and isGold(row2.name.color) and not isGold(row1.name.color))
activeSpec = 1
fire(ATGC, 1, 2)

row1.load.scripts.OnClick(row1.load)      -- standing in spec 1 with spec 1's keys
kbPanel.autoCheck.checked = true
kbPanel.autoCheck.scripts.OnClick(kbPanel.autoCheck)
check("turning automatic switching on is remembered", kbDB().auto == true and kbPanel.autoCheck.checked)

SetBinding("F", "JUMP")                   -- a change made while in spec 1
clearChat()
activeSpec = 2
fire(ATGC, 2, 1)
check("changing spec loads the other spec's keys",
    keysOf("ACTIONBUTTON1") == "Q" and keysOf("ACTIONBUTTON2") == "E" and keysOf("TOGGLEBAGS") == "B" and keysOf("JUMP") == "SPACE"
    and has("Spec byttet: hentet tastebindingene for Sekundærspec."), chatText())
check("...after saving what you had on the spec you left", table.concat(kbDB().sets[1].binds.JUMP, ",") == "SPACE,F")

SetBinding("G", "TOGGLEBAGS")             -- a change made while in spec 2
activeSpec = 1
fire(ATGC, 1, 2)
check("switching back brings spec 1's keys, including the change made there",
    keysOf("JUMP") == "SPACE,F" and keysOf("ACTIONBUTTON1") == "1" and keysOf("TOGGLEBAGS") == "", tostring(keysOf("JUMP")))
check("...and spec 2 remembers the change made there", table.concat(kbDB().sets[2].binds.TOGGLEBAGS, ",") == "B,G")

inCombat = true
activeSpec = 2
fire(ATGC, 2, 1)
check("a spec change in combat does not touch the keys yet", keysOf("ACTIONBUTTON1") == "1" and keysOf("TOGGLEBAGS") == "")
inCombat = false
fire("PLAYER_REGEN_ENABLED")
check("...and is carried out when combat ends", keysOf("ACTIONBUTTON1") == "Q" and keysOf("TOGGLEBAGS") == "B,G", tostring(keysOf("ACTIONBUTTON1")))

kbDB().sets[1] = nil
clearChat()
activeSpec = 1
fire(ATGC, 1, 2)
check("first time in a spec with nothing saved: the keys stay, and are saved for it",
    keysOf("ACTIONBUTTON1") == "Q" and kbDB().sets[1] ~= nil and kbDB().sets[1].binds.ACTIONBUTTON1[1] == "Q" and has("Første gang i Hovedspec"), chatText())

SetBinding("X", "JUMP")
row2.save.scripts.OnClick(row2.save)      -- saved by hand for the other spec, while standing in spec 1
activeSpec = 2
fire(ATGC, 2, 1)
check("keys saved by hand for the other spec do not overwrite the spec you were in",
    not table.concat(kbDB().sets[1].binds.JUMP, ","):find("X", 1, true) and table.concat(kbDB().sets[2].binds.JUMP, ","):find("X", 1, true) ~= nil)

character = { name = "Altine", realm = "Stormrage", class = "MAGE" }
kbChip.scripts.OnClick(kbChip)
rsChip.scripts.OnClick(rsChip)
kbChip.scripts.OnClick(kbChip)
check("another character has its own, empty, keybind sets", specRows()[1].status.text == "Ingenting lagret ennå" and not kbPanel.autoCheck.checked)
character = { name = "Tester", realm = "Stormrage", class = "PALADIN" }

ns.SetLanguage("nl", true)
check("Keybinds follows the language", kbPanel.title.text == "Keybinds per spec" and specRows()[1].name.text == "Primaire spec" and specRows()[1].save.label.text == "Huidige opslaan")
ns.SetLanguage("nb", true)
clearChat()

-- ================================ Guild-events ==================================
local EV_PREFIX = "DragonworldEv"
local TAB = "\t"
local function evDB() return DragonworldDB.modules.events end
-- A message arriving from another guild member.
local function receive(text, sender, channel, prefix)
    fire("CHAT_MSG_ADDON", prefix or EV_PREFIX, text, channel or "GUILD", sender or "Altine-Stormrage")
end
-- Everything this client has sent under one message name since last asked, as
-- plain strings. Messages under other names are left where they are.
local function sentNow(prefix)
    prefix = prefix or EV_PREFIX
    local out, rest = {}, {}
    for _, m in ipairs(wire) do
        assert(m.chatType == "GUILD", "addon message sent somewhere other than the guild channel")
        if m.prefix == prefix then out[#out + 1] = m.message else rest[#rest + 1] = m end
    end
    wire = rest
    return out
end
local function count(list, pattern)
    local n = 0
    for _, text in ipairs(list) do
        if text:find(pattern) then n = n + 1 end
    end
    return n
end

flush()
do
    local sent = sentNow()
    check("the message prefix is registered, and login announced itself once on the guild channel", prefixes[EV_PREFIX] == true and #sent == 1 and sent[1] == "Q", table.concat(sent, " ; "))
end

-- What the roster module sent at login is looked at in its own section; set it
-- aside so the counts below are about events only.
local rosterLogin = sentNow("DragonworldPr")
GBANK.login = sentNow("DragonworldGB")      -- looked at in the Guildbank section
SUG_LOGIN = sentNow("DragonworldSug")       -- and this in the Forslag section (global: the main chunk is out of locals)
STATUS_LOGIN = sentNow("DragonworldSt")     -- and this in the Status section
PROFILE_LOGIN = sentNow("DragonworldPf")    -- and this in the member card section
VERSION_LOGIN = sentNow("DragonworldVer")   -- and this in the version section
check("nothing else is waiting on the wire", #wire == 0, #wire)

evChip.scripts.OnClick(evChip)
local evPanel = DragonworldEventsScroll.parent.parent
local gv, form, detail = evPanel.guild, evPanel.guild.form, evPanel.guild.detail
local function eventRows()
    local out = {}
    for _, row in ipairs(DragonworldEventsScroll.scrollChild.children) do
        if row:IsShown() then out[#out + 1] = row end
    end
    return out
end
check("Guild-events opens from its chip", evPanel:IsVisible() and evChip.selected and evChip.label.text == "Guild-events" and evChip.icon.texture == "Interface\\Icons\\INV_Scroll_03")
check("panel text is Norwegian, with two tabs and our own events first",
    evPanel.title.text == "Guild-events" and evPanel.tabs.guild.label.text == "Våre events" and evPanel.tabs.calendar.label.text == "Spillets kalender"
    and evPanel.tabs.guild.selected and not evPanel.tabs.calendar.selected and gv:IsVisible() and not evPanel.calendar:IsVisible())
check("with no events the panel says so and offers New event",
    #eventRows() == 0 and gv.empty:IsShown() and gv.empty.text == ns.strings.nb.EV_EMPTY and gv.newButton.label.text == "Ny event" and not detail:IsShown() and not form:IsShown())

-- Making an event.
gv.newButton.scripts.OnClick(gv.newButton)
check("New event opens the form", form:IsVisible() and not detail:IsShown() and not gv.empty:IsShown()
    and form.titleLabel.text == "Tittel" and form.dateLabel.text == "Dato (DD.MM.ÅÅÅÅ)" and form.save.label.text == "Lag event" and form.timeBox:GetText() == "20:00")
-- The fields must hold a whole date and time (the game lets in one character
-- less than SetMaxBytes says, which once cut "20.11.2026" to "20.11.202").
check("the date starts on today's date, and both fields hold a full date and time", form.dateBox:GetText() == "20.11.2026" and form.timeBox:GetText() == "20:00",
    form.dateBox:GetText() .. " / " .. form.timeBox:GetText())
form.dateBox:TypeText("31.12.2026xx")
form.timeBox:TypeText("23:59xx")
check("typing stops at exactly a full date and a full time", form.dateBox:GetText() == "31.12.2026" and form.timeBox:GetText() == "23:59")
form.titleBox:SetText(string.rep("a", 80))
form.noteBox:SetText(string.rep("b", 200))
check("title and description take exactly what fits in a message", #form.titleBox:GetText() == 60 and #form.noteBox:GetText() == 100,
    #form.titleBox:GetText() .. " / " .. #form.noteBox:GetText())
form.titleBox:SetText("")
form.noteBox:SetText("")
form.dateBox:SetText("20.11.2026")
form.timeBox:SetText("20:00")

-- The calendar button opens a month overview to click a day in.
check("there is a calendar button next to the date field",
    form.calendarButton ~= nil and form.calendarButton.normalTexture == "Interface\\AddOns\\Dragonworld\\Media\\calendar" and select(2, form.calendarButton:GetPoint(1)) == form.dateBox)
form.calendarButton.scripts.OnEnter(form.calendarButton)
check("hovering it says what it does", GameTooltip:IsShown() and GameTooltip.lines[1] == "Velg dato")
form.calendarButton.scripts.OnLeave(form.calendarButton)
form.calendarButton.scripts.OnClick(form.calendarButton)
local picker
for _, child in ipairs(evPanel.children) do
    if child.days then picker = child end
end
local function pickerDay(day)
    for _, button in ipairs(picker.days) do
        if button:IsShown() and button.day == day then return button end
    end
end
check("clicking it opens the month that is in the date field", picker ~= nil and picker:IsVisible() and picker.title.text == "November 2026"
    and picker.weekdays[1].text == "Ma" and picker.weekdays[7].text == "Sø" and picker.strata == "DIALOG")
check("days sit under the right weekday: 1 November 2026 is a Sunday",
    not picker.days[6]:IsShown() and picker.days[7].label.text == "1" and picker.days[36].label.text == "30" and not picker.days[37]:IsShown())
check("the day in the date field is marked; days that have passed are greyed out and cannot be clicked",
    pickerDay(20).selected and pickerDay(20):IsEnabled() and not pickerDay(20).dimmed and not pickerDay(19):IsEnabled() and pickerDay(19).dimmed and not pickerDay(19).selected)
pickerDay(25).scripts.OnClick(pickerDay(25))
check("clicking a day writes it into the date field and closes the overview", form.dateBox:GetText() == "25.11.2026" and not picker:IsShown())
form.calendarButton.scripts.OnClick(form.calendarButton)
check("opening it again marks the day that was picked", picker:IsVisible() and pickerDay(25).selected and not pickerDay(20).selected)
picker.next.scripts.OnClick(picker.next)
check("the arrow moves to the next month: 1 December 2026 is a Tuesday",
    picker.title.text == "Desember 2026" and not picker.days[1]:IsShown() and picker.days[2].label.text == "1" and picker.days[32].label.text == "31" and not picker.days[33]:IsShown())
picker.next.scripts.OnClick(picker.next)
check("...and on into the next year: 1 January 2027 is a Friday", picker.title.text == "Januar 2027" and picker.days[5].label.text == "1" and not picker.days[4]:IsShown())
for _ = 1, 13 do picker.next.scripts.OnClick(picker.next) end
check("a leap year has 29 days in February: 1 February 2028 is a Tuesday",
    picker.title.text == "Februar 2028" and picker.days[2].label.text == "1" and picker.days[30].label.text == "29" and not picker.days[31]:IsShown(), picker.title.text)
for _ = 1, 15 do picker.previous.scripts.OnClick(picker.previous) end
check("the other arrow goes back, across the year too", picker.title.text == "November 2026" and pickerDay(25).selected)
picker.previous.scripts.OnClick(picker.previous)
do
    local anyOpen = false
    for _, button in ipairs(picker.days) do
        if button:IsShown() and button:IsEnabled() then anyOpen = true end
    end
    check("a month that has passed has no day to pick", picker.title.text == "Oktober 2026" and not anyOpen)
end
picker.next.scripts.OnClick(picker.next)
ns.SetLanguage("en", true)
check("the overview follows the language", picker.title.text == "November 2026" and picker.weekdays[1].text == "Mo" and picker.weekdays[3].text == "We")
ns.SetLanguage("nl", true)
check("...in Dutch too", picker.weekdays[2].text == "Di" and picker.weekdays[6].text == "Za")
ns.SetLanguage("nb", true)
form.calendarButton.scripts.OnClick(form.calendarButton)
check("clicking the calendar button again closes the overview", not picker:IsShown())
form.calendarButton.scripts.OnClick(form.calendarButton)
form.cancel.scripts.OnClick(form.cancel)
check("Cancel closes the overview along with the form", not picker:IsShown() and not form:IsShown())
gv.newButton.scripts.OnClick(gv.newButton)
form.calendarButton.scripts.OnClick(form.calendarButton)
evPanel.tabs.calendar.scripts.OnClick(evPanel.tabs.calendar)
check("so does switching to the game's calendar", not picker:IsShown())
evPanel.tabs.guild.scripts.OnClick(evPanel.tabs.guild)
gv.newButton.scripts.OnClick(gv.newButton)
calendar.opened = 0                       -- the tab visit above asked the game for its calendar
calendar.selected = { month = 11, year = 2004 }

form.dateBox:SetText("22.11.2026")
form.save.scripts.OnClick(form.save)
check("an event needs a title", form.error.text == "Gi eventen en tittel." and next(evDB().events) == nil)
form.titleBox:SetText("Raid: Molten Core")
form.dateBox:SetText("32.13.2026")
form.save.scripts.OnClick(form.save)
check("a date that makes no sense is refused", form.error.text == ns.strings.nb.EV_ERR_WHEN and next(evDB().events) == nil)
form.dateBox:SetText("01.01.2020")
form.save.scripts.OnClick(form.save)
check("a time in the past is refused", form.error.text == "Det tidspunktet har allerede vært." and next(evDB().events) == nil)
-- The fields forgive the common ways of writing a date and a time. A date in
-- the past is used so that "understood" shows up as the past-date message.
do
    local understood, refused = {}, {}
    for _, pair in ipairs({ { "01.01.20", "20:00" }, { "1.1.2020", "20" }, { "01/01/2020", "2000" }, { "01-01-2020", "20.30" }, { "1.1.2020 ", " 9:05" } }) do
        form.dateBox:SetText(pair[1])
        form.timeBox:SetText(pair[2])
        form.save.scripts.OnClick(form.save)
        if form.error.text ~= "Det tidspunktet har allerede vært." then understood[#understood + 1] = pair[1] .. " " .. pair[2] end
    end
    for _, pair in ipairs({ { "20.11.203", "20:00" }, { "31.11.2026", "20:00" }, { "29.02.2027", "20:00" }, { "22.11.2026", "25:00" }, { "22.11.2026", "20:0" }, { "22.11.2026", "" }, { "", "20:00" } }) do
        form.dateBox:SetText(pair[1])
        form.timeBox:SetText(pair[2])
        form.save.scripts.OnClick(form.save)
        if form.error.text ~= ns.strings.nb.EV_ERR_WHEN then refused[#refused + 1] = pair[1] .. " " .. pair[2] end
    end
    check("dates and times written in the usual ways are understood", #understood == 0, table.concat(understood, " ; "))
    check("dates and times that do not exist are refused with an explanation", #refused == 0 and next(evDB().events) == nil, table.concat(refused, " ; "))
end
form.cancel.scripts.OnClick(form.cancel)
check("Cancel closes the form without making anything", not form:IsShown() and next(evDB().events) == nil and #sentNow() == 0)

gv.newButton.scripts.OnClick(gv.newButton)
form.dateBox:SetText("22.11.2026")
form.timeBox:SetText("20:00")
form.noteBox:SetText("Ta med fire resist | og\tpotions")
form.save.scripts.OnClick(form.save)
local raidWhen = time({ year = 2026, month = 11, day = 22, hour = 20, min = 0 })
local raidID = "Tester-Stormrage:" .. NOW .. ":1"
local raid = evDB().events[raidID]
check("the event is stored with who made it and when it starts",
    raid ~= nil and raid.title == "Raid: Molten Core" and raid.creator == "Tester-Stormrage" and raid.when == raidWhen and raid.updated == NOW and next(raid.signups) == nil)
check("characters the game treats specially are taken out of the text", raid ~= nil and not raid.note:find("|", 1, true) and not raid.note:find("\t", 1, true) and raid.note:find("fire resist", 1, true) ~= nil, raid and raid.note)
do
    local sent = sentNow()
    check("it is sent to the guild as one message, saying it is for everyone and goes in the calendar",
        #sent == 1 and sent[1] == table.concat({ "E", raidID, NOW, raidWhen, "0", "Raid: Molten Core", raid.note, "1:A" }, TAB), sent[1])
end
check("being for everyone, it went into the game's calendar as a guild event in the same click",
    raid.aud == nil and raid.cal == true and #calendar.created == 1 and calendar.created[1].kind == "GUILD" and calendar.created[1].title == "Raid: Molten Core"
    and calendar.created[1].month == 11 and calendar.created[1].day == 22 and calendar.created[1].year == 2026
    and calendar.created[1].hour == 20 and calendar.created[1].minute == 0 and calendar.created[1].description == raid.note
    and has("Lagt i spillets kalender som guild-event."), chatText())
check("the form closes and the new event is shown, selected",
    not form:IsShown() and detail:IsVisible() and #eventRows() == 1 and eventRows()[1].label.text == "Raid: Molten Core" and eventRows()[1].selected
    and eventRows()[1].sub.text == "DATE(" .. raidWhen .. ")   0 / 0 / 0", eventRows()[1] and eventRows()[1].sub.text)
check("details: title, time, who made it, and the three answers",
    detail.title.text == "Raid: Molten Core" and detail.when.text == "DATE(" .. raidWhen .. ") - laget av Tester" and detail.note.text == raid.note
    and detail.chips.Y.label.text == "Kommer (0)" and detail.chips.M.label.text == "Kanskje (0)" and detail.chips.N.label.text == "Kommer ikke (0)"
    and detail.lists.Y.text == "Kommer: -", detail.when.text)
check("the maker can delete it; anyone can post it in guild chat", detail.delete:IsShown() and detail.delete.label.text == "Slett" and detail.share:IsShown() and detail.share.label.text == "Del i guild-chat")

-- Signing up.
detail.chips.Y.scripts.OnClick(detail.chips.Y)
check("one click signs you up", raid.signups["Tester-Stormrage"].status == "Y" and raid.signups["Tester-Stormrage"].class == "PALADIN"
    and detail.chips.Y.selected and detail.chips.Y.label.text == "Kommer (1)" and detail.lists.Y.text == "Kommer: Tester")
check("the list shows your answer", eventRows()[1].sub.text == "DATE(" .. raidWhen .. ")   1 / 0 / 0   Kommer", eventRows()[1].sub.text)
do
    local sent = sentNow()
    check("the sign-up is sent to the guild", #sent == 1 and sent[1] == table.concat({ "S", raidID, "Tester-Stormrage,Y," .. NOW .. ",PALADIN" }, TAB), sent[1])
end
detail.chips.M.scripts.OnClick(detail.chips.M)
check("changing your answer replaces it, with a newer timestamp even in the same second",
    raid.signups["Tester-Stormrage"].status == "M" and raid.signups["Tester-Stormrage"].updated == NOW + 1
    and detail.chips.M.selected and not detail.chips.Y.selected and detail.chips.Y.label.text == "Kommer (0)")
sentNow()

-- Things arriving from other members.
local dungeonWhen = time({ year = 2026, month = 11, day = 21, hour = 18, min = 0 })
local dungeonID = "Altine-Stormrage:" .. (NOW - 100) .. ":1"
receive(table.concat({ "E", dungeonID, NOW - 100, dungeonWhen, "0", "Dungeon run", "Scholomance" }, TAB))
check("an event made by someone else appears, soonest first",
    #eventRows() == 2 and eventRows()[1].label.text == "Dungeon run" and eventRows()[2].label.text == "Raid: Molten Core" and evDB().events[dungeonID].creator == "Altine-Stormrage")
check("...without changing which event you are looking at", detail.title.text == "Raid: Molten Core" and eventRows()[2].selected and not eventRows()[1].selected)
receive(table.concat({ "S", raidID, "Altine-Stormrage,Y," .. (NOW + 5) .. ",MAGE", "Borin-Stormrage,N," .. (NOW + 6) .. ",WARRIOR" }, TAB))
check("other members' answers are counted and listed by name",
    detail.chips.Y.label.text == "Kommer (1)" and detail.chips.M.label.text == "Kanskje (1)" and detail.chips.N.label.text == "Kommer ikke (1)"
    and detail.lists.Y.text == "Kommer: Altine" and detail.lists.M.text == "Kanskje: Tester" and detail.lists.N.text == "Kommer ikke: Borin", detail.lists.N.text)
eventRows()[1].scripts.OnClick(eventRows()[1])
check("clicking an event in the list shows it", detail.title.text == "Dungeon run" and eventRows()[1].selected and detail.when.text:find("laget av Altine", 1, true) ~= nil)
check("you cannot delete someone else's event", not detail.delete:IsShown() and detail.share:IsShown())
eventRows()[2].scripts.OnClick(eventRows()[2])

receive(table.concat({ "E", raidID, NOW + 500, raidWhen, "1", "X", "Y" }, TAB), "Tester-Stormrage")
check("your own messages echoed back are ignored", raid.title == "Raid: Molten Core" and not raid.deleted)
receive(table.concat({ "E", raidID, NOW + 500, raidWhen, "1", "X", "Y" }, TAB), "Altine-Stormrage", "PARTY")
receive(table.concat({ "E", raidID, NOW + 500, raidWhen, "1", "X", "Y" }, TAB), "Altine-Stormrage", "GUILD", "SomeOtherAddon")
check("messages on another channel or from another addon are ignored", raid.title == "Raid: Molten Core" and not raid.deleted)
receive(table.concat({ "E", dungeonID, NOW - 200, dungeonWhen, "0", "Old title", "old" }, TAB))
check("an older version does not overwrite a newer one", evDB().events[dungeonID].title == "Dungeon run")
receive(table.concat({ "E", dungeonID, NOW - 50, dungeonWhen, "0", "Dungeon run tonight", "Scholo | Strat" }, TAB))
check("a newer version does, and its text is cleaned too", evDB().events[dungeonID].title == "Dungeon run tonight" and not evDB().events[dungeonID].note:find("|", 1, true) and eventRows()[1].label.text == "Dungeon run tonight")
receive(table.concat({ "E", dungeonID, NOW + 3 * 86400, dungeonWhen, "1", "Hacked", "x" }, TAB))
check("a timestamp far in the future is refused, so nobody can freeze an event", evDB().events[dungeonID].title == "Dungeon run tonight" and not evDB().events[dungeonID].deleted)
receive(table.concat({ "E", "Altine-Stormrage:5:9", NOW, NOW - 8 * 86400, "0", "Ancient", "" }, TAB))
check("an event that ended long ago is not taken in", evDB().events["Altine-Stormrage:5:9"] == nil)
receive(table.concat({ "S", raidID, "Borin-Stormrage,Y," .. (NOW + 2) .. ",WARRIOR" }, TAB))
check("an older answer does not overwrite a newer one", raid.signups["Borin-Stormrage"].status == "N")
receive(table.concat({ "S", raidID, "Borin-Stormrage,X," .. (NOW + 20) .. ",WARRIOR" }, TAB))
check("an answer that is not one of the three is ignored", raid.signups["Borin-Stormrage"].status == "N")

clearChat()
for _, junk in ipairs({ "", "E", "E\t\t\t", "S", "S\t", "S\t" .. raidID .. "\tgarbage", "H\tgarbage", "H", "G", "Z\tunknown", "E\tx\ty\tz\t0\ta\tb", "E\tno-id-shape\t5\t" .. raidWhen .. "\t0\ta\tb" }) do
    receive(junk)
end
check("broken messages are ignored without errors", chatText() == "" and raid.title == "Raid: Molten Core" and evDB().events["no-id-shape"] == nil, chatText())

receive(table.concat({ "E", dungeonID, NOW + 50, dungeonWhen, "1", "Dungeon run tonight", "" }, TAB))
check("a deleted event disappears from the list but is remembered as deleted", #eventRows() == 1 and eventRows()[1].label.text == "Raid: Molten Core" and evDB().events[dungeonID].deleted == true)

flush()
sentNow()
receive(table.concat({ "S", "Borin-Stormrage:77:1", "Borin-Stormrage,Y," .. NOW .. ",WARRIOR" }, TAB), "Borin-Stormrage")
check("an answer to an event we have never heard of is kept, but nothing is shown yet", #eventRows() == 1 and evDB().events["Borin-Stormrage:77:1"].stub == true)
flush()
do
    local sent = sentNow()
    check("...and the event itself is asked for", #sent == 1 and sent[1] == "G" .. TAB .. "Borin-Stormrage:77:1", table.concat(sent, " ; "))
end
receive(table.concat({ "E", "Borin-Stormrage:77:1", NOW, raidWhen + 3600, "0", "After-raid drinks", "" }, TAB), "Borin-Stormrage")
check("when it arrives, the answer that came first is still there",
    #eventRows() == 2 and eventRows()[2].label.text == "After-raid drinks" and eventRows()[2].sub.text:find("1 / 0 / 0", 1, true) ~= nil, eventRows()[2] and eventRows()[2].sub.text)
local drinksID = "Borin-Stormrage:77:1"

-- Someone logs in who has nothing: they get everything we have.
flush()
sentNow()
receive("Q", "Nykommer-Stormrage")
check("nothing is sent the same instant; replies are spread out", #sentNow() == 0 and queued(2.5) == 1, queued(2.5))
flush()
local fullSync = sentNow()
check("a member with nothing gets every event, including the deleted one, so the deletion spreads",
    count(fullSync, "^E\t") == 3 and count(fullSync, "^E\t" .. raidID:gsub("%-", "%%-") .. "\t") == 1
    and count(fullSync, "^E\t" .. dungeonID:gsub("%-", "%%-") .. "\t%d+\t%d+\t1\t") == 1, table.concat(fullSync, " ; "))
check("...and every answer", count(fullSync, "^S\t") >= 2 and count(fullSync, "Altine%-Stormrage,Y") == 1 and count(fullSync, "Borin%-Stormrage,N") == 1 and count(fullSync, "Tester%-Stormrage,M") == 1)

-- Round trip: a client that starts empty and receives exactly those messages ends up with the same data.
do
    local original = evDB().events
    evDB().events = {}
    for _, message in ipairs(fullSync) do receive(message, "Altine-Stormrage") end
    local copy = evDB().events
    local same = true
    for id, event in pairs(original) do
        local other = copy[id]
        if not other or other.title ~= event.title or other.note ~= event.note or other.when ~= event.when or other.updated ~= event.updated
            or (other.deleted or false) ~= (event.deleted or false) or other.creator ~= event.creator then
            same = false
        else
            for player, signup in pairs(event.signups) do
                local s = other.signups[player]
                if not s or s.status ~= signup.status or s.updated ~= signup.updated or s.class ~= signup.class then same = false end
            end
        end
    end
    check("what is sent is enough to rebuild everything on another client", same)
    evDB().events = original
    flush()
    sentNow()
    eventRows()[1].scripts.OnClick(eventRows()[1])        -- look at the raid again
    check("the raid is the selected event again", detail.title.text == "Raid: Molten Core")
end

-- If someone else answers first, we stay quiet.
receive("Q", "Nykommer-Stormrage")
for _, message in ipairs(fullSync) do receive(message, "Altine-Stormrage") end
flush()
check("when another member already sent it all, we send nothing", #sentNow() == 0)

-- A member who lists what they have only gets the differences.
local function helloEntry(id, eventUpdated, signupCount, newestSignup) return table.concat({ id, eventUpdated, signupCount, newestSignup }, ",") end
local dungeonUpdated, drinksUpdated = evDB().events[dungeonID].updated, evDB().events[drinksID].updated
receive(table.concat({ "H", helloEntry(raidID, raid.updated, 3, NOW + 6), helloEntry(dungeonID, dungeonUpdated, 0, 0), helloEntry(drinksID, drinksUpdated, 1, NOW) }, TAB), "Borin-Stormrage")
receive("Q", "Borin-Stormrage")
flush()
check("a member who already has the same gets nothing", #sentNow() == 0)

receive(table.concat({ "H", helloEntry(raidID, raid.updated - 10, 3, NOW + 6), helloEntry(dungeonID, dungeonUpdated, 0, 0), helloEntry(drinksID, drinksUpdated, 1, NOW) }, TAB), "Borin-Stormrage")
receive("Q", "Borin-Stormrage")
flush()
do
    local sent = sentNow()
    check("a member with an older version of an event gets just that event", #sent == 1 and sent[1]:find("^E\tTester%-Stormrage") ~= nil, table.concat(sent, " ; "))
end
receive(table.concat({ "H", helloEntry(raidID, raid.updated, 2, NOW + 5), helloEntry(dungeonID, dungeonUpdated, 0, 0), helloEntry(drinksID, drinksUpdated, 1, NOW) }, TAB), "Borin-Stormrage")
receive("Q", "Borin-Stormrage")
flush()
do
    local sent = sentNow()
    check("a member missing answers gets the answers, not the event again", count(sent, "^S\t") >= 1 and count(sent, "^E\t") == 0, table.concat(sent, " ; "))
end
receive(table.concat({ "H", helloEntry(raidID, raid.updated + 30, 5, NOW + 90), helloEntry(dungeonID, dungeonUpdated, 0, 0), helloEntry(drinksID, drinksUpdated, 1, NOW),
    helloEntry("Borin-Stormrage:99:4", NOW, 0, 0) }, TAB), "Borin-Stormrage")
receive("Q", "Borin-Stormrage")
flush()
do
    local sent = sentNow()
    check("when they have something newer, or something we lack, we ask for it instead",
        #sent == 1 and sent[1] == table.concat({ "G", "Borin-Stormrage:99:4", raidID }, TAB), table.concat(sent, " ; "))
end
receive("G" .. TAB .. drinksID, "Nykommer-Stormrage")
flush()
do
    local sent = sentNow()
    check("being asked for one event sends that event and its answers", count(sent, "^E\tBorin%-Stormrage:77:1\t") == 1 and count(sent, "^S\tBorin%-Stormrage:77:1\t") == 1 and #sent == 2, table.concat(sent, " ; "))
end

-- The game allows about one message a second. A burst is queued, not dropped.
clock = clock + 100
for i = 1, 14 do
    detail.chips[(i % 2 == 0) and "Y" or "N"].scripts.OnClick(detail.chips[(i % 2 == 0) and "Y" or "N"])
end
check("a burst of 14 sends 10 at once and holds the rest", #wire == 10, #wire)
clock = clock + 2
flushNow()
check("two seconds later two more go out", #wire == 12, #wire)
clock = clock + 5
flushNow()
check("...and then the last ones", #wire == 14 and wire[14].message:find(",Y,", 1, true) ~= nil, #wire)
sentNow()

clock = clock + 100
sendResult = 3                            -- the game says: throttled
detail.chips.M.scripts.OnClick(detail.chips.M)
check("a message the game throttles is kept", #wire == 0)
sendResult = 0
clock = clock + 2
flushNow()
check("...and sent a little later", #wire == 1 and wire[1].message:find(",M,", 1, true) ~= nil)
sentNow()

chatLock = true
detail.chips.Y.scripts.OnClick(detail.chips.Y)
check("while the game has chat locked nothing is sent", #wire == 0 and queued(5) == 1)
chatLock = false
clock = clock + 6
flushNow()
check("...and it goes out once the lock is lifted", #wire == 1)
sentNow()

-- Posting an event in guild chat for those without the addon.
guildChat = {}
detail.share.scripts.OnClick(detail.share)
check("Post in guild chat writes the heading with the time, the description, and a line about the addon",
    #guildChat == 3 and guildChat[1].text == "Guild-event: Raid: Molten Core - DATE(" .. raidWhen .. ")" and guildChat[1].chatType == "GUILD"
    and guildChat[2].text == raid.note and guildChat[3].text == ns.strings.nb.EV_SHARE_ADDON and guildChat[3].chatType == "GUILD",
    guildChat[1] and guildChat[1].text)
detail.share.scripts.OnClick(detail.share)
check("a second click right away does not post it twice", #guildChat == 3)
clock = clock + 11
detail.share.scripts.OnClick(detail.share)
check("after a little while it can be posted again", #guildChat == 6)
guildChat = {}
eventRows()[2].scripts.OnClick(eventRows()[2])       -- the event without a description
detail.share.scripts.OnClick(detail.share)
check("an event without a description posts two lines", #guildChat == 2 and guildChat[1].text:find("After-raid drinks", 1, true) ~= nil)
guildChat = {}
clock = clock + 11
chatLock = true
clearChat()
detail.share.scripts.OnClick(detail.share)
check("if the game has chat locked, nothing is posted and the player is told", #guildChat == 0 and has("tillater ikke chatmeldinger"), chatText())
chatLock = false
clearChat()
eventRows()[1].scripts.OnClick(eventRows()[1])
check("no addon messages were sent by posting in chat", #sentNow() == 0)

-- Events drop off the list 12 hours after they start.
do
    local realWhen = raid.when
    raid.when = NOW - 13 * 3600
    evChip.scripts.OnClick(evChip)
    rsChip.scripts.OnClick(rsChip)
    evChip.scripts.OnClick(evChip)
    check("an event that started more than 12 hours ago is no longer listed", #eventRows() == 1 and eventRows()[1].label.text == "After-raid drinks")
    raid.when = realWhen
    rsChip.scripts.OnClick(rsChip)
    evChip.scripts.OnClick(evChip)
    eventRows()[1].scripts.OnClick(eventRows()[1])
end

-- The game's own calendar.
calendar.events["2026-11-19"] = { { title = "Yesterday", calendarType = "GUILD_EVENT", sequenceType = "", startTime = { hour = 20, minute = 0 } } }
calendar.events["2026-11-21"] = { { title = "Molten Core", calendarType = "RAID_LOCKOUT", sequenceType = "", startTime = { hour = 8, minute = 0 } } }
calendar.events["2026-11-22"] = { { title = "Raid night", calendarType = "GUILD_EVENT", sequenceType = "", startTime = { hour = 20, minute = 0 } } }
calendar.events["2026-11-25"] = { { title = "Winter Veil", calendarType = "HOLIDAY", sequenceType = "START", startTime = { hour = 0, minute = 0 } } }
calendar.events["2026-11-26"] = { { title = "Winter Veil", calendarType = "HOLIDAY", sequenceType = "ONGOING", startTime = { hour = 0, minute = 0 } } }
calendar.events["2026-12-3"] = { { title = "My | dentist", calendarType = "PLAYER", sequenceType = "", startTime = { hour = 9, minute = 30 } } }
evPanel.tabs.calendar.scripts.OnClick(evPanel.tabs.calendar)
local function calendarDescribe()
    local parts = {}
    for _, row in ipairs(DragonworldCalendarScroll.scrollChild.children) do
        if row:IsShown() then parts[#parts + 1] = row.when.text .. " " .. row.title.text .. " [" .. row.kind.text .. "]" end
    end
    return table.concat(parts, " | ")
end
check("the calendar tab asks the game for the calendar and points it at this month",
    evPanel.calendar:IsVisible() and not gv:IsVisible() and evPanel.tabs.calendar.selected and calendar.opened == 1 and calendar.selected.month == 11 and calendar.selected.year == 2026)
check("it lists what is coming from today through next month, without raid lockouts or repeated holiday days",
    calendarDescribe() == "22.11 20:00 Raid night [Guild] | 25.11 00:00 Winter Veil [Høytid] | 03.12 09:30 My   dentist [Personlig]", calendarDescribe())
calendar.events["2026-11-23"] = { { title = "Officer meeting", calendarType = "GUILD_ANNOUNCEMENT", sequenceType = "", startTime = { hour = 19, minute = 0 } } }
fire("CALENDAR_UPDATE_EVENT_LIST")
check("it refreshes when the game delivers calendar data", calendarDescribe():find("23.11 19:00 Officer meeting [Guild]", 1, true) ~= nil, calendarDescribe())
do
    local savedEvents = calendar.events
    calendar.events = {}
    fire("CALENDAR_UPDATE_EVENT_LIST")
    check("an empty calendar is explained", calendarDescribe() == "" and evPanel.calendar.empty:IsShown() and evPanel.calendar.empty.text == ns.strings.nb.EV_CAL_EMPTY)
    calendar.events = savedEvents
    local savedCalendar = C_Calendar
    C_Calendar = nil
    fire("CALENDAR_UPDATE_EVENT_LIST")
    check("a client without the calendar is explained too", calendarDescribe() == "" and evPanel.calendar.empty.text == ns.strings.nb.EV_CAL_MISSING)
    C_Calendar = savedCalendar
end
evPanel.tabs.guild.scripts.OnClick(evPanel.tabs.guild)
check("back to our own events", gv:IsVisible() and not evPanel.calendar:IsVisible() and #eventRows() == 2)

ns.SetLanguage("en", true)
check("Guild-events follows the language",
    evPanel.tabs.guild.label.text == "Our events" and evPanel.tabs.calendar.label.text == "Game calendar" and detail.chips.Y.label.text:find("Coming", 1, true) ~= nil and evChip.label.text == "Guild Events")
ns.SetLanguage("nb", true)

-- Another character on the same account sees the same events and answers for itself.
character = { name = "Altine", realm = "Stormrage", class = "MAGE" }
rsChip.scripts.OnClick(rsChip)
evChip.scripts.OnClick(evChip)
check("another of your characters sees the events, but cannot delete what the first one made", detail.title.text == "Raid: Molten Core" and not detail.delete:IsShown())
character = { name = "Tester", realm = "Stormrage", class = "PALADIN" }
rsChip.scripts.OnClick(rsChip)
evChip.scripts.OnClick(evChip)

-- ---- Who an event is for: everyone, a level range, or chosen members ----
local function eventRow(title)
    for _, row in ipairs(eventRows()) do
        if row.label.text == title then return row end
    end
end
local function reopenEvents()             -- redraw the panel as the current character
    rsChip.scripts.OnClick(rsChip)
    evChip.scripts.OnClick(evChip)
end
local function tick(box, checked)
    box.checked = checked
    if box.scripts.OnClick then box.scripts.OnClick(box) end
end
eventRow("Raid: Molten Core").scripts.OnClick(eventRow("Raid: Molten Core"))
check("an event's details say who it is for", detail.audience.text == "For alle")

flush()
sentNow()
clearChat()
gv.newButton.scripts.OnClick(gv.newButton)
check("the form asks who the event is for; 'everyone' and 'in the game's calendar' are chosen to begin with",
    form.audienceLabel.text == "Hvem gjelder det?" and form.audienceChips.A.selected and form.audienceChips.A.label.text == "Alle"
    and form.audienceChips.L.label.text == "Etter level" and form.audienceChips.P.label.text == "Utvalgte"
    and not form.levelRow:IsShown() and not form.membersButton:IsShown()
    and form.calendarCheck.checked == true and form.calendarLabel.text == "Legg den også i spillets kalender")

-- By level.
form.audienceChips.L.scripts.OnClick(form.audienceChips.L)
check("choosing 'by level' shows a level range, 1 to 60 to begin with",
    form.audienceChips.L.selected and not form.audienceChips.A.selected and form.levelRow:IsVisible() and not form.membersButton:IsShown()
    and form.levelMin:GetText() == "1" and form.levelMax:GetText() == "60" and form.levelLabel.text == "Level fra" and form.levelTo.text == "til")
form.titleBox:SetText("Low level run")
form.dateBox:SetText("23.11.2026")
form.timeBox:SetText("19:00")
form.levelMin:SetText("x")
form.save.scripts.OnClick(form.save)
check("levels must be numbers", form.error.text == "Skriv level som tall, lavest først.")
form.levelMin:SetText("40")
form.levelMax:SetText("20")
form.save.scripts.OnClick(form.save)
check("...with the lowest first", form.error.text == "Skriv level som tall, lavest først." and #sentNow() == 0)
form.levelMin:SetText("20")
form.levelMax:SetText("40")
form.save.scripts.OnClick(form.save)
local lowID = "Tester-Stormrage:" .. NOW .. ":2"
local low = evDB().events[lowID]
check("the level range is stored with the event", low ~= nil and low.aud == "L" and low.min == 20 and low.max == 40 and low.cal == true)
do
    local sent = sentNow()
    check("...and sent with it", #sent == 1 and sent[1]:find("\t1:L20%-40$") ~= nil, sent[1])
end
check("for a level range it goes into the maker's own calendar, not as a guild event",
    #calendar.created == 2 and calendar.created[2].kind == "PLAYER" and calendar.created[2].title == "Low level run"
    and calendar.created[2].day == 23 and calendar.created[2].hour == 19 and has("Lagt i kalenderen din i spillet."), chatText())
check("the maker sees the event even when outside the range", detail.title.text == "Low level run" and detail.audience.text == "For level 20-40")
guildChat = {}
clock = clock + 11
detail.share.scripts.OnClick(detail.share)
check("posting it in guild chat says who it is for", guildChat[1] ~= nil and guildChat[1].text:find("(For level 20-40)", 1, true) ~= nil, guildChat[1] and guildChat[1].text)

character = { name = "Altine", realm = "Stormrage", class = "MAGE", level = 60, guid = "Player-1-Altine" }
reopenEvents()
check("a character outside the level range does not see the event", eventRow("Low level run") == nil and eventRow("Raid: Molten Core") ~= nil)
character.level = 30
reopenEvents()
check("a character inside the range does", eventRow("Low level run") ~= nil)
eventRow("Low level run").scripts.OnClick(eventRow("Low level run"))
clearChat()
detail.chips.Y.scripts.OnClick(detail.chips.Y)
check("answering 'coming' puts it in that character's own calendar in the game",
    #calendar.created == 3 and calendar.created[3].kind == "PLAYER" and calendar.created[3].title == "Low level run" and has("Lagt i kalenderen din i spillet."), chatText())
detail.chips.M.scripts.OnClick(detail.chips.M)
check("...only once, however often the answer changes", #calendar.created == 3)
character = { name = "Borin", realm = "Stormrage", class = "WARRIOR", level = 25, guid = "Player-1-Borin" }
reopenEvents()
eventRow("Low level run").scripts.OnClick(eventRow("Low level run"))
detail.chips.N.scripts.OnClick(detail.chips.N)
check("answering 'not coming' adds nothing to the calendar", #calendar.created == 3)
eventRow("Raid: Molten Core").scripts.OnClick(eventRow("Raid: Molten Core"))
detail.chips.Y.scripts.OnClick(detail.chips.Y)
check("an event for everyone is not added again when answering: it is already there as a guild event", #calendar.created == 3)
character = { name = "Tester", realm = "Stormrage", class = "PALADIN" }
reopenEvents()

-- Chosen members.
flush()
sentNow()
clearChat()
gv.newButton.scripts.OnClick(gv.newButton)
check("a new form starts over on 'everyone'", form.audienceChips.A.selected and form.titleBox:GetText() == "")
form.audienceChips.P.scripts.OnClick(form.audienceChips.P)
check("choosing 'chosen' shows a button for picking members", form.membersButton:IsVisible() and form.membersButton.label.text == "Velg medlemmer (0)" and not form.levelRow:IsShown())
form.titleBox:SetText("Officer meeting")
form.dateBox:SetText("24.11.2026")
form.timeBox:SetText("21:00")
tick(form.calendarCheck, false)
form.save.scripts.OnClick(form.save)
check("at least one member must be chosen", form.error.text == "Velg minst ett medlem." and #sentNow() == 0)

form.membersButton.scripts.OnClick(form.membersButton)
local members = gv.members
local function memberNames()
    local parts = {}
    for _, row in ipairs(DragonworldEventMembersScroll.scrollChild.children) do
        if row:IsShown() then parts[#parts + 1] = row.name.text .. (row.check.checked and "*" or "") end
    end
    return table.concat(parts, ",")
end
local function memberRow(name)
    for _, row in ipairs(DragonworldEventMembersScroll.scrollChild.children) do
        if row:IsShown() and row.name.text == name then return row end
    end
end
check("the member list opens in place of the form, with everyone in the guild A-Z",
    members:IsVisible() and not form:IsShown() and members.title.text == "Hvem gjelder eventen?" and members.searchLabel.text == "Søk:"
    and memberNames() == "Altine,Borin,Cedric,Dagny,Eira,Tester" and members.done.label.text == "Ferdig (0 valgt)", memberNames())
check("members are shown with level and class colour", memberRow("Borin").level.text == "42" and colour(memberRow("Altine").name.color, 0.25, 0.78, 0.92))
typeInto(members.searchBox, "DA")
check("the search box narrows the list", memberNames() == "Dagny", memberNames())
tick(memberRow("Dagny").check, true)
check("ticking a member counts them", members.done.label.text == "Ferdig (1 valgt)" and memberNames() == "Dagny*")
typeInto(members.searchBox, "")
check("ticks stay when the search changes", memberNames() == "Altine,Borin,Cedric,Dagny*,Eira,Tester", memberNames())
tick(memberRow("Altine").check, true)
tick(memberRow("Cedric").check, true)
tick(memberRow("Eira").check, true)
tick(memberRow("Eira").check, false)
check("ticks can be taken away again", members.done.label.text == "Ferdig (3 valgt)" and memberNames() == "Altine*,Borin,Cedric*,Dagny*,Eira,Tester", memberNames())
members.done.scripts.OnClick(members.done)
check("Done returns to the form, which shows how many are chosen", form:IsVisible() and not members:IsShown() and form.membersButton.label.text == "Velg medlemmer (3)")
local createdBefore = #calendar.created
form.save.scripts.OnClick(form.save)
local pickID = "Tester-Stormrage:" .. NOW .. ":3"
local pick = evDB().events[pickID]
check("the chosen members are stored with the event, by their fixed id (or name where the game gives no id)",
    pick ~= nil and pick.aud == "P" and pick.invitedCount == 3 and pick.invited["Player-1-Altine"] and pick.invited["Player-1-Dagny"] and pick.invited["name:cedric"]
    and not pick.invited["Player-1-Eira"] and pick.cal == nil)
do
    local sent = sentNow()
    check("it is sent as the event followed by the list of who it is for",
        #sent == 2 and sent[1]:find("\t0:P3$") ~= nil and sent[2] == table.concat({ "I", pickID, NOW, "Player-1-Altine;Player-1-Dagny;name:cedric" }, TAB), table.concat(sent, " ; "))
end
check("with the calendar box unticked nothing goes into the game's calendar", #calendar.created == createdBefore)
check("the details say how many it is for", detail.title.text == "Officer meeting" and detail.audience.text == "For 3 utvalgte")

character = { name = "Altine", realm = "Stormrage", class = "MAGE", guid = "Player-1-Altine" }
reopenEvents()
check("a chosen member sees the event", eventRow("Officer meeting") ~= nil)
character = { name = "Borin", realm = "Stormrage", class = "WARRIOR", guid = "Player-1-Borin" }
reopenEvents()
check("a member who was not chosen does not", eventRow("Officer meeting") == nil)
character = { name = "Cedric", realm = "Stormrage", class = "ROGUE", guid = "Player-9-Unknown" }
reopenEvents()
check("a member chosen by name (no id in the roster) sees it too", eventRow("Officer meeting") ~= nil)
character = { name = "Tester", realm = "Stormrage", class = "PALADIN" }
reopenEvents()

-- The same, arriving from another member.
flush()
sentNow()
local secretID = "Altine-Stormrage:" .. (NOW - 5) .. ":7"
receive(table.concat({ "E", secretID, NOW - 5, raidWhen + 7200, "0", "Secret plan", "", "1:P2" }, TAB))
check("an event for chosen members is not shown until we know we are one of them", eventRow("Secret plan") == nil and evDB().events[secretID].aud == "P")
receive(table.concat({ "I", secretID, NOW - 99, "Player-1-Tester" }, TAB))
check("a list that belongs to another version of the event is ignored", eventRow("Secret plan") == nil)
receive(table.concat({ "I", secretID, NOW - 5, "Player-1-Borin;Player-1-Tester" }, TAB))
check("once the list arrives and we are on it, the event appears", eventRow("Secret plan") ~= nil and evDB().events[secretID].invited["Player-1-Borin"] == true)
eventRow("Secret plan").scripts.OnClick(eventRow("Secret plan"))
clearChat()
detail.chips.Y.scripts.OnClick(detail.chips.Y)
check("answering it puts it in our own calendar", #calendar.created == createdBefore + 1 and calendar.created[#calendar.created].title == "Secret plan" and has("Lagt i kalenderen din i spillet."))
flush()
check("a complete list is not asked for again", count(sentNow(), "^G\t") == 0)

local partID = "Altine-Stormrage:" .. (NOW - 4) .. ":8"
receive(table.concat({ "E", partID, NOW - 4, raidWhen + 9000, "0", "Half told", "", "0:P3" }, TAB))
receive(table.concat({ "I", partID, NOW - 4, "Player-1-Borin" }, TAB))
flush()
flush()
do
    local sent = sentNow()
    check("if part of the list never arrives, the event is asked for again", count(sent, "^G\t" .. partID:gsub("%-", "%%-")) == 1, table.concat(sent, " ; "))
end

receive("G" .. TAB .. pickID, "Nykommer-Stormrage")
flush()
do
    local sent = sentNow()
    check("an event for chosen members is passed on together with its list", count(sent, "^E\t") == 1 and count(sent, "^I\t") == 1 and sent[1]:find("0:P3", 1, true) ~= nil, table.concat(sent, " ; "))
end

receive(table.concat({ "E", "Altine-Stormrage:" .. (NOW - 3) .. ":9", NOW - 3, raidWhen + 9900, "0", "Old style", "from an older version" }, TAB))
check("an event from an older version, with nothing about who it is for, is for everyone", eventRow("Old style") ~= nil and evDB().events["Altine-Stormrage:" .. (NOW - 3) .. ":9"].aud == nil)

-- A maker whose guild rank may not make guild events in the game's calendar.
flush()
sentNow()
clearChat()
guild.cannotMakeEvents = true
gv.newButton.scripts.OnClick(gv.newButton)
check("the calendar box is ticked again for each new event", form.calendarCheck.checked == true)
form.titleBox:SetText("Fishing trip")
form.dateBox:SetText("25.11.2026")
form.timeBox:SetText("18:00")
do
    local before = #calendar.created
    form.save.scripts.OnClick(form.save)
    local fish = evDB().events["Tester-Stormrage:" .. NOW .. ":4"]
    check("without the right to make guild events, an event for everyone goes into the maker's own calendar instead",
        fish ~= nil and fish.aud == nil and fish.own == true and #calendar.created == before + 1 and calendar.created[before + 1].kind == "PLAYER"
        and has("Lagt i kalenderen din i spillet."), chatText())
    local sent = sentNow()
    check("...and the others are told to add it to theirs", #sent == 1 and sent[1]:find("\t2:A$") ~= nil, sent[1])
end
guild.cannotMakeEvents = nil

do
    local ownID = "Altine-Stormrage:" .. (NOW - 2) .. ":10"
    receive(table.concat({ "E", ownID, NOW - 2, raidWhen + 3600, "0", "Own calendars", "", "2:A" }, TAB))
    eventRow("Own calendars").scripts.OnClick(eventRow("Own calendars"))
    local before = #calendar.created
    detail.chips.M.scripts.OnClick(detail.chips.M)
    check("such an event from another member goes into our own calendar when we answer",
        evDB().events[ownID].own == true and #calendar.created == before + 1 and calendar.created[before + 1].kind == "PLAYER" and calendar.created[before + 1].title == "Own calendars")
end

-- The game refusing an event after taking it.
flush()
sentNow()
gv.newButton.scripts.OnClick(gv.newButton)
form.titleBox:SetText("Refused")
form.dateBox:SetText("26.11.2026")
form.timeBox:SetText("18:00")
form.save.scripts.OnClick(form.save)
do
    local before = #calendar.created
    clearChat()
    fire("CALENDAR_UPDATE_ERROR", "Du har for mange events.")
    check("if the game refuses the event, that is said, with the game's reason", has("Fikk ikke lagt den i spillets kalender. (Du har for mange events.)"), chatText())
    detail.chips.Y.scripts.OnClick(detail.chips.Y)
    check("...and answering 'coming' on your own event tries once more",
        detail.title.text == "Refused" and #calendar.created == before + 1 and calendar.created[before + 1].kind == "GUILD" and calendar.created[before + 1].title == "Refused")
    clock = clock + 10
    clearChat()
    fire("CALENDAR_UPDATE_ERROR", "Noe helt annet.")
    check("a calendar error long afterwards is not about our event and is left alone", not has("Fikk ikke"), chatText())
    detail.chips.M.scripts.OnClick(detail.chips.M)
    check("an event already in the calendar is not added twice", #calendar.created == before + 1)
    clearChat()
    dw("debug")
    check("/dw debug tells whether the calendar can be used", has("lov til guild-events: true"), chatText())
end

-- Tidy up so the remaining tests see the two events they expect.
for id in pairs(evDB().events) do
    if id ~= raidID and id ~= drinksID and id ~= dungeonID then evDB().events[id] = nil end
end
raid.signups["Borin-Stormrage"] = { status = "N", updated = NOW + 6, class = "WARRIOR" }
reopenEvents()
eventRow("Raid: Molten Core").scripts.OnClick(eventRow("Raid: Molten Core"))
check("back to the two events from before", #eventRows() == 2 and detail.title.text == "Raid: Molten Core")

-- Deleting your own event.
flush()
sentNow()
local updatedBefore = raid.updated
detail.delete.scripts.OnClick(detail.delete)
do
    local sent = sentNow()
    check("deleting your own event removes it and tells the guild",
        raid.deleted == true and raid.updated > updatedBefore and #sent == 1 and sent[1]:find("^E\tTester%-Stormrage:%d+:1\t%d+\t%d+\t1\t") ~= nil
        and #eventRows() == 1 and detail.title.text == "After-raid drinks", sent[1])
end
flush()
sentNow()
clearChat()
kbChip.scripts.OnClick(kbChip)

-- ================================== Medlemmer ===================================
local RO_PREFIX = "DragonworldPr"
local function roDB() return DragonworldDB.modules.roster end
local function roReceive(text, sender) fire("CHAT_MSG_ADDON", RO_PREFIX, text, "GUILD", sender) end

check("at login the addon tells the guild this character's professions, and asks the others for theirs",
    prefixes[RO_PREFIX] == true and #rosterLogin == 2 and rosterLogin[1] == "P\tPlayer-1-Tester\tCooking:150:225;Engineering:210:225;Mining:225:300" and rosterLogin[2] == "R",
    table.concat(rosterLogin, " ; "))
check("...and remembers its own", roDB().professions["Player-1-Tester"] ~= nil and roDB().professions["Player-1-Tester"].list[3].name == "Mining"
    and roDB().professions["Player-1-Tester"].list[3].level == 225)

roChip.scripts.OnClick(roChip)
local roPanel = DragonworldRosterScroll.parent
local function roRows()
    local out = {}
    for _, row in ipairs(DragonworldRosterScroll.scrollChild.children) do
        if row:IsShown() then out[#out + 1] = row end
    end
    return out
end
local function roRow(name)
    for _, row in ipairs(roRows()) do
        if row.name.text == name then return row end
    end
end
-- A member's professions as the list has them: "Cooking 150, Mining 225".
local function profs(row)
    local parts = {}
    for _, p in ipairs(row.member and row.member.professions or {}) do parts[#parts + 1] = p.name .. " " .. p.level end
    return table.concat(parts, ", ")
end
-- What the row really shows: the professions that fit (a * marks one that can
-- be opened), and "+N" for the rest.
local function shownProfs(row)
    local parts = {}
    for _, b in ipairs(row.buttons) do
        if b:IsShown() then parts[#parts + 1] = b.text.text .. (b.linked and "*" or "") end
    end
    return table.concat(parts, ", ") .. (row.more.text ~= "" and (" " .. row.more.text) or "")
end
-- "Name level rank [professions] last-online", one per row.
local function roDescribe()
    local parts = {}
    for _, row in ipairs(roRows()) do
        parts[#parts + 1] = ("%s %s %s [%s] %s"):format(row.name.text, row.level.text, row.rank.text, profs(row), row.last.text)
    end
    return table.concat(parts, " | ")
end
local function roNames()
    local parts = {}
    for _, row in ipairs(roRows()) do parts[#parts + 1] = row.name.text end
    return table.concat(parts, ",")
end

check("Medlemmer opens from its chip and asks the game for a fresh member list",
    roPanel:IsVisible() and roChip.selected and roChip.label.text == "Medlemmer" and roChip.icon.texture == "Interface\\Icons\\INV_Banner_02" and rosterRequests == 1)
check("panel text is Norwegian",
    roPanel.title.text == "Guildmedlemmer" and roPanel.statusChips.all.label.text == "Alle" and roPanel.statusChips.online.label.text == "Pålogget"
    and roPanel.statusChips.active.label.text == "Aktive" and roPanel.statusChips.inactive.label.text == "Inaktive"
    and roPanel.professionChip.label.text == "Profession: Alle" and roPanel.searchLabel.text == "Søk:"
    and roPanel.headerName.text == "Navn" and roPanel.headerLast.text == "Sist pålogget" and roPanel.footer.text == ns.strings.nb.RO_FOOTER)
check("every member is listed A-Z, online or not, with level, rank and how long since they were on",
    roDescribe() == "Altine 58 Officer [] Pålogget | Borin 42 Member [] 3 d | Cedric 20 Member [] 2 mnd | Dagny 60 Initiate [] 1 år | Eira 35 Member [] 6 t"
    .. " | Tester 60 Guild Master [Cooking 150, Engineering 210, Mining 225] Pålogget", roDescribe())
check("the count shows how many are listed out of the whole guild", roPanel.count.text == "Viser 6 av 6" and roPanel.statusChips.all.selected)
check("names are in class colour, and 'online' is green",
    colour(roRow("Tester").name.color, 0.96, 0.55, 0.73) and colour(roRow("Altine").name.color, 0.25, 0.78, 0.92)
    and colour(roRow("Tester").last.color, 0.25, 1.00, 0.25) and colour(roRow("Borin").last.color, 0.75, 0.75, 0.75))

-- Filters.
roPanel.statusChips.online.scripts.OnClick(roPanel.statusChips.online)
check("filter: online", roNames() == "Altine,Tester" and roPanel.count.text == "Viser 2 av 6" and roPanel.statusChips.online.selected and not roPanel.statusChips.all.selected, roNames())
roPanel.statusChips.active.scripts.OnClick(roPanel.statusChips.active)
check("filter: active = online, or on within the last 30 days", roNames() == "Altine,Borin,Eira,Tester", roNames())
roPanel.statusChips.inactive.scripts.OnClick(roPanel.statusChips.inactive)
check("filter: inactive = not on for 30 days or more", roNames() == "Cedric,Dagny", roNames())
roPanel.statusChips.all.scripts.OnClick(roPanel.statusChips.all)

-- Other members' addons tell us their professions.
roReceive("P\tPlayer-1-Altine\tAlchemy:300:300;Herbalism:280:300", "Altine-Stormrage")
check("the list is not redrawn for every message", profs(roRow("Altine")) == "" and queued(0.5) == 1)
flush()
check("a member's professions appear once their addon has told us",
    profs(roRow("Altine")) == "Alchemy 300, Herbalism 280" and roDB().professions["Player-1-Altine"].list[1].max == 300 and roDB().professions["Player-1-Altine"].updated == NOW)
check("...and are filed under the player's fixed id, not the name", roDB().professions["Altine-Stormrage"] == nil)
roReceive("P\tSkinning:75:150", "Borin")
flush()
check("a message from an older version, without an id and without realm, is matched on the name", profs(roRow("Borin")) == "Skinning 75")

-- Names in this game can contain spaces, and the game does not write them the
-- same way everywhere. A member is still recognised.
do
    table.insert(ROSTER, { "Anna Berg-Stormrage", "Member", 3, 32, "Paladin", "Wetlands", "", "", true, 0, "PALADIN", guid = "Player-1-AnnaBerg" })
    roReceive("P\tPlayer-1-AnnaBerg\tBlacksmithing:120:150", "AnnaBerg-Stormrage")
    flush()
    check("a name with a space is shown whole, and matched by id whatever the sender is called",
        roRow("Anna Berg") ~= nil and profs(roRow("Anna Berg")) == "Blacksmithing 120", roNames())
    roDB().professions["Player-1-AnnaBerg"] = nil
    ROSTER[#ROSTER].guid = nil
    roReceive("P\tMining:80:150", "AnnaBerg-Stormrage")
    flush()
    check("without an id, 'AnnaBerg' and 'Anna Berg' are still the same member", profs(roRow("Anna Berg")) == "Mining 80")
    roDB().professions["name:akropolis"] = nil
    table.remove(ROSTER)
    fire("GUILD_ROSTER_UPDATE")
    flush()
end

-- This character's own professions are read in three ways, because the game
-- does not always report them the same way.
do
    local realGetProfessions = GetProfessions
    GetProfessions = function() end        -- the character's profession list is empty in this client
    fire("GUILD_ROSTER_UPDATE")
    flush()
    check("with nothing from the profession list, the own row is empty", profs(roRow("Tester")) == "")

    C_TradeSkillUI = {
        GetAllProfessionTradeSkillLines = function() return { 164, 165, 171 } end,
        GetProfessionInfoBySkillLineID = function(id)
            if id == 164 then return { professionName = "Blacksmithing", skillLevel = 120, maxSkillLevel = 150 } end
            return { professionName = id == 165 and "Leatherworking" or "Alchemy", skillLevel = 0, maxSkillLevel = 0 }
        end,
    }
    fire("GUILD_ROSTER_UPDATE")
    flush()
    check("the crafting system's list is used, taking only professions the character has skill in",
        profs(roRow("Tester")) == "Blacksmithing 120", profs(roRow("Tester")))

    C_TradeSkillUI = { GetBaseProfessionInfo = function() return { professionName = "Blacksmithing", skillLevel = 125, maxSkillLevel = 150 } end }
    roDB().seen = {}
    fire("TRADE_SKILL_SHOW")               -- the player opens the Blacksmithing window
    flush()
    check("opening a profession window teaches the addon that profession",
        profs(roRow("Tester")) == "Blacksmithing 125" and roDB().seen["Player-1-Tester"].Blacksmithing.level == 125, profs(roRow("Tester")))
    C_TradeSkillUI = nil                   -- window closed, nothing else reports it
    fire("GUILD_ROSTER_UPDATE")
    flush()
    check("...and it is remembered after the window is closed", profs(roRow("Tester")) == "Blacksmithing 125")

    roDB().seen = {}
    GetProfessions = realGetProfessions
    fire("GUILD_ROSTER_UPDATE")
    flush()
    check("back to the normal profession list", profs(roRow("Tester")) == "Cooking 150, Engineering 210, Mining 225", profs(roRow("Tester")))
    flush()
    sentNow(RO_PREFIX)
end

-- /dw debug prints what the game reports, for troubleshooting.
clearChat()
dw("debug")
check("/dw debug shows who the game says this character is",
    has("[identitet]") and has("GUID: Player-1-Tester") and has("guild: Dragonworld") and has("medlem: true") and has("min rad: key=Tester-Stormrage"), chatText())
check("...what it reports about professions, and how message senders are written",
    has("[professions]") and has("GetProfessions[1] = 1 -> Mining 225/300") and has("resultat: Cooking:150:225;Engineering:210:225;Mining:225:300")
    and has("[meldinger]") and has("siste avsender:"), chatText())
clearChat()
clearChat()
roReceive("P\tgarbage;;:::;Mining:x:y", "Cedric-Stormrage")
roReceive("P", "Eira-Stormrage")
roReceive("", "Eira-Stormrage")
roReceive("X\tunknown", "Eira-Stormrage")
flush()
check("broken profession messages are ignored without errors", chatText() == "" and profs(roRow("Cedric")) == "" and profs(roRow("Eira")) == "", chatText())
roReceive("P\t|cffff0000Evil|r:1:1", "Eira-Stormrage")
flush()
check("colour codes smuggled into a profession name are taken out", profs(roRow("Eira")) ~= "" and not profs(roRow("Eira")):find("|", 1, true), profs(roRow("Eira")))
roReceive("P\t", "Eira-Stormrage")
flush()
check("a member can report having no professions", profs(roRow("Eira")) == "")
roReceive("P\tFishing:10:75", "Tester-Stormrage")
flush()
check("nobody can report professions for another character: our own echo is ignored", profs(roRow("Tester")) == "Cooking 150, Engineering 210, Mining 225")

lastMenu = nil
roPanel.professionChip.scripts.OnClick(roPanel.professionChip)
do
    local names = {}
    for _, radio in ipairs(lastMenu and lastMenu.radios or {}) do names[#names + 1] = radio.text end
    check("the profession button lists every profession anyone has",
        lastMenu ~= nil and lastMenu.titles[1] == "Profession" and table.concat(names, ",") == "Alle,Alchemy,Cooking,Engineering,Herbalism,Mining,Skinning"
        and lastMenu.radios[1].selected(), table.concat(names, ","))
end
lastMenu.radios[6].click()                -- Mining
check("filter: profession", roNames() == "Tester" and roPanel.professionChip.label.text == "Profession: Mining" and roPanel.count.text == "Viser 1 av 6", roNames())
roPanel.statusChips.inactive.scripts.OnClick(roPanel.statusChips.inactive)
check("filters combine: nobody inactive has Mining, and the panel says so", roNames() == "" and roPanel.empty:IsShown() and roPanel.empty.text == "Ingen medlemmer passer dette filteret.")
roPanel.statusChips.all.scripts.OnClick(roPanel.statusChips.all)
roPanel.professionChip.scripts.OnClick(roPanel.professionChip)
lastMenu.radios[1].click()
check("back to all professions", roNames() == "Altine,Borin,Cedric,Dagny,Eira,Tester" and roPanel.professionChip.label.text == "Profession: Alle")

-- Search looks in name, rank and professions.
typeInto(roPanel.searchBox, "BOR")
check("search by name, ignoring capitals", roNames() == "Borin", roNames())
typeInto(roPanel.searchBox, "office")
check("search by rank", roNames() == "Altine", roNames())
typeInto(roPanel.searchBox, "herb")
check("search by profession", roNames() == "Altine", roNames())
roPanel.statusChips.online.scripts.OnClick(roPanel.statusChips.online)
typeInto(roPanel.searchBox, "in")
check("search works together with the status filter", roNames() == "Altine,Tester", roNames())
roPanel.statusChips.all.scripts.OnClick(roPanel.statusChips.all)
check("...and stays when the filter changes (Dagny matches on the rank Initiate, Tester on Mining)",
    roNames() == "Altine,Borin,Dagny,Tester" and roPanel.searchBox:GetText() == "in", roNames())
typeInto(roPanel.searchBox, "")

-- Hovering a member shows everything about them.
do
    local row = roRow("Altine")
    row.scripts.OnEnter(row)
    local text = table.concat(GameTooltip.lines, " / ")
    check("hover: name, level and rank, zone, professions with max, and when they were updated",
        GameTooltip:IsShown() and GameTooltip.lines[1] == "Altine" and GameTooltip.lines[2] == "Level 58 - Officer" and GameTooltip.lines[3] == "Stormwind"
        and text:find("Alchemy 300/300", 1, true) and text:find("Herbalism 280/300", 1, true) and text:find("Professions oppdatert DATE(" .. NOW .. ")", 1, true), text)
    row.scripts.OnLeave(row)
    row = roRow("Borin")
    row.scripts.OnEnter(row)
    check("hover shows the member's public note", table.concat(GameTooltip.lines, " / "):find("Alt of Tester", 1, true) ~= nil)
    row.scripts.OnLeave(row)
    row = roRow("Dagny")
    row.scripts.OnEnter(row)
    check("hover on a member without the addon explains why there are no professions", GameTooltip.lines[#GameTooltip.lines - 1] == ns.strings.nb.RO_TIP_NONE)
    row.scripts.OnLeave(row)
end

-- Someone logs in and asks everyone for their professions.
flush()
sentNow(RO_PREFIX)
roReceive("R", "Nykommer-Stormrage")
roReceive("R", "Annen-Stormrage")
check("the answer is not sent the same instant, and two requests give one answer", #sentNow(RO_PREFIX) == 0 and queued(4.5) == 1, queued(4.5))
flush()
do
    local sent = sentNow(RO_PREFIX)
    check("then this character's professions are sent again", #sent == 1 and sent[1] == "P\tPlayer-1-Tester\tCooking:150:225;Engineering:210:225;Mining:225:300", table.concat(sent, " ; "))
end

-- Skill goes up: the guild is told, but only when something changed.
MY_PROFESSIONS[1][3] = 230
fire("SKILL_LINES_CHANGED")
fire("SKILL_LINES_CHANGED")
check("skill changes are batched", #sentNow(RO_PREFIX) == 0 and queued(60) == 1)
flush()
do
    local sent = sentNow(RO_PREFIX)
    check("a higher skill is sent to the guild", #sent == 1 and sent[1]:find("Mining:230:300", 1, true) ~= nil, table.concat(sent, " ; "))
    flush()
    check("...and shown in the list", profs(roRow("Tester")):find("Mining 230", 1, true) ~= nil, profs(roRow("Tester")))
end
fire("SKILL_LINES_CHANGED")
flush()
check("nothing is sent when nothing changed", #sentNow(RO_PREFIX) == 0)

-- The member list changes.
ROSTER[3][9] = true                       -- Borin logs in
ROSTER[3].last = nil
fire("GUILD_ROSTER_UPDATE")
check("roster updates are batched too", roRow("Borin").last.text == "3 d" and queued(0.5) == 1)
flush()
check("a member who logs in shows as online", roRow("Borin").last.text == "Pålogget" and colour(roRow("Borin").last.color, 0.25, 1.00, 0.25))
ROSTER[3][9] = false
ROSTER[3].last = { 0, 0, 3, 5 }

-- A client that has the game's own guild profession overview fills in the rest.
do
    local gameList = {
        { 197, false, 1, "Tailoring", 0, 1, 2 },
        { 197, nil, nil, nil, nil, nil, nil, "Dagny", "Dagny-Stormrage", "Priest", false, "Darnassus", 300 },
        { 197, nil, nil, nil, nil, nil, nil, "Altine", "Altine-Stormrage", "Mage", true, "Stormwind", 10 },
        { 333, false, 1, "Enchanting", 0, 1, 1 },
        { 333, nil, nil, nil, nil, nil, nil, "Cedric", "Cedric-Stormrage", "Rogue", false, "Elwynn Forest", 120 },
    }
    GetNumGuildTradeSkill = function() return #gameList end
    GetGuildTradeSkillInfo = function(index) return table.unpack(gameList[index], 1, 13) end
    fire("GUILD_ROSTER_UPDATE")
    flush()
    check("members without the addon get their professions from the game's overview",
        profs(roRow("Dagny")) == "Tailoring 300" and profs(roRow("Cedric")) == "Enchanting 120", profs(roRow("Dagny")))
    check("what a member's own addon reported wins over the game's overview", profs(roRow("Altine")) == "Alchemy 300, Herbalism 280")
    local row = roRow("Dagny")
    row.scripts.OnEnter(row)
    check("hover says where it came from", GameTooltip.lines[#GameTooltip.lines - 1] == "Fra spillets egen guild-oversikt" and table.concat(GameTooltip.lines, " / "):find("Tailoring 300", 1, true) ~= nil)
    row.scripts.OnLeave(row)
    roPanel.professionChip.scripts.OnClick(roPanel.professionChip)
    local names = {}
    for _, radio in ipairs(lastMenu.radios) do names[#names + 1] = radio.text end
    check("those professions can be filtered on as well", table.concat(names, ","):find("Enchanting", 1, true) ~= nil and table.concat(names, ","):find("Tailoring", 1, true) ~= nil)
    GetNumGuildTradeSkill, GetGuildTradeSkillInfo = nil, nil
    fire("GUILD_ROSTER_UPDATE")
    flush()
    check("without that overview the list simply shows what the addons reported", profs(roRow("Dagny")) == "" and profs(roRow("Altine")) == "Alchemy 300, Herbalism 280")
end

-- ---- Opening a member's profession, like a profession link in chat ----
-- (Since the Legacy column came in, professions have 40 px less room.)
check("each profession stands on its own in the row; what does not fit becomes '+2'",
    shownProfs(roRow("Tester")) == "Cooking 150 +2" and shownProfs(roRow("Altine")) == "Alchemy 300, Herbalism 280"
    and shownProfs(roRow("Dagny")) == "", shownProfs(roRow("Tester")) .. " | " .. shownProfs(roRow("Altine")))
do
    local x1 = select(4, roRow("Altine").buttons[1]:GetPoint())
    local x2 = select(4, roRow("Altine").buttons[2]:GetPoint())
    check("professions start under their heading and follow each other with a gap",
        x1 == 310 and x2 == 310 + 66 + 10 and select(4, roPanel.headerProfessions:GetPoint()) == 320, tostring(x1) .. " " .. tostring(x2))
end
do
    local button = roRow("Altine").buttons[1]
    check("a profession the member has not shared is white", not button.linked and colour(button.text.color, 0.90, 0.90, 0.90))
    button.scripts.OnClick(button)
    check("...and clicking it opens nothing", #itemRefs == 0)
    button.scripts.OnEnter(button)
    check("...hovering says why", GameTooltip.lines[1] == "Alchemy 300/300" and GameTooltip.lines[2] == ns.strings.nb.RO_TIP_NO_LINK:format("Altine")
        and GameTooltip.lines[2]:find("Altine har ikke delt", 1, true) ~= nil, table.concat(GameTooltip.lines, " / "))
    button.scripts.OnLeave(button)
end

-- Altine's addon sends the game's links to her professions.
roReceive("L\tPlayer-1-Altine\tAlchemy:2259:171;Herbalism:bad|link;;Evil", "Altine-Stormrage")
flush()
check("links from a member are stored; broken ones are dropped",
    roDB().professions["Player-1-Altine"].links.Alchemy == "2259:171" and roDB().professions["Player-1-Altine"].links.Herbalism == nil and chatText() == "", chatText())
check("a shared profession is marked as one that can be opened", shownProfs(roRow("Altine")) == "Alchemy 300*, Herbalism 280"
    and colour(roRow("Altine").buttons[1].text.color, 1.00, 0.82, 0.00), shownProfs(roRow("Altine")))
do
    local button = roRow("Altine").buttons[1]
    button.scripts.OnEnter(button)
    check("hovering it says what a click does", GameTooltip.lines[2] == "Klikk for å se hva Altine kan lage." and colour(button.text.color, 1, 1, 1), table.concat(GameTooltip.lines, " / "))
    button.scripts.OnLeave(button)
    check("...and it goes back to yellow", colour(button.text.color, 1.00, 0.82, 0.00) and not GameTooltip:IsShown())
    button.scripts.OnClick(button)
    check("clicking it does what a click on the profession link in chat does",
        #itemRefs == 1 and itemRefs[1].link == "trade:Player-1-Altine:2259:171"
        and itemRefs[1].text == "|cffffd000|Htrade:Player-1-Altine:2259:171|h[Alchemy]|h|r", itemRefs[1] and itemRefs[1].text)
end
roReceive("P\tPlayer-1-Altine\tAlchemy:300:300;Herbalism:285:300", "Altine-Stormrage")
flush()
check("the links stay when the member's skill is updated", shownProfs(roRow("Altine")) == "Alchemy 300*, Herbalism 285", shownProfs(roRow("Altine")))

-- Clicking the row opens the member card, which lists every profession.
roRow("Altine").scripts.OnMouseUp(roRow("Altine"), "LeftButton")
do
    local card = DragonworldMemberCard
    check("clicking a row opens the member card, with the member's professions; those not shared are greyed out",
        card ~= nil and card:IsVisible() and card.name.text == "Altine" and card.professionChips[1]:IsShown() and card.professionChips[2]:IsShown()
        and card.professionChips[1].label.text == "Alchemy 300/300" and not card.professionChips[1].dimmed
        and card.professionChips[2].label.text == "Herbalism 285/300" and card.professionChips[2].dimmed)
    card.professionChips[1].scripts.OnClick(card.professionChips[1])
    check("clicking a shared one on the card opens it", #itemRefs == 2 and itemRefs[2].link == "trade:Player-1-Altine:2259:171")
    card.close.scripts.OnClick(card.close)
    roRow("Dagny").scripts.OnMouseUp(roRow("Dagny"), "LeftButton")
    check("a member with no known professions gets a card that says so",
        card:IsVisible() and card.name.text == "Dagny" and not card.professionChips[1]:IsShown() and card.noProfessions:IsShown())
    card.close.scripts.OnClick(card.close)
end
do
    local row = roRow("Altine")
    row.scripts.OnEnter(row)
    check("hovering a row mentions what a click does", GameTooltip.lines[#GameTooltip.lines] == ns.strings.nb.RO_TIP_CLICK_ROW)
    row.scripts.OnLeave(row)
end

-- If the game will not open it for us, the link is put in chat to be clicked there.
clearChat()
SetItemRef = function() error("blocked") end
roRow("Altine").buttons[1].scripts.OnClick(roRow("Altine").buttons[1])
check("if opening fails, the link is put in the player's chat instead",
    has("Fikk ikke åpnet professionen til Altine direkte.") and has("|Htrade:Player-1-Altine:2259:171|h[Alchemy]|h"), chatText())
clearChat()
SetItemRef = nil
roRow("Altine").buttons[1].scripts.OnClick(roRow("Altine").buttons[1])
check("...also in a client without that function", has("|Htrade:Player-1-Altine:2259:171|h[Alchemy]|h"), chatText())
SetItemRef = realSetItemRef
clearChat()

-- A link filed under a name (older version, no id) cannot be opened.
roReceive("L\tPlayer-1-Borin\tSkinning:8613:393", "Borin-Stormrage")
flush()
check("links are only used together with professions filed under the same id",
    shownProfs(roRow("Borin")) == "Skinning 75" and roDB().professions["Player-1-Borin"].links.Skinning == "8613:393", shownProfs(roRow("Borin")))
roDB().professions["Player-1-Borin"] = nil

-- Our own professions: the link is read when the profession window is open.
flush()
sentNow(RO_PREFIX)
C_TradeSkillUI = {
    GetBaseProfessionInfo = function() return { professionName = "Mining", skillLevel = 230, maxSkillLevel = 300 } end,
    GetTradeSkillListLink = function() return "|cffffd000|Htrade:Player-1-Tester:2575:186|h[Mining]|h|r" end,
    IsTradeSkillLinked = function() return false end,
}
fire("TRADE_SKILL_SHOW")
flush()
do
    local sent = sentNow(RO_PREFIX)
    check("opening your own profession window shares its link with the guild, in a message of its own",
        #sent == 1 and sent[1] == "L\tPlayer-1-Tester\tMining:2575:186", table.concat(sent, " ; "))
end
roRow("Tester").scripts.OnMouseUp(roRow("Tester"), "LeftButton")
check("your own card can open it too, also the profession that did not fit in the row",
    DragonworldMemberCard:IsVisible() and DragonworldMemberCard.professionChips[3]:IsShown() and DragonworldMemberCard.professionChips[3].label.text == "Mining 230/300"
    and not DragonworldMemberCard.professionChips[3].dimmed and DragonworldMemberCard.professionChips[1].dimmed and DragonworldMemberCard.professionChips[2].dimmed)
DragonworldMemberCard.close.scripts.OnClick(DragonworldMemberCard.close)
C_TradeSkillUI.GetTradeSkillListLink = function() return nil end
fire("TRADE_SKILL_LIST_UPDATE")
flush()
check("a moment where the game gives no link does not lose the one we had",
    roDB().seen["Player-1-Tester"].Mining.link == "2575:186" and #sentNow(RO_PREFIX) == 0)

-- Looking at someone else's profession must not make it ours.
C_TradeSkillUI = {
    GetBaseProfessionInfo = function() return { professionName = "Alchemy", skillLevel = 300, maxSkillLevel = 300 } end,
    GetTradeSkillListLink = function() return "|cffffd000|Htrade:Player-1-Altine:2259:171|h[Alchemy]|h|r" end,
    IsTradeSkillLinked = function() return true end,
}
fire("TRADE_SKILL_SHOW")
flush()
check("looking at another member's profession does not add it to your own",
    roDB().seen["Player-1-Tester"].Alchemy == nil and profs(roRow("Tester")):find("Alchemy", 1, true) == nil and #sentNow(RO_PREFIX) == 0, profs(roRow("Tester")))
C_TradeSkillUI.IsTradeSkillLinked = nil
fire("TRADE_SKILL_SHOW")
flush()
check("...also when the game does not say whose window it is: the link carries the owner's id",
    roDB().seen["Player-1-Tester"].Alchemy == nil and #sentNow(RO_PREFIX) == 0)
C_TradeSkillUI = nil
fire("GUILD_ROSTER_UPDATE")
flush()
roRow("Tester").scripts.OnMouseUp(roRow("Tester"), "LeftButton")
check("the link is remembered after the window is closed", DragonworldMemberCard:IsVisible() and not DragonworldMemberCard.professionChips[3].dimmed)
DragonworldMemberCard.close.scripts.OnClick(DragonworldMemberCard.close)

roReceive("R", "Nykommer-Stormrage")
flush()
do
    local sent = sentNow(RO_PREFIX)
    check("someone who asks gets both the professions and the links",
        #sent == 2 and sent[1]:find("^P\tPlayer%-1%-Tester\t") ~= nil and sent[2] == "L\tPlayer-1-Tester\tMining:2575:186", table.concat(sent, " ; "))
end
clearChat()
dw("debug")
check("/dw debug shows which links are shared", has("lenker som deles: Mining:2575:186") and has("SetItemRef: true"), chatText())
clearChat()

-- The reminder about opening your professions can be brought back from here.
check("Medlemmer has a button for your own professions", roPanel.mineChip.label.text == "Mine professions" and not shareNotice:IsShown())
roPanel.mineChip.scripts.OnClick(roPanel.mineChip)
check("it opens the reminder again, now showing what has been shared",
    shareNotice:IsVisible() and shareNotice.title.text == "Del professionene dine"
    and shareNotice.list.text == "Cooking 150 - ikke åpnet ennå\nEngineering 210 - ikke åpnet ennå\n|cff40ff40Mining 230 - delt|r", shareNotice.list.text)
C_TradeSkillUI = {
    GetBaseProfessionInfo = function() return { professionName = "Engineering", skillLevel = 210, maxSkillLevel = 225 } end,
    GetTradeSkillListLink = function() return "|cffffd000|Htrade:Player-1-Tester:4036:202|h[Engineering]|h|r" end,
}
fire("TRADE_SKILL_SHOW")
check("opening another profession ticks it off at once",
    shareNotice.list.text == "Cooking 150 - ikke åpnet ennå\n|cff40ff40Engineering 210 - delt|r\n|cff40ff40Mining 230 - delt|r", shareNotice.list.text)
C_TradeSkillUI = nil
ns.SetLanguage("en", true)
check("the reminder follows the language", shareNotice.title.text == "Share your professions" and shareNotice.list.text:find("Cooking 150 - not opened yet", 1, true) ~= nil)
ns.SetLanguage("nb", true)
shareNotice.ok.scripts.OnClick(shareNotice.ok)
check("OK closes it again", not shareNotice:IsShown())
do
    -- Another character on the same account has not seen it yet.
    local altinesProfessions = roDB().professions["Player-1-Altine"]
    character = { name = "Altine", realm = "Stormrage", class = "MAGE", guid = "Player-1-Altine" }
    dw("")
    dw("")
    check("another character gets the reminder the first time the window is opened there", win:IsShown() and shareNotice:IsVisible())
    shareNotice.ok.scripts.OnClick(shareNotice.ok)
    check("...and it is remembered per character", roDB().reminded["Altine-Stormrage"] == true and roDB().reminded["Tester-Stormrage"] == true)
    character = { name = "Tester", realm = "Stormrage", class = "PALADIN" }
    roDB().professions["Player-1-Altine"] = altinesProfessions
    dw("")
    dw("")
    check("back on the first character it stays away", win:IsShown() and roPanel:IsVisible() and not shareNotice:IsShown())
end

-- ---- "Open next": the addon opens the professions for the player, one per click ----
do
    local realGetProfessions = GetProfessions
    GetProfessions = function() return 1, 2, nil, 4, 5 end
    MY_PROFESSIONS[4] = { "Fishing", 136245, 29, 75, 0, 0, 356 }
    roDB().seen = {}
    flush()
    sentNow(RO_PREFIX)

    -- The game: OpenTradeSkill opens one profession window and only works from
    -- a click. Fishing has no window. Mining's window is called Smelting, and
    -- its link does not carry Mining's number.
    local opened, closed, current, linkReady = {}, 0, nil, true
    local WINDOWS = {
        [185] = { name = "Cooking", level = 150, max = 225, link = "2550:185" },
        [202] = { name = "Engineering", level = 210, max = 225, link = "4036:202" },
        [186] = { name = "Smelting", level = 230, max = 300, link = "2656:9999" },
    }
    C_TradeSkillUI = {
        OpenTradeSkill = function(line)
            assert(type(line) == "number", "OpenTradeSkill(skillLineID)")
            assert(inHardwareEvent, "OpenTradeSkill called outside a click; the game would refuse it")
            opened[#opened + 1] = line
            if not WINDOWS[line] then return false end
            current = line
            return true
        end,
        CloseTradeSkill = function() current = nil; closed = closed + 1 end,
        GetBaseProfessionInfo = function()
            local w = current and WINDOWS[current]
            if w then return { professionName = w.name, skillLevel = w.level, maxSkillLevel = w.max } end
        end,
        GetTradeSkillListLink = function()
            local w = current and WINDOWS[current]
            if w and linkReady then return ("|cffffd000|Htrade:Player-1-Tester:%s|h[%s]|h|r"):format(w.link, w.name) end
        end,
    }

    roPanel.mineChip.scripts.OnClick(roPanel.mineChip)
    local open = shareNotice.open
    check("where the game lets an addon open a profession, the reminder has a button for the next one",
        open:IsShown() and open:IsEnabled() and open.label.text == "Åpne neste: Cooking" and select(1, shareNotice.ok:GetPoint()) == "BOTTOMLEFT"
        and shareNotice.text.text == ns.strings.nb.RO_SHARE_TEXT .. " " .. ns.strings.nb.RO_SHARE_TEXT_BUTTON and shareNotice.status.text == ""
        and shareNotice.list.text == "Cooking 150 - ikke åpnet ennå\nEngineering 210 - ikke åpnet ennå\nFishing 29 - ikke åpnet ennå\nMining 230 - ikke åpnet ennå",
        open.label.text .. " | " .. shareNotice.list.text)

    inCombat = true
    open.scripts.OnClick(open)
    check("nothing is opened in combat", #opened == 0 and shareNotice.status.text == "Ikke i kamp. Prøv igjen etterpå." and open:IsEnabled())
    inCombat = false

    open.scripts.OnClick(open)
    check("one click opens exactly one profession, and the button waits meanwhile",
        #opened == 1 and opened[1] == 185 and not open:IsEnabled() and shareNotice.status.text == "Åpner Cooking ...", shareNotice.status.text)
    fire("TRADE_SKILL_SHOW")
    flushNow()
    check("when its link has been read, the window is closed again and the profession is ticked off",
        closed == 1 and current == nil and shareNotice.status.text == "Cooking er delt." and roDB().seen["Player-1-Tester"].Cooking.link == "2550:185"
        and shareNotice.list.text:find("|cff40ff40Cooking 150 - delt|r", 1, true) ~= nil and open:IsEnabled() and open.label.text == "Åpne neste: Engineering",
        shareNotice.status.text .. " | " .. open.label.text)

    linkReady = false
    open.scripts.OnClick(open)
    flushNow()
    check("the addon keeps looking while the game has not given the link yet",
        #opened == 2 and opened[2] == 202 and closed == 1 and not open:IsEnabled() and shareNotice.status.text == "Åpner Engineering ...")
    for _ = 1, 5 do flushNow() end
    check("after a few seconds it gives up on that one, leaves its window open, and moves on",
        shareNotice.status.text == "Fikk ingenting fra Engineering. Prøv å åpne den selv." and closed == 1 and current == 202
        and open:IsEnabled() and open.label.text == "Åpne neste: Fishing", shareNotice.status.text .. " | " .. open.label.text)
    linkReady = true
    fire("TRADE_SKILL_LIST_UPDATE")
    check("a link that arrives late is still taken", shareNotice.list.text:find("|cff40ff40Engineering 210 - delt|r", 1, true) ~= nil, shareNotice.list.text)

    open.scripts.OnClick(open)
    check("a profession the game cannot open is explained and passed over",
        #opened == 3 and opened[3] == 356 and shareNotice.status.text == "Fikk ikke åpnet Fishing. Den har kanskje ikke noe vindu."
        and open:IsEnabled() and open.label.text == "Åpne neste: Mining" and closed == 1, shareNotice.status.text .. " | " .. open.label.text)

    open.scripts.OnClick(open)
    fire("TRADE_SKILL_SHOW")
    flushNow()
    check("a window with another name is filed under the profession that was asked for (Mining's window is called Smelting)",
        #opened == 4 and opened[4] == 186 and roDB().seen["Player-1-Tester"].Mining.link == "2656:9999" and roDB().seen["Player-1-Tester"].Smelting == nil
        and shareNotice.status.text == "Mining er delt." and closed == 2, shareNotice.status.text)
    check("with nothing left to open, the button says so and is greyed out",
        not open:IsEnabled() and open.label.text == "Ingen flere å åpne"
        and shareNotice.list.text == "|cff40ff40Cooking 150 - delt|r\n|cff40ff40Engineering 210 - delt|r\nFishing 29 - ikke åpnet ennå\n|cff40ff40Mining 230 - delt|r",
        open.label.text .. " | " .. shareNotice.list.text)
    open.scripts.OnClick(open)
    check("...and pressing it does nothing", #opened == 4)

    clearChat()
    dw("debug")
    check("/dw debug shows whether the addon can open professions, and the game's number for each",
        has("kan åpne for deg (OpenTradeSkill): true | nummer: Cooking=185, Engineering=202, Fishing=356, Mining=186"), chatText())
    clearChat()

    C_TradeSkillUI.OpenTradeSkill = nil
    fire("TRADE_SKILL_LIST_UPDATE")
    check("in a game without that function there is no such button, and OK sits in the middle",
        not open:IsShown() and select(1, shareNotice.ok:GetPoint()) == "BOTTOM" and shareNotice.text.text == ns.strings.nb.RO_SHARE_TEXT)

    shareNotice.ok.scripts.OnClick(shareNotice.ok)
    C_TradeSkillUI = nil
    GetProfessions = realGetProfessions
    MY_PROFESSIONS[4] = nil
end
roDB().seen = {}
fire("GUILD_ROSTER_UPDATE")
flush()
sentNow(RO_PREFIX)

ns.SetLanguage("en", true)
check("Medlemmer follows the language",
    roPanel.title.text == "Guild members" and roChip.label.text == "Roster" and roPanel.headerLast.text == "Last online" and roRow("Dagny").last.text == "1 y"
    and roRow("Cedric").last.text == "2 mo" and roRow("Eira").last.text == "6 h" and roRow("Tester").last.text == "Online" and roPanel.count.text == "Showing 6 of 6")
ns.SetLanguage("nb", true)

flush()
sentNow(RO_PREFIX)
clearChat()
kbChip.scripts.OnClick(kbChip)

-- ================================= Guildbank ====================================
-- In a function of its own: the main chunk is at Lua's limit of 200 locals.
-- (The semicolon keeps Lua from reading it as a call on the line above.)
;(function()
    local GB_PREFIX = "DragonworldGB"
    local gbChip = chipByID.guildbank
    local function gbDB() return DragonworldDB.modules.guildbank end
    local function gbReceive(text, sender) fire("CHAT_MSG_ADDON", GB_PREFIX, text, "GUILD", sender or "Altine-Stormrage") end
    local function gbSent() return sentNow(GB_PREFIX) end
    local function all(list) return table.concat(list, " ; ") end
    -- The same check sum the addon uses, written out again here: two clients
    -- must agree on it, so a change on one side shows up as a failure.
    local function digestOf(text, entries)
        local hash = 7
        for index = 1, #text do hash = (hash * 31 + text:byte(index)) % 16777213 end
        return entries .. "." .. hash
    end
    -- What we know about who sees which tab, as one version: newest time and check sum.
    local function accessVersion()
        local access, tabList, parts, newest = gbDB().access, {}, {}, 0
        for tab in pairs(access) do tabList[#tabList + 1] = tab end
        table.sort(tabList)
        for _, tab in ipairs(tabList) do
            local ranks = {}
            for rank in pairs(access[tab]) do ranks[#ranks + 1] = rank end
            table.sort(ranks)
            for _, rank in ipairs(ranks) do
                local known = access[tab][rank]
                parts[#parts + 1] = tab .. ":" .. rank .. ":" .. (known.view and 1 or 0) .. ":" .. known.time
                newest = math.max(newest, known.time)
            end
        end
        return newest, digestOf(table.concat(parts, ","), #parts)
    end

    check("at login the guild bank module tells the guild which versions it has (none yet)",
        prefixes[GB_PREFIX] == true and #GBANK.login == 1 and GBANK.login[1] == "V\t", all(GBANK.login))

    gbChip.scripts.OnClick(gbChip)
    local gbPanel = DragonworldGuildbankScroll.parent
    local function gbRows()
        local out = {}
        for _, row in ipairs(DragonworldGuildbankScroll.scrollChild.children) do
            if row:IsShown() then out[#out + 1] = row end
        end
        return out
    end
    local function gbDescribe()
        local parts = {}
        for _, row in ipairs(gbRows()) do parts[#parts + 1] = row.name.text .. "=" .. row.count.text end
        return table.concat(parts, " | ")
    end
    local function gbRow(name)
        for _, row in ipairs(gbRows()) do
            if row.name.text == name then return row end
        end
    end

    check("Guildbank opens from its chip, in Norwegian",
        gbPanel:IsVisible() and gbChip.selected and gbChip.label.text == "Guildbank" and gbChip.icon.texture == "Interface\\Icons\\INV_Misc_Coin_02"
        and gbPanel.title.text == "Guildbanken" and gbPanel.tabChip.label.text == "Fane: Alle" and gbPanel.headerItem.text == "Gjenstand"
        and gbPanel.headerCount.text == "Antall" and gbPanel.searchLabel.text == "Søk:")
    check("before anyone has looked in the bank, the panel explains how it gets filled",
        gbDescribe() == "" and gbPanel.empty:IsShown() and gbPanel.empty.text == ns.strings.nb.GB_EMPTY_NONE and gbPanel.money.text == "" and gbPanel.footer.text == "")

    -- The guild bank: materials, gear (one item the game has not loaded yet),
    -- an officers' tab this rank may not see, and an empty tab.
    ITEMS[10].unloaded = true
    GBANK.tabs = {
        { name = "Mats", icon = 133784, slots = { [1] = { 20, 20 }, [2] = { 20, 15 }, [5] = { 21, 10 } } },
        { name = "Gear", icon = "Interface\\Icons\\INV_Sword_04", slots = { [1] = { 7, 1 }, [98] = { 10, 1 } } },
        { name = "Officers", icon = 133785, viewable = false, slots = { [1] = { 22, 5 } } },
        { name = "Spare", icon = 133786, slots = {} },
    }
    GBANK.money = 1234567
    GBANK.current = 1
    GBANK.loaded = { [1] = true }        -- the game's own window loads the tab it shows

    -- The server answers the oldest question the client has asked.
    local function answer()
        local tab = table.remove(GBANK.queries, 1)
        if tab then
            GBANK.loaded[tab] = true
            fire("GUILDBANKBAGSLOTS_CHANGED")
        end
    end
    -- Lets time pass at the bank, the server answering every question.
    local function stayAtBank(answers)
        for _ = 1, 10 do
            flush()
            if answers ~= false then answer() else GBANK.queries = {} end
        end
    end
    local function openBank()
        GBANK.asked, GBANK.queries = {}, {}
        fire("PLAYER_INTERACTION_MANAGER_FRAME_SHOW", 10)
        fire("GUILDBANKFRAME_OPENED")                   -- Forever lists both; the second must not start another visit
        fire("GUILDBANKBAGSLOTS_CHANGED")
    end
    local function closeBank()
        fire("PLAYER_INTERACTION_MANAGER_FRAME_HIDE", 10)
        fire("GUILDBANKFRAME_CLOSED")
    end

    flush()
    gbSent()
    clearChat()
    fire("PLAYER_INTERACTION_MANAGER_FRAME_SHOW", 8)     -- the ordinary bank is not the guild bank
    flush(); flush()
    check("opening the ordinary bank reads nothing", #GBANK.asked == 0 and next(gbDB().tabs) == nil)
    -- A client that never says the guild bank opened: its first slot change is how we notice.
    fire("GUILDBANKBAGSLOTS_CHANGED")
    flush(); flush()
    check("a client that never says the guild bank opened is still read when its slots arrive", gbDB().tabs[1] ~= nil)
    closeBank()
    gbDB().tabs, gbDB().money, gbDB().access = {}, nil, {}
    gbSent()
    clearChat()

    local t0 = SERVER_NOW
    openBank()
    check("nothing is asked for the instant the bank opens", #GBANK.asked == 0 and next(gbDB().tabs) == nil)
    stayAtBank()
    local tabs = gbDB().tabs
    check("each tab is asked for one at a time, skipping the one already shown and the one this rank may not see",
        #GBANK.asked == 2 and GBANK.asked[1] == 2 and GBANK.asked[2] == 4, table.concat(GBANK.asked, ","))
    check("every tab that arrived is stored, with what is in it, when, and by whom",
        tabs[1] and tabs[1].name == "Mats" and tabs[1].icon == 133784 and tabs[1].items[20] == 35 and tabs[1].items[21] == 10
        and tabs[1].time == t0 and tabs[1].by == "Tester"
        and tabs[2] and tabs[2].name == "Gear" and tabs[2].icon == "Interface\\Icons\\INV_Sword_04" and tabs[2].items[7] == 1 and tabs[2].items[10] == 1)
    check("a tab this rank may not see is left out", tabs[3] == nil)
    check("an empty tab nobody is looking at is not stored: it cannot be told apart from one that has not loaded", tabs[4] == nil)
    check("the gold is stored", gbDB().money and gbDB().money.amount == 1234567 and gbDB().money.time == t0 and gbDB().money.by == "Tester")
    local sent = gbSent()
    local d1, d2 = digestOf("20:35,21:10", 2), digestOf("7:1,10:1", 2)
    check("what was read is sent to the guild: each tab whole, the gold, and which tabs this rank sees",
        #sent == 6 and sent[1] == "T\t1\t" .. t0 .. "\t1\t" .. d1 .. "\tTester\t133784\tMats" and sent[2] == "D\t1\t" .. t0 .. "\t1\t20:35,21:10"
        and sent[3] == "M\t" .. t0 .. "\t1234567\tTester"
        and sent[4] == "A\t3\t1:1:" .. t0 .. ",2:1:" .. t0 .. ",3:0:" .. t0 .. ",4:1:" .. t0
        and sent[5] == "T\t2\t" .. t0 .. "\t1\t" .. d2 .. "\tTester\tInterface\\Icons\\INV_Sword_04\tGear" and sent[6] == "D\t2\t" .. t0 .. "\t1\t7:1,10:1", all(sent))
    check("this character's rank (3) is recorded as seeing tabs 1, 2 and 4, but not the officers' tab",
        gbDB().access[1][3].view == true and gbDB().access[2][3].view == true and gbDB().access[3][3].view == false and gbDB().access[4][3].view == true)
    check("the check sum is the one the addon stores", tabs[1].digest == d1 and tabs[2].digest == d2, tostring(tabs[1].digest) .. " " .. d1)
    check("chat says once that the bank was read and shared", #chat == 1 and has("Guildbanken er lest. Endringer i 2 fane(r) er delt med guilden."), chatText())

    check("the panel lists everything, A-Z, added up over the tabs",
        gbDescribe() == "Copper Ore=35 | Iron Sword=1 | Linen Cloth=10 | item:10=1" and not gbPanel.empty:IsShown(), gbDescribe())
    check("rows show the item icon and quality colour", gbRow("Copper Ore").icon.texture == 1020 and colour(gbRow("Copper Ore").name.color, 1, 1, 1))
    check("the gold is shown with the game's colours",
        gbPanel.money.text == "Gull: 123|cffffd700g|r 45|cffc7c7cfs|r 67|cffeda55fc|r", gbPanel.money.text)
    check("the footer says when and by whom", gbPanel.footer.text == "Oppdateres hver gang noen med addonen åpner guildbanken. Sist: DATE(" .. t0 .. ") av Tester.", gbPanel.footer.text)

    -- Someone takes 15 ore out while we stand there.
    clearChat()
    GBANK.tabs[1].slots[2] = nil
    fire("GUILDBANKBAGSLOTS_CHANGED")
    fire("GUILDBANKBAGSLOTS_CHANGED")
    flush(); flush()
    sent = gbSent()
    check("a change is read again and only that tab is sent, newer than the last even within the same second",
        #sent == 2 and sent[1]:find("^T\t1\t" .. (t0 + 1) .. "\t1\t") ~= nil and sent[2] == "D\t1\t" .. (t0 + 1) .. "\t1\t20:20,21:10"
        and tabs[1].items[20] == 20 and tabs[1].time == t0 + 1, all(sent))
    check("...without another line in chat", #chat == 0, chatText())
    check("...and the panel follows", gbDescribe() == "Copper Ore=20 | Iron Sword=1 | Linen Cloth=10 | item:10=1", gbDescribe())

    -- The player clicks the empty tab.
    GBANK.current = 4
    fire("GUILDBANKBAGSLOTS_CHANGED")
    flush(); flush()
    sent = gbSent()
    check("an empty tab counts as empty once it is the one on the screen",
        tabs[4] and next(tabs[4].items) == nil and tabs[4].name == "Spare" and #sent == 1 and sent[1] == "T\t4\t" .. t0 .. "\t0\t0.7\tTester\t133786\tSpare", all(sent))

    closeBank()
    GBANK.loaded = {}
    fire("GUILDBANKBAGSLOTS_CHANGED")                    -- a late message after closing
    flush(); flush()
    check("after closing, a late change from the game does not open a new visit", #gbSent() == 0 and #GBANK.asked == 2)

    -- Next visit: the server never answers.
    SERVER_NOW = SERVER_NOW + 60
    GBANK.current, GBANK.loaded = 1, { [1] = true }
    clearChat()
    openBank()
    stayAtBank(false)
    check("tabs that never arrive are given up on one by one, and what we knew about them is kept",
        #GBANK.asked == 2 and tabs[2].items[7] == 1 and tabs[2].time == t0 and tabs[4] ~= nil and #gbSent() == 0, all(GBANK.asked))
    check("...the shown tab was read, nothing had changed, and chat says so", has("Guildbanken er lest. Ingenting nytt siden sist.") and #chat == 1, chatText())
    closeBank()

    -- Ten minutes later, nothing has changed: say it is still true, without sending it all.
    SERVER_NOW = SERVER_NOW + 700
    local t1 = SERVER_NOW
    GBANK.loaded = { [1] = true }
    openBank()
    stayAtBank()
    sent = gbSent()
    check("unchanged tabs seen again are confirmed in one short message each, and so are the gold and what the rank sees",
        #sent == 4 and sent[1] == "C\t1\t" .. t1 .. "\t" .. tabs[1].digest .. "\tTester" and sent[2] == "M\t" .. t1 .. "\t1234567\tTester"
        and sent[3] == "A\t3\t1:1:" .. t1 .. ",2:1:" .. t1 .. ",3:0:" .. t1 .. ",4:1:" .. t1
        and sent[4] == "C\t2\t" .. t1 .. "\t" .. d2 .. "\tTester" and tabs[1].time == t1 and tabs[2].time == t1, all(sent))
    closeBank()
    flush()
    gbSent()

    -- Someone logs in with nothing: they get every tab and the gold.
    local snapshot = {}
    for tab, data in pairs(tabs) do snapshot[tab] = data end
    gbReceive("V\t", "Nykommer-Stormrage")
    check("nothing is sent the same instant; the reply waits a little", #gbSent() == 0)
    flush()
    local full = gbSent()
    check("a member with nothing gets every tab whole, the gold, and who sees what",
        count(full, "^T\t") == 3 and count(full, "^D\t") == 2 and count(full, "^M\t") == 1 and count(full, "^A\t") == 1
        and count(full, "^C\t") == 0, all(full))

    -- Round trip: a client that starts empty and receives exactly that ends up with the same.
    do
        local money, access = gbDB().money, gbDB().access
        local accessBefore = select(2, accessVersion())
        gbDB().tabs, gbDB().money, gbDB().access = {}, nil, {}
        for _, message in ipairs(full) do gbReceive(message, "Altine-Stormrage") end
        flush()
        local copy, same = gbDB().tabs, true
        for tab, data in pairs(snapshot) do
            local other = copy[tab]
            if not other or other.name ~= data.name or other.icon ~= data.icon or other.time ~= data.time or other.by ~= data.by or other.digest ~= data.digest then
                same = false
            else
                for itemID, n in pairs(data.items) do if other.items[itemID] ~= n then same = false end end
                for itemID, n in pairs(other.items) do if data.items[itemID] ~= n then same = false end end
            end
        end
        local m = gbDB().money
        check("what is sent is enough to rebuild the whole guild bank on another client, including who sees what",
            same and m and m.amount == money.amount and m.time == money.time and m.by == money.by and select(2, accessVersion()) == accessBefore)
        gbDB().tabs, gbDB().money, gbDB().access = snapshot, money, access
        tabs = snapshot
        check("receiving it does not make us send anything", #gbSent() == 0)
    end

    -- If someone else answers first, we stay quiet.
    gbReceive("V\t", "Nykommer-Stormrage")
    for _, message in ipairs(full) do gbReceive(message, "Altine-Stormrage") end
    flush()
    check("when another member already answered, we do not send it all again", #gbSent() == 0)

    -- A member whose versions are all the same except a newer Gear tab.
    local function versionsExcept(tab, entry)
        local parts = {}
        for n = 1, 16 do
            if tabs[n] then parts[#parts + 1] = n == tab and entry or (n .. ":" .. tabs[n].time .. ":" .. tabs[n].digest) end
        end
        parts[#parts + 1] = "0:" .. gbDB().money.time .. ":1234567"
        local accessTime, accessDigest = accessVersion()
        parts[#parts + 1] = "17:" .. accessTime .. ":" .. accessDigest
        return "V\t" .. table.concat(parts, ",")
    end
    local t2 = t1 + 100
    gbReceive(versionsExcept(2, "2:" .. t2 .. ":2.55"), "Borin-Stormrage")
    flush()
    sent = gbSent()
    check("when someone has a newer tab, we ask for it, and only for it", #sent == 1 and sent[1] == "W\t2\t" .. t2 .. "\t" .. d2, all(sent))
    local newGear = digestOf("7:2", 1)
    gbReceive("T\t2\t" .. t2 .. "\t1\t" .. newGear .. "\tBorin\tInterface\\Icons\\INV_Sword_04\tGear", "Borin-Stormrage")
    check("a tab that has only begun arriving changes nothing yet", tabs[2].time == t1)
    gbReceive("D\t2\t" .. t2 .. "\t1\t7:2", "Borin-Stormrage")
    flush()
    check("once it has all arrived, the newer tab replaces ours", gbDB().tabs[2].time == t2 and gbDB().tabs[2].by == "Borin" and gbDB().tabs[2].items[7] == 2 and gbDB().tabs[2].items[10] == nil)
    check("...and the panel shows it", gbDescribe() == "Copper Ore=20 | Iron Sword=2 | Linen Cloth=10", gbDescribe())
    check("...without us sending anything", #gbSent() == 0)
    tabs = gbDB().tabs

    -- Two others ask the same thing: one question is enough.
    gbReceive(versionsExcept(1, "1:" .. (t2 + 5) .. ":9.9"), "Borin-Stormrage")
    gbReceive("W\t1\t" .. (t2 + 5) .. "\t" .. tabs[1].digest, "Cedric-Stormrage")
    flush()
    check("someone else already asked for it, so we do not", #gbSent() == 0)

    -- A member asks for a tab: the whole of it if theirs is different, a confirmation if it is the same.
    gbReceive("W\t4\t" .. tabs[4].time .. "\t-", "Nykommer-Stormrage")
    flush()
    sent = gbSent()
    check("asked for a tab they lack: it is sent whole", #sent == 1 and sent[1]:find("^T\t4\t") ~= nil, all(sent))
    gbReceive("W\t1\t" .. tabs[1].time .. "\t" .. tabs[1].digest, "Nykommer-Stormrage")
    flush()
    sent = gbSent()
    check("asked for a tab they already have the same of: a short confirmation is enough", #sent == 1 and sent[1]:find("^C\t1\t") ~= nil, all(sent))

    -- Confirmations from others.
    gbReceive("C\t1\t" .. (t2 + 50) .. "\t" .. tabs[1].digest .. "\tCedric", "Cedric-Stormrage")
    flush()
    check("someone saw the same tab later: only the time and name change", tabs[1].time == t2 + 50 and tabs[1].by == "Cedric" and tabs[1].items[20] == 20 and #gbSent() == 0)
    gbReceive("C\t4\t" .. (t2 + 60) .. "\t3.123\tCedric", "Cedric-Stormrage")
    flush()
    sent = gbSent()
    check("someone saw something different in a tab later: we ask for it", #sent == 1 and sent[1] == "W\t4\t" .. (t2 + 60) .. "\t0.7" and tabs[4].time ~= t2 + 60, all(sent))
    gbReceive("M\t" .. (t2 + 70) .. "\t500\tCedric", "Cedric-Stormrage")
    gbReceive("M\t" .. (t2 + 10) .. "\t999\tDagny", "Dagny-Stormrage")
    flush()
    check("newer gold is taken, older is not", gbDB().money.amount == 500 and gbDB().money.by == "Cedric", gbDB().money.amount)

    -- Broken or hostile messages change nothing and raise no errors.
    clearChat()
    gbReceive("T\t1\t" .. (t2 + 90) .. "\t1\t1.5\tMallory\t1\tMats", "Mallory-Stormrage")
    gbReceive("D\t1\t" .. (t2 + 90) .. "\t1\t20:9999", "Mallory-Stormrage")
    check("a tab whose contents do not match its check sum is thrown away", tabs[1].items[20] == 20 and tabs[1].by == "Cedric")
    gbReceive("T\t1\t" .. (SERVER_NOW + 5 * 86400) .. "\t0\t0.7\tMallory\t1\tFuture", "Mallory-Stormrage")
    gbReceive("T\t99\t" .. t2 .. "\t0\t0.7\tMallory\t1\tNinetynine", "Mallory-Stormrage")
    gbReceive("D\t1\tnope", "Mallory-Stormrage")
    gbReceive("V\tgarbage", "Mallory-Stormrage")
    gbReceive("W\tx\ty", "Mallory-Stormrage")
    gbReceive("", "Mallory-Stormrage")
    gbReceive("M\t-5\t-5", "Mallory-Stormrage")
    flush()
    check("times far in the future, unknown tabs and garbage are ignored without errors",
        tabs[1].name == "Mats" and gbDB().tabs[99] == nil and #chat == 0 and gbDB().money.amount == 500, chatText())
    gbSent()

    -- Filtering on a tab.
    lastMenu = nil
    gbPanel.tabChip.scripts.OnClick(gbPanel.tabChip)
    check("the tab button opens a menu with every known tab",
        lastMenu and lastMenu.titles[1] == "Fane" and #lastMenu.radios == 4 and lastMenu.radios[1].text == "Alle" and lastMenu.radios[2].text == "Mats"
        and lastMenu.radios[3].text == "Gear" and lastMenu.radios[4].text == "Spare" and lastMenu.radios[1].selected())
    lastMenu.radios[3].click()
    check("choosing a tab shows only what is in it, and who saw it last",
        gbDescribe() == "Iron Sword=2" and gbPanel.tabChip.label.text == "Fane: Gear"
        and gbPanel.footer.text == "Denne fanen ble sist sett av Borin, DATE(" .. t2 .. ").", gbDescribe() .. " / " .. gbPanel.footer.text)
    lastMenu.radios[4].click()
    check("an empty tab says nothing was found", gbDescribe() == "" and gbPanel.empty:IsShown() and gbPanel.empty.text == "Fant ingenting med dette filteret.")
    lastMenu.radios[1].click()

    gbPanel.tabChip:Fire("OnEnter")
    check("hovering the tab button lists when each tab was last seen",
        GameTooltip:IsShown() and GameTooltip.lines[1] == "Sist sett" and GameTooltip.lines[2] == "Mats: DATE(" .. (t2 + 50) .. ") (Cedric)"
        and GameTooltip.lines[3] == "Gear: DATE(" .. t2 .. ") (Borin)", table.concat(GameTooltip.lines, " / "))
    gbPanel.tabChip:Fire("OnLeave")

    gbRow("Copper Ore"):Fire("OnEnter")
    check("hovering an item shows it and which tab it is in", GameTooltip.lines[1] == "Copper Ore" and GameTooltip.lines[#GameTooltip.lines] == "Mats: 20",
        table.concat(GameTooltip.lines, " / "))
    gbRow("Copper Ore"):Fire("OnLeave")

    gbPanel.searchBox:TypeText("  LIN ")
    check("the search box narrows the list", gbDescribe() == "Linen Cloth=10", gbDescribe())
    gbPanel.searchBox:TypeText("")

    -- An item whose name was not loaded: the guild bank had it, so we wait for the name.
    gbReceive("T\t2\t" .. (t2 + 200) .. "\t1\t" .. digestOf("10:3", 1) .. "\tBorin\t1\tGear", "Borin-Stormrage")
    gbReceive("D\t2\t" .. (t2 + 200) .. "\t1\t10:3", "Borin-Stormrage")
    flush()
    check("an item without a loaded name is shown by its number", gbDescribe() == "Copper Ore=20 | Linen Cloth=10 | item:10=3", gbDescribe())
    ITEMS[10].unloaded = nil
    fire("GET_ITEM_INFO_RECEIVED", 10, true)
    flush()
    check("...and by name once the game has it", gbDescribe() == "Copper Ore=20 | Linen Cloth=10 | Unloaded Thing=3" and gbDB().items[10].name == "Unloaded Thing", gbDescribe())
    ITEMS[10].unloaded = true

    ns.SetLanguage("en", true)
    check("Guildbank follows the language",
        gbChip.label.text == "Guild Bank" and gbPanel.title.text == "The guild bank" and gbPanel.tabChip.label.text == "Tab: All"
        and gbPanel.money.text:find("^Gold: ") ~= nil and gbPanel.headerItem.text == "Item")
    ns.SetLanguage("nb", true)

    clearChat()
    dw("debug")
    check("/dw debug has a guild bank part", has("[guildbank]") and has("fane 1 'Mats'") and has("QueryGuildBankTab=true"), chatText())
    clearChat()

    -- Who sees which tab ---------------------------------------------------------
    -- An officer (rank 1) has seen the officers' tab and says what rank 1 sees.
    local t3 = t2 + 300
    gbReceive("T\t3\t" .. t3 .. "\t1\t" .. digestOf("22:5", 1) .. "\tAltine\t133785\tOfficers", "Altine-Stormrage")
    gbReceive("D\t3\t" .. t3 .. "\t1\t22:5", "Altine-Stormrage")
    gbReceive("A\t1\t1:1:" .. t3 .. ",2:1:" .. t3 .. ",3:1:" .. t3 .. ",4:1:" .. t3, "Altine-Stormrage")
    flush()
    check("the officers' tab is stored, and that rank 1 sees it", gbDB().tabs[3] ~= nil and gbDB().access[3][1].view == true)
    check("...but rank 3, which does not see it in the game, does not see it here either",
        gbDescribe() == "Copper Ore=20 | Linen Cloth=10 | Unloaded Thing=3" and gbRow("Strange Dust") == nil, gbDescribe())
    local function menuNames()
        lastMenu = nil
        gbPanel.tabChip.scripts.OnClick(gbPanel.tabChip)
        local names = {}
        for _, radio in ipairs(lastMenu.radios) do names[#names + 1] = radio.text end
        return table.concat(names, ",")
    end
    check("...nor in the tab menu", menuNames() == "Alle,Mats,Gear,Spare", menuNames())

    guild.rankIndex = 1                                  -- promoted to officer
    fire("PLAYER_GUILD_UPDATE", "player")
    flush()
    check("promoted to rank 1: the officers' tab shows up",
        gbDescribe() == "Copper Ore=20 | Linen Cloth=10 | Strange Dust=5 | Unloaded Thing=3" and menuNames() == "Alle,Mats,Gear,Officers,Spare", gbDescribe())
    lastMenu.radios[4].click()
    check("...and can be chosen", gbPanel.tabChip.label.text == "Fane: Officers" and gbDescribe() == "Strange Dust=5")
    guild.rankIndex = nil                                -- back to rank 3
    fire("PLAYER_GUILD_UPDATE", "player")
    flush()
    check("back at rank 3 it is hidden again, and the list goes back to all tabs",
        gbPanel.tabChip.label.text == "Fane: Alle" and gbRow("Strange Dust") == nil and menuNames() == "Alle,Mats,Gear,Spare")

    -- A tab only the guild master (rank 0) has been seen to see.
    local t4 = t3 + 10
    gbReceive("T\t5\t" .. t4 .. "\t1\t" .. digestOf("21:1", 1) .. "\tTester\t1\tStash", "Altine-Stormrage")
    gbReceive("D\t5\t" .. t4 .. "\t1\t21:1", "Altine-Stormrage")
    gbReceive("A\t0\t5:1:" .. t4, "Altine-Stormrage")
    flush()
    check("a tab nobody of rank 3 or lower has been seen to see is hidden", menuNames() == "Alle,Mats,Gear,Spare", menuNames())
    gbReceive("A\t4\t5:1:" .. (t4 + 1), "Dagny-Stormrage")
    flush()
    check("once rank 4 is seen to see it, rank 3 (higher) sees it too", menuNames() == "Alle,Mats,Gear,Spare,Stash", menuNames())
    gbReceive("A\t3\t5:0:" .. (t4 + 2), "Borin-Stormrage")
    flush()
    check("when rank 3 itself is later seen not to see it, the newest report wins", menuNames() == "Alle,Mats,Gear,Spare", menuNames())

    guild.rankIndex = 9                                  -- a rank nobody has reported on
    fire("PLAYER_GUILD_UPDATE", "player")
    flush()
    check("a rank nobody of that rank or lower has reported on sees no tabs, and is told why",
        gbDescribe() == "" and gbPanel.empty:IsShown() and gbPanel.empty.text == ns.strings.nb.GB_EMPTY_HIDDEN and gbPanel.money.text ~= "")
    guild.rankIndex = nil
    fire("PLAYER_GUILD_UPDATE", "player")
    flush()

    -- Bad rank reports.
    gbReceive("A\t99\t1:0:" .. t4, "Mallory-Stormrage")
    gbReceive("A\t3\t1:0:" .. (SERVER_NOW + 5 * 86400), "Mallory-Stormrage")
    gbReceive("A\tx\ty", "Mallory-Stormrage")
    gbReceive("A\t2.5\t1:0:" .. t4, "Mallory-Stormrage")
    flush()
    check("rank reports with a strange rank or a time in the future are ignored",
        gbDB().access[1][99] == nil and gbDB().access[1][3].view == true and gbDB().access[1][2.5] == nil and #gbSent() == 0)

    -- Comparing what we know about ranks with others.
    do
        local at, ad = accessVersion()
        local mine = versionsExcept(1, "1:" .. tabs[1].time .. ":" .. tabs[1].digest)
        gbReceive((mine:gsub("17:%d+:[%d%.]+", "17:" .. (at + 50) .. ":9.9")), "Eira-Stormrage")
        flush()
        sent = gbSent()
        check("someone knows something newer about ranks: we ask for it", #sent == 1 and sent[1] == "W\t17\t" .. (at + 50) .. "\t" .. ad, all(sent))
        gbReceive((mine:gsub("17:%d+:[%d%.]+", "17:" .. at .. ":1.1")), "Eira-Stormrage")
        flush()
        sent = gbSent()
        check("as new as ours but different: we send what we know, one message per rank", #sent == 4 and count(sent, "^A\t") == 4, all(sent))
    end

    clearChat()
    dw("debug")
    check("/dw debug shows the rank and who sees what", has("min rank: 3") and has("fane 3 ses av: rank 1 ja, rank 3 nei") and has("synlig for meg: false"), chatText())
    clearChat()

    -- A bank where every tab reads as hidden has not loaded yet: it says nothing about ranks.
    for _, t in ipairs(GBANK.tabs) do t.wasViewable, t.viewable = t.viewable, false end
    do
        local before = select(2, accessVersion())
        SERVER_NOW = SERVER_NOW + 1000
        GBANK.loaded, GBANK.current = { [1] = true }, 1
        openBank()
        stayAtBank()
        closeBank()
        flush()
        sent = gbSent()
        check("a bank where no tab can be seen yet says nothing about who sees what", count(sent, "^A\t") == 0 and select(2, accessVersion()) == before, all(sent))
    end
    for _, t in ipairs(GBANK.tabs) do t.viewable, t.wasViewable = t.wasViewable, nil end

    -- A full tab of 98 different things takes several messages, and still arrives whole.
    local gearSlots = GBANK.tabs[2].slots
    local big = {}
    for slot = 1, 98 do
        ITEMS[5000 + slot] = { name = "Thing " .. slot, quality = 1, classID = 7, bind = 0 }
        big[slot] = { 5000 + slot, 100 + slot }
    end
    GBANK.tabs[2].slots = big
    GBANK.loaded, GBANK.current = { [1] = true }, 1
    openBank()
    stayAtBank()
    closeBank()
    flush()
    sent = gbSent()
    local bigTab = gbDB().tabs[2]
    local parts = count(sent, "^D\t2\t")
    check("a full tab is read whole and sent in several parts, each within the game's limit",
        bigTab.items[5001] == 101 and bigTab.items[5098] == 198 and parts >= 5 and count(sent, "^T\t2\t") == 1, parts)
    gbDB().tabs[2] = nil
    for _, message in ipairs(sent) do gbReceive(message, "Altine-Stormrage") end
    local copy = gbDB().tabs[2]
    local same = copy ~= nil and copy.digest == bigTab.digest and copy.time == bigTab.time
    for itemID, n in pairs(bigTab.items) do
        if not copy or copy.items[itemID] ~= n then same = false end
    end
    check("...and another client puts it together again exactly", same)
    for slot = 1, 98 do ITEMS[5000 + slot] = nil end
    GBANK.tabs[2].slots = gearSlots

    -- Leave things as the remaining tests expect.
    flush()
    gbSent()
    kbChip.scripts.OnClick(kbChip)
end)()

-- ============================ tab order and Forslag =============================
;(function()
    local function all(list) return table.concat(list, " ; ") end

    -- The order of the tabs, chosen under Settings.
    win.settingsChip.scripts.OnClick(win.settingsChip)
    local function orderNames()
        local names = {}
        for _, row in ipairs(settings.orderRows) do
            if row:IsShown() then names[#names + 1] = row.id end
        end
        return table.concat(names, ",")
    end
    local function chipY(id) return select(5, chipByID[id]:GetPoint(1)) end
    local function rowFor(id)
        for _, row in ipairs(settings.orderRows) do
            if row:IsShown() and row.id == id then return row end
        end
    end
    local DEFAULT_ORDER = "roster,guildchat,dungeons,guildbank,events,professions,materialer,ryddesekk,keybinds,forslag,etter,kaputt"
    check("Settings lists the tabs in the default order (the guild leader's), in the chosen language",
        settings.orderLabel.text == "Rekkefølgen på fanene til venstre (bruk pilene)" and orderNames() == DEFAULT_ORDER
        and settings.orderRows[1].name.text == ns.ModuleTitle(ns.modules.roster) and settings.orderRows[1].icon.texture == ns.modules.roster.icon, orderNames())
    check("the top tab cannot move up, and the bottom one cannot move down",
        not settings.orderRows[1].up:IsEnabled() and settings.orderRows[1].down:IsEnabled()
        and settings.orderRows[12].up:IsEnabled() and not settings.orderRows[12].down:IsEnabled())
    check("the arrows use the game's own arrow pictures", settings.orderRows[1].up.normalTexture == "Interface\\Buttons\\UI-ScrollBar-ScrollUpButton-Up"
        and settings.orderRows[1].down.disabledTexture == "Interface\\Buttons\\UI-ScrollBar-ScrollDownButton-Disabled")

    rowFor("roster").down.scripts.OnClick(rowFor("roster").down)
    check("moving Members down swaps it with Guild chat in the sidebar at once",
        chipY("guildchat") == 0 and chipY("roster") == -32 and chipY("dungeons") == -64 and orderNames():find("^guildchat,roster,dungeons,") ~= nil, orderNames())
    check("...and the order is saved", DragonworldDB.tabOrder[1] == "guildchat" and DragonworldDB.tabOrder[2] == "roster" and #DragonworldDB.tabOrder == 12)
    for _ = 1, 10 do
        local row = rowFor("forslag")
        if row.up:IsEnabled() then row.up.scripts.OnClick(row.up) end
    end
    check("a tab can be moved all the way to the top", chipY("forslag") == 0 and orderNames():find("^forslag,guildchat,roster,") ~= nil, orderNames())
    check("moving past the top does nothing", ns.MoveModule("forslag", -1) == false and chipY("forslag") == 0)

    DragonworldDB.tabOrder = { "guildbank", "nothing-here", 42, "guildbank", "forslag" }
    ns.MoveModule("forslag", 1)
    check("a saved order with unknown or repeated names still works; tabs missing from it get their default place, others come last",
        orderNames() == "roster,guildchat,dungeons,guildbank,events,professions,materialer,ryddesekk,keybinds,etter,forslag,kaputt"
        and chipY("roster") == 0 and chipY("kaputt") == -11 * 32, orderNames())
    DragonworldDB.tabOrder = { "forslag", "roster", "dungeons", "guildbank", "events", "professions", "materialer", "ryddesekk", "keybinds" }
    ns.MoveModule("etter", 1)
    check("a tab that is new since the order was saved lands right under the one before it by default (Guild chat under Members)",
        orderNames():find("^forslag,roster,guildchat,dungeons,") ~= nil, orderNames())

    ns.SetLanguage("en", true)
    check("the list follows the language", settings.orderLabel.text == "Order of the tabs on the left (use the arrows)" and rowFor("forslag").name.text == "Suggestions")
    ns.SetLanguage("nb", true)

    DragonworldDB.tabOrder = nil
    ns.MoveModule("materialer", -1)
    ns.MoveModule("materialer", 1)
    check("back to the default order", orderNames() == DEFAULT_ORDER and chipY("roster") == 0, orderNames())

    -- Forslag ---------------------------------------------------------------------
    local SUG_PREFIX = "DragonworldSug"
    local function sugDB() return DragonworldDB.modules.forslag end
    local function sugReceive(text, sender) fire("CHAT_MSG_ADDON", SUG_PREFIX, text, "GUILD", sender or "Altine-Stormrage") end
    local function sugSent() return sentNow(SUG_PREFIX) end

    check("at login Forslag says it has nothing (an empty list is just the end mark)",
        prefixes[SUG_PREFIX] == true and #SUG_LOGIN == 1 and SUG_LOGIN[1] == "Q", all(SUG_LOGIN))

    local sugChip = chipByID.forslag
    sugChip.scripts.OnClick(sugChip)
    local p = DragonworldForslagScroll.parent
    local form, detail = p.form, p.detail
    local function sugRows()
        local out = {}
        for _, row in ipairs(DragonworldForslagScroll.scrollChild.children) do
            if row:IsShown() then out[#out + 1] = row end
        end
        return out
    end
    local function sugDescribe()
        local parts = {}
        for _, row in ipairs(sugRows()) do parts[#parts + 1] = row.label.text .. " [" .. row.sub.text .. "]" end
        return table.concat(parts, " | ")
    end
    local function click(button) button.scripts.OnClick(button) end

    check("Forslag opens from its chip, in Norwegian, and explains itself when there is nothing yet",
        p:IsVisible() and sugChip.selected and sugChip.label.text == "Forslag" and sugChip.icon.texture == "Interface\\Icons\\INV_Misc_Note_01"
        and p.title.text == "Forslag til addonen" and p.newButton.label.text == "Nytt forslag" and p.filters.all.selected
        and p.filters.new.label.text == "Nye ting" and p.filters.improve.label.text == "Forbedringer"
        and p.empty:IsShown() and p.empty.text == ns.strings.nb.SUG_EMPTY and not form:IsShown() and not detail:IsShown())

    click(p.newButton)
    check("New suggestion opens the form: something new, about the whole addon",
        form:IsShown() and not p.empty:IsShown() and form.heading.text == "Nytt forslag" and form.kindNew.selected and not form.kindImprove.selected
        and form.module.label.text == "Gjelder: Hele addonen" and not form.module:IsEnabled() and form.send.label.text == "Send forslag"
        and form.cancel.label.text == "Avbryt" and form.titleLabel.text == "Overskrift:" and form.noteLabel.text == "Beskrivelse:")
    check("the description is a text field over several lines", form.noteBox.multiLine == true and form.noteBox.fontObject ~= nil)
    click(form.send)
    check("a heading is needed", form.error.text == "Skriv en overskrift først." and form:IsShown() and #sugSent() == 0)

    click(form.kindImprove)
    check("choosing Improvement lets you say what it is about", form.kindImprove.selected and not form.kindNew.selected and form.module:IsEnabled())
    lastMenu = nil
    click(form.module)
    local materialer
    for _, radio in ipairs(lastMenu.radios) do
        if radio.text == "Materialer" then materialer = radio end
    end
    check("...from a menu of the modules, or the whole addon",
        lastMenu.titles[1] == "Gjelder" and lastMenu.radios[1].text == "Hele addonen" and lastMenu.radios[1].selected() and materialer ~= nil)
    materialer.click()
    check("...and the choice is shown", form.module.label.text == "Gjelder: Materialer")

    local seam = "Det hadde vært fint å se hva som ligger i guildbanken, rett i Materialer-fanen, "
    form.titleBox:TypeText("Vis materialer fra guildbanken")
    form.noteBox:TypeText(seam .. "sammen med det jeg har selv.\nOg gjerne et søk på tvers av alt sammen, så slipper jeg å lete i hver fane for seg.")
    local t = SERVER_NOW
    click(form.send)
    local myID = "Tester-Stormrage:" .. t .. ":1"
    local mine = sugDB().items[myID]
    local expectedNote = seam .. "sammen med det jeg har selv. Og gjerne et søk på tvers av alt sammen, så slipper jeg å lete i hver fane for seg."
    check("sending stores the suggestion, and the writer agrees with it",
        mine ~= nil and mine.title == "Vis materialer fra guildbanken" and mine.kind == "I" and mine.module == "materialer" and mine.author == "Tester-Stormrage"
        and mine.note == expectedNote and mine.updated == t and mine.votes["Tester-Stormrage"].v == 1, mine and mine.note)
    local sent = sugSent()
    check("it goes to the guild: the suggestion, the description in two pieces, and the agree",
        #sent == 4 and sent[1] == "F\t" .. myID .. "\t" .. t .. "\t0\tI\tmaterialer\t2\tVis materialer fra guildbanken"
        and sent[2]:find("^N\t" .. myID:gsub("%-", "%%-") .. "\t" .. t .. "\t1\t") ~= nil and sent[3]:find("\t2\t", 1, true) ~= nil
        and sent[4] == "B\t" .. myID .. "\tTester-Stormrage,1," .. t, all(sent))
    check("the form closes and the new suggestion is shown",
        not form:IsShown() and detail:IsShown() and detail.title.text == "Vis materialer fra guildbanken"
        and detail.meta.text == "Forbedring: Materialer  -  Tester  -  DATE(" .. t .. ")" and detail.votes.text == "Enige: 1 (Tester)"
        and detail.note.text == expectedNote and detail.vote.label.text == "Ikke enig likevel" and detail.delete:IsShown() and detail.delete.label.text == "Slett")
    check("the list shows it, selected", sugDescribe() == "Vis materialer fra guildbanken [Materialer  -  Enige: 1]" and sugRows()[1].selected, sugDescribe())
    click(p.newButton)
    check("the form starts empty next time", form.titleBox:GetText() == "" and form.noteBox:GetText() == "" and form.error.text == "")
    click(form.cancel)
    check("Cancel goes back", not form:IsShown() and detail:IsShown())

    -- Round trip: a client that starts empty and receives exactly that ends up with the same.
    do
        local items = sugDB().items
        sugDB().items = {}
        for _, message in ipairs(sent) do sugReceive(message, "Altine-Stormrage") end
        local copy = sugDB().items[myID]
        check("what is sent is enough to rebuild the suggestion on another client",
            copy ~= nil and copy.title == mine.title and copy.note == mine.note and copy.kind == mine.kind and copy.module == mine.module
            and copy.updated == mine.updated and copy.author == mine.author and copy.noteParts == nil and copy.votes["Tester-Stormrage"].v == 1, copy and copy.note)
        sugDB().items = items
        flush()
        check("receiving it does not make us send anything", #sugSent() == 0)
    end

    -- Suggestions from others.
    local borinID = "Borin-Stormrage:" .. (t - 100) .. ":1"
    sugReceive("F\t" .. borinID .. "\t" .. (t - 100) .. "\t0\tN\t\t0\tDKP-modul", "Borin-Stormrage")
    sugReceive("B\t" .. borinID .. "\tBorin-Stormrage,1," .. (t - 100) .. "\tCedric-Stormrage,1," .. (t - 50) .. "\tEira-Stormrage,1," .. (t - 40), "Borin-Stormrage")
    flush()
    check("a suggestion from another member shows up; the one most agree with comes first",
        sugDescribe() == "DKP-modul [Ny ting  -  Enige: 3] | Vis materialer fra guildbanken [Materialer  -  Enige: 1]", sugDescribe())
    click(sugRows()[1])
    check("someone else's suggestion: you can agree, but not delete it",
        detail.title.text == "DKP-modul" and detail.meta.text == "Ny ting  -  Borin  -  DATE(" .. (t - 100) .. ")" and detail.votes.text == "Enige: 3 (Borin, Cedric, Eira)"
        and detail.note.text == "(ingen beskrivelse)" and detail.vote.label.text == "Enig" and not detail.delete:IsShown())
    click(detail.vote)
    sent = sugSent()
    check("agreeing is sent and counted", #sent == 1 and sent[1] == "B\t" .. borinID .. "\tTester-Stormrage,1," .. t and detail.votes.text == "Enige: 4 (Borin, Cedric, Eira, Tester)"
        and detail.vote.label.text == "Ikke enig likevel", all(sent))
    click(detail.vote)
    sent = sugSent()
    check("taking it back is sent too, newer than the agree", #sent == 1 and sent[1] == "B\t" .. borinID .. "\tTester-Stormrage,0," .. (t + 1) and detail.votes.text == "Enige: 3 (Borin, Cedric, Eira)", all(sent))

    click(p.filters.new)
    check("filter: new things", sugDescribe() == "DKP-modul [Ny ting  -  Enige: 3]" and p.filters.new.selected and not p.filters.all.selected, sugDescribe())
    click(p.filters.improve)
    check("filter: improvements", sugDescribe() == "Vis materialer fra guildbanken [Materialer  -  Enige: 1]", sugDescribe())
    click(p.filters.all)

    -- A description that arrives in pieces, one of them late.
    local cedricID = "Cedric-Stormrage:" .. t .. ":4"
    sugReceive("F\t" .. cedricID .. "\t" .. t .. "\t0\tN\t\t2\tRaid-kalender", "Cedric-Stormrage")
    sugReceive("N\t" .. cedricID .. "\t" .. t .. "\t1\tFørste del, ", "Cedric-Stormrage")
    flush()
    for _, row in ipairs(sugRows()) do if row.label.text == "Raid-kalender" then click(row) end end
    check("while the description is on its way, the suggestion says so", detail.title.text == "Raid-kalender" and detail.note.text == "(beskrivelsen er på vei)")
    flush()
    sent = sugSent()
    check("if the rest does not come, we ask for the suggestion again", count(sent, "^G\t" .. cedricID:gsub("%-", "%%-") .. "$") == 1, all(sent))
    sugReceive("N\t" .. cedricID .. "\t" .. t .. "\t2\tandre del.", "Cedric-Stormrage")
    flush()
    check("when the last piece comes, the description is whole, space at the seam included", detail.note.text == "Første del, andre del.", detail.note.text)

    -- Deleting your own.
    for _, row in ipairs(sugRows()) do if row.label.text == "Vis materialer fra guildbanken" then click(row) end end
    click(detail.delete)
    sent = sugSent()
    check("deleting your own suggestion removes it and tells the guild",
        #sent == 1 and sent[1] == "F\t" .. myID .. "\t" .. (t + 1) .. "\t1\tI\tmaterialer\t0\t" and mine.deleted == true
        and sugDescribe() == "DKP-modul [Ny ting  -  Enige: 3] | Raid-kalender [Ny ting  -  Enige: 0]" and not detail:IsShown(), all(sent))

    -- Someone logs in with nothing: they get everything, the deletion included.
    flush()
    sugSent()
    sugReceive("Q", "Nykommer-Stormrage")
    check("nothing is sent the same instant", #sugSent() == 0)
    flush()
    local full = sugSent()
    check("a member with nothing gets every suggestion, the deleted one too, with the agrees",
        count(full, "^F\t") == 3 and count(full, "^N\t") == 1 and count(full, "^B\t") == 2 and count(full, "^F\t" .. myID:gsub("%-", "%%-") .. "\t%d+\t1\t") == 1, all(full))
    sugReceive("Q", "Nykommer-Stormrage")
    for _, message in ipairs(full) do sugReceive(message, "Altine-Stormrage") end
    flush()
    check("when another member already answered, we stay quiet", #sugSent() == 0)

    -- Someone has more agrees on the DKP suggestion than we do.
    sugReceive("H\t" .. borinID .. "," .. (t - 100) .. ",5," .. (t + 50), "Borin-Stormrage")
    flush()
    sent = sugSent()
    check("when someone has newer agrees, we ask for them", count(sent, "^G\t" .. borinID:gsub("%-", "%%-") .. "$") == 1, all(sent))
    sugReceive("Q", "Borin-Stormrage")
    flush()
    sugSent()

    -- Broken or hostile messages change nothing and raise no errors.
    clearChat()
    sugReceive("F\tnoauthor\t" .. t .. "\t0\tN\t\t0\tX", "Mallory-Stormrage")
    sugReceive("F\tMallory-Stormrage:1:1\t" .. (t + 5 * 86400) .. "\t0\tN\t\t0\tFuture", "Mallory-Stormrage")
    sugReceive("F\tMallory-Stormrage:2:1\t" .. t .. "\t0\tZ\t\t0\tBad kind", "Mallory-Stormrage")
    sugReceive("F\tMallory-Stormrage:3:1\t" .. t .. "\t0\tN\t\t99\tToo many parts", "Mallory-Stormrage")
    sugReceive("B\t" .. borinID .. "\tMallory-Stormrage,7," .. t, "Mallory-Stormrage")
    sugReceive("N\t" .. cedricID .. "\t" .. t .. "\t9\tnope", "Mallory-Stormrage")
    sugReceive("", "Mallory-Stormrage")
    sugReceive("H\tgarbage", "Mallory-Stormrage")
    flush()
    check("bad suggestions, agrees and pieces are ignored without errors",
        sugDB().items["noauthor"] == nil and sugDB().items["Mallory-Stormrage:1:1"] == nil and sugDB().items["Mallory-Stormrage:2:1"] == nil
        and sugDB().items["Mallory-Stormrage:3:1"] == nil and sugDB().items[borinID].votes["Mallory-Stormrage"] == nil
        and detail.note.text ~= "nope" and #chat == 0, chatText())
    sugSent()

    -- Admin: log in with a code (only a fingerprint of it is in the addon).
    check("SHA-256 gives the standard answers",
        ns.Sha256("") == "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855"
        and ns.Sha256("abc") == "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad"
        and ns.Sha256("abcdbcdecdefdefgefghfghighijhijkijkljklmklmnlmnomnopnopq") == "248d6a61d20638b8e5c026930c3e6039a33ce45964ff2167f6ecedd419db06c1",
        ns.Sha256("abc"))
    check("the admin fingerprint is salted and repeated (same as computed outside the game)",
        ns.AdminHash("test-code") == "53ad21b07189dae7b3b20b87546e653ffd92ad5ccb807c76d850b23d81ca4c70")
    ns.ADMIN_HASH = ns.AdminHash("test-code") -- the tests use a code of their own

    for _, row in ipairs(sugRows()) do if row.label.text == "DKP-modul" then click(row) end end
    check("not admin: no buttons for marking suggestions",
        detail:IsShown() and not detail.done:IsShown() and not detail.reject:IsShown() and not detail.reopen:IsShown() and p.admin.label.text == "Admin")
    click(p.admin)
    local login = DragonworldAdminLogin
    check("the Admin button opens a login box, with the code shown as dots",
        login ~= nil and login:IsShown() and login.code.password == true and login.title.text == "Admin" and login.login.label.text == "Logg inn"
        and login.text.text == ns.strings.nb.ADM_PROMPT)
    login.code:TypeText("wrong")
    login.code.scripts.OnEnterPressed(login.code)
    check("a wrong code says so, and gives nothing", login:IsShown() and login.error.text == "Feil kode." and not ns.IsAdmin() and login.code.text == "")
    clearChat()
    login.code:TypeText("test-code")
    click(login.login)
    check("the right code logs in as admin, remembered on the account",
        not login:IsShown() and ns.IsAdmin() and DragonworldDB.admin.on == true and has("Du er logget inn som admin."), chatText())
    check("as admin: Mark as done and Reject on an open suggestion",
        detail.done:IsShown() and detail.reject:IsShown() and not detail.reopen:IsShown()
        and detail.done.label.text == "Merk som utført" and detail.reject.label.text == "Avvis" and p.admin.label.text == "Logg ut admin")

    local dkp = sugDB().items[borinID]
    sugSent()
    SERVER_NOW = SERVER_NOW + 10
    click(detail.done)
    sent = sugSent()
    check("Mark as done: the suggestion gets the status, who and when, and the guild is told",
        dkp.status == "D" and dkp.statusBy == "Tester" and dkp.statusAt == SERVER_NOW
        and #sent == 1 and sent[1] == table.concat({ "S", borinID, "D", tostring(SERVER_NOW), "Tester" }, "\t"), all(sent))
    check("...and it leaves the open list for the archive", not sugDescribe():find("DKP-modul", 1, true) and p.views.archive.label.text == "Arkiv (1)"
        and p.views.active.label.text == "Åpne", sugDescribe())

    click(p.views.archive)
    local rows = sugRows()
    check("the archive lists it, with its status", #rows == 1 and rows[1].label.text == "DKP-modul" and rows[1].sub.text:find("Utført", 1, true) ~= nil, sugDescribe())
    click(rows[1])
    check("...and shows who marked it done and when, in green; as admin it can be reopened, and there is no voting",
        detail.status:IsShown() and detail.status.text == "Utført av Tester, " .. date("%d.%m.%Y", SERVER_NOW) and detail.status.color[2] > 0.8
        and detail.reopen:IsShown() and detail.reopen.label.text == "Åpne igjen" and not detail.done:IsShown() and not detail.vote:IsShown(), detail.status.text)
    SERVER_NOW = SERVER_NOW + 10
    click(detail.reopen)
    sent = sugSent()
    check("Reopen puts it back among the open ones",
        dkp.status == nil and dkp.statusAt == SERVER_NOW and #sent == 1 and sent[1] == table.concat({ "S", borinID, "O", tostring(SERVER_NOW), "Tester" }, "\t")
        and p.views.archive.label.text == "Arkiv (0)", all(sent))
    check("an empty archive explains itself", p.empty:IsShown() and p.empty.text == ns.strings.nb.SUG_ARCHIVE_EMPTY)
    click(p.views.active)

    -- Statuses from others.
    local cedric = sugDB().items[cedricID]
    sugReceive(table.concat({ "S", cedricID, "R", tostring(SERVER_NOW + 5), "Altine" }, "\t"), "Altine-Stormrage")
    flush()
    check("a status from another admin is taken in: rejected, into the archive",
        cedric.status == "R" and cedric.statusBy == "Altine" and p.views.archive.label.text == "Arkiv (1)")
    sugReceive(table.concat({ "S", cedricID, "D", tostring(SERVER_NOW + 1), "Borin" }, "\t"), "Borin-Stormrage")
    sugReceive(table.concat({ "S", cedricID, "X", tostring(SERVER_NOW + 50), "Borin" }, "\t"), "Borin-Stormrage")
    sugReceive(table.concat({ "S", cedricID, "D", tostring(SERVER_NOW + 5 * 86400), "Borin" }, "\t"), "Borin-Stormrage")
    sugReceive("S\t" .. cedricID, "Borin-Stormrage")
    flush()
    check("an older status, an unknown one, one from the future, or a broken one is ignored", cedric.status == "R" and cedric.statusBy == "Altine")
    sugReceive(table.concat({ "S", "Dagny-Stormrage:5:1", "D", tostring(SERVER_NOW), "Altine" }, "\t"), "Altine-Stormrage")
    flush()
    sent = sugSent()
    check("a status for a suggestion we lack: kept, and the suggestion asked for",
        sugDB().items["Dagny-Stormrage:5:1"].stub and sugDB().items["Dagny-Stormrage:5:1"].status == "D" and count(sent, "^G\tDagny%-Stormrage:5:1$") == 1, all(sent))

    -- Someone's list shows they lack the status: they get it.
    local cedricVotes = 0
    for _ in pairs(cedric.votes) do cedricVotes = cedricVotes + 1 end
    sugReceive("H\t" .. cedricID .. "," .. cedric.updated .. "," .. cedricVotes .. ",0", "Eira-Stormrage")
    sugReceive("Q", "Eira-Stormrage")
    flush()
    sent = sugSent()
    check("someone whose list lacks the status gets it", count(sent, "^S\t" .. cedricID:gsub("%-", "%%-") .. "\tR\t") == 1, all(sent))

    -- Only the writer can delete a suggestion.
    local deletion = table.concat({ "F", cedricID, tostring(cedric.updated + 100), "1", "N", "", "0", "" }, "\t")
    sugReceive(deletion, "Mallory-Stormrage")
    flush()
    check("a deletion sent by someone other than the writer is ignored", not cedric.deleted and cedric.title == "Raid-kalender")
    sugReceive(deletion, "Cedric-Stormrage")
    flush()
    check("...from the writer it is taken in", cedric.deleted == true)
    sugSent()

    clearChat()
    click(p.admin)
    check("Log out admin: no more admin buttons", not ns.IsAdmin() and DragonworldDB.admin == nil and p.admin.label.text == "Admin" and has("Du er logget ut som admin."), chatText())
    ns.ADMIN_HASH = nil
    clearChat()

    ns.SetLanguage("en", true)
    check("Forslag follows the language", sugChip.label.text == "Suggestions" and p.title.text == "Suggestions for the addon"
        and p.newButton.label.text == "New suggestion" and p.filters.improve.label.text == "Improvements")
    ns.SetLanguage("nb", true)

    -- Leave things as the remaining tests expect.
    flush()
    sugSent()
    kbChip.scripts.OnClick(kbChip)
end)()

-- ========================= status pills and Dungeons ============================
;(function()
    local function all(list) return table.concat(list, " ; ") end
    local ST_PREFIX = "DragonworldSt"
    local function stReceive(text, sender) fire("CHAT_MSG_ADDON", ST_PREFIX, text, "GUILD", sender or "Altine-Stormrage") end
    local function stSent() return sentNow(ST_PREFIX) end
    local function click(button) button.scripts.OnClick(button) end
    local QUEST_ICON, DUNGEON_ICON, BUSY_ICON = "Interface\\GossipFrame\\AvailableQuestIcon", "Interface\\Icons\\Ability_DualWield", "Interface\\Icons\\Trade_Tailoring"

    check("at login the addon says it has no status, and asks the others for theirs",
        prefixes[ST_PREFIX] == true and #STATUS_LOGIN == 2 and STATUS_LOGIN[1]:find("^S\tPlayer%-1%-Tester\t%-\t%d+\t\t$") ~= nil and STATUS_LOGIN[2] == "R",
        all(STATUS_LOGIN))

    -- The three pills at the top right of the window.
    local pills = win.statusPills
    check("three status pills at the top right, in the chosen language, none of them on",
        #pills == 3 and pills[1].label.text == "Quester" and pills[2].label.text == "Dungeons" and pills[3].label.text == "Ikke forstyrr"
        and pills[1].icon.texture == QUEST_ICON and pills[2].icon.texture == DUNGEON_ICON and pills[3].icon.texture == BUSY_ICON
        and not pills[1].selected and not pills[2].selected and not pills[3].selected)
    do
        local point, _, _, x, y = pills[3]:GetPoint(1)
        local _, _, _, x1 = pills[1]:GetPoint(1)
        check("...right of the guild name and left of the close button", point == "TOPRIGHT" and x == -46 and y == -30 and x1 == -46 - 2 * 140)
    end
    pills[3]:Fire("OnEnter")
    check("hovering a pill explains it", GameTooltip:IsShown() and GameTooltip.lines[1] == "Ikke forstyrr" and GameTooltip.lines[2] == ns.strings.nb.ST_BUSY_TIP)
    pills[3]:Fire("OnLeave")

    -- The roster shows the icon by the name.
    roChip.scripts.OnClick(roChip)
    local function rosterRow(name)
        for _, row in ipairs(DragonworldRosterScroll.scrollChild.children) do
            if row:IsShown() and row.member and row.member.name == name then return row end
        end
    end
    check("no status, no icon", not rosterRow("Tester").statusIcon:IsShown())

    local t = SERVER_NOW
    click(pills[1])
    flush()
    local sent = stSent()
    check("Quester turns on, and is sent to the guild",
        pills[1].selected and not pills[2].selected and ns.GetMyStatus() == "Q" and #sent == 1 and sent[1] == "S\tPlayer-1-Tester\tQ\t" .. t .. "\t\t", all(sent))
    check("...and shows as a small icon right after the name in the roster",
        rosterRow("Tester").statusIcon:IsShown() and rosterRow("Tester").statusIcon.texture == QUEST_ICON
        and select(2, rosterRow("Tester").statusIcon:GetPoint(1)) == rosterRow("Tester").name)
    click(pills[3])
    flush()
    check("only one can be on: Ikke forstyrr replaces Quester", pills[3].selected and not pills[1].selected and ns.GetMyStatus() == "C"
        and rosterRow("Tester").statusIcon.texture == BUSY_ICON and #stSent() == 1)
    click(pills[3])
    flush()
    sent = stSent()
    check("clicking the one that is on turns it off, and that is sent too",
        not pills[3].selected and ns.GetMyStatus() == nil and not rosterRow("Tester").statusIcon:IsShown() and #sent == 1 and sent[1]:find("^S\tPlayer%-1%-Tester\t%-\t") ~= nil, all(sent))

    -- Other members.
    stReceive("S\tPlayer-1-Altine\tC\t" .. t .. "\t\t")
    stReceive("S\tPlayer-1-Borin\tQ\t" .. t .. "\t\t", "Borin-Stormrage")
    flush()
    check("another member's status shows by their name", rosterRow("Altine").statusIcon:IsShown() and rosterRow("Altine").statusIcon.texture == BUSY_ICON)
    check("...but not for someone who is offline", not rosterRow("Borin").statusIcon:IsShown())
    rosterRow("Altine"):Fire("OnEnter")
    check("...and the roster tooltip says what it means", GameTooltip.lines[3] == "Ikke forstyrr", table.concat(GameTooltip.lines, " / "))
    rosterRow("Altine"):Fire("OnLeave")
    stReceive("S\tPlayer-1-Altine\tQ\t" .. (t - 10) .. "\t\t")
    stReceive("S\tPlayer-1-Altine\tZ\t" .. (t + 10) .. "\t\t")
    stReceive("S\tPlayer-1-Altine\tQ\t" .. (t + 5 * 86400) .. "\t\t")
    stReceive("S\t\tQ\t" .. t .. "\t\t")
    stReceive("garbage")
    flush()
    check("older, unknown or future statuses are ignored", rosterRow("Altine").statusIcon.texture == BUSY_ICON and #chat == 0, chatText())

    stReceive("R", "Nykommer-Stormrage")
    flush()
    check("asked for statuses while we have none: we stay quiet", #stSent() == 0)

    -- Dungeons: the pill opens the picker.
    click(pills[2])
    local picker = DragonworldDungeonPicker
    local function checkFor(name)
        for _, check in ipairs(picker.dungeonChecks) do
            if check.dungeon.name == name then return check end
        end
    end
    check("the Dungeons pill opens a window to choose dungeons, without turning the status on yet",
        picker ~= nil and picker:IsVisible() and picker.strata == "DIALOG" and ns.GetMyStatus() == nil and not pills[2].selected
        and picker.title.text == "Hvilke dungeons vil du ta?" and picker.hint.text == "Kryss av dungeons, og hvorfor. De hvite passer leveln din (60).")
    check("every dungeon from DungeonJournal is listed with its levels, and the two raids",
        #picker.dungeonChecks == 37 and checkFor("Hall of Thanes").label.text == "Hall of Thanes (13-20)"
        and checkFor("Molten Core").label.text == "Molten Core (raid, 60)" and checkFor("Shaper's Terrace").label.text == "Shaper's Terrace (58-60)")
    check("the ones that fit your level are white, the others grey",
        colour(checkFor("Scholomance").label.color, 1, 1, 1) and colour(checkFor("Hall of Thanes").label.color, 0.55, 0.55, 0.55))
    check("three reasons to choose from", #picker.purposeChecks == 3 and picker.purposeChecks[1].label.text == "Quest-run"
        and picker.purposeChecks[2].label.text == "Loot" and picker.purposeChecks[3].label.text == "XP" and picker.whyLabel.text == "Hvorfor:")
    check("the button to stop is not there while you are not on", not picker.off:IsShown())
    click(picker.save)
    check("saving with no dungeon asks for one", picker.error.text == "Velg minst én dungeon." and picker:IsVisible() and ns.GetMyStatus() == nil)
    click(picker.fitting)
    local fitting = 0
    for _, check in ipairs(picker.dungeonChecks) do if check:GetChecked() then fitting = fitting + 1 end end
    check("'pick all that fit me' ticks every dungeon for level 60", fitting == 14 and checkFor("Molten Core"):GetChecked() and not checkFor("Uldaman"):GetChecked(), fitting)
    picker.purposeChecks[2]:SetChecked(true); click(picker.purposeChecks[2])
    picker.purposeChecks[3]:SetChecked(true); click(picker.purposeChecks[3])
    local scholo = checkFor("Scholomance")
    scholo:SetChecked(false); click(scholo)
    click(picker.save)
    flush()
    sent = stSent()
    local _, entry = ns.GetMyStatus()
    check("saving turns the status on, with the dungeons and reasons",
        ns.GetMyStatus() == "D" and entry.dungeons[25] and entry.dungeons[101] and not entry.dungeons[34] and entry.purposes.L and entry.purposes.X and not entry.purposes.Q
        and pills[2].selected and not picker:IsShown())
    check("...sent to the guild in one message",
        #sent == 1 and sent[1]:find("^S\tPlayer%-1%-Tester\tD\t%d+\t24,25,26,27,28,29,30,31,32,33,35,101,102\tLX$") ~= nil, all(sent))

    local dgChip = chipByID.dungeons
    local dg = DragonworldDungeonsScroll.parent
    local function dgRows()
        local out = {}
        for _, row in ipairs(DragonworldDungeonsScroll.scrollChild.children) do
            if row:IsShown() then out[#out + 1] = row end
        end
        return out
    end
    check("after saving, the Dungeons tab opens", dg:IsVisible() and dgChip.selected and dgChip.label.text == "Dungeons" and dgChip.icon.texture == DUNGEON_ICON
        and dg.title.text == "Hvem vil ta dungeons?" and dg.mine.label.text == "Endre mine valg")
    do
        local rows = dgRows()
        check("you are on the list, marked as you, without whisper and invite",
            #rows == 1 and rows[1].name.text == "Tester (deg)" and rows[1].level.text == "60" and rows[1].why.text == "Loot, XP"
            and rows[1].dungeons.text:find("^|cff40ff40Sunken Temple|r, |cff40ff40Blackrock Depths|r") ~= nil
            and not rows[1].whisper:IsShown() and not rows[1].invite:IsShown(), rows[1] and rows[1].dungeons.text)
    end

    -- Altine (online) is up for two dungeons, one of them one we picked too.
    stReceive("S\tPlayer-1-Altine\tD\t" .. (t + 20) .. "\t30,4\tQ")
    stReceive("S\tPlayer-1-Borin\tD\t" .. (t + 20) .. "\t30\tL", "Borin-Stormrage")   -- offline
    flush()
    do
        local rows = dgRows()
        local altine = rows[2]
        check("another member shows up after you; offline members do not",
            #rows == 2 and altine.name.text == "Altine" and altine.level.text == "58" and altine.why.text == "Quest-run"
            and altine.dungeons.text == "The Deadmines, |cff40ff40Dire Maul: North|r" and altine.whisper:IsShown() and altine.invite:IsShown()
            and altine.whisper.label.text == "Hvisk" and altine.invite.label.text == "Inviter", altine and altine.dungeons.text)
        local told, invited
        local savedTell, savedParty = ChatFrame_SendTell, C_PartyInfo
        ChatFrame_SendTell = function(name) told = name end
        C_PartyInfo = { InviteUnit = function(name) invited = name end }
        click(altine.whisper)
        click(altine.invite)
        check("Whisper and Invite use the game's own functions with the member's name", told == "Altine-Stormrage" and invited == "Altine-Stormrage")
        ChatFrame_SendTell, C_PartyInfo = savedTell, savedParty
        altine:Fire("OnEnter")
        check("hovering lists the dungeons, with ours in green", GameTooltip.lines[1] == "Altine" and GameTooltip.lines[2] == "Quest-run"
            and GameTooltip.lines[3] == "The Deadmines (17-26)" and GameTooltip.lines[4] == "Dire Maul: North (56-60)", table.concat(GameTooltip.lines, " / "))
        altine:Fire("OnLeave")
    end
    check("the roster shows the dungeon icon for Altine", (function()
        roChip.scripts.OnClick(roChip); flush()
        local ok = rosterRow("Altine").statusIcon.texture == DUNGEON_ICON
        dgChip.scripts.OnClick(dgChip)
        return ok
    end)())

    lastMenu = nil
    click(dg.filter)
    local names = {}
    for _, radio in ipairs(lastMenu.radios) do names[#names + 1] = radio.text end
    check("the filter offers only dungeons someone has picked", lastMenu.titles[1] == "Dungeon" and names[1] == "Alle" and names[2] == "The Deadmines"
        and #names == 1 + 14, table.concat(names, ","))
    for _, radio in ipairs(lastMenu.radios) do if radio.text == "The Deadmines" then radio.click() end end
    check("filtering on The Deadmines shows only Altine", #dgRows() == 1 and dgRows()[1].name.text == "Altine" and dg.filter.label.text == "Dungeon: The Deadmines")
    for _, radio in ipairs(lastMenu.radios) do if radio.text == "Molten Core" then radio.click() end end
    check("...and Molten Core only you", #dgRows() == 1 and dgRows()[1].name.text == "Tester (deg)")
    lastMenu.radios[1].click()

    stReceive("R", "Nykommer-Stormrage")
    flush()
    sent = stSent()
    check("asked for statuses while we have one: we answer once, after a little while", #sent == 1 and sent[1]:find("^S\tPlayer%-1%-Tester\tD\t") ~= nil, all(sent))

    -- The picker remembers the choice, and can turn it off.
    click(pills[2])
    check("opening the picker again shows what you chose, and the button to stop",
        picker:IsVisible() and checkFor("Blackrock Depths"):GetChecked() and not checkFor("Scholomance"):GetChecked()
        and picker.purposeChecks[2]:GetChecked() and not picker.purposeChecks[1]:GetChecked() and picker.off:IsShown() and picker.off.label.text == "Ikke lenger åpen")
    click(picker.cancel)
    check("Cancel changes nothing", not picker:IsShown() and ns.GetMyStatus() == "D")
    click(dg.mine)
    click(picker.off)
    flush()
    sent = stSent()
    check("'no longer up for it' turns the status off and tells the guild",
        ns.GetMyStatus() == nil and not pills[2].selected and #sent == 1 and sent[1]:find("^S\tPlayer%-1%-Tester\t%-\t") ~= nil
        and #dgRows() == 1 and dgRows()[1].name.text == "Altine" and dg.mine.label.text == "Jeg er åpen for dungeons", all(sent))

    -- Altine logs out.
    ROSTER[2][9] = false
    fire("GUILD_ROSTER_UPDATE")
    flush()
    check("someone who logs out leaves the list", #dgRows() == 0 and dg.empty:IsShown() and dg.empty.text == ns.strings.nb.DG_EMPTY)
    ROSTER[2][9] = true
    fire("GUILD_ROSTER_UPDATE")
    flush()

    ns.SetLanguage("en", true)
    check("the pills and the Dungeons tab follow the language",
        pills[1].label.text == "Questing" and pills[3].label.text == "Do not disturb" and dg.title.text == "Who wants to run dungeons?"
        and dgRows()[1].whisper.label.text == "Whisper")
    ns.SetLanguage("nb", true)

    clearChat()
    dw("debug")
    check("/dw debug has a status part", has("[status]") and has("andre med status:"), chatText())
    clearChat()

    -- Leave things as the remaining tests expect.
    stReceive("S\tPlayer-1-Altine\t-\t" .. (t + 100) .. "\t\t")
    stReceive("S\tPlayer-1-Borin\t-\t" .. (t + 100) .. "\t\t", "Borin-Stormrage")
    flush()
    stSent()
    kbChip.scripts.OnClick(kbChip)
end)()

-- ====================== shared profile and the member card ======================
;(function()
    local function all(list) return table.concat(list, " ; ") end
    local PF_PREFIX = "DragonworldPf"
    local function pfReceive(text, sender) fire("CHAT_MSG_ADDON", PF_PREFIX, text, "GUILD", sender or "Altine-Stormrage") end
    local function pfSent() return sentNow(PF_PREFIX) end
    local function click(button) button.scripts.OnClick(button) end

    check("at login the addon asks the others for their profiles (it had nothing readable of its own)",
        prefixes[PF_PREFIX] == true and #PROFILE_LOGIN == 1 and PROFILE_LOGIN[1] == "R", all(PROFILE_LOGIN))

    -- What the game gives about this character: points, gear and the talent tree.
    -- Legacy points: no documented function, so the addon looks for a C_...Legacy... getter.
    -- (Something else named Legacy, only to be listed by /dw debug.)
    C_LegacyTree = { GetTotalPoints = function() return 99 end, GetSpentPoints = function() return 2 end, GetPointCost = function() return 1 end }
    -- The points are the renown level of the Legacy Track faction (2802), as AltStable and LegacyNavigator read them.
    C_MajorFactions = { GetCurrentRenownLevel = function(faction) assert(faction == 2802); return 23 end }
    local gear = { [1] = 20, [16] = 7 }
    GetInventoryItemLink = function(unit, slot)
        assert(unit == "player")
        return gear[slot] and link(gear[slot]) or nil
    end
    local NODES = {
        [101] = { ID = 101, posX = 100, posY = 100, groupIDs = { 1 }, ranksPurchased = 5, activeEntry = { entryID = 1 } },
        [102] = { ID = 102, posX = 100, posY = 200, groupIDs = { 1 }, ranksPurchased = 2, entryIDs = { 2 } },
        [103] = { ID = 103, posX = 100, posY = 100, groupIDs = { 3 }, ranksPurchased = 0, activeEntry = { entryID = 3 } },
        [104] = { ID = 104, posX = 200, posY = 100, groupIDs = { 3 }, activeRank = 3, activeEntry = { entryID = 4 } },
    }
    C_ClassTalents = { GetActiveConfigID = function() return 1 end }
    C_Traits = {
        GetConfigInfo = function(id) assert(id == 1); return { treeIDs = { 10 } } end,
        GetGroupDisplayInfoByTreeID = function(tree)
            assert(tree == 10)
            return { { groupID = 3, orderIndex = 2, displayName = "Retribution" }, { groupID = 1, orderIndex = 0, displayName = "Holy" },
                     { groupID = 2, orderIndex = 1, displayName = "Protection" } }
        end,
        GetTreeNodes = function() return { 101, 102, 103, 104 } end,
        GetNodeInfo = function(config, id) return NODES[id] end,
        GetEntryInfo = function(config, entryID) return { definitionID = entryID + 1000 } end,
        GetDefinitionInfo = function(definitionID) return { spellID = definitionID + 20000 } end,
        GetMaxAvailableTraitCurrency = function(currency, flag) assert(currency == 4225 and flag == false); return 65 end,
    }
    local spellNames = { [21001] = "Divine Strength", [21002] = "Divine Intellect", [21004] = "Improved Seal" }
    local savedSpell = C_Spell
    C_Spell = { GetSpellName = function(id) return spellNames[id] end }
    HEADSLOT, MAINHANDSLOT = "Head", "Main Hand"

    local t = SERVER_NOW
    flush()                                                                   -- a minute passes, so the addon looks for the points again
    pfReceive("R", "Nykommer-Stormrage")
    check("asked for profiles, we answer after a little while, not at once", #pfSent() == 0)
    flush()
    local sent = pfSent()
    check("we send our legacy points, gear and talents",
        #sent == 3 and sent[1] == "P\tPlayer-1-Tester\t" .. t .. "\t23\t65"
        and sent[2] == "E\tPlayer-1-Tester\t" .. t .. "\t1/1\t1=20::::::::60,16=7::::::::60"
        and sent[3] == "T\tPlayer-1-Tester\t" .. t .. "\t1/1\tHoly~7~21001-5,21002-2;Protection~0~;Retribution~3~21004-3", all(sent))

    fire("PLAYER_EQUIPMENT_CHANGED", 16, false)
    flush()
    check("an equipment event with nothing really changed sends nothing", #pfSent() == 0)
    gear[16] = 6
    fire("PLAYER_EQUIPMENT_CHANGED", 16, false)
    flush()
    sent = pfSent()
    check("a real gear change sends only the gear, a little later", #sent == 1 and sent[1]:find("^E\tPlayer%-1%-Tester\t%d+\t1/1\t1=20::::::::60,16=6::::::::60$") ~= nil, all(sent))

    -- Other members.
    pfReceive("L\tPlayer-1-Altine\t" .. t .. "\t0")                         -- from 0.12/0.13: a wrong number, ignored
    pfReceive("P\tPlayer-1-Altine\t" .. t .. "\t41\t65")
    pfReceive("E\tPlayer-1-Altine\t" .. t .. "\t1/1\t1=20,16=7::::::::60")
    pfReceive("T\tPlayer-1-Altine\t" .. t .. "\t2/2\t~0~;Frost~20~21002-3")   -- the pieces may arrive in any order
    pfReceive("T\tPlayer-1-Altine\t" .. t .. "\t1/2\tArcane~31~21001-5;Fire")
    ROSTER[5].points = 12      -- Dagny: the game's achievement points, which are not legacy points (they were 0 for 2 legacy points)
    roChip.scripts.OnClick(roChip)
    fire("GUILD_ROSTER_UPDATE")
    flush()
    check("the roster has a Legacy column", roPanel.headerLegacy.text == "Legacy")
    check("...with the points members' addons have shared, and nothing for the others (achievement points are not used)",
        roRow("Tester").legacy.text == "23" and roRow("Altine").legacy.text == "41" and roRow("Dagny").legacy.text == "" and roRow("Borin").legacy.text == "",
        roRow("Tester").legacy.text .. "/" .. roRow("Altine").legacy.text .. "/" .. roRow("Dagny").legacy.text)
    -- What 0.12.0/0.13.0 stored (achievement points, 0 for someone with 2 legacy points) is thrown away.
    DragonworldDB.profilesCleaned = nil
    DragonworldDB.profiles["Player-1-Borin"] = { legacy = { points = 0, time = t } }
    fire("GUILD_ROSTER_UPDATE")
    flush()
    check("points stored by the previous versions (a wrong number) are thrown away",
        roRow("Borin").legacy.text == "" and DragonworldDB.profiles["Player-1-Borin"].legacy == nil and DragonworldDB.profilesCleaned == 1)

    -- The member card.
    roRow("Altine").scripts.OnMouseUp(roRow("Altine"), "LeftButton")
    local card = DragonworldMemberCard
    check("the card shows who it is, where, and the legacy points",
        card:IsVisible() and card.strata == "DIALOG" and card.name.text == "Altine" and card.info.text == "Level 58  -  Officer"
        and card.seen.text == "Pålogget, i Stormwind" and card.legacy.text == "Legacy-poeng: 41 / 65", card.legacy.text)
    check("talents: points in each tree", card.talentsLabel.text == "Talenter (hold over for å se alle)" and card.talents.text == "Arcane 31  /  Fire 0  /  Frost 20", card.talents.text)
    card.talentsHover:Fire("OnEnter")
    check("...and hovering lists every talent by name", table.concat(GameTooltip.lines, " / ") == "Arcane (31) /   Divine Strength 5 / Fire (0) / Frost (20) /   Divine Intellect 3",
        table.concat(GameTooltip.lines, " / "))
    card.talentsHover:Fire("OnLeave")
    do
        local rows = {}
        for _, row in ipairs(card.gearRows) do if row:IsShown() then rows[#rows + 1] = row end end
        check("gear: one line per item, with the slot, icon and name in its quality colour",
            #rows == 2 and rows[1].slot.text == "Head" and rows[1].name.text == "Copper Ore" and rows[1].icon.texture == 1020
            and rows[2].slot.text == "Main Hand" and rows[2].name.text == "Iron Sword" and card.gearWhen.text == "delt DATE(" .. t .. ")" and not card.noGear:IsShown())
        rows[2]:Fire("OnEnter")
        check("...hovering an item shows it", GameTooltip:IsShown() and GameTooltip.lines[1] == "Iron Sword")
        rows[2]:Fire("OnLeave")
    end
    check("buttons for an online member: inspect, whisper, invite, close",
        card.inspect:IsShown() and card.whisper:IsShown() and card.invite:IsShown() and card.inspect.label.text == "Inspiser" and card.close.label.text == "Lukk")

    clearChat()
    click(card.inspect)
    check("inspecting someone who is not targeted or in the group explains why it cannot", has("Altine må være target eller i gruppen din"), chatText())
    do
        local inspected
        local realGUID = UnitGUID
        UnitExists = function(unit) return unit == "target" end
        UnitGUID = function(unit) if unit == "target" then return "Player-1-Altine" end return realGUID(unit) end
        InspectUnit = function(unit) inspected = unit end
        click(card.inspect)
        check("...and with Altine as target, the game's inspect window opens", inspected == "target")
        UnitExists, InspectUnit, UnitGUID = nil, nil, realGUID
    end
    do
        local told, invited
        local savedTell, savedParty = ChatFrame_SendTell, C_PartyInfo
        ChatFrame_SendTell = function(name) told = name end
        C_PartyInfo = { InviteUnit = function(name) invited = name end }
        click(card.whisper)
        click(card.invite)
        check("whisper and invite from the card", told == "Altine-Stormrage" and invited == "Altine-Stormrage")
        ChatFrame_SendTell, C_PartyInfo = savedTell, savedParty
    end

    -- Notes.
    check("notes: empty to begin with, and labelled as private", card.notes:GetText() == "" and card.notesLabel.text == "Mine notater (bare du ser dem)" and card.notes.multiLine)
    card.notes:TypeText("Tank. God på Molten Core.")
    check("typing a note saves it at once", DragonworldDB.notes["Player-1-Altine"] == "Tank. God på Molten Core.")
    pfReceive("P\tPlayer-1-Altine\t" .. (t + 5) .. "\t42\t65")
    check("new points arriving while the card is open show at once", card.legacy.text == "Legacy-poeng: 42 / 65")
    click(card.close)
    roRow("Borin").scripts.OnMouseUp(roRow("Borin"), "LeftButton")
    check("another member's card has its own (empty) note, and nothing shared yet",
        card.name.text == "Borin" and card.notes:GetText() == "" and card.talents.text == "Ikke delt ennå." and card.noGear:IsShown()
        and card.legacy.text == "Legacy-poeng: ukjent" and card.seen.text == "Sist pålogget for 3 dager siden", card.seen.text)
    check("someone offline cannot be whispered or invited from the card", card.inspect:IsShown() and not card.whisper:IsShown() and not card.invite:IsShown())
    click(card.close)
    roRow("Altine").scripts.OnMouseUp(roRow("Altine"), "LeftButton")
    check("coming back, the note is still there", card.notes:GetText() == "Tank. God på Molten Core.")
    card.notes:TypeText("")
    check("emptying a note removes it", DragonworldDB.notes["Player-1-Altine"] == nil)
    click(card.close)

    roRow("Tester").scripts.OnMouseUp(roRow("Tester"), "LeftButton")
    check("your own card reads you directly, without inspect, whisper or invite",
        card.name.text == "Tester" and card.legacy.text == "Legacy-poeng: 23 / 65" and card.talents.text == "Holy 7  /  Protection 0  /  Retribution 3"
        and not card.inspect:IsShown() and not card.whisper:IsShown() and not card.invite:IsShown(), card.talents.text)
    pfSent()

    -- "About me": written on your own card, shown on it for everyone else.
    check("your own card has a field for what others should see about you",
        card.aboutLabel.text == "Om meg (alle med addonen ser dette)" and card.aboutBox:IsShown() and not card.aboutText:IsShown()
        and card.aboutBox:GetText() == "" and card.aboutBox.multiLine)
    card.aboutBox:TypeText("Healer. Liker dungeons\nog crafting.")
    check("what you write is kept (one line), but not sent while you type", ns.GetMyAbout() == "Healer. Liker dungeons og crafting." and #pfSent() == 0)
    card.aboutBox:Fire("OnEditFocusLost")
    local sent = pfSent()
    check("when you are done writing, it is sent to the guild",
        #sent == 1 and sent[1]:find("^A\tPlayer%-1%-Tester\t%d+\t1/1\tHealer%. Liker dungeons og crafting%.$") ~= nil, all(sent))
    click(card.close)
    check("closing the card sends nothing more when nothing changed", #pfSent() == 0)
    roRow("Tester").scripts.OnMouseUp(roRow("Tester"), "LeftButton")
    check("opening your card again shows what you wrote", card.aboutBox:GetText() == "Healer. Liker dungeons og crafting.")
    card.aboutBox:TypeText("")
    click(card.close)
    sent = pfSent()
    check("emptying it and closing the card tells the guild it is gone", #sent == 1 and sent[1]:find("^A\tPlayer%-1%-Tester\t%d+\t1/1\t$") ~= nil, all(sent))

    -- Another member's text, on their card.
    pfReceive("A\tPlayer-1-Altine\t" .. t .. "\t1/1\tTank. Spør meg om Molten Core.")
    roRow("Altine").scripts.OnMouseUp(roRow("Altine"), "LeftButton")
    check("on someone else's card you read what they wrote about themselves, and cannot edit it",
        card.aboutLabel.text == "Om Altine" and card.aboutText:IsShown() and not card.aboutBox:IsShown()
        and card.aboutText.text == "Tank. Spør meg om Molten Core." and colour(card.aboutText.color, 1, 1, 1))
    click(card.close)
    roRow("Borin").scripts.OnMouseUp(roRow("Borin"), "LeftButton")
    check("...or that nothing is written yet", card.aboutText.text == "Ikke skrevet noe ennå." and colour(card.aboutText.color, 0.55, 0.55, 0.55))
    click(card.close)
    pfReceive("A\tPlayer-1-Altine\t" .. (t - 10) .. "\t1/1\tOld text")
    roRow("Altine").scripts.OnMouseUp(roRow("Altine"), "LeftButton")
    check("an older text does not replace a newer one", card.aboutText.text == "Tank. Spør meg om Molten Core.")
    click(card.close)
    pfSent()

    -- Picking dungeons closes the card, so only one of them is on top.
    click(win.statusPills[2])
    check("opening the dungeon picker closes the card", not card:IsShown() and DragonworldDungeonPicker:IsShown())
    click(DragonworldDungeonPicker.cancel)

    -- Old or broken messages.
    clearChat()
    pfReceive("P\tPlayer-1-Altine\t" .. (t - 50) .. "\t5\t65")
    pfReceive("T\tPlayer-1-Altine\t" .. (t - 50) .. "\t1/1\tOld~1~1-1")
    pfReceive("E\tPlayer-1-Altine\t" .. t .. "\t3/2\tx")
    pfReceive("E\tPlayer-1-Altine\t" .. (t + 5 * 86400) .. "\t1/1\t1=5")
    pfReceive("P\t\t" .. t .. "\t9")
    pfReceive("nonsense")
    roRow("Altine").scripts.OnMouseUp(roRow("Altine"), "LeftButton")
    check("older, broken or future messages change nothing and raise no errors",
        card.legacy.text == "Legacy-poeng: 42 / 65" and card.talents.text == "Arcane 31  /  Fire 0  /  Frost 20" and #chat == 0, chatText())

    ns.SetLanguage("en", true)
    check("the card follows the language", card.legacy.text == "Legacy points: 42 / 65" and card.inspect.label.text == "Inspect" and card.gearLabel.text == "Gear")
    ns.SetLanguage("nb", true)
    click(card.close)

    clearChat()
    dw("debug")
    check("/dw debug shows where the points came from and everything in the game named Legacy, to find the right one",
        has("[profil]") and has("legacy-poeng: 23 av 65 | fra: C_MajorFactions.GetCurrentRenownLevel(2802)") and has("C_LegacyTree {GetPointCost, GetSpentPoints, GetTotalPoints}")
        and has("talenter: Holy 7 (2), Protection 0 (0), Retribution 3 (1)") and has("utstyr: 2 plasser") and has("valutaer:"), chatText())
    clearChat()

    -- Leave things as the remaining tests expect.
    C_LegacyTree, C_MajorFactions, GetInventoryItemLink, C_ClassTalents, C_Traits, C_Spell = nil, nil, nil, nil, nil, savedSpell
    HEADSLOT, MAINHANDSLOT = nil, nil
    ROSTER[5].points = nil
    flush()
    pfSent()
    kbChip.scripts.OnClick(kbChip)
end)()

-- ================================ Professions ===================================
;(function()
    local DATA = ns.ProfessionData
    local Crafts, Plan = ns.ProfessionStepCrafts, ns.ProfessionBuildPlan
    local function profDB() return DragonworldDB.modules.professions end
    local savedCharacter, savedBags, savedStacks, savedTradeSkill = character, BAGS, STACKS, C_TradeSkillUI
    character = { name = "Tester", realm = "Stormrage", class = "PALADIN" }
    C_TradeSkillUI = nil

    -- The data from Wowhead: every route goes from 1 to 300 without gaps, and
    -- everything it points to is there.
    do
        local problems = {}
        local count = 0
        for line, profession in pairs(DATA.professions) do
            count = count + 1
            local last = 1
            for _, step in ipairs(profession.steps) do
                if step[1] ~= last then problems[#problems + 1] = profession.name .. " gap at " .. step[1] end
                last = step[2]
                if step[3] ~= 0 then
                    local recipe = DATA.recipes[step[3]]
                    if not recipe then
                        problems[#problems + 1] = profession.name .. " missing recipe " .. step[3]
                    else
                        for _, reagent in ipairs(recipe[4]) do
                            if not DATA.items[reagent[1]] then problems[#problems + 1] = "missing item " .. reagent[1] end
                        end
                        for _, key in ipairs(recipe.tools or {}) do
                            if not DATA.tools[key] then problems[#problems + 1] = "missing tool " .. key end
                        end
                    end
                elseif not step.note then
                    problems[#problems + 1] = profession.name .. " text step without text"
                end
            end
            if last ~= 300 then problems[#problems + 1] = profession.name .. " ends at " .. last end
            for itemID, recipeID in pairs(profession.makes) do
                local recipe = DATA.recipes[recipeID]
                if not (recipe and recipe.creates == itemID) then problems[#problems + 1] = "bad maker for " .. itemID end
            end
            for _, step in ipairs(profession.steps) do
                if step.note and step.note:match("^PROF_NOTE_") then
                    for _, code in ipairs({ "en", "nb", "nl" }) do
                        ns.SetLanguage(code)
                        if ns.L[step.note] == step.note then problems[#problems + 1] = "note " .. step.note .. " missing in " .. code end
                    end
                end
            end
        end
        ns.SetLanguage("nb")
        check("the Wowhead routes for all 8 professions go from 1 to 300, and every recipe, material and note exists", count == 8 and #problems == 0, table.concat(problems, "; "))
    end

    -- The skill-up model gives what Wowhead's planner shows ("1 -> 28: 29 crafts, 32 to be safe").
    check("crafts per step match Wowhead's planner",
        Crafts(DATA.recipes[2660], 1, 28) == 29 and Crafts(DATA.recipes[2660], 1, 28, true) == 32
        and Crafts(DATA.recipes[2668], 80, 100) == 20 and Crafts(DATA.recipes[2668], 80, 100, true) == 20
        and Crafts(DATA.recipes[2674], 100, 109) == 13 and Crafts(DATA.recipes[2674], 100, 109, true) == 17
        and Crafts(DATA.recipes[8768], 125, 129) == 6 and Crafts(DATA.recipes[8768], 125, 129, true) == 10
        and Crafts(DATA.recipes[3501], 140, 175) == 37 and Crafts(DATA.recipes[3501], 140, 175, true) == 40,
        Crafts(DATA.recipes[2660], 1, 28) .. "/" .. Crafts(DATA.recipes[2660], 1, 28, true))
    check("orange recipes always give a point: one craft per point", Crafts(DATA.recipes[2668], 80, 90) == 10)

    -- Blacksmithing at 87 (cap 150), with 40 Bronze Bars and 3 Coarse Grinding Stones.
    local plan = Plan(164, 87, 150, 300, { [2841] = 40, [3478] = 3 }, false)
    local first = plan.rows[1]
    check("the route starts where you are, in the middle of the current step",
        first.kind == "step" and first.current and first.from == 87 and first.to == 90 and first.recipeID == 2668 and first.crafts == 3
        and first.mats[1][1] == 2841 and first.mats[1][2] == 18, first.from .. "-" .. first.to .. " x" .. tostring(first.crafts))
    local gates, placed = {}, true
    for index, row in ipairs(plan.rows) do
        if row.kind == "gate" then
            gates[#gates + 1] = row.rank .. "@" .. row.before
            if not (plan.rows[index + 1].to > row.before and plan.rows[index - 1].to <= row.before) then placed = false end
        end
    end
    check("ranks you have not learned show up just before the step that needs them (Expert before 150, Artisan before 225)",
        table.concat(gates, ",") == "2@150,3@225" and placed, table.concat(gates, ","))
    local function shopEntry(p, itemID)
        for _, entry in ipairs(p.shop) do if entry.itemID == itemID then return entry end end
    end
    local function makeEntry(p, itemID)
        for _, entry in ipairs(p.make) do if entry.itemID == itemID then return entry end end
    end
    local bronze = shopEntry(plan, 2841)
    local bronzeNeed = 0
    for _, row in ipairs(plan.rows) do
        for _, mat in ipairs(row.mats or {}) do if mat[1] == 2841 then bronzeNeed = bronzeNeed + mat[2] end end
    end
    check("the shopping list adds up the whole route and takes off what you have",
        bronze and bronze.need == bronzeNeed and bronze.have == 40 and bronze.missing == bronzeNeed - 40 and bronze.row == 1, bronze and bronze.missing)
    local coarse = makeEntry(plan, 3478)
    local coarseStone = shopEntry(plan, 2836)
    local bracers
    for _, row in ipairs(plan.rows) do if row.recipeID == 2672 then bracers = row end end
    check("things you make yourself on the way (grinding stones) use what you have first, and their materials go on the list",
        coarse and bracers and coarse.crafts == bracers.crafts * 2 - 3 and coarse.have == 3 and shopEntry(plan, 3478) == nil
        and coarseStone and coarseStone.need == coarse.crafts * 2 and coarseStone.missing == coarseStone.need, coarse and coarse.crafts)
    local hammer = plan.tools[1]
    check("the tools the route needs are listed", hammer and hammer.name == "Blacksmith Hammer" and hammer.items[1] == 5956 and #plan.tools == 1)
    check("finished steps are gone: nothing below 87 is on the route", (function()
        for _, row in ipairs(plan.rows) do if row.kind == "step" and row.from < 87 then return false end end
        return true
    end)())

    -- Engineering from 1: the powder made for skill in the first step is used by the bombs later.
    local eng = Plan(202, 1, 0, 300, {}, false)
    local powder = makeEntry(eng, 4357)
    local rough = shopEntry(eng, 2835)
    local bombs
    for _, row in ipairs(eng.rows) do if row.recipeID == 3923 then bombs = row end end
    check("what an earlier step makes is used by later steps, and only the rest is made extra",
        powder and bombs and rough and powder.crafts == bombs.crafts * 2 - eng.rows[1].crafts and rough.need == eng.rows[1].crafts + powder.crafts,
        powder and (powder.crafts .. " extra, rough stone " .. rough.need))
    local spanner
    for _, tool in ipairs(eng.tools) do if tool.key == "c14" then spanner = tool end end
    check("a tool the route makes itself (Arclight Spanner) says so", spanner and spanner.madeIn ~= nil)
    check("a profession you have not learned shows every rank", (function()
        local n = 0
        for _, row in ipairs(eng.rows) do if row.kind == "gate" then n = n + 1 end end
        return n == 3
    end)())
    local engTo225 = Plan(202, 1, 0, 225, {}, false)
    check("a lower goal stops the route there", engTo225.rows[#engTo225.rows].to == 225 and engTo225.crafts < eng.crafts)
    local engSafe = Plan(202, 1, 0, 300, {}, true)
    check("'a little extra' counts more crafts", engSafe.crafts > eng.crafts, engSafe.crafts .. " vs " .. eng.crafts)
    local ench = Plan(333, 5, 75, 300, {}, false)
    check("Enchanting's disenchant step has no recipe: one point per disenchant",
        ench.rows[1].recipeID == 0 and ench.rows[1].crafts == 15 and ench.rows[1].note == "PROF_NOTE_DISENCHANT")

    -- The tab. Tester has Mining 225/300, Engineering 210/225 and Cooking 150/225.
    ITEMS[3860] = { name = "Mithril Bar", quality = 1, classID = 7, sub = 7, bind = 0 }
    ITEMS[4338] = { name = "Mageweave Cloth", quality = 1, classID = 7, sub = 5, bind = 0 }
    ITEMS[10505] = { name = "Solid Blasting Powder", quality = 1, classID = 7, sub = 1, bind = 0 }
    ITEMS[6219] = { name = "Arclight Spanner", quality = 1, classID = 2, bind = 0 }
    BAGS = { [0] = { 3860, 4338, 6219 }, [1] = {}, [2] = {}, [6] = { 3860 } }
    STACKS = { ["0:1"] = 20, ["0:2"] = 5, ["6:1"] = 15 }
    fire("BAG_UPDATE_DELAYED")
    flush()
    local me = profDB().characters["Tester-Stormrage"]
    check("the bags are read for the things the routes use", me and me.bags[3860] == 20 and me.bags[4338] == 5 and me.bags[6219] == 1, me and tostring(me.bags[3860]))
    bankIsOpen = true
    fire("BANKFRAME_OPENED")
    flush()
    check("the bank is read while it is open", me.bank[3860] == 15 and me.bankTime == NOW, tostring(me.bank[3860]))
    bankIsOpen = false
    fire("BANKFRAME_CLOSED")

    ns.OpenModule("professions")
    local profPanel = DragonworldProfessionsScroll and DragonworldProfessionsScroll.parent
    check("the Professions tab opens", win:IsShown() and profPanel ~= nil and profPanel:IsVisible())
    local function shownRows()
        local list = {}
        for _, row in ipairs(profPanel.content.children) do
            if row:IsShown() then list[#list + 1] = row end
        end
        return list
    end
    local chips = profPanel.professionChips
    check("your own professions with a route get a chip, crafting first (Mining has no route)",
        chips[1]:IsShown() and chips[1].label.text == "Engineering" and chips[1].selected and chips[2]:IsShown() and chips[2].label.text == "Cooking"
        and not chips[3]:IsShown() and profPanel.otherChip.label.text == "Andre", chips[1].label.text)
    check("the status line shows your skill and what is left",
        profPanel.status.text:find("Engineering: 210 / 225", 1, true) ~= nil and profPanel.status.text:find("crafts igjen til 300", 1, true) ~= nil, profPanel.status.text)
    local list = shownRows()
    check("the route starts at your skill: Unstable Trigger 210 - 215, marked as the current step",
        list[1].range.text == "210 - 215" and list[1].name.text == "Unstable Trigger" and list[1].right.text:find("crafts", 1, true) ~= nil
        and list[1].detail.text:find("Mithril Bar", 1, true) ~= nil and list[1].source.text == "Trainer", list[1].range.text .. " " .. list[1].name.text)
    check("the rank you need next is in the route, and says you can learn it now (level 60, skill 210)",
        list[2].name.text:find("Lær Artisan før 225 hos en trainer", 1, true) ~= nil and list[2].name.text:find("du kan lære den nå", 1, true) ~= nil, list[2].name.text)
    check("the footer says where the route is from and when the bank was read",
        profPanel.footer.text:find("Wowhead «Tried & Tested in Forever»", 1, true) ~= nil and profPanel.footer.text:find("Banken lest", 1, true) ~= nil, profPanel.footer.text)

    list[1].scripts.OnEnter(list[1])
    local tip = table.concat(GameTooltip.lines, " / ")
    check("hovering a step shows the recipe, the colours and each material with what you have",
        GameTooltip.lines[1] == "Unstable Trigger" and tip:find("Oransje til 200", 1, true) ~= nil and tip:find("Mithril Bar", 1, true) ~= nil
        and tip:find("du har 35", 1, true) ~= nil and tip:find("Trainer", 1, true) ~= nil, tip)
    list[1].scripts.OnLeave(list[1])

    profPanel.shopChip.scripts.OnClick(profPanel.shopChip)
    list = shownRows()
    local mithrilRow
    for _, row in ipairs(list) do if row.name.text:find("Mithril Bar", 1, true) then mithrilRow = row end end
    check("the shopping list has a heading and shows need, have and missing",
        list[1].name.text == "Må skaffes" and mithrilRow ~= nil and mithrilRow.right.text:find("har 35", 1, true) ~= nil
        and mithrilRow.right.text:find("mangler", 1, true) ~= nil, mithrilRow and mithrilRow.right.text)
    local spannerRow
    for _, row in ipairs(list) do if row.name.text:find("Arclight Spanner", 1, true) then spannerRow = row end end
    check("tools you carry are marked as there", spannerRow ~= nil and spannerRow.right.text:find("i baggene", 1, true) ~= nil, spannerRow and spannerRow.right.text)

    -- The tooltip on the item itself says how many more you need.
    local lines = hover(3860)
    check("the item's own tooltip says how many more you need (for the auction house)",
        table.concat(lines, " / "):find("Dragonworld: Engineering trenger %d+ til %(du har 35%)") ~= nil, table.concat(lines, " / "))
    check("items the routes do not use get no extra line", not table.concat(hover(5), " / "):find("Dragonworld:", 1, true))

    -- Another character's things count when you tick "Other characters".
    profDB().characters["Altine-Stormrage"] = { name = "Altine", bags = { [3860] = 100 }, bank = {} }
    local function mithrilText()
        for _, row in ipairs(shownRows()) do if row.name.text:find("Mithril Bar", 1, true) then return row.right.text end end
        return ""
    end
    check("by default only this character counts", mithrilText():find("har 35", 1, true) ~= nil, mithrilText())
    profPanel.altsCheck:SetChecked(true)
    profPanel.altsCheck.scripts.OnClick(profPanel.altsCheck)
    check("ticking 'Andre karakterer' counts the others too, and is saved", profDB().alts == true and mithrilText():find("har 135", 1, true) ~= nil, mithrilText())
    profPanel.altsCheck:SetChecked(false)
    profPanel.altsCheck.scripts.OnClick(profPanel.altsCheck)
    local function needOf(text) return tonumber(text:match("trenger (%d+)")) or 0 end
    local averageNeed = needOf(mithrilText())
    profPanel.safeCheck:SetChecked(true)
    profPanel.safeCheck.scripts.OnClick(profPanel.safeCheck)
    check("'Litt ekstra' asks for a bit more", profDB().safe == true and needOf(mithrilText()) > averageNeed, mithrilText())
    profPanel.safeCheck:SetChecked(false)
    profPanel.safeCheck.scripts.OnClick(profPanel.safeCheck)

    -- Goal: only up to 225.
    profPanel.targetChip.scripts.OnClick(profPanel.targetChip)
    check("the goal menu offers the caps above your skill", lastMenu and #lastMenu.radios == 2 and lastMenu.radios[1].text == "225" and lastMenu.radios[2].text == "300")
    lastMenu.radios[1].click()
    check("choosing 225 shortens the list and is remembered for this profession",
        me.targets[202] == 225 and profPanel.targetChip.label.text == "Mål: 225" and needOf(mithrilText()) < averageNeed, profPanel.targetChip.label.text)
    me.targets[202] = nil

    -- Another profession, one you do not have.
    profPanel.routeChip.scripts.OnClick(profPanel.routeChip)
    profPanel.otherChip.scripts.OnClick(profPanel.otherChip)
    check("the menu lists all 8 professions, with your skill on your own", lastMenu and #lastMenu.radios == 8 and lastMenu.radios[1].text == "Alchemy"
        and lastMenu.radios[4].text == "Engineering (210)" and lastMenu.radios[7].text == "Cooking (150)", lastMenu and lastMenu.radios[4].text)
    lastMenu.radios[2].click() -- Blacksmithing
    list = shownRows()
    check("a profession you do not have shows the whole route from 1",
        profPanel.status.text:find("Blacksmithing: ikke lært", 1, true) ~= nil and list[1].range.text == "1 - 30" and list[1].source.text == "Kan fra start"
        and profPanel.otherChip.selected and profPanel.otherChip.label.text == "Blacksmithing", profPanel.status.text)
    check("the choice is remembered for the character", me.selected == 164)

    -- Recipes you know, read from your own profession window.
    C_TradeSkillUI = {
        GetAllRecipeIDs = function() return { 3320, 2661 } end,
        GetRecipeInfo = function(id) return { learned = id == 3320 } end,
        IsTradeSkillLinked = function() return false end,
    }
    fire("TRADE_SKILL_SHOW")
    flush()
    list = shownRows()
    check("recipes you know are marked as learned", me.known[3320] == true and me.known[2661] == nil and list[2].source.text:find("Lært", 1, true) ~= nil, list[2].source.text)
    me.known = {}
    C_TradeSkillUI.IsTradeSkillLinked = function() return true end
    fire("TRADE_SKILL_SHOW")
    flush()
    check("someone else's profession window does not count", next(me.known) == nil)
    C_TradeSkillUI = nil

    ns.SetLanguage("en", true)
    check("the tab follows the language", profPanel.status.text:find("Blacksmithing: not learned", 1, true) ~= nil and profPanel.routeChip.label.text == "Route"
        and profPanel.safeCheck.label.text == "A little extra", profPanel.status.text)
    ns.SetLanguage("nb", true)

    chips[1].scripts.OnClick(chips[1])
    check("clicking your own profession's chip goes back to it", me.selected == 202 and chips[1].selected and not profPanel.otherChip.selected)

    clearChat()
    dw("debug")
    check("/dw debug shows what the Professions tab reads", has("[professions]") and has("med rute: Cooking 150/225, Engineering 210/225"), chatText())
    clearChat()

    -- Leave things as the remaining tests expect.
    profDB().characters["Altine-Stormrage"] = nil
    character, BAGS, STACKS, C_TradeSkillUI = savedCharacter, savedBags, savedStacks, savedTradeSkill
    fire("BAG_UPDATE_DELAYED")
    flush()
    kbChip.scripts.OnClick(kbChip)
end)()

-- ================================ guild lock ====================================
local function setGuild(name)
    guild.inGuild = name ~= nil
    guild.name = name
    fire("PLAYER_GUILD_UPDATE", "player")
end
check("a member of Dragonworld sees everything", ns.IsMember() and win:IsShown() and mm:IsShown())

setGuild("Other Guild")
check("in another guild: the window closes and the minimap button disappears", not ns.IsMember() and not win:IsShown() and not mm:IsShown())
check("...there are no lines in tooltips", verdict(5) == nil)
clearChat()
dw("")
check("...and /dw explains why, in the chosen language, naming the guild the character is in",
    has("bare for medlemmer av guilden Dragonworld") and has("i guilden Other Guild") and not win:IsShown(), chatText())
clearChat()
kast("")
check("...the module commands are locked as well", has("bare for medlemmer av guilden Dragonworld") and not win:IsShown(), chatText())
kast("merk " .. link(4))
check("...including the ones that change something", saved().marks[4] == nil)

do
    local keysBefore = keysOf("ACTIONBUTTON1")
    flush()
    BAGS[0][1] = 20
    fire("BAG_UPDATE_DELAYED")
    flush()
    activeSpec = (activeSpec == 1) and 2 or 1
    fire(ATGC, activeSpec, 0)
    check("while locked, materials are not recorded and keybinds are not switched", me.bags[20] == nil and keysOf("ACTIONBUTTON1") == keysBefore)
end

setGuild("Dragonworld Reborn")
check("a guild with a different name stays locked", not ns.IsMember())
setGuild("dragon world")
check("capitals and spaces in the guild name do not matter", ns.IsMember() and mm:IsShown())

-- Logging in before the game has the guild name: it is checked again shortly after.
guild.name = nil
guild.inGuild = false
fire("PLAYER_ENTERING_WORLD")
check("at login without guild data the addon is locked, and a re-check is scheduled", not ns.IsMember() and queued(3) == 1 and queued(10) == 1)
guild.inGuild = true
guild.name = "Dragonworld"
flush()                                   -- no guild event arrives; only the scheduled re-check runs
check("the scheduled re-check unlocks once the name is there", ns.IsMember() and mm:IsShown())
flush()

setGuild(nil)
clearChat()
dw("")
check("a character with no guild is told so", has("ikke i en guild"), chatText())
guild.inGuild = true
guild.name = nil
fire("GUILD_ROSTER_UPDATE")
check("a guild whose name has not loaded yet does not unlock anything", not ns.IsMember() and not mm:IsShown())

setGuild("Dragonworld")
check("joining Dragonworld unlocks: the button and the tooltips are back", ns.IsMember() and mm:IsShown() and verdict(5) == "Kan trolig kastes", (verdict(5)))
flush()
check("...and the bags are read to catch up", me.bags[20] == 1)
BAGS[0][1] = false

guild.name = nil
fire("PLAYER_GUILD_UPDATE", "player")
check("a member is not locked out when the name is briefly unavailable", ns.IsMember() and mm:IsShown())
guild.name = "Dragonworld"

ns.SetMinimapButtonShown(false)
setGuild("Other Guild")
setGuild("Dragonworld")
check("a hidden minimap button stays hidden after re-joining", ns.IsMember() and not mm:IsShown())
ns.SetMinimapButtonShown(true)

-- Leave things as the remaining tests expect: window open on Ryddesekk.
fire("BAG_UPDATE_DELAYED")
flush()
clearChat()
ns.OpenModule("ryddesekk")
check("the window opens again for a member", win:IsShown() and rsPanel:IsVisible() and describe() == "Faded Letter=Kan trolig kastes | Qiraji Bindings=Sjekk før du kaster", describe())

-- ================================== /dw =========================================
dw("")
check("/dw closes the open window", not win:IsShown())
dw("")
check("/dw opens it again, on what was showing last", win:IsShown() and rsPanel:IsVisible() and rsChip.selected)
check("/dw (nil message) does not error", pcall(dw, nil) and not win:IsShown())
dw("etter")
check("/dw <module> opens the window on that module", win:IsShown() and etterPanel:IsVisible() and etterChip.selected)
dw("  RyddeSekk  ")
check("/dw is not case- or space-sensitive", rsPanel:IsVisible() and rsChip.selected)
dw("ryddesekk")
check("/dw ryddesekk when it is already showing closes the window", not win:IsShown())
clearChat()
dw("ryddesekk liste")
check("/dw ryddesekk liste passes the rest on to the module", has("[Qiraji Bindings]") and not win:IsShown(), chatText())
clearChat()
dw("hjelp")
check("/dw <anything else> lists the commands in the chosen language",
    has("Kommandoer:") and has("/dw - åpner Dragonworld") and has("/kast - Ryddesekk: viser hvilke quest-gjenstander")
    and has("/dw boom - Boom: kaster feil") and has("/dw knapp - skjuler eller viser"), chatText())
clearChat()
dw("boom")
check("/dw <module with nothing to open> lists the commands", has("Kommandoer:"), chatText())

-- ============================ minimap button ====================================
local function near(a, b) return math.abs(a - b) < 0.001 end
local function mmPoint() local point, relTo, relPoint, x, y = mm:GetPoint(1); return point, relTo, relPoint, x, y end
do
    local point, relTo, relPoint, x, y = mmPoint()
    check("button sits on the minimap edge at the saved angle (90 = straight up)",
        mm.parent == Minimap and point == "CENTER" and relTo == Minimap and relPoint == "CENTER" and near(x, 0) and near(y, 75) and select("#", mm:GetPoint(2)) == 0,
        tostring(x) .. "," .. tostring(y))
end
check("button is shown and uses the round guild icon", mm:IsShown() and mm.icon.texture == "Interface\\AddOns\\Dragonworld\\Media\\minimap", mm.icon.texture)

mm.scripts.OnClick(mm, "LeftButton")
lastMenu = nil
check("clicking the button opens the main window (no dropdown)", win:IsShown() and lastMenu == nil)
mm.scripts.OnClick(mm, "LeftButton")
check("clicking it again closes the window", not win:IsShown())

mm.scripts.OnDragStart(mm)
check("dragging starts following the cursor", type(mm.scripts.OnUpdate) == "function")
cursor = { 600, 500 }                     -- straight right of the minimap centre
mm.scripts.OnUpdate(mm, 0.01)
do
    local _, _, _, x, y = mmPoint()
    check("cursor to the right -> angle 0, button at the right edge", near(DragonworldDB.minimap.angle, 0) and near(x, 75) and near(y, 0), tostring(x) .. "," .. tostring(y))
end
cursor = { 500, 400 }                     -- straight below
mm.scripts.OnUpdate(mm, 0.01)
do
    local _, _, _, x, y = mmPoint()
    check("cursor below -> angle 270, button at the bottom edge", near(DragonworldDB.minimap.angle, 270) and near(x, 0) and near(y, -75), tostring(x) .. "," .. tostring(y))
end
Minimap.scale = 2                         -- UI scale: cursor is in screen pixels
cursor = { 1000, 1200 }                   -- = (500, 600) in minimap units: straight up
mm.scripts.OnUpdate(mm, 0.01)
check("cursor position is corrected for UI scale", near(DragonworldDB.minimap.angle, 90), DragonworldDB.minimap.angle)
Minimap.scale = 1
mm.scripts.OnDragStop(mm)
check("dropping stops following the cursor", mm.scripts.OnUpdate == nil)

GetMinimapShape = function() return "SQUARE" end
DragonworldDB.minimap.angle = 45
fire("PLAYER_LOGIN")
do
    local _, _, _, x, y = mmPoint()
    local want = math.cos(math.rad(45)) * (math.sqrt(2 * 75 ^ 2) - 10)
    check("square minimap: 45 degrees goes out towards the corner", near(x, want) and near(y, want) and x > 60, tostring(x) .. "," .. tostring(y))
end
DragonworldDB.minimap.angle = 0
fire("PLAYER_LOGIN")
do
    local _, _, _, x, y = mmPoint()
    check("square minimap: straight right is clamped to the edge", near(x, 75) and near(y, 0), tostring(x) .. "," .. tostring(y))
end
GetMinimapShape = nil

mm.scripts.OnEnter(mm)
check("hover tooltip is in the chosen language",
    GameTooltip:IsShown() and GameTooltip.owner == mm and #GameTooltip.lines == 3 and GameTooltip.lines[1] == "Dragonworld" and GameTooltip.lines[2] == "Klikk for å åpne Dragonworld.",
    table.concat(GameTooltip.lines, " / "))
mm.scripts.OnLeave(mm)
check("leaving hides the tooltip", not GameTooltip:IsShown())

clearChat()
dw("knapp")
check("/dw knapp hides the button and saves that", not mm:IsShown() and DragonworldDB.minimap.hide == true and has("skjult"), chatText())
win.settingsChip.scripts.OnClick(win.settingsChip)
dw("")
check("Settings shows the button as off after /dw knapp", win:IsShown() and settings:IsVisible() and settings.minimapCheck.checked == false)
dw("BUTTON")
check("/dw button (English word) shows it again", mm:IsShown() and DragonworldDB.minimap.hide == nil)
dw("knop")
check("/dw knop (Dutch word) hides it", not mm:IsShown())
dw("knapp")
rsChip.scripts.OnClick(rsChip)

-- ======================== Chat og logg (Guildchat.lua) ==========================
;(function()
    local function click(button) button.scripts.OnClick(button) end
    local function lines(frame) local out = {}; for _, m in ipairs(frame.messages or {}) do out[#out + 1] = m.text end; return out end
    local gcChip = chipByID.guildchat
    check("Chat & Log has a tab, with a speech bubble", gcChip ~= nil and gcChip.label.text == "Chat og logg" and gcChip.icon.texture == "Interface\\GossipFrame\\GossipGossipIcon")
    ns.OpenModule("guildchat")
    local gc
    for _, child in ipairs(win.content.children) do
        if child.chat and child.log and child.views then gc = child end
    end
    check("empty at first: it says where the chat will come from, with the guild message on top",
        gc ~= nil and gc:IsVisible() and gc.chat:IsShown() and gc.chatInput:IsShown() and not gc.log:IsShown()
        and lines(gc.chat)[1] == ns.strings.nb.GC_EMPTY and gc.motd.text == "Guildmelding: Raid fredag kl 20!"
        and gc.chat.hyperlinks == true and gc.chat.fading == false and gc.chat.mouseWheel == true)

    fire("CHAT_MSG_GUILD", "Hei alle!", "Altine-Stormrage", "Common", "", "Altine", "", 0, 0, "", 7, 1234, "Player-1-Altine")
    local stored = DragonworldDB.modules.guildchat.messages
    local want = "|cff909090[" .. date("%H:%M", NOW) .. "]|r |Hplayer:Altine-Stormrage|h[|cff40c7ebAltine|r]|h: Hei alle!"
    check("a guild chat message shows with the time, the name in its class colour as a link, and the text, in guild green",
        #stored == 1 and stored[1].from == "Altine-Stormrage" and stored[1].text == "Hei alle!"
        and #gc.chat.messages == 1 and gc.chat.messages[1].text == want and gc.chat.messages[1].g == 1.0, lines(gc.chat)[1])
    fire("CHAT_MSG_GUILD", SECRET, "Altine-Stormrage")
    fire("CHAT_MSG_GUILD", "hemmelig", SECRET)
    check("messages the game keeps secret are skipped", #stored == 1)
    gc.chat.scripts.OnHyperlinkClick(gc.chat, "player:Altine-Stormrage", "|Hplayer:Altine-Stormrage|h[Altine]|h", "LeftButton")
    check("clicking the name works like in the chat window", itemRefs[#itemRefs].link == "player:Altine-Stormrage")

    local before = #guildChat
    gc.input = gc.chatInput
    gc.send = gc.chatInput.button
    gc.input:TypeText("Hei | tilbake ")
    gc.input.scripts.OnEnterPressed(gc.input)
    check("Enter sends it to the guild chat ('|' replaced, spaces trimmed) and empties the field",
        #guildChat == before + 1 and guildChat[#guildChat].text == "Hei / tilbake" and guildChat[#guildChat].chatType == "GUILD" and gc.input.text == "")
    gc.input:TypeText("   ")
    click(gc.send)
    check("an empty message is not sent", #guildChat == before + 1)
    chatLock = true
    clearChat()
    gc.input:TypeText("hei")
    click(gc.send)
    check("when the game blocks chat, the player is told and the text is kept",
        #guildChat == before + 1 and has(ns.strings.nb.GC_BLOCKED) and gc.input.text == "hei", chatText())
    chatLock = false
    clearChat()
    gc.input:SetText("")

    for i = 1, 305 do fire("CHAT_MSG_GUILD", "m" .. i, "Borin-Stormrage") end
    check("the last 300 messages are kept", #stored == 300 and stored[1].text == "m6" and stored[300].text == "m305")


    -- Whispers: every conversation, in and out, so it can be picked up again.
    click(gc.views.whisper)
    check("Whispers: empty at first, and says what will show up",
        gc.whisperChat:IsShown() and not gc.chat:IsShown() and not gc.chatInput:IsShown() and lines(gc.whisperChat)[1] == ns.strings.nb.GC_WHISPER_EMPTY
        and not gc.whisperInput:IsShown() and gc.views.whisper.label.text == "Hvisking" and gc.views.whisper.selected)
    click(gc.views.chat)
    local realTime = time
    local clockNow = NOW
    time = function(t) if t ~= nil then return realTime(t) end return clockNow end
    fire("CHAT_MSG_WHISPER", "Hei, skal vi ta Deadmines?", "Altine-Stormrage")
    clockNow = NOW + 60
    fire("CHAT_MSG_WHISPER", "Hallo der", "Zed-Otherrealm")
    fire("CHAT_MSG_WHISPER", SECRET, "Altine-Stormrage")
    local whispers = DragonworldDB.modules.guildchat.whispers
    check("whispers coming in are kept per person (guild or not) and counted as unread; secret ones are skipped",
        whispers.altine.unread == 1 and whispers.zed.unread == 1 and #whispers.altine.messages == 1 and whispers.zed.name == "Zed-Otherrealm"
        and gc.views.whisper.label.text == "Hvisking (2)", gc.views.whisper.label.text)

    click(gc.views.whisper)
    local rows = gc.whisperRows
    check("the list: newest conversation first, unread in brackets, guild members in class colour; the newest one opens and is read",
        rows[1]:IsShown() and rows[1].label.text == "|cffc8c8c8Zed|r" and rows[1].selected
        and rows[2].label.text == "|cffffd100(1)|r |cff40c7ebAltine|r" and not rows[2].selected
        and rows[1].sub.text == date("%H:%M", NOW + 60) .. "  Hallo der" and whispers.zed.unread == 0 and gc.views.whisper.label.text == "Hvisking (1)",
        rows[1].label.text .. " / " .. rows[2].label.text .. " / " .. tostring(rows[1].sub.text))
    check("...with the whole conversation, date and time on each line",
        gc.whisperName.text == "|cffc8c8c8Zed|r" and lines(gc.whisperChat)[1] == "|cff909090[" .. date("%d.%m %H:%M", NOW + 60) .. "]|r |Hplayer:Zed-Otherrealm|h[|cffc8c8c8Zed|r]|h: Hallo der"
        and gc.whisperChat.messages[1].r == 1.00 and gc.whisperChat.messages[1].g == 0.50, lines(gc.whisperChat)[1])

    click(rows[2])
    check("clicking a conversation opens it and marks it read", gc.whisperName.text == "|cff40c7ebAltine|r" and whispers.altine.unread == 0
        and gc.views.whisper.label.text == "Hvisking" and rows[1].label.text == "|cffc8c8c8Zed|r" and rows[2].selected)
    local sentBefore = #guildChat
    gc.whisperInput:TypeText("Ja, om 10 min")
    gc.whisperInput.scripts.OnEnterPressed(gc.whisperInput)
    check("the field at the bottom answers with a whisper to that person",
        #guildChat == sentBefore + 1 and guildChat[#guildChat].chatType == "WHISPER" and guildChat[#guildChat].target == "Altine-Stormrage"
        and guildChat[#guildChat].text == "Ja, om 10 min" and gc.whisperInput.text == "")
    clockNow = NOW + 120
    fire("CHAT_MSG_WHISPER_INFORM", "Ja, om 10 min", "Altine-Stormrage") -- the game confirms what was sent
    fire("CHAT_MSG_WHISPER", "Supert!", "Altine-Stormrage")
    local l = lines(gc.whisperChat)
    check("what you send shows under your own name, and new lines in the open conversation are not unread",
        #l == 3 and l[2] == "|cff909090[" .. date("%d.%m %H:%M", NOW + 120) .. "]|r |Hplayer:Tester|h[|cfff58cbaTester|r]|h: Ja, om 10 min"
        and l[3]:find("Supert!", 1, true) ~= nil and whispers.altine.unread == 0 and whispers.altine.messages[2].out == true
        and rows[1].label.text == "|cff40c7ebAltine|r" and rows[1].sub.text == date("%H:%M", NOW + 120) .. "  Supert!", table.concat(l, " / "))
    fire("CHAT_MSG_WHISPER_INFORM", "Hei Borin", "Borin-Stormrage")
    check("whispering someone new from the game's own chat starts a conversation too, not unread",
        whispers.borin ~= nil and whispers.borin.unread == 0 and whispers.borin.messages[1].out == true and whispers.borin.messages[1].me == "Tester")

    click(gc.whisperDelete)
    check("Delete conversation removes it, and the next one opens",
        whispers.altine == nil and gc.whisperName.text ~= "" and gc.whisperDelete.label.text == "Slett samtalen")

    for i = 1, 205 do
        clockNow = NOW + 1000 + i
        fire("CHAT_MSG_WHISPER", "w" .. i, "Cedric-Stormrage")
    end
    check("a conversation keeps its last 200 lines", #whispers.cedric.messages == 200 and whispers.cedric.messages[1].text == "w6")
    for i = 1, 55 do
        clockNow = NOW + 5000 + i
        fire("CHAT_MSG_WHISPER", "hei", "Person" .. i .. "-Somewhere")
    end
    local kept = 0
    for _ in pairs(whispers) do kept = kept + 1 end
    check("the 50 newest conversations are kept", kept == 50 and whispers.person55 ~= nil and whispers.zed == nil, kept)
    time = realTime
    click(gc.views.chat)

    -- The game's guild log.
    GUILD_LOG = {
        { "invite", "Tester-Stormrage", "Borin-Stormrage", "", 0, 0, 3, 2 },
        { "join", "Borin-Stormrage", "", "", 0, 0, 3, 1 },
        { "promote", "Tester-Stormrage", "Borin-Stormrage", "Officer", 0, 0, 1, 0 },
        { "quit", "Eira-Stormrage", "", "", 0, 1, 0, 0 },
        { "mystery", "Dagny-Stormrage", "", "", 0, 0, 0, 0 },
    }
    local queries = GUILD_LOG_QUERIES
    click(gc.views.log)
    check("Log asks the game for the guild log, and swaps the chat for it",
        GUILD_LOG_QUERIES == queries + 1 and gc.log:IsShown() and not gc.chat:IsShown() and not gc.chatInput:IsShown() and not gc.motd:IsShown()
        and not gc.whisperChat:IsShown()
        and gc.refresh:IsShown() and gc.views.log.selected)
    local l = lines(gc.log)
    check("...and shows it oldest first, with how long ago and the names in class colours",
        #l == 5 and l[1] == "|cff909090[1 mnd. siden]|r |cffabd473Eira|r forlot guilden."
        and l[2] == "|cff909090[3 dager siden]|r |cfff58cbaTester|r inviterte |cffc79c6eBorin|r."
        and l[3] == "|cff909090[3 dager siden]|r |cffc79c6eBorin|r ble med i guilden."
        and l[4] == "|cff909090[1 dager siden]|r |cfff58cbaTester|r forfremmet |cffc79c6eBorin|r til Officer."
        and l[5]:find("^|cff909090%[nettopp%]|r mystery: ") ~= nil, table.concat(l, " / "))
    table.remove(GUILD_LOG, 5)
    fire("GUILD_EVENT_LOG_UPDATE")
    check("when the game sends the log, it is shown again", #lines(gc.log) == 4)
    GUILD_LOG = {}
    click(gc.refresh)
    check("Refresh asks again; an empty log says so", GUILD_LOG_QUERIES == queries + 2 and lines(gc.log)[1] == ns.strings.nb.GC_LOG_EMPTY)
    local realInfo = GetGuildEventInfo
    GetGuildEventInfo = nil
    click(gc.refresh)
    check("without the game's log functions it says so", lines(gc.log)[1] == ns.strings.nb.GC_LOG_UNAVAILABLE)
    GetGuildEventInfo = realInfo

    ns.SetLanguage("en", true)
    check("the tab follows the language", gcChip.label.text == "Chat & Log" and gc.views.log.label.text == "Log" and gc.refresh.label.text == "Refresh")
    ns.SetLanguage("nb", true)
    click(gc.views.chat)
    check("back to the chat: every kept message is shown, scrolled to the newest", #gc.chat.messages == 300 and gc.chat.atBottom == true)
    click(rsChip)
end)()

-- ======================= version check (Update.lua) ===============================
;(function()
    local VER = "DragonworldVer"
    local function verReceive(text, sender) fire("CHAT_MSG_ADDON", VER, text, "GUILD", sender or "Altine-Stormrage") end
    local function all(list) return table.concat(list, " ; ") end
    local mine = table.concat({ "V", ns.RELEASE, "?", ns.RESTART_RELEASE, tostring(ns.RELEASED_AT) }, "\t")

    check("versions compare number by number, not as text",
        ns.CompareVersions("0.9.0", "0.10.0") == -1 and ns.CompareVersions("1.0.0", "0.99.9") == 1 and ns.CompareVersions("0.15.0", "0.15") == 0
        and ns.CompareVersions("0.15.0", "0.15.0") == 0 and ns.CompareVersions("banana", "0.1.0") == 0)
    check("the version file and the download link are there", ns.RELEASE:match("^%d+%.%d+%.%d+$") ~= nil and ns.DOWNLOAD_URL:find("^https://github%.com/") ~= nil, ns.RELEASE)
    check("at login the addon tells the guild which version it has, once", prefixes[VER] == true and #VERSION_LOGIN == 1 and VERSION_LOGIN[1] == mine, all(VERSION_LOGIN))
    check("nothing is outdated while nobody has said a newer version", not ns.IsOutdated() and ns.NewestVersion() == ns.RELEASE and DragonworldUpdateNotice == nil)

    verReceive("V\t0.14.0\t0.14.0", "Borin-Stormrage")
    check("hearing an older version is not answered at once", #sentNow(VER) == 0)
    flush()
    local sent = sentNow(VER)
    check("...but a little later, so the one who is behind finds out", #sent == 1 and sent[1] == mine, all(sent))
    check("an older version never shows the update window", DragonworldUpdateNotice == nil)

    verReceive("V\t0.14.0\t0.14.0", "Borin-Stormrage")
    verReceive("V\t" .. ns.RELEASE .. "\t" .. ns.RELEASE, "Dagny-Stormrage")
    flush()
    check("...unless someone else with the same version answered first", #sentNow(VER) == 0)

    clearChat()
    verReceive("V\t0.99.0\t0.99.1", "Altine-Stormrage")
    local notice = DragonworldUpdateNotice
    check("hearing a newer version shows 'Update Dragonworld!' at once, in the chosen language",
        notice ~= nil and notice:IsShown() and notice.strata == "DIALOG" and notice.title.text == "Oppdater Dragonworld!"
        and notice.text.text == ns.strings.nb.UP_TEXT:format("0.99.0", ns.RELEASE) and notice.how.text == ns.strings.nb.UP_HOW
        and notice.link.text == ns.DOWNLOAD_URL and notice.ok.label.text == "OK" and notice.logo.texture == ns.ICON)
    check("...says it in chat with the link", has("Versjon 0.99.0 av addonen er ute (du har " .. ns.RELEASE .. ")") and has(ns.DOWNLOAD_URL), chatText())
    check("...and remembers it for the next login", DragonworldDB.update.newest == "0.99.0" and DragonworldDB.update.from == "Altine" and ns.IsOutdated())
    check("Escape closes the window", UISpecialFrames[#UISpecialFrames] == "DragonworldUpdateNotice")
    notice.link:TypeText("hello")
    check("the link can be copied but not changed", notice.link.text == ns.DOWNLOAD_URL and notice.link.highlighted == true)
    notice.ok.scripts.OnClick(notice.ok)
    check("OK closes it", not notice:IsShown())
    verReceive("V\t0.99.0\t0.99.0", "Dagny-Stormrage")
    check("the same version again does not bring it back in this session", not notice:IsShown())

    inCombat = true
    verReceive("V\t1.0.0\t1.0.0", "Altine-Stormrage")
    check("an even newer one during a fight waits until the fight is over", not notice:IsShown() and DragonworldDB.update.newest == "1.0.0")
    inCombat = false
    fire("PLAYER_REGEN_ENABLED")
    check("...then it shows", notice:IsShown() and notice.text.text == ns.strings.nb.UP_TEXT:format("1.0.0", ns.RELEASE))
    notice.ok.scripts.OnClick(notice.ok)

    for _, junk in ipairs({ "V\tbanana\t", "X\t9.0.0\t", "V", "", "V\t9.9.9.9.9.9.9.9.9.9.9\t" }) do
        verReceive(junk, "Altine-Stormrage")
    end
    check("garbage is ignored", DragonworldDB.update.newest == "1.0.0" and not notice:IsShown())

    win.settingsChip.scripts.OnClick(win.settingsChip)
    check("Settings shows your version, that a newer one is out, and the link",
        settings.versionLabel.text == "Versjon" and settings.versionText.text == "Du har Dragonworld " .. ns.RELEASE .. "."
        and settings.versionStatus.text == "Versjon 1.0.0 er ute - oppdater!" and settings.versionStatus.color[1] == 1.00
        and settings.link.text == ns.DOWNLOAD_URL and settings.linkHint.text == ns.strings.nb.UP_LINK_HINT)

    local release = ns.RELEASE
    ns.RELEASE = "1.0.0" -- as if the player had updated
    check("once updated, the remembered version is forgotten", not ns.IsOutdated() and DragonworldDB.update.newest == nil)
    settings:Refresh()
    check("...and Settings says so", settings.versionStatus.text == "Ingen nyere versjon sett i guilden." and settings.versionStatus.color[2] > 0.8)
    ns.RELEASE = release
    check("Settings says automatic updates are off", settings.autoText.text == ns.strings.nb.UP_AUTO_OFF)

    -- Automatic updates: Dragonworld Updater has set AUTO_UPDATE in Version.lua.
    ns.AUTO_UPDATE = true
    settings:Refresh()
    check("...or on", settings.autoText.text == ns.strings.nb.UP_AUTO_ON)
    clearChat()
    verReceive(table.concat({ "V", "2.0.0", "2.0.0", ns.RELEASE, tostring(SERVER_NOW - 60) }, "\t"), "Altine-Stormrage")
    check("with automatic updates, the window waits until the new version has surely been downloaded",
        not notice:IsShown() and DragonworldDB.update.newest == "2.0.0" and DragonworldDB.update.restart == ns.RELEASE and DragonworldDB.update.releasedAt == SERVER_NOW - 60)
    SERVER_NOW = SERVER_NOW + 10 * 60
    flush()
    check("...still waiting ten minutes later", not notice:IsShown())
    SERVER_NOW = SERVER_NOW + 10 * 60
    flush()
    check("...then: it is downloaded, type /reload, with a button that does it",
        notice:IsShown() and notice.title.text == "Ny versjon er klar!" and notice.text.text == ns.strings.nb.UP_READY_RELOAD:format("2.0.0")
        and not notice.link:IsShown() and not notice.how:IsShown() and notice.ok.label.text == "Reload nå" and notice.later:IsShown() and notice.later.label.text == "Senere")
    check("...and in chat", has("Dragonworld 2.0.0 er lastet ned. Skriv /reload"), chatText())
    settings:Refresh()
    check("...and in Settings", settings.versionStatus.text == "Versjon 2.0.0 er lastet ned - skriv /reload!")
    RELOADS = 0
    notice.later.scripts.OnClick(notice.later)
    check("Later just closes it", RELOADS == 0 and not notice:IsShown())
    ns.ShowUpdatePopup()
    notice.ok.scripts.OnClick(notice.ok)
    check("Reload now reloads the interface", RELOADS == 1 and not notice:IsShown())

    verReceive(table.concat({ "V", "3.0.0", "3.0.0", "3.0.0", tostring(SERVER_NOW - 3600) }, "\t"), "Altine-Stormrage")
    check("a version with new files, out for an hour: restart the game, and no reload button",
        notice:IsShown() and notice.text.text == ns.strings.nb.UP_READY_RESTART:format("3.0.0") and notice.ok.label.text == "OK" and not notice.later:IsShown())
    settings:Refresh()
    check("...Settings says so too", settings.versionStatus.text == "Versjon 3.0.0 er lastet ned - start spillet på nytt!")
    notice.ok.scripts.OnClick(notice.ok)
    check("...and OK there only closes it", RELOADS == 1 and not notice:IsShown())

    verReceive("V\t4.0.0\t4.0.0", "Altine-Stormrage")
    check("from an older addon that does not say whether files were added: to be safe, restart",
        notice:IsShown() and notice.text.text == ns.strings.nb.UP_READY_RESTART:format("4.0.0"))
    notice.ok.scripts.OnClick(notice.ok)
    verReceive(table.concat({ "V", "5.0.0", "5.0.0", "4.0.0", tostring(SERVER_NOW + 5 * 86400) }, "\t"), "Altine-Stormrage")
    check("a release time far in the future is not believed (the window is not held back)", notice:IsShown() and DragonworldDB.update.releasedAt == nil)
    notice.ok.scripts.OnClick(notice.ok)

    ns.AUTO_UPDATE = false
    DragonworldDB.update = {}
    check("nothing else went out", #sentNow(VER) == 0)
end)()

-- =================== blinking and the action bar button (Alerts.lua) =================
;(function()
    local function stReceive(text, sender) fire("CHAT_MSG_ADDON", "DragonworldSt", text, "GUILD", sender or "Altine-Stormrage") end
    local function click(button) button.scripts.OnClick(button) end
    local function toggle(check, on) check.checked = on; check.scripts.OnClick(check) end
    local function colour(texture) return texture.vertexColor and ("%.2f,%.2f,%.2f"):format(texture.vertexColor[1], texture.vertexColor[2], texture.vertexColor[3]) end
    local GREEN, GOLD = "0.30,1.00,0.45", "1.00,0.70,0.15"
    local pulse = ns.alertPulse
    local dungeonsChip = chipByID.dungeons

    for _, alert in ipairs(ns.ALERTS) do ns.MarkAlertSeen(alert.kind) end
    check("four things can blink: a new event (gold), a whisper, a guild chat message, and someone wanting a dungeon (green)",
        #ns.ALERTS == 4 and ns.ALERTS[1].kind == "event" and ns.ALERTS[2].kind == "whisper" and ns.ALERTS[3].kind == "guildchat"
        and ns.ALERTS[4].kind == "dungeon" and ns.ALERTS[1].module == "events" and ns.ALERTS[2].module == "guildchat" and ns.ALERTS[4].module == "dungeons")
    check("nothing new: nothing blinks", not ns.IsBlinking() and pulse.scripts.OnUpdate == nil and not mm.glow:IsShown())
    check("the minimap glow is the round ring itself lit up (a grey copy on top of it, coloured), with a soft halo around the button",
        mm.glow.blend == "ADD" and mm.glow.desaturated and mm.glow.texture == "Interface\\Minimap\\MiniMap-TrackingBorder" and mm.glow.layer == "OVERLAY"
        and mm.glow.sublevel == 7 and mm.glow.width == 50 and mm.halo.atlas == "gamepad-hud-actionbar-casting-complete-glow" and mm.halo.blend == "ADD"
        and mm.halo.desaturated and mm.halo.layer == "BACKGROUND" and mm.halo.width == 60)

    -- Someone wants a dungeon at your level (Tester is 60; Blackrock Depths 52-60, Stratholme 58-60).
    -- (The status section left Altine's last status 100 s ahead of its clock.)
    SERVER_NOW = SERVER_NOW + 600
    stReceive("S\tPlayer-1-Altine\tD\t" .. SERVER_NOW .. "\t25,33\tL")
    flush()
    check("someone open for a dungeon at your level makes the buttons blink", ns.IsBlinking() and pulse.scripts.OnUpdate ~= nil)
    pulse.scripts.OnUpdate(pulse, 1.2) -- half a blink in: brightest
    check("the ring around the minimap button lights up green, at full strength at the top of a blink",
        mm.glow:IsShown() and colour(mm.glow) == GREEN and math.abs(mm.glow.alpha - 1.0) < 0.001, mm.glow.alpha)
    check("...and so does the halo around it", mm.halo:IsShown() and colour(mm.halo) == GREEN and mm.halo.alpha == mm.glow.alpha)
    pulse.scripts.OnUpdate(pulse, 1.2) -- end of the blink
    check("...fading out between blinks", mm.glow.alpha < 0.01, mm.glow.alpha)
    mm.scripts.OnEnter(mm)
    check("holding the mouse over the minimap icon lists what is new, under a heading, in its colour",
        #GameTooltip.lines == 6 and GameTooltip.lines[4] == " " and GameTooltip.lines[5] == "Nytt:"
        and GameTooltip.lines[6] == "Altine ser etter dungeon: Blackrock Depths, Stratholme: Undead (Loot)" and colour({ vertexColor = GameTooltip.colors[6] }) == GREEN,
        table.concat(GameTooltip.lines, " / "))
    check("...and that counts as seen: the blinking stops at once", not ns.IsBlinking() and pulse.scripts.OnUpdate == nil and not mm.glow:IsShown() and not mm.halo:IsShown())
    mm.scripts.OnLeave(mm)
    mm.scripts.OnEnter(mm)
    check("the next time, the list is gone", #GameTooltip.lines == 3, table.concat(GameTooltip.lines, " / "))
    mm.scripts.OnLeave(mm)

    win:Hide()
    mm.scripts.OnClick(mm, "LeftButton")
    check("a click right after still opens the tab with what was new", win:IsShown() and dungeonsChip.selected)
    check("...and nothing blinks", not ns.IsBlinking() and not mm.glow:IsShown())

    SERVER_NOW = SERVER_NOW + 60
    stReceive("S\tPlayer-1-Altine\tD\t" .. SERVER_NOW .. "\t25\tX")
    flush()
    check("something new arriving while you look at that tab does not blink", not ns.IsBlinking())

    click(rsChip)
    SERVER_NOW = SERVER_NOW + 60
    stReceive("S\tPlayer-1-Altine\tD\t" .. SERVER_NOW .. "\t2,3\tX") -- Ragefire Chasm, Ruins of Lordaeron: 13-22
    flush()
    check("a dungeon far from your level does not blink", not ns.IsBlinking())
    stReceive("S\tPlayer-1-Borin\tD\t" .. SERVER_NOW .. "\t\t", "Borin-Stormrage")
    flush()
    check("someone who is offline does not blink", not ns.IsBlinking())

    SERVER_NOW = SERVER_NOW + 60
    stReceive("S\tPlayer-1-Altine\tD\t" .. SERVER_NOW .. "\t\tQ") -- no dungeons chosen: any will do
    ns.SetMyStatus("C")
    flush()
    check("while you are 'Do not disturb', dungeons do not blink", not ns.IsBlinking())
    ns.SetMyStatus(nil)
    flush()
    check("...and do again once that is off", ns.IsBlinking())
    sentNow("DragonworldSt")

    -- Settings.
    click(win.settingsChip)
    local blink = settings.blink
    check("Settings has blinking, with what it blinks for and each colour, in the chosen language",
        blink.main.label.text == "Blink når noe er nytt" and blink.main.checked == true
        and blink.kinds[1].label.text == "Ny event" and blink.kinds[4].label.text == "Noen ser etter dungeon"
        and blink.kinds[2].label.text == "Ny hvisking" and blink.kinds[3].label.text == "Ny melding i guildchatten"
        and blink.kinds[1].checked == true and blink.kinds[4].checked == true and blink.kinds[4].swatch.texture == "color")
    toggle(blink.kinds[4], false)
    check("unticking dungeons stops that blinking, and is saved", not ns.IsBlinking() and DragonworldDB.alerts.off.dungeon == true)
    toggle(blink.kinds[4], true)
    check("ticking it again starts it", ns.IsBlinking() and DragonworldDB.alerts.off.dungeon == nil)
    toggle(blink.main, false)
    check("turning blinking off stops it everywhere, and greys out the choices under it",
        not ns.IsBlinking() and not mm.glow:IsShown() and blink.kinds[1].enabled == false and blink.kinds[1].label.color[1] == 0.5 and DragonworldDB.alerts.blinkOff == true)
    win:Hide()
    mm.scripts.OnClick(mm, "LeftButton")
    check("with blinking off, the button just opens the window as usual", win:IsShown() and win.settingsChip.selected and not dungeonsChip.selected)
    toggle(blink.main, true)
    check("on again: it blinks again", ns.IsBlinking() and blink.kinds[1].enabled == true)
    ns.SetLanguage("en", true)
    check("the choices follow the language", blink.main.label.text == "Blink when something is new" and blink.kinds[1].label.text == "New event"
        and settings.actionLabel.text == "Button for your action bar")
    ns.SetLanguage("nb", true)

    -- A new event from someone else.
    click(rsChip)
    SERVER_NOW = SERVER_NOW + 60
    receive(table.concat({ "E", "Altine-Stormrage:" .. NOW .. ":77", NOW, NOW + 3 * 86400, "0", "Blink test", "" }, TAB))
    flush()
    check("a new event from someone else blinks too", ns.IsBlinking() and #ns.ActiveAlerts() == 2)
    local colours = {}
    for _ = 1, 2 do
        pulse.scripts.OnUpdate(pulse, 2.4)
        colours[colour(mm.glow)] = true
    end
    check("with two new things the colour changes every blink: gold for the event, green for the dungeon", colours[GOLD] and colours[GREEN])
    do
        local items = ns.ALERTS[1].Items(ns.AlertSeenTime("event"))
        check("in the list, a new event shows its title, when, and who posted it",
            #items == 1 and items[1] == "Ny event: Blink test, " .. date("%d.%m.%Y %H:%M", NOW + 3 * 86400) .. " (Altine)", items[1])
    end
    click(evChip)
    check("opening Events makes that seen; the dungeon still blinks", #ns.ActiveAlerts() == 1 and ns.ActiveAlerts()[1].kind == "dungeon")
    click(rsChip)
    SERVER_NOW = SERVER_NOW + 60
    receive(table.concat({ "E", "Tester-Stormrage:" .. NOW .. ":78", NOW, NOW + 3 * 86400, "0", "My own", "" }, TAB))
    flush()
    check("your own event coming back from someone else does not blink", #ns.ActiveAlerts() == 1 and ns.ActiveAlerts()[1].kind == "dungeon")
    sentNow()

    -- The action bar button.
    click(win.settingsChip)
    local source = settings.actionSource
    check("Settings has the icon to drag onto the action bar, with what it is for",
        settings.actionLabel.text == "Knapp til action bar" and settings.actionHint.text == ns.strings.nb.AB_HINT and source.icon.texture == ns.ACTION_ICON)
    source.scripts.OnEnter(source)
    check("hovering it explains it", GameTooltip.lines[2] == ns.strings.nb.AB_TIP)
    source.scripts.OnLeave(source)
    inCombat = true
    clearChat()
    source.scripts.OnDragStart(source)
    check("during a fight the macro can't be made, and the player is told why", #MACROS == 0 and CURSOR_MACRO == nil and has(ns.strings.nb.AB_COMBAT), chatText())
    inCombat = false
    source.scripts.OnDragStart(source)
    check("dragging it makes the account macro 'Dragonworld' (/dw) with the dragon icon, and puts it on the cursor",
        #MACROS == 1 and MACROS[1].name == "Dragonworld" and MACROS[1].body == "/dw" and MACROS[1].icon == 134153 and MACROS[1].perCharacter == false and CURSOR_MACRO == 1)
    CURSOR_MACRO = nil
    click(source)
    check("clicking it does the same, and reuses the macro", #MACROS == 1 and CURSOR_MACRO == 1)

    local buttons = {}
    for index = 1, 12 do
        local b = CreateFrame("CheckButton", "ActionButton" .. index, UIParent)
        b:SetSize(45, 45)
        b.action = index
        b.icon = b:CreateTexture(nil, "BACKGROUND")
        b.IconMask = { mask = true }
        b:SetScript("OnEnter", function(self) -- what the game's action buttons do
            GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
            GameTooltip:SetAction(self.action)
        end)
        buttons[index] = b
    end
    local function overlayOf(b)
        local logo, glow
        local all = {}
        for _, t in ipairs(b.textures or {}) do all[#all + 1] = t end
        for _, child in ipairs(b.children or {}) do
            for _, t in ipairs(child.textures or {}) do all[#all + 1] = t end
        end
        for _, t in ipairs(all) do
            if t.texture == ns.ACTION_ICON then logo = t elseif t.texture == "Interface\\SpellActivationOverlay\\IconAlert" then glow = t end
        end
        return logo, glow
    end
    ACTION_SLOTS[3] = { "macro", 1 }
    fire("ACTIONBAR_SLOT_CHANGED", 3)
    flush()
    local logo, glow = overlayOf(buttons[3])
    check("where the macro lies on the action bar, the guild logo covers its icon, just above it",
        logo ~= nil and logo:IsShown() and logo.layer == "BACKGROUND" and logo.sublevel == 1 and logo.allPoints == buttons[3].icon and logo.mask == buttons[3].IconMask)
    check("...with the game's proc glow around it (grey, so the colour is clean), a bit bigger than the button",
        glow ~= nil and glow.blend == "ADD" and glow.desaturated and glow.layer == "OVERLAY" and glow.width == 45 * 1.4 and glow.height == 45 * 1.4
        and select(1, glow:GetPoint(1)) == "CENTER" and select(2, glow:GetPoint(1)) == buttons[3])
    check("...drawn in a frame of its own above the button, like the game's own proc glow",
        glow.parent ~= buttons[3] and glow.parent.parent == buttons[3] and glow.parent.allPoints == buttons[3] and glow.parent.level == buttons[3]:GetFrameLevel() + 10)
    pulse.scripts.OnUpdate(pulse, 0.6)
    check("...that blinks along with the minimap icon, in the same colour", glow:IsShown() and colour(glow) == colour(mm.glow) and glow.alpha == mm.glow.alpha and glow.alpha > 0)
    check("buttons without the macro are left alone", overlayOf(buttons[4]) == nil and #buttons[4].textures == 1)

    ACTION_SLOTS[3] = nil
    ACTION_SLOTS[7] = { "macro", 1 }
    fire("ACTIONBAR_SLOT_CHANGED", 3)
    fire("ACTIONBAR_SLOT_CHANGED", 7)
    flush()
    pulse.scripts.OnUpdate(pulse, 0.6) -- the next frame
    local logo7, glow7 = overlayOf(buttons[7])
    check("moving it moves the logo and the glow with it", not logo:IsShown() and not glow:IsShown() and logo7 ~= nil and logo7:IsShown() and glow7:IsShown())

    inCombat = true
    ACTION_SLOTS[9] = { "macro", 1 }
    fire("ACTIONBAR_SLOT_CHANGED", 9)
    flush()
    check("during a fight nothing new is made on the action bar", #buttons[9].textures == 1)
    inCombat = false
    fire("PLAYER_REGEN_ENABLED")
    flush()
    check("...it comes right after", overlayOf(buttons[9]) ~= nil)
    ACTION_SLOTS[9] = nil


    -- Newer clients: the slot from GetPagedID (the main bar paged, say), the name from C_ActionBar.
    local paged = buttons[11]
    paged.GetPagedID = function() return 97 end -- e.g. bear form pages the main bar to 97-108
    ACTION_SLOTS[97] = { "macro", 1 }
    fire("ACTIONBAR_SLOT_CHANGED", 97)
    flush()
    check("the slot is taken from GetPagedID when the button has it (not .action)", overlayOf(paged) ~= nil)
    paged.GetPagedID = nil
    ACTION_SLOTS[97] = nil
    local realText = GetActionText
    GetActionText = nil
    C_ActionBar = { GetActionText = function(slot) if slot == 12 then return "Dragonworld" end end }
    ACTION_SLOTS[12] = { "macro", 999 } -- a number that does not match: found by the name instead
    fire("ACTIONBAR_SLOT_CHANGED", 12)
    flush()
    check("the macro is also recognised by its name, read with C_ActionBar.GetActionText", overlayOf(buttons[12]) ~= nil)
    clearChat()
    ns.PrintDebug()
    check("/dw debug lists the buttons with a macro, where, and whether they have the glow",
        has("ActionButton12: plass 12, makro nr 999, navn Dragonworld, har gløden") and has("C_ActionBar.GetActionText: true"), chatText())
    ACTION_SLOTS[12] = nil
    C_ActionBar = nil
    GetActionText = realText
    fire("ACTIONBAR_SLOT_CHANGED", 12)
    flush()
    clearChat()

    local bt = CreateFrame("CheckButton", "BT4Button50", UIParent)
    bt:SetSize(36, 36)
    bt._state_type, bt._state_action = "action", 50
    bt.icon = bt:CreateTexture(nil, "ARTWORK", nil, 7)
    ACTION_SLOTS[50] = { "macro", 1 }
    fire("ACTIONBAR_SLOT_CHANGED", 50)
    flush()
    local btLogo = overlayOf(bt)
    check("Bartender4's buttons are found too (and the logo stays within the layer's sublevels)", btLogo ~= nil and btLogo.sublevel == 7)

    buttons[7]:Fire("OnEnter")
    check("holding the mouse over the action bar button: the game's tooltip, with the list under it",
        GameTooltip.owner == buttons[7] and GameTooltip.lines[1] == "Dragonworld" and GameTooltip.lines[3] == "Nytt:"
        and (GameTooltip.lines[4] or ""):find("^Altine ser etter dungeon") ~= nil and GameTooltip:IsShown(), table.concat(GameTooltip.lines, " / "))
    check("...and the blinking stops there too", not ns.IsBlinking() and not glow7:IsShown())
    local lineCount = #GameTooltip.lines
    GameTooltip:SetAction(7) -- the game redraws the tooltip while the mouse is there
    check("...the list stays when the game redraws the tooltip, without doubling", #GameTooltip.lines == lineCount and GameTooltip.lines[3] == "Nytt:", #GameTooltip.lines)
    buttons[7]:Fire("OnLeave")
    buttons[4]:Fire("OnEnter")
    check("other action buttons' tooltips are left alone", #GameTooltip.lines == 1, table.concat(GameTooltip.lines, " / "))
    buttons[4]:Fire("OnLeave")

    win:Hide()
    dw("")
    check("/dw (what the action bar button runs) right after opens the tab with what was new", win:IsShown() and dungeonsChip.selected)
    check("...and then nothing blinks, on the minimap or the action bar", not ns.IsBlinking() and not mm.glow:IsShown() and not glow7:IsShown())

    -- Whispers and guild chat messages blink too.
    local gc
    for _, child in ipairs(win.content.children) do
        if child.chat and child.whisperChat then gc = child end
    end
    for _, alert in ipairs(ns.ALERTS) do ns.MarkAlertSeen(alert.kind) end
    click(rsChip)
    -- The local clock moves on too (the whisper tests left conversations up to NOW + 5055).
    local realTime = time
    time = function(t) if t ~= nil then return realTime(t) end return NOW + 10000 end
    SERVER_NOW = SERVER_NOW + 60
    fire("CHAT_MSG_WHISPER", "Kan du hjelpe meg med en quest?", "Borin-Stormrage")
    flush()
    check("a new whisper makes the buttons blink", ns.IsBlinking() and #ns.ActiveAlerts() == 1 and ns.ActiveAlerts()[1].kind == "whisper")
    pulse.scripts.OnUpdate(pulse, 1.2)
    check("...in pink, like whispers in the chat", colour(mm.glow) == "1.00,0.45,1.00", colour(mm.glow))
    fire("CHAT_MSG_GUILD", "Noen til Deadmines?", "Altine-Stormrage")
    flush()
    check("guild chat is off by default, so it does not blink", #ns.ActiveAlerts() == 1)
    ns.SetAlertOn("guildchat", true)
    check("turned on, a guild chat message from someone else blinks too, in light blue",
        #ns.ActiveAlerts() == 2 and ns.ActiveAlerts()[2].kind == "guildchat" and ns.ActiveAlerts()[2].color[3] == 1.00)
    mm.scripts.OnEnter(mm)
    local tip = table.concat(GameTooltip.lines, " / ")
    check("hovering lists who whispered what, and the guild chat line",
        tip:find("Borin: Kan du hjelpe meg med en quest?", 1, true) ~= nil and tip:find("Altine: Noen til Deadmines?", 1, true) ~= nil, tip)
    mm.scripts.OnLeave(mm)
    win:Hide()
    mm.scripts.OnClick(mm, "LeftButton")
    check("a click right after opens Chat & Log on the whispers, with Borin's conversation",
        win:IsShown() and chipByID.guildchat.selected and gc.whisperChat:IsShown() and gc.whisperName.text == "|cffc79c6eBorin|r" and not ns.IsBlinking(),
        gc and gc.whisperName.text)
    click(rsChip)
    SERVER_NOW = SERVER_NOW + 60
    fire("CHAT_MSG_GUILD", "Jeg er her", "Tester-Stormrage")
    flush()
    check("your own guild chat messages never blink", not ns.IsBlinking())
    fire("CHAT_MSG_GUILD", "Kom igjen!", "Altine-Stormrage")
    flush()
    check("someone else's do, when turned on", ns.IsBlinking() and ns.ActiveAlerts()[1].kind == "guildchat")
    ns.OpenModule("guildchat")
    click(gc.views.chat)
    check("looking at the guild chat counts as seen", not ns.IsBlinking())
    ns.SetAlertOn("guildchat", false)
    time = realTime

    -- The intro again, from Settings.
    click(win.settingsChip)
    check("Settings has a button to see the intro again", settings.introButton.label.text == "Vis introen")
    click(settings.introButton)
    check("...which shows the intro and the choices again", win.intro:IsVisible() and not win.body:IsVisible())
    click(win.intro.next)
    click(win.setup.done)
    check("...and then back to where you were", win.body:IsVisible() and win.settingsChip.selected and not win.setup:IsVisible())

    clearChat()
    dw("blink")
    check("/dw blink shows all the colours for a while, so you can see how it looks",
        ns.IsBlinking() and #ns.ActiveAlerts() == 4 and has(ns.strings.nb.BLINK_TEST), chatText())
    flush()
    check("...and then stops by itself", not ns.IsBlinking() and not mm.glow:IsShown())
    clearChat()

    click(rsChip)
end)()

-- ============================== error handling ==================================
questInfoThrows = true
clearChat()
local okA = pcall(hover, 2)
local okB = pcall(hover, 2)
check("API error does not propagate into the tooltip", okA and okB and #GameTooltip.lines == 0)
check("API error reported exactly once in chat", #chat == 1 and chat[1]:find("boom", 1, true) and chat[1]:find("Feil:", 1, true), chatText())
local okC = pcall(function() fire("BAG_UPDATE_DELAYED"); flush() end)
check("API error does not break the panel refresh", okC and win:IsShown() and rsPanel:IsVisible() and #visibleRows() == 0)
questInfoThrows = false
check("recovers once the API works again", verdict(2) == "Behold")

io.write(("\n%d checks, %d failures\n"):format(checks, failures))
if failures > 0 then error("TESTS FAILED") end
