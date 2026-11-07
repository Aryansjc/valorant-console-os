#!/usr/bin/env bash
# Phase 1: Tiny10 extraction, offline WIM minimalism, and Vanguard compatibility audit.
#
# This script is intentionally conservative:
#   - It only writes inside "$PROJECT_ROOT/build" and "$PROJECT_ROOT/payloads".
#   - It never touches a host block device.
#   - It resolves the source ISO by glob, because the filename contains spaces.
#
# Usage:
#   ./scripts/01_prepare_wim.sh          # resume any incomplete stage
#   ./scripts/01_prepare_wim.sh --force  # rebuild phase 1 artifacts from scratch

set -Eeuo pipefail
IFS=$'\n\t'

PROJECT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
readonly PROJECT_ROOT

readonly WORKDIR="${PROJECT_ROOT}/build"
readonly PAYLOAD_DIR="${PROJECT_ROOT}/payloads"
readonly ISO_EXTRACT="${WORKDIR}/iso_extracted"
readonly CUSTOM_WIM="${WORKDIR}/custom_install.wim"
readonly SLIM_LIST="${WORKDIR}/wim_slim.txt"
readonly REG_AUDIT="${WORKDIR}/reg_audit"
readonly EFI_STAGED="${WORKDIR}/efi_staged"
readonly LOG_DIR="${WORKDIR}/logs"
readonly MANIFEST="${WORKDIR}/phase01_manifest.env"
readonly CACHE_DIR="${WORKDIR}/cache"

readonly EXTRACT_MARKER="${WORKDIR}/.phase01_iso_extracted"
readonly EXPORT_MARKER="${WORKDIR}/.phase01_exported"
readonly SLIM_MARKER="${WORKDIR}/.phase01_slimmed"
readonly AUDIT_MARKER="${WORKDIR}/.phase01_audited"

readonly KB_MSU_URL='https://catalog.s.download.windowsupdate.com/c/upgr/2022/07/windows10.0-kb5015684-x64_523c039b86ca98f2d818c4e6706e2cc94b634c4a.msu'
# SHA-1 is embedded in Microsoft's official MSU filename.
readonly KB_MSU_SHA1='523c039b86ca98f2d818c4e6706e2cc94b634c4a'
# SHA-256 of Windows10.0-KB5015684-x64_PSFX.cab extracted from that MSU.
readonly KB_CAB_SHA256='930e469881c615c997f5c57bf19c2a292684192eea40fe88224ebe445181258b'
readonly KB_CAB="${PAYLOAD_DIR}/windows10.0-kb5015684-x64.cab"
readonly KB_MSU="${CACHE_DIR}/windows10.0-kb5015684-x64.msu"

readonly JOBS="$(nproc)"
FORCE=0

log() { printf '[phase01] %s\n' "$*"; }
die() { printf '[FAIL] %s\n' "$*" >&2; exit 1; }

trap 'rc=$?; printf "[FAIL] phase01 aborted unexpectedly at line %s (exit %s)\n" "$LINENO" "$rc" >&2' ERR

usage() {
    cat <<'EOF'
Usage: scripts/01_prepare_wim.sh [--force]

  --force   Remove phase 1 staging artifacts and rebuild them.
  -h, --help
            Show this help.
EOF
}

for arg in "$@"; do
    case "$arg" in
        --force) FORCE=1 ;;
        -h|--help) usage; exit 0 ;;
        *) die "Unknown argument: $arg" ;;
    esac
done

# This script must never remove anything outside the repository's build tree.
case "$WORKDIR" in
    "${PROJECT_ROOT}/build") ;;
    *) die "Refusing to operate: WORKDIR is not below PROJECT_ROOT/build" ;;
esac

mkdir -p "$WORKDIR" "$PAYLOAD_DIR" "$LOG_DIR" "$CACHE_DIR" "$REG_AUDIT" "$EFI_STAGED"
: > "${LOG_DIR}/phase01_prepare.log"
exec > >(tee -a "${LOG_DIR}/phase01_prepare.log") 2>&1

