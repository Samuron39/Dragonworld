-- Dragonworld - Medlemmer
-- Viser alle i guilden, også de som er avlogget, med level, rank, professions
-- og når de sist var pålogget. Listen kan filtreres på status (alle, pålogget,
-- aktive, inaktive) og på profession, og det er et søkefelt.
--
-- Hvor opplysningene kommer fra:
--   * Navn, level, klasse, rank, sone, notat og sist pålogget kommer fra
--     spillets egen medlemsliste, og finnes for alle.
--   * Professions oppgir ikke spillet for andre spillere. Derfor forteller
--     hver addon resten av guilden hvilke professions karakteren har, og alle
--     tar vare på det de får høre. Professions vises altså bare for medlemmer
--     som bruker addonen, og først etter at dere har vært pålogget samtidig.
--   * Har klienten spillets gamle guild-oversikt over professions, brukes den
--     i tillegg for dem addonen ikke har hørt fra.
--
-- Se hva et medlem kan lage: når du åpner en av dine egne professions, tar
-- addonen vare på spillets lenke til den (den samme som når man deler en
-- profession i chatten) og sender den til guilden. I listen er slike
-- professions gule. Et klikk åpner spillets eget vindu med oppskriftene,
-- akkurat som et klikk på lenken i chatten.
--
-- Egne professions leses på tre måter, fordi spillet ikke alltid oppgir dem
-- likt: karakterens profession-liste, håndverkssystemets liste, og det som
-- sto i håndverksvinduet sist det var åpent.
--
-- Medlemmer kjennes igjen på spillerens faste ID, ikke på navnet. I Forever
-- kan navn ha mellomrom, og spillet skriver dem ikke likt overalt.
--
-- "Aktiv" betyr pålogget i løpet av de siste 30 dagene.
--
-- All tekst ligger i Locales.lua (navnene som begynner med RO_).

local ADDON_NAME, DW = ...
local L = DW.L

local MODULE_ID = "roster"
local PREFIX = "DragonworldPr" -- navnet på meldingene; maks 16 tegn
local SEP = "\t"
local ACTIVE_DAYS = 30
local MAX_PROFESSIONS = 8
local MAX_LINK_BYTES = 40

-- Lagrede data. Settes i OnLoad nederst.
--   db.professions[nøkkel] = {
--       list = { { name = "Mining", level = 225, max = 300 }, ... },
--       links = { Blacksmithing = "2018:164" },   -- se under
--       updated = når vi sist fikk høre det,
--   }
--   Nøkkelen er spillerens faste ID. For meldinger fra eldre versjoner uten
--   ID er den "name:" fulgt av navnet uten mellomrom og realm.
--   db.seen[nøkkel][navn] = { level, max, link }: det vi har sett i ditt eget
--   håndverksvindu.
--
-- Spillets lenke til en profession ser slik ut: "trade:<spillerens ID>:2018:164".
-- Vi lagrer og sender bare det som står etter ID-en, og setter lenken sammen
-- igjen når noen klikker.
local db = { professions = {}, seen = {} }

-- Småting -----------------------------------------------------------------------

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

-- Navn på en profession, uten tegn som brukes som skilletegn i meldingene.
local function CleanName(text)
    text = tostring(text):gsub("[%c|:;]", " ")
    text = text:gsub("^%s+", "")
    text = text:gsub("%s+$", "")
    return text:sub(1, 40)
end

local function NameStoreKey(name)
    return "name:" .. DW.NameKey(name)
end

-- Nøkkelen vi lagrer denne karakterens egne professions under.
local function MyStoreKey()
    local guid = DW.MyGUID()
    if guid then
        return guid
    end
    local _, name = DW.CharacterKey()
    return name and NameStoreKey(name) or nil
end

-- Er dette slutten av en profession-lenke slik vi godtar den? Bare bokstaver,
-- tall, kolon og bindestrek, så ingen kan smugle inn noe annet.
local function ValidLinkRest(rest)
    return type(rest) == "string" and #rest > 0 and #rest <= MAX_LINK_BYTES and rest:find("^[%w:%-]+$") ~= nil
