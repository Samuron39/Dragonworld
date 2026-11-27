-- Dragonworld - Achievements
--
-- Two things:
--   1. Milestones. When someone in the guild reaches level 20, 30, 40, 50 or
--      60, 300 (the maximum) in a profession, or completes a Legacy
--      Challenge, a banner appears at the top of the screen for everyone who
--      is online and has the addon: "GUILD MILESTONE! Gyongy Fa reached level 60!",
--      with a Gratz button that congratulates in guild chat. All milestones
--      are also listed in the tab, newest first.
--   2. Guild achievements. Shared goals for the whole guild (five at level 60,
--      50 members, 300 in all crafts ...), with how far you have come.
--      If a goal is reached while you are online, a banner appears for that
--      too.
--   3. New members. When someone joins the guild, everyone online with the
--      addon gets a banner "NEW MEMBER! Welcome to Dragonworld, <name>!" with a
--      Welcome! button that greets them in guild chat. The member who sent
--      the invite also gets a button that whispers the address of the addon.
--      Each join is also a line in the list. This sends no addon messages:
--      the game's own system message ("X has joined the guild.") is the live
--      signal, and the roster is the fallback. Who invited is known only
--      locally: from the hook on C_GuildInfo.Invite and from the game's
--      "You have invited X to join your guild." message.
--   4. Guild firsts. The first time the guild (any group with at least one
--      member who has the addon) kills the last boss of a dungeon or any
--      raid boss, everyone online gets a "GUILD FIRST!" banner with the guild
--      members of that group, and it becomes a line in the list. The game
--      reports the kill with ENCOUNTER_END / BOSS_KILL; in a raid where it
--      does not, the raid lockout is the fallback. The names in the group
--      can be hidden during the fight, so they are read just after it.
--      Kills from before the addon are not known.
--
-- Where the milestones come from:
--   * The one who reaches a milestone announces it themselves (message M) as
--     it happens. This is the only source for professions and legacy, and it
--     gives the exact time.
--   * Legacy Challenges are the game's achievements in new clothes (Blizzard's
--     own Legacy window is built on GetCategoryList/GetAchievementInfo). The
--     game reports ACHIEVEMENT_EARNED when one is completed; name,
--     description and icon are read with GetAchievementInfo, and the legacy
--     points it gives with C_Traits.GetTraitCurrencyForAchievement(4225, id).
--     Nothing is listed by hand, so new challenges are picked up on their
--     own. One that was already completed on the account (an alt) is not
--     announced.
--   * For level the addon also looks at the game's roster. If a member has
--     passed a milestone since last time, it has been reached, even if the
--     member does not have the addon. It gives a banner only when the member
--     is online and we saw them earlier in the same session; otherwise it
--     happened while you were away, and it only becomes a line in the list.
--     The game updates the roster when someone asks for it (the guild
--     window, the Roster tab etc.); the addon does not ask all the time.
--   * On login the addon asks the others for milestones since last time (R),
--     and each replies with their own. That gives the list the right time for
--     those who have the addon.
--
-- Messages (name DragonworldAch, fields separated by tab):
--   M key time L level name class                    level milestone (20-60)
--   M key time P skill name class line name          profession (300)
--   M key time A points name class id title          legacy challenge (id = achievement)
--   R [time]                                         send me your milestones after time
--   F key time type enc map count boss instance names    a guild first (see below)
-- "line" is the game's number for the profession (164 = Blacksmithing), the
-- same in all clients; the last field is the name as the sender's client
-- spells it.
-- For legacy, id is the game's number for the challenge; the receiver looks
-- up the name in their own language and uses the title only if the game does
-- not know it.
-- For F, key is "d" and the dungeon's number in DW.DUNGEONS (type D), "e" and
-- the encounter's number (a raid boss, type R), or "L" map "." boss number
-- (a raid boss seen only in the raid lockout, type R). enc is the encounter's
-- number (0 for L), map the instance's map number, count how many guild
-- members were in the group, and names (comma-separated) as many of them as
-- fit in the message. A group member sends it once, just after the kill. An
-- F about a kill in the last 15 minutes must come from one of the names; an
-- older one is a catch-up answer to R, sent by anyone who has it.
--
-- The guild achievements are calculated from the roster (all members) and
-- from professions shared by those who have the addon (the Roster tab).
-- They are not sent; each addon calculates them itself. If one is completed
-- while you are online, and it happened just now (a milestone, a new member),
-- the banner appears. Anything already completed the first time the addon
-- looked counts as "before the addon".
--
-- All text is in Locales.lua (the names that start with ACH_).

local ADDON_NAME, DW = ...
local L = DW.L

local MODULE_ID = "achievements"
local PREFIX = "DragonworldAch" -- the name of the messages; max 16 characters
local SEP = "\t"

local LEVELS = { 20, 30, 40, 50, 60 } -- the level milestones
local PROF_MAX = 300                   -- the maximum in a profession
local FEED_MAX = 300                   -- this many milestones are remembered
local LIVE_SECONDS = 15 * 60           -- a message about a milestone newer than this gives a banner
local LIVE_WINDOW = 30                 -- how long after something happens now a completed guild achievement gives a banner
local GRATZ_HOURS = 3                  -- Gratz button in the list for milestones newer than this
local HELLO_DELAY = 12                 -- after login
local BANNER_SECONDS = 12              -- how long the banner stays (longer while the mouse is over it)
local QUEUE_MAX = 6
local REPLY_MAX = 15

local TITLE_FONT = "Fonts\\MORPHEUS.TTF"
local TEXT_FONT = "Fonts\\FRIZQT__.TTF"
local SPARKLE = "Interface\\Cooldown\\star4"
local QUESTION = "Interface\\Icons\\INV_Misc_QuestionMark"
local LEGACY_CURRENCY = 4225           -- the legacy points as a talent currency (see Profile.lua)
local LEGACY_ICON = "Interface\\Icons\\Spell_Holy_ChampionsBond"

-- New members.
local INVITE_KEEP = 3600               -- an invite you sent counts for this long
local REJOIN_AFTER = 86400             -- someone who joins again after this gets a new welcome
local RECENT_JOIN = 600                -- a join from the system message is not counted again from the roster
local INVITER_SECONDS = 30             -- how long the inviter's banner stays
local JOIN_KEEP = 50                   -- this many joins are kept in the list
local LINK_SECONDS = 86400             -- the inviter's "Addon link" button in the list

-- Saved (for the whole account). Set in OnLoad at the bottom.
--   db.feed[id]     = { id, who, name, class, kind = "L"/"P"/"A"/"J", value, line, prof,
--                       time, exact, bannered, gratz, sent }
--                     J (joined the guild) also has invited (you sent the
--                     invite), linkSent (you whispered the addon link) and
--                     target (the name to whisper)
--                     who is the player's permanent ID (or "name:" and the name);
--                     for P, line is the profession's number and prof the name;
--                     for A, line is the challenge's number, prof the title and
--                     value the points;
--                     exact = the time came from the one who reached the milestone
--   db.levels[key]  = level last seen in the roster
--   db.mine[key]    = { [profession] = skill } own professions last seen
--   db.guild[id]    = { time } or { before = true } when a guild achievement was reached
--   db.guildInit    = true once the addon has looked once
--   db.banner, db.sound = false when the player has turned them off
--   db.newsBanner   = false when banners for announcements and polls are turned off
--   db.bannerPos    = { point, point, x, y } if the banner has been moved
--   db.invites[nameKey] = server time you invited that player to the guild
--   db.joinInit     = true once the roster has been read, so later members are new
--   db.welcome      = false when the welcome banner for new members is turned off
--   db.firsts[key]  = { key, kind = "F", type = "D"/"R", enc, map, boss, instance,
--                       names, count, time, heardAt, mine, bannered, gratz, sent,
--                       heard, id = "F:" .. key }   a guild first (see Messages);
--                     heardAt = when it was first stored here, mine = you were
--                     in the group, sent = you sent it, heard = someone else did,
--                     trusted = your own, or told by someone in its names.
--                     Not pruned; no new ones past 200.
--   db.bossLog[encounterID] = { name, map, type, n, last, result } the last 60
--                     boss kills seen here (for /dw debug); result is the
--                     first's key, "raid" or "none"
--   db.raidEventSeen = true once the game reported a boss kill inside a raid
--                     (then the raid lockout fallback is no longer needed)
local db = { feed = {}, levels = {}, mine = {}, guild = {}, invites = {}, firsts = {}, bossLog = {} }

-- Small things ------------------------------------------------------------------

local function Num(value)
    if type(value) == "number" and not DW.IsSecret(value) then
        return value
    end
    return nil
end

local function Text(value)
    if type(value) == "string" and not DW.IsSecret(value) then
        return value
    end
    return ""
end

local function Now()
    return DW.ServerNow()
end

-- A name without characters used as separators or color codes.
local function CleanName(text)
    text = Text(text):gsub("[%c|]", " ")
    text = text:gsub("^%s+", "")
    text = text:gsub("%s+$", "")
    return text:sub(1, 40)
end

local function KeyOf(guid, name)
    if type(guid) == "string" and guid:find("^Player%-") then
        return guid
    end
    return "name:" .. DW.NameKey(name)
end

local function IsLevelMilestone(value)
    for _, level in ipairs(LEVELS) do
        if level == value then
            return true
        end
    end
    return false
end

-- The roster as of the last time we read it, to find a member again.
local rosterByGuid, rosterByName = {}, {}

-- The key we store a player under. If the game's roster has no permanent
-- IDs, the name is used, so the same member does not get two keys.
local function Canonical(key, name)
    local member = rosterByName[DW.NameKey(name)]
    if type(key) == "string" and key:find("^Player%-") and (rosterByGuid[key] or not member) then
        return key
    end
    if member then
        return KeyOf(member.guid, member.key)
    end
    return key
end

-- The key we send about ourselves (the permanent ID), and the name.
local function MySendKey()
    local _, name = DW.CharacterKey()
    if not name then
        return nil
    end
    return KeyOf(DW.MyGUID(), name), name
end

local function MyKey()
    local key, name = MySendKey()
    if not key then
        return nil
    end
    return Canonical(key, name), name
end

local function MyClass()
    if type(UnitClass) ~= "function" then
        return ""
    end
    local class = select(2, UnitClass("player"))
    return Text(class):match("^[A-Z]+$") or ""
end

-- Professions -------------------------------------------------------------------

-- The game's number for each profession, the name in English clients, which
-- group it belongs to, and an icon (the Professions tab has its own icons for
-- most of them, see ProfessionIcon).
local PROFESSIONS = {
    [171] = { "Alchemy", "craft", "Interface\\Icons\\Trade_Alchemy" },
    [164] = { "Blacksmithing", "craft", "Interface\\Icons\\Trade_BlackSmithing" },
    [333] = { "Enchanting", "craft", "Interface\\Icons\\Trade_Engraving" },
    [202] = { "Engineering", "craft", "Interface\\Icons\\Trade_Engineering" },
    [165] = { "Leatherworking", "craft", "Interface\\Icons\\INV_Misc_ArmorKit_17" },
    [197] = { "Tailoring", "craft", "Interface\\Icons\\Trade_Tailoring" },
    [186] = { "Mining", "gather", "Interface\\Icons\\Trade_Mining" },
    [182] = { "Herbalism", "gather", "Interface\\Icons\\Spell_Nature_NatureTouchGrow" },
    [393] = { "Skinning", "gather", "Interface\\Icons\\INV_Misc_Pelt_Wolf_01" },
    [185] = { "Cooking", "secondary", "Interface\\Icons\\INV_Misc_Food_15" },
    [129] = { "First Aid", "secondary", "Interface\\Icons\\Spell_Holy_SealOfSacrifice" },
    [356] = { "Fishing", "secondary", "Interface\\Icons\\Trade_Fishing" },
}
-- The order they are shown in (in tooltips).
local PROFESSION_ORDER = { 171, 164, 333, 202, 165, 197, 186, 182, 393, 185, 129, 356 }

local LINE_BY_NAME = { smelting = 186 } -- the Mining window can be called Smelting
for line, profession in pairs(PROFESSIONS) do
    LINE_BY_NAME[profession[1]:lower()] = line
end

-- The number of a profession, from the number we got or the name.
local function LineOf(name, line)
    line = line ~= nil and tonumber(line) or nil
    if line and line > 0 and line < 100000 then
        return math.floor(line)
    end
    return LINE_BY_NAME[Text(name):lower()]
end

-- The name as this client spells it.
local function ProfessionName(line, fallback)
    if line and C_TradeSkillUI and type(C_TradeSkillUI.GetProfessionInfoBySkillLineID) == "function" then
        local ok, info = pcall(C_TradeSkillUI.GetProfessionInfoBySkillLineID, line)
        if ok and type(info) == "table" and Text(info.professionName) ~= "" then
            return info.professionName
        end
    end
    if line and PROFESSIONS[line] then
        return PROFESSIONS[line][1]
    end
    if Text(fallback) ~= "" then
        return fallback
    end
    return "?"
end

local function ProfessionIcon(line)
    local data = DW.ProfessionData and DW.ProfessionData.professions and DW.ProfessionData.professions[line]
    if data and data.icon then
        return data.icon
    end
    return line and PROFESSIONS[line] and PROFESSIONS[line][3] or QUESTION
end

local function LevelIcon(level)
    return "Interface\\Icons\\Achievement_Level_" .. level
end

-- Guild firsts: the bosses ----------------------------------------------------------

