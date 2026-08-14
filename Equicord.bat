@echo off
setlocal DisableDelayedExpansion
rem The marker is deliberately assembled so the loader cannot find its own search text.
powershell.exe -NoLogo -NoProfile -ExecutionPolicy Bypass -Command "& { try { $f = [System.IO.File]::ReadAllText('%~f0'); $marker = ('#' + 'region INIT'); $start = $f.IndexOf($marker, [System.StringComparison]::Ordinal); if ($start -lt 0) { throw 'Setup marker not found.' }; Invoke-Expression ($f.Substring($start)) } catch { try { $Host.UI.RawUI.WindowTitle = 'EquicordSetup - Startup Error' } catch {}; Write-Host ''; Write-Host 'EquicordSetup could not start.' -ForegroundColor Red; Write-Host $_.Exception.Message -ForegroundColor Yellow; if ($_.InvocationInfo.PositionMessage) { Write-Host ''; Write-Host $_.InvocationInfo.PositionMessage -ForegroundColor DarkYellow }; Write-Host ''; Read-Host 'Press Enter to close' | Out-Null; exit 1 } }"
set "EQUICORD_SETUP_EXIT=%ERRORLEVEL%"
endlocal & exit /b %EQUICORD_SETUP_EXIT%

#region INIT
$Host.UI.RawUI.WindowTitle = "EquicordSetup"
try { $Host.UI.RawUI.BackgroundColor = "Black"; Clear-Host } catch {}

$LINE = "-" * 60
$script:RepoUrl = "https://github.com/Equicord/Equicord"
$script:EquicordDir = Join-Path ([Environment]::GetFolderPath("MyDocuments")) "Equicord"
$script:ConfigDir = Join-Path $env:LOCALAPPDATA "EquicordSetup"
$script:ConfigPath = Join-Path $script:ConfigDir "config.json"
$script:DependencyStatePath = Join-Path $script:ConfigDir "dependency-state.json"
$script:ConfigVersion = 2
$script:PnpmBin = $null
$script:GitBin = $null
$script:DiscordInstall = $null
$ProgressPreference = "SilentlyContinue"

function Test-IsAdministrator {
    $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = New-Object Security.Principal.WindowsPrincipal $identity
    return $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

function Refresh-SessionPath {
    $extra = @(
        "$env:ProgramFiles\Git\cmd",
        "$env:ProgramFiles\nodejs",
        "$env:APPDATA\npm",
        "$env:LOCALAPPDATA\pnpm",
        "$env:LOCALAPPDATA\Microsoft\WinGet\Packages",
        "$env:USERPROFILE\AppData\Local\pnpm"
    ) | Where-Object { $_ -and (Test-Path $_) }

    $machine = [Environment]::GetEnvironmentVariable("Path", "Machine")
    $user = [Environment]::GetEnvironmentVariable("Path", "User")
    $current = @($env:Path, $machine, $user) -join ";"
    $paths = ($extra + ($current -split ";")) | Where-Object { $_ } | Select-Object -Unique
    $env:Path = $paths -join ";"
}

Refresh-SessionPath
#endregion

#region HELPERS
function Write-Header {
    param([string]$Title = "")
    Write-Host ""
    if ($Title) {
        $pad = [math]::Max(0, [math]::Floor((60 - $Title.Length - 2) / 2))
        $right = [math]::Max(0, 60 - $pad - $Title.Length - 2)
        Write-Host ("-" * $pad) -ForegroundColor Cyan -NoNewline
        Write-Host " $Title " -ForegroundColor White -NoNewline
        Write-Host ("-" * $right) -ForegroundColor Cyan
    }
    Write-Host $LINE -ForegroundColor Cyan
}

function Write-Section {
    param([string]$Label = "")
    Write-Host ""
    Write-Host $LINE -ForegroundColor Cyan
    if ($Label) { Write-Host "  $Label" -ForegroundColor White }
    Write-Host $LINE -ForegroundColor Cyan
}

function Write-MenuItem {
    param([string]$Key, [string]$Label, [System.ConsoleColor]$Color = "White")
    Write-Host "  [" -NoNewline
    Write-Host $Key -ForegroundColor Cyan -NoNewline
    Write-Host "] " -NoNewline
    Write-Host $Label -ForegroundColor $Color
}

function Write-Success { param([string]$Msg); Write-Host ""; Write-Host "  v  $Msg" -ForegroundColor Green }
function Write-Err     { param([string]$Msg); Write-Host ""; Write-Host "  x  $Msg" -ForegroundColor Red }
function Write-Warn    { param([string]$Msg); Write-Host ""; Write-Host "  !  $Msg" -ForegroundColor Yellow }
function Write-Info    { param([string]$Msg); Write-Host "     $Msg" -ForegroundColor DarkGray }
function Write-Step    { param([string]$Msg); Write-Host "  -> $Msg" -ForegroundColor Cyan }

function Get-KeyChoice {
    Write-Host ""
    Write-Host "  Choose an option: " -ForegroundColor Cyan -NoNewline
    $key = $Host.UI.RawUI.ReadKey("NoEcho,IncludeKeyDown")
    Write-Host $key.Character
    return ($key.Character.ToString().ToLower())
}

function Read-ChoiceText {
    Write-Host ""
    Write-Host "  Choose an option: " -ForegroundColor Cyan -NoNewline
    return (Read-Host).Trim()
}

function Pause-Return {
    Write-Host ""
    Write-Host "  Press Enter to go back..." -ForegroundColor DarkGray -NoNewline
    Read-Host | Out-Null
}

function Get-Confirm {
    param([string]$Msg = "Are you sure?")
    Write-Host ""
    Write-Host "  $Msg (y/n): " -ForegroundColor Yellow -NoNewline
    $key = $Host.UI.RawUI.ReadKey("NoEcho,IncludeKeyDown")
    Write-Host $key.Character
    return ($key.Character.ToString().ToLower() -eq "y")
}

function Resolve-Executable {
    param([Parameter(Mandatory = $true)][string[]]$Names)
    Refresh-SessionPath
    foreach ($name in $Names) {
        $command = Get-Command $name -ErrorAction SilentlyContinue | Select-Object -First 1
        if ($command) { return $command.Source }
    }
    return $null
}

function Invoke-InDirectory {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][scriptblock]$Script
    )
    $old = Get-Location
    try {
        Set-Location -LiteralPath $Path
        & $Script
    } finally {
        Set-Location $old
    }
}

function Invoke-NativeChecked {
    param(
        [Parameter(Mandatory = $true)][string]$FilePath,
        [Parameter(Mandatory = $true)][string[]]$Arguments,
        [Parameter(Mandatory = $true)][string]$Description
    )
    & $FilePath @Arguments | Out-Host
    $code = $LASTEXITCODE
    if ($null -eq $code) { $code = 0 }
    if ($code -ne 0) { throw "$Description failed with exit code $code." }
}

function Get-NativeOutput {
    param(
        [Parameter(Mandatory = $true)][string]$FilePath,
        [Parameter(Mandatory = $true)][string[]]$Arguments
    )
    $output = & $FilePath @Arguments 2>&1
    $code = $LASTEXITCODE
    if ($null -eq $code) { $code = 0 }
    if ($code -ne 0) { throw "$FilePath exited with code $code`: $(($output | Out-String).Trim())" }
    return ($output | Out-String).Trim()
}

function Invoke-Git {
    param([Parameter(ValueFromRemainingArguments = $true)][string[]]$Arguments)
    if (-not $script:GitBin) { $script:GitBin = Resolve-Executable @("git.exe", "git") }
    if (-not $script:GitBin) { throw "Git is not available in this terminal session." }
    $output = & $script:GitBin @Arguments 2>&1
    $code = $LASTEXITCODE
    if ($null -eq $code) { $code = 0 }
    if ($code -ne 0) { throw "Git failed with exit code $code`: $(($output | Out-String).Trim())" }
    return $output
}

function Invoke-GitChecked {
    param([Parameter(Mandatory = $true)][string[]]$Arguments, [Parameter(Mandatory = $true)][string]$Description)
    if (-not $script:GitBin) { $script:GitBin = Resolve-Executable @("git.exe", "git") }
    if (-not $script:GitBin) { throw "Git is not available in this terminal session." }
    Invoke-NativeChecked -FilePath $script:GitBin -Arguments $Arguments -Description $Description
}

function Invoke-Pnpm {
    param([Parameter(ValueFromRemainingArguments = $true)][string[]]$Arguments)
    if (-not $script:PnpmBin) { $script:PnpmBin = Resolve-Executable @("pnpm.cmd", "pnpm.exe", "pnpm") }
    if (-not $script:PnpmBin) { throw "pnpm is not available in this terminal session." }
    $output = & $script:PnpmBin @Arguments 2>&1
    $code = $LASTEXITCODE
    if ($null -eq $code) { $code = 0 }
    if ($code -ne 0) { throw "pnpm failed with exit code $code`: $(($output | Out-String).Trim())" }
    return $output
}

function Invoke-PnpmChecked {
    param([Parameter(Mandatory = $true)][string[]]$Arguments, [Parameter(Mandatory = $true)][string]$Description)
    if (-not $script:PnpmBin) { $script:PnpmBin = Resolve-Executable @("pnpm.cmd", "pnpm.exe", "pnpm") }
    if (-not $script:PnpmBin) { throw "pnpm is not available in this terminal session." }
    Invoke-NativeChecked -FilePath $script:PnpmBin -Arguments $Arguments -Description $Description
}

function Get-ToolVersion {
    param(
        [Parameter(Mandatory = $true)][string[]]$Names,
        [string[]]$VersionArguments = @("--version")
    )
    $exe = Resolve-Executable $Names
    if (-not $exe) { return "not found" }
    try {
        $text = Get-NativeOutput -FilePath $exe -Arguments $VersionArguments
        if ([string]::IsNullOrWhiteSpace($text)) { return "found: $exe" }
        return $text.Split("`n")[0].Trim()
    } catch {
        return "found, version check failed"
    }
}

function Install-WingetPackage {
    param(
        [Parameter(Mandatory = $true)][string]$Id,
        [Parameter(Mandatory = $true)][string]$Name
    )

    $winget = Resolve-Executable @("winget.exe", "winget")
    if (-not $winget) {
        Write-Err "Windows Package Manager (winget) is unavailable."
        Write-Info "Install $Name manually, then run this setup again."
        return $false
    }

    Write-Step "Installing $Name with winget..."
    try {
        Invoke-NativeChecked -FilePath $winget -Arguments @("install", "--id", $Id, "--exact", "--source", "winget", "--accept-package-agreements", "--accept-source-agreements") -Description "$Name installation"
    } catch {
        Write-Err $_.Exception.Message
        return $false
    }

    Refresh-SessionPath
    return $true
}

function Get-NodeMajorVersion {
    $node = Resolve-Executable @("node.exe", "node")
    if (-not $node) { return $null }
    try {
        $version = (Get-NativeOutput -FilePath $node -Arguments @("--version")).Trim().TrimStart("v")
        return [int]($version.Split(".")[0])
    } catch {
        return $null
    }
}

function Ensure-DevTools {
    Refresh-SessionPath

    Write-Step "Checking for Git..."
    $script:GitBin = Resolve-Executable @("git.exe", "git")
    if (-not $script:GitBin) {
        if (-not (Install-WingetPackage -Id "Git.Git" -Name "Git")) { return $false }
        $script:GitBin = Resolve-Executable @("git.exe", "git")
        if (-not $script:GitBin) {
            Write-Err "Git installed, but this terminal cannot find it yet."
            Write-Info "Close this setup and run it again."
            return $false
        }
    }
    Write-Success "Git is available."

    Write-Step "Checking for Node.js 22 or newer..."
    $node = Resolve-Executable @("node.exe", "node")
    $npm = Resolve-Executable @("npm.cmd", "npm")
    $major = Get-NodeMajorVersion
    if (-not $node -or -not $npm -or -not $major -or $major -lt 22) {
        if ($major -and $major -lt 22) {
            Write-Warn "Current Equicord requires Node.js 22 or newer. Detected Node.js $major."
        }
        if (-not (Install-WingetPackage -Id "OpenJS.NodeJS.LTS" -Name "Node.js LTS")) { return $false }
        $node = Resolve-Executable @("node.exe", "node")
        $npm = Resolve-Executable @("npm.cmd", "npm")
        $major = Get-NodeMajorVersion
        if (-not $node -or -not $npm -or -not $major -or $major -lt 22) {
            Write-Err "Node.js LTS installed, but this terminal cannot find a compatible Node.js yet."
            Write-Info "Close this setup and run it again."
            return $false
        }
    }
    Write-Success "Node.js is available."

    Write-Step "Checking for pnpm..."
    $script:PnpmBin = Resolve-Executable @("pnpm.cmd", "pnpm.exe", "pnpm")
    if (-not $script:PnpmBin) {
        Write-Info "Installing pnpm with npm, matching Equicord's current README guidance."
        try {
            Invoke-NativeChecked -FilePath $npm -Arguments @("install", "--global", "pnpm") -Description "pnpm installation"
        } catch {
            Write-Err $_.Exception.Message
            return $false
        }
        Refresh-SessionPath
        $script:PnpmBin = Resolve-Executable @("pnpm.cmd", "pnpm.exe", "pnpm")
        if (-not $script:PnpmBin) {
            Write-Err "pnpm was installed, but this terminal cannot find it yet."
            Write-Info "Close this setup and run it again."
            return $false
        }
    }
    Write-Success "pnpm is available."

    return $true
}

function Write-Utf8FileAtomic {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][string]$Content
    )
    $folder = Split-Path -Parent $Path
    if (-not (Test-Path -LiteralPath $folder)) { New-Item -ItemType Directory -Path $folder -Force | Out-Null }
    $folderItem = Get-Item -LiteralPath $folder -Force -ErrorAction Stop
    if (-not $folderItem.PSIsContainer) { throw "Refusing to write through a non-directory path: $folder" }
    if (($folderItem.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
        throw "Refusing to write through a reparse-point directory: $folder"
    }
    $temp = Join-Path $folder ("." + [IO.Path]::GetFileName($Path) + "." + [guid]::NewGuid().ToString("N") + ".tmp")
    $encoding = New-Object System.Text.UTF8Encoding -ArgumentList $false
    try {
        [IO.File]::WriteAllText($temp, $Content, $encoding)
        if (Test-Path -LiteralPath $Path -PathType Leaf) {
            $existing = [IO.File]::ReadAllText($Path, [Text.Encoding]::UTF8)
            if ($existing -ceq $Content) {
                Remove-Item -LiteralPath $temp -Force -ErrorAction SilentlyContinue
                return $false
            }
        }
        Move-Item -LiteralPath $temp -Destination $Path -Force
        return $true
    } finally {
        if (Test-Path -LiteralPath $temp) { Remove-Item -LiteralPath $temp -Force -ErrorAction SilentlyContinue }
    }
}

