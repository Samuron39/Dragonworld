-- Dragonworld - versjonen som er lagt ut
--
-- RELEASE er versjonen guildmedlemmene har fått, altså den som sist ble lagt
-- ut på GitHub. Den sammenlignes med de andre i guilden (Update.lua), og den
-- som har en eldre, får beskjed om å oppdatere.
--
-- Den skrives av tools\release.ps1 når en ny versjon legges ut. Ikke endre den
-- for hånd: versjonen i Dragonworld.toc kan godt være nyere mens noe er under
-- arbeid og testes i spillet, uten at resten av guilden blir bedt om å
-- oppdatere til noe som ikke finnes ennå.

local ADDON_NAME, DW = ...

DW.RELEASE = "0.18.1"

-- Når RELEASE ble lagt ut (sekunder siden 1970, UTC). Med automatisk
-- oppdatering er den lastet ned noen minutter etter dette. Skrives av release.ps1.
DW.RELEASED_AT = 1795282790

-- Den nyeste versjonen som la til eller fjernet filer eller bilder. Har man en
-- eldre enn denne, holder ikke /reload; spillet må startes helt på nytt.
-- Skrives av release.ps1.
DW.RESTART_RELEASE = "0.17.0"

-- Settes til true av oppdateringsprogrammet (Updater\update.ps1) på PC-er der
-- automatisk oppdatering er slått på. Da vet addonen at nye versjoner lastes
-- ned av seg selv, og ber bare om /reload.
DW.AUTO_UPDATE = false

-- Her henter man siste versjon. Vises i oppdater-vinduet og under Innstillinger.
DW.DOWNLOAD_URL = "https://github.com/Samuron39/Dragonworld/releases/latest"
