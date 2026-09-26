@echo off
rem ============================================================
rem  DeepSeek Harness Desktop Launcher - double-click to run
rem ============================================================
setlocal
cd /d "%~dp0"
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0launcher.ps1"
endlocal