function Get-SafeChildPath {
    param(
        [Parameter(Mandatory = $true)][string]$Root,
        [Parameter(Mandatory = $true)][string]$Child
    )
    if ([string]::IsNullOrWhiteSpace($Child) -or $Child.IndexOfAny([char[]]"\/:") -ge 0 -or $Child -eq "." -or $Child -eq "..") {
        throw "Unsafe plugin folder name: $Child"
    }
    $rootFull = [IO.Path]::GetFullPath((Join-Path $Root "."))
    if (-not $rootFull.EndsWith("\")) { $rootFull += "\" }
    $target = [IO.Path]::GetFullPath((Join-Path $rootFull $Child))
    if (-not $target.StartsWith($rootFull, [StringComparison]::OrdinalIgnoreCase)) {
        throw "Refusing to access a path outside src\userplugins: $target"
    }
    return $target
}

function Remove-SafeDirectory {
    param(
        [Parameter(Mandatory = $true)][string]$Root,
        [Parameter(Mandatory = $true)][string]$Child
    )
    $target = Get-SafeChildPath -Root $Root -Child $Child
    if (-not (Test-Path -LiteralPath $target)) { return $false }
    $item = Get-Item -LiteralPath $target -Force
    if (-not $item.PSIsContainer) { throw "Refusing to remove non-directory path: $target" }
    if (($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
        throw "Refusing to remove reparse point: $target"
    }
    Remove-Item -LiteralPath $target -Recurse -Force
    return $true
}

function Get-PluginsDir {
    param([string]$EquicordDir = $script:EquicordDir)
    return Join-Path $EquicordDir "src\userplugins"
}

function Test-EquicordRepo {
    param([string]$Path = $script:EquicordDir)
    return (Test-Path -LiteralPath (Join-Path $Path ".git")) -and (Test-Path -LiteralPath (Join-Path $Path "package.json"))
}

function Stop-DiscordForInjection {
    $processes = Get-Process -Name "Discord", "DiscordPTB", "DiscordCanary" -ErrorAction SilentlyContinue
    if (-not $processes) { return $true }

    Write-Warn "Discord must be closed before Equicord can patch its files."
    if (-not (Get-Confirm "Close Discord now?")) { return $false }

    $processes | Stop-Process -Force -ErrorAction SilentlyContinue
    Start-Sleep -Seconds 2

    if (Get-Process -Name "Discord", "DiscordPTB", "DiscordCanary" -ErrorAction SilentlyContinue) {
        Write-Err "Discord is still running. Close it from the tray, then try again."
        return $false
    }
    Write-Success "Discord closed."
    return $true
}

function Get-DiscordInstallCandidates {
    $roots = @(
        @{ Name = "Discord Stable"; Root = (Join-Path $env:LOCALAPPDATA "Discord") },
        @{ Name = "Discord PTB"; Root = (Join-Path $env:LOCALAPPDATA "DiscordPTB") },
        @{ Name = "Discord Canary"; Root = (Join-Path $env:LOCALAPPDATA "DiscordCanary") }
    )

    $found = @()
    foreach ($candidate in $roots) {
        if (-not (Test-Path -LiteralPath $candidate.Root)) { continue }
        $apps = Get-ChildItem -Path $candidate.Root -Directory -Filter "app-*" -ErrorAction SilentlyContinue |
            ForEach-Object {
                $resources = Join-Path $_.FullName "resources"
                $asar = Join-Path $resources "app.asar"
                $backup = Join-Path $resources "_app.asar"
                $versionText = $_.Name -replace "^app-", ""
                $version = try { [version]$versionText } catch { [version]"0.0.0.0" }
                [pscustomobject]@{
                    Name = $candidate.Name
                    Root = $candidate.Root
                    AppDirectory = $_.FullName
                    Resources = $resources
                    Version = $version
                    HasBase = (Test-Path -LiteralPath $asar -PathType Leaf) -or (Test-Path -LiteralPath $backup -PathType Leaf)
                }
            } |
            Where-Object { $_.HasBase } |
            Sort-Object Version -Descending
        if ($apps) { $found += @($apps | Select-Object -First 1) }
    }
    return $found
}

function Get-DiscordInstall {
    if ($script:DiscordInstall -and (Test-Path -LiteralPath $script:DiscordInstall.Resources)) { return $script:DiscordInstall }
    $candidates = @(Get-DiscordInstallCandidates)
    if ($candidates.Count -eq 0) { return $null }
    if ($candidates.Count -eq 1) {
        $script:DiscordInstall = $candidates[0]
        return $script:DiscordInstall
    }

    Write-Warn "Multiple Discord installations were detected."
    for ($i = 0; $i -lt $candidates.Count; $i++) {
        Write-Host ("  [{0}] {1} ({2})" -f ($i + 1), $candidates[$i].Name, $candidates[$i].AppDirectory)
    }
    while ($true) {
        $choice = Read-ChoiceText
        if ($choice -match "^\d+$") {
            $index = [int]$choice - 1
            if ($index -ge 0 -and $index -lt $candidates.Count) {
                $script:DiscordInstall = $candidates[$index]
                break
            }
        }
        Write-Warn "Choose one of the listed Discord installations."
    }
    return $script:DiscordInstall
}

function Test-DiscordUpdateInProgress {
    $roots = @(
        (Join-Path $env:LOCALAPPDATA "Discord"),
        (Join-Path $env:LOCALAPPDATA "DiscordPTB"),
        (Join-Path $env:LOCALAPPDATA "DiscordCanary")
    )
    foreach ($process in @(Get-Process -Name "Update" -ErrorAction SilentlyContinue)) {
        try {
            $path = $process.Path
            if ($path -and ($roots | Where-Object { $path.StartsWith($_, [StringComparison]::OrdinalIgnoreCase) })) { return $true }
        } catch {}
    }
    return $false
}

function Test-UsableAsarFile {
    param([string]$Path)
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { return $false }
    try { return (Get-Item -LiteralPath $Path -Force).Length -ge 4096 } catch { return $false }
}

function Test-EquicordInjectionMarker {
    param([Parameter(Mandatory = $true)]$Install)
    $loaderDir = Join-Path $Install.Resources "app.asar"
    $indexPath = Join-Path $loaderDir "index.js"
    $packagePath = Join-Path $loaderDir "package.json"
    $patcherPath = Join-Path $script:EquicordDir "dist\desktop\patcher.js"
    if (-not (Test-Path -LiteralPath $indexPath -PathType Leaf) -or
        -not (Test-Path -LiteralPath $packagePath -PathType Leaf) -or
        -not (Test-Path -LiteralPath $patcherPath -PathType Leaf)) { return $false }
    try {
        $expected = ([IO.Path]::GetFullPath($patcherPath)).Replace("\", "\\")
        return ([IO.File]::ReadAllText($indexPath)).Contains($expected)
    } catch { return $false }
}

function Fix-DiscordAsar {
    param($Install = $null)
    $install = if ($Install) { $Install } else { Get-DiscordInstall }
    if (-not $install) {
        Write-Err "No usable Discord app folder was found."
        Write-Info "Discord may be updating. Open it once, wait for it to finish, close it fully, then try again."
        return $false
    }

    $res = $install.Resources
    $asarPath = Join-Path $res "app.asar"
    $backupPath = Join-Path $res "_app.asar"

    Write-Info "Using $($install.Name): $($install.AppDirectory)"

    if (Test-Path -LiteralPath $asarPath -PathType Container) {
        $asarItem = Get-Item -LiteralPath $asarPath -Force -ErrorAction SilentlyContinue
        if (-not $asarItem -or (($asarItem.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0)) {
            Write-Err "Refusing to repair a reparse-point app.asar directory."
            return $false
        }
        if (-not (Test-UsableAsarFile $backupPath)) {
            Write-Err "Discord has a patched app.asar folder but no usable _app.asar backup."
            Write-Info "Let Discord update or reinstall itself, then retry."
            return $false
        }
        if (Test-EquicordInjectionMarker -Install $install) {
            Write-Info "An existing Equicord loader was found; the official installer will refresh it."
            return $true
        }
        $fullAsar = [IO.Path]::GetFullPath($asarPath)
        $fullRes = [IO.Path]::GetFullPath($res).TrimEnd("\") + "\"
        if (-not $fullAsar.StartsWith($fullRes, [StringComparison]::OrdinalIgnoreCase)) {
            Write-Err "Refusing to remove an unsafe app.asar path."
            return $false
        }
        Remove-Item -LiteralPath $asarPath -Recurse -Force
        Write-Info "Removed a leftover patched app.asar folder from an earlier patch."
    }

    if (-not (Test-UsableAsarFile $asarPath)) {
        if (Test-UsableAsarFile $backupPath) {
            Copy-Item -LiteralPath $backupPath -Destination $asarPath -Force
            Write-Info "Restored a missing or corrupt app.asar from Equicord's backup."
        } else {
            Write-Err "The selected Discord folder no longer has a usable app.asar file."
            Write-Info "Open Discord once, wait for any update to finish, close it fully, then rerun this step."
            return $false
        }
    }

    return $true
}
#endregion

#region PLUGIN WRITERS
function Write-PluginSmoothType {
    param([Parameter(Mandatory = $true)][string]$PluginsDir)
    $dir = Get-SafeChildPath -Root $PluginsDir -Child "smoothType"
    $changed = $false
    $content1 = @'
/*
 * Vencord, a Discord client mod
 * Copyright (c) 2024 Vendicated and contributors
 * SPDX-License-Identifier: GPL-3.0-or-later
 */

import { definePluginSettings } from "@api/Settings";
import definePlugin, { OptionType } from "@utils/types";

const STYLE_ID = "vc-smoothtype";

const settings = definePluginSettings({
    transitionDelay: {
        type: OptionType.NUMBER,
        description: "Transition Delay (ms)",
        default: 60,
        onChange: () => applyCSS(),
    },
    animationType: {
        type: OptionType.SELECT,
        description: "Animation Type",
        options: [
            { label: "Ease", value: "ease", default: true },
            { label: "Linear", value: "linear" },
            { label: "Ease-in", value: "ease-in" },
            { label: "Ease-out", value: "ease-out" },
            { label: "Ease-in-out", value: "ease-in-out" },
        ],
        onChange: () => applyCSS(),
    },
});

function buildCSS(): string {
    const ms = settings.store.transitionDelay ?? 60;
    const easing = settings.store.animationType ?? "ease";
    return `
@keyframes vc-blink {
    0%, 100% { opacity: 1; }
    50%       { opacity: 0; }
}
#vc-smoothtype-caret.is-blinking {
    animation: vc-blink 1s ease-in-out infinite;
}
#vc-smoothtype-caret {
    position: fixed;
    top: 0; left: 0;
    width: 2px;
    border-radius: 2px;
    background: white;
    pointer-events: none;
    z-index: 99999;
    display: none;
    transition: left ${ms}ms ${easing}, top ${ms}ms ${easing}, height ${ms}ms ${easing};
}
[data-slate-editor] { caret-color: transparent !important; }
`;
}

function getCaret(): HTMLDivElement | null {
    let el = document.getElementById("vc-smoothtype-caret") as HTMLDivElement | null;
    if (!el) {
        if (!document.body) return null;
        el = document.createElement("div");
        el.id = "vc-smoothtype-caret";
        document.body.appendChild(el);
    }
    return el;
}

let blinkTimer: ReturnType<typeof setTimeout> | null = null;
let initTimer: ReturnType<typeof setTimeout> | null = null;
let initialized = false;

function startBlink() { blinkTimer = null; const el = getCaret(); if (!el) return; el.classList.add("is-blinking"); }
function stopBlink() {
    const el = getCaret(); if (!el) return;
    el.classList.remove("is-blinking");
    if (blinkTimer) clearTimeout(blinkTimer);
    blinkTimer = setTimeout(startBlink, 1000);
}

function applyCaretPosition() {
    const el = getCaret();
    if (!el) return;
    if (!document.activeElement?.closest("[data-slate-editor]")) { el.style.display = "none"; return; }
    const sel = window.getSelection();
    if (!sel?.rangeCount) { el.style.display = "none"; return; }
    const range = sel.getRangeAt(0).cloneRange();
    range.collapse(false);
    const rects = range.getClientRects();
    let rect: DOMRect | null = rects.length > 0 ? rects[0] : null;
    if (!rect || rect.height === 0) {
        const node = range.startContainer;
        const parent = (node.nodeType === Node.TEXT_NODE ? node.parentElement : node) as HTMLElement | null;
        if (parent) rect = parent.getBoundingClientRect();
    }
    if (!rect || rect.height === 0) { el.style.display = "none"; return; }
    const newLeft = rect.right + "px";
    const newTop = rect.top + "px";
    if (el.style.left !== newLeft || el.style.top !== newTop) { if (el.style.display !== "none") stopBlink(); }
    el.style.display = "block";
    el.style.left = newLeft;
    el.style.top = rect.top + "px";
    el.style.height = rect.height + "px";
}

let observer: MutationObserver | null = null;
function startObserver() {
    if (observer || document.visibilityState === "hidden") return;
    observer = new MutationObserver(() => applyCaretPosition());
    observer.observe(document.body, { childList: true, subtree: true });
}
function stopObserver() { observer?.disconnect(); observer = null; }

function handleVisibilityChange() {
    if (document.visibilityState === "hidden") { stopObserver(); }
    else if (document.activeElement?.closest("[data-slate-editor]")) { startObserver(); }
}

const handlers = {
    sel:   () => applyCaretPosition(),
    focus: () => { applyCaretPosition(); if (document.activeElement?.closest("[data-slate-editor]")) startObserver(); },
    blur:  () => { const el = getCaret(); if (el) el.style.display = "none"; stopObserver(); },
    key:   () => applyCaretPosition(),
    click: () => { applyCaretPosition(); if (document.activeElement?.closest("[data-slate-editor]")) startObserver(); else stopObserver(); },
};

function startListeners() {
    document.addEventListener("selectionchange", handlers.sel);
    document.addEventListener("focusin", handlers.focus);
    document.addEventListener("focusout", handlers.blur);
    document.addEventListener("keyup", handlers.key, true);
    document.addEventListener("click", handlers.click, true);
}
function stopListeners() {
    document.removeEventListener("selectionchange", handlers.sel);
    document.removeEventListener("focusin", handlers.focus);
    document.removeEventListener("focusout", handlers.blur);
    document.removeEventListener("keyup", handlers.key, true);
    document.removeEventListener("click", handlers.click, true);
}

function applyCSS() {
    document.getElementById(STYLE_ID)?.remove();
    const s = document.createElement("style");
    s.id = STYLE_ID; s.textContent = buildCSS();
    document.head.appendChild(s);
}
function removeCSS() { document.getElementById(STYLE_ID)?.remove(); }

export default definePlugin({
    name: "SmoothType",
    enabledByDefault: true,
    description: "Smooth animated caret for the Discord message input.",
    authors: [{ name: "danish", id: 0n }],
    settings,
    start() {
        const init = () => {
            initTimer = null;
            if (!document.body) { initTimer = setTimeout(init, 100); return; }
            if (initialized) return;
            initialized = true;
            applyCSS();
            getCaret();
            if (document.activeElement?.closest("[data-slate-editor]")) startObserver();
            startListeners();
            document.addEventListener("visibilitychange", handleVisibilityChange);
        };
        init();
    },
    stop() {
        initialized = false;
        if (initTimer) { clearTimeout(initTimer); initTimer = null; }
        document.removeEventListener("visibilitychange", handleVisibilityChange);
        stopObserver(); stopListeners(); removeCSS();
        if (blinkTimer) { clearTimeout(blinkTimer); blinkTimer = null; }
        document.getElementById("vc-smoothtype-caret")?.remove();
    },
});

'@
    if (Write-Utf8FileAtomic -Path (Join-Path $dir "index.tsx") -Content $content1) { $changed = $true }
    return $changed
}

function Write-PluginStreamerModeOnStream {
    param([Parameter(Mandatory = $true)][string]$PluginsDir)
    $dir = Get-SafeChildPath -Root $PluginsDir -Child "streamerModeOnStream"
    $changed = $false
    $content1 = @'
/*
 * Vencord, a Discord client mod
 * Copyright (c) 2026 Vendicated and contributors
 * SPDX-License-Identifier: GPL-3.0-or-later
 */

import { Devs } from "@utils/constants";
import definePlugin from "@utils/types";
import { FluxDispatcher, UserStore } from "@webpack/common";

interface StreamEvent {
    streamKey: string;
}

function toggleStreamerMode({ streamKey }: StreamEvent, value: boolean) {
    const currentUser = UserStore.getCurrentUser();
    if (!currentUser || !streamKey?.endsWith(currentUser.id)) return;

    FluxDispatcher.dispatch({
        type: "STREAMER_MODE_UPDATE",
        key: "enabled",
        value
    });
}

export default definePlugin({
    name: "StreamerModeOnStream",
    description: "Automatically enables streamer mode when you begin streaming in Discord.",
    tags: ["Privacy", "Utility"],
    authors: [Devs.IcedMarina],
    flux: {
        STREAM_CREATE: d => toggleStreamerMode(d, true),
        STREAM_DELETE: d => toggleStreamerMode(d, false)
    }
});

'@
    if (Write-Utf8FileAtomic -Path (Join-Path $dir "index.ts") -Content $content1) { $changed = $true }
    return $changed
}

function Write-PluginExportDM {
    param([Parameter(Mandatory = $true)][string]$PluginsDir)
    $dir = Get-SafeChildPath -Root $PluginsDir -Child "exportDM"
    $changed = $false
    $content1 = @'
/*
 * Vencord, a Discord client mod
 * Copyright (c) 2026 Vendicated and contributors
 * SPDX-License-Identifier: GPL-3.0-or-later
 */

import { addContextMenuPatch, NavContextMenuPatchCallback, removeContextMenuPatch } from "@api/ContextMenu";
import { Divider } from "@components/Divider";
import definePlugin from "@utils/types";
import type { RenderModalProps } from "@vencord/discord-types";
import { ChannelStore, Constants, Menu, Modal, openModal, React, RestAPI, useState } from "@webpack/common";
import { strToU8, type Zippable, zipSync } from "fflate";

type ExportFormat = "json" | "onlineHtml" | "offlineArchive" | "singleHtml";
type AssetCategory = "attachments" | "avatars" | "emojis" | "stickers" | "embeds";
type MediaKind = "image" | "video" | "audio" | "file";
type HtmlMode = "online" | "archive" | "single";

interface ExportOptions {
    attachments: boolean;
    avatars: boolean;
    emojisStickers: boolean;
    embedMedia: boolean;
}

interface ExportProgress {
    stage: string;
    processed: number;
    total: number;
    downloadedBytes: number;
    failures: number;
}

interface AssetRequest {
    aliases: string[];
    category: AssetCategory;
    expectedSize: number;
    kind: MediaKind;
    originalUrl: string;
    path: string;
    urls: string[];
}

interface AssetCatalog {
    aliases: Map<string, AssetRequest>;
    requests: AssetRequest[];
}

interface AssetResult {
    bytes?: Uint8Array;
    contentType: string;
    error?: string;
    kind: MediaKind;
    originalUrl: string;
    path: string;
}

interface DownloadSummary {
    aliases: Map<string, AssetResult>;
    downloaded: AssetResult[];
    downloadedBytes: number;
    failures: AssetResult[];
}

interface ArchiveBuildResult {
    bytes: Uint8Array;
    html: string;
    manifest: Record<string, unknown>;
    report: string;
}

interface EmbeddedAssetPayload {
    aliases: Record<string, string>;
    data: Record<string, string>;
}

const DEFAULT_OPTIONS: ExportOptions = {
    attachments: true,
    avatars: true,
    emojisStickers: true,
    embedMedia: true
};
const ASSET_CONCURRENCY = 4;
const ASSET_RETRIES = 3;
const ASSET_TIMEOUT_MS = 20_000;
const SINGLE_HTML_WARNING_BYTES = 25 * 1024 * 1024;
const GROUP_WINDOW_MS = 7 * 60 * 1000;

const FORMAT_CHOICES: Array<{ id: ExportFormat; title: string; description: string; badge?: string; }> = [
    { id: "json", title: "JSON", description: "Raw data, preserving every collected message field." },
    { id: "onlineHtml", title: "Online HTML", description: "Small file; media loads from its original online source." },
    { id: "offlineArchive", title: "Offline Archive", description: "Complete offline copy in one ZIP file.", badge: "Recommended" },
    { id: "singleHtml", title: "Single HTML", description: "One portable offline file; potentially very large." }
];

const EXPORT_MODAL_CSS = `
.eq-export-modal { color: #dbdee1; padding: 4px 0; }
.eq-export-modal * { box-sizing: border-box; }
.eq-export-format-grid { display: grid; grid-template-columns: repeat(2, minmax(0, 1fr)); gap: 10px; }
.eq-export-format {
    appearance: none; min-height: 78px; padding: 12px; border: 1px solid #4e5058; border-radius: 7px;
    background: #2b2d31; color: #dbdee1; text-align: left; cursor: pointer;
}
.eq-export-format:hover:not(:disabled), .eq-export-format:focus-visible { border-color: #949ba4; outline: none; }
.eq-export-format--selected { border-color: #7289da; background: #35384a; box-shadow: inset 0 0 0 1px #7289da; }
.eq-export-format:disabled { cursor: not-allowed; opacity: .6; }
.eq-export-format-head { display: flex; align-items: center; justify-content: space-between; gap: 8px; color: #f2f3f5; font-size: 14px; font-weight: 700; }
.eq-export-format-desc { display: block; margin-top: 5px; color: #b5bac1; font-size: 12px; line-height: 1.4; }
.eq-export-badge { padding: 2px 6px; border-radius: 4px; background: #248046; color: #fff; font-size: 10px; font-weight: 700; }
.eq-export-options { display: grid; grid-template-columns: repeat(2, minmax(0, 1fr)); gap: 8px 14px; margin-top: 12px; padding: 11px 12px; border: 1px solid #3f4147; border-radius: 7px; background: #2b2d31; }
.eq-export-option { display: flex; align-items: center; gap: 8px; min-height: 28px; color: #dbdee1; font-size: 13px; cursor: pointer; }
.eq-export-option input { width: 16px; height: 16px; accent-color: #5865f2; }
.eq-export-summary, .eq-export-progress { margin-top: 12px; padding: 11px 12px; border: 1px solid #3f4147; border-radius: 7px; background: #232428; }
.eq-export-summary-grid { display: grid; grid-template-columns: repeat(3, 1fr); gap: 8px; margin-top: 7px; }
.eq-export-metric { color: #b5bac1; font-size: 11px; }
.eq-export-metric strong { display: block; margin-top: 2px; color: #f2f3f5; font-size: 14px; }
.eq-export-progress-line { display: flex; justify-content: space-between; gap: 10px; color: #b5bac1; font-size: 12px; }
.eq-export-bar { height: 5px; margin-top: 9px; overflow: hidden; border-radius: 3px; background: #3f4147; }
.eq-export-bar > span { display: block; height: 100%; background: #5865f2; transition: width .15s ease; }
.eq-export-note, .eq-export-status { margin-top: 10px; color: #b5bac1; font-size: 12px; line-height: 1.4; }
.eq-export-warning { color: #f0b232; }
.eq-export-actions { display: flex; gap: 9px; margin-top: 14px; }
.eq-export-button { appearance: none; min-height: 38px; padding: 0 15px; border: 1px solid transparent; border-radius: 6px; color: #fff; font-weight: 700; cursor: pointer; }
.eq-export-button--primary { flex: 1; background: #5865f2; border-color: #7289da; }
.eq-export-button--primary:hover:not(:disabled) { background: #4752c4; }
.eq-export-button--cancel { background: #4e5058; border-color: #6d6f78; }
.eq-export-button:disabled { cursor: not-allowed; opacity: .58; }
@media (max-width: 540px) {
    .eq-export-format-grid, .eq-export-options { grid-template-columns: 1fr; }
    .eq-export-summary-grid { grid-template-columns: 1fr 1fr; }
}
`;

function abortError(): DOMException {
    return new DOMException("Export cancelled.", "AbortError");
}

function throwIfAborted(signal: AbortSignal) {
    if (signal.aborted) throw abortError();
}

function isAbortError(error: unknown): boolean {
    return error instanceof DOMException && error.name === "AbortError";
}

function delay(ms: number, signal: AbortSignal): Promise<void> {
    return new Promise((resolve, reject) => {
        const timer = window.setTimeout(() => {
            signal.removeEventListener("abort", onAbort);
            resolve();
        }, ms);
        const onAbort = () => {
            window.clearTimeout(timer);
            reject(abortError());
        };
        signal.addEventListener("abort", onAbort, { once: true });
    });
}

async function fetchAllMessages(channelId: string, signal: AbortSignal, onProgress: (count: number) => void) {
    const messages: any[] = [];
    let beforeId: string | null = null;

    while (true) {
        throwIfAborted(signal);
        const query: Record<string, string | number> = { limit: 100 };
        if (beforeId) query.before = beforeId;
        const response = await RestAPI.get({ url: Constants.Endpoints.MESSAGES(channelId), query });
        throwIfAborted(signal);
        const status = Number(response?.status ?? 200);
        if (response?.ok === false || status >= 400) throw new Error(`Discord returned ${status}.`);

        const batch: any[] = Array.isArray(response.body) ? response.body : [];
        if (!batch.length) break;
        messages.push(...batch);
        onProgress(messages.length);
        if (batch.length < 100) break;
        beforeId = batch[batch.length - 1].id;
        await delay(250, signal);
    }

    return messages.reverse();
}

const HTML_ESCAPE_MAP: Record<string, string> = {
    "&": "&amp;",
    "<": "&lt;",
    ">": "&gt;",
    '"': "&quot;",
    "'": "&#39;"
};

function escapeHtml(value: unknown): string {
    return String(value ?? "").replace(/[&<>"']/g, character => HTML_ESCAPE_MAP[character] ?? character);
}

function safeExternalUrl(value: unknown): string {
    try {
        const url = new URL(String(value ?? ""));
        return url.protocol === "https:" || url.protocol === "http:" ? url.href : "";
    } catch {
        return "";
    }
}

function formatBytes(value: unknown): string {
    const bytes = Number(value);
    if (!Number.isFinite(bytes) || bytes < 0) return "Unknown";
    const units = ["B", "KB", "MB", "GB"];
    let size = bytes;
    let index = 0;
    while (size >= 1024 && index < units.length - 1) {
        size /= 1024;
        index++;
    }
    return `${size >= 10 || index === 0 ? size.toFixed(0) : size.toFixed(1)} ${units[index]}`;
}

function mediaKind(item: any): MediaKind {
    const contentType = String(item?.content_type ?? item?.contentType ?? "").toLowerCase();
    const name = String(item?.filename ?? item?.name ?? item?.url ?? "").toLowerCase();
    if (contentType.startsWith("image/") || /\.(?:apng|avif|bmp|gif|jpe?g|png|svg|webp)(?:$|[?#])/.test(name)) return "image";
    if (contentType.startsWith("video/") || /\.(?:m4v|mov|mp4|ogv|webm)(?:$|[?#])/.test(name)) return "video";
    if (contentType.startsWith("audio/") || /\.(?:aac|flac|m4a|mp3|oga|ogg|opus|wav|weba)(?:$|[?#])/.test(name)) return "audio";
    return "file";
}

function sanitizeFilenamePart(value: unknown, fallback = "asset"): string {
    const cleaned = String(value ?? "")
        .normalize("NFKC")
        .replace(/[<>:"/\\|?*\u0000-\u001f]/g, "_")
        .replace(/\.\.+/g, ".")
        .replace(/\s+/g, " ")
        .replace(/^[. ]+|[. ]+$/g, "")
        .slice(0, 96);
    return cleaned || fallback;
}

function safeFilename(value: string): string {
    return sanitizeFilenamePart(value, "discord-export");
}

function extensionFrom(value: unknown, kind: MediaKind): string {
    const plain = String(value ?? "").split(/[?#]/, 1)[0];
    const match = plain.match(/\.([A-Za-z0-9]{1,8})$/);
    if (match) return `.${match[1].toLowerCase()}`;
    if (kind === "image") return ".webp";
    if (kind === "video") return ".mp4";
    if (kind === "audio") return ".ogg";
    return ".bin";
}

function uniqueAssetPath(category: AssetCategory, id: string, originalName: string, kind: MediaKind, used: Set<string>): string {
    const safeId = sanitizeFilenamePart(id, "asset");
    let safeName = sanitizeFilenamePart(originalName, "asset");
    if (!/\.[A-Za-z0-9]{1,8}$/.test(safeName)) safeName += extensionFrom(originalName, kind);
    const dot = safeName.lastIndexOf(".");
    const stem = dot > 0 ? safeName.slice(0, dot) : safeName;
    const extension = dot > 0 ? safeName.slice(dot).toLowerCase() : extensionFrom(originalName, kind);
    let path = `assets/${category}/${safeId}-${stem}${extension}`;
    let suffix = 2;
    while (used.has(path.toLowerCase())) path = `assets/${category}/${safeId}-${stem}-${suffix++}${extension}`;
    used.add(path.toLowerCase());
    return path;
}

function stickerItems(message: any): any[] {
    return Array.isArray(message?.sticker_items)
        ? message.sticker_items
        : Array.isArray(message?.stickers) ? message.stickers : [];
}

function collectAssetRequests(messages: any[], options: ExportOptions): AssetCatalog {
    const aliases = new Map<string, AssetRequest>();
    const byUrl = new Map<string, AssetRequest>();
    const requests: AssetRequest[] = [];
    const usedPaths = new Set<string>();

    function add(alias: string, category: AssetCategory, id: string, originalName: string, urls: unknown[], kind: MediaKind, expectedSize = 0) {
        const safeUrls = urls.map(safeExternalUrl).filter(Boolean);
        if (!safeUrls.length) return;
        const dedupeKey = safeUrls[0];
        let request = byUrl.get(dedupeKey);
        if (!request) {
            request = {
                aliases: [],
                category,
                expectedSize: Number.isFinite(expectedSize) && expectedSize > 0 ? expectedSize : 0,
                kind,
                originalUrl: safeUrls[0],
                path: uniqueAssetPath(category, id, originalName, kind, usedPaths),
                urls: Array.from(new Set(safeUrls))
            };
            requests.push(request);
            byUrl.set(dedupeKey, request);
        }
        if (!aliases.has(alias)) request.aliases.push(alias);
        aliases.set(alias, request);
    }

    for (const message of messages) {
        const messageId = sanitizeFilenamePart(message?.id, "message");
        const author = message?.author;
        if (options.avatars && author?.id && author?.avatar) {
            const animated = String(author.avatar).startsWith("a_");
            const extension = animated ? "gif" : "webp";
            add(
                `avatar:${author.id}:${author.avatar}`,
                "avatars",
                `${author.id}-${author.avatar}`,
                `avatar.${extension}`,
                [`https://cdn.discordapp.com/avatars/${author.id}/${author.avatar}.${extension}?size=128`],
                "image"
            );
        }

        if (options.attachments) {
            const attachments = Array.isArray(message?.attachments) ? message.attachments : [];
            attachments.forEach((attachment: any, index: number) => {
                const id = String(attachment?.id ?? index);
                add(
                    `attachment:${message?.id}:${id}`,
                    "attachments",
                    `${messageId}-${sanitizeFilenamePart(id, String(index))}`,
                    String(attachment?.filename ?? `attachment-${index}`),
                    [attachment?.url, attachment?.proxy_url],
                    mediaKind(attachment),
                    Number(attachment?.size ?? 0)
                );
            });
        }

        if (options.emojisStickers) {
            const emojiPattern = /<(a?):([A-Za-z0-9_]+):(\d+)>/g;
            for (const match of String(message?.content ?? "").matchAll(emojiPattern)) {
                const extension = match[1] ? "gif" : "webp";
                add(
                    `emoji:${match[3]}`,
                    "emojis",
                    match[3],
                    `${match[2]}.${extension}`,
                    [`https://cdn.discordapp.com/emojis/${match[3]}.${extension}?size=96&quality=lossless`],
                    "image"
                );
            }

            stickerItems(message).forEach((sticker, index) => {
                const id = String(sticker?.id ?? index);
                const format = Number(sticker?.format_type ?? sticker?.formatType ?? 1);
                if (format === 3 || !/^\d+$/.test(id)) return;
                const extension = format === 4 ? "gif" : "png";
                add(
                    `sticker:${id}`,
                    "stickers",
                    id,
                    `${sticker?.name ?? "sticker"}.${extension}`,
                    [`https://media.discordapp.net/stickers/${id}.${extension}?size=320&quality=lossless`],
                    "image"
                );
            });
        }

        if (options.embedMedia) {
            const attachmentUrls = new Set<string>();
            for (const attachment of Array.isArray(message?.attachments) ? message.attachments : []) {
                const url = safeExternalUrl(attachment?.url);
                const proxy = safeExternalUrl(attachment?.proxy_url);
                if (url) attachmentUrls.add(url);
                if (proxy) attachmentUrls.add(proxy);
            }
            const embeds = Array.isArray(message?.embeds) ? message.embeds : [];
            embeds.forEach((embed: any, index: number) => {
                const imageUrl = safeExternalUrl(embed?.image?.proxy_url ?? embed?.image?.url);
                const thumbnailUrl = safeExternalUrl(embed?.thumbnail?.proxy_url ?? embed?.thumbnail?.url);
                const proxyVideoUrl = safeExternalUrl(embed?.video?.proxy_url);
                const videoUrl = proxyVideoUrl || safeExternalUrl(embed?.video?.url);
                if (imageUrl && !attachmentUrls.has(imageUrl)) {
                    add(`embed:${message?.id}:${index}:image`, "embeds", `${messageId}-${index}-image`, "embed-image", [imageUrl, embed?.image?.url], "image");
                }
                if (thumbnailUrl && !attachmentUrls.has(thumbnailUrl)) {
                    add(`embed:${message?.id}:${index}:thumbnail`, "embeds", `${messageId}-${index}-thumbnail`, "embed-thumbnail", [thumbnailUrl, embed?.thumbnail?.url], "image");
                }
                if (videoUrl && !attachmentUrls.has(videoUrl) && (proxyVideoUrl || mediaKind({ url: videoUrl }) === "video")) {
                    add(`embed:${message?.id}:${index}:video`, "embeds", `${messageId}-${index}-video`, "embed-video", [videoUrl, embed?.video?.url], "video");
                }
            });
        }
    }

    return { aliases, requests };
}

function contentTypeMatches(kind: MediaKind, contentType: string, url: string): boolean {
    const type = contentType.toLowerCase().split(";", 1)[0].trim();
    if (type === "text/html" || type === "application/xhtml+xml") return false;
    if (!type || type === "application/octet-stream") return true;
    if (kind === "file") return true;
    if (kind === "image") return type.startsWith("image/");
    if (kind === "video") return type.startsWith("video/") || mediaKind({ url }) === "video";
    return type.startsWith("audio/") || mediaKind({ url }) === "audio";
}

async function fetchAsset(request: AssetRequest, signal: AbortSignal, fetcher: typeof fetch): Promise<AssetResult> {
    let finalError = "No usable URL was available.";
    for (const url of request.urls) {
        for (let attempt = 0; attempt < ASSET_RETRIES; attempt++) {
            throwIfAborted(signal);
            const timeoutController = new AbortController();
            const onAbort = () => timeoutController.abort();
            signal.addEventListener("abort", onAbort, { once: true });
            const timeout = window.setTimeout(() => timeoutController.abort(), ASSET_TIMEOUT_MS);
            try {
                const response = await fetcher(url, { credentials: "omit", signal: timeoutController.signal });
                if (!response.ok) throw new Error(`HTTP ${response.status}`);
                const contentType = response.headers.get("content-type") ?? "application/octet-stream";
                if (!contentTypeMatches(request.kind, contentType, url)) throw new Error(`unexpected content type ${contentType}`);
                const bytes = new Uint8Array(await response.arrayBuffer());
                if (!bytes.byteLength) throw new Error("empty response");
                return { bytes, contentType, kind: request.kind, originalUrl: request.originalUrl, path: request.path };
            } catch (error) {
                if (signal.aborted) throw abortError();
                finalError = error instanceof Error ? error.message : String(error);
                if (attempt < ASSET_RETRIES - 1) await delay(350 * 2 ** attempt, signal);
            } finally {
                window.clearTimeout(timeout);
                signal.removeEventListener("abort", onAbort);
            }
        }
    }
    return {
        contentType: "",
        error: finalError,
        kind: request.kind,
        originalUrl: request.originalUrl,
        path: request.path
    };
}

async function downloadAssetRequests(
    catalog: AssetCatalog,
    signal: AbortSignal,
    onProgress: (progress: ExportProgress) => void,
    fetcher: typeof fetch = fetch
): Promise<DownloadSummary> {
    const aliases = new Map<string, AssetResult>();
    const downloaded: AssetResult[] = [];
    const failures: AssetResult[] = [];
    let cursor = 0;
    let processed = 0;
    let downloadedBytes = 0;

    async function worker() {
        while (true) {
            throwIfAborted(signal);
            const index = cursor++;
            if (index >= catalog.requests.length) return;
            const request = catalog.requests[index];
            const result = await fetchAsset(request, signal, fetcher);
            for (const alias of request.aliases) aliases.set(alias, result);
            if (result.bytes) {
                downloaded.push(result);
                downloadedBytes += result.bytes.byteLength;
            } else {
                failures.push(result);
            }
            processed++;
            onProgress({ stage: "Downloading media", processed, total: catalog.requests.length, downloadedBytes, failures: failures.length });
        }
    }

    await Promise.all(Array.from({ length: Math.min(ASSET_CONCURRENCY, Math.max(1, catalog.requests.length)) }, worker));
    throwIfAborted(signal);
    return { aliases, downloaded, downloadedBytes, failures };
}

function renderMessageText(value: unknown, resolve: (alias: string) => AssetResult | undefined, mode: HtmlMode): string {
    const text = String(value ?? "");
    const tokenPattern = /<(a?):([A-Za-z0-9_]+):(\d+)>|https?:\/\/[^\s<>]+/g;
    let output = "";
    let offset = 0;
    for (const match of text.matchAll(tokenPattern)) {
        const index = match.index ?? 0;
        output += escapeHtml(text.slice(offset, index));
        if (match[3]) {
            const alias = `emoji:${match[3]}`;
            const result = resolve(alias);
            const alt = `:${match[2]}:`;
            output += renderImageAsset(alias, result, alt, mode, "emoji");
        } else {
            const url = safeExternalUrl(match[0]);
            output += url
                ? `<a href="${escapeHtml(url)}" target="_blank" rel="noopener noreferrer">${escapeHtml(match[0])}</a>`
                : escapeHtml(match[0]);
        }
        offset = index + match[0].length;
    }
    output += escapeHtml(text.slice(offset));
    return output.replace(/\r?\n/g, "<br>");
}

function assetSourceAttributes(alias: string, result: AssetResult | undefined, mode: HtmlMode): string {
    if (!result || result.error) return "";
    if (mode === "online") return `src="${escapeHtml(result.originalUrl)}"`;
    if (mode === "archive") return `src="${escapeHtml(result.path)}"`;
    return `data-asset-key="${escapeHtml(alias)}"`;
}

function localLinkAttributes(alias: string, result: AssetResult | undefined, mode: HtmlMode): string {
    if (!result || result.error) return "";
    if (mode === "online") return `href="${escapeHtml(result.originalUrl)}"`;
    if (mode === "archive") return `href="${escapeHtml(result.path)}"`;
    return `href="#" data-asset-key="${escapeHtml(alias)}"`;
}

function originalLink(result: AssetResult | undefined): string {
    const url = safeExternalUrl(result?.originalUrl);
    return url ? `<a class="original-link" href="${escapeHtml(url)}" target="_blank" rel="noopener noreferrer">Original online source</a>` : "";
}

function unavailableMedia(label: string, result: AssetResult | undefined): string {
    const reason = result?.error ? ` (${escapeHtml(result.error)})` : "";
    return `<span class="media-unavailable" role="note">${escapeHtml(label)} unavailable offline${reason}</span>${originalLink(result)}`;
}

function renderImageAsset(alias: string, result: AssetResult | undefined, alt: string, mode: HtmlMode, className = "media-image"): string {
    const source = assetSourceAttributes(alias, result, mode);
    if (!source) return unavailableMedia(alt, result);
    return `<img class="${className}" ${source} alt="${escapeHtml(alt)}" loading="lazy">`;
}

function renderAttachment(message: any, attachment: any, index: number, resolve: (alias: string) => AssetResult | undefined, mode: HtmlMode): string {
    const id = String(attachment?.id ?? index);
    const alias = `attachment:${message?.id}:${id}`;
    const result = resolve(alias);
    const name = String(attachment?.filename ?? "attachment");
    const description = String(attachment?.description ?? "");
    const details = [escapeHtml(name), attachment?.size ? formatBytes(attachment.size) : ""].filter(Boolean).join(" - ");
    const caption = `<figcaption>${details}${description ? `<span>${escapeHtml(description)}</span>` : ""}${originalLink(result)}</figcaption>`;
    const source = assetSourceAttributes(alias, result, mode);
    const link = localLinkAttributes(alias, result, mode);
    if (!source || !link) return `<div class="file-card">${unavailableMedia(name, result)}</div>`;

    const kind = mediaKind(attachment);
    if (kind === "image") return `<figure><a ${link} download>${renderImageAsset(alias, result, description || name, mode)}</a>${caption}</figure>`;
    if (kind === "video") return `<figure><video ${source} controls preload="metadata"></video>${caption}</figure>`;
    if (kind === "audio") return `<figure><audio ${source} controls preload="metadata"></audio>${caption}</figure>`;
    return `<div class="file-card"><a ${link} download>${escapeHtml(name)}</a><span>${details}</span>${originalLink(result)}</div>`;
}

function renderStickers(message: any, resolve: (alias: string) => AssetResult | undefined, mode: HtmlMode): string {
    const rendered = stickerItems(message).map(sticker => {
        const id = String(sticker?.id ?? "");
        const name = String(sticker?.name ?? "sticker");
        const format = Number(sticker?.format_type ?? sticker?.formatType ?? 1);
        if (format === 3) {
            const url = safeExternalUrl(`https://cdn.discordapp.com/stickers/${id}.json`);
            return `<span class="media-unavailable">${escapeHtml(name)} uses an unsupported Lottie format</span><a class="original-link" href="${escapeHtml(url)}" target="_blank" rel="noopener noreferrer">Original Lottie data</a>`;
        }
        if (!/^\d+$/.test(id)) return "";
        return renderImageAsset(`sticker:${id}`, resolve(`sticker:${id}`), name, mode, "sticker");
    }).filter(Boolean).join("");
    return rendered ? `<div class="sticker-row">${rendered}</div>` : "";
}

function renderEmbed(message: any, embed: any, index: number, resolve: (alias: string) => AssetResult | undefined, mode: HtmlMode): string {
    const title = String(embed?.title ?? "");
    const description = renderMessageText(embed?.description ?? "", resolve, mode);
    const url = safeExternalUrl(embed?.url);
    const author = escapeHtml(embed?.author?.name ?? "");
    const provider = escapeHtml(embed?.provider?.name ?? "");
    const fields = Array.isArray(embed?.fields) ? embed.fields.map((field: any) =>
        `<div class="embed-field"><strong>${escapeHtml(field?.name ?? "")}</strong><div>${renderMessageText(field?.value ?? "", resolve, mode)}</div></div>`
    ).join("") : "";
    const imageAlias = `embed:${message?.id}:${index}:image`;
    const thumbnailAlias = `embed:${message?.id}:${index}:thumbnail`;
    const videoAlias = `embed:${message?.id}:${index}:video`;
    const imageResult = resolve(imageAlias);
    const thumbnailResult = resolve(thumbnailAlias);
    const videoResult = resolve(videoAlias);
    const image = imageResult ? renderImageAsset(imageAlias, imageResult, "Embedded image", mode, "embed-image") : "";
    const thumbnail = thumbnailResult ? renderImageAsset(thumbnailAlias, thumbnailResult, "Embedded thumbnail", mode, "embed-thumbnail") : "";
    const videoSource = assetSourceAttributes(videoAlias, videoResult, mode);
    const video = videoResult
        ? videoSource ? `<video class="embed-video" ${videoSource} controls preload="metadata"></video>` : unavailableMedia("Embedded video", videoResult)
        : "";
    const linkedTitle = title
        ? url ? `<a href="${escapeHtml(url)}" target="_blank" rel="noopener noreferrer">${escapeHtml(title)}</a>` : escapeHtml(title)
        : "";
    if (!linkedTitle && !description && !fields && !image && !thumbnail && !video) return "";
    return `<aside class="embed">${thumbnail}<div class="embed-body">${author || provider ? `<div class="embed-meta">${[author, provider].filter(Boolean).join(" - ")}</div>` : ""}${linkedTitle ? `<div class="embed-title">${linkedTitle}</div>` : ""}${description ? `<div>${description}</div>` : ""}${fields ? `<div class="embed-fields">${fields}</div>` : ""}${video}${image}</div></aside>`;
}

function renderMessageMedia(message: any, resolve: (alias: string) => AssetResult | undefined, mode: HtmlMode): string {
    const attachments = (Array.isArray(message?.attachments) ? message.attachments : [])
        .map((attachment: any, index: number) => renderAttachment(message, attachment, index, resolve, mode))
        .join("");
    const embeds = (Array.isArray(message?.embeds) ? message.embeds : [])
        .map((embed: any, index: number) => renderEmbed(message, embed, index, resolve, mode))
        .join("");
    const stickers = renderStickers(message, resolve, mode);
    return attachments || embeds || stickers ? `<div class="media-stack">${attachments}${embeds}${stickers}</div>` : "";
}

function renderAvatar(author: any, resolve: (alias: string) => AssetResult | undefined, mode: HtmlMode): string {
    const alias = `avatar:${author?.id}:${author?.avatar}`;
    const result = resolve(alias);
    if (result) return renderImageAsset(alias, result, "", mode, "avatar");
    const name = String(author?.global_name ?? author?.username ?? "?").trim();
    return `<span class="avatar avatar-fallback" aria-hidden="true">${escapeHtml(name.slice(0, 1).toUpperCase() || "?")}</span>`;
}

function conversationStyles(): string {
    return String.raw`:root{color-scheme:dark}*{box-sizing:border-box}body{margin:0;background:#313338;color:#dbdee1;font-family:system-ui,-apple-system,BlinkMacSystemFont,"Segoe UI",sans-serif;font-size:15px;line-height:1.46;padding:28px 18px}main{max-width:960px;margin:0 auto}h1{margin:0;color:#f2f3f5;font-size:24px;overflow-wrap:anywhere}.subtitle{margin:4px 0 24px;color:#949ba4;font-size:13px}.message{display:grid;grid-template-columns:46px minmax(0,1fr);column-gap:12px;padding:11px 10px 3px;border-radius:6px}.message.continuation{padding-top:3px}.message:hover{background:#2e3035}.avatar-slot{grid-column:1;grid-row:1/span 2}.avatar{display:grid;width:40px;height:40px;border-radius:50%;object-fit:cover;place-items:center;background:#5865f2;color:#fff;font-weight:700}.message-body{grid-column:2;min-width:0}.message-header{display:flex;align-items:baseline;gap:7px;min-width:0}.author{color:#f2f3f5;font-weight:700;overflow-wrap:anywhere}.username,.timestamp{color:#949ba4;font-size:12px}.continuation-time{grid-column:1;color:#949ba4;font-size:10px;text-align:right;padding-top:4px}.content{white-space:normal;overflow-wrap:anywhere;word-break:break-word}.content pre,.content code{white-space:pre-wrap;overflow-wrap:anywhere}.content a,.embed a,.file-card a,.original-link{color:#00a8fc;text-decoration:none;overflow-wrap:anywhere}.content a:hover,.embed a:hover,.file-card a:hover,.original-link:hover{text-decoration:underline}.emoji{display:inline-block;width:auto;height:1.4em;vertical-align:-.32em;object-fit:contain}.media-stack{display:flex;flex-direction:column;align-items:flex-start;gap:10px;margin-top:7px}.media-stack figure{max-width:min(100%,720px);margin:0}.media-stack img:not(.emoji):not(.avatar){display:block;max-width:100%;max-height:520px;border-radius:6px;object-fit:contain;background:#1e1f22}.media-stack video{display:block;max-width:100%;max-height:520px;border-radius:6px;background:#1e1f22}.media-stack audio{display:block;width:min(100%,440px)}figcaption{display:flex;flex-wrap:wrap;gap:4px 10px;margin-top:4px;color:#b5bac1;font-size:12px}figcaption span{flex-basis:100%}.original-link{font-size:11px}.file-card{display:flex;flex-wrap:wrap;align-items:center;gap:5px 10px;max-width:100%;padding:9px 11px;border:1px solid #4e5058;border-radius:6px;background:#2b2d31;overflow-wrap:anywhere}.file-card span{color:#949ba4;font-size:12px}.media-unavailable{display:inline-block;padding:8px 10px;border:1px dashed #5d6068;border-radius:5px;color:#b5bac1;background:#2b2d31;font-size:12px}.sticker-row{display:flex;flex-wrap:wrap;gap:8px}.sticker{width:160px;height:auto}.embed{display:flex;gap:12px;max-width:min(100%,720px);padding:10px 12px;border-left:4px solid #4f5660;border-radius:4px;background:#2b2d31;overflow-wrap:anywhere}.embed-body{min-width:0;flex:1}.embed-meta{margin-bottom:3px;color:#b5bac1;font-size:12px}.embed-title{margin-bottom:4px;color:#f2f3f5;font-weight:700}.embed-fields{display:grid;grid-template-columns:repeat(2,minmax(0,1fr));gap:8px;margin-top:8px}.embed-field{min-width:0;font-size:13px}.embed-field strong{display:block;color:#f2f3f5}.embed-thumbnail{order:2;width:80px;height:80px;object-fit:cover}.embed-image,.embed-video{max-width:100%;max-height:420px;margin-top:9px}.archive-footer{margin-top:26px;padding-top:12px;border-top:1px solid #3f4147;color:#949ba4;font-size:11px}@media(max-width:580px){body{padding:17px 7px}.message{grid-template-columns:38px minmax(0,1fr);column-gap:8px;padding-inline:4px}.avatar{width:34px;height:34px}.embed{gap:8px}.embed-thumbnail{width:60px;height:60px}.embed-fields{grid-template-columns:1fr}}`;
}

function renderConversationHtml(
    messages: any[],
    channelName: string,
    mode: HtmlMode,
    aliases: Map<string, AssetResult>,
    embeddedAssets?: EmbeddedAssetPayload
): string {
    const resolve = (alias: string) => aliases.get(alias);
    const rows: string[] = [];
    let previousAuthor = "";
    let previousTimestamp = 0;
    for (const message of messages) {
        const authorId = String(message?.author?.id ?? "");
        const timestamp = new Date(message?.timestamp ?? 0);
        const timestampMs = timestamp.getTime();
        const grouped = Boolean(authorId && authorId === previousAuthor && Number.isFinite(timestampMs) && timestampMs - previousTimestamp <= GROUP_WINDOW_MS);
        const author = escapeHtml(message?.author?.global_name ?? message?.author?.username ?? "Unknown user");
        const username = escapeHtml(message?.author?.username ?? "unknown");
        const iso = Number.isFinite(timestampMs) ? timestamp.toISOString() : "";
        const displayTime = Number.isFinite(timestampMs) ? timestamp.toLocaleString() : "Unknown time";
        const content = renderMessageText(message?.content ?? "", resolve, mode);
        const media = renderMessageMedia(message, resolve, mode);
        const header = grouped
            ? `<time class="continuation-time" datetime="${escapeHtml(iso)}" title="${escapeHtml(displayTime)}">${escapeHtml(timestamp.toLocaleTimeString([], { hour: "2-digit", minute: "2-digit" }))}</time>`
            : `<div class="avatar-slot">${renderAvatar(message?.author, resolve, mode)}</div><header class="message-header"><span class="author">${author}</span><span class="username">@${username}</span><time class="timestamp" datetime="${escapeHtml(iso)}">${escapeHtml(displayTime)}</time></header>`;
        rows.push(`<article class="message${grouped ? " continuation" : ""}" data-message-id="${escapeHtml(message?.id ?? "")}">${header}<div class="message-body"><div class="content">${content || (media ? "" : "<em>[no text or media]</em>")}</div>${media}</div></article>`);
        previousAuthor = authorId;
        previousTimestamp = Number.isFinite(timestampMs) ? timestampMs : 0;
    }

    const title = escapeHtml(channelName);
    const modeNote = mode === "online"
        ? "Online HTML export. Internet access is required to load media from its original source."
        : mode === "archive" ? "Offline archive. Media is loaded from the included assets folders." : "Self-contained offline HTML export.";
    const assetPayload = mode === "single"
        ? `<script type="application/json" id="asset-data">${JSON.stringify(embeddedAssets ?? { aliases: {}, data: {} }).replace(/</g, "\\u003c")}</script><script>(()=>{const n=document.getElementById("asset-data");if(!n)return;const a=JSON.parse(n.textContent||"{}");document.querySelectorAll("[data-asset-key]").forEach(e=>{const k=e.getAttribute("data-asset-key")||"";const u=a.data?.[a.aliases?.[k]];if(!u)return;if(e.tagName==="A")e.setAttribute("href",u);else e.setAttribute("src",u)})})()</script>`
        : "";
    const scriptPolicy = mode === "single" ? "'unsafe-inline'" : "'none'";
    const mediaPolicy = mode === "online" ? "https: http: data:" : mode === "single" ? "data:" : "'self' data:";
    return `<!DOCTYPE html><html lang="en"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1"><meta http-equiv="Content-Security-Policy" content="default-src 'none'; img-src ${mediaPolicy}; media-src ${mediaPolicy}; style-src 'unsafe-inline'; script-src ${scriptPolicy}"><title>${title}</title><style>${conversationStyles()}</style></head><body><main><h1>${title}</h1><p class="subtitle">${escapeHtml(modeNote)} ${messages.length} message${messages.length === 1 ? "" : "s"}.</p>${rows.join("\n")}<footer class="archive-footer">Generated locally by Equicord ExportDM. No analytics or remote scripts are included.</footer></main>${assetPayload}</body></html>`;
}

function rawJson(messages: any[], channelName: string, exportedAt = new Date().toISOString()): string {
    return JSON.stringify({ channel: channelName, exportedAt, messages }, null, 2);
}

function bytesToBase64(bytes: Uint8Array): string {
    let binary = "";
    const chunkSize = 0x8000;
    for (let offset = 0; offset < bytes.length; offset += chunkSize) {
        binary += String.fromCharCode(...bytes.subarray(offset, offset + chunkSize));
    }
    return btoa(binary);
}

function buildDownloadReport(summary: DownloadSummary): string {
    const lines = [
        "Equicord ExportDM download report",
        "",
        `Downloaded assets: ${summary.downloaded.length}`,
        `Downloaded bytes: ${summary.downloadedBytes}`,
        `Failed assets: ${summary.failures.length}`,
        ""
    ];
    if (summary.failures.length) {
        lines.push("Failures:");
        summary.failures.forEach(failure => lines.push(`- ${failure.path} | ${failure.originalUrl} | ${failure.error ?? "Unknown error"}`));
    } else {
        lines.push("All requested assets were downloaded successfully.");
    }
    return lines.join("\r\n");
}

function createOfflineArchive(
    messages: any[],
    channelName: string,
    options: ExportOptions,
    summary: DownloadSummary,
    exportedAt = new Date().toISOString()
): ArchiveBuildResult {
    const html = renderConversationHtml(messages, channelName, "archive", summary.aliases);
    const report = buildDownloadReport(summary);
    const manifest = {
        format: "Equicord ExportDM Offline Archive",
        version: 1,
        channel: channelName,
        exportedAt,
        messageCount: messages.length,
        options,
        downloadedBytes: summary.downloadedBytes,
        downloadedAssets: summary.downloaded.map(asset => ({ path: asset.path, contentType: asset.contentType, size: asset.bytes?.byteLength ?? 0, originalUrl: asset.originalUrl })),
        failedAssets: summary.failures.map(asset => ({ path: asset.path, originalUrl: asset.originalUrl, error: asset.error }))
    };
    const files: Zippable = {
        "index.html": [strToU8(html), { level: 6 }],
        "messages.json": [strToU8(rawJson(messages, channelName, exportedAt)), { level: 6 }],
        "manifest.json": [strToU8(JSON.stringify(manifest, null, 2)), { level: 6 }],
        "download-report.txt": [strToU8(report), { level: 6 }],
        "assets/attachments/": new Uint8Array(),
        "assets/avatars/": new Uint8Array(),
        "assets/emojis/": new Uint8Array(),
        "assets/stickers/": new Uint8Array(),
        "assets/embeds/": new Uint8Array()
    };
    for (const asset of summary.downloaded) {
        if (asset.bytes) files[asset.path] = [asset.bytes, { level: 0 }];
    }
    return { bytes: zipSync(files, { level: 6 }), html, manifest, report };
}

function createSingleHtml(messages: any[], channelName: string, summary: DownloadSummary): string {
    const embeddedAssets: EmbeddedAssetPayload = { aliases: {}, data: {} };
    for (const [alias, result] of summary.aliases) {
        if (!result.bytes || result.error) continue;
        if (!embeddedAssets.data[result.path]) {
            embeddedAssets.data[result.path] = `data:${result.contentType || "application/octet-stream"};base64,${bytesToBase64(result.bytes)}`;
        }
        embeddedAssets.aliases[alias] = result.path;
    }
    return renderConversationHtml(messages, channelName, "single", summary.aliases, embeddedAssets);
}

function retainSkippedAssetLinks(allAssets: AssetCatalog, summary: DownloadSummary) {
    for (const [alias, request] of allAssets.aliases) {
        if (summary.aliases.has(alias)) continue;
        summary.aliases.set(alias, {
            contentType: "",
            error: "Not included by the selected media options.",
            kind: request.kind,
            originalUrl: request.originalUrl,
            path: request.path
        });
    }
}

function createOnlineAliases(catalog: AssetCatalog): Map<string, AssetResult> {
    const aliases = new Map<string, AssetResult>();
    for (const [alias, request] of catalog.aliases) {
        aliases.set(alias, { contentType: "", kind: request.kind, originalUrl: request.originalUrl, path: request.path });
    }
    return aliases;
}

function downloadBlob(content: BlobPart, filename: string, mime: string) {
    const blob = new Blob([content], { type: mime });
    const url = URL.createObjectURL(blob);
    const link = document.createElement("a");
    link.href = url;
    link.download = filename;
    document.body.appendChild(link);
    link.click();
    link.remove();
    window.setTimeout(() => URL.revokeObjectURL(url), 1000);
}

function conversationSummary(messages: any[]) {
    let attachmentCount = 0;
    let knownBytes = 0;
    for (const message of messages) {
        for (const attachment of Array.isArray(message?.attachments) ? message.attachments : []) {
            attachmentCount++;
            const size = Number(attachment?.size ?? 0);
            if (Number.isFinite(size) && size > 0) knownBytes += size;
        }
    }
    const messageBytes = new TextEncoder().encode(JSON.stringify(messages)).byteLength;
    const estimatedSingleHtmlBytes = messageBytes + Math.ceil(knownBytes / 3) * 4;
    return { attachmentCount, estimatedSingleHtmlBytes, knownBytes, messageCount: messages.length };
}

function ExportModal({ rootProps, channelId }: { rootProps: RenderModalProps; channelId: string; }) {
    const [format, setFormat] = useState<ExportFormat>("offlineArchive");
    const [options, setOptions] = useState<ExportOptions>(DEFAULT_OPTIONS);
    const [messages, setMessages] = useState<any[] | null>(null);
    const [status, setStatus] = useState("");
    const [busy, setBusy] = useState(false);
    const [progress, setProgress] = useState<ExportProgress>({ stage: "", processed: 0, total: 0, downloadedBytes: 0, failures: 0 });
    const controllerRef = React.useRef<AbortController | null>(null);
    const channel = ChannelStore.getChannel(channelId);
    const channelName = channel?.name ?? channelId;
    const offline = format === "offlineArchive" || format === "singleHtml";
    const summary = messages ? conversationSummary(messages) : null;

    React.useEffect(() => () => controllerRef.current?.abort(), []);

    function beginOperation(stage: string) {
        controllerRef.current?.abort();
        const controller = new AbortController();
        controllerRef.current = controller;
        setBusy(true);
        setStatus("");
        setProgress({ stage, processed: 0, total: 0, downloadedBytes: 0, failures: 0 });
        return controller;
    }

    function finishOperation(controller: AbortController) {
        if (controllerRef.current === controller) controllerRef.current = null;
        setBusy(false);
    }

    async function prepareMessages() {
        if (busy) return;
        const controller = beginOperation("Fetching messages");
        try {
            const collected = await fetchAllMessages(channelId, controller.signal, count => {
                setProgress({ stage: "Fetching messages", processed: count, total: 0, downloadedBytes: 0, failures: 0 });
            });
            throwIfAborted(controller.signal);
            setMessages(collected);
            setProgress({ stage: "Ready", processed: 0, total: 0, downloadedBytes: 0, failures: 0 });
            setStatus(`Ready to export ${collected.length} message${collected.length === 1 ? "" : "s"}.`);
        } catch (error) {
            if (isAbortError(error)) {
                setProgress({ stage: "Cancelled", processed: 0, total: 0, downloadedBytes: 0, failures: 0 });
                setStatus("Preparation cancelled.");
            } else {
                setProgress({ stage: "Failed", processed: 0, total: 0, downloadedBytes: 0, failures: 0 });
                setStatus(`Could not fetch messages: ${error instanceof Error ? error.message : String(error)}`);
            }
        } finally {
            finishOperation(controller);
        }
    }

    async function createExport() {
        if (busy || !messages) return;
        if (format === "singleHtml" && (summary?.estimatedSingleHtmlBytes ?? 0) >= SINGLE_HTML_WARNING_BYTES) {
            const proceed = window.confirm(`Single HTML is estimated at least ${formatBytes(summary?.estimatedSingleHtmlBytes)} from known messages and attachments. It may be very large or slow. Offline Archive is recommended. Continue anyway?`);
            if (!proceed) {
                setStatus("Single HTML export cancelled before downloading media.");
                return;
            }
        }

        const controller = beginOperation(format === "json" || format === "onlineHtml" ? "Building document" : "Preparing media list");
        try {
            const baseName = `${safeFilename(channelName)}-export`;
            if (format === "json") {
                downloadBlob(rawJson(messages, channelName), `${baseName}.json`, "application/json;charset=utf-8");
            } else {
                const catalog = collectAssetRequests(messages, offline ? options : DEFAULT_OPTIONS);
                if (format === "onlineHtml") {
                    const html = renderConversationHtml(messages, channelName, "online", createOnlineAliases(catalog));
                    throwIfAborted(controller.signal);
                    downloadBlob(html, `${baseName}-online.html`, "text/html;charset=utf-8");
                } else {
                    setProgress({ stage: "Downloading media", processed: 0, total: catalog.requests.length, downloadedBytes: 0, failures: 0 });
                    const assets = await downloadAssetRequests(catalog, controller.signal, setProgress);
                    retainSkippedAssetLinks(collectAssetRequests(messages, DEFAULT_OPTIONS), assets);
                    throwIfAborted(controller.signal);
                    setProgress(current => ({ ...current, stage: format === "offlineArchive" ? "Building ZIP archive" : "Building self-contained HTML" }));
                    await delay(0, controller.signal);
                    if (format === "offlineArchive") {
                        const archive = createOfflineArchive(messages, channelName, options, assets);
                        throwIfAborted(controller.signal);
                        downloadBlob(archive.bytes as BlobPart, `${baseName}-offline.zip`, "application/zip");
                    } else {
                        const html = createSingleHtml(messages, channelName, assets);
                        throwIfAborted(controller.signal);
                        downloadBlob(html, `${baseName}-single.html`, "text/html;charset=utf-8");
                    }
                    const completion = assets.failures.length ? "Partial completion" : "Complete";
                    setProgress(current => ({ ...current, stage: completion }));
                    setStatus(`${completion}: ${messages.length} messages, ${assets.downloaded.length} assets downloaded, ${assets.failures.length} failed. Offline failures are shown in the transcript${format === "offlineArchive" ? " and download-report.txt" : ""}.`);
                    return;
                }
            }
            setProgress(current => ({ ...current, stage: "Complete" }));
            setStatus(`Complete: ${messages.length} message${messages.length === 1 ? "" : "s"} exported.`);
        } catch (error) {
            if (isAbortError(error)) {
                setProgress(current => ({ ...current, stage: "Cancelled" }));
                setStatus("Export cancelled. No completed download was created.");
            } else {
                setProgress(current => ({ ...current, stage: "Failed" }));
                setStatus(`Export failed: ${error instanceof Error ? error.message : String(error)}`);
            }
        } finally {
            finishOperation(controller);
        }
    }

    function updateOption(key: keyof ExportOptions, checked: boolean) {
        setOptions(current => ({ ...current, [key]: checked }));
    }

    const progressPercent = progress.total > 0 ? Math.min(100, progress.processed / progress.total * 100) : 0;
    return (
        <Modal {...rootProps} size="medium" title={`Export - ${channelName}`}>
            <style>{EXPORT_MODAL_CSS}</style>
            <div className="eq-export-modal">
                <div className="eq-export-format-grid" role="radiogroup" aria-label="Export format">
                    {FORMAT_CHOICES.map(choice => (
                        <button
                            key={choice.id}
                            type="button"
                            role="radio"
                            aria-checked={format === choice.id}
                            className={`eq-export-format${format === choice.id ? " eq-export-format--selected" : ""}`}
                            disabled={busy}
                            onClick={() => setFormat(choice.id)}
                        >
                            <span className="eq-export-format-head">{choice.title}{choice.badge && <span className="eq-export-badge">{choice.badge}</span>}</span>
                            <span className="eq-export-format-desc">{choice.description}</span>
                        </button>
                    ))}
                </div>

                {offline && (
                    <div className="eq-export-options" aria-label="Offline media options">
                        <label className="eq-export-option"><input type="checkbox" checked={options.attachments} disabled={busy} onChange={event => updateOption("attachments", event.currentTarget.checked)} />Attachments</label>
                        <label className="eq-export-option"><input type="checkbox" checked={options.avatars} disabled={busy} onChange={event => updateOption("avatars", event.currentTarget.checked)} />Author avatars</label>
                        <label className="eq-export-option"><input type="checkbox" checked={options.emojisStickers} disabled={busy} onChange={event => updateOption("emojisStickers", event.currentTarget.checked)} />Emojis and stickers</label>
                        <label className="eq-export-option"><input type="checkbox" checked={options.embedMedia} disabled={busy} onChange={event => updateOption("embedMedia", event.currentTarget.checked)} />Embed previews</label>
                    </div>
                )}

                {format === "onlineHtml" && <div className="eq-export-note">Internet access is required whenever this HTML file displays online media.</div>}
                {format === "singleHtml" && <div className="eq-export-note eq-export-warning">Downloaded media is base64-embedded once per asset. The resulting file can be much larger and slower than Offline Archive.</div>}

                {summary && (
                    <div className="eq-export-summary">
                        <strong>Export summary</strong>
                        <div className="eq-export-summary-grid">
                            <span className="eq-export-metric">Messages<strong>{summary.messageCount}</strong></span>
                            <span className="eq-export-metric">Attachments<strong>{summary.attachmentCount}</strong></span>
                            <span className="eq-export-metric">{format === "singleHtml" ? "Estimated output" : "Known media size"}<strong>{formatBytes(format === "singleHtml" ? summary.estimatedSingleHtmlBytes : summary.knownBytes)}</strong></span>
                        </div>
                    </div>
                )}

                {(busy || progress.stage) && (
                    <div className="eq-export-progress" aria-live="polite">
                        <div className="eq-export-progress-line"><strong>{progress.stage}</strong><span>{progress.total ? `${progress.processed}/${progress.total} assets` : `${progress.processed} messages`}</span></div>
                        <div className="eq-export-progress-line"><span>{formatBytes(progress.downloadedBytes)} downloaded</span><span>{progress.failures} failures</span></div>
                        {progress.total > 0 && <div className="eq-export-bar" aria-hidden="true"><span style={{ width: `${progressPercent}%` }} /></div>}
                    </div>
                )}

                {status && <div className="eq-export-status" role="status">{status}</div>}
                <Divider style={{ margin: "16px 0 0" }} />
                <div className="eq-export-actions">
                    <button type="button" className="eq-export-button eq-export-button--primary" disabled={busy} onClick={messages ? createExport : prepareMessages}>
                        {busy ? "Working..." : messages ? "Create export" : "Prepare export"}
                    </button>
                    {busy && <button type="button" className="eq-export-button eq-export-button--cancel" onClick={() => controllerRef.current?.abort()}>Cancel</button>}
                </div>
            </div>
        </Modal>
    );
}

const patchDMContext: NavContextMenuPatchCallback = (children, { channel }) => {
    if (!channel) return;
    children.push(
        <Menu.MenuItem
            id="export-dm"
            key="export-dm"
            label="Export DM"
            action={() => openModal(props => <ExportModal rootProps={props} channelId={channel.id} />)}
        />
    );
};

const patchChannelContext: NavContextMenuPatchCallback = (children, { channel }) => {
    if (!channel) return;
    children.push(
        <Menu.MenuItem
            id="export-dm"
            key="export-dm"
            label="Export Messages"
            action={() => openModal(props => <ExportModal rootProps={props} channelId={channel.id} />)}
        />
    );
};

export const ExportDmTestApi = {
    collectAssetRequests,
    createOfflineArchive,
    createOnlineAliases,
    createSingleHtml,
    downloadAssetRequests,
    renderConversationHtml,
    safeFilename,
    sanitizeFilenamePart
};

export default definePlugin({
    name: "ExportDM",
    description: "Export messages as raw JSON, online HTML, a complete offline ZIP archive, or one self-contained HTML file.",
    authors: [{ name: "sqlu", id: 0n }],
    enabledByDefault: true,
    dependencies: ["ContextMenuAPI"],
    start() {
        addContextMenuPatch("gdm-context", patchDMContext);
        addContextMenuPatch("user-context", patchDMContext);
        addContextMenuPatch("channel-context", patchChannelContext);
    },
    stop() {
        removeContextMenuPatch("gdm-context", patchDMContext);
        removeContextMenuPatch("user-context", patchDMContext);
        removeContextMenuPatch("channel-context", patchChannelContext);
    }
});

'@
    if (Write-Utf8FileAtomic -Path (Join-Path $dir "index.tsx") -Content $content1) { $changed = $true }
    return $changed
}

function Write-PluginServerCloner {
    param([Parameter(Mandatory = $true)][string]$PluginsDir)
    $dir = Get-SafeChildPath -Root $PluginsDir -Child "serverCloner"
    $changed = $false
    $content1 = @'
/*
 * Vencord, a Discord client mod
 * Copyright (c) 2026 Vendicated and contributors
 * SPDX-License-Identifier: GPL-3.0-or-later
 */

import { addContextMenuPatch, NavContextMenuPatchCallback, removeContextMenuPatch } from "@api/ContextMenu";
import { definePluginSettings } from "@api/Settings";
import { FormSwitch } from "@components/FormSwitch";
import { sleep } from "@utils/misc";
import definePlugin, { OptionType } from "@utils/types";
import type { RenderModalProps } from "@vencord/discord-types";
import { findStoreLazy } from "@webpack";
import { Button, Forms, GuildStore, IconUtils, Menu, Modal, openModal, React, RestAPI, Select, Toasts, useMemo, useRef, UserStore, useState } from "@webpack/common";

const F = Forms as any;
const PermissionStore = findStoreLazy("PermissionStore");
const ADMIN_BIT = 0x8n;

function hasAdmin(guildId: string): boolean { try { const guild = GuildStore.getGuild(guildId); if (!guild) return false; const me = UserStore.getCurrentUser(); if (guild.ownerId === me.id) return true; const perms = PermissionStore.getGuildPermissions({ id: guildId }); if (typeof perms === "bigint") return (perms & ADMIN_BIT) === ADMIN_BIT; return false; } catch { return false; } }
async function apiCall(method: "get" | "post" | "patch" | "put" | "del", url: string, body?: any): Promise<any> { const opts: any = { url }; if (body) opts.body = body; const res = await (RestAPI as any)[method](opts); const status = Number(res?.status ?? 200); if (res?.ok === false || status >= 400) throw new Error(res?.body?.message || `HTTP ${status}`); return res?.body; }
async function wait(ms: number) { await sleep(ms); }
function mapPermOverwrites(overwrites: any[], roleMapping: Map<string, string>): any[] { return overwrites.filter(ow => roleMapping.has(ow.id)).map(ow => ({ id: roleMapping.get(ow.id)!, type: ow.type, allow: String(ow.allow), deny: String(ow.deny) })); }

interface CloneOptions { roles: boolean; clearRoles: boolean; channels: boolean; noDeleteChannels: boolean; permissions: boolean; icon: boolean; emojis: boolean; guildSettings: boolean; }
interface LogEntry { text: string; type: "ok" | "err" | "warn" | "info"; }

let _running = false; let _cancelled = false; let _progress = 0; let _logs: LogEntry[] = [];
const MAX_LOG_ENTRIES = 1000;
const _listeners = new Set<() => void>();
function notifyListeners() { _listeners.forEach(fn => fn()); }
function persistLog(entry: LogEntry) { _logs = [..._logs, entry].slice(-MAX_LOG_ENTRIES); notifyListeners(); }
function persistProgress(p: number) { _progress = p; notifyListeners(); }
function persistRunning(v: boolean) { _running = v; notifyListeners(); }

async function cloneServer(sourceId: string, targetId: string, options: CloneOptions, log: (e: LogEntry) => void, setProgress: (p: number) => void) {
    _cancelled = false;
    if (!UserStore.getCurrentUser()) { log({ text: "Discord user was not found. Restart Discord, then try again.", type: "err" }); return; }
    const steps = [options.guildSettings && "settings", options.icon && "icon", options.roles && "roles", options.channels && "channels", options.emojis && "emojis"].filter(Boolean) as string[];
    let currentStep = 0;
    const advance = (name: string) => { currentStep++; setProgress(Math.round((currentStep / steps.length) * 100)); log({ text: `-- ${name} done (${currentStep}/${steps.length})`, type: "info" }); };
    const isCancelled = () => { if (_cancelled) { log({ text: "Cancelled.", type: "warn" }); return true; } return false; };
    const sourceGuild = GuildStore.getGuild(sourceId); if (!sourceGuild) { log({ text: "Source server not found", type: "err" }); return; }
    log({ text: `Cloning "${sourceGuild.name}"...`, type: "info" });
    if (options.guildSettings && !isCancelled()) { try { const patch: any = {}; if (sourceGuild.name) patch.name = sourceGuild.name; if (sourceGuild.description) patch.description = sourceGuild.description; if (Object.keys(patch).length) { await apiCall("patch", `/guilds/${targetId}`, patch); log({ text: "Settings copied", type: "ok" }); } } catch (e: any) { log({ text: `Settings error: ${e?.message}`, type: "err" }); } await wait(500); advance("Settings"); }
    if (options.icon && sourceGuild.icon && !isCancelled()) { try { const iconUrl = IconUtils?.getGuildIconURL({ id: sourceId, icon: sourceGuild.icon, size: 512 }) ?? ""; if (iconUrl) { const blob = await (await fetch(iconUrl)).blob(); const base64 = await new Promise<string>(res => { const r = new FileReader(); r.onloadend = () => res(r.result as string); r.readAsDataURL(blob); }); await apiCall("patch", `/guilds/${targetId}`, { icon: base64 }); log({ text: "Icon copied", type: "ok" }); } } catch (e: any) { log({ text: `Icon error: ${e?.message}`, type: "err" }); } await wait(500); advance("Icon"); } else if (options.icon) advance("Icon");
    const roleMapping = new Map<string, string>();
    if (options.roles && !isCancelled()) { try { const sourceRoles: any[] = await apiCall("get", `/guilds/${sourceId}/roles`); const targetRoles: any[] = await apiCall("get", `/guilds/${targetId}/roles`); if (options.clearRoles) { for (const r of targetRoles) { if (r.name === "@everyone" || r.managed) continue; try { await apiCall("del", `/guilds/${targetId}/roles/${r.id}`); await wait(300); } catch { } } } const evSrc = sourceRoles.find(r => r.name === "@everyone"); const updatedTarget: any[] = await apiCall("get", `/guilds/${targetId}/roles`); const evTgt = updatedTarget.find(r => r.name === "@everyone"); if (evSrc && evTgt) roleMapping.set(evSrc.id, evTgt.id); for (const role of sourceRoles.filter(r => r.name !== "@everyone").sort((a, b) => b.position - a.position)) { try { const body: any = { name: role.name, color: role.color, hoist: role.hoist, mentionable: role.mentionable }; if (options.permissions && role.permissions != null) body.permissions = String(role.permissions); const created = await apiCall("post", `/guilds/${targetId}/roles`, body); roleMapping.set(role.id, created.id); log({ text: `  Role: ${role.name}`, type: "ok" }); await wait(300); } catch (e: any) { log({ text: `  Role error "${role.name}": ${e?.message}`, type: "err" }); } } } catch (e: any) { log({ text: `Roles error: ${e?.message}`, type: "err" }); } await wait(500); advance("Roles"); }
    const channelMapping = new Map<string, string>();
    if (options.channels && !isCancelled()) { try { const sourceChannels: any[] = await apiCall("get", `/guilds/${sourceId}/channels`); if (!options.noDeleteChannels) { const tgt: any[] = await apiCall("get", `/guilds/${targetId}/channels`); for (const ch of tgt) { try { await apiCall("del", `/channels/${ch.id}`); await wait(300); } catch { } } } for (const cat of sourceChannels.filter(c => c.type === 4).sort((a, b) => a.position - b.position)) { if (_cancelled) break; try { const body: any = { name: cat.name, type: 4, position: cat.position }; if (options.permissions && cat.permission_overwrites?.length) body.permission_overwrites = mapPermOverwrites(cat.permission_overwrites, roleMapping); const created = await apiCall("post", `/guilds/${targetId}/channels`, body); channelMapping.set(cat.id, created.id); log({ text: `  Category: ${cat.name}`, type: "ok" }); await wait(500); } catch (e: any) { log({ text: `  Category error: ${e?.message}`, type: "err" }); } } for (const ch of sourceChannels.filter(c => c.type !== 4).sort((a, b) => a.position - b.position)) { if (_cancelled) break; try { const body: any = { name: ch.name, type: ch.type, position: ch.position, topic: ch.topic, nsfw: ch.nsfw ?? false, bitrate: ch.bitrate, user_limit: ch.user_limit, rate_limit_per_user: ch.rate_limit_per_user }; if (ch.parent_id && channelMapping.has(ch.parent_id)) body.parent_id = channelMapping.get(ch.parent_id); if (options.permissions && ch.permission_overwrites?.length) body.permission_overwrites = mapPermOverwrites(ch.permission_overwrites, roleMapping); const created = await apiCall("post", `/guilds/${targetId}/channels`, body); channelMapping.set(ch.id, created.id); log({ text: `  Channel: #${ch.name}`, type: "ok" }); await wait(500); } catch (e: any) { log({ text: `  Channel error: ${e?.message}`, type: "err" }); } } } catch (e: any) { log({ text: `Channels error: ${e?.message}`, type: "err" }); } await wait(500); advance("Channels"); }
    if (options.emojis && !isCancelled()) { try { const sourceEmojis: any[] = await apiCall("get", `/guilds/${sourceId}/emojis`); let count = 0; for (const emoji of sourceEmojis) { if (_cancelled) break; try { const emojiUrl = IconUtils?.getEmojiURL({ id: emoji.id, animated: emoji.animated, size: 128 }) ?? ""; if (!emojiUrl) continue; const blob = await (await fetch(emojiUrl)).blob(); const base64 = await new Promise<string>(res => { const r = new FileReader(); r.onloadend = () => res(r.result as string); r.readAsDataURL(blob); }); await apiCall("post", `/guilds/${targetId}/emojis`, { name: emoji.name, image: base64, roles: [] }); count++; log({ text: `  Emoji: ${emoji.name} (${count}/${sourceEmojis.length})`, type: "ok" }); await wait(3000); } catch (e: any) { log({ text: `  Emoji error: ${e?.message}`, type: "err" }); } } } catch (e: any) { log({ text: `Emojis error: ${e?.message}`, type: "err" }); } advance("Emojis"); }
    setProgress(100);
    if (_cancelled) { Toasts.show({ message: "Cloning cancelled.", type: Toasts.Type.FAILURE, id: Toasts.genId() }); }
    else { log({ text: "Done.", type: "info" }); Toasts.show({ message: "Server cloning finished!", type: Toasts.Type.SUCCESS, id: Toasts.genId() }); }
}

function ServerClonerUI({ initialSourceId = "" }: { initialSourceId?: string }) {
    const [sourceId, setSourceId] = useState<string>(initialSourceId); const [targetId, setTargetId] = useState<string>("");
    const [opts, setOpts] = useState<CloneOptions>({ roles: true, clearRoles: true, channels: true, noDeleteChannels: false, permissions: true, icon: true, emojis: true, guildSettings: true });
    const [, forceUpdate] = useState(0); const logRef = useRef<HTMLDivElement>(null);
    React.useEffect(() => { const l = () => forceUpdate(n => n + 1); _listeners.add(l); return () => { _listeners.delete(l); }; }, []);
    React.useEffect(() => { if (logRef.current) logRef.current.scrollTop = logRef.current.scrollHeight; }, [_logs.length]);
    const allGuilds = useMemo(() => Object.values(GuildStore.getGuilds() as Record<string, any>).sort((a, b) => a.name.localeCompare(b.name)).map(g => ({ label: g.name, value: g.id })), []);
    const adminGuilds = useMemo(() => allGuilds.filter(g => hasAdmin(g.value)), [allGuilds]);
    async function startClone() { if (!sourceId || !targetId || _running) return; if (sourceId === targetId) { persistLog({ text: "Source and target cannot be the same!", type: "err" }); return; } persistRunning(true); _progress = 0; _logs = []; notifyListeners(); try { await cloneServer(sourceId, targetId, opts, persistLog, persistProgress); } catch (e: any) { persistLog({ text: `Fatal: ${e?.message}`, type: "err" }); } persistRunning(false); }
    const logColors: Record<string, string> = { ok: "#3ba55d", err: "#ed4245", warn: "#faa81a", info: "#dcddde" };
    const OPTS = [{ key: "guildSettings", label: "Server settings" }, { key: "icon", label: "Icon" }, { key: "roles", label: "Roles" }, { key: "clearRoles", label: "Delete existing roles" }, { key: "channels", label: "Channels" }, { key: "noDeleteChannels", label: "Keep existing channels" }, { key: "permissions", label: "Permissions" }, { key: "emojis", label: "Emojis" }] as const;
    return (
        <div style={{ display: "flex", flexDirection: "column", gap: 16 }}>
            <F.FormSection><F.FormTitle>Source server</F.FormTitle><Select options={allGuilds} placeholder="Choose..." isSelected={v => v === sourceId} select={v => setSourceId(v)} serialize={v => v} /></F.FormSection>
            <F.FormSection><F.FormTitle>Target server (ADMIN required)</F.FormTitle>{adminGuilds.length === 0 ? <F.FormText style={{ color: "var(--text-danger)" }}>No admin servers found.</F.FormText> : <Select options={adminGuilds} placeholder="Choose..." isSelected={v => v === targetId} select={v => setTargetId(v)} serialize={v => v} />}</F.FormSection>
            <F.FormDivider />
            <F.FormSection><F.FormTitle>Options</F.FormTitle><div style={{ display: "grid", gridTemplateColumns: "1fr 1fr", gap: "0 24px" }}>{OPTS.map(o => <FormSwitch key={o.key} title={o.label} value={opts[o.key]} onChange={v => setOpts(p => ({ ...p, [o.key]: v }))} disabled={_running} hideBorder />)}</div></F.FormSection>
            <F.FormDivider />
            <div style={{ display: "flex", gap: 8 }}>
                <Button size={Button.Sizes.MEDIUM} color={_running ? Button.Colors.PRIMARY : Button.Colors.BRAND} disabled={!sourceId || !targetId || _running} onClick={startClone} style={{ flex: 1 }}>{_running ? "Cloning..." : "Start cloning"}</Button>
                {_running && <Button size={Button.Sizes.MEDIUM} color={Button.Colors.RED} onClick={() => { _cancelled = true; }} style={{ minWidth: 100 }}>Stop</Button>}
            </div>
            {_running && <div style={{ height: 8, background: "var(--background-modifier-accent)", borderRadius: 4, overflow: "hidden" }}><div style={{ height: "100%", width: `${_progress}%`, background: "var(--brand-experiment)", transition: "width 0.3s" }} /></div>}
            {_logs.length > 0 && <div ref={logRef} style={{ maxHeight: 200, overflowY: "auto", background: "var(--background-secondary)", borderRadius: 4, padding: 8, fontFamily: "monospace", fontSize: 12 }}>{_logs.map((l, i) => <div key={i} style={{ color: logColors[l.type], marginBottom: 2 }}>{l.text}</div>)}</div>}
        </div>
    );
}

function ServerClonerModal({ rootProps, guildId }: { rootProps: RenderModalProps; guildId: string }) {
    return <Modal {...rootProps} size="lg" title="Server Cloner"><div style={{ paddingBottom: 8 }}><ServerClonerUI initialSourceId={guildId} /></div></Modal>;
}

const patchGuildContext: NavContextMenuPatchCallback = (children, { guild }) => { if (!children || !Array.isArray(children) || !guild) return; try { children.push(<Menu.MenuItem id="server-cloner" key="server-cloner" label="ServerCloner" action={() => openModal(props => <ServerClonerModal rootProps={props} guildId={guild.id} />)} />); } catch { } };
const settings = definePluginSettings({ cloner: { type: OptionType.COMPONENT, description: "", component: ServerClonerUI as any } });

export default definePlugin({
    name: "ServerCloner", enabledByDefault: true,
    description: "Clone an entire server to another server where you have ADMIN. Right-click a server to open.",
    authors: [{ name: "Nightcord", id: 0n }], settings,
    start() { addContextMenuPatch("guild-context", patchGuildContext); },
    stop() { removeContextMenuPatch("guild-context", patchGuildContext); _cancelled = true; _running = false; _listeners.clear(); }
});

'@
    if (Write-Utf8FileAtomic -Path (Join-Path $dir "index.tsx") -Content $content1) { $changed = $true }
    return $changed
}

function Write-PluginAntiDeleteMessage {
    param([Parameter(Mandatory = $true)][string]$PluginsDir)
    $dir = Get-SafeChildPath -Root $PluginsDir -Child "antiDeleteMessage"
    $changed = $false
    $content1 = @'
/*
 * Vencord, a Discord client mod
 * Copyright (c) 2026 Vendicated and contributors
 * SPDX-License-Identifier: GPL-3.0-or-later
 */

import * as DataStore from "@api/DataStore";
import { definePluginSettings } from "@api/Settings";
import { Logger } from "@utils/Logger";
import definePlugin, { OptionType } from "@utils/types";
import { Constants, RestAPI, UserStore } from "@webpack/common";
const logger = new Logger("AntiDeleteMessage");
const settings = definePluginSettings({
    enabled: { type: OptionType.BOOLEAN, description: "Enable automatic message restoration", default: true },
    dmProtection: { type: OptionType.BOOLEAN, description: "Also protect DMs", default: false },
    maxCacheSize: { type: OptionType.NUMBER, description: "Max messages cached", default: 500 },
    serverBlacklist: { type: OptionType.STRING, description: "Server IDs to ignore (comma-separated)", default: "" }
});
const DB_KEY = "AntiDeleteMessage_cache";
interface CachedMessage { content: string; channelId: string; nonce: string; guildId?: string; messageReference?: any; savedAt: number; }
let memCache: Record<string, CachedMessage> = {}; let dbLoaded = false;
async function loadCache() { try { const stored = await DataStore.get<Record<string, CachedMessage>>(DB_KEY); if (stored && typeof stored === "object") memCache = stored; } catch (error) { logger.error("Failed to load the message cache", error); } finally { dbLoaded = true; } }
let saveTimer: ReturnType<typeof setTimeout> | null = null;
const resendTimers = new Set<ReturnType<typeof setTimeout>>();
function scheduleSave() { if (saveTimer) clearTimeout(saveTimer); saveTimer = setTimeout(async () => { saveTimer = null; try { await DataStore.set(DB_KEY, memCache); } catch (error) { logger.error("Failed to save the message cache", error); } }, 1000); }
function getBlacklist() { return new Set((settings.store.serverBlacklist ?? "").split(",").map((s: string) => s.trim()).filter(Boolean)); }
function addToCache(id: string, data: CachedMessage) { const max = Math.max(10, Math.min(5000, Number(settings.store.maxCacheSize) || 500)); const ids = Object.keys(memCache); if (ids.length >= max) ids.sort((a, b) => (memCache[a].savedAt ?? 0) - (memCache[b].savedAt ?? 0)).slice(0, Math.max(1, Math.floor(max * 0.1))).forEach(k => delete memCache[k]); memCache[id] = data; scheduleSave(); }
async function resendMessage(c: CachedMessage) { try { const body: any = { content: c.content, flags: 0, mobile_network_type: "unknown", nonce: c.nonce, tts: false }; if (c.messageReference) body.message_reference = c.messageReference; const response = await RestAPI.post({ url: Constants.Endpoints.MESSAGES(c.channelId), body }); const status = Number(response?.status ?? 200); if (response?.ok === false || status >= 400) throw new Error(`Discord returned ${status}`); } catch (error) { logger.error("Failed to restore a deleted message", error); } }
export default definePlugin({
    name: "AntiDeleteMessage", description: "Automatically resends your messages if someone deletes them.", authors: [{ name: "Nightcord", id: 0n }], enabledByDefault: false, settings,
    flux: {
        MESSAGE_CREATE({ message, guildId }: { message: { id: string; author: { id: string; }; content: string; channel_id: string; nonce?: string; message_reference?: any; }; guildId?: string; }) {
            if (!settings.store.enabled || !dbLoaded) return;
            const me = UserStore.getCurrentUser(); if (!me || message.author.id !== me.id || !message.content?.trim()) return;
            if (!guildId && !settings.store.dmProtection) return;
            if (guildId && getBlacklist().has(guildId)) return;
            addToCache(message.id, { content: message.content, channelId: message.channel_id, nonce: message.id, guildId, messageReference: message.message_reference, savedAt: Date.now() });
        },
        MESSAGE_DELETE({ id, channelId }: { id: string; channelId: string; }) {
            if (!settings.store.enabled) return; const c = memCache[id]; if (!c) return;
            if (c.guildId && getBlacklist().has(c.guildId)) { delete memCache[id]; scheduleSave(); return; }
            delete memCache[id]; scheduleSave(); const timer = setTimeout(() => { resendTimers.delete(timer); resendMessage(c); }, 400); resendTimers.add(timer);
        },
    },
    async start() { await loadCache(); },
    stop() { if (saveTimer) { clearTimeout(saveTimer); saveTimer = null; DataStore.set(DB_KEY, memCache).catch(error => logger.error("Failed to flush the message cache", error)); } resendTimers.forEach(timer => clearTimeout(timer)); resendTimers.clear(); memCache = {}; dbLoaded = false; }
});

'@
    if (Write-Utf8FileAtomic -Path (Join-Path $dir "index.ts") -Content $content1) { $changed = $true }
    return $changed
}

function Write-PluginLastSeen {
    param([Parameter(Mandatory = $true)][string]$PluginsDir)
    $dir = Get-SafeChildPath -Root $PluginsDir -Child "lastSeen"
    $changed = $false
    $content1 = @'
/*
 * Vencord, a Discord client mod
 * Copyright (c) 2026 Vendicated and contributors
 * SPDX-License-Identifier: GPL-3.0-or-later
 */

import * as DataStore from "@api/DataStore";
import { definePluginSettings } from "@api/Settings";
import ErrorBoundary from "@components/ErrorBoundary";
import { Logger } from "@utils/Logger";
import definePlugin, { OptionType } from "@utils/types";
import { findByPropsLazy, findComponentByCodeLazy } from "@webpack";
import { React, useStateFromStores } from "@webpack/common";

const Section = findComponentByCodeLazy("headingVariant:", '"section"', "headingIcon:");
const PresenceStore = findByPropsLazy("getStatus", "getActivities");
const logger = new Logger("LastSeen");

const settings = definePluginSettings({
    language: {
        type: OptionType.SELECT,
        description: "Language",
        options: [
            { label: "English", value: "en", default: true },
            { label: "Francais", value: "fr" }
        ]
    }
});

const STORAGE_KEY = "LastSeen_entries_v2";
const LEGACY_PREFIX = "lastseen_";
const MAX_ENTRIES = 2000;
const SAVE_DELAY_MS = 1000;

let entries: Record<string, number> = {};
let cacheLoaded = false;
let loadPromise: Promise<void> | null = null;
let saveTimer: ReturnType<typeof setTimeout> | null = null;
const listeners = new Set<() => void>();

function notifyListeners() {
    listeners.forEach(listener => listener());
}

function trimEntries() {
    const ids = Object.keys(entries);
    if (ids.length <= MAX_ENTRIES) return;
    ids.sort((a, b) => entries[b] - entries[a]);
    entries = Object.fromEntries(ids.slice(0, MAX_ENTRIES).map(id => [id, entries[id]]));
}

async function ensureCacheLoaded() {
    if (cacheLoaded) return;
    if (loadPromise) return loadPromise;

    loadPromise = (async () => {
        try {
            const stored = await DataStore.get<Record<string, number>>(STORAGE_KEY);
            const valid: Record<string, number> = {};
            if (stored && typeof stored === "object") {
                for (const [id, timestamp] of Object.entries(stored)) {
                    const value = Number(timestamp);
                    if (/^\d+$/.test(id) && Number.isFinite(value) && value > 0) valid[id] = value;
                }
            }
            entries = { ...valid, ...entries };
            trimEntries();
        } catch (error) {
            logger.error("Failed to load stored activity timestamps", error);
        } finally {
            cacheLoaded = true;
            loadPromise = null;
            notifyListeners();
        }
    })();

    return loadPromise;
}

function scheduleSave() {
    if (saveTimer) clearTimeout(saveTimer);
    saveTimer = setTimeout(async () => {
        saveTimer = null;
        await ensureCacheLoaded();
        try {
            await DataStore.set(STORAGE_KEY, entries);
        } catch (error) {
            logger.error("Failed to save activity timestamps", error);
        }
    }, SAVE_DELAY_MS);
}

function recordSeen(userId: string | undefined, timestamp = Date.now()) {
    if (!userId || !/^\d+$/.test(userId)) return;
    void ensureCacheLoaded();
    entries[userId] = timestamp;
    trimEntries();
    scheduleSave();
    notifyListeners();
}

async function migrateLegacyEntry(userId: string) {
    await ensureCacheLoaded();
    if (entries[userId]) return;
    const legacyKey = LEGACY_PREFIX + userId;
    try {
        const value = Number(await DataStore.get(legacyKey));
        if (Number.isFinite(value) && value > 0) {
            recordSeen(userId, value);
            await DataStore.del(legacyKey);
        }
    } catch (error) {
        logger.warn("Could not migrate a legacy activity timestamp", error);
    }
}

function formatTimestamp(timestamp: number): string {
    const now = new Date();
    const date = new Date(timestamp);
    const language = settings.store.language ?? "en";
    const locale = language === "fr" ? "fr-FR" : "en-US";
    const time = date.toLocaleTimeString(locale, { hour: "2-digit", minute: "2-digit", second: "2-digit" });

    if (date.toDateString() === now.toDateString()) return language === "fr" ? `Aujourd'hui a ${time}` : `Today at ${time}`;
    const yesterday = new Date(now);
    yesterday.setDate(now.getDate() - 1);
    if (date.toDateString() === yesterday.toDateString()) return language === "fr" ? `Hier a ${time}` : `Yesterday at ${time}`;
    const day = date.toLocaleDateString(locale, { day: "numeric", month: "short" });
    return language === "fr" ? `Le ${day} a ${time}` : `${day} at ${time}`;
}

function LastSeenText({ userId }: { userId: string; }) {
    const status = useStateFromStores([PresenceStore], () => PresenceStore.getStatus(userId));
    const [, forceUpdate] = React.useState(0);

    React.useEffect(() => {
        let active = true;
        const listener = () => { if (active) forceUpdate(value => value + 1); };
        listeners.add(listener);
        void migrateLegacyEntry(userId);
        return () => { active = false; listeners.delete(listener); };
    }, [userId]);

    if (!cacheLoaded) return null;
    const language = settings.store.language ?? "en";
    const isOnline = status && status !== "offline" && status !== "invisible";
    let content: string;
    let color = "#dcddde";

    if (isOnline) {
        if (status === "idle") { content = language === "fr" ? "Inactif" : "Idle"; color = "#faa81a"; }
        else if (status === "dnd") { content = language === "fr" ? "Ne pas deranger" : "Do Not Disturb"; color = "#ed4245"; }
        else if (status === "streaming") { content = language === "fr" ? "En direct" : "Streaming"; color = "#593695"; }
        else { content = language === "fr" ? "En ligne" : "Online"; color = "#3ba55d"; }
    } else if (entries[userId]) {
        content = formatTimestamp(entries[userId]);
        color = "#b5bac1";
    } else {
        content = language === "fr" ? "Pas encore trace" : "Not tracked yet";
        color = "#80848e";
    }

    return <div style={{ fontSize: "14px", lineHeight: "18px", color, WebkitTextFillColor: color, fontWeight: 400, userSelect: "text" } as React.CSSProperties}>{content}</div>;
}

const LastSeenSection = ErrorBoundary.wrap(({ userId, isSideBar }: { userId: string; isSideBar: boolean; }) => (
    <Section heading="Last Seen" headingVariant={isSideBar ? "text-xs/semibold" : "text-xs/medium"} headingColor={isSideBar ? "text-strong" : "text-default"}>
        <LastSeenText userId={userId} />
    </Section>
), { noop: true });

export default definePlugin({
    name: "LastSeen",
    description: "Shows when a user was last seen. Text always visible.",
    authors: [{ name: "nightcord", id: 0n }],
    enabledByDefault: true,
    dependencies: ["ProfileSectionsAPI"],
    settings,
    renderProfileSection: {
        render: LastSeenSection,
        priority: 0
    },
    flux: {
        PRESENCE_UPDATE(event: any) {
            if (Array.isArray(event?.updates)) event.updates.forEach((update: any) => recordSeen(update?.user?.id ?? update?.userId ?? update?.user_id));
            else recordSeen(event?.user?.id ?? event?.userId ?? event?.user_id);
        },
        PRESENCE_UPDATES(event: any) {
            const updates = Array.isArray(event?.updates) ? event.updates : Array.isArray(event) ? event : [event];
            updates.forEach((update: any) => recordSeen(update?.user?.id ?? update?.userId ?? update?.user_id));
        },
        MESSAGE_CREATE(event: any) { recordSeen(event?.message?.author?.id ?? event?.author?.id); },
        VOICE_STATE_UPDATES(event: any) { (event?.voiceStates ?? []).forEach((state: any) => recordSeen(state?.userId ?? state?.user_id)); },
        TYPING_START(event: any) { recordSeen(event?.userId ?? event?.user_id); },
        MESSAGE_REACTION_ADD(event: any) { recordSeen(event?.userId ?? event?.user_id); }
    },
    start() { void ensureCacheLoaded(); },
    stop() {
        if (saveTimer) {
            clearTimeout(saveTimer);
            saveTimer = null;
            void DataStore.set(STORAGE_KEY, entries).catch(error => logger.error("Failed to flush activity timestamps", error));
        }
        listeners.clear();
    }
});

'@
    if (Write-Utf8FileAtomic -Path (Join-Path $dir "index.tsx") -Content $content1) { $changed = $true }
    return $changed
}

function Write-PluginStreamProof {
    param([Parameter(Mandatory = $true)][string]$PluginsDir)
    $dir = Get-SafeChildPath -Root $PluginsDir -Child "streamProof"
    $changed = $false
    $content1 = @'
/*
 * Vencord, a Discord client mod
 * Copyright (c) 2026 Vendicated and contributors
 * SPDX-License-Identifier: GPL-3.0-or-later
 */

import { ChatBarButton, ChatBarButtonFactory } from "@api/ChatButtons";
import { definePluginSettings } from "@api/Settings";
import definePlugin, { OptionType } from "@utils/types";
import { findByPropsLazy } from "@webpack";
import { React, UserStore, useState, useStateFromStores } from "@webpack/common";
const StreamStore = findByPropsLazy("getActiveStreamForUser", "getAllActiveStreams");
const RTCConnectionStore = findByPropsLazy("getMediaSessionId");
const StreamerModeStore = findByPropsLazy("hidePersonalInformation");
const settings = definePluginSettings({ autoStreamProof: { type: OptionType.BOOLEAN, description: "Auto-enable when streaming", default: false, onChange(v: boolean) { if (v && isStreaming()) enableStreamProof(); } } });
let clickHandler: ((e: MouseEvent) => void) | null = null; let streamProofActive = false;
const stateListeners = new Set<(active: boolean) => void>();
function notifyState() { stateListeners.forEach(listener => listener(streamProofActive)); }
function isStreaming(): boolean { try { if (StreamerModeStore?.hidePersonalInformation) return true; const u = UserStore?.getCurrentUser?.(); if (!u) return false; if (StreamStore?.getActiveStreamForUser?.(u.id)) return true; const all = StreamStore?.getAllActiveStreams?.(); if (all?.length > 0 && all.find((s: any) => s.ownerId === u.id)) return true; if (RTCConnectionStore?.getMediaSessionId?.() && RTCConnectionStore?.getState?.()?.context === "stream") return true; return false; } catch { return false; } }
function handleStreamChange() { if (!settings.store.autoStreamProof) return; if (isStreaming()) enableStreamProof(); else disableStreamProof(); }
function enableStreamProof() { const changed = !streamProofActive; streamProofActive = true; document.body.classList.add("stream-proof-enabled"); if (!clickHandler) { clickHandler = (e: MouseEvent) => { const t = e.target as HTMLElement | null; if (!t) return; const el = t.closest("[class*=\"messageContent_\"],[class*=\"markup_\"],[class*=\"imageWrapper_\"],[class*=\"embedWrapper_\"],[class*=\"attachment_\"],[class*=\"stickerAsset_\"]"); if (el && !el.classList.contains("stream-proof-revealed")) { el.classList.add("stream-proof-revealed"); e.preventDefault(); e.stopPropagation(); } }; document.addEventListener("click", clickHandler as any, true); } if (changed) notifyState(); }
function disableStreamProof() { const changed = streamProofActive; streamProofActive = false; document.body.classList.remove("stream-proof-enabled"); if (clickHandler) { document.removeEventListener("click", clickHandler as any, true); clickHandler = null; } document.querySelectorAll(".stream-proof-revealed").forEach(el => el.classList.remove("stream-proof-revealed")); if (changed) notifyState(); }
function EyeIcon() { return <svg aria-hidden="true" role="img" xmlns="http://www.w3.org/2000/svg" width="20" height="20" fill="none" viewBox="0 0 24 24"><path fill="currentColor" d="M12 5C5.648 5 1 12 1 12s4.648 7 11 7 11-7 11-7-4.648-7-11-7Zm0 12a5 5 0 1 1 0-10 5 5 0 0 1 0 10Zm0-8a3 3 0 1 0 0 6 3 3 0 0 0 0-6Z" /></svg>; }
function EyeSlashIcon() { return <svg aria-hidden="true" role="img" xmlns="http://www.w3.org/2000/svg" width="20" height="20" fill="none" viewBox="0 0 24 24"><path fill="currentColor" d="M2.22 2.22a.75.75 0 0 1 1.06 0l18.5 18.5a.75.75 0 1 1-1.06 1.06l-3.56-3.56A11.18 11.18 0 0 1 12 19C5.648 19 1 12 1 12s1.81-2.73 4.69-4.95L2.22 3.28a.75.75 0 0 1 0-1.06ZM12 5c1.92 0 3.7.52 5.25 1.37l-1.5 1.5A8.87 8.87 0 0 0 20.93 12a9.57 9.57 0 0 1-3.37 3.44l1.5 1.5C21.42 15.2 23 12 23 12s-4.648-7-11-7Z" /></svg>; }
const StreamProofButton: ChatBarButtonFactory = ({ isMainChat }) => {
    useStateFromStores([StreamerModeStore, StreamStore, RTCConnectionStore], () => isStreaming());
    const [active, setActive] = useState(streamProofActive);
    React.useEffect(() => { stateListeners.add(setActive); return () => { stateListeners.delete(setActive); }; }, []);
    if (!isMainChat) return null;
    function toggle() { if (streamProofActive) disableStreamProof(); else enableStreamProof(); }
    return <ChatBarButton tooltip={active ? "StreamProof: ON (click to disable)" : "StreamProof: OFF (click to enable)"} onClick={toggle}><span style={{ color: active ? "var(--status-danger)" : "currentColor" }}>{active ? <EyeSlashIcon /> : <EyeIcon />}</span></ChatBarButton>;
};
export default definePlugin({
    name: "StreamProof", description: "Blurs Discord content while streaming. Click blurred content to reveal.", authors: [{ name: "TheArmagan", id: 0n }], dependencies: ["ChatInputButtonAPI"], enabledByDefault: true, settings,
    chatBarButton: { icon: EyeSlashIcon, render: StreamProofButton },
    flux: { STREAM_START() { handleStreamChange(); }, STREAM_STOP() { handleStreamChange(); }, STREAM_CREATE() { handleStreamChange(); }, STREAM_DELETE() { handleStreamChange(); }, STREAMER_MODE_UPDATE() { handleStreamChange(); }, RTC_CONNECTION_STATE() { handleStreamChange(); } },
    start() { document.getElementById("stream-proof-styles")?.remove(); const s = document.createElement("style"); s.id = "stream-proof-styles"; s.textContent = ".stream-proof-enabled [class*=\"messageContent_\"],.stream-proof-enabled [class*=\"markup_\"],.stream-proof-enabled [class*=\"imageWrapper_\"],.stream-proof-enabled [class*=\"embedWrapper_\"],.stream-proof-enabled [class*=\"attachment_\"],.stream-proof-enabled [class*=\"stickerAsset_\"]{filter:blur(12px);transition:filter 0.2s ease;cursor:pointer}.stream-proof-enabled .stream-proof-revealed{filter:none!important;cursor:unset!important}"; document.head.appendChild(s); if (settings.store.autoStreamProof && isStreaming()) enableStreamProof(); },
    stop() { document.getElementById("stream-proof-styles")?.remove(); disableStreamProof(); stateListeners.clear(); }
});

'@
    if (Write-Utf8FileAtomic -Path (Join-Path $dir "index.tsx") -Content $content1) { $changed = $true }
    return $changed
}

function Write-PluginFakePerm {
    param([Parameter(Mandatory = $true)][string]$PluginsDir)
    $dir = Get-SafeChildPath -Root $PluginsDir -Child "fakePerm"
    $changed = $false
    $content1 = @'
/*
 * Vencord, a Discord client mod
 * Copyright (c) 2026 Vendicated and contributors
 * SPDX-License-Identifier: GPL-3.0-or-later
 */

import { addContextMenuPatch, NavContextMenuPatchCallback, removeContextMenuPatch } from "@api/ContextMenu";
import { definePluginSettings } from "@api/Settings";
import definePlugin, { OptionType } from "@utils/types";
import type { RenderModalProps } from "@vencord/discord-types";
import { FluxDispatcher, GuildMemberStore, GuildRoleStore, GuildStore, Menu, Modal, openModal, React, SelectedGuildStore, showToast } from "@webpack/common";

const settings = definePluginSettings({
    enabled: {
        type: OptionType.BOOLEAN,
        description: "Enable fake moderation options in right-click menu",
        default: false,
        onChange(v: boolean) {
            if (!v) {
                document.querySelectorAll("[data-fp-hidden='true']").forEach(el => {
                    (el as HTMLElement).style.display = "";
                    (el as HTMLElement).removeAttribute("data-fp-hidden");
                });
                clearFakePermState();
            }
            showToast(v ? "FakePerm enabled" : "FakePerm disabled");
        }
    }
});

function isEnabled() { return settings.store.enabled; }
function fpHide(el: HTMLElement) { el.style.display = "none"; el.setAttribute("data-fp-hidden", "true"); }
const mutedUsers = new Map<string, boolean>(); const deafenedUsers = new Map<string, boolean>(); const fakeNicks = new Map<string, string>();
const disconnectedUsers = new Set<string>(); const kickedUsers = new Set<string>(); const bannedUsers = new Set<string>(); const deletedMessages = new Set<string>();
const timeoutTimers = new Set<ReturnType<typeof setTimeout>>();
function clearFakePermState() { mutedUsers.clear(); deafenedUsers.clear(); fakeNicks.clear(); disconnectedUsers.clear(); kickedUsers.clear(); bannedUsers.clear(); deletedMessages.clear(); timeoutTimers.forEach(timer => clearTimeout(timer)); timeoutTimers.clear(); }
function getCurrentGuildId(): string | null { try { return SelectedGuildStore?.getGuildId() ?? null; } catch { return null; } }
function notifyMemberListChange() { if (!isEnabled()) return; try { const guildId = getCurrentGuildId(); if (!guildId) return; FluxDispatcher?.dispatch({ type: "GUILD_MEMBER_LIST_UPDATE", ops: [], id: "everyone", guildId }); } catch {} }
function getMember(guildId: string | null, userId: string) { if (!guildId) return null; try { return GuildMemberStore?.getMember(guildId, userId) ?? null; } catch { return null; } }
function getGuildRoles(guildId: string | null): Array<{ id: string; name: string; color: number; }> {
    if (!guildId) return [];
    try { return (GuildRoleStore as any)?.getSortedRoles?.(guildId)?.filter((r: any) => r.id !== guildId).map((r: any) => ({ id: r.id, name: r.name, color: r.color })) ?? []; }
    catch { try { const g = (GuildStore as any)?.getGuild?.(guildId); if (!g?.roles) return []; return Object.values(g.roles as Record<string, any>).filter((r: any) => r.id !== guildId).sort((a: any, b: any) => b.position - a.position).map((r: any) => ({ id: r.id, name: r.name, color: r.color })); } catch { return []; } }
}
function getMemberRoleIds(guildId: string | null, userId: string): string[] { if (!guildId) return []; try { return (GuildMemberStore as any)?.getMember?.(guildId, userId)?.roles ?? []; } catch { return getMember(guildId, userId)?.roles ?? []; } }
function toast(msg: string) { try { showToast(msg); } catch {} }

function hideMessageInDOM(messageId: string) {
    let msgEl: HTMLElement | null = document.querySelector(`[id$="-${messageId}"]`) ?? document.querySelector(`[data-list-item-id$="${messageId}"]`);
    if (!msgEl) { for (const li of document.querySelectorAll("ol[data-list-id='chat-messages'] > li")) { if ((li as HTMLElement).id.includes(messageId)) { msgEl = li as HTMLElement; break; } } }
    if (!msgEl) return; fpHide(msgEl);
}

function RenameModal({ rootProps, user, guildId }: { rootProps: RenderModalProps; user: any; guildId: string | null; }) {
    const [nick, setNick] = React.useState<string>(fakeNicks.get(user.id) ?? getMember(guildId, user.id)?.nick ?? user.username ?? "");
    function applyNick() { const t = nick.trim(); if (t) fakeNicks.set(user.id, t); else fakeNicks.delete(user.id); notifyMemberListChange(); toast("Nickname changed"); rootProps.onClose(); }
    return <Modal {...rootProps} size="sm" title="Change Nickname" actions={[{ text: "Cancel", variant: "secondary", onClick: rootProps.onClose }, { text: "Apply", variant: "primary", onClick: applyNick }]}><input value={nick} onChange={e => setNick(e.target.value)} autoFocus maxLength={32} onKeyDown={e => { if (e.key === "Enter") applyNick(); }} style={{ width: "100%", background: "#383a40", border: "1px solid rgba(255,255,255,0.15)", borderRadius: "8px", padding: "10px 12px", color: "#fff", fontSize: "16px", outline: "none", boxSizing: "border-box" as any }} /></Modal>;
}

function KickModal({ rootProps, user, guildId }: { rootProps: RenderModalProps; user: any; guildId: string | null; }) {
    const [reason, setReason] = React.useState(""); const tag = user.username ?? "";
    function kick() { kickedUsers.add(user.id); disconnectedUsers.add(user.id); notifyMemberListChange(); toast(`@${tag} kicked (local)`); rootProps.onClose(); }
    return <Modal {...rootProps} size="sm" title={`Kick ${user.globalName ?? user.username}`} actions={[{ text: "Cancel", variant: "secondary", onClick: rootProps.onClose }, { text: "Kick", variant: "critical-primary", onClick: kick }]}><textarea value={reason} onChange={e => setReason(e.target.value)} placeholder="Reason" style={{ width: "100%", height: "80px", background: "#1e1f22", border: "1px solid #1e1f22", borderRadius: "4px", padding: "10px", color: "#fff", fontSize: "14px", resize: "none", outline: "none", boxSizing: "border-box" as any }} /></Modal>;
}

function BanModal({ rootProps, user }: { rootProps: RenderModalProps; user: any; }) {
    const [reason, setReason] = React.useState<string | null>(null);
    const REASONS = [{ label: "Suspicious/spam", value: "spam" }, { label: "Compromised", value: "comp" }, { label: "Rule violation", value: "rules" }, { label: "Other", value: "other" }];
    function ban() { if (!reason) return toast("Select a reason"); bannedUsers.add(user.id); kickedUsers.add(user.id); disconnectedUsers.add(user.id); notifyMemberListChange(); toast(`@${user.username} banned (local)`); rootProps.onClose(); }
    return <Modal {...rootProps} size="sm" title={`Ban @${user.username}?`} actions={[{ text: "Cancel", variant: "secondary", onClick: rootProps.onClose }, { text: "Ban", variant: "critical-primary", onClick: ban }]}>{REASONS.map(opt => <label key={opt.value} style={{ display: "flex", alignItems: "center", gap: "12px", cursor: "pointer", fontSize: "16px", color: "#fff", userSelect: "none" as any, marginBottom: 12 }} onClick={() => setReason(opt.value)}><div style={{ width: 20, height: 20, borderRadius: "50%", flexShrink: 0, border: reason === opt.value ? "6px solid #5865f2" : "2px solid #4e5058", background: reason === opt.value ? "#fff" : "transparent", boxSizing: "border-box" as any }} />{opt.label}</label>)}</Modal>;
}

const TDs = [{ label: "60s", seconds: 60 }, { label: "5m", seconds: 300 }, { label: "10m", seconds: 600 }, { label: "1h", seconds: 3600 }, { label: "1d", seconds: 86400 }, { label: "1w", seconds: 604800 }];
function TimeoutModal({ rootProps, user }: { rootProps: RenderModalProps; user: any; }) {
    const [idx, setIdx] = React.useState(0); const tag = user.username ?? "";
    function timeout() { const d = TDs[idx]; disconnectedUsers.add(user.id); notifyMemberListChange(); toast(`@${tag} timed out for ${d.label} (local)`); const timer = setTimeout(() => { timeoutTimers.delete(timer); disconnectedUsers.delete(user.id); notifyMemberListChange(); }, d.seconds * 1000); timeoutTimers.add(timer); rootProps.onClose(); }
    return <Modal {...rootProps} size="sm" title={`Timeout ${user.globalName ?? user.username}`} actions={[{ text: "Cancel", variant: "secondary", onClick: rootProps.onClose }, { text: "Timeout", variant: "primary", onClick: timeout }]}><div style={{ display: "flex", marginBottom: "8px", borderRadius: "4px", overflow: "hidden", border: "1px solid rgba(255,255,255,0.1)" }}>{TDs.map((d, i) => <button key={i} onClick={() => setIdx(i)} style={{ flex: 1, background: idx === i ? "#5865f2" : "#2b2d31", color: "#fff", border: "none", borderRight: i < TDs.length - 1 ? "1px solid rgba(255,255,255,0.1)" : "none", padding: "8px 2px", cursor: "pointer" }}>{d.label}</button>)}</div></Modal>;
}

function findGroupIdx(children: any[], ids: string[]): number { for (let i = 0; i < children.length; i++) { const sub = Array.isArray(children[i]?.props?.children) ? children[i].props.children : children[i]?.props?.children ? [children[i].props.children] : []; if (sub.some((c: any) => c?.props?.id && ids.includes(c.props.id))) return i; } return -1; }

const messageContextPatch: NavContextMenuPatchCallback = (children, { message }: any) => {
    if (!children || !Array.isArray(children) || !isEnabled() || !message?.id || !getCurrentGuildId()) return;
    try { children.splice(-1, 0, (<Menu.MenuGroup key="fp-msg-group"><Menu.MenuItem key="fp-delete-msg" id="fp-delete-msg" label="Delete for me (fake)" color="danger" action={() => { deletedMessages.add(message.id); hideMessageInDOM(message.id); toast("Message deleted (local only)"); }} /></Menu.MenuGroup>)); } catch {}
};

const userContextPatch: NavContextMenuPatchCallback = (children, { user }: any) => {
    if (!children || !Array.isArray(children) || !isEnabled() || !user) return;
    try {
        const guildId = getCurrentGuildId(); if (!guildId) return;
        const allRoles = getGuildRoles(guildId); const memberRoleIds = getMemberRoleIds(guildId, user.id); const { username } = user;
        const groupA = (<Menu.MenuGroup key="fp-group-a">
            <Menu.MenuItem key="fp-rename" id="fp-rename" label="Change Nickname" action={() => openModal(p => <RenameModal rootProps={p} user={user} guildId={guildId} />)} />
            <Menu.MenuItem key="fp-roles" id="fp-roles" label="Roles">
                {allRoles.length === 0 ? <Menu.MenuItem key="fp-roles-empty" id="fp-roles-empty" label="No roles" disabled /> :
                    allRoles.map(role => { const hasRole = memberRoleIds.includes(role.id); const color = role.color ? `#${role.color.toString(16).padStart(6, "0")}` : "#80848e"; return <Menu.MenuItem key={`fp-role-${role.id}`} id={`fp-role-${role.id}`} label={role.name} action={() => {}} render={() => <div style={{ display: "flex", alignItems: "center", padding: "8px 10px", gap: 8, width: "100%", boxSizing: "border-box", cursor: "pointer" }}><div style={{ width: 14, height: 14, borderRadius: "50%", background: color, flexShrink: 0 }} /><span style={{ flex: 1, color: "#fff", fontSize: 14 }}>{role.name}</span><div style={{ width: 16, height: 16, borderRadius: 3, flexShrink: 0, border: hasRole ? "none" : "1.5px solid #72767d", background: hasRole ? "#5865f2" : "transparent", display: "flex", alignItems: "center", justifyContent: "center" }}>{hasRole && <svg width="10" height="8" viewBox="0 0 10 8" fill="none"><path d="M1 4L3.5 6.5L9 1" stroke="white" strokeWidth="1.5" strokeLinecap="round" strokeLinejoin="round" /></svg>}</div></div>} />; })}
            </Menu.MenuItem>
            <Menu.MenuCheckboxItem key="fp-mute" id="fp-mute" label="Server Mute" color="danger" checked={mutedUsers.get(user.id) === true} action={() => { mutedUsers.set(user.id, !mutedUsers.get(user.id)); }} />
            <Menu.MenuCheckboxItem key="fp-deafen" id="fp-deafen" label="Server Deafen" color="danger" checked={deafenedUsers.get(user.id) === true} action={() => { deafenedUsers.set(user.id, !deafenedUsers.get(user.id)); }} />
            <Menu.MenuItem key="fp-disconnect" id="fp-disconnect" label="Disconnect" color="danger" action={() => { disconnectedUsers.add(user.id); notifyMemberListChange(); toast(`@${username} disconnected (local)`); }} />
            <Menu.MenuItem key="fp-timeout" id="fp-timeout" label={`Timeout ${username}`} color="danger" action={() => openModal(p => <TimeoutModal rootProps={p} user={user} />)} />
            <Menu.MenuItem key="fp-kick" id="fp-kick" label={`Kick ${username}`} color="danger" action={() => openModal(p => <KickModal rootProps={p} user={user} guildId={guildId} />)} />
            <Menu.MenuItem key="fp-ban" id="fp-ban" label={`Ban ${username}`} color="danger" action={() => openModal(p => <BanModal rootProps={p} user={user} />)} />
        </Menu.MenuGroup>);
        const idx = findGroupIdx(children, ["block", "ignore"]);
        if (idx >= 0) children.splice(idx + 1, 0, groupA); else children.splice(-1, 0, groupA);
    } catch (e) { console.error("[FakePerm]", e); }
};

export default definePlugin({
    name: "FakePerm", enabledByDefault: false, settings,
    description: "Visually simulates moderation options in right-click menus. No real actions. Enable in plugin settings.",
    authors: [{ name: "Nightcord", id: 0n }], dependencies: ["ContextMenuAPI"],
    patches: [
        { find: "showCommunicationDisabledStyles", predicate: () => isEnabled(), replacement: { match: /&&\i\.\i\.canManageUser\(\i\.\i\.MODERATE_MEMBERS,\i\.author,\i\)/, replace: "" } },
        { find: "INVITES_DISABLED)||", predicate: () => isEnabled(), replacement: { match: /\i\.\i\.can\(\i\.\i.MANAGE_GUILD,\i\)/, replace: "true" } },
        { find: /,checkElevated:!1}\),\i\.\i\)}(?<=getCurrentUser\(\);return.+?)/, predicate: () => isEnabled(), replacement: { match: /return \i\.\i\(\i\.\i\(\{user:\i,context:\i,checkElevated:!1\}\),\i\.\i\)/, replace: "return true" } },
        { find: 'action:"PRESS_MOD_VIEW",icon:', predicate: () => isEnabled(), replacement: { match: /\i(?=\?null)/, replace: "false" } }
    ],
    start() { addContextMenuPatch("message", messageContextPatch); addContextMenuPatch("user-context", userContextPatch); addContextMenuPatch("guild-channel-user-context", userContextPatch); },
    stop() {
        removeContextMenuPatch("message", messageContextPatch); removeContextMenuPatch("user-context", userContextPatch); removeContextMenuPatch("guild-channel-user-context", userContextPatch);
        document.querySelectorAll("[data-fp-hidden='true']").forEach(el => { (el as HTMLElement).style.display = ""; (el as HTMLElement).removeAttribute("data-fp-hidden"); });
        clearFakePermState();
    }
});

'@
    if (Write-Utf8FileAtomic -Path (Join-Path $dir "index.tsx") -Content $content1) { $changed = $true }
    return $changed
}

function Write-PluginFakeDM {
    param([Parameter(Mandatory = $true)][string]$PluginsDir)
    $dir = Get-SafeChildPath -Root $PluginsDir -Child "fakeDM"
    $changed = $false
    $content1 = @'
/*
 * Vencord, a Discord client mod
 * Copyright (c) 2026 Vendicated and contributors
 * SPDX-License-Identifier: GPL-3.0-or-later
 */

import "./styles.css";

import { ChatBarButton, ChatBarButtonFactory } from "@api/ChatButtons";
import * as DataStore from "@api/DataStore";
import { Logger } from "@utils/Logger";
import definePlugin from "@utils/types";
import { ChannelStore, FluxDispatcher, IconUtils, React, ReactDOM, SelectedChannelStore, UserStore } from "@webpack/common";

let _idCounter = 0;
function uniqueSnowflake(date: Date): string { const offset = _idCounter++ % 4096; const ms = Math.max(0, date.getTime() - 1420070400000); return ((BigInt(ms) << 22n) | BigInt(offset)).toString(); }
function randomSeconds(date: Date): Date { return new Date(date.getTime() + (1 + Math.floor(Math.random() * 59)) * 1000); }

const STORAGE_KEY = "nightcord_fakedm_fakes";
const MAX_PERSISTED = 250;
const logger = new Logger("FakeDM");
type PersistedFake = { type: "message"; channelId: string; authorId: string; content: string; timestamp: string; snowflakeId: string; } | { type: "call"; channelId: string; callerId: string; otherId: string; missed: boolean; durationSec: number; timestamp: string; endedTimestamp: string | null; snowflakeId: string; };
let persistedFakes: PersistedFake[] = [];
let persistenceLoaded = false;
let persistencePromise: Promise<void> | null = null;
async function loadPersisted() {
    if (persistenceLoaded) return;
    if (persistencePromise) return persistencePromise;
    persistencePromise = (async () => {
        try {
            let stored = await DataStore.get<PersistedFake[]>(STORAGE_KEY);
            if (!Array.isArray(stored)) {
                const legacyRaw = localStorage.getItem(STORAGE_KEY);
                const legacy = legacyRaw ? JSON.parse(legacyRaw) : [];
                stored = Array.isArray(legacy) ? legacy : [];
                await DataStore.set(STORAGE_KEY, stored.slice(-MAX_PERSISTED));
                localStorage.removeItem(STORAGE_KEY);
            }
            persistedFakes = stored.slice(-MAX_PERSISTED);
        } catch (error) {
            logger.error("Failed to load persisted local entries", error);
            persistedFakes = [];
        } finally {
            persistenceLoaded = true;
            persistencePromise = null;
        }
    })();
    return persistencePromise;
}
function savePersisted(fakes: PersistedFake[]) {
    persistedFakes = fakes.slice(-MAX_PERSISTED);
    void DataStore.set(STORAGE_KEY, persistedFakes).catch(error => logger.error("Failed to save local entries", error));
}

const fakeIds = new Map<string, Set<string>>();
function registerFake(channelId: string, id: string) { if (!fakeIds.has(channelId)) fakeIds.set(channelId, new Set()); fakeIds.get(channelId)!.add(id); }
function clearFakes(channelId: string): number { const ids = fakeIds.get(channelId); if (!ids?.size) return 0; let n = 0; for (const id of ids) { FluxDispatcher.dispatch({ type: "MESSAGE_DELETE", channelId, id, mlDeleted: true }); n++; } savePersisted(persistedFakes.filter(f => !(f.channelId === channelId && ids.has(f.snowflakeId)))); ids.clear(); return n; }

function avatarUrl(user: any): string { if (!user) return ""; return user.avatar ? IconUtils.getUserAvatarURL(user, false, 32) : IconUtils.getDefaultAvatarURL(user.id); }
function getCurrentDMChannel(): any | null { try { const chId = SelectedChannelStore.getChannelId(); if (!chId) return null; const ch = ChannelStore.getChannel(chId); if (!ch || (ch.type !== 1 && ch.type !== 3)) return null; return ch; } catch { return null; } }
function getOtherUser(): any | null { try { const ch = getCurrentDMChannel(); if (!ch || ch.type !== 1) return null; const me = UserStore.getCurrentUser(); const otherId = ch.recipients?.find((id: string) => id !== me?.id); return otherId ? (UserStore.getUser(otherId) ?? null) : null; } catch { return null; } }
function getChannelMembers(): any[] { try { const ch = getCurrentDMChannel(); if (!ch) return []; const me = UserStore.getCurrentUser(); const ids: string[] = ch.recipients ?? ch.rawRecipients?.map((r: any) => r.id) ?? []; const members: any[] = []; if (me) members.push(me); for (const id of ids) { if (id === me?.id) continue; const u = UserStore.getUser(id); if (u) members.push(u); } return members; } catch { return []; } }
function buildAuthor(user: any) { return { id: user.id, username: user.username, discriminator: user.discriminator ?? "0", avatar: user.avatar ?? null, public_flags: user.publicFlags ?? 0, flags: user.flags ?? 0, banner: user.banner ?? null, accent_color: null, global_name: user.globalName ?? user.username, avatar_decoration_data: null, banner_color: null }; }

function inject(channelId: string, author: any, content: string, date: Date, persistedId?: string) {
    const actualDate = persistedId ? date : randomSeconds(date); const id = persistedId ?? uniqueSnowflake(actualDate);
    FluxDispatcher.dispatch({ type: "MESSAGE_CREATE", channelId, message: { attachments: [], components: [], embeds: [], mention_roles: [], mentions: [], author: buildAuthor(author), channel_id: channelId, content, edited_timestamp: null, flags: 0, id, mention_everyone: false, nonce: id, pinned: false, timestamp: actualDate.toISOString(), tts: false, type: 0 }, optimistic: false, isPushNotification: false });
    registerFake(channelId, id);
    if (!persistedId) savePersisted([...persistedFakes, { type: "message", channelId, authorId: author.id, content, timestamp: actualDate.toISOString(), snowflakeId: id }]);
}

function injectCall(channelId: string, caller: any, other: any, missed: boolean, durationSec: number, date: Date, persistedId?: string, persistedEndedTs?: string | null) {
    const actualDate = persistedId ? date : randomSeconds(date); const id = persistedId ?? uniqueSnowflake(actualDate);
    const endedDate = missed ? actualDate : (persistedEndedTs ? new Date(persistedEndedTs) : new Date(actualDate.getTime() + durationSec * 1000));
    FluxDispatcher.dispatch({ type: "MESSAGE_CREATE", channelId, message: { attachments: [], components: [], embeds: [], mention_roles: [], mentions: [], author: buildAuthor(caller), channel_id: channelId, content: "", edited_timestamp: null, flags: 0, id, mention_everyone: false, nonce: id, pinned: false, timestamp: actualDate.toISOString(), tts: false, type: 3, call: { participants: missed ? [caller.id] : [caller.id, other.id], ended_timestamp: endedDate.toISOString(), duration: missed ? undefined : durationSec } }, optimistic: false, isPushNotification: false });
    registerFake(channelId, id);
    if (!persistedId) savePersisted([...persistedFakes, { type: "call", channelId, callerId: caller.id, otherId: other.id, missed, durationSec, timestamp: actualDate.toISOString(), endedTimestamp: endedDate.toISOString(), snowflakeId: id }]);
}

let _restoreHandler: (() => void) | null = null;
let _restoreTimer: ReturnType<typeof setTimeout> | null = null;
function scheduleRestore() {
    if (_restoreTimer) clearTimeout(_restoreTimer);
    _restoreTimer = setTimeout(() => { _restoreTimer = null; for (const f of persistedFakes) { if (f.type === "message") { const author = UserStore.getUser(f.authorId); if (author) inject(f.channelId, author, f.content, new Date(f.timestamp), f.snowflakeId); } else { const caller = UserStore.getUser(f.callerId); const other = UserStore.getUser(f.otherId); if (caller && other) injectCall(f.channelId, caller, other, f.missed, f.durationSec, new Date(f.timestamp), f.snowflakeId, f.endedTimestamp); } } }, 1200);
}

function toLocal(d: Date): string { const p = (n: number) => String(n).padStart(2, "0"); return `${d.getFullYear()}-${p(d.getMonth()+1)}-${p(d.getDate())}T${p(d.getHours())}:${p(d.getMinutes())}`; }

function UserAvatar({ user }: { user: any; }) { const [err, setErr] = React.useState(false); if (!user) return null; const url = avatarUrl(user); if (err || !url) return <div className="fdm-sender-avatar fdm-sender-avatar-placeholder">{user.username?.[0]?.toUpperCase() ?? "?"}</div>; return <img src={url} className="fdm-sender-avatar" alt="" onError={() => setErr(true)} />; }
function MemberSelect({ members, value, onChange, label }: { members: any[]; value: string; onChange(id: string): void; label?: string; }) { return <div style={{ display: "flex", alignItems: "center", gap: 6, padding: "4px 12px" }}>{label && <span className="fdm-date-label">{label}</span>}<select value={value} onChange={e => onChange(e.target.value)} style={{ flex: 1, background: "rgba(255,255,255,0.07)", border: "1px solid rgba(255,255,255,0.12)", borderRadius: 6, color: "#fff", fontSize: 13, padding: "4px 6px", cursor: "pointer" }}>{members.map(m => <option key={m.id} value={m.id} style={{ background: "#2b2d31" }}>{m.globalName || m.username}</option>)}</select></div>; }

let _portalRoot: HTMLDivElement | null = null;
function getPortalRoot(): HTMLDivElement { if (!_portalRoot || !document.body.contains(_portalRoot)) { _portalRoot = document.createElement("div"); _portalRoot.id = "fdm-portal-root"; document.body.appendChild(_portalRoot); } return _portalRoot; }

// Panel opens near the bottom center of the screen (above the chat bar)
function FakeDMPanel({ onClose }: { onClose(): void; }) {
    const me = UserStore.getCurrentUser(); const ch = getCurrentDMChannel(); const channelId = SelectedChannelStore.getChannelId();
    const isGroup = ch?.type === 3; const other = getOtherUser(); const members = getChannelMembers(); const isInDMOrGroup = !!ch;
    const [mode, setMode] = React.useState<"message" | "call">("message");
    const [senderId, setSenderId] = React.useState<string>(() => me?.id ?? "");
    const [callerId, setCallerId] = React.useState<string>(() => me?.id ?? "");
    const [callReceiverId, setCallReceiverId] = React.useState<string>(() => members.find(m => m.id !== me?.id)?.id ?? me?.id ?? "");
    const [callMissed, setCallMissed] = React.useState(false); const [callDuration, setCallDuration] = React.useState("5");
    const [text, setText] = React.useState(""); const [dateStr, setDateStr] = React.useState(() => toLocal(new Date()));
    const [status, setStatus] = React.useState<{ msg: string; ok: boolean; } | null>(null);
    const textareaRef = React.useRef<HTMLTextAreaElement>(null);
    const timers = React.useRef(new Set<ReturnType<typeof setTimeout>>());
    function schedulePanelTask(task: () => void, delay: number) { const timer = setTimeout(() => { timers.current.delete(timer); task(); }, delay); timers.current.add(timer); }
    React.useEffect(() => { schedulePanelTask(() => textareaRef.current?.focus(), 80); return () => { timers.current.forEach(timer => clearTimeout(timer)); timers.current.clear(); }; }, []);
    React.useEffect(() => { const h = (e: KeyboardEvent) => { if (e.key === "Escape") onClose(); }; document.addEventListener("keydown", h, true); return () => document.removeEventListener("keydown", h, true); }, [onClose]);
    function setMsg(msg: string, ok: boolean) { setStatus({ msg, ok }); schedulePanelTask(() => setStatus(null), 2500); }
    function send() { if (!text.trim() || !channelId) return; const author = members.find(m => m.id === senderId) ?? me; if (!author) return; const date = new Date(dateStr); if (isNaN(date.getTime())) { setMsg("Invalid Date!", false); return; } inject(channelId, author, text.trim(), date); setText(""); setMsg("Message injected", true); setDateStr(toLocal(new Date(date.getTime() + 60_000))); schedulePanelTask(() => textareaRef.current?.focus(), 10); }
    function sendCall() { if (!channelId) return; const callerUser = members.find(m => m.id === callerId); const receiverUser = members.find(m => m.id === callReceiverId); if (!callerUser || !receiverUser) return; const date = new Date(dateStr); if (isNaN(date.getTime())) { setMsg("Invalid Date!", false); return; } injectCall(channelId, callerUser, receiverUser, callMissed, callMissed ? 0 : Math.max(1, Math.round((parseFloat(callDuration) || 0) * 60)), date); setMsg(callMissed ? "Missed call injected" : "Call injected", true); setDateStr(toLocal(new Date(date.getTime() + 60_000))); }
    const meName = (me as any)?.globalName || me?.username || "Me"; const otherName = other?.globalName || other?.username || "Other";
    const SenderRow = isGroup ? <MemberSelect members={members} value={senderId} onChange={setSenderId} label="From:" /> : <div className="fdm-sender-row"><button className={`fdm-sender-btn${senderId === me?.id ? " fdm-sender-btn-active" : ""}`} onClick={() => setSenderId(me?.id ?? "")}><UserAvatar user={me} /><span className="fdm-sender-name">{meName}</span></button><button className={`fdm-sender-btn${senderId !== me?.id ? " fdm-sender-btn-active" : ""}`} onClick={() => setSenderId(other?.id ?? "")}><UserAvatar user={other} /><span className="fdm-sender-name">{otherName}</span></button></div>;
    const CallerRow = isGroup ? <><MemberSelect members={members} value={callerId} onChange={setCallerId} label="Caller:" /><MemberSelect members={members} value={callReceiverId} onChange={setCallReceiverId} label="Receiver:" /></> : <div className="fdm-sender-row"><button className={`fdm-sender-btn${callerId === me?.id ? " fdm-sender-btn-active" : ""}`} onClick={() => { setCallerId(me?.id ?? ""); setCallReceiverId(other?.id ?? ""); }}><UserAvatar user={me} /><span className="fdm-sender-name">{meName}</span></button><button className={`fdm-sender-btn${callerId !== me?.id ? " fdm-sender-btn-active" : ""}`} onClick={() => { setCallerId(other?.id ?? ""); setCallReceiverId(me?.id ?? ""); }}><UserAvatar user={other} /><span className="fdm-sender-name">{otherName}</span></button></div>;
    // Position: fixed, centered above chat bar
    const panelStyle: React.CSSProperties = { position: "fixed", left: "50%", transform: "translateX(-50%)", bottom: "80px", width: "430px", backgroundColor: "#2b2d31", border: "1px solid rgba(255,255,255,0.1)", borderRadius: "12px", boxShadow: "0 16px 48px rgba(0,0,0,0.65)", overflow: "hidden", zIndex: 1000000, display: "flex", flexDirection: "column" };
    return (<>
        <div onClick={onClose} style={{ position: "fixed", inset: 0, zIndex: 999999, backgroundColor: "rgba(0,0,0,0.4)" }} />
        <div className="fdm-panel" style={panelStyle} onClick={e => e.stopPropagation()} onMouseDown={e => e.stopPropagation()}>
            <div className="fdm-header"><span className="fdm-title">{mode === "message" ? "Fake DM" : "Fake Call"}{isGroup ? " (Group)" : ""}</span><button className="fdm-close" onClick={onClose}>x</button></div>
            <div style={{ display: "flex", gap: 6, padding: "0 12px 10px" }}>
                <button onClick={() => setMode("message")} style={{ flex: 1, padding: "5px 0", borderRadius: 6, border: "none", cursor: "pointer", fontSize: 12, fontWeight: 600, background: mode === "message" ? "#5865f2" : "rgba(255,255,255,0.07)", color: mode === "message" ? "#fff" : "rgba(255,255,255,0.5)" }}>Message</button>
                <button onClick={() => setMode("call")} style={{ flex: 1, padding: "5px 0", borderRadius: 6, border: "none", cursor: "pointer", fontSize: 12, fontWeight: 600, background: mode === "call" ? "#5865f2" : "rgba(255,255,255,0.07)", color: mode === "call" ? "#fff" : "rgba(255,255,255,0.5)" }}>Call</button>
            </div>
            {!isInDMOrGroup ? <div style={{ padding: "16px 14px", color: "rgba(255,255,255,0.45)", fontSize: 13, textAlign: "center" }}>Open a DM or group DM first.</div> :
            mode === "message" ? <>
                {SenderRow}
                <div className="fdm-date-row"><span className="fdm-date-label">Date:</span><input type="datetime-local" className="fdm-date-input" value={dateStr} onChange={e => setDateStr(e.target.value)} /><button className="fdm-date-now" onClick={() => setDateStr(toLocal(new Date()))}>Now</button></div>
                <div className="fdm-input-row"><textarea ref={textareaRef} className="fdm-textarea" rows={2} placeholder="Message (Enter to send)" value={text} onChange={e => setText(e.target.value)} onKeyDown={e => { if (e.key === "Enter" && !e.shiftKey) { e.preventDefault(); send(); } }} /><div className="fdm-actions"><button className="fdm-send-btn" disabled={!text.trim()} onClick={send}>Send</button><button className="fdm-clear-btn" onClick={() => { if (!channelId) return; const n = clearFakes(channelId); setMsg(`${n} cleared`, true); }}>Clear</button></div></div>
            </> : <>
                {CallerRow}
                <div style={{ display: "flex", alignItems: "center", gap: 6, padding: "6px 12px" }}>
                    <button onClick={() => setCallMissed(false)} style={{ flex: 1, padding: "4px 0", borderRadius: 6, border: "none", cursor: "pointer", fontSize: 12, fontWeight: 600, background: !callMissed ? "#3ba55c" : "rgba(255,255,255,0.07)", color: !callMissed ? "#fff" : "rgba(255,255,255,0.45)" }}>Answered</button>
                    <button onClick={() => setCallMissed(true)} style={{ flex: 1, padding: "4px 0", borderRadius: 6, border: "none", cursor: "pointer", fontSize: 12, fontWeight: 600, background: callMissed ? "#ed4245" : "rgba(255,255,255,0.07)", color: callMissed ? "#fff" : "rgba(255,255,255,0.45)" }}>Missed</button>
                    {!callMissed && <div style={{ display: "flex", alignItems: "center", gap: 4 }}><input type="number" min="1" max="999" value={callDuration} onChange={e => setCallDuration(e.target.value)} style={{ width: 48, background: "rgba(255,255,255,0.07)", border: "1px solid rgba(255,255,255,0.12)", borderRadius: 6, color: "#fff", fontSize: 12, padding: "3px 6px", textAlign: "center" }} /><span style={{ fontSize: 11, color: "rgba(255,255,255,0.4)" }}>min</span></div>}
                </div>
                <div className="fdm-date-row"><span className="fdm-date-label">Date:</span><input type="datetime-local" className="fdm-date-input" value={dateStr} onChange={e => setDateStr(e.target.value)} /><button className="fdm-date-now" onClick={() => setDateStr(toLocal(new Date()))}>Now</button></div>
                <div className="fdm-input-row"><div className="fdm-actions"><button className="fdm-send-btn" onClick={sendCall}>Inject Call</button><button className="fdm-clear-btn" onClick={() => { if (!channelId) return; const n = clearFakes(channelId); setMsg(`${n} cleared`, true); }}>Clear</button></div></div>
            </>}
            {status && <div className={`fdm-status fdm-status-${status.ok ? "ok" : "error"}`}>{status.msg}</div>}
        </div>
    </>);
}

// FIXED: chatBarButton.render is the component slot; ChatBarButton wraps the icon inside it.
// The panel is rendered via a portal, toggled by clicking the bar button.
// No ref forwarding needed; panel is always centered above chat bar.
const FakeDMButtonIcon = () => <svg aria-hidden="true" role="img" xmlns="http://www.w3.org/2000/svg" width="20" height="20" fill="none" viewBox="0 0 24 24"><path fill="currentColor" d="M12 2C6.486 2 2 6.037 2 11c0 2.579 1.178 4.898 3.073 6.576L4 22l4.648-2.343C9.72 20.213 10.848 20.4 12 20.4c5.514 0 10-4.037 10-9s-4.486-9-10-9Zm1 13H7v-2h6v2Zm2-4H7v-2h8v2Z" /></svg>;

const FakeDMChatButton: ChatBarButtonFactory = ({ isMainChat }) => {
    const [open, setOpen] = React.useState(false);
    if (!isMainChat) return null;
    return <>
        <ChatBarButton tooltip="FakeDM" onClick={() => setOpen(v => !v)}>
            <FakeDMButtonIcon />
        </ChatBarButton>
        {open && ReactDOM.createPortal(<FakeDMPanel onClose={() => setOpen(false)} />, getPortalRoot())}
    </>;
};

export default definePlugin({
    name: "FakeDM", description: "Inject fake messages and calls into DMs. Only visible to you. Click the chat bar button.", authors: [{ name: "sqlu", id: 0n }], enabledByDefault: true, dependencies: ["ChatInputButtonAPI"],
    chatBarButton: { icon: FakeDMButtonIcon, render: FakeDMChatButton },
    async start() { await loadPersisted(); _restoreHandler = () => { fakeIds.clear(); scheduleRestore(); }; FluxDispatcher.subscribe("CONNECTION_OPEN", _restoreHandler); scheduleRestore(); },
    stop() { if (_restoreHandler) { FluxDispatcher.unsubscribe("CONNECTION_OPEN", _restoreHandler); _restoreHandler = null; } if (_restoreTimer) { clearTimeout(_restoreTimer); _restoreTimer = null; } _portalRoot?.remove(); _portalRoot = null; fakeIds.clear(); }
});

'@
    if (Write-Utf8FileAtomic -Path (Join-Path $dir "index.tsx") -Content $content1) { $changed = $true }
    $content2 = @'
.fdm-panel {
    font-family: var(--font-primary);
}

.fdm-header {
    display: flex;
    align-items: center;
    justify-content: space-between;
    padding: 12px 14px 10px;
    border-bottom: 1px solid rgb(255 255 255 / 8%);
}

.fdm-title {
    color: #fff;
    font-size: 15px;
    font-weight: 700;
}

.fdm-close {
    padding: 2px 6px;
    border: none;
    border-radius: 4px;
    background: none;
    color: rgb(255 255 255 / 50%);
    font-size: 16px;
    cursor: pointer;
}

.fdm-close:hover {
    background: rgb(255 255 255 / 10%);
    color: #fff;
}

.fdm-sender-row {
    display: flex;
    gap: 6px;
    padding: 0 12px 8px;
}

.fdm-sender-btn {
    display: flex;
    flex: 1;
    gap: 6px;
    align-items: center;
    padding: 5px 8px;
    border: 1.5px solid transparent;
    border-radius: 8px;
    background: rgb(255 255 255 / 5%);
    color: rgb(255 255 255 / 50%);
    font-size: 13px;
    font-weight: 500;
    cursor: pointer;
}

.fdm-sender-btn-active {
    border-color: #5865f2;
    background: rgb(88 101 242 / 15%);
    color: #fff;
}

.fdm-sender-avatar {
    width: 24px;
    height: 24px;
    border-radius: 50%;
    object-fit: cover;
    flex-shrink: 0;
}

.fdm-sender-avatar-placeholder {
    display: flex;
    align-items: center;
    justify-content: center;
    background: #5865f2;
    color: #fff;
    font-size: 11px;
    font-weight: 700;
}

.fdm-sender-name {
    overflow: hidden;
    text-overflow: ellipsis;
    white-space: nowrap;
}

.fdm-date-row {
    display: flex;
    gap: 6px;
    align-items: center;
    padding: 0 12px 8px;
}

.fdm-date-label {
    color: rgb(255 255 255 / 40%);
    font-size: 12px;
    white-space: nowrap;
    flex-shrink: 0;
}

.fdm-date-input {
    flex: 1;
    padding: 4px 8px;
    border: 1px solid rgb(255 255 255 / 12%);
    border-radius: 6px;
    outline: none;
    background: rgb(255 255 255 / 7%);
    color: #fff;
    font-size: 12px;
}

.fdm-date-input:focus {
    border-color: #5865f2;
}

.fdm-date-now {
    padding: 4px 8px;
    border: none;
    border-radius: 6px;
    background: rgb(255 255 255 / 8%);
    color: rgb(255 255 255 / 60%);
    font-size: 11px;
    cursor: pointer;
    flex-shrink: 0;
}

.fdm-date-now:hover {
    background: rgb(255 255 255 / 15%);
    color: #fff;
}

.fdm-input-row {
    padding: 0 12px 12px;
}

.fdm-textarea {
    box-sizing: border-box;
    width: 100%;
    margin-bottom: 8px;
    padding: 8px 10px;
    border: 1px solid rgb(255 255 255 / 10%);
    border-radius: 8px;
    outline: none;
    background: rgb(255 255 255 / 6%);
    color: #fff;
    font-family: var(--font-primary);
    font-size: 14px;
    line-height: 1.4;
    resize: none;
}

.fdm-textarea:focus {
    border-color: #5865f2;
}

.fdm-actions {
    display: flex;
    justify-content: flex-end;
    gap: 6px;
}

.fdm-send-btn {
    padding: 6px 16px;
    border: none;
    border-radius: 6px;
    background: #5865f2;
    color: #fff;
    font-size: 13px;
    font-weight: 600;
    cursor: pointer;
}

.fdm-send-btn:disabled {
    background: rgb(88 101 242 / 40%);
    cursor: not-allowed;
}

.fdm-send-btn:not(:disabled):hover {
    background: #4752c4;
}

.fdm-clear-btn {
    padding: 6px 12px;
    border: 1px solid rgb(237 66 69 / 30%);
    border-radius: 6px;
    background: rgb(237 66 69 / 15%);
    color: #ed4245;
    font-size: 13px;
    font-weight: 500;
    cursor: pointer;
}

.fdm-clear-btn:hover {
    background: rgb(237 66 69 / 25%);
}

.fdm-status {
    padding: 0 12px 10px;
    font-size: 12px;
    text-align: center;
}

.fdm-status-ok {
    color: #3ba55d;
}

.fdm-status-error {
    color: #ed4245;
}

'@
    if (Write-Utf8FileAtomic -Path (Join-Path $dir "styles.css") -Content $content2) { $changed = $true }
    return $changed
}

function Write-PluginAntiMoveDeco {
    param([Parameter(Mandatory = $true)][string]$PluginsDir)
    $dir = Get-SafeChildPath -Root $PluginsDir -Child "antiMoveDeco"
    $changed = $false
    $content1 = @'
/*
 * Vencord, a Discord client mod
 * Copyright (c) 2026 Vendicated and contributors
 * SPDX-License-Identifier: GPL-3.0-or-later
 */

import { ChatBarButton, ChatBarButtonFactory } from "@api/ChatButtons";
import definePlugin from "@utils/types";
import { findByPropsLazy } from "@webpack";
import { FluxDispatcher, React, UserStore, useState,VoiceStateStore } from "@webpack/common";

const ChannelActions = findByPropsLazy("selectVoiceChannel", "disconnect");

// Module-level state (persists across renders)
let antiMoveEnabled = false;
let targetChannelId: string | null = null;
let returnTimer: ReturnType<typeof setTimeout> | null = null;

function returnToTargetChannel() {
    if (!targetChannelId) return;
    if (returnTimer) clearTimeout(returnTimer);
    returnTimer = setTimeout(() => {
        returnTimer = null;
        try { if (targetChannelId) ChannelActions?.selectVoiceChannel?.(targetChannelId); } catch {}
    }, 500);
}

function onVoiceStateUpdate({ voiceStates }: { voiceStates: any[]; }) {
    if (!antiMoveEnabled || !targetChannelId) return;
    const currentUser = UserStore.getCurrentUser();
    if (!currentUser) return;
    const myState = voiceStates.find(s => s.userId === currentUser.id);
    if (!myState) return;
    // If moved to a different channel or disconnected, snap back
    if (myState.channelId && myState.channelId !== targetChannelId) {
        returnToTargetChannel();
    } else if (!myState.channelId) {
        // Disconnected - rejoin
        returnToTargetChannel();
    }
}

// Listeners set so the button component can react to module-level state changes
const stateListeners = new Set<(enabled: boolean) => void>();
function notifyStateChange(enabled: boolean) { stateListeners.forEach(fn => fn(enabled)); }

const AntiMoveButton: ChatBarButtonFactory = ({ isMainChat }) => {
    const [enabled, setEnabled] = useState(antiMoveEnabled);

    React.useEffect(() => {
        const listener = (e: boolean) => setEnabled(e);
        stateListeners.add(listener);
        return () => { stateListeners.delete(listener); };
    }, []);

    if (!isMainChat) return null;

    function toggle() {
        antiMoveEnabled = !antiMoveEnabled;
        if (antiMoveEnabled) {
            // Lock to current voice channel
            try {
                const me = UserStore.getCurrentUser();
                if (me) {
                    const vs = VoiceStateStore?.getVoiceStateForUser?.(me.id);
                    targetChannelId = vs?.channelId ?? null;
                }
            } catch {}
        } else {
            targetChannelId = null;
        }
        notifyStateChange(antiMoveEnabled);
    }

    const color = enabled ? "#43b581" : "currentColor";
    const tooltip = enabled
        ? `AntiMove: ON${targetChannelId ? " (locked)" : " (join a VC first)"} - click to disable`
        : "AntiMove: OFF - click to enable (join a VC first)";

    return (
        <ChatBarButton tooltip={tooltip} onClick={toggle}>
            <svg width="20" height="20" viewBox="0 0 24 24" fill="none" xmlns="http://www.w3.org/2000/svg">
                <circle cx="12" cy="12" r="9" stroke={color} strokeWidth="2" />
                {enabled
                    ? <path fill={color} d="M9 12l2 2 4-4" stroke={color} strokeWidth="2" strokeLinecap="round" strokeLinejoin="round" />
                    : <path fill={color} d="M8 8l8 8M16 8l-8 8" stroke={color} strokeWidth="2" strokeLinecap="round" />
                }
            </svg>
        </ChatBarButton>
    );
};

export default definePlugin({
    name: "AntiMoveDeco",
    description: "Prevents being moved or disconnected from a voice channel. Toggle via chat bar button.",
    authors: [{ name: "Nightcord", id: 0n }],
    enabledByDefault: true,
    dependencies: ["ChatInputButtonAPI"],
    chatBarButton: { icon: () => <svg width="20" height="20" viewBox="0 0 24 24" fill="none" xmlns="http://www.w3.org/2000/svg"><circle cx="12" cy="12" r="9" stroke="currentColor" strokeWidth="2" /></svg>, render: AntiMoveButton },
    start() { FluxDispatcher.subscribe("VOICE_STATE_UPDATES", onVoiceStateUpdate); },
    stop() { FluxDispatcher.unsubscribe("VOICE_STATE_UPDATES", onVoiceStateUpdate); if (returnTimer) { clearTimeout(returnTimer); returnTimer = null; } antiMoveEnabled = false; targetChannelId = null; notifyStateChange(false); }
});

'@
    if (Write-Utf8FileAtomic -Path (Join-Path $dir "index.tsx") -Content $content1) { $changed = $true }
    return $changed
}

#endregion

#region PLUGIN REGISTRY AND CONFIG
function Get-BundledPlugins {
    return @(
        [pscustomobject]@{ Id = "smoothType"; DisplayName = "SmoothType"; FolderName = "smoothType"; Description = "Smooth animated caret for Discord's message input."; DefaultSelected = $true; Writer = "Write-PluginSmoothType"; LegacyFolders = @("SmoothType"); Notes = "Uses DOM selection listeners with cleanup." }
        [pscustomobject]@{ Id = "streamerModeOnStream"; DisplayName = "StreamerModeOnStream"; FolderName = "streamerModeOnStream"; Description = "Automatically enables streamer mode while you stream."; DefaultSelected = $true; Writer = "Write-PluginStreamerModeOnStream"; LegacyFolders = @("StreamerModeOnStream"); Notes = "Uses declarative Flux events." }
        [pscustomobject]@{ Id = "exportDM"; DisplayName = "ExportDM"; FolderName = "exportDM"; Description = "Exports messages as JSON, online HTML, an offline ZIP archive, or self-contained HTML."; DefaultSelected = $true; Writer = "Write-PluginExportDM"; LegacyFolders = @("ExportDM"); Notes = "Uses Discord REST pagination and bounded, cancellable media downloads." }
        [pscustomobject]@{ Id = "serverCloner"; DisplayName = "ServerCloner"; FolderName = "serverCloner"; Description = "Clones server settings, roles, channels, icon, and emojis to another server."; DefaultSelected = $true; Writer = "Write-PluginServerCloner"; LegacyFolders = @("ServerCloner"); Notes = "Uses Discord RestAPI and throttled clone steps." }
        [pscustomobject]@{ Id = "antiDeleteMessage"; DisplayName = "AntiDeleteMessage"; FolderName = "antiDeleteMessage"; Description = "Locally resends your messages when someone deletes them."; DefaultSelected = $true; Writer = "Write-PluginAntiDeleteMessage"; LegacyFolders = @("AntiDeleteMessage"); Notes = "Bounded cache setting and cleared delayed resend timers." }
        [pscustomobject]@{ Id = "lastSeen"; DisplayName = "LastSeen"; FolderName = "lastSeen"; Description = "Shows a user's last observed activity in the profile panel."; DefaultSelected = $true; Writer = "Write-PluginLastSeen"; LegacyFolders = @("LastSeen"); Notes = "Subscribes/unsubscribes Flux events explicitly." }
        [pscustomobject]@{ Id = "streamProof"; DisplayName = "StreamProof"; FolderName = "streamProof"; Description = "Blurs sensitive Discord content while streaming until clicked."; DefaultSelected = $true; Writer = "Write-PluginStreamProof"; LegacyFolders = @("StreamProof"); Notes = "Removes click listener, style tag, and reveal classes on stop." }
        [pscustomobject]@{ Id = "fakePerm"; DisplayName = "FakePerm"; FolderName = "fakePerm"; Description = "Adds local-only fake moderation menu actions for visual testing."; DefaultSelected = $true; Writer = "Write-PluginFakePerm"; LegacyFolders = @("FakePerm"); Notes = "Clears local state and fake timeout timers on disable/stop." }
        [pscustomobject]@{ Id = "fakeDM"; DisplayName = "FakeDM"; FolderName = "fakeDM"; Description = "Injects local-only fake DM messages and calls through a chat bar panel."; DefaultSelected = $true; Writer = "Write-PluginFakeDM"; LegacyFolders = @("FakeDM"); Notes = "Caps persisted entries and clears restore timers on stop." }
        [pscustomobject]@{ Id = "antiMoveDeco"; DisplayName = "AntiMoveDeco"; FolderName = "antiMoveDeco"; Description = "Keeps you in the selected voice channel when moved or disconnected."; DefaultSelected = $true; Writer = "Write-PluginAntiMoveDeco"; LegacyFolders = @("AntiMoveDeco"); Notes = "Uses VoiceStateStore and clears pending reconnect timers." }
    )
}

function Get-PluginById {
    param([string]$Id)
    return Get-BundledPlugins | Where-Object { $_.Id -eq $Id } | Select-Object -First 1
}

function Test-BundledPluginInstalled {
    param(
        [Parameter(Mandatory = $true)]$Plugin,
        [Parameter(Mandatory = $true)][string]$PluginsDir
    )
    $names = @($Plugin.FolderName) + @($Plugin.LegacyFolders)
    foreach ($name in $names) {
        $path = Get-SafeChildPath -Root $PluginsDir -Child $name
        if (Test-Path -LiteralPath $path -PathType Container) { return $true }
    }
    return $false
}

function Get-InstalledBundledPluginIds {
    param([string]$PluginsDir)
    $ids = @()
    foreach ($plugin in Get-BundledPlugins) {
        if (Test-BundledPluginInstalled -Plugin $plugin -PluginsDir $PluginsDir) { $ids += $plugin.Id }
    }
    return $ids
}

function Get-UnknownUserPluginFolders {
    param([string]$PluginsDir)
    if (-not (Test-Path -LiteralPath $PluginsDir)) { return @() }
    $known = New-Object System.Collections.Generic.HashSet[string] ([StringComparer]::OrdinalIgnoreCase)
    foreach ($plugin in Get-BundledPlugins) {
        [void]$known.Add($plugin.FolderName)
        foreach ($legacy in $plugin.LegacyFolders) { [void]$known.Add($legacy) }
    }
    [void]$known.Add("AudioLimiter")
    [void]$known.Add("audioLimiter")
    return @(Get-ChildItem -LiteralPath $PluginsDir -Directory -Force -ErrorAction SilentlyContinue | Where-Object { -not $known.Contains($_.Name) } | Select-Object -ExpandProperty Name)
}

function Load-SetupConfig {
    if (-not (Test-Path -LiteralPath $script:ConfigPath -PathType Leaf)) { return $null }
    try {
        $raw = Get-Content -LiteralPath $script:ConfigPath -Raw -ErrorAction Stop
        if ([string]::IsNullOrWhiteSpace($raw)) { return $null }
        return $raw | ConvertFrom-Json -ErrorAction Stop
    } catch {
        Write-Warn "Saved plugin preferences could not be read. Defaults will be used for this run."
        return $null
    }
}

function Save-SetupConfig {
    param([Parameter(Mandatory = $true)][AllowNull()][AllowEmptyCollection()][string[]]$SelectedIds)
    $tmp = $null
    try {
        if ($null -eq $SelectedIds) { $SelectedIds = @() }
        if (-not (Test-Path -LiteralPath $script:ConfigDir)) { New-Item -ItemType Directory -Path $script:ConfigDir -Force | Out-Null }
        $data = [ordered]@{
            version = $script:ConfigVersion
            selectedPluginIds = @($SelectedIds | Sort-Object)
            updatedAt = (Get-Date).ToString("o")
        }
        $json = $data | ConvertTo-Json -Depth 6
        $tmp = Join-Path $script:ConfigDir ("config." + [guid]::NewGuid().ToString("N") + ".tmp")
        $encoding = New-Object System.Text.UTF8Encoding -ArgumentList $false
        [IO.File]::WriteAllText($tmp, $json, $encoding)
        Move-Item -LiteralPath $tmp -Destination $script:ConfigPath -Force
        return $true
    } catch {
        Write-Warn "Plugin preferences could not be saved, but the selected plugins were still applied."
        return $false
    } finally {
        if ($tmp -and (Test-Path -LiteralPath $tmp)) {
            Remove-Item -LiteralPath $tmp -Force -ErrorAction SilentlyContinue
        }
    }
}

function Get-PreferredSelection {
    param([string]$PluginsDir)
    $plugins = @(Get-BundledPlugins)
    $known = @{}
    foreach ($plugin in $plugins) { $known[$plugin.Id] = $true }
    $selected = @{}
    foreach ($plugin in $plugins) { $selected[$plugin.Id] = $false }

    $config = Load-SetupConfig
    $selectionProperty = if ($config) { $config.PSObject.Properties["selectedPluginIds"] } else { $null }
    if ($selectionProperty) {
        foreach ($id in @($selectionProperty.Value)) {
            $sid = [string]$id
            if ($known.ContainsKey($sid)) { $selected[$sid] = $true }
        }
        return $selected
    }

    $installed = @(Get-InstalledBundledPluginIds -PluginsDir $PluginsDir)
    if ($installed.Count -gt 0) {
        foreach ($id in $installed) { $selected[$id] = $true }
        return $selected
    }

    foreach ($plugin in $plugins) {
        if ($plugin.DefaultSelected) { $selected[$plugin.Id] = $true }
    }
    return $selected
}

function Get-SelectedIds {
    param([hashtable]$Selection)
    return @(Get-BundledPlugins | Where-Object { $Selection[$_.Id] } | Select-Object -ExpandProperty Id)
}
#endregion

#region PLUGIN APPLY
function New-PluginSummary {
    return [pscustomobject]@{
        InstalledOrRefreshed = New-Object System.Collections.ArrayList
        Removed = New-Object System.Collections.ArrayList
        Unchanged = New-Object System.Collections.ArrayList
        Failed = New-Object System.Collections.ArrayList
        Cancelled = $false
        FilesChanged = $false
        BuildPerformed = $false
        InjectPerformed = $false
    }
}

function Get-RemovalPlan {
    param([hashtable]$Selection, [string]$PluginsDir)
    $items = New-Object System.Collections.ArrayList
    foreach ($plugin in Get-BundledPlugins) {
        if ($Selection[$plugin.Id]) { continue }
        if (Test-BundledPluginInstalled -Plugin $plugin -PluginsDir $PluginsDir) {
            [void]$items.Add($plugin.DisplayName)
        }
    }
    foreach ($obsolete in @("AudioLimiter", "audioLimiter")) {
        $path = Get-SafeChildPath -Root $PluginsDir -Child $obsolete
        if (Test-Path -LiteralPath $path -PathType Container) { [void]$items.Add("$obsolete (obsolete)") }
    }
    return @($items)
}

function Confirm-PluginRemovalPlan {
    param([string[]]$Names)
    if (-not $Names -or $Names.Count -eq 0) { return $true }
    Write-Warn "The following bundled plugin folders will be removed:"
    foreach ($name in $Names) { Write-Host "     - $name" -ForegroundColor Yellow }
    Write-Info "Unknown or third-party folders in src\userplugins will not be touched."
    return Get-Confirm "Remove these bundled plugin folders?"
}

function Remove-ManagedPluginFolders {
    param([Parameter(Mandatory = $true)]$Plugin, [Parameter(Mandatory = $true)][string]$PluginsDir)
    $removed = $false
    $names = @($Plugin.FolderName) + @($Plugin.LegacyFolders)
    foreach ($name in ($names | Select-Object -Unique)) {
        if (Remove-SafeDirectory -Root $PluginsDir -Child $name) { $removed = $true }
    }
    return $removed
}

function Normalize-PluginFolderCasing {
    param([Parameter(Mandatory = $true)]$Plugin, [Parameter(Mandatory = $true)][string]$PluginsDir)
    foreach ($legacy in @($Plugin.LegacyFolders)) {
        if ($legacy -cne $Plugin.FolderName -and $legacy -ieq $Plugin.FolderName) {
            $legacyPath = Get-SafeChildPath -Root $PluginsDir -Child $legacy
            if (-not (Test-Path -LiteralPath $legacyPath -PathType Container)) { continue }

            $item = Get-ChildItem -LiteralPath $PluginsDir -Directory -Force -ErrorAction Stop |
                Where-Object { $_.Name -ieq $legacy } |
                Select-Object -First 1
            if (-not $item) { continue }
            if ($item.Name -ceq $Plugin.FolderName) { continue }
            if (($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
                throw "Refusing to rename reparse-point plugin directory: $($item.FullName)"
            }

            $temporaryName = ".equicordSetup-rename-$([Guid]::NewGuid().ToString('N'))"
            $temporaryPath = Get-SafeChildPath -Root $PluginsDir -Child $temporaryName
            try {
                Rename-Item -LiteralPath $item.FullName -NewName $temporaryName -ErrorAction Stop
                Rename-Item -LiteralPath $temporaryPath -NewName $Plugin.FolderName -ErrorAction Stop
            } catch {
                if ((Test-Path -LiteralPath $temporaryPath -PathType Container) -and
                    -not (Test-Path -LiteralPath $legacyPath)) {
                    Rename-Item -LiteralPath $temporaryPath -NewName $legacy -ErrorAction SilentlyContinue
                }
                throw
            }
            return $true
        }
    }
    return $false
}

function Remove-LegacyPluginFolders {
    param([Parameter(Mandatory = $true)]$Plugin, [Parameter(Mandatory = $true)][string]$PluginsDir)
    $removed = $false
    foreach ($legacy in @($Plugin.LegacyFolders)) {
        if ($legacy -ieq $Plugin.FolderName) { continue }
        if (Remove-SafeDirectory -Root $PluginsDir -Child $legacy) { $removed = $true }
    }
    return $removed
}

function Apply-BundledPluginSelection {
    param(
        [Parameter(Mandatory = $true)][hashtable]$Selection,
        [switch]$SkipRemovalPrompt
    )
    $summary = New-PluginSummary
    $equicord = $script:EquicordDir
    $pluginsDir = Get-PluginsDir $equicord
    if (-not (Test-Path -LiteralPath $pluginsDir)) { New-Item -ItemType Directory -Path $pluginsDir -Force | Out-Null }

    $removalPlan = @(Get-RemovalPlan -Selection $Selection -PluginsDir $pluginsDir)
    if (-not $SkipRemovalPrompt) {
        if (-not (Confirm-PluginRemovalPlan -Names $removalPlan)) {
            $summary.Cancelled = $true
            return $summary
        }
    }

    foreach ($obsolete in @("AudioLimiter", "audioLimiter")) {
        try {
            if (Remove-SafeDirectory -Root $pluginsDir -Child $obsolete) {
                [void]$summary.Removed.Add("$obsolete (obsolete)")
                $summary.FilesChanged = $true
            }
        } catch {
            [void]$summary.Failed.Add("$obsolete`: $($_.Exception.Message)")
        }
    }

    foreach ($plugin in Get-BundledPlugins) {
        if ($Selection[$plugin.Id]) {
            try {
                $writer = Get-Command $plugin.Writer -ErrorAction Stop
                $casingChanged = Normalize-PluginFolderCasing -Plugin $plugin -PluginsDir $pluginsDir
                $changed = & $writer -PluginsDir $pluginsDir
                $legacyRemoved = Remove-LegacyPluginFolders -Plugin $plugin -PluginsDir $pluginsDir
                if ($changed -or $legacyRemoved -or $casingChanged) {
                    [void]$summary.InstalledOrRefreshed.Add($plugin.DisplayName)
                    $summary.FilesChanged = $true
                } else {
                    [void]$summary.Unchanged.Add($plugin.DisplayName)
                }
            } catch {
                [void]$summary.Failed.Add("$($plugin.DisplayName)`: $($_.Exception.Message)")
            }
        } else {
            try {
                if (Remove-ManagedPluginFolders -Plugin $plugin -PluginsDir $pluginsDir) {
                    [void]$summary.Removed.Add($plugin.DisplayName)
                    $summary.FilesChanged = $true
                } else {
                    [void]$summary.Unchanged.Add("$($plugin.DisplayName) (not installed)")
                }
            } catch {
                [void]$summary.Failed.Add("$($plugin.DisplayName)`: $($_.Exception.Message)")
            }
        }
    }

    Save-SetupConfig -SelectedIds @(Get-SelectedIds -Selection $Selection) | Out-Null
    return $summary
}

function Write-PluginApplySummary {
    param($Summary)
    Write-Section "Plugin Summary"
    Write-Host "  Installed/refreshed: " -ForegroundColor Cyan -NoNewline
    Write-Host ($(if ($Summary.InstalledOrRefreshed.Count) { ($Summary.InstalledOrRefreshed -join ", ") } else { "none" }))
    Write-Host "  Removed:             " -ForegroundColor Cyan -NoNewline
    Write-Host ($(if ($Summary.Removed.Count) { ($Summary.Removed -join ", ") } else { "none" }))
    Write-Host "  Unchanged:           " -ForegroundColor Cyan -NoNewline
    Write-Host ($(if ($Summary.Unchanged.Count) { ($Summary.Unchanged -join ", ") } else { "none" }))
    Write-Host "  Failed:              " -ForegroundColor Cyan -NoNewline
    Write-Host ($(if ($Summary.Failed.Count) { ($Summary.Failed -join "; ") } else { "none" }))
    Write-Host "  Build performed:     " -ForegroundColor Cyan -NoNewline
    Write-Host ($(if ($Summary.BuildPerformed) { "yes" } else { "no" }))
    Write-Host "  Reinjection done:    " -ForegroundColor Cyan -NoNewline
    Write-Host ($(if ($Summary.InjectPerformed) { "yes" } else { "no" }))
}

function Show-PluginManager {
    param([switch]$DuringSetup)
    $equicord = $script:EquicordDir
    if (-not (Test-EquicordRepo $equicord)) {
        Write-Err "Equicord folder not found. Run Full Equicord setup first."
        Pause-Return
        return $null
    }

    $pluginsDir = Get-PluginsDir $equicord
    $selection = Get-PreferredSelection -PluginsDir $pluginsDir
    $forceBuild = $false

    while ($true) {
        Clear-Host
        Write-Header "Custom Plugin Manager"
        Write-Info "Selected plugins are the desired state. Unselected bundled plugins will be removed after confirmation."
        Write-Info "Unknown folders in src\userplugins are preserved."
        Write-Host ""
        $plugins = @(Get-BundledPlugins)
        for ($i = 0; $i -lt $plugins.Count; $i++) {
            $plugin = $plugins[$i]
            $installed = Test-BundledPluginInstalled -Plugin $plugin -PluginsDir $pluginsDir
            $selText = if ($selection[$plugin.Id]) { "[x]" } else { "[ ]" }
            $state = if ($installed) { "installed" } else { "not installed" }
            $num = ($i + 1).ToString().PadLeft(2)
            Write-Host ("  {0}. {1} {2,-22} {3}" -f $num, $selText, $plugin.DisplayName, $state) -ForegroundColor White
            Write-Host ("      " + $plugin.Description) -ForegroundColor DarkGray
        }
        Write-Section "Actions"
        Write-MenuItem "1-10" "Toggle a plugin"
        Write-MenuItem "A" "Select all bundled plugins"
        Write-MenuItem "N" "Select none"
        Write-MenuItem "D" "Restore recommended defaults"
        Write-MenuItem "F" ("Force rebuild after apply: " + $(if ($forceBuild) { "on" } else { "off" }))
        Write-MenuItem "P" $(if ($DuringSetup) { "Apply and continue setup" } else { "Apply selected configuration" })
        Write-MenuItem "C" "Cancel without changing anything"
        Write-Host $LINE -ForegroundColor Cyan

        $choice = (Read-ChoiceText).ToLower()
        if ($choice -match "^\d+$") {
            $idx = [int]$choice
            if ($idx -ge 1 -and $idx -le $plugins.Count) {
                $id = $plugins[$idx - 1].Id
                $selection[$id] = -not [bool]$selection[$id]
            }
            continue
        }
        switch ($choice) {
            "a" { foreach ($p in $plugins) { $selection[$p.Id] = $true } }
            "n" { foreach ($p in $plugins) { $selection[$p.Id] = $false } }
            "d" { foreach ($p in $plugins) { $selection[$p.Id] = [bool]$p.DefaultSelected } }
            "f" { $forceBuild = -not $forceBuild }
            "c" { Write-Info "No plugin changes were made."; return $null }
            "p" {
                $summary = Apply-BundledPluginSelection -Selection $selection
                if ($summary.Cancelled) {
                    Write-Warn "Plugin changes were cancelled before any removal."
                    Pause-Return
                    return $null
                }
                $summary | Add-Member -NotePropertyName ForceBuild -NotePropertyValue $forceBuild -Force
                Write-PluginApplySummary -Summary $summary
                return $summary
            }
        }
    }
}
#endregion

#region REPOSITORY AND BUILD
function Get-DependencyFingerprint {
    param([string]$EquicordDir)
    $files = @("package.json", "pnpm-lock.yaml", "pnpm-workspace.yaml")
    $hashes = @()
    foreach ($file in $files) {
        $path = Join-Path $EquicordDir $file
        if (Test-Path -LiteralPath $path -PathType Leaf) {
            $hashes += (Get-FileHash -LiteralPath $path -Algorithm SHA256).Hash
        }
    }
    return ($hashes -join "|")
}

function Load-DependencyState {
    if (-not (Test-Path -LiteralPath $script:DependencyStatePath -PathType Leaf)) { return $null }
    try { return (Get-Content -LiteralPath $script:DependencyStatePath -Raw | ConvertFrom-Json) } catch { return $null }
}

function Save-DependencyState {
    param([string]$Fingerprint)
    try {
        if (-not (Test-Path -LiteralPath $script:ConfigDir)) { New-Item -ItemType Directory -Path $script:ConfigDir -Force | Out-Null }
        $data = [ordered]@{ fingerprint = $Fingerprint; updatedAt = (Get-Date).ToString("o") }
        $json = $data | ConvertTo-Json
        Write-Utf8FileAtomic -Path $script:DependencyStatePath -Content $json | Out-Null
    } catch {}
}

function Test-DependenciesCurrent {
    param([string]$EquicordDir, [string]$Fingerprint)
    $modules = Join-Path $EquicordDir "node_modules\.modules.yaml"
    if (-not (Test-Path -LiteralPath $modules -PathType Leaf)) { return $false }
    $state = Load-DependencyState
    if ($state -and $state.fingerprint -eq $Fingerprint) { return $true }

    $moduleTime = (Get-Item -LiteralPath $modules).LastWriteTimeUtc
    foreach ($file in @("package.json", "pnpm-lock.yaml", "pnpm-workspace.yaml")) {
        $path = Join-Path $EquicordDir $file
        if ((Test-Path -LiteralPath $path -PathType Leaf) -and ((Get-Item -LiteralPath $path).LastWriteTimeUtc -gt $moduleTime)) { return $false }
    }
    return $true
}

function Install-EquicordDependencies {
    param([switch]$Force)
    $equicord = $script:EquicordDir
    $fingerprint = Get-DependencyFingerprint -EquicordDir $equicord
    if (-not $Force -and (Test-DependenciesCurrent -EquicordDir $equicord -Fingerprint $fingerprint)) {
        Write-Success "Dependencies are already current."
        return
    }
    Write-Step "Installing dependencies with pnpm install --frozen-lockfile..."
    Invoke-InDirectory -Path $equicord -Script {
        Invoke-PnpmChecked -Arguments @("install", "--frozen-lockfile") -Description "Dependency install"
    }
    Save-DependencyState -Fingerprint $fingerprint
    Write-Success "Dependencies installed."
}

function Invoke-EquicordBuild {
    Write-Step "Building Equicord..."
    Invoke-InDirectory -Path $script:EquicordDir -Script {
        Invoke-PnpmChecked -Arguments @("build") -Description "Equicord build"
    }
    Write-Success "Build complete."
}

function Invoke-EquicordInject {
    param([switch]$Repair)
    if (-not (Stop-DiscordForInjection)) { return $false }
    if (Test-DiscordUpdateInProgress) {
        Write-Err "A Discord update is still running. Wait for it to finish, then retry."
        return $false
    }
    $install = Get-DiscordInstall
    if (-not $install) { Write-Err "No usable Discord installation was found."; return $false }
    if (-not (Fix-DiscordAsar -Install $install)) { return $false }
    $node = Resolve-Executable @("node.exe", "node")
    if (-not $node) { throw "Node.js is not available in this terminal session." }
    $runner = Join-Path $script:EquicordDir "scripts\runInstaller.mjs"
    if (-not (Test-Path -LiteralPath $runner -PathType Leaf)) { throw "Equicord's installer runner is missing: $runner" }
    $action = if ($Repair) { "--repair" } else { "--install" }
    Write-Step ($(if ($Repair) { "Repairing and reinjecting Equicord..." } else { "Injecting Equicord..." }))
    Invoke-InDirectory -Path $script:EquicordDir -Script {
        Invoke-NativeChecked -FilePath $node -Arguments @("scripts/runInstaller.mjs", "--", $action, "--location", $install.Root) -Description "Equicord installer"
    }
    if (-not (Test-EquicordInjectionMarker -Install $install)) {
        throw "The installer returned without creating a valid Equicord loader in $($install.Name)."
    }
    Write-Success "Injection complete."
    return $true
}

function Ensure-EquicordSource {
    param([switch]$UpdateExisting)
    $equicord = $script:EquicordDir
    $documents = Split-Path -Parent $equicord
    if (-not (Test-Path -LiteralPath $documents)) { New-Item -ItemType Directory -Path $documents -Force | Out-Null }

    if (Test-EquicordRepo $equicord) {
        if ($UpdateExisting) { return Update-EquicordSource }
        return $false
    }

    if (Test-Path -LiteralPath $equicord) {
        throw "Documents\Equicord exists but is not a usable Git clone. Rename that folder or repair it manually."
    }

    Write-Step "Cloning Equicord into Documents..."
    Invoke-GitChecked -Arguments @("clone", $script:RepoUrl, $equicord) -Description "Equicord clone"
    if (-not (Test-EquicordRepo $equicord)) {
        throw "Clone finished but the Equicord folder looks incomplete."
    }
    Write-Success "Equicord cloned."
    return $true
}

function Update-EquicordSource {
    $equicord = $script:EquicordDir
    if (-not (Test-EquicordRepo $equicord)) { throw "Equicord folder not found. Run Full Equicord setup first." }
    $changed = $false
    Invoke-InDirectory -Path $equicord -Script {
        $status = @(Invoke-Git status --porcelain)
        if ($status.Count -gt 0) {
            Write-Warn "Local changes were found in the Equicord worktree."
            Write-Info "The script will not reset, clean, or discard anything."
            if (-not (Get-Confirm "Try a fast-forward update anyway?")) { throw "Update cancelled because the worktree has local changes." }
        }
        $oldHead = (Invoke-Git rev-parse HEAD | Select-Object -First 1)
        Write-Step "Fetching latest Equicord..."
        Invoke-GitChecked -Arguments @("fetch", "--prune") -Description "Git fetch"
        Write-Step "Applying fast-forward update..."
        Invoke-GitChecked -Arguments @("pull", "--ff-only") -Description "Git fast-forward pull"
        $newHead = (Invoke-Git rev-parse HEAD | Select-Object -First 1)
        if ($oldHead -ne $newHead) { $script:UpdateChanged = $true } else { $script:UpdateChanged = $false }
    }
    $changed = [bool]$script:UpdateChanged
    Remove-Variable -Name UpdateChanged -Scope Script -ErrorAction SilentlyContinue
    if ($changed) { Write-Success "Equicord updated." } else { Write-Success "Equicord is already current." }
    return $changed
}
#endregion

#region WORKFLOWS
function Run-FullSetup {
    Clear-Host
    Write-Header "Full Equicord Setup"
    Write-Info "Installs missing tools, clones or updates Equicord, lets you choose plugins,"
    Write-Info "then installs dependencies, builds, and injects."
    Write-Warn "This setup must NOT be run as Administrator."
    Write-Host ""
    if (-not (Get-Confirm "Ready to begin?")) { return }
    if (Test-IsAdministrator) { Write-Err "Close this and run it normally, not as Administrator."; Pause-Return; return }

    try {
        if (-not (Ensure-DevTools)) { Pause-Return; return }
        Ensure-EquicordSource -UpdateExisting | Out-Null
        $summary = Show-PluginManager -DuringSetup
        if (-not $summary) { Write-Warn "Setup cancelled before plugin selection was applied."; Pause-Return; return }
        if ($summary.Failed.Count) { throw "One or more selected plugins could not be applied. Review the plugin summary before retrying." }
        Install-EquicordDependencies
        Invoke-EquicordBuild
        $summary.BuildPerformed = $true
        if (Invoke-EquicordInject) { $summary.InjectPerformed = $true }
        Write-PluginApplySummary -Summary $summary
        if ($summary.InjectPerformed) { Write-Success "Full setup complete. Open Discord normally." }
        else { Write-Warn "Equicord was built, but injection was not completed." }
    } catch {
        Write-Err $_.Exception.Message
    }
    Pause-Return
}

function Run-ManagePlugins {
    Clear-Host
    Write-Header "Manage Custom Plugins"
    if (Test-IsAdministrator) { Write-Err "Close this and run it normally, not as Administrator."; Pause-Return; return }
    $summary = Show-PluginManager
    if (-not $summary) { return }
    if ($summary.Failed.Count) { Write-Err "One or more plugin changes failed. Build was skipped."; Pause-Return; return }

    try {
        $force = [bool]$summary.ForceBuild
        if ($summary.FilesChanged -or $force) {
            if (-not (Ensure-DevTools)) { Pause-Return; return }
            if (Get-Confirm "Build Equicord now?") {
                Install-EquicordDependencies
                Invoke-EquicordBuild
                $summary.BuildPerformed = $true
                if (Get-Confirm "Run repair/reinject now?") {
                    if (Invoke-EquicordInject -Repair) { $summary.InjectPerformed = $true }
                }
            } else {
                Write-Warn "Plugin files changed. Build later before expecting Discord to show the new selection."
            }
        } else {
            Write-Success "No plugin files changed, so build and injection were skipped."
        }
        Write-PluginApplySummary -Summary $summary
    } catch {
        Write-Err $_.Exception.Message
    }
    Pause-Return
}

function Run-UpdateEquicord {
    Clear-Host
    Write-Header "Update Equicord and Rebuild"
    Write-Info "Updates Equicord with a fast-forward Git pull, preserves userplugins, then rebuilds."
    Write-Info "Reinjection is separate; use Repair/reinject if Discord is no longer patched."
    Write-Host ""
    if (-not (Get-Confirm "Ready to update and rebuild?")) { return }
    if (Test-IsAdministrator) { Write-Err "Close this and run it normally, not as Administrator."; Pause-Return; return }
    try {
        if (-not (Ensure-DevTools)) { Pause-Return; return }
        $changed = Ensure-EquicordSource -UpdateExisting
        if (-not $changed) {
            if (-not (Get-Confirm "No source update was found. Rebuild anyway?")) { Pause-Return; return }
        }
        Install-EquicordDependencies
        Invoke-EquicordBuild
        Write-Success "Update/rebuild complete. Restart Discord to load the new build."
    } catch {
        Write-Err $_.Exception.Message
    }
    Pause-Return
}

function Run-RepairReinject {
    Clear-Host
    Write-Header "Repair / Reinject Equicord"
    Write-Info "Use this after Discord updates or when Equicord stops loading."
    Write-Info "This does not rewrite custom plugins."
    Write-Host ""
    if (-not (Get-Confirm "Ready to repair and reinject?")) { return }
    if (Test-IsAdministrator) { Write-Err "Close this and run it normally, not as Administrator."; Pause-Return; return }
    try {
        if (-not (Ensure-DevTools)) { Pause-Return; return }
        if (-not (Test-EquicordRepo $script:EquicordDir)) { throw "Equicord folder not found. Run Full Equicord setup first." }
        if (-not (Invoke-EquicordInject -Repair)) { Write-Warn "Repair/reinjection was not completed." }
    } catch {
        Write-Err $_.Exception.Message
    }
    Pause-Return
}

function Run-Diagnostics {
    Clear-Host
    Write-Header "Diagnostics / Status"
    $equicord = $script:EquicordDir
    $pluginsDir = Get-PluginsDir $equicord
    Write-Section "Paths"
    Write-Host "  Equicord directory: $equicord"
    Write-Host "  Config file:        $script:ConfigPath"

    Write-Section "Tools"
    Write-Host "  Git:   $(Get-ToolVersion -Names @('git.exe','git'))"
    Write-Host "  Node:  $(Get-ToolVersion -Names @('node.exe','node'))"
    Write-Host "  npm:   $(Get-ToolVersion -Names @('npm.cmd','npm'))"
    Write-Host "  pnpm:  $(Get-ToolVersion -Names @('pnpm.cmd','pnpm.exe','pnpm'))"
    Write-Host "  Corepack:$(Get-ToolVersion -Names @('corepack.cmd','corepack.exe','corepack'))"
    Write-Host "  winget:$(Get-ToolVersion -Names @('winget.exe','winget'))"

    Write-Section "Equicord Repository"
    if (Test-EquicordRepo $equicord) {
        try {
            Invoke-InDirectory -Path $equicord -Script {
                Write-Host "  Branch: $(Invoke-Git branch --show-current)"
                Write-Host "  HEAD:   $((Invoke-Git rev-parse --short HEAD | Select-Object -First 1))"
                Write-Host "  Status: $((Invoke-Git status -sb | Select-Object -First 1))"
            }
        } catch { Write-Host "  Git status unavailable: $($_.Exception.Message)" }
    } else {
        Write-Host "  Not found or incomplete."
    }

    Write-Section "Discord"
    $discords = @(Get-DiscordInstallCandidates)
    if ($discords.Count) {
        foreach ($d in $discords) { Write-Host "  $($d.Name): $($d.AppDirectory)" }
    } else {
        Write-Host "  No usable Discord install was detected."
    }

    Write-Section "Bundled Plugins"
    if (Test-Path -LiteralPath $pluginsDir) {
        foreach ($plugin in Get-BundledPlugins) {
            $installed = Test-BundledPluginInstalled -Plugin $plugin -PluginsDir $pluginsDir
            Write-Host ("  {0,-22} {1}" -f $plugin.DisplayName, $(if ($installed) { "installed" } else { "not installed" }))
        }
        $unknown = @(Get-UnknownUserPluginFolders -PluginsDir $pluginsDir)
        Write-Host ""
        Write-Host "  Unknown user-plugin folders: " -NoNewline
        Write-Host ($(if ($unknown.Count) { $unknown -join ", " } else { "none" }))
    } else {
        Write-Host "  src\userplugins does not exist yet."
    }

    Write-Section "Build"
    $desktopAsar = Join-Path $equicord "dist\desktop.asar"
    $renderer = Join-Path $equicord "dist\desktop\renderer.js"
    if ((Test-Path -LiteralPath $desktopAsar -PathType Leaf) -or (Test-Path -LiteralPath $renderer -PathType Leaf)) {
        Write-Host "  Desktop build appears to exist."
    } else {
        Write-Host "  No desktop build output was found."
    }

    Pause-Return
}
#endregion

#region MAIN MENU
function Show-MainMenu {
    if (Test-IsAdministrator) {
        Clear-Host
        Write-Err "Do not run EquicordSetup as Administrator."
        Write-Info "Close this window and double-click the file normally."
        Pause-Return
        exit 1
    }

    while ($true) {
        Clear-Host
        Write-Host ""
        Write-Host "    ___  ____  ____  ____  ___  __  ____  ____  " -ForegroundColor Cyan
        Write-Host "   / __)( ___)(  _ \(_  _)/ __)/  \(  _ \(  _ \ " -ForegroundColor Cyan
        Write-Host "  ( (__  )__)  )(_) )_)(_ \__ \  O ))   / )(_) )" -ForegroundColor Cyan
        Write-Host "   \___)(____)(___ /(____)(___)/___)(_)\_)(____/ " -ForegroundColor Cyan
        Write-Host "                                            setup " -ForegroundColor DarkGray
        Write-Host ""
        Write-Host $LINE -ForegroundColor Cyan
        Write-Section "What do you want to do?"
        Write-MenuItem "1" "Full Equicord setup"
        Write-MenuItem "2" "Manage custom plugins"
        Write-MenuItem "3" "Update Equicord and rebuild"
        Write-MenuItem "4" "Repair/reinject Equicord"
        Write-MenuItem "5" "Diagnostics/status"
        Write-MenuItem "6" "Exit"
        Write-Host $LINE -ForegroundColor Cyan

        switch (Get-KeyChoice) {
            "1" { Run-FullSetup }
            "2" { Run-ManagePlugins }
            "3" { Run-UpdateEquicord }
            "4" { Run-RepairReinject }
            "5" { Run-Diagnostics }
            "6" { Clear-Host; Write-Host ""; Write-Host "  Goodbye." -ForegroundColor Cyan; Write-Host ""; exit }
        }
    }
}

if ($env:EQUICORD_SETUP_VALIDATE_ONLY -eq "1") {
    Write-Output "EquicordSetup embedded PowerShell loaded successfully."
    exit 0
}
Show-MainMenu
#endregion
