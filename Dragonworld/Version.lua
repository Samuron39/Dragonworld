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

DW.RELEASE = "0.25.0"

-- When RELEASE was released (seconds since 1970, UTC). With automatic updates
-- it is downloaded a few minutes after this. Written by release.ps1.
DW.RELEASED_AT = 1795350035

-- The newest version that added or removed files or images. With an older
-- one than this, /reload is not enough; the game must be fully restarted.
-- Written by release.ps1.
DW.RESTART_RELEASE = "0.22.0"

-- What is new in RELEASE: a sentence or two per language. Shown in the update
-- window of those who still have an older version (it travels to them over
-- the guild channel, so each text must stay within 220 bytes), and once in
-- chat after updating. Written by release.ps1 from -News.
DW.RELEASE_NEWS = { en = "Alts outside the guild now get the personal tabs when another of your characters is in it. Materials has a new Everything button: all items in bags and bank, and the gold on each character.", nb = "Alter utenfor guilden får nå de personlige fanene når en annen karakter av deg er med. Materialer har fått knappen Alt: alt i bagger og bank, og gullet på hver karakter.", nl = "Alts buiten de guild krijgen nu de persoonlijke tabbladen als een ander personage van je erin zit. Materialen heeft een knop Alles: alles in tassen en bank, en het goud per personage.", de = "Twinks außerhalb der Gilde haben jetzt die persönlichen Reiter, wenn ein anderer Charakter von dir drin ist. Materialien hat den Knopf Alles: alles in Taschen und Bank, und das Gold pro Charakter.", da = "Alts uden for guilden får nu de personlige faner, når en anden af dine karakterer er med. Materialer har fået knappen Alt: alt i tasker og bank, og guldet på hver karakter.", sv = "Alts utanför guilden får nu de personliga flikarna när en annan av dina karaktärer är med. Material har fått knappen Allt: allt i väskor och bank, och guldet på varje karaktär.", fr = "Tes rerolls hors guilde ont les onglets personnels si un de tes personnages est dans la guilde. Matériaux a un bouton Tout : tout dans les sacs et la banque, et l'or de chaque personnage." }

-- Set to true by the updater (Updater\update.ps1) on PCs where automatic
-- updates are turned on. Then the addon knows that new versions download by
-- themselves, and only asks for /reload.
DW.AUTO_UPDATE = false

-- Where to get the latest version. Shown in the update window and under Settings.
DW.DOWNLOAD_URL = "https://github.com/Samuron39/Dragonworld/releases/latest"
