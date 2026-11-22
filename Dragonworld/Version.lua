-- Dragonworld - the released version
--
-- RELEASE is the version the guild members have received, that is, the one
-- last released on GitHub. It is compared with everyone else's in the guild
-- (Update.lua), and whoever has an older one is told to update.
--
-- It is written by tools\release.ps1 when a new version is released. Don't
-- change it by hand: the version in Dragonworld.toc may well be newer while
-- something is being worked on and tested in the game, without the rest of
-- the guild being asked to update to something that doesn't exist yet.

local ADDON_NAME, DW = ...

DW.RELEASE = "0.25.1"

-- When RELEASE was released (seconds since 1970, UTC). With automatic updates
-- it is downloaded a few minutes after this. Written by release.ps1.
DW.RELEASED_AT = 1795350373

-- The newest version that added or removed files or images. With an older
-- one than this, /reload is not enough; the game must be fully restarted.
-- Written by release.ps1.
DW.RESTART_RELEASE = "0.22.0"

-- What is new in RELEASE: a sentence or two per language. Shown in the update
-- window of those who still have an older version (it travels to them over
-- the guild channel, so each text must stay within 220 bytes), and once in
-- chat after updating. Written by release.ps1 from -News.
DW.RELEASE_NEWS = { en = "The welcome guide now tells you to log in and open the bank once on every character, alts outside the guild too, so Materials counts their items and gold.", nb = "Velkomstguiden ber deg nå logge inn og åpne banken én gang på hver karakter, også alter utenfor guilden, så Materialer teller tingene og gullet deres.", nl = "De welkomstgids vraagt je nu om op elk personage in te loggen en de bank te openen, ook alts buiten de guild, zodat Materialen hun spullen en goud telt.", de = "Die Einführung sagt jetzt, dass du dich auf jedem Charakter einloggen und die Bank öffnen sollst, auch bei Twinks, damit Materialien ihre Sachen und ihr Gold zählt.", da = "Velkomstguiden beder dig nu logge ind og åbne banken én gang på hver karakter, også alts uden for guilden, så Materialer tæller deres ting og guld.", sv = "Välkomstguiden ber dig nu logga in och öppna banken en gång på varje karaktär, även alts utanför guilden, så att Material räknar deras saker och guld.", fr = "Le guide de bienvenue te dit maintenant de te connecter et d'ouvrir la banque sur chaque personnage, rerolls compris, pour que Matériaux compte leurs objets et leur or." }

-- Set to true by the updater (Updater\update.ps1) on PCs where automatic
-- updates are turned on. Then the addon knows that new versions download by
-- themselves, and only asks for /reload.
DW.AUTO_UPDATE = false

-- Where to get the latest version. Shown in the update window and under Settings.
DW.DOWNLOAD_URL = "https://github.com/Samuron39/Dragonworld/releases/latest"
