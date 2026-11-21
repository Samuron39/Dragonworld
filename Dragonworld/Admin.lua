-- Dragonworld - admin
--
-- Guildlederen kan logge inn som admin med en kode, og får da flere
-- rettigheter: i Forslag kan admin merke forslag som utført eller avvist, så
-- de flyttes til arkivet (Modules\Forslag.lua). Innloggingen huskes på kontoen
-- (DragonworldDB.admin) til man logger ut.
--
-- Koden står ikke i addonen, bare et fingeravtrykk av den (SHA-256 med salt,
-- 100 runder). Addonen ligger åpent på GitHub, så koden selv skal ikke stå her.
-- Dette er en enkel sperre, ikke ekte sikkerhet: den som vil, kan endre filene
-- i sin egen addon, og de andre i guilden kan ikke sjekke hvem som er admin.
--
-- Ny kode: regn ut fingeravtrykket med DW.AdminHash("ny kode") (f.eks. med
-- /run print(DragonworldAdminHash("ny kode")) i spillet) og bytt ADMIN_HASH.

local ADDON_NAME, DW = ...
local L = DW.L

local ADMIN_HASH = "0a032bcf1282b6b43dedf77d6cbc5cd3766687d32885352353c559058b4278e3"
local SALT = "Dragonworld-admin:"
local ROUNDS = 100

-- SHA-256 -----------------------------------------------------------------------
-- Skrevet for spillets Lua 5.1 med bit-biblioteket. Alle tall holdes som
-- 32-bits tall uten fortegn (0 til 2^32 - 1).

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

-- Fingeravtrykket av en tekst, som 64 heksadesimale tegn.
local function Sha256(message)
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
DW.Sha256 = Sha256

-- Fingeravtrykket av en admin-kode, slik det står i ADMIN_HASH.
function DW.AdminHash(code)
    local hash = Sha256(SALT .. tostring(code))
    for _ = 2, ROUNDS do
        hash = Sha256(hash .. SALT)
    end
    return hash
end
DragonworldAdminHash = DW.AdminHash -- så det kan brukes med /run i spillet

-- Innlogging ----------------------------------------------------------------------

local listeners = {}

function DW.OnAdminChanged(callback)
    listeners[#listeners + 1] = callback
end

local function Changed()
    for _, callback in ipairs(listeners) do
        local ok, problem = pcall(callback)
        if not ok then
            DW.PrintError(L.ERROR, problem)
        end
    end
end

function DW.IsAdmin()
    return type(DragonworldDB) == "table" and type(DragonworldDB.admin) == "table" and DragonworldDB.admin.on == true
end

-- Prøver en kode. Returnerer true hvis den er riktig.
function DW.AdminLogin(code)
    if type(code) ~= "string" or code == "" or type(DragonworldDB) ~= "table" then
        return false
    end
    if DW.AdminHash(code) ~= (DW.ADMIN_HASH or ADMIN_HASH) then
        return false
    end
    DragonworldDB.admin = { on = true }
    DW.Print(L.ADM_IN)
    Changed()
    return true
end

function DW.AdminLogout()
    if type(DragonworldDB) == "table" then
        DragonworldDB.admin = nil
    end
    DW.Print(L.ADM_OUT)
    Changed()
end

-- Vinduet -------------------------------------------------------------------------

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
    table.insert(UISpecialFrames, "DragonworldAdminLogin") -- Escape lukker

    f.title = f:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
    f.title:SetPoint("TOP", 0, -16)

    f.text = f:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    f.text:SetPoint("TOPLEFT", 20, -42)
    f.text:SetPoint("RIGHT", -20, 0)
    f.text:SetJustifyH("LEFT")

    -- Koden vises som prikker.
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

-- Viser innloggingen.
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

DW.AddDebug("admin", function(add)
    add("admin: " .. DW.DebugText(DW.IsAdmin()))
end)
