# Universal Service OS (USOS) 1.0.0

**Languages:** English ·
[Български](docs/readme/README.bg.md) ·
[Čeština](docs/readme/README.cs.md) ·
[Dansk](docs/readme/README.da.md) ·
[Deutsch](docs/readme/README.de.md) ·
[Ελληνικά](docs/readme/README.el.md) ·
[Español](docs/readme/README.es.md) ·
[Eesti](docs/readme/README.et.md) ·
[Suomi](docs/readme/README.fi.md) ·
[Français](docs/readme/README.fr.md) ·
[Hrvatski](docs/readme/README.hr.md) ·
[Magyar](docs/readme/README.hu.md) ·
[Italiano](docs/readme/README.it.md) ·
[Lietuvių](docs/readme/README.lt.md) ·
[Latviešu](docs/readme/README.lv.md) ·
[Norsk bokmål](docs/readme/README.nb.md) ·
[Nederlands](docs/readme/README.nl.md) ·
[Polski](docs/readme/README.pl.md) ·
[Português (Brasil)](docs/readme/README.pt-BR.md) ·
[Română](docs/readme/README.ro.md) ·
[Русский](docs/readme/README.ru.md) ·
[Slovenčina](docs/readme/README.sk.md) ·
[Slovenščina](docs/readme/README.sl.md) ·
[Srpski (latinica)](docs/readme/README.sr-Latn.md) ·
[Svenska](docs/readme/README.sv.md) ·
[Türkçe](docs/readme/README.tr.md) ·
[Українська](docs/readme/README.uk.md)

This English README is the authoritative version; the translations follow it.

## Contents

