# OpenCode.md — Valorant Console OS Engineering Charter

**Project:** Convert a tiny10 x64 source ISO into a minimalist, bare-metal bootable
"Valorant Console OS" (Windows To Go) on a high-speed microSD card.

**Host platform:** Arch / CachyOS Linux
**Target firmware:** UEFI + GPT only (no Legacy/CSM)
**Base:** Windows LTSC Build 19044 (21H2) → 19045 (22H2) via `KB5015684`
**Kiosk:** Replace the interactive `explorer.exe` shell with a Valorant-only kiosk
launcher while preserving everything Riot Vanguard (`vgk.sys`) depends on.

These rules are mandatory for every script, test, payload, and document in this
repository. If a requested change conflicts with a rule below, stop and surface
the conflict instead of working around it.

---

## 1. Dynamic Relative Paths Only

Never hardcode a user home directory, username, absolute project path, or rely on
the caller's current working directory. Every script in `./scripts/` or `./tests/`
must resolve the project root exactly like this:

```bash
PROJECT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
```

For scripts nested deeper than one level, increase the `..` count or use a shared
helper that walks up to the directory containing this file; never substitute
`$HOME`, `~`, `$PWD`, or a literal `/home/...`.

Requirements:

- Anchor every repository path to `"$PROJECT_ROOT"`.
- Double-quote every variable expansion, including loop variables, command
  substitutions, and array elements: `"$ISO_PATH"`, `"${args[@]}"`.
- Use Bash arrays for argv construction; never rely on word splitting.
- Handle spaces literally. The source ISO is named with spaces
  (`tiny10 x64 23h2.iso` in the brief; see Workspace Note below).
- Use `find` / glob discovery for the ISO; never hardcode either filename. Fail
  loudly if zero or multiple candidates are found.
- Use `--` before operands for external commands where supported.
- If a path comes from user input, resolve it, reject empty paths, and verify it
  stays inside the expected directory before use.
- No `cd` without a quoted, validated path; restore the previous directory or
  avoid changing directory entirely.

Required skeleton for every script:

```bash
#!/usr/bin/env bash
set -Eeuo pipefail
IFS=$'\n\t'

PROJECT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
readonly PROJECT_ROOT
```

## 2. Host Drive Safety (CRITICAL)

This toolkit can destroy data. A wrong device name is unacceptable.

- **Never hardcode block device names** (`/dev/sda`, `/dev/sdb`,
  `/dev/mmcblk0`, `/dev/nvme0n1`, etc.) in any executable path.
- Every script that writes to, formats, partitions, mounts read-write, or runs
  `dd`/`wipefs`/`sgdisk`/`parted` against a block device **must first query
  `lsblk`** and validate the exact target.
- The target must be supplied explicitly (for example `--target /dev/...`) and
  must never be inferred as "the only removable disk" without validation.
- Abort immediately, before any write, if the target or any ancestor/child in
  its device tree:
  - matches `nvme*`;
  - is mounted at `/`, `/home`, `/boot`, `/boot/efi`, `/var`, or any path
    belonging to the running host root;
  - is an active swap device or has mountpoint `[SWAP]`;
  - is not a `loop*` device and does not report `RM=1` (removable);
  - is read-only (`RO=1`), is a partition of a non-removable host disk, or is
    otherwise part of the host's root device ancestry;
  - is busy (`findmnt`, `fuser`, or an active mount on any child).
- Allowed write targets are exactly:
  1. loop devices created by this toolkit from files under `./build/`, or from
     the disposable QEMU image under `./vm-test/`; and
  2. a whole removable disk (`TYPE=disk`, `RM=1`) with no host filesystem
     mounted, after explicit confirmation.
- Default to dry-run. Destructive operations require a second explicit flag
  (for example `--commit`) in addition to the validated target.
- Log the validated `lsblk` record to `"$PROJECT_ROOT/build/logs/"` before the
  first write.
- Never run destructive commands against `/dev` globs, `lsblk` defaults, or
  variables that were not validated in the same script run.
- Partition names are derived from the validated disk, never guessed. Verify
  the parent disk (`PKNAME`) matches the approved target.
- Refuse to operate if the host root device cannot be determined; fail closed.

Minimum validation fields to inspect:

```bash
lsblk -J -o NAME,KNAME,PATH,TYPE,RM,RO,SIZE,MOUNTPOINTS,PKNAME
```

## 3. Vanguard Anti-Cheat Compliance

Riot Vanguard requires a trustworthy, non-tampered Windows environment. The
following are **immutable project invariants**:

Never delete, disable, bypass, patch, rename, block, or weaken:

- Windows Defender: `WinDefend` service, `WdFilter.sys`, `MsMpEng.exe`,
  Defender platform/security intelligence components, and real-time protection
  required by policy.
- Security Health Service (`SecurityHealthService`) and Windows Security UI
  components.
- Code Integrity: `ci.dll`, HVCI / Memory Integrity, kernel-mode code signing,
  and the driver blocklist.
