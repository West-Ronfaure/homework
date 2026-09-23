# Homework (Horizon Server Approved by Horizon)

Weekly task tracker for FFXI Horizon Server.

This addon tracks your weekly objectives, ENM timers and Assault points. It was created specifically for Horizon Server due to differences in EcoWarrior mechanics and includes tracking for the custom Highwind NM and the Ashu Talif quest chain.

## Tracked Tasks
- Dynamis entry
- Limbus entry
- X'sKnife
- Ashu Talif chain (Scouting > Royal Painter Escort > Targeting the Captain)
- Assault tags, points and mercenary rank
- ISNM Imperial orders (2000 / 3000)
- EcoWarrior (with nation rotation)
- Highwind
- UnInvited
- CookBook
- SpiceGals

## Features
- Multi-character support
- Account-wide pooling for Dynamis entries, Limbus runs, and Assault tag stock
- Auto-detects progress via Key Items, NPC menus, and the quest log
- Dynamis glasses identified by serial number - re-entering on the same glass never double counts, even after a job change or disconnect
- ISNM daily buy-lock (resets at Japanese midnight) with holding state
- Ashu Talif: pay / fight / win / fail detection, including a stage paid before the weekly reset
- ENM timers, including the separate Mine Shaft Dial timer (Pulling the Strings / Automaton Assault)
- Auto-resets weekly
- **Assault tab**
  - Assault points for all five areas, read from the Currencies menu, the mission givers and assault wins - nothing is ever sent to the server
  - Mercenary rank from your Wildcat Badge, shown as an 11-step ladder
  - Each mission giver's reward list with prices: green stripe = buy it now, blue fill = how close your points are, greyed with a rank chip = not unlocked yet
  - Hover any reward for its in-game item card (icon, slot, stats, level, jobs)
  - Hover the Assault row on the Tasks tab for a quick view of all five totals; click it to open the tab
- ImGui window with a status icon per task:
  - filled dot - ready / go here
  - check mark - done this week (or on cooldown, for timers)
  - empty ring - still to do (or ready but key item not taken yet, for timers)
  - ring with `?` - unknown, needs a sync
  - `KI` badge - key item in your bag, fight open
  - ring with a number - Ashu Talif fight you are on
  - row of dots - Assault tags in stock
  - `You` / `Account` dots on Dynamis and Limbus - entries left for this character / for everyone on the account
  - EcoWarrior shows the three nation flags: colour with a green frame when that nation is open, grey when it is done this cycle, gold frame for the one in progress
- Chat commands print the same information with bracket icons: `[KI]`, `[  ]`, `[ x ]`, `[ ? ]`, and counts like `2/3` (remaining/max)

## Commands
- `/hw` - Toggle window (always opens on the Tasks tab)
- `/hw assault` - Assault points and rank in chat
- `/hw help` - Full command list

## Setup
- Copy the whole `homework` folder into `addons` - `homework.lua` **and** the `images` folder next to it. The `images` folder holds the EcoWarrior nation flags; without it the row falls back to plain text chips.
- Add `/addon load homework` to your `scripts/default.txt` file to load it automatically on startup. This addon relies on Key Item changes, NPC conversations, and quest log packets to track progress, so it must be running at all times.
- New install checklist (each is a one-time visit that syncs a tracker instantly):
  - Speak to Eeko-Weeko in Ru'Lude Gardens to initialize the EcoWarrior nation rotation.
  - Talk to Rytaal in Whitegate to pick up your Assault tag count.
  - Talk to Shajaf in Whitegate to sync the ISNM daily lock.
  - Pay Halshaob in Nashmau (or wait one weekly reset) to sync the Ashu Talif chain.
  - Open Menu > Status > Currencies once to sync your Assault points.
- Anything still showing `?` mid-week settles by itself at the next weekly reset.

<table><tr>
<td><img width="300" alt="Tasks" src="https://github.com/user-attachments/assets/7e3c57cb-519b-4e3f-8b22-89f5e75ea02d" /></td>
<td><img width="300" alt="Assault" src="https://github.com/user-attachments/assets/ca1ed4b0-7e26-4bf9-9908-fdeaae13f18a" /></td>
<td><img width="300" alt="Settings" src="https://github.com/user-attachments/assets/64ab18ba-c467-4bfa-8c32-acc15839fcff" /></td>
</tr><tr>
<td colspan="3"><img width="900" alt="Chat" src="https://github.com/user-attachments/assets/20115a2b-0500-4745-9903-4fe43f1416b7" /></td>
</tr></table>
