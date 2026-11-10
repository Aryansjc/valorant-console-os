#!/usr/bin/env bash
# Phase 5 verification gate: prove the bare-metal attestation validator accepts
# a real hardware report and rejects every weakened or virtualized state.
#
# --self-test runs the fixture/target-loop tests only.  That is a development
# gate, not a Phase 5 pass: the real gate requires --target on a whole RM=1 card
# with a physical-hardware report.  --report validates a copied report offline
# but cannot prove card binding.
#
# Destructive scope: vm-test/p5_sdcard.img only.  Host block devices are never
# touched.  Run as root through pkexec or sudo (loop devices and mounts).

set -Eeuo pipefail
IFS=$'\n\t'

PROJECT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
readonly PROJECT_ROOT

readonly ATTEST_SCRIPT="${PROJECT_ROOT}/scripts/05_attest_baremetal.sh"
readonly COLLECTOR="${PROJECT_ROOT}/payloads/phase5_attest.ps1"
readonly LAUNCHER="${PROJECT_ROOT}/payloads/phase5_attest.cmd"
readonly TEMPLATE="${PROJECT_ROOT}/tests/fixtures/phase05/valid-report.template.json"
readonly TEST_DIR="${PROJECT_ROOT}/vm-test"
readonly WORK_DIR="${TEST_DIR}/p5-verify"
readonly IMAGE="${TEST_DIR}/p5_sdcard.img"
readonly LOG_DIR="${PROJECT_ROOT}/build/logs"
readonly LOG="${LOG_DIR}/test_05_baremetal.log"

SELF_TEST=0
TARGET=""
REPORT=""
KEEP_IMAGE=0
HARDWARE_MODE="offline"

LOOP_DEV=""
IMAGE_MOUNTED=0
REMOVE_IMAGE=0

PASS=0
FAIL=0
FAILED_CHECKS=()

usage() {
    cat <<'EOF'
Usage: test_05_baremetal.sh [options]

Options:
  --self-test          Run fixture and loop-image validator tests only.
  --target <device>    Validate the real hardware report on a whole RM=1 card.
  --report <json>      Validate a copied report offline (no card binding).
  --keep-image         Keep vm-test/p5_sdcard.img for debugging.
  -h, --help           Show this help.

The self-test creates a disposable 1 GiB loop image under vm-test/ and requires
root for loop devices and ntfs-3g mounts.  The hardware gate passes only when a
whole RM=1 card contains a physical-hardware report showing Secure Boot, TPM
2.0, Defender, code integrity, the kiosk shell, and Vanguard vgk.sys/vgc
running.  --report validates a copied report but cannot prove card binding.
EOF
}

log() { printf '[phase05-test] %s\n' "$*"; }

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
    fail "$1" "$2"
    summary
}

summary() {
    local rc=0
    printf '\n[phase05-test] Passed: %d  Failed: %d\n' "$PASS" "$FAIL"
    if (( FAIL > 0 )); then
        printf '[FAIL] Phase 5 bare-metal attestation gate failed: %s\n' \
            "${FAILED_CHECKS[*]}" >&2
        rc=1
    elif (( SELF_TEST )); then
        printf '[PASS] Phase 5 self-test passed (not the hardware gate)\n'
        REMOVE_IMAGE=1
    elif [[ "$HARDWARE_MODE" == "target" ]]; then
        printf '[PASS] Phase 5 bare-metal attestation gate passed\n'
        REMOVE_IMAGE=1
    else
        printf '[PASS] Phase 5 offline report validated (hardware gate not proven)\n'
        REMOVE_IMAGE=1
    fi
    exit "$rc"
}

cleanup() {
    local rc=$?
    trap - EXIT
    set +e
    if (( IMAGE_MOUNTED )); then
        umount -- "${WORK_DIR}/mnt" 2>/dev/null \
            || umount -l -- "${WORK_DIR}/mnt" 2>/dev/null || true
        IMAGE_MOUNTED=0
    fi
    if [[ -n "$LOOP_DEV" ]]; then
        losetup -d "$LOOP_DEV" 2>/dev/null || true
    fi
    sync 2>/dev/null || true
    if (( REMOVE_IMAGE )) && [[ -f "$IMAGE" ]]; then
        rm -f -- "$IMAGE"
        printf '[phase05-test] Removed disposable image: %s\n' "$IMAGE"
    elif [[ -f "$IMAGE" ]]; then
        printf '[phase05-test] Kept test image for debugging: %s\n' "$IMAGE"
    fi
    exit "$rc"
}

