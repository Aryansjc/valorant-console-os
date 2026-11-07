#!/usr/bin/env bash
# Phase 2: normalize Windows payloads to CRLF and inject them into the WIM.
#
# The script writes only to PROJECT_ROOT/build and updates the already-built
# custom_install.wim.  It never touches a host block device.

set -Eeuo pipefail
IFS=$'\n\t'

PROJECT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
readonly PROJECT_ROOT

readonly WORKDIR="${PROJECT_ROOT}/build"
readonly PAYLOAD_DIR="${PROJECT_ROOT}/payloads"
readonly WIM="${WORKDIR}/custom_install.wim"
readonly LOG_DIR="${WORKDIR}/logs"
readonly LOG="${LOG_DIR}/phase02_inject.log"
readonly CMDFILE="${WORKDIR}/wim_inject_commands.txt"
readonly EFI_STAGED="${WORKDIR}/efi_staged"

mkdir -p "$LOG_DIR"
: > "$LOG"
exec > >(tee -a "$LOG") 2>&1

log() { printf '[phase02] %s\n' "$*"; }
die() { printf '[FAIL] %s\n' "$*" >&2; exit 1; }

trap 'rc=$?; if (( rc != 0 )); then printf "[FAIL] phase02 injection aborted unexpectedly at line %s (exit %s)\n" "$LINENO" "$rc" >&2; fi' ERR

case "$WORKDIR" in
    "${PROJECT_ROOT}/build") ;;
    *) die "Refusing to operate: WORKDIR is not below PROJECT_ROOT/build" ;;
esac

command -v wimlib-imagex >/dev/null 2>&1 || die "wimlib-imagex is required"
command -v unix2dos >/dev/null 2>&1 || die "unix2dos is required"
command -v python3 >/dev/null 2>&1 || die "python3 is required"
command -v xmllint >/dev/null 2>&1 || die "xmllint is required"

[[ -f "$WIM" ]] || die "Missing Phase 1 WIM: $WIM"
[[ -f "$EFI_STAGED/bootmgfw.efi" ]] || die "Missing staged EFI boot manager: $EFI_STAGED/bootmgfw.efi"
wimlib-imagex info "$WIM" >/dev/null 2>&1 || die "Cannot read WIM: $WIM"

REQUIRED_PAYLOADS=(
    "$PAYLOAD_DIR/autounattend.xml"
    "$PAYLOAD_DIR/sd_survival_and_kiosk.cmd"
    "$PAYLOAD_DIR/val-kiosk.bat"
    "$PAYLOAD_DIR/switch-mode.bat"
    "$PAYLOAD_DIR/windows10.0-kb5015684-x64.cab"
)
for payload in "${REQUIRED_PAYLOADS[@]}"; do
    [[ -f "$payload" ]] || die "Missing payload: $payload"
done

xmllint --noout "$PAYLOAD_DIR/autounattend.xml" || die "autounattend.xml is not well-formed XML"

# ---------------------------------------------------------------------------
# Normalize every batch/cmd payload to CRLF before it enters the WIM.
# ---------------------------------------------------------------------------
mapfile -d '' BATCH_FILES < <(
    find "$PAYLOAD_DIR" -maxdepth 1 -type f \
        \( -iname '*.bat' -o -iname '*.cmd' \) -print0 | sort -z
)
(( ${#BATCH_FILES[@]} > 0 )) || die "No .bat/.cmd payloads found in $PAYLOAD_DIR"

for file in "${BATCH_FILES[@]}"; do
    log "Converting to CRLF: ${file#"$PROJECT_ROOT"/}"
    unix2dos "$file" >/dev/null
    if ! python3 - "$file" <<'PY'
import sys
data = open(sys.argv[1], "rb").read()
if not data or b"\r\n" not in data:
    raise SystemExit(1)
remainder = data.replace(b"\r\n", b"")
if b"\n" in remainder or b"\r" in remainder:
    raise SystemExit(1)
PY
    then
        die "CRLF normalization failed for $file"
    fi
done

# ---------------------------------------------------------------------------
# Build the wimlib update command file and inject the five payloads.
# ---------------------------------------------------------------------------
: > "$CMDFILE"
inject_one() {
    local src="$1" dst="$2"
    printf 'add "%s" "%s"\n' "$src" "$dst" >> "$CMDFILE"
}

inject_one "$PAYLOAD_DIR/autounattend.xml" \
    '/Windows/Panther/unattend.xml'
inject_one "$PAYLOAD_DIR/sd_survival_and_kiosk.cmd" \
    '/Riot Games/sd_survival_and_kiosk.cmd'
inject_one "$PAYLOAD_DIR/val-kiosk.bat" \
    '/Riot Games/val-kiosk.bat'
inject_one "$PAYLOAD_DIR/switch-mode.bat" \
    '/Riot Games/switch-mode.bat'
inject_one "$PAYLOAD_DIR/windows10.0-kb5015684-x64.cab" \
    '/Riot Games/windows10.0-kb5015684-x64.cab'

log "Injecting payloads into image 1 of $WIM"
if ! wimlib-imagex update "$WIM" 1 < "$CMDFILE" \
    > "${LOG_DIR}/phase02_wim_update.log" 2>&1
then
    tail -n 80 "${LOG_DIR}/phase02_wim_update.log" >&2 || true
    die "wimlib-imagex update failed"
fi

DESTINATIONS=(
    '/Windows/Panther/unattend.xml'
    '/Riot Games/sd_survival_and_kiosk.cmd'
    '/Riot Games/val-kiosk.bat'
    '/Riot Games/switch-mode.bat'
    '/Riot Games/windows10.0-kb5015684-x64.cab'
)
for dst in "${DESTINATIONS[@]}"; do
    if ! wimlib-imagex dir "$WIM" 1 --path="$dst" >/dev/null 2>&1; then
        die "Injection verification failed; missing in WIM: $dst"
    fi
    log "Verified in WIM: $dst"
done

log "Phase 2 payload injection complete"
log "Injection log: ${LOG_DIR}/phase02_wim_update.log"
