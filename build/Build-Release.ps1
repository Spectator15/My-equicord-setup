[CmdletBinding()]
param(
    [switch]$Check
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$repoRoot = Split-Path -Parent $PSScriptRoot
$launcherPath = Join-Path $repoRoot "src\EquicordLauncher.template.bat"
$installerPath = Join-Path $repoRoot "src\EquicordSetup.ps1"
$pluginsRoot = Join-Path $repoRoot "src\plugins"
$manifestPath = Join-Path $pluginsRoot "PluginManifest.psd1"
$outputPath = Join-Path $repoRoot "Equicord.bat"
$launcherMarker = "{{EQUICORD_SETUP_POWERSHELL}}"
$registryMarker = "# <BUILD:BUNDLED_PLUGIN_REGISTRY>"
$utf8NoBom = New-Object System.Text.UTF8Encoding -ArgumentList $false
$strictUtf8 = New-Object System.Text.UTF8Encoding -ArgumentList $false, $true

function ConvertTo-Crlf {
    param([Parameter(Mandatory = $true)][string]$Text)
    $lf = ($Text -replace "`r`n", "`n") -replace "`r", "`n"
    return $lf -replace "`n", "`r`n"
}

function Read-RequiredUtf8File {
    param([Parameter(Mandatory = $true)][string]$Path)
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
        throw "Required source file is missing: $Path"
    }
    try {
        return [IO.File]::ReadAllText($Path, $strictUtf8)
    } catch {
        throw "Required source file is not valid UTF-8: $Path`n$($_.Exception.Message)"
    }
}

function Assert-SingleMarker {
    param(
        [Parameter(Mandatory = $true)][string]$Text,
        [Parameter(Mandatory = $true)][string]$Marker,
        [Parameter(Mandatory = $true)][string]$Description
    )
    $first = $Text.IndexOf($Marker, [StringComparison]::Ordinal)
    $last = $Text.LastIndexOf($Marker, [StringComparison]::Ordinal)
    if ($first -lt 0) { throw "$Description is missing: $Marker" }
    if ($first -ne $last) { throw "$Description must appear exactly once: $Marker" }
}

function ConvertTo-PowerShellLiteral {
    param([AllowEmptyString()][string]$Value)
    if ($null -eq $Value) { return "''" }
    return "'" + $Value.Replace("'", "''") + "'"
}

function Test-SafeLeafName {
    param([Parameter(Mandatory = $true)][string]$Name)
    return -not [string]::IsNullOrWhiteSpace($Name) -and
        $Name -ne "." -and
        $Name -ne ".." -and
        [IO.Path]::GetFileName($Name) -ceq $Name -and
        $Name.IndexOfAny([IO.Path]::GetInvalidFileNameChars()) -lt 0
}

function Add-RegistryLine {
    param(
        [Parameter(Mandatory = $true)]$Lines,
        [Parameter(Mandatory = $true)][AllowEmptyString()][string]$Text
    )
    [void]$Lines.Add($Text)
}

if (-not (Test-Path -LiteralPath $manifestPath -PathType Leaf)) {
    throw "Plugin manifest is missing: $manifestPath"
}
$manifest = Import-PowerShellDataFile -LiteralPath $manifestPath
if ([int]$manifest.SchemaVersion -ne 1) {
    throw "Unsupported plugin manifest schema version: $($manifest.SchemaVersion)"
}
$plugins = @($manifest.Plugins)
if ($plugins.Count -eq 0) { throw "The plugin manifest contains no plugins." }

$requiredFields = @(
    "Id",
    "DisplayName",
    "FolderName",
    "Description",
    "DefaultSelected",
    "LegacyFolders",
    "Notes",
    "Files"
)
$ids = New-Object System.Collections.Generic.HashSet[string] ([StringComparer]::OrdinalIgnoreCase)
$folders = New-Object System.Collections.Generic.HashSet[string] ([StringComparer]::OrdinalIgnoreCase)
$manifestFolderNames = New-Object System.Collections.Generic.List[string]
$registryLines = New-Object System.Collections.Generic.List[string]
Add-RegistryLine $registryLines '$script:BundledPlugins = @('

