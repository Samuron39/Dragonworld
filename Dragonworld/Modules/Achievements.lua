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
-- "line" is the game's number for the profession (164 = Blacksmithing), the
-- same in all clients; the last field is the name as the sender's client
-- spells it.
-- For legacy, id is the game's number for the challenge; the receiver looks
-- up the name in their own language and uses the title only if the game does
-- not know it.
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

-- Saved (for the whole account). Set in OnLoad at the bottom.
--   db.feed[id]     = { id, who, name, class, kind = "L"/"P"/"A", value, line, prof,
--                       time, exact, bannered, gratz, sent }
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
--   db.bannerPos    = { point, point, x, y } if the banner has been moved
local db = { feed = {}, levels = {}, mine = {}, guild = {} }

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

-- Removes the oldest when the list gets too long.
local function Prune()
    local list = {}
    for _, entry in pairs(db.feed) do
        list[#list + 1] = entry
    end
    if #list <= FEED_MAX then
        return
    end
    table.sort(list, function(a, b)
        return (a.time or 0) > (b.time or 0)
    end)
    for index = FEED_MAX + 1, #list do
        db.feed[list[index].id] = nil
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
    text = text:gsub("|", "/")
    local send = (C_ChatInfo and C_ChatInfo.SendChatMessage) or SendChatMessage
    if type(send) ~= "function" then
        return false
    end
    if C_ChatInfo and C_ChatInfo.InChatMessagingLockdown and C_ChatInfo.InChatMessagingLockdown() then
        return false
    end
    return (pcall(send, text, "GUILD"))
end

-- Congratulates in guild chat, once per milestone.
local function Gratz(entry)
    if type(entry) ~= "table" or entry.gratz or entry.sample then
        return false
    end
    local what = entry.kind == "A" and ChallengeTitle(entry) or WhatText(entry)
    if SendGuildChat(L.ACH_GRATZ_CHAT:format(what, entry.name)) then
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

local function PlayFanfare()
    if db.sound == false or type(PlaySound) ~= "function" then
        return
    end
    pcall(PlaySound, FanfareKit())
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

    -- Gratz! (or Hurra! when it is about you or the whole guild).
    b.button = DW.CreateButton(b, 150, 36, "gold")
    b.button:SetPoint("RIGHT", -28, -10)
    b.button:SetScript("OnClick", function()
        local item = b.item
        if item and item.entry and not item.own then
            Gratz(item.entry)
        end
        FinishBanner()
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
    banner.age, banner.left, banner.closing, banner.fade = 0, BANNER_SECONDS, false, 0
    FillBanner()
    PlaceBanner()
    banner:SetAlpha(0)
    banner:Show()
    PlayFanfare()
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
-- (except the example, which the player asks for themselves).
local function Enqueue(item)
    if db.banner == false and not item.sample then
        return
    end
    if #queue >= QUEUE_MAX then
        return
    end
    queue[#queue + 1] = item
    NextBanner()
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

local function ScheduleReply(since)
    replySince = math.min(replySince or since, since)
    if replyScheduled then
        return
    end
    replyScheduled = true
    C_Timer.After(1 + math.random() * 5, function()
        replyScheduled = false
        local from = replySince or 0
        replySince = nil
        if DW.IsMember() then
            Publish(from)
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
        if level > 0 then
            db.levels[key] = level
        end
        rosterSeen[key] = true
    end
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

local function SortedFeed()
    local list = {}
    for _, entry in pairs(db.feed) do
        list[#list + 1] = entry
    end
    table.sort(list, function(a, b)
        if (a.time or 0) ~= (b.time or 0) then
            return (a.time or 0) > (b.time or 0)
        end
        return a.id < b.id
    end)
    return list
end

local function CanGratz(entry)
    local myKey = MyKey()
    return not entry.gratz and entry.who ~= myKey and Now() - (entry.time or 0) <= GRATZ_HOURS * 3600
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

    row.gratz = DW.CreateButton(row, 74, 22, "gold")
    row.gratz:SetPoint("RIGHT", -4, 0)
    row.gratz:SetScript("OnClick", function(self)
        Gratz(self:GetParent().entry)
        RefreshPanel()
    end)

    row.when = row:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
    row.when:SetPoint("RIGHT", -84, 0)
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
        local _, _, wording = Wording(entry)
        row.text:SetText(wording:format(ClassName(entry.name, entry.class), Gold(WhatText(entry))))
        row.when:SetText(Ago(entry.time))
        row.gratz.label:SetText(L.ACH_GRATZ)
        row.gratz:SetShown(CanGratz(entry))
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
    scroll:SetPoint("BOTTOMRIGHT", -30, 42)
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
    f.sample = DW.CreateButton(f, 170, 26, "gold")
    f.sample:SetPoint("BOTTOMRIGHT", -14, 10)
    f.sample:SetScript("OnClick", ShowSample)

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
    else
        QueueProfessionCheck()
    end
end)
for _, event in ipairs({
    "PLAYER_ENTERING_WORLD",
    "PLAYER_LEVEL_UP",
    "ACHIEVEMENT_EARNED",
    "GUILD_ROSTER_UPDATE",
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

DW.RegisterModule({
    id = MODULE_ID,
    titleKey = "ACH_TITLE",
    notesKey = "ACH_NOTES",
    icon = "Interface\\Icons\\Achievement_Level_60",

    OnLoad = function(self, saved)
        for _, field in ipairs({ "feed", "levels", "mine", "guild" }) do
            if type(saved[field]) ~= "table" then
                saved[field] = {}
            end
        end
        -- Entries from a corrupted file are not included.
        for id, entry in pairs(saved.feed) do
            if type(entry) ~= "table" or type(entry.who) ~= "string" or type(entry.name) ~= "string"
                or (entry.kind ~= "L" and entry.kind ~= "P" and entry.kind ~= "A") or type(entry.value) ~= "number" then
                saved.feed[id] = nil
            else
                entry.id = id
            end
        end
        db = saved
    end,

    OnSlash = function(self, message)
        if SAMPLE_WORDS[(message or ""):lower()] then
            ShowSample()
        elseif DW.OpenModule then
            DW.OpenModule(MODULE_ID)
        end
    end,

    CreatePanel = function(self, parent)
        return CreatePanel(parent)
    end,
})
