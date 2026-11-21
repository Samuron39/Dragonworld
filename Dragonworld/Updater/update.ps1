# Dragonworld Updater
#
# Henter siste versjon av guild-addonen Dragonworld fra GitHub og legger den i
# AddOns-mappen til World of Warcraft Forever. Startes med "Dragonworld
# Updater.cmd" (ved siden av denne filen) eller snarveien på skrivebordet.
#
#   * Ligger skriptet i ...\Interface\AddOns\Dragonworld\Updater, oppdateres
#     den mappen. Ellers letes det etter WoW Forever, og spør om mappen hvis
#     den ikke finnes.
#   * Har du alt siste versjon, skjer ingenting.
#   * Lagrede innstillinger (WTF-mappen) røres ikke.
#   * Første gang tilbys en snarvei "Dragonworld Updater" på skrivebordet.
#
# Skrevet for Windows PowerShell 5.1, som følger med Windows.

param(
    [switch]$NoPause,
    [string]$AddOns,   # bruk denne AddOns-mappen i stedet for å lete
    [string]$FromZip   # bruk denne zip-filen i stedet for å laste ned (til testing)
)

$ErrorActionPreference = 'Stop'
$Repo = 'Samuron39/Dragonworld'
$ZipUrl = "https://github.com/$Repo/releases/latest/download/Dragonworld.zip"
$PageUrl = "https://github.com/$Repo/releases/latest"

# Tekst på språket Windows bruker: norsk, nederlandsk, ellers engelsk.
$Texts = @{
    en = @{
        Looking      = 'Looking for World of Warcraft Forever...'
        Pick         = 'Choose the _forever_ folder of World of Warcraft (for example C:\Program Files (x86)\World of Warcraft\_forever_)'
        NotFound     = 'World of Warcraft Forever was not found.'
        Folder       = 'AddOns folder: {0}'
        Downloading  = 'Downloading the newest version...'
        Same         = 'You already have the newest version ({0}).'
        Updated      = 'Dragonworld is updated from {0} to {1}.'
        Installed    = 'Dragonworld {0} is installed.'
        Restart      = 'Restart the game to use it.'
        Failed       = 'Something went wrong: {0}'
        Manual       = 'You can download the addon yourself here: {0}'
        Shortcut     = 'Put a shortcut "Dragonworld Updater" on the desktop? (Y/N)'
        ShortcutMade = 'The shortcut is on the desktop. Double-click it whenever the game says Dragonworld needs an update.'
        Close        = 'Press Enter to close.'
    }
    nb = @{
        Looking      = 'Leter etter World of Warcraft Forever...'
        Pick         = 'Velg mappen _forever_ i World of Warcraft (for eksempel C:\Program Files (x86)\World of Warcraft\_forever_)'
        NotFound     = 'Fant ikke World of Warcraft Forever.'
        Folder       = 'AddOns-mappe: {0}'
        Downloading  = 'Laster ned siste versjon...'
        Same         = 'Du har allerede siste versjon ({0}).'
        Updated      = 'Dragonworld er oppdatert fra {0} til {1}.'
        Installed    = 'Dragonworld {0} er installert.'
        Restart      = 'Start spillet på nytt for å bruke den.'
        Failed       = 'Noe gikk galt: {0}'
        Manual       = 'Du kan laste ned addonen selv her: {0}'
        Shortcut     = 'Lage en snarvei "Dragonworld Updater" på skrivebordet? (J/N)'
        ShortcutMade = 'Snarveien ligger på skrivebordet. Dobbeltklikk den når spillet sier at Dragonworld må oppdateres.'
        Close        = 'Trykk Enter for å lukke.'
    }
    nl = @{
        Looking      = 'Zoeken naar World of Warcraft Forever...'
        Pick         = 'Kies de map _forever_ van World of Warcraft (bijvoorbeeld C:\Program Files (x86)\World of Warcraft\_forever_)'
        NotFound     = 'World of Warcraft Forever is niet gevonden.'
        Folder       = 'AddOns-map: {0}'
        Downloading  = 'De nieuwste versie wordt gedownload...'
        Same         = 'Je hebt al de nieuwste versie ({0}).'
        Updated      = 'Dragonworld is bijgewerkt van {0} naar {1}.'
        Installed    = 'Dragonworld {0} is geïnstalleerd.'
        Restart      = 'Start het spel opnieuw om hem te gebruiken.'
        Failed       = 'Er ging iets mis: {0}'
        Manual       = 'Je kunt de addon zelf downloaden: {0}'
        Shortcut     = 'Een snelkoppeling "Dragonworld Updater" op het bureaublad zetten? (J/N)'
        ShortcutMade = 'De snelkoppeling staat op het bureaublad. Dubbelklik erop als het spel zegt dat Dragonworld bijgewerkt moet worden.'
        Close        = 'Druk op Enter om te sluiten.'
    }
}
$language = (Get-UICulture).TwoLetterISOLanguageName
if ($language -in @('nb', 'nn', 'no')) { $language = 'nb' }
if (-not $Texts.ContainsKey($language)) { $language = 'en' }
$T = $Texts[$language]

