# Dragonworld

Guild addon for the guild **Dragonworld** in World of Warcraft Forever. English, Norsk, Nederlands.

Only characters in the guild Dragonworld can use it.

## English

**Install (first time)**

1. Download `Installer-Dragonworld.cmd` from the [newest release](https://github.com/Samuron39/Dragonworld/releases/latest) (or `Dragonworld.zip`, and open it).
2. Double-click `Installer-Dragonworld.cmd`. It finds World of Warcraft Forever, puts the addon in the right folder, and offers a shortcut **Dragonworld Updater** on your desktop (answer **Y**).
3. Start the game.

Windows may warn that the file comes from the internet: choose *More info* and *Run anyway*. By hand also works: unzip `Dragonworld.zip` into `World of Warcraft\_forever_\Interface\AddOns`, so that you get `AddOns\Dragonworld\Dragonworld.toc`.

**Update**

When a newer version is out, the addon says so in the game ("Update Dragonworld!"). Close the game, double-click **Dragonworld Updater** on your desktop, and start the game again. It only downloads the newest `Dragonworld.zip` from this page and replaces the `Dragonworld` folder in your AddOns; your settings are kept.

## Norsk

**Installere (første gang)**

1. Last ned `Installer-Dragonworld.cmd` fra [siste versjon](https://github.com/Samuron39/Dragonworld/releases/latest) (eller `Dragonworld.zip`, og åpne den).
2. Dobbeltklikk `Installer-Dragonworld.cmd`. Den finner World of Warcraft Forever, legger addonen i riktig mappe og tilbyr en snarvei **Dragonworld Updater** på skrivebordet (svar **J**).
3. Start spillet.

Windows kan advare om at filen kommer fra internett: velg *Mer informasjon* og *Kjør likevel*.

**Oppdatere**

Når en nyere versjon er ute, sier addonen fra i spillet ("Oppdater Dragonworld!"). Lukk spillet, dobbeltklikk **Dragonworld Updater** på skrivebordet, og start spillet igjen.

## Nederlands

**Installeren (eerste keer)**

1. Download `Installer-Dragonworld.cmd` van de [nieuwste versie](https://github.com/Samuron39/Dragonworld/releases/latest) (of `Dragonworld.zip`, en open hem).
2. Dubbelklik op `Installer-Dragonworld.cmd`. Hij vindt World of Warcraft Forever, zet de addon in de juiste map en biedt een snelkoppeling **Dragonworld Updater** op je bureaublad aan (antwoord **J**).
3. Start het spel.

Windows kan waarschuwen dat het bestand van internet komt: kies *Meer info* en *Toch uitvoeren*.

**Bijwerken**

Als er een nieuwere versie is, zegt de addon het in het spel ("Werk Dragonworld bij!"). Sluit het spel, dubbelklik op **Dragonworld Updater** op je bureaublad en start het spel opnieuw.

## For developers

- `Dragonworld/` is the addon. `tests/` runs it against a fake WoW API: `node tests/run.js Dragonworld` (run `npm install` in `tests` first).
- `tools/release.ps1` publishes a new version: tests, `Version.lua`, commit, tag, push, GitHub release with `Dragonworld.zip` and `Installer-Dragonworld.cmd`.
- `Installer-Dragonworld.cmd` downloads `Dragonworld/Updater/update.ps1` from this repository and runs it; the updater finds the game, installs the newest release and offers the desktop shortcut.
- The addons in the guild tell each other their version over addon messages, since an addon cannot read the internet; the one with an older version gets the update window.
