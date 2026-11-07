#!/usr/bin/env bash
# Phase 2 verification gate: payload syntax, CRLF endings, staged EFI, and
# injected WIM contents.

set -Eeuo pipefail
IFS=$'\n\t'

PROJECT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
readonly PROJECT_ROOT

readonly PAYLOAD_DIR="${PROJECT_ROOT}/payloads"
readonly WIM="${PROJECT_ROOT}/build/custom_install.wim"
readonly EFI_STAGED="${PROJECT_ROOT}/build/efi_staged"
readonly LOG_DIR="${PROJECT_ROOT}/build/logs"
readonly LOG="${LOG_DIR}/test_02_payloads.log"
readonly EXTRACT_DIR="${PROJECT_ROOT}/build/phase02_extract_verify"

readonly XML="${PAYLOAD_DIR}/autounattend.xml"
readonly SETUP_CMD="${PAYLOAD_DIR}/sd_survival_and_kiosk.cmd"
readonly KIOSK_BAT="${PAYLOAD_DIR}/val-kiosk.bat"
readonly SWITCH_BAT="${PAYLOAD_DIR}/switch-mode.bat"
readonly KB_CAB="${PAYLOAD_DIR}/windows10.0-kb5015684-x64.cab"

mkdir -p "$LOG_DIR"
: > "$LOG"
exec > >(tee -a "$LOG") 2>&1

PASS=0
FAIL=0
FAILED_CHECKS=()

pass() {
    PASS=$((PASS + 1))
    printf '[PASS] %s: %s\n' "$1" "$2"
}

fail() {
    FAIL=$((FAIL + 1))
    FAILED_CHECKS+=("$1")
    printf '[FAIL] %s: %s\n' "$1" "$2"
}

trap 'rc=$?; if (( rc != 0 )); then printf "[FAIL] phase02 test harness aborted unexpectedly (exit %s) at line %s\n" "$rc" "$LINENO" >&2; fi' ERR

contains() {
    local id="$1" file="$2" needle="$3"
    if [[ -f "$file" ]] && grep -Fq -- "$needle" "$file"; then
        pass "$id" "found in $(basename "$file"): $needle"
    else
        fail "$id" "missing from $(basename "$file"): $needle"
    fi
}

# ---------------------------------------------------------------------------
# XML and CRLF validation
# ---------------------------------------------------------------------------
if [[ -f "$XML" ]] && xmllint --noout "$XML" >/dev/null 2>"${LOG_DIR}/phase02_xmllint.err"; then
    pass "xml-well-formed" "xmllint --noout accepted autounattend.xml"
else
    fail "xml-well-formed" "autounattend.xml is missing or malformed"
fi