trap cleanup EXIT
trap 'rc=$?; printf "[FAIL] phase05-test aborted unexpectedly at line %s (exit %s)\n" "$LINENO" "$rc" >&2' ERR

while (( $# > 0 )); do
    case "$1" in
        --self-test)
            SELF_TEST=1
            shift
            ;;
        --target)
            (( $# >= 2 )) || die "args" "--target requires a device"
            TARGET="$2"
            shift 2
            ;;
        --report)
            (( $# >= 2 )) || die "args" "--report requires a JSON path"
            REPORT="$2"
            shift 2
            ;;
        --keep-image)
            KEEP_IMAGE=1
            shift
            ;;
        -h|--help)
            usage
            exit 0
            ;;
        *)
            die "args" "Unknown argument: $1"
            ;;
    esac
done

if [[ -n "$TARGET" && -n "$REPORT" ]]; then
    die "args" "--target and --report are mutually exclusive"
fi
if (( SELF_TEST )) && [[ -n "$TARGET$REPORT" ]]; then
    die "args" "--self-test cannot be combined with --target/--report"
fi
if [[ -n "$TARGET" ]]; then
    HARDWARE_MODE="target"
fi

if (( EUID != 0 )); then
    printf '[FAIL] root-privileges: run this gate as root (pkexec or sudo)\n' >&2
    exit 1
fi

for tool in truncate losetup parted mkntfs ntfs-3g partprobe udevadm python3 \
    blockdev lsblk sha256sum grep sed; do
    command -v "$tool" >/dev/null 2>&1 || die "tool-${tool}" "required tool is missing: $tool"
done
[[ -x "$ATTEST_SCRIPT" ]] || die "attest-script" "missing or not executable: $ATTEST_SCRIPT"
[[ -f "$COLLECTOR" ]] || die "collector" "missing collector: $COLLECTOR"
[[ -f "$LAUNCHER" ]] || die "launcher" "missing launcher: $LAUNCHER"
[[ -f "$TEMPLATE" ]] || die "fixture-template" "missing report template: $TEMPLATE"

mkdir -p -- "$LOG_DIR" "$TEST_DIR"
rm -rf -- "$WORK_DIR"
mkdir -p -- "$WORK_DIR/mnt"
: > "$LOG"
exec > >(tee -a "$LOG") 2>&1

# ---------------------------------------------------------------------------
# Static payload and script checks
# ---------------------------------------------------------------------------
if [[ -s "$COLLECTOR" ]] \
    && grep -Fq -- 'Confirm-SecureBootUEFI' "$COLLECTOR" \
    && grep -Fq -- 'Get-Tpm' "$COLLECTOR" \
    && grep -Fq -- 'Get-MpComputerStatus' "$COLLECTOR" \
    && grep -Fq -- 'Get-TpmEndorsementKeyInfo' "$COLLECTOR" \
    && grep -Fq -- 'Win32_SystemDriver' "$COLLECTOR" \
    && grep -Fq -- 'vgkServiceState = [string]$vgkDriver.State' "$COLLECTOR" \
    && grep -Fq -- 'phase5_attestation.json' "$COLLECTOR"; then
    pass "collector-payload" "collector reads Secure Boot, TPM, Defender, and Vanguard state"
else
    fail "collector-payload" "collector payload is incomplete"
fi

if [[ -s "$LAUNCHER" ]] && grep -Fq -- 'phase5_attest.ps1' "$LAUNCHER"; then
    pass "collector-launcher" "launcher invokes the PowerShell collector"
else
    fail "collector-launcher" "launcher does not invoke phase5_attest.ps1"
fi

