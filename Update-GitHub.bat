@echo off
rem Double-click de day thay doi len GitHub. Them -DryRun de chi xem, khong day.
chcp 65001 >nul
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0Update-GitHub.ps1" %*
echo.
pause
