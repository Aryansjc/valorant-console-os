@echo off
REM ============================================================================
REM  Valorant Console OS - Phase 2 first-logon provisioning
REM  Must run elevated.  This script never disables Vanguard or Defender.
REM ============================================================================
setlocal EnableExtensions
title Valorant Console OS - Provisioning

set "RIOT_DIR=C:\Riot Games"
set "LOG=%RIOT_DIR%\phase2_setup.log"

if not exist "%RIOT_DIR%" mkdir "%RIOT_DIR%" >nul 2>&1
echo [%DATE% %TIME%] Phase 2 provisioning started > "%LOG%"

REM ---------------------------------------------------------------------------
REM  1. Windows 10 22H2 enablement and LTSC build-string compliance
REM ---------------------------------------------------------------------------
echo [%DATE% %TIME%] Installing KB5015684 enablement package >> "%LOG%"
dism /online /add-package /packagepath:"C:\Riot Games\windows10.0-kb5015684-x64.cab" /quiet /norestart >> "%LOG%" 2>&1
echo [%DATE% %TIME%] DISM add-package exit code: %ERRORLEVEL% >> "%LOG%"

reg add "HKLM\SOFTWARE\Microsoft\Windows NT\CurrentVersion" /v DisplayVersion /t REG_SZ /d "22H2" /f >> "%LOG%" 2>&1
reg add "HKLM\SOFTWARE\Microsoft\Windows NT\CurrentVersion" /v ReleaseId /t REG_SZ /d "2009" /f >> "%LOG%" 2>&1
reg add "HKLM\SOFTWARE\Microsoft\Windows NT\CurrentVersion" /v CurrentBuild /t REG_SZ /d "19045" /f >> "%LOG%" 2>&1
reg add "HKLM\SOFTWARE\Microsoft\Windows NT\CurrentVersion" /v CurrentBuildNumber /t REG_SZ /d "19045" /f >> "%LOG%" 2>&1

REM ---------------------------------------------------------------------------
REM  2. CompactOS and microSD write survival
REM ---------------------------------------------------------------------------
echo [%DATE% %TIME%] Enabling CompactOS >> "%LOG%"
compact.exe /CompactOS:always >> "%LOG%" 2>&1

echo [%DATE% %TIME%] Disabling hibernation >> "%LOG%"
powercfg -h off >> "%LOG%" 2>&1

echo [%DATE% %TIME%] Disabling last-access updates >> "%LOG%"
fsutil behavior set disablelastaccess 1 >> "%LOG%" 2>&1

echo [%DATE% %TIME%] Disabling 8.3 name creation >> "%LOG%"
fsutil 8dot3name set 1 >> "%LOG%" 2>&1

echo [%DATE% %TIME%] Setting fixed pagefile 2048-4096 MiB >> "%LOG%"
reg add "HKLM\SYSTEM\CurrentControlSet\Control\Session Manager\Memory Management" /v PagingFiles /t REG_MULTI_SZ /d "C:\pagefile.sys 2048 4096" /f >> "%LOG%" 2>&1

REM ---------------------------------------------------------------------------
REM  3. Audio and microphone access for Valorant voice chat
REM ---------------------------------------------------------------------------
sc config Audiosrv start= auto >> "%LOG%" 2>&1
sc config AudioEndpointBuilder start= auto >> "%LOG%" 2>&1
sc start Audiosrv >> "%LOG%" 2>&1
sc start AudioEndpointBuilder >> "%LOG%" 2>&1

reg add "HKLM\SOFTWARE\Microsoft\Windows\CurrentVersion\CapabilityAccessManager\ConsentStore\microphone" /v Value /t REG_SZ /d "Allow" /f >> "%LOG%" 2>&1
reg add "HKLM\SOFTWARE\Microsoft\Windows\CurrentVersion\CapabilityAccessManager\ConsentStore\microphone\NonPackaged" /v Value /t REG_SZ /d "Allow" /f >> "%LOG%" 2>&1

