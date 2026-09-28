# Universal Service OS (USOS) 1.0.0

**Po polsku:** [Przewodnik użytkownika (PL)](docs/USER-GUIDE.pl.md), the
primary user guide. English guide: [docs/USER-GUIDE.en.md](docs/USER-GUIDE.en.md).

USOS is one USB stick for installing and starting operating systems, from
MS-DOS to Windows 11 and Linux, on BIOS and UEFI computers, including UEFI
with Secure Boot. You copy your own ISO images to the stick; USOS gives you
one menu, an explicit and guarded choice of the target disk, and the drivers
and fixes old systems need on new hardware. The stick is prepared on Windows
with `USOS Installer.exe`.

## Highlights

- **One menu, BIOS and UEFI.** The same stick starts in Legacy BIOS and in
  UEFI (x64), with the same catalog of systems and tools.
- **Secure Boot.** Distribution-signed shim 16.1 plus the USOS key, enrolled
  once per computer (straight from the USOS menu with Secure Boot off, or
  with MokManager).
- **Images stay ISO files.** ISO, WIM, IMG, VHD, VHDX and EFI images are read
  straight from the NTFS DATA partition; no extraction, no catalog rebuild
  after copying.
- **Guarded target disk.** You always pick and confirm the disk; the USOS
  stick itself is never offered.
- **Old Windows on new hardware.** Windows XP with PAE and a driver package
  on UEFI; XP and Vista on UEFI without CSM through CSMWrap; Windows 7 x64 on
  UEFI without CSM through UefiSeven with a VGA-routing dispatcher; USB 3 and
  NVMe integration for Windows 7.
- **Answer profiles.** One profile (accounts, computer name, language, time
  zone, optional tweaks) rendered at start into `WINNT.SIF`,
  `autounattend.xml`, Ubuntu autoinstall, Debian preseed or Fedora
  kickstart. Edited in the UEFI menu with an on-screen keyboard. The target
  disk is always chosen by hand; product keys are stored only on explicit
  opt-in and are never shipped.
- **Linux ISOs from DATA** (Ubuntu, Mint, Fedora, Debian, SystemRescue,
  GParted, Clonezilla and others) on UEFI with and without Secure Boot and
  on BIOS.
- **Tools:** built-in FreeDOS with a file manager (BIOS), Hardware & SMART
  panel (BIOS), EDK2 UEFI Shell (UEFI), your own bootable tools in
  `Utilities`, user UEFI drivers and Windows INF driver folders.
- **27 languages**, themes (built-in, examples and an in-menu editor),
  gamepad and touch input (ROG Ally).

## Supported systems (summary)

