-- Dragonworld - Guildbank
-- Shows what is in the guild bank, for everyone in the guild who has the
-- addon, even when they are far away from the bank.
--
-- Where the information comes from:
--   * The game only lets whoever is standing at the guild bank see what is in
--     it. When a member with the addon opens the guild bank, the addon reads
--     all the tabs the member is allowed to see, and the money, and sends it
--     to the rest of the guild. Everyone keeps what they receive, and sees it
--     in this tab.
--   * Each tab has its own time: when it was last seen, and by whom. The
--     newest version of a tab wins.
--   * Whoever logs in says which versions they have. If someone else has
--     newer ones, they send them. If the one who logged in has newer ones,
--     the others ask for them.
--   * None of this happens outside the guild Dragonworld.
--
-- Who gets to see which tabs (guild rank):
--   * A tab is only shown to ranks that can see it in the game. The game only
--     tells each player which tabs their own rank can see, and only at the
--     bank. So whoever is at the bank announces: "rank 4 sees tabs 1, 2 and
--     4, but not 3". Everyone collects such information.
--   * Rank 0 is the guild master; the higher the number, the lower the rank.
--     We assume a higher rank sees at least what a lower one sees. If rank 6
--     sees a tab, rank 4 sees it too. If rank 2 does not see a tab, rank 4
--     does not either.
--   * If the information conflicts, the newest applies. If we know nothing
--     that applies to your rank, the tab is hidden. It appears when someone
--     with your rank or lower has been in the guild bank with the addon.
--   * This hides the tabs in the addon. The content is still sent on the
--     guild channel, so it is not secret from anyone who makes their own
--     addon to read it.
--
-- The tabs are read one at a time: the addon asks the game for the content
-- and waits until it arrives. A tab that looks completely empty only counts
-- as empty if it is the one the player is looking at; otherwise it may just
-- be unloaded. Then what we knew from before is kept.
--
-- The messages (name DragonworldGB, fields separated by tab):
--   T tab time parts checksum who icon name    a tab begins; then come
--   D tab time no content                      the parts: "id:count,id:count"
--   C tab time checksum who     the tab is unchanged, but seen again
--   M time copper who           the money in the bank
--   A rank tab:sees:time,...    which tabs a rank sees (sees = 1) and does not (0)
--   V tab:time:checksum,...     which versions I have (tab 0 = the money,
--                               tab 17 = all we know about who sees what)
--   W tab time checksum         I want this tab (the checksum is mine)
--
-- All text is in Locales.lua (the names that start with GB_).

local ADDON_NAME, DW = ...
local L = DW.L

local MODULE_ID = "guildbank"
local PREFIX = "DragonworldGB" -- the name of the messages; max 16 characters
local SEP = "\t"

local MAX_TABS = 16            -- more tabs than this are not accepted in messages
local SLOTS_PER_TAB = MAX_GUILDBANK_SLOTS_PER_TAB or 98
local CHUNK_BYTES = 200        -- content per D message
local MAX_PARTS = 20
local MAX_NAME_BYTES = 40
local MAX_ICON_BYTES = 100
local CONFIRM_AFTER = 600      -- how old an unchanged tab must be before we announce it was seen again
local MONEY = 0                -- "tab" 0 in messages is the money
local ACCESS = MAX_TABS + 1    -- and this one is who sees which tabs
local MAX_RANK = 20            -- higher rank numbers than this are not accepted

local START_DELAY = 1.0        -- after the bank opens, before we ask for the tabs
local QUERY_GAP = 0.4          -- between each tab
local QUERY_TIMEOUT = 4        -- how long we wait for a tab
local SCAN_DELAY = 1.2         -- changes come several in a row; read when it has calmed down
local HELLO_DELAY = 15         -- after login
local REFRESH_DELAY = 0.2

local GetItemInfo = (C_Item and C_Item.GetItemInfo) or GetItemInfo
local PET_CAGE = 82800         -- caged pets do not have a normal item ID

-- Saved data. Set in OnLoad at the bottom.
--   db.tabs[nr] = { name, icon, items = { [itemID] = antall }, time, by, digest }
--   db.money = { amount, time, by }
--   db.access[fane][rank] = { view = true/false, time }   whether the rank sees the tab
--   db.items[itemID] = { name, quality }   names we have seen, so items can be
--                                          shown by name before the game has loaded them
local db = { tabs = {}, items = {}, access = {} }

-- Small things ------------------------------------------------------------------

