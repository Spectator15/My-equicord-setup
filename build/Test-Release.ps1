[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$repoRoot = Split-Path -Parent $PSScriptRoot
$releasePath = Join-Path $repoRoot "Equicord.bat"
$installerPath = Join-Path $repoRoot "src\EquicordSetup.ps1"
$pluginsRoot = Join-Path $repoRoot "src\plugins"
$manifestPath = Join-Path $pluginsRoot "PluginManifest.psd1"
$strictUtf8 = New-Object System.Text.UTF8Encoding -ArgumentList $false, $true
$utf8NoBom = New-Object System.Text.UTF8Encoding -ArgumentList $false

function ConvertTo-Crlf {
    param([Parameter(Mandatory = $true)][string]$Text)
    $lf = ($Text -replace "`r`n", "`n") -replace "`r", "`n"
    return $lf -replace "`n", "`r`n"
}

function Assert-ByteEqual {
    param(
        [Parameter(Mandatory = $true)][byte[]]$Expected,
        [Parameter(Mandatory = $true)][byte[]]$Actual,
        [Parameter(Mandatory = $true)][string]$Description
    )
    if (-not [Linq.Enumerable]::SequenceEqual($Expected, $Actual)) {
        throw "$Description does not match the organised source file."
    }
}

& (Join-Path $PSScriptRoot "Build-Release.ps1") -Check

$release = [IO.File]::ReadAllText($releasePath, $strictUtf8)
if (-not $release.StartsWith("@echo off`r`n", [StringComparison]::Ordinal)) {
    throw "Equicord.bat no longer starts with the Batch launcher."
}
if (-not $release.Contains("rem GENERATED FILE: built from src/ by build/Build-Release.ps1.")) {
    throw "Equicord.bat is missing its generated-file notice."
}
if ([regex]::IsMatch($release, "(?<!`r)`n|`r(?!`n)")) {
    throw "Equicord.bat contains non-CRLF line endings."
}

$payloadMarker = "#region INIT"
$payloadStart = $release.IndexOf($payloadMarker, [StringComparison]::Ordinal)
if ($payloadStart -lt 0 -or
    $payloadStart -ne $release.LastIndexOf($payloadMarker, [StringComparison]::Ordinal)) {
    throw "Equicord.bat must contain exactly one embedded PowerShell startup marker."
}
$batchLauncher = $release.Substring(0, $payloadStart)
if (-not $batchLauncher.Contains("`$marker = ('#' + 'region INIT')")) {
    throw "The Batch launcher cannot locate the embedded PowerShell marker."
}

$sourceTokens = $null
$sourceErrors = $null
[void][Management.Automation.Language.Parser]::ParseFile(
    $installerPath,
    [ref]$sourceTokens,
    [ref]$sourceErrors
)
if ($sourceErrors.Count -gt 0) {
    throw "src/EquicordSetup.ps1 failed to parse: $($sourceErrors[0].Message)"
}

$payload = $release.Substring($payloadStart)
$payloadTokens = $null
$payloadErrors = $null
$payloadAst = [Management.Automation.Language.Parser]::ParseInput(
    $payload,
    [ref]$payloadTokens,
    [ref]$payloadErrors
)
if ($payloadErrors.Count -gt 0) {
    throw "Generated embedded PowerShell failed to parse: $($payloadErrors[0].Message)"
}

$registryAssignment = $payloadAst.Find({
    param($node)
    $node -is [Management.Automation.Language.AssignmentStatementAst] -and
        $node.Left.Extent.Text -ceq '$script:BundledPlugins'
}, $true)
if (-not $registryAssignment) { throw "Generated plugin registry assignment was not found." }
$script:BundledPlugins = $null
& ([scriptblock]::Create($registryAssignment.Extent.Text))
$generatedPlugins = @($script:BundledPlugins)

$manifest = Import-PowerShellDataFile -LiteralPath $manifestPath
$manifestPlugins = @($manifest.Plugins)
if ($generatedPlugins.Count -ne $manifestPlugins.Count) {
    throw "Generated plugin count does not match the manifest."
}

$fileCount = 0
foreach ($manifestPlugin in $manifestPlugins) {
    $id = [string]$manifestPlugin.Id
    $generated = @($generatedPlugins | Where-Object { $_.Id -ceq $id })
    if ($generated.Count -ne 1) { throw "Generated registry entry is missing or duplicated: $id" }
    $generatedPlugin = $generated[0]
    foreach ($field in @("DisplayName", "FolderName", "Description", "DefaultSelected", "Notes")) {
        if ($generatedPlugin.$field -cne $manifestPlugin[$field]) {
            throw "Generated metadata differs for $id/$field."
        }
    }
    if ((@($generatedPlugin.LegacyFolders) -join "`0") -cne (@($manifestPlugin.LegacyFolders) -join "`0")) {
        throw "Generated legacy folder metadata differs for $id."
    }

    $manifestFiles = @($manifestPlugin.Files | ForEach-Object { [string]$_ })
    if ($generatedPlugin.Files.Count -ne $manifestFiles.Count) {
        throw "Generated file count differs for $id."
    }
    foreach ($fileName in $manifestFiles) {
        if (-not $generatedPlugin.Files.Contains($fileName)) {
            throw "Generated registry is missing $id/$fileName."
        }
        $sourcePath = Join-Path (Join-Path $pluginsRoot ([string]$manifestPlugin.FolderName)) $fileName
        $source = [IO.File]::ReadAllText($sourcePath, $strictUtf8)
        $expectedBytes = $utf8NoBom.GetBytes((ConvertTo-Crlf $source))
        try {
            $actualBytes = [Convert]::FromBase64String([string]$generatedPlugin.Files[$fileName])
        } catch {
            throw "Generated registry contains invalid Base64 for $id/$fileName."
        }
        Assert-ByteEqual -Expected $expectedBytes -Actual $actualBytes -Description "$id/$fileName"
        $fileCount++
    }
}

if ($generatedPlugins.Count -ne 10 -or $fileCount -ne 11) {
    throw "Expected 10 bundled plugins and 11 generated files; found $($generatedPlugins.Count) and $fileCount."
}

foreach ($functionName in @(
    "Write-Utf8FileAtomic",
    "Get-SafeChildPath",
    "Get-SafePluginFilePath",
    "Write-BundledPlugin"
)) {
    $definition = $payloadAst.Find({
        param($node)
        $node -is [Management.Automation.Language.FunctionDefinitionAst] -and
            $node.Name -ceq $functionName
    }, $true)
    if (-not $definition) { throw "Generated installer function is missing: $functionName" }
    . ([scriptblock]::Create($definition.Extent.Text))
}

$temporaryRoot = [IO.Path]::GetFullPath([IO.Path]::GetTempPath())
$testDirectory = [IO.Path]::GetFullPath((
    Join-Path $temporaryRoot ("equicord-release-test-" + [Guid]::NewGuid().ToString("N"))
))
if (-not $testDirectory.StartsWith($temporaryRoot, [StringComparison]::OrdinalIgnoreCase)) {
    throw "Refusing to create a release test directory outside the system temporary directory."
}

New-Item -ItemType Directory -Path $testDirectory -Force | Out-Null
try {
    $unknownDirectory = Join-Path $testDirectory "thirdPartyPlugin"
    New-Item -ItemType Directory -Path $unknownDirectory | Out-Null

    foreach ($plugin in $generatedPlugins) {
        if (-not (Write-BundledPlugin -Plugin $plugin -PluginsDir $testDirectory)) {
            throw "First runtime write unexpectedly reported no change: $($plugin.Id)"
        }
        if (Write-BundledPlugin -Plugin $plugin -PluginsDir $testDirectory) {
            throw "Second runtime write unexpectedly reported a change: $($plugin.Id)"
        }
        foreach ($file in $plugin.Files.GetEnumerator()) {
            $writtenPath = Join-Path (Join-Path $testDirectory $plugin.FolderName) ([string]$file.Key)
            $writtenBytes = [IO.File]::ReadAllBytes($writtenPath)
            $embeddedBytes = [Convert]::FromBase64String([string]$file.Value)
            Assert-ByteEqual -Expected $embeddedBytes -Actual $writtenBytes -Description "Runtime write $($plugin.Id)/$($file.Key)"
        }
    }
    if (-not (Test-Path -LiteralPath $unknownDirectory -PathType Container)) {
        throw "The generic writer removed an unknown user-plugin folder."
    }

    $unsafePlugin = [pscustomobject]@{
        DisplayName = "unsafePathTest"
        FolderName = "unsafePathTest"
        Files = [ordered]@{
            "..\escape.ts" = [Convert]::ToBase64String($utf8NoBom.GetBytes("blocked"))
        }
    }
    $unsafePathBlocked = $false
    try {
        Write-BundledPlugin -Plugin $unsafePlugin -PluginsDir $testDirectory | Out-Null
    } catch {
        $unsafePathBlocked = $true
    }
    if (-not $unsafePathBlocked) { throw "The generic writer accepted an unsafe plugin file path." }
} finally {
    if ((Test-Path -LiteralPath $testDirectory) -and
        $testDirectory.StartsWith($temporaryRoot, [StringComparison]::OrdinalIgnoreCase)) {
        Remove-Item -LiteralPath $testDirectory -Recurse -Force
    }
}

& (Join-Path $PSScriptRoot "Test-WindowsUninstall.ps1")

Write-Output "Release validation passed: 10 plugins, 11 files, valid loader, CRLF, UTF-8, parse-clean PowerShell, atomic no-change writes, safe paths, unknown-folder preservation, and Windows full-removal coverage."
