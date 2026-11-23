# WoW Forever: API notes

Things learned while building Dragonworld that are easy to get wrong. The game is **WoW Forever**, not retail or classic.

## Client

- Addons go in `World of Warcraft\_forever_\Interface\AddOns` (product `wowf`, 1.60.1). On the main development PC the game is in `D:\wow\World of Warcraft\_forever_`.
- TOC: `## Interface: 16001`. `WOW_PROJECT_ID` is 18 (`WOW_PROJECT_CAMELOT`).
- The API is the modern (Midnight-style) one, with secret values active: `TooltipDataProcessor`, `C_Container`, `C_QuestLog`, `C_Item`, `MenuUtil`. The old global `GetItemInfo` does not exist; use `C_Item.GetItemInfo`.
- `/reload` picks up Lua changes; a new file in the .toc or a new texture needs a full game restart.

## Where to check an API

- Blizzard's own UI code for Forever is mirrored at GitHub `Gethe/wow-ui-source`, branch `forever` (Forever-specific overrides in `Camelot/` subfolders; generated API docs in `Blizzard_APIDocumentationGenerated`, incomplete). Read a file with `gh api "repos/Gethe/wow-ui-source/contents/<path>?ref=forever" -H "Accept: application/vnd.github.raw"`; list files with `git/trees/forever?recursive=1`.
- The Warcraft Wiki API pages list a "forever" row per function.
- Other addons installed in the game's AddOns folder run on the live client, so grepping them confirms that a call or template exists.

## Facts

- **Names:** characters have first and last names ("Akro Polis") and there are no realms. The same name may be reported with or without the space, or as "Akro-Polis". Match people by GUID (17th value of `GetGuildRosterInfo`, `UnitGUID("player")`), or use `DW.IdentityKey` / `DW.SameCharacter` (Core.lua, Admin.lua). `DW.NameKey` keeps only the part before the first `-` and must not be used for identity.
- **`ReloadUI()` is protected:** called from addon code, even from a click, it fails with "Interface action failed because of an AddOn". Reload through a `SecureActionButtonTemplate` button with `type = "macro"`, `macrotext = "/reload"`, registered for up and down clicks (see Update.lua). Secure frames cannot be shown, hidden, moved or changed in combat; `PLAYER_REGEN_DISABLED` fires just before the lockdown.
- **Hardware events:** `DeleteCursorItem()` (one item per click), `C_Calendar.AddEvent()` (call from a click, never a timer; it returns nothing, and a refusal comes later as `CALENDAR_UPDATE_ERROR`), calendar invites (one character per click), `C_TradeSkillUI.OpenTradeSkill(skillLineID)` (one per click; the skill line is the 7th value of `GetProfessionInfo(index)`), `InviteUnit` and `ConvertToRaid`. `SetBinding` is blocked in combat.
- **Spec** means the two talent groups: `C_SpecializationInfo.GetActiveSpecGroup()`, `GetNumSpecGroups()`, event `ACTIVE_TALENT_GROUP_CHANGED`.
- **Talents:** the old functions (`GetNumTalentTabs`, `GetTalentTabInfo`, `GetTalentInfo`) do not exist. The talent window is a trait tree: `C_ClassTalents.GetActiveConfigID()` (or `C_SpecializationInfo.GetCombatConfigIDForSpecGroup`), `C_Traits.GetConfigInfo(config).treeIDs[1]`, `GetGroupDisplayInfoByTreeID`, `GetTreeNodes`, `GetNodeInfo` (ranksPurchased/activeRank, groupIDs), entry -> definition -> spellID. `ForeverDungeonJournal\Systems\CharacterSnapshot.lua` is a working reference.
- **Bank:** containers 6-14 (`Enum.BagIndex.CharacterBankTab_N`), keyring -1. Read the bank only between `BANKFRAME_OPENED` and `BANKFRAME_CLOSED`.
- **Guild bank:** `GetGuildBankItemInfo`, `GetGuildBankItemLink`, `GetGuildBankTabInfo`, `GetGuildBankMoney`, events `GUILDBANKBAGSLOTS_CHANGED` (no payload) and `PLAYER_INTERACTION_MANAGER_FRAME_SHOW` (GuildBanker = 10) exist. `QueryGuildBankTab`, `GetNumGuildBankTabs`, `GetCurrentGuildBankTab` are unconfirmed (`/dw debug` shows whether they exist). A tab not yet received reads exactly like an empty tab.
- **Guild:** `GetGuildInfo("player")` can be nil right after login. The guild message of the day: `C_GuildInfo.GetMOTD` first.
- **EditBox:** `SetMaxBytes(n)` lets only n - 1 bytes in. Use `SetMaxLetters(n)` for an exact character count.
- **Professions:** confirmed in game: `C_TradeSkillUI.GetAllRecipeIDs`, `GetRecipeInfo(id).learned`, `GetRecipeSchematic` while your own profession window is open. `C_TradeSkillUI.GetTradeSkillListLink()` gives `|Htrade:<playerGUID>:<spellID>:<skillLineID>|h[Name]|h`, but opening another player's profession link did nothing between two guildmates. `GetBaseProfessionInfo()` also describes a linked profession: check `IsTradeSkillLinked()`. The professions frame shows only professions where `C_TradeSkillUI.CanTradeSkillShowCraftingUI(spellID)` is true, so gathering professions have no recipe window.
- **Legacy points** (account-wide, "Legacy Points 2 / 65"): no documented API; third-party addons read them as `C_MajorFactions.GetCurrentRenownLevel(2802)`, max `C_Traits.GetMaxAvailableTraitCurrency(4225, false)`. `GetTotalAchievementPoints()` is not it. Not confirmed in Dragonworld.

## Profession data (Wowhead)

Wowhead's Forever profession leveling guides load their data from two JSON endpoints that `curl`/Node `fetch` can read with a browser User-Agent:

- `https://www.wowhead.com/forever/profession-leveling-guides/catalog?skill=<skillLine>`: every recipe (spell, skill colours, reagents, created item, trainer/vendor/drop/quest source) plus items and vendors.
- `https://www.wowhead.com/forever/profession-leveling-guides/guides?skill=<skillLine>`: the leveling guides; the one with `official: true` is "Tried & Tested in Forever".

Skill lines with guides: 171 Alchemy, 164 Blacksmithing, 333 Enchanting, 202 Engineering, 165 Leatherworking, 197 Tailoring, 185 Cooking, 129 First Aid. `tools\make_profession_data.js` turns this into `Dragonworld\Modules\ProfessionData.lua`. Forever has its own items and recipes, so classic data is no substitute.
