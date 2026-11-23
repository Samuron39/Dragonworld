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

DW.RELEASE = "0.26.0"

-- When RELEASE was released (seconds since 1970, UTC). With automatic updates
-- it is downloaded a few minutes after this. Written by release.ps1.
DW.RELEASED_AT = 1795466428

-- The newest version that added or removed files or images. With an older
-- one than this, /reload is not enough; the game must be fully restarted.
-- Written by release.ps1.
DW.RESTART_RELEASE = "0.26.0"

-- What is new in RELEASE: a sentence or two per language. Shown in the update
-- window of those who still have an older version (it travels to them over
-- the guild channel, so each text must stay within 220 bytes), and once in
-- chat after updating. Written by release.ps1 from -News.
DW.RELEASE_NEWS = { en = "Big update: new Home and Quest together tabs, Announcements, Polls, roles and reminders in Guild Events, Lead a group in Dungeons, Who can craft it?, a welcome banner and GUILD FIRST!", nb = "Stor oppdatering: nye tabs Hjem og Quest sammen, Kunngjøringer, Avstemninger, roller og påminnelser i Guild-events, Led en gruppe i Dungeons, Hvem kan lage det?, velkomst og FØRST I GUILDEN!", nl = "Grote update: nieuwe tabs Start en Samen questen, Mededelingen, Peilingen, rollen en herinneringen in Guild-events, Groep leiden in Dungeons, Wie kan het maken?, welkomstbanner en EERSTE IN DE GUILD!", de = "Großes Update: neue Tabs Übersicht und Gemeinsam questen, Ankündigungen, Umfragen, Rollen und Erinnerungen in Gilden-Events, Gruppe leiten, Wer kann es herstellen? und ERSTER SIEG DER GILDE!", da = "Stor opdatering: nye tabs Hjem og Quest sammen, Meddelelser, Afstemninger, roller og påmindelser i Guild-events, Led en gruppe i Dungeons, Hvem kan lave det?, velkomst og FØRST I GUILDEN!", sv = "Stor uppdatering: nya tabs Hem och Questa tillsammans, Meddelanden, Omröstningar, roller och påminnelser i Guild-events, Led en grupp i Dungeons, Vem kan tillverka det? och FÖRST I GUILDEN!", fr = "Grosse mise à jour : onglets Accueil et Quêtes ensemble, Annonces, Sondages, rôles et rappels dans Événements, Mener un groupe, Qui peut le fabriquer ? et PREMIER DE LA GUILDE !" }

-- Set to true by the updater (Updater\update.ps1) on PCs where automatic
-- updates are turned on. Then the addon knows that new versions download by
-- themselves, and only asks for /reload.
DW.AUTO_UPDATE = false

-- Where to get the latest version. Shown in the update window and under Settings.
DW.DOWNLOAD_URL = "https://github.com/Samuron39/Dragonworld/releases/latest"
