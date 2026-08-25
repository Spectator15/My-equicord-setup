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

{{EQUICORD_SETUP_POWERSHELL}}
