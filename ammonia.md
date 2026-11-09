# Ammonia - architecture, decisions and change log

This is the working document for Ammonia. The player-facing release notes live
in `CHANGELOG.md`; this file explains how the addon is put together, why the
settings look the way they do, and what changed when.

**Every update must update two places:**

1. `CHANGELOG.md` - what players will notice.
2. The **Change log** at the bottom of this file - what changed in the code
   and which decision was made.

---

## Architecture at a glance

```
game events + 1-second watch
        |
        v
Core/Events.lua            triggers: bags, inventory, merchants, login
        |
        v
Core/Reminders.lua         decisions: staircase, missing ammo, vendors
        |
        +--> Core/Ammo.lua reads: bags, ammo slot, item classification
        |
        v
AmmoniaDB                  settings + per-character/session state
        |
        v
UI.lua                     settings window + minimap icon
        |
        v
output                     chat / chime, through the channel helpers
```

- **State:** `AmmoniaDB` for settings, plus session locals for the staircase
  level, whether real ammo has been seen, the greeting and per-visit flags.
- **Detection:** `Core/Ammo.lua` turns client reads into `kind, types,
  equipped count`.
- **Decision:** `Core/Reminders.lua` decides whether a warning is due; it does
  not touch the UI.
- **Triggers:** `Core/Events.lua` wires game events and the 1-second watch to
  those decisions.
- **Presentation:** `UI.lua` reads state and writes settings; it never does
  detection itself.
- **Output:** every chat line and chime goes through the channel helpers, so
  the global Text/Audio switches stay authoritative.

The detailed layers are in sections 3-6 below.

---

## 1. What Ammonia is

Ammo reminder for **WoW Forever 1.60.1** (`## Interface: 16001`) and
**Classic Era 1.15.9** (`## Interface: 11509`, partial support).

It counts the ammo the equipped ranged weapon fires, warns in steps as it
runs low, reminds you to restock at vendors, warns when the ammo slot is
missing or holds the wrong type, and optionally greets you with the count on
login.

Stored locally in `AmmoniaDB`. Nothing is shared.

---

## 2. Repository and file map

Load order is the order in `Ammonia.toc`:

| File | Responsibility |
| --- | --- |
| `Core.lua` | Shared helpers, colours, chime, `DEFAULTS`, `ApplyDefaults`, master switch. |
| `Core/Ammo.lua` | Item classification, bag counting, ammo-slot reads, equipped-type detection, `/ammonia ammo`. |
| `Core/Reminders.lua` | Low-ammo staircase, missing-ammo checks, vendor reminders, greeting, cooldown state. |
| `Core/Events.lua` | Event frame, 1-second watch, slash commands. |
| `UI.lua` | Minimap icon, settings window, every row/slider/edit box. |
| `.pkgmeta` | CurseForge packaging: `package-as: Ammonia`, docs excluded. |
| `CHANGELOG.md` | Player-facing release history. |
| `AGENTS.md` | Rules for agents working on the addon. |
| `ammonia.md` | This document. |

`AGENTS.md`, `ammonia.md`, `README.md`, `LICENSE` and `CHANGELOG.md` are
ignored by `.pkgmeta` and never ship in the addon zip.

---

## 3. Settings and saved data

`AmmoniaDB` is the saved variable table, assigned to `ns.db`. `ApplyDefaults`
fills missing keys from `DEFAULTS`; tables recurse one level deeper. Existing
values are never overwritten.

Current `DEFAULTS` (in load order as written in `Core.lua`):

