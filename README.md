# Homework (Horizon Server Approved by Horizon)

Weekly task tracker for FFXI Horizon Server.

This addon tracks your weekly objectives and ENM timers. It was created specifically for Horizon Server due to differences in EcoWarrior mechanics and includes tracking for the custom Highwind NM and the Ashu Talif quest chain.

## Tracked Tasks
- Dynamis entry
- Limbus entry
- X'sKnife
- Ashu Talif chain (Scouting > Royal Painter Escort > Targeting the Captain)
- Assault tags
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
- ImGui window and chat commands, same icons in both:
  - `[KI]` in your bag - fight open
  - `[  ]` ready, not taken yet
  - `[ x ]` done or on cooldown
  - `[ ? ]` unknown - needs a sync
  - counts like `2/3` are remaining/max

## Commands
- `/hw` - Toggle window
- `/hw help` - Full command list

## Setup
- Add `/addon load homework` to your `scripts/default.txt` file to load it automatically on startup. This addon relies on Key Item changes, NPC conversations, and quest log packets to track progress, so it must be running at all times.
- New install checklist (each is a one-time visit that syncs a tracker instantly):
  - Speak to Eeko-Weeko in Ru'Lude Gardens to initialize the EcoWarrior nation rotation.
  - Talk to Rytaal in Whitegate to pick up your Assault tag count.
  - Talk to Shajaf in Whitegate to sync the ISNM daily lock.
  - Pay Halshaob in Nashmau (or wait one weekly reset) to sync the Ashu Talif chain.
- Anything still showing `[ ? ]` mid-week settles by itself at the next weekly reset.

<table><tr>
<td><img width="330" alt="Tasks" src="https://github.com/user-attachments/assets/069b3533-ab3e-473a-a7f0-53e7ebd2eb9d" /></td>
<td><img width="330" alt="Settings" src="https://github.com/user-attachments/assets/610a2991-a6c5-451d-ac7d-3fd83034a761" /></td>
</tr><tr>
<td colspan="2"><img width="670" alt="Chat" src="https://github.com/user-attachments/assets/20115a2b-0500-4745-9903-4fe43f1416b7" /></td>
</tr></table>
