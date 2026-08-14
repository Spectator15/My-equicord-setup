# My Equicord setup

This repo contains my custom Equicord setup script, which lets me install and manage selected custom plugins alongside Equicord. Some of the included plugins originate from Nightcord or the wider Vencord/Equicord ecosystem and have been cleaned up or modified for my own use.

This is a Windows script. `Equicord.bat` starts an embedded PowerShell setup with a menu for installing Equicord, managing the bundled plugins, updating and rebuilding the client mod, repairing its Discord injection, and checking the current setup status.

This is a personal setup and is not an official Equicord or Nightcord project.

## What the full setup does

The full setup first refuses to continue if it is running as Administrator. It checks for Git, Node.js 22 or newer, and pnpm. Missing Git and Node.js are installed through Windows Package Manager when available, and missing pnpm is installed globally through npm.

Equicord is cloned from the upstream GitHub repository into the current user's Windows Documents folder at `Documents\Equicord`. If that folder already contains a usable Equicord checkout, the script updates it with a fast-forward-only Git pull. It does not reset, clean, or discard local changes.

After the source is ready, the setup opens the custom plugin manager. It writes the selected embedded plugin sources into `Documents\Equicord\src\userplugins`, installs Equicord's dependencies with `pnpm install --frozen-lockfile` when needed, runs `pnpm build`, and uses Equicord's own `scripts/runInstaller.mjs` runner to inject the build into Discord.

Discord must be closed before injection. The script can detect normal Discord, Discord PTB, and Discord Canary installations under the current user's local application data. If more than one installation is found, it asks which one to use. It also checks for an update in progress and can restore a missing or damaged `app.asar` from Equicord's `_app.asar` backup before running the installer.

## Plugin manager

The plugin manager treats the selection as the desired set of bundled plugin folders. Selected plugins are installed or refreshed from the source embedded in the batch file. Unselected bundled plugins are removed only after a confirmation prompt. Unknown or third-party folders already present in `src\userplugins` are left alone. The old `AudioLimiter` folder is treated as obsolete and is removed by this setup if found.

Selections are remembered in `%LOCALAPPDATA%\EquicordSetup\config.json`. If there is no saved configuration, the manager first looks at which bundled plugin folders are already installed. On a fresh setup, all ten bundled plugins are selected as the recommended default.

Selecting a plugin in this manager controls whether its source folder is included in the Equicord build. It does not necessarily enable the plugin at runtime. In the embedded source, `AntiDeleteMessage` and `FakePerm` are disabled by default inside Equicord. The AntiMove feature also starts switched off until its chat bar button is used.

When plugin files change, the standalone manager offers to install dependencies, rebuild Equicord, and repair or reinject it. If nothing changed, it skips those steps unless a forced rebuild was selected.

## Bundled plugins

- **SmoothType** replaces the normal message-input caret with a smoothly animated caret. Its settings control the transition delay and easing style.

- **StreamerModeOnStream** turns Discord's streamer mode on when the current user starts streaming and turns it off when that stream ends.

- **ExportDM** adds export actions to DM, user, and channel context menus. It fetches the available message history and can save raw JSON, online HTML, an offline ZIP archive, or one self-contained HTML file. Offline exports can include attachments, avatars, custom emojis, stickers, and embed media. Downloads are cancellable and use bounded concurrency, retries, and timeouts.

- **ServerCloner** copies selected server settings to another server where the current user has Administrator permission. It can copy the name and description, icon, roles, channels, permission overwrites, and emojis. Its options can also delete existing roles or channels in the target server, so the target and options need to be checked carefully before starting.

- **AntiDeleteMessage** keeps a bounded local cache of the current user's text messages and resends one if it is deleted. DM protection is optional, servers can be blacklisted, and the cache limit is configurable. A restored message is sent through Discord and is not just a local visual replacement.

- **LastSeen** records activity that the client observes from presence changes, messages, voice state changes, typing, and reactions. It shows the current presence or the last locally observed activity time in a user's profile, with English and French display options. The stored history is capped and is only as complete as the activity this client has seen.

- **StreamProof** adds a chat bar toggle that blurs message text, images, embeds, attachments, and stickers. Blurred items can be revealed by clicking them, and an optional setting turns the feature on automatically while streaming.

- **FakePerm** adds local-only moderation-style controls for visual testing, including simulated nickname, mute, deafen, disconnect, timeout, kick, ban, role display, and message removal actions. These actions do not perform real moderation on the server.

- **FakeDM** adds a chat bar panel for inserting local-only fake message and call entries into DMs and group DMs. It supports choosing participants and timestamps, answered or missed calls, call duration, clearing injected entries from the current conversation, and restoring a capped set of saved entries after reconnecting.

- **AntiMoveDeco** adds a chat bar toggle that remembers the current voice channel. If the client observes the current user being moved or disconnected, it attempts to return to that channel after a short delay.

## Updating, repair, and diagnostics

The update option fetches and applies a fast-forward-only Equicord update, checks dependencies, and rebuilds. It preserves `src\userplugins`. Reinjection is deliberately separate, so use the repair option if a Discord update has removed or broken the patch.

Repair or reinject closes Discord with confirmation, checks that Discord is not still updating, repairs the local `app.asar` layout when possible, and runs Equicord's installer in repair mode. It does not rewrite the custom plugin selection.

Diagnostics reports the Equicord and configuration paths, versions or availability of Git, Node.js, npm, pnpm, Corepack, and winget, the Equicord branch and working-tree status, detected Discord installations, bundled plugin folders, unknown user-plugin folders, and whether desktop build output appears to exist.

Dependency state is cached in `%LOCALAPPDATA%\EquicordSetup\dependency-state.json`. The script fingerprints Equicord's package and pnpm workspace files so it can avoid reinstalling dependencies when the existing install still appears current.

## Usage and important notes

Download or clone this repository, then double-click `Equicord.bat` and choose an option from the menu.

Do not run the script as Administrator. The script intentionally exits when elevated because Equicord, Discord, the dependency tools, and the saved setup state are expected to belong to the normal Windows user account.

The setup can install development tools, download Equicord source and dependencies, stop Discord after asking, build code, and patch the selected Discord installation. ServerCloner can make substantial changes to a target server, and AntiDeleteMessage can send replacement messages. Read the prompts and plugin settings before using those features.

Discord and Equicord updates can change internal APIs or file layouts. If Equicord stops loading after a Discord update, try the repair or reinject menu option. If a plugin stops building, its embedded source may need to be updated for the current Equicord codebase.

## Security and code origins

In the versions embedded in this script, known unwanted token-grabbing behaviour, unsafe functionality, or outdated API usage have been removed or replaced where applicable, based on the current code. This is not a guarantee of complete safety, and it is not a promise that every possible token grabber has been removed forever. Review the current script and the generated plugin source before running code you do not trust.

Existing copyright and licence headers inside the embedded plugin sources are kept intact. This repository does not claim ownership of Equicord, Vencord, Nightcord, Discord, or third-party plugin code, and it does not add a separate repository-wide licence.