Hardware-tested on an ASRock X470 / Ryzen 7 5700X / Radeon RX 560 (UEFI),
an MSI MS-7100 Socket 939 PC (BIOS) and an ASUS ROG Ally RC71L (UEFI with
Secure Boot). Details per firmware mode, with what is hardware-tested,
QEMU-only or experimental: [the matrix in the user guide](docs/USER-GUIDE.en.md#5-what-works-in-which-firmware-mode).

| Group | Status in 1.0 |
|---|---|
| MS-DOS 6.22, Windows 3.x, Windows 98 SE | BIOS only |
| Windows 2000 | BIOS (hardware); UEFI experimental (QEMU) |
| Windows XP x86 SP3 | UEFI with CSM and without CSM (CSMWrap): hardware-tested; BIOS: VM-tested |
| Windows XP x64, Server 2003 x86 | experimental (QEMU to GUI Setup) |
| Windows Vista SP2 x64 | BIOS, UEFI with CSM, UEFI without CSM (CSMWrap): hardware-tested |
| Windows 7 SP1 x64 | BIOS and UEFI without CSM: hardware-tested |
| Windows 8 / 8.1 | routed, not tested |
| Windows 10 / 11 | UEFI hardware-tested; Windows 10 x86 on BIOS hardware-tested |
| Windows Server 2008 - 2025 | experimental, not started yet |
| Linux ISOs | QEMU on all paths; first hardware round on the X470 and the Socket 939 PC |
| FreeDOS, Memtest86+, Hardware & SMART | BIOS |
| UEFI Shell | UEFI (QEMU) |

Windows XP, Vista and 7 and every CSMWrap path need Secure Boot off.
Known issues and the list of things not tested yet are in the guide
(sections 9 and 10) and in the [release notes](docs/release-notes-1.0.md).

## Download: release assets

| File | Purpose |
|---|---|
| `USOS-Installer-1.0.0.exe` | the installer; contains all of USOS |
| `USOS-1.0.0-WinPE-PE10-donor.zip` | PE10 donor image for Vista and original Windows 7 ISOs on UEFI; copy `Programs\USOS\WinPE\PE10_x64_19041_USOS.iso` to DATA, then run **Update USOS** |
| `USOS-1.0.0-XP-package-PL.zip`, `USOS-1.0.0-XP-package-EN.zip` | Windows XP x86 SP3 UEFI package for exactly `pl_windows_xp_professional_with_service_pack_3_x86_cd_x14-80476.iso` / `en_windows_xp_professional_with_service_pack_3_x86_cd_x14-80428.iso`; installed onto the stick's ESP (`EFI\USOS-XP`) with the included `install-xp-package.ps1`, run as administrator; one package at a time |
| `USOS-1.0.0-sources.zip` | source code |
| `LICENSES`, `THIRD-PARTY-NOTICES.txt` | licences and third-party notices |
| `SHA256SUMS` | SHA-256 of every asset |

Windows images are never included: bring your own ISOs.

Check a download before running it:

```
certutil -hashfile USOS-Installer-1.0.0.exe SHA256
```

or `Get-FileHash .\USOS-Installer-1.0.0.exe -Algorithm SHA256` in
PowerShell, and compare with the line in `SHA256SUMS`.

## Quick start

1. Get a USB stick of **at least 32 GiB** (in practice 64 GB; a stick sold as
   "32 GB" is usually too small). Everything on it will be erased.
2. On a Windows PC run `USOS-Installer-1.0.0.exe` (it asks for administrator
   rights), choose **Installation**, pick the stick, type the confirmation
   text and click **ERASE AND INSTALL**.
3. Copy your ISO images to the DATA partition, into the `Images` folder of
   each system, e.g. `Systems\Windows\Windows 11\Images\`. Add the PE10
   donor and the XP package if you need Vista, original Windows 7 or XP on
   UEFI (then run **Update USOS**).
4. Boot the target PC from the stick (BIOS or UEFI). With Secure Boot on,
   enroll the USOS key once (guide, section 6).
5. Pick the system and the image, optionally an answer profile, confirm the
   target disk, and follow the installer.

## Documentation

- User guide: [Polski](docs/USER-GUIDE.pl.md) (primary), [English](docs/USER-GUIDE.en.md)
- [Release notes 1.0](docs/release-notes-1.0.md)
- [Licence audit](docs/LICENSES-AUDIT.md)
- [Release test plan 1.0](docs/RELEASE-TEST-1.0.md)
- [Roadmap](docs/ROADMAP.md) (Polish) and [test results](TESTING.md) (Polish)
- Topic docs: [media layout](MEDIA_LAYOUT.md), [answer profiles](docs/answer-profiles.md),
  [themes](docs/menu-themes.md), [Secure Boot](docs/secure-boot-usos.md),
  [UEFI Shell](docs/uefi-shell.md), [drivers](docs/drivers.md),
  [hands-off XP](docs/xp-unattended.md), [Windows Server](docs/windows-server.md),
  [Linux ISO boot](docs/design/linux-iso-boot.md), [CSMWrap](docs/design/csmwrap-integration.md),
  [Windows 7 / Vista without CSM](docs/design/win7-vista-no-csm.md)
- Project rules and architecture: [PROJECT_RULES.md](PROJECT_RULES.md),
  [ARCHITECTURE.md](ARCHITECTURE.md), [BOOT_FLOW.md](BOOT_FLOW.md)

## Building from source

The build runs on Windows.

- **Zig**: the portable compiler in `tools/zig/zig.exe` is used; Zig does not
  need to be on `PATH`.
- **Go** and **Python** must be on `PATH` (`build.bat` runs `go run` for the
  signer and the payload packer, and Python helpers).
- `build.bat` builds the complete `ReleaseFast` release: the shared EFI
  program for the stick and the QEMU test, the micro-Linux, the Legacy BIOS
  core, the payload (`installer/internal/payload/assets/payload.zip`) and
  `installer\USOS Installer.exe`, and ends with a SHA-256 consistency check.
  Each build gets one build id (`BYYMMDD-HHMMSS-XXXXXXXX`,
  `build/generated/build-info.ini`).
- `tools/tests/run.ps1` is the single entry point for the automated tests:
  `-Suite all` (unit, selftest, QEMU x86_64 and ARM64), `unit`, `selftest`,
  `x86_64`, `aarch64`. Example:
  `powershell.exe -NoProfile -ExecutionPolicy Bypass -File tools/tests/run.ps1 -Suite all`.
- `TEST-USOS.cmd` runs a full, visible USOS test in QEMU with a real Windows
  ISO; `RESET-USOS-TEST.cmd` clears only that test's state and virtual disk.
- A freshly built installer's **Update USOS** mode writes the current build
  onto an existing USOS stick without formatting and without deleting system
  images.
- Release assets:
  `powershell -ExecutionPolicy Bypass -File tools\release\make_release.ps1`
  produces `zig-out\release-1.0\`.

**Signing key.** The Secure Boot (MOK) signing key lives **outside the
repository**, in `%APPDATA%\USOS\signing\` (`USOS_SIGNING_DIR` overrides
it). Only the public certificate is tracked
(`assets/secure-boot/usos-secure-boot.cer`). Without the key the build emits
the same shim layout **unsigned**, and it boots only with Secure Boot off.
Never commit or share the key; every computer that enrolled the USOS key
trusts code signed with it.

Windows ISOs, drivers and other third-party media are never part of the
repository.

## Licence

The repository has no `LICENSE` file for the USOS code yet: **the licence
for USOS's own code is to be decided before publishing.** Third-party
components keep their own licences; see `THIRD-PARTY-NOTICES.txt` and
`LICENSES` in the release and [docs/LICENSES-AUDIT.md](docs/LICENSES-AUDIT.md).

Windows, MS-DOS and related names are trademarks of Microsoft. USOS is not
affiliated with Microsoft.
