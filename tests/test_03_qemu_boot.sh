#!/usr/bin/env bash
# Phase 3 verification gate: deploy the prepared WIM to a disposable 25 GiB
# sparse "microSD" image through the Phase 3 engine, then boot that image under
# QEMU with 4 MiB OVMF (Secure Boot firmware), SMM, and a TPM 2.0 swtpm.
#
# The gate passes only when Windows reaches first logon, the provisioning
# payload writes /Riot Games/boot_verified.txt, the guest shuts itself down, and
# the offline hive changes are visible from a read-only mount.
#
# Destructive scope: vm-test/test_sdcard.img only.  Host block devices are never
# touched.  Run as root through pkexec or sudo (loop devices and mounts).

set -Eeuo pipefail
IFS=$'\n\t'

PROJECT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
readonly PROJECT_ROOT

readonly DEPLOY_SCRIPT="${PROJECT_ROOT}/scripts/03_deploy_wtg.sh"
readonly TEST_DIR="${PROJECT_ROOT}/vm-test"
readonly IMAGE="${TEST_DIR}/test_sdcard.img"
readonly VARS="${TEST_DIR}/OVMF_VARS.4m.fd"
readonly MOUNT_DIR="${TEST_DIR}/mnt-ro"
readonly SCREENS_DIR="${TEST_DIR}/screens"
readonly TPM_DIR="${TEST_DIR}/tpm-state"
readonly SWTPM_SOCK="${TEST_DIR}/swtpm.sock"
readonly SWTPM_PIDFILE="${TEST_DIR}/swtpm.pid"
readonly QMP_SOCK="${TEST_DIR}/qmp.sock"
readonly SERIAL_LOG="${TEST_DIR}/serial.log"
readonly QEMU_LOG="${TEST_DIR}/qemu.log"
readonly VERIFY_DIR="${TEST_DIR}/verify"

readonly OVMF_CODE="/usr/share/edk2/x64/OVMF_CODE.secboot.4m.fd"
readonly OVMF_VARS_SRC="/usr/share/edk2/x64/OVMF_VARS.4m.fd"

readonly LOG_DIR="${PROJECT_ROOT}/build/logs"
readonly LOG="${LOG_DIR}/test_03_qemu_boot.log"

readonly IMAGE_SIZE_BYTES=$((25 * 1024 * 1024 * 1024))
TIMEOUT_SECONDS=7200
SCREEN_INTERVAL=300
KEEP_IMAGE=1

LOOP_DEV=""
QEMU_PID=""
SWTPM_PID=""
RO_MOUNTED=0
TIMED_OUT=0
QEMU_RC=""
QEMU_SHUTDOWN_OK=0

PASS=0
FAIL=0
FAILED_CHECKS=()

usage() {
    cat <<'EOF'
Usage: test_03_qemu_boot.sh [options]

Options:
  --timeout <seconds>  Maximum QEMU wall time (default: 7200).
  --clean-image        Delete the disposable image after the test.
  --keep-image         Keep vm-test/test_sdcard.img (default).
  -h, --help           Show this help.

The test creates vm-test/test_sdcard.img, deploys through
scripts/03_deploy_wtg.sh, boots with OVMF CODE.secboot.4m.fd + TPM 2.0, then
mounts partition 2 read-only and verifies the first-logon artifacts.

This script must run as root and only modifies files under vm-test/.
EOF
}