if (( FORCE )); then
    log "Force mode: clearing only phase 1 output artifacts"
    rm -rf -- "$ISO_EXTRACT" "$REG_AUDIT" "$EFI_STAGED" "${CACHE_DIR}/kb5015684_extracted"
    rm -f -- "$CUSTOM_WIM" "${CUSTOM_WIM}.tmp" "$SLIM_LIST" "$MANIFEST" \
        "$EXTRACT_MARKER" "$EXPORT_MARKER" "$SLIM_MARKER" "$AUDIT_MARKER" \
        "${LOG_DIR}/wim_info_before_slim.txt" "${LOG_DIR}/wim_info_after_slim.txt" \
        "${LOG_DIR}/wim_info_after_optimize.txt" "${LOG_DIR}/wim_info_after_export.txt" \
        "${LOG_DIR}/wim_file_bytes_after_export.txt" "${LOG_DIR}/wim_file_bytes_after_optimize.txt"
    rm -f -- "$KB_CAB" "$KB_MSU" "${KB_MSU}.tmp"
    mkdir -p "$REG_AUDIT" "$EFI_STAGED"
fi

log "Project root: $PROJECT_ROOT"
log "Work directory: $WORKDIR"

# ---------------------------------------------------------------------------
# 1. Required host tools
# ---------------------------------------------------------------------------
declare -A TOOL_PACKAGE=(
    [wimlib-imagex]='wimlib'
    [7z]='7zip'
    [chntpw]='chntpw'
    [reged]='chntpw'
    [parted]='parted'
    [mkfs.fat]='dosfstools'
    [mkfs.ntfs]='ntfs-3g'
    [ntfs-3g]='ntfs-3g'
    [qemu-system-x86_64]='qemu-system-x86'
    [swtpm]='swtpm'
    [xmllint]='libxml2'
    [unix2dos]='dos2unix'
    [zstd]='zstd'
    [python3]='python'
    [curl]='curl'
)

REQUIRED_BINS=(
    wimlib-imagex 7z chntpw reged parted mkfs.fat mkfs.ntfs ntfs-3g
    qemu-system-x86_64 swtpm xmllint unix2dos zstd python3 curl
)

MISSING_PKGS=()
for bin in "${REQUIRED_BINS[@]}"; do
    if ! command -v "$bin" >/dev/null 2>&1; then
        printf '[FAIL] required binary missing: %s\n' "$bin"
        MISSING_PKGS+=("${TOOL_PACKAGE[$bin]}")
    else
        printf '[ OK ] %s -> %s\n' "$bin" "$(command -v "$bin")"
    fi
done

OVMF_CODE=''
for candidate in \
    /usr/share/edk2/x64/OVMF_CODE.secboot.4m.fd \
    /usr/share/edk2/x64/OVMF_CODE.secboot.fd
do
    if [[ -f "$candidate" ]]; then
        OVMF_CODE="$candidate"
        break
    fi
done

if [[ -z "$OVMF_CODE" ]]; then
    printf '[FAIL] OVMF Secure Boot firmware not found\n'
    MISSING_PKGS+=('edk2-ovmf')
else
    printf '[ OK ] OVMF Secure Boot firmware -> %s\n' "$OVMF_CODE"
fi

