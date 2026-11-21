@echo off
title Dragonworld Installer
rem Installerer guild-addonen Dragonworld i World of Warcraft Forever.
rem Henter oppdateringsprogrammet fra GitHub og kjorer det; det finner spillet
rem selv, henter siste versjon og tilbyr en snarvei pa skrivebordet.
powershell -NoProfile -ExecutionPolicy Bypass -Command "$f = Join-Path $env:TEMP 'dragonworld-update.ps1'; try { [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor 3072; Invoke-WebRequest -UseBasicParsing -Uri 'https://raw.githubusercontent.com/Samuron39/Dragonworld/main/Dragonworld/Updater/update.ps1' -OutFile $f } catch { Write-Host ('Could not reach GitHub: ' + $_.Exception.Message) -ForegroundColor Red; Write-Host 'https://github.com/Samuron39/Dragonworld'; [void](Read-Host 'Press Enter to close'); exit 1 }; & $f"