foreach ($plugin in $plugins) {
    foreach ($field in $requiredFields) {
        if (-not $plugin.ContainsKey($field)) {
            throw "Plugin manifest entry is missing '$field': $($plugin.Id)"
        }
    }

    $id = [string]$plugin.Id
    $folderName = [string]$plugin.FolderName
    if ($id -notmatch '^[A-Za-z0-9][A-Za-z0-9_-]*$') {
        throw "Unsafe plugin id in manifest: $id"
    }
    if (-not (Test-SafeLeafName $folderName)) {
        throw "Unsafe plugin folder name in manifest: $folderName"
    }
    if (-not $ids.Add($id)) { throw "Duplicate plugin id in manifest: $id" }
    if (-not $folders.Add($folderName)) { throw "Duplicate plugin folder in manifest: $folderName" }
    $manifestFolderNames.Add($folderName)

    $pluginDirectory = Join-Path $pluginsRoot $folderName
    if (-not (Test-Path -LiteralPath $pluginDirectory -PathType Container)) {
        throw "Required plugin directory is missing: $pluginDirectory"
    }
    $directoryItem = Get-Item -LiteralPath $pluginDirectory -Force
    if (($directoryItem.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
        throw "Plugin source directory must not be a reparse point: $pluginDirectory"
    }
    if (Get-ChildItem -LiteralPath $pluginDirectory -Directory -Force) {
        throw "Nested plugin source directories are not supported: $pluginDirectory"
    }

    $fileNames = @($plugin.Files | ForEach-Object { [string]$_ })
    if ($fileNames.Count -eq 0) { throw "Plugin manifest entry contains no files: $id" }
    $fileSet = New-Object System.Collections.Generic.HashSet[string] ([StringComparer]::OrdinalIgnoreCase)
    foreach ($fileName in $fileNames) {
        if (-not (Test-SafeLeafName $fileName)) {
            throw "Unsafe plugin file name in manifest: $id/$fileName"
        }
        if (-not $fileSet.Add($fileName)) {
            throw "Duplicate plugin file in manifest: $id/$fileName"
        }
    }

    $actualFiles = @(Get-ChildItem -LiteralPath $pluginDirectory -File -Force | Select-Object -ExpandProperty Name)
    $missingFiles = @($fileNames | Where-Object { $actualFiles -cnotcontains $_ })
    $unexpectedFiles = @($actualFiles | Where-Object { $fileNames -cnotcontains $_ })
    if ($missingFiles.Count -gt 0) {
        throw "Required plugin source is missing: $id/$($missingFiles -join ', ')"
    }
    if ($unexpectedFiles.Count -gt 0) {
        throw "Plugin source is not registered in the manifest: $id/$($unexpectedFiles -join ', ')"
    }

    Add-RegistryLine $registryLines '    [pscustomobject]@{'
    Add-RegistryLine $registryLines ("        Id = " + (ConvertTo-PowerShellLiteral $id))
    Add-RegistryLine $registryLines ("        DisplayName = " + (ConvertTo-PowerShellLiteral ([string]$plugin.DisplayName)))
    Add-RegistryLine $registryLines ("        FolderName = " + (ConvertTo-PowerShellLiteral $folderName))
    Add-RegistryLine $registryLines ("        Description = " + (ConvertTo-PowerShellLiteral ([string]$plugin.Description)))
    Add-RegistryLine $registryLines ("        DefaultSelected = `$$(([bool]$plugin.DefaultSelected).ToString().ToLowerInvariant())")
    $legacyLiterals = @($plugin.LegacyFolders | ForEach-Object {
        $legacy = [string]$_
        if (-not (Test-SafeLeafName $legacy)) { throw "Unsafe legacy plugin folder in manifest: $id/$legacy" }
        ConvertTo-PowerShellLiteral $legacy
    })
    Add-RegistryLine $registryLines ("        LegacyFolders = @(" + ($legacyLiterals -join ", ") + ")")
    Add-RegistryLine $registryLines ("        Notes = " + (ConvertTo-PowerShellLiteral ([string]$plugin.Notes)))
    Add-RegistryLine $registryLines '        Files = [ordered]@{'

    foreach ($fileName in $fileNames) {
        $filePath = Join-Path $pluginDirectory $fileName
        $sourceText = Read-RequiredUtf8File $filePath
        $windowsText = ConvertTo-Crlf $sourceText
        $bytes = $utf8NoBom.GetBytes($windowsText)
        $base64 = [Convert]::ToBase64String($bytes)
        $chunks = @()
        for ($offset = 0; $offset -lt $base64.Length; $offset += 120) {
            $length = [Math]::Min(120, $base64.Length - $offset)
            $chunks += $base64.Substring($offset, $length)
        }

        Add-RegistryLine $registryLines ("            " + (ConvertTo-PowerShellLiteral $fileName) + " = (@(")
        foreach ($chunk in $chunks) {
            Add-RegistryLine $registryLines ("                " + (ConvertTo-PowerShellLiteral $chunk))
        }
        Add-RegistryLine $registryLines "            ) -join '')"
    }
    Add-RegistryLine $registryLines '        }'
    Add-RegistryLine $registryLines '    }'
}
Add-RegistryLine $registryLines ')'
$registryBlock = $registryLines -join "`r`n"

$actualDirectories = @(
    Get-ChildItem -LiteralPath $pluginsRoot -Directory -Force |
        Select-Object -ExpandProperty Name
)
$missingDirectories = @($manifestFolderNames | Where-Object { $actualDirectories -cnotcontains $_ })
$unexpectedDirectories = @($actualDirectories | Where-Object { $manifestFolderNames -cnotcontains $_ })
if ($missingDirectories.Count -gt 0) {
    throw "Manifest plugin directories are missing: $($missingDirectories -join ', ')"
}
if ($unexpectedDirectories.Count -gt 0) {
    throw "Plugin source directories are not registered in the manifest: $($unexpectedDirectories -join ', ')"
}

$launcher = ConvertTo-Crlf (Read-RequiredUtf8File $launcherPath)
$installer = ConvertTo-Crlf (Read-RequiredUtf8File $installerPath)
Assert-SingleMarker -Text $launcher -Marker $launcherMarker -Description "Launcher payload marker"
Assert-SingleMarker -Text $installer -Marker $registryMarker -Description "Installer registry marker"

$installer = $installer.Replace($registryMarker, $registryBlock)
$parseTokens = $null
$parseErrors = $null
[void][Management.Automation.Language.Parser]::ParseInput(
    $installer,
    [ref]$parseTokens,
    [ref]$parseErrors
)
if ($parseErrors.Count -gt 0) {
    $messages = $parseErrors | ForEach-Object { $_.Message }
    throw "Generated installer PowerShell failed to parse:`n$($messages -join "`n")"
}

$launcher = $launcher.TrimEnd("`r", "`n")
$installer = $installer.TrimEnd("`r", "`n")
$output = $launcher.Replace($launcherMarker, $installer) + "`r`n"
if ($output.Contains($launcherMarker) -or $output.Contains($registryMarker)) {
    throw "Generated output still contains an unresolved build marker."
}
Assert-SingleMarker -Text $output -Marker "#region INIT" -Description "Embedded PowerShell startup marker"
if (-not $output.Contains("`$marker = ('#' + 'region INIT')")) {
    throw "The Batch launcher no longer assembles the embedded PowerShell marker safely."
}
if ([regex]::IsMatch($output, "(?<!`r)`n|`r(?!`n)")) {
    throw "Generated output contains non-CRLF line endings."
}
if ($output.IndexOf($repoRoot, [StringComparison]::OrdinalIgnoreCase) -ge 0 -or
    $output.IndexOf(($repoRoot -replace '\\', '/'), [StringComparison]::OrdinalIgnoreCase) -ge 0) {
    throw "Generated output contains a machine-specific repository path."
}

$outputBytes = $utf8NoBom.GetBytes($output)
if ($Check) {
    if (-not (Test-Path -LiteralPath $outputPath -PathType Leaf)) {
        throw "Generated release is missing: $outputPath"
    }
    $existingBytes = [IO.File]::ReadAllBytes($outputPath)
    if (-not [Linq.Enumerable]::SequenceEqual($existingBytes, $outputBytes)) {
        throw "Equicord.bat is out of date. Run .\build\Build-Release.ps1 and commit the result."
    }
    Write-Output "Equicord.bat matches the organised source files."
    return
}

if (Test-Path -LiteralPath $outputPath -PathType Leaf) {
    $existingBytes = [IO.File]::ReadAllBytes($outputPath)
    if ([Linq.Enumerable]::SequenceEqual($existingBytes, $outputBytes)) {
        Write-Output "Equicord.bat is already current."
        return
    }
}

$temporaryPath = Join-Path $repoRoot (".Equicord.bat." + [Guid]::NewGuid().ToString("N") + ".tmp")
try {
    [IO.File]::WriteAllBytes($temporaryPath, $outputBytes)
    Move-Item -LiteralPath $temporaryPath -Destination $outputPath -Force
} finally {
    if (Test-Path -LiteralPath $temporaryPath) {
        Remove-Item -LiteralPath $temporaryPath -Force -ErrorAction SilentlyContinue
    }
}
Write-Output "Built Equicord.bat from the organised source files."
