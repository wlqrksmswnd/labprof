@echo off
title Change Container Password
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0change-password.ps1" %*
echo.
pause
