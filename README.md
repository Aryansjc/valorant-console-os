# Valorant Console OS

Automated Arch/CachyOS toolkit that converts a Tiny10 Windows 10 LTSC image into
a UEFI/GPT Windows To Go microSD system with a Valorant-only console shell.

> Unofficial engineering project. Not affiliated with Riot Games or Microsoft.
> Valorant and Vanguard are trademarks of Riot Games, Inc.

## Status

| Phase | Scope | Gate |
|-------|-------|------|
| 1 | ISO extraction, LTSC WIM slim/optimize, KB5015684 staging, Vanguard audit | 23/23 passing |
| 2 | unattend/OOBE, kiosk shell, microSD survival tweaks, WIM injection | 57/57 passing |
| 3 | GPT/UEFI deploy engine, offline boot fixes, OVMF + TPM 2.0 VM smoke test | 17/17 passing |
| 4 | microSD write and read-back verify | 32/32 passing |
| 5 | Bare-metal boot and Vanguard attestation | 56/56 self-test; hardware report pending |

## Safety

- Phases 1 and 2 never write to a block device. They only touch `build/` and the
  small pinned payloads under `payloads/`.
- Phase 3 writes only to a loop device backed by `vm-test/test_sdcard.img` during
  the VM gate. The deploy engine rejects NVMe disks, host-mounted devices, swap,
  read-only devices, partitions, and non-removable disks.
- Phase 4 accepts only a whole removable disk (`RM=1`) or a loop device backed
  by a file under `build/` or `vm-test/`. The gate proves the validator rejects
  NVMe, host/root-mounted, swap, read-only, partition, stacked, and
  non-removable targets before the disposable loop image is written.
- The Phase 5 collector only reads security state. It never disables, stops,
  patches, or reconfigures Defender, TPM, Secure Boot, code integrity, or
  Vanguard. `--prepare` copies the collector onto the card and requires a
  validated target plus `--commit` (and `--yes` when non-interactive). Reports
  from QEMU, VMware, VirtualBox, Hyper-V, or reports older than 72 hours are
  rejected.
- `build/` (WIM, extracted ISO, logs, manifests, staged EFI) and `vm-test/` (QEMU
  images, OVMF variables, TPM state) are disposable and git-ignored.
- Source media (`*.iso`) is git-ignored and must never be committed.
- Defender, TPM 2.0, Secure Boot, code integrity, Vanguard services, and the
  networking/audio services Valorant depends on are protected invariants. The
  tests fail if any of them is disabled.

## Requirements

- Arch Linux / CachyOS
- `wimlib`, `7zip`, `dos2unix`, `libxml2`, `python`, `curl`
- Phase 1 audit also expects `chntpw`, `parted`, `dosfstools`, `ntfs-3g`
- Phase 3 gate also expects `qemu-system-x86`, `swtpm`, `socat`, `edk2-ovmf`,
  `libvirt`-free KVM access (`/dev/kvm`)
- Phase 4 gate also expects `reged` (from `chntpw`), `ntfs-3g`, `losetup`,
  `blockdev`, and `python3`
- Phase 5 gate also expects `ntfs-3g` (including `mkntfs`), `parted`, `losetup`,
  `blockdev`, `udevadm`, and `python3`; the Windows target needs only the
  built-in PowerShell 5.1 and Windows Security cmdlets

```bash
sudo pacman -S --needed wimlib 7zip dos2unix libxml2 python curl \
    chntpw parted dosfstools ntfs-3g qemu-system-x86 swtpm socat edk2-ovmf
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

Deploy to a validated removable disk or loop device (dry-run is the default):

```bash
# Validation only; no block device is modified
bash ./scripts/03_deploy_wtg.sh --target /dev/sdX

# Destructive deployment after the interactive ERASE confirmation
sudo bash ./scripts/03_deploy_wtg.sh --target /dev/sdX --commit
```

Phase 4 wraps the deploy engine with an independent post-write read-back:

```bash
# Validation only (default)
bash ./scripts/04_write_sdcard.sh --target /dev/sdX

# Destructive write plus read-back of GPT, ESP, NTFS, payloads, and SYSTEM
sudo bash ./scripts/04_write_sdcard.sh --target /dev/sdX --commit

# Non-interactive commit (microSD production run)
sudo bash ./scripts/04_write_sdcard.sh --target /dev/sdX --commit --yes --full-read