mapfile -d '' BATCH_FILES < <(
    find "$PAYLOAD_DIR" -maxdepth 1 -type f \
        \( -iname '*.bat' -o -iname '*.cmd' \) -print0 | sort -z
)
if (( ${#BATCH_FILES[@]} == 0 )); then
    fail "crlf-payloads" "no .bat/.cmd payloads found"
fi

for file in "${BATCH_FILES[@]}"; do
    id="crlf-$(basename "$file")"
    if python3 - "$file" <<'PY'
import sys
data = open(sys.argv[1], "rb").read()
if not data or b"\r\n" not in data:
    raise SystemExit(1)
remainder = data.replace(b"\r\n", b"")
if b"\n" in remainder or b"\r" in remainder:
    raise SystemExit(1)
PY
    then
        pass "$id" "pure CRLF line endings"
    else
        fail "$id" "missing CRLF or contains bare LF/CR"
    fi
done

# ---------------------------------------------------------------------------
# Staged EFI and WIM existence
# ---------------------------------------------------------------------------
if [[ -f "$EFI_STAGED/bootmgfw.efi" ]]; then
    pass "efi-staged" "bootmgfw.efi is staged at $EFI_STAGED/bootmgfw.efi"
else
    fail "efi-staged" "bootmgfw.efi is not staged under $EFI_STAGED"
fi

if [[ -f "$WIM" ]]; then
    pass "wim-exists" "$WIM"
else
    fail "wim-exists" "missing $WIM"
fi

check_wim_path() {
    local id="$1" path="$2" out
    if [[ ! -f "$WIM" ]]; then
        fail "$id" "WIM missing"
        return
    fi
    if out="$(wimlib-imagex dir "$WIM" 1 --path="$path" 2>&1)"; then
        if grep -Fxq -- "$path" <<<"$out"; then
            pass "$id" "present in WIM: $path"
        else
            fail "$id" "path not found in WIM listing: $path"
        fi
    else
        fail "$id" "wimlib-imagex could not find $path"
    fi
}

check_wim_path "wim-unattend" "/Windows/Panther/unattend.xml"
check_wim_path "wim-setup-cmd" "/Riot Games/sd_survival_and_kiosk.cmd"
check_wim_path "wim-kiosk-bat" "/Riot Games/val-kiosk.bat"
check_wim_path "wim-switch-bat" "/Riot Games/switch-mode.bat"
check_wim_path "wim-kb-cab" "/Riot Games/windows10.0-kb5015684-x64.cab"

# ---------------------------------------------------------------------------
# Verify the injected bytes match the normalized payloads
# ---------------------------------------------------------------------------
rm -rf -- "$EXTRACT_DIR"
mkdir -p "$EXTRACT_DIR"
if [[ -f "$WIM" ]] && wimlib-imagex extract "$WIM" 1 \
    '/Windows/Panther/unattend.xml' \
    '/Riot Games/sd_survival_and_kiosk.cmd' \
    '/Riot Games/val-kiosk.bat' \
    '/Riot Games/switch-mode.bat' \
    '/Riot Games/windows10.0-kb5015684-x64.cab' \
    --dest-dir="$EXTRACT_DIR" \
    > "${LOG_DIR}/phase02_extract.log" 2>&1
then
    content_ok=1
    cmp -s -- "$XML" "$EXTRACT_DIR/unattend.xml" || content_ok=0
    cmp -s -- "$SETUP_CMD" "$EXTRACT_DIR/sd_survival_and_kiosk.cmd" || content_ok=0
    cmp -s -- "$KIOSK_BAT" "$EXTRACT_DIR/val-kiosk.bat" || content_ok=0
    cmp -s -- "$SWITCH_BAT" "$EXTRACT_DIR/switch-mode.bat" || content_ok=0
    cmp -s -- "$KB_CAB" "$EXTRACT_DIR/windows10.0-kb5015684-x64.cab" || content_ok=0
    if (( content_ok )); then
        pass "wim-content" "all five injected files match their payload bytes"
    else
        fail "wim-content" "one or more injected files differ from the payloads"
    fi
else
    fail "wim-content" "could not extract injected files for comparison"
fi

# ---------------------------------------------------------------------------
# Autounattend requirements
# ---------------------------------------------------------------------------
contains "xml-valplayer" "$XML" "ValPlayer"
contains "xml-firstlogon" "$XML" "FirstLogonCommands"
contains "xml-provision-command" "$XML" "sd_survival_and_kiosk.cmd"
contains "xml-autologon" "$XML" "AutoLogon"
contains "xml-admin-group" "$XML" "Administrators"
contains "xml-skip-oobe" "$XML" "SkipMachineOOBE"

# ---------------------------------------------------------------------------
# First-logon provisioning requirements
# ---------------------------------------------------------------------------
contains "payload-kb-install" "$SETUP_CMD" "dism /online /add-package /packagepath:\"C:\Riot Games\windows10.0-kb5015684-x64.cab\" /quiet /norestart"
contains "payload-build-display" "$SETUP_CMD" "/v DisplayVersion /t REG_SZ /d \"22H2\""
contains "payload-build-release" "$SETUP_CMD" "/v ReleaseId /t REG_SZ /d \"2009\""
contains "payload-build-current" "$SETUP_CMD" "/v CurrentBuild /t REG_SZ /d \"19045\""
contains "payload-build-number" "$SETUP_CMD" "/v CurrentBuildNumber /t REG_SZ /d \"19045\""
contains "payload-compactos" "$SETUP_CMD" "compact.exe /CompactOS:always"
contains "payload-hibernation" "$SETUP_CMD" "powercfg -h off"
contains "payload-lastaccess" "$SETUP_CMD" "fsutil behavior set disablelastaccess 1"
contains "payload-8dot3" "$SETUP_CMD" "fsutil 8dot3name set 1"
contains "payload-pagefile" "$SETUP_CMD" "PagingFiles /t REG_MULTI_SZ /d \"C:\pagefile.sys 2048 4096\""
contains "payload-mic" "$SETUP_CMD" "ConsentStore\microphone\NonPackaged"
contains "payload-autologon" "$SETUP_CMD" "/v AutoAdminLogon /t REG_SZ /d \"1\""
contains "payload-username" "$SETUP_CMD" "/v DefaultUserName /t REG_SZ /d \"ValPlayer\""
contains "payload-shell" "$SETUP_CMD" 'cmd.exe /c \"C:\Riot Games\val-kiosk.bat\"'
contains "payload-marker" "$SETUP_CMD" "boot_verified.txt"

SERVICES=(
    SysMain WSearch DiagTrack dmwappushservice Spooler PrintNotify Fax
    WbioSrvc MapsBroker lfsvc RemoteRegistry TermService SessionEnv
    UmRdpService TrkWks WMPNetworkSvc WerSvc PcaSvc wisvc RetailDemo
    XblAuthManager XblGameSave XboxNetApiSvc
)
missing_services=()
for svc in "${SERVICES[@]}"; do
    grep -Fq -- "$svc" "$SETUP_CMD" || missing_services+=("$svc")
done
if (( ${#missing_services[@]} == 0 )); then
    pass "payload-23-services" "all 23 non-gaming services are present in the disable loop"
else
    fail "payload-23-services" "missing service names: ${missing_services[*]}"
fi

CRITICAL=(WinDefend WdNisSvc SecurityHealthService mpssvc BFE Dnscache Dhcp WlanSvc Audiosrv vgk vgc)
critical_disabled=()
for svc in "${CRITICAL[@]}"; do
    if grep -Eiq "sc[[:space:]]+config[[:space:]]+\"?${svc}\"?[[:space:]]+start=[[:space:]]*disabled" "$SETUP_CMD"; then
        critical_disabled+=("$svc")
    fi
done
if (( ${#critical_disabled[@]} == 0 )); then
    pass "payload-critical-services" "no Vanguard/Defender/network/audio service is disabled"
else
    fail "payload-critical-services" "critical services disabled: ${critical_disabled[*]}"
fi

FEATURES=(
    Printing-Foundation-Features
    Printing-PrintToPDFServices-Features
    Printing-XPSServices-Features
    WorkFolders-Client
    MSRDP-Infrastructure
)
missing_features=()
for feature in "${FEATURES[@]}"; do
    grep -Fq -- "$feature" "$SETUP_CMD" || missing_features+=("$feature")
done
if (( ${#missing_features[@]} == 0 )); then
    pass "payload-optional-features" "all five non-gaming optional features are targeted"
else
    fail "payload-optional-features" "missing features: ${missing_features[*]}"
fi

# ---------------------------------------------------------------------------
# Kiosk + switch-mode requirements
# ---------------------------------------------------------------------------
contains "kiosk-vgtray" "$KIOSK_BAT" "C:\Program Files\Riot Vanguard\vgtray.exe"
contains "kiosk-client" "$KIOSK_BAT" "C:\Riot Games\Riot Client\RiotClientServices.exe"
contains "kiosk-launch" "$KIOSK_BAT" "--launch-product=valorant --launch-patchline=live"
contains "kiosk-relaunch-menu" "$KIOSK_BAT" "[1] Relaunch Valorant"
contains "kiosk-network-menu" "$KIOSK_BAT" "ms-settings:network-wifi"
contains "kiosk-audio-menu" "$KIOSK_BAT" "control.exe mmsys.cpl sounds"
contains "kiosk-desktop-menu" "$KIOSK_BAT" "start \"\" explorer.exe"
contains "kiosk-reboot-menu" "$KIOSK_BAT" "shutdown /r /t 0"
contains "kiosk-shutdown-menu" "$KIOSK_BAT" "shutdown /s /t 0"
contains "kiosk-diskmgmt" "$KIOSK_BAT" "diskmgmt.msc"
contains "kiosk-offline" "$KIOSK_BAT" "Offline"
contains "kiosk-drivers" "$KIOSK_BAT" "GPU and Wi-Fi drivers"
contains "kiosk-valorant-install" "$KIOSK_BAT" "Install Valorant into C:\Riot Games"
contains "kiosk-reboot-instruction" "$KIOSK_BAT" "Reboot back into this microSD card"

contains "switch-kiosk" "$SWITCH_BAT" "--kiosk"
contains "switch-desktop" "$SWITCH_BAT" "--desktop"
contains "switch-explorer" "$SWITCH_BAT" "explorer.exe"
contains "switch-kiosk-path" "$SWITCH_BAT" "val-kiosk.bat"

# ---------------------------------------------------------------------------
# Summary
# ---------------------------------------------------------------------------
printf '\nPassed: %d  Failed: %d\n' "$PASS" "$FAIL"
if (( FAIL > 0 )); then
    printf '[FAIL] Phase 2 verification gate failed: %s\n' "${FAILED_CHECKS[*]}"
    exit 1
fi
printf '[PASS] Phase 2 verification gate passed\n'
