#region INIT
$Host.UI.RawUI.WindowTitle = "EquicordSetup"
try { $Host.UI.RawUI.BackgroundColor = "Black"; Clear-Host } catch {}

$LINE = "-" * 60
$script:RepoUrl = "https://github.com/Equicord/Equicord"
$script:ManagerId = "Spectator15/My-equicord-setup"
$script:DocumentsDir = [Environment]::GetFolderPath("MyDocuments")
$script:EquicordDir = Join-Path $script:DocumentsDir "Equicord"
$script:ConfigDir = Join-Path $env:LOCALAPPDATA "EquicordSetup"
$script:ConfigPath = Join-Path $script:ConfigDir "config.json"
$script:DependencyStatePath = Join-Path $script:ConfigDir "dependency-state.json"
$script:OwnershipPath = Join-Path $script:ConfigDir "workspace-owner.json"
$script:UninstallStatePath = Join-Path $script:ConfigDir "uninstall-state.json"
$script:LogDir = Join-Path $script:ConfigDir "logs"
$script:BackupDir = Join-Path $script:ConfigDir "backups"
$script:CacheDir = Join-Path $script:ConfigDir "cache"
$script:TempDir = Join-Path $script:ConfigDir "temp"
$script:ConfigVersion = 3
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
        @{ Name = "Discord Stable"; Branch = "stable"; ProcessName = "Discord"; Root = (Join-Path $env:LOCALAPPDATA "Discord") },
        @{ Name = "Discord PTB"; Branch = "ptb"; ProcessName = "DiscordPTB"; Root = (Join-Path $env:LOCALAPPDATA "DiscordPTB") },
        @{ Name = "Discord Canary"; Branch = "canary"; ProcessName = "DiscordCanary"; Root = (Join-Path $env:LOCALAPPDATA "DiscordCanary") }
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
                    Branch = $candidate.Branch
                    ProcessName = $candidate.ProcessName
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

