#!/usr/bin/env bash
# Phase 4 verification gate: prove the microSD writer rejects unsafe targets,
# refuses to write without explicit confirmation, deploys the prepared WIM to a
# disposable 25 GiB loop image, and verifies the result by reading it back.
#
# Destructive scope: vm-test/p4_sdcard.img only.  Host block devices are never
# touched.  Run as root through pkexec or sudo (loop devices and mounts).

set -Eeuo pipefail
IFS=$'\n\t'

PROJECT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
readonly PROJECT_ROOT

readonly WRITE_SCRIPT="${PROJECT_ROOT}/scripts/04_write_sdcard.sh"
readonly TEST_DIR="${PROJECT_ROOT}/vm-test"
readonly IMAGE="${TEST_DIR}/p4_sdcard.img"
readonly FIXTURES="${PROJECT_ROOT}/tests/fixtures/phase04"
readonly LOG_DIR="${PROJECT_ROOT}/build/logs"
readonly LOG="${LOG_DIR}/test_04_sdcard.log"
readonly WORK_DIR="${TEST_DIR}/p4-verify"
readonly DRY_OUT="${TEST_DIR}/p4-dry-run.out"
readonly GUARD_OUT="${TEST_DIR}/p4-guard.out"
readonly BLANK_OUT="${TEST_DIR}/p4-blank.out"
readonly COMMIT_OUT="${TEST_DIR}/p4-commit.out"
readonly VERIFY_OUT="${TEST_DIR}/p4-verify-only.out"
readonly COMMIT_MARKER="${TEST_DIR}/p4-commit.marker"

mkdir -p -- "$LOG_DIR" "$TEST_DIR" "$WORK_DIR"
: > "$LOG"
exec > >(tee -a "$LOG") 2>&1

PASS=0
FAIL=0
FAILED_CHECKS=()
LOOP_DEV=""
REMOVE_IMAGE=0

pass() {
    PASS=$((PASS + 1))
    printf '[PASS] %s: %s\n' "$1" "$2"
}

fail() {
    FAIL=$((FAIL + 1))
    FAILED_CHECKS+=("$1")
    printf '[FAIL] %s: %s\n' "$1" "$2"
}

summary() {
    printf '\n[phase04-test] Passed: %d  Failed: %d\n' "$PASS" "$FAIL"
    if (( FAIL > 0 )); then
        printf '[FAIL] Phase 4 microSD write/read-back gate failed: %s\n' \
            "${FAILED_CHECKS[*]}" >&2
        exit 1
    fi
    REMOVE_IMAGE=1
    printf '[PASS] Phase 4 microSD write/read-back gate passed\n'
    exit 0
}

die() {
    fail "$1" "$2"
    summary
}

log() { printf '[phase04-test] %s\n' "$*"; }

cleanup() {
    local rc=$? mountpoint_path
    trap - EXIT
    set +e
    for mountpoint_path in "$WORK_DIR/mnt-ntfs" "$WORK_DIR/mnt-rw" "$WORK_DIR/mnt-esp"; do
        if mountpoint -q -- "$mountpoint_path" 2>/dev/null; then
            umount -- "$mountpoint_path" 2>/dev/null \
                || umount -l -- "$mountpoint_path" 2>/dev/null || true
        fi
    done
    if [[ -n "$LOOP_DEV" ]]; then
        losetup -d "$LOOP_DEV" 2>/dev/null || true
    fi
    sync 2>/dev/null || true
    if (( REMOVE_IMAGE )) && [[ -f "$IMAGE" ]]; then
        rm -f -- "$IMAGE"
        printf '[phase04-test] Removed disposable image: %s\n' "$IMAGE"
    elif [[ -f "$IMAGE" ]]; then
        printf '[phase04-test] Kept test image for debugging: %s\n' "$IMAGE"
    fi
    exit "$rc"
}
trap cleanup EXIT
trap 'rc=$?; printf "[FAIL] phase04-test aborted unexpectedly at line %s (exit %s)\n" "$LINENO" "$rc" >&2' ERR

sha_file() {
    local file="$1" digest
    digest="$(sha256sum -- "$file" | cut -d' ' -f1)" || return 1
    printf '%s' "$digest"
}

