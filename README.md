<h1 align="center">My Equicord Setup</h1>

<p align="center">This repo contains my personal Equicord setup script. It installs Equicord and lets me manage a small collection of custom plugins that I personally use.</p>

---

## Why this exists

Nightcord has some genuinely useful plugins that I could not find good replacements for elsewhere. However, I stopped trusting Nightcord itself after Vendicated, the creator of Vencord, published evidence showing that Nightcord `v1.18.2` contained a token logger which uploaded Discord tokens to Nightcord's server.

The offending code appears to have been removed from later Nightcord releases, but after something like that had already been shipped, I did not feel comfortable trusting future prebuilt versions.

Instead, I decided to take only the individual plugins I wanted, inspect and clean them up where needed, and compile them myself through Equicord. This repo is basically my personal way of keeping the useful parts without having to install or trust Nightcord itself.

**Evidence published by Vendicated:** [View the published evidence](https://gist.github.com/Vendicated/bb30cb67878fa682bcee140f56af1531)

## What the script does

`Equicord.bat` handles most of my setup for me. It can install or update Equicord, manage my selected plugins, rebuild Equicord, repair or reinject it after Discord updates, and run some basic diagnostics.

The script keeps the custom plugins inside Equicord's `src\userplugins` folder and remembers which bundled plugins I have selected.

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

## Using it

This is made for **Windows**.

1. Download or clone the repo.
2. Run `Equicord.bat` normally.
3. Follow the menu.

> [!WARNING]
> Do not run `Equicord.bat` as Administrator. The script intentionally refuses to continue when elevated.

On a fresh setup, the full setup option handles the Equicord installation, plugin selection, dependencies, build, and Discord injection.

After that, the same script can be used whenever I want to change plugins, update Equicord, rebuild it, or repair the Discord injection.

---

## Disclaimer

This is a personal setup and is not an official Equicord, Vencord, Nightcord, or Discord project.

This repository is distributed under `GPL-3.0-or-later`. Third-party components retain their original copyright and attribution.

I do not claim ownership of third-party code included or adapted here. Existing copyright and licence notices inside plugin source are kept intact.
