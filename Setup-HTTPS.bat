@echo off
chcp 65001 >nul
cd /d "%~dp0"
echo Configuring trusted HTTPS for iPhone true HDR...
echo This only needs to be done once per computer.
powershell -NoProfile -ExecutionPolicy Bypass -File scripts\setup_hyperdr_https.ps1 %*
pause