| Key | Default | Meaning |
| --- | --- | --- |
| `enabled` | `true` | Master switch (also right-click the icon). |
| `chatAlert` | `true` | Show reminder text in chat. |
| `showAmmoCount` | `true` | Append the ammo count to reminder text. |
| `greetOnLoad` | `true` | Greet with the count on login/reload. |
| `vendorReminder` | `true` | "Buy ammo" line at ammo vendors. |
| `remindMissingAmmo` | `true` | Warn when the ammo slot is empty/wrong. |
| `warnLowAmmo` | `true` | Low-ammo staircase master (to be replaced by `warnWhen`). |
| `vendorLowAmmo` | `true` | Low-ammo warning at vendors that do not sell ammo. |
| `warnBelow` | `400` | Warn at this count and below. |
| `warnStep` | `50` | Distance between steps. |
| `reminderText` | `ns.DEFAULT_REMINDER_TEXT` | The vendor reminder wording. |
| `colourKey` | `"yellow"` | Chat colour. |
| `chime` | `"PING"` | Chime selection. |
| `volume` | `0.8` | Chime volume. |
| `useCooldown` | `true` | Limit repeat vendor reminders. |
| `cooldown` | `30` | Seconds between vendor reminders. |
| `icon.shown` | `true` | Minimap icon visible. |
| `icon.locked` | `false` | Icon position locked. |
| `icon.angle` | `180` | Degrees around the minimap. |

`icon.ringRevision` is a one-time migration (not in `DEFAULTS`) that moved
old saves from a free-floating icon to the minimap ring.

### Planned settings (approved design, not built yet)

| Key | Default | Meaning |
| --- | --- | --- |
| `chimeAlerts` | `true` | Global **Audio reminders** master (new). |
| `warnWhen` | `"both"` | Low-ammo staircase mode: `"both"`, `"combat"`, `"out"`, `"off"`. |

- `chatAlert` is relabelled **Text reminders** and becomes the global text
  master.
- Old `warnLowAmmo = false` migrates to `warnWhen = "off"`; `true`/missing
  becomes `"both"`.
- The low-ammo dropdown sits with the Warn at / Warn every sliders.
  `Disable warnings` is rendered red. Values keep their numbers while
  disabled.
- The staircase obeys **global channel AND mode**: text = `chatAlert` and
  mode allows, sound = `chimeAlerts` and mode allows.
- `Warn at 0` warns only at an empty quiver. `Warn every 0` gives the first
  warning only, with no repeats.
- `Warn at` range 0-20,000; `Warn every` 0-2,000; both have exact-value
  boxes. 20,000 is 100 stacks of 200, beyond realistic carry capacity.
- `Warn at other vendors` keeps its own checkbox and uses the global
  channels; it is a low-ammo warning, so it is also muted when the mode
  excludes the current state (vendors are out of combat, so `In Combat`
  mutes it).

---

## 4. Runtime flow

### Login and setup

1. `ADDON_LOADED` for `Ammonia`: create `AmmoniaDB` if missing, assign
   `ns.db`, run `ApplyDefaults`, apply the icon migration, build the UI.
2. No `PLAYER_LOGIN` handler; after `/reload` this client only raises
   `ADDON_LOADED` (see quirks).

### Event frame (`Core/Events.lua`)

| Event | Action |
| --- | --- |
| `ADDON_LOADED` | Initialize DB/defaults and UI. |
| `MERCHANT_SHOW` | Reset per-visit flags; `TryReminder`; schedule the low-ammo vendor check after 1s. |
| `MERCHANT_UPDATE` | `TryReminder` again; schedule the vendor check again. |
| `MERCHANT_CLOSED` | Invalidate the scheduled merchant check. |
| `BAG_UPDATE` | `CheckLowAmmo`. |
| `PLAYER_ENTERING_WORLD` | `CheckLowAmmo`; schedule the 15s missing-ammo check; reapply icon position. |
| `UNIT_INVENTORY_CHANGED` (player) | `CheckLowAmmo`; reschedule the missing-ammo check (weapon swap). |
| `PLAYER_LOGOUT` | Restore the dialog volume used for the chime. |

All handlers run through `pcall`; one failing event is reported once and does
not interrupt the game.

### 1-second watch

- `TickMissingAmmo(delta)` every frame: counts toward the 5-minute
  missing-ammo repeat.