end

-- Egne professions --------------------------------------------------------------

-- Viser håndverksvinduet noe som ikke er ditt eget: en annens profession (åpnet
-- fra en lenke), guildens, eller en NPC sin?
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

-- Spillets lenke til professionen som står i håndverksvinduet. Returnerer
-- spillerens ID og det som står etter den i lenken, eller nil.
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

-- Professions spillet selv lister for karakteren (uten det vi har sett i
-- håndverksvinduet). Hver har også spillets nummer på professionen (line),
-- som trengs for å åpne den. Returnerer en tabell med navnet som nøkkel, og
-- funksjonen som legger til flere.
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

    -- 1. Karakterens egen liste over professions.
    if GetProfessions and GetProfessionInfo then
        for _, index in pairs({ GetProfessions() }) do
            local name, _, level, max, _, _, line = GetProfessionInfo(index)
            if Text(name) ~= "" and type(level) == "number" and not DW.IsSecret(level) then
                Add(name, level, Number(max), line)
            end
        end
    end

    -- 2. Håndverkssystemets liste. Den har alle professions som finnes, så vi
    --    tar bare dem karakteren har skill i.
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

-- Professionen addonen akkurat nå har bedt spillet åpne (se "Åpne neste"
-- lenger ned), eller nil.
local opening

-- Leser hvilken profession som står i håndverksvinduet akkurat nå, og husker
-- den. Returnerer true hvis vi fant noe.
local function RememberOpenTradeSkill()
    local name, level, max, windowLine

    -- Ser du på en annens profession, er det ikke din.
    local linkOwner, linkRest = ReadOpenLink()
    local me = DW.MyGUID()
    if ShowsSomeoneElse() or (linkOwner and me and linkOwner ~= me) then
        return false
    end
    if linkOwner ~= me then
        linkRest = nil -- uten egen ID kan vi ikke vite at lenken er din
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

    -- Vinduet kan hete noe annet enn professionen i karakterens liste (vinduet
    -- til Mining kan f.eks. hete "Smelting"). Bruk navnet fra listen når
    -- spillets nummer på professionen stemmer, eller når det var addonen som
    -- nettopp ba om å få akkurat den åpnet.
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
    -- Lenken kommer ikke alltid med en gang vinduet åpnes. Behold den vi
    -- hadde hvis spillet ikke ga noen nå.
    name = CleanName(name)
    local before = db.seen[key][name]
    db.seen[key][name] = {
        level = level,
        max = max,
        link = linkRest or (type(before) == "table" and ValidLinkRest(before.link) and before.link) or nil,
    }
    return true
end

local function ReadMyProfessions()
    -- 1 og 2: det spillet selv lister for karakteren.
    local byName, Add = ReadListedProfessions()

    -- 3. Det vi har sett i håndverksvinduet. Derfra har vi også lenkene.
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

-- Gjør listen om til tekst for en melding: "Mining:225:300;Cooking:150:225".
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

-- Lenkene som tekst for en melding: "Blacksmithing:2018:164;Mining:2575:186".
-- Tar med så mange som får plass i én melding.
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

-- Leser egne professions og tar vare på dem. Returnerer teksten til meldingen
-- om professions, nøkkelen, og teksten til meldingen om lenker.
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

-- Deling ------------------------------------------------------------------------

local Send = DW.CreateSender(PREFIX)
local QueueRefresh

local lastSent, lastSentLinks -- det vi sist fortalte guilden, så vi ikke gjentar oss

-- Forteller guilden hvilke professions karakteren har, hvis noe er endret
-- (eller alltid, med force). Meldingen har spillerens faste ID først. Lenkene
-- til professions går i en egen melding, så eldre versjoner av addonen ikke
-- snubler i dem.
local function Publish(force)
    local text, key, links = StoreMine()
    if not text then
        return
    end
    if force or text ~= lastSent then
        lastSent = text
        Send("P" .. SEP .. key .. SEP .. text)
    end
    if links ~= "" and key:find("^Player%-") and (force or links ~= lastSentLinks) then
        lastSentLinks = links
        Send("L" .. SEP .. key .. SEP .. links)
    end
