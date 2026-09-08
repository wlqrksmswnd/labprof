@echo off
title Collect Environment
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0collect-env.ps1"
echo.
pause
