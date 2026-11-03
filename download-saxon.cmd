@echo off
setlocal
powershell.exe -NoLogo -NoProfile -ExecutionPolicy Bypass -File "%~dp0download-saxon.ps1" %*
exit /b %errorlevel%
