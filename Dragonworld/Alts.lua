-- Dragonworld - main and alts
-- A player can show the guild which characters are theirs. It is off until
-- the player turns it on, on their own member card ("My characters").
--
-- How a link is made (nobody can claim someone else's characters):
--   * The player ticks characters of their own account (those the addon has
--     seen in the guild, DragonworldDB.memberCharacters) and picks a main.
--   * Each character publishes its own record (Profile.lua, message K): the
--     list of characters it says belong together. Only the character itself
--     sends its record, and the receiver checks that the game-given sender
--     is that character (DW.AltSenderMatches).
--   * Two characters are linked only when EACH lists the other. So a link
--     shows once every character has logged in once with the addon after the
--     choice was saved, and members see it after they have been online at the
--     same time as each character (or got a full sync while it was online).
--
-- Others then see "Also plays: ..." on the card, last online covering all the
-- characters, and Roster folds them into one row with a "+N".
--
-- Saved, account-wide: DragonworldDB.alts = {
--   on = false,        "Show my characters to the guild"
--   time = 0,          server time of the last saved change (0 = never took part)
--   main = GUID or nil,
--   show = { [guid] = true },  the ticked characters
--   told = { [guid] = true },  characters that got the "not shown" chat line
-- }
-- Each character's record is kept in DragonworldDB.profiles[guid].alts =
-- { time, state = "S" (shown) / "H" (hidden while the account shares) /
-- "O" (sharing off), list = { full GUIDs, main first } } (Profile.lua).
--
-- All text is in Locales.lua (MC_ALTS..., RO_ALTS..., ALT_...).

local ADDON_NAME, DW = ...
local L = DW.L

DW.ALT_MAX = 12
local ROSTER_MAX_AGE = 5     -- seconds a read of the guild roster is reused
local REMIND_DELAY = 12      -- after login: the chat line for a character that is not ticked
local PICKER_NAME = "DragonworldAltPicker"
local ROW_HEIGHT = 22

-- Saved data --------------------------------------------------------------------

-- The saved choice, or nil when this account never opened it. Never creates it,
-- so an account that does not take part keeps no data and sends nothing.
local function Saved()
    if type(DragonworldDB) ~= "table" or type(DragonworldDB.alts) ~= "table" then
        return nil
    end
    return DragonworldDB.alts
end

-- The saved choice, created when missing.
local function Store()
    if type(DragonworldDB) ~= "table" then
        return { on = false, time = 0, show = {}, told = {} }
    end
    local store = DragonworldDB.alts
    if type(store) ~= "table" then
        store = {}
        DragonworldDB.alts = store
    end
    store.on = store.on == true
    if type(store.time) ~= "number" then
        store.time = 0
    end
    if type(store.main) ~= "string" then
        store.main = nil
    end
    if type(store.show) ~= "table" then
        store.show = {}
    end
    if type(store.told) ~= "table" then
        store.told = {}
    end
    return store
end

-- A GUID that can go in a K message: "Player-<server>-<id>", where the part
-- after "Player-" is at most 24 bytes.
local function SendableGUID(guid)
    return type(guid) == "string" and guid:find("^Player%-[%w]+%-[%w]+$") ~= nil and #guid - 7 <= 24
end

-- The guild roster ----------------------------------------------------------------

local index = { rows = {}, byGuid = {} }

-- The guild roster with an index by GUID. Read again when it is older than a
-- few seconds or the game says it has changed.
local function RosterIndex()
    local now = GetTime()
    if not index.at or index.dirty or now - index.at > ROSTER_MAX_AGE then
        local rows = DW.ReadGuildRoster()
        local byGuid = {}
        for _, row in ipairs(rows) do
            if row.guid then
                byGuid[row.guid] = row
            end
        end
        index = { at = now, rows = rows, byGuid = byGuid }
    end
    return index
end

-- Makes the next look at the roster read it again (Profile.lua calls this
-- before it retries messages that waited for the roster).
function DW.InvalidateAltRoster()
    index.dirty = true
end

-- Is the game-given sender of a message the character with this GUID? False
-- when the GUID is not in the guild roster (yet).
function DW.AltSenderMatches(guid, sender)
    if type(guid) ~= "string" or type(sender) ~= "string" then
        return false
    end
    local row = RosterIndex().byGuid[guid]
    if not row then
        return false
    end
    if DW.NameKey(row.key) == "" or DW.IsSecret(row.key) or DW.IsSecret(sender) then
        return false
    end
    -- The whole name must match (a realm other than yours too), so a member
    -- with the same first name, or the same name on another (connected)
    -- realm, cannot speak for this character.
    return DW.SameCharacter(row.key, sender)
end

-- A roster row as the member card wants it: with the member's professions.
function DW.AltCardRow(row)
    local copy
    if DW.RosterRowOf then
        copy = DW.RosterRowOf(row)
    else
        copy = {}
        for key, value in pairs(row) do
            copy[key] = value
        end
        copy.professions = DW.ProfessionsOfMember and DW.ProfessionsOfMember(row) or {}
    end
    copy.altGroup, copy.altKept, copy.altChild = nil, nil, nil
    return copy
end

-- Your own record -------------------------------------------------------------------

-- The roster row of a ticked character with the highest level (then name).
local function HighestTicked(show, rows)
    local best
    for _, row in ipairs(rows) do
        if row.guid and show[row.guid] and (not best or row.level > best.level or (row.level == best.level and row.name < best.name)) then
            best = row
        end
    end
    return best and best.guid
end

-- What this character publishes: nil when the account never took part (or the
-- game has not given our GUID yet), else { time, state, list }.
function DW.MyAltRecord()
    local store = Saved()
    local me = DW.MyGUID()
    if not store or type(store.time) ~= "number" or store.time <= 0 or not me then
        return nil
    end
    if store.on ~= true then
        return { time = store.time, state = "O", list = {} }
    end
    local show = type(store.show) == "table" and store.show or {}
    if not show[me] or not SendableGUID(me) then
        return { time = store.time, state = "H", list = {} }
    end
    local main = store.main
    if not (main and show[main] and SendableGUID(main)) then
        main = HighestTicked(show, RosterIndex().rows) or me
    end
    local rest = {}
    for guid, ticked in pairs(show) do
        if ticked == true and guid ~= main and SendableGUID(guid) then
            rest[#rest + 1] = guid
        end
    end
    table.sort(rest)
    local list = { main }
    for _, guid in ipairs(rest) do
        if #list >= DW.ALT_MAX then
            break
        end
        list[#list + 1] = guid
    end
    local hasMe = false
    for _, guid in ipairs(list) do
        hasMe = hasMe or guid == me
    end
    if not hasMe then
        list[math.min(#list + 1, DW.ALT_MAX)] = me
    end
    return { time = store.time, state = "S", list = list }
end

-- The characters of this account that are in the guild, as far as the addon
-- has seen them: { guid, name, class, level, current, row }, highest level first.
function DW.MyAccountCharacters()
    local idx = RosterIndex()
    local byKey, byName = {}, {}
    for _, row in ipairs(idx.rows) do
        if row.guid then
            byKey[row.key] = byKey[row.key] or row
            local nameKey = DW.NameKey(row.key)
            byName[nameKey] = byName[nameKey] or row
        end
    end
    local me = DW.MyGUID()
    local out, seen = {}, {}
    local function Add(row)
        if row and row.guid and not seen[row.guid] then
            seen[row.guid] = true
            out[#out + 1] = { guid = row.guid, name = row.name, class = row.class, level = row.level, current = row.guid == me, row = row }
        end
    end
    if me then
        if idx.byGuid[me] then
            Add(idx.byGuid[me])
        else
            local _, name = DW.CharacterKey()
            local _, class = UnitClass("player")
            seen[me] = true
            out[#out + 1] = { guid = me, name = name or "?", class = type(class) == "string" and not DW.IsSecret(class) and class or "",
                level = tonumber(UnitLevel("player")) or 0, current = true }
        end
    end
    local characters = type(DragonworldDB) == "table" and type(DragonworldDB.memberCharacters) == "table" and DragonworldDB.memberCharacters or {}
    for key in pairs(characters) do
        if type(key) == "string" then
            Add(byKey[key] or byName[DW.NameKey(key)])
        end
    end
    table.sort(out, function(a, b)
        if a.level ~= b.level then
            return a.level > b.level
        end
        if a.name ~= b.name then
            return a.name < b.name
        end
        return a.guid < b.guid
    end)
    return out
end

-- The choice ---------------------------------------------------------------------

local listeners = {}

-- Registers a function that is called after your own choice has changed.
function DW.OnAltsChanged(callback)
    listeners[#listeners + 1] = callback
end

local function CopySet(set)
    local copy = {}
    for key, value in pairs(type(set) == "table" and set or {}) do
        if value == true then
            copy[key] = true
        end
    end
    return copy
end

-- Your choice: { on, main, show = { [guid] = true } (a copy), time }.
function DW.GetMyAltChoice()
    local store = Saved()
    if not store then
        return { on = false, show = {}, time = 0 }
    end
    return { on = store.on == true, main = type(store.main) == "string" and store.main or nil, show = CopySet(store.show),
        time = type(store.time) == "number" and store.time or 0 }
end

local function SameSet(a, b)
    for key in pairs(a) do
        if not b[key] then
            return false
        end
    end
    for key in pairs(b) do
        if not a[key] then
            return false
        end
    end
    return true
end

-- Saves your choice and sends it. show is limited to the characters of this
-- account the addon knows. Returns false when nothing changed.
function DW.SetMyAltChoice(on, main, show)
    on = on == true
    local characters = DW.MyAccountCharacters()
    local allowed = {}
    for _, character in ipairs(characters) do
        allowed[character.guid] = true
    end
    local newShow = {}
    for guid, ticked in pairs(type(show) == "table" and show or {}) do
        if ticked and allowed[guid] then
            newShow[guid] = true
        end
    end
    -- The main is always a ticked character: else the highest-level ticked one
    -- (MyAccountCharacters is highest level first), or none when nothing is ticked.
    main = type(main) == "string" and newShow[main] and main or nil
    if not main then
        for _, character in ipairs(characters) do
            if not main and newShow[character.guid] then
                main = character.guid
            end
        end
    end
    local store = Saved()
    -- Turning sharing "off" on an account that never took part changes nothing:
    -- such an account keeps no data and sends nothing.
    if not on and not (store and type(store.time) == "number" and store.time > 0) then
        return false
    end
    local oldShow = store and CopySet(store.show) or {}
    local oldOn = store and store.on == true or false
    local oldMain = store and type(store.main) == "string" and store.main or nil
    if oldOn == on and oldMain == main and SameSet(oldShow, newShow) then
        return false
    end
    store = Store()
    store.on = on
    store.main = main
    store.show = newShow
    store.time = math.max(DW.ServerNow(), store.time + 1)
    DW.PublishProfile()
    for _, callback in ipairs(listeners) do
        local ok, problem = pcall(callback)
        if not ok then
            DW.PrintError(L.ERROR, problem)
        end
    end
    return true
end

-- Groups --------------------------------------------------------------------------

local function Age(row)
    if row.online then
        return -1
    end
    return (row.days or 0) * 24 + (row.hours or 0)
end

local function SortMembers(members, mainGuid)
    table.sort(members, function(a, b)
        if (a.guid == mainGuid) ~= (b.guid == mainGuid) then
            return a.guid == mainGuid
        end
        if a.level ~= b.level then
            return a.level > b.level
        end
        if a.name ~= b.name then
            return a.name < b.name
        end
        return a.guid < b.guid
    end)
end

-- The linked characters among roster rows. Returns byGuid (a character's
-- GUID -> its group) and the list of groups. A group is { key (the main's
-- GUID), main (row), members (rows: main first, then level, then name),
-- online, days, hours (of the most recent member; 0/0 when online), recent
-- (that member's row) }.
--
-- Two characters are linked only when each one's record lists the other. The
-- newest record of the linked characters says who belongs (its list) and who
-- the main is. A character whose newest record turned sharing off ("O") after
-- that hides the whole group, until a newer record brings it back.
function DW.AltGroups(rows)
    local byRow, records, listed, guids = {}, {}, {}, {}
    for _, row in ipairs(type(rows) == "table" and rows or {}) do
        if type(row) == "table" and row.guid and not byRow[row.guid] then
            byRow[row.guid] = row
            guids[#guids + 1] = row.guid
        end
    end
    table.sort(guids)
    local function Record(guid)
        if records[guid] == nil then
            records[guid] = DW.AltRecordOf and DW.AltRecordOf(guid) or false
        end
        return records[guid] or nil
    end
    for _, guid in ipairs(guids) do
        local record = Record(guid)
        if record and record.state == "S" then
            local set = {}
            for _, other in ipairs(record.list) do
                set[other] = true
            end
            listed[guid] = set
        end
    end

    -- Union-find over the links both sides agree on.
    local parent = {}
    local function Find(guid)
        while parent[guid] ~= guid do
            parent[guid] = parent[parent[guid]]
            guid = parent[guid]
        end
        return guid
    end
    for guid in pairs(listed) do
        parent[guid] = guid
    end
    for _, guid in ipairs(guids) do
        local set = listed[guid]
        if set then
            for other in pairs(set) do
                if other ~= guid and byRow[other] and listed[other] and listed[other][guid] then
                    local a, b = Find(guid), Find(other)
                    if a ~= b then
                        if a < b then
                            parent[b] = a
                        else
                            parent[a] = b
                        end
                    end
                end
            end
        end
    end
    local components, roots = {}, {}
    for _, guid in ipairs(guids) do
        if listed[guid] then
            local root = Find(guid)
            if not components[root] then
                components[root] = {}
                roots[#roots + 1] = root
            end
            local list = components[root]
            list[#list + 1] = guid
        end
    end

    local byGuid, groups = {}, {}
    for _, root in ipairs(roots) do
        local component = components[root]
        if #component >= 2 then
            local inComponent = {}
            local truthGuid
            for _, guid in ipairs(component) do
                inComponent[guid] = true
                local record = Record(guid)
                local best = truthGuid and Record(truthGuid)
                if not best or record.time > best.time or (record.time == best.time and guid > truthGuid) then
                    truthGuid = guid
                end
            end
            local truth = Record(truthGuid)
            local members, isMember = {}, {}
            for _, guid in ipairs(truth.list) do
                if inComponent[guid] and not isMember[guid] then
                    isMember[guid] = true
                    members[#members + 1] = byRow[guid]
                end
            end
            local withdrawn = false
            for _, guid in ipairs(component) do
                for _, other in ipairs(Record(guid).list) do
                    local otherRecord = Record(other)
                    if otherRecord and otherRecord.state == "O" and otherRecord.time > truth.time then
                        withdrawn = true
                    end
                end
            end
            if not withdrawn and #members >= 2 then
                local mainGuid = truth.list[1]
                if not isMember[mainGuid] then
                    local best
                    for _, row in ipairs(members) do
                        if not best or row.level > best.level or (row.level == best.level and row.name < best.name) then
                            best = row
                        end
                    end
                    mainGuid = best.guid
                end
                SortMembers(members, mainGuid)
                local recent = members[1]
                for _, row in ipairs(members) do
                    if Age(row) < Age(recent) then
                        recent = row
                    end
                end
                local group = {
                    key = mainGuid, main = byRow[mainGuid], members = members, recent = recent,
                    online = recent.online == true,
                    days = recent.online and 0 or (recent.days or 0),
                    hours = recent.online and 0 or (recent.hours or 0),
                }
                groups[#groups + 1] = group
                for _, row in ipairs(members) do
                    byGuid[row.guid] = group
                end
            end
        end
    end
    return byGuid, groups
end

-- The groups for the cached roster, worked out again when the roster is read
-- again or a profile has changed.
local groupCache = { version = 0 }
local profileVersion = 0

local function CachedGroups()
    local idx = RosterIndex()
    if groupCache.index ~= idx or groupCache.version ~= profileVersion then
        local byGuid, groups = DW.AltGroups(idx.rows)
        groupCache = { index = idx, version = profileVersion, byGuid = byGuid, groups = groups }
    end
    return groupCache
end

-- The group a member (a roster row, matched by GUID) belongs to, or nil.
function DW.AltGroupOf(member)
    if type(member) ~= "table" or not member.guid then
        return nil
    end
    return CachedGroups().byGuid[member.guid]
end

-- The main of a member's group (a roster row), or the member itself when it
-- has no group.
function DW.MainOf(member)
    local group = DW.AltGroupOf(member)
    return group and group.main or member
end

-- The picker ---------------------------------------------------------------------

local picker
local pickOn, pickMain, pickShow = false, nil, {}
local RefreshPicker

local function TickedCount()
    local count = 0
    for _ in pairs(pickShow) do
        count = count + 1
    end
    return count
end

-- Your own card again, after the picker closes.
local function ReopenMyCard()
    local me = DW.MyGUID()
    local row = me and RosterIndex().byGuid[me]
    if row and DW.ShowMemberCard then
        DW.ShowMemberCard(DW.AltCardRow(row))
    end
end

local function GetPickerRow(i)
    local row = picker.rows[i]
    if row then
        return row
    end
    row = CreateFrame("Frame", nil, picker.content)
    row:SetSize(picker.content:GetWidth(), ROW_HEIGHT)
    row:SetPoint("TOPLEFT", 0, -(i - 1) * ROW_HEIGHT)

    row.check = CreateFrame("CheckButton", nil, row, "UICheckButtonTemplate")
    row.check:SetSize(20, 20)
    row.check:SetPoint("LEFT", 0, 0)
    row.check:SetScript("OnClick", function(self)
        local guid = row.guid
        if not guid then
            return
        end
        if self:GetChecked() then
            if not pickShow[guid] and TickedCount() >= DW.ALT_MAX then
                self:SetChecked(false)
                picker.error:SetText(L.ALT_MAX:format(DW.ALT_MAX))
                return
            end
            pickShow[guid] = true
        else
            pickShow[guid] = nil
        end
        picker.error:SetText("")
        RefreshPicker()
    end)

    row.name = row:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
    row.name:SetPoint("LEFT", 26, 0)
    row.name:SetWidth(180)
    row.name:SetJustifyH("LEFT")
    row.name:SetWordWrap(false)

    row.level = row:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    row.level:SetPoint("LEFT", 212, 0)
    row.level:SetWidth(70)
    row.level:SetJustifyH("LEFT")

    -- "Main": click to make this character the main (ticked rows only).
    row.main = DW.CreateChip(row, 110, 20)
    row.main:SetPoint("LEFT", 288, 0)
    row.main.label:SetFontObject("GameFontHighlightSmall")
    row.main.label:SetJustifyH("CENTER")
    row.main:SetScript("OnClick", function()
        if row.guid and pickShow[row.guid] then
            pickMain = row.guid
            RefreshPicker()
        end
    end)

    row.status = row:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    row.status:SetPoint("LEFT", 408, 0)
    row.status:SetWidth(row:GetWidth() - 408)
    row.status:SetJustifyH("LEFT")
    row.status:SetWordWrap(false)

    picker.rows[i] = row
    return row
end

RefreshPicker = function()
    if not picker or not picker:IsShown() then
        return
    end
    picker.title:SetText(L.ALT_TITLE)
    picker.hint:SetText(L.ALT_HINT)
    picker.shareLabel:SetText(L.ALT_SHARE)
    picker.share:SetChecked(pickOn)
    picker.save.label:SetText(L.ALT_SAVE)
    picker.cancel.label:SetText(L.ALT_CANCEL)
    picker.empty:SetText(L.ALT_EMPTY)

    local characters = DW.MyAccountCharacters()
    local store = Saved()
    local savedTime = store and store.time or 0
    local alone = #characters < 2
    picker.empty:SetShown(alone)
    local shown = alone and 0 or #characters
    for i = 1, shown do
        local character = characters[i]
        local row = GetPickerRow(i)
        local ticked = pickShow[character.guid] == true
        row.guid = character.guid
        row.check:SetChecked(ticked)
        row.name:SetText(character.name)
        local colour = RAID_CLASS_COLORS and RAID_CLASS_COLORS[character.class]
        if colour then
            row.name:SetTextColor(colour.r, colour.g, colour.b)
        else
            row.name:SetTextColor(1, 1, 1)
        end
        row.level:SetText(L.RO_TIP_LEVEL:format(character.level))
        row.main.label:SetText(L.ALT_MAIN)
        row.main:SetShown(ticked)
        row.main:SetSelected(ticked and pickMain == character.guid)
        local record = DW.AltRecordOf and DW.AltRecordOf(character.guid)
        if character.current then
            row.status:SetText(L.ALT_ROW_CURRENT)
            row.status:SetTextColor(1, 1, 1)
        elseif not ticked then
            row.status:SetText(L.ALT_ROW_HIDDEN)
            row.status:SetTextColor(0.55, 0.55, 0.55)
        elseif record and savedTime > 0 and record.time == savedTime and record.state == "S" then
            row.status:SetText(L.ALT_ROW_LINKED)
            row.status:SetTextColor(0.25, 1.00, 0.25)
        else
            row.status:SetText(L.ALT_ROW_PENDING)
            row.status:SetTextColor(1.00, 0.60, 0.20)
        end
        row:Show()
    end
    for i = shown + 1, #picker.rows do
        picker.rows[i].guid = nil
        picker.rows[i]:Hide()
    end
    picker.content:SetHeight(math.max(1, shown * ROW_HEIGHT))
end

local function SavePicker()
    -- Save with the box off on an account that never took part: nothing to save
    -- or say (it would make the account send "off" records for good).
    if not pickOn and DW.GetMyAltChoice().time == 0 then
        picker:Hide()
        ReopenMyCard()
        return
    end
    local characters = DW.MyAccountCharacters()
    local count = 0
    for _, character in ipairs(characters) do
        if pickShow[character.guid] then
            count = count + 1
        end
    end
    if pickOn and count < 2 then
        picker.error:SetText(L.ALT_NEED_TWO)
        return
    end
    local main = pickMain
    if not (main and pickShow[main]) then
        main = nil
        for _, character in ipairs(characters) do -- highest level first
            if not main and pickShow[character.guid] then
                main = character.guid
            end
        end
    end
    DW.SetMyAltChoice(pickOn, main, pickShow)
    DW.Print(pickOn and L.ALT_SAVED_ON or L.ALT_SAVED_OFF)
    picker:Hide()
    ReopenMyCard()
end

local function CreatePicker(window)
    local p = CreateFrame("Frame", PICKER_NAME, window, "BackdropTemplate")
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
    p.rows = {}
    picker = p
    local width = p:GetWidth()

    p.title = p:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
    p.title:SetPoint("TOPLEFT", 16, -12)

    p.hint = p:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    p.hint:SetPoint("TOPLEFT", 16, -36)
    p.hint:SetWidth(width - 32)
    p.hint:SetJustifyH("LEFT")

    -- The master switch, under the hint (which may take several lines).
    p.share = CreateFrame("CheckButton", nil, p, "UICheckButtonTemplate")
    p.share:SetSize(22, 22)
    p.share:SetPoint("TOPLEFT", p.hint, "BOTTOMLEFT", -2, -8)
    p.share:SetScript("OnClick", function(self)
        pickOn = self:GetChecked() and true or false
        p.error:SetText("")
    end)
    p.shareLabel = p:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    p.shareLabel:SetPoint("LEFT", p.share, "RIGHT", 4, 0)

    local scroll = CreateFrame("ScrollFrame", "DragonworldAltPickerScroll", p, "ScrollFrameTemplate")
    scroll:SetPoint("TOPLEFT", p.share, "BOTTOMLEFT", 2, -8)
    scroll:SetPoint("BOTTOMRIGHT", -36, 64)
    p.scroll = scroll
    p.content = CreateFrame("Frame", nil, scroll)
    p.content:SetSize(width - 32 - 20, 1)
    scroll:SetScrollChild(p.content)

    p.empty = p:CreateFontString(nil, "OVERLAY", "GameFontDisable")
    p.empty:SetPoint("TOPLEFT", scroll, "TOPLEFT", 0, -8)
    p.empty:SetWidth(width - 64)
    p.empty:SetJustifyH("LEFT")

    p.error = p:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    p.error:SetPoint("BOTTOMLEFT", 16, 46)
    p.error:SetTextColor(1.00, 0.35, 0.30)

    p.cancel = DW.CreateChip(p, 100, 28)
    p.cancel:SetPoint("BOTTOMRIGHT", -16, 12)
    p.cancel.label:SetJustifyH("CENTER")
    p.cancel:SetScript("OnClick", function()
        p:Hide()
        ReopenMyCard()
    end)

    p.save = DW.CreateButton(p, 130, 28, "gold")
    p.save:SetPoint("RIGHT", p.cancel, "LEFT", -8, 0)
    p.save:SetScript("OnClick", SavePicker)

    DW.RegisterOverlay(PICKER_NAME)
    return p
end

-- Opens "My characters" (from your own member card), with what was saved.
function DW.OpenAltPicker()
    local window = _G.DragonworldFrame
    if not window or not DW.IsMember() then
        return
    end
    -- Laid out for the full window: the compact view becomes it first.
    DW.ExpandWindow()
    if not picker then
        CreatePicker(window)
    end
    -- Only one such window on top at a time (MainWindow.lua's overlay registry).
    DW.HideOverlays(PICKER_NAME)
    local choice = DW.GetMyAltChoice()
    pickOn = choice.on
    -- Only characters the list shows, so the limit of 12 counts what you see.
    pickShow = {}
    for _, character in ipairs(DW.MyAccountCharacters()) do
        if choice.show[character.guid] then
            pickShow[character.guid] = true
        end
    end
    local me = DW.MyGUID()
    pickMain = choice.main and pickShow[choice.main] and choice.main or me
    -- The first time, the character you are on is ticked already.
    if choice.time == 0 and me then
        pickShow[me] = true
    end
    picker.error:SetText("")
    picker:Show()
    RefreshPicker()
end

-- Events ----------------------------------------------------------------------

DW.OnProfileChanged(function()
    profileVersion = profileVersion + 1
    RefreshPicker()
end)
DW.OnAltsChanged(function()
    profileVersion = profileVersion + 1
end)
DW.OnLanguageChanged(function()
    RefreshPicker()
end)

-- A character of an account that shares, but which is not ticked: tell the
-- player once how to add it.
local remindQueued = false

local function PlanReminder()
    local store = Saved()
    if remindQueued or not store or store.on ~= true or not (C_Timer and C_Timer.After) then
        return
    end
    remindQueued = true
    C_Timer.After(REMIND_DELAY, function()
        remindQueued = false
        local current = Saved()
        local me = DW.MyGUID()
        if not DW.IsMember() or not current or current.on ~= true or not me then
            return
        end
        local show = type(current.show) == "table" and current.show or {}
        if type(current.told) ~= "table" then
            current.told = {}
        end
        if not show[me] and not current.told[me] then
            current.told[me] = true
            DW.Print(L.ALT_NEW_CHAR)
        end
    end)
end

local frame = CreateFrame("Frame")
frame:SetScript("OnEvent", function(self, event)
    if event == "GUILD_ROSTER_UPDATE" then
        index.dirty = true
    elseif event == "PLAYER_ENTERING_WORLD" and DW.IsMember() then
        PlanReminder()
    end
end)
frame:RegisterEvent("GUILD_ROSTER_UPDATE")
frame:RegisterEvent("PLAYER_ENTERING_WORLD")

DW.OnMembershipChanged(function(member)
    if member then
        PlanReminder()
    end
end)

DW.AddDebug("alts", function(add)
    local text = DW.DebugText
    local store = Saved()
    local ticked = 0
    for _ in pairs(store and type(store.show) == "table" and store.show or {}) do
        ticked = ticked + 1
    end
    add("på: " .. text(store and store.on or false) .. " | tid: " .. text(store and store.time or 0) .. " | main: " .. text(store and store.main)
        .. " | krysset av: " .. ticked)
    local record = DW.MyAltRecord()
    add("min post: " .. (record and (record.state .. " " .. record.time .. " [" .. table.concat(record.list, ",") .. "]") or "ingen"))
    local sentK, stored, buffered = 0, 0, 0
    if DW.AltProfileStats then
        sentK, stored, buffered = DW.AltProfileStats()
    end
    add("sendt K: " .. text(sentK) .. " | K lagret: " .. text(stored) .. " | grupper: " .. #CachedGroups().groups
        .. " | K som venter: " .. text(buffered))
end)
