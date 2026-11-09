# Ammonia - release history

Ammonia is an ammo reminder for WoW Forever 1.60.1 (`## Interface: 16001`) and
Classic Era 1.15.9 (`## Interface: 11509`). It is not a Retail addon and is not
marked for Retail. Classic Era support is partial.

---

## 20261109 - 9 November 2026

**Changed**

- The "Warn at" slider now runs from 0 to 20,000 (100 stacks of 200) and
  "Warn every" from 0 to 2,000. Both rows have a number box on the right for
  an exact value, whatever the slider step.
- Warn at 0 warns only when the quiver is empty. Warn every 0 gives the first
  warning only, with no repeats on the way down.

---

## 20261107.1 - 7 November 2026

Rebuild. Removed the experimental ammo-use counter: this client blocks addons
from reading the combat log, which produced the "blocked from an action only
available to the Blizzard UI" message. Ammo counting and every reminder are
unchanged from 20261107.

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
