# Windows 98 SE fresh install on the X470 — fixes, 2026-10-20

Fresh install from build B261019-223809-E7B78C62 (int/me-round, d4e8ef27)
onto the Micron 3400 (RTL9210B-CG enclosure), stock USOS answer (no
profile). Working: mouse in Setup and in Windows (buttons, wheel), DOS-box
mouse (USOSVMD, also Alt+Enter), USB stick hot-swap, restart, power-off; no
ICW icon, no "0/10" window. The logs were read from the disk read-only (disk
signature bbd5e42d, partition 1 WINDOWS98 4E1C-303D FAT32, 32 GiB at 1 MiB;
partition 2 CSMWRAP with `pci_irq_routing = true`).

## I211: "device not working properly (0000)", no network

Evidence:

* `C:\WINDOWS\SYSTEM\USOSNET.SYS` present (0.4, the f61a1100 AUTOEXEC copy
  worked); `Class\Net\0000` complete; the driver started: `UsosnetStage`
  12, `UsosnetError` 0, IRQ 5, MAC read, PHY ID — the same values as the
  working Me install.
* `C:\WINDOWS\NDISLOG.TXT`: exactly four entries, USN1..USN4 at second 3,
  nothing afterwards (no USN5, no rounds at 10 / 30 / 60 s). The working Me
  installs log USN1..USN5 every round. `(0000)` in the notice is the
  `Class\Net` instance, not an error code. `DhcpInfo00` empty.
* NDIS.VXD 4.10.2222 (`C:\WINDOWS\SYSTEM\NDIS.VXD`, read-only, disassembled
  locally): `NdisWriteErrorLogEntry` keeps a per-adapter count and a 30 s
  timer started by the first entry. Until NDIS has seen VxD
  `Init_Complete`, the first entry posts the "device not working properly"
  notice and the **fifth entry within 30 s** schedules
  `CONFIGMG_Call_At_Appy_Time` -> `CONFIGMG_Remove_SubTree` on the
  adapter's devnode; later entries are dropped. Me's NDIS.VXD has the same
  code; its logs show five entries per round from second 3 on, so there
  `Init_Complete` evidently came earlier (inferred, not measured).

Cause: usosnet 0.4 wrote five entries (USN1..USN5) at second 3 of the first
round, during VxD initialisation of the first 98 SE start: NDIS showed the
notice and removed the adapter.

Fix (usosnet 0.5): `LogBudget` — no error log entry in the first 30 s and
at most 4 per 31 s window; rounds at 30 and 65 s and every 5 min (the first
round's USN5 and entries over the budget are skipped). Host-compiled test
against a model of the NDIS.VXD rule (`tools/tests/test_usosnet.py`,
`ErrorLogBudget`); a budget of 5 makes the model fail.

## Display stayed at 640x480

Evidence: `C:\USOS9X\DISPLAY.TXT` `1920x1080xauto`, the Run entry worked
(USOSRES ran at two sign-ins); `USOSRES.LOG` twice "DISPLAY no fresh VBE/INF
memory evidence; unchanged"; no `VBE.DAT` in `C:\USOS9X`, so the Win16 VBE
collector USOSVBI.EXE wrote nothing.

Cause found in the collector binary: its DGROUP began with the string
`VBE.DAT` at DS:0. KERNEL's InitTask / LocalInit write the local heap and
stack bounds into the first 16 bytes of a Win16 application's DGROUP
(USOSDBG reserves them with a `_NULL` BEGDATA area; USOSVBI did not), and
the collector's `zero_bss` then cleared the stack bounds. Fix: the same
reserved `_NULL` area; a test checks that the built DGROUP starts with 16
zero bytes.

Diagnostics for the next hardware start (the collector path itself was
never run on a desktop): USOSVBI writes `VBE.LOG` (stage reached, VBE
version, TotalMemory, mode list address, listed / kept modes, the first
rejected mode and why); USOSRES copies it into `USOSRES.LOG` and logs the
process start error, wait result and exit code, each VBE mode with its pitch
and each Windows mode with its verdict. USOSRES no longer requires the Win16
exit code: a fresh `VBE.DAT` (deleted before the start, magic, count, exact
length) is the evidence.

Not verified: the collector on a running 98 SE desktop; whether the X470's
VBE list (CSMWrap) passes the `2 * pitch * height` memory rule for
1920x1080. If it does not, the log now says which mode failed and why.
