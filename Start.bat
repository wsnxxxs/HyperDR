@echo off
chcp 65001 >nul
cd /d "%~dp0"
echo Starting HyperDR LAN interface...
echo Use the complete iPhone URL printed below, including its temporary token.
powershell -NoProfile -ExecutionPolicy Bypass -File scripts\start_hyperdr_lan.ps1
if errorlevel 1 pause