function Test-EquicordLoaderAsar {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [string]$ExpectedEquicordDirectory = (Join-Path $script:EquicordDir "dist\desktop")
    )
    try {
        if (Test-Path -LiteralPath $Path -PathType Container) {
            $item = Get-Item -LiteralPath $Path -Force -ErrorAction Stop
            if (($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) { return $false }
            $indexPath = Join-Path $Path "index.js"
            $packagePath = Join-Path $Path "package.json"
            if (-not (Test-Path -LiteralPath $indexPath -PathType Leaf) -or
                -not (Test-Path -LiteralPath $packagePath -PathType Leaf)) { return $false }
            $index = [IO.File]::ReadAllText($indexPath)
            $package = [IO.File]::ReadAllText($packagePath)
            $expectedDesktop = ([IO.Path]::GetFullPath($ExpectedEquicordDirectory)).Replace("\", "\\")
            $expectedPatcher = ([IO.Path]::GetFullPath((Join-Path $ExpectedEquicordDirectory "patcher.js"))).Replace("\", "\\")
            return $package.Contains('"name"') -and $package.Contains('"discord"') -and
                ($index.Contains($expectedDesktop) -or $index.Contains($expectedPatcher))
        }

        if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { return $false }
        $item = Get-Item -LiteralPath $Path -Force -ErrorAction Stop
        if (($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0 -or $item.Length -gt 131072) { return $false }
        $text = [Text.Encoding]::UTF8.GetString([IO.File]::ReadAllBytes($Path))
        $expected = ([IO.Path]::GetFullPath($ExpectedEquicordDirectory)).Replace("\", "\\")
        return [regex]::IsMatch($text, '"name"\s*:\s*"discord"') -and
            [regex]::IsMatch($text, '"main"\s*:\s*"index[.]js"') -and
            $text.Contains("require(") -and $text.Contains($expected)
    } catch { return $false }
}

function Test-EquicordInjectionMarker {
    param([Parameter(Mandatory = $true)]$Install)
    return Test-EquicordLoaderAsar -Path (Join-Path $Install.Resources "app.asar")
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
# <BUILD:BUNDLED_PLUGIN_REGISTRY>
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

function Write-SetupConfigRecord {
    param(
        [Parameter(Mandatory = $true)][AllowNull()][AllowEmptyCollection()][string[]]$SelectedIds,
        [AllowNull()]$DiscordTarget
    )
    try {
        if ($null -eq $SelectedIds) { $SelectedIds = @() }
        $data = [ordered]@{
            version = $script:ConfigVersion
            selectedPluginIds = @($SelectedIds | Sort-Object)
            workspacePath = [IO.Path]::GetFullPath($script:EquicordDir)
            updatedAt = (Get-Date).ToString("o")
        }
        if ($DiscordTarget) { $data.discordTarget = $DiscordTarget }
        $json = $data | ConvertTo-Json -Depth 6
        Write-Utf8FileAtomic -Path $script:ConfigPath -Content $json | Out-Null
        return $true
    } catch {
        Write-Warn "Setup configuration could not be saved safely: $($_.Exception.Message)"
        return $false
    }
}

function Save-SetupConfig {
    param([Parameter(Mandatory = $true)][AllowNull()][AllowEmptyCollection()][string[]]$SelectedIds)
    $existing = Load-SetupConfig
    $targetProperty = if ($existing) { $existing.PSObject.Properties["discordTarget"] } else { $null }
    $target = if ($targetProperty) { $targetProperty.Value } else { $null }
    return Write-SetupConfigRecord -SelectedIds $SelectedIds -DiscordTarget $target
}

function ConvertTo-DiscordTargetRecord {
    param([Parameter(Mandatory = $true)]$Install)
    return [ordered]@{
        branch = [string]$Install.Branch
        name = [string]$Install.Name
        root = [IO.Path]::GetFullPath([string]$Install.Root)
    }
}

function Save-RecordedDiscordTarget {
    param([Parameter(Mandatory = $true)]$Install)
    $existing = Load-SetupConfig
    $selectionProperty = if ($existing) { $existing.PSObject.Properties["selectedPluginIds"] } else { $null }
    $selected = if ($selectionProperty) {
        @($selectionProperty.Value | ForEach-Object { [string]$_ })
    } else {
        @(Get-InstalledBundledPluginIds -PluginsDir (Get-PluginsDir $script:EquicordDir))
    }
    if (-not (Write-SetupConfigRecord -SelectedIds $selected -DiscordTarget (ConvertTo-DiscordTargetRecord -Install $Install))) {
        throw "The selected Discord target could not be recorded safely."
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

function Invoke-EquicordInstallerAction {
    param(
        [Parameter(Mandatory = $true)][ValidateSet("Install", "Repair", "Uninstall")][string]$Action,
        [Parameter(Mandatory = $true)]$Install,
        [scriptblock]$Invoker
    )
    if ($Action -eq "Uninstall") {
        [void](Assert-ValidatedDiscordInstall $Install)
        if (-not (Get-WorkspaceOwnershipAssessment).CanUseInstaller) {
            throw "The official installer wrapper could not be verified. Recovery files were preserved."
        }
        if (-not $Invoker) { Assert-NoUnrelatedDiscordProcess $Install }
    }
    $node = Resolve-Executable @("node.exe", "node")
    if (-not $node) { throw "Node.js is not available in this terminal session." }
    $runner = Join-Path $script:EquicordDir "scripts\runInstaller.mjs"
    if (-not (Test-Path -LiteralPath $runner -PathType Leaf)) { throw "Equicord's installer runner is missing: $runner" }
    $argument = switch ($Action) {
        "Install" { "--install" }
        "Repair" { "--repair" }
        "Uninstall" { "--uninstall" }
    }
    $arguments = @("scripts/runInstaller.mjs", "--", $argument, "--location", [string]$Install.Root)
    if ($Invoker) {
        & $Invoker $node $arguments "Equicord installer" $script:EquicordDir
        return
    }
    Invoke-InDirectory -Path $script:EquicordDir -Script {
        Invoke-NativeChecked -FilePath $node -Arguments $arguments -Description "Equicord installer"
    }
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
    $installerAction = if ($Repair) { "Repair" } else { "Install" }
    Write-Step ($(if ($Repair) { "Repairing and reinjecting Equicord..." } else { "Injecting Equicord..." }))
    Invoke-EquicordInstallerAction -Action $installerAction -Install $install
    if (-not (Test-EquicordInjectionMarker -Install $install)) {
        throw "The installer returned without creating a valid Equicord loader in $($install.Name)."
    }
    Save-RecordedDiscordTarget -Install $install
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
    Write-WorkspaceOwnershipRecord -MigrationReason "new-installation"
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

#region FULL WINDOWS REMOVAL
function Get-NormalizedWindowsPath {
    param([Parameter(Mandatory = $true)][string]$Path)
    if ([string]::IsNullOrWhiteSpace($Path) -or $Path -notmatch '^[A-Za-z]:[\\/]') {
        throw "Refusing to use an empty, relative, or unsupported non-local path."
    }
    $full = [IO.Path]::GetFullPath($Path)
    $root = [IO.Path]::GetPathRoot($full)
    if ($full.Length -gt $root.Length) { $full = $full.TrimEnd("\") }
    return $full
}

function Assert-NoReparseTraversal {
    param([Parameter(Mandatory = $true)][string]$Path)
    $cursor = Get-NormalizedWindowsPath $Path
    while ($cursor) {
        $item = Get-Item -LiteralPath $cursor -Force -ErrorAction SilentlyContinue
        if ($item -and ($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
            throw "Refusing to traverse a reparse point, junction, or symbolic link: $cursor"
        }
        $parent = Split-Path -Parent $cursor
        if (-not $parent -or $parent -eq $cursor) { break }
        $cursor = $parent
    }
}

function Test-SameWindowsPath {
    param([Parameter(Mandatory = $true)][string]$Left, [Parameter(Mandatory = $true)][string]$Right)
    try {
        return (Get-NormalizedWindowsPath $Left).Equals(
            (Get-NormalizedWindowsPath $Right),
            [StringComparison]::OrdinalIgnoreCase
        )
    } catch { return $false }
}

function Assert-ExactManagerDirectoryPath {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][string]$Expected,
        [Parameter(Mandatory = $true)][string]$Description
    )
    $full = Get-NormalizedWindowsPath $Path
    $expectedFull = Get-NormalizedWindowsPath $Expected
    Assert-NoReparseTraversal $full
    if (-not $full.Equals($expectedFull, [StringComparison]::OrdinalIgnoreCase)) {
        throw "Refusing to use an unexpected $Description path: $full"
    }

    $forbidden = @(
        [IO.Path]::GetPathRoot($full),
        $env:USERPROFILE,
        $script:DocumentsDir
    ) | Where-Object { -not [string]::IsNullOrWhiteSpace($_) }
    foreach ($blocked in $forbidden) {
        if (Test-SameWindowsPath $full $blocked) {
            throw "Refusing to use the drive, user-profile, or Documents root as $Description."
        }
    }

    if (Test-Path -LiteralPath $full) {
        $item = Get-Item -LiteralPath $full -Force -ErrorAction Stop
        if (-not $item.PSIsContainer) { throw "The $Description path is not a directory: $full" }
        if (($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
            throw "Refusing to use a reparse point, junction, or symbolic link as $Description`: $full"
        }
    }
    return $full
}

function ConvertTo-NormalizedRepositoryRemote {
    param([Parameter(Mandatory = $true)][string]$Remote)
    $value = $Remote.Trim().Replace("\", "/").TrimEnd("/")
    if ($value.EndsWith(".git", [StringComparison]::OrdinalIgnoreCase)) {
        $value = $value.Substring(0, $value.Length - 4)
    }
    $value = $value -replace '^https?://github[.]com/', ''
    $value = $value -replace '^ssh://git@github[.]com/', ''
    $value = $value -replace '^git@github[.]com:', ''
    return $value.ToLowerInvariant()
}

function Get-WorkspaceGitOutput {
    param(
        [Parameter(Mandatory = $true)][string]$Workspace,
        [Parameter(Mandatory = $true)][string[]]$Arguments
    )
    $allArguments = @("-C", $Workspace) + $Arguments
    return @(Invoke-Git @allArguments)
}

function Test-ExpectedEquicordProjectFiles {
    param([Parameter(Mandatory = $true)][string]$Workspace)
    foreach ($relative in @(".git", "package.json", "pnpm-lock.yaml", "scripts\runInstaller.mjs", "src")) {
        if (-not (Test-Path -LiteralPath (Join-Path $Workspace $relative))) { return $false }
        try { Assert-NoReparseTraversal (Join-Path $Workspace $relative) } catch { return $false }
    }
    return $true
}

function Test-ManagerConfigForWorkspace {
    param([Parameter(Mandatory = $true)][string]$Workspace)
    if (-not (Test-Path -LiteralPath $script:ConfigPath -PathType Leaf)) { return $false }
    try {
        Assert-NoReparseTraversal $script:ConfigPath
        $config = Get-Content -LiteralPath $script:ConfigPath -Raw -ErrorAction Stop | ConvertFrom-Json -ErrorAction Stop
        $versionProperty = $config.PSObject.Properties["version"]
        $selectionProperty = $config.PSObject.Properties["selectedPluginIds"]
        if (-not $versionProperty -or -not $selectionProperty) { return $false }
        $version = [int]$versionProperty.Value
        if ($version -lt 1 -or $version -gt $script:ConfigVersion) { return $false }
        $known = @{}
        foreach ($plugin in Get-BundledPlugins) { $known[[string]$plugin.Id] = $true }
        foreach ($id in @($selectionProperty.Value)) {
            if (-not $known.ContainsKey([string]$id)) { return $false }
        }
        $workspaceProperty = $config.PSObject.Properties["workspacePath"]
        if ($workspaceProperty -and -not (Test-SameWindowsPath ([string]$workspaceProperty.Value) $Workspace)) { return $false }
        return $true
    } catch { return $false }
}

function Test-WorkspaceOwnershipRecord {
    param([Parameter(Mandatory = $true)][string]$Workspace)
    if (-not (Test-Path -LiteralPath $script:OwnershipPath -PathType Leaf)) { return $false }
    try {
        Assert-NoReparseTraversal $script:OwnershipPath
        $record = Get-Content -LiteralPath $script:OwnershipPath -Raw -ErrorAction Stop | ConvertFrom-Json -ErrorAction Stop
        return [int]$record.schemaVersion -eq 1 -and
            [string]$record.managerId -ceq $script:ManagerId -and
            (Test-SameWindowsPath ([string]$record.workspacePath) $Workspace) -and
            (ConvertTo-NormalizedRepositoryRemote ([string]$record.remote)) -ceq
                (ConvertTo-NormalizedRepositoryRemote $script:RepoUrl)
    } catch { return $false }
}

function Get-WorkspaceOwnershipAssessment {
    param([string]$Workspace = $script:EquicordDir)
    $result = [ordered]@{
        Workspace = $Workspace
        Exists = $false
        PathValid = $false
        RepositoryValid = $false
        RemoteValid = $false
        ProjectFilesValid = $false
        ConfigValid = $false
        OwnershipRecordExists = (Test-Path -LiteralPath $script:OwnershipPath -PathType Leaf)
        OwnershipRecordValid = $false
        Clean = $false
        DirtyEntries = @()
        InstallerTrusted = $false
        LegacyEligible = $false
        CanDeleteWorkspace = $false
        CanUseInstaller = $false
        Reason = "Workspace is missing."
    }

    try {
        [void](Assert-ExactManagerDirectoryPath -Path $Workspace -Expected (Join-Path $script:DocumentsDir "Equicord") -Description "Equicord workspace")
        $result.PathValid = $true
    } catch {
        $result.Reason = $_.Exception.Message
        return [pscustomobject]$result
    }
    if (-not (Test-Path -LiteralPath $Workspace -PathType Container)) { return [pscustomobject]$result }
    $result.Exists = $true

    # A stopped cleanup may already have removed Git metadata. Only a previously
    # verified, hash-recorded deletion inventory can authorize the remaining files.
    if (Test-InterruptedWorkspaceCleanup $Workspace) {
        foreach ($key in @("RepositoryValid", "RemoteValid", "ProjectFilesValid", "ConfigValid", "OwnershipRecordValid", "Clean", "CanDeleteWorkspace")) { $result[$key] = $true }
        $result.Reason = "Remaining files match the verified pre-cleanup inventory; cleanup can resume."
        return [pscustomobject]$result
    }

    if (-not (Test-Path -LiteralPath (Join-Path $Workspace ".git") -PathType Container)) {
        $result.Reason = "The expected workspace is not a genuine Git repository."
        return [pscustomobject]$result
    }
    try {
        Assert-NoReparseTraversal (Join-Path $Workspace ".git")
        $top = [string](Get-WorkspaceGitOutput $Workspace @("rev-parse", "--show-toplevel") | Select-Object -First 1)
        if (-not (Test-SameWindowsPath $top $Workspace)) { throw "Unexpected Git worktree root." }
        $result.RepositoryValid = $true
    } catch { $result.Reason = "The workspace Git root could not be verified."; return [pscustomobject]$result }
    $result.ProjectFilesValid = Test-ExpectedEquicordProjectFiles -Workspace $Workspace
    if (-not $result.ProjectFilesValid) {
        $result.Reason = "The expected Equicord project files are incomplete."
        return [pscustomobject]$result
    }

    try {
        $remote = [string](Get-WorkspaceGitOutput -Workspace $Workspace -Arguments @("remote", "get-url", "origin") | Select-Object -First 1)
        $result.RemoteValid = (ConvertTo-NormalizedRepositoryRemote $remote) -ceq
            (ConvertTo-NormalizedRepositoryRemote $script:RepoUrl)
    } catch { $result.RemoteValid = $false }
    if (-not $result.RemoteValid) {
        $result.Reason = "The Equicord workspace origin is not the official Equicord repository."
        return [pscustomobject]$result
    }

    $result.ConfigValid = Test-ManagerConfigForWorkspace -Workspace $Workspace
    $result.OwnershipRecordValid = Test-WorkspaceOwnershipRecord -Workspace $Workspace
    try {
        $statusText = ((Get-WorkspaceGitOutput -Workspace $Workspace -Arguments @("status", "--porcelain=v1", "--untracked-files=all")) | Out-String).Trim()
        $result.DirtyEntries = @(if ($statusText) { $statusText -split "`r?`n" })
        # Git ignores userplugins. Check their actual bytes as well as ordinary Git status.
        $result.DirtyEntries += @(Get-UnexplainedWorkspaceFiles -Workspace $Workspace)
        $result.Clean = $result.DirtyEntries.Count -eq 0
    } catch {
        $result.Reason = "The Equicord workspace status could not be verified: $($_.Exception.Message)"
        return [pscustomobject]$result
    }

    try {
        [void](Get-WorkspaceGitOutput -Workspace $Workspace -Arguments @("ls-files", "--error-unmatch", "--", "scripts/runInstaller.mjs"))
        $runnerStatus = ((Get-WorkspaceGitOutput -Workspace $Workspace -Arguments @("status", "--porcelain=v1", "--", "scripts/runInstaller.mjs")) | Out-String).Trim()
        $result.InstallerTrusted = [string]::IsNullOrWhiteSpace($runnerStatus)
    } catch { $result.InstallerTrusted = $false }

    $result.LegacyEligible = -not $result.OwnershipRecordExists -and $result.ConfigValid -and $result.Clean
    $result.CanDeleteWorkspace = $result.Clean -and $result.ConfigValid -and ($result.OwnershipRecordValid -or $result.LegacyEligible)
    $result.CanUseInstaller = $result.RepositoryValid -and $result.RemoteValid -and
        $result.ProjectFilesValid -and $result.InstallerTrusted
    if (-not $result.Clean) {
        $result.Reason = "Local edits or untracked files were found, so the workspace will be preserved."
    } elseif ($result.OwnershipRecordValid) {
        $result.Reason = "The workspace has a valid manager ownership record and a clean worktree."
    } elseif ($result.LegacyEligible) {
        $result.Reason = "The clean legacy workspace is eligible for ownership migration after typed confirmation."
    } elseif ($result.OwnershipRecordExists) {
        $result.Reason = "The workspace ownership record is invalid and the workspace will be preserved."
    } else {
        $result.Reason = "The workspace has no valid ownership record or matching legacy configuration."
    }
    return [pscustomobject]$result
}

function Get-UnexplainedWorkspaceFiles {
    param([Parameter(Mandatory = $true)][string]$Workspace)
    $expected = @{}
    foreach ($plugin in Get-BundledPlugins) {
        foreach ($file in $plugin.Files.GetEnumerator()) {
            $expected["src/userplugins/$($plugin.FolderName)/$($file.Key)"] = [string]$file.Value
        }
    }
    # node_modules and dist are generated, including pnpm's links. They are removed
    # without following links. Everything else ignored by Git needs an explanation.
    $ignored = @(Get-WorkspaceGitOutput $Workspace @("-c", "core.quotePath=false", "ls-files", "--others", "--ignored", "--exclude-standard", "--", ".", ":!node_modules", ":!dist"))
    foreach ($relative in $ignored) {
        $relative = [string]$relative
        $path = Join-Path $Workspace $relative
        Assert-NoReparseTraversal $path
        if ($expected.ContainsKey($relative) -and (Test-Path -LiteralPath $path -PathType Leaf) -and
            [Convert]::ToBase64String([IO.File]::ReadAllBytes($path)) -ceq $expected[$relative]) { continue }
        "Ignored user content: $relative"
    }
    foreach ($entry in Get-ChildItem -LiteralPath $Workspace -Force) {
        if (($entry.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
            "Linked workspace entry: $($entry.Name)"
        }
    }
}

function Write-WorkspaceOwnershipRecord {
    param([Parameter(Mandatory = $true)][string]$MigrationReason)
    [void](Assert-ExactManagerDirectoryPath -Path $script:EquicordDir -Expected (Join-Path $script:DocumentsDir "Equicord") -Description "Equicord workspace")
    [void](Assert-ExactManagerDirectoryPath -Path $script:ConfigDir -Expected (Join-Path $env:LOCALAPPDATA "EquicordSetup") -Description "manager configuration")
    if (-not (Test-ExpectedEquicordProjectFiles -Workspace $script:EquicordDir)) {
        throw "Refusing to record ownership of an incomplete Equicord workspace."
    }
    $remote = [string](Get-WorkspaceGitOutput -Workspace $script:EquicordDir -Arguments @("remote", "get-url", "origin") | Select-Object -First 1)
    if ((ConvertTo-NormalizedRepositoryRemote $remote) -cne (ConvertTo-NormalizedRepositoryRemote $script:RepoUrl)) {
        throw "Refusing to record ownership for a workspace with an unexpected Git remote."
    }
    $status = ((Get-WorkspaceGitOutput -Workspace $script:EquicordDir -Arguments @("status", "--porcelain=v1", "--untracked-files=all")) | Out-String).Trim()
    if ($status) { throw "Refusing to record ownership while the Equicord worktree has local or untracked changes." }
    $record = [ordered]@{
        schemaVersion = 1
        managerId = $script:ManagerId
        workspacePath = Get-NormalizedWindowsPath $script:EquicordDir
        remote = $script:RepoUrl
        recordedAt = (Get-Date).ToString("o")
        reason = $MigrationReason
    }
    Write-Utf8FileAtomic -Path $script:OwnershipPath -Content ($record | ConvertTo-Json -Depth 4) | Out-Null
}

function Complete-LegacyWorkspaceOwnershipMigration {
    param([Parameter(Mandatory = $true)]$Assessment, [string]$ConfirmationText)
    if (-not (Test-RemovalConfirmationText $ConfirmationText) -or -not $Assessment.LegacyEligible -or -not $Assessment.Clean) {
        throw "The legacy Equicord workspace does not meet the ownership-migration requirements."
    }
    Write-WorkspaceOwnershipRecord -MigrationReason "confirmed-legacy-uninstall"
    $updated = Get-WorkspaceOwnershipAssessment
    if (-not $updated.OwnershipRecordValid -or -not $updated.CanDeleteWorkspace) {
        throw "The migrated workspace ownership record could not be validated."
    }
    return $updated
}

function Assert-ValidatedDiscordInstall {
    param([Parameter(Mandatory = $true)]$Install)
    $branch = [string]$Install.Branch
    $expectedName = switch ($branch) {
        "stable" { "Discord" }
        "ptb" { "DiscordPTB" }
        "canary" { "DiscordCanary" }
        default { throw "Unsupported recorded Discord branch: $branch" }
    }
    $expectedRoot = Join-Path $env:LOCALAPPDATA $expectedName
    if (-not (Test-SameWindowsPath ([string]$Install.Root) $expectedRoot)) {
        throw "The recorded Discord root does not match its branch: $($Install.Root)"
    }
    $root = Get-NormalizedWindowsPath ([string]$Install.Root)
    $appDirectory = Get-NormalizedWindowsPath ([string]$Install.AppDirectory)
    $resources = Get-NormalizedWindowsPath ([string]$Install.Resources)
    if (-not (Split-Path -Leaf $appDirectory).StartsWith("app-", [StringComparison]::OrdinalIgnoreCase) -or
        -not (Test-SameWindowsPath (Split-Path -Parent $appDirectory) $root) -or
        -not (Test-SameWindowsPath $resources (Join-Path $appDirectory "resources"))) {
        throw "The recorded Discord application path is not an exact supported installation layout."
    }
    foreach ($pair in @(
        @{ Path = $root; Label = "Discord root" },
        @{ Path = $appDirectory; Label = "Discord app directory" },
        @{ Path = $resources; Label = "Discord resources directory" }
    )) {
        Assert-NoReparseTraversal $pair.Path
        if (-not (Test-Path -LiteralPath $pair.Path -PathType Container)) { throw "$($pair.Label) is unavailable: $($pair.Path)" }
        $item = Get-Item -LiteralPath $pair.Path -Force -ErrorAction Stop
        if (($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
            throw "$($pair.Label) is a reparse point, junction, or symbolic link: $($pair.Path)"
        }
    }
    foreach ($name in @("app.asar", "_app.asar", "app.asar.tmp", "_app.asar.unpacked")) {
        Assert-NoReparseTraversal (Join-Path $resources $name)
    }
    return $true
}

function Test-UninstallOriginalAsar {
    param([Parameter(Mandatory = $true)][string]$Path)
    $stream = $null
    try {
        Assert-NoReparseTraversal $Path
        if (-not (Test-UsableAsarFile $Path)) { return $false }
        $stream = [IO.File]::OpenRead($Path)
        $prefix = New-Object byte[] 16
        if ($stream.Read($prefix, 0, 16) -ne 16 -or [BitConverter]::ToUInt32($prefix, 0) -ne 4) { return $false }
        $headerSize = [BitConverter]::ToUInt32($prefix, 4)
        $jsonSize = [BitConverter]::ToUInt32($prefix, 12)
        if ($jsonSize -lt 2 -or $jsonSize -gt 16777216 -or $headerSize -lt ($jsonSize + 8) -or
            ($headerSize + 8) -gt $stream.Length) { return $false }
        $bytes = New-Object byte[] $jsonSize
        if ($stream.Read($bytes, 0, $bytes.Length) -ne $bytes.Length) { return $false }
        $header = [Text.Encoding]::UTF8.GetString($bytes) | ConvertFrom-Json -ErrorAction Stop
        # The tiny two-file Equilotl loader is not an original Discord archive.
        return $null -ne $header.files.PSObject.Properties["package.json"] -and
            @($header.files.PSObject.Properties).Count -gt 2
    } catch { return $false } finally { if ($stream) { $stream.Dispose() } }
}

function Get-DiscordInjectionState {
    param([Parameter(Mandatory = $true)]$Install)
    [void](Assert-ValidatedDiscordInstall -Install $Install)
    $asar = Join-Path $Install.Resources "app.asar"
    $backup = Join-Path $Install.Resources "_app.asar"
    $backupExists = Test-Path -LiteralPath $backup
    $backupUsable = Test-UninstallOriginalAsar $backup
    $loaderActive = Test-EquicordLoaderAsar -Path $asar
    $originalUsable = Test-UninstallOriginalAsar $asar
    if (($loaderActive -or $backupExists) -and -not $backupUsable) {
        return [pscustomobject]@{ Kind = "corrupt"; Display = "incomplete injection with a missing or corrupt _app.asar backup"; NeedsUninstall = $false }
    }
    if ($backupUsable) {
        if (-not $loaderActive -and -not $originalUsable) {
            return [pscustomobject]@{ Kind = "corrupt"; Display = "unrecognized loader; another installation may own it"; NeedsUninstall = $false }
        }
        $originalPath = if ($loaderActive) { $backup } else { $asar }
        return [pscustomobject]@{ Kind = $(if ($loaderActive) { "injected" } else { "stale-backup" }); Display = $(if ($loaderActive) { "Equicord is injected" } else { "a stale injection backup is present" }); NeedsUninstall = $true; OriginalHash = (Get-FileHash -LiteralPath $originalPath -Algorithm SHA256).Hash }
    }
    if ($originalUsable -and -not $loaderActive) {
        return [pscustomobject]@{ Kind = "clean"; Display = "Discord already has its original app.asar"; NeedsUninstall = $false }
    }
    return [pscustomobject]@{ Kind = "corrupt"; Display = "Discord's app.asar state cannot be verified safely"; NeedsUninstall = $false }
}

function Test-DiscordRestoredAfterUninstall {
    param([Parameter(Mandatory = $true)]$Install)
    try { [void](Assert-ValidatedDiscordInstall -Install $Install) } catch { return $false }
    $asar = Join-Path $Install.Resources "app.asar"
    foreach ($leftover in @("_app.asar", "_app.asar.unpacked", "app.asar.tmp")) {
        if (Test-Path -LiteralPath (Join-Path $Install.Resources $leftover)) { return $false }
    }
    if (-not (Test-UninstallOriginalAsar $asar)) { return $false }
    return -not (Test-EquicordLoaderAsar -Path $asar)
}

function Select-DiscordInstallForRemoval {
    param(
        [AllowNull()]$Config,
        [AllowNull()][object[]]$Candidates,
        [scriptblock]$ChoiceProvider
    )
    if ($null -eq $Candidates) { $Candidates = @(Get-DiscordInstallCandidates) }
    $validated = @()
    foreach ($candidate in @($Candidates)) {
        try {
            [void](Assert-ValidatedDiscordInstall -Install $candidate)
            $validated += $candidate
        } catch { Write-Warn "Skipping an unsafe Discord candidate: $($_.Exception.Message)" }
    }

    $targetProperty = if ($Config) { $Config.PSObject.Properties["discordTarget"] } else { $null }
    if ($targetProperty) {
        $target = $targetProperty.Value
        $recorded = @($validated | Where-Object {
            [string]$_.Branch -ceq [string]$target.branch -and
                (Test-SameWindowsPath ([string]$_.Root) ([string]$target.root))
        })
        if ($recorded.Count -eq 1) {
            $recorded[0] | Add-Member -NotePropertyName SelectionSource -NotePropertyValue "recorded" -Force
            return $recorded[0]
        }
        Write-Warn "The Discord target recorded by this manager is unavailable."
    } else {
        Write-Warn "This legacy setup does not contain a recorded Discord target."
    }

    if ($validated.Count -eq 0) { throw "No validated Discord installation is available for removal." }
    Write-Info "Choose the exact Discord installation previously used by this manager. No other installation will be changed."
    for ($index = 0; $index -lt $validated.Count; $index++) {
        $state = Get-DiscordInjectionState -Install $validated[$index]
        Write-Host ("  [{0}] {1} | {2} | {3}" -f ($index + 1), $validated[$index].Name, $validated[$index].AppDirectory, $state.Display)
    }
    while ($true) {
        $choice = if ($ChoiceProvider) { & $ChoiceProvider } else { Read-ChoiceText }
        if ([string]$choice -match '^\d+$') {
            $selectedIndex = [int]$choice - 1
            if ($selectedIndex -ge 0 -and $selectedIndex -lt $validated.Count) {
                $validated[$selectedIndex] | Add-Member -NotePropertyName SelectionSource -NotePropertyValue "explicit" -Force
                return $validated[$selectedIndex]
            }
        }
        Write-Warn "Choose one of the exact validated Discord installations shown above."
    }
}

function Get-DiscordProcessesForInstall {
    param(
        [Parameter(Mandatory = $true)]$Install,
        [AllowNull()][object[]]$Processes
    )
    $processName = [string]$Install.ProcessName
    if ([string]::IsNullOrWhiteSpace($processName)) {
        $processName = switch ([string]$Install.Branch) {
            "stable" { "Discord" }
            "ptb" { "DiscordPTB" }
            "canary" { "DiscordCanary" }
            default { throw "Unsupported Discord branch for process management." }
        }
    }
    if (-not $PSBoundParameters.ContainsKey("Processes")) {
        $Processes = @(Get-Process -Name $processName -ErrorAction SilentlyContinue)
    }
    $root = (Get-NormalizedWindowsPath ([string]$Install.Root)).TrimEnd("\") + "\"
    return @($Processes | Where-Object {
        $candidateName = if ($_.PSObject.Properties["ProcessName"]) { [string]$_.ProcessName } else { [string]$_.Name }
        if (-not $candidateName.Equals($processName, [StringComparison]::OrdinalIgnoreCase)) { return $false }
        try {
            $processPath = Get-NormalizedWindowsPath ([string]$_.Path)
            return $processPath.StartsWith($root, [StringComparison]::OrdinalIgnoreCase)
        } catch { return $false }
    })
}

function Stop-SelectedDiscordForRemoval {
    param(
        [Parameter(Mandatory = $true)]$Install,
        [scriptblock]$ProcessProvider,
        [scriptblock]$Stopper,
        [scriptblock]$Delay,
        [ValidateRange(0, 15)][int]$TimeoutSeconds = 15
    )
    if (-not $ProcessProvider) { $ProcessProvider = { param($target) @(Get-DiscordProcessesForInstall -Install $target) } }
    if (-not $Stopper) { $Stopper = { param($process) Stop-Process -Id $process.Id -Force -ErrorAction Stop } }
    if (-not $Delay) { $Delay = { Start-Sleep -Milliseconds 250 } }
    $processes = @(& $ProcessProvider $Install)
    if ($processes.Count -eq 0) {
        return [pscustomobject]@{ WasRunning = $false; Stopped = $false; ExecutablePath = $null }
    }
    $executable = [string]$processes[0].Path
    foreach ($process in $processes) { & $Stopper $process }
    $deadline = (Get-Date).AddSeconds($TimeoutSeconds)
    while ((Get-Date) -lt $deadline) {
        if (@(& $ProcessProvider $Install).Count -eq 0) {
            return [pscustomobject]@{ WasRunning = $true; Stopped = $true; ExecutablePath = $executable }
        }
        & $Delay
    }
    throw "The selected $($Install.Name) processes did not exit within 15 seconds."
}

function Assert-NoUnrelatedDiscordProcess {
    param($Install, [AllowNull()][object[]]$Processes)
    if (-not $PSBoundParameters.ContainsKey("Processes")) {
        $Processes = @(Get-Process -Name $Install.ProcessName -ErrorAction SilentlyContinue)
    }
    # Equilotl itself uses a process name internally. Do not let it close another
    # installation with the same name, or a process whose executable is unreadable.
    if (@($Processes).Count -ne @(Get-DiscordProcessesForInstall $Install -Processes $Processes).Count) {
        throw "Another same-name Discord process could be affected by Equilotl. Close it yourself, then retry."
    }
}

function Restart-SelectedDiscordAfterRemoval {
    param(
        [Parameter(Mandatory = $true)]$Install,
        [Parameter(Mandatory = $true)]$ProcessState,
        [scriptblock]$Starter
    )
    if (-not $ProcessState.WasRunning -or -not $ProcessState.Stopped) { return $false }
    $root = Get-NormalizedWindowsPath ([string]$Install.Root)
    $processName = [string]$Install.ProcessName
    if (-not $processName) {
        $processName = switch ([string]$Install.Branch) { "stable" { "Discord" } "ptb" { "DiscordPTB" } "canary" { "DiscordCanary" } }
    }
    $updater = Join-Path $root "Update.exe"
    $captured = [string]$ProcessState.ExecutablePath
    if ($captured -and (Test-Path -LiteralPath $captured -PathType Leaf) -and
        (Get-NormalizedWindowsPath $captured).StartsWith($root.TrimEnd("\") + "\", [StringComparison]::OrdinalIgnoreCase)) {
        $filePath = $captured
        $arguments = @()
        $workingDirectory = Split-Path -Parent $captured
    } elseif (Test-Path -LiteralPath $updater -PathType Leaf) {
        $filePath = $updater
        $arguments = @("--processStart", "$processName.exe")
        $workingDirectory = $root
    } else {
        $filePath = Join-Path ([string]$Install.AppDirectory) "$processName.exe"
        if (-not (Test-Path -LiteralPath $filePath -PathType Leaf)) {
            throw "The selected Discord branch was running, but its exact executable can no longer be found."
        }
        $arguments = @()
        $workingDirectory = [string]$Install.AppDirectory
    }
    if ($Starter) { & $Starter $filePath $arguments $workingDirectory } elseif ($arguments.Count) {
        Start-Process -FilePath $filePath -ArgumentList $arguments -WorkingDirectory $workingDirectory
    } else {
        Start-Process -FilePath $filePath -WorkingDirectory $workingDirectory
    }
    return $true
}

function Read-UninstallState {
    if (-not (Test-Path -LiteralPath $script:UninstallStatePath -PathType Leaf)) { return $null }
    try {
        Assert-NoReparseTraversal $script:UninstallStatePath
        $state = Get-Content -LiteralPath $script:UninstallStatePath -Raw -ErrorAction Stop | ConvertFrom-Json -ErrorAction Stop
        if ($state.managerId -cne $script:ManagerId -or $state.schemaVersion -ne 1 -or
            -not (Test-SameWindowsPath $state.workspacePath $script:EquicordDir)) { return $null }
        return $state
    } catch { return $null }
}

function Write-UninstallState {
    param(
        [Parameter(Mandatory = $true)][ValidateSet("planned", "discord-stopped", "uninjection-started", "discord-restored", "cleanup-started", "cleanup-complete")][string]$Stage,
        [Parameter(Mandatory = $true)]$Install,
        [string]$Message = "",
        [AllowNull()]$ProcessState
    )
    [void](Assert-ExactManagerDirectoryPath -Path $script:ConfigDir -Expected (Join-Path $env:LOCALAPPDATA "EquicordSetup") -Description "manager configuration")
    $state = [ordered]@{
        schemaVersion = 1
        managerId = $script:ManagerId
        stage = $Stage
        updatedAt = (Get-Date).ToString("o")
        discordBranch = [string]$Install.Branch
        discordRoot = Get-NormalizedWindowsPath ([string]$Install.Root)
        workspacePath = Get-NormalizedWindowsPath $script:EquicordDir
        message = $Message
        processState = $ProcessState
    }
    Write-Utf8FileAtomic -Path $script:UninstallStatePath -Content ($state | ConvertTo-Json -Depth 4) | Out-Null
}

function Remove-ExactManagerDirectory {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][string]$Expected,
        [Parameter(Mandatory = $true)][string]$Description
    )
    $validated = Assert-ExactManagerDirectoryPath -Path $Path -Expected $Expected -Description $Description
    if (-not (Test-Path -LiteralPath $validated)) { return $false }
    # Never recurse through links, including pnpm's ordinary node_modules junctions.
    Remove-ManagerTreeWithoutFollowingLinks -Path $validated -Root $validated
    return $true
}

function Get-WorkspaceRemovalInventory {
    param([string]$Workspace)
    $pending = New-Object 'System.Collections.Generic.Queue[string]'
    $pending.Enqueue($Workspace)
    while ($pending.Count) {
        foreach ($item in Get-ChildItem -LiteralPath $pending.Dequeue() -Force -ErrorAction Stop) {
            $relative = $item.FullName.Substring($Workspace.Length + 1)
            if (($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
                [pscustomobject]@{ path=$relative; kind="link"; value=([string]($item.Target -join "|")) }
            } elseif ($item.PSIsContainer) {
                [pscustomobject]@{ path=$relative; kind="directory"; value="" }
                $pending.Enqueue($item.FullName)
            } else {
                [pscustomobject]@{ path=$relative; kind="file"; value=(Get-FileHash -LiteralPath $item.FullName -Algorithm SHA256 -ErrorAction Stop).Hash }
            }
        }
    }
}

function Test-InterruptedWorkspaceCleanup {
    param([string]$Workspace)
    $inventoryPath = Join-Path $script:ConfigDir "cleanup-files.json"
    if (-not (Test-Path -LiteralPath $inventoryPath -PathType Leaf)) { return $false }
    try {
        Assert-NoReparseTraversal $inventoryPath
        $state = Read-UninstallState
        if (-not $state -or $state.stage -notin @("cleanup-started", "cleanup-complete") -or
            -not (Test-WorkspaceOwnershipRecord $Workspace) -or -not (Test-ManagerConfigForWorkspace $Workspace)) { return $false }
        $record = Get-Content -LiteralPath $inventoryPath -Raw | ConvertFrom-Json
        if ($record.managerId -cne $script:ManagerId -or -not (Test-SameWindowsPath $record.workspacePath $Workspace) -or
            (ConvertTo-NormalizedRepositoryRemote $record.remote) -cne (ConvertTo-NormalizedRepositoryRemote $script:RepoUrl)) { return $false }
        $expected = @{}
        foreach ($entry in $record.files) { $expected[$entry.path] = $entry }
        foreach ($entry in @(Get-WorkspaceRemovalInventory $Workspace)) {
            if (-not $expected.ContainsKey($entry.path)) { return $false }
            $saved = $expected[$entry.path]
            if ($entry.kind -cne $saved.kind -or $entry.value -cne $saved.value) { return $false }
        }
        return $true
    } catch { return $false }
}

function Remove-ManagerTreeWithoutFollowingLinks {
    param([string]$Path, [string]$Root)
    $full = Get-NormalizedWindowsPath $Path
    if (-not (Test-SameWindowsPath $full $Root) -and
        -not $full.StartsWith($Root.TrimEnd("\") + "\", [StringComparison]::OrdinalIgnoreCase)) {
        throw "Removal escaped its validated manager root."
    }
    $item = Get-Item -LiteralPath $full -Force -ErrorAction Stop
    if (($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
        if ($item.PSIsContainer) { [IO.Directory]::Delete($full) } else { [IO.File]::Delete($full) }
    } elseif ($item.PSIsContainer) {
        foreach ($child in Get-ChildItem -LiteralPath $full -Force -ErrorAction Stop) {
            Remove-ManagerTreeWithoutFollowingLinks -Path $child.FullName -Root $Root
        }
        Remove-Item -LiteralPath $full -Force -ErrorAction Stop
    } else {
        Remove-Item -LiteralPath $full -Force -ErrorAction Stop
    }
}

function Assert-ManagerStateForRemoval {
    [void](Assert-ExactManagerDirectoryPath $script:ConfigDir (Join-Path $env:LOCALAPPDATA "EquicordSetup") "manager configuration")
    if (-not (Test-Path -LiteralPath $script:ConfigDir)) { return }
    if (-not (Test-ManagerConfigForWorkspace $script:EquicordDir)) {
        throw "Manager configuration ownership is not verified. State was preserved."
    }
    $known = @("config.json", "dependency-state.json", "workspace-owner.json", "uninstall-state.json", "cleanup-files.json", "logs", "backups", "cache", "temp")
    $pending = New-Object 'System.Collections.Generic.Queue[string]'
    $pending.Enqueue($script:ConfigDir)
    while ($pending.Count) {
        foreach ($item in Get-ChildItem -LiteralPath $pending.Dequeue() -Force -ErrorAction Stop) {
            Assert-NoReparseTraversal $item.FullName
            $top = $item.FullName.Substring($script:ConfigDir.Length + 1).Split('\')[0]
            if ($top -notin $known) { throw "Unrecognized manager-state content was preserved: $($item.FullName)" }
            if ($item.PSIsContainer) { $pending.Enqueue($item.FullName) }
        }
    }
}

function Invoke-ManagerOwnedCleanup {
    param(
        [Parameter(Mandatory = $true)]$WorkspaceAssessment,
        [scriptblock]$Remover,
        [scriptblock]$BeforeConfigRemoval
    )
    if (-not $Remover) {
        $Remover = {
            param($path, $expected, $description)
            Remove-ExactManagerDirectory -Path $path -Expected $expected -Description $description
        }
    }
    $workspaceRemoved = $false
    $workspacePreserved = $false
    # Re-check after uninjection, immediately before deleting anything.
    $WorkspaceAssessment = Get-WorkspaceOwnershipAssessment
    if (-not $WorkspaceAssessment.PathValid) { throw $WorkspaceAssessment.Reason }
    Assert-ManagerStateForRemoval
    if ($WorkspaceAssessment.Exists) {
        if ($WorkspaceAssessment.CanDeleteWorkspace) {
            try {
                if (-not (Test-InterruptedWorkspaceCleanup $script:EquicordDir)) {
                    $inventory = [ordered]@{
                        managerId = $script:ManagerId
                        workspacePath = $script:EquicordDir
                        remote = $script:RepoUrl
                        files = @(Get-WorkspaceRemovalInventory $script:EquicordDir)
                    }
                    Write-Utf8FileAtomic -Path (Join-Path $script:ConfigDir "cleanup-files.json") -Content ($inventory | ConvertTo-Json -Depth 6) | Out-Null
                }
                [void](& $Remover $script:EquicordDir (Join-Path $script:DocumentsDir "Equicord") "Equicord workspace")
                $workspaceRemoved = -not (Test-Path -LiteralPath $script:EquicordDir)
            } catch {
                return [pscustomobject]@{ Complete = $false; WorkspaceRemoved = $false; ConfigRemoved = $false; WorkspacePreserved = $true; Message = "Discord was restored, but the workspace could not be removed: $($_.Exception.Message)" }
            }
        } else {
            $workspacePreserved = $true
        }
    }
    if ($workspacePreserved) {
        return [pscustomobject]@{ Complete = $false; WorkspaceRemoved = $false; ConfigRemoved = $false; WorkspacePreserved = $true; Message = "Discord was restored. The workspace and ownership/recovery state were preserved because local, ignored, or untracked user content needs review. Resolve that content and retry full removal." }
    }
    if ($BeforeConfigRemoval) { & $BeforeConfigRemoval }
    try {
        $configRemoved = [bool](& $Remover $script:ConfigDir (Join-Path $env:LOCALAPPDATA "EquicordSetup") "manager configuration")
    } catch {
        return [pscustomobject]@{ Complete = $false; WorkspaceRemoved = $workspaceRemoved; ConfigRemoved = $false; WorkspacePreserved = $workspacePreserved; Message = "Discord was restored, but manager configuration cleanup failed: $($_.Exception.Message)" }
    }
    $complete = -not $workspacePreserved -and (-not $WorkspaceAssessment.Exists -or $workspaceRemoved) -and
        (-not (Test-Path -LiteralPath $script:ConfigDir))
    $message = if ($workspacePreserved) {
        "Discord was restored and manager state was removed, but the Equicord workspace was preserved because it contains potentially user-owned work or lacks verified ownership."
    } else {
        "Discord was restored and the verified manager-owned Windows files were removed."
    }
    return [pscustomobject]@{ Complete = $complete; WorkspaceRemoved = $workspaceRemoved; ConfigRemoved = $configRemoved; WorkspacePreserved = $workspacePreserved; Message = $message }
}

function Test-FullRemovalContextReady {
    param([Parameter(Mandatory = $true)]$Context, [switch]$WriteErrors)
    $failure = $null
    if (-not $Context.WorkspaceAssessment.PathValid) {
        $failure = $Context.WorkspaceAssessment.Reason
    } elseif ($Context.InjectionState.Kind -eq "corrupt") {
        $failure = "Discord cannot be restored safely because app.asar or _app.asar is missing or corrupt."
    } elseif ($Context.WorkspaceAssessment.Exists -and
        (-not $Context.WorkspaceAssessment.PathValid -or -not $Context.WorkspaceAssessment.RepositoryValid -or
            -not $Context.WorkspaceAssessment.RemoteValid -or -not $Context.WorkspaceAssessment.ProjectFilesValid)) {
        $failure = $Context.WorkspaceAssessment.Reason
    } elseif ($Context.InjectionState.NeedsUninstall -and -not $Context.WorkspaceAssessment.CanUseInstaller) {
        $failure = "The official Equicord installer wrapper cannot be trusted or is unavailable, so uninjection was not attempted."
    } elseif ($Context.WorkspaceAssessment.Exists -and -not $Context.WorkspaceAssessment.ConfigValid -and
        -not $Context.WorkspaceAssessment.OwnershipRecordValid) {
        $failure = "The workspace has neither a valid ownership record nor matching manager configuration."
    }
    if ($failure) {
        if ($WriteErrors) { Write-Err $failure }
        return $false
    }
    return $true
}

function Invoke-FullRemovalPlan {
    param(
        [Parameter(Mandatory = $true)]$Context,
        [scriptblock]$StageWriter,
        [scriptblock]$StopAction,
        [scriptblock]$UninstallAction,
        [scriptblock]$VerifyAction,
        [scriptblock]$CleanupAction,
        [scriptblock]$RestartAction
    )
    if (-not $StageWriter) { $StageWriter = { param($stage, $message) Write-UninstallState -Stage $stage -Install $Context.Install -Message $message -ProcessState $processState } }
    if (-not $StopAction) { $StopAction = { param($install) Stop-SelectedDiscordForRemoval -Install $install } }
    if (-not $UninstallAction) { $UninstallAction = { param($install) Invoke-EquicordInstallerAction -Action Uninstall -Install $install } }
    if (-not $VerifyAction) { $VerifyAction = { param($install) Test-DiscordRestoredAfterUninstall -Install $install } }
    if (-not $CleanupAction) {
        $CleanupAction = { param($assessment, $beforeConfig) Invoke-ManagerOwnedCleanup -WorkspaceAssessment $assessment -BeforeConfigRemoval $beforeConfig }
    }
    if (-not $RestartAction) { $RestartAction = { param($install, $processState) Restart-SelectedDiscordAfterRemoval -Install $install -ProcessState $processState } }

    $currentStage = "planned"
    $processState = [pscustomobject]@{ WasRunning = $false; Stopped = $false; ExecutablePath = $null }
    $previous = $Context.PreviousState
    if ($previous -and $previous.PSObject.Properties["processState"] -and $previous.processState -and
        (Test-SameWindowsPath $previous.discordRoot $Context.Install.Root) -and
        $previous.discordBranch -ceq $Context.Install.Branch) {
        $processState = $previous.processState
    }
    if ($Context.DiscordRunning -and $Context.InjectionState.NeedsUninstall) {
        $running = @(Get-DiscordProcessesForInstall $Context.Install)
        if ($running.Count) {
            $processState = [pscustomobject]@{ WasRunning = $true; Stopped = $true; ExecutablePath = [string]$running[0].Path }
        }
    }
    $status = "Failed"
    $message = "Removal did not complete."
    $cleanup = $null
    $restarted = $false
    $discordRestored = $false
    try {
        if (-not (Test-FullRemovalContextReady $Context)) { throw "Removal prerequisites failed; no changes were made." }
        & $StageWriter $currentStage "Full removal confirmed."
        if ($Context.InjectionState.NeedsUninstall) {
            $stoppedNow = & $StopAction $Context.Install
            if ($stoppedNow.WasRunning -or -not $processState.WasRunning) { $processState = $stoppedNow }
            $currentStage = "discord-stopped"
            & $StageWriter $currentStage "The selected Discord process is stopped or was not running."
            $currentStage = "uninjection-started"
            & $StageWriter $currentStage "Official Equilotl uninjection has started."
            & $UninstallAction $Context.Install
        }
        if (-not (& $VerifyAction $Context.Install)) {
            throw "Official uninjection did not restore a verified original app.asar or left an injection backup active."
        }
        $hashProperty = $Context.InjectionState.PSObject.Properties["OriginalHash"]
        if ($hashProperty -and (Get-FileHash -LiteralPath (Join-Path $Context.Install.Resources "app.asar") -Algorithm SHA256).Hash -cne $hashProperty.Value) {
            throw "Restored app.asar does not match the original archive recorded before uninjection."
        }
        $discordRestored = $true
        $currentStage = "discord-restored"
        & $StageWriter $currentStage "Discord's original app.asar is verified and the loader backup is inactive."
        $currentStage = "cleanup-started"
        & $StageWriter $currentStage "Manager-owned file cleanup has started."
        $beforeConfig = { & $StageWriter "cleanup-started" "Workspace cleanup finished; manager-state deletion is the last step." }
        $cleanup = & $CleanupAction $Context.WorkspaceAssessment $beforeConfig
        if ($cleanup.Complete) {
            $status = "Complete"
            # Successful cleanup removes the journal itself. Do not recreate it.
            $currentStage = "cleanup-complete"
        } else {
            $status = "Partial"
            & $StageWriter $currentStage ([string]$cleanup.Message)
        }
        $message = [string]$cleanup.Message
    } catch {
        if ($discordRestored) { $status = "Partial" }
        $message = $_.Exception.Message
        try { & $StageWriter $currentStage $message } catch {}
    } finally {
        if ($processState.WasRunning -and $processState.Stopped -and
            @(Get-DiscordProcessesForInstall $Context.Install).Count -eq 0) {
            try { $restarted = [bool](& $RestartAction $Context.Install $processState) } catch {
                $message += " The selected Discord branch could not be relaunched: $($_.Exception.Message)"
                if ($status -eq "Complete") { $status = "Partial" }
            }
        }
    }
    return [pscustomobject]@{
        Status = $status
        Message = $message
        Cleanup = $cleanup
        DiscordWasRunning = [bool]$processState.WasRunning
        DiscordRestarted = $restarted
        LastStage = $currentStage
    }
}

function Test-RemovalConfirmationText {
    param([AllowNull()][string]$Text)
    return $null -ne $Text -and $Text.Trim() -ceq "REMOVE"
}

function Show-FullRemovalPreview {
    param([Parameter(Mandatory = $true)]$Context)
    Write-Section "Removal Preview"
    Write-Host "  Discord branch:       $($Context.Install.Name)"
    Write-Host "  Discord installation: $($Context.Install.AppDirectory)"
    Write-Host "  Injection state:      $($Context.InjectionState.Display)"
    Write-Host "  Discord running:      $(if ($Context.DiscordRunning) { 'yes' } else { 'no' })"
    Write-Host "  Equicord workspace:   $script:EquicordDir"
    Write-Host "  Configuration/state:  $script:ConfigDir"
    Write-Host "  Ownership check:      $($Context.WorkspaceAssessment.Reason)"
    Write-Host "  Previous stage:       $(if ($Context.PreviousState) { $Context.PreviousState.stage } else { 'none' })"
    Write-Host ""
    Write-Host "  Manager-owned paths scheduled for deletion:" -ForegroundColor Yellow
    if ($Context.WorkspaceAssessment.CanDeleteWorkspace) { Write-Host "     - $script:EquicordDir" }
    Write-Host "     - $script:ConfigDir (configuration, dependency state, ownership, logs, backups, cache, and temporary state)"
    Write-Host ""
    Write-Host "  Always preserved:" -ForegroundColor Green
    Write-Host "     - Discord, account data, messages, and ordinary settings"
    Write-Host "     - Git, Node.js, npm, pnpm, Corepack, PowerShell, and system packages"
    Write-Host "     - Other Discord branches and unrelated Equicord or Vencord installations"
    Write-Host "     - This downloaded Equicord.bat launcher"
    if (-not $Context.WorkspaceAssessment.CanDeleteWorkspace -and $Context.WorkspaceAssessment.Exists) {
        Write-Host "     - The entire Equicord workspace, because ownership or worktree cleanliness is not fully verified" -ForegroundColor Yellow
    }
}

function Run-FullRemoval {
    Clear-Host
    Write-Header "Fully Remove My Equicord Setup"
    if (Test-IsAdministrator) { Write-Err "Close this and run it normally, not as Administrator."; Pause-Return; return }
    if (-not (Test-Path -LiteralPath $script:EquicordDir) -and -not (Test-Path -LiteralPath $script:ConfigDir)) {
        Write-Success "No manager-owned Windows setup remains. Nothing was changed."
        Write-Info "Delete the downloaded Equicord.bat manually if you no longer want the launcher."
        Pause-Return
        return
    }

    try {
        $config = Load-SetupConfig
        $install = Select-DiscordInstallForRemoval -Config $config
        $assessment = Get-WorkspaceOwnershipAssessment
        $injectionState = Get-DiscordInjectionState -Install $install
        $running = @(Get-DiscordProcessesForInstall -Install $install).Count -gt 0
        $context = [pscustomobject]@{
            Install = $install
            InjectionState = $injectionState
            WorkspaceAssessment = $assessment
            DiscordRunning = $running
            PreviousState = Read-UninstallState
        }
        Show-FullRemovalPreview -Context $context
        if (-not (Test-FullRemovalContextReady -Context $context -WriteErrors)) { Pause-Return; return }
        Assert-ManagerStateForRemoval
        Write-Host ""
        Write-Warn "This action restores only the selected Discord branch, then removes only verified manager-owned files."
        $typed = Read-Host "  Type REMOVE to continue"
        if (-not (Test-RemovalConfirmationText $typed)) {
            Write-Info "Full removal cancelled. Nothing was changed."
            Pause-Return
            return
        }
        if ($assessment.LegacyEligible) {
            $assessment = Complete-LegacyWorkspaceOwnershipMigration -Assessment $assessment -ConfirmationText $typed
            $context.WorkspaceAssessment = $assessment
        }
        Save-RecordedDiscordTarget -Install $install
        $result = Invoke-FullRemovalPlan -Context $context
        if ($result.Status -eq "Complete") {
            Write-Success $result.Message
        } elseif ($result.Status -eq "Partial") {
            Write-Warn "Partial cleanup: $($result.Message)"
            Write-Info "Run this option again after resolving the reported file or permission problem."
        } else {
            Write-Err $result.Message
            Write-Info "The workspace, configuration, injector, and recovery information were preserved so removal can be retried."
        }
        if ($result.DiscordWasRunning -and $result.DiscordRestarted) { Write-Success "The same Discord branch was relaunched." }
        Write-Info "Equicord.bat was not deleted. Delete the downloaded launcher manually if you no longer want it."
    } catch {
        Write-Err $_.Exception.Message
        Write-Info "No questionable manager path was deleted. Resolve the reported issue and retry."
    }
    Pause-Return
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
        Write-MenuItem "6" "Fully remove my Equicord setup"
        Write-MenuItem "7" "Exit"
        Write-Host $LINE -ForegroundColor Cyan

        switch (Get-KeyChoice) {
            "1" { Run-FullSetup }
            "2" { Run-ManagePlugins }
            "3" { Run-UpdateEquicord }
            "4" { Run-RepairReinject }
            "5" { Run-Diagnostics }
            "6" { Run-FullRemoval }
            "7" { Clear-Host; Write-Host ""; Write-Host "  Goodbye." -ForegroundColor Cyan; Write-Host ""; exit }
        }
    }
}

if ($env:EQUICORD_SETUP_VALIDATE_ONLY -eq "1") {
    Write-Output "EquicordSetup embedded PowerShell loaded successfully."
    exit 0
}
if ($env:EQUICORD_SETUP_LIBRARY_ONLY -ne "1") { Show-MainMenu }
#endregion