- Every second: `CheckLowAmmo` if `enabled` and (`warnLowAmmo` or
  `greetOnLoad`). The staircase only speaks on a new step, so this never
  becomes a timer message.

### Low-ammo staircase (`CheckLowAmmo`)

State:

- `announcedLevel` - last spoken level; `nil` = fully armed.
- `sawRealAmmo` - a real ammo stack has been seen this session.
- `greetedThisSession` - the login greeting has run.

Algorithm:

1. If disabled, reset `announcedLevel` and return.
2. If warnings are off and the greeting is done, reset and return.
3. `GetFiringAmmo()` gives the kind and the equipped type. No ranged weapon
   -> reset and return.
4. `count` = equipped type total. If `count == 0` and no real ammo has been
   seen, return (bags may still be loading).
5. `start = warnBelow`, `step = warnStep`.
   - `step < 1`: the only level is `start` (first warning only).
   - else `level = ceil(count / step) * step`, clamped to `start`.
6. First look of the session: greet if enabled, then start the staircase from
   this level.
7. If `count > start`: reset `announcedLevel` (restocked).
8. If `announcedLevel` is nil or `level < announcedLevel`: speak and store
   the level.
9. If `level > announcedLevel`: silently climb (small top-up), re-arming the
   steps above.

`FireLowAmmoWarning` says `You are out of arrows!` at 0, otherwise
`Low ammo: N bullets/arrows left` (plus the type split when several types are
carried).

### Missing or wrong ammo (`CheckEquippedAmmo`)

- Conditions: `enabled`, `remindMissingAmmo`, a ranged weapon equipped, and
  no compatible ammo in the ammo slot (item ID or count missing, or the item
  classifies as the other kind).
- First check 15 seconds after login or equipping; repeats every 5 minutes
  while unresolved (`TickMissingAmmo`).
- State: `missingAmmoReminded`, `missingAmmoRepeatElapsed`,
  `missingAmmoCheckGeneration` (invalidates older scheduled checks).

### Vendor reminders

- `TryReminder` (ammo vendor): `enabled`, `vendorReminder`, not already
  reminded this visit, cooldown satisfied, ranged weapon equipped, merchant
  sells ammo. Fires the editable text + count, once per visit.
- `TryLowAmmoMerchantWarning` (other vendor): `enabled`, `warnLowAmmo`,
  `vendorLowAmmo`, not already warned this visit, merchant does not sell
  ammo, count <= `warnBelow`. Fires `You're low on Ammo, find a merchant that
  sells it`. Scheduled 1 second after `MERCHANT_SHOW`/`MERCHANT_UPDATE` so the
  merchant stock has time to load.

### Greeting

Once per session, on the first real ammo reading, if `greetOnLoad`:
`Ammonia enabled - You have N bullets left`.

---

## 5. Ammo detection (`Core/Ammo.lua`)

- `ClassifyAmmo(itemID, hyperlink)`:
  - `GetItemInfo` via `C_Item` or the global function.
  - Class must be `6` (Projectile) when the class is known.
  - Name must contain `arrow` -> `"arrow"`, or `bullet`/`shot` -> `"bullet"`.
- `CountCarriedAmmo()` scans bag `0` through
  `NUM_BAG_SLOTS + NUM_REAGENTBAG_SLOTS` via `C_Container` and sums arrows and
  bullets.
- `CollectAmmoTypes(kind)` groups bag stacks by item ID and decides the
  equipped type:
  1. the ammo-slot item ID (`GetInventoryItemID("player", INVSLOT_AMMO)`),
  2. the type whose bag total last dropped (`observedEquipped`),
  3. the smallest stack (`fallback`).
- `GetAmmoSlotCount()` reads `GetInventoryItemCount("player", INVSLOT_AMMO)`;
  `GetAmmoSlotItemID()` reads `GetInventoryItemID`. Both return nil when the
  slot is empty or unreadable.
- `GetAmmoSummary()` / `AmmoTypeListText()` build the message counts; when
  several types are carried, the equipped count comes from the ammo slot and
  the other types are listed as "spare".
