# USOS 1.0.0 release notes

Universal Service OS (USOS) 1.0.0 puts one USB stick in place of a drawer of
boot sticks. It installs and starts systems from MS-DOS to Windows 11 and
Linux, in Legacy BIOS and UEFI, with Secure Boot on as well. You get one
menu, the target disk is always chosen and confirmed explicitly, installs
don't have to return to the stick, and there are drivers and fixes for newer
hardware. The stick is prepared on Windows with `USOS-Installer-1.0.0.exe`.

The menu header shows "Universal Service OS 1.0.0" and the shortened build
ID (hidden on narrow screens); the installer shows "1.0.0 (B...)". The first
release candidate is build `B260928-214844-A6711A1F`; the full ID is in
`EFI\USOS\build-info.ini` on the stick.

> Status of this document: the release candidate. The git tag `v1.0.0` is
> created only after the fresh-install test in
> [RELEASE-TEST-1.0.md](RELEASE-TEST-1.0.md) passes.

## Highlights

- **One menu for UEFI and Legacy BIOS.** The UEFI menu is graphical and
  works with keyboard, mouse, wheel, touch and USB gamepads. The BIOS Core
  menu has the same catalog. Both read ISO/WIM/IMG/VHD(X) images straight
  from the NTFS `USOS_DATA` partition with a read-only parser. Images that
  don't match the current firmware carry a badge ("Requires BIOS",
  "Requires Secure Boot off") and can't be started.
- **Windows installer (`USOS Installer.exe`)** with four modes: Install
  (new stick, erases it), Update (writes the current build without
  formatting, keeps images, profiles and themes), Repair (rebuilds the ESP
  boot files, leaves DATA alone) and Uninstall. Updates verify every payload
  file by SHA-256 after writing. They refuse a downgrade unless you confirm
  it, and they log `VERSION media=... installer=...`.
- **Secure Boot through shim + MOK.** The removable path holds shim 16.1
  (Fedora build, signed by the Microsoft UEFI CA 2011 and 2023) with
  MokManager. USOS itself, the micro-Linux kernel, systemd-boot, the NTFS
  driver, the UEFI Shell and the touch driver are signed with the USOS key.
  The key has to be enrolled once per computer. If Secure Boot is off or the
  board is in Setup Mode, USOS saves it into MokList itself. Otherwise
  MokManager does it ("Enroll key from disk" -> `USOS_ESP` ->
  `USOS-KEY.cer`). The installer shows a card that guides you through this.
  Details: [secure-boot-usos.md](secure-boot-usos.md).
- **Answer profiles and the profile manager.** One small settings file is
  turned into `WINNT.SIF` (2000/XP/2003), `autounattend.xml` (Vista to 11,
  Server 2008-2025), or autoinstall/preseed/kickstart (Ubuntu, Debian,
  Fedora). You create and edit profiles in the UEFI menu, with an on-screen
  keyboard. Each profile has a "Use for" filter, shows a warning when a
  required answer is missing, and offers per-OS tweaks. Disk selection always
  stays manual. Commands from the profile run without console windows
  (`usos-run-hidden.exe`). Details: [answer-profiles.md](answer-profiles.md).
- **Themes and the theme editor.** Built-in themes: default, dark, light,
  high-contrast and retro. Three example user themes are included
  (`usos-ocean`, `usos-sunset`, `usos-forest`). The UEFI editor (Tools ->
  Theme) has a live preview and checks contrast as you edit. The BIOS menu
  also uses the colours of user themes. Details:
  [menu-themes.md](menu-themes.md).
- **27 languages** across the installer, both menus, micro-Linux, the XP
  helpers and WinPE. English is the reference. The other locales are marked
  as machine-translated in part or in full.
- **User drivers from DATA.** `DATA\Drivers\UEFI\<name>` holds drivers
  loaded by the menu, with a manifest, a watchdog and a toggle in Tools ->
  Drivers. `DATA\Drivers\<Windows>\{Storage,USB,Other}` holds INF packages
  that are staged for Windows 7/8/10/11 Setup and for the NT 5.2 profiles.
  The Vista and XP x86 folders are created but not used yet. Details:
  [drivers.md](drivers.md).
