# Server 2008 R2, Server 2012 R2 and Embedded 8.1 Industry (2026-10-08)

New media in the library (`OS\Windows\Windows Server 2008 R2`,
`Windows Server 2012 R2`, `Windows Embedded 8.1 Industry`), wired into the
existing menu paths. Branch `feature/srv-modern`.

## What each system uses

| System | Menu entry | UEFI path | Product key |
|---|---|---|---|
| Server 2008 R2 SP1 VL x64 (Standard / Enterprise / Datacenter / Web, full + Core) | Servers: Windows Server 2008 R2 (existing, `route_as windows-7`) | Windows 7 native start: PE10 donor, Setup 7601 from the ISO; installed system through the Int10 dispatcher (with or without CSM) | none (Setup has no key page) |
| Server 2012 R2 Foundation / Storage Server 2012 R2 (Standard, Workgroup) x64 | Servers: Windows Server 2012 R2 (existing, `route_as windows-8-1`) | **new**: Windows 8.1 native start (the ISO's own WinPE 5.0 through wimboot, ESP guard and finalizer), like Windows 10/11 | **required**: no public setup key exists for these editions; Setup stops with "cannot read the ProductKey setting" without one |
| Embedded 8.1 Industry Pro x64 | Windows list: **new** entry Windows Embedded 8.1 Industry (UEFI only, `route_as windows-8-1`) | Windows 8.1 native start | required by Setup; the public KMS client setup key of the edition installs it (`key.windows-embedded-8-1-industry` in the profile) |
| Embedded 8.1 Industry Pro x86 | same entry | blocked on 64-bit UEFI ("32-bit image"); no 32-bit modern Windows path without CSM exists | - |

Windows 8.1 itself now takes the same native start on UEFI; BIOS keeps
the WORK copy (profile `win81-bios-chainload`). Windows 8 / Server 2012
are unchanged (WORK copy).

## Answer changes

* Server: `DoNotOpenServerManagerAtLogon` (2008 R2+) and
  `DoNotOpenInitialConfigurationTasksAtLogon` (2008 / 2008 R2) in
  specialize; Administrator password from the profile (unchanged).
* Server default edition: no edition and no key in the profile =
  Standard full installation when the ISO has it (2008 R2 VL: image 1).
* An ISO with one install image always names it (8.1 Setup showed its
  one-line edition list otherwise).
* 8 / 8.1 / 2012 / 2012 R2 / Embedded 8.1 without a key: the profile row
  and summary warn ("Setup stops on the product key page").

## Fixes found by the QEMU runs

* `usos-source` scanned PhysicalDrive0..63; WinPE 5.0 on QEMU's NVMe
  controller listed 255 empty namespace disks first. Now 0..255. (The
  e2e runs use an AHCI target: the phantom disks also made Setup's disk
  page hang.)
* The native test stick had an MSR first; WinPE before Windows 10 1703
  mounts only the first partition of a removable disk, so the ESP guard
  saw no stick ESP. The test stick is now ESP-first like the installer's
  layout (`new_native_stick.ps1`).
* WinPE 5.0 listed no volume for the ESP that 8.1 Setup created on the
  target disk. The finalizer now adds GPT ESPs from the drive layouts that
  no listed volume covers (`\\?\GLOBALROOT\Device\HarddiskN\PartitionM\`,
  DOS device name when a letter is needed); new diagnostic verb
  `usos-modern-finalize volumes`.

## QEMU e2e (OVMF without CSM, AHCI target, stick on xHCI)

* **Embedded 8.1 Industry Pro x64**: profile with the public setup key;
  Setup from the ISO, edition page (fixed since), disk page (manual by
  design), install, finalizer PASS ("target boots on its own; USOS stick
  ESP unchanged"), first boot, OOBE stopped once on the 8.1 "Settings"
  (express settings) page although `ProtectYourPC=3` is answered, then the
  lock screen and the Start screen as Tester. WHPX hung on WinPE reboots
  and on the installed 8.1 kernel; the first boot ran under TCG.
* **Server 2012 R2 Foundation / Storage**: the native start works (PE 5.0,
  Setup from the ISO, summary lists the editions and warns about the key);
  Setup then stops on the missing product key. No key available: not
  installed.
* **Server 2008 R2 SP1 VL x64**: summary "Edition: SERVERSTANDARD (image
  1)", PE10 donor; Setup went straight to the disk page (no key, edition
  or license page) and installed; see the status below for the first boot.

Open: the 8.1 express-settings page; the summary calls the 2008 R2 full
installation "Desktop Experience" and the Foundation image "Other";
Embedded 8.1 x86 and 32-bit Windows on 64-bit UEFI without CSM; X470
hardware test.