if grep -Eq -- '^[[:space:]]*\*\.ps1[[:space:]]+text[[:space:]]+eol=crlf' \
        "${PROJECT_ROOT}/.gitattributes" \
    && grep -Eq -- '^[[:space:]]*\*\.cmd[[:space:]]+text[[:space:]]+eol=crlf' \
        "${PROJECT_ROOT}/.gitattributes"; then
    pass "collector-crlf-attributes" "PowerShell and cmd payloads are checked out with CRLF"
else
    fail "collector-crlf-attributes" ".gitattributes does not pin *.ps1 and *.cmd to CRLF"
fi

WEAKENING_PATTERNS='DisableRealtimeMonitoring|DisableAntiSpyware|Set-MpPreference|sc[[:space:]]+stop[[:space:]]+vgk|sc[[:space:]]+config[[:space:]]+vgk|bcdedit[[:space:]]+/set|Remove-Item.*Defender|Disable-BitLocker'
if ! grep -Eiq -- "$WEAKENING_PATTERNS" "$COLLECTOR"; then
    pass "collector-no-weakening" "collector never disables Defender, TPM, code integrity, or Vanguard"
else
    fail "collector-no-weakening" "collector contains a forbidden weakening command"
fi

if bash -n "$ATTEST_SCRIPT" 2>"${WORK_DIR}/attest-syntax.err"; then
    pass "validator-syntax" "05_attest_baremetal.sh parses cleanly"
else
    fail "validator-syntax" "05_attest_baremetal.sh has a syntax error"
fi

HELP_OUT="${WORK_DIR}/help.out"
if "$ATTEST_SCRIPT" --help > "$HELP_OUT" 2>&1 \
    && grep -Fq -- '--prepare' "$HELP_OUT" \
    && grep -Fq -- '--report' "$HELP_OUT"; then
    pass "validator-cli" "validator documents target, prepare, and offline report modes"
else
    fail "validator-cli" "validator help is missing a required mode"
fi

# ---------------------------------------------------------------------------
# Materialize a fresh valid report
# ---------------------------------------------------------------------------
REPORT_ID="$(python3 -c 'import uuid; print(uuid.uuid4())')"
REPORT_TIME="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
VALID_REPORT="${WORK_DIR}/valid-report.json"
python3 - "$TEMPLATE" "$VALID_REPORT" "$REPORT_ID" "$REPORT_TIME" <<'PY'
import json
import sys

src, dst, report_id, timestamp = sys.argv[1:5]
text = open(src, encoding="utf-8").read()
text = text.replace("REPORT_ID", report_id)
text = text.replace("REPORT_TIMESTAMP", timestamp)
text = text.replace("EK_HASH", "a" * 64)
text = text.replace("DISK_GUID", "1" * 32)
text = text.replace("PART_GUID", "2" * 32)
text = text.replace("MARKER_HASH", "b" * 64)
json.loads(text)
open(dst, "w", encoding="utf-8").write(text)
PY

VALID_OUT="${WORK_DIR}/valid.out"
if "$ATTEST_SCRIPT" --report "$VALID_REPORT" > "$VALID_OUT" 2>&1; then
    pass_count="$(grep -c '^\[PASS\] [a-z]' "$VALID_OUT" || true)"
    if [[ "$pass_count" == "30" ]] && ! grep -Fq -- '[FAIL]' "$VALID_OUT"; then
        pass "validator-accepts-valid" "a complete report passes all 30 checks"
    else
        fail "validator-accepts-valid" "valid report passed ${pass_count:-0} checks, expected 30"
    fi
else
    fail "validator-accepts-valid" "validator rejected the complete fixture report"
fi