1. [What USOS is](#what-usos-is)
2. [Features](#features)
3. [Supported systems and firmware modes](#supported-systems)
4. [Quick start](#quick-start)
5. [DATA folder layout](#data-layout)
6. [Secure Boot](#secure-boot)
7. [Answer profiles](#answer-profiles)
8. [Known issues](#known-issues)
9. [Building from source](#building)
10. [Licence](#licence)
11. [Support](#support)
12. [Documentation](#documentation)

<a id="what-usos-is"></a>
## 1. What USOS is

USOS is one USB stick for installing and starting operating systems, from
MS-DOS to Windows 11 and Linux, on BIOS and UEFI computers, including UEFI
with Secure Boot. You copy your own ISO images to the stick like normal
files; USOS gives you one menu, an explicit and guarded choice of the target
disk, and the drivers and fixes old systems need on new hardware. The stick
is prepared on Windows with `USOS-Installer-1.0.0.exe`. USOS ships no
Windows images, no product keys and no activation bypass.

![USOS UEFI menu, home screen](docs/images/menu-home.png)

<a id="features"></a>
## 2. Features

- **One menu, BIOS and UEFI.** The same stick starts in Legacy BIOS and in
  UEFI (x64) with the same catalog. The UEFI menu works with keyboard,
  mouse, touch and USB gamepads.
- **Images stay files.** ISO, WIM, IMG, VHD, VHDX and EFI images are read
  straight from the NTFS DATA partition; nothing is extracted and nothing has
  to run after copying.
- **Guarded target disk.** You always pick and confirm the disk; the USOS
  stick itself is never offered.
- **Secure Boot** through shim 16.1 (signed by Microsoft) and the USOS key
  (MOK), enrolled once per computer.
- **Old Windows on new hardware.** Windows XP with a driver package and PAE
  on UEFI with CSM; XP and Vista on UEFI without CSM through CSMWrap
  (experimental); Windows 7 x64 without CSM through UefiSeven and a
  VGA-routing dispatcher; USB 3 and NVMe integration for Windows 7.
- **Answer profiles** for unattended Windows and Linux installs, edited in
  the UEFI menu with an on-screen keyboard.
- **Linux ISOs from DATA** (Ubuntu, Mint, Fedora, Debian, SystemRescue,
  GParted, Clonezilla and others), on UEFI with and without Secure Boot and
  on BIOS.
- **Tools:** built-in FreeDOS with a file manager and a Hardware & SMART
  panel (BIOS), the EDK2 UEFI Shell (UEFI), your own bootable tools in
  `Utilities`, your own UEFI drivers and Windows INF driver folders.
- **Installer with four modes:** Installation, Local update (**Update
  USOS**, keeps images and your files), Repair (**Repair ESP**), Uninstall.
- **27 languages** (English is the reference; the other locales are marked
  as machine-translated in part or in full, except Polish), themes with an
  in-menu editor, touch and pad support on the ROG Ally.

| | |
|---|---|
| ![Windows systems list with status badges](docs/images/windows-list.png) | ![Linux distributions list](docs/images/linux-list.png) |
| Windows systems with status badges | Linux ISOs from DATA |
| ![Legacy BIOS menu](docs/images/bios-menu.png) | ![Built-in and user themes](docs/images/themes-grid.png) |
| The Legacy BIOS menu | Themes: Dark, Light, Retro, Sunset |

<a id="supported-systems"></a>
## 3. Supported systems and firmware modes

**HW** = tested on real hardware, **VM** = tested in QEMU/VirtualBox only,
**exp.** = experimental (marked as such in the menu), **untested** = the
route exists but no run is recorded, **—** = not supported (the menu shows
the reason). Test machines: **X470** (ASRock X470, Ryzen 7 5700X, Radeon RX
560, UEFI), **MS-7100** (MSI, Socket 939, Athlon 64 X2, BIOS), **Ally**
(ASUS ROG Ally RC71L, UEFI with Secure Boot).

| System | BIOS (Legacy) | UEFI + CSM | UEFI without CSM (CSMWrap) | Secure Boot on |
|---|---|---|---|---|
| USOS menu itself | HW | HW | HW | HW (X470, Ally) |
| MS-DOS 6.22, Windows 3.1/3.11 | HW (Windows 3.1 in standard mode, MS-7100) | — | — | — |
| Windows 98 SE | VM; HW partial (MS-7100: Setup up to first-boot preparation, desktop not confirmed) | — | — | — |
| Windows 2000 SP4 | HW (MS-7100) | exp., VM (to file copy) | exp., VM (CSMWrap) | — |
| Windows XP x86 SP3 | VM (no driver package, no PAE) | HW (X470: driver package, PAE, 31.9 GB) | exp., HW (X470, CSMWrap) | — |
| Windows XP x64 SP2 | untested | exp., VM (to GUI Setup); X470: STOP 0xA5 | exp., VM (CSMWrap) | — |
| Windows Server 2003 R2 SP2 x86 | untested | exp., VM (to GUI Setup); X470 untested with 1.0 | exp., VM (CSMWrap) | — |
| Windows Vista SP2 x64 | HW (MS-7100) | HW (X470) | exp., HW (X470, CSMWrap, legacy MBR) | — |
| Windows 7 SP1 x64 | HW (MS-7100) | VM (full install) | HW (X470, UefiSeven + dispatcher) | — |
| Windows 8 / 8.1 | untested | untested | untested | untested |
| Windows 10 | HW (x86, MS-7100) | HW (x64, X470) | native UEFI, same path as with CSM | VM (up to the Windows loader) |
| Windows 11 | untested | HW (user report) | native UEFI, same path as with CSM | VM (up to the Windows loader) |
| Windows Server 2008 - 2025 | exp., never started | exp., never started | exp., never started | 2008/2008 R2: —; 2012+: untested |
| Linux ISOs (Ubuntu, Mint, Fedora, Debian, GParted, Clonezilla) | VM; HW Mint live (MS-7100) | HW (X470: Mint, Fedora, Debian netinst, Clonezilla, GParted) | same as with CSM | HW Fedora, Mint (X470); VM the rest |
| SystemRescue | VM | HW (X470) | same as with CSM | — (no signed boot loader) |
| FreeDOS, Hardware & SMART (built in) | VM (FreeDOS); HW (Hardware & SMART) | — | — | — |
| MemTest86+ (i586 ISO, you supply it) | HW | `.efi` build from `Utilities` (untested) | as with CSM | signed `.efi` only |
| UEFI Shell (built in) | — | VM | VM | VM (starts, cannot launch tools) |

UEFI with or without CSM only matters for the legacy paths (2000, XP,
2003, Vista, 7); every other UEFI entry runs the same code in both modes.
Windows XP, Vista and 7 and every CSMWrap path need Secure Boot off. The
full matrix with notes and the per-build hardware results are in the
[user guide, section 5](docs/USER-GUIDE.en.md#5-what-works-in-which-firmware-mode)
and the [release notes](docs/release-notes-1.0.md#supported-systems).

<a id="quick-start"></a>
## 4. Quick start

Release assets:

| File | Purpose |
|---|---|
| `USOS-Installer-1.0.0.exe` | **Full installer**: all of USOS plus the WinPE donor and both XP packages; works offline |
| `USOS-Installer-1.0.0-online.exe` | **Online installer**: small download; fetches the WinPE donor and XP packages from this release when needed and verifies them |
| `USOS-1.0.0-WinPE-PE10-donor.zip` | PE10 donor, needed for Vista and original Windows 7 ISOs on UEFI (included in the full installer; separate for manual or offline use) |
| `USOS-1.0.0-XP-package-PL.zip`, `USOS-1.0.0-XP-package-EN.zip` | Windows XP x86 SP3 UEFI package for exactly one original ISO each (`pl_..._x14-80476.iso` / `en_..._x14-80428.iso`); included in the full installer, or installed by hand with the included `install-xp-package.ps1` |
| `USOS-1.0.0-sources.zip` + `SOURCE-OFFER.txt` | sources of the third-party components and the written source offer |
| `USOS-1.0.0-buildkit.zip` | pinned toolchains and build inputs for an offline rebuild |
| `LICENSES/`, `THIRD-PARTY-NOTICES.txt` | licence texts and notices |
| `SHA256SUMS` | SHA-256 of every asset |

Check a download with `certutil -hashfile USOS-Installer-1.0.0.exe SHA256`
(or `Get-FileHash` in PowerShell) against `SHA256SUMS`.

![USOS installer: choose an operation](docs/images/installer-mode.png)

1. Get a USB stick of **at least 32 GiB** (in practice 64 GB; a stick sold
   as "32 GB" is usually too small). **Everything on it will be erased.**
2. On a Windows PC run `USOS-Installer-1.0.0.exe` (it asks for
   administrator rights), choose **Installation**, pick the stick, type the
   confirmation text and click **ERASE AND INSTALL**.
3. Copy your ISO images to the DATA partition, into the `Images` folder of
   each system, e.g. `Systems\Windows\Windows 11\Images\`.
4. After the install, the installer's **Components** step puts the WinPE
   donor (Vista and original Windows 7 on UEFI) and the XP package (XP on
   UEFI, in the language of your ISO) on the stick: from the full installer
   directly, from the online installer by download, both verified by
   SHA-256. You can skip them and add them later with **Update USOS** or
   **Repair**.
5. Boot the target PC from the stick (BIOS or UEFI). With Secure Boot on,
   enroll the USOS key once ([Secure Boot](#secure-boot)). Pick the system
   and the image, optionally an answer profile, confirm the target disk and
   follow the system's installer.

Step-by-step instructions for every screen are in the user
guide: [English](docs/USER-GUIDE.en.md), [Polski](docs/USER-GUIDE.pl.md).

<a id="data-layout"></a>
## 5. DATA folder layout

The installer creates the stick with three partitions: `USOS_ESP` (FAT32,
1 GiB: boot files, key, settings, logs, profiles), `USOS_DATA` (NTFS: your
files) and `USOS_WORK` (NTFS, working space for some Windows installers).
All folders on DATA are created for you:

```
USOS_DATA\
├─ Systems\
│  ├─ Windows\<version>\   Images\  Unattended\   (Windows 3.1 to 11, Server 2003-2025)
│  ├─ Linux\<distribution>\ Images\  Unattended\   (Other Linux\ for unknown ISOs)
│  ├─ Betas\
│  └─ DOS\<flavour>\        Images\
├─ Utilities\
│  ├─ FreeDOS\Programs\     DOS programs for the built-in FreeDOS
│  ├─ UEFI Shell\Tools\     EFI tools for the UEFI Shell
│  └─ <your tool>\Images\   e.g. MemTest86\Images\memtest86.efi
├─ Drivers\
│  ├─ UEFI\<name>\          .efi drivers loaded by the USOS menu
│  └─ <Windows version>\    Storage\  USB\  Other\  (INF packages)
├─ Themes\<name>\theme.ini  your own themes (UEFI menu)
└─ Programs\
   └─ USOS\                 managed by USOS (PE10 donor), do not touch
```

After adding an `icon.png` or a new tool folder, run **Update USOS**. The
full tree is in [the user guide, section 4](docs/USER-GUIDE.en.md#4-folder-layout-on-data).

<a id="secure-boot"></a>
## 6. Secure Boot

With Secure Boot on, USOS starts through **shim 16.1** (Fedora build, signed
by the Microsoft UEFI CA) and MokManager. USOS itself and its components are
signed with the **USOS key**, which is enrolled **once per computer**:

- **Easiest:** turn Secure Boot off, boot the stick, choose **Add** on the
  home screen and confirm with **Yes, save the key**, then turn Secure Boot
  back on. This also works in Setup Mode (confirmed on the X470).
- **With Secure Boot kept on:** on "Verification failed" use MokManager ->
  **Enroll key from disk** -> `USOS_ESP` -> `USOS-KEY.cer` (confirmed on the
  ROG Ally). The installer's **Prepare (one time)** card makes MokManager
  wait instead of counting down.

An NVRAM reset removes the key; enroll it again. XP, Vista, 7, every
CSMWrap path, SystemRescue and tools started from the UEFI Shell need Secure
Boot off. The kernel is not locked down yet (roadmap item N6), so enrolling
the USOS key trusts everything signed with it. Details:
[user guide, section 6](docs/USER-GUIDE.en.md#6-secure-boot-and-the-usos-key-mok),
[secure-boot-usos.md](docs/secure-boot-usos.md).

<a id="answer-profiles"></a>
## 7. Answer profiles

One small profile (accounts, computer name, language, time zone, optional
tweaks) is turned at start into `WINNT.SIF` (2000/XP/2003),
`autounattend.xml` (Vista to 11, Server) or Ubuntu autoinstall, Debian
preseed or Fedora kickstart. Profiles are created in the UEFI menu
(**Unattended setup** -> **+ Add a new profile**) and stored on the ESP.

![Answer-profile editor with the Appearance and extras section](docs/images/profile-editor-appearance.png)

- The target disk is **always chosen by hand**; a profile never selects or
  wipes a disk.
- A product key is stored only if you tick "Remember the key on this
  stick"; otherwise it lives only until the restart. **USOS ships no keys**
  and does not bypass activation or the product key page.
- Passwords and remembered keys are stored on the stick as plain text (never
  shown in lists or logs). Linux profiles work on UEFI only.

Details: [user guide, section 7](docs/USER-GUIDE.en.md#7-answer-profiles-and-tweaks),
[answer-profiles.md](docs/answer-profiles.md).

<a id="known-issues"></a>
## 8. Known issues

- **Vista on USB 3-only boards (X470):** USB flash drives are not visible in
  the installed system, and Vista stays in test mode (test-signed USB 3
  backport). A Renesas uPD72020x PCIe card avoids both.
- **CSMWrap paths:** need a graphics card with a legacy VBIOS (otherwise a
  black screen), take one CPU thread, need an MBR target disk (wiped) and
  Secure Boot off.
- **Server 2003 x86 / XP x64:** STOP 0xA5 (ACPI) on the X470 and no USB
  input on xHCI-only boards.
- **Windows 2000** does not work on AHCI-only boards (no NT 5.0 AHCI
  driver); **XP** has no NVMe support and gets no driver package or PAE in
  BIOS mode.
- **Secure Boot:** SystemRescue is blocked (no signed loader); the UEFI
  Shell cannot launch tools; after the BlackLotus DBX update older Windows
  media do not start.
- **Linux:** the Ubuntu Server installer preselects the largest disk, which
  may be the USOS stick; always check the target.
- **AMI firmware** lists every partition of the stick as its own boot entry.
- The micro-Linux helper needs an x86-64 CPU and at least 256 MiB RAM.

The full list with workarounds, and the honest list of what has **not been
tested** on hardware yet (e.g. Windows Server 2008-2025, Windows 8/8.1,
Windows 10/11 with Secure Boot on hardware, the original Windows 7 SP1 ISO
through the PE10 donor), are in the
[release notes](docs/release-notes-1.0.md#known-issues) and the
[user guide, sections 9 and 10](docs/USER-GUIDE.en.md#9-known-issues-and-workarounds).

<a id="building"></a>
## 9. Building from source

The build runs on Windows. Full instructions: [docs/BUILDING.md](docs/BUILDING.md).

- `build.bat` builds the complete release (EFI program, micro-Linux, BIOS
  core, payload and `installer\USOS Installer.exe`) with one build id
  (`BYYMMDD-HHMMSS-XXXXXXXX`). It uses the portable Zig in `tools\zig`; Go
  and Python must be on `PATH`.
- **Not in git:** Zig 0.16.0 (`tools\zig\zig.exe`) and QEMU 11.1
  (`tools\qemu`, only for the QEMU tests). Take Zig from the build kit
  (`toolchains\zig-x86_64-windows-0.16.0.zip`) or from
  [ziglang.org](https://ziglang.org/download/), and QEMU 11.1 from
  [qemu.org](https://www.qemu.org/download/#windows). The embedded payload
  `installer\internal\payload\assets\payload.zip` is a build output:
  `build.bat` regenerates it.
- **Windows clone:** some media paths are long. Run
  `git config --global core.longpaths true` **before** cloning.
- `tools/tests/run.ps1` runs the automated tests, e.g.
  `powershell.exe -NoProfile -ExecutionPolicy Bypass -File tools/tests/run.ps1 -Suite all`.
- `powershell -ExecutionPolicy Bypass -File tools\release\make_release.ps1`
  produces the release assets in `zig-out\release-1.0\`.
- **Offline build:** extract `USOS-1.0.0-buildkit.zip`, set `USOS_BUILDKIT`
  to the extracted `USOS-1.0.0-buildkit` folder and run `build.bat`; the kit
  is checked against its manifest and downloads are disabled.
- **Signing key:** the Secure Boot (MOK) key lives **outside the
  repository**, in `%APPDATA%\USOS\signing\` (`USOS_SIGNING_DIR` overrides
  it). Without it the build is **unsigned** and boots only with Secure Boot
  off. Never commit or share the key.

Windows ISOs, drivers and other third-party media are never part of the
repository.

<a id="licence"></a>
## 10. Licence

- USOS's own code is licensed under the **GNU General Public License,
  version 3 or later** (GPL-3.0-or-later): see [LICENSE](LICENSE) and
  [NOTICE](NOTICE). Copyright (C) 2026 Maksymilian and the USOS Authors.
- Third-party components keep their own licences. They are separate
  programs aggregated on the stick; see `THIRD-PARTY-NOTICES.txt` and
  `LICENSES/` in the release and [docs/LICENSES-AUDIT.md](docs/LICENSES-AUDIT.md).
- Microsoft files in the release (update and driver files, the files in the
  XP packages, the WinPE donor) are kept for preservation, redistributed at
  the maintainer's own risk, not covered by any USOS licence, and will be
  removed on request of the rights holder.
- Contributions are accepted under [CONTRIBUTING.md](CONTRIBUTING.md) (a
  lightweight contributor licence grant).

Windows, MS-DOS and related names are trademarks of Microsoft. USOS is not
affiliated with Microsoft.

<a id="support"></a>
## 11. Support

- Questions and bug reports: GitHub issues. Please attach the logs described
  in [the user guide, section 11](docs/USER-GUIDE.en.md#11-troubleshooting-and-logs)
  and check that they hold no passwords or keys.
- Paid setup help for businesses is available on request; for now, get in
  touch through GitHub issues.
- Sponsoring: through `.github/FUNDING.yml` once it is filled in.

<a id="documentation"></a>
## 12. Documentation

- User guide: [English](docs/USER-GUIDE.en.md), [Polski](docs/USER-GUIDE.pl.md)
- [Release notes 1.0](docs/release-notes-1.0.md)
- [How USOS works](docs/HOW-IT-WORKS.md)
- [Building](docs/BUILDING.md)
- [Licence audit](docs/LICENSES-AUDIT.md)
- [Release test plan 1.0](docs/RELEASE-TEST-1.0.md)
- [Roadmap](docs/ROADMAP.md) (Polish) and [test results](TESTING.md) (Polish)