log() { printf '[phase03-test] %s\n' "$*"; }
die() { printf '[FAIL] %s\n' "$*" >&2; exit 1; }

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
        --timeout)
            (( $# >= 2 )) || die "--timeout requires a value"
            [[ "$2" =~ ^[1-9][0-9]*$ ]] || die "--timeout must be a positive integer"
            TIMEOUT_SECONDS="$2"
            shift 2
            ;;
        --clean-image)
            KEEP_IMAGE=0
            shift
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
            die "Unknown argument: $1"
            ;;
    esac
done

if (( EUID != 0 )); then
    die "This gate needs loop devices, mounts, and KVM; run it through: pkexec $0"
fi

REQUIRED_TOOLS=(
    qemu-system-x86_64 swtpm socat losetup partx truncate stat
    blkid udevadm ntfs-3g reged mountpoint sync awk grep sed
    sha256sum date ps sleep cat timeout pgrep readlink umount lsblk
)
for tool in "${REQUIRED_TOOLS[@]}"; do
    command -v "$tool" >/dev/null 2>&1 || die "Required tool not found: $tool"
done
for firmware in "$OVMF_CODE" "$OVMF_VARS_SRC"; do
    [[ -r "$firmware" ]] || die "Missing OVMF firmware: $firmware"
done
[[ -x "$DEPLOY_SCRIPT" ]] || die "Deploy engine is missing or not executable: $DEPLOY_SCRIPT"
[[ -r /dev/kvm ]] || die "/dev/kvm is unavailable; this gate never falls back to TCG"

mkdir -p -- "$LOG_DIR" "$TEST_DIR"
[[ "$TEST_DIR" == "${PROJECT_ROOT}/vm-test" ]] || die "vm-test escaped the project root: $TEST_DIR"
mkdir -p -- "$LOG_DIR"
: > "$LOG"
exec > >(tee -a "$LOG") 2>&1

trap 'rc=$?; if (( rc != 0 )); then printf "[FAIL] phase03 test harness aborted unexpectedly (exit %s) at line %s\n" "$rc" "$LINENO" >&2; fi' ERR

process_alive() {
    local pid="${1:-}" state
    [[ -n "$pid" ]] || return 1
    state="$(ps -o stat= -p "$pid" 2>/dev/null | tr -d '[:space:]')"
    [[ -n "$state" && "$state" != Z* ]]
}

qmp_exec() {
    local command="$1"
    printf '{"execute":"qmp_capabilities"}\n%s\n' "$command" \
        | timeout 10 socat - "UNIX-CONNECT:${QMP_SOCK}" >/dev/null 2>&1 || true
}

take_screenshot() {
    local label="${1:-last}" ppm png
    ppm="${SCREENS_DIR}/${label}.ppm"
    png="${SCREENS_DIR}/${label}.png"
    mkdir -p -- "$SCREENS_DIR"
    qmp_exec "{\"execute\":\"screendump\",\"arguments\":{\"filename\":\"${ppm}\"}}"
    sleep 1
    if [[ -s "$ppm" ]]; then
        if command -v magick >/dev/null 2>&1; then
            magick "$ppm" "$png" >/dev/null 2>&1 || true
        elif command -v convert >/dev/null 2>&1; then
            convert "$ppm" "$png" >/dev/null 2>&1 || true
        fi
        log "Screenshot: $png"
    fi
}

stop_swtpm() {
    local pid="${SWTPM_PID:-}"
    if [[ -z "$pid" && -f "$SWTPM_PIDFILE" ]]; then
        pid="$(cat -- "$SWTPM_PIDFILE" 2>/dev/null || true)"
    fi
    if [[ -n "$pid" ]] && kill -0 "$pid" 2>/dev/null; then
        kill "$pid" 2>/dev/null || true
        for ((i = 0; i < 20; i++)); do
            kill -0 "$pid" 2>/dev/null || break
            sleep 0.25
        done
        kill -9 "$pid" 2>/dev/null || true
    fi
    SWTPM_PID=""
}

# The desktop can auto-mount any new filesystem it sees.  Such a mount keeps
# the loop device busy and prevents a clean detach, so clear those mounts
# before touching the loop device.
unmount_loop_mounts() {
    local mp
    [[ -n "${LOOP_DEV:-}" ]] || return 0
    while IFS= read -r mp; do
        [[ -n "$mp" ]] || continue
        log "Unmounting loop mount left by an automounter: $mp"
        umount -- "$mp" 2>/dev/null || umount -l -- "$mp" 2>/dev/null || true
    done < <(lsblk -lnpo MOUNTPOINTS -- "$LOOP_DEV" 2>/dev/null | sed '/^[[:space:]]*$/d')
}

cleanup() {
    local rc=$? i
    trap - EXIT
    trap - ERR
    set +e

    if process_alive "${QEMU_PID:-}"; then
        qmp_exec '{"execute":"quit"}'
        sleep 1
    fi
    if process_alive "${QEMU_PID:-}"; then
        kill "$QEMU_PID" 2>/dev/null || true
    fi
    if [[ -n "${QEMU_PID:-}" ]]; then
        wait "$QEMU_PID" 2>/dev/null || true
    fi
    QEMU_PID=""

    stop_swtpm

    if mountpoint -q -- "$MOUNT_DIR" 2>/dev/null; then
        umount -- "$MOUNT_DIR" || umount -l -- "$MOUNT_DIR" || true
    fi
    if [[ -n "${LOOP_DEV:-}" ]]; then
        unmount_loop_mounts
        partx -d -- "$LOOP_DEV" >/dev/null 2>&1 || true
        for ((i = 0; i < 20; i++)); do
            losetup -d "$LOOP_DEV" 2>/dev/null || true
            [[ -z "$(losetup -n -O BACK-FILE -- "$LOOP_DEV" 2>/dev/null)" ]] && break
            sleep 0.5
            unmount_loop_mounts
        done
    fi
    LOOP_DEV=""

    if (( KEEP_IMAGE == 0 )) && [[ -f "$IMAGE" ]]; then
        rm -f -- "$IMAGE"
    fi

    if (( rc != 0 )); then
        printf '[FAIL] phase03 QEMU boot gate aborted (exit %s)\n' "$rc" >&2
    fi
    exit "$rc"
}
trap cleanup EXIT

summary() {
    printf '\nPassed: %d  Failed: %d\n' "$PASS" "$FAIL"
    if (( FAIL > 0 )); then
        printf '[FAIL] Phase 3 QEMU boot gate failed: %s\n' "${FAILED_CHECKS[*]}"
        exit 1
    fi
    printf '[PASS] Phase 3 QEMU boot gate passed\n'
    exit 0
}

export_reg() {
    local hive="$1" prefix="$2" key="$3" out="$4" rc=0
    rm -f -- "$out"
    set +e
    ( reged -x "$hive" "$prefix" "$key" "$out" ) >/dev/null 2>&1
    rc=$?
    set -e
    # reged 0.1 can abort during cleanup after writing a complete export.
    if (( rc != 0 )) && [[ -s "$out" ]]; then
        log "WARN: reged export exited $rc after writing ${key} (accepted)"
    fi
    [[ -s "$out" ]]
}

# ---------------------------------------------------------------------------
# Disposable image and Phase 3 deployment
# ---------------------------------------------------------------------------
if pgrep -f -- "qemu-system-x86_64.*${IMAGE}" >/dev/null 2>&1; then
    die "QEMU is still using ${IMAGE}; refusing to truncate it"
fi

log "Creating 25 GiB sparse test image: ${IMAGE}"
rm -f -- "$IMAGE"
truncate -s "$IMAGE_SIZE_BYTES" -- "$IMAGE"
actual_size="$(stat -c %s -- "$IMAGE")"
[[ "$actual_size" == "$IMAGE_SIZE_BYTES" ]] || die "Sparse image has wrong size: $actual_size"
log "  apparent size: $(numfmt --to=iec --suffix=B "$actual_size" 2>/dev/null || echo "$actual_size bytes")"

log "Attaching image to a loop device"
LOOP_DEV="$(losetup --find --show --partscan "$IMAGE")" || die "losetup failed for $IMAGE"
[[ -b "$LOOP_DEV" ]] || die "losetup did not return a block device: $LOOP_DEV"
log "  loop device: $LOOP_DEV"

log "Running the Phase 3 deploy engine"
if ! "$DEPLOY_SCRIPT" --target "$LOOP_DEV" --commit --yes; then
    fail "deploy-engine" "$DEPLOY_SCRIPT failed; see build/logs/03_deploy_*.log"
    summary
fi

for ((i = 0; i < 30; i++)); do
    [[ -b "${LOOP_DEV}p1" && -b "${LOOP_DEV}p2" ]] && break
    partx -u -- "$LOOP_DEV" >/dev/null 2>&1 || true
    sleep 1
done
[[ -b "${LOOP_DEV}p1" && -b "${LOOP_DEV}p2" ]] || {
    fail "partition-nodes" "loop partitions did not appear after deployment"
    summary
}
pass "deploy-engine" "deploy completed and loop partitions exist"

log "Detaching the loop device before QEMU"
sync
udevadm settle --timeout=30 || true
saved_err_trap="$(trap -p ERR || true)"
trap - ERR
detached=0
for ((i = 0; i < 20; i++)); do
    unmount_loop_mounts
    partx -d -- "$LOOP_DEV" >/dev/null 2>&1 || true
    losetup -d "$LOOP_DEV" 2>/dev/null || true
    if [[ -z "$(losetup -n -O BACK-FILE -- "$LOOP_DEV" 2>/dev/null)" ]]; then
        detached=1
        break
    fi
    sleep 0.5
done
(( detached == 1 )) || die "Failed to detach $LOOP_DEV; still mounted or busy"
LOOP_DEV=""
eval "${saved_err_trap:-trap - ERR}"
udevadm settle --timeout=30 || true

# ---------------------------------------------------------------------------
# TPM 2.0 and QEMU/OVMF
# ---------------------------------------------------------------------------
log "Preparing OVMF variables and swtpm state"
if [[ -f "$SWTPM_PIDFILE" ]]; then
    stale_pid="$(cat -- "$SWTPM_PIDFILE" 2>/dev/null || true)"
    if [[ -n "$stale_pid" ]] && kill -0 "$stale_pid" 2>/dev/null; then
        kill "$stale_pid" 2>/dev/null || true
        for ((i = 0; i < 20; i++)); do
            kill -0 "$stale_pid" 2>/dev/null || break
            sleep 0.25
        done
        kill -9 "$stale_pid" 2>/dev/null || true
    fi
fi
cp -- "$OVMF_VARS_SRC" "$VARS"
rm -rf -- "$TPM_DIR" "$SCREENS_DIR" "$VERIFY_DIR"
mkdir -p -- "$TPM_DIR" "$SCREENS_DIR" "$VERIFY_DIR"

swtpm socket --tpm2 \
    --tpmstate "dir=${TPM_DIR}" \
    --ctrl "type=unixio,path=${SWTPM_SOCK}" \
    --daemon \
    --pid "file=${SWTPM_PIDFILE}" \
    --flags not-need-init,startup-clear \
    || die "swtpm failed to start"
SWTPM_PID="$(cat -- "$SWTPM_PIDFILE" 2>/dev/null || true)"
[[ -n "$SWTPM_PID" ]] || die "swtpm did not write a PID file"
process_alive "$SWTPM_PID" || die "swtpm exited immediately"
pass "tpm2-swtpm" "TPM 2.0 swtpm is running (pid $SWTPM_PID)"

QEMU_ARGS=(
    -name "ValOS-Phase3-Gate"
    -machine "q35,smm=on"
    -global "driver=cfi.pflash01,property=secure,value=on"
    -drive "if=pflash,format=raw,unit=0,readonly=on,file=${OVMF_CODE}"
    -drive "if=pflash,format=raw,unit=1,file=${VARS}"
    -drive "file=${IMAGE},format=raw,if=ide,media=disk"
    -chardev "socket,id=chrtpm,path=${SWTPM_SOCK}"
    -tpmdev "emulator,id=tpm0,chardev=chrtpm"
    -device "tpm-tis,tpmdev=tpm0"
    -enable-kvm
    -m 4096
    -cpu host
    -smp 4
    -boot "order=c,menu=off"
    -nic none
    -display none
    -qmp "unix:${QMP_SOCK},server=on,wait=off"
    -serial "file:${SERIAL_LOG}"
)

log "Booting the deployed image under OVMF Secure Boot firmware + TPM 2.0"
qemu-system-x86_64 "${QEMU_ARGS[@]}" >"$QEMU_LOG" 2>&1 &
QEMU_PID=$!
log "  QEMU pid: $QEMU_PID; timeout: ${TIMEOUT_SECONDS}s"

for ((i = 0; i < 30; i++)); do
    [[ -S "$QMP_SOCK" ]] && break
    process_alive "$QEMU_PID" || break
    sleep 1
done
if ! process_alive "$QEMU_PID"; then
    printf '\n--- qemu.log ---\n' >&2
    tail -n 80 "$QEMU_LOG" >&2 || true
    fail "qemu-start" "QEMU exited before the guest could boot"
    summary
fi

START_TIME="$(date +%s)"
LAST_SCREEN="$START_TIME"
while process_alive "$QEMU_PID"; do
    NOW="$(date +%s)"
    ELAPSED=$((NOW - START_TIME))
    if (( ELAPSED >= TIMEOUT_SECONDS )); then
        TIMED_OUT=1
        break
    fi
    if (( NOW - LAST_SCREEN >= SCREEN_INTERVAL )); then
        take_screenshot "elapsed-${ELAPSED}"
        log "QEMU still running after ${ELAPSED}s"
        LAST_SCREEN="$NOW"
    fi
    sleep 15
done

if (( TIMED_OUT )); then
    log "QEMU exceeded ${TIMEOUT_SECONDS}s; requesting ACPI shutdown"
    take_screenshot "timeout"
    qmp_exec '{"execute":"system_powerdown"}'
    for ((i = 0; i < 60; i++)); do
        process_alive "$QEMU_PID" || break
        sleep 1
    done
    if process_alive "$QEMU_PID"; then
        log "ACPI shutdown did not complete; quitting QEMU"
        qmp_exec '{"execute":"quit"}'
        sleep 2
    fi
    if process_alive "$QEMU_PID"; then
        kill "$QEMU_PID" 2>/dev/null || true
    fi
fi

set +e
wait "$QEMU_PID"
QEMU_RC=$?
set -e
QEMU_PID=""
log "QEMU exited with status ${QEMU_RC}"

stop_swtpm

# A clean QEMU exit is necessary but not sufficient: the guest must also have
# written the first-logon marker below.  Both are asserted together there.
if (( TIMED_OUT )); then
    log "QEMU timed out; the guest did not request shutdown"
elif (( QEMU_RC == 0 )); then
    QEMU_SHUTDOWN_OK=1
    log "QEMU exited cleanly; awaiting the boot-marker check"
else
    log "QEMU exited with status ${QEMU_RC}; treating it as an abnormal exit"
fi

# ---------------------------------------------------------------------------
# Read-only verification mount
# ---------------------------------------------------------------------------
log "Attaching the image read-only for verification"
LOOP_DEV="$(losetup --find --show --read-only --partscan "$IMAGE")" \
    || die "Failed to attach the image read-only"
LOOP_DEV="$(readlink -f -- "$LOOP_DEV")"
PART2="${LOOP_DEV}p2"

for ((i = 0; i < 30; i++)); do
    [[ -b "$PART2" ]] && break
    partx -u -- "$LOOP_DEV" >/dev/null 2>&1 || true
    sleep 1
done
if [[ ! -b "$PART2" ]]; then
    fail "verify-partition" "read-only partition node did not appear: $PART2"
    summary
fi

mkdir -p -- "$MOUNT_DIR"
if ntfs-3g -o ro "$PART2" "$MOUNT_DIR" 2>"${VERIFY_DIR}/mount.err"; then
    RO_MOUNTED=1
elif ntfs-3g -o ro,force "$PART2" "$MOUNT_DIR" 2>>"${VERIFY_DIR}/mount.err"; then
    RO_MOUNTED=1
    log "Mounted with -o ro,force because the volume was left dirty"
else
    cat -- "${VERIFY_DIR}/mount.err" >&2 || true
    fail "verify-mount" "could not mount $PART2 read-only"
    summary
fi
pass "verify-mount" "partition 2 mounted read-only at $MOUNT_DIR"

# ---------------------------------------------------------------------------
# Required first-logon artifacts
# ---------------------------------------------------------------------------
MARKER="${MOUNT_DIR}/Riot Games/boot_verified.txt"
if [[ -f "$MARKER" ]]; then
    pass "boot-marker-present" "found /Riot Games/boot_verified.txt"
    printf '%s\n' '---- boot_verified.txt ----'
    cat -- "$MARKER"
    printf '%s\n' '---- end boot_verified.txt ----'
else
    fail "boot-marker-present" "missing /Riot Games/boot_verified.txt"
fi

if [[ -f "$MARKER" ]] && (( QEMU_SHUTDOWN_OK == 1 )); then
    pass "qemu-autoshutdown" "guest wrote the boot marker and exited QEMU cleanly (rc 0)"
elif (( TIMED_OUT )); then
    fail "qemu-autoshutdown" "guest did not shut down within ${TIMEOUT_SECONDS}s"
elif (( QEMU_RC != 0 )); then
    fail "qemu-autoshutdown" "QEMU exited with status ${QEMU_RC}; no clean guest shutdown"
else
    fail "qemu-autoshutdown" "QEMU exited cleanly but the guest boot marker is missing"
fi

if [[ -f "$MARKER" ]] && grep -Fq -- "QEMU" "$MARKER"; then
    pass "boot-marker-qemu" "marker records the QEMU SystemManufacturer"
else
    fail "boot-marker-qemu" "marker does not record QEMU"
fi

SOFTWARE_HIVE="${MOUNT_DIR}/Windows/System32/config/SOFTWARE"
SYSTEM_HIVE="${MOUNT_DIR}/Windows/System32/config/SYSTEM"

if [[ -f "$SOFTWARE_HIVE" ]]; then
    if export_reg "$SOFTWARE_HIVE" 'HKEY_LOCAL_MACHINE\SOFTWARE' \
        'Microsoft\Windows NT\CurrentVersion' "${VERIFY_DIR}/currentversion.reg"; then
        if tr -d '\r' < "${VERIFY_DIR}/currentversion.reg" | grep -Fxq -- '"CurrentBuild"="19045"'; then
            pass "software-currentbuild" "SOFTWARE CurrentBuild is 19045"
        else
            fail "software-currentbuild" "SOFTWARE CurrentBuild is not 19045"
        fi
    else
        fail "software-currentbuild" "could not export the SOFTWARE CurrentVersion key"
    fi
else
    fail "software-currentbuild" "SOFTWARE hive is missing"
fi

if [[ -f "$SOFTWARE_HIVE" ]]; then
    if export_reg "$SOFTWARE_HIVE" 'HKEY_LOCAL_MACHINE\SOFTWARE' \
        'Microsoft\Windows NT\CurrentVersion\Winlogon' "${VERIFY_DIR}/winlogon.reg"; then
        expected_shell='"Shell"="cmd.exe /c \"C:\\Riot Games\\val-kiosk.bat\""'
        if grep -Fq -- "$expected_shell" "${VERIFY_DIR}/winlogon.reg"; then
            pass "winlogon-shell" "Winlogon Shell is the Valorant kiosk command"
        else
            fail "winlogon-shell" "Winlogon Shell is not the expected kiosk command"
        fi
    else
        fail "winlogon-shell" "could not export the Winlogon key"
    fi
else
    fail "winlogon-shell" "SOFTWARE hive is missing"
fi

CONTROL_SET=""
if [[ -f "$SYSTEM_HIVE" ]]; then
    if export_reg "$SYSTEM_HIVE" 'HKEY_LOCAL_MACHINE\SYSTEM' 'Select' "${VERIFY_DIR}/select.reg"; then
        current_hex="$(grep -m1 -oE '"Current"=dword:[0-9a-fA-F]+' "${VERIFY_DIR}/select.reg" | cut -d: -f2 || true)"
        if [[ -n "$current_hex" ]]; then
            CONTROL_SET="$(printf 'ControlSet%03d' "$((16#$current_hex))")"
        fi
    fi
fi
if [[ -z "$CONTROL_SET" ]]; then
    fail "system-control-set" "could not determine the active SYSTEM control set"
fi

if [[ -n "$CONTROL_SET" ]] && export_reg "$SYSTEM_HIVE" 'HKEY_LOCAL_MACHINE\SYSTEM' \
    "${CONTROL_SET}\\Control" "${VERIFY_DIR}/control.reg"; then
    if tr -d '\r' < "${VERIFY_DIR}/control.reg" | grep -Fxq -- '"PortableOperatingSystem"=dword:00000001'; then
        pass "system-portable-os" "SYSTEM PortableOperatingSystem is 1"
    else
        fail "system-portable-os" "SYSTEM PortableOperatingSystem is not 1"
    fi
else
    fail "system-portable-os" "could not export the SYSTEM Control key"
fi

# ---------------------------------------------------------------------------
# Security invariants must remain enabled
# ---------------------------------------------------------------------------
service_start() {
    local service="$1" out
    [[ -n "$CONTROL_SET" ]] || return 1
    out="${VERIFY_DIR}/service_${service}.reg"
    export_reg "$SYSTEM_HIVE" 'HKEY_LOCAL_MACHINE\SYSTEM' \
        "${CONTROL_SET}\\Services\\${service}" "$out" || return 1
    grep -m1 -oE '"Start"=dword:[0-9a-fA-F]+' "$out" | cut -d: -f2
}

for service in WinDefend SecurityHealthService TPM; do
    start_hex="$(service_start "$service" || true)"
    if [[ -z "$start_hex" ]]; then
        fail "invariant-service-${service}" "service key is missing from the offline SYSTEM hive"
    elif (( 16#$start_hex == 4 )); then
        fail "invariant-service-${service}" "service Start is 4 (disabled)"
    else
        pass "invariant-service-${service}" "service Start=${start_hex} (not disabled)"
    fi
done

defender_disabled=0
for defender_key in 'Policies\Microsoft\Windows Defender' 'Microsoft\Windows Defender'; do
    out="${VERIFY_DIR}/defender_$(printf '%s' "$defender_key" | tr '\\ ' '__').reg"
    if [[ -f "$SOFTWARE_HIVE" ]] && export_reg "$SOFTWARE_HIVE" \
        'HKEY_LOCAL_MACHINE\SOFTWARE' "$defender_key" "$out"; then
        if grep -Eiq '"DisableAntiSpyware"=dword:0*1' "$out"; then
            defender_disabled=1
        fi
    fi
done
if (( defender_disabled )); then
    fail "invariant-defender-policy" "DisableAntiSpyware is enabled"
else
    pass "invariant-defender-policy" "no Defender-disabling policy is present"
fi

for path in Windows/System32/ci.dll Windows/System32/drivers/tpm.sys; do
    if [[ -f "${MOUNT_DIR}/${path}" ]]; then
        pass "invariant-file-$(basename "$path")" "present: /$path"
    else
        fail "invariant-file-$(basename "$path")" "missing: /$path"
    fi
done

if [[ "$OVMF_CODE" == *secboot* ]] && printf '%s\n' "${QEMU_ARGS[@]}" | grep -Fq -- "q35,smm=on"; then
    pass "invariant-secureboot-firmware" "secboot OVMF 4m launched with SMM"
else
    fail "invariant-secureboot-firmware" "gate did not launch secboot OVMF with SMM"
fi

# ---------------------------------------------------------------------------
# Summary
# ---------------------------------------------------------------------------
if (( RO_MOUNTED )); then
    sync
    umount -- "$MOUNT_DIR" || die "Failed to unmount the read-only verification mount"
    RO_MOUNTED=0
fi
partx -d -- "$LOOP_DEV" >/dev/null 2>&1 || true
losetup -d "$LOOP_DEV" || die "Failed to detach the verification loop device"
LOOP_DEV=""

if (( KEEP_IMAGE )); then
    log "Kept test image: $IMAGE"
    log "QEMU log:        $QEMU_LOG"
    log "Screenshots:     $SCREENS_DIR"
    log "Verification:    $VERIFY_DIR"
fi

summary
