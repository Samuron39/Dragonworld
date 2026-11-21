# Dragonworld Updater
#
# Henter siste versjon av guild-addonen Dragonworld fra GitHub og legger den i
# AddOns-mappen til World of Warcraft Forever. Startes med "Dragonworld
# Updater.cmd" (ved siden av denne filen), snarveien på skrivebordet, eller
# Installer-Dragonworld.cmd første gang.
#
#   * Ligger skriptet i ...\Interface\AddOns\Dragonworld\Updater, oppdateres
#     den mappen. Ellers letes det etter WoW Forever, og spør om mappen hvis
#     den ikke finnes.
#   * Har du alt siste versjon, skjer ingenting.
#   * Lagrede innstillinger (WTF-mappen) røres ikke.
#   * Første gang tilbys en snarvei "Dragonworld Updater" på skrivebordet, og
#     automatisk oppdatering.
#
# Automatisk oppdatering er en oppgave i Windows' Oppgaveplanlegging
# ("Dragonworld Updater") som kjører dette skriptet med -Silent hvert 10.
# minutt, uten vindu (conhost --headless). Den spør GitHub hvilken versjon som
# er nyest, og laster bare ned når den er nyere. Den skriver DW.AUTO_UPDATE =
# true i Version.lua, så addonen i spillet vet at den bare skal be om /reload.
# Logg: %LOCALAPPDATA%\Dragonworld\updater.log.
#
# Skrevet for Windows PowerShell 5.1, som følger med Windows.

param(
    [switch]$NoPause,
    [string]$AddOns,      # bruk denne AddOns-mappen i stedet for å lete
    [string]$FromZip,     # bruk denne zip-filen i stedet for å laste ned (til testing)
    [switch]$Silent,      # bakgrunnsjobben: ingen vinduer, ingen spørsmål, bare logg
    [switch]$EnableAuto,  # slå på automatisk oppdatering uten å spørre
    [switch]$DisableAuto  # slå av automatisk oppdatering
)

$ErrorActionPreference = 'Stop'
$Repo = 'Samuron39/Dragonworld'
$ZipUrl = "https://github.com/$Repo/releases/latest/download/Dragonworld.zip"
$PageUrl = "https://github.com/$Repo/releases/latest"
$TaskName = 'Dragonworld Updater'
$LogFile = Join-Path $env:LOCALAPPDATA 'Dragonworld\updater.log'
if ($Silent) { $NoPause = $true }

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

# Skriver til skjermen, eller til loggen når det kjører i bakgrunnen.
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

# Et svar fra den som sitter ved tastaturet, eller $null når ingen kan svare.
function Ask([string]$question) {
    if ($Silent -or $NoPause -or [Console]::IsInputRedirected) { return $null }
    return Read-Host $question
}

# En tekst-verdi fra en .lua-fil i en Dragonworld-mappe, f.eks. DW.RELEASE.
function Get-LuaValue([string]$dir, [string]$name) {
    $file = Join-Path $dir 'Version.lua'
    if (-not (Test-Path -LiteralPath $file)) { return $null }
    $m = Select-String -LiteralPath $file -Pattern ([regex]::Escape($name) + '\s*=\s*"([^"]+)"') | Select-Object -First 1
    if ($m) { return $m.Matches[0].Groups[1].Value }
    return $null
}

# Versjonen i en Dragonworld-mappe: den som er lagt ut (Version.lua), ellers .toc.
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

