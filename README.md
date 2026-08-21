# Homework (Horizon Server Approved by Horizon)

Weekly task tracker for FFXI Horizon Server.

This addon tracks your weekly objectives and ENM timers. It was created specifically for Horizon Server due to differences in EcoWarrior mechanics and includes tracking for the custom Highwind NM.

## Tracked Tasks
- Dynamis entry
- Limbus entry
- Assault tags
- EcoWarrior (with nation rotation)
- Highwind
- UnInvited
- CookBook
- SpiceGals
- X'sKnife

## Features
- Multi-character support
- Account-wide entry pooling for Dynamis and Limbus
- Auto-detects progress via Key Items
- Auto-resets weekly
- ENM timers
- ImGui window and chat commands

## Commands
- `/hw` - Toggle window
- `/hw help` - Full command list

## Setup
- Add `/addon load homework` to your `scripts/default.txt` file to load it automatically on startup. This addon relies on Key Item changes and NPC conversations to track progress, so it must be running at all times.
- Speak to Eeko-Weeko in Ru'Lude Gardens once to initialize the EcoWarrior nation rotation.
- Talk to Rytaal once to pick up your Assault tag count.
- Counts start as unknown mid-week and settle at the next weekly reset.

<table><tr>
<td><img width="330" alt="Tasks" src="https://github.com/user-attachments/assets/069b3533-ab3e-473a-a7f0-53e7ebd2eb9d" /></td>
<td><img width="330" alt="Settings" src="https://github.com/user-attachments/assets/610a2991-a6c5-451d-ac7d-3fd83034a761" /></td>
</tr><tr>
<td colspan="2"><img width="670" alt="Chat" src="https://github.com/user-attachments/assets/20115a2b-0500-4745-9903-4fe43f1416b7" /></td>
</tr></table>