end

local replyScheduled = false

-- Noen ba alle om å si fra. Svar etter en tilfeldig ventetid, så ikke hele
-- guilden svarer i samme øyeblikk.
local function ScheduleReply()
    if replyScheduled then
        return
    end
    replyScheduled = true
    C_Timer.After(1 + math.random() * 7, function()
        replyScheduled = false
        if DW.IsMember() then
            Publish(true)
        end
    end)
end

DW.OnGuildMessage(PREFIX, function(text, sender)
    local kind = text:sub(1, 1)
    if kind == "P" then
        -- Et medlem forteller hvilke professions karakteren har.
        local guid, rest = text:match("^P\t(Player%-[^\t]+)\t?(.*)$")
        local key = guid
        if not key then
            -- Eldre versjon uten ID: bruk avsenderens navn.
            key, rest = NameStoreKey(sender), text:sub(3)
        end
        -- Lenkene kommer i en egen melding; behold dem vi har.
        local before = db.professions[key]
        db.professions[key] = {
            list = Parse(rest),
            links = type(before) == "table" and before.links or nil,
            updated = time(),
        }
        QueueRefresh()
    elseif kind == "L" then
        -- Lenkene til et medlems professions, så de kan åpnes herfra.
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
    elseif kind == "R" then
        ScheduleReply()
    end
end)

-- Spillets egen oversikt -------------------------------------------------------

-- Noen klienter har en guild-oversikt over professions innebygd. Finnes den,
-- leser vi den for å dekke medlemmer addonen ikke har hørt fra. Den huskes
-- ikke mellom økter. Nøkkelen er navnet uten mellomrom og realm.
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

-- Professions for ett medlem: det addonen har fått høre, ellers spillets egen
-- oversikt. Andre verdi sier hvor det kom fra ("addon", "game" eller nil),
-- tredje er oppføringen vi fant, og fjerde er nøkkelen den lå under.
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

-- Åpne et medlems profession -----------------------------------------------------

-- Spillets lenke til et medlems profession ("trade:<ID>:2018:164"), eller nil
-- hvis medlemmet ikke har delt den.
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

-- Åpner spillets vindu med hva medlemmet kan lage. Vi gjør nøyaktig det
-- spillet gjør når man klikker på en profession-lenke i chatten. Går ikke
-- det, legges lenken i chatten din så du kan klikke på den der.
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

-- Påminnelsen om å åpne professionene -----------------------------------------------
--
-- Addonen får først vite om en profession, og lenken til den, når spilleren
-- åpner den. Derfor vises en liten rute første gang hovedvinduet åpnes på en
-- karakter (rett etter språkvalget), som ber om akkurat det og viser hva som
-- er funnet så langt. Den kan hentes fram igjen fra Medlemmer.

local NOTICE_NAME = "DragonworldShareNotice"

local notice     -- ruten; lages første gang den trengs
local mainWindow -- hovedvinduet, som ruten ligger oppå

-- "Åpne neste": addonen kan åpne en profession for spilleren, men spillet
-- tillater bare én per klikk. Hvert klikk på knappen åpner derfor den neste
-- som ikke er delt. Når lenken er lest, lukkes vinduet igjen.
local tried = {}   -- professions vi har prøvd å åpne i denne økten
local noticeStatus -- { key, navn }: siste beskjed under listen, eller nil

local function CanOpenForPlayer()
    return C_TradeSkillUI ~= nil and type(C_TradeSkillUI.OpenTradeSkill) == "function"
end

-- Denne karakterens professions slik de er lagret, og lenkene til dem.
local function MyStored()
    local key = MyStoreKey()
    local mine = key and db.professions[key]
    if type(mine) ~= "table" or type(mine.list) ~= "table" then
        return {}, {}
    end
    return mine.list, type(mine.links) == "table" and mine.links or {}
end

