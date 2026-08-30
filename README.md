<h1 align="center">My Equicord Setup</h1>

<p align="center">This repo contains my personal Equicord setup scripts. They install Equicord and let me manage a small collection of custom plugins that I personally use on Windows or Linux.</p>

---

## Why this exists

Nightcord has some genuinely useful plugins that I could not find good replacements for elsewhere. However, I stopped trusting Nightcord itself after Vendicated, the creator of Vencord, published evidence showing that Nightcord `v1.18.2` contained a token logger which uploaded Discord tokens to Nightcord's server.

The offending code appears to have been removed from later Nightcord releases, but after something like that had already been shipped, I did not feel comfortable trusting future prebuilt versions.

Instead, I decided to take only the individual plugins I wanted, inspect and clean them up where needed, and compile them myself through Equicord. This repo is basically my personal way of keeping the useful parts without having to install or trust Nightcord itself.

**Evidence published by Vendicated:** [View the published evidence](https://gist.github.com/Vendicated/bb30cb67878fa682bcee140f56af1531)

## What the setup does

The setup installs or updates an official [Equicord](https://github.com/Equicord/Equicord) source checkout, puts my bundled plugins in `src/userplugins`, builds Equicord, and applies that custom build to a selected Discord installation. It can also rebuild after plugin changes, repair the injection after Discord updates, report diagnostics, remove only the managed plugins, and restore a manager backup.

**The currently bundled plugins are:**

- `SmoothType`
- `StreamerModeOnStream`
- `ExportDM`
- `ServerCloner`
- `AntiDeleteMessage`
- `LastSeen`
- `StreamProof`
- `FakePerm`
- `FakeDM`
- `AntiMoveDeco`

Some of these originated from Nightcord while others come from or are based on the wider Vencord and Equicord ecosystem.

Where needed, I have removed or replaced known unwanted token-grabbing behaviour, unsafe functionality, and outdated API usage from the versions included here. I still recommend looking through the code yourself before running anything you do not trust.

All ten bundled plugins have the required Equicord user-plugin entry structure, and they compile against the upstream Equicord commit recorded in the testing section below. No plugin contains a detected Windows-only runtime dependency. Their live behaviour on a graphical Linux Discord session still needs manual beta testing.

## Windows

1. Download `Equicord.bat` from the [latest stable GitHub release](https://github.com/Spectator15/My-equicord-setup/releases/latest), or download it directly from the repository.
2. Run `Equicord.bat` normally.
3. Follow the menu.

Normal users do not need to build or combine anything. The committed `Equicord.bat` is the complete ready-to-run Windows installer.

> [!WARNING]
> Do not run `Equicord.bat` as Administrator. The script intentionally refuses to continue when elevated.

On a fresh setup, the full setup option handles the Equicord installation, plugin selection, dependencies, build, and Discord injection. After that, the same script can change the selected plugins, update Equicord, rebuild it, or repair the Discord injection.

## Linux beta

Download `Equicord-Linux.sh` from the [Linux beta release](https://github.com/Spectator15/My-equicord-setup/releases/tag/v1.1.0-beta.2), then run:

```bash
chmod +x Equicord-Linux.sh
./Equicord-Linux.sh
```

Normal users only need that one release script. It contains the bundled plugin sources and does not require PowerShell or a separate copy of this repository.

Equicord user plugins must be compiled from source, so the Linux setup cannot use a normal prebuilt Equicord package on its own. The initial setup needs Git, `curl`, core build utilities, Node.js 22 or newer, and the `pnpm` version declared by the checked-out Equicord `package.json`. Corepack can provide that declared `pnpm` version. The script checks these requirements before changing the setup and prints distribution-specific package guidance, but it does not install system packages automatically.

The initial dependency install and source build may take several minutes and use additional disk space. The Linux menu provides:

1. Install or repair my Equicord setup
2. Update Equicord and my plugins
3. Rebuild and reapply my plugins
4. Remove only my custom plugin setup
5. Restore a backup
6. Status and diagnostics
7. Exit

The manager uses these XDG locations by default:

| Purpose | Default location |
| --- | --- |
| Equicord source and backups | `${XDG_DATA_HOME:-$HOME/.local/share}/my-equicord-setup/` |
| Build state, logs, and install manifest | `${XDG_STATE_HOME:-$HOME/.local/state}/my-equicord-setup/` |
| Manager configuration | `${XDG_CONFIG_HOME:-$HOME/.config}/my-equicord-setup/` |
| Verified injector and temporary build data | `${XDG_CACHE_HOME:-$HOME/.cache}/my-equicord-setup/` |

Updates validate the official Git remote, refuse dirty or diverged checkouts, and use fetch plus fast-forward behavior. Plugin deployment is staged and backed up before replacement. A failed plugin build restores the previous manager-owned source set. Removal only targets plugins recorded by this manager, preserves unrelated user plugins and themes, rebuilds Equicord, and does not uninstall Discord or Equicord.

### Linux client support

This beta supports `x86_64` Linux. Ubuntu is exercised on a real GitHub Actions Linux runner. The script is designed to be distribution-independent when its dependencies are available, but other distributions are not yet claimed as fully tested.

Current Discord Stable, PTB, and Canary layouts are detected for native system or user installations, supported system Electron layouts, and versioned installations in the locations used by current [Equilotl](https://github.com/Equicord/Equilotl). Matching unpacked or versioned layouts under common `Applications` and `AppImages` directories can also be found. Standalone Snap packages are not supported upstream and are not offered as targets.

Flatpak detection and injection follow current Equilotl behavior, including the required filesystem override, but Flatpak remains experimental here until it receives a real graphical test. The script never patches every discovered client automatically. If it finds more than one installation, it shows the branch, package format, resolved path, and injection status so you can choose one.

The setup refuses to run as root. A verified, versioned Equilotl CLI asset is downloaded with its published SHA-256 digest. Elevation is requested only if that injector must modify a selected system-owned Discord target. Git, Node.js, `pnpm`, plugin deployment, builds, and XDG files stay under the normal user account.

[Equibop](https://github.com/Equicord/Equibop) is a separate Linux-focused Discord client with Equicord preinstalled. Current Equibop can be pointed at a custom Equicord `dist` directory through its developer settings, but a normal packaged Equibop does not automatically contain this repository's custom plugins. This beta detects Equibop and explains that distinction, but does not change its settings or treat it as an installation target. ChromeOS is rejected, and NixOS receives a warning because the official documentation currently describes the Equibop Nix package as outdated.

### Linux validation status

Automated tests cover the generated release, XDG paths, paths with spaces and non-ASCII characters, safe Git updates, plugin staging and restoration, unknown-plugin preservation, native and Flatpak discovery, branch distinction, symlink deduplication, exact process targeting, root refusal, narrow mocked elevation, download failures, digest failures, deterministic generation, LF line endings, executable mode, and shell syntax.

The ten plugins are also compiled in Ubuntu CI against official Equicord commit `0d27aec1ab604f1c0d7f7eb9114114e71da93573`, with their names checked in the resulting bundle. The reviewed `streamerModeOnStream` folder collision is safe at that revision because upstream's plugin has the distinct runtime name `StreamerModeOn`, while this repository's plugin is `StreamerModeOnStream`. Any new collision, or a future loss of that distinction, stops the setup.

The source build and injection structure are verified automatically. A real graphical Discord launch, plugin visibility in the settings page, Flatpak persistence after an update, and each plugin's runtime behavior have not yet been manually confirmed on Linux. That is why the Linux release is marked as a beta prerelease.

## Development

The editable installers and plugin sources live under `src/`. Contributors should change those source files rather than editing the generated `Equicord.bat` or `Equicord-Linux.sh` directly.

To rebuild the Windows release from the repository root, use:

```powershell
.\build\Build-Release.ps1
```

To rebuild the Linux release, use Bash:

```bash
./build/Build-LinuxRelease.sh
```

Both complete generated files remain committed so normal users can download and run them directly. See the [GitHub releases page](https://github.com/Spectator15/My-equicord-setup/releases) for ready-to-run downloads.

---

## Disclaimer

This is a personal setup and is not an official Equicord, Vencord, Nightcord, Equilotl, Equibop, or Discord project.

This repository is distributed under `GPL-3.0-or-later`. Third-party components retain their original copyright and attribution.

I do not claim ownership of third-party code included or adapted here. Existing copyright and licence notices inside plugin source are kept intact.
