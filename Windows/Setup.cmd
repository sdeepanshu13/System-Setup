@echo off
REM ============================================================
REM  System-Setup launcher -- double-click this file to start.
REM  Everything else is in the .setup folder (hidden).
REM ============================================================
setlocal

set "SCRIPT_DIR=%~dp0"
if exist "%SCRIPT_DIR%.setup\Setup.ps1" (
    set "SETUP_PS1=%SCRIPT_DIR%.setup\Setup.ps1"
) else if exist "%SCRIPT_DIR%Setup.ps1" (
    set "SETUP_PS1=%SCRIPT_DIR%Setup.ps1"
) else (
    echo ERROR: Cannot find Setup.ps1
    echo Looked in: %SCRIPT_DIR%.setup\
    echo        and: %SCRIPT_DIR%
    pause
    exit /b 1
)

echo Starting System-Setup...
echo Script: %SETUP_PS1%
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%SETUP_PS1%" %*
if %ERRORLEVEL% neq 0 (
    echo.
    echo Setup exited with error code %ERRORLEVEL%
    pause
)
exit /b %ERRORLEVEL%
