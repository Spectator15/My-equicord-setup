<h1 align="center">My Equicord Setup</h1>

<p align="center">
  A one-script installer for <a href="https://github.com/Equicord/Equicord">Equicord</a> with a hand-picked, reviewed set of custom plugins — for Windows and Linux.
</p>

<p align="center">
  <a href="https://github.com/Spectator15/My-equicord-setup/releases/latest"><img src="https://img.shields.io/github/v/release/Spectator15/My-equicord-setup?label=stable" alt="Latest release"></a>
  <a href="https://github.com/Spectator15/My-equicord-setup/releases"><img src="https://img.shields.io/github/v/release/Spectator15/My-equicord-setup?include_prereleases&label=linux%20beta&color=orange" alt="Linux beta"></a>
  <img src="https://img.shields.io/badge/platform-Windows%20%7C%20Linux-blue" alt="Platforms">
  <a href="LICENSE"><img src="https://img.shields.io/badge/license-GPL--3.0--or--later-green" alt="License"></a>
</p>

---

## Quick start

**Windows:** download `Equicord.bat` from the [latest release](https://github.com/Spectator15/My-equicord-setup/releases/latest), run it normally, and follow the menu.

> [!WARNING]
> Do not run `Equicord.bat` as Administrator. The script refuses to continue when elevated.

**Linux (beta):** download `Equicord-Linux.sh` from the [Linux beta release](https://github.com/Spectator15/My-equicord-setup/releases/tag/v1.1.0-beta.4), then:

```bash
chmod +x Equicord-Linux.sh
./Equicord-Linux.sh
```

Each script is self-contained. You don't need to clone this repo or build anything yourself.

## Why this exists

Nightcord has some genuinely useful plugins I couldn't find elsewhere. But Vendicated, the creator of Vencord, [published evidence](https://gist.github.com/Vendicated/bb30cb67878fa682bcee140f56af1531) that Nightcord `v1.18.2` shipped a token logger that uploaded Discord tokens to Nightcord's server.

The code was later removed, but after something like that I didn't want to trust their prebuilt releases again. So I took only the plugins I wanted, reviewed and cleaned them up, and compile them myself through official Equicord.

## Bundled plugins

| Plugin | What it does | Credit |
| --- | --- | --- |
| **SmoothType** | Smooth animated caret in the message box | Spectator15 |
| **StreamerModeOnStream** | Turns on Streamer Mode automatically when you start streaming | IcedMarina |
| **ExportDM** | Exports chats as JSON, HTML, or a full offline ZIP archive | sqlu |
| **ServerCloner** | Clones a whole server into one where you're an admin | Nightcord |
| **AntiDeleteMessage** | Resends your messages if someone deletes them | Nightcord |
| **LastSeen** | Shows when a user was last seen | Nightcord |
| **StreamProof** | Blurs Discord content while streaming; click to reveal | TheArmagan |
| **FakePerm** | Visually simulates moderation options (no real actions) | Nightcord |
| **FakeDM** | Adds fake messages and calls to DMs, visible only to you | sqlu |
| **AntiMoveDeco** | Stops you from being moved or disconnected from voice | Nightcord |

Known token-grabbing behaviour, unsafe functionality, and outdated APIs have been removed or replaced where needed. You should still read the code yourself before running anything you don't trust.

## What the script does

- Installs or updates an official Equicord source checkout
- Lets you install all plugins in one go, or pick specific ones (type `1 4 7` or `2-5`)
- Builds Equicord and injects it into the Discord installation you pick
- Rebuilds automatically after plugin changes
- **Update Equicord and rebuild everything**: one option pulls the latest Equicord, rewrites your plugins, rebuilds, and reinjects Discord only if it lost Equicord
- Repairs injection after Discord updates
- Shows status and diagnostics
- Fully removes everything it installed (Linux can also restore backups)

**Removing it:** choose **Fully remove my Equicord setup** and type `REMOVE` to confirm. It restores Discord's original files, then deletes only what the manager created. Discord itself, your account, and shared tools like Git and Node.js are left alone. Anything you edited yourself is kept, never deleted. The downloaded script doesn't delete itself; remove it by hand if you like.

<details>
<summary><b>How removal stays safe (details)</b></summary>

- Ownership, the official Git remote, exact paths, and the worktree are all checked before anything is deleted.
- Uninjection uses the official Equilotl tool and checks that Discord's original `app.asar` is back before cleanup continues.
- Local edits, unknown plugins, and anything questionable are kept, not deleted.
- If something fails partway through, it reports **partial cleanup** without reinjecting. Fix the reported issue and run removal again to resume safely.
- Only the selected Discord client is closed, and it's relaunched if it was running.
- On Linux, Flatpak permission overrides are restored only when the manager can prove it made them.
- Unattended Linux removal requires `MES_NONINTERACTIVE=1` plus `--remove --confirm-remove`.

</details>

## Linux notes

Equicord user plugins have to be compiled from source, so Linux needs **Git, `curl`, core build tools, and Node.js 22+**. The script checks for these and tells you the right install command for your distro, but it won't install system packages for you. It finds the exact `pnpm` version Equicord needs on its own, without `sudo`.

The first setup can take a few minutes. It never runs as root, and it only asks for elevation if the Discord install you chose is system-owned.

<details>
<summary><b>Supported Discord clients</b></summary>

- **Supported:** Discord Stable, PTB, and Canary as native, system Electron, or versioned installs (the same layouts [Equilotl](https://github.com/Equicord/Equilotl) supports), plus matching layouts under `Applications` / `AppImages`.
- **Experimental:** Flatpak. Detection and injection work, but it hasn't had a real graphical test yet.
- **Not supported:** Snap (not supported upstream) and ChromeOS.
- **Equibop:** detected, but not modified. Packaged Equibop doesn't include these custom plugins.
- If more than one install is found, you choose which one gets patched. It never patches all of them.

</details>

<details>
<summary><b>Where files are stored</b></summary>

| Purpose | Default location |
| --- | --- |
| Equicord source and backups | `${XDG_DATA_HOME:-$HOME/.local/share}/my-equicord-setup/` |
| Build state, logs, and install manifest | `${XDG_STATE_HOME:-$HOME/.local/state}/my-equicord-setup/` |
| Manager configuration | `${XDG_CONFIG_HOME:-$HOME/.config}/my-equicord-setup/` |
| Verified injector and temporary build data | `${XDG_CACHE_HOME:-$HOME/.cache}/my-equicord-setup/` |

</details>

<details>
<summary><b>Testing status</b></summary>

All ten plugins are compiled in Ubuntu CI against official Equicord commit `0d27aec1ab604f1c0d7f7eb9114114e71da93573`. Automated tests cover install, update, plugin staging, client detection, safe removal, and the `pnpm` setup across Ubuntu/Debian, Arch, Fedora, and openSUSE fixtures.

**Not yet manually confirmed on Linux:** a real graphical Discord launch, plugins appearing in settings, Flatpak surviving updates, and each plugin's runtime behaviour. That's why Linux is still a beta.

</details>

## Development

Edit the sources in `src/`, not the generated `Equicord.bat` / `Equicord-Linux.sh`. To rebuild:

```powershell
.\build\Build-Release.ps1          # Windows
```

```bash
./build/Build-LinuxRelease.sh      # Linux
```

The generated scripts are committed so users can download them directly.

---

## Disclaimer

This is a personal project. It is not an official Equicord, Vencord, Nightcord, Equilotl, Equibop, or Discord project.

Distributed under `GPL-3.0-or-later`. Third-party code keeps its original copyright and licence notices. I don't claim ownership of it.
