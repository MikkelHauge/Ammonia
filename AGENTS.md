# AGENTS.md

Ammonia is an ammo reminder for **WoW Forever 1.60.1** (`## Interface: 16001`)
and **Classic Era 1.15.9** (`## Interface: 11509`, partial support). The
repository root is the addon root: `Ammonia.toc` is here.

## Read first

- [`ammonia.md`](ammonia.md) - architecture, settings flow, decisions and the
  document's own change log. Every code change gets an entry there and in
  `CHANGELOG.md`.
- The workspace `AGENTS.md` - the workflow shared with Tally and Tongues.

## Shared workflow (all addons)

- The user tests manually in WoW Forever. Static checks never count as an
  in-game result; install the build and give a numbered test script.
- Back up the installed copy before replacing it:
  ```powershell
  Remove-Item -Recurse -Force D:\projects\Convenient\backups\Ammonia-previous -ErrorAction SilentlyContinue
  Copy-Item -Recurse -Force "G:\Games\World of Warcraft\_forever_\Interface\AddOns\Ammonia" "D:\projects\Convenient\backups\Ammonia-previous"
  ```
- Install only the addon files (`*.lua`, `*.toc`, `Core/`) to
  `G:\Games\World of Warcraft\_forever_\Interface\AddOns\Ammonia`.
  Never copy `.git`, docs, tooling or build output.
- New features and fixes use `feature/<short-name>` or `fix/<short-name>`,
  are installed and tested from that branch, and merge to `main` only after
  the user's test passes. `main` stays releasable.

## Ammonia rules

- CurseForge project `1765120`; game versions `16001` and `11509` only. No
  Retail and no Mists.
- The **pushed tag** triggers CurseForge; the GitHub release does not.
- Every user-facing message goes through the channel helpers and respects the
  global Text and Audio settings. A new feature needs:
  - a default in `DEFAULTS`,
  - its own settings row,
  - its own enable/disable switch,
  - and it must not bypass the channel helpers with a direct `AddMessage` or
    `PlayChime`.
- Warn at is 0-20,000 and Warn every is 0-2,000, with exact-value boxes; see
  `ammonia.md` for the 0 semantics.
- This client's Lua has **no `os` table**: use `date()` and `time()`.
- After `/reload` only `ADDON_LOADED` is raised; schedule checks from there.
- Combat-log reads are blocked on this client (the removed shot counter). Do
  not reintroduce them.
- Never commit the CurseForge webhook token.

## Checks

```powershell
foreach($f in @('Core.lua','UI.lua','Core\Ammo.lua','Core\Events.lua','Core\Reminders.lua')) {
  powershell -NoProfile -File D:\projects\Convenient\tools\check-lua.ps1 -Path $f
}
```