accept_fixture() {
    local id="$1" fixture="$2" out
    out="${TEST_DIR}/fixture-${id}.out"
    if "$WRITE_SCRIPT" --check-lsblk-fixture "${FIXTURES}/${fixture}" \
        > "$out" 2>&1; then
        pass "$id" "validator accepted ${fixture}"
    else
        fail "$id" "validator rejected the safe fixture ${fixture}"
    fi
}

reject_fixture() {
    local id="$1" fixture="$2" needle="$3" out
    out="${TEST_DIR}/fixture-${id}.out"
    if "$WRITE_SCRIPT" --check-lsblk-fixture "${FIXTURES}/${fixture}" \
        > "$out" 2>&1; then
        fail "$id" "validator accepted the unsafe fixture ${fixture}"
    elif grep -Fq -- "$needle" "$out"; then
        pass "$id" "rejected ${fixture}: ${needle}"
    else
        fail "$id" "rejected ${fixture} without the expected message: ${needle}"
    fi
}

expect_cli_failure() {
    local id="$1" needle="$2" out
    shift 2
    out="${TEST_DIR}/cli-${id}.out"
    if "$WRITE_SCRIPT" "$@" > "$out" 2>&1; then
        fail "$id" "command unexpectedly succeeded: $*"
    elif grep -Fq -- "$needle" "$out"; then
        pass "$id" "rejected unsafe CLI combination: ${needle}"
    else
        fail "$id" "failed without the expected message: ${needle}"
    fi
}

umount_quiet() {
    local mountpoint_path="$1"
    if mountpoint -q -- "$mountpoint_path" 2>/dev/null; then
        umount -- "$mountpoint_path" 2>/dev/null \
            || umount -l -- "$mountpoint_path" 2>/dev/null || true
    fi
}

# ---------------------------------------------------------------------------
# Privileges and disposable target
# ---------------------------------------------------------------------------
if (( EUID != 0 )); then
    printf '[FAIL] root-privileges: run this gate as root (pkexec or sudo)\n' >&2
    exit 1
fi

command -v truncate >/dev/null 2>&1 || die "tool-truncate" "truncate is required"
command -v losetup >/dev/null 2>&1 || die "tool-losetup" "losetup is required"
command -v ntfs-3g >/dev/null 2>&1 || die "tool-ntfs3g" "ntfs-3g is required"
command -v reged >/dev/null 2>&1 || die "tool-reged" "reged is required"
command -v python3 >/dev/null 2>&1 || die "tool-python3" "python3 is required"

rm -f -- "$IMAGE"
truncate -s 25G -- "$IMAGE" || die "image-create" "cannot create $IMAGE"
pass "image-create" "created 25 GiB sparse disposable image at $IMAGE"

LOOP_DEV="$(losetup --find --show --partscan "$IMAGE")" \
    || die "loop-attach" "could not attach $IMAGE to a loop device"
LOOP_DEV="$(readlink -f -- "$LOOP_DEV")" || die "loop-attach" "cannot resolve the loop device"
[[ -b "$LOOP_DEV" ]] || die "loop-attach" "not a block device: $LOOP_DEV"
pass "loop-attach" "attached $IMAGE at $LOOP_DEV"

PRE_HASH="$(sha_file "$IMAGE")" || die "image-hash" "cannot hash $IMAGE"

# ---------------------------------------------------------------------------
# lsblk validator fixtures
# ---------------------------------------------------------------------------
accept_fixture "fixture-safe-loop" "safe-loop.json"
accept_fixture "fixture-safe-removable" "safe-removable.json"
reject_fixture "reject-nvme-root" "nvme-root.json" "Refusing NVMe"
reject_fixture "reject-nvme-partition" "nvme-partition.json" "Refusing NVMe"
reject_fixture "reject-host-mounted" "host-mounted.json" "mounted: /boot/efi"
reject_fixture "reject-root-mounted" "root-mounted.json" "mounted: /"
reject_fixture "reject-swap" "swap.json" "active as swap"
reject_fixture "reject-read-only" "read-only.json" "Refusing read-only"
reject_fixture "reject-partition" "partition.json" "not TYPE=part"
reject_fixture "reject-non-removable" "non-removable.json" "Refusing non-removable"
reject_fixture "reject-stacked" "stacked.json" "stacked device-mapper"
reject_fixture "reject-multiple-roots" "multiple-roots.json" "expected exactly one root"
reject_fixture "reject-zero-roots" "zero-roots.json" "expected exactly one root"
reject_fixture "reject-invalid-json" "invalid.json" "invalid lsblk JSON"

