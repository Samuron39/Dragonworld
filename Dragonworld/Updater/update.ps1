# Dragonworld Updater
#
# Gets the latest version of the guild addon Dragonworld from GitHub and puts
# it in the AddOns folder of World of Warcraft Forever. Started with
# "Dragonworld Updater.cmd" (next to this file), the desktop shortcut, or
# Installer-Dragonworld.cmd the first time.
#
#   * If the script is in ...\Interface\AddOns\Dragonworld\Updater, that
#     folder is updated. Otherwise it looks for WoW Forever, and asks for the
#     folder if it can't find it.
#   * If you already have the latest version, nothing happens.
#   * Saved settings (the WTF folder) are not touched.
#   * The first time, it offers a desktop shortcut "Dragonworld Updater" and
#     automatic updates.
#
# Automatic updates are a task in Windows Task Scheduler ("Dragonworld
# Updater") that runs this script with -Silent every 10 minutes, without a
# window (conhost --headless). It asks GitHub which version is the newest, and
# only downloads when it is newer. It writes DW.AUTO_UPDATE = true in
# Version.lua, so the addon in the game knows it only has to ask for /reload.
# Log: %LOCALAPPDATA%\Dragonworld\updater.log.
#
# Written for Windows PowerShell 5.1, which comes with Windows.
#
# Smart App Control: on PCs where it is on, Windows blocks script files
# downloaded with a browser (so Installer-Dragonworld.cmd), and runs this
# script in Constrained Language Mode, where it may only use PowerShell's own
# commands, not .NET or COM. Everything here that needs .NET or COM therefore
# has a fallback that uses only commands and Windows' own programs (tar.exe,
# schtasks.exe). On such PCs the first install is a line pasted into
# Windows + R (see README.md), which downloads this script with PowerShell
# itself, so it is not marked as downloaded:
#   powershell -ep bypass -c "iwr https://github.com/Samuron39/Dragonworld/releases/latest/download/update.ps1 -OutFile $env:TEMP\dragonworld-update.ps1 -UseBasicParsing; & $env:TEMP\dragonworld-update.ps1"

param(
    [switch]$NoPause,
    [string]$AddOns,      # use this AddOns folder instead of looking for it
    [string]$FromZip,     # use this zip file instead of downloading (for testing)
    [switch]$Silent,      # the background job: no windows, no questions, only the log
    [switch]$EnableAuto,  # turn on automatic updates without asking
    [switch]$DisableAuto, # turn off automatic updates
    [string]$TaskName = 'Dragonworld Updater' # name of the scheduled task (another name only for testing)
)

$ErrorActionPreference = 'Stop'
$Repo = 'Samuron39/Dragonworld'
$ZipUrl = "https://github.com/$Repo/releases/latest/download/Dragonworld.zip"
$PageUrl = "https://github.com/$Repo/releases/latest"
$LogFile = Join-Path $env:LOCALAPPDATA 'Dragonworld\updater.log'
if ($Silent) { $NoPause = $true }

