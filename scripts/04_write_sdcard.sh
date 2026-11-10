#!/usr/bin/env bash
# Phase 4: write the verified Windows To Go image to a validated whole
# removable disk (microSD) and verify the result by an independent read-back.
#
# Destructive writes are delegated to 03_deploy_wtg.sh; this script adds an
# independent preflight, a post-write read-back of GPT/ESP/NTFS/SYSTEM, and an
# explicit manifest under build/logs/.  The default mode is a dry-run.
#
# Safety contract (see OpenCode.md Rule 2):
#   * Only a whole removable disk (RM=1) or a loop device backed by a file
#     under build/ or vm-test/ is accepted.
#   * nvme*, host-mounted devices, swap, read-only devices, partitions, busy
#     devices, stacked device-mapper children, and host-root ancestry are
#     rejected before the first write.
#   * --commit is required to write; --yes is required for non-interactive
#     commits.  --verify-only performs read-back without writing.

set -Eeuo pipefail
IFS=$'\n\t'

PROJECT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
readonly PROJECT_ROOT

readonly BUILD_DIR="${PROJECT_ROOT}/build"
readonly LOG_DIR="${BUILD_DIR}/logs"
readonly DEFAULT_WIM="${BUILD_DIR}/custom_install.wim"
readonly DEPLOY_SCRIPT="${PROJECT_ROOT}/scripts/03_deploy_wtg.sh"
readonly PAYLOAD_DIR="${PROJECT_ROOT}/payloads"

# Byte-based geometry (the deploy engine partitions with parted's MiB units).
readonly ESP_START_BYTES=$((1 * 1024 * 1024))
readonly ESP_END_BYTES=$((261 * 1024 * 1024))
readonly OS_START_BYTES=$((261 * 1024 * 1024))
# On-disk (little-endian) GPT type GUID bytes, used for raw byte comparison.
readonly ESP_TYPE_GUID_HEX='28732ac11ff8d211ba4b00a0c93ec93b'
readonly OS_TYPE_GUID_HEX='a2a0d0ebe5b9334487c068b6b72699c7'
# BCD object GUIDs used by the Phase 3 deploy engine.
readonly LOADER_GUID='{7619dcc9-fafe-11d9-b411-000476eba25f}'
readonly BOOTMGR_GUID='{9dea862c-5cdd-4e70-acc1-f32b344d4795}'

TARGET=""
WIM_PATH="$DEFAULT_WIM"
COMMIT=0
ASSUME_YES=0
VERIFY_ONLY=0
FULL_READ=0
FIXTURE_PATH=""

RUN_STAMP=""
LOG_FILE=""
VALIDATION_RECORD=""
WORK_DIR=""
ESP_MNT=""
NTFS_MNT=""
ESP_MOUNTED=0
NTFS_MOUNTED=0
UDEV_RULE_FILE=""
LOOP_BACKING=""
TARGET_BASE=""
SUMMARY_DONE=0

PASS=0
FAIL=0
FAILED_CHECKS=()
declare -A INFO=()

DISK_GUID=""
ESP_GUID=""
OS_GUID=""
FULL_READ_SHA256=""
ESP_BOOTX64_SHA256=""
ESP_BOOTMGFW_SHA256=""
ESP_BCD_SHA256=""
SECTOR_SIZE=512
PART1=""
PART2=""
GPT_OK=0
MANIFEST_FILE=""
declare -A GPT=()

usage() {
    cat <<'EOF'
Usage: 04_write_sdcard.sh --target <whole-disk-or-loop-device> [options]

Required (except --check-lsblk-fixture):
  --target <dev>        Whole removable disk (RM=1) or loop device backed by
                        a file under build/ or vm-test/.

Options:
  --commit              Write the image.  Without this the script validates
                        and prints a dry-run plan only.
  --yes                 Skip the interactive ERASE confirmation.  Requires
                        --commit.
  --verify-only         Skip the write; mount the target read-only and verify.
  --full-read           Read the whole target twice and require matching
                        SHA-256 digests (slow).
  --wim <path>          Source WIM (default: build/custom_install.wim).
  --check-lsblk-fixture <json>
                        Validate an lsblk JSON fixture without touching a
                        device (used by tests/test_04_sdcard.sh).
  -h, --help            Show this help.

The target is destroyed by --commit.  The script refuses nvme*, mounted
devices, swap, read-only devices, partitions, busy devices, and
non-removable disks.
EOF
}

log() { printf '[phase04] %s\n' "$*"; }
warn() { printf '[phase04] WARN: %s\n' "$*" >&2; }
die() { SUMMARY_DONE=1; printf '[FAIL] %s\n' "$*" >&2; exit 1; }

pass() {
    PASS=$((PASS + 1))
    printf '[PASS] %s: %s\n' "$1" "$2"
}

fail() {
    FAIL=$((FAIL + 1))
    FAILED_CHECKS+=("$1")
    printf '[FAIL] %s: %s\n' "$1" "$2"
}

