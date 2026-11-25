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

DW.RELEASE = "0.27.0"

-- When RELEASE was released (seconds since 1970, UTC). With automatic updates
-- it is downloaded a few minutes after this. Written by release.ps1.
DW.RELEASED_AT = 1795643232

-- The newest version that added or removed files or images. With an older
-- one than this, /reload is not enough; the game must be fully restarted.
-- Written by release.ps1.
DW.RESTART_RELEASE = "0.27.0"

-- What is new in RELEASE: a sentence or two per language. Shown in the update
-- window of those who still have an older version (it travels to them over
-- the guild channel, so each text must stay within 220 bytes), and once in
-- chat after updating. Written by release.ps1 from -News.
DW.RELEASE_NEWS = { en = "New tab Tactics: draw a boss fight on a board with markers, arrows and text, and show it to your group, scene by scene. Our buttons in the game's own windows now open just that tab, next to the window.", nb = "Ny tab Taktikk: tegn en bosskamp på en tavle med markører, piler og tekst, og vis den til gruppen din, scene for scene. Knappene våre i spillets egne vinduer åpner nå bare den ene taben, ved siden av vinduet.", nl = "Nieuwe tab Tactiek: teken een bossgevecht op een bord met markeringen, pijlen en tekst, en laat het je groep zien, scène voor scène. Onze knoppen in de vensters van het spel openen nu alleen die tab, naast het venster.", de = "Neuer Tab Taktik: Zeichne einen Bosskampf mit Markierungen, Pfeilen und Text auf eine Tafel und zeige ihn deiner Gruppe, Szene für Szene. Unsere Buttons in den Spielfenstern öffnen nun nur diesen Tab neben dem Fenster.", da = "Ny tab Taktik: tegn en bosskamp på en tavle med markører, pile og tekst, og vis den til din gruppe, scene for scene. Vores knapper i spillets egne vinduer åbner nu kun den ene tab, ved siden af vinduet.", sv = "Ny tab Taktik: rita en bosstrid på en tavla med markörer, pilar och text, och visa den för din grupp, scen för scen. Våra knappar i spelets egna fönster öppnar nu bara den ena tabben, bredvid fönstret.", fr = "Nouvel onglet Tactiques : dessine un combat de boss avec marqueurs, flèches et texte, et montre-le à ton groupe, scène par scène. Nos boutons dans les fenêtres du jeu n'ouvrent plus que cet onglet, juste à côté." }

-- Set to true by the updater (Updater\update.ps1) on PCs where automatic
-- updates are turned on. Then the addon knows that new versions download by
-- themselves, and only asks for /reload.
DW.AUTO_UPDATE = false

-- Where to get the latest version. Shown in the update window and under Settings.
DW.DOWNLOAD_URL = "https://github.com/Samuron39/Dragonworld/releases/latest"
