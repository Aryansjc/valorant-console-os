@echo off
REM ============================================================================
REM  Valorant Console OS - dedicated kiosk shell
REM  This is the shell selected by HKLM\...\Winlogon\Shell in kiosk mode.
REM ============================================================================
setlocal EnableExtensions
title Valorant Console OS
color 0A

set "RIOT_CLIENT=C:\Riot Games\Riot Client\RiotClientServices.exe"
set "VGTRAY=C:\Program Files\Riot Vanguard\vgtray.exe"

if exist "%VGTRAY%" (
    start "" /b "%VGTRAY%"
)

if exist "%RIOT_CLIENT%" goto console_mode
goto setup_mode

REM ---------------------------------------------------------------------------
REM  Valorant Console Mode
REM ---------------------------------------------------------------------------
:console_mode
cls
echo ================================================================
echo                  VALORANT CONSOLE MODE
echo ================================================================
echo.
echo Launching Valorant...
echo.

"%RIOT_CLIENT%" --launch-product=valorant --launch-patchline=live

REM Give the game a moment to appear, then wait while its process is alive.
timeout /t 5 /nobreak >nul
:wait_for_valorant
tasklist /FI "IMAGENAME eq VALORANT-Win64-Shipping.exe" 2>nul | find /I "VALORANT-Win64-Shipping.exe" >nul
if not errorlevel 1 (
    timeout /t 5 /nobreak >nul
    goto wait_for_valorant
)
goto menu

REM ---------------------------------------------------------------------------
REM  Post-game console menu
REM ---------------------------------------------------------------------------
:menu
cls
echo ================================================================
echo                  VALORANT CONSOLE SHELL
echo ================================================================
echo.
echo   [1] Relaunch Valorant
echo   [2] Open Wi-Fi / Network Settings
echo   [3] Open Audio Settings
echo   [4] Launch Full Windows Desktop
echo   [5] Reboot PC
echo   [6] Shut Down PC
echo.
set "CHOICE="
set /p "CHOICE=Select an option [1-6]: "

if "%CHOICE%"=="1" goto console_mode
if "%CHOICE%"=="2" goto network_settings
if "%CHOICE%"=="3" goto audio_settings
if "%CHOICE%"=="4" goto desktop_mode
if "%CHOICE%"=="5" goto reboot_pc
if "%CHOICE%"=="6" goto shutdown_pc

echo.
echo Invalid selection.
timeout /t 2 /nobreak >nul
goto menu

:reboot_pc
shutdown /r /t 0
exit /b 0

:shutdown_pc
shutdown /s /t 0
exit /b 0

:network_settings
start "" "ms-settings:network-wifi"
start "" "ncpa.cpl"
timeout /t 2 /nobreak >nul
goto menu

:audio_settings
control.exe mmsys.cpl sounds
timeout /t 2 /nobreak >nul
goto menu

:desktop_mode
start "" explorer.exe
timeout /t 2 /nobreak >nul
goto menu

REM ---------------------------------------------------------------------------
REM  First-boot setup mode: Riot Client is not installed yet
REM ---------------------------------------------------------------------------
:setup_mode
cls
echo ================================================================
echo                 FIRST-BOOT SETUP MODE
echo ================================================================
echo.
echo Valorant is not installed yet. Windows Explorer will open for setup.
echo.
echo   1. Open diskmgmt.msc and set every internal NVMe/SATA drive
echo      to Offline for safety before installing anything.
echo   2. Install the GPU and Wi-Fi drivers.
echo   3. Install Valorant into C:\Riot Games.
echo   4. Reboot back into this microSD card so vgk.sys initializes
echo      and the console boots directly into Valorant Console Mode.
echo.
echo A terminal window with these instructions remains open.
echo Close it when you are ready to continue.
echo.
start "" explorer.exe
pause >nul
exit /b 0