# ---------------------------------------------------------------------------
# Negative report mutations
# ---------------------------------------------------------------------------
run_mutation() {
    local name="$1" json_path="$2" json_value="$3" expected_id="$4"
    local mutated="${WORK_DIR}/mutated-${name}.json"
    local out="${WORK_DIR}/mutated-${name}.out"
    local rc=0
    if [[ "$json_value" == "__DELETE__" ]]; then
        python3 - "$VALID_REPORT" "$mutated" "$json_path" <<'PY'
import json
import sys

src, dst, dotted = sys.argv[1:4]
data = json.load(open(src, encoding="utf-8"))
current = data
parts = dotted.split(".")
for part in parts[:-1]:
    current = current[part]
del current[parts[-1]]
json.dump(data, open(dst, "w", encoding="utf-8"), indent=2)
PY
    else
        python3 - "$VALID_REPORT" "$mutated" "$json_path" "$json_value" <<'PY'
import json
import sys

src, dst, dotted, raw_value = sys.argv[1:5]
data = json.load(open(src, encoding="utf-8"))
value = json.loads(raw_value)
current = data
parts = dotted.split(".")
for part in parts[:-1]:
    current = current[part]
current[parts[-1]] = value
json.dump(data, open(dst, "w", encoding="utf-8"), indent=2)
PY
    fi
    "$ATTEST_SCRIPT" --report "$mutated" > "$out" 2>&1 || rc=$?
    if (( rc == 0 )); then
        fail "reject-${name}" "validator accepted a report with ${json_path}=${json_value}"
    elif ! grep -Fq -- "[FAIL] ${expected_id}:" "$out"; then
        fail "reject-${name}" "validator failed without [FAIL] ${expected_id}"
    else
        local fail_count
        fail_count="$(grep -c '^\[FAIL\] [a-z]' "$out" || true)"
        if [[ "$fail_count" == "1" ]]; then
            pass "reject-${name}" "${expected_id} rejected ${json_path}=${json_value}"
        else
            fail "reject-${name}" "expected exactly one failed check, got ${fail_count}"
        fi
    fi
}

run_mutation "schema-report-id" "reportId" '"not-a-uuid"' "report-schema"
run_mutation "schema-missing-id" "reportId" '__DELETE__' "report-schema"
run_mutation "not-elevated" "isElevated" 'false' "report-elevated"
run_mutation "stale-report" "collectedAtUtc" '"2020-01-01T00:00:00Z"' "report-fresh"
run_mutation "future-report" "collectedAtUtc" '"2099-01-01T00:00:00Z"' "report-fresh"
run_mutation "virtual-qemu" "bareMetal.manufacturer" '"QEMU"' "report-bare-metal"
run_mutation "virtual-flag" "bareMetal.isBareMetal" 'false' "report-bare-metal"
run_mutation "virtual-hyperv" "bareMetal.model" '"Virtual Machine"' "report-bare-metal"
run_mutation "computer-name" "os.computerName" '"DESKTOP-ABC"' "os-computer-name"
run_mutation "build" "os.build" '"19044"' "os-build"
run_mutation "firmware-bios" "os.firmwareType" '"Bios"' "os-uefi"
run_mutation "portable-off" "os.portableOperatingSystem" 'false' "os-portable"
run_mutation "boot-media-nvme" "systemVolume.busType" '"NVMe"' "os-boot-media"
run_mutation "secureboot-off" "firmware.secureBootEnabled" 'false' "secureboot-enabled"
run_mutation "secureboot-setup-mode" "firmware.secureBootSetupMode" 'true' "secureboot-enabled"
run_mutation "tpm-not-ready" "tpm.ready" 'false' "tpm-present"
run_mutation "tpm-v1" "tpm.specVersion" '"1.2"' "tpm-v2"
run_mutation "tpm-no-ek" "tpm.ekPublicKeyHashSha256" '""' "tpm-ek"
run_mutation "defender-service" "defender.serviceState" '"Stopped"' "defender-service"
run_mutation "defender-realtime" "defender.realTimeProtectionEnabled" 'false' "defender-realtime"
run_mutation "defender-tamper" "defender.tamperProtectionEnabled" 'false' "defender-tamper"
run_mutation "defender-signatures" "defender.signatureAgeDays" '99' "defender-signatures"
run_mutation "ci-tpm-sys" "codeIntegrity.tpmSysPresent" 'false' "code-integrity-files"
run_mutation "testsigning" "codeIntegrity.testSigningEnabled" 'true' "code-integrity-testsigning"
run_mutation "kernel-debug" "codeIntegrity.kernelDebugEnabled" 'true' "code-integrity-kernel-debug"
run_mutation "driver-blocklist" "codeIntegrity.driverBlocklistEnabled" 'false' "code-integrity-driver-blocklist"
run_mutation "hvci-policy" "codeIntegrity.hvciPolicyDisabled" 'true' "code-integrity-hvci"
run_mutation "vanguard-service" "vanguard.vgcServiceState" '"Stopped"' "vanguard-service"
run_mutation "vanguard-driver" "vanguard.vgkDriverLoaded" 'false' "vanguard-driver"
run_mutation "vanguard-signature" "vanguard.vgkSigner" '"CN=Not Riot"' "vanguard-signature"
run_mutation "kiosk-shell" "kiosk.shell" '"explorer.exe"' "kiosk-shell"
run_mutation "kiosk-marker" "kiosk.bootVerifiedMarker" 'false' "kiosk-marker"
run_mutation "kiosk-user" "kiosk.user" '"Administrator"' "kiosk-user"