# Text in the language Windows uses: Norwegian, Dutch, otherwise English.
$Texts = @{
    en = @{
        Looking      = 'Looking for World of Warcraft Forever...'
        Pick         = 'Choose the _forever_ folder of World of Warcraft (for example C:\Program Files (x86)\World of Warcraft\_forever_)'
        PickType     = 'Type or paste the path to the _forever_ folder of World of Warcraft (for example C:\Program Files (x86)\World of Warcraft\_forever_)'
        NotFound     = 'World of Warcraft Forever was not found.'
        Folder       = 'AddOns folder: {0}'
        Downloading  = 'Downloading the newest version...'
        Same         = 'You already have the newest version ({0}).'
        Updated      = 'Dragonworld is updated from {0} to {1}.'
        Installed    = 'Dragonworld {0} is installed.'
        Restart      = 'Restart the game to use it.'
        Reload       = 'If the game is running, type /reload to use it.'
        Failed       = 'Something went wrong: {0}'
        Manual       = 'You can download the addon yourself here: {0}'
        Shortcut     = 'Put a shortcut "Dragonworld Updater" on the desktop? (Y/N)'
        ShortcutMade = 'The shortcut is on the desktop.'
        AutoAsk      = 'Update Dragonworld automatically in the background? Then you only type /reload in the game when a new version is out. (Y/N)'
        AutoMade     = 'Automatic updates are on. It checks every 10 minutes, without any window.'
        AutoIsOn     = 'Automatic updates are on. Type O and press Enter to turn them off, or just press Enter to close.'
        AutoOffKey   = 'o'
        AutoOff      = 'Automatic updates are off.'
        AutoFailed   = 'Could not turn on automatic updates: {0}'
        Close        = 'Press Enter to close.'
    }
    nb = @{
        Looking      = 'Leter etter World of Warcraft Forever...'
        Pick         = 'Velg mappen _forever_ i World of Warcraft (for eksempel C:\Program Files (x86)\World of Warcraft\_forever_)'
        PickType     = 'Skriv eller lim inn stien til mappen _forever_ i World of Warcraft (for eksempel C:\Program Files (x86)\World of Warcraft\_forever_)'
        NotFound     = 'Fant ikke World of Warcraft Forever.'
        Folder       = 'AddOns-mappe: {0}'
        Downloading  = 'Laster ned siste versjon...'
        Same         = 'Du har allerede siste versjon ({0}).'
        Updated      = 'Dragonworld er oppdatert fra {0} til {1}.'
        Installed    = 'Dragonworld {0} er installert.'
        Restart      = 'Start spillet på nytt for å bruke den.'
        Reload       = 'Kjører spillet, skriver du /reload for å ta den i bruk.'
        Failed       = 'Noe gikk galt: {0}'
        Manual       = 'Du kan laste ned addonen selv her: {0}'
        Shortcut     = 'Lage en snarvei "Dragonworld Updater" på skrivebordet? (J/N)'
        ShortcutMade = 'Snarveien ligger på skrivebordet.'
        AutoAsk      = 'Oppdatere Dragonworld automatisk i bakgrunnen? Da trenger du bare skrive /reload i spillet når en ny versjon er ute. (J/N)'
        AutoMade     = 'Automatisk oppdatering er på. Den sjekker hvert 10. minutt, uten å vise noe vindu.'
        AutoIsOn     = 'Automatisk oppdatering er på. Skriv A og trykk Enter for å slå den av, eller bare trykk Enter for å lukke.'
        AutoOffKey   = 'a'
        AutoOff      = 'Automatisk oppdatering er slått av.'
        AutoFailed   = 'Fikk ikke slått på automatisk oppdatering: {0}'
        Close        = 'Trykk Enter for å lukke.'
    }
    nl = @{
        Looking      = 'Zoeken naar World of Warcraft Forever...'
        Pick         = 'Kies de map _forever_ van World of Warcraft (bijvoorbeeld C:\Program Files (x86)\World of Warcraft\_forever_)'
        PickType     = 'Typ of plak het pad naar de map _forever_ van World of Warcraft (bijvoorbeeld C:\Program Files (x86)\World of Warcraft\_forever_)'
        NotFound     = 'World of Warcraft Forever is niet gevonden.'
        Folder       = 'AddOns-map: {0}'
        Downloading  = 'De nieuwste versie wordt gedownload...'
        Same         = 'Je hebt al de nieuwste versie ({0}).'
        Updated      = 'Dragonworld is bijgewerkt van {0} naar {1}.'
        Installed    = 'Dragonworld {0} is geïnstalleerd.'
        Restart      = 'Start het spel opnieuw om hem te gebruiken.'
        Reload       = 'Als het spel draait, typ /reload om hem te gebruiken.'
        Failed       = 'Er ging iets mis: {0}'
        Manual       = 'Je kunt de addon zelf downloaden: {0}'
        Shortcut     = 'Een snelkoppeling "Dragonworld Updater" op het bureaublad zetten? (J/N)'
        ShortcutMade = 'De snelkoppeling staat op het bureaublad.'
        AutoAsk      = 'Dragonworld automatisch bijwerken op de achtergrond? Dan typ je alleen /reload in het spel als er een nieuwe versie is. (J/N)'
        AutoMade     = 'Automatische updates staan aan. Er wordt elke 10 minuten gecontroleerd, zonder venster.'
        AutoIsOn     = 'Automatische updates staan aan. Typ U en druk op Enter om ze uit te zetten, of druk alleen op Enter om te sluiten.'
        AutoOffKey   = 'u'
        AutoOff      = 'Automatische updates staan uit.'
        AutoFailed   = 'Kon automatische updates niet aanzetten: {0}'
        Close        = 'Druk op Enter om te sluiten.'
    }
}
$language = (Get-UICulture).TwoLetterISOLanguageName
if ($language -in @('nb', 'nn', 'no')) { $language = 'nb' }
if (-not $Texts.ContainsKey($language)) { $language = 'en' }
$T = $Texts[$language]

