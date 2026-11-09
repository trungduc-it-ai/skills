@echo off
rem Double-click de chay. Co the truyen tham so: BaoCaoSuaSP.cmd -Server TEN_SERVER -Objects sp_X
chcp 65001 >nul
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0BaoCaoSuaSP.ps1" %*
echo.
pause
