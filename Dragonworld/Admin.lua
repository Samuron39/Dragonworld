-- Dragonworld - admin code and officers (guild rank)
--
-- Two kinds of rights, kept apart:
--   * The admin code is only for Forslag (suggestions): logged in with the
--     code, you can mark suggestions as done or rejected, and reopen them
--     (Modules\Forslag.lua). Only the guild leader has the code, because
--     they are the one who changes the addon.
--   * Officer ranks (below) are for everything else: announcements, ending
--     and deleting anyone's poll, deleting spam guild events, and so on.
--
-- Admin code ------------------------------------------------------------------
-- The login is remembered on the account (DragonworldDB.admin) until you log
-- out. The code is not in the addon, only a fingerprint of it (SHA-256 with
-- salt, 100 rounds). The addon is public on GitHub, so the code itself must
-- not be here. This is a simple lock, not real security: anyone who wants to
-- can change the files in their own addon, and the others in the guild can't
-- check who is admin.
--
-- New code: compute the fingerprint with DW.AdminHash("new code") (e.g. with
-- /run print(DragonworldAdminHash("new code")) in the game) and change ADMIN_HASH.
--
-- Officers --------------------------------------------------------------------
-- Officer rights come from the character's guild rank. Rank 0 is the Guild
-- Master; a character is an officer when its rank index is at or below the
-- officer limit (default 1: the Guild Master and the rank just below). The
-- Guild Master can change the limit (DW.SetOfficerLimit); the limit is shared
-- with the guild on the DragonworldOff messages.
--
-- Security: the rank comes from the game. The sender of an addon message is
-- set by the server and cannot be faked, so an officer action is accepted only
-- from its actor (sender == by), or from an officer relaying it. The
-- self-written `by` field alone is never trusted. Helpers for that, used by
-- the modules:
--   DW.MayActFor(sender, by)                       may this sender speak for by?
--   DW.WhenOfficerAction(key, sender, by, author, fn)  fn(true/false), maybe later
--   DW.WhenOfficerKnown(who, fn)                   fn(true/false), maybe later
-- Announcements and polls are the exception: any guild member may pass on a
-- version made by an officer (or a poll by its author), so members who log in
-- while no officer is online still get them. A faked version in someone's
-- name is removed by that person's own client (Kunngjoringer.lua, Forslag.lua).
--   DW.TrustedVersion(by, author)                  is this version by its author or an officer?
--   DW.MayRelay(sender, by, author)                ...and is the sender a guild member?
--   DW.WhenRelayedAction(key, sender, by, author, fn)  fn(true/false), maybe later
--   DW.IsMemberKey(who)                            in the guild roster? true, or nil if unknown
--   DW.WhenMemberKnown(who, fn)                    fn(true/false), maybe later
--   DW.NewHeldStore(saved, name)                   versions rejected or undecided
--
-- Saved (account-wide):
--   DragonworldDB.admin = { on = true } while logged in with the admin code
--   DragonworldDB.officerRanks = { limit = 0..9, at = server time, by = "Name-Realm" of the GM }
--
-- Messages (name DragonworldOff, fields separated by tab):
--   V at                 hello: the time of the limit I have (once per session)
--   W                    "you have a newer limit than me, send it"
--   K limit at by        the limit, set by `by` (the Guild Master) at `at`

local ADDON_NAME, DW = ...
local L = DW.L

local PREFIX = "DragonworldOff" -- max 16 characters
local SEP = "\t"

local DEFAULT_LIMIT = 1   -- the Guild Master and the rank just below
local MAX_LIMIT = 9
local HELLO_DELAY = 15    -- after login (other modules use other delays)
local W_EVERY = 30        -- at most one W per this many seconds
local K_FUTURE = 300      -- how far ahead of the server clock a K may be
local REQUEST_EVERY = 10  -- at most one roster request per this many seconds
local RECENT_SENDER = 120 -- a sender seen this recently gets a fresh roster on a "no"
local PENDING_SECONDS = 120
local PENDING_TIMER = 121
local MAX_PENDING = 200
local HELD_DAYS = 3
local DAY = 86400

-- Legacy messages (guild event deletions relayed by old clients, Events.lua)
-- are accepted as before until this server time: 2026-12-06 00:00 UTC, 14
-- days after officer ranks were built. Exported so the tests can move it.
DW.F6_CUTOFF = 1796515200

-- Admin code (Forslag only) ----------------------------------------------------

local ADMIN_HASH = "0a032bcf1282b6b43dedf77d6cbc5cd3766687d32885352353c559058b4278e3"
local SALT = "Dragonworld-admin:"
local ROUNDS = 100