# ---------------------------------------------------------------------------
# CLI and confirmation guards
# ---------------------------------------------------------------------------
expect_cli_failure "guard-yes-without-commit" "--yes is only valid with --commit" --yes
expect_cli_failure "guard-commit-verify-conflict" "mutually exclusive" \
    --target "$LOOP_DEV" --commit --verify-only

log "Dry-run must validate without writing"
if "$WRITE_SCRIPT" --target "$LOOP_DEV" > "$DRY_OUT" 2>&1; then
    if ! grep -Fq -- '[PASS] dry-run:' "$DRY_OUT"; then
        fail "dry-run-no-write" "dry-run did not report [PASS] dry-run"
    elif [[ "$(sha_file "$IMAGE")" != "$PRE_HASH" ]]; then
        fail "dry-run-no-write" "dry-run modified the target image"
    else
        pass "dry-run-no-write" "dry-run reported success and left the image byte-identical"
    fi
else
    fail "dry-run-no-write" "dry-run exited non-zero; see $DRY_OUT"
fi
if [[ ! -e "${LOOP_DEV}p1" && ! -e "${LOOP_DEV}p2" ]]; then
    pass "dry-run-no-partitions" "dry-run did not create partition nodes"
else
    fail "dry-run-no-partitions" "dry-run unexpectedly created partition nodes"
fi

log "Commit without --yes must refuse before any write"
if "$WRITE_SCRIPT" --target "$LOOP_DEV" --commit < /dev/null > "$GUARD_OUT" 2>&1; then
    fail "guard-commit-requires-yes" "commit without --yes unexpectedly succeeded"
elif ! grep -Fq -- '--yes is required' "$GUARD_OUT"; then
    fail "guard-commit-requires-yes" "missing the non-interactive --yes guard"
elif [[ "$(sha_file "$IMAGE")" != "$PRE_HASH" ]]; then
    fail "guard-commit-requires-yes" "the guard path modified the target image"
else
    pass "guard-commit-requires-yes" "commit refused without --yes and left the image untouched"
fi

log "Verify-only on a blank image must fail closed"
if "$WRITE_SCRIPT" --target "$LOOP_DEV" --verify-only > "$BLANK_OUT" 2>&1; then
    fail "verify-only-rejects-blank" "verify-only accepted a blank image"
elif grep -Fq -- '[FAIL] gpt-protective-mbr:' "$BLANK_OUT" \
    && grep -Fq -- '[FAIL] Phase 4 microSD write/read-back failed' "$BLANK_OUT"; then
    pass "verify-only-rejects-blank" "blank image failed GPT read-back with a non-zero exit"
else
    fail "verify-only-rejects-blank" "blank image failed without the expected GPT diagnostics"
fi

# ---------------------------------------------------------------------------
# Commit to the disposable loop image
# ---------------------------------------------------------------------------
touch -- "$COMMIT_MARKER"
log "Committing the prepared WIM to $LOOP_DEV (this takes several minutes)"
COMMIT_START="$(date +%s)"
if timeout 7200 "$WRITE_SCRIPT" --target "$LOOP_DEV" --commit --yes --full-read \
    > "$COMMIT_OUT" 2>&1; then
    COMMIT_SECONDS=$(( $(date +%s) - COMMIT_START ))
    pass "commit-exit" "writer completed in ${COMMIT_SECONDS}s with --commit --yes --full-read"
else
    COMMIT_RC=$?
    fail "commit-exit" "writer exited ${COMMIT_RC}; see $COMMIT_OUT"
    summary
fi

# ---------------------------------------------------------------------------
# Required writer checks
# ---------------------------------------------------------------------------
if grep -Fq -- '[FAIL]' "$COMMIT_OUT"; then
    fail "commit-no-failures" "the writer reported at least one [FAIL]"
else
    pass "commit-no-failures" "the writer completed without [FAIL] lines"
fi

