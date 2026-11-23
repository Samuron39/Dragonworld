-- Dragonworld - Roster
-- Shows everyone in the guild, also those who are offline, with level, rank,
-- professions and when they were last online. The list can be filtered by
-- status (all, online, active, inactive) and by profession, and there is a
-- search field.
--
-- Where the information comes from:
--   * Name, level, class, rank, zone, note and last online come from the game's
--     own member list, and exist for everyone.
--   * The game does not give out professions for other players. So each addon
--     tells the rest of the guild which professions the character has, and
--     everyone keeps what they hear. Professions are therefore only shown for
--     members who use the addon, and only after you have been online at the
--     same time.
--   * If the client has the game's old guild overview of professions, it is
--     also used for those the addon has not heard from.
--
-- See what a member can craft: when you open one of your own professions, the
-- addon reads which recipes you know, and sends the list to the guild
-- (C messages). In the list such professions are yellow, and a click shows the
-- recipes in the addon's own window (RecipeWindow.lua), also when the member is
-- offline. The game's link to the profession (the same as when you share a
-- profession in chat) is still sent. Between two players it opens nothing in
-- Forever, so it is only used for your own (a button in the recipe window).
--
-- Gathering professions (Fishing, Skinning, Herbalism) have no recipes, and
-- do not count as "not opened".
--
-- Your own professions are read in three ways, because the game does not
-- always report them the same way: the character's profession list, the
-- tradeskill system's list, and what was in the tradeskill window the last
-- time it was open.
--
-- Members are recognized by the player's permanent ID, not by name. In Forever
-- names can have spaces, and the game does not write them the same everywhere.
--
-- "Active" means online within the last 30 days.
--
-- Characters a player has linked (Alts.lua) share one row, with a gold "+2"
-- that shows the others under it. Active and Inactive then go by the most
-- recent login on any of them.
--
-- All text is in Locales.lua (the names that start with RO_).

local ADDON_NAME, DW = ...
local L = DW.L

local MODULE_ID = "roster"
local PREFIX = "DragonworldPr" -- the name of the messages; max 16 characters
local SEP = "\t"
local ACTIVE_DAYS = 30
local MAX_PROFESSIONS = 8
local MAX_LINK_BYTES = 40
local MAX_RECIPES = 600   -- more recipes than this in one profession are not accepted
local MAX_PARTS = 20      -- a recipe list is sent in at most this many messages