while (( $# > 0 )); do
    case "$1" in
        --target)
            (( $# >= 2 )) || die "--target requires a value"
            TARGET="$2"
            shift 2
            ;;
        --wim)
            (( $# >= 2 )) || die "--wim requires a value"
            WIM_PATH="$2"
            shift 2
            ;;
        --commit)
            COMMIT=1
            shift
            ;;
        --yes)
            ASSUME_YES=1
            shift
            ;;
        --verify-only)
            VERIFY_ONLY=1
            shift
            ;;
        --full-read)
            FULL_READ=1
            shift
            ;;
        --check-lsblk-fixture)
            (( $# >= 2 )) || die "--check-lsblk-fixture requires a value"
            FIXTURE_PATH="$2"
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

if (( COMMIT == 1 && VERIFY_ONLY == 1 )); then
    die "--commit and --verify-only are mutually exclusive"
fi
if (( ASSUME_YES == 1 && COMMIT == 0 )); then
    die "--yes is only valid with --commit"
fi
if [[ -n "$FIXTURE_PATH" && -n "$TARGET" ]]; then
    die "--check-lsblk-fixture cannot be combined with --target"
fi
if [[ -z "$FIXTURE_PATH" && -z "$TARGET" ]]; then
    usage >&2
    die "--target is required"
fi

# ---------------------------------------------------------------------------
# lsblk JSON parsing and policy validation
# ---------------------------------------------------------------------------
parse_lsblk_json() {
    local json="$1"
    python3 - "$json" <<'PY'
import json
import sys

try:
    document = json.loads(sys.argv[1])
except Exception as exc:
    print(f"invalid lsblk JSON: {exc}", file=sys.stderr)
    raise SystemExit(2)

devices = document.get("blockdevices")
if not isinstance(devices, list) or len(devices) != 1:
    count = len(devices) if isinstance(devices, list) else "no"
    print(f"expected exactly one root block device, got {count}", file=sys.stderr)
    raise SystemExit(2)

root = devices[0]


def flag(value):
    if isinstance(value, bool):
        return 1 if value else 0
    if isinstance(value, int):
        return 1 if value else 0
    if isinstance(value, str):
        return 1 if value.strip().lower() in ("1", "true", "yes", "on") else 0
    return 0


def as_items(value):
    if value is None:
        return []
    if isinstance(value, list):
        return value
    if isinstance(value, str):
        return [value]
    return []


def walk(node):
    yield node
    children = node.get("children")
    if isinstance(children, list):
        for child in children:
            if isinstance(child, dict):
                yield from walk(child)


nodes = list(walk(root))
names = []
paths = []
types = []
mounts = []
for node in nodes:
    name = str(node.get("name") or "")
    path = str(node.get("path") or (("/dev/" + name) if name else ""))
    kind = str(node.get("type") or "")
    names.append(name)
    paths.append(path)
    types.append(kind)
    for mountpoint in as_items(node.get("mountpoints")):
        if mountpoint is None:
            continue
        mountpoint = str(mountpoint).strip()
        if mountpoint:
            mounts.append(mountpoint)

has_nvme = any("nvme" in (name + " " + path).lower()
               for name, path in zip(names, paths))
has_stacked = any(kind in ("lvm", "crypt", "md", "dm") for kind in types)
mounted = [mountpoint for mountpoint in mounts if mountpoint != "[SWAP]"]
swap = [mountpoint for mountpoint in mounts if mountpoint == "[SWAP]"]

values = {
    "path": paths[0] if paths else "",
    "name": names[0] if names else "",
    "type": types[0] if types else "",
    "rm": flag(root.get("rm")),
    "ro": flag(root.get("ro")),
    "size": str(root.get("size") or ""),
    "pkname": str(root.get("pkname") or ""),
    "mounted": 1 if mounted else 0,
    "swap": 1 if swap else 0,
    "nvme": 1 if has_nvme else 0,
    "stacked": 1 if has_stacked else 0,
    "mount_list": ",".join(mounted),
}

for key, value in values.items():
    print(f"{key}\t{value}")
PY
}

load_lsblk_info() {
    local json="$1" output key value
    if ! output="$(parse_lsblk_json "$json")"; then
        return 1
    fi
    INFO=()
    while IFS=$'\t' read -r key value; do
        [[ -n "$key" ]] || continue
        INFO["$key"]="$value"
    done <<< "$output"
    return 0
}

validate_info() {
    local path="${INFO[path]:-}"
    local kind="${INFO[type]:-}"
    local rm="${INFO[rm]:-}"
    local ro="${INFO[ro]:-}"

    [[ -n "$path" ]] || die "lsblk returned an empty device path"
    if [[ "${INFO[nvme]:-0}" == 1 ]]; then
        die "Refusing NVMe target or NVMe ancestry: $path"
    fi
    if [[ "${INFO[stacked]:-0}" == 1 ]]; then
        die "Refusing target with stacked device-mapper children: $path"
    fi
    if [[ "$ro" != 0 ]]; then
        die "Refusing read-only target (RO=$ro): $path"
    fi
    if [[ "$kind" != "disk" && "$kind" != "loop" ]]; then
        die "Target must be a whole disk or loop device, not TYPE=$kind: $path"
    fi
    if [[ -n "${INFO[pkname]:-}" ]]; then
        die "Target is a child device (PKNAME=${INFO[pkname]}), not a whole disk: $path"
    fi
    if [[ "${INFO[mounted]:-0}" == 1 ]]; then
        die "Target or one of its children is mounted: ${INFO[mount_list]:-unknown}"
    fi
    if [[ "${INFO[swap]:-0}" == 1 ]]; then
        die "Target or one of its children is active as swap: $path"
    fi
    if [[ "$kind" == "disk" && "$rm" != 1 ]]; then
        die "Refusing non-removable disk (RM=$rm): $path"
    fi
}

fixture_mode() {
    local fixture="$1" json
    [[ -f "$fixture" && -r "$fixture" ]] || die "Fixture is not readable: $fixture"
    json="$(cat -- "$fixture")" || die "Cannot read fixture: $fixture"
    load_lsblk_info "$json" || die "Fixture is not valid lsblk JSON: $fixture"
    validate_info
    printf '[PASS] fixture-validation: accepted %s (%s, type=%s, rm=%s, ro=%s)\n' \
        "$fixture" "${INFO[path]}" "${INFO[type]}" "${INFO[rm]}" "${INFO[ro]}"
}

if [[ -n "$FIXTURE_PATH" ]]; then
    command -v python3 >/dev/null 2>&1 || die "python3 is required"
    fixture_mode "$FIXTURE_PATH"
    exit 0
fi

# ---------------------------------------------------------------------------
# Tool, WIM, and BCD checks
# ---------------------------------------------------------------------------
if (( VERIFY_ONLY == 0 )); then
    [[ -x "$DEPLOY_SCRIPT" ]] || die "Deploy engine is missing or not executable: $DEPLOY_SCRIPT"
    [[ -f "$WIM_PATH" ]] || die "WIM not found: $WIM_PATH"
    WIM_PATH="$(readlink -f -- "$WIM_PATH")" || die "Cannot resolve WIM path"
    [[ -f "$WIM_PATH" && -r "$WIM_PATH" ]] || die "WIM is not a readable regular file: $WIM_PATH"
    command -v wimlib-imagex >/dev/null 2>&1 || die "wimlib-imagex is required"
    wimlib-imagex info "$WIM_PATH" 1 >/dev/null 2>&1 || die "WIM does not contain image 1: $WIM_PATH"
elif [[ -n "$WIM_PATH" && -e "$WIM_PATH" ]]; then
    WIM_PATH="$(readlink -f -- "$WIM_PATH")" || die "Cannot resolve WIM path"
    if command -v wimlib-imagex >/dev/null 2>&1; then
        wimlib-imagex info "$WIM_PATH" 1 >/dev/null 2>&1 \
            || die "WIM does not contain image 1: $WIM_PATH"
    fi
else
    WIM_PATH=""
fi

REQUIRED_TOOLS=(
    lsblk findmnt swapon losetup partx partprobe blkid blockdev
    mount umount mountpoint ntfs-3g reged sha256sum dd python3
    stat date awk grep sed tr readlink basename head cut cmp tee
    sync mktemp udevadm
)
for tool in "${REQUIRED_TOOLS[@]}"; do
    command -v "$tool" >/dev/null 2>&1 || die "Required tool not found: $tool"
done

for payload in \
    autounattend.xml \
    sd_survival_and_kiosk.cmd \
    val-kiosk.bat \
    switch-mode.bat \
    windows10.0-kb5015684-x64.cab
do
    [[ -f "${PAYLOAD_DIR}/${payload}" ]] || die "Missing payload: ${PAYLOAD_DIR}/${payload}"
done

mkdir -p -- "$LOG_DIR"
RUN_STAMP="$(date -u +%Y%m%dT%H%M%SZ)-$$"
LOG_FILE="${LOG_DIR}/04_write_sdcard_${RUN_STAMP}.log"
: > "$LOG_FILE"
exec > >(tee -a "$LOG_FILE") 2>&1

trap 'rc=$?; if (( rc != 0 )) && (( SUMMARY_DONE == 0 )); then printf "[FAIL] phase04 aborted unexpectedly at line %s (exit %s)\n" "$LINENO" "$rc" >&2; fi' ERR

remove_udev_guard() {
    if [[ -n "$UDEV_RULE_FILE" && -f "$UDEV_RULE_FILE" ]]; then
        rm -f -- "$UDEV_RULE_FILE" || true
        udevadm control --reload-rules >/dev/null 2>&1 || true
    fi
    UDEV_RULE_FILE=""
}

cleanup() {
    local rc=$?
    trap - EXIT
    set +e
    if (( NTFS_MOUNTED )); then
        umount -- "$NTFS_MNT" 2>/dev/null || umount -l -- "$NTFS_MNT" 2>/dev/null || true
        NTFS_MOUNTED=0
    fi
    if (( ESP_MOUNTED )); then
        umount -- "$ESP_MNT" 2>/dev/null || umount -l -- "$ESP_MNT" 2>/dev/null || true
        ESP_MOUNTED=0
    fi
    remove_udev_guard
    if [[ -n "$WORK_DIR" && -d "$WORK_DIR" ]]; then
        rm -rf -- "$WORK_DIR" || true
    fi
    sync 2>/dev/null || true
    if (( rc != 0 )) && (( SUMMARY_DONE == 0 )); then
        printf '[FAIL] phase04 write/read-back failed (exit %s)\n' "$rc" >&2
    fi
    exit "$rc"
}
trap cleanup EXIT

summary() {
    SUMMARY_DONE=1
    printf '\n[phase04] Passed: %d  Failed: %d\n' "$PASS" "$FAIL"
    if (( FAIL > 0 )); then
        printf '[FAIL] Phase 4 microSD write/read-back failed: %s\n' "${FAILED_CHECKS[*]}" >&2
        exit 1
    fi
    printf '[PASS] Phase 4 microSD write/read-back passed\n'
    exit 0
}

partition_path() {
    local disk="$1" index="$2" base
    base="$(basename -- "$disk")"
    case "$base" in
        loop*|mmcblk*|nvme*) printf '%sp%s\n' "$disk" "$index" ;;
        *) printf '%s%s\n' "$disk" "$index" ;;
    esac
}

