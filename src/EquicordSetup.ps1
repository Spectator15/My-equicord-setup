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
