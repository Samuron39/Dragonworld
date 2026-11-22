# Dragonworld

Guild addon for the guild **Dragonworld** in World of Warcraft Forever. English, Norsk, Nederlands, Deutsch, Dansk, Svenska, Français.

It is for characters in the guild Dragonworld. Alts outside the guild get the personal tabs (Materials, Professions, Tidy Bag, Keybinds) when another character on the same account is in the guild.

## English

**Install (first time)**

1. Download `Installer-Dragonworld.cmd` from the [newest release](https://github.com/Samuron39/Dragonworld/releases/latest) (or `Dragonworld.zip`, and open it).
2. Double-click `Installer-Dragonworld.cmd`. It finds World of Warcraft Forever, puts the addon in the right folder, and offers a shortcut **Dragonworld Updater** on your desktop and **automatic updates** (answer **Y** to both).
3. Start the game.

Windows may warn that the file comes from the internet: choose *More info* and *Run anyway*. By hand also works: unzip `Dragonworld.zip` into `World of Warcraft\_forever_\Interface\AddOns`, so that you get `AddOns\Dragonworld\Dragonworld.toc`.

**Does Windows say Smart App Control blocked the file?** Smart App Control (on by default on many new PCs) blocks every script file downloaded with a browser. Install this way instead:

1. Click **Start**, type `powershell` and open **Windows PowerShell**. It does not need to run as administrator.
2. Paste this line into the window and press **Enter**:

   ```
   Set-ExecutionPolicy Bypass -Scope Process -Force; iwr https://github.com/Samuron39/Dragonworld/releases/latest/download/update.ps1 -OutFile $env:TEMP\dragonworld-update.ps1 -UseBasicParsing; & $env:TEMP\dragonworld-update.ps1
   ```

3. Answer **Y** to the shortcut and to automatic updates.

It downloads the same updater and runs it, and everything works as above, automatic updates included. The first part only lets this one window run the updater, until you close it. On such PCs the desktop shortcut gets Windows' standard icon. Don't paste the line into Windows + R: Windows often stops PowerShell started from there.

**Update**

With automatic updates, the newest version is downloaded in the background (checked every 10 minutes, without any window). The game then says "New version ready!": type `/reload`, or restart the game if it says so.

Without them, the addon says "Update Dragonworld!" in the game. Close the game, double-click **Dragonworld Updater** on your desktop, and start the game again.

The updater only downloads the newest `Dragonworld.zip` from this page and replaces the `Dragonworld` folder in your AddOns; your settings are kept. To turn automatic updates off, double-click **Dragonworld Updater** and type **O**. They are a task named "Dragonworld Updater" in Windows' Task Scheduler.

## Norsk

**Installere (første gang)**

1. Last ned `Installer-Dragonworld.cmd` fra [siste versjon](https://github.com/Samuron39/Dragonworld/releases/latest) (eller `Dragonworld.zip`, og åpne den).
2. Dobbeltklikk `Installer-Dragonworld.cmd`. Den finner World of Warcraft Forever, legger addonen i riktig mappe og tilbyr en snarvei **Dragonworld Updater** på skrivebordet og **automatisk oppdatering** (svar **J** på begge).
3. Start spillet.

Windows kan advare om at filen kommer fra internett: velg *Mer informasjon* og *Kjør likevel*.

**Sier Windows at Smart App Control har blokkert filen?** Smart App Control (som er på fra start på mange nye PC-er) stopper alle skriptfiler som er lastet ned med nettleseren. Installer slik i stedet:

1. Klikk **Start**, skriv `powershell` og åpne **Windows PowerShell**. Den trenger ikke kjøres som administrator.
2. Lim inn denne linjen i vinduet og trykk **Enter**:

   ```
   Set-ExecutionPolicy Bypass -Scope Process -Force; iwr https://github.com/Samuron39/Dragonworld/releases/latest/download/update.ps1 -OutFile $env:TEMP\dragonworld-update.ps1 -UseBasicParsing; & $env:TEMP\dragonworld-update.ps1
   ```

3. Svar **J** på snarveien og på automatisk oppdatering.

Den laster ned det samme oppdateringsprogrammet og kjører det, og alt virker som over, også automatisk oppdatering. Det første leddet gir bare dette ene vinduet lov til å kjøre oppdateringsprogrammet, til du lukker det. På slike PC-er får snarveien på skrivebordet Windows' vanlige ikon. Ikke lim linjen inn i Windows + R: Windows stopper ofte PowerShell som startes derfra.

**Oppdatere**

Med automatisk oppdatering lastes nyeste versjon ned i bakgrunnen (sjekkes hvert 10. minutt, uten vindu). Spillet sier da "Ny versjon er klar!": skriv `/reload`, eller start spillet på nytt hvis det står det.

Uten sier addonen "Oppdater Dragonworld!" i spillet. Lukk spillet, dobbeltklikk **Dragonworld Updater** på skrivebordet, og start spillet igjen. Automatisk oppdatering slås av ved å dobbeltklikke **Dragonworld Updater** og skrive **A**.

## Nederlands

**Installeren (eerste keer)**

1. Download `Installer-Dragonworld.cmd` van de [nieuwste versie](https://github.com/Samuron39/Dragonworld/releases/latest) (of `Dragonworld.zip`, en open hem).
2. Dubbelklik op `Installer-Dragonworld.cmd`. Hij vindt World of Warcraft Forever, zet de addon in de juiste map en biedt een snelkoppeling **Dragonworld Updater** op je bureaublad en **automatische updates** aan (antwoord **J** op beide).
3. Start het spel.

Windows kan waarschuwen dat het bestand van internet komt: kies *Meer info* en *Toch uitvoeren*.

**Zegt Windows dat Smart App Control het bestand heeft geblokkeerd?** Smart App Control (standaard aan op veel nieuwe pc's) blokkeert elk scriptbestand dat met een browser is gedownload. Installeer dan zo:

1. Klik op **Start**, typ `powershell` en open **Windows PowerShell**. Het hoeft niet als administrator.
2. Plak deze regel in het venster en druk op **Enter**:

   ```
   Set-ExecutionPolicy Bypass -Scope Process -Force; iwr https://github.com/Samuron39/Dragonworld/releases/latest/download/update.ps1 -OutFile $env:TEMP\dragonworld-update.ps1 -UseBasicParsing; & $env:TEMP\dragonworld-update.ps1
   ```

3. Antwoord **J** op de snelkoppeling en op automatische updates.

Hij downloadt hetzelfde updateprogramma en voert het uit, en alles werkt zoals hierboven, ook automatische updates. Het eerste deel laat alleen dit ene venster het updateprogramma uitvoeren, tot je het sluit. Op zulke pc's krijgt de snelkoppeling op het bureaublad het standaardpictogram van Windows. Plak de regel niet in Windows + R: Windows houdt PowerShell die daar wordt gestart vaak tegen.

**Bijwerken**

Met automatische updates wordt de nieuwste versie op de achtergrond gedownload (elke 10 minuten gecontroleerd, zonder venster). Het spel zegt dan "Nieuwe versie klaar!": typ `/reload`, of start het spel opnieuw als dat er staat.

Zonder zegt de addon "Werk Dragonworld bij!" in het spel. Sluit het spel, dubbelklik op **Dragonworld Updater** op je bureaublad en start het spel opnieuw. Automatische updates zet je uit door **Dragonworld Updater** te dubbelklikken en **U** te typen.

## For developers

- `Dragonworld/` is the addon. `tests/` runs it against a fake WoW API: `node tests/run.js Dragonworld` (run `npm install` in `tests` first).
- `tools/release.ps1 -News @{ en = '...'; nb = '...'; ... }` publishes a new version: tests, `Version.lua` (with the short news shown in the game's update window), commit, tag, push, GitHub release with `Dragonworld.zip` and `Installer-Dragonworld.cmd`. See `CLAUDE.md`.
- `Installer-Dragonworld.cmd` downloads `Dragonworld/Updater/update.ps1` from this repository and runs it; the updater finds the game, installs the newest release and offers the desktop shortcut.
- `update.ps1` must also work in PowerShell's Constrained Language Mode, which Smart App Control turns on for scripts that aren't signed: only PowerShell's own commands, and .NET or COM only with a fallback (`tar.exe` for the zip, `schtasks.exe` for the task). To test, run it from a session after `$ExecutionContext.SessionState.LanguageMode = 'ConstrainedLanguage'`.
- The addons in the guild tell each other their version over addon messages, since an addon cannot read the internet; the one with an older version gets the update window.