if (( ${#MISSING_PKGS[@]} > 0 )); then
    mapfile -t UNIQUE_PKGS < <(printf '%s\n' "${MISSING_PKGS[@]}" | sort -u)
    printf '\nInstall missing host packages with:\n'
    printf '  sudo pacman -S --needed %s\n' "${UNIQUE_PKGS[*]}"
    exit 1
fi

# ---------------------------------------------------------------------------
# 2. Locate the source ISO dynamically
# ---------------------------------------------------------------------------
mapfile -d '' ISO_CANDIDATES < <(
    find "$PROJECT_ROOT" -maxdepth 1 -type f -iname '*.iso' -print0 | sort -z
)

if (( ${#ISO_CANDIDATES[@]} == 0 )); then
    die "No *.iso found in $PROJECT_ROOT"
fi
if (( ${#ISO_CANDIDATES[@]} > 1 )); then
    printf '[FAIL] Multiple ISO candidates found; refusing to guess:\n' >&2
    printf '  %s\n' "${ISO_CANDIDATES[@]}" >&2
    exit 1
fi

readonly ISO_PATH="${ISO_CANDIDATES[0]}"
[[ -r "$ISO_PATH" ]] || die "ISO is not readable: $ISO_PATH"
ISO_BYTES="$(stat -c '%s' -- "$ISO_PATH")"
log "Source ISO: $ISO_PATH (${ISO_BYTES} bytes)"

# ---------------------------------------------------------------------------
# 3. Extract only the ISO members needed for offline servicing
# ---------------------------------------------------------------------------
if [[ ! -f "$EXTRACT_MARKER" ]]; then
    log "Extracting sources/install.*, efi/, boot/, bootmgr* from the ISO"
    rm -rf -- "$ISO_EXTRACT"
    mkdir -p "$ISO_EXTRACT"
    if ! 7z x -y -o"$ISO_EXTRACT" "$ISO_PATH" \
        'sources/install.*' 'efi/*' 'boot/*' 'bootmgr*' \
        > "${LOG_DIR}/7z_iso_extract.log" 2>&1
    then
        tail -n 40 "${LOG_DIR}/7z_iso_extract.log" >&2 || true
        die "7z failed to extract the ISO payload"
    fi
    touch "$EXTRACT_MARKER"
else
    log "ISO extraction already complete; skipping"
fi

mapfile -d '' INSTALL_FILES < <(
    find "$ISO_EXTRACT/sources" -maxdepth 1 -type f -iname 'install.*' -print0 | sort -z
)
if (( ${#INSTALL_FILES[@]} != 1 )); then
    die "Expected exactly one sources/install.* file, found ${#INSTALL_FILES[@]}"
fi
readonly INSTALL_IMAGE="${INSTALL_FILES[0]}"
[[ -d "$ISO_EXTRACT/efi" ]] || die "ISO extraction is missing efi/"
[[ -d "$ISO_EXTRACT/boot" ]] || die "ISO extraction is missing boot/"
compgen -G "$ISO_EXTRACT/bootmgr*" >/dev/null || die "ISO extraction is missing bootmgr*"
log "Install image: $INSTALL_IMAGE"

# ---------------------------------------------------------------------------
# 4. Export image index 1 as a non-solid LZX WIM
# ---------------------------------------------------------------------------
if [[ ! -f "$EXPORT_MARKER" ]]; then
    log "Exporting image 1 to LZX (this can take several minutes)"
    rm -f -- "$CUSTOM_WIM" "${CUSTOM_WIM}.tmp"
    if ! wimlib-imagex export "$INSTALL_IMAGE" 1 "${CUSTOM_WIM}.tmp" \
        --compress=LZX --threads="$JOBS" \
        > "${LOG_DIR}/wim_export.log" 2>&1
    then
        tail -n 60 "${LOG_DIR}/wim_export.log" >&2 || true
        die "wimlib-imagex export failed"
    fi
    if ! wimlib-imagex verify "${CUSTOM_WIM}.tmp" \
        > "${LOG_DIR}/wim_verify_after_export.log" 2>&1
    then
        tail -n 40 "${LOG_DIR}/wim_verify_after_export.log" >&2 || true
        die "Exported WIM failed verification"
    fi
    mv -f -- "${CUSTOM_WIM}.tmp" "$CUSTOM_WIM"
    touch "$EXPORT_MARKER"
else
    [[ -f "$CUSTOM_WIM" ]] || die "Export marker exists but $CUSTOM_WIM is missing; rerun with --force"
    log "WIM export already complete; skipping"
fi

if [[ ! -f "${LOG_DIR}/wim_info_before_slim.txt" ]]; then
    wimlib-imagex info "$CUSTOM_WIM" 1 > "${LOG_DIR}/wim_info_before_slim.txt"
fi
if [[ ! -f "${LOG_DIR}/wim_file_bytes_after_export.txt" ]]; then
    stat -c '%s' -- "$CUSTOM_WIM" > "${LOG_DIR}/wim_file_bytes_after_export.txt"
fi

# ---------------------------------------------------------------------------
# 5. Aggressive, Vanguard-safe offline WIM minimalism
# ---------------------------------------------------------------------------
PROTECTED_PATHS=(
    '/Program Files/Windows Defender'
    '/Program Files/Windows Defender/MsMpEng.exe'
    '/Windows/System32/drivers/tpm.sys'
    '/Windows/System32/drivers/WdFilter.sys'
    '/Windows/System32/ci.dll'
)

if [[ ! -f "$SLIM_MARKER" ]]; then
    log "Writing WIM deletion list to $SLIM_LIST"
    cat > "$SLIM_LIST" <<'EOF'
# Phase 1 bloat removal. Paths are quoted because WIM paths contain spaces.
# These deletions must never include Defender, TPM, code integrity, or Secure Boot.
delete --force --recursive "/Windows/System32/Recovery"
delete --force --recursive "/Program Files/Windows Media Player"
delete --force --recursive "/Program Files (x86)/Windows Media Player"
delete --force --recursive "/Program Files/Internet Explorer"
delete --force --recursive "/Program Files (x86)/Internet Explorer"
delete --force --recursive "/Program Files/Windows NT/Accessories"
delete --force --recursive "/Windows/Web/Wallpaper"
delete --force --recursive "/Windows/Web/4K"
delete --force --recursive "/Windows/Help"
delete --force --recursive "/Windows/Media"
delete --force "/Windows/System32/OneDriveSetup.exe"
delete --force "/Windows/SysWOW64/OneDriveSetup.exe"
EOF

    for path in "${PROTECTED_PATHS[@]}"; do
        if ! wimlib-imagex dir "$CUSTOM_WIM" 1 --path="$path" >/dev/null 2>&1; then
            die "Protected path missing before slim: $path"
        fi
    done

    log "Applying offline WIM deletions"
    if ! wimlib-imagex update "$CUSTOM_WIM" 1 < "$SLIM_LIST" \
        > "${LOG_DIR}/wim_update.log" 2>&1
    then
        tail -n 80 "${LOG_DIR}/wim_update.log" >&2 || true
        die "wimlib-imagex update failed"
    fi

    for path in "${PROTECTED_PATHS[@]}"; do
        if ! wimlib-imagex dir "$CUSTOM_WIM" 1 --path="$path" >/dev/null 2>&1; then
            die "Protected path missing after slim: $path"
        fi
    done

    wimlib-imagex info "$CUSTOM_WIM" 1 > "${LOG_DIR}/wim_info_after_slim.txt"

    log "Optimizing WIM to reclaim deleted data"
    if ! wimlib-imagex optimize "$CUSTOM_WIM" \
        > "${LOG_DIR}/wim_optimize.log" 2>&1
    then
        tail -n 60 "${LOG_DIR}/wim_optimize.log" >&2 || true
        die "wimlib-imagex optimize failed"
    fi

    wimlib-imagex info "$CUSTOM_WIM" 1 > "${LOG_DIR}/wim_info_after_optimize.txt"
    stat -c '%s' -- "$CUSTOM_WIM" > "${LOG_DIR}/wim_file_bytes_after_optimize.txt"

    if ! wimlib-imagex verify "$CUSTOM_WIM" \
        > "${LOG_DIR}/wim_verify_after_optimize.log" 2>&1
    then
        tail -n 40 "${LOG_DIR}/wim_verify_after_optimize.log" >&2 || true
        die "Slimmed/optimized WIM failed verification"
    fi
    touch "$SLIM_MARKER"
else
    log "WIM minimalism/optimization already complete; skipping"
fi

[[ -f "${LOG_DIR}/wim_info_after_slim.txt" ]] || \
    wimlib-imagex info "$CUSTOM_WIM" 1 > "${LOG_DIR}/wim_info_after_slim.txt"
[[ -f "${LOG_DIR}/wim_info_after_optimize.txt" ]] || \
    wimlib-imagex info "$CUSTOM_WIM" 1 > "${LOG_DIR}/wim_info_after_optimize.txt"
[[ -f "${LOG_DIR}/wim_file_bytes_after_optimize.txt" ]] || \
    stat -c '%s' -- "$CUSTOM_WIM" > "${LOG_DIR}/wim_file_bytes_after_optimize.txt"

# ---------------------------------------------------------------------------
# 6. Stage registry hives and in-WIM EFI boot manager
# ---------------------------------------------------------------------------
if [[ ! -f "$AUDIT_MARKER" ]]; then
    log "Extracting SOFTWARE/SYSTEM hives and Windows/Boot/EFI"
    rm -rf -- "$REG_AUDIT" "$EFI_STAGED"
    mkdir -p "$REG_AUDIT" "$EFI_STAGED"

    if ! wimlib-imagex extract "$CUSTOM_WIM" 1 \
        '/Windows/System32/config/SOFTWARE' \
        '/Windows/System32/config/SYSTEM' \
        --dest-dir="$REG_AUDIT" \
        > "${LOG_DIR}/wim_extract_hives.log" 2>&1
    then
        tail -n 40 "${LOG_DIR}/wim_extract_hives.log" >&2 || true
        die "Failed to extract registry hives"
    fi

    if ! wimlib-imagex extract "$CUSTOM_WIM" 1 \
        '/Windows/Boot/EFI/*' \
        --dest-dir="$EFI_STAGED" \
        > "${LOG_DIR}/wim_extract_efi.log" 2>&1
    then
        tail -n 40 "${LOG_DIR}/wim_extract_efi.log" >&2 || true
        die "Failed to extract /Windows/Boot/EFI"
    fi

    [[ -f "$REG_AUDIT/SOFTWARE" ]] || die "Missing extracted SOFTWARE hive"
    [[ -f "$REG_AUDIT/SYSTEM" ]] || die "Missing extracted SYSTEM hive"

    if [[ ! -f "$EFI_STAGED/bootmgfw.efi" ]]; then
        BOOTMGFW_FOUND="$(find "$EFI_STAGED" -type f -iname 'bootmgfw.efi' -print -quit)"
        [[ -n "$BOOTMGFW_FOUND" ]] || die "bootmgfw.efi is missing from /Windows/Boot/EFI"
        cp -f -- "$BOOTMGFW_FOUND" "$EFI_STAGED/bootmgfw.efi"
    fi

    touch "$AUDIT_MARKER"
else
    log "Registry/EFI audit staging already complete; skipping"
fi

[[ -f "$REG_AUDIT/SOFTWARE" ]] || die "Missing $REG_AUDIT/SOFTWARE"
[[ -f "$REG_AUDIT/SYSTEM" ]] || die "Missing $REG_AUDIT/SYSTEM"
[[ -f "$EFI_STAGED/bootmgfw.efi" ]] || die "Missing $EFI_STAGED/bootmgfw.efi"

# ---------------------------------------------------------------------------
# 7. Read CurrentBuild and obtain the 22H2 enablement package
# ---------------------------------------------------------------------------
read_hive_value() {
    local hive="$1" key="$2" value="$3"
    printf 'cd %s\ncat %s\nq\n' "$key" "$value" \
        | chntpw -e "$hive" 2>/dev/null \
        | awk -v marker="Value <$value>" '
            index($0, marker) {
                if (getline > 0) {
                    gsub(/\r/, "")
                    gsub(/^[[:space:]]+|[[:space:]]+$/, "")
                    print
                    exit
                }
            }'
}

CURRENT_BUILD="$(read_hive_value "$REG_AUDIT/SOFTWARE" \
    'Microsoft\Windows NT\CurrentVersion' 'CurrentBuild')"
DISPLAY_VERSION="$(read_hive_value "$REG_AUDIT/SOFTWARE" \
    'Microsoft\Windows NT\CurrentVersion' 'DisplayVersion')"
PRODUCT_NAME="$(read_hive_value "$REG_AUDIT/SOFTWARE" \
    'Microsoft\Windows NT\CurrentVersion' 'ProductName')"

[[ "$CURRENT_BUILD" =~ ^[0-9]+$ ]] || die "Could not read CurrentBuild from SOFTWARE hive"
log "CurrentBuild=${CURRENT_BUILD} DisplayVersion=${DISPLAY_VERSION:-unknown}"
log "ProductName=${PRODUCT_NAME:-unknown}"

case "$CURRENT_BUILD" in
    19044)
        log "LTSC 2021 baseline detected; KB5015684 is required for 22H2"
        ;;
    19045)
        log "Image already reports 19045; KB5015684 payload will still be verified"
        ;;
    *)
        die "Unexpected base build $CURRENT_BUILD; expected 19044 or 19045"
        ;;
esac

verify_kb_cab() {
    local cab="$1"
    [[ -f "$cab" ]] || return 1
    [[ "$(sha256sum -- "$cab" | awk '{print $1}')" == "$KB_CAB_SHA256" ]] || return 1
    7z t "$cab" >/dev/null 2>&1 || return 1
    7z l "$cab" 2>/dev/null | grep -qi 'microsoft-windows-22h2enablement-package.*\.mum' || return 1
    return 0
}

ensure_kb_payload() {
    if verify_kb_cab "$KB_CAB"; then
        log "KB5015684 payload already present and valid; skipping download"
        return 0
    fi
    rm -f -- "$KB_CAB"

    mkdir -p "$CACHE_DIR"
    local need_download=0
    if [[ ! -f "$KB_MSU" ]]; then
        need_download=1
    elif [[ "$(sha1sum -- "$KB_MSU" | awk '{print $1}')" != "$KB_MSU_SHA1" ]]; then
        log "Cached MSU checksum mismatch; downloading a fresh copy"
        rm -f -- "$KB_MSU"
        need_download=1
    fi

    if (( need_download )); then
        log "Downloading official KB5015684 x64 MSU"
        rm -f -- "${KB_MSU}.tmp"
        if ! curl --fail --location --retry 3 --connect-timeout 30 \
            --output "${KB_MSU}.tmp" "$KB_MSU_URL"
        then
            die "Failed to download KB5015684 MSU"
        fi
        if [[ "$(sha1sum -- "${KB_MSU}.tmp" | awk '{print $1}')" != "$KB_MSU_SHA1" ]]; then
            die "Downloaded MSU failed the official SHA-1 check"
        fi
        mv -f -- "${KB_MSU}.tmp" "$KB_MSU"
    fi

    if ! 7z t "$KB_MSU" >/dev/null 2>&1; then
        die "KB5015684 MSU failed archive integrity testing"
    fi

    local extracted="${CACHE_DIR}/kb5015684_extracted"
    rm -rf -- "$extracted"
    mkdir -p "$extracted"
    if ! 7z x -y -o"$extracted" "$KB_MSU" \
        'Windows10.0-KB5015684-x64_PSFX.cab' \
        > "${LOG_DIR}/kb_extract.log" 2>&1
    then
        tail -n 40 "${LOG_DIR}/kb_extract.log" >&2 || true
        die "Failed to extract the enablement CAB from the MSU"
    fi

    local cab="${extracted}/Windows10.0-KB5015684-x64_PSFX.cab"
    [[ -f "$cab" ]] || die "The MSU did not contain the expected PSFX CAB"
    if [[ "$(sha256sum -- "$cab" | awk '{print $1}')" != "$KB_CAB_SHA256" ]]; then
        die "Extracted enablement CAB failed the pinned SHA-256 check"
    fi
    if ! 7z t "$cab" >/dev/null 2>&1; then
        die "Extracted enablement CAB failed archive integrity testing"
    fi
    if ! 7z l "$cab" 2>/dev/null | grep -qi 'microsoft-windows-22h2enablement-package.*\.mum'; then
        die "Extracted CAB does not contain the 22H2 enablement package manifest"
    fi

    cp -f -- "$cab" "${KB_CAB}.tmp"
    mv -f -- "${KB_CAB}.tmp" "$KB_CAB"
    verify_kb_cab "$KB_CAB" || die "Stored KB5015684 payload failed final validation"
    log "Staged KB5015684 payload: $KB_CAB"
}

ensure_kb_payload

# ---------------------------------------------------------------------------
# 8. Record phase metadata and savings
# ---------------------------------------------------------------------------
total_bytes_from_info() {
    awk -F': *' '$1 == "Total Bytes" { gsub(/[[:space:]]/, "", $2); print $2; exit }' "$1"
}

BEFORE_TOTAL="$(total_bytes_from_info "${LOG_DIR}/wim_info_before_slim.txt")"
AFTER_SLIM_TOTAL="$(total_bytes_from_info "${LOG_DIR}/wim_info_after_slim.txt")"
AFTER_OPT_TOTAL="$(total_bytes_from_info "${LOG_DIR}/wim_info_after_optimize.txt")"

[[ "$BEFORE_TOTAL" =~ ^[0-9]+$ ]] || die "Could not read pre-slim WIM Total Bytes"
[[ "$AFTER_SLIM_TOTAL" =~ ^[0-9]+$ ]] || die "Could not read post-slim WIM Total Bytes"
[[ "$AFTER_OPT_TOTAL" =~ ^[0-9]+$ ]] || die "Could not read optimized WIM Total Bytes"

SAVED_MIB=$(( (BEFORE_TOTAL - AFTER_OPT_TOTAL) / 1048576 ))
KB_CAB_ACTUAL_SHA256="$(sha256sum -- "$KB_CAB" | awk '{print $1}')"
KB_CAB_BYTES="$(stat -c '%s' -- "$KB_CAB")"
WIM_FILE_BYTES_AFTER_EXPORT="$(cat "${LOG_DIR}/wim_file_bytes_after_export.txt")"
WIM_FILE_BYTES_AFTER_OPTIMIZE="$(cat "${LOG_DIR}/wim_file_bytes_after_optimize.txt")"

{
    printf 'PHASE=01\n'
    printf 'GENERATED_AT=%q\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
    printf 'SOURCE_ISO=%q\n' "$ISO_PATH"
    printf 'ISO_BYTES=%s\n' "$ISO_BYTES"
    printf 'INSTALL_IMAGE=%q\n' "$INSTALL_IMAGE"
    printf 'CURRENT_BUILD=%s\n' "$CURRENT_BUILD"
    printf 'DISPLAY_VERSION=%q\n' "$DISPLAY_VERSION"
    printf 'PRODUCT_NAME=%q\n' "$PRODUCT_NAME"
    printf 'OVMF_CODE=%q\n' "$OVMF_CODE"
    printf 'WIM_TOTAL_BYTES_BEFORE_SLIM=%s\n' "$BEFORE_TOTAL"
    printf 'WIM_TOTAL_BYTES_AFTER_SLIM=%s\n' "$AFTER_SLIM_TOTAL"
    printf 'WIM_TOTAL_BYTES_AFTER_OPTIMIZE=%s\n' "$AFTER_OPT_TOTAL"
    printf 'WIM_FILE_BYTES_AFTER_EXPORT=%s\n' "$WIM_FILE_BYTES_AFTER_EXPORT"
    printf 'WIM_FILE_BYTES_AFTER_OPTIMIZE=%s\n' "$WIM_FILE_BYTES_AFTER_OPTIMIZE"
    printf 'WIM_MIB_SAVED=%s\n' "$SAVED_MIB"
    printf 'KB_CAB_PATH=%q\n' "$KB_CAB"
    printf 'KB_CAB_SHA256=%s\n' "$KB_CAB_ACTUAL_SHA256"
    printf 'KB_CAB_BYTES=%s\n' "$KB_CAB_BYTES"
    printf 'KB_MSU_SHA1=%s\n' "$KB_MSU_SHA1"
} > "$MANIFEST"

log "CurrentBuild=$CURRENT_BUILD; WIM payload MiB saved=$SAVED_MIB"
log "KB5015684 payload: $KB_CAB (${KB_CAB_BYTES} bytes, sha256=$KB_CAB_ACTUAL_SHA256)"
log "Manifest: $MANIFEST"
log "Phase 1 preparation complete"
