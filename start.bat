@echo off
title Lab Chrome Profile
rem ASCII only, on purpose. Korean bytes in a .bat make cmd mis-parse the next
rem line (see CLAUDE.md), so every message lives in the .ps1 instead.
rem
rem 2>> catches what run-log.txt cannot: powershell failing to start, or dying
rem before Start-LPLog runs. stdout is left alone so Write-Host output and the
rem password prompt keep working. The file is created even when nothing is
rem written, so it is deleted when empty - its presence alone is the signal.
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0lab-profile.ps1" %* 2>>"%~dp0boot-error.txt"
if not exist "%~dp0boot-error.txt" goto :done
for %%A in ("%~dp0boot-error.txt") do if %%~zA EQU 0 (del "%%~fA") else (echo *** see boot-error.txt ***)
:done
echo.
pause