# Writes to the screen, or to the log when it runs in the background.
function Say([string]$text, [string]$color = 'Gray') {
    if ($Silent) {
        try {
            New-Item -ItemType Directory -Force -Path (Split-Path -Parent $LogFile) | Out-Null
            $lines = @()
            if (Test-Path -LiteralPath $LogFile) { $lines = @(Get-Content -LiteralPath $LogFile -Tail 199) }
            $lines += ('{0:yyyy-MM-dd HH:mm:ss}  {1}' -f (Get-Date), $text)
            Set-Content -LiteralPath $LogFile -Value $lines -Encoding UTF8
        } catch { }
    } else {
        Write-Host $text -ForegroundColor $color
    }
}

# An answer from whoever is at the keyboard, or $null when nobody can answer.
function Ask([string]$question) {
    if ($Silent -or $NoPause -or [Console]::IsInputRedirected) { return $null }
    return Read-Host $question
}

# A text value from a .lua file in a Dragonworld folder, e.g. DW.RELEASE.
function Get-LuaValue([string]$dir, [string]$name) {
    $file = Join-Path $dir 'Version.lua'
    if (-not (Test-Path -LiteralPath $file)) { return $null }
    $m = Select-String -LiteralPath $file -Pattern ([regex]::Escape($name) + '\s*=\s*"([^"]+)"') | Select-Object -First 1
    if ($m) { return $m.Matches[0].Groups[1].Value }
    return $null
}

# The version in a Dragonworld folder: the released one (Version.lua), otherwise .toc.
function Get-Release([string]$dir) {
    $release = Get-LuaValue $dir 'DW.RELEASE'
    if ($release) { return $release }
    $toc = Join-Path $dir 'Dragonworld.toc'
    if (Test-Path -LiteralPath $toc) {
        $m = Select-String -LiteralPath $toc -Pattern '^## Version:\s*(\S+)' | Select-Object -First 1
        if ($m) { return $m.Matches[0].Groups[1].Value }
    }
    return $null
}

function Test-Older([string]$a, [string]$b) {
    try { return ([version]$a) -lt ([version]$b) } catch { return $false }
}

# The latest version on GitHub, without downloading anything: "latest"
# redirects to .../releases/tag/vX.Y.Z. $null if that didn't work.
function Get-LatestVersion {
    $location = $null
    try {
        $request = [System.Net.HttpWebRequest]::Create($PageUrl)
        $request.AllowAutoRedirect = $false
        $request.Method = 'HEAD'
        $request.UserAgent = 'DragonworldUpdater'
        $request.Timeout = 20000
        $response = $request.GetResponse()
        $location = $response.Headers['Location']
        $response.Close()
    } catch {
        # Constrained Language Mode (no .NET): Windows PowerShell's
        # Invoke-WebRequest stops at the redirect and still returns it.
        try {
            $response = Invoke-WebRequest -Uri $PageUrl -Method Head -MaximumRedirection 0 -UseBasicParsing -TimeoutSec 20 -ErrorAction SilentlyContinue
            if ($response) { $location = [string]$response.Headers.Location }
        } catch { }
    }
    if ($location -match '/tag/v(\d+(\.\d+)+)$') { return $Matches[1] }
    # Last resort: GitHub's API (limited to 60 questions an hour per address).
    try {
        $release = Invoke-RestMethod -Uri "https://api.github.com/repos/$Repo/releases/latest" -UseBasicParsing -TimeoutSec 20
        if ([string]$release.tag_name -match '^v(\d+(\.\d+)+)$') { return $Matches[1] }
    } catch { }
    return $null
}

