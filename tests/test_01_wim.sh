#!/usr/bin/env bash
# Phase 1 verification gate for the custom WIM.
#
# Every requirement is reported as [PASS] or [FAIL].  The script exits non-zero
# if any check fails.  It only reads files below PROJECT_ROOT; it never touches
# a block device.

set -Eeuo pipefail
IFS=$'\n\t'

PROJECT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
readonly PROJECT_ROOT

readonly WIM="${PROJECT_ROOT}/build/custom_install.wim"
readonly REG_AUDIT="${PROJECT_ROOT}/build/reg_audit"
readonly EFI_STAGED="${PROJECT_ROOT}/build/efi_staged"
readonly MANIFEST="${PROJECT_ROOT}/build/phase01_manifest.env"
readonly KB_CAB="${PROJECT_ROOT}/payloads/windows10.0-kb5015684-x64.cab"
readonly KB_CAB_SHA256='930e469881c615c997f5c57bf19c2a292684192eea40fe88224ebe445181258b'
readonly LOG_DIR="${PROJECT_ROOT}/build/logs"
readonly LOG="${LOG_DIR}/test_01_wim.log"
readonly LISTING="${LOG_DIR}/wim_listing_phase01.txt"

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

trap 'rc=$?; if (( rc != 0 )); then printf "[FAIL] phase01 test harness aborted unexpectedly (exit %s) at line %s\n" "$rc" "$LINENO" >&2; fi' ERR

manifest_value() {
    local key="$1"
    [[ -f "$MANIFEST" ]] || return 1
    awk -v k="$key" 'index($0, k "=") == 1 { print substr($0, length(k) + 2); exit }' "$MANIFEST"
}

# ---------------------------------------------------------------------------
# Basic WIM integrity and enumeration
# ---------------------------------------------------------------------------
if [[ -f "$WIM" ]]; then
    pass "wim-exists" "$WIM"
else
    fail "wim-exists" "missing $WIM"
fi

verify_out=''
if [[ -f "$WIM" ]] && verify_out="$(wimlib-imagex verify "$WIM" 2>&1)"; then
    pass "wim-verify" "wimlib-imagex verify succeeded"
else
    fail "wim-verify" "verification failed: $(printf '%s' "${verify_out:-WIM missing}" | tr '\n' ' ')"
fi

if [[ -f "$WIM" ]] && wimlib-imagex dir "$WIM" 1 > "$LISTING" 2>"${LISTING}.err"; then
    pass "wim-listing" "enumerated $(wc -l < "$LISTING") WIM entries"
else
    fail "wim-listing" "could not enumerate the WIM"
    : > "$LISTING"
fi

check_absent_path() {
    local id="$1" path="$2" out
    if [[ ! -f "$WIM" ]]; then
        fail "$id" "WIM missing"
        return
    fi
    if out="$(wimlib-imagex dir "$WIM" 1 --path="$path" 2>&1)"; then
        fail "$id" "still present: $path"
    elif [[ "$out" == *"path does not exist"* ]]; then
        pass "$id" "absent: $path"
    else
        fail "$id" "unexpected wimlib error for $path: $(printf '%s' "$out" | tr '\n' ' ')"
    fi
}

check_present_path() {
    local id="$1" path="$2" out
    if [[ ! -f "$WIM" ]]; then
        fail "$id" "WIM missing"
        return
    fi
    if out="$(wimlib-imagex dir "$WIM" 1 --path="$path" 2>&1)"; then
        if grep -Fxq -- "$path" <<<"$out"; then
            pass "$id" "present: $path"
        else
            fail "$id" "path not found in WIM listing: $path"
        fi
    else
        fail "$id" "unexpected wimlib error for $path: $(printf '%s' "$out" | tr '\n' ' ')"
    fi
}

# ---------------------------------------------------------------------------
# Removed bloat
# ---------------------------------------------------------------------------
check_absent_path "no-winre-dir" "/Windows/System32/Recovery"
check_absent_path "no-wmp-x64" "/Program Files/Windows Media Player"
check_absent_path "no-wmp-x86" "/Program Files (x86)/Windows Media Player"
check_absent_path "no-ie-x64" "/Program Files/Internet Explorer"
check_absent_path "no-ie-x86" "/Program Files (x86)/Internet Explorer"

if grep -Eiq '(^|/)Winre\.wim$' "$LISTING"; then
    fail "no-winre-file" "Winre.wim is still present in the WIM"
else
    pass "no-winre-file" "Winre.wim is absent"
fi

# ---------------------------------------------------------------------------
# Vanguard-critical components
# ---------------------------------------------------------------------------
check_present_path "tpm-driver" "/Windows/System32/drivers/tpm.sys"
check_present_path "code-integrity" "/Windows/System32/ci.dll"
check_present_path "defender-filter" "/Windows/System32/drivers/WdFilter.sys"
check_present_path "defender-dir" "/Program Files/Windows Defender"
check_present_path "defender-engine" "/Program Files/Windows Defender/MsMpEng.exe"
check_present_path "security-health" "/Windows/System32/SecurityHealthService.exe"
check_present_path "bootmgfw-wim" "/Windows/Boot/EFI/bootmgfw.efi"