-- The time everyone in the guild agrees on (the server's), so "newest" means
-- the same to everyone whatever their machine's clock is set to.
local function Now()
    local now = GetServerTime and GetServerTime()
    if type(now) == "number" and not DW.IsSecret(now) then
        return now
    end
    return time()
end

local function Plain(value)
    if DW.IsSecret(value) then
        return nil
    end
    return value
end

-- Text without characters used in the messages, cut to maxBytes without
-- splitting a character in the middle (æ, ø, å and the like are more than one byte).
local function Clean(text, maxBytes)
    if type(text) ~= "string" or DW.IsSecret(text) then
        return ""
    end
    text = text:gsub("[%c|]", " ")
    text = text:gsub("^%s+", "")
    text = text:gsub("%s+$", "")
    local out = ""
    for char in text:gmatch("[%z\1-\127\194-\244][\128-\191]*") do
        if #out + #char > maxBytes then
            break
        end
        out = out .. char
    end
    return out
end

local function MyName()
    local _, name = DW.CharacterKey()
    return Clean(name or "?", MAX_NAME_BYTES)
end

-- The content of a tab as text: "id:antall,id:antall", sorted by ID, so it
-- is the same for everyone who has the same thing.
local function Serialize(items)
    local ids = {}
    for itemID in pairs(items) do
        ids[#ids + 1] = itemID
    end
    table.sort(ids)
    local parts = {}
    for index, itemID in ipairs(ids) do
        parts[index] = itemID .. ":" .. items[itemID]
    end
    return table.concat(parts, ","), #ids
end

-- A short checksum of the content. An equal checksum means (almost certainly)
-- equal content, so we can say "still the same" without sending it all again.
local function HashText(text, count)
    local hash = 7
    for index = 1, #text do
        hash = (hash * 31 + text:byte(index)) % 16777213
    end
    return count .. "." .. hash
end

local function Digest(items)
    return HashText(Serialize(items))
end

local function MoneyDigest(amount)
    return ("%.0f"):format(amount)
end

-- Who sees what --------------------------------------------------------------------

-- The rank of the character you are playing: 0 is guild master, higher numbers are lower rank.
local function MyRank()
    if GetGuildInfo then
        local _, _, rankIndex = GetGuildInfo("player")
        rankIndex = Plain(rankIndex)
        if type(rankIndex) == "number" then
            return rankIndex
        end
    end
    -- Otherwise: find ourselves in the roster.
    local guid = DW.MyGUID()
    if guid then
        for _, member in ipairs(DW.ReadGuildRoster()) do
            if member.guid == guid then
                return member.rankIndex
            end
        end
    end
    return nil
end

-- Saves that a rank sees (or does not see) a tab, if it is newer than what
-- we knew. Returns true if something changed.
local function Observe(tab, rank, view, when)
    local byRank = db.access[tab]
    if type(byRank) ~= "table" then
        byRank = {}
        db.access[tab] = byRank
    end
    local known = byRank[rank]
    if type(known) == "table" and known.time >= when then
        return false
    end
    byRank[rank] = { view = view, time = when }
    return true
end

-- Does this rank see the tab? What says something about the rank is: that it
-- or a lower rank sees the tab, or that it or a higher rank does not.
-- The newest of these applies. With nothing to go on, the answer is no.
local function RankCanSee(tab, rank)
    local byRank = db.access[tab]
    if type(byRank) ~= "table" or type(rank) ~= "number" then
        return false
    end
    local best
    for observed, known in pairs(byRank) do
        if (known.view and observed >= rank) or (not known.view and observed <= rank) then
            if not best or known.time > best.time or (known.time == best.time and not known.view) then
                best = known
            end
        end
    end
    return best ~= nil and best.view
end

-- All we know about who sees what, as one "version": the newest time and a
-- checksum, so it can be compared with what the others have.
local function AccessVersion()
    local newest
    local parts = {}
    local tabs = {}
    for tab in pairs(db.access) do
        tabs[#tabs + 1] = tab
    end
    table.sort(tabs)
    for _, tab in ipairs(tabs) do
        local ranks = {}
        for rank in pairs(db.access[tab]) do
            ranks[#ranks + 1] = rank
        end
        table.sort(ranks)
        for _, rank in ipairs(ranks) do
            local known = db.access[tab][rank]
            parts[#parts + 1] = tab .. ":" .. rank .. ":" .. (known.view and 1 or 0) .. ":" .. known.time
            if not newest or known.time > newest then
                newest = known.time
            end
        end
    end
    if not newest then
        return nil
    end
    return newest, HashText(table.concat(parts, ","), #parts)
end

-- The version we have of a tab (or the money): time and checksum.
local function VersionOf(tab)
    if tab == ACCESS then
        return AccessVersion()
    end
    if tab == MONEY then
        local money = db.money
        if type(money) == "table" and type(money.time) == "number" then
            return money.time, MoneyDigest(money.amount)
        end
        return nil
    end
    local data = db.tabs[tab]
    if type(data) == "table" and type(data.time) == "number" then
        return data.time, data.digest
    end
    return nil
end

local function TabName(tab)
    local data = db.tabs[tab]
    local name = type(data) == "table" and data.name
    if type(name) == "string" and name ~= "" then
        return name
    end
    return L.GB_TAB_N:format(tab)
end

-- The view needs to know if something changed. Set further down.
local QueueRefresh

-- Sharing -----------------------------------------------------------------------

local Send = DW.CreateSender(PREFIX)

local function SendTab(tab)
    local data = db.tabs[tab]
    if type(data) ~= "table" then
        return
    end
    local text = Serialize(data.items)
    local parts = {}
    local current = ""
    for piece in text:gmatch("[^,]+") do
        if current ~= "" and #current + 1 + #piece > CHUNK_BYTES then
            parts[#parts + 1] = current
            current = ""
        end
        current = (current == "") and piece or (current .. "," .. piece)
    end
    if current ~= "" then
        parts[#parts + 1] = current
    end

    local icon = data.icon
    icon = (type(icon) == "number" or type(icon) == "string") and Clean(tostring(icon), MAX_ICON_BYTES) or ""
    Send(table.concat({ "T", tab, data.time, #parts, data.digest, data.by or "?", icon, data.name or "" }, SEP))
    for index, part in ipairs(parts) do
        Send(table.concat({ "D", tab, data.time, index, part }, SEP))
    end
end

local function SendConfirm(tab)
    local data = db.tabs[tab]
    if type(data) == "table" then
        Send(table.concat({ "C", tab, data.time, data.digest, data.by or "?" }, SEP))
    end
end

local function SendMoney()
    local money = db.money
    if type(money) == "table" then
        Send(table.concat({ "M", money.time, MoneyDigest(money.amount), money.by or "?" }, SEP))
    end
end

-- What we know about what one rank sees: one message, or several if it does not fit.
local function SendAccessRow(rank)
    local head = "A" .. SEP .. rank .. SEP
    local message = head
    for tab = 1, MAX_TABS do
        local known = type(db.access[tab]) == "table" and db.access[tab][rank]
        if type(known) == "table" then
            local entry = tab .. ":" .. (known.view and 1 or 0) .. ":" .. known.time
            if message ~= head and #message + 1 + #entry > 250 then
                Send(message)
                message = head
            end
            message = message .. (message ~= head and "," or "") .. entry
        end
    end
    if message ~= head then
        Send(message)
    end
end

-- All we know about who sees what: one message per rank.
local function SendAccess()
    local ranks = {}
    for _, byRank in pairs(db.access) do
        for rank in pairs(byRank) do
            ranks[rank] = true
        end
    end
    for rank = 0, MAX_RANK do
        if ranks[rank] then
            SendAccessRow(rank)
        end
    end
end

-- Announces which versions we have. Split into several messages if needed.
local function SendVersions()
    local entries = {}
    for tab = 0, ACCESS do
        local when, digest = VersionOf(tab)
        if when then
            entries[#entries + 1] = tab .. ":" .. when .. ":" .. digest
        end
    end
    local message = "V" .. SEP
    local hasEntries = false
    for _, entry in ipairs(entries) do
        if hasEntries and #message + 1 + #entry > 250 then
            Send(message)
            message, hasEntries = "V" .. SEP, false
        end
        message = message .. (hasEntries and "," or "") .. entry
        hasEntries = true
    end
    Send(message)
end

-- Offers and wants wait a random short while, so the whole guild does not
-- answer at once. If we hear that someone else has done the same first, we
-- do not.
local offers = {}       -- [fane] = { time, full }   something we are going to send
local wants = {}        -- [fane] = { time }         something we are going to ask for
local lastOffered = {}  -- [fane] = { time, at }     so we do not send the same twice in a row

local function RandomDelay()
    return 1 + math.random() * 5
end

local function Offer(tab, needFull)
    local when = VersionOf(tab)
    if not when then
        return
    end
    local last = lastOffered[tab]
    if last and last.time == when and GetTime() - last.at < 30 and not needFull then
        return
    end
    local offer = offers[tab]
    if offer and offer.time == when then
        offer.full = offer.full or needFull
        return
    end
    offers[tab] = { time = when, full = needFull }
    C_Timer.After(RandomDelay(), function()
        local current = offers[tab]
        offers[tab] = nil
        if not current or not DW.IsMember() or VersionOf(tab) ~= current.time then
            return
        end
        lastOffered[tab] = { time = current.time, at = GetTime() }
        if tab == MONEY then
            SendMoney()
        elseif tab == ACCESS then
            SendAccess()
        elseif current.full then
            SendTab(tab)
        else
            SendConfirm(tab)
        end
    end)
end

local function Want(tab, when)
    local mine = VersionOf(tab)
    if (mine and mine >= when) or (wants[tab] and wants[tab].time >= when) then
        return
    end
    wants[tab] = { time = when }
    C_Timer.After(RandomDelay(), function()
        local current = wants[tab]
        wants[tab] = nil
        if not current or not DW.IsMember() then
            return
        end
        local have, digest = VersionOf(tab)
        if have and have >= current.time then
            return
        end
        Send(table.concat({ "W", tab, current.time, digest or "-" }, SEP))
    end)
end

-- Someone else has sent (or is in the middle of sending) a version from the
-- time when. Then we do not need to send or ask for anything that is not newer.
local function HeardVersion(tab, when)
    if offers[tab] and offers[tab].time <= when then
        offers[tab] = nil
    end
    if wants[tab] and wants[tab].time <= when then
        wants[tab] = nil
    end
end

-- Saving what we read or receive --------------------------------------------------

local function StoreTab(tab, data)
    db.tabs[tab] = data
    QueueRefresh()
end

local function ParseItems(text, into)
    for itemID, count in text:gmatch("(%d+):(%d+)") do
        itemID, count = tonumber(itemID), tonumber(count)
        if itemID and count and itemID > 0 and count > 0 and count < 10000000 then
            into[itemID] = (into[itemID] or 0) + count
        end
    end
end

-- Receiving ---------------------------------------------------------------------

local incoming = {} -- [sender + tab + time] = a tab on its way, part by part

local function ValidTab(tab)
    return tab and tab >= 1 and tab <= MAX_TABS
end

-- Times from the future (more than a day) are not accepted, so a wrong clock
-- or a corrupted message cannot lock a tab forever.
local function ValidTime(when)
    return when and when > 0 and when <= Now() + 86400
end

local function Complete(key, entry)
    incoming[key] = nil
    local items = {}
    for index = 1, entry.parts do
        ParseItems(entry.got[index], items)
    end
    if Digest(items) ~= entry.digest then
        return -- something was lost or corrupted along the way
    end
    local have = VersionOf(entry.tab)
    if have and have >= entry.time then
        return
    end
    StoreTab(entry.tab, {
        name = entry.name, icon = entry.icon, items = items,
        time = entry.time, by = entry.by, digest = entry.digest,
    })
end

local function OnMessage(text, sender)
    local fields = {}
    for field in (text .. SEP):gmatch("(.-)" .. SEP) do
        fields[#fields + 1] = field
    end
    local kind = fields[1]

    if kind == "T" then
        local tab, when, parts = tonumber(fields[2]), tonumber(fields[3]), tonumber(fields[4])
        if not (ValidTab(tab) and ValidTime(when) and parts and parts >= 0 and parts <= MAX_PARTS and fields[5]) then
            return
        end
        HeardVersion(tab, when)
        local have = VersionOf(tab)
        if have and have >= when then
            return
        end
        -- Clean up the tabs that never finished.
        for key, entry in pairs(incoming) do
            if GetTime() - entry.at > 120 then
                incoming[key] = nil
            end
        end
        local icon = fields[7] or ""
        local key = sender .. SEP .. tab .. SEP .. when
        local entry = {
            tab = tab, time = when, parts = parts, digest = fields[5],
            by = Clean(fields[6], MAX_NAME_BYTES), name = Clean(fields[8], MAX_NAME_BYTES),
            icon = tonumber(icon) or (icon ~= "" and Clean(icon, MAX_ICON_BYTES)) or nil,
            got = {}, count = 0, at = GetTime(),
        }
        incoming[key] = entry
        if parts == 0 then
            Complete(key, entry)
        end

    elseif kind == "D" then
        local key = sender .. SEP .. tostring(fields[2]) .. SEP .. tostring(fields[3])
        local entry = incoming[key]
        local index = tonumber(fields[4])
        if entry and index and index >= 1 and index <= entry.parts and fields[5] and not entry.got[index] then
            entry.got[index] = fields[5]
            entry.count = entry.count + 1
            if entry.count == entry.parts then
                Complete(key, entry)
            end
        end

    elseif kind == "C" then
        local tab, when, digest = tonumber(fields[2]), tonumber(fields[3]), fields[4]
        if not (ValidTab(tab) and ValidTime(when) and digest) then
            return
        end
        HeardVersion(tab, when)
        local data = db.tabs[tab]
        if type(data) == "table" and data.digest == digest then
            if when > data.time then
                data.time, data.by = when, Clean(fields[5], MAX_NAME_BYTES)
                QueueRefresh()
            end
        elseif not (type(data) == "table" and data.time >= when) then
            Want(tab, when) -- someone has seen something other than what we have
        end

    elseif kind == "M" then
        local when, amount = tonumber(fields[2]), tonumber(fields[3])
        if not (ValidTime(when) and amount and amount >= 0) then
            return
        end
        HeardVersion(MONEY, when)
        local have = VersionOf(MONEY)
        if not have or when > have then
            db.money = { amount = amount, time = when, by = Clean(fields[4], MAX_NAME_BYTES) }
            QueueRefresh()
        end

    elseif kind == "A" then
        -- What a rank sees. Each tab on its own; the newest wins.
        local rank = tonumber(fields[2])
        if not (rank and rank >= 0 and rank <= MAX_RANK and rank == math.floor(rank)) then
            return
        end
        local changed, newest = false, nil
        for tab, view, when in (fields[3] or ""):gmatch("(%d+):([01]):(%d+)") do
            tab, when = tonumber(tab), tonumber(when)
            if ValidTab(tab) and ValidTime(when) then
                if Observe(tab, rank, view == "1", when) then
                    changed = true
                end
                newest = math.max(newest or 0, when)
            end
        end
        if newest then
            if wants[ACCESS] and wants[ACCESS].time <= newest then
                wants[ACCESS] = nil
            end
            -- Someone else is sending the same as we were going to send: then we
            -- do not. If we got something new, they know something different
            -- from us, and we send anyway.
            if not changed and offers[ACCESS] and offers[ACCESS].time <= newest then
                offers[ACCESS] = nil
            end
        end
        if changed then
            QueueRefresh()
        end

    elseif kind == "V" then
        -- A member says which versions they have. Send what we have that is
        -- newer, and ask for what they have that is newer.
        local theirs = {}
        for tab, when, digest in (fields[2] or ""):gmatch("(%d+):(%d+):([%d%.]+)") do
            tab, when = tonumber(tab), tonumber(when)
            if tab and tab >= 0 and tab <= ACCESS and ValidTime(when) then
                theirs[tab] = { time = when, digest = digest }
            end
        end
        for tab = 0, ACCESS do
            local mine, myDigest = VersionOf(tab)
            local other = theirs[tab]
            if mine and (not other or other.time < mine) then
                Offer(tab, not (other and other.digest == myDigest))
            elseif other and (not mine or other.time > mine) then
                Want(tab, other.time)
            elseif tab == ACCESS and mine and other.digest ~= myDigest then
                -- Equally new, but different content: we each know our own thing.
                -- What we send is added on their side, and vice versa.
                Offer(tab, true)
            end
        end

    elseif kind == "W" then
        local tab, when = tonumber(fields[2]), tonumber(fields[3])
        if not (tab and tab >= 0 and tab <= ACCESS and when) then
            return
        end
        -- Others who would ask for the same do not need to.
        if wants[tab] and wants[tab].time <= when then
            wants[tab] = nil
        end
        local mine, myDigest = VersionOf(tab)
        if mine and mine >= when then
            Offer(tab, fields[4] ~= myDigest)
        end
    end
end

DW.OnGuildMessage(PREFIX, OnMessage)

-- Reading the guild bank ----------------------------------------------------------

local bankOpen = false
local sawOpenEvent = false -- has the game announced that the bank was opened (in this session)?
local visit -- what belongs to one visit to the bank; nil when the bank is closed

local function NumTabs()
    if GetNumGuildBankTabs then
        local count = Plain(GetNumGuildBankTabs())
        if type(count) == "number" then
            return math.min(count, MAX_TABS)
        end
    end
    return 0
end

local function CurrentTab()
    local tab = GetCurrentGuildBankTab and Plain(GetCurrentGuildBankTab())
    return type(tab) == "number" and tab or nil
end

-- Whether the game says this character (the rank) gets to see the tab.
local function IsViewable(tab)
    if not GetGuildBankTabInfo then
        return false
    end
    local _, _, isViewable = GetGuildBankTabInfo(tab)
    isViewable = Plain(isViewable)
    return isViewable == true or isViewable == 1
end

-- Name, icon and whether the player gets to see the tab.
local function TabInfo(tab)
    if not GetGuildBankTabInfo then
        return nil
    end
    local name, icon, isViewable = GetGuildBankTabInfo(tab)
    name, icon, isViewable = Plain(name), Plain(icon), Plain(isViewable)
    if isViewable == false or isViewable == 0 or isViewable == nil then
        return nil
    end
    if type(icon) ~= "number" and type(icon) ~= "string" then
        icon = nil
    end
    return Clean(name, MAX_NAME_BYTES), icon
end

local function ItemIDFromLink(link)
    if type(link) ~= "string" or DW.IsSecret(link) then
        return nil
    end
    local itemID = tonumber(link:match("|Hitem:(%d+)") or link:match("^item:(%d+)"))
    if itemID then
        return itemID
    end
    if link:find("battlepet:", 1, true) then
        return PET_CAGE
    end
    return nil
end

local waitingForName = {} -- [itemID] = true while we wait for the game to load the name

local function RememberItem(itemID)
    if type(db.items[itemID]) == "table" then
        return
    end
    local name, _, quality = GetItemInfo(itemID)
    if type(name) == "string" then
        db.items[itemID] = { name = name, quality = quality }
        waitingForName[itemID] = nil
    elseif not waitingForName[itemID] then
        waitingForName[itemID] = true
        if C_Item and C_Item.RequestLoadItemDataByID then
            C_Item.RequestLoadItemDataByID(itemID)
        end
    end
end

-- Reads one tab. Returns the content and whether anything was there at all.
local function ReadTab(tab)
    local items, any = {}, false
    for slot = 1, SLOTS_PER_TAB do
        local itemID = ItemIDFromLink(GetGuildBankItemLink(tab, slot))
        if itemID then
            local _, count = GetGuildBankItemInfo(tab, slot)
            count = Plain(count)
            if type(count) ~= "number" or count < 1 then
                count = 1
            end
            items[itemID] = (items[itemID] or 0) + count
            any = true
            RememberItem(itemID)
        end
    end
    return items, any
end

-- Reads all the tabs we trust, and the money, and shares what is new.
local function Scan()
    if not visit or not DW.IsMember() or not (GetGuildBankItemLink and GetGuildBankItemInfo) then
        return
    end
    local now, me = Now(), MyName()
    local current = CurrentTab()

    for tab = 1, NumTabs() do
        local name, icon = TabInfo(tab)
        if name and visit.loaded[tab] then
            local items, any = ReadTab(tab)
            -- A tab with nothing in it can also be one that is not loaded yet.
            -- It only counts as empty if it is the one the player is looking at.
            if any or tab == current then
                visit.read[tab] = true
                local digest = Digest(items)
                local stored = db.tabs[tab]
                if type(stored) == "table" and stored.digest == digest and stored.name == name and stored.icon == icon then
                    -- Unchanged. If it has been a while since last time, we say
                    -- it was seen again, without sending everything.
                    if now - (stored.time or 0) >= CONFIRM_AFTER then
                        stored.time, stored.by = now, me
                        SendConfirm(tab)
                        QueueRefresh()
                    end
                else
                    -- Always newer than the version we had, even if it is from
                    -- the same second, otherwise the others would keep the old one.
                    local when = math.max(now, (type(stored) == "table" and stored.time or 0) + 1)
                    StoreTab(tab, { name = name, icon = icon, items = items, time = when, by = me, digest = digest })
                    SendTab(tab)
                    visit.changed[tab] = true
                end
            end
        end
    end

    if visit.anyEvent and GetGuildBankMoney then
        local amount = Plain(GetGuildBankMoney())
        if type(amount) == "number" and amount >= 0 then
            local money = db.money
            local known = type(money) == "table"
            if not known or money.amount ~= amount or now - money.time >= CONFIRM_AFTER then
                db.money = { amount = amount, time = math.max(now, known and (money.time + 1) or 0), by = me }
                SendMoney()
                QueueRefresh()
            end
        end
    end

    -- Which tabs our rank sees and does not see. If we see none at all, the
    -- tabs are probably not loaded yet, and then we say nothing.
    local rank = MyRank()
    local tabs = NumTabs()
    if visit.anyEvent and rank and rank >= 0 and rank <= MAX_RANK and tabs > 0 then
        local views, anyView, changed, last = {}, false, false, 0
        for tab = 1, tabs do
            views[tab] = IsViewable(tab)
            anyView = anyView or views[tab]
            local known = type(db.access[tab]) == "table" and db.access[tab][rank]
            if type(known) ~= "table" or known.view ~= views[tab] or now - known.time >= CONFIRM_AFTER then
                changed = true
            end
            if type(known) == "table" then
                last = math.max(last, known.time)
            end
        end
        if anyView and changed then
            local when = math.max(now, last + 1)
            for tab = 1, tabs do
                Observe(tab, rank, views[tab], when)
            end
            SendAccessRow(rank)
            QueueRefresh()
        end
    end

    -- When all the tabs have been asked for, we say once in chat what happened,
    -- so the player sees that it works.
    if visit.done and not visit.reported and next(visit.read) then
        visit.reported = true
        local changed = 0
        for _ in pairs(visit.changed) do
            changed = changed + 1
        end
        DW.Print(changed > 0 and L.GB_SHARED:format(changed) or L.GB_UNCHANGED)
    end
end

-- Changes often come several in a row. Read when it has been quiet for a bit.
local function QueueScan()
    if not visit or visit.scanQueued then
        return
    end
    visit.scanQueued = true
    local thisVisit = visit
    C_Timer.After(SCAN_DELAY, function()
        thisVisit.scanQueued = false
        if visit == thisVisit then
            Scan()
        end
    end)
end

-- Asks the game for one tab at a time, and waits until it has arrived (or
-- gives up after a while) before the next.
local QueryNext

local function TabArrived(thisVisit)
    if thisVisit.waitingFor then
        thisVisit.loaded[thisVisit.waitingFor] = true
        thisVisit.waitingFor = nil
        C_Timer.After(QUERY_GAP, function()
            QueryNext(thisVisit)
        end)
    end
end

QueryNext = function(thisVisit)
    if visit ~= thisVisit or thisVisit.waitingFor then
        return
    end
    local tabs = NumTabs()
    while thisVisit.nextTab <= tabs do
        local tab = thisVisit.nextTab
        thisVisit.nextTab = tab + 1
        if TabInfo(tab) and not thisVisit.loaded[tab] then
            thisVisit.waitingFor = tab
            local token = {}
            thisVisit.token = token
            pcall(QueryGuildBankTab, tab)
            C_Timer.After(QUERY_TIMEOUT, function()
                -- If it never came, we move on without trusting it.
                if visit == thisVisit and thisVisit.token == token and thisVisit.waitingFor == tab then
                    thisVisit.waitingFor = nil
                    QueryNext(thisVisit)
                end
            end)
            return
        end
    end
    thisVisit.done = true
    QueueScan()
end

local function OpenBank()
    if visit then
        return
    end
    bankOpen = true
    visit = { loaded = {}, read = {}, changed = {}, nextTab = 1 }
    local thisVisit = visit
    if QueryGuildBankTab then
        C_Timer.After(START_DELAY, function()
            QueryNext(thisVisit)
        end)
    else
        -- Without a way to ask for the tabs, we only read the ones the player clicks.
        thisVisit.done = true
    end
end

local function CloseBank()
    if visit and visit.scanQueued then
        Scan() -- read the last before the bank is gone
    end
    bankOpen = false
    visit = nil
end

local function SlotsChanged()
    if not visit then
        -- If the game has announced when the bank opens before, it is closed
        -- now. Otherwise the game does not announce it, and we only now know
        -- that the bank is open.
        if sawOpenEvent then
            return
        end
        OpenBank()
    end
    visit.anyEvent = true
    -- The tab the player is looking at is loaded by the game's own window.
    local current = CurrentTab()
    if current then
        visit.loaded[current] = true
    end
    TabArrived(visit)
    QueueScan()
end

-- View ------------------------------------------------------------------------

local ROW_HEIGHT = 24
local FALLBACK_ICON = 134400 -- question mark

local panel
local rows = {}
local RefreshPanel

local filterTab   -- the tab number, or nil for all
local searchText = ""

local function KnownTabs()
    local list = {}
    for tab, data in pairs(db.tabs) do
        if type(tab) == "number" and type(data) == "table" and type(data.items) == "table" then
            list[#list + 1] = tab
        end
    end
    table.sort(list)
    return list
end

-- The tabs your rank gets to see. The rest are not shown at all.
local function VisibleTabs()
    local rank = MyRank()
    local list = {}
    for _, tab in ipairs(KnownTabs()) do
        if RankCanSee(tab, rank) then
            list[#list + 1] = tab
        end
    end
    return list
end

local function WhenText(when)
    return date("%d.%m.%Y %H:%M", when)
end

-- Money as "12g 34s 56c" with the game's colors on the letters.
local function MoneyText(copper)
    copper = math.floor(copper)
    local gold = math.floor(copper / 10000)
    local silver = math.floor((copper % 10000) / 100)
    return ("%d|cffffd700g|r %d|cffc7c7cfs|r %d|cffeda55fc|r"):format(gold, silver, copper % 100)
end

local function Collect()
    local totals = {}
    for _, tab in ipairs(VisibleTabs()) do
        if filterTab == nil or filterTab == tab then
            for itemID, count in pairs(db.tabs[tab].items) do
                if type(itemID) == "number" and type(count) == "number" then
                    totals[itemID] = (totals[itemID] or 0) + count
                end
            end
        end
    end

    local needle = searchText:lower()
    needle = needle:gsub("^%s+", "")
    needle = needle:gsub("%s+$", "")

    local entries = {}
    for itemID, count in pairs(totals) do
        local known = db.items[itemID]
        local name, quality
        if type(known) == "table" then
            name, quality = known.name, known.quality
        else
            RememberItem(itemID)
            known = db.items[itemID]
            if type(known) == "table" then
                name, quality = known.name, known.quality
            else
                name = "item:" .. itemID
            end
        end
        if needle == "" or name:lower():find(needle, 1, true) then
            local _, _, _, _, icon = C_Item.GetItemInfoInstant(itemID)
            entries[#entries + 1] = { itemID = itemID, count = count, name = name, quality = quality, icon = icon }
        end
    end

    table.sort(entries, function(a, b)
        if a.name ~= b.name then
            return a.name < b.name
        end
        return a.itemID < b.itemID
    end)
    return entries
end

local function SetTab(tab)
    filterTab = tab
    RefreshPanel()
end

local function OpenTabMenu(owner)
    local tabs = VisibleTabs()
    if not (MenuUtil and MenuUtil.CreateContextMenu) then
        -- Without a menu: go to the next tab on each click, and finally all.
        local nextTab = tabs[1]
        for index, tab in ipairs(tabs) do
            if tab == filterTab then
                nextTab = tabs[index + 1]
            end
        end
        SetTab(nextTab)
        return
    end

    local function IsSelected(data)
        return (filterTab or false) == data
    end
    local function Select(data)
        SetTab(data or nil)
    end
    MenuUtil.CreateContextMenu(owner, function(_, root)
        root:CreateTitle(L.GB_TAB)
        root:CreateRadio(L.GB_ALL_TABS, IsSelected, Select, false)
        for _, tab in ipairs(tabs) do
            root:CreateRadio(TabName(tab), IsSelected, Select, tab)
        end
    end)
end

-- When each tab was last seen, in the tooltip on the tab selector.
local function ShowTabTooltip(owner)
    local tabs = VisibleTabs()
    if #tabs == 0 then
        return
    end
    GameTooltip:SetOwner(owner, "ANCHOR_BOTTOM")
    GameTooltip:AddLine(L.GB_TOOLTIP_SEEN)
    for _, tab in ipairs(tabs) do
        local data = db.tabs[tab]
        GameTooltip:AddLine(L.GB_TOOLTIP_TAB_LINE:format(TabName(tab), WhenText(data.time), data.by or "?"), 0.75, 0.75, 0.75)
    end
    GameTooltip:Show()
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

    row.icon = row:CreateTexture(nil, "ARTWORK")
    row.icon:SetSize(18, 18)
    row.icon:SetPoint("LEFT", 2, 0)
    row.icon:SetTexCoord(0.07, 0.93, 0.07, 0.93)

    row.count = row:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
    row.count:SetPoint("RIGHT", -8, 0)
    row.count:SetWidth(80)
    row.count:SetJustifyH("RIGHT")

    row.name = row:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
    row.name:SetPoint("LEFT", row.icon, "RIGHT", 6, 0)
    row.name:SetPoint("RIGHT", row.count, "LEFT", -6, 0)
    row.name:SetJustifyH("LEFT")
    row.name:SetWordWrap(false)

    -- Hover over the row to see the item and which tabs it is in.
    row:SetScript("OnEnter", function(self)
        local entry = self.entry
        if not entry then
            return
        end
        GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
        if GameTooltip.SetItemByID then
            GameTooltip:SetItemByID(entry.itemID)
        else
            GameTooltip:AddLine(entry.name)
        end
        GameTooltip:AddLine(" ")
        for _, tab in ipairs(VisibleTabs()) do
            local count = db.tabs[tab].items[entry.itemID]
            if count then
                GameTooltip:AddLine(L.GB_TOOLTIP_IN_TAB:format(TabName(tab), count), 0.75, 0.75, 0.75)
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

RefreshPanel = function()
    if not panel or not panel:IsVisible() then
        return
    end

    -- The tab that was selected may be gone, or hidden (e.g. after a new rank).
    if filterTab and not (type(db.tabs[filterTab]) == "table" and RankCanSee(filterTab, MyRank())) then
        filterTab = nil
    end

    panel.title:SetText(L.GB_PANEL_TITLE)
    panel.searchLabel:SetText(L.GB_SEARCH)
    panel.headerItem:SetText(L.GB_HEADER_ITEM)
    panel.headerCount:SetText(L.GB_HEADER_COUNT)
    panel.tabChip.label:SetText(L.GB_TAB_LABEL:format(filterTab and TabName(filterTab) or L.GB_ALL_TABS))

    local money = db.money
    if type(money) == "table" and type(money.amount) == "number" then
        panel.money:SetText(L.GB_MONEY:format(MoneyText(money.amount)))
    else
        panel.money:SetText("")
    end

    local entries = Collect()
    for index, entry in ipairs(entries) do
        local row = GetRow(index)
        local colour = ITEM_QUALITY_COLORS and entry.quality and ITEM_QUALITY_COLORS[entry.quality]
        row.entry = entry
        row.icon:SetTexture(entry.icon or FALLBACK_ICON)
        row.name:SetText(entry.name)
        if colour then
            row.name:SetTextColor(colour.r, colour.g, colour.b)
        else
            row.name:SetTextColor(1, 1, 1)
        end
        row.count:SetText(tostring(entry.count))
        row:Show()
    end
    for index = #entries + 1, #rows do
        rows[index].entry = nil
        rows[index]:Hide()
    end
    panel.content:SetHeight(math.max(1, #entries * ROW_HEIGHT))

    local tabs = VisibleTabs()
    if #tabs > 0 then
        panel.empty:SetText(L.GB_EMPTY_FILTER)
    elseif #KnownTabs() > 0 then
        panel.empty:SetText(L.GB_EMPTY_HIDDEN)
    else
        panel.empty:SetText(L.GB_EMPTY_NONE)
    end
    panel.empty:SetShown(#entries == 0)

    -- At the bottom: when what we show was last seen, and by whom.
    if filterTab then
        local data = db.tabs[filterTab]
        panel.footer:SetText(L.GB_SEEN:format(data.by or "?", WhenText(data.time)))
    elseif #tabs > 0 then
        local newest
        for _, tab in ipairs(tabs) do
            local data = db.tabs[tab]
            if not newest or data.time > newest.time then
                newest = data
            end
        end
        panel.footer:SetText(L.GB_SEEN_ALL:format(WhenText(newest.time), newest.by or "?"))
    else
        panel.footer:SetText("")
    end
end

QueueRefresh = function()
    if not panel or not panel:IsVisible() or panel.refreshQueued then
        return
    end
    panel.refreshQueued = true
    C_Timer.After(REFRESH_DELAY, function()
        panel.refreshQueued = false
        RefreshPanel()
    end)
end

local function CreatePanel(parent)
    local f = CreateFrame("Frame", nil, parent)
    f:SetAllPoints(parent)

    f.title = f:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
    f.title:SetPoint("TOP", 0, -12)

    -- Filter: which tab.
    f.tabChip = DW.CreateChip(f, 230, 26)
    f.tabChip:SetPoint("TOPLEFT", 14, -40)
    f.tabChip:SetScript("OnClick", function(self)
        GameTooltip:Hide()
        OpenTabMenu(self)
    end)
    f.tabChip:HookScript("OnEnter", function(self)
        ShowTabTooltip(self)
    end)
    f.tabChip:HookScript("OnLeave", function()
        GameTooltip:Hide()
    end)

    -- The money in the bank.
    f.money = f:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
    f.money:SetPoint("TOPRIGHT", -18, -46)
    f.money:SetJustifyH("RIGHT")

    f.searchLabel = f:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    f.searchLabel:SetPoint("TOPLEFT", 14, -80)

    f.searchBox = CreateFrame("EditBox", nil, f, "InputBoxTemplate")
    f.searchBox:SetSize(260, 22)
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

    f.headerItem = f:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    f.headerItem:SetPoint("TOPLEFT", 14, -108)

    f.headerCount = f:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    f.headerCount:SetPoint("TOPRIGHT", -38, -108)

    local scroll = CreateFrame("ScrollFrame", "DragonworldGuildbankScroll", f, "ScrollFrameTemplate")
    scroll:SetPoint("TOPLEFT", 10, -124)
    scroll:SetPoint("BOTTOMRIGHT", -30, 34)

    f.content = CreateFrame("Frame", nil, scroll)
    f.content:SetSize(parent:GetWidth() - 10 - 30, 1)
    scroll:SetScrollChild(f.content)

    f.empty = f:CreateFontString(nil, "OVERLAY", "GameFontDisable")
    f.empty:SetPoint("TOP", scroll, "TOP", 0, -40)
    f.empty:SetWidth(400)

    f.footer = f:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    f.footer:SetPoint("BOTTOMLEFT", 14, 12)
    f.footer:SetPoint("BOTTOMRIGHT", -14, 12)
    f.footer:SetJustifyH("LEFT")
    f.footer:SetWordWrap(false)

    f:SetScript("OnShow", function()
        RefreshPanel()
    end)

    panel = f
    return f
end

-- Events ----------------------------------------------------------------------

local helloSent = false

-- Once per session, a little after login: announce which versions we have,
-- so the others can send what is newer.
local function PlanHello()
    if helloSent or not (C_Timer and C_Timer.After) then
        return
    end
    C_Timer.After(HELLO_DELAY, function()
        if not helloSent and DW.IsMember() then
            helloSent = true
            SendVersions()
        end
    end)
end

local GUILD_BANKER = (Enum and Enum.PlayerInteractionType and Enum.PlayerInteractionType.GuildBanker) or 10

local frame = CreateFrame("Frame")

frame:SetScript("OnEvent", function(self, event, arg)
    if not DW.IsMember() then
        return
    end
    if event == "GUILDBANKFRAME_OPENED" then
        sawOpenEvent = true
        OpenBank()
    elseif event == "GUILDBANKFRAME_CLOSED" then
        CloseBank()
    elseif event == "PLAYER_INTERACTION_MANAGER_FRAME_SHOW" then
        if arg == GUILD_BANKER then
            sawOpenEvent = true
            OpenBank()
        end
    elseif event == "PLAYER_INTERACTION_MANAGER_FRAME_HIDE" then
        if arg == GUILD_BANKER then
            CloseBank()
        end
    elseif event == "GUILDBANKBAGSLOTS_CHANGED" then
        SlotsChanged()
    elseif event == "GUILDBANK_UPDATE_MONEY" then
        if visit then
            visit.anyEvent = true
            QueueScan()
        end
    elseif event == "GUILDBANK_UPDATE_TABS" then
        if visit then
            QueueScan()
        end
    elseif event == "GET_ITEM_INFO_RECEIVED" then
        -- The game has loaded an item whose name we were waiting for.
        if type(arg) == "number" and waitingForName[arg] then
            RememberItem(arg)
            QueueRefresh()
        end
    elseif event == "PLAYER_ENTERING_WORLD" then
        PlanHello()
    elseif event == "PLAYER_GUILD_UPDATE" or event == "GUILD_ROSTER_UPDATE" then
        QueueRefresh() -- the rank may have changed, and with it which tabs are shown
    end
end)

for _, event in ipairs({
    "PLAYER_ENTERING_WORLD",
    "GUILDBANKFRAME_OPENED",
    "GUILDBANKFRAME_CLOSED",
    "PLAYER_INTERACTION_MANAGER_FRAME_SHOW",
    "PLAYER_INTERACTION_MANAGER_FRAME_HIDE",
    "GUILDBANKBAGSLOTS_CHANGED",
    "GUILDBANK_UPDATE_MONEY",
    "GUILDBANK_UPDATE_TABS",
    "GET_ITEM_INFO_RECEIVED",
    "PLAYER_GUILD_UPDATE",
    "GUILD_ROSTER_UPDATE",
}) do
    pcall(frame.RegisterEvent, frame, event)
end

DW.OnMembershipChanged(function(member)
    if member then
        PlanHello()
    else
        CloseBank()
    end
end)

DW.OnLanguageChanged(function()
    RefreshPanel()
end)

-- Debugging: what the game reports about the guild bank, and what we have saved.
DW.AddDebug("guildbank", function(add)
    local text = DW.DebugText
    add("funksjoner: GetNumGuildBankTabs=" .. text(GetNumGuildBankTabs ~= nil) .. " QueryGuildBankTab=" .. text(QueryGuildBankTab ~= nil)
        .. " GetCurrentGuildBankTab=" .. text(GetCurrentGuildBankTab ~= nil) .. " GetGuildBankItemLink=" .. text(GetGuildBankItemLink ~= nil))
    local rank = MyRank()
    add("banken åpen: " .. text(bankOpen) .. " | faner i spillet: " .. text(NumTabs()) .. " | viser fane: " .. text(CurrentTab())
        .. " | min rank: " .. text(rank))
    for _, tab in ipairs(KnownTabs()) do
        local data = db.tabs[tab]
        local count = 0
        for _ in pairs(data.items) do
            count = count + 1
        end
        add(("fane %d '%s': %d slags, sett %s av %s, sjekksum %s | synlig for meg: %s"):format(tab, text(data.name), count,
            text(data.time), text(data.by), text(data.digest), text(RankCanSee(tab, rank))))
    end
    -- What we know about who sees what: "fane 3: rank 1 ja, rank 4 nei".
    for tab = 1, MAX_TABS do
        local byRank = db.access[tab]
        if type(byRank) == "table" then
            local parts = {}
            for observed = 0, MAX_RANK do
                local known = byRank[observed]
                if type(known) == "table" then
                    parts[#parts + 1] = ("rank %d %s"):format(observed, known.view and "ja" or "nei")
                end
            end
            add(("fane %d ses av: %s"):format(tab, table.concat(parts, ", ")))
        end
    end
    local money = db.money
    add("penger: " .. (type(money) == "table" and (text(money.amount) .. " sett " .. text(money.time) .. " av " .. text(money.by)) or "ukjent"))
end)

-- Module -------------------------------------------------------------------------

DW.RegisterModule({
    id = MODULE_ID,
    titleKey = "GB_TITLE",
    notesKey = "GB_NOTES",
    icon = "Interface\\Icons\\INV_Misc_Coin_02",

    OnLoad = function(self, saved)
        if type(saved.tabs) ~= "table" then
            saved.tabs = {}
        end
        if type(saved.items) ~= "table" then
            saved.items = {}
        end
        -- Clean up anything that does not look right (e.g. from a corrupted file).
        for tab, data in pairs(saved.tabs) do
            if type(tab) ~= "number" or type(data) ~= "table" or type(data.items) ~= "table" or type(data.time) ~= "number" then
                saved.tabs[tab] = nil
            end
        end
        if type(saved.money) ~= "table" or type(saved.money.amount) ~= "number" or type(saved.money.time) ~= "number" then
            saved.money = nil
        end
        if type(saved.access) ~= "table" then
            saved.access = {}
        end
        for tab, byRank in pairs(saved.access) do
            if type(tab) ~= "number" or type(byRank) ~= "table" then
                saved.access[tab] = nil
            else
                for rank, known in pairs(byRank) do
                    if type(rank) ~= "number" or type(known) ~= "table" or type(known.time) ~= "number" then
                        byRank[rank] = nil
                    end
                end
            end
        end
        db = saved
    end,

    CreatePanel = function(self, parent)
        return CreatePanel(parent)
    end,
})

-- The Home page (Modules\Home.lua): the gold in the bank, when someone has seen
-- it since you last played. The amount at logout is kept to compare with.
DW.RegisterHomeSection({
    id = "guildbank",
    order = 70,
    titleKey = "HOME_SEC_GUILDBANK",
    icon = "Interface\\Icons\\INV_Misc_Coin_02",
    Snapshot = function()
        local money = db.money
        return type(money) == "table" and money.amount or nil
    end,
    Lines = function(ctx)
        local money = db.money
        if not ctx.since or type(money) ~= "table" or type(money.amount) ~= "number" or (money.time or 0) <= ctx.since then
            return {}
        end
        local before = tonumber(ctx.before)
        if before == money.amount then
            return {}
        end
        local text
        if before then
            local diff = money.amount - before
            local change = diff > 0 and ("|cff40ff40+|r" .. MoneyText(diff)) or ("|cffff4040-|r" .. MoneyText(-diff))
            text = L.HOME_GB_CHANGE:format(MoneyText(money.amount), MoneyText(before), change)
        else
            text = L.HOME_GB_NOW:format(MoneyText(money.amount))
        end
        return { {
            text = text, when = money.time, tip = L.HOME_GB_TIP:format(money.by or "?"), changed = true, tab = MODULE_ID,
            onClick = function()
                DW.OpenModule(MODULE_ID)
            end,
        } }
    end,
})