-- Everything about guild firsts lives in this one table (data, session memory
-- and functions), so the file stays under Lua's limit of 200 local names.
local Firsts = {
    -- The last boss of each dungeon in DW.DUNGEONS: { English name, encounter IDs ... }.
    -- IDs from ForeverDungeonJournal's RunLogEncounters (build 1.60.1.70862);
    -- 2747, 2755, 2910, 2760, 592 and 3482 were seen in the game.
    END_BOSSES = {
        [1] = { "Durgen Dirgehammer", 3496 },
        [2] = { "Bazzalan", 433, 2735 },
        [3] = { "Rath'mael", 3354 },
        [4] = { "Edwin VanCleef", 167, 2747 },
        [5] = { "Mutanus the Devourer", 592 },
        [6] = { "Archmage Arugal", 471, 2755 },
        [7] = { "Aku'mai", 226, 2767, 2910 },
        [8] = { "Bazil Thredd", 2760 },
        [9] = { "Relic Guardian", 3482 },
        [10] = { "Shade of the Archmage", 3303 },
        [11] = { "Mekgineer Thermaplugg", 382 },
        [12] = { "Charlga Razorflank", 443, 2778 },
        [13] = { "Bloodmage Thalnos", 445 },
        [14] = { "Arcanist Doan", 447 },
        [15] = { "Min'loth the Serpent", 3479 },
        [16] = { "Herod", 448 },
        [17] = { "High Inquisitor Whitemane", 450 },
        [18] = { "Amnennar the Coldbringer", 437, 2785 },
        [19] = { "Overlord Mugg", 3451 },
        [20] = { "Archaedas", 554 },
        [21] = { "Chief Ukorz Sandscalp", 600 },
        [22] = { "Princess Theradras", 429 },
        [23] = { "Blazeroar", 3409 },
        [24] = { "Shade of Eranikus", 493, 492 },
        [25] = { "Emperor Dagran Thaurissan", 245 },
        [26] = { "Overlord Wyrmthalak", 275 },
        [27] = { "General Drakkisath", 280, 3069 },
        [28] = { "Alzzin the Wildshaper", 346 },
        [29] = { "Prince Tortheldrin", 361 },
        [30] = { "King Gordok", 368 },
        [31] = { "Varrox Bleakhoof", 3334 },
        [32] = { "Balnazzar", 478 },
        [33] = { "Baron Rivendare", 484 },
        [34] = { "Darkmaster Gandling", 2801 },
        [35] = { "Nanaya", 3502 },
    },
    -- Raid map IDs -> the raid in DW.DUNGEONS, for its English name (Molten Core, Onyxia's Lair).
    RAID_NAMES = { [409] = 101, [249] = 102 },
    ICON_DUNGEON = "Interface\\Icons\\INV_Misc_Bone_HumanSkull_01",
    ICON_RAID = "Interface\\Icons\\INV_Misc_Head_Dragon_Black",
    MAX = 200,          -- past this many, only a first told by someone who was there is stored (pushing out one that was not)
    LIVE_PER_SENDER = 12, -- live guild-first banners one sender may give in an hour
    liveFrom = {},      -- [DW.IdentityKey(sender)] = { GetTime() of each live first from them } (session)
    LOG_MAX = 60,       -- boss kills remembered for /dw debug
    PENDING_MAX = 10,   -- kills waiting for the end of the fight
    WAIT_MAX = 20,      -- kills waiting for the login sync to finish
    SAME_KILL = 30,     -- ENCOUNTER_END and BOSS_KILL for the same boss within this many seconds are one kill
    LOCK_SAME = 120,    -- a lockout change this soon after a reported kill of that boss is the same kill
    SETTLE = 30,        -- seconds after the hello before a kill can count as a first
    REPLY_MAX = 20,     -- firsts sent in a catch-up answer
    BATCH = 5,          -- ...this many at a time
    WORDS = { first = true, boss = true }, -- "/dw achievements first" shows an example

    byEncounter = {},   -- [encounterID] = dungeon number, for the last bosses
    byName = {},        -- [lower-case English name] = dungeon number

    -- Session memory.
    signals = { ee = 0, bk = 0, hidden = 0, lock = 0, deferred = 0 }, -- what the game reported, for /dw debug
    lastKillAt = {},     -- [encounterID] = GetTime() of the last kill counted
    lastKillByName = {}, -- [lower-case name] = GetTime() of the last reported kill
    pendingKills = {},   -- kills waiting for the names in the group
    pendingFirsts = {},  -- kills waiting for the login sync: { rec, position }
    heard = 0,           -- F messages heard from others this session
    lockSnap = {},       -- [boss number] = true for bosses killed in the raid lockout when we looked
    -- lockMap (raid map ID the lockout is watched for), lockTotal (bosses in the
    -- lockout at that read), fightEndAt (GetTime() of the last PLAYER_REGEN_ENABLED),
    -- helloAt (GetTime() of the hello)
}

-- The guild-first rules only accept times from after this (server time).
-- 2026-11-22 00:00 UTC, the day guild firsts were added. On DW so the tests can move it.
DW.FIRSTS_EPOCH = 1795305600

for dungeonID, boss in pairs(Firsts.END_BOSSES) do
    local dungeon = DW.DUNGEON_BY_ID and DW.DUNGEON_BY_ID[dungeonID]
    if dungeon and not dungeon.raid then
        Firsts.byName[boss[1]:lower()] = dungeonID
        for index = 2, #boss do
            Firsts.byEncounter[boss[index]] = dungeonID
        end
    end
end

-- Legacy Challenges -----------------------------------------------------------------

-- What the game knows about a challenge (an achievement): { name, description, icon, isGuild }.
local function ChallengeInfo(id)
    if not id or type(GetAchievementInfo) ~= "function" then
        return nil
    end
    local ok, foundID, name, _, _, _, _, _, description, _, icon, _, isGuild = pcall(GetAchievementInfo, id)
    if not ok or Num(foundID) ~= id or Text(name) == "" then
        return nil
    end
    local picture = Num(icon) or (Text(icon) ~= "" and icon) or nil
    return { name = name, description = Text(description), icon = picture, isGuild = isGuild == true }
end

-- The legacy points a challenge gives, or nil if the game does not say.
local function ChallengePoints(id)
    local get = C_Traits and C_Traits.GetTraitCurrencyForAchievement
    if not id or type(get) ~= "function" then
        return nil
    end
    local ok, points = pcall(get, LEGACY_CURRENCY, id)
    points = ok and Num(points)
    if points and points >= 0 and points < 1000 then
        return math.floor(points)
    end
    return nil
end

-- The name of a challenge in your language, otherwise what the sender wrote.
local function ChallengeTitle(entry)
    local info = ChallengeInfo(entry.line)
    if info then
        return info.name
    end
    return Text(entry.prof) ~= "" and entry.prof or "?"
end

-- Milestones ----------------------------------------------------------------------

local function EntryID(entry)
    if entry.kind == "L" then
        return entry.who .. ":L" .. entry.value
    elseif entry.kind == "A" then
        return entry.who .. ":A" .. tostring(entry.line)
    elseif entry.kind == "J" then
        return entry.who .. ":J"
    end
    return entry.who .. ":P" .. tostring(entry.line or Text(entry.prof):lower())
end

-- What the milestone is, without colors: "level 60", "300 i Blacksmithing" or
-- "legacy-utfordringen Master Druid (+1)".
local function WhatText(entry)
    if entry.kind == "L" then
        return L.ACH_LEVEL:format(entry.value)
    elseif entry.kind == "A" then
        if (entry.value or 0) > 0 then
            return L.ACH_CHALLENGE:format(ChallengeTitle(entry), entry.value)
        end
        return L.ACH_CHALLENGE_PLAIN:format(ChallengeTitle(entry))
    end
    return L.ACH_PROFESSION:format(entry.value, ProfessionName(entry.line, entry.prof))
end

-- The texts for "reached" or, for legacy, "completed".
local function Wording(entry)
    if entry.kind == "A" then
        return L.ACH_BANNER_OTHER_DONE, L.ACH_BANNER_YOU_DONE, L.ACH_ROW_DONE
    end
    return L.ACH_BANNER_OTHER, L.ACH_BANNER_YOU, L.ACH_ROW
end

local function EntryIcon(entry)
    if entry.kind == "L" then
        return LevelIcon(entry.value)
    elseif entry.kind == "A" then
        local info = ChallengeInfo(entry.line)
        return info and info.icon or LEGACY_ICON
    elseif entry.kind == "J" then
        return DW.ICON
    elseif entry.kind == "F" then
        return entry.type == "R" and Firsts.ICON_RAID or Firsts.ICON_DUNGEON
    end
    return ProfessionIcon(entry.line)
end

local function ClassName(name, class)
    local colour = RAID_CLASS_COLORS and RAID_CLASS_COLORS[class]
    if colour and colour.r then
        local function Byte(value)
            return math.floor(math.max(0, math.min(1, value)) * 255 + 0.5)
        end
        return ("|cff%02x%02x%02x%s|r"):format(Byte(colour.r), Byte(colour.g), Byte(colour.b), name)
    end
    return name
end

local function Gold(text)
    return "|cffffd100" .. text .. "|r"
end

-- Who killed a guild first: "Altine, Borin, Dagny" or "Altine, Borin, Dagny
-- and 5 more", in the class colours when coloured.
local function WhoText(entry, coloured)
    local names = type(entry.names) == "table" and entry.names or {}
    local shown = {}
    for index = 1, math.min(3, #names) do
        local name = Text(names[index])
        if coloured then
            local member = rosterByName[DW.NameKey(name)]
            name = ClassName(name, member and member.class)
        end
        shown[#shown + 1] = name
    end
    local count = math.max(Num(entry.count) or 0, #names)
    if #shown == 0 then
        return tostring(count)
    end
    local list = table.concat(shown, ", ")
    if count > #shown then
        return L.ACH_FIRST_MORE:format(list, count - #shown)
    end
    return list
end

local function Newest(a, b)
    if (a.time or 0) ~= (b.time or 0) then
        return (a.time or 0) > (b.time or 0)
    end
    return tostring(a.id) < tostring(b.id)
end

-- Removes the oldest when the list gets too long. Joins and milestones each
-- have their own limit: the newest JOIN_KEEP joins and the newest FEED_MAX
-- milestones stay, so joins never push legacy challenges out, and a full
-- list of milestones never pushes the joins out.
local function Prune()
    local joins, others = {}, {}
    for _, entry in pairs(db.feed) do
        if entry.kind == "J" then
            joins[#joins + 1] = entry
        else
            others[#others + 1] = entry
        end
    end
    if #joins > JOIN_KEEP then
        table.sort(joins, Newest)
        for index = #joins, JOIN_KEEP + 1, -1 do
            db.feed[joins[index].id] = nil
        end
    end
    if #others > FEED_MAX then
        table.sort(others, Newest)
        for index = #others, FEED_MAX + 1, -1 do
            db.feed[others[index].id] = nil
        end
    end
end

-- Saves a milestone. If it already exists, it gets the time from the one who
-- reached it (exact), if we did not have that. Returns the entry and whether
-- it is new.
local function Remember(entry)
    entry.id = EntryID(entry)
    local old = db.feed[entry.id]
    if old then
        if entry.exact and (not old.exact or entry.time < (old.time or 0)) then
            old.time, old.exact = entry.time, true
        end
        if Text(entry.class) ~= "" then
            old.class = entry.class
        end
        return old, false
    end
    db.feed[entry.id] = entry
    Prune()
    return entry, true
end

-- The banner ----------------------------------------------------------------------

local banner
local queue = {}
local NextBanner

local function SendGuildChat(text)
    return DW.SendChat(text, "GUILD")
end

-- Congratulates in guild chat, once per milestone. A new member (J) is
-- greeted with one of three welcomes instead, in the clicker's language,
-- and a guild first (F) names the boss and the group.
local function Gratz(entry)
    if type(entry) ~= "table" or entry.gratz or entry.sample then
        return false
    end
    local text
    if entry.kind == "J" then
        local variant = math.min(3, math.floor(math.random() * 3) + 1)
        text = L["WEL_CHAT_" .. variant]:format(entry.name)
    elseif entry.kind == "F" then
        text = L.ACH_FIRST_GRATZ_CHAT:format(entry.boss, WhoText(entry, false))
    else
        local what = entry.kind == "A" and ChallengeTitle(entry) or WhatText(entry)
        text = L.ACH_GRATZ_CHAT:format(what, entry.name)
    end
    if SendGuildChat(text) then
        entry.gratz = true
        return true
    end
    return false
end

-- The sound the game uses when you get an achievement. Different clients know
-- it under different names (same lookup as DungeonJournal does), otherwise
-- another festive sound.
local soundKit
local function FanfareKit()
    if soundKit ~= nil then
        return soundKit
    end
    soundKit = false
    if type(SOUNDKIT) == "table" then
        local keys = {}
        for key, id in pairs(SOUNDKIT) do
            local name = tostring(key)
            if type(id) == "number" and name:find("ACHIEVEMENT") and (name:find("GAIN") or name:find("EARN") or name:find("ALERT") or name:find("TOAST")) then
                keys[#keys + 1] = name
            end
        end
        table.sort(keys)
        if keys[1] then
            soundKit = SOUNDKIT[keys[1]]
        elseif type(SOUNDKIT.LFG_REWARDS) == "number" then
            soundKit = SOUNDKIT.LFG_REWARDS
        end
    end
    if not soundKit then
        soundKit = 12891 -- "UI Alert AchievementGained"
    end
    return soundKit
end

-- The fanfare follows the Sound box. A custom banner (DW.ShowBanner) can ask
-- for a sound kit number of its own, which plays even with the box off, or
-- for silence with sound = false.
local function PlayFanfare(item)
    if type(PlaySound) ~= "function" then
        return
    end
    if item and item.kind == "custom" then
        if type(item.sound) == "number" then
            pcall(PlaySound, item.sound)
            return
        elseif item.sound == false then
            return
        end
    end
    if db.sound == false then
        return
    end
    pcall(PlaySound, FanfareKit())
end

-- The main button's size and place, as CreateBanner makes it. A custom banner
-- with two buttons moves it; FillBanner puts it back first.
local BUTTON_WIDTH, BUTTON_HEIGHT, BUTTON_X, BUTTON_Y = 150, 36, -28, -10

-- A custom banner's field: a string, or a function that returns one.
local function Resolve(value)
    if type(value) == "function" then
        local ok, result = pcall(value)
        value = ok and result or nil
    end
    if type(value) == "string" then
        return value
    end
    return ""
end

-- A custom banner's buttonActive / button2Active: true unless the function says false.
local function IsActive(fn)
    if type(fn) ~= "function" then
        return true
    end
    local ok, result = pcall(fn)
    return not (ok and result == false)
end

local function PlaceBanner()
    banner:ClearAllPoints()
    local pos = db.bannerPos
    if type(pos) == "table" and type(pos[1]) == "string" and type(pos[2]) == "string" and Num(pos[3]) and Num(pos[4]) then
        banner:SetPoint(pos[1], UIParent, pos[2], pos[3], pos[4])
    else
        banner:SetPoint("TOP", UIParent, "TOP", 0, -110)
    end
end

-- Writes the text for the banner shown now (also when the language changes).
local function FillBanner()
    local item = banner.item
    if not item then
        return
    end
    -- The default layout first: one button where CreateBanner put it, and the shield.
    local b = banner
    b.button:ClearAllPoints()
    b.button:SetSize(BUTTON_WIDTH, BUTTON_HEIGHT)
    b.button:SetPoint("RIGHT", BUTTON_X, BUTTON_Y)
    b.button:SetActive(true)
    b.button2:Hide()
    b.shield:SetTexture(DW.ICON)

    if item.kind == "custom" then
        b.title:SetText(Resolve(item.title))
        b.text:SetText(Resolve(item.text))
        b.button.label:SetText(Resolve(item.button))
        b.button:SetActive(IsActive(item.buttonActive))
        b.shield:SetTexture(item.icon or DW.ICON)
        if item.button2 ~= nil then
            b.button:ClearAllPoints()
            b.button:SetSize(150, 28)
            b.button:SetPoint("RIGHT", -28, 18)
            b.button2:ClearAllPoints()
            b.button2:SetSize(150, 28)
            b.button2:SetPoint("RIGHT", -28, -24)
            b.button2.label:SetText(Resolve(item.button2))
            b.button2:SetActive(IsActive(item.button2Active))
            b.button2:Show()
        end
        return
    end
    if item.kind == "guild" then
        local achievement = item.achievement
        banner.title:SetText(L.ACH_GUILD_BANNER)
        banner.text:SetText(Gold(L[achievement.name]) .. "\n" .. achievement.Describe())
        banner.button.label:SetText(L.ACH_HOORAY)
        return
    end
    local entry = item.entry
    local other, you = Wording(entry)
    banner.title:SetText(L.ACH_BANNER)
    if item.own then
        banner.text:SetText(you:format(Gold(WhatText(entry))))
        banner.button.label:SetText(L.ACH_HOORAY)
    else
        banner.text:SetText(other:format(ClassName(entry.name, entry.class), Gold(WhatText(entry))))
        banner.button.label:SetText(L.ACH_GRATZ)
    end
end

-- Closes the banner and shows the next one waiting.
local function FinishBanner()
    if banner then
        banner.item = nil
        banner:Hide()
    end
    if #queue > 0 and C_Timer and C_Timer.After then
        C_Timer.After(0.4, NextBanner)
    end
end

-- Writes the banner's text again if it is shown, e.g. after a custom
-- banner's data changed.
local function RefillBanner()
    if banner and banner:IsShown() then
        FillBanner()
    end
end

-- A click on one of a custom banner's buttons: returning true from the
-- handler keeps the banner open (with its text written again), otherwise it closes.
local function ClickCustom(item, handler)
    local keep = false
    if type(handler) == "function" then
        local ok, result = pcall(handler, item)
        keep = ok and result == true
    end
    if keep then
        RefillBanner()
    else
        FinishBanner()
    end
end

-- The banner fades in, a flash of light passes over it once, the stars in the
-- corners twinkle slowly, and after a while it fades out. If the mouse is
-- over it, it stays.
local function AnimateBanner(self, elapsed)
    self.age = self.age + elapsed
    local alpha = math.min(1, self.age / 0.35)
    if self.closing then
        self.fade = self.fade + elapsed
        alpha = math.max(0, 1 - self.fade / 0.6)
        if alpha <= 0 then
            FinishBanner()
            return
        end
    elseif not self.dragging and not (self.IsMouseOver and self:IsMouseOver()) then
        self.left = self.left - elapsed
        if self.left <= 0 then
            self.closing, self.fade = true, 0
        end
    end
    self:SetAlpha(alpha)

    local sweep = (self.age - 0.3) / 1.1
    if sweep > 0 and sweep < 1 then
        self.shine:SetAlpha(math.max(0, math.min(1, math.sin(sweep * math.pi) * 0.8)))
        self.shine:ClearAllPoints()
        self.shine:SetPoint("CENTER", self, "LEFT", -30 + sweep * (self:GetWidth() + 60), 0)
    else
        self.shine:SetAlpha(0)
    end
    for index, star in ipairs(self.stars) do
        star:SetAlpha(math.max(0, math.min(1, 0.45 + 0.45 * math.sin(self.age * 2.2 + index * 1.6))))
    end
end

local function CreateBanner()
    local b = CreateFrame("Frame", "DragonworldMilestoneBanner", UIParent, "BackdropTemplate")
    b:SetSize(660, 124)
    b:SetFrameStrata("HIGH")
    b:SetClampedToScreen(true)
    b:EnableMouse(true)
    b:SetMovable(true)
    b:RegisterForDrag("LeftButton")
    b:SetBackdrop({
        bgFile = "Interface\\Buttons\\WHITE8X8",
        edgeFile = "Interface\\DialogFrame\\UI-DialogBox-Gold-Border",
        edgeSize = 24,
        insets = { left = 6, right = 6, top = 6, bottom = 6 },
    })
    b:SetBackdropColor(0.07, 0.07, 0.09, 0.96)
    b:Hide()

    -- A faint golden tint inside the edge.
    local warm = b:CreateTexture(nil, "BACKGROUND", nil, 1)
    warm:SetPoint("TOPLEFT", 6, -6)
    warm:SetPoint("BOTTOMRIGHT", -6, 6)
    warm:SetColorTexture(1, 0.78, 0.25, 0.05)

    -- The guild shield on the left.
    b.shield = b:CreateTexture(nil, "ARTWORK")
    b.shield:SetSize(104, 104)
    b.shield:SetPoint("LEFT", 12, 0)
    b.shield:SetTexture(DW.ICON)

    b.title = b:CreateFontString(nil, "OVERLAY", "GameFontNormalHuge")
    b.title:SetPoint("TOPLEFT", 130, -18)
    b.title:SetPoint("RIGHT", -184, 0)
    b.title:SetJustifyH("LEFT")
    b.title:SetWordWrap(false)
    pcall(b.title.SetFont, b.title, TITLE_FONT, 32, "")
    b.title:SetTextColor(1.00, 0.86, 0.25)

    b.text = b:CreateFontString(nil, "OVERLAY", "GameFontHighlightLarge")
    b.text:SetPoint("TOPLEFT", b.title, "BOTTOMLEFT", 0, -8)
    b.text:SetPoint("RIGHT", -184, 0)
    b.text:SetJustifyH("LEFT")
    pcall(b.text.SetFont, b.text, TEXT_FONT, 17, "")
    b.text:SetTextColor(1, 1, 1)
    -- Room for three lines; more would run over the border.
    if b.text.SetMaxLines then
        b.text:SetMaxLines(3)
    end

    -- Gratz! (or Hurra! when it is about you or the whole guild).
    b.button = DW.CreateButton(b, BUTTON_WIDTH, BUTTON_HEIGHT, "gold")
    b.button:SetPoint("RIGHT", BUTTON_X, BUTTON_Y)
    b.button:SetScript("OnClick", function()
        local item = b.item
        if item and item.kind == "custom" then
            ClickCustom(item, item.onClick)
            return
        end
        if item and item.entry and not item.own then
            Gratz(item.entry)
        end
        FinishBanner()
    end)

    -- A second button, only for custom banners that ask for one (button2).
    b.button2 = DW.CreateButton(b, 150, 28, "gold")
    b.button2:SetPoint("RIGHT", -28, -24)
    b.button2:Hide()
    b.button2:SetScript("OnClick", function()
        local item = b.item
        if item and item.kind == "custom" then
            ClickCustom(item, item.onClick2)
        else
            FinishBanner()
        end
    end)

    b.close = CreateFrame("Button", nil, b, "UIPanelCloseButton")
    b.close:SetPoint("TOPRIGHT", -2, -2)
    b.close:SetScript("OnClick", FinishBanner)

    -- Stars that twinkle in the corners, and a flash of light that passes over the banner.
    b.stars = {}
    for index, corner in ipairs({ "TOPLEFT", "TOPRIGHT", "BOTTOMRIGHT", "BOTTOMLEFT" }) do
        local star = b:CreateTexture(nil, "OVERLAY")
        star:SetTexture(SPARKLE)
        star:SetBlendMode("ADD")
        star:SetVertexColor(1, 0.85, 0.45)
        star:SetSize(44, 44)
        star:SetPoint("CENTER", b, corner, 0, 0)
        b.stars[index] = star
    end
    b.shine = b:CreateTexture(nil, "OVERLAY")
    b.shine:SetTexture(SPARKLE)
    b.shine:SetBlendMode("ADD")
    b.shine:SetSize(110, 128)
    b.shine:SetAlpha(0)

    -- Can be moved; the position is remembered.
    b:SetScript("OnDragStart", function(self)
        self.dragging = true
        self:StartMoving()
    end)
    b:SetScript("OnDragStop", function(self)
        self:StopMovingOrSizing()
        self.dragging = false
        local point, _, relativePoint, x, y = self:GetPoint(1)
        if point then
            db.bannerPos = { point, relativePoint or point, x or 0, y or 0 }
        end
    end)
    b:SetScript("OnUpdate", AnimateBanner)
    return b
end

local function Present(item)
    if not banner then
        banner = CreateBanner()
    end
    banner.item = item
    local seconds = item.seconds
    if type(seconds) ~= "number" or seconds <= 0 then
        seconds = BANNER_SECONDS
    end
    banner.age, banner.left, banner.closing, banner.fade = 0, seconds, false, 0
    FillBanner()
    PlaceBanner()
    banner:SetAlpha(0)
    banner:Show()
    PlayFanfare(item)
    if item.kind == "custom" and type(item.onShow) == "function" then
        pcall(item.onShow, item)
    end
end

NextBanner = function()
    if banner and banner:IsShown() then
        return
    end
    local item = table.remove(queue, 1)
    if item then
        Present(item)
    end
end

-- Puts a banner in the queue. If banners are turned off, nothing is shown
-- (except the example, which the player asks for themselves, and custom
-- banners with always = true). A custom banner whose key is already queued or
-- shown is dropped. Returns true if it was queued.
local function Enqueue(item)
    if item.kind == "custom" then
        if db.banner == false and not item.always then
            return false
        end
        if banner and banner.item and banner.item.key == item.key then
            return false
        end
        for _, queued in ipairs(queue) do
            if queued.key == item.key then
                return false
            end
        end
    elseif db.banner == false and not item.sample then
        return false
    end
    if item.urgent then
        -- Goes first, even past QUEUE_MAX (the last waiting one makes room).
        if #queue >= QUEUE_MAX then
            table.remove(queue)
        end
        table.insert(queue, 1, item)
        NextBanner()
        return true
    end
    if #queue >= QUEUE_MAX then
        return false
    end
    queue[#queue + 1] = item
    NextBanner()
    return true
end

-- The public gold banner, for other modules. item fields:
--   key            (required) string; an item with the same key queued or shown is dropped
--   title, text, button   string, or a function returning one (read again on language change)
--   button2        optional second gold button, same types
--   buttonActive, button2Active   optional functions returning false to grey a button out
--   onClick(item), onClick2(item) optional; returning true keeps the banner open
--   onShow(item)   optional; called right after the banner is shown
--   sound          a sound kit number (plays even with the Sound box off),
--                  false for silence, nil for the fanfare (follows the Sound box)
--   seconds        how long it stays (default BANNER_SECONDS; longer while the mouse is over it)
--   icon           the picture on the left (default the guild shield)
--   always         shown even when the milestone banner box is off
--   urgent         goes first in the queue, even when it is full (event reminders)
-- Returns true if the banner was queued.
function DW.ShowBanner(item)
    if type(item) ~= "table" or type(item.key) ~= "string" or item.key == "" then
        return false
    end
    item.kind = "custom"
    return Enqueue(item)
end

-- The banner's gold text colour, for other modules' banner texts.
DW.BannerGold = Gold

-- Whether banners for announcements and polls are on (their own box).
function DW.NewsBannersOn()
    return db.newsBanner ~= false
end

-- How many banners wait behind the one shown (for the tests).
function DW.BannerQueueLength()
    return #queue
end

-- Guild achievements ---------------------------------------------------------------

-- Everything we know about the guild: how many are level 60/40, how many
-- members, and who has 300 in each profession ([line] = { name, ... }).
local function GuildStats()
    local members = DW.ReadGuildRoster()
    local stats = { members = #members, at60 = 0, at40 = 0, masters = {}, challenges = 0 }

    local function AddMaster(line, name)
        if not line or Text(name) == "" then
            return
        end
        local names = stats.masters[line]
        if not names then
            names = {}
            stats.masters[line] = names
        end
        for _, known in ipairs(names) do
            if DW.NameKey(known) == DW.NameKey(name) then
                return
            end
        end
        names[#names + 1] = name
    end

    -- The milestones we have heard about, in case the roster is not updated yet.
    local best = {}
    for _, entry in pairs(db.feed) do
        if entry.kind == "L" then
            best[entry.who] = math.max(best[entry.who] or 0, entry.value)
        elseif entry.kind == "P" and (entry.value or 0) >= PROF_MAX then
            AddMaster(entry.line, entry.name)
        elseif entry.kind == "A" then
            stats.challenges = stats.challenges + 1
        end
    end

    for _, member in ipairs(members) do
        local level = math.max(member.level, best[KeyOf(member.guid, member.key)] or 0)
        if level >= 60 then
            stats.at60 = stats.at60 + 1
        end
        if level >= 40 then
            stats.at40 = stats.at40 + 1
        end
        local list = DW.ProfessionsOfMember and DW.ProfessionsOfMember(member)
        for _, profession in ipairs(type(list) == "table" and list or {}) do
            if type(profession) == "table" and (Num(profession.level) or 0) >= PROF_MAX then
                AddMaster(LineOf(profession.name, profession.line), member.name)
            end
        end
    end

    -- Your own, straight from the game.
    local _, myName = DW.CharacterKey()
    local mine = DW.ReadMyProfessions and DW.ReadMyProfessions()
    for _, profession in ipairs(type(mine) == "table" and mine or {}) do
        if (Num(profession.level) or 0) >= PROF_MAX then
            AddMaster(LineOf(profession.name, profession.line), myName)
        end
    end
    return stats
end

local function CountGroup(stats, group)
    local count = 0
    for line, profession in pairs(PROFESSIONS) do
        if profession[2] == group and stats.masters[line] then
            count = count + 1
        end
    end
    return count
end

local function CountMastered(stats)
    local count = 0
    for _ in pairs(stats.masters) do
        count = count + 1
    end
    return count
end

-- The achievements. value(stats) gives how far the guild has come toward goal.
-- Describe() gives the description in the chosen language.
local GUILD = {}

local function AddLevel(id, name, goal, level, firstText)
    GUILD[#GUILD + 1] = {
        id = id, name = name, goal = goal, icon = LevelIcon(level),
        value = function(stats) return level == 60 and stats.at60 or stats.at40 end,
        Describe = function() return firstText and L[firstText] or L.ACH_G_LEVEL_D:format(goal, level) end,
    }
end

local function AddSize(id, name, goal)
    GUILD[#GUILD + 1] = {
        id = id, name = name, goal = goal, icon = DW.ICON,
        value = function(stats) return stats.members end,
        Describe = function() return L.ACH_G_SIZE_D:format(goal) end,
    }
end

local function AddProfessions(id, name, description, group, goal, icon)
    GUILD[#GUILD + 1] = {
        id = id, name = name, goal = goal, icon = icon, group = group,
        value = function(stats) return group and CountGroup(stats, group) or CountMastered(stats) end,
        Describe = function() return L[description]:format(PROF_MAX) end,
    }
end

AddLevel("lvl60_1", "ACH_G_TOP1", 1, 60, "ACH_G_TOP1_D")
AddLevel("lvl60_5", "ACH_G_TOP5", 5, 60)
AddLevel("lvl60_10", "ACH_G_TOP10", 10, 60)
AddLevel("lvl60_20", "ACH_G_RAID20", 20, 60)
AddLevel("lvl60_40", "ACH_G_RAID40", 40, 60)
AddLevel("lvl40_10", "ACH_G_HALF", 10, 40)
AddSize("size_25", "ACH_G_SIZE25", 25)
AddSize("size_50", "ACH_G_SIZE50", 50)
AddSize("size_100", "ACH_G_SIZE100", 100)
AddProfessions("prof_1", "ACH_G_MASTER", "ACH_G_MASTER_D", nil, 1, PROFESSIONS[164][3])
AddProfessions("prof_craft", "ACH_G_CRAFT", "ACH_G_CRAFT_D", "craft", 6, PROFESSIONS[202][3])
AddProfessions("prof_gather", "ACH_G_GATHER", "ACH_G_GATHER_D", "gather", 3, PROFESSIONS[186][3])
AddProfessions("prof_second", "ACH_G_SECOND", "ACH_G_SECOND_D", "secondary", 3, PROFESSIONS[185][3])

-- Legacy Challenges completed in the guild, as far as the addon has heard.
local function AddLegacy(id, name, goal)
    GUILD[#GUILD + 1] = {
        id = id, name = name, goal = goal, icon = LEGACY_ICON,
        value = function(stats) return stats.challenges end,
        Describe = function() return L.ACH_G_LEGACY_D:format(goal) end,
    }
end
AddLegacy("legacy_25", "ACH_G_LEGACY25", 25)
AddLegacy("legacy_100", "ACH_G_LEGACY100", 100)

local liveUntil = 0 -- GetTime() until when a completed guild achievement gives a banner

-- Checks whether any guild achievements have been reached. What is reached the
-- first time the addon looks counts as reached "before the addon". Otherwise
-- it gets the current time, and a banner if it happened just now.
local function Evaluate()
    if not DW.IsMember() then
        return
    end
    local stats = GuildStats()
    if stats.members == 0 then
        return -- the roster is not loaded yet
    end
    local live = GetTime() <= liveUntil
    for _, achievement in ipairs(GUILD) do
        if not db.guild[achievement.id] and achievement.value(stats) >= achievement.goal then
            if not db.guildInit then
                db.guild[achievement.id] = { before = true }
            else
                db.guild[achievement.id] = { time = Now() }
                if live then
                    Enqueue({ kind = "guild", achievement = achievement })
                end
            end
        end
    end
    db.guildInit = true
end

-- Sharing -----------------------------------------------------------------------

local Send = DW.CreateSender(PREFIX)
local QueueRefresh

local function SendEntry(entry)
    local key = MySendKey()
    if not key then
        return
    end
    entry.sent = true
    Send(table.concat({
        "M", key, ("%d"):format(entry.time), entry.kind, ("%d"):format(entry.value),
        CleanName(entry.name), Text(entry.class),
        entry.line and ("%d"):format(entry.line) or "", CleanName(entry.prof),
    }, SEP))
end

-- Sends your own milestones (only for the character you are playing now).
-- Without since: those not sent yet. With since: all after that time (0 = all).
local function Publish(since)
    local myKey = MyKey()
    if not myKey then
        return
    end
    local list = {}
    for _, entry in pairs(db.feed) do
        if entry.who == myKey and entry.exact and entry.time and ((since == nil and not entry.sent) or (since ~= nil and entry.time > since)) then
            list[#list + 1] = entry
        end
    end
    table.sort(list, function(a, b)
        return a.time > b.time
    end)
    for index = 1, math.min(#list, REPLY_MAX) do
        SendEntry(list[index])
    end
end

-- You reached a milestone yourself: remember it, show the banner and tell the guild.
local function OwnMilestone(kind, value, line, prof)
    local sendKey, name = MySendKey()
    if not sendKey then
        return
    end
    local entry = Remember({
        who = Canonical(sendKey, name), name = name, class = MyClass(), kind = kind, value = value,
        line = line, prof = prof and CleanName(prof) or nil, time = Now(), exact = true,
    })
    liveUntil = GetTime() + LIVE_WINDOW
    if not entry.bannered then
        entry.bannered = true
        Enqueue({ kind = "milestone", entry = entry, own = true })
    end
    if not entry.sent then
        SendEntry(entry)
    end
    Evaluate()
    QueueRefresh()
end

-- You completed an achievement: if it is a Legacy Challenge (not a guild
-- achievement, and not one that another character on the account already
-- had), it is announced.
local function OnAchievementEarned(id, alreadyEarned)
    id = id ~= nil and Num(tonumber(id)) or nil
    if not id or alreadyEarned == true then
        return
    end
    local info = ChallengeInfo(id)
    if info and info.isGuild then
        return
    end
    -- If the game says it gives no legacy points, it is not a challenge.
    -- (If the game cannot say, it is announced anyway, without points.)
    local points = ChallengePoints(id)
    if points == 0 then
        return
    end
    OwnMilestone("A", points or 0, id, info and info.name or ("#" .. id))
end

local function OnLevelUp(level)
    level = level ~= nil and Num(tonumber(level)) or nil
    if level and IsLevelMilestone(level) then
        OwnMilestone("L", level)
    end
end

-- Looks for own professions that have reached 300 since last time. The first
-- time we see a profession, we only remember where it stands.
local function CheckOwnProfessions()
    local key = MySendKey()
    local list = DW.ReadMyProfessions and DW.ReadMyProfessions()
    if not key or type(list) ~= "table" then
        return
    end
    local seen = db.mine[key]
    if type(seen) ~= "table" then
        seen = {}
        db.mine[key] = seen
    end
    for _, profession in ipairs(list) do
        local level = type(profession) == "table" and Num(profession.level)
        local name = type(profession) == "table" and CleanName(profession.name) or ""
        if level and name ~= "" then
            local before = Num(seen[name])
            seen[name] = level
            if before and before < PROF_MAX and level >= PROF_MAX then
                OwnMilestone("P", PROF_MAX, LineOf(name, profession.line), name)
            end
        end
    end
end

local replyScheduled = false
local replySince

-- Someone asked for milestones (R): our own milestones, and later the guild
-- firsts we know of (anyone may answer those; see Firsts.PlanReply).
local function ScheduleReply(since)
    replySince = math.min(replySince or since, since)
    if replyScheduled then
        return
    end
    replyScheduled = true
    -- F messages heard from now on mean someone else answers the firsts.
    local serial = Firsts.heard
    C_Timer.After(1 + math.random() * 5, function()
        replyScheduled = false
        local from = replySince or 0
        replySince = nil
        if DW.IsMember() then
            Publish(from)
            Firsts.PlanReply(from, serial)
        end
    end)
end

DW.OnGuildMessage(PREFIX, function(text, sender)
    local fields = {}
    for field in (text .. SEP):gmatch("(.-)" .. SEP) do
        fields[#fields + 1] = field
    end
    if fields[1] == "R" then
        ScheduleReply(DW.SyncRequestSince(text))
        return
    end
    if fields[1] == "F" then
        Firsts.OnMessage(fields, sender)
        return
    end
    if fields[1] ~= "M" then
        return
    end

    local key, when, kind, value = fields[2] or "", tonumber(fields[3] or ""), fields[4], tonumber(fields[5] or "")
    if #key > 60 or not (key:find("^Player%-[%w%-]+$") or key:find("^name:%S+$")) then
        return
    end
    if not when or when <= 0 or when > Now() + 86400 or not value then
        return
    end
    if not ((kind == "L" and IsLevelMilestone(value)) or (kind == "P" and value == PROF_MAX)
        or (kind == "A" and value >= 0 and value < 1000 and value == math.floor(value))) then
        return
    end
    local name = CleanName(fields[6])
    if name == "" then
        name = CleanName(sender:match("^([^-]+)") or sender)
    end
    local class = Text(fields[7]):match("^[A-Z]+$") or ""
    local prof = kind ~= "L" and CleanName(fields[9]) or nil
    local line
    if kind == "P" then
        line = LineOf(prof, fields[8])
        if not line and prof == "" then
            return
        end
    elseif kind == "A" then
        line = tonumber((fields[8] or ""):match("^%d+$") or "")
        if not line or line <= 0 or line >= 10000000 then
            return
        end
    end

    local entry = Remember({
        who = Canonical(key, name), name = name, class = class, kind = kind, value = value,
        line = line, prof = prof, time = when, exact = true,
    })
    if Now() - when <= LIVE_SECONDS and not entry.bannered then
        entry.bannered = true
        liveUntil = GetTime() + LIVE_WINDOW
        Enqueue({ kind = "milestone", entry = entry })
        -- Ask for a fresh roster, so the level numbers are right.
        if C_GuildInfo and C_GuildInfo.GuildRoster then
            C_GuildInfo.GuildRoster()
        end
    end
    Evaluate()
    QueueRefresh()
end)

-- New members ------------------------------------------------------------------------

local recentJoins = {} -- [nameKey] = GetTime() when the system message said they joined

-- A Lua pattern from one of the game's texts with a single %s, e.g.
-- "%s has joined the guild." -> "^(.+) has joined the guild%.$".
local function MakePattern(format)
    if type(format) ~= "string" or DW.IsSecret(format) then
        return nil
    end
    local pattern, count = format:gsub("%%%d?%$?s", "\001")
    if count ~= 1 then
        return nil
    end
    pattern = pattern:gsub("[%^%$%(%)%%%.%[%]%*%+%-%?]", "%%%0")
    return "^" .. pattern:gsub("\001", "(.+)") .. "$"
end

-- The patterns from the game's text and the English text, without doubles.
local function BuildPatterns(...)
    local list, seen = {}, {}
    for index = 1, select("#", ...) do
        local pattern = MakePattern((select(index, ...)))
        if pattern and not seen[pattern] then
            seen[pattern] = true
            list[#list + 1] = pattern
        end
    end
    return list
end

local joinPatterns, invitePatterns -- built the first time they are needed

local function JoinPatterns()
    joinPatterns = joinPatterns or BuildPatterns(_G.ERR_GUILD_JOIN_S, "%s has joined the guild.")
    return joinPatterns
end

local function InvitePatterns()
    invitePatterns = invitePatterns or BuildPatterns(_G.ERR_GUILD_INVITE_S, "You have invited %s to join your guild.")
    return invitePatterns
end

-- The name in a system message, or nil. The name can be a player link and
-- can have a colour.
local function NameFromSystem(text, patterns)
    if type(text) ~= "string" or DW.IsSecret(text) then
        return nil
    end
    -- Colours first: a colour code inside the link's [brackets] would
    -- otherwise stop the link from being recognised.
    text = text:gsub("|c%x%x%x%x%x%x%x%x(.-)|r", "%1")
    text = text:gsub("|Hplayer:[^|]*|h%[?([^%]|]*)%]?|h", "%1")
    for _, pattern in ipairs(patterns) do
        local name = text:match(pattern)
        if name then
            name = CleanName(name)
            if name ~= "" then
                return name
            end
        end
    end
    return nil
end

-- You invited someone to the guild (only this PC knows).
local function RememberInvite(name)
    if not DW.IsMember() or type(name) ~= "string" or DW.IsSecret(name) then
        return
    end
    local nameKey = DW.NameKey(name)
    if nameKey == "" then
        return
    end
    db.invites = type(db.invites) == "table" and db.invites or {}
    db.invites[nameKey] = Now()
end

-- C_GuildInfo.Invite is what /ginvite and the Communities "Add member" dialog
-- use. The old global GuildInvite is not hooked (it is deprecated); addons
-- that call it are still caught by the system message.
if C_GuildInfo and type(C_GuildInfo.Invite) == "function" and type(hooksecurefunc) == "function" then
    hooksecurefunc(C_GuildInfo, "Invite", function(name)
        RememberInvite(name)
    end)
end

-- Whether you invited this player within the last hour. The invite is used
-- up either way.
local function InvitedByMe(nameKey)
    local invites = type(db.invites) == "table" and db.invites or {}
    local at = Num(invites[nameKey])
    invites[nameKey] = nil
    return at ~= nil and Now() - at <= INVITE_KEEP
end

-- Whether the member a J entry is about is online now (as the roster said
-- the last time it was read).
local function MemberOnline(who)
    local member
    if type(who) == "string" and who:find("^name:") then
        member = rosterByName[who:sub(6)]
    else
        member = rosterByGuid[who]
    end
    return member ~= nil and member.online == true
end

-- The short address of the addon's page: github.com/Samuron39/Dragonworld.
local function InstallPage()
    local page = ((DW.DOWNLOAD_URL or ""):gsub("^https?://", ""):gsub("/releases/latest$", ""))
    if page == "" then
        page = "github.com/Samuron39/Dragonworld"
    end
    return page
end

-- Whispers the new member the addon's address. Only for one you invited.
local function SendAddonLink(entry)
    if type(entry) ~= "table" or entry.sample or not entry.invited or entry.linkSent then
        return false
    end
    if DW.SendChat(L.WEL_LINK_WHISPER:format(InstallPage()), "WHISPER", entry.target or entry.name) then
        entry.linkSent = true
        return true
    end
    return false
end

-- The welcome banner. For the one who invited (and in the example) it has a
-- second button for the addon link, and stays until both are used or 30 s
-- pass. The example's buttons send nothing.
local function ShowWelcome(entry, sample)
    local inviter = sample or entry.invited
    local state = {}
    return DW.ShowBanner({
        key = "wel:" .. (entry.id or "sample"),
        welcome = entry,
        always = sample or nil,
        seconds = inviter and INVITER_SECONDS or nil,
        title = function()
            return L.WEL_BANNER
        end,
        text = function()
            local text = L.WEL_BANNER_TEXT:format(ClassName(entry.name, entry.class))
            if inviter then
                text = text .. "\n" .. L.WEL_BANNER_INVITER
            end
            return text
        end,
        button = function()
            return L.WEL_BUTTON
        end,
        buttonActive = function()
            return not (state.welcomed or (entry.gratz and not sample))
        end,
        onClick = function()
            if not sample and not entry.gratz and not Gratz(entry) then
                DW.Print(L.GC_BLOCKED)
                return true
            end
            state.welcomed = true
            QueueRefresh()
            return inviter and not (state.linked or entry.linkSent) and true or false
        end,
        button2 = inviter and function()
            return (state.linked or entry.linkSent) and L.WEL_LINK_SENT or L.WEL_SEND_LINK
        end or nil,
        button2Active = function()
            return not (state.linked or entry.linkSent)
        end,
        onClick2 = function()
            if not sample and not SendAddonLink(entry) then
                DW.Print(L.GC_BLOCKED)
                return true
            end
            state.linked = true
            QueueRefresh()
            return not (state.welcomed or (entry.gratz and not sample))
        end,
    })
end

-- A new member's banner, unless the welcome banner (or all banners) is
-- turned off. Then the inviter is told in chat where the link button is.
local function EnqueueWelcome(entry)
    entry.bannered = true
    if db.welcome == false or db.banner == false then
        if entry.invited then
            DW.Print(L.WEL_CHAT_INVITER:format(entry.name, L.ACH_TITLE, L.ACH_VIEW_FEED))
        end
        return
    end
    ShowWelcome(entry, false)
end

-- The newest join saved for this name, under any key.
local function JoinByName(nameKey)
    local found
    for _, entry in pairs(db.feed) do
        if entry.kind == "J" and DW.NameKey(entry.target or entry.name) == nameKey
            and (not found or Newest(entry, found)) then
            found = entry
        end
    end
    return found
end

-- The game says someone joined the guild (live, with the exact time).
local function OnJoinMessage(name)
    if DW.IsMe(name) then
        return
    end
    local nameKey = DW.NameKey(name)
    if nameKey == "" then
        return
    end
    recentJoins[nameKey] = GetTime()
    local member = rosterByName[nameKey]
    local who = member and KeyOf(member.guid, member.key) or ("name:" .. nameKey)
    local old = db.feed[who .. ":J"]
    if not old and not member then
        -- Not in the roster (any more): someone who left and came back has
        -- their earlier join under their permanent ID.
        old = JoinByName(nameKey)
    end
    if old then
        if Now() - (old.time or 0) < REJOIN_AFTER then
            return
        end
        db.feed[old.id or (who .. ":J")] = nil -- joined again after a while: a new welcome
    end
    local entry = Remember({
        who = who, name = CleanName(member and member.name or (name:match("^([^-]+)") or name)),
        class = member and member.class or "", kind = "J", value = 0, time = Now(), exact = true,
        invited = InvitedByMe(nameKey) or nil, target = member and member.key or name,
    })
    liveUntil = GetTime() + LIVE_WINDOW
    if C_GuildInfo and C_GuildInfo.GuildRoster then
        C_GuildInfo.GuildRoster()
    end
    EnqueueWelcome(entry)
    Evaluate()
    QueueRefresh()
end

-- A member in the roster we have never seen (the fallback when there was no
-- system message, e.g. it came while you were offline). live = it happened
-- now, while you are online, and they are online.
local function OnRosterJoin(member, key, live)
    local nameKey = DW.NameKey(member.key)
    local seenAt = recentJoins[nameKey]
    if seenAt and GetTime() - seenAt < RECENT_JOIN then
        return
    end
    local old = db.feed[key .. ":J"]
    if old and Now() - (old.time or 0) < REJOIN_AFTER then
        if Text(member.class) ~= "" then
            old.class = member.class
        end
        old.target = member.key
        return
    end
    if old then
        db.feed[old.id or (key .. ":J")] = nil
    end
    local entry = Remember({
        who = key, name = CleanName(member.name), class = Text(member.class), kind = "J", value = 0,
        time = Now(), exact = false, invited = InvitedByMe(nameKey) or nil, target = member.key,
    })
    if live and not DW.IsMe(member.key) then
        liveUntil = GetTime() + LIVE_WINDOW
        EnqueueWelcome(entry)
    else
        entry.bannered = true
    end
end

-- A join first saved under the name (from the system message) moves to the
-- player's permanent ID once the roster shows it, and gets the class.
local function RekeyJoin(nameKey, guidKey, member)
    local entry = db.feed[nameKey .. ":J"]
    if not entry or nameKey == guidKey then
        return
    end
    local taken = db.feed[guidKey .. ":J"]
    if taken then
        if (taken.time or 0) + REJOIN_AFTER > (entry.time or 0) then
            -- The same join saved twice: keep the one under the ID, with
            -- what was done on either, and the exact time if only one has it.
            taken.gratz = taken.gratz or entry.gratz
            taken.invited = taken.invited or entry.invited
            taken.linkSent = taken.linkSent or entry.linkSent
            taken.bannered = taken.bannered or entry.bannered
            if entry.exact and not taken.exact then
                taken.time, taken.exact = entry.time, true
            end
            if Text(member.class) ~= "" then
                taken.class = member.class
            end
            taken.target = member.key
            db.feed[nameKey .. ":J"] = nil
            return
        end
        -- An old join under the ID (a member who left and came back) gives way.
        db.feed[guidKey .. ":J"] = nil
    end
    db.feed[nameKey .. ":J"] = nil
    entry.who = guidKey
    if Text(member.class) ~= "" then
        entry.class = member.class
    end
    entry.target = member.key
    entry.id = EntryID(entry)
    db.feed[entry.id] = entry
    if banner and banner:IsShown() and banner.item and banner.item.welcome == entry then
        RefillBanner()
    end
end

-- A system message: an invite you sent went out, or someone joined.
local function OnSystemMessage(text)
    local invited = NameFromSystem(text, InvitePatterns())
    if invited then
        RememberInvite(invited)
        return
    end
    local joined = NameFromSystem(text, JoinPatterns())
    if joined then
        OnJoinMessage(joined)
    end
end

-- An example of the welcome banner, as the inviter sees it, with your own name.
local function ShowWelcomeSample()
    local _, name = DW.CharacterKey()
    return ShowWelcome({ name = name or "Dragonworld", class = MyClass(), kind = "J", value = 0, sample = true }, true)
end

-- Guild firsts ---------------------------------------------------------------------

-- A name compared without case, spaces and dashes ("Anna Berg" = "annaberg").
function Firsts.Plain(text)
    return (Text(text):lower():gsub("[%s%-]", ""))
end

-- Whether a name in a guild first is the character you are playing.
function Firsts.IsMine(name)
    local plain = Firsts.Plain(name)
    if plain == "" then
        return false
    end
    local _, myName = DW.CharacterKey()
    if myName ~= nil and plain == Firsts.Plain(myName) then
        return true
    end
    -- Forever gives first and last name as name and realm ("Akro", "Polis"),
    -- while the roster has the whole name ("Akro Polis").
    local ok, unitName, realm = pcall(UnitName, "player")
    return ok and type(unitName) == "string" and type(realm) == "string" and not DW.IsSecret(unitName)
        and not DW.IsSecret(realm) and realm ~= "" and plain == Firsts.Plain(unitName .. realm)
end

-- The raid's name: English for the raids in DW.DUNGEONS, otherwise the game's.
function Firsts.RaidInstance(mapID, instName)
    local dungeon = Firsts.RAID_NAMES[mapID] and DW.DUNGEON_BY_ID and DW.DUNGEON_BY_ID[Firsts.RAID_NAMES[mapID]]
    if dungeon then
        return dungeon.name
    end
    instName = CleanName(instName)
    return instName ~= "" and instName or "?"
end

-- The first we already have for this kill: the same key, or for a raid boss
-- the same boss in the same raid (a kill first seen in the lockout, then
-- reported, or the other way round).
function Firsts.Known(rec)
    local old = db.firsts[rec.key]
    if old then
        return old
    end
    if rec.type == "R" then
        local boss = Text(rec.boss):lower()
        for _, other in pairs(db.firsts) do
            if other.type == "R" and other.map == rec.map and Text(other.boss):lower() == boss then
                return other
            end
        end
    end
    return nil
end

function Firsts.Count()
    local total, dungeons, raids = 0, 0, 0
    for _, rec in pairs(db.firsts) do
        total = total + 1
        if rec.type == "R" then
            raids = raids + 1
        else
            dungeons = dungeons + 1
        end
    end
    return total, dungeons, raids
end

-- A kill counts only once the login sync has had time to tell us about
-- firsts from while we were away.
function Firsts.Settled()
    return Firsts.helloAt ~= nil and GetTime() - Firsts.helloAt >= Firsts.SETTLE
end

-- The gold banner. own = you were in the group (Hooray!, posts nothing);
-- otherwise Gratz! congratulates in guild chat.
function Firsts.Show(e, own)
    return DW.ShowBanner({
        key = "first:" .. e.key,
        title = function()
            return L.ACH_FIRST_BANNER
        end,
        text = function()
            if own then
                return L.ACH_FIRST_YOU:format(Gold(e.boss), e.instance)
            end
            return L.ACH_FIRST_OTHER:format(WhoText(e, true), Gold(e.boss), e.instance)
        end,
        button = function()
            return own and L.ACH_HOORAY or L.ACH_GRATZ
        end,
        onClick = function()
            if not own then
                Gratz(e)
                QueueRefresh()
            end
        end,
        icon = e.type == "R" and Firsts.ICON_RAID or Firsts.ICON_DUNGEON,
        always = e.sample or nil,
    })
end

-- The F message: as many names as fit in 255 bytes (count stays the real number).
-- Your own name always gets a place: receivers only trust a fresh first from
-- someone in its list of names. The names keep their order.
function Firsts.Message(rec)
    local head = table.concat({
        "F", rec.key, ("%d"):format(rec.time), rec.type, ("%d"):format(Num(rec.enc) or 0), ("%d"):format(Num(rec.map) or 0),
        ("%d"):format(Num(rec.count) or 1), CleanName(rec.boss), CleanName(rec.instance),
    }, SEP) .. SEP
    local list = {}
    for _, name in ipairs(type(rec.names) == "table" and rec.names or {}) do
        local add = (CleanName(name):gsub(",", " "))
        if add ~= "" then
            list[#list + 1] = add
        end
    end
    local room, used, keep = 255 - #head, 0, {}
    for index, name in ipairs(list) do
        if Firsts.IsMine(name) then
            if #name <= room then
                keep[index], used = true, #name
            end
            break
        end
    end
    for index, name in ipairs(list) do
        if not keep[index] then
            local cost = #name + (used > 0 and 1 or 0) -- the comma before it
            if used + cost > room then
                break
            end
            keep[index], used = true, used + cost
        end
    end
    local names = {}
    for index, name in ipairs(list) do
        if keep[index] then
            names[#names + 1] = name
        end
    end
    return head .. table.concat(names, ",")
end

function Firsts.SendRec(rec)
    rec.sent = true
    Send(Firsts.Message(rec))
end

-- The guild members in your group, yourself included: display names sorted
-- by name, how many, your place in the list (from 0), and whether some
-- member could not be told (the game hides names during a fight).
function Firsts.GroupMembers()
    local Plain = Firsts.Plain
    local byGuid, byPlain = {}, {}
    for _, member in ipairs(DW.ReadGuildRoster()) do
        if member.guid then
            byGuid[member.guid] = member
        end
        byPlain[Plain(member.key)] = byPlain[Plain(member.key)] or member
        byPlain[Plain(member.name)] = byPlain[Plain(member.name)] or member
    end
    local units = { "player" }
    for _, unit in ipairs(DW.GroupUnits()) do
        units[#units + 1] = unit
    end
    local names, seen, restricted, selfName = {}, {}, false, nil
    for _, unit in ipairs(units) do
        local ok, guid = pcall(UnitGUID, unit)
        guid = ok and type(guid) == "string" and not DW.IsSecret(guid) and guid ~= "" and guid or nil
        local member = guid and byGuid[guid]
        local named = false
        if not member then
            local fine, name, realm = pcall(UnitName, unit)
            if fine and type(name) == "string" and not DW.IsSecret(name) and name ~= "" then
                named = true
                -- Forever gives first and last name as name and realm, so with
                -- a realm only the whole name counts (a pug "Anna Berg" is not
                -- the member "Anna").
                if type(realm) == "string" and not DW.IsSecret(realm) and realm ~= "" then
                    member = byPlain[Plain(name .. realm)]
                else
                    member = byPlain[Plain(name)]
                end
            end
        end
        if not guid and not named then
            restricted = true
        end
        if member then
            local display = (CleanName(member.name):gsub(",", " "))
            if not seen[member.key] then
                seen[member.key] = true
                names[#names + 1] = display
            end
            if unit == "player" then
                selfName = display
            end
        end
    end
    if not selfName then
        local _, myName = DW.CharacterKey()
        myName = myName and (CleanName(myName):gsub(",", " ")) or ""
        for _, name in ipairs(names) do
            if not selfName and Firsts.IsMine(name) then
                selfName = name
            end
        end
        if not selfName and myName ~= "" then
            names[#names + 1] = myName
            selfName = myName
        end
    end
    table.sort(names, function(a, b)
        local pa, pb = Plain(a), Plain(b)
        if pa ~= pb then
            return pa < pb
        end
        return a < b
    end)
    local position = 0
    for index, name in ipairs(names) do
        if name == selfName then
            position = index - 1
            break
        end
    end
    return names, #names, position, restricted
end

-- Keeps checking whether the login sync has finished, while kills wait for it.
function Firsts.PlanFlush()
    if Firsts.flushQueued then
        return
    end
    Firsts.flushQueued = true
    C_Timer.After(5.5, function()
        Firsts.flushQueued = false
        Firsts.FlushPending()
    end)
end

function Firsts.FlushPending()
    if #Firsts.pendingFirsts == 0 then
        return
    end
    if not Firsts.Settled() then
        Firsts.PlanFlush()
        return
    end
    local list = Firsts.pendingFirsts
    Firsts.pendingFirsts = {}
    for _, item in ipairs(list) do
        Firsts.Claim(item.rec, item.position)
    end
end

-- Our group killed a boss: if nobody has told us it was killed before, it is
-- a guild first. The banner shows at once; one group member sends it, the
-- first in name order first (the others wait 2 s more each and stay quiet
-- once they hear it).
function Firsts.Claim(rec, position)
    if not Firsts.Settled() then
        if #Firsts.pendingFirsts < Firsts.WAIT_MAX then
            table.insert(Firsts.pendingFirsts, { rec = rec, position = position })
        end
        Firsts.PlanFlush()
        return
    end
    if Firsts.Known(rec) or not Firsts.MakeRoom(true) then
        return
    end
    rec.id = "F:" .. rec.key
    rec.trusted = true
    rec.heardAt = Now()
    rec.bannered = true
    db.firsts[rec.key] = rec
    liveUntil = GetTime() + LIVE_WINDOW
    Firsts.Show(rec, true)
    QueueRefresh()
    C_Timer.After(1.2 + 2 * position, function()
        if not rec.heard and not rec.sent and DW.IsMember() then
            Firsts.SendRec(rec)
        end
    end)
end

-- The kills waiting for the end of the fight get the names in the group.
function Firsts.RunPending()
    local list = Firsts.pendingKills
    if #list == 0 then
        return
    end
    -- Names read during a fight can be hidden: wait for PLAYER_REGEN_ENABLED.
    if type(InCombatLockdown) == "function" and InCombatLockdown() == true then
        for _, rec in ipairs(list) do
            if not rec.deferred then
                rec.deferred = true
                Firsts.signals.deferred = Firsts.signals.deferred + 1
            end
        end
        return
    end
    Firsts.pendingKills = {}
    local names, count, position, restricted = Firsts.GroupMembers()
    for _, rec in ipairs(list) do
        local copy = {}
        for index, name in ipairs(names) do
            copy[index] = name
        end
        rec.names, rec.count = copy, count
        -- Only you could be told apart (the game still hides the others):
        -- count the group instead.
        if restricted and count <= 1 and (rec.groupSize or 0) > 1 then
            rec.count = math.max(1, math.min(40, rec.groupSize))
        end
        rec.groupSize, rec.deferred = nil, nil
        Firsts.Claim(rec, position)
    end
end

-- Waits for the end of the fight (names are hidden during it), or 2.2 s.
function Firsts.QueueKill(rec)
    if #Firsts.pendingKills >= Firsts.PENDING_MAX then
        return
    end
    local ok, size = pcall(GetNumGroupMembers)
    rec.groupSize = ok and Num(size) or 0
    Firsts.pendingKills[#Firsts.pendingKills + 1] = rec
    local inCombat = type(InCombatLockdown) == "function" and InCombatLockdown() == true
    if inCombat then
        rec.deferred = true
        Firsts.signals.deferred = Firsts.signals.deferred + 1 -- runs on PLAYER_REGEN_ENABLED
    elseif not Firsts.runQueued then
        Firsts.runQueued = true
        C_Timer.After(2.2, function()
            Firsts.runQueued = false
            Firsts.RunPending()
        end)
    end
end

-- Remembers a boss kill for /dw debug (the newest LOG_MAX).
function Firsts.Log(id, name, mapID, kind, result)
    local log = db.bossLog
    local entry = type(log[id]) == "table" and log[id] or { n = 0 }
    entry.name, entry.map, entry.type, entry.result = name, mapID, kind, result
    entry.n = (Num(entry.n) or 0) + 1
    entry.last = Now()
    log[id] = entry
    local count, oldestID, oldest = 0, nil, nil
    for key, item in pairs(log) do
        count = count + 1
        local last = type(item) == "table" and Num(item.last) or 0
        if not oldest or last < oldest then
            oldestID, oldest = key, last
        end
    end
    if count > Firsts.LOG_MAX and oldestID then
        log[oldestID] = nil
    end
end

-- ENCOUNTER_END (source "ee") or BOSS_KILL ("bk"). Only what is safe during
-- the fight is read here; the names come after it (Firsts.RunPending).
function Firsts.OnKill(source, id, name, groupSize)
    local signals = Firsts.signals
    if DW.IsSecret(id) then
        id = nil
    end
    id = id ~= nil and Num(tonumber(id)) or nil
    name = CleanName(name)
    if not id then
        signals.hidden = signals.hidden + 1
        return
    end
    signals[source] = signals[source] + 1
    local now = GetTime()
    local lower = name:lower()
    if lower ~= "" then
        Firsts.lastKillByName[lower] = now
    end
    local last = Firsts.lastKillAt[id]
    if last and now - last < Firsts.SAME_KILL then
        return -- ENCOUNTER_END and BOSS_KILL for the same kill
    end
    Firsts.lastKillAt[id] = now

    local inside, itype, instName, mapID = DW.InstanceInfo()
    local kind
    if itype == "raid" then
        kind = "R"
    elseif itype == "party" then
        kind = "D"
    elseif inside and itype ~= "pvp" and itype ~= "arena" and itype ~= "scenario" then
        -- Inside, but the game does not say what: a big group is a raid,
        -- otherwise a dungeon if it is one of the last bosses.
        if (Num(groupSize) or 0) > 5 then
            kind = "R"
        elseif Firsts.byEncounter[id] or Firsts.byName[lower] then
            kind = "D"
        end
    end
    if not kind then
        Firsts.Log(id, name, mapID, itype, "none") -- world bosses and the like never count
        return
    end
    if kind == "R" then
        db.raidEventSeen = true
    end

    local rec = { kind = "F", type = kind, enc = id, map = mapID, time = Now(), mine = true }
    if kind == "D" then
        local dungeonID = Firsts.byEncounter[id] or (lower ~= "" and Firsts.byName[lower]) or nil
        if not dungeonID then
            Firsts.Log(id, name, mapID, kind, "none") -- not the last boss
            return
        end
        rec.key = "d" .. dungeonID
        rec.instance = DW.DUNGEON_BY_ID[dungeonID].name
        rec.boss = name ~= "" and name or Firsts.END_BOSSES[dungeonID][1]
    else
        if id < 1 or id > 9999999 then
            Firsts.Log(id, name, mapID, kind, "none")
            return
        end
        rec.key = "e" .. id
        rec.boss = name ~= "" and name or ("#" .. id)
        rec.instance = Firsts.RaidInstance(mapID, instName)
    end
    Firsts.Log(id, name, mapID, kind, kind == "D" and rec.key or "raid")
    Firsts.QueueKill(rec)
end

-- The raid lockout fallback, for raids where the game reports no boss kill
-- (only until one is reported inside a raid). The game's list of bosses
-- killed in this lockout is read when you enter, and after each fight; a
-- boss that has become killed since is a kill.
function Firsts.LockReady()
    return db.raidEventSeen ~= true and type(GetInstanceLockTimeRemainingEncounter) == "function"
        and type(GetInstanceLockTimeRemaining) == "function"
end

-- [boss number] = killed, and [boss number] = name, as the lockout says now.
function Firsts.ReadLocks()
    local killed, names = {}, {}
    local ok, _, _, total = pcall(GetInstanceLockTimeRemaining)
    total = ok and Num(total) or 0
    for index = 1, math.min(total, 40) do
        local fine, bossName, _, isKilled = pcall(GetInstanceLockTimeRemainingEncounter, index)
        killed[index] = fine and not DW.IsSecret(isKilled) and isKilled == true
        names[index] = fine and CleanName(bossName) or ""
    end
    return killed, names, math.min(total, 40)
end

function Firsts.PlanSnapshot()
    if not DW.IsMember() or not Firsts.LockReady() or Firsts.snapQueued then
        return
    end
    Firsts.snapQueued = true
    C_Timer.After(3.2, function()
        Firsts.snapQueued = false
        local _, itype, _, mapID = DW.InstanceInfo()
        if itype ~= "raid" or mapID <= 0 or not Firsts.LockReady() then
            Firsts.lockMap = nil
            return
        end
        if type(RequestRaidInfo) == "function" then
            pcall(RequestRaidInfo)
        end
        Firsts.lockMap = mapID
        local killed, _, total = Firsts.ReadLocks()
        Firsts.lockSnap, Firsts.lockTotal = killed, total
    end)
end

-- request = ask the game for fresh lockout info first. Not after
-- UPDATE_INSTANCE_INFO, which is the answer to such a request (no loop).
function Firsts.PlanCheck(request)
    if not Firsts.lockMap or not Firsts.LockReady() or Firsts.checkQueued then
        return
    end
    local _, _, _, mapID = DW.InstanceInfo()
    if mapID ~= Firsts.lockMap then
        Firsts.lockMap = nil
        return
    end
    if request and type(RequestRaidInfo) == "function" then
        pcall(RequestRaidInfo)
    end
    Firsts.checkQueued = true
    C_Timer.After(2.2, Firsts.CheckLocks)
end

function Firsts.CheckLocks()
    Firsts.checkQueued = false
    local map = Firsts.lockMap
    if not map or not Firsts.LockReady() then
        return
    end
    local _, _, instName, mapID = DW.InstanceInfo()
    if mapID ~= map then
        Firsts.lockMap = nil
        return
    end
    local killed, names, total = Firsts.ReadLocks()
    local fresh = {}
    for index = 1, total do
        if killed[index] and not Firsts.lockSnap[index] then
            fresh[#fresh + 1] = index
        end
    end
    -- Only one boss at a time dies. The earlier read may have come before the
    -- game had the lockout (no bosses, or another number of them), and then
    -- every boss killed before you came would look new: start over from this
    -- read instead. From no lockout at all, one killed boss right after a
    -- fight is the kill that saved you to it.
    local before = Firsts.lockTotal or 0
    local trusted = #fresh == 1 and total > 0 and (before == total
        or (before == 0 and Firsts.fightEndAt ~= nil and GetTime() - Firsts.fightEndAt <= Firsts.LOCK_SAME))
    Firsts.lockSnap, Firsts.lockTotal = killed, total
    if not trusted then
        return
    end
    local index = fresh[1]
    local boss = names[index] ~= "" and names[index] or ("#" .. index)
    local last = Firsts.lastKillByName[boss:lower()]
    -- Reported by the game already (that kill is counted as such).
    if (last and GetTime() - last <= Firsts.LOCK_SAME) or #Firsts.pendingKills >= Firsts.PENDING_MAX then
        return
    end
    Firsts.signals.lock = Firsts.signals.lock + 1
    local ok, size = pcall(GetNumGroupMembers)
    Firsts.pendingKills[#Firsts.pendingKills + 1] = {
        key = ("L%d.%d"):format(map, index), kind = "F", type = "R", enc = 0, map = map, boss = boss,
        instance = Firsts.RaidInstance(map, instName), time = Now(), mine = true, groupSize = ok and Num(size) or 0,
    }
    Firsts.RunPending()
end

-- An F from someone else.
function Firsts.OnMessage(fields, sender)
    local key, when, kind = fields[2] or "", tonumber(fields[3] or ""), fields[4]
    local valid = false
    local dungeon = key:match("^d(%d+)$")
    local encounter = key:match("^e(%d+)$")
    if dungeon then
        local info = DW.DUNGEON_BY_ID and DW.DUNGEON_BY_ID[tonumber(dungeon)]
        valid = kind == "D" and info ~= nil and not info.raid
    elseif encounter then
        encounter = tonumber(encounter)
        valid = kind == "R" and encounter >= 1 and encounter <= 9999999
    elseif key:match("^L%d+%.%d+$") then
        valid = kind == "R"
    end
    if not valid or #key > 24 then
        return
    end
    local now = Now()
    if not when or when < (Num(DW.FIRSTS_EPOCH) or 0) or when > now + 600 then
        return
    end
    local count = tonumber(fields[7] or "")
    if not count or count < 1 or count > 40 or count ~= math.floor(count) then
        return
    end
    local boss, instance = CleanName(fields[8]), CleanName(fields[9])
    if boss == "" or instance == "" then
        return
    end
    local map = Num(tonumber(fields[6] or "")) or 0
    local lockMap = key:match("^L(%d+)%.")
    if lockMap and tonumber(lockMap) ~= map then
        return
    end
    -- Names from our own data where we have them, not the sender's text.
    if dungeon then
        local dungeonID = tonumber(dungeon)
        instance = DW.DUNGEON_BY_ID[dungeonID].name
        if Firsts.byName[boss:lower()] ~= dungeonID and Firsts.END_BOSSES[dungeonID] then
            boss = Firsts.END_BOSSES[dungeonID][1]
        end
    else
        instance = Firsts.RaidInstance(map, instance)
        if encounter and type(EJ_GetEncounterInfo) == "function" then
            local ok, name = pcall(EJ_GetEncounterInfo, encounter)
            if ok and CleanName(name) ~= "" then
                boss = CleanName(name)
            end
        end
    end
    local names = {}
    for name in ((fields[10] or "") .. ","):gmatch("([^,]*),") do
        name = CleanName(name)
        if name ~= "" and #names < 40 then
            names[#names + 1] = name
        end
    end
    -- Was the sender there (in the list of names)?
    local listed = Firsts.SenderListed(names, sender)
    -- A kill just now gets the banner only from someone who was there, and
    -- at most LIVE_PER_SENDER per sender an hour. From anyone else it is a
    -- catch-up answer (to a member who just logged in): stored quietly, like
    -- any older first.
    local live = now - when <= LIVE_SECONDS and listed and Firsts.LiveAllowed(sender)

    Firsts.heard = Firsts.heard + 1
    local mine = false
    for _, name in ipairs(names) do
        mine = mine or Firsts.IsMine(name)
    end
    local rec = {
        key = key, kind = "F", type = kind, enc = Num(tonumber(fields[5] or "")) or 0, map = map,
        boss = boss, instance = instance, names = names, count = count, time = when,
    }
    local old = Firsts.Known(rec)
    if old then
        old.heard = true
        -- An earlier kill from a catch-up answer wins, but only told by someone
        -- who was there; a live message never moves a first we already have.
        -- The boss and raid names stay as we have them.
        if when < (old.time or 0) and not live and listed then
            old.time, old.names, old.count = when, names, count
            old.mine = old.mine or mine or nil
            old.trusted = true
        end
        QueueRefresh()
        return
    end
    if not Firsts.MakeRoom(listed) then
        return
    end
    rec.id = "F:" .. key
    rec.heard, rec.heardAt, rec.mine, rec.bannered = true, now, mine or nil, true
    rec.trusted = listed or nil
    db.firsts[key] = rec
    if live then
        Firsts.liveFrom[DW.IdentityKey(sender)] = Firsts.liveFrom[DW.IdentityKey(sender)] or {}
        table.insert(Firsts.liveFrom[DW.IdentityKey(sender)], GetTime())
        liveUntil = GetTime() + LIVE_WINDOW
        Firsts.Show(rec, mine)
    end
    QueueRefresh()
end

-- Is the sender one of the names in a first? Names in it are as the group
-- showed them ("Akro Polis"), the sender as the server gave it.
function Firsts.SenderListed(names, sender)
    if type(sender) ~= "string" or DW.IsSecret(sender) then
        return false
    end
    local from = DW.IdentityKey(sender)
    for _, name in ipairs(names) do
        if (from ~= "" and Firsts.Plain(name) == from) or DW.SameCharacter(name, sender) then
            return true
        end
    end
    return false
end

-- May this sender give one more live guild-first banner (at most
-- LIVE_PER_SENDER in an hour)?
function Firsts.LiveAllowed(sender)
    local list = Firsts.liveFrom[DW.IdentityKey(sender)]
    if not list then
        return true
    end
    local now, recent = GetTime(), {}
    for _, at in ipairs(list) do
        if now - at < 3600 then
            recent[#recent + 1] = at
        end
    end
    Firsts.liveFrom[DW.IdentityKey(sender)] = recent
    return #recent < Firsts.LIVE_PER_SENDER
end

-- Room for one more first. When the store is full, a first told by someone
-- who was there (or our own: trusted) pushes out the most recently heard
-- first that was not (a flood of made-up ones from catch-up answers cannot
-- lock out real firsts for good). Returns false when there is no room.
function Firsts.MakeRoom(trusted)
    if Firsts.Count() < Firsts.MAX then
        return true
    end
    if not trusted then
        return false
    end
    local dropKey, dropAt
    for key, rec in pairs(db.firsts) do
        if not rec.trusted and not rec.mine then
            local at = Num(rec.heardAt) or 0
            if not dropAt or at > dropAt or (at == dropAt and key > dropKey) then
                dropKey, dropAt = key, at
            end
        end
    end
    if not dropKey then
        return false
    end
    db.firsts[dropKey] = nil
    return true
end

-- The catch-up answer to R: the firsts stored or heard after since, newest
-- first, 5 at a time. Everyone has them, so we stop as soon as we hear
-- someone else send one (serial = Firsts.heard when the R came).
function Firsts.PlanReply(since, serial)
    local function Newer(rec)
        return math.max(Num(rec.time) or 0, Num(rec.heardAt) or 0)
    end
    local list = {}
    for _, rec in pairs(db.firsts) do
        if Newer(rec) > since then
            list[#list + 1] = rec
        end
    end
    if #list == 0 then
        return
    end
    table.sort(list, function(a, b)
        if Newer(a) ~= Newer(b) then
            return Newer(a) > Newer(b)
        end
        return a.key < b.key
    end)
    local done = 0
    local function Batch()
        if Firsts.heard ~= serial or not DW.IsMember() then
            return
        end
        local last = math.min(#list, Firsts.REPLY_MAX, done + Firsts.BATCH)
        for index = done + 1, last do
            Send(Firsts.Message(list[index]))
        end
        done = last
        if done < math.min(#list, Firsts.REPLY_MAX) then
            C_Timer.After(6 + math.random() * 2, Batch)
        end
    end
    C_Timer.After(3.2 + math.random() * 9, Batch)
end

-- An example of the banner ("/dw achievements first"); Gratz! sends nothing.
function Firsts.ShowSample()
    local _, name = DW.CharacterKey()
    return Firsts.Show({
        kind = "F", sample = true, type = "R", key = "sample", boss = "Ragnaros", instance = "Molten Core",
        names = { name or "Dragonworld" }, count = 1,
    }, false)
end

-- The roster ---------------------------------------------------------------------

local rosterSeen = {}  -- [key] = true for members we have read before in this session
local rosterCount      -- number of members the last time we read
local firstReadAt      -- GetTime() when we first read the roster in the session

local function ReadRoster()
    if not DW.IsMember() then
        return
    end
    local members = DW.ReadGuildRoster()
    if #members == 0 then
        return
    end
    rosterByGuid, rosterByName = {}, {}
    for _, member in ipairs(members) do
        if member.guid then
            rosterByGuid[member.guid] = member
        end
        rosterByName[DW.NameKey(member.key)] = member
    end

    local now = GetTime()
    firstReadAt = firstReadAt or now
    -- A member we have never seen is new in the guild. Right after login the
    -- list can arrive bit by bit, so only later it is something that happens now.
    local joinLive = now - firstReadAt > 60
    local myKey = MyKey()
    for _, member in ipairs(members) do
        local key = KeyOf(member.guid, member.key)
        local level = member.level
        local before = Num(db.levels[key])
        if level > 0 and before and level > before then
            -- If we have seen the member before in this session, and they are
            -- online, it happened now. Otherwise while you were away.
            local live = rosterSeen[key] and member.online
            for _, milestone in ipairs(LEVELS) do
                if before < milestone and milestone <= level then
                    local entry, new = Remember({
                        who = key, name = member.name, class = member.class, kind = "L", value = milestone,
                        time = Now(), exact = false,
                    })
                    if live then
                        liveUntil = now + LIVE_WINDOW
                        if not entry.bannered and key ~= myKey then
                            entry.bannered = true
                            Enqueue({ kind = "milestone", entry = entry })
                        end
                    elseif new then
                        entry.bannered = true
                    end
                end
            end
        end
        local nameKey = "name:" .. DW.NameKey(member.key)
        if member.guid then
            RekeyJoin(nameKey, key, member)
        end
        if db.joinInit and level > 0 and db.levels[key] == nil and db.levels[nameKey] == nil then
            OnRosterJoin(member, key, joinLive and member.online)
        end
        if level > 0 then
            db.levels[key] = level
        end
        rosterSeen[key] = true
    end
    -- The first read after the update (or on a new install) records no joins:
    -- everyone in it was there before.
    db.joinInit = true
    -- A new member while you are online is also something that happens now.
    -- (Right after login the list can arrive bit by bit, so not then.)
    if rosterCount and #members > rosterCount and now - firstReadAt > 60 then
        liveUntil = now + LIVE_WINDOW
    end
    rosterCount = #members
    Evaluate()
    QueueRefresh()
end

-- The tab ---------------------------------------------------------------------------

local FEED_ROW, GUILD_ROW = 32, 48
local BAR_WIDTH = 150
local panel
local view = "feed"
local feedRows, guildRows = {}, {}
local RefreshPanel

-- "5 min ago", "3 hours ago" ... or the date when it is a long time ago.
local function Ago(when)
    local seconds = math.max(0, Now() - (when or 0))
    if seconds < 60 then
        return L.GC_AGO_NOW
    elseif seconds < 3600 then
        return L.ACH_AGO_MINUTES:format(math.floor(seconds / 60))
    elseif seconds < 86400 then
        return L.GC_AGO_HOURS:format(math.floor(seconds / 3600))
    elseif seconds < 7 * 86400 then
        return L.GC_AGO_DAYS:format(math.floor(seconds / 86400))
    end
    return date("%d.%m.%Y", when)
end

-- The milestones and the guild firsts, newest first.
local function SortedFeed()
    local list = {}
    for _, entry in pairs(db.feed) do
        list[#list + 1] = entry
    end
    for key, rec in pairs(db.firsts) do
        rec.id = rec.id or ("F:" .. key)
        list[#list + 1] = rec
    end
    table.sort(list, function(a, b)
        if (a.time or 0) ~= (b.time or 0) then
            return (a.time or 0) > (b.time or 0)
        end
        return a.id < b.id
    end)
    return list
end

-- A join seen only in the roster gets a Welcome! button only while the new
-- member is online (it may have happened while you were away).
local function CanGratz(entry)
    if entry.kind == "F" then
        return not entry.gratz and not entry.mine and not entry.sample and Now() - (entry.time or 0) <= GRATZ_HOURS * 3600
    end
    local myKey = MyKey()
    if entry.gratz or entry.who == myKey or Now() - (entry.time or 0) > GRATZ_HOURS * 3600 then
        return false
    end
    return entry.kind ~= "J" or entry.exact == true or MemberOnline(entry.who)
end

-- The inviter's "Addon link" button, for a day after the join.
local function CanLink(entry)
    return entry.kind == "J" and entry.invited == true and not entry.linkSent and Now() - (entry.time or 0) <= LINK_SECONDS
end

-- The line's text: "Altine reached level 60", "Anna joined the guild" or
-- "Guild first: Altine, Borin defeated Edwin VanCleef in The Deadmines".
local function RowText(entry)
    if entry.kind == "J" then
        return L.WEL_ROW:format(ClassName(entry.name, entry.class))
    elseif entry.kind == "F" then
        return L.ACH_FIRST_ROW:format(WhoText(entry, true), Gold(entry.boss), entry.instance)
    end
    local _, _, wording = Wording(entry)
    return wording:format(ClassName(entry.name, entry.class), Gold(WhatText(entry)))
end

local function GetFeedRow(index)
    local row = feedRows[index]
    if row then
        return row
    end
    row = CreateFrame("Frame", nil, panel.content)
    row:SetSize(panel.content:GetWidth(), FEED_ROW - 2)
    row:SetPoint("TOPLEFT", 0, -(index - 1) * FEED_ROW)
    row:EnableMouse(true)

    row.icon = row:CreateTexture(nil, "ARTWORK")
    row.icon:SetSize(24, 24)
    row.icon:SetPoint("LEFT", 4, 0)
    row.icon:SetTexCoord(0.07, 0.93, 0.07, 0.93)

    row.gratz = DW.CreateButton(row, 90, 22, "gold")
    row.gratz:SetPoint("RIGHT", -4, 0)
    row.gratz:SetScript("OnClick", function(self)
        local entry = self:GetParent().entry
        if not Gratz(entry) and type(entry) == "table" and entry.kind == "J" and not entry.gratz then
            DW.Print(L.GC_BLOCKED)
        end
        RefreshPanel()
    end)

    -- The inviter's "Addon link" on a join.
    row.link = DW.CreateButton(row, 90, 22, "gold")
    row.link:SetPoint("RIGHT", row.gratz, "LEFT", -6, 0)
    row.link:Hide()
    row.link:SetScript("OnClick", function(self)
        if not SendAddonLink(self:GetParent().entry) then
            DW.Print(L.GC_BLOCKED)
        end
        RefreshPanel()
    end)

    row.when = row:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
    row.when:SetPoint("RIGHT", -100, 0)
    row.when:SetWidth(110)
    row.when:SetJustifyH("RIGHT")
    row.when:SetWordWrap(false)

    row.text = row:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
    row.text:SetPoint("LEFT", row.icon, "RIGHT", 8, 0)
    row.text:SetPoint("RIGHT", row.when, "LEFT", -8, 0)
    row.text:SetJustifyH("LEFT")
    row.text:SetWordWrap(false)

    row:SetScript("OnEnter", function(self)
        local entry = self.entry
        if not entry then
            return
        end
        GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
        if entry.kind == "F" then
            GameTooltip:AddLine(L.ACH_FIRST_ROW:format(WhoText(entry, false), entry.boss, entry.instance), 1, 1, 1, true)
            GameTooltip:AddLine(date("%d.%m.%Y %H:%M", entry.time or 0), 0.8, 0.8, 0.8)
            GameTooltip:AddLine(L.ACH_FIRST_TIP_GROUP:format(Num(entry.count) or 1, table.concat(entry.names or {}, ", ")), 0.4, 1, 0.4, true)
            GameTooltip:AddLine(L.ACH_FIRST_TIP, 0.7, 0.7, 0.7, true)
            if entry.gratz then
                GameTooltip:AddLine(L.ACH_TIP_GRATZED, 0.4, 1, 0.4)
            end
            GameTooltip:Show()
            return
        end
        if entry.kind == "J" then
            GameTooltip:AddLine(L.WEL_ROW:format(entry.name), 1, 1, 1)
            GameTooltip:AddLine(date("%d.%m.%Y %H:%M", entry.time or 0), 0.8, 0.8, 0.8)
            if not entry.exact then
                GameTooltip:AddLine(L.ACH_TIP_SEEN, 0.7, 0.7, 0.7, true)
            end
            if entry.invited then
                GameTooltip:AddLine(L.WEL_TIP_INVITED, 1, 0.82, 0)
            end
            if entry.gratz then
                GameTooltip:AddLine(L.WEL_TIP_WELCOMED, 0.4, 1, 0.4)
            end
            if entry.linkSent then
                GameTooltip:AddLine(L.WEL_TIP_LINK_SENT, 0.4, 1, 0.4)
            end
            GameTooltip:Show()
            return
        end
        local _, _, wording = Wording(entry)
        GameTooltip:AddLine(wording:format(entry.name, WhatText(entry)), 1, 1, 1)
        local info = entry.kind == "A" and ChallengeInfo(entry.line)
        if info and info.description ~= "" then
            GameTooltip:AddLine(info.description, 1, 0.82, 0, true)
        end
        GameTooltip:AddLine(date("%d.%m.%Y %H:%M", entry.time or 0), 0.8, 0.8, 0.8)
        if not entry.exact then
            GameTooltip:AddLine(L.ACH_TIP_SEEN, 0.7, 0.7, 0.7, true)
        end
        if entry.gratz then
            GameTooltip:AddLine(L.ACH_TIP_GRATZED, 0.4, 1, 0.4)
        end
        GameTooltip:Show()
    end)
    row:SetScript("OnLeave", function()
        GameTooltip:Hide()
    end)

    feedRows[index] = row
    return row
end

-- Who has 300 in each profession in the group, for the tooltip.
local function AddMastersToTooltip(achievement)
    local stats = GuildStats()
    for _, line in ipairs(PROFESSION_ORDER) do
        if not achievement.group or PROFESSIONS[line][2] == achievement.group then
            local names = stats.masters[line]
            if names or achievement.group then
                local who = names and table.concat(names, ", ") or "-"
                if names then
                    GameTooltip:AddLine(("%s: %s"):format(ProfessionName(line), who), 0.4, 1, 0.4)
                else
                    GameTooltip:AddLine(("%s: %s"):format(ProfessionName(line), who), 0.6, 0.6, 0.6)
                end
            end
        end
    end
    GameTooltip:AddLine(L.ACH_TIP_ADDON, 0.7, 0.7, 0.7, true)
end

local function GetGuildRow(index)
    local row = guildRows[index]
    if row then
        return row
    end
    row = CreateFrame("Frame", nil, panel.content)
    row:SetSize(panel.content:GetWidth(), GUILD_ROW - 4)
    row:SetPoint("TOPLEFT", 0, -(index - 1) * GUILD_ROW)
    row:EnableMouse(true)

    row.icon = row:CreateTexture(nil, "ARTWORK")
    row.icon:SetSize(36, 36)
    row.icon:SetPoint("LEFT", 4, 0)
    row.icon:SetTexCoord(0.07, 0.93, 0.07, 0.93)

    row.status = row:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    row.status:SetPoint("TOPRIGHT", -8, -6)
    row.status:SetWidth(BAR_WIDTH + 20)
    row.status:SetJustifyH("RIGHT")
    row.status:SetWordWrap(false)

    row.barBack = row:CreateTexture(nil, "ARTWORK")
    row.barBack:SetSize(BAR_WIDTH, 10)
    row.barBack:SetPoint("BOTTOMRIGHT", -8, 8)
    row.barBack:SetColorTexture(0.15, 0.15, 0.17, 1)
    row.bar = row:CreateTexture(nil, "OVERLAY")
    row.bar:SetHeight(10)
    row.bar:SetPoint("LEFT", row.barBack, "LEFT", 0, 0)
    row.bar:SetColorTexture(0.85, 0.65, 0.10, 1)

    row.name = row:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    row.name:SetPoint("TOPLEFT", row.icon, "TOPRIGHT", 10, -1)
    row.name:SetPoint("RIGHT", row.status, "LEFT", -10, 0)
    row.name:SetJustifyH("LEFT")
    row.name:SetWordWrap(false)

    row.desc = row:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    row.desc:SetPoint("TOPLEFT", row.name, "BOTTOMLEFT", 0, -4)
    row.desc:SetPoint("RIGHT", -(BAR_WIDTH + 24), 0)
    row.desc:SetJustifyH("LEFT")
    row.desc:SetWordWrap(false)

    row:SetScript("OnEnter", function(self)
        local achievement = self.achievement
        if not achievement then
            return
        end
        GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
        GameTooltip:AddLine(L[achievement.name], 1, 0.82, 0)
        GameTooltip:AddLine(achievement.Describe(), 1, 1, 1, true)
        if achievement.id:find("^prof_") then
            AddMastersToTooltip(achievement)
        end
        GameTooltip:Show()
    end)
    row:SetScript("OnLeave", function()
        GameTooltip:Hide()
    end)

    guildRows[index] = row
    return row
end

local function GuildDoneCount()
    local done = 0
    for _, achievement in ipairs(GUILD) do
        if db.guild[achievement.id] then
            done = done + 1
        end
    end
    return done
end

local function RefreshFeed()
    local list = SortedFeed()
    for index, entry in ipairs(list) do
        local row = GetFeedRow(index)
        row.entry = entry
        row.icon:SetTexture(EntryIcon(entry))
        row.text:SetText(RowText(entry))
        row.when:SetText(Ago(entry.time))
        row.gratz.label:SetText(entry.kind == "J" and L.WEL_BUTTON or L.ACH_GRATZ)
        row.gratz:SetShown(CanGratz(entry))
        local link = CanLink(entry)
        row.link.label:SetText(L.WEL_LINK_BUTTON)
        row.link:SetShown(link)
        row.when:ClearAllPoints()
        row.when:SetPoint("RIGHT", link and -196 or -100, 0)
        row:Show()
    end
    for index = #list + 1, #feedRows do
        feedRows[index].entry = nil
        feedRows[index]:Hide()
    end
    for _, row in ipairs(guildRows) do
        row:Hide()
    end
    panel.content:SetHeight(math.max(1, #list * FEED_ROW))
    panel.empty:SetText(L.ACH_EMPTY)
    panel.empty:SetShown(#list == 0)
end

local function RefreshGuild()
    local stats = GuildStats()
    for index, achievement in ipairs(GUILD) do
        local row = GetGuildRow(index)
        local done = db.guild[achievement.id]
        local value = math.min(achievement.value(stats), achievement.goal)
        row.achievement = achievement
        row.icon:SetTexture(achievement.icon)
        row.icon:SetDesaturated(not done)
        row.name:SetText(L[achievement.name])
        if done then
            row.name:SetTextColor(1.00, 0.82, 0.00)
        else
            row.name:SetTextColor(0.75, 0.75, 0.75)
        end
        row.desc:SetText(achievement.Describe())
        if done then
            row.status:SetText(done.time and L.ACH_DONE_ON:format(date("%d.%m.%Y", done.time)) or L.ACH_DONE_BEFORE)
            row.status:SetTextColor(0.40, 1.00, 0.40)
            value = achievement.goal
        else
            row.status:SetText(L.ACH_PROGRESS:format(value, achievement.goal))
            row.status:SetTextColor(1, 1, 1)
        end
        row.bar:SetWidth(math.max(1, BAR_WIDTH * value / achievement.goal))
        if done then
            row.bar:SetColorTexture(0.25, 0.75, 0.25, 1)
        else
            row.bar:SetColorTexture(0.85, 0.65, 0.10, 1)
        end
        row:Show()
    end
    for index = #GUILD + 1, #guildRows do
        guildRows[index]:Hide()
    end
    for _, row in ipairs(feedRows) do
        row.entry = nil
        row:Hide()
    end
    panel.content:SetHeight(#GUILD * GUILD_ROW)
    panel.empty:Hide()
end

RefreshPanel = function()
    if not panel or not panel:IsVisible() then
        return
    end
    Evaluate()
    panel.title:SetText(L.ACH_PANEL_TITLE)
    panel.feedChip.label:SetText(L.ACH_VIEW_FEED)
    panel.guildChip.label:SetText(L.ACH_VIEW_GUILD:format(GuildDoneCount(), #GUILD))
    panel.feedChip:SetSelected(view == "feed")
    panel.guildChip:SetSelected(view == "guild")
    panel.bannerCheck:SetChecked(db.banner ~= false)
    panel.bannerCheck.label:SetText(L.ACH_SHOW_BANNER)
    panel.soundCheck:SetChecked(db.sound ~= false)
    panel.soundCheck.label:SetText(L.ACH_SOUND)
    panel.welcomeCheck:SetChecked(db.welcome ~= false)
    panel.welcomeCheck.label:SetText(L.WEL_SHOW_BANNER)
    panel.newsCheck:SetChecked(db.newsBanner ~= false)
    panel.newsCheck.label:SetText(L.ACH_NEWS_BANNER)
    panel.sample.label:SetText(L.ACH_SAMPLE)
    if view == "guild" then
        RefreshGuild()
    else
        RefreshFeed()
    end
end

local refreshQueued = false

QueueRefresh = function()
    if refreshQueued or not panel or not panel:IsVisible() then
        return
    end
    refreshQueued = true
    C_Timer.After(0.25, function()
        refreshQueued = false
        RefreshPanel()
    end)
end

-- An example of the banner, with your own name, so you see what it looks like.
local function ShowSample()
    local _, name = DW.CharacterKey()
    Enqueue({
        kind = "milestone", sample = true,
        entry = { name = name or "Dragonworld", class = MyClass(), kind = "L", value = 60, sample = true },
    })
end

local function CreateCheck(parent, onClick)
    local check = CreateFrame("CheckButton", nil, parent, "UICheckButtonTemplate")
    check:SetSize(24, 24)
    check:SetScript("OnClick", onClick)
    check.label = parent:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
    check.label:SetPoint("LEFT", check, "RIGHT", 4, 0)
    check.label:SetJustifyH("LEFT")
    return check
end

local function CreatePanel(parent)
    local f = CreateFrame("Frame", nil, parent)
    f:SetAllPoints(parent)
    panel = f

    f.title = f:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
    f.title:SetPoint("TOP", 0, -12)

    -- Milestones or guild achievements.
    f.feedChip = DW.CreateChip(f, 170, 26)
    f.feedChip:SetPoint("TOPLEFT", 14, -40)
    f.feedChip:SetScript("OnClick", function()
        view = "feed"
        RefreshPanel()
    end)
    f.guildChip = DW.CreateChip(f, 230, 26)
    f.guildChip:SetPoint("LEFT", f.feedChip, "RIGHT", 8, 0)
    f.guildChip:SetScript("OnClick", function()
        view = "guild"
        RefreshPanel()
    end)

    local scroll = CreateFrame("ScrollFrame", "DragonworldAchievementsScroll", f, "ScrollFrameTemplate")
    scroll:SetPoint("TOPLEFT", 10, -76)
    scroll:SetPoint("BOTTOMRIGHT", -30, 68)
    f.content = CreateFrame("Frame", nil, scroll)
    f.content:SetSize(parent:GetWidth() - 10 - 30, 1)
    scroll:SetScrollChild(f.content)

    f.empty = f:CreateFontString(nil, "OVERLAY", "GameFontDisable")
    f.empty:SetPoint("TOP", scroll, "TOP", 0, -40)
    f.empty:SetWidth(440)

    -- Banner on/off, sound on/off, and an example.
    f.bannerCheck = CreateCheck(f, function(self)
        db.banner = self:GetChecked() and true or false
    end)
    f.bannerCheck:SetPoint("BOTTOMLEFT", 12, 10)
    f.soundCheck = CreateCheck(f, function(self)
        db.sound = self:GetChecked() and true or false
    end)
    f.soundCheck:SetPoint("BOTTOMLEFT", 250, 10)
    -- The welcome banner for new members has its own box.
    f.welcomeCheck = CreateCheck(f, function(self)
        db.welcome = self:GetChecked() and true or false
    end)
    f.welcomeCheck:SetPoint("BOTTOMLEFT", 12, 38)
    -- Announcements and polls (Kunngjoringer.lua, Forslag.lua) have their own
    -- box too: the milestone box does not cover them.
    f.newsCheck = CreateCheck(f, function(self)
        db.newsBanner = self:GetChecked() and true or false
    end)
    f.newsCheck:SetPoint("BOTTOMLEFT", 250, 38)
    f.newsCheck.label:SetWidth(parent:GetWidth() - 250 - 28 - 14)
    f.newsCheck.label:SetWordWrap(false)
    -- The example takes turns: a milestone, then a welcome.
    f.sample = DW.CreateButton(f, 170, 26, "gold")
    f.sample:SetPoint("BOTTOMRIGHT", -14, 10)
    local welcomeNext = false
    f.sample:SetScript("OnClick", function()
        if welcomeNext then
            ShowWelcomeSample()
        else
            ShowSample()
        end
        welcomeNext = not welcomeNext
    end)

    f:SetScript("OnShow", function()
        if C_GuildInfo and C_GuildInfo.GuildRoster then
            C_GuildInfo.GuildRoster()
        end
        RefreshPanel()
    end)
    return f
end

-- Events ----------------------------------------------------------------------

local helloSent = false
local rosterQueued, professionsQueued = false, false

local function QueueRosterRead()
    if rosterQueued or not (C_Timer and C_Timer.After) then
        return
    end
    rosterQueued = true
    C_Timer.After(1.5, function()
        rosterQueued = false
        ReadRoster()
    end)
end

local function QueueProfessionCheck()
    if professionsQueued or not helloSent or not (C_Timer and C_Timer.After) then
        return
    end
    professionsQueued = true
    C_Timer.After(2.2, function()
        professionsQueued = false
        if DW.IsMember() then
            CheckOwnProfessions()
        end
    end)
end

local function PlanHello()
    if helloSent or not (C_Timer and C_Timer.After) then
        return
    end
    C_Timer.After(HELLO_DELAY, function()
        if helloSent or not DW.IsMember() then
            return
        end
        helloSent = true
        Firsts.helloAt = GetTime() -- kills count as firsts SETTLE seconds after this
        -- Where own professions stand now, so we notice when they reach 300.
        CheckOwnProfessions()
        Publish()
        Send(DW.SyncRequest())
        QueueRosterRead()
    end)
end

local frame = CreateFrame("Frame")
frame:SetScript("OnEvent", function(self, event, ...)
    if not DW.IsMember() then
        return
    end
    if event == "PLAYER_LEVEL_UP" then
        OnLevelUp(...)
    elseif event == "ACHIEVEMENT_EARNED" then
        OnAchievementEarned(...)
    elseif event == "GUILD_ROSTER_UPDATE" then
        QueueRosterRead()
    elseif event == "PLAYER_ENTERING_WORLD" then
        PlanHello()
        Firsts.PlanSnapshot()
    elseif event == "CHAT_MSG_SYSTEM" then
        OnSystemMessage(...)
    elseif event == "ENCOUNTER_END" then
        local id, name, _, size, success = ...
        if success == nil or DW.IsSecret(success) then
            Firsts.signals.hidden = Firsts.signals.hidden + 1
        elseif Num(success) == 1 or success == true then
            Firsts.OnKill("ee", id, name, size)
        end
    elseif event == "BOSS_KILL" then
        local id, name = ...
        Firsts.OnKill("bk", id, name, nil)
    elseif event == "PLAYER_REGEN_ENABLED" then
        Firsts.fightEndAt = GetTime()
        Firsts.RunPending()
        Firsts.PlanCheck(true)
    elseif event == "ZONE_CHANGED_NEW_AREA" then
        Firsts.PlanSnapshot()
    elseif event == "UPDATE_INSTANCE_INFO" then
        Firsts.PlanCheck(false)
    elseif event == "INSTANCE_LOCK_START" then
        Firsts.PlanCheck(true)
    else
        QueueProfessionCheck()
    end
end)
for _, event in ipairs({
    "PLAYER_ENTERING_WORLD",
    "PLAYER_LEVEL_UP",
    "ACHIEVEMENT_EARNED",
    "GUILD_ROSTER_UPDATE",
    "CHAT_MSG_SYSTEM",
    "ENCOUNTER_END",
    "BOSS_KILL",
    "PLAYER_REGEN_ENABLED",
    "ZONE_CHANGED_NEW_AREA",
    "UPDATE_INSTANCE_INFO",
    "INSTANCE_LOCK_START",
    "SKILL_LINES_CHANGED",
    "CHAT_MSG_SKILL",
    "TRADE_SKILL_SHOW",
    "TRADE_SKILL_LIST_UPDATE",
    "TRADE_SKILL_CLOSE",
}) do
    pcall(frame.RegisterEvent, frame, event)
end

DW.OnMembershipChanged(function(member)
    if member then
        PlanHello()
        QueueRosterRead()
    end
end)

DW.OnLanguageChanged(function()
    RefreshPanel()
    if banner and banner:IsShown() then
        FillBanner()
    end
end)

-- For other files and the tests ------------------------------------------------------

-- The guild achievements with how far the guild has come:
-- { { id, value, goal, done = { time } / { before = true } / nil }, ... }
function DW.GuildAchievements()
    local stats = GuildStats()
    local list = {}
    for _, achievement in ipairs(GUILD) do
        list[#list + 1] = { id = achievement.id, value = achievement.value(stats), goal = achievement.goal, done = db.guild[achievement.id] }
    end
    return list
end

-- Shows an example of the banner ("/dw achievements test").
DW.ShowMilestoneSample = ShowSample

-- Shows an example of the welcome banner ("/dw achievements welcome").
DW.ShowWelcomeSample = ShowWelcomeSample

-- Shows an example of the guild-first banner ("/dw achievements first").
DW.ShowGuildFirstSample = Firsts.ShowSample

-- The guild firsts, newest first (copies):
-- { { key, type = "D"/"R", boss, instance, names, count, time, mine }, ... }
function DW.GuildFirsts()
    local list = {}
    for key, rec in pairs(db.firsts) do
        local names = {}
        for index, name in ipairs(type(rec.names) == "table" and rec.names or {}) do
            names[index] = name
        end
        list[#list + 1] = {
            key = key, type = rec.type, boss = rec.boss, instance = rec.instance, names = names,
            count = rec.count, time = rec.time, mine = rec.mine == true,
        }
    end
    table.sort(list, function(a, b)
        if (a.time or 0) ~= (b.time or 0) then
            return (a.time or 0) > (b.time or 0)
        end
        return a.key < b.key
    end)
    return list
end

-- Members who joined after since (server time), newest first:
-- { { who, name, class, time, exact }, ... }
function DW.RecentJoins(since)
    since = Num(since) or 0
    local list = {}
    for _, entry in pairs(db.feed) do
        if entry.kind == "J" and (entry.time or 0) > since then
            list[#list + 1] = { who = entry.who, name = entry.name, class = entry.class, time = entry.time, exact = entry.exact, id = entry.id }
        end
    end
    table.sort(list, Newest)
    for _, item in ipairs(list) do
        item.id = nil
    end
    return list
end

-- The Welcome! button for a roster member who joined recently (for other
-- tabs): { text, onClick }, or nil when there is nothing to welcome.
function DW.WelcomeButtonFor(member)
    if type(member) ~= "table" then
        return nil
    end
    local entry = db.feed[KeyOf(member.guid, member.key) .. ":J"] or db.feed["name:" .. DW.NameKey(member.key) .. ":J"]
    if not entry or not CanGratz(entry) then
        return nil
    end
    return {
        text = L.WEL_BUTTON,
        onClick = function()
            if not Gratz(entry) then
                DW.Print(L.GC_BLOCKED)
            end
            RefreshPanel()
        end,
    }
end

DW.AddDebug("prestasjoner", function(add)
    local count, mine, exact = 0, 0, 0
    local myKey = MyKey()
    for _, entry in pairs(db.feed) do
        count = count + 1
        if entry.who == myKey then
            mine = mine + 1
        end
        if entry.exact then
            exact = exact + 1
        end
    end
    local levels = 0
    for _ in pairs(db.levels) do
        levels = levels + 1
    end
    add(("milepæler: %d (egne %d, med nøyaktig tid %d) | level kjent for %d medlemmer"):format(count, mine, exact, levels))
    local key = MySendKey()
    local seen = key and db.mine[key]
    local parts = {}
    for name, level in pairs(type(seen) == "table" and seen or {}) do
        parts[#parts + 1] = name .. "=" .. tostring(level)
    end
    table.sort(parts)
    add("egne professions sist sett: " .. (#parts > 0 and table.concat(parts, ", ") or "ingen ennå"))
    add(("guild-prestasjoner: %d av %d | banner: %s | lyd: %s (kit %s) | PlaySound: %s"):format(GuildDoneCount(), #GUILD,
        tostring(db.banner ~= false), tostring(db.sound ~= false), tostring(FanfareKit()), tostring(type(PlaySound) == "function")))

    -- New members: the game's texts the system message is matched against.
    local joins, invites = 0, 0
    for _, entry in pairs(db.feed) do
        if entry.kind == "J" then
            joins = joins + 1
        end
    end
    for _ in pairs(type(db.invites) == "table" and db.invites or {}) do
        invites = invites + 1
    end
    add(("velkomst: ERR_GUILD_JOIN_S=%s | ERR_GUILD_INVITE_S=%s | Invite-krok=%s | nye medlemmer i lista=%d | invitasjoner=%d | joinInit=%s"):format(
        DW.DebugText(_G.ERR_GUILD_JOIN_S), DW.DebugText(_G.ERR_GUILD_INVITE_S),
        tostring(C_GuildInfo ~= nil and type(C_GuildInfo.Invite) == "function"), joins, invites, tostring(db.joinInit == true)))

    -- Guild firsts: which boss signals the game gives here (raids are not verified).
    local signals = Firsts.signals
    local inside, itype, instName, mapID = DW.InstanceInfo()
    add(("bosser: ENCOUNTER_END %d, BOSS_KILL %d, skjult %d, utsatt %d, lås-reserve %d | raid-hendelse sett: %s | GetInstanceInfo: %s | låsinfo: %s"):format(
        signals.ee, signals.bk, signals.hidden, signals.deferred, signals.lock, tostring(db.raidEventSeen == true),
        ("%s %s %s (%s)"):format(tostring(inside), itype, mapID, instName),
        type(GetInstanceLockTimeRemainingEncounter) == "function" and ("ja, kart " .. tostring(Firsts.lockMap or "-")) or "nei"))
    local kills = {}
    for id, item in pairs(db.bossLog) do
        if type(item) == "table" then
            kills[#kills + 1] = { id = id, item = item }
        end
    end
    table.sort(kills, function(a, b)
        return (Num(a.item.last) or 0) > (Num(b.item.last) or 0)
    end)
    local lines = {}
    for index = 1, math.min(6, #kills) do
        local item = kills[index].item
        lines[#lines + 1] = ("%s %s (kart %s, %s, %s)"):format(tostring(kills[index].id), Text(item.name),
            tostring(item.map), tostring(item.type), tostring(item.result))
    end
    add("siste bosser: " .. (#lines > 0 and table.concat(lines, ", ") or "ingen ennå"))
    add(("guild firsts: %d (dungeon %d, raid %d)"):format(Firsts.Count()))

    -- Legacy Challenges: what the game returns, so we can see it is right in Forever.
    local text = DW.DebugText
    add(("legacy: GetCategoryList %s | GetAchievementInfo %s | GetTraitCurrencyForAchievement %s"):format(
        text(type(GetCategoryList) == "function"), text(type(GetAchievementInfo) == "function"),
        text(C_Traits ~= nil and type(C_Traits.GetTraitCurrencyForAchievement) == "function")))
    if type(GetCategoryList) == "function" and type(GetCategoryNumAchievements) == "function" and type(GetAchievementInfo) == "function" then
        local ok, categories = pcall(GetCategoryList)
        local total, mine, points, examples = 0, 0, 0, {}
        for _, category in ipairs(ok and type(categories) == "table" and categories or {}) do
            local fine, count = pcall(GetCategoryNumAchievements, category)
            for index = 1, (fine and Num(count)) or 0 do
                local good, id, name, _, completed, _, _, _, _, _, _, _, _, earnedByMe = pcall(GetAchievementInfo, category, index)
                if good and Num(id) then
                    total = total + 1
                    if completed == true and earnedByMe ~= false then
                        mine = mine + 1
                        local worth = ChallengePoints(id)
                        points = points + (worth or 0)
                        if #examples < 4 then
                            examples[#examples + 1] = ("%s (%s) %s"):format(text(name), text(id), worth and ("+" .. worth) or "?")
                        end
                    end
                end
            end
        end
        add(("utfordringer: %d i %d kategorier | fullført av deg: %d, %d poeng | %s"):format(total,
            ok and type(categories) == "table" and #categories or 0, mine, points, table.concat(examples, ", ")))
    end
end)

-- Module -------------------------------------------------------------------------

local SAMPLE_WORDS = { test = true, eksempel = true, voorbeeld = true, example = true }
local WELCOME_WORDS = { welcome = true, velkommen = true, welkom = true, willkommen = true, ["välkommen"] = true, bienvenue = true }

DW.RegisterModule({
    id = MODULE_ID,
    titleKey = "ACH_TITLE",
    notesKey = "ACH_NOTES",
    icon = "Interface\\Icons\\Achievement_Level_60",

    OnLoad = function(self, saved)
        for _, field in ipairs({ "feed", "levels", "mine", "guild", "invites", "firsts", "bossLog" }) do
            if type(saved[field]) ~= "table" then
                saved[field] = {}
            end
        end
        -- Entries from a corrupted file are not included.
        for id, entry in pairs(saved.feed) do
            if type(entry) ~= "table" or type(entry.who) ~= "string" or type(entry.name) ~= "string"
                or (entry.kind ~= "L" and entry.kind ~= "P" and entry.kind ~= "A" and entry.kind ~= "J") or type(entry.value) ~= "number" then
                saved.feed[id] = nil
            else
                entry.id = id
            end
        end
        -- Invites older than an hour no longer count.
        local now = Now()
        for nameKey, at in pairs(saved.invites) do
            if type(at) ~= "number" or now - at > INVITE_KEEP then
                saved.invites[nameKey] = nil
            end
        end
        -- Guild firsts from a corrupted file are not included either.
        for key, rec in pairs(saved.firsts) do
            if type(key) ~= "string" or type(rec) ~= "table"
                or not (key:find("^d%d+$") or key:find("^e%d+$") or key:find("^L%d+%.%d+$"))
                or (rec.type ~= "D" and rec.type ~= "R") or type(rec.time) ~= "number"
                or type(rec.boss) ~= "string" or type(rec.instance) ~= "string" then
                saved.firsts[key] = nil
            else
                local names = {}
                for _, name in ipairs(type(rec.names) == "table" and rec.names or {}) do
                    if type(name) == "string" and name ~= "" then
                        names[#names + 1] = name
                    end
                end
                rec.names = names
                rec.count = math.max(1, math.floor(tonumber(rec.count) or #names))
                rec.heardAt = type(rec.heardAt) == "number" and rec.heardAt or rec.time
                rec.key, rec.kind, rec.id = key, "F", "F:" .. key
            end
        end
        for id, item in pairs(saved.bossLog) do
            if type(item) ~= "table" then
                saved.bossLog[id] = nil
            end
        end
        db = saved
    end,

    OnSlash = function(self, message)
        local word = (message or ""):lower()
        if WELCOME_WORDS[word] then
            ShowWelcomeSample()
        elseif Firsts.WORDS[word] then
            Firsts.ShowSample()
        elseif SAMPLE_WORDS[word] then
            ShowSample()
        elseif DW.OpenModule then
            DW.OpenModule(MODULE_ID)
        end
    end,

    CreatePanel = function(self, parent)
        return CreatePanel(parent)
    end,
})

-- The Home page (Modules\Home.lua): milestones, joins and guild firsts since you
-- last played, not your own. When Home has last session's member list, it
-- shows levels and joins itself (with this file's Welcome! button), so
-- level milestones and joins are left out here.
DW.RegisterHomeSection({
    id = "milestones",
    order = 30,
    titleKey = "HOME_SEC_MILESTONES",
    icon = "Interface\\Icons\\Achievement_Level_60",
    Lines = function(ctx)
        local since = ctx.since
        if not since then
            return {}
        end
        local lines, me = {}, MyKey()
        for _, entry in ipairs(SortedFeed()) do
            if (entry.time or 0) > since and not (entry.mine or (me and entry.who == me))
                and not (ctx.hasRosterBaseline and (entry.kind == "L" or entry.kind == "J")) then
                local member = entry.who and ctx.Member(entry.who)
                -- A guild first is about everyone in the kill: Home's green
                -- dot shows when one of them is online.
                local members
                if entry.kind == "F" then
                    members = {}
                    for _, name in ipairs(type(entry.names) == "table" and entry.names or {}) do
                        members[#members + 1] = ctx.Member(Text(name))
                    end
                end
                lines[#lines + 1] = {
                    text = RowText(entry), icon = EntryIcon(entry), when = entry.time, changed = true,
                    member = member or nil, members = members, tab = MODULE_ID,
                    onClick = function()
                        DW.OpenModule(MODULE_ID)
                    end,
                    button = CanGratz(entry) and {
                        text = entry.kind == "J" and L.WEL_BUTTON or L.ACH_GRATZ,
                        onClick = function()
                            Gratz(entry)
                            RefreshPanel()
                        end,
                    } or nil,
                }
            end
        end
        return lines
    end,
})
