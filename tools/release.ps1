# Legger ut en ny versjon av Dragonworld til guilden.
#
#   pwsh tools\release.ps1 [-Notes "hva som er nytt"] [-NoInstall]
#
# (Notater som begynner med "-" må gis fra PowerShell: & tools\release.ps1 -Notes $notes)
#
# Gjør alt i én operasjon, i denne rekkefølgen:
#   1. Versjonen er den i Dragonworld.toc. Er den alt lagt ut (taggen finnes),
#      økes siste tall med én (0.15.0 -> 0.15.1) og skrives tilbake i .toc.
#   2. Kjører testene (node tests\run.js Dragonworld). Feiler de, stopper alt.
#   3. Skriver versjonen i Dragonworld\Version.lua (DW.RELEASE). Det er den
#      addonene sammenligner i spillet; først nå får guilden beskjed om den.
#      Skriver også når den ble lagt ut (DW.RELEASED_AT), og hvis den har nye
#      eller fjernede filer eller bilder siden forrige versjon, at den krever
#      omstart av spillet (DW.RESTART_RELEASE). Ellers holder /reload.
#   4. Committer alt, lager taggen vX.Y.Z og pusher til GitHub.
#   5. Lager Dragonworld.zip (mappen Dragonworld fra taggen, pluss
#      Installer-Dragonworld.cmd øverst) og en GitHub release med zip-en og
#      installeringsfilen. Oppdateringsprogrammet henter alltid siste release.
#   6. Kopierer addonen inn i spillet (med mindre -NoInstall).
#
# Versjoner som bare testes i spillet underveis trenger ikke dette: de har
# fortsatt forrige DW.RELEASE, så ingen i guilden blir bedt om å oppdatere.

param(
    [string]$Notes = '',
    [switch]$NoInstall
)

$ErrorActionPreference = 'Stop'
$Root = Split-Path -Parent $PSScriptRoot
$Addon = Join-Path $Root 'Dragonworld'
$Toc = Join-Path $Addon 'Dragonworld.toc'
$VersionFile = Join-Path $Addon 'Version.lua'
$Dist = Join-Path $Root 'dist'
$Game = 'D:\wow\World of Warcraft\_forever_\Interface\AddOns\Dragonworld'
$CoAuthor = 'Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>'

function Step([string]$text) { Write-Host "==> $text" -ForegroundColor Cyan }

# Kjører et program og stopper hvis det feiler.
function Invoke-Checked([string]$exe, [string[]]$arguments) {
    & $exe @arguments
    if ($LASTEXITCODE -ne 0) { throw "$exe $($arguments -join ' ') feilet (kode $LASTEXITCODE)" }
}

function Read-Utf8([string]$path) { [System.IO.File]::ReadAllText($path, [System.Text.UTF8Encoding]::new($false)) }
function Write-Utf8([string]$path, [string]$text) { [System.IO.File]::WriteAllText($path, $text, [System.Text.UTF8Encoding]::new($false)) }

