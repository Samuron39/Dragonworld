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

DW.RELEASE = "0.15.0"

-- Her henter man siste versjon. Vises i oppdater-vinduet og under Innstillinger.
DW.DOWNLOAD_URL = "https://github.com/Samuron39/Dragonworld/releases/latest"
