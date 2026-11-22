@echo off
title Dragonworld Installer
rem Installs the guild addon Dragonworld in World of Warcraft Forever.
rem Gets the updater (update.ps1) from the latest release on GitHub, or from
rem main if the release doesn't have it, and runs it; it finds the game itself,
rem gets the latest version and offers a shortcut on the desktop.
rem With Smart App Control on, Windows blocks this file; see README.md.
powershell -NoProfile -ExecutionPolicy Bypass -Command "$f = Join-Path $env:TEMP 'dragonworld-update.ps1'; try { [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor 3072 } catch { }; $ok = $false; foreach ($u in @('https://github.com/Samuron39/Dragonworld/releases/latest/download/update.ps1', 'https://raw.githubusercontent.com/Samuron39/Dragonworld/main/Dragonworld/Updater/update.ps1')) { try { Invoke-WebRequest -UseBasicParsing -Uri $u -OutFile $f; $ok = $true; break } catch { } }; if (-not $ok) { Write-Host 'Could not reach GitHub.' -ForegroundColor Red; Write-Host 'https://github.com/Samuron39/Dragonworld'; [void](Read-Host 'Press Enter to close'); exit 1 }; & $f"