function Say([string]$text, [string]$color = 'Gray') {
    Write-Host $text -ForegroundColor $color
}

# Versjonen i en Dragonworld-mappe: den som er lagt ut (Version.lua), ellers .toc.
function Get-Release([string]$dir) {
    $file = Join-Path $dir 'Version.lua'
    if (Test-Path -LiteralPath $file) {
        $m = Select-String -LiteralPath $file -Pattern 'DW\.RELEASE\s*=\s*"([^"]+)"' | Select-Object -First 1
        if ($m) { return $m.Matches[0].Groups[1].Value }
    }
    $toc = Join-Path $dir 'Dragonworld.toc'
    if (Test-Path -LiteralPath $toc) {
        $m = Select-String -LiteralPath $toc -Pattern '^## Version:\s*(\S+)' | Select-Object -First 1
        if ($m) { return $m.Matches[0].Groups[1].Value }
    }
    return $null
}

# Finner AddOns-mappen til WoW Forever.
function Find-AddOns {
    # 1. Skriptet ligger selv i ...\Interface\AddOns\Dragonworld\Updater.
    try {
        $addonDir = Split-Path -Parent $PSScriptRoot
        $parent = Split-Path -Parent $addonDir
        if ((Split-Path -Leaf $addonDir) -eq 'Dragonworld' -and (Split-Path -Leaf $parent) -eq 'AddOns') {
            return $parent
        }
    } catch { }

    Say $T.Looking
    # 2. Forever ligger i mappen _forever_ i WoW-installasjonen. Battle.net
    #    skriver hvor den er i product.db; ellers registeret og vanlige steder.
    $candidates = New-Object System.Collections.Generic.List[string]
    $productDb = Join-Path $env:ProgramData 'Battle.net\Agent\product.db'
    if (Test-Path -LiteralPath $productDb) {
        try {
            $text = [System.Text.Encoding]::UTF8.GetString([System.IO.File]::ReadAllBytes($productDb))
            foreach ($match in [regex]::Matches($text, '[A-Za-z]:[\\/][^\x00-\x1f"]{0,200}?World of Warcraft')) {
                $candidates.Add((Join-Path ($match.Value -replace '/', '\') '_forever_'))
            }
        } catch { }
    }
    foreach ($key in @('HKLM:\SOFTWARE\WOW6432Node\Blizzard Entertainment\World of Warcraft',
                       'HKLM:\SOFTWARE\Blizzard Entertainment\World of Warcraft')) {
        try {
            $path = (Get-ItemProperty -Path $key -ErrorAction Stop).InstallPath
            if ($path) { $candidates.Add((Join-Path (Split-Path -Parent $path.TrimEnd('\')) '_forever_')) }
        } catch { }
    }
    foreach ($drive in Get-PSDrive -PSProvider FileSystem) {
        foreach ($sub in @('Program Files (x86)\World of Warcraft', 'Program Files\World of Warcraft', 'World of Warcraft',
                           'Games\World of Warcraft', 'Spill\World of Warcraft', 'wow\World of Warcraft', 'Blizzard\World of Warcraft')) {
            $candidates.Add((Join-Path $drive.Root (Join-Path $sub '_forever_')))
        }
    }
    foreach ($candidate in $candidates) {
        if (Test-Path -LiteralPath $candidate -PathType Container) {
            return (Join-Path $candidate 'Interface\AddOns')
        }
    }

    # 3. Spør.
    Say $T.NotFound 'Yellow'
    Add-Type -AssemblyName System.Windows.Forms
    $dialog = New-Object System.Windows.Forms.FolderBrowserDialog
    $dialog.Description = $T.Pick
    if ($dialog.ShowDialog() -ne [System.Windows.Forms.DialogResult]::OK) { return $null }
    $chosen = $dialog.SelectedPath
    if ((Split-Path -Leaf $chosen) -eq 'AddOns') { return $chosen }
    if ((Split-Path -Leaf $chosen) -eq 'Interface') { return (Join-Path $chosen 'AddOns') }
    if (Test-Path -LiteralPath (Join-Path $chosen '_forever_')) { $chosen = Join-Path $chosen '_forever_' }
    return (Join-Path $chosen 'Interface\AddOns')
}

# Kopierer den nye versjonen over den gamle, og fjerner filer som ikke er med
# lenger. Selve mappen beholdes (snarveien peker inn i den).
function Copy-Addon([string]$source, [string]$target) {
    New-Item -ItemType Directory -Force -Path $target | Out-Null
    Get-ChildItem -LiteralPath $source -Recurse -File | ForEach-Object {
        $relative = $_.FullName.Substring($source.Length).TrimStart('\')
        $destination = Join-Path $target $relative
        New-Item -ItemType Directory -Force -Path (Split-Path -Parent $destination) | Out-Null
        Copy-Item -LiteralPath $_.FullName -Destination $destination -Force
    }
    Get-ChildItem -LiteralPath $target -Recurse -File | ForEach-Object {
        $relative = $_.FullName.Substring($target.Length).TrimStart('\')
        if (-not (Test-Path -LiteralPath (Join-Path $source $relative))) {
            Remove-Item -LiteralPath $_.FullName -Force -ErrorAction SilentlyContinue
        }
    }
}

function Offer-Shortcut([string]$target) {
    $desktop = [Environment]::GetFolderPath('Desktop')
    $link = Join-Path $desktop 'Dragonworld Updater.lnk'
    $cmd = Join-Path $target 'Updater\Dragonworld Updater.cmd'
    if ((Test-Path -LiteralPath $link) -or -not (Test-Path -LiteralPath $cmd)) { return }
    # Bare når noen sitter ved tastaturet og svarer (ikke ved testing).
    if ($NoPause -or [Console]::IsInputRedirected) { return }
    $answer = Read-Host $T.Shortcut
    if ($null -eq $answer) { return }
    if ($answer -notmatch '^\s*(y|j)') { return }
    $shell = New-Object -ComObject WScript.Shell
    $shortcut = $shell.CreateShortcut($link)
    $shortcut.TargetPath = $cmd
    $shortcut.WorkingDirectory = $env:TEMP
    $shortcut.IconLocation = (Join-Path $target 'Updater\dragonworld.ico') + ',0'
    $shortcut.Description = 'Dragonworld Updater'
    $shortcut.Save()
    Say $T.ShortcutMade 'Green'
}

Write-Host ''
Write-Host '  DRAGONWORLD UPDATER' -ForegroundColor Yellow
Write-Host ''

$temp = Join-Path $env:TEMP ('dragonworld-' + [guid]::NewGuid().ToString('N'))
try {
    $addOns = if ($AddOns) { $AddOns } else { Find-AddOns }
    if (-not $addOns) { throw $T.NotFound }
    Say ($T.Folder -f $addOns)
    $target = Join-Path $addOns 'Dragonworld'
    $old = Get-Release $target

    Say $T.Downloading
    [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12
    New-Item -ItemType Directory -Path $temp | Out-Null
    $zip = Join-Path $temp 'Dragonworld.zip'
    $ProgressPreference = 'SilentlyContinue'
    if ($FromZip) {
        Copy-Item -LiteralPath $FromZip -Destination $zip
    } else {
        Invoke-WebRequest -Uri $ZipUrl -OutFile $zip -UseBasicParsing
    }
    Expand-Archive -LiteralPath $zip -DestinationPath (Join-Path $temp 'x')
    $source = Join-Path $temp 'x\Dragonworld'
    if (-not (Test-Path -LiteralPath (Join-Path $source 'Dragonworld.toc'))) { throw 'Dragonworld.zip has no Dragonworld\Dragonworld.toc' }
    $new = Get-Release $source

    Write-Host ''
    if ($old -and $new -and $old -eq $new) {
        Say ($T.Same -f $new) 'Green'
    } else {
        Copy-Addon $source $target
        if ($old) { Say ($T.Updated -f $old, $new) 'Green' } else { Say ($T.Installed -f $new) 'Green' }
        Say $T.Restart 'Green'
    }
    Write-Host ''
    Offer-Shortcut $target
} catch {
    Write-Host ''
    Say ($T.Failed -f $_.Exception.Message) 'Red'
    Say ($T.Manual -f $PageUrl) 'Yellow'
} finally {
    if (Test-Path -LiteralPath $temp) { Remove-Item -LiteralPath $temp -Recurse -Force -ErrorAction SilentlyContinue }
}

if (-not $NoPause) {
    Write-Host ''
    [void](Read-Host $T.Close)
}