# Finds the AddOns folder of WoW Forever.
function Find-AddOns {
    # 1. The script itself is in ...\Interface\AddOns\Dragonworld\Updater.
    try {
        $addonDir = Split-Path -Parent $PSScriptRoot
        $parent = Split-Path -Parent $addonDir
        if ((Split-Path -Leaf $addonDir) -eq 'Dragonworld' -and (Split-Path -Leaf $parent) -eq 'AddOns') {
            return $parent
        }
    } catch { }

    Say $T.Looking
    # 2. Forever is in the _forever_ folder of the WoW installation. Battle.net
    #    writes where it is in product.db; otherwise the registry and usual places.
    # (A plain array and Get-Content, so it also works in Constrained Language Mode.)
    $candidates = @()
    $productDb = Join-Path $env:ProgramData 'Battle.net\Agent\product.db'
    if (Test-Path -LiteralPath $productDb) {
        try {
            $text = Get-Content -LiteralPath $productDb -Raw -Encoding UTF8
            foreach ($match in [regex]::Matches($text, '[A-Za-z]:[\\/][^\x00-\x1f"]{0,200}?World of Warcraft')) {
                $candidates += (Join-Path ($match.Value -replace '/', '\') '_forever_')
            }
        } catch { }
    }
    foreach ($key in @('HKLM:\SOFTWARE\WOW6432Node\Blizzard Entertainment\World of Warcraft',
                       'HKLM:\SOFTWARE\Blizzard Entertainment\World of Warcraft')) {
        try {
            $path = (Get-ItemProperty -Path $key -ErrorAction Stop).InstallPath
            if ($path) { $candidates += (Join-Path (Split-Path -Parent $path.TrimEnd('\')) '_forever_') }
        } catch { }
    }
    foreach ($drive in Get-PSDrive -PSProvider FileSystem) {
        foreach ($sub in @('Program Files (x86)\World of Warcraft', 'Program Files\World of Warcraft', 'World of Warcraft',
                           'Games\World of Warcraft', 'Spill\World of Warcraft', 'wow\World of Warcraft', 'Blizzard\World of Warcraft')) {
            $candidates += (Join-Path $drive.Root (Join-Path $sub '_forever_'))
        }
    }
    foreach ($candidate in $candidates) {
        if (Test-Path -LiteralPath $candidate -PathType Container) {
            return (Join-Path $candidate 'Interface\AddOns')
        }
    }

    # 3. Ask (never in the background): a folder window, or where that isn't
    #    allowed (Constrained Language Mode), a question in the console.
    Say $T.NotFound 'Yellow'
    if ($Silent) { return $null }
    $chosen = $null
    try {
        Add-Type -AssemblyName System.Windows.Forms
        $dialog = New-Object System.Windows.Forms.FolderBrowserDialog
        $dialog.Description = $T.Pick
        if ($dialog.ShowDialog() -ne [System.Windows.Forms.DialogResult]::OK) { return $null }
        $chosen = $dialog.SelectedPath
    } catch {
        $typed = Ask $T.PickType
        if ($typed) { $chosen = $typed.Trim().Trim('"').TrimEnd('\') }
        if (-not $chosen -or -not (Test-Path -LiteralPath $chosen -PathType Container)) { return $null }
    }
    if ((Split-Path -Leaf $chosen) -eq 'AddOns') { return $chosen }
    if ((Split-Path -Leaf $chosen) -eq 'Interface') { return (Join-Path $chosen 'AddOns') }
    if (Test-Path -LiteralPath (Join-Path $chosen '_forever_')) { $chosen = Join-Path $chosen '_forever_' }
    return (Join-Path $chosen 'Interface\AddOns')
}

# Copies the new version over the old one, and removes files that are no longer
# included. The folder itself is kept (the shortcut and the background job
# point into it).
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

# Automatic updates --------------------------------------------------------------

# The task is made, checked and removed with Windows' own schtasks.exe, which
# also works in Constrained Language Mode (the ScheduledTasks commands may not
# load there).
function Test-AutoUpdate {
    $ErrorActionPreference = 'Continue'
    & schtasks.exe /Query /TN $TaskName 2>&1 | Out-Null
    return $LASTEXITCODE -eq 0
}

# Writes DW.AUTO_UPDATE = true/false in Version.lua, so the addon knows.
# The file is read and written as bytes, so everything else in it (UTF-8,
# without BOM) stays exactly as it was. That needs no .NET either.
function Set-AutoFlag([string]$target, [bool]$on) {
    $file = Join-Path $target 'Version.lua'
    if (-not (Test-Path -LiteralPath $file)) { return }
    if ($PSVersionTable.PSVersion.Major -ge 6) {
        $read = @{ AsByteStream = $true; Raw = $true }
        $write = @{ AsByteStream = $true }
    } else {
        $read = @{ Encoding = 'Byte'; ReadCount = 0 }
        $write = @{ Encoding = 'Byte' }
    }
    $bytes = Get-Content -LiteralPath $file @read
    $text = -join ($bytes | ForEach-Object { [char]$_ })
    $value = if ($on) { 'true' } else { 'false' }
    $new = $text -creplace 'DW\.AUTO_UPDATE\s*=\s*(true|false)', "DW.AUTO_UPDATE = $value"
    if ($new -cne $text) {
        Set-Content -LiteralPath $file -Value ([byte[]]($new.ToCharArray() | ForEach-Object { [byte]$_ })) @write
    }
}

function ConvertTo-XmlText([string]$text) {
    return $text -replace '&', '&amp;' -replace '<', '&lt;' -replace '>', '&gt;'
}

function Enable-AutoUpdate([string]$target) {
    $script = Join-Path $target 'Updater\update.ps1'
    $arguments = '--headless powershell.exe -NoProfile -NonInteractive -ExecutionPolicy Bypass -WindowStyle Hidden -File "{0}" -Silent' -f $script
    $description = 'Keeps the WoW addon Dragonworld up to date (github.com/Samuron39/Dragonworld). Turn off: run Dragonworld Updater on the desktop.'
    $start = (Get-Date -Format 'yyyy-MM-dd') + 'T00:00:00'
    # Every day from midnight, every 10 minutes around the clock, also on
    # battery. If the PC was off, it runs as soon as it can. It runs as you,
    # only while you are logged in.
    $xml = @"
<?xml version="1.0" encoding="UTF-16"?>
<Task version="1.3" xmlns="http://schemas.microsoft.com/windows/2004/02/mit/task">
  <RegistrationInfo>
    <Description>$(ConvertTo-XmlText $description)</Description>
  </RegistrationInfo>
  <Principals>
    <Principal id="Author">
      <LogonType>InteractiveToken</LogonType>
      <RunLevel>LeastPrivilege</RunLevel>
    </Principal>
  </Principals>
  <Settings>
    <DisallowStartIfOnBatteries>false</DisallowStartIfOnBatteries>
    <StopIfGoingOnBatteries>false</StopIfGoingOnBatteries>
    <ExecutionTimeLimit>PT10M</ExecutionTimeLimit>
    <MultipleInstancesPolicy>IgnoreNew</MultipleInstancesPolicy>
    <StartWhenAvailable>true</StartWhenAvailable>
    <Enabled>true</Enabled>
  </Settings>
  <Triggers>
    <CalendarTrigger>
      <StartBoundary>$start</StartBoundary>
      <Repetition>
        <Interval>PT10M</Interval>
        <Duration>P1D</Duration>
        <StopAtDurationEnd>true</StopAtDurationEnd>
      </Repetition>
      <ScheduleByDay>
        <DaysInterval>1</DaysInterval>
      </ScheduleByDay>
    </CalendarTrigger>
  </Triggers>
  <Actions Context="Author">
    <Exec>
      <Command>conhost.exe</Command>
      <Arguments>$(ConvertTo-XmlText $arguments)</Arguments>
    </Exec>
  </Actions>
</Task>
"@
    $xmlFile = Join-Path $env:TEMP ('dragonworld-task-' + [guid]::NewGuid().ToString('N') + '.xml')
    Set-Content -LiteralPath $xmlFile -Value $xml -Encoding Unicode
    $ErrorActionPreference = 'Continue'
    $output = & schtasks.exe /Create /TN $TaskName /XML $xmlFile /F 2>&1
    $code = $LASTEXITCODE
    Remove-Item -LiteralPath $xmlFile -Force -ErrorAction SilentlyContinue
    if ($code -ne 0) { throw ('schtasks: ' + (($output | ForEach-Object { [string]$_ }) -join ' ').Trim()) }
    Set-AutoFlag $target $true
}

function Disable-AutoUpdate([string]$target) {
    $ErrorActionPreference = 'Continue'
    & schtasks.exe /Delete /TN $TaskName /F 2>&1 | Out-Null
    Set-AutoFlag $target $false
}

# The desktop folder (it may have been moved, for example to OneDrive).
function Get-DesktopFolder {
    try { return [Environment]::GetFolderPath('Desktop') } catch { }
    try {
        $desktop = (Get-ItemProperty -Path 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\Shell Folders' -ErrorAction Stop).Desktop
        if ($desktop) { return $desktop }
    } catch { }
    return (Join-Path $env:USERPROFILE 'Desktop')
}

function Offer-Shortcut([string]$target) {
    $desktop = Get-DesktopFolder
    $link = Join-Path $desktop 'Dragonworld Updater.lnk'
    $batch = Join-Path $desktop 'Dragonworld Updater.cmd'
    $cmd = Join-Path $target 'Updater\Dragonworld Updater.cmd'
    if ((Test-Path -LiteralPath $link) -or (Test-Path -LiteralPath $batch) -or -not (Test-Path -LiteralPath $cmd)) { return }
    $answer = Ask $T.Shortcut
    if ($null -eq $answer -or $answer -notmatch '^\s*(y|j)') { return }
    try {
        $shell = New-Object -ComObject WScript.Shell
        $shortcut = $shell.CreateShortcut($link)
        $shortcut.TargetPath = $cmd
        $shortcut.WorkingDirectory = $env:TEMP
        $shortcut.IconLocation = (Join-Path $target 'Updater\dragonworld.ico') + ',0'
        $shortcut.Description = 'Dragonworld Updater'
        $shortcut.Save()
    } catch {
        # Constrained Language Mode: no COM, so no real shortcut. A small .cmd
        # file on the desktop that starts the updater does the same job, with
        # Windows' standard icon.
        Set-Content -LiteralPath $batch -Encoding Oem -Value @('@echo off', ('call "{0}"' -f $cmd))
    }
    Say $T.ShortcutMade 'Green'
}

# Asks about automatic updates, or (if they are on) whether to turn them off.
# Returns true if the player has already answered, so "Press Enter" isn't needed.
function Offer-AutoUpdate([string]$target) {
    if (Test-AutoUpdate) {
        Set-AutoFlag $target $true
        $answer = Ask $T.AutoIsOn
        if ($null -eq $answer) { return $false }
        if ($answer.Trim().ToLower() -eq $T.AutoOffKey) {
            Disable-AutoUpdate $target
            Say $T.AutoOff 'Yellow'
            return $false
        }
        return $true
    }
    $answer = Ask $T.AutoAsk
    if ($null -eq $answer -or $answer -notmatch '^\s*(y|j)') { return $false }
    try {
        Enable-AutoUpdate $target
        Say $T.AutoMade 'Green'
    } catch {
        Say ($T.AutoFailed -f $_.Exception.Message) 'Red'
    }
    return $false
}

# Main run --------------------------------------------------------------------------

if (-not $Silent) {
    Write-Host ''
    Write-Host '  DRAGONWORLD UPDATER' -ForegroundColor Yellow
    Write-Host ''
}

$answered = $false
$temp = Join-Path $env:TEMP ('dragonworld-' + [guid]::NewGuid().ToString('N'))
try {
    $addOns = if ($AddOns) { $AddOns } else { Find-AddOns }
    if (-not $addOns) { throw $T.NotFound }
    if (-not $Silent) { Say ($T.Folder -f $addOns) }
    $target = Join-Path $addOns 'Dragonworld'
    $old = Get-Release $target

    if ($DisableAuto) {
        Disable-AutoUpdate $target
        Say $T.AutoOff 'Yellow'
        return
    }

    # TLS 1.2 for GitHub on older Windows. Not allowed in Constrained Language
    # Mode, but there Windows is new enough to use it anyway.
    try { [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12 } catch { }
    # Ask GitHub first; if it's the same as what we have, nothing is downloaded.
    $latest = if ($FromZip) { $null } else { Get-LatestVersion }
    if ($Silent -and -not $latest -and -not $FromZip) {
        Say 'Could not ask GitHub for the newest version; trying again later.'
        exit 1
    }

    if ($old -and $latest -and -not (Test-Older $old $latest)) {
        if (-not $Silent) { Write-Host ''; Say ($T.Same -f $old) 'Green' }
    } else {
        if (-not $Silent) { Say $T.Downloading }
        New-Item -ItemType Directory -Path $temp | Out-Null
        $zip = Join-Path $temp 'Dragonworld.zip'
        $ProgressPreference = 'SilentlyContinue'
        if ($FromZip) {
            Copy-Item -LiteralPath $FromZip -Destination $zip
        } else {
            # Get exactly the version GitHub said was newest: the "latest" links
            # can point to the previous version for a few minutes after a release.
            $url = if ($latest) { "https://github.com/$Repo/releases/download/v$latest/Dragonworld.zip" } else { $ZipUrl }
            Invoke-WebRequest -Uri $url -OutFile $zip -UseBasicParsing
        }
        # .NET directly instead of Expand-Archive: that one can be loaded from a
        # newer PowerShell and fail in Windows PowerShell. Where .NET isn't
        # allowed (Constrained Language Mode), Windows' own tar.exe, which also
        # unpacks zip files.
        $unpacked = Join-Path $temp 'x'
        try {
            Add-Type -AssemblyName System.IO.Compression.FileSystem
            [System.IO.Compression.ZipFile]::ExtractToDirectory($zip, $unpacked)
        } catch {
            New-Item -ItemType Directory -Force -Path $unpacked | Out-Null
            & (Join-Path $env:SystemRoot 'System32\tar.exe') -xf $zip -C $unpacked
            if ($LASTEXITCODE -ne 0) { throw "tar.exe could not unpack Dragonworld.zip ($LASTEXITCODE)" }
        }
        $source = Join-Path $temp 'x\Dragonworld'
        if (-not (Test-Path -LiteralPath (Join-Path $source 'Dragonworld.toc'))) { throw 'Dragonworld.zip has no Dragonworld\Dragonworld.toc' }
        $new = Get-Release $source

        if (-not $Silent) { Write-Host '' }
        if ($old -and $new -and ($old -eq $new -or (Test-Older $new $old))) {
            # The same, or (right after a release) an older one than ours: never go back.
            if (-not $Silent) { Say ($T.Same -f $old) 'Green' }
        } else {
            Copy-Addon $source $target
            if ($old) { Say ($T.Updated -f $old, $new) 'Green' } else { Say ($T.Installed -f $new) 'Green' }
            # Is /reload enough, or does the new version have new files?
            $restartFrom = Get-LuaValue $source 'DW.RESTART_RELEASE'
            if ($old -and $restartFrom -and -not (Test-Older $old $restartFrom)) {
                if (-not $Silent) { Say $T.Reload 'Green' }
            } elseif (-not $Silent) {
                Say $T.Restart 'Green'
            }
        }
    }

    # The new Version.lua has AUTO_UPDATE = false; if the job is on, set it again.
    if ($EnableAuto -and -not (Test-AutoUpdate)) {
        Enable-AutoUpdate $target
        Say $T.AutoMade 'Green'
    } elseif (Test-AutoUpdate) {
        Set-AutoFlag $target $true
    }

    if (-not $Silent) {
        Write-Host ''
        Offer-Shortcut $target
        $answered = Offer-AutoUpdate $target
    }
} catch {
    if (-not $Silent) { Write-Host '' }
    Say ($T.Failed -f $_.Exception.Message) 'Red'
    if (-not $Silent) { Say ($T.Manual -f $PageUrl) 'Yellow' }
    if ($Silent) { exit 1 }
} finally {
    if (Test-Path -LiteralPath $temp) { Remove-Item -LiteralPath $temp -Recurse -Force -ErrorAction SilentlyContinue }
}

if (-not $NoPause -and -not $answered) {
    Write-Host ''
    [void](Read-Host $T.Close)
}
