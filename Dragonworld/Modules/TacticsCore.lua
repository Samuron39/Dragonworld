-- Dragonworld - Tactics: the data, the storage and the messages
--
-- The Tactics tab lets a raid or dungeon leader explain a boss fight on a
-- board: a picture of the room with markers for the boss, tanks, healers,
-- dps, raid groups and single players, arrows, drawn lines, areas and short
-- notes. A tactic ("plan") has several scenes, one per phase of the fight.
-- It is saved under its dungeon or raid and boss, and can be played later as
-- a slideshow that everyone in the group who has the addon sees.
--
-- The four files:
--   TacticsCore.lua    (this one) the plan as data, checking and packing it,
--                      the saved library, the list of dungeons and bosses,
--                      who is in the group, and the messages to the group.
--                      No windows.
--   TacticsBoard.lua   the board: draws one scene, and lets it be edited.
--   Tactics.lua        the tab in the main window (the library) and the editor.
--   TacticsViewer.lua  the slideshow window, for the leader and for the group.
--
-- THE PLAN ---------------------------------------------------------------------
--
-- Everything on the board is placed in board units, whole numbers: x from 0
-- to T.BOARD_W (left to right), y from 0 to T.BOARD_H (top to bottom). The
-- board is drawn at any size by scaling these, so a plan looks the same in the
-- editor and for every viewer.
--
--   plan = {
--     id      = "p1a2b3c",        -- unique: small letters and digits only, at most 12; made by T.NewPlan
--     name    = "Two tanks",      -- the plan's own name, at most T.MAX_NAME characters
--     inst    = 4,                -- the dungeon or raid: an id from DW.DUNGEONS (Status.lua), 0 = none of them
--     instName = "The Deadmines", -- its name, kept in the plan so it still reads if the list changes;
--                                 -- with inst = 0 this is what the leader typed
--     boss    = "Edwin VanCleef", -- chosen from the list or typed, at most T.MAX_NAME characters
--     author  = "Akro Polis",     -- who saved it last
--     updated = 1795000000,       -- server time when it was saved last
--     scenes  = { scene, ... },   -- 1 to T.MAX_SCENES
--   }
--
--   scene = {
--     title = "Phase 1",          -- at most T.MAX_NAME characters, may be ""
--     notes = { "Tanks swap at 3 stacks", ... },  -- at most T.MAX_NOTES lines of T.MAX_NOTE characters
--     bg    = background,         -- the room (see below)
--     items = { item, ... },      -- at most T.MAX_ITEMS, drawn in this order (later ones on top)
--   }
--
--   background, one of:
--     { kind = "room", room = "round" }   -- a drawn room shape; the ids are in T.ROOMS (TacticsBoard.lua)
--     { kind = "map", map = 291, zoom = 30, cx = 500, cy = 500 }
--                                 -- the game's own map of a dungeon floor (uiMapID). zoom is 10 to 80
--                                 -- (10 = the whole map fits the board, 30 = three times closer);
--                                 -- cx, cy is the point of the map at the middle of the board, each
--                                 -- 0 to 1000 across the map's width and height.
--
--   item, one of (k says which; c is a colour, an index into T.COLORS, 1 when left out; s is a size
--   1 to 3, 2 when left out):
--     { k = "m", i = "tank", x =, y =, t = "MT", c =, s = }   -- a marker: an icon (ids in T.ICONS,
--                                 -- TacticsBoard.lua) with an optional short label t under it
--     { k = "p", n = "Akro Polis", cl = "MAGE", x =, y = }    -- one player, by name, in class colour
--     { k = "g", g = { 1, 2 }, x =, y =, t = "Left side" }    -- one or more raid groups (1 to 8) placed
--                                 -- as one team, with an optional label. Who is in the groups is
--                                 -- looked up in the viewer's own raid, so it is never sent.
--     { k = "a", x =, y =, x2 =, y2 =, c =, s = }             -- an arrow from x,y to x2,y2
--     { k = "l", p = { x1, y1, x2, y2, ... }, c =, s = }      -- a drawn line through 2 to T.MAX_POINTS points
--     { k = "z", x =, y =, r = 80, c = }                      -- a round area (stand here / stay out), radius r
--     { k = "t", x =, y =, t = "Stack here", c =, s = }       -- a text on the board
--
-- An icon or room id this version does not know is kept as it is and drawn as
-- a plain marker or room: a leader with a newer version may send one.
-- Everything read from saved data or received from someone else goes through
-- T.Sanitize first, so the rest of the code can trust a plan it is handed.
-- After T.Sanitize every field shown above is there: c and s are filled in, a
-- label t that was left out is "", a class cl that is not a class name is "",
-- a round area with no radius gets 80, and a scene always has title, notes,
-- bg and items. A text has no "|" (it becomes "/") and no line breaks. An item
-- that cannot be drawn (no place, a marker with no icon, a player with no
-- name, a text with no text, a line with fewer than 2 points, a kind this
-- version does not know) is left out.
--
-- A plan from T.Received() has three fields more: from (who showed it), at
-- (server time when it arrived) and kept (the id of the copy in your own
-- library, when T.KeepReceived made one that still exists).
--
-- WHAT THIS FILE GIVES THE OTHERS (T = DW.Tactics) ----------------------------------
--
--   The plan       T.NewPlan(name), T.NewScene(copyFrom), T.CopyPlan(plan),
--                  T.Sanitize(plan), T.SanitizeScene(scene)
--   Packing        T.EncodeScene / T.DecodeScene, T.EncodeHeader / T.DecodeHeader,
--                  T.PlanBytes(plan), T.MAX_BYTES
--   The library    T.Plans(), T.GetPlan(id), T.SavePlan(plan), T.DeletePlan(id),
--                  T.Received(), T.KeepReceived(id)
--   The catalogue  T.Instances(), T.InstanceMaps(instID), T.MapArt(uiMapID)
--   The group      T.Roster(), T.CanPresent(), T.IsMine(item)
--   The slideshow  T.Present(plan), T.ShowScene(n), T.Ping(x, y), T.StopPresenting(),
--                  T.Presenting(), T.Watching(), T.StopWatching()
--   Events         T.On(event, callback): "plans", "received", "present", "watch",
--                  "scene" (number), "ping" (x, y), "roster"
-- Functions that can refuse return a reason as the name of a text in
-- Locales.lua (TAC_ERR_...).

local ADDON_NAME, DW = ...
local L = DW.L

local T = {}
DW.Tactics = T

-- The board in board units (16:10).
T.BOARD_W, T.BOARD_H = 1000, 625

-- Limits. They keep a plan small enough to send to a raid in a few seconds.
T.MAX_SCENES = 10
T.MAX_ITEMS = 40   -- per scene
T.MAX_POINTS = 24  -- in one drawn line
T.MAX_NOTES = 5    -- lines per scene
T.MAX_NOTE = 90    -- characters in a note line
T.MAX_NAME = 40    -- characters in a plan name, boss name or scene title
T.MAX_LABEL = 24   -- characters in a label or a text on the board
T.MAX_RADIUS = 300 -- of a round area
T.MIN_ZOOM, T.MAX_ZOOM = 10, 80

-- The colours of markers, arrows, lines, areas and texts: { r, g, b, name }.
-- The name is the end of the text key (TAC_COLOR_WHITE, ...). The order must
-- not change: plans store the index.
T.COLORS = {
    { 1.00, 1.00, 1.00, "WHITE" },
    { 1.00, 0.25, 0.20, "RED" },
    { 1.00, 0.55, 0.10, "ORANGE" },
    { 1.00, 0.85, 0.15, "YELLOW" },
    { 0.30, 0.90, 0.30, "GREEN" },
    { 0.30, 0.70, 1.00, "BLUE" },
    { 0.75, 0.40, 1.00, "PURPLE" },
    { 0.10, 0.10, 0.10, "BLACK" },
}

-- The most a plan may weigh when it is packed for sending (T.PlanBytes).
-- That is about 27 messages: 10 go at once and the rest one per second.
T.MAX_BYTES = 6000
T.MAX_PLANS = 200    -- plans in your own library
T.MAX_RECEIVED = 10  -- plans kept from slideshows you have watched
T.PROTOCOL = 1       -- the version of the messages to the group

local MODULE_ID = "tactics"
local PREFIX = "DragonworldTac" -- name of the messages; max 16 characters
local SEP = "\t"

local DEFAULT_ROOM = "round"
local DEFAULT_COLOR, DEFAULT_SIZE, DEFAULT_RADIUS = 1, 2, 80
local MAX_ID = 12        -- characters in a plan, icon or room id
local MAX_TIME = 2147483647
local HEADER_BYTES = 230 -- a packed header fits in one message with this
local CHUNK_BYTES = 230  -- ...and so does a piece of a packed scene
local MAX_PARTS = 64     -- pieces of one scene accepted from someone else

local floor, ceil, min, max = math.floor, math.ceil, math.min, math.max
local unpack = table.unpack or unpack

-- Small things ------------------------------------------------------------------

local function PlainString(value)
    if type(value) == "string" and not DW.IsSecret(value) then
        return value
    end
    return nil
end

local function PlainNumber(value)
    if type(value) == "number" and not DW.IsSecret(value) then
        return value
    end
    return nil
end

local function PlainTrue(value)
    return not DW.IsSecret(value) and value == true
end

local function IsTable(value)
    return not DW.IsSecret(value) and type(value) == "table"
end

-- Calls a game function safely: nothing if it is missing or fails.
local function CountAndList(...)
    return select("#", ...), { ... }
end

local function Safe(fn, ...)
    if type(fn) ~= "function" then
        return nil
    end
    local count, result = CountAndList(pcall(fn, ...))
    if not result[1] then
        return nil
    end
    return unpack(result, 2, count)
end

-- A whole number from low to high, or `default` when the value is no number.
local function Whole(value, low, high, default)
    if DW.IsSecret(value) or type(value) ~= "number" or value ~= value then
        return default
    end
    return floor(max(low, min(high, value)) + 0.5)
end

-- The whole number a text of digits stands for, when it is from low to high.
local function Digits(text, low, high)
    if type(text) ~= "string" or #text > 6 or not text:match("^%d+$") then
        return nil
    end
    local number = tonumber(text)
    if number < low or number > high then
        return nil
    end
    return number
end

local DIGITS = "0123456789abcdefghijklmnopqrstuvwxyz"

local function Base36(number, width)
    local text = ""
    repeat
        local digit = number % 36
        text = DIGITS:sub(digit + 1, digit + 1) .. text
        number = floor(number / 36)
    until number == 0
    while width and #text < width do
        text = "0" .. text
    end
    return text
end

local function FromBase36(text)
    if type(text) ~= "string" or text == "" or text:find("[^%da-z]") then
        return nil
    end
    return tonumber(text, 36)
end

