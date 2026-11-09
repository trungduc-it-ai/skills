@echo off
rem Build goi cai dat API (chay tren may co .NET SDK)
chcp 65001 >nul
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0Build-Package.ps1" %*
pause
