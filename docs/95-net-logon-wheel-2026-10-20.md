# Windows 95 fresh install: network by registry, Windows Logon, wheel (2026-10-20)

Branch `int/9x-final` (on top of `fix/w95-round1` + `feat/usosnet-95-nt4`).
Status: host tests pass. **Not yet run as a fresh 95 install (QEMU or X470).**

## Network card without the New Hardware wizard

What the branches had: `feat/usosnet-95-nt4` staged `usosnet95.inf` +
`usosnet4.sys` and gave 95 Setup `/P I`, so 95's PnP finds the I211 and
installs it from the INF. Nobody had checked that path. Two open points: does
95 OSR2 install a new PCI card on the first desktop without a dialog (the
OSR2 Update Device Driver Wizard), and does it bind TCP/IP and the client to
the card. The X470 in-place kit 95-net (PASS) did not use PnP at all. Before
Windows started, it wrote the registry that the 95 installers would write.

Decision: the fresh install does the same as the kit, and keeps the INF as
the fallback.

* `tools/network_setup.sh` `usos_net_w95_stage` (95, exactly one matched
  card): `C:\USOS9X\NET\NET95.REG` (`usos_net_w95_reg`) contains:
  * the devnode `Enum\PCI\VEN_8086&DEV_1539\<instance>`, bound to
    `Class\Net\0009` (the usosnet95.inf AddReg values plus its
    Advanced-tab parameters);
  * TCP/IP `NetTrans\0009` (DHCP) for that card;
  * Client for Microsoft Networks `NetClient\0009` with the MSNP32
    provider, without file and printer sharing.

  The values match the kit's NET95.REG. The differences are the instance
  numbers (0009, so they never collide with Setup's 0000-0002), English
  descriptions, and no MS help texts.
* The devnode instance comes from the card's PCI path in the micro Linux
  (`usos_net_w95_instance`, sysfs `cd -P`). 95 OSR2 names root-bus devices
  `BUS_bb&DEV_dd&FUNC_ff`. A device behind a bridge gets the devfn bytes from
  the card up to the root-bus bridge, followed by the root bus number. I
  worked this out from the X470 95 registry (95-fresh2, read-only): I211
  `0008020B00`, NVMe `0020020B00`, GPU `001900`, `BUS_00&DEV_18&FUNC_03`.
  If the PCI path is missing or more than one card matches, no NET95.REG is
  written. The card then comes from PnP + INF as before, and the reason is
  logged in `NETSETUP.TXT`.
* `tools/w9x_reg95.sh`: NET95.REG is merged into REG95.REG (one real-mode
  REGEDIT import, before 95's first PnP pass on the PC). REG95.BAT then
  exports `C:\USOS9X\NET\C1..C3.REG`, checks them with FIND, and writes
  `NET95.OK` or `NET95.ERR`. These are the same evidence files as the kit.
* A static IP from the profile is not applied on 95 yet: NET95.REG uses
  DHCP, and the log says so.

## Logon dialog on the first start

The 95 PWL approach (the Me empty-password list) was **not** taken: no
password-list file is generated or seeded for 95.

Changed for every USOS-made 95 answer:
* REG95.BAT deletes `Network\Logon` (REGEDIT /D, as the kit did).
* REG95.REG writes Windows Logon as the primary logon: `ProcessLoginScript`
  1, `LMLogon` 0, no `PrimaryProvider`. 95 Setup had left `PrimaryProvider
  "Microsoft Network"` there, although MSBATCH asks for
  `PrimaryLogon=Windows`.
* The user name is the answer's Winlogon `DefaultUserName` when there is one.
* Evidence file: `C:\USOS9X\REG95LGN.REG`.

What may remain: one Windows Logon dialog on the very first start. On 95 that
dialog creates the user's password list, and nothing here creates one. The
kit state (Windows Logon, client installed) started without a dialog on the
X470 after the user had answered it once.

## Wheel on 95

95 USER has no WM_MOUSEWHEEL.
* USOSMOUS.DRV tells 95 from 98 by INT 2Fh AX=160Ah (BX 0400h). Both report
  DOS 7.10. On 95 it never calls USER's event procedure with AX=0800h and
  does not report msExists 4Bh; the notch counter runs as on 98.
* USOSKEY.DRV (`wheel_decide95`) handles each notch one of two ways:
  * if there is a WS_VSCROLL window under the pointer (or one of its
    parents), that window gets WM_VSCROLL, whether it is Win16 or Win32;
  * otherwise the registered `MSWHEEL_ROLLMSG` is posted to the window under
    the pointer.

  95 OSR2's COMCTL32.DLL and IE 3's SHDOCVW.DLL / MSHTML.DLL register that
  message. I checked this with a string search in the user's 95 OSR2.1 PL
  files; it has not been tested in 95. SYSTEM.INI `[usosmous] MSWheel=0`
  turns the message off.

## Materials

Own code. Facts come from the user's 95 OSR2.1 PL media and from registries
read back from the X470 install. These were read-only, and no Microsoft file
or text was copied.
