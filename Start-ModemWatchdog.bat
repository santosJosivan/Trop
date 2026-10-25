@echo off
REM Double-click to start the watchdog. Extra arguments are passed through, e.g.:
REM   Start-ModemWatchdog.bat -TestLogin
title Modem Watchdog
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0ModemWatchdog.ps1" %*
pause
