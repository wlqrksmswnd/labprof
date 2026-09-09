@echo off
title Change Container Password
rem ASCII only, on purpose - see the comment in start.bat.
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0change-password.ps1" %* 2>>"%~dp0boot-error.txt"
if not exist "%~dp0boot-error.txt" goto :done
for %%A in ("%~dp0boot-error.txt") do if %%~zA EQU 0 (del "%%~fA") else (echo *** see boot-error.txt ***)
:done
echo.
pause