- TPM 2.0: `tpm.sys`, TPM device/services, and measured-boot configuration.
- UEFI Secure Boot: firmware Secure Boot state, db/dbx/KEK/PK, Microsoft UEFI
  CA certificates, and boot manager files.
- Vanguard components: `vgk.sys`, `vgc`, and their services/drivers.

Also forbidden:

- `sysprep /generalize` **after** Vanguard is installed. Vanguard must be the
  last installation step, after OOBE/specialize and after the 19045 upgrade.
- `bcdedit` test signing, kernel debugging, Driver Signature Enforcement
  bypasses, or disabling integrity checks.
- Deleting `System32\drivers` files or setting security services to
  `Disabled`/`Manual` as a "performance tweak".
- Applying "debloat" scripts that remove Defender, TPM, Secure Boot, or
  servicing components.

Performance and flash-wear optimizations are allowed only when they preserve
every invariant above. Each phase's tests must positively assert the presence
and enabled state of these components. Any telemetry that shows a missing or
disabled invariant is a hard `[FAIL]`.

## 4. Test-Driven Phases

No implementation proceeds without an executable gate.

- Every phase has a verification script in `./tests/`, named
  `verify_phaseNN_<name>.sh`.
- Each script prints one line per requirement:
  - `[PASS] <requirement-id>: <what was verified>`
  - `[FAIL] <requirement-id>: <what failed and why>`
- A script exits `0` only when every requirement passed; any `[FAIL]` exits
  non-zero and prints a final `[FAIL] phase ...` summary.
- Tests are runnable from any working directory and resolve `PROJECT_ROOT` per
  Rule 1.
- Tests must be repeatable and safe: read-only against the host; destructive
  checks run only inside a disposable VM or a loop-backed image under
  `"$PROJECT_ROOT/build/"` or `"$PROJECT_ROOT/vm-test/"`.
- Disk-safety tests must exercise the `lsblk` validator with fixtures/mocks and
  prove that `nvme*`, host-mounted, swap, and non-removable targets are
  rejected.
- Test logs are written under `"$PROJECT_ROOT/build/logs/"` and are disposable.
- **Phase N+1 may not begin until all Phase N tests pass.** A failing test is
  fixed, not skipped, muted, or marked expected-failure.
- Every phase gate lists its requirements in this file or in the phase script's
  header, and the test covers each one.

Phase gate sequence (tests must exist before implementation of each phase):

| Gate | Scope | Verification focus |
|------|-------|--------------------|
| 1 | ISO extraction, LTSC WIM preparation, `KB5015684` staging | WIM/edition/build audit (`tests/test_01_wim.sh`) |
| 2 | Payload injection: unattend, kiosk shell, survival tweaks | Payload syntax/CRLF and injected WIM contents (`tests/test_02_payloads.sh`) |
| 3 | GPT/UEFI WTG deploy and OVMF + TPM 2.0 boot | GPT/ESP, BCD system store, first logon, invariants (`tests/test_03_qemu_boot.sh`) |
| 4 | microSD write and read-back verification | Validated `RM=1` target or loop image, GPT/ESP/NTFS/hash checks (`tests/test_04_sdcard.sh`) |
| 5 | Bare-metal boot and Vanguard attestation | Secure Boot on, TPM 2.0 on, Defender on, Vanguard loads; self-test plus a physical-hardware report (`tests/test_05_baremetal.sh`) |

## Directory Contract

```text
.
├── OpenCode.md      # This charter; source of truth for rules and phase gates
├── scripts/         # Phase scripts and shared Bash helpers (no secrets)
├── payloads/        # unattend.xml, kiosk launcher, registry/service payloads
├── vm-test/         # Disposable QEMU/OVMF images, vars, VM-only assets
├── tests/           # verify_phaseNN_*.sh, fixtures, [PASS]/[FAIL] output
└── build/           # Generated WIMs, images, logs, checksums (disposable)
```

Rules for the tree:

- `scripts/` and `tests/` contain Bash only unless a documented exception is
  approved.
- `payloads/` contains only static inputs; every payload is referenced by an
  explicit `"$PROJECT_ROOT/payloads/..."` path.
- `vm-test/` and `build/` are disposable and never used as sources of truth.
- All generated artifacts stay inside the repository tree; nothing is written
  to the host home directory.
- No secrets, license keys, tokens, or Riot credentials are committed.

## Workspace Note

At initialization time the project root contains exactly one ISO named
`tiny10 23h1 x64.iso` (3,945,988,096 bytes). The task brief refers to
`tiny10 x64 23h2.iso`. Scripts must therefore auto-discover the source with a
case-insensitive `tiny10*.iso` glob and fail on zero or multiple matches. Do not
hardcode either spelling; treat the actual filename as environment data.

## Change Protocol

- Read this file before changing any script, payload, or test.
- Do not weaken Rules 1–4. Safety and Vanguard invariants are not negotiable.
- Update this charter when a phase gate, directory, or invariant changes.
- Prefer small, reviewable commits: one phase or one safety fix at a time.
- When in doubt, fail closed and ask before touching a block device.
