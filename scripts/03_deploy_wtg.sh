#!/usr/bin/env bash
# Phase 3: deploy the prepared Windows image to a UEFI/GPT Windows To Go target.
#
# Safety contract (see OpenCode.md Rule 2):
#   * Dry-run by default.  Nothing is written without --commit.
#   * Only a whole removable disk (RM=1) or a loop device backed by a file under
#     build/ or vm-test/ is accepted.
#   * nvme*, host-mounted devices, swap devices, read-only devices, partitions,
#     and anything with host root ancestry are rejected before the first write.
#
# Bootability contract:
#   * GPT: ESP (FAT32, 1-261 MiB, boot+esp) + ValOS (NTFS, msftdata).
#   * Offline SYSTEM hive: PortableOperatingSystem=1, PollBootPartitionTimeout=30000,
#     and boot-start USB/SD storage drivers.
#   * ESP: Windows UEFI boot files + a freshly generated BCD whose application,
#     OS, and boot-manager devices point at the target's GPT GUIDs.

set -Eeuo pipefail
IFS=$'\n\t'

PROJECT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
readonly PROJECT_ROOT

readonly BUILD_DIR="${PROJECT_ROOT}/build"
readonly LOG_DIR="${BUILD_DIR}/logs"
readonly DEFAULT_WIM="${BUILD_DIR}/custom_install.wim"
readonly BCD_TEMPLATE="${PROJECT_ROOT}/payloads/bcd_template"
readonly FALLBACK_BCD_TEMPLATE="${BUILD_DIR}/iso_extracted/efi/microsoft/boot/bcd"
readonly EFI_FALLBACK="${BUILD_DIR}/efi_staged"

readonly LOADER_GUID='{7619dcc9-fafe-11d9-b411-000476eba25f}'
readonly BOOTMGR_GUID='{9dea862c-5cdd-4e70-acc1-f32b344d4795}'

TARGET=""
WIM_PATH="$DEFAULT_WIM"
COMMIT=0
ASSUME_YES=0
KEEP_WORK=0

WTG_EFI_LABEL="WTG_EFI"
VAL_OS_LABEL="VAL_OS"

WORK_DIR=""
NTFS_MNT=""
ESP_MNT=""
PART1=""
PART2=""
UDEV_RULE_FILE=""

readonly UDEV_RULE_DIR="/run/udev/rules.d"

usage() {
    cat <<'EOF'
Usage: 03_deploy_wtg.sh --target <whole-disk-or-loop-device> [options]

Required:
  --target <dev>     Target block device (for example /dev/sdX or /dev/loopN).
                     It must be a whole disk, removable (RM=1), or a loop
                     device backed by a file under build/ or vm-test/.

Options:
  --wim <path>       Source WIM (default: build/custom_install.wim).
  --commit           Actually partition, format, and deploy.  Without this the
                     script performs a full validation and dry-run only.
  --yes              Skip the interactive ERASE confirmation (used by the
                     automated QEMU gate).  Requires --commit.
  --keep-work        Keep the temporary work directory for debugging.
  -h, --help         Show this help.

The target is destroyed.  The script refuses nvme*, mounted devices, swap,
read-only devices, partitions, and non-removable disks.
EOF
}

log() { printf '[phase03] %s\n' "$*"; }
warn() { printf '[phase03] WARN: %s\n' "$*" >&2; }
die() { printf '[FAIL] %s\n' "$*" >&2; exit 1; }

