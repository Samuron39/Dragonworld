@echo off
title Dragonworld Updater
rem Gets the latest version of Dragonworld from GitHub (see update.ps1). All on one
rem line, so the file can be replaced while it runs.
pushd "%TEMP%" & powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0update.ps1" & popd & exit /b