- `ns.GetFiringAmmo()` returns `kind, types, equipped`.
- `/ammonia ammo` prints the slot, the equipped guess and every ammo stack
  in the bags; use it to check what the client actually reports.

Known risk: if this client keeps the firing stack only in the ammo slot and
not in the bags, the staircase counts spare bags only (or zero). Verify with
`/ammonia ammo` before changing the count logic. The planned fix is to make
the ammo-slot count the authoritative firing stack and add spare bag stacks.

---

## 6. Reminder paths and channels

Current code:

| Path | Chat | Chime | Notes |
| --- | --- | --- | --- |
| `FireReminder` (vendor) | if `chatAlert` | always | One helper for the vendor reminder. |
| `FireLowAmmoWarning` (steps) | always | **never** | Ignores `chatAlert`; no sound. |
| `FireAmmoGreeting` | always | never | Ignores `chatAlert`. |
| `TryLowAmmoMerchantWarning` | always | always | Ignores `chatAlert`. |
| `CheckEquippedAmmo` (missing) | via `FireReminder` | always | Respects `chatAlert` for text. |

This is the inconsistency the planned channel model fixes.

Planned model:

- Global **Text reminders** (`chatAlert`) and **Audio reminders**
  (`chimeAlerts`) are the channel masters. Every message goes through them.
- Each feature keeps its own enable switch on top; effective channel =
  global master AND feature switch.
- Low-ammo adds the `warnWhen` mode (`both` / `combat` / `out` / `off`) and
  uses `UnitAffectingCombat("player")`. `PLAYER_REGEN_DISABLED` and
  `PLAYER_REGEN_ENABLED` trigger an immediate check.
- `Disable warnings` resets `announcedLevel`, so re-enabling warns at the
  current step.
- The greeting follows the global text master and its own `greetOnLoad`.

---

## 7. Decisions

1. **Targets:** WoW Forever 1.60.1 (`16001`) and Classic Era 1.15.9
   (`11509`, partial). No Retail, no Mists.
2. **Counting scope:** carried ammo only. Bank, mail and auction stock are
   deliberately excluded.
3. **Staircase:** the first reading is a baseline; warn at Warn at and every
   Warn every below it; restocking above Warn at re-arms the staircase.
4. **Warn at 0:** warn only when the quiver is empty. **Warn every 0:** first
   warning only, no repeats.
5. **Limits:** Warn at 0-20,000 (100 stacks of 200); Warn every 0-2,000.
   Exact-value boxes override the slider step.
6. **Missing ammo:** first check 15 seconds after login/equip; repeat every
   5 minutes while unresolved.
7. **Vendors:** ammo-vendor reminder once per visit with optional cooldown;
   low-ammo-at-other-vendor once per visit.
8. **Channels:** global Text/Audio masters; per-feature switches compose with
   AND; no feature may call `AddMessage`/`PlayChime` directly.
9. **Low-ammo control:** `Warn when` dropdown (`Both` default, `In Combat`,
   `Out of Combat`, red `Disable warnings`), values retained while disabled.
10. **No shot-count statistic:** removed because this client blocks
    combat-log reads (`ADDON_ACTION_BLOCKED`). Do not reintroduce it without a
    safe, non-protected method.
11. **Client quirks:** no `os` table (`date()`/`time()`); only
    `ADDON_LOADED` after `/reload`; item info and the ammo slot can lag at
    login.
12. **Packaging:** docs stay out of the addon zip via `.pkgmeta`; the GitHub
    zip includes README/LICENSE.
13. **Versioning/release:** `YYYYMMDD[.N]`, lightweight tag `v...`; the tag
    push triggers CurseForge; GitHub release notes are separate.
14. **Workflow:** the user tests manually in game; back up the installed
    version before every install; features/fixes use branches and merge to
    `main` only after the user's test passes.

---

## 8. Adding a new feature