-- Den neste professionen knappen skal åpne: en som ikke er delt, som spillet
-- har et nummer på, og som vi ikke alt har prøvd.
local function NextToOpen()
    local list, links = MyStored()
    for _, profession in ipairs(list) do
        if profession.line and not links[profession.name] and not tried[profession.name] then
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
        if links[profession.name] then
            lines[#lines + 1] = "|cff40ff40" .. L.RO_SHARE_DONE:format(name) .. "|r"
        else
            lines[#lines + 1] = L.RO_SHARE_TODO:format(name)
        end
    end
    notice.list:SetText(#lines > 0 and table.concat(lines, "\n") or L.RO_SHARE_NONE)

    -- Knappen som åpner den neste. Finnes ikke funksjonen i spillet, vises
    -- bare OK, midt i ruten.
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

-- Åpner den neste professionen som ikke er delt. Må kalles rett fra et klikk:
-- spillet åpner bare en profession for en addon når spilleren selv trykker.
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
        -- Noen professions har ikke noe vindu (f.eks. Fishing).
        noticeStatus = { key = "RO_SHARE_FAILED", name = profession.name }
        RefreshNotice()
        return
    end

    -- Vinduet åpnes, og lenken kommer et øyeblikk etterpå. Se etter den noen
    -- ganger, og lukk vinduet når vi har den.
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
        if links[run.name] then
            opening = nil
            noticeStatus = { key = "RO_SHARE_GOT", name = run.name }
            if C_TradeSkillUI and C_TradeSkillUI.CloseTradeSkill then
                pcall(C_TradeSkillUI.CloseTradeSkill)
            end
        elseif run.checks >= 6 then
            -- Vinduet ga oss ingenting. La det stå åpent, så ser spilleren hva
            -- som kom opp.
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
    f:EnableMouse(true) -- så klikk ikke går gjennom til det som ligger under
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

    -- Hva som skjedde sist knappen "Åpne neste" ble brukt.
    f.status = f:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    f.status:SetPoint("BOTTOMLEFT", 24, 56)
    f.status:SetWidth(432)
    f.status:SetJustifyH("LEFT")
    f.status:SetWordWrap(false)

    -- Åpner den neste professionen som ikke er delt. Ett klikk per profession.
    f.open = DW.CreateButton(f, 240, 28, "gold")
    f.open:SetPoint("BOTTOMRIGHT", f, "BOTTOM", 64, 18)
    f.open:SetScript("OnClick", function()
        OpenNextProfession()
    end)

    f.ok = DW.CreateButton(f, 110, 28, "gold")
    f.ok:SetPoint("BOTTOM", 0, 18)
    f.ok:SetScript("OnClick", function()
        -- Husk at denne karakteren har sett den.
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

-- Første gang hovedvinduet åpnes på en karakter: vis påminnelsen.
DW.OnWindowOpened(function(window)
    mainWindow = window
    local key = DW.CharacterKey()
    if key and not (type(db.reminded) == "table" and db.reminded[key]) then
        ShowNotice()
    elseif notice then
        notice:Hide()
    end
end)

-- Visning ---------------------------------------------------------------------

local ROW_HEIGHT = 22

-- Kolonnene i en rad, fra venstre: navn, level, rank, professions, sist
-- pålogget. Professions får plassen som er igjen.
local NAME_WIDTH, LEVEL_WIDTH, RANK_WIDTH, LAST_WIDTH = 130, 28, 86, 84
local LEGACY_WIDTH = 34   -- legacy-poeng, rett etter level (se Profile.lua)
local PROFESSIONS_LEFT = 4 + NAME_WIDTH + 4 + LEVEL_WIDTH + 6 + LEGACY_WIDTH + 10 + RANK_WIDTH + 8
local PROFESSIONS_RIGHT = 6 + LAST_WIDTH + 8
local PROFESSION_GAP = 10 -- luft mellom to professions
local MORE_WIDTH = 22     -- plass til "+2" når ikke alle får plass

local panel -- lages første gang modulen velges i hovedvinduet
local rows = {}
local RefreshPanel

local filterStatus = "all" -- "all", "online", "active" eller "inactive"
local filterProfession     -- navnet på en profession, eller nil for alle
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

-- Alle professions vi kjenner til, til menyen.
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

-- Medlemmene som passer filtrene, sortert på navn. Returnerer også hvor mange
-- det er i guilden totalt.
local function Collect()
    local members = DW.ReadGuildRoster()

    local needle = searchText:lower()
    needle = needle:gsub("^%s+", "")
    needle = needle:gsub("%s+$", "")

    local list = {}
    for _, member in ipairs(members) do
        member.professions, member.source, member.shared, member.storeKey = ProfessionsOf(member)

        local keep = true
        if filterStatus == "online" then
            keep = member.online
        elseif filterStatus == "active" then
            keep = member.online or member.days < ACTIVE_DAYS
        elseif filterStatus == "inactive" then
            keep = not member.online and member.days >= ACTIVE_DAYS
        end

        if keep and filterProfession then
            keep = false
            for _, profession in ipairs(member.professions) do
                if profession.name == filterProfession then
                    keep = true
                end
            end
        end

        -- Søket leter i navn, rank og professions.
        if keep and needle ~= "" then
            local haystack = (member.name .. " " .. member.rank .. " " .. ProfessionText(member.professions)):lower()
            keep = haystack:find(needle, 1, true) ~= nil
        end

        if keep then
            list[#list + 1] = member
        end
    end

    table.sort(list, function(a, b)
        if a.name ~= b.name then
            return a.name < b.name
        end
        return a.key < b.key
    end)
    return list, #members
end

local function SetStatus(status)
    filterStatus = status
    RefreshPanel()
end

local function SetProfession(name)
    filterProfession = name
    RefreshPanel()
end

-- Menyen for valg av profession. data er navnet, eller false for "alle".
local function OpenProfessionMenu(owner)
    local names = KnownProfessions()

    if not (MenuUtil and MenuUtil.CreateContextMenu) then
        -- Uten meny: gå til neste profession for hvert klikk, og til slutt alle.
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

-- "Blacksmithing 225/300", eller bare "Blacksmithing 225" når vi ikke vet
-- hvor høyt den kan gå.
local function ProfessionLabel(profession)
    if profession.max > 0 then
        return ("%s %d/%d"):format(profession.name, profession.level, profession.max)
    end
    return ("%s %d"):format(profession.name, profession.level)
end

-- Menyen som kommer opp når du klikker på en rad: alle professions medlemmet
-- har. De som er delt kan åpnes; de andre står grå.
local function OpenMemberMenu(owner, member)
    if #member.professions == 0 or not (MenuUtil and MenuUtil.CreateContextMenu) then
        return
    end
    MenuUtil.CreateContextMenu(owner, function(_, root)
        root:CreateTitle(member.name)
        for _, profession in ipairs(member.professions) do
            local entry = root:CreateButton(ProfessionLabel(profession), function()
                OpenProfession(member, profession)
            end)
            if entry and entry.SetEnabled and not LinkData(member, profession) then
                entry:SetEnabled(false)
            end
        end
    end)
end

-- Fargen på en profession i raden: gul når den kan åpnes, ellers hvit.
local function ColourProfession(button, hover)
    if not button.linked then
        button.text:SetTextColor(0.90, 0.90, 0.90)
    elseif hover then
        button.text:SetTextColor(1.00, 1.00, 1.00)
    else
        button.text:SetTextColor(1.00, 0.82, 0.00)
    end
end

-- Én profession i en rad. Den er en knapp, så den kan klikkes på som en lenke
-- i chatten.
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
            OpenProfession(self.member, self.profession)
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

-- Legger medlemmets professions ut i raden, så mange som får plass. Resten
-- vises som "+2", og finnes i menyen når du klikker på raden.
local function LayoutProfessions(row, member)
    local available = row:GetWidth() - PROFESSIONS_LEFT - PROFESSIONS_RIGHT
    local list = member.professions
    local x, shown = 0, 0

    for index, profession in ipairs(list) do
        local button = GetProfessionButton(row, index)
        button.text:SetWidth(0) -- 0 = så bred som teksten
        button.text:SetText(("%s %d"):format(profession.name, profession.level))
        local width = math.ceil(button.text:GetStringWidth())
        local reserve = index < #list and MORE_WIDTH or 0
        if index > 1 and x + width + reserve > available then
            break
        end
        if width > available - reserve then
            -- Selv den første er for lang: kutt den.
            width = math.max(10, available - reserve)
            button.text:SetWidth(width)
        end

        button.member, button.profession = member, profession
        button.linked = LinkData(member, profession) ~= nil
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

    -- Lite ikon rett etter navnet når medlemmet har satt en status (quester,
    -- dungeon, crafter / ikke forstyrr). Se Status.lua.
    row.statusIcon = row:CreateTexture(nil, "OVERLAY")
    row.statusIcon:SetSize(14, 14)
    row.statusIcon:Hide()

    row.level = row:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    row.level:SetPoint("LEFT", row.name, "RIGHT", 4, 0)
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

    row.last = row:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    row.last:SetPoint("RIGHT", -6, 0)
    row.last:SetWidth(LAST_WIDTH)
    row.last:SetJustifyH("RIGHT")

    -- Professions: én knapp per profession (lages etter behov), og "+2" når
    -- ikke alle får plass.
    row.buttons = {}
    row.more = row:CreateFontString(nil, "OVERLAY", "GameFontDisable")
    row.more:SetJustifyH("LEFT")

    -- Klikk på raden for å få opp medlemskortet (MemberCard.lua): alt om
    -- medlemmet, med professions, talenter, utstyr og dine egne notater.
    -- Uten kortet kommer menyen med professions, som før.
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

    -- Hold over raden for å se alt om medlemmet.
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
        GameTooltip:AddLine(("%s - %s"):format(L.RO_TIP_LEVEL:format(member.level), member.rank), 1, 1, 1)
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
        -- Et klikk på raden åpner medlemskortet (MemberCard.lua).
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

    -- Les egne professions på nytt hver gang, så din egen rad alltid stemmer.
    StoreMine()
    ReadGameProfessions()

    panel.title:SetText(L.RO_PANEL_TITLE)
    panel.searchLabel:SetText(L.RO_SEARCH)
    panel.mineChip.label:SetText(L.RO_MINE)
    panel.headerName:SetText(L.RO_H_NAME)
    panel.headerLevel:SetText(L.RO_H_LEVEL)
    panel.headerLegacy:SetText(L.RO_H_LEGACY)
    panel.headerRank:SetText(L.RO_H_RANK)
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

    local list, total = Collect()
    for index, member in ipairs(list) do
        local row = GetRow(index)
        local colour = RAID_CLASS_COLORS and RAID_CLASS_COLORS[member.class]
        row.member = member
        row.name:SetText(member.name)
        if colour then
            row.name:SetTextColor(colour.r, colour.g, colour.b)
        else
            row.name:SetTextColor(1, 1, 1)
        end
        -- Status vises bare for dem som er pålogget.
        local statusCode = member.online and DW.StatusOf and DW.StatusOf(member)
        local status = statusCode and DW.STATUS_BY_CODE[statusCode]
        if status then
            row.statusIcon:SetTexture(status.icon)
            row.statusIcon:ClearAllPoints()
            row.statusIcon:SetPoint("LEFT", row.name, "LEFT", math.min(row.name:GetStringWidth(), NAME_WIDTH - 16) + 4, 0)
            row.statusIcon:Show()
        else
            row.statusIcon:Hide()
        end
        row.statusCode = status and statusCode or nil
        row.level:SetText(tostring(member.level))
        local points = DW.LegacyPointsOf and DW.LegacyPointsOf(member)
        row.legacy:SetText(points and tostring(points) or "")
        row.rank:SetText(member.rank)
        LayoutProfessions(row, member)
        row.last:SetText(LastOnlineText(member))
        if member.online then
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
    panel.empty:SetShown(#list == 0)
    panel.count:SetText(L.RO_COUNT:format(#list, total))
end

-- Kalles av hovedvinduet første gang modulen velges.
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

    -- Søkefelt: leter i navn, rank og professions mens du skriver.
    f.searchLabel = f:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    f.searchLabel:SetPoint("TOPLEFT", 14, -80)

    f.searchBox = CreateFrame("EditBox", nil, f, "InputBoxTemplate")
    f.searchBox:SetSize(200, 22)
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

    -- Viser påminnelsen om å åpne professionene dine, med hva som er funnet.
    f.mineChip = DW.CreateChip(f, 140, 24)
    f.mineChip:SetPoint("LEFT", f.searchBox, "RIGHT", 14, 0)
    f.mineChip.label:SetJustifyH("CENTER")
    f.mineChip:SetScript("OnClick", function()
        ShowNotice()
    end)

    f.count = f:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    f.count:SetPoint("TOPRIGHT", -14, -82)

    -- Overskriftene står over hver sin kolonne.
    f.headerName = f:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    f.headerName:SetPoint("TOPLEFT", 14, -108)
    f.headerLevel = f:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    f.headerLevel:SetPoint("TOPLEFT", 150, -108)
    f.headerLegacy = f:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    f.headerLegacy:SetPoint("TOPLEFT", 184, -108)
    f.headerRank = f:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    f.headerRank:SetPoint("TOPLEFT", 226, -108)
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
        -- Be spillet om en fersk medlemsliste. Svaret kommer som en hendelse.
        if C_GuildInfo and C_GuildInfo.GuildRoster then
            C_GuildInfo.GuildRoster()
        end
        RefreshPanel()
    end)

    panel = f
    return f
end

-- Hendelser -------------------------------------------------------------------

-- Medlemslisten oppdateres ofte. Samle opp og tegn på nytt én gang.
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

-- Én gang per økt, litt etter innlogging: fortell guilden hvilke professions
-- karakteren har, og be de andre om å si fra om sine.
local function PlanHello()
    if helloSent or not (C_Timer and C_Timer.After) then
        return
    end
    C_Timer.After(10, function()
        if not helloSent and DW.IsMember() then
            helloSent = true
            Publish(true)
            Send("R")
        end
    end)
end

local publishQueued = false

-- Professions er endret (lært en ny, gått opp i skill, eller sett i
-- håndverksvinduet). Si fra til guilden, men ikke oftere enn hvert minutt.
local function PlanPublish()
    if publishQueued or not helloSent or not (C_Timer and C_Timer.After) then
        return
    end
    publishQueued = true
    C_Timer.After(60, function()
        publishQueued = false
        if DW.IsMember() then
            Publish(false)
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
            -- Håndverksvinduet er åpent: husk hvilken profession det viser.
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

-- Guild-navnet kan komme sent etter innlogging. Si da fra når det er klart.
DW.OnMembershipChanged(function(member)
    if member then
        PlanHello()
    end
end)

DW.OnLanguageChanged(function()
    RefreshPanel()
    RefreshNotice()
end)

-- Noen har endret status: tegn ikonene ved navnene på nytt.
DW.OnStatusChanged(function()
    QueueRefresh()
end)

-- Nye legacy-poeng (Profile.lua): tegn kolonnen på nytt.
DW.OnProfileChanged(function()
    QueueRefresh()
end)

-- For medlemskortet (MemberCard.lua): åpne et medlems profession, og om det går.
-- member er en rad fra listen her (den har professions og det som er delt).
DW.OpenMemberProfession = OpenProfession
function DW.CanOpenMemberProfession(member, profession)
    return LinkData(member, profession) ~= nil
end

-- Feilsøking: hva spillet faktisk oppgir om professions på denne karakteren.
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
    add("spillets guild-oversikt: " .. text(GetNumGuildTradeSkill and select(2, pcall(GetNumGuildTradeSkill))))
end)

-- Modul --------------------------------------------------------------------------

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
        db = saved
    end,

    CreatePanel = function(self, parent)
        return CreatePanel(parent)
    end,
})
