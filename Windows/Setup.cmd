@echo off
REM ============================================================
REM  System-Setup launcher -- double-click this file to start.
REM  Everything else is in the .setup folder (hidden).
REM ============================================================
setlocal

REM Try .setup subfolder first (zip distribution), then same folder (source)
set "SCRIPT_DIR=%~dp0"
if exist "%SCRIPT_DIR%.setup\Setup.ps1" (
    set "SETUP_PS1=%SCRIPT_DIR%.setup\Setup.ps1"
) else (
    set "SETUP_PS1=%SCRIPT_DIR%Setup.ps1"
)

powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%SETUP_PS1%" %*
exit /b %ERRORLEVEL%
