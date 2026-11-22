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

DW.RELEASE = "0.24.0"

-- When RELEASE was released (seconds since 1970, UTC). With automatic updates
-- it is downloaded a few minutes after this. Written by release.ps1.
DW.RELEASED_AT = 1795343467

-- The newest version that added or removed files or images. With an older
-- one than this, /reload is not enough; the game must be fully restarted.
-- Written by release.ps1.
DW.RESTART_RELEASE = "0.22.0"

-- What is new in RELEASE: a sentence or two per language. Shown in the update
-- window of those who still have an older version (it travels to them over
-- the guild channel, so each text must stay within 220 bytes), and once in
-- chat after updating. Written by release.ps1 from -News.
DW.RELEASE_NEWS = { en = "Dragonworld now also comes in German, Danish, Swedish and French (choose under Settings). The update window now says what is new. Installing also works on PCs with Smart App Control.", nb = "Dragonworld finnes nå også på tysk, dansk, svensk og fransk (velg under Innstillinger). Oppdateringsvinduet sier nå hva som er nytt. Installering virker også på PC-er med Smart App Control.", nl = "Dragonworld is er nu ook in het Duits, Deens, Zweeds en Frans (kies bij Instellingen). Het updatevenster zegt nu wat er nieuw is. Installeren werkt ook op pc's met Smart App Control.", de = "Dragonworld gibt es jetzt auch auf Deutsch, Dänisch, Schwedisch und Französisch (unter Einstellungen). Das Update-Fenster zeigt, was neu ist. Installieren klappt auch mit Smart App Control.", da = "Dragonworld findes nu også på tysk, dansk, svensk og fransk (vælg under Indstillinger). Opdateringsvinduet viser, hvad der er nyt. Installation virker også med Smart App Control.", sv = "Dragonworld finns nu även på tyska, danska, svenska och franska (välj under Inställningar). Uppdateringsfönstret visar vad som är nytt. Installation fungerar även med Smart App Control.", fr = "Dragonworld existe aussi en allemand, danois, suédois et français (dans Options). La fenêtre de mise à jour indique les nouveautés. L'installation marche aussi avec Smart App Control." }

-- Set to true by the updater (Updater\update.ps1) on PCs where automatic
-- updates are turned on. Then the addon knows that new versions download by
-- themselves, and only asks for /reload.
DW.AUTO_UPDATE = false

-- Where to get the latest version. Shown in the update window and under Settings.
DW.DOWNLOAD_URL = "https://github.com/Samuron39/Dragonworld/releases/latest"
