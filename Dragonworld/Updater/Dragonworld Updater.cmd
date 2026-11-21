@echo off
title Dragonworld Updater
rem Henter siste versjon av Dragonworld fra GitHub (se update.ps1). Alt pa en linje,
rem sa filen kan byttes ut mens den kjorer.
pushd "%TEMP%" & powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0update.ps1" & popd & exit /b
