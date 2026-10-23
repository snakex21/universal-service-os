# Winsock for Windows 3.1 / WfW 3.11 on the X470 I211 - options (2026-10-23)

Research note, no code. Question: how Windows 3.1 and Windows for Workgroups
3.11 (MS-DOS 6.22 on CSMWrap/SeaBIOS, X470 Master, Intel I211) get a
`WINSOCK.DLL` (Windows Sockets 1.1) so Win16 applications and browsers use
TCP/IP, building on USOSPKT.COM (`docs/dos-usospkt-2026-10-23.md`, own
GPL-3.0-or-later packet driver, ~42 KiB resident incl. the 34 KiB DMA block)
and mTCP (GPL-3.0). Policy: Microsoft and other third-party files are never
in git; user-supplied or a separate compat-pack asset only if the licence
allows; otherwise our own implementation.

"Unverified" = not confirmed from a primary source in this round.

## Facts that shape every option

1. **Register access under Windows 386 enhanced mode.** WIN386 runs all DOS
   code (USOSPKT's ISR and `send_pkt`) in V86 mode. USOSPKT's MMIO path needs
   real mode (`unreal`, `usospkt.S` ~l.541, refuses in V86), so **inside
   Windows enhanced mode only the I/O BAR path works**. X470 evidence: the
   MS-DOS 6.22 FULL PASS of 2026-10-23 (build B261023-122630-A5B5CCA3) ran
   USOSPKT through the I211 I/O BAR (project status notes of that hardware
   run; the raw `C:\NET\USOSPKT.LOG` line was not re-read for this note), so
   this gate is very likely open on the X470 under CSMWrap; other boards may
   leave the BAR unassigned. It is the first gate for every real-mode option
   (packet driver, NDIS2). Only a ring-0 VxD (NDIS3 MAC or an MMIO helper
   VxD) is independent of it.
2. **Standard mode (Windows 3.1 default menu item).** Trumpet's own manual
   says packet drivers are reliable only in enhanced mode with WINPKT;
   standard mode "can be used" with care (Trumpet 3.0 manual, see sources).
   TCP/IP-32 is enhanced-mode only (VxD). So a Winsock on Windows 3.1 means
   the 386-enhanced menu item, unless we write our own DLL that avoids
   real-mode upcalls (option A3).
3. **Receive upcalls.** A packet driver calls its client's receiver
   (far call, AX=0/1) from the ISR. Under WIN386 the ISR can run in any VM
   (global IRQ reflection), but a Windows client's receiver lives in the
   system VM: this is what WINPKT solves (it defers the upcall into the
   right VM). Trumpet's manual requires WINPKT "or a substitute" and has an
   error string for a missing "WINPKT or PKTDRV virtual packet driver".
4. **DMA under WIN386.** USOSPKT's DMA block is in global DOS memory loaded
   before Windows; its physical address is taken at load time (VDS under
   EMM386, else seg*16). Global V86 memory below the first-VM boundary is not
   moved or paged by WIN386 (expected behaviour, unverified on our setup);
   loading USOSPKT high (UMB) is the risky case (EMM386 remap handed over to
   WIN386 via GEMMIS) - keep it low for Windows.
5. **Toolchain we already have.** OpenWatcom 2.0 (pinned snapshot,
   `tools/build_win3_usb_keyboard.py`) already builds our Win16 drivers
   (USOSMOUS.DRV etc.) and an LE VxD (`USOSVMD.VXD`, `wasm` + `wlink`,
   `src/platform/win9x/usosvmd.lnk`). So Win16 DLLs and 3.1-style VxDs need
   no MASM/DDK purchase; only headers/service tables have to be written by us.
6. **usosnet** (`tools/nt/usosnet`) is a PE `.sys` NDIS 5.0/4.0 miniport
   (98/Me/2000/XP; 95 OSR2/NT4 via `usosnet4.sys`) plus NDIS 3.0 builds for
   NT 3.5/3.51 and an NT 3.1 NDIS 3.0 **full MAC** (`src31/usosnet31.c`).
   WfW 3.11 cannot load PE `.sys` drivers (its NDIS 3.0 MACs are `.386` LE
   VxDs), so none of these binaries runs there; the igb backend
   (`usosnet_igb.c`) and the NT 3.1 full-MAC logic are reusable source.

## 1. Winsock DLL over the packet driver

| candidate | licence / status (evidence) | redistributable by USOS | std / 386enh | needs WINPKT |
|---|---|---|---|---|
| **Trumpet Winsock 2.0b / 3.0** (Peter Tattam, TSI; rights bought by Tattam Software Enterprises 2008) | Shareware, 30-day evaluation, then registration. 3.0 manual sec. 1.5: the licence "does not allow You to resupply the software". Still sold as shareware by Tattam Software (Wikipedia). Trumpet sued OzEmail (1996) over cover-disk distribution of 2.0b. | **No** - user-supplied only (user registers it). | Enhanced reliable; standard "with care" (manual). | Yes (or substitute; NDIS3PKT replaces it) |
| **WINPKT.COM** (Joe R. Doupnik, Utah State Univ., 1992; Crynwr-era shim) | Shipped as "source code, doc, and executable" in winpkt.zip (Doupnik's wfw.txt). Licence text **unverified** (the Crynwr collection ships the FSF GPL as COPYING.DOC, but WINPKT is not in the Crynwr manifest checked). Author warns of modified copies circulating. | Unknown until the original winpkt.zip licence is read; an own replacement is small (see A1). | Enhanced (its purpose) | - |
| **NDIS3PKT.386** (Dan Lanciani) | VxD giving a packet-driver interface over NDIS 3.0/3.1 (WfW 3.11, Win95), replaces WINPKT. Licence (quoted on VOGONS, unverified at the author's site danlan.com): free for personal/internal business use only, no for-profit distribution, demo + paid full version. | No | Enhanced | No (replaces it) |
| **Twinsock** (Troy Rollo) | GPL; a Win16 WINSOCK.DLL that proxies calls over a serial line to a Unix helper. Source location (corvu.com.au) offline, archive copy unverified. | GPL - yes, but it is not a TCP/IP stack. | n/a | n/a |
| **Wine `winsock.dll16`** | LGPL; 16-bit thunks to Win32/host sockets. | Yes, but unusable on real Win 3.x (no backend). | n/a | n/a |
| **WATTCP / Watt-32** | Free (Watt-32 licence in LICENSE.H); DOS TCP/IP library over packet drivers. No Win16 WINSOCK.DLL built from it was found. | Library only | - | - |
| **mTCP** (M. Brutman) | GPL-3.0; DOS tools only, no Win16 Winsock and no stated plans found. | Yes (code base for A3) | - | - |
| FTP Software PC/TCP / OnNet, NetManage Chameleon, Novell LAN WorkPlace (ODI), Sun PC-NFS, WRQ Reflection | Commercial; packet-driver/NDIS/ODI support per product (details unverified). VOGONS: Chameleon 4-disk install, <500 KB conventional memory left. | No - user-supplied only | mostly enhanced | product-specific |
| 2020s hobby Win16 Winsock over a packet driver | **None found** (GitHub/VOGONS searches this round). | - | - | - |

## 2. Microsoft TCP/IP-32 3.11b (WfW 3.11 only)

* 32-bit VxD TCP/IP stack with WINSOCK.DLL for **WfW 3.11**; `tcp32b.exe`,
  ~696 KB, distributed free by Microsoft (WinWorld listing). Its EULA /
  redistribution text was **not checked** - per policy: user-supplied, or a
  compat-pack asset only after a licence review; never git.
* Binds to WfW 3.11's NDIS 3.0 (`NDIS.386` + a `.386` MAC). PC Week 1994:
  needs the NDIS-3 drivers for NetBEUI and TCP/IP to coexist. Whether it binds
  to a **real-mode NDIS2 MAC** under WfW 3.11 is **unverified** (forum reports
  show NDIS2 drivers working in WfW 3.11, none confirms TCP/IP-32 on them).
  Cheap check: QEMU NE2000 with WfW's own `NE2000.DOS` (NDIS2) chosen as the
  real-mode driver, then add TCP/IP-32 (Codex QEMU task, QEMU only).
* Also gives the WfW Microsoft Network client over TCP/IP (NetBT).
* **Not for plain Windows 3.1**: it needs WfW 3.11's network components
  (one user on VOGONS: "no way to install" on 3.1). Windows 3.1 options from
  Microsoft: MS Network Client 3.0 for MS-DOS (NDIS2, real-mode TCP/IP,
  NetBEUI, NWLink; TechNet setup guide). A Windows Sockets add-on for it is
  mentioned on VOGONS, but one user could not install it on plain 3.1 -
  **unverified**, do not plan on it.

### Our own MAC for TCP/IP-32

| | NDIS2 real-mode MAC (`USOSNDIS.DOS`) | NDIS 3.0 VxD MAC (`USOSNET.386`) |
|---|---|---|
| spec | NDIS 2.0.1 Final (3Com/Microsoft, Oct 1990) - transcription on EDM2 | WfW 3.11 NDIS 3.0 = NT 3.1 NDIS 3.0 API, but called as VxD services of NDIS.386; the service table (ordinals) is in the non-free WfW/Win95 DDK - we must derive it (Win95 DDK docs or analysis of the user's NDIS.386; provenance to be recorded) |
| code reuse | USOSPKT 16-bit hardware code (reset, iNVM MAC, PHY, rings, ISR) almost 1:1 | `usosnet_igb.c` + NT 3.1 full-MAC logic (`src31/usosnet31.c`), recompiled with OpenWatcom 32-bit flat |
| new work | device header, PROTMAN registration (IOCTL to PROTMAN$), characteristics tables (common/specific/upper dispatch), `Bind`, `TransmitChain`, `ReceiveLookahead`/`IndicationComplete`, `GeneralRequests`, PROTOCOL.INI parser, OEMSETUP.INF for WfW | DDB + control proc (3.1 style), NdisRegisterMac / adapter open / send / indicate, MapPhysToLinear for MMIO, VPICD IRQ, OEMSETUP.INF |
| I/O BAR needed | yes (V86 under WIN386) | **no** (ring 0 MMIO) |
| conventional memory | ~40 KiB (same DMA block) | none |
| also serves | MS Network Client 3.0 (DOS), LAN Manager, DIS_PKT | only WfW 3.11 (Win95 has its own path: usosnet4) |
| risk | TCP/IP-32-over-NDIS2 unverified | NDIS.386 service ordinals/semantics, VxD debugging only by log |
| effort | 8-12 person-days + X470 | 15-25 person-days + X470 |

## 3. Packet driver -> NDIS2 shim

No direct shim found. Shikadi's shim index (10 shims) has only the opposite
direction (**DIS_PKT** = NDIS2 -> packet driver; Doupnik / Lanciani,
FTP Software 1991 copyright in the v1.11 banner, licence unverified) and
**PDETHER** (packet driver -> ODI MLID, licence not stated). A chain
USOSPKT -> PDETHER -> Novell LSL -> ODINSUP (ODI -> NDIS2) is theoretically
possible but needs Novell LSL/ODINSUP (not redistributable), costs more
conventional memory and is fragile. ODI is otherwise only relevant for Novell
LAN WorkPlace (commercial). Not recommended.

## Recommendation (one path)

**Packet-driver Winsock path, enhanced mode, in two milestones:**

* **M1 (3-5 person-days + one X470 run): Windows-aware USOSPKT + user-supplied
  Trumpet.**
  - X470 gate: the I211 I/O BAR was used in the MS-DOS hardware PASS (fact
    1); re-read `USOSPKT.LOG` on the first Windows run (no BAR = this path
    needs a ring-0 MMIO helper VxD, +4-6 days, see risks).
  - Own WINPKT-equivalent (GPL, either inside USOSPKT `/W` or a small
    `USOSVPKT.COM`): register with WIN386 through the INT 2Fh 1605h startup
    broadcast, deliver receive upcalls into the client's VM through INT 2Fh
    1685h (switch VMs and call back), keep the ISR in global memory. Use the
    original WINPKT only if its winpkt.zip licence permits; detection of
    "WINPKT present" by Trumpet must be checked (analysis of the user's
    Trumpet binary is allowed locally; unverified how it detects it).
  - Windows 3.x menus: done on feat/win3-net (Part A of this round,
    `docs/win3-net-2026-10-23.md`): `C:\NET\NETSTART.BAT` runs before `WIN`
    in every Windows 1.x-3.x start menu, USOSPKT loaded low (our CONFIG.SYS
    has no UMB provider). Windows 3.1 needs the 386-enhanced item for
    Trumpet; in QEMU (SeaBIOS USB input) Windows 3.1 386 enhanced mode loses
    the USB keyboard and mouse even without USOSPKT (control run 2026-10-23),
    so that path is judged on the X470 (WfW 3.11, enhanced only, works
    there). TRUMPWSK.INI with DHCP (Trumpet 3.0 has
    DHCP; 2.0b would need the mTCP DHCP lease written as static values -
    unverified).
  - Trumpet itself: user drops it into `DATA\Drivers` (or the media folder);
    USOS never ships it.
* **M2 (20-30 person-days, public deliverable): own GPL `WINSOCK.DLL`
  (Win16, OpenWatcom), TCP/UDP/DNS from mTCP's GPL-3.0 code**, talking to
  USOSPKT in a queue mode (frames kept in USOSPKT's own ring, the DLL polls
  them via a DPMI-mapped selector + timer/hidden window; no real-mode upcall
  into Windows) - works in **standard and enhanced mode** and on both 3.1 and
  WfW, with no third-party file at all. Winsock 1.1 surface: ~45 exports
  incl. WSAAsyncSelect / WSAAsyncGetHostByName and blocking hooks; browser
  compatibility (Netscape 1.x-3.x, Mosaic, IE 3/5 16-bit) is the test bar.

**Fallback:** WfW 3.11 only - user-supplied TCP/IP-32 3.11b over our own
MAC. Start with the NDIS2 MAC (8-12 days) if the QEMU check shows TCP/IP-32
binding to an NDIS2 driver; otherwise (or with no I211 I/O BAR) the NDIS3 VxD
MAC (15-25 days). Gives the Microsoft Network client as a bonus, but nothing
for plain Windows 3.1.

## Top risks on the X470

| risk | impact | mitigation |
|---|---|---|
| I211 I/O BAR unassigned under CSMWrap/SeaBIOS | every real-mode driver dead inside WIN386 (MMIO refused in V86) | read USOSPKT.LOG first; assign the BAR ourselves before DOS (SeaBIOS/CSMWrap or USOSPKT writing BAR + bridge I/O window), or a ring-0 MMIO VxD loaded via the 1605h startup structure |
| receive upcall in the wrong VM (DOS box current) | crash / lost frames | WINPKT-style 1685h callback (M1) or queue mode (M2) |
| DMA block physical address after WIN386 start | NIC writes into the wrong page | load low (not UMB), keep the VDS lock, verify with a DOS-box + network stress run |
| IRQ: global reflection latency, edge-triggered line (X470 ELCR showed IRQ 5 edge) | lost interrupts | ISR already re-arms via IMC/IMS; timer poll stays as safety net (INT 08h is reflected by VPICD too) |
| CSMWrap/SeaBIOS USB HID polling + NIC IRQ + WIN386 together never tested | hangs | silent log to the target disk (USOSLOG pattern), DOS box test |
| conventional memory: USOSPKT 42 KiB + WINPKT + Trumpet + HIMEM/EMM386 | Windows 3.1 / DOS boxes tight | shrink DMA block for the Windows profile (8 RX buffers = -16 KiB), or the VxD route |
| Trumpet licence | cannot ship, 30-day evaluation | user-supplied only; M2 removes the dependency |

## Sources

* Trumpet Winsock 3.0 manual (licence sec. 1.5, packet driver / WINPKT /
  shim table): https://cdimage.debian.org/mirror/archive/ftp.sunet.se/pub/simtelnet/trumpet/winsock/docs/twsk30p5.doc
* Trumpet Winsock, status and owner: https://en.wikipedia.org/wiki/Trumpet_Winsock ;
  OzEmail case: https://www.judgments.fedcourt.gov.au/judgments/Judgments/fca/single/1996/1996fca0560
* Trumpet standard vs enhanced mode (2.1 help): https://discmaster.textfiles.com/file/23879/PC%20World%20Interactive%206.iso/online/twsk21c.EXE/TRUMPWSK.HLP/TRUMPWSK.pdf
* WINPKT / DIS_PKT9 / ODIPKT with WfW (Doupnik): https://sunsite.icm.edu.pl/packages/novell/drivers/wfw.txt
* WINPKT doc: https://discmaster.textfiles.com/view/10596/science%20library(b).zip/science%20library(b)/COMMUNIC/2056.ZIP/MSK313.ZIP/NETWORKS/WINPKT.DOC
* Crynwr manifest (COPYING.DOC = FSF GPL): https://files.retropc.se/unpacked/hardware/net/crynwr/drivers.zip/manifest.doc
* Shim index: https://www.shikadi.net/network/
* NDIS3PKT licence quote (VOGONS): https://www.vogons.org/viewtopic.php?p=1320873 ; https://lists.endsoftwarepatents.org/archive/html/lynx-dev/2011-04/msg00015.html
* Twinsock: https://virtuallyfun.com/?p=376 ; https://ftp1.nluug.nl/pub/ibiblio/system/network/serial/twinsock2.0.ELF.lsm
* TCP/IP-32 3.11b: https://winworldpc.com/product/microsoft-tcp-ip-32/tcpip-32-3-11b ;
  PC Week review: https://blakeley.com/rooms/my-articles/WfW-IP.PCW210293.html ;
  Wolverine: https://columbia.edu/cu/moment/v0/030195/wolverine.html
* MS Network Client 3.0 setup: https://learn.microsoft.com/en-us/previous-versions/tn-archive/cc750214(v=technet.10) ;
  forum reports: https://www.vogons.org/viewtopic.php?p=1381251 , https://www.vogons.org/viewtopic.php?p=1366680
* NDIS 2.0.1 spec: https://www.edm2.com/index.php/3Com/Microsoft_LAN_Manager_Network_Driver_Interface_Specification_Version_2.0.1_Final
* NDIS versions per OS: https://en.wikipedia.org/wiki/Network_Driver_Interface_Specification
* mTCP (GPL-3.0): https://ftp.icm.edu.pl/packages/freedos/repositories/latest/pkg-html/mtcp.html
* Watt-32: https://tangentsoft.com/articles/othersys.html
