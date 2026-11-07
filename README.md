# Valorant Console OS

Automated Arch/CachyOS toolkit that converts a Tiny10 Windows 10 LTSC image into
a UEFI/GPT Windows To Go microSD system with a Valorant-only console shell.

> Unofficial engineering project. Not affiliated with Riot Games or Microsoft.
> Valorant and Vanguard are trademarks of Riot Games, Inc.

## Status

| Phase | Scope | Gate |
|-------|-------|------|
| 1 | ISO extraction, LTSC WIM slim/optimize, KB5015684 staging, Vanguard audit | 23/23 passing |
| 2 | unattend/OOBE, kiosk shell, microSD survival tweaks, WIM injection | 54/54 passing |
| 3+ | GPT/UEFI assembly, VM smoke test, microSD write, bare-metal attestation | planned |

## Safety

- Phases 1 and 2 never write to a block device. They only touch `build/` and the
  small pinned payloads under `payloads/`.
- `build/` (WIM, extracted ISO, logs, manifests, staged EFI) is disposable and
  git-ignored.
- Source media (`*.iso`) is git-ignored and must never be committed.
- Defender, TPM 2.0, Secure Boot, code integrity, Vanguard services, and the
  networking/audio services Valorant depends on are protected invariants. The
  tests fail if any of them is disabled.

## Requirements

- Arch Linux / CachyOS
- `wimlib`, `7zip`, `dos2unix`, `libxml2`, `python`, `curl`
- Phase 1 audit also expects `chntpw`, `parted`, `dosfstools`, `ntfs-3g`

```bash
sudo pacman -S --needed wimlib 7zip dos2unix libxml2 python curl \
    chntpw parted dosfstools ntfs-3g
```

Place a matching `tiny10*.iso` in the project root. The scripts discover the ISO
by glob and fail if zero or multiple candidates are found.

## Build

```bash
# Phase 1: extract ISO, export LTSC image, slim, optimize, audit, stage KB
bash ./scripts/01_prepare_wim.sh

# Phase 2: normalize payloads to CRLF and inject into the WIM
bash ./scripts/02_inject_payloads.sh
```

## Verify

```bash
bash ./tests/test_01_wim.sh       # Phase 1 gate
bash ./tests/test_02_payloads.sh  # Phase 2 gate
```

Logs are written to `build/logs/`. The generated image is
`build/custom_install.wim`.

## Payloads

| File | Purpose |
|------|---------|
| `payloads/autounattend.xml` | Skips OOBE, creates local admin `ValPlayer`, enables AutoLogon, runs first-logon provisioning. |
| `payloads/sd_survival_and_kiosk.cmd` | 22H2 build strings, CompactOS, pagefile, audio/mic consent, 23 non-gaming services disabled, optional features removed, kiosk shell, verification marker. |
| `payloads/val-kiosk.bat` | Launches Riot Client/Valorant, post-game console menu, first-boot setup mode. |
| `payloads/switch-mode.bat` | Switches between kiosk and desktop shells. |
| `payloads/windows10.0-kb5015684-x64.cab` | 22H2 enablement PSFX extracted from Microsoft's official MSU; SHA-256 pinned. |

Injected WIM destinations:

```text
/Windows/Panther/unattend.xml
/Riot Games/sd_survival_and_kiosk.cmd
/Riot Games/val-kiosk.bat
/Riot Games/switch-mode.bat
/Riot Games/windows10.0-kb5015684-x64.cab
```

## Layout

```text
.
├── OpenCode.md      # engineering charter and safety invariants
├── scripts/         # phase implementation scripts
├── payloads/        # Windows configuration payloads
├── tests/           # executable phase gates
├── vm-test/         # disposable VM assets
└── build/           # generated, disposable, git-ignored
```

## Reproducibility

The source ISO is not distributed here. The KB CAB is validated against:

```text
930e469881c615c997f5c57bf19c2a292684192eea40fe88224ebe445181258b
```

## Commit policy

History is kept granular: charter/docs, phase implementation, payloads, and
tests are committed as separate logical units. Every phase must pass its gate
before its commit is pushed.
