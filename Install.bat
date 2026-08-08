@echo off
setlocal
title WoW 3.3.5a Client Installer
cd /d "%~dp0"

where powershell >nul 2>&1
if errorlevel 1 (
  echo PowerShell is required to run this installer.
  pause
  exit /b 1
)

powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0Install.ps1" %*
set ERR=%ERRORLEVEL%
echo.
if not "%ERR%"=="0" (
  echo Install failed with exit code %ERR%.
  pause
)
exit /b %ERR%
