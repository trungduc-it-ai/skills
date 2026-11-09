@echo off
rem Cong cu trien khai API len IIS - tu xin quyen Administrator
chcp 65001 >nul
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0Deploy.ps1" %*
if errorlevel 1 pause
