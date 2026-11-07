# Ammonia
Ammonia is a WoW Forever addon aimed at hunters, and warriors and rogues who use a bow, gun or crossbow should give it a shot as well.

Built for **WoW Forever**. It is not supported on Retail, and Classic Era support is partial.

What it does is, provide the player with notifications (in chat) about their ammo needs.

* **Low ammo** - as your ammo falls to a new step (400, 350, 300), it prints a line such as “Low ammo: 350 bullets left”. This is based on remaining ammo, not a shot counter, and it can happen in or out of combat.
* **Missing or wrong ammo** - if a bow, gun or crossbow is equipped but the ammo slot has no compatible ammo, it reminds you 15 seconds after login or equipping the weapon, and again every five minutes until fixed.
* **Ammo vendor** - when you open a vendor that sells ammo while a ranged weapon is equipped, it reminds you to stock up. Once per vendor visit, an optional cooldown limits repeats across visits. (Default 30 sec)
* **Other vendors** - if you are low and open a vendor that does not sell ammo, it tells you to find one that does.
* **Login greeting** - optionally tells you how much ammo you have left when you log in or reload.

It adds up every stack of the same ammo item in your bags. If you carry more than one type of the firing ammo, it shows the equipped type and the spare types separately.

You can choose chat messages, a chime, or both for the vendor, other-vendor and missing-ammo reminders; choose the message colour, chime and volume; edit the vendor reminder text; and adjust the low-ammo start and step. The minimap icon opens the settings with left-click and switches reminders on or off with right-click.

Ammonia does not buy ammo, does not know where another vendor is, and does not count bank, mail or auction stock. It supports bows, guns and crossbows only.

## Examples:

<img width="190" height="65" alt="{7D5CF459-2A50-4672-905C-F5DFEC8E389E}" src="https://github.com/user-attachments/assets/127e88f0-b071-45ad-9baf-41740a9bfefd" />

<img width="198" height="60" alt="{0042B365-8215-46D2-ABF8-6B419567493F}" src="https://github.com/user-attachments/assets/dbb94ddd-df50-45c7-8191-35420cb0291d" />

Stacks of the same ammo item are added together, so reminders will not just include your currently equipped arrows.

In-combat notifications, fires every X shot (customizable)

<img width="481" height="179" alt="low ammo - in combat" src="https://github.com/user-attachments/assets/ebfeca1a-b161-454e-83e9-c5bb23342a33" />

General low on ammo reminder:

<img width="364" height="33" alt="ammonia reminder buy ammo" src="https://github.com/user-attachments/assets/3af7ea5b-c744-4cb3-9aa2-27cd9f896dd7" />

When no ammo is equipped (the (arrows 174 indicates we got 174 in our bags, but 'ammo' slot is empty.

<img width="144" height="103" alt="{3131F1DC-DDED-4DFA-BA6F-60354F3C9D9C}" src="https://github.com/user-attachments/assets/fa300398-3d85-4d8d-ad75-8520c9cb8c51" />

<img width="436" height="28" alt="{095EA628-3717-49FC-91A9-B6E7CEF92FF0}" src="https://github.com/user-attachments/assets/8d67ef6c-c729-4c88-a7d9-cb2362a310cc" />


Talking to an NPC that does not sell ammo:

<img width="493" height="26" alt="ammonia-wrongvendor" src="https://github.com/user-attachments/assets/f5717038-777f-4ced-897d-40c041b1d8f3" />

You can customize most of these, incl adding a audible notification chrime, in the addons settings.

<img width="816" height="1811" alt="ammonia-settingsfull" src="https://github.com/user-attachments/assets/e98434b2-be04-4481-8350-5567235d6989" />



## How it works

It reads the ammo-slot and equipped bow/gun/crossbow, and counts available ammo in your bags. 
### Available commands:

/ammonia              open settings

/ammonia on|off|toggle

/ammonia test         show the current vendor reminder

/ammonia warn         show a low-ammo warning

/ammonia ammo         print the ammo diagnostic report

/ammonia vendors      toggle vendor reminders

/ammonia missing      toggle missing-ammo reminders

/ammonia vendorwarn   toggle low-ammo warnings at other vendors

/ammonia reset        reset the minimap icon position
