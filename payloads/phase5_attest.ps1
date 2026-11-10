#requires -Version 5.1
<#
.SYNOPSIS
    Valorant Console OS - Phase 5 bare-metal attestation collector.

.DESCRIPTION
    Runs on the booted microSD card and writes a JSON evidence report to
    C:\Riot Games\phase5_attestation.json.  The report is validated on the
    Linux host by scripts/05_attest_baremetal.sh.

    This script only reads security state.  It never disables, stops, patches,
    or reconfigures Defender, TPM, Secure Boot, code integrity, or Vanguard.

.NOTES
    Must run elevated.  If launched from a non-elevated shell it relaunches
    itself through UAC.
#>
[CmdletBinding()]
param(
    [string]$OutputDirectory = "C:\Riot Games"
)

$ErrorActionPreference = "Stop"
$collectorVersion = "1.0.0"
$expectedShell = 'cmd.exe /c "C:\Riot Games\val-kiosk.bat"'

function Test-IsElevated {
    $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = New-Object Security.Principal.WindowsPrincipal($identity)
    return $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

if (-not (Test-IsElevated)) {
    Write-Host "Phase 5 attestation needs administrator rights; requesting elevation..." -ForegroundColor Yellow
    try {
        $arguments = @(
            "-NoProfile",
            "-ExecutionPolicy", "Bypass",
            "-File", ('"{0}"' -f $PSCommandPath)
        )
        $elevated = Start-Process -FilePath "powershell.exe" -Verb RunAs -ArgumentList $arguments -Wait -PassThru
        exit $elevated.ExitCode
    }
    catch {
        Write-Host "Elevation failed: $($_.Exception.Message)" -ForegroundColor Red
        exit 1
    }
}

function Get-RegistryValue {
    param(
        [string]$Path,
        [string]$Name,
        $Default = $null
    )
    try {
        $item = Get-ItemProperty -Path $Path -Name $Name -ErrorAction Stop
        return $item.$Name
    }
    catch {
        return $Default
    }
}

function Get-ServiceState {
    param([string]$Name)
    try {
        $service = Get-Service -Name $Name -ErrorAction Stop
        return [string]$service.Status
    }
    catch {
        return "NotFound"
    }
}

function Get-ServiceExecutable {
    param([string]$Name)
    try {
        $service = Get-CimInstance -ClassName Win32_Service -Filter ("Name='{0}'" -f $Name) -ErrorAction Stop
        $pathName = [string]$service.PathName
        if ([string]::IsNullOrWhiteSpace($pathName)) { return "" }
        if ($pathName -match '^\s*"([^"]+)"') { return $matches[1] }
        return ($pathName -split '\s+')[0]
    }
    catch {
        return ""
    }
}

function Get-FileSignatureInfo {
    param([string]$Path)
    $info = [ordered]@{
        path = $Path
        present = $false
        status = "Missing"
        signer = ""
    }
    if ([string]::IsNullOrWhiteSpace($Path)) { return $info }
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { return $info }
    $info.present = $true
    try {
        $signature = Get-AuthenticodeSignature -LiteralPath $Path -ErrorAction Stop
        $info.status = [string]$signature.Status
        if ($null -ne $signature.SignerCertificate) {
            $info.signer = [string]$signature.SignerCertificate.Subject
        }
    }
    catch {
        $info.status = "Error"
    }
    return $info
}

function Normalize-Guid {
    param($Guid)
    if ($null -eq $Guid) { return "" }
    $text = [string]$Guid
    $text = $text.Trim([char[]]@('{', '}')).Replace("-", "").ToLowerInvariant()
    return $text
}

function Resolve-DriverPath {
    param([string]$PathName)
    if ([string]::IsNullOrWhiteSpace($PathName)) { return "" }
    $path = $PathName
    if ($path.StartsWith('\??\')) { $path = $path.Substring(4) }
    if ($path.StartsWith('\SystemRoot\')) {
        $path = Join-Path $env:SystemRoot $path.Substring(12)
    }
    return [Environment]::ExpandEnvironmentVariables($path)
}

$collectedAt = (Get-Date).ToUniversalTime()
$collectedAtUtc = $collectedAt.ToString("yyyy-MM-ddTHH:mm:ssZ")

# ---------------------------------------------------------------------------
# Operating system and firmware
# ---------------------------------------------------------------------------
$os = Get-CimInstance -ClassName Win32_OperatingSystem -ErrorAction Stop
$computerSystem = Get-CimInstance -ClassName Win32_ComputerSystem -ErrorAction Stop
$bios = Get-CimInstance -ClassName Win32_BIOS -ErrorAction Stop
$currentVersion = Get-ItemProperty -Path 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion' -ErrorAction SilentlyContinue

$firmwareType = ""
try {
    $firmwareType = [string](Get-ComputerInfo -Property BiosFirmwareType -ErrorAction Stop).BiosFirmwareType
}
catch {
    $firmwareType = ""
}

$portableOperatingSystem = [int](Get-RegistryValue 'HKLM:\SYSTEM\CurrentControlSet\Control' 'PortableOperatingSystem' 0)

# ---------------------------------------------------------------------------
# Secure Boot
# ---------------------------------------------------------------------------
$secureBootEnabled = $false
$secureBootSetupMode = $true
try {
    $secureBootEnabled = [bool](Confirm-SecureBootUEFI -ErrorAction Stop)
}
catch {
    $secureBootEnabled = $false
}
try {
    $setupMode = Get-SecureBootUEFI -Name SetupMode -ErrorAction Stop
    if ($null -ne $setupMode.Bytes -and $setupMode.Bytes.Length -gt 0) {
        $secureBootSetupMode = ([byte[]]$setupMode.Bytes)[0] -ne 0
    }
}
catch {
    $secureBootSetupMode = $true
}

# ---------------------------------------------------------------------------
# TPM 2.0
# ---------------------------------------------------------------------------
$tpmPresent = $false
$tpmReady = $false
$tpmEnabled = $false
$tpmActivated = $false
$tpmOwned = $false
$tpmSpecVersion = ""
$tpmManufacturerId = ""
$tpmManufacturerVersion = ""
$ekPublicKeyHashSha256 = ""

try {
    $tpm = Get-Tpm -ErrorAction Stop
    $tpmPresent = [bool]$tpm.TpmPresent
    $tpmReady = [bool]$tpm.TpmReady
    $tpmEnabled = [bool]$tpm.TpmEnabled
    $tpmActivated = [bool]$tpm.TpmActivated
    $tpmOwned = [bool]$tpm.TpmOwned
    $tpmSpecVersion = [string]$tpm.SpecVersion
    $tpmManufacturerId = [string]$tpm.ManufacturerId
    $tpmManufacturerVersion = [string]$tpm.ManufacturerVersion
}
catch {
    $tpmPresent = $false
}

try {
    $ek = Get-TpmEndorsementKeyInfo -HashAlgorithm Sha256 -ErrorAction Stop
    if ($null -ne $ek.PublicKeyHash) {
        if ($ek.PublicKeyHash -is [byte[]]) {
            $ekBytes = [byte[]]$ek.PublicKeyHash
            $ekPublicKeyHashSha256 = (($ekBytes | ForEach-Object { $_.ToString("x2") }) -join "")
        }
        else {
            # Some TPM modules expose the hash as an already-formatted string.
            $ekText = ([string]$ek.PublicKeyHash).Trim().ToLowerInvariant()
            if ($ekText -match '^[0-9a-f]{64}$') {
                $ekPublicKeyHashSha256 = $ekText
            }
        }
    }
}
catch {
    $ekPublicKeyHashSha256 = ""
}

# ---------------------------------------------------------------------------
# Defender and Security Health
# ---------------------------------------------------------------------------
$mpStatus = $null
try {
    $mpStatus = Get-MpComputerStatus -ErrorAction Stop
}
catch {
    $mpStatus = $null
}

$defenderSignatureAge = -1
$defenderSignatureVersion = ""
$defenderAmService = $false
$defenderAntivirus = $false
$defenderRealtime = $false
$defenderTamper = $false
if ($null -ne $mpStatus) {
    if ($null -ne $mpStatus.AntivirusSignatureAge) {
        $defenderSignatureAge = [int]$mpStatus.AntivirusSignatureAge
    }
    $defenderSignatureVersion = [string]$mpStatus.AntivirusSignatureVersion
    $defenderAmService = [bool]$mpStatus.AMServiceEnabled
    $defenderAntivirus = [bool]$mpStatus.AntivirusEnabled
    $defenderRealtime = [bool]$mpStatus.RealTimeProtectionEnabled
    $defenderTamper = [bool]$mpStatus.IsTamperProtected
}

$winDefendState = Get-ServiceState "WinDefend"
$securityHealthState = Get-ServiceState "SecurityHealthService"

# ---------------------------------------------------------------------------
# Code integrity and HVCI state
# ---------------------------------------------------------------------------
$ciDllPresent = Test-Path -LiteralPath (Join-Path $env:SystemRoot "System32\ci.dll") -PathType Leaf
$tpmSysPresent = Test-Path -LiteralPath (Join-Path $env:SystemRoot "System32\drivers\tpm.sys") -PathType Leaf

$bcdOutput = ""
try {
    $bcdOutput = (& bcdedit.exe /enum "{current}" 2>&1 | Out-String)
}
catch {
    $bcdOutput = ""
}
$testSigningEnabled = [bool]($bcdOutput -match '(?im)^\s*testsigning\s+Yes\s*$')
$kernelDebugEnabled = [bool]($bcdOutput -match '(?im)^\s*debug\s+Yes\s*$')

$driverBlocklistValue = [int](Get-RegistryValue 'HKLM:\SYSTEM\CurrentControlSet\Control\CI\Config' 'VulnerableDriverBlocklistEnable' 1)
$disableIntegrityValue = [int](Get-RegistryValue 'HKLM:\SYSTEM\CurrentControlSet\Control\CI' 'DisableIntegrityChecks' 0)
$driverBlocklistEnabled = ($driverBlocklistValue -ne 0)
$integrityChecksDisabled = ($disableIntegrityValue -ne 0)

$deviceGuard = $null
try {
    $deviceGuard = Get-CimInstance -Namespace 'root\Microsoft\Windows\DeviceGuard' -ClassName Win32_DeviceGuard -ErrorAction Stop
}
catch {
    $deviceGuard = $null
}

$hvciRunning = $false
$hvciConfigured = $false
$vbsStatus = 0
if ($null -ne $deviceGuard) {
    $hvciRunning = [bool]($deviceGuard.SecurityServicesRunning -contains 2)
    $hvciConfigured = [bool]($deviceGuard.SecurityServicesConfigured -contains 2)
    $vbsStatus = [int]$deviceGuard.VirtualizationBasedSecurityStatus
}
if ($hvciRunning) {
    $hvciStatus = "running"
}
elseif ($hvciConfigured) {
    $hvciStatus = "configured"
}
else {
    $hvciStatus = "not-enabled"
}

$hvciPolicyValue = [int](Get-RegistryValue 'HKLM:\SYSTEM\CurrentControlSet\Control\DeviceGuard\Scenarios\HypervisorEnforcedCodeIntegrity' 'Enabled' 1)
$vbsPolicyValue = [int](Get-RegistryValue 'HKLM:\SYSTEM\CurrentControlSet\Control\DeviceGuard' 'EnableVirtualizationBasedSecurity' 1)
$hvciPolicyDisabled = (($hvciPolicyValue -eq 0) -or ($vbsPolicyValue -eq 0))

# ---------------------------------------------------------------------------
# Vanguard services, driver, and signatures
# ---------------------------------------------------------------------------
$vgkServiceState = Get-ServiceState "vgk"
$vgcServiceState = Get-ServiceState "vgc"
$vgkDriver = $null
try {
    $vgkDriver = Get-CimInstance -ClassName Win32_SystemDriver -Filter "Name='vgk'" -ErrorAction Stop
}
catch {
    $vgkDriver = $null
}
# vgk is a kernel-mode driver service.  Get-Service only enumerates Win32
# services on some Windows builds, so the driver state is authoritative.
if ($null -ne $vgkDriver) {
    $vgkServiceState = [string]$vgkDriver.State
}
$vgkDriverLoaded = [bool]($null -ne $vgkDriver -and $vgkDriver.State -eq "Running")

$vgkPath = ""
if ($null -ne $vgkDriver) {
    $vgkPath = Resolve-DriverPath ([string]$vgkDriver.PathName)
}
if ([string]::IsNullOrWhiteSpace($vgkPath) -or -not (Test-Path -LiteralPath $vgkPath -PathType Leaf)) {
    $vgkCandidates = @(
        (Join-Path $env:ProgramFiles "Riot Vanguard\vgk.sys"),
        (Join-Path $env:SystemRoot "System32\drivers\vgk.sys")
    )
    foreach ($candidate in $vgkCandidates) {
        if (Test-Path -LiteralPath $candidate -PathType Leaf) {
            $vgkPath = $candidate
            break
        }
    }
}

$vgcPath = Get-ServiceExecutable "vgc"
if ([string]::IsNullOrWhiteSpace($vgcPath) -or -not (Test-Path -LiteralPath $vgcPath -PathType Leaf)) {
    $vgcCandidates = @(
        (Join-Path $env:ProgramFiles "Riot Vanguard\vgc.exe")
    )
    foreach ($candidate in $vgcCandidates) {
        if (Test-Path -LiteralPath $candidate -PathType Leaf) {
            $vgcPath = $candidate
            break
        }
    }
}

$vgkSignature = Get-FileSignatureInfo $vgkPath
$vgcSignature = Get-FileSignatureInfo $vgcPath
$vanguardInstalled = (($vgkServiceState -ne "NotFound") -or ($vgcServiceState -ne "NotFound") -or $vgkSignature.present)

# ---------------------------------------------------------------------------
# Kiosk and first-boot marker
# ---------------------------------------------------------------------------
$winlogon = Get-ItemProperty -Path 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Winlogon' -ErrorAction SilentlyContinue
$kioskShell = ""
$kioskUser = ""
$autoAdminLogon = 0
if ($null -ne $winlogon) {
    $kioskShell = [string]$winlogon.Shell
    $kioskUser = [string]$winlogon.DefaultUserName
    if ($null -ne $winlogon.AutoAdminLogon) {
        $autoAdminLogon = [int]$winlogon.AutoAdminLogon
    }
}

$bootMarkerPath = Join-Path $OutputDirectory "boot_verified.txt"
$bootMarkerPresent = Test-Path -LiteralPath $bootMarkerPath -PathType Leaf
$bootMarkerHash = ""
if ($bootMarkerPresent) {
    try {
        $bootMarkerHash = (Get-FileHash -LiteralPath $bootMarkerPath -Algorithm SHA256 -ErrorAction Stop).Hash.ToLowerInvariant()
    }
    catch {
        $bootMarkerHash = ""
    }
}

# ---------------------------------------------------------------------------
# System volume and physical boot medium
# ---------------------------------------------------------------------------
$systemDrive = $env:SystemDrive.TrimEnd(':')
$diskGuid = ""
$partitionGuid = ""
$diskSerial = ""
$diskBusType = ""
$diskModel = ""
$diskSize = 0
$partitionIsBoot = $false
$partitionIsSystem = $false
$volumeFileSystem = ""

try {
    $partition = Get-Partition -DriveLetter $systemDrive -ErrorAction Stop
    $disk = Get-Disk -Number $partition.DiskNumber -ErrorAction Stop
    $volume = Get-Volume -DriveLetter $systemDrive -ErrorAction Stop
    $diskGuid = Normalize-Guid $disk.Guid
    $partitionGuid = Normalize-Guid $partition.Guid
    $diskSerial = [string]$disk.SerialNumber
    $diskBusType = [string]$disk.BusType
    $diskModel = [string]$disk.FriendlyName
    $diskSize = [long]$disk.Size
    $partitionIsBoot = [bool]$partition.IsBoot
    $partitionIsSystem = [bool]$partition.IsSystem
    $volumeFileSystem = [string]$volume.FileSystem
}
catch {
    $diskBusType = ""
}

$bootedFromRemovableMedia = [bool]($diskBusType -match '^(USB|SD|MMC|Secure Digital)')

# ---------------------------------------------------------------------------
# Bare-metal detection
# ---------------------------------------------------------------------------
$manufacturer = [string]$computerSystem.Manufacturer
$model = [string]$computerSystem.Model
$biosManufacturer = [string]$bios.Manufacturer
$biosVersion = [string]$bios.SMBIOSBIOSVersion
$virtualPattern = '(?i)(qemu|vmware|virtualbox|vbox|innotek|xen|hvm domu|hyper-v|parallels|bochs|openstack|kubevirt|amazon ec2|google compute|digitalocean|microsoft corporation virtual|virtual machine|kvm|bhyve|virtio|cloud hypervisor|firecracker)'
$isVirtual = [bool](
    ($manufacturer -match $virtualPattern) -or
    ($model -match $virtualPattern) -or
    ($biosManufacturer -match $virtualPattern)
)
$isBareMetal = (
    (-not $isVirtual) -and
    (-not [string]::IsNullOrWhiteSpace($manufacturer)) -and
    (-not [string]::IsNullOrWhiteSpace($model))
)

# ---------------------------------------------------------------------------
# Report
# ---------------------------------------------------------------------------
$report = [ordered]@{
    schemaVersion = 1
    collectorVersion = $collectorVersion
    reportId = [guid]::NewGuid().ToString()
    collectedAtUtc = $collectedAtUtc
    isElevated = $true
    os = [ordered]@{
        productName = [string]$os.Caption
        build = [string]$os.BuildNumber
        displayVersion = ""
        architecture = [string]$os.OSArchitecture
        firmwareType = $firmwareType
        portableOperatingSystem = ($portableOperatingSystem -eq 1)
        bootedFromRemovableMedia = $bootedFromRemovableMedia
        computerName = [string]$env:COMPUTERNAME
        userName = [string]$env:USERNAME
    }
    firmware = [ordered]@{
        secureBootEnabled = $secureBootEnabled
        secureBootSetupMode = $secureBootSetupMode
    }
    tpm = [ordered]@{
        present = $tpmPresent
        ready = $tpmReady
        enabled = $tpmEnabled
        activated = $tpmActivated
        owned = $tpmOwned
        specVersion = $tpmSpecVersion
        manufacturerId = $tpmManufacturerId
        manufacturerVersion = $tpmManufacturerVersion
        ekPublicKeyHashSha256 = $ekPublicKeyHashSha256
    }
    defender = [ordered]@{
        serviceState = $winDefendState
        securityHealthServiceState = $securityHealthState
        amServiceEnabled = $defenderAmService
        antivirusEnabled = $defenderAntivirus
        realTimeProtectionEnabled = $defenderRealtime
        tamperProtectionEnabled = $defenderTamper
        signatureAgeDays = $defenderSignatureAge
        signatureVersion = $defenderSignatureVersion
    }
    codeIntegrity = [ordered]@{
        ciDllPresent = $ciDllPresent
        tpmSysPresent = $tpmSysPresent
        testSigningEnabled = $testSigningEnabled
        kernelDebugEnabled = $kernelDebugEnabled
        driverBlocklistEnabled = $driverBlocklistEnabled
        integrityChecksDisabled = $integrityChecksDisabled
        hvciStatus = $hvciStatus
        hvciPolicyDisabled = $hvciPolicyDisabled
        vbsStatus = $vbsStatus
    }
    vanguard = [ordered]@{
        installed = $vanguardInstalled
        vgkServiceState = $vgkServiceState
        vgcServiceState = $vgcServiceState
        vgkDriverLoaded = $vgkDriverLoaded
        vgkPath = $vgkSignature.path
        vgkFilePresent = $vgkSignature.present
        vgkSignatureStatus = $vgkSignature.status
        vgkSigner = $vgkSignature.signer
        vgcPath = $vgcSignature.path
        vgcFilePresent = $vgcSignature.present
        vgcSignatureStatus = $vgcSignature.status
        vgcSigner = $vgcSignature.signer
    }
    kiosk = [ordered]@{
        shell = $kioskShell
        expectedShell = $expectedShell
        user = $kioskUser
        autoAdminLogon = $autoAdminLogon
        bootVerifiedMarker = $bootMarkerPresent
        bootVerifiedContentSha256 = $bootMarkerHash
    }
    systemVolume = [ordered]@{
        driveLetter = $systemDrive
        fileSystem = $volumeFileSystem
        diskGuid = $diskGuid
        partitionGuid = $partitionGuid
        diskSerialNumber = $diskSerial
        busType = $diskBusType
        model = $diskModel
        sizeBytes = $diskSize
        isBoot = $partitionIsBoot
        isSystem = $partitionIsSystem
    }
    bareMetal = [ordered]@{
        isBareMetal = $isBareMetal
        isVirtual = $isVirtual
        manufacturer = $manufacturer
        model = $model
        biosManufacturer = $biosManufacturer
        biosVersion = $biosVersion
        hypervisorPresent = [bool]$computerSystem.HypervisorPresent
    }
}

if ($null -ne $currentVersion) {
    $report.os.displayVersion = [string]$currentVersion.DisplayVersion
}

# ---------------------------------------------------------------------------
# Write report and human-readable summary
# ---------------------------------------------------------------------------
if (-not (Test-Path -LiteralPath $OutputDirectory -PathType Container)) {
    New-Item -ItemType Directory -Path $OutputDirectory -Force | Out-Null
}

$jsonPath = Join-Path $OutputDirectory "phase5_attestation.json"
$textPath = Join-Path $OutputDirectory "phase5_attestation.txt"
$json = $report | ConvertTo-Json -Depth 8
$utf8 = New-Object System.Text.UTF8Encoding($false)
[System.IO.File]::WriteAllText($jsonPath, $json, $utf8)

$checks = [ordered]@{
    "secureboot-enabled" = ($secureBootEnabled -and (-not $secureBootSetupMode))
    "tpm-present" = ($tpmPresent -and $tpmReady -and $tpmEnabled -and $tpmActivated)
    "tpm-v2" = ($tpmSpecVersion -like "2.0*")
    "tpm-ek" = ($ekPublicKeyHashSha256 -match '^[0-9a-f]{64}$')
    "defender-service" = (($winDefendState -eq "Running") -and ($securityHealthState -eq "Running"))
    "defender-realtime" = ($defenderAmService -and $defenderAntivirus -and $defenderRealtime)
    "defender-tamper" = $defenderTamper
    "code-integrity-files" = ($ciDllPresent -and $tpmSysPresent)
    "code-integrity-testsigning" = (-not $testSigningEnabled)
    "code-integrity-kernel-debug" = (-not $kernelDebugEnabled)
    "code-integrity-driver-blocklist" = ($driverBlocklistEnabled -and (-not $integrityChecksDisabled))
    "code-integrity-hvci" = (-not $hvciPolicyDisabled)
    "vanguard-service" = (($vgkServiceState -eq "Running") -and ($vgcServiceState -eq "Running"))
    "vanguard-driver" = $vgkDriverLoaded
    "vanguard-signature" = (
        $vgkSignature.present -and ($vgkSignature.status -eq "Valid") -and
        ($vgkSignature.signer -match '(?i)Riot Games') -and
        $vgcSignature.present -and ($vgcSignature.status -eq "Valid") -and
        ($vgcSignature.signer -match '(?i)Riot Games')
    )
    "kiosk-shell" = ($kioskShell.Trim() -ieq $expectedShell)
    "kiosk-marker" = $bootMarkerPresent
    "bare-metal" = $isBareMetal
    "os-boot-media" = $bootedFromRemovableMedia
    "os-portable" = ($portableOperatingSystem -eq 1)
}

$text = New-Object System.Collections.Generic.List[string]
$text.Add("Valorant Console OS - Phase 5 attestation")
$text.Add("Collected: $collectedAtUtc")
$text.Add("Computer: $env:COMPUTERNAME   User: $env:USERNAME")
$text.Add("Report: $jsonPath")
$text.Add("")
$failed = 0
foreach ($key in $checks.Keys) {
    if ($checks[$key]) {
        $text.Add("[PASS] ${key}: true")
    }
    else {
        $text.Add("[FAIL] ${key}: false")
        $failed++
    }
}
$text.Add("")
$text.Add("Passed: $($checks.Count - $failed)  Failed: $failed")
[System.IO.File]::WriteAllLines($textPath, $text.ToArray(), $utf8)

Write-Host ""
Write-Host "Valorant Console OS - Phase 5 attestation" -ForegroundColor Cyan
Write-Host "Report: $jsonPath"
Write-Host ""
foreach ($line in $text) {
    if ($line -like "[PASS]*") { Write-Host $line -ForegroundColor Green }
    elseif ($line -like "[FAIL]*") { Write-Host $line -ForegroundColor Red }
    else { Write-Host $line }
}

if ($failed -gt 0) {
    exit 1
}
exit 0
