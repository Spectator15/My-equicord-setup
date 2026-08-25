@echo off
setlocal DisableDelayedExpansion
rem This project contains modified third-party GPL-licensed plugin code.
rem Original copyright and authorship remain with the respective upstream contributors.
rem Modifications for My Equicord Setup by Spectator15, 2026-08-15.
rem SPDX-License-Identifier: GPL-3.0-or-later
rem GENERATED FILE: built from src/ by build/Build-Release.ps1.
rem Edit the organised source files instead of editing Equicord.bat directly.
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

#region BUNDLED PLUGIN PAYLOAD
$script:BundledPlugins = @(
    [pscustomobject]@{
        Id = 'smoothType'
        DisplayName = 'SmoothType'
        FolderName = 'smoothType'
        Description = 'Smooth animated caret for Discord''s message input.'
        DefaultSelected = $true
        LegacyFolders = @('SmoothType')
        Notes = 'Uses DOM selection listeners with cleanup.'
        Files = [ordered]@{
            'index.tsx' = (@(
                'LyoNCiAqIFZlbmNvcmQsIGEgRGlzY29yZCBjbGllbnQgbW9kDQogKiBDb3B5cmlnaHQgKGMpIDIwMjQgVmVuZGljYXRlZCBhbmQgY29udHJpYnV0b3JzDQog'
                'KiBTUERYLUxpY2Vuc2UtSWRlbnRpZmllcjogR1BMLTMuMC1vci1sYXRlcg0KICoNCiAqIE1vZGlmaWVkIGZvciBNeSBFcXVpY29yZCBTZXR1cCBieSBTcGVj'
                'dGF0b3IxNSwgMjAyNi0wOC0xNS4NCiAqIE9yaWdpbmFsIGNvcHlyaWdodCBhbmQgYXV0aG9yc2hpcCByZW1haW4gd2l0aCB0aGUgcmVzcGVjdGl2ZSB1cHN0'
                'cmVhbSBjb250cmlidXRvcnMuDQogKi8NCg0KaW1wb3J0IHsgZGVmaW5lUGx1Z2luU2V0dGluZ3MgfSBmcm9tICJAYXBpL1NldHRpbmdzIjsNCmltcG9ydCBk'
                'ZWZpbmVQbHVnaW4sIHsgT3B0aW9uVHlwZSB9IGZyb20gIkB1dGlscy90eXBlcyI7DQoNCmNvbnN0IFNUWUxFX0lEID0gInZjLXNtb290aHR5cGUiOw0KDQpj'
                'b25zdCBzZXR0aW5ncyA9IGRlZmluZVBsdWdpblNldHRpbmdzKHsNCiAgICB0cmFuc2l0aW9uRGVsYXk6IHsNCiAgICAgICAgdHlwZTogT3B0aW9uVHlwZS5O'
                'VU1CRVIsDQogICAgICAgIGRlc2NyaXB0aW9uOiAiVHJhbnNpdGlvbiBEZWxheSAobXMpIiwNCiAgICAgICAgZGVmYXVsdDogNjAsDQogICAgICAgIG9uQ2hh'
                'bmdlOiAoKSA9PiBhcHBseUNTUygpLA0KICAgIH0sDQogICAgYW5pbWF0aW9uVHlwZTogew0KICAgICAgICB0eXBlOiBPcHRpb25UeXBlLlNFTEVDVCwNCiAg'
                'ICAgICAgZGVzY3JpcHRpb246ICJBbmltYXRpb24gVHlwZSIsDQogICAgICAgIG9wdGlvbnM6IFsNCiAgICAgICAgICAgIHsgbGFiZWw6ICJFYXNlIiwgdmFs'
                'dWU6ICJlYXNlIiwgZGVmYXVsdDogdHJ1ZSB9LA0KICAgICAgICAgICAgeyBsYWJlbDogIkxpbmVhciIsIHZhbHVlOiAibGluZWFyIiB9LA0KICAgICAgICAg'
                'ICAgeyBsYWJlbDogIkVhc2UtaW4iLCB2YWx1ZTogImVhc2UtaW4iIH0sDQogICAgICAgICAgICB7IGxhYmVsOiAiRWFzZS1vdXQiLCB2YWx1ZTogImVhc2Ut'
                'b3V0IiB9LA0KICAgICAgICAgICAgeyBsYWJlbDogIkVhc2UtaW4tb3V0IiwgdmFsdWU6ICJlYXNlLWluLW91dCIgfSwNCiAgICAgICAgXSwNCiAgICAgICAg'
                'b25DaGFuZ2U6ICgpID0+IGFwcGx5Q1NTKCksDQogICAgfSwNCn0pOw0KDQpmdW5jdGlvbiBidWlsZENTUygpOiBzdHJpbmcgew0KICAgIGNvbnN0IG1zID0g'
                'c2V0dGluZ3Muc3RvcmUudHJhbnNpdGlvbkRlbGF5ID8/IDYwOw0KICAgIGNvbnN0IGVhc2luZyA9IHNldHRpbmdzLnN0b3JlLmFuaW1hdGlvblR5cGUgPz8g'
                'ImVhc2UiOw0KICAgIHJldHVybiBgDQpAa2V5ZnJhbWVzIHZjLWJsaW5rIHsNCiAgICAwJSwgMTAwJSB7IG9wYWNpdHk6IDE7IH0NCiAgICA1MCUgICAgICAg'
                'eyBvcGFjaXR5OiAwOyB9DQp9DQojdmMtc21vb3RodHlwZS1jYXJldC5pcy1ibGlua2luZyB7DQogICAgYW5pbWF0aW9uOiB2Yy1ibGluayAxcyBlYXNlLWlu'
                'LW91dCBpbmZpbml0ZTsNCn0NCiN2Yy1zbW9vdGh0eXBlLWNhcmV0IHsNCiAgICBwb3NpdGlvbjogZml4ZWQ7DQogICAgdG9wOiAwOyBsZWZ0OiAwOw0KICAg'
                'IHdpZHRoOiAycHg7DQogICAgYm9yZGVyLXJhZGl1czogMnB4Ow0KICAgIGJhY2tncm91bmQ6IHdoaXRlOw0KICAgIHBvaW50ZXItZXZlbnRzOiBub25lOw0K'
                'ICAgIHotaW5kZXg6IDk5OTk5Ow0KICAgIGRpc3BsYXk6IG5vbmU7DQogICAgdHJhbnNpdGlvbjogbGVmdCAke21zfW1zICR7ZWFzaW5nfSwgdG9wICR7bXN9'
                'bXMgJHtlYXNpbmd9LCBoZWlnaHQgJHttc31tcyAke2Vhc2luZ307DQp9DQpbZGF0YS1zbGF0ZS1lZGl0b3JdIHsgY2FyZXQtY29sb3I6IHRyYW5zcGFyZW50'
                'ICFpbXBvcnRhbnQ7IH0NCmA7DQp9DQoNCmZ1bmN0aW9uIGdldENhcmV0KCk6IEhUTUxEaXZFbGVtZW50IHwgbnVsbCB7DQogICAgbGV0IGVsID0gZG9jdW1l'
                'bnQuZ2V0RWxlbWVudEJ5SWQoInZjLXNtb290aHR5cGUtY2FyZXQiKSBhcyBIVE1MRGl2RWxlbWVudCB8IG51bGw7DQogICAgaWYgKCFlbCkgew0KICAgICAg'
                'ICBpZiAoIWRvY3VtZW50LmJvZHkpIHJldHVybiBudWxsOw0KICAgICAgICBlbCA9IGRvY3VtZW50LmNyZWF0ZUVsZW1lbnQoImRpdiIpOw0KICAgICAgICBl'
                'bC5pZCA9ICJ2Yy1zbW9vdGh0eXBlLWNhcmV0IjsNCiAgICAgICAgZG9jdW1lbnQuYm9keS5hcHBlbmRDaGlsZChlbCk7DQogICAgfQ0KICAgIHJldHVybiBl'
                'bDsNCn0NCg0KbGV0IGJsaW5rVGltZXI6IFJldHVyblR5cGU8dHlwZW9mIHNldFRpbWVvdXQ+IHwgbnVsbCA9IG51bGw7DQpsZXQgaW5pdFRpbWVyOiBSZXR1'
                'cm5UeXBlPHR5cGVvZiBzZXRUaW1lb3V0PiB8IG51bGwgPSBudWxsOw0KbGV0IGluaXRpYWxpemVkID0gZmFsc2U7DQoNCmZ1bmN0aW9uIHN0YXJ0Qmxpbmso'
                'KSB7IGJsaW5rVGltZXIgPSBudWxsOyBjb25zdCBlbCA9IGdldENhcmV0KCk7IGlmICghZWwpIHJldHVybjsgZWwuY2xhc3NMaXN0LmFkZCgiaXMtYmxpbmtp'
                'bmciKTsgfQ0KZnVuY3Rpb24gc3RvcEJsaW5rKCkgew0KICAgIGNvbnN0IGVsID0gZ2V0Q2FyZXQoKTsgaWYgKCFlbCkgcmV0dXJuOw0KICAgIGVsLmNsYXNz'
                'TGlzdC5yZW1vdmUoImlzLWJsaW5raW5nIik7DQogICAgaWYgKGJsaW5rVGltZXIpIGNsZWFyVGltZW91dChibGlua1RpbWVyKTsNCiAgICBibGlua1RpbWVy'
                'ID0gc2V0VGltZW91dChzdGFydEJsaW5rLCAxMDAwKTsNCn0NCg0KZnVuY3Rpb24gYXBwbHlDYXJldFBvc2l0aW9uKCkgew0KICAgIGNvbnN0IGVsID0gZ2V0'
                'Q2FyZXQoKTsNCiAgICBpZiAoIWVsKSByZXR1cm47DQogICAgaWYgKCFkb2N1bWVudC5hY3RpdmVFbGVtZW50Py5jbG9zZXN0KCJbZGF0YS1zbGF0ZS1lZGl0'
                'b3JdIikpIHsgZWwuc3R5bGUuZGlzcGxheSA9ICJub25lIjsgcmV0dXJuOyB9DQogICAgY29uc3Qgc2VsID0gd2luZG93LmdldFNlbGVjdGlvbigpOw0KICAg'
                'IGlmICghc2VsPy5yYW5nZUNvdW50KSB7IGVsLnN0eWxlLmRpc3BsYXkgPSAibm9uZSI7IHJldHVybjsgfQ0KICAgIGNvbnN0IHJhbmdlID0gc2VsLmdldFJh'
                'bmdlQXQoMCkuY2xvbmVSYW5nZSgpOw0KICAgIHJhbmdlLmNvbGxhcHNlKGZhbHNlKTsNCiAgICBjb25zdCByZWN0cyA9IHJhbmdlLmdldENsaWVudFJlY3Rz'
                'KCk7DQogICAgbGV0IHJlY3Q6IERPTVJlY3QgfCBudWxsID0gcmVjdHMubGVuZ3RoID4gMCA/IHJlY3RzWzBdIDogbnVsbDsNCiAgICBpZiAoIXJlY3QgfHwg'
                'cmVjdC5oZWlnaHQgPT09IDApIHsNCiAgICAgICAgY29uc3Qgbm9kZSA9IHJhbmdlLnN0YXJ0Q29udGFpbmVyOw0KICAgICAgICBjb25zdCBwYXJlbnQgPSAo'
                'bm9kZS5ub2RlVHlwZSA9PT0gTm9kZS5URVhUX05PREUgPyBub2RlLnBhcmVudEVsZW1lbnQgOiBub2RlKSBhcyBIVE1MRWxlbWVudCB8IG51bGw7DQogICAg'
                'ICAgIGlmIChwYXJlbnQpIHJlY3QgPSBwYXJlbnQuZ2V0Qm91bmRpbmdDbGllbnRSZWN0KCk7DQogICAgfQ0KICAgIGlmICghcmVjdCB8fCByZWN0LmhlaWdo'
                'dCA9PT0gMCkgeyBlbC5zdHlsZS5kaXNwbGF5ID0gIm5vbmUiOyByZXR1cm47IH0NCiAgICBjb25zdCBuZXdMZWZ0ID0gcmVjdC5yaWdodCArICJweCI7DQog'
                'ICAgY29uc3QgbmV3VG9wID0gcmVjdC50b3AgKyAicHgiOw0KICAgIGlmIChlbC5zdHlsZS5sZWZ0ICE9PSBuZXdMZWZ0IHx8IGVsLnN0eWxlLnRvcCAhPT0g'
                'bmV3VG9wKSB7IGlmIChlbC5zdHlsZS5kaXNwbGF5ICE9PSAibm9uZSIpIHN0b3BCbGluaygpOyB9DQogICAgZWwuc3R5bGUuZGlzcGxheSA9ICJibG9jayI7'
                'DQogICAgZWwuc3R5bGUubGVmdCA9IG5ld0xlZnQ7DQogICAgZWwuc3R5bGUudG9wID0gcmVjdC50b3AgKyAicHgiOw0KICAgIGVsLnN0eWxlLmhlaWdodCA9'
                'IHJlY3QuaGVpZ2h0ICsgInB4IjsNCn0NCg0KbGV0IG9ic2VydmVyOiBNdXRhdGlvbk9ic2VydmVyIHwgbnVsbCA9IG51bGw7DQpmdW5jdGlvbiBzdGFydE9i'
                'c2VydmVyKCkgew0KICAgIGlmIChvYnNlcnZlciB8fCBkb2N1bWVudC52aXNpYmlsaXR5U3RhdGUgPT09ICJoaWRkZW4iKSByZXR1cm47DQogICAgb2JzZXJ2'
                'ZXIgPSBuZXcgTXV0YXRpb25PYnNlcnZlcigoKSA9PiBhcHBseUNhcmV0UG9zaXRpb24oKSk7DQogICAgb2JzZXJ2ZXIub2JzZXJ2ZShkb2N1bWVudC5ib2R5'
                'LCB7IGNoaWxkTGlzdDogdHJ1ZSwgc3VidHJlZTogdHJ1ZSB9KTsNCn0NCmZ1bmN0aW9uIHN0b3BPYnNlcnZlcigpIHsgb2JzZXJ2ZXI/LmRpc2Nvbm5lY3Qo'
                'KTsgb2JzZXJ2ZXIgPSBudWxsOyB9DQoNCmZ1bmN0aW9uIGhhbmRsZVZpc2liaWxpdHlDaGFuZ2UoKSB7DQogICAgaWYgKGRvY3VtZW50LnZpc2liaWxpdHlT'
                'dGF0ZSA9PT0gImhpZGRlbiIpIHsgc3RvcE9ic2VydmVyKCk7IH0NCiAgICBlbHNlIGlmIChkb2N1bWVudC5hY3RpdmVFbGVtZW50Py5jbG9zZXN0KCJbZGF0'
                'YS1zbGF0ZS1lZGl0b3JdIikpIHsgc3RhcnRPYnNlcnZlcigpOyB9DQp9DQoNCmNvbnN0IGhhbmRsZXJzID0gew0KICAgIHNlbDogICAoKSA9PiBhcHBseUNh'
                'cmV0UG9zaXRpb24oKSwNCiAgICBmb2N1czogKCkgPT4geyBhcHBseUNhcmV0UG9zaXRpb24oKTsgaWYgKGRvY3VtZW50LmFjdGl2ZUVsZW1lbnQ/LmNsb3Nl'
                'c3QoIltkYXRhLXNsYXRlLWVkaXRvcl0iKSkgc3RhcnRPYnNlcnZlcigpOyB9LA0KICAgIGJsdXI6ICAoKSA9PiB7IGNvbnN0IGVsID0gZ2V0Q2FyZXQoKTsg'
                'aWYgKGVsKSBlbC5zdHlsZS5kaXNwbGF5ID0gIm5vbmUiOyBzdG9wT2JzZXJ2ZXIoKTsgfSwNCiAgICBrZXk6ICAgKCkgPT4gYXBwbHlDYXJldFBvc2l0aW9u'
                'KCksDQogICAgY2xpY2s6ICgpID0+IHsgYXBwbHlDYXJldFBvc2l0aW9uKCk7IGlmIChkb2N1bWVudC5hY3RpdmVFbGVtZW50Py5jbG9zZXN0KCJbZGF0YS1z'
                'bGF0ZS1lZGl0b3JdIikpIHN0YXJ0T2JzZXJ2ZXIoKTsgZWxzZSBzdG9wT2JzZXJ2ZXIoKTsgfSwNCn07DQoNCmZ1bmN0aW9uIHN0YXJ0TGlzdGVuZXJzKCkg'
                'ew0KICAgIGRvY3VtZW50LmFkZEV2ZW50TGlzdGVuZXIoInNlbGVjdGlvbmNoYW5nZSIsIGhhbmRsZXJzLnNlbCk7DQogICAgZG9jdW1lbnQuYWRkRXZlbnRM'
                'aXN0ZW5lcigiZm9jdXNpbiIsIGhhbmRsZXJzLmZvY3VzKTsNCiAgICBkb2N1bWVudC5hZGRFdmVudExpc3RlbmVyKCJmb2N1c291dCIsIGhhbmRsZXJzLmJs'
                'dXIpOw0KICAgIGRvY3VtZW50LmFkZEV2ZW50TGlzdGVuZXIoImtleXVwIiwgaGFuZGxlcnMua2V5LCB0cnVlKTsNCiAgICBkb2N1bWVudC5hZGRFdmVudExp'
                'c3RlbmVyKCJjbGljayIsIGhhbmRsZXJzLmNsaWNrLCB0cnVlKTsNCn0NCmZ1bmN0aW9uIHN0b3BMaXN0ZW5lcnMoKSB7DQogICAgZG9jdW1lbnQucmVtb3Zl'
                'RXZlbnRMaXN0ZW5lcigic2VsZWN0aW9uY2hhbmdlIiwgaGFuZGxlcnMuc2VsKTsNCiAgICBkb2N1bWVudC5yZW1vdmVFdmVudExpc3RlbmVyKCJmb2N1c2lu'
                'IiwgaGFuZGxlcnMuZm9jdXMpOw0KICAgIGRvY3VtZW50LnJlbW92ZUV2ZW50TGlzdGVuZXIoImZvY3Vzb3V0IiwgaGFuZGxlcnMuYmx1cik7DQogICAgZG9j'
                'dW1lbnQucmVtb3ZlRXZlbnRMaXN0ZW5lcigia2V5dXAiLCBoYW5kbGVycy5rZXksIHRydWUpOw0KICAgIGRvY3VtZW50LnJlbW92ZUV2ZW50TGlzdGVuZXIo'
                'ImNsaWNrIiwgaGFuZGxlcnMuY2xpY2ssIHRydWUpOw0KfQ0KDQpmdW5jdGlvbiBhcHBseUNTUygpIHsNCiAgICBkb2N1bWVudC5nZXRFbGVtZW50QnlJZChT'
                'VFlMRV9JRCk/LnJlbW92ZSgpOw0KICAgIGNvbnN0IHMgPSBkb2N1bWVudC5jcmVhdGVFbGVtZW50KCJzdHlsZSIpOw0KICAgIHMuaWQgPSBTVFlMRV9JRDsg'
                'cy50ZXh0Q29udGVudCA9IGJ1aWxkQ1NTKCk7DQogICAgZG9jdW1lbnQuaGVhZC5hcHBlbmRDaGlsZChzKTsNCn0NCmZ1bmN0aW9uIHJlbW92ZUNTUygpIHsg'
                'ZG9jdW1lbnQuZ2V0RWxlbWVudEJ5SWQoU1RZTEVfSUQpPy5yZW1vdmUoKTsgfQ0KDQpleHBvcnQgZGVmYXVsdCBkZWZpbmVQbHVnaW4oew0KICAgIG5hbWU6'
                'ICJTbW9vdGhUeXBlIiwNCiAgICBlbmFibGVkQnlEZWZhdWx0OiB0cnVlLA0KICAgIGRlc2NyaXB0aW9uOiAiU21vb3RoIGFuaW1hdGVkIGNhcmV0IGZvciB0'
                'aGUgRGlzY29yZCBtZXNzYWdlIGlucHV0LiIsDQogICAgYXV0aG9yczogW3sgbmFtZTogImRhbmlzaCIsIGlkOiAwbiB9XSwNCiAgICBzZXR0aW5ncywNCiAg'
                'ICBzdGFydCgpIHsNCiAgICAgICAgY29uc3QgaW5pdCA9ICgpID0+IHsNCiAgICAgICAgICAgIGluaXRUaW1lciA9IG51bGw7DQogICAgICAgICAgICBpZiAo'
                'IWRvY3VtZW50LmJvZHkpIHsgaW5pdFRpbWVyID0gc2V0VGltZW91dChpbml0LCAxMDApOyByZXR1cm47IH0NCiAgICAgICAgICAgIGlmIChpbml0aWFsaXpl'
                'ZCkgcmV0dXJuOw0KICAgICAgICAgICAgaW5pdGlhbGl6ZWQgPSB0cnVlOw0KICAgICAgICAgICAgYXBwbHlDU1MoKTsNCiAgICAgICAgICAgIGdldENhcmV0'
                'KCk7DQogICAgICAgICAgICBpZiAoZG9jdW1lbnQuYWN0aXZlRWxlbWVudD8uY2xvc2VzdCgiW2RhdGEtc2xhdGUtZWRpdG9yXSIpKSBzdGFydE9ic2VydmVy'
                'KCk7DQogICAgICAgICAgICBzdGFydExpc3RlbmVycygpOw0KICAgICAgICAgICAgZG9jdW1lbnQuYWRkRXZlbnRMaXN0ZW5lcigidmlzaWJpbGl0eWNoYW5n'
                'ZSIsIGhhbmRsZVZpc2liaWxpdHlDaGFuZ2UpOw0KICAgICAgICB9Ow0KICAgICAgICBpbml0KCk7DQogICAgfSwNCiAgICBzdG9wKCkgew0KICAgICAgICBp'
                'bml0aWFsaXplZCA9IGZhbHNlOw0KICAgICAgICBpZiAoaW5pdFRpbWVyKSB7IGNsZWFyVGltZW91dChpbml0VGltZXIpOyBpbml0VGltZXIgPSBudWxsOyB9'
                'DQogICAgICAgIGRvY3VtZW50LnJlbW92ZUV2ZW50TGlzdGVuZXIoInZpc2liaWxpdHljaGFuZ2UiLCBoYW5kbGVWaXNpYmlsaXR5Q2hhbmdlKTsNCiAgICAg'
                'ICAgc3RvcE9ic2VydmVyKCk7IHN0b3BMaXN0ZW5lcnMoKTsgcmVtb3ZlQ1NTKCk7DQogICAgICAgIGlmIChibGlua1RpbWVyKSB7IGNsZWFyVGltZW91dChi'
                'bGlua1RpbWVyKTsgYmxpbmtUaW1lciA9IG51bGw7IH0NCiAgICAgICAgZG9jdW1lbnQuZ2V0RWxlbWVudEJ5SWQoInZjLXNtb290aHR5cGUtY2FyZXQiKT8u'
                'cmVtb3ZlKCk7DQogICAgfSwNCn0pOw0K'
            ) -join '')
        }
    }
    [pscustomobject]@{
        Id = 'streamerModeOnStream'
        DisplayName = 'StreamerModeOnStream'
        FolderName = 'streamerModeOnStream'
        Description = 'Automatically enables streamer mode while you stream.'
        DefaultSelected = $true
        LegacyFolders = @('StreamerModeOnStream')
        Notes = 'Uses declarative Flux events.'
        Files = [ordered]@{
            'index.ts' = (@(
                'LyoNCiAqIFZlbmNvcmQsIGEgRGlzY29yZCBjbGllbnQgbW9kDQogKiBDb3B5cmlnaHQgKGMpIDIwMjYgVmVuZGljYXRlZCBhbmQgY29udHJpYnV0b3JzDQog'
                'KiBTUERYLUxpY2Vuc2UtSWRlbnRpZmllcjogR1BMLTMuMC1vci1sYXRlcg0KICoNCiAqIE1vZGlmaWVkIGZvciBNeSBFcXVpY29yZCBTZXR1cCBieSBTcGVj'
                'dGF0b3IxNSwgMjAyNi0wOC0xNS4NCiAqIE9yaWdpbmFsIGNvcHlyaWdodCBhbmQgYXV0aG9yc2hpcCByZW1haW4gd2l0aCB0aGUgcmVzcGVjdGl2ZSB1cHN0'
                'cmVhbSBjb250cmlidXRvcnMuDQogKi8NCg0KaW1wb3J0IHsgRGV2cyB9IGZyb20gIkB1dGlscy9jb25zdGFudHMiOw0KaW1wb3J0IGRlZmluZVBsdWdpbiBm'
                'cm9tICJAdXRpbHMvdHlwZXMiOw0KaW1wb3J0IHsgRmx1eERpc3BhdGNoZXIsIFVzZXJTdG9yZSB9IGZyb20gIkB3ZWJwYWNrL2NvbW1vbiI7DQoNCmludGVy'
                'ZmFjZSBTdHJlYW1FdmVudCB7DQogICAgc3RyZWFtS2V5OiBzdHJpbmc7DQp9DQoNCmZ1bmN0aW9uIHRvZ2dsZVN0cmVhbWVyTW9kZSh7IHN0cmVhbUtleSB9'
                'OiBTdHJlYW1FdmVudCwgdmFsdWU6IGJvb2xlYW4pIHsNCiAgICBjb25zdCBjdXJyZW50VXNlciA9IFVzZXJTdG9yZS5nZXRDdXJyZW50VXNlcigpOw0KICAg'
                'IGlmICghY3VycmVudFVzZXIgfHwgIXN0cmVhbUtleT8uZW5kc1dpdGgoY3VycmVudFVzZXIuaWQpKSByZXR1cm47DQoNCiAgICBGbHV4RGlzcGF0Y2hlci5k'
                'aXNwYXRjaCh7DQogICAgICAgIHR5cGU6ICJTVFJFQU1FUl9NT0RFX1VQREFURSIsDQogICAgICAgIGtleTogImVuYWJsZWQiLA0KICAgICAgICB2YWx1ZQ0K'
                'ICAgIH0pOw0KfQ0KDQpleHBvcnQgZGVmYXVsdCBkZWZpbmVQbHVnaW4oew0KICAgIG5hbWU6ICJTdHJlYW1lck1vZGVPblN0cmVhbSIsDQogICAgZGVzY3Jp'
                'cHRpb246ICJBdXRvbWF0aWNhbGx5IGVuYWJsZXMgc3RyZWFtZXIgbW9kZSB3aGVuIHlvdSBiZWdpbiBzdHJlYW1pbmcgaW4gRGlzY29yZC4iLA0KICAgIHRh'
                'Z3M6IFsiUHJpdmFjeSIsICJVdGlsaXR5Il0sDQogICAgYXV0aG9yczogW0RldnMuSWNlZE1hcmluYV0sDQogICAgZmx1eDogew0KICAgICAgICBTVFJFQU1f'
                'Q1JFQVRFOiBkID0+IHRvZ2dsZVN0cmVhbWVyTW9kZShkLCB0cnVlKSwNCiAgICAgICAgU1RSRUFNX0RFTEVURTogZCA9PiB0b2dnbGVTdHJlYW1lck1vZGUo'
                'ZCwgZmFsc2UpDQogICAgfQ0KfSk7DQo='
            ) -join '')
        }
    }
    [pscustomobject]@{
        Id = 'exportDM'
        DisplayName = 'ExportDM'
        FolderName = 'exportDM'
        Description = 'Exports messages as JSON, online HTML, an offline ZIP archive, or self-contained HTML.'
        DefaultSelected = $true
        LegacyFolders = @('ExportDM')
        Notes = 'Uses Discord REST pagination and bounded, cancellable media downloads.'
        Files = [ordered]@{
            'index.tsx' = (@(
                'LyoNCiAqIFZlbmNvcmQsIGEgRGlzY29yZCBjbGllbnQgbW9kDQogKiBDb3B5cmlnaHQgKGMpIDIwMjYgVmVuZGljYXRlZCBhbmQgY29udHJpYnV0b3JzDQog'
                'KiBTUERYLUxpY2Vuc2UtSWRlbnRpZmllcjogR1BMLTMuMC1vci1sYXRlcg0KICoNCiAqIE1vZGlmaWVkIGZvciBNeSBFcXVpY29yZCBTZXR1cCBieSBTcGVj'
                'dGF0b3IxNSwgMjAyNi0wOC0xNS4NCiAqIE9yaWdpbmFsIGNvcHlyaWdodCBhbmQgYXV0aG9yc2hpcCByZW1haW4gd2l0aCB0aGUgcmVzcGVjdGl2ZSB1cHN0'
                'cmVhbSBjb250cmlidXRvcnMuDQogKi8NCg0KaW1wb3J0IHsgYWRkQ29udGV4dE1lbnVQYXRjaCwgTmF2Q29udGV4dE1lbnVQYXRjaENhbGxiYWNrLCByZW1v'
                'dmVDb250ZXh0TWVudVBhdGNoIH0gZnJvbSAiQGFwaS9Db250ZXh0TWVudSI7DQppbXBvcnQgeyBEaXZpZGVyIH0gZnJvbSAiQGNvbXBvbmVudHMvRGl2aWRl'
                'ciI7DQppbXBvcnQgZGVmaW5lUGx1Z2luIGZyb20gIkB1dGlscy90eXBlcyI7DQppbXBvcnQgdHlwZSB7IFJlbmRlck1vZGFsUHJvcHMgfSBmcm9tICJAdmVu'
                'Y29yZC9kaXNjb3JkLXR5cGVzIjsNCmltcG9ydCB7IENoYW5uZWxTdG9yZSwgQ29uc3RhbnRzLCBNZW51LCBNb2RhbCwgb3Blbk1vZGFsLCBSZWFjdCwgUmVz'
                'dEFQSSwgdXNlU3RhdGUgfSBmcm9tICJAd2VicGFjay9jb21tb24iOw0KaW1wb3J0IHsgc3RyVG9VOCwgdHlwZSBaaXBwYWJsZSwgemlwU3luYyB9IGZyb20g'
                'ImZmbGF0ZSI7DQoNCnR5cGUgRXhwb3J0Rm9ybWF0ID0gImpzb24iIHwgIm9ubGluZUh0bWwiIHwgIm9mZmxpbmVBcmNoaXZlIiB8ICJzaW5nbGVIdG1sIjsN'
                'CnR5cGUgQXNzZXRDYXRlZ29yeSA9ICJhdHRhY2htZW50cyIgfCAiYXZhdGFycyIgfCAiZW1vamlzIiB8ICJzdGlja2VycyIgfCAiZW1iZWRzIjsNCnR5cGUg'
                'TWVkaWFLaW5kID0gImltYWdlIiB8ICJ2aWRlbyIgfCAiYXVkaW8iIHwgImZpbGUiOw0KdHlwZSBIdG1sTW9kZSA9ICJvbmxpbmUiIHwgImFyY2hpdmUiIHwg'
                'InNpbmdsZSI7DQoNCmludGVyZmFjZSBFeHBvcnRPcHRpb25zIHsNCiAgICBhdHRhY2htZW50czogYm9vbGVhbjsNCiAgICBhdmF0YXJzOiBib29sZWFuOw0K'
                'ICAgIGVtb2ppc1N0aWNrZXJzOiBib29sZWFuOw0KICAgIGVtYmVkTWVkaWE6IGJvb2xlYW47DQp9DQoNCmludGVyZmFjZSBFeHBvcnRQcm9ncmVzcyB7DQog'
                'ICAgc3RhZ2U6IHN0cmluZzsNCiAgICBwcm9jZXNzZWQ6IG51bWJlcjsNCiAgICB0b3RhbDogbnVtYmVyOw0KICAgIGRvd25sb2FkZWRCeXRlczogbnVtYmVy'
                'Ow0KICAgIGZhaWx1cmVzOiBudW1iZXI7DQp9DQoNCmludGVyZmFjZSBBc3NldFJlcXVlc3Qgew0KICAgIGFsaWFzZXM6IHN0cmluZ1tdOw0KICAgIGNhdGVn'
                'b3J5OiBBc3NldENhdGVnb3J5Ow0KICAgIGV4cGVjdGVkU2l6ZTogbnVtYmVyOw0KICAgIGtpbmQ6IE1lZGlhS2luZDsNCiAgICBvcmlnaW5hbFVybDogc3Ry'
                'aW5nOw0KICAgIHBhdGg6IHN0cmluZzsNCiAgICB1cmxzOiBzdHJpbmdbXTsNCn0NCg0KaW50ZXJmYWNlIEFzc2V0Q2F0YWxvZyB7DQogICAgYWxpYXNlczog'
                'TWFwPHN0cmluZywgQXNzZXRSZXF1ZXN0PjsNCiAgICByZXF1ZXN0czogQXNzZXRSZXF1ZXN0W107DQp9DQoNCmludGVyZmFjZSBBc3NldFJlc3VsdCB7DQog'
                'ICAgYnl0ZXM/OiBVaW50OEFycmF5Ow0KICAgIGNvbnRlbnRUeXBlOiBzdHJpbmc7DQogICAgZXJyb3I/OiBzdHJpbmc7DQogICAga2luZDogTWVkaWFLaW5k'
                'Ow0KICAgIG9yaWdpbmFsVXJsOiBzdHJpbmc7DQogICAgcGF0aDogc3RyaW5nOw0KfQ0KDQppbnRlcmZhY2UgRG93bmxvYWRTdW1tYXJ5IHsNCiAgICBhbGlh'
                'c2VzOiBNYXA8c3RyaW5nLCBBc3NldFJlc3VsdD47DQogICAgZG93bmxvYWRlZDogQXNzZXRSZXN1bHRbXTsNCiAgICBkb3dubG9hZGVkQnl0ZXM6IG51bWJl'
                'cjsNCiAgICBmYWlsdXJlczogQXNzZXRSZXN1bHRbXTsNCn0NCg0KaW50ZXJmYWNlIEFyY2hpdmVCdWlsZFJlc3VsdCB7DQogICAgYnl0ZXM6IFVpbnQ4QXJy'
                'YXk7DQogICAgaHRtbDogc3RyaW5nOw0KICAgIG1hbmlmZXN0OiBSZWNvcmQ8c3RyaW5nLCB1bmtub3duPjsNCiAgICByZXBvcnQ6IHN0cmluZzsNCn0NCg0K'
                'aW50ZXJmYWNlIEVtYmVkZGVkQXNzZXRQYXlsb2FkIHsNCiAgICBhbGlhc2VzOiBSZWNvcmQ8c3RyaW5nLCBzdHJpbmc+Ow0KICAgIGRhdGE6IFJlY29yZDxz'
                'dHJpbmcsIHN0cmluZz47DQp9DQoNCmNvbnN0IERFRkFVTFRfT1BUSU9OUzogRXhwb3J0T3B0aW9ucyA9IHsNCiAgICBhdHRhY2htZW50czogdHJ1ZSwNCiAg'
                'ICBhdmF0YXJzOiB0cnVlLA0KICAgIGVtb2ppc1N0aWNrZXJzOiB0cnVlLA0KICAgIGVtYmVkTWVkaWE6IHRydWUNCn07DQpjb25zdCBBU1NFVF9DT05DVVJS'
                'RU5DWSA9IDQ7DQpjb25zdCBBU1NFVF9SRVRSSUVTID0gMzsNCmNvbnN0IEFTU0VUX1RJTUVPVVRfTVMgPSAyMF8wMDA7DQpjb25zdCBTSU5HTEVfSFRNTF9X'
                'QVJOSU5HX0JZVEVTID0gMjUgKiAxMDI0ICogMTAyNDsNCmNvbnN0IEdST1VQX1dJTkRPV19NUyA9IDcgKiA2MCAqIDEwMDA7DQoNCmNvbnN0IEZPUk1BVF9D'
                'SE9JQ0VTOiBBcnJheTx7IGlkOiBFeHBvcnRGb3JtYXQ7IHRpdGxlOiBzdHJpbmc7IGRlc2NyaXB0aW9uOiBzdHJpbmc7IGJhZGdlPzogc3RyaW5nOyB9PiA9'
                'IFsNCiAgICB7IGlkOiAianNvbiIsIHRpdGxlOiAiSlNPTiIsIGRlc2NyaXB0aW9uOiAiUmF3IGRhdGEsIHByZXNlcnZpbmcgZXZlcnkgY29sbGVjdGVkIG1l'
                'c3NhZ2UgZmllbGQuIiB9LA0KICAgIHsgaWQ6ICJvbmxpbmVIdG1sIiwgdGl0bGU6ICJPbmxpbmUgSFRNTCIsIGRlc2NyaXB0aW9uOiAiU21hbGwgZmlsZTsg'
                'bWVkaWEgbG9hZHMgZnJvbSBpdHMgb3JpZ2luYWwgb25saW5lIHNvdXJjZS4iIH0sDQogICAgeyBpZDogIm9mZmxpbmVBcmNoaXZlIiwgdGl0bGU6ICJPZmZs'
                'aW5lIEFyY2hpdmUiLCBkZXNjcmlwdGlvbjogIkNvbXBsZXRlIG9mZmxpbmUgY29weSBpbiBvbmUgWklQIGZpbGUuIiwgYmFkZ2U6ICJSZWNvbW1lbmRlZCIg'
                'fSwNCiAgICB7IGlkOiAic2luZ2xlSHRtbCIsIHRpdGxlOiAiU2luZ2xlIEhUTUwiLCBkZXNjcmlwdGlvbjogIk9uZSBwb3J0YWJsZSBvZmZsaW5lIGZpbGU7'
                'IHBvdGVudGlhbGx5IHZlcnkgbGFyZ2UuIiB9DQpdOw0KDQpjb25zdCBFWFBPUlRfTU9EQUxfQ1NTID0gYA0KLmVxLWV4cG9ydC1tb2RhbCB7IGNvbG9yOiAj'
                'ZGJkZWUxOyBwYWRkaW5nOiA0cHggMDsgfQ0KLmVxLWV4cG9ydC1tb2RhbCAqIHsgYm94LXNpemluZzogYm9yZGVyLWJveDsgfQ0KLmVxLWV4cG9ydC1mb3Jt'
                'YXQtZ3JpZCB7IGRpc3BsYXk6IGdyaWQ7IGdyaWQtdGVtcGxhdGUtY29sdW1uczogcmVwZWF0KDIsIG1pbm1heCgwLCAxZnIpKTsgZ2FwOiAxMHB4OyB9DQou'
                'ZXEtZXhwb3J0LWZvcm1hdCB7DQogICAgYXBwZWFyYW5jZTogbm9uZTsgbWluLWhlaWdodDogNzhweDsgcGFkZGluZzogMTJweDsgYm9yZGVyOiAxcHggc29s'
                'aWQgIzRlNTA1ODsgYm9yZGVyLXJhZGl1czogN3B4Ow0KICAgIGJhY2tncm91bmQ6ICMyYjJkMzE7IGNvbG9yOiAjZGJkZWUxOyB0ZXh0LWFsaWduOiBsZWZ0'
                'OyBjdXJzb3I6IHBvaW50ZXI7DQp9DQouZXEtZXhwb3J0LWZvcm1hdDpob3Zlcjpub3QoOmRpc2FibGVkKSwgLmVxLWV4cG9ydC1mb3JtYXQ6Zm9jdXMtdmlz'
                'aWJsZSB7IGJvcmRlci1jb2xvcjogIzk0OWJhNDsgb3V0bGluZTogbm9uZTsgfQ0KLmVxLWV4cG9ydC1mb3JtYXQtLXNlbGVjdGVkIHsgYm9yZGVyLWNvbG9y'
                'OiAjNzI4OWRhOyBiYWNrZ3JvdW5kOiAjMzUzODRhOyBib3gtc2hhZG93OiBpbnNldCAwIDAgMCAxcHggIzcyODlkYTsgfQ0KLmVxLWV4cG9ydC1mb3JtYXQ6'
                'ZGlzYWJsZWQgeyBjdXJzb3I6IG5vdC1hbGxvd2VkOyBvcGFjaXR5OiAuNjsgfQ0KLmVxLWV4cG9ydC1mb3JtYXQtaGVhZCB7IGRpc3BsYXk6IGZsZXg7IGFs'
                'aWduLWl0ZW1zOiBjZW50ZXI7IGp1c3RpZnktY29udGVudDogc3BhY2UtYmV0d2VlbjsgZ2FwOiA4cHg7IGNvbG9yOiAjZjJmM2Y1OyBmb250LXNpemU6IDE0'
                'cHg7IGZvbnQtd2VpZ2h0OiA3MDA7IH0NCi5lcS1leHBvcnQtZm9ybWF0LWRlc2MgeyBkaXNwbGF5OiBibG9jazsgbWFyZ2luLXRvcDogNXB4OyBjb2xvcjog'
                'I2I1YmFjMTsgZm9udC1zaXplOiAxMnB4OyBsaW5lLWhlaWdodDogMS40OyB9DQouZXEtZXhwb3J0LWJhZGdlIHsgcGFkZGluZzogMnB4IDZweDsgYm9yZGVy'
                'LXJhZGl1czogNHB4OyBiYWNrZ3JvdW5kOiAjMjQ4MDQ2OyBjb2xvcjogI2ZmZjsgZm9udC1zaXplOiAxMHB4OyBmb250LXdlaWdodDogNzAwOyB9DQouZXEt'
                'ZXhwb3J0LW9wdGlvbnMgeyBkaXNwbGF5OiBncmlkOyBncmlkLXRlbXBsYXRlLWNvbHVtbnM6IHJlcGVhdCgyLCBtaW5tYXgoMCwgMWZyKSk7IGdhcDogOHB4'
                'IDE0cHg7IG1hcmdpbi10b3A6IDEycHg7IHBhZGRpbmc6IDExcHggMTJweDsgYm9yZGVyOiAxcHggc29saWQgIzNmNDE0NzsgYm9yZGVyLXJhZGl1czogN3B4'
                'OyBiYWNrZ3JvdW5kOiAjMmIyZDMxOyB9DQouZXEtZXhwb3J0LW9wdGlvbiB7IGRpc3BsYXk6IGZsZXg7IGFsaWduLWl0ZW1zOiBjZW50ZXI7IGdhcDogOHB4'
                'OyBtaW4taGVpZ2h0OiAyOHB4OyBjb2xvcjogI2RiZGVlMTsgZm9udC1zaXplOiAxM3B4OyBjdXJzb3I6IHBvaW50ZXI7IH0NCi5lcS1leHBvcnQtb3B0aW9u'
                'IGlucHV0IHsgd2lkdGg6IDE2cHg7IGhlaWdodDogMTZweDsgYWNjZW50LWNvbG9yOiAjNTg2NWYyOyB9DQouZXEtZXhwb3J0LXN1bW1hcnksIC5lcS1leHBv'
                'cnQtcHJvZ3Jlc3MgeyBtYXJnaW4tdG9wOiAxMnB4OyBwYWRkaW5nOiAxMXB4IDEycHg7IGJvcmRlcjogMXB4IHNvbGlkICMzZjQxNDc7IGJvcmRlci1yYWRp'
                'dXM6IDdweDsgYmFja2dyb3VuZDogIzIzMjQyODsgfQ0KLmVxLWV4cG9ydC1zdW1tYXJ5LWdyaWQgeyBkaXNwbGF5OiBncmlkOyBncmlkLXRlbXBsYXRlLWNv'
                'bHVtbnM6IHJlcGVhdCgzLCAxZnIpOyBnYXA6IDhweDsgbWFyZ2luLXRvcDogN3B4OyB9DQouZXEtZXhwb3J0LW1ldHJpYyB7IGNvbG9yOiAjYjViYWMxOyBm'
                'b250LXNpemU6IDExcHg7IH0NCi5lcS1leHBvcnQtbWV0cmljIHN0cm9uZyB7IGRpc3BsYXk6IGJsb2NrOyBtYXJnaW4tdG9wOiAycHg7IGNvbG9yOiAjZjJm'
                'M2Y1OyBmb250LXNpemU6IDE0cHg7IH0NCi5lcS1leHBvcnQtcHJvZ3Jlc3MtbGluZSB7IGRpc3BsYXk6IGZsZXg7IGp1c3RpZnktY29udGVudDogc3BhY2Ut'
                'YmV0d2VlbjsgZ2FwOiAxMHB4OyBjb2xvcjogI2I1YmFjMTsgZm9udC1zaXplOiAxMnB4OyB9DQouZXEtZXhwb3J0LWJhciB7IGhlaWdodDogNXB4OyBtYXJn'
                'aW4tdG9wOiA5cHg7IG92ZXJmbG93OiBoaWRkZW47IGJvcmRlci1yYWRpdXM6IDNweDsgYmFja2dyb3VuZDogIzNmNDE0NzsgfQ0KLmVxLWV4cG9ydC1iYXIg'
                'PiBzcGFuIHsgZGlzcGxheTogYmxvY2s7IGhlaWdodDogMTAwJTsgYmFja2dyb3VuZDogIzU4NjVmMjsgdHJhbnNpdGlvbjogd2lkdGggLjE1cyBlYXNlOyB9'
                'DQouZXEtZXhwb3J0LW5vdGUsIC5lcS1leHBvcnQtc3RhdHVzIHsgbWFyZ2luLXRvcDogMTBweDsgY29sb3I6ICNiNWJhYzE7IGZvbnQtc2l6ZTogMTJweDsg'
                'bGluZS1oZWlnaHQ6IDEuNDsgfQ0KLmVxLWV4cG9ydC13YXJuaW5nIHsgY29sb3I6ICNmMGIyMzI7IH0NCi5lcS1leHBvcnQtYWN0aW9ucyB7IGRpc3BsYXk6'
                'IGZsZXg7IGdhcDogOXB4OyBtYXJnaW4tdG9wOiAxNHB4OyB9DQouZXEtZXhwb3J0LWJ1dHRvbiB7IGFwcGVhcmFuY2U6IG5vbmU7IG1pbi1oZWlnaHQ6IDM4'
                'cHg7IHBhZGRpbmc6IDAgMTVweDsgYm9yZGVyOiAxcHggc29saWQgdHJhbnNwYXJlbnQ7IGJvcmRlci1yYWRpdXM6IDZweDsgY29sb3I6ICNmZmY7IGZvbnQt'
                'd2VpZ2h0OiA3MDA7IGN1cnNvcjogcG9pbnRlcjsgfQ0KLmVxLWV4cG9ydC1idXR0b24tLXByaW1hcnkgeyBmbGV4OiAxOyBiYWNrZ3JvdW5kOiAjNTg2NWYy'
                'OyBib3JkZXItY29sb3I6ICM3Mjg5ZGE7IH0NCi5lcS1leHBvcnQtYnV0dG9uLS1wcmltYXJ5OmhvdmVyOm5vdCg6ZGlzYWJsZWQpIHsgYmFja2dyb3VuZDog'
                'IzQ3NTJjNDsgfQ0KLmVxLWV4cG9ydC1idXR0b24tLWNhbmNlbCB7IGJhY2tncm91bmQ6ICM0ZTUwNTg7IGJvcmRlci1jb2xvcjogIzZkNmY3ODsgfQ0KLmVx'
                'LWV4cG9ydC1idXR0b246ZGlzYWJsZWQgeyBjdXJzb3I6IG5vdC1hbGxvd2VkOyBvcGFjaXR5OiAuNTg7IH0NCkBtZWRpYSAobWF4LXdpZHRoOiA1NDBweCkg'
                'ew0KICAgIC5lcS1leHBvcnQtZm9ybWF0LWdyaWQsIC5lcS1leHBvcnQtb3B0aW9ucyB7IGdyaWQtdGVtcGxhdGUtY29sdW1uczogMWZyOyB9DQogICAgLmVx'
                'LWV4cG9ydC1zdW1tYXJ5LWdyaWQgeyBncmlkLXRlbXBsYXRlLWNvbHVtbnM6IDFmciAxZnI7IH0NCn0NCmA7DQoNCmZ1bmN0aW9uIGFib3J0RXJyb3IoKTog'
                'RE9NRXhjZXB0aW9uIHsNCiAgICByZXR1cm4gbmV3IERPTUV4Y2VwdGlvbigiRXhwb3J0IGNhbmNlbGxlZC4iLCAiQWJvcnRFcnJvciIpOw0KfQ0KDQpmdW5j'
                'dGlvbiB0aHJvd0lmQWJvcnRlZChzaWduYWw6IEFib3J0U2lnbmFsKSB7DQogICAgaWYgKHNpZ25hbC5hYm9ydGVkKSB0aHJvdyBhYm9ydEVycm9yKCk7DQp9'
                'DQoNCmZ1bmN0aW9uIGlzQWJvcnRFcnJvcihlcnJvcjogdW5rbm93bik6IGJvb2xlYW4gew0KICAgIHJldHVybiBlcnJvciBpbnN0YW5jZW9mIERPTUV4Y2Vw'
                'dGlvbiAmJiBlcnJvci5uYW1lID09PSAiQWJvcnRFcnJvciI7DQp9DQoNCmZ1bmN0aW9uIGRlbGF5KG1zOiBudW1iZXIsIHNpZ25hbDogQWJvcnRTaWduYWwp'
                'OiBQcm9taXNlPHZvaWQ+IHsNCiAgICByZXR1cm4gbmV3IFByb21pc2UoKHJlc29sdmUsIHJlamVjdCkgPT4gew0KICAgICAgICBjb25zdCB0aW1lciA9IHdp'
                'bmRvdy5zZXRUaW1lb3V0KCgpID0+IHsNCiAgICAgICAgICAgIHNpZ25hbC5yZW1vdmVFdmVudExpc3RlbmVyKCJhYm9ydCIsIG9uQWJvcnQpOw0KICAgICAg'
                'ICAgICAgcmVzb2x2ZSgpOw0KICAgICAgICB9LCBtcyk7DQogICAgICAgIGNvbnN0IG9uQWJvcnQgPSAoKSA9PiB7DQogICAgICAgICAgICB3aW5kb3cuY2xl'
                'YXJUaW1lb3V0KHRpbWVyKTsNCiAgICAgICAgICAgIHJlamVjdChhYm9ydEVycm9yKCkpOw0KICAgICAgICB9Ow0KICAgICAgICBzaWduYWwuYWRkRXZlbnRM'
                'aXN0ZW5lcigiYWJvcnQiLCBvbkFib3J0LCB7IG9uY2U6IHRydWUgfSk7DQogICAgfSk7DQp9DQoNCmFzeW5jIGZ1bmN0aW9uIGZldGNoQWxsTWVzc2FnZXMo'
                'Y2hhbm5lbElkOiBzdHJpbmcsIHNpZ25hbDogQWJvcnRTaWduYWwsIG9uUHJvZ3Jlc3M6IChjb3VudDogbnVtYmVyKSA9PiB2b2lkKSB7DQogICAgY29uc3Qg'
                'bWVzc2FnZXM6IGFueVtdID0gW107DQogICAgbGV0IGJlZm9yZUlkOiBzdHJpbmcgfCBudWxsID0gbnVsbDsNCg0KICAgIHdoaWxlICh0cnVlKSB7DQogICAg'
                'ICAgIHRocm93SWZBYm9ydGVkKHNpZ25hbCk7DQogICAgICAgIGNvbnN0IHF1ZXJ5OiBSZWNvcmQ8c3RyaW5nLCBzdHJpbmcgfCBudW1iZXI+ID0geyBsaW1p'
                'dDogMTAwIH07DQogICAgICAgIGlmIChiZWZvcmVJZCkgcXVlcnkuYmVmb3JlID0gYmVmb3JlSWQ7DQogICAgICAgIGNvbnN0IHJlc3BvbnNlID0gYXdhaXQg'
                'UmVzdEFQSS5nZXQoeyB1cmw6IENvbnN0YW50cy5FbmRwb2ludHMuTUVTU0FHRVMoY2hhbm5lbElkKSwgcXVlcnkgfSk7DQogICAgICAgIHRocm93SWZBYm9y'
                'dGVkKHNpZ25hbCk7DQogICAgICAgIGNvbnN0IHN0YXR1cyA9IE51bWJlcihyZXNwb25zZT8uc3RhdHVzID8/IDIwMCk7DQogICAgICAgIGlmIChyZXNwb25z'
                'ZT8ub2sgPT09IGZhbHNlIHx8IHN0YXR1cyA+PSA0MDApIHRocm93IG5ldyBFcnJvcihgRGlzY29yZCByZXR1cm5lZCAke3N0YXR1c30uYCk7DQoNCiAgICAg'
                'ICAgY29uc3QgYmF0Y2g6IGFueVtdID0gQXJyYXkuaXNBcnJheShyZXNwb25zZS5ib2R5KSA/IHJlc3BvbnNlLmJvZHkgOiBbXTsNCiAgICAgICAgaWYgKCFi'
                'YXRjaC5sZW5ndGgpIGJyZWFrOw0KICAgICAgICBtZXNzYWdlcy5wdXNoKC4uLmJhdGNoKTsNCiAgICAgICAgb25Qcm9ncmVzcyhtZXNzYWdlcy5sZW5ndGgp'
                'Ow0KICAgICAgICBpZiAoYmF0Y2gubGVuZ3RoIDwgMTAwKSBicmVhazsNCiAgICAgICAgYmVmb3JlSWQgPSBiYXRjaFtiYXRjaC5sZW5ndGggLSAxXS5pZDsN'
                'CiAgICAgICAgYXdhaXQgZGVsYXkoMjUwLCBzaWduYWwpOw0KICAgIH0NCg0KICAgIHJldHVybiBtZXNzYWdlcy5yZXZlcnNlKCk7DQp9DQoNCmNvbnN0IEhU'
                'TUxfRVNDQVBFX01BUDogUmVjb3JkPHN0cmluZywgc3RyaW5nPiA9IHsNCiAgICAiJiI6ICImYW1wOyIsDQogICAgIjwiOiAiJmx0OyIsDQogICAgIj4iOiAi'
                'Jmd0OyIsDQogICAgJyInOiAiJnF1b3Q7IiwNCiAgICAiJyI6ICImIzM5OyINCn07DQoNCmZ1bmN0aW9uIGVzY2FwZUh0bWwodmFsdWU6IHVua25vd24pOiBz'
                'dHJpbmcgew0KICAgIHJldHVybiBTdHJpbmcodmFsdWUgPz8gIiIpLnJlcGxhY2UoL1smPD4iJ10vZywgY2hhcmFjdGVyID0+IEhUTUxfRVNDQVBFX01BUFtj'
                'aGFyYWN0ZXJdID8/IGNoYXJhY3Rlcik7DQp9DQoNCmZ1bmN0aW9uIHNhZmVFeHRlcm5hbFVybCh2YWx1ZTogdW5rbm93bik6IHN0cmluZyB7DQogICAgdHJ5'
                'IHsNCiAgICAgICAgY29uc3QgdXJsID0gbmV3IFVSTChTdHJpbmcodmFsdWUgPz8gIiIpKTsNCiAgICAgICAgcmV0dXJuIHVybC5wcm90b2NvbCA9PT0gImh0'
                'dHBzOiIgfHwgdXJsLnByb3RvY29sID09PSAiaHR0cDoiID8gdXJsLmhyZWYgOiAiIjsNCiAgICB9IGNhdGNoIHsNCiAgICAgICAgcmV0dXJuICIiOw0KICAg'
                'IH0NCn0NCg0KZnVuY3Rpb24gZm9ybWF0Qnl0ZXModmFsdWU6IHVua25vd24pOiBzdHJpbmcgew0KICAgIGNvbnN0IGJ5dGVzID0gTnVtYmVyKHZhbHVlKTsN'
                'CiAgICBpZiAoIU51bWJlci5pc0Zpbml0ZShieXRlcykgfHwgYnl0ZXMgPCAwKSByZXR1cm4gIlVua25vd24iOw0KICAgIGNvbnN0IHVuaXRzID0gWyJCIiwg'
                'IktCIiwgIk1CIiwgIkdCIl07DQogICAgbGV0IHNpemUgPSBieXRlczsNCiAgICBsZXQgaW5kZXggPSAwOw0KICAgIHdoaWxlIChzaXplID49IDEwMjQgJiYg'
                'aW5kZXggPCB1bml0cy5sZW5ndGggLSAxKSB7DQogICAgICAgIHNpemUgLz0gMTAyNDsNCiAgICAgICAgaW5kZXgrKzsNCiAgICB9DQogICAgcmV0dXJuIGAk'
                'e3NpemUgPj0gMTAgfHwgaW5kZXggPT09IDAgPyBzaXplLnRvRml4ZWQoMCkgOiBzaXplLnRvRml4ZWQoMSl9ICR7dW5pdHNbaW5kZXhdfWA7DQp9DQoNCmZ1'
                'bmN0aW9uIG1lZGlhS2luZChpdGVtOiBhbnkpOiBNZWRpYUtpbmQgew0KICAgIGNvbnN0IGNvbnRlbnRUeXBlID0gU3RyaW5nKGl0ZW0/LmNvbnRlbnRfdHlw'
                'ZSA/PyBpdGVtPy5jb250ZW50VHlwZSA/PyAiIikudG9Mb3dlckNhc2UoKTsNCiAgICBjb25zdCBuYW1lID0gU3RyaW5nKGl0ZW0/LmZpbGVuYW1lID8/IGl0'
                'ZW0/Lm5hbWUgPz8gaXRlbT8udXJsID8/ICIiKS50b0xvd2VyQ2FzZSgpOw0KICAgIGlmIChjb250ZW50VHlwZS5zdGFydHNXaXRoKCJpbWFnZS8iKSB8fCAv'
                'XC4oPzphcG5nfGF2aWZ8Ym1wfGdpZnxqcGU/Z3xwbmd8c3ZnfHdlYnApKD86JHxbPyNdKS8udGVzdChuYW1lKSkgcmV0dXJuICJpbWFnZSI7DQogICAgaWYg'
                'KGNvbnRlbnRUeXBlLnN0YXJ0c1dpdGgoInZpZGVvLyIpIHx8IC9cLig/Om00dnxtb3Z8bXA0fG9ndnx3ZWJtKSg/OiR8Wz8jXSkvLnRlc3QobmFtZSkpIHJl'
                'dHVybiAidmlkZW8iOw0KICAgIGlmIChjb250ZW50VHlwZS5zdGFydHNXaXRoKCJhdWRpby8iKSB8fCAvXC4oPzphYWN8ZmxhY3xtNGF8bXAzfG9nYXxvZ2d8'
                'b3B1c3x3YXZ8d2ViYSkoPzokfFs/I10pLy50ZXN0KG5hbWUpKSByZXR1cm4gImF1ZGlvIjsNCiAgICByZXR1cm4gImZpbGUiOw0KfQ0KDQpmdW5jdGlvbiBz'
                'YW5pdGl6ZUZpbGVuYW1lUGFydCh2YWx1ZTogdW5rbm93biwgZmFsbGJhY2sgPSAiYXNzZXQiKTogc3RyaW5nIHsNCiAgICBjb25zdCBjbGVhbmVkID0gU3Ry'
                'aW5nKHZhbHVlID8/ICIiKQ0KICAgICAgICAubm9ybWFsaXplKCJORktDIikNCiAgICAgICAgLnJlcGxhY2UoL1s8PjoiL1xcfD8qXHUwMDAwLVx1MDAxZl0v'
                'ZywgIl8iKQ0KICAgICAgICAucmVwbGFjZSgvXC5cLisvZywgIi4iKQ0KICAgICAgICAucmVwbGFjZSgvXHMrL2csICIgIikNCiAgICAgICAgLnJlcGxhY2Uo'
                'L15bLiBdK3xbLiBdKyQvZywgIiIpDQogICAgICAgIC5zbGljZSgwLCA5Nik7DQogICAgcmV0dXJuIGNsZWFuZWQgfHwgZmFsbGJhY2s7DQp9DQoNCmZ1bmN0'
                'aW9uIHNhZmVGaWxlbmFtZSh2YWx1ZTogc3RyaW5nKTogc3RyaW5nIHsNCiAgICByZXR1cm4gc2FuaXRpemVGaWxlbmFtZVBhcnQodmFsdWUsICJkaXNjb3Jk'
                'LWV4cG9ydCIpOw0KfQ0KDQpmdW5jdGlvbiBleHRlbnNpb25Gcm9tKHZhbHVlOiB1bmtub3duLCBraW5kOiBNZWRpYUtpbmQpOiBzdHJpbmcgew0KICAgIGNv'
                'bnN0IHBsYWluID0gU3RyaW5nKHZhbHVlID8/ICIiKS5zcGxpdCgvWz8jXS8sIDEpWzBdOw0KICAgIGNvbnN0IG1hdGNoID0gcGxhaW4ubWF0Y2goL1wuKFtB'
                'LVphLXowLTldezEsOH0pJC8pOw0KICAgIGlmIChtYXRjaCkgcmV0dXJuIGAuJHttYXRjaFsxXS50b0xvd2VyQ2FzZSgpfWA7DQogICAgaWYgKGtpbmQgPT09'
                'ICJpbWFnZSIpIHJldHVybiAiLndlYnAiOw0KICAgIGlmIChraW5kID09PSAidmlkZW8iKSByZXR1cm4gIi5tcDQiOw0KICAgIGlmIChraW5kID09PSAiYXVk'
                'aW8iKSByZXR1cm4gIi5vZ2ciOw0KICAgIHJldHVybiAiLmJpbiI7DQp9DQoNCmZ1bmN0aW9uIHVuaXF1ZUFzc2V0UGF0aChjYXRlZ29yeTogQXNzZXRDYXRl'
                'Z29yeSwgaWQ6IHN0cmluZywgb3JpZ2luYWxOYW1lOiBzdHJpbmcsIGtpbmQ6IE1lZGlhS2luZCwgdXNlZDogU2V0PHN0cmluZz4pOiBzdHJpbmcgew0KICAg'
                'IGNvbnN0IHNhZmVJZCA9IHNhbml0aXplRmlsZW5hbWVQYXJ0KGlkLCAiYXNzZXQiKTsNCiAgICBsZXQgc2FmZU5hbWUgPSBzYW5pdGl6ZUZpbGVuYW1lUGFy'
                'dChvcmlnaW5hbE5hbWUsICJhc3NldCIpOw0KICAgIGlmICghL1wuW0EtWmEtejAtOV17MSw4fSQvLnRlc3Qoc2FmZU5hbWUpKSBzYWZlTmFtZSArPSBleHRl'
                'bnNpb25Gcm9tKG9yaWdpbmFsTmFtZSwga2luZCk7DQogICAgY29uc3QgZG90ID0gc2FmZU5hbWUubGFzdEluZGV4T2YoIi4iKTsNCiAgICBjb25zdCBzdGVt'
                'ID0gZG90ID4gMCA/IHNhZmVOYW1lLnNsaWNlKDAsIGRvdCkgOiBzYWZlTmFtZTsNCiAgICBjb25zdCBleHRlbnNpb24gPSBkb3QgPiAwID8gc2FmZU5hbWUu'
                'c2xpY2UoZG90KS50b0xvd2VyQ2FzZSgpIDogZXh0ZW5zaW9uRnJvbShvcmlnaW5hbE5hbWUsIGtpbmQpOw0KICAgIGxldCBwYXRoID0gYGFzc2V0cy8ke2Nh'
                'dGVnb3J5fS8ke3NhZmVJZH0tJHtzdGVtfSR7ZXh0ZW5zaW9ufWA7DQogICAgbGV0IHN1ZmZpeCA9IDI7DQogICAgd2hpbGUgKHVzZWQuaGFzKHBhdGgudG9M'
                'b3dlckNhc2UoKSkpIHBhdGggPSBgYXNzZXRzLyR7Y2F0ZWdvcnl9LyR7c2FmZUlkfS0ke3N0ZW19LSR7c3VmZml4Kyt9JHtleHRlbnNpb259YDsNCiAgICB1'
                'c2VkLmFkZChwYXRoLnRvTG93ZXJDYXNlKCkpOw0KICAgIHJldHVybiBwYXRoOw0KfQ0KDQpmdW5jdGlvbiBzdGlja2VySXRlbXMobWVzc2FnZTogYW55KTog'
                'YW55W10gew0KICAgIHJldHVybiBBcnJheS5pc0FycmF5KG1lc3NhZ2U/LnN0aWNrZXJfaXRlbXMpDQogICAgICAgID8gbWVzc2FnZS5zdGlja2VyX2l0ZW1z'
                'DQogICAgICAgIDogQXJyYXkuaXNBcnJheShtZXNzYWdlPy5zdGlja2VycykgPyBtZXNzYWdlLnN0aWNrZXJzIDogW107DQp9DQoNCmZ1bmN0aW9uIGNvbGxl'
                'Y3RBc3NldFJlcXVlc3RzKG1lc3NhZ2VzOiBhbnlbXSwgb3B0aW9uczogRXhwb3J0T3B0aW9ucyk6IEFzc2V0Q2F0YWxvZyB7DQogICAgY29uc3QgYWxpYXNl'
                'cyA9IG5ldyBNYXA8c3RyaW5nLCBBc3NldFJlcXVlc3Q+KCk7DQogICAgY29uc3QgYnlVcmwgPSBuZXcgTWFwPHN0cmluZywgQXNzZXRSZXF1ZXN0PigpOw0K'
                'ICAgIGNvbnN0IHJlcXVlc3RzOiBBc3NldFJlcXVlc3RbXSA9IFtdOw0KICAgIGNvbnN0IHVzZWRQYXRocyA9IG5ldyBTZXQ8c3RyaW5nPigpOw0KDQogICAg'
                'ZnVuY3Rpb24gYWRkKGFsaWFzOiBzdHJpbmcsIGNhdGVnb3J5OiBBc3NldENhdGVnb3J5LCBpZDogc3RyaW5nLCBvcmlnaW5hbE5hbWU6IHN0cmluZywgdXJs'
                'czogdW5rbm93bltdLCBraW5kOiBNZWRpYUtpbmQsIGV4cGVjdGVkU2l6ZSA9IDApIHsNCiAgICAgICAgY29uc3Qgc2FmZVVybHMgPSB1cmxzLm1hcChzYWZl'
                'RXh0ZXJuYWxVcmwpLmZpbHRlcihCb29sZWFuKTsNCiAgICAgICAgaWYgKCFzYWZlVXJscy5sZW5ndGgpIHJldHVybjsNCiAgICAgICAgY29uc3QgZGVkdXBl'
                'S2V5ID0gc2FmZVVybHNbMF07DQogICAgICAgIGxldCByZXF1ZXN0ID0gYnlVcmwuZ2V0KGRlZHVwZUtleSk7DQogICAgICAgIGlmICghcmVxdWVzdCkgew0K'
                'ICAgICAgICAgICAgcmVxdWVzdCA9IHsNCiAgICAgICAgICAgICAgICBhbGlhc2VzOiBbXSwNCiAgICAgICAgICAgICAgICBjYXRlZ29yeSwNCiAgICAgICAg'
                'ICAgICAgICBleHBlY3RlZFNpemU6IE51bWJlci5pc0Zpbml0ZShleHBlY3RlZFNpemUpICYmIGV4cGVjdGVkU2l6ZSA+IDAgPyBleHBlY3RlZFNpemUgOiAw'
                'LA0KICAgICAgICAgICAgICAgIGtpbmQsDQogICAgICAgICAgICAgICAgb3JpZ2luYWxVcmw6IHNhZmVVcmxzWzBdLA0KICAgICAgICAgICAgICAgIHBhdGg6'
                'IHVuaXF1ZUFzc2V0UGF0aChjYXRlZ29yeSwgaWQsIG9yaWdpbmFsTmFtZSwga2luZCwgdXNlZFBhdGhzKSwNCiAgICAgICAgICAgICAgICB1cmxzOiBBcnJh'
                'eS5mcm9tKG5ldyBTZXQoc2FmZVVybHMpKQ0KICAgICAgICAgICAgfTsNCiAgICAgICAgICAgIHJlcXVlc3RzLnB1c2gocmVxdWVzdCk7DQogICAgICAgICAg'
                'ICBieVVybC5zZXQoZGVkdXBlS2V5LCByZXF1ZXN0KTsNCiAgICAgICAgfQ0KICAgICAgICBpZiAoIWFsaWFzZXMuaGFzKGFsaWFzKSkgcmVxdWVzdC5hbGlh'
                'c2VzLnB1c2goYWxpYXMpOw0KICAgICAgICBhbGlhc2VzLnNldChhbGlhcywgcmVxdWVzdCk7DQogICAgfQ0KDQogICAgZm9yIChjb25zdCBtZXNzYWdlIG9m'
                'IG1lc3NhZ2VzKSB7DQogICAgICAgIGNvbnN0IG1lc3NhZ2VJZCA9IHNhbml0aXplRmlsZW5hbWVQYXJ0KG1lc3NhZ2U/LmlkLCAibWVzc2FnZSIpOw0KICAg'
                'ICAgICBjb25zdCBhdXRob3IgPSBtZXNzYWdlPy5hdXRob3I7DQogICAgICAgIGlmIChvcHRpb25zLmF2YXRhcnMgJiYgYXV0aG9yPy5pZCAmJiBhdXRob3I/'
                'LmF2YXRhcikgew0KICAgICAgICAgICAgY29uc3QgYW5pbWF0ZWQgPSBTdHJpbmcoYXV0aG9yLmF2YXRhcikuc3RhcnRzV2l0aCgiYV8iKTsNCiAgICAgICAg'
                'ICAgIGNvbnN0IGV4dGVuc2lvbiA9IGFuaW1hdGVkID8gImdpZiIgOiAid2VicCI7DQogICAgICAgICAgICBhZGQoDQogICAgICAgICAgICAgICAgYGF2YXRh'
                'cjoke2F1dGhvci5pZH06JHthdXRob3IuYXZhdGFyfWAsDQogICAgICAgICAgICAgICAgImF2YXRhcnMiLA0KICAgICAgICAgICAgICAgIGAke2F1dGhvci5p'
                'ZH0tJHthdXRob3IuYXZhdGFyfWAsDQogICAgICAgICAgICAgICAgYGF2YXRhci4ke2V4dGVuc2lvbn1gLA0KICAgICAgICAgICAgICAgIFtgaHR0cHM6Ly9j'
                'ZG4uZGlzY29yZGFwcC5jb20vYXZhdGFycy8ke2F1dGhvci5pZH0vJHthdXRob3IuYXZhdGFyfS4ke2V4dGVuc2lvbn0/c2l6ZT0xMjhgXSwNCiAgICAgICAg'
                'ICAgICAgICAiaW1hZ2UiDQogICAgICAgICAgICApOw0KICAgICAgICB9DQoNCiAgICAgICAgaWYgKG9wdGlvbnMuYXR0YWNobWVudHMpIHsNCiAgICAgICAg'
                'ICAgIGNvbnN0IGF0dGFjaG1lbnRzID0gQXJyYXkuaXNBcnJheShtZXNzYWdlPy5hdHRhY2htZW50cykgPyBtZXNzYWdlLmF0dGFjaG1lbnRzIDogW107DQog'
                'ICAgICAgICAgICBhdHRhY2htZW50cy5mb3JFYWNoKChhdHRhY2htZW50OiBhbnksIGluZGV4OiBudW1iZXIpID0+IHsNCiAgICAgICAgICAgICAgICBjb25z'
                'dCBpZCA9IFN0cmluZyhhdHRhY2htZW50Py5pZCA/PyBpbmRleCk7DQogICAgICAgICAgICAgICAgYWRkKA0KICAgICAgICAgICAgICAgICAgICBgYXR0YWNo'
                'bWVudDoke21lc3NhZ2U/LmlkfToke2lkfWAsDQogICAgICAgICAgICAgICAgICAgICJhdHRhY2htZW50cyIsDQogICAgICAgICAgICAgICAgICAgIGAke21l'
                'c3NhZ2VJZH0tJHtzYW5pdGl6ZUZpbGVuYW1lUGFydChpZCwgU3RyaW5nKGluZGV4KSl9YCwNCiAgICAgICAgICAgICAgICAgICAgU3RyaW5nKGF0dGFjaG1l'
                'bnQ/LmZpbGVuYW1lID8/IGBhdHRhY2htZW50LSR7aW5kZXh9YCksDQogICAgICAgICAgICAgICAgICAgIFthdHRhY2htZW50Py51cmwsIGF0dGFjaG1lbnQ/'
                'LnByb3h5X3VybF0sDQogICAgICAgICAgICAgICAgICAgIG1lZGlhS2luZChhdHRhY2htZW50KSwNCiAgICAgICAgICAgICAgICAgICAgTnVtYmVyKGF0dGFj'
                'aG1lbnQ/LnNpemUgPz8gMCkNCiAgICAgICAgICAgICAgICApOw0KICAgICAgICAgICAgfSk7DQogICAgICAgIH0NCg0KICAgICAgICBpZiAob3B0aW9ucy5l'
                'bW9qaXNTdGlja2Vycykgew0KICAgICAgICAgICAgY29uc3QgZW1vamlQYXR0ZXJuID0gLzwoYT8pOihbQS1aYS16MC05X10rKTooXGQrKT4vZzsNCiAgICAg'
                'ICAgICAgIGZvciAoY29uc3QgbWF0Y2ggb2YgU3RyaW5nKG1lc3NhZ2U/LmNvbnRlbnQgPz8gIiIpLm1hdGNoQWxsKGVtb2ppUGF0dGVybikpIHsNCiAgICAg'
                'ICAgICAgICAgICBjb25zdCBleHRlbnNpb24gPSBtYXRjaFsxXSA/ICJnaWYiIDogIndlYnAiOw0KICAgICAgICAgICAgICAgIGFkZCgNCiAgICAgICAgICAg'
                'ICAgICAgICAgYGVtb2ppOiR7bWF0Y2hbM119YCwNCiAgICAgICAgICAgICAgICAgICAgImVtb2ppcyIsDQogICAgICAgICAgICAgICAgICAgIG1hdGNoWzNd'
                'LA0KICAgICAgICAgICAgICAgICAgICBgJHttYXRjaFsyXX0uJHtleHRlbnNpb259YCwNCiAgICAgICAgICAgICAgICAgICAgW2BodHRwczovL2Nkbi5kaXNj'
                'b3JkYXBwLmNvbS9lbW9qaXMvJHttYXRjaFszXX0uJHtleHRlbnNpb259P3NpemU9OTYmcXVhbGl0eT1sb3NzbGVzc2BdLA0KICAgICAgICAgICAgICAgICAg'
                'ICAiaW1hZ2UiDQogICAgICAgICAgICAgICAgKTsNCiAgICAgICAgICAgIH0NCg0KICAgICAgICAgICAgc3RpY2tlckl0ZW1zKG1lc3NhZ2UpLmZvckVhY2go'
                'KHN0aWNrZXIsIGluZGV4KSA9PiB7DQogICAgICAgICAgICAgICAgY29uc3QgaWQgPSBTdHJpbmcoc3RpY2tlcj8uaWQgPz8gaW5kZXgpOw0KICAgICAgICAg'
                'ICAgICAgIGNvbnN0IGZvcm1hdCA9IE51bWJlcihzdGlja2VyPy5mb3JtYXRfdHlwZSA/PyBzdGlja2VyPy5mb3JtYXRUeXBlID8/IDEpOw0KICAgICAgICAg'
                'ICAgICAgIGlmIChmb3JtYXQgPT09IDMgfHwgIS9eXGQrJC8udGVzdChpZCkpIHJldHVybjsNCiAgICAgICAgICAgICAgICBjb25zdCBleHRlbnNpb24gPSBm'
                'b3JtYXQgPT09IDQgPyAiZ2lmIiA6ICJwbmciOw0KICAgICAgICAgICAgICAgIGFkZCgNCiAgICAgICAgICAgICAgICAgICAgYHN0aWNrZXI6JHtpZH1gLA0K'
                'ICAgICAgICAgICAgICAgICAgICAic3RpY2tlcnMiLA0KICAgICAgICAgICAgICAgICAgICBpZCwNCiAgICAgICAgICAgICAgICAgICAgYCR7c3RpY2tlcj8u'
                'bmFtZSA/PyAic3RpY2tlciJ9LiR7ZXh0ZW5zaW9ufWAsDQogICAgICAgICAgICAgICAgICAgIFtgaHR0cHM6Ly9tZWRpYS5kaXNjb3JkYXBwLm5ldC9zdGlj'
                'a2Vycy8ke2lkfS4ke2V4dGVuc2lvbn0/c2l6ZT0zMjAmcXVhbGl0eT1sb3NzbGVzc2BdLA0KICAgICAgICAgICAgICAgICAgICAiaW1hZ2UiDQogICAgICAg'
                'ICAgICAgICAgKTsNCiAgICAgICAgICAgIH0pOw0KICAgICAgICB9DQoNCiAgICAgICAgaWYgKG9wdGlvbnMuZW1iZWRNZWRpYSkgew0KICAgICAgICAgICAg'
                'Y29uc3QgYXR0YWNobWVudFVybHMgPSBuZXcgU2V0PHN0cmluZz4oKTsNCiAgICAgICAgICAgIGZvciAoY29uc3QgYXR0YWNobWVudCBvZiBBcnJheS5pc0Fy'
                'cmF5KG1lc3NhZ2U/LmF0dGFjaG1lbnRzKSA/IG1lc3NhZ2UuYXR0YWNobWVudHMgOiBbXSkgew0KICAgICAgICAgICAgICAgIGNvbnN0IHVybCA9IHNhZmVF'
                'eHRlcm5hbFVybChhdHRhY2htZW50Py51cmwpOw0KICAgICAgICAgICAgICAgIGNvbnN0IHByb3h5ID0gc2FmZUV4dGVybmFsVXJsKGF0dGFjaG1lbnQ/LnBy'
                'b3h5X3VybCk7DQogICAgICAgICAgICAgICAgaWYgKHVybCkgYXR0YWNobWVudFVybHMuYWRkKHVybCk7DQogICAgICAgICAgICAgICAgaWYgKHByb3h5KSBh'
                'dHRhY2htZW50VXJscy5hZGQocHJveHkpOw0KICAgICAgICAgICAgfQ0KICAgICAgICAgICAgY29uc3QgZW1iZWRzID0gQXJyYXkuaXNBcnJheShtZXNzYWdl'
                'Py5lbWJlZHMpID8gbWVzc2FnZS5lbWJlZHMgOiBbXTsNCiAgICAgICAgICAgIGVtYmVkcy5mb3JFYWNoKChlbWJlZDogYW55LCBpbmRleDogbnVtYmVyKSA9'
                'PiB7DQogICAgICAgICAgICAgICAgY29uc3QgaW1hZ2VVcmwgPSBzYWZlRXh0ZXJuYWxVcmwoZW1iZWQ/LmltYWdlPy5wcm94eV91cmwgPz8gZW1iZWQ/Lmlt'
                'YWdlPy51cmwpOw0KICAgICAgICAgICAgICAgIGNvbnN0IHRodW1ibmFpbFVybCA9IHNhZmVFeHRlcm5hbFVybChlbWJlZD8udGh1bWJuYWlsPy5wcm94eV91'
                'cmwgPz8gZW1iZWQ/LnRodW1ibmFpbD8udXJsKTsNCiAgICAgICAgICAgICAgICBjb25zdCBwcm94eVZpZGVvVXJsID0gc2FmZUV4dGVybmFsVXJsKGVtYmVk'
                'Py52aWRlbz8ucHJveHlfdXJsKTsNCiAgICAgICAgICAgICAgICBjb25zdCB2aWRlb1VybCA9IHByb3h5VmlkZW9VcmwgfHwgc2FmZUV4dGVybmFsVXJsKGVt'
                'YmVkPy52aWRlbz8udXJsKTsNCiAgICAgICAgICAgICAgICBpZiAoaW1hZ2VVcmwgJiYgIWF0dGFjaG1lbnRVcmxzLmhhcyhpbWFnZVVybCkpIHsNCiAgICAg'
                'ICAgICAgICAgICAgICAgYWRkKGBlbWJlZDoke21lc3NhZ2U/LmlkfToke2luZGV4fTppbWFnZWAsICJlbWJlZHMiLCBgJHttZXNzYWdlSWR9LSR7aW5kZXh9'
                'LWltYWdlYCwgImVtYmVkLWltYWdlIiwgW2ltYWdlVXJsLCBlbWJlZD8uaW1hZ2U/LnVybF0sICJpbWFnZSIpOw0KICAgICAgICAgICAgICAgIH0NCiAgICAg'
                'ICAgICAgICAgICBpZiAodGh1bWJuYWlsVXJsICYmICFhdHRhY2htZW50VXJscy5oYXModGh1bWJuYWlsVXJsKSkgew0KICAgICAgICAgICAgICAgICAgICBh'
                'ZGQoYGVtYmVkOiR7bWVzc2FnZT8uaWR9OiR7aW5kZXh9OnRodW1ibmFpbGAsICJlbWJlZHMiLCBgJHttZXNzYWdlSWR9LSR7aW5kZXh9LXRodW1ibmFpbGAs'
                'ICJlbWJlZC10aHVtYm5haWwiLCBbdGh1bWJuYWlsVXJsLCBlbWJlZD8udGh1bWJuYWlsPy51cmxdLCAiaW1hZ2UiKTsNCiAgICAgICAgICAgICAgICB9DQog'
                'ICAgICAgICAgICAgICAgaWYgKHZpZGVvVXJsICYmICFhdHRhY2htZW50VXJscy5oYXModmlkZW9VcmwpICYmIChwcm94eVZpZGVvVXJsIHx8IG1lZGlhS2lu'
                'ZCh7IHVybDogdmlkZW9VcmwgfSkgPT09ICJ2aWRlbyIpKSB7DQogICAgICAgICAgICAgICAgICAgIGFkZChgZW1iZWQ6JHttZXNzYWdlPy5pZH06JHtpbmRl'
                'eH06dmlkZW9gLCAiZW1iZWRzIiwgYCR7bWVzc2FnZUlkfS0ke2luZGV4fS12aWRlb2AsICJlbWJlZC12aWRlbyIsIFt2aWRlb1VybCwgZW1iZWQ/LnZpZGVv'
                'Py51cmxdLCAidmlkZW8iKTsNCiAgICAgICAgICAgICAgICB9DQogICAgICAgICAgICB9KTsNCiAgICAgICAgfQ0KICAgIH0NCg0KICAgIHJldHVybiB7IGFs'
                'aWFzZXMsIHJlcXVlc3RzIH07DQp9DQoNCmZ1bmN0aW9uIGNvbnRlbnRUeXBlTWF0Y2hlcyhraW5kOiBNZWRpYUtpbmQsIGNvbnRlbnRUeXBlOiBzdHJpbmcs'
                'IHVybDogc3RyaW5nKTogYm9vbGVhbiB7DQogICAgY29uc3QgdHlwZSA9IGNvbnRlbnRUeXBlLnRvTG93ZXJDYXNlKCkuc3BsaXQoIjsiLCAxKVswXS50cmlt'
                'KCk7DQogICAgaWYgKHR5cGUgPT09ICJ0ZXh0L2h0bWwiIHx8IHR5cGUgPT09ICJhcHBsaWNhdGlvbi94aHRtbCt4bWwiKSByZXR1cm4gZmFsc2U7DQogICAg'
                'aWYgKCF0eXBlIHx8IHR5cGUgPT09ICJhcHBsaWNhdGlvbi9vY3RldC1zdHJlYW0iKSByZXR1cm4gdHJ1ZTsNCiAgICBpZiAoa2luZCA9PT0gImZpbGUiKSBy'
                'ZXR1cm4gdHJ1ZTsNCiAgICBpZiAoa2luZCA9PT0gImltYWdlIikgcmV0dXJuIHR5cGUuc3RhcnRzV2l0aCgiaW1hZ2UvIik7DQogICAgaWYgKGtpbmQgPT09'
                'ICJ2aWRlbyIpIHJldHVybiB0eXBlLnN0YXJ0c1dpdGgoInZpZGVvLyIpIHx8IG1lZGlhS2luZCh7IHVybCB9KSA9PT0gInZpZGVvIjsNCiAgICByZXR1cm4g'
                'dHlwZS5zdGFydHNXaXRoKCJhdWRpby8iKSB8fCBtZWRpYUtpbmQoeyB1cmwgfSkgPT09ICJhdWRpbyI7DQp9DQoNCmFzeW5jIGZ1bmN0aW9uIGZldGNoQXNz'
                'ZXQocmVxdWVzdDogQXNzZXRSZXF1ZXN0LCBzaWduYWw6IEFib3J0U2lnbmFsLCBmZXRjaGVyOiB0eXBlb2YgZmV0Y2gpOiBQcm9taXNlPEFzc2V0UmVzdWx0'
                'PiB7DQogICAgbGV0IGZpbmFsRXJyb3IgPSAiTm8gdXNhYmxlIFVSTCB3YXMgYXZhaWxhYmxlLiI7DQogICAgZm9yIChjb25zdCB1cmwgb2YgcmVxdWVzdC51'
                'cmxzKSB7DQogICAgICAgIGZvciAobGV0IGF0dGVtcHQgPSAwOyBhdHRlbXB0IDwgQVNTRVRfUkVUUklFUzsgYXR0ZW1wdCsrKSB7DQogICAgICAgICAgICB0'
                'aHJvd0lmQWJvcnRlZChzaWduYWwpOw0KICAgICAgICAgICAgY29uc3QgdGltZW91dENvbnRyb2xsZXIgPSBuZXcgQWJvcnRDb250cm9sbGVyKCk7DQogICAg'
                'ICAgICAgICBjb25zdCBvbkFib3J0ID0gKCkgPT4gdGltZW91dENvbnRyb2xsZXIuYWJvcnQoKTsNCiAgICAgICAgICAgIHNpZ25hbC5hZGRFdmVudExpc3Rl'
                'bmVyKCJhYm9ydCIsIG9uQWJvcnQsIHsgb25jZTogdHJ1ZSB9KTsNCiAgICAgICAgICAgIGNvbnN0IHRpbWVvdXQgPSB3aW5kb3cuc2V0VGltZW91dCgoKSA9'
                'PiB0aW1lb3V0Q29udHJvbGxlci5hYm9ydCgpLCBBU1NFVF9USU1FT1VUX01TKTsNCiAgICAgICAgICAgIHRyeSB7DQogICAgICAgICAgICAgICAgY29uc3Qg'
                'cmVzcG9uc2UgPSBhd2FpdCBmZXRjaGVyKHVybCwgeyBjcmVkZW50aWFsczogIm9taXQiLCBzaWduYWw6IHRpbWVvdXRDb250cm9sbGVyLnNpZ25hbCB9KTsN'
                'CiAgICAgICAgICAgICAgICBpZiAoIXJlc3BvbnNlLm9rKSB0aHJvdyBuZXcgRXJyb3IoYEhUVFAgJHtyZXNwb25zZS5zdGF0dXN9YCk7DQogICAgICAgICAg'
                'ICAgICAgY29uc3QgY29udGVudFR5cGUgPSByZXNwb25zZS5oZWFkZXJzLmdldCgiY29udGVudC10eXBlIikgPz8gImFwcGxpY2F0aW9uL29jdGV0LXN0cmVh'
                'bSI7DQogICAgICAgICAgICAgICAgaWYgKCFjb250ZW50VHlwZU1hdGNoZXMocmVxdWVzdC5raW5kLCBjb250ZW50VHlwZSwgdXJsKSkgdGhyb3cgbmV3IEVy'
                'cm9yKGB1bmV4cGVjdGVkIGNvbnRlbnQgdHlwZSAke2NvbnRlbnRUeXBlfWApOw0KICAgICAgICAgICAgICAgIGNvbnN0IGJ5dGVzID0gbmV3IFVpbnQ4QXJy'
                'YXkoYXdhaXQgcmVzcG9uc2UuYXJyYXlCdWZmZXIoKSk7DQogICAgICAgICAgICAgICAgaWYgKCFieXRlcy5ieXRlTGVuZ3RoKSB0aHJvdyBuZXcgRXJyb3Io'
                'ImVtcHR5IHJlc3BvbnNlIik7DQogICAgICAgICAgICAgICAgcmV0dXJuIHsgYnl0ZXMsIGNvbnRlbnRUeXBlLCBraW5kOiByZXF1ZXN0LmtpbmQsIG9yaWdp'
                'bmFsVXJsOiByZXF1ZXN0Lm9yaWdpbmFsVXJsLCBwYXRoOiByZXF1ZXN0LnBhdGggfTsNCiAgICAgICAgICAgIH0gY2F0Y2ggKGVycm9yKSB7DQogICAgICAg'
                'ICAgICAgICAgaWYgKHNpZ25hbC5hYm9ydGVkKSB0aHJvdyBhYm9ydEVycm9yKCk7DQogICAgICAgICAgICAgICAgZmluYWxFcnJvciA9IGVycm9yIGluc3Rh'
                'bmNlb2YgRXJyb3IgPyBlcnJvci5tZXNzYWdlIDogU3RyaW5nKGVycm9yKTsNCiAgICAgICAgICAgICAgICBpZiAoYXR0ZW1wdCA8IEFTU0VUX1JFVFJJRVMg'
                'LSAxKSBhd2FpdCBkZWxheSgzNTAgKiAyICoqIGF0dGVtcHQsIHNpZ25hbCk7DQogICAgICAgICAgICB9IGZpbmFsbHkgew0KICAgICAgICAgICAgICAgIHdp'
                'bmRvdy5jbGVhclRpbWVvdXQodGltZW91dCk7DQogICAgICAgICAgICAgICAgc2lnbmFsLnJlbW92ZUV2ZW50TGlzdGVuZXIoImFib3J0Iiwgb25BYm9ydCk7'
                'DQogICAgICAgICAgICB9DQogICAgICAgIH0NCiAgICB9DQogICAgcmV0dXJuIHsNCiAgICAgICAgY29udGVudFR5cGU6ICIiLA0KICAgICAgICBlcnJvcjog'
                'ZmluYWxFcnJvciwNCiAgICAgICAga2luZDogcmVxdWVzdC5raW5kLA0KICAgICAgICBvcmlnaW5hbFVybDogcmVxdWVzdC5vcmlnaW5hbFVybCwNCiAgICAg'
                'ICAgcGF0aDogcmVxdWVzdC5wYXRoDQogICAgfTsNCn0NCg0KYXN5bmMgZnVuY3Rpb24gZG93bmxvYWRBc3NldFJlcXVlc3RzKA0KICAgIGNhdGFsb2c6IEFz'
                'c2V0Q2F0YWxvZywNCiAgICBzaWduYWw6IEFib3J0U2lnbmFsLA0KICAgIG9uUHJvZ3Jlc3M6IChwcm9ncmVzczogRXhwb3J0UHJvZ3Jlc3MpID0+IHZvaWQs'
                'DQogICAgZmV0Y2hlcjogdHlwZW9mIGZldGNoID0gZmV0Y2gNCik6IFByb21pc2U8RG93bmxvYWRTdW1tYXJ5PiB7DQogICAgY29uc3QgYWxpYXNlcyA9IG5l'
                'dyBNYXA8c3RyaW5nLCBBc3NldFJlc3VsdD4oKTsNCiAgICBjb25zdCBkb3dubG9hZGVkOiBBc3NldFJlc3VsdFtdID0gW107DQogICAgY29uc3QgZmFpbHVy'
                'ZXM6IEFzc2V0UmVzdWx0W10gPSBbXTsNCiAgICBsZXQgY3Vyc29yID0gMDsNCiAgICBsZXQgcHJvY2Vzc2VkID0gMDsNCiAgICBsZXQgZG93bmxvYWRlZEJ5'
                'dGVzID0gMDsNCg0KICAgIGFzeW5jIGZ1bmN0aW9uIHdvcmtlcigpIHsNCiAgICAgICAgd2hpbGUgKHRydWUpIHsNCiAgICAgICAgICAgIHRocm93SWZBYm9y'
                'dGVkKHNpZ25hbCk7DQogICAgICAgICAgICBjb25zdCBpbmRleCA9IGN1cnNvcisrOw0KICAgICAgICAgICAgaWYgKGluZGV4ID49IGNhdGFsb2cucmVxdWVz'
                'dHMubGVuZ3RoKSByZXR1cm47DQogICAgICAgICAgICBjb25zdCByZXF1ZXN0ID0gY2F0YWxvZy5yZXF1ZXN0c1tpbmRleF07DQogICAgICAgICAgICBjb25z'
                'dCByZXN1bHQgPSBhd2FpdCBmZXRjaEFzc2V0KHJlcXVlc3QsIHNpZ25hbCwgZmV0Y2hlcik7DQogICAgICAgICAgICBmb3IgKGNvbnN0IGFsaWFzIG9mIHJl'
                'cXVlc3QuYWxpYXNlcykgYWxpYXNlcy5zZXQoYWxpYXMsIHJlc3VsdCk7DQogICAgICAgICAgICBpZiAocmVzdWx0LmJ5dGVzKSB7DQogICAgICAgICAgICAg'
                'ICAgZG93bmxvYWRlZC5wdXNoKHJlc3VsdCk7DQogICAgICAgICAgICAgICAgZG93bmxvYWRlZEJ5dGVzICs9IHJlc3VsdC5ieXRlcy5ieXRlTGVuZ3RoOw0K'
                'ICAgICAgICAgICAgfSBlbHNlIHsNCiAgICAgICAgICAgICAgICBmYWlsdXJlcy5wdXNoKHJlc3VsdCk7DQogICAgICAgICAgICB9DQogICAgICAgICAgICBw'
                'cm9jZXNzZWQrKzsNCiAgICAgICAgICAgIG9uUHJvZ3Jlc3MoeyBzdGFnZTogIkRvd25sb2FkaW5nIG1lZGlhIiwgcHJvY2Vzc2VkLCB0b3RhbDogY2F0YWxv'
                'Zy5yZXF1ZXN0cy5sZW5ndGgsIGRvd25sb2FkZWRCeXRlcywgZmFpbHVyZXM6IGZhaWx1cmVzLmxlbmd0aCB9KTsNCiAgICAgICAgfQ0KICAgIH0NCg0KICAg'
                'IGF3YWl0IFByb21pc2UuYWxsKEFycmF5LmZyb20oeyBsZW5ndGg6IE1hdGgubWluKEFTU0VUX0NPTkNVUlJFTkNZLCBNYXRoLm1heCgxLCBjYXRhbG9nLnJl'
                'cXVlc3RzLmxlbmd0aCkpIH0sIHdvcmtlcikpOw0KICAgIHRocm93SWZBYm9ydGVkKHNpZ25hbCk7DQogICAgcmV0dXJuIHsgYWxpYXNlcywgZG93bmxvYWRl'
                'ZCwgZG93bmxvYWRlZEJ5dGVzLCBmYWlsdXJlcyB9Ow0KfQ0KDQpmdW5jdGlvbiByZW5kZXJNZXNzYWdlVGV4dCh2YWx1ZTogdW5rbm93biwgcmVzb2x2ZTog'
                'KGFsaWFzOiBzdHJpbmcpID0+IEFzc2V0UmVzdWx0IHwgdW5kZWZpbmVkLCBtb2RlOiBIdG1sTW9kZSk6IHN0cmluZyB7DQogICAgY29uc3QgdGV4dCA9IFN0'
                'cmluZyh2YWx1ZSA/PyAiIik7DQogICAgY29uc3QgdG9rZW5QYXR0ZXJuID0gLzwoYT8pOihbQS1aYS16MC05X10rKTooXGQrKT58aHR0cHM/OlwvXC9bXlxz'
                'PD5dKy9nOw0KICAgIGxldCBvdXRwdXQgPSAiIjsNCiAgICBsZXQgb2Zmc2V0ID0gMDsNCiAgICBmb3IgKGNvbnN0IG1hdGNoIG9mIHRleHQubWF0Y2hBbGwo'
                'dG9rZW5QYXR0ZXJuKSkgew0KICAgICAgICBjb25zdCBpbmRleCA9IG1hdGNoLmluZGV4ID8/IDA7DQogICAgICAgIG91dHB1dCArPSBlc2NhcGVIdG1sKHRl'
                'eHQuc2xpY2Uob2Zmc2V0LCBpbmRleCkpOw0KICAgICAgICBpZiAobWF0Y2hbM10pIHsNCiAgICAgICAgICAgIGNvbnN0IGFsaWFzID0gYGVtb2ppOiR7bWF0'
                'Y2hbM119YDsNCiAgICAgICAgICAgIGNvbnN0IHJlc3VsdCA9IHJlc29sdmUoYWxpYXMpOw0KICAgICAgICAgICAgY29uc3QgYWx0ID0gYDoke21hdGNoWzJd'
                'fTpgOw0KICAgICAgICAgICAgb3V0cHV0ICs9IHJlbmRlckltYWdlQXNzZXQoYWxpYXMsIHJlc3VsdCwgYWx0LCBtb2RlLCAiZW1vamkiKTsNCiAgICAgICAg'
                'fSBlbHNlIHsNCiAgICAgICAgICAgIGNvbnN0IHVybCA9IHNhZmVFeHRlcm5hbFVybChtYXRjaFswXSk7DQogICAgICAgICAgICBvdXRwdXQgKz0gdXJsDQog'
                'ICAgICAgICAgICAgICAgPyBgPGEgaHJlZj0iJHtlc2NhcGVIdG1sKHVybCl9IiB0YXJnZXQ9Il9ibGFuayIgcmVsPSJub29wZW5lciBub3JlZmVycmVyIj4k'
                'e2VzY2FwZUh0bWwobWF0Y2hbMF0pfTwvYT5gDQogICAgICAgICAgICAgICAgOiBlc2NhcGVIdG1sKG1hdGNoWzBdKTsNCiAgICAgICAgfQ0KICAgICAgICBv'
                'ZmZzZXQgPSBpbmRleCArIG1hdGNoWzBdLmxlbmd0aDsNCiAgICB9DQogICAgb3V0cHV0ICs9IGVzY2FwZUh0bWwodGV4dC5zbGljZShvZmZzZXQpKTsNCiAg'
                'ICByZXR1cm4gb3V0cHV0LnJlcGxhY2UoL1xyP1xuL2csICI8YnI+Iik7DQp9DQoNCmZ1bmN0aW9uIGFzc2V0U291cmNlQXR0cmlidXRlcyhhbGlhczogc3Ry'
                'aW5nLCByZXN1bHQ6IEFzc2V0UmVzdWx0IHwgdW5kZWZpbmVkLCBtb2RlOiBIdG1sTW9kZSk6IHN0cmluZyB7DQogICAgaWYgKCFyZXN1bHQgfHwgcmVzdWx0'
                'LmVycm9yKSByZXR1cm4gIiI7DQogICAgaWYgKG1vZGUgPT09ICJvbmxpbmUiKSByZXR1cm4gYHNyYz0iJHtlc2NhcGVIdG1sKHJlc3VsdC5vcmlnaW5hbFVy'
                'bCl9ImA7DQogICAgaWYgKG1vZGUgPT09ICJhcmNoaXZlIikgcmV0dXJuIGBzcmM9IiR7ZXNjYXBlSHRtbChyZXN1bHQucGF0aCl9ImA7DQogICAgcmV0dXJu'
                'IGBkYXRhLWFzc2V0LWtleT0iJHtlc2NhcGVIdG1sKGFsaWFzKX0iYDsNCn0NCg0KZnVuY3Rpb24gbG9jYWxMaW5rQXR0cmlidXRlcyhhbGlhczogc3RyaW5n'
                'LCByZXN1bHQ6IEFzc2V0UmVzdWx0IHwgdW5kZWZpbmVkLCBtb2RlOiBIdG1sTW9kZSk6IHN0cmluZyB7DQogICAgaWYgKCFyZXN1bHQgfHwgcmVzdWx0LmVy'
                'cm9yKSByZXR1cm4gIiI7DQogICAgaWYgKG1vZGUgPT09ICJvbmxpbmUiKSByZXR1cm4gYGhyZWY9IiR7ZXNjYXBlSHRtbChyZXN1bHQub3JpZ2luYWxVcmwp'
                'fSJgOw0KICAgIGlmIChtb2RlID09PSAiYXJjaGl2ZSIpIHJldHVybiBgaHJlZj0iJHtlc2NhcGVIdG1sKHJlc3VsdC5wYXRoKX0iYDsNCiAgICByZXR1cm4g'
                'YGhyZWY9IiMiIGRhdGEtYXNzZXQta2V5PSIke2VzY2FwZUh0bWwoYWxpYXMpfSJgOw0KfQ0KDQpmdW5jdGlvbiBvcmlnaW5hbExpbmsocmVzdWx0OiBBc3Nl'
                'dFJlc3VsdCB8IHVuZGVmaW5lZCk6IHN0cmluZyB7DQogICAgY29uc3QgdXJsID0gc2FmZUV4dGVybmFsVXJsKHJlc3VsdD8ub3JpZ2luYWxVcmwpOw0KICAg'
                'IHJldHVybiB1cmwgPyBgPGEgY2xhc3M9Im9yaWdpbmFsLWxpbmsiIGhyZWY9IiR7ZXNjYXBlSHRtbCh1cmwpfSIgdGFyZ2V0PSJfYmxhbmsiIHJlbD0ibm9v'
                'cGVuZXIgbm9yZWZlcnJlciI+T3JpZ2luYWwgb25saW5lIHNvdXJjZTwvYT5gIDogIiI7DQp9DQoNCmZ1bmN0aW9uIHVuYXZhaWxhYmxlTWVkaWEobGFiZWw6'
                'IHN0cmluZywgcmVzdWx0OiBBc3NldFJlc3VsdCB8IHVuZGVmaW5lZCk6IHN0cmluZyB7DQogICAgY29uc3QgcmVhc29uID0gcmVzdWx0Py5lcnJvciA/IGAg'
                'KCR7ZXNjYXBlSHRtbChyZXN1bHQuZXJyb3IpfSlgIDogIiI7DQogICAgcmV0dXJuIGA8c3BhbiBjbGFzcz0ibWVkaWEtdW5hdmFpbGFibGUiIHJvbGU9Im5v'
                'dGUiPiR7ZXNjYXBlSHRtbChsYWJlbCl9IHVuYXZhaWxhYmxlIG9mZmxpbmUke3JlYXNvbn08L3NwYW4+JHtvcmlnaW5hbExpbmsocmVzdWx0KX1gOw0KfQ0K'
                'DQpmdW5jdGlvbiByZW5kZXJJbWFnZUFzc2V0KGFsaWFzOiBzdHJpbmcsIHJlc3VsdDogQXNzZXRSZXN1bHQgfCB1bmRlZmluZWQsIGFsdDogc3RyaW5nLCBt'
                'b2RlOiBIdG1sTW9kZSwgY2xhc3NOYW1lID0gIm1lZGlhLWltYWdlIik6IHN0cmluZyB7DQogICAgY29uc3Qgc291cmNlID0gYXNzZXRTb3VyY2VBdHRyaWJ1'
                'dGVzKGFsaWFzLCByZXN1bHQsIG1vZGUpOw0KICAgIGlmICghc291cmNlKSByZXR1cm4gdW5hdmFpbGFibGVNZWRpYShhbHQsIHJlc3VsdCk7DQogICAgcmV0'
                'dXJuIGA8aW1nIGNsYXNzPSIke2NsYXNzTmFtZX0iICR7c291cmNlfSBhbHQ9IiR7ZXNjYXBlSHRtbChhbHQpfSIgbG9hZGluZz0ibGF6eSI+YDsNCn0NCg0K'
                'ZnVuY3Rpb24gcmVuZGVyQXR0YWNobWVudChtZXNzYWdlOiBhbnksIGF0dGFjaG1lbnQ6IGFueSwgaW5kZXg6IG51bWJlciwgcmVzb2x2ZTogKGFsaWFzOiBz'
                'dHJpbmcpID0+IEFzc2V0UmVzdWx0IHwgdW5kZWZpbmVkLCBtb2RlOiBIdG1sTW9kZSk6IHN0cmluZyB7DQogICAgY29uc3QgaWQgPSBTdHJpbmcoYXR0YWNo'
                'bWVudD8uaWQgPz8gaW5kZXgpOw0KICAgIGNvbnN0IGFsaWFzID0gYGF0dGFjaG1lbnQ6JHttZXNzYWdlPy5pZH06JHtpZH1gOw0KICAgIGNvbnN0IHJlc3Vs'
                'dCA9IHJlc29sdmUoYWxpYXMpOw0KICAgIGNvbnN0IG5hbWUgPSBTdHJpbmcoYXR0YWNobWVudD8uZmlsZW5hbWUgPz8gImF0dGFjaG1lbnQiKTsNCiAgICBj'
                'b25zdCBkZXNjcmlwdGlvbiA9IFN0cmluZyhhdHRhY2htZW50Py5kZXNjcmlwdGlvbiA/PyAiIik7DQogICAgY29uc3QgZGV0YWlscyA9IFtlc2NhcGVIdG1s'
                'KG5hbWUpLCBhdHRhY2htZW50Py5zaXplID8gZm9ybWF0Qnl0ZXMoYXR0YWNobWVudC5zaXplKSA6ICIiXS5maWx0ZXIoQm9vbGVhbikuam9pbigiIC0gIik7'
                'DQogICAgY29uc3QgY2FwdGlvbiA9IGA8ZmlnY2FwdGlvbj4ke2RldGFpbHN9JHtkZXNjcmlwdGlvbiA/IGA8c3Bhbj4ke2VzY2FwZUh0bWwoZGVzY3JpcHRp'
                'b24pfTwvc3Bhbj5gIDogIiJ9JHtvcmlnaW5hbExpbmsocmVzdWx0KX08L2ZpZ2NhcHRpb24+YDsNCiAgICBjb25zdCBzb3VyY2UgPSBhc3NldFNvdXJjZUF0'
                'dHJpYnV0ZXMoYWxpYXMsIHJlc3VsdCwgbW9kZSk7DQogICAgY29uc3QgbGluayA9IGxvY2FsTGlua0F0dHJpYnV0ZXMoYWxpYXMsIHJlc3VsdCwgbW9kZSk7'
                'DQogICAgaWYgKCFzb3VyY2UgfHwgIWxpbmspIHJldHVybiBgPGRpdiBjbGFzcz0iZmlsZS1jYXJkIj4ke3VuYXZhaWxhYmxlTWVkaWEobmFtZSwgcmVzdWx0'
                'KX08L2Rpdj5gOw0KDQogICAgY29uc3Qga2luZCA9IG1lZGlhS2luZChhdHRhY2htZW50KTsNCiAgICBpZiAoa2luZCA9PT0gImltYWdlIikgcmV0dXJuIGA8'
                'ZmlndXJlPjxhICR7bGlua30gZG93bmxvYWQ+JHtyZW5kZXJJbWFnZUFzc2V0KGFsaWFzLCByZXN1bHQsIGRlc2NyaXB0aW9uIHx8IG5hbWUsIG1vZGUpfTwv'
                'YT4ke2NhcHRpb259PC9maWd1cmU+YDsNCiAgICBpZiAoa2luZCA9PT0gInZpZGVvIikgcmV0dXJuIGA8ZmlndXJlPjx2aWRlbyAke3NvdXJjZX0gY29udHJv'
                'bHMgcHJlbG9hZD0ibWV0YWRhdGEiPjwvdmlkZW8+JHtjYXB0aW9ufTwvZmlndXJlPmA7DQogICAgaWYgKGtpbmQgPT09ICJhdWRpbyIpIHJldHVybiBgPGZp'
                'Z3VyZT48YXVkaW8gJHtzb3VyY2V9IGNvbnRyb2xzIHByZWxvYWQ9Im1ldGFkYXRhIj48L2F1ZGlvPiR7Y2FwdGlvbn08L2ZpZ3VyZT5gOw0KICAgIHJldHVy'
                'biBgPGRpdiBjbGFzcz0iZmlsZS1jYXJkIj48YSAke2xpbmt9IGRvd25sb2FkPiR7ZXNjYXBlSHRtbChuYW1lKX08L2E+PHNwYW4+JHtkZXRhaWxzfTwvc3Bh'
                'bj4ke29yaWdpbmFsTGluayhyZXN1bHQpfTwvZGl2PmA7DQp9DQoNCmZ1bmN0aW9uIHJlbmRlclN0aWNrZXJzKG1lc3NhZ2U6IGFueSwgcmVzb2x2ZTogKGFs'
                'aWFzOiBzdHJpbmcpID0+IEFzc2V0UmVzdWx0IHwgdW5kZWZpbmVkLCBtb2RlOiBIdG1sTW9kZSk6IHN0cmluZyB7DQogICAgY29uc3QgcmVuZGVyZWQgPSBz'
                'dGlja2VySXRlbXMobWVzc2FnZSkubWFwKHN0aWNrZXIgPT4gew0KICAgICAgICBjb25zdCBpZCA9IFN0cmluZyhzdGlja2VyPy5pZCA/PyAiIik7DQogICAg'
                'ICAgIGNvbnN0IG5hbWUgPSBTdHJpbmcoc3RpY2tlcj8ubmFtZSA/PyAic3RpY2tlciIpOw0KICAgICAgICBjb25zdCBmb3JtYXQgPSBOdW1iZXIoc3RpY2tl'
                'cj8uZm9ybWF0X3R5cGUgPz8gc3RpY2tlcj8uZm9ybWF0VHlwZSA/PyAxKTsNCiAgICAgICAgaWYgKGZvcm1hdCA9PT0gMykgew0KICAgICAgICAgICAgY29u'
                'c3QgdXJsID0gc2FmZUV4dGVybmFsVXJsKGBodHRwczovL2Nkbi5kaXNjb3JkYXBwLmNvbS9zdGlja2Vycy8ke2lkfS5qc29uYCk7DQogICAgICAgICAgICBy'
                'ZXR1cm4gYDxzcGFuIGNsYXNzPSJtZWRpYS11bmF2YWlsYWJsZSI+JHtlc2NhcGVIdG1sKG5hbWUpfSB1c2VzIGFuIHVuc3VwcG9ydGVkIExvdHRpZSBmb3Jt'
                'YXQ8L3NwYW4+PGEgY2xhc3M9Im9yaWdpbmFsLWxpbmsiIGhyZWY9IiR7ZXNjYXBlSHRtbCh1cmwpfSIgdGFyZ2V0PSJfYmxhbmsiIHJlbD0ibm9vcGVuZXIg'
                'bm9yZWZlcnJlciI+T3JpZ2luYWwgTG90dGllIGRhdGE8L2E+YDsNCiAgICAgICAgfQ0KICAgICAgICBpZiAoIS9eXGQrJC8udGVzdChpZCkpIHJldHVybiAi'
                'IjsNCiAgICAgICAgcmV0dXJuIHJlbmRlckltYWdlQXNzZXQoYHN0aWNrZXI6JHtpZH1gLCByZXNvbHZlKGBzdGlja2VyOiR7aWR9YCksIG5hbWUsIG1vZGUs'
                'ICJzdGlja2VyIik7DQogICAgfSkuZmlsdGVyKEJvb2xlYW4pLmpvaW4oIiIpOw0KICAgIHJldHVybiByZW5kZXJlZCA/IGA8ZGl2IGNsYXNzPSJzdGlja2Vy'
                'LXJvdyI+JHtyZW5kZXJlZH08L2Rpdj5gIDogIiI7DQp9DQoNCmZ1bmN0aW9uIHJlbmRlckVtYmVkKG1lc3NhZ2U6IGFueSwgZW1iZWQ6IGFueSwgaW5kZXg6'
                'IG51bWJlciwgcmVzb2x2ZTogKGFsaWFzOiBzdHJpbmcpID0+IEFzc2V0UmVzdWx0IHwgdW5kZWZpbmVkLCBtb2RlOiBIdG1sTW9kZSk6IHN0cmluZyB7DQog'
                'ICAgY29uc3QgdGl0bGUgPSBTdHJpbmcoZW1iZWQ/LnRpdGxlID8/ICIiKTsNCiAgICBjb25zdCBkZXNjcmlwdGlvbiA9IHJlbmRlck1lc3NhZ2VUZXh0KGVt'
                'YmVkPy5kZXNjcmlwdGlvbiA/PyAiIiwgcmVzb2x2ZSwgbW9kZSk7DQogICAgY29uc3QgdXJsID0gc2FmZUV4dGVybmFsVXJsKGVtYmVkPy51cmwpOw0KICAg'
                'IGNvbnN0IGF1dGhvciA9IGVzY2FwZUh0bWwoZW1iZWQ/LmF1dGhvcj8ubmFtZSA/PyAiIik7DQogICAgY29uc3QgcHJvdmlkZXIgPSBlc2NhcGVIdG1sKGVt'
                'YmVkPy5wcm92aWRlcj8ubmFtZSA/PyAiIik7DQogICAgY29uc3QgZmllbGRzID0gQXJyYXkuaXNBcnJheShlbWJlZD8uZmllbGRzKSA/IGVtYmVkLmZpZWxk'
                'cy5tYXAoKGZpZWxkOiBhbnkpID0+DQogICAgICAgIGA8ZGl2IGNsYXNzPSJlbWJlZC1maWVsZCI+PHN0cm9uZz4ke2VzY2FwZUh0bWwoZmllbGQ/Lm5hbWUg'
                'Pz8gIiIpfTwvc3Ryb25nPjxkaXY+JHtyZW5kZXJNZXNzYWdlVGV4dChmaWVsZD8udmFsdWUgPz8gIiIsIHJlc29sdmUsIG1vZGUpfTwvZGl2PjwvZGl2PmAN'
                'CiAgICApLmpvaW4oIiIpIDogIiI7DQogICAgY29uc3QgaW1hZ2VBbGlhcyA9IGBlbWJlZDoke21lc3NhZ2U/LmlkfToke2luZGV4fTppbWFnZWA7DQogICAg'
                'Y29uc3QgdGh1bWJuYWlsQWxpYXMgPSBgZW1iZWQ6JHttZXNzYWdlPy5pZH06JHtpbmRleH06dGh1bWJuYWlsYDsNCiAgICBjb25zdCB2aWRlb0FsaWFzID0g'
                'YGVtYmVkOiR7bWVzc2FnZT8uaWR9OiR7aW5kZXh9OnZpZGVvYDsNCiAgICBjb25zdCBpbWFnZVJlc3VsdCA9IHJlc29sdmUoaW1hZ2VBbGlhcyk7DQogICAg'
                'Y29uc3QgdGh1bWJuYWlsUmVzdWx0ID0gcmVzb2x2ZSh0aHVtYm5haWxBbGlhcyk7DQogICAgY29uc3QgdmlkZW9SZXN1bHQgPSByZXNvbHZlKHZpZGVvQWxp'
                'YXMpOw0KICAgIGNvbnN0IGltYWdlID0gaW1hZ2VSZXN1bHQgPyByZW5kZXJJbWFnZUFzc2V0KGltYWdlQWxpYXMsIGltYWdlUmVzdWx0LCAiRW1iZWRkZWQg'
                'aW1hZ2UiLCBtb2RlLCAiZW1iZWQtaW1hZ2UiKSA6ICIiOw0KICAgIGNvbnN0IHRodW1ibmFpbCA9IHRodW1ibmFpbFJlc3VsdCA/IHJlbmRlckltYWdlQXNz'
                'ZXQodGh1bWJuYWlsQWxpYXMsIHRodW1ibmFpbFJlc3VsdCwgIkVtYmVkZGVkIHRodW1ibmFpbCIsIG1vZGUsICJlbWJlZC10aHVtYm5haWwiKSA6ICIiOw0K'
                'ICAgIGNvbnN0IHZpZGVvU291cmNlID0gYXNzZXRTb3VyY2VBdHRyaWJ1dGVzKHZpZGVvQWxpYXMsIHZpZGVvUmVzdWx0LCBtb2RlKTsNCiAgICBjb25zdCB2'
                'aWRlbyA9IHZpZGVvUmVzdWx0DQogICAgICAgID8gdmlkZW9Tb3VyY2UgPyBgPHZpZGVvIGNsYXNzPSJlbWJlZC12aWRlbyIgJHt2aWRlb1NvdXJjZX0gY29u'
                'dHJvbHMgcHJlbG9hZD0ibWV0YWRhdGEiPjwvdmlkZW8+YCA6IHVuYXZhaWxhYmxlTWVkaWEoIkVtYmVkZGVkIHZpZGVvIiwgdmlkZW9SZXN1bHQpDQogICAg'
                'ICAgIDogIiI7DQogICAgY29uc3QgbGlua2VkVGl0bGUgPSB0aXRsZQ0KICAgICAgICA/IHVybCA/IGA8YSBocmVmPSIke2VzY2FwZUh0bWwodXJsKX0iIHRh'
                'cmdldD0iX2JsYW5rIiByZWw9Im5vb3BlbmVyIG5vcmVmZXJyZXIiPiR7ZXNjYXBlSHRtbCh0aXRsZSl9PC9hPmAgOiBlc2NhcGVIdG1sKHRpdGxlKQ0KICAg'
                'ICAgICA6ICIiOw0KICAgIGlmICghbGlua2VkVGl0bGUgJiYgIWRlc2NyaXB0aW9uICYmICFmaWVsZHMgJiYgIWltYWdlICYmICF0aHVtYm5haWwgJiYgIXZp'
                'ZGVvKSByZXR1cm4gIiI7DQogICAgcmV0dXJuIGA8YXNpZGUgY2xhc3M9ImVtYmVkIj4ke3RodW1ibmFpbH08ZGl2IGNsYXNzPSJlbWJlZC1ib2R5Ij4ke2F1'
                'dGhvciB8fCBwcm92aWRlciA/IGA8ZGl2IGNsYXNzPSJlbWJlZC1tZXRhIj4ke1thdXRob3IsIHByb3ZpZGVyXS5maWx0ZXIoQm9vbGVhbikuam9pbigiIC0g'
                'Iil9PC9kaXY+YCA6ICIifSR7bGlua2VkVGl0bGUgPyBgPGRpdiBjbGFzcz0iZW1iZWQtdGl0bGUiPiR7bGlua2VkVGl0bGV9PC9kaXY+YCA6ICIifSR7ZGVz'
                'Y3JpcHRpb24gPyBgPGRpdj4ke2Rlc2NyaXB0aW9ufTwvZGl2PmAgOiAiIn0ke2ZpZWxkcyA/IGA8ZGl2IGNsYXNzPSJlbWJlZC1maWVsZHMiPiR7ZmllbGRz'
                'fTwvZGl2PmAgOiAiIn0ke3ZpZGVvfSR7aW1hZ2V9PC9kaXY+PC9hc2lkZT5gOw0KfQ0KDQpmdW5jdGlvbiByZW5kZXJNZXNzYWdlTWVkaWEobWVzc2FnZTog'
                'YW55LCByZXNvbHZlOiAoYWxpYXM6IHN0cmluZykgPT4gQXNzZXRSZXN1bHQgfCB1bmRlZmluZWQsIG1vZGU6IEh0bWxNb2RlKTogc3RyaW5nIHsNCiAgICBj'
                'b25zdCBhdHRhY2htZW50cyA9IChBcnJheS5pc0FycmF5KG1lc3NhZ2U/LmF0dGFjaG1lbnRzKSA/IG1lc3NhZ2UuYXR0YWNobWVudHMgOiBbXSkNCiAgICAg'
                'ICAgLm1hcCgoYXR0YWNobWVudDogYW55LCBpbmRleDogbnVtYmVyKSA9PiByZW5kZXJBdHRhY2htZW50KG1lc3NhZ2UsIGF0dGFjaG1lbnQsIGluZGV4LCBy'
                'ZXNvbHZlLCBtb2RlKSkNCiAgICAgICAgLmpvaW4oIiIpOw0KICAgIGNvbnN0IGVtYmVkcyA9IChBcnJheS5pc0FycmF5KG1lc3NhZ2U/LmVtYmVkcykgPyBt'
                'ZXNzYWdlLmVtYmVkcyA6IFtdKQ0KICAgICAgICAubWFwKChlbWJlZDogYW55LCBpbmRleDogbnVtYmVyKSA9PiByZW5kZXJFbWJlZChtZXNzYWdlLCBlbWJl'
                'ZCwgaW5kZXgsIHJlc29sdmUsIG1vZGUpKQ0KICAgICAgICAuam9pbigiIik7DQogICAgY29uc3Qgc3RpY2tlcnMgPSByZW5kZXJTdGlja2VycyhtZXNzYWdl'
                'LCByZXNvbHZlLCBtb2RlKTsNCiAgICByZXR1cm4gYXR0YWNobWVudHMgfHwgZW1iZWRzIHx8IHN0aWNrZXJzID8gYDxkaXYgY2xhc3M9Im1lZGlhLXN0YWNr'
                'Ij4ke2F0dGFjaG1lbnRzfSR7ZW1iZWRzfSR7c3RpY2tlcnN9PC9kaXY+YCA6ICIiOw0KfQ0KDQpmdW5jdGlvbiByZW5kZXJBdmF0YXIoYXV0aG9yOiBhbnks'
                'IHJlc29sdmU6IChhbGlhczogc3RyaW5nKSA9PiBBc3NldFJlc3VsdCB8IHVuZGVmaW5lZCwgbW9kZTogSHRtbE1vZGUpOiBzdHJpbmcgew0KICAgIGNvbnN0'
                'IGFsaWFzID0gYGF2YXRhcjoke2F1dGhvcj8uaWR9OiR7YXV0aG9yPy5hdmF0YXJ9YDsNCiAgICBjb25zdCByZXN1bHQgPSByZXNvbHZlKGFsaWFzKTsNCiAg'
                'ICBpZiAocmVzdWx0KSByZXR1cm4gcmVuZGVySW1hZ2VBc3NldChhbGlhcywgcmVzdWx0LCAiIiwgbW9kZSwgImF2YXRhciIpOw0KICAgIGNvbnN0IG5hbWUg'
                'PSBTdHJpbmcoYXV0aG9yPy5nbG9iYWxfbmFtZSA/PyBhdXRob3I/LnVzZXJuYW1lID8/ICI/IikudHJpbSgpOw0KICAgIHJldHVybiBgPHNwYW4gY2xhc3M9'
                'ImF2YXRhciBhdmF0YXItZmFsbGJhY2siIGFyaWEtaGlkZGVuPSJ0cnVlIj4ke2VzY2FwZUh0bWwobmFtZS5zbGljZSgwLCAxKS50b1VwcGVyQ2FzZSgpIHx8'
                'ICI/Iil9PC9zcGFuPmA7DQp9DQoNCmZ1bmN0aW9uIGNvbnZlcnNhdGlvblN0eWxlcygpOiBzdHJpbmcgew0KICAgIHJldHVybiBTdHJpbmcucmF3YDpyb290'
                'e2NvbG9yLXNjaGVtZTpkYXJrfSp7Ym94LXNpemluZzpib3JkZXItYm94fWJvZHl7bWFyZ2luOjA7YmFja2dyb3VuZDojMzEzMzM4O2NvbG9yOiNkYmRlZTE7'
                'Zm9udC1mYW1pbHk6c3lzdGVtLXVpLC1hcHBsZS1zeXN0ZW0sQmxpbmtNYWNTeXN0ZW1Gb250LCJTZWdvZSBVSSIsc2Fucy1zZXJpZjtmb250LXNpemU6MTVw'
                'eDtsaW5lLWhlaWdodDoxLjQ2O3BhZGRpbmc6MjhweCAxOHB4fW1haW57bWF4LXdpZHRoOjk2MHB4O21hcmdpbjowIGF1dG99aDF7bWFyZ2luOjA7Y29sb3I6'
                'I2YyZjNmNTtmb250LXNpemU6MjRweDtvdmVyZmxvdy13cmFwOmFueXdoZXJlfS5zdWJ0aXRsZXttYXJnaW46NHB4IDAgMjRweDtjb2xvcjojOTQ5YmE0O2Zv'
                'bnQtc2l6ZToxM3B4fS5tZXNzYWdle2Rpc3BsYXk6Z3JpZDtncmlkLXRlbXBsYXRlLWNvbHVtbnM6NDZweCBtaW5tYXgoMCwxZnIpO2NvbHVtbi1nYXA6MTJw'
                'eDtwYWRkaW5nOjExcHggMTBweCAzcHg7Ym9yZGVyLXJhZGl1czo2cHh9Lm1lc3NhZ2UuY29udGludWF0aW9ue3BhZGRpbmctdG9wOjNweH0ubWVzc2FnZTpo'
                'b3ZlcntiYWNrZ3JvdW5kOiMyZTMwMzV9LmF2YXRhci1zbG90e2dyaWQtY29sdW1uOjE7Z3JpZC1yb3c6MS9zcGFuIDJ9LmF2YXRhcntkaXNwbGF5OmdyaWQ7'
                'd2lkdGg6NDBweDtoZWlnaHQ6NDBweDtib3JkZXItcmFkaXVzOjUwJTtvYmplY3QtZml0OmNvdmVyO3BsYWNlLWl0ZW1zOmNlbnRlcjtiYWNrZ3JvdW5kOiM1'
                'ODY1ZjI7Y29sb3I6I2ZmZjtmb250LXdlaWdodDo3MDB9Lm1lc3NhZ2UtYm9keXtncmlkLWNvbHVtbjoyO21pbi13aWR0aDowfS5tZXNzYWdlLWhlYWRlcntk'
                'aXNwbGF5OmZsZXg7YWxpZ24taXRlbXM6YmFzZWxpbmU7Z2FwOjdweDttaW4td2lkdGg6MH0uYXV0aG9ye2NvbG9yOiNmMmYzZjU7Zm9udC13ZWlnaHQ6NzAw'
                'O292ZXJmbG93LXdyYXA6YW55d2hlcmV9LnVzZXJuYW1lLC50aW1lc3RhbXB7Y29sb3I6Izk0OWJhNDtmb250LXNpemU6MTJweH0uY29udGludWF0aW9uLXRp'
                'bWV7Z3JpZC1jb2x1bW46MTtjb2xvcjojOTQ5YmE0O2ZvbnQtc2l6ZToxMHB4O3RleHQtYWxpZ246cmlnaHQ7cGFkZGluZy10b3A6NHB4fS5jb250ZW50e3do'
                'aXRlLXNwYWNlOm5vcm1hbDtvdmVyZmxvdy13cmFwOmFueXdoZXJlO3dvcmQtYnJlYWs6YnJlYWstd29yZH0uY29udGVudCBwcmUsLmNvbnRlbnQgY29kZXt3'
                'aGl0ZS1zcGFjZTpwcmUtd3JhcDtvdmVyZmxvdy13cmFwOmFueXdoZXJlfS5jb250ZW50IGEsLmVtYmVkIGEsLmZpbGUtY2FyZCBhLC5vcmlnaW5hbC1saW5r'
                'e2NvbG9yOiMwMGE4ZmM7dGV4dC1kZWNvcmF0aW9uOm5vbmU7b3ZlcmZsb3ctd3JhcDphbnl3aGVyZX0uY29udGVudCBhOmhvdmVyLC5lbWJlZCBhOmhvdmVy'
                'LC5maWxlLWNhcmQgYTpob3Zlciwub3JpZ2luYWwtbGluazpob3Zlcnt0ZXh0LWRlY29yYXRpb246dW5kZXJsaW5lfS5lbW9qaXtkaXNwbGF5OmlubGluZS1i'
                'bG9jazt3aWR0aDphdXRvO2hlaWdodDoxLjRlbTt2ZXJ0aWNhbC1hbGlnbjotLjMyZW07b2JqZWN0LWZpdDpjb250YWlufS5tZWRpYS1zdGFja3tkaXNwbGF5'
                'OmZsZXg7ZmxleC1kaXJlY3Rpb246Y29sdW1uO2FsaWduLWl0ZW1zOmZsZXgtc3RhcnQ7Z2FwOjEwcHg7bWFyZ2luLXRvcDo3cHh9Lm1lZGlhLXN0YWNrIGZp'
                'Z3VyZXttYXgtd2lkdGg6bWluKDEwMCUsNzIwcHgpO21hcmdpbjowfS5tZWRpYS1zdGFjayBpbWc6bm90KC5lbW9qaSk6bm90KC5hdmF0YXIpe2Rpc3BsYXk6'
                'YmxvY2s7bWF4LXdpZHRoOjEwMCU7bWF4LWhlaWdodDo1MjBweDtib3JkZXItcmFkaXVzOjZweDtvYmplY3QtZml0OmNvbnRhaW47YmFja2dyb3VuZDojMWUx'
                'ZjIyfS5tZWRpYS1zdGFjayB2aWRlb3tkaXNwbGF5OmJsb2NrO21heC13aWR0aDoxMDAlO21heC1oZWlnaHQ6NTIwcHg7Ym9yZGVyLXJhZGl1czo2cHg7YmFj'
                'a2dyb3VuZDojMWUxZjIyfS5tZWRpYS1zdGFjayBhdWRpb3tkaXNwbGF5OmJsb2NrO3dpZHRoOm1pbigxMDAlLDQ0MHB4KX1maWdjYXB0aW9ue2Rpc3BsYXk6'
                'ZmxleDtmbGV4LXdyYXA6d3JhcDtnYXA6NHB4IDEwcHg7bWFyZ2luLXRvcDo0cHg7Y29sb3I6I2I1YmFjMTtmb250LXNpemU6MTJweH1maWdjYXB0aW9uIHNw'
                'YW57ZmxleC1iYXNpczoxMDAlfS5vcmlnaW5hbC1saW5re2ZvbnQtc2l6ZToxMXB4fS5maWxlLWNhcmR7ZGlzcGxheTpmbGV4O2ZsZXgtd3JhcDp3cmFwO2Fs'
                'aWduLWl0ZW1zOmNlbnRlcjtnYXA6NXB4IDEwcHg7bWF4LXdpZHRoOjEwMCU7cGFkZGluZzo5cHggMTFweDtib3JkZXI6MXB4IHNvbGlkICM0ZTUwNTg7Ym9y'
                'ZGVyLXJhZGl1czo2cHg7YmFja2dyb3VuZDojMmIyZDMxO292ZXJmbG93LXdyYXA6YW55d2hlcmV9LmZpbGUtY2FyZCBzcGFue2NvbG9yOiM5NDliYTQ7Zm9u'
                'dC1zaXplOjEycHh9Lm1lZGlhLXVuYXZhaWxhYmxle2Rpc3BsYXk6aW5saW5lLWJsb2NrO3BhZGRpbmc6OHB4IDEwcHg7Ym9yZGVyOjFweCBkYXNoZWQgIzVk'
                'NjA2ODtib3JkZXItcmFkaXVzOjVweDtjb2xvcjojYjViYWMxO2JhY2tncm91bmQ6IzJiMmQzMTtmb250LXNpemU6MTJweH0uc3RpY2tlci1yb3d7ZGlzcGxh'
                'eTpmbGV4O2ZsZXgtd3JhcDp3cmFwO2dhcDo4cHh9LnN0aWNrZXJ7d2lkdGg6MTYwcHg7aGVpZ2h0OmF1dG99LmVtYmVke2Rpc3BsYXk6ZmxleDtnYXA6MTJw'
                'eDttYXgtd2lkdGg6bWluKDEwMCUsNzIwcHgpO3BhZGRpbmc6MTBweCAxMnB4O2JvcmRlci1sZWZ0OjRweCBzb2xpZCAjNGY1NjYwO2JvcmRlci1yYWRpdXM6'
                'NHB4O2JhY2tncm91bmQ6IzJiMmQzMTtvdmVyZmxvdy13cmFwOmFueXdoZXJlfS5lbWJlZC1ib2R5e21pbi13aWR0aDowO2ZsZXg6MX0uZW1iZWQtbWV0YXtt'
                'YXJnaW4tYm90dG9tOjNweDtjb2xvcjojYjViYWMxO2ZvbnQtc2l6ZToxMnB4fS5lbWJlZC10aXRsZXttYXJnaW4tYm90dG9tOjRweDtjb2xvcjojZjJmM2Y1'
                'O2ZvbnQtd2VpZ2h0OjcwMH0uZW1iZWQtZmllbGRze2Rpc3BsYXk6Z3JpZDtncmlkLXRlbXBsYXRlLWNvbHVtbnM6cmVwZWF0KDIsbWlubWF4KDAsMWZyKSk7'
                'Z2FwOjhweDttYXJnaW4tdG9wOjhweH0uZW1iZWQtZmllbGR7bWluLXdpZHRoOjA7Zm9udC1zaXplOjEzcHh9LmVtYmVkLWZpZWxkIHN0cm9uZ3tkaXNwbGF5'
                'OmJsb2NrO2NvbG9yOiNmMmYzZjV9LmVtYmVkLXRodW1ibmFpbHtvcmRlcjoyO3dpZHRoOjgwcHg7aGVpZ2h0OjgwcHg7b2JqZWN0LWZpdDpjb3Zlcn0uZW1i'
                'ZWQtaW1hZ2UsLmVtYmVkLXZpZGVve21heC13aWR0aDoxMDAlO21heC1oZWlnaHQ6NDIwcHg7bWFyZ2luLXRvcDo5cHh9LmFyY2hpdmUtZm9vdGVye21hcmdp'
                'bi10b3A6MjZweDtwYWRkaW5nLXRvcDoxMnB4O2JvcmRlci10b3A6MXB4IHNvbGlkICMzZjQxNDc7Y29sb3I6Izk0OWJhNDtmb250LXNpemU6MTFweH1AbWVk'
                'aWEobWF4LXdpZHRoOjU4MHB4KXtib2R5e3BhZGRpbmc6MTdweCA3cHh9Lm1lc3NhZ2V7Z3JpZC10ZW1wbGF0ZS1jb2x1bW5zOjM4cHggbWlubWF4KDAsMWZy'
                'KTtjb2x1bW4tZ2FwOjhweDtwYWRkaW5nLWlubGluZTo0cHh9LmF2YXRhcnt3aWR0aDozNHB4O2hlaWdodDozNHB4fS5lbWJlZHtnYXA6OHB4fS5lbWJlZC10'
                'aHVtYm5haWx7d2lkdGg6NjBweDtoZWlnaHQ6NjBweH0uZW1iZWQtZmllbGRze2dyaWQtdGVtcGxhdGUtY29sdW1uczoxZnJ9fWA7DQp9DQoNCmZ1bmN0aW9u'
                'IHJlbmRlckNvbnZlcnNhdGlvbkh0bWwoDQogICAgbWVzc2FnZXM6IGFueVtdLA0KICAgIGNoYW5uZWxOYW1lOiBzdHJpbmcsDQogICAgbW9kZTogSHRtbE1v'
                'ZGUsDQogICAgYWxpYXNlczogTWFwPHN0cmluZywgQXNzZXRSZXN1bHQ+LA0KICAgIGVtYmVkZGVkQXNzZXRzPzogRW1iZWRkZWRBc3NldFBheWxvYWQNCik6'
                'IHN0cmluZyB7DQogICAgY29uc3QgcmVzb2x2ZSA9IChhbGlhczogc3RyaW5nKSA9PiBhbGlhc2VzLmdldChhbGlhcyk7DQogICAgY29uc3Qgcm93czogc3Ry'
                'aW5nW10gPSBbXTsNCiAgICBsZXQgcHJldmlvdXNBdXRob3IgPSAiIjsNCiAgICBsZXQgcHJldmlvdXNUaW1lc3RhbXAgPSAwOw0KICAgIGZvciAoY29uc3Qg'
                'bWVzc2FnZSBvZiBtZXNzYWdlcykgew0KICAgICAgICBjb25zdCBhdXRob3JJZCA9IFN0cmluZyhtZXNzYWdlPy5hdXRob3I/LmlkID8/ICIiKTsNCiAgICAg'
                'ICAgY29uc3QgdGltZXN0YW1wID0gbmV3IERhdGUobWVzc2FnZT8udGltZXN0YW1wID8/IDApOw0KICAgICAgICBjb25zdCB0aW1lc3RhbXBNcyA9IHRpbWVz'
                'dGFtcC5nZXRUaW1lKCk7DQogICAgICAgIGNvbnN0IGdyb3VwZWQgPSBCb29sZWFuKGF1dGhvcklkICYmIGF1dGhvcklkID09PSBwcmV2aW91c0F1dGhvciAm'
                'JiBOdW1iZXIuaXNGaW5pdGUodGltZXN0YW1wTXMpICYmIHRpbWVzdGFtcE1zIC0gcHJldmlvdXNUaW1lc3RhbXAgPD0gR1JPVVBfV0lORE9XX01TKTsNCiAg'
                'ICAgICAgY29uc3QgYXV0aG9yID0gZXNjYXBlSHRtbChtZXNzYWdlPy5hdXRob3I/Lmdsb2JhbF9uYW1lID8/IG1lc3NhZ2U/LmF1dGhvcj8udXNlcm5hbWUg'
                'Pz8gIlVua25vd24gdXNlciIpOw0KICAgICAgICBjb25zdCB1c2VybmFtZSA9IGVzY2FwZUh0bWwobWVzc2FnZT8uYXV0aG9yPy51c2VybmFtZSA/PyAidW5r'
                'bm93biIpOw0KICAgICAgICBjb25zdCBpc28gPSBOdW1iZXIuaXNGaW5pdGUodGltZXN0YW1wTXMpID8gdGltZXN0YW1wLnRvSVNPU3RyaW5nKCkgOiAiIjsN'
                'CiAgICAgICAgY29uc3QgZGlzcGxheVRpbWUgPSBOdW1iZXIuaXNGaW5pdGUodGltZXN0YW1wTXMpID8gdGltZXN0YW1wLnRvTG9jYWxlU3RyaW5nKCkgOiAi'
                'VW5rbm93biB0aW1lIjsNCiAgICAgICAgY29uc3QgY29udGVudCA9IHJlbmRlck1lc3NhZ2VUZXh0KG1lc3NhZ2U/LmNvbnRlbnQgPz8gIiIsIHJlc29sdmUs'
                'IG1vZGUpOw0KICAgICAgICBjb25zdCBtZWRpYSA9IHJlbmRlck1lc3NhZ2VNZWRpYShtZXNzYWdlLCByZXNvbHZlLCBtb2RlKTsNCiAgICAgICAgY29uc3Qg'
                'aGVhZGVyID0gZ3JvdXBlZA0KICAgICAgICAgICAgPyBgPHRpbWUgY2xhc3M9ImNvbnRpbnVhdGlvbi10aW1lIiBkYXRldGltZT0iJHtlc2NhcGVIdG1sKGlz'
                'byl9IiB0aXRsZT0iJHtlc2NhcGVIdG1sKGRpc3BsYXlUaW1lKX0iPiR7ZXNjYXBlSHRtbCh0aW1lc3RhbXAudG9Mb2NhbGVUaW1lU3RyaW5nKFtdLCB7IGhv'
                'dXI6ICIyLWRpZ2l0IiwgbWludXRlOiAiMi1kaWdpdCIgfSkpfTwvdGltZT5gDQogICAgICAgICAgICA6IGA8ZGl2IGNsYXNzPSJhdmF0YXItc2xvdCI+JHty'
                'ZW5kZXJBdmF0YXIobWVzc2FnZT8uYXV0aG9yLCByZXNvbHZlLCBtb2RlKX08L2Rpdj48aGVhZGVyIGNsYXNzPSJtZXNzYWdlLWhlYWRlciI+PHNwYW4gY2xh'
                'c3M9ImF1dGhvciI+JHthdXRob3J9PC9zcGFuPjxzcGFuIGNsYXNzPSJ1c2VybmFtZSI+QCR7dXNlcm5hbWV9PC9zcGFuPjx0aW1lIGNsYXNzPSJ0aW1lc3Rh'
                'bXAiIGRhdGV0aW1lPSIke2VzY2FwZUh0bWwoaXNvKX0iPiR7ZXNjYXBlSHRtbChkaXNwbGF5VGltZSl9PC90aW1lPjwvaGVhZGVyPmA7DQogICAgICAgIHJv'
                'd3MucHVzaChgPGFydGljbGUgY2xhc3M9Im1lc3NhZ2Uke2dyb3VwZWQgPyAiIGNvbnRpbnVhdGlvbiIgOiAiIn0iIGRhdGEtbWVzc2FnZS1pZD0iJHtlc2Nh'
                'cGVIdG1sKG1lc3NhZ2U/LmlkID8/ICIiKX0iPiR7aGVhZGVyfTxkaXYgY2xhc3M9Im1lc3NhZ2UtYm9keSI+PGRpdiBjbGFzcz0iY29udGVudCI+JHtjb250'
                'ZW50IHx8IChtZWRpYSA/ICIiIDogIjxlbT5bbm8gdGV4dCBvciBtZWRpYV08L2VtPiIpfTwvZGl2PiR7bWVkaWF9PC9kaXY+PC9hcnRpY2xlPmApOw0KICAg'
                'ICAgICBwcmV2aW91c0F1dGhvciA9IGF1dGhvcklkOw0KICAgICAgICBwcmV2aW91c1RpbWVzdGFtcCA9IE51bWJlci5pc0Zpbml0ZSh0aW1lc3RhbXBNcykg'
                'PyB0aW1lc3RhbXBNcyA6IDA7DQogICAgfQ0KDQogICAgY29uc3QgdGl0bGUgPSBlc2NhcGVIdG1sKGNoYW5uZWxOYW1lKTsNCiAgICBjb25zdCBtb2RlTm90'
                'ZSA9IG1vZGUgPT09ICJvbmxpbmUiDQogICAgICAgID8gIk9ubGluZSBIVE1MIGV4cG9ydC4gSW50ZXJuZXQgYWNjZXNzIGlzIHJlcXVpcmVkIHRvIGxvYWQg'
                'bWVkaWEgZnJvbSBpdHMgb3JpZ2luYWwgc291cmNlLiINCiAgICAgICAgOiBtb2RlID09PSAiYXJjaGl2ZSIgPyAiT2ZmbGluZSBhcmNoaXZlLiBNZWRpYSBp'
                'cyBsb2FkZWQgZnJvbSB0aGUgaW5jbHVkZWQgYXNzZXRzIGZvbGRlcnMuIiA6ICJTZWxmLWNvbnRhaW5lZCBvZmZsaW5lIEhUTUwgZXhwb3J0LiI7DQogICAg'
                'Y29uc3QgYXNzZXRQYXlsb2FkID0gbW9kZSA9PT0gInNpbmdsZSINCiAgICAgICAgPyBgPHNjcmlwdCB0eXBlPSJhcHBsaWNhdGlvbi9qc29uIiBpZD0iYXNz'
                'ZXQtZGF0YSI+JHtKU09OLnN0cmluZ2lmeShlbWJlZGRlZEFzc2V0cyA/PyB7IGFsaWFzZXM6IHt9LCBkYXRhOiB7fSB9KS5yZXBsYWNlKC88L2csICJcXHUw'
                'MDNjIil9PC9zY3JpcHQ+PHNjcmlwdD4oKCk9Pntjb25zdCBuPWRvY3VtZW50LmdldEVsZW1lbnRCeUlkKCJhc3NldC1kYXRhIik7aWYoIW4pcmV0dXJuO2Nv'
                'bnN0IGE9SlNPTi5wYXJzZShuLnRleHRDb250ZW50fHwie30iKTtkb2N1bWVudC5xdWVyeVNlbGVjdG9yQWxsKCJbZGF0YS1hc3NldC1rZXldIikuZm9yRWFj'
                'aChlPT57Y29uc3Qgaz1lLmdldEF0dHJpYnV0ZSgiZGF0YS1hc3NldC1rZXkiKXx8IiI7Y29uc3QgdT1hLmRhdGE/LlthLmFsaWFzZXM/LltrXV07aWYoIXUp'
                'cmV0dXJuO2lmKGUudGFnTmFtZT09PSJBIillLnNldEF0dHJpYnV0ZSgiaHJlZiIsdSk7ZWxzZSBlLnNldEF0dHJpYnV0ZSgic3JjIix1KX0pfSkoKTwvc2Ny'
                'aXB0PmANCiAgICAgICAgOiAiIjsNCiAgICBjb25zdCBzY3JpcHRQb2xpY3kgPSBtb2RlID09PSAic2luZ2xlIiA/ICIndW5zYWZlLWlubGluZSciIDogIidu'
                'b25lJyI7DQogICAgY29uc3QgbWVkaWFQb2xpY3kgPSBtb2RlID09PSAib25saW5lIiA/ICJodHRwczogaHR0cDogZGF0YToiIDogbW9kZSA9PT0gInNpbmds'
                'ZSIgPyAiZGF0YToiIDogIidzZWxmJyBkYXRhOiI7DQogICAgcmV0dXJuIGA8IURPQ1RZUEUgaHRtbD48aHRtbCBsYW5nPSJlbiI+PGhlYWQ+PG1ldGEgY2hh'
                'cnNldD0idXRmLTgiPjxtZXRhIG5hbWU9InZpZXdwb3J0IiBjb250ZW50PSJ3aWR0aD1kZXZpY2Utd2lkdGgsaW5pdGlhbC1zY2FsZT0xIj48bWV0YSBodHRw'
                'LWVxdWl2PSJDb250ZW50LVNlY3VyaXR5LVBvbGljeSIgY29udGVudD0iZGVmYXVsdC1zcmMgJ25vbmUnOyBpbWctc3JjICR7bWVkaWFQb2xpY3l9OyBtZWRp'
                'YS1zcmMgJHttZWRpYVBvbGljeX07IHN0eWxlLXNyYyAndW5zYWZlLWlubGluZSc7IHNjcmlwdC1zcmMgJHtzY3JpcHRQb2xpY3l9Ij48dGl0bGU+JHt0aXRs'
                'ZX08L3RpdGxlPjxzdHlsZT4ke2NvbnZlcnNhdGlvblN0eWxlcygpfTwvc3R5bGU+PC9oZWFkPjxib2R5PjxtYWluPjxoMT4ke3RpdGxlfTwvaDE+PHAgY2xh'
                'c3M9InN1YnRpdGxlIj4ke2VzY2FwZUh0bWwobW9kZU5vdGUpfSAke21lc3NhZ2VzLmxlbmd0aH0gbWVzc2FnZSR7bWVzc2FnZXMubGVuZ3RoID09PSAxID8g'
                'IiIgOiAicyJ9LjwvcD4ke3Jvd3Muam9pbigiXG4iKX08Zm9vdGVyIGNsYXNzPSJhcmNoaXZlLWZvb3RlciI+R2VuZXJhdGVkIGxvY2FsbHkgYnkgRXF1aWNv'
                'cmQgRXhwb3J0RE0uIE5vIGFuYWx5dGljcyBvciByZW1vdGUgc2NyaXB0cyBhcmUgaW5jbHVkZWQuPC9mb290ZXI+PC9tYWluPiR7YXNzZXRQYXlsb2FkfTwv'
                'Ym9keT48L2h0bWw+YDsNCn0NCg0KZnVuY3Rpb24gcmF3SnNvbihtZXNzYWdlczogYW55W10sIGNoYW5uZWxOYW1lOiBzdHJpbmcsIGV4cG9ydGVkQXQgPSBu'
                'ZXcgRGF0ZSgpLnRvSVNPU3RyaW5nKCkpOiBzdHJpbmcgew0KICAgIHJldHVybiBKU09OLnN0cmluZ2lmeSh7IGNoYW5uZWw6IGNoYW5uZWxOYW1lLCBleHBv'
                'cnRlZEF0LCBtZXNzYWdlcyB9LCBudWxsLCAyKTsNCn0NCg0KZnVuY3Rpb24gYnl0ZXNUb0Jhc2U2NChieXRlczogVWludDhBcnJheSk6IHN0cmluZyB7DQog'
                'ICAgbGV0IGJpbmFyeSA9ICIiOw0KICAgIGNvbnN0IGNodW5rU2l6ZSA9IDB4ODAwMDsNCiAgICBmb3IgKGxldCBvZmZzZXQgPSAwOyBvZmZzZXQgPCBieXRl'
                'cy5sZW5ndGg7IG9mZnNldCArPSBjaHVua1NpemUpIHsNCiAgICAgICAgYmluYXJ5ICs9IFN0cmluZy5mcm9tQ2hhckNvZGUoLi4uYnl0ZXMuc3ViYXJyYXko'
                'b2Zmc2V0LCBvZmZzZXQgKyBjaHVua1NpemUpKTsNCiAgICB9DQogICAgcmV0dXJuIGJ0b2EoYmluYXJ5KTsNCn0NCg0KZnVuY3Rpb24gYnVpbGREb3dubG9h'
                'ZFJlcG9ydChzdW1tYXJ5OiBEb3dubG9hZFN1bW1hcnkpOiBzdHJpbmcgew0KICAgIGNvbnN0IGxpbmVzID0gWw0KICAgICAgICAiRXF1aWNvcmQgRXhwb3J0'
                'RE0gZG93bmxvYWQgcmVwb3J0IiwNCiAgICAgICAgIiIsDQogICAgICAgIGBEb3dubG9hZGVkIGFzc2V0czogJHtzdW1tYXJ5LmRvd25sb2FkZWQubGVuZ3Ro'
                'fWAsDQogICAgICAgIGBEb3dubG9hZGVkIGJ5dGVzOiAke3N1bW1hcnkuZG93bmxvYWRlZEJ5dGVzfWAsDQogICAgICAgIGBGYWlsZWQgYXNzZXRzOiAke3N1'
                'bW1hcnkuZmFpbHVyZXMubGVuZ3RofWAsDQogICAgICAgICIiDQogICAgXTsNCiAgICBpZiAoc3VtbWFyeS5mYWlsdXJlcy5sZW5ndGgpIHsNCiAgICAgICAg'
                'bGluZXMucHVzaCgiRmFpbHVyZXM6Iik7DQogICAgICAgIHN1bW1hcnkuZmFpbHVyZXMuZm9yRWFjaChmYWlsdXJlID0+IGxpbmVzLnB1c2goYC0gJHtmYWls'
                'dXJlLnBhdGh9IHwgJHtmYWlsdXJlLm9yaWdpbmFsVXJsfSB8ICR7ZmFpbHVyZS5lcnJvciA/PyAiVW5rbm93biBlcnJvciJ9YCkpOw0KICAgIH0gZWxzZSB7'
                'DQogICAgICAgIGxpbmVzLnB1c2goIkFsbCByZXF1ZXN0ZWQgYXNzZXRzIHdlcmUgZG93bmxvYWRlZCBzdWNjZXNzZnVsbHkuIik7DQogICAgfQ0KICAgIHJl'
                'dHVybiBsaW5lcy5qb2luKCJcclxuIik7DQp9DQoNCmZ1bmN0aW9uIGNyZWF0ZU9mZmxpbmVBcmNoaXZlKA0KICAgIG1lc3NhZ2VzOiBhbnlbXSwNCiAgICBj'
                'aGFubmVsTmFtZTogc3RyaW5nLA0KICAgIG9wdGlvbnM6IEV4cG9ydE9wdGlvbnMsDQogICAgc3VtbWFyeTogRG93bmxvYWRTdW1tYXJ5LA0KICAgIGV4cG9y'
                'dGVkQXQgPSBuZXcgRGF0ZSgpLnRvSVNPU3RyaW5nKCkNCik6IEFyY2hpdmVCdWlsZFJlc3VsdCB7DQogICAgY29uc3QgaHRtbCA9IHJlbmRlckNvbnZlcnNh'
                'dGlvbkh0bWwobWVzc2FnZXMsIGNoYW5uZWxOYW1lLCAiYXJjaGl2ZSIsIHN1bW1hcnkuYWxpYXNlcyk7DQogICAgY29uc3QgcmVwb3J0ID0gYnVpbGREb3du'
                'bG9hZFJlcG9ydChzdW1tYXJ5KTsNCiAgICBjb25zdCBtYW5pZmVzdCA9IHsNCiAgICAgICAgZm9ybWF0OiAiRXF1aWNvcmQgRXhwb3J0RE0gT2ZmbGluZSBB'
                'cmNoaXZlIiwNCiAgICAgICAgdmVyc2lvbjogMSwNCiAgICAgICAgY2hhbm5lbDogY2hhbm5lbE5hbWUsDQogICAgICAgIGV4cG9ydGVkQXQsDQogICAgICAg'
                'IG1lc3NhZ2VDb3VudDogbWVzc2FnZXMubGVuZ3RoLA0KICAgICAgICBvcHRpb25zLA0KICAgICAgICBkb3dubG9hZGVkQnl0ZXM6IHN1bW1hcnkuZG93bmxv'
                'YWRlZEJ5dGVzLA0KICAgICAgICBkb3dubG9hZGVkQXNzZXRzOiBzdW1tYXJ5LmRvd25sb2FkZWQubWFwKGFzc2V0ID0+ICh7IHBhdGg6IGFzc2V0LnBhdGgs'
                'IGNvbnRlbnRUeXBlOiBhc3NldC5jb250ZW50VHlwZSwgc2l6ZTogYXNzZXQuYnl0ZXM/LmJ5dGVMZW5ndGggPz8gMCwgb3JpZ2luYWxVcmw6IGFzc2V0Lm9y'
                'aWdpbmFsVXJsIH0pKSwNCiAgICAgICAgZmFpbGVkQXNzZXRzOiBzdW1tYXJ5LmZhaWx1cmVzLm1hcChhc3NldCA9PiAoeyBwYXRoOiBhc3NldC5wYXRoLCBv'
                'cmlnaW5hbFVybDogYXNzZXQub3JpZ2luYWxVcmwsIGVycm9yOiBhc3NldC5lcnJvciB9KSkNCiAgICB9Ow0KICAgIGNvbnN0IGZpbGVzOiBaaXBwYWJsZSA9'
                'IHsNCiAgICAgICAgImluZGV4Lmh0bWwiOiBbc3RyVG9VOChodG1sKSwgeyBsZXZlbDogNiB9XSwNCiAgICAgICAgIm1lc3NhZ2VzLmpzb24iOiBbc3RyVG9V'
                'OChyYXdKc29uKG1lc3NhZ2VzLCBjaGFubmVsTmFtZSwgZXhwb3J0ZWRBdCkpLCB7IGxldmVsOiA2IH1dLA0KICAgICAgICAibWFuaWZlc3QuanNvbiI6IFtz'
                'dHJUb1U4KEpTT04uc3RyaW5naWZ5KG1hbmlmZXN0LCBudWxsLCAyKSksIHsgbGV2ZWw6IDYgfV0sDQogICAgICAgICJkb3dubG9hZC1yZXBvcnQudHh0Ijog'
                'W3N0clRvVTgocmVwb3J0KSwgeyBsZXZlbDogNiB9XSwNCiAgICAgICAgImFzc2V0cy9hdHRhY2htZW50cy8iOiBuZXcgVWludDhBcnJheSgpLA0KICAgICAg'
                'ICAiYXNzZXRzL2F2YXRhcnMvIjogbmV3IFVpbnQ4QXJyYXkoKSwNCiAgICAgICAgImFzc2V0cy9lbW9qaXMvIjogbmV3IFVpbnQ4QXJyYXkoKSwNCiAgICAg'
                'ICAgImFzc2V0cy9zdGlja2Vycy8iOiBuZXcgVWludDhBcnJheSgpLA0KICAgICAgICAiYXNzZXRzL2VtYmVkcy8iOiBuZXcgVWludDhBcnJheSgpDQogICAg'
                'fTsNCiAgICBmb3IgKGNvbnN0IGFzc2V0IG9mIHN1bW1hcnkuZG93bmxvYWRlZCkgew0KICAgICAgICBpZiAoYXNzZXQuYnl0ZXMpIGZpbGVzW2Fzc2V0LnBh'
                'dGhdID0gW2Fzc2V0LmJ5dGVzLCB7IGxldmVsOiAwIH1dOw0KICAgIH0NCiAgICByZXR1cm4geyBieXRlczogemlwU3luYyhmaWxlcywgeyBsZXZlbDogNiB9'
                'KSwgaHRtbCwgbWFuaWZlc3QsIHJlcG9ydCB9Ow0KfQ0KDQpmdW5jdGlvbiBjcmVhdGVTaW5nbGVIdG1sKG1lc3NhZ2VzOiBhbnlbXSwgY2hhbm5lbE5hbWU6'
                'IHN0cmluZywgc3VtbWFyeTogRG93bmxvYWRTdW1tYXJ5KTogc3RyaW5nIHsNCiAgICBjb25zdCBlbWJlZGRlZEFzc2V0czogRW1iZWRkZWRBc3NldFBheWxv'
                'YWQgPSB7IGFsaWFzZXM6IHt9LCBkYXRhOiB7fSB9Ow0KICAgIGZvciAoY29uc3QgW2FsaWFzLCByZXN1bHRdIG9mIHN1bW1hcnkuYWxpYXNlcykgew0KICAg'
                'ICAgICBpZiAoIXJlc3VsdC5ieXRlcyB8fCByZXN1bHQuZXJyb3IpIGNvbnRpbnVlOw0KICAgICAgICBpZiAoIWVtYmVkZGVkQXNzZXRzLmRhdGFbcmVzdWx0'
                'LnBhdGhdKSB7DQogICAgICAgICAgICBlbWJlZGRlZEFzc2V0cy5kYXRhW3Jlc3VsdC5wYXRoXSA9IGBkYXRhOiR7cmVzdWx0LmNvbnRlbnRUeXBlIHx8ICJh'
                'cHBsaWNhdGlvbi9vY3RldC1zdHJlYW0ifTtiYXNlNjQsJHtieXRlc1RvQmFzZTY0KHJlc3VsdC5ieXRlcyl9YDsNCiAgICAgICAgfQ0KICAgICAgICBlbWJl'
                'ZGRlZEFzc2V0cy5hbGlhc2VzW2FsaWFzXSA9IHJlc3VsdC5wYXRoOw0KICAgIH0NCiAgICByZXR1cm4gcmVuZGVyQ29udmVyc2F0aW9uSHRtbChtZXNzYWdl'
                'cywgY2hhbm5lbE5hbWUsICJzaW5nbGUiLCBzdW1tYXJ5LmFsaWFzZXMsIGVtYmVkZGVkQXNzZXRzKTsNCn0NCg0KZnVuY3Rpb24gcmV0YWluU2tpcHBlZEFz'
                'c2V0TGlua3MoYWxsQXNzZXRzOiBBc3NldENhdGFsb2csIHN1bW1hcnk6IERvd25sb2FkU3VtbWFyeSkgew0KICAgIGZvciAoY29uc3QgW2FsaWFzLCByZXF1'
                'ZXN0XSBvZiBhbGxBc3NldHMuYWxpYXNlcykgew0KICAgICAgICBpZiAoc3VtbWFyeS5hbGlhc2VzLmhhcyhhbGlhcykpIGNvbnRpbnVlOw0KICAgICAgICBz'
                'dW1tYXJ5LmFsaWFzZXMuc2V0KGFsaWFzLCB7DQogICAgICAgICAgICBjb250ZW50VHlwZTogIiIsDQogICAgICAgICAgICBlcnJvcjogIk5vdCBpbmNsdWRl'
                'ZCBieSB0aGUgc2VsZWN0ZWQgbWVkaWEgb3B0aW9ucy4iLA0KICAgICAgICAgICAga2luZDogcmVxdWVzdC5raW5kLA0KICAgICAgICAgICAgb3JpZ2luYWxV'
                'cmw6IHJlcXVlc3Qub3JpZ2luYWxVcmwsDQogICAgICAgICAgICBwYXRoOiByZXF1ZXN0LnBhdGgNCiAgICAgICAgfSk7DQogICAgfQ0KfQ0KDQpmdW5jdGlv'
                'biBjcmVhdGVPbmxpbmVBbGlhc2VzKGNhdGFsb2c6IEFzc2V0Q2F0YWxvZyk6IE1hcDxzdHJpbmcsIEFzc2V0UmVzdWx0PiB7DQogICAgY29uc3QgYWxpYXNl'
                'cyA9IG5ldyBNYXA8c3RyaW5nLCBBc3NldFJlc3VsdD4oKTsNCiAgICBmb3IgKGNvbnN0IFthbGlhcywgcmVxdWVzdF0gb2YgY2F0YWxvZy5hbGlhc2VzKSB7'
                'DQogICAgICAgIGFsaWFzZXMuc2V0KGFsaWFzLCB7IGNvbnRlbnRUeXBlOiAiIiwga2luZDogcmVxdWVzdC5raW5kLCBvcmlnaW5hbFVybDogcmVxdWVzdC5v'
                'cmlnaW5hbFVybCwgcGF0aDogcmVxdWVzdC5wYXRoIH0pOw0KICAgIH0NCiAgICByZXR1cm4gYWxpYXNlczsNCn0NCg0KZnVuY3Rpb24gZG93bmxvYWRCbG9i'
                'KGNvbnRlbnQ6IEJsb2JQYXJ0LCBmaWxlbmFtZTogc3RyaW5nLCBtaW1lOiBzdHJpbmcpIHsNCiAgICBjb25zdCBibG9iID0gbmV3IEJsb2IoW2NvbnRlbnRd'
                'LCB7IHR5cGU6IG1pbWUgfSk7DQogICAgY29uc3QgdXJsID0gVVJMLmNyZWF0ZU9iamVjdFVSTChibG9iKTsNCiAgICBjb25zdCBsaW5rID0gZG9jdW1lbnQu'
                'Y3JlYXRlRWxlbWVudCgiYSIpOw0KICAgIGxpbmsuaHJlZiA9IHVybDsNCiAgICBsaW5rLmRvd25sb2FkID0gZmlsZW5hbWU7DQogICAgZG9jdW1lbnQuYm9k'
                'eS5hcHBlbmRDaGlsZChsaW5rKTsNCiAgICBsaW5rLmNsaWNrKCk7DQogICAgbGluay5yZW1vdmUoKTsNCiAgICB3aW5kb3cuc2V0VGltZW91dCgoKSA9PiBV'
                'UkwucmV2b2tlT2JqZWN0VVJMKHVybCksIDEwMDApOw0KfQ0KDQpmdW5jdGlvbiBjb252ZXJzYXRpb25TdW1tYXJ5KG1lc3NhZ2VzOiBhbnlbXSkgew0KICAg'
                'IGxldCBhdHRhY2htZW50Q291bnQgPSAwOw0KICAgIGxldCBrbm93bkJ5dGVzID0gMDsNCiAgICBmb3IgKGNvbnN0IG1lc3NhZ2Ugb2YgbWVzc2FnZXMpIHsN'
                'CiAgICAgICAgZm9yIChjb25zdCBhdHRhY2htZW50IG9mIEFycmF5LmlzQXJyYXkobWVzc2FnZT8uYXR0YWNobWVudHMpID8gbWVzc2FnZS5hdHRhY2htZW50'
                'cyA6IFtdKSB7DQogICAgICAgICAgICBhdHRhY2htZW50Q291bnQrKzsNCiAgICAgICAgICAgIGNvbnN0IHNpemUgPSBOdW1iZXIoYXR0YWNobWVudD8uc2l6'
                'ZSA/PyAwKTsNCiAgICAgICAgICAgIGlmIChOdW1iZXIuaXNGaW5pdGUoc2l6ZSkgJiYgc2l6ZSA+IDApIGtub3duQnl0ZXMgKz0gc2l6ZTsNCiAgICAgICAg'
                'fQ0KICAgIH0NCiAgICBjb25zdCBtZXNzYWdlQnl0ZXMgPSBuZXcgVGV4dEVuY29kZXIoKS5lbmNvZGUoSlNPTi5zdHJpbmdpZnkobWVzc2FnZXMpKS5ieXRl'
                'TGVuZ3RoOw0KICAgIGNvbnN0IGVzdGltYXRlZFNpbmdsZUh0bWxCeXRlcyA9IG1lc3NhZ2VCeXRlcyArIE1hdGguY2VpbChrbm93bkJ5dGVzIC8gMykgKiA0'
                'Ow0KICAgIHJldHVybiB7IGF0dGFjaG1lbnRDb3VudCwgZXN0aW1hdGVkU2luZ2xlSHRtbEJ5dGVzLCBrbm93bkJ5dGVzLCBtZXNzYWdlQ291bnQ6IG1lc3Nh'
                'Z2VzLmxlbmd0aCB9Ow0KfQ0KDQpmdW5jdGlvbiBFeHBvcnRNb2RhbCh7IHJvb3RQcm9wcywgY2hhbm5lbElkIH06IHsgcm9vdFByb3BzOiBSZW5kZXJNb2Rh'
                'bFByb3BzOyBjaGFubmVsSWQ6IHN0cmluZzsgfSkgew0KICAgIGNvbnN0IFtmb3JtYXQsIHNldEZvcm1hdF0gPSB1c2VTdGF0ZTxFeHBvcnRGb3JtYXQ+KCJv'
                'ZmZsaW5lQXJjaGl2ZSIpOw0KICAgIGNvbnN0IFtvcHRpb25zLCBzZXRPcHRpb25zXSA9IHVzZVN0YXRlPEV4cG9ydE9wdGlvbnM+KERFRkFVTFRfT1BUSU9O'
                'Uyk7DQogICAgY29uc3QgW21lc3NhZ2VzLCBzZXRNZXNzYWdlc10gPSB1c2VTdGF0ZTxhbnlbXSB8IG51bGw+KG51bGwpOw0KICAgIGNvbnN0IFtzdGF0dXMs'
                'IHNldFN0YXR1c10gPSB1c2VTdGF0ZSgiIik7DQogICAgY29uc3QgW2J1c3ksIHNldEJ1c3ldID0gdXNlU3RhdGUoZmFsc2UpOw0KICAgIGNvbnN0IFtwcm9n'
                'cmVzcywgc2V0UHJvZ3Jlc3NdID0gdXNlU3RhdGU8RXhwb3J0UHJvZ3Jlc3M+KHsgc3RhZ2U6ICIiLCBwcm9jZXNzZWQ6IDAsIHRvdGFsOiAwLCBkb3dubG9h'
                'ZGVkQnl0ZXM6IDAsIGZhaWx1cmVzOiAwIH0pOw0KICAgIGNvbnN0IGNvbnRyb2xsZXJSZWYgPSBSZWFjdC51c2VSZWY8QWJvcnRDb250cm9sbGVyIHwgbnVs'
                'bD4obnVsbCk7DQogICAgY29uc3QgY2hhbm5lbCA9IENoYW5uZWxTdG9yZS5nZXRDaGFubmVsKGNoYW5uZWxJZCk7DQogICAgY29uc3QgY2hhbm5lbE5hbWUg'
                'PSBjaGFubmVsPy5uYW1lID8/IGNoYW5uZWxJZDsNCiAgICBjb25zdCBvZmZsaW5lID0gZm9ybWF0ID09PSAib2ZmbGluZUFyY2hpdmUiIHx8IGZvcm1hdCA9'
                'PT0gInNpbmdsZUh0bWwiOw0KICAgIGNvbnN0IHN1bW1hcnkgPSBtZXNzYWdlcyA/IGNvbnZlcnNhdGlvblN1bW1hcnkobWVzc2FnZXMpIDogbnVsbDsNCg0K'
                'ICAgIFJlYWN0LnVzZUVmZmVjdCgoKSA9PiAoKSA9PiBjb250cm9sbGVyUmVmLmN1cnJlbnQ/LmFib3J0KCksIFtdKTsNCg0KICAgIGZ1bmN0aW9uIGJlZ2lu'
                'T3BlcmF0aW9uKHN0YWdlOiBzdHJpbmcpIHsNCiAgICAgICAgY29udHJvbGxlclJlZi5jdXJyZW50Py5hYm9ydCgpOw0KICAgICAgICBjb25zdCBjb250cm9s'
                'bGVyID0gbmV3IEFib3J0Q29udHJvbGxlcigpOw0KICAgICAgICBjb250cm9sbGVyUmVmLmN1cnJlbnQgPSBjb250cm9sbGVyOw0KICAgICAgICBzZXRCdXN5'
                'KHRydWUpOw0KICAgICAgICBzZXRTdGF0dXMoIiIpOw0KICAgICAgICBzZXRQcm9ncmVzcyh7IHN0YWdlLCBwcm9jZXNzZWQ6IDAsIHRvdGFsOiAwLCBkb3du'
                'bG9hZGVkQnl0ZXM6IDAsIGZhaWx1cmVzOiAwIH0pOw0KICAgICAgICByZXR1cm4gY29udHJvbGxlcjsNCiAgICB9DQoNCiAgICBmdW5jdGlvbiBmaW5pc2hP'
                'cGVyYXRpb24oY29udHJvbGxlcjogQWJvcnRDb250cm9sbGVyKSB7DQogICAgICAgIGlmIChjb250cm9sbGVyUmVmLmN1cnJlbnQgPT09IGNvbnRyb2xsZXIp'
                'IGNvbnRyb2xsZXJSZWYuY3VycmVudCA9IG51bGw7DQogICAgICAgIHNldEJ1c3koZmFsc2UpOw0KICAgIH0NCg0KICAgIGFzeW5jIGZ1bmN0aW9uIHByZXBh'
                'cmVNZXNzYWdlcygpIHsNCiAgICAgICAgaWYgKGJ1c3kpIHJldHVybjsNCiAgICAgICAgY29uc3QgY29udHJvbGxlciA9IGJlZ2luT3BlcmF0aW9uKCJGZXRj'
                'aGluZyBtZXNzYWdlcyIpOw0KICAgICAgICB0cnkgew0KICAgICAgICAgICAgY29uc3QgY29sbGVjdGVkID0gYXdhaXQgZmV0Y2hBbGxNZXNzYWdlcyhjaGFu'
                'bmVsSWQsIGNvbnRyb2xsZXIuc2lnbmFsLCBjb3VudCA9PiB7DQogICAgICAgICAgICAgICAgc2V0UHJvZ3Jlc3MoeyBzdGFnZTogIkZldGNoaW5nIG1lc3Nh'
                'Z2VzIiwgcHJvY2Vzc2VkOiBjb3VudCwgdG90YWw6IDAsIGRvd25sb2FkZWRCeXRlczogMCwgZmFpbHVyZXM6IDAgfSk7DQogICAgICAgICAgICB9KTsNCiAg'
                'ICAgICAgICAgIHRocm93SWZBYm9ydGVkKGNvbnRyb2xsZXIuc2lnbmFsKTsNCiAgICAgICAgICAgIHNldE1lc3NhZ2VzKGNvbGxlY3RlZCk7DQogICAgICAg'
                'ICAgICBzZXRQcm9ncmVzcyh7IHN0YWdlOiAiUmVhZHkiLCBwcm9jZXNzZWQ6IDAsIHRvdGFsOiAwLCBkb3dubG9hZGVkQnl0ZXM6IDAsIGZhaWx1cmVzOiAw'
                'IH0pOw0KICAgICAgICAgICAgc2V0U3RhdHVzKGBSZWFkeSB0byBleHBvcnQgJHtjb2xsZWN0ZWQubGVuZ3RofSBtZXNzYWdlJHtjb2xsZWN0ZWQubGVuZ3Ro'
                'ID09PSAxID8gIiIgOiAicyJ9LmApOw0KICAgICAgICB9IGNhdGNoIChlcnJvcikgew0KICAgICAgICAgICAgaWYgKGlzQWJvcnRFcnJvcihlcnJvcikpIHsN'
                'CiAgICAgICAgICAgICAgICBzZXRQcm9ncmVzcyh7IHN0YWdlOiAiQ2FuY2VsbGVkIiwgcHJvY2Vzc2VkOiAwLCB0b3RhbDogMCwgZG93bmxvYWRlZEJ5dGVz'
                'OiAwLCBmYWlsdXJlczogMCB9KTsNCiAgICAgICAgICAgICAgICBzZXRTdGF0dXMoIlByZXBhcmF0aW9uIGNhbmNlbGxlZC4iKTsNCiAgICAgICAgICAgIH0g'
                'ZWxzZSB7DQogICAgICAgICAgICAgICAgc2V0UHJvZ3Jlc3MoeyBzdGFnZTogIkZhaWxlZCIsIHByb2Nlc3NlZDogMCwgdG90YWw6IDAsIGRvd25sb2FkZWRC'
                'eXRlczogMCwgZmFpbHVyZXM6IDAgfSk7DQogICAgICAgICAgICAgICAgc2V0U3RhdHVzKGBDb3VsZCBub3QgZmV0Y2ggbWVzc2FnZXM6ICR7ZXJyb3IgaW5z'
                'dGFuY2VvZiBFcnJvciA/IGVycm9yLm1lc3NhZ2UgOiBTdHJpbmcoZXJyb3IpfWApOw0KICAgICAgICAgICAgfQ0KICAgICAgICB9IGZpbmFsbHkgew0KICAg'
                'ICAgICAgICAgZmluaXNoT3BlcmF0aW9uKGNvbnRyb2xsZXIpOw0KICAgICAgICB9DQogICAgfQ0KDQogICAgYXN5bmMgZnVuY3Rpb24gY3JlYXRlRXhwb3J0'
                'KCkgew0KICAgICAgICBpZiAoYnVzeSB8fCAhbWVzc2FnZXMpIHJldHVybjsNCiAgICAgICAgaWYgKGZvcm1hdCA9PT0gInNpbmdsZUh0bWwiICYmIChzdW1t'
                'YXJ5Py5lc3RpbWF0ZWRTaW5nbGVIdG1sQnl0ZXMgPz8gMCkgPj0gU0lOR0xFX0hUTUxfV0FSTklOR19CWVRFUykgew0KICAgICAgICAgICAgY29uc3QgcHJv'
                'Y2VlZCA9IHdpbmRvdy5jb25maXJtKGBTaW5nbGUgSFRNTCBpcyBlc3RpbWF0ZWQgYXQgbGVhc3QgJHtmb3JtYXRCeXRlcyhzdW1tYXJ5Py5lc3RpbWF0ZWRT'
                'aW5nbGVIdG1sQnl0ZXMpfSBmcm9tIGtub3duIG1lc3NhZ2VzIGFuZCBhdHRhY2htZW50cy4gSXQgbWF5IGJlIHZlcnkgbGFyZ2Ugb3Igc2xvdy4gT2ZmbGlu'
                'ZSBBcmNoaXZlIGlzIHJlY29tbWVuZGVkLiBDb250aW51ZSBhbnl3YXk/YCk7DQogICAgICAgICAgICBpZiAoIXByb2NlZWQpIHsNCiAgICAgICAgICAgICAg'
                'ICBzZXRTdGF0dXMoIlNpbmdsZSBIVE1MIGV4cG9ydCBjYW5jZWxsZWQgYmVmb3JlIGRvd25sb2FkaW5nIG1lZGlhLiIpOw0KICAgICAgICAgICAgICAgIHJl'
                'dHVybjsNCiAgICAgICAgICAgIH0NCiAgICAgICAgfQ0KDQogICAgICAgIGNvbnN0IGNvbnRyb2xsZXIgPSBiZWdpbk9wZXJhdGlvbihmb3JtYXQgPT09ICJq'
                'c29uIiB8fCBmb3JtYXQgPT09ICJvbmxpbmVIdG1sIiA/ICJCdWlsZGluZyBkb2N1bWVudCIgOiAiUHJlcGFyaW5nIG1lZGlhIGxpc3QiKTsNCiAgICAgICAg'
                'dHJ5IHsNCiAgICAgICAgICAgIGNvbnN0IGJhc2VOYW1lID0gYCR7c2FmZUZpbGVuYW1lKGNoYW5uZWxOYW1lKX0tZXhwb3J0YDsNCiAgICAgICAgICAgIGlm'
                'IChmb3JtYXQgPT09ICJqc29uIikgew0KICAgICAgICAgICAgICAgIGRvd25sb2FkQmxvYihyYXdKc29uKG1lc3NhZ2VzLCBjaGFubmVsTmFtZSksIGAke2Jh'
                'c2VOYW1lfS5qc29uYCwgImFwcGxpY2F0aW9uL2pzb247Y2hhcnNldD11dGYtOCIpOw0KICAgICAgICAgICAgfSBlbHNlIHsNCiAgICAgICAgICAgICAgICBj'
                'b25zdCBjYXRhbG9nID0gY29sbGVjdEFzc2V0UmVxdWVzdHMobWVzc2FnZXMsIG9mZmxpbmUgPyBvcHRpb25zIDogREVGQVVMVF9PUFRJT05TKTsNCiAgICAg'
                'ICAgICAgICAgICBpZiAoZm9ybWF0ID09PSAib25saW5lSHRtbCIpIHsNCiAgICAgICAgICAgICAgICAgICAgY29uc3QgaHRtbCA9IHJlbmRlckNvbnZlcnNh'
                'dGlvbkh0bWwobWVzc2FnZXMsIGNoYW5uZWxOYW1lLCAib25saW5lIiwgY3JlYXRlT25saW5lQWxpYXNlcyhjYXRhbG9nKSk7DQogICAgICAgICAgICAgICAg'
                'ICAgIHRocm93SWZBYm9ydGVkKGNvbnRyb2xsZXIuc2lnbmFsKTsNCiAgICAgICAgICAgICAgICAgICAgZG93bmxvYWRCbG9iKGh0bWwsIGAke2Jhc2VOYW1l'
                'fS1vbmxpbmUuaHRtbGAsICJ0ZXh0L2h0bWw7Y2hhcnNldD11dGYtOCIpOw0KICAgICAgICAgICAgICAgIH0gZWxzZSB7DQogICAgICAgICAgICAgICAgICAg'
                'IHNldFByb2dyZXNzKHsgc3RhZ2U6ICJEb3dubG9hZGluZyBtZWRpYSIsIHByb2Nlc3NlZDogMCwgdG90YWw6IGNhdGFsb2cucmVxdWVzdHMubGVuZ3RoLCBk'
                'b3dubG9hZGVkQnl0ZXM6IDAsIGZhaWx1cmVzOiAwIH0pOw0KICAgICAgICAgICAgICAgICAgICBjb25zdCBhc3NldHMgPSBhd2FpdCBkb3dubG9hZEFzc2V0'
                'UmVxdWVzdHMoY2F0YWxvZywgY29udHJvbGxlci5zaWduYWwsIHNldFByb2dyZXNzKTsNCiAgICAgICAgICAgICAgICAgICAgcmV0YWluU2tpcHBlZEFzc2V0'
                'TGlua3MoY29sbGVjdEFzc2V0UmVxdWVzdHMobWVzc2FnZXMsIERFRkFVTFRfT1BUSU9OUyksIGFzc2V0cyk7DQogICAgICAgICAgICAgICAgICAgIHRocm93'
                'SWZBYm9ydGVkKGNvbnRyb2xsZXIuc2lnbmFsKTsNCiAgICAgICAgICAgICAgICAgICAgc2V0UHJvZ3Jlc3MoY3VycmVudCA9PiAoeyAuLi5jdXJyZW50LCBz'
                'dGFnZTogZm9ybWF0ID09PSAib2ZmbGluZUFyY2hpdmUiID8gIkJ1aWxkaW5nIFpJUCBhcmNoaXZlIiA6ICJCdWlsZGluZyBzZWxmLWNvbnRhaW5lZCBIVE1M'
                'IiB9KSk7DQogICAgICAgICAgICAgICAgICAgIGF3YWl0IGRlbGF5KDAsIGNvbnRyb2xsZXIuc2lnbmFsKTsNCiAgICAgICAgICAgICAgICAgICAgaWYgKGZv'
                'cm1hdCA9PT0gIm9mZmxpbmVBcmNoaXZlIikgew0KICAgICAgICAgICAgICAgICAgICAgICAgY29uc3QgYXJjaGl2ZSA9IGNyZWF0ZU9mZmxpbmVBcmNoaXZl'
                'KG1lc3NhZ2VzLCBjaGFubmVsTmFtZSwgb3B0aW9ucywgYXNzZXRzKTsNCiAgICAgICAgICAgICAgICAgICAgICAgIHRocm93SWZBYm9ydGVkKGNvbnRyb2xs'
                'ZXIuc2lnbmFsKTsNCiAgICAgICAgICAgICAgICAgICAgICAgIGRvd25sb2FkQmxvYihhcmNoaXZlLmJ5dGVzIGFzIEJsb2JQYXJ0LCBgJHtiYXNlTmFtZX0t'
                'b2ZmbGluZS56aXBgLCAiYXBwbGljYXRpb24vemlwIik7DQogICAgICAgICAgICAgICAgICAgIH0gZWxzZSB7DQogICAgICAgICAgICAgICAgICAgICAgICBj'
                'b25zdCBodG1sID0gY3JlYXRlU2luZ2xlSHRtbChtZXNzYWdlcywgY2hhbm5lbE5hbWUsIGFzc2V0cyk7DQogICAgICAgICAgICAgICAgICAgICAgICB0aHJv'
                'd0lmQWJvcnRlZChjb250cm9sbGVyLnNpZ25hbCk7DQogICAgICAgICAgICAgICAgICAgICAgICBkb3dubG9hZEJsb2IoaHRtbCwgYCR7YmFzZU5hbWV9LXNp'
                'bmdsZS5odG1sYCwgInRleHQvaHRtbDtjaGFyc2V0PXV0Zi04Iik7DQogICAgICAgICAgICAgICAgICAgIH0NCiAgICAgICAgICAgICAgICAgICAgY29uc3Qg'
                'Y29tcGxldGlvbiA9IGFzc2V0cy5mYWlsdXJlcy5sZW5ndGggPyAiUGFydGlhbCBjb21wbGV0aW9uIiA6ICJDb21wbGV0ZSI7DQogICAgICAgICAgICAgICAg'
                'ICAgIHNldFByb2dyZXNzKGN1cnJlbnQgPT4gKHsgLi4uY3VycmVudCwgc3RhZ2U6IGNvbXBsZXRpb24gfSkpOw0KICAgICAgICAgICAgICAgICAgICBzZXRT'
                'dGF0dXMoYCR7Y29tcGxldGlvbn06ICR7bWVzc2FnZXMubGVuZ3RofSBtZXNzYWdlcywgJHthc3NldHMuZG93bmxvYWRlZC5sZW5ndGh9IGFzc2V0cyBkb3du'
                'bG9hZGVkLCAke2Fzc2V0cy5mYWlsdXJlcy5sZW5ndGh9IGZhaWxlZC4gT2ZmbGluZSBmYWlsdXJlcyBhcmUgc2hvd24gaW4gdGhlIHRyYW5zY3JpcHQke2Zv'
                'cm1hdCA9PT0gIm9mZmxpbmVBcmNoaXZlIiA/ICIgYW5kIGRvd25sb2FkLXJlcG9ydC50eHQiIDogIiJ9LmApOw0KICAgICAgICAgICAgICAgICAgICByZXR1'
                'cm47DQogICAgICAgICAgICAgICAgfQ0KICAgICAgICAgICAgfQ0KICAgICAgICAgICAgc2V0UHJvZ3Jlc3MoY3VycmVudCA9PiAoeyAuLi5jdXJyZW50LCBz'
                'dGFnZTogIkNvbXBsZXRlIiB9KSk7DQogICAgICAgICAgICBzZXRTdGF0dXMoYENvbXBsZXRlOiAke21lc3NhZ2VzLmxlbmd0aH0gbWVzc2FnZSR7bWVzc2Fn'
                'ZXMubGVuZ3RoID09PSAxID8gIiIgOiAicyJ9IGV4cG9ydGVkLmApOw0KICAgICAgICB9IGNhdGNoIChlcnJvcikgew0KICAgICAgICAgICAgaWYgKGlzQWJv'
                'cnRFcnJvcihlcnJvcikpIHsNCiAgICAgICAgICAgICAgICBzZXRQcm9ncmVzcyhjdXJyZW50ID0+ICh7IC4uLmN1cnJlbnQsIHN0YWdlOiAiQ2FuY2VsbGVk'
                'IiB9KSk7DQogICAgICAgICAgICAgICAgc2V0U3RhdHVzKCJFeHBvcnQgY2FuY2VsbGVkLiBObyBjb21wbGV0ZWQgZG93bmxvYWQgd2FzIGNyZWF0ZWQuIik7'
                'DQogICAgICAgICAgICB9IGVsc2Ugew0KICAgICAgICAgICAgICAgIHNldFByb2dyZXNzKGN1cnJlbnQgPT4gKHsgLi4uY3VycmVudCwgc3RhZ2U6ICJGYWls'
                'ZWQiIH0pKTsNCiAgICAgICAgICAgICAgICBzZXRTdGF0dXMoYEV4cG9ydCBmYWlsZWQ6ICR7ZXJyb3IgaW5zdGFuY2VvZiBFcnJvciA/IGVycm9yLm1lc3Nh'
                'Z2UgOiBTdHJpbmcoZXJyb3IpfWApOw0KICAgICAgICAgICAgfQ0KICAgICAgICB9IGZpbmFsbHkgew0KICAgICAgICAgICAgZmluaXNoT3BlcmF0aW9uKGNv'
                'bnRyb2xsZXIpOw0KICAgICAgICB9DQogICAgfQ0KDQogICAgZnVuY3Rpb24gdXBkYXRlT3B0aW9uKGtleToga2V5b2YgRXhwb3J0T3B0aW9ucywgY2hlY2tl'
                'ZDogYm9vbGVhbikgew0KICAgICAgICBzZXRPcHRpb25zKGN1cnJlbnQgPT4gKHsgLi4uY3VycmVudCwgW2tleV06IGNoZWNrZWQgfSkpOw0KICAgIH0NCg0K'
                'ICAgIGNvbnN0IHByb2dyZXNzUGVyY2VudCA9IHByb2dyZXNzLnRvdGFsID4gMCA/IE1hdGgubWluKDEwMCwgcHJvZ3Jlc3MucHJvY2Vzc2VkIC8gcHJvZ3Jl'
                'c3MudG90YWwgKiAxMDApIDogMDsNCiAgICByZXR1cm4gKA0KICAgICAgICA8TW9kYWwgey4uLnJvb3RQcm9wc30gc2l6ZT0ibWVkaXVtIiB0aXRsZT17YEV4'
                'cG9ydCAtICR7Y2hhbm5lbE5hbWV9YH0+DQogICAgICAgICAgICA8c3R5bGU+e0VYUE9SVF9NT0RBTF9DU1N9PC9zdHlsZT4NCiAgICAgICAgICAgIDxkaXYg'
                'Y2xhc3NOYW1lPSJlcS1leHBvcnQtbW9kYWwiPg0KICAgICAgICAgICAgICAgIDxkaXYgY2xhc3NOYW1lPSJlcS1leHBvcnQtZm9ybWF0LWdyaWQiIHJvbGU9'
                'InJhZGlvZ3JvdXAiIGFyaWEtbGFiZWw9IkV4cG9ydCBmb3JtYXQiPg0KICAgICAgICAgICAgICAgICAgICB7Rk9STUFUX0NIT0lDRVMubWFwKGNob2ljZSA9'
                'PiAoDQogICAgICAgICAgICAgICAgICAgICAgICA8YnV0dG9uDQogICAgICAgICAgICAgICAgICAgICAgICAgICAga2V5PXtjaG9pY2UuaWR9DQogICAgICAg'
                'ICAgICAgICAgICAgICAgICAgICAgdHlwZT0iYnV0dG9uIg0KICAgICAgICAgICAgICAgICAgICAgICAgICAgIHJvbGU9InJhZGlvIg0KICAgICAgICAgICAg'
                'ICAgICAgICAgICAgICAgIGFyaWEtY2hlY2tlZD17Zm9ybWF0ID09PSBjaG9pY2UuaWR9DQogICAgICAgICAgICAgICAgICAgICAgICAgICAgY2xhc3NOYW1l'
                'PXtgZXEtZXhwb3J0LWZvcm1hdCR7Zm9ybWF0ID09PSBjaG9pY2UuaWQgPyAiIGVxLWV4cG9ydC1mb3JtYXQtLXNlbGVjdGVkIiA6ICIifWB9DQogICAgICAg'
                'ICAgICAgICAgICAgICAgICAgICAgZGlzYWJsZWQ9e2J1c3l9DQogICAgICAgICAgICAgICAgICAgICAgICAgICAgb25DbGljaz17KCkgPT4gc2V0Rm9ybWF0'
                'KGNob2ljZS5pZCl9DQogICAgICAgICAgICAgICAgICAgICAgICA+DQogICAgICAgICAgICAgICAgICAgICAgICAgICAgPHNwYW4gY2xhc3NOYW1lPSJlcS1l'
                'eHBvcnQtZm9ybWF0LWhlYWQiPntjaG9pY2UudGl0bGV9e2Nob2ljZS5iYWRnZSAmJiA8c3BhbiBjbGFzc05hbWU9ImVxLWV4cG9ydC1iYWRnZSI+e2Nob2lj'
                'ZS5iYWRnZX08L3NwYW4+fTwvc3Bhbj4NCiAgICAgICAgICAgICAgICAgICAgICAgICAgICA8c3BhbiBjbGFzc05hbWU9ImVxLWV4cG9ydC1mb3JtYXQtZGVz'
                'YyI+e2Nob2ljZS5kZXNjcmlwdGlvbn08L3NwYW4+DQogICAgICAgICAgICAgICAgICAgICAgICA8L2J1dHRvbj4NCiAgICAgICAgICAgICAgICAgICAgKSl9'
                'DQogICAgICAgICAgICAgICAgPC9kaXY+DQoNCiAgICAgICAgICAgICAgICB7b2ZmbGluZSAmJiAoDQogICAgICAgICAgICAgICAgICAgIDxkaXYgY2xhc3NO'
                'YW1lPSJlcS1leHBvcnQtb3B0aW9ucyIgYXJpYS1sYWJlbD0iT2ZmbGluZSBtZWRpYSBvcHRpb25zIj4NCiAgICAgICAgICAgICAgICAgICAgICAgIDxsYWJl'
                'bCBjbGFzc05hbWU9ImVxLWV4cG9ydC1vcHRpb24iPjxpbnB1dCB0eXBlPSJjaGVja2JveCIgY2hlY2tlZD17b3B0aW9ucy5hdHRhY2htZW50c30gZGlzYWJs'
                'ZWQ9e2J1c3l9IG9uQ2hhbmdlPXtldmVudCA9PiB1cGRhdGVPcHRpb24oImF0dGFjaG1lbnRzIiwgZXZlbnQuY3VycmVudFRhcmdldC5jaGVja2VkKX0gLz5B'
                'dHRhY2htZW50czwvbGFiZWw+DQogICAgICAgICAgICAgICAgICAgICAgICA8bGFiZWwgY2xhc3NOYW1lPSJlcS1leHBvcnQtb3B0aW9uIj48aW5wdXQgdHlw'
                'ZT0iY2hlY2tib3giIGNoZWNrZWQ9e29wdGlvbnMuYXZhdGFyc30gZGlzYWJsZWQ9e2J1c3l9IG9uQ2hhbmdlPXtldmVudCA9PiB1cGRhdGVPcHRpb24oImF2'
                'YXRhcnMiLCBldmVudC5jdXJyZW50VGFyZ2V0LmNoZWNrZWQpfSAvPkF1dGhvciBhdmF0YXJzPC9sYWJlbD4NCiAgICAgICAgICAgICAgICAgICAgICAgIDxs'
                'YWJlbCBjbGFzc05hbWU9ImVxLWV4cG9ydC1vcHRpb24iPjxpbnB1dCB0eXBlPSJjaGVja2JveCIgY2hlY2tlZD17b3B0aW9ucy5lbW9qaXNTdGlja2Vyc30g'
                'ZGlzYWJsZWQ9e2J1c3l9IG9uQ2hhbmdlPXtldmVudCA9PiB1cGRhdGVPcHRpb24oImVtb2ppc1N0aWNrZXJzIiwgZXZlbnQuY3VycmVudFRhcmdldC5jaGVj'
                'a2VkKX0gLz5FbW9qaXMgYW5kIHN0aWNrZXJzPC9sYWJlbD4NCiAgICAgICAgICAgICAgICAgICAgICAgIDxsYWJlbCBjbGFzc05hbWU9ImVxLWV4cG9ydC1v'
                'cHRpb24iPjxpbnB1dCB0eXBlPSJjaGVja2JveCIgY2hlY2tlZD17b3B0aW9ucy5lbWJlZE1lZGlhfSBkaXNhYmxlZD17YnVzeX0gb25DaGFuZ2U9e2V2ZW50'
                'ID0+IHVwZGF0ZU9wdGlvbigiZW1iZWRNZWRpYSIsIGV2ZW50LmN1cnJlbnRUYXJnZXQuY2hlY2tlZCl9IC8+RW1iZWQgcHJldmlld3M8L2xhYmVsPg0KICAg'
                'ICAgICAgICAgICAgICAgICA8L2Rpdj4NCiAgICAgICAgICAgICAgICApfQ0KDQogICAgICAgICAgICAgICAge2Zvcm1hdCA9PT0gIm9ubGluZUh0bWwiICYm'
                'IDxkaXYgY2xhc3NOYW1lPSJlcS1leHBvcnQtbm90ZSI+SW50ZXJuZXQgYWNjZXNzIGlzIHJlcXVpcmVkIHdoZW5ldmVyIHRoaXMgSFRNTCBmaWxlIGRpc3Bs'
                'YXlzIG9ubGluZSBtZWRpYS48L2Rpdj59DQogICAgICAgICAgICAgICAge2Zvcm1hdCA9PT0gInNpbmdsZUh0bWwiICYmIDxkaXYgY2xhc3NOYW1lPSJlcS1l'
                'eHBvcnQtbm90ZSBlcS1leHBvcnQtd2FybmluZyI+RG93bmxvYWRlZCBtZWRpYSBpcyBiYXNlNjQtZW1iZWRkZWQgb25jZSBwZXIgYXNzZXQuIFRoZSByZXN1'
                'bHRpbmcgZmlsZSBjYW4gYmUgbXVjaCBsYXJnZXIgYW5kIHNsb3dlciB0aGFuIE9mZmxpbmUgQXJjaGl2ZS48L2Rpdj59DQoNCiAgICAgICAgICAgICAgICB7'
                'c3VtbWFyeSAmJiAoDQogICAgICAgICAgICAgICAgICAgIDxkaXYgY2xhc3NOYW1lPSJlcS1leHBvcnQtc3VtbWFyeSI+DQogICAgICAgICAgICAgICAgICAg'
                'ICAgICA8c3Ryb25nPkV4cG9ydCBzdW1tYXJ5PC9zdHJvbmc+DQogICAgICAgICAgICAgICAgICAgICAgICA8ZGl2IGNsYXNzTmFtZT0iZXEtZXhwb3J0LXN1'
                'bW1hcnktZ3JpZCI+DQogICAgICAgICAgICAgICAgICAgICAgICAgICAgPHNwYW4gY2xhc3NOYW1lPSJlcS1leHBvcnQtbWV0cmljIj5NZXNzYWdlczxzdHJv'
                'bmc+e3N1bW1hcnkubWVzc2FnZUNvdW50fTwvc3Ryb25nPjwvc3Bhbj4NCiAgICAgICAgICAgICAgICAgICAgICAgICAgICA8c3BhbiBjbGFzc05hbWU9ImVx'
                'LWV4cG9ydC1tZXRyaWMiPkF0dGFjaG1lbnRzPHN0cm9uZz57c3VtbWFyeS5hdHRhY2htZW50Q291bnR9PC9zdHJvbmc+PC9zcGFuPg0KICAgICAgICAgICAg'
                'ICAgICAgICAgICAgICAgIDxzcGFuIGNsYXNzTmFtZT0iZXEtZXhwb3J0LW1ldHJpYyI+e2Zvcm1hdCA9PT0gInNpbmdsZUh0bWwiID8gIkVzdGltYXRlZCBv'
                'dXRwdXQiIDogIktub3duIG1lZGlhIHNpemUifTxzdHJvbmc+e2Zvcm1hdEJ5dGVzKGZvcm1hdCA9PT0gInNpbmdsZUh0bWwiID8gc3VtbWFyeS5lc3RpbWF0'
                'ZWRTaW5nbGVIdG1sQnl0ZXMgOiBzdW1tYXJ5Lmtub3duQnl0ZXMpfTwvc3Ryb25nPjwvc3Bhbj4NCiAgICAgICAgICAgICAgICAgICAgICAgIDwvZGl2Pg0K'
                'ICAgICAgICAgICAgICAgICAgICA8L2Rpdj4NCiAgICAgICAgICAgICAgICApfQ0KDQogICAgICAgICAgICAgICAgeyhidXN5IHx8IHByb2dyZXNzLnN0YWdl'
                'KSAmJiAoDQogICAgICAgICAgICAgICAgICAgIDxkaXYgY2xhc3NOYW1lPSJlcS1leHBvcnQtcHJvZ3Jlc3MiIGFyaWEtbGl2ZT0icG9saXRlIj4NCiAgICAg'
                'ICAgICAgICAgICAgICAgICAgIDxkaXYgY2xhc3NOYW1lPSJlcS1leHBvcnQtcHJvZ3Jlc3MtbGluZSI+PHN0cm9uZz57cHJvZ3Jlc3Muc3RhZ2V9PC9zdHJv'
                'bmc+PHNwYW4+e3Byb2dyZXNzLnRvdGFsID8gYCR7cHJvZ3Jlc3MucHJvY2Vzc2VkfS8ke3Byb2dyZXNzLnRvdGFsfSBhc3NldHNgIDogYCR7cHJvZ3Jlc3Mu'
                'cHJvY2Vzc2VkfSBtZXNzYWdlc2B9PC9zcGFuPjwvZGl2Pg0KICAgICAgICAgICAgICAgICAgICAgICAgPGRpdiBjbGFzc05hbWU9ImVxLWV4cG9ydC1wcm9n'
                'cmVzcy1saW5lIj48c3Bhbj57Zm9ybWF0Qnl0ZXMocHJvZ3Jlc3MuZG93bmxvYWRlZEJ5dGVzKX0gZG93bmxvYWRlZDwvc3Bhbj48c3Bhbj57cHJvZ3Jlc3Mu'
                'ZmFpbHVyZXN9IGZhaWx1cmVzPC9zcGFuPjwvZGl2Pg0KICAgICAgICAgICAgICAgICAgICAgICAge3Byb2dyZXNzLnRvdGFsID4gMCAmJiA8ZGl2IGNsYXNz'
                'TmFtZT0iZXEtZXhwb3J0LWJhciIgYXJpYS1oaWRkZW49InRydWUiPjxzcGFuIHN0eWxlPXt7IHdpZHRoOiBgJHtwcm9ncmVzc1BlcmNlbnR9JWAgfX0gLz48'
                'L2Rpdj59DQogICAgICAgICAgICAgICAgICAgIDwvZGl2Pg0KICAgICAgICAgICAgICAgICl9DQoNCiAgICAgICAgICAgICAgICB7c3RhdHVzICYmIDxkaXYg'
                'Y2xhc3NOYW1lPSJlcS1leHBvcnQtc3RhdHVzIiByb2xlPSJzdGF0dXMiPntzdGF0dXN9PC9kaXY+fQ0KICAgICAgICAgICAgICAgIDxEaXZpZGVyIHN0eWxl'
                'PXt7IG1hcmdpbjogIjE2cHggMCAwIiB9fSAvPg0KICAgICAgICAgICAgICAgIDxkaXYgY2xhc3NOYW1lPSJlcS1leHBvcnQtYWN0aW9ucyI+DQogICAgICAg'
                'ICAgICAgICAgICAgIDxidXR0b24gdHlwZT0iYnV0dG9uIiBjbGFzc05hbWU9ImVxLWV4cG9ydC1idXR0b24gZXEtZXhwb3J0LWJ1dHRvbi0tcHJpbWFyeSIg'
                'ZGlzYWJsZWQ9e2J1c3l9IG9uQ2xpY2s9e21lc3NhZ2VzID8gY3JlYXRlRXhwb3J0IDogcHJlcGFyZU1lc3NhZ2VzfT4NCiAgICAgICAgICAgICAgICAgICAg'
                'ICAgIHtidXN5ID8gIldvcmtpbmcuLi4iIDogbWVzc2FnZXMgPyAiQ3JlYXRlIGV4cG9ydCIgOiAiUHJlcGFyZSBleHBvcnQifQ0KICAgICAgICAgICAgICAg'
                'ICAgICA8L2J1dHRvbj4NCiAgICAgICAgICAgICAgICAgICAge2J1c3kgJiYgPGJ1dHRvbiB0eXBlPSJidXR0b24iIGNsYXNzTmFtZT0iZXEtZXhwb3J0LWJ1'
                'dHRvbiBlcS1leHBvcnQtYnV0dG9uLS1jYW5jZWwiIG9uQ2xpY2s9eygpID0+IGNvbnRyb2xsZXJSZWYuY3VycmVudD8uYWJvcnQoKX0+Q2FuY2VsPC9idXR0'
                'b24+fQ0KICAgICAgICAgICAgICAgIDwvZGl2Pg0KICAgICAgICAgICAgPC9kaXY+DQogICAgICAgIDwvTW9kYWw+DQogICAgKTsNCn0NCg0KY29uc3QgcGF0'
                'Y2hETUNvbnRleHQ6IE5hdkNvbnRleHRNZW51UGF0Y2hDYWxsYmFjayA9IChjaGlsZHJlbiwgeyBjaGFubmVsIH0pID0+IHsNCiAgICBpZiAoIWNoYW5uZWwp'
                'IHJldHVybjsNCiAgICBjaGlsZHJlbi5wdXNoKA0KICAgICAgICA8TWVudS5NZW51SXRlbQ0KICAgICAgICAgICAgaWQ9ImV4cG9ydC1kbSINCiAgICAgICAg'
                'ICAgIGtleT0iZXhwb3J0LWRtIg0KICAgICAgICAgICAgbGFiZWw9IkV4cG9ydCBETSINCiAgICAgICAgICAgIGFjdGlvbj17KCkgPT4gb3Blbk1vZGFsKHBy'
                'b3BzID0+IDxFeHBvcnRNb2RhbCByb290UHJvcHM9e3Byb3BzfSBjaGFubmVsSWQ9e2NoYW5uZWwuaWR9IC8+KX0NCiAgICAgICAgLz4NCiAgICApOw0KfTsN'
                'Cg0KY29uc3QgcGF0Y2hDaGFubmVsQ29udGV4dDogTmF2Q29udGV4dE1lbnVQYXRjaENhbGxiYWNrID0gKGNoaWxkcmVuLCB7IGNoYW5uZWwgfSkgPT4gew0K'
                'ICAgIGlmICghY2hhbm5lbCkgcmV0dXJuOw0KICAgIGNoaWxkcmVuLnB1c2goDQogICAgICAgIDxNZW51Lk1lbnVJdGVtDQogICAgICAgICAgICBpZD0iZXhw'
                'b3J0LWRtIg0KICAgICAgICAgICAga2V5PSJleHBvcnQtZG0iDQogICAgICAgICAgICBsYWJlbD0iRXhwb3J0IE1lc3NhZ2VzIg0KICAgICAgICAgICAgYWN0'
                'aW9uPXsoKSA9PiBvcGVuTW9kYWwocHJvcHMgPT4gPEV4cG9ydE1vZGFsIHJvb3RQcm9wcz17cHJvcHN9IGNoYW5uZWxJZD17Y2hhbm5lbC5pZH0gLz4pfQ0K'
                'ICAgICAgICAvPg0KICAgICk7DQp9Ow0KDQpleHBvcnQgY29uc3QgRXhwb3J0RG1UZXN0QXBpID0gew0KICAgIGNvbGxlY3RBc3NldFJlcXVlc3RzLA0KICAg'
                'IGNyZWF0ZU9mZmxpbmVBcmNoaXZlLA0KICAgIGNyZWF0ZU9ubGluZUFsaWFzZXMsDQogICAgY3JlYXRlU2luZ2xlSHRtbCwNCiAgICBkb3dubG9hZEFzc2V0'
                'UmVxdWVzdHMsDQogICAgcmVuZGVyQ29udmVyc2F0aW9uSHRtbCwNCiAgICBzYWZlRmlsZW5hbWUsDQogICAgc2FuaXRpemVGaWxlbmFtZVBhcnQNCn07DQoN'
                'CmV4cG9ydCBkZWZhdWx0IGRlZmluZVBsdWdpbih7DQogICAgbmFtZTogIkV4cG9ydERNIiwNCiAgICBkZXNjcmlwdGlvbjogIkV4cG9ydCBtZXNzYWdlcyBh'
                'cyByYXcgSlNPTiwgb25saW5lIEhUTUwsIGEgY29tcGxldGUgb2ZmbGluZSBaSVAgYXJjaGl2ZSwgb3Igb25lIHNlbGYtY29udGFpbmVkIEhUTUwgZmlsZS4i'
                'LA0KICAgIGF1dGhvcnM6IFt7IG5hbWU6ICJzcWx1IiwgaWQ6IDBuIH1dLA0KICAgIGVuYWJsZWRCeURlZmF1bHQ6IHRydWUsDQogICAgZGVwZW5kZW5jaWVz'
                'OiBbIkNvbnRleHRNZW51QVBJIl0sDQogICAgc3RhcnQoKSB7DQogICAgICAgIGFkZENvbnRleHRNZW51UGF0Y2goImdkbS1jb250ZXh0IiwgcGF0Y2hETUNv'
                'bnRleHQpOw0KICAgICAgICBhZGRDb250ZXh0TWVudVBhdGNoKCJ1c2VyLWNvbnRleHQiLCBwYXRjaERNQ29udGV4dCk7DQogICAgICAgIGFkZENvbnRleHRN'
                'ZW51UGF0Y2goImNoYW5uZWwtY29udGV4dCIsIHBhdGNoQ2hhbm5lbENvbnRleHQpOw0KICAgIH0sDQogICAgc3RvcCgpIHsNCiAgICAgICAgcmVtb3ZlQ29u'
                'dGV4dE1lbnVQYXRjaCgiZ2RtLWNvbnRleHQiLCBwYXRjaERNQ29udGV4dCk7DQogICAgICAgIHJlbW92ZUNvbnRleHRNZW51UGF0Y2goInVzZXItY29udGV4'
                'dCIsIHBhdGNoRE1Db250ZXh0KTsNCiAgICAgICAgcmVtb3ZlQ29udGV4dE1lbnVQYXRjaCgiY2hhbm5lbC1jb250ZXh0IiwgcGF0Y2hDaGFubmVsQ29udGV4'
                'dCk7DQogICAgfQ0KfSk7DQo='
            ) -join '')
        }
    }
    [pscustomobject]@{
        Id = 'serverCloner'
        DisplayName = 'ServerCloner'
        FolderName = 'serverCloner'
        Description = 'Clones server settings, roles, channels, icon, and emojis to another server.'
        DefaultSelected = $true
        LegacyFolders = @('ServerCloner')
        Notes = 'Uses Discord RestAPI and throttled clone steps.'
        Files = [ordered]@{
            'index.tsx' = (@(
                'LyoNCiAqIFZlbmNvcmQsIGEgRGlzY29yZCBjbGllbnQgbW9kDQogKiBDb3B5cmlnaHQgKGMpIDIwMjYgVmVuZGljYXRlZCBhbmQgY29udHJpYnV0b3JzDQog'
                'KiBTUERYLUxpY2Vuc2UtSWRlbnRpZmllcjogR1BMLTMuMC1vci1sYXRlcg0KICoNCiAqIE1vZGlmaWVkIGZvciBNeSBFcXVpY29yZCBTZXR1cCBieSBTcGVj'
                'dGF0b3IxNSwgMjAyNi0wOC0xNS4NCiAqIE9yaWdpbmFsIGNvcHlyaWdodCBhbmQgYXV0aG9yc2hpcCByZW1haW4gd2l0aCB0aGUgcmVzcGVjdGl2ZSB1cHN0'
                'cmVhbSBjb250cmlidXRvcnMuDQogKi8NCg0KaW1wb3J0IHsgYWRkQ29udGV4dE1lbnVQYXRjaCwgTmF2Q29udGV4dE1lbnVQYXRjaENhbGxiYWNrLCByZW1v'
                'dmVDb250ZXh0TWVudVBhdGNoIH0gZnJvbSAiQGFwaS9Db250ZXh0TWVudSI7DQppbXBvcnQgeyBkZWZpbmVQbHVnaW5TZXR0aW5ncyB9IGZyb20gIkBhcGkv'
                'U2V0dGluZ3MiOw0KaW1wb3J0IHsgRm9ybVN3aXRjaCB9IGZyb20gIkBjb21wb25lbnRzL0Zvcm1Td2l0Y2giOw0KaW1wb3J0IHsgc2xlZXAgfSBmcm9tICJA'
                'dXRpbHMvbWlzYyI7DQppbXBvcnQgZGVmaW5lUGx1Z2luLCB7IE9wdGlvblR5cGUgfSBmcm9tICJAdXRpbHMvdHlwZXMiOw0KaW1wb3J0IHR5cGUgeyBSZW5k'
                'ZXJNb2RhbFByb3BzIH0gZnJvbSAiQHZlbmNvcmQvZGlzY29yZC10eXBlcyI7DQppbXBvcnQgeyBmaW5kU3RvcmVMYXp5IH0gZnJvbSAiQHdlYnBhY2siOw0K'
                'aW1wb3J0IHsgQnV0dG9uLCBGb3JtcywgR3VpbGRTdG9yZSwgSWNvblV0aWxzLCBNZW51LCBNb2RhbCwgb3Blbk1vZGFsLCBSZWFjdCwgUmVzdEFQSSwgU2Vs'
                'ZWN0LCBUb2FzdHMsIHVzZU1lbW8sIHVzZVJlZiwgVXNlclN0b3JlLCB1c2VTdGF0ZSB9IGZyb20gIkB3ZWJwYWNrL2NvbW1vbiI7DQoNCmNvbnN0IEYgPSBG'
                'b3JtcyBhcyBhbnk7DQpjb25zdCBQZXJtaXNzaW9uU3RvcmUgPSBmaW5kU3RvcmVMYXp5KCJQZXJtaXNzaW9uU3RvcmUiKTsNCmNvbnN0IEFETUlOX0JJVCA9'
                'IDB4OG47DQoNCmZ1bmN0aW9uIGhhc0FkbWluKGd1aWxkSWQ6IHN0cmluZyk6IGJvb2xlYW4geyB0cnkgeyBjb25zdCBndWlsZCA9IEd1aWxkU3RvcmUuZ2V0'
                'R3VpbGQoZ3VpbGRJZCk7IGlmICghZ3VpbGQpIHJldHVybiBmYWxzZTsgY29uc3QgbWUgPSBVc2VyU3RvcmUuZ2V0Q3VycmVudFVzZXIoKTsgaWYgKGd1aWxk'
                'Lm93bmVySWQgPT09IG1lLmlkKSByZXR1cm4gdHJ1ZTsgY29uc3QgcGVybXMgPSBQZXJtaXNzaW9uU3RvcmUuZ2V0R3VpbGRQZXJtaXNzaW9ucyh7IGlkOiBn'
                'dWlsZElkIH0pOyBpZiAodHlwZW9mIHBlcm1zID09PSAiYmlnaW50IikgcmV0dXJuIChwZXJtcyAmIEFETUlOX0JJVCkgPT09IEFETUlOX0JJVDsgcmV0dXJu'
                'IGZhbHNlOyB9IGNhdGNoIHsgcmV0dXJuIGZhbHNlOyB9IH0NCmFzeW5jIGZ1bmN0aW9uIGFwaUNhbGwobWV0aG9kOiAiZ2V0IiB8ICJwb3N0IiB8ICJwYXRj'
                'aCIgfCAicHV0IiB8ICJkZWwiLCB1cmw6IHN0cmluZywgYm9keT86IGFueSk6IFByb21pc2U8YW55PiB7IGNvbnN0IG9wdHM6IGFueSA9IHsgdXJsIH07IGlm'
                'IChib2R5KSBvcHRzLmJvZHkgPSBib2R5OyBjb25zdCByZXMgPSBhd2FpdCAoUmVzdEFQSSBhcyBhbnkpW21ldGhvZF0ob3B0cyk7IGNvbnN0IHN0YXR1cyA9'
                'IE51bWJlcihyZXM/LnN0YXR1cyA/PyAyMDApOyBpZiAocmVzPy5vayA9PT0gZmFsc2UgfHwgc3RhdHVzID49IDQwMCkgdGhyb3cgbmV3IEVycm9yKHJlcz8u'
                'Ym9keT8ubWVzc2FnZSB8fCBgSFRUUCAke3N0YXR1c31gKTsgcmV0dXJuIHJlcz8uYm9keTsgfQ0KYXN5bmMgZnVuY3Rpb24gd2FpdChtczogbnVtYmVyKSB7'
                'IGF3YWl0IHNsZWVwKG1zKTsgfQ0KZnVuY3Rpb24gbWFwUGVybU92ZXJ3cml0ZXMob3ZlcndyaXRlczogYW55W10sIHJvbGVNYXBwaW5nOiBNYXA8c3RyaW5n'
                'LCBzdHJpbmc+KTogYW55W10geyByZXR1cm4gb3ZlcndyaXRlcy5maWx0ZXIob3cgPT4gcm9sZU1hcHBpbmcuaGFzKG93LmlkKSkubWFwKG93ID0+ICh7IGlk'
                'OiByb2xlTWFwcGluZy5nZXQob3cuaWQpISwgdHlwZTogb3cudHlwZSwgYWxsb3c6IFN0cmluZyhvdy5hbGxvdyksIGRlbnk6IFN0cmluZyhvdy5kZW55KSB9'
                'KSk7IH0NCg0KaW50ZXJmYWNlIENsb25lT3B0aW9ucyB7IHJvbGVzOiBib29sZWFuOyBjbGVhclJvbGVzOiBib29sZWFuOyBjaGFubmVsczogYm9vbGVhbjsg'
                'bm9EZWxldGVDaGFubmVsczogYm9vbGVhbjsgcGVybWlzc2lvbnM6IGJvb2xlYW47IGljb246IGJvb2xlYW47IGVtb2ppczogYm9vbGVhbjsgZ3VpbGRTZXR0'
                'aW5nczogYm9vbGVhbjsgfQ0KaW50ZXJmYWNlIExvZ0VudHJ5IHsgdGV4dDogc3RyaW5nOyB0eXBlOiAib2siIHwgImVyciIgfCAid2FybiIgfCAiaW5mbyI7'
                'IH0NCg0KbGV0IF9ydW5uaW5nID0gZmFsc2U7IGxldCBfY2FuY2VsbGVkID0gZmFsc2U7IGxldCBfcHJvZ3Jlc3MgPSAwOyBsZXQgX2xvZ3M6IExvZ0VudHJ5'
                'W10gPSBbXTsNCmNvbnN0IE1BWF9MT0dfRU5UUklFUyA9IDEwMDA7DQpjb25zdCBfbGlzdGVuZXJzID0gbmV3IFNldDwoKSA9PiB2b2lkPigpOw0KZnVuY3Rp'
                'b24gbm90aWZ5TGlzdGVuZXJzKCkgeyBfbGlzdGVuZXJzLmZvckVhY2goZm4gPT4gZm4oKSk7IH0NCmZ1bmN0aW9uIHBlcnNpc3RMb2coZW50cnk6IExvZ0Vu'
                'dHJ5KSB7IF9sb2dzID0gWy4uLl9sb2dzLCBlbnRyeV0uc2xpY2UoLU1BWF9MT0dfRU5UUklFUyk7IG5vdGlmeUxpc3RlbmVycygpOyB9DQpmdW5jdGlvbiBw'
                'ZXJzaXN0UHJvZ3Jlc3MocDogbnVtYmVyKSB7IF9wcm9ncmVzcyA9IHA7IG5vdGlmeUxpc3RlbmVycygpOyB9DQpmdW5jdGlvbiBwZXJzaXN0UnVubmluZyh2'
                'OiBib29sZWFuKSB7IF9ydW5uaW5nID0gdjsgbm90aWZ5TGlzdGVuZXJzKCk7IH0NCg0KYXN5bmMgZnVuY3Rpb24gY2xvbmVTZXJ2ZXIoc291cmNlSWQ6IHN0'
                'cmluZywgdGFyZ2V0SWQ6IHN0cmluZywgb3B0aW9uczogQ2xvbmVPcHRpb25zLCBsb2c6IChlOiBMb2dFbnRyeSkgPT4gdm9pZCwgc2V0UHJvZ3Jlc3M6IChw'
                'OiBudW1iZXIpID0+IHZvaWQpIHsNCiAgICBfY2FuY2VsbGVkID0gZmFsc2U7DQogICAgaWYgKCFVc2VyU3RvcmUuZ2V0Q3VycmVudFVzZXIoKSkgeyBsb2co'
                'eyB0ZXh0OiAiRGlzY29yZCB1c2VyIHdhcyBub3QgZm91bmQuIFJlc3RhcnQgRGlzY29yZCwgdGhlbiB0cnkgYWdhaW4uIiwgdHlwZTogImVyciIgfSk7IHJl'
                'dHVybjsgfQ0KICAgIGNvbnN0IHN0ZXBzID0gW29wdGlvbnMuZ3VpbGRTZXR0aW5ncyAmJiAic2V0dGluZ3MiLCBvcHRpb25zLmljb24gJiYgImljb24iLCBv'
                'cHRpb25zLnJvbGVzICYmICJyb2xlcyIsIG9wdGlvbnMuY2hhbm5lbHMgJiYgImNoYW5uZWxzIiwgb3B0aW9ucy5lbW9qaXMgJiYgImVtb2ppcyJdLmZpbHRl'
                'cihCb29sZWFuKSBhcyBzdHJpbmdbXTsNCiAgICBsZXQgY3VycmVudFN0ZXAgPSAwOw0KICAgIGNvbnN0IGFkdmFuY2UgPSAobmFtZTogc3RyaW5nKSA9PiB7'
                'IGN1cnJlbnRTdGVwKys7IHNldFByb2dyZXNzKE1hdGgucm91bmQoKGN1cnJlbnRTdGVwIC8gc3RlcHMubGVuZ3RoKSAqIDEwMCkpOyBsb2coeyB0ZXh0OiBg'
                'LS0gJHtuYW1lfSBkb25lICgke2N1cnJlbnRTdGVwfS8ke3N0ZXBzLmxlbmd0aH0pYCwgdHlwZTogImluZm8iIH0pOyB9Ow0KICAgIGNvbnN0IGlzQ2FuY2Vs'
                'bGVkID0gKCkgPT4geyBpZiAoX2NhbmNlbGxlZCkgeyBsb2coeyB0ZXh0OiAiQ2FuY2VsbGVkLiIsIHR5cGU6ICJ3YXJuIiB9KTsgcmV0dXJuIHRydWU7IH0g'
                'cmV0dXJuIGZhbHNlOyB9Ow0KICAgIGNvbnN0IHNvdXJjZUd1aWxkID0gR3VpbGRTdG9yZS5nZXRHdWlsZChzb3VyY2VJZCk7IGlmICghc291cmNlR3VpbGQp'
                'IHsgbG9nKHsgdGV4dDogIlNvdXJjZSBzZXJ2ZXIgbm90IGZvdW5kIiwgdHlwZTogImVyciIgfSk7IHJldHVybjsgfQ0KICAgIGxvZyh7IHRleHQ6IGBDbG9u'
                'aW5nICIke3NvdXJjZUd1aWxkLm5hbWV9Ii4uLmAsIHR5cGU6ICJpbmZvIiB9KTsNCiAgICBpZiAob3B0aW9ucy5ndWlsZFNldHRpbmdzICYmICFpc0NhbmNl'
                'bGxlZCgpKSB7IHRyeSB7IGNvbnN0IHBhdGNoOiBhbnkgPSB7fTsgaWYgKHNvdXJjZUd1aWxkLm5hbWUpIHBhdGNoLm5hbWUgPSBzb3VyY2VHdWlsZC5uYW1l'
                'OyBpZiAoc291cmNlR3VpbGQuZGVzY3JpcHRpb24pIHBhdGNoLmRlc2NyaXB0aW9uID0gc291cmNlR3VpbGQuZGVzY3JpcHRpb247IGlmIChPYmplY3Qua2V5'
                'cyhwYXRjaCkubGVuZ3RoKSB7IGF3YWl0IGFwaUNhbGwoInBhdGNoIiwgYC9ndWlsZHMvJHt0YXJnZXRJZH1gLCBwYXRjaCk7IGxvZyh7IHRleHQ6ICJTZXR0'
                'aW5ncyBjb3BpZWQiLCB0eXBlOiAib2siIH0pOyB9IH0gY2F0Y2ggKGU6IGFueSkgeyBsb2coeyB0ZXh0OiBgU2V0dGluZ3MgZXJyb3I6ICR7ZT8ubWVzc2Fn'
                'ZX1gLCB0eXBlOiAiZXJyIiB9KTsgfSBhd2FpdCB3YWl0KDUwMCk7IGFkdmFuY2UoIlNldHRpbmdzIik7IH0NCiAgICBpZiAob3B0aW9ucy5pY29uICYmIHNv'
                'dXJjZUd1aWxkLmljb24gJiYgIWlzQ2FuY2VsbGVkKCkpIHsgdHJ5IHsgY29uc3QgaWNvblVybCA9IEljb25VdGlscz8uZ2V0R3VpbGRJY29uVVJMKHsgaWQ6'
                'IHNvdXJjZUlkLCBpY29uOiBzb3VyY2VHdWlsZC5pY29uLCBzaXplOiA1MTIgfSkgPz8gIiI7IGlmIChpY29uVXJsKSB7IGNvbnN0IGJsb2IgPSBhd2FpdCAo'
                'YXdhaXQgZmV0Y2goaWNvblVybCkpLmJsb2IoKTsgY29uc3QgYmFzZTY0ID0gYXdhaXQgbmV3IFByb21pc2U8c3RyaW5nPihyZXMgPT4geyBjb25zdCByID0g'
                'bmV3IEZpbGVSZWFkZXIoKTsgci5vbmxvYWRlbmQgPSAoKSA9PiByZXMoci5yZXN1bHQgYXMgc3RyaW5nKTsgci5yZWFkQXNEYXRhVVJMKGJsb2IpOyB9KTsg'
                'YXdhaXQgYXBpQ2FsbCgicGF0Y2giLCBgL2d1aWxkcy8ke3RhcmdldElkfWAsIHsgaWNvbjogYmFzZTY0IH0pOyBsb2coeyB0ZXh0OiAiSWNvbiBjb3BpZWQi'
                'LCB0eXBlOiAib2siIH0pOyB9IH0gY2F0Y2ggKGU6IGFueSkgeyBsb2coeyB0ZXh0OiBgSWNvbiBlcnJvcjogJHtlPy5tZXNzYWdlfWAsIHR5cGU6ICJlcnIi'
                'IH0pOyB9IGF3YWl0IHdhaXQoNTAwKTsgYWR2YW5jZSgiSWNvbiIpOyB9IGVsc2UgaWYgKG9wdGlvbnMuaWNvbikgYWR2YW5jZSgiSWNvbiIpOw0KICAgIGNv'
                'bnN0IHJvbGVNYXBwaW5nID0gbmV3IE1hcDxzdHJpbmcsIHN0cmluZz4oKTsNCiAgICBpZiAob3B0aW9ucy5yb2xlcyAmJiAhaXNDYW5jZWxsZWQoKSkgeyB0'
                'cnkgeyBjb25zdCBzb3VyY2VSb2xlczogYW55W10gPSBhd2FpdCBhcGlDYWxsKCJnZXQiLCBgL2d1aWxkcy8ke3NvdXJjZUlkfS9yb2xlc2ApOyBjb25zdCB0'
                'YXJnZXRSb2xlczogYW55W10gPSBhd2FpdCBhcGlDYWxsKCJnZXQiLCBgL2d1aWxkcy8ke3RhcmdldElkfS9yb2xlc2ApOyBpZiAob3B0aW9ucy5jbGVhclJv'
                'bGVzKSB7IGZvciAoY29uc3QgciBvZiB0YXJnZXRSb2xlcykgeyBpZiAoci5uYW1lID09PSAiQGV2ZXJ5b25lIiB8fCByLm1hbmFnZWQpIGNvbnRpbnVlOyB0'
                'cnkgeyBhd2FpdCBhcGlDYWxsKCJkZWwiLCBgL2d1aWxkcy8ke3RhcmdldElkfS9yb2xlcy8ke3IuaWR9YCk7IGF3YWl0IHdhaXQoMzAwKTsgfSBjYXRjaCB7'
                'IH0gfSB9IGNvbnN0IGV2U3JjID0gc291cmNlUm9sZXMuZmluZChyID0+IHIubmFtZSA9PT0gIkBldmVyeW9uZSIpOyBjb25zdCB1cGRhdGVkVGFyZ2V0OiBh'
                'bnlbXSA9IGF3YWl0IGFwaUNhbGwoImdldCIsIGAvZ3VpbGRzLyR7dGFyZ2V0SWR9L3JvbGVzYCk7IGNvbnN0IGV2VGd0ID0gdXBkYXRlZFRhcmdldC5maW5k'
                'KHIgPT4gci5uYW1lID09PSAiQGV2ZXJ5b25lIik7IGlmIChldlNyYyAmJiBldlRndCkgcm9sZU1hcHBpbmcuc2V0KGV2U3JjLmlkLCBldlRndC5pZCk7IGZv'
                'ciAoY29uc3Qgcm9sZSBvZiBzb3VyY2VSb2xlcy5maWx0ZXIociA9PiByLm5hbWUgIT09ICJAZXZlcnlvbmUiKS5zb3J0KChhLCBiKSA9PiBiLnBvc2l0aW9u'
                'IC0gYS5wb3NpdGlvbikpIHsgdHJ5IHsgY29uc3QgYm9keTogYW55ID0geyBuYW1lOiByb2xlLm5hbWUsIGNvbG9yOiByb2xlLmNvbG9yLCBob2lzdDogcm9s'
                'ZS5ob2lzdCwgbWVudGlvbmFibGU6IHJvbGUubWVudGlvbmFibGUgfTsgaWYgKG9wdGlvbnMucGVybWlzc2lvbnMgJiYgcm9sZS5wZXJtaXNzaW9ucyAhPSBu'
                'dWxsKSBib2R5LnBlcm1pc3Npb25zID0gU3RyaW5nKHJvbGUucGVybWlzc2lvbnMpOyBjb25zdCBjcmVhdGVkID0gYXdhaXQgYXBpQ2FsbCgicG9zdCIsIGAv'
                'Z3VpbGRzLyR7dGFyZ2V0SWR9L3JvbGVzYCwgYm9keSk7IHJvbGVNYXBwaW5nLnNldChyb2xlLmlkLCBjcmVhdGVkLmlkKTsgbG9nKHsgdGV4dDogYCAgUm9s'
                'ZTogJHtyb2xlLm5hbWV9YCwgdHlwZTogIm9rIiB9KTsgYXdhaXQgd2FpdCgzMDApOyB9IGNhdGNoIChlOiBhbnkpIHsgbG9nKHsgdGV4dDogYCAgUm9sZSBl'
                'cnJvciAiJHtyb2xlLm5hbWV9IjogJHtlPy5tZXNzYWdlfWAsIHR5cGU6ICJlcnIiIH0pOyB9IH0gfSBjYXRjaCAoZTogYW55KSB7IGxvZyh7IHRleHQ6IGBS'
                'b2xlcyBlcnJvcjogJHtlPy5tZXNzYWdlfWAsIHR5cGU6ICJlcnIiIH0pOyB9IGF3YWl0IHdhaXQoNTAwKTsgYWR2YW5jZSgiUm9sZXMiKTsgfQ0KICAgIGNv'
                'bnN0IGNoYW5uZWxNYXBwaW5nID0gbmV3IE1hcDxzdHJpbmcsIHN0cmluZz4oKTsNCiAgICBpZiAob3B0aW9ucy5jaGFubmVscyAmJiAhaXNDYW5jZWxsZWQo'
                'KSkgeyB0cnkgeyBjb25zdCBzb3VyY2VDaGFubmVsczogYW55W10gPSBhd2FpdCBhcGlDYWxsKCJnZXQiLCBgL2d1aWxkcy8ke3NvdXJjZUlkfS9jaGFubmVs'
                'c2ApOyBpZiAoIW9wdGlvbnMubm9EZWxldGVDaGFubmVscykgeyBjb25zdCB0Z3Q6IGFueVtdID0gYXdhaXQgYXBpQ2FsbCgiZ2V0IiwgYC9ndWlsZHMvJHt0'
                'YXJnZXRJZH0vY2hhbm5lbHNgKTsgZm9yIChjb25zdCBjaCBvZiB0Z3QpIHsgdHJ5IHsgYXdhaXQgYXBpQ2FsbCgiZGVsIiwgYC9jaGFubmVscy8ke2NoLmlk'
                'fWApOyBhd2FpdCB3YWl0KDMwMCk7IH0gY2F0Y2ggeyB9IH0gfSBmb3IgKGNvbnN0IGNhdCBvZiBzb3VyY2VDaGFubmVscy5maWx0ZXIoYyA9PiBjLnR5cGUg'
                'PT09IDQpLnNvcnQoKGEsIGIpID0+IGEucG9zaXRpb24gLSBiLnBvc2l0aW9uKSkgeyBpZiAoX2NhbmNlbGxlZCkgYnJlYWs7IHRyeSB7IGNvbnN0IGJvZHk6'
                'IGFueSA9IHsgbmFtZTogY2F0Lm5hbWUsIHR5cGU6IDQsIHBvc2l0aW9uOiBjYXQucG9zaXRpb24gfTsgaWYgKG9wdGlvbnMucGVybWlzc2lvbnMgJiYgY2F0'
                'LnBlcm1pc3Npb25fb3ZlcndyaXRlcz8ubGVuZ3RoKSBib2R5LnBlcm1pc3Npb25fb3ZlcndyaXRlcyA9IG1hcFBlcm1PdmVyd3JpdGVzKGNhdC5wZXJtaXNz'
                'aW9uX292ZXJ3cml0ZXMsIHJvbGVNYXBwaW5nKTsgY29uc3QgY3JlYXRlZCA9IGF3YWl0IGFwaUNhbGwoInBvc3QiLCBgL2d1aWxkcy8ke3RhcmdldElkfS9j'
                'aGFubmVsc2AsIGJvZHkpOyBjaGFubmVsTWFwcGluZy5zZXQoY2F0LmlkLCBjcmVhdGVkLmlkKTsgbG9nKHsgdGV4dDogYCAgQ2F0ZWdvcnk6ICR7Y2F0Lm5h'
                'bWV9YCwgdHlwZTogIm9rIiB9KTsgYXdhaXQgd2FpdCg1MDApOyB9IGNhdGNoIChlOiBhbnkpIHsgbG9nKHsgdGV4dDogYCAgQ2F0ZWdvcnkgZXJyb3I6ICR7'
                'ZT8ubWVzc2FnZX1gLCB0eXBlOiAiZXJyIiB9KTsgfSB9IGZvciAoY29uc3QgY2ggb2Ygc291cmNlQ2hhbm5lbHMuZmlsdGVyKGMgPT4gYy50eXBlICE9PSA0'
                'KS5zb3J0KChhLCBiKSA9PiBhLnBvc2l0aW9uIC0gYi5wb3NpdGlvbikpIHsgaWYgKF9jYW5jZWxsZWQpIGJyZWFrOyB0cnkgeyBjb25zdCBib2R5OiBhbnkg'
                'PSB7IG5hbWU6IGNoLm5hbWUsIHR5cGU6IGNoLnR5cGUsIHBvc2l0aW9uOiBjaC5wb3NpdGlvbiwgdG9waWM6IGNoLnRvcGljLCBuc2Z3OiBjaC5uc2Z3ID8/'
                'IGZhbHNlLCBiaXRyYXRlOiBjaC5iaXRyYXRlLCB1c2VyX2xpbWl0OiBjaC51c2VyX2xpbWl0LCByYXRlX2xpbWl0X3Blcl91c2VyOiBjaC5yYXRlX2xpbWl0'
                'X3Blcl91c2VyIH07IGlmIChjaC5wYXJlbnRfaWQgJiYgY2hhbm5lbE1hcHBpbmcuaGFzKGNoLnBhcmVudF9pZCkpIGJvZHkucGFyZW50X2lkID0gY2hhbm5l'
                'bE1hcHBpbmcuZ2V0KGNoLnBhcmVudF9pZCk7IGlmIChvcHRpb25zLnBlcm1pc3Npb25zICYmIGNoLnBlcm1pc3Npb25fb3ZlcndyaXRlcz8ubGVuZ3RoKSBi'
                'b2R5LnBlcm1pc3Npb25fb3ZlcndyaXRlcyA9IG1hcFBlcm1PdmVyd3JpdGVzKGNoLnBlcm1pc3Npb25fb3ZlcndyaXRlcywgcm9sZU1hcHBpbmcpOyBjb25z'
                'dCBjcmVhdGVkID0gYXdhaXQgYXBpQ2FsbCgicG9zdCIsIGAvZ3VpbGRzLyR7dGFyZ2V0SWR9L2NoYW5uZWxzYCwgYm9keSk7IGNoYW5uZWxNYXBwaW5nLnNl'
                'dChjaC5pZCwgY3JlYXRlZC5pZCk7IGxvZyh7IHRleHQ6IGAgIENoYW5uZWw6ICMke2NoLm5hbWV9YCwgdHlwZTogIm9rIiB9KTsgYXdhaXQgd2FpdCg1MDAp'
                'OyB9IGNhdGNoIChlOiBhbnkpIHsgbG9nKHsgdGV4dDogYCAgQ2hhbm5lbCBlcnJvcjogJHtlPy5tZXNzYWdlfWAsIHR5cGU6ICJlcnIiIH0pOyB9IH0gfSBj'
                'YXRjaCAoZTogYW55KSB7IGxvZyh7IHRleHQ6IGBDaGFubmVscyBlcnJvcjogJHtlPy5tZXNzYWdlfWAsIHR5cGU6ICJlcnIiIH0pOyB9IGF3YWl0IHdhaXQo'
                'NTAwKTsgYWR2YW5jZSgiQ2hhbm5lbHMiKTsgfQ0KICAgIGlmIChvcHRpb25zLmVtb2ppcyAmJiAhaXNDYW5jZWxsZWQoKSkgeyB0cnkgeyBjb25zdCBzb3Vy'
                'Y2VFbW9qaXM6IGFueVtdID0gYXdhaXQgYXBpQ2FsbCgiZ2V0IiwgYC9ndWlsZHMvJHtzb3VyY2VJZH0vZW1vamlzYCk7IGxldCBjb3VudCA9IDA7IGZvciAo'
                'Y29uc3QgZW1vamkgb2Ygc291cmNlRW1vamlzKSB7IGlmIChfY2FuY2VsbGVkKSBicmVhazsgdHJ5IHsgY29uc3QgZW1vamlVcmwgPSBJY29uVXRpbHM/Lmdl'
                'dEVtb2ppVVJMKHsgaWQ6IGVtb2ppLmlkLCBhbmltYXRlZDogZW1vamkuYW5pbWF0ZWQsIHNpemU6IDEyOCB9KSA/PyAiIjsgaWYgKCFlbW9qaVVybCkgY29u'
                'dGludWU7IGNvbnN0IGJsb2IgPSBhd2FpdCAoYXdhaXQgZmV0Y2goZW1vamlVcmwpKS5ibG9iKCk7IGNvbnN0IGJhc2U2NCA9IGF3YWl0IG5ldyBQcm9taXNl'
                'PHN0cmluZz4ocmVzID0+IHsgY29uc3QgciA9IG5ldyBGaWxlUmVhZGVyKCk7IHIub25sb2FkZW5kID0gKCkgPT4gcmVzKHIucmVzdWx0IGFzIHN0cmluZyk7'
                'IHIucmVhZEFzRGF0YVVSTChibG9iKTsgfSk7IGF3YWl0IGFwaUNhbGwoInBvc3QiLCBgL2d1aWxkcy8ke3RhcmdldElkfS9lbW9qaXNgLCB7IG5hbWU6IGVt'
                'b2ppLm5hbWUsIGltYWdlOiBiYXNlNjQsIHJvbGVzOiBbXSB9KTsgY291bnQrKzsgbG9nKHsgdGV4dDogYCAgRW1vamk6ICR7ZW1vamkubmFtZX0gKCR7Y291'
                'bnR9LyR7c291cmNlRW1vamlzLmxlbmd0aH0pYCwgdHlwZTogIm9rIiB9KTsgYXdhaXQgd2FpdCgzMDAwKTsgfSBjYXRjaCAoZTogYW55KSB7IGxvZyh7IHRl'
                'eHQ6IGAgIEVtb2ppIGVycm9yOiAke2U/Lm1lc3NhZ2V9YCwgdHlwZTogImVyciIgfSk7IH0gfSB9IGNhdGNoIChlOiBhbnkpIHsgbG9nKHsgdGV4dDogYEVt'
                'b2ppcyBlcnJvcjogJHtlPy5tZXNzYWdlfWAsIHR5cGU6ICJlcnIiIH0pOyB9IGFkdmFuY2UoIkVtb2ppcyIpOyB9DQogICAgc2V0UHJvZ3Jlc3MoMTAwKTsN'
                'CiAgICBpZiAoX2NhbmNlbGxlZCkgeyBUb2FzdHMuc2hvdyh7IG1lc3NhZ2U6ICJDbG9uaW5nIGNhbmNlbGxlZC4iLCB0eXBlOiBUb2FzdHMuVHlwZS5GQUlM'
                'VVJFLCBpZDogVG9hc3RzLmdlbklkKCkgfSk7IH0NCiAgICBlbHNlIHsgbG9nKHsgdGV4dDogIkRvbmUuIiwgdHlwZTogImluZm8iIH0pOyBUb2FzdHMuc2hv'
                'dyh7IG1lc3NhZ2U6ICJTZXJ2ZXIgY2xvbmluZyBmaW5pc2hlZCEiLCB0eXBlOiBUb2FzdHMuVHlwZS5TVUNDRVNTLCBpZDogVG9hc3RzLmdlbklkKCkgfSk7'
                'IH0NCn0NCg0KZnVuY3Rpb24gU2VydmVyQ2xvbmVyVUkoeyBpbml0aWFsU291cmNlSWQgPSAiIiB9OiB7IGluaXRpYWxTb3VyY2VJZD86IHN0cmluZyB9KSB7'
                'DQogICAgY29uc3QgW3NvdXJjZUlkLCBzZXRTb3VyY2VJZF0gPSB1c2VTdGF0ZTxzdHJpbmc+KGluaXRpYWxTb3VyY2VJZCk7IGNvbnN0IFt0YXJnZXRJZCwg'
                'c2V0VGFyZ2V0SWRdID0gdXNlU3RhdGU8c3RyaW5nPigiIik7DQogICAgY29uc3QgW29wdHMsIHNldE9wdHNdID0gdXNlU3RhdGU8Q2xvbmVPcHRpb25zPih7'
                'IHJvbGVzOiB0cnVlLCBjbGVhclJvbGVzOiB0cnVlLCBjaGFubmVsczogdHJ1ZSwgbm9EZWxldGVDaGFubmVsczogZmFsc2UsIHBlcm1pc3Npb25zOiB0cnVl'
                'LCBpY29uOiB0cnVlLCBlbW9qaXM6IHRydWUsIGd1aWxkU2V0dGluZ3M6IHRydWUgfSk7DQogICAgY29uc3QgWywgZm9yY2VVcGRhdGVdID0gdXNlU3RhdGUo'
                'MCk7IGNvbnN0IGxvZ1JlZiA9IHVzZVJlZjxIVE1MRGl2RWxlbWVudD4obnVsbCk7DQogICAgUmVhY3QudXNlRWZmZWN0KCgpID0+IHsgY29uc3QgbCA9ICgp'
                'ID0+IGZvcmNlVXBkYXRlKG4gPT4gbiArIDEpOyBfbGlzdGVuZXJzLmFkZChsKTsgcmV0dXJuICgpID0+IHsgX2xpc3RlbmVycy5kZWxldGUobCk7IH07IH0s'
                'IFtdKTsNCiAgICBSZWFjdC51c2VFZmZlY3QoKCkgPT4geyBpZiAobG9nUmVmLmN1cnJlbnQpIGxvZ1JlZi5jdXJyZW50LnNjcm9sbFRvcCA9IGxvZ1JlZi5j'
                'dXJyZW50LnNjcm9sbEhlaWdodDsgfSwgW19sb2dzLmxlbmd0aF0pOw0KICAgIGNvbnN0IGFsbEd1aWxkcyA9IHVzZU1lbW8oKCkgPT4gT2JqZWN0LnZhbHVl'
                'cyhHdWlsZFN0b3JlLmdldEd1aWxkcygpIGFzIFJlY29yZDxzdHJpbmcsIGFueT4pLnNvcnQoKGEsIGIpID0+IGEubmFtZS5sb2NhbGVDb21wYXJlKGIubmFt'
                'ZSkpLm1hcChnID0+ICh7IGxhYmVsOiBnLm5hbWUsIHZhbHVlOiBnLmlkIH0pKSwgW10pOw0KICAgIGNvbnN0IGFkbWluR3VpbGRzID0gdXNlTWVtbygoKSA9'
                'PiBhbGxHdWlsZHMuZmlsdGVyKGcgPT4gaGFzQWRtaW4oZy52YWx1ZSkpLCBbYWxsR3VpbGRzXSk7DQogICAgYXN5bmMgZnVuY3Rpb24gc3RhcnRDbG9uZSgp'
                'IHsgaWYgKCFzb3VyY2VJZCB8fCAhdGFyZ2V0SWQgfHwgX3J1bm5pbmcpIHJldHVybjsgaWYgKHNvdXJjZUlkID09PSB0YXJnZXRJZCkgeyBwZXJzaXN0TG9n'
                'KHsgdGV4dDogIlNvdXJjZSBhbmQgdGFyZ2V0IGNhbm5vdCBiZSB0aGUgc2FtZSEiLCB0eXBlOiAiZXJyIiB9KTsgcmV0dXJuOyB9IHBlcnNpc3RSdW5uaW5n'
                'KHRydWUpOyBfcHJvZ3Jlc3MgPSAwOyBfbG9ncyA9IFtdOyBub3RpZnlMaXN0ZW5lcnMoKTsgdHJ5IHsgYXdhaXQgY2xvbmVTZXJ2ZXIoc291cmNlSWQsIHRh'
                'cmdldElkLCBvcHRzLCBwZXJzaXN0TG9nLCBwZXJzaXN0UHJvZ3Jlc3MpOyB9IGNhdGNoIChlOiBhbnkpIHsgcGVyc2lzdExvZyh7IHRleHQ6IGBGYXRhbDog'
                'JHtlPy5tZXNzYWdlfWAsIHR5cGU6ICJlcnIiIH0pOyB9IHBlcnNpc3RSdW5uaW5nKGZhbHNlKTsgfQ0KICAgIGNvbnN0IGxvZ0NvbG9yczogUmVjb3JkPHN0'
                'cmluZywgc3RyaW5nPiA9IHsgb2s6ICIjM2JhNTVkIiwgZXJyOiAiI2VkNDI0NSIsIHdhcm46ICIjZmFhODFhIiwgaW5mbzogIiNkY2RkZGUiIH07DQogICAg'
                'Y29uc3QgT1BUUyA9IFt7IGtleTogImd1aWxkU2V0dGluZ3MiLCBsYWJlbDogIlNlcnZlciBzZXR0aW5ncyIgfSwgeyBrZXk6ICJpY29uIiwgbGFiZWw6ICJJ'
                'Y29uIiB9LCB7IGtleTogInJvbGVzIiwgbGFiZWw6ICJSb2xlcyIgfSwgeyBrZXk6ICJjbGVhclJvbGVzIiwgbGFiZWw6ICJEZWxldGUgZXhpc3Rpbmcgcm9s'
                'ZXMiIH0sIHsga2V5OiAiY2hhbm5lbHMiLCBsYWJlbDogIkNoYW5uZWxzIiB9LCB7IGtleTogIm5vRGVsZXRlQ2hhbm5lbHMiLCBsYWJlbDogIktlZXAgZXhp'
                'c3RpbmcgY2hhbm5lbHMiIH0sIHsga2V5OiAicGVybWlzc2lvbnMiLCBsYWJlbDogIlBlcm1pc3Npb25zIiB9LCB7IGtleTogImVtb2ppcyIsIGxhYmVsOiAi'
                'RW1vamlzIiB9XSBhcyBjb25zdDsNCiAgICByZXR1cm4gKA0KICAgICAgICA8ZGl2IHN0eWxlPXt7IGRpc3BsYXk6ICJmbGV4IiwgZmxleERpcmVjdGlvbjog'
                'ImNvbHVtbiIsIGdhcDogMTYgfX0+DQogICAgICAgICAgICA8Ri5Gb3JtU2VjdGlvbj48Ri5Gb3JtVGl0bGU+U291cmNlIHNlcnZlcjwvRi5Gb3JtVGl0bGU+'
                'PFNlbGVjdCBvcHRpb25zPXthbGxHdWlsZHN9IHBsYWNlaG9sZGVyPSJDaG9vc2UuLi4iIGlzU2VsZWN0ZWQ9e3YgPT4gdiA9PT0gc291cmNlSWR9IHNlbGVj'
                'dD17diA9PiBzZXRTb3VyY2VJZCh2KX0gc2VyaWFsaXplPXt2ID0+IHZ9IC8+PC9GLkZvcm1TZWN0aW9uPg0KICAgICAgICAgICAgPEYuRm9ybVNlY3Rpb24+'
                'PEYuRm9ybVRpdGxlPlRhcmdldCBzZXJ2ZXIgKEFETUlOIHJlcXVpcmVkKTwvRi5Gb3JtVGl0bGU+e2FkbWluR3VpbGRzLmxlbmd0aCA9PT0gMCA/IDxGLkZv'
                'cm1UZXh0IHN0eWxlPXt7IGNvbG9yOiAidmFyKC0tdGV4dC1kYW5nZXIpIiB9fT5ObyBhZG1pbiBzZXJ2ZXJzIGZvdW5kLjwvRi5Gb3JtVGV4dD4gOiA8U2Vs'
                'ZWN0IG9wdGlvbnM9e2FkbWluR3VpbGRzfSBwbGFjZWhvbGRlcj0iQ2hvb3NlLi4uIiBpc1NlbGVjdGVkPXt2ID0+IHYgPT09IHRhcmdldElkfSBzZWxlY3Q9'
                'e3YgPT4gc2V0VGFyZ2V0SWQodil9IHNlcmlhbGl6ZT17diA9PiB2fSAvPn08L0YuRm9ybVNlY3Rpb24+DQogICAgICAgICAgICA8Ri5Gb3JtRGl2aWRlciAv'
                'Pg0KICAgICAgICAgICAgPEYuRm9ybVNlY3Rpb24+PEYuRm9ybVRpdGxlPk9wdGlvbnM8L0YuRm9ybVRpdGxlPjxkaXYgc3R5bGU9e3sgZGlzcGxheTogImdy'
                'aWQiLCBncmlkVGVtcGxhdGVDb2x1bW5zOiAiMWZyIDFmciIsIGdhcDogIjAgMjRweCIgfX0+e09QVFMubWFwKG8gPT4gPEZvcm1Td2l0Y2gga2V5PXtvLmtl'
                'eX0gdGl0bGU9e28ubGFiZWx9IHZhbHVlPXtvcHRzW28ua2V5XX0gb25DaGFuZ2U9e3YgPT4gc2V0T3B0cyhwID0+ICh7IC4uLnAsIFtvLmtleV06IHYgfSkp'
                'fSBkaXNhYmxlZD17X3J1bm5pbmd9IGhpZGVCb3JkZXIgLz4pfTwvZGl2PjwvRi5Gb3JtU2VjdGlvbj4NCiAgICAgICAgICAgIDxGLkZvcm1EaXZpZGVyIC8+'
                'DQogICAgICAgICAgICA8ZGl2IHN0eWxlPXt7IGRpc3BsYXk6ICJmbGV4IiwgZ2FwOiA4IH19Pg0KICAgICAgICAgICAgICAgIDxCdXR0b24gc2l6ZT17QnV0'
                'dG9uLlNpemVzLk1FRElVTX0gY29sb3I9e19ydW5uaW5nID8gQnV0dG9uLkNvbG9ycy5QUklNQVJZIDogQnV0dG9uLkNvbG9ycy5CUkFORH0gZGlzYWJsZWQ9'
                'eyFzb3VyY2VJZCB8fCAhdGFyZ2V0SWQgfHwgX3J1bm5pbmd9IG9uQ2xpY2s9e3N0YXJ0Q2xvbmV9IHN0eWxlPXt7IGZsZXg6IDEgfX0+e19ydW5uaW5nID8g'
                'IkNsb25pbmcuLi4iIDogIlN0YXJ0IGNsb25pbmcifTwvQnV0dG9uPg0KICAgICAgICAgICAgICAgIHtfcnVubmluZyAmJiA8QnV0dG9uIHNpemU9e0J1dHRv'
                'bi5TaXplcy5NRURJVU19IGNvbG9yPXtCdXR0b24uQ29sb3JzLlJFRH0gb25DbGljaz17KCkgPT4geyBfY2FuY2VsbGVkID0gdHJ1ZTsgfX0gc3R5bGU9e3sg'
                'bWluV2lkdGg6IDEwMCB9fT5TdG9wPC9CdXR0b24+fQ0KICAgICAgICAgICAgPC9kaXY+DQogICAgICAgICAgICB7X3J1bm5pbmcgJiYgPGRpdiBzdHlsZT17'
                'eyBoZWlnaHQ6IDgsIGJhY2tncm91bmQ6ICJ2YXIoLS1iYWNrZ3JvdW5kLW1vZGlmaWVyLWFjY2VudCkiLCBib3JkZXJSYWRpdXM6IDQsIG92ZXJmbG93OiAi'
                'aGlkZGVuIiB9fT48ZGl2IHN0eWxlPXt7IGhlaWdodDogIjEwMCUiLCB3aWR0aDogYCR7X3Byb2dyZXNzfSVgLCBiYWNrZ3JvdW5kOiAidmFyKC0tYnJhbmQt'
                'ZXhwZXJpbWVudCkiLCB0cmFuc2l0aW9uOiAid2lkdGggMC4zcyIgfX0gLz48L2Rpdj59DQogICAgICAgICAgICB7X2xvZ3MubGVuZ3RoID4gMCAmJiA8ZGl2'
                'IHJlZj17bG9nUmVmfSBzdHlsZT17eyBtYXhIZWlnaHQ6IDIwMCwgb3ZlcmZsb3dZOiAiYXV0byIsIGJhY2tncm91bmQ6ICJ2YXIoLS1iYWNrZ3JvdW5kLXNl'
                'Y29uZGFyeSkiLCBib3JkZXJSYWRpdXM6IDQsIHBhZGRpbmc6IDgsIGZvbnRGYW1pbHk6ICJtb25vc3BhY2UiLCBmb250U2l6ZTogMTIgfX0+e19sb2dzLm1h'
                'cCgobCwgaSkgPT4gPGRpdiBrZXk9e2l9IHN0eWxlPXt7IGNvbG9yOiBsb2dDb2xvcnNbbC50eXBlXSwgbWFyZ2luQm90dG9tOiAyIH19PntsLnRleHR9PC9k'
                'aXY+KX08L2Rpdj59DQogICAgICAgIDwvZGl2Pg0KICAgICk7DQp9DQoNCmZ1bmN0aW9uIFNlcnZlckNsb25lck1vZGFsKHsgcm9vdFByb3BzLCBndWlsZElk'
                'IH06IHsgcm9vdFByb3BzOiBSZW5kZXJNb2RhbFByb3BzOyBndWlsZElkOiBzdHJpbmcgfSkgew0KICAgIHJldHVybiA8TW9kYWwgey4uLnJvb3RQcm9wc30g'
                'c2l6ZT0ibGciIHRpdGxlPSJTZXJ2ZXIgQ2xvbmVyIj48ZGl2IHN0eWxlPXt7IHBhZGRpbmdCb3R0b206IDggfX0+PFNlcnZlckNsb25lclVJIGluaXRpYWxT'
                'b3VyY2VJZD17Z3VpbGRJZH0gLz48L2Rpdj48L01vZGFsPjsNCn0NCg0KY29uc3QgcGF0Y2hHdWlsZENvbnRleHQ6IE5hdkNvbnRleHRNZW51UGF0Y2hDYWxs'
                'YmFjayA9IChjaGlsZHJlbiwgeyBndWlsZCB9KSA9PiB7IGlmICghY2hpbGRyZW4gfHwgIUFycmF5LmlzQXJyYXkoY2hpbGRyZW4pIHx8ICFndWlsZCkgcmV0'
                'dXJuOyB0cnkgeyBjaGlsZHJlbi5wdXNoKDxNZW51Lk1lbnVJdGVtIGlkPSJzZXJ2ZXItY2xvbmVyIiBrZXk9InNlcnZlci1jbG9uZXIiIGxhYmVsPSJTZXJ2'
                'ZXJDbG9uZXIiIGFjdGlvbj17KCkgPT4gb3Blbk1vZGFsKHByb3BzID0+IDxTZXJ2ZXJDbG9uZXJNb2RhbCByb290UHJvcHM9e3Byb3BzfSBndWlsZElkPXtn'
                'dWlsZC5pZH0gLz4pfSAvPik7IH0gY2F0Y2ggeyB9IH07DQpjb25zdCBzZXR0aW5ncyA9IGRlZmluZVBsdWdpblNldHRpbmdzKHsgY2xvbmVyOiB7IHR5cGU6'
                'IE9wdGlvblR5cGUuQ09NUE9ORU5ULCBkZXNjcmlwdGlvbjogIiIsIGNvbXBvbmVudDogU2VydmVyQ2xvbmVyVUkgYXMgYW55IH0gfSk7DQoNCmV4cG9ydCBk'
                'ZWZhdWx0IGRlZmluZVBsdWdpbih7DQogICAgbmFtZTogIlNlcnZlckNsb25lciIsIGVuYWJsZWRCeURlZmF1bHQ6IHRydWUsDQogICAgZGVzY3JpcHRpb246'
                'ICJDbG9uZSBhbiBlbnRpcmUgc2VydmVyIHRvIGFub3RoZXIgc2VydmVyIHdoZXJlIHlvdSBoYXZlIEFETUlOLiBSaWdodC1jbGljayBhIHNlcnZlciB0byBv'
                'cGVuLiIsDQogICAgYXV0aG9yczogW3sgbmFtZTogIk5pZ2h0Y29yZCIsIGlkOiAwbiB9XSwgc2V0dGluZ3MsDQogICAgc3RhcnQoKSB7IGFkZENvbnRleHRN'
                'ZW51UGF0Y2goImd1aWxkLWNvbnRleHQiLCBwYXRjaEd1aWxkQ29udGV4dCk7IH0sDQogICAgc3RvcCgpIHsgcmVtb3ZlQ29udGV4dE1lbnVQYXRjaCgiZ3Vp'
                'bGQtY29udGV4dCIsIHBhdGNoR3VpbGRDb250ZXh0KTsgX2NhbmNlbGxlZCA9IHRydWU7IF9ydW5uaW5nID0gZmFsc2U7IF9saXN0ZW5lcnMuY2xlYXIoKTsg'
                'fQ0KfSk7DQo='
            ) -join '')
        }
    }
    [pscustomobject]@{
        Id = 'antiDeleteMessage'
        DisplayName = 'AntiDeleteMessage'
        FolderName = 'antiDeleteMessage'
        Description = 'Locally resends your messages when someone deletes them.'
        DefaultSelected = $true
        LegacyFolders = @('AntiDeleteMessage')
        Notes = 'Bounded cache setting and cleared delayed resend timers.'
        Files = [ordered]@{
            'index.ts' = (@(
                'LyoNCiAqIFZlbmNvcmQsIGEgRGlzY29yZCBjbGllbnQgbW9kDQogKiBDb3B5cmlnaHQgKGMpIDIwMjYgVmVuZGljYXRlZCBhbmQgY29udHJpYnV0b3JzDQog'
                'KiBTUERYLUxpY2Vuc2UtSWRlbnRpZmllcjogR1BMLTMuMC1vci1sYXRlcg0KICoNCiAqIE1vZGlmaWVkIGZvciBNeSBFcXVpY29yZCBTZXR1cCBieSBTcGVj'
                'dGF0b3IxNSwgMjAyNi0wOC0xNS4NCiAqIE9yaWdpbmFsIGNvcHlyaWdodCBhbmQgYXV0aG9yc2hpcCByZW1haW4gd2l0aCB0aGUgcmVzcGVjdGl2ZSB1cHN0'
                'cmVhbSBjb250cmlidXRvcnMuDQogKi8NCg0KaW1wb3J0ICogYXMgRGF0YVN0b3JlIGZyb20gIkBhcGkvRGF0YVN0b3JlIjsNCmltcG9ydCB7IGRlZmluZVBs'
                'dWdpblNldHRpbmdzIH0gZnJvbSAiQGFwaS9TZXR0aW5ncyI7DQppbXBvcnQgeyBMb2dnZXIgfSBmcm9tICJAdXRpbHMvTG9nZ2VyIjsNCmltcG9ydCBkZWZp'
                'bmVQbHVnaW4sIHsgT3B0aW9uVHlwZSB9IGZyb20gIkB1dGlscy90eXBlcyI7DQppbXBvcnQgeyBDb25zdGFudHMsIFJlc3RBUEksIFVzZXJTdG9yZSB9IGZy'
                'b20gIkB3ZWJwYWNrL2NvbW1vbiI7DQpjb25zdCBsb2dnZXIgPSBuZXcgTG9nZ2VyKCJBbnRpRGVsZXRlTWVzc2FnZSIpOw0KY29uc3Qgc2V0dGluZ3MgPSBk'
                'ZWZpbmVQbHVnaW5TZXR0aW5ncyh7DQogICAgZW5hYmxlZDogeyB0eXBlOiBPcHRpb25UeXBlLkJPT0xFQU4sIGRlc2NyaXB0aW9uOiAiRW5hYmxlIGF1dG9t'
                'YXRpYyBtZXNzYWdlIHJlc3RvcmF0aW9uIiwgZGVmYXVsdDogdHJ1ZSB9LA0KICAgIGRtUHJvdGVjdGlvbjogeyB0eXBlOiBPcHRpb25UeXBlLkJPT0xFQU4s'
                'IGRlc2NyaXB0aW9uOiAiQWxzbyBwcm90ZWN0IERNcyIsIGRlZmF1bHQ6IGZhbHNlIH0sDQogICAgbWF4Q2FjaGVTaXplOiB7IHR5cGU6IE9wdGlvblR5cGUu'
                'TlVNQkVSLCBkZXNjcmlwdGlvbjogIk1heCBtZXNzYWdlcyBjYWNoZWQiLCBkZWZhdWx0OiA1MDAgfSwNCiAgICBzZXJ2ZXJCbGFja2xpc3Q6IHsgdHlwZTog'
                'T3B0aW9uVHlwZS5TVFJJTkcsIGRlc2NyaXB0aW9uOiAiU2VydmVyIElEcyB0byBpZ25vcmUgKGNvbW1hLXNlcGFyYXRlZCkiLCBkZWZhdWx0OiAiIiB9DQp9'
                'KTsNCmNvbnN0IERCX0tFWSA9ICJBbnRpRGVsZXRlTWVzc2FnZV9jYWNoZSI7DQppbnRlcmZhY2UgQ2FjaGVkTWVzc2FnZSB7IGNvbnRlbnQ6IHN0cmluZzsg'
                'Y2hhbm5lbElkOiBzdHJpbmc7IG5vbmNlOiBzdHJpbmc7IGd1aWxkSWQ/OiBzdHJpbmc7IG1lc3NhZ2VSZWZlcmVuY2U/OiBhbnk7IHNhdmVkQXQ6IG51bWJl'
                'cjsgfQ0KbGV0IG1lbUNhY2hlOiBSZWNvcmQ8c3RyaW5nLCBDYWNoZWRNZXNzYWdlPiA9IHt9OyBsZXQgZGJMb2FkZWQgPSBmYWxzZTsNCmFzeW5jIGZ1bmN0'
                'aW9uIGxvYWRDYWNoZSgpIHsgdHJ5IHsgY29uc3Qgc3RvcmVkID0gYXdhaXQgRGF0YVN0b3JlLmdldDxSZWNvcmQ8c3RyaW5nLCBDYWNoZWRNZXNzYWdlPj4o'
                'REJfS0VZKTsgaWYgKHN0b3JlZCAmJiB0eXBlb2Ygc3RvcmVkID09PSAib2JqZWN0IikgbWVtQ2FjaGUgPSBzdG9yZWQ7IH0gY2F0Y2ggKGVycm9yKSB7IGxv'
                'Z2dlci5lcnJvcigiRmFpbGVkIHRvIGxvYWQgdGhlIG1lc3NhZ2UgY2FjaGUiLCBlcnJvcik7IH0gZmluYWxseSB7IGRiTG9hZGVkID0gdHJ1ZTsgfSB9DQps'
                'ZXQgc2F2ZVRpbWVyOiBSZXR1cm5UeXBlPHR5cGVvZiBzZXRUaW1lb3V0PiB8IG51bGwgPSBudWxsOw0KY29uc3QgcmVzZW5kVGltZXJzID0gbmV3IFNldDxS'
                'ZXR1cm5UeXBlPHR5cGVvZiBzZXRUaW1lb3V0Pj4oKTsNCmZ1bmN0aW9uIHNjaGVkdWxlU2F2ZSgpIHsgaWYgKHNhdmVUaW1lcikgY2xlYXJUaW1lb3V0KHNh'
                'dmVUaW1lcik7IHNhdmVUaW1lciA9IHNldFRpbWVvdXQoYXN5bmMgKCkgPT4geyBzYXZlVGltZXIgPSBudWxsOyB0cnkgeyBhd2FpdCBEYXRhU3RvcmUuc2V0'
                'KERCX0tFWSwgbWVtQ2FjaGUpOyB9IGNhdGNoIChlcnJvcikgeyBsb2dnZXIuZXJyb3IoIkZhaWxlZCB0byBzYXZlIHRoZSBtZXNzYWdlIGNhY2hlIiwgZXJy'
                'b3IpOyB9IH0sIDEwMDApOyB9DQpmdW5jdGlvbiBnZXRCbGFja2xpc3QoKSB7IHJldHVybiBuZXcgU2V0KChzZXR0aW5ncy5zdG9yZS5zZXJ2ZXJCbGFja2xp'
                'c3QgPz8gIiIpLnNwbGl0KCIsIikubWFwKChzOiBzdHJpbmcpID0+IHMudHJpbSgpKS5maWx0ZXIoQm9vbGVhbikpOyB9DQpmdW5jdGlvbiBhZGRUb0NhY2hl'
                'KGlkOiBzdHJpbmcsIGRhdGE6IENhY2hlZE1lc3NhZ2UpIHsgY29uc3QgbWF4ID0gTWF0aC5tYXgoMTAsIE1hdGgubWluKDUwMDAsIE51bWJlcihzZXR0aW5n'
                'cy5zdG9yZS5tYXhDYWNoZVNpemUpIHx8IDUwMCkpOyBjb25zdCBpZHMgPSBPYmplY3Qua2V5cyhtZW1DYWNoZSk7IGlmIChpZHMubGVuZ3RoID49IG1heCkg'
                'aWRzLnNvcnQoKGEsIGIpID0+IChtZW1DYWNoZVthXS5zYXZlZEF0ID8/IDApIC0gKG1lbUNhY2hlW2JdLnNhdmVkQXQgPz8gMCkpLnNsaWNlKDAsIE1hdGgu'
                'bWF4KDEsIE1hdGguZmxvb3IobWF4ICogMC4xKSkpLmZvckVhY2goayA9PiBkZWxldGUgbWVtQ2FjaGVba10pOyBtZW1DYWNoZVtpZF0gPSBkYXRhOyBzY2hl'
                'ZHVsZVNhdmUoKTsgfQ0KYXN5bmMgZnVuY3Rpb24gcmVzZW5kTWVzc2FnZShjOiBDYWNoZWRNZXNzYWdlKSB7IHRyeSB7IGNvbnN0IGJvZHk6IGFueSA9IHsg'
                'Y29udGVudDogYy5jb250ZW50LCBmbGFnczogMCwgbW9iaWxlX25ldHdvcmtfdHlwZTogInVua25vd24iLCBub25jZTogYy5ub25jZSwgdHRzOiBmYWxzZSB9'
                'OyBpZiAoYy5tZXNzYWdlUmVmZXJlbmNlKSBib2R5Lm1lc3NhZ2VfcmVmZXJlbmNlID0gYy5tZXNzYWdlUmVmZXJlbmNlOyBjb25zdCByZXNwb25zZSA9IGF3'
                'YWl0IFJlc3RBUEkucG9zdCh7IHVybDogQ29uc3RhbnRzLkVuZHBvaW50cy5NRVNTQUdFUyhjLmNoYW5uZWxJZCksIGJvZHkgfSk7IGNvbnN0IHN0YXR1cyA9'
                'IE51bWJlcihyZXNwb25zZT8uc3RhdHVzID8/IDIwMCk7IGlmIChyZXNwb25zZT8ub2sgPT09IGZhbHNlIHx8IHN0YXR1cyA+PSA0MDApIHRocm93IG5ldyBF'
                'cnJvcihgRGlzY29yZCByZXR1cm5lZCAke3N0YXR1c31gKTsgfSBjYXRjaCAoZXJyb3IpIHsgbG9nZ2VyLmVycm9yKCJGYWlsZWQgdG8gcmVzdG9yZSBhIGRl'
                'bGV0ZWQgbWVzc2FnZSIsIGVycm9yKTsgfSB9DQpleHBvcnQgZGVmYXVsdCBkZWZpbmVQbHVnaW4oew0KICAgIG5hbWU6ICJBbnRpRGVsZXRlTWVzc2FnZSIs'
                'IGRlc2NyaXB0aW9uOiAiQXV0b21hdGljYWxseSByZXNlbmRzIHlvdXIgbWVzc2FnZXMgaWYgc29tZW9uZSBkZWxldGVzIHRoZW0uIiwgYXV0aG9yczogW3sg'
                'bmFtZTogIk5pZ2h0Y29yZCIsIGlkOiAwbiB9XSwgZW5hYmxlZEJ5RGVmYXVsdDogZmFsc2UsIHNldHRpbmdzLA0KICAgIGZsdXg6IHsNCiAgICAgICAgTUVT'
                'U0FHRV9DUkVBVEUoeyBtZXNzYWdlLCBndWlsZElkIH06IHsgbWVzc2FnZTogeyBpZDogc3RyaW5nOyBhdXRob3I6IHsgaWQ6IHN0cmluZzsgfTsgY29udGVu'
                'dDogc3RyaW5nOyBjaGFubmVsX2lkOiBzdHJpbmc7IG5vbmNlPzogc3RyaW5nOyBtZXNzYWdlX3JlZmVyZW5jZT86IGFueTsgfTsgZ3VpbGRJZD86IHN0cmlu'
                'ZzsgfSkgew0KICAgICAgICAgICAgaWYgKCFzZXR0aW5ncy5zdG9yZS5lbmFibGVkIHx8ICFkYkxvYWRlZCkgcmV0dXJuOw0KICAgICAgICAgICAgY29uc3Qg'
                'bWUgPSBVc2VyU3RvcmUuZ2V0Q3VycmVudFVzZXIoKTsgaWYgKCFtZSB8fCBtZXNzYWdlLmF1dGhvci5pZCAhPT0gbWUuaWQgfHwgIW1lc3NhZ2UuY29udGVu'
                'dD8udHJpbSgpKSByZXR1cm47DQogICAgICAgICAgICBpZiAoIWd1aWxkSWQgJiYgIXNldHRpbmdzLnN0b3JlLmRtUHJvdGVjdGlvbikgcmV0dXJuOw0KICAg'
                'ICAgICAgICAgaWYgKGd1aWxkSWQgJiYgZ2V0QmxhY2tsaXN0KCkuaGFzKGd1aWxkSWQpKSByZXR1cm47DQogICAgICAgICAgICBhZGRUb0NhY2hlKG1lc3Nh'
                'Z2UuaWQsIHsgY29udGVudDogbWVzc2FnZS5jb250ZW50LCBjaGFubmVsSWQ6IG1lc3NhZ2UuY2hhbm5lbF9pZCwgbm9uY2U6IG1lc3NhZ2UuaWQsIGd1aWxk'
                'SWQsIG1lc3NhZ2VSZWZlcmVuY2U6IG1lc3NhZ2UubWVzc2FnZV9yZWZlcmVuY2UsIHNhdmVkQXQ6IERhdGUubm93KCkgfSk7DQogICAgICAgIH0sDQogICAg'
                'ICAgIE1FU1NBR0VfREVMRVRFKHsgaWQsIGNoYW5uZWxJZCB9OiB7IGlkOiBzdHJpbmc7IGNoYW5uZWxJZDogc3RyaW5nOyB9KSB7DQogICAgICAgICAgICBp'
                'ZiAoIXNldHRpbmdzLnN0b3JlLmVuYWJsZWQpIHJldHVybjsgY29uc3QgYyA9IG1lbUNhY2hlW2lkXTsgaWYgKCFjKSByZXR1cm47DQogICAgICAgICAgICBp'
                'ZiAoYy5ndWlsZElkICYmIGdldEJsYWNrbGlzdCgpLmhhcyhjLmd1aWxkSWQpKSB7IGRlbGV0ZSBtZW1DYWNoZVtpZF07IHNjaGVkdWxlU2F2ZSgpOyByZXR1'
                'cm47IH0NCiAgICAgICAgICAgIGRlbGV0ZSBtZW1DYWNoZVtpZF07IHNjaGVkdWxlU2F2ZSgpOyBjb25zdCB0aW1lciA9IHNldFRpbWVvdXQoKCkgPT4geyBy'
                'ZXNlbmRUaW1lcnMuZGVsZXRlKHRpbWVyKTsgcmVzZW5kTWVzc2FnZShjKTsgfSwgNDAwKTsgcmVzZW5kVGltZXJzLmFkZCh0aW1lcik7DQogICAgICAgIH0s'
                'DQogICAgfSwNCiAgICBhc3luYyBzdGFydCgpIHsgYXdhaXQgbG9hZENhY2hlKCk7IH0sDQogICAgc3RvcCgpIHsgaWYgKHNhdmVUaW1lcikgeyBjbGVhclRp'
                'bWVvdXQoc2F2ZVRpbWVyKTsgc2F2ZVRpbWVyID0gbnVsbDsgRGF0YVN0b3JlLnNldChEQl9LRVksIG1lbUNhY2hlKS5jYXRjaChlcnJvciA9PiBsb2dnZXIu'
                'ZXJyb3IoIkZhaWxlZCB0byBmbHVzaCB0aGUgbWVzc2FnZSBjYWNoZSIsIGVycm9yKSk7IH0gcmVzZW5kVGltZXJzLmZvckVhY2godGltZXIgPT4gY2xlYXJU'
                'aW1lb3V0KHRpbWVyKSk7IHJlc2VuZFRpbWVycy5jbGVhcigpOyBtZW1DYWNoZSA9IHt9OyBkYkxvYWRlZCA9IGZhbHNlOyB9DQp9KTsNCg=='
            ) -join '')
        }
    }
    [pscustomobject]@{
        Id = 'lastSeen'
        DisplayName = 'LastSeen'
        FolderName = 'lastSeen'
        Description = 'Shows a user''s last observed activity in the profile panel.'
        DefaultSelected = $true
        LegacyFolders = @('LastSeen')
        Notes = 'Subscribes/unsubscribes Flux events explicitly.'
        Files = [ordered]@{
            'index.tsx' = (@(
                'LyoNCiAqIFZlbmNvcmQsIGEgRGlzY29yZCBjbGllbnQgbW9kDQogKiBDb3B5cmlnaHQgKGMpIDIwMjYgVmVuZGljYXRlZCBhbmQgY29udHJpYnV0b3JzDQog'
                'KiBTUERYLUxpY2Vuc2UtSWRlbnRpZmllcjogR1BMLTMuMC1vci1sYXRlcg0KICoNCiAqIE1vZGlmaWVkIGZvciBNeSBFcXVpY29yZCBTZXR1cCBieSBTcGVj'
                'dGF0b3IxNSwgMjAyNi0wOC0xNS4NCiAqIE9yaWdpbmFsIGNvcHlyaWdodCBhbmQgYXV0aG9yc2hpcCByZW1haW4gd2l0aCB0aGUgcmVzcGVjdGl2ZSB1cHN0'
                'cmVhbSBjb250cmlidXRvcnMuDQogKi8NCg0KaW1wb3J0ICogYXMgRGF0YVN0b3JlIGZyb20gIkBhcGkvRGF0YVN0b3JlIjsNCmltcG9ydCB7IGRlZmluZVBs'
                'dWdpblNldHRpbmdzIH0gZnJvbSAiQGFwaS9TZXR0aW5ncyI7DQppbXBvcnQgRXJyb3JCb3VuZGFyeSBmcm9tICJAY29tcG9uZW50cy9FcnJvckJvdW5kYXJ5'
                'IjsNCmltcG9ydCB7IExvZ2dlciB9IGZyb20gIkB1dGlscy9Mb2dnZXIiOw0KaW1wb3J0IGRlZmluZVBsdWdpbiwgeyBPcHRpb25UeXBlIH0gZnJvbSAiQHV0'
                'aWxzL3R5cGVzIjsNCmltcG9ydCB7IGZpbmRCeVByb3BzTGF6eSwgZmluZENvbXBvbmVudEJ5Q29kZUxhenkgfSBmcm9tICJAd2VicGFjayI7DQppbXBvcnQg'
                'eyBSZWFjdCwgdXNlU3RhdGVGcm9tU3RvcmVzIH0gZnJvbSAiQHdlYnBhY2svY29tbW9uIjsNCg0KY29uc3QgU2VjdGlvbiA9IGZpbmRDb21wb25lbnRCeUNv'
                'ZGVMYXp5KCJoZWFkaW5nVmFyaWFudDoiLCAnInNlY3Rpb24iJywgImhlYWRpbmdJY29uOiIpOw0KY29uc3QgUHJlc2VuY2VTdG9yZSA9IGZpbmRCeVByb3Bz'
                'TGF6eSgiZ2V0U3RhdHVzIiwgImdldEFjdGl2aXRpZXMiKTsNCmNvbnN0IGxvZ2dlciA9IG5ldyBMb2dnZXIoIkxhc3RTZWVuIik7DQoNCmNvbnN0IHNldHRp'
                'bmdzID0gZGVmaW5lUGx1Z2luU2V0dGluZ3Moew0KICAgIGxhbmd1YWdlOiB7DQogICAgICAgIHR5cGU6IE9wdGlvblR5cGUuU0VMRUNULA0KICAgICAgICBk'
                'ZXNjcmlwdGlvbjogIkxhbmd1YWdlIiwNCiAgICAgICAgb3B0aW9uczogWw0KICAgICAgICAgICAgeyBsYWJlbDogIkVuZ2xpc2giLCB2YWx1ZTogImVuIiwg'
                'ZGVmYXVsdDogdHJ1ZSB9LA0KICAgICAgICAgICAgeyBsYWJlbDogIkZyYW5jYWlzIiwgdmFsdWU6ICJmciIgfQ0KICAgICAgICBdDQogICAgfQ0KfSk7DQoN'
                'CmNvbnN0IFNUT1JBR0VfS0VZID0gIkxhc3RTZWVuX2VudHJpZXNfdjIiOw0KY29uc3QgTEVHQUNZX1BSRUZJWCA9ICJsYXN0c2Vlbl8iOw0KY29uc3QgTUFY'
                'X0VOVFJJRVMgPSAyMDAwOw0KY29uc3QgU0FWRV9ERUxBWV9NUyA9IDEwMDA7DQoNCmxldCBlbnRyaWVzOiBSZWNvcmQ8c3RyaW5nLCBudW1iZXI+ID0ge307'
                'DQpsZXQgY2FjaGVMb2FkZWQgPSBmYWxzZTsNCmxldCBsb2FkUHJvbWlzZTogUHJvbWlzZTx2b2lkPiB8IG51bGwgPSBudWxsOw0KbGV0IHNhdmVUaW1lcjog'
                'UmV0dXJuVHlwZTx0eXBlb2Ygc2V0VGltZW91dD4gfCBudWxsID0gbnVsbDsNCmNvbnN0IGxpc3RlbmVycyA9IG5ldyBTZXQ8KCkgPT4gdm9pZD4oKTsNCg0K'
                'ZnVuY3Rpb24gbm90aWZ5TGlzdGVuZXJzKCkgew0KICAgIGxpc3RlbmVycy5mb3JFYWNoKGxpc3RlbmVyID0+IGxpc3RlbmVyKCkpOw0KfQ0KDQpmdW5jdGlv'
                'biB0cmltRW50cmllcygpIHsNCiAgICBjb25zdCBpZHMgPSBPYmplY3Qua2V5cyhlbnRyaWVzKTsNCiAgICBpZiAoaWRzLmxlbmd0aCA8PSBNQVhfRU5UUklF'
                'UykgcmV0dXJuOw0KICAgIGlkcy5zb3J0KChhLCBiKSA9PiBlbnRyaWVzW2JdIC0gZW50cmllc1thXSk7DQogICAgZW50cmllcyA9IE9iamVjdC5mcm9tRW50'
                'cmllcyhpZHMuc2xpY2UoMCwgTUFYX0VOVFJJRVMpLm1hcChpZCA9PiBbaWQsIGVudHJpZXNbaWRdXSkpOw0KfQ0KDQphc3luYyBmdW5jdGlvbiBlbnN1cmVD'
                'YWNoZUxvYWRlZCgpIHsNCiAgICBpZiAoY2FjaGVMb2FkZWQpIHJldHVybjsNCiAgICBpZiAobG9hZFByb21pc2UpIHJldHVybiBsb2FkUHJvbWlzZTsNCg0K'
                'ICAgIGxvYWRQcm9taXNlID0gKGFzeW5jICgpID0+IHsNCiAgICAgICAgdHJ5IHsNCiAgICAgICAgICAgIGNvbnN0IHN0b3JlZCA9IGF3YWl0IERhdGFTdG9y'
                'ZS5nZXQ8UmVjb3JkPHN0cmluZywgbnVtYmVyPj4oU1RPUkFHRV9LRVkpOw0KICAgICAgICAgICAgY29uc3QgdmFsaWQ6IFJlY29yZDxzdHJpbmcsIG51bWJl'
                'cj4gPSB7fTsNCiAgICAgICAgICAgIGlmIChzdG9yZWQgJiYgdHlwZW9mIHN0b3JlZCA9PT0gIm9iamVjdCIpIHsNCiAgICAgICAgICAgICAgICBmb3IgKGNv'
                'bnN0IFtpZCwgdGltZXN0YW1wXSBvZiBPYmplY3QuZW50cmllcyhzdG9yZWQpKSB7DQogICAgICAgICAgICAgICAgICAgIGNvbnN0IHZhbHVlID0gTnVtYmVy'
                'KHRpbWVzdGFtcCk7DQogICAgICAgICAgICAgICAgICAgIGlmICgvXlxkKyQvLnRlc3QoaWQpICYmIE51bWJlci5pc0Zpbml0ZSh2YWx1ZSkgJiYgdmFsdWUg'
                'PiAwKSB2YWxpZFtpZF0gPSB2YWx1ZTsNCiAgICAgICAgICAgICAgICB9DQogICAgICAgICAgICB9DQogICAgICAgICAgICBlbnRyaWVzID0geyAuLi52YWxp'
                'ZCwgLi4uZW50cmllcyB9Ow0KICAgICAgICAgICAgdHJpbUVudHJpZXMoKTsNCiAgICAgICAgfSBjYXRjaCAoZXJyb3IpIHsNCiAgICAgICAgICAgIGxvZ2dl'
                'ci5lcnJvcigiRmFpbGVkIHRvIGxvYWQgc3RvcmVkIGFjdGl2aXR5IHRpbWVzdGFtcHMiLCBlcnJvcik7DQogICAgICAgIH0gZmluYWxseSB7DQogICAgICAg'
                'ICAgICBjYWNoZUxvYWRlZCA9IHRydWU7DQogICAgICAgICAgICBsb2FkUHJvbWlzZSA9IG51bGw7DQogICAgICAgICAgICBub3RpZnlMaXN0ZW5lcnMoKTsN'
                'CiAgICAgICAgfQ0KICAgIH0pKCk7DQoNCiAgICByZXR1cm4gbG9hZFByb21pc2U7DQp9DQoNCmZ1bmN0aW9uIHNjaGVkdWxlU2F2ZSgpIHsNCiAgICBpZiAo'
                'c2F2ZVRpbWVyKSBjbGVhclRpbWVvdXQoc2F2ZVRpbWVyKTsNCiAgICBzYXZlVGltZXIgPSBzZXRUaW1lb3V0KGFzeW5jICgpID0+IHsNCiAgICAgICAgc2F2'
                'ZVRpbWVyID0gbnVsbDsNCiAgICAgICAgYXdhaXQgZW5zdXJlQ2FjaGVMb2FkZWQoKTsNCiAgICAgICAgdHJ5IHsNCiAgICAgICAgICAgIGF3YWl0IERhdGFT'
                'dG9yZS5zZXQoU1RPUkFHRV9LRVksIGVudHJpZXMpOw0KICAgICAgICB9IGNhdGNoIChlcnJvcikgew0KICAgICAgICAgICAgbG9nZ2VyLmVycm9yKCJGYWls'
                'ZWQgdG8gc2F2ZSBhY3Rpdml0eSB0aW1lc3RhbXBzIiwgZXJyb3IpOw0KICAgICAgICB9DQogICAgfSwgU0FWRV9ERUxBWV9NUyk7DQp9DQoNCmZ1bmN0aW9u'
                'IHJlY29yZFNlZW4odXNlcklkOiBzdHJpbmcgfCB1bmRlZmluZWQsIHRpbWVzdGFtcCA9IERhdGUubm93KCkpIHsNCiAgICBpZiAoIXVzZXJJZCB8fCAhL15c'
                'ZCskLy50ZXN0KHVzZXJJZCkpIHJldHVybjsNCiAgICB2b2lkIGVuc3VyZUNhY2hlTG9hZGVkKCk7DQogICAgZW50cmllc1t1c2VySWRdID0gdGltZXN0YW1w'
                'Ow0KICAgIHRyaW1FbnRyaWVzKCk7DQogICAgc2NoZWR1bGVTYXZlKCk7DQogICAgbm90aWZ5TGlzdGVuZXJzKCk7DQp9DQoNCmFzeW5jIGZ1bmN0aW9uIG1p'
                'Z3JhdGVMZWdhY3lFbnRyeSh1c2VySWQ6IHN0cmluZykgew0KICAgIGF3YWl0IGVuc3VyZUNhY2hlTG9hZGVkKCk7DQogICAgaWYgKGVudHJpZXNbdXNlcklk'
                'XSkgcmV0dXJuOw0KICAgIGNvbnN0IGxlZ2FjeUtleSA9IExFR0FDWV9QUkVGSVggKyB1c2VySWQ7DQogICAgdHJ5IHsNCiAgICAgICAgY29uc3QgdmFsdWUg'
                'PSBOdW1iZXIoYXdhaXQgRGF0YVN0b3JlLmdldChsZWdhY3lLZXkpKTsNCiAgICAgICAgaWYgKE51bWJlci5pc0Zpbml0ZSh2YWx1ZSkgJiYgdmFsdWUgPiAw'
                'KSB7DQogICAgICAgICAgICByZWNvcmRTZWVuKHVzZXJJZCwgdmFsdWUpOw0KICAgICAgICAgICAgYXdhaXQgRGF0YVN0b3JlLmRlbChsZWdhY3lLZXkpOw0K'
                'ICAgICAgICB9DQogICAgfSBjYXRjaCAoZXJyb3IpIHsNCiAgICAgICAgbG9nZ2VyLndhcm4oIkNvdWxkIG5vdCBtaWdyYXRlIGEgbGVnYWN5IGFjdGl2aXR5'
                'IHRpbWVzdGFtcCIsIGVycm9yKTsNCiAgICB9DQp9DQoNCmZ1bmN0aW9uIGZvcm1hdFRpbWVzdGFtcCh0aW1lc3RhbXA6IG51bWJlcik6IHN0cmluZyB7DQog'
                'ICAgY29uc3Qgbm93ID0gbmV3IERhdGUoKTsNCiAgICBjb25zdCBkYXRlID0gbmV3IERhdGUodGltZXN0YW1wKTsNCiAgICBjb25zdCBsYW5ndWFnZSA9IHNl'
                'dHRpbmdzLnN0b3JlLmxhbmd1YWdlID8/ICJlbiI7DQogICAgY29uc3QgbG9jYWxlID0gbGFuZ3VhZ2UgPT09ICJmciIgPyAiZnItRlIiIDogImVuLVVTIjsN'
                'CiAgICBjb25zdCB0aW1lID0gZGF0ZS50b0xvY2FsZVRpbWVTdHJpbmcobG9jYWxlLCB7IGhvdXI6ICIyLWRpZ2l0IiwgbWludXRlOiAiMi1kaWdpdCIsIHNl'
                'Y29uZDogIjItZGlnaXQiIH0pOw0KDQogICAgaWYgKGRhdGUudG9EYXRlU3RyaW5nKCkgPT09IG5vdy50b0RhdGVTdHJpbmcoKSkgcmV0dXJuIGxhbmd1YWdl'
                'ID09PSAiZnIiID8gYEF1am91cmQnaHVpIGEgJHt0aW1lfWAgOiBgVG9kYXkgYXQgJHt0aW1lfWA7DQogICAgY29uc3QgeWVzdGVyZGF5ID0gbmV3IERhdGUo'
                'bm93KTsNCiAgICB5ZXN0ZXJkYXkuc2V0RGF0ZShub3cuZ2V0RGF0ZSgpIC0gMSk7DQogICAgaWYgKGRhdGUudG9EYXRlU3RyaW5nKCkgPT09IHllc3RlcmRh'
                'eS50b0RhdGVTdHJpbmcoKSkgcmV0dXJuIGxhbmd1YWdlID09PSAiZnIiID8gYEhpZXIgYSAke3RpbWV9YCA6IGBZZXN0ZXJkYXkgYXQgJHt0aW1lfWA7DQog'
                'ICAgY29uc3QgZGF5ID0gZGF0ZS50b0xvY2FsZURhdGVTdHJpbmcobG9jYWxlLCB7IGRheTogIm51bWVyaWMiLCBtb250aDogInNob3J0IiB9KTsNCiAgICBy'
                'ZXR1cm4gbGFuZ3VhZ2UgPT09ICJmciIgPyBgTGUgJHtkYXl9IGEgJHt0aW1lfWAgOiBgJHtkYXl9IGF0ICR7dGltZX1gOw0KfQ0KDQpmdW5jdGlvbiBMYXN0'
                'U2VlblRleHQoeyB1c2VySWQgfTogeyB1c2VySWQ6IHN0cmluZzsgfSkgew0KICAgIGNvbnN0IHN0YXR1cyA9IHVzZVN0YXRlRnJvbVN0b3JlcyhbUHJlc2Vu'
                'Y2VTdG9yZV0sICgpID0+IFByZXNlbmNlU3RvcmUuZ2V0U3RhdHVzKHVzZXJJZCkpOw0KICAgIGNvbnN0IFssIGZvcmNlVXBkYXRlXSA9IFJlYWN0LnVzZVN0'
                'YXRlKDApOw0KDQogICAgUmVhY3QudXNlRWZmZWN0KCgpID0+IHsNCiAgICAgICAgbGV0IGFjdGl2ZSA9IHRydWU7DQogICAgICAgIGNvbnN0IGxpc3RlbmVy'
                'ID0gKCkgPT4geyBpZiAoYWN0aXZlKSBmb3JjZVVwZGF0ZSh2YWx1ZSA9PiB2YWx1ZSArIDEpOyB9Ow0KICAgICAgICBsaXN0ZW5lcnMuYWRkKGxpc3RlbmVy'
                'KTsNCiAgICAgICAgdm9pZCBtaWdyYXRlTGVnYWN5RW50cnkodXNlcklkKTsNCiAgICAgICAgcmV0dXJuICgpID0+IHsgYWN0aXZlID0gZmFsc2U7IGxpc3Rl'
                'bmVycy5kZWxldGUobGlzdGVuZXIpOyB9Ow0KICAgIH0sIFt1c2VySWRdKTsNCg0KICAgIGlmICghY2FjaGVMb2FkZWQpIHJldHVybiBudWxsOw0KICAgIGNv'
                'bnN0IGxhbmd1YWdlID0gc2V0dGluZ3Muc3RvcmUubGFuZ3VhZ2UgPz8gImVuIjsNCiAgICBjb25zdCBpc09ubGluZSA9IHN0YXR1cyAmJiBzdGF0dXMgIT09'
                'ICJvZmZsaW5lIiAmJiBzdGF0dXMgIT09ICJpbnZpc2libGUiOw0KICAgIGxldCBjb250ZW50OiBzdHJpbmc7DQogICAgbGV0IGNvbG9yID0gIiNkY2RkZGUi'
                'Ow0KDQogICAgaWYgKGlzT25saW5lKSB7DQogICAgICAgIGlmIChzdGF0dXMgPT09ICJpZGxlIikgeyBjb250ZW50ID0gbGFuZ3VhZ2UgPT09ICJmciIgPyAi'
                'SW5hY3RpZiIgOiAiSWRsZSI7IGNvbG9yID0gIiNmYWE4MWEiOyB9DQogICAgICAgIGVsc2UgaWYgKHN0YXR1cyA9PT0gImRuZCIpIHsgY29udGVudCA9IGxh'
                'bmd1YWdlID09PSAiZnIiID8gIk5lIHBhcyBkZXJhbmdlciIgOiAiRG8gTm90IERpc3R1cmIiOyBjb2xvciA9ICIjZWQ0MjQ1IjsgfQ0KICAgICAgICBlbHNl'
                'IGlmIChzdGF0dXMgPT09ICJzdHJlYW1pbmciKSB7IGNvbnRlbnQgPSBsYW5ndWFnZSA9PT0gImZyIiA/ICJFbiBkaXJlY3QiIDogIlN0cmVhbWluZyI7IGNv'
                'bG9yID0gIiM1OTM2OTUiOyB9DQogICAgICAgIGVsc2UgeyBjb250ZW50ID0gbGFuZ3VhZ2UgPT09ICJmciIgPyAiRW4gbGlnbmUiIDogIk9ubGluZSI7IGNv'
                'bG9yID0gIiMzYmE1NWQiOyB9DQogICAgfSBlbHNlIGlmIChlbnRyaWVzW3VzZXJJZF0pIHsNCiAgICAgICAgY29udGVudCA9IGZvcm1hdFRpbWVzdGFtcChl'
                'bnRyaWVzW3VzZXJJZF0pOw0KICAgICAgICBjb2xvciA9ICIjYjViYWMxIjsNCiAgICB9IGVsc2Ugew0KICAgICAgICBjb250ZW50ID0gbGFuZ3VhZ2UgPT09'
                'ICJmciIgPyAiUGFzIGVuY29yZSB0cmFjZSIgOiAiTm90IHRyYWNrZWQgeWV0IjsNCiAgICAgICAgY29sb3IgPSAiIzgwODQ4ZSI7DQogICAgfQ0KDQogICAg'
                'cmV0dXJuIDxkaXYgc3R5bGU9e3sgZm9udFNpemU6ICIxNHB4IiwgbGluZUhlaWdodDogIjE4cHgiLCBjb2xvciwgV2Via2l0VGV4dEZpbGxDb2xvcjogY29s'
                'b3IsIGZvbnRXZWlnaHQ6IDQwMCwgdXNlclNlbGVjdDogInRleHQiIH0gYXMgUmVhY3QuQ1NTUHJvcGVydGllc30+e2NvbnRlbnR9PC9kaXY+Ow0KfQ0KDQpj'
                'b25zdCBMYXN0U2VlblNlY3Rpb24gPSBFcnJvckJvdW5kYXJ5LndyYXAoKHsgdXNlcklkLCBpc1NpZGVCYXIgfTogeyB1c2VySWQ6IHN0cmluZzsgaXNTaWRl'
                'QmFyOiBib29sZWFuOyB9KSA9PiAoDQogICAgPFNlY3Rpb24gaGVhZGluZz0iTGFzdCBTZWVuIiBoZWFkaW5nVmFyaWFudD17aXNTaWRlQmFyID8gInRleHQt'
                'eHMvc2VtaWJvbGQiIDogInRleHQteHMvbWVkaXVtIn0gaGVhZGluZ0NvbG9yPXtpc1NpZGVCYXIgPyAidGV4dC1zdHJvbmciIDogInRleHQtZGVmYXVsdCJ9'
                'Pg0KICAgICAgICA8TGFzdFNlZW5UZXh0IHVzZXJJZD17dXNlcklkfSAvPg0KICAgIDwvU2VjdGlvbj4NCiksIHsgbm9vcDogdHJ1ZSB9KTsNCg0KZXhwb3J0'
                'IGRlZmF1bHQgZGVmaW5lUGx1Z2luKHsNCiAgICBuYW1lOiAiTGFzdFNlZW4iLA0KICAgIGRlc2NyaXB0aW9uOiAiU2hvd3Mgd2hlbiBhIHVzZXIgd2FzIGxh'
                'c3Qgc2Vlbi4gVGV4dCBhbHdheXMgdmlzaWJsZS4iLA0KICAgIGF1dGhvcnM6IFt7IG5hbWU6ICJuaWdodGNvcmQiLCBpZDogMG4gfV0sDQogICAgZW5hYmxl'
                'ZEJ5RGVmYXVsdDogdHJ1ZSwNCiAgICBkZXBlbmRlbmNpZXM6IFsiUHJvZmlsZVNlY3Rpb25zQVBJIl0sDQogICAgc2V0dGluZ3MsDQogICAgcmVuZGVyUHJv'
                'ZmlsZVNlY3Rpb246IHsNCiAgICAgICAgcmVuZGVyOiBMYXN0U2VlblNlY3Rpb24sDQogICAgICAgIHByaW9yaXR5OiAwDQogICAgfSwNCiAgICBmbHV4OiB7'
                'DQogICAgICAgIFBSRVNFTkNFX1VQREFURShldmVudDogYW55KSB7DQogICAgICAgICAgICBpZiAoQXJyYXkuaXNBcnJheShldmVudD8udXBkYXRlcykpIGV2'
                'ZW50LnVwZGF0ZXMuZm9yRWFjaCgodXBkYXRlOiBhbnkpID0+IHJlY29yZFNlZW4odXBkYXRlPy51c2VyPy5pZCA/PyB1cGRhdGU/LnVzZXJJZCA/PyB1cGRh'
                'dGU/LnVzZXJfaWQpKTsNCiAgICAgICAgICAgIGVsc2UgcmVjb3JkU2VlbihldmVudD8udXNlcj8uaWQgPz8gZXZlbnQ/LnVzZXJJZCA/PyBldmVudD8udXNl'
                'cl9pZCk7DQogICAgICAgIH0sDQogICAgICAgIFBSRVNFTkNFX1VQREFURVMoZXZlbnQ6IGFueSkgew0KICAgICAgICAgICAgY29uc3QgdXBkYXRlcyA9IEFy'
                'cmF5LmlzQXJyYXkoZXZlbnQ/LnVwZGF0ZXMpID8gZXZlbnQudXBkYXRlcyA6IEFycmF5LmlzQXJyYXkoZXZlbnQpID8gZXZlbnQgOiBbZXZlbnRdOw0KICAg'
                'ICAgICAgICAgdXBkYXRlcy5mb3JFYWNoKCh1cGRhdGU6IGFueSkgPT4gcmVjb3JkU2Vlbih1cGRhdGU/LnVzZXI/LmlkID8/IHVwZGF0ZT8udXNlcklkID8/'
                'IHVwZGF0ZT8udXNlcl9pZCkpOw0KICAgICAgICB9LA0KICAgICAgICBNRVNTQUdFX0NSRUFURShldmVudDogYW55KSB7IHJlY29yZFNlZW4oZXZlbnQ/Lm1l'
                'c3NhZ2U/LmF1dGhvcj8uaWQgPz8gZXZlbnQ/LmF1dGhvcj8uaWQpOyB9LA0KICAgICAgICBWT0lDRV9TVEFURV9VUERBVEVTKGV2ZW50OiBhbnkpIHsgKGV2'
                'ZW50Py52b2ljZVN0YXRlcyA/PyBbXSkuZm9yRWFjaCgoc3RhdGU6IGFueSkgPT4gcmVjb3JkU2VlbihzdGF0ZT8udXNlcklkID8/IHN0YXRlPy51c2VyX2lk'
                'KSk7IH0sDQogICAgICAgIFRZUElOR19TVEFSVChldmVudDogYW55KSB7IHJlY29yZFNlZW4oZXZlbnQ/LnVzZXJJZCA/PyBldmVudD8udXNlcl9pZCk7IH0s'
                'DQogICAgICAgIE1FU1NBR0VfUkVBQ1RJT05fQUREKGV2ZW50OiBhbnkpIHsgcmVjb3JkU2VlbihldmVudD8udXNlcklkID8/IGV2ZW50Py51c2VyX2lkKTsg'
                'fQ0KICAgIH0sDQogICAgc3RhcnQoKSB7IHZvaWQgZW5zdXJlQ2FjaGVMb2FkZWQoKTsgfSwNCiAgICBzdG9wKCkgew0KICAgICAgICBpZiAoc2F2ZVRpbWVy'
                'KSB7DQogICAgICAgICAgICBjbGVhclRpbWVvdXQoc2F2ZVRpbWVyKTsNCiAgICAgICAgICAgIHNhdmVUaW1lciA9IG51bGw7DQogICAgICAgICAgICB2b2lk'
                'IERhdGFTdG9yZS5zZXQoU1RPUkFHRV9LRVksIGVudHJpZXMpLmNhdGNoKGVycm9yID0+IGxvZ2dlci5lcnJvcigiRmFpbGVkIHRvIGZsdXNoIGFjdGl2aXR5'
                'IHRpbWVzdGFtcHMiLCBlcnJvcikpOw0KICAgICAgICB9DQogICAgICAgIGxpc3RlbmVycy5jbGVhcigpOw0KICAgIH0NCn0pOw0K'
            ) -join '')
        }
    }
    [pscustomobject]@{
        Id = 'streamProof'
        DisplayName = 'StreamProof'
        FolderName = 'streamProof'
        Description = 'Blurs sensitive Discord content while streaming until clicked.'
        DefaultSelected = $true
        LegacyFolders = @('StreamProof')
        Notes = 'Removes click listener, style tag, and reveal classes on stop.'
        Files = [ordered]@{
            'index.tsx' = (@(
                'LyoNCiAqIFZlbmNvcmQsIGEgRGlzY29yZCBjbGllbnQgbW9kDQogKiBDb3B5cmlnaHQgKGMpIDIwMjYgVmVuZGljYXRlZCBhbmQgY29udHJpYnV0b3JzDQog'
                'KiBTUERYLUxpY2Vuc2UtSWRlbnRpZmllcjogR1BMLTMuMC1vci1sYXRlcg0KICoNCiAqIE1vZGlmaWVkIGZvciBNeSBFcXVpY29yZCBTZXR1cCBieSBTcGVj'
                'dGF0b3IxNSwgMjAyNi0wOC0xNS4NCiAqIE9yaWdpbmFsIGNvcHlyaWdodCBhbmQgYXV0aG9yc2hpcCByZW1haW4gd2l0aCB0aGUgcmVzcGVjdGl2ZSB1cHN0'
                'cmVhbSBjb250cmlidXRvcnMuDQogKi8NCg0KaW1wb3J0IHsgQ2hhdEJhckJ1dHRvbiwgQ2hhdEJhckJ1dHRvbkZhY3RvcnkgfSBmcm9tICJAYXBpL0NoYXRC'
                'dXR0b25zIjsNCmltcG9ydCB7IGRlZmluZVBsdWdpblNldHRpbmdzIH0gZnJvbSAiQGFwaS9TZXR0aW5ncyI7DQppbXBvcnQgZGVmaW5lUGx1Z2luLCB7IE9w'
                'dGlvblR5cGUgfSBmcm9tICJAdXRpbHMvdHlwZXMiOw0KaW1wb3J0IHsgZmluZEJ5UHJvcHNMYXp5IH0gZnJvbSAiQHdlYnBhY2siOw0KaW1wb3J0IHsgUmVh'
                'Y3QsIFVzZXJTdG9yZSwgdXNlU3RhdGUsIHVzZVN0YXRlRnJvbVN0b3JlcyB9IGZyb20gIkB3ZWJwYWNrL2NvbW1vbiI7DQpjb25zdCBTdHJlYW1TdG9yZSA9'
                'IGZpbmRCeVByb3BzTGF6eSgiZ2V0QWN0aXZlU3RyZWFtRm9yVXNlciIsICJnZXRBbGxBY3RpdmVTdHJlYW1zIik7DQpjb25zdCBSVENDb25uZWN0aW9uU3Rv'
                'cmUgPSBmaW5kQnlQcm9wc0xhenkoImdldE1lZGlhU2Vzc2lvbklkIik7DQpjb25zdCBTdHJlYW1lck1vZGVTdG9yZSA9IGZpbmRCeVByb3BzTGF6eSgiaGlk'
                'ZVBlcnNvbmFsSW5mb3JtYXRpb24iKTsNCmNvbnN0IHNldHRpbmdzID0gZGVmaW5lUGx1Z2luU2V0dGluZ3MoeyBhdXRvU3RyZWFtUHJvb2Y6IHsgdHlwZTog'
                'T3B0aW9uVHlwZS5CT09MRUFOLCBkZXNjcmlwdGlvbjogIkF1dG8tZW5hYmxlIHdoZW4gc3RyZWFtaW5nIiwgZGVmYXVsdDogZmFsc2UsIG9uQ2hhbmdlKHY6'
                'IGJvb2xlYW4pIHsgaWYgKHYgJiYgaXNTdHJlYW1pbmcoKSkgZW5hYmxlU3RyZWFtUHJvb2YoKTsgfSB9IH0pOw0KbGV0IGNsaWNrSGFuZGxlcjogKChlOiBN'
                'b3VzZUV2ZW50KSA9PiB2b2lkKSB8IG51bGwgPSBudWxsOyBsZXQgc3RyZWFtUHJvb2ZBY3RpdmUgPSBmYWxzZTsNCmNvbnN0IHN0YXRlTGlzdGVuZXJzID0g'
                'bmV3IFNldDwoYWN0aXZlOiBib29sZWFuKSA9PiB2b2lkPigpOw0KZnVuY3Rpb24gbm90aWZ5U3RhdGUoKSB7IHN0YXRlTGlzdGVuZXJzLmZvckVhY2gobGlz'
                'dGVuZXIgPT4gbGlzdGVuZXIoc3RyZWFtUHJvb2ZBY3RpdmUpKTsgfQ0KZnVuY3Rpb24gaXNTdHJlYW1pbmcoKTogYm9vbGVhbiB7IHRyeSB7IGlmIChTdHJl'
                'YW1lck1vZGVTdG9yZT8uaGlkZVBlcnNvbmFsSW5mb3JtYXRpb24pIHJldHVybiB0cnVlOyBjb25zdCB1ID0gVXNlclN0b3JlPy5nZXRDdXJyZW50VXNlcj8u'
                'KCk7IGlmICghdSkgcmV0dXJuIGZhbHNlOyBpZiAoU3RyZWFtU3RvcmU/LmdldEFjdGl2ZVN0cmVhbUZvclVzZXI/Lih1LmlkKSkgcmV0dXJuIHRydWU7IGNv'
                'bnN0IGFsbCA9IFN0cmVhbVN0b3JlPy5nZXRBbGxBY3RpdmVTdHJlYW1zPy4oKTsgaWYgKGFsbD8ubGVuZ3RoID4gMCAmJiBhbGwuZmluZCgoczogYW55KSA9'
                'PiBzLm93bmVySWQgPT09IHUuaWQpKSByZXR1cm4gdHJ1ZTsgaWYgKFJUQ0Nvbm5lY3Rpb25TdG9yZT8uZ2V0TWVkaWFTZXNzaW9uSWQ/LigpICYmIFJUQ0Nv'
                'bm5lY3Rpb25TdG9yZT8uZ2V0U3RhdGU/LigpPy5jb250ZXh0ID09PSAic3RyZWFtIikgcmV0dXJuIHRydWU7IHJldHVybiBmYWxzZTsgfSBjYXRjaCB7IHJl'
                'dHVybiBmYWxzZTsgfSB9DQpmdW5jdGlvbiBoYW5kbGVTdHJlYW1DaGFuZ2UoKSB7IGlmICghc2V0dGluZ3Muc3RvcmUuYXV0b1N0cmVhbVByb29mKSByZXR1'
                'cm47IGlmIChpc1N0cmVhbWluZygpKSBlbmFibGVTdHJlYW1Qcm9vZigpOyBlbHNlIGRpc2FibGVTdHJlYW1Qcm9vZigpOyB9DQpmdW5jdGlvbiBlbmFibGVT'
                'dHJlYW1Qcm9vZigpIHsgY29uc3QgY2hhbmdlZCA9ICFzdHJlYW1Qcm9vZkFjdGl2ZTsgc3RyZWFtUHJvb2ZBY3RpdmUgPSB0cnVlOyBkb2N1bWVudC5ib2R5'
                'LmNsYXNzTGlzdC5hZGQoInN0cmVhbS1wcm9vZi1lbmFibGVkIik7IGlmICghY2xpY2tIYW5kbGVyKSB7IGNsaWNrSGFuZGxlciA9IChlOiBNb3VzZUV2ZW50'
                'KSA9PiB7IGNvbnN0IHQgPSBlLnRhcmdldCBhcyBIVE1MRWxlbWVudCB8IG51bGw7IGlmICghdCkgcmV0dXJuOyBjb25zdCBlbCA9IHQuY2xvc2VzdCgiW2Ns'
                'YXNzKj1cIm1lc3NhZ2VDb250ZW50X1wiXSxbY2xhc3MqPVwibWFya3VwX1wiXSxbY2xhc3MqPVwiaW1hZ2VXcmFwcGVyX1wiXSxbY2xhc3MqPVwiZW1iZWRX'
                'cmFwcGVyX1wiXSxbY2xhc3MqPVwiYXR0YWNobWVudF9cIl0sW2NsYXNzKj1cInN0aWNrZXJBc3NldF9cIl0iKTsgaWYgKGVsICYmICFlbC5jbGFzc0xpc3Qu'
                'Y29udGFpbnMoInN0cmVhbS1wcm9vZi1yZXZlYWxlZCIpKSB7IGVsLmNsYXNzTGlzdC5hZGQoInN0cmVhbS1wcm9vZi1yZXZlYWxlZCIpOyBlLnByZXZlbnRE'
                'ZWZhdWx0KCk7IGUuc3RvcFByb3BhZ2F0aW9uKCk7IH0gfTsgZG9jdW1lbnQuYWRkRXZlbnRMaXN0ZW5lcigiY2xpY2siLCBjbGlja0hhbmRsZXIgYXMgYW55'
                'LCB0cnVlKTsgfSBpZiAoY2hhbmdlZCkgbm90aWZ5U3RhdGUoKTsgfQ0KZnVuY3Rpb24gZGlzYWJsZVN0cmVhbVByb29mKCkgeyBjb25zdCBjaGFuZ2VkID0g'
                'c3RyZWFtUHJvb2ZBY3RpdmU7IHN0cmVhbVByb29mQWN0aXZlID0gZmFsc2U7IGRvY3VtZW50LmJvZHkuY2xhc3NMaXN0LnJlbW92ZSgic3RyZWFtLXByb29m'
                'LWVuYWJsZWQiKTsgaWYgKGNsaWNrSGFuZGxlcikgeyBkb2N1bWVudC5yZW1vdmVFdmVudExpc3RlbmVyKCJjbGljayIsIGNsaWNrSGFuZGxlciBhcyBhbnks'
                'IHRydWUpOyBjbGlja0hhbmRsZXIgPSBudWxsOyB9IGRvY3VtZW50LnF1ZXJ5U2VsZWN0b3JBbGwoIi5zdHJlYW0tcHJvb2YtcmV2ZWFsZWQiKS5mb3JFYWNo'
                'KGVsID0+IGVsLmNsYXNzTGlzdC5yZW1vdmUoInN0cmVhbS1wcm9vZi1yZXZlYWxlZCIpKTsgaWYgKGNoYW5nZWQpIG5vdGlmeVN0YXRlKCk7IH0NCmZ1bmN0'
                'aW9uIEV5ZUljb24oKSB7IHJldHVybiA8c3ZnIGFyaWEtaGlkZGVuPSJ0cnVlIiByb2xlPSJpbWciIHhtbG5zPSJodHRwOi8vd3d3LnczLm9yZy8yMDAwL3N2'
                'ZyIgd2lkdGg9IjIwIiBoZWlnaHQ9IjIwIiBmaWxsPSJub25lIiB2aWV3Qm94PSIwIDAgMjQgMjQiPjxwYXRoIGZpbGw9ImN1cnJlbnRDb2xvciIgZD0iTTEy'
                'IDVDNS42NDggNSAxIDEyIDEgMTJzNC42NDggNyAxMSA3IDExLTcgMTEtNy00LjY0OC03LTExLTdabTAgMTJhNSA1IDAgMSAxIDAtMTAgNSA1IDAgMCAxIDAg'
                'MTBabTAtOGEzIDMgMCAxIDAgMCA2IDMgMyAwIDAgMCAwLTZaIiAvPjwvc3ZnPjsgfQ0KZnVuY3Rpb24gRXllU2xhc2hJY29uKCkgeyByZXR1cm4gPHN2ZyBh'
                'cmlhLWhpZGRlbj0idHJ1ZSIgcm9sZT0iaW1nIiB4bWxucz0iaHR0cDovL3d3dy53My5vcmcvMjAwMC9zdmciIHdpZHRoPSIyMCIgaGVpZ2h0PSIyMCIgZmls'
                'bD0ibm9uZSIgdmlld0JveD0iMCAwIDI0IDI0Ij48cGF0aCBmaWxsPSJjdXJyZW50Q29sb3IiIGQ9Ik0yLjIyIDIuMjJhLjc1Ljc1IDAgMCAxIDEuMDYgMGwx'
                'OC41IDE4LjVhLjc1Ljc1IDAgMSAxLTEuMDYgMS4wNmwtMy41Ni0zLjU2QTExLjE4IDExLjE4IDAgMCAxIDEyIDE5QzUuNjQ4IDE5IDEgMTIgMSAxMnMxLjgx'
                'LTIuNzMgNC42OS00Ljk1TDIuMjIgMy4yOGEuNzUuNzUgMCAwIDEgMC0xLjA2Wk0xMiA1YzEuOTIgMCAzLjcuNTIgNS4yNSAxLjM3bC0xLjUgMS41QTguODcg'
                'OC44NyAwIDAgMCAyMC45MyAxMmE5LjU3IDkuNTcgMCAwIDEtMy4zNyAzLjQ0bDEuNSAxLjVDMjEuNDIgMTUuMiAyMyAxMiAyMyAxMnMtNC42NDgtNy0xMS03'
                'WiIgLz48L3N2Zz47IH0NCmNvbnN0IFN0cmVhbVByb29mQnV0dG9uOiBDaGF0QmFyQnV0dG9uRmFjdG9yeSA9ICh7IGlzTWFpbkNoYXQgfSkgPT4gew0KICAg'
                'IHVzZVN0YXRlRnJvbVN0b3JlcyhbU3RyZWFtZXJNb2RlU3RvcmUsIFN0cmVhbVN0b3JlLCBSVENDb25uZWN0aW9uU3RvcmVdLCAoKSA9PiBpc1N0cmVhbWlu'
                'ZygpKTsNCiAgICBjb25zdCBbYWN0aXZlLCBzZXRBY3RpdmVdID0gdXNlU3RhdGUoc3RyZWFtUHJvb2ZBY3RpdmUpOw0KICAgIFJlYWN0LnVzZUVmZmVjdCgo'
                'KSA9PiB7IHN0YXRlTGlzdGVuZXJzLmFkZChzZXRBY3RpdmUpOyByZXR1cm4gKCkgPT4geyBzdGF0ZUxpc3RlbmVycy5kZWxldGUoc2V0QWN0aXZlKTsgfTsg'
                'fSwgW10pOw0KICAgIGlmICghaXNNYWluQ2hhdCkgcmV0dXJuIG51bGw7DQogICAgZnVuY3Rpb24gdG9nZ2xlKCkgeyBpZiAoc3RyZWFtUHJvb2ZBY3RpdmUp'
                'IGRpc2FibGVTdHJlYW1Qcm9vZigpOyBlbHNlIGVuYWJsZVN0cmVhbVByb29mKCk7IH0NCiAgICByZXR1cm4gPENoYXRCYXJCdXR0b24gdG9vbHRpcD17YWN0'
                'aXZlID8gIlN0cmVhbVByb29mOiBPTiAoY2xpY2sgdG8gZGlzYWJsZSkiIDogIlN0cmVhbVByb29mOiBPRkYgKGNsaWNrIHRvIGVuYWJsZSkifSBvbkNsaWNr'
                'PXt0b2dnbGV9PjxzcGFuIHN0eWxlPXt7IGNvbG9yOiBhY3RpdmUgPyAidmFyKC0tc3RhdHVzLWRhbmdlcikiIDogImN1cnJlbnRDb2xvciIgfX0+e2FjdGl2'
                'ZSA/IDxFeWVTbGFzaEljb24gLz4gOiA8RXllSWNvbiAvPn08L3NwYW4+PC9DaGF0QmFyQnV0dG9uPjsNCn07DQpleHBvcnQgZGVmYXVsdCBkZWZpbmVQbHVn'
                'aW4oew0KICAgIG5hbWU6ICJTdHJlYW1Qcm9vZiIsIGRlc2NyaXB0aW9uOiAiQmx1cnMgRGlzY29yZCBjb250ZW50IHdoaWxlIHN0cmVhbWluZy4gQ2xpY2sg'
                'Ymx1cnJlZCBjb250ZW50IHRvIHJldmVhbC4iLCBhdXRob3JzOiBbeyBuYW1lOiAiVGhlQXJtYWdhbiIsIGlkOiAwbiB9XSwgZGVwZW5kZW5jaWVzOiBbIkNo'
                'YXRJbnB1dEJ1dHRvbkFQSSJdLCBlbmFibGVkQnlEZWZhdWx0OiB0cnVlLCBzZXR0aW5ncywNCiAgICBjaGF0QmFyQnV0dG9uOiB7IGljb246IEV5ZVNsYXNo'
                'SWNvbiwgcmVuZGVyOiBTdHJlYW1Qcm9vZkJ1dHRvbiB9LA0KICAgIGZsdXg6IHsgU1RSRUFNX1NUQVJUKCkgeyBoYW5kbGVTdHJlYW1DaGFuZ2UoKTsgfSwg'
                'U1RSRUFNX1NUT1AoKSB7IGhhbmRsZVN0cmVhbUNoYW5nZSgpOyB9LCBTVFJFQU1fQ1JFQVRFKCkgeyBoYW5kbGVTdHJlYW1DaGFuZ2UoKTsgfSwgU1RSRUFN'
                'X0RFTEVURSgpIHsgaGFuZGxlU3RyZWFtQ2hhbmdlKCk7IH0sIFNUUkVBTUVSX01PREVfVVBEQVRFKCkgeyBoYW5kbGVTdHJlYW1DaGFuZ2UoKTsgfSwgUlRD'
                'X0NPTk5FQ1RJT05fU1RBVEUoKSB7IGhhbmRsZVN0cmVhbUNoYW5nZSgpOyB9IH0sDQogICAgc3RhcnQoKSB7IGRvY3VtZW50LmdldEVsZW1lbnRCeUlkKCJz'
                'dHJlYW0tcHJvb2Ytc3R5bGVzIik/LnJlbW92ZSgpOyBjb25zdCBzID0gZG9jdW1lbnQuY3JlYXRlRWxlbWVudCgic3R5bGUiKTsgcy5pZCA9ICJzdHJlYW0t'
                'cHJvb2Ytc3R5bGVzIjsgcy50ZXh0Q29udGVudCA9ICIuc3RyZWFtLXByb29mLWVuYWJsZWQgW2NsYXNzKj1cIm1lc3NhZ2VDb250ZW50X1wiXSwuc3RyZWFt'
                'LXByb29mLWVuYWJsZWQgW2NsYXNzKj1cIm1hcmt1cF9cIl0sLnN0cmVhbS1wcm9vZi1lbmFibGVkIFtjbGFzcyo9XCJpbWFnZVdyYXBwZXJfXCJdLC5zdHJl'
                'YW0tcHJvb2YtZW5hYmxlZCBbY2xhc3MqPVwiZW1iZWRXcmFwcGVyX1wiXSwuc3RyZWFtLXByb29mLWVuYWJsZWQgW2NsYXNzKj1cImF0dGFjaG1lbnRfXCJd'
                'LC5zdHJlYW0tcHJvb2YtZW5hYmxlZCBbY2xhc3MqPVwic3RpY2tlckFzc2V0X1wiXXtmaWx0ZXI6Ymx1cigxMnB4KTt0cmFuc2l0aW9uOmZpbHRlciAwLjJz'
                'IGVhc2U7Y3Vyc29yOnBvaW50ZXJ9LnN0cmVhbS1wcm9vZi1lbmFibGVkIC5zdHJlYW0tcHJvb2YtcmV2ZWFsZWR7ZmlsdGVyOm5vbmUhaW1wb3J0YW50O2N1'
                'cnNvcjp1bnNldCFpbXBvcnRhbnR9IjsgZG9jdW1lbnQuaGVhZC5hcHBlbmRDaGlsZChzKTsgaWYgKHNldHRpbmdzLnN0b3JlLmF1dG9TdHJlYW1Qcm9vZiAm'
                'JiBpc1N0cmVhbWluZygpKSBlbmFibGVTdHJlYW1Qcm9vZigpOyB9LA0KICAgIHN0b3AoKSB7IGRvY3VtZW50LmdldEVsZW1lbnRCeUlkKCJzdHJlYW0tcHJv'
                'b2Ytc3R5bGVzIik/LnJlbW92ZSgpOyBkaXNhYmxlU3RyZWFtUHJvb2YoKTsgc3RhdGVMaXN0ZW5lcnMuY2xlYXIoKTsgfQ0KfSk7DQo='
            ) -join '')
        }
    }
    [pscustomobject]@{
        Id = 'fakePerm'
        DisplayName = 'FakePerm'
        FolderName = 'fakePerm'
        Description = 'Adds local-only fake moderation menu actions for visual testing.'
        DefaultSelected = $true
        LegacyFolders = @('FakePerm')
        Notes = 'Clears local state and fake timeout timers on disable/stop.'
        Files = [ordered]@{
            'index.tsx' = (@(
                'LyoNCiAqIFZlbmNvcmQsIGEgRGlzY29yZCBjbGllbnQgbW9kDQogKiBDb3B5cmlnaHQgKGMpIDIwMjYgVmVuZGljYXRlZCBhbmQgY29udHJpYnV0b3JzDQog'
                'KiBTUERYLUxpY2Vuc2UtSWRlbnRpZmllcjogR1BMLTMuMC1vci1sYXRlcg0KICoNCiAqIE1vZGlmaWVkIGZvciBNeSBFcXVpY29yZCBTZXR1cCBieSBTcGVj'
                'dGF0b3IxNSwgMjAyNi0wOC0xNS4NCiAqIE9yaWdpbmFsIGNvcHlyaWdodCBhbmQgYXV0aG9yc2hpcCByZW1haW4gd2l0aCB0aGUgcmVzcGVjdGl2ZSB1cHN0'
                'cmVhbSBjb250cmlidXRvcnMuDQogKi8NCg0KaW1wb3J0IHsgYWRkQ29udGV4dE1lbnVQYXRjaCwgTmF2Q29udGV4dE1lbnVQYXRjaENhbGxiYWNrLCByZW1v'
                'dmVDb250ZXh0TWVudVBhdGNoIH0gZnJvbSAiQGFwaS9Db250ZXh0TWVudSI7DQppbXBvcnQgeyBkZWZpbmVQbHVnaW5TZXR0aW5ncyB9IGZyb20gIkBhcGkv'
                'U2V0dGluZ3MiOw0KaW1wb3J0IGRlZmluZVBsdWdpbiwgeyBPcHRpb25UeXBlIH0gZnJvbSAiQHV0aWxzL3R5cGVzIjsNCmltcG9ydCB0eXBlIHsgUmVuZGVy'
                'TW9kYWxQcm9wcyB9IGZyb20gIkB2ZW5jb3JkL2Rpc2NvcmQtdHlwZXMiOw0KaW1wb3J0IHsgRmx1eERpc3BhdGNoZXIsIEd1aWxkTWVtYmVyU3RvcmUsIEd1'
                'aWxkUm9sZVN0b3JlLCBHdWlsZFN0b3JlLCBNZW51LCBNb2RhbCwgb3Blbk1vZGFsLCBSZWFjdCwgU2VsZWN0ZWRHdWlsZFN0b3JlLCBzaG93VG9hc3QgfSBm'
                'cm9tICJAd2VicGFjay9jb21tb24iOw0KDQpjb25zdCBzZXR0aW5ncyA9IGRlZmluZVBsdWdpblNldHRpbmdzKHsNCiAgICBlbmFibGVkOiB7DQogICAgICAg'
                'IHR5cGU6IE9wdGlvblR5cGUuQk9PTEVBTiwNCiAgICAgICAgZGVzY3JpcHRpb246ICJFbmFibGUgZmFrZSBtb2RlcmF0aW9uIG9wdGlvbnMgaW4gcmlnaHQt'
                'Y2xpY2sgbWVudSIsDQogICAgICAgIGRlZmF1bHQ6IGZhbHNlLA0KICAgICAgICBvbkNoYW5nZSh2OiBib29sZWFuKSB7DQogICAgICAgICAgICBpZiAoIXYp'
                'IHsNCiAgICAgICAgICAgICAgICBkb2N1bWVudC5xdWVyeVNlbGVjdG9yQWxsKCJbZGF0YS1mcC1oaWRkZW49J3RydWUnXSIpLmZvckVhY2goZWwgPT4gew0K'
                'ICAgICAgICAgICAgICAgICAgICAoZWwgYXMgSFRNTEVsZW1lbnQpLnN0eWxlLmRpc3BsYXkgPSAiIjsNCiAgICAgICAgICAgICAgICAgICAgKGVsIGFzIEhU'
                'TUxFbGVtZW50KS5yZW1vdmVBdHRyaWJ1dGUoImRhdGEtZnAtaGlkZGVuIik7DQogICAgICAgICAgICAgICAgfSk7DQogICAgICAgICAgICAgICAgY2xlYXJG'
                'YWtlUGVybVN0YXRlKCk7DQogICAgICAgICAgICB9DQogICAgICAgICAgICBzaG93VG9hc3QodiA/ICJGYWtlUGVybSBlbmFibGVkIiA6ICJGYWtlUGVybSBk'
                'aXNhYmxlZCIpOw0KICAgICAgICB9DQogICAgfQ0KfSk7DQoNCmZ1bmN0aW9uIGlzRW5hYmxlZCgpIHsgcmV0dXJuIHNldHRpbmdzLnN0b3JlLmVuYWJsZWQ7'
                'IH0NCmZ1bmN0aW9uIGZwSGlkZShlbDogSFRNTEVsZW1lbnQpIHsgZWwuc3R5bGUuZGlzcGxheSA9ICJub25lIjsgZWwuc2V0QXR0cmlidXRlKCJkYXRhLWZw'
                'LWhpZGRlbiIsICJ0cnVlIik7IH0NCmNvbnN0IG11dGVkVXNlcnMgPSBuZXcgTWFwPHN0cmluZywgYm9vbGVhbj4oKTsgY29uc3QgZGVhZmVuZWRVc2VycyA9'
                'IG5ldyBNYXA8c3RyaW5nLCBib29sZWFuPigpOyBjb25zdCBmYWtlTmlja3MgPSBuZXcgTWFwPHN0cmluZywgc3RyaW5nPigpOw0KY29uc3QgZGlzY29ubmVj'
                'dGVkVXNlcnMgPSBuZXcgU2V0PHN0cmluZz4oKTsgY29uc3Qga2lja2VkVXNlcnMgPSBuZXcgU2V0PHN0cmluZz4oKTsgY29uc3QgYmFubmVkVXNlcnMgPSBu'
                'ZXcgU2V0PHN0cmluZz4oKTsgY29uc3QgZGVsZXRlZE1lc3NhZ2VzID0gbmV3IFNldDxzdHJpbmc+KCk7DQpjb25zdCB0aW1lb3V0VGltZXJzID0gbmV3IFNl'
                'dDxSZXR1cm5UeXBlPHR5cGVvZiBzZXRUaW1lb3V0Pj4oKTsNCmZ1bmN0aW9uIGNsZWFyRmFrZVBlcm1TdGF0ZSgpIHsgbXV0ZWRVc2Vycy5jbGVhcigpOyBk'
                'ZWFmZW5lZFVzZXJzLmNsZWFyKCk7IGZha2VOaWNrcy5jbGVhcigpOyBkaXNjb25uZWN0ZWRVc2Vycy5jbGVhcigpOyBraWNrZWRVc2Vycy5jbGVhcigpOyBi'
                'YW5uZWRVc2Vycy5jbGVhcigpOyBkZWxldGVkTWVzc2FnZXMuY2xlYXIoKTsgdGltZW91dFRpbWVycy5mb3JFYWNoKHRpbWVyID0+IGNsZWFyVGltZW91dCh0'
                'aW1lcikpOyB0aW1lb3V0VGltZXJzLmNsZWFyKCk7IH0NCmZ1bmN0aW9uIGdldEN1cnJlbnRHdWlsZElkKCk6IHN0cmluZyB8IG51bGwgeyB0cnkgeyByZXR1'
                'cm4gU2VsZWN0ZWRHdWlsZFN0b3JlPy5nZXRHdWlsZElkKCkgPz8gbnVsbDsgfSBjYXRjaCB7IHJldHVybiBudWxsOyB9IH0NCmZ1bmN0aW9uIG5vdGlmeU1l'
                'bWJlckxpc3RDaGFuZ2UoKSB7IGlmICghaXNFbmFibGVkKCkpIHJldHVybjsgdHJ5IHsgY29uc3QgZ3VpbGRJZCA9IGdldEN1cnJlbnRHdWlsZElkKCk7IGlm'
                'ICghZ3VpbGRJZCkgcmV0dXJuOyBGbHV4RGlzcGF0Y2hlcj8uZGlzcGF0Y2goeyB0eXBlOiAiR1VJTERfTUVNQkVSX0xJU1RfVVBEQVRFIiwgb3BzOiBbXSwg'
                'aWQ6ICJldmVyeW9uZSIsIGd1aWxkSWQgfSk7IH0gY2F0Y2gge30gfQ0KZnVuY3Rpb24gZ2V0TWVtYmVyKGd1aWxkSWQ6IHN0cmluZyB8IG51bGwsIHVzZXJJ'
                'ZDogc3RyaW5nKSB7IGlmICghZ3VpbGRJZCkgcmV0dXJuIG51bGw7IHRyeSB7IHJldHVybiBHdWlsZE1lbWJlclN0b3JlPy5nZXRNZW1iZXIoZ3VpbGRJZCwg'
                'dXNlcklkKSA/PyBudWxsOyB9IGNhdGNoIHsgcmV0dXJuIG51bGw7IH0gfQ0KZnVuY3Rpb24gZ2V0R3VpbGRSb2xlcyhndWlsZElkOiBzdHJpbmcgfCBudWxs'
                'KTogQXJyYXk8eyBpZDogc3RyaW5nOyBuYW1lOiBzdHJpbmc7IGNvbG9yOiBudW1iZXI7IH0+IHsNCiAgICBpZiAoIWd1aWxkSWQpIHJldHVybiBbXTsNCiAg'
                'ICB0cnkgeyByZXR1cm4gKEd1aWxkUm9sZVN0b3JlIGFzIGFueSk/LmdldFNvcnRlZFJvbGVzPy4oZ3VpbGRJZCk/LmZpbHRlcigocjogYW55KSA9PiByLmlk'
                'ICE9PSBndWlsZElkKS5tYXAoKHI6IGFueSkgPT4gKHsgaWQ6IHIuaWQsIG5hbWU6IHIubmFtZSwgY29sb3I6IHIuY29sb3IgfSkpID8/IFtdOyB9DQogICAg'
                'Y2F0Y2ggeyB0cnkgeyBjb25zdCBnID0gKEd1aWxkU3RvcmUgYXMgYW55KT8uZ2V0R3VpbGQ/LihndWlsZElkKTsgaWYgKCFnPy5yb2xlcykgcmV0dXJuIFtd'
                'OyByZXR1cm4gT2JqZWN0LnZhbHVlcyhnLnJvbGVzIGFzIFJlY29yZDxzdHJpbmcsIGFueT4pLmZpbHRlcigocjogYW55KSA9PiByLmlkICE9PSBndWlsZElk'
                'KS5zb3J0KChhOiBhbnksIGI6IGFueSkgPT4gYi5wb3NpdGlvbiAtIGEucG9zaXRpb24pLm1hcCgocjogYW55KSA9PiAoeyBpZDogci5pZCwgbmFtZTogci5u'
                'YW1lLCBjb2xvcjogci5jb2xvciB9KSk7IH0gY2F0Y2ggeyByZXR1cm4gW107IH0gfQ0KfQ0KZnVuY3Rpb24gZ2V0TWVtYmVyUm9sZUlkcyhndWlsZElkOiBz'
                'dHJpbmcgfCBudWxsLCB1c2VySWQ6IHN0cmluZyk6IHN0cmluZ1tdIHsgaWYgKCFndWlsZElkKSByZXR1cm4gW107IHRyeSB7IHJldHVybiAoR3VpbGRNZW1i'
                'ZXJTdG9yZSBhcyBhbnkpPy5nZXRNZW1iZXI/LihndWlsZElkLCB1c2VySWQpPy5yb2xlcyA/PyBbXTsgfSBjYXRjaCB7IHJldHVybiBnZXRNZW1iZXIoZ3Vp'
                'bGRJZCwgdXNlcklkKT8ucm9sZXMgPz8gW107IH0gfQ0KZnVuY3Rpb24gdG9hc3QobXNnOiBzdHJpbmcpIHsgdHJ5IHsgc2hvd1RvYXN0KG1zZyk7IH0gY2F0'
                'Y2gge30gfQ0KDQpmdW5jdGlvbiBoaWRlTWVzc2FnZUluRE9NKG1lc3NhZ2VJZDogc3RyaW5nKSB7DQogICAgbGV0IG1zZ0VsOiBIVE1MRWxlbWVudCB8IG51'
                'bGwgPSBkb2N1bWVudC5xdWVyeVNlbGVjdG9yKGBbaWQkPSItJHttZXNzYWdlSWR9Il1gKSA/PyBkb2N1bWVudC5xdWVyeVNlbGVjdG9yKGBbZGF0YS1saXN0'
                'LWl0ZW0taWQkPSIke21lc3NhZ2VJZH0iXWApOw0KICAgIGlmICghbXNnRWwpIHsgZm9yIChjb25zdCBsaSBvZiBkb2N1bWVudC5xdWVyeVNlbGVjdG9yQWxs'
                'KCJvbFtkYXRhLWxpc3QtaWQ9J2NoYXQtbWVzc2FnZXMnXSA+IGxpIikpIHsgaWYgKChsaSBhcyBIVE1MRWxlbWVudCkuaWQuaW5jbHVkZXMobWVzc2FnZUlk'
                'KSkgeyBtc2dFbCA9IGxpIGFzIEhUTUxFbGVtZW50OyBicmVhazsgfSB9IH0NCiAgICBpZiAoIW1zZ0VsKSByZXR1cm47IGZwSGlkZShtc2dFbCk7DQp9DQoN'
                'CmZ1bmN0aW9uIFJlbmFtZU1vZGFsKHsgcm9vdFByb3BzLCB1c2VyLCBndWlsZElkIH06IHsgcm9vdFByb3BzOiBSZW5kZXJNb2RhbFByb3BzOyB1c2VyOiBh'
                'bnk7IGd1aWxkSWQ6IHN0cmluZyB8IG51bGw7IH0pIHsNCiAgICBjb25zdCBbbmljaywgc2V0Tmlja10gPSBSZWFjdC51c2VTdGF0ZTxzdHJpbmc+KGZha2VO'
                'aWNrcy5nZXQodXNlci5pZCkgPz8gZ2V0TWVtYmVyKGd1aWxkSWQsIHVzZXIuaWQpPy5uaWNrID8/IHVzZXIudXNlcm5hbWUgPz8gIiIpOw0KICAgIGZ1bmN0'
                'aW9uIGFwcGx5TmljaygpIHsgY29uc3QgdCA9IG5pY2sudHJpbSgpOyBpZiAodCkgZmFrZU5pY2tzLnNldCh1c2VyLmlkLCB0KTsgZWxzZSBmYWtlTmlja3Mu'
                'ZGVsZXRlKHVzZXIuaWQpOyBub3RpZnlNZW1iZXJMaXN0Q2hhbmdlKCk7IHRvYXN0KCJOaWNrbmFtZSBjaGFuZ2VkIik7IHJvb3RQcm9wcy5vbkNsb3NlKCk7'
                'IH0NCiAgICByZXR1cm4gPE1vZGFsIHsuLi5yb290UHJvcHN9IHNpemU9InNtIiB0aXRsZT0iQ2hhbmdlIE5pY2tuYW1lIiBhY3Rpb25zPXtbeyB0ZXh0OiAi'
                'Q2FuY2VsIiwgdmFyaWFudDogInNlY29uZGFyeSIsIG9uQ2xpY2s6IHJvb3RQcm9wcy5vbkNsb3NlIH0sIHsgdGV4dDogIkFwcGx5IiwgdmFyaWFudDogInBy'
                'aW1hcnkiLCBvbkNsaWNrOiBhcHBseU5pY2sgfV19PjxpbnB1dCB2YWx1ZT17bmlja30gb25DaGFuZ2U9e2UgPT4gc2V0TmljayhlLnRhcmdldC52YWx1ZSl9'
                'IGF1dG9Gb2N1cyBtYXhMZW5ndGg9ezMyfSBvbktleURvd249e2UgPT4geyBpZiAoZS5rZXkgPT09ICJFbnRlciIpIGFwcGx5TmljaygpOyB9fSBzdHlsZT17'
                'eyB3aWR0aDogIjEwMCUiLCBiYWNrZ3JvdW5kOiAiIzM4M2E0MCIsIGJvcmRlcjogIjFweCBzb2xpZCByZ2JhKDI1NSwyNTUsMjU1LDAuMTUpIiwgYm9yZGVy'
                'UmFkaXVzOiAiOHB4IiwgcGFkZGluZzogIjEwcHggMTJweCIsIGNvbG9yOiAiI2ZmZiIsIGZvbnRTaXplOiAiMTZweCIsIG91dGxpbmU6ICJub25lIiwgYm94'
                'U2l6aW5nOiAiYm9yZGVyLWJveCIgYXMgYW55IH19IC8+PC9Nb2RhbD47DQp9DQoNCmZ1bmN0aW9uIEtpY2tNb2RhbCh7IHJvb3RQcm9wcywgdXNlciwgZ3Vp'
                'bGRJZCB9OiB7IHJvb3RQcm9wczogUmVuZGVyTW9kYWxQcm9wczsgdXNlcjogYW55OyBndWlsZElkOiBzdHJpbmcgfCBudWxsOyB9KSB7DQogICAgY29uc3Qg'
                'W3JlYXNvbiwgc2V0UmVhc29uXSA9IFJlYWN0LnVzZVN0YXRlKCIiKTsgY29uc3QgdGFnID0gdXNlci51c2VybmFtZSA/PyAiIjsNCiAgICBmdW5jdGlvbiBr'
                'aWNrKCkgeyBraWNrZWRVc2Vycy5hZGQodXNlci5pZCk7IGRpc2Nvbm5lY3RlZFVzZXJzLmFkZCh1c2VyLmlkKTsgbm90aWZ5TWVtYmVyTGlzdENoYW5nZSgp'
                'OyB0b2FzdChgQCR7dGFnfSBraWNrZWQgKGxvY2FsKWApOyByb290UHJvcHMub25DbG9zZSgpOyB9DQogICAgcmV0dXJuIDxNb2RhbCB7Li4ucm9vdFByb3Bz'
                'fSBzaXplPSJzbSIgdGl0bGU9e2BLaWNrICR7dXNlci5nbG9iYWxOYW1lID8/IHVzZXIudXNlcm5hbWV9YH0gYWN0aW9ucz17W3sgdGV4dDogIkNhbmNlbCIs'
                'IHZhcmlhbnQ6ICJzZWNvbmRhcnkiLCBvbkNsaWNrOiByb290UHJvcHMub25DbG9zZSB9LCB7IHRleHQ6ICJLaWNrIiwgdmFyaWFudDogImNyaXRpY2FsLXBy'
                'aW1hcnkiLCBvbkNsaWNrOiBraWNrIH1dfT48dGV4dGFyZWEgdmFsdWU9e3JlYXNvbn0gb25DaGFuZ2U9e2UgPT4gc2V0UmVhc29uKGUudGFyZ2V0LnZhbHVl'
                'KX0gcGxhY2Vob2xkZXI9IlJlYXNvbiIgc3R5bGU9e3sgd2lkdGg6ICIxMDAlIiwgaGVpZ2h0OiAiODBweCIsIGJhY2tncm91bmQ6ICIjMWUxZjIyIiwgYm9y'
                'ZGVyOiAiMXB4IHNvbGlkICMxZTFmMjIiLCBib3JkZXJSYWRpdXM6ICI0cHgiLCBwYWRkaW5nOiAiMTBweCIsIGNvbG9yOiAiI2ZmZiIsIGZvbnRTaXplOiAi'
                'MTRweCIsIHJlc2l6ZTogIm5vbmUiLCBvdXRsaW5lOiAibm9uZSIsIGJveFNpemluZzogImJvcmRlci1ib3giIGFzIGFueSB9fSAvPjwvTW9kYWw+Ow0KfQ0K'
                'DQpmdW5jdGlvbiBCYW5Nb2RhbCh7IHJvb3RQcm9wcywgdXNlciB9OiB7IHJvb3RQcm9wczogUmVuZGVyTW9kYWxQcm9wczsgdXNlcjogYW55OyB9KSB7DQog'
                'ICAgY29uc3QgW3JlYXNvbiwgc2V0UmVhc29uXSA9IFJlYWN0LnVzZVN0YXRlPHN0cmluZyB8IG51bGw+KG51bGwpOw0KICAgIGNvbnN0IFJFQVNPTlMgPSBb'
                'eyBsYWJlbDogIlN1c3BpY2lvdXMvc3BhbSIsIHZhbHVlOiAic3BhbSIgfSwgeyBsYWJlbDogIkNvbXByb21pc2VkIiwgdmFsdWU6ICJjb21wIiB9LCB7IGxh'
                'YmVsOiAiUnVsZSB2aW9sYXRpb24iLCB2YWx1ZTogInJ1bGVzIiB9LCB7IGxhYmVsOiAiT3RoZXIiLCB2YWx1ZTogIm90aGVyIiB9XTsNCiAgICBmdW5jdGlv'
                'biBiYW4oKSB7IGlmICghcmVhc29uKSByZXR1cm4gdG9hc3QoIlNlbGVjdCBhIHJlYXNvbiIpOyBiYW5uZWRVc2Vycy5hZGQodXNlci5pZCk7IGtpY2tlZFVz'
                'ZXJzLmFkZCh1c2VyLmlkKTsgZGlzY29ubmVjdGVkVXNlcnMuYWRkKHVzZXIuaWQpOyBub3RpZnlNZW1iZXJMaXN0Q2hhbmdlKCk7IHRvYXN0KGBAJHt1c2Vy'
                'LnVzZXJuYW1lfSBiYW5uZWQgKGxvY2FsKWApOyByb290UHJvcHMub25DbG9zZSgpOyB9DQogICAgcmV0dXJuIDxNb2RhbCB7Li4ucm9vdFByb3BzfSBzaXpl'
                'PSJzbSIgdGl0bGU9e2BCYW4gQCR7dXNlci51c2VybmFtZX0/YH0gYWN0aW9ucz17W3sgdGV4dDogIkNhbmNlbCIsIHZhcmlhbnQ6ICJzZWNvbmRhcnkiLCBv'
                'bkNsaWNrOiByb290UHJvcHMub25DbG9zZSB9LCB7IHRleHQ6ICJCYW4iLCB2YXJpYW50OiAiY3JpdGljYWwtcHJpbWFyeSIsIG9uQ2xpY2s6IGJhbiB9XX0+'
                'e1JFQVNPTlMubWFwKG9wdCA9PiA8bGFiZWwga2V5PXtvcHQudmFsdWV9IHN0eWxlPXt7IGRpc3BsYXk6ICJmbGV4IiwgYWxpZ25JdGVtczogImNlbnRlciIs'
                'IGdhcDogIjEycHgiLCBjdXJzb3I6ICJwb2ludGVyIiwgZm9udFNpemU6ICIxNnB4IiwgY29sb3I6ICIjZmZmIiwgdXNlclNlbGVjdDogIm5vbmUiIGFzIGFu'
                'eSwgbWFyZ2luQm90dG9tOiAxMiB9fSBvbkNsaWNrPXsoKSA9PiBzZXRSZWFzb24ob3B0LnZhbHVlKX0+PGRpdiBzdHlsZT17eyB3aWR0aDogMjAsIGhlaWdo'
                'dDogMjAsIGJvcmRlclJhZGl1czogIjUwJSIsIGZsZXhTaHJpbms6IDAsIGJvcmRlcjogcmVhc29uID09PSBvcHQudmFsdWUgPyAiNnB4IHNvbGlkICM1ODY1'
                'ZjIiIDogIjJweCBzb2xpZCAjNGU1MDU4IiwgYmFja2dyb3VuZDogcmVhc29uID09PSBvcHQudmFsdWUgPyAiI2ZmZiIgOiAidHJhbnNwYXJlbnQiLCBib3hT'
                'aXppbmc6ICJib3JkZXItYm94IiBhcyBhbnkgfX0gLz57b3B0LmxhYmVsfTwvbGFiZWw+KX08L01vZGFsPjsNCn0NCg0KY29uc3QgVERzID0gW3sgbGFiZWw6'
                'ICI2MHMiLCBzZWNvbmRzOiA2MCB9LCB7IGxhYmVsOiAiNW0iLCBzZWNvbmRzOiAzMDAgfSwgeyBsYWJlbDogIjEwbSIsIHNlY29uZHM6IDYwMCB9LCB7IGxh'
                'YmVsOiAiMWgiLCBzZWNvbmRzOiAzNjAwIH0sIHsgbGFiZWw6ICIxZCIsIHNlY29uZHM6IDg2NDAwIH0sIHsgbGFiZWw6ICIxdyIsIHNlY29uZHM6IDYwNDgw'
                'MCB9XTsNCmZ1bmN0aW9uIFRpbWVvdXRNb2RhbCh7IHJvb3RQcm9wcywgdXNlciB9OiB7IHJvb3RQcm9wczogUmVuZGVyTW9kYWxQcm9wczsgdXNlcjogYW55'
                'OyB9KSB7DQogICAgY29uc3QgW2lkeCwgc2V0SWR4XSA9IFJlYWN0LnVzZVN0YXRlKDApOyBjb25zdCB0YWcgPSB1c2VyLnVzZXJuYW1lID8/ICIiOw0KICAg'
                'IGZ1bmN0aW9uIHRpbWVvdXQoKSB7IGNvbnN0IGQgPSBURHNbaWR4XTsgZGlzY29ubmVjdGVkVXNlcnMuYWRkKHVzZXIuaWQpOyBub3RpZnlNZW1iZXJMaXN0'
                'Q2hhbmdlKCk7IHRvYXN0KGBAJHt0YWd9IHRpbWVkIG91dCBmb3IgJHtkLmxhYmVsfSAobG9jYWwpYCk7IGNvbnN0IHRpbWVyID0gc2V0VGltZW91dCgoKSA9'
                'PiB7IHRpbWVvdXRUaW1lcnMuZGVsZXRlKHRpbWVyKTsgZGlzY29ubmVjdGVkVXNlcnMuZGVsZXRlKHVzZXIuaWQpOyBub3RpZnlNZW1iZXJMaXN0Q2hhbmdl'
                'KCk7IH0sIGQuc2Vjb25kcyAqIDEwMDApOyB0aW1lb3V0VGltZXJzLmFkZCh0aW1lcik7IHJvb3RQcm9wcy5vbkNsb3NlKCk7IH0NCiAgICByZXR1cm4gPE1v'
                'ZGFsIHsuLi5yb290UHJvcHN9IHNpemU9InNtIiB0aXRsZT17YFRpbWVvdXQgJHt1c2VyLmdsb2JhbE5hbWUgPz8gdXNlci51c2VybmFtZX1gfSBhY3Rpb25z'
                'PXtbeyB0ZXh0OiAiQ2FuY2VsIiwgdmFyaWFudDogInNlY29uZGFyeSIsIG9uQ2xpY2s6IHJvb3RQcm9wcy5vbkNsb3NlIH0sIHsgdGV4dDogIlRpbWVvdXQi'
                'LCB2YXJpYW50OiAicHJpbWFyeSIsIG9uQ2xpY2s6IHRpbWVvdXQgfV19PjxkaXYgc3R5bGU9e3sgZGlzcGxheTogImZsZXgiLCBtYXJnaW5Cb3R0b206ICI4'
                'cHgiLCBib3JkZXJSYWRpdXM6ICI0cHgiLCBvdmVyZmxvdzogImhpZGRlbiIsIGJvcmRlcjogIjFweCBzb2xpZCByZ2JhKDI1NSwyNTUsMjU1LDAuMSkiIH19'
                'PntURHMubWFwKChkLCBpKSA9PiA8YnV0dG9uIGtleT17aX0gb25DbGljaz17KCkgPT4gc2V0SWR4KGkpfSBzdHlsZT17eyBmbGV4OiAxLCBiYWNrZ3JvdW5k'
                'OiBpZHggPT09IGkgPyAiIzU4NjVmMiIgOiAiIzJiMmQzMSIsIGNvbG9yOiAiI2ZmZiIsIGJvcmRlcjogIm5vbmUiLCBib3JkZXJSaWdodDogaSA8IFREcy5s'
                'ZW5ndGggLSAxID8gIjFweCBzb2xpZCByZ2JhKDI1NSwyNTUsMjU1LDAuMSkiIDogIm5vbmUiLCBwYWRkaW5nOiAiOHB4IDJweCIsIGN1cnNvcjogInBvaW50'
                'ZXIiIH19PntkLmxhYmVsfTwvYnV0dG9uPil9PC9kaXY+PC9Nb2RhbD47DQp9DQoNCmZ1bmN0aW9uIGZpbmRHcm91cElkeChjaGlsZHJlbjogYW55W10sIGlk'
                'czogc3RyaW5nW10pOiBudW1iZXIgeyBmb3IgKGxldCBpID0gMDsgaSA8IGNoaWxkcmVuLmxlbmd0aDsgaSsrKSB7IGNvbnN0IHN1YiA9IEFycmF5LmlzQXJy'
                'YXkoY2hpbGRyZW5baV0/LnByb3BzPy5jaGlsZHJlbikgPyBjaGlsZHJlbltpXS5wcm9wcy5jaGlsZHJlbiA6IGNoaWxkcmVuW2ldPy5wcm9wcz8uY2hpbGRy'
                'ZW4gPyBbY2hpbGRyZW5baV0ucHJvcHMuY2hpbGRyZW5dIDogW107IGlmIChzdWIuc29tZSgoYzogYW55KSA9PiBjPy5wcm9wcz8uaWQgJiYgaWRzLmluY2x1'
                'ZGVzKGMucHJvcHMuaWQpKSkgcmV0dXJuIGk7IH0gcmV0dXJuIC0xOyB9DQoNCmNvbnN0IG1lc3NhZ2VDb250ZXh0UGF0Y2g6IE5hdkNvbnRleHRNZW51UGF0'
                'Y2hDYWxsYmFjayA9IChjaGlsZHJlbiwgeyBtZXNzYWdlIH06IGFueSkgPT4gew0KICAgIGlmICghY2hpbGRyZW4gfHwgIUFycmF5LmlzQXJyYXkoY2hpbGRy'
                'ZW4pIHx8ICFpc0VuYWJsZWQoKSB8fCAhbWVzc2FnZT8uaWQgfHwgIWdldEN1cnJlbnRHdWlsZElkKCkpIHJldHVybjsNCiAgICB0cnkgeyBjaGlsZHJlbi5z'
                'cGxpY2UoLTEsIDAsICg8TWVudS5NZW51R3JvdXAga2V5PSJmcC1tc2ctZ3JvdXAiPjxNZW51Lk1lbnVJdGVtIGtleT0iZnAtZGVsZXRlLW1zZyIgaWQ9ImZw'
                'LWRlbGV0ZS1tc2ciIGxhYmVsPSJEZWxldGUgZm9yIG1lIChmYWtlKSIgY29sb3I9ImRhbmdlciIgYWN0aW9uPXsoKSA9PiB7IGRlbGV0ZWRNZXNzYWdlcy5h'
                'ZGQobWVzc2FnZS5pZCk7IGhpZGVNZXNzYWdlSW5ET00obWVzc2FnZS5pZCk7IHRvYXN0KCJNZXNzYWdlIGRlbGV0ZWQgKGxvY2FsIG9ubHkpIik7IH19IC8+'
                'PC9NZW51Lk1lbnVHcm91cD4pKTsgfSBjYXRjaCB7fQ0KfTsNCg0KY29uc3QgdXNlckNvbnRleHRQYXRjaDogTmF2Q29udGV4dE1lbnVQYXRjaENhbGxiYWNr'
                'ID0gKGNoaWxkcmVuLCB7IHVzZXIgfTogYW55KSA9PiB7DQogICAgaWYgKCFjaGlsZHJlbiB8fCAhQXJyYXkuaXNBcnJheShjaGlsZHJlbikgfHwgIWlzRW5h'
                'YmxlZCgpIHx8ICF1c2VyKSByZXR1cm47DQogICAgdHJ5IHsNCiAgICAgICAgY29uc3QgZ3VpbGRJZCA9IGdldEN1cnJlbnRHdWlsZElkKCk7IGlmICghZ3Vp'
                'bGRJZCkgcmV0dXJuOw0KICAgICAgICBjb25zdCBhbGxSb2xlcyA9IGdldEd1aWxkUm9sZXMoZ3VpbGRJZCk7IGNvbnN0IG1lbWJlclJvbGVJZHMgPSBnZXRN'
                'ZW1iZXJSb2xlSWRzKGd1aWxkSWQsIHVzZXIuaWQpOyBjb25zdCB7IHVzZXJuYW1lIH0gPSB1c2VyOw0KICAgICAgICBjb25zdCBncm91cEEgPSAoPE1lbnUu'
                'TWVudUdyb3VwIGtleT0iZnAtZ3JvdXAtYSI+DQogICAgICAgICAgICA8TWVudS5NZW51SXRlbSBrZXk9ImZwLXJlbmFtZSIgaWQ9ImZwLXJlbmFtZSIgbGFi'
                'ZWw9IkNoYW5nZSBOaWNrbmFtZSIgYWN0aW9uPXsoKSA9PiBvcGVuTW9kYWwocCA9PiA8UmVuYW1lTW9kYWwgcm9vdFByb3BzPXtwfSB1c2VyPXt1c2VyfSBn'
                'dWlsZElkPXtndWlsZElkfSAvPil9IC8+DQogICAgICAgICAgICA8TWVudS5NZW51SXRlbSBrZXk9ImZwLXJvbGVzIiBpZD0iZnAtcm9sZXMiIGxhYmVsPSJS'
                'b2xlcyI+DQogICAgICAgICAgICAgICAge2FsbFJvbGVzLmxlbmd0aCA9PT0gMCA/IDxNZW51Lk1lbnVJdGVtIGtleT0iZnAtcm9sZXMtZW1wdHkiIGlkPSJm'
                'cC1yb2xlcy1lbXB0eSIgbGFiZWw9Ik5vIHJvbGVzIiBkaXNhYmxlZCAvPiA6DQogICAgICAgICAgICAgICAgICAgIGFsbFJvbGVzLm1hcChyb2xlID0+IHsg'
                'Y29uc3QgaGFzUm9sZSA9IG1lbWJlclJvbGVJZHMuaW5jbHVkZXMocm9sZS5pZCk7IGNvbnN0IGNvbG9yID0gcm9sZS5jb2xvciA/IGAjJHtyb2xlLmNvbG9y'
                'LnRvU3RyaW5nKDE2KS5wYWRTdGFydCg2LCAiMCIpfWAgOiAiIzgwODQ4ZSI7IHJldHVybiA8TWVudS5NZW51SXRlbSBrZXk9e2BmcC1yb2xlLSR7cm9sZS5p'
                'ZH1gfSBpZD17YGZwLXJvbGUtJHtyb2xlLmlkfWB9IGxhYmVsPXtyb2xlLm5hbWV9IGFjdGlvbj17KCkgPT4ge319IHJlbmRlcj17KCkgPT4gPGRpdiBzdHls'
                'ZT17eyBkaXNwbGF5OiAiZmxleCIsIGFsaWduSXRlbXM6ICJjZW50ZXIiLCBwYWRkaW5nOiAiOHB4IDEwcHgiLCBnYXA6IDgsIHdpZHRoOiAiMTAwJSIsIGJv'
                'eFNpemluZzogImJvcmRlci1ib3giLCBjdXJzb3I6ICJwb2ludGVyIiB9fT48ZGl2IHN0eWxlPXt7IHdpZHRoOiAxNCwgaGVpZ2h0OiAxNCwgYm9yZGVyUmFk'
                'aXVzOiAiNTAlIiwgYmFja2dyb3VuZDogY29sb3IsIGZsZXhTaHJpbms6IDAgfX0gLz48c3BhbiBzdHlsZT17eyBmbGV4OiAxLCBjb2xvcjogIiNmZmYiLCBm'
                'b250U2l6ZTogMTQgfX0+e3JvbGUubmFtZX08L3NwYW4+PGRpdiBzdHlsZT17eyB3aWR0aDogMTYsIGhlaWdodDogMTYsIGJvcmRlclJhZGl1czogMywgZmxl'
                'eFNocmluazogMCwgYm9yZGVyOiBoYXNSb2xlID8gIm5vbmUiIDogIjEuNXB4IHNvbGlkICM3Mjc2N2QiLCBiYWNrZ3JvdW5kOiBoYXNSb2xlID8gIiM1ODY1'
                'ZjIiIDogInRyYW5zcGFyZW50IiwgZGlzcGxheTogImZsZXgiLCBhbGlnbkl0ZW1zOiAiY2VudGVyIiwganVzdGlmeUNvbnRlbnQ6ICJjZW50ZXIiIH19Pnto'
                'YXNSb2xlICYmIDxzdmcgd2lkdGg9IjEwIiBoZWlnaHQ9IjgiIHZpZXdCb3g9IjAgMCAxMCA4IiBmaWxsPSJub25lIj48cGF0aCBkPSJNMSA0TDMuNSA2LjVM'
                'OSAxIiBzdHJva2U9IndoaXRlIiBzdHJva2VXaWR0aD0iMS41IiBzdHJva2VMaW5lY2FwPSJyb3VuZCIgc3Ryb2tlTGluZWpvaW49InJvdW5kIiAvPjwvc3Zn'
                'Pn08L2Rpdj48L2Rpdj59IC8+OyB9KX0NCiAgICAgICAgICAgIDwvTWVudS5NZW51SXRlbT4NCiAgICAgICAgICAgIDxNZW51Lk1lbnVDaGVja2JveEl0ZW0g'
                'a2V5PSJmcC1tdXRlIiBpZD0iZnAtbXV0ZSIgbGFiZWw9IlNlcnZlciBNdXRlIiBjb2xvcj0iZGFuZ2VyIiBjaGVja2VkPXttdXRlZFVzZXJzLmdldCh1c2Vy'
                'LmlkKSA9PT0gdHJ1ZX0gYWN0aW9uPXsoKSA9PiB7IG11dGVkVXNlcnMuc2V0KHVzZXIuaWQsICFtdXRlZFVzZXJzLmdldCh1c2VyLmlkKSk7IH19IC8+DQog'
                'ICAgICAgICAgICA8TWVudS5NZW51Q2hlY2tib3hJdGVtIGtleT0iZnAtZGVhZmVuIiBpZD0iZnAtZGVhZmVuIiBsYWJlbD0iU2VydmVyIERlYWZlbiIgY29s'
                'b3I9ImRhbmdlciIgY2hlY2tlZD17ZGVhZmVuZWRVc2Vycy5nZXQodXNlci5pZCkgPT09IHRydWV9IGFjdGlvbj17KCkgPT4geyBkZWFmZW5lZFVzZXJzLnNl'
                'dCh1c2VyLmlkLCAhZGVhZmVuZWRVc2Vycy5nZXQodXNlci5pZCkpOyB9fSAvPg0KICAgICAgICAgICAgPE1lbnUuTWVudUl0ZW0ga2V5PSJmcC1kaXNjb25u'
                'ZWN0IiBpZD0iZnAtZGlzY29ubmVjdCIgbGFiZWw9IkRpc2Nvbm5lY3QiIGNvbG9yPSJkYW5nZXIiIGFjdGlvbj17KCkgPT4geyBkaXNjb25uZWN0ZWRVc2Vy'
                'cy5hZGQodXNlci5pZCk7IG5vdGlmeU1lbWJlckxpc3RDaGFuZ2UoKTsgdG9hc3QoYEAke3VzZXJuYW1lfSBkaXNjb25uZWN0ZWQgKGxvY2FsKWApOyB9fSAv'
                'Pg0KICAgICAgICAgICAgPE1lbnUuTWVudUl0ZW0ga2V5PSJmcC10aW1lb3V0IiBpZD0iZnAtdGltZW91dCIgbGFiZWw9e2BUaW1lb3V0ICR7dXNlcm5hbWV9'
                'YH0gY29sb3I9ImRhbmdlciIgYWN0aW9uPXsoKSA9PiBvcGVuTW9kYWwocCA9PiA8VGltZW91dE1vZGFsIHJvb3RQcm9wcz17cH0gdXNlcj17dXNlcn0gLz4p'
                'fSAvPg0KICAgICAgICAgICAgPE1lbnUuTWVudUl0ZW0ga2V5PSJmcC1raWNrIiBpZD0iZnAta2ljayIgbGFiZWw9e2BLaWNrICR7dXNlcm5hbWV9YH0gY29s'
                'b3I9ImRhbmdlciIgYWN0aW9uPXsoKSA9PiBvcGVuTW9kYWwocCA9PiA8S2lja01vZGFsIHJvb3RQcm9wcz17cH0gdXNlcj17dXNlcn0gZ3VpbGRJZD17Z3Vp'
                'bGRJZH0gLz4pfSAvPg0KICAgICAgICAgICAgPE1lbnUuTWVudUl0ZW0ga2V5PSJmcC1iYW4iIGlkPSJmcC1iYW4iIGxhYmVsPXtgQmFuICR7dXNlcm5hbWV9'
                'YH0gY29sb3I9ImRhbmdlciIgYWN0aW9uPXsoKSA9PiBvcGVuTW9kYWwocCA9PiA8QmFuTW9kYWwgcm9vdFByb3BzPXtwfSB1c2VyPXt1c2VyfSAvPil9IC8+'
                'DQogICAgICAgIDwvTWVudS5NZW51R3JvdXA+KTsNCiAgICAgICAgY29uc3QgaWR4ID0gZmluZEdyb3VwSWR4KGNoaWxkcmVuLCBbImJsb2NrIiwgImlnbm9y'
                'ZSJdKTsNCiAgICAgICAgaWYgKGlkeCA+PSAwKSBjaGlsZHJlbi5zcGxpY2UoaWR4ICsgMSwgMCwgZ3JvdXBBKTsgZWxzZSBjaGlsZHJlbi5zcGxpY2UoLTEs'
                'IDAsIGdyb3VwQSk7DQogICAgfSBjYXRjaCAoZSkgeyBjb25zb2xlLmVycm9yKCJbRmFrZVBlcm1dIiwgZSk7IH0NCn07DQoNCmV4cG9ydCBkZWZhdWx0IGRl'
                'ZmluZVBsdWdpbih7DQogICAgbmFtZTogIkZha2VQZXJtIiwgZW5hYmxlZEJ5RGVmYXVsdDogZmFsc2UsIHNldHRpbmdzLA0KICAgIGRlc2NyaXB0aW9uOiAi'
                'VmlzdWFsbHkgc2ltdWxhdGVzIG1vZGVyYXRpb24gb3B0aW9ucyBpbiByaWdodC1jbGljayBtZW51cy4gTm8gcmVhbCBhY3Rpb25zLiBFbmFibGUgaW4gcGx1'
                'Z2luIHNldHRpbmdzLiIsDQogICAgYXV0aG9yczogW3sgbmFtZTogIk5pZ2h0Y29yZCIsIGlkOiAwbiB9XSwgZGVwZW5kZW5jaWVzOiBbIkNvbnRleHRNZW51'
                'QVBJIl0sDQogICAgcGF0Y2hlczogWw0KICAgICAgICB7IGZpbmQ6ICJzaG93Q29tbXVuaWNhdGlvbkRpc2FibGVkU3R5bGVzIiwgcHJlZGljYXRlOiAoKSA9'
                'PiBpc0VuYWJsZWQoKSwgcmVwbGFjZW1lbnQ6IHsgbWF0Y2g6IC8mJlxpXC5caVwuY2FuTWFuYWdlVXNlclwoXGlcLlxpXC5NT0RFUkFURV9NRU1CRVJTLFxp'
                'XC5hdXRob3IsXGlcKS8sIHJlcGxhY2U6ICIiIH0gfSwNCiAgICAgICAgeyBmaW5kOiAiSU5WSVRFU19ESVNBQkxFRCl8fCIsIHByZWRpY2F0ZTogKCkgPT4g'
                'aXNFbmFibGVkKCksIHJlcGxhY2VtZW50OiB7IG1hdGNoOiAvXGlcLlxpXC5jYW5cKFxpXC5caS5NQU5BR0VfR1VJTEQsXGlcKS8sIHJlcGxhY2U6ICJ0cnVl'
                'IiB9IH0sDQogICAgICAgIHsgZmluZDogLyxjaGVja0VsZXZhdGVkOiExfVwpLFxpXC5caVwpfSg/PD1nZXRDdXJyZW50VXNlclwoXCk7cmV0dXJuLis/KS8s'
                'IHByZWRpY2F0ZTogKCkgPT4gaXNFbmFibGVkKCksIHJlcGxhY2VtZW50OiB7IG1hdGNoOiAvcmV0dXJuIFxpXC5caVwoXGlcLlxpXChce3VzZXI6XGksY29u'
                'dGV4dDpcaSxjaGVja0VsZXZhdGVkOiExXH1cKSxcaVwuXGlcKS8sIHJlcGxhY2U6ICJyZXR1cm4gdHJ1ZSIgfSB9LA0KICAgICAgICB7IGZpbmQ6ICdhY3Rp'
                'b246IlBSRVNTX01PRF9WSUVXIixpY29uOicsIHByZWRpY2F0ZTogKCkgPT4gaXNFbmFibGVkKCksIHJlcGxhY2VtZW50OiB7IG1hdGNoOiAvXGkoPz1cP251'
                'bGwpLywgcmVwbGFjZTogImZhbHNlIiB9IH0NCiAgICBdLA0KICAgIHN0YXJ0KCkgeyBhZGRDb250ZXh0TWVudVBhdGNoKCJtZXNzYWdlIiwgbWVzc2FnZUNv'
                'bnRleHRQYXRjaCk7IGFkZENvbnRleHRNZW51UGF0Y2goInVzZXItY29udGV4dCIsIHVzZXJDb250ZXh0UGF0Y2gpOyBhZGRDb250ZXh0TWVudVBhdGNoKCJn'
                'dWlsZC1jaGFubmVsLXVzZXItY29udGV4dCIsIHVzZXJDb250ZXh0UGF0Y2gpOyB9LA0KICAgIHN0b3AoKSB7DQogICAgICAgIHJlbW92ZUNvbnRleHRNZW51'
                'UGF0Y2goIm1lc3NhZ2UiLCBtZXNzYWdlQ29udGV4dFBhdGNoKTsgcmVtb3ZlQ29udGV4dE1lbnVQYXRjaCgidXNlci1jb250ZXh0IiwgdXNlckNvbnRleHRQ'
                'YXRjaCk7IHJlbW92ZUNvbnRleHRNZW51UGF0Y2goImd1aWxkLWNoYW5uZWwtdXNlci1jb250ZXh0IiwgdXNlckNvbnRleHRQYXRjaCk7DQogICAgICAgIGRv'
                'Y3VtZW50LnF1ZXJ5U2VsZWN0b3JBbGwoIltkYXRhLWZwLWhpZGRlbj0ndHJ1ZSddIikuZm9yRWFjaChlbCA9PiB7IChlbCBhcyBIVE1MRWxlbWVudCkuc3R5'
                'bGUuZGlzcGxheSA9ICIiOyAoZWwgYXMgSFRNTEVsZW1lbnQpLnJlbW92ZUF0dHJpYnV0ZSgiZGF0YS1mcC1oaWRkZW4iKTsgfSk7DQogICAgICAgIGNsZWFy'
                'RmFrZVBlcm1TdGF0ZSgpOw0KICAgIH0NCn0pOw0K'
            ) -join '')
        }
    }
    [pscustomobject]@{
        Id = 'fakeDM'
        DisplayName = 'FakeDM'
        FolderName = 'fakeDM'
        Description = 'Injects local-only fake DM messages and calls through a chat bar panel.'
        DefaultSelected = $true
        LegacyFolders = @('FakeDM')
        Notes = 'Caps persisted entries and clears restore timers on stop.'
        Files = [ordered]@{
            'index.tsx' = (@(
                'LyoNCiAqIFZlbmNvcmQsIGEgRGlzY29yZCBjbGllbnQgbW9kDQogKiBDb3B5cmlnaHQgKGMpIDIwMjYgVmVuZGljYXRlZCBhbmQgY29udHJpYnV0b3JzDQog'
                'KiBTUERYLUxpY2Vuc2UtSWRlbnRpZmllcjogR1BMLTMuMC1vci1sYXRlcg0KICoNCiAqIE1vZGlmaWVkIGZvciBNeSBFcXVpY29yZCBTZXR1cCBieSBTcGVj'
                'dGF0b3IxNSwgMjAyNi0wOC0xNS4NCiAqIE9yaWdpbmFsIGNvcHlyaWdodCBhbmQgYXV0aG9yc2hpcCByZW1haW4gd2l0aCB0aGUgcmVzcGVjdGl2ZSB1cHN0'
                'cmVhbSBjb250cmlidXRvcnMuDQogKi8NCg0KaW1wb3J0ICIuL3N0eWxlcy5jc3MiOw0KDQppbXBvcnQgeyBDaGF0QmFyQnV0dG9uLCBDaGF0QmFyQnV0dG9u'
                'RmFjdG9yeSB9IGZyb20gIkBhcGkvQ2hhdEJ1dHRvbnMiOw0KaW1wb3J0ICogYXMgRGF0YVN0b3JlIGZyb20gIkBhcGkvRGF0YVN0b3JlIjsNCmltcG9ydCB7'
                'IExvZ2dlciB9IGZyb20gIkB1dGlscy9Mb2dnZXIiOw0KaW1wb3J0IGRlZmluZVBsdWdpbiBmcm9tICJAdXRpbHMvdHlwZXMiOw0KaW1wb3J0IHsgQ2hhbm5l'
                'bFN0b3JlLCBGbHV4RGlzcGF0Y2hlciwgSWNvblV0aWxzLCBSZWFjdCwgUmVhY3RET00sIFNlbGVjdGVkQ2hhbm5lbFN0b3JlLCBVc2VyU3RvcmUgfSBmcm9t'
                'ICJAd2VicGFjay9jb21tb24iOw0KDQpsZXQgX2lkQ291bnRlciA9IDA7DQpmdW5jdGlvbiB1bmlxdWVTbm93Zmxha2UoZGF0ZTogRGF0ZSk6IHN0cmluZyB7'
                'IGNvbnN0IG9mZnNldCA9IF9pZENvdW50ZXIrKyAlIDQwOTY7IGNvbnN0IG1zID0gTWF0aC5tYXgoMCwgZGF0ZS5nZXRUaW1lKCkgLSAxNDIwMDcwNDAwMDAw'
                'KTsgcmV0dXJuICgoQmlnSW50KG1zKSA8PCAyMm4pIHwgQmlnSW50KG9mZnNldCkpLnRvU3RyaW5nKCk7IH0NCmZ1bmN0aW9uIHJhbmRvbVNlY29uZHMoZGF0'
                'ZTogRGF0ZSk6IERhdGUgeyByZXR1cm4gbmV3IERhdGUoZGF0ZS5nZXRUaW1lKCkgKyAoMSArIE1hdGguZmxvb3IoTWF0aC5yYW5kb20oKSAqIDU5KSkgKiAx'
                'MDAwKTsgfQ0KDQpjb25zdCBTVE9SQUdFX0tFWSA9ICJuaWdodGNvcmRfZmFrZWRtX2Zha2VzIjsNCmNvbnN0IE1BWF9QRVJTSVNURUQgPSAyNTA7DQpjb25z'
                'dCBsb2dnZXIgPSBuZXcgTG9nZ2VyKCJGYWtlRE0iKTsNCnR5cGUgUGVyc2lzdGVkRmFrZSA9IHsgdHlwZTogIm1lc3NhZ2UiOyBjaGFubmVsSWQ6IHN0cmlu'
                'ZzsgYXV0aG9ySWQ6IHN0cmluZzsgY29udGVudDogc3RyaW5nOyB0aW1lc3RhbXA6IHN0cmluZzsgc25vd2ZsYWtlSWQ6IHN0cmluZzsgfSB8IHsgdHlwZTog'
                'ImNhbGwiOyBjaGFubmVsSWQ6IHN0cmluZzsgY2FsbGVySWQ6IHN0cmluZzsgb3RoZXJJZDogc3RyaW5nOyBtaXNzZWQ6IGJvb2xlYW47IGR1cmF0aW9uU2Vj'
                'OiBudW1iZXI7IHRpbWVzdGFtcDogc3RyaW5nOyBlbmRlZFRpbWVzdGFtcDogc3RyaW5nIHwgbnVsbDsgc25vd2ZsYWtlSWQ6IHN0cmluZzsgfTsNCmxldCBw'
                'ZXJzaXN0ZWRGYWtlczogUGVyc2lzdGVkRmFrZVtdID0gW107DQpsZXQgcGVyc2lzdGVuY2VMb2FkZWQgPSBmYWxzZTsNCmxldCBwZXJzaXN0ZW5jZVByb21p'
                'c2U6IFByb21pc2U8dm9pZD4gfCBudWxsID0gbnVsbDsNCmFzeW5jIGZ1bmN0aW9uIGxvYWRQZXJzaXN0ZWQoKSB7DQogICAgaWYgKHBlcnNpc3RlbmNlTG9h'
                'ZGVkKSByZXR1cm47DQogICAgaWYgKHBlcnNpc3RlbmNlUHJvbWlzZSkgcmV0dXJuIHBlcnNpc3RlbmNlUHJvbWlzZTsNCiAgICBwZXJzaXN0ZW5jZVByb21p'
                'c2UgPSAoYXN5bmMgKCkgPT4gew0KICAgICAgICB0cnkgew0KICAgICAgICAgICAgbGV0IHN0b3JlZCA9IGF3YWl0IERhdGFTdG9yZS5nZXQ8UGVyc2lzdGVk'
                'RmFrZVtdPihTVE9SQUdFX0tFWSk7DQogICAgICAgICAgICBpZiAoIUFycmF5LmlzQXJyYXkoc3RvcmVkKSkgew0KICAgICAgICAgICAgICAgIGNvbnN0IGxl'
                'Z2FjeVJhdyA9IGxvY2FsU3RvcmFnZS5nZXRJdGVtKFNUT1JBR0VfS0VZKTsNCiAgICAgICAgICAgICAgICBjb25zdCBsZWdhY3kgPSBsZWdhY3lSYXcgPyBK'
                'U09OLnBhcnNlKGxlZ2FjeVJhdykgOiBbXTsNCiAgICAgICAgICAgICAgICBzdG9yZWQgPSBBcnJheS5pc0FycmF5KGxlZ2FjeSkgPyBsZWdhY3kgOiBbXTsN'
                'CiAgICAgICAgICAgICAgICBhd2FpdCBEYXRhU3RvcmUuc2V0KFNUT1JBR0VfS0VZLCBzdG9yZWQuc2xpY2UoLU1BWF9QRVJTSVNURUQpKTsNCiAgICAgICAg'
                'ICAgICAgICBsb2NhbFN0b3JhZ2UucmVtb3ZlSXRlbShTVE9SQUdFX0tFWSk7DQogICAgICAgICAgICB9DQogICAgICAgICAgICBwZXJzaXN0ZWRGYWtlcyA9'
                'IHN0b3JlZC5zbGljZSgtTUFYX1BFUlNJU1RFRCk7DQogICAgICAgIH0gY2F0Y2ggKGVycm9yKSB7DQogICAgICAgICAgICBsb2dnZXIuZXJyb3IoIkZhaWxl'
                'ZCB0byBsb2FkIHBlcnNpc3RlZCBsb2NhbCBlbnRyaWVzIiwgZXJyb3IpOw0KICAgICAgICAgICAgcGVyc2lzdGVkRmFrZXMgPSBbXTsNCiAgICAgICAgfSBm'
                'aW5hbGx5IHsNCiAgICAgICAgICAgIHBlcnNpc3RlbmNlTG9hZGVkID0gdHJ1ZTsNCiAgICAgICAgICAgIHBlcnNpc3RlbmNlUHJvbWlzZSA9IG51bGw7DQog'
                'ICAgICAgIH0NCiAgICB9KSgpOw0KICAgIHJldHVybiBwZXJzaXN0ZW5jZVByb21pc2U7DQp9DQpmdW5jdGlvbiBzYXZlUGVyc2lzdGVkKGZha2VzOiBQZXJz'
                'aXN0ZWRGYWtlW10pIHsNCiAgICBwZXJzaXN0ZWRGYWtlcyA9IGZha2VzLnNsaWNlKC1NQVhfUEVSU0lTVEVEKTsNCiAgICB2b2lkIERhdGFTdG9yZS5zZXQo'
                'U1RPUkFHRV9LRVksIHBlcnNpc3RlZEZha2VzKS5jYXRjaChlcnJvciA9PiBsb2dnZXIuZXJyb3IoIkZhaWxlZCB0byBzYXZlIGxvY2FsIGVudHJpZXMiLCBl'
                'cnJvcikpOw0KfQ0KDQpjb25zdCBmYWtlSWRzID0gbmV3IE1hcDxzdHJpbmcsIFNldDxzdHJpbmc+PigpOw0KZnVuY3Rpb24gcmVnaXN0ZXJGYWtlKGNoYW5u'
                'ZWxJZDogc3RyaW5nLCBpZDogc3RyaW5nKSB7IGlmICghZmFrZUlkcy5oYXMoY2hhbm5lbElkKSkgZmFrZUlkcy5zZXQoY2hhbm5lbElkLCBuZXcgU2V0KCkp'
                'OyBmYWtlSWRzLmdldChjaGFubmVsSWQpIS5hZGQoaWQpOyB9DQpmdW5jdGlvbiBjbGVhckZha2VzKGNoYW5uZWxJZDogc3RyaW5nKTogbnVtYmVyIHsgY29u'
                'c3QgaWRzID0gZmFrZUlkcy5nZXQoY2hhbm5lbElkKTsgaWYgKCFpZHM/LnNpemUpIHJldHVybiAwOyBsZXQgbiA9IDA7IGZvciAoY29uc3QgaWQgb2YgaWRz'
                'KSB7IEZsdXhEaXNwYXRjaGVyLmRpc3BhdGNoKHsgdHlwZTogIk1FU1NBR0VfREVMRVRFIiwgY2hhbm5lbElkLCBpZCwgbWxEZWxldGVkOiB0cnVlIH0pOyBu'
                'Kys7IH0gc2F2ZVBlcnNpc3RlZChwZXJzaXN0ZWRGYWtlcy5maWx0ZXIoZiA9PiAhKGYuY2hhbm5lbElkID09PSBjaGFubmVsSWQgJiYgaWRzLmhhcyhmLnNu'
                'b3dmbGFrZUlkKSkpKTsgaWRzLmNsZWFyKCk7IHJldHVybiBuOyB9DQoNCmZ1bmN0aW9uIGF2YXRhclVybCh1c2VyOiBhbnkpOiBzdHJpbmcgeyBpZiAoIXVz'
                'ZXIpIHJldHVybiAiIjsgcmV0dXJuIHVzZXIuYXZhdGFyID8gSWNvblV0aWxzLmdldFVzZXJBdmF0YXJVUkwodXNlciwgZmFsc2UsIDMyKSA6IEljb25VdGls'
                'cy5nZXREZWZhdWx0QXZhdGFyVVJMKHVzZXIuaWQpOyB9DQpmdW5jdGlvbiBnZXRDdXJyZW50RE1DaGFubmVsKCk6IGFueSB8IG51bGwgeyB0cnkgeyBjb25z'
                'dCBjaElkID0gU2VsZWN0ZWRDaGFubmVsU3RvcmUuZ2V0Q2hhbm5lbElkKCk7IGlmICghY2hJZCkgcmV0dXJuIG51bGw7IGNvbnN0IGNoID0gQ2hhbm5lbFN0'
                'b3JlLmdldENoYW5uZWwoY2hJZCk7IGlmICghY2ggfHwgKGNoLnR5cGUgIT09IDEgJiYgY2gudHlwZSAhPT0gMykpIHJldHVybiBudWxsOyByZXR1cm4gY2g7'
                'IH0gY2F0Y2ggeyByZXR1cm4gbnVsbDsgfSB9DQpmdW5jdGlvbiBnZXRPdGhlclVzZXIoKTogYW55IHwgbnVsbCB7IHRyeSB7IGNvbnN0IGNoID0gZ2V0Q3Vy'
                'cmVudERNQ2hhbm5lbCgpOyBpZiAoIWNoIHx8IGNoLnR5cGUgIT09IDEpIHJldHVybiBudWxsOyBjb25zdCBtZSA9IFVzZXJTdG9yZS5nZXRDdXJyZW50VXNl'
                'cigpOyBjb25zdCBvdGhlcklkID0gY2gucmVjaXBpZW50cz8uZmluZCgoaWQ6IHN0cmluZykgPT4gaWQgIT09IG1lPy5pZCk7IHJldHVybiBvdGhlcklkID8g'
                'KFVzZXJTdG9yZS5nZXRVc2VyKG90aGVySWQpID8/IG51bGwpIDogbnVsbDsgfSBjYXRjaCB7IHJldHVybiBudWxsOyB9IH0NCmZ1bmN0aW9uIGdldENoYW5u'
                'ZWxNZW1iZXJzKCk6IGFueVtdIHsgdHJ5IHsgY29uc3QgY2ggPSBnZXRDdXJyZW50RE1DaGFubmVsKCk7IGlmICghY2gpIHJldHVybiBbXTsgY29uc3QgbWUg'
                'PSBVc2VyU3RvcmUuZ2V0Q3VycmVudFVzZXIoKTsgY29uc3QgaWRzOiBzdHJpbmdbXSA9IGNoLnJlY2lwaWVudHMgPz8gY2gucmF3UmVjaXBpZW50cz8ubWFw'
                'KChyOiBhbnkpID0+IHIuaWQpID8/IFtdOyBjb25zdCBtZW1iZXJzOiBhbnlbXSA9IFtdOyBpZiAobWUpIG1lbWJlcnMucHVzaChtZSk7IGZvciAoY29uc3Qg'
                'aWQgb2YgaWRzKSB7IGlmIChpZCA9PT0gbWU/LmlkKSBjb250aW51ZTsgY29uc3QgdSA9IFVzZXJTdG9yZS5nZXRVc2VyKGlkKTsgaWYgKHUpIG1lbWJlcnMu'
                'cHVzaCh1KTsgfSByZXR1cm4gbWVtYmVyczsgfSBjYXRjaCB7IHJldHVybiBbXTsgfSB9DQpmdW5jdGlvbiBidWlsZEF1dGhvcih1c2VyOiBhbnkpIHsgcmV0'
                'dXJuIHsgaWQ6IHVzZXIuaWQsIHVzZXJuYW1lOiB1c2VyLnVzZXJuYW1lLCBkaXNjcmltaW5hdG9yOiB1c2VyLmRpc2NyaW1pbmF0b3IgPz8gIjAiLCBhdmF0'
                'YXI6IHVzZXIuYXZhdGFyID8/IG51bGwsIHB1YmxpY19mbGFnczogdXNlci5wdWJsaWNGbGFncyA/PyAwLCBmbGFnczogdXNlci5mbGFncyA/PyAwLCBiYW5u'
                'ZXI6IHVzZXIuYmFubmVyID8/IG51bGwsIGFjY2VudF9jb2xvcjogbnVsbCwgZ2xvYmFsX25hbWU6IHVzZXIuZ2xvYmFsTmFtZSA/PyB1c2VyLnVzZXJuYW1l'
                'LCBhdmF0YXJfZGVjb3JhdGlvbl9kYXRhOiBudWxsLCBiYW5uZXJfY29sb3I6IG51bGwgfTsgfQ0KDQpmdW5jdGlvbiBpbmplY3QoY2hhbm5lbElkOiBzdHJp'
                'bmcsIGF1dGhvcjogYW55LCBjb250ZW50OiBzdHJpbmcsIGRhdGU6IERhdGUsIHBlcnNpc3RlZElkPzogc3RyaW5nKSB7DQogICAgY29uc3QgYWN0dWFsRGF0'
                'ZSA9IHBlcnNpc3RlZElkID8gZGF0ZSA6IHJhbmRvbVNlY29uZHMoZGF0ZSk7IGNvbnN0IGlkID0gcGVyc2lzdGVkSWQgPz8gdW5pcXVlU25vd2ZsYWtlKGFj'
                'dHVhbERhdGUpOw0KICAgIEZsdXhEaXNwYXRjaGVyLmRpc3BhdGNoKHsgdHlwZTogIk1FU1NBR0VfQ1JFQVRFIiwgY2hhbm5lbElkLCBtZXNzYWdlOiB7IGF0'
                'dGFjaG1lbnRzOiBbXSwgY29tcG9uZW50czogW10sIGVtYmVkczogW10sIG1lbnRpb25fcm9sZXM6IFtdLCBtZW50aW9uczogW10sIGF1dGhvcjogYnVpbGRB'
                'dXRob3IoYXV0aG9yKSwgY2hhbm5lbF9pZDogY2hhbm5lbElkLCBjb250ZW50LCBlZGl0ZWRfdGltZXN0YW1wOiBudWxsLCBmbGFnczogMCwgaWQsIG1lbnRp'
                'b25fZXZlcnlvbmU6IGZhbHNlLCBub25jZTogaWQsIHBpbm5lZDogZmFsc2UsIHRpbWVzdGFtcDogYWN0dWFsRGF0ZS50b0lTT1N0cmluZygpLCB0dHM6IGZh'
                'bHNlLCB0eXBlOiAwIH0sIG9wdGltaXN0aWM6IGZhbHNlLCBpc1B1c2hOb3RpZmljYXRpb246IGZhbHNlIH0pOw0KICAgIHJlZ2lzdGVyRmFrZShjaGFubmVs'
                'SWQsIGlkKTsNCiAgICBpZiAoIXBlcnNpc3RlZElkKSBzYXZlUGVyc2lzdGVkKFsuLi5wZXJzaXN0ZWRGYWtlcywgeyB0eXBlOiAibWVzc2FnZSIsIGNoYW5u'
                'ZWxJZCwgYXV0aG9ySWQ6IGF1dGhvci5pZCwgY29udGVudCwgdGltZXN0YW1wOiBhY3R1YWxEYXRlLnRvSVNPU3RyaW5nKCksIHNub3dmbGFrZUlkOiBpZCB9'
                'XSk7DQp9DQoNCmZ1bmN0aW9uIGluamVjdENhbGwoY2hhbm5lbElkOiBzdHJpbmcsIGNhbGxlcjogYW55LCBvdGhlcjogYW55LCBtaXNzZWQ6IGJvb2xlYW4s'
                'IGR1cmF0aW9uU2VjOiBudW1iZXIsIGRhdGU6IERhdGUsIHBlcnNpc3RlZElkPzogc3RyaW5nLCBwZXJzaXN0ZWRFbmRlZFRzPzogc3RyaW5nIHwgbnVsbCkg'
                'ew0KICAgIGNvbnN0IGFjdHVhbERhdGUgPSBwZXJzaXN0ZWRJZCA/IGRhdGUgOiByYW5kb21TZWNvbmRzKGRhdGUpOyBjb25zdCBpZCA9IHBlcnNpc3RlZElk'
                'ID8/IHVuaXF1ZVNub3dmbGFrZShhY3R1YWxEYXRlKTsNCiAgICBjb25zdCBlbmRlZERhdGUgPSBtaXNzZWQgPyBhY3R1YWxEYXRlIDogKHBlcnNpc3RlZEVu'
                'ZGVkVHMgPyBuZXcgRGF0ZShwZXJzaXN0ZWRFbmRlZFRzKSA6IG5ldyBEYXRlKGFjdHVhbERhdGUuZ2V0VGltZSgpICsgZHVyYXRpb25TZWMgKiAxMDAwKSk7'
                'DQogICAgRmx1eERpc3BhdGNoZXIuZGlzcGF0Y2goeyB0eXBlOiAiTUVTU0FHRV9DUkVBVEUiLCBjaGFubmVsSWQsIG1lc3NhZ2U6IHsgYXR0YWNobWVudHM6'
                'IFtdLCBjb21wb25lbnRzOiBbXSwgZW1iZWRzOiBbXSwgbWVudGlvbl9yb2xlczogW10sIG1lbnRpb25zOiBbXSwgYXV0aG9yOiBidWlsZEF1dGhvcihjYWxs'
                'ZXIpLCBjaGFubmVsX2lkOiBjaGFubmVsSWQsIGNvbnRlbnQ6ICIiLCBlZGl0ZWRfdGltZXN0YW1wOiBudWxsLCBmbGFnczogMCwgaWQsIG1lbnRpb25fZXZl'
                'cnlvbmU6IGZhbHNlLCBub25jZTogaWQsIHBpbm5lZDogZmFsc2UsIHRpbWVzdGFtcDogYWN0dWFsRGF0ZS50b0lTT1N0cmluZygpLCB0dHM6IGZhbHNlLCB0'
                'eXBlOiAzLCBjYWxsOiB7IHBhcnRpY2lwYW50czogbWlzc2VkID8gW2NhbGxlci5pZF0gOiBbY2FsbGVyLmlkLCBvdGhlci5pZF0sIGVuZGVkX3RpbWVzdGFt'
                'cDogZW5kZWREYXRlLnRvSVNPU3RyaW5nKCksIGR1cmF0aW9uOiBtaXNzZWQgPyB1bmRlZmluZWQgOiBkdXJhdGlvblNlYyB9IH0sIG9wdGltaXN0aWM6IGZh'
                'bHNlLCBpc1B1c2hOb3RpZmljYXRpb246IGZhbHNlIH0pOw0KICAgIHJlZ2lzdGVyRmFrZShjaGFubmVsSWQsIGlkKTsNCiAgICBpZiAoIXBlcnNpc3RlZElk'
                'KSBzYXZlUGVyc2lzdGVkKFsuLi5wZXJzaXN0ZWRGYWtlcywgeyB0eXBlOiAiY2FsbCIsIGNoYW5uZWxJZCwgY2FsbGVySWQ6IGNhbGxlci5pZCwgb3RoZXJJ'
                'ZDogb3RoZXIuaWQsIG1pc3NlZCwgZHVyYXRpb25TZWMsIHRpbWVzdGFtcDogYWN0dWFsRGF0ZS50b0lTT1N0cmluZygpLCBlbmRlZFRpbWVzdGFtcDogZW5k'
                'ZWREYXRlLnRvSVNPU3RyaW5nKCksIHNub3dmbGFrZUlkOiBpZCB9XSk7DQp9DQoNCmxldCBfcmVzdG9yZUhhbmRsZXI6ICgoKSA9PiB2b2lkKSB8IG51bGwg'
                'PSBudWxsOw0KbGV0IF9yZXN0b3JlVGltZXI6IFJldHVyblR5cGU8dHlwZW9mIHNldFRpbWVvdXQ+IHwgbnVsbCA9IG51bGw7DQpmdW5jdGlvbiBzY2hlZHVs'
                'ZVJlc3RvcmUoKSB7DQogICAgaWYgKF9yZXN0b3JlVGltZXIpIGNsZWFyVGltZW91dChfcmVzdG9yZVRpbWVyKTsNCiAgICBfcmVzdG9yZVRpbWVyID0gc2V0'
                'VGltZW91dCgoKSA9PiB7IF9yZXN0b3JlVGltZXIgPSBudWxsOyBmb3IgKGNvbnN0IGYgb2YgcGVyc2lzdGVkRmFrZXMpIHsgaWYgKGYudHlwZSA9PT0gIm1l'
                'c3NhZ2UiKSB7IGNvbnN0IGF1dGhvciA9IFVzZXJTdG9yZS5nZXRVc2VyKGYuYXV0aG9ySWQpOyBpZiAoYXV0aG9yKSBpbmplY3QoZi5jaGFubmVsSWQsIGF1'
                'dGhvciwgZi5jb250ZW50LCBuZXcgRGF0ZShmLnRpbWVzdGFtcCksIGYuc25vd2ZsYWtlSWQpOyB9IGVsc2UgeyBjb25zdCBjYWxsZXIgPSBVc2VyU3RvcmUu'
                'Z2V0VXNlcihmLmNhbGxlcklkKTsgY29uc3Qgb3RoZXIgPSBVc2VyU3RvcmUuZ2V0VXNlcihmLm90aGVySWQpOyBpZiAoY2FsbGVyICYmIG90aGVyKSBpbmpl'
                'Y3RDYWxsKGYuY2hhbm5lbElkLCBjYWxsZXIsIG90aGVyLCBmLm1pc3NlZCwgZi5kdXJhdGlvblNlYywgbmV3IERhdGUoZi50aW1lc3RhbXApLCBmLnNub3dm'
                'bGFrZUlkLCBmLmVuZGVkVGltZXN0YW1wKTsgfSB9IH0sIDEyMDApOw0KfQ0KDQpmdW5jdGlvbiB0b0xvY2FsKGQ6IERhdGUpOiBzdHJpbmcgeyBjb25zdCBw'
                'ID0gKG46IG51bWJlcikgPT4gU3RyaW5nKG4pLnBhZFN0YXJ0KDIsICIwIik7IHJldHVybiBgJHtkLmdldEZ1bGxZZWFyKCl9LSR7cChkLmdldE1vbnRoKCkr'
                'MSl9LSR7cChkLmdldERhdGUoKSl9VCR7cChkLmdldEhvdXJzKCkpfToke3AoZC5nZXRNaW51dGVzKCkpfWA7IH0NCg0KZnVuY3Rpb24gVXNlckF2YXRhcih7'
                'IHVzZXIgfTogeyB1c2VyOiBhbnk7IH0pIHsgY29uc3QgW2Vyciwgc2V0RXJyXSA9IFJlYWN0LnVzZVN0YXRlKGZhbHNlKTsgaWYgKCF1c2VyKSByZXR1cm4g'
                'bnVsbDsgY29uc3QgdXJsID0gYXZhdGFyVXJsKHVzZXIpOyBpZiAoZXJyIHx8ICF1cmwpIHJldHVybiA8ZGl2IGNsYXNzTmFtZT0iZmRtLXNlbmRlci1hdmF0'
                'YXIgZmRtLXNlbmRlci1hdmF0YXItcGxhY2Vob2xkZXIiPnt1c2VyLnVzZXJuYW1lPy5bMF0/LnRvVXBwZXJDYXNlKCkgPz8gIj8ifTwvZGl2PjsgcmV0dXJu'
                'IDxpbWcgc3JjPXt1cmx9IGNsYXNzTmFtZT0iZmRtLXNlbmRlci1hdmF0YXIiIGFsdD0iIiBvbkVycm9yPXsoKSA9PiBzZXRFcnIodHJ1ZSl9IC8+OyB9DQpm'
                'dW5jdGlvbiBNZW1iZXJTZWxlY3QoeyBtZW1iZXJzLCB2YWx1ZSwgb25DaGFuZ2UsIGxhYmVsIH06IHsgbWVtYmVyczogYW55W107IHZhbHVlOiBzdHJpbmc7'
                'IG9uQ2hhbmdlKGlkOiBzdHJpbmcpOiB2b2lkOyBsYWJlbD86IHN0cmluZzsgfSkgeyByZXR1cm4gPGRpdiBzdHlsZT17eyBkaXNwbGF5OiAiZmxleCIsIGFs'
                'aWduSXRlbXM6ICJjZW50ZXIiLCBnYXA6IDYsIHBhZGRpbmc6ICI0cHggMTJweCIgfX0+e2xhYmVsICYmIDxzcGFuIGNsYXNzTmFtZT0iZmRtLWRhdGUtbGFi'
                'ZWwiPntsYWJlbH08L3NwYW4+fTxzZWxlY3QgdmFsdWU9e3ZhbHVlfSBvbkNoYW5nZT17ZSA9PiBvbkNoYW5nZShlLnRhcmdldC52YWx1ZSl9IHN0eWxlPXt7'
                'IGZsZXg6IDEsIGJhY2tncm91bmQ6ICJyZ2JhKDI1NSwyNTUsMjU1LDAuMDcpIiwgYm9yZGVyOiAiMXB4IHNvbGlkIHJnYmEoMjU1LDI1NSwyNTUsMC4xMiki'
                'LCBib3JkZXJSYWRpdXM6IDYsIGNvbG9yOiAiI2ZmZiIsIGZvbnRTaXplOiAxMywgcGFkZGluZzogIjRweCA2cHgiLCBjdXJzb3I6ICJwb2ludGVyIiB9fT57'
                'bWVtYmVycy5tYXAobSA9PiA8b3B0aW9uIGtleT17bS5pZH0gdmFsdWU9e20uaWR9IHN0eWxlPXt7IGJhY2tncm91bmQ6ICIjMmIyZDMxIiB9fT57bS5nbG9i'
                'YWxOYW1lIHx8IG0udXNlcm5hbWV9PC9vcHRpb24+KX08L3NlbGVjdD48L2Rpdj47IH0NCg0KbGV0IF9wb3J0YWxSb290OiBIVE1MRGl2RWxlbWVudCB8IG51'
                'bGwgPSBudWxsOw0KZnVuY3Rpb24gZ2V0UG9ydGFsUm9vdCgpOiBIVE1MRGl2RWxlbWVudCB7IGlmICghX3BvcnRhbFJvb3QgfHwgIWRvY3VtZW50LmJvZHku'
                'Y29udGFpbnMoX3BvcnRhbFJvb3QpKSB7IF9wb3J0YWxSb290ID0gZG9jdW1lbnQuY3JlYXRlRWxlbWVudCgiZGl2Iik7IF9wb3J0YWxSb290LmlkID0gImZk'
                'bS1wb3J0YWwtcm9vdCI7IGRvY3VtZW50LmJvZHkuYXBwZW5kQ2hpbGQoX3BvcnRhbFJvb3QpOyB9IHJldHVybiBfcG9ydGFsUm9vdDsgfQ0KDQovLyBQYW5l'
                'bCBvcGVucyBuZWFyIHRoZSBib3R0b20gY2VudGVyIG9mIHRoZSBzY3JlZW4gKGFib3ZlIHRoZSBjaGF0IGJhcikNCmZ1bmN0aW9uIEZha2VETVBhbmVsKHsg'
                'b25DbG9zZSB9OiB7IG9uQ2xvc2UoKTogdm9pZDsgfSkgew0KICAgIGNvbnN0IG1lID0gVXNlclN0b3JlLmdldEN1cnJlbnRVc2VyKCk7IGNvbnN0IGNoID0g'
                'Z2V0Q3VycmVudERNQ2hhbm5lbCgpOyBjb25zdCBjaGFubmVsSWQgPSBTZWxlY3RlZENoYW5uZWxTdG9yZS5nZXRDaGFubmVsSWQoKTsNCiAgICBjb25zdCBp'
                'c0dyb3VwID0gY2g/LnR5cGUgPT09IDM7IGNvbnN0IG90aGVyID0gZ2V0T3RoZXJVc2VyKCk7IGNvbnN0IG1lbWJlcnMgPSBnZXRDaGFubmVsTWVtYmVycygp'
                'OyBjb25zdCBpc0luRE1Pckdyb3VwID0gISFjaDsNCiAgICBjb25zdCBbbW9kZSwgc2V0TW9kZV0gPSBSZWFjdC51c2VTdGF0ZTwibWVzc2FnZSIgfCAiY2Fs'
                'bCI+KCJtZXNzYWdlIik7DQogICAgY29uc3QgW3NlbmRlcklkLCBzZXRTZW5kZXJJZF0gPSBSZWFjdC51c2VTdGF0ZTxzdHJpbmc+KCgpID0+IG1lPy5pZCA/'
                'PyAiIik7DQogICAgY29uc3QgW2NhbGxlcklkLCBzZXRDYWxsZXJJZF0gPSBSZWFjdC51c2VTdGF0ZTxzdHJpbmc+KCgpID0+IG1lPy5pZCA/PyAiIik7DQog'
                'ICAgY29uc3QgW2NhbGxSZWNlaXZlcklkLCBzZXRDYWxsUmVjZWl2ZXJJZF0gPSBSZWFjdC51c2VTdGF0ZTxzdHJpbmc+KCgpID0+IG1lbWJlcnMuZmluZCht'
                'ID0+IG0uaWQgIT09IG1lPy5pZCk/LmlkID8/IG1lPy5pZCA/PyAiIik7DQogICAgY29uc3QgW2NhbGxNaXNzZWQsIHNldENhbGxNaXNzZWRdID0gUmVhY3Qu'
                'dXNlU3RhdGUoZmFsc2UpOyBjb25zdCBbY2FsbER1cmF0aW9uLCBzZXRDYWxsRHVyYXRpb25dID0gUmVhY3QudXNlU3RhdGUoIjUiKTsNCiAgICBjb25zdCBb'
                'dGV4dCwgc2V0VGV4dF0gPSBSZWFjdC51c2VTdGF0ZSgiIik7IGNvbnN0IFtkYXRlU3RyLCBzZXREYXRlU3RyXSA9IFJlYWN0LnVzZVN0YXRlKCgpID0+IHRv'
                'TG9jYWwobmV3IERhdGUoKSkpOw0KICAgIGNvbnN0IFtzdGF0dXMsIHNldFN0YXR1c10gPSBSZWFjdC51c2VTdGF0ZTx7IG1zZzogc3RyaW5nOyBvazogYm9v'
                'bGVhbjsgfSB8IG51bGw+KG51bGwpOw0KICAgIGNvbnN0IHRleHRhcmVhUmVmID0gUmVhY3QudXNlUmVmPEhUTUxUZXh0QXJlYUVsZW1lbnQ+KG51bGwpOw0K'
                'ICAgIGNvbnN0IHRpbWVycyA9IFJlYWN0LnVzZVJlZihuZXcgU2V0PFJldHVyblR5cGU8dHlwZW9mIHNldFRpbWVvdXQ+PigpKTsNCiAgICBmdW5jdGlvbiBz'
                'Y2hlZHVsZVBhbmVsVGFzayh0YXNrOiAoKSA9PiB2b2lkLCBkZWxheTogbnVtYmVyKSB7IGNvbnN0IHRpbWVyID0gc2V0VGltZW91dCgoKSA9PiB7IHRpbWVy'
                'cy5jdXJyZW50LmRlbGV0ZSh0aW1lcik7IHRhc2soKTsgfSwgZGVsYXkpOyB0aW1lcnMuY3VycmVudC5hZGQodGltZXIpOyB9DQogICAgUmVhY3QudXNlRWZm'
                'ZWN0KCgpID0+IHsgc2NoZWR1bGVQYW5lbFRhc2soKCkgPT4gdGV4dGFyZWFSZWYuY3VycmVudD8uZm9jdXMoKSwgODApOyByZXR1cm4gKCkgPT4geyB0aW1l'
                'cnMuY3VycmVudC5mb3JFYWNoKHRpbWVyID0+IGNsZWFyVGltZW91dCh0aW1lcikpOyB0aW1lcnMuY3VycmVudC5jbGVhcigpOyB9OyB9LCBbXSk7DQogICAg'
                'UmVhY3QudXNlRWZmZWN0KCgpID0+IHsgY29uc3QgaCA9IChlOiBLZXlib2FyZEV2ZW50KSA9PiB7IGlmIChlLmtleSA9PT0gIkVzY2FwZSIpIG9uQ2xvc2Uo'
                'KTsgfTsgZG9jdW1lbnQuYWRkRXZlbnRMaXN0ZW5lcigia2V5ZG93biIsIGgsIHRydWUpOyByZXR1cm4gKCkgPT4gZG9jdW1lbnQucmVtb3ZlRXZlbnRMaXN0'
                'ZW5lcigia2V5ZG93biIsIGgsIHRydWUpOyB9LCBbb25DbG9zZV0pOw0KICAgIGZ1bmN0aW9uIHNldE1zZyhtc2c6IHN0cmluZywgb2s6IGJvb2xlYW4pIHsg'
                'c2V0U3RhdHVzKHsgbXNnLCBvayB9KTsgc2NoZWR1bGVQYW5lbFRhc2soKCkgPT4gc2V0U3RhdHVzKG51bGwpLCAyNTAwKTsgfQ0KICAgIGZ1bmN0aW9uIHNl'
                'bmQoKSB7IGlmICghdGV4dC50cmltKCkgfHwgIWNoYW5uZWxJZCkgcmV0dXJuOyBjb25zdCBhdXRob3IgPSBtZW1iZXJzLmZpbmQobSA9PiBtLmlkID09PSBz'
                'ZW5kZXJJZCkgPz8gbWU7IGlmICghYXV0aG9yKSByZXR1cm47IGNvbnN0IGRhdGUgPSBuZXcgRGF0ZShkYXRlU3RyKTsgaWYgKGlzTmFOKGRhdGUuZ2V0VGlt'
                'ZSgpKSkgeyBzZXRNc2coIkludmFsaWQgRGF0ZSEiLCBmYWxzZSk7IHJldHVybjsgfSBpbmplY3QoY2hhbm5lbElkLCBhdXRob3IsIHRleHQudHJpbSgpLCBk'
                'YXRlKTsgc2V0VGV4dCgiIik7IHNldE1zZygiTWVzc2FnZSBpbmplY3RlZCIsIHRydWUpOyBzZXREYXRlU3RyKHRvTG9jYWwobmV3IERhdGUoZGF0ZS5nZXRU'
                'aW1lKCkgKyA2MF8wMDApKSk7IHNjaGVkdWxlUGFuZWxUYXNrKCgpID0+IHRleHRhcmVhUmVmLmN1cnJlbnQ/LmZvY3VzKCksIDEwKTsgfQ0KICAgIGZ1bmN0'
                'aW9uIHNlbmRDYWxsKCkgeyBpZiAoIWNoYW5uZWxJZCkgcmV0dXJuOyBjb25zdCBjYWxsZXJVc2VyID0gbWVtYmVycy5maW5kKG0gPT4gbS5pZCA9PT0gY2Fs'
                'bGVySWQpOyBjb25zdCByZWNlaXZlclVzZXIgPSBtZW1iZXJzLmZpbmQobSA9PiBtLmlkID09PSBjYWxsUmVjZWl2ZXJJZCk7IGlmICghY2FsbGVyVXNlciB8'
                'fCAhcmVjZWl2ZXJVc2VyKSByZXR1cm47IGNvbnN0IGRhdGUgPSBuZXcgRGF0ZShkYXRlU3RyKTsgaWYgKGlzTmFOKGRhdGUuZ2V0VGltZSgpKSkgeyBzZXRN'
                'c2coIkludmFsaWQgRGF0ZSEiLCBmYWxzZSk7IHJldHVybjsgfSBpbmplY3RDYWxsKGNoYW5uZWxJZCwgY2FsbGVyVXNlciwgcmVjZWl2ZXJVc2VyLCBjYWxs'
                'TWlzc2VkLCBjYWxsTWlzc2VkID8gMCA6IE1hdGgubWF4KDEsIE1hdGgucm91bmQoKHBhcnNlRmxvYXQoY2FsbER1cmF0aW9uKSB8fCAwKSAqIDYwKSksIGRh'
                'dGUpOyBzZXRNc2coY2FsbE1pc3NlZCA/ICJNaXNzZWQgY2FsbCBpbmplY3RlZCIgOiAiQ2FsbCBpbmplY3RlZCIsIHRydWUpOyBzZXREYXRlU3RyKHRvTG9j'
                'YWwobmV3IERhdGUoZGF0ZS5nZXRUaW1lKCkgKyA2MF8wMDApKSk7IH0NCiAgICBjb25zdCBtZU5hbWUgPSAobWUgYXMgYW55KT8uZ2xvYmFsTmFtZSB8fCBt'
                'ZT8udXNlcm5hbWUgfHwgIk1lIjsgY29uc3Qgb3RoZXJOYW1lID0gb3RoZXI/Lmdsb2JhbE5hbWUgfHwgb3RoZXI/LnVzZXJuYW1lIHx8ICJPdGhlciI7DQog'
                'ICAgY29uc3QgU2VuZGVyUm93ID0gaXNHcm91cCA/IDxNZW1iZXJTZWxlY3QgbWVtYmVycz17bWVtYmVyc30gdmFsdWU9e3NlbmRlcklkfSBvbkNoYW5nZT17'
                'c2V0U2VuZGVySWR9IGxhYmVsPSJGcm9tOiIgLz4gOiA8ZGl2IGNsYXNzTmFtZT0iZmRtLXNlbmRlci1yb3ciPjxidXR0b24gY2xhc3NOYW1lPXtgZmRtLXNl'
                'bmRlci1idG4ke3NlbmRlcklkID09PSBtZT8uaWQgPyAiIGZkbS1zZW5kZXItYnRuLWFjdGl2ZSIgOiAiIn1gfSBvbkNsaWNrPXsoKSA9PiBzZXRTZW5kZXJJ'
                'ZChtZT8uaWQgPz8gIiIpfT48VXNlckF2YXRhciB1c2VyPXttZX0gLz48c3BhbiBjbGFzc05hbWU9ImZkbS1zZW5kZXItbmFtZSI+e21lTmFtZX08L3NwYW4+'
                'PC9idXR0b24+PGJ1dHRvbiBjbGFzc05hbWU9e2BmZG0tc2VuZGVyLWJ0biR7c2VuZGVySWQgIT09IG1lPy5pZCA/ICIgZmRtLXNlbmRlci1idG4tYWN0aXZl'
                'IiA6ICIifWB9IG9uQ2xpY2s9eygpID0+IHNldFNlbmRlcklkKG90aGVyPy5pZCA/PyAiIil9PjxVc2VyQXZhdGFyIHVzZXI9e290aGVyfSAvPjxzcGFuIGNs'
                'YXNzTmFtZT0iZmRtLXNlbmRlci1uYW1lIj57b3RoZXJOYW1lfTwvc3Bhbj48L2J1dHRvbj48L2Rpdj47DQogICAgY29uc3QgQ2FsbGVyUm93ID0gaXNHcm91'
                'cCA/IDw+PE1lbWJlclNlbGVjdCBtZW1iZXJzPXttZW1iZXJzfSB2YWx1ZT17Y2FsbGVySWR9IG9uQ2hhbmdlPXtzZXRDYWxsZXJJZH0gbGFiZWw9IkNhbGxl'
                'cjoiIC8+PE1lbWJlclNlbGVjdCBtZW1iZXJzPXttZW1iZXJzfSB2YWx1ZT17Y2FsbFJlY2VpdmVySWR9IG9uQ2hhbmdlPXtzZXRDYWxsUmVjZWl2ZXJJZH0g'
                'bGFiZWw9IlJlY2VpdmVyOiIgLz48Lz4gOiA8ZGl2IGNsYXNzTmFtZT0iZmRtLXNlbmRlci1yb3ciPjxidXR0b24gY2xhc3NOYW1lPXtgZmRtLXNlbmRlci1i'
                'dG4ke2NhbGxlcklkID09PSBtZT8uaWQgPyAiIGZkbS1zZW5kZXItYnRuLWFjdGl2ZSIgOiAiIn1gfSBvbkNsaWNrPXsoKSA9PiB7IHNldENhbGxlcklkKG1l'
                'Py5pZCA/PyAiIik7IHNldENhbGxSZWNlaXZlcklkKG90aGVyPy5pZCA/PyAiIik7IH19PjxVc2VyQXZhdGFyIHVzZXI9e21lfSAvPjxzcGFuIGNsYXNzTmFt'
                'ZT0iZmRtLXNlbmRlci1uYW1lIj57bWVOYW1lfTwvc3Bhbj48L2J1dHRvbj48YnV0dG9uIGNsYXNzTmFtZT17YGZkbS1zZW5kZXItYnRuJHtjYWxsZXJJZCAh'
                'PT0gbWU/LmlkID8gIiBmZG0tc2VuZGVyLWJ0bi1hY3RpdmUiIDogIiJ9YH0gb25DbGljaz17KCkgPT4geyBzZXRDYWxsZXJJZChvdGhlcj8uaWQgPz8gIiIp'
                'OyBzZXRDYWxsUmVjZWl2ZXJJZChtZT8uaWQgPz8gIiIpOyB9fT48VXNlckF2YXRhciB1c2VyPXtvdGhlcn0gLz48c3BhbiBjbGFzc05hbWU9ImZkbS1zZW5k'
                'ZXItbmFtZSI+e290aGVyTmFtZX08L3NwYW4+PC9idXR0b24+PC9kaXY+Ow0KICAgIC8vIFBvc2l0aW9uOiBmaXhlZCwgY2VudGVyZWQgYWJvdmUgY2hhdCBi'
                'YXINCiAgICBjb25zdCBwYW5lbFN0eWxlOiBSZWFjdC5DU1NQcm9wZXJ0aWVzID0geyBwb3NpdGlvbjogImZpeGVkIiwgbGVmdDogIjUwJSIsIHRyYW5zZm9y'
                'bTogInRyYW5zbGF0ZVgoLTUwJSkiLCBib3R0b206ICI4MHB4Iiwgd2lkdGg6ICI0MzBweCIsIGJhY2tncm91bmRDb2xvcjogIiMyYjJkMzEiLCBib3JkZXI6'
                'ICIxcHggc29saWQgcmdiYSgyNTUsMjU1LDI1NSwwLjEpIiwgYm9yZGVyUmFkaXVzOiAiMTJweCIsIGJveFNoYWRvdzogIjAgMTZweCA0OHB4IHJnYmEoMCww'
                'LDAsMC42NSkiLCBvdmVyZmxvdzogImhpZGRlbiIsIHpJbmRleDogMTAwMDAwMCwgZGlzcGxheTogImZsZXgiLCBmbGV4RGlyZWN0aW9uOiAiY29sdW1uIiB9'
                'Ow0KICAgIHJldHVybiAoPD4NCiAgICAgICAgPGRpdiBvbkNsaWNrPXtvbkNsb3NlfSBzdHlsZT17eyBwb3NpdGlvbjogImZpeGVkIiwgaW5zZXQ6IDAsIHpJ'
                'bmRleDogOTk5OTk5LCBiYWNrZ3JvdW5kQ29sb3I6ICJyZ2JhKDAsMCwwLDAuNCkiIH19IC8+DQogICAgICAgIDxkaXYgY2xhc3NOYW1lPSJmZG0tcGFuZWwi'
                'IHN0eWxlPXtwYW5lbFN0eWxlfSBvbkNsaWNrPXtlID0+IGUuc3RvcFByb3BhZ2F0aW9uKCl9IG9uTW91c2VEb3duPXtlID0+IGUuc3RvcFByb3BhZ2F0aW9u'
                'KCl9Pg0KICAgICAgICAgICAgPGRpdiBjbGFzc05hbWU9ImZkbS1oZWFkZXIiPjxzcGFuIGNsYXNzTmFtZT0iZmRtLXRpdGxlIj57bW9kZSA9PT0gIm1lc3Nh'
                'Z2UiID8gIkZha2UgRE0iIDogIkZha2UgQ2FsbCJ9e2lzR3JvdXAgPyAiIChHcm91cCkiIDogIiJ9PC9zcGFuPjxidXR0b24gY2xhc3NOYW1lPSJmZG0tY2xv'
                'c2UiIG9uQ2xpY2s9e29uQ2xvc2V9Png8L2J1dHRvbj48L2Rpdj4NCiAgICAgICAgICAgIDxkaXYgc3R5bGU9e3sgZGlzcGxheTogImZsZXgiLCBnYXA6IDYs'
                'IHBhZGRpbmc6ICIwIDEycHggMTBweCIgfX0+DQogICAgICAgICAgICAgICAgPGJ1dHRvbiBvbkNsaWNrPXsoKSA9PiBzZXRNb2RlKCJtZXNzYWdlIil9IHN0'
                'eWxlPXt7IGZsZXg6IDEsIHBhZGRpbmc6ICI1cHggMCIsIGJvcmRlclJhZGl1czogNiwgYm9yZGVyOiAibm9uZSIsIGN1cnNvcjogInBvaW50ZXIiLCBmb250'
                'U2l6ZTogMTIsIGZvbnRXZWlnaHQ6IDYwMCwgYmFja2dyb3VuZDogbW9kZSA9PT0gIm1lc3NhZ2UiID8gIiM1ODY1ZjIiIDogInJnYmEoMjU1LDI1NSwyNTUs'
                'MC4wNykiLCBjb2xvcjogbW9kZSA9PT0gIm1lc3NhZ2UiID8gIiNmZmYiIDogInJnYmEoMjU1LDI1NSwyNTUsMC41KSIgfX0+TWVzc2FnZTwvYnV0dG9uPg0K'
                'ICAgICAgICAgICAgICAgIDxidXR0b24gb25DbGljaz17KCkgPT4gc2V0TW9kZSgiY2FsbCIpfSBzdHlsZT17eyBmbGV4OiAxLCBwYWRkaW5nOiAiNXB4IDAi'
                'LCBib3JkZXJSYWRpdXM6IDYsIGJvcmRlcjogIm5vbmUiLCBjdXJzb3I6ICJwb2ludGVyIiwgZm9udFNpemU6IDEyLCBmb250V2VpZ2h0OiA2MDAsIGJhY2tn'
                'cm91bmQ6IG1vZGUgPT09ICJjYWxsIiA/ICIjNTg2NWYyIiA6ICJyZ2JhKDI1NSwyNTUsMjU1LDAuMDcpIiwgY29sb3I6IG1vZGUgPT09ICJjYWxsIiA/ICIj'
                'ZmZmIiA6ICJyZ2JhKDI1NSwyNTUsMjU1LDAuNSkiIH19PkNhbGw8L2J1dHRvbj4NCiAgICAgICAgICAgIDwvZGl2Pg0KICAgICAgICAgICAgeyFpc0luRE1P'
                'ckdyb3VwID8gPGRpdiBzdHlsZT17eyBwYWRkaW5nOiAiMTZweCAxNHB4IiwgY29sb3I6ICJyZ2JhKDI1NSwyNTUsMjU1LDAuNDUpIiwgZm9udFNpemU6IDEz'
                'LCB0ZXh0QWxpZ246ICJjZW50ZXIiIH19Pk9wZW4gYSBETSBvciBncm91cCBETSBmaXJzdC48L2Rpdj4gOg0KICAgICAgICAgICAgbW9kZSA9PT0gIm1lc3Nh'
                'Z2UiID8gPD4NCiAgICAgICAgICAgICAgICB7U2VuZGVyUm93fQ0KICAgICAgICAgICAgICAgIDxkaXYgY2xhc3NOYW1lPSJmZG0tZGF0ZS1yb3ciPjxzcGFu'
                'IGNsYXNzTmFtZT0iZmRtLWRhdGUtbGFiZWwiPkRhdGU6PC9zcGFuPjxpbnB1dCB0eXBlPSJkYXRldGltZS1sb2NhbCIgY2xhc3NOYW1lPSJmZG0tZGF0ZS1p'
                'bnB1dCIgdmFsdWU9e2RhdGVTdHJ9IG9uQ2hhbmdlPXtlID0+IHNldERhdGVTdHIoZS50YXJnZXQudmFsdWUpfSAvPjxidXR0b24gY2xhc3NOYW1lPSJmZG0t'
                'ZGF0ZS1ub3ciIG9uQ2xpY2s9eygpID0+IHNldERhdGVTdHIodG9Mb2NhbChuZXcgRGF0ZSgpKSl9Pk5vdzwvYnV0dG9uPjwvZGl2Pg0KICAgICAgICAgICAg'
                'ICAgIDxkaXYgY2xhc3NOYW1lPSJmZG0taW5wdXQtcm93Ij48dGV4dGFyZWEgcmVmPXt0ZXh0YXJlYVJlZn0gY2xhc3NOYW1lPSJmZG0tdGV4dGFyZWEiIHJv'
                'd3M9ezJ9IHBsYWNlaG9sZGVyPSJNZXNzYWdlIChFbnRlciB0byBzZW5kKSIgdmFsdWU9e3RleHR9IG9uQ2hhbmdlPXtlID0+IHNldFRleHQoZS50YXJnZXQu'
                'dmFsdWUpfSBvbktleURvd249e2UgPT4geyBpZiAoZS5rZXkgPT09ICJFbnRlciIgJiYgIWUuc2hpZnRLZXkpIHsgZS5wcmV2ZW50RGVmYXVsdCgpOyBzZW5k'
                'KCk7IH0gfX0gLz48ZGl2IGNsYXNzTmFtZT0iZmRtLWFjdGlvbnMiPjxidXR0b24gY2xhc3NOYW1lPSJmZG0tc2VuZC1idG4iIGRpc2FibGVkPXshdGV4dC50'
                'cmltKCl9IG9uQ2xpY2s9e3NlbmR9PlNlbmQ8L2J1dHRvbj48YnV0dG9uIGNsYXNzTmFtZT0iZmRtLWNsZWFyLWJ0biIgb25DbGljaz17KCkgPT4geyBpZiAo'
                'IWNoYW5uZWxJZCkgcmV0dXJuOyBjb25zdCBuID0gY2xlYXJGYWtlcyhjaGFubmVsSWQpOyBzZXRNc2coYCR7bn0gY2xlYXJlZGAsIHRydWUpOyB9fT5DbGVh'
                'cjwvYnV0dG9uPjwvZGl2PjwvZGl2Pg0KICAgICAgICAgICAgPC8+IDogPD4NCiAgICAgICAgICAgICAgICB7Q2FsbGVyUm93fQ0KICAgICAgICAgICAgICAg'
                'IDxkaXYgc3R5bGU9e3sgZGlzcGxheTogImZsZXgiLCBhbGlnbkl0ZW1zOiAiY2VudGVyIiwgZ2FwOiA2LCBwYWRkaW5nOiAiNnB4IDEycHgiIH19Pg0KICAg'
                'ICAgICAgICAgICAgICAgICA8YnV0dG9uIG9uQ2xpY2s9eygpID0+IHNldENhbGxNaXNzZWQoZmFsc2UpfSBzdHlsZT17eyBmbGV4OiAxLCBwYWRkaW5nOiAi'
                'NHB4IDAiLCBib3JkZXJSYWRpdXM6IDYsIGJvcmRlcjogIm5vbmUiLCBjdXJzb3I6ICJwb2ludGVyIiwgZm9udFNpemU6IDEyLCBmb250V2VpZ2h0OiA2MDAs'
                'IGJhY2tncm91bmQ6ICFjYWxsTWlzc2VkID8gIiMzYmE1NWMiIDogInJnYmEoMjU1LDI1NSwyNTUsMC4wNykiLCBjb2xvcjogIWNhbGxNaXNzZWQgPyAiI2Zm'
                'ZiIgOiAicmdiYSgyNTUsMjU1LDI1NSwwLjQ1KSIgfX0+QW5zd2VyZWQ8L2J1dHRvbj4NCiAgICAgICAgICAgICAgICAgICAgPGJ1dHRvbiBvbkNsaWNrPXso'
                'KSA9PiBzZXRDYWxsTWlzc2VkKHRydWUpfSBzdHlsZT17eyBmbGV4OiAxLCBwYWRkaW5nOiAiNHB4IDAiLCBib3JkZXJSYWRpdXM6IDYsIGJvcmRlcjogIm5v'
                'bmUiLCBjdXJzb3I6ICJwb2ludGVyIiwgZm9udFNpemU6IDEyLCBmb250V2VpZ2h0OiA2MDAsIGJhY2tncm91bmQ6IGNhbGxNaXNzZWQgPyAiI2VkNDI0NSIg'
                'OiAicmdiYSgyNTUsMjU1LDI1NSwwLjA3KSIsIGNvbG9yOiBjYWxsTWlzc2VkID8gIiNmZmYiIDogInJnYmEoMjU1LDI1NSwyNTUsMC40NSkiIH19Pk1pc3Nl'
                'ZDwvYnV0dG9uPg0KICAgICAgICAgICAgICAgICAgICB7IWNhbGxNaXNzZWQgJiYgPGRpdiBzdHlsZT17eyBkaXNwbGF5OiAiZmxleCIsIGFsaWduSXRlbXM6'
                'ICJjZW50ZXIiLCBnYXA6IDQgfX0+PGlucHV0IHR5cGU9Im51bWJlciIgbWluPSIxIiBtYXg9Ijk5OSIgdmFsdWU9e2NhbGxEdXJhdGlvbn0gb25DaGFuZ2U9'
                'e2UgPT4gc2V0Q2FsbER1cmF0aW9uKGUudGFyZ2V0LnZhbHVlKX0gc3R5bGU9e3sgd2lkdGg6IDQ4LCBiYWNrZ3JvdW5kOiAicmdiYSgyNTUsMjU1LDI1NSww'
                'LjA3KSIsIGJvcmRlcjogIjFweCBzb2xpZCByZ2JhKDI1NSwyNTUsMjU1LDAuMTIpIiwgYm9yZGVyUmFkaXVzOiA2LCBjb2xvcjogIiNmZmYiLCBmb250U2l6'
                'ZTogMTIsIHBhZGRpbmc6ICIzcHggNnB4IiwgdGV4dEFsaWduOiAiY2VudGVyIiB9fSAvPjxzcGFuIHN0eWxlPXt7IGZvbnRTaXplOiAxMSwgY29sb3I6ICJy'
                'Z2JhKDI1NSwyNTUsMjU1LDAuNCkiIH19Pm1pbjwvc3Bhbj48L2Rpdj59DQogICAgICAgICAgICAgICAgPC9kaXY+DQogICAgICAgICAgICAgICAgPGRpdiBj'
                'bGFzc05hbWU9ImZkbS1kYXRlLXJvdyI+PHNwYW4gY2xhc3NOYW1lPSJmZG0tZGF0ZS1sYWJlbCI+RGF0ZTo8L3NwYW4+PGlucHV0IHR5cGU9ImRhdGV0aW1l'
                'LWxvY2FsIiBjbGFzc05hbWU9ImZkbS1kYXRlLWlucHV0IiB2YWx1ZT17ZGF0ZVN0cn0gb25DaGFuZ2U9e2UgPT4gc2V0RGF0ZVN0cihlLnRhcmdldC52YWx1'
                'ZSl9IC8+PGJ1dHRvbiBjbGFzc05hbWU9ImZkbS1kYXRlLW5vdyIgb25DbGljaz17KCkgPT4gc2V0RGF0ZVN0cih0b0xvY2FsKG5ldyBEYXRlKCkpKX0+Tm93'
                'PC9idXR0b24+PC9kaXY+DQogICAgICAgICAgICAgICAgPGRpdiBjbGFzc05hbWU9ImZkbS1pbnB1dC1yb3ciPjxkaXYgY2xhc3NOYW1lPSJmZG0tYWN0aW9u'
                'cyI+PGJ1dHRvbiBjbGFzc05hbWU9ImZkbS1zZW5kLWJ0biIgb25DbGljaz17c2VuZENhbGx9PkluamVjdCBDYWxsPC9idXR0b24+PGJ1dHRvbiBjbGFzc05h'
                'bWU9ImZkbS1jbGVhci1idG4iIG9uQ2xpY2s9eygpID0+IHsgaWYgKCFjaGFubmVsSWQpIHJldHVybjsgY29uc3QgbiA9IGNsZWFyRmFrZXMoY2hhbm5lbElk'
                'KTsgc2V0TXNnKGAke259IGNsZWFyZWRgLCB0cnVlKTsgfX0+Q2xlYXI8L2J1dHRvbj48L2Rpdj48L2Rpdj4NCiAgICAgICAgICAgIDwvPn0NCiAgICAgICAg'
                'ICAgIHtzdGF0dXMgJiYgPGRpdiBjbGFzc05hbWU9e2BmZG0tc3RhdHVzIGZkbS1zdGF0dXMtJHtzdGF0dXMub2sgPyAib2siIDogImVycm9yIn1gfT57c3Rh'
                'dHVzLm1zZ308L2Rpdj59DQogICAgICAgIDwvZGl2Pg0KICAgIDwvPik7DQp9DQoNCi8vIEZJWEVEOiBjaGF0QmFyQnV0dG9uLnJlbmRlciBpcyB0aGUgY29t'
                'cG9uZW50IHNsb3Q7IENoYXRCYXJCdXR0b24gd3JhcHMgdGhlIGljb24gaW5zaWRlIGl0Lg0KLy8gVGhlIHBhbmVsIGlzIHJlbmRlcmVkIHZpYSBhIHBvcnRh'
                'bCwgdG9nZ2xlZCBieSBjbGlja2luZyB0aGUgYmFyIGJ1dHRvbi4NCi8vIE5vIHJlZiBmb3J3YXJkaW5nIG5lZWRlZDsgcGFuZWwgaXMgYWx3YXlzIGNlbnRl'
                'cmVkIGFib3ZlIGNoYXQgYmFyLg0KY29uc3QgRmFrZURNQnV0dG9uSWNvbiA9ICgpID0+IDxzdmcgYXJpYS1oaWRkZW49InRydWUiIHJvbGU9ImltZyIgeG1s'
                'bnM9Imh0dHA6Ly93d3cudzMub3JnLzIwMDAvc3ZnIiB3aWR0aD0iMjAiIGhlaWdodD0iMjAiIGZpbGw9Im5vbmUiIHZpZXdCb3g9IjAgMCAyNCAyNCI+PHBh'
                'dGggZmlsbD0iY3VycmVudENvbG9yIiBkPSJNMTIgMkM2LjQ4NiAyIDIgNi4wMzcgMiAxMWMwIDIuNTc5IDEuMTc4IDQuODk4IDMuMDczIDYuNTc2TDQgMjJs'
                'NC42NDgtMi4zNDNDOS43MiAyMC4yMTMgMTAuODQ4IDIwLjQgMTIgMjAuNGM1LjUxNCAwIDEwLTQuMDM3IDEwLTlzLTQuNDg2LTktMTAtOVptMSAxM0g3di0y'
                'aDZ2MlptMi00SDd2LTJoOHYyWiIgLz48L3N2Zz47DQoNCmNvbnN0IEZha2VETUNoYXRCdXR0b246IENoYXRCYXJCdXR0b25GYWN0b3J5ID0gKHsgaXNNYWlu'
                'Q2hhdCB9KSA9PiB7DQogICAgY29uc3QgW29wZW4sIHNldE9wZW5dID0gUmVhY3QudXNlU3RhdGUoZmFsc2UpOw0KICAgIGlmICghaXNNYWluQ2hhdCkgcmV0'
                'dXJuIG51bGw7DQogICAgcmV0dXJuIDw+DQogICAgICAgIDxDaGF0QmFyQnV0dG9uIHRvb2x0aXA9IkZha2VETSIgb25DbGljaz17KCkgPT4gc2V0T3Blbih2'
                'ID0+ICF2KX0+DQogICAgICAgICAgICA8RmFrZURNQnV0dG9uSWNvbiAvPg0KICAgICAgICA8L0NoYXRCYXJCdXR0b24+DQogICAgICAgIHtvcGVuICYmIFJl'
                'YWN0RE9NLmNyZWF0ZVBvcnRhbCg8RmFrZURNUGFuZWwgb25DbG9zZT17KCkgPT4gc2V0T3BlbihmYWxzZSl9IC8+LCBnZXRQb3J0YWxSb290KCkpfQ0KICAg'
                'IDwvPjsNCn07DQoNCmV4cG9ydCBkZWZhdWx0IGRlZmluZVBsdWdpbih7DQogICAgbmFtZTogIkZha2VETSIsIGRlc2NyaXB0aW9uOiAiSW5qZWN0IGZha2Ug'
                'bWVzc2FnZXMgYW5kIGNhbGxzIGludG8gRE1zLiBPbmx5IHZpc2libGUgdG8geW91LiBDbGljayB0aGUgY2hhdCBiYXIgYnV0dG9uLiIsIGF1dGhvcnM6IFt7'
                'IG5hbWU6ICJzcWx1IiwgaWQ6IDBuIH1dLCBlbmFibGVkQnlEZWZhdWx0OiB0cnVlLCBkZXBlbmRlbmNpZXM6IFsiQ2hhdElucHV0QnV0dG9uQVBJIl0sDQog'
                'ICAgY2hhdEJhckJ1dHRvbjogeyBpY29uOiBGYWtlRE1CdXR0b25JY29uLCByZW5kZXI6IEZha2VETUNoYXRCdXR0b24gfSwNCiAgICBhc3luYyBzdGFydCgp'
                'IHsgYXdhaXQgbG9hZFBlcnNpc3RlZCgpOyBfcmVzdG9yZUhhbmRsZXIgPSAoKSA9PiB7IGZha2VJZHMuY2xlYXIoKTsgc2NoZWR1bGVSZXN0b3JlKCk7IH07'
                'IEZsdXhEaXNwYXRjaGVyLnN1YnNjcmliZSgiQ09OTkVDVElPTl9PUEVOIiwgX3Jlc3RvcmVIYW5kbGVyKTsgc2NoZWR1bGVSZXN0b3JlKCk7IH0sDQogICAg'
                'c3RvcCgpIHsgaWYgKF9yZXN0b3JlSGFuZGxlcikgeyBGbHV4RGlzcGF0Y2hlci51bnN1YnNjcmliZSgiQ09OTkVDVElPTl9PUEVOIiwgX3Jlc3RvcmVIYW5k'
                'bGVyKTsgX3Jlc3RvcmVIYW5kbGVyID0gbnVsbDsgfSBpZiAoX3Jlc3RvcmVUaW1lcikgeyBjbGVhclRpbWVvdXQoX3Jlc3RvcmVUaW1lcik7IF9yZXN0b3Jl'
                'VGltZXIgPSBudWxsOyB9IF9wb3J0YWxSb290Py5yZW1vdmUoKTsgX3BvcnRhbFJvb3QgPSBudWxsOyBmYWtlSWRzLmNsZWFyKCk7IH0NCn0pOw0K'
            ) -join '')
            'styles.css' = (@(
                'LyoNCiAqIE1vZGlmaWVkIGZvciBNeSBFcXVpY29yZCBTZXR1cCBieSBTcGVjdGF0b3IxNSwgMjAyNi0wOC0xNS4NCiAqIE9yaWdpbmFsIGNvcHlyaWdodCBh'
                'bmQgYXV0aG9yc2hpcCByZW1haW4gd2l0aCB0aGUgcmVzcGVjdGl2ZSB1cHN0cmVhbSBjb250cmlidXRvcnMuDQogKi8NCg0KLmZkbS1wYW5lbCB7DQogICAg'
                'Zm9udC1mYW1pbHk6IHZhcigtLWZvbnQtcHJpbWFyeSk7DQp9DQoNCi5mZG0taGVhZGVyIHsNCiAgICBkaXNwbGF5OiBmbGV4Ow0KICAgIGFsaWduLWl0ZW1z'
                'OiBjZW50ZXI7DQogICAganVzdGlmeS1jb250ZW50OiBzcGFjZS1iZXR3ZWVuOw0KICAgIHBhZGRpbmc6IDEycHggMTRweCAxMHB4Ow0KICAgIGJvcmRlci1i'
                'b3R0b206IDFweCBzb2xpZCByZ2IoMjU1IDI1NSAyNTUgLyA4JSk7DQp9DQoNCi5mZG0tdGl0bGUgew0KICAgIGNvbG9yOiAjZmZmOw0KICAgIGZvbnQtc2l6'
                'ZTogMTVweDsNCiAgICBmb250LXdlaWdodDogNzAwOw0KfQ0KDQouZmRtLWNsb3NlIHsNCiAgICBwYWRkaW5nOiAycHggNnB4Ow0KICAgIGJvcmRlcjogbm9u'
                'ZTsNCiAgICBib3JkZXItcmFkaXVzOiA0cHg7DQogICAgYmFja2dyb3VuZDogbm9uZTsNCiAgICBjb2xvcjogcmdiKDI1NSAyNTUgMjU1IC8gNTAlKTsNCiAg'
                'ICBmb250LXNpemU6IDE2cHg7DQogICAgY3Vyc29yOiBwb2ludGVyOw0KfQ0KDQouZmRtLWNsb3NlOmhvdmVyIHsNCiAgICBiYWNrZ3JvdW5kOiByZ2IoMjU1'
                'IDI1NSAyNTUgLyAxMCUpOw0KICAgIGNvbG9yOiAjZmZmOw0KfQ0KDQouZmRtLXNlbmRlci1yb3cgew0KICAgIGRpc3BsYXk6IGZsZXg7DQogICAgZ2FwOiA2'
                'cHg7DQogICAgcGFkZGluZzogMCAxMnB4IDhweDsNCn0NCg0KLmZkbS1zZW5kZXItYnRuIHsNCiAgICBkaXNwbGF5OiBmbGV4Ow0KICAgIGZsZXg6IDE7DQog'
                'ICAgZ2FwOiA2cHg7DQogICAgYWxpZ24taXRlbXM6IGNlbnRlcjsNCiAgICBwYWRkaW5nOiA1cHggOHB4Ow0KICAgIGJvcmRlcjogMS41cHggc29saWQgdHJh'
                'bnNwYXJlbnQ7DQogICAgYm9yZGVyLXJhZGl1czogOHB4Ow0KICAgIGJhY2tncm91bmQ6IHJnYigyNTUgMjU1IDI1NSAvIDUlKTsNCiAgICBjb2xvcjogcmdi'
                'KDI1NSAyNTUgMjU1IC8gNTAlKTsNCiAgICBmb250LXNpemU6IDEzcHg7DQogICAgZm9udC13ZWlnaHQ6IDUwMDsNCiAgICBjdXJzb3I6IHBvaW50ZXI7DQp9'
                'DQoNCi5mZG0tc2VuZGVyLWJ0bi1hY3RpdmUgew0KICAgIGJvcmRlci1jb2xvcjogIzU4NjVmMjsNCiAgICBiYWNrZ3JvdW5kOiByZ2IoODggMTAxIDI0MiAv'
                'IDE1JSk7DQogICAgY29sb3I6ICNmZmY7DQp9DQoNCi5mZG0tc2VuZGVyLWF2YXRhciB7DQogICAgd2lkdGg6IDI0cHg7DQogICAgaGVpZ2h0OiAyNHB4Ow0K'
                'ICAgIGJvcmRlci1yYWRpdXM6IDUwJTsNCiAgICBvYmplY3QtZml0OiBjb3ZlcjsNCiAgICBmbGV4LXNocmluazogMDsNCn0NCg0KLmZkbS1zZW5kZXItYXZh'
                'dGFyLXBsYWNlaG9sZGVyIHsNCiAgICBkaXNwbGF5OiBmbGV4Ow0KICAgIGFsaWduLWl0ZW1zOiBjZW50ZXI7DQogICAganVzdGlmeS1jb250ZW50OiBjZW50'
                'ZXI7DQogICAgYmFja2dyb3VuZDogIzU4NjVmMjsNCiAgICBjb2xvcjogI2ZmZjsNCiAgICBmb250LXNpemU6IDExcHg7DQogICAgZm9udC13ZWlnaHQ6IDcw'
                'MDsNCn0NCg0KLmZkbS1zZW5kZXItbmFtZSB7DQogICAgb3ZlcmZsb3c6IGhpZGRlbjsNCiAgICB0ZXh0LW92ZXJmbG93OiBlbGxpcHNpczsNCiAgICB3aGl0'
                'ZS1zcGFjZTogbm93cmFwOw0KfQ0KDQouZmRtLWRhdGUtcm93IHsNCiAgICBkaXNwbGF5OiBmbGV4Ow0KICAgIGdhcDogNnB4Ow0KICAgIGFsaWduLWl0ZW1z'
                'OiBjZW50ZXI7DQogICAgcGFkZGluZzogMCAxMnB4IDhweDsNCn0NCg0KLmZkbS1kYXRlLWxhYmVsIHsNCiAgICBjb2xvcjogcmdiKDI1NSAyNTUgMjU1IC8g'
                'NDAlKTsNCiAgICBmb250LXNpemU6IDEycHg7DQogICAgd2hpdGUtc3BhY2U6IG5vd3JhcDsNCiAgICBmbGV4LXNocmluazogMDsNCn0NCg0KLmZkbS1kYXRl'
                'LWlucHV0IHsNCiAgICBmbGV4OiAxOw0KICAgIHBhZGRpbmc6IDRweCA4cHg7DQogICAgYm9yZGVyOiAxcHggc29saWQgcmdiKDI1NSAyNTUgMjU1IC8gMTIl'
                'KTsNCiAgICBib3JkZXItcmFkaXVzOiA2cHg7DQogICAgb3V0bGluZTogbm9uZTsNCiAgICBiYWNrZ3JvdW5kOiByZ2IoMjU1IDI1NSAyNTUgLyA3JSk7DQog'
                'ICAgY29sb3I6ICNmZmY7DQogICAgZm9udC1zaXplOiAxMnB4Ow0KfQ0KDQouZmRtLWRhdGUtaW5wdXQ6Zm9jdXMgew0KICAgIGJvcmRlci1jb2xvcjogIzU4'
                'NjVmMjsNCn0NCg0KLmZkbS1kYXRlLW5vdyB7DQogICAgcGFkZGluZzogNHB4IDhweDsNCiAgICBib3JkZXI6IG5vbmU7DQogICAgYm9yZGVyLXJhZGl1czog'
                'NnB4Ow0KICAgIGJhY2tncm91bmQ6IHJnYigyNTUgMjU1IDI1NSAvIDglKTsNCiAgICBjb2xvcjogcmdiKDI1NSAyNTUgMjU1IC8gNjAlKTsNCiAgICBmb250'
                'LXNpemU6IDExcHg7DQogICAgY3Vyc29yOiBwb2ludGVyOw0KICAgIGZsZXgtc2hyaW5rOiAwOw0KfQ0KDQouZmRtLWRhdGUtbm93OmhvdmVyIHsNCiAgICBi'
                'YWNrZ3JvdW5kOiByZ2IoMjU1IDI1NSAyNTUgLyAxNSUpOw0KICAgIGNvbG9yOiAjZmZmOw0KfQ0KDQouZmRtLWlucHV0LXJvdyB7DQogICAgcGFkZGluZzog'
                'MCAxMnB4IDEycHg7DQp9DQoNCi5mZG0tdGV4dGFyZWEgew0KICAgIGJveC1zaXppbmc6IGJvcmRlci1ib3g7DQogICAgd2lkdGg6IDEwMCU7DQogICAgbWFy'
                'Z2luLWJvdHRvbTogOHB4Ow0KICAgIHBhZGRpbmc6IDhweCAxMHB4Ow0KICAgIGJvcmRlcjogMXB4IHNvbGlkIHJnYigyNTUgMjU1IDI1NSAvIDEwJSk7DQog'
                'ICAgYm9yZGVyLXJhZGl1czogOHB4Ow0KICAgIG91dGxpbmU6IG5vbmU7DQogICAgYmFja2dyb3VuZDogcmdiKDI1NSAyNTUgMjU1IC8gNiUpOw0KICAgIGNv'
                'bG9yOiAjZmZmOw0KICAgIGZvbnQtZmFtaWx5OiB2YXIoLS1mb250LXByaW1hcnkpOw0KICAgIGZvbnQtc2l6ZTogMTRweDsNCiAgICBsaW5lLWhlaWdodDog'
                'MS40Ow0KICAgIHJlc2l6ZTogbm9uZTsNCn0NCg0KLmZkbS10ZXh0YXJlYTpmb2N1cyB7DQogICAgYm9yZGVyLWNvbG9yOiAjNTg2NWYyOw0KfQ0KDQouZmRt'
                'LWFjdGlvbnMgew0KICAgIGRpc3BsYXk6IGZsZXg7DQogICAganVzdGlmeS1jb250ZW50OiBmbGV4LWVuZDsNCiAgICBnYXA6IDZweDsNCn0NCg0KLmZkbS1z'
                'ZW5kLWJ0biB7DQogICAgcGFkZGluZzogNnB4IDE2cHg7DQogICAgYm9yZGVyOiBub25lOw0KICAgIGJvcmRlci1yYWRpdXM6IDZweDsNCiAgICBiYWNrZ3Jv'
                'dW5kOiAjNTg2NWYyOw0KICAgIGNvbG9yOiAjZmZmOw0KICAgIGZvbnQtc2l6ZTogMTNweDsNCiAgICBmb250LXdlaWdodDogNjAwOw0KICAgIGN1cnNvcjog'
                'cG9pbnRlcjsNCn0NCg0KLmZkbS1zZW5kLWJ0bjpkaXNhYmxlZCB7DQogICAgYmFja2dyb3VuZDogcmdiKDg4IDEwMSAyNDIgLyA0MCUpOw0KICAgIGN1cnNv'
                'cjogbm90LWFsbG93ZWQ7DQp9DQoNCi5mZG0tc2VuZC1idG46bm90KDpkaXNhYmxlZCk6aG92ZXIgew0KICAgIGJhY2tncm91bmQ6ICM0NzUyYzQ7DQp9DQoN'
                'Ci5mZG0tY2xlYXItYnRuIHsNCiAgICBwYWRkaW5nOiA2cHggMTJweDsNCiAgICBib3JkZXI6IDFweCBzb2xpZCByZ2IoMjM3IDY2IDY5IC8gMzAlKTsNCiAg'
                'ICBib3JkZXItcmFkaXVzOiA2cHg7DQogICAgYmFja2dyb3VuZDogcmdiKDIzNyA2NiA2OSAvIDE1JSk7DQogICAgY29sb3I6ICNlZDQyNDU7DQogICAgZm9u'
                'dC1zaXplOiAxM3B4Ow0KICAgIGZvbnQtd2VpZ2h0OiA1MDA7DQogICAgY3Vyc29yOiBwb2ludGVyOw0KfQ0KDQouZmRtLWNsZWFyLWJ0bjpob3ZlciB7DQog'
                'ICAgYmFja2dyb3VuZDogcmdiKDIzNyA2NiA2OSAvIDI1JSk7DQp9DQoNCi5mZG0tc3RhdHVzIHsNCiAgICBwYWRkaW5nOiAwIDEycHggMTBweDsNCiAgICBm'
                'b250LXNpemU6IDEycHg7DQogICAgdGV4dC1hbGlnbjogY2VudGVyOw0KfQ0KDQouZmRtLXN0YXR1cy1vayB7DQogICAgY29sb3I6ICMzYmE1NWQ7DQp9DQoN'
                'Ci5mZG0tc3RhdHVzLWVycm9yIHsNCiAgICBjb2xvcjogI2VkNDI0NTsNCn0NCg=='
            ) -join '')
        }
    }
    [pscustomobject]@{
        Id = 'antiMoveDeco'
        DisplayName = 'AntiMoveDeco'
        FolderName = 'antiMoveDeco'
        Description = 'Keeps you in the selected voice channel when moved or disconnected.'
        DefaultSelected = $true
        LegacyFolders = @('AntiMoveDeco')
        Notes = 'Uses VoiceStateStore and clears pending reconnect timers.'
        Files = [ordered]@{
            'index.tsx' = (@(
                'LyoNCiAqIFZlbmNvcmQsIGEgRGlzY29yZCBjbGllbnQgbW9kDQogKiBDb3B5cmlnaHQgKGMpIDIwMjYgVmVuZGljYXRlZCBhbmQgY29udHJpYnV0b3JzDQog'
                'KiBTUERYLUxpY2Vuc2UtSWRlbnRpZmllcjogR1BMLTMuMC1vci1sYXRlcg0KICoNCiAqIE1vZGlmaWVkIGZvciBNeSBFcXVpY29yZCBTZXR1cCBieSBTcGVj'
                'dGF0b3IxNSwgMjAyNi0wOC0xNS4NCiAqIE9yaWdpbmFsIGNvcHlyaWdodCBhbmQgYXV0aG9yc2hpcCByZW1haW4gd2l0aCB0aGUgcmVzcGVjdGl2ZSB1cHN0'
                'cmVhbSBjb250cmlidXRvcnMuDQogKi8NCg0KaW1wb3J0IHsgQ2hhdEJhckJ1dHRvbiwgQ2hhdEJhckJ1dHRvbkZhY3RvcnkgfSBmcm9tICJAYXBpL0NoYXRC'
                'dXR0b25zIjsNCmltcG9ydCBkZWZpbmVQbHVnaW4gZnJvbSAiQHV0aWxzL3R5cGVzIjsNCmltcG9ydCB7IGZpbmRCeVByb3BzTGF6eSB9IGZyb20gIkB3ZWJw'
                'YWNrIjsNCmltcG9ydCB7IEZsdXhEaXNwYXRjaGVyLCBSZWFjdCwgVXNlclN0b3JlLCB1c2VTdGF0ZSxWb2ljZVN0YXRlU3RvcmUgfSBmcm9tICJAd2VicGFj'
                'ay9jb21tb24iOw0KDQpjb25zdCBDaGFubmVsQWN0aW9ucyA9IGZpbmRCeVByb3BzTGF6eSgic2VsZWN0Vm9pY2VDaGFubmVsIiwgImRpc2Nvbm5lY3QiKTsN'
                'Cg0KLy8gTW9kdWxlLWxldmVsIHN0YXRlIChwZXJzaXN0cyBhY3Jvc3MgcmVuZGVycykNCmxldCBhbnRpTW92ZUVuYWJsZWQgPSBmYWxzZTsNCmxldCB0YXJn'
                'ZXRDaGFubmVsSWQ6IHN0cmluZyB8IG51bGwgPSBudWxsOw0KbGV0IHJldHVyblRpbWVyOiBSZXR1cm5UeXBlPHR5cGVvZiBzZXRUaW1lb3V0PiB8IG51bGwg'
                'PSBudWxsOw0KDQpmdW5jdGlvbiByZXR1cm5Ub1RhcmdldENoYW5uZWwoKSB7DQogICAgaWYgKCF0YXJnZXRDaGFubmVsSWQpIHJldHVybjsNCiAgICBpZiAo'
                'cmV0dXJuVGltZXIpIGNsZWFyVGltZW91dChyZXR1cm5UaW1lcik7DQogICAgcmV0dXJuVGltZXIgPSBzZXRUaW1lb3V0KCgpID0+IHsNCiAgICAgICAgcmV0'
                'dXJuVGltZXIgPSBudWxsOw0KICAgICAgICB0cnkgeyBpZiAodGFyZ2V0Q2hhbm5lbElkKSBDaGFubmVsQWN0aW9ucz8uc2VsZWN0Vm9pY2VDaGFubmVsPy4o'
                'dGFyZ2V0Q2hhbm5lbElkKTsgfSBjYXRjaCB7fQ0KICAgIH0sIDUwMCk7DQp9DQoNCmZ1bmN0aW9uIG9uVm9pY2VTdGF0ZVVwZGF0ZSh7IHZvaWNlU3RhdGVz'
                'IH06IHsgdm9pY2VTdGF0ZXM6IGFueVtdOyB9KSB7DQogICAgaWYgKCFhbnRpTW92ZUVuYWJsZWQgfHwgIXRhcmdldENoYW5uZWxJZCkgcmV0dXJuOw0KICAg'
                'IGNvbnN0IGN1cnJlbnRVc2VyID0gVXNlclN0b3JlLmdldEN1cnJlbnRVc2VyKCk7DQogICAgaWYgKCFjdXJyZW50VXNlcikgcmV0dXJuOw0KICAgIGNvbnN0'
                'IG15U3RhdGUgPSB2b2ljZVN0YXRlcy5maW5kKHMgPT4gcy51c2VySWQgPT09IGN1cnJlbnRVc2VyLmlkKTsNCiAgICBpZiAoIW15U3RhdGUpIHJldHVybjsN'
                'CiAgICAvLyBJZiBtb3ZlZCB0byBhIGRpZmZlcmVudCBjaGFubmVsIG9yIGRpc2Nvbm5lY3RlZCwgc25hcCBiYWNrDQogICAgaWYgKG15U3RhdGUuY2hhbm5l'
                'bElkICYmIG15U3RhdGUuY2hhbm5lbElkICE9PSB0YXJnZXRDaGFubmVsSWQpIHsNCiAgICAgICAgcmV0dXJuVG9UYXJnZXRDaGFubmVsKCk7DQogICAgfSBl'
                'bHNlIGlmICghbXlTdGF0ZS5jaGFubmVsSWQpIHsNCiAgICAgICAgLy8gRGlzY29ubmVjdGVkIC0gcmVqb2luDQogICAgICAgIHJldHVyblRvVGFyZ2V0Q2hh'
                'bm5lbCgpOw0KICAgIH0NCn0NCg0KLy8gTGlzdGVuZXJzIHNldCBzbyB0aGUgYnV0dG9uIGNvbXBvbmVudCBjYW4gcmVhY3QgdG8gbW9kdWxlLWxldmVsIHN0'
                'YXRlIGNoYW5nZXMNCmNvbnN0IHN0YXRlTGlzdGVuZXJzID0gbmV3IFNldDwoZW5hYmxlZDogYm9vbGVhbikgPT4gdm9pZD4oKTsNCmZ1bmN0aW9uIG5vdGlm'
                'eVN0YXRlQ2hhbmdlKGVuYWJsZWQ6IGJvb2xlYW4pIHsgc3RhdGVMaXN0ZW5lcnMuZm9yRWFjaChmbiA9PiBmbihlbmFibGVkKSk7IH0NCg0KY29uc3QgQW50'
                'aU1vdmVCdXR0b246IENoYXRCYXJCdXR0b25GYWN0b3J5ID0gKHsgaXNNYWluQ2hhdCB9KSA9PiB7DQogICAgY29uc3QgW2VuYWJsZWQsIHNldEVuYWJsZWRd'
                'ID0gdXNlU3RhdGUoYW50aU1vdmVFbmFibGVkKTsNCg0KICAgIFJlYWN0LnVzZUVmZmVjdCgoKSA9PiB7DQogICAgICAgIGNvbnN0IGxpc3RlbmVyID0gKGU6'
                'IGJvb2xlYW4pID0+IHNldEVuYWJsZWQoZSk7DQogICAgICAgIHN0YXRlTGlzdGVuZXJzLmFkZChsaXN0ZW5lcik7DQogICAgICAgIHJldHVybiAoKSA9PiB7'
                'IHN0YXRlTGlzdGVuZXJzLmRlbGV0ZShsaXN0ZW5lcik7IH07DQogICAgfSwgW10pOw0KDQogICAgaWYgKCFpc01haW5DaGF0KSByZXR1cm4gbnVsbDsNCg0K'
                'ICAgIGZ1bmN0aW9uIHRvZ2dsZSgpIHsNCiAgICAgICAgYW50aU1vdmVFbmFibGVkID0gIWFudGlNb3ZlRW5hYmxlZDsNCiAgICAgICAgaWYgKGFudGlNb3Zl'
                'RW5hYmxlZCkgew0KICAgICAgICAgICAgLy8gTG9jayB0byBjdXJyZW50IHZvaWNlIGNoYW5uZWwNCiAgICAgICAgICAgIHRyeSB7DQogICAgICAgICAgICAg'
                'ICAgY29uc3QgbWUgPSBVc2VyU3RvcmUuZ2V0Q3VycmVudFVzZXIoKTsNCiAgICAgICAgICAgICAgICBpZiAobWUpIHsNCiAgICAgICAgICAgICAgICAgICAg'
                'Y29uc3QgdnMgPSBWb2ljZVN0YXRlU3RvcmU/LmdldFZvaWNlU3RhdGVGb3JVc2VyPy4obWUuaWQpOw0KICAgICAgICAgICAgICAgICAgICB0YXJnZXRDaGFu'
                'bmVsSWQgPSB2cz8uY2hhbm5lbElkID8/IG51bGw7DQogICAgICAgICAgICAgICAgfQ0KICAgICAgICAgICAgfSBjYXRjaCB7fQ0KICAgICAgICB9IGVsc2Ug'
                'ew0KICAgICAgICAgICAgdGFyZ2V0Q2hhbm5lbElkID0gbnVsbDsNCiAgICAgICAgfQ0KICAgICAgICBub3RpZnlTdGF0ZUNoYW5nZShhbnRpTW92ZUVuYWJs'
                'ZWQpOw0KICAgIH0NCg0KICAgIGNvbnN0IGNvbG9yID0gZW5hYmxlZCA/ICIjNDNiNTgxIiA6ICJjdXJyZW50Q29sb3IiOw0KICAgIGNvbnN0IHRvb2x0aXAg'
                'PSBlbmFibGVkDQogICAgICAgID8gYEFudGlNb3ZlOiBPTiR7dGFyZ2V0Q2hhbm5lbElkID8gIiAobG9ja2VkKSIgOiAiIChqb2luIGEgVkMgZmlyc3QpIn0g'
                'LSBjbGljayB0byBkaXNhYmxlYA0KICAgICAgICA6ICJBbnRpTW92ZTogT0ZGIC0gY2xpY2sgdG8gZW5hYmxlIChqb2luIGEgVkMgZmlyc3QpIjsNCg0KICAg'
                'IHJldHVybiAoDQogICAgICAgIDxDaGF0QmFyQnV0dG9uIHRvb2x0aXA9e3Rvb2x0aXB9IG9uQ2xpY2s9e3RvZ2dsZX0+DQogICAgICAgICAgICA8c3ZnIHdp'
                'ZHRoPSIyMCIgaGVpZ2h0PSIyMCIgdmlld0JveD0iMCAwIDI0IDI0IiBmaWxsPSJub25lIiB4bWxucz0iaHR0cDovL3d3dy53My5vcmcvMjAwMC9zdmciPg0K'
                'ICAgICAgICAgICAgICAgIDxjaXJjbGUgY3g9IjEyIiBjeT0iMTIiIHI9IjkiIHN0cm9rZT17Y29sb3J9IHN0cm9rZVdpZHRoPSIyIiAvPg0KICAgICAgICAg'
                'ICAgICAgIHtlbmFibGVkDQogICAgICAgICAgICAgICAgICAgID8gPHBhdGggZmlsbD17Y29sb3J9IGQ9Ik05IDEybDIgMiA0LTQiIHN0cm9rZT17Y29sb3J9'
                'IHN0cm9rZVdpZHRoPSIyIiBzdHJva2VMaW5lY2FwPSJyb3VuZCIgc3Ryb2tlTGluZWpvaW49InJvdW5kIiAvPg0KICAgICAgICAgICAgICAgICAgICA6IDxw'
                'YXRoIGZpbGw9e2NvbG9yfSBkPSJNOCA4bDggOE0xNiA4bC04IDgiIHN0cm9rZT17Y29sb3J9IHN0cm9rZVdpZHRoPSIyIiBzdHJva2VMaW5lY2FwPSJyb3Vu'
                'ZCIgLz4NCiAgICAgICAgICAgICAgICB9DQogICAgICAgICAgICA8L3N2Zz4NCiAgICAgICAgPC9DaGF0QmFyQnV0dG9uPg0KICAgICk7DQp9Ow0KDQpleHBv'
                'cnQgZGVmYXVsdCBkZWZpbmVQbHVnaW4oew0KICAgIG5hbWU6ICJBbnRpTW92ZURlY28iLA0KICAgIGRlc2NyaXB0aW9uOiAiUHJldmVudHMgYmVpbmcgbW92'
                'ZWQgb3IgZGlzY29ubmVjdGVkIGZyb20gYSB2b2ljZSBjaGFubmVsLiBUb2dnbGUgdmlhIGNoYXQgYmFyIGJ1dHRvbi4iLA0KICAgIGF1dGhvcnM6IFt7IG5h'
                'bWU6ICJOaWdodGNvcmQiLCBpZDogMG4gfV0sDQogICAgZW5hYmxlZEJ5RGVmYXVsdDogdHJ1ZSwNCiAgICBkZXBlbmRlbmNpZXM6IFsiQ2hhdElucHV0QnV0'
                'dG9uQVBJIl0sDQogICAgY2hhdEJhckJ1dHRvbjogeyBpY29uOiAoKSA9PiA8c3ZnIHdpZHRoPSIyMCIgaGVpZ2h0PSIyMCIgdmlld0JveD0iMCAwIDI0IDI0'
                'IiBmaWxsPSJub25lIiB4bWxucz0iaHR0cDovL3d3dy53My5vcmcvMjAwMC9zdmciPjxjaXJjbGUgY3g9IjEyIiBjeT0iMTIiIHI9IjkiIHN0cm9rZT0iY3Vy'
                'cmVudENvbG9yIiBzdHJva2VXaWR0aD0iMiIgLz48L3N2Zz4sIHJlbmRlcjogQW50aU1vdmVCdXR0b24gfSwNCiAgICBzdGFydCgpIHsgRmx1eERpc3BhdGNo'
                'ZXIuc3Vic2NyaWJlKCJWT0lDRV9TVEFURV9VUERBVEVTIiwgb25Wb2ljZVN0YXRlVXBkYXRlKTsgfSwNCiAgICBzdG9wKCkgeyBGbHV4RGlzcGF0Y2hlci51'
                'bnN1YnNjcmliZSgiVk9JQ0VfU1RBVEVfVVBEQVRFUyIsIG9uVm9pY2VTdGF0ZVVwZGF0ZSk7IGlmIChyZXR1cm5UaW1lcikgeyBjbGVhclRpbWVvdXQocmV0'
                'dXJuVGltZXIpOyByZXR1cm5UaW1lciA9IG51bGw7IH0gYW50aU1vdmVFbmFibGVkID0gZmFsc2U7IHRhcmdldENoYW5uZWxJZCA9IG51bGw7IG5vdGlmeVN0'
                'YXRlQ2hhbmdlKGZhbHNlKTsgfQ0KfSk7DQo='
            ) -join '')
        }
    }
)
#endregion

function Get-SafePluginFilePath {
    param(
        [Parameter(Mandatory = $true)][string]$PluginDirectory,
        [Parameter(Mandatory = $true)][string]$FileName
    )
    if ([string]::IsNullOrWhiteSpace($FileName) -or
        $FileName -eq "." -or
        $FileName -eq ".." -or
        [IO.Path]::GetFileName($FileName) -cne $FileName -or
        $FileName.IndexOfAny([IO.Path]::GetInvalidFileNameChars()) -ge 0) {
        throw "Unsafe bundled plugin file name: $FileName"
    }
    return Join-Path $PluginDirectory $FileName
}

function Write-BundledPlugin {
    param(
        [Parameter(Mandatory = $true)]$Plugin,
        [Parameter(Mandatory = $true)][string]$PluginsDir
    )

    $directory = Get-SafeChildPath -Root $PluginsDir -Child $Plugin.FolderName
    if (-not (Test-Path -LiteralPath $directory)) {
        New-Item -ItemType Directory -Path $directory -Force | Out-Null
    }
    $directoryItem = Get-Item -LiteralPath $directory -Force -ErrorAction Stop
    if (-not $directoryItem.PSIsContainer) {
        throw "Refusing to write plugin files through a non-directory path: $directory"
    }
    if (($directoryItem.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
        throw "Refusing to write plugin files through a reparse-point directory: $directory"
    }
    if (-not $Plugin.Files -or $Plugin.Files.Count -eq 0) {
        throw "Bundled plugin has no embedded files: $($Plugin.DisplayName)"
    }

    $changed = $false
    $strictUtf8 = New-Object System.Text.UTF8Encoding -ArgumentList $false, $true
    foreach ($file in $Plugin.Files.GetEnumerator()) {
        $path = Get-SafePluginFilePath -PluginDirectory $directory -FileName ([string]$file.Key)
        try {
            $bytes = [Convert]::FromBase64String([string]$file.Value)
            $content = $strictUtf8.GetString($bytes)
        } catch {
            throw "Embedded file data is invalid for $($Plugin.DisplayName)/$($file.Key): $($_.Exception.Message)"
        }
        if (Write-Utf8FileAtomic -Path $path -Content $content) { $changed = $true }
    }
    return $changed
}

#region PLUGIN REGISTRY AND CONFIG
function Get-BundledPlugins {
    return @($script:BundledPlugins)
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
                $casingChanged = Normalize-PluginFolderCasing -Plugin $plugin -PluginsDir $pluginsDir
                $changed = Write-BundledPlugin -Plugin $plugin -PluginsDir $pluginsDir
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
