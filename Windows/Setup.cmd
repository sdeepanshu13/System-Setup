@echo off
REM ============================================================
REM  System-Setup -- double-click this file to start.
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

echo.
echo  =============================================
echo   System-Setup - Windows Dev Machine Setup
echo  =============================================
echo.
echo  Setup is running in the Administrator window.
echo  This window will close when setup finishes.
echo  DO NOT close this window.
echo.

powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%SETUP_PS1%" %*
exit /b %ERRORLEVEL%
