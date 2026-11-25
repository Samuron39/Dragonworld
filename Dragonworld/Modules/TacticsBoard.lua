-- Dragonworld - Tactics: the board
--
-- Draws one scene of a plan (the room, the markers, arrows, lines, areas and
-- texts) and lets the leader edit it. The plan as data is described at the top
-- of TacticsCore.lua.
--
-- In this file:
--   T.ICONS, T.ROOMS         what the editor's palette offers
--   T.IconArt, T.PaintIcon   the picture of an icon
--   T.Geo                    the arithmetic: no frames, so it can be tested alone
--   T.CreateBoard            the board
--
-- The board's own art is in Media\Tactics and is made by
-- tools\make_tactics_art.js. It is white where the board colours it.
--
-- How the board is built: the board frame clips its children. On it lie, from
-- the bottom up, one frame for the room or map, one frame per item (so a later
-- item always covers an earlier one, whatever it is made of), one for the
-- outline of what is about to be placed, one for the selection and one for
-- pings. Together they use the frame levels from the board's own level up to
-- board.levels above it; a host that lays something over the board must go
-- higher than that.

local ADDON_NAME, DW = ...
local L = DW.L
local T = DW.Tactics

local floor, ceil, sqrt, abs, min, max = math.floor, math.ceil, math.sqrt, math.abs, math.min, math.max
local sin, cos, pi = math.sin, math.cos, math.pi
local atan2 = math.atan2 or math.atan -- math.atan takes both numbers where atan2 is gone

-- Art --------------------------------------------------------------------------

local MEDIA = "Interface\\AddOns\\" .. ADDON_NAME .. "\\Media\\Tactics\\"
local ART = {
    glyphs = MEDIA .. "glyphs", -- the icons, in cells (see GLYPHS)
    token = MEDIA .. "token",   -- the round base of a marker: its rim takes the marker's colour
    ring = MEDIA .. "ring",     -- the selection ring and the ping
    glow = MEDIA .. "glow",     -- lies under an item that is the player's own
    arrow = MEDIA .. "arrow",   -- an arrowhead pointing right
    dot = MEDIA .. "dot",       -- a small disc: joints of lines, handles, round ends
    disc = MEDIA .. "disc",     -- a large disc: areas, and the mask that makes a floor round
    line = MEDIA .. "line",     -- what thin lines are drawn with: soft across, even along
    band = MEDIA .. "band",     -- the same for thick lines, with a narrower soft edge
    floor = MEDIA .. "floor",   -- stone slabs, repeating
    rock = MEDIA .. "rock",     -- rough rock and bare ground, repeating
}

-- The cells of glyphs.tga, row by row. tools\make_tactics_art.js draws them in
-- this order and stops if its list differs from this one.
local GLYPHS = {
    "boss", "add", "tank", "heal", "dps", "melee", "ranged", "stack",
    "spread", "safe", "danger", "fire", "frost", "poison", "void", "bolt",
    "interrupt", "dispel", "move", "swap", "bomb", "eye", "flag", "plain",
    "person", "group",
}
local GLYPH_COLUMNS, GLYPH_ROWS = 8, 4
local glyphCoords = {}
for index, name in ipairs(GLYPHS) do
    local column, row = (index - 1) % GLYPH_COLUMNS, floor((index - 1) / GLYPH_COLUMNS)
    glyphCoords[name] = { column / GLYPH_COLUMNS, (column + 1) / GLYPH_COLUMNS, row / GLYPH_ROWS, (row + 1) / GLYPH_ROWS }
end

-- Sizes of the art and of what is drawn. Lengths are in pixels on a board
-- 720 wide unless they say board units; the board scales them with its width.
local K = {
    DOT_FILL = 32 / 28,    -- dot.tga is this much larger than the disc in it
    DISC_FILL = 64 / 62,   -- and disc.tga
    TOKEN_FILL = 32 / 31,  -- and token.tga
    ICON_FILL = 0.66,      -- an icon's size on its token
    RING = 1.45,           -- the selection ring's texture against the token it circles
    GLOW = 2.4,            -- the glow's texture against the token it lies under
    HEAD_TIP = 29 / 64,    -- arrow.tga: from the middle to the tip
    HEAD_JOIN = 4 / 64,    -- and to where the shaft ends inside the head
    LINE_SOLID = 0.625,    -- line.tga: the share of its height that is the line itself
    BAND_SOLID = 0.8125,   -- band.tga
    BAND_FROM = 6,         -- lines this thick (pixels) and thicker use band.tga
    OUTLINE = 3,           -- how much wider the dark line under a line is
    MIN_FONT = 6,          -- smaller text is left out (a board used as a thumbnail)
    OVAL_STEP = 9,         -- a circle is drawn from lines about this long
    OVAL_MIN = 16,
    OVAL_MAX = 96,
    AREA_ALPHA = 0.22,
    FLOOR_UNIT = 250,      -- board units per repeat of floor.tga
    ROCK_UNIT = 180,       -- and of rock.tga
    WALL = 8,              -- board units: how wide a wall is
    NAME_H = 16,           -- board units: the name under a player
    LABEL_H = { 15, 17, 20 }, -- board units: the label under a marker, by size
    UNDO = 20,
    SLOP = 3,              -- board units the mouse may move in a click that is not a drag
    CLICK = 6,
    SAMPLE = 4,            -- board units between the points taken while a line is drawn
    RAW_MAX = 600,
    PING_TIME = 0.9,       -- seconds one ring of a ping lives
    PING_GAP = 0.22,       -- seconds between its three rings
    PING_FROM = 12,        -- board units: the ring's radius at the start
    PING_TO = 80,
    GHOST_ALPHA = 0.55,
}

local GOLD = { 1.00, 0.82, 0.00 }          -- selection, handles, "mine"
local WALL_COLOUR = { 0.86, 0.69, 0.27 }   -- the old gold of a wall's edge
local FLOOR_TINT = { 0.70, 0.66, 0.58 }
local SURROUND_TINT = { 0.20, 0.19, 0.23 } -- the dark rock around a room
local PIT_TINT = { 0.09, 0.09, 0.11 }
local BASE_COLOUR = { 0.05, 0.05, 0.06 }   -- under everything, should a texture be missing

