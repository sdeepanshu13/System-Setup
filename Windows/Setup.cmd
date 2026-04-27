@echo off
REM ============================================================
REM  System-Setup -- double-click this file to start.
REM  Handles elevation itself so only ONE window exists.
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

REM Check if we're already admin
net session >nul 2>&1
if %ERRORLEVEL% neq 0 (
    echo Requesting Administrator access...
    powershell.exe -NoProfile -Command "Start-Process -FilePath 'cmd.exe' -ArgumentList '/c \"\"%~f0\" %*\"' -Verb RunAs -Wait"
    exit /b %ERRORLEVEL%
)

echo.
echo  =============================================
echo   System-Setup - Windows Dev Machine Setup
echo  =============================================
echo.

powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%SETUP_PS1%" %*

echo.
if %ERRORLEVEL% neq 0 (
    echo Setup finished with errors. Check the log file above.
) else (
    echo Setup complete!
)
echo.
pause
exit /b %ERRORLEVEL%
exit /b %ERRORLEVEL%
