#!/usr/bin/env bash
# Phase 5: bare-metal attestation for the Valorant Console OS microSD card.
#
# The target Windows installation runs payloads/phase5_attest.ps1 after boot.
# That collector reads Secure Boot, TPM 2.0, Defender, code-integrity, kiosk,
# and Vanguard state and writes Riot Games/phase5_attestation.json on the card.
# This script mounts the card read-only, validates the report, and binds it to
# the card's GPT GUIDs and first-boot marker.
#
# Modes:
#   --target <dev>            Read and validate the report on the card (root).
#   --target <dev> --prepare --commit
#                             Copy the collector onto the card (root).
#   --report <json>           Validate an offline report (no root).
#
# The script never boots hardware and never weakens a security invariant.

set -Eeuo pipefail
IFS=$'\n\t'

PROJECT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
readonly PROJECT_ROOT

readonly WRITER="${PROJECT_ROOT}/scripts/04_write_sdcard.sh"
readonly COLLECTOR_PS1="${PROJECT_ROOT}/payloads/phase5_attest.ps1"
readonly COLLECTOR_CMD="${PROJECT_ROOT}/payloads/phase5_attest.cmd"
readonly LOG_DIR="${PROJECT_ROOT}/build/logs"
readonly REPORT_REL="Riot Games/phase5_attestation.json"
readonly MARKER_REL="Riot Games/boot_verified.txt"
readonly EXPECTED_SHELL='cmd.exe /c "C:\Riot Games\val-kiosk.bat"'

TARGET=""
REPORT_PATH=""
PREPARE=0
COMMIT=0
ASSUME_YES=0
MAX_AGE_HOURS=72
MAX_SIGNATURE_AGE_DAYS=30

WORK_DIR=""
NTFS_MNT=""
PART2=""
TARGET_BASE=""
UDEV_RULE_FILE=""
NTFS_MOUNTED=0
SUMMARY_DONE=0

PASS=0
FAIL=0
FAILED_CHECKS=()

usage() {
    cat <<'EOF'
Usage:
  05_attest_baremetal.sh --target <whole-disk-or-loop-device>
  05_attest_baremetal.sh --target <device> --prepare --commit [--yes]
  05_attest_baremetal.sh --report <phase5_attestation.json>

Options:
  --target <dev>        Validated whole removable disk (RM=1) or loop device
                        backed by a file under build/ or vm-test/.
  --prepare             Copy phase5_attest.ps1/.cmd onto the card. Requires
                        --target and --commit.
  --commit              Confirm the --prepare write.
  --yes                 Skip the interactive confirmation for --prepare.
  --report <json>       Validate an offline report inside the project tree
                        (for example build/phase5/phase5_attestation.json).
  --max-age-hours <n>   Maximum report age (default: 72).
  --max-signature-age-days <n>
                        Maximum Defender signature age (default: 30).
  -h, --help            Show this help.

The normal hardware flow is:
  1. Prepare the card:  sudo 05_attest_baremetal.sh --target /dev/sdX --prepare --commit
  2. Boot the card on the target PC and run C:\Riot Games\phase5_attest.cmd.
  3. Shut down, reconnect the card, then run:
       sudo 05_attest_baremetal.sh --target /dev/sdX

QEMU, VMware, VirtualBox, Hyper-V, and other virtual machines are rejected as
non-bare-metal.  A report older than --max-age-hours is rejected.
EOF
}

log() { printf '[phase05] %s\n' "$*"; }
warn() { printf '[phase05] WARN: %s\n' "$*" >&2; }

pass() {
    PASS=$((PASS + 1))
    printf '[PASS] %s: %s\n' "$1" "$2"
}

fail() {
    FAIL=$((FAIL + 1))
    FAILED_CHECKS+=("$1")
    printf '[FAIL] %s: %s\n' "$1" "$2"
}

die() {
    SUMMARY_DONE=1
    printf '[FAIL] %s\n' "$*" >&2
    exit 1
}

summary() {
    SUMMARY_DONE=1
    printf '\n[phase05] Passed: %d  Failed: %d\n' "$PASS" "$FAIL"
    if (( FAIL > 0 )); then
        printf '[FAIL] Phase 5 bare-metal attestation failed: %s\n' \
            "${FAILED_CHECKS[*]}" >&2
        exit 1
    fi
    printf '[PASS] Phase 5 bare-metal attestation passed\n'
    exit 0
}

cleanup() {
    local rc=$?
    trap - EXIT
    set +e
    if (( NTFS_MOUNTED )); then
        umount -- "$NTFS_MNT" 2>/dev/null || umount -l -- "$NTFS_MNT" 2>/dev/null || true
        NTFS_MOUNTED=0
    fi
    remove_udev_guard
    if [[ -n "$WORK_DIR" && -d "$WORK_DIR" ]]; then
        rm -rf -- "$WORK_DIR" || true
    fi
    sync 2>/dev/null || true
    if (( rc != 0 )) && (( SUMMARY_DONE == 0 )); then
        printf '[FAIL] phase05 aborted unexpectedly (exit %s)\n' "$rc" >&2
    fi
    exit "$rc"
}

