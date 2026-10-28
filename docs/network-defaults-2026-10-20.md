# Network defaults, 2026-10-20

Implemented on `codex/siec-9x-instalator`, based on
`9ca9d9a6a85dbed7a52c3c68cd75f6aac6cffd7d`. Host verification is separate
from a successful installation on physical hardware. No disk deployment or
full Windows VM installation was performed for this change.

## Policy and system differences

| System | Setup requests | Own Ethernet package | First hardware desktop |
|---|---|---|---|
| 95 | VREDIR + MSTCP, DHCP by default | usosnet4.sys (NDIS 4.0, usosnet95.inf) for a matching card, Setup /P I; never receives NDIS 5 (docs/usosnet-ndis4-2026-10-20.md) | IE LAN defaults and Favorite if IE exposes its Favorites folder |
| 98 / 98 SE | VREDIR + MSTCP, DHCP by default | Existing usosnet NDIS 5, only with matching Ethernet PCI ID and SYS/INF pair | EnableDNS, IE LAN defaults, Favorite, transport diagnostics |
| Me | Same | Same | Additionally removes exactly the inbox `*PNP8387` Dial-Up Adapter through SetupAPI |
| NT4 | Inbox MS Loopback + TCP/IP, Workstation; Server and Browser services disabled | usosnet4.sys takes over the loopback adapter (USOSNET.REG, POST.CMD) for a matching card; never receives NDIS 5 | IE settings in current and Default User profiles, Favorites, no network wait |
| 2000 | Microsoft client + TCP/IP; no MS_Server in NetServices | Existing usosnet, matching hardware only; OEM package and merged OemPnPDriversPath | IE settings and Favorites; existing `reg=` setup path seeds defaults too |
| XP x86, Server 2003 x86 (2026-10-22) | Same WINNT.SIF block as 2000 (a user .sif with its own network sections keeps them) | Same usosnet.sys + usosnet.inf in `C:\USOS\Drivers\USOSNET`, merged OemPnPDriversPath, `OemPreinstall` stays `No`, no `$OEM$` | LAN.REG imported at setup end: XP by `usos-users.cmd` (pae.exe), 2003 by `usos-setup.cmd`. XP x64 / 2003 x64: no amd64 usosnet build, nothing staged |

NT4's loopback uses `198.51.100.1/24`, **not a usable LAN address or DHCP
lease**. It keeps TCP/IP installed until an NT4-compatible NIC driver is
available. A loopback cannot obtain a LAN DHCP lease. It is independent of
the temporary VM's emulated NIC and is not presented as successful LAN.
The optional static LAN request is logged as deferred on NT4.

The staging address was corrected on 2026-10-22 after original NT4 PL Setup
reported TCPCFG string 25296. Its unattended validator rejects a zero in any
address octet, including the former `192.0.2.1`. Bounded x86 execution of the
original TCPCFG function at RVA `0x11562` rejects the old address and accepts
the replacement. POST still replaces the loopback configuration with the
requested LAN policy; this correction alone does not prove DHCP or LAN.

On 9x, Setup is requested to install MSTCP even with no NIC. PnP and the
inbox networking installer determine the resulting bindings. An unbound
transport is not usable LAN. Me's implicit Dial-Up binding is removed on
the first hardware desktop. The helper logs the actual MSTCP NetTrans keys
and configured addresses; no successful binding or DHCP lease is inferred
from the answer file. These no-NIC cases still need real Setup validation.

No file/printer sharing, VSERVER or new network service is requested. On
9x, Windows primary logon is paired with explicit AutoAdminLogon and the
profile username (USOS for the stock answer), with an empty initial password,
while retaining VREDIR. This corrects the previous assumption that primary
logon alone prevented the first Client-for-Microsoft-Networks logon prompt.
No extra menu questions
or manual first-boot actions were added. XP/2003 and routing policy are
outside this change.

## Profile

Advanced file keys, preserved when the UEFI editor saves a profile:

```ini
network=on
ip=dhcp
gateway=
dns=
home_page=about:blank
dialup=off
```

`network=off` leaves the old 9x answer bytes intact and skips staging and
the LAN helper. Missing fields select the new defaults. `dialup=on` only
opts 95/98/98 SE into Dial-Up Networking; Me always removes its Dial-Up
Adapter. Static example: `ip=192.168.1.20/24`, `gateway=192.168.1.1`,
`dns=1.1.1.1,8.8.8.8`. Prefixes 1–30, usable host addresses, a distinct
gateway in the same subnet and up to three DNS addresses are checked.
No leading-zero IPv4 components, multicast, loopback, command delimiters
or non-HTTP(S) home pages are accepted. A URL query containing `&` stays
in a data file; it never becomes a CMD or INF command.

9x static fields are native MSBATCH fields. W2K static addressing is
adapter-specific and is emitted only for exactly one actual matched NIC,
using the ID from its INF and `SpecificTo`. With zero or multiple matches,
the static request is logged as not applied; DHCP remains the safe Setup
default. W2K `network=on` owns the Networking/NetClients/NetProtocols/
NetServices sections; use `network=off` with a custom answer that owns
those sections itself.