# Siste versjon på GitHub, uten å laste ned noe: "latest" sender videre til
# .../releases/tag/vX.Y.Z. $null hvis det ikke gikk.
function Get-LatestVersion {
    try {
        $request = [System.Net.HttpWebRequest]::Create($PageUrl)
        $request.AllowAutoRedirect = $false
        $request.Method = 'HEAD'
        $request.UserAgent = 'DragonworldUpdater'
        $request.Timeout = 20000
        $response = $request.GetResponse()
        $location = $response.Headers['Location']
        $response.Close()
        if ($location -match '/tag/v(\d+(\.\d+)+)$') { return $Matches[1] }
    } catch { }
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

    # 3. Spør (aldri i bakgrunnen).
    Say $T.NotFound 'Yellow'
    if ($Silent) { return $null }
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
# lenger. Selve mappen beholdes (snarveien og bakgrunnsjobben peker inn i den).
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

# Automatisk oppdatering ---------------------------------------------------------

function Test-AutoUpdate {
    try { return $null -ne (Get-ScheduledTask -TaskName $TaskName -ErrorAction Stop) } catch { return $false }
}

# Skriver DW.AUTO_UPDATE = true/false i Version.lua, så addonen vet det.
function Set-AutoFlag([string]$target, [bool]$on) {
    $file = Join-Path $target 'Version.lua'
    if (-not (Test-Path -LiteralPath $file)) { return }
    $text = [System.IO.File]::ReadAllText($file)
    $value = if ($on) { 'true' } else { 'false' }
    $new = [regex]::Replace($text, 'DW\.AUTO_UPDATE\s*=\s*(true|false)', "DW.AUTO_UPDATE = $value")
    if ($new -ne $text) { [System.IO.File]::WriteAllText($file, $new, (New-Object System.Text.UTF8Encoding($false))) }
}

function Enable-AutoUpdate([string]$target) {
    $script = Join-Path $target 'Updater\update.ps1'
    $arguments = '--headless powershell.exe -NoProfile -NonInteractive -ExecutionPolicy Bypass -WindowStyle Hidden -File "{0}" -Silent' -f $script
    $action = New-ScheduledTaskAction -Execute 'conhost.exe' -Argument $arguments
    # Hver dag fra midnatt, hvert 10. minutt døgnet rundt. Var PC-en av, kjøres
    # den så snart det går.
    $trigger = New-ScheduledTaskTrigger -Daily -At '00:00'
    $trigger.Repetition = (New-ScheduledTaskTrigger -Once -At '00:00' -RepetitionInterval (New-TimeSpan -Minutes 10) -RepetitionDuration (New-TimeSpan -Days 1)).Repetition
    $settings = New-ScheduledTaskSettingsSet -StartWhenAvailable -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries `
        -ExecutionTimeLimit (New-TimeSpan -Minutes 10) -MultipleInstances IgnoreNew
    Register-ScheduledTask -TaskName $TaskName -Action $action -Trigger $trigger -Settings $settings -Force `
        -Description 'Keeps the WoW addon Dragonworld up to date (github.com/Samuron39/Dragonworld). Turn off: run Dragonworld Updater on the desktop.' | Out-Null
    Set-AutoFlag $target $true
}

function Disable-AutoUpdate([string]$target) {
    try { Unregister-ScheduledTask -TaskName $TaskName -Confirm:$false -ErrorAction Stop } catch { }
    Set-AutoFlag $target $false
}

function Offer-Shortcut([string]$target) {
    $desktop = [Environment]::GetFolderPath('Desktop')
    $link = Join-Path $desktop 'Dragonworld Updater.lnk'
    $cmd = Join-Path $target 'Updater\Dragonworld Updater.cmd'
    if ((Test-Path -LiteralPath $link) -or -not (Test-Path -LiteralPath $cmd)) { return }
    $answer = Ask $T.Shortcut
    if ($null -eq $answer -or $answer -notmatch '^\s*(y|j)') { return }
    $shell = New-Object -ComObject WScript.Shell
    $shortcut = $shell.CreateShortcut($link)
    $shortcut.TargetPath = $cmd
    $shortcut.WorkingDirectory = $env:TEMP
    $shortcut.IconLocation = (Join-Path $target 'Updater\dragonworld.ico') + ',0'
    $shortcut.Description = 'Dragonworld Updater'
    $shortcut.Save()
    Say $T.ShortcutMade 'Green'
}

# Spør om automatisk oppdatering, eller (er den på) om den skal slås av.
# Returnerer true hvis spilleren alt har svart, så "Trykk Enter" ikke trengs.
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

# Hovedløpet ------------------------------------------------------------------------

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

    [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12
    # Spør GitHub først; er den samme som vi har, lastes ingenting ned.
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
            Invoke-WebRequest -Uri $ZipUrl -OutFile $zip -UseBasicParsing
        }
        # .NET direkte i stedet for Expand-Archive: den kan bli lastet fra en nyere
        # PowerShell og feile i Windows PowerShell.
        Add-Type -AssemblyName System.IO.Compression.FileSystem
        [System.IO.Compression.ZipFile]::ExtractToDirectory($zip, (Join-Path $temp 'x'))
        $source = Join-Path $temp 'x\Dragonworld'
        if (-not (Test-Path -LiteralPath (Join-Path $source 'Dragonworld.toc'))) { throw 'Dragonworld.zip has no Dragonworld\Dragonworld.toc' }
        $new = Get-Release $source

        if (-not $Silent) { Write-Host '' }
        if ($old -and $new -and $old -eq $new) {
            if (-not $Silent) { Say ($T.Same -f $new) 'Green' }
        } else {
            Copy-Addon $source $target
            if ($old) { Say ($T.Updated -f $old, $new) 'Green' } else { Say ($T.Installed -f $new) 'Green' }
            # Holder /reload, eller har den nye versjonen nye filer?
            $restartFrom = Get-LuaValue $source 'DW.RESTART_RELEASE'
            if ($old -and $restartFrom -and -not (Test-Older $old $restartFrom)) {
                if (-not $Silent) { Say $T.Reload 'Green' }
            } elseif (-not $Silent) {
                Say $T.Restart 'Green'
            }
        }
    }

    # Den nye Version.lua har AUTO_UPDATE = false; er jobben på, settes den igjen.
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
