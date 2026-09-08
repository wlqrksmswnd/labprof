@echo off
title Lab Chrome Profile
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0lab-profile.ps1" %*
echo.
pause
