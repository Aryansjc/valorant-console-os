@echo off
REM ============================================================================
REM  Valorant Console OS - switch between kiosk shell and desktop shell
REM  Usage: switch-mode.bat --kiosk ^| --desktop
REM ============================================================================
setlocal EnableExtensions
set "WINLOGON=HKLM\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Winlogon"

if /I "%~1"=="--kiosk" (
    reg add "%WINLOGON%" /v Shell /t REG_SZ /d "cmd.exe /c \"C:\Riot Games\val-kiosk.bat\"" /f
    if errorlevel 1 (
        echo [FAIL] Could not enable kiosk shell.
        exit /b 1
    )
    echo [PASS] Kiosk shell enabled.
    echo Reboot or sign out to apply.
    exit /b 0
)

if /I "%~1"=="--desktop" (
    reg add "%WINLOGON%" /v Shell /t REG_SZ /d "explorer.exe" /f
    if errorlevel 1 (
        echo [FAIL] Could not enable desktop shell.
        exit /b 1
    )
    echo [PASS] Desktop shell enabled.
    echo Reboot or sign out to apply.
    exit /b 0
)

echo Usage: %~nx0 --kiosk ^| --desktop
exit /b 1