-- Splits a text at every `separator` (one character), keeping empty pieces.
local function Split(text, separator)
    local pieces, from = {}, 1
    while true do
        local at = text:find(separator, from, true)
        if not at then
            pieces[#pieces + 1] = text:sub(from)
            return pieces
        end
        pieces[#pieces + 1] = text:sub(from, at - 1)
        from = at + 1
    end
end

local function Copy(value)
    if type(value) ~= "table" then
        return value
    end
    local copy = {}
    for key, inner in pairs(value) do
        copy[key] = Copy(inner)
    end
    return copy
end

-- New ids. The time and a random number keep two players' ids apart, the
-- counter keeps two made in the same second apart.
local idCounter = 0

local function Random(below)
    return floor(math.random() * below) % below
end

local NewId -- (defined under "The library": it must not pick an id that is in use)

-- A short id for one slideshow.
local function NewSid()
    idCounter = idCounter + 1
    return Base36(Random(46656), 3) .. Base36(DW.ServerNow() % 1296, 2) .. Base36(idCounter % 1296, 2)
end

-- Events ------------------------------------------------------------------------
--
-- T.On(event, callback): the windows listen here.
--   "plans"     the library changed
--   "received"  the list of received plans changed
--   "present"   something in T.Presenting() changed
--   "watch"     a slideshow you watch started, got another scene, or ended
--   "scene"     the scene being shown changed, for the one who shows and the
--               ones who watch; the callback gets the scene's number
--   "ping"      the one who shows pointed at a spot; the callback gets x, y
--               (also called for the one who points)
--   "roster"    the group changed (who is in it, who leads, the roles)

local listeners = {}

function T.On(event, callback)
    if type(event) ~= "string" or type(callback) ~= "function" then
        return
    end
    listeners[event] = listeners[event] or {}
    table.insert(listeners[event], callback)
end

local function Emit(event, ...)
    local list = listeners[event]
    if not list then
        return
    end
    for index = 1, #list do
        -- An error in one window must not stop the others, or the messages.
        local ok, problem = pcall(list[index], ...)
        if not ok then
            DW.PrintError(L.ERROR, problem)
        end
    end
end

-- Checking a plan -----------------------------------------------------------------

-- How many bytes the UTF-8 letter starting with this byte has; 0 when no
-- letter starts with it.
local function LetterBytes(byte)
    if byte < 0x80 then
        return 1
    elseif byte >= 0xC2 and byte <= 0xDF then
        return 2
    elseif byte >= 0xE0 and byte <= 0xEF then
        return 3
    elseif byte >= 0xF0 and byte <= 0xF4 then
        return 4
    end
    return 0
end

-- A text that is safe to save, send and show: at most `limit` letters (a
-- letter of several bytes is never cut in two), no control characters, no
-- "|" (the game reads it as the start of a colour or a link), no broken
-- bytes, no spaces at the ends. Anything that is not a text gives "".
local function CleanText(value, limit)
    if DW.IsSecret(value) or type(value) ~= "string" then
        return ""
    end
    -- Most texts are short and plain: nothing to do.
    if #value <= limit and not value:find("[^\32-\123\125\126]") and value:sub(1, 1) ~= " " and value:sub(-1) ~= " " then
        return value
    end
    local out, count, index, length = {}, 0, 1, #value
    while index <= length and count < limit do
        local byte = value:byte(index)
        local size = LetterBytes(byte)
        local piece
        if size == 1 then
            if byte < 0x20 or byte == 0x7F then
                piece = " "
            elseif byte == 0x7C then
                piece = "/"
            else
                piece = value:sub(index, index)
            end
        elseif size > 1 and index + size - 1 <= length then
            piece = value:sub(index, index + size - 1)
            for inner = index + 1, index + size - 1 do
                local follow = value:byte(inner)
                if follow < 0x80 or follow > 0xBF then
                    piece = nil
                    break
                end
            end
        end
        if not piece then
            index = index + 1 -- a byte that belongs to no letter: left out
        else
            index = index + #piece
            -- Spaces at the start do not count and are not kept.
            if not (piece == " " and count == 0) then
                count = count + 1
                out[count] = piece
            end
        end
    end
    while count > 0 and out[count] == " " do
        out[count] = nil
        count = count - 1
    end
    return table.concat(out)
end

-- The same text with its last letter taken off.
local function DropLastLetter(text)
    local cut = #text
    while cut > 1 do
        local byte = text:byte(cut)
        if byte < 0x80 or byte > 0xBF then
            break
        end
        cut = cut - 1
    end
    return text:sub(1, cut - 1)
end

-- An id: small letters and digits, at most MAX_ID of them. nil for anything else.
local function CleanId(value)
    if PlainString(value) and #value <= MAX_ID and value:match("^[%l%d]+$") then
        return value
    end
    return nil
end

local function CleanBackground(bg)
    if IsTable(bg) then
        if bg.kind == "map" then
            local map = Whole(bg.map, 1, 999999)
            if map then
                return {
                    kind = "map", map = map,
                    zoom = Whole(bg.zoom, T.MIN_ZOOM, T.MAX_ZOOM, T.MIN_ZOOM),
                    cx = Whole(bg.cx, 0, 1000, 500),
                    cy = Whole(bg.cy, 0, 1000, 500),
                }
            end
        elseif bg.kind == "room" then
            local room = CleanId(bg.room)
            if room then
                return { kind = "room", room = room }
            end
        end
    end
    return { kind = "room", room = DEFAULT_ROOM }
end

local function CleanColor(value)
    return Whole(value, 1, #T.COLORS, DEFAULT_COLOR)
end

local function CleanSize(value)
    return Whole(value, 1, 3, DEFAULT_SIZE)
end

-- The points of a drawn line: x1, y1, x2, y2, ... nil if it is not a line.
local function CleanPoints(list)
    if not IsTable(list) then
        return nil
    end
    local points = {}
    for index = 1, T.MAX_POINTS * 2 do
        local value = list[index]
        if value == nil then
            break
        end
        value = Whole(value, 0, (index % 2 == 1) and T.BOARD_W or T.BOARD_H)
        if not value then
            return nil
        end
        points[index] = value
    end
    if #points % 2 == 1 then
        points[#points] = nil
    end
    if #points < 4 then
        return nil
    end
    return points
end

-- The raid groups of a "g" item: 1 to 8, each once, lowest first.
local function CleanGroups(list)
    if not IsTable(list) then
        return nil
    end
    local seen, groups = {}, {}
    for index = 1, 16 do
        local value = list[index]
        if value == nil then
            break
        end
        value = PlainNumber(value)
        if value and value >= 1 and value <= 8 and value == floor(value) and not seen[value] then
            seen[value] = true
            groups[#groups + 1] = value
        end
    end
    if #groups == 0 then
        return nil
    end
    table.sort(groups)
    return groups
end

-- One item, clean, or nil when it cannot be drawn.
local function CleanItem(item)
    if not IsTable(item) then
        return nil
    end
    local kind = item.k
    if kind == "l" then
        local points = CleanPoints(item.p)
        if not points then
            return nil
        end
        return { k = "l", p = points, c = CleanColor(item.c), s = CleanSize(item.s) }
    end

    local x, y = Whole(item.x, 0, T.BOARD_W), Whole(item.y, 0, T.BOARD_H)
    if not x or not y then
        return nil
    end
    if kind == "m" then
        local icon = CleanId(item.i)
        if not icon then
            return nil
        end
        return { k = "m", i = icon, x = x, y = y, t = CleanText(item.t, T.MAX_LABEL), c = CleanColor(item.c), s = CleanSize(item.s) }
    elseif kind == "p" then
        local name = CleanText(item.n, T.MAX_NAME)
        if name == "" then
            return nil
        end
        local class = PlainString(item.cl)
        if not class or #class > MAX_ID or not class:match("^%u+$") then
            class = ""
        end
        return { k = "p", n = name, cl = class, x = x, y = y }
    elseif kind == "g" then
        local groups = CleanGroups(item.g)
        if not groups then
            return nil
        end
        return { k = "g", g = groups, x = x, y = y, t = CleanText(item.t, T.MAX_LABEL) }
    elseif kind == "a" then
        local x2, y2 = Whole(item.x2, 0, T.BOARD_W), Whole(item.y2, 0, T.BOARD_H)
        if not x2 or not y2 then
            return nil
        end
        return { k = "a", x = x, y = y, x2 = x2, y2 = y2, c = CleanColor(item.c), s = CleanSize(item.s) }
    elseif kind == "z" then
        return { k = "z", x = x, y = y, r = Whole(item.r, 1, T.MAX_RADIUS, DEFAULT_RADIUS), c = CleanColor(item.c) }
    elseif kind == "t" then
        local text = CleanText(item.t, T.MAX_LABEL)
        if text == "" then
            return nil
        end
        return { k = "t", x = x, y = y, t = text, c = CleanColor(item.c), s = CleanSize(item.s) }
    end
    return nil
end

local function EmptyScene()
    return { title = "", notes = {}, bg = { kind = "room", room = DEFAULT_ROOM }, items = {} }
end

local function CleanScene(scene)
    if not IsTable(scene) then
        return EmptyScene()
    end
    local clean = { title = CleanText(scene.title, T.MAX_NAME), notes = {}, bg = CleanBackground(scene.bg), items = {} }
    if IsTable(scene.notes) then
        for index = 1, T.MAX_NOTES * 4 do
            local line = scene.notes[index]
            if line == nil or #clean.notes >= T.MAX_NOTES then
                break
            end
            line = CleanText(line, T.MAX_NOTE)
            if line ~= "" then
                clean.notes[#clean.notes + 1] = line
            end
        end
    end
    if IsTable(scene.items) then
        -- Broken items are skipped, so look a bit further than the limit.
        for index = 1, T.MAX_ITEMS * 4 do
            local item = scene.items[index]
            if item == nil or #clean.items >= T.MAX_ITEMS then
                break
            end
            item = CleanItem(item)
            if item then
                clean.items[#clean.items + 1] = item
            end
        end
    end
    return clean
end

local function CleanPlan(plan)
    if not IsTable(plan) then
        return nil
    end
    local clean = {
        id = CleanId(plan.id) or NewId(),
        name = CleanText(plan.name, T.MAX_NAME),
        inst = Whole(plan.inst, 0, 9999, 0),
        instName = CleanText(plan.instName, T.MAX_NAME),
        boss = CleanText(plan.boss, T.MAX_NAME),
        author = CleanText(plan.author, T.MAX_NAME),
        updated = Whole(plan.updated, 0, MAX_TIME, 0),
        scenes = {},
    }
    local dungeon = DW.DUNGEON_BY_ID and DW.DUNGEON_BY_ID[clean.inst]
    if clean.instName == "" and dungeon then
        clean.instName = CleanText(dungeon.name, T.MAX_NAME)
    end
    if IsTable(plan.scenes) then
        for index = 1, T.MAX_SCENES do
            local scene = plan.scenes[index]
            if scene == nil then
                break
            end
            clean.scenes[index] = CleanScene(scene)
        end
    end
    if #clean.scenes == 0 then
        clean.scenes[1] = EmptyScene()
    end
    return clean
end

-- A clean copy of a scene: every number whole and in range, every text cut
-- to its limit, broken items left out. Never fails: garbage gives an empty scene.
function T.SanitizeScene(scene)
    local ok, clean = pcall(CleanScene, scene)
    if ok and type(clean) == "table" then
        return clean
    end
    return EmptyScene()
end

-- A clean copy of a plan, or nil when it is not a plan at all. A plan with no
-- usable id gets a new one, and a plan with no scenes gets an empty one.
function T.Sanitize(plan)
    local ok, clean = pcall(CleanPlan, plan)
    if ok and type(clean) == "table" then
        return clean
    end
    return nil
end

-- Packing -------------------------------------------------------------------------
--
-- A scene as a short text, for sending. Records are separated by ";":
--   title ; background ; notes ; item ; item ; ...
-- and the fields inside a record by ",". Empty fields at the end of a record
-- are left out, and so is a value that is the usual one (colour 1, size 2,
-- zoom 10, the middle of the map). In a text, "~", ";" and "," are written
-- "~0", "~1" and "~2", so a text can never end a record or a field.
--   background  r<room>                       or  m<map>,<zoom>,<cx>,<cy>
--   notes       <line>,<line>,...
-- A place is four characters: x and y, each two digits in base 36.
--   marker      m<place><icon>,<label>,<colour>,<size>
--   player      p<place><class>,<name>        class: its place in CLASSES as one base 36
--                                             digit, or the class name when it is not there
--   groups      g<place><group digits>,<label>
--   arrow       a<place><place of the tip>,<colour>,<size>
--   line        l<place><place>...,<colour>,<size>
--   area        z<place><radius in base 36>,<colour>
--   text        t<place><text>,<colour>,<size>
-- A packed text has only printable characters and letters, never a tab or a
-- zero byte, so it can go in an addon message as it is.

local ESCAPE = { ["~"] = "~0", [";"] = "~1", [","] = "~2" }
local UNESCAPE = { ["0"] = "~", ["1"] = ";", ["2"] = "," }

-- The classes, so a packed player needs one character for the class. The
-- order must not change (add new ones at the end): both ends count in it.
local CLASSES = {
    "WARRIOR", "PALADIN", "HUNTER", "ROGUE", "PRIEST", "DEATHKNIGHT", "SHAMAN",
    "MAGE", "WARLOCK", "MONK", "DRUID", "DEMONHUNTER", "EVOKER",
}
local CLASS_CODE = {}
for index, class in ipairs(CLASSES) do
    CLASS_CODE[class] = Base36(index)
end

local function Escape(text)
    return (text:gsub("[~;,]", ESCAPE))
end

local function Unescape(text)
    return ((text or ""):gsub("~([012])", UNESCAPE))
end

-- Fields joined with ",", without the empty ones at the end.
local function Record(...)
    return (table.concat({ ... }, ","):gsub(",+$", ""))
end

local function Unless(value, usual)
    if value == usual then
        return ""
    end
    return value
end

local function Place(x, y)
    return Base36(x, 2) .. Base36(y, 2)
end

local function FromPlace(text)
    if #text ~= 4 then
        return nil
    end
    return FromBase36(text:sub(1, 2)), FromBase36(text:sub(3, 4))
end

local function PackBackground(bg)
    if bg.kind == "map" then
        return "m" .. Record(bg.map, Unless(bg.zoom, T.MIN_ZOOM), Unless(bg.cx, 500), Unless(bg.cy, 500))
    end
    return "r" .. bg.room
end

local function PackItem(item)
    local kind = item.k
    local colour, size = Unless(item.c, DEFAULT_COLOR), Unless(item.s, DEFAULT_SIZE)
    if kind == "l" then
        local places = {}
        for index = 1, #item.p, 2 do
            places[#places + 1] = Place(item.p[index], item.p[index + 1])
        end
        return "l" .. Record(table.concat(places), colour, size)
    end
    local place = kind .. Place(item.x, item.y)
    if kind == "m" then
        return place .. Record(item.i, Escape(item.t), colour, size)
    elseif kind == "p" then
        return place .. Record(CLASS_CODE[item.cl] or item.cl, Escape(item.n))
    elseif kind == "g" then
        return place .. Record(table.concat(item.g), Escape(item.t))
    elseif kind == "a" then
        return place .. Record(Place(item.x2, item.y2), colour, size)
    elseif kind == "z" then
        return place .. Record(Base36(item.r), colour)
    end
    return place .. Record(Escape(item.t), colour, size)
end

local function PackScene(clean)
    local records = { Escape(clean.title), PackBackground(clean.bg) }
    local notes = {}
    for index, line in ipairs(clean.notes) do
        notes[index] = Escape(line)
    end
    records[3] = table.concat(notes, ",")
    for _, item in ipairs(clean.items) do
        records[#records + 1] = PackItem(item)
    end
    return table.concat(records, ";")
end

local function UnpackBackground(record)
    local kind, rest = record:sub(1, 1), record:sub(2)
    if kind == "m" then
        local fields = Split(rest, ",")
        return { kind = "map", map = tonumber(fields[1]), zoom = tonumber(fields[2]), cx = tonumber(fields[3]), cy = tonumber(fields[4]) }
    elseif kind == "r" then
        return { kind = "room", room = rest }
    end
    return nil
end

local function UnpackItem(record)
    local kind = record:sub(1, 1)
    if kind == "l" then
        local fields = Split(record:sub(2), ",")
        local places, points = fields[1], {}
        for index = 1, #places, 4 do
            local x, y = FromPlace(places:sub(index, index + 3))
            points[#points + 1] = x or false
            points[#points + 1] = y or false
        end
        return { k = "l", p = points, c = tonumber(fields[2]), s = tonumber(fields[3]) }
    end
    local x, y = FromPlace(record:sub(2, 5))
    local fields = Split(record:sub(6), ",")
    if kind == "m" then
        return { k = "m", i = fields[1], x = x, y = y, t = Unescape(fields[2]), c = tonumber(fields[3]), s = tonumber(fields[4]) }
    elseif kind == "p" then
        local class = fields[1]
        if not class:match("^%u+$") then
            class = CLASSES[FromBase36(class) or 0]
        end
        return { k = "p", cl = class, n = Unescape(fields[2]), x = x, y = y }
    elseif kind == "g" then
        local groups = {}
        for digit in fields[1]:gmatch("%d") do
            groups[#groups + 1] = tonumber(digit)
        end
        return { k = "g", g = groups, x = x, y = y, t = Unescape(fields[2]) }
    elseif kind == "a" then
        local x2, y2 = FromPlace(fields[1])
        return { k = "a", x = x, y = y, x2 = x2, y2 = y2, c = tonumber(fields[2]), s = tonumber(fields[3]) }
    elseif kind == "z" then
        return { k = "z", x = x, y = y, r = FromBase36(fields[1]), c = tonumber(fields[2]) }
    elseif kind == "t" then
        return { k = "t", x = x, y = y, t = Unescape(fields[1]), c = tonumber(fields[2]), s = tonumber(fields[3]) }
    end
    return nil
end

local function UnpackScene(text)
    local records = Split(text, ";")
    if #records < 3 then
        return nil
    end
    local scene = { title = Unescape(records[1]), bg = UnpackBackground(records[2]), notes = {}, items = {} }
    if records[3] ~= "" then
        for index, line in ipairs(Split(records[3], ",")) do
            scene.notes[index] = Unescape(line)
        end
    end
    for index = 4, #records do
        -- A record we cannot read becomes a broken item, which CleanScene leaves out.
        scene.items[#scene.items + 1] = UnpackItem(records[index]) or false
    end
    return CleanScene(scene)
end

-- A scene as a text for sending. The scene is checked first, so anything can
-- be handed in.
function T.EncodeScene(scene)
    return PackScene(T.SanitizeScene(scene))
end

-- The scene a packed text stands for, checked like T.SanitizeScene does; nil
-- when the text is no packed scene.
function T.DecodeScene(text)
    if not PlainString(text) or #text > 20000 then
        return nil
    end
    local ok, scene = pcall(UnpackScene, text)
    if ok and IsTable(scene) then
        return scene
    end
    return nil
end

-- What a group needs to know about a plan before its scenes arrive: id, name,
-- inst, instName, boss, author, updated and the number of scenes, as one text
-- of at most HEADER_BYTES bytes. If the names are too long for that (only with
-- letters of several bytes each), the longest is shortened until it fits.
local function PackHeader(plan)
    if not IsTable(plan) then
        plan = {}
    end
    local count = 1
    if IsTable(plan.scenes) then
        count = max(1, min(T.MAX_SCENES, #plan.scenes))
    end
    local id, inst, updated = CleanId(plan.id) or NewId(), Whole(plan.inst, 0, 9999, 0), Whole(plan.updated, 0, MAX_TIME, 0)
    local texts = {
        CleanText(plan.name, T.MAX_NAME), CleanText(plan.instName, T.MAX_NAME),
        CleanText(plan.boss, T.MAX_NAME), CleanText(plan.author, T.MAX_NAME),
    }
    while true do
        local header = table.concat({ id, Escape(texts[1]), inst, Escape(texts[2]), Escape(texts[3]), Escape(texts[4]), updated, count }, ",")
        if #header <= HEADER_BYTES then
            return header
        end
        local longest = 1
        for index = 2, #texts do
            if #texts[index] > #texts[longest] then
                longest = index
            end
        end
        if texts[longest] == "" then
            return header -- cannot happen: the rest is a few numbers
        end
        texts[longest] = DropLastLetter(texts[longest])
    end
end

function T.EncodeHeader(plan)
    local ok, header = pcall(PackHeader, plan)
    if ok then
        return header
    end
    return PackHeader(nil)
end

-- { id, name, inst, instName, boss, author, updated, count } from a packed
-- header (count is the number of scenes), or nil when it is not one.
function T.DecodeHeader(text)
    if not PlainString(text) or #text > 255 then
        return nil
    end
    local fields = Split(text, ",")
    local id, count = CleanId(fields[1]), Digits(fields[8], 1, T.MAX_SCENES)
    if #fields ~= 8 or not id or not count then
        return nil
    end
    return {
        id = id,
        name = CleanText(Unescape(fields[2]), T.MAX_NAME),
        inst = Whole(tonumber(fields[3]), 0, 9999, 0),
        instName = CleanText(Unescape(fields[4]), T.MAX_NAME),
        boss = CleanText(Unescape(fields[5]), T.MAX_NAME),
        author = CleanText(Unescape(fields[6]), T.MAX_NAME),
        updated = Whole(tonumber(fields[7]), 0, MAX_TIME, 0),
        count = count,
    }
end

-- A checked plan packed for sending: the header, each scene, and the bytes of
-- all of it.
local function PackPlan(clean)
    local header, scenes = PackHeader(clean), {}
    local bytes = #header
    for index, scene in ipairs(clean.scenes) do
        scenes[index] = PackScene(scene)
        bytes = bytes + #scenes[index]
    end
    return header, scenes, bytes
end

-- How many bytes a plan is when packed: T.Present refuses more than T.MAX_BYTES.
function T.PlanBytes(plan)
    local clean = T.Sanitize(plan)
    if not clean then
        return 0
    end
    local _, _, bytes = PackPlan(clean)
    return bytes
end

-- Names and the group ---------------------------------------------------------------

local function Squash(text)
    return (text:lower():gsub("%s+", ""))
end

local function MyRealm()
    local realm = PlainString(Safe(GetNormalizedRealmName))
    if realm and realm ~= "" then
        return Squash(realm)
    end
    return nil
end

-- A character's name the way it is shown and stored in a plan: first and last
-- name with a space between, without the realm you play on. Forever gives the
-- same name as "First Last", as "First-Last", or as name and realm apart.
local function ShownName(name, realm)
    name = PlainString(name)
    if not name or name == "" then
        return nil
    end
    local mine = MyRealm()
    local first, last = name:match("^(.+)%-([^%-]+)$")
    if first then
        name = (mine and Squash(last) == mine) and first or (first .. " " .. last)
    end
    realm = PlainString(realm)
    if realm and realm ~= "" and not (mine and Squash(realm) == mine) then
        name = name .. " " .. realm
    end
    return name
end

local function MyName()
    local _, name, realm = DW.CharacterKey()
    return ShownName(name, realm)
end

-- A yes or no from the game: true, false, or nil when it does not say (the
-- function is missing, it failed, or the answer is secret). What is done on a
-- plain "no" (ending a slideshow) must not be done on "do not know".
local function YesNo(value)
    if DW.IsSecret(value) or type(value) ~= "boolean" then
        return nil
    end
    return value
end

local function InGroup()
    return PlainTrue(Safe(IsInGroup))
end

local function InRaid()
    return InGroup() and PlainTrue(Safe(IsInRaid))
end

-- The unit tokens of the other members of the group. In a raid the list may
-- hold you as well: the game can refuse to say which raid unit you are, and
-- DW.GroupUnits leaves those out, which would hide the whole raid from us.
local function GroupUnitList()
    if not InRaid() then
        return DW.GroupUnits()
    end
    local units = {}
    for index = 1, min(40, PlainNumber(Safe(GetNumGroupMembers)) or 0) do
        units[index] = "raid" .. index
    end
    return units
end

-- The unit of the group member with this name (as a message's sender is
-- written), and the name as we show it. nil when nobody in the group has it;
-- then the third value is true if the game hid someone's name, so that it
-- may still be one of them.
local function UnitOf(who)
    local units = GroupUnitList()
    local unsure = #units < (PlainNumber(Safe(GetNumGroupMembers)) or 0) - 1
    local found, foundName, several
    for _, unit in ipairs(units) do
        local name = ShownName(Safe(UnitName, unit))
        if not name then
            unsure = true
        elseif DW.SameCharacter(who, name) then
            if found then
                several = true
            else
                found, foundName = unit, name
            end
        end
    end
    -- A name that fits two members is nobody's: one of them may be the leader
    -- and the other not, and we cannot tell who it was.
    if found and not several then
        return found, foundName
    end
    return nil, nil, unsure or several == true
end

-- May this group member show a slideshow? The leader, and in a raid the
-- assistants too. true, false, or nil when the game does not say.
local function MayPresent(unit)
    local leader = YesNo(Safe(UnitIsGroupLeader, unit))
    if leader == true then
        return true
    end
    local assistant = false
    if InRaid() then
        assistant = YesNo(Safe(UnitIsGroupAssistant, unit))
        if assistant == true then
            return true
        end
    end
    if leader == nil or assistant == nil then
        return nil
    end
    return false
end

-- The plan --------------------------------------------------------------------------

-- A new scene. With copyFrom it starts with that scene's room, items and
-- notes (the next phase of a fight usually starts from the previous one).
function T.NewScene(copyFrom)
    local scene = EmptyScene()
    if IsTable(copyFrom) then
        local clean = T.SanitizeScene(copyFrom)
        scene.bg, scene.items, scene.notes = clean.bg, clean.items, clean.notes
    end
    return scene
end

-- A new plan with one empty scene. It is not saved until T.SavePlan.
function T.NewPlan(name)
    return {
        id = NewId(),
        name = CleanText(name, T.MAX_NAME),
        inst = 0, instName = "", boss = "",
        author = MyName() or "",
        updated = DW.ServerNow(),
        scenes = { EmptyScene() },
    }
end

-- A copy of a plan under a new id (nil when it is not a plan).
function T.CopyPlan(plan)
    local copy = T.Sanitize(plan)
    if copy then
        copy.id = NewId()
    end
    return copy
end

-- The library -----------------------------------------------------------------------
--
-- Saved for the account (DragonworldDB.modules.tactics):
--   plans[id]   your own plans
--   received    the plans from slideshows you have watched, newest first, at
--               most T.MAX_RECEIVED, one per plan id; each with from, at, kept
-- The saved data is checked the first time it is used in a session, not at
-- login: a big library takes a moment.

local saved -- the module's saved table
local savedChecked = false

NewId = function()
    local plans = (type(saved) == "table" and type(saved.plans) == "table") and saved.plans or {}
    while true do
        idCounter = idCounter + 1
        local id = "p" .. Base36(DW.ServerNow() % 60466176, 5) .. Base36(Random(46656), 3) .. Base36(idCounter % 1296, 2)
        if not plans[id] then
            return id
        end
    end
end

local function CleanReceived(list)
    local clean, seen = {}, {}
    if not IsTable(list) then
        return clean
    end
    for index = 1, T.MAX_RECEIVED * 4 do
        local entry = list[index]
        if entry == nil or #clean >= T.MAX_RECEIVED then
            break
        end
        local plan = T.Sanitize(entry)
        if plan and not seen[plan.id] then
            seen[plan.id] = true
            plan.from = CleanText(entry.from, T.MAX_NAME)
            plan.at = Whole(entry.at, 0, MAX_TIME, 0)
            plan.kept = CleanId(entry.kept)
            clean[#clean + 1] = plan
        end
    end
    return clean
end

-- The saved table, checked; nil before the saved data has been read.
local function Library()
    if type(saved) ~= "table" then
        return nil
    end
    if not savedChecked then
        savedChecked = true
        local plans, count = {}, 0
        if type(saved.plans) == "table" then
            for _, plan in pairs(saved.plans) do
                local clean = T.Sanitize(plan)
                -- (A saved plan always has a name: one without is damage.)
                if clean and clean.name ~= "" and not plans[clean.id] and count < T.MAX_PLANS then
                    plans[clean.id] = clean
                    count = count + 1
                end
            end
        end
        saved.plans = plans
        saved.received = CleanReceived(saved.received)
    end
    return saved
end

local function Lower(text)
    return text:lower()
end

-- Your saved plans as copies, sorted by dungeon or raid, boss and name.
function T.Plans()
    local library = Library()
    local list = {}
    for _, plan in pairs(library and library.plans or {}) do
        list[#list + 1] = Copy(plan)
    end
    table.sort(list, function(a, b)
        local x, y = Lower(a.instName), Lower(b.instName)
        if x ~= y then
            return x < y
        end
        x, y = Lower(a.boss), Lower(b.boss)
        if x ~= y then
            return x < y
        end
        x, y = Lower(a.name), Lower(b.name)
        if x ~= y then
            return x < y
        end
        return a.id < b.id
    end)
    return list
end

-- A copy of one saved plan, or nil.
function T.GetPlan(id)
    local library = Library()
    local plan = library and PlainString(id) and library.plans[id]
    return plan and Copy(plan) or nil
end

-- Saves a plan (new, or over the one with the same id), with you as the
-- author and the time now. Returns a copy of what was saved, or nil and why:
-- TAC_ERR_BAD_PLAN, TAC_ERR_NO_NAME or TAC_ERR_FULL.
function T.SavePlan(plan)
    local library = Library()
    local clean = library and T.Sanitize(plan)
    if not clean then
        return nil, "TAC_ERR_BAD_PLAN"
    end
    if clean.name == "" then
        return nil, "TAC_ERR_NO_NAME"
    end
    if not library.plans[clean.id] then
        local count = 0
        for _ in pairs(library.plans) do
            count = count + 1
        end
        if count >= T.MAX_PLANS then
            return nil, "TAC_ERR_FULL"
        end
    end
    clean.author = MyName() or clean.author
    clean.updated = DW.ServerNow()
    library.plans[clean.id] = clean
    Emit("plans")
    return Copy(clean)
end

-- Deletes a saved plan. True if there was one.
function T.DeletePlan(id)
    local library = Library()
    if not library or not PlainString(id) or not library.plans[id] then
        return false
    end
    library.plans[id] = nil
    Emit("plans")
    Emit("received") -- a received plan may have pointed at it (kept)
    return true
end

-- The plans from slideshows you have watched, as copies, newest first. Each
-- has from, at and kept as well (see the top of the file).
function T.Received()
    local library = Library()
    local list = {}
    for index, entry in ipairs(library and library.received or {}) do
        local copy = Copy(entry)
        if copy.kept and not library.plans[copy.kept] then
            copy.kept = nil
        end
        list[index] = copy
    end
    return list
end

-- Copies a received plan into your own library, under a new id, with its
-- author and time as they were. Returns a copy of the new plan, or nil and
-- why (TAC_ERR_BAD_PLAN: no such plan; TAC_ERR_FULL).
function T.KeepReceived(id)
    local library = Library()
    if not library then
        return nil, "TAC_ERR_BAD_PLAN"
    end
    for _, entry in ipairs(library.received) do
        if entry.id == id then
            local count = 0
            for _ in pairs(library.plans) do
                count = count + 1
            end
            if count >= T.MAX_PLANS then
                return nil, "TAC_ERR_FULL"
            end
            local plan = T.Sanitize(entry) -- leaves from, at and kept behind
            plan.id = NewId()
            if plan.name == "" then
                -- A saved plan must have a name (see Library).
                plan.name = (plan.boss ~= "" and plan.boss) or (plan.instName ~= "" and plan.instName) or L.TAC_TITLE
            end
            library.plans[plan.id] = plan
            entry.kept = plan.id
            Emit("plans")
            Emit("received")
            return Copy(plan)
        end
    end
    return nil, "TAC_ERR_BAD_PLAN"
end

-- Puts a plan that was shown to us first in the received list.
local function AddReceived(plan, from)
    local library = Library()
    local entry = library and T.Sanitize(plan)
    if not entry then
        return
    end
    local list = library.received
    for index = #list, 1, -1 do
        if list[index].id == entry.id then
            entry.kept = list[index].kept -- the copy in the library is still of this plan
            table.remove(list, index)
        end
    end
    entry.from = CleanText(from, T.MAX_NAME)
    entry.at = DW.ServerNow()
    table.insert(list, 1, entry)
    while #list > T.MAX_RECEIVED do
        list[#list] = nil
    end
    Emit("received")
end

-- The catalogue -----------------------------------------------------------------------
--
-- The bosses of each dungeon in DW.DUNGEONS (by its id), with the game's own
-- names, and the game's maps of its floors (uiMapID). The map ids are the ones
-- that had map art on build 1.60.1; they can differ between builds, so they
-- are checked before use, and a dungeon with none is looked up by name.
-- Forever's own new dungeons have no map art. The raids have no boss list
-- here: the game's journal is asked instead, and the leader can always type
-- a boss name.

local CATALOGUE = {
    [1] = { bosses = "Faldrim Anvilmar;Magmatus;Plunder;Durgen Dirgehammer" },
    [2] = { maps = { 213 }, bosses = "Oggleflint;Taragaman the Hungerer;Jergosh the Invoker;Bazzalan" },
    [3] = { bosses = "The Baron;Witherfang;Viktor the Vile;The Abandoned;Bjork;Rath'mael" },
    [4] = { maps = { 291, 292 }, bosses = "Rhahk'Zor;Sneed's Shredder;Gilnid;Mr. Smite;Captain Greenskin;Edwin VanCleef;Cookie" },
    [5] = { maps = { 279 }, bosses = "Lord Cobrahn;Lady Anacondra;Kresh;Lord Pythas;Skum;Lord Serpentis;Verdan the Everliving;Mutanus the Devourer" },
    [6] = { maps = { 310, 316, 315 }, bosses = "Rethilgore;Razorclaw the Butcher;Baron Silverlaine;Commander Springvale;Odo the Blindwatcher;"
        .. "Fenrus the Devourer;Wolf Master Nandos;Archmage Arugal" },
    [7] = { maps = { 221, 222, 223 }, bosses = "Ghamoo-ra;Lady Sarevess;Gelihast;Lorgus Jett;Old Serra'kis;Twilight Lord Kelris;Aku'mai" },
    [8] = { maps = { 225 }, bosses = "Targorr the Dread;Kam Deepfury;Hamhock;Dextren Ward;Bazil Thredd" },
    [9] = { bosses = "Saltspine;Shadetooth;Relic Guardian" },
    [10] = { bosses = "Atrexis the Grave Knight;Arcane Anomaly;Fel Ancient;Unstable Sentinel;Mana Devourer;Arcanic Enigma;Shade of the Archmage" },
    [11] = { maps = { 226, 227, 228, 229 }, bosses = "Grubbis;Viscous Fallout;Electrocutioner 6000;Crowd Pummeler 9-60;Mekgineer Thermaplugg" },
    [12] = { maps = { 301 }, bosses = "Roogug;Aggem Thorncurse;Death Speaker Jargba;Overlord Ramtusk;Agathelos the Raging;Charlga Razorflank" },
    [13] = { maps = { 302 }, bosses = "Interrogator Vishas;Bloodmage Thalnos" },
    [14] = { maps = { 303 }, bosses = "Houndmaster Loksey;Arcanist Doan" },
    [15] = { bosses = "Zul'Alai;Var'Taka;Captain Dreadrise;Deathless Marrow;Min'loth the Serpent" },
    [16] = { maps = { 304 }, bosses = "Herod" },
    [17] = { maps = { 305 }, bosses = "High Inquisitor Fairbanks;Scarlet Commander Mograine;High Inquisitor Whitemane" },
    [18] = { maps = { 300 }, bosses = "Tuten'kash;Plaguemaw the Rotting;Mordresh Fire Eye;Glutton;Amnennar the Coldbringer" },
    [19] = { bosses = "Slavecrusher Grox;Twilight Commander Zarmok;War Handler Ashka;Nar'gurk;Bossman Toof;Overlord Mugg" },
    [20] = { maps = { 230, 231 }, bosses = "Revelosh;The Lost Dwarves;Ironaya;Obsidian Sentinel;Ancient Stone Keeper;Galgann Firehammer;Grimlok;Archaedas" },
    [21] = { bosses = "Theka the Martyr;Antu'sul;Witch Doctor Zum'rah;Nekrum Gutchewer;Shadowpriest Sezz'ziz;Sergeant Bly;Hydromancer Velratha;"
        .. "Gahz'rilla;Ruuzlu;Chief Ukorz Sandscalp" },
    [22] = { maps = { 280, 281 }, bosses = "Noxxion;Razorlash;Lord Vyletongue;Celebras the Cursed;Landslide;Tinkerer Gizlock;Rotgrip;Princess Theradras" },
    [23] = { bosses = "Overseer Wrex;The Questioner;Tidemistress Ca'zass;Katerina the Cleaner;Blazeroar" },
    [24] = { bosses = "Atal'alarion;Morphaz & Hazzas;Jammal'an the Prophet;Ogom the Wretched;Dreamscythe & Weaver;Shade of Eranikus;Avatar of Hakkar" },
    [25] = { maps = { 242, 243 }, bosses = "High Interrogator Gerstahn;Lord Roccor;Houndmaster Grebmar;Ring of Law;Pyromancer Loregrain;"
        .. "Fineous Darkvire;Warder Stilgiss;Lord Incendius;Bael'Gar;General Angerforge;Golem Lord Argelmach;Hurley Blackbreath;Phalanx;"
        .. "Ribbly Screwspigot;Plugger Spazzring;Ambassador Flamelash;The Seven;Magmus;Princess Moira Bronzebeard;Emperor Dagran Thaurissan" },
    [26] = { bosses = "Highlord Omokk;Shadow Hunter Vosh'gajin;War Master Voone;Mother Smolderweb;Urok Doomhowl;Quartermaster Zigris;Halycon;"
        .. "Gizrul the Slavener;Overlord Wyrmthalak" },
    [27] = { bosses = "Pyroguard Emberseer;Solakar Flamewreath;Goraluk Anvilcrack;Gyth;Warchief Rend Blackhand;The Beast;General Drakkisath" },
    [28] = { maps = { 240, 239 }, bosses = "Pusillin;Zevrim Thornhoof;Hydrospawn;Lethtendris;Alzzin the Wildshaper" },
    [29] = { maps = { 236, 237, 238 }, bosses = "Tendris Warpwood;Magister Kalendris;Illyanna Ravenoak;Immol'thar;Prince Tortheldrin" },
    [30] = { maps = { 235 }, bosses = "Guard Mol'dar;Stomper Kreeg;Guard Fengus;Guard Slip'kik;Captain Kromcrush;Cho'Rush the Observer;King Gordok" },
    [31] = { bosses = "Impaan the Imprisoner;Bonesnout the Unbroken;Withermaw;Elder Shaman Bloodmane;Blackmaw Behemoth;Unbound Spirit;Varrox Bleakhoof" },
    [32] = { maps = { 317 }, bosses = "The Unforgiven;Timmy the Cruel;Malor the Zealous;Postmaster Malown;Cannon Master Willey;Archivist Galford;Balnazzar" },
    [33] = { maps = { 318 }, bosses = "Nerub'enkan;Baroness Anastari;Maleki the Pallid;Magistrate Barthilas;Ramstein the Gorger;Baron Rivendare" },
    [34] = { maps = { 306, 307, 308, 309 }, bosses = "Kirtonos the Herald;Jandice Barov;Rattlegore;Marduk Blackpool;Vectus;Ras Frostwhisper;"
        .. "Instructor Malicia;Doctor Theolen Krastinov;Lorekeeper Polkelt;The Ravenian;Lord Alexei Barov;Lady Illucia Barov;Darkmaster Gandling" },
    [35] = { bosses = "Titanosaur;Venomridge;Thunderhoof;Direhorn Matriarch;Cinder;Bolt;Snowtalon;Vitrix;Izha'Rel and Tor'Rel;Nanaya" },
}

local MAP_DUNGEON = (Enum and Enum.UIMapType and Enum.UIMapType.Dungeon) or 4
local MAP_SCAN_TO = 3000  -- the highest map id looked at when a dungeon's maps are found by name
local JOURNAL_RETRY = 60  -- seconds before the journal is asked again after it gave nothing

-- A name without capitals, spaces and punctuation, for comparing.
local function Norm(text)
    return (text:lower():gsub("[^%w\128-\255]", ""))
end

-- The bosses the game's journal has for the instances with no list above:
-- journal[dungeon id] = { "name", ... }.
local journal = {}
local journalAskedAt

-- Reads the bosses of one journal instance (already found by its index).
local function JournalBosses(instanceID)
    local bosses = {}
    pcall(EJ_SelectInstance, instanceID)
    for index = 1, 40 do
        local name = Safe(EJ_GetEncounterInfoByIndex, index, instanceID)
        if not PlainString(name) then
            name = Safe(EJ_GetEncounterInfoByIndex, index)
        end
        name = CleanText(name, T.MAX_NAME)
        if name == "" then
            break
        end
        bosses[#bosses + 1] = name
    end
    return bosses
end

local function ReadJournal()
    local wanted, any = {}, false
    for _, dungeon in ipairs(DW.DUNGEONS or {}) do
        local entry = CATALOGUE[dungeon.id]
        if not (entry and entry.bosses) and not journal[dungeon.id] then
            wanted[Norm(dungeon.name)] = dungeon
            any = true
        end
    end
    local now = GetTime()
    if not any or (journalAskedAt and now - journalAskedAt < JOURNAL_RETRY) then
        return
    end
    if type(EJ_GetInstanceByIndex) ~= "function" or type(EJ_SelectInstance) ~= "function" or type(EJ_GetEncounterInfoByIndex) ~= "function" then
        journalAskedAt = now
        return
    end
    -- Do not turn the pages of a journal the player is reading.
    if type(EncounterJournal) == "table" and PlainTrue(Safe(EncounterJournal.IsShown, EncounterJournal)) then
        return
    end
    journalAskedAt = now

    local before = PlainNumber(Safe(EJ_GetCurrentTier))
    local tiers = { false } -- false: the tier that is selected already
    local count = type(EJ_SelectTier) == "function" and PlainNumber(Safe(EJ_GetNumTiers))
    if count and count > 0 then
        tiers = {}
        for tier = 1, min(count, 30) do
            tiers[tier] = tier
        end
    end
    for _, tier in ipairs(tiers) do
        if tier then
            pcall(EJ_SelectTier, tier)
        end
        for _, raids in ipairs({ true, false }) do
            for index = 1, 200 do
                local instanceID, name = Safe(EJ_GetInstanceByIndex, index, raids)
                if not PlainNumber(instanceID) then
                    break
                end
                local dungeon = PlainString(name) and wanted[Norm(name)]
                if dungeon and not journal[dungeon.id] and (dungeon.raid == true) == raids then
                    local bosses = JournalBosses(instanceID)
                    if #bosses > 0 then
                        journal[dungeon.id] = bosses
                    end
                end
            end
        end
    end
    if before and type(EJ_SelectTier) == "function" then
        pcall(EJ_SelectTier, before)
    end
end

-- The dungeons and raids a plan can be for, in DW.DUNGEONS' order:
-- { { id, name, raid, bosses = { "name", ... } }, ... }. bosses is empty when
-- none are known (a raid the journal does not have).
function T.Instances()
    pcall(ReadJournal)
    local list = {}
    for _, dungeon in ipairs(DW.DUNGEONS or {}) do
        local entry = CATALOGUE[dungeon.id]
        local bosses
        if entry and entry.bosses then
            bosses = Split(entry.bosses, ";")
        else
            bosses = Copy(journal[dungeon.id] or {})
        end
        list[#list + 1] = { id = dungeon.id, name = dungeon.name, raid = dungeon.raid == true, bosses = bosses }
    end
    return list
end

local artCache = {} -- [uiMapID] = what T.MapArt gives, or false when the client has no art for it
local mapCache = {} -- [dungeon id] = what T.InstanceMaps gives
local mapsByName    -- [Norm(name)] = { uiMapID, ... }, from one walk through the client's maps

-- The pieces the game's map of a dungeon floor is made of:
-- { width, height, tileW, tileH, cols, rows, textures = { ... } }, the tiles
-- row by row from the top left (cols * rows of them, each tileW x tileH; the
-- last column and row may reach past width and height). nil when this client
-- has no art for the map. Do not change the table: it is shared.
function T.MapArt(uiMapID)
    uiMapID = Whole(uiMapID, 1, 999999)
    if not uiMapID then
        return nil
    end
    local art = artCache[uiMapID]
    if art == nil then
        art = false
        if type(C_Map) == "table" and type(C_Map.GetMapArtLayers) == "function" and type(C_Map.GetMapArtLayerTextures) == "function" then
            local layers = Safe(C_Map.GetMapArtLayers, uiMapID)
            local layer = not DW.IsSecret(layers) and type(layers) == "table" and layers[1]
            local textures = Safe(C_Map.GetMapArtLayerTextures, uiMapID, 1)
            if not DW.IsSecret(layer) and type(layer) == "table" and not DW.IsSecret(textures) and type(textures) == "table" then
                local width, height = PlainNumber(layer.layerWidth), PlainNumber(layer.layerHeight)
                local tileW, tileH = PlainNumber(layer.tileWidth), PlainNumber(layer.tileHeight)
                if width and height and tileW and tileH and width > 0 and height > 0 and tileW > 0 and tileH > 0 then
                    local cols, rows = ceil(width / tileW), ceil(height / tileH)
                    local list = {}
                    if cols * rows <= 400 then
                        for index = 1, cols * rows do
                            local texture = textures[index]
                            if DW.IsSecret(texture) or (type(texture) ~= "number" and type(texture) ~= "string") then
                                break
                            end
                            list[index] = texture
                        end
                    end
                    if #list > 0 and #list == cols * rows then
                        art = { width = width, height = height, tileW = tileW, tileH = tileH, cols = cols, rows = rows, textures = list }
                    end
                end
            end
        end
        artCache[uiMapID] = art
    end
    return art or nil
end

local function MapInfo(uiMapID)
    if type(C_Map) ~= "table" then
        return nil
    end
    local info = Safe(C_Map.GetMapInfo, uiMapID)
    if not DW.IsSecret(info) and type(info) == "table" then
        return info
    end
    return nil
end

local function MapsByName()
    if not mapsByName then
        mapsByName = {}
        for uiMapID = 1, MAP_SCAN_TO do
            local info = MapInfo(uiMapID)
            local name = info and PlainString(info.name)
            if name and name ~= "" then
                local key = Norm(name)
                mapsByName[key] = mapsByName[key] or {}
                table.insert(mapsByName[key], uiMapID)
            end
        end
    end
    return mapsByName
end

-- The game's maps of a dungeon's floors that this client has art for:
-- { { map = uiMapID, name = "..." }, ... }, empty when there are none. The
-- first call for a dungeon without known maps walks through all the client's
-- maps (slow, once per session), so call it when the leader picks a map, not
-- when a window opens.
function T.InstanceMaps(instID)
    instID = Whole(instID, 0, 9999)
    if not instID then
        return {}
    end
    local found = mapCache[instID]
    if not found then
        found = {}
        local dungeon = DW.DUNGEON_BY_ID and DW.DUNGEON_BY_ID[instID]
        if dungeon then
            local ids, taken = {}, {}
            local entry = CATALOGUE[instID]
            for _, uiMapID in ipairs(entry and entry.maps or {}) do
                -- On another build the id may be some other map: a dungeon
                -- floor it must be.
                local info = MapInfo(uiMapID)
                local kind = info and PlainNumber(info.mapType)
                if (kind == nil or kind == MAP_DUNGEON) and T.MapArt(uiMapID) then
                    ids[#ids + 1] = uiMapID
                end
            end
            if #ids == 0 then
                -- By name: the whole name, the part after ":" (a wing), the part before it.
                local name = dungeon.name
                for _, wanted in ipairs({ name, (name:gsub("^.-:%s*", "")), (name:gsub("%s*:.*$", "")) }) do
                    for _, uiMapID in ipairs(MapsByName()[Norm(wanted)] or {}) do
                        if not taken[uiMapID] and T.MapArt(uiMapID) then
                            taken[uiMapID] = true
                            ids[#ids + 1] = uiMapID
                        end
                    end
                    if #ids > 0 then
                        break
                    end
                end
            end
            -- Floors often share the dungeon's name: number the later ones.
            local seen = {}
            for _, uiMapID in ipairs(ids) do
                local info = MapInfo(uiMapID)
                local name = CleanText(info and info.name, 60)
                if name == "" then
                    name = dungeon.name
                end
                seen[name] = (seen[name] or 0) + 1
                if seen[name] > 1 then
                    name = name .. " (" .. seen[name] .. ")"
                end
                found[#found + 1] = { map = uiMapID, name = name }
            end
        end
        mapCache[instID] = found
    end
    return Copy(found)
end

-- The group ---------------------------------------------------------------------------

local ROLES = { TANK = true, HEALER = true, DAMAGER = true }

-- The role the game has for a group member: "TANK", "HEALER", "DAMAGER", or
-- nil when it has none.
local function RoleOf(unit, fromRoster)
    fromRoster = PlainString(fromRoster)
    if fromRoster and ROLES[fromRoster] then
        return fromRoster
    end
    local role = PlainString(Safe(UnitGroupRolesAssigned, unit))
    return role and ROLES[role] and role or nil
end

local function ClassOf(unit)
    local _, class = Safe(UnitClass, unit)
    return PlainString(class) or ""
end

-- Offline only when the game plainly says so.
local function IsOnline(value)
    if DW.IsSecret(value) or value == nil then
        return true
    end
    return value == true or value == 1
end

local function Me()
    return { name = MyName() or "?", class = ClassOf("player"), role = RoleOf("player"), online = true, me = true }
end

local myGroup -- the raid group you are in (1 outside a raid, 0 when the raid does not say); nil = not looked up since the group changed

-- Who is in the group:
--   { inGroup, inRaid, size, myGroup, groups = { [1..8] = { member, ... } } }
--   myGroup is 0 when you are in a raid and the game does not say which group
--   is yours (you are then listed in group 1, but no group counts as yours).
--   member = { name, class ("MAGE", "" when unknown), role ("TANK", "HEALER",
--              "DAMAGER" or nil), online, me }
-- In a raid the members are in their raid groups. In a party everyone is in
-- group 1, and alone you are there yourself (inGroup = false).
function T.Roster()
    local roster = { inGroup = false, inRaid = false, size = 1, myGroup = 1, groups = {} }
    for group = 1, 8 do
        roster.groups[group] = {}
    end
    if not InGroup() then
        roster.groups[1][1] = Me()
        return roster
    end
    roster.inGroup = true

    if InRaid() then
        roster.inRaid = true
        local mine = MyName()
        local size, sawMe = 0, false
        for index = 1, min(40, PlainNumber(Safe(GetNumGroupMembers)) or 0) do
            local name, _, group, _, _, class, _, online, _, _, _, role = Safe(GetRaidRosterInfo, index)
            name, group = ShownName(name), PlainNumber(group)
            if name and group and roster.groups[group] then
                local unit = "raid" .. index
                local same = Safe(UnitIsUnit, unit, "player")
                local me = PlainTrue(same)
                if not me and (DW.IsSecret(same) or same == nil) and not sawMe and mine then
                    me = DW.SameCharacter(name, mine) -- the game would not say: go by the name
                end
                if me then
                    sawMe = true
                    roster.myGroup = group
                end
                size = size + 1
                table.insert(roster.groups[group], {
                    name = name, class = PlainString(class) or "", role = RoleOf(unit, role),
                    online = me or IsOnline(online), me = me,
                })
            end
        end
        if not sawMe then
            size = size + 1
            table.insert(roster.groups[1], Me())
            roster.myGroup = 0
        end
        roster.size = size
    else
        local members = roster.groups[1]
        members[1] = Me()
        for _, unit in ipairs(DW.GroupUnits()) do
            local name = ShownName(Safe(UnitName, unit))
            if name then
                members[#members + 1] = {
                    name = name, class = ClassOf(unit), role = RoleOf(unit),
                    online = IsOnline(Safe(UnitIsConnected, unit)), me = false,
                }
            end
        end
        roster.size = #members
    end
    myGroup = roster.myGroup
    return roster
end

-- May you show a slideshow to the group now? In a raid the leader and the
-- assistants, in a party the leader. Otherwise false and why:
-- TAC_ERR_NO_ACCESS, TAC_ERR_NO_GROUP or TAC_ERR_NOT_LEADER.
function T.CanPresent()
    if not DW.HasAccess() then
        return false, "TAC_ERR_NO_ACCESS"
    end
    if not InGroup() then
        return false, "TAC_ERR_NO_GROUP"
    end
    if MayPresent("player") then
        return true
    end
    return false, "TAC_ERR_NOT_LEADER"
end

-- Is this item about you? A player item with your name, or a groups item
-- with the raid group you are in (group 1 outside a raid).
local function IsMine(item)
    if item.k == "p" then
        local key, name, realm = DW.CharacterKey()
        local shown = ShownName(name, realm)
        return (shown ~= nil and DW.SameCharacter(item.n, shown)) or (key ~= nil and DW.SameCharacter(item.n, key))
    elseif item.k == "g" and IsTable(item.g) then
        local mine = myGroup or T.Roster().myGroup
        for _, group in ipairs(item.g) do
            if group == mine then
                return true
            end
        end
    end
    return false
end

function T.IsMine(item)
    if not IsTable(item) then
        return false
    end
    local ok, mine = pcall(IsMine, item)
    return ok and mine == true
end

-- The slideshow -------------------------------------------------------------------------
--
-- Messages to the group (name DragonworldTac, fields separated by tab):
--   S sid protocol scenes current header
--                      a slideshow starts. sid: a short id for it; protocol:
--                      T.PROTOCOL (a higher one than we know is ignored);
--                      scenes: how many; current: the one being shown; header:
--                      T.EncodeHeader.
--   C sid scene part parts data
--                      one piece of one packed scene (T.EncodeScene). The
--                      scenes go out in order, so scene 1 can be shown before
--                      the rest has arrived.
--   G sid scene        the one who shows moved to this scene
--   P sid x y          ...points at this spot on the board
--   E sid              the slideshow ended
--   A sid scenes       from someone watching: all the scenes have arrived (sent once)
--   Q                  "is a slideshow running?", sent a few seconds after you
--                      join a group or log in inside one. The one who shows
--                      sends everything again, at most once per RESEND_GAP.
-- S, C, G, P and E count only from a group member who may show one by OUR
-- roster: the leader, or an assistant in a raid. A and Q count from anyone in
-- the group. Everything else is ignored without a word.
-- There is one slideshow at a time: a new S replaces the one you watch, and
-- stops your own.
--
-- The game may refuse addon messages for a while (Comm.lua, "Messages to the
-- group"). T.Presenting() tells: locked while it is being tried again, and
-- problem = "TAC_ERR_BLOCKED" when it was given up.

local RESEND_GAP = 15    -- seconds between two times everything is sent
local PING_GAP = 0.5     -- seconds between two pings
local ASK_DELAY = 4      -- seconds after joining before Q, so the others have us in their roster
local CHECK_DELAY = 1.5  -- the roster is looked at again this long after a change that would end a slideshow
local TIE_WINDOW = 5     -- two slideshows started within this many seconds are one race: the lower id wins
local TIE_RESEND = 1.5   -- seconds before the winner of that race sends its slideshow again
local REPAIR_WAIT = 8    -- seconds without a new piece before someone watching asks for the slideshow again
local ASK_ANSWERS = 4    -- questions (Q) from one group member that are answered per slideshow
local END_ROUNDS = 5     -- times the "it ended" message is queued again after the game dropped it
local BYTES_SLACK = 1000 -- a slideshow from someone else may be this much over T.MAX_BYTES before it is dropped

local Group = DW.CreateGroupSender(PREFIX)

local present        -- the slideshow we show (see T.Present)
local watch          -- the slideshow we watch (see OnStart)
local dismissed      -- the sid of a slideshow the player closed: sending it again must not reopen it
local owedEnd        -- { sid, rounds }: the "it ended" (E) of our last slideshow, until the group has it
local filling = false -- true while a whole plan is being queued
local lastPing
local asked, askPlanned = false, false
local checkPlanned = false

-- A packed scene in pieces that fit a message, never cut inside a letter.
local function Chunks(text)
    local pieces, from, length = {}, 1, #text
    while from <= length do
        local to = min(length, from + CHUNK_BYTES - 1)
        while to < length and to > from do
            local following = text:byte(to + 1)
            if following < 0x80 or following > 0xBF then
                break
            end
            to = to - 1
        end
        pieces[#pieces + 1] = text:sub(from, to)
        from = to + 1
    end
    if #pieces == 0 then
        pieces[1] = ""
    end
    return pieces
end

-- Queues the whole slideshow: S, then every piece of every scene.
local function SendAll()
    filling = true
    present.failed = false
    present.sentAt = GetTime()
    present.total = 1 + #present.chunks
    Group(table.concat({ "S", present.sid, T.PROTOCOL, #present.plan.scenes, present.scene, present.header }, SEP))
    for _, message in ipairs(present.chunks) do
        Group(message)
    end
    filling = false
    present.sent = present.total - Group.Waiting("^[SC]\t")
    present.locked = Group.Locked() and Group.Waiting() > 0
end

-- Stops showing without telling the group (they have been told, or cannot be).
local function DropPresenting()
    if present then
        present = nil
        Group.Clear()
        Emit("present")
    end
end

local function EndWatching()
    if watch then
        watch = nil
        Emit("watch")
    end
end

-- Everything again, for someone who asked (Q): not more often than every
-- RESEND_GAP, and not while the last round is still going out.
local function Resend()
    if not present then
        return
    end
    local wait = RESEND_GAP - (GetTime() - present.sentAt)
    if wait <= 0 and Group.Waiting("^[SC]\t") == 0 then
        SendAll()
        Emit("present")
        return
    end
    if present.resendPlanned then
        return
    end
    present.resendPlanned = true
    local sid = present.sid
    C_Timer.After(max(wait, 1.5), function()
        if present and present.sid == sid then
            present.resendPlanned = false
            Resend()
        end
    end)
end

-- Two pressed "Show to group" at the same moment, and we won (OnStart). The
-- group has just been told about the other slideshow, so ours goes out again.
local function PlanTieResend()
    if present.tiePlanned then
        return
    end
    present.tiePlanned = true
    local sid = present.sid
    C_Timer.After(TIE_RESEND, function()
        if present and present.sid == sid then
            present.tiePlanned = false
            Group.Clear("^[SCG]\t")
            SendAll()
            Emit("present")
        end
    end)
end

-- The sender tells us when messages went out or the game refused them.
Group.OnChange(function(what)
    if not present then
        -- The message that ends our slideshow must get through, or the group
        -- keeps "X is showing ..." on the screen. A boss fight can lock the
        -- messages for longer than the sender waits: queue it again then.
        if owedEnd then
            if what == "gaveup" and owedEnd.rounds < END_ROUNDS and InGroup() then
                owedEnd.rounds = owedEnd.rounds + 1
                Group("E" .. SEP .. owedEnd.sid)
            elseif what ~= "locked" and Group.Waiting("^E\t") == 0 then
                owedEnd = nil -- it went out, or there is nobody left to tell
            end
        end
        return
    end
    if filling then
        return
    end
    local sent, failed = present.sent, present.failed
    if what == "gaveup" then
        -- What waited is gone. sent stays at what did go out.
        present.failed = true
    elseif what == "sent" then
        if present.failed then
            -- The game takes messages again: send what was dropped.
            Resend()
            return
        end
        present.sent = present.total - Group.Waiting("^[SC]\t")
    end
    -- Tell the windows only when what T.Presenting() says has changed (a
    -- scene change or a ping going out changes nothing).
    local locked = Group.Locked() and Group.Waiting() > 0
    if present.sent ~= sent or present.failed ~= failed or present.locked ~= locked then
        present.locked = locked
        Emit("present")
    end
end)

-- Shows a plan to the group as a slideshow, starting at its first scene.
-- Returns true, or false and why: what T.CanPresent says, TAC_ERR_BAD_PLAN,
-- TAC_ERR_NO_NAME (the group keeps a copy, and a plan cannot be saved without
-- a name) or TAC_ERR_TOO_BIG (more than T.MAX_BYTES packed).
function T.Present(plan)
    local can, reason = T.CanPresent()
    if not can then
        return false, reason
    end
    local clean = T.Sanitize(plan)
    if not clean then
        return false, "TAC_ERR_BAD_PLAN"
    end
    if clean.name == "" then
        return false, "TAC_ERR_NO_NAME"
    end
    local header, scenes, bytes = PackPlan(clean)
    if bytes > T.MAX_BYTES then
        return false, "TAC_ERR_TOO_BIG"
    end

    -- One slideshow at a time: ours replaces the one we watched, and for the
    -- others the new S replaces our old one.
    EndWatching()
    Group.Clear()
    owedEnd = nil -- the new slideshow replaces the old one for everybody
    local sid = NewSid()
    local chunks = {}
    for index, text in ipairs(scenes) do
        local pieces = Chunks(text)
        for part, data in ipairs(pieces) do
            chunks[#chunks + 1] = table.concat({ "C", sid, index, part, #pieces, data }, SEP)
        end
    end
    present = {
        sid = sid, plan = clean, scene = 1, header = header, chunks = chunks,
        total = 0, sent = 0, sentAt = 0, failed = false, locked = false, resendPlanned = false,
        viewers = {}, viewerCount = 0,
        startedAt = GetTime(), answered = {}, tiePlanned = false,
    }
    SendAll()
    Emit("present")
    Emit("scene", 1)
    return true
end

-- Moves the slideshow you show to scene n. True if you are showing one and
-- it has that scene.
function T.ShowScene(n)
    if not present or not PlainNumber(n) or n ~= floor(n) or n < 1 or n > #present.plan.scenes then
        return false
    end
    if n ~= present.scene then
        present.scene = n
        -- Only the newest counts. It goes ahead of the pieces still waiting,
        -- but not ahead of the S that starts the slideshow.
        Group.Clear("^G\t")
        Group(table.concat({ "G", present.sid, n }, SEP), Group.Waiting("^S\t") == 0)
        Emit("scene", n)
        Emit("present")
    end
    return true
end

-- Points at a spot on the board (board units) for everyone watching. At most
-- one per PING_GAP; false when it was not sent.
function T.Ping(x, y)
    x, y = Whole(x, 0, T.BOARD_W), Whole(y, 0, T.BOARD_H)
    if not present or not x or not y then
        return false
    end
    local now = GetTime()
    if lastPing and now - lastPing < PING_GAP then
        return false
    end
    lastPing = now
    Group.Clear("^P\t") -- a ping that still waits is old news
    -- While the slideshow itself is still going out, a ping is shown to you
    -- only: ahead of the pieces it would hold them back (pointing once a
    -- second would stop them altogether), and after them it would be old.
    if Group.Waiting("^[SC]\t") == 0 then
        Group(table.concat({ "P", present.sid, x, y }, SEP), true)
    end
    Emit("ping", x, y)
    return true
end

-- Ends the slideshow you show, and tells the group.
function T.StopPresenting()
    if not present then
        return false
    end
    local sid = present.sid
    present = nil
    Group.Clear()
    if InGroup() then
        owedEnd = { sid = sid, rounds = 0 }
        Group("E" .. SEP .. sid)
    end
    Emit("present")
    return true
end

-- The slideshow you show, or nil:
--   plan         the plan (do not change it)
--   scene        the scene being shown
--   sent, total  how many of its messages have gone out
--   locked       true while the game refuses addon messages and we keep trying
--   problem      nil, "TAC_ERR_LOCKED" (refused; trying again every few
--                seconds) or "TAC_ERR_BLOCKED" (refused for two minutes: the
--                rest was not sent, and the group may be missing scenes)
--   viewers      { [name] = true } for those who have received all of it
--   viewerCount  how many they are
function T.Presenting()
    if not present then
        return nil
    end
    local locked = Group.Locked() and Group.Waiting() > 0
    return {
        plan = present.plan, scene = present.scene,
        sent = present.sent, total = present.total,
        locked = locked,
        problem = (present.failed and "TAC_ERR_BLOCKED") or (locked and "TAC_ERR_LOCKED") or nil,
        viewers = present.viewers, viewerCount = present.viewerCount,
    }
end

-- The slideshow you watch, or nil:
--   plan         the plan (do not change it). plan.scenes[n] is nil until
--                that scene has arrived.
--   scene        the scene the one who shows is on
--   from         who shows it
--   ready, total how many scenes have arrived, of how many
function T.Watching()
    if not watch then
        return nil
    end
    return { plan = watch.plan, scene = watch.scene, from = watch.from, ready = watch.ready, total = watch.total }
end

-- Closes the slideshow you watch, for you only.
function T.StopWatching()
    if not watch then
        return false
    end
    dismissed = watch.sid
    EndWatching()
    return true
end

local function SameSender(sender)
    return watch ~= nil and (sender == watch.sender or DW.SameCharacter(sender, watch.sender))
end

-- A piece can get lost (a loading screen, the game holding messages back).
-- Someone whose slideshow has stood still, incomplete, for REPAIR_WAIT asks
-- for it again, once.
local function PlanRepair(sid)
    C_Timer.After(REPAIR_WAIT, function()
        if not watch or watch.sid ~= sid or watch.ready >= watch.total or watch.repaired then
            return
        end
        if GetTime() - watch.lastPiece >= REPAIR_WAIT - 0.5 then
            watch.repaired = true
            Group("Q")
        else
            PlanRepair(sid)
        end
    end)
end

-- S: a slideshow starts (or is sent again).
local function OnStart(fields, sender, name)
    local sid = CleanId(fields[2])
    local protocol = Digits(fields[3], 1, 999999)
    local count = Digits(fields[4], 1, T.MAX_SCENES)
    local current = count and Digits(fields[5], 1, count)
    if not sid or not protocol or protocol > T.PROTOCOL or not current then
        return
    end
    local header = T.DecodeHeader(table.concat(fields, SEP, 6))
    if not header or header.count ~= count or sid == dismissed then
        return
    end
    if watch and watch.sid == sid then
        -- Sent again for someone who asked: we have it, but follow the scene.
        if SameSender(sender) and watch.scene ~= current then
            watch.scene = current
            Emit("scene", current)
        end
        return
    end

    if present and present.sid < sid and GetTime() - present.startedAt < TIE_WINDOW then
        -- Two pressed "Show to group" at the same moment. The lower id wins on
        -- both sides (the other one stops when our slideshow reaches them).
        PlanTieResend()
        return
    end

    DropPresenting()
    header.count = nil
    header.scenes = {}
    watch = {
        sid = sid, sender = sender, from = name, plan = header,
        total = count, ready = 0, scene = current, parts = {}, acked = false,
        bytes = 0, lastPiece = GetTime(), repaired = false,
    }
    Emit("watch")
    Emit("scene", current)
    PlanRepair(sid)
end

-- C: one piece of one scene.
local function OnChunk(fields)
    local index = Digits(fields[3], 1, watch.total)
    local part, parts = Digits(fields[4], 1, MAX_PARTS), Digits(fields[5], 1, MAX_PARTS)
    if not index or not part or not parts or part > parts or watch.plan.scenes[index] then
        return
    end
    local got = watch.parts[index]
    if not got or got.parts ~= parts then
        got = { parts = parts, have = 0, data = {} }
        watch.parts[index] = got
    end
    local data = table.concat(fields, SEP, 6)
    if got.data[part] == nil then
        got.have = got.have + 1
        -- The addon never sends more than T.MAX_BYTES; someone sending by hand
        -- must not fill our memory and saved data.
        watch.bytes = watch.bytes + #data
        if watch.bytes > T.MAX_BYTES + BYTES_SLACK then
            dismissed = watch.sid
            EndWatching()
            return
        end
    end
    got.data[part] = data
    watch.lastPiece = GetTime()
    if got.have < parts then
        return
    end

    watch.parts[index] = nil
    -- A scene that cannot be read still counts, as an empty one, so the
    -- slideshow gets complete.
    watch.plan.scenes[index] = T.DecodeScene(table.concat(got.data)) or EmptyScene()
    watch.ready = watch.ready + 1
    if watch.ready == watch.total and not watch.acked then
        watch.acked = true
        Group(table.concat({ "A", watch.sid, watch.ready }, SEP))
        AddReceived(watch.plan, watch.from)
    end
    Emit("watch")
end

DW.OnGroupMessage(PREFIX, function(text, sender)
    local fields = Split(text, SEP)
    local kind = fields[1]
    -- Only from someone who is in the group by our own roster.
    local unit, name = UnitOf(sender)
    if not unit then
        return
    end

    if kind == "Q" then
        if present then
            -- Everything again is some twenty messages to the whole group, so
            -- one member gets it only a few times per slideshow.
            local answered = present.answered[name] or 0
            if answered < ASK_ANSWERS then
                present.answered[name] = answered + 1
                Resend()
            end
        elseif SameSender(sender) then
            -- The one we watch asks: they have lost their slideshow (a reload).
            EndWatching()
        end
    elseif kind == "A" then
        if present and fields[2] == present.sid and not present.viewers[name] then
            present.viewers[name] = true
            present.viewerCount = present.viewerCount + 1
            Emit("present")
        end
    elseif kind == "S" then
        if MayPresent(unit) then
            OnStart(fields, sender, name)
        end
    elseif kind == "C" or kind == "G" or kind == "P" or kind == "E" then
        if not watch or fields[2] ~= watch.sid or not SameSender(sender) or not MayPresent(unit) then
            return
        end
        if kind == "C" then
            OnChunk(fields)
        elseif kind == "G" then
            local scene = Digits(fields[3], 1, watch.total)
            if scene and scene ~= watch.scene then
                watch.scene = scene
                Emit("scene", scene)
            end
        elseif kind == "P" then
            local x, y = Digits(fields[3], 0, T.BOARD_W), Digits(fields[4], 0, T.BOARD_H)
            if x and y then
                Emit("ping", x, y)
            end
        else
            EndWatching()
        end
    end
end)

-- Asks the group once whether a slideshow is running.
local function Ask()
    askPlanned = false
    if asked or not InGroup() or not DW.HasAccess() then
        return
    end
    asked = true
    -- (No need to ask when a slideshow has reached us meanwhile, or we show one.)
    if not watch and not present then
        Group("Q")
    end
end

local function PlanAsk()
    if asked or askPlanned or not InGroup() then
        return
    end
    askPlanned = true
    C_Timer.After(ASK_DELAY, Ask)
end

-- Ends a slideshow that cannot go on: we may no longer show ours, or the one
-- we watch is shown by someone who left or may no longer show it. Only on a
-- plain answer from the game: in a fight it can hide names and ranks, and
-- that must not close anything.
local function CheckSlideshows()
    checkPlanned = false
    if YesNo(Safe(IsInGroup)) ~= true then
        return -- alone is handled at once in OnGroupChanged
    end
    if present and MayPresent("player") == false then
        T.StopPresenting()
    end
    if present and present.viewerCount > 0 then
        -- Those who have left no longer count as having received it.
        local here, all = {}, true
        for _, unit in ipairs(GroupUnitList()) do
            local name = ShownName(Safe(UnitName, unit))
            if name then
                here[name] = true
            else
                all = false -- the game hides a name: it may be any of them
            end
        end
        local gone = false
        for name in pairs(all and present.viewers or {}) do
            if not here[name] then
                present.viewers[name] = nil
                present.viewerCount = present.viewerCount - 1
                gone = true
            end
        end
        if gone then
            Emit("present")
        end
    end
    if watch then
        local unit, _, unsure = UnitOf(watch.sender)
        if (not unit and not unsure) or (unit and MayPresent(unit) == false) then
            EndWatching()
        end
    end
end

local function OnGroupChanged()
    myGroup = nil
    local inGroup = YesNo(Safe(IsInGroup))
    if inGroup == false then
        asked = false
        DropPresenting()
        EndWatching()
    elseif inGroup == true then
        PlanAsk()
        -- The game reports a change in several steps, and a member can be
        -- missing for a moment in between. So look again shortly before
        -- ending anything.
        if (present or watch) and not checkPlanned then
            checkPlanned = true
            C_Timer.After(CHECK_DELAY, CheckSlideshows)
        end
    end
    Emit("roster")
end

local frame = CreateFrame("Frame")
frame:SetScript("OnEvent", OnGroupChanged)
for _, event in ipairs({ "GROUP_ROSTER_UPDATE", "PARTY_LEADER_CHANGED", "PLAYER_ROLES_ASSIGNED", "PLAYER_ENTERING_WORLD" }) do
    pcall(frame.RegisterEvent, frame, event)
end

-- The slideshow is for those who may use the personal tabs. The guild name
-- can arrive a while after login.
DW.OnAccessChanged(function(access)
    if access then
        PlanAsk()
    else
        DropPresenting()
        EndWatching()
    end
end)

-- Module --------------------------------------------------------------------------------

-- No CreatePanel here: Tactics.lua adds the tab.
T.module = DW.RegisterModule({
    id = MODULE_ID,
    titleKey = "TAC_TITLE",
    notesKey = "TAC_NOTES",
    icon = "Interface\\Icons\\INV_Misc_Map_01",
    personal = true, -- the messages go to the group, not the guild

    OnLoad = function(self, db)
        saved = db
        savedChecked = false
    end,
})

-- Debugging.
DW.AddDebug(MODULE_ID, function(add)
    local text = DW.DebugText
    local can, reason = T.CanPresent()
    add(("gruppe: %s | raid: %s | størrelse: %s | leder: %s | assistent: %s | kan vise: %s%s"):format(
        text(InGroup()), text(InRaid()), text(Safe(GetNumGroupMembers)), text(Safe(UnitIsGroupLeader, "player")),
        text(Safe(UnitIsGroupAssistant, "player")), text(can), reason and (" (" .. reason .. ")") or ""))
    add(("meldinger: venter %d | spillet sperrer nå: %s | sperret ved siste forsøk: %s | siste svar fra spillet: %s"):format(
        Group.Waiting(), text(C_ChatInfo and Safe(C_ChatInfo.InChatMessagingLockdown)), text(Group.Locked()), text(Group.LastResult())))
    local plans, received = 0, 0
    if type(saved) == "table" then
        for _ in pairs(type(saved.plans) == "table" and saved.plans or {}) do
            plans = plans + 1
        end
        received = type(saved.received) == "table" and #saved.received or 0
    end
    add(("viser: %s | ser på: %s | spurt: %s | lagret: %d | mottatt: %d"):format(
        present and (present.sid .. " " .. present.sent .. "/" .. present.total .. (present.failed and " (gitt opp)" or "")) or "-",
        watch and (watch.sid .. " " .. watch.ready .. "/" .. watch.total .. " fra " .. watch.from) or "-",
        text(asked), plans, received))
end)
