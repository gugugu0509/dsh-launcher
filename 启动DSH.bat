@echo off
rem ============================================================
rem  DeepSeek Harness Desktop Launcher - double-click to run
rem ============================================================
setlocal
cd /d "%~dp0"
rem NOTE: do NOT add -WindowStyle Hidden, it also hides/minimizes the GUI window.
rem The console black window is hidden inside launcher.ps1 via ShowWindow.
rem ============================================================
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0launcher.ps1"
endlocal
