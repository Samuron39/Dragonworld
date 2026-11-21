# Dragonworld

Guild addon for the guild **Dragonworld** in World of Warcraft Forever. English, Norsk, Nederlands.

Only characters in the guild Dragonworld can use it.

## English

**Install (first time)**

1. Download `Dragonworld.zip` from the [newest release](https://github.com/Samuron39/Dragonworld/releases/latest).
2. Unzip it into `World of Warcraft\_forever_\Interface\AddOns`, so that you get `AddOns\Dragonworld\Dragonworld.toc`.
3. Double-click `AddOns\Dragonworld\Updater\Dragonworld Updater.cmd` once and answer **Y** to put a shortcut on your desktop.
4. Start the game.

**Update**

When a newer version is out, the addon says so in the game ("Update Dragonworld!"). Close the game, double-click **Dragonworld Updater** on your desktop, and start the game again.

Windows may warn the first time you run the updater, because it was downloaded from the internet. It only downloads the newest `Dragonworld.zip` from this page and replaces the `Dragonworld` folder in your AddOns; your settings are kept.

## Norsk

**Installere (første gang)**

1. Last ned `Dragonworld.zip` fra [siste versjon](https://github.com/Samuron39/Dragonworld/releases/latest).
2. Pakk den ut i `World of Warcraft\_forever_\Interface\AddOns`, så du får `AddOns\Dragonworld\Dragonworld.toc`.
3. Dobbeltklikk `AddOns\Dragonworld\Updater\Dragonworld Updater.cmd` én gang og svar **J** for å få en snarvei på skrivebordet.
4. Start spillet.

**Oppdatere**

Når en nyere versjon er ute, sier addonen fra i spillet ("Oppdater Dragonworld!"). Lukk spillet, dobbeltklikk **Dragonworld Updater** på skrivebordet, og start spillet igjen.

## Nederlands

**Installeren (eerste keer)**

1. Download `Dragonworld.zip` van de [nieuwste versie](https://github.com/Samuron39/Dragonworld/releases/latest).
2. Pak hem uit in `World of Warcraft\_forever_\Interface\AddOns`, zodat je `AddOns\Dragonworld\Dragonworld.toc` krijgt.
3. Dubbelklik één keer op `AddOns\Dragonworld\Updater\Dragonworld Updater.cmd` en antwoord **J** voor een snelkoppeling op je bureaublad.
4. Start het spel.

**Bijwerken**

Als er een nieuwere versie is, zegt de addon het in het spel ("Werk Dragonworld bij!"). Sluit het spel, dubbelklik op **Dragonworld Updater** op je bureaublad en start het spel opnieuw.

## For developers

- `Dragonworld/` is the addon. `tests/` runs it against a fake WoW API: `node tests/run.js Dragonworld` (run `npm install` in `tests` first).
- `tools/release.ps1` publishes a new version: tests, `Version.lua`, commit, tag, push, GitHub release with `Dragonworld.zip`.
- The addons in the guild tell each other their version over addon messages, since an addon cannot read the internet; the one with an older version gets the update window.
