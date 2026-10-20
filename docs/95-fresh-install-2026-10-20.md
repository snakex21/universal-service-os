# Windows 95 OSR2 fresh install on the X470 — findings and fixes, 2026-10-20

Fresh install from build B261020-111448-1F997795 onto the Micron 3400
(RTL9210B-CG enclosure), stock USOS answer (no profile), phase 1 in USOS's
QEMU, then CSMWrap on the X470. Working: USB mouse (buttons, wheel), USB
stick hot-swap (slight delay re-reading after a replug), shutdowns after
the first one. The logs were read from the disk read-only with a raw FAT
reader (disk signature 1876bb82, partition 1 WINDOWS95 0B02-B4A7 FAT32,
32 GiB at 1 MiB; partition 2 CSMWRAP).

## Common cause: 95 Setup ignores MSBATCH.INF [Install]

Evidence:

* SYSTEM.DAT / USER.DAT (and the VESA95 backup SYSTEM.V5 / USER.V5 from
  the end of phase 1) contain none of the values of `[USOS.Lan]`,
  `[USOS.Display]`, `[USOS.CsmReg]`, `[USOS.RunOnce]`: the machine Run key
  has only `internat.exe`, `SystemTray` and `ActiveMovie File Extensions`;
  no `USOSDisplay`, `USOSLan`, `USOSLog`; no `Internet Connection
  Wizard\Completed`; IE's Start Page is still Microsoft's; no Winlogon values.
  `[NameAndOrg]` did apply (RegisteredOrganization = USOS).
* SETUPLOG.TXT: 98 SE's has `MSBATCH.INF=10,,...` (Setup copies the answer
  into Windows and runs its sections); 95's has no MSBATCH.INF entry at all.
* The 2026-10-06 QEMU note already saw a symptom ("USOS.NoWelcome is not
  honoured on 95").

So on 95 every AddReg the answer carries is lost. This is the cause of
problems 1 and 2 and of the missing USOSLOG / USOSLAN.

## 1. Display at 1024x768 instead of Full HD

* `C:\USOS9X\DISPLAY.TXT` = `autoxauto`, no `DISPLAY.DONE`, no `USOSRES.LOG`,
  no `VBE.LOG` / `VBE.DAT`: USOSRES (and so the VBE collector USOSVBI) never
  started, because its Run value never existed.
* 1024x768 16-bit is VESA95.BAT's own mode (`VESA95.REG`:
  `Config\0001\Display\Settings` Resolution 1024,768, `DEFAULT\Mode`
  16,1024,768); VESA95.OK.
* Side finding: with `/P I` (NVMe opt-in) 95 now detects the PCI bus
  (DETLOG `*PNP0A03`), Setup bound the RX 580 (`PCI\VEN_1002&DEV_67EF`) to
  USOSVESA.INF as `Display\0001` and removed the legacy `*PNP0900`; the old
  `Display\0000` class key is an orphan. The VESA95 comment "95 never
  enumerates PCI" no longer holds for NVMe installs (no change made).

Not a 95 API limit: USOSRES is the same binary that works on 98 SE; whether
it picks 1920x1080 on 95 is unverified until it runs there.

## 2. IE starts the Internet Connection Wizard

* 95 OSR2's desktop "Internet" icon
  (`CLSID\{FBF23B42-E3F0-101B-8488-00AA003E56F8}\Shell\Open\Command`) runs
  `ICW-Internet Connection Wizard\icwconn1.exe` until the wizard finishes;
  the Start menu IE shortcuts point at IEXPLORE.EXE (IE 3, build 1155).
* The wizard ran in the first desktop session (S2 below): at 17:34:20-28 Dial-Up Networking
  (Start menu link), the Dial-Up Adapter (`Enum\Root\Net\0000`, NETPPP.INF,
  bound to TCP/IP) and PROTOCOL.INI appeared and AUTOEXEC.BAT / CONFIG.SYS /
  MSDOS.SYS were rewritten. `[OptionalComponents] "Dial-Up Networking"=0`
  had kept DUN out of Setup itself.
* USOSLAN: staged (`NETSETUP.TXT`: no NDIS 4 build, NDIS 5 not staged on
  95, "LAN helper staged: hardware desktop only"), but its Run value was
  lost the same way.

## 3. First shutdown hung at "Please wait while your computer shuts down"

* Sessions on the X470 (BIOS tick count of the first BOOTLOG line and file
  times): S1 from 17:30:46 (VESA95.BAT, USBREG.BAT, Start menu creation),
  S2 from 17:31:57 (BOOTLOG.PRV; first PnP pass, ICW network install), S3
  from 17:40:33 (BOOTLOG.TXT) until 17:42:08. S2's log ends at
  17:36:18 with the complete Windows terminate sequence (`EndTerminate =
  KERNEL`); the next start came 4 minutes later: S2 is the hung shutdown.
* So the hang came after Windows had finished its own shutdown, in the
  APM power-off / return-to-real-mode path, not in a program. Nothing of
  USOS was running in S2: no Run value existed (no USOSLOG watcher, no
  USOSRES, no pack runner: ADDONS.LOG "no package staged; runner not
  registered"). RunOnce held only Setup's own items.
* What was special about S2: the ICW network install with its restart
  request, and the first PnP pass (NVMe "restart required"). The APM
  breadcrumbs of CSMWrap live in CMOS and are read by the USOS menu; the
  Micron's ESP has no `EFI\USOS\Logs\apm-off.txt`, and S3's successful
  power-off overwrote the record. Root cause not proven; with ICW no longer
  reachable the S2 trigger is gone. If it recurs, the next run has USOSLOG
  (now started on 95) for the process side.

## Fixes (fix/w95-round1)

* `tools/w9x_reg95.sh`: for 95 with a USOS answer, the target writer turns
  the AddReg sections named in `[Install]` into `C:\USOS9X\REG95.REG`
  (REGEDIT4; HKCU -> `HKEY_USERS\.Default`, the 95 HKCU without profiles and
  the template of a new profile; HKCR -> `HKLM\SOFTWARE\Classes`; LDID,
  HKR and unsupported flags are left as comments) plus three 95 additions:
  the `USOSLog` Run value (INSTALL.BAT adds it at DOS time), the desktop
  Internet icon -> IEXPLORE.EXE when the LAN policy is on, and
  `Explorer\Tips` Show = 0 (no Welcome window; NoWelcome's RunOnce needs
  an INF 95 never copies). `REG95.BAT` imports it once from AUTOEXEC.BAT
  (real-mode REGEDIT, REG95.RUN/OK markers, Run key export REG95CHK.REG),
  after VESA95.BAT and before the first desktop.
* 98 FE: `[USOS.ChannelBar]` HKCU `Software\Microsoft\Internet
  Explorer\Main` Show_ChannelBand = "no". Source: 98 FE PL CD,
  shdocvw.dll 4.72 reads this REG_SZ and writes it as "yes"/"no".

Tests: `tools/tests/test_w9x_reg95.py` (conversion, DOS-safe batch, wiring,
98 FE section). Not run on hardware or in a VM yet.
