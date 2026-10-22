# usosnvme - USOS NVMe SCSI miniport (NT 3.1 to Server 2003, x86)

Own GPL-3.0-or-later code (Copyright (C) 2026 Maksymilian and the USOS
Authors), written clean-room from the NVM Express Base Specification and the
public SCSI miniport documentation. No Microsoft source and no other NVMe
driver's source was used. Modelled on how AHCINT (ages2001, GPL-3.0, vendored
in `tools/vendor/ahcint`) is built and integrated, but no AHCINT code is in it.

Design and status: `docs/nvme-nt-2026-10-11.md`.

| Build | Folder | For | Notes |
|---|---|---|---|
| `2kxp`  | `bin/2KXP`  | Windows 2000 / XP / Server 2003 x86 | PnP ScsiPort (`Parameters\PnpInterface\5 = 1`), 64-bit DMA |
| `nt4`   | `bin/NT4`   | Windows NT 4.0 | non-PnP, scans PCI for class 01-08-02, no interrupt, PE 4.00 |
| `nt351` | `bin/NT351` | Windows NT 3.5 / 3.51 | PCI config through CF8h/CFCh, Isa registration, PE 3.51 |
| `nt31`  | `bin/NT31`  | Windows NT 3.1 | 0x40-byte init data, no SlotNumber, EISA bus master, PE 3.10 |

Build (WDK 7.1, as AHCINT / usosusb): `tools\nt\usosnvme\build.cmd all`
(`WDKROOT` if `tools\WinDDK71` is elsewhere). Tests:
`python tools/tests/test_usosnvme.py` (imports against the NT export
fixtures, PE versions, no CRT imports, source rules).

Behaviour: one admin and one I/O queue pair, polled (INTMS = all, PCI INTx
disable, I/O CQ with IEN = 0); READ/WRITE via PRP1/PRP2/one PRP list page,
split at min(MDTS, 128 KiB); FLUSH; the first active namespace is target 0,
LUN 0. Only 512-byte LBA formats without metadata are exposed; anything else
is refused (no disk) with an event-log entry (unique id 0x4E560003) and a red
line in VGA text row 9. A successful start writes a blue status line there
(`USOSNVME 1.0 VVVV:DDDD NS1 <MiB> MiB x512 chunk <K>K VWC <0/1> VS <ver> OK`).

Timeouts and flush (2026-10-22, all builds): the polling loop counts real
time (2 / 10 / 50 us steps); I/O and FLUSH give up after 10 s, admin
commands after 5 s (a polled wait at raised IRQL must stay well below the
~20 s DPC watchdog of Windows 8+). A timed-out command fails as ABORTED
COMMAND and the controller is re-initialised before the next one. FLUSH is
sent only after a WRITE since the last good flush and only with VWC = 1, so
SYNCHRONIZE CACHE + SRB_FUNCTION_FLUSH / SHUTDOWN cost one command. NT6:
SRB_FUNCTION_SHUTDOWN = flush + CC.SHN normal shutdown (RTD3E, 1-10 s).
A failed FLUSH is logged as unique id 0x4E561000 | (SCT << 8 | SC), 0x4E561FFF
for a timeout. Refused commands (invalid opcode / field / namespace) map to
ILLEGAL REQUEST, Namespace Not Ready to NOT READY, aborts to ABORTED COMMAND.

Diagnostics: IOCTL_SCSI_MINIPORT to `\\.\ScsiN:` with signature `USOSNVME`
and code 0x55534401 returns `USOSNVME_DIAG` (`src/usosnvme_diag.h`): flush
counts, last / max / total duration, last NVMe status, the last eight flushes,
read / write / error / timeout counters, CSTS at the last failure. The WinPE
helper `usos-nvme-modern.exe` prints it after every RegFlushKey and flush
probe (`[USOS] Modern NVMe diag ...` lines in usos-startup.log). Host test:
`tools/tests/test_usosnvme_flush.py` (driver code against a simulated
controller).
