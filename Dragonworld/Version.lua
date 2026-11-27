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

DW.RELEASE = "0.27.2"

-- When RELEASE was released (seconds since 1970, UTC). With automatic updates
-- it is downloaded a few minutes after this. Written by release.ps1.
DW.RELEASED_AT = 1795811715

-- The newest version that added or removed files or images. With an older
-- one than this, /reload is not enough; the game must be fully restarted.
-- Written by release.ps1.
DW.RESTART_RELEASE = "0.27.0"

-- What is new in RELEASE: a sentence or two per language. Shown in the update
-- window of those who still have an older version (it travels to them over
-- the guild channel, so each text must stay within 220 bytes), and once in
-- chat after updating. Written by release.ps1 from -News.
DW.RELEASE_NEWS = { en = "Home: a green dot before a line means that player is online now, so your Gratz! reaches them. Hover the line to see who, also when they are on another of their characters.", nb = "Hjem: en grønn prikk foran en linje betyr at spilleren er pålogget nå, så Gratz! når fram. Hold musepekeren over linjen for å se hvem, også når de er på en annen av karakterene sine.", nl = "Start: een groene stip voor een regel betekent dat die speler nu online is, dus je Gratz! komt aan. Houd de muis op de regel om te zien wie, ook als die op een ander personage speelt.", de = "Übersicht: Ein grüner Punkt vor einer Zeile zeigt, dass der Spieler gerade online ist, dein Gratz! kommt also an. Mit der Maus über der Zeile siehst du, wer, auch auf einem anderen Charakter.", da = "Hjem: en grøn prik foran en linje betyder, at spilleren er online nu, så dit Gratz! når frem. Hold musen over linjen for at se hvem, også når de er på en anden af deres karakterer.", sv = "Hem: en grön prick framför en rad betyder att spelaren är online nu, så ditt Gratz! når fram. Håll musen över raden för att se vem, även när de är på en annan av sina karaktärer.", fr = "Accueil : un point vert devant une ligne indique que le joueur est en ligne, votre Bravo ! lui parviendra. Survolez la ligne pour voir qui, même s'il joue un autre de ses personnages." }

-- Set to true by the updater (Updater\update.ps1) on PCs where automatic
-- updates are turned on. Then the addon knows that new versions download by
-- themselves, and only asks for /reload.
DW.AUTO_UPDATE = false

-- Where to get the latest version. Shown in the update window and under Settings.
DW.DOWNLOAD_URL = "https://github.com/Samuron39/Dragonworld/releases/latest"