INVALID_JSON="${WORK_DIR}/invalid.json"
printf '{not json\n' > "$INVALID_JSON"
if "$ATTEST_SCRIPT" --report "$INVALID_JSON" > "${WORK_DIR}/invalid.out" 2>&1; then
    fail "reject-invalid-json" "validator accepted invalid JSON"
elif grep -Fq -- '[FAIL] report-schema:' "${WORK_DIR}/invalid.out"; then
    pass "reject-invalid-json" "report-schema rejected invalid JSON"
else
    fail "reject-invalid-json" "invalid JSON failed without report-schema"
fi

# ---------------------------------------------------------------------------
# CLI safety guards (these fail before any device write)
# ---------------------------------------------------------------------------
expect_failure() {
    local id="$1" needle="$2"
    shift 2
    local out="${WORK_DIR}/guard-${id}.out"
    if "$ATTEST_SCRIPT" "$@" > "$out" 2>&1; then
        fail "$id" "command unexpectedly succeeded: $*"
    elif grep -Fq -- "$needle" "$out"; then
        pass "$id" "rejected: ${needle}"
    else
        fail "$id" "failed without the expected message: ${needle}"
    fi
}

expect_failure "guard-prepare-commit" "--prepare writes to the card and requires --commit" --prepare --target /dev/null
expect_failure "guard-commit-without-prepare" "--commit is only valid with --prepare" --commit --target /dev/null
expect_failure "guard-yes-without-commit" "--yes is only valid with --commit" --yes
expect_failure "guard-target-report" "--target and --report are mutually exclusive" --target /dev/null --report /dev/null
expect_failure "guard-prepare-target" "--prepare requires --target" --prepare
expect_failure "guard-report-outside-tree" \
    "Report path must stay inside the project tree" --report /etc/os-release

# ---------------------------------------------------------------------------
# Loop-image target tests: layout, GPT/marker binding, missing report, prepare
# ---------------------------------------------------------------------------
log "Creating a disposable 1 GiB GPT/ValOS loop image"
rm -f -- "$IMAGE"
truncate -s 1G -- "$IMAGE" || die "image-create" "cannot create $IMAGE"
parted -s -- "$IMAGE" mklabel gpt \
    mkpart ESP fat32 1MiB 17MiB set 1 esp on \
    mkpart ValOS ntfs 17MiB 529MiB \
    || die "image-partition" "parted failed"
LOOP_DEV="$(losetup --find --show --partscan "$IMAGE")" \
    || die "loop-attach" "cannot attach $IMAGE"
LOOP_DEV="$(readlink -f -- "$LOOP_DEV")" || die "loop-attach" "cannot resolve loop path"
partprobe -- "$LOOP_DEV" >/dev/null 2>&1 || true
udevadm settle --timeout=30 || true
[[ -b "${LOOP_DEV}p2" ]] || die "loop-partition" "partition 2 did not appear"
mkntfs -F -L VAL_OS "${LOOP_DEV}p2" >"${WORK_DIR}/mkntfs.log" 2>&1 \
    || die "image-format" "mkntfs failed"
pass "image-create" "created 1 GiB GPT image with an NTFS ValOS partition at $LOOP_DEV"