- **Linux ISOs from DATA** (`DATA\Systems\Linux\<Distro>\Images`). USOS
  boots the ISO's own kernel and initrd and maps the ISO file, so the distro
  starts as if from a DVD. This works on UEFI with Secure Boot off, on UEFI
  with Secure Boot on (the distro's own signed shim is relayed), and in
  Legacy BIOS. Tested with Ubuntu, Mint, Fedora, Debian live and netinst,
  SystemRescue, GParted Live and Clonezilla. Unknown Linux ISOs with a GRUB
  entry are marked "unverified". Details:
  [design/linux-iso-boot.md](design/linux-iso-boot.md).
- **XP and Vista without a firmware CSM (CSMWrap, experimental).** When the
  board has no CSM, USOS adds a small CSMWrap ESP at the end of the target
  disk. CSMWrap 3.1.2-usos1 is a quiet build with SeaBIOS as the CSM, and it
  boots the installed legacy system on every start. Windows 2000, Server
  2003 x86 and XP x64 use the same mechanism. Details:
  [design/csmwrap-integration.md](design/csmwrap-integration.md).
- **Windows 7 x64 without CSM.** UefiSeven plus the USOS Int10 dispatcher,
  which routes legacy VGA to the GOP graphics card. Details:
  [design/win7-vista-no-csm.md](design/win7-vista-no-csm.md).
- **Windows XP SP3 on modern UEFI boards with CSM.** The XP preparation
  runs from UEFI and ships a driver package: GenAHCI, StorPort, KMDF, a USB 3
  backport and a community ACPI 2.0 driver. PAE is turned on at the end of
  Setup, so the X470 test machine sees 31.9 GB of RAM.
- **Legacy BIOS toolbox.** FreeDOS 1.4 with Doszip, a Hardware & SMART panel
  (system information, disks and SMART, in micro-Linux), MemTest86+ (you
  supply the i586 ISO in `DATA\Utilities\MemTest86\Images`), MS-DOS 6.22
  and Windows 3.x, and Windows 98 SE through DOS Setup with the Patcher9x
  RAM fix.
- **Built-in UEFI Shell** (EDK2, MOK-signed) at Utilities -> UEFI Shell.
  DATA is mapped read-only, and your own EFI tools go in
  `DATA\Utilities\UEFI Shell\Tools`. Details: [uefi-shell.md](uefi-shell.md).
- **ROG Ally (RC71L) support in the UEFI menu.** Touch uses the bundled,
  MOK-signed TouchI2cDxe v1.3.1-usos1, which is loaded only on matching
  SMBIOS. Pad buttons work, and the footer shows dynamic A/B hints.

## Supported systems

Legend: **HW** = tested on real hardware (machines listed below), **VM** =
tested in QEMU/VirtualBox only, **exp.** = experimental (marked as such in
the menu), **untested** = the route exists but no run is recorded, **—** =
not supported (the menu shows the reason).

| System | Legacy BIOS | UEFI + CSM | UEFI without CSM | Secure Boot on |
|---|---|---|---|---|
| USOS menu itself | HW | HW | HW | HW (X470, Ally) |
| MS-DOS 6.22, Windows 3.1/3.11 | HW (Win 3.1 in standard mode, MS-7100) | — | — | — |
| Windows 98 SE | HW, partial (Setup up to first-boot preparation on the MS-7100; desktop not confirmed) | — | — | — |
| Windows 2000 SP4 | HW (MS-7100) | exp., VM (to text-mode copy; the X470 needs an NT 5.0 AHCI driver that is not included) | exp., VM (via CSMWrap) | — |
| Windows XP SP3 x86 | HW (MS-7100; no driver package, no PAE) | HW (X470, driver package, PAE) | exp., HW (X470, via CSMWrap) | — |
| Windows XP x64 SP2 | untested | exp., VM (to GUI Setup); X470: STOP 0xA5, see known issues | exp., VM (via CSMWrap) | — |
| Windows Server 2003 R2 SP2 x86 | untested | exp., VM (to GUI Setup); X470 untested with the 1.0 package | exp., VM (via CSMWrap) | — |
| Windows Vista SP2 x64 | HW (MS-7100) | HW (X470) | exp., HW (X470, via CSMWrap, legacy MBR install) | — |
| Windows 7 SP1 x64 | HW (MS-7100) | VM (full install); X470 with CSM not confirmed | HW (X470, UefiSeven + dispatcher) | — |
| Windows 8 / 8.1 | untested (WORK copy + chainload) | untested | untested | untested |
| Windows 10 22H2 | HW (x86, MS-7100) | HW (x64, X470) | same path as with CSM | VM (up to the Windows loader) |
| Windows 11 | untested | HW (user report 2026-09-13, WORK path with an answer file) | same path as with CSM | VM (up to the Windows loader) |
| Windows Server 2008-2025 | exp., untested | exp., untested | exp., untested | exp., untested |
| Linux ISOs (Ubuntu, Mint, Fedora, Debian, GParted, Clonezilla) | VM; HW Mint live (MS-7100) | HW (X470: Mint, Fedora, Debian netinst, Clonezilla, GParted) | same as with CSM | HW Fedora, Mint (X470); VM the rest |
| SystemRescue | VM | HW (X470) | same as with CSM | — (no signed boot loader) |
| FreeDOS, Hardware & SMART | VM (FreeDOS); HW (Hardware & SMART, first version) | — (BIOS menu only) | — | — |
| MemTest86+ (i586 ISO, user-supplied) | HW | — (use a `.efi` build from Utilities) | — | — |
| UEFI Shell | — | VM | VM | VM (starts; can't launch tools) |

UEFI with or without CSM only matters for the legacy paths (XP, Vista,
2000, 2003, Windows 7). Every other UEFI entry runs the same code in both
modes. Windows XP, Vista and 7 always need Secure Boot off.

## Hardware-tested configurations

**ASRock X470 (Taichi), Ryzen 7 5700X, Radeon RX 560, AMI Aptio.** Test
disks: Intel SSD 120 GB and Biostar S100 120 GB (SATA). Monitor: BenQ over
HDMI. This is the main UEFI test target.

| Result | Firmware | Build |
|---|---|---|
| XP SP3 PL clean install, 31.9 GB RAM with PAE, no extra restart | UEFI + CSM | B260925-155911-756B569B |
| XP SP3 EN unattended to the desktop, logo boot, no autochk | UEFI + CSM | B260925-190925-0D127F18 |
| XP answer screen: manual-install row and Back fixed | UEFI + CSM | B260926-105618-0E2F611F |
| XP SP3 PL unattended without CSM (CSMWrap ESP on the target) | UEFI, CSM off, SB off | B260927-153019-CF3402AF |
| Vista SP2 x64: install, USB in phase 2, OOBE, desktop | UEFI + CSM | B260927-130833-DC959455 |
| Vista SP2 x64 without CSM (legacy MBR, PE10 Setup with profile `vista-ultimate.ini`, boots without the stick) | UEFI, CSM off | B260927-205829-3C3E79FE |
| Windows 7 x64 (`WIN7X64.6in1.pl-PL.JULY2019.ISO`) to the desktop | UEFI, CSM off, SB off | B260926-134756-A6EF9DD9 |
| Windows 10 x64 native UEFI path (wimboot from ISO, answer file) | UEFI | B260925-084847-A23C795E |
| Answer-profile manager (create a profile, install with it), theme editor | UEFI | B260926-134756-A6EF9DD9 |
| Secure Boot: key saved straight into MokList from Setup Mode, then shim boots USOS with no MokManager | UEFI, SB on | B260924-202302-7ED55EB2 |
| Linux ISOs, SB off: Mint, Fedora, Debian netinst with profile, SystemRescue, Clonezilla, GParted. SB on: Fedora, Mint | UEFI | B260928-122908-E1145505 |
| Server 2003 x86 / XP x64: STOP 0xA5 at the start of text mode (see known issues) | UEFI + CSM | B260927-201324 |

**ASUS ROG Ally RC71L.** UEFI touch (tap, drag-to-scroll, touch
diagnostics), the pad with A/B hints, and Secure Boot MOK enrolment through
MokManager: all confirmed with build B260924-141634-EDC5E1F4.

**MSI MS-7100 (K8N Neo4 SLI Platinum, Socket 939, nForce4 CK804, Athlon 64
X2 4200+, Radeon X1950 Pro, Intel SATA disk, 2 GB RAM), Legacy BIOS.** This
is the retro PC. The docs call it both "MS-7100" and "Socket 939": they are
the same machine, not two.

| Result | Build / date |
|---|---|
| Windows 7 SP1 installed (BIOS) | B260910-193835-A2AE2C61 |
| Windows Vista installed (BIOS; the restarts during Setup needed a manual RESET) | 2026-09-12 |
| Windows 2000 SP4 working | 2026-09-12 |
| Windows 10 22H2 x86 working (BIOS, wimboot) | 2026-09-12 (release B260912-154813-9796550D) |
| Windows 3.1 installed; interface started in standard mode without SMARTDrive; file written and read back after a restart (386 enhanced mode not confirmed) | 2026-09-12 |
| Windows 98 SE Setup ran up to first-boot preparation; the next start stopped at the logo. A RAM fix (Patcher9x `mem`) followed; desktop not confirmed | 2026-09-12 |
| MemTest86+ 8.10 from Utilities | B260913-084102-08ED8D73 |
| SliTaz live desktop | 2026-09-13 |
| Windows XP BIOS staging (SATA through `sata_nv`, NT52 EDD boot sector) developed on this machine | 2026-09-09 |
| Linux Mint live desktop (BIOS menu, USB 2) | B260928-122908-E1145505 |

The fix for the garbled ISO names in the BIOS list (seen on this PC)
arrived in B260928-161042 and is not confirmed on this PC yet. FreeDOS has
not been started on physical hardware.

## Release assets

| File | Content |
|---|---|
| `USOS-Installer-1.0.0.exe` | Windows installer. It embeds the whole stick payload: install, update, repair, uninstall. |
| `USOS-1.0.0-WinPE-PE10-donor.zip` | PE10 donor (`PE10_x64_19041_USOS.iso`, WinPE 10 x64 with Setup, no install image). Vista and original Windows 7 need it on UEFI, and Vista needs it without CSM. Copy its `Programs` folder to the root of `USOS_DATA` (the file lands in `Programs\USOS\WinPE`), then run the installer's Update: it records the SHA-256 in `EFI\USOS\winpe-donor.ini`. |
| `USOS-1.0.0-XP-package-PL.zip`, `USOS-1.0.0-XP-package-EN.zip` | XP x86 SP3 UEFI package (micro-Linux preparation, driver bundle, `pae.exe`). Each one works with **exactly one** original ISO: PL `pl_windows_xp_professional_with_service_pack_3_x86_cd_x14-80476.iso` or EN `en_windows_xp_professional_with_service_pack_3_x86_cd_x14-80428.iso` (SHA-256 allowlist). The included `install-xp-package.ps1` (run as administrator) installs it to `EFI\USOS-XP` on the stick's ESP. Only one package can be installed at a time. The release packages carry no Server 2003 driver bundle. |
| `USOS-1.0.0-sources.zip` + `SOURCE-OFFER.txt` | Sources of the third-party components that are available locally (among them the modified CSMWrap 3.1.2-usos1 with SeaBIOS and its patches), and the written offer with the upstream source locations for the other (L)GPL components. USOS's own source is the git repository. |
| `LICENSE.txt`, `NOTICE.txt`, `CONTRIBUTING.md` | USOS's own licence (GPL-3.0-or-later), copyright notice and contribution terms. |
| `LICENSES/` + `THIRD-PARTY-NOTICES.txt` | Licence texts and notices of every bundled component. |
| `USOS-1.0.0-buildkit.zip` | Exact toolchains (Zig 0.16.0, Go 1.26.2, 7-Zip, Pillow) and pinned build inputs for an offline rebuild; see `docs/BUILDING.md`. |
| `SHA256SUMS` | SHA-256 of every file above. |

The release includes no Windows ISOs, no product keys and no activation
bypass. You supply every Microsoft medium yourself.

**Microsoft files in the release (deliberate decision).** The installer
payload carries Microsoft update and driver files (Windows 7 SHA-2, KMDF and
NVMe updates; the Vista KMDF update and USB 3 driver files), the XP packages
carry files derived from the matching XP ISO and community-modified
Microsoft drivers, and the WinPE donor is a Microsoft image. The maintainer
keeps them on purpose, for preservation, because the original downloads may
disappear. They are Microsoft's files, redistributed at the maintainer's own
risk and not covered by any USOS licence; they will be removed on request of
the rights holder. The menu icons were generated by the maintainer with
ChatGPT; they depict Windows and MS-DOS logos, trademarks of Microsoft. USOS
is not affiliated with Microsoft. Details: [LICENSES-AUDIT.md](LICENSES-AUDIT.md).

`USOS-1.0.0-buildkit.zip` holds the exact toolchains and pinned build inputs
(Zig, Go, Alpine, CSMWrap build VM inputs and the other cached downloads) to
rebuild this release offline: [BUILDING.md](BUILDING.md).

## Known issues

### Windows Vista: USB flash drives are not visible in the installed system

On boards with only USB 3 (xHCI) ports, such as the ASRock X470, Vista has
no USB 3 driver of its own. USOS installs a test-signed USB 3 backport so
that the keyboard and the mouse work. With that stack, USB flash drives and
other USB mass-storage devices don't show up in Explorer or Disk
Management. Keyboard and mouse are not affected. The cause is still being
investigated (logs from the X470 are pending).

Workaround:

- move files over the network (a shared folder on another PC), or through a
  second internal disk (SATA) or an optical drive;
- or fit a PCIe USB 3 card with a Renesas uPD72020x controller and install
  its vendor driver for Vista. Its own USB stack should also drive USB
  storage, and it is the only way to leave test mode on the X470.

### Windows Vista on X470 stays in test mode

The USB 3 backport is test-signed, so Vista x64 runs with test signing on
("Test Mode" on the desktop). See ROADMAP.md section 3.

### CSMWrap paths (XP, Vista, 2000, 2003, XP x64 without a firmware CSM)

- CSMWrap reserves one CPU thread for its BIOS proxy, so the installed
  system sees one logical CPU fewer.
- The graphics card needs a legacy VBIOS (a PC-AT image in its ROM). A
  GOP-only card or iGPU gives a black text-mode screen. Handheld iGPUs such
  as the ROG Ally's almost certainly lack one.
- Even on a quiet boot, a blinking text cursor shows in the top-left corner
  until the Windows loader changes the video mode. It needs another SeaBIOS
  patch.
- The target must be an MBR disk (up to 2 TiB), and it is wiped. CSMWrap is
  unsigned, so Secure Boot must be off.
- Vista without CSM needs a restart between the USOS disk preparation and
  Windows Setup.
- An empty `EFI\USOS\csmwrap-verbose.flag` on the stick brings back the
  full CSMWrap and SeaBIOS diagnostics.

### Secure Boot

- SystemRescue has no Secure Boot-signed boot loader. With Secure Boot on
  it is blocked in the list ("This ISO has no boot loader signed for Secure
  Boot"), so turn Secure Boot off to use it. On the X470 a firmware screen
  and a 30 s wait were also seen in this case. USOS doesn't load anything
  there in QEMU, and the cause isn't known yet.
- The UEFI Shell starts under Secure Boot, but it can't launch `.efi`
  tools. Unsigned tools fail verification. Signed ones get "The image is not
  an application", because shim 16 replaces LoadImage. Turn Secure Boot off,
  or put a signed tool in `DATA\Utilities\<Name>\Images` and start it from
  the USOS menu.
- The kernel is not locked down and the initramfs is not verified (planned:
  ROADMAP N6). Enrolling the USOS key trusts everything signed with it.
- An NVRAM reset (CMOS clear, some BIOS updates) removes the enrolled key.
  Enrol it again.
- On computers that have applied the DBX update for the Windows Production
  PCA 2011 (BlackLotus, KB5025885), older Windows 10/11 media won't start
  with Secure Boot on. Use media with the Windows UEFI CA 2023 boot manager,
  or turn Secure Boot off.

### NT 5.x on modern boards

- **Server 2003 x86 and XP x64 have no USB input on xHCI-only boards**
  (X470 and most current boards). NT 5.2 has no xHCI driver, and the USB 3
  port for Server 2003 is parked (STOP 0xDEADBEEF in QEMU). Use a PS/2
  keyboard, an unattended profile with a product key, or a Renesas
  uPD720201/720202 PCIe card with its official driver
  (`DATA\Drivers\Windows XP x64\USB\`). XP x86 SP3 is not affected, because
  its package carries the USB 3 backport.
- **STOP 0xA5 (ACPI_BIOS_ERROR 0x11, 0x8) on the X470** at the start of
  text mode for Server 2003 x86 and XP x64. The stock NT 5.2 ACPI.SYS can't
  parse that board's ACPI tables. For Server 2003 x86 a community ACPI
  bundle exists, but the 1.0 release packages don't include it. XP x64
  needs an x64 community ACPI driver that USOS can't redistribute (built
  from leaked source). You would have to supply it yourself, and USOS has no
  step yet to stage it. XP x64 has no non-ACPI HAL, so F7 is not an option.
- Windows 2000 from UEFI has no driver package. Boards with only AHCI need
  an NT 5.0 AHCI driver, which is not included.
- XP has no NVMe support, with or without CSM. XP in Legacy BIOS mode gets
  neither the driver package nor PAE (only the UEFI-CSM variant has them).

### Linux ISOs

- The Ubuntu Desktop installer showed "Something went wrong" under Secure
  Boot in QEMU (TCG only). The live desktop works. Still to check on
  hardware.
- The Ubuntu Server installer (subiquity) preselects the largest disk,
  which may be the USOS stick. Always pick the target yourself.
- A fragmented ISO can't be used by Debian netinst (its installer has no
  device-mapper). If USOS asks, copy the ISO again.
- Linux answer profiles work only on UEFI. The BIOS menu has no profile
  manager.

### Console windows during Windows Setup

- A console window (`winpeshl.exe`, about 1 s) flashes right after PE10
  starts, before Setup. It belongs to Windows PE itself.
- On Vista's first start, a "USOS - Vista USB diagnostics" console appears.
  It comes from the frozen v11 USB helper, which uses it to report USB
  errors.
- The BIOS wimboot and WORK starts still show Setup's own console windows.
  Only the PE10/WinPE paths with `/noreboot` use the hidden runner.

### General limitations

- AMI firmware lists **every mountable partition** of the stick as its own
  "UEFI: <stick>, Partition N" boot entry (ESP, DATA, WORK). USOS can't
  change this.
- The micro-Linux (disk preparation, Hardware & SMART, XP/Vista staging)
  needs an x86-64 CPU and at least 256 MiB RAM.
- Windows 98 and MS-DOS start only in Legacy BIOS.
- Windows Server 2008-2025 routes are experimental and have not been
  started from any Server ISO yet.

## Not tested yet

These items are built and pass the automated and QEMU checks, but have not
run on real hardware:

- Windows 7 SP1 retail ISO (`pl_windows_7_professional_with_sp1_x64_dvd_u_676944.iso`)
  through the PE10 donor.
- Windows Server 2008-2025 anywhere, on hardware or in a VM.
- Windows Server 2003, XP x64 and 2000 on the X470 with the 1.0 build (the
  earlier NT 5.2 run stopped with STOP 0xA5).
- Linux ISOs on hardware beyond round 1: Ubuntu Server/Desktop (Secure Boot
  on and off), Debian live, and the Linux fixes of B260928-134508 (no
  "Verification failed" before the relay, notices closing on any key).
- The last pre-1.0 polish (build B260928-193034-65E00BAD and later):
  - the hidden-console runner for profile commands (`usos-run-hidden.exe`,
    log `%WINDIR%\Panther\usos-hidden-commands.log`);
  - quiet CSMWrap 3.1.2-usos1 on the X470 (XP and Vista): no CSMWrap logo,
    no SeaBIOS banner, no "Press ESC";
  - Vista on UEFI with CSM using an answer profile;
  - the XP icon for XP x64 and Server 2003 on the X470 (UEFI and BIOS
    menus);
  - BIOS menu with user themes on hardware;
  - the BIOS image-list name fix on the MS-7100.
- XP via CSMWrap: the user still has to report PAE / 31.9 GB, the CPU count
  and USB.
- Secure Boot start of Windows 10/11 media on hardware (VM only, up to the
  loader).
- FreeDOS on physical hardware.

## Licence

USOS itself is free software under the GNU General Public License, version
3 or later (`GPL-3.0-or-later`): `LICENSE` and `NOTICE` in the release and
the repository ("Copyright (C) 2026 Maksymilian and the USOS Authors"). The third-party
components are separate programs aggregated with USOS and keep their own
licences (`THIRD-PARTY-NOTICES.txt`, `LICENSES/`). Contributions are
accepted under `CONTRIBUTING.md`.

## Credits and thanks

USOS stands on the work of these projects. The exact versions, hashes and
licences are pinned under `tools/vendor/` and listed in
`THIRD-PARTY-NOTICES.txt` and [LICENSES-AUDIT.md](LICENSES-AUDIT.md).

- **CSMWrap** (LGPL-2.1) with **SeaBIOS** (LGPLv3) as the CSM, shipped as
  the modified build 3.1.2-usos1. The source and patches are on the stick
  and on every CSMWrap ESP.
- **shim** 16.1 (Fedora build) and MokManager.
- **EDK2 / TianoCore**: the UEFI Shell (edk2-stable202002). **TouchI2cDxe**
  v1.3.1 (usos1 changes), an EDK2 I2C-HID touch driver.
- **UefiSeven** 1.30 (Int10h emulation for Windows 7 on UEFI).
- **efifs** 1.12 (the NTFS UEFI driver).
- **memtest86+** (supported, not bundled).
- **FreeDOS** 1.4 (kernel, FreeCOM), **Doszip**, **HimemX** 3.40.
- **Syslinux** 6.03 (MEMDISK), **wimboot** 2.9.0 from the **iPXE**
  project, **wimlib** 1.14.5, **ImDisk** 2.1.2.
- **Patcher9x** 0.9.91 (Windows 98 RAM fix), **PatchPAE3** (XP PAE),
  **GenAHCI** 6.3.0.1 (AHCI for NT 5.x).
- The community XP driver work used by the XP package (ACPI 2.0 driver,
  USB 3 backport and kernel extender). See `THIRD-PARTY-NOTICES.txt` for
  what is included and under which terms.
- **Alpine Linux** (the micro-Linux base), the **Linux kernel** (LTS),
  **BusyBox**, **systemd-boot**.
- **Zig** (menus, BIOS Core, micro-Linux tools) and **Go** (the installer).

Thanks also to the Linux distributions whose signed shims make the Secure
Boot relay possible, and to everyone who documents old Windows internals.