-- Gathering professions: they have no recipes, so there is nothing to share or
-- show. Recognized by the game's number for the profession, or by the English
-- name when we only have the name (from other people's messages).
local GATHERING_LINES = { [182] = true, [356] = true, [393] = true } -- Herbalism, Fishing, Skinning
local GATHERING_NAMES = { Herbalism = true, Fishing = true, Skinning = true }

-- Saved data. Set in OnLoad at the bottom.
--   db.professions[key] = {
--       list = { { name = "Mining", level = 225, max = 300 }, ... },
--       links = { Blacksmithing = "2018:164" },   -- see below
--       updated = when we last heard it,
--   }
--   The key is the player's permanent ID. For messages from older versions
--   without an ID it is "name:" followed by the name without spaces and realm.
--   db.seen[key][name] = { level, max, link }: what we have seen in your own
--   tradeskill window.
--   db.crafts[player's ID][name] = { t = server time, ids = "1zk,2b0,..." }:
--   the recipes the member can craft in that profession (spellIDs in base 36,
--   sorted). Our own are read from the tradeskill window; the others' come in
--   C messages. t is when the list was last changed; newest wins.
--
-- The game's link to a profession looks like this: "trade:<player's ID>:2018:164".
-- We only store and send what comes after the ID, and put the link together
-- again when someone clicks. The link opens the game's own window, but only
-- when the game agrees to it (it did not between two players in Forever), so
-- the recipe list is what is shown; the link is an extra button for your own.
local db = { professions = {}, seen = {}, crafts = {} }

-- Small things -------------------------------------------------------------------

local function Number(value)
    if type(value) == "number" and not DW.IsSecret(value) then
        return value
    end
    return 0
end

local function Text(value)
    if type(value) == "string" and not DW.IsSecret(value) then
        return value
    end
    return ""
end

-- The name of a profession, without characters used as separators in the messages.
local function CleanName(text)
    text = tostring(text):gsub("[%c|:;]", " ")
    text = text:gsub("^%s+", "")
    text = text:gsub("%s+$", "")
    return text:sub(1, 40)
end

local function NameStoreKey(name)
    return "name:" .. DW.NameKey(name)
end

-- The key we store this character's own professions under.
local function MyStoreKey()
    local guid = DW.MyGUID()
    if guid then
        return guid
    end
    local _, name = DW.CharacterKey()
    return name and NameStoreKey(name) or nil
end

-- Is this the end of a profession link in the form we accept? Only letters,
-- digits, colons and hyphens, so nobody can smuggle in anything else.
local function ValidLinkRest(rest)
    return type(rest) == "string" and #rest > 0 and #rest <= MAX_LINK_BYTES and rest:find("^[%w:%-]+$") ~= nil
end

-- The names your client uses for the gathering professions, in addition to the English ones.
local localGatheringNames

local function IsGathering(profession)
    if type(profession) ~= "table" then
        return false
    end
    if type(profession.line) == "number" and GATHERING_LINES[profession.line] then
        return true
    end
    local name = profession.name
    if type(name) ~= "string" then
        return false
    end
    if GATHERING_NAMES[name] then
        return true
    end
    -- Looked up once per session.
    if not localGatheringNames and C_TradeSkillUI and C_TradeSkillUI.GetProfessionInfoBySkillLineID then
        local names = {}
        for line in pairs(GATHERING_LINES) do
            local ok, info = pcall(C_TradeSkillUI.GetProfessionInfoBySkillLineID, line)
            -- Only when the game confirms that the answer is for exactly that line.
            if ok and type(info) == "table" and Text(info.professionName) ~= "" and info.professionID == line then
                names[CleanName(info.professionName)] = true
            end
        end
        localGatheringNames = names
    end
    return localGatheringNames ~= nil and localGatheringNames[name] == true
end

-- Recipe lists --------------------------------------------------------------------
--
-- A recipe is the spellID the game uses for it. In the messages they are written
-- in base 36 ("2660" becomes "21w"), so more fit in each message.

local DIGITS = "0123456789abcdefghijklmnopqrstuvwxyz"

local function ToBase36(number)
    local text = ""
    repeat
        local digit = number % 36
        text = DIGITS:sub(digit + 1, digit + 1) .. text
        number = math.floor(number / 36)
    until number == 0
    return text
end

-- Turns a list of spellIDs into stored text: sorted, without duplicates.
local function EncodeRecipes(ids)
    local seen, sorted = {}, {}
    for _, id in ipairs(ids) do
        if type(id) == "number" and id > 0 and id == math.floor(id) and not seen[id] and #sorted < MAX_RECIPES then
            seen[id] = true
            sorted[#sorted + 1] = id
        end
    end
    table.sort(sorted)
    local parts = {}
    for index, id in ipairs(sorted) do
        parts[index] = ToBase36(id)
    end
    return table.concat(parts, ",")
end

local function DecodeRecipes(text)
    local ids = {}
    if type(text) ~= "string" then
        return ids
    end
    for token in text:gmatch("[0-9a-z]+") do
        local id = #token <= 6 and tonumber(token, 36)
        if id and id > 0 and #ids < MAX_RECIPES then
            ids[#ids + 1] = id
        end
    end
    return ids
end

-- The recipe lists for one player (key = the player's permanent ID).
local function CraftsOf(key, create)
    if type(db.crafts) ~= "table" then
        db.crafts = {}
    end
    local crafts = db.crafts[key]
    if type(crafts) ~= "table" then
        if not create then
            return nil
        end
        crafts = {}
        db.crafts[key] = crafts
    end
    return crafts
end

local function CraftsEntry(key, name)
    local crafts = type(key) == "string" and CraftsOf(key, false)
    local entry = crafts and crafts[name]
    if type(entry) == "table" and type(entry.t) == "number" and type(entry.ids) == "string" and entry.ids ~= "" then
        return entry
    end
    return nil
end

-- Who wants to know when a recipe list has arrived (the recipe window).
local recipeListeners = {}

local function RecipesChanged()
    for _, callback in ipairs(recipeListeners) do
        local ok, problem = pcall(callback)
        if not ok then
            DW.PrintError(L.ERROR, problem)
        end
    end
end

-- Own professions ---------------------------------------------------------------

-- Does the tradeskill window show something that is not your own: someone
-- else's profession (opened from a link), the guild's, or an NPC's?
local function ShowsSomeoneElse()
    local function Yes(fn)
        if type(fn) ~= "function" then
            return false
        end
        local ok, value = pcall(fn)
        return ok and not DW.IsSecret(value) and value and true or false
    end
    if C_TradeSkillUI and (Yes(C_TradeSkillUI.IsTradeSkillLinked) or Yes(C_TradeSkillUI.IsTradeSkillGuild) or Yes(C_TradeSkillUI.IsNPCCrafting)) then
        return true
    end
    return Yes(IsTradeSkillLinked)
end

-- The game's link to the profession in the tradeskill window. Returns the
-- player's ID and what comes after it in the link, or nil.
local function ReadOpenLink()
    local getter = (C_TradeSkillUI and C_TradeSkillUI.GetTradeSkillListLink) or GetTradeSkillListLink
    if type(getter) ~= "function" then
        return nil
    end
    local ok, link = pcall(getter)
    if not ok or Text(link) == "" then
        return nil
    end
    local guid, rest = link:match("|Htrade:(Player%-[%w%-]+):([^|]+)|h")
    if not guid or not ValidLinkRest(rest) then
        return nil
    end
    return guid, rest
end

-- Professions the game itself lists for the character (without what we have
-- seen in the tradeskill window). Each also has the game's number for the
-- profession (line), which is needed to open it. Returns a table with the name
-- as key, and the function that adds more.
local function ReadListedProfessions()
    local byName = {}
    local function Add(name, level, max, line)
        name = CleanName(name)
        if name == "" then
            return
        end
        if type(line) ~= "number" or DW.IsSecret(line) or line <= 0 then
            line = nil
        end
        local current = byName[name]
        if not current or level > current.level then
            byName[name] = { name = name, level = level, max = max, line = line or (current and current.line) or nil }
        elseif not current.line then
            current.line = line
        end
    end

    -- 1. The character's own list of professions.
    if GetProfessions and GetProfessionInfo then
        for _, index in pairs({ GetProfessions() }) do
            local name, _, level, max, _, _, line = GetProfessionInfo(index)
            if Text(name) ~= "" and type(level) == "number" and not DW.IsSecret(level) then
                Add(name, level, Number(max), line)
            end
        end
    end

    -- 2. The tradeskill system's list. It has every profession that exists, so
    --    we only take those the character has skill in.
    if C_TradeSkillUI and C_TradeSkillUI.GetAllProfessionTradeSkillLines and C_TradeSkillUI.GetProfessionInfoBySkillLineID then
        local ok, lines = pcall(C_TradeSkillUI.GetAllProfessionTradeSkillLines)
        if ok and type(lines) == "table" then
            for _, id in ipairs(lines) do
                local fine, info = pcall(C_TradeSkillUI.GetProfessionInfoBySkillLineID, id)
                if fine and type(info) == "table" and Text(info.professionName) ~= "" and Number(info.skillLevel) > 0 then
                    Add(info.professionName, Number(info.skillLevel), Number(info.maxSkillLevel), id)
                end
            end
        end
    end

    return byName, Add
end

-- Does the recipe belong to the profession with this number? The game can show
-- the name of one profession while the list is still the previous one, so each
-- recipe is checked separately. If the game cannot answer, it is accepted.
local function RecipeInLine(ui, id, line)
    if type(line) ~= "number" then
        return true
    end
    local saidNo = false
    if ui.IsRecipeInSkillLine then
        local ok, yes = pcall(ui.IsRecipeInSkillLine, id, line)
        if ok and yes == true then
            return true
        end
        saidNo = ok and yes == false
    end
    -- Recipes can be in a sub-line (e.g. per expansion); then the profession
    -- is the "parent" line.
    if ui.GetProfessionInfoByRecipeID then
        local ok, info = pcall(ui.GetProfessionInfoByRecipeID, id)
        if ok and type(info) == "table" then
            local own, parent = Number(info.professionID), Number(info.parentProfessionID)
            if own > 0 or parent > 0 then
                return own == line or parent == line
            end
        end
    end
    return not saidNo
end

-- The recipes you know in the profession in the tradeskill window, as a sorted
-- list of spellIDs. nil when the game gives none (the window has not finished
-- loading, or the functions do not exist).
local function ReadOpenRecipes(line)
    local ui = C_TradeSkillUI
    if not (ui and ui.GetAllRecipeIDs and ui.GetRecipeInfo) then
        return nil
    end
    if ui.IsDataSourceChanging then
        local ok, changing = pcall(ui.IsDataSourceChanging)
        if ok and changing == true then
            return nil
        end
    end
    local ok, all = pcall(ui.GetAllRecipeIDs)
    if not ok or type(all) ~= "table" then
        return nil
    end
    local learned, inLine = {}, {}
    for _, id in ipairs(all) do
        if type(id) == "number" and not DW.IsSecret(id) and id > 0 then
            local fine, info = pcall(ui.GetRecipeInfo, id)
            if fine and type(info) == "table" and info.learned == true then
                learned[#learned + 1] = id
                if RecipeInLine(ui, id, line) then
                    inLine[#inLine + 1] = id
                end
            end
        end
    end
    if #learned == 0 then
        return nil -- every crafting profession has at least one recipe; the list is not ready
    end
    -- If the game says none of them belong to the profession, it is the answer
    -- that is wrong (e.g. a sub-line we do not know): take all. A list that was
    -- from the previous profession is corrected anyway the next time the
    -- window is updated.
    return #inLine > 0 and inLine or learned
end

-- The profession the addon has just asked the game to open (see "Open next"
-- (Open next) further down), or nil.
local opening

-- Reads which profession is in the tradeskill window right now, and remembers
-- it. Returns true if we found something.
local function RememberOpenTradeSkill()
    local name, level, max, windowLine

    -- If you are looking at someone else's profession, it is not yours.
    local linkOwner, linkRest = ReadOpenLink()
    local me = DW.MyGUID()
    if ShowsSomeoneElse() or (linkOwner and me and linkOwner ~= me) then
        return false
    end
    if linkOwner ~= me then
        linkRest = nil -- without our own ID we cannot know the link is yours
    end

    if C_TradeSkillUI then
        for _, getter in ipairs({ "GetBaseProfessionInfo", "GetChildProfessionInfo" }) do
            if not name and C_TradeSkillUI[getter] then
                local ok, info = pcall(C_TradeSkillUI[getter])
                if ok and type(info) == "table" and Text(info.professionName) ~= "" and Number(info.maxSkillLevel) > 0 then
                    name, level, max = info.professionName, Number(info.skillLevel), Number(info.maxSkillLevel)
                    windowLine = Number(info.professionID) > 0 and info.professionID or nil
                end
            end
        end
    end
    if not name and GetTradeSkillLine then
        local ok, lineName, rank, maxRank = pcall(GetTradeSkillLine)
        if ok and Text(lineName) ~= "" and lineName ~= "UNKNOWN" and Number(maxRank) > 0 then
            name, level, max = lineName, Number(rank), Number(maxRank)
        end
    end

    -- The window can have a different name than the profession in the
    -- character's list (the Mining window can be called "Smelting", e.g.). Use
    -- the name from the list when the game's number for the profession matches,
    -- or when the addon had just asked for exactly that one to be opened.
    local listed = ReadListedProfessions()
    local lines = {}
    if windowLine then
        lines[windowLine] = true
    end
    local linkLine = linkRest and tonumber(linkRest:match("(%d+)$"))
    if linkLine then
        lines[linkLine] = true
    end
    local resolved
    for listedName, profession in pairs(listed) do
        if profession.line and lines[profession.line] then
            resolved = listedName
        end
    end
    if not resolved and opening and not (name and listed[CleanName(name)]) then
        resolved = opening.name
    end
    if resolved then
        name = resolved
        if level == nil and listed[resolved] then
            level, max = listed[resolved].level, listed[resolved].max
        end
    end

    local key = MyStoreKey()
    if not name or not key or level == nil then
        return false
    end
    if type(db.seen) ~= "table" then
        db.seen = {}
    end
    if type(db.seen[key]) ~= "table" then
        db.seen[key] = {}
    end
    -- The link does not always arrive right when the window opens. Keep the
    -- one we had if the game gave none now.
    name = CleanName(name)
    local before = db.seen[key][name]
    db.seen[key][name] = {
        level = level,
        max = max,
        link = linkRest or (type(before) == "table" and ValidLinkRest(before.link) and before.link) or nil,
    }

    -- The recipes you know, so the guild can see them (not for gathering professions).
    local line = (listed[name] and listed[name].line) or windowLine or linkLine
    if key:find("^Player%-") and not IsGathering({ name = name, line = line }) then
        local ids = ReadOpenRecipes(line)
        if ids then
            local text = EncodeRecipes(ids)
            local crafts = CraftsOf(key, true)
            local old = crafts[name]
            if type(old) ~= "table" or old.ids ~= text or type(old.t) ~= "number" then
                -- Always newer than last time, even if the clock stands still.
                local t = math.max(DW.ServerNow(), (type(old) == "table" and type(old.t) == "number") and (old.t + 1) or 0)
                crafts[name] = { t = t, ids = text }
                RecipesChanged()
            end
        end
    end
    return true
end

-- Is this one of your own professions shared? With recipe lists the list must
-- have been read; in a client without them the link is enough, as before.
local function MineShared(name, links)
    if C_TradeSkillUI and C_TradeSkillUI.GetAllRecipeIDs then
        return CraftsEntry(MyStoreKey(), name) ~= nil
    end
    return links[name] ~= nil
end

local function ReadMyProfessions()
    -- 1 and 2: what the game itself lists for the character.
    local byName, Add = ReadListedProfessions()

    -- 3. What we have seen in the tradeskill window. We also get the links from there.
    local key = MyStoreKey()
    local seen = key and type(db.seen) == "table" and db.seen[key]
    if type(seen) == "table" then
        for name, info in pairs(seen) do
            if type(info) == "table" then
                Add(name, Number(info.level), Number(info.max))
            end
        end
        for name, info in pairs(seen) do
            if type(info) == "table" and byName[name] and ValidLinkRest(info.link) then
                byName[name].link = info.link
            end
        end
    end

    local list = {}
    for _, profession in pairs(byName) do
        list[#list + 1] = profession
    end
    table.sort(list, function(a, b)
        return a.name < b.name
    end)
    while #list > MAX_PROFESSIONS do
        table.remove(list)
    end
    return list
end

-- Turns the list into text for a message: "Mining:225:300;Cooking:150:225".
local function Serialize(list)
    local parts = {}
    for _, profession in ipairs(list) do
        parts[#parts + 1] = ("%s:%d:%d"):format(profession.name, profession.level, profession.max)
    end
    return table.concat(parts, ";")
end

local function Parse(text)
    local list = {}
    for piece in text:gmatch("[^;]+") do
        local name, level, max = piece:match("^([^:]+):(%d+):(%d+)$")
        if name and #list < MAX_PROFESSIONS then
            list[#list + 1] = { name = CleanName(name), level = tonumber(level), max = tonumber(max) }
        end
    end
    return list
end

-- The links as text for a message: "Blacksmithing:2018:164;Mining:2575:186".
-- Includes as many as fit in one message.
local function SerializeLinks(links)
    local names = {}
    for name in pairs(links) do
        names[#names + 1] = name
    end
    table.sort(names)

    local text = ""
    for _, name in ipairs(names) do
        local piece = name .. ":" .. links[name]
        if #text + #piece + 1 <= 200 then
            text = text .. (text ~= "" and ";" or "") .. piece
        end
    end
    return text
end

local function ParseLinks(text)
    local links, count = {}, 0
    for piece in text:gmatch("[^;]+") do
        local name, rest = piece:match("^([^:]+):(.+)$")
        if name and ValidLinkRest(rest) and count < MAX_PROFESSIONS then
            links[CleanName(name)] = rest
            count = count + 1
        end
    end
    return links
end

-- A recipe list as messages: "C <ID> <profession> <time> <part> <count> <recipes>".
-- The list is split so each message stays under the game's 255 characters.
local function CraftMessages(key, name, entry)
    local head = ("C%s%s%s%s%s%d%s"):format(SEP, key, SEP, name, SEP, entry.t, SEP)
    local budget = 255 - #head - 6 -- room for "12\t12\t"
    local chunks, current = {}, ""
    for token in entry.ids:gmatch("[0-9a-z]+") do
        if current ~= "" and #current + 1 + #token > budget then
            chunks[#chunks + 1] = current
            current = ""
        end
        current = current == "" and token or (current .. "," .. token)
    end
    if current ~= "" then
        chunks[#chunks + 1] = current
    end
    local messages = {}
    if #chunks > MAX_PARTS then
        return messages
    end
    for index, chunk in ipairs(chunks) do
        messages[index] = ("%s%d%s%d%s%s"):format(head, index, SEP, #chunks, SEP, chunk)
    end
    return messages
end

-- Reads your own professions and keeps them. Returns the text of the
-- professions message, the key, and the text of the links message.
local function StoreMine()
    local key = MyStoreKey()
    if not key then
        return nil
    end
    local list = ReadMyProfessions()
    local links = {}
    for _, profession in ipairs(list) do
        if profession.link then
            links[profession.name] = profession.link
        end
    end
    db.professions[key] = { list = list, links = links, updated = time() }
    return Serialize(list), key, SerializeLinks(links)
end

-- Sharing -----------------------------------------------------------------------

local Send = DW.CreateSender(PREFIX)
local QueueRefresh

-- What we have told the guild about our own professions, also after logout:
-- db.sent[key] = { p, pt, sp, l, lt, sl }
--   p / l   the text of the P and L message the last time we read
--   pt / lt server time when that text last changed
--   sp / sl the time (pt / lt) of what we last sent
local function MySent(key)
    if type(db.sent) ~= "table" then
        db.sent = {}
    end
    local mine = db.sent[key]
    if type(mine) ~= "table" then
        mine = {}
        db.sent[key] = mine
    end
    return mine
end

-- Tells the guild which professions the character has, if something has
-- changed and not been sent yet. With since, what has changed after that time
-- (0 = everything) is also sent, to someone who has asked for it. The message
-- has the player's permanent ID first. The links to professions go in a
-- separate message, so older versions of the addon do not trip on them.
local function Publish(since)
    local text, key, links = StoreMine()
    if not text then
        return
    end
    local mine = MySent(key)
    -- Always newer than last time, even if the clock stands still for a second:
    -- otherwise a change right after a send would look like already sent.
    local function Stamp(before)
        return math.max(DW.ServerNow(), type(before) == "number" and (before + 1) or 0)
    end
    if mine.p ~= text or type(mine.pt) ~= "number" then
        mine.p, mine.pt = text, Stamp(mine.pt)
    end
    if mine.l ~= links or type(mine.lt) ~= "number" then
        mine.l, mine.lt = links, Stamp(mine.lt)
    end
    if mine.sp ~= mine.pt or (since ~= nil and mine.pt > since) then
        mine.sp = mine.pt
        Send("P" .. SEP .. key .. SEP .. text)
    end
    if links ~= "" and key:find("^Player%-") and (mine.sl ~= mine.lt or (since ~= nil and mine.lt > since)) then
        mine.sl = mine.lt
        Send("L" .. SEP .. key .. SEP .. links)
    end

    -- The recipe lists, for the professions the character has now.
    if not key:find("^Player%-") then
        return
    end
    if type(mine.sc) ~= "table" then
        mine.sc = {}
    end
    local stored = db.professions[key]
    for _, profession in ipairs(type(stored) == "table" and stored.list or {}) do
        local entry = CraftsEntry(key, profession.name)
        if entry and (mine.sc[profession.name] ~= entry.t or (since ~= nil and entry.t > since)) then
            mine.sc[profession.name] = entry.t
            for _, message in ipairs(CraftMessages(key, profession.name, entry)) do
                Send(message)
            end
        end
    end
end

local replyScheduled = false
local replySince -- the earliest time anyone has asked for changes from

-- Someone asked everyone to report what has changed after a time (or everything).
-- Answer after a random delay, so the whole guild does not answer at the same
-- moment, and only with what has changed after that time.
local function ScheduleReply(since)
    replySince = math.min(replySince or since, since)
    if replyScheduled then
        return
    end
    replyScheduled = true
    C_Timer.After(1 + math.random() * 7, function()
        replyScheduled = false
        local from = replySince or 0
        replySince = nil
        if DW.IsMember() then
            Publish(from)
        end
    end)
end

-- Parts of recipe lists that are not complete yet, only in memory:
-- incoming["<ID>\t<profession>"] = { t, n, got, parts = { [part] = text } }
local incoming = {}

-- A member sends (part of) the recipe list for one profession. When all the
-- parts have arrived, and the list is newer than the one we have, it is saved.
local function ReceiveCrafts(text)
    local guid, name, t, part, total, ids = text:match("^C\t(Player%-[%w%-]+)\t([^\t]+)\t(%d+)\t(%d+)\t(%d+)\t([0-9a-z,]*)$")
    t, part, total = tonumber(t or ""), tonumber(part or ""), tonumber(total or "")
    if not guid or not t or not part or not total or total < 1 or total > MAX_PARTS or part < 1 or part > total then
        return
    end
    name = CleanName(name)
    if name == "" or guid == DW.MyGUID() then
        return
    end
    local have = CraftsEntry(guid, name)
    if have and have.t >= t then
        return -- we have this one or a newer one
    end

    local slot = guid .. SEP .. name
    local pending = incoming[slot]
    if pending and t < pending.t then
        return -- an older list while a newer one is on its way
    end
    if not pending or pending.t ~= t or pending.n ~= total then
        pending = { t = t, n = total, got = 0, parts = {} }
        incoming[slot] = pending
    end
    if not pending.parts[part] then
        pending.parts[part] = ids
        pending.got = pending.got + 1
    end
    if pending.got < total then
        return
    end

    incoming[slot] = nil
    local list = DecodeRecipes(table.concat(pending.parts, ","))
    if #list == 0 then
        return
    end
    CraftsOf(guid, true)[name] = { t = t, ids = EncodeRecipes(list) }
    QueueRefresh()
    RecipesChanged()
end

DW.OnGuildMessage(PREFIX, function(text, sender)
    local kind = text:sub(1, 1)
    if kind == "P" then
        -- A member tells which professions the character has.
        local guid, rest = text:match("^P\t(Player%-[^\t]+)\t?(.*)$")
        local key = guid
        if not key then
            -- Older version without ID: use the sender's name.
            key, rest = NameStoreKey(sender), text:sub(3)
        end
        -- The links come in a separate message; keep the ones we have.
        local before = db.professions[key]
        db.professions[key] = {
            list = Parse(rest),
            links = type(before) == "table" and before.links or nil,
            updated = time(),
        }
        QueueRefresh()
    elseif kind == "L" then
        -- The links to a member's professions, so they can be opened from here.
        local guid, rest = text:match("^L\t(Player%-[%w%-]+)\t(.*)$")
        if guid then
            local entry = db.professions[guid]
            if type(entry) ~= "table" then
                entry = { list = {}, updated = time() }
                db.professions[guid] = entry
            end
            entry.links = ParseLinks(rest)
            QueueRefresh()
        end
    elseif kind == "C" then
        ReceiveCrafts(text)
    elseif kind == "R" then
        ScheduleReply(DW.SyncRequestSince(text))
    end
end)

-- The game's own overview --------------------------------------------------------

-- Some clients have a guild overview of professions built in. If it exists, we
-- read it to cover members the addon has not heard from. It is not remembered
-- between sessions. The key is the name without spaces and realm.
local gameProfessions = {}

local function ReadGameProfessions()
    gameProfessions = {}
    if not (GetNumGuildTradeSkill and GetGuildTradeSkillInfo) then
        return
    end
    local ok, count = pcall(GetNumGuildTradeSkill)
    if not ok or type(count) ~= "number" or DW.IsSecret(count) then
        return
    end

    local header
    for index = 1, count do
        local fine, _, _, _, headerName, _, _, _, playerName, fullName, _, _, _, skill = pcall(GetGuildTradeSkillInfo, index)
        if fine then
            if Text(headerName) ~= "" then
                header = CleanName(headerName)
            elseif header and type(skill) == "number" and not DW.IsSecret(skill) then
                local name = Text(fullName) ~= "" and fullName or Text(playerName)
                if name ~= "" then
                    local key = DW.NameKey(name)
                    gameProfessions[key] = gameProfessions[key] or {}
                    table.insert(gameProfessions[key], { name = header, level = skill, max = 0 })
                end
            end
        end
    end
end

-- Professions for one member: what the addon has heard, otherwise the game's
-- own overview. The second value says where it came from ("addon", "game" or
-- nil), the third is the entry we found, and the fourth is the key it was under.
local function ProfessionsOf(member)
    for _, key in ipairs({ member.guid or false, NameStoreKey(member.key) }) do
        local shared = key and db.professions[key]
        if type(shared) == "table" and type(shared.list) == "table" and #shared.list > 0 then
            return shared.list, "addon", shared, key
        end
    end
    local fromGame = gameProfessions[DW.NameKey(member.key)]
    if fromGame then
        return fromGame, "game"
    end
    return {}, nil
end

-- Open a member's profession -----------------------------------------------------

-- The game's link to a member's profession ("trade:<ID>:2018:164"), or nil if
-- the member has not shared it.
local function LinkData(member, profession)
    local shared, key = member.shared, member.storeKey
    if type(shared) ~= "table" or type(shared.links) ~= "table" or type(key) ~= "string" or not key:find("^Player%-[%w%-]+$") then
        return nil
    end
    local rest = shared.links[profession.name]
    if not ValidLinkRest(rest) then
        return nil
    end
    return "trade:" .. key .. ":" .. rest
end

-- Opens the game's window with what the member can craft. We do exactly what
-- the game does when you click a profession link in chat. If that does not
-- work, the link is put in your chat so you can click it there.
local function OpenProfession(member, profession)
    local data = LinkData(member, profession)
    if not data then
        return false
    end
    local link = ("|cffffd000|H%s|h[%s]|h|r"):format(data, profession.name)
    local opened = type(SetItemRef) == "function" and pcall(SetItemRef, data, link, "LeftButton", DEFAULT_CHAT_FRAME)
    if not opened then
        DW.Print(L.RO_LINK_IN_CHAT:format(member.name) .. " " .. link)
    end
    return true
end

-- The recipes a member has shared for a profession, as a list of spellIDs, and
-- when the list was last changed. nil if none are shared.
local function RecipesOf(member, profession)
    if type(member) ~= "table" or type(profession) ~= "table" or type(member.guid) ~= "string" then
        return nil
    end
    local entry = CraftsEntry(member.guid, profession.name)
    if not entry then
        return nil
    end
    return DecodeRecipes(entry.ids), entry.t
end

-- Is there anything to show for the profession: a recipe list, or (only for
-- your own) the game's link. The game does not open another player's profession
-- from the link in Forever (tried both ways 21.11.2026), so for others only the
-- recipe list counts.
local function CanShow(member, profession)
    if IsGathering(profession) then
        return false
    end
    if RecipesOf(member, profession) ~= nil then
        return true
    end
    local me = DW.MyGUID()
    return me ~= nil and type(member) == "table" and member.guid == me and LinkData(member, profession) ~= nil
end

-- Shows what the member can craft, in the addon's own recipe window
-- (RecipeWindow.lua). If that does not exist, the game's link is opened as before.
local function ShowProfession(member, profession)
    if DW.ShowRecipes then
        DW.ShowRecipes(member, profession)
        return true
    end
    return OpenProfession(member, profession)
end

-- The reminder to open the professions -------------------------------------------
--
-- The addon only learns about a profession, and the link to it, when the player
-- opens it. That is why a small box is shown the first time the main window is
-- opened on a character (right after the language choice), asking for exactly
-- that and showing what has been found so far. It can be brought up again from
-- the Roster tab.

local NOTICE_NAME = "DragonworldShareNotice"

local notice     -- the box; created the first time it is needed
local mainWindow -- the main window, which the box sits on top of

-- "Open next": the addon can open a profession for the player, but
-- the game only allows one per click. Each click on the button therefore opens
-- the next one that is not shared. When the link has been read, the window is
-- closed again.
local tried = {}   -- professions we have tried to open in this session
local noticeStatus -- { key, navn }: the last message under the list, or nil

local function CanOpenForPlayer()
    return C_TradeSkillUI ~= nil and type(C_TradeSkillUI.OpenTradeSkill) == "function"
end

-- This character's professions as they are stored, and the links to them.
local function MyStored()
    local key = MyStoreKey()
    local mine = key and db.professions[key]
    if type(mine) ~= "table" or type(mine.list) ~= "table" then
        return {}, {}
    end
    return mine.list, type(mine.links) == "table" and mine.links or {}
end

-- The next profession the button should open: one that is not shared, that the
-- game has a number for, and that we have not already tried.
local function NextToOpen()
    local list, links = MyStored()
    for _, profession in ipairs(list) do
        if profession.line and not IsGathering(profession) and not MineShared(profession.name, links) and not tried[profession.name] then
            return profession
        end
    end
    return nil
end

local function RefreshNotice()
    if not notice or not notice:IsShown() then
        return
    end
    StoreMine()

    local canOpen = CanOpenForPlayer()
    notice.title:SetText(L.RO_SHARE_TITLE)
    notice.text:SetText(L.RO_SHARE_TEXT .. (canOpen and (" " .. L.RO_SHARE_TEXT_BUTTON) or ""))
    notice.listHeader:SetText(L.RO_SHARE_LIST)
    notice.note:SetText(L.RO_SHARE_NOTE)
    notice.ok.label:SetText(L.RO_SHARE_OK)

    local list, links = MyStored()
    local lines = {}
    for _, profession in ipairs(list) do
        local name = ("%s %d"):format(profession.name, profession.level)
        if IsGathering(profession) then
            lines[#lines + 1] = "|cff9d9d9d" .. L.RO_SHARE_GATHER:format(name) .. "|r"
        elseif MineShared(profession.name, links) then
            lines[#lines + 1] = "|cff40ff40" .. L.RO_SHARE_DONE:format(name) .. "|r"
        else
            lines[#lines + 1] = L.RO_SHARE_TODO:format(name)
        end
    end
    notice.list:SetText(#lines > 0 and table.concat(lines, "\n") or L.RO_SHARE_NONE)

    -- The button that opens the next one. If the function does not exist in the
    -- game, only OK is shown, in the middle of the box.
    local nextOne = canOpen and NextToOpen() or nil
    notice.open:SetShown(canOpen)
    notice.open.label:SetText(nextOne and L.RO_SHARE_OPEN_NEXT:format(nextOne.name) or L.RO_SHARE_OPEN_DONE)
    notice.open:SetActive(nextOne ~= nil and not opening)
    notice.ok:ClearAllPoints()
    if canOpen then
        notice.ok:SetPoint("BOTTOMLEFT", notice, "BOTTOM", 76, 18)
    else
        notice.ok:SetPoint("BOTTOM", notice, "BOTTOM", 0, 18)
    end

    if noticeStatus then
        notice.status:SetText(L[noticeStatus.key]:format(noticeStatus.name or ""))
    else
        notice.status:SetText("")
    end
end

-- Opens the next profession that is not shared. Must be called straight from a
-- click: the game only opens a profession for an addon when the player presses.
local function OpenNextProfession()
    if opening or not CanOpenForPlayer() then
        return
    end
    if InCombatLockdown and InCombatLockdown() then
        noticeStatus = { key = "RO_SHARE_COMBAT" }
        RefreshNotice()
        return
    end
    StoreMine()
    local profession = NextToOpen()
    if not profession then
        RefreshNotice()
        return
    end
    tried[profession.name] = true

    local ok, success = pcall(C_TradeSkillUI.OpenTradeSkill, profession.line)
    if not ok or success == false then
        -- Some professions have no window (e.g. Fishing).
        noticeStatus = { key = "RO_SHARE_FAILED", name = profession.name }
        RefreshNotice()
        return
    end

    -- The window opens, and the link arrives a moment later. Look for it a few
    -- times, and close the window when we have it.
    local run = { name = profession.name, checks = 0 }
    opening = run
    noticeStatus = { key = "RO_SHARE_OPENING", name = profession.name }
    RefreshNotice()

    local function Check()
        if opening ~= run then
            return
        end
        run.checks = run.checks + 1
        RememberOpenTradeSkill()
        StoreMine()
        local _, links = MyStored()
        if MineShared(run.name, links) then
            opening = nil
            noticeStatus = { key = "RO_SHARE_GOT", name = run.name }
            if C_TradeSkillUI and C_TradeSkillUI.CloseTradeSkill then
                pcall(C_TradeSkillUI.CloseTradeSkill)
            end
        elseif run.checks >= 6 then
            -- The window gave us nothing. Leave it open, so the player sees what
            -- came up.
            opening = nil
            noticeStatus = { key = "RO_SHARE_NOTHING", name = run.name }
        else
            C_Timer.After(0.5, Check)
            return
        end
        RefreshNotice()
    end

    if C_Timer and C_Timer.After then
        C_Timer.After(0.5, Check)
    else
        opening = nil
    end
end

local function CreateNotice(parent)
    local f = CreateFrame("Frame", NOTICE_NAME, parent, "BackdropTemplate")
    f:SetSize(480, 380)
    f:SetPoint("CENTER", parent, "CENTER", 0, -20)
    f:SetFrameStrata("DIALOG")
    f:EnableMouse(true) -- so clicks do not go through to what is underneath
    f:SetBackdrop(DW.PANEL_BACKDROP)
    f:SetBackdropColor(0.05, 0.05, 0.07, 0.98)
    f:SetBackdropBorderColor(1.00, 0.82, 0.00, 1)
    f:Hide()

    f.title = f:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
    f.title:SetPoint("TOP", 0, -18)

    f.text = f:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
    f.text:SetPoint("TOPLEFT", 24, -52)
    f.text:SetWidth(432)
    f.text:SetJustifyH("LEFT")

    f.listHeader = f:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    f.listHeader:SetPoint("TOPLEFT", f.text, "BOTTOMLEFT", 0, -16)

    f.list = f:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    f.list:SetPoint("TOPLEFT", f.listHeader, "BOTTOMLEFT", 0, -6)
    f.list:SetWidth(432)
    f.list:SetJustifyH("LEFT")

    f.note = f:CreateFontString(nil, "OVERLAY", "GameFontDisable")
    f.note:SetPoint("BOTTOMLEFT", 24, 80)
    f.note:SetWidth(432)
    f.note:SetJustifyH("LEFT")

    -- What happened the last time the "Open next" button was used.
    f.status = f:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    f.status:SetPoint("BOTTOMLEFT", 24, 56)
    f.status:SetWidth(432)
    f.status:SetJustifyH("LEFT")
    f.status:SetWordWrap(false)

    -- Opens the next profession that is not shared. One click per profession.
    f.open = DW.CreateButton(f, 240, 28, "gold")
    f.open:SetPoint("BOTTOMRIGHT", f, "BOTTOM", 64, 18)
    f.open:SetScript("OnClick", function()
        OpenNextProfession()
    end)

    f.ok = DW.CreateButton(f, 110, 28, "gold")
    f.ok:SetPoint("BOTTOM", 0, 18)
    f.ok:SetScript("OnClick", function()
        -- Remember that this character has seen it.
        local key = DW.CharacterKey()
        if key then
            if type(db.reminded) ~= "table" then
                db.reminded = {}
            end
            db.reminded[key] = true
        end
        f:Hide()
    end)

    return f
end

local function ShowNotice()
    if not mainWindow then
        return
    end
    if not notice then
        notice = CreateNotice(mainWindow)
    end
    notice:Show()
    RefreshNotice()
end

-- The first time the main window is opened on a character: show the reminder.
DW.OnWindowOpened(function(window)
    mainWindow = window
    local key = DW.CharacterKey()
    if key and not (type(db.reminded) == "table" and db.reminded[key]) then
        ShowNotice()
    elseif notice then
        notice:Hide()
    end
end)

-- Display ---------------------------------------------------------------------

local ROW_HEIGHT = 22

-- The columns in a row, from the left: name, level, rank, role, professions,
-- last online. Professions get the space that is left. Last online is short
-- text ("Online", "3 d"), so that column is narrow.
local NAME_WIDTH, LEVEL_WIDTH, RANK_WIDTH, LAST_WIDTH = 130, 28, 80, 60
local LEGACY_WIDTH = 34   -- legacy points, right after level (see Profile.lua)
local ROLE_WIDTH = 34     -- the role icons (one or two), right after rank
local RANK_LEFT = 4 + NAME_WIDTH + 4 + LEVEL_WIDTH + 6 + LEGACY_WIDTH + 10
local ROLE_LEFT = RANK_LEFT + RANK_WIDTH + 6
local PROFESSIONS_LEFT = ROLE_LEFT + ROLE_WIDTH + 6
local PROFESSIONS_RIGHT = 6 + LAST_WIDTH + 8
local PROFESSION_GAP = 10 -- space between two professions
local MORE_WIDTH = 22     -- room for "+2" when not all fit

local panel -- created the first time the module is selected in the main window
local rows = {}
local RefreshPanel

-- "all", "online", "active" or "inactive". The tab opens with those who are
-- online (the guild leader's wish); the others are one click away.
local filterStatus = "online"
local filterProfession     -- the name of a profession, or nil for all
local searchText = ""

local function ProfessionText(list)
    local parts = {}
    for _, profession in ipairs(list) do
        parts[#parts + 1] = ("%s %d"):format(profession.name, profession.level)
    end
    return table.concat(parts, ", ")
end

local function LastOnlineText(member)
    if member.online then
        return L.RO_ONLINE
    end
    if member.days >= 365 then
        return L.RO_YEARS:format(math.floor(member.days / 365))
    elseif member.days >= 30 then
        return L.RO_MONTHS:format(math.floor(member.days / 30))
    elseif member.days >= 1 then
        return L.RO_DAYS:format(member.days)
    end
    return L.RO_HOURS:format(member.hours)
end

-- All professions we know of, for the menu.
local function KnownProfessions()
    local names = {}
    local function Add(list)
        if type(list) == "table" then
            for _, profession in ipairs(list) do
                if type(profession) == "table" and type(profession.name) == "string" then
                    names[profession.name] = true
                end
            end
        end
    end
    for _, shared in pairs(db.professions) do
        if type(shared) == "table" then
            Add(shared.list)
        end
    end
    for _, list in pairs(gameProfessions) do
        Add(list)
    end

    local sorted = {}
    for name in pairs(names) do
        sorted[#sorted + 1] = name
    end
    table.sort(sorted)
    return sorted
end

-- Linked characters (Alts.lua) whose "+N" has been clicked open, by group key.
-- Only for this session.
local expanded = {}

-- The members who match the filters, sorted by name. Also returns how many
-- there are in the guild in total, how many players that is (linked
-- characters count once), how many characters, and whether any characters
-- are linked.
--
-- Linked characters (Alts.lua) become one row: the first of them that is
-- online and matches the filters, else the main, else the highest level.
-- That row (the head) gets altGroup and altKept (the others that match); when
-- its "+N" is open, they follow it with altChild set. Active and Inactive
-- go by the most recent login on any of the characters.
local function Collect()
    local members = DW.ReadGuildRoster()
    local groups, groupList = {}, {}
    if DW.AltGroups then
        groups, groupList = DW.AltGroups(members)
    end

    local needle = searchText:lower()
    needle = needle:gsub("^%s+", "")
    needle = needle:gsub("%s+$", "")

    local list, kept = {}, {}
    for _, member in ipairs(members) do
        member.professions, member.source, member.shared, member.storeKey = ProfessionsOf(member)
        member.altGroup, member.altKept, member.altChild = nil, nil, nil
        local group = member.guid and groups[member.guid]
        local online, days = member.online, member.days
        if group then
            online, days = group.online, group.days
        end

        local keep = true
        if filterStatus == "online" then
            keep = member.online
        elseif filterStatus == "active" then
            keep = online or days < ACTIVE_DAYS
        elseif filterStatus == "inactive" then
            keep = not online and days >= ACTIVE_DAYS
        end

        if keep and filterProfession then
            keep = false
            for _, profession in ipairs(member.professions) do
                if profession.name == filterProfession then
                    keep = true
                end
            end
        end

        -- The search looks in name, rank, role (e.g. "healer") and professions.
        if keep and needle ~= "" then
            local roleNames = {}
            for _, role in ipairs(DW.ROLES or {}) do
                local roles = DW.RolesOf and DW.RolesOf(member)
                if roles and roles[role.code] then
                    roleNames[#roleNames + 1] = L[role.key]
                end
            end
            local haystack = (member.name .. " " .. member.rank .. " " .. table.concat(roleNames, " ") .. " " .. ProfessionText(member.professions)):lower()
            keep = haystack:find(needle, 1, true) ~= nil
        end

        if keep then
            if group then
                kept[member] = true
            else
                list[#list + 1] = member
            end
        end
    end

    -- One row per group, for the characters that matched.
    for _, group in ipairs(groupList) do
        local head
        for _, member in ipairs(group.members) do
            if kept[member] and member.online and not head then
                head = member
            end
        end
        for _, member in ipairs(group.members) do -- main first, then level, then name
            if kept[member] and not head then
                head = member
            end
        end
        if head then
            head.altGroup = group
            head.altKept = {}
            for _, member in ipairs(group.members) do
                if kept[member] and member ~= head then
                    head.altKept[#head.altKept + 1] = member
                end
            end
            list[#list + 1] = head
        end
    end

    table.sort(list, function(a, b)
        if a.name ~= b.name then
            return a.name < b.name
        end
        return a.key < b.key
    end)
    local heads = #list
    if next(expanded) then
        local open = {}
        for _, member in ipairs(list) do
            open[#open + 1] = member
            if member.altGroup and expanded[member.altGroup.key] then
                for _, child in ipairs(member.altKept) do
                    child.altChild = true
                    open[#open + 1] = child
                end
            end
        end
        list = open
    end
    local players = #members
    for _, group in ipairs(groupList) do
        players = players - (#group.members - 1)
    end
    return list, #members, players, heads, #groupList > 0
end

local function SetStatus(status)
    filterStatus = status
    RefreshPanel()
end

local function SetProfession(name)
    filterProfession = name
    RefreshPanel()
end

-- The menu for choosing a profession. data is the name, or false for "all".
local function OpenProfessionMenu(owner)
    local names = KnownProfessions()

    if not (MenuUtil and MenuUtil.CreateContextMenu) then
        -- Without a menu: go to the next profession on each click, and finally all.
        local nextName = names[1]
        for index, name in ipairs(names) do
            if name == filterProfession then
                nextName = names[index + 1]
            end
        end
        SetProfession(nextName)
        return
    end

    local function IsSelected(data)
        return (filterProfession or false) == data
    end
    local function Select(data)
        SetProfession(data or nil)
    end

    MenuUtil.CreateContextMenu(owner, function(_, root)
        root:CreateTitle(L.RO_PROFESSION)
        root:CreateRadio(L.RO_ALL_PROFESSIONS, IsSelected, Select, false)
        for _, name in ipairs(names) do
            root:CreateRadio(name, IsSelected, Select, name)
        end
    end)
end

-- "Blacksmithing 225/300", or just "Blacksmithing 225" when we do not know
-- how high it can go.
local function ProfessionLabel(profession)
    if profession.max > 0 then
        return ("%s %d/%d"):format(profession.name, profession.level, profession.max)
    end
    return ("%s %d"):format(profession.name, profession.level)
end

-- The menu that comes up when you click a row: all the professions the member
-- has. Those that are shared can be opened; the others are grayed out.
local function OpenMemberMenu(owner, member)
    if #member.professions == 0 or not (MenuUtil and MenuUtil.CreateContextMenu) then
        return
    end
    MenuUtil.CreateContextMenu(owner, function(_, root)
        root:CreateTitle(member.name)
        for _, profession in ipairs(member.professions) do
            local entry = root:CreateButton(ProfessionLabel(profession), function()
                ShowProfession(member, profession)
            end)
            if entry and entry.SetEnabled and not CanShow(member, profession) then
                entry:SetEnabled(false)
            end
        end
    end)
end

-- The color of a profession in the row: yellow when it can be opened, otherwise white.
local function ColourProfession(button, hover)
    if not button.linked then
        button.text:SetTextColor(0.90, 0.90, 0.90)
    elseif hover then
        button.text:SetTextColor(1.00, 1.00, 1.00)
    else
        button.text:SetTextColor(1.00, 0.82, 0.00)
    end
end

-- One profession in a row. It is a button, so it can be clicked like a link
-- in chat.
local function GetProfessionButton(row, index)
    local button = row.buttons[index]
    if button then
        return button
    end

    button = CreateFrame("Button", nil, row)
    button:SetHeight(ROW_HEIGHT)
    button.text = button:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    button.text:SetPoint("LEFT", 0, 0)
    button.text:SetJustifyH("LEFT")
    button.text:SetWordWrap(false)

    button:SetScript("OnClick", function(self)
        if self.member and self.profession and self.linked then
            ShowProfession(self.member, self.profession)
        end
    end)
    button:SetScript("OnEnter", function(self)
        if not (self.member and self.profession) then
            return
        end
        ColourProfession(self, true)
        GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
        GameTooltip:AddLine(ProfessionLabel(self.profession), 1.00, 0.82, 0.00)
        if self.linked then
            GameTooltip:AddLine(L.RO_TIP_OPEN:format(self.member.name), 1, 1, 1, true)
        elseif IsGathering(self.profession) then
            GameTooltip:AddLine(L.RO_TIP_GATHER, 0.75, 0.75, 0.75, true)
        else
            GameTooltip:AddLine(L.RO_TIP_NO_LINK:format(self.member.name), 0.75, 0.75, 0.75, true)
        end
        GameTooltip:Show()
    end)
    button:SetScript("OnLeave", function(self)
        ColourProfession(self, false)
        GameTooltip:Hide()
    end)

    row.buttons[index] = button
    return button
end

-- Lays out the member's professions in the row, as many as fit. The rest is
-- shown as "+2", and is in the menu when you click the row.
local function LayoutProfessions(row, member)
    local available = row:GetWidth() - PROFESSIONS_LEFT - PROFESSIONS_RIGHT
    local list = member.professions
    local x, shown = 0, 0

    for index, profession in ipairs(list) do
        local button = GetProfessionButton(row, index)
        button.text:SetWidth(0) -- 0 = as wide as the text
        button.text:SetText(("%s %d"):format(profession.name, profession.level))
        local width = math.ceil(button.text:GetStringWidth())
        local reserve = index < #list and MORE_WIDTH or 0
        if index > 1 and x + width + reserve > available then
            break
        end
        if width > available - reserve then
            -- Even the first one is too long: cut it.
            width = math.max(10, available - reserve)
            button.text:SetWidth(width)
        end

        button.member, button.profession = member, profession
        button.linked = CanShow(member, profession)
        ColourProfession(button, false)
        button:SetWidth(width)
        button:ClearAllPoints()
        button:SetPoint("LEFT", row, "LEFT", PROFESSIONS_LEFT + x, 0)
        button:Show()

        x = x + width + PROFESSION_GAP
        shown = index
    end

    for index = shown + 1, #row.buttons do
        row.buttons[index].member, row.buttons[index].profession = nil, nil
        row.buttons[index]:Hide()
    end

    row.more:ClearAllPoints()
    row.more:SetPoint("LEFT", row, "LEFT", PROFESSIONS_LEFT + x, 0)
    row.more:SetText(shown < #list and ("+%d"):format(#list - shown) or "")
end

local function GetRow(index)
    local row = rows[index]
    if row then
        return row
    end

    row = CreateFrame("Frame", nil, panel.content)
    row:SetSize(panel.content:GetWidth(), ROW_HEIGHT)
    row:SetPoint("TOPLEFT", 0, -(index - 1) * ROW_HEIGHT)
    row:EnableMouse(true)

    row.name = row:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
    row.name:SetPoint("LEFT", 4, 0)
    row.name:SetWidth(NAME_WIDTH)
    row.name:SetJustifyH("LEFT")
    row.name:SetWordWrap(false)

    -- Small icon right after the name when the member has set a status (quester,
    -- dungeon, crafter / do not disturb). See Status.lua.
    row.statusIcon = row:CreateTexture(nil, "OVERLAY")
    row.statusIcon:SetSize(14, 14)
    row.statusIcon:Hide()

    -- "+2": the member's linked characters (Alts.lua). Click to show or hide them.
    row.altsButton = CreateFrame("Button", nil, row)
    row.altsButton:SetHeight(ROW_HEIGHT)
    row.altsButton.text = row.altsButton:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    row.altsButton.text:SetPoint("LEFT", 2, 0)
    row.altsButton.text:SetTextColor(1.00, 0.82, 0.00)
    row.altsButton:SetScript("OnClick", function(self)
        if self.key then
            expanded[self.key] = not expanded[self.key] or nil
            RefreshPanel()
        end
    end)
    row.altsButton:SetScript("OnEnter", function(self)
        GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
        GameTooltip:AddLine((expanded[self.key] and L.RO_ALTS_TIP_HIDE or L.RO_ALTS_TIP):format(self.count or 0), 1, 1, 1, true)
        GameTooltip:Show()
    end)
    row.altsButton:SetScript("OnLeave", function()
        GameTooltip:Hide()
    end)
    row.altsButton:Hide()

    -- Placed from the row, not from the name: the name column narrows for "+2".
    row.level = row:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    row.level:SetPoint("LEFT", row, "LEFT", 4 + NAME_WIDTH + 4, 0)
    row.level:SetWidth(LEVEL_WIDTH)
    row.level:SetJustifyH("RIGHT")

    row.rank = row:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    row.legacy = row:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    row.legacy:SetPoint("LEFT", row.level, "RIGHT", 6, 0)
    row.legacy:SetWidth(LEGACY_WIDTH)
    row.legacy:SetJustifyH("RIGHT")
    row.legacy:SetTextColor(1.00, 0.82, 0.00)

    row.rank:SetPoint("LEFT", row.legacy, "RIGHT", 10, 0)
    row.rank:SetWidth(RANK_WIDTH)
    row.rank:SetJustifyH("LEFT")
    row.rank:SetWordWrap(false)

    -- The role the member has chosen (Profile.lua), as icons.
    row.roles = row:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    row.roles:SetPoint("LEFT", row, "LEFT", ROLE_LEFT, 0)
    row.roles:SetWidth(ROLE_WIDTH)
    row.roles:SetJustifyH("LEFT")
    row.roles:SetWordWrap(false)

    row.last = row:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    row.last:SetPoint("RIGHT", -6, 0)
    row.last:SetWidth(LAST_WIDTH)
    row.last:SetJustifyH("RIGHT")

    -- Professions: one button per profession (created as needed), and "+2" when
    -- not all fit.
    row.buttons = {}
    row.more = row:CreateFontString(nil, "OVERLAY", "GameFontDisable")
    row.more:SetJustifyH("LEFT")

    -- Click the row to bring up the member card (MemberCard.lua): everything
    -- about the member, with professions, talents, gear and your own notes.
    -- Without the card the menu with professions comes up, as before.
    row:SetScript("OnMouseUp", function(self)
        if not self.member then
            return
        end
        GameTooltip:Hide()
        if DW.ShowMemberCard then
            DW.ShowMemberCard(self.member)
        else
            OpenMemberMenu(self, self.member)
        end
    end)

    -- Hover over the row to see everything about the member.
    row:SetScript("OnEnter", function(self)
        local member = self.member
        if not member then
            return
        end
        local colour = RAID_CLASS_COLORS and RAID_CLASS_COLORS[member.class]
        GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
        if colour then
            GameTooltip:AddLine(member.name, colour.r, colour.g, colour.b)
        else
            GameTooltip:AddLine(member.name)
        end
        GameTooltip:AddLine(("%s - %s"):format(L.RO_TIP_LEVEL:format(member.level), DW.OfficerBadge(member) .. member.rank), 1, 1, 1)
        local roles = DW.RolesOf and DW.RolesOf(member)
        if roles then
            GameTooltip:AddLine(DW.RoleNames(roles), 1, 1, 1)
        end
        local status = self.statusCode and DW.STATUS_BY_CODE[self.statusCode]
        if status then
            GameTooltip:AddLine(L[status.key], 0.25, 1.00, 0.25)
        end
        if member.zone ~= "" then
            GameTooltip:AddLine(member.zone, 0.75, 0.75, 0.75)
        end
        if member.note ~= "" then
            GameTooltip:AddLine(member.note, 0.75, 0.75, 0.75, true)
        end
        -- Linked characters (Alts.lua) on a row that stands for all of them.
        local group = member.altGroup
        if group then
            if group.main and group.main ~= member then
                GameTooltip:AddLine(L.RO_TIP_MAIN:format(group.main.name), 1.00, 0.82, 0.00)
            end
            GameTooltip:AddLine(L.RO_TIP_ALSO, 1.00, 0.82, 0.00)
            for _, other in ipairs(group.members) do
                if other ~= member then
                    GameTooltip:AddDoubleLine(("%s %d"):format(other.name, other.level), LastOnlineText(other), 1, 1, 1, 0.75, 0.75, 0.75)
                end
            end
        end
        GameTooltip:AddLine(" ")
        if #member.professions == 0 then
            GameTooltip:AddLine(L.RO_TIP_NONE, 0.75, 0.75, 0.75, true)
        else
            for _, profession in ipairs(member.professions) do
                GameTooltip:AddLine(ProfessionLabel(profession), 1.00, 0.82, 0.00)
            end
            if member.source == "addon" then
                GameTooltip:AddLine(L.RO_TIP_UPDATED:format(date("%d.%m.%Y", member.shared.updated or 0)), 0.60, 0.60, 0.60)
            else
                GameTooltip:AddLine(L.RO_TIP_FROM_GAME, 0.60, 0.60, 0.60)
            end
        end
        -- A click on the row opens the member card (MemberCard.lua).
        GameTooltip:AddLine(L.RO_TIP_CLICK_ROW, 0.60, 0.60, 0.60, true)
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

    -- Read your own professions again every time, so your own row is always right.
    StoreMine()
    ReadGameProfessions()

    panel.title:SetText(L.RO_PANEL_TITLE)
    panel.searchLabel:SetText(L.RO_SEARCH)
    panel.mineChip.label:SetText(L.RO_MINE)
    panel.craftChip.label:SetText(L.CS_OPEN)
    panel.craftChip:SetShown(DW.ShowCraftSearch ~= nil)
    panel.headerName:SetText(L.RO_H_NAME)
    panel.headerLevel:SetText(L.RO_H_LEVEL)
    panel.headerLegacy:SetText(L.RO_H_LEGACY)
    panel.headerRank:SetText(L.RO_H_RANK)
    panel.headerRole:SetText(L.RO_H_ROLE)
    panel.headerProfessions:SetText(L.RO_H_PROFESSIONS)
    panel.headerLast:SetText(L.RO_H_LAST)
    panel.footer:SetText(L.RO_FOOTER)
    panel.empty:SetText(L.RO_EMPTY)

    panel.statusChips.all.label:SetText(L.RO_ALL)
    panel.statusChips.online.label:SetText(L.RO_ONLINE_FILTER)
    panel.statusChips.active.label:SetText(L.RO_ACTIVE)
    panel.statusChips.inactive.label:SetText(L.RO_INACTIVE)
    for status, chip in pairs(panel.statusChips) do
        chip:SetSelected(status == filterStatus)
    end
    panel.professionChip.label:SetText(L.RO_PROFESSION_LABEL:format(filterProfession or L.RO_ALL_PROFESSIONS))

    local list, total, players, heads, linked = Collect()
    for index, member in ipairs(list) do
        local row = GetRow(index)
        local colour = RAID_CLASS_COLORS and RAID_CLASS_COLORS[member.class]
        row.member = member
        -- A linked character under its head is moved in a little; a head
        -- leaves room for its "+2".
        local indent = member.altChild and 12 or 0
        local nameWidth = NAME_WIDTH - indent - (member.altGroup and 26 or 0)
        row.name:ClearAllPoints()
        row.name:SetPoint("LEFT", 4 + indent, 0)
        row.name:SetWidth(nameWidth)
        row.name:SetText(member.name)
        if colour then
            row.name:SetTextColor(colour.r, colour.g, colour.b)
        else
            row.name:SetTextColor(1, 1, 1)
        end
        -- Status is only shown for those who are online.
        local statusCode = member.online and DW.StatusOf and DW.StatusOf(member)
        local status = statusCode and DW.STATUS_BY_CODE[statusCode]
        local afterName = math.min(row.name:GetStringWidth(), nameWidth) + 4
        if status then
            local iconX = math.min(row.name:GetStringWidth(), nameWidth - 16) + 4
            row.statusIcon:SetTexture(status.icon)
            row.statusIcon:ClearAllPoints()
            row.statusIcon:SetPoint("LEFT", row.name, "LEFT", iconX, 0)
            row.statusIcon:Show()
            afterName = iconX + 14 + 2
        else
            row.statusIcon:Hide()
        end
        row.statusCode = status and statusCode or nil
        local group = member.altGroup
        if group then
            local count = #group.members - 1
            row.altsButton.key, row.altsButton.count = group.key, count
            row.altsButton.text:SetText(("+%d"):format(count))
            row.altsButton:SetWidth(math.ceil(row.altsButton.text:GetStringWidth()) + 4)
            row.altsButton:ClearAllPoints()
            row.altsButton:SetPoint("LEFT", row.name, "LEFT", afterName, 0)
            row.altsButton:Show()
        else
            row.altsButton.key, row.altsButton.count = nil, nil
            row.altsButton:Hide()
        end
        row.level:SetText(tostring(member.level))
        local points = DW.LegacyPointsOf and DW.LegacyPointsOf(member)
        row.legacy:SetText(points and tostring(points) or "")
        -- Officers get a small badge in front of the rank (Admin.lua).
        row.rank:SetText(DW.OfficerBadge(member) .. member.rank)
        row.roles:SetText(DW.RoleIcons and DW.RoleIcons(DW.RolesOf and DW.RolesOf(member)) or "")
        LayoutProfessions(row, member)
        -- A head stands for all its characters: the most recent of them.
        local seen = group and { online = group.online, days = group.days, hours = group.hours } or member
        row.last:SetText(LastOnlineText(seen))
        if seen.online then
            row.last:SetTextColor(0.25, 1.00, 0.25)
        else
            row.last:SetTextColor(0.75, 0.75, 0.75)
        end
        row:Show()
    end
    for index = #list + 1, #rows do
        rows[index].member = nil
        rows[index]:Hide()
    end

    panel.content:SetHeight(math.max(1, #list * ROW_HEIGHT))
    -- A search that found no member may still be something members can make:
    -- point to "Who crafts?" (CraftSearch.lua).
    local trimmed = searchText:gsub("^%s+", ""):gsub("%s+$", "")
    panel.searchFoundNobody = (#list == 0 and trimmed ~= "")
    local craftMatches = 0
    if #list == 0 and #trimmed >= 2 and DW.CountCraftMatches then
        craftMatches = DW.CountCraftMatches(trimmed)
    end
    if craftMatches > 0 then
        panel.empty:SetText(L.RO_EMPTY_CRAFT:format(craftMatches))
    else
        panel.empty:SetText(L.RO_EMPTY)
    end
    panel.empty:SetShown(#list == 0)
    if linked then
        panel.count:SetText(L.RO_COUNT_ALTS:format(heads, players, total))
    else
        panel.count:SetText(L.RO_COUNT:format(#list, total))
    end
end

-- Called by the main window the first time the module is selected.
local function CreatePanel(parent)
    local f = CreateFrame("Frame", nil, parent)
    f:SetAllPoints(parent)

    f.title = f:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
    f.title:SetPoint("TOP", 0, -12)

    -- Filter: status.
    f.statusChips = {}
    for index, status in ipairs({ "all", "online", "active", "inactive" }) do
        local chip = DW.CreateChip(f, 96, 26)
        chip:SetPoint("TOPLEFT", 14 + (index - 1) * 102, -40)
        chip.label:SetJustifyH("CENTER")
        chip:SetScript("OnClick", function()
            SetStatus(status)
        end)
        f.statusChips[status] = chip
    end

    -- Filter: profession.
    f.professionChip = DW.CreateChip(f, 170, 26)
    f.professionChip:SetPoint("TOPRIGHT", -14, -40)
    f.professionChip:SetScript("OnClick", function(self)
        OpenProfessionMenu(self)
    end)

    -- Search field: looks in name, rank and professions as you type.
    f.searchLabel = f:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    f.searchLabel:SetPoint("TOPLEFT", 14, -80)

    f.searchBox = CreateFrame("EditBox", nil, f, "InputBoxTemplate")
    f.searchBox:SetSize(150, 22)
    f.searchBox:SetPoint("LEFT", f.searchLabel, "RIGHT", 12, 0)
    f.searchBox:SetAutoFocus(false)
    f.searchBox:SetMaxLetters(40)
    f.searchBox:SetScript("OnEscapePressed", function(self)
        self:ClearFocus()
    end)
    f.searchBox:SetScript("OnEnterPressed", function(self)
        self:ClearFocus()
    end)
    f.searchBox:HookScript("OnTextChanged", function(self)
        searchText = self:GetText() or ""
        RefreshPanel()
    end)

    -- Shows the reminder to open your professions, with what has been found.
    f.mineChip = DW.CreateChip(f, 128, 24)
    f.mineChip:SetPoint("LEFT", f.searchBox, "RIGHT", 14, 0)
    f.mineChip.label:SetJustifyH("CENTER")
    f.mineChip:SetScript("OnClick", function()
        ShowNotice()
    end)

    -- "Who crafts?": searches everything members can make (CraftSearch.lua).
    -- A search here that found no member is taken along.
    f.craftChip = DW.CreateChip(f, 128, 24)
    f.craftChip:SetPoint("LEFT", f.mineChip, "RIGHT", 8, 0)
    f.craftChip.label:SetJustifyH("CENTER")
    f.craftChip:SetShown(DW.ShowCraftSearch ~= nil)
    f.craftChip:SetScript("OnClick", function()
        if DW.ShowCraftSearch then
            DW.ShowCraftSearch(f.searchFoundNobody and searchText or nil)
        end
    end)
    f.craftChip:HookScript("OnEnter", function(self)
        GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
        GameTooltip:AddLine(L.CS_OPEN_TIP, 1, 1, 1, true)
        GameTooltip:Show()
    end)
    f.craftChip:HookScript("OnLeave", function()
        GameTooltip:Hide()
    end)

    -- On the title line: row 2 is full with the search box and its chips. The
    -- width keeps it off the centred title; a long text wraps to a second line.
    f.count = f:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    f.count:SetPoint("TOPRIGHT", -14, -12)
    f.count:SetWidth(220)
    f.count:SetJustifyH("RIGHT")

    -- The headers sit above their own column.
    f.headerName = f:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    f.headerName:SetPoint("TOPLEFT", 14, -108)
    f.headerLevel = f:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    f.headerLevel:SetPoint("TOPLEFT", 150, -108)
    f.headerLegacy = f:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    f.headerLegacy:SetPoint("TOPLEFT", 184, -108)
    f.headerRank = f:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    f.headerRank:SetPoint("TOPLEFT", 10 + RANK_LEFT, -108)
    f.headerRole = f:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    f.headerRole:SetPoint("TOPLEFT", 10 + ROLE_LEFT, -108)
    f.headerProfessions = f:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    f.headerProfessions:SetPoint("TOPLEFT", 10 + PROFESSIONS_LEFT, -108)
    f.headerLast = f:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    f.headerLast:SetPoint("TOPRIGHT", -36, -108)

    local scroll = CreateFrame("ScrollFrame", "DragonworldRosterScroll", f, "ScrollFrameTemplate")
    scroll:SetPoint("TOPLEFT", 10, -124)
    scroll:SetPoint("BOTTOMRIGHT", -30, 34)

    f.content = CreateFrame("Frame", nil, scroll)
    f.content:SetSize(parent:GetWidth() - 10 - 30, 1)
    scroll:SetScrollChild(f.content)

    f.empty = f:CreateFontString(nil, "OVERLAY", "GameFontDisable")
    f.empty:SetPoint("TOP", scroll, "TOP", 0, -40)
    f.empty:SetWidth(360)

    f.footer = f:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    f.footer:SetPoint("BOTTOMLEFT", 14, 12)
    f.footer:SetPoint("BOTTOMRIGHT", -14, 12)
    f.footer:SetJustifyH("LEFT")
    f.footer:SetWordWrap(false)

    f:SetScript("OnShow", function()
        -- Ask the game for a fresh member list. The answer comes as an event.
        if C_GuildInfo and C_GuildInfo.GuildRoster then
            C_GuildInfo.GuildRoster()
        end
        RefreshPanel()
    end)

    panel = f
    return f
end

-- Game events -----------------------------------------------------------------

-- The member list is updated often. Collect and redraw once.
local refreshQueued = false

QueueRefresh = function()
    if refreshQueued or not panel or not panel:IsVisible() then
        return
    end
    if not (C_Timer and C_Timer.After) then
        RefreshPanel()
        return
    end
    refreshQueued = true
    C_Timer.After(0.5, function()
        refreshQueued = false
        RefreshPanel()
    end)
end

local helloSent = false

-- Once per session, a little after login: tell the guild what has changed in
-- the character's professions since last time, and ask the others for what
-- they have changed since we were last online (see "What we have received"
-- in Comm.lua).
local function PlanHello()
    if helloSent or not (C_Timer and C_Timer.After) then
        return
    end
    C_Timer.After(10, function()
        if not helloSent and DW.IsMember() then
            helloSent = true
            Publish()
            Send(DW.SyncRequest())
        end
    end)
end

local publishQueued = false

-- Professions have changed (learned a new one, gained skill, or seen in the
-- tradeskill window). Tell the guild, but not more often than every minute.
local function PlanPublish()
    if publishQueued or not helloSent or not (C_Timer and C_Timer.After) then
        return
    end
    publishQueued = true
    C_Timer.After(60, function()
        publishQueued = false
        if DW.IsMember() then
            Publish()
            QueueRefresh()
        end
    end)
end

local TRADE_SKILL_EVENTS = {
    TRADE_SKILL_SHOW = true,
    TRADE_SKILL_LIST_UPDATE = true,
    TRADE_SKILL_DATA_SOURCE_CHANGED = true,
}

local frame = CreateFrame("Frame")

frame:SetScript("OnEvent", function(self, event)
    if not DW.IsMember() then
        return
    end
    if event == "GUILD_ROSTER_UPDATE" then
        QueueRefresh()
    elseif event == "PLAYER_ENTERING_WORLD" then
        PlanHello()
    else
        if TRADE_SKILL_EVENTS[event] then
            -- The tradeskill window is open: remember which profession it shows.
            RememberOpenTradeSkill()
            QueueRefresh()
            RefreshNotice()
        end
        PlanPublish()
    end
end)

for _, event in ipairs({
    "PLAYER_ENTERING_WORLD",
    "GUILD_ROSTER_UPDATE",
    "SKILL_LINES_CHANGED",
    "CHAT_MSG_SKILL",
    "TRADE_SKILL_SHOW",
    "TRADE_SKILL_LIST_UPDATE",
    "TRADE_SKILL_DATA_SOURCE_CHANGED",
}) do
    pcall(frame.RegisterEvent, frame, event)
end

-- The guild name can arrive late after login. Then announce when it is ready.
DW.OnMembershipChanged(function(member)
    if member then
        PlanHello()
    end
end)

DW.OnLanguageChanged(function()
    RefreshPanel()
    RefreshNotice()
end)

-- Someone has changed status: redraw the icons next to the names.
DW.OnStatusChanged(function()
    QueueRefresh()
end)

-- New legacy points or linked characters (Profile.lua): redraw.
DW.OnProfileChanged(function()
    QueueRefresh()
end)

-- Your own choice of linked characters (Alts.lua) has changed.
DW.OnAltsChanged(function()
    QueueRefresh()
end)

-- A new officer limit (or promotions): redraw the badges in the rank column.
DW.OnOfficersChanged(function()
    QueueRefresh()
end)

-- For the member card (MemberCard.lua) and the recipe window (RecipeWindow.lua).
-- member is a row from the list here (it has professions and what is shared).
--   DW.OpenMemberProfession: the game's own window, via the link (as before)
--   DW.CanOpenMemberProfession: whether the link exists
--   DW.ShowMemberProfession / DW.CanShowMemberProfession: the recipe window,
--       and whether there is anything to show there
--   DW.MemberRecipes: the recipes (spellIDs) and when the list was changed
--   DW.IsGatheringProfession: gathering profession without recipes
--   DW.OnRecipesChanged: called when a recipe list has arrived or changed
DW.OpenMemberProfession = OpenProfession
function DW.CanOpenMemberProfession(member, profession)
    return LinkData(member, profession) ~= nil
end
DW.ShowMemberProfession = ShowProfession
DW.CanShowMemberProfession = CanShow
DW.MemberRecipes = RecipesOf
DW.IsGatheringProfession = IsGathering
function DW.OnRecipesChanged(callback)
    recipeListeners[#recipeListeners + 1] = callback
end

-- Every shared recipe list we have (CraftSearch.lua): callback(guid, profession
-- name, list of spellIDs, when the list was changed), in a fixed order.
function DW.EachRecipeList(callback)
    local keys = {}
    for key in pairs(type(db.crafts) == "table" and db.crafts or {}) do
        if type(key) == "string" then
            keys[#keys + 1] = key
        end
    end
    table.sort(keys)
    for _, key in ipairs(keys) do
        local names = {}
        for name in pairs(CraftsOf(key, false) or {}) do
            if type(name) == "string" then
                names[#names + 1] = name
            end
        end
        table.sort(names)
        for _, name in ipairs(names) do
            local entry = CraftsEntry(key, name)
            if entry then
                callback(key, name, DecodeRecipes(entry.ids), entry.t)
            end
        end
    end
end

-- Debugging: what the game actually reports about professions on this character.
DW.AddDebug("professions", function(add)
    local text = DW.DebugText

    if GetProfessions and GetProfessionInfo then
        local slots = { GetProfessions() }
        local found = 0
        for slot, index in pairs(slots) do
            found = found + 1
            local name, _, level, max, _, _, skillLine = GetProfessionInfo(index)
            add(("GetProfessions[%s] = %s -> %s %s/%s (linje %s)"):format(text(slot), text(index), text(name), text(level), text(max), text(skillLine)))
        end
        if found == 0 then
            add("GetProfessions: ingen")
        end
    else
        add("GetProfessions: finnes ikke")
    end

    if C_TradeSkillUI and C_TradeSkillUI.GetAllProfessionTradeSkillLines and C_TradeSkillUI.GetProfessionInfoBySkillLineID then
        local ok, lines = pcall(C_TradeSkillUI.GetAllProfessionTradeSkillLines)
        if ok and type(lines) == "table" then
            local shown = 0
            for _, id in ipairs(lines) do
                local fine, info = pcall(C_TradeSkillUI.GetProfessionInfoBySkillLineID, id)
                if fine and type(info) == "table" and Number(info.skillLevel) > 0 and shown < 8 then
                    shown = shown + 1
                    add(("håndverkslinje %s -> %s %s/%s"):format(text(id), text(info.professionName), text(info.skillLevel), text(info.maxSkillLevel)))
                end
            end
            add(("håndverkslinjer: %d totalt, %d med skill"):format(#lines, shown))
        else
            add("håndverkslinjer: feil ved lesing")
        end
    else
        add("håndverkslinjer: finnes ikke")
    end

    local key = MyStoreKey()
    add("lagringsnøkkel: " .. text(key))
    local seen = key and type(db.seen) == "table" and db.seen[key]
    if type(seen) == "table" then
        for name, info in pairs(seen) do
            add(("sett i håndverksvindu: %s %s/%s"):format(text(name), text(info.level), text(info.max)))
        end
    else
        add("sett i håndverksvindu: ingenting ennå")
    end
    add("resultat: " .. Serialize(ReadMyProfessions()))
    local linkOwner, linkRest = ReadOpenLink()
    local _, _, myLinks = StoreMine()
    add("lenke i åpent håndverksvindu: " .. text(linkOwner) .. " " .. text(linkRest) .. " | viser en annens: " .. text(ShowsSomeoneElse()))
    add("lenker som deles: " .. text(myLinks) .. " | SetItemRef: " .. text(type(SetItemRef) == "function"))
    local numbers = {}
    for name, profession in pairs(ReadListedProfessions()) do
        numbers[#numbers + 1] = name .. "=" .. text(profession.line)
    end
    table.sort(numbers)
    add("kan åpne for deg (OpenTradeSkill): " .. text(CanOpenForPlayer()) .. " | nummer: " .. table.concat(numbers, ", "))
    local ui = C_TradeSkillUI
    local recipeCounts = {}
    for name, entry in pairs(key and CraftsOf(key, false) or {}) do
        if type(entry) == "table" then
            recipeCounts[#recipeCounts + 1] = name .. "=" .. #DecodeRecipes(entry.ids)
        end
    end
    table.sort(recipeCounts)
    add("oppskrifter delt: " .. (#recipeCounts > 0 and table.concat(recipeCounts, ", ") or "ingen")
        .. " | GetAllRecipeIDs: " .. text(ui ~= nil and ui.GetAllRecipeIDs ~= nil)
        .. " | IsRecipeInSkillLine: " .. text(ui ~= nil and ui.IsRecipeInSkillLine ~= nil)
        .. " | GetRecipeSchematic: " .. text(ui ~= nil and ui.GetRecipeSchematic ~= nil))
    local others = 0
    for guid in pairs(type(db.crafts) == "table" and db.crafts or {}) do
        if guid ~= key then
            others = others + 1
        end
    end
    add("oppskriftslister fra andre: " .. others)
    add("spillets guild-oversikt: " .. text(GetNumGuildTradeSkill and select(2, pcall(GetNumGuildTradeSkill))))
end)

-- For other files (Achievements.lua): your own professions
-- as we read them ({ { name, level, max, line }, ... }), and a member's
-- professions from DW.ReadGuildRoster() as we know them (shared with the addon,
-- or the game's own overview).
function DW.ReadMyProfessions()
    return ReadMyProfessions()
end

function DW.ProfessionsOfMember(member)
    if type(member) ~= "table" then
        return {}
    end
    return (ProfessionsOf(member))
end

-- A copy of a DW.ReadGuildRoster() row filled the way the Roster tab fills its
-- own rows (professions, source, shared, storeKey), so the member card and the
-- recipe window can open the member's professions from it.
function DW.RosterRowOf(member)
    local copy = {}
    if type(member) ~= "table" then
        return copy
    end
    for key, value in pairs(member) do
        copy[key] = value
    end
    copy.professions, copy.source, copy.shared, copy.storeKey = ProfessionsOf(member)
    return copy
end

-- Module -------------------------------------------------------------------------

DW.RegisterModule({
    id = MODULE_ID,
    titleKey = "RO_TITLE",
    notesKey = "RO_NOTES",
    icon = "Interface\\Icons\\INV_Banner_02",

    OnLoad = function(self, saved)
        if type(saved.professions) ~= "table" then
            saved.professions = {}
        end
        if type(saved.seen) ~= "table" then
            saved.seen = {}
        end
        if type(saved.reminded) ~= "table" then
            saved.reminded = {}
        end
        if type(saved.crafts) ~= "table" then
            saved.crafts = {}
        end
        db = saved
    end,

    CreatePanel = function(self, parent)
        return CreatePanel(parent)
    end,
})