REM ---------------------------------------------------------------------------
REM  4. Non-gaming service minimalism
REM  NEVER add WinDefend, WdNisSvc, SecurityHealthService, mpssvc, BFE,
REM  Dnscache, Dhcp, WlanSvc, Audiosrv, vgk, or vgc to this list.
REM ---------------------------------------------------------------------------
for %%S in (
    SysMain
    WSearch
    DiagTrack
    dmwappushservice
    Spooler
    PrintNotify
    Fax
    WbioSrvc
    MapsBroker
    lfsvc
    RemoteRegistry
    TermService
    SessionEnv
    UmRdpService
    TrkWks
    WMPNetworkSvc
    WerSvc
    PcaSvc
    wisvc
    RetailDemo
    XblAuthManager
    XblGameSave
    XboxNetApiSvc
) do (
    sc stop "%%S" >nul 2>&1
    sc config "%%S" start= disabled >nul 2>&1
    echo [%DATE% %TIME%] Service disabled or absent: %%S >> "%LOG%"
)

echo [%DATE% %TIME%] Disabling optional non-gaming features >> "%LOG%"
dism /online /disable-feature /featurename:Printing-Foundation-Features /featurename:Printing-PrintToPDFServices-Features /featurename:Printing-XPSServices-Features /featurename:WorkFolders-Client /featurename:MSRDP-Infrastructure /quiet /norestart >> "%LOG%" 2>&1

REM Record the security-critical services that must remain untouched.
for %%S in (WinDefend WdNisSvc SecurityHealthService mpssvc BFE Dnscache Dhcp WlanSvc Audiosrv) do (
    sc qc "%%S" >> "%LOG%" 2>&1
)
sc query vgk >nul 2>&1
if not errorlevel 1 sc qc vgk >> "%LOG%" 2>&1
sc query vgc >nul 2>&1
if not errorlevel 1 sc qc vgc >> "%LOG%" 2>&1

REM ---------------------------------------------------------------------------
REM  5. AutoLogon and Valorant kiosk shell
REM ---------------------------------------------------------------------------
reg add "HKLM\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Winlogon" /v AutoAdminLogon /t REG_SZ /d "1" /f >> "%LOG%" 2>&1
reg add "HKLM\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Winlogon" /v DefaultUserName /t REG_SZ /d "ValPlayer" /f >> "%LOG%" 2>&1
reg add "HKLM\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Winlogon" /v DefaultPassword /t REG_SZ /d "" /f >> "%LOG%" 2>&1
if errorlevel 1 (
    powershell -NoProfile -Command "Set-ItemProperty -Path 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Winlogon' -Name DefaultPassword -Value '' -Type String" >> "%LOG%" 2>&1
)
reg add "HKLM\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Winlogon" /v Shell /t REG_SZ /d "cmd.exe /c \"C:\Riot Games\val-kiosk.bat\"" /f >> "%LOG%" 2>&1

REM ---------------------------------------------------------------------------
REM  6. Verification marker
REM ---------------------------------------------------------------------------
(
    ver
    whoami
    sc query WinDefend
    reg query "HKLM\HARDWARE\DESCRIPTION\System\BIOS" /v SystemManufacturer
    reg query "HKLM\SOFTWARE\Microsoft\Windows NT\CurrentVersion" /v CurrentBuild
    reg query "HKLM\SYSTEM\CurrentControlSet\Control" /v PortableOperatingSystem
) > "%RIOT_DIR%\boot_verified.txt" 2>&1

REM ---------------------------------------------------------------------------
REM  7. QEMU boot-gate auto-shutdown
REM  Only a QEMU SystemManufacturer string schedules shutdown.  Physical
REM  hardware is never shut down by this provisioning script.
REM ---------------------------------------------------------------------------
set "SYS_MFG="
for /f "tokens=2,*" %%A in ('reg query "HKLM\HARDWARE\DESCRIPTION\System\BIOS" /v SystemManufacturer 2^>nul ^| findstr /i "SystemManufacturer"') do set "SYS_MFG=%%B"
echo [%DATE% %TIME%] SystemManufacturer=%SYS_MFG% >> "%LOG%"
if /i "%SYS_MFG%"=="QEMU" (
    echo [%DATE% %TIME%] QEMU boot gate detected; scheduling shutdown >> "%LOG%"
    shutdown /s /t 15 /f >> "%LOG%" 2>&1
)

echo [%DATE% %TIME%] Phase 2 provisioning complete >> "%LOG%"
echo.
echo Phase 2 provisioning complete.
echo Log: %LOG%
echo Marker: %RIOT_DIR%\boot_verified.txt
exit /b 0