1. **Branch:** `git switch -c feature/<short-name>` (or `fix/<name>`).
2. **Defaults:** add the new setting to `DEFAULTS`; if an old key changes
   meaning, add a one-time migration next to the `icon.ringRevision` pattern.
3. **Settings row:** add it to the right section in `UI.lua`; if it has a
   value, give it the same slider/edit-box treatment where useful.
4. **Channels:** route every message through the channel helpers. The new
   feature must respect the global Text/Audio masters and get its own
   enable/disable switch. Never add a direct `AddMessage` or `PlayChime`.
5. **State:** keep values when the feature is muted; only suppress output.
6. **Data:** store per-character data under `AmmoniaDB`; document the shape
   here.
7. **Diagnostics:** if it depends on client data, add a `/ammonia ...`
   command that prints what the client actually reports.
8. **Checks:** run the Lua checker over every TOC file.
9. **Install:** back up the installed folder, copy the branch build, give the
   user a numbered in-game test script.
10. **After the test passes:** merge to `main`, bump `## Version:`, update
    `CHANGELOG.md` and this document's Change log, then tag and release.

---

## 9. Client quirks that have caused real bugs

- No `os` table in Lua: use the game's `date()` and `time()`.
- After `/reload` only `ADDON_LOADED` is raised; schedule login checks from
  there as well as `PLAYER_ENTERING_WORLD`.
- Combat-log reads are blocked; the experimental shot counter produced
  "Ammonia has been blocked from an action only available to the Blizzard UI"
  and was removed.
- Item info and the ammo slot can be empty for a moment after login;
  `sawRealAmmo` treats the first zero as "not known yet".
- Ammo in the bank, mail or auction house is not counted, by design.
- `SetNumeric` on edit boxes is guarded for clients that lack it.

---

## 10. Release notes

- CurseForge project `1765120`; game versions `16001` + `11509` only.
- Version `YYYYMMDD[.N]` in `Ammonia.toc`; tag `vYYYYMMDD[.N]`.
- Commit and push `main`, then push the tag. The tag push triggers the
  CurseForge webhook.
- `.pkgmeta` packages as `Ammonia` and excludes README, LICENSE, CHANGELOG,
  AGENTS and this file.
- GitHub release: include `README.md` and `LICENSE` in the zip; attach the
  zip to the release.
- CurseForge files sit in processing for 10-20 minutes and are hidden from
  the public API until approved.
- Project creation, API token and webhook are manual; see the generic
  procedure in `Tally/RELEASE.md`.

---

## 11. Change log (this document)

Newest first. Every code change gets an entry here, in addition to
`CHANGELOG.md`.

### 2026-11-09 - documentation and workflow

- Created `ammonia.md`, `AGENTS.md` and the shared workspace `AGENTS.md`.
- Recorded the decisions above, the pending channel/`warnWhen` design, and
  the workflow rules: manual in-game testing, install path, one backup,
  feature branches.
- `.pkgmeta` now excludes `AGENTS.md` and `ammonia.md`.

### 2026-11-09 - 20261109 (staged, not yet tagged)

- Warn at slider 0-20,000; Warn every 0-2,000; exact-value boxes on both.
- Warn at 0 warns only at empty; Warn every 0 gives the first warning only.
- Greeting no longer suppresses the empty warning at Warn at 0.

### Pending - channel masters and `Warn when`

- Global Text (`chatAlert`) and Audio (`chimeAlerts`) masters.
- `warnWhen` dropdown at the sliders: `Both` / `In Combat` /
  `Out of Combat` / red `Disable warnings`, values retained.
- All reminder paths obey the global channels; low-ammo finally chimes and
  respects the text toggle.

### 2026-11-07 - 20261107.1

- Removed the experimental ammo-use counter. The combat-log read is blocked
  on this client and produced a blocked-action message. Behaviour otherwise
  identical to 20261107.

### 2026-11-07 - 20261107

- First released build: ammo counting, low-ammo steps, missing/wrong ammo,
  vendor reminders, login greeting.