Push-Location $Root
try {
    git remote get-url origin *> $null
    if ($LASTEXITCODE -ne 0) { throw 'Repoet har ingen remote "origin". Opprett GitHub-repoet først.' }

    # 1. Versjonen.
    $tocText = Read-Utf8 $Toc
    if ($tocText -notmatch '(?m)^## Version:\s*(\d+)\.(\d+)\.(\d+)\s*$') { throw 'Fant ikke "## Version: X.Y.Z" i Dragonworld.toc' }
    $major, $minor, $patch = [int]$Matches[1], [int]$Matches[2], [int]$Matches[3]
    Invoke-Checked git @('fetch', '--tags', '--quiet', 'origin')
    while ($true) {
        $version = "$major.$minor.$patch"
        git rev-parse -q --verify "refs/tags/v$version" *> $null
        if ($LASTEXITCODE -ne 0) { break }
        $patch++
    }
    if ($tocText -notmatch "(?m)^## Version:\s*$([regex]::Escape($version))\s*$") {
        Step "v$major.$minor.$($patch - 1) er alt lagt ut; bruker $version"
        $tocText = [regex]::Replace($tocText, '(?m)^## Version:.*$', "## Version: $version")
        Write-Utf8 $Toc $tocText
    }
    Step "Legger ut Dragonworld $version"

    # 2. Testene.
    Step 'Kjører testene'
    Invoke-Checked node @('tests/run.js', 'Dragonworld')

    # 3. Versjonen guilden sammenligner med, når den ble lagt ut, og om den
    #    krever at spillet startes på nytt: /reload leser bare filene som
    #    fantes da spillet startet, så nye eller fjernede filer, endrede
    #    bilder eller en ny fil-liste i .toc krever omstart.
    Invoke-Checked git @('add', '-A')
    $previous = git tag --list 'v*' --sort=-v:refname | Select-Object -First 1
    $restart = $true
    if ($previous) {
        $restart = $false
        foreach ($line in (git diff --cached --name-status $previous -- Dragonworld)) {
            $status, $path = $line -split "`t", 2
            if ($path -like 'Dragonworld/Updater/*') { continue }
            if ($status -notmatch '^M' -or $path -like 'Dragonworld/Media/*') {
                $restart = $true
            } elseif ($path -eq 'Dragonworld/Dragonworld.toc') {
                $files = { $input | ForEach-Object { $_.Trim() } | Where-Object { $_ -and -not $_.StartsWith('#') } }
                $before = (git show "${previous}:Dragonworld/Dragonworld.toc" | & $files) -join '|'
                $after = (Get-Content -LiteralPath $Toc | & $files) -join '|'
                if ($before -ne $after) { $restart = $true }
            }
        }
    }
    Step ($(if ($restart) { 'Krever omstart av spillet (nye filer)' } else { '/reload holder' }))
    $versionText = Read-Utf8 $VersionFile
    $versionText = [regex]::Replace($versionText, 'DW\.RELEASE\s*=\s*"[^"]*"', "DW.RELEASE = `"$version`"")
    $versionText = [regex]::Replace($versionText, 'DW\.RELEASED_AT\s*=\s*\d+', "DW.RELEASED_AT = $([DateTimeOffset]::UtcNow.ToUnixTimeSeconds())")
    $versionText = [regex]::Replace($versionText, 'DW\.AUTO_UPDATE\s*=\s*(true|false)', 'DW.AUTO_UPDATE = false')
    if ($restart) {
        $versionText = [regex]::Replace($versionText, 'DW\.RESTART_RELEASE\s*=\s*"[^"]*"', "DW.RESTART_RELEASE = `"$version`"")
    }
    Write-Utf8 $VersionFile $versionText

    # 4. Commit, tag, push.
    Step 'Committer og pusher'
    Invoke-Checked git @('add', '-A')
    git diff --cached --quiet
    if ($LASTEXITCODE -ne 0) {
        Invoke-Checked git @('commit', '--quiet', '-m', "Dragonworld $version", '-m', $CoAuthor)
    }
    Invoke-Checked git @('tag', '-a', "v$version", '-m', "Dragonworld $version")
    Invoke-Checked git @('push', '--quiet', 'origin', 'HEAD')
    Invoke-Checked git @('push', '--quiet', 'origin', "v$version")

    # 5. Zip og release.
    Step 'Lager release på GitHub'
    New-Item -ItemType Directory -Force -Path $Dist | Out-Null
    $zip = Join-Path $Dist 'Dragonworld.zip'
    if (Test-Path -LiteralPath $zip) { Remove-Item -LiteralPath $zip -Force }
    # Zip-en har mappen Dragonworld og installeringsfilen øverst, så den som
    # får zip-en (f.eks. på Discord) bare åpner den og dobbeltklikker filen.
    Invoke-Checked git @('archive', '--format=zip', '-o', $zip, '--prefix=', '--add-file=Installer-Dragonworld.cmd',
        '--prefix=Dragonworld/', "v${version}:Dragonworld")
    $installer = Join-Path $Root 'Installer-Dragonworld.cmd'
    # Installeringsfilen henter oppdateringsprogrammet herfra (GitHubs kopi av
    # main kan henge noen minutter etter etter en push).
    $updater = Join-Path $Addon 'Updater\update.ps1'
    if (-not $Notes) { $Notes = "Dragonworld $version" }
    $Notes += "`n`nFirst time: download Installer-Dragonworld.cmd (or Dragonworld.zip) and double-click Installer-Dragonworld.cmd. In game, the addon tells you when a newer version is out; then double-click Dragonworld Updater on your desktop."
    Invoke-Checked gh @('release', 'create', "v$version", $zip, $installer, $updater, '--title', "Dragonworld $version", '--notes', $Notes)

    # 6. Inn i spillet.
    if (-not $NoInstall -and (Test-Path -LiteralPath (Split-Path -Parent $Game))) {
        Step "Installerer i $Game"
        New-Item -ItemType Directory -Force -Path $Game | Out-Null
        Get-ChildItem -LiteralPath $Addon -Recurse -File | ForEach-Object {
            $relative = $_.FullName.Substring($Addon.Length).TrimStart('\')
            $destination = Join-Path $Game $relative
            New-Item -ItemType Directory -Force -Path (Split-Path -Parent $destination) | Out-Null
            Copy-Item -LiteralPath $_.FullName -Destination $destination -Force
        }
        Get-ChildItem -LiteralPath $Game -Recurse -File | ForEach-Object {
            $relative = $_.FullName.Substring($Game.Length).TrimStart('\')
            if (-not (Test-Path -LiteralPath (Join-Path $Addon $relative))) { Remove-Item -LiteralPath $_.FullName -Force }
        }
    }

    $url = (gh release view "v$version" --json url --jq .url)
    Write-Host ''
    Write-Host "Dragonworld $version er lagt ut: $url" -ForegroundColor Green
} finally {
    Pop-Location
}