install_udev_guard() {
    local base
    base="$(basename -- "$TARGET")"
    mkdir -p -- /run/udev/rules.d || die "Cannot create /run/udev/rules.d"
    UDEV_RULE_FILE="/run/udev/rules.d/99-valos-p4-ignore-${base}.rules"
    {
        printf '# Temporary rule written by 04_write_sdcard.sh; removed on exit.\n'
        printf 'ACTION=="add|change", SUBSYSTEM=="block", KERNEL=="%s", ENV{UDISKS_AUTO}="0", ENV{UDISKS_IGNORE}="1"\n' "$base"
        printf 'ACTION=="add|change", SUBSYSTEM=="block", KERNEL=="%s*", ENV{UDISKS_AUTO}="0", ENV{UDISKS_IGNORE}="1"\n' "$base"
    } > "$UDEV_RULE_FILE" || die "Cannot write $UDEV_RULE_FILE"
    udevadm control --reload-rules || die "udevadm control --reload-rules failed"
    udevadm trigger --action=change --subsystem-match=block --sysname-match="${base}*" \
        || die "udevadm trigger failed for $base"
    udevadm settle --timeout=30 || true
    log "Installed transient udev auto-mount guard for $base"
}

check_host_ancestry() {
    local mountpoint source source_real device parent i
    for mountpoint in / /home /boot /boot/efi /var; do
        source="$(findmnt -no SOURCE --target "$mountpoint" 2>/dev/null || true)"
        source="${source%%\[*}"
        if [[ -z "$source" || "$source" == "none" ]]; then
            if [[ "$mountpoint" == "/" ]]; then
                die "Cannot determine the host root device; refusing to operate"
            fi
            continue
        fi
        source_real="$(readlink -f -- "$source" 2>/dev/null || true)"
        if [[ -z "$source_real" || ! -b "$source_real" ]]; then
            if [[ "$mountpoint" == "/" ]]; then
                die "Host root source is not a block device: $source"
            fi
            continue
        fi
        if [[ "$source_real" == "$TARGET" ]]; then
            die "Target is mounted at $mountpoint"
        fi
        device="$source_real"
        for ((i = 0; i < 16; i++)); do
            parent="$(lsblk -no PKNAME -- "$device" 2>/dev/null | head -n1 | tr -d '[:space:]')"
            [[ -n "$parent" ]] || break
            device="/dev/${parent}"
            if [[ "$device" == "$TARGET" ]]; then
                die "Target is the parent disk of the host mount $mountpoint"
            fi
        done
    done
}