## Keys and evidence

The sources below are Microsoft-authored deployment material, some
preserved by third-party archives, and a registry capture from the existing
Me test. No NT source code was needed for this work.

| Key / mechanism | System and effect | Source |
|---|---|---|
| Clients=VREDIR, Protocols=MSTCP, ValidatedLogon=0 | 9x client + TCP/IP without domain validation | [Microsoft MSDN sample](https://techshelps.github.io/MSDN/DNWIN95/HTML/S7376.HTM), Windows 98 CD Resource Kit BATCH98.CHM/BATCH.EXE |
| PrimaryLogon=Windows | 9x Windows primary logon with the client still installed | Original BATCH.EXE UTF-16 resource names and choices, including Windows |
| DHCP, IPAddress, **IPMask**, **Gateways**, DNSServers, Hostname | 9x addressing; these are not the NT SubnetMask/DefaultGateway field names | [Microsoft Q157267](https://www.betaarchive.com/wiki/index.php/Microsoft_KB_Archive/157267), BATCH98 |
| OptionalComponents Dial-Up Networking=0 | Avoid DUN and static-address binding conflicts; Me additionally needs runtime removal | [Microsoft sample](https://techshelps.github.io/MSDN/DNWIN95/HTML/S7376.HTM), [Microsoft Q190954](https://helparchive.huntertur.net/document/106241) |
| InstallAdapters=..., LOOP, InstallProtocols=..., TC | NT4 inbox loopback + TCP/IP | [Microsoft Q197302](https://www.betaarchive.com/wiki/index.php/Microsoft_KB_Archive/197302), [Microsoft Q155197](https://www.betaarchive.com/wiki/index.php/Microsoft_KB_Archive/155197) |
| OemPreinstall=Yes, OemPnPDriversPath | 2000 PnP package; retains other driver paths | [Microsoft OEM driver guide](https://learn.microsoft.com/en-us/troubleshoot/windows-server/setup-upgrade-and-drivers/add-oem-plug-play-drivers), SP4 CD SUPPORT/TOOLS/DEPLOY.CAB/UNATTEND.DOC |
| NetClients MS_MSClient, NetProtocols MS_TCPIP, AdapterSections, SpecificTo, InfID | 2000 explicit client/TCP and static adapter selection | Same original UNATTEND.DOC |
| HKCU Internet Settings EnableAutodial=0, NoNetAutodial=1, ProxyEnable=0, GlobalUserOffline=0; HKLM EnableAutodial=0 | IE4/5/5.5 LAN behavior | Successful Me `me-netcfg2/LANFIX.REG` capture, not a claim of testing every IE version |
| Internet Connection Wizard Completed = binary 01 00 00 00 | Existing ICW-completed behavior | Same Me LANFIX.REG; original IE deployment behavior needs per-OS hardware check |
| Internet Explorer Main / Start Page | about:blank or validated profile URL | Existing IE registry interface; direct registry write avoids command interpolation |
| Shell Folders Favorites; NT Default User NTUSER.DAT | Locale-aware 68k.news .URL placement; preserves an existing file | Existing OS shell registry paths; Default User locator reused from USOS's usos-reg design |
| NETPPP.INF *PNP8387; SetupAPI DIF_REMOVE with DI_QUIETINSTALL | Me Dial-Up Adapter removal without deleting registry trees or other adapters | Original Me PRECOPY1.CAB NETPPP.INF and the documented SetupAPI class-installer interface |

PnP is retained: no `IgnoreDetectedNetCards=1` and no fixed `NetCards=`
list. Driver IDs, `PollMode`, IRQ, ELCR and $PIR are unchanged. The INF is
the match authority, including SUBSYS/REV restrictions if present.

ICW completion, autodial settings, First Home Page and RunOnce welcome flags
are applied together. Localized desktop `.LNK` names are not guessed:
IShellLink/IPersistFile reads each shortcut's actual target without executing
or resolving it. Only an ICWCONN1.EXE target is removed; unrelated or unreadable
links stay. Common Desktop is checked on NT. OLE32 is loaded dynamically.
Confirm actual shortcut and IE behavior on the target versions.

DHCP with no explicit DNS keeps `EnableDNS=1` and the computer Hostname,
without inventing DNSServers. This allows DHCP-provided DNS; a lease and
working resolution still require hardware validation. NT4 disables Browser
as well as LanmanServer so the remaining service has no disabled dependency.

## Files, logs and execution

The initramfs builder builds own `USOSLAN9X.EXE` and `USOSLANNT.EXE`, GUI
PE 4.0, no CRT, static kernel32/advapi32 imports only. `stage_driver` copies
an optional unchanged SYS/INF pair; `network_setup.sh` only stages it after
matching actual PCI Ethernet hardware. States `missing`, `no_card`,
`unsupported`, `staged` and readback failures are logged.
Absence of an optional driver never prevents installation.

9x: `C:\USOS9X\NETCFG.INI`, `USOSLAN.EXE`, optional `NET\USOSNET.*` and
`LOGS\NETSETUP.TXT`. INSTALL.BAT places the pair beside Setup only when
both files exist, using the existing DevicePath=1 flow. The support builder
does not create an unused second driver stage. Selection and distribution
remain centralized in initramfs staging.

The DOS-native/RAM-disk route also carries USOSLAN.EXE. If NETCFG.INI has
not been staged, the helper creates its portable config beside itself from
the selected adjacent MSBATCH's own network/homepage metadata. Existing
NETCFG.INI takes priority. This makes the browser configuration available
on the native path without claiming a new native NDIS driver installation.

NT: `C:\USOS\NT4` or `C:\USOS\W2K`, `NETCFG.INI`, `USOSLAN.EXE`, `LAN.REG`,
`NETSETUP.TXT`. NT4 POST.CMD registers it after SP6; W2K's setup-end script
registers it. W2K also stages the optional OEM driver package under its
local source's OEM roots and in `C:\USOS\Drivers\USOSNET`, with readback.

HKLM Run `USOSLan` is used, not RunOnce: the helper exits in a VM and
retains Run. On hardware an early invocation waits up to five minutes for
relevant taskbar or RunOnce registry notifications. It pumps messages but
does not periodically poll readiness. Older systems without SetWinEventHook
can use one Explorer input-idle wait; timeout/unavailable notifications
retain Run for a later logon. See [original Microsoft startup ordering,
Q179365](https://ftp.zx.net.nz/pub/archive/ftp.microsoft.com/MISC/KB/en-us/179/365.HTM)
and [SetWinEventHook](https://learn.microsoft.com/en-us/windows/win32/api/winuser/nf-winuser-setwineventhook).

NETSTATE.DAT beside the helper stores a config fingerprint, completed steps
and an attempt counter. Only failed steps retry, for at most three attempts;
then Run is removed and the log records the incomplete result. Successfully
set IE/default-profile preferences are not overwritten on an ordinary retry
for a failed Favorite or adapter removal. A new config resets the state.
The addons runner's explicit `/refresh` reapplies browser/system defaults
after an IE/DUN installation; normal Run registration omits that argument.
Logs have a timestamp and attempt number. No service, task, console, network
traffic or restart is added.
An OS class-installer reboot requirement is logged and left to normal
shutdown. DNS/binding changes may only become effective after that boot.
No DHCP lease is asserted without a separate network test.

Only NETCFG/state/logs/helper files are private app data. OS registry preferences
and the user-requested Favorites are intentional system configuration.
NT's Default User hive is loaded briefly, seeded and unloaded; .DEFAULT is
not substituted for that profile. Existing other users are not migrated.

When integrating the display and addons branches, stage display, then network,
then addons. Each answer transform must consume the current staged MSBATCH.INF,
preserving prior removed Run entries. The addons review calls USOSLAN with an
explicit `/refresh` after its IE/DUN changes; that call and the persistent
NETSTATE logic must land together. There is no required ordering between the
ordinary Run entries: the explicit final refresh supplies the dependency.

## X470 verification to be performed by Claude

Host results: 562 Zig tests and the interactive x64 UEFI build passed;
98 selected Python tests plus the XP settings checks passed. The dedicated
LAN suite passed 20 tests, including native retry-state/file roundtrips,
notification/deadline/fallback behavior, verified-target matching and original-byte comparisons with
`network=off`, the default source/renderer match, all four driver/card
states, subsystem/revision matching, W2K static ambiguity, OEM path merge
and PE/import checks. The full answer-render regression passed after the
intentional 9x/NT4/W2K golden update. XP/2003 and routing goldens did not
change. Matrix golden removals are expected: W2K's baseline now already
uses usos-reg for LAN, so option deltas no longer add that common wrapper.

For existing Me, MSBATCH is too late. Copy the built 9x helper to
`C:\USOS9X\USOSLAN.EXE` and a validated CRLF NETCFG.INI with `system=ME`,
the fields above and `driver=staged`. Register that EXE under HKLM Run
`USOSLan`, using the existing authorized in-place mechanism. Leave the
working driver and PollMode alone. No full reinstall is needed.

Expected log: first hardware desktop; Me Dial-Up removed/absent; MSTCP
NetTrans entries and addresses; IE LAN defaults applied; Favorite. A failed
class removal or unresolved Favorites path is an incomplete result, not
success. Claude should collect the existing automatic USOSLOG NET section
to check binding, DHCP, DNS and HTTP. USOSLOG itself is not added to Setup
by this task. No user DIAG command or photo is required.

Second pass: fresh 98 SE with matching I211, plus a no-NIC/unsupported-NIC
case when practical. Confirm VREDIR/MSTCP present, DUN absent, no Server
sharing, automatic logon without the initial password dialog, IE opens
without ICW/dialer, and DHCP plus `68k.news` resolution work in the first
hardware session. Confirm the helper starts in that session and disappears
from Run after success or its third failed attempt. Change the homepage after
an IE-success/Favorite-failure run and confirm a later retry preserves it.
On NT4 check absence of the Browser dependency startup error. Then verify static
IP on exactly one NIC and the normal subsequent reboot. Run 2000 and NT4
separately; host tests do not replace those checks. The existing usosnet
20 ms polling/IRQ issue remains Claude's separate driver work.
