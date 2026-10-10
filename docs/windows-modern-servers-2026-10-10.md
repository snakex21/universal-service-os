# Web Server 2008, Home Server 2011, Server 2012 R2 key, 32-bit without CSM (2026-10-10)

Branch `feature/srv-modern2`. Follows
[windows-modern-servers-2026-10-08.md](windows-modern-servers-2026-10-08.md).

## Media (OS library)

| ISO | Arch | DATA folder |
|---|---|---|
| Windows Web Server 2008 SP2 (6002.18005) PL x64 | x64 | `Systems\Windows\Windows Server 2008\Images` |
| Windows Web Server 2008 SP2 (6002.18005) PL x86 | x86 | (no path without CSM yet; see below) |
| Windows Home Server 2011 (7601.17514) EN x64 | x64 | `Systems\Windows\Windows Home Server 2011\Images` (new entry; older builds: `Windows Server 2008 R2\Images`) |
| Storage Server 2012 R2 + Server 2012 R2 Foundation (9600.17415) PL x64 | x64 | `Systems\Windows\Windows Server 2012 R2\Images` (needs a key) |

## Windows Web Server 2008 SP2

Server 2008 is routed as Vista. Without CSM the menu picks the Vista CSMWrap
variant (`vista-x64-sp2-uefi-csmwrap`): micro-Linux step 610 prepares an MBR
disk with the PE10 staging partition and the CSMWrap ESP, the disk then
starts PE10 in BIOS mode and Setup installs a legacy system that boots
through CSMWrap (as Vista, hardware PASS 2026-09-28).

Fix: the probe read Server 2008 media as client media ("belongs in
Systems\Windows\Windows Vista"). Its install.wim has no `EDITIONID` and no
`INSTALLATIONTYPE`; the edition id is in `FLAGS` (`SERVERWEB`) and the
Server Core image is the same `SERVERWEB` with "Server Core" in its name.
`windows_media.parseInstall` now falls back to `FLAGS` (as
`flow/answer/editions.zig` already did) and both readers treat a
`PRODUCTTYPE ServerNT` image named "Server Core" as Core (profile edition
"Web Core" selects image 2, "Web" image 1).

x86: blocked on 64-bit UEFI like Vista x86 (`needs_32bit_uefi_or_bios`).
See "32-bit Windows without CSM".

## Windows Home Server 2011

The ISO boots its own WinPE 3.1 with `sources\wpshell.exe` (winpeshl.ini),
a custom wizard that checks the hardware (160 GB disk, RAM, CPU), wipes the
chosen disk and builds an unattend file from
`sources\Unattend_template.xml` (60 GB system partition + data partition,
GPT with MSR on UEFI, autologon Administrator) before it starts the normal
`setup.exe /unattend`. The documented way around the checks is the OEM
`cfg.ini` (`[WinPE]` section, `CheckReqs=0`, `ConfigDisk=...`) on the root of
any drive.

USOS does not need either: the new entry **Windows Home Server 2011**
(UEFI only, `route_as windows-7`) takes the Windows 7 native start, where
the PE10 donor runs the ISO's `sources\setup.exe` directly. wpshell never
runs, so there is no 160 GB check and no automatic disk wipe; the Biostar
S100 (120 GB) is not a blocker. Setup is the plain Server 2008 R2 Setup
(language, edition `ServerHomePremium`, license, disk page). Recommended
layout, as wpshell would make it: a 60 GB (61440 MB) partition for Windows,
the rest left for the data partition. The image's own
`Windows\Setup\Scripts\SetupComplete.cmd` and the Windows Server Solutions
first-logon configuration run as on a normal install.

QEMU e2e (OVMF without CSM, q35, TCG, 120 GB AHCI target, stick on xHCI;
the WHS ISO was in the `Windows Server 2008 R2` folder, i.e. the existing
2008 R2 entry, which takes the same path as the new entry): USOS menu ->
PE10 -> Setup (English, ServerHomePremium, license) -> manual 60 GB
partition (Setup made ESP + MSR + 60 GB, 60 GB left unallocated) -> install
-> phase 2 through the Int10 dispatcher -> logon screen "The user's
password must be changed" (as 2008 R2) -> new Administrator password
(PS/2 keyboard: the system has no xHCI driver) -> desktop -> the WHS wizard
"Set Up Windows Home Server 2011" stops with **"A network device driver was
not found"** (the VM had no NIC). The WHS configuration needs a working
network adapter: on the X470 the onboard NIC driver (2008 R2 / Win7 x64
package) must be in `Drivers\Windows Home Server 2011` (or loaded through
the wizard's "Install network drivers" button). Not re-run with a NIC.

Open for WHS: USB 3 (as 2008 R2), Administrator password from the profile
(as 2008 R2), NIC driver on the X470, the data partition (the wizard's
storage step was not reached).

## Server 2012 R2 (Foundation / Storage Server)

No `ei.cfg`, no `PID.txt` in the ISO, nothing in the OS library README and
no key file in `%LOCALAPPDATA%\USOS\test-assets\private-keys`. Setup stops
on the product key page without one; these editions have no public setup
(KMS client) key. Needed from the user: a Foundation or Storage Server 2012
R2 key (OEM), for the profile's key field (hardware) or the private-keys
folder (QEMU test).

## 32-bit Windows without CSM (Vista / 2008 x86, 8.x x86, 10 x86)

The X470 firmware is 64-bit UEFI only, so 32-bit Windows can only start
through a legacy BIOS, here CSMWrap. Feasibility:

* **Windows 8.x / 10 x86**: good. Their own WinPE has xHCI, AHCI, NVMe and
  input, so no donor is needed: stage the ISO's `boot.wim` (x86) on the
  target like the Vista CSMWrap staging partition, boot it through CSMWrap,
  run Setup in BIOS mode; the installed system boots through CSMWrap
  (one CPU core reserved by CSMWrap; display through the card's VBIOS).
  Needs: x86 builds of the USOS WinPE helpers (installer, finalizer), a new
  profile next to `vista-x64-sp2-uefi-csmwrap`, golden rows. Medium effort.
* **Vista / Server 2008 x86**: the same staging, but Vista's WinPE has no
  xHCI driver (no input on the X470). Needs an x86 PE10 donor (the user's
  Windows 10 22H2 x86 ISO boot.wim fits) plus x86 helpers and an x86 USB 3
  package for the installed system. Larger effort.

Recommendation: do 8.x / 10 x86 first (one new x86 CSMWrap profile, no
donor), then reuse it for Vista / 2008 x86 with an x86 donor. Not
implemented in this round.
