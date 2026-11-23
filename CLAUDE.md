# Dragonworld: notes for Claude sessions

Guild addon for the guild Dragonworld in World of Warcraft Forever (interface 16001, modern API). The addon is in `Dragonworld/`, with its tabs in `Dragonworld/Modules/`. The guild leader is not a programmer: talk to them in Norwegian, in plain words.

## Code

- Comments in the code are in English (guild members read the public code). Norwegian names stay: modules and files (Forslag, Ryddesekk, Materialer), saved-data fields, quoted UI text.
- All UI text goes in `Dragonworld/Locales.lua`, in every language in `DW.LANGUAGES`: English, Norwegian, Dutch, German, Danish, Swedish and French (`en`, `nb`, `nl`, `de`, `da`, `sv`, `fr`). The tests fail if a text is missing in one of them or its `%s` placeholders or colour codes differ. Keep placeholders in the same order (`string.format` cannot reorder them), and keep slash commands as they are.
- There is no Norwegian, Dutch, Danish or Swedish WoW client, so those players see the game in English: keep the game's English names for its windows and items there, and the gamer words they use (guild, dungeon, raid, loot). German and French use the terms of Blizzard's German and French clients.
- `Dragonworld/Updater/update.ps1` must keep working in PowerShell's Constrained Language Mode: with Smart App Control on, Windows runs it that way (and blocks `Installer-Dragonworld.cmd`; those players paste the line from README.md into a Windows PowerShell window, which works without administrator. Not Windows + R: Windows stopped PowerShell started from there on a test laptop). Use PowerShell's own commands; .NET calls, `Add-Type` and COM only inside `try` with a fallback. Test with Windows PowerShell 5.1 (`powershell.exe`, not `pwsh`) from a session where `$ExecutionContext.SessionState.LanguageMode = 'ConstrainedLanguage'`, against a temporary `-AddOns` folder.

## WoW Forever API

`docs/forever-api.md` lists what is known about the Forever client: where Blizzard's Forever UI source is, how names work (first and last name, no realms: compare people with `DW.SameCharacter`, never `DW.NameKey`), protected calls, and API facts that differ from retail and classic. Read it before using an API the addon does not already use, and add to it when you learn something new in the game.

## Tests

- `node tests\run.js Dragonworld` runs the addon against a fake WoW API (`tests\harness.lua`). It must pass with 0 failures.
- The harness's main chunk is at Lua's limit of 200 local variables: put new test sections in `;(function() ... end)()`, and new fake state in globals.

## Testing in the game

Copy the changed files to `D:\wow\World of Warcraft\_forever_\Interface\AddOns\Dragonworld`. Never copy `Version.lua`: its `DW.RELEASE` may only change when a version is released, and the game's copy may have `DW.AUTO_UPDATE = true`. A new file or a changed file list in the `.toc` needs a full restart of the game; otherwise `/reload` is enough.

## Releasing a version

Only when the user asks for it ("legg ut"). Several sessions may work in this folder at once, and the release commits everything in it (`git add -A`): check `git status` first, and ask before releasing work from other sessions that is still in progress.

From PowerShell:

```powershell
& tools\release.ps1 -News @{ en = '...'; nb = '...'; nl = '...'; de = '...'; da = '...'; sv = '...'; fr = '...' } -Notes $notes
```

- `-News` (required): what is new in this version, in a sentence or two for every language in `DW.LANGUAGES` (the script reads the list from Locales.lua and stops if one is missing), at most 220 bytes each and no `|`. Members with an older version see it in the update window in the game ("Nytt i 0.24.0: ..."), and everyone sees it once in chat after updating. Write it for players: what they will notice, not how it is built. Use the names of tabs and buttons as the addon shows them in that language (look them up in Locales.lua, for example `RO_TITLE`: Roster / Medlemmer / Leden).
- `-Notes`: the longer English text for the GitHub release page. Without it, the English news is used.

The script runs the tests, writes `Version.lua` (`DW.RELEASE`, `DW.RELEASED_AT`, `DW.RESTART_RELEASE`, `DW.RELEASE_NEWS`), commits, tags, pushes, creates the GitHub release and installs the version in the game.

## A new PC

The user works on more than one PC; the code moves through GitHub (`git pull` / `git push`), not by copying folders. On a PC where the repository was just cloned:

- Set the repository's git identity before the first commit, or the user's private email goes into the public repo: `git config user.name Samuron39` and `git config user.email 208341369+Samuron39@users.noreply.github.com`.
- `npm install` in `tests` (node_modules is not in git).
- Releasing needs `gh auth login` (GitHub account Samuron39).
- Find the game folder (`World of Warcraft\_forever_\Interface\AddOns`) on that PC; it may not be on `D:\wow`. Use it wherever this file says `D:\wow\...`. `tools\release.ps1` installs only into `D:\wow\...` and skips that step when the folder does not exist, so copy the release into the game by hand there.
- `intro-page/` and `dist/` are not in git.

## Privacy

The repository is public. Never commit the user's personal email address (git in this folder uses the GitHub noreply address), and never write passwords or codes the user gives you into any file.
