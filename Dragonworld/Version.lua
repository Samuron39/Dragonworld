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

DW.RELEASE = "0.24.1"

-- When RELEASE was released (seconds since 1970, UTC). With automatic updates
-- it is downloaded a few minutes after this. Written by release.ps1.
DW.RELEASED_AT = 1795346394

-- The newest version that added or removed files or images. With an older
-- one than this, /reload is not enough; the game must be fully restarted.
-- Written by release.ps1.
DW.RESTART_RELEASE = "0.22.0"

-- What is new in RELEASE: a sentence or two per language. Shown in the update
-- window of those who still have an older version (it travels to them over
-- the guild channel, so each text must stay within 220 bytes), and once in
-- chat after updating. Written by release.ps1 from -News.
DW.RELEASE_NEWS = { en = "New tabs in the game's Guild & Communities and Legacy windows open Dragonworld's Achievements tab.", nb = "Nye faner i spillets Guild & Communities- og Legacy-vindu åpner Prestasjoner i Dragonworld.", nl = "Nieuwe tabbladen in de vensters Guild & Communities en Legacy van het spel openen Prestaties in Dragonworld.", de = "Neue Tabs im Gilden- und Legacy-Fenster des Spiels öffnen Erfolge in Dragonworld.", da = "Nye faner i spillets Guild & Communities- og Legacy-vindue åbner Præstationer i Dragonworld.", sv = "Nya flikar i spelets Guild & Communities- och Legacy-fönster öppnar Prestationer i Dragonworld.", fr = "De nouveaux onglets dans les fenêtres Guilde et Legacy du jeu ouvrent Hauts faits dans Dragonworld." }

-- Set to true by the updater (Updater\update.ps1) on PCs where automatic
-- updates are turned on. Then the addon knows that new versions download by
-- themselves, and only asks for /reload.
DW.AUTO_UPDATE = false

-- Where to get the latest version. Shown in the update window and under Settings.
DW.DOWNLOAD_URL = "https://github.com/Samuron39/Dragonworld/releases/latest"