REQUIRED_PASS_IDS=(
    gpt-protective-mbr
    gpt-header
    gpt-layout
    esp-mount
    esp-boot-files
    esp-bcd-system-store
    esp-bcd-device-paths
    ntfs-mount
    payload-sd-survival
    payload-val-kiosk
    payload-switch-mode
    payload-kb-cab
    payload-autounattend
    system-portable-os
    system-poll-boot-timeout
    system-storage-drivers
    invariant-service-WinDefend
    invariant-service-SecurityHealthService
    invariant-service-TPM
    invariant-defender-policy
    invariant-file-ci.dll
    invariant-file-tpm.sys
    full-read
    manifest
    deploy-engine
)
MISSING_IDS=()
for required_id in "${REQUIRED_PASS_IDS[@]}"; do
    if ! grep -Fq -- "[PASS] ${required_id}:" "$COMMIT_OUT"; then
        MISSING_IDS+=("$required_id")
    fi
done
if (( ${#MISSING_IDS[@]} == 0 )); then
    pass "commit-required-checks" "all ${#REQUIRED_PASS_IDS[@]} writer read-back checks passed"
else
    fail "commit-required-checks" "missing writer [PASS] lines: ${MISSING_IDS[*]}"
fi

# ---------------------------------------------------------------------------
# Independent GPT verification
# ---------------------------------------------------------------------------
TOTAL_SECTORS="$(blockdev --getsz "$LOOP_DEV")" \
    || die "independent-gpt" "cannot read the target sector count"
log "Verifying GPT independently from the writer's output"
if python3 - "$LOOP_DEV" "$TOTAL_SECTORS" <<'PY'
import os
import struct
import sys
import zlib

path = sys.argv[1]
total = int(sys.argv[2])
sector = 512


def read_at(fd, offset, length):
    os.lseek(fd, offset, os.SEEK_SET)
    data = b""
    while len(data) < length:
        chunk = os.read(fd, length - len(data))
        if not chunk:
            raise IOError("short read")
        data += chunk
    return data


def parse(fd, lba):
    header = read_at(fd, lba * sector, 92)
    (signature, revision, header_size, header_crc, reserved,
     current_lba, backup_lba, first_usable, last_usable,
     disk_guid, entry_lba, entry_count, entry_size,
     array_crc) = struct.unpack_from("<8sIIIIQQQQ16sQIII", header, 0)
    if signature != b"EFI PART":
        raise ValueError(f"bad signature at LBA {lba}")
    full = read_at(fd, lba * sector, header_size)
    check = bytearray(full)
    check[16:20] = b"\x00\x00\x00\x00"
    if zlib.crc32(check) & 0xffffffff != header_crc:
        raise ValueError(f"header CRC at LBA {lba}")
    entries = read_at(fd, entry_lba * sector, entry_count * entry_size)
    if zlib.crc32(entries) & 0xffffffff != array_crc:
        raise ValueError(f"array CRC at LBA {entry_lba}")
    return {
        "current": current_lba,
        "backup": backup_lba,
        "first": first_usable,
        "last": last_usable,
        "guid": disk_guid,
        "entries": entries,
        "entry_size": entry_size,
    }


fd = os.open(path, os.O_RDONLY)
try:
    mbr = read_at(fd, 0, 512)
    if mbr[510:512] != b"\x55\xaa" or mbr[450] != 0xEE:
        raise ValueError("protective MBR missing")
    primary = parse(fd, 1)
    if primary["current"] != 1 or primary["backup"] != total - 1:
        raise ValueError("primary GPT pointers are wrong")
    backup = parse(fd, primary["backup"])
    if backup["current"] != primary["backup"] or backup["backup"] != 1:
        raise ValueError("backup GPT pointers are wrong")
    if backup["guid"] != primary["guid"] or backup["entries"] != primary["entries"]:
        raise ValueError("backup GPT differs from the primary")

    size = primary["entry_size"]
    parts = []
    for index in range(2):
        entry = primary["entries"][index * size:(index + 1) * size]
        part_type = entry[0:16]
        first_lba, last_lba = struct.unpack_from("<QQ", entry, 32)
        name = entry[56:128].decode("utf-16le", "replace").split("\x00", 1)[0]
        parts.append((part_type, first_lba, last_lba, name))

    esp, os_part = parts
    if esp[0] != bytes.fromhex("28732ac11ff8d211ba4b00a0c93ec93b"):
        raise ValueError("partition 1 is not an ESP")
    if esp[1] != 2048 or esp[2] != 534527 or esp[3] != "ESP":
        raise ValueError("ESP geometry or name is wrong")
    if os_part[0] != bytes.fromhex("a2a0d0ebe5b9334487c068b6b72699c7"):
        raise ValueError("partition 2 is not msftdata")
    if os_part[1] != 534528 or os_part[2] <= os_part[1] or os_part[3] != "ValOS":
        raise ValueError("ValOS geometry or name is wrong")
except Exception as exc:
    print(f"independent GPT check failed: {exc}", file=sys.stderr)
    raise SystemExit(1)
finally:
    os.close(fd)
PY
then
    pass "independent-gpt" "GPT headers, CRCs, and ESP/ValOS geometry are valid"
else
    fail "independent-gpt" "raw GPT validation failed"
fi

# ---------------------------------------------------------------------------
# Independent ESP read-back
# ---------------------------------------------------------------------------
ESP_MNT="$WORK_DIR/mnt-esp"
mkdir -p -- "$ESP_MNT"
if mount -o ro "${LOOP_DEV}p1" "$ESP_MNT" 2>"${WORK_DIR}/ind-esp.err"; then
    ESP_OK=1
    if [[ -f "$ESP_MNT/EFI/Boot/bootx64.efi" \
        && -f "$ESP_MNT/EFI/Microsoft/Boot/bootmgfw.efi" ]] \
        && cmp -s -- "$ESP_MNT/EFI/Boot/bootx64.efi" \
                    "$ESP_MNT/EFI/Microsoft/Boot/bootmgfw.efi"; then
        :
    else
        ESP_OK=0
    fi
    if [[ -f "$ESP_MNT/EFI/Microsoft/Boot/BCD" ]]; then
        cp -- "$ESP_MNT/EFI/Microsoft/Boot/BCD" "${WORK_DIR}/BCD.independent" \
            || ESP_OK=0
        reged -x "${WORK_DIR}/BCD.independent" 'HKEY_LOCAL_MACHINE\BCD00000000' \
            'Description' "${WORK_DIR}/bcd.independent.reg" >/dev/null 2>&1 || true
        if [[ -s "${WORK_DIR}/bcd.independent.reg" ]]; then
            tr -d '\r' < "${WORK_DIR}/bcd.independent.reg" \
                > "${WORK_DIR}/bcd.independent.norm"
            if grep -Fq -- '"KeyName"="BCD00000000"' "${WORK_DIR}/bcd.independent.norm" \
                && grep -Fq -- '"System"=dword:00000001' "${WORK_DIR}/bcd.independent.norm" \
                && grep -Fq -- '"TreatAsSystem"=dword:00000001' "${WORK_DIR}/bcd.independent.norm"; then
                :
            else
                ESP_OK=0
            fi
        else
            ESP_OK=0
        fi
    else
        ESP_OK=0
    fi
    umount_quiet "$ESP_MNT"
    if (( ESP_OK )); then
        pass "independent-esp" "ESP boot files match and the BCD is a system store"
    else
        fail "independent-esp" "ESP boot files or BCD system-store markers are wrong"
    fi
else
    cat -- "${WORK_DIR}/ind-esp.err" >&2 || true
    fail "independent-esp" "could not mount ${LOOP_DEV}p1 read-only"
fi

# ---------------------------------------------------------------------------
# Independent NTFS payload and SYSTEM-hive read-back
# ---------------------------------------------------------------------------
NTFS_MNT="$WORK_DIR/mnt-ntfs"
mkdir -p -- "$NTFS_MNT"
if ntfs-3g -o ro,force "${LOOP_DEV}p2" "$NTFS_MNT" 2>"${WORK_DIR}/ind-ntfs.err"; then
    PAYLOAD_OK=1
    while IFS='|' read -r name rel; do
        [[ -n "$name" ]] || continue
        src="${PROJECT_ROOT}/payloads/${name}"
        dst="${NTFS_MNT}/${rel}"
        if [[ ! -f "$dst" || -L "$dst" ]]; then
            PAYLOAD_OK=0
            continue
        fi
        expected="$(sha_file "$src" || true)"
        actual="$(sha_file "$dst" || true)"
        if [[ -z "$expected" || "$actual" != "$expected" ]]; then
            PAYLOAD_OK=0
        fi
    done <<'EOF'
sd_survival_and_kiosk.cmd|Riot Games/sd_survival_and_kiosk.cmd
val-kiosk.bat|Riot Games/val-kiosk.bat
switch-mode.bat|Riot Games/switch-mode.bat
windows10.0-kb5015684-x64.cab|Riot Games/windows10.0-kb5015684-x64.cab
EOF
    if ! cmp -s -- "${PROJECT_ROOT}/payloads/autounattend.xml" \
        "${NTFS_MNT}/Windows/Panther/unattend.xml"; then
        PAYLOAD_OK=0
    fi
    if (( PAYLOAD_OK )); then
        pass "independent-payload-hashes" "all Riot Games payloads and the answer file match"
    else
        fail "independent-payload-hashes" "a payload hash or file is wrong on the target"
    fi

    SYSTEM_OK=1
    SYSTEM_HIVE="${NTFS_MNT}/Windows/System32/config/SYSTEM"
    if [[ -f "$SYSTEM_HIVE" ]]; then
        reged -x "$SYSTEM_HIVE" 'HKEY_LOCAL_MACHINE\SYSTEM' 'ControlSet001\Control' \
            "${WORK_DIR}/ind-control.reg" >/dev/null 2>&1 || true
        if [[ -s "${WORK_DIR}/ind-control.reg" ]]; then
            tr -d '\r' < "${WORK_DIR}/ind-control.reg" > "${WORK_DIR}/ind-control.norm"
            grep -Fq -- '"PortableOperatingSystem"=dword:00000001' \
                "${WORK_DIR}/ind-control.norm" || SYSTEM_OK=0
            grep -Fq -- '"PollBootPartitionTimeout"=dword:00007530' \
                "${WORK_DIR}/ind-control.norm" || SYSTEM_OK=0
        else
            SYSTEM_OK=0
        fi
        for service in USBSTOR UASPStor sdbus sdstor USBXHCI; do
            reged -x "$SYSTEM_HIVE" 'HKEY_LOCAL_MACHINE\SYSTEM' \
                "ControlSet001\\Services\\${service}" \
                "${WORK_DIR}/ind-${service}.reg" >/dev/null 2>&1 || true
            if [[ ! -s "${WORK_DIR}/ind-${service}.reg" ]]; then
                SYSTEM_OK=0
                continue
            fi
            tr -d '\r' < "${WORK_DIR}/ind-${service}.reg" \
                > "${WORK_DIR}/ind-${service}.norm"
            grep -Fq -- '"Start"=dword:00000000' \
                "${WORK_DIR}/ind-${service}.norm" || SYSTEM_OK=0
        done
        for pair in "WinDefend:2" "SecurityHealthService:3" "TPM:3"; do
            service="${pair%%:*}"
            expected_start="${pair#*:}"
            reged -x "$SYSTEM_HIVE" 'HKEY_LOCAL_MACHINE\SYSTEM' \
                "ControlSet001\\Services\\${service}" \
                "${WORK_DIR}/ind-${service}.reg" >/dev/null 2>&1 || true
            if [[ ! -s "${WORK_DIR}/ind-${service}.reg" ]]; then
                SYSTEM_OK=0
                continue
            fi
            tr -d '\r' < "${WORK_DIR}/ind-${service}.reg" \
                > "${WORK_DIR}/ind-${service}.norm"
            start_hex="$(grep -m1 -oE '"Start"=dword:[0-9a-fA-F]+' \
                "${WORK_DIR}/ind-${service}.norm" | cut -d: -f2 | tr -d '[:space:]' || true)"
            if [[ -z "$start_hex" || "$((16#$start_hex))" != "$expected_start" ]]; then
                SYSTEM_OK=0
            fi
        done
    else
        SYSTEM_OK=0
    fi
    for path in Windows/System32/ci.dll Windows/System32/drivers/tpm.sys; do
        if [[ ! -f "${NTFS_MNT}/${path}" && ! -L "${NTFS_MNT}/${path}" ]]; then
            SYSTEM_OK=0
        fi
    done
    umount_quiet "$NTFS_MNT"
    if (( SYSTEM_OK )); then
        pass "independent-system-hive" "portable-OS, boot timeout, storage drivers, and invariants are intact"
    else
        fail "independent-system-hive" "a SYSTEM-hive or invariant-file check failed"
    fi
else
    cat -- "${WORK_DIR}/ind-ntfs.err" >&2 || true
    fail "independent-payload-hashes" "could not mount ${LOOP_DEV}p2 read-only"
    fail "independent-system-hive" "could not mount ${LOOP_DEV}p2 read-only"
fi

# ---------------------------------------------------------------------------
# Manifest
# ---------------------------------------------------------------------------
mapfile -t MANIFESTS < <(
    find "$LOG_DIR" -maxdepth 1 -type f -name '04_manifest_*.env' \
        -newer "$COMMIT_MARKER" -printf '%T@ %p\n' 2>/dev/null \
        | sort -nr | cut -d' ' -f2-
)
if (( ${#MANIFESTS[@]} == 0 )); then
    fail "manifest" "no manifest newer than $COMMIT_MARKER"
else
    MANIFEST="${MANIFESTS[0]}"
    if grep -Fxq -- "TARGET=$LOOP_DEV" "$MANIFEST" \
        && grep -Fxq -- 'MODE=commit' "$MANIFEST" \
        && grep -Fxq -- "LOOP_BACKING=$IMAGE" "$MANIFEST" \
        && grep -Eq -- '^DISK_GUID=[0-9a-f]{32}$' "$MANIFEST" \
        && grep -Eq -- '^ESP_GUID=[0-9a-f]{32}$' "$MANIFEST" \
        && grep -Eq -- '^OS_GUID=[0-9a-f]{32}$' "$MANIFEST" \
        && grep -Eq -- '^FULL_READ_SHA256=[0-9a-f]{64}$' "$MANIFEST" \
        && grep -Fxq -- 'FULL_READ_PASSES=2' "$MANIFEST"; then
        pass "manifest" "manifest records the target, GPT GUIDs, and full-read digest"
    else
        fail "manifest" "manifest contents are incomplete: $MANIFEST"
    fi
fi

# ---------------------------------------------------------------------------
# --verify-only tolerates an answer file rewritten by first boot
# ---------------------------------------------------------------------------
log "Simulating a first-boot rewrite of unattend.xml for --verify-only"
PROCESSED_XML="${WORK_DIR}/unattend.processed.xml"
sed '3s/<settings pass="specialize">/<settings pass="specialize" wasPassProcessed="true">/' \
    "${PROJECT_ROOT}/payloads/autounattend.xml" > "$PROCESSED_XML"
RW_MNT="$WORK_DIR/mnt-rw"
mkdir -p -- "$RW_MNT"
MUTATION_OK=0
if cmp -s -- "${PROJECT_ROOT}/payloads/autounattend.xml" "$PROCESSED_XML"; then
    fail "verify-only-processed-setup" "could not create a processed answer file"
elif ntfs-3g -o rw,force "${LOOP_DEV}p2" "$RW_MNT" 2>"${WORK_DIR}/rw-mount.err"; then
    if cp -- "$PROCESSED_XML" "$RW_MNT/Windows/Panther/unattend.xml"; then
        sync
        if umount -- "$RW_MNT" 2>/dev/null; then
            MUTATION_OK=1
            pass "verify-only-processed-setup" "installed a processed answer file in the disposable image"
        else
            fail "verify-only-processed-setup" "could not unmount the read-write NTFS volume"
        fi
    else
        fail "verify-only-processed-setup" "could not replace unattend.xml"
        umount_quiet "$RW_MNT"
    fi
else
    cat -- "${WORK_DIR}/rw-mount.err" >&2 || true
    fail "verify-only-processed-setup" "could not mount the NTFS volume read-write"
fi

if (( MUTATION_OK )); then
    if "$WRITE_SCRIPT" --target "$LOOP_DEV" --verify-only > "$VERIFY_OUT" 2>&1; then
        if grep -Fq -- '[PASS] payload-autounattend:' "$VERIFY_OUT" \
            && ! grep -Fq -- '[FAIL]' "$VERIFY_OUT"; then
            pass "verify-only-success" "--verify-only accepted the rewritten answer file and all read-back checks"
        else
            fail "verify-only-success" "--verify-only passed without the expected processed-answer-file check"
        fi
    else
        fail "verify-only-success" "--verify-only exited non-zero; see $VERIFY_OUT"
    fi
else
    fail "verify-only-success" "skipped because the processed answer file could not be installed"
fi

summary