-- SHA-256. Written for the game's Lua 5.1 with the bit library. All numbers
-- are kept as unsigned 32-bit numbers (0 to 2^32 - 1).
local Sha256
do
    local MOD = 2 ^ 32
    local function U(x)
        return x % MOD
    end

    local K = {
        0x428a2f98, 0x71374491, 0xb5c0fbcf, 0xe9b5dba5, 0x3956c25b, 0x59f111f1, 0x923f82a4, 0xab1c5ed5,
        0xd807aa98, 0x12835b01, 0x243185be, 0x550c7dc3, 0x72be5d74, 0x80deb1fe, 0x9bdc06a7, 0xc19bf174,
        0xe49b69c1, 0xefbe4786, 0x0fc19dc6, 0x240ca1cc, 0x2de92c6f, 0x4a7484aa, 0x5cb0a9dc, 0x76f988da,
        0x983e5152, 0xa831c66d, 0xb00327c8, 0xbf597fc7, 0xc6e00bf3, 0xd5a79147, 0x06ca6351, 0x14292967,
        0x27b70a85, 0x2e1b2138, 0x4d2c6dfc, 0x53380d13, 0x650a7354, 0x766a0abb, 0x81c2c92e, 0x92722c85,
        0xa2bfe8a1, 0xa81a664b, 0xc24b8b70, 0xc76c51a3, 0xd192e819, 0xd6990624, 0xf40e3585, 0x106aa070,
        0x19a4c116, 0x1e376c08, 0x2748774c, 0x34b0bcb5, 0x391c0cb3, 0x4ed8aa4a, 0x5b9cca4f, 0x682e6ff3,
        0x748f82ee, 0x78a5636f, 0x84c87814, 0x8cc70208, 0x90befffa, 0xa4506ceb, 0xbef9a3f7, 0xc67178f2,
    }
    local H0 = { 0x6a09e667, 0xbb67ae85, 0x3c6ef372, 0xa54ff53a, 0x510e527f, 0x9b05688c, 0x1f83d9ab, 0x5be0cd19 }
    for index, value in ipairs(K) do
        K[index] = U(value)
    end
    for index, value in ipairs(H0) do
        H0[index] = U(value)
    end

    local function band(a, b) return U(bit.band(a, b)) end
    local function bxor(a, b) return U(bit.bxor(a, b)) end
    local function bnot(a) return U(bit.bnot(a)) end
    local function rshift(a, n) return U(bit.rshift(a, n)) end
    local function rrotate(a, n)
        return U(bit.bor(bit.rshift(a, n), bit.lshift(a, 32 - n)))
    end

    -- The fingerprint of a text, as 64 hexadecimal characters.
    Sha256 = function(message)
        local length = #message
        local bits = length * 8
        message = message .. "\128" .. string.rep("\0", (55 - length) % 64)
            .. string.char(0, 0, 0, 0,
                math.floor(bits / 2 ^ 24) % 256, math.floor(bits / 2 ^ 16) % 256, math.floor(bits / 2 ^ 8) % 256, bits % 256)

        local h = {}
        for index = 1, 8 do
            h[index] = H0[index]
        end
        local w = {}
        for start = 1, #message, 64 do
            for i = 0, 15 do
                local a, b, c, d = message:byte(start + i * 4, start + i * 4 + 3)
                w[i] = U(((a * 256 + b) * 256 + c) * 256 + d)
            end
            for i = 16, 63 do
                local s0 = bxor(bxor(rrotate(w[i - 15], 7), rrotate(w[i - 15], 18)), rshift(w[i - 15], 3))
                local s1 = bxor(bxor(rrotate(w[i - 2], 17), rrotate(w[i - 2], 19)), rshift(w[i - 2], 10))
                w[i] = U(w[i - 16] + s0 + w[i - 7] + s1)
            end

            local a, b, c, d, e, f, g, hh = h[1], h[2], h[3], h[4], h[5], h[6], h[7], h[8]
            for i = 0, 63 do
                local s1 = bxor(bxor(rrotate(e, 6), rrotate(e, 11)), rrotate(e, 25))
                local ch = bxor(band(e, f), band(bnot(e), g))
                local t1 = U(hh + s1 + ch + K[i + 1] + w[i])
                local s0 = bxor(bxor(rrotate(a, 2), rrotate(a, 13)), rrotate(a, 22))
                local maj = bxor(bxor(band(a, b), band(a, c)), band(b, c))
                local t2 = U(s0 + maj)
                hh, g, f, e, d, c, b, a = g, f, e, U(d + t1), c, b, a, U(t1 + t2)
            end
            h[1], h[2], h[3], h[4] = U(h[1] + a), U(h[2] + b), U(h[3] + c), U(h[4] + d)
            h[5], h[6], h[7], h[8] = U(h[5] + e), U(h[6] + f), U(h[7] + g), U(h[8] + hh)
        end

        local out = {}
        for _, value in ipairs(h) do
            for shift = 24, 0, -8 do
                out[#out + 1] = ("%02x"):format(math.floor(value / 2 ^ shift) % 256)
            end
        end
        return table.concat(out)
    end
end
DW.Sha256 = Sha256

-- The fingerprint of an admin code, as it appears in ADMIN_HASH.
function DW.AdminHash(code)
    local hash = Sha256(SALT .. tostring(code))
    for _ = 2, ROUNDS do
        hash = Sha256(hash .. SALT)
    end
    return hash
end
DragonworldAdminHash = DW.AdminHash -- so it can be used with /run in the game

local adminListeners = {}

-- Called when you log in or out with the admin code.
function DW.OnAdminChanged(callback)
    adminListeners[#adminListeners + 1] = callback
end

local function AdminChanged()
    for _, callback in ipairs(adminListeners) do
        local ok, problem = pcall(callback)
        if not ok then
            DW.PrintError(L.ERROR, problem)
        end
    end
end

-- Logged in with the admin code? (Forslag only; officer rights are DW.IsOfficer.)
function DW.IsAdmin()
    return type(DragonworldDB) == "table" and type(DragonworldDB.admin) == "table" and DragonworldDB.admin.on == true
end

-- Tries a code. Returns true if it is correct.
function DW.AdminLogin(code)
    if type(code) ~= "string" or code == "" or type(DragonworldDB) ~= "table" then
        return false
    end
    if DW.AdminHash(code) ~= (DW.ADMIN_HASH or ADMIN_HASH) then
        return false
    end
    DragonworldDB.admin = { on = true }
    DW.Print(L.ADM_IN)
    AdminChanged()
    return true
end

function DW.AdminLogout()
    if type(DragonworldDB) == "table" then
        DragonworldDB.admin = nil
    end
    DW.Print(L.ADM_OUT)
    AdminChanged()
end

-- The login box.
do
    local box

    local function TryLogin()
        if DW.AdminLogin(box.code:GetText()) then
            box.code:SetText("")
            box:Hide()
        else
            box.error:SetText(L.ADM_WRONG)
            box.code:SetText("")
            box.code:SetFocus()
        end
    end

    local function CreateBox()
        local f = CreateFrame("Frame", "DragonworldAdminLogin", UIParent, "BackdropTemplate")
        f:SetSize(340, 168)
        f:SetPoint("CENTER", 0, 80)
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
        f:Hide()
        table.insert(UISpecialFrames, "DragonworldAdminLogin") -- Escape closes

        f.title = f:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
        f.title:SetPoint("TOP", 0, -16)

        f.text = f:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
        f.text:SetPoint("TOPLEFT", 20, -42)
        f.text:SetPoint("RIGHT", -20, 0)
        f.text:SetJustifyH("LEFT")

        -- The code is shown as dots.
        f.code = CreateFrame("EditBox", nil, f, "InputBoxTemplate")
        f.code:SetSize(290, 22)
        f.code:SetPoint("TOPLEFT", 26, -78)
        f.code:SetAutoFocus(false)
        f.code:SetPassword(true)
        f.code:SetMaxLetters(64)
        f.code:SetScript("OnEnterPressed", TryLogin)
        f.code:SetScript("OnEscapePressed", function()
            f:Hide()
        end)
        f.code:SetScript("OnTextChanged", function(_, userInput)
            if userInput then
                f.error:SetText("")
            end
        end)

        f.error = f:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
        f.error:SetPoint("TOPLEFT", 22, -104)
        f.error:SetTextColor(1.00, 0.35, 0.30)

        f.login = DW.CreateButton(f, 130, 28, "gold")
        f.login:SetPoint("BOTTOMLEFT", 20, 16)
        f.login:SetScript("OnClick", TryLogin)

        f.cancel = DW.CreateChip(f, 110, 28)
        f.cancel.label:SetJustifyH("CENTER")
        f.cancel:SetPoint("BOTTOMRIGHT", -20, 16)
        f.cancel:SetScript("OnClick", function()
            f:Hide()
        end)

        f:SetScript("OnHide", function()
            f.code:SetText("")
            f.code:ClearFocus()
        end)
        return f
    end

    local function RefreshBox()
        if not box then
            return
        end
        box.title:SetText(L.ADM_TITLE)
        box.text:SetText(L.ADM_PROMPT)
        box.login.label:SetText(L.ADM_LOGIN)
        box.cancel.label:SetText(L.SUG_CANCEL)
    end

    -- Shows the login.
    function DW.ShowAdminLogin()
        if not box then
            box = CreateBox()
        end
        RefreshBox()
        box.error:SetText("")
        box:Show()
        box.code:SetFocus()
    end

    DW.OnLanguageChanged(RefreshBox)
end

DW.AddDebug("admin", function(add)
    add("admin: " .. DW.DebugText(DW.IsAdmin()))
end)

-- Saved data -------------------------------------------------------------------

local function IsWhole(value)
    return type(value) == "number" and not DW.IsSecret(value) and value == math.floor(value)
end

-- The saved limit, or nil when there is none (or it is broken).
local function Stored()
    local saved = type(DragonworldDB) == "table" and DragonworldDB.officerRanks
    if type(saved) == "table" and IsWhole(saved.limit) and saved.limit >= 0 and saved.limit <= MAX_LIMIT then
        return saved
    end
    return nil
end

local function StoredAt()
    local saved = Stored()
    return saved and tonumber(saved.at) or 0
end

-- Roster cache -----------------------------------------------------------------

local cache = {
    built = false,  -- read at least once
    ready = false,  -- the roster had members the last time it was read
    members = {},
    byName = {},    -- [DW.IdentityKey(name)] = rankIndex
    byFirst = {},   -- [DW.FirstNameKey(name)] = { count, rankIndex, identity key } for a lone first name
    byGuid = {},    -- [guid] = rankIndex
    rankNames = {}, -- [rankIndex] = rank name
    maxRank = nil,
    officers = {},  -- { name, key, guid, rankIndex, online }
}

local Rebuild

local function EnsureCache()
    if not cache.built then
        Rebuild()
    end
end

-- Is `who` (a roster member table, a "Player-" GUID or a name) the character
-- you are playing?
local function IsMine(who)
    local guid = DW.MyGUID()
    if type(who) == "table" then
        if guid and who.guid then
            return who.guid == guid
        end
        who = who.key or who.name
    end
    if type(who) ~= "string" or DW.IsSecret(who) or who == "" then
        return false
    end
    if who:match("^Player%-") then
        return who == guid
    end
    return DW.SameCharacter(who, (DW.CharacterKey()))
end

-- Asks the game for a fresh roster, at most once per REQUEST_EVERY seconds.
local lastRequestAt
local function RequestRoster()
    local now = GetTime()
    if lastRequestAt and now - lastRequestAt < REQUEST_EVERY then
        return
    end
    local request = (C_GuildInfo and C_GuildInfo.GuildRoster) or GuildRoster
    if type(request) == "function" then
        lastRequestAt = now
        pcall(request)
    end
end

function DW.MyRankIndex()
    if GetGuildInfo then
        local ok, _, _, rankIndex = pcall(GetGuildInfo, "player")
        if ok and type(rankIndex) == "number" and not DW.IsSecret(rankIndex) then
            return rankIndex
        end
    end
    EnsureCache()
    local guid = DW.MyGUID()
    if guid and cache.byGuid[guid] ~= nil then
        return cache.byGuid[guid]
    end
    return DW.RankIndexOf((DW.CharacterKey()), true)
end

-- The rank index of `who`: a roster member table (.rankIndex), a "Player-"
-- GUID, or a name. Your own rank always comes from DW.MyRankIndex(). nil if unknown.
function DW.RankIndexOf(who, rosterOnly)
    if not rosterOnly and IsMine(who) then
        return DW.MyRankIndex()
    end
    if type(who) == "table" then
        if type(who.rankIndex) == "number" and not DW.IsSecret(who.rankIndex) then
            return who.rankIndex
        end
        who = who.guid or who.key or who.name
    end
    if type(who) ~= "string" or DW.IsSecret(who) or who == "" then
        return nil
    end
    EnsureCache()
    if who:match("^Player%-") then
        return cache.byGuid[who]
    end
    local key = DW.IdentityKey(who)
    if key == "" then
        return nil
    end
    if cache.byName[key] ~= nil then
        return cache.byName[key]
    end
    -- The name may have only the first name ("Akro-Stormrage" for "Akro
    -- Polis"): taken only when one member alone has that first name, and the
    -- roster has more than the first name (so "Borin-OtherRealm" is not "Borin").
    local first = DW.FirstNameKey(who)
    local lone = cache.byFirst[first]
    if lone and lone.count == 1 and key == first and lone.key ~= first then
        return lone.rankIndex
    end
    return nil
end

-- Are a and b (names, or "Player-" GUIDs) the same character? Names are
-- compared whole (DW.IdentityKey), so members who share a first name stay
-- apart. When one side has only the first name, it is the same character
-- only if one member alone in the roster has that first name and the other
-- side is that member's whole name.
function DW.SameCharacter(a, b)
    if type(a) ~= "string" or type(b) ~= "string" or DW.IsSecret(a) or DW.IsSecret(b) or a == "" or b == "" then
        return false
    end
    if a:match("^Player%-") or b:match("^Player%-") then
        return a == b
    end
    local ka, kb = DW.IdentityKey(a), DW.IdentityKey(b)
    if ka == "" or kb == "" then
        return false
    end
    if ka == kb then
        return true
    end
    local first = DW.FirstNameKey(a)
    if first == "" or first ~= DW.FirstNameKey(b) or (ka ~= first and kb ~= first) then
        return false
    end
    EnsureCache()
    local lone = cache.byFirst[first]
    return lone ~= nil and lone.count == 1 and lone.key == (ka == first and kb or ka)
end

-- The officer limit in force: the stored one while the one who set it is
-- still the Guild Master (or the roster is not read yet), otherwise the
-- default. The same rule on every client.
function DW.OfficerLimit()
    local saved = Stored()
    if not saved then
        return DEFAULT_LIMIT
    end
    EnsureCache()
    if cache.ready and DW.RankIndexOf(saved.by) ~= 0 then
        return DEFAULT_LIMIT
    end
    return saved.limit
end

function DW.IsGuildMaster()
    if not DW.IsMember() then
        return false
    end
    if type(IsGuildLeader) == "function" then
        local ok, leader = pcall(IsGuildLeader)
        if ok and type(leader) == "boolean" and not DW.IsSecret(leader) then
            return leader
        end
    end
    return DW.MyRankIndex() == 0
end

function DW.IsOfficer()
    if not DW.IsMember() then
        return false
    end
    local rankIndex = DW.MyRankIndex()
    return rankIndex ~= nil and rankIndex <= DW.OfficerLimit()
end

local recentSenders = {} -- [DW.IdentityKey(sender)] = GetTime() when last seen in a check

-- Is `who` an officer? true/false, or nil when we cannot tell yet (the
-- roster is not read, or the name is not in it; then a fresh roster is asked for).
function DW.IsOfficerKey(who)
    if IsMine(who) then
        return DW.IsOfficer()
    end
    EnsureCache()
    if not cache.ready then
        return nil
    end
    local rankIndex = DW.RankIndexOf(who)
    if rankIndex == nil then
        RequestRoster()
        return nil
    end
    local officer = rankIndex <= DW.OfficerLimit()
    if not officer and type(who) == "string" then
        -- Maybe just promoted: a fresh roster may say otherwise.
        local seen = recentSenders[DW.IdentityKey(who)]
        if seen and GetTime() - seen <= RECENT_SENDER then
            RequestRoster()
        end
    end
    return officer
end

local LEADER_ICON = "|TInterface\\GroupFrame\\UI-Group-LeaderIcon:%d:%d|t "
local ASSISTANT_ICON = "|TInterface\\GroupFrame\\UI-Group-AssistantIcon:%d:%d|t "

-- A small icon to put in front of an officer's rank or name: the leader icon
-- for the Guild Master, the assistant icon for the other officers, "" otherwise.
function DW.OfficerBadge(who, size)
    size = size or 12
    local rankIndex = DW.RankIndexOf(who)
    if rankIndex == 0 then
        return LEADER_ICON:format(size, size)
    elseif rankIndex and rankIndex >= 1 and rankIndex <= DW.OfficerLimit() then
        return ASSISTANT_ICON:format(size, size)
    end
    return ""
end

-- The officers in the roster: { name, key, guid, rankIndex, online }, highest rank first.
function DW.Officers()
    EnsureCache()
    local list = {}
    for index, officer in ipairs(cache.officers) do
        list[index] = officer
    end
    return list
end

local function PlainText(value)
    return type(value) == "string" and not DW.IsSecret(value) and value ~= "" and value or nil
end

function DW.RankName(rankIndex)
    if type(GuildControlGetRankName) == "function" and IsWhole(rankIndex) then
        local ok, name = pcall(GuildControlGetRankName, rankIndex + 1)
        if ok and PlainText(name) then
            return name
        end
    end
    EnsureCache()
    return cache.rankNames[rankIndex] or ("#" .. tostring(rankIndex))
end

function DW.NumRanks()
    if type(GuildControlGetNumRanks) == "function" then
        local ok, count = pcall(GuildControlGetNumRanks)
        if ok and IsWhole(count) and count > 0 then
            return count
        end
    end
    EnsureCache()
    return (cache.maxRank or 0) + 1
end

-- Listeners --------------------------------------------------------------------

local listeners = {}

-- Called when my officer flag, the limit in force or the list of officers changes.
function DW.OnOfficersChanged(callback)
    listeners[#listeners + 1] = callback
end

local function Notify()
    for _, callback in ipairs(listeners) do
        local ok, problem = pcall(callback)
        if not ok then
            DW.PrintError(L.ERROR, problem)
        end
    end
end

local function OfficerList()
    local limit = DW.OfficerLimit()
    local list = {}
    for _, member in ipairs(cache.members) do
        local rankIndex = DW.RankIndexOf(member)
        if rankIndex ~= nil and rankIndex <= limit then
            list[#list + 1] = { name = member.name, key = member.key, guid = member.guid, rankIndex = rankIndex, online = member.online }
        end
    end
    table.sort(list, function(a, b)
        if a.rankIndex ~= b.rankIndex then
            return a.rankIndex < b.rankIndex
        end
        return a.name < b.name
    end)
    return list
end

local function Signature()
    local names = {}
    for _, officer in ipairs(cache.officers) do
        names[#names + 1] = DW.IdentityKey(officer.key)
    end
    table.sort(names)
    return table.concat({ tostring(DW.IsOfficer()), tostring(DW.OfficerLimit()), table.concat(names, ",") }, "|")
end

local lastSignature

-- Reads the roster into the cache. Does not notify.
Rebuild = function()
    local members = DW.ReadGuildRoster()
    local byName, byFirst, byGuid, rankNames, maxRank = {}, {}, {}, {}, nil
    for _, member in ipairs(members) do
        local rankIndex = member.rankIndex
        if rankIndex ~= nil then
            local key = DW.IdentityKey(member.key)
            if key ~= "" then
                byName[key] = rankIndex
                local first = DW.FirstNameKey(member.key)
                local lone = byFirst[first]
                if lone then
                    lone.count = lone.count + 1
                else
                    byFirst[first] = { count = 1, rankIndex = rankIndex, key = key }
                end
            end
            if member.guid then
                byGuid[member.guid] = rankIndex
            end
            if member.rank ~= "" and rankNames[rankIndex] == nil then
                rankNames[rankIndex] = member.rank
            end
            if not maxRank or rankIndex > maxRank then
                maxRank = rankIndex
            end
        end
    end
    cache.built = true
    cache.ready = #members > 0
    cache.members = members
    cache.byName, cache.byFirst, cache.byGuid, cache.rankNames, cache.maxRank = byName, byFirst, byGuid, rankNames, maxRank
    cache.officers = OfficerList()
    if lastSignature == nil then
        lastSignature = Signature()
    end
end

-- Pending checks ---------------------------------------------------------------
-- Questions we could not answer yet (a name not in the roster). One entry per
-- key (a record version, or a person), each holding one or more waiting
-- checks; resolved after each roster rebuild, or false after PENDING_SECONDS.
--
-- An "exclusive" entry (an officer action) is the same record version passed
-- on by several senders: one check per sender (a newer copy from the same
-- sender replaces it). The first check that says yes decides it, and the
-- others are dropped without a call; a "no" for one sender never cancels
-- another sender's check. Other entries (WhenOfficerKnown) call every
-- waiting fn with the answer.

local MAX_WAITING = 20 -- waiting checks per key

local pending = {}  -- [key] = { exclusive, items = { { id, check, fn, created, expires } } }
local pendingOrder = {} -- keys, oldest first
local pendingTimer = false

local function PendingCount()
    return #pendingOrder
end
DW.PendingOfficerChecks = PendingCount

local function RemovePending(key)
    pending[key] = nil
    for index, waiting in ipairs(pendingOrder) do
        if waiting == key then
            table.remove(pendingOrder, index)
            break
        end
    end
end

local function Finish(item, result)
    local ok, problem = pcall(item.fn, result)
    if not ok then
        DW.PrintError(L.ERROR, problem)
    end
end

local function FinishAll(entry, result)
    for _, item in ipairs(entry.items) do
        Finish(item, result)
    end
end

local ResolvePending

local function ScheduleResolve()
    if pendingTimer or not (C_Timer and C_Timer.After) then
        return
    end
    pendingTimer = true
    C_Timer.After(PENDING_TIMER, function()
        pendingTimer = false
        ResolvePending(false)
        if #pendingOrder > 0 then
            ScheduleResolve()
        end
    end)
end

-- id: who the check is for within the key (an exclusive entry keeps one check
-- per id; nil adds a new waiting check every time).
local function AddPending(key, check, fn, exclusive, id)
    local now = GetTime()
    local item = { id = id, check = check, fn = fn, created = now, expires = now + PENDING_SECONDS }
    local entry = pending[key]
    if entry then
        if id ~= nil then
            for index, waiting in ipairs(entry.items) do
                if waiting.id == id then
                    -- A newer copy of the same question from the same sender.
                    entry.items[index] = item
                    return
                end
            end
        end
        if #entry.items >= MAX_WAITING then
            Finish(table.remove(entry.items, 1), false)
        end
        entry.items[#entry.items + 1] = item
        return
    end
    while #pendingOrder >= MAX_PENDING do
        local oldest = table.remove(pendingOrder, 1)
        local dropped = pending[oldest]
        pending[oldest] = nil
        if dropped then
            FinishAll(dropped, false)
        end
    end
    pending[key] = { exclusive = exclusive and true or false, items = { item } }
    pendingOrder[#pendingOrder + 1] = key
    ScheduleResolve()
end

-- afterRebuild: true when called right after the roster was read again.
ResolvePending = function(afterRebuild)
    local now = GetTime()
    local keys = {}
    for index, key in ipairs(pendingOrder) do
        keys[index] = key
    end
    for _, key in ipairs(keys) do
        local entry = pending[key]
        if entry then
            local waiting, done = {}, {}
            local winner
            for _, item in ipairs(entry.items) do
                local result = item.check()
                local refreshed = afterRebuild and cache.ready and lastRequestAt ~= nil
                    and lastRequestAt >= item.created - REQUEST_EVERY and now > lastRequestAt
                if result == nil and (now >= item.expires or refreshed) then
                    result = false
                end
                if result == true and entry.exclusive then
                    winner = item
                    break
                elseif result == nil then
                    waiting[#waiting + 1] = item
                else
                    done[#done + 1] = { item = item, result = result }
                end
            end
            if winner then
                -- Accepted from one sender: the other copies are not needed.
                RemovePending(key)
                Finish(winner, true)
            else
                if #waiting == 0 then
                    RemovePending(key)
                else
                    entry.items = waiting
                end
                for _, finished in ipairs(done) do
                    Finish(finished.item, finished.result)
                end
            end
        end
    end
end

-- Rebuilds (reading the roster again when readRoster), notifies the
-- listeners if something changed, then resolves pending checks.
local function Refresh(readRoster)
    if readRoster then
        Rebuild()
    else
        EnsureCache()
        cache.officers = OfficerList()
    end
    local signature = Signature()
    if signature ~= lastSignature then
        lastSignature = signature
        Notify()
    end
    ResolvePending(readRoster)
end

local rebuildQueued = false
local function QueueRebuild()
    if rebuildQueued or not (C_Timer and C_Timer.After) then
        return
    end
    rebuildQueued = true
    C_Timer.After(1, function()
        rebuildQueued = false
        Refresh(true)
    end)
end

-- Trust helpers ----------------------------------------------------------------

-- May `sender` (set by the server) act for `by` (written in the message)?
-- true when it is the same person, or the sender is an officer relaying it;
-- false when the sender is known not to be an officer; nil if unknown.
function DW.MayActFor(sender, by)
    if type(by) == "string" and not DW.IsSecret(by) and by ~= "" then
        if DW.SameCharacter(sender, by) then
            return true
        end
    end
    local officer = DW.IsOfficerKey(sender)
    if officer == true then
        return true
    elseif officer == false then
        return false
    end
    return nil
end

-- The sender may act for `by`, and `by` is the author (when given) or an officer.
local function DecideAction(sender, by, author)
    local may = DW.MayActFor(sender, by)
    if may == false then
        return false
    end
    local byOk
    if author and DW.SameCharacter(by, author) then
        byOk = true
    else
        byOk = DW.IsOfficerKey(by)
    end
    if byOk == false then
        return false
    end
    if may == true and byOk == true then
        return true
    end
    return nil
end

local function Remember(sender)
    local key = DW.IdentityKey(sender)
    if key ~= "" then
        recentSenders[key] = GetTime()
    end
end

-- Calls fn(true) when the officer action may be accepted, fn(false) when not.
-- key names the record version (e.g. "forslag:S:<id>:<time>"); while the
-- answer is unknown, one check per key and sender waits for the roster (a
-- newer call from the same sender replaces it). Pass author = nil when `by`
-- must be an officer. Returns the answer when it was known at once, nil when
-- it waits. A "no" for this sender leaves other senders' waiting checks alone.
local function WhenDecided(key, sender, check, fn)
    Remember(sender)
    local result = check()
    if result == true then
        -- Accepted: copies from other senders that still wait are not needed.
        RemovePending(key)
    end
    if result ~= nil then
        fn(result)
        return result
    end
    AddPending(key, check, fn, true, DW.IdentityKey(sender))
    return nil
end

function DW.WhenOfficerAction(key, sender, by, author, fn)
    return WhenDecided(key, sender, function()
        return DecideAction(sender, by, author)
    end, fn)
end

-- Is this version made by its author (author given; then the author must be
-- in the guild) or by an officer? true/false, or nil while unknown. Pass
-- author = nil when `by` must be an officer (announcements).
function DW.TrustedVersion(by, author)
    if author and DW.SameCharacter(by, author) then
        return DW.IsMemberKey(by)
    end
    return DW.IsOfficerKey(by)
end

-- May a copy of this version from `sender` be accepted, for records any
-- member may pass on? The version must be trusted (above), and the sender a
-- guild member. true/false, or nil while unknown. The sender is set by the
-- server, and only guild members can send on the guild channel, so a sender
-- missing from the roster is only waited for.
function DW.MayRelay(sender, by, author)
    local direct = DW.SameCharacter(sender, by)
    if direct and author and DW.SameCharacter(by, author) then
        -- From the author themselves.
        return true
    end
    local versionOk = DW.TrustedVersion(by, author)
    if versionOk == false then
        return false
    end
    local senderOk = direct or DW.IsMemberKey(sender) == true
    if versionOk == true and senderOk then
        return true
    end
    return nil
end

-- Calls fn(true) when a copy of the version may be accepted (DW.MayRelay),
-- fn(false) when not, now or once the roster tells. Works like
-- DW.WhenOfficerAction otherwise.
function DW.WhenRelayedAction(key, sender, by, author, fn)
    return WhenDecided(key, sender, function()
        return DW.MayRelay(sender, by, author)
    end, fn)
end

-- Is `who` in the guild roster? true when they are, nil when we cannot tell
-- yet (the roster is not read, or the name is not in it; then a fresh roster
-- is asked for). Pending checks turn nil into false once a fresh roster
-- still lacks them, or after the wait.
function DW.IsMemberKey(who)
    if IsMine(who) then
        return DW.IsMember()
    end
    EnsureCache()
    if not cache.ready then
        return nil
    end
    if DW.RankIndexOf(who) ~= nil then
        return true
    end
    RequestRoster()
    return nil
end

-- Calls fn with the answer of check(), now or once it is known. Every caller
-- that waits on the same key gets the answer.
local function WhenKnown(key, check, fn)
    local result = check()
    if result ~= nil then
        local entry = pending[key]
        if entry then
            RemovePending(key)
            FinishAll(entry, result)
        end
        fn(result)
        return result
    end
    AddPending(key, check, fn, false, nil)
    return nil
end

-- The same for a plain "is this person an officer" question.
function DW.WhenOfficerKnown(who, fn)
    return WhenKnown("who:" .. DW.IdentityKey(who), function()
        return DW.IsOfficerKey(who)
    end, fn)
end

-- And for "is this person in the guild": fn(true), or fn(false) once a fresh
-- roster still lacks them (or after the wait).
function DW.WhenMemberKnown(who, fn)
    return WhenKnown("member:" .. DW.IdentityKey(who), function()
        return DW.IsMemberKey(who)
    end, fn)
end

-- Held versions ----------------------------------------------------------------
-- A version rejected or still undecided for trust reasons. It counts as "have"
-- in digest comparisons (so others do not send it to us again at every hello)
-- for HELD_DAYS, and is tried again when the officers change.

local heldStores = {} -- { name, store }, for /dw debug
local MAX_HELD = 300  -- held versions per store

function DW.NewHeldStore(saved, name)
    if type(saved) ~= "table" then
        saved = {}
    end
    if type(saved.held) ~= "table" then
        saved.held = {}
    end
    -- [id] = { [sender key] = function that re-runs the receive } (memory
    -- only). One per sender, so a copy refused from a relayer never replaces
    -- the actor's own message.
    local replays = {}
    local store = {}

    local function Fresh(entry)
        return type(entry) == "table" and type(entry.u) == "number" and type(entry.at) == "number"
            and DW.ServerNow() - entry.at < HELD_DAYS * DAY
    end

    local function Count()
        local count = 0
        for _ in pairs(saved.held) do
            count = count + 1
        end
        return count
    end

    -- Makes room for one more entry: expired ones go first, then the oldest.
    local function MakeRoom()
        if Count() < MAX_HELD then
            return
        end
        store:Purge()
        while Count() >= MAX_HELD do
            local oldestId, oldestAt
            for id, entry in pairs(saved.held) do
                local at = type(entry) == "table" and tonumber(entry.at) or 0
                if not oldestAt or at < oldestAt or (at == oldestAt and tostring(id) < tostring(oldestId)) then
                    oldestId, oldestAt = id, at
                end
            end
            saved.held[oldestId] = nil
            replays[oldestId] = nil
        end
    end

    -- from: who sent the held copy (its replay is kept next to other senders').
    function store:Hold(id, updated, replay, from)
        if type(id) ~= "string" or type(updated) ~= "number" then
            return
        end
        local fromKey = DW.IdentityKey(from)
        local entry = saved.held[id]
        if type(entry) ~= "table" or type(entry.u) ~= "number" or entry.u < updated then
            if entry == nil then
                MakeRoom()
            end
            saved.held[id] = { u = updated, at = DW.ServerNow() }
            replays[id] = replay and { [fromKey] = replay } or nil
        elseif entry.u == updated and replay then
            replays[id] = replays[id] or {}
            replays[id][fromKey] = replay
        end
    end

    function store:Has(id, updated)
        local entry = saved.held[id]
        return Fresh(entry) and entry.u >= (updated or 0)
    end

    -- The held version for id, if any (and still fresh).
    function store:Version(id)
        local entry = saved.held[id]
        return Fresh(entry) and entry.u or nil
    end

    -- Called when a version is accepted: forgets the held one it covers.
    function store:Clear(id, updated)
        local entry = saved.held[id]
        if entry ~= nil and (updated == nil or type(entry) ~= "table" or type(entry.u) ~= "number" or updated >= entry.u) then
            saved.held[id] = nil
            replays[id] = nil
        end
    end

    function store:ReplayAll()
        local list = {}
        for _, bySender in pairs(replays) do
            for _, replay in pairs(bySender) do
                list[#list + 1] = replay
            end
        end
        for _, replay in ipairs(list) do
            local ok, problem = pcall(replay)
            if not ok then
                DW.PrintError(L.ERROR, problem)
            end
        end
    end

    function store:Purge()
        for id, entry in pairs(saved.held) do
            if not Fresh(entry) then
                saved.held[id] = nil
                replays[id] = nil
            end
        end
    end

    function store:Count()
        return Count()
    end

    if name then
        heldStores[#heldStores + 1] = { name = name, store = store }
    end
    return store
end

-- Limit sync -------------------------------------------------------------------

local Send = DW.CreateSender(PREFIX)

local function SendK()
    local saved = Stored()
    if saved and type(saved.by) == "string" then
        Send(table.concat({ "K", ("%d"):format(saved.limit), ("%d"):format(tonumber(saved.at) or 0), saved.by }, SEP))
    end
end

local kToken = 0     -- the K we plan to send; 0 when none
local kSerial = 0
local lastW

local function ScheduleK()
    if kToken ~= 0 or not (C_Timer and C_Timer.After) then
        return
    end
    kSerial = kSerial + 1
    kToken = kSerial
    local token = kToken
    -- Random wait, so not every officer answers at once (2.7 s in the tests).
    C_Timer.After(1.2 + math.random() * 3, function()
        if kToken ~= token then
            return
        end
        kToken = 0
        if DW.IsMember() and DW.IsOfficer() and StoredAt() > 0 then
            SendK()
        end
    end)
end

local function CancelK()
    kToken = 0
end

function DW.SetOfficerLimit(n)
    if not DW.IsGuildMaster() or not IsWhole(n) or n < 0 or n > math.min(MAX_LIMIT, DW.NumRanks() - 2) then
        return false
    end
    local key = DW.CharacterKey()
    if not key or type(DragonworldDB) ~= "table" then
        return false
    end
    local at = math.max(DW.ServerNow(), StoredAt() + 1)
    DragonworldDB.officerRanks = { limit = n, at = at, by = key }
    CancelK()
    SendK()
    DW.Print(L.OFF_SET:format(DW.RankName(n)))
    Refresh(false)
    return true
end

-- Is the sender of a K allowed to set it? The Guild Master itself, or an
-- officer under both the current and the new limit; `by` must be rank 0.
local function TrustK(sender, limit, by)
    local byRank = DW.RankIndexOf(by)
    if byRank ~= nil and byRank ~= 0 then
        return false
    end
    local senderRank = DW.RankIndexOf(sender)
    if senderRank ~= nil and senderRank ~= 0 and senderRank > math.min(DW.OfficerLimit(), limit) then
        return false
    end
    if byRank == 0 and senderRank ~= nil then
        return true
    end
    EnsureCache()
    if cache.ready then
        RequestRoster()
    end
    return nil
end

local function AcceptK(limit, at, by)
    if at <= StoredAt() or type(DragonworldDB) ~= "table" then
        return
    end
    DragonworldDB.officerRanks = { limit = limit, at = at, by = by }
    Refresh(false)
end

-- The newest K time we refused this session: a hello naming that time (or an
-- older one) does not make us ask for it again.
local refusedK = 0

-- Is our stored limit still set by the Guild Master (or can we not tell)?
-- A limit from a former Guild Master is not sent on: nobody takes it.
local function StoredStillValid()
    local saved = Stored()
    if not saved then
        return false
    end
    local rankIndex = DW.RankIndexOf(saved.by)
    return rankIndex == nil or rankIndex == 0
end

local function OnMessage(text, sender)
    local fields = {}
    for piece in (text .. SEP):gmatch("(.-)" .. SEP) do
        fields[#fields + 1] = piece
    end
    local kind = fields[1]

    if kind == "V" then
        local theirs = tonumber(fields[2])
        if not theirs then
            return
        end
        local mine = StoredAt()
        if theirs > mine and theirs > refusedK then
            local now = GetTime()
            if not lastW or now - lastW >= W_EVERY then
                lastW = now
                Send("W")
            end
        elseif theirs < mine and mine > 0 and DW.IsOfficer() and StoredStillValid() then
            ScheduleK()
        end

    elseif kind == "W" then
        if StoredAt() > 0 and DW.IsOfficer() and StoredStillValid() then
            ScheduleK()
        end

    elseif kind == "K" and #fields >= 4 then
        local limit, at, by = tonumber(fields[2]), tonumber(fields[3]), fields[4]
        if not (IsWhole(limit) and IsWhole(at)) then
            return
        end
        if at >= StoredAt() then
            CancelK() -- someone else already said it
        end
        if limit < 0 or limit > MAX_LIMIT or at > DW.ServerNow() + K_FUTURE or at <= StoredAt() or by == "" or #by > 80 then
            return
        end
        Remember(sender)
        local check = function()
            return TrustK(sender, limit, by)
        end
        local finish = function(ok)
            if ok then
                AcceptK(limit, at, by)
            elseif at > refusedK then
                refusedK = at
            end
        end
        local result = check()
        if result ~= nil then
            finish(result)
        else
            AddPending("off:K:" .. at, check, finish, true, DW.IdentityKey(sender))
        end
    end
end

DW.OnGuildMessage(PREFIX, OnMessage)

-- Events -----------------------------------------------------------------------

local helloSent = false

local function PlanHello()
    if helloSent or not (C_Timer and C_Timer.After) then
        return
    end
    C_Timer.After(HELLO_DELAY, function()
        if not helloSent and DW.IsMember() then
            helloSent = true
            Send("V" .. SEP .. ("%d"):format(StoredAt()))
        end
    end)
end

local frame = CreateFrame("Frame")
frame:SetScript("OnEvent", function(self, event)
    if event == "PLAYER_LOGIN" or event == "PLAYER_ENTERING_WORLD" then
        if DW.IsMember() then
            PlanHello()
        end
        return
    end
    -- GUILD_ROSTER_UPDATE, PLAYER_GUILD_UPDATE, GUILD_RANKS_UPDATE
    QueueRebuild()
end)
for _, event in ipairs({ "PLAYER_LOGIN", "PLAYER_ENTERING_WORLD", "GUILD_ROSTER_UPDATE", "PLAYER_GUILD_UPDATE", "GUILD_RANKS_UPDATE" }) do
    pcall(frame.RegisterEvent, frame, event)
end

DW.OnMembershipChanged(function(member)
    if member then
        PlanHello()
    end
    QueueRebuild()
end)

DW.AddDebug("offiserer", function(add)
    local text = DW.DebugText
    local rankIndex = DW.MyRankIndex()
    add("rang: " .. text(rankIndex) .. (rankIndex and (" (" .. DW.RankName(rankIndex) .. ")") or "")
        .. " | offiser: " .. (DW.IsOfficer() and "ja" or "nei") .. " | GM: " .. (DW.IsGuildMaster() and "ja" or "nei"))
    local saved = Stored()
    if saved then
        add(("grense: %d (satt %s av %s) | i kraft: %s | grense nå: %d"):format(saved.limit, text(saved.at), text(saved.by),
            (DW.OfficerLimit() == saved.limit) and "ja" or "nei", DW.OfficerLimit()))
    else
        add(("grense: standard %d"):format(DW.OfficerLimit()))
    end
    EnsureCache()
    local names = 0
    for _ in pairs(cache.byName) do
        names = names + 1
    end
    add("roster klar: " .. text(cache.ready) .. " | navn: " .. names .. " | ventende sjekker: " .. PendingCount())
    local held = {}
    for _, entry in ipairs(heldStores) do
        held[#held + 1] = entry.name .. " " .. entry.store:Count()
    end
    add("holdt: " .. (#held > 0 and table.concat(held, ", ") or "-"))
    add("IsGuildLeader: " .. text(type(IsGuildLeader) == "function")
        .. " | GuildControlGetNumRanks: " .. text(type(GuildControlGetNumRanks) == "function")
        .. " | GetGuildRankOrder: " .. text(C_GuildInfo ~= nil and type(C_GuildInfo.GetGuildRankOrder) == "function"))
    local officers = {}
    for _, officer in ipairs(cache.officers) do
        officers[#officers + 1] = officer.name .. " (" .. officer.rankIndex .. ")"
    end
    add("offiserer: " .. (#officers > 0 and table.concat(officers, ", ") or "-"))
end)
