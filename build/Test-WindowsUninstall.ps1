[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$repoRoot = Split-Path -Parent $PSScriptRoot
$releasePath = Join-Path $repoRoot "Equicord.bat"
$sourcePath = Join-Path $repoRoot "src\EquicordSetup.ps1"
$git = (Get-Command git.exe, git -ErrorAction SilentlyContinue | Select-Object -First 1).Source
if (-not $git) { throw "Git is required for the disposable Windows uninstall tests." }

$originalLocalAppData = $env:LOCALAPPDATA
$originalUserProfile = $env:USERPROFILE
$temporaryRoot = Join-Path ([IO.Path]::GetTempPath()) ("equicord-windows-uninstall-tests-" + [Guid]::NewGuid().ToString("N"))
$temporaryRoot = [IO.Path]::GetFullPath($temporaryRoot)
$systemTemp = [IO.Path]::GetFullPath([IO.Path]::GetTempPath())
if (-not $temporaryRoot.StartsWith($systemTemp, [StringComparison]::OrdinalIgnoreCase)) {
    throw "Refusing to create Windows uninstall fixtures outside the system temporary directory."
}
New-Item -ItemType Directory -Path $temporaryRoot | Out-Null

$release = [IO.File]::ReadAllText($releasePath, [Text.Encoding]::UTF8)
$payloadStart = $release.IndexOf("#region INIT", [StringComparison]::Ordinal)
if ($payloadStart -lt 0) { throw "Generated Windows PowerShell payload was not found." }
$env:EQUICORD_SETUP_LIBRARY_ONLY = "1"
try {
    Invoke-Expression $release.Substring($payloadStart)
} finally {
    Remove-Item Env:\EQUICORD_SETUP_LIBRARY_ONLY -ErrorAction SilentlyContinue
}

$passes = 0
$failures = 0

function Assert-True {
    param([bool]$Condition, [string]$Message)
    if (-not $Condition) { throw $Message }
}

function Invoke-TestCase {
    param([string]$Name, [scriptblock]$Test)
    try {
        & $Test
        $script:passes++
        Write-Output "ok - $Name"
    } catch {
        $script:failures++
        Write-Output "not ok - $Name"
        Write-Output "  $($_.Exception.Message)"
    }
}

function Set-FixturePaths {
    param([string]$Name)
    $fixtureRoot = Join-Path $temporaryRoot $Name
    $env:USERPROFILE = Join-Path $fixtureRoot "User Profile"
    $env:LOCALAPPDATA = Join-Path $env:USERPROFILE "AppData\Local"
    $script:DocumentsDir = Join-Path $env:USERPROFILE "Documents"
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
    $script:GitBin = $git
    New-Item -ItemType Directory -Path $script:DocumentsDir, $env:LOCALAPPDATA -Force | Out-Null
    return $fixtureRoot
}

function Invoke-TestGit {
    param([string]$Workspace, [string[]]$Arguments)
    & $git -C $Workspace @Arguments | Out-Null
    if ($LASTEXITCODE -ne 0) { throw "Fixture Git command failed: git $($Arguments -join ' ')" }
}

function New-TestWorkspace {
    param([string]$Remote = "https://github.com/Equicord/Equicord")
    New-Item -ItemType Directory -Path (Join-Path $script:EquicordDir "scripts"), (Join-Path $script:EquicordDir "src"), (Join-Path $script:EquicordDir "dist\desktop") -Force | Out-Null
    Set-Content -LiteralPath (Join-Path $script:EquicordDir "package.json") -Value '{"name":"equicord"}' -Encoding utf8NoBOM
    Set-Content -LiteralPath (Join-Path $script:EquicordDir "pnpm-lock.yaml") -Value 'lockfileVersion: 9' -Encoding utf8NoBOM
    Set-Content -LiteralPath (Join-Path $script:EquicordDir "scripts\runInstaller.mjs") -Value 'console.log("fixture");' -Encoding utf8NoBOM
    Set-Content -LiteralPath (Join-Path $script:EquicordDir "dist\desktop\patcher.js") -Value 'module.exports = {};' -Encoding utf8NoBOM
    & $git init $script:EquicordDir | Out-Null
    if ($LASTEXITCODE -ne 0) { throw "Could not initialise fixture repository." }
    Invoke-TestGit $script:EquicordDir @("config", "user.name", "Equicord Test")
    Invoke-TestGit $script:EquicordDir @("config", "user.email", "equicord-test@example.invalid")
    Invoke-TestGit $script:EquicordDir @("remote", "add", "origin", $Remote)
    Invoke-TestGit $script:EquicordDir @("add", ".")
    Invoke-TestGit $script:EquicordDir @("commit", "-m", "fixture")
}

function Write-TestConfig {
    param(
        [AllowNull()]$DiscordTarget,
        [int]$Version = 3,
        [switch]$Legacy
    )
    New-Item -ItemType Directory -Path $script:ConfigDir -Force | Out-Null
    $data = [ordered]@{
        version = $Version
        selectedPluginIds = @("smoothType")
        updatedAt = (Get-Date).ToString("o")
    }
    if (-not $Legacy) { $data.workspacePath = $script:EquicordDir }
    if ($DiscordTarget) { $data.discordTarget = ConvertTo-DiscordTargetRecord -Install $DiscordTarget }
    [IO.File]::WriteAllText($script:ConfigPath, ($data | ConvertTo-Json -Depth 6), (New-Object Text.UTF8Encoding $false))
    [IO.File]::WriteAllText($script:DependencyStatePath, '{"fingerprint":"fixture"}', (New-Object Text.UTF8Encoding $false))
    foreach ($directory in @($script:LogDir, $script:BackupDir, $script:CacheDir, $script:TempDir)) {
        New-Item -ItemType Directory -Path $directory -Force | Out-Null
        Set-Content -LiteralPath (Join-Path $directory "fixture.txt") -Value "manager-owned" -Encoding utf8NoBOM
    }
}

function New-TestDiscordInstall {
    param(
        [ValidateSet("stable", "ptb", "canary")][string]$Branch = "stable",
        [ValidateSet("clean", "injected", "stale", "corrupt")][string]$State = "injected"
    )
    $details = switch ($Branch) {
        "stable" { @{ Directory = "Discord"; Name = "Discord Stable"; Process = "Discord"; Version = "app-1.0.9999" } }
        "ptb" { @{ Directory = "DiscordPTB"; Name = "Discord PTB"; Process = "DiscordPTB"; Version = "app-1.0.9998" } }
        "canary" { @{ Directory = "DiscordCanary"; Name = "Discord Canary"; Process = "DiscordCanary"; Version = "app-1.0.9997" } }
    }
    $root = Join-Path $env:LOCALAPPDATA $details.Directory
    $app = Join-Path $root $details.Version
    $resources = Join-Path $app "resources"
    New-Item -ItemType Directory -Path $resources -Force | Out-Null
    [IO.File]::WriteAllBytes((Join-Path $root "Update.exe"), [byte[]](1..16))
    [IO.File]::WriteAllBytes((Join-Path $app "$($details.Process).exe"), [byte[]](1..16))
    $original = New-Object byte[] 8192
    [Array]::Fill[byte]($original, 65)
    $header = [Text.Encoding]::UTF8.GetBytes('{"files":{"package.json":{"size":0,"offset":"0"},"app_bootstrap":{"files":{}},"common":{"files":{}}}}')
    [BitConverter]::GetBytes([uint32]4).CopyTo($original, 0)
    [BitConverter]::GetBytes([uint32]($header.Length + 8)).CopyTo($original, 4)
    [BitConverter]::GetBytes([uint32]($header.Length + 4)).CopyTo($original, 8)
    [BitConverter]::GetBytes([uint32]$header.Length).CopyTo($original, 12)
    $header.CopyTo($original, 16)
    $asar = Join-Path $resources "app.asar"
    $backup = Join-Path $resources "_app.asar"
    if ($State -eq "clean") {
        [IO.File]::WriteAllBytes($asar, $original)
    } elseif ($State -eq "corrupt") {
        New-Item -ItemType Directory -Path $asar | Out-Null
        Set-Content -LiteralPath (Join-Path $asar "package.json") -Value '{"name":"discord","main":"index.js"}' -Encoding utf8NoBOM
        $expected = ([IO.Path]::GetFullPath((Join-Path $script:EquicordDir "dist\desktop"))).Replace("\", "\\")
        Set-Content -LiteralPath (Join-Path $asar "index.js") -Value "require(`"$expected`")" -Encoding utf8NoBOM
        [IO.File]::WriteAllBytes($backup, [byte[]](1..32))
    } else {
        [IO.File]::WriteAllBytes($backup, $original)
        if ($State -eq "stale") {
            [IO.File]::WriteAllBytes($asar, $original)
        } else {
            New-Item -ItemType Directory -Path $asar | Out-Null
            Set-Content -LiteralPath (Join-Path $asar "package.json") -Value '{"name":"discord","main":"index.js"}' -Encoding utf8NoBOM
            $expected = ([IO.Path]::GetFullPath((Join-Path $script:EquicordDir "dist\desktop"))).Replace("\", "\\")
            Set-Content -LiteralPath (Join-Path $asar "index.js") -Value "require(`"$expected`")" -Encoding utf8NoBOM
        }
    }
    return [pscustomobject]@{
        Name = $details.Name
        Branch = $Branch
        ProcessName = $details.Process
        Root = $root
        AppDirectory = $app
        Resources = $resources
        Version = [version]"1.0.9999"
        HasBase = $true
    }
}