real_validate_target() {
    local requested="$1" resolved json backing swap_devices
    [[ -n "$requested" ]] || die "--target is empty"
    [[ -e "$requested" ]] || die "Target does not exist: $requested"
    resolved="$(readlink -f -- "$requested")" || die "Cannot resolve target path: $requested"
    [[ "$resolved" == /dev/* ]] || die "Target is not a /dev block device: $resolved"
    [[ -b "$resolved" ]] || die "Target is not a block device: $resolved"
    TARGET="$resolved"
    TARGET_BASE="$(basename -- "$TARGET")"
    if [[ "$TARGET_BASE" == nvme* ]]; then
        die "Refusing NVMe host disk: $TARGET"
    fi

    json="$(lsblk -J -o NAME,KNAME,PATH,TYPE,RM,RO,SIZE,MOUNTPOINTS,PKNAME -- "$TARGET" 2>/dev/null)" \
        || die "Unable to query lsblk for $TARGET"
    load_lsblk_info "$json" || die "Unable to parse the lsblk record for $TARGET"
    [[ "${INFO[path]:-}" == "$TARGET" ]] \
        || die "lsblk returned ${INFO[path]:-<empty>} for $TARGET"
    validate_info

    if [[ "${INFO[type]}" == "loop" ]]; then
        backing="$(losetup -n -O BACK-FILE -- "$TARGET" 2>/dev/null | head -n1)"
        [[ -n "$backing" ]] || die "Loop device has no backing file: $TARGET"
        backing="$(readlink -f -- "$backing")" || die "Cannot resolve loop backing file: $backing"
        [[ -f "$backing" ]] || die "Loop backing is not a regular file: $backing"
        case "$backing" in
            "$BUILD_DIR"/*|"${PROJECT_ROOT}/vm-test"/*) ;;
            *) die "Loop backing file is outside build/ or vm-test/: $backing" ;;
        esac
        if [[ -n "$WIM_PATH" && "$backing" == "$WIM_PATH" ]]; then
            die "Loop backing file is the source WIM: $backing"
        fi
        LOOP_BACKING="$backing"
    else
        LOOP_BACKING=""
    fi

    check_host_ancestry

    swap_devices="$(swapon --show=NAME --noheadings --raw 2>/dev/null || true)"
    if grep -Fxq -- "$TARGET" <<< "$swap_devices"; then
        die "Target is an active swap device: $TARGET"
    fi

    if command -v fuser >/dev/null 2>&1; then
        # fuser does not implement end-of-options; the target is already a
        # validated /dev path, so no operand can begin with a dash.
        if fuser -m "$TARGET" >/dev/null 2>&1; then
            die "Target is busy (open by another process): $TARGET"
        fi
    fi

    log "Validated target: $TARGET"
    log "  type=${INFO[type]} rm=${INFO[rm]} ro=${INFO[ro]} size=${INFO[size]:-unknown}"
    if [[ -n "$LOOP_BACKING" ]]; then
        log "  loop backing: $LOOP_BACKING"
    fi
    lsblk -o NAME,KNAME,PATH,TYPE,RM,RO,SIZE,MOUNTPOINTS,PKNAME -- "$TARGET" || true
}

write_validation_record() {
    VALIDATION_RECORD="${LOG_DIR}/04_validated_target_${RUN_STAMP}.lsblk.txt"
    if ! lsblk -o NAME,KNAME,PATH,TYPE,RM,RO,SIZE,MOUNTPOINTS,PKNAME \
        -- "$TARGET" > "$VALIDATION_RECORD"; then
        die "Could not write the validated lsblk record: $VALIDATION_RECORD"
    fi
    log "Validated lsblk record: $VALIDATION_RECORD"
}

# ---------------------------------------------------------------------------
# Read-back helpers: raw GPT parsing and offline registry access
# ---------------------------------------------------------------------------
read_gpt_info() {
    local target="$1" sector_size="$2" total_sectors="$3"
    python3 - "$target" "$sector_size" "$total_sectors" <<'PY'
import os
import struct
import sys
import uuid
import zlib

path = sys.argv[1]
sector = int(sys.argv[2])
total = int(sys.argv[3])


def read_at(fd, offset, length):
    os.lseek(fd, offset, os.SEEK_SET)
    chunks = []
    remaining = length
    while remaining:
        chunk = os.read(fd, remaining)
        if not chunk:
            raise IOError(f"short read at byte {offset + length - remaining}")
        chunks.append(chunk)
        remaining -= len(chunk)
    return b"".join(chunks)


def parse_header(fd, lba):
    header = read_at(fd, lba * sector, 92)
    (signature, revision, header_size, header_crc, reserved,
     current_lba, backup_lba, first_usable, last_usable,
     disk_guid, entry_lba, entry_count, entry_size,
     array_crc) = struct.unpack_from("<8sIIIIQQQQ16sQIII", header, 0)
    if signature != b"EFI PART":
        raise ValueError(f"bad GPT signature at LBA {lba}")
    if header_size < 92 or header_size > 512:
        raise ValueError(f"invalid GPT header size {header_size} at LBA {lba}")
    if entry_count < 1 or entry_count > 1024:
        raise ValueError(f"invalid GPT entry count {entry_count} at LBA {lba}")
    if entry_size < 128 or entry_size % 8 != 0:
        raise ValueError(f"invalid GPT entry size {entry_size} at LBA {lba}")
    if entry_lba < 1 or entry_lba >= total:
        raise ValueError(f"invalid GPT entry LBA {entry_lba}")
    full_header = read_at(fd, lba * sector, header_size)
    check = bytearray(full_header)
    check[16:20] = b"\x00\x00\x00\x00"
    if zlib.crc32(check) & 0xffffffff != header_crc:
        raise ValueError(f"GPT header CRC mismatch at LBA {lba}")
    entries = read_at(fd, entry_lba * sector, entry_count * entry_size)
    if zlib.crc32(entries) & 0xffffffff != array_crc:
        raise ValueError(f"GPT partition array CRC mismatch at LBA {entry_lba}")
    return {
        "current_lba": current_lba,
        "backup_lba": backup_lba,
        "first_usable": first_usable,
        "last_usable": last_usable,
        "disk_guid": disk_guid,
        "entry_lba": entry_lba,
        "entry_count": entry_count,
        "entry_size": entry_size,
        "entries": entries,
    }


try:
    fd = os.open(path, os.O_RDONLY)
except OSError as exc:
    print(f"cannot open target: {exc}", file=sys.stderr)
    raise SystemExit(2)

try:
    mbr = read_at(fd, 0, 512)
    mbr_ok = int(mbr[510:512] == b"\x55\xaa" and mbr[450] == 0xEE)

    primary = parse_header(fd, 1)
    if primary["current_lba"] != 1:
        raise ValueError("primary GPT header is not at LBA 1")
    if primary["backup_lba"] != total - 1:
        raise ValueError("primary GPT backup pointer is not the last LBA")
    if primary["first_usable"] < 34:
        raise ValueError("GPT first usable LBA is below 34")
    if primary["last_usable"] > total - 34:
        raise ValueError("GPT last usable LBA exceeds the backup area")

    backup = parse_header(fd, primary["backup_lba"])
    if backup["current_lba"] != primary["backup_lba"]:
        raise ValueError("backup GPT header points at the wrong LBA")
    if backup["backup_lba"] != 1:
        raise ValueError("backup GPT header does not point back to LBA 1")
    if backup["disk_guid"] != primary["disk_guid"]:
        raise ValueError("primary and backup GPT disk GUIDs differ")
    if backup["entries"] != primary["entries"]:
        raise ValueError("primary and backup GPT partition arrays differ")

    parts = []
    for index in range(primary["entry_count"]):
        start = index * primary["entry_size"]
        entry = primary["entries"][start:start + primary["entry_size"]]
        if entry[:16] == b"\x00" * 16:
            continue
        part_type = entry[0:16]
        part_guid = entry[16:32]
        first_lba, last_lba, attrs = struct.unpack_from("<QQQ", entry, 32)
        name = entry[56:128].decode("utf-16le", "replace").split("\x00", 1)[0]
        if first_lba > last_lba or first_lba < primary["first_usable"] \
                or last_lba > primary["last_usable"]:
            raise ValueError(f"partition {index + 1} lies outside the usable GPT area")
        parts.append({
            "type": part_type,
            "guid": part_guid,
            "start": first_lba,
            "end": last_lba,
            "attrs": attrs,
            "name": name,
        })

    print(f"mbr_ok={mbr_ok}")
    print("primary_ok=1")
    print("backup_ok=1")
    print(f"total_sectors={total}")
    print(f"sector_size={sector}")
    print(f"first_usable={primary['first_usable']}")
    print(f"last_usable={primary['last_usable']}")
    print(f"disk_guid={primary['disk_guid'].hex()}")
    print(f"partition_count={len(parts)}")
    for index, part in enumerate(parts, 1):
        print(f"p{index}_type={part['type'].hex()}")
        print(f"p{index}_guid={part['guid'].hex()}")
        print(f"p{index}_start={part['start']}")
        print(f"p{index}_end={part['end']}")
        print(f"p{index}_attrs={part['attrs']}")
        print(f"p{index}_name={part['name']}")
except Exception as exc:
    print(f"error={exc}", file=sys.stderr)
    raise SystemExit(2)
finally:
    os.close(fd)
PY
}

load_gpt_info() {
    local output key value
    if ! output="$(read_gpt_info "$1" "$2" "$3")"; then
        return 1
    fi
    GPT=()
    while IFS='=' read -r key value; do
        [[ -n "$key" ]] || continue
        GPT["$key"]="$value"
    done <<< "$output"
    return 0
}

reged_export() {
    local hive="$1" prefix="$2" key="$3" out="$4" rc=0
    rm -f -- "$out"
    set +e
    ( reged -x "$hive" "$prefix" "$key" "$out" ) >/dev/null 2>&1
    rc=$?
    set -e
    if [[ ! -s "$out" ]]; then
        warn "reged export produced no data (exit $rc): ${prefix}\\${key}"
        return 1
    fi
    if (( rc != 0 )); then
        warn "reged export exited $rc after writing ${prefix}\\${key} (accepted)"
    fi
    return 0
}

normalize_reg() {
    local src="$1" dst="$2"
    tr -d '\r' < "$src" > "$dst"
}

find_control_set() {
    local hive="$1" out="$2" current_hex
    if reged_export "$hive" 'HKEY_LOCAL_MACHINE\SYSTEM' 'Select' "$out"; then
        current_hex="$(grep -m1 -oE '"Current"=dword:[0-9a-fA-F]+' "$out" \
            | cut -d: -f2 | tr -d '[:space:]' || true)"
        if [[ -n "$current_hex" ]]; then
            printf 'ControlSet%03d' "$((16#$current_hex))"
            return 0
        fi
    fi
    return 1
}

read_reg_element_hex() {
    local hive="$1" key="$2" out="$3" hex
    reged_export "$hive" 'HKEY_LOCAL_MACHINE\BCD00000000' "Objects\\$key" "$out" || return 1
    hex="$(tr -d '\\ \n\r' < "$out" \
        | grep -o '"Element"=hex:[0-9a-f,]*' | head -n1 | cut -d: -f2 | tr -d ',' || true)"
    if [[ ${#hex} -ne 176 ]]; then
        return 1
    fi
    printf '%s' "$hex"
}

verify_bcd_elements() {
    local bcd="$1" hex element path_reg
    hex="$(read_reg_element_hex "$bcd" "${BOOTMGR_GUID}\\Elements\\11000001" \
        "${WORK_DIR}/verify_bootmgr.reg")" || return 1
    [[ "${hex:32:2}" == "06" ]] || return 1
    [[ "${hex:48:2}" == "48" ]] || return 1
    [[ "${hex:104:2}" == "00" ]] || return 1
    [[ "${hex:64:32}" == "$ESP_GUID" ]] || return 1
    [[ "${hex:112:32}" == "$DISK_GUID" ]] || return 1

    for element in 11000001 21000001; do
        hex="$(read_reg_element_hex "$bcd" "${LOADER_GUID}\\Elements\\${element}" \
            "${WORK_DIR}/verify_loader_${element}.reg")" || return 1
        [[ "${hex:32:2}" == "06" ]] || return 1
        [[ "${hex:48:2}" == "48" ]] || return 1
        [[ "${hex:104:2}" == "00" ]] || return 1
        [[ "${hex:64:32}" == "$OS_GUID" ]] || return 1
        [[ "${hex:112:32}" == "$DISK_GUID" ]] || return 1
    done

    path_reg="${WORK_DIR}/verify_loader_path.reg"
    reged_export "$bcd" 'HKEY_LOCAL_MACHINE\BCD00000000' \
        "Objects\\${LOADER_GUID}\\Elements\\12000002" "$path_reg" || return 1
    grep -Fq -- '"Element"="\\Windows\\system32\\winload.efi"' "$path_reg" || return 1
    return 0
}

# ---------------------------------------------------------------------------
# Read-back checks
# ---------------------------------------------------------------------------
sha_file() {
    local file="$1" digest
    digest="$(sha256sum -- "$file" | cut -d' ' -f1)" || return 1
    printf '%s' "$digest"
}

attach_partitions() {
    local i
    PART1="$(partition_path "$TARGET" 1)"
    PART2="$(partition_path "$TARGET" 2)"
    partprobe -- "$TARGET" >/dev/null 2>&1 || true
    udevadm settle --timeout=30 || true
    for ((i = 0; i < 30; i++)); do
        if [[ -b "$PART1" && -b "$PART2" ]]; then
            return 0
        fi
        partx -u -- "$TARGET" >/dev/null 2>&1 || true
        sleep 1
    done
    [[ -b "$PART1" && -b "$PART2" ]]
}

readback_gpt() {
    local total_sectors layout_ok=0
    # blockdev does not implement end-of-options; TARGET is a validated /dev path.
    SECTOR_SIZE="$(blockdev --getss "$TARGET" 2>/dev/null || true)"
    [[ "$SECTOR_SIZE" =~ ^[0-9]+$ ]] || SECTOR_SIZE=512
    total_sectors="$(blockdev --getsz "$TARGET" 2>/dev/null || true)"
    if [[ ! "$total_sectors" =~ ^[0-9]+$ ]] \
        || ! load_gpt_info "$TARGET" "$SECTOR_SIZE" "$total_sectors"; then
        fail "gpt-protective-mbr" "cannot read a protective MBR from $TARGET"
        fail "gpt-header" "primary/backup GPT headers are absent or invalid"
        fail "gpt-layout" "partition layout cannot be parsed"
        return 1
    fi
    GPT_OK=1
    DISK_GUID="${GPT[disk_guid]:-}"
    ESP_GUID="${GPT[p1_guid]:-}"
    OS_GUID="${GPT[p2_guid]:-}"

    if [[ "${GPT[mbr_ok]:-0}" == 1 ]]; then
        pass "gpt-protective-mbr" "protective MBR (type 0xEE, signature 0x55AA) is present"
    else
        fail "gpt-protective-mbr" "protective MBR is missing or malformed"
    fi

    if [[ "${GPT[primary_ok]:-0}" == 1 && "${GPT[backup_ok]:-0}" == 1 ]]; then
        pass "gpt-header" "primary and backup GPT headers and array CRCs are valid"
    else
        fail "gpt-header" "GPT header or partition-array CRC validation failed"
    fi

    local p1_start_byte p1_end_byte p2_start_byte
    p1_start_byte=$(( ${GPT[p1_start]:-0} * SECTOR_SIZE ))
    p1_end_byte=$(( (${GPT[p1_end]:-0} + 1) * SECTOR_SIZE ))
    p2_start_byte=$(( ${GPT[p2_start]:-0} * SECTOR_SIZE ))
    if [[ "${GPT[partition_count]:-0}" == 2 \
        && "${GPT[p1_type]:-}" == "$ESP_TYPE_GUID_HEX" \
        && "${GPT[p1_name]:-}" == "ESP" \
        && "${GPT[p2_type]:-}" == "$OS_TYPE_GUID_HEX" \
        && "${GPT[p2_name]:-}" == "ValOS" ]] \
        && (( p1_start_byte == ESP_START_BYTES )) \
        && (( p1_end_byte == ESP_END_BYTES )) \
        && (( p2_start_byte == OS_START_BYTES )) \
        && (( ${GPT[p2_end]:-0} > ${GPT[p2_start]:-0} )) \
        && (( ${GPT[p2_end]:-0} <= ${GPT[last_usable]:-0} )); then
        layout_ok=1
    fi
    if (( layout_ok )); then
        pass "gpt-layout" \
            "ESP ${GPT[p1_start]}..${GPT[p1_end]} + ValOS ${GPT[p2_start]}..${GPT[p2_end]}"
    else
        fail "gpt-layout" \
            "expected ESP at 1..261 MiB and ValOS from 261 MiB; got ESP ${GPT[p1_start]:-?}..${GPT[p1_end]:-?}"
    fi
    return 0
}

mount_esp() {
    mkdir -p -- "$ESP_MNT"
    if mount -o ro -- "$PART1" "$ESP_MNT" 2>"${WORK_DIR}/esp-mount.err"; then
        ESP_MOUNTED=1
        pass "esp-mount" "ESP mounted read-only at $ESP_MNT"
        return 0
    fi
    cat -- "${WORK_DIR}/esp-mount.err" >&2 || true
    fail "esp-mount" "could not mount the ESP read-only"
    return 1
}

unmount_esp() {
    if (( ESP_MOUNTED )); then
        umount -- "$ESP_MNT" 2>/dev/null || umount -l -- "$ESP_MNT" 2>/dev/null || true
        ESP_MOUNTED=0
    fi
}

mount_ntfs() {
    mkdir -p -- "$NTFS_MNT"
    # ntfs-3g does not implement end-of-options; PART2 is a validated /dev path.
    if ntfs-3g -o ro "$PART2" "$NTFS_MNT" 2>"${WORK_DIR}/ntfs-mount.err"; then
        NTFS_MOUNTED=1
    elif ntfs-3g -o ro,force "$PART2" "$NTFS_MNT" 2>>"${WORK_DIR}/ntfs-mount.err"; then
        NTFS_MOUNTED=1
        warn "NTFS mounted with -o ro,force because the volume was marked dirty"
    else
        cat -- "${WORK_DIR}/ntfs-mount.err" >&2 || true
        fail "ntfs-mount" "could not mount the ValOS partition read-only"
        return 1
    fi
    pass "ntfs-mount" "ValOS NTFS volume mounted read-only at $NTFS_MNT"
    return 0
}

unmount_ntfs() {
    if (( NTFS_MOUNTED )); then
        umount -- "$NTFS_MNT" 2>/dev/null || umount -l -- "$NTFS_MNT" 2>/dev/null || true
        NTFS_MOUNTED=0
    fi
}

readback_esp() {
    local bootx64="${ESP_MNT}/EFI/Boot/bootx64.efi"
    local bootmgfw="${ESP_MNT}/EFI/Microsoft/Boot/bootmgfw.efi"
    local bcd="${ESP_MNT}/EFI/Microsoft/Boot/BCD"
    local description="${WORK_DIR}/bcd_description.reg"
    local bcd_copy="${WORK_DIR}/BCD"

    if [[ -f "$bootx64" && -f "$bootmgfw" ]] && cmp -s -- "$bootx64" "$bootmgfw"; then
        ESP_BOOTX64_SHA256="$(sha_file "$bootx64")" || ESP_BOOTX64_SHA256=""
        ESP_BOOTMGFW_SHA256="$(sha_file "$bootmgfw")" || ESP_BOOTMGFW_SHA256=""
        pass "esp-boot-files" "bootx64.efi and bootmgfw.efi are present and byte-identical"
    else
        fail "esp-boot-files" "EFI/Boot/bootx64.efi and/or EFI/Microsoft/Boot/bootmgfw.efi are missing or differ"
    fi

    if [[ ! -f "$bcd" ]]; then
        fail "esp-bcd-system-store" "EFI/Microsoft/Boot/BCD is missing"
        fail "esp-bcd-device-paths" "EFI/Microsoft/Boot/BCD is missing"
        return 0
    fi
    cp -- "$bcd" "$bcd_copy"
    ESP_BCD_SHA256="$(sha_file "$bcd")" || ESP_BCD_SHA256=""

    if reged_export "$bcd_copy" 'HKEY_LOCAL_MACHINE\BCD00000000' 'Description' "$description"; then
        normalize_reg "$description" "${WORK_DIR}/bcd_description.norm"
        if grep -Fq -- '"KeyName"="BCD00000000"' "${WORK_DIR}/bcd_description.norm" \
            && grep -Fq -- '"System"=dword:00000001' "${WORK_DIR}/bcd_description.norm" \
            && grep -Fq -- '"TreatAsSystem"=dword:00000001' "${WORK_DIR}/bcd_description.norm"; then
            pass "esp-bcd-system-store" "BCD is a Windows system store (KeyName/System/TreatAsSystem)"
        else
            fail "esp-bcd-system-store" "BCD is not marked as a Windows system store"
        fi
    else
        fail "esp-bcd-system-store" "could not export the BCD Description key"
    fi

    if verify_bcd_elements "$bcd_copy"; then
        pass "esp-bcd-device-paths" "BCD application/OS elements reference the target GPT GUIDs"
    else
        fail "esp-bcd-device-paths" "BCD device elements do not match the target GPT GUIDs"
    fi
    return 0
}

readback_payloads() {
    local name rel src dst expected actual id
    while IFS='|' read -r name rel; do
        [[ -n "$name" ]] || continue
        case "$name" in
            sd_survival_and_kiosk.cmd) id='payload-sd-survival' ;;
            val-kiosk.bat)             id='payload-val-kiosk' ;;
            switch-mode.bat)           id='payload-switch-mode' ;;
            windows10.0-kb5015684-x64.cab) id='payload-kb-cab' ;;
            *)                         id="payload-${name}" ;;
        esac
        src="${PAYLOAD_DIR}/${name}"
        dst="${NTFS_MNT}/${rel}"
        if [[ ! -f "$dst" ]]; then
            fail "$id" "missing /${rel}"
            continue
        fi
        if [[ -L "$dst" ]]; then
            fail "$id" "unexpected reparse point at /${rel}"
            continue
        fi
        expected="$(sha_file "$src")" || { fail "$id" "cannot hash ${src}"; continue; }
        actual="$(sha_file "$dst")" || { fail "$id" "cannot hash /${rel}"; continue; }
        if [[ "$actual" == "$expected" ]]; then
            pass "$id" "sha256 ${actual} matches payloads/${name}"
        else
            fail "$id" "sha256 mismatch: ${actual} != ${expected}"
        fi
    done <<'EOF'
sd_survival_and_kiosk.cmd|Riot Games/sd_survival_and_kiosk.cmd
val-kiosk.bat|Riot Games/val-kiosk.bat
switch-mode.bat|Riot Games/switch-mode.bat
windows10.0-kb5015684-x64.cab|Riot Games/windows10.0-kb5015684-x64.cab
EOF

    local src="${PAYLOAD_DIR}/autounattend.xml"
    local dst="${NTFS_MNT}/Windows/Panther/unattend.xml"
    if [[ -f "$dst" ]]; then
        local expected actual
        expected="$(sha_file "$src")" || expected=""
        actual="$(sha_file "$dst")" || actual=""
        if [[ -n "$expected" && "$actual" == "$expected" ]]; then
            pass "payload-autounattend" "sha256 ${actual} matches payloads/autounattend.xml"
        elif (( VERIFY_ONLY )); then
            tr -d '\000' < "$dst" > "${WORK_DIR}/unattend.norm"
            if grep -Fq -- 'wasPassProcessed="true"' "${WORK_DIR}/unattend.norm"; then
                pass "payload-autounattend" \
                    "answer file was rewritten by Windows first boot (source hash intentionally differs)"
            else
                fail "payload-autounattend" "answer file differs from the source without a processed marker"
            fi
        else
            fail "payload-autounattend" "sha256 mismatch: ${actual:-<unreadable>} != ${expected:-<unreadable>}"
        fi
    elif (( VERIFY_ONLY )); then
        pass "payload-autounattend" "answer file was removed after provisioning (verify-only)"
    else
        fail "payload-autounattend" "missing /Windows/Panther/unattend.xml"
    fi
}

readback_system_hive() {
    local hive="${NTFS_MNT}/Windows/System32/config/SYSTEM"
    local control_set out service start_hex expected_start drivers_ok=1
    local missing=()

    if [[ ! -f "$hive" ]]; then
        fail "system-portable-os" "SYSTEM hive is missing"
        fail "system-poll-boot-timeout" "SYSTEM hive is missing"
        fail "system-storage-drivers" "SYSTEM hive is missing"
        fail "invariant-service-WinDefend" "SYSTEM hive is missing"
        fail "invariant-service-SecurityHealthService" "SYSTEM hive is missing"
        fail "invariant-service-TPM" "SYSTEM hive is missing"
        return 0
    fi

    control_set="$(find_control_set "$hive" "${WORK_DIR}/select.reg" || true)"
    if [[ -z "$control_set" ]]; then
        control_set='ControlSet001'
        warn "could not read the SYSTEM Select key; assuming ControlSet001"
    fi
    log "Read-back control set: $control_set"

    out="${WORK_DIR}/control.reg"
    if reged_export "$hive" 'HKEY_LOCAL_MACHINE\SYSTEM' "${control_set}\\Control" "$out"; then
        normalize_reg "$out" "${WORK_DIR}/control.norm"
        if grep -Fq -- '"PortableOperatingSystem"=dword:00000001' "${WORK_DIR}/control.norm"; then
            pass "system-portable-os" "SYSTEM PortableOperatingSystem is 1"
        else
            fail "system-portable-os" "SYSTEM PortableOperatingSystem is not 1"
        fi
        if grep -Fq -- '"PollBootPartitionTimeout"=dword:00007530' "${WORK_DIR}/control.norm"; then
            pass "system-poll-boot-timeout" "SYSTEM PollBootPartitionTimeout is 30000"
        else
            fail "system-poll-boot-timeout" "SYSTEM PollBootPartitionTimeout is not 30000"
        fi
    else
        fail "system-portable-os" "could not export ${control_set}\\Control"
        fail "system-poll-boot-timeout" "could not export ${control_set}\\Control"
    fi

    for service in USBSTOR UASPStor sdbus sdstor USBXHCI; do
        out="${WORK_DIR}/driver_${service}.reg"
        if ! reged_export "$hive" 'HKEY_LOCAL_MACHINE\SYSTEM' \
            "${control_set}\\Services\\${service}" "$out"; then
            drivers_ok=0
            missing+=("$service")
            continue
        fi
        normalize_reg "$out" "${WORK_DIR}/driver_${service}.norm"
        if ! grep -Fq -- '"Start"=dword:00000000' "${WORK_DIR}/driver_${service}.norm"; then
            drivers_ok=0
            missing+=("$service")
        fi
    done
    if (( drivers_ok )); then
        pass "system-storage-drivers" "USB/SD storage drivers are boot-start"
    else
        fail "system-storage-drivers" "drivers not at Start=0: ${missing[*]}"
    fi

    for service in WinDefend SecurityHealthService TPM; do
        case "$service" in
            WinDefend)               expected_start='2' ;;
            SecurityHealthService)   expected_start='3' ;;
            TPM)                     expected_start='3' ;;
        esac
        out="${WORK_DIR}/service_${service}.reg"
        if ! reged_export "$hive" 'HKEY_LOCAL_MACHINE\SYSTEM' \
            "${control_set}\\Services\\${service}" "$out"; then
            fail "invariant-service-${service}" "service key is missing from the SYSTEM hive"
            continue
        fi
        normalize_reg "$out" "${WORK_DIR}/service_${service}.norm"
        start_hex="$(grep -m1 -oE '"Start"=dword:[0-9a-fA-F]+' \
            "${WORK_DIR}/service_${service}.norm" | cut -d: -f2 | tr -d '[:space:]' || true)"
        if [[ -z "$start_hex" ]]; then
            fail "invariant-service-${service}" "Start value is missing"
        elif [[ "$((16#$start_hex))" == "$expected_start" ]]; then
            pass "invariant-service-${service}" "service Start=${start_hex} (enabled)"
        else
            fail "invariant-service-${service}" \
                "service Start=${start_hex}, expected ${expected_start}"
        fi
    done
}

readback_software_hive() {
    local hive="${NTFS_MNT}/Windows/System32/config/SOFTWARE"
    local boot_marker="${NTFS_MNT}/Riot Games/boot_verified.txt"
    local out defender_key defender_disabled=0 check_kiosk=0
    local expected_shell='"Shell"="cmd.exe /c \"C:\\Riot Games\\val-kiosk.bat\""'

    # The kiosk shell is installed by the first-boot survival payload, not by
    # the WIM.  Only assert it when reading back a card that already booted.
    if (( VERIFY_ONLY )) && [[ -f "$boot_marker" ]]; then
        check_kiosk=1
    fi

    if [[ ! -f "$hive" ]]; then
        fail "invariant-defender-policy" "SOFTWARE hive is missing"
        if (( check_kiosk )); then
            fail "kiosk-shell" "SOFTWARE hive is missing"
        else
            log "Skipping kiosk-shell: it is installed by the first-boot survival payload"
        fi
        return 0
    fi

    if (( check_kiosk )); then
        out="${WORK_DIR}/winlogon.reg"
        if reged_export "$hive" 'HKEY_LOCAL_MACHINE\SOFTWARE' \
            'Microsoft\Windows NT\CurrentVersion\Winlogon' "$out"; then
            normalize_reg "$out" "${WORK_DIR}/winlogon.norm"
            if grep -Fq -- "$expected_shell" "${WORK_DIR}/winlogon.norm"; then
                pass "kiosk-shell" "Winlogon Shell is the Valorant kiosk command"
            else
                fail "kiosk-shell" "Winlogon Shell is not the expected kiosk command"
            fi
        else
            fail "kiosk-shell" "could not export the Winlogon key"
        fi
    else
        log "Skipping kiosk-shell: it is installed by the first-boot survival payload"
    fi

    for defender_key in 'Policies\Microsoft\Windows Defender' 'Microsoft\Windows Defender'; do
        out="${WORK_DIR}/defender_$(printf '%s' "$defender_key" | tr '\\ ' '__').reg"
        if reged_export "$hive" 'HKEY_LOCAL_MACHINE\SOFTWARE' "$defender_key" "$out"; then
            normalize_reg "$out" "${out}.norm"
            if grep -Eiq -- '"DisableAntiSpyware"=dword:0*1' "${out}.norm"; then
                defender_disabled=1
            fi
        fi
    done
    if (( defender_disabled )); then
        fail "invariant-defender-policy" "DisableAntiSpyware is enabled"
    else
        pass "invariant-defender-policy" "no Defender-disabling policy is present"
    fi
}

readback_invariant_files() {
    local path abs target
    for path in Windows/System32/ci.dll Windows/System32/drivers/tpm.sys; do
        abs="${NTFS_MNT}/${path}"
        if [[ -f "$abs" ]]; then
            pass "invariant-file-$(basename -- "$path")" "present: /${path}"
        elif [[ -L "$abs" ]]; then
            target="$(readlink -- "$abs" 2>/dev/null || true)"
            if [[ "$target" == *'unsupported reparse tag 0x80000017'* ]]; then
                pass "invariant-file-$(basename -- "$path")" \
                    "present as WOF reparse point (0x80000017): /${path}"
            else
                fail "invariant-file-$(basename -- "$path")" \
                    "unexpected reparse target for /${path}: ${target:-<empty>}"
            fi
        else
            fail "invariant-file-$(basename -- "$path")" "missing: /${path}"
        fi
    done
}

readback_ntfs() {
    readback_payloads
    readback_system_hive
    readback_software_hive
    readback_invariant_files
}

full_read_check() {
    local first second
    log "Performing two full raw reads of $TARGET (this can take a while)"
    sync
    first="$(sha_file "$TARGET")" || {
        fail "full-read" "first raw read failed"
        return 0
    }
    second="$(sha_file "$TARGET")" || {
        fail "full-read" "second raw read failed"
        return 0
    }
    FULL_READ_SHA256="$first"
    if [[ -n "$first" && "$first" == "$second" ]]; then
        pass "full-read" "two full reads matched (sha256 ${first})"
    else
        fail "full-read" "full-read digests differ: ${first} != ${second}"
    fi
}

write_manifest() {
    MANIFEST_FILE="${LOG_DIR}/04_manifest_${RUN_STAMP}.env"
    {
        printf 'PHASE=04\n'
        printf 'GENERATED_AT=%s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
        printf 'MODE=%s\n' "$([[ "$VERIFY_ONLY" == 1 ]] && echo verify-only || echo commit)"
        printf 'TARGET=%s\n' "$TARGET"
        printf 'TARGET_TYPE=%s\n' "${INFO[type]:-}"
        printf 'TARGET_RM=%s\n' "${INFO[rm]:-}"
        printf 'TARGET_RO=%s\n' "${INFO[ro]:-}"
        printf 'TARGET_SIZE=%s\n' "${INFO[size]:-}"
        printf 'LOOP_BACKING=%s\n' "$LOOP_BACKING"
        printf 'DISK_GUID=%s\n' "$DISK_GUID"
        printf 'ESP_GUID=%s\n' "$ESP_GUID"
        printf 'OS_GUID=%s\n' "$OS_GUID"
        printf 'ESP_BOOTX64_SHA256=%s\n' "$ESP_BOOTX64_SHA256"
        printf 'ESP_BOOTMGFW_SHA256=%s\n' "$ESP_BOOTMGFW_SHA256"
        printf 'ESP_BCD_SHA256=%s\n' "$ESP_BCD_SHA256"
        printf 'FULL_READ_SHA256=%s\n' "$FULL_READ_SHA256"
        printf 'FULL_READ_PASSES=%s\n' "$([[ "$FULL_READ" == 1 ]] && echo 2 || echo 0)"
    } > "$MANIFEST_FILE"
    if [[ -s "$MANIFEST_FILE" ]]; then
        pass "manifest" "read-back manifest written to $MANIFEST_FILE"
    else
        fail "manifest" "could not write the read-back manifest"
    fi
}

perform_readback() {
    WORK_DIR="$(mktemp -d "${BUILD_DIR}/phase04-verify.XXXXXX")" \
        || die "Cannot create the read-back work directory"
    ESP_MNT="${WORK_DIR}/esp"
    NTFS_MNT="${WORK_DIR}/ntfs"
    mkdir -p -- "$ESP_MNT" "$NTFS_MNT"

    readback_gpt || true
    if attach_partitions; then
        if mount_esp; then
            readback_esp
            unmount_esp
        fi
        if mount_ntfs; then
            readback_ntfs
            unmount_ntfs
        fi
    else
        fail "esp-mount" "partition nodes did not appear: $PART1 $PART2"
        fail "ntfs-mount" "partition nodes did not appear: $PART1 $PART2"
    fi

    if (( FULL_READ )); then
        full_read_check
    fi
    write_manifest
}

# ---------------------------------------------------------------------------
# Main execution
# ---------------------------------------------------------------------------
real_validate_target "$TARGET"
write_validation_record

if (( VERIFY_ONLY )); then
    log "Verify-only mode: reading back $TARGET without writing"
    perform_readback
    summary
elif (( COMMIT == 0 )); then
    log "Dry run: target is valid for a Phase 4 commit"
    log "  target:  $TARGET"
    log "  wim:     $WIM_PATH"
    log "  command: 04_write_sdcard.sh --target $TARGET --commit --yes"
    pass "dry-run" "target validated; no writes were performed"
    summary
fi

if (( ASSUME_YES == 0 )); then
    if [[ ! -t 0 ]]; then
        die "--yes is required for a non-interactive --commit"
    fi
    printf 'Type ERASE to destroy %s and write the image: ' "$TARGET"
    read -r answer
    if [[ "$answer" != "ERASE" ]]; then
        die "Erase was not confirmed"
    fi
else
    log "Erase confirmed non-interactively by --yes"
fi

install_udev_guard
log "Delegating the destructive write to $DEPLOY_SCRIPT"
if ! "$DEPLOY_SCRIPT" --target "$TARGET" --wim "$WIM_PATH" --commit --yes; then
    die "Phase 3 deploy engine failed"
fi
remove_udev_guard
sync
partprobe -- "$TARGET" >/dev/null 2>&1 || true
udevadm settle --timeout=30 || true
pass "deploy-engine" "Phase 3 deploy engine completed on $TARGET"

perform_readback
summary