trap cleanup EXIT
trap 'rc=$?; printf "[FAIL] phase05 aborted unexpectedly at line %s (exit %s)\n" "$LINENO" "$rc" >&2' ERR

sha_file() {
    local file="$1" digest
    digest="$(sha256sum -- "$file" | cut -d' ' -f1)" || return 1
    printf '%s' "$digest"
}

partition_path() {
    local disk="$1" index="$2" base
    base="$(basename -- "$disk")"
    case "$base" in
        loop*|mmcblk*) printf '%sp%s\n' "$disk" "$index" ;;
        *) printf '%s%s\n' "$disk" "$index" ;;
    esac
}

resolve_report_path() {
    local raw="$1" resolved root
    [[ -n "$raw" ]] || die "--report must not be empty"
    resolved="$(readlink -f -- "$raw")" || die "Cannot resolve report path: $raw"
    root="$(readlink -f -- "$PROJECT_ROOT")" || die "Cannot resolve the project root"
    case "$resolved" in
        "$root"/*) ;;
        *) die "Report path must stay inside the project tree: $resolved" ;;
    esac
    [[ -f "$resolved" ]] || die "report file does not exist: $resolved"
    REPORT_PATH="$resolved"
}

attach_partitions() {
    local i
    PART2="$(partition_path "$TARGET" 2)"
    partprobe -- "$TARGET" >/dev/null 2>&1 || true
    udevadm settle --timeout=30 || true
    for ((i = 0; i < 30; i++)); do
        [[ -b "$PART2" ]] && return 0
        partx -u -- "$TARGET" >/dev/null 2>&1 || true
        sleep 1
    done
    [[ -b "$PART2" ]]
}

install_udev_guard() {
    local base
    base="$(basename -- "$TARGET")"
    mkdir -p -- /run/udev/rules.d || die "Cannot create /run/udev/rules.d"
    UDEV_RULE_FILE="/run/udev/rules.d/99-valos-p5-ignore-${base}.rules"
    {
        printf '# Temporary rule written by 05_attest_baremetal.sh; removed on exit.\n'
        printf 'ACTION=="add|change", SUBSYSTEM=="block", KERNEL=="%s", ENV{UDISKS_AUTO}="0", ENV{UDISKS_IGNORE}="1"\n' "$base"
        printf 'ACTION=="add|change", SUBSYSTEM=="block", KERNEL=="%s*", ENV{UDISKS_AUTO}="0", ENV{UDISKS_IGNORE}="1"\n' "$base"
    } > "$UDEV_RULE_FILE" || die "Cannot write $UDEV_RULE_FILE"
    udevadm control --reload-rules || die "udevadm control --reload-rules failed"
    udevadm trigger --action=change --subsystem-match=block --sysname-match="${base}*" \
        || die "udevadm trigger failed for $base"
    udevadm settle --timeout=30 || true
    log "Installed transient udev auto-mount guard for $base"
}

remove_udev_guard() {
    if [[ -n "$UDEV_RULE_FILE" && -f "$UDEV_RULE_FILE" ]]; then
        rm -f -- "$UDEV_RULE_FILE" || true
        udevadm control --reload-rules >/dev/null 2>&1 || true
    fi
    UDEV_RULE_FILE=""
}

mount_ntfs() {
    local mode="$1"
    mkdir -p -- "$NTFS_MNT"
    # ntfs-3g does not implement end-of-options; PART2 is a validated /dev path.
    if [[ "$mode" == "ro" ]]; then
        if ntfs-3g -o ro,force "$PART2" "$NTFS_MNT" 2>"${WORK_DIR}/ntfs-mount.err"; then
            NTFS_MOUNTED=1
        else
            cat -- "${WORK_DIR}/ntfs-mount.err" >&2 || true
            fail "ntfs-mount" "could not mount ${PART2} read-only"
            return 1
        fi
        pass "ntfs-mount" "ValOS NTFS volume mounted read-only"
    else
        if ntfs-3g -o rw,force "$PART2" "$NTFS_MNT" 2>"${WORK_DIR}/ntfs-mount.err"; then
            NTFS_MOUNTED=1
        else
            cat -- "${WORK_DIR}/ntfs-mount.err" >&2 || true
            fail "ntfs-mount" "could not mount ${PART2} read-write"
            return 1
        fi
        pass "ntfs-mount" "ValOS NTFS volume mounted read-write for --prepare"
    fi
    return 0
}

unmount_ntfs() {
    if (( NTFS_MOUNTED )); then
        umount -- "$NTFS_MNT" 2>/dev/null || umount -l -- "$NTFS_MNT" 2>/dev/null \
            || die "Could not unmount $NTFS_MNT"
        NTFS_MOUNTED=0
    fi
}

target_layout_check() {
    local required=(
        "Windows/System32/config/SYSTEM"
        "Windows/System32/config/SOFTWARE"
    )
    local rel missing=()
    for rel in "${required[@]}"; do
        [[ -f "${NTFS_MNT}/${rel}" ]] || missing+=("$rel")
    done
    if (( ${#missing[@]} == 0 )); then
        pass "target-layout" "the target contains a Windows SYSTEM/SOFTWARE hive"
    else
        fail "target-layout" "missing Windows files: ${missing[*]}"
    fi
}

gpt_guids() {
    local target="$1" sector_size
    # blockdev does not implement end-of-options; target is a validated /dev path.
    sector_size="$(blockdev --getss "$target" 2>/dev/null || true)"
    [[ "$sector_size" =~ ^[0-9]+$ ]] || sector_size=512
    python3 - "$target" "$sector_size" <<'PY'
import os
import struct
import sys
import uuid

path = sys.argv[1]
sector = int(sys.argv[2])

fd = os.open(path, os.O_RDONLY)


def read_at(offset, length):
    os.lseek(fd, offset, os.SEEK_SET)
    data = b""
    while len(data) < length:
        chunk = os.read(fd, length - len(data))
        if not chunk:
            raise IOError("short read")
        data += chunk
    return data


try:
    header = read_at(sector, 92)
    if header[0:8] != b"EFI PART":
        raise ValueError("bad GPT signature")
    disk_guid = uuid.UUID(bytes_le=header[56:72])
    entry_lba = struct.unpack_from("<Q", header, 72)[0]
    entry_count = struct.unpack_from("<I", header, 80)[0]
    entry_size = struct.unpack_from("<I", header, 84)[0]
    if entry_count < 2 or entry_size < 128:
        raise ValueError("invalid GPT partition array")
    entries = read_at(entry_lba * sector, entry_count * entry_size)
    entry = entries[entry_size:entry_size * 2]
    if entry[0:16] == b"\x00" * 16:
        raise ValueError("partition 2 is missing")
    part_guid = uuid.UUID(bytes_le=entry[16:32])
    print(str(disk_guid).lower())
    print(str(part_guid).lower())
finally:
    os.close(fd)
PY
}

to_crlf() {
    local src="$1" dst="$2"
    sed -e 's/\r$//' -e 's/$/\r/' -- "$src" > "$dst"
}

run_validator() {
    local report="$1" max_age="$2" max_sig="$3" disk_guid="$4" part_guid="$5" marker_hash="$6"
    python3 - "$report" "$max_age" "$max_sig" "$disk_guid" "$part_guid" "$marker_hash" <<'PY'
import datetime
import json
import re
import sys
import uuid

path, max_age_text, max_sig_text, expected_disk, expected_part, expected_marker = sys.argv[1:7]
max_age_hours = int(max_age_text)
max_sig_days = int(max_sig_text)
virtual_pattern = re.compile(
    r"(?i)(qemu|vmware|virtualbox|vbox|innotek|xen|hvm domu|hyper-v|parallels|bochs|"
    r"openstack|kubevirt|amazon ec2|google compute|digitalocean|"
    r"microsoft corporation virtual|virtual machine|kvm|bhyve|virtio|"
    r"cloud hypervisor|firecracker)"
)
expected_shell = 'cmd.exe /c "C:\\Riot Games\\val-kiosk.bat"'
failures = 0


def emit(ok, check_id, message):
    global failures
    status = "PASS" if ok else "FAIL"
    if not ok:
        failures += 1
    print(f"{status}\t{check_id}\t{message.replace(chr(9), ' ').replace(chr(10), ' ')}")


def get(value, dotted, default=None):
    current = value
    for key in dotted.split("."):
        if not isinstance(current, dict) or key not in current:
            return default
        current = current[key]
    return current


def is_bool(value):
    return type(value) is bool


def normalize_guid(value):
    if not isinstance(value, str):
        return ""
    return value.strip().strip("{}").replace("-", "").lower()


try:
    with open(path, "r", encoding="utf-8-sig") as handle:
        report = json.load(handle)
except Exception as exc:
    emit(False, "report-schema", f"cannot parse JSON: {exc}")
    raise SystemExit(1)

# ---------------------------------------------------------------------------
# Report metadata
# ---------------------------------------------------------------------------
schema_ok = (
    isinstance(report, dict)
    and report.get("schemaVersion") == 1
    and isinstance(report.get("collectorVersion"), str)
    and report.get("collectorVersion", "").strip() != ""
    and isinstance(report.get("reportId"), str)
)
try:
    uuid.UUID(report.get("reportId", ""))
    report_id_ok = True
except Exception:
    report_id_ok = False
timestamp = None
try:
    timestamp = datetime.datetime.fromisoformat(
        str(report.get("collectedAtUtc", "")).replace("Z", "+00:00")
    )
    if timestamp.tzinfo is None:
        timestamp = timestamp.replace(tzinfo=datetime.timezone.utc)
except Exception:
    timestamp = None
if schema_ok and report_id_ok and timestamp is not None:
    emit(True, "report-schema", "schemaVersion=1, UUID reportId, and UTC timestamp are present")
else:
    emit(False, "report-schema", "schemaVersion, collectorVersion, reportId, or collectedAtUtc is invalid")

emit(
    is_bool(get(report, "isElevated")) and get(report, "isElevated") is True,
    "report-elevated",
    "collector ran elevated" if get(report, "isElevated") is True else "collector was not elevated",
)

if timestamp is None:
    emit(False, "report-fresh", "collectedAtUtc cannot be parsed")
else:
    now = datetime.datetime.now(datetime.timezone.utc)
    age_seconds = (now - timestamp.astimezone(datetime.timezone.utc)).total_seconds()
    fresh = -300 <= age_seconds <= max_age_hours * 3600
    emit(
        fresh,
        "report-fresh",
        f"report age {age_seconds / 3600:.1f}h is within {max_age_hours}h"
        if fresh else f"report age {age_seconds / 3600:.1f}h is outside 0..{max_age_hours}h",
    )

# ---------------------------------------------------------------------------
# Bare metal
# ---------------------------------------------------------------------------
manufacturer = str(get(report, "bareMetal.manufacturer", ""))
model = str(get(report, "bareMetal.model", ""))
bios_manufacturer = str(get(report, "bareMetal.biosManufacturer", ""))
is_virtual = get(report, "bareMetal.isVirtual")
is_bare = get(report, "bareMetal.isBareMetal")
virtual_match = bool(
    virtual_pattern.search(manufacturer)
    or virtual_pattern.search(model)
    or virtual_pattern.search(bios_manufacturer)
)
bare_ok = (
    is_bool(is_virtual) and is_virtual is False
    and is_bool(is_bare) and is_bare is True
    and not virtual_match
    and manufacturer.strip() != ""
    and model.strip() != ""
)
emit(
    bare_ok,
    "report-bare-metal",
    f"{manufacturer} {model} is physical hardware"
    if bare_ok else f"virtual or unknown platform: {manufacturer} {model} / BIOS {bios_manufacturer}",
)

computer_name = str(get(report, "os.computerName", ""))
emit(
    computer_name.upper() == "VALCONSOLE",
    "os-computer-name",
    f"computer name is {computer_name}" if computer_name else "computer name is missing",
)

# ---------------------------------------------------------------------------
# OS, firmware, boot medium
# ---------------------------------------------------------------------------
build = str(get(report, "os.build", ""))
emit(build == "19045", "os-build", f"Windows build {build} is 19045" if build == "19045" else f"Windows build is {build}, expected 19045")

firmware_type = str(get(report, "os.firmwareType", "")).lower()
emit(firmware_type == "uefi", "os-uefi", f"firmware type is {firmware_type or 'missing'}" if firmware_type == "uefi" else f"firmware type is {firmware_type or 'missing'}, expected UEFI")

portable = get(report, "os.portableOperatingSystem")
emit(is_bool(portable) and portable is True, "os-portable", "PortableOperatingSystem is enabled" if portable is True else "PortableOperatingSystem is not enabled")

bus_type = str(get(report, "systemVolume.busType", ""))
removable = get(report, "os.bootedFromRemovableMedia")
boot_media_ok = (
    is_bool(removable) and removable is True
    and bus_type.upper() in {"USB", "SD", "MMC", "SECURE DIGITAL"}
)
emit(
    boot_media_ok,
    "os-boot-media",
    f"system disk bus type is {bus_type}" if boot_media_ok else f"system disk bus type is {bus_type or 'missing'}, expected USB/SD/MMC",
)

# ---------------------------------------------------------------------------
# Secure Boot and TPM
# ---------------------------------------------------------------------------
secure_boot = get(report, "firmware.secureBootEnabled")
setup_mode = get(report, "firmware.secureBootSetupMode")
secure_ok = is_bool(secure_boot) and secure_boot is True and is_bool(setup_mode) and setup_mode is False
emit(secure_ok, "secureboot-enabled", "Secure Boot is enabled and not in Setup Mode" if secure_ok else "Secure Boot is disabled or firmware is in Setup Mode")

tpm_flags = [
    get(report, "tpm.present"),
    get(report, "tpm.ready"),
    get(report, "tpm.enabled"),
    get(report, "tpm.activated"),
]
tpm_ok = all(is_bool(flag) and flag is True for flag in tpm_flags)
emit(tpm_ok, "tpm-present", "TPM is present, ready, enabled, and activated" if tpm_ok else "TPM is missing or not ready/enabled/activated")

tpm_version = str(get(report, "tpm.specVersion", ""))
tpm_v2_ok = tpm_version.startswith("2.0")
emit(tpm_v2_ok, "tpm-v2", f"TPM spec version is {tpm_version or 'missing'}" if tpm_v2_ok else f"TPM spec version is {tpm_version or 'missing'}, expected 2.0")

ek_hash = str(get(report, "tpm.ekPublicKeyHashSha256", "")).lower()
ek_ok = bool(re.fullmatch(r"[0-9a-f]{64}", ek_hash))
emit(ek_ok, "tpm-ek", "TPM endorsement-key SHA-256 is present" if ek_ok else "TPM endorsement-key SHA-256 is missing or malformed")

# ---------------------------------------------------------------------------
# Defender
# ---------------------------------------------------------------------------
win_defend = str(get(report, "defender.serviceState", ""))
security_health = str(get(report, "defender.securityHealthServiceState", ""))
defender_service_ok = win_defend == "Running" and security_health == "Running"
emit(
    defender_service_ok,
    "defender-service",
    f"WinDefend={win_defend}, SecurityHealthService={security_health}"
    if defender_service_ok else f"WinDefend={win_defend or 'missing'}, SecurityHealthService={security_health or 'missing'}",
)

defender_realtime_ok = all(
    is_bool(get(report, f"defender.{field}")) and get(report, f"defender.{field}") is True
    for field in ("amServiceEnabled", "antivirusEnabled", "realTimeProtectionEnabled")
)
emit(
    defender_realtime_ok,
    "defender-realtime",
    "Defender antivirus, AM service, and real-time protection are enabled"
    if defender_realtime_ok else "Defender antivirus, AM service, or real-time protection is disabled",
)

tamper = get(report, "defender.tamperProtectionEnabled")
tamper_ok = is_bool(tamper) and tamper is True
emit(tamper_ok, "defender-tamper", "Defender tamper protection is enabled" if tamper_ok else "Defender tamper protection is disabled or missing")

signature_age = get(report, "defender.signatureAgeDays")
signature_ok = (
    isinstance(signature_age, int) and not isinstance(signature_age, bool)
    and 0 <= signature_age <= max_sig_days
)
emit(
    signature_ok,
    "defender-signatures",
    f"Defender signatures are {signature_age} days old (limit {max_sig_days})"
    if signature_ok else f"Defender signature age is {signature_age!r}, expected 0..{max_sig_days}",
)

# ---------------------------------------------------------------------------
# Code integrity
# ---------------------------------------------------------------------------
ci_files_ok = all(
    is_bool(get(report, f"codeIntegrity.{field}")) and get(report, f"codeIntegrity.{field}") is True
    for field in ("ciDllPresent", "tpmSysPresent")
)
emit(ci_files_ok, "code-integrity-files", "ci.dll and tpm.sys are present" if ci_files_ok else "ci.dll or tpm.sys is missing")

test_signing = get(report, "codeIntegrity.testSigningEnabled")
test_signing_ok = is_bool(test_signing) and test_signing is False
emit(test_signing_ok, "code-integrity-testsigning", "test signing is disabled" if test_signing_ok else "test signing is enabled or missing")

kernel_debug = get(report, "codeIntegrity.kernelDebugEnabled")
kernel_debug_ok = is_bool(kernel_debug) and kernel_debug is False
emit(kernel_debug_ok, "code-integrity-kernel-debug", "kernel debugging is disabled" if kernel_debug_ok else "kernel debugging is enabled or missing")

blocklist = get(report, "codeIntegrity.driverBlocklistEnabled")
integrity_disabled = get(report, "codeIntegrity.integrityChecksDisabled")
blocklist_ok = (
    is_bool(blocklist) and blocklist is True
    and is_bool(integrity_disabled) and integrity_disabled is False
)
emit(
    blocklist_ok,
    "code-integrity-driver-blocklist",
    "driver blocklist is enabled and integrity checks are not disabled"
    if blocklist_ok else "driver blocklist is disabled or integrity checks are disabled",
)

hvci_status = str(get(report, "codeIntegrity.hvciStatus", ""))
hvci_disabled = get(report, "codeIntegrity.hvciPolicyDisabled")
hvci_ok = (
    is_bool(hvci_disabled) and hvci_disabled is False
    and hvci_status in {"running", "configured", "not-enabled"}
)
emit(
    hvci_ok,
    "code-integrity-hvci",
    f"HVCI is not disabled by policy (status: {hvci_status})"
    if hvci_ok else f"HVCI policy is disabled or status is {hvci_status or 'missing'}",
)

# ---------------------------------------------------------------------------
# Vanguard
# ---------------------------------------------------------------------------
installed = get(report, "vanguard.installed")
vgk_service = str(get(report, "vanguard.vgkServiceState", ""))
vgc_service = str(get(report, "vanguard.vgcServiceState", ""))
vanguard_service_ok = is_bool(installed) and installed is True and vgk_service == "Running" and vgc_service == "Running"
emit(
    vanguard_service_ok,
    "vanguard-service",
    f"vgk={vgk_service}, vgc={vgc_service}" if vanguard_service_ok else f"vgk={vgk_service or 'missing'}, vgc={vgc_service or 'missing'}, installed={installed!r}",
)

driver_loaded = get(report, "vanguard.vgkDriverLoaded")
driver_ok = is_bool(driver_loaded) and driver_loaded is True
emit(driver_ok, "vanguard-driver", "vgk.sys is loaded and running" if driver_ok else "vgk.sys is not loaded")

signature_ok = True
signature_detail = []
for prefix in ("vgk", "vgc"):
    present = get(report, f"vanguard.{prefix}FilePresent")
    status = str(get(report, f"vanguard.{prefix}SignatureStatus", ""))
    signer = str(get(report, f"vanguard.{prefix}Signer", ""))
    valid = (
        is_bool(present) and present is True
        and status == "Valid"
        and "riot games" in signer.lower()
    )
    signature_ok = signature_ok and valid
    signature_detail.append(f"{prefix}={status or 'missing'}")
emit(
    signature_ok,
    "vanguard-signature",
    "Vanguard vgk.sys and vgc.exe signatures are valid and signed by Riot Games"
    if signature_ok else "Vanguard signature check failed: " + ", ".join(signature_detail),
)

# ---------------------------------------------------------------------------
# Kiosk
# ---------------------------------------------------------------------------
shell_value = str(get(report, "kiosk.shell", ""))
shell_ok = " ".join(shell_value.split()).lower() == " ".join(expected_shell.split()).lower()
emit(shell_ok, "kiosk-shell", f"Winlogon Shell is {shell_value}" if shell_ok else f"Winlogon Shell is {shell_value or 'missing'}")

marker = get(report, "kiosk.bootVerifiedMarker")
marker_ok = is_bool(marker) and marker is True
emit(marker_ok, "kiosk-marker", "first-boot marker is present" if marker_ok else "first-boot marker is missing")

kiosk_user = str(get(report, "kiosk.user", ""))
auto_logon = get(report, "kiosk.autoAdminLogon")
user_ok = (
    kiosk_user.lower() == "valplayer"
    and type(auto_logon) is int
    and auto_logon == 1
)
emit(user_ok, "kiosk-user", f"AutoLogon user is {kiosk_user}" if user_ok else f"AutoLogon user is {kiosk_user or 'missing'} (AutoAdminLogon={auto_logon!r})")

# ---------------------------------------------------------------------------
# Card binding
# ---------------------------------------------------------------------------
report_disk = normalize_guid(get(report, "systemVolume.diskGuid"))
report_part = normalize_guid(get(report, "systemVolume.partitionGuid"))
if expected_disk and expected_part:
    gpt_ok = report_disk == normalize_guid(expected_disk) and report_part == normalize_guid(expected_part)
    emit(
        gpt_ok,
        "card-binding-gpt",
        "report GPT disk/partition GUIDs match the target card"
        if gpt_ok else f"report GPT GUIDs {report_disk or 'missing'}/{report_part or 'missing'} do not match {expected_disk}/{expected_part}",
    )
else:
    emit(True, "card-binding-gpt", "skipped: offline report has no target GPT to compare")

report_marker = str(get(report, "kiosk.bootVerifiedContentSha256", "")).lower()
if expected_marker:
    marker_hash_ok = bool(re.fullmatch(r"[0-9a-f]{64}", report_marker)) and report_marker == expected_marker.lower()
    emit(
        marker_hash_ok,
        "card-binding-marker",
        "report boot-marker SHA-256 matches the target card"
        if marker_hash_ok else "report boot-marker SHA-256 does not match the target card",
    )
else:
    emit(True, "card-binding-marker", "skipped: offline report has no target boot marker to compare")

raise SystemExit(1 if failures else 0)
PY
}

validate_report_file() {
    local report="$1" disk_guid="$2" part_guid="$3" marker_hash="$4"
    local out="${WORK_DIR}/validator.tsv" err="${WORK_DIR}/validator.err" rc=0
    run_validator "$report" "$MAX_AGE_HOURS" "$MAX_SIGNATURE_AGE_DAYS" \
        "$disk_guid" "$part_guid" "$marker_hash" > "$out" 2> "$err" || rc=$?

    while IFS=$'\t' read -r status check_id message; do
        [[ -n "${check_id:-}" ]] || continue
        if [[ "$status" == "PASS" ]]; then
            pass "$check_id" "$message"
        else
            fail "$check_id" "$message"
        fi
    done < "$out"

    if (( rc != 0 )); then
        if [[ ! -s "$out" ]]; then
            fail "validator" "report validator crashed: $(head -c 500 -- "$err" 2>/dev/null || true)"
        fi
    fi
}

# ---------------------------------------------------------------------------
# Argument parsing
# ---------------------------------------------------------------------------
while (( $# > 0 )); do
    case "$1" in
        --target)
            (( $# >= 2 )) || die "--target requires a device path"
            [[ -n "$2" ]] || die "--target must not be empty"
            TARGET="$2"
            shift 2
            ;;
        --report)
            (( $# >= 2 )) || die "--report requires a JSON path"
            [[ -n "$2" ]] || die "--report must not be empty"
            REPORT_PATH="$2"
            shift 2
            ;;
        --prepare)
            PREPARE=1
            shift
            ;;
        --commit)
            COMMIT=1
            shift
            ;;
        --yes)
            ASSUME_YES=1
            shift
            ;;
        --max-age-hours)
            (( $# >= 2 )) || die "--max-age-hours requires a value"
            [[ "$2" =~ ^[1-9][0-9]*$ ]] || die "--max-age-hours must be a positive integer"
            MAX_AGE_HOURS="$2"
            shift 2
            ;;
        --max-signature-age-days)
            (( $# >= 2 )) || die "--max-signature-age-days requires a value"
            [[ "$2" =~ ^[1-9][0-9]*$ ]] || die "--max-signature-age-days must be a positive integer"
            MAX_SIGNATURE_AGE_DAYS="$2"
            shift 2
            ;;
        -h|--help)
            usage
            exit 0
            ;;
        *)
            die "Unknown argument: $1"
            ;;
    esac
done

if [[ -n "$TARGET" && -n "$REPORT_PATH" ]]; then
    die "--target and --report are mutually exclusive"
fi
if (( PREPARE )) && [[ -z "$TARGET" ]]; then
    die "--prepare requires --target"
fi
if (( PREPARE )) && (( COMMIT == 0 )); then
    die "--prepare writes to the card and requires --commit"
fi
if (( COMMIT )) && (( PREPARE == 0 )); then
    die "--commit is only valid with --prepare"
fi
if (( ASSUME_YES )) && (( COMMIT == 0 )); then
    die "--yes is only valid with --commit"
fi
if [[ -z "$TARGET" && -z "$REPORT_PATH" ]]; then
    usage >&2
    die "either --target or --report is required"
fi
if (( PREPARE )) && (( COMMIT )) && (( ASSUME_YES == 0 )) && [[ ! -t 0 ]]; then
    die "--yes is required for a non-interactive --prepare --commit"
fi
if [[ -n "$REPORT_PATH" ]]; then
    resolve_report_path "$REPORT_PATH"
fi

mkdir -p -- "$LOG_DIR"
RUN_STAMP="$(date -u +%Y%m%dT%H%M%SZ)-$$"
LOG_FILE="${LOG_DIR}/05_attest_baremetal_${RUN_STAMP}.log"
: > "$LOG_FILE"
exec > >(tee -a "$LOG_FILE") 2>&1

WORK_DIR="$(mktemp -d "${PROJECT_ROOT}/build/phase05.XXXXXX")" \
    || die "Cannot create a work directory under build/"
NTFS_MNT="${WORK_DIR}/ntfs"

if [[ -n "$TARGET" ]]; then
    if (( EUID != 0 )); then
        die "Run --target/--prepare as root (pkexec or sudo)"
    fi
    for tool in ntfs-3g lsblk python3 blockdev partx partprobe udevadm sha256sum sed; do
        command -v "$tool" >/dev/null 2>&1 || die "Required tool is missing: $tool"
    done
    [[ -x "$WRITER" ]] || die "Phase 4 writer is missing or not executable: $WRITER"
    [[ -f "$COLLECTOR_PS1" ]] || die "Collector payload is missing: $COLLECTOR_PS1"
    [[ -f "$COLLECTOR_CMD" ]] || die "Collector launcher is missing: $COLLECTOR_CMD"

    TARGET="$(readlink -f -- "$TARGET")" || die "Cannot resolve target: $TARGET"
    [[ -b "$TARGET" ]] || die "Target is not a block device: $TARGET"

    log "Validating $TARGET through the Phase 4 safety validator"
    if ! "$WRITER" --target "$TARGET" > "${WORK_DIR}/target-validate.out" 2>&1; then
        cat -- "${WORK_DIR}/target-validate.out" >&2 || true
        die "Phase 4 target validation failed"
    fi
    if ! grep -Fq -- '[PASS] dry-run:' "${WORK_DIR}/target-validate.out"; then
        cat -- "${WORK_DIR}/target-validate.out" >&2 || true
        die "Phase 4 validator did not report a successful dry-run"
    fi
    pass "target-validation" "Phase 4 safety validator accepted $TARGET"

    install_udev_guard
    attach_partitions || die "Partition 2 did not appear on $TARGET"
    pass "target-partition" "ValOS partition is ${PART2}"
fi

# ---------------------------------------------------------------------------
# Offline report validation
# ---------------------------------------------------------------------------
if [[ -n "$REPORT_PATH" ]]; then
    validate_report_file "$REPORT_PATH" "" "" ""
    summary
fi

# ---------------------------------------------------------------------------
# Prepare the collector on the card
# ---------------------------------------------------------------------------
if (( PREPARE )); then
    if (( ASSUME_YES == 0 )); then
        printf '[phase05] This will copy the Phase 5 collector onto %s.\n' "$PART2" >&2
        printf 'Type ERASE to continue: ' >&2
        read -r confirmation
        [[ "$confirmation" == "ERASE" ]] || die "Card preparation cancelled"
    fi

    mount_ntfs rw || summary
    target_layout_check
    if (( FAIL > 0 )); then
        unmount_ntfs
        summary
    fi

    mkdir -p -- "${NTFS_MNT}/Riot Games"
    to_crlf "$COLLECTOR_PS1" "${WORK_DIR}/phase5_attest.ps1"
    to_crlf "$COLLECTOR_CMD" "${WORK_DIR}/phase5_attest.cmd"

    if grep -Fq -- 'Confirm-SecureBootUEFI' "${WORK_DIR}/phase5_attest.ps1" \
        && grep -Fq -- 'Get-Tpm' "${WORK_DIR}/phase5_attest.ps1" \
        && grep -Fq -- 'Get-MpComputerStatus' "${WORK_DIR}/phase5_attest.ps1" \
        && grep -Fq -- 'phase5_attestation.json' "${WORK_DIR}/phase5_attest.ps1"; then
        pass "prepare-collector" "collector contains the Secure Boot, TPM, Defender, and report checks"
    else
        fail "prepare-collector" "collector payload is missing a required check"
    fi

    cat > "${WORK_DIR}/PHASE5_README.txt" <<'EOF'
Valorant Console OS - Phase 5 bare-metal attestation

1. Boot the microSD card on the target PC with UEFI Secure Boot and TPM 2.0
   enabled in firmware.
2. From the Valorant console menu choose [4] Launch Full Windows Desktop.
3. Open C:\Riot Games and run phase5_attest.cmd as administrator.
   The collector only reads security state and writes:
     C:\Riot Games\phase5_attestation.json
     C:\Riot Games\phase5_attestation.txt
4. Shut down Windows, return the card to the Linux host, and run:
     sudo scripts/05_attest_baremetal.sh --target /dev/sdX
EOF
    to_crlf "${WORK_DIR}/PHASE5_README.txt" "${WORK_DIR}/PHASE5_README.crlf.txt"

    cp -- "${WORK_DIR}/phase5_attest.ps1" "${NTFS_MNT}/Riot Games/phase5_attest.ps1" \
        || die "Cannot copy the collector onto the card"
    cp -- "${WORK_DIR}/phase5_attest.cmd" "${NTFS_MNT}/Riot Games/phase5_attest.cmd" \
        || die "Cannot copy the launcher onto the card"
    cp -- "${WORK_DIR}/PHASE5_README.crlf.txt" "${NTFS_MNT}/Riot Games/PHASE5_README.txt" \
        || die "Cannot copy the Phase 5 README onto the card"
    sync

    installed_ps1="${NTFS_MNT}/Riot Games/phase5_attest.ps1"
    installed_cmd="${NTFS_MNT}/Riot Games/phase5_attest.cmd"
    if [[ -f "$installed_ps1" && "$(sha_file "$installed_ps1")" == "$(sha_file "${WORK_DIR}/phase5_attest.ps1")" ]]; then
        pass "prepare-ps1" "phase5_attest.ps1 copied byte-for-byte"
    else
        fail "prepare-ps1" "phase5_attest.ps1 is missing or changed on the card"
    fi
    if [[ -f "$installed_cmd" && "$(sha_file "$installed_cmd")" == "$(sha_file "${WORK_DIR}/phase5_attest.cmd")" ]]; then
        pass "prepare-cmd" "phase5_attest.cmd copied byte-for-byte"
    else
        fail "prepare-cmd" "phase5_attest.cmd is missing or changed on the card"
    fi
    if grep -q $'\r' "$installed_ps1" && grep -q $'\r' "$installed_cmd"; then
        pass "prepare-crlf" "installed Windows payloads use CRLF line endings"
    else
        fail "prepare-crlf" "installed Windows payloads are not CRLF"
    fi

    unmount_ntfs
    log "Collector installed. Boot the card, run C:\\Riot Games\\phase5_attest.cmd,"
    log "then re-run this script with --target $TARGET to validate the report."
    summary
fi

# ---------------------------------------------------------------------------
# Validate the report on the card (normal hardware gate)
# ---------------------------------------------------------------------------
mount_ntfs ro || summary
target_layout_check

REPORT_ON_CARD="${NTFS_MNT}/${REPORT_REL}"
MARKER_ON_CARD="${NTFS_MNT}/${MARKER_REL}"
EXPECTED_MARKER_HASH=""

if [[ -f "$REPORT_ON_CARD" ]]; then
    pass "report-present" "found ${REPORT_REL} on the card"
else
    fail "report-present" "missing ${REPORT_REL}; run C:\\Riot Games\\phase5_attest.cmd on the target PC first"
    unmount_ntfs
    summary
fi

if [[ -f "$MARKER_ON_CARD" ]]; then
    EXPECTED_MARKER_HASH="$(sha_file "$MARKER_ON_CARD")" \
        || fail "target-marker" "cannot hash ${MARKER_REL}"
    if [[ -n "$EXPECTED_MARKER_HASH" ]]; then
        pass "target-marker" "first-boot marker is present on the card"
    fi
else
    fail "target-marker" "missing ${MARKER_REL}; the card has not completed first boot"
fi

mapfile -t CARD_GUIDS < <(gpt_guids "$TARGET" 2>"${WORK_DIR}/gpt.err" || true)
if (( ${#CARD_GUIDS[@]} == 2 )); then
    pass "target-gpt" "GPT disk and partition-2 GUIDs were read from the card"
else
    cat -- "${WORK_DIR}/gpt.err" >&2 || true
    fail "target-gpt" "cannot read GPT GUIDs from $TARGET"
fi

EXPECTED_DISK_GUID="${CARD_GUIDS[0]:-}"
EXPECTED_PART_GUID="${CARD_GUIDS[1]:-}"

validate_report_file "$REPORT_ON_CARD" "$EXPECTED_DISK_GUID" "$EXPECTED_PART_GUID" "$EXPECTED_MARKER_HASH"
unmount_ntfs
summary