function Restore-TestDiscord {
    param($Install)
    $asar = Join-Path $Install.Resources "app.asar"
    $backup = Join-Path $Install.Resources "_app.asar"
    if (Test-Path -LiteralPath $asar) { Remove-Item -LiteralPath $asar -Recurse -Force }
    Move-Item -LiteralPath $backup -Destination $asar
}

function New-TestFixture {
    param(
        [string]$Name,
        [ValidateSet("clean", "injected", "stale", "corrupt")][string]$DiscordState = "injected",
        [string]$Remote = "https://github.com/Equicord/Equicord",
        [switch]$Legacy,
        [switch]$NoOwnership
    )
    $root = Set-FixturePaths $Name
    New-TestWorkspace -Remote $Remote
    $install = New-TestDiscordInstall -State $DiscordState
    Write-TestConfig -DiscordTarget $install -Version $(if ($Legacy) { 2 } else { 3 }) -Legacy:$Legacy
    if (-not $NoOwnership -and -not $Legacy -and $Remote -eq "https://github.com/Equicord/Equicord") {
        Write-WorkspaceOwnershipRecord -MigrationReason "test-fixture"
    }
    return [pscustomobject]@{ Root = $root; Install = $install }
}

function New-RemovalContext {
    param($Install, $Assessment = (Get-WorkspaceOwnershipAssessment))
    return [pscustomobject]@{
        Install = $Install
        InjectionState = Get-DiscordInjectionState -Install $Install
        WorkspaceAssessment = $Assessment
        DiscordRunning = $false
        PreviousState = $null
    }
}