# Read-back only, without writing (works on a card that already booted)
sudo bash ./scripts/04_write_sdcard.sh --target /dev/sdX --verify-only
```

`--full-read` reads the whole target twice and requires matching SHA-256
digests. Commit and read-back runs write a manifest to
`build/logs/04_manifest_*.env`.

## Phase 5 hardware attestation

Phase 5 proves the card boots on physical hardware with Secure Boot and TPM 2.0
enabled, Defender and code integrity intact, and Riot Vanguard loaded. The Linux
side only reads the card; the Windows collector writes the evidence.

1. Copy the collector onto the finished card:

   ```bash
   sudo bash ./scripts/05_attest_baremetal.sh --target /dev/sdX \
       --prepare --commit --yes
   ```

2. Boot the card on the target PC with UEFI, Secure Boot, and TPM 2.0 enabled.
   From the console menu choose the full Windows desktop, install Riot Vanguard
   as the last installation step, and let Windows Update/Defender refresh
   signatures. Then open `C:\Riot Games` and run `phase5_attest.cmd` as
   administrator. The gate requires `vgk.sys`/`vgc` running and Defender
   signatures no older than 30 days.

3. Return the card to the Linux host and validate the report:

   ```bash
   sudo bash ./scripts/05_attest_baremetal.sh --target /dev/sdX
   ```

The collector writes `C:\Riot Games\phase5_attestation.json` and a readable
`.txt` summary. The validator checks 30 report requirements plus target and
binding checks, and binds the report to the card's GPT disk/partition GUIDs and
the SHA-256 of `C:\Riot Games\boot_verified.txt`. `--report <json>` validates a
report copied inside the project tree without the card, but cannot verify that
binding and is therefore not a hardware pass.

## Verify

```bash
bash ./tests/test_01_wim.sh       # Phase 1 gate
bash ./tests/test_02_payloads.sh  # Phase 2 gate

# Phase 3 gate: 25 GiB sparse image, loop deploy, OVMF + TPM 2.0 boot,
# then read-only verification. Needs root for loop devices and mounts.
pkexec bash ./tests/test_03_qemu_boot.sh

# Phase 4 gate: lsblk safety fixtures, CLI/confirmation guards, a fresh
# 25 GiB loop deploy, independent GPT/ESP/NTFS/SYSTEM read-back, manifest,
# and --verify-only against a first-boot-rewritten answer file.
pkexec bash ./tests/test_04_sdcard.sh

# Phase 5 self-test: fixture report, 33 negative mutations, CLI/input guards,
# and a disposable 1 GiB loop card with GPT/marker binding and prepare read-back.
# This is a development gate, not the hardware pass.
pkexec bash ./tests/test_05_baremetal.sh --self-test

# Phase 5 hardware gate, after the card has booted on the target PC
pkexec bash ./tests/test_05_baremetal.sh --target /dev/sdX

# ...or validate a report copied into build/phase5/ (no card binding check)
mkdir -p ./build/phase5
cp /media/card/Riot\ Games/phase5_attestation.json ./build/phase5/
pkexec bash ./tests/test_05_baremetal.sh \
    --report ./build/phase5/phase5_attestation.json
```

The Phase 5 hardware gate requires `--target` with a whole `RM=1` card and fails
closed when no physical report exists; a QEMU report is deliberately rejected as
non-bare-metal. `--report` validates a copied report offline, without proving
card binding, and is not a hardware pass.

Logs are written to `build/logs/`. The generated image is
`build/custom_install.wim`.

## Payloads

| File | Purpose |
|------|---------|
| `payloads/autounattend.xml` | Skips OOBE, creates local admin `ValPlayer`, enables AutoLogon, runs first-logon provisioning. |
| `payloads/sd_survival_and_kiosk.cmd` | 22H2 build strings, CompactOS, pagefile, audio/mic consent, 23 non-gaming services disabled, optional features removed, kiosk shell, verification marker. |
| `payloads/val-kiosk.bat` | Launches Riot Client/Valorant, post-game console menu, first-boot setup mode. |
| `payloads/switch-mode.bat` | Switches between kiosk and desktop shells. |
| `payloads/phase5_attest.ps1` | Reads Secure Boot, TPM 2.0, Defender, code integrity, kiosk, boot media, and Vanguard state; writes the Phase 5 JSON report. |
| `payloads/phase5_attest.cmd` | Elevated launcher for the Phase 5 collector. |
| `payloads/windows10.0-kb5015684-x64.cab` | 22H2 enablement PSFX extracted from Microsoft's official MSU; SHA-256 pinned. |

Injected WIM destinations:

```text
/Windows/Panther/unattend.xml
/Riot Games/sd_survival_and_kiosk.cmd
/Riot Games/val-kiosk.bat
/Riot Games/switch-mode.bat
/Riot Games/windows10.0-kb5015684-x64.cab
```

The Phase 5 collector is copied to `/Riot Games/` by
`05_attest_baremetal.sh --prepare`, after the card has been written. It is not
injected into the WIM, so Phases 1–4 remain unchanged.

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
