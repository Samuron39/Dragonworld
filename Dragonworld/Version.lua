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

DW.RELEASE = "0.27.1"

-- When RELEASE was released (seconds since 1970, UTC). With automatic updates
-- it is downloaded a few minutes after this. Written by release.ps1.
DW.RELEASED_AT = 1795647809

-- The newest version that added or removed files or images. With an older
-- one than this, /reload is not enough; the game must be fully restarted.
-- Written by release.ps1.
DW.RESTART_RELEASE = "0.27.0"

-- What is new in RELEASE: a sentence or two per language. Shown in the update
-- window of those who still have an older version (it travels to them over
-- the guild channel, so each text must stay within 220 bytes), and once in
-- chat after updating. Written by release.ps1 from -News.
DW.RELEASE_NEWS = { en = "Tidy Bag no longer calls a quest item safe to discard when its quest uses a shorter name for it, and quest items with a time limit are always kept.", nb = "Ryddesekk sier ikke lenger at en quest-gjenstand kan kastes når questen bruker et kortere navn på den, og quest-gjenstander med tidsfrist beholdes alltid.", nl = "Opruimtas zegt niet meer dat een quest-voorwerp weg kan als de quest er een kortere naam voor gebruikt, en quest-voorwerpen met een tijdslimiet worden altijd bewaard.", de = "Taschenputz hält einen Questgegenstand nicht mehr für wegwerfbar, wenn die Quest ihn kürzer nennt, und Questgegenstände mit Zeitlimit werden immer behalten.", da = "Oprydning siger ikke længere, at en quest-genstand kan smides ud, når questen bruger et kortere navn for den, og quest-genstande med tidsfrist beholdes altid.", sv = "Städsäck säger inte längre att ett questföremål kan kastas när questen använder ett kortare namn på det, och questföremål med tidsgräns behålls alltid.", fr = "Vide-sac ne dit plus qu'un objet de quête est à jeter quand la quête lui donne un nom plus court, et les objets de quête à durée limitée sont toujours gardés." }

-- Set to true by the updater (Updater\update.ps1) on PCs where automatic
-- updates are turned on. Then the addon knows that new versions download by
-- themselves, and only asks for /reload.
DW.AUTO_UPDATE = false

-- Where to get the latest version. Shown in the update window and under Settings.
DW.DOWNLOAD_URL = "https://github.com/Samuron39/Dragonworld/releases/latest"
