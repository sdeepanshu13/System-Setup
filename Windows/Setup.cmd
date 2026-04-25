@echo off
REM ============================================================
REM  System-Setup launcher (works from CMD, double-click, or PS)
REM  Bypasses the default execution policy so the .ps1 just runs.
REM ============================================================
setlocal
set "SCRIPT_DIR=%~dp0"
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%SCRIPT_DIR%Setup.ps1" %*
exit /b %ERRORLEVEL%