while (( $# > 0 )); do
    case "$1" in
        --target)
            if (( $# < 2 )); then die "--target requires a value"; fi
            TARGET="$2"
            shift 2
            ;;
        --wim)
            if (( $# < 2 )); then die "--wim requires a value"; fi
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
        --keep-work)
            KEEP_WORK=1
            shift
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

if [[ -z "$TARGET" ]]; then
    usage >&2
    die "--target is required"
fi
if (( ASSUME_YES == 1 && COMMIT == 0 )); then
    die "--yes is only valid with --commit"
fi

mkdir -p -- "$LOG_DIR"
LOG_FILE="${LOG_DIR}/03_deploy_$(date -u +%Y%m%dT%H%M%SZ).log"
exec > >(tee -a "$LOG_FILE") 2>&1

trap 'rc=$?; printf "[FAIL] phase03 deploy aborted unexpectedly at line %s (exit %s)\n" "$LINENO" "$rc" >&2' ERR

cleanup() {
    local rc=$?
    trap - EXIT
    set +e
    if [[ -n "$NTFS_MNT" ]] && mountpoint -q -- "$NTFS_MNT" 2>/dev/null; then
        umount -- "$NTFS_MNT" || true
    fi
    if [[ -n "$ESP_MNT" ]] && mountpoint -q -- "$ESP_MNT" 2>/dev/null; then
        umount -- "$ESP_MNT" || true
    fi
    if [[ -n "${TARGET:-}" ]]; then
        while IFS= read -r target_mount; do
            [[ -n "$target_mount" ]] || continue
            log "Unmounting target mount left by an automounter: $target_mount"
            umount -- "$target_mount" 2>/dev/null || umount -l -- "$target_mount" 2>/dev/null || true
        done < <(lsblk -lnpo MOUNTPOINTS -- "$TARGET" 2>/dev/null | sed '/^[[:space:]]*$/d')
    fi
    if [[ -n "${UDEV_RULE_FILE:-}" && -f "$UDEV_RULE_FILE" ]]; then
        rm -f -- "$UDEV_RULE_FILE" || true
        udevadm control --reload-rules >/dev/null 2>&1 || true
    fi
    sync || true
    if [[ -n "$WORK_DIR" && -d "$WORK_DIR" ]] && (( KEEP_WORK == 0 )); then
        rm -rf -- "$WORK_DIR"
    elif [[ -n "$WORK_DIR" && -d "$WORK_DIR" ]]; then
        log "Kept work directory: $WORK_DIR"
    fi
    if (( rc != 0 )); then
        printf '[FAIL] phase03 deployment failed (exit %s)\n' "$rc" >&2
    fi
    exit "$rc"
}
trap cleanup EXIT

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------
partition_path() {
    local disk="$1" index="$2" base
    base="$(basename -- "$disk")"
    case "$base" in
        loop*|mmcblk*|nvme*) printf '%sp%s\n' "$disk" "$index" ;;
        *) printf '%s%s\n' "$disk" "$index" ;;
    esac
}

wait_for_partitions() {
    local p1="$1" p2="$2" i
    for ((i = 0; i < 30; i++)); do
        if [[ -b "$p1" && -b "$p2" ]]; then
            return 0
        fi
        sleep 1
    done
    return 1
}

target_mountpoints() {
    lsblk -lnpo MOUNTPOINTS -- "$TARGET" 2>/dev/null \
        | sed 's/^[[:space:]]*//; s/[[:space:]]*$//' \
        | sed '/^$/d' || true
}

target_has_mounts() {
    [[ -n "$(target_mountpoints)" ]]
}

unmount_target_mounts() {
    local mp failed=0
    while IFS= read -r mp; do
        [[ -n "$mp" ]] || continue
        log "Unmounting target path auto-mounted by the desktop: $mp"
        if ! umount -- "$mp" 2>/dev/null; then
            warn "Normal unmount failed for $mp; trying a lazy unmount"
            umount -l -- "$mp" 2>/dev/null || failed=1
        fi
    done < <(target_mountpoints)
    return "$failed"
}

# Wait briefly for any delayed desktop auto-mount request, unmount it, and
# require two consecutive clean samples before returning.
ensure_target_unmounted() {
    local i stable=0
    for ((i = 0; i < 20; i++)); do
        unmount_target_mounts || true
        if target_has_mounts; then
            stable=0
        else
            stable=$((stable + 1))
            if (( stable >= 2 )); then
                return 0
            fi
        fi
        sleep 1
    done
    return 1
}

# udisks/Plasma auto-mounts newly appeared filesystems.  While we are writing
# raw data to the target, a second mount would corrupt the filesystem and make
# the target impossible to unmount.  Hide the target from the desktop for the
# duration of the deployment; the rule is removed by cleanup().
install_target_udev_guard() {
    mkdir -p -- "$UDEV_RULE_DIR" || die "Cannot create $UDEV_RULE_DIR"
    UDEV_RULE_FILE="${UDEV_RULE_DIR}/99-valos-ignore-${TARGET_BASE}.rules"
    {
        printf '# Temporary rule written by 03_deploy_wtg.sh; removed on exit.\n'
        printf 'ACTION=="add|change", SUBSYSTEM=="block", KERNEL=="%s", ENV{UDISKS_AUTO}="0", ENV{UDISKS_IGNORE}="1"\n' "$TARGET_BASE"
        printf 'ACTION=="add|change", SUBSYSTEM=="block", KERNEL=="%s*", ENV{UDISKS_AUTO}="0", ENV{UDISKS_IGNORE}="1"\n' "$TARGET_BASE"
    } > "$UDEV_RULE_FILE" || die "Cannot write $UDEV_RULE_FILE"
    udevadm control --reload-rules || die "udevadm control --reload-rules failed"
    udevadm trigger --action=change --subsystem-match=block --sysname-match="${TARGET_BASE}*" \
        || die "udevadm trigger failed for $TARGET_BASE"
    udevadm settle --timeout=30 || true
    log "Installed transient udev auto-mount guard for $TARGET_BASE"
}

verify_gpt_layout() {
    local signature p1_type p2_type
    signature="$(xxd -p -l 8 -s 512 -- "$TARGET" | tr -d '[:space:]')"
    if [[ "$signature" != "4546492050415254" ]]; then
        die "Target does not contain a GPT header (EFI PART signature missing)"
    fi
    p1_type="$(xxd -p -l 16 -s $((1024 + 0 * 128)) -- "$TARGET" | tr -d '[:space:]')"
    p2_type="$(xxd -p -l 16 -s $((1024 + 1 * 128)) -- "$TARGET" | tr -d '[:space:]')"
    # ESP type GUID C12A7328-F81F-11D2-BA4B-00A0C93EC93B (on-disk order).
    if [[ "$p1_type" != "28732ac11ff8d211ba4b00a0c93ec93b" ]]; then
        die "Partition 1 is not an EFI System Partition (type=$p1_type)"
    fi
    # Microsoft basic data EBD0A0A2-B9E5-4433-87C0-68B6B72699C7 (on-disk order).
    if [[ "$p2_type" != "a2a0d0ebe5b9334487c068b6b72699c7" ]]; then
        die "Partition 2 is not Microsoft basic data (type=$p2_type)"
    fi
}

read_gpt_guids() {
    DISK_GUID="$(xxd -p -l 16 -s $((512 + 56)) -- "$TARGET" | tr -d '[:space:]')"
    PART1_GUID="$(xxd -p -l 16 -s $((1024 + 0 * 128 + 16)) -- "$TARGET" | tr -d '[:space:]')"
    PART2_GUID="$(xxd -p -l 16 -s $((1024 + 1 * 128 + 16)) -- "$TARGET" | tr -d '[:space:]')"
    local guid
    for guid in "$DISK_GUID" "$PART1_GUID" "$PART2_GUID"; do
        if [[ ! "$guid" =~ ^[0-9a-f]{32}$ ]]; then
            die "Invalid GPT GUID read from $TARGET: $guid"
        fi
        if [[ "$guid" == "00000000000000000000000000000000" ]]; then
            die "Zero GPT GUID read from $TARGET"
        fi
    done
}

make_gpt_device_blob() {
    local part_guid="$1"
    # 88 bytes: 16-byte reserved header, device type 0x06 (partition),
    # length field 0x48, partition GUID at 0x20, GPT marker 0x00 at 0x34,
    # disk GUID at 0x38, and 16 reserved bytes.
    printf '00000000000000000000000000000000'
    printf '0600000000000000'
    printf '4800000000000000'
    printf '%s' "$part_guid"
    printf '0000000000000000'
    printf '%s' "$DISK_GUID"
    printf '00000000000000000000000000000000'
}

hex_to_reg() {
    printf '%s' "$1" | sed 's/../&,/g; s/,$//'
}

run_reged_import() {
    local hive="$1" prefix="$2" regfile="$3" logfile="$4" rc=0
    set +e
    ( reged -C -I "$hive" "$prefix" "$regfile" ) >"$logfile" 2>&1
    rc=$?
    set -e
    if ! grep -q 'operation SUCCEEDED' "$logfile"; then
        printf '[phase03] reged import failed; log follows:\n' >&2
        sed -n '1,120p' "$logfile" >&2
        return 1
    fi
    # reged 0.1 returns 2 after a successful commit and can even abort during
    # cleanup after committing.  The operation marker above plus the
    # re-export verification are authoritative.
    if (( rc != 0 && rc != 2 )); then
        printf '[phase03] WARN: reged import exited %s after a successful commit (accepted)\n' "$rc" >&2
    fi
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
        printf '[phase03] reged export produced no data (exit %s): %s\\%s\n' "$rc" "$prefix" "$key" >&2
        return 1
    fi
    if (( rc != 0 )); then
        printf '[phase03] WARN: reged export exited %s after writing %s\\%s (accepted)\n' "$rc" "$prefix" "$key" >&2
    fi
    return 0
}

verify_system_hive() {
    local hive="$1" control_set="$2" out service
    out="${WORK_DIR}/verify_control.reg"
    reged_export "$hive" 'HKEY_LOCAL_MACHINE\SYSTEM' "${control_set}\\Control" "$out" || return 1
    grep -q '"PortableOperatingSystem"=dword:00000001' "$out" || return 1
    grep -q '"PollBootPartitionTimeout"=dword:00007530' "$out" || return 1
    for service in USBSTOR UASPStor sdbus sdstor USBXHCI; do
        out="${WORK_DIR}/verify_${service}.reg"
        reged_export "$hive" 'HKEY_LOCAL_MACHINE\SYSTEM' "${control_set}\\Services\\${service}" "$out" || return 1
        grep -q '"Start"=dword:00000000' "$out" || return 1
    done
    return 0
}

read_reg_element_hex() {
    local hive="$1" key="$2" out="$3" hex
    reged_export "$hive" 'HKEY_LOCAL_MACHINE\BCD00000000' "Objects\\$key" "$out" || return 1
    hex="$(tr -d '\\ \n\r' < "$out" | grep -o '"Element"=hex:[0-9a-f,]*' | head -n1 | cut -d: -f2 | tr -d ',')"
    if [[ ${#hex} -ne 176 ]]; then
        return 1
    fi
    printf '%s' "$hex"
}

verify_bcd() {
    local hive="$1" hex element path_reg elements_reg
    hex="$(read_reg_element_hex "$hive" "${BOOTMGR_GUID}\\Elements\\11000001" "${WORK_DIR}/verify_bootmgr.reg")" \
        || return 1
    [[ "${hex:32:2}" == "06" ]] || return 1
    [[ "${hex:48:2}" == "48" ]] || return 1
    [[ "${hex:104:2}" == "00" ]] || return 1
    [[ "${hex:64:32}" == "$PART1_GUID" ]] || return 1
    [[ "${hex:112:32}" == "$DISK_GUID" ]] || return 1

    for element in 11000001 21000001; do
        hex="$(read_reg_element_hex "$hive" "${LOADER_GUID}\\Elements\\${element}" "${WORK_DIR}/verify_loader_${element}.reg")" \
            || return 1
        [[ "${hex:32:2}" == "06" ]] || return 1
        [[ "${hex:48:2}" == "48" ]] || return 1
        [[ "${hex:104:2}" == "00" ]] || return 1
        [[ "${hex:64:32}" == "$PART2_GUID" ]] || return 1
        [[ "${hex:112:32}" == "$DISK_GUID" ]] || return 1
    done

    path_reg="${WORK_DIR}/verify_loader_path.reg"
    reged_export "$hive" 'HKEY_LOCAL_MACHINE\BCD00000000' "Objects\\${LOADER_GUID}\\Elements\\12000002" "$path_reg" || return 1
    grep -Fq '"Element"="\\Windows\\system32\\winload.efi"' "$path_reg" || return 1

    elements_reg="${WORK_DIR}/verify_loader_elements.reg"
    reged_export "$hive" 'HKEY_LOCAL_MACHINE\BCD00000000' "Objects\\${LOADER_GUID}\\Elements" "$elements_reg" || return 1
    for element in 26000022 26000010 260000b0; do
        if grep -Fq "Elements\\${element}]" "$elements_reg"; then
            return 1
        fi
    done
    return 0
}

# ---------------------------------------------------------------------------
# Required tools
# ---------------------------------------------------------------------------
REQUIRED_TOOLS=(
    parted partprobe udevadm lsblk blkid xxd blockdev findmnt swapon
    mkfs.fat mkfs.ntfs wimlib-imagex
    reged mount umount sync mountpoint ntfs-3g
    losetup partx wipefs
)
for tool in "${REQUIRED_TOOLS[@]}"; do
    command -v "$tool" >/dev/null 2>&1 || die "Required tool not found: $tool"
done

# ---------------------------------------------------------------------------
# WIM and BCD template
# ---------------------------------------------------------------------------
if [[ ! -e "$WIM_PATH" ]]; then
    die "WIM not found: $WIM_PATH"
fi
WIM_PATH="$(readlink -f -- "$WIM_PATH")" || die "Cannot resolve WIM path"
if [[ ! -f "$WIM_PATH" || ! -r "$WIM_PATH" ]]; then
    die "WIM is not a readable regular file: $WIM_PATH"
fi
if ! wimlib-imagex info "$WIM_PATH" 1 >/dev/null 2>&1; then
    die "WIM does not contain image 1: $WIM_PATH"
fi

if [[ -f "$BCD_TEMPLATE" ]]; then
    BCD_SOURCE="$BCD_TEMPLATE"
elif [[ -f "$FALLBACK_BCD_TEMPLATE" ]]; then
    BCD_SOURCE="$FALLBACK_BCD_TEMPLATE"
else
    die "No BCD template found at payloads/bcd_template or build/iso_extracted/efi/microsoft/boot/bcd"
fi
if [[ ! -s "$BCD_SOURCE" ]]; then
    die "BCD template is empty: $BCD_SOURCE"
fi

# ---------------------------------------------------------------------------
# Target validation (fail closed, before any write)
# ---------------------------------------------------------------------------
if [[ ! -e "$TARGET" ]]; then
    die "Target does not exist: $TARGET"
fi
TARGET="$(readlink -f -- "$TARGET")" || die "Cannot resolve target path"
if [[ ! -b "$TARGET" ]]; then
    die "Target is not a block device: $TARGET"
fi

TARGET_BASE="$(basename -- "$TARGET")"
if [[ "$TARGET_BASE" == nvme* ]]; then
    die "Refusing NVMe host disk: $TARGET"
fi
if lsblk -lnpo PATH -- "$TARGET" 2>/dev/null | grep -qi 'nvme'; then
    die "Refusing target with NVMe ancestry: $TARGET"
fi

TARGET_TYPE="$(lsblk -dno TYPE -- "$TARGET" 2>/dev/null | head -n1 | tr -d '[:space:]')"
if [[ "$TARGET_TYPE" != "disk" && "$TARGET_TYPE" != "loop" ]]; then
    die "Target must be a whole disk or loop device, not TYPE=$TARGET_TYPE"
fi
TARGET_RM="$(lsblk -dno RM -- "$TARGET" 2>/dev/null | head -n1 | tr -d '[:space:]')"
TARGET_RO="$(lsblk -dno RO -- "$TARGET" 2>/dev/null | head -n1 | tr -d '[:space:]')"
TARGET_SIZE="$(lsblk -bdno SIZE -- "$TARGET" 2>/dev/null | head -n1 | tr -d '[:space:]')"
TARGET_MODEL="$(lsblk -dno MODEL -- "$TARGET" 2>/dev/null | head -n1 | sed 's/[[:space:]]*$//')"
if [[ "$TARGET_RO" != "0" ]]; then
    die "Refusing read-only target (RO=$TARGET_RO): $TARGET"
fi

LOOP_BACKING=""
if [[ "$TARGET_TYPE" == "loop" ]]; then
    LOOP_BACKING="$(losetup -n -O BACK-FILE -- "$TARGET" 2>/dev/null | head -n1)"
    if [[ -z "$LOOP_BACKING" ]]; then
        die "Loop device has no backing file: $TARGET"
    fi
    LOOP_BACKING="$(readlink -f -- "$LOOP_BACKING")" || die "Cannot resolve loop backing file"
    if [[ ! -f "$LOOP_BACKING" ]]; then
        die "Loop backing is not a regular file: $LOOP_BACKING"
    fi
    case "$LOOP_BACKING" in
        "$BUILD_DIR"/*|"${PROJECT_ROOT}/vm-test"/*) ;;
        *) die "Loop backing file is outside build/ or vm-test/: $LOOP_BACKING" ;;
    esac
    if [[ "$LOOP_BACKING" == "$WIM_PATH" ]]; then
        die "Loop backing file is the source WIM: $LOOP_BACKING"
    fi
else
    if [[ "$TARGET_RM" != "1" ]]; then
        die "Refusing non-removable disk (RM=$TARGET_RM): $TARGET"
    fi
fi

# No mount may exist anywhere in the target's tree.  This includes [SWAP].
if ! TARGET_ROWS="$(lsblk -lnpo NAME,MOUNTPOINTS -- "$TARGET" 2>/dev/null)"; then
    die "Unable to query the target device tree"
fi
if awk 'NF > 1 { found=1 } END { exit(found ? 0 : 1) }' <<< "$TARGET_ROWS"; then
    printf '%s\n' "$TARGET_ROWS" >&2
    die "Target or one of its children is mounted or active as swap"
fi
if swapon --show=NAME --noheadings --raw 2>/dev/null | grep -Fxq -- "$TARGET"; then
    die "Target is an active swap device: $TARGET"
fi

# Host root / home / boot ancestry checks.
for mountpoint_path in / /home /boot /boot/efi /var; do
    host_source="$(findmnt -no SOURCE --target "$mountpoint_path" 2>/dev/null || true)"
    host_source="${host_source%%\[*}"
    if [[ -z "$host_source" || "$host_source" == "none" || ! -b "$host_source" ]]; then
        continue
    fi
    if [[ "$host_source" == "$TARGET" ]]; then
        die "Target is mounted at $mountpoint_path"
    fi
    host_parent="$(lsblk -no PKNAME -- "$host_source" 2>/dev/null | head -n1 | tr -d '[:space:]')"
    if [[ -n "$host_parent" && "/dev/$host_parent" == "$TARGET" ]]; then
        die "Target is the parent disk of the host mount $mountpoint_path"
    fi
done

# Refuse stacked/unknown device-mapper children.
if lsblk -lnpo TYPE -- "$TARGET" 2>/dev/null | grep -Eq '^(lvm|crypt|md|dm)$'; then
    die "Target has stacked device-mapper children"
fi

# Partition layout sanity.
PART1="$(partition_path "$TARGET" 1)"
PART2="$(partition_path "$TARGET" 2)"

log "Validated target: $TARGET"
log "  type=$TARGET_TYPE rm=$TARGET_RM ro=$TARGET_RO size=${TARGET_SIZE:-unknown} model=${TARGET_MODEL:-unknown}"
if [[ -n "$LOOP_BACKING" ]]; then
    log "  loop backing: $LOOP_BACKING"
fi
lsblk -o NAME,KNAME,PATH,TYPE,RM,RO,SIZE,MOUNTPOINTS,PKNAME -- "$TARGET" || true

if (( COMMIT == 0 )); then
    cat <<EOF

[phase03] DRY-RUN: validation passed; no block device was modified.
  WIM:        $WIM_PATH
  BCD source: $BCD_SOURCE
  Partition 1: $PART1  260 MiB FAT32, flags boot,esp, label $WTG_EFI_LABEL
  Partition 2: $PART2  remainder NTFS, flag msftdata, label $VAL_OS_LABEL
  Planned:    GPT relabel, format both partitions, apply WIM image 1 to
              partition 2, patch the offline SYSTEM hive, and install a
              GPT-aware UEFI BCD on the ESP.
  To deploy:  re-run as root with --commit --yes
EOF
    exit 0
fi

if (( EUID != 0 )); then
    die "Refusing to write as a non-root user; re-run with sudo or pkexec"
fi
if (( ASSUME_YES == 0 )); then
    if [[ ! -t 0 ]]; then
        die "Refusing non-interactive commit without --yes"
    fi
    printf 'Type ERASE to irreversibly destroy %s: ' "$TARGET"
    read -r confirmation
    if [[ "$confirmation" != "ERASE" ]]; then
        die "Confirmation failed; target was not modified"
    fi
fi

log "Commit confirmed for $TARGET"
date -u +'[phase03] started at %Y-%m-%dT%H:%M:%SZ'

ensure_target_unmounted || die "Target has mounts that could not be cleared before deployment"
install_target_udev_guard

WORK_DIR="$(mktemp -d "${BUILD_DIR}/phase03_deploy.XXXXXX")"
if [[ "$WORK_DIR" != "${BUILD_DIR}/phase03_deploy."* ]]; then
    die "Temporary directory escaped build/: $WORK_DIR"
fi
NTFS_MNT="${WORK_DIR}/ntfs"
ESP_MNT="${WORK_DIR}/esp"
mkdir -p -- "$NTFS_MNT" "$ESP_MNT"

# ---------------------------------------------------------------------------
# GPT partitioning
# ---------------------------------------------------------------------------
log "Creating GPT on $TARGET"
partx -d -- "$TARGET" >/dev/null 2>&1 || true
wipefs -a -- "$TARGET" >/dev/null 2>&1 || true
parted -s -- "$TARGET" mklabel gpt
parted -s -- "$TARGET" unit MiB mkpart ESP fat32 1 261
parted -s -- "$TARGET" set 1 esp on
parted -s -- "$TARGET" set 1 boot on
parted -s -- "$TARGET" unit MiB mkpart ValOS ntfs 261 100%
parted -s -- "$TARGET" set 2 msftdata on

partprobe -- "$TARGET" >/dev/null 2>&1 || true
udevadm settle --timeout=30 || true
blockdev --rereadpt -- "$TARGET" >/dev/null 2>&1 || true
partx -u -- "$TARGET" >/dev/null 2>&1 || true
udevadm settle --timeout=30 || true

wait_for_partitions "$PART1" "$PART2" || die "Kernel partition nodes did not appear: $PART1 $PART2"

for part in "$PART1" "$PART2"; do
    part_parent="$(lsblk -no PKNAME -- "$part" 2>/dev/null | head -n1 | tr -d '[:space:]')"
    if [[ "$part_parent" != "$(basename -- "$TARGET")" ]]; then
        die "Partition $part does not belong to $TARGET (PKNAME=${part_parent:-empty})"
    fi
done

verify_gpt_layout

# ---------------------------------------------------------------------------
# Filesystems and WIM apply
# ---------------------------------------------------------------------------
log "Formatting $PART1 as FAT32 ($WTG_EFI_LABEL)"
mkfs.fat -F 32 -n "$WTG_EFI_LABEL" "$PART1"

ensure_target_unmounted || die "Target was auto-mounted after formatting the ESP"

log "Formatting $PART2 as NTFS ($VAL_OS_LABEL)"
mkfs.ntfs -Q -F -L "$VAL_OS_LABEL" "$PART2"

ensure_target_unmounted || die "Target was auto-mounted after formatting the OS partition"

if [[ "$(blkid -p -o value -s TYPE -- "$PART1" 2>/dev/null)" != "vfat" ]]; then
    die "Partition 1 is not detected as vfat"
fi
if [[ "$(blkid -p -o value -s TYPE -- "$PART2" 2>/dev/null)" != "ntfs" ]]; then
    die "Partition 2 is not detected as NTFS"
fi

if target_has_mounts; then
    die "Target is mounted immediately before WIM apply; refusing a raw write"
fi
log "Applying image 1 from $WIM_PATH to $PART2"
wimlib-imagex apply "$WIM_PATH" 1 "$PART2"

if target_has_mounts; then
    die "Target was mounted while the WIM was being applied; refusing to patch a possibly inconsistent filesystem"
fi

if ! ntfs-3g -o rw "$PART2" "$NTFS_MNT"; then
    die "Failed to mount the NTFS partition read-write"
fi
if ! mount -t vfat "$PART1" "$ESP_MNT"; then
    die "Failed to mount the ESP read-write"
fi
[[ -d "$NTFS_MNT/Windows/System32/config" ]] || die "Applied image is missing Windows/System32/config"

# ---------------------------------------------------------------------------
# Offline SYSTEM hive: portable-OS and USB/SD boot-start fixes
# ---------------------------------------------------------------------------
log "Patching the offline SYSTEM hive"
SYSTEM_HIVE="$NTFS_MNT/Windows/System32/config/SYSTEM"
SYSTEM_WORK="${WORK_DIR}/SYSTEM"
[[ -f "$SYSTEM_HIVE" ]] || die "SYSTEM hive not found in the applied image"
cp -- "$SYSTEM_HIVE" "$SYSTEM_WORK"

SELECT_REG="${WORK_DIR}/select.reg"
reged_export "$SYSTEM_WORK" 'HKEY_LOCAL_MACHINE\SYSTEM' 'Select' "$SELECT_REG" \
    || die "Could not export SYSTEM\\Select"
current_hex="$(grep -m1 -oE '"Current"=dword:[0-9a-fA-F]+' "$SELECT_REG" | cut -d: -f2 || true)"
[[ -n "$current_hex" ]] || die "Could not read SYSTEM\\Select\\Current"
current_set=$((16#$current_hex))
control_set="$(printf 'ControlSet%03d' "$current_set")"
[[ "$control_set" =~ ^ControlSet[0-9]{3}$ ]] || die "Invalid control set: $control_set"
log "  active control set: $control_set"

SYSTEM_PATCH="${WORK_DIR}/system_patch.reg"
{
    printf 'Windows Registry Editor Version 5.00\n\n'
    printf '[HKEY_LOCAL_MACHINE\\SYSTEM\\%s\\Control]\n' "$control_set"
    printf '"PortableOperatingSystem"=dword:00000001\n\n'
    printf '[HKEY_LOCAL_MACHINE\\SYSTEM\\%s\\Control\\PnP]\n' "$control_set"
    printf '"PollBootPartitionTimeout"=dword:00007530\n\n'
    for service in USBSTOR UASPStor sdbus sdstor USBXHCI; do
        printf '[HKEY_LOCAL_MACHINE\\SYSTEM\\%s\\Services\\%s]\n' "$control_set" "$service"
        printf '"Start"=dword:00000000\n\n'
    done
} > "$SYSTEM_PATCH"

run_reged_import "$SYSTEM_WORK" 'HKEY_LOCAL_MACHINE\SYSTEM' "$SYSTEM_PATCH" "${WORK_DIR}/system_import.log" \
    || die "reged failed to import the SYSTEM patch"

verify_system_hive "$SYSTEM_WORK" "$control_set" \
    || die "SYSTEM hive verification failed after patching"

cat -- "$SYSTEM_WORK" > "$SYSTEM_HIVE"
sync

# ---------------------------------------------------------------------------
# BCD: convert the setup template into a normal GPT Windows loader
# ---------------------------------------------------------------------------
log "Building the GPT-aware UEFI BCD"
verify_gpt_layout
read_gpt_guids

BCD_WORK="${WORK_DIR}/BCD"
cp -- "$BCD_SOURCE" "$BCD_WORK"

BOOTMGR_BLOB="$(make_gpt_device_blob "$PART1_GUID")"
LOADER_BLOB="$(make_gpt_device_blob "$PART2_GUID")"

BCD_PATCH="${WORK_DIR}/bcd_patch.reg"
{
    printf 'Windows Registry Editor Version 5.00\n\n'
    printf '[HKEY_LOCAL_MACHINE\\BCD00000000\\Objects\\%s\\Elements\\11000001]\n' "$BOOTMGR_GUID"
    printf '"Element"=hex:%s\n\n' "$(hex_to_reg "$BOOTMGR_BLOB")"
    printf '[HKEY_LOCAL_MACHINE\\BCD00000000\\Objects\\%s\\Elements\\11000001]\n' "$LOADER_GUID"
    printf '"Element"=hex:%s\n\n' "$(hex_to_reg "$LOADER_BLOB")"
    printf '[HKEY_LOCAL_MACHINE\\BCD00000000\\Objects\\%s\\Elements\\21000001]\n' "$LOADER_GUID"
    printf '"Element"=hex:%s\n\n' "$(hex_to_reg "$LOADER_BLOB")"
    printf '[HKEY_LOCAL_MACHINE\\BCD00000000\\Objects\\%s\\Elements\\12000002]\n' "$LOADER_GUID"
    printf '"Element"="\\\\Windows\\\\system32\\\\winload.efi"\n\n'
    printf '[HKEY_LOCAL_MACHINE\\BCD00000000\\Objects\\%s\\Elements\\12000004]\n' "$LOADER_GUID"
    printf '"Element"="Windows 10 ValOS"\n\n'
} > "$BCD_PATCH"

run_reged_import "$BCD_WORK" 'HKEY_LOCAL_MACHINE\BCD00000000' "$BCD_PATCH" "${WORK_DIR}/bcd_import.log" \
    || die "reged failed to import the BCD patch"

# Remove the WinPE-only flags from the repurposed setup loader.
BCD_DELETE_LOG="${WORK_DIR}/bcd_delete.log"
set +e
printf 'cd \\Objects\\%s\\Elements\nrdel 26000022\nrdel 26000010\nrdel 260000b0\nq\ny\n' "$LOADER_GUID" \
    | reged -C -e "$BCD_WORK" >"$BCD_DELETE_LOG" 2>&1
set -e

verify_bcd "$BCD_WORK" || die "BCD verification failed after patching"

# ---------------------------------------------------------------------------
# ESP payload
# ---------------------------------------------------------------------------
EFI_SRC="$NTFS_MNT/Windows/Boot/EFI"
if [[ ! -f "$EFI_SRC/bootmgfw.efi" ]]; then
    warn "Windows/Boot/EFI is missing from the image; using staged EFI files"
    EFI_SRC="$EFI_FALLBACK"
fi
[[ -f "$EFI_SRC/bootmgfw.efi" ]] || die "No bootmgfw.efi found in the image or build/efi_staged"
[[ -s "$BCD_WORK" ]] || die "Patched BCD is empty"

log "Installing UEFI boot files on the ESP"
mkdir -p -- "$ESP_MNT/EFI/Microsoft/Boot" "$ESP_MNT/EFI/Boot"
cp -a -- "$EFI_SRC/." "$ESP_MNT/EFI/Microsoft/Boot/"

# Copy the patched BCD last so a source BCD cannot overwrite it.
cp -- "$BCD_WORK" "$ESP_MNT/EFI/Microsoft/Boot/BCD"

if [[ -d "$NTFS_MNT/Windows/Boot/Fonts" ]]; then
    cp -a -- "$NTFS_MNT/Windows/Boot/Fonts" "$ESP_MNT/EFI/Microsoft/Boot/"
fi

cp -- "$ESP_MNT/EFI/Microsoft/Boot/bootmgfw.efi" "$ESP_MNT/EFI/Boot/bootx64.efi"
sync

[[ -s "$ESP_MNT/EFI/Microsoft/Boot/bootmgfw.efi" ]] || die "bootmgfw.efi was not installed on the ESP"
[[ -s "$ESP_MNT/EFI/Boot/bootx64.efi" ]] || die "EFI/Boot/bootx64.efi was not installed"
[[ -s "$ESP_MNT/EFI/Microsoft/Boot/BCD" ]] || die "BCD was not installed on the ESP"
cmp -s -- "$ESP_MNT/EFI/Microsoft/Boot/bootmgfw.efi" "$ESP_MNT/EFI/Boot/bootx64.efi" \
    || die "bootx64.efi does not match bootmgfw.efi"
cmp -s -- "$BCD_WORK" "$ESP_MNT/EFI/Microsoft/Boot/BCD" \
    || die "The installed BCD differs from the verified BCD"

# ---------------------------------------------------------------------------
# Clean unmount and summary
# ---------------------------------------------------------------------------
log "Syncing and unmounting"
sync
umount -- "$NTFS_MNT" || die "Failed to unmount the NTFS partition cleanly"
NTFS_MNT=""
umount -- "$ESP_MNT" || die "Failed to unmount the ESP cleanly"
ESP_MNT=""
sync

ensure_target_unmounted || die "Target is still mounted after deployment"
partprobe -- "$TARGET" >/dev/null 2>&1 || true
udevadm settle --timeout=30 || true

log "Deployment complete"
log "  target:      $TARGET"
log "  partition 1: $PART1 ($WTG_EFI_LABEL)"
log "  partition 2: $PART2 ($VAL_OS_LABEL)"
log "  disk GUID:   $DISK_GUID"
log "  ESP GUID:    $PART1_GUID"
log "  OS GUID:     $PART2_GUID"
log "  log:         $LOG_FILE"

exit 0
