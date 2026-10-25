@echo off
REM Read-only diagnosis. Run while 192.168.2.95 is NOT responding.
title Device Diagnosis
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0Diagnose-Device.ps1" %*
pause
