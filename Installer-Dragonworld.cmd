@echo off
title Dragonworld Installer
rem Installerer guild-addonen Dragonworld i World of Warcraft Forever.
rem Henter oppdateringsprogrammet (update.ps1) fra siste release pa GitHub, eller
rem fra main hvis releasen ikke har det, og kjorer det; det finner spillet selv,
rem henter siste versjon og tilbyr en snarvei pa skrivebordet.
powershell -NoProfile -ExecutionPolicy Bypass -Command "$f = Join-Path $env:TEMP 'dragonworld-update.ps1'; [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor 3072; $ok = $false; foreach ($u in @('https://github.com/Samuron39/Dragonworld/releases/latest/download/update.ps1', 'https://raw.githubusercontent.com/Samuron39/Dragonworld/main/Dragonworld/Updater/update.ps1')) { try { Invoke-WebRequest -UseBasicParsing -Uri $u -OutFile $f; $ok = $true; break } catch { } }; if (-not $ok) { Write-Host 'Could not reach GitHub.' -ForegroundColor Red; Write-Host 'https://github.com/Samuron39/Dragonworld'; [void](Read-Host 'Press Enter to close'); exit 1 }; & $f"
