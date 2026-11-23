-- Dragonworld - Dungeons
-- Shows everyone in the guild who is online and has said they are open to
-- dungeons, with role (tank, healer, dps), which dungeons they want to do and
-- why (quest-run, loot, xp). From here you can whisper them or invite
-- them.
--
-- This is also where the window you get when you press "Dungeon" at the top of
-- the main window lives: there you pick role (one or two), dungeons and purpose,
-- and save. The status itself, the dungeon list and the sharing with the guild
-- are in Status.lua.
--
-- Leading a group ("Lead a group, need X"):
--   * A leader posts which dungeon, the group size, what the group has and
--     what it still needs (tanks, healers, DPS), with an optional note. The
--     post shows at the top of the tab for everyone, and members whose role
--     and level fit get a small green pop-up (DragonworldGroupToast) and the
--     green blink.
--   * The group size starts at the chosen dungeon's or raid's own size (its
--     size in DW.DUNGEONS: 5 for a dungeon, 40 for a raid) and can be set to
--     5, 10, 20, 25 or 40. In a group bigger than 5, "We have" is counts per
--     role (not counting the leader) instead of three ticks, and a full
--     party offers "Make raid". "Other group" (id 0, not in DW.DUNGEONS) is
--     a group for no particular dungeon: a world boss, farming, quests. It
--     starts at 5, and it fits members within 5 levels of the leader's level
--     (the roster's; any level when the roster does not say).
--   * "Ask to join" sends a request; the leader sees it under the post and in
--     a pop-up, with Invite (or "Make raid" for a raid post with a full
--     party) and "No thanks". Invite and conversion are attempts: the game
--     may still refuse, so the request goes back to "new" after 2 minutes if
--     the person has not joined.
--   * A post closes by itself when the group is full, when the leader goes
--     into the dungeon, or after an hour. People joining the group lower
--     what it needs.
--   * This is a guild-only layer. The game's own Group Finder is never
--     opened or touched from code; the form only has a tip about it.
--
-- Messages (name DragonworldGrp, fields separated by tab):
--   P key created updated dungeon have need size note [max haveCount]
--                       a post (or a newer version of it). need is "T,H,D"
--                       (counts), have a subset of "THD", size how many are
--                       in the group now. max is the group size chosen and
--                       haveCount ("T,H,D") the counts of "We have" in a
--                       group bigger than 5. They come after the note and
--                       are only sent when max is not the dungeon's own
--                       size or there are counts, so a copy that reads no
--                       further than the note (the first version of group
--                       posts) still works; without max a post has the
--                       dungeon's own size. Such a copy ignores "Other
--                       group" (dungeon 0) and dungeon posts needing over 4.
--   X key created time  the post is closed
--   J leaderKey created requesterKey role level
--                       asks to join a post as a role
--   R                   send me the open posts (once per session, at login)
-- key is the player's GUID ("Player-...") or "name:" .. name. A message is
-- only taken from the player it is about (the sender must be the roster
-- member with that key). The roster's online flag is not required: a
-- message arriving proves the sender is online.
--
-- Saved (per account, in this module's data): mine["Name-Realm"] = your own
-- open post (so it survives /reload; dropped after an hour), toast (false =
-- no pop-ups) and toastPos (where the pop-up was dragged to). Others' posts
-- and requests are kept in memory only.
--
-- All text is in Locales.lua (the names that start with DG_).

local ADDON_NAME, DW = ...
local L = DW.L

local MODULE_ID = "dungeons"

local COLUMNS, PER_COLUMN = 3, 13 -- the dungeons in the picker: three columns
local CHECK_ROW = 22
local ROW_HEIGHT = 44
local POST_ROW = 44     -- a group post at the top of the list
local REQUEST_ROW = 24  -- a request to join, under your own post
local HEADER_ROW = 20   -- "Groups looking for players" / "Up for dungeons"

-- Details -----------------------------------------------------------------------

local function MyLevel()
    local level = UnitLevel and UnitLevel("player")
    if type(level) == "number" and not DW.IsSecret(level) then
        return level
    end
    return 0
end

local function Fits(dungeon, level)
    return level >= dungeon.min and level <= dungeon.max
end

local function DungeonLabel(dungeon)
    if dungeon.other then
        return L.DG_OTHER_GROUP
    end
    local range = dungeon.min == dungeon.max and tostring(dungeon.min) or ("%d-%d"):format(dungeon.min, dungeon.max)
    if dungeon.raid then
        return L.DG_RAID_LABEL:format(dungeon.name, range)
    end
    return ("%s (%s)"):format(dungeon.name, range)
end

local function PurposesText(purposes)
    local parts = {}
    for _, purpose in ipairs(DW.PURPOSES) do
        if purposes and purposes[purpose.code] then
            parts[#parts + 1] = L[purpose.key]
        end
    end
    return #parts > 0 and table.concat(parts, ", ") or L.DG_ANY_REASON
end

-- The role icons of an entry, e.g. tank + dps. Empty if they have not chosen
-- any (older version of the addon).
local RoleIcons = DW.RoleIcons

-- The roles with icon and name, for tooltips: "[icon] Tank, [icon] Healer".
local RolesText = DW.RoleNames

local function CountOf(set)
    local count = 0
    for _ in pairs(set or {}) do
        count = count + 1
    end
    return count
end

local function MyWish()
    local code, entry = DW.GetMyStatus()
    if code == "D" and entry then
        return entry.dungeons
    end
    return nil
end

-- The dungeons in an entry, in a fixed order, with the ones you also want to
-- do in green.
local function DungeonsText(dungeons, separator)
    local mine = MyWish() or {}
    local parts = {}
    for _, dungeon in ipairs(DW.DUNGEONS) do
        if dungeons and dungeons[dungeon.id] then
            parts[#parts + 1] = mine[dungeon.id] and ("|cff40ff40" .. dungeon.name .. "|r") or dungeon.name
        end
    end
    return table.concat(parts, separator or ", ")
end

local function SharedCount(dungeons)
    local mine = MyWish() or {}
    local count = 0
    for id in pairs(dungeons or {}) do
        if mine[id] then
            count = count + 1
        end
    end
    return count
end

local function IsMe(member)
    local guid = DW.MyGUID()
    if guid and member.guid then
        return member.guid == guid
    end
    local name = DW.CharacterKey()
    return name ~= nil and DW.SameCharacter(member.key, name)
end

-- Whisper and invite: the game's own functions, the newer one first.
local function Whisper(name)
    DW.WhisperTo(name)
end

local function Invite(name)
    DW.InviteToGroup(name)
end

-- The picker ----------------------------------------------------------------------

local picker
local pickDungeons, pickPurposes, pickRoles = {}, {}, {}
local OpenTab -- opens the tab after saving

local function RefreshPicker()
    if not picker then
        return
    end
    local level = MyLevel()
    picker.title:SetText(L.DG_PICK_TITLE)
    picker.hint:SetText(L.DG_PICK_HINT:format(level))
    picker.roleLabel:SetText(L.DG_ROLE)
    -- With two roles chosen, the third can't be picked until one is removed.
    local full = CountOf(pickRoles) >= DW.MAX_ROLES
    for _, check in ipairs(picker.roleChecks) do
        local chosen = pickRoles[check.role.code] and true or false
        check.label:SetText(DW.RoleIcon(check.role, 16) .. " " .. L[check.role.key])
        check:SetChecked(chosen)
        check:SetEnabled(chosen or not full)
        if chosen or not full then
            check.label:SetTextColor(1, 1, 1)
        else
            check.label:SetTextColor(0.55, 0.55, 0.55)
        end
    end
    picker.whyLabel:SetText(L.DG_WHY)
    for _, check in ipairs(picker.purposeChecks) do
        check.label:SetText(L[check.purpose.key])
        check:SetChecked(pickPurposes[check.purpose.code] and true or false)
    end
    for _, check in ipairs(picker.dungeonChecks) do
        local dungeon = check.dungeon
        check.label:SetText(DungeonLabel(dungeon))
        if Fits(dungeon, level) then
            check.label:SetTextColor(1, 1, 1)
        else
            check.label:SetTextColor(0.55, 0.55, 0.55)
        end
        check:SetChecked(pickDungeons[dungeon.id] and true or false)
    end
    picker.fitting.label:SetText(L.DG_PICK_FITTING)
    picker.clear.label:SetText(L.DG_PICK_CLEAR)
    picker.save.label:SetText(L.DG_PICK_SAVE)
    picker.cancel.label:SetText(L.DG_PICK_CANCEL)
    picker.off.label:SetText(L.DG_PICK_OFF)
    picker.off:SetShown(DW.GetMyStatus() == "D")
end

local function CreatePicker(window)
    local p = CreateFrame("Frame", "DragonworldDungeonPicker", window, "BackdropTemplate")
    p:SetPoint("TOPLEFT", 14, -92)
    p:SetSize(window:GetWidth() - 28, window:GetHeight() - 92 - 14)
    p:SetFrameStrata("DIALOG")
    p:EnableMouse(true)
    p:SetBackdrop(DW.PANEL_BACKDROP)
    p:SetBackdropColor(0.05, 0.05, 0.07, 1)
    p:SetBackdropBorderColor(1.00, 0.82, 0.00, 1)
    -- Fully opaque background inside the border, so what is behind doesn't show through.
    p.solid = p:CreateTexture(nil, "BACKGROUND")
    p.solid:SetPoint("TOPLEFT", 3, -3)
    p.solid:SetPoint("BOTTOMRIGHT", -3, 3)
    p.solid:SetColorTexture(0.05, 0.05, 0.07, 1)
    local width = p:GetWidth()

    p.title = p:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
    p.title:SetPoint("TOPLEFT", 16, -12)

    p.hint = p:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    p.hint:SetPoint("TOPLEFT", 16, -36)
    p.hint:SetWidth(width - 32)
    p.hint:SetJustifyH("LEFT")

    -- Role: tank, healer, dps. One or two.
    p.roleLabel = p:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    p.roleLabel:SetPoint("TOPLEFT", 16, -62)
    p.roleChecks = {}
    for index, role in ipairs(DW.ROLES) do
        local check = CreateFrame("CheckButton", nil, p, "UICheckButtonTemplate")
        check:SetSize(22, 22)
        check:SetPoint("TOPLEFT", 76 + (index - 1) * 100, -58)
        check.role = role
        check.label = check:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
        check.label:SetPoint("LEFT", check, "RIGHT", 2, 0)
        check:SetScript("OnClick", function(self)
            if self:GetChecked() and CountOf(pickRoles) < DW.MAX_ROLES then
                pickRoles[self.role.code] = true
            else
                pickRoles[self.role.code] = nil
            end
            p.error:SetText("")
            RefreshPicker()
        end)
        p.roleChecks[index] = check
    end

    -- Why: quest-run, loot, xp. You can tick several.
    p.whyLabel = p:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    p.whyLabel:SetPoint("TOPLEFT", 400, -62)
    p.purposeChecks = {}
    for index, purpose in ipairs(DW.PURPOSES) do
        local check = CreateFrame("CheckButton", nil, p, "UICheckButtonTemplate")
        check:SetSize(22, 22)
        check:SetPoint("TOPLEFT", 474 + (index - 1) * 110, -58)
        check.purpose = purpose
        check.label = check:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
        check.label:SetPoint("LEFT", check, "RIGHT", 2, 0)
        check:SetScript("OnClick", function(self)
            pickPurposes[self.purpose.code] = self:GetChecked() and true or nil
        end)
        p.purposeChecks[index] = check
    end

    -- The dungeons, in three columns.
    p.dungeonChecks = {}
    local columnWidth = math.floor((width - 32) / COLUMNS)
    for index, dungeon in ipairs(DW.DUNGEONS) do
        local column = math.floor((index - 1) / PER_COLUMN)
        local line = (index - 1) % PER_COLUMN
        local check = CreateFrame("CheckButton", nil, p, "UICheckButtonTemplate")
        check:SetSize(20, 20)
        check:SetPoint("TOPLEFT", 16 + column * columnWidth, -92 - line * CHECK_ROW)
        check.dungeon = dungeon
        check.label = check:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
        check.label:SetPoint("LEFT", check, "RIGHT", 2, 0)
        check.label:SetWidth(columnWidth - 28)
        check.label:SetJustifyH("LEFT")
        check.label:SetWordWrap(false)
        check:SetScript("OnClick", function(self)
            pickDungeons[self.dungeon.id] = self:GetChecked() and true or nil
            p.error:SetText("")
        end)
        p.dungeonChecks[index] = check
    end

    p.error = p:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    p.error:SetPoint("BOTTOMLEFT", 16, 46)
    p.error:SetTextColor(1.00, 0.35, 0.30)

    -- The buttons at the bottom.
    p.fitting = DW.CreateChip(p, 190, 28)
    p.fitting:SetPoint("BOTTOMLEFT", 16, 12)
    p.fitting.label:SetJustifyH("CENTER")
    p.fitting:SetScript("OnClick", function()
        local level = MyLevel()
        for _, dungeon in ipairs(DW.DUNGEONS) do
            if Fits(dungeon, level) then
                pickDungeons[dungeon.id] = true
            end
        end
        p.error:SetText("")
        RefreshPicker()
    end)

    p.clear = DW.CreateChip(p, 110, 28)
    p.clear:SetPoint("LEFT", p.fitting, "RIGHT", 8, 0)
    p.clear.label:SetJustifyH("CENTER")
    p.clear:SetScript("OnClick", function()
        pickDungeons = {}
        RefreshPicker()
    end)

    p.cancel = DW.CreateChip(p, 100, 28)
    p.cancel:SetPoint("BOTTOMRIGHT", -16, 12)
    p.cancel.label:SetJustifyH("CENTER")
    p.cancel:SetScript("OnClick", function()
        p:Hide()
    end)

    p.save = DW.CreateButton(p, 130, 28, "gold")
    p.save:SetPoint("RIGHT", p.cancel, "LEFT", -8, 0)
    p.save:SetScript("OnClick", function()
        if not next(pickDungeons) then
            p.error:SetText(L.DG_NEED_DUNGEON)
            return
        end
        if not next(pickRoles) then
            p.error:SetText(L.DG_NEED_ROLE)
            return
        end
        DW.SetMyStatus("D", { dungeons = pickDungeons, purposes = pickPurposes, roles = pickRoles })
        p:Hide()
        if OpenTab then
            OpenTab()
        end
    end)

    -- Only when you are already open to dungeons.
    p.off = DW.CreateButton(p, 150, 28, "red")
    p.off:SetPoint("RIGHT", p.save, "LEFT", -8, 0)
    p.off:SetScript("OnClick", function()
        DW.SetMyStatus(nil)
        p:Hide()
    end)

    return p
end

-- Opens the picker, with what you chose last already ticked.
function DW.OpenDungeonPicker()
    local window = _G.DragonworldFrame
    if not window or not DW.IsMember() then
        return
    end
    if not picker then
        picker = CreatePicker(window)
    end
    -- Only one such window on top at a time (MainWindow.lua's overlay registry).
    DW.HideOverlays("DragonworldDungeonPicker")
    local _, entry = DW.GetMyStatus()
    pickDungeons, pickPurposes, pickRoles = {}, {}, {}
    for id in pairs(entry and entry.dungeons or {}) do
        pickDungeons[id] = true
    end
    for code in pairs(entry and entry.purposes or {}) do
        pickPurposes[code] = true
    end
    for code in pairs(entry and entry.roles or {}) do
        pickRoles[code] = true
    end
    -- First time: the role you chose in your profile (Roster).
    if not next(pickRoles) and DW.GetMyRoles then
        for code in pairs(DW.GetMyRoles()) do
            pickRoles[code] = true
        end
    end
    picker.error:SetText("")
    RefreshPicker()
    picker:Show()
end

-- Leading a group: the engine ---------------------------------------------------------

-- Everything about group posts lives in this one table (the file would
-- otherwise need too many local names).
local G = {
    PREFIX = "DragonworldGrp",
    SEP = "\t",
    LIFETIME = 3600,        -- a post closes after an hour
    ALIVE_FOR = 3660,       -- others' posts count as open a minute longer (clocks differ)
    RECEIVE_MAX_AGE = 3900, -- an arriving post older than this is refused
    FUTURE = 300,           -- times at most this far ahead are accepted
    HELLO_DELAY = 25,
    POST_DEBOUNCE = 3.2,    -- automatic changes are sent at most this often
    TICK = 30,              -- the post timer
    ASK_AGAIN = 120,        -- "Asked" for this long, then "Ask again"
    INVITE_RESET = 120,     -- an invite not taken goes back to "new" after this long
    ONLINE_GRACE = 120,     -- a message proves the sender was online this long
    ROSTER_EVERY = 15,      -- ask the game for a fresh roster at most this often
    TOAST_MAX_AGE = 900,    -- pop-ups only for posts at most 15 min old
    TOAST_LEADER_GAP = 600, -- the same leader at most once per 10 min
    TOAST_SECONDS = 25,
    TOAST_FADE = 0.5,
    QUEUE_MAX = 3,
    MAX_REQUESTS = 20,
    NOTE_BYTES = 80,        -- the note in the form
    NOTE_RECEIVE = 160,     -- the longest note taken from a message
    SLACK = 2,              -- levels of leeway on a dungeon's range
    OTHER_SLACK = 5,        -- "Other group": levels either side of the leader's
    SIZES = { 5, 10, 20, 25, 40 }, -- the group sizes the form offers
    -- "Other group": no particular dungeon (a world boss, farming, quests).
    -- Not in DW.DUNGEONS, so it is not in the "open for dungeons" picker.
    OTHER = { id = 0, other = true },

    posts = {},         -- [leaderKey] = post (others' open posts)
    closedAt = {},      -- [leaderKey] = time of the last X
    requests = {},      -- [requesterKey] = request to join your post
    asked = {},         -- [leaderKey .. ":" .. created] = GetTime() of our J
    toastedPost = {},   -- [leaderKey .. ":" .. created] = true
    toastedLeader = {}, -- [leaderKey] = GetTime() of the last pop-up
    queue = {},         -- pop-ups waiting
}
G.Send = DW.CreateSender(G.PREFIX)

-- Truncate/Clean as in Events.lua: cut at a whole letter, and remove line
-- breaks, tabs and "|" (colours and links).
function G.Truncate(text, maxBytes)
    if #text <= maxBytes then
        return text
    end
    text = text:sub(1, maxBytes)
    while #text > 0 and text:byte(-1) >= 128 and text:byte(-1) < 192 do
        text = text:sub(1, -2)
    end
    if #text > 0 and text:byte(-1) >= 192 then
        text = text:sub(1, -2)
    end
    return text
end

function G.Clean(text, maxBytes)
    text = tostring(text or "")
    text = text:gsub("[%c|]", " ")
    text = text:gsub("^%s+", "")
    text = text:gsub("%s+$", "")
    return G.Truncate(text, maxBytes)
end

function G.Now()
    return DW.ServerNow()
end

-- The key a player is recognized by, as in Status.lua.
function G.KeyOf(guid, name)
    if type(guid) == "string" and guid:find("^Player%-") then
        return guid
    end
    return "name:" .. DW.NameKey(name)
end

function G.MyKey()
    local _, name = DW.CharacterKey()
    if not name then
        return nil
    end
    return G.KeyOf(DW.MyGUID(), name)
end

-- A dungeon by id, "Other group" (0) included.
function G.Dungeon(id)
    if id == G.OTHER.id then
        return G.OTHER
    end
    return DW.DUNGEON_BY_ID[id]
end

-- The usual group size of a dungeon or raid: its size in DW.DUNGEONS, else 5
-- for a dungeon and 40 for a raid. "Other group" starts at 5.
function G.MaxSize(dungeon)
    if not dungeon then
        return 5
    end
    return dungeon.size or (dungeon.raid and 40) or 5
end

-- A group size from a message or saved data, or nil: a whole number 2..40.
function G.ValidSize(value)
    if type(value) == "number" and value == math.floor(value) and value >= 2 and value <= 40 then
        return value
    end
    return nil
end

-- The group size of a post (saved or received): the size chosen, else the
-- dungeon's usual size (posts that do not say, and posts saved before).
function G.SizeOf(entry)
    return G.ValidSize(entry.max) or G.MaxSize(G.Dungeon(entry.dungeon))
end

-- One role at most this many: the size less the leader (4 in a group of 5).
function G.RoleCap(max)
    return math.max(0, (max or 5) - 1)
end

-- The name of a post's dungeon in lines, pop-ups and chat. With another size
-- than the usual one the size follows, "Molten Core (20)"; "Other group"
-- always has it: "Other group (10)".
function G.Title(dungeon, max)
    if not dungeon then
        return "?"
    end
    max = max or G.MaxSize(dungeon)
    if dungeon.other then
        return ("%s (%d)"):format(L.DG_OTHER_GROUP, max)
    end
    if max ~= G.MaxSize(dungeon) then
        return ("%s (%d)"):format(dungeon.name, max)
    end
    return dungeon.name
end

-- Whether a dungeon fits a level: its range with 2 levels of leeway; a raid
-- needs its own level. "Other group" fits everyone here (in the form's menu);
-- for others' posts G.PostLevelFits looks at the leader's level.
function G.LevelFits(dungeon, level)
    if not dungeon then
        return false
    end
    if dungeon.other then
        return true
    end
    if dungeon.raid then
        return level >= dungeon.min
    end
    return level >= dungeon.min - G.SLACK and level <= dungeon.max + G.SLACK
end

-- Whether a post fits your level. "Other group" has no range of its own: it
-- fits within 5 levels of the leader's level in the roster, and any level
-- when the roster does not say.
function G.PostLevelFits(post, level, index)
    local dungeon = G.Dungeon(post.dungeon)
    if dungeon and dungeon.other then
        local leader = G.MemberOf(post.key, index)
        local theirs = leader and tonumber(leader.level)
        if not theirs or theirs <= 0 then
            return true
        end
        return math.abs(level - theirs) <= G.OTHER_SLACK
    end
    return G.LevelFits(dungeon, level)
end

-- "0,1,3" -> { T = 0, H = 1, D = 3 }, or nil if it is not three counts 0..39.
-- Also used for the counts of "We have" in a group bigger than 5.
function G.ParseNeed(text)
    local t, h, d = tostring(text or ""):match("^(%d+),(%d+),(%d+)$")
    t, h, d = tonumber(t), tonumber(h), tonumber(d)
    if not (t and h and d) or t > 39 or h > 39 or d > 39 then
        return nil
    end
    return { T = t, H = h, D = d }
end

function G.NeedText(need)
    return ("%d,%d,%d"):format(need.T or 0, need.H or 0, need.D or 0)
end

function G.NeedSum(need)
    return (need.T or 0) + (need.H or 0) + (need.D or 0)
end

-- "TH" -> { T = true, H = true }.
function G.HaveSet(text)
    local set = {}
    for _, role in ipairs(DW.ROLES) do
        if tostring(text or ""):find(role.code, 1, true) then
            set[role.code] = true
        end
    end
    return set
end

function G.HaveText(set)
    return DW.RolesToText(set)
end

-- { T = 2, H = 0, D = 3 } -> { T = true, D = true }: the roles with a count.
function G.CountSet(counts)
    local set = {}
    for _, role in ipairs(DW.ROLES) do
        if (counts and counts[role.code] or 0) > 0 then
            set[role.code] = true
        end
    end
    return set
end

-- What a post says the group has, with icons ("has" in the post line), or
-- with names (the tooltip). Counts in a group bigger than 5, else the roles.
-- Empty when it says nothing.
function G.HasText(post, names)
    if post.haveCount then
        if G.NeedSum(post.haveCount) == 0 then
            return ""
        end
        return names and G.NeedNames(post.haveCount, true) or G.NeedIcons(post.haveCount)
    end
    if not next(post.have) then
        return ""
    end
    return names and DW.RoleNames(post.have) or DW.RoleIcons(post.have)
end

-- What the group needs as text: "2 [icon]" per role ("2 [icon] DPS" with
-- names), or plain "1 Healer, 3 DPS" for guild chat.
function G.NeedIcons(need, size)
    local parts = {}
    for _, role in ipairs(DW.ROLES) do
        local count = need[role.code] or 0
        if count > 0 then
            parts[#parts + 1] = ("%d %s"):format(count, DW.RoleIcon(role, size))
        end
    end
    return table.concat(parts, " ")
end

function G.NeedNames(need, icons)
    local parts = {}
    for _, role in ipairs(DW.ROLES) do
        local count = need[role.code] or 0
        if count > 0 then
            if icons then
                parts[#parts + 1] = ("%d %s %s"):format(count, DW.RoleIcon(role), L[role.key])
            else
                parts[#parts + 1] = ("%d %s"):format(count, L[role.key])
            end
        end
    end
    return table.concat(parts, ", ")
end

function G.RoleText(code, size)
    local role = nil
    for _, r in ipairs(DW.ROLES) do
        if r.code == code then
            role = r
        end
    end
    if not role then
        return tostring(code)
    end
    return DW.RoleIcon(role, size) .. " " .. L[role.key]
end

function G.RoleName(code)
    for _, role in ipairs(DW.ROLES) do
        if role.code == code then
            return L[role.key]
        end
    end
    return tostring(code)
end

-- Your roles for group posts: those of your "open for dungeons" status when
-- it is on, otherwise the role in your profile.
function G.MyRoles()
    local code, entry = DW.GetMyStatus()
    if code == "D" and entry then
        return entry.roles or {}
    end
    return (DW.GetMyRoles and DW.GetMyRoles()) or {}
end

local function PlainValue(fn, ...)
    if type(fn) ~= "function" then
        return nil
    end
    local ok, value = pcall(fn, ...)
    if ok and not DW.IsSecret(value) then
        return value
    end
    return nil
end

function G.InRaid()
    return PlainValue(IsInRaid) == true
end

function G.InCombat()
    return PlainValue(InCombatLockdown) == true
end

-- The GUIDs of the others in your group (secret ones are skipped).
function G.GroupGUIDs()
    local set = {}
    for _, unit in ipairs(DW.GroupUnits()) do
        local guid = PlainValue(UnitGUID, unit)
        if type(guid) == "string" and guid ~= "" then
            set[guid] = true
        end
    end
    return set
end

-- The roster as two lookups: by GUID and by "name:" key.
function G.Index()
    local index = { byGuid = {}, byName = {} }
    for _, member in ipairs(DW.ReadGuildRoster()) do
        if member.guid then
            index.byGuid[member.guid] = member
        end
        index.byName["name:" .. DW.NameKey(member.key)] = member
    end
    return index
end

-- The roster member a key is about, or nil.
function G.MemberOf(key, index)
    if type(key) ~= "string" then
        return nil
    end
    index = index or G.Index()
    if key:find("^Player%-") then
        return index.byGuid[key]
    end
    return index.byName[key]
end

function G.NameOf(key, index)
    local member = G.MemberOf(key, index)
    if member then
        return member.name
    end
    return (tostring(key):gsub("^name:", ""))
end

-- The member a message is about, if the game says that member sent it.
-- The roster's online flag is not required: it lags behind logins, and a
-- message arriving proves the sender is online. If the roster says offline,
-- a fresh roster is asked for (at most every 15 s).
function G.SenderIs(key, sender)
    if type(sender) ~= "string" then
        return nil
    end
    local member = G.MemberOf(key)
    if not member or not DW.SameCharacter(member.key, sender) then
        return nil
    end
    if not member.online and C_GuildInfo and type(C_GuildInfo.GuildRoster) == "function" then
        local now = GetTime()
        if not G.rosterAskedAt or now - G.rosterAskedAt >= G.ROSTER_EVERY then
            G.rosterAskedAt = now
            pcall(C_GuildInfo.GuildRoster)
        end
    end
    return member
end

-- Your own post --------------------------------------------------------------------

function G.ValidSaved(entry)
    return type(entry) == "table" and type(entry.created) == "number" and type(entry.updated) == "number"
        and type(entry.dungeon) == "number" and G.Dungeon(entry.dungeon) ~= nil and G.ParseNeed(entry.need) ~= nil
end

-- Your saved post (this character), or nil, also when its hour is up.
function G.Saved()
    local key = DW.CharacterKey()
    local db = G.db
    if not key or type(db) ~= "table" or type(db.mine) ~= "table" then
        return nil
    end
    local entry = db.mine[key]
    if not G.ValidSaved(entry) then
        return nil
    end
    return entry
end

-- Your open post (this character), or nil. A post older than an hour is not
-- open, even before the timer or the hello has removed it.
function G.Mine()
    local entry = G.Saved()
    if not entry or G.Now() - entry.created >= G.LIFETIME then
        return nil
    end
    return entry
end

-- Your post in the same form as others' posts.
function G.MyPost()
    local entry = G.Mine()
    if not entry then
        return nil
    end
    return {
        key = G.MyKey(), created = entry.created, updated = entry.updated, dungeon = entry.dungeon,
        have = G.HaveSet(entry.have), need = G.ParseNeed(entry.need), size = entry.size or 1,
        max = G.SizeOf(entry), haveCount = entry.haveCount and G.ParseNeed(entry.haveCount) or nil,
        note = entry.note or "", mine = true,
    }
end

function G.SendPost()
    local entry, key = G.Mine(), G.MyKey()
    if not entry or not key then
        return
    end
    local fields = {
        "P", key, ("%d"):format(entry.created), ("%d"):format(entry.updated), tostring(entry.dungeon),
        entry.have or "", entry.need, ("%d"):format(entry.size or 1), entry.note or "",
    }
    -- The group size and the counts go after the note, where the first
    -- version of group posts does not look. A post with the dungeon's usual
    -- size and no counts stays exactly as that version sends it.
    local max = G.SizeOf(entry)
    local haveCount = entry.haveCount and G.ParseNeed(entry.haveCount)
    if max ~= G.MaxSize(G.Dungeon(entry.dungeon)) or haveCount then
        fields[10] = ("%d"):format(max)
        fields[11] = haveCount and G.NeedText(haveCount) or nil
    end
    G.Send(table.concat(fields, G.SEP))
end

-- Automatic changes (people joining): one P after 3.2 s, however many changes.
function G.QueuePost()
    if G.postQueued or not (C_Timer and C_Timer.After) then
        return
    end
    G.postQueued = true
    C_Timer.After(G.POST_DEBOUNCE, function()
        G.postQueued = false
        if DW.IsMember() and G.Mine() then
            G.SendPost()
        end
    end)
end

-- Something changed: redraw what shows it, and look for what is new.
function G.Changed()
    if G.RefreshPanel then
        G.RefreshPanel()
    end
    if G.RefreshToast then
        G.RefreshToast()
    end
    if DW.QueueAlertRefresh then
        DW.QueueAlertRefresh()
    end
end

-- Closes your post. reason: "full", "instance", "time" or "manual".
function G.Close(reason)
    local entry, key = G.Saved(), G.MyKey()
    if not entry then
        return
    end
    if key then
        G.Send(table.concat({ "X", key, ("%d"):format(entry.created), ("%d"):format(G.Now()) }, G.SEP))
    end
    G.db.mine[DW.CharacterKey()] = nil
    G.requests = {}
    if reason == "full" then
        DW.Print(L.DG_POST_CLOSED_FULL)
    elseif reason == "instance" then
        DW.Print(L.DG_POST_CLOSED_INSTANCE)
    elseif reason == "time" then
        DW.Print(L.DG_POST_CLOSED_TIME)
    end
    if G.form and G.form:IsShown() then
        G.form:Hide()
    end
    G.Changed()
end

-- The post timer: every 30 s while you have a post; closes it after an hour.
function G.StartTick()
    if G.tickScheduled or not (C_Timer and C_Timer.After) or not G.Saved() then
        return
    end
    G.tickScheduled = true
    C_Timer.After(G.TICK, function()
        G.tickScheduled = false
        local entry = G.Saved()
        if not entry then
            return
        end
        if G.Now() - entry.created >= G.LIFETIME then
            G.Close("time")
            return
        end
        if G.RefreshPanel then
            G.RefreshPanel()
        end
        G.StartTick()
    end)
end

-- Saves and sends your post from the form's values (new or changed).
function G.SavePost(values, sayInChat)
    local charKey = DW.CharacterKey()
    if not charKey or type(G.db) ~= "table" then
        return false
    end
    local entry = G.Mine()
    local isNew = entry == nil
    local now = G.Now()
    if isNew then
        entry = { created = now, updated = now }
        G.requests = {}
    else
        entry.updated = math.max(now, entry.updated + 1)
    end
    entry.dungeon = values.dungeon
    entry.max = G.ValidSize(values.max) or G.MaxSize(G.Dungeon(values.dungeon))
    if entry.max > 5 then
        -- Counts per role; have keeps the roles with a count, for a copy
        -- that does not read the counts.
        entry.haveCount = G.NeedText(values.haveCount or {})
        entry.have = G.HaveText(G.CountSet(values.haveCount))
    else
        entry.haveCount = nil
        entry.have = G.HaveText(values.have)
    end
    entry.need = G.NeedText(values.need)
    entry.note = G.Clean(values.note, G.NOTE_BYTES)
    entry.size = DW.GroupSize()
    entry.known = G.GroupGUIDs()
    -- Those in the group now are already part of what you said you need.
    local counted = (not isNew and type(entry.counted) == "table") and entry.counted or {}
    for guid in pairs(entry.known) do
        counted[guid] = true
    end
    entry.counted = counted
    G.db.mine =type(G.db.mine) == "table" and G.db.mine or {}
    G.db.mine[charKey] = entry
    G.SendPost()
    -- Leading a group: you are no longer "open for dungeons" yourself.
    if DW.GetMyStatus() == "D" then
        DW.SetMyStatus(nil)
    end
    if isNew and sayInChat then
        local dungeon = G.Dungeon(entry.dungeon)
        DW.SendChat(L.DG_CHAT_LFM:format(G.Title(dungeon, entry.max), G.NeedNames(values.need, false)), "GUILD")
    end
    G.StartTick()
    G.Changed()
    return true
end

-- The group changed: people who joined lower what is needed; a full group
-- closes the post. Leaving the group does not close it.
function G.OnGroupChanged()
    local entry = G.Mine()
    if not entry then
        G.Changed()
        return
    end
    local need = G.ParseNeed(entry.need)
    -- In a group bigger than 5, someone joining for a needed role also
    -- counts as one more the group has.
    local haveCount = entry.haveCount and G.ParseNeed(entry.haveCount)
    local known = type(entry.known) == "table" and entry.known or {}
    -- Everyone who has been in the group while this post was open. A GUID in
    -- it never lowers a need again: not when someone leaves and comes back,
    -- and not when a GUID could not be read for one update.
    local counted = entry.counted
    if type(counted) ~= "table" then
        counted = {}
        for guid in pairs(known) do
            counted[guid] = true
        end
    end
    local current = G.GroupGUIDs()
    local readable = 0
    for _ in pairs(current) do
        readable = readable + 1
    end
    if readable < DW.GroupSize() - 1 then
        -- Some GUIDs are hidden: nobody we knew counts as gone this time.
        for guid in pairs(known) do
            current[guid] = true
        end
    end
    local changed = false
    local index
    for guid in pairs(current) do
        if not known[guid] then
            changed = true
        end
        local request = G.requests[guid]
        if not counted[guid] then
            counted[guid] = true
            local role
            if request then
                if request.state ~= "joined" then
                    role = request.role
                end
            else
                -- No request: their role, if exactly one of them is needed.
                index = index or G.Index()
                local member = index.byGuid[guid]
                local roles
                if member then
                    local code, status = DW.StatusOf(member)
                    roles = (code == "D" and status and status.roles) or (DW.RolesOf and DW.RolesOf(member))
                end
                local match, count = nil, 0
                for _, r in ipairs(DW.ROLES) do
                    if roles and roles[r.code] and (need[r.code] or 0) > 0 then
                        match, count = r.code, count + 1
                    end
                end
                if count == 1 then
                    role = match
                end
            end
            if role and (need[role] or 0) > 0 then
                need[role] = need[role] - 1
                if haveCount then
                    haveCount[role] = math.min(39, (haveCount[role] or 0) + 1)
                end
            end
        end
        -- In the group: their request is done (also when already counted).
        if request then
            request.state = "joined"
        end
    end
    for guid in pairs(known) do
        if not current[guid] then
            changed = true
        end
    end
    local size = DW.GroupSize()
    if size ~= entry.size then
        changed = true
    end
    entry.known = current
    entry.counted = counted
    entry.size = size
    entry.need = G.NeedText(need)
    if haveCount then
        entry.haveCount = G.NeedText(haveCount)
        entry.have = G.HaveText(G.CountSet(haveCount))
    end
    if size >= G.SizeOf(entry) or G.NeedSum(need) == 0 then
        G.Close("full")
        return
    end
    if changed then
        entry.updated = math.max(G.Now(), entry.updated + 1)
        G.QueuePost()
    end
    G.Changed()
end

-- Others' posts ---------------------------------------------------------------------

-- Is a post still open: not closed, the leader online (roster, or a message
-- in the last 2 minutes), and not older than an hour.
function G.Alive(post, index)
    if not post then
        return false
    end
    if post.mine then
        return G.Mine() ~= nil
    end
    if G.Now() - post.created > G.ALIVE_FOR then
        return false
    end
    local member = G.MemberOf(post.key, index)
    if member and member.online then
        return true
    end
    return post.seenOnlineAt ~= nil and G.Now() - post.seenOnlineAt <= G.ONLINE_GRACE
end

-- Does a post fit you: open, not yours, your level, a role it needs, not
-- "Do not disturb", no post of your own, not in an instance, a group with
-- room, and not already in that group.
function G.Fits(post, index)
    if not post or post.mine or post.key == G.MyKey() or not G.Alive(post, index) then
        return false
    end
    if not G.PostLevelFits(post, MyLevel(), index) then
        return false
    end
    local roles, match = G.MyRoles(), false
    for _, role in ipairs(DW.ROLES) do
        if roles[role.code] and (post.need[role.code] or 0) > 0 then
            match = true
        end
    end
    if not match or DW.GetMyStatus() == "C" or G.Mine() or DW.InDungeonInstance() or DW.GroupSize() >= 5 then
        return false
    end
    return not DW.GroupMemberKeys()[post.key]
end

-- The open posts, others' and yours: { { post, member, fits }, ... }.
function G.AlivePosts()
    local list, index = {}, G.Index()
    local mine = G.MyPost()
    if mine then
        list[#list + 1] = { post = mine, member = G.MemberOf(mine.key, index), fits = false }
    end
    for _, post in pairs(G.posts) do
        if G.Alive(post, index) then
            list[#list + 1] = { post = post, member = G.MemberOf(post.key, index), fits = G.Fits(post, index) }
        end
    end
    table.sort(list, function(a, b)
        if (a.post.mine or false) ~= (b.post.mine or false) then
            return a.post.mine or false
        end
        if a.fits ~= b.fits then
            return a.fits
        end
        if a.post.created ~= b.post.created then
            return a.post.created > b.post.created
        end
        return a.post.key < b.post.key
    end)
    return list
end

-- For the blink: posts that fit you, made after since.
function G.FittingPosts(since)
    local list, index = {}, G.Index()
    for _, post in pairs(G.posts) do
        if post.created > since and G.Fits(post, index) then
            list[#list + 1] = post
        end
    end
    table.sort(list, function(a, b) return a.created > b.created end)
    return list
end

-- Requests to join your post that came after since and are not answered.
function G.NewRequests(since)
    local list = {}
    if not G.Mine() then
        return list
    end
    for _, request in pairs(G.requests) do
        if G.RequestState(request) == "new" and request.at > since then
            list[#list + 1] = request
        end
    end
    table.sort(list, function(a, b) return a.at > b.at end)
    return list
end

-- A request's state; an invite not taken within 2 minutes goes back to "new".
function G.RequestState(request)
    if request.state == "invited" and GetTime() - (request.invitedAt or 0) >= G.INVITE_RESET then
        request.state = "new"
    end
    return request.state
end

-- Asking to join ----------------------------------------------------------------------

-- The roles you can ask as: the needed roles you have (tank, healer, dps
-- order). With no role chosen at all, every needed role. Second value: true
-- when you have roles but none is needed.
function G.AskChoices(post)
    local mine, matches, all = G.MyRoles(), {}, {}
    for _, role in ipairs(DW.ROLES) do
        if (post.need[role.code] or 0) > 0 then
            all[#all + 1] = role.code
            if mine[role.code] then
                matches[#matches + 1] = role.code
            end
        end
    end
    if #matches > 0 then
        return matches, false
    end
    if not next(mine) then
        return all, false
    end
    return {}, true
end

-- "ask", "asked" (within 2 minutes), "again" or "norole".
function G.AskState(post)
    local _, noMatch = G.AskChoices(post)
    if noMatch then
        return "norole"
    end
    local at = G.asked[post.key .. ":" .. post.created]
    if at then
        if GetTime() - at < G.ASK_AGAIN then
            return "asked"
        end
        return "again"
    end
    return "ask"
end

function G.SendJoin(post, role)
    local id = post.key .. ":" .. post.created
    local me = G.MyKey()
    if not me or (G.asked[id] and GetTime() - G.asked[id] < G.ASK_AGAIN) then
        return false
    end
    G.Send(table.concat({ "J", post.key, ("%d"):format(post.created), me, role, ("%d"):format(MyLevel()) }, G.SEP))
    G.asked[id] = GetTime()
    DW.Print(L.DG_ASK_SENT:format(G.NameOf(post.key), G.RoleName(role)))
    G.PlanRecheck()
    G.Changed()
    return true
end

-- "Ask to join": one fitting role sends at once; several (or none chosen)
-- open a menu. after() runs once a request has gone out. Returns "sent",
-- "menu" or nil.
function G.Ask(post, owner, after)
    if not post or G.AskState(post) == "asked" then
        return nil
    end
    local choices, noMatch = G.AskChoices(post)
    if noMatch or #choices == 0 then
        return nil
    end
    local function Pick(role)
        if G.SendJoin(post, role) and after then
            after()
        end
    end
    if #choices == 1 and next(G.MyRoles()) then
        Pick(choices[1])
        return "sent"
    end
    if not (MenuUtil and MenuUtil.CreateContextMenu) then
        Pick(choices[1])
        return "sent"
    end
    MenuUtil.CreateContextMenu(owner, function(_, root)
        root:CreateTitle(L.DG_ASK_PICK_ROLE)
        for _, code in ipairs(choices) do
            root:CreateButton(G.RoleText(code), function()
                Pick(code)
            end)
        end
    end)
    return "menu"
end

-- Sets up an "Ask to join" button for a post.
function G.PaintAsk(button, post)
    local state = G.AskState(post)
    if state == "asked" then
        button.label:SetText(L.DG_ASKED)
    elseif state == "again" then
        button.label:SetText(L.DG_ASK_AGAIN)
    else
        button.label:SetText(L.DG_ASK)
    end
    button:SetActive(state == "ask" or state == "again")
end

-- The tooltip on a greyed-out "Ask to join".
function G.AskTooltip(button, post)
    if not post or G.AskState(post) ~= "norole" then
        return
    end
    GameTooltip:SetOwner(button, "ANCHOR_RIGHT")
    GameTooltip:AddLine(L.DG_ASK_NO_ROLE:format(DW.RoleNames(G.MyRoles())), 1, 1, 1, true)
    GameTooltip:Show()
end

-- The leader's Invite --------------------------------------------------------------

-- A post for a group bigger than 5 (a raid, or a bigger size chosen) with a
-- full party, not yet a raid: the next click makes it a raid.
function G.NeedsRaid()
    local entry = G.Mine()
    if not entry or G.SizeOf(entry) <= 5 or G.InRaid() then
        return false
    end
    local count = PlainValue(GetNumGroupMembers)
    return type(count) == "number" and count >= 5
end

-- Sets up an Invite button for a request.
function G.PaintInvite(button, request)
    if G.NeedsRaid() then
        button.label:SetText(L.DG_MAKE_RAID)
        button:SetActive(true)
    elseif G.RequestState(request) == "invited" then
        button.label:SetText(L.DG_REQ_INVITED)
        button:SetActive(false)
    else
        button.label:SetText(L.DG_INVITE)
        button:SetActive(true)
    end
end

-- One protected action per click: make a raid, or invite. Both are attempts
-- (the game may refuse without an error). Returns "raid", "invited" or nil.
function G.Invite(request)
    if not request then
        return nil
    end
    if G.NeedsRaid() then
        if DW.CanConvertToRaid() then
            DW.ConvertToRaid()
        end
        G.Changed()
        return "raid"
    end
    if G.RequestState(request) ~= "new" then
        return nil
    end
    if DW.InviteToGroup(request.memberKey) then
        request.state = "invited"
        request.invitedAt = GetTime()
        G.PlanRecheck()
        G.Changed()
        return "invited"
    end
    return nil
end

function G.Decline(request)
    if request then
        request.state = "declined"
        G.Changed()
    end
end

-- "Asked" and "Invite sent" change back after 2 minutes: one timer looks again
-- when the next of them is due.
function G.PlanRecheck()
    if G.recheckScheduled or not (C_Timer and C_Timer.After) then
        return
    end
    local now, due = GetTime(), nil
    for id, at in pairs(G.asked) do
        if now - at >= G.ASK_AGAIN then
            if now - at > 4 * G.ASK_AGAIN then
                G.asked[id] = nil
            end
        elseif not due or at + G.ASK_AGAIN < due then
            due = at + G.ASK_AGAIN
        end
    end
    for _, request in pairs(G.requests) do
        if request.state == "invited" then
            local at = (request.invitedAt or 0) + G.INVITE_RESET
            if not due or at < due then
                due = at
            end
        end
    end
    if not due then
        return
    end
    G.recheckScheduled = true
    C_Timer.After(math.max(1, due - now) + 0.05, function()
        G.recheckScheduled = false
        for _, request in pairs(G.requests) do
            G.RequestState(request)
        end
        G.Changed()
        G.PlanRecheck()
    end)
end

-- Receiving -------------------------------------------------------------------------

local function Integer(text)
    local number = tonumber(text)
    if number and number == math.floor(number) then
        return number
    end
    return nil
end

function G.OnPost(fields, sender)
    local key = fields[2]
    local created, updated = Integer(fields[3]), Integer(fields[4])
    local dungeon = G.Dungeon(Integer(fields[5]) or -1)
    local have, need, size = fields[6] or "", G.ParseNeed(fields[7]), Integer(fields[8])
    if type(key) ~= "string" or key == "" or #key > 60 or not (created and updated and dungeon and need and size) then
        return
    end
    -- After the note: the group size and the counts of "We have" (see the
    -- top of the file). Without them, the dungeon's usual size and no counts.
    local max, haveCount = G.MaxSize(dungeon), nil
    if (fields[10] or "") ~= "" then
        max = G.ValidSize(Integer(fields[10]))
    end
    if (fields[11] or "") ~= "" then
        haveCount = G.ParseNeed(fields[11])
        if not haveCount then
            return
        end
    end
    local sum = G.NeedSum(need)
    if not max or sum < 1 or sum > max - 1 or (haveCount and G.NeedSum(haveCount) + sum + 1 > max)
        or size < 1 or size > 40 or not have:find("^[THD]*$") or #have > 3 then
        return
    end
    local now = G.Now()
    if created > now + G.FUTURE or updated < created or updated > now + G.FUTURE or now - created > G.RECEIVE_MAX_AGE then
        return
    end
    local member = G.SenderIs(key, sender)
    if not member then
        return
    end
    local old = G.posts[key]
    if old then
        old.seenOnlineAt = now
    end
    if (old and updated <= old.updated) or (G.closedAt[key] and updated <= G.closedAt[key]) then
        return
    end
    local note = fields[9] or ""
    if #note > G.NOTE_RECEIVE then
        note = ""
    end
    local post = {
        key = key, created = created, updated = updated, dungeon = dungeon.id,
        have = G.HaveSet(have), need = need, size = size, max = max, haveCount = haveCount,
        note = G.Clean(note, G.NOTE_RECEIVE), seenOnlineAt = now,
    }
    G.posts[key] = post
    G.ConsiderToast(post)
    G.Changed()
end

function G.OnClose(fields, sender)
    local key, created, when = fields[2], Integer(fields[3]), Integer(fields[4])
    if type(key) ~= "string" or not created or not when or when > G.Now() + G.FUTURE then
        return
    end
    if not G.SenderIs(key, sender) then
        return
    end
    G.closedAt[key] = math.max(G.closedAt[key] or 0, when)
    local post = G.posts[key]
    if post and post.created <= created and when >= post.updated then
        G.posts[key] = nil
    end
    G.Changed()
end

function G.OnJoin(fields, sender)
    local leaderKey, created, requesterKey = fields[2], Integer(fields[3]), fields[4]
    local role, level = fields[5], Integer(fields[6])
    local entry = G.Mine()
    if not entry or leaderKey ~= G.MyKey() or created ~= entry.created then
        return
    end
    if not (role == "T" or role == "H" or role == "D") or not level or level < 1 or level > 100 then
        return
    end
    if type(requesterKey) ~= "string" or #requesterKey > 60 then
        return
    end
    local member = G.SenderIs(requesterKey, sender)
    if not member then
        return
    end
    if not G.requests[requesterKey] then
        local count = 0
        for _ in pairs(G.requests) do
            count = count + 1
        end
        if count >= G.MAX_REQUESTS then
            return
        end
    end
    G.requests[requesterKey] = {
        key = requesterKey, name = member.name, memberKey = member.key, class = member.class,
        role = role, level = level, at = G.Now(), state = "new",
    }
    G.Enqueue({ kind = "request", key = requesterKey })
    G.Changed()
end

DW.OnGuildMessage(G.PREFIX, function(text, sender)
    local fields = {}
    for field in (text .. G.SEP):gmatch("(.-)" .. G.SEP) do
        fields[#fields + 1] = field
    end
    if fields[1] == "P" then
        G.OnPost(fields, sender)
    elseif fields[1] == "X" then
        G.OnClose(fields, sender)
    elseif fields[1] == "J" then
        G.OnJoin(fields, sender)
    elseif fields[1] == "R" then
        -- Someone logged in: send our open post, after a short random delay.
        if G.replyScheduled or not G.Mine() or not (C_Timer and C_Timer.After) then
            return
        end
        G.replyScheduled = true
        C_Timer.After(1 + math.random() * 5, function()
            G.replyScheduled = false
            if DW.IsMember() and G.Mine() then
                G.SendPost()
            end
        end)
    end
end)

-- Login: ask for the open posts once, and send our own again (after /reload).
function G.Hello()
    if G.helloSent then
        return
    end
    G.helloSent = true
    local now = G.Now()
    if type(G.db) == "table" and type(G.db.mine) == "table" then
        for key, entry in pairs(G.db.mine) do
            if not G.ValidSaved(entry) or now - entry.created >= G.LIFETIME then
                G.db.mine[key] = nil
            end
        end
    end
    G.Send("R")
    if G.Mine() then
        G.SendPost()
        G.StartTick()
    end
    G.Changed()
end

function G.PlanHello()
    if G.helloSent or G.helloPlanned or not (C_Timer and C_Timer.After) then
        return
    end
    G.helloPlanned = true
    C_Timer.After(G.HELLO_DELAY, function()
        G.helloPlanned = false
        if DW.IsMember() then
            G.Hello()
        end
    end)
end

-- For tests: as after a /reload, the hello runs again.
function DW.RestartGroupHello()
    G.helloSent = false
    G.PlanHello()
end

-- Going into the dungeon closes your post.
DW.OnDungeonEntered(function()
    if G.Mine() then
        G.Close("instance")
    end
end)

-- The pop-up ------------------------------------------------------------------------

-- A new post that fits you: a pop-up, unless turned off, already shown for
-- this post, older than 15 minutes, or the same leader had one in the last 10.
function G.ConsiderToast(post)
    if type(G.db) == "table" and G.db.toast == false then
        return
    end
    if not G.Fits(post) or G.Now() - post.created > G.TOAST_MAX_AGE then
        return
    end
    local id = post.key .. ":" .. post.created
    local last = G.toastedLeader[post.key]
    if G.toastedPost[id] or (last and GetTime() - last < G.TOAST_LEADER_GAP) then
        return
    end
    -- Only a pop-up that was kept counts as shown (a full queue drops it).
    if G.Enqueue({ kind = "post", key = post.key, created = post.created }) then
        G.toastedPost[id] = true
        G.toastedLeader[post.key] = GetTime()
    end
end

-- At most 3 waiting, first in first out; the same leader or requester
-- replaces their waiting one. Returns true when the item was kept (new,
-- replacing a waiting one, or refilling the one showing), false when dropped.
function G.Enqueue(item)
    local shown = G.toast and G.toast:IsShown() and G.toast.item
    if shown and shown.kind == item.kind and shown.key == item.key and not shown.sample then
        G.toast.item = item
        G.FillToast()
        return true
    end
    for index, waiting in ipairs(G.queue) do
        if waiting.kind == item.kind and waiting.key == item.key then
            G.queue[index] = item
            G.ShowNext()
            return true
        end
    end
    if #G.queue >= G.QUEUE_MAX then
        return false
    end
    G.queue[#G.queue + 1] = item
    G.ShowNext()
    return true
end

-- Is a waiting item still worth showing?
function G.ItemValid(item)
    if item.sample then
        return true
    end
    if item.kind == "post" then
        local post = G.posts[item.key]
        return post ~= nil and post.created == item.created and G.Fits(post)
    end
    local request = G.requests[item.key]
    return request ~= nil and G.Mine() ~= nil and G.RequestState(request) == "new"
end

-- Shows the next waiting pop-up, unless one is showing or you are in combat.
function G.ShowNext()
    if (G.toast and G.toast:IsShown()) or G.InCombat() then
        return
    end
    while #G.queue > 0 do
        local item = table.remove(G.queue, 1)
        if G.ItemValid(item) then
            G.ShowToast(item)
            return
        end
    end
end

function G.CloseToast()
    if G.toast and G.toast:IsShown() then
        G.toast:Hide()
    end
    G.ShowNext()
end

function G.SavedToastPos()
    local pos = type(G.db) == "table" and G.db.toastPos
    if type(pos) == "table" and type(pos[1]) == "string" and type(pos[2]) == "string"
        and type(pos[3]) == "number" and type(pos[4]) == "number" then
        return pos
    end
    return nil
end

function G.CreateToast()
    local t = CreateFrame("Frame", "DragonworldGroupToast", UIParent, "BackdropTemplate")
    t:SetSize(440, 84)
    t:SetFrameStrata("HIGH")
    t:SetClampedToScreen(true)
    t:SetMovable(true)
    t:EnableMouse(true)
    t:RegisterForDrag("LeftButton")
    t:SetBackdrop(DW.PANEL_BACKDROP)
    t:SetBackdropColor(0.04, 0.06, 0.05, 1)
    t:SetBackdropBorderColor(0.30, 1.00, 0.45, 1)
    t.solid = t:CreateTexture(nil, "BACKGROUND")
    t.solid:SetPoint("TOPLEFT", 3, -3)
    t.solid:SetPoint("BOTTOMRIGHT", -3, 3)
    t.solid:SetColorTexture(0.04, 0.06, 0.05, 1)
    local pos = G.SavedToastPos()
    if pos then
        t:SetPoint(pos[1], UIParent, pos[2], pos[3], pos[4])
    else
        t:SetPoint("TOP", UIParent, "TOP", 0, -250)
    end

    t.icon = t:CreateTexture(nil, "ARTWORK")
    t.icon:SetSize(40, 40)
    t.icon:SetPoint("TOPLEFT", 12, -12)
    t.icon:SetTexture("Interface\\Icons\\Ability_DualWield")

    t.title = t:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
    t.title:SetPoint("TOPLEFT", 62, -9)
    t.title:SetPoint("RIGHT", -32, 0)
    t.title:SetJustifyH("LEFT")
    t.title:SetWordWrap(false)
    t.title:SetTextColor(1.00, 0.82, 0.00)

    t.text = t:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
    t.text:SetPoint("TOPLEFT", 62, -29)
    t.text:SetWidth(300)
    t.text:SetJustifyH("LEFT")
    t.text:SetWordWrap(true)

    t.secondary = DW.CreateChip(t, 90, 22)
    t.secondary:SetPoint("BOTTOMRIGHT", -12, 7)
    t.secondary.label:SetJustifyH("CENTER")
    t.primary = DW.CreateButton(t, 110, 22, "gold")
    t.primary:SetPoint("RIGHT", t.secondary, "LEFT", -6, 0)

    t.close = CreateFrame("Button", nil, t, "UIPanelCloseButton")
    t.close:SetPoint("TOPRIGHT", -2, -2)
    t.close:SetScript("OnClick", function()
        G.CloseToast()
    end)

    t.primary:SetScript("OnClick", function(self)
        local item = t.item
        if not item or item.sample then
            G.CloseToast()
            return
        end
        if item.kind == "post" then
            local result = G.Ask(G.posts[item.key], self, function()
                if t.item == item then
                    G.CloseToast()
                end
            end)
            if result == nil then
                G.CloseToast()
            end
        else
            local result = G.Invite(G.requests[item.key])
            if result == "raid" then
                -- Stays open for the invite that comes next.
                t.remaining = G.TOAST_SECONDS
                t:SetAlpha(1)
                G.FillToast()
            else
                G.CloseToast()
            end
        end
    end)
    t.primary:HookScript("OnEnter", function(self)
        local item = t.item
        if item and item.kind == "post" and not item.sample then
            G.AskTooltip(self, G.posts[item.key])
        end
    end)
    t.primary:HookScript("OnLeave", function()
        GameTooltip:Hide()
    end)
    t.secondary:SetScript("OnClick", function()
        local item = t.item
        if item and not item.sample then
            if item.kind == "post" then
                local member = G.MemberOf(item.key)
                if member then
                    DW.WhisperTo(member.key)
                end
            else
                G.Decline(G.requests[item.key])
            end
        end
        G.CloseToast()
    end)

    t:SetScript("OnDragStart", function(self)
        self:StartMoving()
    end)
    t:SetScript("OnDragStop", function(self)
        self:StopMovingOrSizing()
        local point, _, relativePoint, x, y = self:GetPoint(1)
        if type(G.db) == "table" and type(point) == "string" and type(x) == "number" and type(y) == "number" then
            G.db.toastPos = { point, relativePoint or point, x, y }
        end
    end)
    -- Stays 25 s (the clock stops while the mouse is over it), then fades out.
    t:SetScript("OnUpdate", function(self, elapsed)
        if self:IsMouseOver() then
            self.remaining = math.max(self.remaining or 0, G.TOAST_FADE + 1)
            self:SetAlpha(1)
            return
        end
        self.remaining = (self.remaining or 0) - elapsed
        if self.remaining <= 0 then
            G.CloseToast()
        elseif self.remaining < G.TOAST_FADE then
            self:SetAlpha(math.max(0, math.min(1, self.remaining / G.TOAST_FADE)))
        end
    end)
    t:Hide()
    G.toast = t
    return t
end

-- Writes the pop-up for its item (also after a language change).
function G.FillToast()
    local t = G.toast
    local item = t and t.item
    if not item then
        return
    end
    if item.kind == "post" then
        local post = item.sample or G.posts[item.key]
        if not post then
            return
        end
        local name = item.sampleName or G.NameOf(post.key)
        local text = L.DG_TOAST_TEXT:format(name, G.Title(G.Dungeon(post.dungeon), post.max), G.NeedNames(post.need, true))
        if post.note and post.note ~= "" then
            text = text .. "\n|cff999999\"" .. post.note .. "\"|r"
        end
        t.title:SetText(L.DG_TOAST_TITLE)
        t.text:SetText(text)
        if item.sample then
            t.primary.label:SetText(L.DG_ASK)
            t.primary:SetActive(true)
        else
            G.PaintAsk(t.primary, post)
        end
        t.secondary.label:SetText(L.DG_WHISPER)
    else
        local request = G.requests[item.key]
        if not request then
            return
        end
        t.title:SetText(L.DG_TOAST_REQ_TITLE)
        t.text:SetText(L.DG_TOAST_REQ_TEXT:format(request.name, request.level, G.RoleText(request.role)))
        G.PaintInvite(t.primary, request)
        t.secondary.label:SetText(L.DG_TOAST_NO)
    end
    -- Grows when the text needs more lines.
    t:SetHeight(math.max(84, 29 + t.text:GetStringHeight() + 36))
end

function G.ShowToast(item)
    local t = G.toast or G.CreateToast()
    t.item = item
    t.remaining = G.TOAST_SECONDS
    t:SetAlpha(1)
    G.FillToast()
    t:Show()
    if type(SOUNDKIT) == "table" and type(SOUNDKIT.IG_PLAYER_INVITE) == "number" and PlaySound then
        pcall(PlaySound, SOUNDKIT.IG_PLAYER_INVITE)
    end
end

-- Refreshes the labels of a pop-up that is showing.
G.RefreshToast = function()
    if G.toast and G.toast:IsShown() then
        G.FillToast()
    end
end

-- An example pop-up, for trying it out.
function DW.ShowGroupToastSample()
    local _, name = DW.CharacterKey()
    G.Enqueue({
        kind = "post", key = "sample", sample = { dungeon = 14, need = { T = 0, H = 1, D = 2 }, note = "" },
        sampleName = name or "?",
    })
end

function DW.GroupToastQueueLength()
    return #G.queue
end

-- The open posts: { { post, member, fits }, ... } (yours first).
function DW.GroupPosts()
    return G.AlivePosts()
end

-- The form ("Lead a group") ---------------------------------------------------------

-- The form's values: dungeon (an id, 0 = "Other group"), max (the group
-- size), have (the three ticks, for a group of 5 or less), haveCount (counts
-- per role, not counting you, for a bigger group), need (counts) and note.

-- Whether "We have" is counts (a group bigger than 5) rather than ticks.
function G.HasCounts(values)
    return (values.max or 5) > 5
end

-- Free places for what the group needs: the group size less those in the
-- group now; with counts also less what the group has and you.
function G.FormRoom(values)
    local max = values.max or 5
    local room = max - DW.GroupSize()
    if G.HasCounts(values) then
        room = math.min(room, max - 1 - G.NeedSum(values.haveCount))
    end
    return math.max(0, room)
end

-- How many more "We have" can count: what has and needs, and you, fill the
-- group size at most.
function G.HaveRoom(values)
    return math.max(0, (values.max or 5) - 1 - G.NeedSum(values.haveCount) - G.NeedSum(values.need))
end

-- Keeps what the group has and needs within the group size: one role at
-- most the size less you (4 in a group of 5); too many in all are taken from
-- DPS first, then healers, then tanks. The counts of "We have" are trimmed
-- first to the size less you, then what is needed to the room left.
function G.ClampNeed(values)
    local cap = G.RoleCap(values.max)
    local function Trim(counts, room)
        for _, role in ipairs(DW.ROLES) do
            counts[role.code] = math.max(0, math.min(counts[role.code] or 0, cap))
        end
        for _, code in ipairs({ "D", "H", "T" }) do
            while G.NeedSum(counts) > room and counts[code] > 0 do
                counts[code] = counts[code] - 1
            end
        end
    end
    values.haveCount = values.haveCount or { T = 0, H = 0, D = 0 }
    if G.HasCounts(values) then
        Trim(values.haveCount, cap)
    end
    Trim(values.need, G.FormRoom(values))
end

-- A dungeon chosen in the form: the group size goes to its usual size.
function G.ChooseFormDungeon(values, id)
    values.dungeon = id
    values.max = G.MaxSize(G.Dungeon(id))
    G.ClampNeed(values)
end

-- A new post: the first dungeon of your "open for dungeons" status that fits
-- your level, at its usual size; what you have is your role if you have
-- exactly one; it needs a tank and a healer unless you are one, and 3 DPS
-- (2 if you are one).
function G.FormDefaults()
    local values = { have = {}, haveCount = { T = 0, H = 0, D = 0 }, need = { T = 0, H = 0, D = 0 } }
    local level = MyLevel()
    local code, entry = DW.GetMyStatus()
    if code == "D" and entry then
        for _, dungeon in ipairs(DW.DUNGEONS) do
            if entry.dungeons and entry.dungeons[dungeon.id] and G.LevelFits(dungeon, level) then
                values.dungeon = dungeon.id
                break
            end
        end
    end
    values.max = G.MaxSize(G.Dungeon(values.dungeon))
    local roles, only, count = G.MyRoles(), nil, 0
    for _, role in ipairs(DW.ROLES) do
        if roles[role.code] then
            only, count = role.code, count + 1
        end
    end
    if count == 1 then
        values.have[only] = true
    end
    values.need.T = values.have.T and 0 or 1
    values.need.H = values.have.H and 0 or 1
    values.need.D = values.have.D and 2 or 3
    G.ClampNeed(values)
    return values
end

function G.RefreshForm()
    local p, values = G.form, G.formValues
    if not p or not values then
        return
    end
    p.title:SetText(L.DG_FORM_TITLE)
    p.hint:SetText(L.DG_FORM_HINT)
    local dungeon = G.Dungeon(values.dungeon)
    p.dungeonChip.label:SetText(L.DG_FORM_DUNGEON:format(dungeon and DungeonLabel(dungeon) or L.DG_FORM_DUNGEON_NONE))
    p.sizeLabel:SetText(L.DG_FORM_SIZE)
    for _, chip in ipairs(p.sizeChips) do
        chip:SetSelected(chip.size == values.max)
    end
    -- "We have": three ticks in a group of 5, counts in a bigger one.
    local counts = G.HasCounts(values)
    p.haveLabel:SetText(L.DG_FORM_HAVE)
    for _, check in ipairs(p.haveChecks) do
        check.label:SetText(G.RoleText(check.role.code, 16))
        check:SetChecked(values.have[check.role.code] and true or false)
        check:SetShown(not counts)
    end
    local haveRoom = G.HaveRoom(values)
    for _, row in ipairs(p.haveRows) do
        local count = values.haveCount[row.role.code] or 0
        row.label:SetText(G.RoleText(row.role.code, 16))
        row.count:SetText(tostring(count))
        row.minus:SetActive(count > 0)
        row.plus:SetActive(haveRoom > 0)
        G.ShowStepper(row, counts)
    end
    p.haveHint:SetText(L.DG_FORM_HAVE_HINT)
    p.haveHint:SetShown(counts)
    p.needLabel:SetText(L.DG_FORM_NEED)
    local room, sum, cap = G.FormRoom(values), G.NeedSum(values.need), G.RoleCap(values.max)
    for _, row in ipairs(p.needRows) do
        local count = values.need[row.role.code] or 0
        row.label:SetText(G.RoleText(row.role.code, 16))
        row.count:SetText(tostring(count))
        row.minus:SetActive(count > 0)
        row.plus:SetActive(sum < room and count < cap)
    end
    p.noteLabel:SetText(L.DG_FORM_NOTE)
    local mine = G.Mine()
    -- "Also say it in guild chat" is only for a new post.
    p.chatLabel:SetText(L.DG_FORM_CHAT)
    p.chatCheck:SetShown(mine == nil)
    p.lifetime:SetText(L.DG_FORM_LIFETIME)
    p.lfgTip:SetText(L.DG_FORM_LFG_TIP)
    p.post.label:SetText(mine and L.DG_FORM_UPDATE or L.DG_FORM_POST)
    p.cancel.label:SetText(L.DG_PICK_CANCEL)
    p.stop.label:SetText(L.DG_LEAD_STOP)
    p.stop:SetShown(mine ~= nil)
end

-- The dungeon menu: "Other group" first, then all the dungeons; those outside
-- your level (2 levels of leeway) in grey. Without the menu API, the first
-- dungeon that fits.
function G.OpenFormDungeonMenu(owner)
    local values, level = G.formValues, MyLevel()
    local function Choose(id)
        G.ChooseFormDungeon(values, id)
        G.form.error:SetText("")
        G.RefreshForm()
    end
    if not (MenuUtil and MenuUtil.CreateContextMenu) then
        for _, dungeon in ipairs(DW.DUNGEONS) do
            if G.LevelFits(dungeon, level) then
                Choose(dungeon.id)
                return
            end
        end
        return
    end
    MenuUtil.CreateContextMenu(owner, function(_, root)
        local function IsChosen(id)
            return values.dungeon == id
        end
        root:CreateTitle(L.DG_FILTER_TITLE)
        root:CreateRadio(L.DG_OTHER_GROUP_MENU, IsChosen, Choose, G.OTHER.id)
        if root.CreateDivider then
            root:CreateDivider()
        end
        for _, dungeon in ipairs(DW.DUNGEONS) do
            local text = DungeonLabel(dungeon)
            if not G.LevelFits(dungeon, level) then
                text = "|cff808080" .. text .. "|r"
            end
            root:CreateRadio(text, IsChosen, Choose, dungeon.id)
        end
    end)
end

function G.SubmitForm()
    local p, values = G.form, G.formValues
    if not values.dungeon or not G.Dungeon(values.dungeon) then
        p.error:SetText(L.DG_FORM_NEED_DUNGEON)
        return
    end
    G.ClampNeed(values)
    if G.NeedSum(values.need) == 0 then
        p.error:SetText(L.DG_FORM_NEED_ROLE)
        G.RefreshForm()
        return
    end
    values.note = p.noteBox:GetText()
    local chat = p.chatCheck:IsShown() and p.chatCheck:GetChecked() and true or false
    p:Hide()
    G.SavePost(values, chat)
end

-- A count for one role in the form: icon and name, "-", the count, "+", from
-- x, y. Change(code, -1 or 1) runs on a click.
function G.CreateStepper(p, role, x, y, Change)
    local row = { role = role }
    row.label = p:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
    row.label:SetPoint("TOPLEFT", x, y)
    row.label:SetWidth(70)
    row.label:SetJustifyH("LEFT")
    row.label:SetWordWrap(false)
    row.minus = DW.CreateButton(p, 22, 22, "gold")
    row.minus:SetPoint("TOPLEFT", x + 72, y + 4)
    row.minus.label:SetText("-")
    row.count = p:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
    row.count:SetPoint("TOPLEFT", x + 96, y)
    row.count:SetWidth(20)
    row.count:SetJustifyH("CENTER")
    row.plus = DW.CreateButton(p, 22, 22, "gold")
    row.plus:SetPoint("TOPLEFT", x + 118, y + 4)
    row.plus.label:SetText("+")
    row.minus:SetScript("OnClick", function()
        Change(role.code, -1)
    end)
    row.plus:SetScript("OnClick", function()
        Change(role.code, 1)
    end)
    return row
end

function G.ShowStepper(row, shown)
    row.label:SetShown(shown)
    row.minus:SetShown(shown)
    row.count:SetShown(shown)
    row.plus:SetShown(shown)
end

function G.CreateForm(window)
    local p = CreateFrame("Frame", "DragonworldGroupForm", window, "BackdropTemplate")
    DW.RegisterOverlay("DragonworldGroupForm")
    p:SetPoint("TOPLEFT", 14, -92)
    p:SetSize(window:GetWidth() - 28, window:GetHeight() - 92 - 14)
    p:SetFrameStrata("DIALOG")
    p:EnableMouse(true)
    p:SetBackdrop(DW.PANEL_BACKDROP)
    p:SetBackdropColor(0.05, 0.05, 0.07, 1)
    p:SetBackdropBorderColor(1.00, 0.82, 0.00, 1)
    p.solid = p:CreateTexture(nil, "BACKGROUND")
    p.solid:SetPoint("TOPLEFT", 3, -3)
    p.solid:SetPoint("BOTTOMRIGHT", -3, 3)
    p.solid:SetColorTexture(0.05, 0.05, 0.07, 1)
    local width = p:GetWidth()

    p.title = p:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
    p.title:SetPoint("TOPLEFT", 16, -12)
    p.hint = p:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    p.hint:SetPoint("TOPLEFT", 16, -36)
    p.hint:SetWidth(width - 32)
    p.hint:SetJustifyH("LEFT")

    p.dungeonChip = DW.CreateChip(p, 300, 24)
    p.dungeonChip:SetPoint("TOPLEFT", 16, -62)
    p.dungeonChip:SetScript("OnClick", function(self)
        G.OpenFormDungeonMenu(self)
    end)

    -- The group size, on the same line: "Group size:" and a chip per size,
    -- the chosen one in gold. The label is as wide as its text, so the chips
    -- follow it in every language.
    p.sizeLabel = p:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    p.sizeLabel:SetPoint("LEFT", p.dungeonChip, "RIGHT", 20, 0)
    p.sizeChips = {}
    for index, size in ipairs(G.SIZES) do
        local chip = DW.CreateChip(p, 42, 24)
        if index == 1 then
            chip:SetPoint("LEFT", p.sizeLabel, "RIGHT", 8, 0)
        else
            chip:SetPoint("LEFT", p.sizeChips[index - 1], "RIGHT", 4, 0)
        end
        chip.size = size
        chip.label:SetJustifyH("CENTER")
        chip.label:SetText(tostring(size))
        chip:SetScript("OnClick", function(self)
            G.formValues.max = self.size
            G.ClampNeed(G.formValues)
            p.error:SetText("")
            G.RefreshForm()
        end)
        p.sizeChips[index] = chip
    end

    -- What the group has: one check per role in a group of 5; in a bigger
    -- group a count per role instead (not counting you), with a hint after.
    p.haveLabel = p:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    p.haveLabel:SetPoint("TOPLEFT", 16, -98)
    p.haveChecks = {}
    p.haveRows = {}
    for index, role in ipairs(DW.ROLES) do
        local check = CreateFrame("CheckButton", nil, p, "UICheckButtonTemplate")
        check:SetSize(22, 22)
        check:SetPoint("TOPLEFT", 76 + (index - 1) * 160, -94)
        check.role = role
        check.label = check:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
        check.label:SetPoint("LEFT", check, "RIGHT", 2, 0)
        check:SetScript("OnClick", function(self)
            G.formValues.have[self.role.code] = self:GetChecked() and true or nil
            G.RefreshForm()
        end)
        p.haveChecks[index] = check
        p.haveRows[index] = G.CreateStepper(p, role, 76 + (index - 1) * 160, -98, function(code, step)
            local values = G.formValues
            local count = values.haveCount[code] or 0
            if step < 0 then
                values.haveCount[code] = math.max(0, count - 1)
            elseif G.HaveRoom(values) > 0 then
                values.haveCount[code] = count + 1
            end
            p.error:SetText("")
            G.RefreshForm()
        end)
    end
    p.haveHint = p:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
    p.haveHint:SetPoint("TOPLEFT", 76 + #DW.ROLES * 160, -100)
    p.haveHint:SetWidth(width - 16 - (76 + #DW.ROLES * 160))
    p.haveHint:SetJustifyH("LEFT")
    p.haveHint:SetWordWrap(false)

    -- What it needs: icon and name, "-", the count, "+".
    p.needLabel = p:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    p.needLabel:SetPoint("TOPLEFT", 16, -130)
    p.needRows = {}
    for index, role in ipairs(DW.ROLES) do
        p.needRows[index] = G.CreateStepper(p, role, 76 + (index - 1) * 160, -130, function(code, step)
            local values = G.formValues
            local count = values.need[code] or 0
            if step < 0 then
                values.need[code] = math.max(0, count - 1)
            elseif G.NeedSum(values.need) < G.FormRoom(values) and count < G.RoleCap(values.max) then
                values.need[code] = count + 1
            end
            p.error:SetText("")
            G.RefreshForm()
        end)
    end

    p.noteLabel = p:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    p.noteLabel:SetPoint("TOPLEFT", 16, -164)
    p.noteBox = CreateFrame("EditBox", nil, p, "InputBoxTemplate")
    p.noteBox:SetSize(360, 20)
    p.noteBox:SetPoint("TOPLEFT", 160, -160)
    p.noteBox:SetAutoFocus(false)
    p.noteBox:SetMaxBytes(G.NOTE_BYTES + 1)
    p.noteBox:SetScript("OnEnterPressed", function(self)
        self:ClearFocus()
    end)
    p.noteBox:SetScript("OnEscapePressed", function(self)
        self:ClearFocus()
    end)

    p.chatCheck = CreateFrame("CheckButton", nil, p, "UICheckButtonTemplate")
    p.chatCheck:SetSize(22, 22)
    p.chatCheck:SetPoint("TOPLEFT", 12, -190)
    p.chatLabel = p.chatCheck:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
    p.chatLabel:SetPoint("LEFT", p.chatCheck, "RIGHT", 2, 0)

    p.lifetime = p:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
    p.lifetime:SetPoint("TOPLEFT", 16, -224)
    p.lifetime:SetWidth(width - 32)
    p.lifetime:SetJustifyH("LEFT")
    p.lfgTip = p:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
    p.lfgTip:SetPoint("TOPLEFT", p.lifetime, "BOTTOMLEFT", 0, -6)
    p.lfgTip:SetWidth(width - 32)
    p.lfgTip:SetJustifyH("LEFT")

    p.error = p:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    p.error:SetPoint("BOTTOMLEFT", 16, 46)
    p.error:SetTextColor(1.00, 0.35, 0.30)

    p.cancel = DW.CreateChip(p, 100, 28)
    p.cancel:SetPoint("BOTTOMRIGHT", -16, 12)
    p.cancel.label:SetJustifyH("CENTER")
    p.cancel:SetScript("OnClick", function()
        p:Hide()
    end)
    p.post = DW.CreateButton(p, 130, 28, "gold")
    p.post:SetPoint("RIGHT", p.cancel, "LEFT", -8, 0)
    p.post:SetScript("OnClick", function()
        G.SubmitForm()
    end)
    p.stop = DW.CreateButton(p, 150, 28, "red")
    p.stop:SetPoint("RIGHT", p.post, "LEFT", -8, 0)
    p.stop:SetScript("OnClick", function()
        G.Close("manual")
        p:Hide()
    end)

    G.form = p
    return p
end

-- Opens the form: your post's values, or the defaults for a new one.
function DW.OpenGroupForm()
    local window = _G.DragonworldFrame
    if not window or not DW.IsMember() then
        return
    end
    local p = G.form or G.CreateForm(window)
    DW.HideOverlays("DragonworldGroupForm")
    local mine = G.Mine()
    if mine then
        G.formValues = {
            dungeon = mine.dungeon, max = G.SizeOf(mine), have = G.HaveSet(mine.have),
            haveCount = (mine.haveCount and G.ParseNeed(mine.haveCount)) or { T = 0, H = 0, D = 0 }, need = G.ParseNeed(mine.need),
        }
        p.noteBox:SetText(mine.note or "")
    else
        G.formValues = G.FormDefaults()
        p.noteBox:SetText("")
    end
    p.chatCheck:SetChecked(false)
    p.error:SetText("")
    G.RefreshForm()
    p:Show()
end

-- The tab ---------------------------------------------------------------------

local panel
local rows = {}
local RefreshPanel
local filterDungeon -- the id of one dungeon, or nil for all
local filterRole    -- the code of one role ("T", "H", "D"), or nil for all

local ROLE_BY_CODE = {}
for _, role in ipairs(DW.ROLES) do
    ROLE_BY_CODE[role.code] = role
end

local function Matches(entry)
    if filterDungeon ~= nil and not (entry.dungeons and entry.dungeons[filterDungeon]) then
        return false
    end
    -- Those who have not chosen a role (older version) are not shown when
    -- filtering by role.
    if filterRole ~= nil and not (entry.roles and entry.roles[filterRole]) then
        return false
    end
    return true
end

local function Collect()
    local list = DW.MembersWithStatus("D")
    local shown = {}
    for _, found in ipairs(list) do
        if Matches(found.entry) then
            found.me = IsMe(found.member)
            found.shared = SharedCount(found.entry.dungeons)
            shown[#shown + 1] = found
        end
    end
    table.sort(shown, function(a, b)
        if a.me ~= b.me then
            return a.me
        end
        if a.shared ~= b.shared then
            return a.shared > b.shared
        end
        return a.member.name < b.member.name
    end)
    return shown, list
end

local function OpenFilterMenu(owner)
    local _, everyone = Collect()
    local used = {}
    for _, found in ipairs(everyone) do
        for id in pairs(found.entry.dungeons or {}) do
            used[id] = true
        end
    end
    for _, found in ipairs(G.AlivePosts()) do
        used[found.post.dungeon] = true
    end
    local function IsSelected(data)
        return (filterDungeon or false) == data
    end
    local function Select(data)
        filterDungeon = data or nil
        RefreshPanel()
    end
    if not (MenuUtil and MenuUtil.CreateContextMenu) then
        filterDungeon = nil
        RefreshPanel()
        return
    end
    MenuUtil.CreateContextMenu(owner, function(_, root)
        root:CreateTitle(L.DG_FILTER_TITLE)
        root:CreateRadio(L.DG_ALL, IsSelected, Select, false)
        -- "Other group" only has posts (nobody is "open" for it).
        if used[G.OTHER.id] then
            root:CreateRadio(L.DG_OTHER_GROUP, IsSelected, Select, G.OTHER.id)
        end
        for _, dungeon in ipairs(DW.DUNGEONS) do
            if used[dungeon.id] then
                root:CreateRadio(dungeon.name, IsSelected, Select, dungeon.id)
            end
        end
    end)
end

-- Filter by role: all three are always in the menu.
local function OpenRoleMenu(owner)
    local function IsSelected(data)
        return (filterRole or false) == data
    end
    local function Select(data)
        filterRole = data or nil
        RefreshPanel()
    end
    if not (MenuUtil and MenuUtil.CreateContextMenu) then
        filterRole = nil
        RefreshPanel()
        return
    end
    MenuUtil.CreateContextMenu(owner, function(_, root)
        root:CreateTitle(L.DG_ROLE_FILTER_TITLE)
        root:CreateRadio(L.DG_ALL, IsSelected, Select, false)
        for _, role in ipairs(DW.ROLES) do
            root:CreateRadio(DW.RoleIcon(role) .. " " .. L[role.key], IsSelected, Select, role.code)
        end
    end)
end

local function GetRow(index)
    local row = rows[index]
    if row then
        return row
    end
    local width = panel.content:GetWidth()
    row = CreateFrame("Frame", nil, panel.content)
    row:SetSize(width, ROW_HEIGHT - 4)
    row:SetPoint("TOPLEFT", 0, -(index - 1) * ROW_HEIGHT)
    row:EnableMouse(true)

    row.name = row:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
    row.name:SetPoint("TOPLEFT", 4, -4)
    row.name:SetWidth(134)
    row.name:SetJustifyH("LEFT")
    row.name:SetWordWrap(false)

    -- The role icons (one or two) between the name and the level.
    row.roles = row:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
    row.roles:SetPoint("TOPLEFT", 140, -3)
    row.roles:SetWidth(40)
    row.roles:SetJustifyH("LEFT")
    row.roles:SetWordWrap(false)

    row.level = row:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    row.level:SetPoint("TOPLEFT", 178, -6)
    row.level:SetWidth(30)
    row.level:SetJustifyH("RIGHT")

    row.why = row:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    row.why:SetPoint("TOPLEFT", 222, -6)
    row.why:SetWidth(200)
    row.why:SetJustifyH("LEFT")
    row.why:SetWordWrap(false)

    row.invite = DW.CreateButton(row, 70, 20, "gold")
    row.invite:SetPoint("TOPRIGHT", -4, -2)
    row.invite:SetScript("OnClick", function(self)
        if row.found then
            Invite(row.found.member.key)
        end
    end)

    row.whisper = DW.CreateChip(row, 70, 20)
    row.whisper:SetPoint("RIGHT", row.invite, "LEFT", -6, 0)
    row.whisper.label:SetJustifyH("CENTER")
    row.whisper:SetScript("OnClick", function()
        if row.found then
            Whisper(row.found.member.key)
        end
    end)

    -- On your own row: "Keep me listed" starts the hour again.
    -- Small text and a little wider: the text is long in several languages.
    row.keep = DW.CreateChip(row, 140, 20)
    row.keep:SetPoint("TOPRIGHT", -4, -2)
    row.keep.label:SetFontObject("GameFontHighlightSmall")
    row.keep.label:SetJustifyH("CENTER")
    row.keep:SetScript("OnClick", function()
        DW.TouchMyStatus()
    end)
    row.keep:HookScript("OnEnter", function(self)
        local left = DW.MyStatusTimeLeft() or 0
        GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
        GameTooltip:AddLine(L.DG_KEEP_TIP:format(math.ceil(left / 60)), 1, 1, 1, true)
        GameTooltip:Show()
    end)
    row.keep:HookScript("OnLeave", function()
        GameTooltip:Hide()
    end)

    row.dungeons = row:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    row.dungeons:SetPoint("BOTTOMLEFT", 4, 4)
    row.dungeons:SetWidth(width - 8)
    row.dungeons:SetJustifyH("LEFT")
    row.dungeons:SetWordWrap(false)

    -- Hold over the row to see all the dungeons the member wants to do.
    row:SetScript("OnEnter", function(self)
        local found = self.found
        if not found then
            return
        end
        GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
        GameTooltip:AddLine(found.member.name)
        if next(found.entry.roles or {}) then
            GameTooltip:AddLine(RolesText(found.entry.roles), 1, 1, 1)
        end
        GameTooltip:AddLine(PurposesText(found.entry.purposes), 1.00, 0.82, 0.00)
        for _, dungeon in ipairs(DW.DUNGEONS) do
            if found.entry.dungeons and found.entry.dungeons[dungeon.id] then
                local mine = MyWish() or {}
                if mine[dungeon.id] then
                    GameTooltip:AddLine(DungeonLabel(dungeon), 0.25, 1.00, 0.25)
                else
                    GameTooltip:AddLine(DungeonLabel(dungeon), 1, 1, 1)
                end
            end
        end
        GameTooltip:Show()
    end)
    row:SetScript("OnLeave", function()
        GameTooltip:Hide()
    end)

    rows[index] = row
    return row
end

-- The posts at the top of the list ---------------------------------------------------

-- Does a post pass the filters (dungeon, and a role it needs)? Your own post
-- always shows: the filters are for finding others' groups, and the
-- requests to join your group are drawn under it.
local function PostMatches(post)
    if post.mine then
        return true
    end
    if filterDungeon ~= nil and post.dungeon ~= filterDungeon then
        return false
    end
    if filterRole ~= nil and (post.need[filterRole] or 0) <= 0 then
        return false
    end
    return true
end

function G.GetPostRow(index)
    local area = panel.postArea
    local row = area.postRows[index]
    if row then
        return row
    end
    local width = area:GetWidth()
    row = CreateFrame("Frame", nil, area)
    row:SetSize(width, POST_ROW - 4)
    row:EnableMouse(true)
    row.bg = row:CreateTexture(nil, "BACKGROUND")
    row.bg:SetAllPoints(row)
    row.bg:SetColorTexture(1, 0.82, 0, 0.08)

    row.name = row:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
    row.name:SetPoint("TOPLEFT", 4, -4)
    row.name:SetWidth(134)
    row.name:SetJustifyH("LEFT")
    row.name:SetWordWrap(false)

    row.needs = row:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
    row.needs:SetPoint("TOPLEFT", 140, -3)
    row.needs:SetWidth(width - 140 - 210)
    row.needs:SetJustifyH("LEFT")
    row.needs:SetWordWrap(false)

    row.ask = DW.CreateButton(row, 120, 20, "gold")
    row.ask:SetPoint("TOPRIGHT", -4, -2)
    row.ask:SetScript("OnClick", function(self)
        if row.post then
            G.Ask(row.post, self)
        end
    end)
    row.ask:HookScript("OnEnter", function(self)
        G.AskTooltip(self, row.post)
    end)
    row.ask:HookScript("OnLeave", function()
        GameTooltip:Hide()
    end)

    row.whisper = DW.CreateChip(row, 70, 20)
    row.whisper:SetPoint("RIGHT", row.ask, "LEFT", -6, 0)
    row.whisper.label:SetJustifyH("CENTER")
    row.whisper:SetScript("OnClick", function()
        if row.member then
            DW.WhisperTo(row.member.key)
        end
    end)

    -- On your own post.
    row.edit = DW.CreateChip(row, 140, 20)
    row.edit:SetPoint("TOPRIGHT", -4, -2)
    row.edit.label:SetFontObject("GameFontHighlightSmall")
    row.edit.label:SetJustifyH("CENTER")
    row.edit:SetScript("OnClick", function()
        DW.OpenGroupForm()
    end)

    row.info = row:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    row.info:SetPoint("BOTTOMLEFT", 4, 4)
    row.info:SetWidth(width - 8)
    row.info:SetJustifyH("LEFT")
    row.info:SetWordWrap(false)

    row:SetScript("OnEnter", function(self)
        local post = self.post
        if not post then
            return
        end
        local dungeon = G.Dungeon(post.dungeon)
        GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
        GameTooltip:AddLine(self.member and self.member.name or G.NameOf(post.key))
        if self.member then
            GameTooltip:AddLine(tostring(self.member.level), 1, 1, 1)
        end
        if dungeon then
            GameTooltip:AddLine(dungeon.other and G.Title(dungeon, post.max) or DungeonLabel(dungeon), 1.00, 0.82, 0.00)
        end
        local has = G.HasText(post, true)
        if has ~= "" then
            GameTooltip:AddLine(L.DG_POST_HAS:format(has), 1, 1, 1)
        end
        GameTooltip:AddLine(L.DG_POST_NEEDS:format(G.NeedNames(post.need, true)), 1, 1, 1)
        if post.note ~= "" then
            GameTooltip:AddLine("\"" .. post.note .. "\"", 0.6, 0.6, 0.6, true)
        end
        local left = math.max(0, math.ceil((G.LIFETIME - (G.Now() - post.created)) / 60))
        GameTooltip:AddLine(L.DG_POST_CLOSES:format(left), 0.6, 0.6, 0.6)
        GameTooltip:Show()
    end)
    row:SetScript("OnLeave", function()
        GameTooltip:Hide()
    end)

    area.postRows[index] = row
    return row
end

function G.GetRequestRow(index)
    local area = panel.postArea
    local row = area.requestRows[index]
    if row then
        return row
    end
    local width = area:GetWidth()
    row = CreateFrame("Frame", nil, area)
    row:SetSize(width, REQUEST_ROW - 2)
    row.text = row:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    row.text:SetPoint("LEFT", 24, 0)
    row.text:SetWidth(width - 24 - 200)
    row.text:SetJustifyH("LEFT")
    row.text:SetWordWrap(false)
    row.no = DW.CreateChip(row, 80, 18)
    row.no:SetPoint("RIGHT", -4, 0)
    row.no.label:SetJustifyH("CENTER")
    row.no:SetScript("OnClick", function()
        G.Decline(row.request)
    end)
    -- 100 px rather than 80, so "Make raid" fits in every language.
    row.invite = DW.CreateButton(row, 100, 18, "gold")
    row.invite:SetPoint("RIGHT", row.no, "LEFT", -6, 0)
    row.invite:SetScript("OnClick", function()
        G.Invite(row.request)
    end)
    area.requestRows[index] = row
    return row
end

-- Fills the post area and returns its height (0 when hidden). shownMembers
-- is how many member rows follow under it.
function G.RefreshPosts(shownMembers)
    local area = panel.postArea
    local posts = {}
    for _, found in ipairs(G.AlivePosts()) do
        if PostMatches(found.post) then
            posts[#posts + 1] = found
        end
    end
    local postIndex, requestIndex = 0, 0
    local y = 0
    if #posts > 0 then
        area.postsHeader:SetText(L.DG_POSTS_HEADER:format(#posts))
        y = HEADER_ROW
        local now = G.Now()
        for _, found in ipairs(posts) do
            local post, member = found.post, found.member
            postIndex = postIndex + 1
            local row = G.GetPostRow(postIndex)
            row.post, row.member = post, member
            row:ClearAllPoints()
            row:SetPoint("TOPLEFT", 0, -y)
            y = y + POST_ROW
            local name = member and member.name or G.NameOf(post.key)
            local colour = member and RAID_CLASS_COLORS and RAID_CLASS_COLORS[member.class]
            row.name:SetText(post.mine and L.DG_ME:format(name) or name)
            if colour then
                row.name:SetTextColor(colour.r, colour.g, colour.b)
            else
                row.name:SetTextColor(1, 1, 1)
            end
            row.needs:SetText(L.DG_POST_NEEDS:format(G.NeedIcons(post.need, 16)))
            local parts = { "|cffffd100" .. G.Title(G.Dungeon(post.dungeon), post.max) .. "|r" }
            local has = G.HasText(post)
            if has ~= "" then
                parts[#parts + 1] = L.DG_POST_HAS:format(has)
            end
            parts[#parts + 1] = L.DG_POST_SIZE:format(post.size, post.max)
            if post.note ~= "" then
                parts[#parts + 1] = "|cff999999\"" .. post.note .. "\"|r"
            end
            parts[#parts + 1] = L.DG_POST_AGO:format(math.max(0, math.floor((now - post.created) / 60)))
            row.info:SetText(table.concat(parts, " - "))
            row.edit.label:SetText(L.DG_LEAD_EDIT)
            row.whisper.label:SetText(L.DG_WHISPER)
            row.edit:SetShown(post.mine == true)
            row.ask:SetShown(not post.mine)
            row.whisper:SetShown(not post.mine)
            if not post.mine then
                G.PaintAsk(row.ask, post)
            end
            row:Show()
            if post.mine then
                -- The requests to join, newest last.
                local requests = {}
                for _, request in pairs(G.requests) do
                    local state = G.RequestState(request)
                    if state == "new" or state == "invited" then
                        requests[#requests + 1] = request
                    end
                end
                table.sort(requests, function(a, b)
                    if a.at ~= b.at then
                        return a.at < b.at
                    end
                    return a.key < b.key
                end)
                for _, request in ipairs(requests) do
                    requestIndex = requestIndex + 1
                    local line = G.GetRequestRow(requestIndex)
                    line.request = request
                    line:ClearAllPoints()
                    line:SetPoint("TOPLEFT", 0, -y)
                    y = y + REQUEST_ROW
                    line.text:SetText(L.DG_REQ_LINE:format(request.name, request.level, G.RoleText(request.role),
                        math.max(0, math.floor((now - request.at) / 60))))
                    line.no.label:SetText(L.DG_TOAST_NO)
                    G.PaintInvite(line.invite, request)
                    line:Show()
                end
            end
        end
        area.membersHeader:ClearAllPoints()
        area.membersHeader:SetPoint("TOPLEFT", 4, -(y + 3))
        area.membersHeader:SetText(L.DG_MEMBERS_HEADER:format(shownMembers))
        y = y + HEADER_ROW
    end
    for index = postIndex + 1, #area.postRows do
        area.postRows[index].post, area.postRows[index].member = nil, nil
        area.postRows[index]:Hide()
    end
    for index = requestIndex + 1, #area.requestRows do
        area.requestRows[index].request = nil
        area.requestRows[index]:Hide()
    end
    area:SetHeight(math.max(1, y))
    area:SetShown(#posts > 0)
    return #posts > 0 and y or 0
end

-- The band under the top row: "Lead a group", or your own post.
function G.RefreshBand()
    local f = panel
    local entry = G.Mine()
    f.leadText:ClearAllPoints()
    if entry then
        local title = G.Title(G.Dungeon(entry.dungeon), G.SizeOf(entry))
        local left = math.max(0, math.ceil((G.LIFETIME - (G.Now() - entry.created)) / 60))
        f.lead.label:SetText(L.DG_LEAD_EDIT)
        f.leadStop.label:SetText(L.DG_LEAD_STOP)
        f.leadStop:Show()
        f.leadText:SetPoint("LEFT", f.leadStop, "RIGHT", 8, 0)
        f.leadText:SetWidth(f:GetWidth() - (14 + 150 + 6 + 110 + 8) - 14)
        f.leadText:SetText(L.DG_LEAD_MINE:format(title, G.NeedIcons(G.ParseNeed(entry.need), 16), left))
    else
        f.lead.label:SetText(L.DG_LEAD)
        f.leadStop:Hide()
        f.leadText:SetPoint("LEFT", f, "TOPLEFT", 172, -84)
        f.leadText:SetWidth(f:GetWidth() - 172 - 14)
        f.leadText:SetText(L.DG_LEAD_HINT)
    end
end

RefreshPanel = function()
    if not panel or not panel:IsVisible() then
        return
    end
    panel.title:SetText(L.DG_PANEL_TITLE)
    panel.mine.label:SetText(DW.GetMyStatus() == "D" and L.DG_CHANGE or L.DG_JOIN)
    local filtered = filterDungeon and G.Dungeon(filterDungeon)
    if not filtered then
        filterDungeon = nil
    end
    panel.filter.label:SetText(L.DG_FILTER:format(filtered and (filtered.other and L.DG_OTHER_GROUP or filtered.name) or L.DG_ALL))
    local role = filterRole and ROLE_BY_CODE[filterRole]
    panel.roleFilter.label:SetText(L.DG_ROLE_FILTER:format(role and (DW.RoleIcon(role) .. " " .. L[role.key]) or L.DG_ALL))
    panel.footer:SetText(L.DG_FOOTER)
    panel.toastLabel:SetText(L.DG_TOAST_SETTING)
    panel.toastCheck:SetChecked(not (type(G.db) == "table" and G.db.toast == false))
    G.RefreshBand()

    local shown, everyone = Collect()
    -- The posts come first; the member rows sit under them.
    local offset = G.RefreshPosts(#shown)
    for index, found in ipairs(shown) do
        local row = GetRow(index)
        local member = found.member
        local colour = RAID_CLASS_COLORS and RAID_CLASS_COLORS[member.class]
        row.found = found
        row:ClearAllPoints()
        row:SetPoint("TOPLEFT", 0, -(offset + (index - 1) * ROW_HEIGHT))
        row.name:SetText(found.me and L.DG_ME:format(member.name) or member.name)
        if colour then
            row.name:SetTextColor(colour.r, colour.g, colour.b)
        else
            row.name:SetTextColor(1, 1, 1)
        end
        row.roles:SetText(RoleIcons(found.entry.roles, 16))
        row.level:SetText(tostring(member.level))
        row.why:SetText(PurposesText(found.entry.purposes))
        row.dungeons:SetText(DungeonsText(found.entry.dungeons))
        row.whisper.label:SetText(L.DG_WHISPER)
        row.invite.label:SetText(L.DG_INVITE)
        row.whisper:SetShown(not found.me)
        row.invite:SetShown(not found.me)
        row.keep.label:SetText(L.DG_KEEP)
        row.keep:SetShown(found.me and DW.GetMyStatus() == "D")
        row:Show()
    end
    for index = #shown + 1, #rows do
        rows[index].found = nil
        rows[index]:Hide()
    end
    panel.content:SetHeight(math.max(1, offset + #shown * ROW_HEIGHT))

    if #everyone == 0 then
        panel.empty:SetText(L.DG_EMPTY)
    else
        panel.empty:SetText(L.DG_EMPTY_FILTER)
    end
    panel.empty:ClearAllPoints()
    if offset > 0 then
        panel.empty:SetPoint("TOP", panel.postArea, "BOTTOM", 0, -16)
    else
        panel.empty:SetPoint("TOP", panel.scroll, "TOP", 0, -40)
    end
    panel.empty:SetShown(#shown == 0)
end
G.RefreshPanel = function()
    RefreshPanel()
end

local refreshQueued = false

local function QueueRefresh()
    if refreshQueued or not panel or not panel:IsVisible() then
        return
    end
    refreshQueued = true
    C_Timer.After(0.25, function()
        refreshQueued = false
        RefreshPanel()
    end)
end

local function CreatePanel(parent)
    local f = CreateFrame("Frame", nil, parent)
    f:SetAllPoints(parent)
    panel = f

    f.title = f:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
    f.title:SetPoint("TOP", 0, -12)

    -- Join yourself, or change what you have chosen.
    f.mine = DW.CreateButton(f, 200, 26, "gold")
    f.mine:SetPoint("TOPLEFT", 14, -40)
    f.mine:SetScript("OnClick", function()
        DW.OpenDungeonPicker()
    end)

    -- Filter: only those who want to do a specific dungeon.
    f.filter = DW.CreateChip(f, 236, 26)
    f.filter:SetPoint("TOPRIGHT", -14, -40)
    f.filter:SetScript("OnClick", function(self)
        OpenFilterMenu(self)
    end)

    -- Filter: only those who can take a specific role.
    f.roleFilter = DW.CreateChip(f, 130, 26)
    f.roleFilter:SetPoint("RIGHT", f.filter, "LEFT", -8, 0)
    f.roleFilter:SetScript("OnClick", function(self)
        OpenRoleMenu(self)
    end)

    -- The band under the top row: lead a group, or your own post.
    f.lead = DW.CreateButton(f, 150, 24, "gold")
    f.lead:SetPoint("TOPLEFT", 14, -72)
    f.lead:SetScript("OnClick", function()
        DW.OpenGroupForm()
    end)
    f.leadStop = DW.CreateButton(f, 110, 24, "red")
    f.leadStop:SetPoint("LEFT", f.lead, "RIGHT", 6, 0)
    f.leadStop:SetScript("OnClick", function()
        G.Close("manual")
    end)
    f.leadText = f:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    f.leadText:SetJustifyH("LEFT")
    f.leadText:SetWordWrap(false)

    local scroll = CreateFrame("ScrollFrame", "DragonworldDungeonsScroll", f, "ScrollFrameTemplate")
    scroll:SetPoint("TOPLEFT", 10, -102)
    scroll:SetPoint("BOTTOMRIGHT", -30, 34)
    f.scroll = scroll
    f.content = CreateFrame("Frame", nil, scroll)
    f.content:SetSize(parent:GetWidth() - 10 - 30, 1)
    scroll:SetScrollChild(f.content)

    -- The group posts sit at the top of the scrolling list, above the members.
    local area = CreateFrame("Frame", nil, f.content)
    area:SetPoint("TOPLEFT", 0, 0)
    area:SetSize(f.content:GetWidth(), 1)
    area.postsHeader = area:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    area.postsHeader:SetPoint("TOPLEFT", 4, -3)
    area.membersHeader = area:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    area.postRows, area.requestRows = {}, {}
    area:Hide()
    f.postArea = area

    f.empty = f:CreateFontString(nil, "OVERLAY", "GameFontDisable")
    f.empty:SetPoint("TOP", scroll, "TOP", 0, -40)
    f.empty:SetWidth(420)

    f.footer = f:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    f.footer:SetPoint("BOTTOMLEFT", 14, 12)
    f.footer:SetPoint("BOTTOMRIGHT", -250, 12)
    f.footer:SetJustifyH("LEFT")
    f.footer:SetWordWrap(false)

    -- Pop-ups on or off.
    f.toastCheck = CreateFrame("CheckButton", nil, f, "UICheckButtonTemplate")
    f.toastCheck:SetSize(22, 22)
    f.toastCheck:SetPoint("BOTTOMRIGHT", -214, 7)
    f.toastLabel = f.toastCheck:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    f.toastLabel:SetPoint("LEFT", f.toastCheck, "RIGHT", 2, 0)
    f.toastLabel:SetWidth(198)
    f.toastLabel:SetJustifyH("LEFT")
    f.toastLabel:SetWordWrap(false)
    f.toastCheck:SetScript("OnClick", function(self)
        if type(G.db) == "table" then
            -- nil = on (the default), false = off.
            if self:GetChecked() then
                G.db.toast = nil
            else
                G.db.toast = false
            end
        end
    end)

    f:SetScript("OnShow", function()
        -- Ask the game for a fresh member list, so "online" is correct.
        if C_GuildInfo and C_GuildInfo.GuildRoster then
            C_GuildInfo.GuildRoster()
        end
        RefreshPanel()
    end)
    return f
end

OpenTab = function()
    if DW.OpenModule then
        DW.OpenModule(MODULE_ID)
    end
end

-- Events ----------------------------------------------------------------------

local frame = CreateFrame("Frame")
frame:SetScript("OnEvent", function(self, event)
    if not DW.IsMember() then
        return
    end
    if event == "GROUP_ROSTER_UPDATE" then
        G.OnGroupChanged()
    elseif event == "PLAYER_REGEN_ENABLED" then
        -- Pop-ups held back during combat.
        G.ShowNext()
    elseif event == "PLAYER_ENTERING_WORLD" then
        G.PlanHello()
    else
        QueueRefresh()
    end
end)
for _, event in ipairs({ "GUILD_ROSTER_UPDATE", "GROUP_ROSTER_UPDATE", "PLAYER_REGEN_ENABLED", "PLAYER_ENTERING_WORLD" }) do
    pcall(frame.RegisterEvent, frame, event)
end

DW.OnMembershipChanged(function(member)
    if member then
        G.PlanHello()
    end
end)

DW.OnStatusChanged(function()
    QueueRefresh()
    RefreshPicker()
end)

DW.OnLanguageChanged(function()
    RefreshPanel()
    RefreshPicker()
    G.RefreshForm()
    G.RefreshToast()
end)

-- Module -------------------------------------------------------------------------

DW.RegisterModule({
    id = MODULE_ID,
    titleKey = "DG_TITLE",
    notesKey = "DG_NOTES",
    icon = "Interface\\Icons\\Ability_DualWield",

    -- Saved: mine (your own open post per character), toast, toastPos.
    -- Broken entries are dropped; old ones go at the hello.
    OnLoad = function(self, db)
        G.db = db
        if type(db.mine) ~= "table" then
            db.mine = {}
        end
        for key, entry in pairs(db.mine) do
            if type(key) ~= "string" or not G.ValidSaved(entry) then
                db.mine[key] = nil
            else
                if type(entry.known) ~= "table" then
                    entry.known = {}
                end
                if type(entry.counted) ~= "table" then
                    -- Saved without it: those it knew are already counted.
                    entry.counted = {}
                    for guid in pairs(entry.known) do
                        entry.counted[guid] = true
                    end
                end
            end
        end
        if db.toast ~= false then
            db.toast = nil
        end
        if db.toastPos ~= nil and not G.SavedToastPos() then
            db.toastPos = nil
        end
    end,

    CreatePanel = function(self, parent)
        return CreatePanel(parent)
    end,
})

-- Debugging.
DW.AddDebug("grupper", function(add)
    local entry = G.Mine()
    if entry then
        local states, known = {}, 0
        for _, request in pairs(G.requests) do
            local state = G.RequestState(request)
            states[state] = (states[state] or 0) + 1
        end
        for _ in pairs(entry.known or {}) do
            known = known + 1
        end
        add(("min post: %s %d | trenger %s | har %s | størrelse %d/%d | kjente %d | forespørsler ny %d, invitert %d, avslått %d, med %d"):format(
            DW.DebugText(G.MyKey()), entry.created, entry.need, entry.haveCount or DW.DebugText(entry.have), entry.size or 0, G.SizeOf(entry), known,
            states.new or 0, states.invited or 0, states.declined or 0, states.joined or 0))
    else
        add("min post: ingen")
    end
    local count, toasted = 0, 0
    for key, post in pairs(G.posts) do
        count = count + 1
        if count <= 10 then
            add(("  %s: %d %s %s/%s%s"):format(key, post.dungeon, G.NeedText(post.need), post.size, post.max, G.Alive(post) and "" or " (stengt)"))
        end
    end
    for _ in pairs(G.toastedLeader) do
        toasted = toasted + 1
    end
    add(("andres poster: %d | pop-up-ledere: %d | kø: %d"):format(count, toasted, #G.queue))
    local inside, itype = nil, nil
    if IsInInstance then
        local ok, a, b = pcall(IsInInstance)
        if ok then
            inside, itype = a, b
        end
    end
    add("IsInInstance: " .. DW.DebugText(IsInInstance ~= nil) .. " " .. DW.DebugText(inside) .. " " .. DW.DebugText(itype)
        .. " | GetNumGroupMembers: " .. DW.DebugText(GetNumGroupMembers ~= nil) .. " " .. DW.DebugText(PlainValue(GetNumGroupMembers))
        .. " | IsInRaid: " .. DW.DebugText(IsInRaid ~= nil) .. " " .. DW.DebugText(PlainValue(IsInRaid)))
end)

-- The buttons blink (Alerts.lua) when someone else is open to a dungeon that
-- fits your level (2 levels of leeway), or has not chosen any, and you
-- have not opened the tab since. If you yourself are set to "Do not disturb",
-- it does not blink.
local SLACK = 2

local function WantsMyLevel(entry)
    local level = MyLevel()
    if level <= 0 or not entry.dungeons or next(entry.dungeons) == nil then
        return true
    end
    for id in pairs(entry.dungeons) do
        local dungeon = DW.DUNGEON_BY_ID[id]
        if dungeon and level >= dungeon.min - SLACK and level <= dungeon.max + SLACK then
            return true
        end
    end
    return false
end

-- Those who are new since the time since: { { member, entry }, ... }.
local function NewWishes(since)
    local list = {}
    if DW.GetMyStatus() == "C" then
        return list
    end
    for _, found in ipairs(DW.MembersWithStatus("D")) do
        local entry = found.entry
        -- entry.since: when they opened (a renewed hour is not new).
        if not IsMe(found.member) and entry and (entry.since or entry.time or 0) > since and WantsMyLevel(entry) then
            list[#list + 1] = found
        end
    end
    return list
end

-- One line in the list at the button: who, and those of their dungeons that fit
-- your level (at most three), and why.
local function WishLine(found)
    local entry, level = found.entry, MyLevel()
    local names = {}
    for _, dungeon in ipairs(DW.DUNGEONS) do
        if entry.dungeons and entry.dungeons[dungeon.id] and level >= dungeon.min - SLACK and level <= dungeon.max + SLACK then
            names[#names + 1] = dungeon.name
        end
    end
    local who = found.member.name
    if next(entry.roles or {}) then
        who = who .. " " .. RoleIcons(entry.roles)
    end
    if #names == 0 then
        return L.AL_DUNGEON_ANY:format(who)
    end
    if #names > 3 then
        names = { names[1], names[2], names[3], "+" .. (#names - 3) }
    end
    local text = L.AL_DUNGEON_ITEM:format(who, table.concat(names, ", "))
    if entry.purposes and next(entry.purposes) then
        text = text .. " (" .. PurposesText(entry.purposes) .. ")"
    end
    return text
end

DW.RegisterAlert({
    kind = "dungeon",
    module = MODULE_ID,
    labelKey = "AL_DUNGEON",
    color = { 0.30, 1.00, 0.45 }, -- green
    -- Also group posts that fit you, and requests to join your own post
    -- (those are not muted by "Do not disturb").
    Check = function(since)
        return #NewWishes(since) > 0 or #G.FittingPosts(since) > 0 or #G.NewRequests(since) > 0
    end,
    Items = function(since)
        local items = {}
        for _, request in ipairs(G.NewRequests(since)) do
            items[#items + 1] = L.AL_GROUP_REQUEST:format(request.name, G.RoleText(request.role))
        end
        for _, post in ipairs(G.FittingPosts(since)) do
            items[#items + 1] = L.AL_GROUP_ITEM:format(G.NameOf(post.key), G.Title(G.Dungeon(post.dungeon), post.max), G.NeedIcons(post.need))
        end
        for _, found in ipairs(NewWishes(since)) do
            items[#items + 1] = WishLine(found)
        end
        return items
    end,
})
