# Dragonworld

Guild addon for the guild **Dragonworld** in World of Warcraft Forever. English, Norsk, Nederlands.

Only characters in the guild Dragonworld can use it.

## English

**Install (first time)**

1. Download `Installer-Dragonworld.cmd` from the [newest release](https://github.com/Samuron39/Dragonworld/releases/latest) (or `Dragonworld.zip`, and open it).
2. Double-click `Installer-Dragonworld.cmd`. It finds World of Warcraft Forever, puts the addon in the right folder, and offers a shortcut **Dragonworld Updater** on your desktop and **automatic updates** (answer **Y** to both).
3. Start the game.

Windows may warn that the file comes from the internet: choose *More info* and *Run anyway*. By hand also works: unzip `Dragonworld.zip` into `World of Warcraft\_forever_\Interface\AddOns`, so that you get `AddOns\Dragonworld\Dragonworld.toc`.

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

**Oppdatere**

Med automatisk oppdatering lastes nyeste versjon ned i bakgrunnen (sjekkes hvert 10. minutt, uten vindu). Spillet sier da "Ny versjon er klar!": skriv `/reload`, eller start spillet på nytt hvis det står det.

Uten sier addonen "Oppdater Dragonworld!" i spillet. Lukk spillet, dobbeltklikk **Dragonworld Updater** på skrivebordet, og start spillet igjen. Automatisk oppdatering slås av ved å dobbeltklikke **Dragonworld Updater** og skrive **A**.

## Nederlands

**Installeren (eerste keer)**

1. Download `Installer-Dragonworld.cmd` van de [nieuwste versie](https://github.com/Samuron39/Dragonworld/releases/latest) (of `Dragonworld.zip`, en open hem).
2. Dubbelklik op `Installer-Dragonworld.cmd`. Hij vindt World of Warcraft Forever, zet de addon in de juiste map en biedt een snelkoppeling **Dragonworld Updater** op je bureaublad en **automatische updates** aan (antwoord **J** op beide).
3. Start het spel.

Windows kan waarschuwen dat het bestand van internet komt: kies *Meer info* en *Toch uitvoeren*.

**Bijwerken**

Met automatische updates wordt de nieuwste versie op de achtergrond gedownload (elke 10 minuten gecontroleerd, zonder venster). Het spel zegt dan "Nieuwe versie klaar!": typ `/reload`, of start het spel opnieuw als dat er staat.

Zonder zegt de addon "Werk Dragonworld bij!" in het spel. Sluit het spel, dubbelklik op **Dragonworld Updater** op je bureaublad en start het spel opnieuw. Automatische updates zet je uit door **Dragonworld Updater** te dubbelklikken en **U** te typen.

## For developers

- `Dragonworld/` is the addon. `tests/` runs it against a fake WoW API: `node tests/run.js Dragonworld` (run `npm install` in `tests` first).
- `tools/release.ps1` publishes a new version: tests, `Version.lua`, commit, tag, push, GitHub release with `Dragonworld.zip` and `Installer-Dragonworld.cmd`.
- `Installer-Dragonworld.cmd` downloads `Dragonworld/Updater/update.ps1` from this repository and runs it; the updater finds the game, installs the newest release and offers the desktop shortcut.
- The addons in the guild tell each other their version over addon messages, since an addon cannot read the internet; the one with an older version gets the update window.
