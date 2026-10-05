# Command List

This document provides an overview of the available commands for managing bots in the application.

## General Commands

- **Debugging and Examples**
  - `,ex`, `,example`, `,debug`: Example or debug commands for testing functionality.

- **Rejoin Commands**
  - `,rejoin`, `,rj`, `,rej`, `,reconnect`, `,r`: Commands to rejoin the server or reconnect.

- **Bot Management**
  - `,bring`: Command to bring a bot to the user.
  - `,line <left/right/back/front>`: Line up bots in the specified direction.

## Promotion Commands

- **Promotion and Sharing**
  - `,promo`, `,promote`, `,share`, `,brag`, `,advertise`, `,ad`: Commands for promoting content or sharing messages.

## Status Commands

- **Account Status**
  - `,index`, `,ingame`, `,online`: Check which accounts are currently online.

## Custom Commands

- **Unique Bot Commands**
  - `,meatballify`, `,meatball`, `,gwibard`: Custom commands specific to the application.

## Termination Commands

- **Stop Commands**
  - `,end`, `,stop`, `,quit`, `,exit`, `,close`: Commands to stop the script or application.

## Emote Commands

- **Dance Emotes**
  - `,dance <1/2/3>`, `,groove`: Commands for bot dance emotes.

- **Greeting and Cheer Emotes**
  - `,wave`, `,hello`, `,cheer`, `,hooray`, `,applaud`, `,clap`, `,shrug`, `,idk`, `,confused`, `,point`, `,pointout`, `,punch`, `,laugh`, `,excite`, `,lol`: Various emote commands for expressing actions.

- **Custom Emote**
  - `,emote <name>`, `,e <name>`: Trigger a custom emote.

## Reset Commands

- **Resetting Bots**
  - `,reset`, `,kill`, `,oof`, `,die`: Commands to reset or remove bots.

## Messaging Commands

- **Chatting**
  - `,say <message>`, `,chat <message>`, `,message <message>`, `,msg <message>`, `,announce <message>`: Commands to send messages in chat.

## Following Commands

- **Follow and Unfollow**
  - `,follow <target>`, `,track`, `,watch`: Commands to follow or track a specified target.
  - `,unfollow`, `,untrack`, `,unwatch`: Commands to stop following or tracking.

## Orbiting Commands

- **Orbiting Behavior**
  - `,orbit <target> <speed>`: Command to make a bot orbit a target at a specified speed.
  - `,unorbit`: Command to stop orbiting.

## Movement Commands

- **Movement Controls**
  - `,ws <speed>`, `,walkspeed <speed>`: Set the bot's walk speed.
  - `,resetws`, `,defaultws`: Reset walk speed to default settings.

## Help

- `,help`: Show the first page privately and send the current command registry to the existing Discord report endpoint.
- `,help 2`: Show another page (eight commands per page).
- `,help ring` or `,help bunnyhop`: Show a command's description, usage where available, and aliases.
- Help is generated from the registered commands, so new commands appear automatically.

## Fun Commands (v3.20)

| Command | What it does |
| --- | --- |
| `,hop [interval]` / `,bunnyhop` | Keep hopping; default 1 second, bounded to 0.4–5 seconds. |
| `,moonwalk` | Walk backward while keeping the starting facing direction. |
| `,zigzag [period]` | Walk forward with alternating sideways movement; default 2 seconds, bounded to 0.5–5 seconds per cycle. |
| `,wiggle [degrees] [speed]` / `,shimmy` | Wiggle in place; default 25 degrees and 2 cycles/second, bounded to 5–60 degrees and 0.5–6 cycles/second. |
| `,sit` / `,chill` | Sit down. |
| `,unsit` / `,getup` | Stand up. |
| `,stopfun` / `,unfun` | Stop any of the fun movement modes above. |

Starting another movement mode cancels the current fun mode. The animated modes stop on death, respawn, or an anchored root. Use `,unfreeze` before starting them while frozen.

## Duplicate “command not found” replies (v3.21)

If a new command works or appears in `,help` but also receives “not found”, an older script copy may still be listening. Send `,end` from the host, wait for the close reply(s), then load the latest script exactly once on the alt. Rejoining the alt provides a clean reset if an old copy remains.

From v3.21 onward, loading the script replaces the previous v3.21+ runtime in the same executor environment. Reload and `,end` disconnect chat/player listeners and stop movement, the debris ring, and god-mode callbacks. Older releases cannot be auto-replaced because they did not register a runtime handle; stop them once before upgrading.