STAGED_BOOTMGFW=''
if [[ -d "$EFI_STAGED" ]]; then
    STAGED_BOOTMGFW="$(find "$EFI_STAGED" -type f -iname 'bootmgfw.efi' -print -quit 2>/dev/null || true)"
fi
if [[ -n "$STAGED_BOOTMGFW" ]]; then
    pass "bootmgfw-staged" "present at $STAGED_BOOTMGFW"
else
    fail "bootmgfw-staged" "bootmgfw.efi not found under $EFI_STAGED"
fi

# ---------------------------------------------------------------------------
# Base build audit
# ---------------------------------------------------------------------------
if [[ -f "$REG_AUDIT/SOFTWARE" ]]; then
    BUILD="$(printf 'cd Microsoft\\Windows NT\\CurrentVersion\ncat CurrentBuild\nq\n' \
        | chntpw -e "$REG_AUDIT/SOFTWARE" 2>/dev/null \
        | awk '/Value <CurrentBuild>/ { if (getline > 0) { gsub(/\r/, ""); gsub(/^[[:space:]]+|[[:space:]]+$/, ""); print; exit } }' || true)"
    if [[ "$BUILD" == "19044" || "$BUILD" == "19045" ]]; then
        pass "current-build" "CurrentBuild=$BUILD (LTSC 2021 baseline)"
    else
        fail "current-build" "unexpected CurrentBuild='${BUILD:-unreadable}' (expected 19044 or 19045)"
    fi
else
    fail "current-build" "missing $REG_AUDIT/SOFTWARE"
fi

# ---------------------------------------------------------------------------
# KB5015684 enablement payload
# ---------------------------------------------------------------------------
if [[ -f "$KB_CAB" ]]; then
    pass "kb-exists" "$KB_CAB"
else
    fail "kb-exists" "missing $KB_CAB"
fi

if [[ -f "$KB_CAB" ]]; then
    KB_ACTUAL_SHA256="$(sha256sum -- "$KB_CAB" | awk '{print $1}')"
    if [[ "$KB_ACTUAL_SHA256" == "$KB_CAB_SHA256" ]]; then
        pass "kb-sha256" "pinned Microsoft PSFX CAB SHA-256 matches"
    else
        fail "kb-sha256" "SHA-256 mismatch: $KB_ACTUAL_SHA256"
    fi
else
    fail "kb-sha256" "cannot hash a missing payload"
fi

if [[ -f "$KB_CAB" ]] && 7z t "$KB_CAB" >/dev/null 2>&1; then
    pass "kb-archive" "7z archive integrity test succeeded"
else
    fail "kb-archive" "enablement CAB is missing or corrupt"
fi

if [[ -f "$KB_CAB" ]] && 7z l "$KB_CAB" 2>/dev/null \
    | grep -qi 'microsoft-windows-22h2enablement-package.*\.mum'
then
    pass "kb-identity" "contains the Windows 10 22H2 enablement package manifest"
else
    fail "kb-identity" "CAB does not contain the expected 22H2 enablement package"
fi

# ---------------------------------------------------------------------------
# Reported savings
# ---------------------------------------------------------------------------
BEFORE_TOTAL="$(manifest_value WIM_TOTAL_BYTES_BEFORE_SLIM || true)"
AFTER_TOTAL="$(manifest_value WIM_TOTAL_BYTES_AFTER_OPTIMIZE || true)"
SAVED_MIB='unavailable'

if [[ "$BEFORE_TOTAL" =~ ^[0-9]+$ && "$AFTER_TOTAL" =~ ^[0-9]+$ ]]; then
    SAVED_MIB=$(( (BEFORE_TOTAL - AFTER_TOTAL) / 1048576 ))
    if (( SAVED_MIB >= 0 )); then
        pass "wim-savings" "payload reduced by ${SAVED_MIB} MiB (${BEFORE_TOTAL} -> ${AFTER_TOTAL} bytes)"
    else
        fail "wim-savings" "WIM payload grew by ${SAVED_MIB#-} MiB"
    fi
else
    fail "wim-savings" "missing WIM size metadata in $MANIFEST"
fi

FILE_BEFORE="$(manifest_value WIM_FILE_BYTES_AFTER_EXPORT || true)"
FILE_AFTER="$(manifest_value WIM_FILE_BYTES_AFTER_OPTIMIZE || true)"
FILE_SAVED_MIB='unavailable'
if [[ "$FILE_BEFORE" =~ ^[0-9]+$ && "$FILE_AFTER" =~ ^[0-9]+$ ]]; then
    FILE_SAVED_MIB=$(( (FILE_BEFORE - FILE_AFTER) / 1048576 ))
fi

printf '\n'
printf 'Total MiB saved (uncompressed WIM payload): %s MiB\n' "$SAVED_MIB"
printf 'Total MiB saved (on-disk WIM after optimize): %s MiB\n' "$FILE_SAVED_MIB"
printf 'Passed: %d  Failed: %d\n' "$PASS" "$FAIL"

if (( FAIL > 0 )); then
    printf '[FAIL] Phase 1 verification gate failed: %s\n' "${FAILED_CHECKS[*]}"
    exit 1
fi

printf '[PASS] Phase 1 verification gate passed\n'