mapfile -t IMAGE_GUIDS < <(python3 - "$LOOP_DEV" <<'PY'
import os
import struct
import sys
import uuid

path = sys.argv[1]
sector = 512
fd = os.open(path, os.O_RDONLY)
try:
    os.lseek(fd, sector, os.SEEK_SET)
    header = os.read(fd, 92)
    disk = uuid.UUID(bytes_le=header[56:72])
    entry_lba = struct.unpack_from("<Q", header, 72)[0]
    count = struct.unpack_from("<I", header, 80)[0]
    size = struct.unpack_from("<I", header, 84)[0]
    os.lseek(fd, entry_lba * sector, os.SEEK_SET)
    entries = os.read(fd, count * size)
    entry = entries[size:size * 2]
    part = uuid.UUID(bytes_le=entry[16:32])
finally:
    os.close(fd)
print(disk)
print(part)
PY
)
[[ ${#IMAGE_GUIDS[@]} -eq 2 ]] || die "image-gpt" "cannot read the image GPT GUIDs"
pass "image-gpt" "read image GPT GUIDs ${IMAGE_GUIDS[0]} / ${IMAGE_GUIDS[1]}"

MARKER_TEXT="Valorant Console OS Phase 5 test marker"
printf '%s\n' "$MARKER_TEXT" > "${WORK_DIR}/boot_verified.txt"
MARKER_HASH="$(sha256sum -- "${WORK_DIR}/boot_verified.txt" | cut -d' ' -f1)"

CARD_REPORT="${WORK_DIR}/card-report.json"
python3 - "$VALID_REPORT" "$CARD_REPORT" "${IMAGE_GUIDS[0]}" "${IMAGE_GUIDS[1]}" "$MARKER_HASH" <<'PY'
import json
import sys

src, dst, disk_guid, part_guid, marker_hash = sys.argv[1:6]
data = json.load(open(src, encoding="utf-8"))
data["systemVolume"]["diskGuid"] = disk_guid.replace("-", "")
data["systemVolume"]["partitionGuid"] = part_guid.replace("-", "")
data["kiosk"]["bootVerifiedContentSha256"] = marker_hash
json.dump(data, open(dst, "w", encoding="utf-8"), indent=2)
PY

mount_image_rw() {
    ntfs-3g -o rw,force "${LOOP_DEV}p2" "${WORK_DIR}/mnt" 2>"${WORK_DIR}/mount.err" \
        || die "image-mount" "cannot mount ${LOOP_DEV}p2 read-write"
    IMAGE_MOUNTED=1
}

mount_image_ro() {
    ntfs-3g -o ro,force "${LOOP_DEV}p2" "${WORK_DIR}/mnt" 2>"${WORK_DIR}/mount.err" \
        || die "image-mount" "cannot mount ${LOOP_DEV}p2 read-only"
    IMAGE_MOUNTED=1
}

unmount_image() {
    local i
    if (( IMAGE_MOUNTED )); then
        sync 2>/dev/null || true
        for ((i = 0; i < 10; i++)); do
            if umount -- "${WORK_DIR}/mnt" 2>/dev/null; then
                IMAGE_MOUNTED=0
                return 0
            fi
            sleep 0.5
        done
        # Safe for the disposable loop image after the sync above.
        if umount -l -- "${WORK_DIR}/mnt" 2>/dev/null; then
            IMAGE_MOUNTED=0
            return 0
        fi
        die "image-unmount" "cannot unmount the test image"
    fi
    return 0
}

mount_image_rw
mkdir -p -- "${WORK_DIR}/mnt/Windows/System32/config" "${WORK_DIR}/mnt/Riot Games"
: > "${WORK_DIR}/mnt/Windows/System32/config/SYSTEM"
: > "${WORK_DIR}/mnt/Windows/System32/config/SOFTWARE"
cp -- "${WORK_DIR}/boot_verified.txt" "${WORK_DIR}/mnt/Riot Games/boot_verified.txt"
cp -- "$CARD_REPORT" "${WORK_DIR}/mnt/Riot Games/phase5_attestation.json"
sync
unmount_image

TARGET_OUT="${WORK_DIR}/target-valid.out"
if "$ATTEST_SCRIPT" --target "$LOOP_DEV" > "$TARGET_OUT" 2>&1; then
    target_pass_count="$(grep -c '^\[PASS\] [a-z]' "$TARGET_OUT" || true)"
    if [[ "$target_pass_count" == "37" ]] && ! grep -Fq -- '[FAIL]' "$TARGET_OUT"; then
        pass "target-valid" "card report passed all 37 target and report checks"
    else
        fail "target-valid" "target report passed ${target_pass_count:-0} checks, expected 37"
    fi
else
    fail "target-valid" "validator rejected the valid card report"
fi

mutate_card_report() {
    local name="$1" json_path="$2" json_value="$3"
    python3 - "$CARD_REPORT" "${WORK_DIR}/card-${name}.json" "$json_path" "$json_value" <<'PY'
import json
import sys

src, dst, dotted, raw_value = sys.argv[1:5]
data = json.load(open(src, encoding="utf-8"))
value = json.loads(raw_value)
current = data
parts = dotted.split(".")
for part in parts[:-1]:
    current = current[part]
current[parts[-1]] = value
json.dump(data, open(dst, "w", encoding="utf-8"), indent=2)
PY
    mount_image_rw
    cp -- "${WORK_DIR}/card-${name}.json" "${WORK_DIR}/mnt/Riot Games/phase5_attestation.json"
    sync
    unmount_image
}

mutate_card_report "bad-gpt" "systemVolume.diskGuid" '"ffffffffffffffffffffffffffffffff"'
if "$ATTEST_SCRIPT" --target "$LOOP_DEV" > "${WORK_DIR}/target-bad-gpt.out" 2>&1; then
    fail "target-gpt-binding" "validator accepted a report with the wrong GPT GUID"
elif grep -Fq -- '[FAIL] card-binding-gpt:' "${WORK_DIR}/target-bad-gpt.out"; then
    pass "target-gpt-binding" "card-binding-gpt rejected a mismatched disk GUID"
else
    fail "target-gpt-binding" "mismatched GPT failed without card-binding-gpt"
fi

python3 - "$CARD_REPORT" "${WORK_DIR}/card-bad-marker.json" <<'PY'
import json
import sys

src, dst = sys.argv[1:3]
data = json.load(open(src, encoding="utf-8"))
data["kiosk"]["bootVerifiedContentSha256"] = "c" * 64
json.dump(data, open(dst, "w", encoding="utf-8"), indent=2)
PY
mount_image_rw
cp -- "${WORK_DIR}/card-bad-marker.json" "${WORK_DIR}/mnt/Riot Games/phase5_attestation.json"
sync
unmount_image
if "$ATTEST_SCRIPT" --target "$LOOP_DEV" > "${WORK_DIR}/target-bad-marker.out" 2>&1; then
    fail "target-marker-binding" "validator accepted a report with the wrong boot-marker hash"
elif grep -Fq -- '[FAIL] card-binding-marker:' "${WORK_DIR}/target-bad-marker.out"; then
    pass "target-marker-binding" "card-binding-marker rejected a mismatched boot-marker hash"
else
    fail "target-marker-binding" "mismatched marker failed without card-binding-marker"
fi

mount_image_rw
cp -- "$CARD_REPORT" "${WORK_DIR}/mnt/Riot Games/phase5_attestation.json"
sync
unmount_image

mount_image_rw
rm -f -- "${WORK_DIR}/mnt/Riot Games/phase5_attestation.json"
sync
unmount_image
if "$ATTEST_SCRIPT" --target "$LOOP_DEV" > "${WORK_DIR}/target-missing.out" 2>&1; then
    fail "target-missing-report" "validator accepted a card without a report"
elif grep -Fq -- '[FAIL] report-present:' "${WORK_DIR}/target-missing.out"; then
    pass "target-missing-report" "report-present failed closed on a card without a report"
else
    fail "target-missing-report" "missing report failed without report-present"
fi

# Restore the report, then prove --prepare installs CRLF collector files.
mount_image_rw
cp -- "$CARD_REPORT" "${WORK_DIR}/mnt/Riot Games/phase5_attestation.json"
sync
unmount_image

if "$ATTEST_SCRIPT" --target "$LOOP_DEV" --prepare --commit --yes \
    > "${WORK_DIR}/prepare.out" 2>&1; then
    prepare_pass_count="$(grep -c '^\[PASS\] [a-z]' "${WORK_DIR}/prepare.out" || true)"
    if [[ "$prepare_pass_count" == "8" ]] && ! grep -Fq -- '[FAIL]' "${WORK_DIR}/prepare.out"; then
        pass "target-prepare" "prepare installed the collector with 8 passing checks"
    else
        fail "target-prepare" "prepare passed ${prepare_pass_count:-0} checks, expected 8"
    fi
else
    fail "target-prepare" "prepare exited non-zero"
fi

mount_image_ro
if [[ -f "${WORK_DIR}/mnt/Riot Games/phase5_attest.ps1" ]] \
    && [[ -f "${WORK_DIR}/mnt/Riot Games/phase5_attest.cmd" ]] \
    && grep -q $'\r' "${WORK_DIR}/mnt/Riot Games/phase5_attest.ps1" \
    && grep -q $'\r' "${WORK_DIR}/mnt/Riot Games/phase5_attest.cmd"; then
    pass "target-prepare-files" "collector and launcher are installed with CRLF endings"
else
    fail "target-prepare-files" "prepared collector files are missing or not CRLF"
fi
unmount_image

if "$ATTEST_SCRIPT" --target "$LOOP_DEV" --prepare --commit < /dev/null \
    > "${WORK_DIR}/prepare-guard.out" 2>&1; then
    fail "guard-prepare-yes" "prepare without --yes unexpectedly succeeded"
elif grep -Fq -- '--yes is required' "${WORK_DIR}/prepare-guard.out"; then
    pass "guard-prepare-yes" "prepare refused a non-interactive commit without --yes"
else
    fail "guard-prepare-yes" "prepare failed without the --yes guard"
fi

# ---------------------------------------------------------------------------
# Real hardware gate
# ---------------------------------------------------------------------------
if (( SELF_TEST )); then
    summary
fi

HARDWARE_OUT="${WORK_DIR}/hardware.out"
if [[ -n "$TARGET" ]]; then
    HW_TARGET="$(readlink -f -- "$TARGET")" \
        || die "hardware-target" "cannot resolve target: $TARGET"
    read -r HW_TYPE HW_RM < <(
        lsblk -dn -o TYPE,RM -- "$HW_TARGET" 2>/dev/null || true
    )
    if [[ "$HW_TYPE" == "disk" && "$HW_RM" == "1" ]]; then
        pass "hardware-target-removable" "$HW_TARGET is a whole removable disk (RM=1)"
        if "$ATTEST_SCRIPT" --target "$TARGET" > "$HARDWARE_OUT" 2>&1; then
            pass "hardware-attestation" "physical card report passed the Phase 5 validator"
        else
            cat -- "$HARDWARE_OUT" >&2 || true
            fail "hardware-attestation" "physical card report failed validation"
        fi
    else
        fail "hardware-target-removable" \
            "the hardware gate requires a whole RM=1 disk; $HW_TARGET is TYPE=${HW_TYPE:-unknown} RM=${HW_RM:-unknown} (use --self-test for loop images)"
    fi
elif [[ -n "$REPORT" ]]; then
    if "$ATTEST_SCRIPT" --report "$REPORT" > "$HARDWARE_OUT" 2>&1; then
        pass "offline-report" "copied report passed the Phase 5 validator; card binding was not checked"
    else
        cat -- "$HARDWARE_OUT" >&2 || true
        fail "offline-report" "copied report failed validation"
    fi
else
    DEFAULT_REPORT="${PROJECT_ROOT}/build/phase5/phase5_attestation.json"
    if [[ -f "$DEFAULT_REPORT" ]]; then
        if "$ATTEST_SCRIPT" --report "$DEFAULT_REPORT" > "$HARDWARE_OUT" 2>&1; then
            pass "offline-report" "build/phase5 report passed the Phase 5 validator; card binding was not checked"
        else
            cat -- "$HARDWARE_OUT" >&2 || true
            fail "offline-report" "build/phase5 report failed validation"
        fi
    else
        fail "hardware-attestation" "no bare-metal report; run --self-test now, then boot the card and use --target"
    fi
fi

summary
