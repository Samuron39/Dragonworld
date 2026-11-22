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

DW.RELEASE = "0.24.2"

-- When RELEASE was released (seconds since 1970, UTC). With automatic updates
-- it is downloaded a few minutes after this. Written by release.ps1.
DW.RELEASED_AT = 1795348099

-- The newest version that added or removed files or images. With an older
-- one than this, /reload is not enough; the game must be fully restarted.
-- Written by release.ps1.
DW.RESTART_RELEASE = "0.22.0"

-- What is new in RELEASE: a sentence or two per language. Shown in the update
-- window of those who still have an older version (it travels to them over
-- the guild channel, so each text must stay within 220 bytes), and once in
-- chat after updating. Written by release.ps1 from -News.
DW.RELEASE_NEWS = { en = "Reload now in the update window works from the next update. This time, type /reload.", nb = "Reload nå i oppdateringsvinduet virker fra neste oppdatering. Denne gangen skriver du /reload.", nl = "Nu herladen in het updatevenster werkt vanaf de volgende update. Typ deze keer /reload.", de = "Jetzt neu laden im Update-Fenster funktioniert ab dem nächsten Update. Gib dieses Mal /reload ein.", da = "Reload nu i opdateringsvinduet virker fra næste opdatering. Skriv /reload denne gang.", sv = "Reload nu i uppdateringsfönstret fungerar från nästa uppdatering. Skriv /reload den här gången.", fr = "Recharger dans la fenêtre de mise à jour fonctionne dès la prochaine mise à jour. Cette fois, tape /reload." }

-- Set to true by the updater (Updater\update.ps1) on PCs where automatic
-- updates are turned on. Then the addon knows that new versions download by
-- themselves, and only asks for /reload.
DW.AUTO_UPDATE = false

-- Where to get the latest version. Shown in the update window and under Settings.
DW.DOWNLOAD_URL = "https://github.com/Samuron39/Dragonworld/releases/latest"