-- Is this file of the game's there? GetFileIDFromPath answers for the game's
-- own files (not for an addon's), and may be missing: then the file is trusted.
local fileKnown = {}
local function GameFileExists(path)
    local known = fileKnown[path]
    if known == nil then
        known = true
        if type(GetFileIDFromPath) == "function" then
            local ok, id = pcall(GetFileIDFromPath, path)
            if ok and (id == nil or id == 0) then
                known = false
            end
        end
        fileKnown[path] = known
    end
    return known
end

-- Icons -------------------------------------------------------------------------

-- What a marker can show. Each entry:
--   id      what an item stores in i
--   group   where the palette puts it: "enemy", "role", "mark" or "spot"
--   tex, coords, tint, scale   the picture (see T.PaintIcon)
--   c       the colour (an index into T.COLORS) that suits it, for the palette
--           to start with
-- The names come from L["TAC_ICON_" .. id:upper()], which the editor adds.

local function GlyphIcon(id, group, colour, r, g, b)
    return { id = id, group = group, tex = ART.glyphs, coords = glyphCoords[id], tint = { r, g, b }, c = colour }
end

-- The game's eight raid target icons, so a marker on the board matches the one
-- over a head in the room. r, g, b colours the plain marker shown if the
-- game's picture is missing.
local function MarkIcon(number, colour, r, g, b)
    return {
        id = "rt" .. number, group = "mark", c = colour, scale = 1.12,
        tex = "Interface\\TargetingFrame\\UI-RaidTargetingIcon_" .. number, game = true,
        fallback = { tex = ART.glyphs, coords = glyphCoords.plain, tint = { r, g, b }, c = colour },
    }
end

T.ICONS = {
    GlyphIcon("boss", "enemy", 2, 1.00, 0.93, 0.82),
    GlyphIcon("add", "enemy", 3, 1.00, 0.62, 0.50),

    GlyphIcon("tank", "role", 6, 0.50, 0.74, 1.00),
    GlyphIcon("heal", "role", 5, 0.45, 0.95, 0.50),
    GlyphIcon("dps", "role", 2, 1.00, 0.50, 0.45),
    GlyphIcon("melee", "role", 3, 1.00, 0.66, 0.40),
    GlyphIcon("ranged", "role", 4, 1.00, 0.88, 0.45),

    MarkIcon(1, 4, 1.00, 0.92, 0.20), -- star
    MarkIcon(2, 3, 1.00, 0.55, 0.10), -- circle
    MarkIcon(3, 7, 0.80, 0.40, 1.00), -- diamond
    MarkIcon(4, 5, 0.30, 0.90, 0.30), -- triangle
    MarkIcon(5, 1, 0.75, 0.85, 1.00), -- moon
    MarkIcon(6, 6, 0.30, 0.70, 1.00), -- square
    MarkIcon(7, 2, 1.00, 0.30, 0.25), -- cross
    MarkIcon(8, 1, 1.00, 1.00, 1.00), -- skull

    GlyphIcon("stack", "spot", 4, 1.00, 0.90, 0.55),     -- gather here
    GlyphIcon("spread", "spot", 1, 1.00, 1.00, 1.00),    -- spread out
    GlyphIcon("move", "spot", 1, 1.00, 1.00, 1.00),      -- run here
    GlyphIcon("safe", "spot", 5, 0.50, 1.00, 0.50),      -- safe to stand in
    GlyphIcon("danger", "spot", 2, 1.00, 0.45, 0.35),    -- stay out
    GlyphIcon("fire", "spot", 3, 1.00, 0.60, 0.20),
    GlyphIcon("frost", "spot", 6, 0.65, 0.90, 1.00),
    GlyphIcon("poison", "spot", 5, 0.60, 1.00, 0.35),
    GlyphIcon("void", "spot", 7, 0.82, 0.55, 1.00),      -- a void zone, shadow
    GlyphIcon("bolt", "spot", 4, 1.00, 0.95, 0.45),      -- lightning, nature
    GlyphIcon("bomb", "spot", 3, 1.00, 0.72, 0.45),      -- carry it out, drop it here
    GlyphIcon("interrupt", "spot", 2, 1.00, 0.45, 0.40),
    GlyphIcon("dispel", "spot", 6, 0.75, 0.92, 1.00),
    GlyphIcon("swap", "spot", 4, 1.00, 0.90, 0.55),      -- tanks swap, switch target
    GlyphIcon("eye", "spot", 7, 0.90, 0.78, 1.00),       -- look away, watch for this
    GlyphIcon("flag", "spot", 1, 1.00, 1.00, 1.00),      -- any other place worth a name
}

local iconById = {}
for _, icon in ipairs(T.ICONS) do
    iconById[icon.id] = icon
end

-- The marker for an icon id this version does not know.
local PLAIN_ICON = { tex = ART.glyphs, coords = glyphCoords.plain, tint = { 1, 1, 1 }, c = 1 }

-- The picture for an icon id: { tex = path, coords = { left, right, top,
-- bottom } or nil for the whole file, tint = { r, g, b } or nil, scale = how
-- much larger than usual it is drawn, or nil, c = the colour that suits it }.
-- An id that is not known gives a plain marker, and so does one of the game's
-- pictures that this client does not have.
function T.IconArt(id)
    local icon = iconById[id]
    if not icon then
        return PLAIN_ICON
    end
    if icon.game and not GameFileExists(icon.tex) then
        return icon.fallback
    end
    return icon
end

-- Puts an icon's picture on a texture. id is an icon id, or a picture as
-- T.IconArt gives it. Returns the picture. The palette uses this too.
function T.PaintIcon(texture, id)
    local art = type(id) == "table" and id or T.IconArt(id)
    texture:SetTexture(art.tex)
    local coords = art.coords
    if coords then
        texture:SetTexCoord(coords[1], coords[2], coords[3], coords[4])
    else
        texture:SetTexCoord(0, 1, 0, 1)
    end
    local tint = art.tint
    if tint then
        texture:SetVertexColor(tint[1], tint[2], tint[3])
    else
        texture:SetVertexColor(1, 1, 1)
    end
    return art
end

-- A class's own colour, or light grey for a class that is not known.
local function ClassColour(class)
    local colour = class and RAID_CLASS_COLORS and RAID_CLASS_COLORS[class]
    if colour and colour.r then
        return colour.r, colour.g, colour.b
    end
    return 0.85, 0.85, 0.85
end

-- The picture on a player's token: the game's round class icon, or a figure
-- in the class colour when the class or the game's picture is not there.
local CLASS_CIRCLES = "Interface\\TargetingFrame\\UI-Classes-Circles"
local classArt = {}
local function ClassArt(class)
    local key = class or ""
    local art = classArt[key]
    if not art then
        local coords = class and CLASS_ICON_TCOORDS and CLASS_ICON_TCOORDS[class]
        if type(coords) == "table" and coords[4] and GameFileExists(CLASS_CIRCLES) then
            art = { tex = CLASS_CIRCLES, coords = coords, scale = 1.24 }
        else
            art = { tex = ART.glyphs, coords = glyphCoords.person, tint = { ClassColour(class) } }
        end
        classArt[key] = art
    end
    return art
end

-- Rooms -------------------------------------------------------------------------

-- The drawn rooms. Each is a floor made of simple shapes that may overlap, in
-- board units:
--   { "r", left, top, width, height }   a rectangle
--   { "c", x, y, radius }               a circle
--   { "e", x, y, radiusX, radiusY }     an oval
-- A shape's tone (0 to 1) makes its floor darker: a lower level.
--   pits     { x, y, radius }: round holes in the floor
--   pillars  { x, y, radius }: columns standing on it
--   steps    { x1, y1, x2, y2 }: the edges of stairs
--   ground   bare ground instead of stone slabs
--   tint     the floor's colour; wall: the colour of its edge
--   open     the ground covers the whole board and there are no walls
-- The names come from L["TAC_ROOM_" .. id:upper()], which the editor adds.
T.ROOMS = {
    { id = "round", shapes = { { "c", 500, 312, 290 } } },
    { id = "square", shapes = { { "r", 215, 27, 570, 570 } } },
    {
        id = "hall", shapes = { { "r", 60, 110, 880, 405 } },
        pillars = {
            { 200, 190, 15 }, { 350, 190, 15 }, { 500, 190, 15 }, { 650, 190, 15 }, { 800, 190, 15 },
            { 200, 435, 15 }, { 350, 435, 15 }, { 500, 435, 15 }, { 650, 435, 15 }, { 800, 435, 15 },
        },
    },
    -- Runs off both ends of the board: a corridor has no end walls.
    { id = "corridor", shapes = { { "r", -40, 212, 1080, 200 } } },
    { id = "cross", shapes = { { "r", 60, 222, 880, 180 }, { "r", 410, 20, 180, 585 } } },
    { id = "ring", shapes = { { "c", 500, 312, 290 } }, pits = { { 500, 312, 105 } } },
    { id = "bridge", shapes = { { "c", 215, 312, 185 }, { "c", 785, 312, 185 }, { "r", 380, 267, 240, 90 } } },
    {
        id = "cave", ground = true, tint = { 0.62, 0.54, 0.43 }, wall = { 0.60, 0.46, 0.25 },
        shapes = {
            { "e", 330, 300, 250, 200 }, { "e", 620, 260, 280, 190 }, { "e", 540, 420, 300, 170 },
            { "e", 800, 380, 150, 150 }, { "e", 180, 380, 130, 120 },
        },
    },
    {
        id = "stairs",
        shapes = { { "r", 70, 70, 370, 485 }, { "r", 560, 70, 370, 485, tone = 0.78 }, { "r", 440, 190, 120, 245, tone = 0.89 } },
        steps = {
            { 455, 190, 455, 435 }, { 470, 190, 470, 435 }, { 485, 190, 485, 435 }, { 500, 190, 500, 435 },
            { 515, 190, 515, 435 }, { 530, 190, 530, 435 }, { 545, 190, 545, 435 },
        },
    },
    { id = "open", ground = true, open = true, tint = { 0.50, 0.56, 0.36 }, shapes = {} },
}

local roomById = {}
for _, room in ipairs(T.ROOMS) do
    roomById[room.id] = room
end

-- Geometry ------------------------------------------------------------------------

-- Everything here is plain arithmetic in board units: no frames, no game calls.

local Geo = {}
T.Geo = Geo

Geo.MARKER_R = { 17, 23, 30 }  -- a marker's radius, by size
Geo.PLAYER_R = 22              -- a player's token
Geo.GROUP_H = 44               -- the height of a group's badge
Geo.LINE_W = { 4, 7, 10 }      -- how thick an arrow or a line is, by size
Geo.TEXT_H = { 20, 27, 36 }    -- the height of a text's letters, by size
Geo.MIN_RADIUS = 20            -- of an area
Geo.DEFAULT_RADIUS = 80        -- an area placed with a click
Geo.MIN_LENGTH = 16            -- a shorter arrow or line is a slip of the hand
Geo.SLACK = 5                  -- how far outside an item a click still hits it
Geo.GRIP = 13                  -- how near a handle a click takes hold of it
Geo.TOLERANCE = 3              -- how far a thinned line may stray from the drawn one

function Geo.Round(value)
    return floor(value + 0.5)
end

function Geo.Clamp(value, low, high)
    if value < low then
        return low
    elseif value > high then
        return high
    end
    return value
end

-- The nearest whole point on the board.
function Geo.ClampPoint(x, y)
    return Geo.Clamp(floor(x + 0.5), 0, T.BOARD_W), Geo.Clamp(floor(y + 0.5), 0, T.BOARD_H)
end

function Geo.OnBoard(x, y)
    return x >= 0 and x <= T.BOARD_W and y >= 0 and y <= T.BOARD_H
end

function Geo.Distance(x1, y1, x2, y2)
    local dx, dy = x2 - x1, y2 - y1
    return sqrt(dx * dx + dy * dy)
end

-- How far the point px, py is from the stretch between x1, y1 and x2, y2.
function Geo.SegmentDistance(px, py, x1, y1, x2, y2)
    local dx, dy = x2 - x1, y2 - y1
    local length = dx * dx + dy * dy
    local along = 0
    if length > 0 then
        along = Geo.Clamp(((px - x1) * dx + (py - y1) * dy) / length, 0, 1)
    end
    return Geo.Distance(px, py, x1 + along * dx, y1 + along * dy)
end

-- A size as stored in an item: 1, 2 or 3; 2 when it is missing or odd.
function Geo.Size(size)
    if size == 1 or size == 3 then
        return size
    end
    return 2
end

-- The length of a line through points { x1, y1, x2, y2, ... }.
function Geo.Length(points)
    local length = 0
    for i = 3, #points - 1, 2 do
        length = length + Geo.Distance(points[i - 2], points[i - 1], points[i], points[i + 1])
    end
    return length
end

-- Thins a drawn stroke { x1, y1, x2, y2, ... } to at most maxPoints points
-- (T.MAX_POINTS when left out), as whole points on the board. The ends are
-- kept; then the point that lies furthest from the line so far is added,
-- again and again, until every point left out is within `tolerance` of the
-- line or the line is full. A straight stroke becomes two points, a curve
-- keeps its bends. Returns a new list.
function Geo.Simplify(points, maxPoints, tolerance)
    maxPoints = max(2, maxPoints or T.MAX_POINTS)
    tolerance = tolerance or Geo.TOLERANCE

    local xs, ys, count = {}, {}, 0
    for i = 1, #points - 1, 2 do
        local x, y = Geo.ClampPoint(points[i], points[i + 1])
        if count == 0 or x ~= xs[count] or y ~= ys[count] then
            count = count + 1
            xs[count], ys[count] = x, y
        end
    end
    if count == 0 then
        return {}
    end

    -- The point furthest from the straight stretch between two kept points.
    local function Span(from, to)
        local farthest, distance = nil, 0
        for i = from + 1, to - 1 do
            local d = Geo.SegmentDistance(xs[i], ys[i], xs[from], ys[from], xs[to], ys[to])
            if d > distance then
                farthest, distance = i, d
            end
        end
        return { from = from, to = to, farthest = farthest, distance = distance }
    end

    local keep = { [1] = true, [count] = true }
    local kept = count > 1 and 2 or 1
    local spans = { Span(1, count) }
    while kept < maxPoints do
        local worst
        for index, span in ipairs(spans) do
            if span.farthest and span.distance > tolerance and (not worst or span.distance > spans[worst].distance) then
                worst = index
            end
        end
        if not worst then
            break
        end
        local span = spans[worst]
        keep[span.farthest] = true
        kept = kept + 1
        spans[worst] = Span(span.from, span.farthest)
        spans[#spans + 1] = Span(span.farthest, span.to)
    end

    local result = {}
    for i = 1, count do
        if keep[i] then
            result[#result + 1] = xs[i]
            result[#result + 1] = ys[i]
        end
    end
    return result
end

-- The groups of a group item as a sorted list without repeats: { 1, 2 }.
function Geo.GroupList(groups)
    local has, list = {}, {}
    if type(groups) == "table" then
        for _, group in ipairs(groups) do
            if type(group) == "number" and group >= 1 and group <= 8 then
                has[floor(group)] = true
            end
        end
    end
    for group = 1, 8 do
        if has[group] then
            list[#list + 1] = group
        end
    end
    return list
end

-- What a group's badge says: "3", "1+2", "1-4" (three or more in a row),
-- "1+2+5". "" when there is no group.
function Geo.GroupText(groups)
    local list = Geo.GroupList(groups)
    local parts = {}
    local i = 1
    while i <= #list do
        local last = i
        while list[last + 1] == list[last] + 1 do
            last = last + 1
        end
        if last - i >= 2 then
            parts[#parts + 1] = ("%d-%d"):format(list[i], list[last])
        elseif last > i then
            parts[#parts + 1] = ("%d+%d"):format(list[i], list[last])
        else
            parts[#parts + 1] = ("%d"):format(list[i])
        end
        i = last + 1
    end
    return table.concat(parts, "+")
end

-- A group's badge: its width, its height and its text. The width follows the
-- text, so the badge is as wide for every viewer.
function Geo.GroupSize(item)
    local text = Geo.GroupText(item.g)
    if text == "" then
        text = "-"
    end
    local height = Geo.GROUP_H
    return floor(height * 1.25 + #text * height * 0.34 + 0.5), height, text
end

-- About how wide a text is drawn with letters `height` tall. The game's own
-- measure differs a little by letter; this is the same everywhere.
function Geo.TextWidth(text, height)
    local _, letters = (text or ""):gsub("[^\128-\191]", "")
    return letters * height * 0.55
end

-- The box an item covers: left, top, right, bottom. Labels under markers are
-- not counted.
function Geo.Box(item)
    local k = item.k
    if k == "g" then
        local width, height = Geo.GroupSize(item)
        return item.x - width / 2, item.y - height / 2, item.x + width / 2, item.y + height / 2
    elseif k == "t" then
        local height = Geo.TEXT_H[Geo.Size(item.s)]
        local width = max(height, Geo.TextWidth(item.t, height))
        return item.x - width / 2, item.y - height * 0.6, item.x + width / 2, item.y + height * 0.6
    elseif k == "a" then
        local half = Geo.LINE_W[Geo.Size(item.s)] / 2
        return min(item.x, item.x2) - half, min(item.y, item.y2) - half, max(item.x, item.x2) + half, max(item.y, item.y2) + half
    elseif k == "l" then
        local half = Geo.LINE_W[Geo.Size(item.s)] / 2
        local p = item.p
        local left, top, right, bottom = p[1], p[2], p[1], p[2]
        for i = 3, #p - 1, 2 do
            left, right = min(left, p[i]), max(right, p[i])
            top, bottom = min(top, p[i + 1]), max(bottom, p[i + 1])
        end
        return left - half, top - half, right + half, bottom + half
    end
    local radius = k == "m" and Geo.MARKER_R[Geo.Size(item.s)] or k == "p" and Geo.PLAYER_R or item.r or 0
    return item.x - radius, item.y - radius, item.x + radius, item.y + radius
end

-- Is the point x, y on this item? Arrows and lines by how far the point is
-- from them, the rest by their shape.
function Geo.Hit(item, x, y, slack)
    slack = slack or Geo.SLACK
    local k = item.k
    if k == "m" then
        return Geo.Distance(x, y, item.x, item.y) <= Geo.MARKER_R[Geo.Size(item.s)] + slack
    elseif k == "p" then
        return Geo.Distance(x, y, item.x, item.y) <= Geo.PLAYER_R + slack
    elseif k == "z" then
        return Geo.Distance(x, y, item.x, item.y) <= (item.r or 0)
    elseif k == "g" or k == "t" then
        local left, top, right, bottom = Geo.Box(item)
        return x >= left - slack and x <= right + slack and y >= top - slack and y <= bottom + slack
    elseif k == "a" then
        return Geo.SegmentDistance(x, y, item.x, item.y, item.x2, item.y2) <= Geo.LINE_W[Geo.Size(item.s)] / 2 + slack
    elseif k == "l" then
        local reach = Geo.LINE_W[Geo.Size(item.s)] / 2 + slack
        local p = item.p
        for i = 3, #p - 1, 2 do
            if Geo.SegmentDistance(x, y, p[i - 2], p[i - 1], p[i], p[i + 1]) <= reach then
                return true
            end
        end
    end
    return false
end

-- The item at a point: its index, or nil. The topmost item wins (the last in
-- the list), but areas are asked last: an area is see-through, so a marker
-- standing in one is what the click means, also when the area was drawn later.
function Geo.HitTest(items, x, y, slack)
    if type(items) ~= "table" then
        return nil
    end
    for index = #items, 1, -1 do
        local item = items[index]
        if type(item) == "table" and item.k ~= "z" and Geo.Hit(item, x, y, slack) then
            return index
        end
    end
    for index = #items, 1, -1 do
        local item = items[index]
        if type(item) == "table" and item.k == "z" and Geo.Hit(item, x, y, slack) then
            return index
        end
    end
    return nil
end

-- Is this a line with two points: one that was drawn straight?
function Geo.IsStraight(item)
    return item.k == "l" and type(item.p) == "table" and #item.p == 4
end

-- Where the handle that sets an area's radius sits: on its edge, on the side
-- that is on the board.
function Geo.RadiusHandle(item)
    local radius = item.r or 0
    if item.x + radius <= T.BOARD_W then
        return item.x + radius, item.y
    elseif item.x - radius >= 0 then
        return item.x - radius, item.y
    elseif item.y + radius <= T.BOARD_H then
        return item.x, item.y + radius
    end
    return item.x, item.y - radius
end

-- Which handle of a selected item is at x, y: "tail" or "head" (the ends of an
-- arrow or a straight line), "radius" (an area), or nil.
function Geo.HitHandle(item, x, y, grip)
    grip = grip or Geo.GRIP
    local k = item.k
    if k == "a" then
        if Geo.Distance(x, y, item.x2, item.y2) <= grip then
            return "head"
        elseif Geo.Distance(x, y, item.x, item.y) <= grip then
            return "tail"
        end
    elseif Geo.IsStraight(item) then
        local p = item.p
        if Geo.Distance(x, y, p[3], p[4]) <= grip then
            return "head"
        elseif Geo.Distance(x, y, p[1], p[2]) <= grip then
            return "tail"
        end
    elseif k == "z" then
        local hx, hy = Geo.RadiusHandle(item)
        if Geo.Distance(x, y, hx, hy) <= grip then
            return "radius"
        end
    end
    return nil
end

-- Moves an item by dx, dy, as far as it can go with every point of it still
-- on the board. Returns whether it moved.
function Geo.Move(item, dx, dy)
    local k = item.k
    local left, top, right, bottom
    if k == "l" then
        local p = item.p
        left, top, right, bottom = p[1], p[2], p[1], p[2]
        for i = 3, #p - 1, 2 do
            left, right = min(left, p[i]), max(right, p[i])
            top, bottom = min(top, p[i + 1]), max(bottom, p[i + 1])
        end
    elseif k == "a" then
        left, top, right, bottom = min(item.x, item.x2), min(item.y, item.y2), max(item.x, item.x2), max(item.y, item.y2)
    else
        left, top, right, bottom = item.x, item.y, item.x, item.y
    end
    dx = Geo.Round(Geo.Clamp(dx, min(0, -left), max(0, T.BOARD_W - right)))
    dy = Geo.Round(Geo.Clamp(dy, min(0, -top), max(0, T.BOARD_H - bottom)))
    if dx == 0 and dy == 0 then
        return false
    end
    if k == "l" then
        local p = item.p
        for i = 1, #p - 1, 2 do
            p[i], p[i + 1] = p[i] + dx, p[i + 1] + dy
        end
    else
        item.x, item.y = item.x + dx, item.y + dy
        if k == "a" then
            item.x2, item.y2 = item.x2 + dx, item.y2 + dy
        end
    end
    return true
end

-- A copy of a value, with copies of the tables in it.
function Geo.Copy(value)
    if type(value) ~= "table" then
        return value
    end
    local copy = {}
    for key, inner in pairs(value) do
        copy[key] = Geo.Copy(inner)
    end
    return copy
end

-- A map background. art is what T.MapArt gives; bg is the scene's background
-- ({ zoom, cx, cy }, see TacticsCore.lua).

-- How large the whole map is drawn, in board units: at zoom 10 it just fits.
function Geo.MapSize(art, zoom)
    local scale = min(T.BOARD_W / art.width, T.BOARD_H / art.height) * (zoom or T.MIN_ZOOM) / 10
    return art.width * scale, art.height * scale
end

-- Where the map lies on the board: left, top, width, height in board units.
function Geo.MapBox(art, bg)
    local width, height = Geo.MapSize(art, bg.zoom)
    return T.BOARD_W / 2 - (bg.cx or 500) / 1000 * width, T.BOARD_H / 2 - (bg.cy or 500) / 1000 * height, width, height
end

-- The point of the map (0 to 1000 each way, like cx and cy) under a board point.
function Geo.BoardToMap(art, bg, x, y)
    local left, top, width, height = Geo.MapBox(art, bg)
    return (x - left) / width * 1000, (y - top) / height * 1000
end

-- Moves the map by dx, dy board units from where its middle was at cx, cy.
-- The middle stays on the map. Not rounded: the board rounds when the drag ends.
function Geo.PanMap(bg, art, cx, cy, dx, dy)
    local width, height = Geo.MapSize(art, bg.zoom)
    bg.cx = Geo.Clamp(cx - dx / width * 1000, 0, 1000)
    bg.cy = Geo.Clamp(cy - dy / height * 1000, 0, 1000)
end

-- Sets the zoom (kept within T.MIN_ZOOM and T.MAX_ZOOM) so that the point of
-- the map under the board point x, y stays there: zooming in on what the mouse
-- points at.
function Geo.ZoomMap(bg, art, zoom, x, y)
    x, y = x or T.BOARD_W / 2, y or T.BOARD_H / 2
    local mx, my = Geo.BoardToMap(art, bg, x, y)
    bg.zoom = Geo.Clamp(Geo.Round(zoom), T.MIN_ZOOM, T.MAX_ZOOM)
    local width, height = Geo.MapSize(art, bg.zoom)
    bg.cx = Geo.Clamp(Geo.Round(mx - (x - T.BOARD_W / 2) / width * 1000), 0, 1000)
    bg.cy = Geo.Clamp(Geo.Round(my - (y - T.BOARD_H / 2) / height * 1000), 0, 1000)
end

-- Small helpers -------------------------------------------------------------------

-- A colour of T.COLORS by its index; white for an index that is not there.
local function Colour(index)
    local colour = T.COLORS[index] or T.COLORS[1]
    return colour[1], colour[2], colour[3]
end

-- Is this colour nearly black? Then the dark outline that makes lines and text
-- readable would hide them instead: they get a light one.
local function IsDark(r, g, b)
    return r * 0.30 + g * 0.59 + b * 0.11 < 0.25
end

-- Empties a table without making a new one: the scene's own tables are kept.
local function Wipe(list)
    for key in pairs(list) do
        list[key] = nil
    end
end

-- At most `limit` characters of a text (not bytes: names have letters like ø
-- and é). nil for anything that is not a text with something in it.
local function CutText(text, limit)
    if type(text) ~= "string" or text == "" then
        return nil
    end
    local count, at, length = 0, 1, #text
    while at <= length do
        if count == limit then
            return text:sub(1, at - 1)
        end
        local byte = text:byte(at)
        at = at + (byte < 0x80 and 1 or byte < 0xE0 and 2 or byte < 0xF0 and 3 or 4)
        count = count + 1
    end
    return text
end

-- A text from Locales.lua when it is there, otherwise the fallback: the
-- editor adds these texts after this file was written.
local function Words(key, fallback)
    local text = L[key]
    if type(text) ~= "string" or text == key then
        return fallback
    end
    return text
end

local function Fire(board, name, ...)
    local callback = board[name]
    if type(callback) == "function" then
        callback(board, ...)
    end
end

-- The font file the game uses for ordinary text, so the board's text has the
-- letters of the player's language.
local fontFile
local function FontFile()
    if not fontFile then
        local file = GameFontNormal and GameFontNormal.GetFont and GameFontNormal:GetFont()
        if type(file) ~= "string" or file == "" then
            file = STANDARD_TEXT_FONT or "Fonts\\FRIZQT__.TTF"
        end
        fontFile = file
    end
    return fontFile
end

local function Positive(value)
    return type(value) == "number" and value > 0
end

-- What T.MapArt gives for a map, when the core has that function and all the
-- numbers the board needs are there. nil otherwise.
local function MapArt(map)
    if type(T.MapArt) ~= "function" or map == nil then
        return nil
    end
    local art = T.MapArt(map)
    if type(art) ~= "table" or type(art.textures) ~= "table" then
        return nil
    end
    if not (Positive(art.width) and Positive(art.height) and Positive(art.tileW) and Positive(art.tileH)
            and Positive(art.cols) and Positive(art.rows)) then
        return nil
    end
    return art
end

-- Pools -----------------------------------------------------------------------------

-- A slot is one frame with the textures, lines and texts drawn on it. Each is
-- made once and used again: a redraw takes them from the start of the lists
-- and hides the ones left over, so nothing new is made unless there is more to
-- draw than ever before.

local function NewSlot(board)
    local frame = CreateFrame("Frame", nil, board)
    frame:SetAllPoints(board)
    return { frame = frame, textures = {}, lines = {}, texts = {}, nTextures = 0, nLines = 0, nTexts = 0 }
end

local function BeginSlot(slot)
    slot.nTextures, slot.nLines, slot.nTexts = 0, 0, 0
end

local function EndSlot(slot)
    for i = slot.nTextures + 1, #slot.textures do
        slot.textures[i]:Hide()
    end
    for i = slot.nLines + 1, #slot.lines do
        slot.lines[i]:Hide()
    end
    for i = slot.nTexts + 1, #slot.texts do
        slot.texts[i]:Hide()
    end
end

-- The next texture of a slot, as if new: what the one before it left behind
-- (a crop, a colour, a turn) is cleared.
local function Texture(slot, layer, sublevel)
    local n = slot.nTextures + 1
    slot.nTextures = n
    local texture = slot.textures[n]
    if not texture then
        texture = slot.frame:CreateTexture(nil, layer, nil, sublevel)
        slot.textures[n] = texture
    end
    texture:SetDrawLayer(layer, sublevel)
    texture:ClearAllPoints()
    texture:SetTexCoord(0, 1, 0, 1)
    texture:SetVertexColor(1, 1, 1, 1)
    texture:SetAlpha(1)
    texture:SetRotation(0)
    texture:Show()
    return texture
end

-- A picture centred on x, y. Places are in pixels from the board's top left
-- corner, y downwards, here and in everything below.
local function Sprite(slot, layer, sublevel, path, x, y, width, height, r, g, b, a)
    local texture = Texture(slot, layer, sublevel)
    texture:SetTexture(path)
    texture:SetVertexColor(r, g, b, a or 1)
    texture:SetSize(max(0.1, width), max(0.1, height))
    texture:SetPoint("CENTER", slot.frame, "TOPLEFT", x, -y)
    return texture
end

-- A rectangle in one colour.
local function Rect(slot, layer, sublevel, left, top, width, height, r, g, b, a)
    local texture = Texture(slot, layer, sublevel)
    texture:SetColorTexture(r, g, b, a or 1)
    texture:SetSize(max(0.1, width), max(0.1, height))
    texture:SetPoint("TOPLEFT", slot.frame, "TOPLEFT", left, -top)
    return texture
end

-- A line `thick` pixels wide. It is drawn with a texture that fades out
-- across the line, so it is smooth at any angle; the texture is wider than
-- the line it shows, which SetThickness makes up for.
local function Line(slot, layer, sublevel, x1, y1, x2, y2, thick, r, g, b, a)
    local n = slot.nLines + 1
    slot.nLines = n
    local line = slot.lines[n]
    if not line then
        line = slot.frame:CreateLine(nil, layer, nil, sublevel)
        slot.lines[n] = line
    end
    line:SetDrawLayer(layer, sublevel)
    local art, solid = ART.line, K.LINE_SOLID
    if thick >= K.BAND_FROM then
        art, solid = ART.band, K.BAND_SOLID
    end
    if line.art ~= art then
        line:SetTexture(art)
        line.art = art
    end
    line:SetVertexColor(r, g, b, a or 1)
    line:SetThickness(thick / solid)
    line:SetStartPoint("TOPLEFT", slot.frame, x1, -y1)
    line:SetEndPoint("TOPLEFT", slot.frame, x2, -y2)
    line:Show()
    return line
end

-- A text with a dark outline, so it reads on any floor. `plain` is for text
-- that is itself dark: no outline, a light shadow instead. Returns nothing
-- when the text would be too small to read.
local function Text(slot, text, size, x, y, anchor, r, g, b, plain)
    size = floor(size + 0.5)
    if size < K.MIN_FONT then
        return nil
    end
    local n = slot.nTexts + 1
    slot.nTexts = n
    local fontString = slot.texts[n]
    if not fontString then
        fontString = slot.frame:CreateFontString(nil, "OVERLAY", "GameFontNormal")
        fontString:SetWordWrap(false)
        fontString:SetJustifyH("CENTER")
        fontString:SetShadowOffset(1, -1)
        slot.texts[n] = fontString
    end
    local flags = plain and "" or "OUTLINE"
    if fontString.size ~= size or fontString.flags ~= flags then
        fontString:SetFont(FontFile(), size, flags)
        fontString.size, fontString.flags = size, flags
    end
    if plain then
        fontString:SetShadowColor(1, 1, 1, 0.9)
    else
        fontString:SetShadowColor(0, 0, 0, 1)
    end
    fontString:SetTextColor(r, g, b)
    fontString:SetText(text)
    fontString:ClearAllPoints()
    fontString:SetPoint(anchor, slot.frame, "TOPLEFT", x, -y)
    fontString:Show()
    return fontString
end

-- A circle or an oval drawn as a ring of short lines, so its edge is as thick
-- at any size (a ring texture would get a thicker edge the larger it is drawn).
-- Each line reaches a little past its ends: lines are cut square, and where
-- two meet at an angle the outside of the bend would otherwise show a gap.
local function Oval(slot, layer, sublevel, x, y, radiusX, radiusY, thick, r, g, b, a)
    local count = max(K.OVAL_MIN, min(K.OVAL_MAX, ceil(pi * (radiusX + radiusY) / K.OVAL_STEP)))
    local step = 2 * pi / count
    local over = thick * 0.5 * step * 0.5 + 0.3
    local fromX, fromY = x + radiusX, y
    for i = 1, count do
        local toX, toY = x + radiusX * cos(i * step), y + radiusY * sin(i * step)
        local dx, dy = toX - fromX, toY - fromY
        local length = sqrt(dx * dx + dy * dy)
        if length > 0.01 then
            dx, dy = dx / length * over, dy / length * over
            Line(slot, layer, sublevel, fromX - dx, fromY - dy, toX + dx, toY + dy, thick, r, g, b, a)
        end
        fromX, fromY = toX, toY
    end
end

-- A disc `size` across.
local function Dot(slot, layer, sublevel, x, y, size, r, g, b, a)
    return Sprite(slot, layer, sublevel, ART.dot, x, y, size * K.DOT_FILL, size * K.DOT_FILL, r, g, b, a)
end

-- A bar with round ends.
local function Pill(slot, layer, sublevel, x, y, width, height, r, g, b)
    width = max(width, height)
    Dot(slot, layer, sublevel, x - width / 2 + height / 2, y, height, r, g, b)
    Dot(slot, layer, sublevel, x + width / 2 - height / 2, y, height, r, g, b)
    if width > height then
        Rect(slot, layer, sublevel, x - width / 2 + height / 2, y - height / 2, width - height, height, r, g, b)
    end
end

-- Drawing the items -------------------------------------------------------------------

-- Within an item's frame: the glow at the very bottom, then the dark outlines,
-- then the item itself, then its text.
local GLOW_LAYER, UNDER_LAYER, MAIN_LAYER = "BACKGROUND", "BORDER", "ARTWORK"

-- The gold glow under an item that is the player's own. The board keeps a list
-- of them and lets them breathe (see OnUpdate).
local function Glow(board, slot, x, y, width, height)
    local glow = Sprite(slot, GLOW_LAYER, 0, ART.glow, x, y, width, height, GOLD[1], GOLD[2], 0.10)
    local n = board.glowN + 1
    board.glowN = n
    board.glows[n] = glow
end

local function Token(slot, x, y, radius, r, g, b)
    local size = radius * 2 * K.TOKEN_FILL
    return Sprite(slot, MAIN_LAYER, 0, ART.token, x, y, size, size, r, g, b)
end

local function Icon(slot, art, x, y, radius)
    local texture = Texture(slot, MAIN_LAYER, 2)
    T.PaintIcon(texture, art)
    local size = radius * 2 * K.ICON_FILL * (art.scale or 1)
    texture:SetSize(size, size)
    texture:SetPoint("CENTER", slot.frame, "TOPLEFT", x, -y)
end

-- The text under a token.
local function Label(slot, text, x, y, size, r, g, b)
    if type(text) == "string" and text ~= "" then
        Text(slot, text, size, x, y + 1, "TOP", r, g, b)
    end
end

-- Draw[k](board, slot, item, s, mine): s is pixels per board unit.
local Draw = {}

function Draw.m(board, slot, item, s, mine)
    local size = Geo.Size(item.s)
    local radius = Geo.MARKER_R[size] * s
    local x, y = item.x * s, item.y * s
    if mine then
        Glow(board, slot, x, y, radius * 2 * K.GLOW, radius * 2 * K.GLOW)
    end
    Token(slot, x, y, radius, Colour(item.c))
    Icon(slot, T.IconArt(item.i), x, y, radius)
    Label(slot, item.t, x, y + radius, K.LABEL_H[size] * s, 1, 1, 1)
end

function Draw.p(board, slot, item, s, mine)
    local radius = Geo.PLAYER_R * s
    local x, y = item.x * s, item.y * s
    local r, g, b = ClassColour(item.cl)
    if mine then
        Glow(board, slot, x, y, radius * 2 * K.GLOW, radius * 2 * K.GLOW)
    end
    Token(slot, x, y, radius, r, g, b)
    Icon(slot, ClassArt(item.cl), x, y, radius)
    Label(slot, item.n, x, y + radius, K.NAME_H * s, r, g, b)
end

function Draw.g(board, slot, item, s, mine)
    local width, height, text = Geo.GroupSize(item)
    local w, h = width * s, height * s
    local x, y = item.x * s, item.y * s
    if mine then
        Glow(board, slot, x, y, w + h * 1.4, h * K.GLOW)
    end
    local rim = max(1.5, h * 0.09)
    Pill(slot, UNDER_LAYER, 0, x, y, w + 3, h + 3, 0, 0, 0)
    Pill(slot, MAIN_LAYER, 0, x, y, w, h, WALL_COLOUR[1], WALL_COLOUR[2], WALL_COLOUR[3])
    Pill(slot, MAIN_LAYER, 1, x, y, w - 2 * rim, h - 2 * rim, 0.10, 0.10, 0.12)
    local figures = Sprite(slot, MAIN_LAYER, 2, ART.glyphs, x - w / 2 + h * 0.58, y, h * 0.66, h * 0.66, 1.00, 0.86, 0.40)
    local coords = glyphCoords.group
    figures:SetTexCoord(coords[1], coords[2], coords[3], coords[4])
    Text(slot, text, h * 0.5, x + h * 0.38, y, "CENTER", 1.00, 0.90, 0.50)
    Label(slot, item.t, x, y + h / 2, K.LABEL_H[2] * s, 1, 1, 1)
end

-- An arrow: the shaft, a round end at the tail and the head, each first in
-- the outline's colour and a little larger, then in the arrow's own.
function Draw.a(board, slot, item, s, mine)
    local thick = max(2, Geo.LINE_W[Geo.Size(item.s)] * s)
    local x1, y1, x2, y2 = item.x * s, item.y * s, item.x2 * s, item.y2 * s
    local dx, dy = x2 - x1, y2 - y1
    local length = sqrt(dx * dx + dy * dy)
    local r, g, b = Colour(item.c)
    local under = IsDark(r, g, b) and 0.92 or 0
    local outline = max(2, K.OUTLINE * s / 0.72)
    if length < 1 then
        -- A drag that has only just begun: a dot where the tail will be.
        Dot(slot, UNDER_LAYER, 0, x1, y1, thick + outline, under, under, under)
        Dot(slot, MAIN_LAYER, 0, x1, y1, thick, r, g, b)
        return
    end
    local ux, uy = dx / length, dy / length
    local head = thick * 3 + 12 * s
    local headX, headY = x2 - ux * head * K.HEAD_TIP, y2 - uy * head * K.HEAD_TIP
    local endX, endY = headX - ux * head * K.HEAD_JOIN, headY - uy * head * K.HEAD_JOIN
    local shaft = (endX - x1) * ux + (endY - y1) * uy > 0.5
    -- The board's y runs down and the game's up, hence the minus.
    local angle = atan2(-dy, dx)
    if mine then
        if shaft then
            Line(slot, GLOW_LAYER, 0, x1, y1, endX, endY, thick + outline * 3, GOLD[1], GOLD[2], GOLD[3], 0.9)
        end
        Sprite(slot, GLOW_LAYER, 0, ART.arrow, headX, headY, head + outline * 5, head + outline * 5, GOLD[1], GOLD[2], GOLD[3], 0.9):SetRotation(angle)
    end
    if shaft then
        Line(slot, UNDER_LAYER, 0, x1, y1, endX, endY, thick + outline, under, under, under)
        Line(slot, MAIN_LAYER, 0, x1, y1, endX, endY, thick, r, g, b)
    end
    Dot(slot, UNDER_LAYER, 0, x1, y1, thick + outline, under, under, under)
    Dot(slot, MAIN_LAYER, 0, x1, y1, thick, r, g, b)
    Sprite(slot, UNDER_LAYER, 1, ART.arrow, headX, headY, head + outline * 1.8, head + outline * 1.8, under, under, under):SetRotation(angle)
    Sprite(slot, MAIN_LAYER, 1, ART.arrow, headX, headY, head, head, r, g, b):SetRotation(angle)
end

-- A drawn line: a stretch between each two points and a disc on every point.
-- Without the discs the outside of each bend would show a notch.
function Draw.l(board, slot, item, s, mine)
    local p = item.p
    if type(p) ~= "table" then
        return
    end
    local thick = max(2, Geo.LINE_W[Geo.Size(item.s)] * s)
    local r, g, b = Colour(item.c)
    local under = IsDark(r, g, b) and 0.92 or 0
    local outline = max(2, K.OUTLINE * s / 0.72)
    local lastX, lastY
    for i = 1, #p - 1, 2 do
        local x, y = p[i] * s, p[i + 1] * s
        if mine then
            Dot(slot, GLOW_LAYER, 0, x, y, thick + outline * 3, GOLD[1], GOLD[2], GOLD[3], 0.9)
        end
        Dot(slot, UNDER_LAYER, 0, x, y, thick + outline, under, under, under)
        Dot(slot, MAIN_LAYER, 0, x, y, thick, r, g, b)
        if lastX and (abs(x - lastX) > 0.5 or abs(y - lastY) > 0.5) then
            if mine then
                Line(slot, GLOW_LAYER, 0, lastX, lastY, x, y, thick + outline * 3, GOLD[1], GOLD[2], GOLD[3], 0.9)
            end
            Line(slot, UNDER_LAYER, 0, lastX, lastY, x, y, thick + outline, under, under, under)
            Line(slot, MAIN_LAYER, 0, lastX, lastY, x, y, thick, r, g, b)
        end
        lastX, lastY = x, y
    end
end

-- An area: a see-through disc with a clear edge.
function Draw.z(board, slot, item, s, mine)
    local radius = max(1, (item.r or 0) * s)
    local x, y = item.x * s, item.y * s
    local r, g, b = Colour(item.c)
    local edge = max(1.5, 3.2 * s / 0.72)
    if mine then
        Oval(slot, GLOW_LAYER, 0, x, y, radius, radius, edge * 3, GOLD[1], GOLD[2], GOLD[3], 0.85)
    end
    local size = radius * 2 * K.DISC_FILL
    Sprite(slot, MAIN_LAYER, 0, ART.disc, x, y, size, size, r, g, b, K.AREA_ALPHA)
    Oval(slot, MAIN_LAYER, 1, x, y, radius, radius, edge, r, g, b, 0.95)
end

function Draw.t(board, slot, item, s, mine)
    if type(item.t) ~= "string" or item.t == "" then
        return
    end
    local height = Geo.TEXT_H[Geo.Size(item.s)] * s
    local x, y = item.x * s, item.y * s
    local r, g, b = Colour(item.c)
    if mine then
        Glow(board, slot, x, y, Geo.TextWidth(item.t, height) + height * 2.5, height * 2.6)
    end
    Text(slot, item.t, height, x, y, "CENTER", r, g, b, IsDark(r, g, b))
end

-- The item's frame, made the first time there is an item at that place in
-- the list.
local function ItemSlot(board, index)
    local slot = board.slots[index]
    if not slot then
        slot = NewSlot(board)
        slot.frame:SetFrameLevel(board.level + 1 + min(index, T.MAX_ITEMS))
        board.slots[index] = slot
    end
    return slot
end

local function DrawItems(board)
    local scene, s = board.scene, board.px
    local items = scene and scene.items
    local count = type(items) == "table" and #items or 0
    local highlight = board.highlightMine and type(T.IsMine) == "function"
    board.glowN = 0
    for index = 1, count do
        local item = items[index]
        local slot = ItemSlot(board, index)
        local draw = type(item) == "table" and Draw[item.k]
        BeginSlot(slot)
        if draw then
            draw(board, slot, item, s, highlight and T.IsMine(item) and true or false)
        end
        EndSlot(slot)
        slot.frame:Show()
    end
    for index = count + 1, #board.slots do
        board.slots[index].frame:Hide()
    end
end

-- The room or the map --------------------------------------------------------------------

-- The frame under the items has, besides a slot's lists, the repeating
-- textures (the floors) and the map's tiles. Those are kept apart because a
-- repeating texture is set up differently, and stays that way.

-- A stretch of a repeating texture: x, y, width, height in board units. The
-- pattern is placed by where the stretch is on the board, so two stretches
-- side by side continue each other. round cuts it to the circle or oval that
-- fits it, with a mask.
local function Tile(back, layer, sublevel, path, unit, s, x, y, width, height, tint, tone, round)
    local n = back.nTiles + 1
    back.nTiles = n
    local tile = back.tiles[n]
    if not tile then
        tile = back.frame:CreateTexture(nil, layer, nil, sublevel)
        back.tiles[n] = tile
    end
    tile:SetDrawLayer(layer, sublevel)
    if tile.path ~= path then
        tile:SetTexture(path, "REPEAT", "REPEAT")
        tile.path = path
    end
    tile:SetTexCoord(x / unit, (x + width) / unit, y / unit, (y + height) / unit)
    tile:SetVertexColor(tint[1] * tone, tint[2] * tone, tint[3] * tone)
    tile:ClearAllPoints()
    tile:SetPoint("TOPLEFT", back.frame, "TOPLEFT", x * s, -y * s)
    tile:SetSize(max(0.1, width * s), max(0.1, height * s))
    if round then
        local mask = tile.mask
        if not mask then
            mask = back.frame:CreateMaskTexture()
            mask:SetTexture(ART.disc, "CLAMPTOBLACKADDITIVE", "CLAMPTOBLACKADDITIVE")
            tile.mask = mask
        end
        mask:ClearAllPoints()
        mask:SetPoint("CENTER", tile, "CENTER")
        mask:SetSize(max(0.1, width * s * K.DISC_FILL), max(0.1, height * s * K.DISC_FILL))
        if not tile.masked then
            tile:AddMaskTexture(mask)
            tile.masked = true
        end
    elseif tile.masked then
        tile:RemoveMaskTexture(tile.mask)
        tile.masked = false
    end
    tile:Show()
end

-- A room. Walls: under each piece of floor lies the same shape a little
-- larger, in the wall's colour. The floors cover everything inside, so what
-- shows is one even edge around the whole room, however its pieces overlap.
local function DrawRoom(back, room, s)
    local tint = room.tint or FLOOR_TINT
    local wall = room.wall or WALL_COLOUR
    local path, unit = ART.floor, K.FLOOR_UNIT
    if room.ground then
        path, unit = ART.rock, K.ROCK_UNIT
    end
    local w = K.WALL
    if room.open then
        Tile(back, "ARTWORK", 0, path, unit, s, 0, 0, T.BOARD_W, T.BOARD_H, tint, 1, false)
    end
    for _, shape in ipairs(room.shapes) do
        local tone = shape.tone or 1
        if shape[1] == "r" then
            local x, y, width, height = shape[2], shape[3], shape[4], shape[5]
            Rect(back, "BORDER", 0, (x - w) * s, (y - w) * s, (width + 2 * w) * s, (height + 2 * w) * s, wall[1], wall[2], wall[3])
            Tile(back, "ARTWORK", 0, path, unit, s, x, y, width, height, tint, tone, false)
        else
            local x, y, radiusX = shape[2], shape[3], shape[4]
            local radiusY = shape[5] or radiusX
            Oval(back, "BORDER", 0, x * s, y * s, radiusX * s, radiusY * s, 2 * w * s, wall[1], wall[2], wall[3])
            Tile(back, "ARTWORK", 0, path, unit, s, x - radiusX, y - radiusY, 2 * radiusX, 2 * radiusY, tint, tone, true)
        end
    end
    for _, pit in ipairs(room.pits or {}) do
        local x, y, radius = pit[1], pit[2], pit[3]
        Oval(back, "ARTWORK", 2, x * s, y * s, radius * s, radius * s, 2 * w * s, wall[1], wall[2], wall[3])
        Tile(back, "ARTWORK", 3, ART.rock, K.ROCK_UNIT, s, x - radius, y - radius, 2 * radius, 2 * radius, PIT_TINT, 1, true)
    end
    for _, pillar in ipairs(room.pillars or {}) do
        local x, y, radius = pillar[1] * s, pillar[2] * s, pillar[3] * s
        Dot(back, "ARTWORK", 2, x, y, radius * 2 + w * s, wall[1], wall[2], wall[3])
        Dot(back, "ARTWORK", 3, x, y, radius * 2, 0.24, 0.23, 0.26)
    end
    for _, step in ipairs(room.steps or {}) do
        Line(back, "ARTWORK", 5, step[1] * s, step[2] * s, step[3] * s, step[4] * s, max(1, 2.5 * s), 0.10, 0.09, 0.08, 0.5)
    end
end

-- The game's map of a dungeon floor: its tiles, scaled and placed from the
-- background's zoom and middle. The tiles in the last column and row are only
-- partly map, so they are cropped to the map's own size.
local function DrawMap(back, art, bg, s)
    local left, top, width = Geo.MapBox(art, bg)
    local scale = width / art.width -- board units per pixel of the map
    local index = 0
    for row = 1, art.rows do
        for column = 1, art.cols do
            index = index + 1
            local tile = back.maps[index]
            if not tile then
                tile = back.frame:CreateTexture(nil, "BACKGROUND", nil, 0)
                back.maps[index] = tile
            end
            local file = art.textures[index]
            local mapX, mapY = (column - 1) * art.tileW, (row - 1) * art.tileH
            local mapW, mapH = min(art.tileW, art.width - mapX), min(art.tileH, art.height - mapY)
            local x, y = left + mapX * scale, top + mapY * scale
            if file and mapW > 0 and mapH > 0 and x < T.BOARD_W and y < T.BOARD_H and x + mapW * scale > 0 and y + mapH * scale > 0 then
                if tile.file ~= file then
                    -- As the game's own map does: smooth when drawn smaller.
                    tile:SetTexture(file, nil, nil, "TRILINEAR")
                    tile.file = file
                end
                tile:SetTexCoord(0, mapW / art.tileW, 0, mapH / art.tileH)
                tile:ClearAllPoints()
                tile:SetPoint("TOPLEFT", back.frame, "TOPLEFT", x * s, -y * s)
                tile:SetSize(mapW * scale * s, mapH * scale * s)
                tile:Show()
            else
                -- Outside the board: not shown, so the game need not load it.
                tile:Hide()
            end
        end
    end
    return index
end

local function DrawBackground(board)
    local back, s = board.back, board.px
    local scene = board.scene
    local bg = scene and scene.bg
    local art
    board.mapMissing = false
    if type(bg) == "table" and bg.kind == "map" then
        art = MapArt(bg.map)
        board.mapMissing = art == nil
    end
    -- A room looks the same until the room or the board's size changes, and a
    -- cave is some hundred lines: it is drawn again only then. A map is cheap,
    -- and moves while it is dragged.
    local room = not art and scene and (type(bg) == "table" and bg.kind == "room" and roomById[bg.room] or roomById.square) or nil
    local what = art and "map" or room or "empty"
    if what ~= "map" and back.what == what and back.px == s then
        return
    end
    back.what, back.px = what, s

    BeginSlot(back)
    back.nTiles = 0
    Rect(back, "BACKGROUND", -8, 0, 0, T.BOARD_W * s, T.BOARD_H * s, BASE_COLOUR[1], BASE_COLOUR[2], BASE_COLOUR[3])
    Tile(back, "BACKGROUND", -6, ART.rock, K.ROCK_UNIT, s, 0, 0, T.BOARD_W, T.BOARD_H, SURROUND_TINT, 1, false)
    local tiles = 0
    if art then
        tiles = DrawMap(back, art, bg, s)
    elseif room then
        DrawRoom(back, room, s)
    end
    for i = tiles + 1, #back.maps do
        back.maps[i]:Hide()
    end
    for i = back.nTiles + 1, #back.tiles do
        back.tiles[i]:Hide()
    end
    EndSlot(back)
end

-- The selection ---------------------------------------------------------------------------

-- A handle: a gold dot with a dark edge, to drag.
local function Handle(slot, x, y, s)
    local size = max(8, 15 * s)
    Dot(slot, "ARTWORK", 2, x, y, size + 4, 0, 0, 0)
    Dot(slot, "ARTWORK", 3, x, y, size, GOLD[1], GOLD[2], GOLD[3])
end

local function DrawSelection(board)
    local slot, s = board.top, board.px
    BeginSlot(slot)
    local _, item = board:GetSelected()
    local k = item and item.k
    if k == "m" or k == "p" then
        local radius = (k == "m" and Geo.MARKER_R[Geo.Size(item.s)] or Geo.PLAYER_R) * s
        Sprite(slot, "ARTWORK", 0, ART.ring, item.x * s, item.y * s, radius * 2 * K.RING, radius * 2 * K.RING, GOLD[1], GOLD[2], GOLD[3])
    elseif k == "z" then
        local radius = (item.r or 0) * s + 3
        Oval(slot, "ARTWORK", 0, item.x * s, item.y * s, radius, radius, max(1.5, 2 * s), GOLD[1], GOLD[2], GOLD[3])
        local x, y = Geo.RadiusHandle(item)
        Handle(slot, x * s, y * s, s)
    elseif k == "a" then
        Handle(slot, item.x * s, item.y * s, s)
        Handle(slot, item.x2 * s, item.y2 * s, s)
    elseif k and Geo.IsStraight(item) then
        Handle(slot, item.p[1] * s, item.p[2] * s, s)
        Handle(slot, item.p[3] * s, item.p[4] * s, s)
    elseif k == "g" or k == "t" or (k == "l" and type(item.p) == "table" and #item.p >= 4) then
        -- A gold frame around a badge, a text or a drawn line.
        local left, top, right, bottom = Geo.Box(item)
        local pad = 7
        left, top, right, bottom = (left - pad) * s, (top - pad) * s, (right + pad) * s, (bottom + pad) * s
        local thick = max(1.5, 2 * s)
        Line(slot, "ARTWORK", 0, left, top, right, top, thick, GOLD[1], GOLD[2], GOLD[3])
        Line(slot, "ARTWORK", 0, right, top, right, bottom, thick, GOLD[1], GOLD[2], GOLD[3])
        Line(slot, "ARTWORK", 0, right, bottom, left, bottom, thick, GOLD[1], GOLD[2], GOLD[3])
        Line(slot, "ARTWORK", 0, left, bottom, left, top, thick, GOLD[1], GOLD[2], GOLD[3])
    end
    EndSlot(slot)
end

-- Undo --------------------------------------------------------------------------------------

-- Puts back a remembered state. The scene's own tables are filled again
-- rather than replaced: the host holds on to them.
local function Restore(board, state)
    local scene = board.scene
    if not scene then
        return
    end
    if type(scene.items) ~= "table" then
        scene.items = {}
    end
    Wipe(scene.items)
    for index, item in ipairs(state.items) do
        scene.items[index] = item
    end
    if type(scene.bg) == "table" and type(state.bg) == "table" then
        Wipe(scene.bg)
        for key, value in pairs(state.bg) do
            scene.bg[key] = value
        end
    else
        scene.bg = state.bg
    end
    local selected = state.selected
    if not selected or not scene.items[selected] then
        selected = nil
    end
    local changed = selected ~= board.selected
    board.selected = selected
    board:Redraw()
    if changed then
        Fire(board, "onSelect", selected)
    end
end

-- Editing ------------------------------------------------------------------------------------

-- Where the mouse is, in board units (not rounded, and outside 0..BOARD_W when
-- the mouse is beside the board). nil before the board has a place on screen.
local function CursorPoint(board)
    local left, top, scale = board:GetLeft(), board:GetTop(), board:GetEffectiveScale()
    if DW.IsSecret(left) or DW.IsSecret(top) or DW.IsSecret(scale) or not left or not top or not scale then
        return nil
    end
    if scale <= 0 or board.px <= 0 then
        return nil
    end
    local x, y = GetCursorPosition()
    return (x / scale - left) / board.px, (top - y / scale) / board.px
end

-- The groups a tool or an item names, or nil when there are none.
local function Groups(groups)
    local list = Geo.GroupList(groups)
    return #list > 0 and list or nil
end

-- A colour index that exists; `fallback` (or white) otherwise.
local function ColourIndex(index, fallback)
    if type(index) == "number" and T.COLORS[index] then
        return index
    end
    return fallback or 1
end

-- The item a placing tool makes at x, y, or nil when the tool lacks what the
-- item needs (a name, a group, a text). The items are shaped as the core's
-- T.Sanitize leaves them: no label is "", an unknown class is "".
local NewItem = {}

function NewItem.m(tool, x, y)
    local icon = tool.i
    if type(icon) ~= "string" or #icon > 12 or not icon:match("^[%l%d]+$") then
        return nil
    end
    return {
        k = "m", i = icon, x = x, y = y, t = CutText(tool.t, T.MAX_LABEL) or "",
        c = ColourIndex(tool.c, T.IconArt(icon).c), s = Geo.Size(tool.s),
    }
end

function NewItem.p(tool, x, y)
    local name = CutText(tool.n, T.MAX_NAME)
    if not name then
        return nil
    end
    local class = tool.cl
    if type(class) ~= "string" or #class > 12 or not class:match("^%u+$") then
        class = ""
    end
    return { k = "p", n = name, cl = class, x = x, y = y }
end

function NewItem.g(tool, x, y)
    local groups = Groups(tool.g)
    if not groups then
        return nil
    end
    return { k = "g", g = groups, x = x, y = y, t = CutText(tool.t, T.MAX_LABEL) or "" }
end

function NewItem.t(tool, x, y)
    local text = CutText(tool.t, T.MAX_LABEL)
    if not text then
        return nil
    end
    return { k = "t", x = x, y = y, t = text, c = ColourIndex(tool.c), s = Geo.Size(tool.s) }
end

-- Adds an item on top. Remembers the state before for undo. Refuses, and
-- tells the host, when the scene is full.
local function AddItem(board, scene, item)
    if type(scene.items) ~= "table" then
        scene.items = {}
    end
    local items = scene.items
    if #items >= T.MAX_ITEMS then
        Fire(board, "onLimit", "items")
        return nil
    end
    board:PushUndo()
    items[#items + 1] = item
    return #items
end

-- Takes an item out, and keeps the selection on the item it was on.
local function RemoveItem(board, index)
    table.remove(board.scene.items, index)
    local selected = board.selected
    if selected == index then
        board.selected = nil
        Fire(board, "onSelect", nil)
    elseif selected and selected > index then
        board.selected = selected - 1
        Fire(board, "onSelect", selected - 1)
    end
end

-- Puts an item back where a copy of it is.
local function PlaceLike(item, original)
    item.x, item.y, item.x2, item.y2, item.r = original.x, original.y, original.x2, original.y2, original.r
    if type(original.p) == "table" then
        local p = item.p
        for i = 1, #original.p do
            p[i] = original.p[i]
        end
        for i = #p, #original.p + 1, -1 do
            p[i] = nil
        end
    end
end

-- Is an arrow or a line too short to be meant?
local function TooShort(item)
    if item.k == "a" then
        return Geo.Distance(item.x, item.y, item.x2, item.y2) < Geo.MIN_LENGTH
    elseif item.k == "l" then
        return Geo.Length(item.p) < Geo.MIN_LENGTH
    end
    return false
end

-- Puts back the state remembered last. Returns whether there was one.
local function TakeBack(board)
    local state = board.scene and table.remove(board.undo)
    if not state then
        return false
    end
    Restore(board, state)
    return true
end

-- Stops a drag and puts back what it changed.
local function CancelDrag(board)
    local drag = board.drag
    if not drag then
        return
    end
    board.drag = nil
    if drag.pushed then
        TakeBack(board)
    end
end

-- A drag takes hold of the state for undo only when something really moves:
-- a click that selects is not an edit.
local function DragBegins(board, drag, x, y)
    if drag.pushed then
        return true
    end
    if abs(x - drag.sx) < K.SLOP and abs(y - drag.sy) < K.SLOP then
        return false
    end
    board:PushUndo()
    drag.pushed = true
    return true
end

-- Start[kind](board, scene, tool, x, y): the left button went down at x, y
-- with this tool. Most set board.drag = { mode = ..., ... }, which Step and
-- Finish below carry on with.
local Start = {}

function Start.select(board, scene, tool, x, y)
    local items = scene.items
    local index, item = board:GetSelected()
    local mode = item and Geo.HitHandle(item, x, y)
    if not mode then
        index = Geo.HitTest(items, x, y)
        board:Select(index)
        item = index and items[index]
        mode = item and "move"
    end
    if mode then
        board.drag = { mode = mode, index = index, sx = x, sy = y, original = Geo.Copy(item) }
    end
end

-- A marker, a player, a group or a text: the click places it, and it follows
-- the mouse until the button is let go, to set it down exactly.
local function StartPlace(board, scene, tool, x, y)
    local px, py = Geo.ClampPoint(x, y)
    local item = NewItem[tool.kind](tool, px, py)
    local index = item and AddItem(board, scene, item)
    if not index then
        return
    end
    board:Select(index)
    board:Redraw()
    board.drag = { mode = "move", index = index, sx = x, sy = y, original = Geo.Copy(item), pushed = true, changed = true }
end
Start.m, Start.p, Start.g, Start.t = StartPlace, StartPlace, StartPlace, StartPlace

function Start.a(board, scene, tool, x, y)
    local px, py = Geo.ClampPoint(x, y)
    local index = AddItem(board, scene, { k = "a", x = px, y = py, x2 = px, y2 = py, c = ColourIndex(tool.c), s = Geo.Size(tool.s) })
    if index then
        board:Redraw()
        board.drag = { mode = "arrow", index = index, sx = x, sy = y, pushed = true }
    end
end

function Start.l(board, scene, tool, x, y)
    local px, py = Geo.ClampPoint(x, y)
    local index = AddItem(board, scene, { k = "l", p = { px, py, px, py }, c = ColourIndex(tool.c), s = Geo.Size(tool.s) })
    if index then
        board:Redraw()
        board.drag = { mode = "line", index = index, sx = x, sy = y, pushed = true, raw = { px, py } }
    end
end

function Start.z(board, scene, tool, x, y)
    local px, py = Geo.ClampPoint(x, y)
    local index = AddItem(board, scene, { k = "z", x = px, y = py, r = Geo.MIN_RADIUS, c = ColourIndex(tool.c) })
    if index then
        board:Redraw()
        board.drag = { mode = "area", index = index, sx = x, sy = y, pushed = true }
    end
end

function Start.erase(board, scene, tool, x, y)
    local index = Geo.HitTest(scene.items, x, y)
    if index then
        board:PushUndo()
        RemoveItem(board, index)
        board:Redraw()
        Fire(board, "onChanged")
    end
end

function Start.bg(board, scene, tool, x, y)
    local bg = scene.bg
    local art = type(bg) == "table" and bg.kind == "map" and MapArt(bg.map)
    if art then
        board.drag = { mode = "pan", sx = x, sy = y, cx = bg.cx or 500, cy = bg.cy or 500, art = art }
    end
end

-- Step[mode](board, scene, drag, x, y): the mouse moved to x, y during a
-- drag. Returns true when the board must be drawn again.
local Step = {}

function Step.move(board, scene, drag, x, y)
    local item = scene.items[drag.index]
    if not item or not DragBegins(board, drag, x, y) then
        return false
    end
    -- From where the item was when the drag began, not from where the last
    -- step left it: rounding and the board's edge would add up otherwise.
    PlaceLike(item, drag.original)
    Geo.Move(item, x - drag.sx, y - drag.sy)
    drag.changed = true
    return true
end

-- One end of an arrow or of a straight line.
local function StepEnd(board, scene, drag, x, y)
    local item = scene.items[drag.index]
    if not item or not DragBegins(board, drag, x, y) then
        return false
    end
    local px, py = Geo.ClampPoint(x, y)
    if item.k == "a" then
        if drag.mode == "tail" then
            item.x, item.y = px, py
        else
            item.x2, item.y2 = px, py
        end
    else
        local at = drag.mode == "tail" and 1 or 3
        item.p[at], item.p[at + 1] = px, py
    end
    drag.changed = true
    return true
end
Step.tail, Step.head = StepEnd, StepEnd

function Step.radius(board, scene, drag, x, y)
    local item = scene.items[drag.index]
    if not item or not DragBegins(board, drag, x, y) then
        return false
    end
    item.r = Geo.Clamp(Geo.Round(Geo.Distance(item.x, item.y, x, y)), Geo.MIN_RADIUS, T.MAX_RADIUS)
    drag.changed = true
    return true
end

function Step.arrow(board, scene, drag, x, y)
    local item = scene.items[drag.index]
    item.x2, item.y2 = Geo.ClampPoint(x, y)
    return true
end

-- Free-hand: the mouse's path is collected and thinned on the way, so what is
-- seen while drawing is what is kept. With shift held: one straight stretch
-- from where the drag began.
function Step.line(board, scene, drag, x, y)
    local item = scene.items[drag.index]
    local px, py = Geo.ClampPoint(x, y)
    local raw = drag.raw
    local count = #raw
    if Geo.Distance(px, py, raw[count - 1], raw[count]) >= K.SAMPLE then
        raw[count + 1], raw[count + 2] = px, py
        if count + 2 > K.RAW_MAX then
            -- A very long stroke: keep its shape in fewer points.
            drag.raw = Geo.Simplify(raw, K.RAW_MAX / 4, 1)
            raw = drag.raw
        end
    end
    local points
    if type(IsShiftKeyDown) == "function" and IsShiftKeyDown() then
        points = { raw[1], raw[2], px, py }
    else
        points = Geo.Simplify(raw, T.MAX_POINTS, Geo.TOLERANCE)
        if #points < 4 then
            points = { raw[1], raw[2], px, py }
        end
    end
    item.p = points
    return true
end

function Step.area(board, scene, drag, x, y)
    local item = scene.items[drag.index]
    local radius = Geo.Distance(item.x, item.y, x, y)
    if radius >= Geo.MIN_RADIUS then
        drag.grown = true
    end
    item.r = Geo.Clamp(Geo.Round(radius), Geo.MIN_RADIUS, T.MAX_RADIUS)
    return true
end

function Step.pan(board, scene, drag, x, y)
    if not DragBegins(board, drag, x, y) then
        return false
    end
    Geo.PanMap(scene.bg, drag.art, drag.cx, drag.cy, x - drag.sx, y - drag.sy)
    drag.changed = true
    return true
end

-- Finish[mode](board, scene, drag, x, y): the button was let go at x, y.
local Finish = {}

-- A click on a board that is not being edited.
function Finish.click(board, scene, drag, x, y)
    if abs(x - drag.sx) <= K.CLICK and abs(y - drag.sy) <= K.CLICK and Geo.OnBoard(x, y) then
        Fire(board, "onClick", Geo.Round(x), Geo.Round(y))
    end
end

local function FinishEdit(board, scene, drag)
    if not drag.changed then
        return
    end
    local item = scene.items[drag.index]
    if item and drag.original and TooShort(item) then
        -- One end was dropped on the other: nothing would be left to see.
        PlaceLike(item, drag.original)
        table.remove(board.undo)
        board:Redraw()
        return
    end
    Fire(board, "onChanged")
end
Finish.move, Finish.tail, Finish.head, Finish.radius = FinishEdit, FinishEdit, FinishEdit, FinishEdit

-- A new arrow or line: kept when it is long enough to be meant.
local function FinishStroke(board, scene, drag)
    local item = scene.items[drag.index]
    if not item or TooShort(item) then
        TakeBack(board)
        return
    end
    board:Select(drag.index)
    Fire(board, "onChanged")
end
Finish.arrow, Finish.line = FinishStroke, FinishStroke

function Finish.area(board, scene, drag)
    local item = scene.items[drag.index]
    if not drag.grown then
        item.r = Geo.DEFAULT_RADIUS -- a click without a drag: an area of the usual size
        board:Redraw()
    end
    board:Select(drag.index)
    Fire(board, "onChanged")
end

function Finish.pan(board, scene, drag)
    if not drag.changed then
        return
    end
    local bg = scene.bg
    bg.cx, bg.cy = Geo.Round(bg.cx), Geo.Round(bg.cy)
    board:Redraw()
    Fire(board, "onChanged")
end

-- The mouse ------------------------------------------------------------------------------------

-- Draws again only what a drag changes: the one item and the gold frame
-- around it. Every item drawn again on each frame the mouse moves is several
-- thousand widget calls in a busy scene. Everything is drawn when the map
-- itself is moved, and when the board marks what is "yours" (the glows are
-- shared between the items).
local function RedrawDragged(board, drag)
    local items = board.scene and board.scene.items
    local index = drag.index
    local item = index and type(items) == "table" and items[index]
    local slot = type(item) == "table" and board.slots[index]
    if not slot or drag.mode == "pan" or board.highlightMine or board:GetFrameLevel() ~= board.level then
        board:Redraw()
        return
    end
    local draw = Draw[item.k]
    BeginSlot(slot)
    if draw then
        draw(board, slot, item, board.px, false)
    end
    EndSlot(slot)
    slot.frame:Show()
    DrawSelection(board)
    board.hoverX = nil -- look again at what is under the mouse
end

local function DragStep(board)
    local drag, scene = board.drag, board.scene
    if not scene then
        board.drag = nil
        return
    end
    local x, y = CursorPoint(board)
    if not x or (x == drag.x and y == drag.y) then
        return
    end
    drag.x, drag.y = x, y
    local step = Step[drag.mode]
    if step and step(board, scene, drag, x, y) then
        RedrawDragged(board, drag)
    end
end

local function HideTip(board)
    if board.tipItem then
        board.tipItem = nil
        if GameTooltip then
            GameTooltip:Hide()
        end
    end
end

-- Who is in the groups of a group item right now, from the viewer's own raid.
local function ShowGroupTip(board, item)
    if not GameTooltip then
        return
    end
    local roster = type(T.Roster) == "function" and T.Roster() or nil
    local groups = type(roster) == "table" and type(roster.groups) == "table" and roster.groups or nil
    GameTooltip:SetOwner(board, "ANCHOR_CURSOR")
    if type(item.t) == "string" and item.t ~= "" then
        GameTooltip:AddLine(item.t, 1, 1, 1)
    end
    for _, group in ipairs(Geo.GroupList(item.g)) do
        GameTooltip:AddLine(Words("TAC_GROUP_N", GROUP_NUMBER or "Group %d"):format(group), GOLD[1], GOLD[2], GOLD[3])
        local members = groups and groups[group]
        if type(members) == "table" and #members > 0 then
            for _, member in ipairs(members) do
                local r, g, b = ClassColour(member.class)
                if member.online == false then
                    r, g, b = 0.5, 0.5, 0.5
                end
                -- An arrow in front of your own name.
                GameTooltip:AddLine((member.me and "> " or "  ") .. tostring(member.name or "?"), r, g, b)
            end
        else
            GameTooltip:AddLine("  " .. Words("TAC_GROUP_EMPTY", EMPTY or "Empty"), 0.5, 0.5, 0.5)
        end
    end
    if not (groups and roster.inGroup) then
        GameTooltip:AddLine(Words("TAC_GROUP_NONE", ERR_NOT_IN_RAID or "You are not in a raid group"), 0.5, 0.5, 0.5)
    end
    GameTooltip:Show()
end

-- A faint picture of what a placing tool would set down, under the mouse.
local function DrawGhost(board, x, y)
    local slot = board.ghost
    BeginSlot(slot)
    local tool = board.editable and not board.drag and board.tool
    local make = tool and x and Geo.OnBoard(x, y) and NewItem[tool.kind]
    local item = make and make(tool, Geo.ClampPoint(x, y))
    if item then
        Draw[item.k](board, slot, item, board.px, false)
    end
    EndSlot(slot)
end

-- What is under the mouse: the tooltip of a group, and the tool's ghost.
local function HoverStep(board)
    local x, y = CursorPoint(board)
    if not x or (x == board.hoverX and y == board.hoverY) then
        return
    end
    board.hoverX, board.hoverY = x, y
    local items = board.scene and board.scene.items
    local index = Geo.HitTest(items, x, y)
    local item = index and items[index]
    if item and item.k == "g" then
        if board.tipItem ~= item then
            board.tipItem = item
            ShowGroupTip(board, item)
        end
    else
        HideTip(board)
    end
    DrawGhost(board, x, y)
end

-- The rings of the pings, each growing and fading.
local function PingStep(board, elapsed)
    local slot, s, pings = board.pingSlot, board.px, board.pings
    BeginSlot(slot)
    for index = #pings, 1, -1 do
        local ping = pings[index]
        ping.age = ping.age + elapsed
        if ping.age > K.PING_TIME + 2 * K.PING_GAP then
            table.remove(pings, index)
        else
            for wave = 0, 2 do
                local life = (ping.age - wave * K.PING_GAP) / K.PING_TIME
                if life > 0 and life < 1 then
                    local size = (K.PING_FROM + (K.PING_TO - K.PING_FROM) * life) * 2 * s * K.RING / 1.25
                    Sprite(slot, "ARTWORK", 0, ART.ring, ping.x * s, ping.y * s, size, size, 1.00, 0.90, 0.35, 1 - life)
                end
            end
        end
    end
    EndSlot(slot)
end

local function OnUpdate(board, elapsed)
    if board.drag then
        DragStep(board)
    elseif board.inside then
        HoverStep(board)
    end
    if board.glowN > 0 then
        -- The glow breathes, so the eye finds it.
        board.clock = (board.clock + elapsed) % (2 * pi)
        local alpha = 0.72 + 0.28 * sin(board.clock * 4)
        for i = 1, board.glowN do
            board.glows[i]:SetAlpha(alpha)
        end
    end
    if board.pings[1] then
        PingStep(board, elapsed)
    end
end

local function OnMouseDown(board, button)
    local scene = board.scene
    local x, y = CursorPoint(board)
    if not scene or not x then
        return
    end
    if button == "RightButton" then
        if board.drag then
            CancelDrag(board) -- the way out of a drag that went wrong
        else
            Fire(board, "onRightClick", Geo.Round(x), Geo.Round(y), Geo.HitTest(scene.items, x, y))
        end
        return
    end
    if button ~= "LeftButton" or board.drag then
        return
    end
    HideTip(board)
    if not board.editable then
        board.drag = { mode = "click", sx = x, sy = y }
        return
    end
    if type(scene.items) ~= "table" then
        scene.items = {}
    end
    local tool = board.tool or board.selectTool
    local start = Start[tool.kind]
    if start then
        start(board, scene, tool, x, y)
        DrawGhost(board)
    end
end

local function OnMouseUp(board, button)
    local drag, scene = board.drag, board.scene
    if button ~= "LeftButton" or not drag then
        return
    end
    if scene then
        DragStep(board) -- to where the mouse is now
    end
    drag = board.drag
    board.drag = nil
    board.hoverX = nil
    local finish = drag and scene and Finish[drag.mode]
    if finish then
        finish(board, scene, drag, drag.x or drag.sx, drag.y or drag.sy)
    end
end

-- The wheel zooms a map background, towards what the mouse points at.
local function OnMouseWheel(board, delta)
    local scene, tool = board.scene, board.tool
    local bg = scene and scene.bg
    if not board.editable or not tool or tool.kind ~= "bg" or board.drag or type(bg) ~= "table" or bg.kind ~= "map" then
        return
    end
    local art = MapArt(bg.map)
    if not art then
        return
    end
    local zoom = bg.zoom or T.MIN_ZOOM
    local target = Geo.Clamp(zoom + delta * max(2, Geo.Round(zoom * 0.12)), T.MIN_ZOOM, T.MAX_ZOOM)
    if target == zoom then
        return
    end
    -- A turn of the wheel is many small steps: one undo for the lot.
    board:PushUndo("zoom")
    local x, y = CursorPoint(board)
    if x and not Geo.OnBoard(x, y) then
        x, y = nil, nil
    end
    Geo.ZoomMap(bg, art, target, x, y)
    board:Redraw()
    Fire(board, "onChanged")
end

local function OnEnter(board)
    board.inside = true
    board.hoverX = nil
end

local function OnLeave(board)
    board.inside = false
    HideTip(board)
    DrawGhost(board)
end

local function OnHide(board)
    CancelDrag(board)
    HideTip(board)
    board.inside = false -- no OnLeave comes for a frame that is hidden under the mouse
    Wipe(board.pings)
    BeginSlot(board.pingSlot)
    EndSlot(board.pingSlot)
end

-- The board -------------------------------------------------------------------------------------

-- The board's own functions; T.CreateBoard copies them onto the frame.
local Board = {}

-- The frames of the board in their order, from the board's own level up.
local function Stack(board)
    local level = board:GetFrameLevel()
    board.level = level
    board.back.frame:SetFrameLevel(level + 1)
    for index, slot in ipairs(board.slots) do
        slot.frame:SetFrameLevel(level + 1 + min(index, T.MAX_ITEMS))
    end
    board.ghost.frame:SetFrameLevel(level + T.MAX_ITEMS + 2)
    board.top.frame:SetFrameLevel(level + T.MAX_ITEMS + 3)
    board.pingSlot.frame:SetFrameLevel(level + T.MAX_ITEMS + 4)
end

-- The wheel is taken only while it does something, so a list the board lies
-- in still scrolls.
local function UpdateWheel(board)
    board:EnableMouseWheel(board.editable and board.tool ~= nil and board.tool.kind == "bg")
end

-- Sets the board's width in pixels; the height follows (16:10).
function Board:SetBoardWidth(width)
    width = max(1, tonumber(width) or 1)
    self.px = width / T.BOARD_W
    self:SetSize(width, width * T.BOARD_H / T.BOARD_W)
    self:Redraw()
end

-- Shows a scene. The table is used as it is: what is edited on the board is
-- changed in it. nil shows an empty board.
function Board:SetScene(scene)
    if scene == self.scene then
        self:Redraw()
        return
    end
    CancelDrag(self)
    HideTip(self)
    self.scene = scene
    Wipe(self.undo)
    local had = self.selected
    self.selected = nil
    self:Redraw()
    if had then
        Fire(self, "onSelect", nil)
    end
end

-- Draws everything again. Call it after changing the scene from outside (a
-- label, a colour, the room).
function Board:Redraw()
    if self:GetFrameLevel() ~= self.level then
        Stack(self)
    end
    local items = self.scene and self.scene.items
    if self.selected and not (type(items) == "table" and items[self.selected]) then
        self.selected = nil
    end
    DrawBackground(self)
    DrawItems(self)
    DrawSelection(self)
    self.hoverX = nil -- look again at what is under the mouse
end

-- Lets the board be edited with the mouse. Off (as it starts): a left click
-- calls onClick, and nothing can be changed.
function Board:SetEditable(on)
    on = on and true or false
    if on == self.editable then
        return
    end
    CancelDrag(self)
    self.editable = on
    UpdateWheel(self)
    if not on then
        self:Select(nil)
    end
    DrawGhost(self)
    self.hoverX = nil
end

-- The tool the left button uses while the board is editable:
--   nil or { kind = "select" }       click selects, drag moves; the ends of a
--                                    selected arrow or straight line, and the
--                                    edge of a selected area, can be dragged
--   { kind = "m", i =, c =, s =, t = }  each click places a marker
--   { kind = "p", n =, cl = }           a player
--   { kind = "g", g = { ... }, t = }    a group
--   { kind = "t", t =, c =, s = }       a text
--   { kind = "a", c =, s = }         drag from the tail to the head of an arrow
--   { kind = "l", c =, s = }         drag draws a line; with shift, a straight one
--   { kind = "z", c = }              drag from the middle of an area to its edge
--   { kind = "erase" }               click removes
--   { kind = "bg" }                  on a map: drag moves it, the wheel zooms
-- The table is read at each click, so the host may change it in place.
function Board:SetTool(tool)
    CancelDrag(self)
    self.tool = type(tool) == "table" and tool or nil
    UpdateWheel(self)
    self.hoverX = nil
    if not self.inside then
        DrawGhost(self)
    end
end

-- Selects the item at this place in the scene's list, or nothing (nil).
function Board:Select(index)
    local items = self.scene and self.scene.items
    if type(index) ~= "number" or type(items) ~= "table" or not items[index] then
        index = nil
    end
    if index == self.selected then
        return
    end
    self.selected = index
    DrawSelection(self)
    Fire(self, "onSelect", index)
end

-- The selected item: its place in the list and the item itself. nil when
-- nothing is selected.
function Board:GetSelected()
    local items = self.scene and self.scene.items
    local index = self.selected
    local item = index and type(items) == "table" and items[index]
    if item then
        return index, item
    end
    return nil
end

-- Removes the selected item. Returns whether there was one.
function Board:DeleteSelected()
    local index = self:GetSelected()
    if not index then
        return false
    end
    CancelDrag(self)
    self:PushUndo()
    RemoveItem(self, index)
    self:Redraw()
    Fire(self, "onChanged")
    return true
end

-- Moves the selected item to the end of the list (on top of the others) or
-- to its start (under them). Returns whether it moved.
local function Reorder(board, toTop)
    local index, item = board:GetSelected()
    local items = board.scene and board.scene.items
    local target = toTop and items and #items or 1
    if not index or index == target then
        return false
    end
    CancelDrag(board)
    board:PushUndo()
    table.remove(items, index)
    table.insert(items, target, item)
    board.selected = target
    board:Redraw()
    Fire(board, "onSelect", target)
    Fire(board, "onChanged")
    return true
end

function Board:RaiseSelected()
    return Reorder(self, true)
end

function Board:LowerSelected()
    return Reorder(self, false)
end

-- Remembers the scene's items and background as they are now, for Undo. The
-- board calls it before each of its own edits; a host calls it before it
-- changes the scene itself (a label, a colour, another room). With a tag,
-- calls with the same tag within a second count as one step.
function Board:PushUndo(tag)
    local scene = self.scene
    if not scene then
        return
    end
    local stack = self.undo
    local now = type(GetTime) == "function" and GetTime() or 0
    local last = stack[#stack]
    if tag and last and last.tag == tag and now - last.at < 1 then
        last.at = now
        return
    end
    stack[#stack + 1] = {
        items = Geo.Copy(type(scene.items) == "table" and scene.items or {}),
        bg = Geo.Copy(scene.bg), selected = self.selected, tag = tag, at = now,
    }
    if #stack > K.UNDO then
        table.remove(stack, 1)
    end
end

-- Takes back the last edit (the last 20 are remembered, until another scene
-- is shown). Returns whether there was one.
function Board:Undo()
    if self.drag and self.drag.pushed then
        CancelDrag(self) -- the edit under way is the last one
        return true
    end
    self.drag = nil
    if not TakeBack(self) then
        return false
    end
    Fire(self, "onChanged")
    return true
end

function Board:CanUndo()
    return self.undo[1] ~= nil
end

-- A gold glow around every item that is the player's own (T.IsMine), so each
-- raider sees at once where to stand.
function Board:SetHighlightMine(on)
    on = on and true or false
    if on ~= self.highlightMine then
        self.highlightMine = on
        self:Redraw()
    end
end

-- Rings spreading from a point of the board for a second or so: "look here".
function Board:Ping(x, y)
    if type(x) ~= "number" or type(y) ~= "number" then
        return
    end
    local pings = self.pings
    if #pings >= 8 then
        table.remove(pings, 1)
    end
    pings[#pings + 1] = { x = x, y = y, age = 0 }
end

-- Makes a board `width` pixels wide (and width * 625 / 1000 high) on parent.
--
-- Fields the host may set, each a function or nil:
--   board.onChanged(board)            after every edit
--   board.onSelect(board, index)      the selection changed (index or nil)
--   board.onClick(board, x, y)        a left click while not editable
--   board.onRightClick(board, x, y, index)  a right click; index is the item under it
--   board.onLimit(board, what)        an edit was refused: what = "items"
-- Fields to read:
--   board.mapMissing   after a redraw: the scene asks for a map this client
--                      has no picture of (a plain room is drawn instead)
--   board.levels       how many frame levels above its own the board uses
function T.CreateBoard(parent, width)
    local board = CreateFrame("Frame", nil, parent)
    for name, method in pairs(Board) do
        board[name] = method
    end
    board.px = 1
    board.level = board:GetFrameLevel()
    board.levels = T.MAX_ITEMS + 4
    board.editable = false
    board.highlightMine = false
    board.inside = false
    board.mapMissing = false
    board.selectTool = { kind = "select" }
    board.undo, board.pings, board.glows, board.slots = {}, {}, {}, {}
    board.glowN, board.clock = 0, 0

    board:SetClipsChildren(true)
    board.back = NewSlot(board)
    board.back.tiles, board.back.maps, board.back.nTiles = {}, {}, 0
    board.ghost = NewSlot(board)
    board.ghost.frame:SetAlpha(K.GHOST_ALPHA)
    board.top = NewSlot(board)
    board.pingSlot = NewSlot(board)
    Stack(board)

    board:SetScript("OnMouseDown", OnMouseDown)
    board:SetScript("OnMouseUp", OnMouseUp)
    board:SetScript("OnMouseWheel", OnMouseWheel)
    board:SetScript("OnEnter", OnEnter)
    board:SetScript("OnLeave", OnLeave)
    board:SetScript("OnUpdate", OnUpdate)
    board:SetScript("OnHide", OnHide)
    board:EnableMouse(true)
    board:EnableMouseWheel(false)

    board:SetBoardWidth(width)
    return board
end