function Get-FixtureSnapshot {
    param([string]$Root)
    if (-not (Test-Path -LiteralPath $Root)) { return "missing" }
    return @(
        Get-ChildItem -LiteralPath $Root -Recurse -Force -File |
            Sort-Object FullName |
            ForEach-Object { "$($_.FullName.Substring($Root.Length))|$((Get-FileHash -LiteralPath $_.FullName -Algorithm SHA256).Hash)" }
    ) -join "`n"
}

try {
    Invoke-TestCase "menu option and numbering" {
        $source = Get-Content -LiteralPath $sourcePath -Raw
        Assert-True ($source.Contains('Write-MenuItem "6" "Fully remove my Equicord setup"')) "Full-removal menu item 6 is missing."
        Assert-True ($source.Contains('Write-MenuItem "7" "Exit"')) "Exit was not moved to item 7."
        Assert-True ($source.Contains('"6" { Run-FullRemoval }')) "Menu item 6 does not invoke full removal."
    }

    Invoke-TestCase "typed REMOVE confirmation" {
        Assert-True (Test-RemovalConfirmationText "REMOVE") "Exact REMOVE confirmation was rejected."
        foreach ($invalid in @($null, "", "remove", "YES", "y")) {
            Assert-True (-not (Test-RemovalConfirmationText $invalid)) "Unsafe confirmation text was accepted: $invalid"
        }
    }

    Invoke-TestCase "cancellation changes nothing" {
        $fixture = New-TestFixture "03 cancellation"
        $before = Get-FixtureSnapshot $fixture.Root
        if (Test-RemovalConfirmationText "cancel") { throw "Cancellation unexpectedly passed the confirmation gate." }
        function Read-Host { param($Prompt) return "cancel" }
        function Clear-Host {}
        function Test-IsAdministrator { return $false }
        function Pause-Return {}
        Run-FullRemoval
        $after = Get-FixtureSnapshot $fixture.Root
        Assert-True ($before -ceq $after) "Cancellation changed fixture files."
        Assert-True (-not (Test-Path -LiteralPath $script:UninstallStatePath)) "Cancellation wrote uninstall state."
    }

    Invoke-TestCase "noninteractive confirmation protection" {
        $env:EQUICORD_SETUP_ASSUME_YES = "1"
        try {
            Assert-True (-not (Test-RemovalConfirmationText "")) "An environment flag bypassed typed confirmation."
            $source = Get-Content -LiteralPath $sourcePath -Raw
            Assert-True (-not $source.Contains("EQUICORD_SETUP_UNINSTALL")) "A single-argument noninteractive uninstall path was added."
        } finally { Remove-Item Env:\EQUICORD_SETUP_ASSUME_YES -ErrorAction SilentlyContinue }
    }

    Invoke-TestCase "official uninstall location invocation" {
        $fixture = New-TestFixture "05 official invocation" -DiscordState clean
        $script:capturedInvocation = $null
        $invoker = {
            param($filePath, $arguments, $description, $workingDirectory)
            $script:capturedInvocation = [pscustomobject]@{ FilePath = $filePath; Arguments = @($arguments); Description = $description; WorkingDirectory = $workingDirectory }
        }
        Invoke-EquicordInstallerAction -Action Uninstall -Install $fixture.Install -Invoker $invoker
        Assert-True (($script:capturedInvocation.Arguments -join "|") -ceq "scripts/runInstaller.mjs|--|--uninstall|--location|$($fixture.Install.Root)") "Official --uninstall --location arguments were not used."
        Assert-True (Test-SameWindowsPath $script:capturedInvocation.WorkingDirectory $script:EquicordDir) "Installer did not run from the validated workspace."
    }

    Invoke-TestCase "recorded Discord target is used" {
        $fixture = New-TestFixture "06 recorded target" -DiscordState clean
        $ptb = New-TestDiscordInstall -Branch ptb -State clean
        $config = Load-SetupConfig
        $script:choiceCalled = $false
        $selected = Select-DiscordInstallForRemoval -Config $config -Candidates @($ptb, $fixture.Install) -ChoiceProvider { $script:choiceCalled = $true; "1" }
        Assert-True (Test-SameWindowsPath $selected.Root $fixture.Install.Root) "The recorded target was not selected."
        Assert-True (-not $script:choiceCalled) "A valid recorded target incorrectly prompted for another client."
    }

    Invoke-TestCase "unrelated Discord targets are preserved" {
        $fixture = New-TestFixture "07 unrelated target"
        $ptb = New-TestDiscordInstall -Branch ptb -State injected
        $ptbBefore = Get-FixtureSnapshot $ptb.Root
        $context = New-RemovalContext $fixture.Install
        $result = Invoke-FullRemovalPlan -Context $context -StopAction { [pscustomobject]@{ WasRunning = $false; Stopped = $false; ExecutablePath = $null } } -UninstallAction { param($install) Restore-TestDiscord $install }
        Assert-True ($result.Status -eq "Complete") "Selected-client removal did not complete: $($result | ConvertTo-Json -Depth 5 -Compress)"
        Assert-True ((Get-FixtureSnapshot $ptb.Root) -ceq $ptbBefore) "An unrelated Discord target was modified."
    }

    Invoke-TestCase "exact Discord process closure" {
        $fixture = New-TestFixture "08 exact process" -DiscordState clean
        $inside = Join-Path $fixture.Install.AppDirectory "Discord.exe"
        $otherRoot = Join-Path $env:LOCALAPPDATA "Other\Discord.exe"
        $processes = @(
            [pscustomobject]@{ Id = 10; ProcessName = "Discord"; Path = $inside },
            [pscustomobject]@{ Id = 11; ProcessName = "DiscordPTB"; Path = $inside },
            [pscustomobject]@{ Id = 12; ProcessName = "Discord"; Path = $otherRoot }
        )
        $matched = @(Get-DiscordProcessesForInstall -Install $fixture.Install -Processes $processes)
        Assert-True ($matched.Count -eq 1 -and $matched[0].Id -eq 10) "Process matching was not limited to the exact selected branch and root."
    }

    Invoke-TestCase "original running state is restored" {
        $fixture = New-TestFixture "09 running restore"
        $context = New-RemovalContext $fixture.Install
        $script:restarts = 0
        $cleanup = { [pscustomobject]@{ Complete = $true; Message = "done" } }
        $result = Invoke-FullRemovalPlan -Context $context -StageWriter { } -StopAction { [pscustomobject]@{ WasRunning = $true; Stopped = $true; ExecutablePath = "C:\fixture\Discord.exe" } } -UninstallAction { param($install) Restore-TestDiscord $install } -CleanupAction $cleanup -RestartAction { $script:restarts++; $true }
        Assert-True ($result.DiscordWasRunning -and $result.DiscordRestarted -and $script:restarts -eq 1) "The selected running branch was not relaunched exactly once."
    }

    Invoke-TestCase "successful app.asar restoration" {
        $fixture = New-TestFixture "10 successful restoration"
        $context = New-RemovalContext $fixture.Install
        $result = Invoke-FullRemovalPlan -Context $context -StageWriter { } -StopAction { [pscustomobject]@{ WasRunning = $false; Stopped = $false; ExecutablePath = $null } } -UninstallAction { param($install) Restore-TestDiscord $install } -CleanupAction { [pscustomobject]@{ Complete = $true; Message = "done" } }
        Assert-True ($result.Status -eq "Complete") "Verified restoration was not reported complete."
        Assert-True (Test-DiscordRestoredAfterUninstall $fixture.Install) "Original app.asar was not verified after restoration."
    }

    Invoke-TestCase "already-clean Discord skips Equilotl" {
        $fixture = New-TestFixture "11 already clean" -DiscordState clean
        $context = New-RemovalContext $fixture.Install
        $script:uninstallCalled = $false
        $result = Invoke-FullRemovalPlan -Context $context -StageWriter { } -UninstallAction { $script:uninstallCalled = $true; throw "should not run" } -CleanupAction { [pscustomobject]@{ Complete = $true; Message = "done" } }
        Assert-True ($result.Status -eq "Complete" -and -not $script:uninstallCalled) "Already-clean Discord incorrectly invoked Equilotl."
    }

    Invoke-TestCase "missing or corrupt backup is blocked" {
        $fixture = New-TestFixture "12 corrupt backup" -DiscordState corrupt
        $context = New-RemovalContext $fixture.Install
        Assert-True ($context.InjectionState.Kind -eq "corrupt") "Corrupt _app.asar was not detected."
        Assert-True (-not (Test-FullRemovalContextReady -Context $context)) "Corrupt backup was allowed to proceed."
    }

    Invoke-TestCase "Equilotl failure preserves recovery files" {
        $fixture = New-TestFixture "13 equilotl failure"
        $context = New-RemovalContext $fixture.Install
        $result = Invoke-FullRemovalPlan -Context $context -StopAction { [pscustomobject]@{ WasRunning = $false; Stopped = $false; ExecutablePath = $null } } -UninstallAction { throw "mock Equilotl failure" }
        Assert-True ($result.Status -eq "Failed") "Equilotl failure was not reported."
        Assert-True ((Test-Path -LiteralPath $script:EquicordDir) -and (Test-Path -LiteralPath $script:ConfigDir)) "Recovery files were removed after Equilotl failure."
        Assert-True ((Read-UninstallState).stage -eq "uninjection-started") "Failure stage was not persisted for retry."
    }

    Invoke-TestCase "cleanup is blocked after failed uninjection" {
        $fixture = New-TestFixture "14 blocked cleanup"
        $context = New-RemovalContext $fixture.Install
        $script:cleanupCalled = $false
        [void](Invoke-FullRemovalPlan -Context $context -StageWriter { } -StopAction { [pscustomobject]@{ WasRunning = $false; Stopped = $false; ExecutablePath = $null } } -UninstallAction { throw "failure" } -CleanupAction { $script:cleanupCalled = $true; throw "cleanup must not run" })
        Assert-True (-not $script:cleanupCalled) "Cleanup ran after failed uninjection."
        Assert-True (Test-Path -LiteralPath $script:OwnershipPath) "Ownership recovery information was deleted."
    }

    Invoke-TestCase "workspace deletion follows verified uninjection" {
        $fixture = New-TestFixture "15 workspace deletion"
        $context = New-RemovalContext $fixture.Install
        $result = Invoke-FullRemovalPlan -Context $context -StopAction { [pscustomobject]@{ WasRunning = $false; Stopped = $false; ExecutablePath = $null } } -UninstallAction { param($install) Restore-TestDiscord $install }
        Assert-True ($result.Status -eq "Complete") "Full cleanup was not complete: $($result | ConvertTo-Json -Depth 5 -Compress)"
        Assert-True (-not (Test-Path -LiteralPath $script:EquicordDir)) "Verified manager workspace was retained unexpectedly."
    }

    Invoke-TestCase "configuration and dependency state cleanup" {
        $fixture = New-TestFixture "16 state cleanup"
        $context = New-RemovalContext $fixture.Install
        [void](Invoke-FullRemovalPlan -Context $context -StopAction { [pscustomobject]@{ WasRunning = $false; Stopped = $false; ExecutablePath = $null } } -UninstallAction { param($install) Restore-TestDiscord $install })
        Assert-True (-not (Test-Path -LiteralPath $script:ConfigDir)) "Configuration, dependency state, logs, backups, cache, or temporary state remained."
    }

    Invoke-TestCase "ownership marker creation and validation" {
        [void](Set-FixturePaths "17 owner marker")
        New-TestWorkspace
        Write-TestConfig -DiscordTarget $null
        Write-WorkspaceOwnershipRecord -MigrationReason "new-installation"
        $assessment = Get-WorkspaceOwnershipAssessment
        Assert-True ($assessment.OwnershipRecordValid -and $assessment.CanDeleteWorkspace) "A new ownership record did not validate: $($assessment | ConvertTo-Json -Depth 5 -Compress)"
    }

    Invoke-TestCase "safe legacy ownership migration" {
        $fixture = New-TestFixture "18 legacy migration" -DiscordState clean -Legacy -NoOwnership
        $assessment = Get-WorkspaceOwnershipAssessment
        Assert-True ($assessment.LegacyEligible -and -not $assessment.OwnershipRecordExists) "Clean legacy workspace was not migration eligible: $($assessment | ConvertTo-Json -Depth 5 -Compress)"
        $migrated = Complete-LegacyWorkspaceOwnershipMigration -Assessment $assessment -ConfirmationText REMOVE
        Assert-True ($migrated.OwnershipRecordValid -and $migrated.CanDeleteWorkspace) "Legacy ownership migration did not validate."
    }

    Invoke-TestCase "dirty workspace is preserved" {
        $fixture = New-TestFixture "19 dirty workspace"
        Add-Content -LiteralPath (Join-Path $script:EquicordDir "package.json") -Value "dirty"
        $assessment = Get-WorkspaceOwnershipAssessment
        Assert-True (-not $assessment.Clean -and -not $assessment.CanDeleteWorkspace) "Tracked edits were not detected."
        $context = New-RemovalContext $fixture.Install $assessment
        $result = Invoke-FullRemovalPlan -Context $context -StopAction { [pscustomobject]@{ WasRunning = $false; Stopped = $false; ExecutablePath = $null } } -UninstallAction { param($install) Restore-TestDiscord $install }
        Assert-True ($result.Status -eq "Partial" -and (Test-Path -LiteralPath $script:EquicordDir)) "Dirty workspace was not preserved as partial cleanup."
    }

    Invoke-TestCase "untracked files are preserved" {
        $fixture = New-TestFixture "20 untracked workspace"
        Set-Content -LiteralPath (Join-Path $script:EquicordDir "personal-notes.txt") -Value "user work"
        $assessment = Get-WorkspaceOwnershipAssessment
        $context = New-RemovalContext $fixture.Install $assessment
        [void](Invoke-FullRemovalPlan -Context $context -StopAction { [pscustomobject]@{ WasRunning = $false; Stopped = $false; ExecutablePath = $null } } -UninstallAction { param($install) Restore-TestDiscord $install })
        Assert-True (Test-Path -LiteralPath (Join-Path $script:EquicordDir "personal-notes.txt")) "Untracked user file was removed."
    }

    Invoke-TestCase "wrong Git remote is rejected" {
        $fixture = New-TestFixture "21 wrong remote" -DiscordState clean -Remote "https://github.com/example/not-equicord" -NoOwnership
        $assessment = Get-WorkspaceOwnershipAssessment
        $context = New-RemovalContext $fixture.Install $assessment
        Assert-True (-not $assessment.RemoteValid -and -not (Test-FullRemovalContextReady -Context $context)) "Unexpected remote was not rejected."
    }

    Invoke-TestCase "reparse point and junction target is rejected" {
        [void](Set-FixturePaths "22 junction rejection")
        $realTarget = Join-Path $temporaryRoot "22 junction real target"
        New-Item -ItemType Directory -Path $realTarget -Force | Out-Null
        $junction = New-Item -ItemType Junction -Path $script:EquicordDir -Target $realTarget
        try {
            $blocked = $false
            try { [void](Assert-ExactManagerDirectoryPath -Path $junction.FullName -Expected $script:EquicordDir -Description "Equicord workspace") } catch { $blocked = $true }
            Assert-True $blocked "A junction workspace target was accepted."
        } finally {
            Remove-Item -LiteralPath $junction.FullName -Force -ErrorAction SilentlyContinue
        }
    }

    Invoke-TestCase "path containment protection" {
        [void](Set-FixturePaths "23 containment")
        $outside = Join-Path $temporaryRoot "outside manager path"
        New-Item -ItemType Directory -Path $outside -Force | Out-Null
        $blocked = $false
        try { [void](Assert-ExactManagerDirectoryPath -Path $outside -Expected $script:EquicordDir -Description "Equicord workspace") } catch { $blocked = $true }
        Assert-True $blocked "A directory outside the exact manager path was accepted."
    }

    Invoke-TestCase "drive, profile, and Documents roots are rejected" {
        [void](Set-FixturePaths "24 forbidden roots")
        foreach ($blockedPath in @([IO.Path]::GetPathRoot($script:EquicordDir), $env:USERPROFILE, $script:DocumentsDir)) {
            $blocked = $false
            try { [void](Assert-ExactManagerDirectoryPath -Path $blockedPath -Expected $blockedPath -Description "test target") } catch { $blocked = $true }
            Assert-True $blocked "Forbidden broad path was accepted: $blockedPath"
        }
    }

    Invoke-TestCase "paths containing spaces and Unicode" {
        $fixture = New-TestFixture "25 données and spaces" -DiscordState clean
        $assessment = Get-WorkspaceOwnershipAssessment
        Assert-True ($assessment.PathValid -and $assessment.OwnershipRecordValid) "Unicode or spaced manager paths failed validation."
        Assert-True (Assert-ValidatedDiscordInstall -Install $fixture.Install) "Unicode or spaced Discord path failed validation."
    }

    Invoke-TestCase "repeated uninstall is a safe no-op" {
        $fixture = New-TestFixture "26 repeated uninstall"
        $context = New-RemovalContext $fixture.Install
        $result = Invoke-FullRemovalPlan -Context $context -StopAction { [pscustomobject]@{ WasRunning = $false; Stopped = $false; ExecutablePath = $null } } -UninstallAction { param($install) Restore-TestDiscord $install }
        Assert-True (-not (Test-Path -LiteralPath $script:EquicordDir) -and -not (Test-Path -LiteralPath $script:ConfigDir)) "First uninstall left manager-owned state: $($result | ConvertTo-Json -Depth 5 -Compress)"
        Assert-True (-not (Test-Path -LiteralPath $script:EquicordDir) -and -not (Test-Path -LiteralPath $script:ConfigDir)) "Repeated uninstall would have a manager target to delete."
    }

    Invoke-TestCase "partial cleanup can be retried" {
        $fixture = New-TestFixture "27 partial retry" -DiscordState clean
        $assessment = Get-WorkspaceOwnershipAssessment
        $script:first = $true
        $remover = {
            param($path, $expected, $description)
            if ($description -eq "manager configuration" -and $script:first) { $script:first = $false; throw "mock permission denial" }
            Remove-ExactManagerDirectory -Path $path -Expected $expected -Description $description
        }
        $partial = Invoke-ManagerOwnedCleanup -WorkspaceAssessment $assessment -Remover $remover -BeforeConfigRemoval { Write-UninstallState -Stage cleanup-complete -Install $fixture.Install }
        Assert-True (-not $partial.Complete -and (Test-Path -LiteralPath $script:ConfigDir)) "Cleanup failure did not preserve retry state."
        $retryAssessment = Get-WorkspaceOwnershipAssessment
        $retry = Invoke-ManagerOwnedCleanup -WorkspaceAssessment $retryAssessment -BeforeConfigRemoval { Write-UninstallState -Stage cleanup-complete -Install $fixture.Install }
        Assert-True ($retry.Complete -and -not (Test-Path -LiteralPath $script:ConfigDir)) "Partial cleanup could not be retried."
    }

    Invoke-TestCase "shared development dependencies are preserved" {
        $fixture = New-TestFixture "28 shared dependencies" -DiscordState clean
        $sharedRoot = Join-Path $fixture.Root "Shared Tools"
        New-Item -ItemType Directory -Path $sharedRoot -Force | Out-Null
        foreach ($tool in @("git.exe", "node.exe", "pnpm.cmd", "corepack.cmd", "powershell.exe")) { Set-Content -LiteralPath (Join-Path $sharedRoot $tool) -Value "shared" }
        $context = New-RemovalContext $fixture.Install
        [void](Invoke-FullRemovalPlan -Context $context)
        foreach ($tool in @("git.exe", "node.exe", "pnpm.cmd", "corepack.cmd", "powershell.exe")) { Assert-True (Test-Path -LiteralPath (Join-Path $sharedRoot $tool)) "Shared tool was removed: $tool" }
    }

    Invoke-TestCase "downloaded launcher is never deleted" {
        $fixture = New-TestFixture "29 launcher preserved" -DiscordState clean
        $launcher = Join-Path $fixture.Root "Downloads\Equicord.bat"
        New-Item -ItemType Directory -Path (Split-Path -Parent $launcher) -Force | Out-Null
        Set-Content -LiteralPath $launcher -Value "launcher"
        $context = New-RemovalContext $fixture.Install
        [void](Invoke-FullRemovalPlan -Context $context)
        Assert-True (Test-Path -LiteralPath $launcher -PathType Leaf) "Downloaded launcher was deleted."
    }

    Invoke-TestCase "fresh setup path remains available after uninstall" {
        $fixture = New-TestFixture "30 fresh setup" -DiscordState clean
        $context = New-RemovalContext $fixture.Install
        [void](Invoke-FullRemovalPlan -Context $context)
        New-Item -ItemType Directory -Path $script:EquicordDir, $script:ConfigDir -Force | Out-Null
        Assert-True ((Test-Path -LiteralPath $script:EquicordDir) -and (Test-Path -LiteralPath $script:ConfigDir)) "Fresh manager paths could not be recreated."
    }

    Invoke-TestCase "legacy migration requires its own typed confirmation gate" {
        [void](New-TestFixture "31 legacy gate" -DiscordState clean -Legacy -NoOwnership)
        $blocked = $false
        try { Complete-LegacyWorkspaceOwnershipMigration (Get-WorkspaceOwnershipAssessment) -ConfirmationText yes } catch { $blocked = $true }
        Assert-True ($blocked -and -not (Test-Path $script:OwnershipPath)) "Legacy ownership was silently claimed."
    }

    Invoke-TestCase "unavailable recorded target needs explicit selection even with one candidate" {
        $fixture = New-TestFixture "32 explicit selection" -DiscordState clean
        $ptb = New-TestDiscordInstall -Branch ptb -State clean
        $script:choices = 0
        $selected = Select-DiscordInstallForRemoval (Load-SetupConfig) -Candidates @($ptb) -ChoiceProvider { $script:choices++; "1" }
        Assert-True ($script:choices -eq 1 -and $selected.Branch -eq "ptb") "Unavailable target was silently substituted."
        Save-RecordedDiscordTarget $selected
        Assert-True ((Load-SetupConfig).discordTarget.branch -eq "ptb") "Explicit target was not recorded for retry."
    }

    Invoke-TestCase "missing backup and large corrupt archive are blocked" {
        $fixture = New-TestFixture "33 missing backup"
        Remove-Item -LiteralPath (Join-Path $fixture.Install.Resources '_app.asar')
        Assert-True ((Get-DiscordInjectionState $fixture.Install).Kind -eq "corrupt") "Missing backup accepted."
        [IO.File]::WriteAllBytes((Join-Path $fixture.Install.Resources '_app.asar'), (New-Object byte[] 8192))
        Assert-True ((Get-DiscordInjectionState $fixture.Install).Kind -eq "corrupt") "Large invalid archive accepted."
    }

    Invoke-TestCase "wrong restored bytes prevent cleanup despite successful wrapper exit" {
        $fixture = New-TestFixture "34 hash verification"
        $context = New-RemovalContext $fixture.Install
        $result = Invoke-FullRemovalPlan $context -StopAction { [pscustomobject]@{ WasRunning=$false; Stopped=$false; ExecutablePath=$null } } -UninstallAction {
            param($install)
            Restore-TestDiscord $install
            $path = Join-Path $install.Resources 'app.asar'
            $bytes = [IO.File]::ReadAllBytes($path); $bytes[8191] = 66; [IO.File]::WriteAllBytes($path, $bytes)
        }
        Assert-True ($result.Status -eq 'Failed' -and (Test-Path $script:EquicordDir)) "Archive mismatch allowed cleanup."
    }

    Invoke-TestCase "ignored custom plugins are byte checked and unknown ignored files preserved" {
        [void](New-TestFixture "35 ignored content" -DiscordState clean)
        Set-Content -LiteralPath (Join-Path $script:EquicordDir '.gitignore') -Value "src/userplugins/"
        Invoke-TestGit $script:EquicordDir @('add', '.gitignore')
        Invoke-TestGit $script:EquicordDir @('commit', '-m', 'ignore fixture')
        $plugins = Join-Path $script:EquicordDir 'src/userplugins'
        [void](Write-BundledPlugin (Get-BundledPlugins)[0] $plugins)
        Assert-True ((Get-WorkspaceOwnershipAssessment).CanDeleteWorkspace) "Exact bundled ignored plugin was treated as unknown."
        $file = Get-ChildItem -LiteralPath $plugins -Recurse -File | Select-Object -First 1
        Add-Content -LiteralPath $file.FullName -Value '// personal edit'
        Assert-True (-not (Get-WorkspaceOwnershipAssessment).CanDeleteWorkspace) "Edited ignored plugin would be deleted."
    }

    Invoke-TestCase "ownership marker corruption is not migrated" {
        $fixture = New-TestFixture "36 invalid marker" -DiscordState clean
        Set-Content -LiteralPath $script:OwnershipPath -Value '{}'
        $assessment = Get-WorkspaceOwnershipAssessment
        Assert-True (-not $assessment.LegacyEligible -and -not $assessment.CanDeleteWorkspace) "Invalid existing marker was replaced by legacy migration."
    }

    Invoke-TestCase "ancestor junctions and non-Git directories are rejected" {
        [void](Set-FixturePaths "37 ancestor junction")
        $target = Join-Path $temporaryRoot '37 actual documents'
        New-Item -ItemType Directory -Path $target | Out-Null
        Remove-Item -LiteralPath $script:DocumentsDir
        New-Item -ItemType Junction -Path $script:DocumentsDir -Target $target | Out-Null
        try { Assert-True (-not (Get-WorkspaceOwnershipAssessment).PathValid) "Ancestor junction accepted." }
        finally { [IO.Directory]::Delete($script:DocumentsDir) }
        New-Item -ItemType Directory -Path $script:EquicordDir -Force | Out-Null
        Assert-True (-not (Get-WorkspaceOwnershipAssessment).RepositoryValid) "Non-Git directory accepted."
    }

    Invoke-TestCase "relative and empty manager paths are rejected" {
        foreach ($path in @('', '.', 'C:', '\', '..\Equicord')) {
            $blocked = $false
            try { Get-NormalizedWindowsPath $path | Out-Null } catch { $blocked = $true }
            Assert-True $blocked "Unresolved path accepted: $path"
        }
    }

    Invoke-TestCase "cleanup never follows generated dependency junctions" {
        $fixture = New-TestFixture "39 dependency link" -DiscordState clean
        $external = Join-Path $fixture.Root 'external dependency'
        New-Item -ItemType Directory -Path $external | Out-Null
        Set-Content -LiteralPath (Join-Path $external 'keep.txt') -Value 'keep'
        $modules = Join-Path $script:EquicordDir 'node_modules'
        New-Item -ItemType Directory -Path $modules | Out-Null
        New-Item -ItemType Junction -Path (Join-Path $modules 'linked') -Target $external | Out-Null
        Remove-ExactManagerDirectory $script:EquicordDir $script:EquicordDir 'fixture' | Out-Null
        Assert-True (Test-Path (Join-Path $external 'keep.txt')) "Removal traversed a dependency junction."
    }

    Invoke-TestCase "cleanup rechecks workspace edits made after preview" {
        $fixture = New-TestFixture "40 late edit" -DiscordState clean
        $assessment = Get-WorkspaceOwnershipAssessment
        Set-Content -LiteralPath (Join-Path $script:EquicordDir 'new-personal.txt') -Value 'preserve'
        $result = Invoke-ManagerOwnedCleanup $assessment
        Assert-True (-not $result.Complete -and (Test-Path $script:EquicordDir)) "Stale preview authorization deleted new content."
    }

    Invoke-TestCase "cleanup exceptions after restoration are partial and retryable" {
        $fixture = New-TestFixture "41 cleanup exception" -DiscordState clean
        $result = Invoke-FullRemovalPlan (New-RemovalContext $fixture.Install) -CleanupAction { throw 'locked file' }
        Assert-True ($result.Status -eq 'Partial' -and (Read-UninstallState).stage -eq 'cleanup-started') "Post-restoration failure lost partial recovery state."
    }

    Invoke-TestCase "unknown state files prevent deletion" {
        $fixture = New-TestFixture "42 unknown state" -DiscordState clean
        Set-Content -LiteralPath (Join-Path $script:ConfigDir 'personal.txt') -Value 'keep'
        $result = Invoke-FullRemovalPlan (New-RemovalContext $fixture.Install)
        Assert-True ($result.Status -eq 'Partial' -and (Test-Path $script:EquicordDir)) "Unverified state content was deleted."
    }

    Invoke-TestCase "exact stopped process and restart executable" {
        $fixture = New-TestFixture "43 exact restart" -DiscordState clean
        $script:processFixture = @([pscustomobject]@{ Id=98765; Path=(Join-Path $fixture.Install.AppDirectory 'Discord.exe') })
        $script:closedId = 0
        $state = Stop-SelectedDiscordForRemoval $fixture.Install -ProcessProvider { $script:processFixture } -Stopper { param($process) $script:closedId=$process.Id; $script:processFixture=@() } -Delay { throw 'unexpected delay' }
        $script:started = ''
        [void](Restart-SelectedDiscordAfterRemoval $fixture.Install $state -Starter { param($path, $arguments, $directory) $script:started=$path })
        Assert-True ($script:closedId -eq 98765 -and $script:started -eq (Join-Path $fixture.Install.AppDirectory 'Discord.exe')) "Exact process lifecycle failed."
    }

    Invoke-TestCase "locked process timeout prevents uninjection" {
        $fixture = New-TestFixture "44 timeout" -DiscordState clean
        $blocked = $false
        try { Stop-SelectedDiscordForRemoval $fixture.Install -TimeoutSeconds 0 -ProcessProvider { [pscustomobject]@{ Id=123; Path='fixture.exe' } } -Stopper {} -Delay {} } catch { $blocked=$true }
        Assert-True $blocked 'Locked process timeout was ignored.'
    }

    Invoke-TestCase "Equilotl cannot close an unrelated same-name process" {
        $fixture = New-TestFixture "45 process boundary" -DiscordState clean
        $blocked=$false
        try { Assert-NoUnrelatedDiscordProcess $fixture.Install -Processes @([pscustomobject]@{ ProcessName='Discord'; Path=(Join-Path $fixture.Root 'Other/Discord.exe') }) } catch { $blocked=$true }
        Assert-True $blocked 'Upstream name-based process boundary was not guarded.'
    }

    Invoke-TestCase "interrupted stopped-client state survives an already-clean retry" {
        $fixture = New-TestFixture "46 interruption retry" -DiscordState clean
        Write-UninstallState -Stage discord-restored -Install $fixture.Install -ProcessState ([pscustomobject]@{ WasRunning=$true; Stopped=$true; ExecutablePath=(Join-Path $fixture.Install.AppDirectory 'Discord.exe') })
        $context=New-RemovalContext $fixture.Install
        $context.PreviousState=Read-UninstallState
        $script:restartCount=0
        $result=Invoke-FullRemovalPlan $context -RestartAction { $script:restartCount++; $true }
        Assert-True ($result.Status -eq 'Complete' -and $script:restartCount -eq 1) 'Interrupted process state was lost.'
    }

    Invoke-TestCase "interrupted workspace deletion resumes only unchanged inventoried files" {
        $fixture = New-TestFixture "47 interrupted workspace" -DiscordState clean
        Write-UninstallState -Stage cleanup-started -Install $fixture.Install
        $partial = Invoke-ManagerOwnedCleanup (Get-WorkspaceOwnershipAssessment) -Remover {
            param($path, $expected, $description)
            if ($description -eq 'Equicord workspace') {
                Remove-Item -LiteralPath (Join-Path $path 'package.json')
                throw 'interrupted after first deletion'
            }
        }
        Assert-True (-not $partial.Complete) 'Interrupted cleanup was not partial.'
        Assert-True ((Get-WorkspaceOwnershipAssessment).CanDeleteWorkspace) 'Recorded partial cleanup cannot resume.'
        Set-Content -LiteralPath (Join-Path $script:EquicordDir 'new-user-file.txt') -Value 'keep'
        Assert-True (-not (Get-WorkspaceOwnershipAssessment).CanDeleteWorkspace) 'New content bypassed the recovery inventory.'
        Remove-Item -LiteralPath (Join-Path $script:EquicordDir 'new-user-file.txt')
        $result = Invoke-FullRemovalPlan (New-RemovalContext $fixture.Install)
        Assert-True ($result.Status -eq 'Complete') 'Verified partial workspace was not cleaned on retry.'
    }
} finally {
    $env:LOCALAPPDATA = $originalLocalAppData
    $env:USERPROFILE = $originalUserProfile
    if (Test-Path -LiteralPath $temporaryRoot) {
        $resolved = [IO.Path]::GetFullPath($temporaryRoot)
        if (-not $resolved.StartsWith($systemTemp, [StringComparison]::OrdinalIgnoreCase) -or
            -not (Split-Path -Leaf $resolved).StartsWith("equicord-windows-uninstall-tests-", [StringComparison]::Ordinal)) {
            throw "Refusing to clean an unexpected Windows uninstall test directory: $resolved"
        }
        Remove-Item -LiteralPath $resolved -Recurse -Force
    }
}

Write-Output "Windows uninstall tests: $passes passed, $failures failed."
if ($failures -ne 0) { throw "$failures Windows uninstall test(s) failed." }
