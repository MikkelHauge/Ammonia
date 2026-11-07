# Ammonia - release history

Ammonia is an ammo reminder for WoW Forever 1.60.1 (`## Interface: 16001`) and
Classic Era 1.15.9 (`## Interface: 11509`). It is not a Retail addon and is not
marked for Retail. Classic Era support is partial.

---

## 20261107.1 - 7 November 2026

**Added**

- Ammo use counter, stored per character: every shot and ranged ability use
  is counted against the ammo type in the slot at that moment. Multi-Shot and
  Volley count once per use, not once per target.
- The bottom of the settings window shows the totals (arrows, bullets, all)
  and one row per ammo type, most used first.
- `/ammonia shots` prints the current character's totals and the combat-log
  state, for checking the counter in game.

---

## 20261107 - 7 November 2026

First released build.

- Counts every stack of the equipped ammo type in your bags and warns in chat
  as it falls through the low-ammo steps.
- Reminds you when a bow, gun or crossbow is equipped with no compatible ammo,
  and repeats until it is fixed.
- Reminds you to stock up when you open a vendor that sells ammo, with an
  optional repeat cooldown, and points you elsewhere when the vendor has none.
- Optional login greeting showing the ammo left.
- Choose chat messages, a chime or both, with message colour, chime and volume
  settings; minimap icon for settings and a reminder toggle.
- Marked for WoW Forever and Classic Era only - no Retail, no Mists.
