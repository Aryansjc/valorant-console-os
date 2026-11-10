@echo off
REM ============================================================================
REM  Valorant Console OS - Phase 5 attestation launcher
REM  Runs phase5_attest.ps1, which self-elevates and only reads security state.
REM ============================================================================
setlocal EnableExtensions
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0phase5_attest.ps1"
set "RC=%ERRORLEVEL%"
echo.
if not "%RC%"=="0" (
    echo Phase 5 attestation reported failures.
    echo Review "C:\Riot Games\phase5_attestation.txt".
)
else (
    echo Phase 5 attestation completed successfully.
    echo Report: "C:\Riot Games\phase5_attestation.json"
)
echo.
pause >nul
exit /b %RC%
